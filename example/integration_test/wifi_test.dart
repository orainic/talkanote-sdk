// Runs Wi-Fi hotspot transfer against a real Wi-Fi card, on Windows.
//
//   cd example
//   flutter test integration_test/wifi_test.dart -d windows --dart-define=CARD_ID=D1:A1:D3:00:0D:29
//
// The computer leaves its Wi-Fi network for about a minute to join the card's
// hotspot, then goes back. The test records about 20 seconds, downloads that
// recording over Wi-Fi, then deletes it. It never touches other recordings.

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:talkanote/talkanote.dart';
import 'package:talkanote_example/windows_wifi.dart';

const cardId = String.fromEnvironment('CARD_ID');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Wi-Fi hotspot transfer end to end', (tester) async {
    final home = await WindowsWifi.currentNetwork();
    debugPrint('home network: $home');

    final found = await TalkaNote.scan(timeout: const Duration(seconds: 15))
        .firstWhere((c) => cardId.isEmpty || c.id.toUpperCase() == cardId.toUpperCase());
    debugPrint('found $found');
    final card = await TalkaNote.connect(found, log: debugPrint);
    addTearDown(card.disconnect);

    final before = await card.listFiles();
    await card.startRecording();
    await Future<void>.delayed(const Duration(seconds: 20));
    await card.saveRecording();
    await Future<void>.delayed(const Duration(seconds: 2));
    final created = (await card.listFiles()).where((f) => !before.any((b) => b.name == f.name)).toList();
    expect(created, hasLength(1), reason: 'one new recording');
    final file = created.single;
    debugPrint('new file $file');

    String? hotspotName;
    try {
      final hotspot = await card.openHotspot();
      hotspotName = hotspot.name;
      debugPrint('hotspot $hotspot');

      final join = Stopwatch()..start();
      await WindowsWifi.joinOpen(hotspot.name);
      debugPrint('joined ${hotspot.name} in ${join.elapsedMilliseconds} ms');

      final link = await card.connectWifi(timeout: const Duration(seconds: 30));
      expect(card.wifi, isNotNull);
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(await card.hotspotHasClient(), isTrue);

      final watch = Stopwatch()..start();
      final data = await card.download(file);
      final ms = watch.elapsedMilliseconds;
      debugPrint(
        'Wi-Fi download: ${data.length} B in $ms ms '
        '(${(data.length / 1024 / (ms / 1000)).toStringAsFixed(1)} KB/s), ${link.received} B over TCP',
      );
      expect(data.length, file.size);
      expect(link.received, greaterThanOrEqualTo(file.size), reason: 'the data came over Wi-Fi');
    } finally {
      await card.closeHotspot();
      final back = Stopwatch()..start();
      await WindowsWifi.rejoin(home, forget: hotspotName);
      debugPrint('rejoin took ${back.elapsedMilliseconds} ms');
      debugPrint('back on ${await WindowsWifi.currentNetwork()}');
    }
    expect(card.wifi, isNull);
    expect(await WindowsWifi.currentNetwork(), home);

    expect(await card.delete(file), isTrue);
  }, timeout: const Timeout(Duration(minutes: 4)));
}
