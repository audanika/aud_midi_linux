// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:aud_midi_core/aud_midi_core.dart';
import 'package:aud_midi_linux/aud_midi_linux.dart';
import 'package:aud_midi_linux/src/alsa/alsa_bindings.g.dart';
import 'package:aud_midi_linux/src/alsa/alsa_client_info.dart';
import 'package:aud_midi_linux/src/alsa/alsa_event.dart';
import 'package:aud_midi_linux/src/alsa/alsa_event_layout.dart';
import 'package:aud_midi_linux/src/alsa/alsa_port_mapper.dart';
import 'package:aud_midi_linux/src/alsa/alsa_reader_loop.dart';
import 'package:aud_midi_linux/src/alsa/alsa_reader_message.dart';
import 'package:aud_midi_linux/src/alsa/alsa_sequencer.dart';
import 'package:aud_midi_linux/src/alsa/alsa_system.dart';
import 'package:aud_midi_standard/aud_midi_standard.dart';
import 'package:test/test.dart';

typedef T = snd_seq_event_type;

/// A port the fake sequencer created.
typedef _Port = ({String name, int capability, int type, int? queue});

/// A subscription the fake sequencer holds.
typedef _Connection = ({int port, int client, int sourcePort});

/// A removal the fake sequencer was asked for.
typedef _Removal = ({int queue, int destClient, int destPort, int? tag});

// #############################################################################
/// A sequencer client that records what the backend asks of it.
final class _FakeSequencer implements AlsaSequencer {
  _FakeSequencer(this._system, this.clientId, this._side);

  final _FakeSystem _system;
  final String _side;
  String name = '';
  Map<String, int?> pools = {};
  bool closed = false;
  final ports = <int, _Port>{};
  final connections = <_Connection>[];
  final events = <AlsaEvent>[];
  final removals = <_Removal>[];
  final freedQueues = <int>[];
  var _nextPort = 0;

  void _call(String api) {
    final failure = _system.failures['$_side.$api'];
    if (failure != null) throw failure;
  }

  @override
  final int clientId;

  @override
  void setClientName(String name) => this.name = name;

  @override
  bool enableUmp() => _system.ump;

  @override
  void setPools({int? input, int? output}) =>
      pools = {'input': input, 'output': output};

  @override
  int createPort({
    required String name,
    required int capability,
    required int type,
    int? timestampQueue,
  }) {
    final port = _nextPort++;
    ports[port] = (
      name: name,
      capability: capability,
      type: type,
      queue: timestampQueue,
    );
    return port;
  }

  @override
  void deletePort(int port) => ports.remove(port);

  @override
  void connectFrom({
    required int port,
    required int client,
    required int sourcePort,
  }) => connections.add((port: port, client: client, sourcePort: sourcePort));

  @override
  void disconnectFrom({
    required int port,
    required int client,
    required int sourcePort,
  }) =>
      connections.remove((port: port, client: client, sourcePort: sourcePort));

  @override
  List<AlsaClientInfo> clients() {
    _call('clients');
    return _system.clients;
  }

  @override
  int startQueue(String name) {
    _call('startQueue');
    return 3;
  }

  @override
  int queueTime(int queue) => _system.monotonic - _system.queueStart;

  @override
  void freeQueue(int queue) {
    _call('freeQueue');
    freedQueues.add(queue);
  }

  @override
  void output(AlsaEvent event) {
    _call('output');
    events.add(event);
    _system._outputted(event);
  }

  @override
  void removeEvents({
    required int queue,
    required int destClient,
    required int destPort,
    int? tag,
  }) => removals.add((
    queue: queue,
    destClient: destClient,
    destPort: destPort,
    tag: tag,
  ));

  @override
  void close() {
    closed = true;
    _call('close');
  }
}

// #############################################################################
/// An ALSA system with two fake clients and a scripted reader.
final class _FakeSystem implements AlsaSystem {
  final failures = <String, Object>{};
  Object? openOutputError;
  Object? openInputError;
  bool ump = false;
  bool readerStops = true;
  int monotonic = 1000000;
  int queueStart = 400000;
  List<AlsaClientInfo> clients = [];
  _FakeSequencer? output;
  _FakeSequencer? input;
  ({int wakeClient, int token})? reader;
  void Function(AlsaReaderMessage message)? _onMessage;
  final _done = Completer<void>();

  @override
  AlsaSequencer open({required bool input}) {
    if (input) {
      if (openInputError case final error?) throw error;
      return this.input = _FakeSequencer(this, 129, 'in');
    }
    if (openOutputError case final error?) throw error;
    return output = _FakeSequencer(this, 128, 'out');
  }

  @override
  Future<AlsaReader> startReader({
    required AlsaSequencer sequencer,
    required int wakeClient,
    required int token,
    required void Function(AlsaReaderMessage message) onMessage,
  }) async {
    _onMessage = onMessage;
    reader = (wakeClient: wakeClient, token: token);
    return _FakeReader(_done.future);
  }

