"""Knob schema and video.ps1-faithful argument vectors.

The arg vector built here must be IDENTICAL to lib/video.ps1's - it is
both the encode argv and the sidecar hash input. video.ps1 is the
authority; tests/vidtune/test_settingsmodel.py carries its rule table.

Maintenance contract: repo docs/vidtune-maintenance.md"""
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
    kind: str        # choice | float | flag | str | flagstr
    default: object  # None = encoder-derived / unset
    level: str       # basic | advanced
    # flagstr only: the encoder's own bare-flag CONST value, shown as a
    # GUI placeholder hint (e.g. "checked + empty" reads as "the
    # conservative default") - never itself emitted; the encoder applies
    # its own const when vidtune sends the bare flag. Optional/keyword
    # so every pre-existing Knob(...) row (5 positional args) is
    # untouched.
    const: object = None
    # Short explanation shown as the row label's tooltip - optional
    # (most existing rows have none; the panel is largely self-
    # explanatory from the flag name + videnc's own --help for detail).
    tooltip: str = ""


KNOBS = [
    Knob("shape",         "--shape",         "choice", "full",   "basic"),
    Knob("fps",           "--fps",           "float",  "25",     "basic"),
    Knob("mono",          "--mono",          "flag",   False,    "basic"),
    Knob("dither",        "--dither",        "float",  "0.5",    "basic"),
    Knob("tile_slack",    "--tile-slack",    "float",  "0.0",    "basic"),
    # prefilter is basic, not advanced: the kit's own VIDEO-PRESETS.md
    # makes it Preset 4 and step 3 of the Preset 6 anti-banding ladder -
    # front-line authoring guidance, not an expert knob.
    Knob("prefilter",     "--prefilter",     "flagstr", False,   "basic",
         const="hqdn3d=2:1.5:3:2.25",
         tooltip="light temporal denoise before scaling - trades a little "
                 "texture for supply headroom on grainy sources"),
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
    # kf_cadence's videnc argparse default is None, but the encoder
    # applies 5.0 internally when untouched - "5.0" here means an
    # untouched knob emits nothing (matches the encoder's own silent
    # default), and "0" (a real, meaningful value - it DISABLES the
    # cadence) must still emit `--kf-cadence 0` since it differs from
    # the "5.0" reference.
    Knob("kf_cadence",    "--kf-cadence",    "float",  "5.0",    "advanced",
         tooltip="rolling-refresh window in seconds; 0 disables"),
    Knob("approx_cuts",   "--approx-cuts",   "flag",   False,    "advanced",
         tooltip="experimental: approximate full-coverage content on "
                 "budget-bound frames instead of deferring bands"),
    Knob("ocopy",         "--ocopy",         "flag",   False,    "advanced",
         tooltip="opt-in: emit detected whole-pixel pans as offset-copy frames"),
    # Deliberately NOT added: --no-merge (bench-fixture-only; production
    # encodes keep merge-gaps on, this is not an authoring knob) and
    # --direct-transport-factor (expert override for the --direct gate's
    # transport-factor constant, out of scope for the tuning panel).
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
        elif k.kind == "flagstr":
            # argparse nargs="?": the next token is a VALUE only if one
            # is present and it does not itself look like a flag - bare
            # "--prefilter" (end of list, or immediately followed by
            # another --flag) means "on, encoder's own const default".
            if i + 1 < len(tokens) and not tokens[i + 1].startswith("--"):
                known[k.name] = tokens[i + 1]
                i += 1
            else:
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


def _extra_units(tokens):
    """Groups an extra-token list into (flag,)/(flag, value) units - a
    unit is a token starting with "--" plus, if present, the following
    token when that one does NOT itself start with "--" (mirrors
    parse_opts's own "keep an unknown flag's value token with it"
    rule); a bare leftover token (parse_opts's dangling-value
    passthrough) is its own single-token unit. deviations() diffs whole
    units, not individual tokens - see its own docstring note for why a
    per-token diff orphans a changed value."""
    units = []
    i = 0
    while i < len(tokens):
        t = tokens[i]
        if t.startswith("--") and i + 1 < len(tokens) \
                and not tokens[i + 1].startswith("--"):
            units.append((t, tokens[i + 1]))
            i += 2
        else:
            units.append((t,))
            i += 1
    return units


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
        elif k.kind == "flagstr":
            # False/None = off (emit nothing, already skipped above when
            # cur == ref); True = on with the encoder's own const
            # default (bare flag); a str = on with an explicit filter
            # (flag + value).
            if cur:
                out.append(k.flag)
                if isinstance(cur, str):
                    out.append(cur)
        elif cur is not None:
            out += [k.flag, str(cur)]
    # Per-token filtering here used to orphan a changed value: a global
    # "--foo A" + a per-clip "--foo B" left "--foo" filtered out (it's
    # in base) but "B" kept (it isn't), emitting a bare "B" with no
    # flag - silently corrupting the arg vector. Theoretical until
    # --prefilter (an extra-passthrough option that carries a value)
    # made it real. Diff whole (flag[, value]) units instead - a unit is
    # emitted (in full) only when it has no exact match in base's units.
    base_units = _extra_units(base.get("extra", []))
    for unit in _extra_units(settings.get("extra", [])):
        if unit not in base_units:
            out += list(unit)
    return out
