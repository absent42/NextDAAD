#!/usr/bin/env python3
"""tests/nxv2_path_sim.py - the player-path event simulator, re-exported from
authoring-kit/lib/nxv2path.py, where the encoder prices with the same
geometry. See that module for the port and its video.asm citations."""
import sys
from pathlib import Path

LIB = Path(__file__).resolve().parent.parent / "authoring-kit" / "lib"
sys.path.insert(0, str(LIB))
import nxv2enc  # noqa: E402,F401
from nxv2path import *  # noqa: E402,F401,F403
from nxv2path import _ClearSourcePlayer, _Player, _KNOWN, _TERMINAL  # noqa: E402,F401
