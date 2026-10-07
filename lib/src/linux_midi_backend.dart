// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:async';
import 'dart:math';

import 'package:aud_midi_core/aud_midi_core.dart';
import 'package:aud_midi_standard/aud_midi_standard.dart';

import 'alsa/alsa_bindings.g.dart';
import 'alsa/alsa_event.dart';
import 'alsa/alsa_event_decoder.dart';
import 'alsa/alsa_event_encoder.dart';
import 'alsa/alsa_port_diff.dart';
import 'alsa/alsa_port_mapper.dart';
import 'alsa/alsa_reader_loop.dart';
import 'alsa/alsa_reader_message.dart';
import 'alsa/alsa_sequencer.dart';
import 'alsa/alsa_system.dart';
import 'alsa/alsa_time_base.dart';
import 'alsa/ffi_alsa_system.dart';
import 'ble/midi_bluez_ble_transport.dart';

// #############################################################################
/// The Linux backend of the aud_midi family: the ALSA sequencer through
/// alsa-lib, plus BLE-MIDI peripherals over BlueZ.
///
/// It opens two sequencer clients. The output client, named [clientName],
/// sends to other ports, owns the virtual sources and the real-time queue
/// for scheduled sends. The input client, named `'<clientName> (in)'`, is
/// read by a reader isolate that blocks in `snd_seq_event_input`; its input
/// port subscribes to every opened source and to the system announce port
/// for hotplug, and it owns the virtual destinations. Both clients switch to
/// UMP with the MIDI 2.0 protocol when alsa-lib and the kernel support it;
/// their ports then exchange UMP words, otherwise MIDI 1.0 bytes.
///
/// Ports of other clients are inputs when they can be read and subscribed
/// to and outputs when they can be written and subscribed to; their ids are
/// `alsa:<client>:<port>:in` and `…:out`. Received events carry the queue's
/// real time stamp converted to the package clock; sends due in the future
/// go to the queue with their time stamp, [cancelPending] removes them
/// again.
///
/// BLE-MIDI peripherals come from a [MidiBleBluetoothBackend] on top of a
/// [MidiBleTransport] (BlueZ by default); their ports have ids `ble:…` and
/// appear in [ports] like all others.
final class LinuxMidiBackend implements MidiBackend, MidiVirtualPortsBackend {
  /// Creates the backend.
  ///
  /// - [clientName] the name other applications see for the app.
  /// - [bluetooth] whether BLE-MIDI peripherals are supported; they are
  ///   reached through [bleTransport], by default BlueZ over D-Bus.
  /// - [useUmp] whether the clients switch to UMP when possible.
  /// - [resyncInterval] how often the clocks are compared again.
  /// - [stopTimeout] how long [stop] waits for the reader isolate.
  /// - [maxSysExChunk] the largest SysEx event sent, in bytes.
  /// - [system] the native layer; tests pass a fake.
  /// - [timerFactory] creates the resync timer; tests pass fake timers.
  /// - [random] creates the token of the reader's wake-up event.
  LinuxMidiBackend({
    this.clientName = 'aud_midi',
    bool bluetooth = true,
    MidiBleTransport? bleTransport,
    this.useUmp = true,
    this.resyncInterval = const Duration(seconds: 10),
    this.stopTimeout = const Duration(seconds: 2),
    this.maxSysExChunk = 256,
    AlsaSystem? system,
    this._timerFactory = Timer.new,
    Random? random,
  }) : _system = system ?? FfiAlsaSystem(),
       _random = random ?? Random.secure(),
       _ble = bluetooth
           ? MidiBleBluetoothBackend(
               transport: bleTransport ?? MidiBlueZBleTransport(),
             )
           : null;

  // ...........................................................................
  /// Opens both sequencer clients, the queue and the reader isolate and
  /// enumerates the ports.
  ///
  /// Throws a [MidiUnsupported] without alsa-lib or `/dev/snd/seq`, a
  /// [MidiPermissionDenied] when the user may not use the sequencer and a
  /// [MidiNativeError] when another call fails.
  @override
  Future<void> start(MidiBackendHost host) async {
    if (_session != null) throw StateError('The backend is running');
    final output = _system.open(input: false);
    final AlsaSequencer input;
    try {
      input = _system.open(input: true);
    } on Object {
      output.close();
      rethrow;
    }
    final _AlsaSession session;
    try {
      session = await _open(host, output, input);
    } on Object {
      input.close();
      output.close();
      rethrow;
    }
    _session = session;
    _rescan(report: false);
    _armResync(session);
    await _ble?.start(host);
  }

