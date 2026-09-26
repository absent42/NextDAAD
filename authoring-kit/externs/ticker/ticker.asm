; ticker.asm - NextDAAD XBN worked example.
;
; EXTERN n 30 arms, EXTERN p 31 stops (p nonzero clears), EXTERN v 32-38
; set row, column, width, ink, paper, mode, speed - latched by the next
; arm. EXTERN n 39 types message n at the cursor (foreground, blocks).
; Interrupt:  int steps one step per `speed` frames into the placed field
;             (typewriter, or marquee once/loop), wrapping inside it,
;             until the message is consumed. It calls xbn_width
;             (xbnmod.inc) for the live text width, so it stays correct
;             after a GFX n 18 mode switch.
;
; What this teaches: SVC_GETMSG's staging buffer is resident and shared
; with the rest of the interpreter - it is only valid until the NEXT
; service call, or across a save/load. An extern that needs the text to
; outlive the EXTERN call that fetched it (as this one does, since the
; #int hook reads it frame by frame long after ext has returned)
; MUST copy it into memory this XBN bank owns. That copy is the whole
; point of this example; everything else is bookkeeping around it.
; SVC_PAIR runs BEFORE SVC_GETMSG: the staging buffer dies at the next
; service call.
; marquee_step skips its LDIR at width 1: BC = 0 copies 64K.

; Standalone build emits its own header and binary; a combined build
; defines XBN_MODULE and supplies both.
    IFNDEF XBN_MODULE
    DEVICE ZXSPECTRUMNEXT
    INCLUDE "xbn.inc"
    INCLUDE "xbnmod.inc"
    ORG XBN_ORG
    XBN_BEGIN ticker.ext, ticker.int
    ENDIF

    MODULE ticker

; Row 27 - the BOTTOM-MOST ULA-COVERED tilemap row in BOTH text widths.
; The tilemap's origin sits 32 pixels above and left of the ULA origin
; (dev guide, NR $1B notes), so of the 32 rows, 0-3 and 28-31 land in
; the BORDER area - real display chains (HDMI scalers, monitor
; overscan) often crop border pixels, and a ticker parked there can be
; invisible on hardware while an emulator window shows it. Rows 4-27
; overlay the ULA area every display shows. If your game wants the
; very bottom border row instead, that is a display question to test
; on your own target hardware, not a code change.
; The row's ADDRESS depends on the text width the game selected with
; GFX n 18: 2 bytes per cell, so the stride is 160 bytes/row at 80x32
; and 80 bytes/row at 40x32.
; Live width/row base probe: xbn_width (xbnmod.inc), called from int below.

TICK_MIN_API    equ 3            ; SVC_PAIR arrived with API 3
TICK_GAP        equ 4            ; blank cells between loops (mode 2)

ext:
    ; Contract on entry: A=B=param1, C=fn, HL=flags+param1, DE=objTable
    ; +param1*6, IX=flags base. Only B (param1) and C (fn) are used.
    ld a, c
    cp 30
    jr z, .arm
    cp 31
    jr z, .stop
    cp 39
    jp z, type_msg                ; fn 39: typed message, foreground
    sub 32
    cp 7
    jr nc, .notmine              ; outside 30-38
    ; setter fns 32-38: settab row = min, max, dw target. Out of range
    ; leaves the stored value alone and fails the entry (CF set).
    add a, a
    add a, a                     ; *4
    ld hl, settab
    add hl, a                    ; Z80N
    ld a, b                      ; the value
    cp (hl)                      ; value - min: CF when below
    ret c
    inc hl
    ld a, (hl)
    cp b                         ; max - value: CF when above
    ret c
    inc hl
    ld e, (hl)
    inc hl
    ld d, (hl)
    ld a, b
    ld (de), a                   ; CF still clear from the cp
    ret
.notmine:
    or a                         ; CF clear: unrecognised fn, no failure
    ret

.stop:
    xor a
    ld (armed), a                ; disarm FIRST: the hook reads the active set
    ld a, b
    or a
    ret z                        ; EXTERN 0 31: text stays; CF clear (or a)
    call tick_clear               ; EXTERN 1 31: field cleared in the ticker's colours
    or a
    ret

.arm:
    xor a
    ld (armed), a                ; disarm FIRST; every exit below leaves it so
                                 ; unless the arm completes
    push bc                      ; B = message number, live across the services
    ld hl, set_row
    ld de, row
    ld bc, 5
    ldir                         ; latch row, col, width, mode, speed
    xor a
    ld (attr), a                 ; fallback: reserved pair 0, white on black
    call SVC_VERSION
    cp TICK_MIN_API
    jr c, .nocolour              ; older interpreter: no SVC_PAIR row
    ld a, (set_paper)
    ld b, a
    ld a, (set_ink)
    ld c, a
    call SVC_PAIR                ; BEFORE SVC_GETMSG: the staging buffer dies
    ld (attr), a                 ; at the next service call
.nocolour:
    pop bc
    ld a, b
    call SVC_GETMSG               ; out HL = staging buffer, BC = length
    jr c, .fail                  ; out of range: field cleared, stays disarmed, CF set
    ld a, b
    or c
    jr z, .empty                 ; BC = 0 is a legal empty message; never ldir it
                                 ; (LDIR with BC = 0 copies 65536 bytes)
    ld de, text
    ld a, b
    or a
    jr z, .lenok
    ld bc, 255                   ; 256 clamps to 255, count and length together
.lenok:
    ld a, c
    ld (textlen), a
    ldir                         ; the staging buffer dies at the next service
                                 ; call: copy into OUR bank first
    call tick_clear
    xor a
    ld (cursor), a
    ld (pos), a
    ld (tail), a
    ld a, (speed)
    ld (count), a                ; first step lands speed frames from now
    ld a, 1
    ld (armed), a                ; arm LAST, once text and state are valid
    or a                         ; CF clear
    ret
.fail:
    call tick_clear
    scf
    ret
.empty:
    call tick_clear
    or a
    ret

; Resolve the active field against the LIVE width. Out: HL = address of
; the field's first cell, B = ew (0 = col past the live width: nothing to
; write), (ew) = B. Corrupts AF, BC, DE, HL.
tick_field:
    ; The select+read pair inside xbn_width must be atomic against the
    ; frame ISR (interrupts.asm's MMU save re-selects and never
    ; restores) - same IFF2-preserving DI bracket as nr_read
    ; (hardware.asm).
    ld a, i
    jp pe, .sampled
    ld a, i
