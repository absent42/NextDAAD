; NRGET encoding: tests/core_floor_check.py assembles this and checks ED C7 n.
    INCLUDE "../../src/nextdaad.inc"
probe_reg equ $6B               ; argument with a "reg" sub-word: no parameter clash

    OUTPUT "tests/out/corefloor/nrget_fixture.bin"
    NRGET $56
    NRGET probe_reg
    OUTEND
