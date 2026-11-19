; NRGET encodings: tests/core_floor_check.py assembles this shipped and
; with -DNR_STANDIN=1. NRS_PAGE stands in for the sled's page (not included).
    INCLUDE "../../src/nextdaad.inc"
FIX_PAGE equ $A7
NRS_PAGE equ FIX_PAGE
probe_reg equ $6B               ; argument with a "reg" sub-word: no parameter clash

    OUTPUT "tests/out/corefloor/nrget_fixture.bin"
    NRGET $56
    NRGET probe_reg
    OUTEND
