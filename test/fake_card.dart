import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:talkanote/talkanote.dart';

/// A simulated card behind a [CardTransport], for tests.
class FakeCard implements CardTransport {
  FakeCard({this.maxWriteLength = 244});

  @override
  final int maxWriteLength;

  final _main = StreamController<Uint8List>.broadcast(sync: true);
  final _events = StreamController<Uint8List>.broadcast(sync: true);
  final _disconnected = Completer<void>();
  final written = <Frame>[];
  final acks = <Frame>[];

  /// Old firmware lists fixed 20-byte names; newer firmware longer ones.
  bool longNames = false;
  final _parser = FrameParser();
  var _seq = 0;

  /// Wi-Fi: once a client connects, replies go over TCP instead of Bluetooth.
  ServerSocket? wifiServer;
  Socket? wifiClient;
  final wifiReceived = BytesBuilder();
  String? wifiSsid;
  String? hotspotPassword;
  String? uploadUrl;

  /// Starts a loopback TCP server that stands in for the card's hotspot.
  Future<int> startWifi() async {
    final server = wifiServer = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((socket) {
      wifiClient = socket;
      socket.listen(wifiReceived.add, onDone: () => wifiClient = null);
    });
    return server.port;
  }

  Future<void> stopWifi() async {
    wifiClient?.destroy();
    wifiClient = null;
    await wifiServer?.close();
  }

  /// Files on the card: name -> Opus bytes.
  final files = <String, Uint8List>{};

  /// Stop sending after this many bytes of the first download, to test resume.
  int? stallAfter;

  /// Notification size of the main channel.
  int chunk = 20;

  int battery = 87;

  @override
  Stream<Uint8List> get mainNotifications => _main.stream;

  @override
  Stream<Uint8List> get eventNotifications => _events.stream;

  @override
  Future<void> get disconnected => _disconnected.future;

  @override
  Future<void> disconnect() async {
    if (!_disconnected.isCompleted) _disconnected.complete();
  }

  @override
  Future<void> write(Uint8List bytes) async {
    if (bytes.length > maxWriteLength) throw StateError('write of ${bytes.length} B > $maxWriteLength');
    for (final f in _parser.add(bytes)) {
      if (f.isAck) {
        acks.add(f);
        continue;
      }
      written.add(f);
      scheduleMicrotask(() => _handle(f));
    }
  }

  /// Sends a frame from the card on the main channel, split into notifications.
  void notify(int type, int cmd, [List<int> params = const []]) {
    final frame = encodeFrame(_seq++, type, cmd, params);
    final tcp = wifiClient;
    if (tcp != null) {
      tcp.add(frame);
      return;
    }
    for (var i = 0; i < frame.length; i += chunk) {
      _main.add(Uint8List.sublistView(frame, i, i + chunk > frame.length ? frame.length : i + chunk));
    }
  }

  /// Sends a frame from the card on the event channel (button presses).
  void event(int type, int cmd, [List<int> params = const []]) => _events.add(encodeFrame(_seq++, type, cmd, params));