  /// Stops the reader isolate, drops the queued events and closes both
  /// clients; BLE peripherals are disconnected.
  @override
  Future<void> stop() async {
    final session = _session;
    if (session == null) return;
    _resyncTimer?.cancel();
    await _stopBluetooth();
    final readerStopped = await _stopReader(session);
    _tryNative(() => session.output.freeQueue(session.queue));
    if (readerStopped) _tryNative(session.input.close);
    _tryNative(session.output.close);
    _session = null;
    _ports = const [];
    _own.clear();
    _openSources.clear();
    _openOwnInputs.clear();
    _encoders.clear();
  }

  // ...........................................................................
  /// Opens [port]: an input subscribes the input client to it, an output
  /// gets an encoder.
  ///
  /// Throws a [MidiPortGone] for an unknown port.
  @override
  Future<void> openPort(MidiPortId port) async {
    final ble = _bleFor(port);
    if (ble != null) return ble.openPort(port);
    final session = _requireSession();
    final own = _own[port];
    if (own != null) {
      if (own.info.isInput) _openOwnInputs.add(port);
      return;
    }
    final info = _require(port);
    if (info.isOutput) {
      _encoderFor(port);
      return;
    }
    final address = _addressOf(info);
    if (_openSources.containsKey(address)) return;
    session.input.connectFrom(
      port: session.inPort,
      client: address.client,
      sourcePort: address.port,
    );
    _openSources[address] = port;
  }

  /// Closes [port]; an input ends its subscription. Unknown ports, closed
  /// ports and calls before [start] are ignored.
  @override
  Future<void> closePort(MidiPortId port) async {
    final ble = _bleFor(port);
    if (ble != null) return ble.closePort(port);
    final session = _session;
    if (session == null) return;
    _openOwnInputs.remove(port);
    _encoders.remove(port);
    final entry = _openSources.entries
        .where((e) => e.value == port)
        .firstOrNull;
    if (entry == null) return;
    _openSources.remove(entry.key);
    session.input.disconnectFrom(
      port: session.inPort,
      client: entry.key.client,
      sourcePort: entry.key.port,
    );
  }

  // ...........................................................................
  /// Sends [packet] to the output [port]: right away when it is due, else
  /// scheduled on the queue at its time.
  ///
  /// Throws a [MidiPortGone] for an unknown port, an [ArgumentError] for an
  /// input, a [MidiUnsupported] for a packet in the wrong raw form (bytes
  /// for a UMP port or UMP words for a byte port) and a [MidiNativeError]
  /// when the sequencer refuses an event, e.g. because its pool is full.
  @override
  Future<void> send(MidiPortId port, MidiPacket packet) async {
    final ble = _bleFor(port);
    if (ble != null) return ble.send(port, packet);
    final session = _requireSession();
    final target = _targetOf(port);
    final encoded = switch (packet) {
      MidiBytesPacket(:final bytes) when !target.ump => _encoderFor(
        port,
      ).encodeBytes(bytes.bytes),
      MidiUmpPacket(:final words) when target.ump => AlsaEventEncoder.encodeUmp(
        words,
      ),
      _ => throw MidiUnsupported(
        target.ump
            ? 'MIDI 1.0 bytes on the UMP port $port'
            : 'UMP words on the MIDI 1.0 port $port',
      ),
    };
    if (encoded.skipped > 0) {
      _diagnostic(
        MidiDiagnosticKind.invalidData,
        port: port,
        count: encoded.skipped,
        cause: 'Skipped ${encoded.skipped} bytes or words that form no message',
      );
    }
    final queueTime = _queueTimeOf(session, packet.time);
    for (final event in encoded.events) {
      final routed = event.routed(
        sourcePort: target.sourcePort,
        destClient: target.destClient,
        destPort: target.destPort,
        tag: target.tag,
      );
      session.output.output(
        queueTime == null
            ? routed.direct()
            : routed.scheduled(queue: session.queue, microseconds: queueTime),
      );
    }
  }

  /// Removes the events queued for the output [port] that are not due yet.
  ///
  /// Throws a [MidiPortGone] for an unknown port and an [ArgumentError] for
  /// an input.
  @override
  Future<void> cancelPending(MidiPortId port) async {
    final ble = _bleFor(port);
    if (ble != null) return ble.cancelPending(port);
    final session = _requireSession();
    final target = _targetOf(port);
    session.output.removeEvents(
      queue: session.queue,
      destClient: target.destClient,
      destPort: target.destPort,
      tag: _own.containsKey(port) ? target.tag : null,
    );
    _encoders[port]?.reset();
  }

