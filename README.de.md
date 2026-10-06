# aud_midi_linux

Das Linux-Backend von aud_midi in reinem Dart: ALSA-Sequencer (MIDI 1.0 und UMP) über FFI, BLE über BlueZ und Avahi über D-Bus.

Teil der aud_midi-Familie, siehe [aud_midi](https://github.com/audanika/aud_midi).

## Ziele

- ALSA-Sequencer-Ports, virtuelle Ports, Hotplug, Queues
- UMP-Clients ab Kernel 6.5
- BLE-MIDI über BlueZ-D-Bus
- Avahi-Advertising
- BLE-Peripheral über den BlueZ-GATT-Server

## Stand

Nur Boilerplate. Die Implementierung folgt in späteren Tickets, siehe den Plan in [aud_midi_pm](https://github.com/audanika/aud_midi_pm/blob/main/doc/2026-Q4/tickets/2026-10-06-aud_midi_01-initial-midi-implementation.md).

## Installation

```bash
dart pub add aud_midi_linux
```

## Mitwirken

Siehe [doc/guides/develop-guide.md](doc/guides/develop-guide.md).
