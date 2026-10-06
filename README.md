# aud_midi_linux

The Linux backend of aud_midi in pure Dart: ALSA sequencer (MIDI 1.0 and UMP) through FFI, BLE over BlueZ and Avahi over D-Bus.

Part of the aud_midi family, see [aud_midi](https://github.com/audanika/aud_midi).

## Goals

- ALSA sequencer ports, virtual ports, hotplug, queues
- UMP clients on kernel 6.5+
- BLE MIDI over BlueZ D-Bus
- Avahi advertising

## State

Boilerplate only. The implementation follows in later tickets, see the plan in [aud_midi_pm](https://github.com/audanika/aud_midi_pm/blob/main/doc/2026-Q4/tickets/2026-10-06-aud_midi_01-initial-midi-implementation.md).

## Installation

```bash
dart pub add aud_midi_linux
```

## Contributing

See [doc/guides/develop-guide.md](doc/guides/develop-guide.md).
