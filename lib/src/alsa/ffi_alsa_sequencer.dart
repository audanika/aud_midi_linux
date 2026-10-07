// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// coverage:ignore-file
// Linux only: every line calls alsa-lib through FFI. The Linux tests in
// test/alsa/ffi_alsa_sequencer_test.dart exercise it on a real sequencer.

import 'dart:ffi';
import 'dart:math';

import 'package:ffi/ffi.dart';

import 'alsa_bindings.g.dart';
import 'alsa_client_info.dart';
import 'alsa_errors.dart';
import 'alsa_event.dart';
import 'alsa_event_layout.dart';
import 'alsa_event_source.dart';
import 'alsa_library.dart';
import 'alsa_sequencer.dart';

// #############################################################################
/// An [AlsaSequencer] on a `snd_seq_t` handle of alsa-lib; it is also the
/// [AlsaEventSource] the reader isolate reads from.
final class FfiAlsaSequencer implements AlsaSequencer, AlsaEventSource {
  /// Opens a handle of [library]: for [input] a blocking one that only
  /// reads, otherwise a non-blocking one that only writes.
  ///
  /// Throws the exception of [AlsaErrors.exception] when opening fails.
  factory FfiAlsaSequencer.open(AlsaLibrary library, {required bool input}) {
    final handle = calloc<Pointer<snd_seq_t>>();
    final name = 'default'.toNativeUtf8(allocator: calloc);
    try {
      final result = library.bindings.snd_seq_open(
        handle,
        name.cast(),
        input ? SND_SEQ_OPEN_INPUT : SND_SEQ_OPEN_OUTPUT,
        input ? 0 : SND_SEQ_NONBLOCK,
      );
      if (result < 0) {
        throw AlsaErrors.exception(api: AlsaErrors.openApi, code: result);
      }
      return FfiAlsaSequencer._(library, handle.value);
    } finally {
      calloc
        ..free(name)
        ..free(handle);
    }
  }

  /// Uses the handle at [address] that another isolate of this process
  /// opened, e.g. in the reader isolate.
  FfiAlsaSequencer.attach(AlsaLibrary library, int address)
    : this._(library, Pointer.fromAddress(address));

  FfiAlsaSequencer._(this._library, this._seq);

  // ...........................................................................
  @override
  void setClientName(String name) {
    final text = name.toNativeUtf8(allocator: calloc);
    try {
      _check(
        'snd_seq_set_client_name',
        _b.snd_seq_set_client_name(_seq, text.cast()),
      );
    } finally {
      calloc.free(text);
    }
  }

  @override
  bool enableUmp() {
    if (!_library.provides('snd_seq_set_client_midi_version')) return false;
    final result = _b.snd_seq_set_client_midi_version(
      _seq,
      SND_SEQ_CLIENT_UMP_MIDI_2_0,
    );
    if (result < 0) return false;
    _isUmp = true;
    return true;
  }

  @override
  void setPools({int? input, int? output}) {
    if (input != null) _b.snd_seq_set_client_pool_input(_seq, input);
    if (output != null) _b.snd_seq_set_client_pool_output(_seq, output);
  }

  // ...........................................................................
  @override
  int createPort({
    required String name,
    required int capability,
    required int type,
    int? timestampQueue,
  }) {
    final info = _allocate<snd_seq_port_info_t>(_b.snd_seq_port_info_malloc);
    final text = name.toNativeUtf8(allocator: calloc);
    try {
      _b
        ..snd_seq_port_info_set_name(info, text.cast())
        ..snd_seq_port_info_set_capability(info, capability)
        ..snd_seq_port_info_set_type(info, type)
        ..snd_seq_port_info_set_midi_channels(info, 16);
      if (timestampQueue != null) {
        _b
          ..snd_seq_port_info_set_timestamping(info, 1)
          ..snd_seq_port_info_set_timestamp_real(info, 1)
          ..snd_seq_port_info_set_timestamp_queue(info, timestampQueue);
      }
      _check('snd_seq_create_port', _b.snd_seq_create_port(_seq, info));
      return _b.snd_seq_port_info_get_port(info);
    } finally {
      calloc.free(text);
      _b.snd_seq_port_info_free(info);
    }
  }

