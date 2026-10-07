// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_midi_linux/src/alsa/alsa_event.dart';
import 'package:aud_midi_linux/src/alsa/alsa_event_source.dart';
import 'package:test/test.dart';

/// A source that hands out a list of results.
final class _ListSource implements AlsaEventSource {
  _ListSource(this._results);

  final List<AlsaReadResult> _results;

  @override
  AlsaReadResult read() => _results.removeAt(0);

  @override
  int pending() => _results.length;
}

void main() {
  group('AlsaEventSource', () {
    test('reads events or error numbers', () {
      final event = AlsaEvent.fixed(type: 6);
      final source = _ListSource([
        (event: event, error: 0),
        (event: null, error: -28),
      ]);
      expect([
        source.pending(),
        source.read(),
        source.read(),
        source.pending(),
      ], equals([2, (event: event, error: 0), (event: null, error: -28), 0]));
    });
  });
}
