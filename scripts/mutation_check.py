"""Plant deliberate bugs in a temporary copy and check that the tests catch each one.

Usage: mutation_check.py [python|dart|all]     Exit code 1 if a bug survives. Python to use: the one running this.
"""
from __future__ import annotations

import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
PY = "loophole_ring/protocol.py"
WEB = "loophole_ring/web.py"
CLIENT = "loophole_ring/client.py"
HTML = "loophole_ring/web.html"
CHECK = "scripts/check_public.py"
COMPARE = "scripts/compare_captures.py"
DART = "app/lib/ring/protocol.dart"
BATTERY = "app/lib/analysis/battery.dart"

PYTHON_BUGS = [
    (PY, "((c << 1) ^ 0x1021)", "((c << 1) ^ 0x8005)"),
    (PY, "OP_CHILL_ON, OP_CHILL_OFF = 0xFB, 0xFC", "OP_CHILL_ON, OP_CHILL_OFF = 0xFC, 0xFB"),
    (PY, "OP_SPO2_ON, OP_SPO2_OFF = 0xD1, 0xD2", "OP_SPO2_ON, OP_SPO2_OFF = 0xD2, 0xD1"),
    (PY, "OP_CRITICAL_ON, OP_CRITICAL_OFF = 0xD3, 0xD4", "OP_CRITICAL_ON, OP_CRITICAL_OFF = 0xD4, 0xD3"),
    (CLIENT, '"chill": (p.OP_CRITICAL_OFF, p.OP_CHILL_ON)', '"chill": (p.OP_CRITICAL_ON, p.OP_CHILL_ON)'),
    (CLIENT, '"turbo": (p.OP_CRITICAL_OFF, p.OP_CHILL_OFF)', '"turbo": (p.OP_CRITICAL_OFF, p.OP_CHILL_ON)'),
    (PY, '"<IBBBBIffIHHBBH", r.data, i * 32', '"<IBBBBIffIHHHBB", r.data, i * 32'),
    (PY, '"<IBBBBIffIHHBBH", r.data, i * 32', '"<IBBBBIffIHHBBH", r.data, i * 31'),
    (PY, 'unpack_from("<i", raw, 1)', 'unpack_from("<I", raw, 1)'),
    (PY, "raw[5], raw[6], be(7)", "raw[6], raw[5], be(7)"),
    (PY, "be(15), be(17)", "be(16), be(17)"),
    (PY, 'struct.Struct("<IBBBBHf")', 'struct.Struct(">IBBBBHf")'),
    (PY, 'struct.Struct("<IBBBBf")', 'struct.Struct("<IBBBxf")'),
    (PY, "payload = raw[3:3 + _u16(raw, 1)]", "payload = raw[3:]"),
    (PY, "len(raw) != 161 or raw[0] != 0x90", "raw[0] != 0x90"),
    (PY, "len(raw) != 161 or raw[0] != 0x90", "len(raw) != 161"),
    (PY, "15 + i * 12", "14 + i * 12"),
    (PY, "P[i * 8 + 3:i * 8 + 9]", "P[i * 8 + 1:i * 8 + 9]"),
    (PY, "P[i * 8 + 3:i * 8 + 9]", "P[i * 8 + 4:i * 8 + 9]"),
    (PY, "P[i * 8 + 3:i * 8 + 9]", "P[i * 8 + 3:i * 8 + 8]"),
    (PY, 'out["firmware"] = hex(_u32(P, 20))', 'out["firmware"] = hex(_u32(P, 24))'),
    (PY, "newest_record=_u16(P, 12)", "newest_record=_u16(P, 14)"),
    (PY, "(w >> 22) & 0xFF", "(w >> 22) & 0x7F"),
    (PY, "(w >> 22) & 0xFF", "(w >> 21) & 0xFF"),
    (PY, "(w & 0x3FFFFF)", "(w & 0x1FFFFF)"),
    (PY, "(w & 0x3FFFFFFF)", "(w & 0x1FFFFFFF)"),
    (PY, "w >> 30 & 1", "w >> 29 & 1"),
    (PY, "86: \"Battery critically low\"", "86: \"Charging\""),
    (PY, "raw[18], \"critical_on\"", "raw[17], \"critical_on\""),
    (PY, '"oldest": _u16(r.data, 2)', '"oldest": _u16(r.data, 0)'),
    (PY, '(8, (9000).to_bytes(2, "big"))', '(8, (9000).to_bytes(2, "little"))'),
    (PY, "return packet == ppg_start_packet()", "return True"),
    (PY, "        return not rest\n", "        return True\n"),
    (PY, "if op == OP_HISTORY:\n        return len(rest) == 2", "if op == OP_HISTORY:\n        return True"),
    (PY, "OP_EVENT_LOG, OP_CLOCK_MANAGEMENT, OP_RECORD_INTERVAL, OP_DEBUG_PAGE})", "OP_EVENT_LOG, OP_RECORD_INTERVAL, OP_DEBUG_PAGE})"),
    (PY, "OP_EVENT_LOG, OP_CLOCK_MANAGEMENT, OP_RECORD_INTERVAL, OP_DEBUG_PAGE})", "OP_EVENT_LOG, OP_CLOCK_MANAGEMENT, OP_DEBUG_PAGE})"),
    (PY, "OP_EVENT_LOG, OP_CLOCK_MANAGEMENT, OP_RECORD_INTERVAL, OP_DEBUG_PAGE})", "OP_CLOCK_MANAGEMENT, OP_RECORD_INTERVAL, OP_DEBUG_PAGE})"),
    (PY, 'if not out["crc_ok"]:', "if False:"),
    (PY, 'if out["valid"] and crc_ok(raw):', 'if out["valid"]:'),
    (PY, 'if b in KNOWN_OPCODES else "other"', "if True else \"other\""),
    (PY, "got {len(raw)}\")", "got {raw.hex()}\")"),
    (WEB, "if len(raw) < 5 or not p.crc_ok(raw):", "if len(raw) < 5:"),
    (WEB, "return n == 9 and head", "return head"),
    (WEB, "return n == 7 and head", "return head"),
    (WEB, "return n == 11 and head", "return head"),
    (WEB, " and raw[3:5] == raw[7:9]", ""),
    (WEB, "return n == 8 and raw[1:5]", "return raw[1:5]"),
    (WEB, r'raw[1:5] == b"\x00\x01\x01\x00"', "True"),
    (WEB, "    return False\n\n\nACTIONS", "    return True\n\n\nACTIONS"),
    (WEB, 'if char == "resp" and understood(raw)', "if understood(raw)"),
    (WEB, 'if p.is_allowed(raw) else f"[{len(raw)} bytes hidden]"', "if True else \"\""),
    (WEB, "(15, 23), (29, 33))", "(15, 24), (29, 33))"),
    (WEB, "STATE_FIELDS = ((0, 11),", "STATE_FIELDS = ((0, 12),"),
    (WEB, "shown = raw[:3] if ack", "shown = raw if ack"),
    (WEB, "else raw[:1] if char", "else raw[:8] if char"),
    (WEB, "and raw[0] in p.KNOWN_OPCODES else", "else"),
    (WEB, "{type(e).__name__ if e else 'unknown'}", "{e!r}"),
    (WEB, "loop.set_exception_handler(quiet)", "pass"),
    (WEB, "microamps=s.microamps", "current_ua=s.microamps"),
    (WEB, 'v.strip(" \\t")', "v.strip()"),
    ("loophole_ring/cli.py", "Bluetooth error: {type(e).__name__}", "Bluetooth error: {e}"),
    (HTML, "m.microamps == null", "m.current_ua == null"),
    (HTML, "SDNN ${m.sdnn}", "SDNN ${m.sdnn_ms}"),
    (HTML, "`Ring ${r.ring}`", "`Ring ${r.name}`"),
    (WEB, 'hex=safe_hex("rx", "resp", raw))', "hex=raw.hex())"),
    (WEB, "hex=safe_hex(direction, char, raw)", "hex=raw.hex()"),
    (WEB, '"ring": self.number(n)', '"ring": self.number(n), "name": n'),
    (WEB, 'text=f"scan failed: {type(e).__name__}"', 'text=f"scan failed: {e!r}"'),
    (WEB, 'text=f"Bluetooth error: {type(e).__name__}"', 'text=f"Bluetooth error: {e!r}"'),
    (WEB, 'if headers.get("host", "").lower() not in hosts:', "if False:"),
    (WEB, 'return origin.lower() in {f"http://{h}" for h in hosts}', "return True"),
    (WEB, 'return method == "GET" and headers', "return headers"),
    (WEB, 'in ("same-origin", "none")', 'in ("same-origin", "none", "cross-site", "same-site")'),
    (WEB, "len(headers) != len(pairs) or ", ""),
    (WEB, "1 <= int(pick)", "0 <= int(pick)"),
    (WEB, "CHOICE_FILE.chmod(0o600)  # the ring", "CHOICE_FILE.chmod(0o644)  # the ring"),
    (WEB, "CHOICE_FILE.chmod(0o600)  # written", "pass  # written"),
    ("loophole_ring/cli.py", "    if not name:\n", "    if False:\n"),
    (CLIENT, 'return (adv.local_name or device.name or "") == name', 'return (adv.local_name or device.name or "").startswith("UH_")'),
    (CHECK, 'if r.returncode == 0 and (repo / ".git").exists():', "if True:"),
    (CHECK, '"__pycache__", ".venv"', '"__pycache__"'),
]
DART_BUGS = [
    (DART, "((c << 1) ^ 0x1021)", "((c << 1) ^ 0x8005)"),
    (DART, "spo2On = 0xD1", "spo2On = 0xD2"),
    (DART, "chillOn = 0xFB", "chillOn = 0xFC"),
    (DART, "chill([Op.criticalOff, Op.chillOn])", "chill([Op.criticalOn, Op.chillOn])"),
    (DART, "motion: _u16(b, 24)", "motion: _u16(b, 26)"),
    (DART, "skinTempC: _f32(b, 12)", "skinTempC: _f32(b, 16)"),
    (DART, "secondTempC: _f32(b, 16)", "secondTempC: _f32(b, 12)"),
    (DART, "index: _u16(b, 30)", "index: _u16(b, 29)"),
    (DART, "byte29: b[29]", "byte29: b[28]"),
    (DART, "cellMah: be(15)", "cellMah: be(16)"),
    (DART, "timestamp: ts == 0 ? null : ts", "timestamp: ts"),
    (DART, "w >> 22) & 0xFF", "w >> 22) & 0x7F"),
    (DART, "(w & 0x3FFFFF)", "(w & 0x1FFFFF)"),
    (DART, "86 => 'Battery critically low'", "86 => 'Charging'"),
    (DART, "raw[18] != 0", "raw[17] != 0"),
    (DART, "hr >= 25", "hr >= 24"),
    (DART, "spo2 <= 100", "spo2 <= 101"),
    (DART, "skinTempC! <= 44", "skinTempC! <= 45"),
    (DART, "_u32(p, 20)", "_u32(p, 16)"),
    (DART, "_oneByte.contains(op)) return p.length == 1", "_oneByte.contains(op)) return true"),
    (DART, "Op.history => p.length == 3", "Op.history => true"),
    (DART, "_f32(b, 10)", "_f32(b, 9)"),
    (DART, "b[7], _f32(b, 8)", "b[6], _f32(b, 8)"),
    (DART, "if ((i + 1) * 32 <= r.data.length)", "if (true)"),
    (DART, "got opcode ${r.opcode}", "got ${hex(raw)} ${r.opcode}"),
    (DART, "{Op.eventLog, 0x10, 0x14, Op.debugPage}", "{Op.eventLog, 0x14, Op.debugPage}"),
    (DART, "{Op.eventLog, 0x10, 0x14, Op.debugPage}", "{Op.eventLog, 0x10, Op.debugPage}"),
    ("app/lib/ring/ring_controller.dart", "'Sync failed (${errorKind(e)}).'", "'Sync failed: $e'"),
    ("app/lib/ring/ring_controller.dart", "e.runtimeType.toString()", "e.toString()"),
    ("app/lib/ring/ring_controller.dart", "Can\\'t reach your ring", "Can\\'t reach $ringName"),
    ("app/lib/screens/today_screen.dart", "'Recovery (experimental)'", "'Recovery'"),
    ("app/android/app/src/main/res/xml/data_extraction_rules.xml", '<cross-platform-transfer platform="ios">\n        <exclude domain="root" path="." />', '<cross-platform-transfer platform="ios">'),
    ("app/android/app/src/main/AndroidManifest.xml", 'android:allowBackup="false"', 'android:allowBackup="true"'),
    (BATTERY, "if (cellMah == null) return", "if (cellMah == null && samples.isEmpty) return"),
]


