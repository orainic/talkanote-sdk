import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'models.dart';
import 'protocol/commands.dart';
import 'protocol/frame.dart';
import 'transport.dart';

/// Called with bytes received so far and the expected total.
typedef DownloadProgress = void Function(int received, int expected);

/// One connected talkaNote card.
///
/// Create it from a connected [CardTransport], usually through
/// `TalkaNote.connect`. All methods are safe to call from the UI isolate; the
/// card handles one request of each kind at a time, so await each call.
class TalkaNoteCard {
  TalkaNoteCard(this.transport, {this.autoAnswerButtons = true, this.log}) {
    _subs
      ..add(transport.mainNotifications.listen((c) => _onChunk(_mainParser, c, fromEvents: false)))
      ..add(transport.eventNotifications.listen((c) => _onChunk(_eventParser, c, fromEvents: true)));
    transport.disconnected.then((_) => _onDisconnected());
  }

  final CardTransport transport;

  /// Answer button presses automatically so the card acts at once. Turn it off
  /// to decide in [buttonEvents] and answer with [answerButton].
  bool autoAnswerButtons;

  /// Optional debug log sink.
  void Function(String message)? log;

  static const commandTimeout = Duration(seconds: 5);
  static const listIdleTimeout = Duration(milliseconds: 1200);
  static const downloadIdleTimeout = Duration(seconds: 12);
  static const deleteTimeout = Duration(seconds: 3);
  static const _echoWindow = Duration(seconds: 3);
  static const _maxResumes = 3;

  final _subs = <StreamSubscription<Uint8List>>[];
  final _mainParser = FrameParser();
  final _eventParser = FrameParser();
  final _waiters = <int, Completer<Frame>>{};
  final _buttons = StreamController<ButtonEvent>.broadcast();
  final _live = StreamController<LiveEvent>.broadcast();
  final _appButtonAt = <int, DateTime>{};
  var _seq = -1;
  var _closed = false;

  _ListSession? _list;
  _DownloadSession? _download;

  /// Button presses on the card.
  Stream<ButtonEvent> get buttonEvents => _buttons.stream;

  /// Live audio while the card streams (after [startLive], or after a
  /// recording started with the card's button).
  Stream<LiveEvent> get liveEvents => _live.stream;

  /// Completes when the link drops.
  Future<void> get disconnected => transport.disconnected;

  // ---------------------------------------------------------------- setup

  /// Sets the card clock to [now] (default: local time). Call it right after
  /// connecting; the card names recordings by this clock.
  Future<void> syncTime([DateTime? now]) {
    final t = now ?? DateTime.now();
    final p = ByteData(7)
      ..setUint16(0, t.year, Endian.little)
      ..setUint8(2, t.month)
      ..setUint8(3, t.day)
      ..setUint8(4, t.hour)
      ..setUint8(5, t.minute)
      ..setUint8(6, t.second);
    return _send(FrameType.control, ControlCmd.syncTime, p.buffer.asUint8List());
  }

  /// Tells the card whether the app is in the foreground. Send `true` when the
  /// app starts or resumes and `false` when it goes to the background.
  Future<void> setAppForeground(bool foreground) => _send(FrameType.control, ControlCmd.appState, [foreground ? 1 : 2]);

  // ------------------------------------------------------------- card info

  Future<Battery> battery() async {
    final f = await _request(FrameType.control, ControlCmd.getBattery, ControlCmd.battery);
    return Battery.fromCode(f.body[0]);
  }

  Future<Storage> storage() async {
    final f = await _request(FrameType.control, ControlCmd.getStorage, ControlCmd.storage);
    final v = ByteData.sublistView(f.body);
    return Storage(freeKb: v.getUint32(0, Endian.little), totalKb: v.getUint32(4, Endian.little));
  }

  Future<String> firmwareVersion() async {
    final f = await _request(FrameType.control, ControlCmd.getVersion, ControlCmd.version);
    return _cString(f.body);
  }

  // ------------------------------------------------------------- recording

  Future<RecordingState> recordingState() async =>
      RecordingState.fromCode((await _record(RecordCmd.getState, RecordCmd.state)).body[0]);

  /// Starts recording. Returns false if the card refused.
  Future<bool> startRecording() async => (await _record(RecordCmd.start, RecordCmd.startResult)).body[0] == 1;

  /// Stops and saves the recording.
  Future<bool> saveRecording() async => (await _record(RecordCmd.save, RecordCmd.saveResult)).body[0] == 1;

