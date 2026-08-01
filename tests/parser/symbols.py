"""Parse build artefacts for the addresses and dispatch mapping the
NextDAAD leg needs. Addresses are never hardcoded in the harness - the
map is a build artefact, so parsing it keeps us correct across relayouts.
"""
import re
from pathlib import Path

# sjasmplus map line: "0000A200 0000A200 00 FLAGS"
_MAP_LINE = re.compile(r"^([0-9A-Fa-f]{8})\s+[0-9A-Fa-f]{8}\s+\S+\s+(\S+)\s*$")

# engine.asm dispatch entry: "    DC h_random                 ; 95  RANDOM"
# Also matches DC1 and DC2 variants, and entries with non-word trailing comments
_DISPATCH = re.compile(r"^\s*DC[12]?\s+(\w+)\s*;\s*(\d+)\b")

# nextdaad.inc constant: "OBJ_SIZE        equ 6"
_OBJ_SIZE = re.compile(r"^\s*OBJ_SIZE\s+equ\s+(\d+)\b")

# engine.asm cprops row: "    db $81,$82,2         ; 35-37 ..." - a db
# directive holding one or more byte literals, decimal or $hex.
_DB_LINE = re.compile(r"^\s*db\s+(.+)$")
_DB_VALUE = re.compile(r"^(?:\$([0-9A-Fa-f]+)|(\d+))$")

# cprops bit layout, per engine.asm's own header comment above the table:
#     bit 7 = action (clear = condition), bits 0-1 = argc
CPROPS_ACTION = 0x80
CPROPS_ARGC = 0x03


def load_symbols(map_path):
    """Return {SYMBOL_NAME: address} from an sjasmplus .map file."""
    syms = {}
    for line in Path(map_path).read_text(encoding="utf-8", errors="replace").splitlines():
        m = _MAP_LINE.match(line)
        if m:
            syms[m.group(2)] = int(m.group(1), 16)
    if not syms:
        raise ValueError("no symbols parsed from %s" % map_path)
    return syms


def load_condacts(engine_asm_path):
    """Return {condact_number: handler_symbol} from engine.asm's DC table."""
    cds = {}
    for line in Path(engine_asm_path).read_text(encoding="utf-8", errors="replace").splitlines():
        m = _DISPATCH.match(line)
        if m:
            cds[int(m.group(2))] = m.group(1)
    if not cds:
        raise ValueError("no dispatch entries parsed from %s" % engine_asm_path)

    # Verify a complete gap-free range starting at 0
    expected_count = max(cds.keys()) + 1
    if len(cds) != expected_count or set(cds.keys()) != set(range(expected_count)):
        missing = set(range(expected_count)) - set(cds.keys())
        raise ValueError("incomplete condact dispatch table: missing %s from %s" % (sorted(missing), engine_asm_path))

    return cds


def load_cprops(engine_asm_path):
    """Return {condact_number: property_byte} from engine.asm's cprops table.

    The byte is engine.asm's own encoding: bit 7 set = ACTION-typed,
    clear = CONDITION-typed (the dispatcher stamps `done` for an action
    and lets a condition's carry gate the rest of the entry); bits 0-1 =
    argc. Callers should mask with CPROPS_ACTION / CPROPS_ARGC rather
    than comparing whole bytes, so an unrelated bit gaining a meaning
    later does not silently break every comparison.

    Read out of the same region tests/check-cprops.ps1 reads - the run
    of `db` directives after the `cprops:` label, ahead of `cdisp:` -
    because the table is source, not a build artefact, and the two
    checks must see the same 128 rows. check-cprops.ps1 validates argc
    against DRF.exe's parameter table; this reader exists so
    parser_selftest.py can pin the TYPING bit, which nothing else checks
    at all. It differs from that script in one way on purpose: an
    unrecognised value RAISES here instead of being skipped, because a
    skipped row shifts every condact number after it.
    """
    text = Path(engine_asm_path).read_text(encoding="utf-8", errors="replace")
    body = re.search(r"^cprops:\s*$(.*?)^cdisp:", text, re.S | re.M)
    if not body:
        raise ValueError("cprops..cdisp block not found in %s" % engine_asm_path)

    vals = []
    for raw in body.group(1).splitlines():
        line = raw.split(";", 1)[0]
        if not line.strip():
            continue
        m = _DB_LINE.match(line)
        if not m:
            # The table ends at the first directive that is not a `db` -
            # in practice the DC/DC1/DC2 MACRO definitions that sit
            # between cprops and the cdisp label, whose own `db
            # OVL0_PAGE` lines are NOT cprops rows. Stopping here rather
            # than skipping unknown lines means a row accidentally moved
            # below such a directive shows up as a row-count failure
            # instead of being silently dropped.
            break
        for tok in m.group(1).split(","):
            tok = tok.strip()
            if not tok:
                continue
            v = _DB_VALUE.match(tok)
            if not v:
                raise ValueError(
                    "cprops value %r in %s is neither a decimal nor a $hex "
                    "byte literal - the table's format changed and this "
                    "reader would silently mis-index every row after it"
                    % (tok, engine_asm_path))
            vals.append(int(v.group(1), 16) if v.group(1) else int(v.group(2)))

    if len(vals) != 128:
        raise ValueError(
            "cprops parsed %d rows from %s, expected 128 - a mis-parse here "
            "shifts every condact number, so refuse rather than guess"
            % (len(vals), engine_asm_path))
    return dict(enumerate(vals))


def load_obj_size(nextdaad_inc_path):
    """Return OBJ_SIZE (bytes per objTable record) from nextdaad.inc.

    objTable (src/engine.asm) is a STRUCT ARRAY, not a flat array of
    object locations - each OBJ_SIZE-byte record holds, per
    eng_load_objects (src/engine.asm):
        +0  location
        +1  attributes
        +2  extended attribute low
        +3  extended attribute high
        +4  noun id
        +5  adjective id
    Reading obj_count consecutive bytes starting at OBJTABLE (as an
    earlier version of nleg.py did) reads record 0's six fields as
    "objects" 0-5, record 1's as 6-11, and so on - never the actual
    locations. Deriving OBJ_SIZE from source here, rather than
    hardcoding 6 a second time, keeps the harness honest if the record
    layout ever changes.
    """
    for line in Path(nextdaad_inc_path).read_text(
            encoding="utf-8", errors="replace").splitlines():
        m = _OBJ_SIZE.match(line)
        if m:
            return int(m.group(1))
    raise ValueError("OBJ_SIZE not found in %s" % nextdaad_inc_path)
