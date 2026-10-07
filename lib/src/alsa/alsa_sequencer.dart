// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'alsa_client_info.dart';
import 'alsa_event.dart';

// #############################################################################
/// One open handle of the ALSA sequencer (`snd_seq_t`): a sequencer client.
///
/// The native implementation calls alsa-lib; tests use a fake. Every call
/// is synchronous and throws the exception of `AlsaErrors.exception` when
/// alsa-lib reports an error.
abstract interface class AlsaSequencer {
  // ...........................................................................
  /// Sets the name other applications see for the client.
  void setClientName(String name);

  /// Switches the client to UMP with the MIDI 2.0 protocol and returns
  /// whether that worked; it fails without throwing on alsa-lib before
  /// 1.2.10 and kernels without UMP sequencer support.
  bool enableUmp();

  /// Sets the sizes of the kernel event pools of the client in events,
  /// best effort; null leaves a pool as it is.
  void setPools({int? input, int? output});

  // ...........................................................................
  /// Creates a port named [name] with the `SND_SEQ_PORT_CAP_*` bits
  /// [capability] and the `SND_SEQ_PORT_TYPE_*` bits [type] and returns its
  /// number; with [timestampQueue] every event the port receives carries
  /// the real time of that queue.
  int createPort({
    required String name,
    required int capability,
    required int type,
    int? timestampQueue,
  });

  /// Deletes the own [port].
  void deletePort(int port);

  /// Subscribes the own [port] to the port [client]:[sourcePort], so it
  /// receives what that port sends.
  void connectFrom({
    required int port,
    required int client,
    required int sourcePort,
  });

  /// Ends the subscription of [connectFrom].
  void disconnectFrom({
    required int port,
    required int client,
    required int sourcePort,
  });

  /// Returns all clients of the system with their ports.
  List<AlsaClientInfo> clients();

  // ...........................................................................
  /// Allocates a queue named [name], starts it and returns its number.
  int startQueue(String name);

  /// Returns the real time of [queue] in microseconds.
  int queueTime(int queue);

  /// Stops and frees [queue]; its pending events are dropped.
  void freeQueue(int queue);

  // ...........................................................................
  /// Hands [event] to the sequencer without user-space buffering.
  void output(AlsaEvent event);

  /// Removes the events this client queued on [queue] for the destination
  /// [destClient]:[destPort], restricted to [tag] when given.
  void removeEvents({
    required int queue,
    required int destClient,
    required int destPort,
    int? tag,
  });

  // ...........................................................................
  /// Closes the handle; the client and its ports disappear.
  void close();

  // ...........................................................................
  /// The client number of the handle.
  int get clientId;
}
