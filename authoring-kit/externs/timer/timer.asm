; timer.asm - NextDAAD XBN worked example: three countdown timers.
;
;   EXTERN 0 63    arm the module
;   EXTERN 0 64    stop all three timers
;
; A timer is armed by writing two flags, not by calling in:
;   LET 229 44 / LET 230 1   remaining = 1*256 + 44 = 300
;   LET 235 1                state 1 = running, counting real seconds
; State 2 counts in IN-GAME minutes instead, which needs the clock module
; present and running; with no clock, flag 225 never changes and a state-2
; timer simply does not advance. State 3 means expired.
;
; Remaining counts are 16-bit pairs because a byte caps a real-seconds timer
; at 255, and "you have five minutes" would not fit.

    IFNDEF XBN_MODULE
    DEVICE ZXSPECTRUMNEXT
    INCLUDE "xbn.inc"
    INCLUDE "xbnmod.inc"
    ORG XBN_ORG
    XBN_BEGIN timer.ext, timer.int
    ENDIF

    MODULE timer

FLAG_REM        equ 229          ; 3 pairs: 229/230, 231/232, 233/234
FLAG_STATE      equ 235          ; 3 bytes: 235, 236, 237
FLAG_CLOCK_HH   equ 224          ; the clock's hour and minute flags, watched
FLAG_CLOCK_MM   equ 225          ; but never written by this module

ST_IDLE         equ 0
ST_SECONDS      equ 1
ST_MINUTES      equ 2
ST_EXPIRED      equ 3

FRAMES_PER_SEC  equ 50           ; the hook is the 50Hz frame interrupt

ext:
    ld a, c
    cp 63
    jp z, arm
    cp 64
    jp z, stopall
    ret

; fn 63 - arm the module. Until this runs the hook ignores flags 229-237
; entirely, so an unused timer module costs the author nothing.
arm:
    xor a
    ld (frames), a
    ld a, (XBN_FLAGS + FLAG_CLOCK_HH)
    ld (lasthh), a
    ld a, (XBN_FLAGS + FLAG_CLOCK_MM)
    ld (lastmm), a
    ld a, 1
    ld (armed), a                ; armed set last: an interrupt before this
    ret                          ; point sees armed=0 and returns at once

; fn 64 - stop all three. Leaves each remaining count alone so the author can
; inspect it; only the states clear.
stopall:
    xor a
    ld (XBN_FLAGS + FLAG_STATE), a
    ld (XBN_FLAGS + FLAG_STATE + 1), a
    ld (XBN_FLAGS + FLAG_STATE + 2), a
    ret

; Frame hook. Idle cost is one load and test. Interrupt context: no services,
; no EI, no DMA.
int:
    ld a, (armed)
    or a
    ret z

    ; One real second every 50 frames.
    ld a, (frames)
    inc a
    cp FRAMES_PER_SEC
    jr c, .nosecond
    xor a
    ld (frames), a
    ld a, 1
    ld (delta), a                ; one second per pass
    ld c, ST_SECONDS             ; C = which state this pass advances
    call step_all
    jr .minutecheck
.nosecond:
    ld (frames), a

.minutecheck:
    ; Elapsed minutes from BOTH clock flags. Minutes alone would see only
    ; (jump mod 60), charging 30 for fn 62's 90-minute sleep and 0 for a
    ; 60-minute one. No coupling: with no clock neither flag moves.
    ld a, (XBN_FLAGS + FLAG_CLOCK_HH)
    ld d, a
    ld e, 60
    mul d, e                     ; DE = hh*60, Z80N ED 30, 8T
    ld a, (XBN_FLAGS + FLAG_CLOCK_MM)
    ld l, a
    ld h, 0
    add hl, de                   ; HL = minutes since midnight, now
    push hl
    ld a, (lasthh)
    ld d, a
    ld e, 60
    mul d, e
    ld a, (lastmm)
    ld l, a
    ld h, 0
    add hl, de                   ; HL = the same, last frame
    ex de, hl
    pop hl
    or a
    sbc hl, de                   ; HL = elapsed minutes
    ret z                        ; clock did not move
    jr nc, .nowrap
    ld de, 1440
    add hl, de                   ; crossed midnight
.nowrap:
    ld a, (XBN_FLAGS + FLAG_CLOCK_HH)
    ld (lasthh), a
    ld a, (XBN_FLAGS + FLAG_CLOCK_MM)
    ld (lastmm), a
    ld a, h                      ; nonzero H = 256+ minutes or a backwards
    or a                         ; jump - never legitimate (fn 62 caps at
    ret nz                       ; 255); re-baselined above, charge nothing
    ld a, l
    ld (delta), a
    ld c, ST_MINUTES
    ; fall through to step_all

; Subtracts (delta) from every timer whose state equals C, clamping at zero
; and expiring there. Corrupts all but C. Two pushes per matching slot, popped
; on BOTH exits - an unbalanced push in a frame hook corrupts the ISR's stack.
step_all:
    ld b, 0                      ; B = slot index 0..2
.slot:
    push bc
    ld hl, XBN_FLAGS + FLAG_STATE
    ld d, 0
    ld e, b
    add hl, de
    ld a, (hl)
    cp c
    jr nz, .next
    push hl                      ; [1] this slot's state flag
    ld hl, XBN_FLAGS + FLAG_REM
    ld d, 0
    ld e, b
    add hl, de
    add hl, de                   ; remaining pair is at FLAG_REM + slot*2
    push hl                      ; [2] pointer to its low byte
    ld e, (hl)
    inc hl
    ld d, (hl)                   ; DE = remaining
    ld a, (delta)
    ld l, a
    ld h, 0
    ex de, hl                    ; HL = remaining, DE = delta
    or a
    sbc hl, de                   ; underflow or zero both mean expired
    jr c, .zero
    ld a, h
    or l
    jr z, .zero
    pop de                       ; [2] pointer
    ex de, hl                    ; HL = pointer, DE = new remaining
    ld (hl), e
    inc hl
    ld (hl), d
    pop hl                       ; [1] discard
    jr .next
.zero:
    pop hl                       ; [2] pointer
    ld (hl), 0
    inc hl
    ld (hl), 0
    pop hl                       ; [1] state flag
    ld (hl), ST_EXPIRED
.next:
    pop bc
    inc b
    ld a, b
    cp 3
    jr c, .slot
    ret

armed:   db 0
frames:  db 0
lasthh:  db 0
lastmm:  db 0
delta:   db 1

    ENDMODULE

    IFNDEF XBN_MODULE
xbn_end:
    SAVEBIN "GAME.XBN", XBN_ORG, xbn_end - XBN_ORG
    XBN_SCRATCH_END
    ENDIF
