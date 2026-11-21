"""Change-aware step stamps: a step reruns only when its input fingerprint changes.

python tests/stamps.py check SPEC.json [--full]   per step: FRESH<TAB>name<TAB>time | STALE<TAB>name<TAB>reason
python tests/stamps.py check SPEC.json --plan     no writes; FRESH | RESTORE | STALE | PENDING per step
python tests/stamps.py pass [--root R] [--stamp-dir D] NAME...   record NAME as passed
python tests/stamps.py fail [--root R] [--stamp-dir D] NAME...   record NAME as failed

SPEC.json: {"root": R, "stamp_dir": D, "steps": {name: spec}}; root and stamp_dir optional.
A spec names its inputs: "git" (git ls-files pathspecs, tracked plus untracked not ignored),
"files", "trees" (every file below), "globs", "tools" {name: path} and "ident" {key: value}.
Each of those counts by relative path, size and mtime (sources). "hash_files" and "hash_trees"
count by relative path and content: the outputs of another step, so a rerun that writes the same
bytes changes nothing downstream. Python always counts. Outputs, checked before a skip:
"outputs" (files), "output_trees", "hash_outputs" (content instead of mtime) and "cache_dir"
(outputs copied there on a pass, up to "cache_limit" bytes, and restored from there when inputs
match). "cache_guard" names a record of which step last wrote the outputs (those under
"cache_guard_tree" when given): a restore then happens only when another step's write is all that
changed them, so an edit reruns the step. "upstream" lists [{"step", "files"}]: under --plan a
fresh step is PENDING while a listed step is stale on one of "files" (any input when none given).
check writes a pending stamp for every stale step; pass promotes it to tests/out/stamps/<name>.json.
A pending or failed stamp never reads as a pass.
"""
import glob
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

FORMAT = 1
ROOT = Path(__file__).resolve().parent.parent
STAMP_DIR = ROOT / "tests" / "out" / "stamps"


class StampError(Exception):
    pass


def _key(root, p):
    """Posix key for p: relative to root when inside it, else absolute."""
    p = str(p)
    full = p if os.path.isabs(p) else os.path.join(str(root), p)
    full = os.path.normpath(full)
    try:
        rel = os.path.relpath(full, str(root))
    except ValueError:
        rel = None
    if rel is None or rel.startswith(".."):
        return full.replace("\\", "/")
    return rel.replace("\\", "/")


def _full(root, key):
    return key if os.path.isabs(key) else os.path.join(str(root), key)


def _stat(path):
    try:
        st = os.stat(path)
    except OSError:
        return None
    return [st.st_size, st.st_mtime_ns]


