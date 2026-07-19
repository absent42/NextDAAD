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

; --- keyboard layer ---
; kb_raw: A = matrix code (row*5 + bit, 0..39) of the first pressed
; non-shift key, or $FF if none. B = shift state: bit 0 caps, bit 1
; symbol. Corrupts AF, BC, DE, HL.
kb_raw:
    ld e, 0                     ; E = shift state during the scan
    ld a, $FE
    in a, ($FE)
    bit 0, a
    jr nz, .nocaps
    set 0, e
.nocaps:
    ld a, $7F
    in a, ($FE)
    bit 1, a
    jr nz, .nosym
    set 1, e
.nosym:
    ld hl, kbRows
    ld d, 0                     ; matrix code base for this row
.row:
    ld a, (hl)
    or a
    jr z, .none
    ld b, a                     ; row-select byte for in a,(c)
    ld c, $FE
    in a, (c)
    cpl
    and $1F
    ld c, a                     ; C = pressed bits this row
    ; mask the shift keys themselves out of their own rows, so a held
    ; shift never wins the scan over the real key
    ld a, b
    cp $FE
    jr nz, .m1
    res 0, c                    ; caps shift itself
.m1:
    cp $7F
    jr nz, .m2
    res 1, c                    ; symbol shift itself
.m2:
    ld a, c
    or a
    jr nz, .hit
    inc hl
    ld a, d
    add a, 5
    ld d, a
    jr .row
.hit:
    ld c, 0                     ; C = bit index
.bit:
    rra
    jr c, .found
    inc c
    jr .bit
.found:
    ld a, d
    add a, c                    ; A = matrix code
    ld b, e                     ; B = shift state
    ret
.none:
    ld b, e
    ld a, $FF
    ret

; Row-select bytes, matrix code base 0,5,10,...,35 in this order.
kbRows:
    db $FE                      ; 0:  CAPS Z X C V
    db $FD                      ; 5:  A S D F G
    db $FB                      ; 10: Q W E R T
    db $F7                      ; 15: 1 2 3 4 5
    db $EF                      ; 20: 0 9 8 7 6
    db $DF                      ; 25: P O I U Y
    db $BF                      ; 30: ENTER L K J H
    db $7F                      ; 35: SPACE SYM M N B
    db 0

; ASCII maps indexed by matrix code 0-39. 0 = no character (handled
; as an editing key or nothing).
kbMapPlain:
    db   0, 'z','x','c','v',  'a','s','d','f','g'
    db 'q','w','e','r','t',  '1','2','3','4','5'
    db '0','9','8','7','6',  'p','o','i','u','y'
    db  13, 'l','k','j','h',  ' ',  0, 'm','n','b'
kbMapCaps:                      ; caps: letters upper; digits/edit keys
    db   0, 'Z','X','C','V',  'A','S','D','F','G'
    db 'Q','W','E','R','T',  '1','2','3','4', 12  ; matrix 19 = Caps+5 cursor left
    db   8, '9', 11, 10, '6',  'P','O','I','U','Y' ; 20 BS, 22 right, 23 recall
    db  13, 'L','K','J','H',  ' ',  0, 'M','N','B'
kbMapSym:                       ; symbol shift: classic punctuation
    db   0, ':', 96, '?','/',  '~','|','\\','{','}'
    db   0,   0,   0, '<','>',  '!','@','#','$','%'
    db '_',')','(', 39, '&',  '"',';',   0,']','['
    db  13, '=','+','-','^',  ' ',  0, '.',',','*'

; kb_char: A = decoded character/control code, or 0 if nothing usable
; is pressed. New keys settle for 2 frames before the first emit so a
; chord's shift bit is always sampled together with the key (CSpect
; delivers PC Backspace as Caps+0 with the bits landing on different
; frames - emitting on first contact printed '0' from the plain map).
; Autorepeat: first emit after the settle, then 35-frame delay, then
; every 5 frames. Corrupts AF, BC, DE, HL.
kb_char:
    call kb_raw
    cp $FF
    jr nz, .down
    ld (inpRepKey), a           ; $FF = nothing held
    xor a
    ret
.down:
    ld c, a                     ; C = matrix code
    ld a, (inpRepKey)
    cp c
    jr z, .held
    ; new key: settle before the first emit
    ld a, c
    ld (inpRepKey), a
    ld a, 2
    ld (inpRepCnt), a
    ld a, 1
    ld (inpRepFirst), a
    ld a, (frameCounter)
    ld (inpRepFrm), a           ; seed the per-frame tick baseline
    xor a
    ret
.held:
    ld a, (frameCounter)
    ld e, a
    ld a, (inpRepFrm)
    cp e
    ld a, e
    ld (inpRepFrm), a
    jr z, .nochar               ; same frame: no new tick
    ld a, (inpRepCnt)
    dec a
    ld (inpRepCnt), a
    jr nz, .nochar
    ; counter expired: emit, then load the next interval
    ld a, (inpRepFirst)
    or a
    jr z, .rep
    xor a
    ld (inpRepFirst), a
    ld a, 35                    ; settle emit -> full repeat delay next
    jr .reload
.rep:
    ld a, 5                     ; repeating
.reload:
    ld (inpRepCnt), a
    jr .emit
.nochar:
    xor a
    ret
.emit:
    ; pick the map by shift state in B
    ld hl, kbMapPlain
    bit 1, b
    jr z, .notsym
    ld hl, kbMapSym
    jr .idx
.notsym:
    bit 0, b
    jr z, .idx
    ld hl, kbMapCaps
.idx:
    ld e, c
    ld d, 0
    add hl, de
    ld a, (hl)
    ret

; --- input line editor ---
; Edits inpLine in the current window from the current cursor position.
; Echo goes through prn_char with moreLock held (input never pages).
; Out: inpLine ASCIIZ, inpLen set; CF set = timeout fired (flag 49
; bit 7 set by the countdown). Corrupts everything.
inp_edit:
    xor a
    ld (inpLen), a
    ld (inpCur), a
    ld (inpLine), a
    ld a, 1                     ; locks BEFORE any echo, including the
    ld (moreLock), a            ; auto-recall below (Task 3 review
    ld (wrapLock), a            ; deferred edge, now load-bearing:
                                ; recalled echo must not word-buffer)
    ; auto-recall after timeout: flag 49 bit 5 requests it, bit 6 says
    ; preserved data exists (set when a timeout interrupted typing)
    ld a, (flags+FLAG_TIMECTL)
    and $60                     ; bits 6+5 both set?
    cp $60
    jr nz, .fresh
    call inp_recall_last        ; preload and echo inpLast
.fresh:
    ; timeout countdown init (0 = disarmed)
    ld hl, 0
    ld (inpTOFrames), hl
    ld a, (flags+FLAG_TIMEOUT)
    or a
    jr z, .loop
    call inp_to_load            ; HL = flag48*50 -> inpTOFrames
.loop:
    call inp_cursor_show
.wait:
    call kb_char
    or a
    jr nz, .key
    ; no key: timeout tick
    ld hl, (inpTOFrames)
    ld a, h
    or l
    jr z, .wait                 ; disarmed
    ; bit 0 of flag 49: timeout only while nothing typed
    ld a, (flags+FLAG_TIMECTL)
    bit 0, a
    jr z, .tick
    ld a, (inpLen)
    or a
    jr nz, .wait                ; typing started: hold the clock
.tick:
    ld a, (frameCounter)
    ld e, a
    ld a, (inpTOFrm)
    cp e
    jr z, .wait
    ld a, e
    ld (inpTOFrm), a
    ld hl, (inpTOFrames)
    dec hl
    ld (inpTOFrames), hl
    ld a, h
    or l
    jr nz, .wait
    ; timeout fired
    call inp_cursor_hide
    ld a, (flags+FLAG_TIMECTL)
    or $80                      ; bit 7: timeout occurred
    ld e, a
    ld a, (inpLen)
    or a
    jr z, .nopart
    set 6, e                    ; bit 6: data available for recall
    call inp_save_last          ; preserve the partial line
    jr .tofin
.nopart:
    res 6, e
.tofin:
    ld a, e
    ld (flags+FLAG_TIMECTL), a
    xor a
    ld (moreLock), a
    ld (wrapLock), a
    scf
    ret
.key:
    push af
    call inp_cursor_hide
    pop af
    cp 13
    jr z, .enter
    cp 8
    jr z, .bs
    cp 12
    jr z, .left
    cp 11
    jr z, .right
    cp 10
    jr z, .recall
    cp ' '
    jr c, .loop                 ; other controls: ignore
    ; printable: insert at cursor if room
    ld e, a
    ld a, (inpLen)
    cp INP_MAX
    jr nc, .loop
    call inp_insert             ; inserts E, redraws tail, len/cur++
    jp .loop
.bs:
    ld a, (inpCur)
    or a
    jp z, .loop
    call inp_delete             ; deletes left of cursor, redraws
    jp .loop
.left:
    ld a, (inpCur)
    or a
    jp z, .loop
    dec a
    ld (inpCur), a
    call inp_col_back
    jp .loop
.right:
    ld a, (inpCur)
    ld e, a
    ld a, (inpLen)
    cp e
    jp z, .loop
    ld a, e
    inc a
    ld (inpCur), a
    call inp_col_fwd
    jp .loop
.recall:
    call inp_clear_line         ; wipe echo + buffer
    call inp_recall_last
    jp .loop
.enter:
    call inp_save_last
    ld a, (flags+FLAG_TIMECTL)
    and $7F                     ; a submit clears the timeout bit
    ld (flags+FLAG_TIMECTL), a
    xor a
    ld (moreLock), a
    ld (wrapLock), a
    call win_newline            ; raw newline (moreLock off, single line safe)
    or a                        ; CF clear = normal submit
    ret

; Insert E at inpCur: shift the buffer tail right, echo E and the
; shifted tail, then reposition the window cursor after the new char.
inp_insert:
    ld a, (inpLen)
    ld c, a                     ; old length
    ld b, 0
    ld hl, inpLine
    add hl, bc                  ; HL -> old terminator
    ld a, (inpCur)
    ld d, a
    ld a, c
    sub d                       ; tail length = len - cur
    jr z, .attail
    inc a                       ; +1 so the terminator moves too (mid-line
    ld b, a                     ; insert must shift index cur..len)
.shift:                         ; move tail right by one, from the end
    ld a, (hl)
    inc hl
    ld (hl), a
    dec hl
    dec hl
    djnz .shift
    inc hl
.attail:
    ; write the char at inpLine+cur
    ld hl, inpLine
    ld a, (inpCur)
    ld c, a
    ld b, 0
    add hl, bc
    ld (hl), e
    ld a, (inpLen)
    inc a
    ld (inpLen), a
    ld hl, inpLine
    add hl, bc
    ld a, (inpLen)
    ; terminator
    push hl
    ld hl, inpLine
    ld e, a
    ld d, 0
    add hl, de
    ld (hl), 0
    pop hl
    ; echo from cursor position to end of line
    call inp_redraw_from_cur
    ld a, (inpCur)
    inc a
    ld (inpCur), a
    jp inp_place_cursor

; Delete the char left of inpCur: shift tail left, redraw tail plus a
; trailing space, reposition.
inp_delete:
    ld a, (inpCur)
    dec a
    ld (inpCur), a
    ld c, a
    ld b, 0
    ld hl, inpLine
    add hl, bc                  ; HL -> deletion point
.shl:
    inc hl
    ld a, (hl)
    dec hl
    ld (hl), a
    inc hl
    or a
    jr nz, .shl
    ld a, (inpLen)
    dec a
    ld (inpLen), a
    call inp_redraw_from_cur_sp ; redraw tail + one erasing space
    jp inp_place_cursor

; A = buffer index -> B = window row, C = window col of that index.
; row/col are window-relative (win_field coordinates), derived from
; inpStartX/Y plus the index, folded by the window width.
inp_cell_of:
    push af
    ld a, WIN_W
    call win_field
    ld e, (hl)                  ; E = window width
    pop af
    ld c, a
    ld a, (inpStartX)
    add a, c                    ; A = startX + index (max 127+79 < 256)
    ld b, 0
.fold:
    cp e
    jr c, .done
    sub e
    inc b
    jr .fold
.done:
    ld c, a                     ; col
    ld a, (inpStartY)
    add a, b
    ld b, a                     ; row
    ret

; Set the window cursor to inpCur's cell.
inp_place_cursor:
    ld a, (inpCur)
    call inp_cell_of
    push bc
    ld a, WIN_CURX
    call win_field
    pop bc
    ld (hl), c
    push bc
    ld a, WIN_CURY
    call win_field
    pop bc
    ld (hl), b
    ret

; Cursor left/right just re-place after inpCur changed - aliases.
inp_col_back:
inp_col_fwd:
    jp inp_place_cursor

; Echo inpLine[inpCur..end] from inpCur's cell, adjusting inpStartY if
; the echo scrolled the window at its bottom row.
inp_redraw_from_cur:
    call inp_place_cursor       ; window cursor -> inpCur cell
    ld a, (inpCur)
    ld c, a
    ld b, 0
    ld hl, inpLine
    add hl, bc                  ; HL -> inpLine[inpCur]
.echo:
    ld a, (hl)
    or a
    jr z, .echoed
    ld c, a
    push hl
    call prn_char               ; prints, may wrap/scroll
    pop hl
    inc hl
    jr .echo
.echoed:
    ; scroll adjust: projected end row (unclamped) - actual WIN_CURY.
    ; A scroll leaves WIN_CURY clamped below the projection; the
    ; difference is how many rows the line start moved up.
    ld a, (inpLen)
    call inp_cell_of            ; B = projected end row (win-rel)
    ld a, WIN_CURY
    call win_field              ; HL -> WIN_CURY; preserves BC
    ld a, b
    sub (hl)                    ; expected - actual
    ret z                       ; no scroll
    ret c                       ; guard: actual > expected (cannot happen)
    ld b, a                     ; B = scroll count
    ld a, (inpStartY)
    sub b
    ld (inpStartY), a
    ret

