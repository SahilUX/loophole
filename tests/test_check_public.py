"""The release check must catch each kind. Bad examples are put together at run time so this file stays clean."""
import base64
import importlib.util
import pathlib
import unittest

_path = pathlib.Path(__file__).resolve().parent.parent / "scripts" / "check_public.py"
_spec = importlib.util.spec_from_file_location("check_public", _path)
assert _spec and _spec.loader
check = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(check)

OCTETS = [f"{0xA1 + i:02x}" for i in range(6)]
RECENT = check.EPOCH_FROM + 99_000_000
BYTES = bytes(range(0xF1, 0xFB)) + bytes([7, 8])


class CheckPublic(unittest.TestCase):
    def assert_kind(self, line: str, kind: str) -> None:
        self.assertIn(kind, check.check_line(line), line)

    def test_addresses_in_every_spelling(self):
        up = [o.upper() for o in OCTETS]
        for text in (":".join(OCTETS), "-".join(up), " ".join(OCTETS), "_".join(OCTETS), ".".join(OCTETS),
                     ", ".join("0x" + o for o in up), "".join(OCTETS), "".join(up), "".join("\\x" + o for o in OCTETS)):
            self.assert_kind(f"x '{text}'", "MAC address")
        self.assert_kind("x " + ".".join([OCTETS[0] + OCTETS[1]] * 3), "MAC address")

    def test_each_address_rule_on_its_own(self):
        self.assert_kind("x " + ".".join(["a1" + "b2"] * 3), "MAC address")  # dotted only
        self.assert_kind("x " + "".join(OCTETS), "MAC address")  # bare only
        self.assert_kind("x " + ", ".join("0x" + o for o in OCTETS), "MAC address")  # listed only
        self.assert_kind("x " + ":".join(OCTETS), "MAC address")  # separated only
        self.assertIn("MAC address", check.check_line("x " + ":".join(OCTETS), machine=True))

    def test_names_and_serials(self):
        self.assert_kind("name UH" + "_" + "".join(OCTETS), "ring name")
        self.assert_kind("name uh" + "-" + "".join(OCTETS), "ring name")
        parts = ["QQ", "ZZ9", "XX", "W7", "0" * 7]
        for text in ("-".join(parts), "-".join(parts).lower(), "_".join(parts).lower(), "-".join(["QQ9", "ZZ", "1234"])):
            self.assert_kind(f"('{text}')", "serial-like")
        self.assert_kind("serial: " + "abc" + "1234", "serial-like")
        self.assert_kind("chip ID = " + "AB" + "99887", "serial-like")
        self.assert_kind("id " + "9" * 14, "long number")
        self.assert_kind("id " + "9_99" * 5, "long number")
        self.assert_kind("-".join(["1234" * 2, "1234", "1234", "1234", "1234" * 3]), "unknown UUID")

    def test_personal_details(self):
        self.assert_kind("mail someone" + "@" + "example.org", "email address")
        for p in ("/Users" + "/someone/x", "/home" + "/someone/x", "C:" + "\\Users\\someone"):
            self.assert_kind(p, "home folder path")
        for ip in ("192.168" + ".4.5", "10.1" + ".2.3", "172.20" + ".0.9", "100.80" + ".1.1"):
            self.assert_kind(ip, "private IP address")
        self.assert_kind("DEVELOPMENT" + "_TEAM = " + "A1B2C3" + "D4E5;", "Apple team ID")
        self.assertIn("Apple team ID", check.check_line("DEVELOPMENT" + "_TEAM = " + "A1B2C3" + "D4E5;", machine=True))

    def test_times(self):
        for text in (f"{RECENT}", f"{RECENT}123", f"{RECENT:_}", f"0x{RECENT:08X}", f"0x{RECENT:_x}"):
            self.assert_kind(f"t = {text}", "recent Unix time")
        self.assert_kind(f"t = {12345 * 1901}", "number that could be a ring time")
        for order in ("little", "big"):
            frame = bytes([5, 0, 1]) + RECENT.to_bytes(4, order) + bytes([9, 9])
            self.assert_kind(frame.hex(), "bytes holding a recent time")

    def test_byte_sequences_in_every_spelling(self):
        for text in (BYTES.hex(), BYTES.hex(" "), BYTES.hex("_"), BYTES.hex(":"), ", ".join(f"0x{b:02X}" for b in BYTES),
                     "".join(f"\\x{b:02x}" for b in BYTES)):
            self.assert_kind(f"'{text}'", "byte sequence")
        self.assert_kind(", ".join(str(b) for b in BYTES), "list of numbers")
        self.assert_kind(", ".join(str(b / 10) for b in BYTES), "list of numbers")
        self.assert_kind(f"'{base64.b64encode(bytes(range(0xE0, 0xEC)) + b'12').decode()}'", "base64 data")

    def test_split_over_lines(self):
        half = len(BYTES.hex()) // 2
        text = f"a = ('{BYTES.hex()[:half]}'\n     '{BYTES.hex()[half:]}')"
        self.assertTrue(any(k == "byte sequence over several lines" for _, k in check.check_text(text)), check.check_text(text))
        text = ",\n".join(str(b) for b in BYTES)
        self.assertTrue(any(k == "list of numbers over several lines" for _, k in check.check_text(text)))

    def test_readings(self):
        self.assert_kind("at 03" + ":15 HR 7" + "7", "timestamped reading")
        self.assert_kind("20" + "31-01-02 10" + ":11:12 battery 4" + "4%", "timestamped reading")
        for text in ("it was 6" + "1 BPM", "3" + "4.29 C", "3" + "6.6 °C", "401" + "2 mV", "HRV was " + "68", "spo2=" + "97"):
            self.assert_kind(text, "reading")

    def test_marked_lines_are_skipped_and_machine_files_keep_the_personal_rules(self):
        self.assertEqual(check.check_line(f"t = {RECENT}  # {check.OK_MARK} why"), set())
        self.assertEqual(check.check_line(BYTES.hex(), machine=True), set())

    def test_clean_lines(self):
        for line in ("8d53dc1d-1db7-4cd3-868b-8a527460aa84", "UH_XXXXXXXXXXXX", "n.startsWith('UH_')",
                     "parse('zz-QQ12-fake')", "'7929070e00'", "FAKE_TIME = 1_000_000_000", "heart rate 111",
                     "http://127.0.0.1:8765", "bytes(32)", "00ff" * 10, "Icon-App-20x20@2x.png", "0xFFE6A68F",
                     "const Duration(milliseconds: 11000)", "android:allowBackup=\"false\""):
            self.assertEqual(check.check_line(line), set(), line)

    def test_binary_files(self):
        name = "by UH" + "_" + "".join(OCTETS)
        self.assertEqual(check.check_bytes(b"\x89PNG\x00\xff" + name.encode() + b"\x00"), {"ring name"})
        self.assertEqual(check.check_bytes(b"\xff\xfe" + name.encode("utf-16-le")), {"ring name"})
        self.assertEqual(check.check_bytes(b"\x00\x01" + ("/Users" + "/someone/pic").encode()), {"home folder path"})
        self.assertEqual(check.check_bytes(bytes(range(256)) * 4), set())



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
            self.assertEqual(check.tracked_files(root), ["a.txt", "sub/b.txt"])


if __name__ == "__main__":
    unittest.main()
