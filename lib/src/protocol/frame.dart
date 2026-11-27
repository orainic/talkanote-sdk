import 'dart:typed_data';

import 'crc16.dart';

/// First byte of every frame.
const frameMagic = 0x5A;

/// MAGIC + SEQ + CRC (2) + LEN (2).
const frameHeaderLength = 6;

/// A LEN above this is treated as a false header and skipped.
const maxFrameDataLength = 8192;

/// One protocol frame: `5A SEQ CRC(LE) LEN(LE) DATA`, where DATA is
/// `TYPE CMD PARAMS...`.
class Frame {
  Frame(this.seq, this.data);

  final int seq;
  final Uint8List data;

  int get type => data[0];

  /// Null for an ACK, which carries only the TYPE byte.
  int? get cmd => data.length >= 2 ? data[1] : null;

  bool get isAck => data.length == 1;

  /// Parameters after TYPE and CMD.
  Uint8List get body => data.length > 2 ? Uint8List.sublistView(data, 2) : Uint8List(0);

  @override
  String toString() => 'Frame(seq=$seq, type=$type, cmd=$cmd, body=${hex(body)})';
}

/// Builds a complete frame for `TYPE CMD PARAMS`.
Uint8List encodeFrame(int seq, int type, int cmd, [List<int> params = const []]) {
  final data = Uint8List(2 + params.length)
    ..[0] = type
    ..[1] = cmd
    ..setRange(2, 2 + params.length, params);
  return encodeRawFrame(seq, data);
}

/// Wraps DATA bytes in a frame header.
Uint8List encodeRawFrame(int seq, List<int> data) {
  final out = Uint8List(frameHeaderLength + data.length);
  final view = ByteData.sublistView(out);
  out[0] = frameMagic;
  out[1] = seq & 0xFF;
  view.setUint16(4, data.length, Endian.little);
  out.setRange(frameHeaderLength, out.length, data);
  view.setUint16(2, crc16Xmodem(Uint8List.sublistView(out, 4)), Endian.little);
  return out;
}

/// Reassembles frames from notification chunks.
///
/// A notification can hold part of a frame or several frames. Use one parser
/// per notify characteristic so their bytes never interleave.
class FrameParser {
  final _buf = BytesBuilder(copy: false);
  Uint8List _pending = Uint8List(0);

  /// Frames dropped because their CRC did not match.
  int crcErrors = 0;

  /// Adds [chunk] and returns every frame that is now complete.
  List<Frame> add(List<int> chunk) {
    _buf
      ..add(_pending)
      ..add(chunk);
    var buf = _buf.takeBytes();
    final frames = <Frame>[];
    var i = 0;
    while (true) {
      while (i < buf.length && buf[i] != frameMagic) {
        i++;
      }
      if (buf.length - i < frameHeaderLength) break;
      final view = ByteData.sublistView(buf, i);
      final crc = view.getUint16(2, Endian.little);
      final len = view.getUint16(4, Endian.little);
      if (len > maxFrameDataLength) {
        i++; // false header: resync on the next MAGIC
        continue;
      }
      if (buf.length - i < frameHeaderLength + len) break;
      final checked = Uint8List.sublistView(buf, i + 4, i + frameHeaderLength + len);
      if (crc16Xmodem(checked) != crc) {
        crcErrors++;
        i++;
        continue;
      }
      if (len > 0) {
        frames.add(
          Frame(
            buf[i + 1],
            Uint8List.fromList(Uint8List.sublistView(buf, i + frameHeaderLength, i + frameHeaderLength + len)),
          ),
        );
      }
      i += frameHeaderLength + len;
    }
    _pending = Uint8List.fromList(Uint8List.sublistView(buf, i));
    return frames;
  }

  void reset() {
    _buf.clear();
    _pending = Uint8List(0);
  }
}

/// Lower-case hex with spaces, for logs.
String hex(List<int> bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