; inp_redraw_from_cur then one space to erase the vacated cell, then
; reposition the window cursor at inpCur.
inp_redraw_from_cur_sp:
    call inp_redraw_from_cur
    ld c, GLYPH_SPACE
    call prn_char
    jp inp_place_cursor

; Erase the echoed line and empty the buffer. Cursor ends at index 0.
inp_clear_line:
    xor a
    ld (inpCur), a
    call inp_place_cursor       ; window cursor -> start cell
    ld a, (inpLen)
    or a
    jr z, .zero
    ld b, a                     ; B = spaces to print
.sp:
    push bc
    ld c, GLYPH_SPACE
    call prn_char
    pop bc
    djnz .sp
.zero:
    xor a
    ld (inpCur), a
    call inp_place_cursor
    xor a
    ld (inpLen), a
    ld (inpLine), a
    ret

; Copy inpLast into inpLine, echo it whole, leave cursor at line end.
inp_recall_last:
    call inp_capture_start      ; anchor start to the window cursor
    ld hl, inpLast
    ld de, inpLine
    ld b, 0                     ; B = length
.cp:
    ld a, (hl)
    ld (de), a
    or a
    jr z, .done
    inc hl
    inc de
    inc b
    ld a, b
    cp INP_MAX
    jr c, .cp
    xor a
    ld (de), a                  ; hit max: force terminator
.done:
    ld a, b
    ld (inpLen), a
    xor a
    ld (inpCur), a              ; echo whole line from index 0
    call inp_redraw_from_cur
    ld a, (inpLen)
    ld (inpCur), a              ; cursor at line end
    jp inp_place_cursor

; Copy inpLine into inpLast when non-empty. Preserves DE (the timeout
; exit keeps its flag-49 value in E across this call).
inp_save_last:
    ld a, (inpLine)
    or a
    ret z                       ; empty: keep the previous recall line
    push de
    ld hl, inpLine
    ld de, inpLast
.cp:
    ld a, (hl)
    ld (de), a
    or a
    jr z, .done
    inc hl
    inc de
    jr .cp
.done:
    pop de
    ret

; Capture the current window cursor as the line origin (idempotent -
; both call sites run with the window cursor already at the origin).
inp_capture_start:
    ld a, WIN_CURX
    call win_field
    ld a, (hl)
    ld (inpStartX), a
    inc hl                      ; -> WIN_CURY
    ld a, (hl)
    ld (inpStartY), a
    ret

; Out: E = the window attribute with ink and paper swapped (the block
; cursor's inverted pair). Mirrors win_attr's paper*16+ink encoding
; with the roles swapped: ink drives the paper slot (masked to 0-7),
; paper drives the ink slot (0-15).
inp_attr_inv:
    ld a, WIN_PAPER
    call win_field
    ld a, (hl)                  ; paper -> ink slot
    and 15
    ld e, a
    ld a, WIN_INK
    call win_field
    ld a, (hl)                  ; ink -> paper slot
    and 7
    swapnib                     ; (ink&7) * 16
    add a, e                    ; pair = (ink&7)*16 + (paper&15)
    add a, a                    ; pair << 1
    ld e, a
    ret

; Draw / erase the block cursor at inpCur's screen cell.
inp_cursor_show:
    ld a, (inpLen)
    or a
    jr nz, .draw
    call inp_capture_start      ; fresh empty line: anchor the origin
.draw:
    call inp_attr_inv           ; E = inverted attr
    jr inp_cursor_put
inp_cursor_hide:
    call win_attr               ; E = normal attr
    ; fall through
; E = attribute. Renders the char under the cursor (or space at the
; line end) at inpCur's absolute screen cell.
inp_cursor_put:
    push de                     ; save attr in E
    ld a, (inpCur)
    call inp_cell_of            ; B = win row, C = win col
    ld hl, (curWin)
    ld a, (hl)                  ; window x
    add a, c
    ld c, a                     ; screen col
    inc hl
    ld a, (hl)                  ; window y
    add a, b
    ld b, a                     ; screen row
    ld a, (inpCur)              ; glyph = inpLine[inpCur] or space
    ld e, a
    ld d, 0
    ld hl, inpLine
    add hl, de
    ld a, (hl)
    or a
    jr nz, .g
    ld a, GLYPH_SPACE
.g:
    pop de                      ; E = attr
    call tm_putc_at             ; B row, C col, E attr, A glyph
    ret

; --- vocabulary ---
; In: inpWord = 5 chars, uppercase, space-padded, NUL at [5].
; Out: CF set = not found; else D = word id, E = word type.
; Vocab entries are 7 bytes: 5 chars stored 255-complemented (spaces
; pad short words), id, type. Table ends at raw byte 0.
voc_find:
    call data_save
    ld hl, (ddbHeader+HDR_VOCAB)
    call rd_seek
.entry:
    call rd_next
    or a
    jr z, .miss                 ; raw 0 = end of table
    ; compare 5 encoded chars against inpWord
    ld hl, inpWord
    ld b, 5
.cmp:
    cpl                         ; decode vocab char
    cp (hl)
    jr nz, .skip
    inc hl
    djnz .cmpnext
    jr .matched
.cmpnext:
    call rd_next
    jr .cmp
.skip:
    ; consume the rest of this entry: we have read (6-B) chars so far
    ; including the mismatch; read the remaining (B-1) chars + id + type
    ld a, b
    dec a
    add a, 2                    ; remaining chars + id + type
    ld b, a
.drain:
    call rd_next
    djnz .drain
    jr .entry
.matched:
    call rd_next
    ld d, a                     ; id
    call rd_next
    ld e, a                     ; type
    call data_restore
    or a
    ret
.miss:
    call data_restore
    scf
    ret

; Scan the ASCIIZ order at (inpPtr) for the next word: fills inpWord
; (5 chars uppercase space-padded), advances inpPtr past the word.
; Out: CF set = no more words (hit NUL or separator char); A = the
; terminator when CF set (0 or the separator). Separator chars end the
; ORDER, not just the word - inpPtr is left ON the separator (h_parse
; consumes it).
word_next:
    ld hl, (inpPtr)
.skipsp:
    ld a, (hl)
    or a
    jr z, .end
    cp ' '
    jr nz, .chk
    inc hl
    jr .skipsp
.chk:
    call is_separator
    jr z, .end
    ; start of a word: fill inpWord
    ld de, inpWord
    ld b, 5
.fill:
    ld a, (hl)
    or a
    jr z, .pad
    cp ' '
    jr z, .pad
    call is_separator
    jr z, .pad
    call to_upper
    ld (de), a
    inc de
    inc hl
    djnz .fill
    ; word longer than 5: consume the excess
.excess:
    ld a, (hl)
    or a
    jr z, .fin
    cp ' '
    jr z, .fin
    call is_separator
    jr z, .fin
    inc hl
    jr .excess
.pad:
    ld a, ' '
.padl:
    ld (de), a
    inc de
    djnz .padl
.fin:
    xor a
    ld (inpWord+5), a
    ld (inpPtr), hl
    or a                        ; CF clear: got a word
    ret
.end:
    ld (inpPtr), hl
    scf
    ret

; A = char: ZF set if order separator (. , ; :). Preserves A.
is_separator:
    cp '.'
    ret z
    cp ','
    ret z
    cp ';'
    ret z
    cp ':'
    ret

; A = char -> uppercase.
to_upper:
    cp 'a'
    ret c
    cp 'z'+1
    ret nc
    sub 32
    ret

; Copy inpLine to inpPending, replacing any whole word of vocabulary
; type 5 (conjunction) with '.'. Case is preserved for echo purposes;
; matching in word_next/voc_find uppercases as it goes.
; Corrupts AF, BC, DE, HL.
ingest_line:
    ld hl, inpLine
    ld de, inpPending
.copy:
    ld a, (hl)
    ldi                         ; copy byte, HL++, DE++
    or a
    jr nz, .copy
    ; conjunction pass: walk inpPending word by word; when voc_find
    ; says type 5, overwrite the word's chars in place with '.' + spaces
    ld hl, inpPending
    ld (inpPtr), hl
.scan:
    ld hl, (inpPtr)
    push hl                     ; word start candidate (pre-space skip)
    call word_next
    pop de
    jr nc, .word
    or a                        ; CF with A=0 is the NUL - done; any
    jr z, .done                 ; other terminator is a user separator:
    ld hl, (inpPtr)             ; step past it and keep scanning the
    inc hl                      ; rest of the line for conjunctions
    ld (inpPtr), hl
    jr .scan
.word:
    push de
    call voc_find
    ld a, e                     ; word type - read BEFORE the pop, which
    pop de                      ; restores the word-start pointer over
                                ; voc_find's returned DE
    jr c, .scan                 ; unknown word: leave it
    cp 5                        ; conjunction?
    jr nz, .scan
    ; overwrite: find the word start (skip spaces from DE), write '.'
    ; then spaces up to (inpPtr)
    ex de, hl
.sksp:
    ld a, (hl)
    cp ' '
    jr nz, .at
    inc hl
    jr .sksp
.at:
    ld (hl), '.'
    inc hl
.blank:
    push hl
    ld de, (inpPtr)
    or a
    sbc hl, de
    pop hl
    jr nc, .scan                ; reached the scan point
    ld (hl), ' '
    inc hl
    jr .blank
.done:
    ret

; Parse one order from (inpPtr) into the LS flags. Assumes flags were
; reset by the caller (h_parse). Out: nothing (flags speak).
parse_order:
    xor a
    ld (prnSeen), a             ; pronoun-in-sentence marker
.word:
    call word_next
    jp c, .post                 ; out of jr range
    call voc_find
    jr c, .word                 ; unknown word: skip
    ; slot-fill by type, first free slot only
    ld a, e
    or a
    jr z, .verb
    cp 2
    jr z, .noun
    cp 3
    jr z, .adj
    cp 4
    jr z, .prep
    cp 1
    jr z, .adv
    cp 6
    jr z, .pron
    jr .word                    ; conjunctions were neutralised; other
                                 ; types ignored
.verb:
    ld a, (flags+FLAG_VERB)
    inc a                       ; 255 -> 0?
    jr nz, .word
    ld a, d
    ld (flags+FLAG_VERB), a
    jr .word
.noun:
    ld a, (flags+FLAG_NOUN1)
    inc a
    jr nz, .noun2
    ld a, d
    ld (flags+FLAG_NOUN1), a
    jr .word
.noun2:
    ld a, (flags+FLAG_NOUN2)
    inc a
    jr nz, .word
    ld a, d
    ld (flags+FLAG_NOUN2), a
    jr .word
.adj:
    ld a, (flags+FLAG_ADJ1)
    inc a
    jr nz, .adj2
    ld a, d
    ld (flags+FLAG_ADJ1), a
    jr .word
.adj2:
    ld a, (flags+FLAG_ADJ2)
    inc a
    jr nz, .word
    ld a, d
    ld (flags+FLAG_ADJ2), a
    jr .word
.prep:
    ld a, (flags+FLAG_PREP)
    inc a
    jr nz, .word
    ld a, d
    ld (flags+FLAG_PREP), a
    jr .word
.adv:
    ld a, (flags+FLAG_ADVERB)
    inc a
    jr nz, .word
    ld a, d
    ld (flags+FLAG_ADVERB), a
    jr .word
.pron:
    ld a, (prnSeen)
    or a
    jr nz, .word                ; only the first pronoun acts
    inc a
    ld (prnSeen), a
    ld a, (flags+FLAG_NOUN1)
    inc a
    jp nz, .word                ; noun1 already set: pronoun ignored (jr range)
    ld a, (flags+FLAG_CPNOUN)
    ld (flags+FLAG_NOUN1), a
    ld a, (flags+FLAG_CPADJ)
    ld (flags+FLAG_ADJ1), a
    jp .word                    ; out of jr range
.post:
    ; 1. convertible noun: verb empty, noun1 < 20 -> verb = noun1
    ;    (noun1 keeps its value - both hold the same code)
    ld a, (flags+FLAG_VERB)
    inc a
    jr nz, .p2
    ld a, (flags+FLAG_NOUN1)
    cp 20
    jr nc, .p2
    ld (flags+FLAG_VERB), a
.p2:
    ; 2. previousVerb: order came from the buffer, verb empty,
    ;    noun1 present -> inherit
    ld a, (inpFromBuf)
    or a
    jr z, .p3
    ld a, (flags+FLAG_VERB)
    inc a
    jr nz, .p3
    ld a, (flags+FLAG_NOUN1)
    inc a
    jr z, .p3
    ld a, (prevVerb)
    ld (flags+FLAG_VERB), a
.p3:
    ; 3. late pronoun apply: noun1 still empty but a pronoun was seen
    ld a, (flags+FLAG_NOUN1)
    inc a
    jr nz, .p4
    ld a, (prnSeen)
    or a
    jr z, .p4
    ld a, (flags+FLAG_CPNOUN)
    inc a
    jr z, .p4
    dec a
    ld (flags+FLAG_NOUN1), a
    ld a, (flags+FLAG_CPADJ)
    ld (flags+FLAG_ADJ1), a
.p4:
    ; 4. pronoun memory update: real noun1 >= 50
    ld a, (flags+FLAG_NOUN1)
    inc a
    jr z, .p5
    dec a
    cp 50
    jr c, .p5
    ld (flags+FLAG_CPNOUN), a
    ld a, (flags+FLAG_ADJ1)
    ld (flags+FLAG_CPADJ), a
.p5:
    ; 5. previousVerb update (only when a verb is present)
    ld a, (flags+FLAG_VERB)
    inc a
    jr z, .p6
    dec a
    ld (prevVerb), a
.p6:
    ; 6. object-2 resolution when noun2 present - unconditional on the
    ; verb, matching jdaad/msx2daad (a verbless "lamp in box" order
    ; must still resolve flags 25-27/39-40)
    ld a, (flags+FLAG_NOUN2)
    inc a
    ret z
    jp obj2_resolve

; Resolve flags 44/45 to an object: flag 25 num, 26 container, 27 loc,
; 39/40 extended attributes (crossed order, as SETCO). Preference:
; pass 1 = objects present (carried, worn, or at the player's
; location); pass 2 = anywhere. Not found: 25/27 = 252, 26/39/40 = 0.
obj2_resolve:
    ld a, 1
    ld (o2Pass), a
    call .pass
    ret nc                      ; found in pass 1
    xor a
    ld (o2Pass), a
    call .pass
    ret nc
    ld a, 252
    ld (flags+FLAG_O2NUM), a
    ld (flags+FLAG_O2LOC), a
    xor a
    ld (flags+FLAG_O2CON), a
    ld (flags+FLAG_O2ATT), a
    ld (flags+FLAG_O2ATT+1), a
    ret
.pass:
    ld b, 0                     ; object number
.next:
    ld a, (numObj)
    cp b
    jr z, .miss
    ; HL -> objTable entry (6 bytes/obj): loc,attr,ext lo,ext hi,noun,adj
    push bc
    ld a, b
    ld l, a
    ld h, 0
    add hl, hl                  ; *2
    ld e, l
    ld d, h
    add hl, hl                  ; *4
    add hl, de                  ; *6
    ld de, objTable
    add hl, de
    pop bc
    push hl
    ld de, 4
    add hl, de
    ld a, (flags+FLAG_NOUN2)
    cp (hl)                     ; object noun match?
    jr nz, .no
    inc hl
    ld a, (hl)                  ; object adjective
    cp 255
    jr z, .adjok                ; object has no adjective: matches
    ld e, a
    ld a, (flags+FLAG_ADJ2)
    cp 255
    jr z, .adjok                ; player gave no adjective: matches
    cp e
    jr nz, .no
.adjok:
    ; presence filter on pass 1
    ld a, (o2Pass)
    or a
    jr z, .take
    pop hl
    push hl
    ld a, (hl)                  ; location
    cp OBJ_CARRIED
    jr z, .take
    cp OBJ_WORN
    jr z, .take
    ld e, a
    ld a, (flags+FLAG_PLAYER)
    cp e
    jr nz, .no
.take:
    pop hl
    ld a, b
    ld (flags+FLAG_O2NUM), a
    ld a, (hl)                  ; loc
    ld (flags+FLAG_O2LOC), a
    inc hl
    ld a, (hl)                  ; attribs
    and $40
    jr z, .ncon
    ld a, 128
.ncon:
    ld (flags+FLAG_O2CON), a
    inc hl
    ld a, (hl)                  ; extAttr first byte -> flag 39
    ld (flags+FLAG_O2ATT), a
    inc hl
    ld a, (hl)                  ; extAttr second byte -> flag 40
    ld (flags+FLAG_O2ATT+1), a
    or a                        ; CF clear = found
    ret
.no:
    pop hl
    inc b
    jr .next
.miss:
    scf
    ret

h_parse:                        ; 73: condition-like. B = option.
    ld a, b
    or a
    jr z, .p0
    ; PARSE 1+ (quoted strings): deferred - fail as condition + done
    call eng_set_done
    jp ovl1_false
.p0:
    ; pending buffer empty?
    ld a, (inpPending)
    or a
    jr nz, .frombuf
    ; fresh input: prompt, then edit
    xor a
    ld (inpFromBuf), a
    ld a, (flags+FLAG_PROMPT)
    or a
    jr nz, .fixed
    ld a, (frameCounter)
    and 3
    add a, 2                    ; SM2..SM5 (animated cursor prompt)
    jr .prompt
.fixed:
    ld e, a
    ld a, (ddbHeader+HDR_NUMSYS)
    cp e
    jr c, .prompt33             ; flag 42 out of range: skip it, still SM33
    jr z, .prompt33
    ld a, e
.prompt:
    ld e, a
    ld a, 0
    call print_msg
.prompt33:
    ; The classic DAAD input prompt is SM33 (jdaad getPlayerOrders ->
    ; readText). It prints on the SAME line as the input - no trailing
    ; newline. Rabenstein's SM33 is "#n>", so it supplies its own leading
    ; line break and the ">" the editor then types after. The old
    ; prn_newline here put input on a blank line below an empty SM2..5
    ; prompt, hiding the ">".
    ld a, (ddbHeader+HDR_NUMSYS)
    cp 34                       ; SM33 present only when numSys > 33
    jr c, .edit
    ld e, 33
    ld a, 0
    call print_msg
.edit:
    call inp_edit
    jr nc, .got
    ; timeout during input: PARSE PASSES (the entry remainder is the
    ; invalid-input/timeout handler; flag 49 bit 7 tells it why)
    jp ovl1_true
.got:
    ; post-edit input options (flag 49): bit 3 clear window,
    ; bit 4 reprint the line in the current stream
    ld a, (flags+FLAG_TIMECTL)
    bit 3, a
    jr z, .nocls
    call win_cls
.nocls:
    ld a, (flags+FLAG_TIMECTL)
    bit 4, a
    jr z, .noecho
    call inp_reprint            ; prn_char each inpLine char + newline
.noecho:
    call ingest_line
    ld hl, inpPending
    ld (inpPtr), hl
    jr .extract
.frombuf:
    ld a, 1
    ld (inpFromBuf), a
    ld hl, inpPending
    ld (inpPtr), hl
.extract:
    ; reset the LS flags
    ld a, 255
    ld (flags+FLAG_VERB), a
    ld (flags+FLAG_NOUN1), a
    ld (flags+FLAG_ADJ1), a
    ld (flags+FLAG_ADVERB), a
    ld (flags+FLAG_PREP), a
    ld (flags+FLAG_NOUN2), a
    ld (flags+FLAG_ADJ2), a
    call parse_order
    ; consume the trailing separator and compact inpPending to the
    ; remainder (the next order), so the next PARSE reads it
    call pending_compact
    ; DAAD PARSE condact semantics are INVERTED from the naive reading
    ; (jdaad _PARSE: condactResult = !result): a VALID logical sentence
    ; makes the condact FAIL - aborting the entry, whose remainder is
    ; the game's invalid-input handler - and marks done. No verb AND
    ; no noun1 -> the condact PASSES so that handler runs.
    ld a, (flags+FLAG_VERB)
    inc a
    jr nz, .valid
    ld a, (flags+FLAG_NOUN1)
    inc a
    jr nz, .valid
    jp ovl1_true                ; unparseable: run the entry remainder
.valid:
    call eng_set_done
    jp ovl1_false

; Shift the unconsumed remainder of inpPending (from inpPtr, skipping
; one leading separator and spaces) to the front of inpPending.
pending_compact:
    ld hl, (inpPtr)
    ld a, (hl)
    or a
    jr z, .empty
    call is_separator
    jr nz, .copy                ; safety: not on a separator
    inc hl
.copy:
    ld de, inpPending
.mv:
    ld a, (hl)
    ldi
    or a
    jr nz, .mv
    ret
.empty:
    xor a
    ld (inpPending), a
    ret

; Echo inpLine into the current window (flag 49 bit 4).
inp_reprint:
    ld hl, inpLine
.l:
    ld a, (hl)
    or a
    jp z, prn_newline
    push hl
    ld c, a
    call prn_char
    pop hl
    inc hl
    jr .l

; HL = flag48*50 -> inpTOFrames; seed the editor's frame baseline.
inp_to_load:
    ld a, (flags+FLAG_TIMEOUT)
    ld l, a
    ld h, 0
    add hl, hl                  ; *2
    push hl
    add hl, hl                  ; *4
    add hl, hl                  ; *8
    add hl, hl                  ; *16
    push hl
    add hl, hl                  ; *32
    pop de
    add hl, de                  ; *48
    pop de
    add hl, de                  ; *50
    ld (inpTOFrames), hl
    ld a, (frameCounter)
    ld (inpTOFrm), a
    ret

; --- SAVE / LOAD handlers ---
; Shared: prompt SM60, read a line, derive savName. Out: CF set = name
; error (SM59 already printed). Timeout suspended around the edit.
sav_prompt:
    ld a, (flags+FLAG_TIMEOUT)
    ld (savTimeStash), a
    xor a
    ld (flags+FLAG_TIMEOUT), a
    ld e, 60                    ; "Type in name of file."
    ld a, 0
    call print_msg
    call inp_edit               ; CF (timeout) impossible: flag 48 = 0
    ld a, (savTimeStash)
    ld (flags+FLAG_TIMEOUT), a
    call prn_reset_lines
    call sav_fname
    jr c, .fname_err
    call sav_fname_sanitize     ; A/C in = name length (1-8); makes the
                                 ; typed name filesystem-safe (see the
                                 ; routine below) so SAVE/LOAD never
                                 ; trip an esxDOS error on stray bytes
    or a                        ; CF clear: success (sanitize does not
    ret                         ; itself carry a fail contract)
.fname_err:
    ld e, 59                    ; "File name error."
    ld a, 0
    call print_msg
    call prn_newline
    scf                         ; prn_newline corrupts flags - re-assert
    ret                         ; the name-error CF for the caller

; Post-process savName's name field (written by sav_fname) toward the
; DAAD manual's SAVE opt wording: "this is not checked on 8 bit
; machines, the file name is MADE acceptable!" (DAAD_Manual_1991.md /
; DAAD_Ready_Documentation_V2.md) - the manual does not specify HOW,
; so: sav_fname already uppercases a-z and drops spaces; this maps
; every remaining non-alphanumeric byte to 'X'. Needed because
; sav_fname otherwise copies punctuation/control bytes into savName
; verbatim - a raw '.' typed mid-name would land ahead of the literal
; ".SAV" suffix appended below it (e.g. typing "my.sv!" would produce
; "MY.SV!.SAV", a malformed multi-dot 8.3 name) and other bytes may
; not be legal in an esxDOS/FAT filename at all, so an unsanitized
; SAVE could fail outright instead of just looking odd.
; In: A and C = name length (1-8), as sav_fname leaves them on return.
; savName[0..len-1] holds the space-dropped, letter-uppercased chars;
; the loop below never touches savName+len.. (the literal ".SAV",0
; sav_fname already appended there). Corrupts AF, B, HL.
sav_fname_sanitize:
    ld b, a
    ld hl, savName
