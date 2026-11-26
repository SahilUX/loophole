"""Ring BLE protocol: UUIDs, opcodes and pure byte parsers (no Bluetooth code here).

notes/protocol.md says how well each fact is checked. Error text never includes the bytes: a frame can hold a hardware ID.
"""
from __future__ import annotations

import calendar
import math
import struct
import time
from dataclasses import dataclass

BASE = "-f706-58a0-95b2-1fb9261e4dc7"
STATE_CHAR = "86f61001" + BASE  # read+notify: 76-byte battery/state record, pushed now and then
CMD_CHAR = "86f65001" + BASE  # write: commands; use Write Requests
RESP_CHAR = "86f65002" + BASE  # notify: command replies
AUX_CHAR = "86f63001" + BASE  # read+notify: four bytes, perhaps sensor bus addresses
STREAM_CHAR = "86f66001" + BASE  # notify: raw PPG/accelerometer frames, live HR and breathing samples
SMP_SERVICE = "8d53dc1d-1db7-4cd3-868b-8a527460aa84"  # MCUmgr firmware update. Never used.

OP_HISTORY = 0x04
OP_CLOCK = 0x05
OP_OLDEST_RECORD = 0x07
OP_NEWEST_RECORD = 0x08
OP_RECORD_RANGE = 0x09
OP_EVENT_LOG = 0x0F
OP_CLOCK_MANAGEMENT = 0x10  # never sent; only known so its replies check
OP_RECORD_INTERVAL = 0x14  # only the read form `14 01` is allowed
OP_STATUS_FLAGS = 0x20
OP_LIVE_HR_START = 0x52
OP_LIVE_HR_STOP = 0x53
OP_SENSOR_MODE = 0x59
OP_BREATHING_START, OP_BREATHING_STOP = 0x72, 0x74
OP_DEBUG_PAGE = 0x79  # `79 29 07 <u16 page>`
OP_CONFIG_PAGE = 0x80  # `80 <page>`
OP_RAW_PPG_START = 0x90  # tag/length/value settings follow
OP_RAW_PPG_STOP = 0x91
OP_WEAR_LOG = 0x9A  # CRC-framed both ways
OP_FAULT_LOG = 0xA1
OP_SPO2_ON, OP_SPO2_OFF = 0xD1, 0xD2
OP_CRITICAL_ON, OP_CRITICAL_OFF = 0xD3, 0xD4
OP_CHILL_ON, OP_CHILL_OFF = 0xFB, 0xFC

# Commands that are one byte and nothing else. Never sent: 0x70 airplane (radio off until charged), 0x98 reset
# (wipes data), anything unidentified, and the SMP firmware service.
ONE_BYTE_COMMANDS = frozenset({OP_CLOCK, OP_OLDEST_RECORD, OP_NEWEST_RECORD, OP_RECORD_RANGE, OP_STATUS_FLAGS,
                               OP_LIVE_HR_START, OP_LIVE_HR_STOP, OP_SENSOR_MODE, OP_BREATHING_START,
                               OP_BREATHING_STOP, OP_RAW_PPG_STOP, OP_FAULT_LOG, OP_SPO2_ON, OP_SPO2_OFF,
                               OP_CRITICAL_ON, OP_CRITICAL_OFF, OP_CHILL_ON, OP_CHILL_OFF})

PPG_RATE_HZ = 25.0


def ppg_start_packet() -> bytes:
    """Raw PPG at 25 Hz: tag, length, value settings, the ones seen in my own phone log. Only tag 8, the finger
    threshold (big-endian), is understood."""
    settings = (
        (1, bytes([4])),  # probably the sample-rate index for 25 Hz
        (4, bytes([2])),
        (5, bytes([1])),
        (6, bytes([51, 102, 102, 0, 0, 0])),  # probably LED drive levels
        (7, bytes([3])),  # probably the accelerometer range
        (8, (9000).to_bytes(2, "big")),
    )
    return bytes([OP_RAW_PPG_START]) + b"".join(bytes([tag, len(v)]) + v for tag, v in settings)


