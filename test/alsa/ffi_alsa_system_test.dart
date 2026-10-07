// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

@TestOn('linux')
library;

import 'dart:ffi';
import 'dart:io';

import 'package:aud_midi_core/aud_midi_core.dart';
import 'package:aud_midi_linux/aud_midi_linux.dart';
import 'package:aud_midi_linux/src/alsa/alsa_bindings.g.dart';
import 'package:aud_midi_linux/src/alsa/alsa_library.dart';
import 'package:aud_midi_linux/src/alsa/alsa_port_mapper.dart';
import 'package:aud_midi_linux/src/alsa/ffi_alsa_sequencer.dart';
import 'package:aud_midi_linux/src/alsa/ffi_alsa_system.dart';
import 'package:aud_midi_standard/aud_midi_standard.dart';
import 'package:ffi/ffi.dart';
import 'package:test/test.dart';

/// A host on the system clock that records what the backend reports.
final class _Host implements MidiBackendHost {
  @override
  final MidiClock clock = const MidiSystemClock();

  final packets = <(MidiPortId, MidiPacket)>[];
  final portEvents = <MidiPortEvent>[];
  final diagnostics = <MidiDiagnostic>[];

  @override
  void portsChanged(List<MidiPortEvent> events) => portEvents.addAll(events);

  @override
  void received(MidiPortId port, MidiPacket packet) =>
      packets.add((port, packet));

  @override
  void diagnostic(MidiDiagnostic diagnostic) => diagnostics.add(diagnostic);
}

