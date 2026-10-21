"""Accept-time writes: the VIDOPTS_NNN line and the .vid.args sidecar.
Writes the VIDOPTS_NNN line to the game's <GAME>.CFG, or to
CONFIG.local.BAT in legacy mode; CONFIG.BAT is never modified."""
import os
import re
from pathlib import Path

from .kitmodel import arg_hash, parse_config


class ConfigConflict(Exception):
    """A config layer changed on disk since it was loaded."""


class StarterProtected(Exception):
    """The VIDOPTS target is inside the shipped STARTER\\ folder."""


class LocalOverride(Exception):
    """CONFIG.local.BAT defines the VIDOPTS_NNN a game .CFG write targets."""


STARTER_MESSAGE = ("STARTER\\ is replaced by every kit update - copy it to "
                   "your own game folder and tune the copy.")

NEW_LOCAL_HEADER = (b"@echo off\r\n"
                    b"REM Machine-local settings; read after CONFIG.BAT and "
                    b"survive kit updates.\r\n")
NEW_GAME_HEADER = (b"REM Game settings; read after CONFIG.BAT, before "
                   b"CONFIG.local.BAT.\r\n")


def _line_re(num3):
    return re.compile(rb'^\s*set\s+"?VIDOPTS_' + num3.encode() + rb"=.*$",
                      re.IGNORECASE)


def local_path_for(config_path):
    return Path(config_path).with_name("CONFIG.local.BAT")


def _mtime(p):
    return p.stat().st_mtime if p is not None and p.is_file() else None


def config_stamp(config_path, game_cfg=None):
    """mtimes of CONFIG.BAT, the game .CFG and CONFIG.local.BAT (None if absent)."""
    return (Path(config_path).stat().st_mtime,
            _mtime(None if game_cfg is None else Path(game_cfg)),
            _mtime(local_path_for(config_path)))


def _in_starter(config_path, target):
    kit = Path(config_path).resolve().parent
    try:
        rel = Path(target).resolve().relative_to(kit)
    except ValueError:
        return False
    return len(rel.parts) > 1 and rel.parts[0].casefold() == "starter"


def _split_lines(raw, default_eol):
    """[[text, ending], ...]; each line keeps its own ending, and a final
    line without one gets default_eol."""
    parts = raw.split(b"\n")
    unterminated = parts[-1] != b""
    if not unterminated:
        parts.pop()
    lines = []
    for i, ln in enumerate(parts):
        if i == len(parts) - 1 and unterminated:
            lines.append([ln, default_eol])
        elif ln.endswith(b"\r"):
            lines.append([ln[:-1], b"\r\n"])
        else:
            lines.append([ln, b"\n"])
    return lines


def write_vidopts_line(config_path, num3, opts, expected_stamp=None,
                       target_path=None):
    config_path = Path(config_path)
    local = local_path_for(config_path)
    loc = local if target_path is None else Path(target_path)
    if _in_starter(config_path, loc):
        raise StarterProtected(STARTER_MESSAGE)
    # Any target other than CONFIG.local.BAT is the game .CFG layer.
    game_cfg = None if loc == local else loc
    if (expected_stamp is not None
            and config_stamp(config_path, game_cfg) != expected_stamp):
        raise ConfigConflict(
            "a config file changed on disk since it was loaded - reload first")
    if game_cfg is not None and local.is_file():
        # CONFIG.local.BAT is read last, so its line would mask the .CFG write.
        if any(_line_re(num3).match(ln.rstrip(b"\r"))
               for ln in local.read_bytes().split(b"\n")):
            raise LocalOverride(
                f"VIDOPTS_{num3} in CONFIG.local.BAT overrides {loc.name} - "
                f"move that line into {loc.name}, then accept again.")
    # Both targets sit directly above CONFIG.BAT, so it alone is the base.
    base = parse_config(config_path, local_path=local.with_name("no.local")
                        ).per_clip.get(num3, "")
    existed = loc.is_file()
    raw = loc.read_bytes() if existed else (
        NEW_LOCAL_HEADER if game_cfg is None else NEW_GAME_HEADER)
    default_eol = b"\r\n" if (not raw or b"\r\n" in raw) else b"\n"
    lines = _split_lines(raw, default_eol)
    target = _line_re(num3)
    any_vidopts = re.compile(rb'^\s*set\s+"?VIDOPTS', re.IGNORECASE)
    new_text = b"SET VIDOPTS_%s=%s" % (num3.encode(), opts.encode())

    idx = next((i for i, ln in enumerate(lines) if target.match(ln[0])), None)
    changed = True
    if idx is not None:
        if opts or base:
            lines[idx][0] = new_text
        else:
            del lines[idx]
    elif opts or base:
        last = [i for i, ln in enumerate(lines) if any_vidopts.match(ln[0])]
        at = max(last) + 1 if last else len(lines)
        lines.insert(at, [new_text, default_eol])
    else:
        changed = False

    wrote_bak = False
    if changed:
        if existed:
            loc.with_name(loc.name + ".bak").write_bytes(raw)
            wrote_bak = True
        tmp = loc.with_name(loc.name + ".tmp")
        try:
            tmp.write_bytes(b"".join(t + e for t, e in lines))
            os.replace(tmp, loc)
        except BaseException:
            tmp.unlink(missing_ok=True)
            raise

    got = parse_config(config_path, game_cfg=game_cfg).per_clip.get(num3, "")
    if got != opts:
        hint = ""
        if wrote_bak:
            hint = f" - restore from {loc.name}.bak"
        elif changed and not existed:
            hint = f" - delete the new {loc.name}"
        raise RuntimeError(
            f"{loc.name} verification failed: VIDOPTS_{num3} reads back "
            f"as '{got}', expected '{opts}'{hint}")


def write_sidecar(sidecar, stamp, args):
    Path(sidecar).write_bytes(arg_hash(stamp, args).encode())
