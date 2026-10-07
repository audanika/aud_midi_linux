// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:aud_midi_core/aud_midi_core.dart';
import 'package:aud_midi_linux/aud_midi_linux.dart';
import 'package:aud_midi_standard/aud_midi_standard.dart';
import 'package:dbus/dbus.dart';
import 'package:test/test.dart';

const _midiService = MidiBleTransport.serviceUuid;
const _midiCharacteristic = MidiBleTransport.characteristicUuid;
const _batteryLevel = '00002a19-0000-1000-8000-00805f9b34fb';

/// Answers a method call of the mock BlueZ: the error configured for it, or
/// success.
DBusMethodResponse _answer(Map<String, String> errors, String method) {
  final error = errors[method];
  return error == null
      ? DBusMethodSuccessResponse()
      : DBusMethodErrorResponse(error);
}

// #############################################################################
/// The object manager at the root of the mock BlueZ.
final class _Root extends DBusObject {
  _Root() : super(DBusObjectPath.root, isObjectManager: true);
}

// #############################################################################
/// `org.bluez.Adapter1` of the mock BlueZ.
final class _Adapter extends DBusObject {
  _Adapter({this.powered = true}) : super(DBusObjectPath('/org/bluez/hci0'));

  final bool powered;
  final calls = <String>[];
  final errors = <String, String>{};
  Map<String, DBusValue> filter = {};

  @override
  Map<String, Map<String, DBusValue>> get interfacesAndProperties => {
    'org.bluez.Adapter1': {
      'Address': const DBusString('00:00:00:00:00:01'),
      'Powered': DBusBoolean(powered),
    },
  };

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall methodCall) async {
    calls.add(methodCall.name);
    if (methodCall.name == 'SetDiscoveryFilter') {
      filter = methodCall.values.first.asStringVariantDict();
    }
    return _answer(errors, methodCall.name);
  }
}

// #############################################################################
/// `org.bluez.Device1` of the mock BlueZ with its GATT objects.
final class _Device extends DBusObject {
  _Device(
    this.address, {
    this.alias = 'Keys',
    this.rssi = -50,
    this.midi = true,
    this.withCharacteristic = true,
    this.mtu = 247,
    this.extraCharacteristics = const [],
  }) : super(
         DBusObjectPath('/org/bluez/hci0/dev_${address.replaceAll(':', '_')}'),
       );

  final String address;
  final String alias;
  int rssi;
  final bool midi;
  final bool withCharacteristic;
  final int? mtu;
  final List<Map<String, DBusValue>> extraCharacteristics;
  bool connected = false;
  bool resolved = false;
  bool resolveLater = false;
  Completer<void>? connectGate;
  final calls = <String>[];
  final errors = <String, String>{};
  final characteristicErrors = <String, String>{};
  final gatt = <DBusObject>[];
  _Characteristic? characteristic;

  @override
  Map<String, Map<String, DBusValue>> get interfacesAndProperties => {
    'org.bluez.Device1': {
      'Address': DBusString(address),
      'Alias': DBusString(alias),
      'Name': const DBusString('Device'),
      'RSSI': DBusInt16(rssi),
      'UUIDs': DBusArray.string([
        if (midi) _midiService,
        '00001800-0000-1000-8000-00805f9b34fb',
      ]),
      'Connected': DBusBoolean(connected),
      'ServicesResolved': DBusBoolean(resolved),
      'Adapter': DBusObjectPath('/org/bluez/hci0'),
    },
  };

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall methodCall) async {
    calls.add(methodCall.name);
    final answer = _answer(errors, methodCall.name);
    if (answer is DBusMethodErrorResponse) return answer;
    if (methodCall.name == 'Connect') {
      await connectGate?.future;
      await setConnected(true);
      if (!resolveLater) await resolve();
    } else if (methodCall.name == 'Disconnect') {
      await setConnected(false);
    }
    return answer;
  }

  /// Exposes the GATT objects and reports the services as resolved.
  Future<void> resolve() async {
    if (gatt.isEmpty) {
      final service = _Gatt('${path.value}/service0010', {
        'org.bluez.GattService1': {
          'UUID': const DBusString(_midiService),
          'Primary': const DBusBoolean(true),
        },
      });
      gatt.add(service);
      for (final (i, properties) in extraCharacteristics.indexed) {
        gatt.add(
          _Gatt('${service.path.value}/char00${20 + i}', {
            'org.bluez.GattCharacteristic1': properties,
          }),
        );
      }
      if (withCharacteristic) {
        gatt.add(
          characteristic = _Characteristic(
            '${service.path.value}/char0011',
            mtu: mtu,
            errors: characteristicErrors,
          ),
        );
      }
      for (final object in gatt) {
        await client!.registerObject(object);
      }
    }
    resolved = true;
    await emitPropertiesChanged(
      'org.bluez.Device1',
      changedProperties: {'ServicesResolved': const DBusBoolean(true)},
    );
  }

  Future<void> setConnected(bool value) async {
    connected = value;
    await emitPropertiesChanged(
      'org.bluez.Device1',
      changedProperties: {'Connected': DBusBoolean(value)},
    );
  }

  Future<void> change(Map<String, DBusValue> properties) =>
      emitPropertiesChanged('org.bluez.Device1', changedProperties: properties);
}