RESULT_OK, RESULT_NO_DATA = 0x00, 0xEE


class ProtocolError(ValueError):
    pass


@dataclass(frozen=True)
class Reply:
    opcode: int
    result: int
    detail: int
    data: bytes  # everything after the 3-byte header, trailing bytes included

    @property
    def ok(self) -> bool:
        return self.result == RESULT_OK


def parse_reply(raw: bytes) -> Reply:
    if len(raw) < 3:
        raise ProtocolError(f"a reply needs 3 header bytes, got {len(raw)}")
    return Reply(raw[0], raw[1], raw[2], bytes(raw[3:]))


def _expect(raw: bytes, *opcodes: int) -> Reply:
    r = parse_reply(raw)
    if r.opcode not in opcodes:
        raise ProtocolError(f"got opcode 0x{r.opcode:02x} where another was expected")
    return r


def _need(data: bytes, size: int, what: str) -> None:
    if len(data) < size:
        raise ProtocolError(f"{what}: {len(data)} of {size} bytes")


def parse_time(raw: bytes) -> int:
    """`05 00 01 <u32 unix time> <crc>` -> unix seconds."""
    r = _expect(raw, OP_CLOCK)
    if not r.ok:
        raise ProtocolError(f"clock request refused: 0x{r.result:02x}")
    _need(r.data, 4, "clock reply")
    return _u32(r.data, 0)


def parse_index(raw: bytes) -> int | None:
    """`07|08 00 01 <u16 index> <crc>` -> record index, None if the ring has no data."""
    r = _expect(raw, OP_OLDEST_RECORD, OP_NEWEST_RECORD)
    if r.result == RESULT_NO_DATA:
        return None
    if not r.ok:
        raise ProtocolError(f"index request refused: 0x{r.result:02x}")
    _need(r.data, 2, "index reply")
    return _u16(r.data, 0)


@dataclass(frozen=True)
class Recording:
    """One 32-byte history record, little-endian. Offsets: notes/protocol.md. Bytes 28 and 29 are kept raw because the
    sources disagree about them."""
    index: int
    timestamp: int
    heart_rate: int  # BPM, 0 = not measured
    rmssd_ms: int
    spo2: int  # %; a value over 100 means no reading (seen with SpO2 sensing off)
    pulse_confidence: int
    temp_time: int
    skin_temp_c: float | None  # NaN -> None
    second_temp_c: float | None  # equal to skin_temp_c in every record I have
    motion_time: int
    activity: int
    steps: int
    byte_28: int
    byte_29: int


def _celsius(v: float) -> float | None:
    return None if math.isnan(v) else round(v, 2)


def parse_recordings(raw: bytes) -> list[Recording]:
    """`04 <result> <count> <count x 32-byte records> <crc>`; results ee and 13 mean none and end."""
    r = _expect(raw, OP_HISTORY)
    if not r.ok:
        return []
    _need(r.data, r.detail * 32, "history page")
    out = []
    for i in range(r.detail):
        ts, hr, rmssd, spo2, conf, t_ts, skin, second, m_ts, act, steps, b28, b29, idx = struct.unpack_from(
            "<IBBBBIffIHHBBH", r.data, i * 32)
        out.append(Recording(idx, ts, hr, rmssd, spo2, conf, t_ts, _celsius(skin), _celsius(second), m_ts, act, steps,
                             b28, b29))
    return out


@dataclass(frozen=True)
class State:
    """76-byte record pushed on STATE_CHAR. Note the mixed byte order."""
    battery_pct: int  # [0]
    microamps: int  # [1..4] i32 LE, + charging / - discharging
    charge_state: int  # [5] 0 not charging, 3 charging
    temp_c: int  # [6]
    millivolts: int | None  # [7..8] big-endian
    charge_stage: int | None  # [9] charger stage, raw
    contact: int | None  # [10] charger contact, raw
    cell_mah: int | None  # [15..16] BE
    minutes_left: int | None  # [17..18] BE
    minutes_to_full: int | None  # [19..20] BE
    cycles: float | None  # [21..22] BE / 100
    timestamp: int | None  # [29..32] u32 LE


