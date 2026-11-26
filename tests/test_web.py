"""The dashboard must not show IDs, and must answer only its own page. Everything here is invented."""
import ast
import asyncio
import contextlib
import io
import json
import re
import unittest
from pathlib import Path
from unittest import mock

from frames import debug_page, frame, layout, reply, stream
from loophole_ring import protocol as p
from loophole_ring import web

CHIP = bytes.fromhex("e1e2e3e4" "e5e6e7e8")
PEER = bytes.fromhex("b1b2b3" "b4b5b6")
NAME = "UH" + "_" + PEER.hex().upper()
PAGES = {28: layout(81, {1 + 2: PEER, 0: 1}), 30: layout(40, {0: CHIP})}


class FakeRing:
    def __init__(self, raw: bytes, hub: web.Hub):
        self.raw, self.hub, self.name = raw, hub, NAME

    async def query(self, packet: bytes, timeout: float = 5.0) -> bytes:
        self.hub.tap("tx", "cmd", packet)
        self.hub.tap("rx", "resp", self.raw)
        return self.raw

    async def collect(self, packet: bytes, timeout: float = 5.0) -> list[bytes]:
        return [await self.query(packet)]


def hub() -> web.Hub:
    with mock.patch.object(web, "load_choice", lambda: None):
        return web.Hub(None, 8765)


def sent(h: web.Hub, q: asyncio.Queue) -> str:
    out = ""
    while not q.empty():
        out += q.get_nowait()
    return out


