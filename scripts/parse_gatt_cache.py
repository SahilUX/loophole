"""Decode Android's /data/misc/bluetooth/gatt_hash_* attribute cache (v6 layout).

Usage: parse_gatt_cache.py gatt_cache.bin
Record = handle(u16) + type uuid(16, big-endian) + 20-byte value; header = version(u16) + count(u16).
"""
import struct
import sys
import uuid

BASE = "-0000-1000-8000-00805f9b34fb"
PROPS = [(0x01, "broadcast"), (0x02, "read"), (0x04, "write-nr"), (0x08, "write"),
         (0x10, "notify"), (0x20, "indicate"), (0x40, "signed"), (0x80, "ext")]


def short(u: uuid.UUID) -> str:
    s = str(u)
    return "0x" + s[4:8] if s.endswith(BASE) and s.startswith("0000") else s


data = open(sys.argv[1], "rb").read()
version, count = struct.unpack_from("<HH", data, 0)
print(f"cache version {version}, {count} attributes")
for i in range(count):
    off = 4 + i * 38
    handle = struct.unpack_from("<H", data, off)[0]
    atype = uuid.UUID(bytes=data[off + 2:off + 18])
    val = data[off + 18:off + 38]
    t = short(atype)
    if t == "0x2800":
        end = struct.unpack_from("<H", val, 16)[0]
        print(f"0x{handle:04x} SERVICE {short(uuid.UUID(bytes=val[:16]))}  (..0x{end:04x})")
    elif t == "0x2803":
        props, vh = struct.unpack_from("<BxH", val, 0)
        p = ",".join(n for b, n in PROPS if props & b)
        print(f"0x{handle:04x}   CHAR value=0x{vh:04x} {short(uuid.UUID(bytes=val[4:20]))} [{p}]")
    else:
        print(f"0x{handle:04x}     desc {t}")
