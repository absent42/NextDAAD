#!/usr/bin/env python3
"""tests/check_frozen_exes.py - fail when a frozen kit exe's bundled code
drifts from the sources it was built from.

videnc.exe and vidtune.exe are PyInstaller bundles that FREEZE nxv2enc and
its siblings in. A stale bundle silently emits old-encoder bytes, which has
happened twice with nothing to catch it. This unmarshals each bundle's code
objects and compares their instruction streams with the working tree's.
Only __doc__ stores are masked: every other string literal, argparse help
text included, is code. Exit 1 = stale. Exit 2 = not verified: an exe is
missing, an LFS pointer or unreadable, nxv2enc was not compared, or the
host Python minor version differs from the bundle's.
"""
import dis
import marshal
import struct
import sys
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LIB = ROOT / "authoring-kit" / "lib"
EXES = [ROOT / "authoring-kit" / "tools" / "videnc" / "videnc.exe",
        ROOT / "authoring-kit" / "tools" / "vidtune" / "vidtune.exe"]
MAGIC = b"MEI\014\013\012\013\016"
LFS_POINTER = b"version https://git-lfs"
REQUIRED = {"nxv2enc"}
SIG = ("co_argcount", "co_posonlyargcount", "co_kwonlyargcount", "co_flags",
       "co_varnames", "co_freevars", "co_cellvars", "co_name", "co_qualname")


def carchive(path):
    data = path.read_bytes()
    pos = data.rfind(MAGIC)
    if pos < 0:
        raise ValueError("no PyInstaller archive cookie")
    _, pkg_len, toc_off, toc_len, pyver, _ = struct.unpack(
        "!8sIIII64s", data[pos:pos + 88])
    start = pos + 88 - pkg_len
    toc = data[start + toc_off:start + toc_off + toc_len]
    out, i = [], 0
    while i < len(toc):
        esz, eoff, dlen, _, cflag, tcode = struct.unpack("!IIIIBc", toc[i:i + 18])
        name = toc[i + 18:i + esz].rstrip(b"\0").decode("utf-8", "replace")
        i += esz
        blob = data[start + eoff:start + eoff + dlen]
        out.append((name, tcode.decode("ascii"),
                    zlib.decompress(blob) if cflag else blob))
    return pyver, out


def frozen_modules(path):
    pyver, entries = carchive(path)
    mods = {}
    for name, tc, blob in entries:
        if tc == "z":
            toc = marshal.loads(blob[struct.unpack("!i", blob[8:12])[0]:])
            for n, (_, off, ln) in (toc.items() if isinstance(toc, dict) else toc):
                try:
                    mods[n] = marshal.loads(zlib.decompress(blob[off:off + ln]))
                except Exception:
                    pass
        elif tc == "s" and not name.startswith("pyi"):
            mods["script:" + name] = marshal.loads(blob)
    return pyver, mods


def instrs(code):
    ins = list(dis.get_instructions(code))
    out = []
    for k, i in enumerate(ins):
        arg = i.argrepr
        nxt = ins[k + 1] if k + 1 < len(ins) else None
        if (i.opname == "LOAD_CONST" and nxt is not None
                and nxt.opname == "STORE_NAME" and nxt.argval == "__doc__"):
            arg = "<doc>"
        elif hasattr(i.argval, "co_code"):
            arg = "<code %s>" % i.argval.co_qualname
        elif (i.opname == "LOAD_CONST" and nxt is not None
              and nxt.opname == "STORE_NAME" and nxt.argval == "__firstlineno__"):
            arg = "<firstlineno>"
        elif "JUMP" in i.opname or i.opname in ("FOR_ITER", "SEND", "END_FOR"):
            arg = "<target>"
        out.append("%s %s" % (i.opname, arg))
    return out


def walk(frz, src, out):
    if instrs(frz) != instrs(src):
        out.append(f"{frz.co_qualname}: bytecode differs")
    for f in SIG:
        if getattr(frz, f) != getattr(src, f):
            out.append(f"{frz.co_qualname}: {f} differs")
    fn = {c.co_qualname: c for c in frz.co_consts if hasattr(c, "co_code")}
    sn = {c.co_qualname: c for c in src.co_consts if hasattr(c, "co_code")}
    for q in sorted(set(fn) ^ set(sn)):
        out.append(f"nested code only in {'bundle' if q in fn else 'source'}: {q}")
    for q in sorted(set(fn) & set(sn)):
        walk(fn[q], sn[q], out)


def module_name(path):
    rel = path.relative_to(LIB).with_suffix("")
    parts = list(rel.parts)
    if parts[-1] == "__init__":
        parts.pop()
    return ".".join(parts) if parts else rel.stem


def main():
    failed = unverified = False
    host = sys.version_info.major * 100 + sys.version_info.minor
    for exe in EXES:
        if not exe.exists():
            unverified = True
            print(f"check_frozen_exes: NOT VERIFIED {exe.name} - missing")
            continue
        with exe.open("rb") as f:
            if f.read(len(LFS_POINTER)) == LFS_POINTER:
                unverified = True
                print(f"check_frozen_exes: NOT VERIFIED {exe.name} - Git LFS pointer, run git lfs pull")
                continue
        try:
            pyver, mods = frozen_modules(exe)
        except (ValueError, struct.error, zlib.error) as e:
            unverified = True
            print(f"check_frozen_exes: NOT VERIFIED {exe.name} - unreadable bundle: {e}")
            continue
        if pyver != host:
            unverified = True
            print(f"check_frozen_exes: NOT VERIFIED {exe.name} - bundle Python "
                  f"{pyver // 100}.{pyver % 100}, host {host // 100}.{host % 100}; "
                  "bytecode compares only within a minor version")
            continue
        compared = set()
        for src_path in sorted(LIB.rglob("*.py")):
            name = module_name(src_path)
            frz = mods.get(name) or mods.get("script:" + src_path.stem)
            if frz is None:
                continue
            compared.add(name)
            src = compile(src_path.read_bytes(), frz.co_filename, "exec",
                          dont_inherit=True, optimize=0)
            out = []
            walk(frz, src, out)
            if out:
                failed = True
                print(f"check_frozen_exes: STALE {exe.name} <- {src_path.relative_to(ROOT)}")
                for line in out[:8]:
                    print("    " + line)
        # an unreadable archive format must not pass having compared nothing
        if REQUIRED - compared:
            unverified = True
            print(f"check_frozen_exes: NOT VERIFIED {exe.name} - not found in the bundle: "
                  + ", ".join(sorted(REQUIRED - compared)))
    if failed:
        print("check_frozen_exes: FAIL - rebuild both exes")
        return 1
    if unverified:
        print("check_frozen_exes: FAIL - staleness not verified")
        return 2
    print("check_frozen_exes: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
