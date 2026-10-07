// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'alsa_event.dart';

// #############################################################################
/// What the reader isolate reports to the isolate of the backend.
sealed class AlsaReaderMessage {
  /// Creates a message.
  const AlsaReaderMessage();
}

// #############################################################################
/// Events the reader received, in their order.
final class AlsaReaderEvents extends AlsaReaderMessage {
  /// Creates the message for [events].
  const AlsaReaderEvents(this.events);

  // ...........................................................................
  /// The received events.
  final List<AlsaEvent> events;
}

// #############################################################################
/// The input FIFO of the sequencer overran; the kernel dropped events and
/// cleared the FIFO.
final class AlsaReaderOverflow extends AlsaReaderMessage {
  /// Creates the message.
  const AlsaReaderOverflow();
}

// #############################################################################
/// Reading failed with the negative error number [code]; the reader ended.
final class AlsaReaderFailed extends AlsaReaderMessage {
  /// Creates the message for the error [code].
  const AlsaReaderFailed(this.code);

  // ...........................................................................
  /// The negative error number of `snd_seq_event_input`.
  final int code;
}

// #############################################################################
/// The reader received its wake-up event and ended.
final class AlsaReaderStopped extends AlsaReaderMessage {
  /// Creates the message.
  const AlsaReaderStopped();
}