class Redaction(unittest.TestCase):
    def check(self, text: str) -> None:
        low = text.lower().replace(" ", "").replace(":", "")
        for secret in (CHIP, CHIP[::-1], PEER, PEER[::-1]):
            self.assertNotIn(secret.hex(), low)
        self.assertNotIn(NAME.lower(), text.lower())

    def test_probes_and_traffic_hide_the_chip_id_and_addresses(self):
        for page, payload in PAGES.items():
            for raw in (debug_page(page, payload), debug_page(page, payload, status=0xFF), debug_page(page, payload)[:30],
                        reply(0x79, payload)):
                h = hub()
                q: asyncio.Queue[str] = asyncio.Queue()
                h.clients.add(q)
                asyncio.run(h.probe(FakeRing(raw, h), f"page-{page}"))
                text = sent(h, q)
                self.assertIn('"probe"', text)
                self.assertIn('"traffic"', text)
                self.check(text)

    def test_every_probe_hides_ids_wherever_they_sit(self):
        """An ID in any reply, at any offset, whole or split, with or without a good CRC."""
        for name, (build, _) in web.Hub.PROBES.items():
            op = build()[0]
            for size in (*range(6, 12), 19, 31, 37, 47, 90, 180):
                secret = (CHIP + PEER) * 13
                raws = [reply(op, secret[:size]), stream(op, secret[:size]), bytes([op]) + secret[:size], secret[:size]]
                if op == p.OP_DEBUG_PAGE:
                    raws.append(debug_page(29, secret[:size]))
                for raw in raws:
                    h = hub()
                    q: asyncio.Queue[str] = asyncio.Queue()
                    h.clients.add(q)
                    asyncio.run(h.probe(FakeRing(raw, h), name))
                    self.check(sent(h, q))

    def test_raw_bytes_shown_in_full(self):
        for raw in (reply(0x05, b"abcd"), reply(0x07, b"ab"), reply(0x08, b"ab"), reply(0x09, b"abcdab"),
                    frame(b"\x14\x00\x01\x01\x00", b"\x11")):
            self.assertEqual(web.safe_hex("rx", "resp", raw), raw.hex())
            for bad in (raw[:-1], raw + b"\0", raw[:-1] + bytes([raw[-1] ^ 1]), raw[:1] + b"\xff" + raw[2:]):
                self.assertIn("hidden", web.safe_hex("rx", "resp", bad))
            for char in ("stream", "aux", "other", "state"):
                self.assertIn("hidden", web.safe_hex("rx", char, raw))
        for longer in (reply(0x05, b"abcdefgh"), reply(0x07, b"abcd"), reply(0x09, b"abcdabzz"), reply(0x05, b"ab"),
                       frame(b"\x14\x00\x01\x01\x00", b"\x11\x12\x13")):
            self.assertIn("hidden", web.safe_hex("rx", "resp", longer))  # right CRC, wrong length
        self.assertIn("hidden", web.safe_hex("rx", "resp", reply(0x09, b"abcdef")))  # the two newest fields differ
        self.assertIn("hidden", web.safe_hex("rx", "resp", frame(b"\x14\x00\x01\x02\x00", b"\x11")))

    def test_acknowledgements_show_three_bytes(self):
        for op in web.ACK_OPCODES:
            self.assertEqual(web.safe_hex("rx", "resp", reply(op, b"\xc7")), f"{op:02x}0001 [3 bytes hidden]")
            for raw in (reply(op, PEER), reply(op, CHIP), bytes([op]) + CHIP):
                self.check(web.safe_hex("rx", "resp", raw))

    def test_everything_else_shows_one_byte_at_most(self):
        for char, raw in (("resp", b"\xee" + PEER), ("resp", reply(0x59, b"\x42")), ("resp", reply(0x04, bytes(32))),
                          ("stream", b"\xa1" + CHIP), ("stream", stream(0x52, bytes(14))), ("stream", b"\x90" + bytes(160)),
                          ("aux", PEER), ("other", b"\x05" + PEER), ("state", PEER * 3), ("resp", b""), ("stream", b"")):
            text = web.safe_hex("rx", char, raw)
            self.assertIn(f"[{len(raw) - len(text.split('[')[0].strip()) // 2} bytes hidden]", text)
            self.assertLessEqual(len(text.split("[")[0].strip()), 2, text)
        self.assertEqual(web.safe_hex("rx", "resp", b"\xee" + PEER), "[7 bytes hidden]")  # not an opcode we know
        self.assertEqual(web.safe_hex("tx", "cmd", b"\x05"), "05")
        self.assertIn("hidden", web.safe_hex("tx", "cmd", b"\x05" + PEER))

    def test_state_record_shows_its_decoded_parts(self):
        text = web.safe_hex("rx", "state", bytes(range(76)))
        shown = {i for i in range(76) if text[2 * i:2 * i + 2] != ".."}
        self.assertEqual(shown, {*range(11), *range(15, 23), *range(29, 33)})

    def test_ring_names_and_bluetooth_errors_stay_on_the_server(self):
        class Dev:
            name = NAME

        class Adv:
            local_name, rssi = NAME, -50

        async def found(**_):
            return {"x": (Dev, Adv)}

        async def broken(**_):
            raise OSError(f"cannot reach {NAME}")

        for discover in (found, broken):
            h = hub()
            q: asyncio.Queue[str] = asyncio.Queue()
            h.clients.add(q)
            h.name = NAME
            with mock.patch.object(web.BleakScanner, "discover", discover):
                asyncio.run(h.scan(0.1))
            asyncio.run(h.run_action("time"))
            text = sent(h, q)
            self.assertIn('"ring": 1', text)
            self.check(text)

        def refuse(*_, **__):
            raise OSError(f"cannot reach {NAME}")

        h = hub()
        q = asyncio.Queue()
        h.clients.add(q)
        with mock.patch.object(web.Ring, "connect", refuse):
            asyncio.run(h.connect_once(NAME))
        h.ring = FakeRing(b"", h)  # type: ignore[assignment]
        asyncio.run(h.run_action("time"))  # FakeRing has no clock: the failure text must be a type name
        self.check(sent(h, q))

    def test_page_does_not_use_names(self):
        html = (Path(web.__file__).parent / "web.html").read_text()
        self.assertNotIn("r.name", html)
        self.assertNotIn("innerHTML = lines", html)


    def test_errors_nobody_caught_print_a_type_only(self):
        async def go():
            asyncio.get_running_loop().set_exception_handler(web.quiet)

            async def fails():
                raise OSError(f"cannot reach {NAME} {PEER.hex(':')}")

            task = asyncio.create_task(fails())
            await asyncio.sleep(0)
            del task
            import gc
            gc.collect()
            await asyncio.sleep(0)

        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            asyncio.run(go())
        self.assertIn("dashboard error: OSError", err.getvalue())
        self.check(err.getvalue())
        self.assertIn("set_exception_handler(quiet)", Path(web.__file__).read_text())

    def test_command_line_errors_show_a_type_only(self):
        from bleak.exc import BleakError
        from loophole_ring import cli

        async def broken(*_):
            raise BleakError(f"cannot reach {NAME}")

        with mock.patch.object(cli, "_run", broken), self.assertRaises(SystemExit) as e:
            cli.main(["battery"])
        self.assertEqual(str(e.exception), "Bluetooth error: BleakError")


