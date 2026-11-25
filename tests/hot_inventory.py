#!/usr/bin/env python3
"""Video page inventory: labels inside IFDEF DEBUG, their sizes, the page end and headroom.

    python tests\\hot_inventory.py [--sld build\\nextdaad.sld] [--nex <nex>] [--min N] [--page hot|cold]
    python tests\\hot_inventory.py --selftest

Reads the SLD and src/video.asm. A label is a non-local address label on the page (VID_PAGE
hot, VID_PAGE2 cold); its size is the next label's address less its own, the page's last
label running to the page end. Totals by nesting: DEBUG, and DEBUG and not NXB_QUIET (0 on a
-BenchQuiet image: not assembled). A label on a conditional directive line is refused.
Page end: the page's last SLD record plus what its line and the lines after it emit up to
the page's "ends at" DISPLAY (data sized from the source, an instruction decoded from the
NEX, default the SLD's sibling .nex). Headroom = OVL_LIMIT - page end.
Exit 0 = ok or a Release image; 1 = a DEBUG image under --min (default hot 40, cold 100);
2 = setup error.
"""

import argparse
import contextlib
import io
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

ROOT = Path(__file__).resolve().parent.parent
BUILD_SLD = ROOT / "build" / "nextdaad.sld"
VIDEO_SRC = ROOT / "src" / "video.asm"
SRC_KEY = "src/video.asm"
DEBUG_MARKER = "dbgNoBank"          # DEBUG-only symbol, as tests\vidraw_oldpaths.py reads it
QUIET_MARKER = "nxbQuietImage"      # -BenchQuiet SLD marker (video.asm)
PAGES = {"hot": ("VID_PAGE", "video ends at", 40), "cold": ("VID_PAGE2", "video2 ends at", 100)}
NEST_D, NEST_DQ = "DEBUG", "DEBUG and not NXB_QUIET"
QUIET_NOTE = "not assembled in a -BenchQuiet image"


class Setup(Exception):
    pass


# ---------------------------------------------------------------- SLD and source

def read_sld(text):
    """(symbols, records). symbols: name -> value (D and F). records: (kind, page, addr,
    line, name) for T and F records of src/video.asm."""
    syms, recs = {}, []
    for raw in text.splitlines():
        f = raw.split("|")
        if len(f) < 8 or f[6] not in ("D", "F", "T"):
            continue
        try:
            page, value, line = int(f[4]), int(f[5]), int(f[1])
        except ValueError:
            continue
        if f[6] in ("D", "F"):
            syms[f[7]] = value
        if f[6] in ("F", "T") and f[0].replace("\\", "/").endswith(SRC_KEY):
            recs.append((f[6], page, value, line, f[7]))
    return syms, recs


CONDS = r"(IFNDEF|IFDEF|IFNUSED|IFUSED|IFN|IF|ELSEIF|ELSE|ENDIF)\b"
COND = re.compile(r"^\s*" + CONDS + r"\s*([^;\s]*)", re.I)
# sjasmplus 1.24 does not pair a conditional that carries a label: refused, not guessed.
LABELLED_COND = re.compile(r"^([A-Za-z_.@?!][\w.@?!#]*)(?::\s*|\s+)" + CONDS, re.I)


def contexts(lines):
    """Per line (index 0 = line 1): the enclosing frames (directive, operand, if-branch)."""
    out, stack = [], []
    for n, text in enumerate(lines, 1):
        m = COND.match(text)
        lab = None if m else LABELLED_COND.match(text)
        if lab:
            raise Setup(f"line {n}: label {lab.group(1)} on a conditional directive line")
        if m:
            k = m.group(1).upper()
            if k == "ENDIF":
                if not stack:
                    raise Setup(f"line {n}: ENDIF without IF")
                stack.pop()
            elif k == "ELSE":
                if not stack:
                    raise Setup(f"line {n}: ELSE without IF")
                d, op, _ = stack.pop()
                stack.append((d, op, False))
            elif k == "ELSEIF":
                if not stack:
                    raise Setup(f"line {n}: ELSEIF without IF")
                stack.pop()
                stack.append(("ELSEIF", m.group(2), True))
            else:
                stack.append((k, m.group(2), True))
            out.append(None)            # a directive line emits nothing
        else:
            out.append(tuple(stack))
    if stack:
        raise Setup(f"{len(stack)} IF block(s) left open at the end of the source")
    return out


