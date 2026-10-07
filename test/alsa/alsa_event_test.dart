// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:typed_data';

import 'package:aud_midi_linux/src/alsa/alsa_bindings.g.dart';
import 'package:aud_midi_linux/src/alsa/alsa_event.dart';
import 'package:aud_midi_linux/src/alsa/alsa_event_layout.dart';
import 'package:test/test.dart';

void main() {
  const noteOn = snd_seq_event_type.SND_SEQ_EVENT_NOTEON;
  const controller = snd_seq_event_type.SND_SEQ_EVENT_CONTROLLER;

  AlsaEvent note() =>
      AlsaEvent.note(type: noteOn, channel: 2, note: 60, velocity: 100);

  group('AlsaEvent', () {
    group('AlsaEvent(cell, ext)', () {
      test('copies the cell and the external data', () {
        final cell = Uint8List(AlsaEventLayout.legacySize)..[0] = noteOn;
        final ext = [1, 2];
        final event = AlsaEvent(cell: cell, ext: ext);
        cell[0] = 0;
        ext[0] = 9;
        expect([event.type, ...event.ext!], equals([noteOn, 1, 2]));
      });

      test('accepts a UMP cell and no external data', () {
        final event = AlsaEvent(cell: Uint8List(AlsaEventLayout.umpSize));
        expect([event.cell.length, event.ext], equals([32, null]));
      });
    });

    group('AlsaEvent.note(type, channel, note, velocity)', () {
      test('fills the note data', () {
        final event = note();
        expect([
          event.type,
          event.channel,
          event.note,
          event.velocity,
        ], equals([noteOn, 2, 60, 100]));
        expect([
          event.isUmp,
          event.isVariable,
          event.cell.length,
        ], equals([false, false, AlsaEventLayout.legacySize]));
      });
    });

    group('AlsaEvent.control(type, channel, param, value)', () {
      test('fills the control data with a signed value', () {
        final event = AlsaEvent.control(
          type: controller,
          channel: 15,
          param: 74,
          value: -8192,
        );
        expect([
          event.type,
          event.channel,
          event.param,
          event.value,
        ], equals([controller, 15, 74, -8192]));
      });

      test('defaults param and value to zero', () {
        final event = AlsaEvent.control(type: controller, channel: 1);
        expect([event.param, event.value], equals([0, 0]));
      });
    });

    group('AlsaEvent.sysEx(bytes)', () {
      test('creates a variable-length event with the data length', () {
        final event = AlsaEvent.sysEx([0xF0, 0x7E, 0xF7]);
        expect(
          [event.type, event.isVariable, event.word(0), ...event.ext!],
          equals([
            snd_seq_event_type.SND_SEQ_EVENT_SYSEX,
            true,
            3,
            0xF0,
            0x7E,
            0xF7,
          ]),
        );
      });
    });

    group('AlsaEvent.ump(words)', () {
      test('creates a UMP event with the words in the data union', () {
        final event = AlsaEvent.ump([0x40903C00, 0xC8000000]);
        expect([
          event.isUmp,
          event.cell.length,
          event.word(0),
          event.word(1),
          event.word(2),
        ], equals([true, AlsaEventLayout.umpSize, 0x40903C00, 0xC8000000, 0]));
      });
    });

    group('routed(sourcePort, destClient, destPort, tag)', () {
      test('sets the addresses and the tag', () {
        final event = note().routed(
          sourcePort: 3,
          destClient: 20,
          destPort: 1,
          tag: 7,
        );
        expect([
          event.sourcePort,
          event.destClient,
          event.destPort,
          event.tag,
        ], equals([3, 20, 1, 7]));
        expect(event.note, 60);
      });

      test('defaults the tag to zero', () {
        final event = note()
            .routed(sourcePort: 0, destClient: 1, destPort: 1, tag: 9)
            .routed(sourcePort: 0, destClient: 1, destPort: 1);
        expect(event.tag, 0);
      });
    });

    group('direct()', () {
      test('clears the schedule', () {
        final event = note()
            .scheduled(queue: 2, microseconds: 1500000)
            .direct();
        expect([
          event.queue,
          event.hasRealTime,
          event.realTimeMicroseconds,
        ], equals([SND_SEQ_QUEUE_DIRECT, false, 0]));
      });
    });

    group('scheduled(queue, microseconds)', () {
      test('sets an absolute real time on the queue', () {
        final event = AlsaEvent.sysEx([
          0xF0,
          0xF7,
        ]).scheduled(queue: 2, microseconds: 3000004);
        expect([
          event.queue,
          event.hasRealTime,
          event.flags & SND_SEQ_TIME_MODE_MASK,
          event.isVariable,
          event.realTimeMicroseconds,
          event.ext!.length,
        ], equals([2, true, SND_SEQ_TIME_MODE_ABS, true, 3000004, 2]));
      });
    });

    group('sourceClient, addrClient, addrPort', () {
      test('read the source address and the address in the data', () {
        final cell = Uint8List(AlsaEventLayout.legacySize)
          ..[AlsaEventLayout.sourceClient] = 5
          ..[AlsaEventLayout.addrClient] = 24
          ..[AlsaEventLayout.addrPort] = 2;
        final event = AlsaEvent(cell: cell);
        expect([
          event.sourceClient,
          event.addrClient,
          event.addrPort,
        ], equals([5, 24, 2]));
      });
    });

    group('==, hashCode', () {
      test('compare cells and external data', () {
        expect(note(), equals(note()));
        expect(note().hashCode, note().hashCode);
        expect(AlsaEvent.sysEx([1]), equals(AlsaEvent.sysEx([1])));
        expect(AlsaEvent.sysEx([1]), isNot(equals(AlsaEvent.sysEx([2]))));
        expect(AlsaEvent.sysEx([1]), isNot(equals(AlsaEvent.sysEx([1, 2]))));
        expect(note(), isNot(equals(AlsaEvent.sysEx([1]))));
        expect(
          note(),
          isNot(
            equals(
              AlsaEvent.note(type: noteOn, channel: 2, note: 61, velocity: 100),
            ),
          ),
        );
        expect(note(), isNot(equals(AlsaEvent.ump([0x10F80000]))));
        expect(note() == Object(), isFalse);
        final same = note();
        expect(same == same, isTrue);
      });
    });

    group('toString()', () {
      test('shows the type, the cell and the external data', () {
        expect(
          AlsaEvent.fixed(type: 42).toString(),
          'AlsaEvent(type: 42, cell: 2a${' 00' * 27})',
        );
        expect(
          AlsaEvent.sysEx([0xF0, 0xF7]).toString(),
          endsWith(', ext: 2 bytes)'),
        );
      });
    });
  });
}
