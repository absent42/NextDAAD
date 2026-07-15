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
; cursor's inverted pair). Mirrors win_attr's pair<<1 encoding.
inp_attr_inv:
    ld a, WIN_INK
    call win_field
    ld a, (hl)                  ; ink
    add a, a
    add a, a
    add a, a                    ; ink*8
    inc hl                      ; -> WIN_PAPER
    add a, (hl)                 ; ink*8 + paper
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
    jr c, .done
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
 IFDEF DEBUG
    ; parser diagnostic: LS <verb> <noun1> <last word scanned>, row 29
    ld b, 29
    ld c, 0
    call dbg_at
    ld hl, msgLsDbg
    call dbg_puts
    ld a, (flags+FLAG_VERB)
    call dbg_hex8
    call dbg_space
    ld a, (flags+FLAG_NOUN1)
    call dbg_hex8
    call dbg_space
    ld hl, inpWord
    call dbg_puts
 ENDIF
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

 IFDEF DEBUG
msgLsDbg: db "LS ", 0
 ENDIF

    ASSERT $ <= OVL_LIMIT
