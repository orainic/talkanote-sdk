// Runs the SDK against a real card over Bluetooth.
//
//   cd example
//   flutter test integration_test -d windows --dart-define=CARD_ID=D1:A1:D3:00:09:E2
//
// The card must be awake and not connected to another app. The test records
// about 5 seconds, checks the live stream and the saved file, then deletes
// that recording again. It never touches other recordings.

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:talkanote/talkanote.dart';

const cardId = String.fromEnvironment('CARD_ID');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('talkaNote card end to end', (tester) async {
    await TalkaNote.requestPermissions();
    final found = await TalkaNote.scan(timeout: const Duration(seconds: 12))
        .firstWhere((c) => cardId.isEmpty || c.id.toUpperCase() == cardId.toUpperCase());
    debugPrint('found $found');

    final card = await TalkaNote.connect(found, log: debugPrint);
    addTearDown(card.disconnect);

    final battery = await card.battery();
    final storage = await card.storage();
    final version = await card.firmwareVersion();
    debugPrint('battery $battery, $storage, firmware $version');
    expect(storage.totalKb, greaterThan(0));
    expect(version, isNotEmpty);
    expect(await card.recordingState(), RecordingState.idle);

    final before = await card.listFiles();
    debugPrint('${before.length} files on the card');

    // Record about 5 s with the live stream on.
    var liveBytes = 0;
    String? liveName;
    final live = card.liveEvents.listen((e) {
      if (e is LiveAudio) liveBytes += e.opus.length;
      if (e is LiveStarted) liveName = e.fileName;
    });
    expect(await card.startRecording(), isTrue);
    await card.startLive();
    await Future<void>.delayed(const Duration(seconds: 5));
    await card.stopLive();
    expect(await card.saveRecording(), isTrue);
    await Future<void>.delayed(const Duration(seconds: 1));
    await live.cancel();
    debugPrint('live: $liveBytes B (${opusDuration(liveBytes).inMilliseconds} ms) to $liveName');
    expect(opusDuration(liveBytes).inSeconds, greaterThanOrEqualTo(3));

    final after = await card.listFiles();
    final created = after.where((f) => !before.any((b) => b.name == f.name)).toList();
    expect(created, hasLength(1), reason: 'one new recording');
    final file = created.single;
    debugPrint('new file $file');

    final watch = Stopwatch()..start();
    final data = await card.download(file);
    debugPrint('downloaded ${data.length} B in ${watch.elapsedMilliseconds} ms');
    expect(data.length, file.size);
    expect(data.length % CardAudio.opusPacketBytes, 0);

    expect(await card.delete(file), isTrue);
    final end = await card.listFiles();
    expect(end.any((f) => f.name == file.name), isFalse);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
