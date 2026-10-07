// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// coverage:ignore-file
// Linux only: the reader isolate blocks in alsa-lib's snd_seq_event_input.
// Its loop is AlsaReaderLoop (tested on every platform); the Linux tests in
// test/alsa/ffi_alsa_reader_test.dart run this isolate on a real sequencer.

import 'dart:isolate';

import 'alsa_errors.dart';
import 'alsa_library.dart';
import 'alsa_reader_loop.dart';
import 'alsa_reader_message.dart';
import 'alsa_system.dart';
import 'ffi_alsa_sequencer.dart';

// #############################################################################
/// The arguments of the reader isolate.
typedef _ReaderArguments = ({
  String libraryName,
  int address,
  int wakeClient,
  int token,
  SendPort messages,
});

// #############################################################################
/// The reader isolate of an input handle: it blocks in
/// `snd_seq_event_input`, copies every event into Dart objects and sends
/// them to the isolate that started it.
final class FfiAlsaReader implements AlsaReader {
  FfiAlsaReader._(this.done);

  // ...........................................................................
  /// Spawns the reader for the handle at [address] of the library
  /// [libraryName]; it stops on the wake-up event with [token] from
  /// [wakeClient]. [onMessage] receives its messages in this isolate.
  static Future<FfiAlsaReader> start({
    required String libraryName,
    required int address,
    required int wakeClient,
    required int token,
    required void Function(AlsaReaderMessage message) onMessage,
  }) async {
    final messages = ReceivePort('aud_midi ALSA reader messages');
    final exit = ReceivePort('aud_midi ALSA reader exit');
    messages.listen((message) => onMessage(message as AlsaReaderMessage));
    final done = exit.first.then((_) {
      exit.close();
      messages.close();
    });
    await Isolate.spawn<_ReaderArguments>(
      _run,
      (
        libraryName: libraryName,
        address: address,
        wakeClient: wakeClient,
        token: token,
        messages: messages.sendPort,
      ),
      onExit: exit.sendPort,
      debugName: 'aud_midi ALSA reader',
    );
    return FfiAlsaReader._(done);
  }

  // ...........................................................................
  @override
  final Future<void> done;

  // ...........................................................................
  static void _run(_ReaderArguments arguments) {
    FfiAlsaSequencer? source;
    try {
      source = FfiAlsaSequencer.attach(
        AlsaLibrary.load(name: arguments.libraryName),
        arguments.address,
      );
      AlsaReaderLoop(
        source: source,
        send: arguments.messages.send,
        wakeClient: arguments.wakeClient,
        token: arguments.token,
      ).run();
    } on Object {
      arguments.messages.send(const AlsaReaderFailed(-AlsaErrors.ebadfd));
    } finally {
      source?.detach();
    }
  }
}
