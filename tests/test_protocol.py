"""Decoder tests. Every frame is built here from invented numbers (frames.py); none comes from a ring."""
import math
import random
import unittest

from frames import FAKE_TIME, crc, debug_page, f32, frame, i32, layout, reply, stream, u16, u32
from loophole_ring import protocol as p
from loophole_ring.hr import estimate_series, resample


def record(index: int, **over: int | float) -> bytes:
    v = {"hr": 111, "rmssd": 22, "spo2": 99, "quality": 3, "skin": 30.5, "ambient": 20.25, "activity": 777,
         "steps": 4321, "b28": 33, "b29": 12} | over
    return layout(32, {0: u32(FAKE_TIME + index), 4: v["hr"], 5: v["rmssd"], 6: v["spo2"], 7: v["quality"],
                       8: u32(FAKE_TIME + index + 1), 12: f32(v["skin"]), 16: f32(v["ambient"]),
                       20: u32(FAKE_TIME + index + 2), 24: u16(v["activity"]), 26: u16(v["steps"]), 28: v["b28"],
                       29: v["b29"], 30: u16(index)})


class Crc(unittest.TestCase):
    def test_published_check_value(self):
        self.assertEqual(p.crc16(b"123456789"), 0x29B1)  # public-ok: published CRC check string

    def test_every_frame_kind(self):
        for raw in (reply(0x05, u32(FAKE_TIME)), reply(0xD3, b"\x07"), stream(0x52, bytes(range(14))),
                    debug_page(15, bytes(range(24))), frame(b"\x14\x00\x01\x01\x00", b"\x11"),
                    frame(b"\x10\x00\x01\x02\x00", bytes(range(25))), frame(b"\x0f\x00\x01\x04\x00", bytes(range(8)))):
            self.assertTrue(p.crc_ok(raw), raw.hex())
            self.assertFalse(p.crc_ok(raw[:-1] + bytes([raw[-1] ^ 1])), raw.hex())


class Replies(unittest.TestCase):
    def test_result_codes(self):
        self.assertTrue(p.parse_reply(reply(0xD3, b"\x00")).ok)
        self.assertFalse(p.parse_reply(reply(0x91, b"\x00", result=0xFF)).ok)
        with self.assertRaises(p.ProtocolError):
            p.parse_reply(b"\x05\x00")

    def test_time(self):
        self.assertEqual(p.parse_time(reply(0x05, u32(FAKE_TIME))), FAKE_TIME)
        for bad in (reply(0x07, u32(FAKE_TIME)), reply(0x05, u32(FAKE_TIME), result=0xFF), b"\x05\x00\x01"):
            with self.assertRaises(p.ProtocolError):
                p.parse_time(bad)

    def test_index(self):
        self.assertEqual(p.parse_index(reply(0x07, u16(258))), 258)
        self.assertEqual(p.parse_index(reply(0x08, u16(4660))), 4660)
        self.assertIsNone(p.parse_index(reply(0x08, b"", result=0xEE)))
        with self.assertRaises(p.ProtocolError):
            p.parse_index(reply(0x05, u16(1)))

    def test_record_range(self):
        d = p.parse_record_range(reply(0x09, u16(7000) + u16(3) + u16(7000)))
        self.assertEqual(d, {"ok": True, "crc_ok": True, "oldest": 3, "newest": 7000})

    def test_mode_and_interval(self):
        self.assertEqual(p.parse_mode(reply(0x59, b"\x42")), {"ok": True, "mode": 0x42})
        self.assertEqual(p.parse_interval(reply(0x14, bytes([9, 9, 17]))), {"minutes": 17})
        self.assertEqual(p.parse_interval(frame(b"\x14\x00\x01\x01\x00", b"\x1d")), {"minutes": 29})

    def test_status_flags(self):
        for offset, name in ((12, "chill_running"), (13, "chill_on"), (14, "critical_on"),
                             (15, "critical_from_low_battery"), (18, "spo2_on")):
            d = p.parse_status_flags(reply(0x20, layout(26, {offset - 3: 1})))
            self.assertEqual({k for k, v in d.items() if v}, {name})
        for bad in (reply(0x20, bytes(26), result=0xFF), reply(0x20, bytes(5)), reply(0x59, bytes(26))):
            with self.assertRaises(p.ProtocolError):
                p.parse_status_flags(bad)

    def test_errors_never_carry_the_bytes(self):
        secret = bytes([0xC7] * 8)
        for parse in (p.parse_time, p.parse_index, p.parse_recordings, p.parse_live_hr, p.parse_breath, p.parse_debug_page,
                      p.parse_config, p.parse_events_info, p.parse_status_flags, p.parse_record_range, p.parse_interval):
            with self.assertRaises(p.ProtocolError) as e:
                parse(bytes([0xEE, 0, 1]) + secret)
            self.assertNotIn("c7c7", str(e.exception))
        with self.assertRaises(p.ProtocolError) as e:
            p.parse_reply(secret[:2])
        self.assertNotIn("c7", str(e.exception))