class PageMatchesServer(unittest.TestCase):
    """Every field the page reads must be one the server sends in that kind of event."""

    def server_fields(self) -> dict[str, set[str]]:
        tree = ast.parse(Path(web.__file__).read_text())
        state = next({k.arg for k in n.value.keywords} for n in ast.walk(tree) if isinstance(n, ast.Assign)
                     and isinstance(n.value, ast.Call) and getattr(n.value.func, "id", "") == "dict")
        fields: dict[str, set[str]] = {}
        for n in ast.walk(tree):
            if isinstance(n, ast.Call) and getattr(n.func, "attr", "") == "emit":
                kind, keys = n.args[0].value, {k.arg for k in n.keywords if k.arg}
                if any(k.arg is None for k in n.keywords):
                    keys |= state
                fields[kind] = fields.get(kind, keys) & keys
        return fields

    def page_fields(self) -> dict[str, set[str]]:
        script = (Path(web.__file__).parent / "web.html").read_text().split("es.onmessage")[1].split("es.onerror")[0]
        parts = re.split(r"m\.type === '(\w+)'", script)[1:]
        return {k: set(re.findall(r"\bm\.(\w+)", body)) - {"t", "type"} for k, body in zip(parts[::2], parts[1::2])}

    def test_fields(self):
        server, page = self.server_fields(), self.page_fields()
        self.assertEqual(set(page), set(server))
        for kind, used in page.items():
            self.assertLessEqual(used, server[kind], kind)
        self.assertIn("microamps", page["state"])

    def test_ring_rows(self):
        h = hub()
        q: asyncio.Queue[str] = asyncio.Queue()
        h.clients.add(q)
        h.nearby[NAME] = {"rssi": -50, "seen": 1.0}
        h.emit_rings()
        (row,) = json.loads(sent(h, q).removeprefix("data: "))["rings"]
        html = (Path(web.__file__).parent / "web.html").read_text()
        used = set(re.findall(r"\br\.(\w+)", html))
        self.assertEqual(used, set(row))

    def test_state_event_has_real_numbers(self):
        h = hub()
        q: asyncio.Queue[str] = asyncio.Queue()
        h.clients.add(q)
        h.on_state(layout(76, {0: 77, 1: (-4321).to_bytes(4, "little", signed=True), 6: 21}))
        event = json.loads(sent(h, q).removeprefix("data: "))
        self.assertEqual((event["battery"], event["microamps"], event["temp"]), (77, -4321, 21))

    def test_every_button_has_a_route(self):
        html = (Path(web.__file__).parent / "web.html").read_text()
        self.assertLessEqual(set(re.findall(r'data-a="([\w-]+)"', html)), web.ACTIONS)
        self.assertLessEqual(set(re.findall(r"post\('([\w-]+)'\)", html)), web.ACTIONS)
        self.assertEqual(set(re.findall(r"\['([\w-]+)','0x", html)), set(web.Hub.PROBES))