def parse_state(raw: bytes) -> State:
    if len(raw) < 7 or not any(raw):
        raise ProtocolError("the state record is empty or cut off")

    def be(o: int) -> int | None:
        return int.from_bytes(raw[o:o + 2], "big") if len(raw) >= o + 2 else None

    cyc = be(21)
    return State(raw[0], struct.unpack_from("<i", raw, 1)[0], raw[5], raw[6], be(7),
                 raw[9] if len(raw) > 9 else None, raw[10] if len(raw) > 10 else None, be(15), be(17), be(19),
                 cyc / 100 if cyc is not None else None,
                 (struct.unpack_from("<I", raw, 29)[0] or None) if len(raw) >= 33 else None)


@dataclass(frozen=True)
class PpgFrame:
    tick_ms: int  # ring uptime in ms at the frame (inferred: last sample)
    samples: tuple[tuple[int, int, int], ...]  # 12 x (ch0, ch1, ch2); which LED is which is unknown


def parse_ppg_frame(raw: bytes) -> PpgFrame | None:
    """161-byte frames: `90 <u16 len> 08 08 <u32 tick> <6 bytes>` header, 12 x 3 x u32, 2 trailing bytes.

    Returns None for other frame types on the same characteristic (accelerometer, 89-95 bytes).
    Consecutive ticks are ~500 ms apart, which fits 12 samples at 25 Hz.
    """
    if len(raw) != 161 or raw[0] != 0x90:
        return None
    tick = struct.unpack_from("<I", raw, 5)[0]
    samples = tuple(struct.unpack_from("<III", raw, 15 + i * 12) for i in range(12))
    return PpgFrame(tick, samples)


@dataclass(frozen=True)
class LiveHr:
    """Ring-computed live sample."""
    timestamp: int
    hr: int
    pulse_confidence: int
    rmssd_ms: int
    byte_7: int  # SpO2 in the same place as a history record's, or something else: unknown
    steps: int
    skin_temp_c: float | None


def _stream_payload(raw: bytes, opcode: int, size: int) -> bytes:
    """`<opcode> <u16 length> <payload> <crc>` on the stream characteristic -> payload."""
    _need(raw, 3, "stream frame")
    if raw[0] != opcode:
        raise ProtocolError(f"got opcode 0x{raw[0]:02x} where another was expected")
    payload = raw[3:3 + _u16(raw, 1)]
    _need(payload, size, "stream payload")
    return payload


_LIVE = struct.Struct("<IBBBBHf")
_BREATH = struct.Struct("<IBBBBf")


def parse_live_hr(raw: bytes) -> LiveHr:
    """Payload: time, heart rate, confidence, RMSSD, one unknown byte, steps u16, skin temperature f32."""
    ts, hr, conf, rmssd, b7, steps, temp = _LIVE.unpack_from(_stream_payload(raw, OP_LIVE_HR_START, _LIVE.size))
    return LiveHr(ts, hr, conf, rmssd, b7, steps, _celsius(temp))


@dataclass(frozen=True)
class Breath:
    """Breathing-mode sample. The rest of the 22-byte payload stayed zero in all my samples, so it isn't decoded."""
    timestamp: int
    hr: int
    pulse_confidence: int
    rmssd_ms: int
    sdnn_ms: int
    skin_temp_c: float | None


def parse_breath(raw: bytes) -> Breath:
    """Payload: time, heart rate, confidence, RMSSD, SDNN, skin temperature f32, then undecoded bytes."""
    ts, hr, conf, rmssd, sdnn, temp = _BREATH.unpack_from(_stream_payload(raw, OP_BREATHING_START, _BREATH.size))
    return Breath(ts, hr, conf, rmssd, sdnn, _celsius(temp))


# --- framing ---------------------------------------------------------------------------------------------
def crc16(data: bytes, init: int = 0xFFFF) -> int:
    """CRC-16/CCITT-FALSE (poly 0x1021, init 0xFFFF). What it covers: crc_ok."""
    c = init
    for b in data:
        c ^= b << 8
        for _ in range(8):
            c = ((c << 1) ^ 0x1021) & 0xFFFF if c & 0x8000 else (c << 1) & 0xFFFF
    return c