class History(unittest.TestCase):
    def test_every_field(self):
        (r,) = p.parse_recordings(reply(0x04, record(513), detail=1))
        self.assertEqual((r.index, r.timestamp, r.temp_time, r.motion_time),
                         (513, FAKE_TIME + 513, FAKE_TIME + 514, FAKE_TIME + 515))
        self.assertEqual((r.heart_rate, r.rmssd_ms, r.spo2, r.pulse_confidence, r.byte_28, r.byte_29),
                         (111, 22, 99, 3, 33, 12))
        self.assertEqual((r.skin_temp_c, r.second_temp_c, r.activity, r.steps), (30.5, 20.25, 777, 4321))

    def test_page_of_seven(self):
        recs = p.parse_recordings(reply(0x04, b"".join(record(100 + i, hr=100 + i) for i in range(7)), detail=7))
        self.assertEqual([r.index for r in recs], list(range(100, 107)))
        self.assertEqual([r.heart_rate for r in recs], list(range(100, 107)))

    def test_no_temperature(self):
        (r,) = p.parse_recordings(reply(0x04, record(1, skin=math.nan, ambient=math.nan), detail=1))
        self.assertIsNone(r.skin_temp_c)
        self.assertIsNone(r.second_temp_c)

    def test_empty_end_and_truncated(self):
        self.assertEqual(p.parse_recordings(reply(0x04, b"", result=0xEE, detail=0)), [])
        self.assertEqual(p.parse_recordings(reply(0x04, b"", result=0x13, detail=0)), [])
        with self.assertRaises(p.ProtocolError):
            p.parse_recordings(reply(0x04, record(1), detail=2))


class State(unittest.TestCase):
    def test_every_field(self):
        raw = layout(76, {0: 77, 1: i32(-120000), 5: 3, 6: 21, 7: (4100).to_bytes(2, "big"), 9: 4, 10: 1,
                          15: (99).to_bytes(2, "big"), 17: (601).to_bytes(2, "big"), 19: (302).to_bytes(2, "big"),
                          21: (1250).to_bytes(2, "big"), 29: u32(FAKE_TIME)})
        s = p.parse_state(raw)
        self.assertEqual((s.battery_pct, s.microamps, s.charge_state, s.temp_c, s.millivolts), (77, -120000, 3, 21, 4100))
        self.assertEqual((s.charge_stage, s.contact, s.cell_mah, s.minutes_left, s.minutes_to_full),
                         (4, 1, 99, 601, 302))
        self.assertEqual((s.cycles, s.timestamp), (12.5, FAKE_TIME))

    def test_short_and_empty(self):
        s = p.parse_state(layout(7, {0: 50, 1: i32(5), 6: 20}))
        self.assertEqual((s.battery_pct, s.millivolts, s.timestamp), (50, None, None))
        for bad in (bytes(7), bytes(76), b"\x01\x02"):
            with self.assertRaises(p.ProtocolError):
                p.parse_state(bad)