.sampled:
    push af
    di
    call xbn_width               ; E = live width, D = stride
    pop af
    jp po, .noei
    ei
.noei:
    ld a, (col)
    cp e
    jr c, .onscreen
    xor a
    ld (ew), a
    ld b, a                      ; off screen
    ret
.onscreen:
    ld c, e                      ; C = live width
    ld a, (width)
    or a
    jr nz, .clamp
    ld a, c                      ; width 0 = to the end of the row
.clamp:
    ld b, a                      ; candidate ew
    ld a, (col)
    add a, b                     ; col + ew <= 159: no byte overflow
    sub c                        ; overhang past the live width, if any
    jr c, .fits
    jr z, .fits
    ld e, a
    ld a, b
    sub e
    ld b, a                      ; ew shrunk to fit
.fits:
    ld a, b
    ld (ew), a
    ld a, (row)
    ld e, a
    mul d, e                     ; Z80N: DE = row * stride, max 31*160 = 4960
    ld hl, XBN_TILEMAP
    add hl, de
    ld a, (col)
    add a, a                     ; cell offset, col <= 79
    add hl, a                    ; Z80N
    ret

; Space + the ticker attribute across the field. Corrupts AF, BC, DE, HL.
tick_clear:
    call tick_field
    ld a, b
    or a
    ret z
    ld a, (attr)
    ld c, a
.cell:
    ld (hl), ' '
    inc hl
    ld (hl), c
    inc hl
    djnz .cell
    ret