  @override
  void deletePort(int port) =>
      _check('snd_seq_delete_port', _b.snd_seq_delete_port(_seq, port));

  @override
  void connectFrom({
    required int port,
    required int client,
    required int sourcePort,
  }) => _check(
    'snd_seq_connect_from',
    _b.snd_seq_connect_from(_seq, port, client, sourcePort),
  );

  @override
  void disconnectFrom({
    required int port,
    required int client,
    required int sourcePort,
  }) => _check(
    'snd_seq_disconnect_from',
    _b.snd_seq_disconnect_from(_seq, port, client, sourcePort),
  );

  @override
  List<AlsaClientInfo> clients() {
    final client = _allocate<snd_seq_client_info_t>(
      _b.snd_seq_client_info_malloc,
    );
    final port = _allocate<snd_seq_port_info_t>(_b.snd_seq_port_info_malloc);
    try {
      _b.snd_seq_client_info_set_client(client, -1);
      final result = <AlsaClientInfo>[];
      while (_b.snd_seq_query_next_client(_seq, client) >= 0) {
        result.add(_clientInfo(client, port));
      }
      return result;
    } finally {
      _b
        ..snd_seq_client_info_free(client)
        ..snd_seq_port_info_free(port);
    }
  }

  // ...........................................................................
  @override
  int startQueue(String name) {
    final text = name.toNativeUtf8(allocator: calloc);
    final int queue;
    try {
      queue = _b.snd_seq_alloc_named_queue(_seq, text.cast());
    } finally {
      calloc.free(text);
    }
    _check('snd_seq_alloc_named_queue', queue);
    _check(
      'snd_seq_control_queue',
      _b.snd_seq_control_queue(
        _seq,
        queue,
        snd_seq_event_type.SND_SEQ_EVENT_START,
        0,
        nullptr,
      ),
    );
    _check('snd_seq_drain_output', _b.snd_seq_drain_output(_seq));
    return queue;
  }

  @override
  int queueTime(int queue) {
    final status = _queueStatus ??= _allocate<snd_seq_queue_status_t>(
      _b.snd_seq_queue_status_malloc,
    );
    _check(
      'snd_seq_get_queue_status',
      _b.snd_seq_get_queue_status(_seq, queue, status),
    );
    final time = _b.snd_seq_queue_status_get_real_time(status).ref;
    return time.tv_sec * Duration.microsecondsPerSecond + time.tv_nsec ~/ 1000;
  }

  @override
  void freeQueue(int queue) =>
      _check('snd_seq_free_queue', _b.snd_seq_free_queue(_seq, queue));

  // ...........................................................................
  @override
  void output(AlsaEvent event) {
    final cell = _cell ??= calloc<Uint8>(AlsaEventLayout.umpSize);
    cell.asTypedList(event.cell.length).setAll(0, event.cell);
    final data = event.ext;
    var ext = nullptr.cast<Uint8>();
    if (data != null) {
      ext = malloc<Uint8>(max(data.length, 1));
      ext.asTypedList(data.length).setAll(0, data);
      cell.cast<snd_seq_event>().ref.data.ext.ptr = ext.cast();
    }
    try {
      if (event.isUmp) {
        _check(
          'snd_seq_ump_event_output_direct',
          _b.snd_seq_ump_event_output_direct(_seq, cell.cast()),
        );
      } else {
        _check(
          'snd_seq_event_output_direct',
          _b.snd_seq_event_output_direct(_seq, cell.cast()),
        );
      }
    } finally {
      if (ext != nullptr) malloc.free(ext);
    }
  }

  @override
  void removeEvents({
    required int queue,
    required int destClient,
    required int destPort,
    int? tag,
  }) {
    final info = _allocate<snd_seq_remove_events_t>(
      _b.snd_seq_remove_events_malloc,
    );
    final address = calloc<snd_seq_addr>()
      ..ref.client = destClient
      ..ref.port = destPort;
    try {
      var condition = SND_SEQ_REMOVE_OUTPUT | SND_SEQ_REMOVE_DEST;
      if (tag != null) {
        condition |= SND_SEQ_REMOVE_TAG_MATCH;
        _b.snd_seq_remove_events_set_tag(info, tag);
      }
      _b
        ..snd_seq_remove_events_set_condition(info, condition)
        ..snd_seq_remove_events_set_queue(info, queue)
        ..snd_seq_remove_events_set_dest(info, address);
      _check('snd_seq_remove_events', _b.snd_seq_remove_events(_seq, info));
    } finally {
      calloc.free(address);
      _b.snd_seq_remove_events_free(info);
    }
  }

