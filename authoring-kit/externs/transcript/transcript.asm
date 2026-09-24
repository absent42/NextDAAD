; transcript.asm - records typed lines and printed text to TRANS.TXT.
; Format 3 header (line + output hooks). fns 90-94. No flags. Bank
; state only: recording is a session activity, a LOAD is harmless.
    IFNDEF XBN_MODULE
    DEVICE ZXSPECTRUMNEXT
    INCLUDE "xbn.inc"
    INCLUDE "xbnmod.inc"
    ORG XBN_ORG
    XBN_BEGIN3 transcript.ext, transcript.int, transcript.line, transcript.out
    ENDIF
    MODULE transcript
TR_MIN_API      equ 3
TR_BUF          equ XBN_SCRATCH + 768
TR_BUFSZ        equ TRANSCRIPT_RING
INP_MAX         equ 127          ; mirrors the interpreter's frozen line length
; Output-tap cap: reserves the line hook's worst case ("\r" ">>" 127
; chars "\r" = INP_MAX+4) so a full ring still has room for the NEXT
; command's marker - the one guarantee the overflow design promises.
TR_OUTCAP       equ TR_BUFSZ - (INP_MAX+4)
    ASSERT TR_OUTCAP > 0, TR_OUTCAP not positive - TRANSCRIPT_RING too small

ext:
    ld a, c
    cp 90
    jr z, start
    cp 91
    jr z, stop
    cp 92
    jr z, query
    cp 93
    jp z, label
    cp 94
    jr z, setwin
    or a
    ret

; fn 90: EXTERN mode 90. bit 0: 0 = input only, 1 = full. bit 1: 1 =
; skip the SVC_GETDATE stamp (header reads "no-date" instead; the call
; derails ZEsarUX, so this bit keeps recording usable in the emulator).
; Creates the file, writes the header line. Condition: CF set when the
; file cannot be made.
start:
    call SVC_VERSION
    cp TR_MIN_API
    jr c, .fail
    ld a, b
    and 3
    ld (mode), a
    ld a, 255
    ld (winsel), a
    xor a
    ld (armed), a
    ld (errb), a
    ld hl, 0
    ld (tlen), hl
    ld (flen), hl
    ld (flen+2), hl
    ld ix, fname
    ld b, XBN_FMODE_W
    call SVC_FOPEN
    jr c, .fail
    call SVC_FCLOSE              ; A = handle; created and truncated
    call hdr_build
    call flush
    jr c, .fail
    ld a, 1
    ld (armed), a
    or a
    ret
.fail:
    scf
    ret

; fn 91: flush what is queued, disarm. Action.
stop:
    ld a, (armed)
    or a
    jr z, .done
    call flush
    xor a
    ld (armed), a
.done:
    or a
    ret

; fn 92: condition, CF clear while recording (a flush failure disarms).
query:
    ld a, (armed)
    or a
    ret nz                       ; CF clear from or
    scf
    ret

; fn 94: EXTERN w 94. Record window w only; 255 = every window.
setwin:
    ld a, b
    ld (winsel), a
    or a
    ret

; fn 93: EXTERN n 93. User message n as a "##" label line. Action.
label:
    ld a, (armed)
    or a
    jr z, .done
    ld a, b
    call SVC_GETMSG
    jr c, .done
    ld a, $0D
    call append
    ld a, '#'
    call append
    ld a, '#'
    call append
    ld a, b
    or c
    jr z, .eol
.cp:
    ld a, (hl)
    call append
    inc hl
    dec bc
    ld a, b
    or c
    jr nz, .cp
.eol:
    ld a, $0D
    call append
.done:
    or a
    ret

; Line hook: HL = line (resident), B = length. Queues newline, ">>",
; the line, newline, then flushes: the file always ends with the
; command about to run. Never consumes (CF clear).
line:
    ld a, (armed)
    or a
    ret z
    ld a, $0D
    call append
    ld a, '>'
    call append
    ld a, '>'
    call append
    ld a, b
    or a
    jr z, .eol
.cp:
    ld a, (hl)
    call append
    inc hl
    djnz .cp
.eol:
    ld a, $0D
    call append
    call flush                   ; failure disarms; the verdict stays clear
    or a
    ret

; Output tap: C = character. No service call here, ever.
out:
    ld a, (armed)
    or a
    ret z
    ld a, (mode)
    bit 0, a                     ; bit 1 (no-date) does not gate output
    ret z
    ld a, (winsel)
    cp 255
    jr z, .rec
    cp (ix+63)                   ; flag 63 = current window
    ret nz
.rec:
    ld a, c
    jp append_out

