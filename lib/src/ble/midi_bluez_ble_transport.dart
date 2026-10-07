// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:aud_midi_core/aud_midi_core.dart';
import 'package:aud_midi_standard/aud_midi_standard.dart';
import 'package:bluez/bluez.dart';
import 'package:dbus/dbus.dart';

// #############################################################################
/// A [MidiBleTransport] on BlueZ, the Linux Bluetooth stack, over D-Bus.
///
/// Discovery and connections go through the `bluez` package: the first
/// adapter scans with a filter on the BLE-MIDI service UUID, a peripheral
/// is the BlueZ device with that address. The BLE-MIDI I/O characteristic
/// is used directly over D-Bus: notifications come from its
/// `PropertiesChanged` signals, each signal carrying its own value, and
/// packets are written without response (`WriteValue` with type
/// `command`). The packet length follows the characteristic's `MTU`
/// property (BlueZ 5.62 and later; 23 bytes otherwise).
///
/// The D-Bus connection opens on first use; [close] ends it.
final class MidiBlueZBleTransport implements MidiBleTransport {
  /// Creates a transport that opens its D-Bus connection with [openBus],
  /// by default to the system bus.
  MidiBlueZBleTransport({DBusClient Function()? openBus})
    : _openBus = openBus ?? DBusClient.system;

  // ...........................................................................
  /// Scans for peripherals advertising the BLE-MIDI service; a peripheral
  /// is reported when it is found and whenever its name, signal strength
  /// or connection changes. Only one scan runs at a time.
  ///
  /// The stream fails with a [MidiUnsupported] without BlueZ or a powered
  /// adapter and with a [MidiPermissionDenied] when D-Bus refuses access.
  @override
  Stream<MidiBlePeripheralInfo> scan({Duration? timeout}) {
    late final _Scan scan;
    final controller = StreamController<MidiBlePeripheralInfo>(
      onListen: () => unawaited(_startScan(scan, timeout)),
      onCancel: () => _stop(scan),
    );
    scan = _Scan(controller);
    return controller.stream;
  }

  @override
  Future<void> stopScan() async {
    final scan = _scan;
    if (scan != null) await _stop(scan);
  }

  // ...........................................................................
  /// Connects the peripheral with the address [peripheralId], waits for
  /// its GATT services and subscribes to the BLE-MIDI characteristic.
  ///
  /// Throws a [MidiNativeError] when the device is unknown (`ENODEV`), the
  /// connection fails or does not succeed within [timeout] (`ETIMEDOUT`),
  /// and a [MidiUnsupported] when the device has no BLE-MIDI service.
  @override
  Future<MidiBleConnection> connect(
    String peripheralId, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final client = await _client();
    final device = _device(client, peripheralId);
    if (device == null) {
      throw MidiNativeError(api: 'BlueZ device $peripheralId', code: -_enodev);
    }
    final watch = Stopwatch()..start();
    try {
      await _call(
        'org.bluez.Device1.Connect',
        device.connect,
        done: 'org.bluez.Error.AlreadyConnected',
      ).timeout(timeout);
      await _servicesResolved(device).timeout(timeout - watch.elapsed);
      final characteristic = await _midiCharacteristic(device, peripheralId);
      final connection = await _BlueZConnection.open(
        bus: _bus!,
        client: client,
        device: device,
        peripheralId: peripheralId,
        path: characteristic.path,
        mtu: characteristic.mtu,
      ).timeout(timeout - watch.elapsed);
      _connections.add(connection);
      unawaited(connection.done.then((_) => _connections.remove(connection)));
      return connection;
    } on TimeoutException {
      await _quietly(device.disconnect());
      throw const MidiNativeError(
        api: 'org.bluez.Device1.Connect',
        code: -_etimedout,
      );
    } on MidiUnsupported {
      await _quietly(device.disconnect());
      rethrow;
    }
  }

