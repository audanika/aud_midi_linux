// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:ffi';

import 'package:aud_midi_core/aud_midi_core.dart';

import 'alsa_bindings.g.dart';

// #############################################################################
/// The loaded alsa-lib (`libasound.so.2`) with its bindings.
///
/// The bindings look symbols up on first use, so functions that older
/// alsa-lib releases lack, e.g. the UMP API of 1.2.10, only fail when
/// called; check them with [provides] first.
final class AlsaLibrary {
  /// Loads the library [name] with [open].
  ///
  /// Throws a [MidiUnsupported] when the library cannot be loaded, e.g.
  /// because alsa-lib is not installed.
  factory AlsaLibrary.load({
    String name = defaultName,
    DynamicLibrary Function(String name) open = DynamicLibrary.open,
  }) {
    final DynamicLibrary library;
    try {
      library = open(name);
    } on ArgumentError catch (error) {
      throw MidiUnsupported('ALSA: $name cannot be loaded (${error.message})');
    }
    return AlsaLibrary._(library);
  }

  AlsaLibrary._(this.library) : bindings = AlsaBindings(library);

  // ...........................................................................
  /// Returns whether the library exports [symbol].
  bool provides(String symbol) => library.providesSymbol(symbol);

  // ...........................................................................
  /// The loaded library.
  final DynamicLibrary library;

  /// The bindings of the sequencer API.
  final AlsaBindings bindings;

  // ...........................................................................
  /// The soname of alsa-lib.
  static const String defaultName = 'libasound.so.2';
}
