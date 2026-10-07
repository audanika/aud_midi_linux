// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_midi_standard/aud_midi_standard.dart';

import 'alsa_bindings.g.dart';
import 'alsa_event.dart';

// #############################################################################
/// The events an [AlsaEventEncoder] made from a chunk of data and the
/// number of bytes or words it had to skip.
typedef AlsaEncoded = ({List<AlsaEvent> events, int skipped});

// #############################################################################
/// Turns the MIDI 1.0 bytes or UMP words the app sends into ALSA sequencer
/// events.
///
/// One encoder serves one output and keeps its state across chunks: the
/// running status and an unfinished System Exclusive message. SysEx goes
/// out as variable-length events of at most [maxSysExChunk] bytes, like the
/// chunks the kernel's rawmidi bridge produces; real-time bytes inside a
/// SysEx become events of their own between the chunks. Stray data bytes
/// and undefined statuses are skipped and counted.
final class AlsaEventEncoder {
  /// Creates an encoder that splits SysEx into events of at most
  /// [maxSysExChunk] bytes.
  AlsaEventEncoder({this.maxSysExChunk = 256}) : assert(maxSysExChunk > 0);

  // ...........................................................................
  /// Converts [bytes] into events in their order.
  AlsaEncoded encodeBytes(List<int> bytes) {
    final events = <AlsaEvent>[];
    var skipped = 0;
    for (final byte in bytes) {
      if (!_add(byte & 0xFF, events)) skipped++;
    }
    _flushSysEx(events);
    return (events: events, skipped: skipped);
  }

  /// Forgets the running status and an unfinished SysEx.
  void reset() {
    _status = 0;
    _data.clear();
    _sysEx = null;
  }

  // ...........................................................................
  /// The largest SysEx event in bytes.
  final int maxSysExChunk;

  // ...........................................................................
  /// Splits [words] into one UMP event per packet; the words of an
  /// incomplete last packet are skipped.
  static AlsaEncoded encodeUmp(List<int> words) {
    final events = <AlsaEvent>[];
    var i = 0;
    while (i < words.length) {
      final size = Ump.sizeOf(words[i]);
      if (i + size > words.length) break;
      events.add(AlsaEvent.ump(words.sublist(i, i + size)));
      i += size;
    }
    return (events: events, skipped: words.length - i);
  }

  // ...........................................................................
  int _status = 0;
  final _data = <int>[];
  List<int>? _sysEx;

  /// Adds one byte; returns false when the byte had to be skipped.
  bool _add(int byte, List<AlsaEvent> events) {
    if (MidiStatus.isRealTime(byte)) return _addRealTime(byte, events);
    if (byte == MidiStatus.endOfSysEx) return _endSysEx(events);
    if (MidiStatus.isStatus(byte)) return _addStatus(byte, events);
    final sysEx = _sysEx;
    if (sysEx != null) {
      sysEx.add(byte);
      if (sysEx.length >= maxSysExChunk) _flushSysEx(events);
      return true;
    }
    return _addData(byte, events);
  }

  bool _addRealTime(int byte, List<AlsaEvent> events) {
    final type = _realTimeTypes[byte];
    if (type == null) return false;
    _flushSysEx(events);
    events.add(AlsaEvent.fixed(type: type));
    return true;
  }

  bool _endSysEx(List<AlsaEvent> events) {
    final sysEx = _sysEx;
    if (sysEx == null) return false;
    sysEx.add(MidiStatus.endOfSysEx);
    _flushSysEx(events);
    _sysEx = null;
    return true;
  }

  bool _addStatus(int byte, List<AlsaEvent> events) {
    _flushSysEx(events);
    _sysEx = null;
    _data.clear();
    _status = 0;
    if (byte == MidiStatus.sysEx) {
      _sysEx = [byte];
      return true;
    }
    if (byte == MidiStatus.tuneRequest) {
      events.add(
        AlsaEvent.fixed(type: snd_seq_event_type.SND_SEQ_EVENT_TUNE_REQUEST),
      );
      return true;
    }
    if (MidiStatus.isSystem(byte) && MidiStatus.dataLength(byte) == 0) {
      return false;
    }
    _status = byte;
    return true;
  }