  /// Stops a scan, disconnects all peripherals and closes the D-Bus
  /// connection; the next call opens it again.
  Future<void> close() async {
    await stopScan();
    for (final connection in [..._connections]) {
      await connection.disconnect();
    }
    final client = _bluez;
    _bluez = null;
    _connecting = null;
    if (client != null) await client.close();
    final bus = _bus;
    _bus = null;
    if (bus != null) await bus.close();
  }

  // ...........................................................................
  final DBusClient Function() _openBus;
  DBusClient? _bus;
  BlueZClient? _bluez;
  final _connections = <_BlueZConnection>{};
  Future<BlueZClient>? _connecting;
  _Scan? _scan;

  static const _enodev = 19;
  static const _etimedout = 110;
  static const _eio = 5;
  static const _characteristicInterface = 'org.bluez.GattCharacteristic1';
  static const _serviceUnknown = 'org.freedesktop.DBus.Error.ServiceUnknown';

  /// Returns the connected BlueZ client, connecting it on first use.
  ///
  /// The bus and BlueZ are probed first: the `bluez` package subscribes to
  /// signals in the background, and a bus that cannot be reached would
  /// fail there, out of reach of any error handling.
  Future<BlueZClient> _client() => _connecting ??= () async {
    final bus = _bus ??= _openBus();
    try {
      var present = false;
      await _call(
        'org.freedesktop.DBus.NameHasOwner',
        () async => present = await bus.nameHasOwner('org.bluez'),
      );
      if (!present) throw _exception('', _serviceUnknown);
      final client = BlueZClient(bus: bus);
      await _call('org.freedesktop.DBus.ObjectManager', client.connect);
      return _bluez = client;
    } on Object {
      _connecting = null;
      _bus = null;
      await _quietly(bus.close());
      rethrow;
    }
  }();

  /// Stops [scan] when it is the running scan.
  Future<void> _stop(_Scan scan) async {
    if (!identical(_scan, scan)) return;
    _scan = null;
    await _release(scan);
  }

  /// Ends [scan]: its timer, subscriptions, discovery and stream.
  static Future<void> _release(_Scan scan) async {
    scan.timer?.cancel();
    for (final subscription in scan.subscriptions) {
      await subscription.cancel();
    }
    final adapter = scan.adapter;
    if (adapter != null) await _quietly(adapter.stopDiscovery());
    unawaited(scan.controller.close());
  }

  /// Makes [scan] the running scan, ending the previous one, and starts the
  /// discovery.
  Future<void> _startScan(_Scan scan, Duration? timeout) async {
    final previous = _scan;
    _scan = scan;
    if (previous != null) await _release(previous);
    try {
      final client = await _client();
      final adapter = _poweredAdapter(client);
      await _call(
        'org.bluez.Adapter1.SetDiscoveryFilter',
        () => adapter.setDiscoveryFilter(
          uuids: [MidiBleTransport.serviceUuid],
          transport: 'le',
        ),
      );
      scan.subscriptions.add(
        client.deviceAdded.listen((device) => _watch(scan, device)),
      );
      for (final device in client.devices) {
        _watch(scan, device);
      }
      await _call(
        'org.bluez.Adapter1.StartDiscovery',
        adapter.startDiscovery,
        done: 'org.bluez.Error.InProgress',
      );
      if (!identical(_scan, scan)) return;
      scan.adapter = adapter;
      if (timeout != null) scan.timer = Timer(timeout, () => _stop(scan));
    } on Object catch (error, stack) {
      if (identical(_scan, scan)) {
        scan.controller.addError(error, stack);
        await _stop(scan);
      }
    }
  }

  /// Reports [device] when it offers BLE-MIDI, now and on every change.
  void _watch(_Scan scan, BlueZDevice device) {
    if (!identical(_scan, scan)) return;
    void report() {
      if (!identical(_scan, scan) || !_isMidi(device)) return;
      scan.controller.add(_peripheral(device));
    }

    scan.subscriptions.add(
      device.propertiesChanged.listen((names) {
        if (names.any(_reportedProperties.contains)) report();
      }),
    );
    report();
  }

