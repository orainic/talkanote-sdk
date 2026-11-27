# Changelog

## 0.2.0

- Wi-Fi hotspot transfer: `openHotspot`, `connectWifi`, `closeHotspot`,
  `setHotspotPassword`, `hotspotHasClient`, `hotspotClients`. File data comes
  over Wi-Fi; commands stay on Bluetooth. About 76 KB/s on firmware 544, against
  3.6 KB/s over Bluetooth.
- `CardWifiLink`: TCP link with heartbeat and the card's `ACK` mode.
- Wi-Fi direct upload commands: `setWifiNetwork`, `setUploadUrl`,
  `wifiNetwork`, `resetWifiNetwork` (not yet tested on a card).
- Example app: Wi-Fi button; on Windows it joins the card's hotspot by itself.

## 0.1.0

First release.

- Scan, connect (universal_ble), model detection from the advertisement.
- Card status: battery, storage, firmware, clock sync, app foreground state.
- Recording control: start, save, pause, resume, state, time, file name, gain.
- Button presses answered automatically, with an opt-out.
- File list, download with progress, streaming and resume after stalls, Opus or WAV.
- Delete one or all recordings.
- Live audio stream while recording; Opus packet and WAV helpers.
- Works with both firmware lines: fixed 20-byte list names (`V1.0.0`) and
  longer names (`544`); every card frame is acknowledged.
- Tested end to end on a Wi-Fi card, firmware 544.