int:
    ; Once per frame while an XBN with an intEntry is loaded (not while
    ; a clip is armed). Cheap when idle: one load and test. The
    ; interpreter saves and restores full context around this call.
    ld a, (armed)
    or a
    ret z
    call SVC_BUSY
    bit 0, a
    ret nz                       ; clip open/prefill: the tilemap is the audio ring
    call tick_field              ; HL = first cell, B = ew
    ld a, b
    or a
    ret z                        ; field off the live screen: frozen whole,
                                 ; countdown included
    ld a, (count)
    dec a
    ld (count), a
    ret nz
    ld a, (speed)
    ld (count), a
    ld a, (mode)
    or a
    jr nz, marquee_step

; Mode 0: one character at col + pos, wrapping inside the field.
typewriter_step:                 ; in HL = first cell, B = ew
    ld a, (pos)
    cp b
    jr c, .posok
    xor a                        ; pos >= ew (a shrink can leave it above): wrap
.posok:
    ld c, a
    add a, a
    add hl, a                    ; Z80N: the cell
    ld a, (cursor)
    ld de, text
    add de, a                    ; Z80N: text[cursor]
    ld a, (de)
    ld (hl), a
    inc hl
    ld a, (attr)
    ld (hl), a
    ld a, c
    inc a
    ld (pos), a
    ld hl, cursor
    inc (hl)
    ld a, (textlen)
    cp (hl)
    ret nz
    xor a
    ld (armed), a                ; consumed: disarm, text stays on screen
    ret

; Modes 1 and 2: shift the field left one cell, feed the rightmost cell.
marquee_step:                    ; in HL = first cell, B = ew (>= 1)
    ld a, b
    dec a
    add a, a                     ; (ew-1)*2 = byte offset of the rightmost cell
    ld c, a                      ; feeds BC for the LDIR; dead on the ew==1 path (Z)
    jr z, .shifted               ; nothing to move: an LDIR with BC = 0 copies 64K
    ld d, h
    ld e, l                      ; DE = cell 0 (dest)
    inc hl
    inc hl                       ; HL = cell 1 (src); dest below src: LDIR is safe
    ld b, 0                      ; BC = (ew-1)*2, never 0 here
    ldir                         ; BC -> 0; DE ends at cell (ew-1) (LDIR: DE = dst+count)
    ex de, hl                    ; HL = the rightmost cell (C is dead here, not reusable)
.shifted:
    ld a, (cursor)
    ld c, a
    ld a, (textlen)
    cp c
    jr z, .blank                 ; text exhausted: feed a blank, count the tail
    ld de, text
    ld a, c
    add de, a                    ; Z80N: text[cursor]
    ld a, (de)
    ld (hl), a
    inc hl
    ld a, (attr)
    ld (hl), a
    ld hl, cursor
    inc (hl)
    ld a, (textlen)
    cp (hl)
    ret nz                       ; more text to come
    ld a, (mode)
    dec a                        ; Z: mode 1 (once)
    ld a, TICK_GAP
    jr nz, .settail              ; mode 2: the gap
    ld a, (ew)                   ; mode 1: a full field width drains the text out
.settail:
    ld (tail), a
    ret
.blank:
    ld (hl), ' '
    inc hl
    ld a, (attr)
    ld (hl), a
    ld hl, tail
    dec (hl)
    ret nz
    ld a, (mode)
    dec a
    jr nz, .again                ; mode 2
    ld (armed), a                ; mode 1: A = 0 here - disarm, field blank
    ret
.again:
    xor a
    ld (cursor), a               ; the message enters again after the gap
    ret

; fn 39: type message B at the cursor, set_speed frames per letter, with
; the printer's word wrap (SVC_FITWORD). Blocks until done. tybuf is the
; copy: the hook reads text while a ticker runs.
type_msg:
    ld a, b
    call SVC_GETMSG               ; out HL = staging buffer, BC = length
    ret c                         ; no such message: the entry fails
    ld a, b
    or c
    ret z                         ; empty: CF clear, nothing typed
    ld a, b
    or a
    jr z, .lenok
    ld bc, 255                    ; 256 clamps to 255, as fn 30 does