  @override
  int monotonicNow() => monotonic;

  /// Delivers [message] as the reader isolate would.
  void send(AlsaReaderMessage message) => _onMessage!(message);

  /// Ends the reader isolate.
  void endReader() => _done.complete();

  void _outputted(AlsaEvent event) {
    if (event.type == T.SND_SEQ_EVENT_USR0 &&
        event.destClient == input!.clientId &&
        readerStops) {
      send(const AlsaReaderStopped());
      endReader();
    }
  }
}

final class _FakeReader implements AlsaReader {
  _FakeReader(this.done);

  @override
  final Future<void> done;
}

// #############################################################################
/// A host that records what the backend reports.
final class _Host implements MidiBackendHost {
  @override
  final MidiFakeClock clock = MidiFakeClock(start: const MidiTime(50000000));

  final portEvents = <MidiPortEvent>[];
  final packets = <(MidiPortId, MidiPacket)>[];
  final diagnostics = <MidiDiagnostic>[];

  @override
  void portsChanged(List<MidiPortEvent> events) => portEvents.addAll(events);

  @override
  void received(MidiPortId port, MidiPacket packet) =>
      packets.add((port, packet));

  @override
  void diagnostic(MidiDiagnostic diagnostic) => diagnostics.add(diagnostic);
}

// #############################################################################
/// A BLE transport whose peripherals connect at once.
final class _FakeBleTransport implements MidiBleTransport {
  final connections = <String, _FakeBleConnection>{};

  @override
  Stream<MidiBlePeripheralInfo> scan({Duration? timeout}) =>
      Stream.value(MidiBlePeripheralInfo(id: 'AA', name: 'Keys'));

  @override
  Future<void> stopScan() async {}

  @override
  Future<MidiBleConnection> connect(
    String peripheralId, {
    Duration timeout = const Duration(seconds: 10),
  }) async => connections[peripheralId] = _FakeBleConnection(peripheralId);
}

final class _FakeBleConnection implements MidiBleConnection {
  _FakeBleConnection(this.peripheralId);

  final written = <List<int>>[];
  Object? disconnectError;
  final _done = Completer<void>();

  @override
  final String peripheralId;

  @override
  Future<void> write(Uint8List packet) async => written.add(packet);

  @override
  Future<void> disconnect() async {
    if (disconnectError case final error?) throw error;
    if (!_done.isCompleted) _done.complete();
  }

  @override
  Stream<Uint8List> get notifications => const Stream.empty();

  @override
  int get maxPacketLength => 20;

  @override
  Future<void> get done => _done.future;
}

