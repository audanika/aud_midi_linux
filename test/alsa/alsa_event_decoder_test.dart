// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:typed_data';

import 'package:aud_midi_linux/src/alsa/alsa_bindings.g.dart';
import 'package:aud_midi_linux/src/alsa/alsa_event.dart';
import 'package:aud_midi_linux/src/alsa/alsa_event_decoder.dart';
import 'package:aud_midi_linux/src/alsa/alsa_event_layout.dart';
import 'package:test/test.dart';

typedef T = snd_seq_event_type;

void main() {
  AlsaEvent note(int type) =>
      AlsaEvent.note(type: type, channel: 1, note: 60, velocity: 64);

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

  group('AlsaEventDecoder', () {
    group('toBytes(event)', () {
      final cases = <String, (AlsaEvent, List<int>)>{
        'note off': (note(T.SND_SEQ_EVENT_NOTEOFF), [0x81, 60, 64]),
        'note on': (note(T.SND_SEQ_EVENT_NOTEON), [0x91, 60, 64]),
        'key pressure': (note(T.SND_SEQ_EVENT_KEYPRESS), [0xA1, 60, 64]),
        'controller': (
          control(T.SND_SEQ_EVENT_CONTROLLER, channel: 2, param: 7, value: 100),
          [0xB2, 7, 100],
        ),
        'program change': (
          control(T.SND_SEQ_EVENT_PGMCHANGE, channel: 3, value: 5),
          [0xC3, 5],
        ),
        'channel pressure': (
          control(T.SND_SEQ_EVENT_CHANPRESS, value: 9),
          [0xD0, 9],
        ),
        'pitch bend centre': (
          control(T.SND_SEQ_EVENT_PITCHBEND),
          [0xE0, 0x00, 0x40],
        ),
        'pitch bend minimum': (
          control(T.SND_SEQ_EVENT_PITCHBEND, value: -8192),
          [0xE0, 0x00, 0x00],
        ),
        'pitch bend maximum': (
          control(T.SND_SEQ_EVENT_PITCHBEND, value: 8191),
          [0xE0, 0x7F, 0x7F],
        ),
        '14-bit controller below 32': (
          control(T.SND_SEQ_EVENT_CONTROL14, param: 7, value: 1000),
          [0xB0, 7, 7, 0xB0, 39, 104],
        ),
        '14-bit controller from 32': (
          control(T.SND_SEQ_EVENT_CONTROL14, param: 64, value: 127),
          [0xB0, 64, 127],
        ),
        'NRPN': (
          control(T.SND_SEQ_EVENT_NONREGPARAM, param: 0x81, value: 0x2000),
          [0xB0, 99, 1, 0xB0, 98, 1, 0xB0, 6, 0x40, 0xB0, 38, 0],
        ),
        'RPN': (
          control(T.SND_SEQ_EVENT_REGPARAM, channel: 1, value: 2),
          [0xB1, 101, 0, 0xB1, 100, 0, 0xB1, 6, 0, 0xB1, 38, 2],
        ),
        'quarter frame': (
          control(T.SND_SEQ_EVENT_QFRAME, value: 0x23),
          [0xF1, 0x23],
        ),
        'song position': (
          control(T.SND_SEQ_EVENT_SONGPOS, value: 300),
          [0xF2, 44, 2],
        ),
        'song select': (control(T.SND_SEQ_EVENT_SONGSEL, value: 3), [0xF3, 3]),
        'tune request': (
          AlsaEvent.fixed(type: T.SND_SEQ_EVENT_TUNE_REQUEST),
          [0xF6],
        ),
        'clock': (AlsaEvent.fixed(type: T.SND_SEQ_EVENT_CLOCK), [0xF8]),
        'start': (AlsaEvent.fixed(type: T.SND_SEQ_EVENT_START), [0xFA]),
        'continue': (AlsaEvent.fixed(type: T.SND_SEQ_EVENT_CONTINUE), [0xFB]),
        'stop': (AlsaEvent.fixed(type: T.SND_SEQ_EVENT_STOP), [0xFC]),
        'active sensing': (
          AlsaEvent.fixed(type: T.SND_SEQ_EVENT_SENSING),
          [0xFE],
        ),
        'reset': (AlsaEvent.fixed(type: T.SND_SEQ_EVENT_RESET), [0xFF]),
        'SysEx': (AlsaEvent.sysEx([0xF0, 0x7E, 0xF7]), [0xF0, 0x7E, 0xF7]),
      };
      for (final MapEntry(key: name, value: (event, bytes)) in cases.entries) {
        test('converts a $name', () {
          expect(AlsaEventDecoder.toBytes(event), equals(bytes));
        });
      }

      final none = <String, AlsaEvent>{
        'note with duration': note(T.SND_SEQ_EVENT_NOTE),
        'tick': AlsaEvent.fixed(type: T.SND_SEQ_EVENT_TICK),
        'announcement': AlsaEvent.fixed(type: T.SND_SEQ_EVENT_PORT_START),
        'UMP event': AlsaEvent.ump([0x20903C64]),
      };
      for (final MapEntry(key: name, value: event) in none.entries) {
        test('returns null for a $name', () {
          expect(AlsaEventDecoder.toBytes(event), isNull);
        });
      }
    });

    group('toUmp(event, group)', () {
      test('returns the words of a UMP event by message type', () {
        expect(
          [
            AlsaEventDecoder.toUmp(AlsaEvent.ump([0x20903C64])),
            AlsaEventDecoder.toUmp(AlsaEvent.ump([0x40903C00, 0xC8000000])),
            AlsaEventDecoder.toUmp(AlsaEvent.ump([0x50000000, 1, 2, 3])),
          ],
          equals([
            [0x20903C64],
            [0x40903C00, 0xC8000000],
            [0x50000000, 1, 2, 3],
          ]),
        );
      });

      test('packs MIDI 1.0 channel voice and system events', () {
        expect(
          [
            AlsaEventDecoder.toUmp(note(T.SND_SEQ_EVENT_NOTEON), group: 3),
            AlsaEventDecoder.toUmp(
              control(T.SND_SEQ_EVENT_SONGPOS, value: 300),
            ),
            AlsaEventDecoder.toUmp(
              AlsaEvent.fixed(type: T.SND_SEQ_EVENT_TUNE_REQUEST),
            ),
            AlsaEventDecoder.toUmp(
              control(T.SND_SEQ_EVENT_CONTROL14, param: 7, value: 1000),
            ),
            AlsaEventDecoder.toUmp(
              control(T.SND_SEQ_EVENT_PGMCHANGE, value: 5),
            ),
          ],
          equals([
            [0x23913C40],
            [0x10F22C02],
            [0x10F60000],
            [0x20B00707, 0x20B02768],
            [0x20C00500],
          ]),
        );
      });

      test('returns null for events without MIDI message', () {
        expect(
          AlsaEventDecoder.toUmp(AlsaEvent.fixed(type: T.SND_SEQ_EVENT_ECHO)),
          isNull,
        );
      });

      final sysEx = <String, (List<int>, List<int>)>{
        'complete in one packet': (
          [0xF0, 0x7E, 0x7F, 0xF7],
          [0x31027E7F, 0x00000000],
        ),
        'empty': ([0xF0, 0xF7], [0x31000000, 0x00000000]),
        'in start and end packets': (
          [0xF0, 1, 2, 3, 4, 5, 6, 7, 8, 0xF7],
          [0x31160102, 0x03040506, 0x31320708, 0x00000000],
        ),
        'in start, continue and end packets': (
          [0xF0, ...List.generate(13, (i) => i + 1), 0xF7],
          [
            0x31160102,
            0x03040506,
            0x31260708,
            0x090A0B0C,
            0x31310D00,
            0x00000000,
          ],
        ),
        'that starts only': ([0xF0, 1, 2, 3], [0x31130102, 0x03000000]),
        'that continues only': (
          [1, 2, 3, 4, 5, 6, 7],
          [0x31260102, 0x03040506, 0x31210700, 0x00000000],
        ),
        'that ends only': ([1, 2, 0xF7], [0x31320102, 0x00000000]),
        'that is an end byte only': ([0xF7], [0x31300000, 0x00000000]),
        'that is empty': (<int>[], <int>[]),
      };
      for (final MapEntry(key: name, value: (bytes, words)) in sysEx.entries) {
        test('packs a SysEx chunk $name', () {
          expect(
            AlsaEventDecoder.toUmp(AlsaEvent.sysEx(bytes), group: 1),
            equals(words),
          );
        });
      }

      test('returns null for a SysEx event without data', () {
        final cell = Uint8List(AlsaEventLayout.legacySize)
          ..[AlsaEventLayout.type] = T.SND_SEQ_EVENT_SYSEX;
        expect(AlsaEventDecoder.toUmp(AlsaEvent(cell: cell)), isNull);
      });
    });
  });
}
