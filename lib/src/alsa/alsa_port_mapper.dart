// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:aud_midi_core/aud_midi_core.dart';
import 'package:aud_midi_standard/aud_midi_standard.dart';

import 'alsa_bindings.g.dart';
import 'alsa_client_info.dart';

// #############################################################################
/// Turns the clients and ports of the ALSA sequencer into the ports of the
/// aud_midi family.
///
/// A port that others can read from and subscribe to becomes an input, a
/// port that others can write to and subscribe to an output; a duplex port
/// becomes both. The system client, the own clients, ports that forbid
/// routing and ports that are no MIDI ports are left out. The client is the
/// device of its ports.
///
/// Ids are `alsa:<client>:<port>:in` and `alsa:<client>:<port>:out`. ALSA
/// reuses client and port numbers, e.g. when a USB device is plugged in
/// again; a number seen again after its client or port left gets a
/// generation suffix (`alsa:20#1:0:in`, `alsa:130:0#1:out`), so an id never
/// names two different ports within one session.
///
/// The `native` map carries the ALSA address and, for the device the
/// engine derives, the client name as device name and product and the kind
/// of client as driver ([MidiPortRegistry.deviceNameKey] and friends).
final class AlsaPortMapper {
  /// Creates a mapper for the backend [backend]; [isUsbCard] tells whether
  /// a sound card is a USB device.
  AlsaPortMapper({this.backend = 'alsa', bool Function(int card)? isUsbCard})
    : _isUsbCard = isUsbCard ?? usbCardFromProcfs;

  // ...........................................................................
  /// Returns the ports of [clients], leaving out [ownClients].
  ///
  /// - [umpIn] whether the own input client receives UMP words
  /// - [umpOut] whether the own output client sends UMP words
  /// - [generations] the generation of each reused client number
  /// - [portGenerations] the generation of each reused port address
  List<MidiPortInfo> map(
    List<AlsaClientInfo> clients, {
    required Set<int> ownClients,
    required bool umpIn,
    required bool umpOut,
    Map<int, int> generations = const {},
    Map<({int client, int port}), int> portGenerations = const {},
  }) => [
    for (final client in clients)
      if (client.client != SND_SEQ_CLIENT_SYSTEM &&
          !ownClients.contains(client.client))
        for (final port in client.ports)
          if (_isMidiPort(port))
            for (final direction in _directions(port))
              _portInfo(
                client,
                port,
                direction,
                ump: direction == MidiDirection.input ? umpIn : umpOut,
                generation: generations[client.client] ?? 0,
                portGeneration:
                    portGenerations[(client: client.client, port: port.port)] ??
                    0,
              ),
  ];

  // ...........................................................................
  /// The backend name, the prefix of every id.
  final String backend;

  // ...........................................................................
  /// Returns the id of the port [client]:[port] in [direction]; a client
  /// [generation] or [portGeneration] above zero is added as suffix.
  static MidiPortId portId({
    required String backend,
    required int client,
    required int port,
    required MidiDirection direction,
    int generation = 0,
    int portGeneration = 0,
  }) => MidiPortId.of(
    backend: backend,
    nativeId:
        '${_numbered(client, generation)}:${_numbered(port, portGeneration)}:'
        '${direction == MidiDirection.input ? 'in' : 'out'}',
  );

  /// Returns the id of the device of [client].
  static MidiDeviceId deviceId({
    required String backend,
    required int client,
    int generation = 0,
  }) => MidiDeviceId.of(
    backend: backend,
    nativeId: _numbered(client, generation),
  );

  /// Returns whether the sound card [card] is a USB device: the USB audio
  /// driver publishes `/proc/asound/card<n>/usbid`.
  static bool usbCardFromProcfs(int card) =>
      File('/proc/asound/card$card/usbid').existsSync();

  /// The capabilities of a port the app reads from.
  static const int readable =
      SND_SEQ_PORT_CAP_READ | SND_SEQ_PORT_CAP_SUBS_READ;

