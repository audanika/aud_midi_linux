// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_midi_linux/src/alsa/alsa_port_diff.dart';
import 'package:aud_midi_standard/aud_midi_standard.dart';
import 'package:test/test.dart';

void main() {
  MidiPortInfo port(String id, {String name = 'Port'}) => MidiPortInfo(
    id: MidiPortId(id),
    name: name,
    direction: MidiDirection.input,
  );

  group('AlsaPortDiff', () {
    group('events(before, after)', () {
      test('reports removed, changed and added ports in this order', () {
        final kept = port('alsa:14:0:in');
        final before = [kept, port('alsa:20:0:in'), port('alsa:24:0:in')];
        final after = [
          kept,
          port('alsa:24:0:in', name: 'Renamed'),
          port('alsa:28:0:in'),
        ];
        expect(
          AlsaPortDiff.events(before: before, after: after),
          equals([
            MidiPortRemoved(
              port: port(
                'alsa:20:0:in',
              ).copyWith(state: MidiPortState.disconnected),
            ),
            MidiPortChanged(
              port: port('alsa:24:0:in', name: 'Renamed'),
              previous: port('alsa:24:0:in'),
            ),
            MidiPortAdded(port: port('alsa:28:0:in')),
          ]),
        );
      });

      test('reports nothing for equal lists', () {
        expect(
          AlsaPortDiff.events(
            before: [port('alsa:14:0:in')],
            after: [port('alsa:14:0:in')],
          ),
          isEmpty,
        );
      });
    });
  });
}
