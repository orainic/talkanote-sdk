import 'dart:typed_data';

/// Hardware family, read from the card's advertisement.
enum CardModel {
  /// Bluetooth only.
  bluetooth(1),

  /// Bluetooth plus a Wi-Fi hotspot for fast transfer.
  wifiHotspot(3),

  /// Bluetooth plus Wi-Fi direct upload.
  wifiDirect(5),

  unknown(-1);

  const CardModel(this.code);

  /// Product type code from the advertisement.
  final int code;

  bool get hasWifi => this == wifiHotspot || this == wifiDirect;

  static CardModel fromCode(int code) => values.firstWhere((m) => m.code == code, orElse: () => unknown);

  /// Decodes the product type from the manufacturer-specific advertisement
  /// data: the low byte of the company ID XOR 0x35.
  static CardModel fromCompanyId(int companyId) => fromCode((companyId & 0xFF) ^ 0x35);
}

/// Recording mode, from the switch on the card.
enum RecordingMode {
  /// Room microphones, for meetings and notes.
  note,

  /// Bone-conduction microphone, for phone calls (card on the back of the phone).
  call,

  unknown,
}

/// A recording stored on the card.
class CardFile {
  CardFile({required this.name, required this.duration, required this.size, required Uint8List listEntry})
    : listEntry = Uint8List.fromList(listEntry);

  /// Parses the entries of one file-list batch: count (4 B, big-endian), then
  /// per file duration (4 B BE), size (4 B BE) and a name that ends with `.`.
  ///
  /// Names are cut before the extension: older firmware sends a fixed 20-byte
  /// `note20261030-111449.`, newer firmware a longer `" note 2026-11-27_10-00-00."`.
  /// Both end at the first `.`, with no padding after it.
  static List<CardFile> parseListBatch(Uint8List body) {
    final files = <CardFile>[];
    if (body.length < 4) return files;
    final view = ByteData.sublistView(body);
    final count = view.getUint32(0, Endian.big);
    var o = 4;
    for (var i = 0; i < count && o + 9 <= body.length; i++) {
      final dot = body.indexOf(0x2E, o + 8);
      if (dot < 0) break;
      final raw = String.fromCharCodes(body.sublist(o + 8, dot)).replaceAll(String.fromCharCode(0), '').trim();
      files.add(
        CardFile(
          name: raw.endsWith('.opus') ? raw : '$raw.opus',
          duration: Duration(seconds: view.getUint32(o, Endian.big)),
          size: view.getUint32(o + 4, Endian.big),
          listEntry: body.sublist(o, dot + 1),
        ),
      );
      o = dot + 1;
    }
    return files;
  }

  /// Full file name, e.g. `note20261030-111449.opus`. Use it unchanged for
  /// download and delete.
  final String name;

  final Duration duration;

  /// Size of the Opus file on the card, in bytes.
  final int size;

  /// The raw list entry, kept for firmware that deletes by entry.
  final Uint8List listEntry;

  /// Name without extension, e.g. `note20261030-111449`.
  String get baseName {
    final dot = name.lastIndexOf('.');
    return dot < 0 ? name : name.substring(0, dot);
  }

  RecordingMode get mode => name.startsWith('note')
      ? RecordingMode.note
      : name.startsWith('call')
      ? RecordingMode.call
      : RecordingMode.unknown;

  /// Local start time encoded in the name, or null if the name has none.
  DateTime? get recordedAt {
    final m = RegExp(r'^(?:note|call)\s*(\d{4})-?(\d{2})-?(\d{2})[-_](\d{2})-?(\d{2})-?(\d{2})').firstMatch(name);
    if (m == null) return null;
    final p = [for (var i = 1; i <= 6; i++) int.parse(m.group(i)!)];
    return DateTime(p[0], p[1], p[2], p[3], p[4], p[5]);
  }

  /// Size of the same recording as a 16 kHz 16-bit mono WAV.
  int get wavSize => duration.inSeconds * 32000 + 44;

  @override
  String toString() => 'CardFile($name, ${duration.inSeconds}s, $size B)';
}

/// Battery reading.
class Battery {
  const Battery({required this.percent, required this.charging});

  /// 0–100, or null while charging (the card then reports no level).
  final int? percent;
  final bool charging;

  static Battery fromCode(int code) =>
      code == 110 ? const Battery(percent: null, charging: true) : Battery(percent: code, charging: false);

  @override
  String toString() => charging ? 'Battery(charging)' : 'Battery($percent%)';
}

/// Storage on the card, in KiB.
class Storage {
  const Storage({required this.freeKb, required this.totalKb});

  final int freeKb;
  final int totalKb;

  @override
  String toString() => 'Storage(free $freeKb KiB of $totalKb KiB)';
}

enum RecordingState {
  recording(1),
  idle(2),
  paused(3),
  unknown(-1);

  const RecordingState(this.code);
  final int code;

  static RecordingState fromCode(int code) => values.firstWhere((s) => s.code == code, orElse: () => unknown);
}

/// Microphone gain.
enum Gain {
  low(1),
  medium(2),
  high(3);

  const Gain(this.code);
  final int code;

  static Gain? fromCode(int code) => values.where((g) => g.code == code).firstOrNull;
}

/// Progress of the recording in progress.
class RecordingTime {
  const RecordingTime({required this.duration, required this.bytes});

  final Duration duration;
  final int bytes;
}

/// A press of the card's button. The card waits for the app's answer before
/// it acts, and drops the link if no answer comes.
enum ButtonAction {
  start(1),
  save(3),
  pause(5),
  resume(7);

  const ButtonAction(this.cmd);
  final int cmd;

  static ButtonAction? fromCmd(int cmd) => values.where((a) => a.cmd == cmd).firstOrNull;
}

class ButtonEvent {
  const ButtonEvent(this.action, {required this.answered});

  final ButtonAction action;

  /// True when the SDK answered the card automatically.
  final bool answered;

  @override
  String toString() => 'ButtonEvent(${action.name}, answered: $answered)';
}

/// Events of the live audio stream.
sealed class LiveEvent {
  const LiveEvent();
}

/// The card announced the file it is recording to.
class LiveStarted extends LiveEvent {
  const LiveStarted(this.fileName);
  final String fileName;
}

/// One notification of raw Opus audio. Split it with `opusFrames` before
/// decoding.
class LiveAudio extends LiveEvent {
  const LiveAudio(this.opus);
  final Uint8List opus;
}

class LivePaused extends LiveEvent {
  const LivePaused();
}

class LiveResumed extends LiveEvent {
  const LiveResumed();
}

class LiveStopped extends LiveEvent {
  const LiveStopped();
}

/// Download format.
enum AudioFormat {
  /// The card's own file: raw Opus, 16 kHz mono, 40-byte packets of 20 ms.
  opus,

  /// The card converts to WAV (16 kHz, 16-bit, mono) while sending. About 16
  /// times larger, so 16 times slower over Bluetooth.
  wav,
}

class TalkaNoteException implements Exception {
  const TalkaNoteException(this.message);
  final String message;

  @override
  String toString() => 'TalkaNoteException: $message';
}

/// The card answered a download with "file not found".
class FileNotFoundOnCard extends TalkaNoteException {
  const FileNotFoundOnCard(super.message);
}
