// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

/// The Linux backend of the aud_midi family: the ALSA sequencer through
/// alsa-lib in pure Dart (MIDI 1.0 and UMP), BLE-MIDI over BlueZ and DNS-SD
/// advertising over Avahi.
library;

export 'src/avahi/midi_avahi_service_advertiser.dart';
export 'src/ble/midi_bluez_ble_transport.dart';
export 'src/linux_midi_backend.dart';
