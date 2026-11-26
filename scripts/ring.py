"""Shim so `scripts/.venv/bin/python -I scripts/ring.py ...` keeps working. The code lives in loophole_ring/."""
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))
from loophole_ring.cli import main  # noqa: E402

main()
