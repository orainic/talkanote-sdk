# Wi-Fi

`DiscoveredCard.model` tells you which family a card belongs to:

| `CardModel` | Wi-Fi | What it is for |
|---|---|---|
| `bluetooth` | none | everything over Bluetooth |
| `wifiHotspot` | the card opens its own hotspot | fast file transfer and firmware updates; the phone joins the hotspot |
| `wifiDirect` | the card joins your Wi-Fi network | the card uploads recordings to your server by itself |

## Status in this SDK

**Not available yet (0.1.0).** Bluetooth works on every model, so `wifiHotspot`
and `wifiDirect` cards can be used today with Bluetooth transfer.

Planned:

1. **Hotspot transfer.** Over Bluetooth, the app turns on the card's hotspot
   and reads its name. The phone joins it, then opens a TCP connection to the
   card at `192.168.1.1:27689`, which carries the same frames as Bluetooth.
   Bluetooth stays the control channel.
2. **Direct upload.** Over Bluetooth, the app gives the card a Wi-Fi network
   (SSID and password) and an upload URL. The card then uploads recordings by
   itself.

Joining a hotspot is a platform API (`WifiNetworkSpecifier` on Android,
`NEHotspotConfiguration` on iOS), outside this SDK's Bluetooth layer.