  Future<bool> pauseRecording() async => (await _record(RecordCmd.pause, RecordCmd.pauseResult)).body[0] == 1;

  Future<bool> resumeRecording() async => (await _record(RecordCmd.resume, RecordCmd.resumeResult)).body[0] == 1;

  Future<RecordingTime> recordingTime() async {
    final v = ByteData.sublistView((await _record(RecordCmd.getTime, RecordCmd.time)).body);
    return RecordingTime(
      duration: Duration(seconds: v.getUint16(0, Endian.little)),
      bytes: v.getUint32(2, Endian.little),
    );
  }

  /// Name of the file being recorded.
  Future<String> currentFileName() async => _cString((await _record(RecordCmd.getFileName, RecordCmd.fileName)).body);

  Future<Gain?> gain() async => Gain.fromCode((await _record(RecordCmd.getGain, RecordCmd.gain)).body[0]);

  Future<bool> setGain(Gain gain) async =>
      (await _record(RecordCmd.setGain, RecordCmd.setGainResult, [gain.code])).body[0] == 0;

  /// Answers a button press yourself when [autoAnswerButtons] is off.
  Future<void> answerButton(ButtonAction action, {bool accept = true}) =>
      _send(FrameType.recording, action.cmd + 1, [accept ? 1 : 2]);

  Future<Frame> _record(int cmd, int reply, [List<int> params = const []]) {
    if (RecordCmd.buttonRequests.contains(cmd)) _appButtonAt[cmd] = DateTime.now();
    return _request(FrameType.recording, cmd, reply, params);
  }

  // ------------------------------------------------------------ live audio

  /// Asks the card to stream audio while it records. Listen to [liveEvents].
  Future<void> startLive() => _send(FrameType.live, LiveCmd.start);

  Future<void> stopLive() => _send(FrameType.live, LiveCmd.stop);

  Future<void> pauseLive(bool pause) => _send(FrameType.live, LiveCmd.pauseResume, [pause ? 1 : 0]);

  // ----------------------------------------------------------------- files

  /// Lists the recordings on the card, oldest first.
  Future<List<CardFile>> listFiles({Duration timeout = const Duration(seconds: 15)}) async {
    if (_list != null) throw const TalkaNoteException('A file list request is already running');
    final session = _list = _ListSession();
    try {
      await _send(FrameType.file, FileCmd.list);
      // With no files the card may send nothing at all, so arm the idle timer now.
      _armListIdle();
      return await session.done.future.timeout(timeout);
    } finally {
      session.idle?.cancel();
      _list = null;
    }
  }