  /// The capabilities of a port the app writes to.
  static const int writable =
      SND_SEQ_PORT_CAP_WRITE | SND_SEQ_PORT_CAP_SUBS_WRITE;

  // ...........................................................................
  final bool Function(int card) _isUsbCard;

  /// The driver name of kernel clients, e.g. USB devices.
  static const String kernelDriver = 'ALSA kernel client';

  /// The driver name of user clients, i.e. applications.
  static const String userDriver = 'ALSA user client';

  static String _numbered(int number, int generation) =>
      generation == 0 ? '$number' : '$number#$generation';

  static const _midiTypes =
      SND_SEQ_PORT_TYPE_MIDI_GENERIC |
      SND_SEQ_PORT_TYPE_SYNTH |
      SND_SEQ_PORT_TYPE_APPLICATION;

  static bool _isMidiPort(AlsaPortInfo port) =>
      port.type & _midiTypes != 0 &&
      port.capability & SND_SEQ_PORT_CAP_NO_EXPORT == 0;

  static List<MidiDirection> _directions(AlsaPortInfo port) => [
    if (port.capability & readable == readable) MidiDirection.input,
    if (port.capability & writable == writable) MidiDirection.output,
  ];

  MidiPortInfo _portInfo(
    AlsaClientInfo client,
    AlsaPortInfo port,
    MidiDirection direction, {
    required bool ump,
    required int generation,
    required int portGeneration,
  }) {
    final group = port.umpGroup > 0 ? port.umpGroup - 1 : null;
    final isEndpoint = port.capability & SND_SEQ_PORT_CAP_UMP_ENDPOINT != 0;
    final blocks = [
      for (final block in client.blocks)
        if (isEndpoint || group != null && _covers(block, group)) block,
    ];
    return MidiPortInfo(
      id: portId(
        backend: backend,
        client: client.client,
        port: port.port,
        direction: direction,
        generation: generation,
        portGeneration: portGeneration,
      ),
      deviceId: deviceId(
        backend: backend,
        client: client.client,
        generation: generation,
      ),
      name: port.name.startsWith(client.name)
          ? port.name
          : '${client.name}: ${port.name}',
      direction: direction,
      index: port.port,
      transport: _transport(client, port),
      protocol: _protocol(client, port),
      state: port.capability & SND_SEQ_PORT_CAP_INACTIVE != 0
          ? MidiPortState.offline
          : MidiPortState.connected,
      isVirtual: client.type == snd_seq_client_type.SND_SEQ_USER_CLIENT,
      group: group ?? 0,
      groups: _groups(blocks, group),
      functionBlocks: [for (final block in blocks) _functionBlock(block)],
      endpoint: client.endpoint == null ? null : _endpoint(client.endpoint!),
      capabilities: MidiPortCapabilities(
        timestampsIn: direction == MidiDirection.input,
        scheduledSend: direction == MidiDirection.output,
        cancelPending: direction == MidiDirection.output,
        ump: ump,
        sysEx8: ump && client.midiVersion != SND_SEQ_CLIENT_LEGACY_MIDI,
      ),
      native: {
        'client': client.client,
        'port': port.port,
        'clientName': client.name,
        'portName': port.name,
        'clientType': client.type,
        'card': client.card,
        'capability': port.capability,
        'type': port.type,
        MidiPortRegistry.deviceNameKey: client.name,
        MidiPortRegistry.productKey: client.name,
        MidiPortRegistry.driverKey:
            client.type == snd_seq_client_type.SND_SEQ_KERNEL_CLIENT
            ? kernelDriver
            : userDriver,
      },
    );
  }

  MidiTransport _transport(AlsaClientInfo client, AlsaPortInfo port) {
    final isKernel = client.type == snd_seq_client_type.SND_SEQ_KERNEL_CLIENT;
    if (port.type & SND_SEQ_PORT_TYPE_HARDWARE != 0 ||
        isKernel && client.card >= 0) {
      return client.card >= 0 && _isUsbCard(client.card)
          ? MidiTransport.usb
          : MidiTransport.unknown;
    }
    return MidiTransport.software;
  }

