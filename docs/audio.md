# Audio

The card records **Opus, 16 kHz, mono**, at about 16 kbit/s (2 KB per second
of audio).

- A `.opus` file from the card is **not** an Ogg Opus file. It is Opus packets
  stored back to back with no container: every packet is **40 bytes = 20 ms**.
- Live audio arrives in notifications of 160 bytes = 4 packets.
- Split with `opusPackets(bytes)` and decode **each packet on its own**. A
  decoder given a whole notification or file produces noise or fails.

## Decoding on the phone

The SDK does not bundle a codec. A common choice is
[opus_dart](https://pub.dev/packages/opus_dart) with
[opus_flutter](https://pub.dev/packages/opus_flutter) (both BSD-2-Clause; opus_flutter loads libopus on Android, iOS and Windows, not macOS):

```dart
import 'package:opus_dart/opus_dart.dart';
import 'package:opus_flutter/opus_flutter.dart' as opus_flutter;
import 'package:talkanote/talkanote.dart';

initOpus(await opus_flutter.load());
final decoder = SimpleOpusDecoder(sampleRate: CardAudio.sampleRate, channels: CardAudio.channels);

final pcm = BytesBuilder();
for (final packet in opusPackets(opusFile)) {
  final samples = decoder.decode(input: packet); // Int16List, 320 samples
  pcm.add(samples.buffer.asUint8List());
}
decoder.destroy();

final wav = wavFromPcm16(pcm.toBytes()); // ready to play or upload
```

## Decoding elsewhere

- **Browser:** WebCodecs `AudioDecoder` with
  `{codec: 'opus', sampleRate: 16000, numberOfChannels: 1}`; one
  `EncodedAudioChunk` per 40-byte packet, timestamps 20 000 µs apart.
- **Server (Python):** `opuslib` or PyAV, one packet at a time. Or upload the raw
  `.opus` file and decode server-side, which keeps the phone's work small.

## Speech-to-text

16 kHz mono PCM suits most speech-to-text engines. Send audio in sentence-sized
pieces (voice activity detection) for live captions; for files, send the whole
decoded WAV.

## Sizes

| Length | Opus | WAV (16-bit) | Bluetooth download (Opus) |
|---|---|---|---|
| 1 minute | ≈ 120 KB | ≈ 1.9 MB | ≈ 50 s |
| 1 hour | ≈ 7 MB | ≈ 115 MB | ≈ 48 min |
