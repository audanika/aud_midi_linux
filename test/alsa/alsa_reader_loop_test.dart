// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:typed_data';

import 'package:aud_midi_linux/src/alsa/alsa_bindings.g.dart';
import 'package:aud_midi_linux/src/alsa/alsa_errors.dart';
import 'package:aud_midi_linux/src/alsa/alsa_event.dart';
import 'package:aud_midi_linux/src/alsa/alsa_event_layout.dart';
import 'package:aud_midi_linux/src/alsa/alsa_event_source.dart';
import 'package:aud_midi_linux/src/alsa/alsa_reader_loop.dart';
import 'package:aud_midi_linux/src/alsa/alsa_reader_message.dart';
import 'package:test/test.dart';

/// Hands out batches of results: [pending] reports the rest of the
/// current batch, like alsa-lib's input buffer.
final class _BatchSource implements AlsaEventSource {
  _BatchSource(this._batches);

  final List<List<AlsaReadResult>> _batches;
  var _index = 0;

  @override
  AlsaReadResult read() {
    final batch = _batches.first;
    final result = batch[_index++];
    if (_index == batch.length) {
      _batches.removeAt(0);
      _index = 0;
    }
    return result;
  }

  @override
  int pending() => _index == 0 ? 0 : _batches.first.length - _index;
}

void main() {
  const wakeClient = 128;
  const token = 0xC0FFEE;

  AlsaReadResult ok(AlsaEvent event) => (event: event, error: 0);
  AlsaReadResult fail(int errno) => (event: null, error: -errno);

  AlsaEvent note(int number) => AlsaEvent.note(
    type: snd_seq_event_type.SND_SEQ_EVENT_NOTEON,
    channel: 0,
    note: number,
    velocity: 100,
  );

  AlsaEvent fromClient(AlsaEvent event, int client) {
    final cell = Uint8List.fromList(event.cell)
      ..[AlsaEventLayout.sourceClient] = client;
    return AlsaEvent(cell: cell);
  }

  AlsaEvent wakeUp({int client = wakeClient, int value = token}) =>
      fromClient(AlsaReaderLoop.wakeUp(token: value), client);

  List<Object> run(List<List<AlsaReadResult>> batches) {
    final messages = <Object>[];
    AlsaReaderLoop(
      source: _BatchSource(batches),
      send: (message) => messages.add(switch (message) {
        AlsaReaderEvents(:final events) => events,
        AlsaReaderOverflow() => 'overflow',
        AlsaReaderFailed(:final code) => code,
        AlsaReaderStopped() => 'stopped',
      }),
      wakeClient: wakeClient,
      token: token,
    ).run();
    return messages;
  }

  group('AlsaReaderLoop', () {
    group('run()', () {
      test('sends what one read brings in as one batch', () {
        expect(
          run([
            [ok(note(60)), ok(note(61))],
            [ok(note(62))],
            [ok(wakeUp())],
          ]),
          equals([
            [note(60), note(61)],
            [note(62)],
            'stopped',
          ]),
        );
      });

      test('sends the events before the wake-up event, then stops', () {
        expect(
          run([
            [ok(note(60)), ok(wakeUp()), ok(note(61))],
          ]),
          equals([
            [note(60)],
            'stopped',
          ]),
        );
      });

      test('ignores wake-up events of other clients or tokens', () {
        final foreign = wakeUp(client: 129);
        final forged = wakeUp(value: 1);
        expect(
          run([
            [ok(foreign), ok(forged)],
            [ok(wakeUp())],
          ]),
          equals([
            [foreign, forged],
            'stopped',
          ]),
        );
      });

      test('reports overruns and goes on', () {
        expect(
          run([
            [ok(note(60)), fail(AlsaErrors.enospc)],
            [fail(AlsaErrors.eagain)],
            [fail(AlsaErrors.eintr)],
            [ok(wakeUp())],
          ]),
          equals([
            [note(60)],
            'overflow',
            'stopped',
          ]),
        );
      });

      test('reports other errors and ends', () {
        expect(
          run([
            [fail(AlsaErrors.enodev)],
          ]),
          equals([-AlsaErrors.enodev]),
        );
      });
    });

    group('wakeUp(token)', () {
      test('creates a user event carrying the token', () {
        final event = AlsaReaderLoop.wakeUp(token: token);
        expect([
          event.type,
          event.word(0),
        ], equals([snd_seq_event_type.SND_SEQ_EVENT_USR0, token]));
      });
    });
  });
}
