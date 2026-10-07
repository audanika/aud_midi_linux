// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_midi_core/aud_midi_core.dart';
import 'package:aud_midi_standard/aud_midi_standard.dart';

// #############################################################################
/// The Linux error numbers alsa-lib returns (negated) and their mapping to
/// the exceptions of the aud_midi family.
///
/// The values are those of `asm-generic/errno-base.h` and
/// `asm-generic/errno.h`, shared by x86_64 and aarch64.
abstract final class AlsaErrors {
  // ...........................................................................
  /// Returns the exception for the call [api] that failed with the negative
  /// error number [code].
  ///
  /// Opening the sequencer fails with `EACCES` or `EPERM` when the user may
  /// not use `/dev/snd/seq`, and with `ENOENT`, `ENODEV` or `ENXIO` when the
  /// kernel module `snd-seq` is missing; every other failure is a
  /// [MidiNativeError].
  static MidiException exception({required String api, required int code}) {
    if (api == openApi) {
      switch (-code) {
        case eacces || eperm:
          return const MidiPermissionDenied(MidiPermission.midi);
        case enoent || enodev || enxio:
          return const MidiUnsupported(
            'the ALSA sequencer (/dev/snd/seq, kernel module snd-seq)',
          );
      }
    }
    return MidiNativeError(api: api, code: code);
  }

  // ...........................................................................
  /// The call that opens a sequencer handle.
  static const String openApi = 'snd_seq_open';

  /// Operation not permitted.
  static const int eperm = 1;

  /// No such file or directory.
  static const int enoent = 2;

  /// Interrupted system call.
  static const int eintr = 4;

  /// No such device or address.
  static const int enxio = 6;

  /// Try again: a non-blocking call would block.
  static const int eagain = 11;

  /// Out of memory.
  static const int enomem = 12;

  /// Permission denied.
  static const int eacces = 13;

  /// Device or resource busy.
  static const int ebusy = 16;

  /// No such device.
  static const int enodev = 19;

  /// Invalid argument.
  static const int einval = 22;

  /// No space left: the sequencer input FIFO overran and was cleared.
  static const int enospc = 28;

  /// File descriptor in bad state, e.g. a UMP call on a legacy client.
  static const int ebadfd = 77;
}
