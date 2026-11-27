import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talkanote/talkanote.dart';

import 'fake_card.dart';

Uint8List _bytes(int n) => Uint8List.fromList(List.generate(n, (i) => i & 0xFF));

void main() {
  late FakeCard fake;
  late TalkaNoteCard card;

  setUp(() {
    fake = FakeCard();
    card = TalkaNoteCard(fake);
  });

  test('reads battery, storage and firmware', () async {
    expect((await card.battery()).percent, 87);
    fake.battery = 110;
    expect((await card.battery()).charging, isTrue);
    expect((await card.storage()).totalKb, 30712448);
    expect(await card.firmwareVersion(), 'V1.0.0');
  });

  test('syncs the clock with year little-endian', () async {
    await card.syncTime(DateTime(2026, 11, 27, 9, 5, 7));
    expect(fake.written.last.body, [0xEA, 0x07, 11, 27, 9, 5, 7]);
  });

  test('lists files across batches', () async {
    fake.files
      ..['note20261127-090000.opus'] = _bytes(4000)
      ..['note20261127-091500.opus'] = _bytes(800)
      ..['call20261127-093000.opus'] = _bytes(1200);
    final files = await card.listFiles();
    expect(files.map((f) => f.name), fake.files.keys);
    expect(files.last.mode, RecordingMode.call);
  });

  test('an empty card answers the list with nothing', () {
    fakeAsync((async) {
      final fresh = TalkaNoteCard(_SilentCard());
      List<CardFile>? result;
      fresh.listFiles().then((r) => result = r);
      async.elapse(const Duration(seconds: 2));
      expect(result, isEmpty);
    });
  });

  test('downloads a file and reports progress and data', () async {
    final data = _bytes(5000);
    fake.files['note20261127-090000.opus'] = data;
    final file = (await card.listFiles()).single;
    var chunks = 0, last = 0;
    final got = await card.download(file, onData: (_) => chunks++, onProgress: (r, _) => last = r);
    expect(got, data);
    expect(chunks, 32);
    expect(last, 5000);
    // The download request (36 bytes) went out as one write.
    expect(fake.written.last.data.length, 30);
  });

  test('resumes a stalled download from the last byte', () {
    fakeAsync((async) {
      final data = _bytes(5000);
      fake.files['note20261127-090000.opus'] = data;
      fake.stallAfter = 1600;
      late CardFile file;
      card.listFiles().then((f) => file = f.single);
      async.elapse(const Duration(seconds: 2));
      Uint8List? got;
      card.download(file).then((d) => got = d);
      async.elapse(const Duration(seconds: 15));
      expect(got, data);
      final requests = fake.written.where((f) => f.type == FrameType.file && f.cmd == FileCmd.download).toList();
      expect(requests, hasLength(2));
      expect(ByteData.sublistView(requests.last.body).getUint32(0, Endian.little), 1600);
    });
  });

  test('newer firmware: long names list, download and delete', () async {
    fake
      ..longNames = true
      ..files['note 2026-11-27_10-02-08.opus'] = _bytes(800);
    final file = (await card.listFiles()).single;
    expect(file.name, 'note 2026-11-27_10-02-08.opus');
    expect(await card.download(file), hasLength(800));
    expect(await card.delete(file), isTrue);
  });

  test('acknowledges every frame from the card', () async {
    await card.battery();
    expect(fake.acks, hasLength(1));
  });

  test('records through the live channel', () async {
    await card.startRecording();
    await card.pauseRecording();
    await card.resumeRecording();
    await card.saveRecording();
    expect(fake.written.map((f) => (f.type, f.cmd, f.body.toList().join(','))), [
      (FrameType.live, LiveCmd.start, ''),
      (FrameType.live, LiveCmd.pauseResume, '1'),
      (FrameType.live, LiveCmd.pauseResume, '0'),
      (FrameType.live, LiveCmd.stop, ''),
      (FrameType.live, LiveCmd.stop, ''),
    ]);
  });

  test('a missing file fails without retrying', () async {
    final file = CardFile(name: 'note20990101-000000.opus', duration: Duration.zero, size: 0, listEntry: Uint8List(28));
    await expectLater(card.download(file), throwsA(isA<FileNotFoundOnCard>()));
  });

  test('refuses a download request that would need two writes', () async {
    final small = TalkaNoteCard(FakeCard(maxWriteLength: 20));
    final file = CardFile(name: 'note20261127-090000.opus', duration: Duration.zero, size: 0, listEntry: Uint8List(28));
    await expectLater(small.download(file), throwsA(isA<TalkaNoteException>()));
  });

  test('deletes by full name', () async {
    fake.files['note20261127-090000.opus'] = _bytes(40);
    final file = (await card.listFiles()).single;
    expect(await card.delete(file), isTrue);
    expect(fake.files, isEmpty);
    expect(fake.written.where((f) => f.cmd == FileCmd.deleteOne).first.body.sublist(0, 4), [0, 0, 0, 0]);
  });

  test('answers a button press so the card acts', () async {
    final events = <ButtonEvent>[];
    card.buttonEvents.listen(events.add);
    fake.event(FrameType.recording, RecordCmd.start);
    await pumpEventQueue();
    expect(events.single.action, ButtonAction.start);
    expect(events.single.answered, isTrue);
    final answer = fake.written.last;
    expect((answer.type, answer.cmd), (FrameType.recording, RecordCmd.startResult));
    expect(answer.body, [1]);
  });

  test('leaves button answers to the app when asked to', () async {
    card.autoAnswerButtons = false;
    final events = <ButtonEvent>[];
    card.buttonEvents.listen(events.add);
    fake.event(FrameType.recording, RecordCmd.save);
    await pumpEventQueue();
    expect(events.single.answered, isFalse);
    expect(fake.written, isEmpty);
  });

  test('streams live audio and its state', () async {
    final events = <LiveEvent>[];
    card.liveEvents.listen(events.add);
    fake
      ..notify(FrameType.live, LiveCmd.start, 'note20261127-100000.opus'.codeUnits)
      ..notify(FrameType.live, LiveCmd.audio, _bytes(160))
      ..notify(FrameType.live, LiveCmd.state, [2]);
    await pumpEventQueue();
    expect((events[0] as LiveStarted).fileName, 'note20261127-100000.opus');
    expect((events[1] as LiveAudio).opus, hasLength(160));
    expect(events[2], isA<LiveStopped>());
  });

  test('sets gain', () async {
    expect(await card.setGain(Gain.high), isTrue);
    expect(fake.written.last.body, [3]);
  });

  test('fails pending requests when the link drops', () async {
    final silent = _SilentCard();
    final c = TalkaNoteCard(silent);
    final pending = c.battery();
    await silent.disconnect();
    await expectLater(pending, throwsA(isA<TalkaNoteException>()));
  });
}

/// A card that never answers.
class _SilentCard extends FakeCard {
  @override
  Future<void> write(Uint8List bytes) async {}
}