# Replies that repeat a two-byte sub-command (or page number) before the payload.
SUB_COMMAND_REPLIES = frozenset({OP_EVENT_LOG, OP_CLOCK_MANAGEMENT, OP_RECORD_INTERVAL, OP_DEBUG_PAGE})


def crc_ok(raw: bytes) -> bool:
    """CRC covers the payload: bytes 5.. for SUB_COMMAND_REPLIES, bytes 3.. for everything else."""
    start = 5 if raw[:1] and raw[0] in SUB_COMMAND_REPLIES else 3
    return len(raw) >= start + 2 and crc16(raw[start:-2]) == int.from_bytes(raw[-2:], "little")


# One-byte commands plus the ones with arguments: the only opcodes the recent-commands page names.
KNOWN_OPCODES = ONE_BYTE_COMMANDS | {OP_HISTORY, OP_EVENT_LOG, OP_RECORD_INTERVAL, OP_DEBUG_PAGE, OP_CONFIG_PAGE,
                                     OP_RAW_PPG_START, OP_WEAR_LOG}

# --- read-only queries ----------------------------------------------------------------------------------
DEBUG_PAGES = {0: "summary", 4: "power", 13: "link", 14: "recent_commands", 15: "sensor_addresses", 28: "bonds",
               29: "page_29", 30: "versions"}
EVENTS_INFO = b"\x0f\x01"
STREAM_REPLY_OPS = {OP_WEAR_LOG, OP_FAULT_LOG}  # these answer on STREAM_CHAR, not on RESP_CHAR


def events_request(start: int = 0) -> bytes:
    """0x0F 04 <u16 start>: event log pages from `start`; the ring ends with `0f ff ..`."""
    return bytes([OP_EVENT_LOG, 0x04]) + start.to_bytes(2, "little")


def _framed(op: int, payload: bytes) -> bytes:
    return bytes([op]) + len(payload).to_bytes(2, "little") + payload + crc16(payload).to_bytes(2, "little")


WEAR_LOG_REQUESTS = {"latest": _framed(OP_WEAR_LOG, b""), "off_finger": _framed(OP_WEAR_LOG, b"\x01"),
                     "on_finger": _framed(OP_WEAR_LOG, b"\x02")}


def debug_page_request(page: int) -> bytes:
    return bytes([OP_DEBUG_PAGE, 0x29, 0x07]) + page.to_bytes(2, "little")


def is_allowed(packet: bytes) -> bool:
    """Every command has one exact shape; the opcode alone is never enough."""
    if not packet:
        return False
    op, rest = packet[0], packet[1:]
    if op in ONE_BYTE_COMMANDS:
        return not rest
    if op == OP_HISTORY:
        return len(rest) == 2
    if op == OP_RAW_PPG_START:
        return packet == ppg_start_packet()
    if op == OP_EVENT_LOG:
        return rest == b"\x01" or (len(rest) == 3 and rest[0] == 0x04)
    if op == OP_RECORD_INTERVAL:
        return rest == b"\x01"
    if op == OP_DEBUG_PAGE:
        return len(rest) == 4 and rest[:2] == b"\x29\x07" and int.from_bytes(rest[2:], "little") in DEBUG_PAGES
    if op == OP_CONFIG_PAGE:
        return len(rest) == 1 and rest[0] in CONFIG_PAGES
    return op == OP_WEAR_LOG and packet in WEAR_LOG_REQUESTS.values()


def _u16(b: bytes, o: int) -> int:
    return int.from_bytes(b[o:o + 2], "little")


def _u32(b: bytes, o: int) -> int:
    return int.from_bytes(b[o:o + 4], "little")


def parse_mode(raw: bytes) -> dict:
    r = parse_reply(raw)
    return {"ok": r.ok and r.detail > 0, "mode": r.data[0] if r.data else None}