def holds(frames, d, sym):
    """True when frames put the line where sym is defined (d True) or undefined (d False)."""
    return any((k == "IFDEF" and op == sym and br == d) or (k == "IFNDEF" and op == sym and br != d)
               for k, op, br in frames)


def nest(frames):
    if not holds(frames, True, "DEBUG"):
        return None
    return NEST_DQ if holds(frames, False, "NXB_QUIET") else NEST_D


def active(frames, defined):
    """True, False, or None when a frame's condition is not one this script evaluates."""
    known = True
    for k, op, br in frames:
        if k in ("IFDEF", "IFNDEF") and op in ("DEBUG", "NXB_QUIET"):
            if ((op in defined) == (k == "IFDEF")) != br:
                return False
        else:
            known = None
    return known


def strip_comment(text):
    q = None
    for i, ch in enumerate(text):
        if q:
            if ch == q:
                q = None
        elif ch in "\"'":
            q = ch
        elif ch == ";":
            return text[:i]
    return text


def split_items(ops):
    items, cur, q = [], "", None
    for ch in ops:
        if q:
            cur += ch
            if ch == q:
                q = None
        elif ch in "\"'":
            q = ch
            cur += ch
        elif ch == ",":
            items.append(cur.strip())
            cur = ""
        else:
            cur += ch
    if cur.strip():
        items.append(cur.strip())
    return items


TOK = re.compile(r"\s*(?:(0x[0-9A-Fa-f]+)|(\$[0-9A-Fa-f]+)|(#[0-9A-Fa-f]+)|([0-9][0-9A-Fa-f]*[hH])\b"
                 r"|(%[01]+)|([0-9]+)|(\$)|([A-Za-z_.][A-Za-z0-9_.]*)|(<<|>>|[-+*/%&|^~()]))")


def evaluate(expr, syms, here):
    """Integer value of an assembler expression: numbers, symbols, $, + - * / % << >> & | ^ ~."""
    out, i, operand = [], 0, True
    expr = expr.strip()
    while i < len(expr):
        m = TOK.match(expr, i)
        if not m or m.end() == i:
            raise Setup(f"cannot evaluate {expr!r}")
        i = m.end()
        hx, dl, hs, hh, bn, dec, cur, name, op = m.groups()
        if bn and not operand:          # % after an operand is the remainder
            out.append("%")
            out.append(str(int(bn[1:])))
            operand = False
            continue
        if hx or dl or hs or hh or bn or dec or cur or name:
            if hx:
                v = int(hx, 16)
            elif dl:
                v = int(dl[1:], 16)
            elif hs:
                v = int(hs[1:], 16)
            elif hh:
                v = int(hh[:-1], 16)
            elif bn:
                v = int(bn[1:], 2)
            elif dec:
                v = int(dec)
            elif cur:
                v = here
            else:
                if name not in syms:
                    raise Setup(f"{expr!r}: symbol {name} not in the SLD")
                v = syms[name]
            out.append(str(v))
            operand = False
        else:
            out.append("//" if op == "/" else op)
            operand = op != ")"
    try:
        return int(eval(" ".join(out), {"__builtins__": {}}, {}))      # noqa: S307
    except Exception as exc:                                            # noqa: BLE001
        raise Setup(f"cannot evaluate {expr!r}: {exc}") from None


DATA = {"DB": 1, "DEFB": 1, "BYTE": 1, "DM": 1, "DEFM": 1, "DC": 1, "DZ": 1,
        "DW": 2, "DEFW": 2, "WORD": 2, "D24": 3, "DD": 4, "DEFD": 4, "DWORD": 4}
SPACE = {"DS", "DEFS", "BLOCK"}
QUIET_STMT = {"ASSERT", "DISPLAY", "EQU", "DEFL", "="}


def statement(text):
    """(label, keyword, operands) of a source line; label is None when it starts indented."""
    body = strip_comment(text).rstrip()
    label = None
    if body and not body[0].isspace():
        parts = body.split(None, 1)
        label = parts[0].rstrip(":")
        body = parts[1] if len(parts) > 1 else ""
    parts = body.split(None, 1)
    if not parts:
        return label, None, ""
    return label, parts[0].upper(), parts[1].strip() if len(parts) > 1 else ""