  // ...........................................................................
  /// Creates a port of the app's own clients that other applications see:
  /// a source on the output client or a destination on the input client.
  ///
  /// The port is added to [ports] at once, without a port event. Throws a
  /// [StateError] before [start].
  @override
  Future<MidiPortInfo> create(MidiVirtualPortSpec spec) async {
    final session = _requireSession();
    final isInput = spec.direction == MidiDirection.input;
    final sequencer = isInput ? session.input : session.output;
    final number = sequencer.createPort(
      name: spec.name,
      capability: isInput ? AlsaPortMapper.writable : AlsaPortMapper.readable,
      type: _ownPortType,
      timestampQueue: isInput ? session.queue : null,
    );
    final ump = isInput ? session.umpIn : session.umpOut;
    final info = MidiPortInfo(
      id: AlsaPortMapper.portId(
        backend: name,
        client: sequencer.clientId,
        port: number,
        direction: spec.direction,
      ),
      deviceId: AlsaPortMapper.deviceId(
        backend: name,
        client: sequencer.clientId,
      ),
      name: spec.name,
      manufacturer: spec.manufacturer,
      direction: spec.direction,
      index: number,
      transport: MidiTransport.virtual,
      protocol: ump ? spec.protocol : MidiProtocol.midi1,
      isVirtual: true,
      isOwn: true,
      groups: [for (final group in spec.groups) MidiGroupInfo(group: group)],
      capabilities: MidiPortCapabilities(
        timestampsIn: isInput,
        scheduledSend: !isInput,
        cancelPending: !isInput,
        ump: ump,
      ),
      native: {
        'client': sequencer.clientId,
        'port': number,
        'uniqueId': spec.uniqueId,
        'model': spec.model,
        MidiPortRegistry.deviceNameKey: isInput
            ? '$clientName (in)'
            : clientName,
        MidiPortRegistry.productKey: clientName,
        MidiPortRegistry.driverKey: AlsaPortMapper.userDriver,
      },
    );
    _own[info.id] = (info: info, port: number);
    return info;
  }

  /// Removes the own virtual [port]; queued events of a source are dropped.
  ///
  /// Throws a [MidiPortGone] when [port] is no own virtual port.
  @override
  Future<void> remove(MidiPortId port) async {
    final session = _requireSession();
    final own = _own[port];
    if (own == null) throw MidiPortGone(port);
    if (own.info.isOutput) await cancelPending(port);
    (own.info.isInput ? session.input : session.output).deletePort(own.port);
    _own.remove(port);
    _openOwnInputs.remove(port);
    _encoders.remove(port);
  }

  // ...........................................................................
  /// The name other applications see for the app.
  final String clientName;

  /// Whether the clients switch to UMP when possible.
  final bool useUmp;

  /// How often the clocks are compared again.
  final Duration resyncInterval;

  /// How long [stop] waits for the reader isolate.
  final Duration stopTimeout;

  /// The largest SysEx event sent, in bytes.
  final int maxSysExChunk;

  @override
  String get name => 'alsa';

  /// Dynamic virtual ports, hardware scheduling, BLE scanning when enabled
  /// and UMP when the clients run in UMP mode.
  @override
  MidiCapabilities get capabilities => MidiCapabilities(
    virtualPorts: MidiVirtualPortSupport.dynamicPorts,
    bleScan: _ble != null,
    ump: _session?.umpIn == true || _session?.umpOut == true,
    scheduling: MidiSchedulingSupport.hardware,
  );

  /// The ports of other clients, the own virtual ports and the ports of
  /// connected BLE peripherals.
  @override
  List<MidiPortInfo> get ports => [
    ..._ports,
    for (final own in _own.values) own.info,
    ...?_ble?.ports,
  ];

  @override
  MidiVirtualPortsBackend get virtualPorts => this;

  @override
  MidiBluetoothBackend? get bluetooth => _ble;

  /// Null: the umbrella package composes the network session.
  @override
  MidiNetworkBackend? get network => null;

  // ...........................................................................
  final AlsaSystem _system;
  final MidiTimerFactory _timerFactory;
  final Random _random;
  final MidiBleBluetoothBackend? _ble;
  late final _mapper = AlsaPortMapper(backend: name);

