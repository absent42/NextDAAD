; INTRO.DAT in page 38, read through slot 6. Slide and item records are
; copied out into curSlide/curItem; strings are read in place.
script_load:
    ld hl, datName
    call name_intro
    call esx_open_name
    jr nc, .open
    ld a, ERR_DAT_MISSING
    call dbg_code
    scf
    ret
.open:
    push af
    ld a, PG_SCRIPT
    call map6
    pop af
    push af
    ld de, 0
    ld bc, DAT_MAX
    call esx_read6
    pop af
    push bc
    call esx_close_a
    pop bc
    ld a, PG_SCRIPT
    call map6
    ld hl, WIN6
    ld a, (hl)
    cp 'N'
    jp nz, .bad                      ; .bad is out of jr range from here
    inc hl
    ld a, (hl)
    cp 'D'
    jp nz, .bad
    inc hl
    ld a, (hl)
    cp 'I'
    jp nz, .bad
    inc hl
    ld a, (hl)
    cp 'N'
    jr nz, .bad
    ld a, (WIN6+DAT_VER)
    cp 1
    jr nz, .bad
    ld a, (WIN6+DAT_NSLIDES)
    or a
    jr z, .counts
    cp 65
    jr nc, .counts
    ld (slideCount), a
    ld hl, (WIN6+DAT_STRLEN)
    ld de, 3501
    or a
    sbc hl, de
    jr nc, .counts
    ld a, (WIN6+DAT_FLAGS)
    ld b, a
    and FL_LOOP
    ld (loopFlag), a
    ld a, b
    and FL_SKIPMASK
    rrca
    ld (skipMode), a
    ld a, b
    and FL_COLFONT
    jr z, .f1
    ld a, 1
.f1:
    ld (fontKind), a
    ld a, b
    and FL_COLS40
    ld a, 80
    ld e, 160
    jr z, .c80
    ld a, 40
    ld e, 80
.c80:
    ld (cols), a
    ld a, e
    ld (tmStride), a
    ld a, (WIN6+DAT_MUSIC)
    ld (musicKind), a
    ld a, (WIN6+DAT_SKIPWIN)
    ld l, a
    ld h, 0
    call scale_hz
    ld (skipWindow), hl
    ld a, (WIN6+DAT_ENDTR)
    ld (endTrans), a
    ld a, (WIN6+DAT_ENDCOL)
    ld (endColour), a
    ld hl, (WIN6+DAT_ENDFR)
    call scale_hz
    ld (endFrames), hl
    ld a, (WIN6+DAT_BORDER)
    ld (borderCol), a
    or a
    ret
.bad:
    ld a, ERR_DAT_MAGIC
    call dbg_code
    scf
    ret
.counts:
    ld a, ERR_DAT_COUNTS
    call dbg_code
    scf
    ret
datName: db "INTRO.DAT", 0

; A = slide index -> curSlide, times scaled. Corrupts AF, BC, DE, HL.
slide_fetch:
    ld de, curSlide
; A = slide index, DE = 16-byte destination. The loader fetches into its
; own loadRec so a prefetch never disturbs the current slide's record.
slide_fetch_de:
    push de
    push af
    ld a, PG_SCRIPT
    call map6
    pop af
    ld l, a
    ld h, 0
    add hl, hl
    add hl, hl
    add hl, hl
    add hl, hl
    ld bc, WIN6+DAT_SLIDES
    add hl, bc
    ld bc, 16
    ldir
    pop ix                           ; IX = destination record
    ld l, (ix+SL_TRF)
    ld h, (ix+SL_TRF+1)
    call scale_hz
    ld (ix+SL_TRF), l
    ld (ix+SL_TRF+1), h
    ld l, (ix+SL_HOLD)
    ld h, (ix+SL_HOLD+1)
    ld a, h
    cp $FF
    ret z                            ; KEY / SCROLL markers stay
    call scale_hz
    ld (ix+SL_HOLD), l
    ld (ix+SL_HOLD+1), h
    ret

; A = item index -> curItem, AT scaled. Corrupts AF, BC, DE, HL.
item_fetch:
    push af
    ld a, PG_SCRIPT
    call map6
    pop af
    ld l, a
    ld h, 0
    ld b, h
    ld c, l                          ; BC = index
    add hl, hl
    add hl, bc                       ; 3x
    add hl, hl
    add hl, hl                       ; 12x
    ld de, WIN6+DAT_ITEMS
    add hl, de
    ld de, curItem
    ld bc, 12
    ldir
    ld hl, (curItem+IT_AT)
    call scale_hz
    ld (curItem+IT_AT), hl
    ret

; DE = string offset -> HL = address in the slot 6 window (page 38 mapped).
str_map:
    ld a, PG_SCRIPT
    call map6
    ld hl, WIN6+DAT_STRINGS
    add hl, de
    ret