def emitted(kw, ops, syms, here):
    """Bytes a data or layout line emits at here; None when kw is not a data or layout keyword."""
    if kw in DATA:
        n = 0
        for it in split_items(ops):
            if len(it) >= 2 and it[0] in "\"'" and it[-1] == it[0]:
                s = it[1:-1]
                n += len(re.sub(r"\\.", "x", s)) if it[0] == '"' else len(s)
            else:
                n += DATA[kw]
        return n + (1 if kw == "DZ" else 0)
    if kw in SPACE:
        return evaluate(split_items(ops)[0], syms, here)
    if kw == "ALIGN":
        a = evaluate(split_items(ops)[0], syms, here)
        return (-here) % a
    if kw in QUIET_STMT:
        return 0
    return None


def page_span(lines, page_sym, disp):
    """(first line, DISPLAY line) of the page's section, 1-based."""
    mmu = re.compile(r"^\s*MMU\s+7\s*,\s*" + page_sym + r"\s*,", re.I)
    first = next((n for n, t in enumerate(lines, 1) if mmu.match(t)), None)
    if first is None:
        raise Setup(f"no 'MMU 7, {page_sym}' line in {SRC_KEY}")
    last = next((n for n, t in enumerate(lines, 1)
                 if n > first and re.match(r"^\s*DISPLAY\s+\"" + disp, t, re.I)), None)
    if last is None:
        raise Setup(f"no DISPLAY \"{disp}\" after line {first} in {SRC_KEY}")
    return first, last


def page_end(recs, lines, ctx, defined, syms, disp_line, page_bytes):
    """Address after the page's last emitted byte (see the module docstring)."""
    top = max(recs, key=lambda r: (r[2], r[3], r[0] == "T"))
    addr, line = top[2], top[3]
    if any(r[0] == "T" and r[2] == addr and r[3] == line for r in recs):
        if page_bytes is None:
            raise Setup(f"the page ends in an instruction (line {line}): the NEX is needed")
        import vidraw_oldpaths as vo                # the guard's Z80N length decoder
        buf = page_bytes(top[1])
        try:
            size = vo.insn(buf, addr & 0x1FFF)[0]
        except vo.Undecodable as exc:
            raise Setup(f"line {line}: {exc}") from None
        addr += size
        line += 1
    for n in range(line, disp_line):
        frames = ctx[n - 1]
        if frames is None:
            continue
        act = active(frames, defined)
        if act is False:
            continue
        _, kw, ops = statement(lines[n - 1])
        if kw is None:
            continue
        size = emitted(kw, ops, syms, addr)
        if size is None or act is None and size:
            raise Setup(f"line {n} after the page's last SLD record cannot be sized: "
                        f"{lines[n - 1].strip()!r}")
        addr += size
    return addr


def inventory(sld_text, src_text, page="hot", page_bytes=None):
    """Labels on the page with sizes and nesting, totals, page end and headroom."""
    page_sym, disp, _ = PAGES[page]
    syms, recs = read_sld(sld_text)
    for need in (page_sym, "OVL_LIMIT"):
        if need not in syms:
            raise Setup(f"{need} not in the SLD")
    pno = syms[page_sym]
    recs = [r for r in recs if r[1] == pno]
    if not recs:
        raise Setup(f"no {SRC_KEY} records on page {pno} ({page_sym})")
    lines = src_text.splitlines()
    ctx = contexts(lines)
    first, last = page_span(lines, page_sym, disp)
    defined = set()
    if DEBUG_MARKER in syms:
        defined.add("DEBUG")
    if QUIET_MARKER in syms:
        defined.add("NXB_QUIET")
    image = "Release" if "DEBUG" not in defined else (
        "DEBUG+NXB_QUIET" if "NXB_QUIET" in defined else "DEBUG")
    stray = [r for r in recs if not first < r[3] < last]
    if stray:
        raise Setup(f"page {pno} record at line {stray[0][3]} is outside lines {first}-{last}")
    end = page_end(recs, lines, ctx, defined, syms, last, page_bytes)
    labs = sorted((r for r in recs if r[0] == "F" and "." not in r[4]), key=lambda r: (r[2], r[3]))
    out, totals = [], {NEST_D: 0, NEST_DQ: 0}
    for i, (_, _, addr, line, name) in enumerate(labs):
        nxt = labs[i + 1][2] if i + 1 < len(labs) else end
        frames = ctx[line - 1] or ()
        kind = nest(frames)
        out.append({"name": name, "addr": addr, "size": nxt - addr, "line": line, "nest": kind})
        if kind:
            totals[kind] += nxt - addr
    return {"image": image, "page": page, "page_sym": page_sym, "page_no": pno, "labels": out,
            "totals": totals, "end": end, "limit": syms["OVL_LIMIT"],
            "headroom": syms["OVL_LIMIT"] - end}


