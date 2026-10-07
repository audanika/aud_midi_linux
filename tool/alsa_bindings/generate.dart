// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

/// Generates `lib/src/alsa/alsa_bindings.g.dart` with ffigen from the
/// headers of an alsa-lib release.
///
/// ```bash
/// dart run tool/alsa_bindings/generate.dart [--alsa-lib <checkout>]
/// ```
///
/// Without `--alsa-lib` the script clones [alsaLibTag] of [alsaLibRepository]
/// into a temporary folder (needs `git` and network). The headers are parsed
/// for a Linux x86_64 target against the stub system headers in `stubs/`,
/// so the result does not depend on the host: both Linux targets of the
/// package (x86_64 and aarch64) are LP64 with the same layouts, and the
/// generated code uses ABI-specific FFI types such as `Long` and `Size`.
library;

import 'dart:io';

import 'package:ffigen/ffigen.dart';

// #############################################################################
/// The alsa-lib release the bindings are generated from.
const alsaLibTag = 'v1.2.16.1';

/// The alsa-lib repository.
const alsaLibRepository = 'https://github.com/alsa-project/alsa-lib.git';

// #############################################################################
/// Generates the bindings, see the library documentation.
Future<void> main(List<String> args) async {
  final toolDir = Platform.script.resolve('./');
  final packageRoot = Platform.script.resolve('../../');
  final temp = Directory.systemTemp.createTempSync('aud_midi_alsa_');
  try {
    final checkout = _alsaLibCheckout(args, temp);
    final includeRoot = Directory('${temp.path}/include')..createSync();
    Link('${includeRoot.path}/alsa').createSync('${checkout.path}/include');
    await FfiGenerator(
      input: Input(
        entryPoints: [toolDir.resolve('alsa_seq.h')],
        compilerOptions: [
          '--target=x86_64-unknown-linux-gnu',
          '-nostdlibinc',
          '-DPIC',
          '-I${toolDir.resolve('stubs').toFilePath()}',
          '-I${includeRoot.path}',
        ],
      ),
      output: Output(
        dart: DartOutput(
          path: packageRoot.resolve('lib/src/alsa/alsa_bindings.g.dart'),
        ),
        preamble: _preamble,
        style: const DynamicLibraryBindings(
          wrapperName: 'AlsaBindings',
          wrapperDocComment:
              'The sequencer API of libasound (alsa-lib $alsaLibTag).',
        ),
      ),
      visitors: [
        Visitor(
          func: (node) =>
              node.isIncluded = _functions.contains(node.originalName),
          struct: (node) {
            node.isIncluded = _structs.contains(node.originalName);
            // Opaque handles: struct _snd_seq → typedef name snd_seq_t.
            if (node.originalName.startsWith('_snd_')) {
              node.name = '${node.originalName.substring(1)}_t';
            }
          },
          union: (node) {
            final members = node.members.map((m) => m.originalName).toSet();
            if (members.contains('ump')) node.name = 'snd_seq_ump_event_data';
            if (members.contains('skew')) {
              node.name = 'snd_seq_ev_queue_control_param';
            }
          },
          field: (node) {
            // The anonymous union of snd_seq_ump_event (data or ump words).
            const named = {
              'type',
              'flags',
              'tag',
              'queue',
              'time',
              'source',
              'dest',
            };
            if (node.parent.originalName == 'snd_seq_ump_event' &&
                !named.contains(node.originalName)) {
              node.name = 'payload';
            }
          },
          enumClass: (node) {
            node.isIncluded = _enums.contains(node.originalName);
            node.style = EnumStyle.intConstants;
            if (node.originalName.startsWith('_')) {
              node.name = node.originalName.substring(1);
            }
            // snd_seq_client_type is a return type; GCC and Clang store it
            // as unsigned int on Linux (non-negative values only), which is
            // what ffigen emits.
            node.silenceWarning = true;
          },
          unnamedEnumConstant: (node) =>
              node.isIncluded = _isConstant(node.originalName),
          macroConstant: (node) =>
              node.isIncluded = _isConstant(node.originalName),
        ),
      ],
    ).generate();
  } finally {
    temp.deleteSync(recursive: true);
  }
}

// .............................................................................
Directory _alsaLibCheckout(List<String> args, Directory temp) {
  final index = args.indexOf('--alsa-lib');
  if (index >= 0 && index + 1 < args.length) {
    return Directory(args[index + 1]);
  }
  final checkout = Directory('${temp.path}/alsa-lib');
  final result = Process.runSync('git', [
    'clone',
    '--depth',
    '1',
    '--branch',
    alsaLibTag,
    alsaLibRepository,
    checkout.path,
  ]);
  if (result.exitCode != 0) {
    throw StateError('git clone failed: ${result.stderr}');
  }
  return checkout;
}