def parse_status_flags(raw: bytes) -> dict:
    """0x20 reply, raw u8 flags. Meanings are not checked against the ring."""
    if not _expect(raw, OP_STATUS_FLAGS).ok:
        raise ProtocolError("status flags refused")
    _need(raw, 19, "status flags")
    return {"spo2_on": raw[18], "critical_on": raw[14], "critical_from_low_battery": raw[15],
            "chill_running": raw[12], "chill_on": raw[13]}


def parse_interval(raw: bytes) -> dict:
    if not _expect(raw, OP_RECORD_INTERVAL).ok:
        raise ProtocolError("record interval refused")
    _need(raw, 6, "record interval")
    return {"minutes": raw[5]}


def parse_debug_page(raw: bytes) -> dict:
    """`79 <status> <x> <u16 page> <payload> <crc>`. Only a few fields are named.
    Identifiers (the chip ID on page 30, the bonded addresses on page 28) are left out on purpose."""
    _expect(raw, OP_DEBUG_PAGE)
    _need(raw, 7, "debug page")
    page, P = _u16(raw, 3), raw[5:-2]
    out: dict = {"page": page, "name": DEBUG_PAGES.get(page, "?"), "status": raw[1], "crc_ok": crc_ok(raw)}
    if raw[1] != 0 or P == b"\xff":
        out["supported"] = False
        return out
    if not out["crc_ok"]:
        return out
    if page == 0 and len(P) >= 44:
        out.update(newest_record=_u16(P, 12), oldest_record=_u16(P, 14), record_limit=_u16(P, 16),
                   clock=_u32(P, 20), steps=_u16(P, 24), steps_total=_u32(P, 28), battery_pct=P[40],
                   restarts=_u16(P, 42))
    elif page == 4 and len(P) >= 31:
        out.update(battery_pct=P[0], microamps=int.from_bytes(P[1:5], "little", signed=True), millivolts=_u16(P, 5),
                   cell_mah=_u16(P, 10), charge_state=P[17], temp_c=P[18], cycles=_u16(P, 25))
    elif page == 15 and len(P) >= 4:  # perhaps sensor bus addresses
        out.update(temperature=hex(P[0]), motion=hex(P[1]), fuel_gauge=hex(P[2]), optical=hex(P[3]))
    elif page == 14:  # opcodes the ring received recently, oldest first
        out["recent_opcodes"] = [f"{b:02x}" if b in KNOWN_OPCODES else "other" for b in P.rstrip(b"\x00")]
    elif page == 30 and len(P) >= 36:
        out["firmware"] = hex(_u32(P, 20))
    elif page == 13 and len(P) >= 99:
        out.update(last_drop_code=P[7], connects=_u32(P, 89), disconnects=_u32(P, 93))
    elif page == 28 and len(P) >= 81:
        out["bonded_count"] = sum(any(P[i * 8 + 3:i * 8 + 9]) for i in range(10))
    else:
        out["payload_len"] = len(P)
    return out


def parse_record_range(raw: bytes) -> dict:
    """0x09: `09 00 01 <u16 newest> <u16 oldest> <u16 newest> <crc>`."""
    r = _expect(raw, OP_RECORD_RANGE)
    _need(r.data, 8, "record range")
    return {"ok": r.ok, "crc_ok": crc_ok(raw), "oldest": _u16(r.data, 2), "newest": _u16(r.data, 4)}


def parse_stream_reply(raw: bytes) -> dict:
    """Wear-log and fault-log replies: `op <u16 len> payload <crc>`. Contents aren't decoded, so only the size."""
    _need(raw, 5, "stream frame")
    n = _u16(raw, 1)
    payload = raw[3:3 + n]
    return {"len": n, "crc_ok": len(raw) >= 5 + n and crc16(payload) == _u16(raw, 3 + n)}