class StreamSamples(unittest.TestCase):
    def test_live_hr(self):
        body = layout(14, {0: u32(FAKE_TIME), 4: 123, 5: 7, 6: 45, 7: 201, 8: u16(2468), 10: f32(31.25)})
        h = p.parse_live_hr(stream(0x52, body))
        self.assertEqual((h.timestamp, h.hr, h.pulse_confidence, h.rmssd_ms, h.byte_7, h.steps, h.skin_temp_c),
                         (FAKE_TIME, 123, 7, 45, 201, 2468, 31.25))
        with self.assertRaises(p.ProtocolError):
            p.parse_live_hr(reply(0x52, b"\x00"))  # the start acknowledgement is not a sample

    def test_breathing(self):
        body = layout(22, {0: u32(FAKE_TIME), 4: 98, 5: 6, 6: 54, 7: 76, 8: f32(32.5)}, fill=0xFF)
        b = p.parse_breath(stream(0x72, body))
        self.assertEqual((b.timestamp, b.hr, b.pulse_confidence, b.rmssd_ms, b.sdnn_ms, b.skin_temp_c),
                         (FAKE_TIME, 98, 6, 54, 76, 32.5))
        with self.assertRaises(p.ProtocolError):
            p.parse_breath(stream(0x72, body[:10]))

    def test_length_field_bounds_the_payload(self):
        body = layout(14, {0: u32(FAKE_TIME), 4: 123})
        short = stream(0x52, body[:13]) + bytes(8)  # says 13 bytes, whatever follows
        with self.assertRaises(p.ProtocolError):
            p.parse_live_hr(short)

    def test_stream_replies_give_sizes_only(self):
        raw = stream(0x9A, bytes(range(20)))
        self.assertEqual(p.parse_stream_reply(raw), {"len": 20, "crc_ok": True})
        self.assertFalse(p.parse_stream_reply(raw[:-1] + bytes([raw[-1] ^ 1]))["crc_ok"])

    def test_ppg_frame(self):
        body = b"".join(u32(1000 + i) + u32(2000 + i) + u32(3000 + i) for i in range(12))
        raw = b"\x90" + u16(156) + b"\x08\x08" + u32(5000) + bytes(6) + body + bytes(2)
        f = p.parse_ppg_frame(raw)
        self.assertEqual((f.tick_ms, len(f.samples), f.samples[3]), (5000, 12, (1003, 2003, 3003)))
        for other in (bytes(89), raw[:-1], raw + b"\0", b"\x91" + raw[1:]):
            self.assertIsNone(p.parse_ppg_frame(other))


