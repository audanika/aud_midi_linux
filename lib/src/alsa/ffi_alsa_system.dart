// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// coverage:ignore-file
// Linux only: opens alsa-lib sequencer handles and the reader isolate. The
// Linux tests in test/alsa/ffi_alsa_system_test.dart run it end to end.

import 'alsa_library.dart';
import 'alsa_monotonic_clock.dart';
import 'alsa_reader_message.dart';
import 'alsa_sequencer.dart';
import 'alsa_system.dart';
import 'ffi_alsa_reader.dart';
import 'ffi_alsa_sequencer.dart';

// #############################################################################
/// The [AlsaSystem] on top of alsa-lib (`libasound.so.2`) and libc.
///
/// The library is loaded on first use, so creating the system is cheap and
/// works on every platform.
final class FfiAlsaSystem implements AlsaSystem {
  /// Creates the system for the alsa-lib [libraryName].
  FfiAlsaSystem({this.libraryName = AlsaLibrary.defaultName});

  // ...........................................................................
  @override
  AlsaSequencer open({required bool input}) =>
      FfiAlsaSequencer.open(_library, input: input);

  @override
  Future<AlsaReader> startReader({
    required AlsaSequencer sequencer,
    required int wakeClient,
    required int token,
    required void Function(AlsaReaderMessage message) onMessage,
  }) => FfiAlsaReader.start(
    libraryName: libraryName,
    address: (sequencer as FfiAlsaSequencer).address,
    wakeClient: wakeClient,
    token: token,
    onMessage: onMessage,
  );

  @override
  int monotonicNow() => _clock.now();

  // ...........................................................................
  /// The soname of alsa-lib.
  final String libraryName;

  // ...........................................................................
  late final AlsaLibrary _library = AlsaLibrary.load(name: libraryName);
  late final AlsaMonotonicClock _clock = AlsaMonotonicClock();
}
