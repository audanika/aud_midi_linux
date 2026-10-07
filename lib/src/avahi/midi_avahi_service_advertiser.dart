// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:aud_midi_core/aud_midi_core.dart';
import 'package:aud_midi_standard/aud_midi_standard.dart';
import 'package:dbus/dbus.dart';

// #############################################################################
/// A [MidiServiceAdvertiser] on the Avahi daemon, the DNS-SD registrar of
/// Linux, over its D-Bus API.
///
/// Each registration is an Avahi entry group: `EntryGroupNew`, then
/// `AddService` and `Commit`. The advertiser waits for the group to be
/// established; on a name collision it asks Avahi for an alternative name
/// (`GetAlternativeServiceName`) and tries again. Avahi withdraws the
/// services of a client that disconnects, so the D-Bus connection stays
/// open while registrations exist; [close] ends it.
final class MidiAvahiServiceAdvertiser implements MidiServiceAdvertiser {
  /// Creates an advertiser that opens its D-Bus connection with [openBus],
  /// by default to the system bus.
  ///
  /// - [timeout] how long [register] waits for Avahi to confirm a name; a
  ///   registration that is still probing then counts as registered.
  /// - [maxRenames] how often a colliding name is replaced.
  MidiAvahiServiceAdvertiser({
    DBusClient Function()? openBus,
    this.timeout = const Duration(seconds: 5),
    this.maxRenames = 12,
  }) : _openBus = openBus ?? DBusClient.system;

  // ...........................................................................
  /// Registers the service [name] of [type], e.g. `_apple-midi._udp`, on
  /// [port] on all interfaces with the TXT record entries [txt].
  ///
  /// Throws a [MidiUnsupported] when Avahi does not run, a
  /// [MidiPermissionDenied] when D-Bus refuses access and a
  /// [MidiNativeError] when Avahi refuses the service.
  @override
  Future<MidiServiceRegistration> register({
    required String name,
    required String type,
    required int port,
    Map<String, String> txt = const {},
  }) async {
    final bus = _bus ??= _openBus();
    final server = DBusRemoteObject(
      bus,
      name: _service,
      path: DBusObjectPath.root,
    );
    final path = await _call(
      'EntryGroupNew',
      () => server.callMethod(
        _serverInterface,
        'EntryGroupNew',
        const [],
        replySignature: DBusSignature.objectPath,
      ),
    );
    final group = _EntryGroup(
      DBusRemoteObject(
        bus,
        name: _service,
        path: path.returnValues.first.asObjectPath(),
      ),
    );
    try {
      final registered = await _publish(server, group, name, type, port, txt);
      return _AvahiRegistration(group, registered);
    } on Object {
      await group.free();
      rethrow;
    }
  }

  /// Closes the D-Bus connection; Avahi withdraws all registrations, and
  /// the next registration opens a new connection.
  Future<void> close() async {
    final bus = _bus;
    _bus = null;
    if (bus != null) await bus.close();
  }

  // ...........................................................................
  /// How long [register] waits for Avahi to confirm a name.
  final Duration timeout;

  /// How often a colliding name is replaced.
  final int maxRenames;

  // ...........................................................................
  final DBusClient Function() _openBus;
  DBusClient? _bus;

  static const _service = 'org.freedesktop.Avahi';
  static const _serverInterface = 'org.freedesktop.Avahi.Server';
  static const _groupInterface = 'org.freedesktop.Avahi.EntryGroup';

  /// `AVAHI_ENTRY_GROUP_ESTABLISHED`, `_COLLISION` and `_FAILURE`.
  static const _established = 2;
  static const _collision = 3;
  static const _failure = 4;

  static const _eio = 5;

  /// Adds the service to [group] and commits it under [name] or, after
  /// collisions, an alternative name; returns the registered name.
  Future<String> _publish(
    DBusRemoteObject server,
    _EntryGroup group,
    String name,
    String type,
    int port,
    Map<String, String> txt,
  ) async {
    var current = name;
    for (var renames = 0; ; renames++) {
      final state = await _commit(group, current, type, port, txt);
      if (state != _collision) return current;
      if (renames >= maxRenames) {
        throw MidiNativeError(
          api: '$_groupInterface.Commit (name collision of $name)',
          code: -_eio,
        );
      }
      current = await _alternativeName(server, current);
      await _call('Reset', () => group.call('Reset'));
    }
  }

