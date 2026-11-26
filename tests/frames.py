"""Builds ring frames for the tests from invented numbers.

Independent of loophole_ring: fields are placed by offset, and the CRC is the standard library's (crc_hqx with an
0xFFFF start is CRC-16/CCITT-FALSE), so a mistake in the decoder isn't repeated here.
"""
import struct
from binascii import crc_hqx

FAKE_TIME = 1_000_000_000  # September 2001, long before any of these rings existed


def crc(payload: bytes) -> bytes:
    return crc_hqx(payload, 0xFFFF).to_bytes(2, "little")


def frame(head: bytes, payload: bytes) -> bytes:
    """Reply or stream frame: header, payload, CRC of the payload."""
    return head + payload + crc(payload)


def reply(op: int, payload: bytes, result: int = 0, detail: int = 1) -> bytes:
    return frame(bytes([op, result, detail]), payload)


def stream(op: int, payload: bytes) -> bytes:
    return frame(bytes([op]) + struct.pack("<H", len(payload)), payload)


def debug_page(page: int, payload: bytes, status: int = 0) -> bytes:
    return frame(bytes([0x79, status, 1]) + struct.pack("<H", page), payload)


def layout(size: int, fields: dict[int, bytes | int], fill: int = 0) -> bytes:
    """`size` bytes with each field written at its offset; an int is one byte."""
    out = bytearray([fill]) * size
    for offset, value in fields.items():
        data = bytes([value]) if isinstance(value, int) else value
        assert offset + len(data) <= size
        out[offset:offset + len(data)] = data
    return bytes(out)


def u16(v: int) -> bytes:
    return v.to_bytes(2, "little")


def u32(v: int) -> bytes:
    return v.to_bytes(4, "little")


def i32(v: int) -> bytes:
    return v.to_bytes(4, "little", signed=True)


def f32(v: float) -> bytes:
    return struct.pack("<f", v)