// #############################################################################
/// A GATT object with fixed properties.
final class _Gatt extends DBusObject {
  _Gatt(String path, this.properties) : super(DBusObjectPath(path));

  final Map<String, Map<String, DBusValue>> properties;

  @override
  Map<String, Map<String, DBusValue>> get interfacesAndProperties => properties;
}

// #############################################################################
/// The BLE-MIDI I/O characteristic of the mock BlueZ.
final class _Characteristic extends DBusObject {
  _Characteristic(String path, {required this.mtu, required this.errors})
    : super(DBusObjectPath(path));

  final int? mtu;
  final Map<String, String> errors;
  final calls = <String>[];
  final writes = <List<Object>>[];

  @override
  Map<String, Map<String, DBusValue>> get interfacesAndProperties => {
    'org.bluez.GattCharacteristic1': {
      'UUID': const DBusString(_midiCharacteristic),
      'Flags': DBusArray.string(['read', 'write-without-response', 'notify']),
      'MTU': ?(mtu == null ? null : DBusUint16(mtu!)),
    },
  };

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall methodCall) async {
    calls.add(methodCall.name);
    if (methodCall.name == 'WriteValue') {
      writes.add([
        methodCall.values[0].asByteArray().toList(),
        methodCall.values[1].asStringVariantDict(),
      ]);
    }
    return _answer(errors, methodCall.name);
  }

  Future<void> change(
    Map<String, DBusValue> properties, {
    String interface = 'org.bluez.GattCharacteristic1',
  }) => emitPropertiesChanged(interface, changedProperties: properties);
}

