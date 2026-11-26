"""Fail if a tracked file looks like it holds a device ID, personal detail or captured health data.

Usage: check_public.py [repo]     Exit code 1 on any finding.
Reports path, line and kind only, never the matching text, so its output is safe to share. It knows patterns, not
values, so it can miss things: also run compare_captures.py and gitleaks.
"""
from __future__ import annotations

import base64
import binascii
import datetime
import re
import subprocess
import sys
from pathlib import Path


def _epoch(year: int) -> int:
    return int(datetime.datetime(year, 1, 1, tzinfo=datetime.timezone.utc).timestamp())


EPOCH_FROM, EPOCH_TO = _epoch(2020), _epoch(2040)  # real ring clocks
RING_BASE = _epoch(2026)  # the ring's event log counts from here

# Checksums in lockfiles, Xcode object IDs and the licence texts are long hex or numbers, never ring data.
MACHINE_FILES = re.compile(r"(\.lock|\.pbxproj|\.storyboard|\.xcscheme|Package\.resolved|\.xcworkspacedata|\.metadata|\.svg"
                           r"|(^|/)LICENSE[^/]*|(^|/)licenses/[^/]+|gradle-wrapper\.properties)$")
# Number lists that are drawing coordinates or settings, not readings.
SHAPES = re.compile(r"(\.svg|/res/drawable[^/]*/[^/]+\.xml|/ui/[^/]+\.dart|\.html|make_icons\.swift)$")

H = "[0-9A-Fa-f]"
EDGE_L, EDGE_R = r"(?<![0-9A-Za-z_])", r"(?![0-9A-Za-z_])"
# The only UUIDs allowed: the ring's services, standard Bluetooth ones and MCUmgr. Others can identify a device.
UUID = re.compile(rf"(?i)(?:86f6{H}{{4}})?-f706-58a0-95b2-1fb9261e4dc7|(?:0000{H}{{4}})?-0000-1000-8000-00805f9b34fb"
                  r"|86f6xxxx-f706-58a0-95b2-1fb9261e4dc7|8d53dc1d-1db7-4cd3-868b-8a527460aa84|da2e7828-fbce-4e01-ae9e-261174997c48")
ANY_UUID = re.compile(rf"(?<!{H}){H}{{8}}-{H}{{4}}-{H}{{4}}-{H}{{4}}-{H}{{12}}(?!{H})")
OK_MARK = "public-ok:"  # on a line someone has looked at, with the reason; every use is counted and listed
MAC = re.compile(rf"(?<!{H}){H}{{2}}(?:([:\-. _])\1?{H}{{2}})(?:\1{{1,2}}{H}{{2}}){{4}}(?!{H})")
MAC_DOTTED = re.compile(rf"(?<![0-9A-Fa-f.]){H}{{4}}\.{H}{{4}}\.{H}{{4}}(?![0-9A-Fa-f.])")
MAC_BARE = re.compile(rf"(?<![0-9A-Za-z#]){H}{{12}}(?![0-9A-Za-z])")
MAC_0X = re.compile(rf"(?:0x{H}{{2}}[,\s]+){{5}}0x{H}{{2}}{EDGE_R}|(?:\\x{H}{{2}}){{6}}")
RING_NAME = re.compile(rf"(?i)UH[_-]{H}{{4,12}}(?![0-9A-Za-z])")
SERIAL = re.compile(r"(?i)(?<![A-Z0-9_-])[A-Z0-9]{2,10}(?:([-_])[A-Z0-9]{1,10}){2,8}(?![A-Z0-9_-])")
SERIAL_BARE = re.compile(r"(?i)\b(?:serial(?: ?(?:no|number))?|s/n|chip ?id)\b\W{1,4}(?=[A-Z0-9-]*\d)[A-Z0-9-]{6,}")
LONG_DIGITS = re.compile(r"(?<![0-9A-Za-z._])(?:\d_?){11,}\d(?![0-9A-Za-z.])")
INTEGER = re.compile(r"(?<![0-9A-Za-z_.])(?:0x([0-9A-Fa-f_]{8,11})|(\d[\d_]{6,15}))(?![0-9A-Za-z_]|\.\d)")
HEX_RUN = re.compile(rf"(?<![0-9A-Za-z_])(?:{H}{{2}}){{8,}}(?![0-9A-Za-z_])")
HEX_LIST = re.compile(rf"(?<![0-9A-Za-z_])(?:(?:0x)?{H}{{2}}(?:, ?|[ :_])){{7,}}(?:0x)?{H}{{2}}(?![0-9A-Za-z_])")
ESCAPES = re.compile(rf"(?:\\x{H}{{2}}){{6,}}")
DECIMALS = re.compile(r"(?<![\d.])(?:\d{1,3}(?:\.\d+)?,\s*){7,}\d{1,3}(?:\.\d+)?(?![\d.])")
BASE64 = re.compile(r"(?<![A-Za-z0-9+/=_.-])[A-Za-z0-9+/]{11,}={0,2}(?![A-Za-z0-9+/=_-])")
TIME = re.compile(r"\b20\d\d-\d\d-\d\d[T ]\d\d:\d\d|(?<![\d:])[0-2]?\d:[0-5]\d(?::[0-5]\d)?(?![\d:])")
LABELLED = re.compile(r"(?i)\b(?:hr|hrv|rmssd|sdnn|spo2|bpm|heart rate|skin temp\w*|battery)\b[^\n]{0,12}?\b\d{2,3}(?:\.\d+)?\b")
READING = re.compile(r"(?i)(?<![\w.])\d{2,4}(?:\.\d+)?\s*(?:bpm\b|beats per minute|°\s*c\b|deg c\b|millivolts|mv\b)"
                     r"|(?<![\w.])\d{2}\.\d{1,2}\s*c\b|(?i:spo2|hrv|rmssd|sdnn)(?:=| of | was )\d{2,3}\b")