  /// Downloads [file] and returns its bytes.
  ///
  /// Stalls are resumed from the last byte received, up to three times.
  /// [onData] receives each chunk as it arrives, for playback while
  /// downloading. Check [recordingState] first: don't download while the card
  /// records.
  Future<Uint8List> download(
    CardFile file, {
    AudioFormat format = AudioFormat.opus,
    int offset = 0,
    DownloadProgress? onProgress,
    void Function(Uint8List chunk)? onData,
  }) async {
    final name = '${file.baseName}.${format.name}';
    final expected = format == AudioFormat.wav ? file.wavSize : file.size;
    var received = Uint8List(0);
    for (var attempt = 0; ; attempt++) {
      try {
        return await _downloadOnce(name, offset + received.length, received, expected, onProgress, onData);
      } on FileNotFoundOnCard {
        rethrow;
      } on TalkaNoteException catch (e) {
        final got = _lastPartial;
        if (_closed || attempt >= _maxResumes || got.length <= received.length) rethrow;
        received = got;
        log?.call('download stalled at ${got.length} B (${e.message}); resuming, attempt ${attempt + 1}');
        await abortDownload();
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    }
  }

  Uint8List _lastPartial = Uint8List(0);

  Future<Uint8List> _downloadOnce(
    String name,
    int offset,
    Uint8List prefix,
    int expected,
    DownloadProgress? onProgress,
    void Function(Uint8List)? onData,
  ) async {
    if (_download != null) throw const TalkaNoteException('A download is already running');
    final s = _download = _DownloadSession(prefix, expected, onProgress, onData);
    try {
      final params = ByteData(4)..setUint32(0, offset, Endian.little);
      final frame = _frame(FrameType.file, FileCmd.download, [...params.buffer.asUint8List(), ..._nameField(name)]);
      // The card misreads this request if it arrives in two writes.
      if (frame.length > transport.maxWriteLength) {
        throw TalkaNoteException(
          'Download request is ${frame.length} B but one write carries ${transport.maxWriteLength} B; request a larger MTU',
        );
      }
      await transport.write(frame);
      _armDownloadIdle();
      return await s.done.future;
    } finally {
      s.idle?.cancel();
      _lastPartial = s.buffer.toBytes();
      _download = null;
    }
  }

  /// Stops a running download on the card.
  Future<void> abortDownload() => _send(FrameType.file, FileCmd.abort);

  /// Deletes [file]. Returns true on success, false if the card refused, and
  /// null if the firmware sent no answer.
  Future<bool?> delete(CardFile file) async {
    int? code;
    for (final params in [
      [0, 0, 0, 0, ...utf8.encode(file.name)],
      file.listEntry,
    ]) {
      try {
        final f = await _requestWithin(
          FrameType.file,
          FileCmd.deleteOne,
          FileCmd.deleteOneResult,
          params,
          deleteTimeout,
        );
        code = f.body.isEmpty ? null : f.body[0];
      } on TimeoutException {
        return null;
      }
      if (code == 0) return true;
    }
    return false;
  }

  /// Deletes every recording. Returns null if the firmware sent no answer.
  Future<bool?> deleteAll() async {
    try {
      final f = await _requestWithin(
        FrameType.file,
        FileCmd.deleteAll,
        FileCmd.deleteAllResult,
        const [],
        deleteTimeout,
      );
      return f.body.isEmpty ? null : f.body[0] == 0;
    } on TimeoutException {
      return null;
    }
  }

  // ------------------------------------------------------------ connection

  Future<void> disconnect() async {
    await transport.disconnect();
    _onDisconnected();
  }

  void _onDisconnected() {
    if (_closed) return;
    _closed = true;
    const e = TalkaNoteException('Card disconnected');
    for (final w in _waiters.values) {
      if (!w.isCompleted) w.completeError(e);
    }
    _waiters.clear();
    _list?.idle?.cancel();
    if (_list?.done.isCompleted == false) _list!.done.completeError(e);
    _download?.idle?.cancel();
    if (_download?.done.isCompleted == false) _download!.done.completeError(e);
    for (final s in _subs) {
      s.cancel();
    }
    _buttons.close();
    _live.close();
  }

  // ------------------------------------------------------------ frame I/O

  Uint8List _frame(int type, int cmd, [List<int> params = const []]) {
    _seq = (_seq + 1) & 0xFF;
    return encodeFrame(_seq, type, cmd, params);
  }

  Future<void> _send(int type, int cmd, [List<int> params = const []]) async {
    if (_closed) throw const TalkaNoteException('Card disconnected');
    final frame = _frame(type, cmd, params);
    final max = transport.maxWriteLength;
    for (var i = 0; i < frame.length; i += max) {
      await transport.write(Uint8List.sublistView(frame, i, i + max > frame.length ? frame.length : i + max));
    }
  }

  Future<Frame> _request(int type, int cmd, int reply, [List<int> params = const []]) =>
      _requestWithin(type, cmd, reply, params, commandTimeout);

  Future<Frame> _requestWithin(int type, int cmd, int reply, List<int> params, Duration timeout) async {
    final key = type << 8 | reply;
    final waiter = _waiters[key] = Completer<Frame>();
    try {
      await _send(type, cmd, params);
      return await waiter.future.timeout(timeout);
    } finally {
      if (identical(_waiters[key], waiter)) _waiters.remove(key);
    }
  }

  void _onChunk(FrameParser parser, Uint8List chunk, {required bool fromEvents}) {
    for (final f in parser.add(chunk)) {
      if (!f.isAck) _onFrame(f, fromEvents: fromEvents);
    }
  }

  void _onFrame(Frame f, {required bool fromEvents}) {
    final cmd = f.cmd!;
    if (f.type == FrameType.file) {
      final dl = _download;
      if (dl != null && (cmd == FileCmd.downloadStart || cmd == FileCmd.downloadData || cmd == FileCmd.downloadEnd)) {
        _onDownloadFrame(dl, f);
        return;
      }
      if (cmd == FileCmd.listBatch) {
        _onListBatch(f.body);
        return;
      }
      if (cmd == FileCmd.listDone) {
        _finishList();
        return;
      }
      if (cmd == FileCmd.downloadData) return; // stray data after an abort
    }
    if (f.type == FrameType.live) {
      _onLiveFrame(f);
      return;
    }
    final waiter = _waiters.remove(f.type << 8 | cmd);
    if (waiter != null && !waiter.isCompleted) {
      waiter.complete(f);
      return;
    }
    if (f.type == FrameType.recording && fromEvents && RecordCmd.buttonRequests.contains(cmd)) {
      _onButton(cmd);
      return;
    }
    log?.call('unhandled $f');
  }

  void _onButton(int cmd) {
    final action = ButtonAction.fromCmd(cmd)!;
    final sentAt = _appButtonAt[cmd];
    // The card echoes a command the app has just sent; that is not a press.
    final echo = sentAt != null && DateTime.now().difference(sentAt) < _echoWindow;
    final answer = autoAnswerButtons && !echo;
    if (answer) {
      answerButton(action).catchError((Object e) => log?.call('button answer failed: $e'));
    }
    if (!echo) _buttons.add(ButtonEvent(action, answered: answer));
  }

  void _onLiveFrame(Frame f) {
    switch (f.cmd) {
      case LiveCmd.start:
        _live.add(LiveStarted(_cString(f.body)));
      case LiveCmd.audio:
        _live.add(LiveAudio(f.body));
      case LiveCmd.state:
        final s = f.body.isEmpty ? -1 : f.body[0];
        _live.add(switch (s) {
          0 => const LiveResumed(),
          1 => const LivePaused(),
          _ => const LiveStopped(),
        });
    }
  }

  // ----------------------------------------------------------- list state

  void _onListBatch(Uint8List body) {
    final list = _list;
    if (list == null || body.length < 4) return;
    final count = ByteData.sublistView(body).getUint32(0, Endian.big);
    for (var i = 0, o = 4; i < count && o + 28 <= body.length; i++, o += 28) {
      list.files.add(CardFile.fromListEntry(Uint8List.sublistView(body, o, o + 28)));
    }
    _armListIdle();
  }

  void _armListIdle() {
    _list?.idle?.cancel();
    _list?.idle = Timer(listIdleTimeout, _finishList);
  }

  void _finishList() {
    final list = _list;
    if (list == null || list.done.isCompleted) return;
    list.idle?.cancel();
    list.done.complete(List.unmodifiable(list.files));
  }

  // ------------------------------------------------------- download state

  void _onDownloadFrame(_DownloadSession s, Frame f) {
    switch (f.cmd) {
      case FileCmd.downloadStart:
        _armDownloadIdle();
      case FileCmd.downloadData:
        s.buffer.add(f.body);
        s.onData?.call(f.body);
        s.onProgress?.call(s.buffer.length, s.expected);
        _armDownloadIdle();
      case FileCmd.downloadEnd:
        s.idle?.cancel();
        final code = f.body.isEmpty ? DownloadEndCode.stopped : f.body[0];
        if (s.done.isCompleted) return;
        switch (code) {
          case DownloadEndCode.ok:
            s.done.complete(s.buffer.toBytes());
          case DownloadEndCode.notFound:
            s.done.completeError(const FileNotFoundOnCard('File not found on the card'));
          case DownloadEndCode.offsetTooLarge:
            s.done.completeError(const TalkaNoteException('Offset is larger than the file'));
          default:
            s.done.completeError(TalkaNoteException('Card stopped the transfer (code $code)'));
        }
    }
  }

  void _armDownloadIdle() {
    final s = _download;
    if (s == null) return;
    s.idle?.cancel();
    s.idle = Timer(downloadIdleTimeout, () {
      if (s.done.isCompleted) return;
      s.done.completeError(
        s.buffer.length > s.prefixLength
            ? TalkaNoteException('Transfer stalled after ${s.buffer.length} B')
            : const TalkaNoteException('No data from the card'),
      );
    });
  }

  static List<int> _nameField(String name) {
    final b = utf8.encode(name);
    return [...b.take(24), ...List.filled(24 - (b.length < 24 ? b.length : 24), 0)];
  }

  static String _cString(Uint8List b) {
    final end = b.indexOf(0);
    return utf8.decode(end < 0 ? b : b.sublist(0, end), allowMalformed: true);
  }
}

class _ListSession {
  final files = <CardFile>[];
  final done = Completer<List<CardFile>>();
  Timer? idle;
}

class _DownloadSession {
  _DownloadSession(Uint8List prefix, this.expected, this.onProgress, this.onData) : prefixLength = prefix.length {
    buffer.add(prefix);
  }

  final buffer = BytesBuilder();
  final int prefixLength;
  final int expected;
  final DownloadProgress? onProgress;
  final void Function(Uint8List)? onData;
  final done = Completer<Uint8List>();
  Timer? idle;
}