# ---------------------------------------------------------------- self-test

SELF_SRC = """\
    MMU 7, VID_PAGE, OVL_ORG
 IFDEF DEBUG
dbg_a:
    nop
.x: nop
cellA:  ds 5
  IFNDEF NXB_QUIET
cellQ:  dw 0, 0
  ENDIF
 ENDIF
shared:
    ld hl, 0
 IFDEF DEBUG
    nop
 ENDIF
    jp shared
 IFDEF DEBUG
tailbuf: ds 2 * N, 0     ; cells
  IFNDEF NXB_QUIET
    db "ab", 2
  ENDIF
 ENDIF
    DISPLAY "video ends at ", $, " headroom ", /D, OVL_LIMIT - $
"""

SELF_ELSE = """\
    MMU 7, VID_PAGE, OVL_ORG
 IFDEF DEBUG
dbg_e:  nop
 ELSE
rel_e:  nop
    nop
 ENDIF
 IFNDEF DEBUG
rel_f:  nop
 ELSE
dbg_f:  nop
    nop
    nop
 ENDIF
both:   nop
 IFDEF DEBUG
    db 1
 ELSE
    ds 4
 ENDIF
    DISPLAY "video ends at ", $, " headroom ", /D, OVL_LIMIT - $
"""

SELF_SYMS = ["src/nextdaad.inc|1||0|-1|59|D|VID_PAGE",
             "src/nextdaad.inc|2||0|-1|57344|D|OVL_ORG",
             "src/nextdaad.inc|3||0|-1|57376|D|OVL_LIMIT",
             "src/nextdaad.inc|4||0|-1|3|D|N"]


def self_sld(recs, extra=()):
    """SLD text: (kind, addr, line, name) records on page 59 plus symbol lines."""
    out = ["|SLD.data.version|1"] + SELF_SYMS + list(extra)
    for kind, addr, line, name in recs:
        out.append(f"{SRC_KEY}|{line}||0|59|{addr}|{kind}|{name}")
    return "\n".join(out) + "\n"


