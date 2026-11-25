#!/usr/bin/env python3
"""tests/videnc_old_direct.py - videnc with the old direct layout selected.

Sets nxv2enc.DIRECT_LAYOUT = "old", then runs videnc.main with the given args.
"""
import sys
from pathlib import Path

LIB = Path(__file__).resolve().parent.parent / "authoring-kit" / "lib"
sys.path.insert(0, str(LIB))

import nxv2enc  # noqa: E402
import videnc  # noqa: E402

nxv2enc.DIRECT_LAYOUT = "old"

if __name__ == "__main__":
    sys.exit(videnc.main(sys.argv))