class OwnPageOnly(unittest.TestCase):
    ROUTES = [("POST", r) for r in ("/scan", "/release", "/reconnect", "/choose/-", "/choose/1", "/action/critical",
                                    "/action/q-page-30")] + [("GET", "/"), ("GET", "/events")]

    def request(self, method: str, path: str, *headers: str) -> tuple[int, web.Hub]:
        async def go():
            h = hub()
            h.tokens = [NAME]
            h.run_action, h.scan, h.release, h.choose = (mock.AsyncMock() for _ in range(4))
            h.sse = mock.AsyncMock(side_effect=lambda w: w.write(b"HTTP/1.1 200 OK\r\n\r\n"))
            server = await asyncio.start_server(h.http, "127.0.0.1", 0)
            r, w = await asyncio.open_connection(*server.sockets[0].getsockname())
            w.write("\r\n".join([f"{method} {path} HTTP/1.1", *headers, "", ""]).encode("latin-1"))
            line = await asyncio.wait_for(r.readline(), 3)
            w.close()
            server.close()
            await asyncio.sleep(0)
            return int(line.split()[1]), h

        return asyncio.run(go())

    HOST, ORIGIN = "Host: 127.0.0.1:8765", "Origin: http://127.0.0.1:8765"

    def test_odd_spacing_in_headers(self):
        self.assertEqual(self.request("POST", "/scan", "Host: 127.0.0.1:8765\xa0", self.ORIGIN)[0], 403)
        self.assertEqual(self.request("POST", "/scan", "Host:\t127.0.0.1:8765 ", self.ORIGIN)[0], 204)

    def test_own_page_works(self):
        for method, path in self.ROUTES:
            for pair in ((self.HOST, self.ORIGIN), ("Host: localhost:8765", "Origin: http://localhost:8765")):
                code, _ = self.request(method, path, *pair)
                self.assertIn(code, (200, 204), (method, path))
        for path in ("/", "/events"):
            self.assertEqual(self.request("GET", path, self.HOST)[0], 200)

    def test_other_sites_are_refused_on_every_route(self):
        evil = "evil." + "example"
        bad = [(self.HOST, f"Origin: http://{evil}"), (self.HOST, "Origin: null"), (self.HOST, "Origin: http://127.0.0.1:9999"),
               (f"Host: {evil}:8765", self.ORIGIN), (f"Host: {evil}", f"Origin: http://{evil}"), (self.ORIGIN,),
               ("Host: 127.0.0.1:8765." + evil, self.ORIGIN), (self.HOST, f"Host: {evil}", self.ORIGIN), (f"Host: {evil}", self.HOST, self.ORIGIN),
               (self.HOST, f"Origin: http://{evil}", self.ORIGIN),
               (self.HOST, self.ORIGIN, f"Origin: http://{evil}"), (f"Host: {evil}:8765",), ("Host: 127.0.0.1",)]
        for method, path in self.ROUTES:
            for headers in bad:
                code, h = self.request(method, path, *headers)
                self.assertEqual(code, 403, (method, path, headers))
                for f in (h.run_action, h.scan, h.release, h.choose, h.sse):
                    f.assert_not_called()

    def test_post_without_origin_and_cross_site_get_are_refused(self):
        for method, path in self.ROUTES:
            if method == "POST":
                self.assertEqual(self.request(method, path, self.HOST)[0], 403, path)
            else:
                for site in ("cross-site", "same-site"):
                    self.assertEqual(self.request(method, path, self.HOST, f"Sec-Fetch-Site: {site}")[0], 403, path)

    def test_bad_ring_numbers_and_actions(self):
        for path, want in (("/choose/0", 400), ("/choose/2", 400), ("/choose/" + NAME, 400), ("/choose/-1", 400),
                           ("/action/q-nope", 404), ("/action/", 404)):
            self.assertEqual(self.request("POST", path, self.HOST, self.ORIGIN)[0], want, path)

    def test_choosing_by_number(self):
        _, h = self.request("POST", "/choose/1", self.HOST, self.ORIGIN)
        h.choose.assert_called_once_with(NAME)


class PickingARing(unittest.TestCase):
    def test_commands_need_a_ring(self):
        from loophole_ring import cli
        with mock.patch.object(web, "load_choice", lambda: None), mock.patch.object(cli.Ring, "connect") as connect, \
                self.assertRaises(SystemExit) as e:
            cli.main(["battery"])
        self.assertIn("which ring", str(e.exception))
        connect.assert_not_called()

    def test_only_the_named_ring_matches(self):
        from loophole_ring import client
        seen = []

        async def find(match, timeout):
            class Dev:
                name = None
            for n in ("UH" + "_OTHER", NAME):
                class Adv:
                    local_name = n
                seen.append((n, match(Dev, Adv)))
            return None

        with mock.patch.object(client.BleakScanner, "find_device_by_filter", find), self.assertRaises(client.RingNotFound):
            asyncio.run(client.find_ring(NAME))
        self.assertEqual(seen, [("UH" + "_OTHER", False), (NAME, True)])


class SavedChoice(unittest.TestCase):
    def test_only_the_owner_can_read_it(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "sub" / "web.json"
            with mock.patch.object(web, "CHOICE_FILE", path):
                web.save_choice("invented")
                self.assertEqual(json.loads(path.read_text()), {"ring": "invented"})
                self.assertEqual(path.stat().st_mode & 0o777, 0o600)
                path.chmod(0o644)  # as an older version left it
                self.assertEqual(web.load_choice(), "invented")
                self.assertEqual(path.stat().st_mode & 0o777, 0o600)


if __name__ == "__main__":
    unittest.main()
