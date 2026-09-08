; Tilemap text over Layer 2. 1-bit: the game's FONT.CHR (2K) or the built-in
; font, text mode, attribute = pair << 1. Colour: INTRO\FONT.TIL (8K) in
; 4-bit mode, attribute = block << 4, index 0 transparent.
text_init:
    call map_bank5
    xor a
    ld (fontFallback), a
    ld a, (fontKind)
    or a
    jr nz, .colour
.onebit:
    ld hl, chrName
    call esx_open_name
    jr c, .builtin
    push af
    ld a, PG_STAGE
    call map6
    pop af
    push af
    ld de, 0
    ld bc, 2048
    call esx_read6
    pop af
    push bc
    call esx_close_a
    pop bc
    ld hl, 2048
    or a
    sbc hl, bc
    jr nz, .builtin
    ld a, PG_STAGE
    call map6
    ld hl, WIN6
    jr .defs
.builtin:
    ld a, ERR_FONT_CHR
    call dbg_code
    ld hl, fontData
.defs:
    call map_bank5
    ld de, TM_DEFS
    ld bc, 2048
    ldir
    ld a, %11001000                  ; text mode, 80x32
    jr .ctrl
.colour:
    ld hl, tilName
    call name_intro
    call esx_open_name
    jr c, .nofont
    push af
    ld a, PG_STAGE
    call map6
    pop af
    push af
    ld de, 0
    ld bc, 8192
    call esx_read6
    pop af
    push bc
    call esx_close_a
    pop bc
    ld hl, 8192
    or a
    sbc hl, bc
    jr nz, .nofont
    ld a, PG_STAGE
    call map6
    ld hl, WIN6
    call map_bank5
    ld de, TM_DEFS
    ASSERT TM_DEFS + 8192 <= $8000   ; colour font defs stay below resident code (rubric 8)
    ld bc, 8192
    ldir
    ld a, %11000000                  ; 4-bit tiles, 80x32
    jr .ctrl
.nofont:
    ld a, ERR_FONT_TIL
    call dbg_code
    ld a, 1
    ld (fontFallback), a             ; built-in 1-bit font, attribute 0 only
    ld hl, fontData
    call map_bank5
    ld de, TM_DEFS
    ld bc, 2048
    ldir
    ld a, %11001000
.ctrl:
    ld b, a
    ld a, (cols)
    cp 80
    ld a, b
    jr z, .w
    and %10111111                    ; 40 columns: bit 6 clear
.w:
    ld (tmCtrl), a
    nextreg NR_TM_MAP_BASE, TM_MAP_MSB
    nextreg NR_TM_DEF_BASE, TM_DEFS_MSB
    nextreg NR_TM_ATTR, 0
    nextreg NR_TM_TRANSP, 0
    nextreg NR_LAYERS, LAYERS_TEXT_TOP
    call tm_palette_load
    call text_clear
    ld a, (tmCtrl)
    nextreg NR_TM_CTRL, a
    ret
chrName: db "FONT.CHR", 0
tilName: db "FONT.TIL", 0
tmCtrl:  db 0

; Tilemap palette from INTRO.DAT's 512 bytes (page 38), or pair 0 alone
; under fontFallback.
tm_palette_load:
    nextreg NR_PAL_CTRL, PAL_TM_FIRST
    nextreg NR_PAL_INDEX, 0
    ld a, (fontFallback)
    or a
    jr nz, .fallback
    ld a, PG_SCRIPT
    call map6
    ld hl, WIN6+DAT_PAL
    ld b, 0
.e:
    ld a, (hl)
    inc hl
    nextreg NR_PAL_VALUE9, a
    ld a, (hl)
    inc hl
    and 1
    nextreg NR_PAL_VALUE9, a
    djnz .e
    ret
.fallback:
    nextreg NR_PAL_VALUE9, L2_TRANSP_COLOUR
    nextreg NR_PAL_VALUE9, 1
    nextreg NR_PAL_VALUE9, $FF
    nextreg NR_PAL_VALUE9, 1
    ld b, 254
.z:
    nextreg NR_PAL_VALUE9, 0
    nextreg NR_PAL_VALUE9, 0
    djnz .z
    ret