EMAIL = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.(?!png\b|jpg\b|xcassets\b)[A-Za-z]{2,}")
HOME = re.compile(r"/Users/(?!Shared\b)[A-Za-z0-9._-]+|/home/[a-z][\w.-]*|[A-Z]:\\\\?Users\\")
PRIVATE_IP = re.compile(r"(?<![\d.])(?:10\.\d{1,3}|192\.168|172\.(?:1[6-9]|2\d|3[01])|100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7]))"
                        r"\.\d{1,3}\.\d{1,3}(?![\d.])")
TEAM = re.compile(r"(?i)(?:DEVELOPMENT_TEAM|DevelopmentTeam|team[ _-]?id)\W{1,6}(?!YOURTEAMID|\$)[A-Z0-9]{10}\b")
PLAIN_WORDS = re.compile(r"(?i)^(?:[a-z]+[-_])*[a-z]+$")


def hex_bytes(text: str) -> bytes:
    digits = re.sub(r"0x|\\x|[^0-9A-Fa-f]", "", text)
    return bytes.fromhex(digits[: len(digits) // 2 * 2])


def recent(value: int) -> bool:
    return EPOCH_FROM <= value < EPOCH_TO or EPOCH_FROM * 1000 <= value < EPOCH_TO * 1000


def bytes_kind(data: bytes) -> str | None:
    for i in range(len(data) - 3):
        if any(recent(int.from_bytes(data[i:i + 4], order)) for order in ("little", "big")):
            return "bytes holding a recent time"
    return "byte sequence" if len(data) >= 8 and len(set(data)) > 2 else None


def serial_like(text: str) -> bool:
    parts = re.split("[-_]", text)
    mixed = sum(bool(re.search(r"\d", x)) for x in parts)
    upper = text == text.upper() and bool(re.search("[A-Z]", text))
    # upper case with a digit group anywhere, or lower case with several coded groups
    return (upper and mixed >= 1 and len(parts) >= 3 and max(map(len, parts)) >= 4 and "_" not in text) or \
        (mixed >= 2 and len(parts) >= 4 and any(re.search(r"[A-Za-z]\d|\d[A-Za-z]", x) for x in parts)
         and bool(re.search(r"\d{4,}", text)))


def check_line(line: str, machine: bool = False, shapes: bool = False) -> set[str]:
    kinds: set[str] = set()
    bare = UUID.sub(" ", line)
    if EMAIL.search(bare):  # rule: email
        kinds.add("email address")
    if HOME.search(bare):  # rule: home
        kinds.add("home folder path")
    if PRIVATE_IP.search(bare):  # rule: ip
        kinds.add("private IP address")
    if TEAM.search(bare):  # rule: team
        kinds.add("Apple team ID")
    if RING_NAME.search(bare):  # rule: name
        kinds.add("ring name")
    if ANY_UUID.search(bare):  # rule: uuid
        kinds.add("unknown UUID")
    if SERIAL_BARE.search(bare):  # rule: labelled serial
        kinds.add("serial-like")
    if machine:
        if MAC.search(bare.replace(" ", ";")):
            kinds.add("MAC address")
        return kinds
    if any(len(set(hex_bytes(m[0]))) > 2 for m in MAC.finditer(bare)):  # rule: mac
        kinds.add("MAC address")
    if MAC_DOTTED.search(bare):  # rule: dotted mac
        kinds.add("MAC address")
    if any(len(set(hex_bytes(m[0]))) > 2 for m in MAC_BARE.finditer(bare)):  # rule: bare mac
        kinds.add("MAC address")
    if any(len(set(hex_bytes(m[0]))) > 2 for m in MAC_0X.finditer(bare)):  # rule: listed mac
        kinds.add("MAC address")
    if any(serial_like(m[0]) and not PLAIN_WORDS.match(m[0]) for m in SERIAL.finditer(bare)):  # rule: serial
        kinds.add("serial-like")
    if LONG_DIGITS.search(bare):  # rule: long number
        kinds.add("long number")
    for m in INTEGER.finditer(bare):  # rule: integer
        value = int(m[1].replace("_", ""), 16) if m[1] else int(m[2].replace("_", ""))
        if recent(value):
            kinds.add("recent Unix time")
        elif m[2] and 1_000_000 <= value < EPOCH_TO - RING_BASE and value % 1000:
            kinds.add("number that could be a ring time")
    for pattern in (HEX_RUN, HEX_LIST, ESCAPES):  # rule: hex
        for m in pattern.finditer(bare):
            if kind := bytes_kind(hex_bytes(m[0])):
                kinds.add(kind)
    if not shapes:
        for m in DECIMALS.finditer(bare):  # rule: decimals
            if len(set(re.findall(r"[\d.]+", m[0]))) > 2:
                kinds.add("list of numbers")
    for m in BASE64.finditer(bare):  # rule: base64
        text = m[0]
        if text.endswith("=") and bare[m.end():m.end() + 1] in tuple("\"'\\") and bare[m.start() - 1:m.start()] not in tuple("\"'"):
            continue  # attribute="..." in XML or keyword="..." in code
        mixed = re.search(r"\d", text) and re.search("[A-Z]", text) and re.search("[a-z]", text)
        if not ("=" in text or "+" in text or (mixed and len(text) >= 16 and len(re.findall(r"\d", text)) >= 3)):
            continue
        try:
            data = base64.b64decode(text, validate=True)
        except (binascii.Error, ValueError):
            continue
        if sum(not 0x20 <= b < 0x7F for b in data) >= 3:
            kinds.add("base64 data")
    if TIME.search(bare) and LABELLED.search(bare):  # rule: timestamped
        kinds.add("timestamped reading")
    if READING.search(bare):  # rule: reading
        kinds.add("reading")
    return set() if OK_MARK in line else kinds


def check_text(text: str, machine: bool = False, shapes: bool = False) -> list[tuple[int, str]]:
    hits = [(n, k) for n, line in enumerate(text.splitlines(), 1) for k in sorted(check_line(line, machine, shapes))]
    if not machine:
        # literals and lists split over several lines
        joined = "\n".join(x for x in text.splitlines() if OK_MARK not in x)
        joined = re.sub(r"""["']\s*\n\s*["']""", "", joined)
        joined = re.sub(r",\s*\n\s*(?=\d|0x)", ", ", joined)
        seen = {k for _, k in hits}
        for line in joined.splitlines():
            hits += [(0, f"{k} over several lines") for k in sorted(check_line(line, machine, shapes) - seen)]  # rule: split
    return hits


def check_bytes(data: bytes) -> set[str]:
    """Binary files: IDs, paths and the like stored as 8-bit or 16-bit text inside them."""
    runs = re.findall(rb"[\x20-\x7e]{8,}", data)
    runs += [m.replace(b"\0", b"") for m in re.findall(rb"(?:[\x20-\x7e]\0){8,}|(?:\0[\x20-\x7e]){8,}", data)]  # rule: utf-16
    keep = ("MAC address", "ring name", "serial-like", "email address", "home folder path", "private IP address", "Apple team ID")
    out = {k for r in runs for k in check_line(r.decode("ascii"), machine=True) if k in keep}
    return out | {"serial-like" for r in runs for m in SERIAL.finditer(r.decode("ascii")) if serial_like(m[0]) and len(m[0]) >= 14}


def tracked_files(repo: Path) -> list[str]:
    """Files git tracks, or every file when this isn't a git checkout (a downloaded archive, say)."""
    r = subprocess.run(["git", "-C", str(repo), "ls-files", "-z"], capture_output=True)
    if r.returncode == 0 and (repo / ".git").exists():
        return [n for n in r.stdout.decode().split("\0") if n]
    print("not a git checkout: checking every file", file=sys.stderr)
    skip = {".git", ".dart_tool", "build", "__pycache__", ".venv", ".gradle", "Pods", "ephemeral"}
    return sorted(str(f.relative_to(repo)) for f in repo.rglob("*") if f.is_file() and not skip & set(f.relative_to(repo).parts))


def main() -> int:
    repo = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    found = files = 0
    names = tracked_files(repo)
    for name in names:
        path = repo / name
        if not path.is_file():
            continue
        files += 1
        data = path.read_bytes()
        hits: list[tuple[int, str]] = [(0, k + " in file name") for k in sorted(check_line(name, True))]
        try:
            if b"\0" in data:
                raise ValueError
            hits += check_text(data.decode("utf-8"), bool(MACHINE_FILES.search(name)), bool(SHAPES.search(name)))
        except ValueError:
            hits += [(0, k) for k in sorted(check_bytes(data))]
        for line, kind in hits:
            found += 1
            print(f"{name}:{line}: {kind}")
    for name in names:
        path = repo / name
        if name != "scripts/check_public.py" and path.is_file():
            count = path.read_bytes().count(OK_MARK.encode())
            if count:
                print(f"reviewed lines in {name}:{count}")
    print(f"checked {files} files: {found} findings")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