bool _isConstant(String name) =>
    name.startsWith('SND_SEQ_') ||
    name.startsWith('SND_UMP_') ||
    name.startsWith('SND_LIB_');

const _preamble = '''
// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// GENERATED by tool/alsa_bindings/generate.dart from the alsa-lib headers
// (LGPL-2.1+ declarations, linked dynamically) - DO NOT EDIT.
// coverage:ignore-file
''';

const _structs = {
  'snd_seq_event',
  'snd_seq_ump_event',
  'snd_seq_addr',
  'snd_seq_connect',
  'snd_seq_real_time',
  'snd_seq_ev_note',
  'snd_seq_ev_ctrl',
  'snd_seq_ev_raw8',
  'snd_seq_ev_raw32',
  'snd_seq_ev_ext',
  'snd_seq_result',
  'snd_seq_queue_skew',
  'snd_seq_ev_queue_control',
  'snd_seq_ev_ump_notify',
  'pollfd',
};

const _enums = {
  'snd_seq_event_type',
  'snd_seq_client_type',
  '_snd_ump_direction',
  '_snd_ump_block_ui_hint',
};

const _functions = {
  // Handle.
  'snd_seq_open',
  'snd_seq_close',
  'snd_seq_name',
  'snd_seq_client_id',
  'snd_seq_nonblock',
  'snd_seq_poll_descriptors_count',
  'snd_seq_poll_descriptors',
  'snd_seq_poll_descriptors_revents',
  'snd_seq_get_output_buffer_size',
  'snd_seq_get_input_buffer_size',
  'snd_seq_set_output_buffer_size',
  'snd_seq_set_input_buffer_size',
  // Clients.
  'snd_seq_client_info_sizeof',
  'snd_seq_client_info_malloc',
  'snd_seq_client_info_free',
  'snd_seq_client_info_get_client',
  'snd_seq_client_info_get_type',
  'snd_seq_client_info_get_name',
  'snd_seq_client_info_get_card',
  'snd_seq_client_info_get_pid',
  'snd_seq_client_info_get_num_ports',
  'snd_seq_client_info_get_event_lost',
  'snd_seq_client_info_get_midi_version',
  'snd_seq_client_info_get_ump_conversion',
  'snd_seq_client_info_set_client',
  'snd_seq_client_info_set_name',
  'snd_seq_client_info_set_midi_version',
  'snd_seq_get_client_info',
  'snd_seq_get_any_client_info',
  'snd_seq_set_client_info',
  'snd_seq_query_next_client',
  'snd_seq_get_ump_endpoint_info',
  'snd_seq_get_ump_block_info',
  // Ports.
  'snd_seq_port_info_sizeof',
  'snd_seq_port_info_malloc',
  'snd_seq_port_info_free',
  'snd_seq_port_info_get_client',
  'snd_seq_port_info_get_port',
  'snd_seq_port_info_get_addr',
  'snd_seq_port_info_get_name',
  'snd_seq_port_info_get_capability',
  'snd_seq_port_info_get_type',
  'snd_seq_port_info_get_midi_channels',
  'snd_seq_port_info_get_read_use',
  'snd_seq_port_info_get_write_use',
  'snd_seq_port_info_get_timestamping',
  'snd_seq_port_info_get_timestamp_real',
  'snd_seq_port_info_get_timestamp_queue',
  'snd_seq_port_info_get_direction',
  'snd_seq_port_info_get_ump_group',
  'snd_seq_port_info_get_ump_is_midi1',
  'snd_seq_port_info_set_client',
  'snd_seq_port_info_set_port',
  'snd_seq_port_info_set_name',
  'snd_seq_port_info_set_capability',
  'snd_seq_port_info_set_type',
  'snd_seq_port_info_set_midi_channels',
  'snd_seq_port_info_set_port_specified',
  'snd_seq_port_info_set_timestamping',
  'snd_seq_port_info_set_timestamp_real',
  'snd_seq_port_info_set_timestamp_queue',
  'snd_seq_port_info_set_direction',
  'snd_seq_port_info_set_ump_group',
  'snd_seq_create_port',
  'snd_seq_delete_port',
  'snd_seq_get_port_info',
  'snd_seq_get_any_port_info',
  'snd_seq_set_port_info',
  'snd_seq_query_next_port',
  // Subscriptions.
  'snd_seq_port_subscribe_malloc',
  'snd_seq_port_subscribe_free',
  'snd_seq_port_subscribe_set_sender',
  'snd_seq_port_subscribe_set_dest',
  'snd_seq_port_subscribe_set_queue',
  'snd_seq_port_subscribe_set_exclusive',
  'snd_seq_port_subscribe_set_time_update',
  'snd_seq_port_subscribe_set_time_real',
  'snd_seq_subscribe_port',
  'snd_seq_unsubscribe_port',
  // Queues.
  'snd_seq_alloc_queue',
  'snd_seq_alloc_named_queue',
  'snd_seq_free_queue',
  'snd_seq_queue_status_malloc',
  'snd_seq_queue_status_free',
  'snd_seq_queue_status_get_queue',
  'snd_seq_queue_status_get_events',
  'snd_seq_queue_status_get_tick_time',
  'snd_seq_queue_status_get_real_time',
  'snd_seq_queue_status_get_status',
  'snd_seq_get_queue_status',
  'snd_seq_queue_tempo_malloc',
  'snd_seq_queue_tempo_free',
  'snd_seq_queue_tempo_get_tempo',
  'snd_seq_queue_tempo_get_ppq',
  'snd_seq_queue_tempo_set_tempo',
  'snd_seq_queue_tempo_set_ppq',
  'snd_seq_get_queue_tempo',
  'snd_seq_set_queue_tempo',
  // Events.
  'snd_seq_event_length',
  'snd_seq_event_output',
  'snd_seq_event_output_buffer',
  'snd_seq_event_output_direct',
  'snd_seq_event_input',
  'snd_seq_event_input_pending',
  'snd_seq_drain_output',
  'snd_seq_event_output_pending',
  'snd_seq_drop_output',
  'snd_seq_drop_output_buffer',
  'snd_seq_drop_input',
  'snd_seq_drop_input_buffer',
  'snd_seq_remove_events_malloc',
  'snd_seq_remove_events_free',
  'snd_seq_remove_events_set_condition',
  'snd_seq_remove_events_set_queue',
  'snd_seq_remove_events_set_time',
  'snd_seq_remove_events_set_dest',
  'snd_seq_remove_events_set_channel',
  'snd_seq_remove_events_set_event_type',
  'snd_seq_remove_events_set_tag',
  'snd_seq_remove_events',
  'snd_seq_ump_event_output',
  'snd_seq_ump_event_output_buffer',
  'snd_seq_ump_event_output_direct',
  'snd_seq_ump_event_input',
  // Middle level helpers.
  'snd_seq_control_queue',
  'snd_seq_create_simple_port',
  'snd_seq_delete_simple_port',
  'snd_seq_connect_from',
  'snd_seq_connect_to',
  'snd_seq_disconnect_from',
  'snd_seq_disconnect_to',
  'snd_seq_set_client_name',
  'snd_seq_set_client_event_filter',
  'snd_seq_set_client_midi_version',
  'snd_seq_set_client_ump_conversion',
  'snd_seq_set_client_pool_output',
  'snd_seq_set_client_pool_output_room',
  'snd_seq_set_client_pool_input',
  'snd_seq_sync_output_queue',
  'snd_seq_parse_address',
  'snd_seq_reset_pool_output',
  'snd_seq_reset_pool_input',
  'snd_seq_create_ump_endpoint',
  'snd_seq_create_ump_block',
  // MIDI byte stream coder.
  'snd_midi_event_new',
  'snd_midi_event_resize_buffer',
  'snd_midi_event_free',
  'snd_midi_event_init',
  'snd_midi_event_reset_encode',
  'snd_midi_event_reset_decode',
  'snd_midi_event_no_status',
  'snd_midi_event_encode',
  'snd_midi_event_encode_byte',
  'snd_midi_event_decode',
  // UMP endpoint and block information.
  'snd_ump_endpoint_info_sizeof',
  'snd_ump_endpoint_info_malloc',
  'snd_ump_endpoint_info_free',
  'snd_ump_endpoint_info_clear',
  'snd_ump_endpoint_info_get_card',
  'snd_ump_endpoint_info_get_device',
  'snd_ump_endpoint_info_get_flags',
  'snd_ump_endpoint_info_get_protocol_caps',
  'snd_ump_endpoint_info_get_protocol',
  'snd_ump_endpoint_info_get_num_blocks',
  'snd_ump_endpoint_info_get_version',
  'snd_ump_endpoint_info_get_manufacturer_id',
  'snd_ump_endpoint_info_get_family_id',
  'snd_ump_endpoint_info_get_model_id',
  'snd_ump_endpoint_info_get_sw_revision',
  'snd_ump_endpoint_info_get_name',
  'snd_ump_endpoint_info_get_product_id',
  'snd_ump_block_info_sizeof',
  'snd_ump_block_info_malloc',
  'snd_ump_block_info_free',
  'snd_ump_block_info_clear',
  'snd_ump_block_info_get_block_id',
  'snd_ump_block_info_get_active',
  'snd_ump_block_info_get_flags',
  'snd_ump_block_info_get_direction',
  'snd_ump_block_info_get_first_group',
  'snd_ump_block_info_get_num_groups',
  'snd_ump_block_info_get_midi_ci_version',
  'snd_ump_block_info_get_sysex8_streams',
  'snd_ump_block_info_get_ui_hint',
  'snd_ump_block_info_get_name',
  // Library.
  'snd_strerror',
  'snd_asoundlib_version',
};
