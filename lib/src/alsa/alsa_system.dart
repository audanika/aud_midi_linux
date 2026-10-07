// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'alsa_reader_message.dart';
import 'alsa_sequencer.dart';

// #############################################################################
/// The native side of the Linux backend: sequencer handles, the reader
/// isolate and the monotonic clock.
///
/// The backend talks to the system only through this interface; the
/// implementation on top of alsa-lib and libc runs on Linux only, tests use
/// a fake.
abstract interface class AlsaSystem {
  // ...........................................................................
  /// Opens a sequencer handle: for [input], a blocking handle the reader
  /// isolate reads from; otherwise a non-blocking handle for output and
  /// control.
  AlsaSequencer open({required bool input});

  /// Starts the reader isolate on the input handle [sequencer], which stops
  /// on the wake-up event with [token] sent by [wakeClient]; [onMessage]
  /// receives its messages in the calling isolate.
  Future<AlsaReader> startReader({
    required AlsaSequencer sequencer,
    required int wakeClient,
    required int token,
    required void Function(AlsaReaderMessage message) onMessage,
  });

  /// Returns the `CLOCK_MONOTONIC` time in microseconds.
  int monotonicNow();
}

// #############################################################################
/// A running reader isolate.
abstract interface class AlsaReader {
  // ...........................................................................
  /// Completes when the reader isolate has ended, after its last message.
  Future<void> get done;
}
