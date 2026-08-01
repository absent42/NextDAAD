"""Kit discovery and CONFIG.BAT reading for vidtune.

Mirrors lib/video.ps1's reading of the same file - that script is the
authority; on any divergence, video.ps1 wins and this module is wrong.
"""
import re
from dataclasses import dataclass, field
from pathlib import Path

_SET_RE = re.compile(r"^\s*set\s+([A-Za-z0-9_]+)=(.*)$", re.IGNORECASE)


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
    per_clip: dict = field(default_factory=dict)
    vidprofile: str = ""


def parse_config(config_path):
    cfg = KitConfig()
    seen = set()
    for line in Path(config_path).read_text(errors="replace").splitlines():
        m = _SET_RE.match(line)
        if not m:
            continue
        name, value = m.group(1).upper(), m.group(2).strip()
        if name in seen:
            continue
        seen.add(name)
        if name == "VIDASPECT":
            cfg.vid_aspect = value
        elif name == "VIDFPS":
            cfg.vid_fps = value
        elif name == "VIDOPTS":
            cfg.vid_opts = value
        elif name == "TOOLSDIR":
            cfg.toolsdir = value or "tools"
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
    for mp4 in sorted(Path(kit_root, "VIDEO").glob("*.mp4")):
        if not mp4.stem.isdigit():
            continue
        vid = mp4.with_suffix(".vid")
        clips.append(Clip(f"{int(mp4.stem):03d}", mp4, vid,
                          Path(str(vid) + ".args")))
    clips.sort(key=lambda c: c.num3)
    return clips