; Blank the whole map (glyph 32, attribute 0), reset the reveal table,
; scroll registers and clip window. Seed-then-LDIR fill (doc 04): the two
; seed bytes propagate through the block. Corrupts AF, BC, DE, HL.
    ASSERT TM_MAP + 80*32*2 <= DBG_MIRROR ; the fill below must not reach the mirror (rubric 8)
text_clear:
    call map_bank5
    ld hl, TM_MAP
    ld (hl), 32
    inc hl
    ld (hl), 0
    ld hl, TM_MAP
    ld de, TM_MAP+2
    ld bc, 80*32*2 - 2
    ldir
    ld hl, itemShown
    ld de, itemShown+1
    ld bc, itemShownEnd - itemShown - 1
    ld (hl), 0
    ldir
    nextreg NR_TM_YOFS, 0
    nextreg NR_TM_XOFS, 0
    nextreg NR_TM_XOFS_MSB, 0
    nextreg NR_CLIP_IDX, 8
    nextreg NR_TM_CLIP, 0
    nextreg NR_TM_CLIP, 159
    nextreg NR_TM_CLIP, 0
    nextreg NR_TM_CLIP, 255
    ret

; B = row: fill its cells with glyph 32, attribute 0.
text_row_clear:
    call map_bank5
    call tm_row_addr
    ld a, (cols)
    ld b, a
.c:
    ld (hl), 32
    inc hl
    ld (hl), 0
    inc hl
    djnz .c
    ret

; B = row -> HL = TM_MAP + row * stride. Corrupts AF, DE.
tm_row_addr:
    ld a, (tmStride)
    ld d, a
    ld e, b
    mul d, e
    ld hl, TM_MAP
    add hl, de
    ret

; HL = string -> A = length (stops at NUL or 80).
str_len:
    ld b, 0
.l:
    ld a, (hl)
    or a
    jr z, .d
    inc hl
    inc b
    ld a, b
    cp 80
    jr c, .l
.d:
    ld a, b
    ret

; B = row, C = col, HL = string in the slot 6 window (page 38 is remapped
; here), E = attribute, D = characters to write (0 = all). Under
; fontFallback the attribute is forced to 0.
text_put:
    ld a, d
    ld (putCount), a
    ld a, e
    ld (putAttr), a
    ld a, (fontFallback)
    or a
    jr z, .attr
    xor a
    ld (putAttr), a
.attr:
    push hl
    call map_bank5
    call tm_row_addr
    ld a, c
    add a, a
    add hl, a                        ; Z80N: HL += A
    ex de, hl                        ; DE = cell address
    pop hl                           ; HL = string
    ld a, PG_SCRIPT
    call map6
    jr text_put_body

; As text_put, HL = a resident string (no page map needed).
text_put_resident:
    ld a, d
    ld (putCount), a
    ld a, e
    ld (putAttr), a
    push hl
    call map_bank5
    call tm_row_addr
    ld a, c
    add a, a
    add hl, a
    ex de, hl
    pop hl
text_put_body:
    ld a, (putCount)
    or a
    jr nz, .go
    ld a, 80
.go:
    ld b, a
    ld a, (putAttr)
    ld c, a                          ; C is free here: the column was consumed
.ch:
    ld a, (hl)
    or a
    ret z
    ld (de), a
    inc de
    ld a, c
    ld (de), a
    inc de
    inc hl
    djnz .ch
    ret
putCount: db 0
putAttr:  db 0

; Captions for the current slide (TEXT items): each frame, items whose AT
; has passed are drawn up to their reveal count; itemShown holds the count
; drawn so far, 255 once complete.
caption_service:
    ld a, (curSlide+SL_NITEM)
    or a
    ret z
    ld b, a
    ld a, (curSlide+SL_ITEM0)
    ld c, a
.each:
    push bc
    ld a, c
    call caption_one
    pop bc
    inc c
    djnz .each
    ret

; A = item index.
caption_one:
    ld (capIdx), a
    ld hl, itemShown
    add hl, a
    ld a, (hl)
    cp 255
    ret z                            ; complete
    ld a, (capIdx)
    call item_fetch
    ld a, (curItem+IT_TYPE)
    or a
    ret nz                           ; LINE items belong to the crawl
    ld hl, (holdFrame)
    ld de, (curItem+IT_AT)
    or a
    sbc hl, de
    ret c                            ; not yet
    push hl
    ld de, (curItem+IT_STR)
    call str_map
    call str_len
    ld (capLen), a
    pop hl
    ld a, (curItem+IT_FLAGS)
    and 1
    jr z, .all
    srl h
    rr l                             ; frames since AT, halved
    inc hl                           ; characters to show
    ld a, h
    or a
    jr nz, .all
    ld a, l
    ld hl, capLen
    cp (hl)
    jr c, .count