class DebugPages(unittest.TestCase):
    def test_summary(self):
        d = p.parse_debug_page(debug_page(0, layout(44, {12: u16(6000), 14: u16(5), 16: u16(9000), 20: u32(FAKE_TIME),
                                                        24: u16(321), 28: u32(987654), 40: 66, 42: u16(8)})))
        self.assertEqual((d["newest_record"], d["oldest_record"], d["record_limit"], d["clock"]), (6000, 5, 9000, FAKE_TIME))
        self.assertEqual((d["steps"], d["steps_total"], d["battery_pct"], d["restarts"]), (321, 987654, 66, 8))

    def test_power(self):
        d = p.parse_debug_page(debug_page(4, layout(31, {0: 55, 1: i32(-7), 5: u16(4001), 10: u16(88), 17: 3, 18: 19,
                                                        25: u16(12)})))
        self.assertEqual((d["battery_pct"], d["microamps"], d["millivolts"], d["cell_mah"], d["charge_state"],
                          d["temp_c"], d["cycles"]), (55, -7, 4001, 88, 3, 19, 12))

    def test_versions_leave_out_the_chip_id(self):
        fake_id = bytes([0xEE] * 8)
        d = p.parse_debug_page(debug_page(30, layout(40, {0: fake_id, 8: u32(0x12345), 20: u32(0x01020304)})))
        self.assertEqual({k: d[k] for k in d if k not in ("page", "name", "status")}, {"crc_ok": True, "firmware": "0x1020304"})
        self.assertNotIn("ee" * 8, repr(d))

    def test_bonds_give_only_a_count(self):
        # 10 slots of 8 bytes after the first; bytes 2..7 of a slot are the address, 0 and 1 are something else
        slots = {1 + i * 8 + 2: bytes([0xC0 + i] * 6) for i in range(3)}
        d = p.parse_debug_page(debug_page(28, layout(81, slots)))
        self.assertEqual(d["bonded_count"], 3)
        self.assertNotIn("c0" * 6, repr(d))
        self.assertEqual(p.parse_debug_page(debug_page(28, layout(81, {1 + i * 8: b"\x01\x02" for i in range(10)})))["bonded_count"], 0)
        edges = {1 + 2: 9, 1 + 9 * 8 + 7: 9}  # first byte of the first address, last byte of the last
        self.assertEqual(p.parse_debug_page(debug_page(28, layout(81, edges)))["bonded_count"], 2)

    def test_link_commands_and_addresses(self):
        d = p.parse_debug_page(debug_page(13, layout(99, {7: 8, 89: u32(40), 93: u32(39)})))
        self.assertEqual((d["last_drop_code"], d["connects"], d["disconnects"]), (8, 40, 39))
        d = p.parse_debug_page(debug_page(14, layout(40, {0: bytes([0x05, 0x20, 0x59])})))
        self.assertEqual(d["recent_opcodes"], ["05", "20", "59"])
        d = p.parse_debug_page(debug_page(14, layout(40, {0: bytes([0x05, 0xE7, 0xE8])})))
        self.assertEqual(d["recent_opcodes"], ["05", "other", "other"])
        d = p.parse_debug_page(debug_page(15, bytes([1, 2, 3, 4]) + bytes(8)))
        self.assertEqual((d["temperature"], d["motion"], d["fuel_gauge"], d["optical"]), ("0x1", "0x2", "0x3", "0x4"))

    def test_nothing_is_decoded_when_the_crc_is_wrong(self):
        for page, size in ((0, 44), (4, 31), (13, 99), (14, 40), (15, 24), (28, 81), (30, 40)):
            raw = debug_page(page, bytes([0x5A]) * size)
            d = p.parse_debug_page(raw[:-1] + bytes([raw[-1] ^ 1]))
            self.assertEqual(set(d), {"page", "name", "status", "crc_ok"}, page)
        raw = Config.page({3: 1})
        self.assertEqual(set(p.parse_config(raw[:-1] + bytes([raw[-1] ^ 1]), 2)), {"page", "valid"})

    def test_unsupported(self):
        self.assertFalse(p.parse_debug_page(debug_page(4, b"\xff"))["supported"])
        self.assertFalse(p.parse_debug_page(debug_page(4, bytes(31), status=0xFF))["supported"])


