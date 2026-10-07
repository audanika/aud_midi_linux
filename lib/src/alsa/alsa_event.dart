// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:typed_data';

import 'alsa_bindings.g.dart';
import 'alsa_event_layout.dart';

// #############################################################################
/// One ALSA sequencer event as plain Dart data.
///
/// [cell] holds the bytes of `snd_seq_event_t` (28 bytes) or, for UMP
/// events, `snd_seq_ump_event_t` (32 bytes) as laid out in
/// [AlsaEventLayout]; [ext] holds the external data of a variable-length
/// event such as SysEx. The native layer copies events into this form and
/// back, so everything else works on Dart objects that can cross isolates.
final class AlsaEvent {
  /// Creates an event from a copy of [cell] and [ext].
  AlsaEvent({required List<int> cell, List<int>? ext})
    : assert(
        cell.length == AlsaEventLayout.legacySize ||
            cell.length == AlsaEventLayout.umpSize,
      ),
      cell = Uint8List.fromList(cell).asUnmodifiableView(),
      ext = ext == null ? null : Uint8List.fromList(ext).asUnmodifiableView();

  // ...........................................................................
  /// Creates a fixed-length event of [type] whose data union starts with
  /// [data].
  factory AlsaEvent.fixed({required int type, List<int> data = const []}) {
    final cell = Uint8List(AlsaEventLayout.legacySize);
    cell[AlsaEventLayout.type] = type;
    cell.setAll(AlsaEventLayout.data, data);
    return AlsaEvent(cell: cell);
  }

  /// Creates a note event of [type] (note on, note off or key pressure).
  factory AlsaEvent.note({
    required int type,
    required int channel,
    required int note,
    required int velocity,
  }) => AlsaEvent.fixed(type: type, data: [channel, note, velocity]);

  /// Creates a control event of [type], e.g. a controller with [param] and
  /// [value] or a program change with [value].
  factory AlsaEvent.control({
    required int type,
    required int channel,
    int param = 0,
    int value = 0,
  }) {
    final data = ByteData(AlsaEventLayout.legacyDataSize)
      ..setUint8(0, channel)
      ..setUint32(4, param, Endian.host)
      ..setInt32(8, value, Endian.host);
    return AlsaEvent.fixed(type: type, data: data.buffer.asUint8List());
  }

  /// Creates a variable-length SysEx event carrying [bytes], a complete
  /// System Exclusive message or a part of one.
  factory AlsaEvent.sysEx(List<int> bytes) {
    final cell = Uint8List(AlsaEventLayout.legacySize);
    cell[AlsaEventLayout.type] = snd_seq_event_type.SND_SEQ_EVENT_SYSEX;
    cell[AlsaEventLayout.flags] = SND_SEQ_EVENT_LENGTH_VARIABLE;
    ByteData.sublistView(
      cell,
    ).setUint32(AlsaEventLayout.extLength, bytes.length, Endian.host);
    return AlsaEvent(cell: cell, ext: bytes);
  }

  /// Creates a UMP event carrying the one to four [words] of one Universal
  /// MIDI Packet.
  factory AlsaEvent.ump(List<int> words) {
    assert(words.isNotEmpty && words.length <= 4);
    final cell = Uint8List(AlsaEventLayout.umpSize);
    cell[AlsaEventLayout.flags] = SND_SEQ_EVENT_UMP;
    final data = ByteData.sublistView(cell);
    for (var i = 0; i < words.length; i++) {
      data.setUint32(AlsaEventLayout.ump + 4 * i, words[i], Endian.host);
    }
    return AlsaEvent(cell: cell);
  }

  // ...........................................................................
  /// Returns a copy sent from [sourcePort] of the sending client to
  /// [destClient]:[destPort] with [tag].
  AlsaEvent routed({
    required int sourcePort,
    required int destClient,
    required int destPort,
    int tag = 0,
  }) => _copy((cell, _) {
    cell[AlsaEventLayout.sourcePort] = sourcePort;
    cell[AlsaEventLayout.destClient] = destClient;
    cell[AlsaEventLayout.destPort] = destPort;
    cell[AlsaEventLayout.tag] = tag;
  });

  /// Returns a copy that the sequencer delivers right away, without queue.
  AlsaEvent direct() => _copy((cell, data) {
    cell[AlsaEventLayout.queue] = SND_SEQ_QUEUE_DIRECT;
    cell[AlsaEventLayout.flags] &= ~_timeBits;
    data
      ..setUint32(AlsaEventLayout.time, 0, Endian.host)
      ..setUint32(AlsaEventLayout.timeNanoseconds, 0, Endian.host);
  });