def selftest():
    fails = []

    def check(what, got, want):
        if got != want:
            fails.append(f"{what}: got {got!r}, want {want!r}")

    dbg = "src/debug.asm|1||0|-1|1|D|" + DEBUG_MARKER
    quiet = "src/video.asm|1||0|-1|1|D|" + QUIET_MARKER
    e = 0xE000
    # DEBUG: tailbuf (6) plus the unlabelled db (3) runs to the page end.
    a = self_sld([("F", e, 3, "dbg_a"), ("T", e, 4, ""), ("F", e + 1, 5, "dbg_a.x"),
                  ("T", e + 1, 5, ""), ("F", e + 2, 6, "cellA"), ("F", e + 7, 8, "cellQ"),
                  ("F", e + 11, 11, "shared"), ("T", e + 11, 12, ""), ("T", e + 14, 14, ""),
                  ("T", e + 15, 16, ""), ("F", e + 18, 18, "tailbuf")], [dbg])
    try:
        r = inventory(a, SELF_SRC)
        check("A image", r["image"], "DEBUG")
        check("A sizes", [(x["name"], x["size"], x["nest"]) for x in r["labels"]],
              [("dbg_a", 2, NEST_D), ("cellA", 5, NEST_D), ("cellQ", 4, NEST_DQ),
               ("shared", 7, None), ("tailbuf", 9, NEST_D)])
        check("A totals", (r["totals"][NEST_D], r["totals"][NEST_DQ]), (16, 4))
        check("A end", r["end"], e + 0x1B)
        check("A headroom", r["headroom"], 5)
        check("A exit --min 40", exit_code(r, 40), 1)
        check("A exit --min 5", exit_code(r, 5), 0)
    except Exception as exc:                                    # noqa: BLE001
        fails.append(f"A: {type(exc).__name__}: {exc}")
    # -BenchQuiet: cellQ and the tail db are not assembled.
    b = self_sld([("F", e, 3, "dbg_a"), ("T", e, 4, ""), ("F", e + 1, 5, "dbg_a.x"),
                  ("T", e + 1, 5, ""), ("F", e + 2, 6, "cellA"), ("F", e + 7, 11, "shared"),
                  ("T", e + 7, 12, ""), ("T", e + 10, 14, ""), ("T", e + 11, 16, ""),
                  ("F", e + 14, 18, "tailbuf")], [dbg, quiet])
    try:
        r = inventory(b, SELF_SRC)
        check("B image", r["image"], "DEBUG+NXB_QUIET")
        check("B sizes", [(x["name"], x["size"]) for x in r["labels"]],
              [("dbg_a", 2), ("cellA", 5), ("shared", 7), ("tailbuf", 6)])
        check("B totals", (r["totals"][NEST_D], r["totals"][NEST_DQ]), (13, 0))
        check("B headroom", r["headroom"], 0x20 - 0x14)
        check("B exit --min 40", exit_code(r, 40), 1)
    except Exception as exc:                                    # noqa: BLE001
        fails.append(f"B: {type(exc).__name__}: {exc}")
    # Release: the page ends in jp shared (3 bytes, decoded from the page bytes).
    c = self_sld([("F", e, 11, "shared"), ("T", e, 12, ""), ("T", e + 3, 16, "")])
    try:
        r = inventory(c, SELF_SRC, page_bytes=lambda p: bytes([0x21, 0, 0, 0xC3, 0, 0xE0]))
        check("C image", r["image"], "Release")
        check("C totals", (r["totals"][NEST_D], r["totals"][NEST_DQ]), (0, 0))
        check("C end", r["end"], e + 6)
        check("C headroom", r["headroom"], 26)
        check("C exit --min 40", exit_code(r, 40), 0)
    except Exception as exc:                                    # noqa: BLE001
        fails.append(f"C: {type(exc).__name__}: {exc}")
    # An instruction after the last record cannot be sized: a setup error.
    bad = SELF_SRC.replace('    db "ab", 2', "    nop")
    try:
        inventory(a, bad)
        fails.append("D: an unsized tail instruction was accepted")
    except Setup:
        pass
    except Exception as exc:                                    # noqa: BLE001
        fails.append(f"D: {type(exc).__name__}: {exc}")
    # ELSE branches: of IFDEF DEBUG not DEBUG-only, of IFNDEF DEBUG DEBUG-only; tail by branch.
    nop8 = lambda p: bytes(8)                                   # noqa: E731
    ed = self_sld([("F", e, 3, "dbg_e"), ("T", e, 3, ""), ("F", e + 1, 11, "dbg_f"),
                   ("T", e + 1, 11, ""), ("T", e + 2, 12, ""), ("T", e + 3, 13, ""),
                   ("F", e + 4, 15, "both"), ("T", e + 4, 15, "")], [dbg])
    er = self_sld([("F", e, 5, "rel_e"), ("T", e, 5, ""), ("T", e + 1, 6, ""),
                   ("F", e + 2, 9, "rel_f"), ("T", e + 2, 9, ""), ("F", e + 3, 15, "both"),
                   ("T", e + 3, 15, "")])
    try:
        r = inventory(ed, SELF_ELSE, page_bytes=nop8)
        check("E DEBUG sizes", [(x["name"], x["size"], x["nest"]) for x in r["labels"]],
              [("dbg_e", 1, NEST_D), ("dbg_f", 3, NEST_D), ("both", 2, None)])
        check("E DEBUG end", r["end"], e + 6)
        r = inventory(er, SELF_ELSE, page_bytes=nop8)
        check("E Release sizes", [(x["name"], x["size"], x["nest"]) for x in r["labels"]],
              [("rel_e", 2, None), ("rel_f", 1, None), ("both", 5, None)])
        check("E Release end", r["end"], e + 8)
    except Exception as exc:                                    # noqa: BLE001
        fails.append(f"E: {type(exc).__name__}: {exc}")
    # A label on a conditional directive line is refused, naming the line.
    lab_if = SELF_SRC.replace("\n IFDEF DEBUG\ndbg_a:", "\nlab: IFDEF DEBUG\ndbg_a:")
    lab_else = SELF_ELSE.replace("\n ELSE\nrel_e:", "\nlab ELSE\nrel_e:")
    for tag, sld, src, n in (("F IFDEF", a, lab_if, 2), ("F ELSE", ed, lab_else, 4)):
        try:
            inventory(sld, src, page_bytes=nop8)
            fails.append(f"{tag}: a labelled directive was accepted")
        except Setup as exc:
            check(f"{tag} message", str(exc).startswith(f"line {n}: label lab "), True)
        except Exception as exc:                                # noqa: BLE001
            fails.append(f"{tag}: {type(exc).__name__}: {exc}")
    # The quiet image's report says why its not-NXB_QUIET total is 0; DEBUG's does not.
    for tag, sld, want in (("G quiet", b, True), ("G DEBUG", a, False)):
        try:
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                report(inventory(sld, SELF_SRC), 40, "selftest")
            tot = [x for x in buf.getvalue().splitlines() if x.startswith("totals:")]
            check(f"{tag} totals note", [QUIET_NOTE in x for x in tot], [want])
        except Exception as exc:                                # noqa: BLE001
            fails.append(f"{tag}: {type(exc).__name__}: {exc}")
    for f in fails:
        print("FAIL " + f)
    print("hot_inventory selftest: " + ("FAIL" if fails else "PASS"))
    return 1 if fails else 0