  static const _reportedProperties = {
    'Name',
    'Alias',
    'RSSI',
    'UUIDs',
    'Connected',
  };

  static bool _isMidi(BlueZDevice device) => device.uuids.any(
    (uuid) => uuid.toString() == MidiBleTransport.serviceUuid,
  );

  static MidiBlePeripheralInfo _peripheral(BlueZDevice device) =>
      MidiBlePeripheralInfo(
        id: device.address,
        name: device.alias.isNotEmpty ? device.alias : device.name,
        rssi: device.rssi == 0 ? null : device.rssi,
        state: device.connected
            ? MidiBlePeripheralState.connected
            : MidiBlePeripheralState.advertising,
      );

  static BlueZAdapter _poweredAdapter(BlueZClient client) {
    final adapters = client.adapters;
    if (adapters.isEmpty) {
      throw const MidiUnsupported('Bluetooth (no adapter)');
    }
    final adapter = adapters.firstWhere(
      (adapter) => adapter.powered,
      orElse: () =>
          throw const MidiUnsupported('Bluetooth (the adapter is powered off)'),
    );
    return adapter;
  }

  static BlueZDevice? _device(BlueZClient client, String address) {
    final wanted = address.toUpperCase();
    for (final device in client.devices) {
      if (device.address.toUpperCase() == wanted) return device;
    }
    return null;
  }

  /// Completes when BlueZ resolved the GATT services of [device].
  static Future<void> _servicesResolved(BlueZDevice device) async {
    if (device.servicesResolved) return;
    final resolved = Completer<void>();
    final subscription = device.propertiesChanged.listen((_) {
      if (device.servicesResolved && !resolved.isCompleted) {
        resolved.complete();
      }
    });
    try {
      await resolved.future;
    } finally {
      await subscription.cancel();
    }
  }

  /// Finds the object path and MTU of the BLE-MIDI characteristic of
  /// [device].
  Future<({DBusObjectPath path, int? mtu})> _midiCharacteristic(
    BlueZDevice device,
    String peripheralId,
  ) async {
    late final Map<DBusObjectPath, Map<String, Map<String, DBusValue>>> objects;
    await _call(
      'org.freedesktop.DBus.ObjectManager.GetManagedObjects',
      () async => objects = await DBusRemoteObjectManager(
        _bus!,
        name: 'org.bluez',
        path: DBusObjectPath.root,
      ).getManagedObjects(),
    );
    for (final MapEntry(key: path, value: interfaces) in objects.entries) {
      final properties = interfaces[_characteristicInterface];
      if (properties == null || !path.isInNamespace(device.path)) continue;
      final uuid = properties['UUID'];
      if (uuid is! DBusString ||
          uuid.value.toLowerCase() != MidiBleTransport.characteristicUuid) {
        continue;
      }
      final mtu = properties['MTU'];
      return (path: path, mtu: mtu is DBusUint16 ? mtu.value : null);
    }
    throw MidiUnsupported('the BLE-MIDI service on $peripheralId');
  }

  /// Runs the D-Bus call [api] and maps its errors to [MidiException]s; the
  /// error [done] means the call had nothing left to do and counts as
  /// success, e.g. starting a discovery that runs already.
  static Future<void> _call(
    String api,
    Future<Object?> Function() call, {
    String? done,
  }) async {
    try {
      await call();
    } on DBusMethodResponseException catch (error) {
      if (error.errorName == done) return;
      throw _exception(api, error.errorName);
    } on SocketException {
      throw const MidiUnsupported('Bluetooth (no D-Bus system bus)');
    }
  }

  static MidiException _exception(String api, String errorName) =>
      switch (errorName) {
        _serviceUnknown => const MidiUnsupported(
          'Bluetooth (the BlueZ daemon does not run)',
        ),
        'org.freedesktop.DBus.Error.AccessDenied' ||
        'org.bluez.Error.NotAuthorized' ||
        'org.bluez.Error.NotPermitted' => const MidiPermissionDenied(
          MidiPermission.bluetooth,
        ),
        _ => MidiNativeError(api: '$api ($errorName)', code: -_eio),
      };

