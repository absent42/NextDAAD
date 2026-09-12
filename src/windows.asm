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
    ld a, (tmCols)
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
    ld a, TM_ATTR_DEFAULT
    ld (hl), a                  ; attr - reserved pair 0 until a condact
    inc hl                      ; changes ink or paper
    ld a, TM_ATTR_CURSOR
    ld (hl), a                  ; attrInv - reserved pair 2, the cursor's
    inc hl                      ; boot inverse, until ink or paper change
    djnz .win
    xor a
    ; fall through to win_select

; A = window number 0-7.
win_select:
    push af
    call prn_flush              ; flush the old window's pending word
    pop af                      ; before the switch (wrapBuf is window-
    and 7                       ; relative); no-op when nothing buffered
    ld hl, winTable
    ld d, WIN_SIZE              ; window 0: MUL gives 0, add hl,0 is
    ld e, a                     ; harmless, so no zero test is needed
    mul d, e
    add hl, de
    ld (curWin), hl
    ret

; HL = curWin + offset A. Corrupts AF (CF clear); preserves BC, DE.
win_field:
    ld hl, (curWin)
    add hl, a                   ; Z80N, clears CF (RTL-settled)
    ret

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

; Out: E = this window's resolved tilemap attribute. A plain fetch:
; the pair is allocated and cached by win_attr_resolve (overlay0)
; whenever ink or paper changes, never here. Preserves D.
win_attr:
    ld a, WIN_ATTR
    call win_field
    ld e, (hl)
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
; The record walk below leaves HL -> WIN_CURY and steps by fixed
; offsets afterwards; the ASSERTs pin the layout it assumes.
    ASSERT WIN_CURY == WIN_CURX+1
    ASSERT WIN_W == WIN_CURX-2
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
    push hl                     ; HL -> WIN_CURY across tm_putc_at
    call tm_putc_at             ; corrupts AF, HL only
    pop hl
    dec hl                      ; -> WIN_CURX
    ld a, (hl)
    inc a
    ld (hl), a
    dec hl
    dec hl                      ; -> WIN_W
    ld a, (hl)
    inc hl
    inc hl                      ; -> WIN_CURX again (.wrap stores here)
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
