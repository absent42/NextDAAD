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
    db   0, ':', 96, '?','/',  '~','|', 92, '{','}'  ; 92 = '\' (0x5C) as
                                 ; a decimal literal, NOT '\\' - sjasmplus
                                 ; expands a quoted '\\' into TWO bytes
                                 ; (5C 5C, a 2-char string), not one
                                 ; escaped backslash. That extra byte was
                                 ; the whole bug: kbMapSym assembled 41
                                 ; bytes instead of 40, shifting every
                                 ; entry from matrix 8 onward down by one
                                 ; physical position - kbMapSym[N] held
                                 ; the value meant for matrix N-1, for
                                 ; every symbol-shifted key from F onward
                                 ; (confirmed via build/nextdaad.sld: the
                                 ; table was 57547..57588 = 41 bytes, and
                                 ; the .lst dump showed "5C 5C" for this
                                 ; single db element). See 96/39 above/
                                 ; below for the SAME decimal-literal
                                 ; convention already used here for
                                 ; backtick/apostrophe - now applied
                                 ; consistently to backslash too.
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
    ; arm the CAPS+2 caps-lock toggle exactly once per fresh press (see
    ; .emit's CAPS+2 handling below for the consuming side and the
    ; audit note on why this combo is special-cased at all)
    xor a
    ld (capsLockArmed), a
    ld a, c
    cp 16
    jr nz, .noarm
    ld a, b
    and 3
    cp 1                         ; bit0 (caps) set, bit1 (sym) clear
    jr nz, .noarm
    ld a, 1
    ld (capsLockArmed), a
