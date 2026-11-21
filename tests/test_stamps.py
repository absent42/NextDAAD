"""Host checks for tests/stamps.py (change-aware step stamps). No emulator, no repo writes.

python tests/test_stamps.py [name ...]   prints PASS name / FAIL name: why; exit 1 on any FAIL
Also run by python tests/cspect/selftest.py --host.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
try:
    import stamps
    IMPORT_ERROR = None
except ImportError as e:
    stamps = None
    IMPORT_ERROR = e


class CheckFailed(Exception):
    pass


def need(cond, why):
    if not cond:
        raise CheckFailed(why)


class Box:
    """A scratch root with its own stamp folder."""

    def __init__(self):
        self.dir = Path(tempfile.mkdtemp(prefix="stamps-test-"))
        self.stamps = self.dir / "stamps"

    def write(self, rel, data=b"x"):
        p = self.dir / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(data)
        return p

    def fp(self, spec):
        return stamps.fingerprint(spec, root=self.dir)

    def check(self, name, spec, full=False):
        return stamps.check(name, spec, root=self.dir, stamp_dir=self.stamps, full=full)

    def passed(self, name, spec, extra=None):
        stamps.begin(name, spec, root=self.dir, stamp_dir=self.stamps)
        return stamps.commit(name, root=self.dir, stamp_dir=self.stamps, extra=extra)

    def close(self):
        shutil.rmtree(self.dir, ignore_errors=True)


def boxed(fn):
    def run():
        if stamps is None:
            raise CheckFailed(f"tests/stamps.py missing: {IMPORT_ERROR}")
        b = Box()
        try:
            return fn(b)
        finally:
            b.close()
    run.__name__ = fn.__name__
    return run


def bump(path, ns=2_000_000_000):
    st = path.stat()
    os.utime(path, ns=(st.st_atime_ns, st.st_mtime_ns + ns))


@boxed
def t_stamp_same_inputs(b):
    b.write("a.dsf", b"one")
    b.write("d/b.txt", b"two")
    spec = {"files": ["a.dsf"], "trees": ["d"], "ident": {"switches": "-Cursor"}}
    need(b.fp(spec) == b.fp(spec), "two fingerprints of unchanged inputs differ")
    b.passed("s", spec)
    fresh, info = b.check("s", spec)
    need(fresh, f"unchanged inputs read as stale: {info}")


@boxed
def t_stamp_touched_input(b):
    p = b.write("a.dsf", b"one")
    spec = {"files": ["a.dsf"]}
    b.passed("s", spec)
    bump(p)
    fresh, info = b.check("s", spec)
    need(not fresh and "a.dsf" in info, f"mtime touch not seen: {fresh} {info}")


@boxed
def t_stamp_resized_input(b):
    p = b.write("a.dsf", b"one")
    spec = {"files": ["a.dsf"]}
    b.passed("s", spec)
    st = p.stat()
    p.write_bytes(b"one more")
    os.utime(p, ns=(st.st_atime_ns, st.st_mtime_ns))
    fresh, info = b.check("s", spec)
    need(not fresh and "a.dsf" in info, f"size change at the same mtime not seen: {fresh} {info}")


@boxed
def t_stamp_deleted_input(b):
    b.write("d/a.txt")
    p = b.write("d/b.txt")
    for spec in ({"trees": ["d"]}, {"globs": ["d/*.txt"]}, {"files": ["d/b.txt"]}):
        p.parent.mkdir(exist_ok=True)
        p.write_bytes(b"x")
        b.passed("s", spec)
        p.unlink()
        fresh, info = b.check("s", spec)
        need(not fresh and "b.txt" in info, f"{spec}: deletion not seen: {fresh} {info}")


@boxed
def t_stamp_added_input(b):
    b.write("d/a.txt")
    spec = {"globs": ["d/*.txt"]}
    b.passed("s", spec)
    b.write("d/new.txt")
    fresh, info = b.check("s", spec)
    need(not fresh and "new.txt" in info, f"added glob match not seen: {fresh} {info}")
    b.write("d/ignored.bin")
    b.passed("s", spec)
    fresh, info = b.check("s", spec)
    need(fresh, f"a file outside the glob changed the fingerprint: {info}")


@boxed
def t_stamp_renamed_input(b):
    b.write("d/a.txt")
    spec = {"trees": ["d"]}
    b.passed("s", spec)
    os.replace(b.dir / "d" / "a.txt", b.dir / "d" / "b.txt")
    fresh, info = b.check("s", spec)
    need(not fresh, "rename inside a tree not seen")


@boxed
def t_stamp_git_set(b):
    if not shutil.which("git"):
        raise CheckFailed("git not on PATH")
    run = lambda *a: subprocess.run(["git", *a], cwd=b.dir, capture_output=True, check=True)
    run("init", "-q")
    b.write(".gitignore", b"out/\n")
    b.write("src/a.asm")
    b.write("out/x.bin")
    run("add", "-A")
    spec = {"git": ["src", "out"]}
    keys = set(b.fp(spec)["files"])
    need("src/a.asm" in keys and not any(k.startswith("out/") for k in keys),
         f"git set wrong: {sorted(keys)}")
    b.passed("s", spec)
    b.write("src/untracked.inc")
    fresh, info = b.check("s", spec)
    need(not fresh and "untracked.inc" in info, f"untracked new source not seen: {fresh} {info}")
    (b.dir / "src" / "untracked.inc").unlink()
    (b.dir / "src" / "a.asm").unlink()
    fresh, info = b.check("s", spec)
    need(not fresh and "a.asm" in info, f"deleted tracked source not seen: {fresh} {info}")


@boxed
def t_stamp_failed_never_pass(b):
    b.write("a.dsf")
    spec = {"files": ["a.dsf"]}
    stamps.begin("s", spec, root=b.dir, stamp_dir=b.stamps)
    fresh, info = b.check("s", spec)
    need(not fresh, "a pending (unfinished) step read as a pass")
    stamps.fail("s", root=b.dir, stamp_dir=b.stamps)
    fresh, info = b.check("s", spec)
    need(not fresh, "a stamp written for a failed step read as a pass")
    p = b.stamps / "s.json"
    need(p.exists(), "fail() wrote no stamp")
    d = json.loads(p.read_text())
    need(d["status"] == "fail", f"failed stamp status {d['status']}")
    d["inputs"] = b.fp(spec)
    p.write_text(json.dumps(d))
    fresh, info = b.check("s", spec)
    need(not fresh, "a failed stamp with matching inputs read as a pass")
    raised = False
    try:
        stamps.commit("t", root=b.dir, stamp_dir=b.stamps)
    except stamps.StampError:
        raised = True
    need(raised, "commit without a pending check succeeded")


@boxed
def t_stamp_tool_changed(b):
    tool = b.write("tools/ndrc.exe", b"MZ1")
    spec = {"files": [], "tools": {"ndrc": str(tool)}}
    b.passed("s", spec)
    fresh, _ = b.check("s", spec)
    need(fresh, "unchanged tool read as stale")
    bump(tool)
    fresh, info = b.check("s", spec)
    need(not fresh and "ndrc" in info, f"rebuilt tool not seen: {fresh} {info}")
    b.passed("s", spec)
    tool.write_bytes(b"MZ22")
    fresh, info = b.check("s", spec)
    need(not fresh and "ndrc" in info, f"resized tool not seen: {fresh} {info}")
    b.passed("s", spec)
    other = b.write("tools2/ndrc.exe", b"MZ22")
    os.utime(other, ns=(tool.stat().st_atime_ns, tool.stat().st_mtime_ns))
    fresh, info = b.check("s", {"files": [], "tools": {"ndrc": str(other)}})
    need(not fresh, "a different tool path with the same size and mtime read as fresh")


@boxed
def t_stamp_outputs_checked(b):
    b.write("a.dsf")
    out = b.write("out/a.ddb", b"ddb")
    spec = {"files": ["a.dsf"], "outputs": ["out/a.ddb"], "output_trees": ["card"]}
    b.write("card/GAME.DDB", b"g")
    b.passed("s", spec)
    fresh, _ = b.check("s", spec)
    need(fresh, "matching outputs read as stale")
    (b.dir / "card" / "GAME.DDB").unlink()
    fresh, info = b.check("s", spec)
    need(not fresh and "GAME.DDB" in info, f"file deleted from a staged folder not seen: {info}")
    b.write("card/GAME.DDB", b"g")
    b.passed("s", spec)
    out.unlink()
    fresh, info = b.check("s", spec)
    need(not fresh and "a.ddb" in info, f"missing output not seen: {info}")


@boxed
def t_stamp_hashed_outputs(b):
    b.write("a.dsf")
    out = b.write("out/a.ddb", b"ddb")
    spec = {"files": ["a.dsf"], "outputs": ["out/a.ddb"], "hash_outputs": True}
    b.passed("s", spec)
    bump(out)
    fresh, info = b.check("s", spec)
    need(fresh, f"rewritten identical output read as stale under hash_outputs: {info}")
    out.write_bytes(b"DDB")
    fresh, info = b.check("s", spec)
    need(not fresh, "changed output bytes not seen under hash_outputs")


@boxed
def t_stamp_full_and_extra(b):
    b.write("a.dsf")
    spec = {"files": ["a.dsf"]}
    b.passed("s", spec, extra={"rc": 1, "pass": 3})
    fresh, info = b.check("s", spec, full=True)
    need(not fresh and "full" in info, f"full run did not force a rerun: {info}")
    st = stamps.read_stamp("s", stamp_dir=b.stamps)
    need(st["extra"] == {"rc": 1, "pass": 3}, f"extra not kept: {st.get('extra')}")


@boxed
def t_stamp_cache_restore(b):
    b.write("src/main.asm")
    nex = b.write("build/n.nex", b"debug")
    spec = {"files": ["src/main.asm"], "outputs": ["build/n.nex"], "cache_dir": "build/variants/D"}
    b.passed("s", spec)
    t0 = nex.stat().st_mtime_ns
    nex.write_bytes(b"release!")
    fresh, info = b.check("s", spec)
    need(fresh and "restored" in info, f"cached outputs not restored: {fresh} {info}")
    need(nex.read_bytes() == b"debug" and nex.stat().st_mtime_ns == t0, "restore lost bytes or mtime")


@boxed
def t_stamp_guarded_restore(b):
    b.write("a.dsf")
    common = {"cache_guard": "guard.json", "cache_guard_tree": "card"}
    one = dict(common, files=["a.dsf"], ident={"sw": "one"}, cache_dir="cache/one", output_trees=["card", "side1"])
    two = dict(common, files=["a.dsf"], ident={"sw": "two"}, cache_dir="cache/two", output_trees=["card", "side2"])
    b.write("side1/expect.bin", b"1")
    b.write("side2/expect.bin", b"2")
    b.write("card/GAME.DDB", b"one")
    b.passed("one", one)
    shutil.rmtree(b.dir / "card")
    b.write("card/GAME.DDB", b"two!")
    b.write("card/EXTRA.BIN", b"x")
    b.passed("two", two)
    fresh, info = b.check("one", one)
    need(fresh and "restored" in info, f"folder another step overwrote not restored: {fresh} {info}")
    need(sorted(p.name for p in (b.dir / "card").iterdir()) == ["GAME.DDB"], "restore left another step's file")
    need((b.dir / "card" / "GAME.DDB").read_bytes() == b"one", "restore wrote the wrong bytes")
    fresh, info = b.check("two", two)
    need(fresh and "restored" in info, f"second restore failed: {fresh} {info}")
    (b.dir / "card" / "EXTRA.BIN").unlink()
    fresh, info = b.check("two", two)
    need(not fresh, f"a folder edited by hand was restored instead of rerun: {info}")
    fresh, info = b.check("one", one)
    need(not fresh, f"an edited folder was restored for another step: {info}")


@boxed
def t_stamp_hashed_inputs(b):
    src = b.write("cursor.dsf", b"; one")
    ddb = b.write("out/cursor.ddb", b"DDB")
    leg = {"files": ["stage.ps1"], "hash_files": ["out/cursor.ddb"], "hash_trees": ["card"]}
    b.write("stage.ps1")
    b.write("card/GAME.DDB", b"DDB")
    b.passed("leg", leg)
    bump(src)
    ddb.write_bytes(b"DDB")
    bump(ddb)
    shutil.rmtree(b.dir / "card")
    b.write("card/GAME.DDB", b"DDB")
    fresh, info = b.check("leg", leg)
    need(fresh, f"identical rewritten upstream outputs read as changed: {info}")
    ddb.write_bytes(b"DDb")
    fresh, info = b.check("leg", leg)
    need(not fresh and "cursor.ddb" in info, f"changed upstream bytes not seen: {fresh} {info}")


@boxed
def t_stamp_plan_no_writes(b):
    b.write("a.dsf")
    one = {"files": ["a.dsf"], "output_trees": ["card"], "cache_dir": "cache/one", "cache_guard": "g.json",
           "cache_guard_tree": "card", "ident": {"sw": "one"}}
    two = dict(one, cache_dir="cache/two", ident={"sw": "two"})
    b.write("card/X", b"1")
    b.passed("one", one)
    b.write("card/X", b"22")
    b.passed("two", two)
    before = sorted(p.name for p in b.stamps.iterdir())
    state, info, _ = stamps.plan_check("one", one, root=b.dir, stamp_dir=b.stamps)
    need(state == "RESTORE", f"restorable step planned as {state}: {info}")
    need((b.dir / "card" / "X").read_bytes() == b"22", "a plan restored a folder")
    state, _, changed = stamps.plan_check("new", one, root=b.dir, stamp_dir=b.stamps)
    need(state == "STALE" and changed is None, "a step with no stamp planned fresh")
    need(sorted(p.name for p in b.stamps.iterdir()) == before, "a plan wrote a stamp file")


@boxed
def t_stamp_plan_upstream(b):
    b.write("cursor.dsf")
    b.write("txt40.dsf")
    fx = {"files": ["cursor.dsf", "txt40.dsf"]}
    cur = {"files": [], "upstream": [{"step": "fx", "files": ["cursor.dsf"]}], "ident": {"l": "c"}}
    txt = {"files": [], "upstream": [{"step": "fx", "files": ["txt40.dsf"]}], "ident": {"l": "t"}}
    for n, s in (("fx", fx), ("cur", cur), ("txt", txt)):
        b.passed(n, s)
    bump(b.dir / "cursor.dsf")
    spec_file = b.write("spec.json", json.dumps({"root": str(b.dir), "stamp_dir": str(b.stamps),
                                                 "steps": {"fx": fx, "cur": cur, "txt": txt}}).encode())
    r = subprocess.run([sys.executable, str(Path(stamps.__file__)), "check", str(spec_file), "--plan"],
                       capture_output=True, text=True)
    got = {l.split("\t")[1]: l.split("\t")[0] for l in r.stdout.splitlines()}
    need(got == {"fx": "STALE", "cur": "PENDING", "txt": "FRESH"}, f"plan states {got} {r.stderr}")
    need(not list(b.stamps.glob("*.pending.json")), "check --plan wrote a pending stamp")


@boxed
def t_stamp_cli(b):
    b.write("a.dsf")
    spec_file = b.write("spec.json", json.dumps({"root": str(b.dir), "stamp_dir": str(b.stamps),
                                                 "steps": {"one": {"files": ["a.dsf"]}}}).encode())
    py = [sys.executable, str(Path(stamps.__file__))]
    r = subprocess.run(py + ["check", str(spec_file)], capture_output=True, text=True)
    need(r.returncode == 0 and r.stdout.startswith("STALE\tone\t"), f"first check: {r.stdout}{r.stderr}")
    r = subprocess.run(py + ["pass", "--stamp-dir", str(b.stamps), "--root", str(b.dir), "one"],
                       capture_output=True, text=True)
    need(r.returncode == 0, f"pass: {r.stdout}{r.stderr}")
    r = subprocess.run(py + ["check", str(spec_file)], capture_output=True, text=True)
    need(r.returncode == 0 and r.stdout.startswith("FRESH\tone\t"), f"second check: {r.stdout}{r.stderr}")
    r = subprocess.run(py + ["check", str(spec_file), "--full"], capture_output=True, text=True)
    need(r.stdout.startswith("STALE\tone\tfull"), f"--full check: {r.stdout}{r.stderr}")


HOST = [t_stamp_same_inputs, t_stamp_touched_input, t_stamp_resized_input, t_stamp_deleted_input,
        t_stamp_added_input, t_stamp_renamed_input, t_stamp_git_set, t_stamp_failed_never_pass,
        t_stamp_tool_changed, t_stamp_outputs_checked, t_stamp_hashed_outputs, t_stamp_full_and_extra,
        t_stamp_cache_restore, t_stamp_guarded_restore, t_stamp_hashed_inputs, t_stamp_plan_no_writes,
        t_stamp_plan_upstream, t_stamp_cli]


def main(argv):
    names = set(argv)
    fails = 0
    for check in HOST:
        if names and check.__name__ not in names:
            continue
        try:
            note = check()
        except Exception as e:
            fails += 1
            kind = "" if isinstance(e, CheckFailed) else type(e).__name__ + ": "
            print(f"FAIL {check.__name__}: {kind}{e}", flush=True)
        else:
            print(f"PASS {check.__name__}" + (f" - {note}" if note else ""), flush=True)
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
