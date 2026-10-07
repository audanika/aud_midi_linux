// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:isolate';

import 'package:aud_midi_linux/src/alsa/alsa_event.dart';
import 'package:aud_midi_linux/src/alsa/alsa_reader_message.dart';
import 'package:test/test.dart';

void main() {
  group('AlsaReaderMessage', () {
    test('crosses isolates like the reader sends it', () async {
      final message = await Isolate.run(
        () => AlsaReaderEvents([
          AlsaEvent.sysEx([0xF0, 1, 0xF7]),
          AlsaEvent.ump([0x20903C64]),
        ]),
      );
      expect(message.events, [
        AlsaEvent.sysEx([0xF0, 1, 0xF7]),
        AlsaEvent.ump([0x20903C64]),
      ]);
    });

    test('describes events, overruns, failures and the stop', () {
      final event = AlsaEvent.fixed(type: 6);
      final messages = <AlsaReaderMessage>[
        AlsaReaderEvents([event]),
        const AlsaReaderOverflow(),
        const AlsaReaderFailed(-9),
        const AlsaReaderStopped(),
      ];
      expect(
        [
          for (final message in messages)
            switch (message) {
              AlsaReaderEvents(:final events) => events,
              AlsaReaderOverflow() => 'overflow',
              AlsaReaderFailed(:final code) => code,
              AlsaReaderStopped() => 'stopped',
            },
        ],
        equals([
          [event],
          'overflow',
          -9,
          'stopped',
        ]),
      );
    });
  });
}
