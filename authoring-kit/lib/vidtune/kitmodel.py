"""Kit discovery and CONFIG.BAT reading for vidtune.

Mirrors lib/video.ps1's reading of the same file - that script is the
authority; on any divergence, video.ps1 wins and this module is wrong.
"""
import hashlib
import os
import re
from dataclasses import dataclass, field
from pathlib import Path

from .settingsmodel import build_arg_vector

_SET_RE = re.compile(r'^\s*set\s+"?([A-Za-z0-9_]+)=(.*?)"?\s*$', re.IGNORECASE)

PATH_KEYS = {
    "TOOLSDIR", "GFXDIR", "ARKOSDIR", "CSPECTDIR", "FFMPEGDIR",
    "SJASMPLUSDIR", "NEXTDAWDIR", "VIDTOOLSDIR", "NDRC", "NEXFILE",
    "INTRONEX",
}


def find_kit_root(start):
    p = Path(start).resolve()
    for cand in (p, *p.parents):
        if (cand / "CONFIG.BAT").is_file() and (cand / "VIDEO").is_dir():
            return cand
    return None


@dataclass
class KitConfig:
    vid_aspect: str = ""
    vid_fps: str = ""
    vid_opts: str = ""
    toolsdir: str = "tools"
    vidtoolsdir: str = ""
    per_clip: dict = field(default_factory=dict)
    vidprofile: str = ""
    ffmpegdir: str = ""


def _read_sets(path, into):
    p = Path(path)
    if not p.is_file():
        return
    # Latin-1 and \r, \n, \r\n breaks only, as kitconfig.ps1's ReadAllLines
    # (str.splitlines would also split on \x85 and other controls).
    with p.open(encoding="latin-1", newline=None) as f:
        lines = f.read().split("\n")
    for line in lines:
        m = _SET_RE.match(line)
        if m:
            # No strip: cmd's SET keeps a leading space after '='; the
            # regex's trailing \s*$ already drops trailing whitespace.
            name = m.group(1).upper()
            value = m.group(2)
            # Non-Windows hosts: a CONFIG written on Windows keeps working.
            if os.name != "nt" and name in PATH_KEYS:
                value = value.replace("\\", "/")
            into[name] = value


def parse_config(config_path, local_path=None):
    # Last-wins within and across files, as cmd's SET is. lib/kitconfig.ps1
    # implements the same grammar; tests/kitconfig-selftest.ps1 pins it.
    vals = {}
    _read_sets(config_path, vals)
    if local_path is None:
        local_path = Path(config_path).with_name("CONFIG.local.BAT")
    _read_sets(local_path, vals)
    cfg = KitConfig()
    for name, value in vals.items():
        if name == "VIDASPECT":
            cfg.vid_aspect = value
        elif name == "VIDFPS":
            cfg.vid_fps = value
        elif name == "VIDOPTS":
            cfg.vid_opts = value
        elif name == "TOOLSDIR":
            cfg.toolsdir = value or "tools"
        elif name == "VIDTOOLSDIR":
            cfg.vidtoolsdir = value
        elif name == "FFMPEGDIR":
            cfg.ffmpegdir = value
        elif name == "VIDPROFILE":
            cfg.vidprofile = value
        elif name.startswith("VIDOPTS_"):
            suffix = name[len("VIDOPTS_"):]
            if suffix.isdigit() and len(suffix) == 3 and value:
                cfg.per_clip[suffix] = value
    return cfg


@dataclass
class Clip:
    num3: str
    mp4: Path
    vid: Path
    sidecar: Path


def list_clips(kit_root):
    clips = []
    sources = sorted(list(Path(kit_root, "VIDEO").glob("*.mp4")) + list(Path(kit_root, "VIDEO").glob("*.mkv")))
    for mp4 in sources:
        if not mp4.stem.isdigit():
            continue
        vid = mp4.with_suffix(".vid")
        clips.append(Clip(f"{int(mp4.stem):03d}", mp4, vid,
                          Path(str(vid) + ".args")))
    clips.sort(key=lambda c: c.num3)
    return clips


_STAMP_RE = re.compile(r"^\$encoderGeneration = '([A-Za-z0-9]+)'", re.MULTILINE)


def read_generation_stamp(kit_root):
    ps1 = Path(kit_root, "lib", "video.ps1")
    if not ps1.is_file():
        return None
    m = _STAMP_RE.search(ps1.read_text(errors="replace"))
    return m.group(1) if m else None


def arg_hash(stamp, args):
    joined = " ".join([stamp] + list(args))
    return hashlib.md5(joined.encode("utf-8")).hexdigest()[:8]


def clip_state(clip, cfg, stamp):
    tuned = clip.num3 in cfg.per_clip
    if stamp is None or not clip.vid.is_file():
        return tuned, True
    if clip.vid.stat().st_mtime < clip.mp4.stat().st_mtime:
        return tuned, True
    if not clip.sidecar.is_file():
        return tuned, True
    want = arg_hash(stamp, build_arg_vector(cfg, clip.num3))
    have = clip.sidecar.read_text(errors="replace").strip()
    return tuned, have != want
