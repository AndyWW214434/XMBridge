# How XMBridge talks to the WH-1000XM6

This guide explains the Bluetooth protocol XMBridge uses, in enough detail to build your own client on any
platform: Linux, Windows, Android, a microcontroller, whatever you like. Every byte example in the
"real conversation" section was recorded from a WH-1000XM6 on firmware 2.1.0.

Sony has never published this protocol. Everything here comes from community reverse-engineering, mostly
[mos9527/SonyHeadphonesClient](https://github.com/mos9527/SonyHeadphonesClient) (libmdr) and
[Gadgetbridge](https://codeberg.org/Freeyourgadget/Gadgetbridge), and was checked against a real XM6.
Sony calls it "MDR"; the WH-1000XM5 and XM6 speak its second generation ("v2").

In the code: [`Frame.swift`](../Sources/MDRKit/Frame.swift) (framing), [`Session.swift`](../Sources/MDRKit/Session.swift)
(ACKs and sequence numbers), [`Protocol.swift`](../Sources/MDRKit/Protocol.swift) (requests) and
[`State.swift`](../Sources/MDRKit/State.swift) (parsing replies).

## 1. Transport: an RFCOMM channel

The headphones advertise a vendor service over **Bluetooth Classic** (not BLE) in their SDP records:

```
Service UUID  956C7B26-D49A-4BA8-B03F-B17D393CB6E2   (v2: WH-1000XM5, WH-1000XM6, recent WF/LinkBuds)
              96CC203E-5068-46AD-B32D-E316F5E069BA   (v1: WH-1000XM4 and older, not covered here)
```

Look up that service record on the paired device, read its **RFCOMM channel number**, and open an RFCOMM
(serial) channel to it. The channel number can change between firmware versions, so always look it up rather than
hard-coding it. The headphones must already be paired, and normally connected for audio too.

| Platform | How to open it |
|---|---|
| macOS | IOBluetooth: `getServiceRecord(for:)`, `getRFCOMMChannelID`, `openRFCOMMChannelAsync` (see [`RFCOMMTransport.swift`](../Sources/XMBridge/Bluetooth/RFCOMMTransport.swift)) |
| Linux | BlueZ: find the channel with SDP (`sdptool browse <addr>`), then a `socket(AF_BLUETOOTH, SOCK_STREAM, BTPROTO_RFCOMM)` |
| Windows | Winsock: `SOCKADDR_BTH` with `serviceClassId` set to the UUID, `connect()` |
| Android | `device.createRfcommSocketToServiceRecord(UUID)` |
| iOS | No RFCOMM access. Use External Accessory with protocol `jp.co.sony.songpal.mdr.link2` |

On macOS the app needs `NSBluetoothAlwaysUsageDescription` in its `Info.plist`, or the system kills it the moment
it touches Bluetooth.

## 2. Framing

Every message is one frame:

```
3E │ type │ seq │ length (4 bytes, big-endian) │ payload … │ checksum │ 3C
   └──────────────── escaped ───────────────────────────────────────┘
```

| Field | Meaning |
|---|---|
| `3E` / `3C` | start / end markers |
| type | `0C` = command (the set used here), `0E` = second command set (voice guidance, pairing), `01` = ACK |
| seq | sequence number, `00` or `01` |
| length | payload length |
| checksum | sum of all bytes from *type* to the end of the payload, modulo 256 (before escaping) |

**Escaping.** The bytes `3C`, `3D` and `3E` can't appear between the markers. Each is replaced by `3D` followed by
the byte with bit 4 cleared: `3C → 3D 2C`, `3D → 3D 2D`, `3E → 3D 2E`. Reverse it when reading.

Example: the request "battery level?" (payload `22 00`) with sequence number 0:

```
3E 0C 00 00 00 00 02 22 00 30 3C
      │  └─ length 2 ┘ └─┬─┘ └ checksum: 0C+02+22+00 = 30
      seq              payload
```

A single read from the channel can hold half a frame or several frames, so buffer bytes and split on the markers.

## 3. Link layer: sequence numbers and ACKs

This is the part people most often get wrong, and the headphones simply stop answering when it is.

1. **Sending.** Send a command with your current sequence number (start at `0`). The headphones reply with an
   **ACK frame** (type `01`, empty payload) whose seq is `1 − yours`. Use that value as your next sequence
   number.
2. **One at a time.** Don't send the next command until the previous one is ACKed. XMBridge resends after 1.5 s
   without an ACK, then gives up on that command.
3. **Receiving.** Every command frame the headphones send you (replies and notifications) must be **ACKed with seq
   `1 − theirs`**. If you don't, they keep re-sending it.

```
Mac → 3E 0C 00 00 00 00 02 22 00 30 3C              GET battery, seq 0
XM6 → 3E 01 01 00 00 00 00 02 3C                    ACK, seq 1  → our next seq is 1
XM6 → 3E 0C 00 00 00 00 04 23 00 51 00 84 3C        RET battery: 81 %, seq 0
Mac → 3E 01 01 00 00 00 00 02 3C                    ACK it with seq 1
```

## 4. Payloads

The first payload byte is the command, and most commands carry a sub-type in the second byte. Commands come in
families that share a sub-type:

| Offset in family | Meaning | Example (noise control family `6x`) |
|---|---|---|
| `…6` | GET_PARAM: you ask | `66 19` |
| `…7` | RET_PARAM: the reply | `67 19 …` |
| `…8` | SET_PARAM: you change it | `68 19 …` |
| `…9` | NTFY_PARAM: the headphones report a change, e.g. a button press | `69 19 …` |

`…2/…3/…5` are the same pattern for "status" values (`22`/`23`/`25` for battery). Notifications have the same
layout as replies, so one parser handles both.

**On/off is not consistent.** Noise control and DSEE use `01` = on. The "system" settings (`F6`/`F8` family:
Speak-to-Chat, pause when taken off) and status flags use **`00` = on, `01` = off**.

## 5. A real conversation with a WH-1000XM6

This is XMBridge connecting, as logged by a debug build. `→` is the Mac, `←` the headphones; ACKs are left out.

| Request | Reply | Meaning |
|---|---|---|
| `00 00` | `01 00 03 00 30 13 00 00` | protocol info; the last two bytes `00 00` say command sets 1 and 2 are both supported |
| `04 01` | `05 01 0A` "WH-1000XM6" | model name (length-prefixed) |
| `04 02` | `05 02 05` "2.1.0" | firmware version |
| `06 00` | `07 00 2C 10 FF 12 FF … 6D 0B … FC 0D …` | **support functions**: 0x2C = 44 pairs of (function id, priority) |
| `12 02` | `13 02 02` | audio codec: AAC |
| `22 00` | `23 00 51 00` | battery 0x51 = 81 %, not charging |
| `66 19` | `67 19 01 00 01 00 14 00 00` | noise control: off, ambient level 20, auto ambient off |
| `50 00 01` | `51 00 0A 0D 09 00 00 30 00 31 00 …` | EQ: 10 bands, 13 steps, 9 presets (names are empty on the XM6) |
| `52 00` | `53 00 00` | EQ is available |
| `56 00` | `57 00 A1 0A 0B 0A 0A 08 09 08 07 0A 0A 0A` | EQ: preset User Setting 1, bands +5 +4 +4 +2 +3 +2 +1 +4 +4 +4 |
| `E6 01` | `E7 01 00` | DSEE Extreme off |
| `F6 0C` | `F7 0C 01 01` | Speak-to-Chat off |
| `FA 0C` | `FB 0C 00 01` | Speak-to-Chat: sensitivity Auto, timeout Standard |
| `F6 01` | `F7 01 00` | Pause when taken off: on |
| `26 05` | `27 05 10 00` | Auto power off: when taken off |

## 6. Support functions: ask before you send

The `06 00` reply lists what this headset and firmware can do. Use it to pick the right command variants instead of
hard-coding a model. These are the ids XMBridge uses:

| Id | Feature | What it decides |
|---|---|---|
| `12` | codec indicator | ask `12 02` |
| `20` / `28` | battery / battery with threshold | ask `22 00` / `22 08` |
| `23` | power off | `24 03 01` allowed |
| `24` / `25` | auto power off / … with wearing detection | sub-type `04` / `05` |
| `50` `52` `53` `57` | preset EQ variants | EQ capability sub-type `00` / `02` / `03` / `04` |
| `6B` | noise control, dual | noise sub-type `17` (**WH-1000XM5**) |
| `6D` | noise control with noise adaptation | noise sub-type `19` (**WH-1000XM6**) |
| `68` | noise control, auto NC | noise sub-type `15` |
| `E2` | upscaling (DSEE) | `E6 01` / `E8 01` |
| `F1` | pause when taken off | `F6 01` / `F8 01` |
| `FC` | Speak-to-Chat | `F6 0C`, `FA 0C` |

## 7. Command reference

### Noise control

| | Bytes |
|---|---|
| Get | `66 19` (XM6) · `66 17` (XM5) |
| Reply / notify | `67`/`69` `19` *chg* *on* *mode* *voice* *level* *auto* *sens* |
| Set | `68 19` *chg* *on* *mode* *voice* *level* *auto* *sens* |

- *chg*: `00` while the user is still dragging the level slider, `01` once settled
- *on*: `00` = noise control off, `01` = on
- *mode*: `00` = noise cancelling, `01` = ambient sound
- *voice*: Focus on Voice, `00`/`01`
- *level*: ambient level `01`–`14` (1–20)
- *auto*, *sens*: XM6 only. Auto Ambient Sound `00`/`01`, and its sensitivity `00` standard, `01` high, `02` low

The XM5 (sub-type `17`) uses the same layout without the last two bytes. Examples for the XM6:

```
68 19 01 01 00 00 14 00 00    noise cancelling
68 19 01 01 01 01 0C 00 00    ambient, level 12, Focus on Voice
68 19 01 00 01 00 14 00 00    off
```

### Equalizer

| | Bytes |
|---|---|
| Capability | `50 00 01` → `51 00` *bands* *steps* *count* { *id* *len* *name…* } |
| Available? | `52 00` → `53 00` *`00` yes / `01` no* |
| Get | `56 00` → `57 00` *preset* *n* *values…* |
| Select preset | `58 00` *preset* `00` |
| Custom bands | `58 00` *preset* *n* *values…* |

Band values are sent as unsigned numbers offset by the top of the range:

- **WH-1000XM6**: *n* = 10 (31, 63, 125, 250, 500, 1k, 2k, 4k, 8k, 16k Hz), range −6…+6, sent as value + 6.
  Flat is `58 00 A0 0A 06 06 06 06 06 06 06 06 06 06`.
- **WH-1000XM5**: *n* = 6: Clear Bass then 400, 1k, 2.5k, 6.3k, 16k Hz; range −10…+10, sent as value + 10.

Preset ids: `00` Off, `10`–`17` Bright, Excited, Mellow, Relaxed, Vocal, Treble Boost, Bass Boost, Speech (XM5),
`20` Gaming, `30`–`33` Heavy, Clear, Hard, Soft (XM6), `A0` Custom, `A1`–`A5` User Setting 1–5.

### Other settings

| Setting | Get → reply | Set |
|---|---|---|
| DSEE Extreme | `E6 01` → `E7 01` *`00` off / `01` auto* | `E8 01 00`/`01` |
| Speak-to-Chat | `F6 0C` → `F7 0C` *on* *preview* | `F8 0C` *`00` on / `01` off* `01` |
| Speak-to-Chat options | `FA 0C` → `FB 0C` *sens* *time* | `FC 0C` *sens* *time* |
| Pause when taken off | `F6 01` → `F7 01` *`00` on / `01` off* | `F8 01 00`/`01` |
| Auto power off | `26 05` → `27 05` *setting* *last timer* | `28 05` *setting* *last timer* |
| Battery | `22 00` → `23 00` *level* *charging* | |
| Codec | `12 02` → `13 02` *codec* | |
| Turn off | | `24 03 01` |

- Speak-to-Chat sensitivity: `00` auto, `01` high, `02` low. Timeout: `00` short, `01` standard, `02` long,
  `03` never.
- Auto power off: `00` 5 min, `01` 30 min, `02` 1 h, `03` 3 h, `10` when taken off, `11` never. *last timer* is
  the timer to fall back to; send the setting itself for timer values and `00` otherwise.
- Charging: `00` no, `01` charging, `03` fully charged.
- Codec: `01` SBC, `02` AAC, `10` LDAC, `20` aptX, `21` aptX HD, `30` LC3.

## 8. Adding a feature to XMBridge

1. Find the bytes. A debug build logs every frame (`CONFIG=debug scripts/build-app.sh`, then filter Console.app for
   `[mdr]`). Press buttons on the headphones to see their notifications. The libmdr headers in
   mos9527/SonyHeadphonesClient (`ProtocolV2T1.hpp`) describe hundreds more messages.
2. Add the support function id to `Feature` and a request builder to `Request` in `Protocol.swift`.
3. Parse the reply in `HeadphoneState.apply` (`State.swift`) and add it to `initialQueries`.
4. Add a unit test with the real bytes in `Tests/MDRKitTests`.
5. Add a setter to `HeadphoneController` and a control to the views. `--demo xm6` shows the UI without headphones.
