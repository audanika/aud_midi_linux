// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:typed_data';

import 'package:aud_midi_standard/aud_midi_standard.dart';

import 'alsa_bindings.g.dart';
import 'alsa_event.dart';

// #############################################################################
/// Turns received ALSA sequencer events into MIDI 1.0 bytes or UMP words.
///
/// The byte form follows the conventions of alsa-lib's `snd_midi_event`
/// coder, which the kernel's rawmidi bridge uses too: pitch bend values are
/// centred on zero, song positions are 14-bit values, 14-bit controllers
/// and (N)RPN events become several Control Changes. Every message gets its
/// own status byte (no running status).
abstract final class AlsaEventDecoder {
  // ...........................................................................
  /// Returns the MIDI 1.0 bytes of [event], or null when the event carries
  /// no MIDI message, e.g. an announcement or a queue control.
  static Uint8List? toBytes(AlsaEvent event) {
    if (event.isUmp) return null;
    if (event.type == snd_seq_event_type.SND_SEQ_EVENT_SYSEX) {
      return event.ext;
    }
    final bytes = _channelBytes(event) ?? _systemBytes(event);
    return bytes == null ? null : Uint8List.fromList(bytes);
  }

  /// Returns the UMP words of [event], or null when it carries no MIDI
  /// message.
  ///
  /// A UMP event yields its packet. A MIDI 1.0 event that the kernel did
  /// not convert, which happens for event types without a UMP counterpart
  /// in the kernel, becomes MIDI 1.0 channel voice (type 2), system (type 1)
  /// or SysEx7 (type 3) packets of [group].
  static Uint32List? toUmp(AlsaEvent event, {int group = 0}) {
    if (event.isUmp) {
      final size = Ump.sizeOf(event.word(0));
      return Uint32List.fromList([
        for (var i = 0; i < size; i++) event.word(i),
      ]);
    }
    final bytes = toBytes(event);
    if (bytes == null) return null;
    if (event.type == snd_seq_event_type.SND_SEQ_EVENT_SYSEX) {
      return _sysExWords(bytes, group);
    }
    return _shortMessageWords(bytes, group);
  }

  // ...........................................................................
  static List<int>? _channelBytes(AlsaEvent event) {
    final channel = event.channel & 0x0F;
    final value = event.value;
    return switch (event.type) {
      snd_seq_event_type.SND_SEQ_EVENT_NOTEOFF => [
        MidiStatus.noteOff | channel,
        event.note & 0x7F,
        event.velocity & 0x7F,
      ],
      snd_seq_event_type.SND_SEQ_EVENT_NOTEON => [
        MidiStatus.noteOn | channel,
        event.note & 0x7F,
        event.velocity & 0x7F,
      ],
      snd_seq_event_type.SND_SEQ_EVENT_KEYPRESS => [
        MidiStatus.polyPressure | channel,
        event.note & 0x7F,
        event.velocity & 0x7F,
      ],
      snd_seq_event_type.SND_SEQ_EVENT_CONTROLLER => [
        MidiStatus.controlChange | channel,
        event.param & 0x7F,
        value & 0x7F,
      ],
      snd_seq_event_type.SND_SEQ_EVENT_PGMCHANGE => [
        MidiStatus.programChange | channel,
        value & 0x7F,
      ],
      snd_seq_event_type.SND_SEQ_EVENT_CHANPRESS => [
        MidiStatus.channelPressure | channel,
        value & 0x7F,
      ],
      snd_seq_event_type.SND_SEQ_EVENT_PITCHBEND => [
        MidiStatus.pitchBend | channel,
        (value + 8192) & 0x7F,
        ((value + 8192) >> 7) & 0x7F,
      ],
      snd_seq_event_type.SND_SEQ_EVENT_CONTROL14 => _control14(event),
      snd_seq_event_type.SND_SEQ_EVENT_NONREGPARAM => _parameter(
        event,
        _nrpnControllers,
      ),
      snd_seq_event_type.SND_SEQ_EVENT_REGPARAM => _parameter(
        event,
        _rpnControllers,
      ),
      _ => null,
    };
  }

