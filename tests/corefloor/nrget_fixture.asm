; NRGET encodings: tests/core_floor_check.py assembles this shipped and
; with -DNR_STANDIN=1. NRS_PAGE stands in for the sled's page (not included).
    INCLUDE "../../src/nextdaad.inc"
FIX_PAGE equ $A7
NRS_PAGE equ FIX_PAGE

    OUTPUT "tests/out/corefloor/nrget_fixture.bin"
    NRGET $56
    NRGET $6B
    OUTEND
