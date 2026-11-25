"""Route presets, the prefilter modifier, and the anti-banding ladder.

Pure logic - no Qt - so the semantics below can be tested without a
widget. The Qt surface lives in presetrow.py.

CONTENT AUTHORITY is the manual's Video page, section 4 "The presets" -
`authoring-kit/docs/video.html`. Every option string here is transcribed
from it; if a preset changes there, this file follows. That page is
GENERATED, so edit it at its repo source, not in the kit.

The six things in that doc are three different kinds of object, and this
module keeps them apart:

  ROUTES    presets 3/2/1/5 - a complete answer for a class of footage,
            mutually exclusive, each with optional framing VARIANTS
            (the same routing decision at other crops)
  MODIFIER  preset 4 - `--prefilter`, added ON TOP of whichever route is
            in use. It is already a real Knob, so there is no separate
            state for it here; MODIFIER_KNOB just names it.
  LADDER    preset 6 - an ordered workflow to walk when a compressed
            encode bands, not a setting.

Nothing here writes anything. A preset stamps panel values and stops;
Accept already turns those into `VIDOPTS_NNN` via `deviations()`, so
presets never touch CONFIG.BAT, never introduce a preset name into it,
and never bypass the deviation logic.
"""
from dataclasses import dataclass, field

# Knobs a ROUTE owns, and therefore resets to kit defaults before
# stamping its own values. Without the reset, leftovers from a previous
# route persist (a stale `--fps 12.5` surviving a switch to a preset
# that never mentions fps) and the preset does not mean what it says.
ROUTE_KNOBS = ("shape", "width", "aspect", "fps", "tile_slack", "direct")

# Explicitly NOT reset by a route: the modifier is orthogonal to routing,
# and trim belongs to the clip, not the route. Listed rather than merely
# omitted so the intent survives someone extending ROUTE_KNOBS.
PRESERVED_KNOBS = ("prefilter", "start", "duration")

MODIFIER_KNOB = "prefilter"

# shape/width/aspect are three ways of saying the same thing, and
# `build_arg_vector` treats any of them as "the per-clip settings carry a
# shape". A route that stamps a shape must therefore clear the other two,
# or a kit whose VIDASPECT is a decimal ends up emitting `--shape 16:9
# --aspect 2.35` together.
_SHAPE_ALIASES = ("width", "aspect")


@dataclass(frozen=True)
class Route:
    key: str
    label: str
    blurb: str                        # what class of footage this is for
    values: dict = field(default_factory=dict)
    variants: tuple = ()              # the same route at other crops


# Transcribed from authoring-kit/docs/video.html section 4. Preset 1 is
# "nothing at all - the kit defaults are the right answer", which is why
# its values are empty: applying it IS the reset. Direct shapes and rates
# follow the raw gate (tests/raw_presets.py prints its verdicts).
# Menu order: the opening route first, then action, quiet, cutscene.
ROUTES = (
    Route("fullrate", "Action at full rate",
          "the same detailed motion, when smooth movement matters more "
          "than picture size - 256x192 at 25 fps",
          {"direct": True, "shape": "256x192"},
          (Route("fullrate-wide", "Action at full rate, wide",
                 "a cinematic wide framing at full width, 320x160",
                 {"direct": True, "shape": "320x160"}),
           Route("fullrate-tall", "Action at full rate, tall",
                 "a taller picture at 25 fps, 280x224 - at the edge of "
                 "what the card delivers",
                 {"direct": True, "shape": "280x224"}))),
    Route("action", "Full-screen action",
          "detailed sustained motion filling the frame - sea, weather, "
          "snow, crowds, smoke - at 320x240 and 16.67 fps",
          {"direct": True, "shape": "320x240", "fps": "16.67"},
          (Route("action-169", "Full-screen action, 16:9 source",
                 "the same route using a 16:9 source's own shape, 320x192",
                 {"direct": True, "shape": "16:9", "fps": "16.67"}),
           Route("action-tall", "Full-screen action, narrower",
                 "256x240: the same height, narrower than the screen with "
                 "black at the sides, for a fifth less card space",
                 {"direct": True, "shape": "256x240", "fps": "16.67"}))),
    Route("quiet", "Quiet scene",
          "slow zooms and pans, held shots, talking heads, title cards",
          {},
          (Route("quiet-motion", "Quiet scene, continuous motion",
                 "a zoom or pan that never stops rather than a static shot",
                 {"tile_slack": "0.5"}),)),
    Route("cutscene", "Long cutscene",
          "anything over about 15 seconds - length forces the compressed "
          "route, so the decision moves to the shape",
          {"shape": "16:9", "tile_slack": "0.5"},
          (Route("cutscene-43", "Long cutscene, 4:3 framing",
                 "a 4:3 framing that still needs the room",
                 {"shape": "classic", "tile_slack": "0.5"}),)),
)

