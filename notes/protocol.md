# Ring Bluetooth protocol

What Loophole relies on. I worked it out with one Ultrahuman Ring AIR, in late October 2026, so other rings and firmware may differ. The repository holds none of the captured data, apart from protocol constants such as the raw PPG start settings.

## How sure each fact is

Each table says what a fact rests on:

- **GB**: documented by [Gadgetbridge](https://gadgetbridge.org/internals/specifics/ultrahuman-protocol/) or in its code, for older firmware. See [Credit](../README.md#credit).
- **Log**: in a private Bluetooth log I still have, either the official app talking to my ring or my Mac doing so.
- **Mac**: the part of those logs where my own code sent the command and the ring answered.
- **Not kept**: I noted it while building and have nothing left to show for it.
- **Not checked**: what the field means hasn't been checked against the ring.
- **Inferred**: my reading.

A layout that my logs fit is still not proof of what each field means. I wrote the decoders, field names and labels myself, though plain words such as "heart rate" or "steps" are bound to match.

## Services

| Characteristic | Use | Source |
| --- | --- | --- |
| `180a` / `2a25` | Standard Device Information, serial number | Log, GB |
| `86f61001-f706-58a0-95b2-1fb9261e4dc7` | Battery and charging state, read and notify | Log, GB |
| `86f65001-…` | Commands, write | Log, GB |
| `86f65002-…` | Command replies, notify | Log, GB |
| `86f66001-…` | Streams: raw PPG, live heart rate, breathing, plus replies to `9a` and `a1` | Log, GB (UUID) |
| `86f63001-…` | Four sensor bus addresses | Log, GB (UUID); meaning not checked |
| `8d53dc1d-1db7-4cd3-868b-8a527460aa84` | MCUmgr firmware update. **Never touched.** | Log |

The ring advertises as `UH_` plus 12 hex digits (GB, Log), and on mine they are its hardware address (Log). Loophole sends Write Requests. That Write Commands are ignored unless the ring is bonded is Not kept.

## Framing

- Byte 0 is the opcode. Integers are little-endian unless noted. Times are Unix seconds (GB, Log).
- Replies: `opcode result detail payload crc`. Result `00` is success, `ee` no data, `ff` failure (GB); `13` ends history (Log). One other history reply, with result `0f`, appears 20 times across 9 of my logs; its meaning is unknown.
- Stream frames: `opcode <u16 length> payload crc` (Log).
- The CRC is CRC-16/CCITT-FALSE, little-endian, over the payload, which starts at byte 3. In replies to `79`, `0f`, `10` and `14` the header repeats a two-byte page or sub-command, so the payload starts at byte 5. With that, every reply and stream frame in my logs checks (Log). GB guessed a checksum.

## Commands Loophole sends

| Bytes | What it does | Source |
| --- | --- | --- |
| `04 <u16 index>` | History from that record on, up to seven records a reply | GB, Log |
| `05` | Ring clock | GB, Log |
| `07` / `08` | Oldest / newest record index | GB. No frames kept; the Android app's sync depends on them |
| `09` | Oldest and newest record index in one reply | Log, Mac |
| `0f 01`, `0f 04 <u16 start>` | Event log counts, event log pages | Log, Mac |
| `14 01` | Minutes between history records | Log |
| `20` | Status flags | Log, Mac |
| `52` / `53` | Live heart rate on / off | Log, Mac. Refused in Critical mode: Not kept |
| `59` | One byte, perhaps the current sensor mode | GB (as a check for new data), Log. Meaning open |
| `72` / `74` | Breathing mode on / off | GB, Mac |
| `79 29 07 <u16 page>` | Debug page | Log; pages 14, 15 and 29 Mac |
| `80 <page 2..6>` | Config page | Log |
| `90 …` / `91` | Raw PPG on / off | Log. From my own code: Not kept |
| `9a …` | Wear log | Log, Mac. Contents not decoded |
| `a1` | Fault log | Log, Mac. Contents not decoded |
| `d1` / `d2` | SpO2 sensing on / off | GB code (its docs page calls them power saving off / on instead). My own test: Not kept |
| `d3` / `d4` | Critical mode on / off | Log |
| `fb` / `fc` | Chill mode on / off | Log |

Battery modes are pairs: Turbo is `d4` then `fc`, Chill is `d4` then `fb`, Critical is `d3` (Log, from switching modes in the official app).

Loophole sends `74` and `91` again after reconnecting if a stop wasn't acknowledged. It does so to be safe: what the ring does when the link drops is Not kept.

### Never sent

Setting the clock (`02`, GB), the sleep window (`0a`), clock management (`10`), airplane mode (`70`, GB), reset (`98`, GB), firmware update (`f0` and the MCUmgr service), removing bonds (`bf`), and anything I couldn't identify.

## History record, 32 bytes

| Bytes | Field | Source |
| --- | --- | --- |
| 0-3 | time | GB, Log |
| 4 | heart rate, 0 when not measured | GB, Log |
| 5 | HRV, 0 when not measured | GB. That it is RMSSD in ms: not checked |
| 6 | SpO2 % | GB. In all my records it is 0 or over 100, never a reading. Sensing was off in every Bluetooth log I have |
| 7 | pulse confidence | Not checked. GB: kind of measurement |
| 8-11 | time of the temperature reading | GB, Log |
| 12-15 | skin temperature, f32 °C, 0.0 in some unworn records | GB (highest), Log |
| 16-19 | second temperature, f32 °C | GB: lowest skin temperature; it could also be ambient. It equals the first in every record I have, which fits GB better. Unresolved, not used |
| 20-23 | time of the motion reading | GB, Log |
| 24-25 | activity | GB |
| 26-27 | steps since the last record | GB |
| 28, 29 | kept raw | GB: one stress value. They could also be SDNN and a breathing rate, but byte 29 was never a plausible rate in my records. Unresolved, not used |
| 30-31 | record index | GB, Log |

What counts as a real reading is decided in `app/lib/ring/protocol.dart`, with the reason for each limit next to it. Off the finger the ring usually repeats its last HRV value (Log: 76 of the 85 unworn records that hold one).

## Live samples

My logs fit both layouts (Log, Mac). What each field means is not checked beyond that.

- Live heart rate, 14 bytes: time u32, heart rate, pulse confidence, RMSSD, one byte I don't understand, steps u16, skin temperature f32.
- Breathing, 22 bytes: time u32, heart rate, pulse confidence, RMSSD, SDNN, skin temperature f32. The other ten bytes stayed zero in my logs, so they aren't decoded.

## Battery state, 76 bytes

| Bytes | Field | Source |
| --- | --- | --- |
| 0 | battery % | GB, Log |
| 1-4 | current in µA, signed, positive while charging | Log |
| 5 | 3 while charging, 0 otherwise | GB, Log |
| 6 | temperature °C | GB, Log |
| 7-8 | millivolts, big-endian | Log |
| 9, 10 | charger stage, charger contact, kept raw | Not checked |
| 15-16 | capacity in mAh, big-endian | Log |
| 17-18, 19-20 | minutes to empty, minutes to full, big-endian; zero in my logs | Not checked |
| 21-22 | charge cycles x 100, big-endian | Not checked |
| 29-32 | time | Log |

Percentage, current and capacity agree with debug page 4 (Log).

## Raw PPG frame, 161 bytes

`90`, u16 length, `08 08`, u32 milliseconds, 6 bytes, then 12 samples of three u32 channels, then 2 bytes. I worked this out from my own log of the official app recording. Frames come about every 500 ms (Log), which fits 12 samples at 25 Hz. Which channel is which LED is unknown. The settings sent to start it (`ppg_start_packet` in `loophole_ring/protocol.py`) are the ones in that log, and only the finger threshold is understood.

## Status flags (`20`)

The reply is in my logs, with byte 18 always 0, byte 13 both ways and byte 14 always 0. Byte 18 SpO2 on, 13 Chill on, 14 Critical on, 15 Critical because the battery is low, 12 Chill running; not checked. That 13 and 18 follow the commands is Not kept.

## Event log (`0f 04`)

A run of u32 words. Bit 31 set means an event, clear means a time mark; bit 30 means valid. A time mark holds seconds since 2026-01-01 UTC in bits 0-29. An event holds its code in bits 22-29, and in bits 0-21 the seconds after the last valid time mark. My log decodes to sensible dates with this format and the 2026 start.

Loophole only names the codes it shows, in its own words. Everything else is "Event" and the number. What each label means is not checked. What my log shows:

| Code | Label | In my log |
| --- | --- | --- |
| 23 | Daily restart | Yes, and nearly always about a day apart |
| 32, 86 | Ring powered on, battery critically low | Yes, several times |
| 81, 89, 97, 98 | See `friendlyEvent` | Yes, meaning not checked |
| 90 | No label | Yes, often three hours apart |
| 2, 5, 6, 28, 110, 112 | No label | Yes |
| Every other labelled code | See `friendlyEvent` | No |

## Debug pages (`79`) and config pages (`80`)

Replies are in my logs; what the fields mean is not checked. Debug pages: 0 summary, 4 power, 13 link counters, 14 recent commands, 15 sensor addresses, 28 bonds, 30 versions. Page 30 starts with the chip's unique ID and page 28 holds paired addresses. The parsers drop both and decode nothing when the CRC is wrong. Error messages never include the bytes. The dashboard shows raw bytes only for whole `05`, `07`, `08`, `09` and `14` replies, the first three bytes of an acknowledgement, and the decoded parts of the battery state.

Config pages are valid when they start with `07 29`. Page 2 holds modes, 3 the motion sensor, 4 the optical sensor.

## Serial number

Dash-separated. One segment looks like two letters for the finish plus two digits, most likely the size (inferred from one ring). Loophole shows the code as it is and has no table of finish names.

## Open questions

- Bytes 16 to 19, 28 and 29 of the history record: Gadgetbridge's reading or another?
- What SpO2 looks like with sensing on.
- The wear log and fault log contents.
- What `59` returns, and byte 7 of a live sample.
