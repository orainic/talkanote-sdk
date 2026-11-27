import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:talkanote/talkanote.dart';

import 'fake_card.dart';

void main() {
  late FakeCard fake;
  late TalkaNoteCard card;

  setUp(() {
    fake = FakeCard();
    card = TalkaNoteCard(fake);
  });

  tearDown(() async {
    await card.disconnectWifi();
    await fake.stopWifi();
  });

  Future<void> until(bool Function() ok) async {
    for (var i = 0; i < 100 && !ok(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(ok(), isTrue);
  }

  test('opens the hotspot and returns its name', () async {
    final h = await card.openHotspot();
    expect(h.name, 'talkaNote-0D29');
    expect(fake.written.last.type, FrameType.control);
    expect(fake.written.last.cmd, ControlCmd.openHotspot);
  });

  test('a refused hotspot throws with the code', () async {
    final c = TalkaNoteCard(_RefusingCard());
    await expectLater(c.openHotspot(), throwsA(isA<TalkaNoteException>()));
  });

  test('sets the hotspot password length-prefixed', () async {
    await card.setHotspotPassword('talka2026');
    expect(fake.hotspotPassword, 'talka2026');
    expect(fake.written.last.body.sublist(0, 2), [0, 9]);
    expect(() => card.setHotspotPassword('short'), throwsArgumentError);
    expect(() => card.setHotspotPassword('x' * 17), throwsArgumentError);
  });

  test('downloads over Wi-Fi once the link is attached', () async {
    final port = await fake.startWifi();
    fake.files['note20261127-131032.opus'] = Uint8List.fromList(List.generate(5000, (i) => i & 0xFF));
    final link = await card.connectWifi(host: '127.0.0.1', port: port);
    await until(() => fake.wifiClient != null);
    expect(await card.hotspotHasClient(), isTrue);

    final files = await card.listFiles();
    final bytes = await card.download(files.single);
    expect(bytes, fake.files['note20261127-131032.opus']);
    expect(link.received, greaterThan(5000));
  });

  test('answers each Wi-Fi packet with ACK when the card asks', () async {
    final port = await fake.startWifi();
    await card.connectWifi(host: '127.0.0.1', port: port);
    await until(() => fake.wifiClient != null);

    // Without the request, nothing but frames' own ACKs go to Bluetooth.
    await card.battery();
    expect(String.fromCharCodes(fake.wifiReceived.toBytes()), isNot(contains('ACK')));

    final tcp = fake.wifiClient!;
    fake.wifiClient = null;
    fake.notify(FrameType.control, ControlCmd.wifiAckMode, [1]);
    fake.wifiClient = tcp;
    expect(card.wifi!.ackEachPacket, isTrue);
    await card.battery();
    await until(() => String.fromCharCodes(fake.wifiReceived.toBytes()).contains('ACK\r\n'));
  });

  test('a dropped Wi-Fi link falls back to Bluetooth', () async {
    final port = await fake.startWifi();
    await card.connectWifi(host: '127.0.0.1', port: port);
    await until(() => fake.wifiClient != null);
    fake.wifiClient!.destroy();
    fake.wifiClient = null;
    await until(() => card.wifi == null);
    expect((await card.battery()).percent, isNotNull);
  });

  test('closing the hotspot closes the link', () async {
    final port = await fake.startWifi();
    await card.connectWifi(host: '127.0.0.1', port: port);
    await card.closeHotspot();
    expect(card.wifi, isNull);
  });

  test('connectWifi gives up when nothing listens', () async {
    await expectLater(
      card.connectWifi(host: '127.0.0.1', port: 1, timeout: const Duration(seconds: 2)),
      throwsA(anything),
    );
  });

  test('reports a phone joining the hotspot', () async {
    final joined = card.hotspotClients.first;
    fake.notify(FrameType.control, ControlCmd.hotspotClient, [1]);
    expect(await joined, isTrue);
  });

  test('Wi-Fi direct: network, upload address, read back, reset', () async {
    await card.setWifiNetwork('Office', 'secret123');
    expect(fake.wifiSsid, 'Office');
    final sent = fake.written.last.body;
    expect(sent.sublist(0, 2), [0, 6]);
    expect(sent.sublist(8, 10), [0, 9]);

    await card.setUploadUrl('https://example.com/upload');
    expect(fake.uploadUrl, 'https://example.com/upload');

    final cfg = await card.wifiNetwork();
    expect(cfg.ssid, 'Office');
    expect(cfg.state, 1);

    await card.resetWifiNetwork();
    expect((await card.wifiNetwork()).ssid, '');
  });
}

/// A card that refuses to open its hotspot.
class _RefusingCard extends FakeCard {
  @override
  Future<void> write(Uint8List bytes) async {
    for (final f in FrameParser().add(bytes)) {
      if (f.type == FrameType.control && f.cmd == ControlCmd.openHotspot) {
        notify(FrameType.control, ControlCmd.hotspotOpened, [1]);
        return;
      }
    }
    return super.write(bytes);
  }
}
