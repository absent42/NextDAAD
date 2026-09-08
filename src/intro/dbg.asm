; DEBUG mirror at DBG_MIRROR (bank 5, always mapped by the launcher's own
; rule: map_bank5 before every bank 5 access). Fatal display in both builds.
 IFDEF DEBUG
dbg_init:
    call map_bank5
    ld hl, DBG_MIRROR
    ld de, DBG_MIRROR+1
    ld bc, 31
    ld (hl), 0
    ldir
    ld hl, DBG_MIRROR
    ld (hl), 'I'
    inc hl
    ld (hl), 'N'
    ret
dbg_code:                            ; A = code, preserved
    ld (lastCode), a
    push af
    ld a, 50
    ld (dbgCodeTimer), a
    pop af
    ret
dbg_mirror:
    call map_bank5
    ld ix, DBG_MIRROR
    ld hl, dbgSeq
    inc (hl)
    ld a, (hl)
    ld (ix+2), a
    ld a, (showState)
    ld (ix+3), a
    ld a, (slideIdx)
    ld (ix+4), a
    ld a, (loadState)
    ld (ix+5), a
    ld a, (transType)
    ld (ix+6), a
    ld a, (lastCode)
    ld (ix+7), a
    ld hl, (frameCounter)
    ld (ix+8), l
    ld (ix+9), h
    ld hl, (holdLeft)
    ld (ix+10), l
    ld (ix+11), h
    ld hl, (transFrame)
    ld (ix+12), l
    ld (ix+13), h
    ld hl, (scrollP)
    ld (ix+14), l
    ld (ix+15), h
    ld a, (frontBank)
    ld (ix+16), a
    ld a, (l2Mode)
    ld (ix+17), a
    ld a, (musicKind)
    ld (ix+18), a
    ld a, (keyCount)
    ld (ix+19), a
    ld a, (hz60)
    ld (ix+20), a
    ld a, (fadeK)
    ld (ix+21), a
    ld hl, (pcmWr)
    ld (ix+22), l
    ld (ix+23), h
    ld a, (loadPage)
    ld (ix+24), a
    ld a, (fading)
    ld (ix+25), a
    ld a, (slideCount)
    ld (ix+26), a
    ld a, (skipMode)
    ld (ix+27), a
    ld a, (akyTicks)
    ld (ix+28), a
    jp dbg_show
; "IN? xx" on row 31 for 50 frames after a code. Harmless before text_init
; has run (the map is blank and the tilemap is off).
dbg_show:
    ld a, (dbgCodeTimer)
    or a
    ret z
    dec a
    ld (dbgCodeTimer), a
    jr z, .clear
    ld a, (lastCode)
    ld hl, dbgMsg+4
    push af
    rra
    rra
    rra
    rra
    call .hex
    pop af
    call .hex
    ld b, 31
    ld c, 0
    ld hl, dbgMsg
    ld e, 0
    ld d, 6
    jp text_put_resident
.clear:
    call map_bank5
    ld b, 31
    call tm_row_addr
    ld b, 6                          ; dbgMsg's own width, not the whole row
.cc:
    ld (hl), 32
    inc hl
    ld (hl), 0
    inc hl
    djnz .cc
    ret
.hex:
    and 15
    add a, '0'
    cp '9'+1
    jr c, .w
    add a, 7
.w:
    ld (hl), a
    inc hl
    ret
dbgMsg: db "IN? 00", 0
 ELSE
dbg_code:
    ld (lastCode), a
    ret
 ENDIF

; A = code. Text mode tilemap with the built-in font at FATAL_DEFS, message
; on row 0, magenta border, halt. Reached only from the hand-off (bank 2
; still intact) - a failure after banks start loading halts in the stub.
fatal_nex:
    di
    push af
    call map_bank5
    ld hl, fontData
    ld de, FATAL_DEFS
    ld bc, 2048
    ldir
    ld hl, TM_MAP
.f:
    ld (hl), 32                      ; space glyph, attribute 0
    inc hl
    ld (hl), 0
    inc hl
    ld a, h
    cp high (TM_MAP+5120)
    jr nz, .f
    nextreg NR_TM_MAP_BASE, TM_MAP_MSB
    nextreg NR_TM_DEF_BASE, FATAL_DEFS_MSB
    nextreg NR_TM_ATTR, 0
    nextreg NR_PAL_CTRL, PAL_TM_FIRST
    nextreg NR_PAL_INDEX, 0
    nextreg NR_PAL_VALUE, 0          ; pair 0 paper black
    nextreg NR_PAL_VALUE, $FF        ; pair 0 ink white
    nextreg NR_LAYERS, LAYERS_TEXT_TOP
    nextreg NR_TM_CTRL, %11001000
    ld hl, fatalMsg
    ld de, TM_MAP
.p:
    ld a, (hl)
    or a
    jr z, .code
    ld (de), a
    inc de
    xor a
    ld (de), a
    inc de
    inc hl
    jr .p
.code:
    pop af
    push af
    rra
    rra
    rra
    rra
    call .hex
    pop af
    call .hex
    ld a, 3
    out ($FE), a
.halt:
    halt
    jr .halt
.hex:
    and 15
    add a, '0'
    cp '9'+1
    jr c, .w
    add a, 7
.w:
    ld (de), a
    inc de
    xor a
    ld (de), a
    inc de
    ret
fatalMsg: db "E9 nextdaad.nex ", 0
fontData:
    INCBIN "../font.chr"
    ASSERT $ - fontData == 2048       ; ld bc, 2048 font copy above (rubric 8)
