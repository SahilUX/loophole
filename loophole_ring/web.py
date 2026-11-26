"""Local live dashboard: what this computer and the ring send each other, plus battery, PPG and heart rate.

Standard library only (asyncio HTTP + Server-Sent Events). Binds to 127.0.0.1 and refuses requests that name another
host or that a browser marks as coming from another site. That stops other web pages, not other programs on this computer. Buttons map to allowlisted commands only; starting
the LEDs needs a confirm in the page and stops itself after MAX_PPG_S.

The page never gets a ring name (it holds the ring's Bluetooth address), a chip ID or a paired address: rings are
numbered, and raw bytes are shown only where safe_hex allows. Errors are shown by type, because Bluetooth error
text can name the device.
"""
from __future__ import annotations

import asyncio
import json
import os
import sys
import time
from pathlib import Path

from bleak import BleakScanner

from . import protocol as p
from .client import Ring, RingNotFound
from .hr import estimate_window, preprocess, resample

MAX_PPG_S = 120
PAGE = (Path(__file__).parent / "web.html").read_bytes()
# The chosen ring is remembered outside the repo, so a ring that shows up nearby later is never picked by accident.
_CONFIG = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config"))
CHOICE_FILE = _CONFIG / "loophole-ring" / "web.json"


def load_choice() -> str | None:
    try:
        if CHOICE_FILE.stat().st_mode & 0o077:
            CHOICE_FILE.chmod(0o600)  # written by an older version, readable by others
        return json.loads(CHOICE_FILE.read_text()).get("ring")
    except (OSError, ValueError, AttributeError):
        return None


def save_choice(name: str | None) -> None:
    CHOICE_FILE.parent.mkdir(parents=True, exist_ok=True)
    CHOICE_FILE.touch(mode=0o600, exist_ok=True)
    CHOICE_FILE.chmod(0o600)  # the ring name holds its Bluetooth address
    CHOICE_FILE.write_text(json.dumps({"ring": name}))


STATE_FIELDS = ((0, 11), (15, 23), (29, 33))  # the decoded parts of the state record
ACK_OPCODES = frozenset({p.OP_LIVE_HR_START, p.OP_LIVE_HR_STOP, p.OP_BREATHING_START, p.OP_BREATHING_STOP, p.OP_RAW_PPG_START,
                         p.OP_RAW_PPG_STOP, p.OP_SPO2_ON, p.OP_SPO2_OFF, p.OP_CRITICAL_ON, p.OP_CRITICAL_OFF, p.OP_CHILL_ON,
                         p.OP_CHILL_OFF})


def understood(raw: bytes) -> bool:
    """A whole reply of an exact shape, with a good CRC, in which every byte is accounted for."""
    if len(raw) < 5 or not p.crc_ok(raw):
        return False
    op, head, n = raw[0], raw[1:3], len(raw)
    if op == p.OP_CLOCK:
        return n == 9 and head == b"\x00\x01"
    if op in (p.OP_OLDEST_RECORD, p.OP_NEWEST_RECORD):
        return n == 7 and head == b"\x00\x01"
    if op == p.OP_RECORD_RANGE:
        return n == 11 and head == b"\x00\x01" and raw[3:5] == raw[7:9]
    if op == p.OP_RECORD_INTERVAL:
        return n == 8 and raw[1:5] == b"\x00\x01\x01\x00"
    return False


ACTIONS = frozenset({"time", "history", "turbo", "chill", "critical", "passive-on", "passive-off", "spo2-on", "spo2-off",
                     "hr-start", "hr-stop", "live-start", "live-stop", "breath-start", "breath-stop", "rec-stop"})