  // ...........................................................................
  @override
  AlsaReadResult read() {
    final out = _input ??= calloc<Pointer<snd_seq_event>>();
    final result = _b.snd_seq_event_input(_seq, out);
    if (result < 0) return (event: null, error: result);
    final event = out.value;
    final flags = event.ref.flags;
    final isUmp = flags & SND_SEQ_EVENT_UMP != 0;
    final cell = event.cast<Uint8>().asTypedList(
      isUmp ? AlsaEventLayout.umpSize : AlsaEventLayout.legacySize,
    );
    final isVariable =
        flags & SND_SEQ_EVENT_LENGTH_MASK == SND_SEQ_EVENT_LENGTH_VARIABLE;
    final ext = !isUmp && isVariable
        ? event.ref.data.ext.ptr.cast<Uint8>().asTypedList(
            event.ref.data.ext.len,
          )
        : null;
    return (event: AlsaEvent(cell: cell, ext: ext), error: 0);
  }

  @override
  int pending() => _b.snd_seq_event_input_pending(_seq, 0);

  // ...........................................................................
  /// Frees the buffers of this object without closing the handle, e.g.
  /// when the reader isolate ends.
  void detach() {
    final input = _input;
    final cell = _cell;
    final status = _queueStatus;
    if (input != null) calloc.free(input);
    if (cell != null) calloc.free(cell);
    if (status != null) _b.snd_seq_queue_status_free(status);
    _input = null;
    _cell = null;
    _queueStatus = null;
  }

  @override
  void close() {
    detach();
    _check('snd_seq_close', _b.snd_seq_close(_seq));
  }

  // ...........................................................................
  @override
  late final int clientId = _b.snd_seq_client_id(_seq);

  /// The address of the handle, to attach another isolate.
  int get address => _seq.address;

  /// Whether the client switched to UMP.
  bool get isUmp => _isUmp;

  // ...........................................................................
  final AlsaLibrary _library;
  final Pointer<snd_seq_t> _seq;
  bool _isUmp = false;
  Pointer<Pointer<snd_seq_event>>? _input;
  Pointer<Uint8>? _cell;
  Pointer<snd_seq_queue_status_t>? _queueStatus;

  AlsaBindings get _b => _library.bindings;

  late final bool _hasMidiVersion = _library.provides(
    'snd_seq_client_info_get_midi_version',
  );
  late final bool _hasUmpPorts = _library.provides(
    'snd_seq_port_info_get_ump_group',
  );
  late final bool _hasUmpInfo = _library.provides(
    'snd_seq_get_ump_endpoint_info',
  );

  static void _check(String api, int result) {
    if (result < 0) throw AlsaErrors.exception(api: api, code: result);
  }

  /// Allocates an alsa-lib container with its `*_malloc` function.
  static Pointer<T> _allocate<T extends NativeType>(
    int Function(Pointer<Pointer<T>>) allocate,
  ) {
    final slot = calloc<IntPtr>();
    try {
      final result = allocate(slot.cast());
      if (result < 0) {
        throw AlsaErrors.exception(api: 'malloc', code: result);
      }
      return Pointer<T>.fromAddress(slot.value);
    } finally {
      calloc.free(slot);
    }
  }

  static String _string(Pointer<Char> text) =>
      text == nullptr ? '' : text.cast<Utf8>().toDartString();

  AlsaClientInfo _clientInfo(
    Pointer<snd_seq_client_info_t> client,
    Pointer<snd_seq_port_info_t> port,
  ) {
    final number = _b.snd_seq_client_info_get_client(client);
    final midiVersion = _hasMidiVersion
        ? _b.snd_seq_client_info_get_midi_version(client)
        : SND_SEQ_CLIENT_LEGACY_MIDI;
    final endpoint = midiVersion != SND_SEQ_CLIENT_LEGACY_MIDI && _hasUmpInfo
        ? _endpoint(number)
        : null;
    return AlsaClientInfo(
      client: number,
      name: _string(_b.snd_seq_client_info_get_name(client)),
      type: _b.snd_seq_client_info_get_type(client),
      card: _b.snd_seq_client_info_get_card(client),
      pid: _b.snd_seq_client_info_get_pid(client),
      midiVersion: midiVersion,
      ports: _ports(number, port),
      endpoint: endpoint,
      blocks: endpoint == null
          ? const []
          : _blocks(number, endpoint.blockCount),
    );
  }

