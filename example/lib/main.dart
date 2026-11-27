import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';
import 'package:talkanote/talkanote.dart';

void main() => runApp(const ExampleApp());

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'talkaNote SDK example',
    theme: ThemeData(colorSchemeSeed: const Color(0xFF6D4AFF)),
    home: const CardPage(),
  );
}

class CardPage extends StatefulWidget {
  const CardPage({super.key});

  @override
  State<CardPage> createState() => _CardPageState();
}

class _CardPageState extends State<CardPage> {
  final _found = <DiscoveredCard>[];
  final _log = <String>[];
  TalkaNoteCard? _card;
  String _info = '';
  List<CardFile> _files = [];
  bool _scanning = false;
  bool _busy = false;
  bool _live = false;
  int _liveBytes = 0;
  String _transfer = '';
  final _subs = <StreamSubscription<Object>>[];

  void _say(String s) {
    final t = TimeOfDay.now().format(context);
    setState(() => _log.insert(0, '$t  $s'));
  }

  Future<void> _run(String label, Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      _say('$label failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _scan() async {
    setState(() {
      _found.clear();
      _scanning = true;
    });
    try {
      await TalkaNote.requestPermissions();
      await for (final c in TalkaNote.scan()) {
        setState(() => _found.add(c));
      }
    } catch (e) {
      _say('Scan failed: $e');
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _connect(DiscoveredCard found) => _run('Connect', () async {
    _say('Connecting to ${found.name} ${found.id}…');
    final card = await TalkaNote.connect(found, log: _say);
    _subs
      ..add(card.buttonEvents.listen((e) => _say('Button: ${e.action.name}${e.answered ? ' (answered)' : ''}')))
      ..add(card.liveEvents.listen(_onLive));
    card.disconnected.then((_) {
      if (!mounted) return;
      _say('Disconnected');
      setState(() {
        _card = null;
        _live = false;
      });
    });
    setState(() => _card = card);
    _say('Connected (${found.model.name})');
    await _refresh();
  });

  void _onLive(LiveEvent e) {
    switch (e) {
      case LiveStarted(:final fileName):
        _say('Live: recording to $fileName');
        setState(() {
          _live = true;
          _liveBytes = 0;
        });
      case LiveAudio(:final opus):
        setState(() => _liveBytes += opus.length);
      case LivePaused():
        _say('Live: paused');
      case LiveResumed():
        _say('Live: resumed');
      case LiveStopped():
        _say('Live: stopped after ${opusDuration(_liveBytes).inSeconds} s of audio');
        setState(() => _live = false);
    }
  }

  Future<void> _refresh() async {
    final card = _card!;
    final battery = await card.battery();
    final storage = await card.storage();
    final version = await card.firmwareVersion();
    final state = await card.recordingState();
    final gain = await card.gain();
    final files = await card.listFiles();
    setState(() {
      _info =
          'Battery ${battery.charging ? 'charging' : '${battery.percent}%'} · '
          'firmware $version · ${(storage.freeKb / 1048576).toStringAsFixed(1)} of '
          '${(storage.totalKb / 1048576).toStringAsFixed(1)} GiB free · ${state.name} · gain ${gain?.name}';
      _files = files.reversed.toList();
    });
  }

  Future<void> _download(CardFile f) => _run('Download', () async {
    final watch = Stopwatch()..start();
    final data = await _card!.download(
      f,
      onProgress: (got, total) => setState(() => _transfer = '${f.name}: $got of $total B'),
    );
    final dir = await getApplicationDocumentsDirectory();
    final out = File('${dir.path}${Platform.pathSeparator}${f.name}');
    await out.writeAsBytes(data);
    final rate = data.length / (watch.elapsedMilliseconds / 1000);
    setState(() => _transfer = '');
    _say('Saved ${out.path} (${data.length} B, ${rate.toStringAsFixed(0)} B/s)');
  });

  Future<void> _delete(CardFile f) => _run('Delete', () async {
    final ok = await _card!.delete(f);
    _say(
      'Delete ${f.name}: ${ok == null
          ? 'sent, no answer'
          : ok
          ? 'done'
          : 'refused'}',
    );
    await _refresh();
  });

  Future<void> _toggleRecording() => _run('Record', () async {
    final card = _card!;
    if (await card.recordingState() == RecordingState.idle) {
      await card.startRecording();
      _say('Recording started');
    } else {
      await card.saveRecording();
      _say('Recording saved');
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    await _refresh();
  });

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _card?.disconnect();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final card = _card;
    return Scaffold(
      appBar: AppBar(title: const Text('talkaNote SDK example')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (card == null) ...[
              FilledButton(onPressed: _scanning ? null : _scan, child: Text(_scanning ? 'Scanning…' : 'Scan')),
              for (final c in _found)
                ListTile(
                  title: Text('${c.name}  ${c.id}'),
                  subtitle: Text('${c.model.name} · RSSI ${c.rssi}'),
                  trailing: TextButton(onPressed: _busy ? null : () => _connect(c), child: const Text('Connect')),
                ),
            ] else ...[
              Text(_info),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  FilledButton(
                    onPressed: _busy ? null : _toggleRecording,
                    child: Text(_live ? 'Stop and save' : 'Record + live'),
                  ),
                  OutlinedButton(
                    onPressed: _busy ? null : () => _run('Refresh', _refresh),
                    child: const Text('Refresh'),
                  ),
                  OutlinedButton(onPressed: () => card.disconnect(), child: const Text('Disconnect')),
                ],
              ),
              if (_live) Text('Live audio: ${opusDuration(_liveBytes).inSeconds} s received'),
              if (_transfer.isNotEmpty) Text(_transfer),
              const Divider(),
              Expanded(
                child: ListView(
                  children: [
                    for (final f in _files)
                      ListTile(
                        dense: true,
                        title: Text(f.name),
                        subtitle: Text('${f.duration.inSeconds} s · ${f.size} B · ${f.mode.name}'),
                        trailing: Wrap(
                          children: [
                            IconButton(
                              tooltip: 'Download',
                              onPressed: _busy ? null : () => _download(f),
                              icon: const Icon(Icons.download),
                            ),
                            IconButton(
                              tooltip: 'Delete',
                              onPressed: _busy ? null : () => _delete(f),
                              icon: const Icon(Icons.delete_outline),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ],
            const Divider(),
            SizedBox(
              height: 160,
              child: ListView(
                children: [
                  for (final l in _log) Text(l, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