def safe_hex(direction: str, char: str, raw: bytes) -> str:
    """Raw bytes for the page. A reply shows in full only when it is understood(), an acknowledgement shows its opcode,
    result and detail, the state record shows its decoded parts, and everything else shows its first byte at most."""
    if direction == "tx":
        return raw.hex() if p.is_allowed(raw) else f"[{len(raw)} bytes hidden]"
    if char == "state" and len(raw) == 76:
        return "".join(f"{b:02x}" if any(a <= i < z for a, z in STATE_FIELDS) else ".." for i, b in enumerate(raw))
    if char == "resp" and understood(raw):
        return raw.hex()
    ack = char == "resp" and len(raw) in (6, 11) and raw[0] in ACK_OPCODES and p.crc_ok(raw)
    shown = raw[:3] if ack else raw[:1] if char in ("resp", "stream") and raw[:1] and raw[0] in p.KNOWN_OPCODES else b""
    return f"{shown.hex()} [{len(raw) - len(shown)} bytes hidden]".strip()


def quiet(loop: asyncio.AbstractEventLoop, context: dict) -> None:
    """Errors nobody caught, by type only: the usual traceback can name the ring or its address."""
    e = context.get("exception")
    print(f"dashboard error: {type(e).__name__ if e else 'unknown'}", file=sys.stderr, flush=True)