# Event codes this project shows. Where the meanings come from: notes/protocol.md.
EVENT_LABELS = {
    23: "Daily restart", 26: "Restarted after hanging", 32: "Ring powered on", 36: "Firmware updated",
    38: "Power dipped", 40: "Restarted after hanging", 49: "Paired with a phone", 79: "Low-power mode on",
    80: "Low-power mode off", 81: "Chill mode on", 82: "Chill mode off", 83: "Charging", 84: "Battery down 10%",
    85: "Battery up 10%", 86: "Battery critically low", 87: "SpO2 sensing on", 88: "SpO2 sensing off",
    89: "Pairing changed", 97: "Factory reset", 98: "Firmware updated", 103: "Firmware updated",
    104: "Firmware updated",
}
EVENTS_BASE_EPOCH = calendar.timegm((2026, 1, 1, 0, 0, 0))


@dataclass(frozen=True)
class LogEntry:
    name: str
    code: int | None  # None for an epoch anchor
    time: int  # unix seconds
    valid: bool


def event_name(code: int) -> str:
    return EVENT_LABELS.get(code, f"Event {code}")


def decode_events(pages: list[bytes]) -> list[LogEntry]:
    """0x0F 04 pages -> events. Each u32 LE word: bit 31 = event (1) or epoch anchor (0), bit 30 = valid.
    Anchor: bits 0-29 = seconds since 2026-01-01 UTC. Event: bits 22-29 = code, bits 0-21 = seconds after the
    latest valid anchor."""
    data = b"".join(pg[5:-2] for pg in pages if len(pg) > 7 and pg[1] == 0)
    anchor: int | None = None
    out = []
    for i in range(0, len(data) - 3, 4):
        w = _u32(data, i)
        valid = bool(w >> 30 & 1)
        if not w >> 31:
            t = (w & 0x3FFFFFFF) + EVENTS_BASE_EPOCH
            if valid:
                anchor = t
            out.append(LogEntry("epoch_anchor", None, t, valid))
        else:
            code = (w >> 22) & 0xFF
            out.append(LogEntry(event_name(code), code, (anchor or EVENTS_BASE_EPOCH) + (w & 0x3FFFFF),
                                 valid and anchor is not None))
    return out


def parse_events(pages: list[bytes]) -> dict:
    events = decode_events(pages)
    counts: dict[str, int] = {}
    for e in events:
        counts[e.name] = counts.get(e.name, 0) + 1
    return {"pages": sum(1 for pg in pages if pg[1] == 0), "events": len(events), "counts": counts,
            "latest": [{"name": e.name, "utc": time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime(e.time))}
                       for e in events[-10:]]}


def parse_events_info(raw: bytes) -> dict:
    """0x0F 01: entry counts of the ring's two event buffers."""
    r = _expect(raw, OP_EVENT_LOG)
    if not r.ok:
        raise ProtocolError("event counts refused")
    _need(r.data, 16, "event counts")
    b = raw[-14:-2]
    return {"count_a": _u16(b, 8), "count_b": _u16(b, 10)}


CONFIG_FIELDS = {  # page -> (offset, name, size) inside the 32-byte section; only a few settings, not checked
    2: [(3, "chill_on", 1), (5, "spo2_on", 1), (12, "record_minutes", 1)],
    3: [(3, "accel_range_g", 1), (4, "accel_hz", 2)],
    4: [(2, "ppg_hz", 2), (10, "finger_threshold", 2), (13, "green_on", 1), (14, "ir_on", 1), (15, "red_on", 1)],
}
CONFIG_PAGES = {2: "modes", 3: "motion", 4: "optical", 5: "page_5", 6: "page_6"}


def parse_config(raw: bytes, page: int | None = None) -> dict:
    """0x80 <page>: one 32-byte section; valid when it starts with the bytes `07 29`. No fields unless the CRC fits."""
    if not _expect(raw, OP_CONFIG_PAGE).ok:
        raise ProtocolError("config page refused")
    _need(raw, 37, "config page")
    sec = raw[3:35]
    out: dict = {"page": CONFIG_PAGES.get(page, page), "valid": sec[:2] == b"\x07\x29"}
    if out["valid"] and crc_ok(raw):
        for off, name, size in CONFIG_FIELDS.get(page or 0, []):
            out[name] = sec[off] if size == 1 else _u16(sec, off)
    return out
