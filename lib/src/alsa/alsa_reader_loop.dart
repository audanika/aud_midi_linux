// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:typed_data';

import 'alsa_bindings.g.dart';
import 'alsa_errors.dart';
import 'alsa_event.dart';
import 'alsa_event_source.dart';
import 'alsa_reader_message.dart';

// #############################################################################
/// The loop of the reader isolate: it blocks in `snd_seq_event_input`,
/// copies what arrives into Dart objects and sends them on in batches.
///
/// A batch is everything alsa-lib read in one go. The loop ends on the
/// wake-up event, which only the backend's own output client can send
/// (checked by [wakeClient] and the random [token]), or on a read error
/// other than an overrun.
final class AlsaReaderLoop {
  /// Creates a loop that reads from [source] and reports through [send].
  AlsaReaderLoop({
    required this.source,
    required this.send,
    required this.wakeClient,
    required this.token,
  });

  // ...........................................................................
  /// Runs until the wake-up event arrives or reading fails.
  void run() {
    for (;;) {
      final batch = <AlsaEvent>[];
      var result = source.read();
      while (true) {
        final event = result.event;
        if (event == null) {
          if (!_handleError(result.error, batch)) return;
          break;
        }
        if (_isWakeUp(event)) {
          _flush(batch);
          send(const AlsaReaderStopped());
          return;
        }
        batch.add(event);
        if (source.pending() <= 0) break;
        result = source.read();
      }
      _flush(batch);
    }
  }

  // ...........................................................................
  /// The handle to read from.
  final AlsaEventSource source;

  /// Delivers a message to the backend.
  final void Function(AlsaReaderMessage message) send;

  /// The client that may send the wake-up event.
  final int wakeClient;

  /// The value the wake-up event carries.
  final int token;

  // ...........................................................................
  /// Returns the wake-up event carrying [token], to be routed to the
  /// reader's port.
  static AlsaEvent wakeUp({required int token}) => AlsaEvent.fixed(
    type: snd_seq_event_type.SND_SEQ_EVENT_USR0,
    data: (ByteData(4)..setUint32(0, token, Endian.host)).buffer.asUint8List(),
  );

  // ...........................................................................
  bool _isWakeUp(AlsaEvent event) =>
      event.type == snd_seq_event_type.SND_SEQ_EVENT_USR0 &&
      event.sourceClient == wakeClient &&
      event.word(0) == token;

  void _flush(List<AlsaEvent> batch) {
    if (batch.isNotEmpty) send(AlsaReaderEvents(List.unmodifiable(batch)));
  }

  /// Reports [error]; returns whether reading goes on.
  bool _handleError(int error, List<AlsaEvent> batch) {
    _flush(batch);
    batch.clear();
    switch (-error) {
      case AlsaErrors.enospc:
        send(const AlsaReaderOverflow());
        return true;
      case AlsaErrors.eagain || AlsaErrors.eintr:
        return true;
    }
    send(AlsaReaderFailed(error));
    return false;
  }
}
