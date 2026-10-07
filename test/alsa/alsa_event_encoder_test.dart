// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_midi_linux/src/alsa/alsa_bindings.g.dart';
import 'package:aud_midi_linux/src/alsa/alsa_event.dart';
import 'package:aud_midi_linux/src/alsa/alsa_event_encoder.dart';
import 'package:test/test.dart';

typedef T = snd_seq_event_type;

void main() {
  late AlsaEventEncoder encoder;

  setUp(() => encoder = AlsaEventEncoder(maxSysExChunk: 4));

  AlsaEvent note(int type, int channel, int note, int velocity) =>
      AlsaEvent.note(
        type: type,
        channel: channel,
        note: note,
        velocity: velocity,
      );

  AlsaEvent control(
    int type, {
    int channel = 0,
    int param = 0,
    int value = 0,
  }) => AlsaEvent.control(
    type: type,
    channel: channel,
    param: param,
    value: value,
  );

  AlsaEvent simple(int type) => AlsaEvent.fixed(type: type);

  List<Object> flat(AlsaEncoded encoded) => [encoded.events, encoded.skipped];

  group('AlsaEventEncoder', () {
    group('AlsaEventEncoder(maxSysExChunk)', () {
      test('defaults to chunks of 256 bytes', () {
        expect(AlsaEventEncoder().maxSysExChunk, 256);
      });
    });

    group('encodeBytes(bytes)', () {
      final cases = <String, (List<int>, List<AlsaEvent>)>{
        'note off': (
          [0x81, 60, 64],
          [note(T.SND_SEQ_EVENT_NOTEOFF, 1, 60, 64)],
        ),
        'note on with velocity 0': (
          [0x90, 60, 0],
          [note(T.SND_SEQ_EVENT_NOTEON, 0, 60, 0)],
        ),
        'poly pressure': (
          [0xA2, 60, 10],
          [note(T.SND_SEQ_EVENT_KEYPRESS, 2, 60, 10)],
        ),
        'control change': (
          [0xB3, 7, 100],
          [
            control(
              T.SND_SEQ_EVENT_CONTROLLER,
              channel: 3,
              param: 7,
              value: 100,
            ),
          ],
        ),
        'program change': (
          [0xC4, 5],
          [control(T.SND_SEQ_EVENT_PGMCHANGE, channel: 4, value: 5)],
        ),
        'channel pressure': (
          [0xD5, 9],
          [control(T.SND_SEQ_EVENT_CHANPRESS, channel: 5, value: 9)],
        ),
        'pitch bend': (
          [0xE6, 0x00, 0x40, 0xE6, 0x7F, 0x7F],
          [
            control(T.SND_SEQ_EVENT_PITCHBEND, channel: 6),
            control(T.SND_SEQ_EVENT_PITCHBEND, channel: 6, value: 8191),
          ],
        ),
        'running status': (
          [0x90, 60, 64, 62, 64],
          [
            note(T.SND_SEQ_EVENT_NOTEON, 0, 60, 64),
            note(T.SND_SEQ_EVENT_NOTEON, 0, 62, 64),
          ],
        ),
        'system common messages': (
          [0xF1, 0x23, 0xF2, 44, 2, 0xF3, 3, 0xF6],
          [
            control(T.SND_SEQ_EVENT_QFRAME, value: 0x23),
            control(T.SND_SEQ_EVENT_SONGPOS, value: 300),
            control(T.SND_SEQ_EVENT_SONGSEL, value: 3),
            simple(T.SND_SEQ_EVENT_TUNE_REQUEST),
          ],
        ),
        'real-time messages': (
          [0xF8, 0xFA, 0xFB, 0xFC, 0xFE, 0xFF],
          [
            simple(T.SND_SEQ_EVENT_CLOCK),
            simple(T.SND_SEQ_EVENT_START),
            simple(T.SND_SEQ_EVENT_CONTINUE),
            simple(T.SND_SEQ_EVENT_STOP),
            simple(T.SND_SEQ_EVENT_SENSING),
            simple(T.SND_SEQ_EVENT_RESET),
          ],
        ),
        'SysEx within one chunk': (
          [0xF0, 1, 0xF7],
          [
            AlsaEvent.sysEx([0xF0, 1, 0xF7]),
          ],
        ),
        'SysEx in chunks': (
          [0xF0, 1, 2, 3, 4, 5, 0xF7],
          [
            AlsaEvent.sysEx([0xF0, 1, 2, 3]),
            AlsaEvent.sysEx([4, 5, 0xF7]),
          ],
        ),
        'SysEx with a real-time message inside': (
          [0xF0, 1, 0xF8, 2, 0xF7],
          [
            AlsaEvent.sysEx([0xF0, 1]),
            simple(T.SND_SEQ_EVENT_CLOCK),
            AlsaEvent.sysEx([2, 0xF7]),
          ],
        ),
        'SysEx cut off by a status': (
          [0xF0, 1, 0x90, 60, 64],
          [
            AlsaEvent.sysEx([0xF0, 1]),
            note(T.SND_SEQ_EVENT_NOTEON, 0, 60, 64),
          ],
        ),
        'SysEx cut off by another SysEx': (
          [0xF0, 1, 0xF0, 2, 0xF7],
          [
            AlsaEvent.sysEx([0xF0, 1]),
            AlsaEvent.sysEx([0xF0, 2, 0xF7]),
          ],
        ),
      };
      for (final MapEntry(key: name, value: (bytes, events)) in cases.entries) {
        test('converts $name', () {
          expect(flat(encoder.encodeBytes(bytes)), equals([events, 0]));
        });
      }

      test('skips stray bytes and undefined statuses', () {
        expect(
          flat(
            encoder.encodeBytes([
              60, // data without status
              0xF7, // end without SysEx
              0xF4, 0xF5, 0xF9, 0xFD, // undefined
              0xF1, 0x10, 0x20, // no running status for system common
            ]),
          ),
          equals([
            [control(T.SND_SEQ_EVENT_QFRAME, value: 0x10)],
            7,
          ]),
        );
      });

      test('keeps the low eight bits of each value', () {
        expect(
          encoder.encodeBytes([0x1F8]).events,
          equals([simple(T.SND_SEQ_EVENT_CLOCK)]),
        );
      });

      test('continues a message and a SysEx across chunks', () {
        expect(
          [
            flat(encoder.encodeBytes([0x90, 60])),
            flat(encoder.encodeBytes([64, 0xF0, 1])),
            flat(encoder.encodeBytes([2, 0xF7])),
          ],
          equals([
            [<AlsaEvent>[], 0],
            [
              [
                note(T.SND_SEQ_EVENT_NOTEON, 0, 60, 64),
                AlsaEvent.sysEx([0xF0, 1]),
              ],
              0,
            ],
            [
              [
                AlsaEvent.sysEx([2, 0xF7]),
              ],
              0,
            ],
          ]),
        );
      });
    });

    group('reset()', () {
      test('forgets the running status and an open SysEx', () {
        encoder.encodeBytes([0x90, 60, 64]);
        encoder.reset();
        expect(encoder.encodeBytes([62, 64]).skipped, 2);
        encoder.encodeBytes([0xF0, 1]);
        encoder.reset();
        expect(encoder.encodeBytes([2, 0xF7]).skipped, 2);
      });
    });

    group('encodeUmp(words)', () {
      test('creates one event per packet', () {
        expect(
          flat(
            AlsaEventEncoder.encodeUmp([0x40903C00, 0xC8000000, 0x20903C64]),
          ),
          equals([
            [
              AlsaEvent.ump([0x40903C00, 0xC8000000]),
              AlsaEvent.ump([0x20903C64]),
            ],
            0,
          ]),
        );
      });

      test('skips the words of an incomplete last packet', () {
        expect(
          flat(AlsaEventEncoder.encodeUmp([0x20903C64, 0x40903C00])),
          equals([
            [
              AlsaEvent.ump([0x20903C64]),
            ],
            1,
          ]),
        );
      });
    });
  });
}
