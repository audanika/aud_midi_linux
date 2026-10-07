// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_midi_linux/src/alsa/alsa_client_info.dart';
import 'package:aud_midi_linux/src/alsa/alsa_event.dart';
import 'package:aud_midi_linux/src/alsa/alsa_sequencer.dart';
import 'package:test/test.dart';

/// The smallest sequencer: one client without ports.
final class _Sequencer implements AlsaSequencer {
  final calls = <String>[];

  @override
  int get clientId => 128;

  @override
  void setClientName(String name) => calls.add('name $name');

  @override
  bool enableUmp() => false;

  @override
  void setPools({int? input, int? output}) => calls.add('pools');

  @override
  int createPort({
    required String name,
    required int capability,
    required int type,
    int? timestampQueue,
  }) => 0;

  @override
  void deletePort(int port) => calls.add('delete $port');

  @override
  void connectFrom({
    required int port,
    required int client,
    required int sourcePort,
  }) => calls.add('connect $client:$sourcePort');

  @override
  void disconnectFrom({
    required int port,
    required int client,
    required int sourcePort,
  }) => calls.add('disconnect $client:$sourcePort');

  @override
  List<AlsaClientInfo> clients() => [
    AlsaClientInfo(client: clientId, name: 'App', type: 1),
  ];

  @override
  int startQueue(String name) => 0;

  @override
  int queueTime(int queue) => 0;

  @override
  void freeQueue(int queue) => calls.add('free $queue');

  @override
  void output(AlsaEvent event) => calls.add('output ${event.type}');

  @override
  void removeEvents({
    required int queue,
    required int destClient,
    required int destPort,
    int? tag,
  }) => calls.add('remove $destClient:$destPort');

  @override
  void close() => calls.add('close');
}

void main() {
  group('AlsaSequencer', () {
    test('describes one sequencer client', () {
      final sequencer = _Sequencer()
        ..setClientName('App')
        ..connectFrom(port: 0, client: 0, sourcePort: 1)
        ..output(AlsaEvent.fixed(type: 6))
        ..close();
      expect(
        [
          sequencer.clients().single.client,
          sequencer.enableUmp(),
          sequencer.calls,
        ],
        [
          128,
          false,
          ['name App', 'connect 0:1', 'output 6', 'close'],
        ],
      );
    });
  });
}
