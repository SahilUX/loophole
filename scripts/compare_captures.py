"""Compare tracked files with your own captures folder: text, bytes, and the ways bytes get written down.

Usage: compare_captures.py CAPTURES [repo]     Exit code 1 on any match.
IDs (ring names, serials, chip ID, addresses), byte sequences and record values are read from the captures at run time.
Only paths, line numbers and kinds are printed, never a value. Looks for hex, spaced hex, \\x escapes, 0x and decimal
lists, base64, whole integers and raw bytes, in both byte orders.

Text in screenshots is read on macOS (Vision) for IDs only. Only files directly in the folder are read, not subfolders.
"""
from __future__ import annotations

import base64
import binascii
import json
import re
import shutil
import struct
import subprocess
import sys
from collections.abc import Iterator
from pathlib import Path

LONG, SHORT = 8, 4  # bytes: any sequence, and sequences checked only where the tree writes bytes down
H = "[0-9A-Fa-f]"
# Checksums, object IDs and licence texts: four random bytes there mean nothing, so only longer sequences count.
MACHINE_FILES = re.compile(r"(\.lock|\.pbxproj|\.storyboard|Package\.resolved|\.metadata|(^|/)LICENSE[^/]*|(^|/)licenses/[^/]+)$")
IMAGES = (".png", ".jpg", ".jpeg")
# Public UUIDs: the ring's services (the four x differ), standard Bluetooth ones, and MCUmgr.
UUIDS = ("86f6xxxx-f706-58a0-95b2-1fb9261e4dc7", "0000xxxx-0000-1000-8000-00805f9b34fb",
         "8d53dc1d-1db7-4cd3-868b-8a527460aa84", "da2e7828-fbce-4e01-ae9e-261174997c48")
UUID_BYTES = [[None if h == "xx" else int(h, 16) for h in re.findall("..", u.replace("-", ""))] for u in UUIDS]
RING_NAME = re.compile(rf"(?i)UH_{H}{{12}}")
SERIAL = re.compile(r"(?<![A-Z0-9-])[A-Z0-9]{2,8}(?:-[A-Z0-9]{2,8}){4,7}(?![A-Z0-9-])")
MAC = re.compile(rf"(?<!{H}){H}{{2}}(?::{H}{{2}}){{5}}(?!{H})")
NUMBER = r"-?\d+(?:\.\d+)?"