.lenok:
    ld a, c
    ld (tylen), a
    ld de, tybuf
    ldir                          ; BC > 0 here; the staging buffer dies at the next service call
    xor a
    ld (tyidx), a
    call SVC_VERSION
    cp TICK_MIN_API
    jr c, .fallback               ; no SVC_FITWORD: word-at-a-time
.next:
    ld a, (tyidx)
    ld hl, tylen
    cp (hl)
    jr nc, .done
    ld hl, tybuf
    add hl, a                     ; Z80N
    ld a, (hl)
    cp ' '
    jr z, .space
    cp $0B
    jr c, .word                  ; $01-$0A print as glyphs: word characters
    cp $10
    jr c, .ctrl                  ; $0B-$0D break, $0E/$0F latch: no delay
.word:
    call ty_word                  ; types the word, leaves tyidx past it
    jr .next
.ctrl:
    call SVC_PUTCHAR
    jr .adv
.space:
    ld hl, tyspc
    call SVC_PUTS                 ; " " + flush; swallowed at column 0 like MES
    call ty_delay
.adv:
    ld hl, tyidx
    inc (hl)
    jr .next
.fallback:
    ld a, (tyidx)
    ld hl, tylen
    cp (hl)
    jr nc, .fdone
    ld hl, tybuf
    add hl, a
    ld a, (hl)
    push af
    call SVC_PUTCHAR
    pop af
    cp $0B
    jr c, .fdelay
    cp $10
    jr c, .fadv                  ; controls and toggles: no delay
.fdelay:
    call ty_delay
.fadv:
    ld hl, tyidx
    inc (hl)
    jr .fallback
.fdone:
    ld hl, tyone+1                ; empty string: flush the last word
    call SVC_PUTS
.done:
    or a                          ; CF clear
    ret