  List<AlsaPortInfo> _ports(int client, Pointer<snd_seq_port_info_t> info) {
    _b
      ..snd_seq_port_info_set_client(info, client)
      ..snd_seq_port_info_set_port(info, -1);
    final ports = <AlsaPortInfo>[];
    while (_b.snd_seq_query_next_port(_seq, info) >= 0) {
      ports.add(
        AlsaPortInfo(
          client: client,
          port: _b.snd_seq_port_info_get_port(info),
          name: _string(_b.snd_seq_port_info_get_name(info)),
          capability: _b.snd_seq_port_info_get_capability(info),
          type: _b.snd_seq_port_info_get_type(info),
          direction: _hasUmpPorts
              ? _b.snd_seq_port_info_get_direction(info)
              : SND_SEQ_PORT_DIR_UNKNOWN,
          umpGroup: _hasUmpPorts ? _b.snd_seq_port_info_get_ump_group(info) : 0,
          umpIsMidi1:
              _hasUmpPorts && _b.snd_seq_port_info_get_ump_is_midi1(info) != 0,
        ),
      );
    }
    return ports;
  }

  AlsaUmpEndpointInfo? _endpoint(int client) {
    final info = _allocate<snd_ump_endpoint_info>(
      _b.snd_ump_endpoint_info_malloc,
    );
    try {
      if (_b.snd_seq_get_ump_endpoint_info(_seq, client, info.cast()) < 0) {
        return null;
      }
      final revision = _b.snd_ump_endpoint_info_get_sw_revision(info);
      return AlsaUmpEndpointInfo(
        name: _string(_b.snd_ump_endpoint_info_get_name(info)),
        productId: _string(_b.snd_ump_endpoint_info_get_product_id(info)),
        flags: _b.snd_ump_endpoint_info_get_flags(info),
        protocolCaps: _b.snd_ump_endpoint_info_get_protocol_caps(info),
        protocol: _b.snd_ump_endpoint_info_get_protocol(info),
        blockCount: _b.snd_ump_endpoint_info_get_num_blocks(info),
        version: _b.snd_ump_endpoint_info_get_version(info),
        manufacturerId: _b.snd_ump_endpoint_info_get_manufacturer_id(info),
        familyId: _b.snd_ump_endpoint_info_get_family_id(info),
        modelId: _b.snd_ump_endpoint_info_get_model_id(info),
        softwareRevision: revision == nullptr
            ? const [0, 0, 0, 0]
            : [for (var i = 0; i < 4; i++) revision[i]],
      );
    } finally {
      _b.snd_ump_endpoint_info_free(info);
    }
  }

  List<AlsaUmpBlockInfo> _blocks(int client, int count) {
    final info = _allocate<snd_ump_block_info>(_b.snd_ump_block_info_malloc);
    try {
      return [
        for (var block = 0; block < count; block++)
          if (_b.snd_seq_get_ump_block_info(_seq, client, block, info.cast()) >=
              0)
            AlsaUmpBlockInfo(
              blockId: _b.snd_ump_block_info_get_block_id(info),
              name: _string(_b.snd_ump_block_info_get_name(info)),
              active: _b.snd_ump_block_info_get_active(info) != 0,
              flags: _b.snd_ump_block_info_get_flags(info),
              direction: _b.snd_ump_block_info_get_direction(info),
              firstGroup: _b.snd_ump_block_info_get_first_group(info),
              groupCount: _b.snd_ump_block_info_get_num_groups(info),
              midiCiVersion: _b.snd_ump_block_info_get_midi_ci_version(info),
              sysEx8Streams: _b.snd_ump_block_info_get_sysex8_streams(info),
              uiHint: _b.snd_ump_block_info_get_ui_hint(info),
            ),
      ];
    } finally {
      _b.snd_ump_block_info_free(info);
    }
  }
}
