// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_midi_standard/aud_midi_standard.dart';

// #############################################################################
/// Compares two port lists and describes the difference as port events.
abstract final class AlsaPortDiff {
  // ...........................................................................
  /// Returns the events that turn [before] into [after]: removed ports
  /// first (in the state [MidiPortState.disconnected]), then changed ports,
  /// then added ports, each group in list order. Ports are matched by id;
  /// a port whose description differs is changed.
  static List<MidiPortEvent> events({
    required List<MidiPortInfo> before,
    required List<MidiPortInfo> after,
  }) {
    final old = {for (final port in before) port.id: port};
    final now = {for (final port in after) port.id: port};
    return [
      for (final port in before)
        if (!now.containsKey(port.id))
          MidiPortRemoved(
            port: port.copyWith(state: MidiPortState.disconnected),
          ),
      for (final port in after)
        if (old[port.id] case final previous? when previous != port)
          MidiPortChanged(port: port, previous: previous),
      for (final port in after)
        if (!old.containsKey(port.id)) MidiPortAdded(port: port),
    ];
  }
}