  _AlsaSession? _session;
  List<MidiPortInfo> _ports = const [];
  final _own = <MidiPortId, ({MidiPortInfo info, int port})>{};
  final _openSources = <({int client, int port}), MidiPortId>{};
  final _openOwnInputs = <MidiPortId>{};
  final _encoders = <MidiPortId, AlsaEventEncoder>{};
  final _generations = <int, int>{};
  final _portGenerations = <({int client, int port}), int>{};
  Timer? _resyncTimer;

  static const _ownPortType =
      SND_SEQ_PORT_TYPE_MIDI_GENERIC |
      SND_SEQ_PORT_TYPE_SOFTWARE |
      SND_SEQ_PORT_TYPE_APPLICATION;

  static const _hotplugTypes = {
    snd_seq_event_type.SND_SEQ_EVENT_CLIENT_START,
    snd_seq_event_type.SND_SEQ_EVENT_CLIENT_EXIT,
    snd_seq_event_type.SND_SEQ_EVENT_CLIENT_CHANGE,
    snd_seq_event_type.SND_SEQ_EVENT_PORT_START,
    snd_seq_event_type.SND_SEQ_EVENT_PORT_EXIT,
    snd_seq_event_type.SND_SEQ_EVENT_PORT_CHANGE,
    snd_seq_event_type.SND_SEQ_EVENT_UMP_EP_CHANGE,
    snd_seq_event_type.SND_SEQ_EVENT_UMP_BLOCK_CHANGE,
  };

  // ...........................................................................
  /// Sets up both clients, the queue, the ports and the reader.
  Future<_AlsaSession> _open(
    MidiBackendHost host,
    AlsaSequencer output,
    AlsaSequencer input,
  ) async {
    output
      ..setClientName(clientName)
      ..setPools(output: 2000);
    input
      ..setClientName('$clientName (in)')
      ..setPools(input: 2000);
    final umpIn = useUmp && input.enableUmp();
    final umpOut = useUmp && output.enableUmp();
    final queue = output.startQueue(clientName);
    final outPort = output.createPort(
      name: 'out',
      capability: SND_SEQ_PORT_CAP_READ,
      type: _ownPortType,
    );
    final inPort = input.createPort(
      name: 'in',
      capability: SND_SEQ_PORT_CAP_WRITE,
      type: _ownPortType,
      timestampQueue: queue,
    );
    input.connectFrom(
      port: inPort,
      client: SND_SEQ_CLIENT_SYSTEM,
      sourcePort: SND_SEQ_PORT_SYSTEM_ANNOUNCE,
    );
    final timeBase = AlsaTimeBase(
      clock: host.clock,
      monotonicNow: _system.monotonicNow,
      queueNow: () => output.queueTime(queue),
    );
    final token = _random.nextInt(1 << 32);
    final reader = await _system.startReader(
      sequencer: input,
      wakeClient: output.clientId,
      token: token,
      onMessage: _onReaderMessage,
    );
    return _AlsaSession(
      host: host,
      output: output,
      input: input,
      queue: queue,
      outPort: outPort,
      inPort: inPort,
      umpIn: umpIn,
      umpOut: umpOut,
      token: token,
      reader: reader,
      timeBase: timeBase,
    );
  }

  /// Disconnects the BLE peripherals and closes the BlueZ connection; a
  /// failure becomes a diagnostic, so the ALSA clients still close.
  Future<void> _stopBluetooth() async {
    final ble = _ble;
    if (ble == null) return;
    try {
      await ble.stop();
      final transport = ble.transport;
      if (transport is MidiBlueZBleTransport) await transport.close();
    } on Object catch (error) {
      _diagnostic(
        MidiDiagnosticKind.nativeError,
        cause: 'Stopping Bluetooth failed: $error',
      );
    }
  }

  /// Wakes the reader up with its token and waits until it ended; returns
  /// false when it did not, so its handle must stay open.
  Future<bool> _stopReader(_AlsaSession session) async {
    if (session.readerRunning) {
      final sent = _tryNative(
        () => session.output.output(
          AlsaReaderLoop.wakeUp(token: session.token)
              .routed(
                sourcePort: session.outPort,
                destClient: session.input.clientId,
                destPort: session.inPort,
              )
              .direct(),
        ),
      );
      if (!sent) return false;
    }
    try {
      await session.reader.done.timeout(stopTimeout);
      return true;
    } on TimeoutException {
      _diagnostic(
        MidiDiagnosticKind.nativeError,
        cause: 'The ALSA reader isolate did not stop within $stopTimeout',
      );
      return false;
    }
  }

