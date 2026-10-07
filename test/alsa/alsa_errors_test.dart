// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_midi_core/aud_midi_core.dart';
import 'package:aud_midi_linux/src/alsa/alsa_errors.dart';
import 'package:aud_midi_standard/aud_midi_standard.dart';
import 'package:test/test.dart';

void main() {
  group('AlsaErrors', () {
    group('exception(api, code)', () {
      for (final code in [AlsaErrors.eacces, AlsaErrors.eperm]) {
        test('denies the MIDI permission when opening fails with $code', () {
          expect(
            AlsaErrors.exception(api: AlsaErrors.openApi, code: -code),
            isA<MidiPermissionDenied>().having(
              (e) => e.permission,
              'permission',
              MidiPermission.midi,
            ),
          );
        });
      }

      for (final code in [
        AlsaErrors.enoent,
        AlsaErrors.enodev,
        AlsaErrors.enxio,
      ]) {
        test('reports a missing sequencer when opening fails with $code', () {
          expect(
            AlsaErrors.exception(api: AlsaErrors.openApi, code: -code),
            isA<MidiUnsupported>().having(
              (e) => e.feature,
              'feature',
              contains('/dev/snd/seq'),
            ),
          );
        });
      }

      test('reports other failures of opening as native errors', () {
        expect(
          AlsaErrors.exception(
            api: AlsaErrors.openApi,
            code: -AlsaErrors.enomem,
          ),
          isA<MidiNativeError>()
              .having((e) => e.api, 'api', 'snd_seq_open')
              .having((e) => e.code, 'code', -AlsaErrors.enomem),
        );
      });

      test('reports failures of other calls as native errors', () {
        expect(
          AlsaErrors.exception(
            api: 'snd_seq_connect_from',
            code: -AlsaErrors.eperm,
          ),
          isA<MidiNativeError>()
              .having((e) => e.api, 'api', 'snd_seq_connect_from')
              .having((e) => e.code, 'code', -AlsaErrors.eperm),
        );
      });
    });
  });
}