  /// Waits for [future] and ignores its errors, for clean-up calls.
  static Future<void> _quietly(Future<void> future) async {
    try {
      await future;
    } on Object {
      return;
    }
  }
}

// #############################################################################
/// The state of the running scan.
final class _Scan {
  _Scan(this.controller);

  final StreamController<MidiBlePeripheralInfo> controller;
  final subscriptions = <StreamSubscription<Object?>>[];
  BlueZAdapter? adapter;
  Timer? timer;
}

// #############################################################################
/// An open connection to the BLE-MIDI characteristic of one device.
final class _BlueZConnection implements MidiBleConnection {
  _BlueZConnection._({
    required this.peripheralId,
    required this._characteristic,
    required this._device,
    required this._mtu,
  });

  /// Subscribes to the characteristic at [path] of [device] and starts its
  /// notifications.
  static Future<_BlueZConnection> open({
    required DBusClient bus,
    required BlueZClient client,
    required BlueZDevice device,
    required String peripheralId,
    required DBusObjectPath path,
    required int? mtu,
  }) async {
    final connection = _BlueZConnection._(
      peripheralId: peripheralId,
      characteristic: DBusRemoteObject(bus, name: 'org.bluez', path: path),
      device: device,
      mtu: mtu,
    );
    connection._subscriptions.addAll([
      connection._characteristic.propertiesChanged.listen(connection._changed),
      device.propertiesChanged.listen((_) {
        if (!device.connected) connection._end();
      }),
      client.deviceRemoved.listen((removed) {
        if (removed.path == device.path) connection._end();
      }),
    ]);
    try {
      await MidiBlueZBleTransport._call(
        '$_interface.StartNotify',
        () => connection._characteristic.callMethod(
          _interface,
          'StartNotify',
          const [],
          replySignature: DBusSignature.empty,
        ),
      );
    } on Object {
      connection._end();
      rethrow;
    }
    return connection;
  }

  // ...........................................................................
  @override
  Future<void> write(Uint8List packet) => MidiBlueZBleTransport._call(
    '$_interface.WriteValue',
    () => _characteristic.callMethod(_interface, 'WriteValue', [
      DBusArray.byte(packet),
      DBusDict.stringVariant({'type': const DBusString('command')}),
    ], replySignature: DBusSignature.empty),
  );

  @override
  Future<void> disconnect() async {
    if (_done.isCompleted) return;
    await MidiBlueZBleTransport._quietly(
      _characteristic.callMethod(
        _interface,
        'StopNotify',
        const [],
        replySignature: DBusSignature.empty,
      ),
    );
    await MidiBlueZBleTransport._quietly(_device.disconnect());
    _end();
  }

  // ...........................................................................
  @override
  final String peripheralId;

  @override
  Stream<Uint8List> get notifications => _notifications.stream;

  @override
  int get maxPacketLength => (_mtu ?? 23) - 3;

  @override
  Future<void> get done => _done.future;

  // ...........................................................................
  static const _interface = 'org.bluez.GattCharacteristic1';

  final DBusRemoteObject _characteristic;
  final BlueZDevice _device;
  int? _mtu;
  final _notifications = StreamController<Uint8List>();
  final _done = Completer<void>();
  final _subscriptions = <StreamSubscription<Object?>>[];

  void _changed(DBusPropertiesChangedSignal signal) {
    if (signal.propertiesInterface != _interface) return;
    final changed = signal.changedProperties;
    final mtu = changed['MTU'];
    if (mtu is DBusUint16) _mtu = mtu.value;
    final value = changed['Value'];
    if (value != null && !_done.isCompleted) {
      _notifications.add(Uint8List.fromList(value.asByteArray().toList()));
    }
  }

  /// Ends the connection once: stops listening and completes [done].
  void _end() {
    if (_done.isCompleted) return;
    _done.complete();
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    unawaited(_notifications.close());
  }
}
