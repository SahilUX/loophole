"""The captures comparison, run on an invented captures folder and an invented repository."""
import base64
import importlib.util
import json
import pathlib
import struct
import subprocess
import sys
import tempfile
import unittest

_path = pathlib.Path(__file__).resolve().parent.parent / "scripts" / "compare_captures.py"
_spec = importlib.util.spec_from_file_location("compare_captures", _path)
assert _spec and _spec.loader
cc = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(cc)

# Invented, and built so that no literal in this file is a run of bytes.
FRAME = bytes((37 * i * i + 11 * i + 5) % 251 for i in range(40))
CHIP = bytes((91 * i * i + 200) % 256 for i in range(8))
PEER = bytes((53 * i * i + 130) % 256 for i in range(6))
BONDED = bytes((29 * i * i + 77) % 256 for i in range(6))
NAME = "UH" + "_" + PEER.hex().upper()
SERIAL = "-".join(["QQ", "ZZ9", "XXX", "W7", "JJ44", "76543" + "21"])
TIME = 1_000_000_000 + 76543 * 101
ROW = [9, TIME] + [111, 22, 99, 3] + [30.57, 20.25, 777, 43] + [0, 0]


def packet(data: bytes) -> bytes:
    return struct.pack(">IIIIQ", len(data), len(data), 0, 0, 0) + data