// End-to-end tests of the backend on the real ALSA sequencer: needs
// libasound2 and /dev/snd/seq (sudo modprobe snd-seq), e.g. on the ubuntu
// runners of the CI. No hardware: the backend's own virtual source is
// connected to its own virtual destination.
void main() {
  final skip = File('/dev/snd/seq').existsSync()
      ? null
      : 'needs /dev/snd/seq (sudo modprobe snd-seq)';

  late _Host host;
  late LinuxMidiBackend backend;
  late AlsaLibrary library;
  late FfiAlsaSequencer helper;

  setUp(() async {
    host = _Host();
    backend = LinuxMidiBackend(
      clientName: 'aud_midi e2e',
      bluetooth: false,
      system: FfiAlsaSystem(),
    );
    await backend.start(host);
    library = AlsaLibrary.load();
    helper = FfiAlsaSequencer.open(library, input: false)
      ..setClientName('aud_midi helper');
  });

  tearDown(() async {
    helper.close();
    await backend.stop();
  });

  ({int client, int port}) addressOf(MidiPortInfo port) => (
    client: port.native['client']! as int,
    port: port.native['port']! as int,
  );

  /// Subscribes [destination] to [source] from a third client, like
  /// `aconnect` does.
  void subscribe(MidiPortInfo source, MidiPortInfo destination) {
    final b = library.bindings;
    final slot = calloc<Pointer<snd_seq_port_subscribe_t>>();
    final from = calloc<snd_seq_addr>()
      ..ref.client = addressOf(source).client
      ..ref.port = addressOf(source).port;
    final to = calloc<snd_seq_addr>()
      ..ref.client = addressOf(destination).client
      ..ref.port = addressOf(destination).port;
    try {
      expect(b.snd_seq_port_subscribe_malloc(slot), 0);
      b
        ..snd_seq_port_subscribe_set_sender(slot.value, from)
        ..snd_seq_port_subscribe_set_dest(slot.value, to);
      expect(
        b.snd_seq_subscribe_port(
          Pointer.fromAddress(helper.address),
          slot.value,
        ),
        0,
      );
      b.snd_seq_port_subscribe_free(slot.value);
    } finally {
      calloc
        ..free(slot)
        ..free(from)
        ..free(to);
    }
  }

  /// Creates an own source and destination, opens the destination and
  /// connects both.
  Future<(MidiPortInfo, MidiPortInfo)> loopback() async {
    final source = await backend.create(
      MidiVirtualPortSpec(name: 'loop out', direction: MidiDirection.output),
    );
    final destination = await backend.create(
      MidiVirtualPortSpec(name: 'loop in', direction: MidiDirection.input),
    );
    await backend.openPort(destination.id);
    subscribe(source, destination);
    return (source, destination);
  }

  Future<void> until(bool Function() condition) async {
    final watch = Stopwatch()..start();
    while (!condition()) {
      if (watch.elapsed > const Duration(seconds: 5)) fail('Timed out');
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  /// A note on as the loop carries it: MIDI 2.0 words in UMP mode, bytes
  /// otherwise.
  MidiPacket note(int number, MidiTime time) => backend.capabilities.ump
      ? MidiUmpPacket(words: [0x40900000 | number << 8, 0x80000000], time: time)
      : MidiBytesPacket(bytes: MidiBytes([0x90, number, 100]), time: time);

  List<int> payload(MidiPacket packet) => switch (packet) {
    MidiBytesPacket(:final bytes) => bytes.bytes.toList(),
    MidiUmpPacket(:final words) => words.toList(),
  };

  group('FfiAlsaSystem with LinuxMidiBackend', skip: skip, () {
    test('loops messages back in order with their time stamps', () async {
      final (source, destination) = await loopback();
      final sent = <MidiTime>[];
      for (var i = 0; i < 100; i++) {
        final now = host.clock.now();
        sent.add(now);
        await backend.send(source.id, note(i, now));
      }
      await until(() => host.packets.length == 100);
      for (var i = 0; i < 100; i++) {
        final (port, packet) = host.packets[i];
        expect(port, destination.id);
        expect(payload(packet), payload(note(i, sent[i])));
        expect(
          packet.time.difference(sent[i]).inMicroseconds,
          inInclusiveRange(-2000, 50000),
        );
      }
    });

    test('sends scheduled messages close to their time', () async {
      final (source, _) = await loopback();
      final due = host.clock.now() + const Duration(milliseconds: 200);
      await backend.send(source.id, note(60, due));
      await until(() => host.packets.isNotEmpty);
      final deviation = host.packets.single.$2.time.difference(due);
      expect(deviation.inMicroseconds.abs(), lessThan(10000));
    });

    test('cancels scheduled messages', () async {
      final (source, _) = await loopback();
      await backend.send(
        source.id,
        note(60, host.clock.now() + const Duration(milliseconds: 300)),
      );
      await backend.cancelPending(source.id);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(host.packets, isEmpty);
    });

    test('loops a long SysEx back', () async {
      if (backend.capabilities.ump) {
        markTestSkipped('the byte form of SysEx is checked in MIDI 1.0 mode');
        return;
      }
      final (source, _) = await loopback();
      final sysEx = [0xF0, for (var i = 0; i < 1000; i++) i & 0x7F, 0xF7];
      await backend.send(
        source.id,
        MidiBytesPacket(bytes: MidiBytes(sysEx), time: host.clock.now()),
      );
      await until(
        () =>
            host.packets.fold<int>(0, (n, p) => n + payload(p.$2).length) ==
            sysEx.length,
      );
      expect([for (final (_, p) in host.packets) ...payload(p)], sysEx);
    });

    test('reports ports of other clients coming and going', () async {
      final port = helper.createPort(
        name: 'hotplug',
        capability: AlsaPortMapper.readable,
        type: SND_SEQ_PORT_TYPE_MIDI_GENERIC,
      );
      final id = AlsaPortMapper.portId(
        backend: 'alsa',
        client: helper.clientId,
        port: port,
        direction: MidiDirection.input,
      );
      await until(
        () => host.portEvents.any((e) => e is MidiPortAdded && e.port.id == id),
      );
      expect(backend.ports.map((p) => p.id), contains(id));
      helper.deletePort(port);
      await until(
        () =>
            host.portEvents.any((e) => e is MidiPortRemoved && e.port.id == id),
      );
      expect(host.diagnostics, isEmpty);
    });
  });
}
