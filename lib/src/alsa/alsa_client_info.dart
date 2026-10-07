// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// #############################################################################
/// A sequencer client as the native layer enumerates it, with its ports
/// and, for UMP clients, the UMP endpoint and function blocks.
final class AlsaClientInfo {
  /// Creates the description of the client [client].
  const AlsaClientInfo({
    required this.client,
    required this.name,
    required this.type,
    this.card = -1,
    this.pid = -1,
    this.midiVersion = 0,
    this.ports = const [],
    this.endpoint,
    this.blocks = const [],
  });

  // ...........................................................................
  /// The client number, 0 to 255.
  final int client;

  /// The client name.
  final String name;

  /// `SND_SEQ_USER_CLIENT` or `SND_SEQ_KERNEL_CLIENT`.
  final int type;

  /// The sound card of a kernel client, or -1.
  final int card;

  /// The process of a user client, or -1.
  final int pid;

  /// `SND_SEQ_CLIENT_LEGACY_MIDI` or one of the UMP versions.
  final int midiVersion;

  /// The ports of the client.
  final List<AlsaPortInfo> ports;

  /// The UMP endpoint of a UMP client, or null.
  final AlsaUmpEndpointInfo? endpoint;

  /// The UMP function blocks of a UMP client.
  final List<AlsaUmpBlockInfo> blocks;
}

// #############################################################################
/// A sequencer port as the native layer enumerates it.
final class AlsaPortInfo {
  /// Creates the description of the port [client]:[port].
  const AlsaPortInfo({
    required this.client,
    required this.port,
    required this.name,
    required this.capability,
    required this.type,
    this.direction = 0,
    this.umpGroup = 0,
    this.umpIsMidi1 = false,
  });

  // ...........................................................................
  /// The client number.
  final int client;

  /// The port number, 0 to 253.
  final int port;

  /// The port name.
  final String name;

  /// The `SND_SEQ_PORT_CAP_*` bits.
  final int capability;

  /// The `SND_SEQ_PORT_TYPE_*` bits.
  final int type;

  /// The `SND_SEQ_PORT_DIR_*` value; 0 when unknown.
  final int direction;

  /// The UMP group 1 to 16 of a group port, or 0.
  final int umpGroup;

  /// Whether the UMP group port speaks MIDI 1.0 only.
  final bool umpIsMidi1;
}

// #############################################################################
/// The UMP endpoint information of a UMP client.
final class AlsaUmpEndpointInfo {
  /// Creates the endpoint information.
  const AlsaUmpEndpointInfo({
    required this.name,
    this.productId = '',
    this.flags = 0,
    this.protocolCaps = 0,
    this.protocol = 0,
    this.blockCount = 0,
    this.version = 0,
    this.manufacturerId = 0,
    this.familyId = 0,
    this.modelId = 0,
    this.softwareRevision = const [0, 0, 0, 0],
  });

  // ...........................................................................
  /// The endpoint name.
  final String name;

  /// The product instance id.
  final String productId;

  /// The `SND_UMP_EP_INFO_*` flags, e.g. static blocks.
  final int flags;

  /// The supported protocols and JR timestamp directions.
  final int protocolCaps;

  /// The current protocol and JR timestamp directions.
  final int protocol;

  /// The number of function blocks.
  final int blockCount;

  /// The UMP version, major in the high byte.
  final int version;

  /// The SysEx manufacturer id, three 7-bit bytes from high to low.
  final int manufacturerId;

  /// The device family id.
  final int familyId;

  /// The device model id.
  final int modelId;

  /// The four bytes of the software revision.
  final List<int> softwareRevision;
}

// #############################################################################
/// A UMP function block of a UMP client.
final class AlsaUmpBlockInfo {
  /// Creates the information of the block [blockId].
  const AlsaUmpBlockInfo({
    required this.blockId,
    required this.name,
    this.active = true,
    this.flags = 0,
    this.direction = 0,
    this.firstGroup = 0,
    this.groupCount = 1,
    this.midiCiVersion = 0,
    this.sysEx8Streams = 0,
    this.uiHint = 0,
  });

  // ...........................................................................
  /// The block number.
  final int blockId;

  /// The block name.
  final String name;

  /// Whether the block is active.
  final bool active;

  /// The `SND_UMP_BLOCK_IS_*` flags.
  final int flags;

  /// The `SND_UMP_DIR_*` direction.
  final int direction;

  /// The first group 0 to 15.
  final int firstGroup;

  /// The number of groups.
  final int groupCount;

  /// The MIDI-CI version.
  final int midiCiVersion;

  /// The maximum number of SysEx8 streams.
  final int sysEx8Streams;

  /// The `SND_UMP_BLOCK_UI_HINT_*` value.
  final int uiHint;
}