  bool _addData(int byte, List<AlsaEvent> events) {
    if (_status == 0) return false;
    _data.add(byte);
    if (_data.length < MidiStatus.dataLength(_status)) return true;
    events.add(_message(_status, _data));
    _data.clear();
    // System common messages have no running status.
    if (MidiStatus.isSystem(_status)) _status = 0;
    return true;
  }

  /// Moves the collected SysEx bytes into an event, if there are any.
  void _flushSysEx(List<AlsaEvent> events) {
    final sysEx = _sysEx;
    if (sysEx == null || sysEx.isEmpty) return;
    events.add(AlsaEvent.sysEx(sysEx));
    _sysEx = [];
  }

  // ...........................................................................
  static AlsaEvent _message(int status, List<int> data) {
    final channel = status & 0x0F;
    final d1 = data[0];
    final d2 = data.length > 1 ? data[1] : 0;
    return switch (MidiStatus.typeOf(status)) {
      MidiStatus.noteOff => _note(_noteOff, channel, d1, d2),
      MidiStatus.noteOn => _note(_noteOn, channel, d1, d2),
      MidiStatus.polyPressure => _note(_keyPress, channel, d1, d2),
      MidiStatus.controlChange => AlsaEvent.control(
        type: snd_seq_event_type.SND_SEQ_EVENT_CONTROLLER,
        channel: channel,
        param: d1,
        value: d2,
      ),
      MidiStatus.programChange => _control(_programChange, channel, d1),
      MidiStatus.channelPressure => _control(_channelPressure, channel, d1),
      MidiStatus.pitchBend => _control(
        snd_seq_event_type.SND_SEQ_EVENT_PITCHBEND,
        channel,
        (d2 << 7 | d1) - 8192,
      ),
      MidiStatus.timeCode => _control(_quarterFrame, 0, d1),
      MidiStatus.songPosition => _control(_songPosition, 0, d2 << 7 | d1),
      _ => _control(snd_seq_event_type.SND_SEQ_EVENT_SONGSEL, 0, d1),
    };
  }

  static AlsaEvent _note(int type, int channel, int note, int velocity) =>
      AlsaEvent.note(
        type: type,
        channel: channel,
        note: note,
        velocity: velocity,
      );

  static AlsaEvent _control(int type, int channel, int value) =>
      AlsaEvent.control(type: type, channel: channel, value: value);

  static const _noteOff = snd_seq_event_type.SND_SEQ_EVENT_NOTEOFF;
  static const _noteOn = snd_seq_event_type.SND_SEQ_EVENT_NOTEON;
  static const _keyPress = snd_seq_event_type.SND_SEQ_EVENT_KEYPRESS;
  static const _programChange = snd_seq_event_type.SND_SEQ_EVENT_PGMCHANGE;
  static const _channelPressure = snd_seq_event_type.SND_SEQ_EVENT_CHANPRESS;
  static const _quarterFrame = snd_seq_event_type.SND_SEQ_EVENT_QFRAME;
  static const _songPosition = snd_seq_event_type.SND_SEQ_EVENT_SONGPOS;

  static const _realTimeTypes = {
    MidiStatus.timingClock: snd_seq_event_type.SND_SEQ_EVENT_CLOCK,
    MidiStatus.start: snd_seq_event_type.SND_SEQ_EVENT_START,
    MidiStatus.continueSequence: snd_seq_event_type.SND_SEQ_EVENT_CONTINUE,
    MidiStatus.stop: snd_seq_event_type.SND_SEQ_EVENT_STOP,
    MidiStatus.activeSensing: snd_seq_event_type.SND_SEQ_EVENT_SENSING,
    MidiStatus.systemReset: snd_seq_event_type.SND_SEQ_EVENT_RESET,
  };
}
