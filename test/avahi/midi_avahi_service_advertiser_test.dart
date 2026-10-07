// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aud_midi_core/aud_midi_core.dart';
import 'package:aud_midi_linux/aud_midi_linux.dart';
import 'package:aud_midi_standard/aud_midi_standard.dart';
import 'package:dbus/dbus.dart';
import 'package:test/test.dart';

const _registering = 1;
const _established = 2;
const _collision = 3;
const _failure = 4;

// #############################################################################
/// `org.freedesktop.Avahi.Server` of the mock Avahi.
final class _Server extends DBusObject {
  _Server() : super(DBusObjectPath.root);

  final groups = <_Group>[];
  final errors = <String, String>{};
  final taken = <String>{};

  /// The states a group reports after committing the service [name].
  List<int> Function(String name) states = (_) => [_registering, _established];

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall methodCall) async {
    final error = errors[methodCall.name];
    if (error != null) return DBusMethodErrorResponse(error);
    switch (methodCall.name) {
      case 'EntryGroupNew':
        final group = _Group('/Client1/EntryGroup${groups.length + 1}', this);
        groups.add(group);
        await client!.registerObject(group);
        return DBusMethodSuccessResponse([group.path]);
      case 'GetAlternativeServiceName':
        final name = methodCall.values.first.asString();
        final match = RegExp(r'^(.*) #(\d+)$').firstMatch(name);
        return DBusMethodSuccessResponse([
          DBusString(
            match == null
                ? '$name #2'
                : '${match[1]} #${int.parse(match[2]!) + 1}',
          ),
        ]);
    }
    return DBusMethodErrorResponse.unknownMethod();
  }
}

// #############################################################################
/// An `org.freedesktop.Avahi.EntryGroup` of the mock Avahi.
final class _Group extends DBusObject {
  _Group(String path, this.server) : super(DBusObjectPath(path));

  final _Server server;
  final calls = <String>[];
  final services = <List<Object>>[];
  String _name = '';

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall methodCall) async {
    calls.add(methodCall.name);
    final error = server.errors[methodCall.name];
    if (error != null) return DBusMethodErrorResponse(error);
    switch (methodCall.name) {
      case 'AddService':
        return _addService(methodCall);
      case 'Commit':
        final states = server.states(_name);
        unawaited(
          Future(() async {
            for (final state in states) {
              await emitSignal(
                'org.freedesktop.Avahi.EntryGroup',
                'StateChanged',
                [
                  DBusInt32(state),
                  DBusString(state == _failure ? 'Not permitted' : ''),
                ],
              );
            }
          }),
        );
      case 'Free':
        await client!.unregisterObject(this);
    }
    return DBusMethodSuccessResponse();
  }

  DBusMethodResponse _addService(DBusMethodCall methodCall) {
    if (methodCall.signature != DBusSignature('iiussssqaay')) {
      return DBusMethodErrorResponse.invalidArgs();
    }
    final v = methodCall.values;
    _name = v[3].asString();
    services.add([
      v[0].asInt32(),
      v[1].asInt32(),
      v[2].asUint32(),
      _name,
      v[4].asString(),
      v[5].asString(),
      v[6].asString(),
      v[7].asUint16(),
      [
        for (final entry in v[8].asArray())
          utf8.decode(entry.asByteArray().toList()),
      ],
    ]);
    if (server.taken.contains(_name)) {
      return DBusMethodErrorResponse('org.freedesktop.Avahi.CollisionError');
    }
    return DBusMethodSuccessResponse();
  }
}

