import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// TCP link to the card over its Wi-Fi hotspot.
///
/// Commands still go over Bluetooth. Once this link is attached with
/// `TalkaNoteCard.attachWifi` (or `connectWifi`), the card sends its replies
/// and file data over Wi-Fi as well, which makes downloads much faster.
///
/// Join the card's hotspot (see `TalkaNoteCard.openHotspot`) before you
/// connect. Joining a Wi-Fi network is done by the phone's operating system,
/// not by this SDK: see `docs/wifi.md`.
class CardWifiLink {
  CardWifiLink._(this._socket) {
    _socket.setOption(SocketOption.tcpNoDelay, true);
    _sub = _socket.listen(_onData, onError: (Object _) => close(), onDone: close, cancelOnError: true);
    _heartbeat = Timer.periodic(heartbeatInterval, (_) => _write(_heartbeatBytes));
  }

  /// Address of the card on its own hotspot.
  static const defaultHost = '192.168.1.1';
  static const defaultPort = 27689;
  static const heartbeatInterval = Duration(seconds: 30);
  static const _heartbeatBytes = [0x01, 0x0A];
  static final _ackBytes = Uint8List.fromList('ACK\r\n'.codeUnits);

  /// Connects to the card. Retries for up to [timeout], because the phone can
  /// take a few seconds to route traffic to a network it has just joined.
  static Future<CardWifiLink> connect({
    String host = defaultHost,
    int port = defaultPort,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final deadline = DateTime.now().add(timeout);
    Object? lastError;
    while (DateTime.now().isBefore(deadline)) {
      final left = deadline.difference(DateTime.now());
      try {
        final socket = await Socket.connect(
          host,
          port,
          timeout: left < const Duration(seconds: 5) ? left : const Duration(seconds: 5),
        );
        return CardWifiLink._(socket);
      } on SocketException catch (e) {
        lastError = e;
        await Future<void>.delayed(const Duration(milliseconds: 700));
      }
    }
    throw SocketException('Could not reach the card at $host:$port ($lastError)');
  }

  final Socket _socket;
  late final StreamSubscription<Uint8List> _sub;
  late final Timer _heartbeat;
  final _data = StreamController<Uint8List>.broadcast();
  final _done = Completer<void>();
  var _closed = false;

  /// Answer every packet with `ACK`. The card asks for this itself when it
  /// connects; `TalkaNoteCard` sets it for you.
  bool ackEachPacket = false;

  /// Bytes received so far.
  int received = 0;

  /// Raw bytes from the card, in frames of the same format as over Bluetooth.
  Stream<Uint8List> get data => _data.stream;

  /// Completes when the link closes.
  Future<void> get done => _done.future;

  bool get isClosed => _closed;

  void _onData(Uint8List chunk) {
    received += chunk.length;
    if (ackEachPacket) _write(_ackBytes);
    _data.add(chunk);
  }

  void _write(List<int> bytes) {
    if (_closed) return;
    try {
      _socket.add(bytes);
    } catch (_) {
      close();
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _heartbeat.cancel();
    await _sub.cancel();
    _socket.destroy();
    await _data.close();
    _done.complete();
  }
}