# Raw target shapes the gate refuses in both sound forms at their rate, so
# no route: ("WxH", fps, {"stereo": util, "mono": util}).
REFUSED_TARGETS = ()

# Stamped into the panel when a clip with no VIDOPTS_NNN is opened. Panel
# only: nothing is saved until Accept or Encode Stale + Edited.
OPENING_ROUTE = "fullrate"

# Decimal MB, as the manual's card-space table states rates.
_MB = 1_000_000


def _raw_dims(settings):
    """(width, height) the encoder takes from shape/width/aspect."""
    import nxv2enc
    aspect = settings.get("aspect")
    if aspect is not None:
        width = int(settings.get("width")) if settings.get("width") else 320
        return width, nxv2enc.derive_free_height(width, float(aspect))
    shape = settings.get("shape") or "full"
    if shape in nxv2enc.PRESETS:
        return nxv2enc.PRESETS[shape]
    w, h = str(shape).lower().split("x", 1)
    return int(w), int(h)


def raw_rate(settings):
    """Card cost of an uncompressed encode, or None when not --direct:
    dict(width, height, fps, form, frame_bytes, per_second). frame_bytes is
    sound in the form the raw gate picks (gate options in extra honoured)
    plus pixel sectors; a scene's palette sector (512 B) and the scene-cut
    mono fallback are not counted. form None: the gate refuses."""
    if not settings.get("direct"):
        return None
    import nxv2enc
    try:
        w, h = _raw_dims(settings)
        fps = float(settings.get("fps") or 25)
        extra = list(settings.get("extra") or [])

        def opt(name, default):
            return extra[extra.index(name) + 1] if name in extra[:-1] else default

        sw, _ = nxv2enc.raw_surface(w, h, opt("--direct-surface", "auto"))
        want = opt("--direct-sound", "auto")
        tf = opt("--direct-transport-factor", None)
        kw = dict(transport_factor=None if tf is None else float(tf),
                  stall_budget=opt("--stall-budget", "off"))
        forms = ("stereo", "mono") if want == "auto" else (want,)
        form = next((f for f in forms if nxv2enc.raw_supply_check(
            w, h, sw, fps, f, **kw)["utilization"] <= 1.0), None)
    except (SystemExit, ValueError, KeyError, TypeError):
        return None
    out = dict(width=w, height=h, fps=fps, form=form,
               frame_bytes=None, per_second=None)
    if form is not None:
        snd = nxv2enc.audio_layout(fps, 2 if form == "stereo" else 1, raw=True)[3]
        frame = snd + nxv2enc.raw_layout(w, h, sw)["sectors"] * 512
        out.update(frame_bytes=frame, per_second=frame * fps)
    return out


def size_text(settings, seconds=None):
    """One plain line on what `settings` costs on the card; `seconds` is
    the clip's length when known."""
    if not settings.get("direct"):
        return "compressed: size depends on the footage - Encode Full shows it"
    rate = raw_rate(settings)
    if rate is None:
        return "uncompressed: size unknown for this shape"
    if rate["form"] is None:
        return "uncompressed: too much for the card at this shape and rate"
    text = f"uncompressed: {rate['per_second'] / _MB:.2f} MB a second"
    if seconds:
        import nxv2enc
        total = rate["per_second"] * float(seconds)
        text += f", about {total / _MB:.1f} MB for this {float(seconds):.1f} s clip"
        if total > nxv2enc.PLAYER_MAX_BYTES:
            text += " - over the 256 MB file limit"
    return text


def all_routes():
    """Every route and variant, flat - for lookup by key."""
    out = []
    for route in ROUTES:
        out.append(route)
        out.extend(route.variants)
    return out


def route_by_key(key):
    for route in all_routes():
        if route.key == key:
            return route
    return None


def apply_route(settings, kit_base, route):
    """Settings with `route` applied: route knobs reset to kit defaults,
    then the route's own values stamped over them. Returns a NEW dict -
    the caller decides whether to commit it.

    The modifier and the trim knobs pass through untouched, and segment
    markers are not settings at all, so this cannot disturb them."""
    out = dict(settings)
    for name in ROUTE_KNOBS:
        out[name] = kit_base.get(name)
    if "shape" in route.values:
        for alias in _SHAPE_ALIASES:
            out[alias] = None
    out.update(route.values)
    return out


def _fmt(value):
    if value is None or value is False or value == "":
        return "unset"
    if value is True:
        return "on"
    return str(value)