  static List<int>? _systemBytes(AlsaEvent event) {
    final value = event.value;
    return switch (event.type) {
      snd_seq_event_type.SND_SEQ_EVENT_QFRAME => [
        MidiStatus.timeCode,
        value & 0x7F,
      ],
      snd_seq_event_type.SND_SEQ_EVENT_SONGPOS => [
        MidiStatus.songPosition,
        value & 0x7F,
        (value >> 7) & 0x7F,
      ],
      snd_seq_event_type.SND_SEQ_EVENT_SONGSEL => [
        MidiStatus.songSelect,
        value & 0x7F,
      ],
      snd_seq_event_type.SND_SEQ_EVENT_TUNE_REQUEST => [MidiStatus.tuneRequest],
      snd_seq_event_type.SND_SEQ_EVENT_CLOCK => [MidiStatus.timingClock],
      snd_seq_event_type.SND_SEQ_EVENT_START => [MidiStatus.start],
      snd_seq_event_type.SND_SEQ_EVENT_CONTINUE => [
        MidiStatus.continueSequence,
      ],
      snd_seq_event_type.SND_SEQ_EVENT_STOP => [MidiStatus.stop],
      snd_seq_event_type.SND_SEQ_EVENT_SENSING => [MidiStatus.activeSensing],
      snd_seq_event_type.SND_SEQ_EVENT_RESET => [MidiStatus.systemReset],
      _ => null,
    };
  }

  /// A 14-bit controller: MSB and LSB for controllers below 32, a plain
  /// Control Change otherwise.
  static List<int> _control14(AlsaEvent event) {
    final status = MidiStatus.controlChange | (event.channel & 0x0F);
    final param = event.param;
    final value = event.value;
    if (param < 32) {
      return [
        status,
        param,
        (value >> 7) & 0x7F,
        status,
        param + 32,
        value & 0x7F,
      ];
    }
    return [status, param & 0x7F, value & 0x7F];
  }

  /// An RPN or NRPN with a 14-bit number and value as four Control Changes.
  static List<int> _parameter(AlsaEvent event, List<int> controllers) {
    final status = MidiStatus.controlChange | (event.channel & 0x0F);
    final values = [
      (event.param & 0x3F80) >> 7,
      event.param & 0x7F,
      (event.value & 0x3F80) >> 7,
      event.value & 0x7F,
    ];
    return [
      for (var i = 0; i < 4; i++) ...[status, controllers[i], values[i]],
    ];
  }

  static const _nrpnControllers = [99, 98, 6, 38];
  static const _rpnControllers = [101, 100, 6, 38];

  // ...........................................................................
  /// Packs complete short messages into MIDI 1.0 channel voice or system
  /// packets.
  static Uint32List _shortMessageWords(Uint8List bytes, int group) {
    final words = <int>[];
    var i = 0;
    while (i < bytes.length) {
      final status = bytes[i];
      final length = MidiStatus.dataLength(status) + 1;
      final type = MidiStatus.isSystem(status) ? 0x1 : 0x2;
      final d1 = length > 1 ? bytes[i + 1] : 0;
      final d2 = length > 2 ? bytes[i + 2] : 0;
      words.add(type << 28 | group << 24 | status << 16 | d1 << 8 | d2);
      i += length;
    }
    return Uint32List.fromList(words);
  }

  /// Packs one SysEx chunk into SysEx7 packets; the chunk's leading F0 and
  /// trailing F7 decide between complete, start, continue and end packets.
  static Uint32List _sysExWords(Uint8List bytes, int group) {
    final begins = bytes.isNotEmpty && bytes.first == MidiStatus.sysEx;
    final ends = bytes.isNotEmpty && bytes.last == MidiStatus.endOfSysEx;
    final payload = bytes.sublist(
      begins ? 1 : 0,
      bytes.length - (ends ? 1 : 0),
    );
    final count = payload.isEmpty
        ? (begins || ends ? 1 : 0)
        : (payload.length + 5) ~/ 6;
    final words = <int>[];
    for (var p = 0; p < count; p++) {
      final first = p == 0;
      final last = p == count - 1;
      final status = switch ((begins && first, ends && last)) {
        (true, true) => 0x0,
        (true, false) => 0x1,
        (false, true) => 0x3,
        (false, false) => 0x2,
      };
      final chunk = payload.skip(p * 6).take(6).toList();
      final data = [...chunk, ...List.filled(6 - chunk.length, 0)];
      words
        ..add(
          0x3 << 28 |
              group << 24 |
              status << 20 |
              chunk.length << 16 |
              data[0] << 8 |
              data[1],
        )
        ..add(data[2] << 24 | data[3] << 16 | data[4] << 8 | data[5]);
    }
    return Uint32List.fromList(words);
  }
}
