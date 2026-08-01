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
