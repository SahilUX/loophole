"""List ATT writes/notifications from a btsnoop file between two epochs.

Usage: dump_att.py file.btsnoop T0 T1 [handle_hex ...]
"""
import subprocess
import sys

path, t0, t1, *handles = sys.argv[1:]
flt = f"frame.time_epoch>={t0} && frame.time_epoch<={t1} && btatt.value"
if handles:
    flt += " && (" + " || ".join(f"btatt.handle=={h}" for h in handles) + ")"
out = subprocess.run(
    ["tshark", "-r", path, "-Y", flt, "-T", "fields", "-e", "frame.time_epoch",
     "-e", "btatt.opcode", "-e", "btatt.handle", "-e", "btatt.value"],
    capture_output=True, text=True, check=True).stdout
for line in out.splitlines():
    ts, op, h, v = line.split("\t")
    print(f"{float(ts) - float(t0):8.3f} op={op} h={h} len={len(v) // 2:3d} {v}")
