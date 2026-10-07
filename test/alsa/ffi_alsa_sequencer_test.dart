// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

@TestOn('linux')
library;

import 'dart:io';

import 'package:aud_midi_linux/src/alsa/alsa_bindings.g.dart';
import 'package:aud_midi_linux/src/alsa/alsa_event.dart';
import 'package:aud_midi_linux/src/alsa/alsa_library.dart';
import 'package:aud_midi_linux/src/alsa/alsa_port_mapper.dart';
import 'package:aud_midi_linux/src/alsa/ffi_alsa_sequencer.dart';
import 'package:test/test.dart';

// Runs against the real ALSA sequencer: needs libasound2 and /dev/snd/seq
// (sudo modprobe snd-seq), e.g. on the ubuntu runners of the CI.
void main() {
  final skip = File('/dev/snd/seq').existsSync()
      ? null
      : 'needs /dev/snd/seq (sudo modprobe snd-seq)';
  const type = SND_SEQ_PORT_TYPE_MIDI_GENERIC | SND_SEQ_PORT_TYPE_APPLICATION;

  late AlsaLibrary library;
  late FfiAlsaSequencer output;
  late FfiAlsaSequencer input;

  setUp(() {
    library = AlsaLibrary.load();
    output = FfiAlsaSequencer.open(library, input: false)
      ..setClientName('aud_midi test out');
    input = FfiAlsaSequencer.open(library, input: true)
      ..setClientName('aud_midi test in');
  });

  tearDown(() {
    input.close();
    output.close();
  });

  /// Creates a source on the output client subscribed by a destination of
  /// the input client that stamps events with the real time of [queue].
  ({int source, int destination}) connect(int queue) {
    final source = output.createPort(
      name: 'source',
      capability: AlsaPortMapper.readable,
      type: type,
    );
    final destination = input.createPort(
      name: 'destination',
      capability: SND_SEQ_PORT_CAP_WRITE,
      type: type,
      timestampQueue: queue,
    );
    input.connectFrom(
      port: destination,
      client: output.clientId,
      sourcePort: source,
    );
    return (source: source, destination: destination);
  }

  AlsaEvent toSubscribers(AlsaEvent event, int source) => event.routed(
    sourcePort: source,
    destClient: SND_SEQ_ADDRESS_SUBSCRIBERS,
    destPort: SND_SEQ_ADDRESS_UNKNOWN,
  );

  group('FfiAlsaSequencer', skip: skip, () {
    group('clients()', () {
      test('lists the system client and the own clients', () {
        final clients = {for (final c in output.clients()) c.client: c};
        expect(
          [
            clients[0]!.ports.map((p) => p.port).take(2),
            clients[output.clientId]!.name,
            clients[input.clientId]!.name,
          ],
          [
            [0, 1],
            'aud_midi test out',
            'aud_midi test in',
          ],
        );
      });
    });

    group('createPort(...), deletePort(port)', () {
      test('add and remove ports of the client', () {
        final port = output.createPort(
          name: 'virtual',
          capability: AlsaPortMapper.readable,
          type: type,
        );
        List<String> names() => [
          for (final c in output.clients())
            if (c.client == output.clientId)
              for (final p in c.ports) p.name,
        ];
        final created = names();
        output.deletePort(port);
        expect(
          [created, names()],
          [
            ['virtual'],
            isEmpty,
          ],
        );
      });
    });

    group('startQueue(name), queueTime(queue), freeQueue(queue)', () {
      test('run a real-time queue', () {
        final queue = output.startQueue('aud_midi test');
        final before = output.queueTime(queue);
        sleep(const Duration(milliseconds: 20));
        final elapsed = output.queueTime(queue) - before;
        output.freeQueue(queue);
        expect(elapsed, inInclusiveRange(15000, 200000));
      });
    });

    group('output(event), read()', () {
      test('deliver a note through a subscription with a time stamp', () {
        final queue = output.startQueue('aud_midi test');
        final ports = connect(queue);
        final note = AlsaEvent.note(
          type: snd_seq_event_type.SND_SEQ_EVENT_NOTEON,
          channel: 1,
          note: 60,
          velocity: 100,
        );
        output.output(toSubscribers(note, ports.source).direct());
        final received = input.read().event!;
        expect(
          [
            received.type,
            received.channel,
            received.note,
            received.velocity,
            received.sourceClient,
            received.sourcePort,
            received.destPort,
            received.hasRealTime,
            received.queue,
          ],
          [
            snd_seq_event_type.SND_SEQ_EVENT_NOTEON,
            1,
            60,
            100,
            output.clientId,
            ports.source,
            ports.destination,
            true,
            queue,
          ],
        );
      });

      test('carry SysEx as variable-length events', () {
        final ports = connect(output.startQueue('aud_midi test'));
        final bytes = [0xF0, for (var i = 0; i < 300; i++) i & 0x7F, 0xF7];
        output.output(
          toSubscribers(AlsaEvent.sysEx(bytes), ports.source).direct(),
        );
        final received = input.read().event!;
        expect([received.isVariable, received.ext], [true, bytes]);
      });

      test('carry UMP words when the system supports UMP', () {
        if (!output.enableUmp() || !input.enableUmp()) {
          markTestSkipped('no UMP support (kernel 6.5+, alsa-lib 1.2.10+)');
          return;
        }
        final ports = connect(output.startQueue('aud_midi test'));
        final words = [0x40903C00, 0xC8000000];
        output.output(
          toSubscribers(AlsaEvent.ump(words), ports.source).direct(),
        );
        final received = input.read().event!;
        expect(
          [received.isUmp, received.word(0), received.word(1)],
          [true, ...words],
        );
      });
    });

    group('removeEvents(queue, destClient, destPort, tag)', () {
      test('drops queued events before they are due', () {
        final queue = output.startQueue('aud_midi test');
        final ports = connect(queue);
        final due = output.queueTime(queue) + 300000;
        output.output(
          AlsaEvent.fixed(type: snd_seq_event_type.SND_SEQ_EVENT_CLOCK)
              .routed(
                sourcePort: ports.source,
                destClient: SND_SEQ_ADDRESS_SUBSCRIBERS,
                destPort: SND_SEQ_ADDRESS_UNKNOWN,
                tag: ports.source,
              )
              .scheduled(queue: queue, microseconds: due),
        );
        output.removeEvents(
          queue: queue,
          destClient: SND_SEQ_ADDRESS_SUBSCRIBERS,
          destPort: SND_SEQ_ADDRESS_UNKNOWN,
          tag: ports.source,
        );
        sleep(const Duration(milliseconds: 500));
        output.output(
          toSubscribers(
            AlsaEvent.fixed(type: snd_seq_event_type.SND_SEQ_EVENT_STOP),
            ports.source,
          ).direct(),
        );
        expect(input.read().event!.type, snd_seq_event_type.SND_SEQ_EVENT_STOP);
      });
    });

    group('disconnectFrom(port, client, sourcePort)', () {
      test('ends the subscription', () {
        final ports = connect(output.startQueue('aud_midi test'));
        input.disconnectFrom(
          port: ports.destination,
          client: output.clientId,
          sourcePort: ports.source,
        );
        expect(
          () => input.disconnectFrom(
            port: ports.destination,
            client: output.clientId,
            sourcePort: ports.source,
          ),
          throwsA(anything),
        );
      });
    });
  });
}
