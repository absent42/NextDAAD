"""Accept-time writes: the single VIDOPTS_NNN line and the .vid.args
sidecar. Everything else in CONFIG.BAT is preserved byte-for-byte."""
import re
from pathlib import Path

from .kitmodel import arg_hash, parse_config


class ConfigConflict(Exception):
    """CONFIG.BAT changed on disk since it was loaded."""


def _line_re(num3):
    return re.compile(rb"^\s*set\s+VIDOPTS_" + num3.encode() + rb"=.*$",
                      re.IGNORECASE)


def write_vidopts_line(config_path, num3, opts, expected_mtime=None):
    path = Path(config_path)
    if expected_mtime is not None and path.stat().st_mtime != expected_mtime:
        raise ConfigConflict(
            "CONFIG.BAT changed on disk since it was loaded - reload first")
    raw = path.read_bytes()
    eol = b"\r\n" if b"\r\n" in raw else b"\n"
    lines = raw.split(eol)
    target = _line_re(num3)
    any_vidopts = re.compile(rb"^\s*set\s+VIDOPTS", re.IGNORECASE)
    new_line = b"SET VIDOPTS_%s=%s" % (num3.encode(), opts.encode())

    idx = next((i for i, ln in enumerate(lines) if target.match(ln)), None)
    if idx is not None:
        if opts:
            lines[idx] = new_line
        else:
            del lines[idx]
    elif opts:
        # Find the LAST VIDOPTS line
        vidopts_indices = [i for i, ln in enumerate(lines) if any_vidopts.match(ln)]
        if vidopts_indices:
            last = max(vidopts_indices)
            lines.insert(last + 1, new_line)
        else:
            # No VIDOPTS line found, insert before trailing sentinel if present
            if lines and lines[-1] == b'':
                lines.insert(len(lines) - 1, new_line)
            else:
                lines.append(new_line)

    path.with_suffix(".BAT.bak").write_bytes(raw)
    path.write_bytes(eol.join(lines))

    got = parse_config(path).per_clip.get(num3, "")
    if got != opts:
        raise RuntimeError(
            f"CONFIG.BAT verification failed: VIDOPTS_{num3} reads back as "
            f"'{got}', expected '{opts}' - restore from CONFIG.BAT.bak")


def write_sidecar(sidecar, stamp, args):
    Path(sidecar).write_bytes(arg_hash(stamp, args).encode())
