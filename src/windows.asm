; The 8 DAAD windows. Struct layout per WIN_* in nextdaad.inc.
; win_putc does NOT advance to the next line itself: on hitting the
; right edge it sets CF and leaves curX at 0; the caller decides how
; to advance (print.asm routes it through the More...-aware newline).

windows_init:
    ld b, WINDOW_COUNT
    ld hl, winTable
.win:
    xor a
    ld (hl), a                  ; x
    inc hl
    ld (hl), a                  ; y
    inc hl
    ld a, TM_COLS
    ld (hl), a                  ; w
    inc hl
    ld a, TM_ROWS
    ld (hl), a                  ; h
    inc hl
    xor a
    ld (hl), a                  ; curX
    inc hl
    ld (hl), a                  ; curY
    inc hl
    ld (hl), a                  ; flags
    inc hl
    ld a, 7
    ld (hl), a                  ; ink (hardware 7 = white)
    inc hl
    xor a
    ld (hl), a                  ; paper
    inc hl
    ld (hl), a                  ; lastPicture
    inc hl
    ld (hl), a                  ; lines
    inc hl
    djnz .win
    ld a, 1
    ld (tmUp), a
    xor a
    ; fall through to win_select

; A = window number 0-7.
win_select:
    push af
    call prn_flush              ; flush the old window's pending word
    pop af                      ; before the switch (wrapBuf is window-
    and 7                       ; relative); no-op when nothing buffered
    ld hl, winTable
    or a
    jr z, .done
    ld b, a
    ld de, WIN_SIZE
.mul:
    add hl, de
    djnz .mul
.done:
    ld (curWin), hl
    ret

; HL = curWin + offset A. Corrupts AF; preserves BC, DE.
win_field:
    push de
    ld e, a
    ld d, 0
    ld hl, (curWin)
    add hl, de
    pop de
    ret

; B=y, C=x, D=h, E=w. Homes the cursor.
win_set_geom:
    ld hl, (curWin)
    ld (hl), c                  ; WIN_X
    inc hl
    ld (hl), b                  ; WIN_Y
    inc hl
    ld (hl), e                  ; WIN_W
    inc hl
    ld (hl), d                  ; WIN_H
    ; fall through to win_home

win_home:
    ld a, WIN_CURX
    call win_field
    xor a
    ld (hl), a                  ; curX
    inc hl
    ld (hl), a                  ; curY
    ld a, WIN_LINES
    call win_field
    ld (hl), 0
    ret

; Out: E = attribute = (paper*16 + ink) << 1. Ink is full 0-15; paper
; masks to 0-7 (the tilemap holds 8 paper slots), so a paper 8-15
; renders as its base hue. Preserves D.
win_attr:
    ld a, WIN_INK
    call win_field
    ld a, (hl)                  ; ink 0-15
    and 15
    ld e, a
    inc hl
    ld a, (hl)                  ; paper
    and 7                       ; 8 paper slots
    swapnib                     ; paper * 16
    add a, e                    ; pair = paper*16 + ink
    add a, a                    ; pair << 1
    ld e, a
    ret

win_cls:
    call win_attr
    ld a, e
    ld (tmAttr), a
    ld hl, (curWin)
    ld c, (hl)                  ; x
    inc hl
    ld b, (hl)                  ; y
    inc hl
    ld e, (hl)                  ; w
    inc hl
    ld d, (hl)                  ; h
    ld a, GLYPH_SPACE
    call tm_fill_rect
    jr win_home

; A = glyph. Prints at the cursor in the window pair and advances.
; Out: CF set = the cursor wrapped past the right edge (curX reset to
; 0, curY NOT advanced - caller must call win_newline). CF clear = no
; wrap. Corrupts AF, BC, DE, HL.
win_putc:
    push af
    call win_attr               ; E = attr
    ld hl, (curWin)
    ld c, (hl)                  ; x
    inc hl
    ld b, (hl)                  ; y
    inc hl
    inc hl
    inc hl                      ; -> WIN_CURX
    ld a, (hl)
    add a, c
    ld c, a                     ; screen col
    inc hl
    ld a, (hl)
    add a, b
    ld b, a                     ; screen row
    pop af
    call tm_putc_at
    ld a, WIN_CURX
    call win_field
    ld a, (hl)
    inc a
    ld (hl), a
    push hl
    ld a, WIN_W
    call win_field
    ld a, (hl)
    pop hl
    cp (hl)                     ; w == new curX?
    jr z, .wrap
    or a                        ; CF clear
    ret
.wrap:
    ld (hl), 0                  ; curX = 0
    scf
    ret

; Column 0, next row; scroll at the bottom; count the line.
; Corrupts all registers.
win_newline:
    ld a, WIN_CURX
    call win_field
    ld (hl), 0
    ld a, WIN_LINES
    call win_field
    inc (hl)
    ld a, WIN_H
    call win_field
    ld e, (hl)                  ; height
    ld a, WIN_CURY
    call win_field
    ld a, (hl)
    inc a
    cp e
    jr z, .scroll
    ld (hl), a
    ret
.scroll:                        ; cursor stays on the last row
    call win_attr
    ld a, e
    ld (tmAttr), a
    ld hl, (curWin)
    ld c, (hl)
    inc hl
    ld b, (hl)
    inc hl
    ld e, (hl)
    inc hl
    ld d, (hl)
    jp tm_scroll_rect

curWin:   dw winTable
winTable: ds WINDOW_COUNT * WIN_SIZE
