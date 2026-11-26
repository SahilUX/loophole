"""Command line for the ring. Run `python -m loophole_ring --help`."""
from __future__ import annotations

import argparse
import asyncio
import sys
import time

from bleak import BleakScanner
from bleak.exc import BleakError

from . import protocol as p
from .client import Ring, RingNotFound
from .hr import estimate_series, resample


def _ts(t: int) -> str:
    return time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(t))


async def _scan(seconds: float) -> None:
    found = await BleakScanner.discover(timeout=seconds, return_adv=True)
    for dev, adv in found.values():
        n = adv.local_name or dev.name or ""
        if n.startswith("UH_"):
            print(n, f"rssi={adv.rssi}")


async def _run(args: argparse.Namespace) -> None:
    from .web import load_choice  # the ring picked in the dashboard, so a nearby one is never used by accident

    name = args.name or load_choice()
    if not name:
        sys.exit("which ring? Pass --name with a name from `loophole-ring scan`, or pick one in the dashboard")
    async with Ring.connect(name, args.scan_seconds) as ring:
        print("connected", file=sys.stderr)
        if args.cmd == "battery":
            s = await ring.state()
            print(f"battery {s.battery_pct}%  {s.microamps / 1000:+.2f} mA  {s.millivolts} mV  {s.temp_c} C  "
                  f"{'charging' if s.charge_state == 3 else 'not charging'}  capacity {s.cell_mah} mAh")
        elif args.cmd == "time":
            t = await ring.time()
            print(f"ring {_ts(t)}  host {_ts(int(time.time()))}  drift {t - int(time.time()):+d} s")
        elif args.cmd == "history":
            first, last = await ring.history_bounds()
            print(f"history indices: earliest={first} latest={last}")
            if args.raw and last is not None:
                start = max(first or 0, last - args.raw + 1)
                for raw in await ring.recordings(start):
                    print(raw.hex())
                    try:
                        for r in p.parse_recordings(raw):
                            print("  ", r)
                    except p.ProtocolError as e:
                        print("   unparsed:", e)
        elif args.cmd == "mode":
            r = await ring.set_mode(args.mode)
            print(f"mode {args.mode}: result 0x{r.result:02x} detail 0x{r.detail:02x} ({'ok' if r.ok else 'FAILED'})")
        elif args.cmd in ("hr", "ppg"):
            frames: list[p.PpgFrame] = []
            async with ring.ppg_stream() as q:
                end = time.monotonic() + args.seconds
                while (left := end - time.monotonic()) > 0:
                    try:
                        f = await asyncio.wait_for(q.get(), min(left, 3.0))
                    except asyncio.TimeoutError:
                        continue
                    frames.append(f)
                    if args.cmd == "ppg":
                        print(f"tick={f.tick_ms} first={f.samples[0]}")
            print(f"{len(frames)} PPG frames, LEDs stopped", file=sys.stderr)
            if args.cmd == "hr":
                rows = list(estimate_series(resample(frames, 0)))
                for t_end, e in rows:
                    shown = f"{e.bpm:5.1f} BPM" if e.bpm else "   -- (no reliable reading)"
                    print(f"t<={t_end:4.0f}s {shown}   dft={e.dft_bpm} acf={e.acf_bpm} q={e.quality}")
                good = [e.bpm for _, e in rows if e.bpm]
                print(f"heart rate: {sorted(good)[len(good) // 2]:.0f} BPM (median of {len(good)} windows)"
                      if good else "heart rate: no reliable reading (ring on a finger? keep still)")


def main(argv: list[str] | None = None) -> None:
    ap = argparse.ArgumentParser(prog="loophole-ring", description="Talk to an Ultrahuman ring without the app.")
    ap.add_argument("--name", help="exact advertised name, e.g. UH_XXXXXXXXXXXX (default: the ring chosen in the dashboard; there is no other default)")
    ap.add_argument("--scan-seconds", type=float, default=15.0)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("scan", help="list advertising rings")
    w = sub.add_parser("web", help="local live dashboard on http://127.0.0.1:PORT")
    w.add_argument("--port", type=int, default=8765)
    sub.add_parser("battery", help="battery %% from the state record")
    sub.add_parser("time", help="ring clock vs this computer")
    h = sub.add_parser("history", help="history index range (opcodes 07/08)")
    h.add_argument("--raw", type=int, default=0, metavar="N", help="also fetch and print the last N records (04)")
    m = sub.add_parser("mode", help="battery mode: turbo, chill or critical")
    m.add_argument("mode", choices=["turbo", "chill", "critical"])
    for name, help_ in (("hr", "measure heart rate from PPG (ring on a finger, keep still)"),
                        ("ppg", "print raw PPG frames")):
        s = sub.add_parser(name, help=help_)
        s.add_argument("--seconds", type=float, default=30.0 if name == "hr" else 10.0)
        s.add_argument("--yes-start-leds", action="store_true", help="required: turns the ring's LEDs on")
    args = ap.parse_args(argv)

    if args.cmd in ("hr", "ppg") and not args.yes_start_leds:
        ap.error("this turns the ring's LEDs on and uses battery: add --yes-start-leds")
    try:
        if args.cmd == "scan":
            asyncio.run(_scan(args.scan_seconds))
        elif args.cmd == "web":
            from .web import serve
            asyncio.run(serve(args.name, args.port))
        else:
            asyncio.run(_run(args))
    except RingNotFound as e:
        sys.exit(str(e))
    except (BleakError, asyncio.TimeoutError) as e:  # its text can name the ring or its address
        sys.exit(f"Bluetooth error: {type(e).__name__}")