def exit_code(r, floor):
    """1 when a DEBUG image's headroom is under floor."""
    return 1 if r["image"] != "Release" and r["headroom"] < floor else 0


def nex_pages(path):
    """page -> 8K bytes of a .nex payload."""
    from dma_contract import NEX_BANK_ORDER
    d = Path(path).read_bytes()
    if d[0:4] != b"Next":
        raise Setup(f"{path} is not a .nex file")
    present = [b for b in NEX_BANK_ORDER if d[18 + b]]

    def page(p):
        if p // 2 not in present:
            raise Setup(f"page {p} is not in {path}")
        off = 512 + 16384 * present.index(p // 2) + 8192 * (p % 2)
        return d[off:off + 8192]
    return page


def report(r, floor, where):
    print(f"hot_inventory: {r['image']} image, {r['page']} page ({r['page_sym']} "
          f"{r['page_no']}), {where}")
    debug = [x for x in r["labels"] if x["nest"]]
    if debug:
        print("    addr  size   line  nesting                  label")
        for x in debug:
            print(f"  ${x['addr']:04X} {x['size']:5d} {x['line']:6d}  {x['nest']:<24} {x['name']}")
    else:
        print("  no labels inside IFDEF DEBUG")
    n = {k: sum(1 for x in debug if x["nest"] == k) for k in (NEST_D, NEST_DQ)}
    quiet = f": {QUIET_NOTE}" if r["image"] == "DEBUG+NXB_QUIET" else ""
    print(f"totals: {NEST_D} {r['totals'][NEST_D]} ({n[NEST_D]} labels), "
          f"{NEST_DQ} {r['totals'][NEST_DQ]} ({n[NEST_DQ]} labels{quiet})")
    verdict = ("Release: no floor" if r["image"] == "Release" else
               f"floor {floor}: " + ("UNDER" if exit_code(r, floor) else "ok"))
    print(f"page end ${r['end']:04X}, OVL_LIMIT ${r['limit']:04X}, "
          f"headroom {r['headroom']} ({verdict})")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--sld", default=str(BUILD_SLD))
    ap.add_argument("--nex", help="default: the SLD's sibling .nex")
    ap.add_argument("--min", type=int, help="headroom floor (default hot 40, cold 100)")
    ap.add_argument("--page", choices=sorted(PAGES), default="hot")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args(argv)
    if args.selftest:
        return selftest()
    floor = PAGES[args.page][2] if args.min is None else args.min
    sld = Path(args.sld)
    nex = Path(args.nex) if args.nex else sld.with_suffix(".nex")
    try:
        for p in (sld, VIDEO_SRC):
            if not p.exists():
                raise Setup(f"{p} is missing")
        pages = None

        def page_bytes(p):
            nonlocal pages
            if pages is None:
                if not nex.exists():
                    raise Setup(f"{nex} is missing")
                pages = nex_pages(nex)
            return pages(p)
        r = inventory(sld.read_text(encoding="utf-8", errors="replace"),
                      VIDEO_SRC.read_text(encoding="utf-8", errors="replace"),
                      args.page, page_bytes)
    except Setup as exc:
        print(f"hot_inventory: setup error: {exc}")
        return 2
    report(r, floor, sld)
    return exit_code(r, floor)


if __name__ == "__main__":
    sys.exit(main())
