import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:talkanote/talkanote.dart';

void main() {
  // Captured from a real card: button "start recording", SEQ 0.
  final captured = Uint8List.fromList([0x5A, 0x00, 0x1A, 0xA8, 0x02, 0x00, 0x03, 0x01]);

  test('CRC-16/XMODEM matches the standard check value', () {
    expect(crc16Xmodem('123456789'.codeUnits), 0x31C3);
  });

  test('encodes a frame exactly as the card sends it', () {
    expect(encodeFrame(0, FrameType.recording, RecordCmd.start), captured);
  });

  test('parses frames split across notifications and packed together', () {
    final two = Uint8List.fromList([
      ...captured,
      ...encodeFrame(1, FrameType.control, ControlCmd.battery, [55]),
    ]);
    final p = FrameParser();
    expect(p.add(two.sublist(0, 5)), isEmpty);
    final frames = p.add(two.sublist(5));
    expect(frames.map((f) => (f.seq, f.type, f.cmd)), [(0, 3, 1), (1, 0, 4)]);
    expect(frames[1].body, [55]);
  });

  test('skips noise and frames with a bad CRC', () {
    final bad = Uint8List.fromList(captured)..[3] ^= 0xFF;
    final p = FrameParser();
    final frames = p.add([0x00, 0x11, ...bad, ...captured]);
    expect(frames, hasLength(1));
    expect(p.crcErrors, 1);
  });

  test('an ACK has a TYPE and no CMD', () {
    final f = FrameParser().add(encodeRawFrame(9, [FrameType.recording])).single;
    expect(f.isAck, isTrue);
    expect(f.cmd, isNull);
  });

  test('a list entry restores the truncated extension and reads the name', () {
    final e = ByteData(28)
      ..setUint32(0, 2031, Endian.big)
      ..setUint32(4, 4062640, Endian.big);
    final entry = e.buffer.asUint8List()..setRange(8, 28, 'note20261030-120313.'.codeUnits);
    final f = CardFile.fromListEntry(entry);
    expect(f.name, 'note20261030-120313.opus');
    expect(f.baseName, 'note20261030-120313');
    expect(f.duration, const Duration(seconds: 2031));
    expect(f.size, 4062640);
    expect(f.mode, RecordingMode.note);
    expect(f.recordedAt, DateTime(2026, 10, 30, 12, 3, 13));
  });

  test('model code from the advertisement', () {
    expect(CardModel.fromCompanyId(0xE434), CardModel.bluetooth); // first card tested
    expect(CardModel.fromCompanyId(0xE436), CardModel.wifiHotspot); // Wi-Fi card tested
    expect(CardModel.wifiHotspot.hasWifi, isTrue);
  });

  test('audio helpers', () {
    expect(opusPackets(Uint8List(160)).length, 4);
    expect(opusDuration(4062640), const Duration(milliseconds: 2031320));
    final wav = wavFromPcm16(Uint8List(32000));
    expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
    expect(ByteData.sublistView(wav).getUint32(24, Endian.little), 16000);
    expect(wav.length, 32044);
  });
}
