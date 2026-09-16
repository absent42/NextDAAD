#!/usr/bin/env python3
"""tests/check_frozen_exes.py - fail when a frozen kit exe's bundled code
drifts from the sources it was built from.

videnc.exe and vidtune.exe are PyInstaller bundles that FREEZE nxv2enc and
its siblings in. A stale bundle silently emits old-encoder bytes, which has
happened twice with nothing to catch it. This unmarshals each bundle's code
objects and compares their instruction streams with the working tree's.
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
SIG = ("co_argcount", "co_posonlyargcount", "co_kwonlyargcount", "co_flags",
       "co_varnames", "co_freevars", "co_cellvars", "co_name", "co_qualname")


def carchive(path):
    data = path.read_bytes()
    pos = data.rfind(MAGIC)
    if pos < 0:
        raise SystemExit(f"{path.name}: no PyInstaller archive cookie")
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
        if isinstance(i.argval, str) and i.opname in ("LOAD_CONST", "RETURN_CONST"):
            arg = "<str>"
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
    failed = False
    for exe in EXES:
        if not exe.exists():
            print(f"check_frozen_exes: {exe.name} missing")
            return 1
        pyver, mods = frozen_modules(exe)
        host = sys.version_info.major * 100 + sys.version_info.minor
        if pyver != host:
            print(f"check_frozen_exes: SKIP {exe.name} - bundle python {pyver}, host {host}")
            continue
        for src_path in sorted(LIB.rglob("*.py")):
            name = module_name(src_path)
            frz = mods.get(name) or mods.get("script:" + src_path.stem)
            if frz is None:
                continue
            src = compile(src_path.read_bytes(), frz.co_filename, "exec",
                          dont_inherit=True, optimize=0)
            out = []
            walk(frz, src, out)
            if out:
                failed = True
                print(f"check_frozen_exes: STALE {exe.name} <- {src_path.relative_to(ROOT)}")
                for line in out[:8]:
                    print("    " + line)
    print("check_frozen_exes: " + ("FAIL - rebuild both exes" if failed else "OK"))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
