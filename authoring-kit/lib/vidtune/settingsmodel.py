"""Knob schema and video.ps1-faithful argument vectors.

The arg vector built here must be IDENTICAL to lib/video.ps1's - it is
both the encode argv and the sidecar hash input. video.ps1 is the
authority; tests/vidtune/test_settingsmodel.py carries its rule table."""
import re
from dataclasses import dataclass

SHAPE_PRESETS = ("full", "16:9", "scope", "classic", "classic-wide")


class VidprofileUnsupported(Exception):
    """VIDPROFILE is a deprecated video.ps1-only shim; tell the user to
    set VIDASPECT instead."""


@dataclass
class Knob:
    name: str
    flag: str
    kind: str        # choice | float | flag | str
    default: object  # None = encoder-derived / unset
    level: str       # basic | advanced


KNOBS = [
    Knob("shape",         "--shape",         "choice", "full",   "basic"),
    Knob("fps",           "--fps",           "float",  "25",     "basic"),
    Knob("mono",          "--mono",          "flag",   False,    "basic"),
    Knob("dither",        "--dither",        "float",  "0.5",    "basic"),
    Knob("tile_slack",    "--tile-slack",    "float",  "0.0",    "basic"),
    Knob("start",         "--start",         "str",    None,     "basic"),
    Knob("duration",      "--duration",      "str",    None,     "basic"),
    Knob("retime",        "--retime",        "choice", "blend",  "advanced"),
    Knob("dither_mode",   "--dither-mode",   "choice", "offset", "advanced"),
    Knob("aspect",        "--aspect",        "float",  None,     "advanced"),
    Knob("width",         "--width",         "choice", None,     "advanced"),
    Knob("stream_budget", "--stream-budget", "float",  None,     "advanced"),
    Knob("budget_target", "--budget-target", "float",  "0.90",   "advanced"),
    Knob("byte_cap",      "--byte-cap",      "float",  "0.65",   "advanced"),
    Knob("direct",        "--direct",        "flag",   False,    "advanced"),
]
_BY_FLAG = {k.flag: k for k in KNOBS}
_BY_NAME = {k.name: k for k in KNOBS}


def split_opts(opt_str):
    return [t for t in re.split(r"\s+", opt_str or "") if t]


def _shape_args(vid_aspect):
    a = vid_aspect
    if re.fullmatch(r"full|16:9|scope|classic|classic-wide", a):
        return ["--shape", a]
    if re.fullmatch(r"\d{2,4}x\d{1,4}", a):
        return ["--shape", a]
    if re.fullmatch(r"\d+([.,]\d+)?", a):
        return ["--aspect", a.replace(",", ".")]
    raise ValueError(
        f"VIDASPECT '{a}' not understood - accepted forms: a preset "
        f"({', '.join(SHAPE_PRESETS)}), an explicit WIDTHxHEIGHT "
        f"(e.g. 320x150), or a decimal aspect ratio (e.g. 2.35 or 2,35)")


def build_arg_vector(cfg, num3):
    if cfg.vidprofile and not cfg.vid_aspect:
        raise VidprofileUnsupported(
            "VIDPROFILE is deprecated and not supported by vidtune - "
            "set VIDASPECT in CONFIG.BAT instead")
    per = split_opts(cfg.per_clip.get(num3, ""))
    per_has_shape = any(t in ("--shape", "--width", "--aspect") for t in per)
    shape = [] if (per_has_shape or not cfg.vid_aspect) \
        else _shape_args(cfg.vid_aspect)
    fps = ["--fps", cfg.vid_fps] if cfg.vid_fps else []
    return shape + fps + split_opts(cfg.vid_opts) + per


def parse_opts(tokens):
    known, extra = {}, []
    i = 0
    while i < len(tokens):
        t = tokens[i]
        k = _BY_FLAG.get(t)
        if k is None:
            extra.append(t)
            # keep an unknown flag's value token with it, if one follows
            if t.startswith("--") and i + 1 < len(tokens) \
                    and not tokens[i + 1].startswith("--"):
                extra.append(tokens[i + 1])
                i += 1
        elif k.kind == "flag":
            known[k.name] = True
        else:
            if i + 1 >= len(tokens):
                extra.append(t)          # dangling value flag: passthrough
            else:
                known[k.name] = tokens[i + 1]
                i += 1
        i += 1
    return known, extra


def _kit_base(cfg):
    """Settings dict for 'kit defaults': encoder defaults + VIDASPECT/
    VIDFPS/VIDOPTS (per-clip NOT applied)."""
    s = {k.name: k.default for k in KNOBS}
    s["extra"] = []
    if cfg.vid_aspect:
        sh = _shape_args(cfg.vid_aspect)
        if sh[0] == "--shape":
            s["shape"] = sh[1]
        else:
            s["aspect"] = sh[1]
    if cfg.vid_fps:
        s["fps"] = cfg.vid_fps
    known, extra = parse_opts(split_opts(cfg.vid_opts))
    s.update(known)
    s["extra"] = extra
    return s


def effective_settings(cfg, num3):
    s = _kit_base(cfg)
    known, extra = parse_opts(split_opts(cfg.per_clip.get(num3, "")))
    s.update(known)
    s["extra"] = s["extra"] + extra
    return s


def deviations(settings, cfg):
    base = _kit_base(cfg)
    out = []
    for k in KNOBS:
        cur, ref = settings.get(k.name), base.get(k.name)
        if cur == ref:
            continue
        if k.kind == "flag":
            if cur:
                out.append(k.flag)
        elif cur is not None:
            out += [k.flag, str(cur)]
    out += [t for t in settings.get("extra", []) if t not in base["extra"]]
    return out
