# Wi-Fi

`DiscoveredCard.model` tells you which family a card belongs to:

| `CardModel` | Wi-Fi | What it is for |
|---|---|---|
| `bluetooth` | none | everything over Bluetooth |
| `wifiHotspot` | the card opens its own hotspot | fast file transfer; the phone joins the hotspot |
| `wifiDirect` | the card joins your Wi-Fi network | the card uploads recordings to your server by itself |

## Hotspot transfer (0.2.0)

Bluetooth stays connected and carries every command. Once the Wi-Fi link is up,
the card sends **file data** over Wi-Fi instead of Bluetooth. Everything else
(replies, button presses, live audio) still comes over Bluetooth.

Measured on a Wi-Fi card, firmware 544: a 119 KB recording in 1.5 s
(about 76 KB/s), against about 3.6 KB/s over Bluetooth.

```dart
final card = await TalkaNote.connect(found);       // Bluetooth first

await card.setHotspotPassword('choose-a-password'); // recommended, see below
final hotspot = await card.openHotspot();           // e.g. "AI NOTE CB08"

// Your app joins hotspot.name here (see "Joining the hotspot").

await card.connectWifi();                           // TCP to 192.168.1.1:27689
final files = await card.listFiles();
final opus = await card.download(files.last);       // arrives over Wi-Fi

await card.closeHotspot();                          // also closes the link
```

| Call | |
|---|---|
| `openHotspot()` | turns the hotspot on; returns `Hotspot(name)` |
| `closeHotspot()` | turns it off and closes the Wi-Fi link |
| `setHotspotPassword(pw)` | 8 to 16 characters; the card keeps it |
| `hotspotHasClient()` / `hotspotClients` | whether a device has joined |
| `connectWifi({host, port, timeout})` | opens and attaches the TCP link; retries until `timeout` |
| `wifi` | the attached `CardWifiLink`, or null |
| `disconnectWifi()` | closes the link; Bluetooth stays |

If the Wi-Fi link drops, downloads continue over Bluetooth.

### Password

The hotspot is **open (no password)** out of the box, so anyone nearby can join
it while it is on. Set a password with `setHotspotPassword` before you turn the
hotspot on, and turn it off when the transfer is done.

### Joining the hotspot

The phone's operating system joins Wi-Fi networks, not this SDK:

- **Android 10+**: `WifiNetworkSpecifier` with `ConnectivityManager.requestNetwork`,
  then bind the process to that network (`bindProcessToNetwork`). Without the
  binding, Android may send the TCP connection over mobile data, because the
  card's network has no internet.
- **iOS 11+**: `NEHotspotConfiguration` (needs the *Hotspot Configuration*
  capability). iOS asks the user to confirm.
- **Windows**: `netsh wlan`. The [example app](../example/lib/windows_wifi.dart)
  does this for you.

Flutter plugins exist for the Android and iOS calls; check each plugin's
licence before you ship it. We have tested the Windows path only.

Watch for a home or office network that also uses `192.168.1.x`: make sure the
device has actually joined the card's network before `connectWifi`, or the
connection goes to the wrong `192.168.1.1`.

### Protocol

| Command | Bytes (TYPE CMD params) | Reply |
|---|---|---|
| open hotspot | `00 13` | `00 14` state (0 = ok), SSID |
| close hotspot | `00 15` | `00 16` |
| hotspot client? | `00 18` | `00 17` 1 = joined, 0 = not |
| set password | `00 3E` len (2 B, big-endian), UTF-8 | `00 3F` result (0 = ok) |

The card also sends `00 17` by itself when a device joins or leaves, and
`00 1E 01` after connecting, which asks the app to answer every TCP packet with
`ACK\r\n`. The app sends `01 0A` every 30 s as a heartbeat. TCP frames are
acknowledged with `ACK\r\n` only, not over Bluetooth.

## Direct upload (wifiDirect models)

The card joins a Wi-Fi network and uploads recordings to your server by itself.

| Call | Bytes | Reply |
|---|---|---|
| `setWifiNetwork(ssid, password)` | `06 00` len, SSID, len, password | `06 01` result |
| `setUploadUrl(url)` | `06 03` len, URL | `06 04` result |
| `wifiNetwork()` | `06 07` | `06 08` len, SSID, state |
| `resetWifiNetwork()` | `06 05` | `06 06` result |

Lengths are 2 bytes, big-endian. Result 0 = ok.

**Not yet tested on a card:** we have no `wifiDirect` card yet. What the card
sends to the upload URL is not documented here yet.
