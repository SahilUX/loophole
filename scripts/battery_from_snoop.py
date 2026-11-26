"""Passive battery check: newest battery state notification in an Android phone's HCI snoop log.

Sends nothing to the ring. Prints one line; exit code 3 if the log has no state record.
"""
import pathlib
import subprocess
import sys
import tempfile
import time

SNOOP = "/data/misc/bluetooth/logs/btsnoop_hci.log"
with tempfile.TemporaryDirectory() as d:
    local = str(pathlib.Path(d) / "snoop")
    subprocess.run(["adb", "pull", SNOOP, local], capture_output=True, check=True)
    out = subprocess.run(
        ["tshark", "-r", local, "-Y", "btatt.handle==0x0021 && btatt.opcode==0x1b", "-T", "fields",
         "-e", "frame.time_epoch", "-e", "btatt.value"],
        capture_output=True, text=True, check=True).stdout.strip().splitlines()
if not out:
    print("no state record in log")
    sys.exit(3)
ts, val = out[-1].split("\t")
b = bytes.fromhex(val)
print(f"{time.strftime('%H:%M:%S', time.localtime(float(ts)))} battery={b[0]}% age={int(time.time() - float(ts))}s")