; Word from tyidx: L = characters that are not $0E/$0F, up to a space or
; $0B-$0D. A word with '_' or '@' goes out whole (the interpreter alone
; knows an object name's length). Others are typed in chunks of at most
; WIN_W glyphs, each fitted, as prn_char flushes. Leaves tyidx at the end.
ty_word:
    ld a, (tyidx)
    ld e, a                       ; E = scan index
    ld d, 0                       ; D = L
    ld c, d                       ; C = nonzero if '_' or '@'
.scan:
    ld a, e
    ld hl, tylen
    cp (hl)
    jr nc, .scanned
    ld hl, tybuf
    add hl, a
    ld a, (hl)
    cp ' '
    jr z, .scanned
    cp $0B
    jr c, .count
    cp $0E
    jr c, .scanned                ; $0B-$0D end the word
    cp $10
    jr c, .skip                   ; $0E/$0F: zero width
    cp '_'
    jr z, .esc
    cp '@'
    jr nz, .count
.esc:
    ld c, 1
.count:
    inc d
.skip:
    inc e
    jr .scan
.scanned:
    ld a, e
    ld (tyend), a
    ld a, c
    or a
    jr nz, .whole
    ld (tychunk), a               ; A = 0: a toggles-only run makes no fit
    ld a, d
    ld (tyrem), a
    or a
    jr z, .type
    call SVC_FITWORD              ; make room: the printer's own wrap rule
    ld (tywid), a                 ; out A = WIN_W
    call ty_chunk
.type:
    ld a, (tyidx)
    ld hl, tyend
    cp (hl)
    ret nc
    ld hl, tybuf
    add hl, a
    ld a, (hl)
    cp $0E
    jr c, .letter
    cp $10
    jr nc, .letter
    call SVC_PUTCHAR                ; toggle: latch only, no delay
    jr .tnext
.letter:
    ld (tyone), a
    ld hl, tyone
    call SVC_PUTS                   ; one letter + flush: shows at once
    call ty_delay
    ld hl, tychunk
    dec (hl)
    jr nz, .tnext
    ld a, (tyrem)
    or a
    jr z, .tnext
    call ty_chunk                   ; prn_char flushes every WIN_W glyphs:
    call SVC_FITWORD                ; place the next chunk by its own length
.tnext:
    ld hl, tyidx
    inc (hl)
    jr .type
.whole:
    ld a, (tyidx)
    ld hl, tyend
    cp (hl)
    jr nc, .wflush
    ld hl, tybuf
    add hl, a
    ld a, (hl)
    call SVC_PUTCHAR
    ld hl, tyidx
    inc (hl)
    jr .whole
.wflush:
    ld hl, tyone+1                  ; empty string: the printer places the word
    call SVC_PUTS
    ; fall through: one delay for the whole word

; set_speed frames, counted as SVC_FRAMES changes (HALT is not a frame
; tick: the sample CTC wakes it). Corrupts AF, DE, HL.
ty_delay:
    ld a, (set_speed)
    ld (tycnt), a
.frame:
    call SVC_FRAMES                 ; HL = counter; corrupts AF, HL
    ld (tyfr), hl
.wait:
    call SVC_FRAMES
    ld de, (tyfr)
    or a
    sbc hl, de
    jr z, .wait
    ld hl, tycnt
    dec (hl)
    jr nz, .frame
    ret

; A = tychunk = min(tyrem, tywid); tyrem -= A. Corrupts F, E, HL.
ty_chunk:
    ld a, (tywid)
    ld hl, tyrem
    cp (hl)
    jr c, .set                      ; wider than the window: a full chunk
    ld a, (hl)
.set:
    ld (tychunk), a
    ld e, a
    ld a, (hl)
    sub e
    ld (hl), a
    ld a, e
    ret

; Setter table: min, max, target - one row per fn 32..38 in order.
settab:
    db 0, 31
    dw set_row                   ; 32 row
    db 0, 79
    dw set_col                   ; 33 column
    db 0, 80
    dw set_width                 ; 34 width, 0 = to end of row
    db 0, 255
    dw set_ink                   ; 35 ink
    db 0, 255
    dw set_paper                 ; 36 paper
    db 0, 2
    dw set_mode                  ; 37 mode
    db 1, 255
    dw set_speed                 ; 38 speed, 0 refused

; Stored settings (fns 32-38 write; fn 30 latches). Order matches the
; active set below for the 5-byte ldir.
set_row:    db 27
set_col:    db 0
set_width:  db 0
set_mode:   db 0
set_speed:  db 1
set_ink:    db 7
set_paper:  db 0
; Active set (fn 30 writes; the hook and fn 31 read)
row:        db 27
col:        db 0
width:      db 0
mode:       db 0
speed:      db 1
attr:       db 0                 ; resolved by each arm (SVC_PAIR); 0 = reserved default pair
; Runtime
armed:      db 0
cursor:     db 0                 ; feed index, stops at textlen
pos:        db 0                 ; typewriter column within the field
textlen:    db 0
count:      db 1                 ; frames until the next step
tail:       db 0                 ; blank steps still to feed (marquee)
ew:         db 0                 ; this frame's effective width
tylen:      db 0                 ; fn 39: message length
tyidx:      db 0                 ; fn 39: next character
tyend:      db 0                 ; fn 39: end of the current word
tywid:      db 0                 ; fn 39: window width (SVC_FITWORD's A)
tychunk:    db 0                 ; fn 39: glyphs left in this chunk
tyrem:      db 0                 ; fn 39: glyphs after this chunk
tycnt:      db 0                 ; fn 39: frames left in this delay
tyfr:       dw 0                 ; fn 39: frame counter snapshot
tyone:      db 0, 0              ; one-letter string; tyone+1 = ""
tyspc:      db " ", 0
text:       ds 256

; fn 39's copy of the message: 256 bytes of XBN scratch (xbnmod.inc claims).
tybuf:      equ XBN_SCRATCH + 768 + TRANSCRIPT_RING

    ENDMODULE

    IFNDEF XBN_MODULE
xbn_end:
    SAVEBIN "GAME.XBN", XBN_ORG, xbn_end - XBN_ORG
    XBN_SCRATCH_END
    ENDIF
