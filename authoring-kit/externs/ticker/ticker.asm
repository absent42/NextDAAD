; ticker.asm - NextDAAD XBN worked example.
;
; Foreground: EXTERN n 30 fetches user message n (SVC_GETMSG) and arms
;             the ticker.
;             EXTERN 0 31 disarms it.
; Interrupt:  int emits one character per frame to the tilemap's
;             bottom row, wrapping, until the message is consumed. It
;             probes the live text width (NR $6B bit 6, see TM_ROW80
;             below) so it stays correct after a GFX n 18 mode switch.
;
; What this teaches: SVC_GETMSG's staging buffer is resident and shared
; with the rest of the interpreter - it is only valid until the NEXT
; service call, or across a save/load. An extern that needs the text to
; outlive the EXTERN call that fetched it (as this one does, since the
; #int hook reads it frame by frame long after ext has returned)
; MUST copy it into memory this XBN bank owns. That copy is the whole
; point of this example; everything else is bookkeeping around it.

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
TM_ROW80        equ $70E0        ; $6000 + 27*160
TM_ROW40        equ $6870        ; $6000 + 27*80

; Live width/row base probe: xbn_width (xbnmod.inc), called from int below.

; The interpreter's own reserved attribute for ordinary text: pair 0 =
; paper 0 (black), ink 7 (white) - src/nextdaad.inc's TM_ATTR_DEFAULT,
; the same value src/tilemap.asm's tm_clear_blank and txt_init paint
; every other cell with. A cleared attribute of 0 could easily have
; meant "black on black" instead; it does not, because pair 0 is
; reserved to be the default text look, not a blank slot. Confirmed
; against the interpreter source rather than assumed.
TICK_ATTR       equ 0

ext:
    ; Contract on entry: A=B=param1, C=fn, HL=flags+param1, DE=objTable
    ; +param1*6, IX=flags base. This example only needs C (fn) and,
    ; once fn=30 is confirmed, B (param1, the message number).
    ld a, c
    cp 30
    jr z, .arm
    cp 31
    jr nz, .notmine              ; any other fn: not ours
    xor a
    ld (armed), a                ; disarm - int checks this first,
                                 ; every frame, and does nothing else if
                                 ; it is 0
    ret                          ; CF clear (xor a above)
.arm:
    xor a
    ld (armed), a                ; disarm FIRST. Every way this can fail
                                 ; below (out of range, or an empty
                                 ; message) must leave the ticker OFF,
                                 ; not still running whatever the
                                 ; PREVIOUS successful arm left ticking -
                                 ; a failed re-arm is a clean stop, not a
                                 ; silent no-op.
    ld a, b                      ; param1 = user message number
    call SVC_GETMSG               ; out: HL=staging buffer, BC=length
    ret c                        ; out of range (A=$FF): stay disarmed
                                 ; (already zeroed above); CF stays SET:
                                 ; message unavailable - this EXTERN fails
    ld a, b                      ; B/C now hold SVC_GETMSG's returned
    or c                         ; length, not param1 any more
    ret z                        ; BC==0: an EMPTY message is a LEGAL
                                 ; result (CF stays clear - the first
                                 ; decoded byte was just the terminator),
                                 ; not an error, but it is NOT safe to
                                 ; fall through to ldir below. Z80's LDIR
                                 ; decrements BC AFTER each copy, so
                                 ; BC==0 does not mean "copy nothing" -
                                 ; it means "copy 65536 bytes", scribbling
                                 ; far past the 256-byte text buffer.
                                 ; Catch the zero-length case here, before
                                 ; ldir ever runs.
    ld de, text
    ld a, b                      ; length high byte: 0 for every length
    or a                         ; up to 255; 1 only for the one edge
    jr z, .lenok                 ; case SVC_GETMSG's contract allows,
    ld bc, 255                   ; BC==256 (the max). Clamp both the
                                 ; copy count and the stored length to
                                 ; 255 together so they agree - this demo
                                 ; ticker never shows a 256th character,
                                 ; which is a fine trade for staying
                                 ; simple.
.lenok:
    ld a, c
    ld (textlen), a
    ldir                         ; copy the staged text into OUR bank -
                                 ; see the file header comment for why
    xor a
    ld (cursor), a
    ld (column), a
    inc a
    ld (armed), a                ; arm last, once text/textlen are valid
    ret                          ; CF clear (xor a; inc/ld leave CF)
.notmine:
    or a                         ; CF clear: unrecognised fn, no failure
    ret

int:
    ; Runs once per frame (50Hz) for every game with an XBN loaded and
    ; an intEntry set, whether or not the ticker is armed - so this must
    ; stay CHEAP and return fast when idle. IX = flags base (unused
    ; here); the interpreter saves and restores full context around
    ; this call, so nothing needs preserving.
    ld a, (armed)
    or a
    ret z                        ; idle: one load-and-test, nothing else
    call SVC_BUSY
    bit 0, a
    ret nz                       ; clip playing: slot 3 is the audio
                                 ; ring - emit nothing, advance nothing
    ld a, (cursor)
    ld hl, textlen
    cp (hl)
    jr nc, .done                 ; consumed the whole message
    ; emit text[cursor] at the current column, at the LIVE text width
    ld e, a
    ld d, 0
    ld hl, text
    add hl, de
    ld a, (hl)                   ; character - GETMSG already decoded it
                                 ; to a plain printable byte (msg_probe,
                                 ; tests/xbn/xbntest.asm, established
                                 ; this - no translation needed here)
    ld (chr), a                  ; parked: the port read below needs BC,
                                 ; and the interpreter restores full
                                 ; context around this hook anyway
    call xbn_width               ; E = width, HL = row base (D unused)
.width:                          ; HL = row base, E = width in columns
    ld a, (column)
    cp e
    jr c, .colok
    xor a                        ; width shrank mid-message (GFX 1 18):
    ld (column), a               ; restart the row rather than write
                                 ; past its end
.colok:
    add a, a                     ; *2 bytes per tilemap cell
    ld d, 0
    push de                      ; E = width, still needed for the wrap
    ld e, a                      ; test after the emit
    add hl, de
    ld a, (chr)
    ld (hl), a
    inc hl
    ld a, TICK_ATTR
    ld (hl), a
    pop de
    ld hl, cursor
    inc (hl)
    ld hl, column
    inc (hl)
    ld a, (column)
    cp e                         ; wrap at the live width
    ret c
    xor a
    ld (column), a               ; wrap to the start of the row
    ret
.done:
    xor a
    ld (armed), a                ; disarm on completion - a finished
                                 ; ticker must not keep re-testing
                                 ; cursor >= textlen every frame forever,
                                 ; and a second EXTERN n 30 must be free
                                 ; to arm it again from a clean state
    ret

armed:   db 0
cursor:  db 0
column:  db 0
textlen: db 0
chr:     db 0                    ; this frame's character, parked across
                                 ; the width probe (which needs BC)
text:    ds 256

    ENDMODULE

    IFNDEF XBN_MODULE
xbn_end:
    SAVEBIN "GAME.XBN", XBN_ORG, xbn_end - XBN_ORG
    ENDIF
