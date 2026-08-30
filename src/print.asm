; The print pipeline: decode dispatch, escapes, More... paging.
; Paging lives HERE, not in windows.asm: prn_newline and prn_char's
; wrap handling both run the More... check, so wrapped long lines page
; exactly like explicit newlines.

; A = kind 0-3, E = number. Prints one whole message.
print_msg:
    push af
    push de
    call data_save
    pop de
    pop af
    call msg_seek
    jr c, .badnum
    xor a
    ld (tokActive), a           ; fresh stream
.loop:
    call txt_next_decoded
    jr c, .done
    call prn_decoded
    jr .loop
.done:
    call prn_flush              ; emit any pending word (no newline added)
    jp data_restore
.badnum:
 IFDEF DEBUG
    ld c, '?'
    call prn_char
    ld c, 'M'
    call prn_char
    ld c, 'S'
    call prn_char
    ld c, 'G'
    call prn_char
 ENDIF
    call prn_flush              ; flush the ?MSG marker / any pending word
    jp data_restore

; A = decoded 7-bit character. Dispatches escapes, prints the rest.
; Token references are resolved by txt_next_decoded before this runs.
prn_decoded:
    cp $0D
    jp z, prn_newline
    cp $0B
    jp z, prn_cls
    cp $0C
    jp z, wait_key_reset
    cp $0E
    jr z, .gfxon
    cp $0F
    jr z, .gfxoff
    cp '_'
    jr z, .objname              ; always a substitution, every database
    cp '@'
    jr nz, .plain
    ; '@' is the CAPITALISED object-name escape and it exists ONLY in
    ; Spanish databases - DAAD_Ready_Documentation_V2.md's escape table:
    ; "@ | Same as the underscore, but the article has its first letter
    ; uppercased. Only works for Spanish interpreter." In an English
    ; database '@' is an ordinary printable character. jDAAD gates it on
    ; exactly this bit (jdaad.js:1636 `(mychar == ESCAPE_OBJNAME) ||
    ; ((mychar == ESCAPE_OBJNAME_CAPS) && DDB.isSpanish())`, isSpanish =
    ; bit 0 of header byte 1, jdaad.js:550). msx2daad substitutes on
    ; both unconditionally (daad_print.c:128) and that is what NextDAAD
    ; copied - it rendered Uto's own compliance fixture message 148
    ; ("-@@-", printed by its PRINTAT/SAVEAT/BACKAT check) as two object
    ; names. The compiler side agrees with jDAAD: DRC never reads the
    ; /CTL null-word character at all (drb.php:1811-1813 writes the
    ; SUB-MACHINE id into header byte 2, and DAAD Ready's own manual
    ; calls /CTL "obsolete and not used anymore"), so byte 2 is not a
    ; per-game substitution character to read - it is 95 in every
    ; database this interpreter accepts (file.asm's DDB_MAGIC check).
    ld hl, ddbHeader+1          ; target/machine + language byte
    bit 0, (hl)                 ; bit 0 = Spanish (drb.php: ES and PT)
    jr nz, .objname
.plain:
    ld c, a
    jr prn_char
.gfxon:
    ld a, 128
    ld (chsGfx), a
    ret
.gfxoff:
    xor a
    ld (chsGfx), a
    ret
.objname:
    ld hl, (objname_hook)
    jp (hl)

; C = printable decoded char. Word-buffering layer over prn_char_raw:
; printable non-space chars accumulate in wrapBuf so whole words wrap at
; the window edge; a space flushes the pending word. wrapLock (held by
; the input editor) bypasses buffering so echo stays immediate.
prn_char:
    ld a, (wrapLock)
    or a
    jr nz, prn_char_raw         ; editor: immediate echo, no buffering
    ld a, c
    cp ' '
    jr z, .space
    ; printable non-space: append C to wrapBuf[wrapLen]
    ld a, (wrapLen)
    ld e, a
    ld d, 0
    ld hl, wrapBuf
    add hl, de
    ld (hl), c
    ld a, (wrapLen)
    inc a
    ld (wrapLen), a
    ld c, a                     ; C = new wrapLen (win_field preserves BC)
    ld a, WIN_W
    call win_field
    ld a, (hl)                  ; A = WIN_W of the current window
    cp c
    jr c, .full                 ; WIN_W < wrapLen: past the window, flush
    ret nz                      ; WIN_W > wrapLen: keep buffering
.full:                          ; wrapLen reached WIN_W: hard-flush
    jp prn_flush
.space:
    call prn_flush              ; place the pending word first
    ld a, WIN_CURX
    call win_field
    ld a, (hl)
    or a
    ret z                       ; cursor at column 0: swallow the space
    ld c, ' '
    ; fall through to prn_char_raw

; C = printable decoded char. Applies the charset offset ($20-$7F only),
; prints, and runs the More... check when the print wrapped the line.
prn_char_raw:
    ld a, c
    cp $20
    jr c, .have                 ; $10-$1F extended glyphs print direct
    cp $80
    jr nc, .have
    ld a, WIN_FLAGS
    call win_field
    bit 0, (hl)                 ; window forces upper charset?
    jr nz, .upper
    ld a, (chsGfx)
    or a
    jr nz, .upper
    ld a, c
    jr .have
.upper:
    ld a, c
    add a, 128
.have:
    call win_putc
    ret nc                      ; no wrap
    call win_newline_only       ; complete the wrap's line advance
    jr prn_more_check

; Emit the buffered word through prn_char_raw. If the word overflows the
; line remainder but still fits the window, newline (+ More check) first
; so the whole word moves down together. No-op while wrapLock is held
; (the buffer belongs to a suspended outer context, e.g. the SM32 More
; prompt) or while the buffer is empty. Corrupts all registers.
prn_flush:
    ld a, (wrapLock)
    or a
    ret nz
    ld a, (wrapLen)
    or a
    ret z
    ld a, WIN_W
    call win_field
    ld c, (hl)                  ; C = WIN_W
    ld a, WIN_CURX
    call win_field
    ld a, (hl)
    ld b, a                     ; B = WIN_CURX
    ld a, c
    sub b                       ; A = remaining = WIN_W - WIN_CURX
    ld b, a                     ; B = remaining
    ld a, (wrapLen)
    cp b
    jr c, .emit                 ; wrapLen < remaining: fits as-is
    jr z, .emit                 ; wrapLen == remaining: fills exactly
    ld a, (wrapLen)             ; wrapLen > remaining
    cp c
    jr nc, .emit                ; wrapLen >= WIN_W: too wide, char-wrap
    call prn_newline_raw        ; word fits the window: wrap it down first
.emit:
    xor a
    ld (wrapIdx), a
.eloop:
    ld a, (wrapIdx)
    ld hl, wrapLen
    cp (hl)
    jr nc, .edone
    ld e, a
    ld d, 0
    ld hl, wrapBuf
    add hl, de
    ld c, (hl)
    ld a, (wrapIdx)
    inc a
    ld (wrapIdx), a
    call prn_char_raw
    jr .eloop
.edone:
    xor a
    ld (wrapLen), a
    ret

; Explicit newline with paging. Flushes the pending word first; the
; flush's own conditional wrap uses prn_newline_raw, so this cannot
; recurse back into the flush.
prn_newline:
    call prn_flush
prn_newline_raw:
    call win_newline_only
    jr prn_more_check

; The raw window newline (windows.asm's win_newline), named for
; clarity at call sites in this module.
win_newline_only:
    jp win_newline

; $0B cls escape: flush the pending word, then clear the window.
prn_cls:
    call prn_flush
    jp win_cls

; Fire the More... prompt when the window's printed lines reach h-1.
; Corrupts all registers. Preserves the outer reader, its in-flight
; push depth and physical MMU state around the nested SM32 print.
prn_more_check:
    ld a, (moreLock)
    or a
    ret nz
    ld a, WIN_FLAGS
    call win_field
    bit 1, (hl)                 ; More disabled for this window?
    ret nz
    ld a, WIN_H
    call win_field
    ld a, (hl)
    dec a
    ld e, a                     ; trigger threshold = h-1
    ld a, WIN_LINES
    call win_field
    ld a, (hl)
    cp e
    ret c
    ld (hl), 0                  ; reset the counter
    ; preserve the outer reader position and in-flight push depth
    ; (a nested SM32 token print may push/pop the reader stack)
    ld a, (rdPage)
    ld (moreSaveRdSv), a
    ld hl, (rdPtr)
    ld (moreSaveRdSv+1), hl
    ld a, (rdSaveSP)
    ld (moreSaveRdSv+3), a
    ld a, (tokActive)
    ld (moreSaveRdSv+4), a
    xor a
    ld (tokActive), a           ; SM32 starts its own fresh stream
    ; preserve the outer MMU-save shadow (the nested print_msg overwrites it)
    ld a, (savedMMU6)
    ld (moreSaveMMU), a
    ; preserve the physical MMU slot exactly as mapped pre-fire
    ld e, NR_MMU6
    call nr_read
    ld (morePhysMMU6), a
    ld a, 1
    ld (moreLock), a
    ld (wrapLock), a            ; SM32 echoes immediately, never buffers -
                                ; this protects the outer word in wrapBuf
    ld a, 0                     ; SM32 through the normal pipeline
    ld e, 32
    call print_msg
    xor a
    ld (wrapLock), a            ; restore buffering for the outer word
    ld e, $02                   ; More... timeout arm bit
    call wait_key_timeout
    xor a
    ld (moreLock), a
    ; erase the prompt line and return the cursor to its start
    ld a, WIN_CURX
    call win_field
    ld (hl), 0
    call win_attr
    ld a, e
    ld (tmAttr), a
    ld hl, (curWin)
    ld c, (hl)                  ; window x
    inc hl
    ld b, (hl)                  ; window y
    inc hl
    ld e, (hl)                  ; width
    push de
    ld a, WIN_CURY
    call win_field
    ld a, (hl)
    add a, b
    ld b, a                     ; screen row of the prompt line
    pop de
    ld d, 1
    ld a, GLYPH_SPACE
    call tm_fill_rect
    ; restore the outer MMU-save shadow (savedMMU6)
    ld a, (moreSaveMMU)
    ld (savedMMU6), a
    ; restore reader position and push depth (variables only - no
    ; physical remap here)
    ld a, (moreSaveRdSv)
    ld (rdPage), a
    ld hl, (moreSaveRdSv+1)
    ld (rdPtr), hl
    ld a, (moreSaveRdSv+3)
    ld (rdSaveSP), a
    ld a, (moreSaveRdSv+4)
    ld (tokActive), a
    ; restore the physical MMU slot exactly as it was pre-fire
    ld a, (morePhysMMU6)
    nextreg NR_MMU6, a
    ret

; HL = resident encoded string (255-complemented), terminated by an
; encoded $0A (byte $F5). Same escapes as messages, no tokens.
prn_encoded:
    ld a, (hl)
    inc hl
    cpl
    cp $0A
    jp z, prn_flush             ; terminator: flush the pending word, ret
    push hl
    call prn_decoded
    pop hl
    jr prn_encoded

; Block until any key is pressed then released. Corrupts AF.
wait_key:
.press:
    xor a
    in a, ($FE)
    and $1F
    cp $1F
    jr z, .press
.release:
    xor a
    in a, ($FE)
    and $1F
    cp $1F
    jr nz, .release
    ret

; Wait for a key press then release, honouring the DAAD input timeout
; when armed. E = arm mask against flag 49 ($02 More..., $04 ANYKEY).
; Returns early with flag 49 bit 7 set if flag 48 seconds elapse
; before a press. A normal keypress leaves bit 7 untouched.
; Corrupts AF, BC, DE, HL.
wait_key_timeout:
    ld a, (flags+FLAG_TIMEOUT)
    or a
    jp z, wait_key              ; no duration -> plain wait
    ld a, (flags+FLAG_TIMECTL)
    and e
    jp z, wait_key              ; this context not armed -> plain wait
    ; frames = flag48 * 50
    ; SP14c batch B PRN1: Z80N MUL D,E replaces the shift/push/add
    ; chain (flag48 is a byte, product always fits 16 bits).
    ld a, (flags+FLAG_TIMEOUT)
    ld e, a
    ld d, 50
    mul d, e
    ex de, hl
    ld (inpTOFrames), hl
    ld a, (frameCounter)
    ld d, a                     ; D = last seen frame low byte
.poll:
    xor a
    in a, ($FE)
    and $1F
    cp $1F
    jr nz, .press               ; a key is down
    ld a, (frameCounter)
    cp d
    jr z, .poll                 ; same frame
    ld d, a
    ld hl, (inpTOFrames)
    dec hl
    ld (inpTOFrames), hl
    ld a, h
    or l
    jr nz, .poll
    ; timeout
    ld a, (flags+FLAG_TIMECTL)
    or $80
    ld (flags+FLAG_TIMECTL), a
    ret
.press:
    xor a
    in a, ($FE)
    and $1F
    cp $1F
    jr nz, .press               ; wait for release
    ret

; $0C escape: wait for a key, then the pause restarts the page count.
wait_key_reset:
    call prn_flush              ; place the pending word before pausing
    call wait_key
    jr prn_reset_lines

; Reset the current window's printed-line counter (the More... pager).
prn_reset_lines:
    ld a, WIN_LINES
    call win_field
    ld (hl), 0
    ret

objname_stub:
    ret

; A = byte -> decimal via prn_char, no leading zeros ("0" for zero).
prn_dec8:
    ld l, a
    ld h, 0
; HL = word -> decimal via prn_char. Corrupts all.
prn_dec16:
    ld e, 0                     ; digits-started flag
    ld bc, -10000
    call prn_dec_digit
    ld bc, -1000
    call prn_dec_digit
    ld bc, -100
    call prn_dec_digit
    ld bc, -10
    call prn_dec_digit
    ld a, l
    add a, '0'
    ld c, a
    jp prn_char

prn_dec_digit:
    ld a, '0'-1
.sub:
    inc a
    add hl, bc
    jr c, .sub
    sbc hl, bc                  ; undo the overshoot
    cp '0'
    jr nz, .emit
    bit 0, e
    ret z                       ; suppress leading zero
.emit:
    ld e, 1
    push hl
    push de
    ld c, a
    call prn_char
    pop de
    pop hl
    ret

chsGfx:       db 0
moreLock:     db 0
objname_hook: dw objname_stub
moreSaveMMU:  db 0
morePhysMMU6: db 0
moreSaveRdSv: ds 5
wrapBuf:      ds 80             ; pending word (word-wrap), max = WIN_W
    ASSERT TM_COLS <= 80        ; TM_COLS is the assemble-time max;
                                 ; wrapBuf covers the widest mode (80).
                                 ; The runtime 40-col mode only narrows
                                 ; WIN_W, which is always safe.
wrapLen:      db 0             ; chars buffered in wrapBuf
wrapLock:     db 0             ; non-zero: bypass buffering (editor/SM32)
wrapIdx:      db 0             ; prn_flush emit-loop cursor

 IFNDEF DEBUG
; SP14c batch B accounting note (same class as tilemap.asm's, see
; that file's comment for the full mechanism): Release's pre-flags
; ALIGN(256) margin was down to 7 bytes by the time this module's
; PRN1 (-8 bytes) landed - measured via CDISP+384 vs the 0xA100/
; 0xA200 boundary pair. This pad cancels PRN1's Release-side effect
; so `flags` stays at 0xA200; DEBUG keeps the full saving (its own
; slack is unaffected). Re-measure before assuming this still
; applies if more pre-flags code changes upstream.
    ds 8
 ENDIF