.loop:
    ld a, (hl)
    cp '0'
    jr c, .bad                  ; < '0': control chars and punctuation
    cp '9'+1
    jr c, .ok                   ; '0'-'9': keep
    cp 'A'
    jr c, .bad                  ; ":;<=>?@": punctuation, keep out
    cp 'Z'+1
    jr nc, .bad                 ; > 'Z': punctuation/high-bit (no a-z
                                 ; survives - sav_fname uppercased it)
.ok:
    inc hl
    djnz .loop
    ret
.bad:
    ld (hl), 'X'
    inc hl
    djnz .loop
    ret

h_save:                         ; 25: condition-typed like LOAD; done
    call sav_prompt             ; set on every outcome (jdaad _SAVEB)
    jr c, .fail                 ; so the game's catch-all stays quiet;
    call sav_write              ; failure aborts the entry so SM59/57
    jr c, .ioerr                ; survive the game's redraw
    call sav_append_part        ; SP11 T4: v1 payload written - append
    jr nc, .ok                  ; curPart to make it v2 (see below)
.ioerr:
    ld e, 57                    ; "I/O Error"
    ld a, 0
    call print_msg
    call prn_newline
.fail:
    call eng_set_done
    jp ovl1_false
.ok:
    call eng_set_done
    jp ovl1_true

h_load:                         ; 26: condition-typed (cprops row 26).
                                ; sav_read_v2 is ATOMIC (staged commit),
                                ; so EVERY failure leaves the session
                                ; untouched: SM57 and fail the entry -
                                ; the game's redraw is skipped, the
                                ; error stays visible, play continues.
                                ; The manual's tape-era restart-on-
                                ; failure existed because a failed
                                ; physical load had already trashed
                                ; state; staging makes it obsolete.
                                ; SP11 T4: sav_read_v2 replaces sav_read
                                ; (resident file.asm, FROZEN - see its
                                ; own header comment below) with the
                                ; same CF contract, so this handler's
                                ; shape is otherwise unchanged. A cross-
                                ; part file hands off to switch_to_part
                                ; and never returns here at all on
                                ; success - "cross-part LOAD is a part-
                                ; entry, not a resume" (brief).
    call sav_prompt
    jr c, .fail                 ; name error: fail the entry
    call sav_read_v2
    jr nc, .ok
    ld e, 57
    ld a, 0
    call print_msg
    call prn_newline
.fail:
    call eng_set_done           ; done on every outcome (jdaad _LOADB)
    jp ovl1_false               ; abort the entry, session survives
.ok:
    call eng_set_done
    jp ovl1_true

