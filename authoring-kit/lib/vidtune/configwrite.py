"""Accept-time writes: the VIDOPTS_NNN line and the .vid.args sidecar.
Writes the VIDOPTS_NNN line to CONFIG.local.BAT; CONFIG.BAT is never
modified."""
import re
from pathlib import Path

from .kitmodel import arg_hash, parse_config


class ConfigConflict(Exception):
    """CONFIG.BAT or CONFIG.local.BAT changed on disk since it was loaded."""


NEW_LOCAL_HEADER = (b"@echo off\r\n"
                    b"REM Machine-local settings; read after CONFIG.BAT and "
                    b"survive kit updates.\r\n")


def _line_re(num3):
    return re.compile(rb"^\s*set\s+VIDOPTS_" + num3.encode() + rb"=.*$",
                      re.IGNORECASE)


def local_path_for(config_path):
    return Path(config_path).with_name("CONFIG.local.BAT")


def config_stamp(config_path):
    """(mtime of CONFIG.BAT, mtime of CONFIG.local.BAT or None)."""
    loc = local_path_for(config_path)
    return (Path(config_path).stat().st_mtime,
            loc.stat().st_mtime if loc.is_file() else None)


def write_vidopts_line(config_path, num3, opts, expected_stamp=None):
    config_path = Path(config_path)
    if expected_stamp is not None and config_stamp(config_path) != expected_stamp:
        raise ConfigConflict(
            "CONFIG.BAT or CONFIG.local.BAT changed on disk since it was "
            "loaded - reload first")
    loc = local_path_for(config_path)
    base = parse_config(config_path, local_path=loc.with_name("no.local")
                        ).per_clip.get(num3, "")
    existed = loc.is_file()
    raw = loc.read_bytes() if existed else NEW_LOCAL_HEADER
    eol = b"\r\n" if (not existed or b"\r\n" in raw) else b"\n"
    lines = raw.split(eol)
    if lines[-1] == b"":
        lines.pop()
    target = _line_re(num3)
    any_vidopts = re.compile(rb"^\s*set\s+VIDOPTS", re.IGNORECASE)
    new_line = b"SET VIDOPTS_%s=%s" % (num3.encode(), opts.encode())

    idx = next((i for i, ln in enumerate(lines) if target.match(ln)), None)
    if idx is not None:
        if opts or base:
            lines[idx] = new_line
        else:
            del lines[idx]
    elif opts or base:
        last = [i for i, ln in enumerate(lines) if any_vidopts.match(ln)]
        lines.insert(max(last) + 1 if last else len(lines), new_line)
    else:
        return

    if existed:
        loc.with_name("CONFIG.local.BAT.bak").write_bytes(raw)
    loc.write_bytes(eol.join(lines) + eol)

    got = parse_config(config_path).per_clip.get(num3, "")
    if got != opts:
        raise RuntimeError(
            f"CONFIG.local.BAT verification failed: VIDOPTS_{num3} reads back "
            f"as '{got}', expected '{opts}' - restore from CONFIG.local.BAT.bak")


def write_sidecar(sidecar, stamp, args):
    Path(sidecar).write_bytes(arg_hash(stamp, args).encode())