  static MidiProtocol _protocol(AlsaClientInfo client, AlsaPortInfo port) {
    if (port.umpIsMidi1) return MidiProtocol.midi1;
    final endpoint = client.endpoint;
    final isMidi2 = endpoint == null
        ? client.midiVersion == SND_SEQ_CLIENT_UMP_MIDI_2_0
        : endpoint.protocol & SND_UMP_EP_INFO_PROTO_MIDI2 != 0;
    return isMidi2 ? MidiProtocol.midi2 : MidiProtocol.midi1;
  }

  static bool _covers(AlsaUmpBlockInfo block, int group) =>
      group >= block.firstGroup && group < block.firstGroup + block.groupCount;

  static List<MidiGroupInfo> _groups(List<AlsaUmpBlockInfo> blocks, int? only) {
    final groups = <int, MidiGroupInfo>{};
    for (final block in blocks) {
      for (
        var g = block.firstGroup;
        g < block.firstGroup + block.groupCount;
        g++
      ) {
        if (g > 15 || only != null && g != only) continue;
        groups.putIfAbsent(
          g,
          () =>
              MidiGroupInfo(group: g, name: block.name, isActive: block.active),
        );
      }
    }
    return [for (final g in groups.keys.toList()..sort()) groups[g]!];
  }

  static MidiFunctionBlockInfo _functionBlock(AlsaUmpBlockInfo block) =>
      MidiFunctionBlockInfo(
        number: block.blockId,
        name: block.name,
        isActive: block.active,
        direction: MidiFunctionBlockDirection.fromValue(block.direction),
        firstGroup: block.firstGroup.clamp(0, 15),
        groupCount: block.groupCount.clamp(0, 16),
        midi1: block.flags & SND_UMP_BLOCK_IS_MIDI1 == 0
            ? MidiFunctionBlockMidi1.notMidi1
            : block.flags & SND_UMP_BLOCK_IS_LOWSPEED == 0
            ? MidiFunctionBlockMidi1.unrestricted
            : MidiFunctionBlockMidi1.restricted31250,
        uiHint: MidiFunctionBlockUiHint.fromValue(block.uiHint),
        midiCiVersion: block.midiCiVersion,
        maxSysEx8Streams: block.sysEx8Streams,
      );

  static MidiEndpointInfo _endpoint(AlsaUmpEndpointInfo info) {
    final hasIdentity =
        info.manufacturerId != 0 || info.familyId != 0 || info.modelId != 0;
    return MidiEndpointInfo(
      name: info.name,
      productInstanceId: info.productId,
      identity: hasIdentity
          ? MidiDeviceIdentity(
              manufacturerId: [
                (info.manufacturerId >> 16) & 0x7F,
                (info.manufacturerId >> 8) & 0x7F,
                info.manufacturerId & 0x7F,
              ],
              familyId: info.familyId,
              modelId: info.modelId,
              softwareRevision: info.softwareRevision,
            )
          : null,
      umpVersionMajor: info.version >> 8,
      umpVersionMinor: info.version & 0xFF,
      supportsMidi1: info.protocolCaps & SND_UMP_EP_INFO_PROTO_MIDI1 != 0,
      supportsMidi2: info.protocolCaps & SND_UMP_EP_INFO_PROTO_MIDI2 != 0,
      supportsRxJr: info.protocolCaps & SND_UMP_EP_INFO_PROTO_JRTS_RX != 0,
      supportsTxJr: info.protocolCaps & SND_UMP_EP_INFO_PROTO_JRTS_TX != 0,
      staticFunctionBlocks: info.flags & SND_UMP_EP_INFO_STATIC_BLOCKS != 0,
      functionBlockCount: info.blockCount,
      protocol: info.protocol & SND_UMP_EP_INFO_PROTO_MIDI2 != 0
          ? MidiProtocol.midi2
          : MidiProtocol.midi1,
      receiveJr: info.protocol & SND_UMP_EP_INFO_PROTO_JRTS_RX != 0,
      transmitJr: info.protocol & SND_UMP_EP_INFO_PROTO_JRTS_TX != 0,
    );
  }
}