; --- SP11 Task 4: part-aware SAVE/LOAD helpers -----------------------
; .SAV v2 = the v1 payload (unchanged byte-for-byte) + ONE trailing part
; byte. SAVE always writes v2 (sav_append_part). LOAD tells the format
; apart by length, not a version field: EOF right at the v1 payload's
; end is v1 (pre-Task-4 file) and is always current-part; one more byte
; present is v2's part number - equal to curPart, restore in place
; exactly like v1; different, hand off to switch_to_part (Task 3,
; overlay0.asm) for a fresh part entry (sav_read_v2). RAMSAVE/RAMLOAD
; fork identically (h_ramsave/h_ramload below) against a stored curPart
; snapshot instead of a file byte.
;
; sav_read_v2 cannot reuse the resident sav_read (file.asm, FROZEN -
; HARD RULES): sav_read rejects any file whose header numObj differs
; from the LIVE numObj as "wrong game" (error 3). Correct for same-part
; loads, but wrong for a legitimate v2 cross-part save, which by
; construction has a DIFFERENT numObj than whatever part is currently
; active (each part is its own DDB with its own object count) - the
; check would misfire on every genuine cross-part load. sav_read_v2
; reimplements the same staged, atomic read shape with the same
; resident primitives and the same resident scratch buffers sav_read
; itself uses (savRdHdr/savStage/savLocs, file.asm), but skips that
; gate and reads one extra byte past the payload to tell v1 from v2 -
; restoring the numObj-vs-live check ONLY on the same-part path (.v1
; below), where it is exactly as valid as it is in sav_read today.
;
; swapStage/swapObjCount (Task 3, overlay0.asm) live in the OVL0 page -
; this file's own header comment ("Calls RESIDENT services only - never
; overlay0") rules out writing them directly from here. The cross-part
; branch below stages into the resident savStage/savLocs instead (the
; same buffers the same-part path commits from) and hands off to a new
; overlay0 entry, xpart_load_entry, via the established trampoline idiom
; (push target, ld a,OVL0_PAGE, jp ovl_map_page - precedented by
; switch_to_part's own SFB re-probe hop into this overlay). That same
; entry also serves h_ramload's cross-part path, below, staged from
; ramSaveBuf instead.
ESX_MODE_WEXIST equ $02        ; F_OPEN: write, open EXISTING only (no
                                ; create, no truncate bit) - contrast
                                ; ESX_MODE_W ($0E, nextdaad.inc), which
                                ; always creates/truncates; reopening a
                                ; file sav_write just wrote must not
                                ; truncate it back to empty

; Reopen savName (just closed by sav_write) and append ONE byte: curPart.
; Seeks to the exact known payload end (6-byte header + 256 flags +
; numObj object-location bytes - the same layout sav_write itself just
; wrote) via F_SEEK (esxDOS API PDF: A=handle, BCDE=distance, IXL=whence
; 0=absolute) rather than any "append" open mode (esxDOS/NextZXOS has
; none outside the dot-command convenience layer this raw rst $08
; caller does not use - confirmed against the F_OPEN/F_SEEK entries in
; NextZXOS_and_esxDOS_APIs.odt). Out: CF clear = OK, CF set = io-error
; (mirrors sav_write's own A/CF contract so h_save's tail needs no
; special-casing between the two).
sav_append_part:
    call esx_getsetdrv
    jr c, .err
    ld ix, savName
    ld b, ESX_MODE_WEXIST
    call esx_fopen
    jr c, .err
    ld (savHandle), a
    ld a, (numObj)
    ld l, a
    ld h, 0
    ld de, 262                   ; 6 (header) + 256 (flags)
    add hl, de
    ex de, hl                    ; DE = seek target low word
    ld bc, 0                     ; BC = seek target high word (always 0:
                                  ; max 262+255=517)
    ld a, (savHandle)
    ld ix, 0                     ; IXL = esx_seek_set (absolute from
                                  ; start)
    call esx_fseek
    jr c, .errclose
    ld a, (savHandle)
    ld ix, curPart                ; write curPart's live resident byte
                                   ; directly - no local copy needed
    ld bc, 1
    call esx_fwrite
    jr c, .errclose
    ld a, (savHandle)
    call esx_fclose
    xor a
    ret
.errclose:
    ld a, (savHandle)
    call esx_fclose
.err:
    scf
    ret

sav_read_v2:
    call esx_getsetdrv
    jp c, .ioerr
    ld ix, savName
    ld b, ESX_MODE_READ
    call esx_fopen
    jp c, .ioerr                 ; not-found or any open error: h_load
                                  ; only tests CF, never the A code, so
                                  ; sav_read's own notfound-vs-ioerr
                                  ; split is not user-visible - one
                                  ; CF-set exit suffices here
    ld (savHandle), a
    ld a, (savHandle)
    ld ix, savRdHdr
    ld bc, 6
    call esx_fread
    jp c, .errclose
    ld hl, 6                     ; short/EOF header read: truncated or
    or a                         ; garbage file
    sbc hl, bc
    jp nz, .errclose
    ld hl, savHdr
    ld de, savRdHdr
    ld b, 5
.cmp:
    ld a, (de)
    cp (hl)
    jp nz, .errclose
    inc hl
    inc de
    djnz .cmp                    ; "NDSV",1 signature confirmed
    ld a, (savHandle)
    ld ix, savStage
    ld bc, 256
    call esx_fread
    jp c, .errclose
    ld hl, 256
    or a
    sbc hl, bc
    jp nz, .errclose
    ld a, (savRdHdr+5)           ; the FILE's own declared object count -
                                  ; NOT compared against live numObj here
                                  ; (see header comment above); .v1 below
                                  ; does that check, scoped to same-part
                                  ; only
    or a
    jr z, .objsdone              ; zero-object part: nothing to read
    ld ix, savLocs
    ld c, a
    ld b, 0
    ld a, (savHandle)
    call esx_fread
    jp c, .errclose
    ld a, (savRdHdr+5)
    ld h, 0
    ld l, a
    or a
    sbc hl, bc
    jp nz, .errclose
.objsdone:
    ld a, (savHandle)            ; probe for a trailing v2 part byte
    ld ix, savPartByte
    ld bc, 1
    call esx_fread
    jp c, .errclose
    ld a, b
    or c
    jp z, .v1                    ; EOF at exactly N bytes: v1 file
    ld a, (savPartByte)
    ld hl, curPart
    cp (hl)
    jp z, .v1                    ; v2, but same part: restore in place
    ; --- cross-part: close, payload already staged in savStage/
    ; savLocs above, hop to the shared overlay0 entry ---
    ld a, (savHandle)
    call esx_fclose
    ld hl, xpart_load_entry
    push hl
    ld hl, savStage
    ld ix, savLocs
    ld a, (savRdHdr+5)
    ld b, a
    ld a, (savPartByte)
    ld c, a
    ld a, OVL0_PAGE
    jp ovl_map_page               ; never returns here on success; on a
                                   ; cross-part probe failure,
                                   ; xpart_load_fail (below) hops back
                                   ; and lands on OUR caller (h_load)
                                   ; with CF set, exactly as if this
                                   ; call had failed directly
.v1:
    ld a, (savHandle)
    call esx_fclose
    ld a, (savRdHdr+5)            ; same-part safety net (mirrors
    ld hl, numObj                 ; sav_read's own numObj check exactly,
    cp (hl)                       ; scoped only to this path - see
    jp nz, .ioerr                 ; header comment above)
    ld hl, savStage
    ld de, flags
    ld bc, 256
    ldir
    call sav_scatter_locs         ; resident (file.asm); uses LIVE
                                   ; numObj, which the check just above
                                   ; proved equals the file's own count
    xor a
    ret
.errclose:
    ld a, (savHandle)
    call esx_fclose
.ioerr:
    scf
    ret

; Landing pad for a cross-part probe failure trampolined back from
; xpart_load_entry (overlay0.asm) - see its own header comment for the
; full reasoning. That trampoline hop already remapped MMU7 to
; OVL1_PAGE, so this plain scf/ret just re-asserts CF and returns to
; whichever of sav_read_v2/h_ramload's own stack frame is underneath -
; the hop into xpart_load_entry was a JP (no frame of its own); its
; CALL switch_to_part is what actually catches the failure and sends
; control back here, so the original caller's return address was never
; disturbed.
xpart_load_fail:
    scf
    ret

savPartByte: db 0

savTimeStash: db 0

h_ramsave:                      ; 62: flags + object locations -> buffer
    ld hl, flags
    ld de, ramSaveBuf
    ld bc, 256
    ldir                         ; DE left at ramSaveBuf+256
    ld hl, objTable
    ld a, (numObj)
    ld (ramSaveNObj), a          ; SP11 T4: snapshot's object count, for
                                  ; cross-part RAMLOAD's swapObjCount
                                  ; (xpart_load_entry, overlay0.asm)
    or a
    jr z, .mark
    ld b, a
.g:
    ld a, (hl)
    ld (de), a
    inc de
    add hl, OBJ_SIZE
    djnz .g
.mark:
    ld a, (curPart)
    ld (ramSavePart), a          ; SP11 T4: which part this snapshot
                                  ; belongs to - h_ramload forks on this
    ld a, 1
    ld (ramSaveOk), a
    ret

h_ramload:                      ; 63: restore locs + flags 0..B inclusive
    ld a, (ramSaveOk)
    or a
    ret z                       ; nothing saved: no-op
    ld a, (ramSavePart)          ; SP11 T4: fork on the snapshot's part
    ld hl, curPart
    cp (hl)
    jp nz, .xpart                ; stored part != current part
    ; object locations first (buffer offset 256)
    ld hl, ramSaveBuf+256
    ld de, objTable
    ld a, (numObj)
    or a
    jr z, .flags
    push bc                     ; preserve arg1 (B): .s below uses B as
                                 ; its own djnz counter
    ld b, a
.s:
    ld a, (hl)
    ld (de), a
    inc hl
    add de, OBJ_SIZE
    djnz .s
    pop bc                      ; restore the original arg1
.flags:
    ; flags 0..B inclusive = B+1 bytes (B=255 -> 256, no overflow)
    ld hl, ramSaveBuf
    ld de, flags
    ld c, b
    ld b, 0
    inc bc                      ; BC = arg1 + 1
    ldir
    ret
.xpart:
    ; SP11 T4: cross-part RAMLOAD. swapStage lives in the OVL0 page -
    ; this file's own header comment ("Calls RESIDENT services only -
    ; never overlay0") rules out writing it directly. Hand off to the
    ; same shared overlay0 entry sav_read_v2's cross-part path uses
    ; (xpart_load_entry, overlay0.asm), staged from ramSaveBuf instead
    ; of savStage/savLocs.
    ld hl, xpart_load_entry
    push hl
    ld hl, ramSaveBuf
    ld ix, ramSaveBuf+256
    ld a, (ramSaveNObj)
    ld b, a
    ld a, (ramSavePart)
    ld c, a
    ld a, OVL0_PAGE
    jp ovl_map_page               ; never returns here on success;
                                   ; RAMLOAD is action-typed (cprops row
                                   ; 63, $81) - no CF/message contract to
                                   ; a caller either way, so a bare
                                   ; landing back here on a probe
                                   ; failure (via xpart_load_fail) needs
                                   ; no special handling

ramSavePart: db 0
ramSaveNObj: db 0

; --- SFX / BEEP handlers (SP7 Task 4) -------------------------------
; Overlay1 cannot call bank-24 code (it owns slot 7), so both condacts
; file requests through the resident audRequest mailbox; aud_tick
; (ISR, bank mapped) performs the real work next frame. The only
; direct bank-24 access here is BYTE LOADING through slot-6 windows
; inside data_save brackets (aud_load_song / aud_load_sfb).

h_beep:                         ; 64: B = duration (cs), C = pitch
    ld a, c                     ; pitch must be even and 24..222
    and 1                       ; inclusive (jdaad pin: FREQ_TABLE has
    ret nz                      ; 100 notes, index (pitch-24)/2 = 0..99)
    ld a, c
    cp 24
    ret c
    cp 223
    ret nc
    ld a, b                     ; duration 0 = no-op
    or a
    ret z
    ld a, c
    sub 24
    srl a
    ld (audReqIdx), a           ; period table index 0..99
    ld a, b                     ; centiseconds -> frames at 50Hz:
    srl a                       ; (B+1)/2, minimum 1
    adc a, 0
    ld (audReqDur), a
    ld c, a                     ; C = frames for the wait below
    ld hl, audRequest
    set 0, (hl)
    ld a, 1
    ld (audEnable), a
    ld hl, (frameCounter)       ; block: target = now + frames + 1
    ld b, 0                     ; (the +1 covers the pickup frame)
    add hl, bc
    inc hl
    ld (bpTarget), hl
.wait:
    halt
    ld hl, (frameCounter)
    ld de, (bpTarget)
    or a
    sbc hl, de
    jr c, .wait
    ret

h_sfx:                          ; 18: B = n, C = sub-command
    ld a, c
    cp 1
    jr z, .smp1
    cp 2
    jr z, .smp2
    cp 3                        ; 3/4 behave as 1/2: DRF 0.40 cannot
    jr z, .smp1                 ; emit the DOS DB rate byte (spec,
    cp 4                        ; plan-time probe) - header rate plays
    jr z, .smp2
    cp 5
    jr z, .stopfx
    cp 6
    jr z, .playonce
    cp 7
    jr z, .playloop
    cp 8
    jr z, .stopmusic
 IFDEF DEBUG                    ; unknown sub-command: no-op with a
    push bc                     ; marker. Inline - overlay1 must NOT
    ld b, 30                    ; call overlay0's h_unimpl; the dbg_*
    ld c, 70                    ; helpers are resident and safe.
    call dbg_at
    ld hl, msgSfxUnk
    call dbg_puts
    ld a, (curCondact)
    call dbg_hex8
    pop bc
 ENDIF
    ret
.smp1:                          ; sample probe first, play once
    xor a
    jr .smp
.smp2:                          ; sample probe first, looped
    ld a, 1
.smp:
    ld (audReqSmpLoop), a
    ld a, b
    or a                        ; numbers are >= 1 (both kinds)
    ret z
    inc a                       ; n = 255 is reserved: it collides with
    jr z, .effect               ; smpLoadedNum's $FF "none" sentinel
                                ; (Task 3 review) - samples are 1-254,
                                ; 255 goes straight to the AY bank
    ld a, b
    push bc                     ; aud_load_wav corrupts BC (the WAV
    call aud_load_wav           ; filename decade-loop clobbers B
    pop bc                      ; before any exit path) - restore n for
                                ; the .effect fallback below. CF = no/
                                ; invalid NNN.WAV (pop bc leaves flags)
    jr c, .effect               ; -> AY effect fallback (SP7 path)
    ld hl, audRequest
    set 6, (hl)
    jr .enable
.effect:                        ; AY effect B on PSG 3 (SP7, loop only
    ld a, b                     ; if authored looping). Both entry
                                ; paths (the n=255 fallthrough, the
                                ; aud_load_wav CF-set jump) already
                                ; proved B >= 1 in .smp's shared check
                                ; above; the sfbCount guard below covers
                                ; the upper bound (Task 4).
    ld a, (sfbCount)
    cp b                        ; CF when count < n: out of range -
    ret c                       ; documented no-op (covers count 0)
    ld a, b
    ld (audReqSfx), a
    ld hl, audRequest
    set 1, (hl)
    jr .enable
.stopfx:                        ; stop WHICHEVER kind is active
    ld hl, audRequest
    set 2, (hl)                 ; AY effect
    set 7, (hl)                 ; sample
    ret                         ; audEnable already set if anything on
.stopmusic:
    ld hl, audRequest
    set 3, (hl)                 ; stop AKY music
    ld hl, audRequest2
    set 0, (hl)                 ; and stop an AYS stream (a stream and an
    ret                         ; AKY song never both play - one bit fires)
.playonce:
    xor a
    jr .load
.playloop:
    ld a, 1
.load:
    ld (audReq2Loop), a         ; stream loop flag (aud_load_ays consumes it)
    ld (audReqLoop), a          ; AKY loop flag (the fallthrough path below)
    push bc                     ; aud_load_ays corrupts BC - keep n for the
    ld a, b                     ; AKY fallback
    call aud_load_ays           ; probe NNN.AYS first; on success it has set
    pop bc                      ; audRequest2 bit 1 + audEnable already
    ret nc                      ; (pop bc leaves CF from aud_load_ays)
    ld a, b
    call aud_load_song          ; no/invalid AYS: existing AKY path (CF =
    ret c                       ; missing/oversized -> no-op)
    ld hl, audRequest
    set 4, (hl)
.enable:
    ld a, 1
    ld (audEnable), a
    ret

msgSfxUnk: db "SFX? ", 0

; --- song / effects-bank loaders ------------------------------------

; aud_load_song: A = song number ($FF = GAME.AKY). Loads NNN.AKY into
; AUD_SONG_ORG through slot-6 windows: the song area spans the tail of
; page 48 (bank offset $1800-$1FFF = file bytes 0-$7FF) and the first
; $1FE0 of page 49 (the state block owns the last 32 bytes). Overlay1
; runs from slot 7, so page 49 is mapped at slot 6 as well - the file
; streams in two windows. Music is stopped (request bit 3 + one-frame
; wait) BEFORE the song area is touched: a playing song must never be
; hot-swapped under the ISR. On success writes audSongNum, applies
; the play-once loop repoint when audReqLoop = 0, returns CF clear.
; CF set on any failure (missing file, oversize, read error) - the
; caller no-ops; a missing file leaves any playing music untouched
; (the open is probed before the stop). Corrupts everything.
aud_load_song:
    ld (audSongReq), a
    cp $FF
    jr nz, .num
    ld hl, audGameAky           ; "GAME.AKY"
    ld de, audName
    ld bc, 9
    ldir
    jr .open
.num:
    ; "NNN.AKY" - 3-digit zero-padded decimal, the project's
    ; repeated-subtraction decade idiom (see gfx_open_chain)
    ld hl, audName
    ld b, '0'-1
.hund:
    inc b
    sub 100
    jr nc, .hund
    add a, 100
    ld (hl), b
    inc hl
    ld b, '0'-1
.tens:
    inc b
    sub 10
    jr nc, .tens
    add a, 10
    ld (hl), b
    inc hl
    add a, '0'
    ld (hl), a
    inc hl
    ld de, audExtAky            ; ".AKY", 0
    ex de, hl
    ld bc, 5
    ldir
.open:
    call esx_getsetdrv
    jp c, .fail
    ld ix, audName
    ld b, ESX_MODE_READ
    call esx_fopen
    jp c, .fail                 ; missing: playing music untouched
    ld (audHandle), a
    ; stop the music before overwriting the song area - BOTH kinds:
    ; an AYS stream must not survive an AKY load (mutual exclusion is
    ; two-way; aud_load_ays mirrors this in the other direction).
    ; audEnable = 0 means the ISR never reaches aud_tick - nothing is
    ; playing and the requests would never be consumed, so skip the
    ; wait. res first: a pending not-yet-consumed start of the OLD
    ; song/stream must not fire mid-load (each set/res is a single
    ; instruction, atomic against the ISR).
    ld a, (audEnable)
    or a
    jr z, .stopped
    ld hl, audRequest
    res 4, (hl)
    set 3, (hl)
    ld hl, audRequest2
    res 1, (hl)
    set 0, (hl)
.waitstop:
    halt
    ld a, (audRequest)
    and %00001000
    jr nz, .waitstop
.waitstop2:
    halt
    ld a, (audRequest2)
    and %00000001
    jr nz, .waitstop2
.stopped:
    call data_save
    ; window 1: page 48, file bytes 0-$7FF at window offset $1800
    ld a, AUD_PAGE_LO
    call data_map_page
    ld a, (audHandle)
    ld ix, DATA_WINDOW+$1800
    ld bc, $0800
    call esx_fread
    jr c, .failclose
    ld (audLoaded), bc
    ld hl, $0800
    or a
    sbc hl, bc
    jr nz, .loaded              ; short read: whole file in
    ; window 2: page 49, up to $1FE0 bytes at window offset 0
    ld a, AUD_PAGE_HI
    call data_map_page
    ld a, (audHandle)
    ld ix, DATA_WINDOW
    ld bc, AUD_SONG_MAX-$0800
    call esx_fread
    jr c, .failclose
    ld hl, (audLoaded)
    add hl, bc
    ld (audLoaded), hl
    ld hl, AUD_SONG_MAX-$0800
    or a
    sbc hl, bc
    jr nz, .loaded
    ; capacity reached: any further byte means oversize
    ld a, (audHandle)
    ld ix, audProbe
    ld bc, 1
    call esx_fread
    jr c, .failclose
    ld a, b
    or c
    jr nz, .failclose           ; oversize: no state committed (music
                                ; already stopped, area inert)
.loaded:
    ld a, (audHandle)
    call esx_fclose
    ld hl, (audLoaded)          ; sanity: smaller than any header +
    ld de, 6                    ; terminator cannot be a song
    or a
    sbc hl, de
    jr c, .failpost
    ; the generated player is fixed 9-channel/3-PSG: any other export
    ; shape desyncs its linker read (it pops exactly 9 track pointers
    ; per entry) into garbage sound. Reject on the header's channel-
    ; count byte (file[1] - layout verified in the Task 4 report) via
    ; the page-48 window; same clean CF path as oversize, no partial
    ; state (music already stopped, area inert).
    ld a, AUD_PAGE_LO
    call data_map_page
    ld a, (DATA_WINDOW+$1801)
    cp 9
    jr nz, .failpost
    ; play-once: repoint the composer's loop at the terminal silence.
    ; CF back from the walk = no terminator inside the loaded bytes -
    ; a malformed/truncated file: REJECT the load (clean-fail
    ; discipline; done before audSongNum so a reject commits nothing)
    ld a, (audReqLoop)
    or a
    jr nz, .keeploop
    call aud_repoint_loop
    jr c, .failpost
.keeploop:
    ; record the song number in the bank state block (page 49 window)
    ld a, AUD_PAGE_HI
    call data_map_page
    ld a, (audSongReq)
    ld (DATA_WINDOW+audSongNum-$E000), a
    call data_restore
    or a
    ret
.failclose:
    ld a, (audHandle)
    call esx_fclose
.failpost:
    call data_restore
.fail:
    scf
    ret

; aud_load_sfb: GAME.SFB -> AUD_SFB_ORG (2K cap). The effects bank
; sits at page 48 bank offset $1000-$17FF, a single slot-6 window
; read. CF set on missing/oversize/read error. Corrupts everything.
aud_load_sfb:
    call esx_getsetdrv
    jr c, .fail
    ld ix, audGameSfb
    ld b, ESX_MODE_READ
    call esx_fopen
    jr c, .fail
    ld (audHandle), a
    call data_save
    ld a, AUD_PAGE_LO
    call data_map_page
    ld a, (audHandle)
    ld ix, DATA_WINDOW+$1000
    ld bc, $0800
    call esx_fread
    jr c, .failclose
    ld hl, $0800
    or a
    sbc hl, bc
    jr nz, .ok                  ; short read: fits
    ld a, (audHandle)           ; full 2K: an extra byte = oversize
    ld ix, audProbe
    ld bc, 1
    call esx_fread
    jr c, .failclose
    ld a, b
    or c
    jr nz, .failclose
.ok:
    ; effect count from the header: the SFB is a bare table of dw
    ; effect addresses, so table[0] - $D000 = table size = 2*count.
    ; Malformed first word (below $D002, odd, or above $D7FF) -> 0.
    ld hl, (DATA_WINDOW+$1000)  ; table[0] (bank offset $1000 = $D000)
    ld de, $D000
    or a
    sbc hl, de
    jr c, .badcnt
    ld a, h
    cp $08                      ; >= $0800: table exceeds the 2K bank
    jr nc, .badcnt
    bit 0, l
    jr nz, .badcnt              ; odd table size: malformed
    srl h
    rr l                        ; HL = count
    ld a, h
    or a
    jr nz, .badcnt              ; > 255: nonsense
    ld a, l
    ld (sfbCount), a
    jr .cntdone
.badcnt:
    xor a
    ld (sfbCount), a
.cntdone:
    ld a, (audHandle)
    call esx_fclose
    call data_restore
    or a
    ret
.failclose:
    ld a, (audHandle)
    call esx_fclose
    call data_restore
.fail:
    xor a
    ld (sfbCount), a            ; missing/rejected bank always reads 0
    scf
    ret

; --- play-once loop repoint -----------------------------------------

; Walk the loaded song's linker and point its terminal loop word at
; the bank's built-in silence pattern, so a play-once song ends in
; silence instead of restarting. Layout verified against real
; SongToAky binary exports (Task 4 report): file[0] = format byte,
; file[1] = channel count (3 per PSG), then 4 bytes per PSG; the
; linker follows at offset 2 + 4*psg as contiguous entries of
; dw duration + one dw track pointer per channel (stride 2 +
; 2*channels), terminated by dw 0 followed by the dw loop pointer.
; Export-shape-agnostic: header and stride are computed from the
; channel-count byte. Runs on the loaded RAM copy inside the load
; bracket (music stopped, page windows mapped per byte) - never on
; the SD file, never during playback. Out: CF clear = loop word
; patched; CF set = malformed file (bogus channel byte, offset past
; the loaded size, or no terminator inside it) - the caller rejects
; the load. Corrupts AF, BC, DE, HL.
aud_repoint_loop:
    ld hl, 0
    call aud_song_rdw           ; E = format byte, D = channel count
    ld a, d
    or a
    jr z, .bad
    cp 25                       ; stride byte tops out at 2+2*24
    jr nc, .bad
    ld c, a                     ; C = channels
    add a, a
    add a, 2
    ld (audStride), a           ; stride = 2 + 2*channels
    ld a, c                     ; psg = channels/3
    ld b, 0
.div3:
    sub 3
    jr c, .divdone
    inc b
    jr .div3
.divdone:
    ld a, b                     ; linker offset = 2 + 4*psg
    add a, a
    add a, a
    add a, 2
    ld l, a
    ld h, 0                     ; HL = linker file offset
.walk:
    ld de, (audLoaded)
    push hl
    ex de, hl                   ; HL = size, DE = offset
    or a
    sbc hl, de                  ; HL = size - offset
    pop de                      ; DE = offset
    ret c                       ; borrow: offset already PAST the end
                                ; (a negative difference would pass
                                ; the high-byte check below as room)
    ld a, h
    or a
    jr nz, .fits
    ld a, l                     ; fewer than 4 bytes left: truncated
    cp 4                        ; or malformed - CF back to the caller
    ret c
.fits:
    ex de, hl                   ; HL = offset
    call aud_song_rdw           ; DE = duration word (HL preserved)
    ld a, d
    or e
    jr z, .patch
    ld a, (audStride)
    add hl, a
    jr .walk
.patch:
    inc hl
    inc hl                      ; HL = file offset of the loop word
    ld de, audSilenceLinker     ; true bank address of the terminal
    call aud_song_wrw           ; silence linker entry (audiobank.asm)
    or a                        ; CF clear: patched
    ret
.bad:
    scf
    ret

; HL = song file offset -> HL = slot-6 window address of that byte,
; with the right page mapped. File bytes 0-$7FF live in page 48 at
; bank offset $1800; the rest in page 49 from its offset 0.
; Corrupts AF, DE.
aud_song_ptr:
    ld a, h
    cp $08
    jr nc, .hi
    ld a, AUD_PAGE_LO
    call data_map_page
    ld de, DATA_WINDOW+$1800
    add hl, de
    ret
.hi:
    ld a, AUD_PAGE_HI
    call data_map_page
    ld de, DATA_WINDOW-$0800
    add hl, de
    ret

; DE = word at song file offset HL (byte-wise: a word may straddle
; the page 48/49 boundary at offset $800). Preserves HL.
aud_song_rdw:
    push hl
    call aud_song_ptr
    ld a, (hl)
    ld (audWalkVal), a
    pop hl
    push hl
    inc hl
    call aud_song_ptr
    ld d, (hl)
    ld a, (audWalkVal)
    ld e, a
    pop hl
    ret

; Write word DE at song file offset HL (byte-wise, as above).
; Corrupts AF, DE, HL.
aud_song_wrw:
    ld (audWalkVal), de
    push hl
    call aud_song_ptr
    ld a, (audWalkVal)
    ld (hl), a
    pop hl
    inc hl
    call aud_song_ptr
    ld a, (audWalkVal+1)
    ld (hl), a
    ret

; --- boot autoplay probe --------------------------------------------

; Called once from main.asm at game takeover (overlay1 mapped by the
; caller). Resets the bank-24 audio state through the page-49 window
; (a warm re-entry must not resurrect stale flags or player state),
; then probes GAME.AKY (looped autoplay) and GAME.SFB (effects bank).
; Fail-silent on CF from either loader. Corrupts everything.
aud_boot_probe:
    call data_save
    ld a, AUD_PAGE_HI
    call data_map_page
    xor a
    ld (DATA_WINDOW+audFlags-$E000), a
    ld (DATA_WINDOW+audPlayerUp-$E000), a
    ld (DATA_WINDOW+smpFlags-$E000), a  ; clear a stale sample-active bit:
                                ; a looping sample must not replay a
                                ; recycled bank table after a warm boot
    ld a, $FF
    ld (DATA_WINDOW+audSongNum-$E000), a
    ld a, AUD_PAGE_LO           ; smpPageCnt/aysFlags/aysPageCnt live in page
    call data_map_page          ; 48 code space: a stale stream page count or
    xor a                       ; active bit must not survive a warm boot
    ld (smpPageCnt), a          ; (bank_table_init recycles the banks)
    ld (aysFlags), a            ; stream-active off (sibling of smpFlags)
    ld (aysPageCnt), a          ; stream page count cold
    call data_restore
    ld a, $FF
    ld (smpLoadedNum), a        ; keep-last cold on any (warm) boot
    xor a
    ld (sfbCount), a            ; 0 until aud_load_sfb below confirms it
    ld a, 1
    ld (audReq2Loop), a         ; boot stream loops
    ld (audReqLoop), a          ; boot music loops (GAME.AKY fallthrough)
    ld a, $FF                   ; $FF = GAME.AYS: streamed boot song, probed
    call aud_load_ays           ; BEFORE GAME.AKY. Success = stream autoplay
    jr nc, .nosong              ; (start bit + audEnable already set) and the
                                ; AKY probe is skipped - one boot song only
    ld a, $FF                   ; no GAME.AYS: fall through to GAME.AKY
    call aud_load_song
    jr c, .nosong
    ld hl, audRequest
    set 4, (hl)
    ld a, 1
    ld (audEnable), a
.nosong:
    call aud_load_sfb
    jr c, .title_chain
    ld hl, audRequest
    set 5, (hl)
    ld a, 1
    ld (audEnable), a
.title_chain:
    ; Boot title screen (SP11 Task 1): every exit of this routine funnels
    ; here (including the ret-c above) so a game with no music still gets
    ; its title - title art with no soundtrack is a normal shipping
    ; configuration, not a degraded one. Cannot inline "nextreg NR_MMU7,
    ; OVL2_PAGE" followed by a plain jp/ret here: this code is ITSELF
    ; executing from the $E000 window (OVL1_PAGE currently mapped at
    ; MMU7), so the moment the nextreg takes effect, the NEXT byte
    ; fetched at this same address range comes from OVL2_PAGE, not from
    ; whatever this file placed after the nextreg (the classic banked-Z80
    ; self-remap hazard - the same reason ovl_map_page is documented
    ; DISPATCHER/ISR ONLY and the engine dispatcher (engine.asm) always
    ; remaps from resident code before jumping into a handler, never the
    ; other way round). Fix: push the REAL target (title_boot, an overlay2
    ; address) as a fake return address, then jp into the resident
    ; ovl_map_page - its own "nextreg NR_MMU7,a / ret" runs entirely from
    ; resident memory (banks.asm, unaffected by the remap it just made),
    ; and its ret pops OUR pushed address, landing on title_boot with
    ; OVL2_PAGE already mapped. Stack-neutral overall: that ret consumes
    ; exactly the one extra word we pushed, leaving main's original
    ; return address on top for title_boot's own eventual ret. MMU7 left
    ; on OVL2 afterwards - harmless, the dispatcher remaps per condact.
    ld hl, title_boot
    push hl
    ld a, OVL2_PAGE
    jp ovl_map_page

audGameAky: db "GAME.AKY", 0
audGameSfb: db "GAME.SFB", 0
audGameAys: db "GAME.AYS", 0
audExtAky:  db ".AKY", 0
audExtAys:  db ".AYS", 0
audName:    ds 9
audHandle:  db 0
audSongReq: db 0
audLoaded:  dw 0                ; bytes of song actually loaded
audStride:  db 0                ; linker entry stride for the walk
audWalkVal: dw 0                ; word scratch for the split windows
audProbe:   db 0                ; oversize one-byte probe target
bpTarget:   dw 0                ; h_beep frameCounter target

; --- WAV sample loader (SP8) ----------------------------------------

; aud_load_wav: A = sample number (1-255). Probes NNN.WAV, validates
; RIFF/fmt (PCM, mono, 8-bit, rate 3500-20000), claims an allocated page
; list (floor banks 25-27 first, then the pool) via aud_banks_claim and
; streams the data payload into it through the slot-6 window, then
; derives the CTC control word + time constant from the header rate and
; the live video-timing mode. Keep-last: when A is already resident the SD
; read is skipped entirely (params persist in the audReqSmp* bytes). Any
; active sample is stopped (mailbox bit 7 + consumed-wait) and its banks
; released before the new claim - a playing sample must never be overwritten.
; Out: CF clear = payload resident + audReqSmpCtrl/Tc/Len/LenHi committed
; (audReqSmpLoop is the CALLER's, set before or after);
; CF set = missing/malformed/oversize/short-read. On any failure past the
; keep-last check the previous sample is stopped AND its banks released
; (smpPageCnt 0, no banks held); a missing file (open fails first) leaves
; the previous sample untouched.
; Corrupts everything.
aud_load_wav:
    ld (wavReqNum), a
    ; keep-last: same number already resident -> instant success, no
    ; SD touch, no stop (a replay restarts via aud_smp_start's state
    ; reinit; the old in-flight chunk tail is at most one frame)
    ld hl, smpLoadedNum
    cp (hl)
    jr nz, .load
    or a                        ; CF clear
    ret
.load:
    ; build "NNN.WAV" (decade idiom, same as aud_load_song)
    ld hl, audName
    ld b, '0'-1
.hund:
    inc b
    sub 100
    jr nc, .hund
    add a, 100
    ld (hl), b
    inc hl
    ld b, '0'-1
.tens:
    inc b
    sub 10
    jr nc, .tens
    add a, 10
    ld (hl), b
    inc hl
    add a, '0'
    ld (hl), a
    inc hl
    ld de, wavExt                ; ".WAV", 0
    ex de, hl
    ld bc, 5
    ldir
    call esx_getsetdrv
    jp c, .fail
    ld ix, audName
    ld b, ESX_MODE_READ
    call esx_fopen
    jp c, .fail                 ; missing: any playing sample untouched
                                 ; (open probed BEFORE the stop, same
                                 ; rule as aud_load_song)
    ld (audHandle), a
    ; stop any playing sample before the banks move under the DMA.
    ; audEnable = 0 means the ISR never reaches aud_tick: nothing can
    ; be playing and the bit would never be consumed - skip the wait.
    ld a, (audEnable)
    or a
    jr z, .stopped
    ld hl, audRequest
    res 6, (hl)                 ; a pending un-consumed start must not
    set 7, (hl)                 ; fire mid-load
.waitstop:
    halt
    ld a, (audRequest)
    and %10000000
    jr nz, .waitstop
.stopped:
    ld a, $FF
    ld (smpLoadedNum), a        ; loading invalidates the resident one
    ; release any previous sample's banks now that the engine is provably
    ; idle (the stop-wait consumed the stop, so the ISR is off the sample)
    ; and BEFORE the new claim - never while the ISR might walk them. page
    ; 48 into slot 6 for smpPageTab/smpPageCnt; slot 6 is free here.
    call data_save
    ld a, AUD_PAGE_LO
    call data_map_page
    ld hl, smpPageTab
    ld a, (smpPageCnt)
    ld b, a
    call aud_banks_release      ; safe on B=0 (first load); zeroes smpPageCnt
    call data_restore
    ; RIFF header: "RIFF" dd size "WAVE"
    ld ix, wavHdr
    ld bc, 12
    call .read
    jp c, .failclose
    ld hl, 12                   ; short read (EOF): BC untouched by
    or a                        ; esxDOS, stale wavHdr would re-validate
    sbc hl, bc                  ; forever - reject explicitly
    jp nz, .failclose
    ld hl, (wavHdr)             ; "RI"
    ld de, "IR"                  ; little-endian word: 'R','I'
    or a
    sbc hl, de
    jp nz, .failclose
    ld hl, (wavHdr+8)           ; "WA"
    ld de, "AW"
    or a
    sbc hl, de
    jp nz, .failclose
    xor a
    ld (wavGotFmt), a
.chunk:
    ; next chunk header: id(4) size(4)
    ld ix, wavHdr
    ld bc, 8
    call .read
    jp c, .failclose
    ld hl, 8                    ; short read (EOF): BC untouched by
    or a                        ; esxDOS, stale wavHdr would re-validate
    sbc hl, bc                  ; forever - reject explicitly
    jp nz, .failclose
    ld hl, (wavHdr)
    ld de, "mf"                  ; 'f','m' of "fmt "
    or a
    sbc hl, de
    jp nz, .notfmt               ; jr: out of range once the short-read
                                 ; checks above push .notfmt further away
    ld hl, (wavHdr+2)
    ld de, " t"                  ; 't',' '
    or a
    sbc hl, de
    jp nz, .notfmt
    ; fmt chunk: need at least 16 bytes; size high word must be 0
    ld hl, (wavHdr+6)
    ld a, h
    or l
    jp nz, .failclose
    ld hl, (wavHdr+4)
    ld de, 16
    or a
    sbc hl, de
    jp c, .failclose            ; fmt shorter than 16: malformed
    ld (wavSkip), hl            ; extra fmt bytes to discard after
    ld ix, wavFmt
    ld bc, 16
    call .read
    jp c, .failclose
    ld hl, 16                   ; short read (EOF): BC untouched by
    or a                        ; esxDOS, stale wavFmt would re-validate
    sbc hl, bc                  ; forever - reject explicitly
    jp nz, .failclose
    ld hl, (wavFmt)             ; wFormatTag
    dec hl                      ; == 1 (PCM)?
    ld a, h
    or l
    jp nz, .failclose
    ld hl, (wavFmt+2)           ; nChannels
    dec hl                      ; == 1 (mono)?
    ld a, h
    or l
    jp nz, .failclose
    ld hl, (wavFmt+6)           ; nSamplesPerSec high word
    ld a, h
    or l
    jp nz, .failclose
    ld a, (wavFmt+14)           ; wBitsPerSample low byte
    cp 8
    jp nz, .failclose
    ld a, (wavFmt+15)
    or a
    jp nz, .failclose
    ld hl, (wavFmt+4)           ; nSamplesPerSec low word = rate
    ld de, AUD_RATE_MIN
    or a
    sbc hl, de
    jp c, .failclose
    ld hl, (wavFmt+4)
    ld de, AUD_RATE_MAX+1
    or a
    sbc hl, de
    jp nc, .failclose
    ld a, 1
    ld (wavGotFmt), a
    ld hl, (wavSkip)            ; discard fmt tail (+ odd pad)
    jr .skipodd
.notfmt:
    ld hl, (wavHdr)
    ld de, "ad"                  ; 'd','a' of "data"
    or a
    sbc hl, de
    jr nz, .skip
    ld hl, (wavHdr+2)
    ld de, "at"                  ; 't','a'
    or a
    sbc hl, de
    jr nz, .skip
    ; data chunk: fmt must have come first (rate needed)
    ld a, (wavGotFmt)
    or a
    jp z, .failclose
    ; 32-bit data size: wavHdr+4 low word, wavHdr+6 high word. Reject the
    ; absurd top byte, then range-check the 24-bit size against AUD_SMP_MAX
    ; (the allocator is the real bound; this only rejects insane WAVs).
    ld a, (wavHdr+7)            ; size bits 24-31
    or a
    jp nz, .failclose          ; > 16MB: absurd
    ld hl, (wavHdr+4)          ; size bits 0-15
    ld a, (wavHdr+6)           ; size bits 16-23
    ld d, a
    or h
    or l
    jp z, .failclose           ; empty data: malformed
    ld a, d                    ; range: size <= AUD_SMP_MAX ($100000)
    cp AUD_SMP_MAX >> 16       ; high byte vs $10
    jr c, .datok               ; < $10: within the cap
    jp nz, .failclose          ; > $10: over the cap
    ld a, h                    ; == $10: low word must be zero
    or l
    jp nz, .failclose
.datok:
    ld (wavLen), hl            ; 24-bit payload length: low word
    ld a, d
    ld (wavLenHi), a           ; high byte
    jp .stream
.skip:
    ; unknown chunk: discard size (+ odd pad); reject a pathological
    ; >64K non-data chunk rather than loop for minutes
    ld hl, (wavHdr+6)
    ld a, h
    or l
    jp nz, .failclose
    ld hl, (wavHdr+4)
.skipodd:
    ; RIFF chunks are word-aligned: odd sizes carry one pad byte
    bit 0, l
    jr z, .skiploop
    inc hl
.skiploop:
    ld a, h
    or l
    jp z, .chunk
    ld de, 16
    or a
    sbc hl, de
    jr nc, .skip16
    add hl, de                  ; fewer than 16 left: read exactly HL
    ld b, h
    ld c, l
    ld hl, 0
    jr .skiprd
.skip16:
    ld bc, 16
.skiprd:
    push hl
    ld ix, wavHdr
    call .read
    pop hl
    jp c, .failclose
    jr .skiploop
.stream:
    ; claim an allocated page list for the 24-bit payload, then stream it
    ; window-by-window over smpPageTab. page 48 into slot 6 for the table
    ; writes: aud_banks_claim needs it mapped (it does not self-bracket).
    call data_save
    ld a, AUD_PAGE_LO
    call data_map_page
    ld a, (wavLenHi)            ; A:DE = 24-bit payload byte count
    ld de, (wavLen)
    ld hl, smpPageTab
    call aud_banks_claim
    jp c, .claimfail            ; allocation failed: nothing held
    ; init the 24-bit streaming counter and the table index
    ld hl, (wavLen)
    ld (wavRem), hl
    ld a, (wavLenHi)
    ld (wavRemHi), a
    xor a
    ld (wavIdx), a
.pageloop:
    ld hl, (wavRem)            ; 24-bit remaining == 0 -> done
    ld a, (wavRemHi)
    or h
    or l
    jr z, .streamed
    ; this window = min(remaining, $2000)
    ld a, (wavRemHi)
    or a
    jr nz, .fullwin            ; high byte set: remaining >= 64K > $2000
    ld hl, (wavRem)
    ld de, $2000
    or a
    sbc hl, de
    jr nc, .fullwin           ; remaining low word >= $2000
    ld hl, (wavRem)            ; partial final window: remLo bytes
    jr .setwin
.fullwin:
    ld hl, $2000
.setwin:
    ld (wavWin), hl
    ; source page = smpPageTab[wavIdx]: map page 48, read the entry
    ld a, AUD_PAGE_LO
    call data_map_page
    ld a, (wavIdx)
    ld e, a
    ld d, 0
    ld hl, smpPageTab
    add hl, de
    ld a, (hl)
    ; map that source page and read the window into the slot-6 window
    call data_map_page
    ld ix, DATA_WINDOW
    ld bc, (wavWin)
    call .read
    jp c, .failpost
    ; short read = truncated file (data chunk lied): reject
    ld hl, (wavWin)
    or a
    sbc hl, bc                 ; requested - actually read
    jp nz, .failpost
    ; DAC signedness: the WAV bytes are staged UNSIGNED, verbatim - no load-time
    ; transform. The CPU-OUT DAC path is unsigned on both silicon and CSpect, so
    ; one convention holds everywhere (full evidence at nextdaad.inc DAC_SILENCE).
    ; The retired -DDAC_CSPECT accommodation used to XOR $80 over every byte read
    ; into this window here; it is gone now that unsigned is empirically pinned.
    ; The ISR ring copy stays a plain move.
    ; advance: remaining -= wavWin (24-bit), step to the next table entry
    ld hl, (wavRem)
    ld bc, (wavWin)
    or a
    sbc hl, bc
    ld (wavRem), hl
    jr nc, .noborrow
    ld hl, wavRemHi
    dec (hl)
.noborrow:
    ld hl, wavIdx
    inc (hl)
    jp .pageloop
.streamed:
    call data_restore
    ld a, (audHandle)
    call esx_fclose
    ; commit: derive the CTC control word + time constant from the sample rate
    ; and the live video-timing mode, fill the mailbox, mark resident. The ring
    ; self-paces at the CTC rate, so no per-frame chunk sizing is needed.
    ld de, (wavFmt+4)           ; rate
    call aud_ctc_params         ; sets audReqSmpCtrl + audReqSmpTc
    ld hl, (wavLen)
    ld (audReqSmpLen), hl
    ld a, (wavLenHi)
    ld (audReqSmpLenHi), a
    ld a, (wavReqNum)
    ld (smpLoadedNum), a
    or a                        ; CF clear
    ret
.claimfail:
    ; allocation failed before any bank was held (aud_banks_claim unwound
    ; its own partial claim and left smpPageCnt 0). restore slot 6, fail.
    call data_restore
    jp .failclose
.failpost:
    ; SD error or short read after a successful claim: release the banks.
    ; slot 6 currently holds a source page (still inside the .stream
    ; data_save bracket); map page 48 for the release, then data_restore
    ; restores the caller's slot 6. Leaves smpPageCnt 0 (no banks held).
    ld a, AUD_PAGE_LO
    call data_map_page
    ld hl, smpPageTab
    ld a, (smpPageCnt)
    ld b, a
    call aud_banks_release
    call data_restore
.failclose:
    ld a, (audHandle)
    call esx_fclose
.fail:
    scf
    ret
; BC bytes from the open file into IX. Out CF = SD error; BC = bytes
; actually read (esx_fread contract). Preserves nothing else.
.read:
    ld a, (audHandle)
    jp esx_fread

; aud_ctc_params: DE = sample rate (validated AUD_RATE_MIN..MAX). Derives the
; CTC control word (audReqSmpCtrl) and time constant (audReqSmpTc) for the rate
; at the LIVE video-timing mode. The CTC input clock IS the FPGA system clock,
; 27-33 MHz by video mode (nextreg $11 bits 2:0), so a fixed constant would
; drift pitch across VGA/HDMI - aud_clk16_tab holds clock/16 per mode (like
; em00k CTCAudio's table). Prescaler /16 for rate >= clk16>>8 (the PER-MODE
; crossover where the /16 TC would reach 256); else /256 (TC = (clk16>>4)/rate).
; TC is floored and clamped to 255 (the boundary rate that divides to 256 lands
; on 255, a <0.5% nudge); residual error is <= one TC step, largest at low rates
; on fast clocks (see the hardware checklist). Corrupts AF,BC,HL; preserves DE.
aud_ctc_params:
    push de                     ; save the rate; nr_read takes the reg in E
    ld e, NR_VIDEO_TIMING
    call nr_read                ; A = nextreg $11 (IFF-preserving)
    and $07                     ; video timing mode 0-7 (7 = HDMI)
    ld l, a
    add a, a
    add a, l                    ; A = mode * 3 (3 bytes per clk16 entry)
    ld l, a
    ld h, 0
    ld bc, aud_clk16_tab
    add hl, bc                  ; HL -> clk16[mode] (24-bit little-endian)
    ld a, (hl)                  ; byte0 (low)
    inc hl
    ld b, (hl)                  ; byte1 (mid)
    inc hl
    ld c, (hl)                  ; byte2 (high) -> C = dividend high
    ld h, b
    ld l, a                     ; HL = clk16 low 16 bits; C:HL = clk16 (24-bit)
    pop de                      ; DE = rate
    ; per-mode crossover = clk16 >> 8 (the rate at which the /16 TC reaches 256).
    ; A fixed constant only holds for VGA0; on faster clocks (up to VGA6 33 MHz)
    ; a 6836 crossover would leave a band where /16 TC overflows 255 and clamps
    ; sharply (+18% on VGA6). clk16 is in C:HL, so clk16 >> 8 = C:H.
    push hl                     ; protect clk16 low word (restored after the test)
    ld l, h
    ld h, c                     ; HL = C:H = clk16 >> 8 = crossover
    or a
    sbc hl, de                  ; crossover - rate: CF (borrow) when rate > crossover
    pop hl                      ; restore clk16 low16 (C:HL = clk16 again)
    jr c, .p16                  ; rate > crossover -> /16
    jr z, .p16                  ; rate == crossover -> /16 (TC 256 -> clamps to 255)
    ld a, AUD_CTC_CW256         ; /256: control word + dividend = clk16 >> 4
    ld (audReqSmpCtrl), a
    srl c                       ; clk16 >> 4 (24-bit C:HL), four right shifts
    rr h
    rr l
    srl c
    rr h
    rr l
    srl c
    rr h
    rr l
    srl c
    rr h
    rr l
    jr .divide
.p16:
    ld a, AUD_CTC_CW16
    ld (audReqSmpCtrl), a
.divide:
    ; TC = C:HL / DE (floor, clamp 255). 24-bit repeated subtraction, B counts.
    ld b, 0
.sub:
    or a
    sbc hl, de
    jr nc, .ok
    dec c
    bit 7, c                    ; borrowed past zero: dividend exhausted
    jr nz, .done
.ok:
    inc b
    jr nz, .sub
    ld b, 255                   ; 256 rounds (rate 6836 only): clamp to 255
.done:
    ld a, b
    ld (audReqSmpTc), a
    ret

; clock/16 per video-timing mode (nextreg $11 bits 2:0), 24-bit little-endian.
; System clock from the Next hardware / em00k CTCAudio table; /16 folds the
; prescaler in so the /16-prescaler divide is a plain clk16/rate (and /256 is
; clk16>>4 / rate). VGA1/VGA2 clocks are non-integer/16 - floored here, matching
; em00k's own inexact entries for those two modes.
aud_clk16_tab:
    db $F0,$B3,$1A              ; VGA0 28000000/16 = 1750000
    db $72,$3F,$1B              ; VGA1 28571429/16 = 1785714
    db $6D,$19,$1C              ; VGA2 29464286/16 = 1841517
    db $38,$9C,$1C              ; VGA3 30000000/16 = 1875000
    db $8C,$90,$1D              ; VGA4 31000000/16 = 1937500
    db $80,$84,$1E              ; VGA5 32000000/16 = 2000000
    db $A4,$78,$1F              ; VGA6 33000000/16 = 2062500
    db $CC,$BF,$19              ; HDMI 27000000/16 = 1687500

; --- AYS streamed-song loader (SP10 client 2) -----------------------

; aud_load_ays: A = song number ($FF = GAME.AYS, else NNN.AYS). Probes/
; opens the file FIRST (a missing file leaves the current music
; untouched), then stops BOTH music kinds - files audRequest bit 3 (stop
; AKY song) AND audRequest2 bit 0 (stop stream) and halt-waits until BOTH
; are consumed (skipped when audEnable = 0: the ISR never ticks, so
; nothing plays and the bits would never clear). An AKY song and a stream
; never coexist, so the double stop-wait always terminates - at most one
; kind is ever actually playing, the other bit is consumed as a no-op on
; the same frame. Releases any previous stream claim, validates the
; 16-byte header (magic "AYS1", psgCount 1-3, loopOffset < streamLength),
; claims a page list for streamLength, streams the file in over those
; pages (a short read OR a trailing byte means the header streamLength
; disagrees with the file size -> reject), precomputes the loop position/
; remainder, commits aysLen/aysPsgs/aysLoop*, then files audRequest2 bit 1
; + audEnable (audReq2Loop is the CALLER's, set before this call).
; Out: CF clear = stream resident and its start filed; CF set =
; missing/malformed/oversize/short-read. Any failure PAST the claim
; releases the banks (aysPageCnt 0); a missing file (open fails first)
; leaves the previous stream untouched. Corrupts everything.
aud_load_ays:
    cp $FF
    jr nz, .num
    ld hl, audGameAys           ; "GAME.AYS"
    ld de, audName
    ld bc, 9
    ldir
    jr .open
.num:
    ld hl, audName              ; "NNN.AYS" - the 3-digit decade idiom
    ld b, '0'-1
.hund:
    inc b
    sub 100
    jr nc, .hund
    add a, 100
    ld (hl), b
    inc hl
    ld b, '0'-1
.tens:
    inc b
    sub 10
    jr nc, .tens
    add a, 10
    ld (hl), b
    inc hl
    add a, '0'
    ld (hl), a
    inc hl
    ld de, audExtAys            ; ".AYS", 0
    ex de, hl
    ld bc, 5
    ldir
.open:
    call esx_getsetdrv
    jp c, .fail
    ld ix, audName
    ld b, ESX_MODE_READ
    call esx_fopen
    jp c, .fail                 ; missing: current music untouched (open
                                ; probed BEFORE the stop, as aud_load_song)
    ld (audHandle), a
    ; stop BOTH music kinds before the banks move / the stream restarts.
    ; res the start bits first so a pending, not-yet-consumed start of the
    ; OLD music cannot fire mid-load.
    ld a, (audEnable)
    or a
    jr z, .stopped
    ld hl, audRequest
    res 4, (hl)                 ; drop a pending AKY start
    set 3, (hl)                 ; stop AKY music
    ld hl, audRequest2
    res 1, (hl)                 ; drop a pending stream start
    set 0, (hl)                 ; stop the stream
.waitstop:
    halt
    ld a, (audRequest)
    and %00001000               ; AKY stop still pending?
    jr nz, .waitstop
    ld a, (audRequest2)
    and %00000001               ; stream stop still pending?
    jr nz, .waitstop
.stopped:
    ; release any previous stream's banks now the engine is provably idle
    ; and BEFORE the new claim. page 48 into slot 6 for aysPageTab/Cnt.
    call data_save
    ld a, AUD_PAGE_LO
    call data_map_page
    ld hl, aysPageTab
    ld a, (aysPageCnt)
    ld b, a
    call aud_banks_release      ; safe on B=0 (first load); zeroes aysPageCnt
    call data_restore
    ; read + validate the 16-byte header (into overlay1 scratch)
    ld ix, aysHdr
    ld bc, 16
    call .read
    jp c, .failclose
    ld hl, 16
    or a
    sbc hl, bc
    jp nz, .failclose           ; short header: reject
    ld hl, (aysHdr)             ; magic "AYS1"
    ld de, "YA"                 ; 'A','Y' little-endian
    or a
    sbc hl, de
    jp nz, .failclose
    ld hl, (aysHdr+2)
    ld de, "1S"                 ; 'S','1' little-endian
    or a
    sbc hl, de
    jp nz, .failclose
    ld a, (aysHdr+4)            ; psgCount 1..3
    or a
    jp z, .failclose
    cp 4
    jp nc, .failclose
    ld (aysPsgTmp), a
    ld hl, (aysHdr+11)          ; streamLength (24-bit: +11 low word,
    ld (aysLenTmp), hl          ; +13 high byte)
    ld a, (aysHdr+13)
    ld (aysLenTmpHi), a
    or h
    or l
    jp z, .failclose            ; empty stream: malformed
    ld hl, (aysHdr+8)           ; loopOffset (24-bit: +8 low word, +10 high)
    ld (aysLoopTmp), hl
    ld a, (aysHdr+10)
    ld (aysLoopTmpHi), a
    ; loopOffset < streamLength (24-bit): loopOffset - streamLength must
    ; borrow, else the loop frame is at/past the end - reject.
    ld de, (aysLenTmp)
    or a
    sbc hl, de
    ld a, (aysLoopTmpHi)
    ld hl, aysLenTmpHi
    sbc a, (hl)
    jp nc, .failclose
    ; claim a page list for streamLength into aysPageTab
    call data_save
    ld a, AUD_PAGE_LO
    call data_map_page
    ld a, (aysLenTmpHi)         ; A:DE = 24-bit streamLength
    ld de, (aysLenTmp)
    ld hl, aysPageTab
    call aud_banks_claim
    jp c, .claimfail            ; alloc failed / > 1MB: nothing held
    ; stream the file in, 24-bit remaining counter, table index from 0
    ld hl, (aysLenTmp)
    ld (aysStrRem), hl
    ld a, (aysLenTmpHi)
    ld (aysStrRemHi), a
    xor a
    ld (aysStrIdx), a
.pageloop:
    ld hl, (aysStrRem)
    ld a, (aysStrRemHi)
    or h
    or l
    jr z, .streamed
    ld a, (aysStrRemHi)
    or a
    jr nz, .fullwin             ; high byte set: remaining >= 64K > $2000
    ld hl, (aysStrRem)
    ld de, $2000
    or a
    sbc hl, de
    jr nc, .fullwin
    ld hl, (aysStrRem)          ; partial final window
    jr .setwin
.fullwin:
    ld hl, $2000
.setwin:
    ld (aysStrWin), hl
    ld a, AUD_PAGE_LO           ; source page = aysPageTab[aysStrIdx]
    call data_map_page
    ld a, (aysStrIdx)
    ld e, a
    ld d, 0
    ld hl, aysPageTab
    add hl, de
    ld a, (hl)
    call data_map_page          ; map that page into slot 6
    ld ix, DATA_WINDOW
    ld bc, (aysStrWin)
    call .read
    jp c, .failpost
    ld hl, (aysStrWin)
    or a
    sbc hl, bc
    jp nz, .failpost            ; short read: file smaller than streamLength
    ld hl, (aysStrRem)          ; remaining -= window (24-bit)
    ld bc, (aysStrWin)
    or a
    sbc hl, bc
    ld (aysStrRem), hl
    jr nc, .noborrow
    ld hl, aysStrRemHi
    dec (hl)
.noborrow:
    ld hl, aysStrIdx
    inc (hl)
    jp .pageloop
.streamed:
    ; oversize check: exactly streamLength bytes must remain (streamLength
    ; == filesize-16). A trailing byte means the header lied - reject.
    ld a, AUD_PAGE_LO           ; a source page is in slot 6: map page 48 for
    call data_map_page          ; the probe target (and the commit below)
    ld a, (audHandle)
    ld ix, aysProbe
    ld bc, 1
    call esx_fread
    jp c, .failpost
    ld a, b
    or c
    jp nz, .failpost            ; trailing byte: oversize
    ; precompute the loop position + remainder into page-48 ays state
    ; (page 48 is in slot 6 now, so the ays* labels are addressable).
    ld hl, (aysLoopTmp)         ; inPage = loopOffset & $1FFF
    ld a, h
    and $1F
    ld h, a
    ld (aysLoopInPage), hl
    ld a, (aysLoopTmpHi)        ; idx = loopOffset >> 13 = (b2<<3)|(b1>>5)
    add a, a
    add a, a
    add a, a
    ld c, a                     ; b2 << 3
    ld a, (aysLoopTmp+1)        ; b1
    rlca
    rlca
    rlca
    and 7                       ; b1 >> 5
    or c
    ld (aysLoopIdx), a
    ld hl, (aysLenTmp)          ; aysLoopRem = streamLength - loopOffset
    ld de, (aysLoopTmp)
    or a
    sbc hl, de
    ld (aysLoopRem), hl
    ld a, (aysLenTmpHi)
    ld hl, aysLoopTmpHi
    sbc a, (hl)
    ld (aysLoopRemHi), a
    ld hl, (aysLenTmp)          ; commit aysLen + aysPsgs
    ld (aysLen), hl
    ld a, (aysLenTmpHi)
    ld (aysLenHi), a
    ld a, (aysPsgTmp)
    ld (aysPsgs), a
    call data_restore
    ld a, (audHandle)
    call esx_fclose
    ld hl, audRequest2          ; file the start (audReq2Loop was the
    set 1, (hl)                 ; caller's) and arm the ISR
    ld a, 1
    ld (audEnable), a
    or a                        ; CF clear
    ret
.claimfail:
    call data_restore
    jp .failclose
.failpost:
    ; failure after a successful claim: release the banks. slot 6 may hold
    ; a source page - map page 48 for the release, then restore slot 6.
    ld a, AUD_PAGE_LO
    call data_map_page
    ld hl, aysPageTab
    ld a, (aysPageCnt)
    ld b, a
    call aud_banks_release
    call data_restore
.failclose:
    ld a, (audHandle)
    call esx_fclose
.fail:
    scf
    ret
.read:
    ld a, (audHandle)
    jp esx_fread

; --- banked-stream allocation (SP10) --------------------------------
;
; PRECONDITION for both helpers: bank 24 page 48 (AUD_PAGE_LO) is mapped
; into slot 6. The page table and its count byte live there and the
; helpers do NOT bracket their own slot-6 mapping (so a caller can batch
; table access - aud_load_wav maps page 48 once per phase, aud_boot_probe
; likewise). Both write bankTable directly (resident, visible regardless
; of slot 6) and call bank_alloc/bank_free (also resident). Working
; storage is mainline-only scratch, so these are not ISR-safe; callers
; run them only with the sample engine idle.
;
; aud_banks_claim: A:DE = 24-bit byte count (A = bits 23-16). HL = page
; table base (smpPageTab or aysPageTab). Fills the table with 2 pages per
; claimed 16K bank - floor banks 25-27 first (BT_RESERVED -> BT_USED by
; direct table write, so bank_alloc can never hand them out twice), then
; the pool via bank_alloc. On success: CF clear, B = page count, and the
; count byte at (base + AUD_STRTAB_MAX) = B. On failure (pool exhausted,
; or more than AUD_STRTAB_MAX/2 banks): everything claimed so far is
; released (floor -> BT_RESERVED, pool -> bank_free), the count byte is
; zeroed, CF set. Corrupts everything.
aud_banks_claim:
    ld (smpClaimTab), hl        ; stash base for the fill and the count byte
    ; zero the count byte (base + AUD_STRTAB_MAX) up front: it then reads 0
    ; on EVERY failure return (cap-fail as well as the unwind), and only a
    ; successful fill overwrites it. Preserves A:DE (the byte count).
    ld bc, AUD_STRTAB_MAX
    add hl, bc
    ld (hl), 0
    ; --- 24-bit bytes -> bank count: ceil(bytes / 16384) ---
    ld hl, 16383
    add hl, de
    adc a, 0                    ; A:HL = bytes + 16383 (24-bit)
    ; banks = (A:HL) >> 14 = (A << 2) | (H >> 6)
    ld c, a                     ; C = high byte
    ld a, h
    rlca
    rlca
    and 3                       ; A = H >> 6 (0..3)
    ld b, a
    ld a, c
    add a, a
    add a, a                    ; A = high byte * 4
    add a, b                    ; A = bank count
    cp AUD_STRTAB_MAX/2 + 1     ; more than 64 banks (1MB)?
    jr nc, .capfail
    ld (smpClaimBanks), a       ; banks still to claim
    xor a
    ld (smpClaimPages), a       ; pages appended so far
    ld hl, (smpClaimTab)
    ld (smpClaimPtr), hl        ; table write pointer
    ; --- pass 1: floor banks 25-27, first-come across clients ---
    ld c, SMP_FLOOR_FIRST
.floorlp:
    ld a, (smpClaimBanks)
    or a
    jp z, .filled               ; all banks satisfied from the floor
    ld a, c
    cp SMP_FLOOR_LAST+1
    jr nc, .poollp              ; floor exhausted -> pool
    ld hl, bankTable
    ld b, 0
    add hl, bc                  ; HL -> bankTable[C] (B=0, so BC = C)
    ld a, (hl)
    cp BT_RESERVED
    jr nz, .floornext           ; already claimed by the other client: skip
    ld (hl), BT_USED            ; claim this floor bank
    ld a, c
    add a, a                    ; low page = bank * 2
    call .append
.floornext:
    inc c
    jr .floorlp
    ; --- pass 2: pool via bank_alloc ---
.poollp:
    ld a, (smpClaimBanks)
    or a
    jr z, .filled
    call bank_alloc
    jr c, .unwind               ; pool exhausted: release the partial claim
    add a, a                    ; low page = bank * 2
    call .append
    jr .poollp
.filled:
    ld a, (smpClaimPages)
    ld hl, (smpClaimTab)
    ld de, AUD_STRTAB_MAX
    add hl, de
    ld (hl), a                  ; count byte = page count
    ld b, a                     ; B = page count (contract)
    or a                        ; CF clear
    ret
.unwind:
    ld a, (smpClaimPages)
    ld b, a
    ld hl, (smpClaimTab)
    call aud_banks_release      ; frees the partial claim, zeroes the count
    scf
    ret
.capfail:
    scf                         ; too big: nothing claimed, count already 0
    ret
; append 2 pages (A = low page, A+1 = high page), advance the write
; pointer, count 2 pages, decrement banks-remaining. Preserves BC;
; corrupts AF, DE, HL.
.append:
    ld hl, (smpClaimPtr)
    ld (hl), a
    inc hl
    inc a
    ld (hl), a
    inc hl
    ld (smpClaimPtr), hl
    ld hl, smpClaimPages
    inc (hl)
    inc (hl)                    ; pages += 2
    ld hl, smpClaimBanks
    dec (hl)                    ; banks -= 1
    ret

; aud_banks_release: HL = page table base, B = page count. Frees every
; bank exactly once - pages come in pairs (bank*2, bank*2+1), so step by
; 2 and take bank = page/2: floor pages (50..55) back to BT_RESERVED, the
; rest via bank_free. Then zeroes the count byte at (base +
; AUD_STRTAB_MAX). Safe on B = 0. Corrupts AF, BC, DE, HL.
aud_banks_release:
    ld (smpRelTab), hl          ; stash base for the count-byte zero
    ld a, b
    or a
    jr z, .relcount             ; B = 0: nothing to free
    srl b                       ; B = bank count (pages / 2)
.rellp:
    ld a, (hl)                  ; low page of this bank
    inc hl
    inc hl                      ; step past the page pair
    push hl
    push bc
    cp SMP_FLOOR_FIRST*2
    jr c, .relpool              ; page < 50: pool bank
    cp (SMP_FLOOR_LAST+1)*2
    jr nc, .relpool             ; page >= 56: pool bank
    srl a                       ; floor bank = page / 2
    ld e, a
    ld d, 0
    ld hl, bankTable
    add hl, de
    ld (hl), BT_RESERVED        ; floor bank back to reserved, NOT free
    jr .relnext
.relpool:
    srl a                       ; pool bank = page / 2
    call bank_free
.relnext:
    pop bc
    pop hl
    djnz .rellp
.relcount:
    ld hl, (smpRelTab)
    ld de, AUD_STRTAB_MAX
    add hl, de
    ld (hl), 0                  ; count byte: no banks held
    ret

wavExt:    db ".WAV", 0
wavReqNum: db 0
wavGotFmt: db 0
wavLen:    dw 0                 ; payload length low word (24-bit)
wavLenHi:  db 0                 ; payload length high byte
wavRem:    dw 0                 ; streaming remaining, low word
wavRemHi:  db 0                 ; streaming remaining, high byte
wavIdx:    db 0                 ; current smpPageTab index while streaming
wavWin:    dw 0                 ; current window byte count
wavSkip:   dw 0
wavHdr:    ds 16                ; RIFF/chunk header + discard scratch
                                 ; (16, NOT 12: the skip loop reads up
                                 ; to 16 bytes here - a 12-byte buffer
                                 ; would overflow into wavFmt and
                                 ; clobber the captured rate)
wavFmt:    ds 16                ; fmt chunk body
smpClaimTab:   dw 0             ; aud_banks_claim: table base + count anchor
smpClaimPtr:   dw 0             ; aud_banks_claim: table write pointer
smpClaimBanks: db 0            ; aud_banks_claim: banks still to claim
smpClaimPages: db 0            ; aud_banks_claim: pages appended so far
smpRelTab:     dw 0            ; aud_banks_release: base for the count zero

; aud_load_ays scratch (overlay1 mainline data, slot 7). aysHdr is the
; 16-byte header buffer; the *Tmp values are staged here and committed to
; the page-48 ays state only after the whole load validates.
aysHdr:        ds 16           ; 16-byte AYS header
aysPsgTmp:     db 0            ; psgCount pending commit
aysLenTmp:     dw 0            ; streamLength low word (24-bit)
aysLenTmpHi:   db 0            ; streamLength high byte
aysLoopTmp:    dw 0            ; loopOffset low word (24-bit)
aysLoopTmpHi:  db 0            ; loopOffset high byte
aysStrRem:     dw 0            ; streaming remaining, low word
aysStrRemHi:   db 0            ; streaming remaining, high byte
aysStrIdx:     db 0            ; current aysPageTab index while streaming
aysStrWin:     dw 0            ; current window byte count
aysProbe:      db 0            ; oversize one-byte probe target

    DISPLAY "overlay1 ends at ", $, " headroom ", /D, OVL_LIMIT - $
    ASSERT $ <= OVL_LIMIT
