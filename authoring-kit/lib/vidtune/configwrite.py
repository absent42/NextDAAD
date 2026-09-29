"""Accept-time writes: the VIDOPTS_NNN line and the .vid.args sidecar.
Writes the VIDOPTS_NNN line to CONFIG.local.BAT; CONFIG.BAT is never
modified."""
import os
import re
from pathlib import Path

from .kitmodel import arg_hash, parse_config


class ConfigConflict(Exception):
    """CONFIG.BAT or CONFIG.local.BAT changed on disk since it was loaded."""


NEW_LOCAL_HEADER = (b"@echo off\r\n"
                    b"REM Machine-local settings; read after CONFIG.BAT and "
                    b"survive kit updates.\r\n")


def _line_re(num3):
    return re.compile(rb'^\s*set\s+"?VIDOPTS_' + num3.encode() + rb"=.*$",
                      re.IGNORECASE)


def local_path_for(config_path):
    return Path(config_path).with_name("CONFIG.local.BAT")


def config_stamp(config_path):
    """(mtime of CONFIG.BAT, mtime of CONFIG.local.BAT or None)."""
    loc = local_path_for(config_path)
    return (Path(config_path).stat().st_mtime,
            loc.stat().st_mtime if loc.is_file() else None)


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
            loc.with_name("CONFIG.local.BAT.bak").write_bytes(raw)
            wrote_bak = True
        tmp = loc.with_name("CONFIG.local.BAT.tmp")
        try:
            tmp.write_bytes(b"".join(t + e for t, e in lines))
            os.replace(tmp, loc)
        except BaseException:
            tmp.unlink(missing_ok=True)
            raise

    got = parse_config(config_path).per_clip.get(num3, "")
    if got != opts:
        hint = ""
        if wrote_bak:
            hint = " - restore from CONFIG.local.BAT.bak"
        elif changed and not existed:
            hint = " - delete the new CONFIG.local.BAT"
        raise RuntimeError(
            f"CONFIG.local.BAT verification failed: VIDOPTS_{num3} reads back "
            f"as '{got}', expected '{opts}'{hint}")


def write_sidecar(sidecar, stamp, args):
    Path(sidecar).write_bytes(arg_hash(stamp, args).encode())