class Compare(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        root = pathlib.Path(cls.tmp.name)
        connect = b"\x04\x3e\x13\x01" + b"\x00\x40\x00\x00\x01" + PEER[::-1] + bytes(7)
        bonds = b"\x79\x00\x01" + b"\x1c\x00\x00" + (b"\x01\x02" + BONDED) + bytes(72 + 2)
        ids = b"\x79\x00\x01\x1e\x00" + CHIP + bytes(30)
        (root / "a.btsnoop").write_bytes(b"btsnoop\0" + bytes(8) + b"".join(
            packet(x) for x in (connect, b"\x02\x40" + FRAME, b"\x02\x40" + bonds, b"\x02\x40" + ids, SERIAL.encode())))
        (root / "r.jsonl").write_text(json.dumps(ROW) + "\n")
        (root / "n.txt").write_text(f"saw {NAME}\n")
        cls.cap = cc.Captures(root)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def kinds(self, content: str | bytes, name: str = "x.py") -> set[str]:
        data = content.encode() if isinstance(content, str) else content
        return {k for _, k in cc.compare(self.cap, name, data)}

    def test_reads_the_ids(self):
        c = self.cap
        self.assertEqual((c.names, c.serials, c.chips), ({NAME}, {SERIAL}, {CHIP}))
        self.assertLessEqual({PEER, BONDED}, c.macs)

    def test_text_in_screenshots_counts(self):
        from unittest import mock
        with tempfile.TemporaryDirectory() as d:
            (pathlib.Path(d) / "shot.png").write_bytes(b"not a picture")
            with mock.patch.object(cc, "ocr", lambda images: f"{NAME}\n{SERIAL}" if images else ""):
                cap = cc.Captures(pathlib.Path(d))
        self.assertEqual((cap.names, cap.serials), ({NAME}, {SERIAL}))

    def test_ids_as_text(self):
        for text, kind in ((NAME.lower(), "ring name as text"), (NAME[3:], "ring name as text"), (SERIAL.lower(), "serial as text"),
                           (SERIAL.replace("-", ""), "serial as text"), ("x" + SERIAL[-7:], "part of a serial as text")):
            self.assertIn(kind, self.kinds(text), text)
        self.assertIn("serial as text", self.kinds(SERIAL.encode("utf-16-le")))

    def test_ids_in_every_spelling(self):
        for value, kind in ((CHIP, "chip ID written out"), (PEER, "address written out"), (BONDED, "address written out")):
            for v in (value, value[::-1]):
                for text in (v.hex(), v.hex(":"), v.hex("-").upper(), v.hex(" "), v.hex("_"), "".join(f"\\x{b:02x}" for b in v),
                             ", ".join(f"0x{b:02X}" for b in v), ", ".join(map(str, v)), ",".join(map(str, v)),
                             *(base64.b64encode(b"z" * k + v + b"z").decode() for k in range(3)),
                             str(int.from_bytes(v, "little"))):
                    self.assertIn(kind, self.kinds(f"a = '{text}'"), (kind, text))
        self.assertIn("chip ID as bytes", self.kinds(b"\0\0" + CHIP + b"\0"))
        self.assertIn("address as bytes", self.kinds(b"\0\0" + BONDED[::-1] + b"\0"))

    def test_captured_bytes_in_every_spelling(self):
        part = FRAME[8:20]
        long = "captured bytes, 8 or more"
        for v in (part, part[::-1]):
            for text in (v.hex(), v.hex(" "), v.hex("_"), "".join(f"\\x{b:02x}" for b in v), ", ".join(f"0x{b:02x}" for b in v),
                         ", ".join(map(str, v)), f"{v.hex()[:10]}'\n   '{v.hex()[10:]}"):
                self.assertIn(long, self.kinds(f"a = '{text}'"), text)
            self.assertIn("captured bytes, base64", self.kinds(f"a = '{base64.b64encode(v).decode()}'"))
        self.assertIn("captured bytes, raw", self.kinds(b"\0" + part + b"\0"))

    def test_short_sequences(self):
        short = "captured bytes, 4 to 7"
        v = FRAME[8:13]
        for text in (v.hex(), v.hex(" "), ", ".join(map(str, v)), "".join(f"\\x{b:02x}" for b in v), v[::-1].hex(),
                     str(int.from_bytes(v[:4], "little")), f"0x{int.from_bytes(v[:4], 'big'):08x}",
                     f"{int.from_bytes(v[:4], 'little'):_}"):
            self.assertIn(short, self.kinds(f"a = '{text}'"), text)
        self.assertNotIn(short, self.kinds(v.hex(), name="pubspec.lock"))

    def test_record_values(self):
        self.assertIn("time of a synced record", self.kinds(f"t = {TIME:_}"))
        self.assertIn("values of a synced record", self.kinds("(" + ", ".join(map(str, ROW[2:6])) + ")"))
        self.assertIn("values of a synced record", self.kinds("[30.57, 20.25, 777, 43]"))

    def test_clean_files(self):
        for text in ("a = 'beef'", "0x79, 0x29, 0x07, 14, 0", "86f61001-f706-58a0-95b2-1fb9261e4dc7", ", ".join(map(str, range(10))),
                     "8d53dc1d-1db7-4cd3-868b-8a527460aa84", "(1, 2, 3, 4)", "a decade of added facade"):
            self.assertEqual(self.kinds(text), set(), text)

    def test_the_command_fails_on_a_match_and_prints_no_value(self):
        with tempfile.TemporaryDirectory() as d:
            repo = pathlib.Path(d)
            subprocess.run(["git", "init", "-q", d], check=True)
            (repo / "a.py").write_text(f"x = '{FRAME.hex()}'  # {NAME}\n")
            subprocess.run(["git", "-C", d, "add", "a.py"], check=True)
            r = subprocess.run([sys.executable, str(_path), self.tmp.name, d], capture_output=True, text=True)
            self.assertEqual(r.returncode, 1)
            self.assertIn("a.py", r.stdout)
            for secret in (NAME, FRAME.hex()[:16], SERIAL):
                self.assertNotIn(secret, r.stdout)
            (repo / "a.py").write_text("x = 1\n")
            self.assertEqual(subprocess.run([sys.executable, str(_path), self.tmp.name, d], capture_output=True).returncode, 0)



class OutsideGit(unittest.TestCase):
    def test_a_downloaded_folder_is_checked_file_by_file(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            root = pathlib.Path(d)
            (root / "a.txt").write_text("x")
            (root / "sub").mkdir()
            (root / "sub" / "b.txt").write_text("y")
            (root / "build").mkdir()
            (root / "build" / "c.txt").write_text("z")
            (root / ".venv").mkdir()
            (root / ".venv" / "d.txt").write_text("w")
            self.assertEqual(cc.tracked_files(root), ["a.txt", "sub/b.txt"])


if __name__ == "__main__":
    unittest.main()