class Hub:
    def __init__(self, name: str | None, port: int = 8765):
        self.port = port
        self.name = name or load_choice()  # None until someone picks a ring in the page
        self.nearby: dict[str, dict] = {}  # advertised name -> {rssi, seen}
        self.tokens: list[str] = []  # ring number in the page -> advertised name
        self.scan_now = asyncio.Event()
        self.drop = asyncio.Event()  # set on disconnect, or to switch rings
        self.session: asyncio.Task | None = None
        self.released = False  # let go of the ring so the phone app can have it; the choice is kept
        self.clients: set[asyncio.Queue[str]] = set()
        self.ring: Ring | None = None
        self.last_state: dict | None = None
        self.frames: list[p.PpgFrame] = []
        self.ppg_task: asyncio.Task | None = None
        self.live_task: asyncio.Task | None = None
        self.breath_task: asyncio.Task | None = None
        self.breath_unconfirmed_stop = False  # link dropped mid-breathing: 0x74 is resent on the next connection
        self.sse_tasks: set[asyncio.Task] = set()
        self.ppg_unconfirmed_stop = False  # link dropped mid-PPG: stop wasn't acknowledged

    def emit(self, kind: str, **data) -> None:
        msg = "data: " + json.dumps({"type": kind, "t": time.time(), **data}) + "\n\n"
        for q in list(self.clients):
            if q.qsize() < 500:
                q.put_nowait(msg)

    def tap(self, direction: str, char: str, raw: bytes) -> None:
        self.emit("traffic", dir=direction, char=char, hex=safe_hex(direction, char, raw), n=len(raw))

    def number(self, name: str) -> int:
        """The ring's number in the page. Names stay on this side."""
        if name not in self.tokens:
            self.tokens.append(name)
        return self.tokens.index(name) + 1

    # --- BLE side -------------------------------------------------------
    async def ble_loop(self) -> None:
        while True:
            if self.released:
                self.emit("status", connected=False, text="released the ring to the phone: press Reconnect when done")
                self.scan_now.clear()
                await self.scan_now.wait()
                continue
            if not self.name:
                self.emit("status", connected=False, text="choose your ring below")
                await self.scan(8.0)
                try:
                    await asyncio.wait_for(self.scan_now.wait(), 4)
                except asyncio.TimeoutError:
                    pass
                continue
            self.drop.clear()
            self.session = asyncio.create_task(self.connect_once(self.name))
            await asyncio.gather(self.session, return_exceptions=True)
            await asyncio.sleep(3)

    async def connect_once(self, target: str) -> None:
        try:
            self.emit("status", connected=False, text="looking for your ring...")
            async with Ring.connect(target, 60.0, tap=self.tap, disconnected=self.drop.set) as ring:
                self.ring = ring
                self.emit("status", connected=True, text="connected")
                self.emit_rings()
                await ring.notify(p.STATE_CHAR, self.on_state)
                if self.ppg_unconfirmed_stop:
                    await self.run_action("rec-stop")
                if self.breath_unconfirmed_stop:
                    self.breath_unconfirmed_stop = not await ring.stop_breath()
                    self.emit("result", action="breath-stop", text="breathing mode stopped after reconnect")
                await self.run_action("time")
                await self.drop.wait()
        except RingNotFound:
            self.emit("status", connected=False, text="your ring was not found: is it free of the phone app, awake and in range?")
        except Exception as e:  # keep the page alive across BLE errors
            self.emit("status", connected=False, text=f"Bluetooth error: {type(e).__name__}")
        finally:
            self.ring = None
            if self.ppg_task:
                self.ppg_task.cancel()
            self.emit_rings()

    async def scan(self, seconds: float) -> None:
        """List advertising UH_* rings for the chooser. A connected ring may stop advertising, so it is kept as is."""
        self.scan_now.clear()
        self.emit("scanning", on=True)
        try:
            found = await BleakScanner.discover(timeout=seconds, return_adv=True)
        except Exception as e:
            self.emit("status", connected=self.ring is not None, text=f"scan failed: {type(e).__name__}")
            found = {}
        now = time.time()
        for dev, adv in found.values():
            n = adv.local_name or dev.name or ""
            if n.startswith("UH_"):
                self.nearby[n] = {"rssi": adv.rssi, "seen": now}
        self.emit("scanning", on=False)
        self.emit_rings()

    def emit_rings(self) -> None:
        connected = self.ring.name if self.ring else None
        names = set(self.nearby) | ({self.name} if self.name else set())
        rows = [{"ring": self.number(n), "rssi": self.nearby.get(n, {}).get("rssi"), "seen": self.nearby.get(n, {}).get("seen"),
                 "chosen": n == self.name, "connected": n == connected} for n in names]
        rows.sort(key=lambda r: (not r["chosen"], -(r["rssi"] or -999)))
        self.emit("rings", rings=rows)

    async def release(self, on: bool) -> None:
        if on == self.released:
            return
        if on:
            for task in (self.ppg_task, self.live_task, self.breath_task):
                if task and not task.done():
                    task.cancel()
                    await asyncio.gather(task, return_exceptions=True)
        self.released = on
        if on and self.ring:
            await self.ring.client.disconnect()
        elif on and self.session and not self.session.done():
            self.session.cancel()
        self.drop.set()
        self.scan_now.set()
        self.emit("released", on=on)

    async def choose(self, name: str | None) -> None:
        """Switch to another ring (or forget the current one). Running LED / live HR sessions are stopped first."""
        if name == self.name:
            return
        for task in (self.ppg_task, self.live_task, self.breath_task):
            if task and not task.done():
                task.cancel()  # their finally blocks send the stop command to the old ring
                await asyncio.gather(task, return_exceptions=True)
        self.name = name
        self.released = False
        save_choice(name)
        self.last_state = None
        self.emit("state_reset")
        self.emit_rings()
        if self.ring:
            await self.ring.client.disconnect()
        elif self.session and not self.session.done():
            self.session.cancel()  # still searching for the old ring
        self.drop.set()
        self.scan_now.set()

    def on_state(self, raw: bytes) -> None:
        try:
            s = p.parse_state(raw)
        except p.ProtocolError:
            return
        self.last_state = dict(battery=s.battery_pct, microamps=s.microamps, mv=s.millivolts, temp=s.temp_c,
                               charging=s.charge_state == 3, charge_stage=s.charge_stage, contact=s.contact,
                               capacity=s.cell_mah, ring_time=s.timestamp)
        self.emit("state", **self.last_state)

    async def run_action(self, action: str) -> None:
        ring = self.ring
        if ring is None:
            self.emit("result", action=action, text="not connected")
            return
        try:
            if action == "time":
                t = await ring.time()
                self.emit("result", action=action, text=f"ring clock {time.strftime('%H:%M:%S', time.localtime(t))}, "
                                                        f"drift {t - int(time.time()):+d} s vs this computer")
            elif action == "history":
                first, last = await ring.history_bounds()
                text = f"history indices {first}..{last}"
                if last is not None:
                    recs = []
                    for raw in await ring.recordings(max(first or 0, last - 4)):
                        try:
                            recs += p.parse_recordings(raw)
                        except p.ProtocolError:
                            pass
                    text += "".join(f"\n#{r.index} {time.strftime('%H:%M:%S', time.localtime(r.timestamp))} "
                                    f"HR {r.heart_rate or '-'} HRV {r.rmssd_ms or '-'} skin {r.skin_temp_c or '-'}C steps {r.steps}" for r in recs)
                self.emit("result", action=action, text=text)
            elif action in ("turbo", "chill", "critical", "passive-on", "passive-off", "spo2-on", "spo2-off"):
                r = await ring.set_mode(action)
                self.emit("result", action=action, text=f"mode {action}: {'ok' if r.ok else 'failed 0x%02x' % r.result}")
            elif action == "hr-start":
                if self.ppg_task and not self.ppg_task.done():
                    return
                self.ppg_task = asyncio.create_task(self.ppg_session(ring))
            elif action.startswith("q-"):
                await self.probe(ring, action[2:])
            elif action == "rec-stop":  # safety: tell the ring to stop any raw PPG stream
                r = p.parse_reply((await ring.command(bytes([p.OP_RAW_PPG_STOP])))[0])
                self.ppg_unconfirmed_stop = False
                self.emit("result", action=action, text="the ring accepted the stop" if r.ok
                          else "the ring refused the stop, probably because nothing was running")
            elif action == "hr-stop":
                if self.ppg_task:
                    self.ppg_task.cancel()
            elif action == "live-start":
                if self.live_task and not self.live_task.done():
                    return
                self.live_task = asyncio.create_task(self.live_session(ring))
            elif action == "live-stop":
                if self.live_task:
                    self.live_task.cancel()
            elif action == "breath-start":
                if self.breath_task and not self.breath_task.done():
                    return
                self.breath_task = asyncio.create_task(self.breath_session(ring))
            elif action == "breath-stop":
                if self.breath_task:
                    self.breath_task.cancel()
        except Exception as e:
            self.emit("result", action=action, text=f"{action} failed: {type(e).__name__}")

    async def ppg_session(self, ring: Ring) -> None:
        self.frames = []
        started = time.monotonic()

        def on_frame(f: p.PpgFrame) -> None:
            self.frames.append(f)
            self.emit("ppg", values=[s[0] for s in f.samples])

        await ring.start_ppg(on_frame)
        self.emit("result", action="hr-start", text=f"LEDs on, streaming PPG (auto-stop after {MAX_PPG_S} s)")
        try:
            while time.monotonic() - started < MAX_PPG_S:
                await asyncio.sleep(5)
                series = resample(self.frames, 0)
                y = preprocess(series)[100:]  # drop 4 s settle
                if len(y) >= 250:
                    e = estimate_window(y[-250:])
                    self.emit("hr", bpm=e.bpm, dft=e.dft_bpm, acf=e.acf_bpm, q=e.quality)
        finally:
            try:
                await asyncio.wait_for(ring.command(bytes([p.OP_RAW_PPG_STOP])), 3)
                await ring.stop_ppg()
            except Exception:
                self.ppg_unconfirmed_stop = True  # retried on the next connection
            self.emit("result", action="hr-stop", text=f"LEDs off after {time.monotonic() - started:.0f} s, "
                                                       f"{len(self.frames)} frames")

    PROBES = {
        "flags": (lambda: bytes([p.OP_STATUS_FLAGS]), p.parse_status_flags),
        "mode": (lambda: bytes([p.OP_SENSOR_MODE]), p.parse_mode),
        "interval": (lambda: b"\x14\x01", p.parse_interval),
        **{f"page-{i}": ((lambda i=i: p.debug_page_request(i)), p.parse_debug_page) for i in p.DEBUG_PAGES},
        "wear": (lambda: p.WEAR_LOG_REQUESTS["latest"], p.parse_stream_reply),
        "wear-off": (lambda: p.WEAR_LOG_REQUESTS["off_finger"], p.parse_stream_reply),
        "wear-on": (lambda: p.WEAR_LOG_REQUESTS["on_finger"], p.parse_stream_reply),
        "range": (lambda: bytes([p.OP_RECORD_RANGE]), p.parse_record_range),
        "faults": (lambda: bytes([p.OP_FAULT_LOG]), p.parse_stream_reply),
        "events-info": (lambda: p.EVENTS_INFO, p.parse_events_info),
        "events": (lambda: p.events_request(0), None),
        **{f"cfg-{g}": ((lambda g=g: bytes([p.OP_CONFIG_PAGE, g])), (lambda raw, g=g: p.parse_config(raw, g)))
           for g in range(2, 7)},
    }

    async def probe(self, ring: Ring, name: str) -> None:
        build, parse = self.PROBES[name]
        if name == "events":
            pages = await ring.collect(build(), timeout=4)
            self.emit("probe", name=name, decoded=p.parse_events(pages), hex="")
            return
        raw = await ring.query(build(), timeout=6)
        try:
            decoded = parse(raw) if parse else {"crc_ok": p.crc_ok(raw), "len": len(raw)}
        except p.ProtocolError as e:
            decoded = {"error": str(e)}
        self.emit("probe", name=name, decoded=decoded, hex=safe_hex("rx", "resp", raw))

    async def live_session(self, ring: Ring) -> None:
        started, n = time.monotonic(), 0

        def on_sample(x) -> None:
            nonlocal n
            n += 1
            if isinstance(x, p.LiveHr):
                self.emit("live", hr=x.hr, q=x.pulse_confidence, hrv=x.rmssd_ms, b7=x.byte_7,
                          steps=x.steps, temp=x.skin_temp_c, ring_time=x.timestamp)
            else:
                self.emit("result", action="live", text=f"live sample of {len(x)} bytes not understood")

        await ring.start_live_hr(on_sample)
        self.emit("result", action="live-start", text=f"live HR started (auto-stop after {MAX_PPG_S} s)")
        try:
            await asyncio.sleep(MAX_PPG_S)
        finally:
            await ring.stop_live_hr()
            self.emit("result", action="live-stop", text=f"live HR stopped after {time.monotonic() - started:.0f} s, "
                                                         f"{n} packets")

    async def breath_session(self, ring: Ring) -> None:
        started, n = time.monotonic(), 0

        def on_sample(x) -> None:
            nonlocal n
            n += 1
            if isinstance(x, p.Breath):
                self.emit("breath", hr=x.hr, q=x.pulse_confidence, hrv=x.rmssd_ms, sdnn=x.sdnn_ms, temp=x.skin_temp_c,
                          ring_time=x.timestamp)
            else:
                self.emit("result", action="breath", text=f"breathing sample of {len(x)} bytes not understood")

        self.breath_unconfirmed_stop = True  # cleared only by an acknowledged 0x74
        await ring.start_breath(on_sample)
        self.emit("result", action="breath-start", text=f"breathing mode on (auto-stop after {MAX_PPG_S} s)")
        try:
            await asyncio.sleep(MAX_PPG_S)
        finally:
            try:
                self.breath_unconfirmed_stop = not await asyncio.wait_for(ring.stop_breath(), 6)
            except Exception:
                pass
            self.emit("result", action="breath-stop", text=f"breathing mode stopped after {time.monotonic() - started:.0f} s, "
                                                           f"{n} packets" + (" (stop NOT confirmed: resent on reconnect)"
                                                                             if self.breath_unconfirmed_stop else ""))

    # --- HTTP side ------------------------------------------------------
    def allowed(self, method: str, headers: dict[str, str]) -> bool:
        """Keeps other web pages out: Host stops DNS rebinding, Origin stops other sites. Browsers send Origin with
        every POST, so a POST without one is refused. Any program on this computer can send the right headers."""
        hosts = {f"127.0.0.1:{self.port}", f"localhost:{self.port}"}
        if headers.get("host", "").lower() not in hosts:
            return False
        origin = headers.get("origin")
        if origin is None:
            return method == "GET" and headers.get("sec-fetch-site", "same-origin") in ("same-origin", "none")
        return origin.lower() in {f"http://{h}" for h in hosts}

    async def http(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        def status(line: str) -> None:
            writer.write(f"HTTP/1.1 {line}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".encode())

        try:
            lines = (await reader.readuntil(b"\r\n\r\n")).decode("latin-1").split("\r\n")
            method, path, _ = lines[0].split(" ", 2)
            pairs = [h.split(":", 1) for h in lines[1:] if ":" in h]
            headers = {k.lower(): v.strip(" \t") for k, v in pairs}
            if len(headers) != len(pairs) or not self.allowed(method, headers):  # a repeated header is refused too
                status("403 Forbidden")
            elif method == "GET" and path == "/":
                writer.write(b"HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\n"
                             b"X-Frame-Options: DENY\r\nContent-Length: " + str(len(PAGE)).encode() + b"\r\n\r\n" + PAGE)
            elif method == "GET" and path == "/events":
                await self.sse(writer)
                return
            elif method == "POST" and path == "/scan":
                if self.ring:  # connected: one scan now (the idle loop scans by itself)
                    asyncio.create_task(self.scan(8.0))
                self.scan_now.set()
                status("204 No Content")
            elif method == "POST" and path in ("/release", "/reconnect"):
                asyncio.create_task(self.release(path == "/release"))
                status("204 No Content")
            elif method == "POST" and path.startswith("/choose/"):
                pick = path.removeprefix("/choose/")
                if pick == "-":
                    asyncio.create_task(self.choose(None))
                    status("204 No Content")
                elif pick.isascii() and pick.isdigit() and 1 <= int(pick) <= len(self.tokens):
                    asyncio.create_task(self.choose(self.tokens[int(pick) - 1]))
                    status("204 No Content")
                else:
                    status("400 Bad Request")
            elif method == "POST" and path.startswith("/action/"):
                action = path.removeprefix("/action/")
                if action in ACTIONS or action in {f"q-{k}" for k in Hub.PROBES}:
                    asyncio.create_task(self.run_action(action))
                    status("204 No Content")
                else:
                    status("404 Not Found")
            else:
                status("404 Not Found")
            await writer.drain()
        except (asyncio.IncompleteReadError, asyncio.LimitOverrunError, ConnectionError, ValueError):
            pass
        finally:
            writer.close()

    async def sse(self, writer: asyncio.StreamWriter) -> None:
        q: asyncio.Queue[str] = asyncio.Queue()
        self.clients.add(q)
        me = asyncio.current_task()
        if me:
            self.sse_tasks.add(me)
        writer.write(b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-store\r\n\r\n")
        connected = self.ring is not None
        text = "connected" if self.ring else ("looking for your ring..." if self.name
                                                                     else "choose your ring below")
        q.put_nowait("data: " + json.dumps({"type": "status", "connected": connected, "text": text}) + "\n\n")
        if self.last_state:
            q.put_nowait("data: " + json.dumps({"type": "state", **self.last_state}) + "\n\n")
        self.emit_rings()
        q.put_nowait("data: " + json.dumps({"type": "released", "on": self.released}) + "\n\n")
        try:
            while True:
                try:
                    msg = await asyncio.wait_for(q.get(), 15)
                except asyncio.TimeoutError:
                    msg = ": ping\n\n"
                writer.write(msg.encode())
                await writer.drain()
        except (ConnectionError, asyncio.CancelledError):
            pass
        finally:
            self.clients.discard(q)
            if me:
                self.sse_tasks.discard(me)
            writer.close()


async def serve(name: str | None, port: int) -> None:
    import signal

    hub = Hub(name, port)
    server = await asyncio.start_server(hub.http, "127.0.0.1", port)
    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    loop.set_exception_handler(quiet)
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, stop.set)
    print(f"dashboard on http://127.0.0.1:{port}  (Ctrl-C or kill stops it; a running PPG session is stopped first)",
          flush=True)
    ble = asyncio.create_task(hub.ble_loop())
    async with server:
        await stop.wait()
        for task in (hub.ppg_task, hub.live_task, hub.breath_task):
            if task and not task.done():
                task.cancel()  # their finally blocks send the stop command while still connected
                await asyncio.gather(task, return_exceptions=True)
        ble.cancel()
        await asyncio.gather(ble, return_exceptions=True)
        server.close()
        for t in list(hub.sse_tasks):  # open event streams would otherwise block server shutdown
            t.cancel()
