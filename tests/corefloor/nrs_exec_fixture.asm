; tests/core_floor_check.py executes this with -DNR_STANDIN=1: the real
; hardware.asm stand-in, reached by NRGET n / halt for n = 0..255 at PROBE.
    DEVICE ZXSPECTRUMNEXT
    INCLUDE "../../src/nextdaad.inc"
PROBE equ $C000
    ORG CODE_ORG
    INCLUDE "../../src/hardware.asm"
    ORG PROBE
    DUP 256, pidx                   ; no "reg" sub-word: NRGET's parameter would recurse
      NRGET pidx
      halt
    EDUP
    SAVEBIN "tests/out/corefloor/nrs_exec_fixture.bin", CODE_ORG, $8000