; A -> TR_BUF[tlen], tlen++; the sentinel '~' goes in once at the cap
; and the rest is dropped. Preserves BC, DE, HL. Two entries share this
; body: append (line, label - cap TR_BUFSZ) and append_out (the output
; tap - cap TR_OUTCAP, reserving the line hook's worst case so a full
; ring never costs the next command's marker).
append:
    push hl
    push de
    push af
    ld de, TR_BUFSZ-1
    jr append_cap
append_out:
    push hl
    push de
    push af
    ld de, TR_OUTCAP-1
append_cap:
    ld hl, (tlen)
    or a
    sbc hl, de
    jr c, .room                  ; tlen < cap-1
    jr nz, .full                 ; past the sentinel: drop
    pop af
    ld a, '~'
    push af
.room:
    ld hl, (tlen)
    ld de, TR_BUF
    add hl, de
    pop af
    ld (hl), a
    ld hl, (tlen)
    inc hl
    ld (tlen), hl
    pop de
    pop hl
    ret
.full:
    pop af
    pop de
    pop hl
    ret

; Writes TR_BUF[0..tlen) at offset flen: open RW, seek, write, close.
; A short count with CF clear is the seek-then-extend hazard: failure.
; Failure sets errb, clears armed, returns CF set. Resets tlen on success.
flush:
    ld hl, (tlen)
    ld a, h
    or l
    ret z                        ; nothing queued: CF clear
    ld ix, fname
    ld b, XBN_FMODE_RW
    call SVC_FOPEN
    jr c, .bad
    ld (fh), a
    ld bc, (flen+2)
    ld de, (flen)
    call SVC_FSEEK
    jr c, .badclose
    ld a, (fh)
    ld ix, TR_BUF
    ld bc, (tlen)
    call SVC_FWRITE
    jr c, .badclose
    ld hl, (tlen)
    or a
    sbc hl, bc
    jr nz, .badclose             ; short write
    ld hl, (flen)
    add hl, bc
    ld (flen), hl
    jr nc, .nocarry
    ld hl, (flen+2)
    inc hl
    ld (flen+2), hl
.nocarry:
    ld hl, 0
    ld (tlen), hl
    ld a, (fh)
    call SVC_FCLOSE
    or a
    ret
.badclose:
    ld a, (fh)
    call SVC_FCLOSE
.bad:
    ld a, 1
    ld (errb), a
    xor a
    ld (armed), a
    scf
    ret

; "## NextDAAD transcript YYYY-MM-DD HH:MM" + newline, or "no-rtc"
; (no RTC fitted), or "no-date" (mode bit 1: SVC_GETDATE not called).
hdr_build:
    ld de, hdr_text
    call put_str
    ld a, (mode)
    bit 1, a
    jr nz, .nodate
    call SVC_GETDATE
    jr c, .nortc
    push de                      ; MS-DOS time
    push bc                      ; MS-DOS date
    ld a, b
    srl a                        ; year - 1980 = date >> 9
    ld l, a
    ld h, 0
    ld de, 1980
    add hl, de
    call put_dec
    ld a, '-'
    call append
    pop bc
    ld a, c
    rlca
    rlca
    rlca
    and 7                        ; month low 3 bits = C >> 5
    bit 0, b
    jr z, .mon
    or 8
.mon:
    call put_dec2
    ld a, '-'
    call append
    ld a, c
    and 31                       ; day
    call put_dec2
    ld a, ' '
    call append
    pop de
    ld a, d
    srl a
    srl a
    srl a                        ; hour = time >> 11
    call put_dec2
    ld a, ':'
    call append
    ld a, e
    rlca
    rlca
    rlca
    and 7                        ; minute low 3 bits = E >> 5
    ld l, a
    ld a, d
    and 7
    rlca
    rlca
    rlca                         ; minute high 3 bits = (D & 7) << 3
    or l
    call put_dec2
    jr .nl
.nortc:
    ld de, nortc_text
    call put_str
    jr .nl
.nodate:
    ld de, nodate_text
    call put_str
.nl:
    ld a, $0D
    jp append

put_str:                         ; DE = ASCIIZ
    ld a, (de)
    or a
    ret z
    call append
    inc de
    jr put_str

put_dec2:                        ; A = 0..99, two digits
    ld b, '0'-1
.t:
    inc b
    sub 10
    jr nc, .t
    add a, 10
    push af
    ld a, b
    call append
    pop af
    add a, '0'
    jp append

put_dec:                         ; HL = 0..65535, no leading zeros
    ld c, 0                      ; bit 0: a digit has been emitted
    ld de, -10000
    call .dig
    ld de, -1000
    call .dig
    ld de, -100
    call .dig
    ld de, -10
    call .dig
    ld a, l
    add a, '0'
    jp append
.dig:
    ld a, '0'-1
.s:
    inc a
    add hl, de
    jr c, .s
    sbc hl, de                   ; undo the failing subtract
    cp '0'
    jr nz, .emit
    bit 0, c
    ret z                        ; leading zero: skip
.emit:
    set 0, c
    jp append

armed:      db 0
mode:       db 0
winsel:     db 255
errb:       db 0
fh:         db 0
flen:       ds 4                 ; running file length
tlen:       dw 0                 ; bytes queued in TR_BUF
fname:      db "TRANS.TXT", 0
hdr_text:   db "## NextDAAD transcript ", 0
nortc_text: db "no-rtc", 0
nodate_text: db "no-date", 0

int:
    ret                          ; no frame work; the chain calls this anyway

    ENDMODULE

    IFNDEF XBN_MODULE
xbn_end:
    SAVEBIN "GAME.XBN", XBN_ORG, xbn_end - XBN_ORG
    XBN_SCRATCH_END
    ENDIF