  /// Runs [call] and reports a [MidiException] as a diagnostic; returns
  /// whether it succeeded.
  bool _tryNative(void Function() call) {
    try {
      call();
      return true;
    } on MidiException catch (error) {
      _diagnostic(MidiDiagnosticKind.nativeError, cause: '$error');
      return false;
    }
  }

  /// Compares the clocks of [session] again after [resyncInterval], then
  /// re-arms; [stop] cancels the timer.
  void _armResync(_AlsaSession session) {
    _resyncTimer = _timerFactory(resyncInterval, () {
      session.timeBase.resync();
      _armResync(session);
    });
  }

  // ...........................................................................
  /// Handles a message of the reader isolate.
  void _onReaderMessage(AlsaReaderMessage message) {
    final session = _session;
    if (session == null) return;
    switch (message) {
      case AlsaReaderEvents(:final events):
        _onEvents(session, events);
      case AlsaReaderOverflow():
        _overflowed();
      case AlsaReaderFailed(:final code):
        session.readerRunning = false;
        _diagnostic(
          MidiDiagnosticKind.nativeError,
          cause: 'snd_seq_event_input failed with $code; input stopped',
        );
      case AlsaReaderStopped():
        session.readerRunning = false;
    }
  }

  /// Reports an overrun of the input FIFO for every open input, so their
  /// parsers start over; without open input it is reported once.
  void _overflowed() {
    final inputs = <MidiPortId?>{..._openSources.values, ..._openOwnInputs};
    for (final port in inputs.isEmpty ? const <MidiPortId?>[null] : inputs) {
      _diagnostic(
        MidiDiagnosticKind.queueOverflow,
        port: port,
        cause: 'The ALSA sequencer input FIFO overran; events were lost',
      );
    }
  }

  /// Delivers received MIDI events and handles announcements.
  void _onEvents(_AlsaSession session, List<AlsaEvent> events) {
    var hotplug = false;
    for (final event in events) {
      if (event.sourceClient == SND_SEQ_CLIENT_SYSTEM &&
          event.sourcePort == SND_SEQ_PORT_SYSTEM_ANNOUNCE) {
        hotplug = _announced(session, event) || hotplug;
        continue;
      }
      final port = _inputOf(session, event);
      if (port != null) _deliver(session, port, event);
    }
    if (!hotplug) return;
    _rescan(report: true);
    session.timeBase.resync();
  }

  /// Notes an announcement; returns whether the ports may have changed.
  ///
  /// A client or port that left gets a new generation, so a client or port
  /// that reuses its number gets new ids, also within one batch.
  bool _announced(_AlsaSession session, AlsaEvent event) {
    if (!_hotplugTypes.contains(event.type)) return false;
    final client = event.addrClient;
    if (client == session.output.clientId || client == session.input.clientId) {
      return true;
    }
    switch (event.type) {
      case snd_seq_event_type.SND_SEQ_EVENT_CLIENT_EXIT:
        _generations[client] = (_generations[client] ?? 0) + 1;
      case snd_seq_event_type.SND_SEQ_EVENT_PORT_EXIT:
        final address = (client: client, port: event.addrPort);
        _portGenerations[address] = (_portGenerations[address] ?? 0) + 1;
    }
    return true;
  }

  /// Returns the open input [event] arrived on, or null.
  MidiPortId? _inputOf(_AlsaSession session, AlsaEvent event) {
    if (event.destPort == session.inPort) {
      return _openSources[(client: event.sourceClient, port: event.sourcePort)];
    }
    for (final id in _openOwnInputs) {
      if (_own[id]?.port == event.destPort) return id;
    }
    return null;
  }

  /// Hands the MIDI message of [event] to the host as a packet of [port].
  void _deliver(_AlsaSession session, MidiPortId port, AlsaEvent event) {
    final time = event.hasRealTime && event.queue == session.queue
        ? session.timeBase.toPackage(event.realTimeMicroseconds)
        : session.host.clock.now();
    if (session.umpIn) {
      final words = AlsaEventDecoder.toUmp(event);
      if (words == null) return;
      session.host.received(port, MidiUmpPacket(words: words, time: time));
      return;
    }
    final bytes = AlsaEventDecoder.toBytes(event);
    if (bytes == null) return;
    session.host.received(
      port,
      MidiBytesPacket(bytes: MidiBytes(bytes), time: time),
    );
  }

