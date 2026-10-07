// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:ffi';

import 'package:aud_midi_linux/src/alsa/alsa_bindings.g.dart';
import 'package:aud_midi_linux/src/alsa/alsa_event_layout.dart';
import 'package:ffi/ffi.dart';
import 'package:test/test.dart';

void main() {
  // Writes a marker through a generated struct accessor and returns the
  // offset of the first byte it changed: the offset of the field on this
  // LP64 little-endian host, the same as on Linux x86_64 and aarch64.
  int offsetOf(void Function(Pointer<Uint8> memory) write) {
    final memory = calloc<Uint8>(64);
    try {
      write(memory);
      for (var i = 0; i < 64; i++) {
        if (memory[i] != 0) return i;
      }
      return -1;
    } finally {
      calloc.free(memory);
    }
  }

  snd_seq_event event(Pointer<Uint8> memory) =>
      memory.cast<snd_seq_event>().ref;

  group('AlsaEventLayout', () {
    test('has the sizes of the generated structs', () {
      expect(
        [
          sizeOf<snd_seq_event>(),
          sizeOf<snd_seq_ump_event>(),
          sizeOf<snd_seq_event_data>(),
          sizeOf<snd_seq_ump_event_data>(),
          sizeOf<snd_seq_ev_ext>(),
          sizeOf<snd_seq_ev_ctrl>(),
          sizeOf<snd_seq_timestamp>(),
        ],
        equals([
          AlsaEventLayout.legacySize,
          AlsaEventLayout.umpSize,
          AlsaEventLayout.legacyDataSize,
          AlsaEventLayout.umpDataSize,
          12,
          12,
          8,
        ]),
      );
    });

    test('has the offsets of the snd_seq_event_t header', () {
      expect(
        [
          offsetOf((m) => event(m).type = 1),
          offsetOf((m) => event(m).flags = 1),
          offsetOf((m) => event(m).tag = 1),
          offsetOf((m) => event(m).queue = 1),
          offsetOf((m) => event(m).time.time.tv_sec = 1),
          offsetOf((m) => event(m).time.tick = 1),
          offsetOf((m) => event(m).time.time.tv_nsec = 1),
          offsetOf((m) => event(m).source.client = 1),
          offsetOf((m) => event(m).source.port = 1),
          offsetOf((m) => event(m).dest.client = 1),
          offsetOf((m) => event(m).dest.port = 1),
        ],
        equals([
          AlsaEventLayout.type,
          AlsaEventLayout.flags,
          AlsaEventLayout.tag,
          AlsaEventLayout.queue,
          AlsaEventLayout.time,
          AlsaEventLayout.time,
          AlsaEventLayout.timeNanoseconds,
          AlsaEventLayout.sourceClient,
          AlsaEventLayout.sourcePort,
          AlsaEventLayout.destClient,
          AlsaEventLayout.destPort,
        ]),
      );
    });

    test('has the offsets of the snd_seq_event_t data union', () {
      expect(
        [
          offsetOf((m) => event(m).data.note.channel = 1),
          offsetOf((m) => event(m).data.note.note = 1),
          offsetOf((m) => event(m).data.note.velocity = 1),
          offsetOf((m) => event(m).data.note.off_velocity = 1),
          offsetOf((m) => event(m).data.note.duration = 1),
          offsetOf((m) => event(m).data.control.channel = 1),
          offsetOf((m) => event(m).data.control.param = 1),
          offsetOf((m) => event(m).data.control.value = 1),
          offsetOf((m) => event(m).data.ext.len = 1),
          offsetOf((m) => event(m).data.ext.ptr = Pointer.fromAddress(1)),
          offsetOf((m) => event(m).data.queue.queue = 1),
          offsetOf((m) => event(m).data.queue.param.value = 1),
          offsetOf((m) => event(m).data.addr.client = 1),
          offsetOf((m) => event(m).data.addr.port = 1),
          offsetOf((m) => event(m).data.raw32.d[2] = 1),
        ],
        equals([
          AlsaEventLayout.channel,
          AlsaEventLayout.note,
          AlsaEventLayout.velocity,
          AlsaEventLayout.offVelocity,
          AlsaEventLayout.duration,
          AlsaEventLayout.channel,
          AlsaEventLayout.param,
          AlsaEventLayout.value,
          AlsaEventLayout.extLength,
          AlsaEventLayout.extPointer,
          AlsaEventLayout.queueControlQueue,
          AlsaEventLayout.queueControlValue,
          AlsaEventLayout.addrClient,
          AlsaEventLayout.addrPort,
          AlsaEventLayout.data + 8,
        ]),
      );
    });

    test('has the offsets of snd_seq_ump_event_t', () {
      snd_seq_ump_event ump(Pointer<Uint8> m) =>
          m.cast<snd_seq_ump_event>().ref;
      expect(
        [
          offsetOf((m) => ump(m).flags = 1),
          offsetOf((m) => ump(m).time.time.tv_nsec = 1),
          offsetOf((m) => ump(m).dest.port = 1),
          offsetOf((m) => ump(m).payload.ump[0] = 1),
          offsetOf((m) => ump(m).payload.ump[3] = 1),
          offsetOf((m) => ump(m).payload.data.control.value = 1),
        ],
        equals([
          AlsaEventLayout.flags,
          AlsaEventLayout.timeNanoseconds,
          AlsaEventLayout.destPort,
          AlsaEventLayout.ump,
          AlsaEventLayout.ump + 12,
          AlsaEventLayout.value,
        ]),
      );
    });
  });
}
