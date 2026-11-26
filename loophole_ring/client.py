"""BLE client for the ring (bleak). Sends only packets that pass protocol.is_allowed and never touches the SMP service.

If the ring is connected to a phone, it may not be found until the phone lets go of it.
"""
from __future__ import annotations

import asyncio
from collections.abc import AsyncIterator, Callable
from contextlib import asynccontextmanager

from bleak import BleakClient, BleakScanner
from bleak.backends.device import BLEDevice

from . import protocol as p


class RingNotFound(RuntimeError):
    pass


async def find_ring(name: str, timeout: float = 15.0) -> BLEDevice:
    """The ring with exactly this name. Never just the first ring nearby: that could be someone else's."""
    def match(device, adv) -> bool:
        return (adv.local_name or device.name or "") == name

    dev = await BleakScanner.find_device_by_filter(match, timeout=timeout)
    if dev is None:
        raise RingNotFound("your ring isn't advertising: is it free of the phone app, awake and in range?")
    return dev


Tap = Callable[[str, str, bytes], None]  # (direction "tx"/"rx", characteristic label, payload)
LABELS = {p.CMD_CHAR: "cmd", p.RESP_CHAR: "resp", p.STATE_CHAR: "state", p.STREAM_CHAR: "stream", p.AUX_CHAR: "aux"}