class EventLog(unittest.TestCase):
    @staticmethod
    def page(*words: int) -> bytes:
        return frame(b"\x0f\x00\x01\x04\x00", b"".join(map(u32, words)))

    def test_anchors_and_events(self):
        anchor, event = 1 << 30, 0b11 << 30
        pages = [self.page(anchor | 1000, event | 32 << 22 | 60), self.page(event | 86 << 22 | 120),
                 reply(0x0F, b"", result=0xFF)]
        ev = p.decode_events(pages)
        self.assertEqual([e.code for e in ev], [None, 32, 86])
        self.assertEqual([e.time - p.EVENTS_BASE_EPOCH for e in ev], [1000, 1060, 1120])
        self.assertTrue(all(e.valid for e in ev))
        self.assertEqual([e.name for e in ev][1:], ["Ring powered on", "Battery critically low"])

    def test_events_before_an_anchor_are_not_valid(self):
        (e,) = p.decode_events([self.page(0b11 << 30 | 32 << 22 | 5)])
        self.assertFalse(e.valid)

    def test_base_is_the_start_of_2026(self):
        from datetime import datetime, timezone
        self.assertEqual(datetime.fromtimestamp(p.EVENTS_BASE_EPOCH, timezone.utc), datetime(2026, 1, 1, tzinfo=timezone.utc))

    def test_full_width_of_code_and_offset(self):
        code, offset = 0xFE, (1 << 22) - 1
        ev = p.decode_events([self.page(1 << 30 | (1 << 30) - 1, 0b11 << 30 | code << 22 | offset)])
        self.assertEqual((ev[1].code, ev[1].time - ev[0].time), (code, offset))
        self.assertEqual(ev[0].time - p.EVENTS_BASE_EPOCH, (1 << 30) - 1)

    def test_crc_starts_after_the_sub_command(self):
        self.assertTrue(p.crc_ok(self.page(1, 2, 3)))

    def test_every_label(self):
        self.assertEqual({c: p.event_name(c) for c in p.EVENT_LABELS},
                         {23: "Daily restart", 26: "Restarted after hanging", 32: "Ring powered on", 36: "Firmware updated",
                          38: "Power dipped", 40: "Restarted after hanging", 49: "Paired with a phone",
                          79: "Low-power mode on", 80: "Low-power mode off", 81: "Chill mode on", 82: "Chill mode off",
                          83: "Charging", 84: "Battery down 10%", 85: "Battery up 10%", 86: "Battery critically low",
                          87: "SpO2 sensing on", 88: "SpO2 sensing off", 89: "Pairing changed",
                          97: "Factory reset", 98: "Firmware updated", 103: "Firmware updated", 104: "Firmware updated"})

    def test_unknown_codes_show_the_number(self):
        self.assertEqual(p.event_name(200), "Event 200")

    def test_info(self):
        d = p.parse_events_info(frame(b"\x0f\x00\x01\x01\x00", u32(0x11223344) + u32(0x55667788) + u16(4) + u16(321)))
        self.assertEqual(d, {"count_a": 4, "count_b": 321})


class Config(unittest.TestCase):
    @staticmethod
    def page(fields: dict[int, bytes | int]) -> bytes:
        return reply(0x80, layout(32, {0: b"\x07\x29"} | fields))

    def test_pages(self):
        d = p.parse_config(self.page({3: 1, 5: 0, 12: 17}), 2)
        self.assertEqual((d["valid"], d["chill_on"], d["spo2_on"], d["record_minutes"]), (True, 1, 0, 17))
        d = p.parse_config(self.page({3: 16, 4: u16(104)}), 3)
        self.assertEqual((d["accel_range_g"], d["accel_hz"]), (16, 104))
        d = p.parse_config(self.page({2: u16(50), 10: u16(1234), 13: 1, 14: 0, 15: 1}), 4)
        self.assertEqual((d["ppg_hz"], d["finger_threshold"], d["green_on"], d["ir_on"], d["red_on"]),
                         (50, 1234, 1, 0, 1))

    def test_empty_page_is_not_valid(self):
        self.assertFalse(p.parse_config(reply(0x80, b"\xff" * 32), 5)["valid"])


