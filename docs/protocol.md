# talkaNote card: Bluetooth LE protocol

You don't need this to use the Flutter SDK. It is for tools in other languages
(Python, Web Bluetooth, a server-side gateway) and for debugging.

Facts marked **[verified]** were measured on real cards: a Bluetooth card
(firmware `V1.0.0`) and a Wi-Fi card (firmware `544`). Where the two differ,
both are described.

## Advertising

| Field | Value |
|---|---|
| Name | `CB08`. Several cards share it; identify a card by its address. |
| Service UUID | `0xAE20` |
| Manufacturer data | company ID `0xE4xx`. The model code is the low byte XOR `0x35`: `1` Bluetooth only, `3` Wi-Fi hotspot, `5` Wi-Fi direct upload. **[verified]** `0xE434` → 1, `0xE436` → 3 |

The card also exposes standard GATT services (Heart Rate, Battery `0x180F`,
Current Time). They carry no talkaNote data; **[verified]** `0x180F` reads a
wrong battery level. Use the protocol's battery command.

## GATT

| UUID | Properties | Use |
|---|---|---|
| `0xAE20` | service | |
| `0xAE21` | write without response | app → card frames |
| `0xAE22` | notify | replies, file list, file data, live audio. Subscribe first. |
| `0xAE23` | notify | button presses and recording events |

Keep a separate reassembly buffer for each notify characteristic. Request an
MTU of at least 39 (the download request must fit in one write; see below).

## Frame

| Offset | Size | Field | Notes |
|---|---|---|---|
| 0 | 1 | MAGIC | `0x5A` |
| 1 | 1 | SEQ | 0–255, wraps |
| 2 | 2 | CRC | CRC-16/XMODEM (poly `0x1021`, init 0), little-endian, over LEN + DATA |
| 4 | 2 | LEN | length of DATA, little-endian |
| 6 | LEN | DATA | `TYPE` (1 B) + `CMD` (1 B) + parameters |

A notification can carry part of a frame or several frames; reassemble by LEN
and resynchronise on the next `0x5A` after a bad CRC. A DATA of one byte (TYPE
only) is an ACK.

**Acknowledge every frame from the card** (except ACKs) by sending back an ACK
with the same SEQ: DATA = `03`. Example for SEQ 7: `5A 07` + CRC + `01 00 03`.

Example **[verified]**, button "start recording" from the card:
`5A 00 1A A8 02 00 03 01` = SEQ 0, CRC `0xA81A`, LEN 2, TYPE 3, CMD 1.

## Commands

Written `TYPE-CMD` in decimal. → app to card, ← card to app. Integers are
little-endian unless marked BE.

### TYPE 0: control

| Command | Parameters / reply |
|---|---|
| 0-0 → sync time | year (2 B) + month, day, hour, minute, second (1 B each). No reply. Send right after connecting. |
| 0-1 → / 0-2 ← storage | reply: free (4 B) + total (4 B), KiB |
| 0-3 → / 0-4 ← battery | reply: 1 B, 0–100; `110` = charging |
| 0-10 → / 0-11 ← firmware | reply: ASCII, e.g. `V1.0.0` |
| 0-18 → app state | 1 B: `1` foreground, `2` background. No reply. |
| 0-4 ← battery, unsolicited | firmware `544` also sends the battery level by itself |
| 0-30 ← (undocumented) | firmware `544` sends `01` after connecting; meaning unknown, ignore it |

### TYPE 1: live audio

| Command | Parameters / reply |
|---|---|
| 1-0 → start recording | the card starts a recording and streams it: ← 1-0 with the file name, then 1-1 packets. No other confirmation. **[verified]** |
| 1-1 ← audio | raw Opus, 160 B per notification (four 40-byte packets) |
| 1-2 → stop and save | send it twice; the card can miss one **[verified]** |
| 1-3 → pause / resume | 1 B: `1` pause, `0` resume |
| 1-4 ← state | 1 B: `0` running, `1` paused, `2` stopped |

When a recording is started with the card's button and the app answers, the
card can also stream 1-0 / 1-1 without a 1-0 request; handle 1-0 at any time.

### TYPE 2: files

| Command | Parameters / reply |
|---|---|
| 2-0 → list | ← one or more 2-1, then 2-18. An empty card may send nothing: stop after about 1.2 s of silence. |
| 2-1 ← list batch | count (4 B **BE**), then count × 28 B entries |
| 2-18 ← list done | 1 B, `0` |
| 2-2 → download | offset (4 B) + file name: NUL-padded to 24 B if shorter, otherwise as it is. **Must be one write.** |
| 2-3 ← download start | file name |
| 2-4 ← file data | bytes, in order |
| 2-5 ← download end | 1 B: `0` done, `1` not found, `2` offset too large, `3` stopped |
| 2-7 → abort | ← 2-11 |
| 2-8 → delete one | 4 zero bytes + full file name. ← 2-13: `0` deleted, `1` failed |
| 2-9 → delete all | ← 2-10: `0` deleted, `1` failed |
| 2-12 → range download | start (4 B) + end (4 B) + file name (24 B) |

List entry: duration in seconds (4 B **BE**), size in bytes (4 B **BE**),
then the name up to and including its first `.`, with no padding; the next
entry starts right after the dot. The extension is cut off: add `opus` back.

| Firmware | Name as listed | Full name |
|---|---|---|
| `V1.0.0` | `note20261030-111449.` (always 20 bytes) | `note20261030-111449.opus` |
| `544` | ` note 2026-11-27_13-10-32.` (leading space) | `note 2026-11-27_13-10-32.opus` (trim the space) |

Names start with `note` (room microphones) or `call` (bone-conduction
microphone), set by the switch on the card.

Rules **[verified]**:
- Split the 2-2 request into two writes and the card answers 2-5 code 1.
- Request `<base>.opus` for the stored file. Request `<base>.wav` and the card
  converts to WAV (16 kHz, 16-bit, mono) while sending, 16 times larger.
- Transfers can pause for more than 12 s on long files. Resume with 2-7, then
  2-2 with the offset of the bytes received so far.
- Delete needs the full name with extension; the raw list entry as
  parameter fails on firmware V1.0.0.
- Bluetooth throughput is about 2.5 KB/s (`V1.0.0`) to 3.6 KB/s (`544`).

### TYPE 3: recording and the button

| Command | Parameters / reply |
|---|---|
| 3-1 / 3-3 / 3-5 / 3-7 ← button: start / save / pause / resume | the app answers 3-2 / 3-4 / 3-6 / 3-8: `1` accept, `2` refuse. To record from the app, use 1-0 / 1-2 / 1-3 instead; firmware `544` did not answer 3-1 from the app in our test |
| 3-19 → / 3-20 ← state | `1` recording, `2` idle, `3` paused |
| 3-21 → / 3-22 ← time | duration (2 B, s) + bytes so far (4 B) |
| 3-23 → / 3-24 ← current file name | |
| 3-25 → / 3-26 ← gain | `1` low, `2` medium, `3` high |
| 3-27 → / 3-28 ← set gain | 1 B gain. Reply `0` ok |

**Button presses.** When the button is pressed, the card sends 3-1, 3-3, 3-5
or 3-7 on `AE23` and waits. Answer with CMD + 1 and parameter `1` (accept) or
`2` (refuse); e.g. 3-1 → reply 3-2 `01`. **[verified]** Without an answer the
card drops the link a few seconds later. The card also echoes a command the
app has just sent on `AE23`; don't answer that echo.

## Wi-Fi

See [wifi.md](wifi.md).
