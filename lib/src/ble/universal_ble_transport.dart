import 'dart:async';
import 'dart:typed_data';

import 'package:universal_ble/universal_ble.dart';

import '../card.dart';
import '../models.dart';
import '../transport.dart';

/// GATT UUIDs of the card.
abstract final class CardUuids {
  static const service = '0000ae20-0000-1000-8000-00805f9b34fb';
  static const write = '0000ae21-0000-1000-8000-00805f9b34fb';
  static const main = '0000ae22-0000-1000-8000-00805f9b34fb';
  static const events = '0000ae23-0000-1000-8000-00805f9b34fb';
}

/// A card found by [TalkaNote.scan].
class DiscoveredCard {
  DiscoveredCard(this.device);

  final BleDevice device;

  /// Platform device ID (a MAC address on Android and Windows, a UUID on iOS
  /// and macOS).
  String get id => device.deviceId;

  /// Advertised name. Several cards can share a name, so tell them apart by [id].
  String get name => device.name ?? '';

  int? get rssi => device.rssi;

  CardModel get model {
    final data = device.manufacturerDataList;
    return data.isEmpty ? CardModel.unknown : CardModel.fromCompanyId(data.first.companyId);
  }

  @override
  String toString() => 'DiscoveredCard($name, $id, ${model.name}, rssi $rssi)';
}

/// Entry point: find and connect cards.
abstract final class TalkaNote {
  /// Asks for the Bluetooth permissions the platform needs (Android 12+ and
  /// iOS). Throws if the user refuses.
  static Future<void> requestPermissions() => UniversalBle.requestPermissions();

  /// Scans for cards for [timeout] and emits each one once.
  static Stream<DiscoveredCard> scan({Duration timeout = const Duration(seconds: 8)}) async* {
    final seen = <String>{};
    final results = StreamController<DiscoveredCard>();
    final sub = UniversalBle.scanStream.listen((d) {
      if (!_isCard(d) || !seen.add(d.deviceId)) return;
      results.add(DiscoveredCard(d));
    });
    await UniversalBle.startScan(scanFilter: ScanFilter(withServices: [CardUuids.service]));
    final timer = Timer(timeout, () async {
      await UniversalBle.stopScan();
      await sub.cancel();
      await results.close();
    });
    try {
      yield* results.stream;
    } finally {
      timer.cancel();
      if (!results.isClosed) {
        await UniversalBle.stopScan();
        await sub.cancel();
        await results.close();
      }
    }
  }

  static bool _isCard(BleDevice d) =>
      d.services.any((s) => s.toLowerCase().contains('ae20')) || (d.name ?? '').toUpperCase().startsWith('CB08');

  /// Connects to [card], subscribes to its notifications, sets its clock and
  /// reports the app in the foreground.
  static Future<TalkaNoteCard> connect(
    DiscoveredCard card, {
    bool autoAnswerButtons = true,
    void Function(String)? log,
  }) {
    return connectById(card.id, autoAnswerButtons: autoAnswerButtons, log: log);
  }

  /// Like [connect], for a card ID saved earlier.
  static Future<TalkaNoteCard> connectById(
    String deviceId, {
    bool autoAnswerButtons = true,
    void Function(String)? log,
  }) async {
    final transport = await UniversalBleTransport.open(deviceId);
    final card = TalkaNoteCard(transport, autoAnswerButtons: autoAnswerButtons, log: log);
    await card.syncTime();
    await card.setAppForeground(true);
    return card;
  }
}

/// [CardTransport] over universal_ble.
class UniversalBleTransport implements CardTransport {
  UniversalBleTransport._(this.deviceId, this.maxWriteLength);

  final String deviceId;

  @override
  final int maxWriteLength;

  final _main = StreamController<Uint8List>.broadcast();
  final _events = StreamController<Uint8List>.broadcast();
  final _disconnected = Completer<void>();
  final _subs = <StreamSubscription<Object>>[];

  /// The download request is a 36-byte frame that must arrive in one write.
  static const minimumMtu = 39;

  static Future<UniversalBleTransport> open(String deviceId, {Duration timeout = const Duration(seconds: 20)}) async {
    await UniversalBle.connect(deviceId, timeout: timeout);
    try {
      await UniversalBle.discoverServices(deviceId);
      var mtu = 23;
      try {
        mtu = await UniversalBle.requestMtu(deviceId, 247);
      } catch (_) {
        // Some platforms negotiate the MTU themselves and refuse the request.
      }
      if (mtu < minimumMtu) {
        throw TalkaNoteException('MTU $mtu is too small; the card needs at least $minimumMtu');
      }
      final t = UniversalBleTransport._(deviceId, mtu - 3);
      await t._subscribe();
      return t;
    } catch (_) {
      await UniversalBle.disconnect(deviceId);
      rethrow;
    }
  }

  Future<void> _subscribe() async {
    _subs
      ..add(
        UniversalBle.characteristicValueStream(
          deviceId,
          CardUuids.main,
          serviceId: CardUuids.service,
        ).listen(_main.add),
      )
      ..add(
        UniversalBle.characteristicValueStream(
          deviceId,
          CardUuids.events,
          serviceId: CardUuids.service,
        ).listen(_events.add),
      )
      ..add(
        UniversalBle.connectionStream(deviceId).listen((connected) {
          if (!connected) _close();
        }),
      );
    // The main channel must be subscribed first.
    await UniversalBle.subscribeNotifications(deviceId, CardUuids.service, CardUuids.main);
    await UniversalBle.subscribeNotifications(deviceId, CardUuids.service, CardUuids.events);
  }

  @override
  Stream<Uint8List> get mainNotifications => _main.stream;

  @override
  Stream<Uint8List> get eventNotifications => _events.stream;

  @override
  Future<void> get disconnected => _disconnected.future;

  @override
  Future<void> write(Uint8List bytes) =>
      UniversalBle.write(deviceId, CardUuids.service, CardUuids.write, bytes, withoutResponse: true);

  @override
  Future<void> disconnect() async {
    try {
      await UniversalBle.disconnect(deviceId);
    } finally {
      _close();
    }
  }

  void _close() {
    if (_disconnected.isCompleted) return;
    _disconnected.complete();
    for (final s in _subs) {
      s.cancel();
    }
    _main.close();
    _events.close();
  }
}