void main() {
  late Directory directory;
  late DBusServer server;
  late DBusAddress address;
  late _Adapter adapter;
  late MidiBlueZBleTransport transport;
  late List<DBusClient> buses;
  DBusClient? bluez;

  DBusClient open() {
    final bus = DBusClient(address, authClient: DBusAuthClient(uid: '1'));
    buses.add(bus);
    return bus;
  }

  /// Starts the mock BlueZ with [devices].
  Future<void> startBlueZ({
    List<_Device> devices = const [],
    bool withAdapter = true,
    bool powered = true,
  }) async {
    final service = bluez = DBusClient(
      address,
      authClient: DBusAuthClient(uid: '1'),
    );
    await service.requestName('org.bluez');
    await service.registerObject(_Root());
    adapter = _Adapter(powered: powered);
    if (withAdapter) await service.registerObject(adapter);
    for (final device in devices) {
      await service.registerObject(device);
    }
  }

  /// Waits until [condition] holds.
  Future<void> until(bool Function() condition) async {
    while (!condition()) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
  }

  setUp(() async {
    directory = Directory.systemTemp.createTempSync('aud_midi_bluez');
    server = DBusServer();
    address = await server.listenAddress(DBusAddress.unix(dir: directory));
    buses = [];
    bluez = null;
    transport = MidiBlueZBleTransport(openBus: open);
  });

  tearDown(() async {
    await transport.close();
    await bluez?.close();
    await server.close();
    directory.deleteSync(recursive: true);
  });

  List<Object?> info(MidiBlePeripheralInfo peripheral) => [
    peripheral.id,
    peripheral.name,
    peripheral.rssi,
    peripheral.state,
  ];

  group('MidiBlueZBleTransport', () {
    group('MidiBlueZBleTransport(openBus)', () {
      test('opens the system bus lazily by default', () async {
        await MidiBlueZBleTransport().close();
        expect(buses, isEmpty);
      });
    });

    group('scan(timeout)', () {
      test('reports BLE-MIDI devices and their changes', () async {
        final keys = _Device('AA:00:00:00:00:01');
        await startBlueZ(
          devices: [
            keys,
            _Device('AA:00:00:00:00:02', alias: 'Mouse', midi: false),
          ],
        );
        final found = <MidiBlePeripheralInfo>[];
        final subscription = transport.scan().listen(found.add);
        await until(() => adapter.calls.contains('StartDiscovery'));
        await bluez!.registerObject(
          _Device('AA:00:00:00:00:03', alias: '', rssi: 0),
        );
        await until(() => found.length == 2);
        await keys.change({'TxPower': const DBusInt16(4)});
        await keys.change({'RSSI': const DBusInt16(-40)});
        await until(() => found.length == 3);
        await subscription.cancel();
        expect(
          [
            for (final peripheral in found) info(peripheral),
            adapter.filter,
            adapter.calls,
          ],
          [
            [
              'AA:00:00:00:00:01',
              'Keys',
              -50,
              MidiBlePeripheralState.advertising,
            ],
            [
              'AA:00:00:00:00:03',
              'Device',
              null,
              MidiBlePeripheralState.advertising,
            ],
            [
              'AA:00:00:00:00:01',
              'Keys',
              -40,
              MidiBlePeripheralState.advertising,
            ],
            {
              'UUIDs': DBusArray.string([_midiService]),
              'Transport': const DBusString('le'),
            },
            ['SetDiscoveryFilter', 'StartDiscovery', 'StopDiscovery'],
          ],
        );
      });

      test('ends after the timeout', () async {
        await startBlueZ(devices: [_Device('AA:00:00:00:00:01')]);
        final found = await transport
            .scan(timeout: const Duration(milliseconds: 50))
            .toList();
        expect([found.length, adapter.calls.last], [1, 'StopDiscovery']);
      });

      test('counts a discovery that runs already as started', () async {
        await startBlueZ(devices: [_Device('AA:00:00:00:00:01')]);
        adapter.errors['StartDiscovery'] = 'org.bluez.Error.InProgress';
        final found = await transport
            .scan(timeout: const Duration(milliseconds: 50))
            .toList();
        expect(found, hasLength(1));
      });

      test('replaces a running scan', () async {
        await startBlueZ(devices: [_Device('AA:00:00:00:00:01')]);
        final first = transport.scan().toList();
        await until(() => adapter.calls.contains('StartDiscovery'));
        final second = transport.scan().first;
        expect(
          [(await first).length, info(await second).first],
          [1, 'AA:00:00:00:00:01'],
        );
      });

      test('fails without adapter', () async {
        await startBlueZ(withAdapter: false);
        await expectLater(
          transport.scan().first,
          throwsA(
            isA<MidiUnsupported>().having(
              (e) => e.feature,
              'feature',
              contains('no adapter'),
            ),
          ),
        );
      });

      test('fails with the adapter powered off', () async {
        await startBlueZ(powered: false);
        await expectLater(
          transport.scan().first,
          throwsA(
            isA<MidiUnsupported>().having(
              (e) => e.feature,
              'feature',
              contains('powered off'),
            ),
          ),
        );
      });

      test('fails without BlueZ and recovers when it appears', () async {
        await expectLater(
          transport.scan().first,
          throwsA(
            isA<MidiUnsupported>().having(
              (e) => e.feature,
              'feature',
              contains('BlueZ daemon'),
            ),
          ),
        );
        await startBlueZ(devices: [_Device('AA:00:00:00:00:01')]);
        expect(info(await transport.scan().first).first, 'AA:00:00:00:00:01');
      });

      test('fails without D-Bus system bus', () async {
        transport = MidiBlueZBleTransport(
          openBus: () => DBusClient(
            DBusAddress.unix(path: '${directory.path}/missing'),
            authClient: DBusAuthClient(uid: '1'),
          ),
        );
        await expectLater(
          transport.scan().first,
          throwsA(
            isA<MidiUnsupported>().having(
              (e) => e.feature,
              'feature',
              contains('no D-Bus'),
            ),
          ),
        );
      });

      test('reports refused discoveries as native errors', () async {
        await startBlueZ();
        adapter.errors['StartDiscovery'] = 'org.bluez.Error.NotReady';
        await expectLater(
          transport.scan().first,
          throwsA(
            isA<MidiNativeError>()
                .having(
                  (e) => e.api,
                  'api',
                  'org.bluez.Adapter1.StartDiscovery '
                      '(org.bluez.Error.NotReady)',
                )
                .having((e) => e.code, 'code', -5),
          ),
        );
      });

      for (final error in [
        'org.freedesktop.DBus.Error.AccessDenied',
        'org.bluez.Error.NotAuthorized',
        'org.bluez.Error.NotPermitted',
      ]) {
        test('reports $error as a missing permission', () async {
          await startBlueZ();
          adapter.errors['SetDiscoveryFilter'] = error;
          await expectLater(
            transport.scan().first,
            throwsA(
              isA<MidiPermissionDenied>().having(
                (e) => e.permission,
                'permission',
                MidiPermission.bluetooth,
              ),
            ),
          );
        });
      }
    });

    group('stopScan()', () {
      test('ends the running scan', () async {
        await startBlueZ(devices: [_Device('AA:00:00:00:00:01')]);
        final found = transport.scan().toList();
        await until(() => adapter.calls.contains('StartDiscovery'));
        await transport.stopScan();
        expect(
          [(await found).length, adapter.calls.last],
          [1, 'StopDiscovery'],
        );
      });

      test('does nothing without scan', () async {
        await transport.stopScan();
        expect(buses, isEmpty);
      });
    });

    group('connect(peripheralId, timeout)', () {
      test('connects and exchanges packets', () async {
        final keys = _Device('AA:00:00:00:00:01');
        await startBlueZ(devices: [keys]);
        final connection = await transport.connect('aa:00:00:00:00:01');
        final characteristic = keys.characteristic!;
        final received = <List<int>>[];
        final notificationsDone = connection.notifications
            .listen(received.add)
            .asFuture<void>();
        await characteristic.change({
          'Value': DBusArray.byte([0x80, 0x80, 0x90, 60, 100]),
        });
        await characteristic.change({
          'Value': DBusArray.byte([0x80, 0x81, 0x80, 60, 0]),
        });
        await characteristic.change({
          'Value': DBusArray.byte([1]),
        }, interface: 'org.example.Other');
        await until(() => received.length == 2);
        await connection.write(Uint8List.fromList([0x80, 0x80, 0xF8]));
        await characteristic.change({'MTU': const DBusUint16(100)});
        await until(() => connection.maxPacketLength == 97);
        await connection.disconnect();
        await connection.disconnect();
        await connection.done;
        await notificationsDone;
        expect(
          [
            connection.peripheralId,
            received,
            characteristic.writes,
            characteristic.calls,
            keys.calls,
          ],
          [
            'aa:00:00:00:00:01',
            [
              [0x80, 0x80, 0x90, 60, 100],
              [0x80, 0x81, 0x80, 60, 0],
            ],
            [
              [
                [0x80, 0x80, 0xF8],
                {'type': const DBusString('command')},
              ],
            ],
            ['StartNotify', 'WriteValue', 'StopNotify'],
            ['Connect', 'Disconnect'],
          ],
        );
      });

      test('uses the MTU of the characteristic', () async {
        await startBlueZ(devices: [_Device('AA:00:00:00:00:01')]);
        final connection = await transport.connect('AA:00:00:00:00:01');
        expect(connection.maxPacketLength, 244);
      });

      test('falls back to 20 bytes without MTU', () async {
        await startBlueZ(devices: [_Device('AA:00:00:00:00:01', mtu: null)]);
        final connection = await transport.connect('AA:00:00:00:00:01');
        expect(connection.maxPacketLength, 20);
      });

      test('waits until the services are resolved', () async {
        final keys = _Device('AA:00:00:00:00:01')..resolveLater = true;
        await startBlueZ(devices: [keys]);
        final connecting = transport.connect('AA:00:00:00:00:01');
        await until(() => keys.connected);
        await keys.resolve();
        final connection = await connecting;
        expect(connection.peripheralId, 'AA:00:00:00:00:01');
      });

      test('picks the BLE-MIDI characteristic of the device', () async {
        final other = _Device('AA:00:00:00:00:02');
        final keys = _Device(
          'AA:00:00:00:00:01',
          extraCharacteristics: [
            {'UUID': const DBusString(_batteryLevel)},
            {
              'Flags': DBusArray.string(['read']),
            },
          ],
        );
        await startBlueZ(devices: [other, keys]);
        await transport.connect('AA:00:00:00:00:02');
        final connection = await transport.connect('AA:00:00:00:00:01');
        await keys.characteristic!.change({
          'Value': DBusArray.byte([0x80, 0x80, 0xFE]),
        });
        expect(await connection.notifications.first, [0x80, 0x80, 0xFE]);
      });

      test('uses a connection the system made already', () async {
        final keys = _Device('AA:00:00:00:00:01');
        await startBlueZ(devices: [keys]);
        keys.errors['Connect'] = 'org.bluez.Error.AlreadyConnected';
        keys.connected = true;
        await keys.resolve();
        final connection = await transport.connect('AA:00:00:00:00:01');
        expect(connection.maxPacketLength, 244);
      });

      test('reports an unknown device', () async {
        await startBlueZ();
        await expectLater(
          transport.connect('AA:00:00:00:00:09'),
          throwsA(
            isA<MidiNativeError>()
                .having((e) => e.api, 'api', 'BlueZ device AA:00:00:00:00:09')
                .having((e) => e.code, 'code', -19),
          ),
        );
      });

      test('times out and disconnects', () async {
        final keys = _Device('AA:00:00:00:00:01')
          ..connectGate = Completer<void>();
        await startBlueZ(devices: [keys]);
        await expectLater(
          transport.connect(
            'AA:00:00:00:00:01',
            timeout: const Duration(milliseconds: 50),
          ),
          throwsA(
            isA<MidiNativeError>()
                .having((e) => e.api, 'api', 'org.bluez.Device1.Connect')
                .having((e) => e.code, 'code', -110),
          ),
        );
        keys.connectGate!.complete();
        await until(() => keys.calls.contains('Disconnect'));
        expect(keys.calls, containsAll(['Connect', 'Disconnect']));
      });

      test('refuses a device without BLE-MIDI characteristic', () async {
        final keys = _Device('AA:00:00:00:00:01', withCharacteristic: false);
        await startBlueZ(devices: [keys]);
        await expectLater(
          transport.connect('AA:00:00:00:00:01'),
          throwsA(isA<MidiUnsupported>()),
        );
        expect(keys.calls, ['Connect', 'Disconnect']);
      });

      test('reports a refused connection', () async {
        final keys = _Device('AA:00:00:00:00:01');
        await startBlueZ(devices: [keys]);
        keys.errors['Connect'] = 'org.bluez.Error.Failed';
        await expectLater(
          transport.connect('AA:00:00:00:00:01'),
          throwsA(
            isA<MidiNativeError>().having(
              (e) => e.api,
              'api',
              'org.bluez.Device1.Connect (org.bluez.Error.Failed)',
            ),
          ),
        );
      });

      test('reports refused notifications', () async {
        final keys = _Device('AA:00:00:00:00:01');
        keys.characteristicErrors['StartNotify'] =
            'org.bluez.Error.NotPermitted';
        await startBlueZ(devices: [keys]);
        await expectLater(
          transport.connect('AA:00:00:00:00:01'),
          throwsA(isA<MidiPermissionDenied>()),
        );
      });
    });

    group('MidiBleConnection.done', () {
      test('completes when the device disconnects', () async {
        final keys = _Device('AA:00:00:00:00:01');
        await startBlueZ(devices: [keys]);
        final connection = await transport.connect('AA:00:00:00:00:01');
        await keys.change({'RSSI': const DBusInt16(-30)});
        await keys.setConnected(false);
        await connection.done;
        expect(keys.calls, ['Connect']);
      });

      test('completes when the device disappears', () async {
        final keys = _Device('AA:00:00:00:00:01');
        await startBlueZ(devices: [keys, _Device('AA:00:00:00:00:02')]);
        final connection = await transport.connect('AA:00:00:00:00:01');
        for (final object in keys.gatt.reversed) {
          await bluez!.unregisterObject(object);
        }
        await bluez!.unregisterObject(keys);
        await connection.done;
        expect(keys.calls, ['Connect']);
      });
    });

    group('close()', () {
      test('disconnects, closes the bus and opens a new one later', () async {
        final keys = _Device('AA:00:00:00:00:01');
        await startBlueZ(devices: [keys]);
        final connection = await transport.connect('AA:00:00:00:00:01');
        await transport.close();
        await connection.done;
        await transport.scan().first;
        expect(
          [buses.length, keys.calls, keys.characteristic!.calls],
          [
            2,
            ['Connect', 'Disconnect'],
            ['StartNotify', 'StopNotify'],
          ],
        );
      });
    });
  });
}
