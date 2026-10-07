// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

@TestOn('linux')
library;

import 'dart:io';

import 'package:aud_midi_linux/src/alsa/alsa_bindings.g.dart';
import 'package:aud_midi_linux/src/alsa/alsa_event.dart';
import 'package:aud_midi_linux/src/alsa/alsa_library.dart';
import 'package:aud_midi_linux/src/alsa/alsa_port_mapper.dart';
import 'package:aud_midi_linux/src/alsa/alsa_reader_loop.dart';
import 'package:aud_midi_linux/src/alsa/alsa_reader_message.dart';
import 'package:aud_midi_linux/src/alsa/ffi_alsa_reader.dart';
import 'package:aud_midi_linux/src/alsa/ffi_alsa_sequencer.dart';
import 'package:test/test.dart';

// Runs against the real ALSA sequencer: needs libasound2 and /dev/snd/seq
// (sudo modprobe snd-seq), e.g. on the ubuntu runners of the CI.
void main() {
  final skip = File('/dev/snd/seq').existsSync()
      ? null
      : 'needs /dev/snd/seq (sudo modprobe snd-seq)';
  const type = SND_SEQ_PORT_TYPE_MIDI_GENERIC | SND_SEQ_PORT_TYPE_APPLICATION;

  group('FfiAlsaReader', skip: skip, () {
    group('start(...)', () {
      test('reads in its isolate and stops on its wake-up event', () async {
        final library = AlsaLibrary.load();
        final output = FfiAlsaSequencer.open(library, input: false);
        final input = FfiAlsaSequencer.open(library, input: true);
        final source = output.createPort(
          name: 'source',
          capability: AlsaPortMapper.readable,
          type: type,
        );
        final destination = input.createPort(
          name: 'destination',
          capability: SND_SEQ_PORT_CAP_WRITE,
          type: type,
        );
        input.connectFrom(
          port: destination,
          client: output.clientId,
          sourcePort: source,
        );
        final messages = <AlsaReaderMessage>[];
        final reader = await FfiAlsaReader.start(
          libraryName: AlsaLibrary.defaultName,
          address: input.address,
          wakeClient: output.clientId,
          token: 42,
          onMessage: messages.add,
        );
        output.output(
          AlsaEvent.fixed(type: snd_seq_event_type.SND_SEQ_EVENT_CLOCK)
              .routed(
                sourcePort: source,
                destClient: SND_SEQ_ADDRESS_SUBSCRIBERS,
                destPort: SND_SEQ_ADDRESS_UNKNOWN,
              )
              .direct(),
        );
        final watch = Stopwatch()..start();
        while (messages.isEmpty && watch.elapsed.inSeconds < 5) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        output.output(
          AlsaReaderLoop.wakeUp(token: 42)
              .routed(
                sourcePort: source,
                destClient: input.clientId,
                destPort: destination,
              )
              .direct(),
        );
        await reader.done.timeout(const Duration(seconds: 5));
        input.close();
        output.close();
        expect(
          [
            for (final message in messages)
              switch (message) {
                AlsaReaderEvents(:final events) => [
                  for (final event in events) event.type,
                ],
                _ => message.runtimeType,
              },
          ],
          [
            [snd_seq_event_type.SND_SEQ_EVENT_CLOCK],
            AlsaReaderStopped,
          ],
        );
      });
    });
  });
}
