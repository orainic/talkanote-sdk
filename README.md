# talkaNote SDK

Flutter SDK for the **talkaNote** recording card: connect over Bluetooth LE,
read the card's status, control recording, list, download and delete
recordings, and receive live audio while the card records.

One Dart API for Android, iOS, macOS and Windows apps.

| | |
|---|---|
| Status | 0.1.0, Bluetooth. Wi-Fi transfer is planned, see [docs/wifi.md](docs/wifi.md) |
| Tested on | talkaNote Wi-Fi card, firmware 544 (Windows, 2026-11-27) |
| Platforms | Android 5.0+ (API 21), iOS 13.1+, macOS 10.15+, Windows 10+ |
| Bluetooth | [universal_ble](https://pub.dev/packages/universal_ble) (BSD-3-Clause) |
| Licence | MIT, see [LICENSE](LICENSE) |

## Install

```yaml
dependencies:
  talkanote:
    git:
      url: https://github.com/orainic/talkanote-sdk.git
      ref: v0.1.0
```

Platform setup (permissions) is in [docs/platform-setup.md](docs/platform-setup.md).

## Quick start

```dart
import 'package:talkanote/talkanote.dart';

await TalkaNote.requestPermissions();

// Cards advertise as "CB08"; several cards can share the name, so keep the id.
final found = await TalkaNote.scan().first;
final card = await TalkaNote.connect(found); // also sets the card's clock

print(await card.battery());          // Battery(87%)
print(await card.firmwareVersion());  // V1.0.0

final files = await card.listFiles(); // oldest first
final opus = await card.download(
  files.last,
  onProgress: (got, total) => print('$got / $total'),
);

await card.delete(files.last);
```

### Live audio

```dart
card.liveEvents.listen((e) {
  switch (e) {
    case LiveStarted(:final fileName): print('recording to $fileName');
    case LiveAudio(:final opus):
      for (final packet in opusPackets(opus)) {
        // decode each 40-byte packet on its own, see docs/audio.md
      }
    case LiveStopped(): print('stopped');
    default:
  }
});
await card.startRecording(); // the card records and streams
// ...
await card.saveRecording();
```

### The card's button

When someone presses the button on the card, the card asks the app first and
waits for the answer. **If nothing answers, the card drops the connection.**
The SDK answers automatically and reports the press:

```dart
card.buttonEvents.listen((e) => print('button: ${e.action}'));
```

To decide yourself, connect with `autoAnswerButtons: false` and call
`card.answerButton(e.action, accept: true)` within a second or two.

### App lifecycle

Tell the card when your app goes to the background and comes back:

```dart
card.setAppForeground(false); // in AppLifecycleState.paused
card.setAppForeground(true);  // in AppLifecycleState.resumed
```

## API

| `TalkaNote` | |
|---|---|
| `requestPermissions()` | Bluetooth permissions (Android 12+, iOS) |
| `scan({timeout})` | `Stream<DiscoveredCard>`: `id`, `name`, `rssi`, `model` |
| `connect(card)` / `connectById(id)` | returns a `TalkaNoteCard`; syncs the clock |

| `TalkaNoteCard` | |
|---|---|
| `battery()` | `Battery(percent, charging)` |
| `storage()` | `Storage(freeKb, totalKb)` |
| `firmwareVersion()` | e.g. `V1.0.0` |
| `syncTime([DateTime])` | the card names recordings by its clock |
| `recordingState()` | `idle`, `recording`, `paused` |
| `startRecording()` `saveRecording()` `pauseRecording()` `resumeRecording()` | the card records and streams to `liveEvents`; it sends no confirmation, so check `recordingState()` |
| `recordingTime()` `currentFileName()` | while recording |
| `gain()` / `setGain(Gain.low/medium/high)` | microphone gain |
| `listFiles()` | `List<CardFile>`: `name`, `duration`, `size`, `mode` (note/call), `recordedAt` |
| `download(file, {format, offset, onProgress, onData})` | `Uint8List`; resumes after stalls |
| `abortDownload()` | |
| `delete(file)` / `deleteAll()` | `true`, `false`, or `null` if the firmware sent no answer |
| `buttonEvents`, `liveEvents`, `disconnected` | streams / future |
| `setAppForeground(bool)`, `answerButton(action)`, `disconnect()` | |

## Rules that matter

1. **Don't transfer files while the card records.** Check `recordingState()`
   first.
2. **Use `CardFile.name` unchanged** for download and delete.
3. **Bluetooth is slow, about 2.5 KB/s.** A 1-hour meeting is about 7 MB of
   Opus, roughly 48 minutes to download. Download Opus, not WAV (WAV is 16 times
   larger), and decode on the phone or your server.
4. **One app at a time.** The card accepts one Bluetooth connection.
5. **The card has no pairing or password.** Any app with this SDK can connect to
   a card in range. Keep cards with their owners and delete recordings you have
   uploaded.
6. **Recordings are personal data.** Tell people they are being recorded, and
   follow the privacy law where you operate.

## Docs

- [docs/platform-setup.md](docs/platform-setup.md): Android, iOS, macOS and Windows setup
- [docs/audio.md](docs/audio.md): the Opus format and how to decode it
- [docs/protocol.md](docs/protocol.md): the Bluetooth protocol, for other languages and tools
- [docs/wifi.md](docs/wifi.md): Wi-Fi models and what is planned
- [example/](example/): a small app that scans, connects, lists, downloads, deletes and records

## Development

```sh
flutter test                       # unit tests, no card needed
cd example
flutter run                        # the example app
flutter test integration_test -d windows --dart-define=CARD_ID=<card id>   # against a real card
```

The integration test records about 5 seconds, downloads that recording and
deletes it again.

Support: ai@talkaflow.com