class Ring:
    def __init__(self, client: BleakClient, tap: Tap | None = None):
        self.client = client
        self.tap: Tap = tap or (lambda *_: None)
        self._replies: asyncio.Queue[bytes] = asyncio.Queue()
        self._lock = asyncio.Lock()
        self._listeners: dict[int, Callable[[bytes], None]] = {}  # opcode -> handler for unsolicited packets
        self._ppg: Callable[[p.PpgFrame], None] | None = None

    @classmethod
    @asynccontextmanager
    async def connect(cls, name: str, scan_timeout: float = 15.0, tap: Tap | None = None,
                      disconnected: Callable[[], None] | None = None) -> AsyncIterator["Ring"]:
        dev = await find_ring(name, scan_timeout)
        async with BleakClient(dev, disconnected_callback=(lambda _: disconnected()) if disconnected else None) as client:
            ring = cls(client, tap)
            await ring.notify(p.RESP_CHAR, ring._on_reply)
            await ring.notify(p.AUX_CHAR, ring._on_aux)
            await ring.notify(p.STREAM_CHAR, ring._on_stream)  # PPG frames (0x90) and live HR samples (0x52)
            yield ring

    def _on_reply(self, raw: bytes) -> None:
        self._replies.put_nowait(raw)

    def _on_stream(self, raw: bytes) -> None:
        if not raw:
            return
        if raw[0] == 0x90 and self._ppg:
            f = p.parse_ppg_frame(raw)
            if f:
                self._ppg(f)
        elif raw[0] in self._listeners:
            self._listeners[raw[0]](raw)
        elif raw[0] in p.STREAM_REPLY_OPS:
            self._replies.put_nowait(raw)

    def _on_aux(self, raw: bytes) -> None:
        if raw and raw[0] in self._listeners:
            self._listeners[raw[0]](raw)

    async def notify(self, char: str, handler: Callable[[bytes], None]) -> None:
        def cb(_, data: bytearray) -> None:
            raw = bytes(data)
            self.tap("rx", LABELS.get(char, char), raw)
            handler(raw)
        await self.client.start_notify(char, cb)

    async def _write(self, packet: bytes) -> None:
        if not p.is_allowed(packet):
            raise ValueError("that packet is not on the allowlist")
        self.tap("tx", "cmd", packet)
        # Write Requests: the only kind this project sends.
        await self.client.write_gatt_char(p.CMD_CHAR, packet, response=True)

    @property
    def name(self) -> str:
        return self.client.name or "?"

    async def command(self, packet: bytes, timeout: float = 5.0, replies: int = 1) -> list[bytes]:
        """Send one allowlisted command as a Write Request and collect `replies` notifications with its opcode."""
        op = packet[0]
        async with self._lock:
            while not self._replies.empty():
                self._replies.get_nowait()
            await self._write(packet)
            out: list[bytes] = []
            while len(out) < replies:
                raw = await asyncio.wait_for(self._replies.get(), timeout)
                if raw[0] == op:
                    out.append(raw)
            return out

    async def state(self, wait: float = 30.0) -> p.State:
        """Wait for the next pushed state record and fall back to a read."""
        got: asyncio.Queue[bytes] = asyncio.Queue()
        await self.notify(p.STATE_CHAR, got.put_nowait)
        try:
            raw = await asyncio.wait_for(got.get(), wait)
        except asyncio.TimeoutError:
            raw = bytes(await self.client.read_gatt_char(p.STATE_CHAR))
        finally:
            await self.client.stop_notify(p.STATE_CHAR)
        return p.parse_state(raw)

    async def time(self) -> int:
        return p.parse_time((await self.command(bytes([p.OP_CLOCK])))[0])

    async def history_bounds(self) -> tuple[int | None, int | None]:
        first = p.parse_index((await self.command(bytes([p.OP_OLDEST_RECORD])))[0])
        last = p.parse_index((await self.command(bytes([p.OP_NEWEST_RECORD])))[0])
        return first, last

    async def recordings(self, start: int, timeout: float = 5.0) -> list[bytes]:
        """Raw `04` replies from `start` onward until the ring goes quiet."""
        op = p.OP_HISTORY
        async with self._lock:
            while not self._replies.empty():
                self._replies.get_nowait()
            await self._write(bytes([op]) + start.to_bytes(2, "little"))
            out: list[bytes] = []
            try:
                while True:
                    raw = await asyncio.wait_for(self._replies.get(), timeout if not out else 2.0)
                    if raw[0] == op:
                        out.append(raw)
            except asyncio.TimeoutError:
                pass
            return out

    # Battery modes are command pairs: Turbo = critical off + chill off, Chill = critical off + chill on.
    MODES = {"turbo": (p.OP_CRITICAL_OFF, p.OP_CHILL_OFF), "chill": (p.OP_CRITICAL_OFF, p.OP_CHILL_ON),
             "critical": (p.OP_CRITICAL_ON,), "passive-on": (p.OP_CHILL_ON,), "passive-off": (p.OP_CHILL_OFF,),
             "spo2-on": (p.OP_SPO2_ON,), "spo2-off": (p.OP_SPO2_OFF,)}

    async def set_mode(self, mode: str) -> p.Reply:
        """Send the mode's commands in order; returns the first failed reply, else the last one."""
        reply = None
        for op in self.MODES[mode]:
            reply = p.parse_reply((await self.command(bytes([op])))[0])
            if not reply.ok:
                break
        assert reply is not None
        return reply

    async def start_ppg(self, on_frame: Callable[[p.PpgFrame], None]) -> None:
        self._ppg = on_frame
        start = p.parse_reply((await self.command(p.ppg_start_packet()))[0])
        if not start.ok:
            self._ppg = None
            raise RuntimeError(f"ring refused to start recording: result 0x{start.result:02x}")

    async def stop_ppg(self) -> None:
        for _ in range(3):  # leave the LEDs off
            try:
                await self.command(bytes([p.OP_RAW_PPG_STOP]))
                break
            except Exception:
                await asyncio.sleep(0.5)
        self._ppg = None

    @asynccontextmanager
    async def ppg_stream(self) -> AsyncIterator[asyncio.Queue[p.PpgFrame]]:
        """Start the 25 Hz raw PPG stream, yield a queue of PPG frames, always stop it on exit."""
        frames: asyncio.Queue[p.PpgFrame] = asyncio.Queue()
        await self.start_ppg(frames.put_nowait)
        try:
            yield frames
        finally:
            await self.stop_ppg()

    async def start_live_hr(self, on_sample: Callable[[p.LiveHr | bytes], None]) -> None:
        """Ring-computed HR stream (0x52). on_sample gets LiveHr, or the raw bytes if they don't parse."""
        def handle(raw: bytes) -> None:
            try:
                on_sample(p.parse_live_hr(raw))
            except p.ProtocolError:
                on_sample(raw)

        reply = p.parse_reply((await self.command(bytes([p.OP_LIVE_HR_START])))[0])
        if not reply.ok:
            raise RuntimeError(f"ring refused live HR: result 0x{reply.result:02x} (Critical mode may block it)")
        self._listeners[p.OP_LIVE_HR_START] = handle

    async def stop_live_hr(self) -> None:
        self._listeners.pop(p.OP_LIVE_HR_START, None)
        try:
            await self.command(bytes([p.OP_LIVE_HR_STOP]))
        except asyncio.TimeoutError:
            pass

    async def start_breath(self, on_sample: Callable[[p.Breath | bytes], None]) -> None:
        """Breathing mode (0x72): samples arrive on the stream char until 0x74. Uses the sensors: always stop it."""
        def handle(raw: bytes) -> None:
            try:
                on_sample(p.parse_breath(raw))
            except p.ProtocolError:
                on_sample(raw)

        reply = p.parse_reply((await self.command(bytes([p.OP_BREATHING_START])))[0])
        if not reply.ok:
            raise RuntimeError(f"ring refused breathing mode: result 0x{reply.result:02x}")
        self._listeners[p.OP_BREATHING_START] = handle

    async def stop_breath(self) -> bool:
        """True if the ring acknowledged the stop."""
        self._listeners.pop(p.OP_BREATHING_START, None)
        return p.parse_reply((await self.command(bytes([p.OP_BREATHING_STOP])))[0]).ok

    async def collect(self, packet: bytes, timeout: float = 5.0, limit: int = 200) -> list[bytes]:
        """Send one command and gather same-opcode replies until one with a non-zero status (end) or a quiet `timeout`."""
        op = packet[0]
        async with self._lock:
            while not self._replies.empty():
                self._replies.get_nowait()
            await self._write(packet)
            out: list[bytes] = []
            while len(out) < limit:
                try:
                    raw = await asyncio.wait_for(self._replies.get(), timeout)
                except asyncio.TimeoutError:
                    break
                if raw[0] == op:
                    out.append(raw)
                    if len(raw) > 1 and raw[1] != 0:
                        break
            return out

    async def query(self, packet: bytes, timeout: float = 5.0) -> bytes:
        """One read-only query (must pass protocol.is_allowed); returns the first reply with the same opcode."""
        return (await self.command(packet, timeout))[0]