def route_deltas(settings, kit_base, route):
    """[(knob, before, after)] for what applying `route` would change.

    This is what makes the "shape is the user's call" requirement
    structural instead of a special case: rather than warning only when a
    preset would overwrite an explicitly-set shape, every route states
    its whole effect up front, and an overwritten shape is simply one of
    the lines the user reads before choosing."""
    after = apply_route(settings, kit_base, route)
    out = []
    for name in ROUTE_KNOBS:
        before, now = settings.get(name), after.get(name)
        if before == now:
            continue
        out.append((name, before, now))
    return out


def format_delta(name, before, after):
    """One delta as a short human line. A knob turning on or off reads
    better as "+direct"/"-direct" than as "direct on -> unset"."""
    label = name.replace("_", "-")
    if after is True:
        return f"+{label}"
    if before is True and not after:
        return f"-{label}"
    if before is None or before is False or before == "":
        return f"{label} {_fmt(after)}"
    return f"{label} {_fmt(before)} -> {_fmt(after)}"


def format_deltas(deltas):
    return [format_delta(*d) for d in deltas] or ["no change"]


# -- preset 6: the anti-banding ladder ----------------------------------

# Step 2's own ordered sequence. Applying step 2 moves one place along
# it, so a user who has already dropped to 16:9 is offered scope next.
SHAPE_LADDER = ("16:9", "scope", "classic-wide")


def _as_float(value, fallback=None):
    try:
        return float(str(value))
    except (TypeError, ValueError):
        return fallback


def next_shape(settings):
    """The next smaller shape to offer, or None at the end of the run."""
    shape = settings.get("shape")
    if shape not in SHAPE_LADDER:
        return SHAPE_LADDER[0]
    i = SHAPE_LADDER.index(shape)
    return SHAPE_LADDER[i + 1] if i + 1 < len(SHAPE_LADDER) else None


@dataclass
class LadderStep:
    n: int
    label: str
    detail: str
    values: dict = None        # None = advisory only, no button
    routes: tuple = ()         # route keys offered instead of raw values
    done: bool = False
    reason: str = ""           # why it is unavailable, when it is
    # Button caption. Overridden where a step's effect VARIES with the
    # current settings (step 2 walks a run of shapes), so the button says
    # what it is about to do rather than a bare "apply".
    action_label: str = "apply"


def is_uncompressed(settings):
    return bool(settings.get("direct"))


def ladder_steps(settings):
    """The six remedies, resolved against the CURRENT settings.

    `done` is DERIVED here on every call, never stored: a stored ladder
    position would go stale the moment the user edited a knob by hand,
    and would then claim a step was taken that no longer holds. Deriving
    it means the panel is always telling the truth about what has
    actually been set."""
    slack = _as_float(settings.get("tile_slack"), 0.0) or 0.0
    fps = _as_float(settings.get("fps"), 25.0)
    shape = settings.get("shape")
    upcoming = next_shape(settings)

    return [
        LadderStep(
            1, "tile-slack 0.5",
            "the one picture knob worth trying on any clip with "
            "continuous motion; does nothing on static material",
            values={"tile_slack": "0.5"},
            done=slack >= 0.5),
        LadderStep(
            2, "a smaller shape",
            "16:9, then scope, then classic-wide - the biggest lever of "
            "the six, and the first that takes something away",
            values={"shape": upcoming} if upcoming else None,
            done=upcoming is None and shape in SHAPE_LADDER,
            reason="" if upcoming else "already at the end of the run",
            action_label=f"apply {upcoming}" if upcoming else "apply"),
        LadderStep(
            3, "prefilter",
            "only if the source has grain or noise in it",
            values={MODIFIER_KNOB: True},
            done=bool(settings.get(MODIFIER_KNOB))),
        LadderStep(
            4, "fps 12.5",
            "halves the motion rate and gives every remaining frame "
            "twice the room",
            values={"fps": "12.5"},
            done=fps is not None and fps <= 12.5),
        LadderStep(
            5, "the uncompressed route",
            "if the clip is short enough to fit, this ends the argument "
            "- banding is not possible there",
            routes=("action", "fullrate"),
            done=is_uncompressed(settings)),
        LadderStep(
            6, "shorten or re-frame the shot",
            "no setting for this one - a four-second version of a "
            "difficult shot at a shape that works beats twelve seconds "
            "of stripes"),
    ]


def ladder_blocked_reason(settings):
    """Why the whole ladder does not apply, or "" when it does.

    An uncompressed encode cannot band at all (preset 3 in
    authoring-kit/docs/video.html: "no banding, every frame
    pixel-exact"), so offering banding remedies against one would be
    advising a fix for a problem that cannot occur - and step 1 in
    particular has nothing to act on there."""
    if is_uncompressed(settings):
        return ("this clip is on the uncompressed route, where banding is "
                "not possible - these remedies are for compressed encodes")
    return ""


def apply_step(settings, step):
    out = dict(settings)
    out.update(step.values or {})
    return out
