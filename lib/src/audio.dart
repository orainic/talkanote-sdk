import 'dart:typed_data';

/// The card's audio: Opus, 16 kHz, mono.
abstract final class CardAudio {
  static const sampleRate = 16000;
  static const channels = 1;

  /// Every Opus packet is 40 bytes and holds 20 ms of audio.
  static const opusPacketBytes = 40;
  static const packetDuration = Duration(milliseconds: 20);
  static const samplesPerPacket = 320;
}

/// Splits raw card audio (a live notification or a downloaded `.opus` file)
/// into Opus packets. The card stores packets back to back with no container,
/// so decode each packet on its own; never pass a whole notification to the
/// decoder.
Iterable<Uint8List> opusPackets(Uint8List opus) sync* {
  for (var i = 0; i + CardAudio.opusPacketBytes <= opus.length; i += CardAudio.opusPacketBytes) {
    yield Uint8List.sublistView(opus, i, i + CardAudio.opusPacketBytes);
  }
}

/// Length of [opusBytes] of card audio.
Duration opusDuration(int opusBytes) => CardAudio.packetDuration * (opusBytes ~/ CardAudio.opusPacketBytes);

/// Wraps 16-bit little-endian PCM in a WAV header.
Uint8List wavFromPcm16(Uint8List pcm, {int sampleRate = CardAudio.sampleRate, int channels = CardAudio.channels}) {
  final out = Uint8List(44 + pcm.length);
  final v = ByteData.sublistView(out);
  void tag(int at, String s) => out.setRange(at, at + 4, s.codeUnits);
  tag(0, 'RIFF');
  v.setUint32(4, 36 + pcm.length, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  v
    ..setUint32(16, 16, Endian.little)
    ..setUint16(20, 1, Endian.little)
    ..setUint16(22, channels, Endian.little)
    ..setUint32(24, sampleRate, Endian.little)
    ..setUint32(28, sampleRate * channels * 2, Endian.little)
    ..setUint16(32, channels * 2, Endian.little)
    ..setUint16(34, 16, Endian.little);
  tag(36, 'data');
  v.setUint32(40, pcm.length, Endian.little);
  out.setRange(44, out.length, pcm);
  return out;
}
