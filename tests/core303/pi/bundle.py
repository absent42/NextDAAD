"""Bundle and frames hashes: sha256 over '<path> <sha256>' lines, first 12 hex digits."""
import hashlib
from pathlib import Path


class BundleError(Exception):
    pass


def _digest(entries):
    lines = "".join("%s %s\n" % (p, hashlib.sha256(data).hexdigest())
                    for p, data in sorted(entries))
    return hashlib.sha256(lines.encode("ascii")).hexdigest()[:12]


def bundle_hash(root):
    root = Path(root)
    names = [n.strip() for n in (root / "BUNDLE.txt").read_text(encoding="ascii").splitlines()
             if n.strip()]
    entries = []
    for n in names:
        f = root / n
        if not f.is_file():
            raise BundleError("BUNDLE.txt lists a missing file: %s" % n)
        entries.append((n, f.read_bytes()))
    return _digest(entries)


def dir_hash(path):
    path = Path(path)
    return _digest((f.relative_to(path).as_posix(), f.read_bytes())
                   for f in path.rglob("*") if f.is_file())