class Requests(unittest.TestCase):
    ONE_BYTE = (0x05, 0x07, 0x08, 0x09, 0x20) + (0x52, 0x53, 0x59, 0x72, 0x74) + (0x91, 0xA1, 0xD1, 0xD2) + (0xD3, 0xD4, 0xFB, 0xFC)

    def test_exact_bytes_of_the_commands_that_change_the_ring(self):
        self.assertEqual((p.OP_SPO2_ON, p.OP_SPO2_OFF), (0xD1, 0xD2))
        self.assertEqual((p.OP_CRITICAL_ON, p.OP_CRITICAL_OFF), (0xD3, 0xD4))
        self.assertEqual((p.OP_CHILL_ON, p.OP_CHILL_OFF), (0xFB, 0xFC))
        self.assertEqual((p.OP_LIVE_HR_START, p.OP_LIVE_HR_STOP), (0x52, 0x53))
        self.assertEqual((p.OP_BREATHING_START, p.OP_BREATHING_STOP), (0x72, 0x74))
        self.assertEqual((p.OP_RAW_PPG_START, p.OP_RAW_PPG_STOP), (0x90, 0x91))

    def test_mode_sequences(self):
        from loophole_ring.client import Ring
        self.assertEqual(Ring.MODES, {"turbo": (0xD4, 0xFC), "chill": (0xD4, 0xFB), "critical": (0xD3,),
                                      "passive-on": (0xFB,), "passive-off": (0xFC,), "spo2-on": (0xD1,), "spo2-off": (0xD2,)})

    def test_every_one_and_two_byte_packet(self):
        """The whole space, so nothing is allowed by accident."""
        ok1 = {bytes([op]) for op in self.ONE_BYTE}
        ok2 = {b"\x14\x01", b"\x0f\x01"} | {bytes([0x80, g]) for g in range(2, 7)}
        self.assertEqual({bytes([a]) for a in range(256) if p.is_allowed(bytes([a]))}, ok1)
        self.assertEqual({bytes([a, b]) for a in range(256) for b in range(256) if p.is_allowed(bytes([a, b]))}, ok2)
        self.assertFalse(p.is_allowed(b""))

    def test_longer_packets(self):
        pages = [p.debug_page_request(i) for i in (0, 4, 13, 14, 15, 28, 29, 30)]  # public-ok: page numbers
        for x in (b"\x04\x01\x00", p.events_request(0), p.ppg_start_packet(), *pages, *p.WEAR_LOG_REQUESTS.values()):
            self.assertTrue(p.is_allowed(x), x.hex())
            self.assertFalse(p.is_allowed(x + b"\x00"), x.hex())
            self.assertFalse(p.is_allowed(x[:-1]) and len(x) > 2, x.hex())
        changed = bytearray(p.ppg_start_packet())
        changed[-1] ^= 1
        for x in (bytes(changed), b"\x79\x29\x07\x05\x00", b"\x79\x28\x07\x00\x00", b"\x9a\x01\x00" + b"\xff" * 3,
                  b"\x0f\x05\x00\x00", b"\x02" + bytes(9), b"\x0a" + bytes(9), b"\xf1" + bytes(4)):
            self.assertFalse(p.is_allowed(x), x.hex())

    def test_wear_log_requests_carry_a_valid_crc(self):
        self.assertEqual([req[3:-2] for req in p.WEAR_LOG_REQUESTS.values()], [b"", b"\x01", b"\x02"])
        for req in p.WEAR_LOG_REQUESTS.values():
            self.assertEqual(crc(req[3:-2]), req[-2:])
            self.assertEqual(int.from_bytes(req[1:3], "little"), len(req[3:-2]))

    def test_ppg_settings_are_well_formed(self):
        packet = p.ppg_start_packet()
        tags, i = {}, 1
        while i < len(packet):
            tag, n = packet[i], packet[i + 1]
            tags[tag] = packet[i + 2:i + 2 + n]
            i += 2 + n
        self.assertEqual(i, len(packet))
        self.assertEqual(sorted(tags), [1, 4, 5, 6, 7, 8])
        self.assertEqual(int.from_bytes(tags[8], "big"), 9000)


def synthetic_frames(bpm, seconds, noise, seed=1):
    rnd = random.Random(seed)
    frames, n = [], 0
    for k in range(int(seconds * 25 / 12)):
        smp = []
        for _ in range(12):
            t = n / 25.0
            v = 44000 + 300 * math.sin(2 * math.pi * bpm / 60 * t) + 2000 * t / seconds + rnd.gauss(0, noise)
            smp.append((int(v), 0, 0))
            n += 1
        frames.append(p.PpgFrame(1000 + int(n * 40) - 40, tuple(smp)))
    return frames


class HeartRate(unittest.TestCase):
    def test_clean_pulse(self):
        for bpm in (52, 72, 110):
            est = [e.bpm for _, e in estimate_series(resample(synthetic_frames(bpm, 30, 40)))]
            good = [b for b in est if b]
            self.assertTrue(good, bpm)
            self.assertTrue(all(abs(b - bpm) <= 3 for b in good), (bpm, est))

    def test_noise_only_is_rejected(self):
        est = [e.bpm for _, e in estimate_series(resample(synthetic_frames(72, 30, 3000)))]
        self.assertTrue(sum(b is not None for b in est) <= 1, est)


if __name__ == "__main__":
    unittest.main()
