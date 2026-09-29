"""vidtune - GUI tuner for VIDEO\\NNN.mp4 encodes (per-clip settings feed
VIDOPTS_NNN in CONFIG.local.BAT)."""

import sys
from pathlib import Path

__version__ = "0.11"  # kit release number
ICON_PATH = Path(__file__).with_name("vidtune.ico")  # scripts/make-vidtune-icon.py

WAYLAND_TEXTINPUT_RULE = "qt.qpa.wayland.textinput=false"


def quiet_wayland_textinput(environ, platform=sys.platform):
    """Mute Qt's Wayland text-input focus warning (harmless, logged on focus
    changes). Must run before Qt starts; a user's own QT_LOGGING_RULES come
    after it, so theirs still win."""
    if not platform.startswith("linux"):
        return
    rules = environ.get("QT_LOGGING_RULES", "")
    if WAYLAND_TEXTINPUT_RULE in rules:
        return
    environ["QT_LOGGING_RULES"] = WAYLAND_TEXTINPUT_RULE + (";" + rules if rules else "")