  /// Returns a copy scheduled on [queue] at the absolute real time
  /// [microseconds] of that queue.
  AlsaEvent scheduled({required int queue, required int microseconds}) =>
      _copy((cell, data) {
        cell[AlsaEventLayout.queue] = queue;
        cell[AlsaEventLayout.flags] =
            (cell[AlsaEventLayout.flags] & ~_timeBits) |
            SND_SEQ_TIME_STAMP_REAL |
            SND_SEQ_TIME_MODE_ABS;
        data
          ..setUint32(
            AlsaEventLayout.time,
            microseconds ~/ Duration.microsecondsPerSecond,
            Endian.host,
          )
          ..setUint32(
            AlsaEventLayout.timeNanoseconds,
            microseconds % Duration.microsecondsPerSecond * 1000,
            Endian.host,
          );
      });

  // ...........................................................................
  /// The bytes of `snd_seq_event_t` or `snd_seq_ump_event_t`.
  final Uint8List cell;

  /// The external data of a variable-length event, or null.
  final Uint8List? ext;

  /// The event type.
  int get type => cell[AlsaEventLayout.type];

  /// The event flags.
  int get flags => cell[AlsaEventLayout.flags];

  /// The tag of the event.
  int get tag => cell[AlsaEventLayout.tag];

  /// The queue of the event.
  int get queue => cell[AlsaEventLayout.queue];

  /// The client of the source address.
  int get sourceClient => cell[AlsaEventLayout.sourceClient];

  /// The port of the source address.
  int get sourcePort => cell[AlsaEventLayout.sourcePort];

  /// The client of the destination address.
  int get destClient => cell[AlsaEventLayout.destClient];

  /// The port of the destination address.
  int get destPort => cell[AlsaEventLayout.destPort];

  /// Whether the event carries a Universal MIDI Packet.
  bool get isUmp => flags & SND_SEQ_EVENT_UMP != 0;

  /// Whether the event has external data of variable length.
  bool get isVariable =>
      flags & SND_SEQ_EVENT_LENGTH_MASK == SND_SEQ_EVENT_LENGTH_VARIABLE;

  /// Whether the time stamp is a real time (not a tick time).
  bool get hasRealTime =>
      flags & SND_SEQ_TIME_STAMP_MASK == SND_SEQ_TIME_STAMP_REAL;

  /// The real time stamp in microseconds.
  int get realTimeMicroseconds =>
      _uint32(AlsaEventLayout.time) * Duration.microsecondsPerSecond +
      _uint32(AlsaEventLayout.timeNanoseconds) ~/ 1000;

  /// The channel of a note or control event.
  int get channel => cell[AlsaEventLayout.channel];

  /// The note number of a note event.
  int get note => cell[AlsaEventLayout.note];

  /// The velocity of a note event.
  int get velocity => cell[AlsaEventLayout.velocity];

  /// The parameter of a control event, e.g. the controller number.
  int get param => _uint32(AlsaEventLayout.param);

  /// The signed value of a control event.
  int get value =>
      ByteData.sublistView(cell).getInt32(AlsaEventLayout.value, Endian.host);

  /// The client of the address in the data of an announce event.
  int get addrClient => cell[AlsaEventLayout.addrClient];

  /// The port of the address in the data of an announce event.
  int get addrPort => cell[AlsaEventLayout.addrPort];

  /// Returns the 32-bit word [index] of the data union, e.g. a UMP word.
  int word(int index) => _uint32(AlsaEventLayout.data + 4 * index);

  // ...........................................................................
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AlsaEvent &&
          _sameBytes(other.cell, cell) &&
          _sameBytes(other.ext, ext);

  @override
  int get hashCode =>
      Object.hash(Object.hashAll(cell), Object.hashAll(ext ?? []));

  @override
  String toString() {
    final hex = [for (final b in cell) b.toRadixString(16).padLeft(2, '0')];
    final extText = ext == null ? '' : ', ext: ${ext!.length} bytes';
    return 'AlsaEvent(type: $type, cell: ${hex.join(' ')}$extText)';
  }

  // ...........................................................................
  static const _timeBits = SND_SEQ_TIME_STAMP_MASK | SND_SEQ_TIME_MODE_MASK;

  int _uint32(int offset) =>
      ByteData.sublistView(cell).getUint32(offset, Endian.host);

  AlsaEvent _copy(void Function(Uint8List cell, ByteData data) change) {
    final copy = Uint8List.fromList(cell);
    change(copy, ByteData.sublistView(copy));
    return AlsaEvent(cell: copy, ext: ext);
  }

  static bool _sameBytes(Uint8List? a, Uint8List? b) {
    if (a == null || b == null) return a == b;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
