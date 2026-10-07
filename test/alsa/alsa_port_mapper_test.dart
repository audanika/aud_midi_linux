// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_midi_core/aud_midi_core.dart';
import 'package:aud_midi_linux/src/alsa/alsa_bindings.g.dart';
import 'package:aud_midi_linux/src/alsa/alsa_client_info.dart';
import 'package:aud_midi_linux/src/alsa/alsa_port_mapper.dart';
import 'package:aud_midi_standard/aud_midi_standard.dart';
import 'package:test/test.dart';

void main() {
  const kernel = snd_seq_client_type.SND_SEQ_KERNEL_CLIENT;
  const user = snd_seq_client_type.SND_SEQ_USER_CLIENT;
  const midi = SND_SEQ_PORT_TYPE_MIDI_GENERIC;
  const duplex = AlsaPortMapper.readable | AlsaPortMapper.writable;

  late AlsaPortMapper mapper;

  setUp(() => mapper = AlsaPortMapper(isUsbCard: (card) => card == 1));

  AlsaPortInfo port(
    int client,
    int number, {
    String name = 'Port',
    int capability = duplex,
    int type = midi,
    int umpGroup = 0,
    bool umpIsMidi1 = false,
  }) => AlsaPortInfo(
    client: client,
    port: number,
    name: name,
    capability: capability,
    type: type,
    umpGroup: umpGroup,
    umpIsMidi1: umpIsMidi1,
  );

  List<MidiPortInfo> map(
    List<AlsaClientInfo> clients, {
    bool ump = false,
    bool? umpOut,
    Map<int, int> generations = const {},
    Map<({int client, int port}), int> portGenerations = const {},
  }) => mapper.map(
    clients,
    ownClients: {128, 129},
    umpIn: ump,
    umpOut: umpOut ?? ump,
    generations: generations,
    portGenerations: portGenerations,
  );

  group('AlsaPortMapper', () {
    group('map(clients, ownClients, ump, generations)', () {
      test('maps readable ports to inputs and writable ones to outputs', () {
        final ports = map([
          AlsaClientInfo(
            client: 20,
            name: 'Keys',
            type: kernel,
            card: 1,
            ports: [
              port(20, 0, name: 'Keys MIDI 1'),
              port(20, 1, name: 'Out', capability: AlsaPortMapper.readable),
              port(20, 2, name: 'In', capability: AlsaPortMapper.writable),
            ],
          ),
        ]);
        expect(
          [
            for (final p in ports)
              [p.id.value, p.deviceId?.value, p.name, p.direction, p.index],
          ],
          equals([
            ['alsa:20:0:in', 'alsa:20', 'Keys MIDI 1', MidiDirection.input, 0],
            [
              'alsa:20:0:out',
              'alsa:20',
              'Keys MIDI 1',
              MidiDirection.output,
              0,
            ],
            ['alsa:20:1:in', 'alsa:20', 'Keys: Out', MidiDirection.input, 1],
            ['alsa:20:2:out', 'alsa:20', 'Keys: In', MidiDirection.output, 2],
          ]),
        );
      });

      test('leaves out the system, own clients and unusable ports', () {
        final ports = map([
          AlsaClientInfo(
            client: 0,
            name: 'System',
            type: kernel,
            ports: [port(0, 1)],
          ),
          AlsaClientInfo(
            client: 128,
            name: 'Own',
            type: user,
            ports: [port(128, 0)],
          ),
          AlsaClientInfo(
            client: 130,
            name: 'Other',
            type: user,
            ports: [
              port(130, 0, type: 0),
              port(130, 1, capability: duplex | SND_SEQ_PORT_CAP_NO_EXPORT),
              port(
                130,
                2,
                capability: SND_SEQ_PORT_CAP_READ | SND_SEQ_PORT_CAP_WRITE,
              ),
              port(130, 3, type: SND_SEQ_PORT_TYPE_SYNTH),
              port(130, 4, type: SND_SEQ_PORT_TYPE_APPLICATION),
            ],
          ),
        ]);
        expect(
          [for (final p in ports) p.id.value],
          equals([
            'alsa:130:3:in',
            'alsa:130:3:out',
            'alsa:130:4:in',
            'alsa:130:4:out',
          ]),
        );
      });

      test('derives the transport from the client and port type', () {
        final ports = map([
          AlsaClientInfo(
            client: 20,
            name: 'USB',
            type: kernel,
            card: 1,
            ports: [port(20, 0)],
          ),
          AlsaClientInfo(
            client: 24,
            name: 'PCI',
            type: kernel,
            card: 2,
            ports: [port(24, 0)],
          ),
          AlsaClientInfo(
            client: 14,
            name: 'Midi Through',
            type: kernel,
            ports: [port(14, 0)],
          ),
          AlsaClientInfo(
            client: 130,
            name: 'Bridge',
            type: user,
            ports: [port(130, 0, type: midi | SND_SEQ_PORT_TYPE_HARDWARE)],
          ),
          AlsaClientInfo(
            client: 131,
            name: 'App',
            type: user,
            ports: [port(131, 0)],
          ),
        ]);
        expect(
          [
            for (final p in ports)
              if (p.isInput) [p.transport, p.isVirtual],
          ],
          equals([
            [MidiTransport.usb, false],
            [MidiTransport.unknown, false],
            [MidiTransport.software, false],
            [MidiTransport.unknown, true],
            [MidiTransport.software, true],
          ]),
        );
      });

      test('marks inactive ports offline', () {
        final ports = map([
          AlsaClientInfo(
            client: 20,
            name: 'Dev',
            type: kernel,
            ports: [
              port(20, 0, capability: duplex | SND_SEQ_PORT_CAP_INACTIVE),
              port(20, 1),
            ],
          ),
        ]);
        expect(
          [for (final p in ports) p.state],
          equals([
            MidiPortState.offline,
            MidiPortState.offline,
            MidiPortState.connected,
            MidiPortState.connected,
          ]),
        );
      });

      test('sets UMP per direction', () {
        final ports = map(
          [
            AlsaClientInfo(
              client: 130,
              name: 'App',
              type: user,
              ports: [port(130, 0)],
            ),
          ],
          ump: true,
          umpOut: false,
        );
        expect([for (final p in ports) p.capabilities.ump], [true, false]);
      });

      test('sets the capabilities per direction and protocol mode', () {
        final legacy = AlsaClientInfo(
          client: 130,
          name: 'App',
          type: user,
          ports: [port(130, 0)],
        );
        final umpClient = AlsaClientInfo(
          client: 131,
          name: 'Ump',
          type: user,
          midiVersion: SND_SEQ_CLIENT_UMP_MIDI_2_0,
          ports: [port(131, 0)],
        );
        expect(
          [
            for (final p in map([legacy])) p.capabilities,
            for (final p in map([legacy, umpClient], ump: true)) p.capabilities,
          ],
          equals([
            const MidiPortCapabilities(timestampsIn: true),
            const MidiPortCapabilities(
              scheduledSend: true,
              cancelPending: true,
            ),
            const MidiPortCapabilities(timestampsIn: true, ump: true),
            const MidiPortCapabilities(
              scheduledSend: true,
              cancelPending: true,
              ump: true,
            ),
            const MidiPortCapabilities(
              timestampsIn: true,
              ump: true,
              sysEx8: true,
            ),
            const MidiPortCapabilities(
              scheduledSend: true,
              cancelPending: true,
              ump: true,
              sysEx8: true,
            ),
          ]),
        );
      });

      test('derives the protocol of UMP clients', () {
        AlsaClientInfo client(
          int number, {
          int midiVersion = SND_SEQ_CLIENT_UMP_MIDI_2_0,
          AlsaUmpEndpointInfo? endpoint,
          bool umpIsMidi1 = false,
        }) => AlsaClientInfo(
          client: number,
          name: 'C$number',
          type: user,
          midiVersion: midiVersion,
          endpoint: endpoint,
          ports: [
            port(
              number,
              0,
              capability: AlsaPortMapper.readable,
              umpIsMidi1: umpIsMidi1,
            ),
          ],
        );
        final ports = map([
          client(130, midiVersion: SND_SEQ_CLIENT_LEGACY_MIDI),
          client(131),
          client(132, midiVersion: SND_SEQ_CLIENT_UMP_MIDI_1_0),
          client(
            133,
            endpoint: const AlsaUmpEndpointInfo(
              name: 'E',
              protocol: SND_UMP_EP_INFO_PROTO_MIDI1,
            ),
          ),
          client(
            134,
            endpoint: const AlsaUmpEndpointInfo(
              name: 'E',
              protocol: SND_UMP_EP_INFO_PROTO_MIDI2,
            ),
          ),
          client(135, umpIsMidi1: true),
        ], ump: true);
        expect(
          [for (final p in ports) p.protocol],
          equals([
            MidiProtocol.midi1,
            MidiProtocol.midi2,
            MidiProtocol.midi1,
            MidiProtocol.midi1,
            MidiProtocol.midi2,
            MidiProtocol.midi1,
          ]),
        );
      });

      test('describes the groups, blocks and endpoint of UMP ports', () {
        const endpoint = AlsaUmpEndpointInfo(
          name: 'Synth',
          productId: 'SN1',
          flags: SND_UMP_EP_INFO_STATIC_BLOCKS,
          protocolCaps:
              SND_UMP_EP_INFO_PROTO_MIDI1 |
              SND_UMP_EP_INFO_PROTO_MIDI2 |
              SND_UMP_EP_INFO_PROTO_JRTS_RX |
              SND_UMP_EP_INFO_PROTO_JRTS_TX,
          protocol:
              SND_UMP_EP_INFO_PROTO_MIDI2 |
              SND_UMP_EP_INFO_PROTO_JRTS_RX |
              SND_UMP_EP_INFO_PROTO_JRTS_TX,
          blockCount: 3,
          version: 0x0101,
          manufacturerId: 0x00201A,
          familyId: 3,
          modelId: 4,
          softwareRevision: [1, 2, 3, 4],
        );
        final ports = map([
          AlsaClientInfo(
            client: 20,
            name: 'Synth',
            type: kernel,
            midiVersion: SND_SEQ_CLIENT_UMP_MIDI_2_0,
            endpoint: endpoint,
            blocks: [
              const AlsaUmpBlockInfo(
                blockId: 0,
                name: 'Main',
                direction: snd_ump_direction.SND_UMP_DIR_BIDIRECTION,
                groupCount: 2,
                uiHint: snd_ump_block_ui_hint.SND_UMP_BLOCK_UI_HINT_BOTH,
                midiCiVersion: 1,
                sysEx8Streams: 2,
              ),
              const AlsaUmpBlockInfo(
                blockId: 1,
                name: 'DIN',
                active: false,
                flags: SND_UMP_BLOCK_IS_MIDI1 | SND_UMP_BLOCK_IS_LOWSPEED,
                direction: snd_ump_direction.SND_UMP_DIR_OUTPUT,
                firstGroup: 15,
                groupCount: 2,
              ),
              const AlsaUmpBlockInfo(
                blockId: 2,
                name: 'USB',
                flags: SND_UMP_BLOCK_IS_MIDI1,
                direction: snd_ump_direction.SND_UMP_DIR_INPUT,
                firstGroup: 0,
                groupCount: 20,
              ),
            ],
            ports: [
              port(
                20,
                0,
                name: 'MIDI 2.0',
                capability:
                    AlsaPortMapper.readable | SND_SEQ_PORT_CAP_UMP_ENDPOINT,
              ),
              port(
                20,
                2,
                name: 'Group 2 (Main)',
                capability: AlsaPortMapper.readable,
                umpGroup: 2,
              ),
            ],
          ),
        ], ump: true);
        const main = MidiFunctionBlockInfo(
          number: 0,
          name: 'Main',
          direction: MidiFunctionBlockDirection.bidirectional,
          firstGroup: 0,
          groupCount: 2,
          uiHint: MidiFunctionBlockUiHint.senderReceiver,
          midiCiVersion: 1,
          maxSysEx8Streams: 2,
        );
        const din = MidiFunctionBlockInfo(
          number: 1,
          name: 'DIN',
          isActive: false,
          direction: MidiFunctionBlockDirection.output,
          firstGroup: 15,
          groupCount: 2,
          midi1: MidiFunctionBlockMidi1.restricted31250,
        );
        const usb = MidiFunctionBlockInfo(
          number: 2,
          name: 'USB',
          direction: MidiFunctionBlockDirection.input,
          firstGroup: 0,
          groupCount: 16,
          midi1: MidiFunctionBlockMidi1.unrestricted,
        );
        expect(
          [
            for (final p in ports)
              [p.name, p.group, p.groups, p.functionBlocks],
          ],
          equals([
            [
              'Synth: MIDI 2.0',
              0,
              [
                for (var g = 0; g < 16; g++)
                  MidiGroupInfo(
                    group: g,
                    name: g < 2 ? 'Main' : (g == 15 ? 'DIN' : 'USB'),
                    isActive: g != 15,
                  ),
              ],
              [main, din, usb],
            ],
            [
              'Synth: Group 2 (Main)',
              1,
              [const MidiGroupInfo(group: 1, name: 'Main')],
              [main, usb],
            ],
          ]),
        );
        expect(
          ports.first.endpoint,
          MidiEndpointInfo(
            name: 'Synth',
            productInstanceId: 'SN1',
            identity: MidiDeviceIdentity(
              manufacturerId: [0x00, 0x20, 0x1A],
              familyId: 3,
              modelId: 4,
              softwareRevision: [1, 2, 3, 4],
            ),
            umpVersionMajor: 1,
            umpVersionMinor: 1,
            supportsMidi1: true,
            supportsMidi2: true,
            supportsRxJr: true,
            supportsTxJr: true,
            staticFunctionBlocks: true,
            functionBlockCount: 3,
            protocol: MidiProtocol.midi2,
            receiveJr: true,
            transmitJr: true,
          ),
        );
      });

      test('leaves out the identity of an anonymous endpoint', () {
        final ports = map([
          AlsaClientInfo(
            client: 131,
            name: 'Ump',
            type: user,
            midiVersion: SND_SEQ_CLIENT_UMP_MIDI_1_0,
            endpoint: const AlsaUmpEndpointInfo(name: 'Ump'),
            ports: [port(131, 0, capability: AlsaPortMapper.readable)],
          ),
        ], ump: true);
        expect(
          ports.single.endpoint,
          const MidiEndpointInfo(
            name: 'Ump',
            umpVersionMajor: 0,
            umpVersionMinor: 0,
            supportsMidi1: false,
            supportsMidi2: false,
            protocol: MidiProtocol.midi1,
          ),
        );
      });

      test('adds the generation of a reused client number to the ids', () {
        final ports = map(
          [
            AlsaClientInfo(
              client: 20,
              name: 'Keys',
              type: kernel,
              ports: [port(20, 0, capability: AlsaPortMapper.readable)],
            ),
          ],
          generations: {20: 2},
        );
        expect([
          ports.single.id.value,
          ports.single.deviceId?.value,
        ], equals(['alsa:20#2:0:in', 'alsa:20#2']));
      });

      test('adds the generation of a reused port address to the ids', () {
        final ports = map(
          [
            AlsaClientInfo(
              client: 130,
              name: 'App',
              type: user,
              ports: [port(130, 0, capability: AlsaPortMapper.writable)],
            ),
          ],
          generations: {130: 1},
          portGenerations: {(client: 130, port: 0): 3},
        );
        expect([
          ports.single.id.value,
          ports.single.deviceId?.value,
        ], equals(['alsa:130#1:0#3:out', 'alsa:130#1']));
      });

      test('keeps the native description and the device keys', () {
        final ports = map([
          AlsaClientInfo(
            client: 20,
            name: 'Keys',
            type: kernel,
            card: 1,
            ports: [port(20, 0, capability: AlsaPortMapper.readable)],
          ),
          AlsaClientInfo(
            client: 130,
            name: 'App',
            type: user,
            ports: [port(130, 0, capability: AlsaPortMapper.readable)],
          ),
        ]);
        expect(
          [for (final p in ports) p.native],
          equals([
            {
              'client': 20,
              'port': 0,
              'clientName': 'Keys',
              'portName': 'Port',
              'clientType': kernel,
              'card': 1,
              'capability': AlsaPortMapper.readable,
              'type': midi,
              MidiPortRegistry.deviceNameKey: 'Keys',
              MidiPortRegistry.productKey: 'Keys',
              MidiPortRegistry.driverKey: AlsaPortMapper.kernelDriver,
            },
            {
              'client': 130,
              'port': 0,
              'clientName': 'App',
              'portName': 'Port',
              'clientType': user,
              'card': -1,
              'capability': AlsaPortMapper.readable,
              'type': midi,
              MidiPortRegistry.deviceNameKey: 'App',
              MidiPortRegistry.productKey: 'App',
              MidiPortRegistry.driverKey: AlsaPortMapper.userDriver,
            },
          ]),
        );
      });
    });

    group('AlsaPortMapper(backend, isUsbCard)', () {
      test('checks /proc/asound for USB cards by default', () {
        final ports = AlsaPortMapper().map(
          [
            AlsaClientInfo(
              client: 20,
              name: 'Card',
              type: kernel,
              card: 99,
              ports: [port(20, 0, capability: AlsaPortMapper.readable)],
            ),
          ],
          ownClients: {},
          umpIn: false,
          umpOut: false,
        );
        expect(ports.single.transport, MidiTransport.unknown);
      });

      test('prefixes the ids with the backend name', () {
        final mapper = AlsaPortMapper(backend: 'test');
        expect(mapper.backend, 'test');
      });
    });

    group('portId(backend, client, port, direction, generation, '
        'portGeneration)', () {
      test('names the direction', () {
        expect(
          [
            AlsaPortMapper.portId(
              backend: 'alsa',
              client: 14,
              port: 0,
              direction: MidiDirection.input,
            ),
            AlsaPortMapper.portId(
              backend: 'alsa',
              client: 14,
              port: 0,
              direction: MidiDirection.output,
              generation: 1,
            ),
          ],
          equals([
            const MidiPortId('alsa:14:0:in'),
            const MidiPortId('alsa:14#1:0:out'),
          ]),
        );
      });
    });

    group('usbCardFromProcfs(card)', () {
      test('is false for a card that does not exist', () {
        expect(AlsaPortMapper.usbCardFromProcfs(99), isFalse);
      });
    });
  });
}
