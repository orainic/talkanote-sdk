import 'dart:io';

/// Joins and leaves Wi-Fi networks on Windows with `netsh`, so the example can
/// reach the card's hotspot without the user changing networks by hand.
///
/// On Android and iOS your app asks the operating system to join instead; see
/// docs/wifi.md.
class WindowsWifi {
  /// The network this computer is on now, or null.
  static Future<String?> currentNetwork() async {
    final r = await Process.run('netsh', ['wlan', 'show', 'interfaces']);
    // Lines end in \r\n; trim them before matching.
    for (final line in (r.stdout as String).split('\n').map((l) => l.trim())) {
      final m = RegExp(r'^SSID\s*:\s*(.+)$').firstMatch(line);
      if (m != null) return m.group(1)!.trim();
    }
    return null;
  }

  /// Joins the open network [ssid] and waits until it is connected.
  static Future<void> joinOpen(String ssid, {Duration timeout = const Duration(seconds: 30)}) async {
    final esc = ssid.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
    final xml =
        '<?xml version="1.0"?><WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">'
        '<name>$esc</name><SSIDConfig><SSID><name>$esc</name></SSID></SSIDConfig>'
        '<connectionType>ESS</connectionType><connectionMode>manual</connectionMode>'
        '<MSM><security><authEncryption><authentication>open</authentication><encryption>none</encryption>'
        '<useOneX>false</useOneX></authEncryption></security></MSM></WLANProfile>';
    final file = File('${Directory.systemTemp.path}${Platform.pathSeparator}talkanote_hotspot.xml');
    await file.writeAsString(xml);
    await Process.run('netsh', ['wlan', 'add', 'profile', 'filename=${file.path}', 'user=current']);
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      // The card's network can take a few seconds to appear in the scan.
      if (await currentNetwork() == ssid) return;
      await Process.run('netsh', ['wlan', 'connect', 'name=$ssid', 'ssid=$ssid']);
      await Future<void>.delayed(const Duration(seconds: 3));
    }
    throw Exception('Could not join "$ssid"');
  }

  /// Goes back to [ssid] and forgets the card's network [forget].
  /// Waits until connected, up to [timeout].
  static Future<void> rejoin(String? ssid, {String? forget, Duration timeout = const Duration(seconds: 45)}) async {
    if (forget != null) await Process.run('netsh', ['wlan', 'delete', 'profile', 'name=$forget']);
    if (ssid == null) return;
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (await currentNetwork() == ssid) return;
      await Process.run('netsh', ['wlan', 'connect', 'name=$ssid']);
      await Future<void>.delayed(const Duration(seconds: 3));
    }
  }
}
