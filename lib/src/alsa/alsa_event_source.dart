// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'alsa_event.dart';

// #############################################################################
/// The result of one read: an event, or a negative error number.
typedef AlsaReadResult = ({AlsaEvent? event, int error});

// #############################################################################
/// The input side of a sequencer handle as the reader isolate uses it.
abstract interface class AlsaEventSource {
  // ...........................................................................
  /// Waits for the next event (`snd_seq_event_input`) and returns a copy of
  /// it, or the negative error number when reading failed.
  AlsaReadResult read();

  /// Returns the number of events alsa-lib has already buffered, which
  /// [read] returns without waiting.
  int pending();
}
