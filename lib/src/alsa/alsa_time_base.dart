// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_midi_core/aud_midi_core.dart';
import 'package:aud_midi_standard/aud_midi_standard.dart';

// #############################################################################
/// Converts between the real time of the backend's ALSA queue, the
/// `CLOCK_MONOTONIC` time of the system and the package clock.
///
/// The sequencer stamps received events with the real time of the queue
/// and schedules sent events against it. That time counts from the start
/// of the queue and runs with `CLOCK_MONOTONIC` (the kernel derives it from
/// `ktime_get_ts64`), so the queue maps to the monotonic clock by an offset,
/// and the monotonic clock maps to the package clock by another. Both
/// offsets are measured by reading the clocks back to back
/// ([MidiClockMapper]); call [resync] from time to time.
final class AlsaTimeBase {
  /// Creates a time base for the package [clock], reading the monotonic
  /// clock with [monotonicNow] and the queue's real time with [queueNow],
  /// both in microseconds.
  AlsaTimeBase({
    required MidiClock clock,
    required int Function() monotonicNow,
    required int Function() queueNow,
  }) : _toPackage = MidiClockMapper(clock: clock, nativeNow: monotonicNow),
       _toMonotonic = MidiClockMapper(
         clock: _NativeClock(monotonicNow),
         nativeNow: queueNow,
       );

  // ...........................................................................
  /// Converts the queue time [queueMicroseconds] to the package clock.
  MidiTime toPackage(int queueMicroseconds) => _toPackage.toPackage(
    _toMonotonic.toPackage(queueMicroseconds).microseconds,
  );

  /// Converts the package time [time] to the queue time in microseconds.
  int toQueue(MidiTime time) =>
      _toMonotonic.toNative(MidiTime(_toPackage.toNative(time)));

  /// Measures both offsets again.
  void resync() {
    _toPackage.resync();
    _toMonotonic.resync();
  }

  // ...........................................................................
  final MidiClockMapper _toPackage;
  final MidiClockMapper _toMonotonic;
}

// #############################################################################
/// Presents a native microsecond clock as a [MidiClock], so a
/// [MidiClockMapper] can map a second native clock onto it.
final class _NativeClock implements MidiClock {
  _NativeClock(this._now);

  @override
  MidiTime now() => MidiTime(_now());

  final int Function() _now;
}