.all:
    ld a, (capLen)
.count:
    ld (capTarget), a
    ld a, (capLen)
    or a
    jr nz, .have                     ; empty string: latch complete, nothing to draw
    ld hl, itemShown
    ld a, (capIdx)
    add hl, a
    ld (hl), 255
    ret
.have:
    ld hl, itemShown
    ld a, (capIdx)
    add hl, a
    ld a, (capTarget)
    cp (hl)
    ret z                            ; nothing new this frame
    ld (hl), a
    ld hl, capLen
    cp (hl)
    jr nz, .draw
    ld hl, itemShown
    ld a, (capIdx)
    add hl, a
    ld (hl), 255
.draw:
    ld a, (curItem+IT_COL)
    cp 255
    jr nz, .col
    ld a, (cols)
    ld hl, capLen
    sub (hl)
    srl a
.col:
    ld c, a
    ld a, (curItem+IT_ROW)
    ld b, a
    push bc
    ld de, (curItem+IT_STR)
    call str_map
    pop bc
    ld a, (curItem+IT_ATTR)
    ld e, a
    ld a, (capTarget)
    ld d, a
    jp text_put
capIdx:    db 0
capLen:    db 0
capTarget: db 0

; Ring-scroll setup (spec 6.6): P and the per-line state reset, clip hides
; the wrap row (display rows 0-7) so it is only ever seen entering the
; bottom.
scroll_begin:
    call text_clear
    ld a, (curSlide+SL_SPEED)
    ld (scrollSpeed), a
    ld a, (curSlide+SL_SATTR)
    ld (scrollAttr), a
    ld a, (curSlide+SL_ITEM0)
    ld (scrollFirst), a
    ld a, (curSlide+SL_NITEM)
    ld (scrollLines), a
    xor a
    ld (scrollLine), a
    ld hl, 0
    ld (scrollP), hl
    nextreg NR_CLIP_IDX, 8
    nextreg NR_TM_CLIP, 0
    nextreg NR_TM_CLIP, 159
    nextreg NR_TM_CLIP, 8            ; hide display rows 0-7
    nextreg NR_TM_CLIP, 255
    ret

; One frame: advance P, feed every line whose entry point P has reached,
; write the scroll register. Z when the last line has left.
scroll_step:
    ld hl, (scrollP)
    ld a, (scrollSpeed)
    add hl, a
    ld (scrollP), hl
.feed:
    ld a, (scrollLine)
    ld l, a
    ld h, 0
    add hl, hl
    add hl, hl
    add hl, hl                       ; 8k
    ld de, (scrollP)
    ex de, hl
    or a
    sbc hl, de                       ; P - 8k
    jr c, .written
    ld a, (scrollLine)
    and 31
    ld b, a
    call text_row_clear
    ld a, (scrollLine)
    ld hl, scrollLines
    cp (hl)
    jr nc, .advance                  ; past the last line: blank row only
    ld hl, scrollFirst
    add a, (hl)
    call item_fetch
    ld de, (curItem+IT_STR)
    call str_map
    call str_len
    ld c, a
    ld a, (cols)
    sub c
    srl a
    ld c, a                          ; centred column
    ld a, (scrollLine)
    and 31
    ld b, a
    push bc
    ld de, (curItem+IT_STR)
    call str_map
    pop bc
    ld a, (scrollAttr)
    ld e, a
    ld d, 0
    call text_put
.advance:
    ld hl, scrollLine
    inc (hl)
    jr .feed
.written:
    ld a, (scrollP)
    nextreg NR_TM_YOFS, a
    ld a, (scrollLines)
    ld l, a
    ld h, 0
    ld de, 31
    add hl, de
    add hl, hl
    add hl, hl
    add hl, hl                       ; 8 (L + 31) in 16 bits: 255 lines = 2288
    ld de, (scrollP)
    ex de, hl
    or a
    sbc hl, de                       ; P - end
    jr nc, .done
    or 1
    ret
.done:
    nextreg NR_TM_YOFS, 0
    xor a
    ret