.noarm:
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
    ; CAPS+2 (matrix 16, CAPS held, SYM clear): the Next's dedicated
    ; CAPS LOCK key emits this combo electrically (classic Spectrum
    ; authority - CAPS SHIFT+2 = CAPS LOCK; confirmed against
    ; tools/tbblue/src/asm/KeyboardTester/KeyboardTester.asm's own
    ; keystopress combo table and the dev guide's keyboard chapter). It
    ; is a LOCK TOGGLE, never a character - kbMapCaps[16] literal '2'
    ; was the bug. capsLockArmed (input.asm, resident) is set once by
    ; the "new key" branch above and consumed here, so a long hold
    ; toggles exactly once rather than once per autorepeat tick.
    ld a, c
    cp 16
    jr nz, .notlock
    ld a, b
    and 3
    cp 1                         ; bit0 (caps) set, bit1 (sym) clear
    jr nz, .notlock
    ld a, (capsLockArmed)
    or a
    jr z, .locked                ; already consumed this hold: no-op
    xor a
    ld (capsLockArmed), a
    ld a, (capsLock)
    xor 1
    ld (capsLock), a
.locked:
    xor a
    ret
.notlock:
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
    ld a, c
    add hl, a                   ; Z80N ED 31: HL += C (unsigned); C is
                                 ; dead after this (rest of the routine
                                 ; reads only D/A) - SP14c OV1-3
    ld a, (hl)
    ; caps-lock (letters only, classic semantics - matches the classic
    ; ROM's k_decode_4 "C mode": forces upper-case letters regardless
    ; of the live CAPS SHIFT read, and touches nothing else). SYM-
    ; shifted chars and physically-CAPS-shifted chars (kbMapCaps, which
    ; already carries the correct case/edit-key value) are returned
    ; unmodified; only the plain-table, no-shift-held path can still be
    ; a lower-case letter that the lock should force upper-case.
    bit 1, b
    ret nz                        ; sym-shifted: return as looked up
    bit 0, b
    ret nz                        ; physical caps held: already correct
    ld d, a                       ; D = looked-up plain-table char
    cp 'a'
    jr c, .plain
    cp 'z'+1
    jr nc, .plain
    ld a, (capsLock)
    or a
    jr z, .plain
    ld a, d
    sub 32                        ; lowercase -> uppercase
    ret
.plain:
    ld a, d
    ret

 IFDEF DEBUG
; KTEST diagnostic (EXTERN 0 6, tests/test.dsf's KTEST verb - see
; overlay0.asm's extVec vector 6 / ktest_trampoline; DEBUG-only, no
; footprint in Release). Called once per engine step by the DSF's own
; PROCESS/REDO loop (PRO 9); draws:
;   - the 8 raw keyboard half-row bytes as binary (pressed=1, the TRUE
;     unmasked electrical state - unlike kb_raw's own masking, which
;     hides a held shift key's bit from its own row);
;   - the kb_raw-decoded matrix code and shift state (C/S bits);
;   - the kb_char-decoded character (hex + glyph if printable) - this
;     exercises the REAL production settle/repeat/decode path, so a
;     brief tap may show 0 until the 2-frame settle catches it, exactly
;     as real typing would;
;   - the capsLock state.
; All rendered natively via the resident dbg_* console (DAAD's own
; PRINT is decimal-only and cannot show binary/hex/glyphs). Exit:
; flags+130 is set to 1 when TRUE VIDEO (CAPS+3, matrix 17) is the
; currently-held key, 0 otherwise - the DSF checks this every pass and
; DONEs on nonzero. TRUE VIDEO is a deliberate two-key chord unlikely
; to be hit while sweeping single keys/combos (named as a safe exit
; choice in the owning task brief); it is excluded from live sweep by
; this choice, same trade-off the brief accepted.
;
; Register-liveness note (doc-13 rubric 1): dbg_putc/dbg_puts/dbg_hex8
; corrupt AF, BC, DE, HL (dbg_putc's own 8-row glyph copy uses B as an
; unconditional djnz counter). Every loop/state value this routine
; needs across a dbg_* call is therefore kept in memory (ktestIdx/
; ktestRowSel/ktestBits/ktestMatrix/ktestShift/ktestChar), never in a
; register held live across such a call. Corrupts everything.
ktest_poll:
    call dbg_cls
    ld b, 12                     ; rows 0-11 sit under the test game's
                                  ; location art (owner bench finding) -
                                  ; the whole readout lives at 12+
    call dbg_at0
    ld hl, ktestTitle
    call dbg_puts
    xor a
    ld (ktestIdx), a
.rowloop:
    ld a, (ktestIdx)
    cp 8
    jp z, .rowsdone
    add a, 16                    ; screen row = 16 + index (below the
                                  ; art + the latched readout rows)
    ld b, a
    call dbg_at0
    ld a, (ktestIdx)
    ld e, a
    ld d, 0
    ld hl, kbRows
    add hl, de
    ld a, (hl)
    ld (ktestRowSel), a
    call dbg_hex8                ; row-select byte identifies the row -
                                  ; see the report's row-name table
                                  ; (kbRows order); trimmed the on-
                                  ; screen name label here for overlay1
                                  ; budget (owner bench feedback task)
    ld a, ':'
    call dbg_putc
    ld a, ' '
    call dbg_putc
    ld a, (ktestRowSel)
    ld b, a
    ld c, $FE
    in a, (c)
    cpl
    and $1F
    ld (ktestBits), a
    ld a, (ktestBits)
    bit 0, a
    ld a, '0'
    jr z, .b0
    ld a, '1'
.b0: call dbg_putc
    ld a, (ktestBits)
    bit 1, a
    ld a, '0'
    jr z, .b1
    ld a, '1'
.b1: call dbg_putc
    ld a, (ktestBits)
    bit 2, a
    ld a, '0'
    jr z, .b2
    ld a, '1'
.b2: call dbg_putc
    ld a, (ktestBits)
    bit 3, a
    ld a, '0'
    jr z, .b3
    ld a, '1'
.b3: call dbg_putc
    ld a, (ktestBits)
    bit 4, a
    ld a, '0'
    jr z, .b4
    ld a, '1'
.b4: call dbg_putc
    ld a, (ktestIdx)
    inc a
    ld (ktestIdx), a
    jp .rowloop
.rowsdone:
    ; --- owner bench feedback (2026-07-22): the old level-triggered
    ; readout (kb_raw/kb_char re-read and re-printed every frame)
    ; flashed and cleared on release - unreadable at the bench. The
    ; decoded MATRIX/SHIFT/CHAR lines below now LATCH: they update
    ; only on a genuine NEW press (edge, not level), consume-on-press
    ; like capsLockArmed's own gate, and hold across release until the
    ; next press. The raw bit rows above stay live per the same
    ; feedback. A rolling 8-entry decoded-char history (hex, newest
    ; first) lets a typing sequence be reviewed after the fact.
    ;
    ; The decode below (.kdnl/.kdns/.kdix/.kdgot) is a deliberate,
    ; self-contained MIRROR of kb_char's own .notlock/.idx/letters-
    ; case-lock logic (overlay1.asm, same file) - NOT a shared call:
    ; kb_char's own settle timing (2 frames) would hide exactly the
    ; "pressed but not yet decoded" state this tool exists to show
    ; (e.g. the owner's reported comma/period/"!" symptom), and this
    ; task's own constraint is to touch nothing outside this KTEST
    ; block. kb_char is still called below for its REAL side effects
    ; (autorepeat bookkeeping, the actual capsLock toggle) - this
    ; mirror never writes capsLock itself.
    call kb_raw                  ; A = matrix ($FF none), B = shift (fresh every frame - feeds the LIVE exit check and the edge test)
    ld (ktestFreshM), a
    ld a, b
    ld (ktestFreshS), a
    ld a, (ktestFreshM)
    ld hl, ktestPrevM
    cp (hl)
    ld (hl), a
    jr z, .noedge
    cp $FF
    jr z, .noedge
    ld (ktestMatrix), a
    ld a, (ktestFreshS)
    ld (ktestShift), a
    ld a, (ktestMatrix)
    cp 16
    jr nz, .kdnl
    ld a, (ktestShift)
    and 3
    cp 1
    jr nz, .kdnl
    xor a
    jr .kdgot
.kdnl:
    ld a, (ktestShift)
    ld c, a
    ld hl, kbMapPlain
    bit 1, c
    jr z, .kdns
    ld hl, kbMapSym
    jr .kdix
.kdns:
    bit 0, c
    jr z, .kdix
    ld hl, kbMapCaps
.kdix:
    ld a, (ktestMatrix)
    ld e, a
    ld d, 0
    add hl, de
    ld a, (hl)
    bit 1, c
    jr nz, .kdgot
    bit 0, c
    jr nz, .kdgot
    cp 'a'
    jr c, .kdgot
    cp 'z'+1
    jr nc, .kdgot
    ld d, a
    ld a, (capsLock)
    or a
    jr z, .kdlo
    ld a, d
    sub 32
    jr .kdgot
.kdlo:
    ld a, d
.kdgot:
    ld (ktestChar), a
    ld hl, ktestHist+6
    ld de, ktestHist+7
    ld bc, 7
    lddr
    ld (ktestHist), a
.noedge:
    call kb_char                 ; real side effects only (autorepeat
                                  ; state, the actual capsLock toggle);
                                  ; return value unused for display
    ; --- decoded matrix code + shift state (row 13, LATCHED - rows
    ; 11-12 sit under the test game's location art; owner bench) ---
    ld b, 13
    call dbg_at0
    ld hl, ktestMatrixLbl
    call dbg_puts
    ld a, (ktestMatrix)
    call dbg_hex8
    ld a, ' '
    call dbg_putc
    ld hl, ktestShiftLbl
    call dbg_puts
    ld a, (ktestShift)
    call dbg_hex8
    ld hl, ktestCLbl
    call dbg_puts
    ld a, (ktestShift)
    bit 0, a
    ld a, '0'
    jr z, .cz
    ld a, '1'
.cz: call dbg_putc
    ld hl, ktestSLbl
    call dbg_puts
    ld a, (ktestShift)
    bit 1, a
    ld a, '0'
    jr z, .sz
    ld a, '1'
.sz: call dbg_putc
    ; --- decoded character (row 14, LATCHED) + caps-lock (live) ---
    ld b, 14
    call dbg_at0
    ld hl, ktestCharLbl
    call dbg_puts
    ld a, (ktestChar)
    call dbg_hex8
    ld a, ' '
    call dbg_putc
    ld a, "'"
    call dbg_putc
    ld a, (ktestChar)
    cp ' '
    jr c, .noglyph
    cp $7F
    jr nc, .noglyph
    call dbg_putc
    jr .glyphdone
.noglyph:
    ld a, '.'
    call dbg_putc
.glyphdone:
    ld a, "'"
    call dbg_putc
    ld hl, ktestLockLbl
    call dbg_puts
    ld a, (capsLock)
    add a, '0'
    call dbg_putc
    ; --- rolling last-8-decoded-chars history (row 15, hex, newest first) ---
    ld b, 15
    call dbg_at0
    ld hl, ktestHistLbl
    call dbg_puts
    xor a
    ld (ktestHi), a
.hloop:
    ld a, (ktestHi)
    cp 8
    jr z, .hdone
    ld e, a
    ld d, 0
    ld hl, ktestHist
    add hl, de
    ld a, (hl)
    call dbg_hex8
    ld a, ' '
    call dbg_putc
    ld a, (ktestHi)
    inc a
    ld (ktestHi), a
    jr .hloop
.hdone:
    ; --- exit check: TRUE VIDEO (CAPS+3, matrix 17) - LIVE (not
    ; latched), so leaving the tool never waits on an edge ---
    xor a
    ld (flags+130), a
    ld a, (ktestFreshM)
    cp 17
    jr nz, .noexit
    ld a, (ktestFreshS)
    and 3
    cp 1                          ; bit0 (caps) set, bit1 (sym) clear
    jr nz, .noexit
    ld a, 1
    ld (flags+130), a
.noexit:
    ret

ktestIdx:      db 0
ktestRowSel:   db 0
ktestBits:     db 0
ktestMatrix:   db 0              ; latched
ktestShift:    db 0              ; latched
ktestChar:     db 0              ; latched
ktestFreshM:   db 0              ; live, this frame only
ktestFreshS:   db 0              ; live, this frame only
ktestPrevM:    db $FF            ; edge-detect baseline
ktestHi:       db 0
ktestHist:     ds 8              ; rolling decoded-char history, newest first

ktestTitle:    db "KTEST keyboard matrix/decode - TRUE VIDEO to exit", 0
ktestMatrixLbl: db "MATRIX=", 0
ktestShiftLbl:  db " SHIFT=", 0
ktestCLbl:      db " C=", 0
ktestSLbl:      db " S=", 0
ktestCharLbl:   db "CHAR=", 0
ktestLockLbl:   db "  CAPSLOCK=", 0
ktestHistLbl:   db "HIST: ", 0
; Row-name labels (kbRows order: $FE=CZXCV $FD=ASDFG $FB=QWERT
; $F7=12345 $EF=09876 $DF=POIUY $BF=ELKJH $7F=_SMNB, bit0..4 left to
; right) were trimmed from the on-screen raw-bits rows for overlay1
; budget (owner bench feedback task) - the row-select hex byte alone
; identifies the row; see the report for the full table.
 ENDIF

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

; Out: E = the block cursor's inverted attribute - the pair with this
; window's ink and paper swapped. Resolved and cached per-window by
; win_attr_resolve (overlay0) whenever the colours change, so a window
; switch (e.g. inp_stream_push's flag-41 handling) picks up whichever
; window is current, not whichever window last set colours. Preserves D.
inp_attr_inv:
    ld a, WIN_ATTRINV
    call win_field
    ld e, (hl)
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
    ld hl, inpLine
    add hl, a                   ; Z80N ED 31: HL += A (unsigned) - gate
                                 ; follow-up, same class as OV1-3/OV1-4
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
    ; SP16 T6, V3: flag 53 bits 4 and 5 are recomputed per LOGICAL
    ; SENTENCE, not per input line - msx2daad clears them at the top of
    ; populateLogicalSentence for exactly that reason (PRP013 V3-02
    ; step 3), and parse_order is the routine that runs once per order.
    ; The three eng_* helpers are resident (engine.asm); overlay1 had 40
    ; bytes of headroom when this landed and could not hold the bodies.
    ld de, $00CF                ; OR 0, AND ~(F53_PREPFIRST|F53_UNRECWRD)
    call eng_v3f53
.word:
    call word_next
    jp c, .post                 ; out of jr range
    call voc_find
    jr nc, .known
    call eng_v3unrec            ; V3 bit 5: unrecognised word, and a
    jr .word                    ; verb already in the sentence
.known:
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
    call eng_v3prep             ; V3 bit 4: preposition before noun1
    jr .word
.adv:
    ld a, (flags+FLAG_ADVERB)
    inc a
    jr nz, .word
    ld a, d
    ld (flags+FLAG_ADVERB), a
    jp .word                    ; out of jr range (SP16 T6 pushed .word
.pron:                          ; back past the bit-5 arm)
    ld a, (prnSeen)
    or a
    jp nz, .word                ; only the first pronoun acts
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
    ; 1. convertible noun: verb empty, noun1 <= 39 -> verb = noun1
    ;    (noun1 keeps its value - both hold the same code)
    ;
    ; SP16 D2, SETTLED 2026-07-31 on the ORIGINAL ZX interpreter. This
    ; was 20 (following msx2daad's "id<20") against jdaad's "id<=39",
    ; and the two references could not settle it. The lineage this
    ; interpreter reimplements was asked directly: the fixture
    ; .superpowers/sdd/sp16-adjudications/zxadj.dsf, compiled for the
    ; classic 48K target and run against ASSETS/ZX/ZXSPECTRUM/
    ; DS48IE3.BIN under ZEsarUX, types bare nouns of id 19, 20, 25, 39,
    ; 40 and 60 and prints the resulting verb/noun flags:
    ;
    ;   19 -> V=19 N=19    39 -> V=39 N=39
    ;   20 -> V=20 N=20    40 -> V=255 N=40
    ;   25 -> V=25 N=25    60 -> V=255 N=60
    ;
    ; The boundary is exactly 39/40, i.e. jdaad's LAST_CONVERTIBLE_NOUN
    ; = 39, and msx2daad's "< 20" is the deviation. Full transcript:
    ; .superpowers/sdd/sp16-adjudications/zxadj-transcript.txt.
    ; Visible effect: bare nouns with ids 20-39 now act as commands, as
    ; they do on the machine this interpreter is a port of.
    ld a, (flags+FLAG_VERB)
    inc a
    jr nz, .p2
    ld a, (flags+FLAG_NOUN1)
    cp 40
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
; 39/40 extended attributes. SP16 A5 - the byte order is the DDB's,
; not an arbitrary convention: the extended attributes are ONE
; LITTLE-ENDIAN WORD in the file (drb.php generateObjectExtraAttr;
; compliance report Appendix A probe 4 - attribute 0 alone compiles
; to the bytes 01 00), so the FIRST file byte is the low byte, holding
; attributes 0-7, and it belongs in flag 40 (and flag 59 for the
; SETCO/current-object pair); the SECOND byte holds attributes 8-15
; and belongs in flag 39 (58). msx2daad states the same assignment
; outright: flags[fO2Att /*39*/] = extAttr2, flags[40] = extAttr1.
; eng_load_objects (engine.asm) already stores the pair in flag
; order - objTable+2 = attrs 8-15, +3 = attrs 0-7 - so the
; sequential copy below is correct and stays in step with
; obj_set_refs (overlay0.asm). Preference:
; pass 1 = objects present (carried, worn, or at the player's
; location); pass 2 = anywhere. Not found: 25/27 = 252, 26/39/40 = 0.
;
; SP16 D1 - matching rule, and how it relates to the Noun1 resolver.
; This one is LENIENT and stays that way: within a pass it takes the
; FIRST object whose noun matches and whose adjective is acceptable,
; where acceptable means the object's adjective is 255, or the player's
; adjective (flag 45) is 255, or the two are equal. There is no
; full-beats-partial preference - that is msx2daad's getObjectId rule
; (daad_objects.c:22) and it is what both references use for the second
; object. obj_find_pass (overlay0.asm) resolves Noun1 with jDAAD's
; stricter partial-match model, where a bare noun yields a PARTIAL that
; a later exact-adjective match overrides. The two therefore agree on
; every input for which a full match exists, and can differ only in
; which candidate a bare noun selects when several objects share it.
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
    ; HL -> objTable entry (6 bytes/obj): loc, attr, ext attrs 8-15,
    ; ext attrs 0-7 (flag order, see the header above), noun, adj
    ; SP14c OV1-1: Z80N MUL D,E for the *6 stride (was 3x ADD HL,HL/DE -
    ; the same shift-add pattern obj_ptr itself used before batch A's
    ; E4 fix; this routine never calls obj_ptr, so E4 never reached it)
    ; plus a bundled ADD HL,nn fold of the immediately-following +4.
    push bc
    ld d, 6
    ld e, b
    mul d, e                    ; Z80N: DE = 6*b = OBJ_SIZE*objnum
    ld hl, objTable
    add hl, de
    pop bc
    push hl
    add hl, 4                   ; Z80N ADD HL,nn
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
    ld a, (hl)                  ; objTable+2 = attrs 8-15 -> flag 39
    ld (flags+FLAG_O2ATT), a
    inc hl
    ld a, (hl)                  ; objTable+3 = attrs 0-7  -> flag 40
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
    jp nz, .quoted              ; PARSE 1+ (B21) lives past .valid
.p0:
    ; pending buffer empty?
    ld a, (inpPending)
    or a
    jr nz, .frombuf
    ; fresh input: prompt, then edit. SP16 B22 - the prompt and the
    ; edit both run in flag 41's window when that flag names one
    ; (jdaad calls PreserveStream BEFORE printing the prompt,
    ; jdaad.js:1352).
    call inp_stream_push
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
    ; invalid-input/timeout handler; flag 49 bit 7 tells it why). The
    ; stream still has to come back - jdaad's RestoreStream runs on the
    ; timeout path too. The two option bits do NOT run here; that is
    ; pre-existing behaviour and B22 leaves it alone.
    call inp_stream_pop
    jp ovl1_true
.got:
    ; post-edit input options (flag 49): bit 3 clear window,
    ; bit 4 reprint the line in the current stream.
    ; SP16 B22 - the ORDER here is jdaad's RestoreStream (jdaad.js:2316)
    ; and it is load-bearing: bit 3 clears the INPUT window (still
    ; selected), then the stream is restored, then bit 4 reprints into
    ; the window the game was using before the input. Neither bit's own
    ; behaviour changes.
    ld a, (flags+FLAG_TIMECTL)
    bit 3, a
    jr z, .nocls
    call win_cls
.nocls:
    call inp_stream_pop
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
    call quote_split            ; SP16 B21: lift any "..." out of the
                                 ; order into inpQuoted first
    call ls_reset
    call parse_order
    ; consume the trailing separator and compact inpPending to the
    ; remainder (the next order), so the next PARSE reads it
    call pending_compact
    ; DAAD PARSE condact semantics are INVERTED from the naive reading
    ; (jdaad _PARSE: condactResult = !result): a VALID logical sentence
    ; makes the condact FAIL - aborting the entry, whose remainder is
    ; the game's invalid-input handler - and marks done. No verb AND
    ; no noun1 -> the condact PASSES so that handler runs.
.verdict:
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
.quoted:
    ; SP16 B21 - PARSE 1+ re-runs the logical-sentence fill over the
    ; quoted section lifted from the order by quote_split. No prompt,
    ; no input, no pending_compact: inpPending's own cursor is not
    ; involved, so the buffered-orders chain is untouched.
    ;
    ; The rule below is MEASURED, not argued. The three references gave
    ; three different answers - jdaad's parseEnd ends
    ; "return result || (globalParseOption>0)" (jdaad.js:1548), so for
    ; it the verdict is pure EXISTENCE; msx2daad's useLiteralSentence
    ; returns whether ANY of the seven slots got filled - so the
    ; original ZX interpreter was asked, on the rig in
    ; .superpowers/sdd/sp16-adjudications/ (V/N are the sentence flags,
    ; QV/QN the markers that show which way the condition went: 254 =
    ; PARSE 1 PASSED, anything else = it FAILED; A is the adverb):
    ;
    ;   SAY FAST PLUGH  V=40  N=25  QV=254 A=55   no quotes: passes,
    ;                                             flags left alone
    ;   SAY ""          V=255 N=255 QV=254 A=255  empty quotes: flags
    ;                                             CLEARED, passes
    ;   SAY "ZZZZ"      V=255 N=255 QV=254 A=255  unknown words: same
    ;   SAY "FAST"      V=255 N=255 QV=254 A=55   adverb only: FILLED
    ;                                             the adverb, still passes
    ;   SAY "PLUGH"     V=25  N=25  QV=25        verb+noun: FAILS
    ;   SAY "N40"       V=255 N=40  QV=255       noun only: FAILS
    ;
    ; which is two rules, both simple:
    ;   - EXISTENCE decides whether the fill runs at all. No quoted
    ;     section and the sentence flags are not touched; a quoted
    ;     section, even an empty one, clears them first.
    ;   - CONTENT decides the condition, by exactly the test PARSE 0
    ;     already uses - verb or noun1 present. "SAY "FAST"" is the
    ;     discriminator: it demonstrably filled the adverb (A=55) and
    ;     still passed, so msx2daad's any-slot rule is out, and it
    ;     parsed nothing into verb/noun1 yet a quoted section existed,
    ;     so jdaad's existence rule is out too.
    ; Both references deviate; NextDAAD follows the machine it is a
    ; port of. Falling into .verdict is what implements the second rule.
    ld a, (inpQuoted)
    or a
    jp z, ovl1_true             ; no quoted section at all: flags stay
    ld hl, inpQuoted
    ld (inpPtr), hl
    call ls_reset
    call parse_order
    jr .verdict

; Reset the seven logical-sentence flags to NULLWORD. Shared by PARSE 0
; and PARSE 1 (jdaad parseEnd clears the same seven for both; the
; pronoun memory 46/47 is deliberately NOT among them - msx2daad
; PRP015 INC-02 and jdaad both persist it across sentences).
ls_reset:
    ld a, 255
    ld (flags+FLAG_VERB), a
    ld (flags+FLAG_NOUN1), a
    ld (flags+FLAG_ADJ1), a
    ld (flags+FLAG_ADVERB), a
    ld (flags+FLAG_PREP), a
    ld (flags+FLAG_NOUN2), a
    ld (flags+FLAG_ADJ2), a
    ret

; SP16 B21. Lift a quoted section out of the order at (inpPtr) into
; inpQuoted (ASCIIZ, empty when there is no quote), blanking it - both
; quote characters included - in the order itself so the REMAINDER
; still parses normally.
;
; The split follows msx2daad's parser() (daad_parser_sentences.c:55-62
; and 128-136), which switches the logical-sentence buffer on the
; opening quote and switches BACK on the closing one, so words after
; the closing quote keep feeding the normal sentence. jdaad's parseB
; (jdaad.js:1393-1397) instead truncates the order at the opening
; quote and throws the tail away; on `SAY "HELLO" LOUDLY` msx2daad
; still sees LOUDLY and jdaad does not. Blanking rather than
; truncating gives msx2daad's answer and costs nothing - the order's
; separator and terminator stay exactly where pending_compact expects
; them.
;
; The scan stops at an order separator, so the quoted section cannot
; run past the end of its own order. That matches both references,
; which split the input into orders BEFORE looking for quotes.
;
; No length guard is needed: the quoted section is a substring of one
; order inside inpPending (INP_MAX+1 bytes) minus at least the opening
; quote, and inpQuoted is INP_MAX+1 bytes, so it always fits.
; Corrupts AF, DE, HL.
quote_split:
    xor a
    ld (inpQuoted), a           ; default: this order quoted nothing
    ld hl, (inpPtr)
.scan:
    ld a, (hl)
    or a
    ret z                       ; end of input
    call is_separator
    ret z                       ; end of this order
    cp '"'
    jr z, .open
    inc hl
    jr .scan
.open:
    ld (hl), ' '                ; blank the opening quote
    inc hl
    ld de, inpQuoted
    ; A leading space, so that EMPTY quotes still leave inpQuoted
    ; non-empty and h_parse can tell `SAY ""` (a quoted section that
    ; happens to be empty) from `SAY JOHN` (no quoted section at all).
    ; The original ZX interpreter distinguishes them - measured, see
    ; h_parse's .quoted - and jdaad reaches the same end by forcing
    ; playerOrderQuoted to " " with the comment "Because original
    ; interpreters make a difference between 'SAY JOHN' and
    ; 'SAY JOHN \"\"'" (jdaad.js:1401). A leading space is free:
    ; word_next skips spaces before every word.
    ;
    ; It still fits. The quoted section is a substring of one order in
    ; inpPending (INP_MAX chars) minus at least the opening quote, so at
    ; most INP_MAX-1 characters; space + INP_MAX-1 + NUL = INP_MAX+1,
    ; exactly inpQuoted's size.
    ld a, ' '
    ld (de), a
    inc de
.copy:
    ld a, (hl)
    or a
    jr z, .fin                  ; unterminated quote: runs to the end
    call is_separator
    jr z, .fin                  ; unterminated quote: ends with the order
    ld (hl), ' '                ; this character leaves the order
    inc hl
    cp '"'
    jr z, .fin                  ; closing quote: blanked, not stored
    ld (de), a
    inc de
    jr .copy
.fin:
    xor a
    ld (de), a
    ret

; SP16 B22 - jdaad PreserveStream / RestoreStream (jdaad.js:2310-2325).
; The input editor runs in the window named by flag 41 when that flag
; names a real one, and the previously active window comes back
; afterwards. INPUT (condact 96, h_input above) already stored the
; stream in flag 41; only the switch was missing.
;
; What is deliberately NOT done: flag 63 (the current-window flag) is
; left alone. jdaad backs up windows.activeWindow and never touches
; the flag, so a game reading it during input still sees the window it
; selected with WINDOW. The stash below is that backup - it is the
; window POINTER rather than the number, so the restore cannot be
; thrown off by a game writing flag 63 directly while input is open.
; Corrupts AF, C, DE, HL (push); AF, DE, HL (pop).
inp_stream_push:
    ld hl, (curWin)
    ld (inpWinStash), hl
    ld a, (flags+FLAG_INPUTSTREAM)
    or a
    ret z                       ; 0 = no input stream selected
    cp WINDOW_COUNT
    ret nc                      ; out of range: ignored, as in jdaad
    ; Already the active window? Then do NOTHING, not even the flush -
    ; win_select flushes unconditionally (windows.asm), and jdaad's
    ; PreserveStream in this case is a bare assignment of a window to
    ; itself. Same defect class as the pop's guard below, opposite end:
    ; a flush the engine never used to perform, on a path where nothing
    ; actually moves.
    ld c, a                     ; C = window number; it has to survive the
    ld d, WIN_SIZE              ; compare, and a push/pop AF would restore
    ld e, a                     ; F and throw the compare's own Z away
    mul d, e                    ; Z80N: DE = WIN_SIZE * window number
    ld hl, winTable
    add hl, de
    ld de, (inpWinStash)
    or a                        ; CF clear for the sbc (A is still the
    sbc hl, de                  ; window number here, non-zero, unchanged)
    ret z                       ; flag 41 names the window already active
    ld a, c
    jp win_select               ; flushes the old window's pending word
inp_stream_pop:
    ld hl, (curWin)
    ld de, (inpWinStash)
    or a
    sbc hl, de
    ret z                       ; push did not switch (flag 41 clear or
                                 ; out of range) - do NOTHING, not even
                                 ; the flush. A flush here on the common
                                 ; no-INPUT path would emit a pending
                                 ; wrapped word at a moment the engine
                                 ; never used to, changing output for
                                 ; every game that never calls INPUT.
    call prn_flush              ; win_select's flush, done by hand
    ld hl, (inpWinStash)        ; because the target is a pointer
    ld (curWin), hl
    ret

inpWinStash: dw winTable

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
; SP14c OV1-2: Z80N MUL D,E replaces the 6-step shift/push/add chain -
; same idiom as batch B's PRN1 (print.asm's wait_key_timeout), which
; computes the identical flag48*50 quantity at a different call site.
inp_to_load:
    ld a, (flags+FLAG_TIMEOUT)
    ld e, a
    ld d, 50
    mul d, e                    ; Z80N: DE = flag48*50
    ex de, hl                   ; HL = product
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
    call sav_write_v2           ; SP11 T4 fix: single-pass v2 write -
    jr nc, .ok                  ; failure aborts the entry so SM59/57
    ld e, 57                    ; "I/O Error"          survive the redraw
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
    xor a                       ; same-part LOAD clears the transient
    ld (gfxDrawTarget), a       ; GFX 87/4 draw-target state (cross-
    ld (gfxRevealPend), a       ; part goes through eng_init_game via
    ld (gfxRevealMode), a       ; switch_to_part instead)
    call eng_set_done
    jp ovl1_true

; --- SP11 Task 4: part-aware SAVE/LOAD helpers -----------------------
; .SAV v2 = the v1 payload (unchanged byte-for-byte) + ONE trailing part
; byte. SAVE always writes v2 (sav_write_v2). LOAD tells the format
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

; sav_write_v2 REPLACES an earlier append-after-close shape (owner
; CSpect sweep evidence: every SAVE reported OK, but PT.SAV/T1.SAV/
; MYXSV.SAV were all landing at exactly the v1 size - 265/266 bytes,
; never 266/267 - the trailing byte was silently never written).
; Investigation (instruction-by-instruction re-read of the committed
; append routine, since removed): the byte count WAS correctly reloaded
; to BC=1 immediately before the esx_fwrite that followed the F_SEEK -
; no register-reuse bug, contrary to the first suspicion. A, IX, and
; the F_OPEN mode ($02: write + open-existing, confirmed against
; NextZXOS_and_esxDOS_APIs.odt's F_OPEN entry as a valid, well-formed
; combination) were all correct too. But F_WRITE's own documented exit
; contract ("Exit (success): Fc=0; BC=bytes actually written" - no
; short-write exemption stated, unlike F_READ's explicit "EOF is not an
; error, check BC" note) was never checked against the requested count
; - the routine trusted CF alone, exactly as sav_write itself does for
; its own (proven-reliable, sequential-from-open) writes. Verdict: a
; write that seeks to the exact current end of an already-open,
; non-created handle and asks it to grow the file by one byte can
; return Fc=0 with BC=0 (silent short write); whether that is a CSpect
; esxDOS-emulation gap in extending mode-$02 handles past their
; original EOF, or a genuine esxDOS/FatFS characteristic that would
; reproduce on real hardware too, could not be determined without
; hardware access - either way it is a real hazard in the seek-then-
; extend shape, not something worth re-proving with a BC check bolted
; onto the same shape.
;
; Fix: eliminate the shape entirely - write the trailing byte as a
; fourth sequential esx_fwrite inside sav_write's own single open/
; create/truncate/close session (mirrors sav_read_v2's own "reimplement
; on the resident primitives" precedent), the exact same call shape as
; the header/flags/objects writes immediately before it, which the
; owner's own evidence proves already write reliably. No second open,
; no seek, no write-extend edge case. sav_write (file.asm, resident,
; FROZEN) and the former sav_append_part are both now unreachable from
; h_save - sav_write cannot be removed (frozen), and sav_append_part's
; code was deleted rather than left in place (leaving 350+ dead-and-
; buggy-in-spirit bytes in an already-tight overlay budget serves no
; one); this comment is the record of the removal.
;
; Post-fix hardening (owner-approved pre-tag review): CF alone is not
; sufficient either - the SAME root-cause lesson applies to every write
; here, not just the removed append: F_WRITE's "Fc=0" success flag does
; not guarantee the full requested count was written (see the append
; bug above - that is exactly how it went unnoticed). Each of the four
; writes below now also checks its own returned BC against what it
; asked for, routing any shortfall to the same .errclose fail-loud path
; as a CF failure - a disk-full mid-write (or any other partial write)
; now fails SAVE outright instead of silently landing a truncated file
; while still reporting OK. The 256-byte flags write compares BC as one
; 16-bit value (sav_read_v2's own short-read idiom, reused here for a
; short WRITE); the three sub-256 counts (6, numObj, 1) compare C
; against the count and B against zero instead - cheaper for a value
; that always fits in one byte, and BC's high byte is never assumed
; zero without checking it.
sav_write_v2:
    call esx_getsetdrv
    jp c, .err
    ld ix, savName
    ld b, ESX_MODE_W               ; nextdaad.inc: write, create or
                                    ; truncate - the SAME mode sav_write
                                    ; itself uses; always a fresh file,
                                    ; never a reopen of an existing one
    call esx_fopen
    jp c, .err
    ld (savHandle), a
    ld a, (numObj)
    ld (savNObj), a                ; savHdr+savNObj = the 6-byte header
                                    ; (file.asm) - same block sav_write
                                    ; itself writes
    ; header (6 bytes)
    ld a, (savHandle)
    ld ix, savHdr
    ld bc, 6
    call esx_fwrite
    jp c, .errclose
    ld a, c
    cp 6
    jp nz, .errclose
    ld a, b
    or a
    jp nz, .errclose
    ; flags (256 bytes)
    ld a, (savHandle)
    ld ix, flags
    ld bc, 256
    call esx_fwrite
    jp c, .errclose
    ld hl, 256
    or a
    sbc hl, bc
    jp nz, .errclose
    ; object locations (numObj bytes)
    call sav_gather_locs           ; resident (file.asm): fills savLocs,
                                    ; BC = numObj
    ld ix, savLocs
    ld a, (savHandle)
    call esx_fwrite
    jp c, .errclose
    ld a, (numObj)
    cp c
    jp nz, .errclose
    ld a, b
    or a
    jp nz, .errclose
    ; trailing part byte - the ONLY new write versus sav_write, same
    ; open/close session, same call shape as the three writes above
    ld a, (savHandle)
    ld ix, curPart
    ld bc, 1
    call esx_fwrite
    jp c, .errclose
    ld a, c
    cp 1
    jp nz, .errclose
    ld a, b
    or a
    jp nz, .errclose
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
    xor a                       ; same-part RAMLOAD clears the transient
    ld (gfxDrawTarget), a       ; GFX 87/4 draw-target state (cross-
    ld (gfxRevealPend), a       ; part goes through eng_init_game via
    ld (gfxRevealMode), a       ; switch_to_part instead)
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

; SP16 A3 (docs/daad-compliance-report.md section 2): the compiler
; SWAPS BEEP's two parameters for every ZX target, so a real database
; carries the TONE in arg1 and the DURATION in arg2 - the reverse of
; what the DAAD manual, jDAAD and msx2daad all document:
;   drb.php:900-914
;     if (($condact->Param2<48) || ($condact->Param2>238))
;         ... replace the whole condact with PAUSE ...
;     else if ($target=='ZX') // Zx Spectrum interpreter expects BEEP
;                             // parameters in opposite order
;     { swap Param1 and Param2 }
; Probe (compliance report Appendix A probe 3): "BEEP 50 120" compiled
; for "zx next" emits 64, 120, 30 - opcode, tone 120, then duration 30
; (50 scaled by the target's 120/200 duration factor, A6).
; This handler reads the COMPILED order and must not be "corrected"
; back to the documented one: doing so plays the duration as a note.
; Note also that DRB rewrites any BEEP whose tone falls outside 48..238
; into a PAUSE before the swap, so a ZX-target DDB only ever reaches
; here with a tone in that range.
;
; SP16 A4: the tone ceiling is 238, not 222. DRC emits tones up to 238
; (octave 8 runs 216..238) and aud_periods.inc carries all 108 entries
; for 24..238; the old 222 clamp threw away the top eight semitones.
; jDAAD's own check accepts 24..238 against a 100-entry table and so
; reads past the end of its own array - NextDAAD's table is the more
; correct of the two, which is why the clamp moves rather than the
; table shrinking.
h_beep:                         ; 64: B = arg1 = tone, C = arg2 = duration (cs)
    ld a, b                     ; tone must be even and 24..238
    and 1                       ; inclusive - index (tone-24)/2 = 0..107,
    ret nz                      ; the full audPeriods table
    ld a, b
    cp 24
    ret c
    cp 239
    ret nc
    ld a, c                     ; duration 0 = no-op
    or a
    ret z
    ld a, b
    sub 24
    srl a
    ld (audReqIdx), a           ; period table index 0..107
    ld a, c                     ; centiseconds -> frames at 50Hz:
    srl a                       ; (C+1)/2, minimum 1
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
    jp z, .stopfx
    cp 6
    jp z, .playonce
    cp 7
    jp z, .playloop
    cp 8
    jp z, .stopmusic
    cp SFX_SUB_VID_ONCE
    jp z, .vidonce
    cp SFX_SUB_VID_LOOP
    jp z, .vidloop
    cp 11                       ; 11-16: the per-channel API (spec D6).
    jr c, .unk                  ; 11/12 = play n once/looped PINNED to
    cp 15                       ; channel 1, 13/14 the same for channel
    jr c, .pinplay              ; 2, 15/16 = stop that channel and
    cp 17                       ; release its pin. Decoded arithmetically
    jp c, .pinstop              ; rather than with six more cp/jr pairs
.unk:
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
    jr .smpset
.smp2:                          ; sample probe first, looped
    ld a, 1
.smpset:
    ld (audReqSmpLoop), a
    xor a                       ; request 0 = auto-allocate a channel
    jr .smpgo
.pinplay:                       ; 11-14 -> a NAMED channel + the loop bit
    sub 11                      ; 0-3: bit 0 = looped, bit 1 = channel 2
    ld e, a
    and 1
    ld (audReqSmpLoop), a
    srl e
    inc e                       ; E = 1 (channel 1) or 2 (channel 2), the
    ld a, e                     ; allocator's pin request codes
.smpgo:                         ; A = allocator request (0 auto, 1/2 pin)
    ld (sfxReq), a
    ld a, b
    or a                        ; numbers are >= 1 (both kinds)
    ret z
    inc a                       ; n = 255 is reserved: the API routes it
    jr z, .effect               ; straight to the AY effects bank (Task 3
                                ; review) - samples are 1-254. Applies to
                                ; the pinned subs identically
    ; The audReqSmp* start parameters are SHARED by both channels
    ; (audiobank.asm's aud_tick header). A start already filed and not
    ; yet consumed would be started with the parameters THIS trigger is
    ; about to commit, so let it go first. Two SFX condacts in one turn
    ; is the reachable case: the ordinary path halt-waits inside
    ; aud_load_wav and would drain it anyway, but a free rewind touches
    ; the card not at all and would not. audEnable 0 means aud_tick never
    ; runs, and then nothing can be pending either: every start filed
    ; below is followed by audEnable in the same breath.
    ld a, (audEnable)
    or a
    jr z, .alloc
.pend:
    ld a, (audRequest)
    and %01000000
    ld e, a
    ld a, (audRequest2)
    and %00001000
    or e
    jr z, .alloc
    halt
    jr .pend
.alloc:
    ld a, (sfxReq)              ; resolve the channel (SFX_PAGE, through
    call sfx_alloc_call         ; the resident trampoline). CF = both
    ret c                       ; channels pinned: trigger dropped, with
                                ; a DEBUG marker printed there
    ld (sfxSel), a              ; bit 0 = channel, bit 7 = free rewind,
    ld e, a                     ; bit 6 = cached rewind of a STREAM
    and %10000000
    jr nz, .started             ; cached whole: no card traffic at all,
                                ; and sfx_alloc has already re-committed
                                ; this channel's start parameters
    bit 6, e                    ; this channel still holds the handle and
    jr z, .fullopen             ; hot filemap of THIS number's file: the
                                ; spec's cached rewind. Skip F_OPEN, the
                                ; chunk walk, DISK_FILEMAP and F_FSTAT -
                                ; only the window re-staging is owed
    call sfx_stop_wait          ; the re-stage overwrites a live window
    ld a, e
    push bc                     ; B is the effect number and this call
    call sfx_rewind_call        ; DOES NOT preserve it: sfx_stream_rewind
    pop bc                      ; runs the staging tail, whose LDIR and
                                ; esx_fread both own BC. Every CF exit is
                                ; downstream of them, so the retry below
                                ; would otherwise build a filename from
                                ; a read count. (pop bc leaves CF)
    jr nc, .started
                                ; the cached path failed and its refusal
                                ; funnel has already invalidated the
                                ; cache: RETRY THE FULL OPEN ONCE, and
                                ; only if that fails too take the AY
                                ; fallback. A card hiccup on the cheap
                                ; path must not cost the effect
.fullopen:
    ld a, b
    push bc                     ; aud_load_wav corrupts BC (the WAV
    call aud_load_wav           ; filename decade-loop clobbers B
    pop bc                      ; before any exit path) - restore n for
                                ; the .effect fallback below. CF = no/
                                ; invalid NNN.WAV (pop bc leaves flags)
    jr c, .effect               ; -> AY effect fallback (SP7 path)
.started:
    ld a, (sfxSel)              ; file the RESOLVED channel's start bit,
    rrca                        ; never both: one start per condact, so
    jr c, .start2               ; the shared parameter cells are only
    ld hl, audRequest           ; ever read by the channel that wrote
    set 6, (hl)                 ; them
    jp .enable
.start2:
    ld hl, audRequest2
    set 3, (hl)
    jp .enable
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
    jp .enable
.pinstop:                       ; 15/16: stop that channel, release pin
    sub 14                      ; 1 = channel 1, 2 = channel 2
    jr .stopgo
.stopfx:                        ; 5: the documented SUPERSET - both
    ld hl, audRequest           ; sampled channels AND the AY effect,
    set 2, (hl)                 ; and both pins released
    ld a, 3
.stopgo:                        ; A = channel mask, bit 0 ch1, bit 1 ch2
    ld e, a
    rrca
    jr nc, .nost1
    ld hl, audRequest
    set 7, (hl)                 ; channel 1's stop
.nost1:
    bit 1, e
    jr z, .nost2
    ld hl, audRequest2
    set 2, (hl)                 ; channel 2's stop, the exact mirror
.nost2:
    ld a, e
    add a, 2                    ; 3/4/5 = the allocator's unpin requests
    jp sfx_alloc_call           ; audEnable is already set if anything is
                                ; playing, so the stops will be consumed
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
.vidonce:
    ld a, 0
    jr .vidgo
.vidloop:
    ld a, 1
.vidgo:
    ; PLAYFLI/PLAYFLIL alias (design doc): B (video number) untouched, C
    ; becomes vid_play's 0/1 loop contract - identical trampoline shape
    ; to h_gfx's own GFX_SUB_VID_ONCE/LOOP handling (overlay2.asm).
    ld c, a
    ld hl, vid_play
    push hl
    ld a, VID_PAGE
    jp ovl_map_page

msgSfxUnk: db "SFX? ", 0

; Stop the sample playing on the channel sfxSel bit 0 names, and wait
; until aud_tick has consumed the stop. Called by aud_load_wav before it
; stages, and by h_sfx before a cached rewind re-stages - both overwrite
; the channel's window, and a playing sample must never be overwritten.
; The wait is also what shuts sfx_chan_refill's gate for the duration:
; aud_smp_stop clears SMPB_FLAGS bit 2 STREAMING, which is that gate.
; audEnable = 0 means the ISR never reaches aud_tick: nothing can be
; playing and the bit would never be consumed - skip the wait rather
; than hang. The OTHER channel is deliberately left alone: two effects
; play together, and a load on one must not silence the other.
; Corrupts AF, HL.
sfx_stop_wait:
    ld a, (audEnable)
    or a
    ret z
    ld a, (sfxSel)
    rrca
    jr c, .ch2
    ld hl, audRequest
    res 6, (hl)                 ; a pending un-consumed start must not
    set 7, (hl)                 ; fire mid-load
.wait1:
    halt
    ld a, (audRequest)
    and %10000000
    jr nz, .wait1
    ret
.ch2:
    ld hl, audRequest2          ; channel 2's pair, the exact mirror
    res 3, (hl)
    set 2, (hl)
.wait2:
    halt
    ld a, (audRequest2)
    and %00000100
    jr nz, .wait2
    ret

; Call a routine on SFX_PAGE with page 48 in slot 6 - sfx_alloc reads
; sfxChan0 there (sfxChan1, the mailbox and frameCounter are resident),
; and sfx_stream_rewind needs it for the block and the window descriptor.
; A and CF cross both trampolines untouched (nextreg writes neither), and
; data_save/data_map_page/data_restore corrupt AF only, so the callee's
; verdict comes back intact. HL survives them too, which is what lets the
; target address be loaded before the bracket.
;
; BC IS THE CALLEE'S, NOT THIS BRACKET'S. The bracket itself preserves it
; (nr_read pushes it), but that says nothing about what runs inside:
; sfx_alloc preserves B deliberately, and sfx_stream_rewind does NOT -
; it runs the staging tail, whose LDIR and esx_fread both own BC. A
; caller keeping a value in BC across a call through here must know
; which callee it is asking for, and h_sfx pushes around the rewind.
sfx_alloc_call:                 ; A = allocator request code
    ld hl, sfx_alloc
    jr sfx_page_bracket
sfx_rewind_call:                ; A bit 0 = channel index
    ld hl, sfx_stream_rewind
sfx_page_bracket:
    push af
    call data_save
    ld a, AUD_PAGE_LO
    call data_map_page
    pop af
    call sfx_page_call
    push af
    call data_restore
    pop af
    ret

; --- song / effects-bank loaders ------------------------------------

; SP14c batch C (OV1-5): shared PARTn\ prefix-build-and-probe helper.
; aud_load_song/aud_load_wav/aud_load_ays/aud_load_sfb each inlined this
; identical ~55-byte block (verified byte-for-byte identical modulo the
; source pointer before folding); this is the single body all four now
; call. In: DE = source name pointer (9 bytes, NUL-padded - audName for
; song/wav/ays, audGameSfb for sfb). curPart==1 is checked first (skips
; straight to CF-set, matching every caller's own un-prefixed root-name
; fallback exactly as before). Out: NC + A = handle on a successful
; PARTn-prefixed open (caller proceeds to its own unchanged
; .partopened body); CF set on curPart==1, no default drive, or an
; open failure (caller falls through to its own unchanged root-name
; open path - none of that fallback code moved). The tail is a plain
; tail-call into esx_fopen, so this routine's own corruption set is
; exactly esx_fopen's: Corrupts AF, BC, DE, HL, IX.
aud_part_open:
    ld a, (curPart)
    dec a
    jr z, .skip
    push de                      ; source ptr survives the buffer build
    ld hl, audNamePart
    ld (hl), 'P'
    inc hl
    ld (hl), 'A'
    inc hl
    ld (hl), 'R'
    inc hl
    ld (hl), 'T'
    inc hl
    ld a, (curPart)
    add a, '0'
    ld (hl), a
    inc hl
    ld (hl), '\'
    inc hl
    ex de, hl                    ; de = audNamePart+6
    pop hl                       ; hl = source ptr
    ld bc, 9
    ldir
    call esx_getsetdrv
    ret c                        ; no drive: CF set, caller's root path
    ld ix, audNamePart
    ld b, ESX_MODE_READ
    jp esx_fopen                 ; tail call: NC+A=handle or CF, as-is
.skip:
    scf
    ret

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
    ; SP14c OV1-5: shared PARTn\ prefix-build-and-probe (aud_part_open,
    ; above) - was an inlined ~55-byte block, identical in shape at all
    ; four song/sample/effects-bank loader sites. curPart == 1: skip
    ; straight to .open - zero new opens, byte-identical to pre-fold
    ; behavior. GAME.AKY (the $FF sentinel above) is never prefixed -
    ; it reaches .open directly via its own jr, before this block.
    ld de, audName
    call aud_part_open
    jr nc, .partopened
.open:
    call esx_getsetdrv
    jp c, .fail
    ld ix, audName
    ld b, ESX_MODE_READ
    call esx_fopen
    jp c, .fail                 ; missing: playing music untouched
.partopened:
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
    ; SP14c OV1-5: shared PARTn\ prefix-build-and-probe (aud_part_open,
    ; above this section). curPart == 1: skip straight to .rootonly -
    ; zero new opens, byte-identical to pre-fold behavior. Task 3's
    ; switch_to_part already re-probes this routine at every part
    ; switch with curPart committed first (overlay0.asm), so this
    ; prefix pass activates automatically on the very next switch.
    ld de, audGameSfb
    call aud_part_open
    jr nc, .partopened
.rootonly:
    call esx_getsetdrv
    jr c, .fail
    ld ix, audGameSfb
    ld b, ESX_MODE_READ
    call esx_fopen
    jr c, .fail
.partopened:
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
    ld a, $FF
    ld (DATA_WINDOW+audSongNum-$E000), a
    ld a, AUD_PAGE_LO           ; aysFlags/aysPageCnt/sfxChan0 live in page
    call data_map_page          ; 48 code space: a stale stream page count
    xor a                       ; or active bit must not survive a warm boot
    ld (aysFlags), a            ; stream-active off (sibling of SMPB_FLAGS)
    ld (aysPageCnt), a          ; stream page count cold
    ld (sfxChan0+SMPB_FLAGS), a ; clear a stale sample-active bit: a looping
                                ; sample must not replay a recycled bank
                                ; table after a warm boot
    ld hl, aud_sfx_init
    call sfx_page_call          ; SP18 item 7 Task 2/11: seed BOTH channels'
                                ; constant block members (ring/cursor/CTC/DAC
                                ; port, window descriptor, stream cells) and
                                ; pin the floor banks. The seed itself is cold
                                ; SFX_PAGE code; the resident trampoline maps
                                ; it into slot 7 (which this page occupies)
                                ; and back. Page 48 is already in slot 6,
                                ; which the seed needs for channel 1's block
    call data_restore
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
; SP11 T5: PARTn\ prefixed scratch, overlay1-local, shared by all four
; overlay1 probe sites (aud_load_wav, aud_load_song/aud_load_ays'
; numbered branches, aud_load_sfb) exactly the way audName above is
; already shared between them - never concurrently in flight, each
; site fully rewrites it before use. Sized 6 ("PARTn\") + 9 (matches
; audName's own size - every name this buffer ever holds, WAV/AKY/AYS/
; GAME.SFB alike, is <= 9 bytes with its own NUL) = 15.
audNamePart: ds 15
audHandle:  db 0
audSongReq: db 0
audLoaded:  dw 0                ; bytes of song actually loaded
audStride:  db 0                ; linker entry stride for the walk
audWalkVal: dw 0                ; word scratch for the split windows
audProbe:   db 0                ; oversize one-byte probe target
bpTarget:   dw 0                ; h_beep frameCounter target
sfxReq:     db 0                ; h_sfx: the allocator request code for
                                ; this trigger (0 auto, 1/2 pin a channel)
sfxSel:     db 0                ; h_sfx: the allocator's verdict - bit 0 =
                                ; the resolved channel (0 = channel 1),
                                ; bit 7 = free rewind (the window already
                                ; holds this effect whole), bit 6 = cached
                                ; rewind (this channel still holds the
                                ; handle and hot filemap of this streamed
                                ; file), neither = a full open. At most
                                ; one of 6/7 is ever set. sfx_stop_wait
                                ; and aud_load_wav read bit 0 for the stop
                                ; bit they file and the block they stage
                                ; into

; --- WAV sample loader (SP8) ----------------------------------------

; aud_load_wav: A = sample number (1-255). Probes NNN.WAV, validates
; RIFF/fmt (PCM, mono, 8-bit, rate 3500-20000), then hands the open file
; to sfx_stream_open (SFX_PAGE, through the resident sfx_open_tramp),
; which stages it into the channel's 24K page window and flags the
; channel COMPLETE (whole file resident) or STREAMING. Finally it derives
; the CTC control word + time constant from the header rate and the live
; video-timing mode.
;
; SP18 item 7 Task 5 replaced the old "claim a page list for the whole
; payload" loop (aud_banks_claim over smpPageTab, up to AUD_SMP_MAX)
; with that call: nothing here allocates banks any more, and no design
; element caps effect length against RAM.
;
; Keep-last is NOT tested here any more (SP18 item 7 Task 12): with two
; channels the question is which channel caches the number, and sfx_alloc
; answers it before this routine is reached. A free rewind never gets
; here at all - h_sfx files the start straight away.
;
; THE CHANNEL IS sfxSel BIT 0, the allocator's verdict. Everything below
; that used to be channel 1 by construction - the stop bit filed and
; waited on, and the block handed to sfx_stream_open - follows it.
;
; The chosen channel's active sample is stopped (its mailbox stop bit +
; consumed-wait) before the staging overwrites the window - a playing
; sample must never be overwritten, and that wait is also what makes a
; STEAL safe: the victim is provably silent before its cache is evicted.
; Out: CF clear = window staged + audReqSmpCtrl/Tc/Len/LenHi committed
; (audReqSmpLoop is the CALLER's, set before or after);
; CF set = missing/malformed/short-read/too fragmented. Any failure past
; the stop leaves that channel's sample stopped but its cache INTACT -
; nothing before sfx_stream_open touches the window, so the effect it
; already held is still resident and still free to rewind; the open's own
; refusal funnel is what clears the cache when staging really started. A
; missing file (open fails first) leaves the previous sample untouched.
; Corrupts everything.
aud_load_wav:
    ld (wavReqNum), a
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
    ; SP14c OV1-5: shared PARTn\ prefix-build-and-probe (aud_part_open).
    ; curPart == 1: skip straight to .rootonly - zero new opens,
    ; byte-identical to pre-fold behavior.
    ld de, audName
    call aud_part_open
    jr nc, .partopened
.rootonly:
    call esx_getsetdrv
    jp c, .fail
    ld ix, audName
    ld b, ESX_MODE_READ
    call esx_fopen
    jp c, .fail                 ; missing: any playing sample untouched
                                 ; (open probed BEFORE the stop, same
                                 ; rule as aud_load_song)
.partopened:
    ld (audHandle), a
    ld hl, 0
    ld (wavDataOff), hl         ; file position tracker: .read accumulates
                                ; every byte it consumes, so the moment
                                ; the data chunk's own header has been
                                ; read this IS the offset of the first
                                ; payload byte - which the window's
                                ; consumer anchor needs
    call sfx_stop_wait          ; stop the sample playing ON THIS CHANNEL
                                ; and wait for the stop to be consumed,
                                ; before the staging overwrites its window
    ; The channel's SMPB_KEEP is NOT invalidated here. Nothing before
    ; sfx_stream_open touches the window, so a header rejection below
    ; leaves the previously cached effect intact and still free to
    ; rewind; the open's own refusal funnel clears both keep cells when
    ; staging really has started.
    ; (SP18 item 7 Task 5: no bank release here any more. The window
    ; pages are fixed floor pages the channel owns permanently, so
    ; nothing is claimed or freed per load - the stop-wait above is all
    ; the "engine is provably off the source" this needs.)
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
    ; 32-bit data size: wavHdr+4 low word, wavHdr+6 high word. Only the
    ; 24-bit sanity bound survives here - AUD_SMP_MAX (the old 1MB cap)
    ; is DELETED with SP18 item 7 Task 5, because the window streams and
    ; no length cap remains by design.
    ld a, (wavHdr+7)            ; size bits 24-31
    or a
    jp nz, .failclose          ; > 16MB: absurd
    ld hl, (wavHdr+4)          ; size bits 0-15
    ld a, (wavHdr+6)           ; size bits 16-23
    ld d, a
    or h
    or l
    jp z, .failclose           ; empty data: malformed
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
    ; Hand the open file to the stream page: it captures the filemap,
    ; stages the window through slot 6 and commits the channel's flags
    ; and consumer anchor. Page 48 goes into slot 6 first - the channel
    ; block lives there and sfx_stream_open reads and writes it
    ; IX-relative (it hands slot 6 back as AUD_PAGE_LO on every exit,
    ; and data_restore below returns the caller's own mapping).
    ;
    ; DAC signedness: the WAV bytes stage UNSIGNED, verbatim - no
    ; load-time transform anywhere. The CPU-OUT DAC path is unsigned on
    ; both silicon and CSpect, so one convention holds everywhere (full
    ; evidence at nextdaad.inc DAC_SILENCE). The retired -DDAC_CSPECT
    ; accommodation used to XOR $80 over every byte on the way in; it is
    ; gone now that unsigned is empirically pinned, and the staging path
    ; is a straight esxDOS read into the window pages.
    call data_save
    ld a, AUD_PAGE_LO
    call data_map_page
    ld ix, sfxChan0             ; the allocated channel's block, per
    ld a, (sfxSel)              ; sfxSel bit 0 - sfxChan0 is page-48 data
    rrca                        ; (just mapped into slot 6 above),
    jr nc, .blkok               ; sfxChan1 is resident
    ld ix, sfxChan1
.blkok:
    ld de, (wavDataOff)         ; first payload byte (consumer anchor)
    ld bc, (wavLen)             ; declared payload length, 24-bit: the
    ld a, (wavLenHi)            ; open checks it against the file's real
    ld h, a                     ; size (a lying data chunk used to be
    ld a, (audHandle)           ; caught by the deleted loop's short read)
    ld l, a
    ld a, (wavReqNum)
    call sfx_open_tramp         ; resident: slot 7 <- SFX_PAGE, call, back
    push af                     ; data_restore corrupts A, not F - but
    call data_restore           ; carry the whole result across anyway
    pop af
    jp c, .fail                 ; refused: the handle is already closed
                                ; and the block's stream bits cleared -
                                ; straight to the caller's AY fallback
    ; commit: derive the CTC control word + time constant from the sample
    ; rate and the live video-timing mode, fill the mailbox. The ring
    ; self-paces at the CTC rate, so no per-frame chunk sizing is needed.
    ; SMPB_KEEP is sfx_stream_open's; aud_smp_start latches these same
    ; parameters (rate included, as SMPB_RATE) into the channel's block,
    ; which is where a later rewind of this effect re-commits them from -
    ; re-deriving Ctrl/Tc from the stored rate against the LIVE video mode
    ; rather than replaying this load's values (owner ruling 2026-08-10).
    ld de, (wavFmt+4)           ; rate
    ld (audReqSmpRate), de      ; latched into SMPB_RATE by aud_smp_start
    ; aud_ctc_params now lives on SFX_PAGE (moved by the same ruling, so a
    ; rewind re-commit can reach it without mapping overlay1 back in); this
    ; page and SFX_PAGE share the slot-7 window, so the resident trampoline
    ; hops it in and back, exactly as sfx_open_tramp does for
    ; sfx_stream_open above. sfx_page_call preserves DE across the hop
    ; (its own header), which this call relies on for the rate parameter.
    ld hl, aud_ctc_params
    call sfx_page_call          ; sets audReqSmpCtrl + audReqSmpTc
    ld hl, (wavLen)
    ld (audReqSmpLen), hl
    ld a, (wavLenHi)
    ld (audReqSmpLenHi), a
    or a                        ; CF clear
    ret
.failclose:
    ld a, (audHandle)
    call esx_fclose
.fail:
    scf
    ret
; BC bytes from the open file into IX. Out CF = SD error; BC = bytes
; actually read (esx_fread contract). Accumulates every byte consumed
; into wavDataOff: all reads on this path are sequential from offset 0
; and there is no seek, so that running total IS the file position, and
; the value it holds when the data chunk header has just been read is
; the offset of the first payload byte. Preserves BC (the callers'
; short-read checks need it); corrupts AF, HL.
.read:
    ld a, (audHandle)
    call esx_fread
    push af
    ld hl, (wavDataOff)
    add hl, bc
    ld (wavDataOff), hl
    pop af
    ret

; aud_ctc_params and aud_clk16_tab moved to SFX_PAGE (src/audio/streamfx.asm)
; by the 2026-08-10 fresh-TC ruling: sfx_alloc's rewind re-commit needed to
; reach them and overlay1 and SFX_PAGE share the slot-7 window, so keeping
; one copy on SFX_PAGE and reaching it from here through sfx_page_call (see
; the .stream commit block above) beat a second copy or a nested page hop.

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
    ; SP14c OV1-5: shared PARTn\ prefix-build-and-probe (aud_part_open).
    ; curPart == 1: skip straight to .open - zero new opens, byte-
    ; identical to pre-fold behavior. GAME.AYS (the $FF sentinel above)
    ; is never prefixed - it reaches .open directly via its own jr,
    ; before this block.
    ld de, audName
    call aud_part_open
    jr nc, .partopened
.open:
    call esx_getsetdrv
    jp c, .fail
    ld ix, audName
    ld b, ESX_MODE_READ
    call esx_fopen
    jp c, .fail                 ; missing: current music untouched (open
                                ; probed BEFORE the stop, as aud_load_song)
.partopened:
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
; table access - aud_load_ays maps page 48 once per phase, aud_boot_probe
; likewise). Both write bankTable directly (resident, visible regardless
; of slot 6) and call bank_alloc/bank_free (also resident). Working
; storage is mainline-only scratch, so these are not ISR-safe; callers
; run them only with the sample engine idle.
;
; SINCE SP18 ITEM 7 TASK 5 the AYS stream is the ONLY client: the sampled
; effects claim nothing (they stream through fixed floor-page windows),
; so aysPageTab is the only table base these are ever handed, and the
; floor pass below always finds banks 25-27 already BT_USED (marked once
; at boot by aud_sfx_init, which owns them as the effect windows)
; and falls straight through to the pool. Shape kept intact for the one
; client that remains.
;
; aud_banks_claim: A:DE = 24-bit byte count (A = bits 23-16). HL = page
; table base (aysPageTab). Fills the table with 2 pages per claimed 16K
; bank - floor banks 25-27 first (BT_RESERVED -> BT_USED by
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
    add hl, a                   ; SP14c OV1-4: A already = C (cp does
                                 ; not touch A) - HL -> bankTable[C],
                                 ; no ld b,0 needed
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
; 2 and take bank = page/2, all of them via bank_free. Then zeroes the
; count byte at (base + AUD_STRTAB_MAX). Safe on B = 0.
;
; THERE IS NO FLOOR SPECIAL CASE any more (SP18 item 7 Task 5). Banks
; 25-27, pages 50-55, are the two channels' effect windows and are pinned
; BT_USED at boot by aud_sfx_init, so aud_banks_claim's floor pass
; never appends them to a claim table and they can never appear in a
; release list. The branch that used to return them to BT_RESERVED is
; DELETED rather than left unreachable: had it ever run it would have
; made two live windows claimable again by the very next call, silently
; handing an AYS stream the pages an effect is playing out of. Every page
; that reaches this loop now is a pool page, which is what bank_free
; expects.
; Corrupts AF, BC, HL. (DE was only the deleted branch's index scratch;
; bank_free itself leaves DE untouched.)
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
    srl a                       ; pool bank = page / 2
    call bank_free
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
wavDataOff: dw 0                ; running file position while the header
                                ; walk runs; at the data chunk it is the
                                ; first payload byte's offset (.read)
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
