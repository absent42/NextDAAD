; The 8 DAAD windows. Struct layout per WIN_* in nextdaad.inc.
; win_putc does NOT advance to the next line itself: on hitting the
; right edge it sets CF and leaves curX at 0; the caller decides how
; to advance (print.asm routes it through the More...-aware newline).

windows_init:
    ld a, (tmCols)
    ld (winTpl+WIN_W), a        ; the template is resident RAM: a plain store
    ld de, winTable
    ld b, WINDOW_COUNT
.win:
    push bc
    ld hl, winTpl
    ld bc, WIN_SIZE
    ldir
    pop bc
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
; the pair is allocated and cached by win_attr_resolve (below)
; whenever ink or paper changes, never here. Preserves D.
win_attr:
    ld a, WIN_ATTR
    call win_field
    ld e, (hl)
    ret

; Out: C = x, B = y, E = w, D = h (tm_fill_rect's order), tmAttr = the
; window's attr. Corrupts AF, HL.
win_rect:
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
    ret

win_cls:
    call win_rect
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
    call win_rect
    jp tm_scroll_rect

; Pre-anchor ballast (engine.asm's flags ALIGN note): moved in from
; tmpairs.asm 2026-09, beside the win_field it calls three times.
; Re-resolve the current window's attribute and the cursor's inverted
; attribute from its ink and paper. Called whenever either changes.
; Corrupts all registers.
    ASSERT WIN_PAPER == WIN_INK+1
win_attr_resolve:
    ld a, WIN_INK
    call win_field
    ld c, (hl)                  ; ink
    inc hl
    ld b, (hl)                  ; paper
    push bc
    call pair_get
    ld e, a
    ld a, WIN_ATTR
    call win_field
    ld (hl), e
    pop bc
    ld a, b                     ; swap the roles for the block cursor
    ld b, c
    ld c, a
    call pair_get
    ld e, a
    ld a, WIN_ATTRINV
    call win_field
    ld (hl), e
    ret

; One window record at boot; WIN_W patched from tmCols by windows_init and win_regeom.
winTpl:
    db 0                        ; WIN_X
    db 0                        ; WIN_Y
    db 80                       ; WIN_W (patched)
    db TM_ROWS                  ; WIN_H
    db 0                        ; WIN_CURX
    db 0                        ; WIN_CURY
    db 0                        ; WIN_FLAGS
    db 7                        ; WIN_INK (hardware 7 = white)
    db 0                        ; WIN_PAPER
    db 0                        ; WIN_LINES
    db TM_ATTR_DEFAULT          ; WIN_ATTR - reserved pair 0 until ink/paper change
    db TM_ATTR_CURSOR           ; WIN_ATTRINV - reserved pair 2, the boot inverse
    ASSERT $ - winTpl == WIN_SIZE
    ASSERT WIN_X == 0 && WIN_Y == 1 && WIN_W == 2 && WIN_H == 3 && WIN_INK == 7
    ASSERT WIN_ATTR == WIN_SIZE-2 && WIN_ATTRINV == WIN_SIZE-1
curWin:   dw winTable
winTable: ds WINDOW_COUNT * WIN_SIZE