void main() {
  const kernel = snd_seq_client_type.SND_SEQ_KERNEL_CLIENT;
  const user = snd_seq_client_type.SND_SEQ_USER_CLIENT;
  const midi = SND_SEQ_PORT_TYPE_MIDI_GENERIC;
  const ownType =
      SND_SEQ_PORT_TYPE_MIDI_GENERIC |
      SND_SEQ_PORT_TYPE_SOFTWARE |
      SND_SEQ_PORT_TYPE_APPLICATION;
  const keys = AlsaClientInfo(
    client: 20,
    name: 'Keys',
    type: kernel,
    ports: [
      AlsaPortInfo(
        client: 20,
        port: 0,
        name: 'Keys MIDI 1',
        capability: AlsaPortMapper.readable | AlsaPortMapper.writable,
        type: midi,
      ),
    ],
  );
  const synth = AlsaClientInfo(
    client: 130,
    name: 'Synth',
    type: user,
    ports: [
      AlsaPortInfo(
        client: 130,
        port: 0,
        name: 'Synth in',
        capability: AlsaPortMapper.writable,
        type: midi,
      ),
    ],
  );
  const keysIn = MidiPortId('alsa:20:0:in');
  const keysOut = MidiPortId('alsa:20:0:out');
  const synthOut = MidiPortId('alsa:130:0:out');
  const now = MidiTime(50000000);

  late _FakeSystem system;
  late _Host host;
  late MidiFakeTimers timers;
  late LinuxMidiBackend backend;

  LinuxMidiBackend create({
    bool bluetooth = false,
    MidiBleTransport? bleTransport,
    bool useUmp = true,
  }) => LinuxMidiBackend(
    clientName: 'App',
    bluetooth: bluetooth,
    bleTransport: bleTransport,
    useUmp: useUmp,
    system: system,
    timerFactory: timers.create,
    random: Random(1),
    stopTimeout: const Duration(milliseconds: 20),
  );

  setUp(() {
    system = _FakeSystem()..clients = [keys, synth];
    host = _Host();
    timers = MidiFakeTimers(clock: host.clock);
    backend = create();
  });

  Future<void> start() => backend.start(host);

  _FakeSequencer output() => system.output!;
  _FakeSequencer input() => system.input!;

  /// An event as it arrives from [client]:[port] at the input client's
  /// [destPort], with the queue time [queueMicros] when given.
  AlsaEvent arriving(
    AlsaEvent event, {
    int client = 20,
    int port = 0,
    int destPort = 0,
    int? queueMicros,
  }) {
    final timed = queueMicros == null
        ? event
        : event.scheduled(queue: 3, microseconds: queueMicros);
    final cell = Uint8List.fromList(
      timed.routed(sourcePort: port, destClient: 129, destPort: destPort).cell,
    )..[AlsaEventLayout.sourceClient] = client;
    return AlsaEvent(cell: cell, ext: event.ext);
  }

  AlsaEvent announcement(int type, {required int client, int port = 0}) =>
      arriving(
        AlsaEvent.fixed(type: type, data: [client, port]),
        client: SND_SEQ_CLIENT_SYSTEM,
        port: SND_SEQ_PORT_SYSTEM_ANNOUNCE,
      );

  AlsaEvent noteOn([int note = 60]) => AlsaEvent.note(
    type: T.SND_SEQ_EVENT_NOTEON,
    channel: 0,
    note: note,
    velocity: 100,
  );

  MidiBytesPacket bytes(List<int> data, {MidiTime time = now}) =>
      MidiBytesPacket(bytes: MidiBytes(data), time: time);

  List<String> ids(List<MidiPortInfo> ports) => [
    for (final port in ports) port.id.value,
  ];

  group('LinuxMidiBackend', () {
    group('LinuxMidiBackend(...)', () {
      test('has defaults and the sub-APIs', () {
        final defaults = LinuxMidiBackend();
        expect(
          [
            defaults.name,
            defaults.clientName,
            defaults.useUmp,
            defaults.resyncInterval,
            defaults.stopTimeout,
            defaults.maxSysExChunk,
            defaults.network,
            identical(defaults.virtualPorts, defaults),
            defaults.bluetooth,
            backend.bluetooth,
          ],
          [
            'alsa',
            'aud_midi',
            true,
            const Duration(seconds: 10),
            const Duration(seconds: 2),
            256,
            null,
            true,
            isA<MidiBleBluetoothBackend>().having(
              (b) => b.transport,
              'transport',
              isA<MidiBlueZBleTransport>(),
            ),
            null,
          ],
        );
      });
    });

    group('capabilities', () {
      test('offers dynamic virtual ports and hardware scheduling', () {
        expect(
          backend.capabilities,
          MidiCapabilities(
            virtualPorts: MidiVirtualPortSupport.dynamicPorts,
            scheduling: MidiSchedulingSupport.hardware,
          ),
        );
      });

      test('offers BLE scans with Bluetooth and UMP in UMP mode', () async {
        system.ump = true;
        backend = create(bluetooth: true, bleTransport: _FakeBleTransport());
        await start();
        expect(
          [backend.capabilities.bleScan, backend.capabilities.ump],
          [true, true],
        );
      });
    });

    group('start(host)', () {
      test('opens both clients, the queue, the ports and the reader', () async {
        await start();
        expect(
          [
            output().name,
            input().name,
            output().pools,
            input().pools,
            output().ports,
            input().ports,
            input().connections,
            system.reader,
            ids(backend.ports),
            host.portEvents,
          ],
          [
            'App',
            'App (in)',
            {'input': null, 'output': 2000},
            {'input': 2000, 'output': null},
            {
              0: (
                name: 'out',
                capability: SND_SEQ_PORT_CAP_READ,
                type: ownType,
                queue: null,
              ),
            },
            {
              0: (
                name: 'in',
                capability: SND_SEQ_PORT_CAP_WRITE,
                type: ownType,
                queue: 3,
              ),
            },
            [(port: 0, client: 0, sourcePort: 1)],
            (wakeClient: 128, token: Random(1).nextInt(1 << 32)),
            [keysIn.value, keysOut.value, synthOut.value],
            isEmpty,
          ],
        );
      });

      test('switches to UMP only when told so', () async {
        system.ump = true;
        backend = create(useUmp: false);
        await start();
        expect(backend.ports.any((p) => p.capabilities.ump), isFalse);
      });

      test('fails when the output client cannot open', () async {
        system.openOutputError = const MidiUnsupported('ALSA');
        await expectLater(start(), throwsA(isA<MidiUnsupported>()));
        expect(system.input, isNull);
      });

      test('closes the output client when the input client fails', () async {
        system.openInputError = const MidiPermissionDenied(MidiPermission.midi);
        await expectLater(start(), throwsA(isA<MidiPermissionDenied>()));
        expect(output().closed, isTrue);
      });

      test('closes both clients when the setup fails', () async {
        system.failures['out.startQueue'] = const MidiNativeError(
          api: 'snd_seq_alloc_named_queue',
          code: -12,
        );
        await expectLater(start(), throwsA(isA<MidiNativeError>()));
        expect([output().closed, input().closed], [true, true]);
      });

      test('refuses to start twice', () async {
        await start();
        await expectLater(start(), throwsStateError);
      });

      test('reports a failing enumeration and goes on', () async {
        system.failures['out.clients'] = const MidiNativeError(
          api: 'snd_seq_query_next_client',
          code: -5,
        );
        await start();
        expect(
          [backend.ports, host.diagnostics.single.kind],
          [isEmpty, MidiDiagnosticKind.nativeError],
        );
      });

      test('starts the BLE backend', () async {
        backend = create(bluetooth: true, bleTransport: _FakeBleTransport());
        await start();
        final ble = backend.bluetooth! as MidiBleBluetoothBackend;
        await expectLater(ble.start(host), throwsStateError);
      });
    });

    group('stop()', () {
      test('wakes the reader up and closes everything', () async {
        await start();
        await backend.stop();
        expect(
          [
            output().events,
            output().freedQueues,
            input().closed,
            output().closed,
            backend.ports,
            backend.capabilities.ump,
          ],
          [
            [
              AlsaReaderLoop.wakeUp(
                token: system.reader!.token,
              ).routed(sourcePort: 0, destClient: 129, destPort: 0).direct(),
            ],
            [3],
            true,
            true,
            isEmpty,
            false,
          ],
        );
      });

      test('does nothing when not started', () async {
        await backend.stop();
        expect(system.output, isNull);
      });

      test('keeps the input client when the reader does not stop', () async {
        system.readerStops = false;
        await start();
        await backend.stop();
        expect(
          [input().closed, output().closed, host.diagnostics.single.cause],
          [false, true, contains('did not stop')],
        );
      });

      test('keeps the input client when the wake-up fails', () async {
        await start();
        system.failures['out.output'] = const MidiNativeError(
          api: 'snd_seq_event_output_direct',
          code: -11,
        );
        await backend.stop();
        expect(
          [input().closed, host.diagnostics.single.kind],
          [false, MidiDiagnosticKind.nativeError],
        );
      });

      test('skips the wake-up when the reader ended already', () async {
        await start();
        system
          ..send(const AlsaReaderFailed(-19))
          ..endReader();
        await backend.stop();
        expect([output().events, input().closed], [isEmpty, true]);
      });

      test('reports failures while releasing', () async {
        await start();
        system.failures
          ..['out.freeQueue'] = const MidiNativeError(
            api: 'snd_seq_free_queue',
            code: -22,
          )
          ..['out.close'] = const MidiNativeError(
            api: 'snd_seq_close',
            code: -9,
          );
        await backend.stop();
        expect(
          [for (final d in host.diagnostics) d.cause],
          [contains('snd_seq_free_queue'), contains('snd_seq_close')],
        );
      });

      test('closes the ALSA clients when Bluetooth fails to stop', () async {
        final transport = _FakeBleTransport();
        backend = create(bluetooth: true, bleTransport: transport);
        await start();
        await backend.bluetooth!.connect('AA');
        transport.connections['AA']!.disconnectError = StateError('gone');
        await backend.stop();
        expect(
          [host.diagnostics.single.cause, input().closed, output().closed],
          [contains('Stopping Bluetooth failed'), true, true],
        );
      });

      test('closes the BlueZ transport it created', () async {
        backend = LinuxMidiBackend(system: system, random: Random(1));
        await start();
        await backend.stop();
        expect(output().closed, isTrue);
      });

      test('cancels the clock resync', () async {
        await start();
        await backend.stop();
        expect(timers.pending, 0);
      });
    });

    group('openPort(port)', () {
      test('subscribes the input client to an input once', () async {
        await start();
        await backend.openPort(keysIn);
        await backend.openPort(keysIn);
        expect(input().connections, [
          (port: 0, client: 0, sourcePort: 1),
          (port: 0, client: 20, sourcePort: 0),
        ]);
      });

      test('prepares an output without native calls', () async {
        await start();
        await backend.openPort(synthOut);
        expect(input().connections, hasLength(1));
      });

      test('throws a MidiPortGone for an unknown port', () async {
        await start();
        await expectLater(
          backend.openPort(const MidiPortId('alsa:99:0:in')),
          throwsA(isA<MidiPortGone>()),
        );
      });

      test('throws a StateError before start', () async {
        await expectLater(backend.openPort(keysIn), throwsStateError);
      });

      test('hands BLE ports to the BLE backend', () async {
        backend = create(bluetooth: true, bleTransport: _FakeBleTransport());
        await start();
        await expectLater(
          backend.openPort(const MidiPortId('ble:AA/input')),
          throwsA(isA<MidiPortGone>()),
        );
      });
    });

    group('closePort(port)', () {
      test('ends the subscription of an input', () async {
        await start();
        await backend.openPort(keysIn);
        await backend.closePort(keysIn);
        expect(input().connections, [(port: 0, client: 0, sourcePort: 1)]);
      });

      test('does nothing before start', () async {
        await backend.closePort(keysIn);
        expect(system.output, isNull);
      });

      test('ignores ports that are not open', () async {
        await start();
        await backend.closePort(keysIn);
        await backend.closePort(const MidiPortId('alsa:99:0:in'));
        expect(input().connections, hasLength(1));
      });

      test('hands BLE ports to the BLE backend', () async {
        backend = create(bluetooth: true, bleTransport: _FakeBleTransport());
        await start();
        await backend.closePort(const MidiPortId('ble:AA/input'));
        expect(input().connections, hasLength(1));
      });
    });

    group('send(port, packet)', () {
      test('sends due bytes right away to the destination', () async {
        await start();
        await backend.send(synthOut, bytes([0x90, 60, 100]));
        expect(output().events, [
          noteOn().routed(sourcePort: 0, destClient: 130, destPort: 0).direct(),
        ]);
      });

      test('schedules bytes due later on the queue', () async {
        await start();
        await backend.send(
          keysOut,
          bytes([0x90, 60, 100], time: now + const Duration(milliseconds: 100)),
        );
        expect(output().events, [
          noteOn()
              .routed(sourcePort: 0, destClient: 20, destPort: 0)
              .scheduled(queue: 3, microseconds: 700000),
        ]);
      });

      test('sends right away when the queue time would be negative', () async {
        system.queueStart = 2000000;
        await start();
        await backend.send(
          keysOut,
          bytes([0xF8], time: now + const Duration(microseconds: 10)),
        );
        expect(output().events.single.queue, SND_SEQ_QUEUE_DIRECT);
      });

      test('sends UMP words as UMP events in UMP mode', () async {
        system.ump = true;
        await start();
        await backend.send(
          synthOut,
          MidiUmpPacket(words: [0x40903C00, 0xC8000000], time: now),
        );
        expect(output().events, [
          AlsaEvent.ump([
            0x40903C00,
            0xC8000000,
          ]).routed(sourcePort: 0, destClient: 130, destPort: 0).direct(),
        ]);
      });

      test('refuses UMP words on a byte port', () async {
        await start();
        await expectLater(
          backend.send(synthOut, MidiUmpPacket(words: [0x20903C64], time: now)),
          throwsA(
            isA<MidiUnsupported>().having(
              (e) => e.feature,
              'feature',
              'UMP words on the MIDI 1.0 port alsa:130:0:out',
            ),
          ),
        );
      });

      test('refuses bytes on a UMP port', () async {
        system.ump = true;
        await start();
        await expectLater(
          backend.send(synthOut, bytes([0xF8])),
          throwsA(
            isA<MidiUnsupported>().having(
              (e) => e.feature,
              'feature',
              'MIDI 1.0 bytes on the UMP port alsa:130:0:out',
            ),
          ),
        );
      });

      test('sends from an own source to its subscribers', () async {
        await start();
        final source = await backend.create(
          MidiVirtualPortSpec(name: 'Out', direction: MidiDirection.output),
        );
        await backend.send(source.id, bytes([0xFA]));
        expect(output().events, [
          AlsaEvent.fixed(type: T.SND_SEQ_EVENT_START)
              .routed(
                sourcePort: 1,
                destClient: SND_SEQ_ADDRESS_SUBSCRIBERS,
                destPort: SND_SEQ_ADDRESS_UNKNOWN,
                tag: 1,
              )
              .direct(),
        ]);
      });

      test('refuses an input', () async {
        await start();
        await expectLater(
          backend.send(keysIn, bytes([0xF8])),
          throwsArgumentError,
        );
      });

      test('throws a MidiPortGone for an unknown port', () async {
        await start();
        await expectLater(
          backend.send(const MidiPortId('alsa:99:0:out'), bytes([0xF8])),
          throwsA(isA<MidiPortGone>()),
        );
      });

      test('reports skipped bytes', () async {
        await start();
        await backend.send(synthOut, bytes([60]));
        expect(
          [output().events, host.diagnostics],
          [
            isEmpty,
            [
              const MidiDiagnostic(
                kind: MidiDiagnosticKind.invalidData,
                port: synthOut,
                cause: 'Skipped 1 bytes or words that form no message',
                time: now,
              ),
            ],
          ],
        );
      });

      test('passes native failures on', () async {
        await start();
        system.failures['out.output'] = const MidiNativeError(
          api: 'snd_seq_event_output_direct',
          code: -11,
        );
        await expectLater(
          backend.send(synthOut, bytes([0xF8])),
          throwsA(isA<MidiNativeError>()),
        );
      });

      test('hands BLE ports to the BLE backend', () async {
        backend = create(bluetooth: true, bleTransport: _FakeBleTransport());
        await start();
        await expectLater(
          backend.send(const MidiPortId('ble:AA/output'), bytes([0xF8])),
          throwsA(isA<MidiPortGone>()),
        );
        expect(output().events, isEmpty);
      });
    });

    group('send(port, packet) over BLE', () {
      test('writes to a connected peripheral', () async {
        final transport = _FakeBleTransport();
        backend = create(bluetooth: true, bleTransport: transport);
        await start();
        await backend.bluetooth!.connect('AA');
        await backend.openPort(const MidiPortId('ble:AA/output'));
        await backend.send(
          const MidiPortId('ble:AA/output'),
          bytes([0x90, 60, 100]),
        );
        await backend.cancelPending(const MidiPortId('ble:AA/output'));
        await backend.closePort(const MidiPortId('ble:AA/output'));
        expect(
          [transport.connections['AA']!.written.length, output().events],
          [1, isEmpty],
        );
      });
    });

    group('cancelPending(port)', () {
      test('removes the queued events of an output', () async {
        await start();
        await backend.cancelPending(synthOut);
        expect(output().removals, [
          (queue: 3, destClient: 130, destPort: 0, tag: null),
        ]);
      });

      test('removes the tagged events of an own source', () async {
        await start();
        final source = await backend.create(
          MidiVirtualPortSpec(name: 'Out', direction: MidiDirection.output),
        );
        await backend.cancelPending(source.id);
        expect(output().removals, [
          (
            queue: 3,
            destClient: SND_SEQ_ADDRESS_SUBSCRIBERS,
            destPort: SND_SEQ_ADDRESS_UNKNOWN,
            tag: 1,
          ),
        ]);
      });

      test('forgets an unfinished SysEx', () async {
        await start();
        await backend.send(synthOut, bytes([0xF0, 1]));
        await backend.cancelPending(synthOut);
        await backend.send(synthOut, bytes([2, 0xF7]));
        expect(host.diagnostics.single.count, 2);
      });

      test('refuses an input', () async {
        await start();
        await expectLater(backend.cancelPending(keysIn), throwsArgumentError);
      });

      test('hands BLE ports to the BLE backend', () async {
        backend = create(bluetooth: true, bleTransport: _FakeBleTransport());
        await start();
        await expectLater(
          backend.cancelPending(const MidiPortId('ble:AA/output')),
          throwsA(isA<MidiPortGone>()),
        );
        expect(output().removals, isEmpty);
      });
    });

    group('create(spec)', () {
      test('creates a destination on the input client', () async {
        await start();
        final port = await backend.create(
          MidiVirtualPortSpec(
            name: 'Loop',
            direction: MidiDirection.input,
            protocol: MidiProtocol.midi2,
            uniqueId: 7,
            groups: [1],
            manufacturer: 'Audanika',
            model: 'M',
          ),
        );
        expect(
          [input().ports[1], port, port.native, ids(backend.ports).last],
          [
            (
              name: 'Loop',
              capability: AlsaPortMapper.writable,
              type: ownType,
              queue: 3,
            ),
            MidiPortInfo(
              id: const MidiPortId('alsa:129:1:in'),
              deviceId: const MidiDeviceId('alsa:129'),
              name: 'Loop',
              manufacturer: 'Audanika',
              direction: MidiDirection.input,
              index: 1,
              transport: MidiTransport.virtual,
              isVirtual: true,
              isOwn: true,
              groups: [const MidiGroupInfo(group: 1)],
              capabilities: const MidiPortCapabilities(timestampsIn: true),
            ),
            {
              'client': 129,
              'port': 1,
              'uniqueId': 7,
              'model': 'M',
              MidiPortRegistry.deviceNameKey: 'App (in)',
              MidiPortRegistry.productKey: 'App',
              MidiPortRegistry.driverKey: AlsaPortMapper.userDriver,
            },
            'alsa:129:1:in',
          ],
        );
      });

      test('creates a MIDI 2.0 source on the output client', () async {
        system.ump = true;
        await start();
        final port = await backend.create(
          MidiVirtualPortSpec(
            name: 'Out',
            direction: MidiDirection.output,
            protocol: MidiProtocol.midi2,
          ),
        );
        expect(
          [output().ports[1], port.id, port.protocol, port.capabilities],
          [
            (
              name: 'Out',
              capability: AlsaPortMapper.readable,
              type: ownType,
              queue: null,
            ),
            const MidiPortId('alsa:128:1:out'),
            MidiProtocol.midi2,
            const MidiPortCapabilities(
              scheduledSend: true,
              cancelPending: true,
              ump: true,
            ),
          ],
        );
      });

      test('throws a StateError before start', () async {
        await expectLater(
          backend.create(
            MidiVirtualPortSpec(name: 'X', direction: MidiDirection.input),
          ),
          throwsStateError,
        );
      });
    });

    group('remove(port)', () {
      test('deletes a destination', () async {
        await start();
        final port = await backend.create(
          MidiVirtualPortSpec(name: 'In', direction: MidiDirection.input),
        );
        await backend.openPort(port.id);
        await backend.remove(port.id);
        expect(
          [input().ports.keys, ids(backend.ports)],
          [
            [0],
            [keysIn.value, keysOut.value, synthOut.value],
          ],
        );
      });

      test('drops the queued events of a source and deletes it', () async {
        await start();
        final port = await backend.create(
          MidiVirtualPortSpec(name: 'Out', direction: MidiDirection.output),
        );
        await backend.openPort(port.id);
        await backend.remove(port.id);
        expect(
          [output().removals.single.tag, output().ports.keys],
          [
            1,
            [0],
          ],
        );
      });

      test('throws a MidiPortGone for other ports', () async {
        await start();
        await expectLater(backend.remove(keysIn), throwsA(isA<MidiPortGone>()));
      });
    });

    group('ports', () {
      test('contains the ports of connected BLE peripherals', () async {
        backend = create(bluetooth: true, bleTransport: _FakeBleTransport());
        await start();
        await backend.bluetooth!.connect('AA');
        expect(ids(backend.ports), [
          keysIn.value,
          keysOut.value,
          synthOut.value,
          'ble:AA/input',
          'ble:AA/output',
        ]);
      });

      test('adds the ports of the BLE backend', () async {
        backend = create(bluetooth: true, bleTransport: _FakeBleTransport());
        await start();
        expect(ids(backend.ports), [
          keysIn.value,
          keysOut.value,
          synthOut.value,
        ]);
      });
    });

    group('reader messages', () {
      test('deliver events of open inputs with their time', () async {
        await start();
        await backend.openPort(keysIn);
        system.send(
          AlsaReaderEvents([
            arriving(noteOn(), queueMicros: 650000),
            arriving(noteOn(61)),
          ]),
        );
        expect(host.packets, [
          (keysIn, bytes([0x90, 60, 100], time: const MidiTime(50050000))),
          (keysIn, bytes([0x90, 61, 100])),
        ]);
      });

      test('deliver UMP packets in UMP mode', () async {
        system.ump = true;
        await start();
        await backend.openPort(keysIn);
        system.send(
          AlsaReaderEvents([
            arriving(AlsaEvent.ump([0x20903C64])),
            arriving(AlsaEvent.fixed(type: T.SND_SEQ_EVENT_USR1)),
          ]),
        );
        expect(host.packets, [
          (keysIn, MidiUmpPacket(words: [0x20903C64], time: now)),
        ]);
      });

      test('drop events of closed inputs and without MIDI', () async {
        await start();
        await backend.openPort(keysIn);
        system.send(
          AlsaReaderEvents([
            arriving(noteOn(), client: 130),
            arriving(AlsaEvent.fixed(type: T.SND_SEQ_EVENT_USR1)),
            arriving(noteOn(), destPort: 5),
          ]),
        );
        expect(host.packets, isEmpty);
      });

      test('deliver events of open own destinations', () async {
        await start();
        final port = await backend.create(
          MidiVirtualPortSpec(name: 'In', direction: MidiDirection.input),
        );
        system.send(AlsaReaderEvents([arriving(noteOn(), destPort: 1)]));
        await backend.openPort(port.id);
        system.send(AlsaReaderEvents([arriving(noteOn(62), destPort: 1)]));
        await backend.closePort(port.id);
        system.send(AlsaReaderEvents([arriving(noteOn(63), destPort: 1)]));
        expect(host.packets, [
          (port.id, bytes([0x90, 62, 100])),
        ]);
      });

      test('report overruns', () async {
        await start();
        system.send(const AlsaReaderOverflow());
        expect(host.diagnostics.single.kind, MidiDiagnosticKind.queueOverflow);
      });

      test('report overruns for every open input', () async {
        await start();
        final own = await backend.create(
          MidiVirtualPortSpec(name: 'In', direction: MidiDirection.input),
        );
        await backend.openPort(keysIn);
        await backend.openPort(own.id);
        system.send(const AlsaReaderOverflow());
        expect(
          [for (final d in host.diagnostics) (d.kind, d.port)],
          [
            (MidiDiagnosticKind.queueOverflow, keysIn),
            (MidiDiagnosticKind.queueOverflow, own.id),
          ],
        );
      });

      test('report a failed reader', () async {
        await start();
        system.send(const AlsaReaderFailed(-19));
        expect(
          [host.diagnostics.single.kind, host.diagnostics.single.cause],
          [MidiDiagnosticKind.nativeError, contains('-19')],
        );
      });

      test('are ignored after stop', () async {
        await start();
        await backend.stop();
        system.send(const AlsaReaderOverflow());
        expect(host.diagnostics, isEmpty);
      });
    });

    group('hotplug', () {
      const drums = AlsaClientInfo(
        client: 24,
        name: 'Drums',
        type: kernel,
        ports: [
          AlsaPortInfo(
            client: 24,
            port: 0,
            name: 'Drums MIDI 1',
            capability: AlsaPortMapper.readable,
            type: midi,
          ),
        ],
      );

      test('reports added ports', () async {
        await start();
        system.clients = [keys, synth, drums];
        system.send(
          AlsaReaderEvents([
            announcement(T.SND_SEQ_EVENT_PORT_START, client: 24),
          ]),
        );
        expect(
          [
            for (final event in host.portEvents)
              (event.runtimeType, event.port.id),
          ],
          [(MidiPortAdded, const MidiPortId('alsa:24:0:in'))],
        );
      });

      test('gives a reused client number a new generation', () async {
        await start();
        await backend.openPort(keysIn);
        await backend.openPort(keysOut);
        await backend.send(keysOut, bytes([0xF0, 1]));
        system.send(
          AlsaReaderEvents([
            announcement(T.SND_SEQ_EVENT_CLIENT_EXIT, client: 20),
            announcement(T.SND_SEQ_EVENT_CLIENT_EXIT, client: 128),
            announcement(T.SND_SEQ_EVENT_CLIENT_START, client: 20),
          ]),
        );
        system.send(AlsaReaderEvents([arriving(noteOn())]));
        await expectLater(
          backend.send(keysOut, bytes([2, 0xF7])),
          throwsA(isA<MidiPortGone>()),
        );
        expect(
          [
            for (final event in host.portEvents)
              (event.runtimeType, event.port.id.value),
            host.packets,
          ],
          [
            (MidiPortRemoved, 'alsa:20:0:in'),
            (MidiPortRemoved, 'alsa:20:0:out'),
            (MidiPortAdded, 'alsa:20#1:0:in'),
            (MidiPortAdded, 'alsa:20#1:0:out'),
            isEmpty,
          ],
        );
      });

      test('gives a re-created port a new generation', () async {
        await start();
        system.send(
          AlsaReaderEvents([
            announcement(T.SND_SEQ_EVENT_PORT_EXIT, client: 130),
            announcement(T.SND_SEQ_EVENT_PORT_EXIT, client: 129),
            announcement(T.SND_SEQ_EVENT_PORT_START, client: 130),
          ]),
        );
        expect(
          [
            for (final event in host.portEvents)
              (event.runtimeType, event.port.id.value),
          ],
          [
            (MidiPortRemoved, 'alsa:130:0:out'),
            (MidiPortAdded, 'alsa:130:0#1:out'),
          ],
        );
      });

      test('ignores subscription announcements', () async {
        await start();
        system.clients = [keys, synth, drums];
        system.send(
          AlsaReaderEvents([
            announcement(T.SND_SEQ_EVENT_PORT_SUBSCRIBED, client: 24),
          ]),
        );
        expect(host.portEvents, isEmpty);
      });

      test('resyncs the clocks', () async {
        await start();
        await backend.openPort(keysIn);
        system.queueStart += 10;
        system.send(
          AlsaReaderEvents([
            announcement(T.SND_SEQ_EVENT_PORT_CHANGE, client: 20),
            arriving(noteOn(), queueMicros: 650000),
          ]),
        );
        system.send(
          AlsaReaderEvents([arriving(noteOn(), queueMicros: 650000)]),
        );
        expect(
          [for (final (_, packet) in host.packets) packet.time],
          [const MidiTime(50050000), const MidiTime(50050010)],
        );
      });

      test('reports a failing enumeration', () async {
        await start();
        system.failures['out.clients'] = const MidiNativeError(
          api: 'snd_seq_query_next_client',
          code: -5,
        );
        system.send(
          AlsaReaderEvents([
            announcement(T.SND_SEQ_EVENT_PORT_START, client: 24),
          ]),
        );
        expect(
          [host.diagnostics.single.kind, ids(backend.ports)],
          [
            MidiDiagnosticKind.nativeError,
            [keysIn.value, keysOut.value, synthOut.value],
          ],
        );
      });
    });

    group('clock resync', () {
      test('compares the clocks after each interval', () async {
        await start();
        await backend.openPort(keysIn);
        system
          ..monotonic += 10000000
          ..queueStart += 10;
        timers.advance(const Duration(seconds: 10));
        system.send(
          AlsaReaderEvents([arriving(noteOn(), queueMicros: 650000)]),
        );
        expect(
          [host.packets.single.$2.time, timers.pending],
          [const MidiTime(50050010), 1],
        );
      });
    });
  });
}