def check_bugs() -> list[tuple[str, str, str]]:
    """Switch off each named rule in the release checks."""
    out = []
    for f in (CHECK, COMPARE):
        for line in (REPO / f).read_text().splitlines():
            if "# rule:" in line:
                body = line.split("# rule:")[0]
                indent = body[: len(body) - len(body.lstrip())]
                if body.strip().startswith("if "):
                    out.append((f, line, f"{indent}if False:"))
                elif body.strip().startswith("for "):
                    head, _, _ = body.strip().partition(" in ")
                    out.append((f, line, f"{indent}{head} in ():"))
                else:
                    name = body.strip().split(" ")[0]
                    out.append((f, line, f"{indent}{name} = type({name})()" if " |= " in body else f"{indent}pass"))
    return out


def run(bugs: list[tuple[str, str, str]], command: list[str], cwd: str) -> int:
    survived = 0
    with tempfile.TemporaryDirectory() as d:
        tree = Path(d) / "tree"
        listing = subprocess.run(["git", "-C", str(REPO), "ls-files", "-z"], capture_output=True)
        if listing.returncode:
            sys.exit("mutation_check.py needs a git checkout of the repository")
        names = listing.stdout
        for name in filter(None, names.decode().split("\0")):
            if (REPO / name).is_file():
                (tree / name).parent.mkdir(parents=True, exist_ok=True)
                shutil.copy(REPO / name, tree / name)

        def failed() -> bool:
            for cache in tree.rglob("__pycache__"):
                shutil.rmtree(cache)
            return subprocess.run(command, cwd=tree / cwd, capture_output=True).returncode != 0

        if failed():
            print("the tests fail before any bug is planted")
            return 1
        for f, old, new in bugs:
            path = tree / f
            text = path.read_text()
            if text.count(old) != 1:
                print(f"{f}: expected one match for {old.strip()[:70]!r}, found {text.count(old)}")
                survived += 1
                continue
            path.write_text(text.replace(old, new))
            if not failed():
                print(f"{f}: not caught: {old.strip()[:90]}")
                survived += 1
            path.write_text(text)
    print(f"{len(bugs) - survived} of {len(bugs)} deliberate bugs caught")
    return survived


def main() -> int:
    which = sys.argv[1] if len(sys.argv) > 1 else "all"
    bad = 0
    if which in ("python", "all"):
        bad += run(PYTHON_BUGS + check_bugs(), [sys.executable, "-B", "-m", "unittest", "discover", "-f", "-s", "tests"], ".")
    if which in ("dart", "all"):
        bad += run(DART_BUGS, ["flutter", "test"], "app")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
