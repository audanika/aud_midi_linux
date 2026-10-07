# aud_midi_linux

Das Linux-Backend von aud_midi in reinem Dart: ALSA-Sequencer (MIDI 1.0 und UMP) über FFI, BLE über BlueZ und Avahi über D-Bus.

Teil der aud_midi-Familie, siehe [aud_midi](https://github.com/audmidi/aud_midi).

## Ziele

- ALSA-Sequencer-Ports, virtuelle Ports, Hotplug, Queues
- UMP-Clients ab Kernel 6.5
- BLE-MIDI über BlueZ-D-Bus
- Avahi-Advertising

## Stand

Umgesetzt (Planschritt 3 und der Linux-Teil von Schritt 7):

- `LinuxMidiBackend` (`MidiBackend`, Name `alsa`): Ports aller anderen
  Sequencer-Clients (Ein- und Ausgänge, Transport aus Client- und
  Port-Typ, UMP-Endpoint und Function Blocks), dynamische virtuelle Ports,
  Hotplug über den Announce-Port, Echtzeit-Queue für geplantes Senden und
  `cancelPending`, Empfangszeitstempel auf der Paketuhr, UMP-Modus
  (`snd_seq_set_client_midi_version`) mit MIDI-1.0-Rückfall,
  BLE-MIDI-Peripheriegeräte über `MidiBleBluetoothBackend` aus dem Core.
- `MidiBlueZBleTransport` (`MidiBleTransport`): Suchen, Verbinden,
  Notifications und Schreiben ohne Antwort auf der BLE-MIDI-Characteristic
  über BlueZ.
- `MidiAvahiServiceAdvertiser` (`MidiServiceAdvertiser`):
  DNS-SD-Registrierung über Avahi mit Umbenennen bei Namenskollisionen.

So ist es geprüft:

- Unit-Tests auf der Dart-VM (macOS): 100 % Zeilenabdeckung pro Datei. Die
  ganze Logik liegt hinter kleinen Schnittstellen mit Fakes; der BlueZ- und
  Avahi-Code läuft über eine echte D-Bus-Verbindung gegen nachgebaute
  Dienste im Prozess; ein Layout-Test prüft die generierten Structs
  (`snd_seq_event_t` 28 Byte, `snd_seq_ump_event_t` 32 Byte).
- In diesem Ticket nicht auf echtem Linux geprüft: der FFI-Klebecode
  (`lib/src/alsa/ffi_*.dart`, von der Abdeckung ausgenommen), das
  Reader-Isolate auf einem echten Handle, die BlueZ- und Avahi-Dienste. Die
  Linux-Tests unten decken den FFI-Code ab; auf anderen Systemen werden sie
  übersprungen.

### Linux-Tests ausführen

```bash
sudo apt-get install libasound2
sudo modprobe snd-seq
dart test test/alsa/ffi_alsa_sequencer_test.dart \
  test/alsa/ffi_alsa_reader_test.dart test/alsa/ffi_alsa_system_test.dart
```

Sie verbinden die eigene virtuelle Quelle des Backends mit seinem eigenen
virtuellen Ziel (Bytes, Reihenfolge, Zeitstempel, Abweichung beim
geplanten Senden, Abbrechen, SysEx, UMP wenn vorhanden) und beobachten
Hotplug eines Hilfs-Clients; Hardware ist nicht nötig.

### Berechtigungen und Paketierung

- `libasound2` zur Laufzeit, `/dev/snd/seq` (Kernelmodul `snd-seq`), auf
  manchen Distributionen der Benutzer in der Gruppe `audio`.
- BlueZ 5 mit Zugriff auf den System-D-Bus; der Avahi-Dienst fürs
  Advertising.
- Snap: Interfaces `alsa`, `bluez`, `avahi-control`, `network`.
- Flatpak: `--device=all`, `--system-talk-name=org.bluez`,
  `--system-talk-name=org.freedesktop.Avahi`.

## Installation

```bash
dart pub add aud_midi_linux
```

## Dokumentation

- Der Plan: [aud_midi_pm](https://github.com/audmidi/aud_midi_pm/blob/main/doc/2026-Q4/tickets/2026-10-06-aud_midi_01-initial-midi-implementation.md)
- Die Guides: [doc/guides](doc/guides)

## Codebeispiele

```dart
import 'package:aud_midi_core/aud_midi_core.dart';
import 'package:aud_midi_linux/aud_midi_linux.dart';
import 'package:aud_midi_standard/aud_midi_standard.dart';

Future<void> main() async {
  final engine = MidiEngine(backend: LinuxMidiBackend(clientName: 'My App'));
  await engine.open();
  for (final port in engine.ports) {
    print('${port.direction.name}: ${port.name} (${port.id})');
  }
  final out = await engine.createVirtualPort(
    MidiVirtualPortSpec(name: 'My App Out', direction: MidiDirection.output),
  );
  await engine.openOutput(out.id);
  await engine.send(
    out.id,
    const MidiNoteOn(channel: 0, note: 60, velocity: 100),
    at: engine.clock.now() + const Duration(milliseconds: 100),
  );
  await engine.close();
}
```

## Funktionsweise

- Zwei Sequencer-Clients: der Ausgabe-Client (der Name der App) sendet
  direkt adressierte Events und besitzt die virtuellen Quellen und die
  Queue; der Eingabe-Client (`<name> (in)`) besitzt die virtuellen Ziele
  und einen Eingangsport, der jede geöffnete Quelle und den Announce-Port
  abonniert.
- Ein Reader-Isolate blockiert in `snd_seq_event_input` auf dem
  Eingabe-Client, kopiert jedes Event in Dart-Objekte und schickt sie
  gebündelt ans Backend; ein Weck-Event mit zufälligem Token beendet es.
- Empfangene Events tragen die Echtzeit der Queue, über `CLOCK_MONOTONIC`
  auf die Paketuhr abgebildet; fällige Sendungen gehen direkt hinaus,
  spätere mit ihrer Zeit in die Queue; `cancelPending` entfernt sie nach
  Ziel (und bei eigenen Quellen nach Tag).
- Mit alsa-lib 1.2.10+ und Kernel 6.5+ schalten beide Clients auf UMP
  (MIDI 2.0); der Kernel übersetzt von und zu MIDI-1.0-Clients. Sonst
  tauschen die Ports MIDI-1.0-Bytes aus, umgewandelt wie alsa-libs
  `snd_midi_event`, SysEx in Stücken zu 256 Byte.
- Port-IDs sind `alsa:<client>:<port>:in|out`; eine wiederverwendete
  Client-Nummer bekommt eine Generation als Suffix (`alsa:20#1:0:in`).

### ALSA-Bindings neu erzeugen

`lib/src/alsa/alsa_bindings.g.dart` erzeugt ffigen aus den
alsa-lib-Headern, geparst für Linux x86_64 gegen die
Stub-System-Header in `tool/alsa_bindings/stubs` (das Ergebnis hängt so
nicht vom Host ab; aarch64 hat dieselben Layouts):

```bash
dart run tool/alsa_bindings/generate.dart              # klont v1.2.16.1
dart run tool/alsa_bindings/generate.dart --alsa-lib ../alsa-lib
```

Nötig ist libclang (Xcode auf macOS, `libclang-dev` auf Linux). Funktionen
neuer als alsa-lib 1.2.10 werden zur Laufzeit nachgeschlagen.

## Mitwirken

Siehe [doc/guides/develop-guide.md](doc/guides/develop-guide.md).