  void _handle(Frame f) {
    final body = f.body;
    switch ((f.type, f.cmd)) {
      case (FrameType.control, ControlCmd.getBattery):
        notify(FrameType.control, ControlCmd.battery, [battery]);
      case (FrameType.control, ControlCmd.getStorage):
        final b = ByteData(8)
          ..setUint32(0, 30632352, Endian.little)
          ..setUint32(4, 30712448, Endian.little);
        notify(FrameType.control, ControlCmd.storage, b.buffer.asUint8List());
      case (FrameType.control, ControlCmd.getVersion):
        notify(FrameType.control, ControlCmd.version, ascii.encode('V1.0.0'));
      case (FrameType.file, FileCmd.list):
        _sendList();
      case (FrameType.file, FileCmd.download):
        final offset = ByteData.sublistView(body).getUint32(0, Endian.little);
        final raw = body.sublist(4);
        final name = ascii.decode(raw.contains(0) ? raw.sublist(0, raw.indexOf(0)) : raw);
        _sendFile(name, offset);
      case (FrameType.file, FileCmd.deleteOne):
        final name = utf8.decode(body.sublist(4));
        notify(FrameType.file, FileCmd.deleteOneResult, [files.remove(name) != null ? 0 : 1]);
      case (FrameType.control, ControlCmd.openHotspot):
        notify(FrameType.control, ControlCmd.hotspotOpened, [0, ...utf8.encode('talkaNote-0D29')]);
      case (FrameType.control, ControlCmd.closeHotspot):
        notify(FrameType.control, ControlCmd.hotspotClosed, [0]);
      case (FrameType.control, ControlCmd.getHotspotClient):
        notify(FrameType.control, ControlCmd.hotspotClient, [wifiClient != null ? 1 : 0]);
      case (FrameType.control, ControlCmd.setHotspotPassword):
        hotspotPassword = utf8.decode(body.sublist(2, 2 + (body[0] << 8 | body[1])));
        notify(FrameType.control, ControlCmd.hotspotPasswordResult, [0]);
      case (FrameType.wifiDirect, WifiDirectCmd.setNetwork):
        final n = body[0] << 8 | body[1];
        wifiSsid = utf8.decode(body.sublist(2, 2 + n));
        notify(FrameType.wifiDirect, WifiDirectCmd.setNetworkResult, [0]);
      case (FrameType.wifiDirect, WifiDirectCmd.setUploadUrl):
        uploadUrl = utf8.decode(body.sublist(2));
        notify(FrameType.wifiDirect, WifiDirectCmd.setUploadUrlResult, [0]);
      case (FrameType.wifiDirect, WifiDirectCmd.reset):
        wifiSsid = null;
        notify(FrameType.wifiDirect, WifiDirectCmd.resetResult, [0]);
      case (FrameType.wifiDirect, WifiDirectCmd.get):
        final b = utf8.encode(wifiSsid ?? '');
        notify(FrameType.wifiDirect, WifiDirectCmd.config, [b.length >> 8, b.length & 0xFF, ...b, 1]);
      case (FrameType.recording, RecordCmd.getState):
        notify(FrameType.recording, RecordCmd.state, [2]);
      case (FrameType.recording, RecordCmd.setGain):
        notify(FrameType.recording, RecordCmd.setGainResult, [0]);
    }
  }

  void _sendList() {
    final names = files.keys.toList();
    // Two files per batch, like the real card's larger lists.
    for (var i = 0; i < names.length; i += 2) {
      final batch = names.skip(i).take(2).toList();
      final b = BytesBuilder()..add((ByteData(4)..setUint32(0, batch.length, Endian.big)).buffer.asUint8List());
      for (final n in batch) {
        final e = ByteData(28)
          ..setUint32(0, files[n]!.length ~/ 2000, Endian.big)
          ..setUint32(4, files[n]!.length, Endian.big);
        final entry = e.buffer.asUint8List();
        // The card sends the name without "opus", ending at the dot.
        final listed = n.substring(0, n.length - 4);
        b
          ..add(entry.sublist(0, 8))
          ..add(ascii.encode(longNames ? ' $listed' : listed));
      }
      notify(FrameType.file, FileCmd.listBatch, b.toBytes());
    }
    notify(FrameType.file, FileCmd.listDone, [0]);
  }

  void _sendFile(String name, int offset) {
    final data = files[name];
    if (data == null) {
      notify(FrameType.file, FileCmd.downloadEnd, [DownloadEndCode.notFound]);
      return;
    }
    notify(FrameType.file, FileCmd.downloadStart, ascii.encode(name));
    final stop = stallAfter;
    stallAfter = null;
    for (var i = offset; i < data.length; i += 160) {
      if (stop != null && i >= stop) return; // goes silent: the SDK must resume
      notify(FrameType.file, FileCmd.downloadData, data.sublist(i, i + 160 > data.length ? data.length : i + 160));
    }
    notify(FrameType.file, FileCmd.downloadEnd, [DownloadEndCode.ok]);
  }
}
