// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_midi_linux/src/alsa/alsa_reader_message.dart';
import 'package:aud_midi_linux/src/alsa/alsa_sequencer.dart';
import 'package:aud_midi_linux/src/alsa/alsa_system.dart';
import 'package:test/test.dart';

/// A system whose reader ends at once.
final class _System implements AlsaSystem {
  @override
  AlsaSequencer open({required bool input}) =>
      throw UnsupportedError('no sequencer');

  @override
  Future<AlsaReader> startReader({
    required AlsaSequencer sequencer,
    required int wakeClient,
    required int token,
    required void Function(AlsaReaderMessage message) onMessage,
  }) async {
    onMessage(const AlsaReaderStopped());
    return _Reader();
  }

  @override
  int monotonicNow() => 42;
}

final class _Reader implements AlsaReader {
  @override
  Future<void> get done => Future.value();
}

void main() {
  group('AlsaSystem', () {
    test('opens handles, starts readers and reads the clock', () async {
      final system = _System();
      final messages = <AlsaReaderMessage>[];
      expect(() => system.open(input: true), throwsUnsupportedError);
      final reader = await system.startReader(
        sequencer: _NoSequencer(),
        wakeClient: 128,
        token: 1,
        onMessage: messages.add,
      );
      await reader.done;
      expect(
        [system.monotonicNow(), messages.single],
        [42, isA<AlsaReaderStopped>()],
      );
    });
  });
}

final class _NoSequencer implements AlsaSequencer {
  @override
  Object? noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
