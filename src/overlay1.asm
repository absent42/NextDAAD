; NextDAAD code overlay 1 (8K page 57 -> MMU slot 7 at $E000).
; Parser, input editor, keyboard decode layer. Reached only via the
; engine dispatcher (cdisp page byte). Calls RESIDENT services only -
; never overlay0.

    MMU 7, OVL1_PAGE, OVL_ORG

; condition result helpers (CF contract, local to this overlay)
ovl1_true:
    or a
    ret
ovl1_false:
    scf
    ret

h_time:                         ; 83: flags 48/49 (semantics live in
    ld a, b                     ; the editor/waits that read them)
    ld (flags+FLAG_TIMEOUT), a
    ld a, c
    ld (flags+FLAG_TIMECTL), a
    ret

h_input:                        ; 96: arg1 -> flag 41 (stream, single
    ld a, b                     ; stream honoured as "current"); arg2
    ld (flags+FLAG_INPUTSTREAM), a ; bits 0-2 -> flag 49 bits 3-5
    ld a, c
    add a, a
    add a, a
    add a, a
    and $38
    ld e, a
    ld a, (flags+FLAG_TIMECTL)
    and $C7
    or e
    ld (flags+FLAG_TIMECTL), a
    ret

    ASSERT $ <= OVL_LIMIT
