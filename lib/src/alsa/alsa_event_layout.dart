// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// #############################################################################
/// The byte layout of `snd_seq_event_t` and `snd_seq_ump_event_t` on Linux
/// x86_64 and aarch64 (alsa-lib `seq_event.h`).
///
/// Both start with the same 16-byte header: type, flags, tag, queue, an
/// 8-byte time stamp union and the source and destination addresses. The
/// data union follows at [data]: 12 bytes in `snd_seq_event_t` (its largest
/// members are the packed `snd_seq_ev_ext` and `snd_seq_ev_ctrl`) and 16
/// bytes in `snd_seq_ump_event_t`, which overlays four UMP words. All
/// offsets count from the start of the event.
abstract final class AlsaEventLayout {
  // ...........................................................................
  /// The event type, `snd_seq_event_type_t`.
  static const int type = 0;

  /// The flags: time stamp kind, time mode, length kind, priority, UMP.
  static const int flags = 1;

  /// The tag the sender chose, used to remove queued events.
  static const int tag = 2;

  /// The queue the event is scheduled on.
  static const int queue = 3;

  /// The tick time, or the seconds of the real time.
  static const int time = 4;

  /// The nanoseconds of the real time.
  static const int timeNanoseconds = 8;

  /// The client of the source address.
  static const int sourceClient = 12;

  /// The port of the source address.
  static const int sourcePort = 13;

  /// The client of the destination address.
  static const int destClient = 14;

  /// The port of the destination address.
  static const int destPort = 15;

  /// The start of the data union.
  static const int data = 16;

  // ...........................................................................
  /// `data.note.channel` and `data.control.channel`.
  static const int channel = 16;

  /// `data.note.note`.
  static const int note = 17;

  /// `data.note.velocity`.
  static const int velocity = 18;

  /// `data.note.off_velocity`.
  static const int offVelocity = 19;

  /// `data.note.duration`, 32 bits.
  static const int duration = 20;

  /// `data.control.param`, 32 bits.
  static const int param = 20;

  /// `data.control.value`, signed 32 bits.
  static const int value = 24;

  /// `data.ext.len`, 32 bits.
  static const int extLength = 16;

  /// `data.ext.ptr`, a 64-bit pointer right after the length (packed).
  static const int extPointer = 20;

  /// `data.queue.queue`.
  static const int queueControlQueue = 16;

  /// `data.queue.param.value`, signed 32 bits.
  static const int queueControlValue = 20;

  /// `data.addr.client`, e.g. of an announce event.
  static const int addrClient = 16;

  /// `data.addr.port`.
  static const int addrPort = 17;

  /// `ump[0]` of `snd_seq_ump_event_t`; the other words follow.
  static const int ump = 16;

  // ...........................................................................
  /// The size of `snd_seq_event_t`.
  static const int legacySize = 28;

  /// The size of `snd_seq_ump_event_t`.
  static const int umpSize = 32;

  /// The size of the data union of `snd_seq_event_t`.
  static const int legacyDataSize = 12;

  /// The size of the data union of `snd_seq_ump_event_t`.
  static const int umpDataSize = 16;
}
