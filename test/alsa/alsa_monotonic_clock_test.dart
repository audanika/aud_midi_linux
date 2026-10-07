// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:aud_midi_core/aud_midi_core.dart';
import 'package:aud_midi_linux/src/alsa/alsa_monotonic_clock.dart';
import 'package:test/test.dart';

void main() {
  group('AlsaMonotonicClock', () {
    group('AlsaMonotonicClock(clockId)', () {
      test('reads CLOCK_MONOTONIC of the running system', () {
        expect(AlsaMonotonicClock().clockId, Platform.isMacOS ? 6 : 1);
      });
    });

    group('now()', () {
      test('runs with the stopwatch of the VM', () {
        final clock = AlsaMonotonicClock();
        final before = clock.now();
        final watch = Stopwatch()..start();
        while (watch.elapsedMicroseconds < 20000) {}
        final watched = watch.elapsedMicroseconds;
        final elapsed = clock.now() - before;
        expect(elapsed, inInclusiveRange(watched - 1000, watched + 500000));
      });

      test('throws a MidiNativeError for an unknown clock', () {
        expect(
          () => AlsaMonotonicClock(clockId: 9999).now(),
          throwsA(
            isA<MidiNativeError>().having((e) => e.api, 'api', 'clock_gettime'),
          ),
        );
      });
    });
  });
}
