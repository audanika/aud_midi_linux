// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:ffi';
import 'dart:io';

import 'package:aud_midi_core/aud_midi_core.dart';
import 'package:ffi/ffi.dart';

// #############################################################################
/// Reads `CLOCK_MONOTONIC` with `clock_gettime` from the C library, the
/// clock the ALSA sequencer queues run on.
final class AlsaMonotonicClock {
  /// Creates a clock that reads [clockId] through the C library of the
  /// process; the default is `CLOCK_MONOTONIC` of the running system
  /// (1 on Linux, 6 on macOS).
  AlsaMonotonicClock({int? clockId})
    : clockId = clockId ?? (Platform.isMacOS ? 6 : 1),
      _clockGettime = DynamicLibrary.process()
          .lookupFunction<
            Int Function(Int, Pointer<_Timespec>),
            int Function(int, Pointer<_Timespec>)
          >('clock_gettime');

  // ...........................................................................
  /// Returns the time of the clock in microseconds.
  ///
  /// Throws a [MidiNativeError] when `clock_gettime` fails, e.g. for an
  /// unknown clock.
  int now() {
    final time = calloc<_Timespec>();
    try {
      final result = _clockGettime(clockId, time);
      if (result != 0) {
        throw MidiNativeError(api: 'clock_gettime', code: result);
      }
      return time.ref.seconds * Duration.microsecondsPerSecond +
          time.ref.nanoseconds ~/ 1000;
    } finally {
      calloc.free(time);
    }
  }

  // ...........................................................................
  /// The id of the clock that is read.
  final int clockId;

  // ...........................................................................
  final int Function(int, Pointer<_Timespec>) _clockGettime;
}

// #############################################################################
/// `struct timespec` of LP64 systems.
final class _Timespec extends Struct {
  @Long()
  external int seconds;

  @Long()
  external int nanoseconds;
}
