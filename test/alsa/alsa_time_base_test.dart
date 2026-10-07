// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_midi_core/aud_midi_core.dart';
import 'package:aud_midi_linux/src/alsa/alsa_time_base.dart';
import 'package:aud_midi_standard/aud_midi_standard.dart';
import 'package:test/test.dart';

void main() {
  late MidiFakeClock clock;
  late int monotonic;
  late int queueStart;
  late AlsaTimeBase timeBase;

  setUp(() {
    clock = MidiFakeClock(start: const MidiTime(50000000));
    monotonic = 1000000;
    queueStart = 400000;
    timeBase = AlsaTimeBase(
      clock: clock,
      monotonicNow: () => monotonic,
      queueNow: () => monotonic - queueStart,
    );
  });

  group('AlsaTimeBase', () {
    group('toPackage(queueMicroseconds)', () {
      test('maps queue time over the monotonic clock to the package', () {
        expect([
          timeBase.toPackage(600000),
          timeBase.toPackage(612345),
        ], equals([const MidiTime(50000000), const MidiTime(50012345)]));
      });
    });

    group('toQueue(time)', () {
      test('maps package time to queue time', () {
        expect([
          timeBase.toQueue(const MidiTime(50000000)),
          timeBase.toQueue(const MidiTime(50100000)),
        ], equals([600000, 700000]));
      });
    });

    group('resync()', () {
      test('measures both offsets again', () {
        queueStart = 400010;
        clock.jumpTo(const MidiTime(60000000));
        timeBase.resync();
        expect([
          timeBase.toPackage(599990),
          timeBase.toQueue(const MidiTime(60000000)),
        ], equals([const MidiTime(60000000), 599990]));
      });
    });
  });
}
