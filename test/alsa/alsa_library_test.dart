// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:ffi';

import 'package:aud_midi_core/aud_midi_core.dart';
import 'package:aud_midi_linux/src/alsa/alsa_library.dart';
import 'package:test/test.dart';

void main() {
  group('AlsaLibrary', () {
    group('AlsaLibrary.load(name, open)', () {
      test('loads libasound.so.2 by default', () {
        final names = <String>[];
        AlsaLibrary.load(
          open: (name) {
            names.add(name);
            return DynamicLibrary.process();
          },
        );
        expect(names, [AlsaLibrary.defaultName]);
      });

      test('reports a missing library as unsupported', () {
        expect(
          () => AlsaLibrary.load(name: 'libaud_midi_missing.so.0'),
          throwsA(
            isA<MidiUnsupported>().having(
              (e) => e.feature,
              'feature',
              startsWith('ALSA: libaud_midi_missing.so.0 cannot be loaded'),
            ),
          ),
        );
      });
    });

    group('provides(symbol)', () {
      test('tells whether the library exports a symbol', () {
        final library = AlsaLibrary.load(open: (_) => DynamicLibrary.process());
        expect(
          [
            library.provides('malloc'),
            library.provides('aud_midi_does_not_exist'),
          ],
          [true, false],
        );
      });
    });

    group('bindings', () {
      test('binds the loaded library', () {
        final library = AlsaLibrary.load(open: (_) => DynamicLibrary.process());
        expect(library.bindings, isNotNull);
      });
    });
  });
}