def _sha1(path):
    h = hashlib.sha1()
    try:
        with open(path, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                h.update(chunk)
    except OSError:
        return None
    return h.hexdigest()


def _list(v):
    if v is None:
        return []
    return [v] if isinstance(v, str) else list(v)


def git_files(root, pathspecs):
    """Tracked plus untracked-not-ignored files under pathspecs (repo-relative posix)."""
    pathspecs = _list(pathspecs)
    if not pathspecs:
        return []
    r = subprocess.run(["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard", "--",
                        *pathspecs], cwd=str(root), capture_output=True)
    if r.returncode != 0:
        raise StampError("git ls-files failed: " + r.stderr.decode("utf-8", "replace").strip())
    return sorted({f for f in r.stdout.decode("utf-8", "replace").split("\0") if f})


def _tree(root, d, out, value):
    base = _full(root, d)
    if not os.path.isdir(base):
        out[_key(root, d).rstrip("/") + "/"] = None
        return
    for dp, dn, fn in os.walk(base):
        dn.sort()
        for f in fn:
            p = os.path.join(dp, f)
            out[_key(root, p)] = value(p)


def _files(spec, root, git=True, value=_stat, prefix=""):
    out = {}
    if git:
        for f in git_files(root, spec.get(prefix + "git")):
            out[f] = value(_full(root, f))
    for f in _list(spec.get(prefix + "files")):
        out[_key(root, f)] = value(_full(root, f))
    for d in _list(spec.get(prefix + "trees")):
        _tree(root, d, out, value)
    for g in _list(spec.get(prefix + "globs")):
        for p in glob.glob(_full(root, g), recursive=True):
            if os.path.isfile(p):
                out[_key(root, p)] = value(p)
    return out


def python_identity():
    return {"exe": sys.executable, "version": sys.version, "stat": _stat(sys.executable)}


def content(p):
    """[size, sha1] of p, None when missing: an identity that ignores mtime."""
    st = _stat(p)
    return None if st is None else [st[0], _sha1(p)]


def fingerprint(spec, root=ROOT):
    """Input fingerprint: {format, python, files, tools, ident}."""
    tools = {}
    for name, path in sorted((spec.get("tools") or {}).items()):
        tools[name] = [_key(root, path), _stat(_full(root, path))]
    ident = {str(k): str(v) for k, v in sorted((spec.get("ident") or {}).items())}
    files = _files(spec, root)
    files.update(_files({"files": spec.get("hash_files"), "trees": spec.get("hash_trees")}, root,
                        git=False, value=content))
    return {"format": FORMAT, "python": python_identity(), "files": files, "tools": tools, "ident": ident}


def _output_value(spec):
    return content if spec.get("hash_outputs") else _stat


def output_spec(spec):
    keys = ("outputs", "output_trees", "hash_outputs", "cache_dir", "cache_guard", "cache_guard_tree", "cache_limit")
    return {k: spec[k] for k in keys if spec.get(k)}


def output_fingerprint(spec, root=ROOT):
    ospec = output_spec(spec)
    if not ospec.get("outputs") and not ospec.get("output_trees"):
        return None
    o = {"files": ospec.get("outputs"), "trees": ospec.get("output_trees")}
    return _files(o, root, git=False, value=_output_value(ospec))


def describe_files(old, new):
    old, new = old or {}, new or {}
    parts = []
    for label, keys in (("changed", sorted(k for k in old if k in new and old[k] != new[k])),
                        ("added", sorted(k for k in new if k not in old)),
                        ("removed", sorted(k for k in old if k not in new))):
        if keys:
            parts.append(f"{label}: {keys[0]}" + (f" (+{len(keys) - 1})" if len(keys) > 1 else ""))
    return "; ".join(parts) or "differs"


def describe(old, new):
    """First reason old and new fingerprints differ."""
    for sec in ("format", "python", "tools", "ident"):
        o, n = old.get(sec), new.get(sec)
        if o != n:
            if isinstance(o, dict) and isinstance(n, dict):
                keys = sorted(k for k in set(o) | set(n) if o.get(k) != n.get(k))
                return f"{sec} {', '.join(keys[:3])}"
            return sec
    return describe_files(old.get("files"), new.get("files"))


def _name(name):
    return re.sub(r"[^A-Za-z0-9._-]", "_", name)


def _write_json(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp%d" % os.getpid())
    tmp.write_text(json.dumps(data, indent=1, sort_keys=True), encoding="utf-8")
    os.replace(tmp, path)


def _read_json(path):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8-sig"))
    except (OSError, ValueError):
        return None


def read_stamp(name, stamp_dir=STAMP_DIR):
    return _read_json(Path(stamp_dir) / (_name(name) + ".json"))


def _restore(root, name, stamp, ospec, dry=False):
    """Put the cached outputs back when every cached copy matches the stamp. With a
    cache_guard, only when the outputs are exactly what another step last wrote there.
    dry: only say whether it would."""
    cache, want = ospec.get("cache_dir"), stamp.get("outputs") or {}
    if not cache or not want or not (stamp.get("extra_cache") or {}).get("complete"):
        return False
    guard = ospec.get("cache_guard")
    if guard:
        g = _read_json(_full(root, guard))
        if not g or g.get("by") == name or g.get("outputs") != _guarded(ospec, output_fingerprint(ospec, root)):
            return False
    value = _output_value(ospec)
    pairs = []
    for k, v in want.items():
        if os.path.isabs(k):
            return False
        if v is not None:
            src = os.path.join(_full(root, cache), k)
            if value(src) != v:
                return False
            pairs.append((src, _full(root, k)))
    if dry:
        return True
    for k in output_fingerprint(ospec, root) or {}:
        if k not in want or want[k] is None:
            try:
                os.unlink(_full(root, k))
            except OSError:
                pass
    for src, dst in pairs:
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copy2(src, dst)
    got = output_fingerprint(ospec, root)
    if got != want:
        return False
    if guard:
        _write_json(_full(root, guard), {"by": name, "outputs": _guarded(ospec, got)})
    return True


def _guarded(ospec, ofp):
    """The part of an output fingerprint the guard watches: cache_guard_tree, else all."""
    tree = ospec.get("cache_guard_tree")
    if not tree or ofp is None:
        return ofp
    pre = tree.rstrip("/") + "/"
    return {k: v for k, v in ofp.items() if k.startswith(pre)}


def changed_inputs(old, new):
    """Input keys that differ between two fingerprints; None when a tool, ident or python did."""
    for sec in ("format", "python", "tools", "ident"):
        if old.get(sec) != new.get(sec):
            return None
    o, n = old.get("files") or {}, new.get("files") or {}
    return sorted(k for k in set(o) | set(n) if o.get(k) != n.get(k))


def _evaluate(name, spec, root, stamp_dir, full, plan):
    """(state, info, fp, changed): state FRESH, RESTORE (fresh once its cache is put back)
    or STALE; changed lists the input keys behind STALE (None: unknown, assume all)."""
    fp = fingerprint(spec, root)
    if full:
        return "STALE", "full run", fp, None
    st = read_stamp(name, stamp_dir)
    if st is None:
        return "STALE", "no stamp", fp, None
    if st.get("status") != "pass":
        return "STALE", "last run %s" % st.get("status"), fp, None
    if st.get("format") != FORMAT or "inputs" not in st:
        return "STALE", "stamp format", fp, None
    if st["inputs"] != fp:
        return "STALE", describe(st["inputs"], fp), fp, changed_inputs(st["inputs"], fp)
    ospec = output_spec(spec)
    if output_fingerprint(spec, root) != st.get("outputs"):
        if _restore(root, name, st, ospec, dry=plan):
            return "RESTORE", "%s (restored from %s)" % (st.get("time"), ospec["cache_dir"]), fp, []
        return "STALE", "outputs " + describe_files(st.get("outputs"), output_fingerprint(spec, root)), fp, None
    return "FRESH", st.get("time", "?"), fp, []


def _check(name, spec, root, stamp_dir, full):
    state, info, fp, _ = _evaluate(name, spec, root, stamp_dir, full, False)
    return state != "STALE", info, fp


def plan_check(name, spec, root=ROOT, stamp_dir=STAMP_DIR):
    """(state, info, changed) with no writes: FRESH, RESTORE or STALE."""
    state, info, _, changed = _evaluate(name, spec, root, stamp_dir, False, True)
    return state, info, changed


def check(name, spec, root=ROOT, stamp_dir=STAMP_DIR, full=False):
    """(fresh, info): info is the pass time when fresh, else the reason to rerun."""
    fresh, info, _ = _check(name, spec, root, stamp_dir, full)
    return fresh, info


def check_fp(name, spec, root=ROOT, stamp_dir=STAMP_DIR, full=False):
    """As check, plus the input fingerprint to hand to begin after the step ran."""
    return _check(name, spec, root, stamp_dir, full)


def begin(name, spec, root=ROOT, stamp_dir=STAMP_DIR, fp=None):
    """Record the inputs a step is about to run on (pending until commit)."""
    if fp is None:
        fp = fingerprint(spec, root)
    _write_json(Path(stamp_dir) / (_name(name) + ".pending.json"),
                {"step": name, "status": "pending", "format": FORMAT, "inputs": fp,
                 "output_spec": output_spec(spec)})


def commit(name, root=ROOT, stamp_dir=STAMP_DIR, extra=None):
    """Promote the pending stamp to a pass, fingerprinting outputs now."""
    pend = Path(stamp_dir) / (_name(name) + ".pending.json")
    p = _read_json(pend)
    if not p or p.get("status") != "pending" or p.get("step") != name:
        raise StampError("%s: no pending stamp (check before pass)" % name)
    ospec = p.get("output_spec") or {}
    ofp = output_fingerprint(ospec, root)
    cached = False
    if ospec.get("cache_dir") and ofp and not any(os.path.isabs(k) for k in ofp):
        size = sum(v[0] for v in ofp.values() if v)
        if not ospec.get("cache_limit") or size <= int(ospec["cache_limit"]):
            for k, v in ofp.items():
                if v is not None:
                    dst = os.path.join(_full(root, ospec["cache_dir"]), k)
                    os.makedirs(os.path.dirname(dst), exist_ok=True)
                    shutil.copy2(_full(root, k), dst)
            cached = True
    if ospec.get("cache_guard") and ofp is not None:
        _write_json(_full(root, ospec["cache_guard"]), {"by": name, "outputs": _guarded(ospec, ofp)})
    st = {"step": name, "status": "pass", "format": FORMAT, "time": time.strftime("%Y-%m-%d %H:%M:%S"),
          "inputs": p["inputs"], "outputs": ofp, "output_spec": ospec, "extra": extra,
          "extra_cache": {"complete": cached}}
    _write_json(Path(stamp_dir) / (_name(name) + ".json"), st)
    pend.unlink()
    return st


def fail(name, root=ROOT, stamp_dir=STAMP_DIR):
    """Record a failed run; it is never read as a pass."""
    _write_json(Path(stamp_dir) / (_name(name) + ".json"),
                {"step": name, "status": "fail", "format": FORMAT, "time": time.strftime("%Y-%m-%d %H:%M:%S")})
    try:
        (Path(stamp_dir) / (_name(name) + ".pending.json")).unlink()
    except OSError:
        pass


def _opts(argv):
    root, sd, names, i = ROOT, None, [], 0
    while i < len(argv):
        if argv[i] == "--root":
            root, i = Path(argv[i + 1]), i + 2
        elif argv[i] == "--stamp-dir":
            sd, i = Path(argv[i + 1]), i + 2
        else:
            names.append(argv[i])
            i += 1
    return root, sd or (Path(root) / "tests" / "out" / "stamps"), names


def main(argv):
    if len(argv) >= 2 and argv[0] == "check":
        spec = _read_json(argv[1])
        if spec is None:
            print("stamps: cannot read %s" % argv[1], file=sys.stderr)
            return 2
        root = Path(spec.get("root") or ROOT)
        sd = Path(spec.get("stamp_dir") or root / "tests" / "out" / "stamps")
        full = "--full" in argv[2:] or bool(spec.get("full"))
        steps = spec.get("steps") or {}
        if "--plan" in argv[2:]:
            res = {n: plan_check(n, s, root, sd) for n, s in steps.items()}
            for n, s in steps.items():
                for u in s.get("upstream") or []:
                    us = res.get(u.get("step"))
                    if res[n][0] == "STALE" or not us or us[0] != "STALE":
                        continue
                    want = set(_files({"files": u.get("files"), "git": u.get("git")}, root))
                    if us[2] is None or not want or want & set(us[2]):
                        res[n] = ("PENDING", "%s reruns first (%s)" % (u["step"], us[1]), None)
            for n in steps:
                print("%s\t%s\t%s" % (res[n][0], n, res[n][1]), flush=True)
            return 0
        for name, s in steps.items():
            fresh, info, fp = _check(name, s, root, sd, full)
            if not fresh:
                begin(name, s, root, sd, fp)
            print("%s\t%s\t%s" % ("FRESH" if fresh else "STALE", name, info), flush=True)
        return 0
    if len(argv) >= 2 and argv[0] in ("pass", "fail"):
        root, sd, names = _opts(argv[1:])
        for name in names:
            if argv[0] == "pass":
                commit(name, root, sd)
            else:
                fail(name, root, sd)
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except StampError as e:
        print("stamps: %s" % e, file=sys.stderr)
        sys.exit(2)