void main() {
  late Directory directory;
  late DBusServer server;
  late DBusAddress address;
  late _Server avahi;
  late List<DBusClient> buses;
  late MidiAvahiServiceAdvertiser advertiser;
  DBusClient? service;

  DBusClient connect() =>
      DBusClient(address, authClient: DBusAuthClient(uid: '1'));

  DBusClient open() {
    final bus = connect();
    buses.add(bus);
    return bus;
  }

  Future<void> startAvahi() async {
    final bus = service = connect();
    await bus.requestName('org.freedesktop.Avahi');
    await bus.registerObject(avahi);
  }

  MidiAvahiServiceAdvertiser create({
    Duration timeout = const Duration(seconds: 5),
    int maxRenames = 12,
  }) => MidiAvahiServiceAdvertiser(
    openBus: open,
    timeout: timeout,
    maxRenames: maxRenames,
  );

  Future<MidiServiceRegistration> register({String name = 'Studio'}) =>
      advertiser.register(
        name: name,
        type: '_apple-midi._udp',
        port: 5004,
        txt: {'model': 'Linux', 'id': '7'},
      );

  setUp(() async {
    directory = Directory.systemTemp.createTempSync('aud_midi_avahi');
    server = DBusServer();
    address = await server.listenAddress(DBusAddress.unix(dir: directory));
    avahi = _Server();
    buses = [];
    service = null;
    advertiser = create();
  });

  tearDown(() async {
    await advertiser.close();
    await service?.close();
    await server.close();
    directory.deleteSync(recursive: true);
  });

  group('MidiAvahiServiceAdvertiser', () {
    group('MidiAvahiServiceAdvertiser(openBus, timeout, maxRenames)', () {
      test('opens the system bus lazily and has defaults', () async {
        final defaults = MidiAvahiServiceAdvertiser();
        await defaults.close();
        expect(
          [defaults.timeout, defaults.maxRenames, buses],
          [const Duration(seconds: 5), 12, isEmpty],
        );
      });
    });

    group('register(name, type, port, txt)', () {
      test('adds the service to a new entry group and commits it', () async {
        await startAvahi();
        final registration = await register();
        final group = avahi.groups.single;
        expect(
          [registration.name, group.services, group.calls],
          [
            'Studio',
            [
              [
                -1,
                -1,
                0,
                'Studio',
                '_apple-midi._udp',
                '',
                '',
                5004,
                ['model=Linux', 'id=7'],
              ],
            ],
            ['AddService', 'Commit'],
          ],
        );
      });

      test('renames the service after a collision', () async {
        await startAvahi();
        avahi.states = (name) => name == 'Studio'
            ? [_registering, _collision]
            : [_registering, _established];
        final registration = await register();
        expect(
          [registration.name, avahi.groups.single.calls],
          [
            'Studio #2',
            ['AddService', 'Commit', 'Reset', 'AddService', 'Commit'],
          ],
        );
      });

      test('renames a service whose name is taken locally', () async {
        await startAvahi();
        avahi.taken.addAll(['Studio', 'Studio #2']);
        final registration = await register();
        expect(
          [registration.name, avahi.groups.single.calls],
          [
            'Studio #3',
            [
              'AddService',
              'Reset',
              'AddService',
              'Reset',
              'AddService',
              'Commit',
            ],
          ],
        );
      });

      test('gives up after too many renames', () async {
        await startAvahi();
        advertiser = create(maxRenames: 1);
        avahi.states = (_) => [_collision];
        await expectLater(
          register(),
          throwsA(
            isA<MidiNativeError>().having(
              (e) => e.api,
              'api',
              contains('name collision of Studio'),
            ),
          ),
        );
        expect(avahi.groups.single.calls.last, 'Free');
      });

      test('reports a failed registration', () async {
        await startAvahi();
        avahi.states = (_) => [_registering, _failure];
        await expectLater(
          register(),
          throwsA(
            isA<MidiNativeError>().having(
              (e) => e.api,
              'api',
              contains('failure: Not permitted'),
            ),
          ),
        );
        expect(avahi.groups.single.calls.last, 'Free');
      });

      test('accepts a service that is still probing at the timeout', () async {
        await startAvahi();
        advertiser = create(timeout: const Duration(milliseconds: 50));
        avahi.states = (_) => [_registering];
        final registration = await register();
        expect(registration.name, 'Studio');
      });

      test('reports a missing Avahi daemon', () async {
        await expectLater(
          register(),
          throwsA(
            isA<MidiUnsupported>().having(
              (e) => e.feature,
              'feature',
              contains('Avahi daemon'),
            ),
          ),
        );
      });

      test('reports a refused bus access as a missing permission', () async {
        await startAvahi();
        avahi.errors['EntryGroupNew'] =
            'org.freedesktop.DBus.Error.AccessDenied';
        await expectLater(
          register(),
          throwsA(
            isA<MidiPermissionDenied>().having(
              (e) => e.permission,
              'permission',
              MidiPermission.localNetwork,
            ),
          ),
        );
      });

      for (final method in [
        'AddService',
        'Commit',
        'GetAlternativeServiceName',
        'Reset',
      ]) {
        test('reports a refused $method as a native error', () async {
          await startAvahi();
          avahi.taken.add('Studio');
          avahi.errors[method] = 'org.freedesktop.Avahi.InvalidArgumentError';
          await expectLater(
            register(),
            throwsA(
              isA<MidiNativeError>()
                  .having(
                    (e) => e.api,
                    'api',
                    'Avahi $method '
                        '(org.freedesktop.Avahi.InvalidArgumentError)',
                  )
                  .having((e) => e.code, 'code', -5),
            ),
          );
        });
      }

      test('reports a missing bus and opens a new one next time', () async {
        await startAvahi();
        var first = true;
        advertiser = MidiAvahiServiceAdvertiser(
          openBus: () {
            if (!first) return open();
            first = false;
            return DBusClient(
              DBusAddress.unix(path: '${directory.path}/missing'),
              authClient: DBusAuthClient(uid: '1'),
            );
          },
        );
        await expectLater(
          register(),
          throwsA(
            isA<MidiUnsupported>().having(
              (e) => e.feature,
              'feature',
              contains('no D-Bus system bus'),
            ),
          ),
        );
        expect((await register()).name, 'Studio');
      });
    });

    group('unregister()', () {
      test('frees the entry group once', () async {
        await startAvahi();
        final registration = await register();
        await registration.unregister();
        await registration.unregister();
        expect(avahi.groups.single.calls, ['AddService', 'Commit', 'Free']);
      });
    });

    group('close()', () {
      test('ends the connection, the next registration opens one', () async {
        await startAvahi();
        await register();
        await advertiser.close();
        await register(name: 'Studio 2');
        expect([buses.length, avahi.groups.length], [2, 2]);
      });
    });
  });
}