  /// Adds and commits the service; returns the established state, the
  /// collision state or null when Avahi did not answer in time.
  Future<int?> _commit(
    _EntryGroup group,
    String name,
    String type,
    int port,
    Map<String, String> txt,
  ) async {
    try {
      await group.call('AddService', [
        const DBusInt32(-1),
        const DBusInt32(-1),
        const DBusUint32(0),
        DBusString(name),
        DBusString(type),
        const DBusString(''),
        const DBusString(''),
        DBusUint16(port),
        DBusArray(DBusSignature('ay'), [
          for (final MapEntry(:key, :value) in txt.entries)
            DBusArray.byte(utf8.encode('$key=$value')),
        ]),
      ]);
    } on DBusMethodResponseException catch (error) {
      if (error.errorName == 'org.freedesktop.Avahi.CollisionError') {
        return _collision;
      }
      throw _exception('AddService', error.errorName);
    }
    await _call('Commit', () => group.call('Commit'));
    final state = await group.nextFinalState(timeout);
    if (state == _failure) {
      throw MidiNativeError(
        api: '$_groupInterface.Commit (failure: ${group.error})',
        code: -_eio,
      );
    }
    return state;
  }

  Future<String> _alternativeName(DBusRemoteObject server, String name) async {
    final response = await _call(
      'GetAlternativeServiceName',
      () => server.callMethod(_serverInterface, 'GetAlternativeServiceName', [
        DBusString(name),
      ], replySignature: DBusSignature.string),
    );
    return response.returnValues.first.asString();
  }

  /// Runs the Avahi call [method] and maps its errors to [MidiException]s;
  /// a bus that cannot be reached is dropped, the next call opens a new
  /// one.
  Future<T> _call<T>(String method, Future<T> Function() call) async {
    try {
      return await call();
    } on DBusMethodResponseException catch (error) {
      throw _exception(method, error.errorName);
    } on SocketException {
      final bus = _bus;
      _bus = null;
      if (bus != null) unawaited(bus.close());
      throw const MidiUnsupported('DNS-SD advertising (no D-Bus system bus)');
    }
  }

  static MidiException _exception(String method, String errorName) =>
      switch (errorName) {
        'org.freedesktop.DBus.Error.ServiceUnknown' => const MidiUnsupported(
          'DNS-SD advertising (the Avahi daemon does not run)',
        ),
        'org.freedesktop.DBus.Error.AccessDenied' => const MidiPermissionDenied(
          MidiPermission.localNetwork,
        ),
        _ => MidiNativeError(api: 'Avahi $method ($errorName)', code: -_eio),
      };
}

// #############################################################################
/// An Avahi entry group and the states it reports.
final class _EntryGroup {
  _EntryGroup(this.object) {
    _subscription = DBusRemoteObjectSignalStream(
      object: object,
      interface: MidiAvahiServiceAdvertiser._groupInterface,
      name: 'StateChanged',
      signature: DBusSignature('is'),
    ).listen(_onState);
  }

  final DBusRemoteObject object;
  late final StreamSubscription<DBusSignal> _subscription;
  final _states = Queue<int>();
  Completer<void>? _arrived;

  /// The error text of the last state.
  String error = '';

  /// Calls [method] of the entry group.
  Future<void> call(String method, [List<DBusValue> values = const []]) =>
      object.callMethod(
        MidiAvahiServiceAdvertiser._groupInterface,
        method,
        values,
        replySignature: DBusSignature.empty,
      );

  /// Returns the next state that ends registering (established, collision
  /// or failure), or null when none arrives within [timeout].
  Future<int?> nextFinalState(Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    for (;;) {
      while (_states.isNotEmpty) {
        final state = _states.removeFirst();
        if (state >= MidiAvahiServiceAdvertiser._established) return state;
      }
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) return null;
      final arrived = _arrived = Completer<void>();
      try {
        await arrived.future.timeout(remaining);
      } on TimeoutException {
        return null;
      }
    }
  }

  /// Frees the group; Avahi withdraws its services. A group that is gone
  /// already, e.g. after a restart of Avahi, is ignored.
  Future<void> free() async {
    await _subscription.cancel();
    try {
      await call('Free');
    } on DBusMethodResponseException {
      return;
    }
  }

  void _onState(DBusSignal signal) {
    _states.add(signal.values[0].asInt32());
    error = signal.values[1].asString();
    final arrived = _arrived;
    _arrived = null;
    arrived?.complete();
  }
}

// #############################################################################
/// A service registered through Avahi.
final class _AvahiRegistration implements MidiServiceRegistration {
  _AvahiRegistration(this._group, this.name);

  @override
  Future<void> unregister() => _group.free();

  @override
  final String name;

  final _EntryGroup _group;
}
