// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_midi_linux/src/alsa/alsa_client_info.dart';
import 'package:test/test.dart';

void main() {
  group('AlsaClientInfo', () {
    test('defaults to a legacy client without card, process and ports', () {
      const client = AlsaClientInfo(client: 128, name: 'App', type: 1);
      expect([
        client.client,
        client.name,
        client.type,
        client.card,
        client.pid,
        client.midiVersion,
        client.ports,
        client.endpoint,
        client.blocks,
      ], equals([128, 'App', 1, -1, -1, 0, isEmpty, null, isEmpty]));
    });
  });

  group('AlsaPortInfo', () {
    test('defaults to a port without direction and UMP group', () {
      const port = AlsaPortInfo(
        client: 20,
        port: 1,
        name: 'MIDI 1',
        capability: 3,
        type: 2,
      );
      expect([
        port.client,
        port.port,
        port.name,
        port.capability,
        port.type,
        port.direction,
        port.umpGroup,
        port.umpIsMidi1,
      ], equals([20, 1, 'MIDI 1', 3, 2, 0, 0, false]));
    });
  });

  group('AlsaUmpEndpointInfo', () {
    test('defaults to an endpoint without identity and blocks', () {
      const endpoint = AlsaUmpEndpointInfo(name: 'Synth');
      expect(
        [
          endpoint.name,
          endpoint.productId,
          endpoint.flags,
          endpoint.protocolCaps,
          endpoint.protocol,
          endpoint.blockCount,
          endpoint.version,
          endpoint.manufacturerId,
          endpoint.familyId,
          endpoint.modelId,
          endpoint.softwareRevision,
        ],
        equals([
          'Synth',
          '',
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          [0, 0, 0, 0],
        ]),
      );
    });
  });

  group('AlsaUmpBlockInfo', () {
    test('defaults to an active block on group 0', () {
      const block = AlsaUmpBlockInfo(blockId: 2, name: 'Main');
      expect([
        block.blockId,
        block.name,
        block.active,
        block.flags,
        block.direction,
        block.firstGroup,
        block.groupCount,
        block.midiCiVersion,
        block.sysEx8Streams,
        block.uiHint,
      ], equals([2, 'Main', true, 0, 0, 0, 1, 0, 0, 0]));
    });
  });
}
