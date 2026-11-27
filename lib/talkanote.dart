/// Flutter SDK for the talkaNote recording card.
///
/// ```dart
/// await TalkaNote.requestPermissions();
/// final found = await TalkaNote.scan().first;
/// final card = await TalkaNote.connect(found);
/// final files = await card.listFiles();
/// final opus = await card.download(files.last);
/// ```
library;

export 'src/audio.dart';
export 'src/ble/universal_ble_transport.dart' show CardUuids, DiscoveredCard, TalkaNote, UniversalBleTransport;
export 'src/card.dart';
export 'src/models.dart';
export 'src/protocol/commands.dart';
export 'src/protocol/crc16.dart';
export 'src/protocol/frame.dart';
export 'src/transport.dart';