# --- reading bytes and numbers out of text -------------------------------------------------------------------
def digits(text: str) -> bytes:
    d = re.sub(r"0x|\\x|[^0-9A-Fa-f]", "", text)
    return bytes.fromhex(d[: len(d) // 2 * 2])


def written_bytes(text: str) -> Iterator[bytes]:
    """Every byte string the text spells out."""
    joined = re.sub(r"""["']\s*\n\s*["']""", "", text)
    for t in {text, joined}:
        for m in re.finditer(rf"(?<![0-9A-Za-z])(?:0x)?((?:{H}{{2}}){{4,}})(?![0-9A-Za-z])", t):  # rule: hex run
            yield bytes.fromhex(m[1])
        for m in re.finditer(rf"(?:(?:0x)?{H}{{2}}[,\s:_-]{{1,3}}){{3,}}(?:0x)?{H}{{2}}", t):  # rule: hex list
            yield digits(m[0])
        for m in re.finditer(rf"(?:\\x{H}{{2}}){{3,}}", t):  # rule: escapes
            yield digits(m[0])
        for m in re.finditer(r"(?:\d{1,3}\s*,\s*){3,}\d{1,3}(?![\d.])", t):  # rule: decimal list
            values = [int(x) for x in re.findall(r"\d+", m[0])]
            if max(values) < 256:
                yield bytes(values)
    for m in re.finditer(r"(?<![\w.])(?:0x([0-9A-Fa-f_]{7,16})|(\d[\d_]{6,19}))(?![\w.])", text):  # rule: integers
        value = int(m[1].replace("_", ""), 16) if m[1] else int(m[2].replace("_", ""))
        yield value.to_bytes(8 if value >> 32 else 4, "little")


def base64_bytes(text: str) -> Iterator[bytes]:
    """Decoded base64; ordinary words decode too, so only long sequences are compared with this."""
    for m in re.finditer(r"(?<![A-Za-z0-9+/])[A-Za-z0-9+/]{11,}={0,2}", text):
        s = m[0].rstrip("=")
        try:
            yield base64.b64decode(s + "=" * (-len(s) % 4))
        except (binascii.Error, ValueError):
            continue


def windows(data: bytes, n: int) -> set[bytes]:
    return {data[i:i + n] for i in range(len(data) - n + 1)}


def public_uuid(w: bytes) -> bool:
    return any(all(x is None or x == y for x, y in zip(v[i:i + len(w)], w))
               for u in UUID_BYTES for v in (u, u[::-1]) for i in range(len(u) - len(w) + 1)
               if sum(x is not None for x in v[i:i + len(w)]) >= 2)


def generic(w: bytes) -> bool:
    """Too plain to identify anything: padding, counters, printable words, public UUIDs, and in short sequences
    anything mostly zero or 0xFF."""
    if len(set(w)) <= (3 if len(w) >= LONG else 2):
        return True
    if len({(b - a) & 0xFF for a, b in zip(w, w[1:])}) == 1:
        return True
    if all(0x20 <= b < 0x7F or b in (9, 10, 13) for b in w):
        return True
    if len(w) < LONG and sum(b in (0, 1, 0xFF) for b in w) >= len(w) // 2:
        return True
    return public_uuid(w)


# --- reading the captures ------------------------------------------------------------------------------------
def btsnoop(data: bytes) -> Iterator[bytes]:
    """HCI packets in a btsnoop file."""
    i = 16
    while i + 24 <= len(data):
        n = struct.unpack_from(">I", data, i + 4)[0]
        yield data[i + 24:i + 24 + n]
        i += 24 + n


def packet_addresses(pkt: bytes) -> Iterator[bytes]:
    if pkt[:2] == b"\x04\x3e" and len(pkt) > 15 and pkt[3] in (0x01, 0x0A):
        yield pkt[9:15][::-1]
    if pkt[:2] == b"\x04\x3e" and len(pkt) > 13 and pkt[3] in (0x02, 0x0D):
        yield pkt[7:13][::-1]
        yield pkt[8:14][::-1]
    if pkt[:3] == b"\x01\x0d\x20" and len(pkt) > 16:
        yield pkt[10:16][::-1]
    if pkt[:2] in (b"\x04\x03", b"\x04\x0f") and len(pkt) > 12:
        yield pkt[6:12][::-1]


def ocr(images: list[Path]) -> str:
    """Text in screenshots, macOS only."""
    if not images or sys.platform != "darwin" or not shutil.which("swift"):
        return ""
    code = """
import Foundation
import Vision
import AppKit
for p in CommandLine.arguments.dropFirst() {
  guard let i = NSImage(contentsOfFile: p)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
  let r = VNRecognizeTextRequest(); r.usesLanguageCorrection = false
  try? VNImageRequestHandler(cgImage: i).perform([r])
  for o in r.results ?? [] { if let t = o.topCandidates(1).first { print(t.string) } }
}
"""
    r = subprocess.run(["swift", "-", *map(str, images)], input=code, capture_output=True, text=True)
    if r.returncode:
        print("could not read the screenshots: their text is not compared")
    return r.stdout


class Captures:
    def __init__(self, root: Path):
        files = [f for f in sorted(root.iterdir()) if f.is_file()]
        images = [f for f in files if f.suffix.lower() in IMAGES]
        self.files = [f for f in files if f.suffix.lower() not in IMAGES]
        self.images = len(images)
        self.long: set[bytes] = set()
        self.short: set[bytes] = set()
        self.names: set[str] = set()
        self.serials: set[str] = set()
        self.macs: set[bytes] = set()
        self.chips: set[bytes] = set()
        self.rows: set[tuple[str, ...]] = set()  # four neighbouring values of a synced record
        self.times: set[int] = set()
        for f in self.files:
            self.read(f)
        self.ids_in(ocr(images))  # rule: screenshots
        self.macs |= {bytes.fromhex(n[3:]) for n in self.names}
        self.macs = {m for m in self.macs if len(set(m)) > 3}
        self.long = {w for w in self.long if not generic(w)}
        self.short = {w for w in self.short if not generic(w)}
        self.chips = {c for c in self.chips if len(set(c)) > 2}

    def ids_in(self, text: str) -> None:
        self.names |= {n.upper() for n in RING_NAME.findall(text)}
        self.serials |= {s for s in SERIAL.findall(text) if re.search(r"\d", s) and re.search(r"[A-Z]", s)}
        self.macs |= {bytes.fromhex(m.replace(":", "")) for m in MAC.findall(text)}

    def blob(self, b: bytes) -> None:
        self.long |= windows(b, LONG)
        self.short |= windows(b, SHORT)
        self.ids_in(b.decode("latin-1"))
        i = b.find(b"\x79\x00")
        while i >= 0:
            page, body = b[i + 3:i + 5], b[i + 5:]
            if page == b"\x1e\x00" and len(body) >= 8:
                self.chips.add(body[:8])
            if page == b"\x1c\x00" and len(body) >= 81:
                self.macs |= {body[1 + s * 8 + 2:1 + s * 8 + 8] for s in range(10)}
            i = b.find(b"\x79\x00", i + 1)

    def read(self, f: Path) -> None:
        data = f.read_bytes()
        text = data.decode("latin-1")
        if data[:8] == b"btsnoop\0":
            for pkt in btsnoop(data):
                self.blob(pkt)
                self.macs |= set(packet_addresses(pkt))
            return
        if b"\0" in data[:4096]:
            self.blob(data)
            return
        self.ids_in(text)
        for b in written_bytes(text):
            self.blob(b)
        for line in text.splitlines():  # rule: record values
            try:
                row = json.loads(line)
            except ValueError:
                continue
            if isinstance(row, list):
                values = [str(x) for x in row]
                self.rows |= {tuple(values[i:i + 4]) for i in range(1, len(values) - 3)}
                self.times |= {x for x in row if isinstance(x, int) and x > 1_000_000_000}

    def row_kinds(self, text: str) -> bool:
        for run in re.findall(rf"{NUMBER}(?:[,\s\])(]+{NUMBER}){{3,}}", text):
            v = [x.rstrip("0").rstrip(".") if "." in x and x.endswith("0") and not x.endswith(".0") else x
                 for x in re.findall(NUMBER, run)]
            for i in range(len(v) - 3):
                w = tuple(v[i:i + 4])
                if w in self.rows and len(set(w)) >= 3 and sum(len(x) >= 2 for x in w) >= 3:
                    return True
        return False


def encodings(value: bytes) -> Iterator[bytes]:
    """The ways an ID could be written in a file, lower case."""
    for v in (value, value[::-1]):
        for sep in ("", ":", "-", " ", ", ", "_", r"\x", ", 0x", ",0x"):  # rule: id hex
            yield sep.join(f"{b:02x}" for b in v).encode()
        for sep in (",", ", "):  # rule: id decimal
            yield sep.join(str(b) for b in v).encode()
        for pad in range(3):  # rule: id base64
            enc = base64.b64encode(bytes(pad) + v).rstrip(b"=")
            yield enc[(pad * 8 + 5) // 6: len(enc) - 1].lower()
        yield str(int.from_bytes(v, "little")).encode()  # rule: id integer


def compare(cap: Captures, name: str, data: bytes) -> list[tuple[int, str]]:
    out: list[tuple[int, str]] = []
    low = data.lower()
    plain = [low, low.replace(b"\0", b"")] if b"\0" in data else [low]
    texts = {"ring name": {n.lower() for n in cap.names} | {n[3:].lower() for n in cap.names},
             "serial": {s.lower() for s in cap.serials} | {s.replace("-", "").lower() for s in cap.serials},
             "part of a serial": {p.lower() for s in cap.serials for p in s.split("-") if len(p) >= 5 and re.search(r"\d", p)}}
    for kind, values in texts.items():
        if any(v.encode() in t for v in values for t in plain):  # rule: text ids
            out.append((0, kind + " as text"))
    for kind, ids in (("chip ID", cap.chips), ("address", cap.macs)):
        if any(v in data or v[::-1] in data for v in ids):  # rule: raw ids
            out.append((0, kind + " as bytes"))
        if any(e in low for v in ids for e in encodings(v)):  # rule: written ids
            out.append((0, kind + " written out"))
    if windows(data, LONG) & cap.long:  # rule: raw bytes
        out.append((0, "captured bytes, raw"))
    if b"\0" in data:
        return out
    text = data.decode("utf-8", "replace")
    bodies = [(0, text)] + list(enumerate(text.splitlines(), 1))
    short_too = not MACHINE_FILES.search(name)
    hits: dict[str, list[int]] = {}
    for n, body in bodies:
        if any(windows(v, LONG) & cap.long for b in base64_bytes(body) for v in (b, b[::-1])):  # rule: base64
            hits.setdefault("captured bytes, base64", []).append(n)
        for b in written_bytes(body):
            for v in (b, b[::-1]):  # rule: reversed
                if windows(v, LONG) & cap.long:
                    hits.setdefault("captured bytes, 8 or more", []).append(n)
                if short_too and windows(v, SHORT) & cap.short:  # rule: short
                    hits.setdefault("captured bytes, 4 to 7", []).append(n)
        if cap.row_kinds(body):  # rule: rows
            hits.setdefault("values of a synced record", []).append(n)
        if any(int(x.replace("_", "")) in cap.times for x in re.findall(r"(?<!\d)\d[\d_]{9,12}(?!\d)", body)):  # rule: times
            hits.setdefault("time of a synced record", []).append(n)
    for kind, lines in hits.items():
        out += [(n, kind) for n in sorted({n for n in lines if n} or {0})]
    return out


# Short sequences that are protocol constants, checked by hand: commands and headers every ring of this kind uses.
def constants(allow: Path) -> set[bytes]:
    if not allow.is_file():
        return set()
    lines = [x.split("#")[0].strip() for x in allow.read_text().splitlines()]
    return {bytes.fromhex(x) for x in lines if x}


def tracked_files(repo: Path) -> list[str]:
    """Files git tracks, or every file when this isn't a git checkout (a downloaded archive, say)."""
    r = subprocess.run(["git", "-C", str(repo), "ls-files", "-z"], capture_output=True)
    if r.returncode == 0 and (repo / ".git").exists():
        return [n for n in r.stdout.decode().split("\0") if n]
    print("not a git checkout: checking every file", file=sys.stderr)
    skip = {".git", ".dart_tool", "build", "__pycache__", ".venv", ".gradle", "Pods", "ephemeral"}
    return sorted(str(f.relative_to(repo)) for f in repo.rglob("*") if f.is_file() and not skip & set(f.relative_to(repo).parts))


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    root, repo = Path(sys.argv[1]).resolve(), Path(sys.argv[2] if len(sys.argv) > 2 else ".").resolve()
    cap = Captures(root)
    if not cap.files:
        print("no capture files found")
        return 2
    allow = constants(repo / "scripts" / "protocol_constants.txt")
    cap.short -= {w for c in allow for w in windows(c, SHORT)} | {w[::-1] for c in allow for w in windows(c, SHORT)}
    print(f"{len(cap.files)} capture files, {cap.images} screenshots: {len(cap.long)} long and {len(cap.short)} short sequences, "
          f"{len(cap.rows)} record rows, {len(cap.names)} ring names, {len(cap.serials)} serials, {len(cap.chips)} chip IDs, "
          f"{len(cap.macs)} addresses")
    found = 0
    for name in tracked_files(repo):
        if not (repo / name).is_file():
            continue
        for line, kind in compare(cap, name, (repo / name).read_bytes()):
            found += 1
            print(f"{name}{':' + str(line) if line else ''}: {kind}")
    print(f"{found} findings")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