  // ...........................................................................
  /// Enumerates the ports again and, with [report], reports the changes.
  void _rescan({required bool report}) {
    final session = _requireSession();
    try {
      final next = _mapper.map(
        session.output.clients(),
        ownClients: {session.output.clientId, session.input.clientId},
        umpIn: session.umpIn,
        umpOut: session.umpOut,
        generations: _generations,
        portGenerations: _portGenerations,
      );
      final events = AlsaPortDiff.events(before: _ports, after: next);
      _ports = next;
      final ids = {for (final port in next) port.id};
      _openSources.removeWhere((_, id) => !ids.contains(id));
      _encoders.removeWhere(
        (id, _) => !ids.contains(id) && !_own.containsKey(id),
      );
      if (report && events.isNotEmpty) session.host.portsChanged(events);
    } on MidiException catch (error) {
      _diagnostic(MidiDiagnosticKind.nativeError, cause: '$error');
    }
  }

  /// Returns the BLE backend when it owns [port].
  MidiBleBluetoothBackend? _bleFor(MidiPortId port) {
    final ble = _ble;
    return ble != null && port.backend == ble.name ? ble : null;
  }

  _AlsaSession _requireSession() =>
      _session ?? (throw StateError('The backend is not started'));

  /// Returns the known port [port] of another client, or throws a
  /// [MidiPortGone].
  MidiPortInfo _require(MidiPortId port) {
    for (final info in _ports) {
      if (info.id == port) return info;
    }
    throw MidiPortGone(port);
  }

  static ({int client, int port}) _addressOf(MidiPortInfo info) =>
      (client: info.native['client'] as int, port: info.native['port'] as int);

  /// Returns how events for the output [port] are addressed: own sources
  /// send to their subscribers and tag their events with the port number;
  /// other outputs are addressed directly from the output port.
  ({int sourcePort, int destClient, int destPort, int tag, bool ump}) _targetOf(
    MidiPortId port,
  ) {
    final own = _own[port];
    final info = own?.info ?? _require(port);
    if (!info.isOutput) {
      throw ArgumentError.value(port, 'port', 'Not an output');
    }
    final ump = info.capabilities.ump;
    if (own != null) {
      return (
        sourcePort: own.port,
        destClient: SND_SEQ_ADDRESS_SUBSCRIBERS,
        destPort: SND_SEQ_ADDRESS_UNKNOWN,
        tag: own.port,
        ump: ump,
      );
    }
    final address = _addressOf(info);
    return (
      sourcePort: _requireSession().outPort,
      destClient: address.client,
      destPort: address.port,
      tag: 0,
      ump: ump,
    );
  }

  AlsaEventEncoder _encoderFor(MidiPortId port) => _encoders.putIfAbsent(
    port,
    () => AlsaEventEncoder(maxSysExChunk: maxSysExChunk),
  );

  /// Returns the queue time for a packet due at [due], or null when it is
  /// due now.
  int? _queueTimeOf(_AlsaSession session, MidiTime due) {
    if (!due.isAfter(session.host.clock.now())) return null;
    final queueTime = session.timeBase.toQueue(due);
    return queueTime < 0 ? null : queueTime;
  }

  void _diagnostic(
    MidiDiagnosticKind kind, {
    MidiPortId? port,
    int count = 1,
    required String cause,
  }) {
    final host = _session?.host;
    host?.diagnostic(
      MidiDiagnostic(
        kind: kind,
        port: port,
        count: count,
        cause: cause,
        time: host.clock.now(),
      ),
    );
  }
}

// #############################################################################
/// The native resources of a started [LinuxMidiBackend].
final class _AlsaSession {
  _AlsaSession({
    required this.host,
    required this.output,
    required this.input,
    required this.queue,
    required this.outPort,
    required this.inPort,
    required this.umpIn,
    required this.umpOut,
    required this.token,
    required this.reader,
    required this.timeBase,
  });

  final MidiBackendHost host;
  final AlsaSequencer output;
  final AlsaSequencer input;
  final int queue;
  final int outPort;
  final int inPort;
  final bool umpIn;
  final bool umpOut;
  final int token;
  final AlsaReader reader;
  final AlsaTimeBase timeBase;
  bool readerRunning = true;
}
