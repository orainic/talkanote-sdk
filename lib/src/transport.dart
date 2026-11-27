import 'dart:async';
import 'dart:typed_data';

/// The link between the SDK and one card.
///
/// [UniversalBleTransport] implements it over Bluetooth LE. Implement it
/// yourself to use another BLE library, or in tests.
abstract interface class CardTransport {
  /// Notifications from characteristic 0xAE22: replies, file data and audio.
  Stream<Uint8List> get mainNotifications;

  /// Notifications from characteristic 0xAE23: button and recording events.
  Stream<Uint8List> get eventNotifications;

  /// Writes [bytes] to characteristic 0xAE21 as one write without response.
  Future<void> write(Uint8List bytes);

  /// Largest number of bytes one [write] can carry (ATT MTU minus 3).
  int get maxWriteLength;

  /// Emits once when the link drops.
  Future<void> get disconnected;

  Future<void> disconnect();
}
