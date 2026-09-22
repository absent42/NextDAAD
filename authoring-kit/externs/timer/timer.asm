; timer.asm - NextDAAD XBN worked example: three countdown timers.
;
;   EXTERN 0 63    arm the module
;   EXTERN 0 64    stop all three timers
;   EXTERN d 65    slot d: convert its pair from a DURATION in minutes to an
;                  absolute deadline, and start it counting
;
; A real-seconds timer is armed by writing two flags, not by calling in:
;   LET 229 44 / LET 230 1   remaining = 1*256 + 44 = 300
;   LET 235 1                state 1 = running, counting real seconds
; State 2 counts in IN-GAME minutes instead: its pair holds an absolute
; deadline, not a countdown, so it needs EXTERN 65 to convert a duration into
; one. It also needs the clock module present and running; with no clock the
; day/hour/minute flags never change and a state-2 timer never expires.
; State 3 means expired.
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
FLAG_CLOCK_HH   equ 224          ; the clock's flags, watched but never
FLAG_CLOCK_MM   equ 225          ; written by this module
FLAG_CLOCK_DAY  equ 244

ST_IDLE         equ 0
ST_SECONDS      equ 1
ST_MINUTES      equ 2
ST_EXPIRED      equ 3

FRAMES_PER_SEC  equ 50           ; the hook is the 50Hz frame interrupt
    ASSERT (XBN_FLAGS & $FF) == 0 ; flag indexing below uses L alone (rubric 8)

ext:
    ld a, b
    ld (param), a                ; park param1 before any call clobbers B
    ld a, c
    cp 63
    jp z, arm
    cp 64
    jp z, stopall
    cp 65
    jp z, arm_minutes
.notmine:
    or a                         ; CF clear: unrecognised fn, no failure
    ret

; fn 63 - arm the module. Until this runs the hook ignores flags 229-237
; entirely, so an unused timer module costs the author nothing.
arm:
    ld hl, 0
    ld (frameAcc), hl
    call SVC_FRAMES
    ld (lastFrames), hl          ; prime: the hook's first delta must count
                                 ; only frames since this arm, not since boot
    ld a, 1
    ld (armed), a                ; armed set last: an interrupt before this
                                 ; point sees armed=0 and returns at once
    or a                         ; CF clear established here, not inherited
    ret                          ; from SVC_FRAMES' trailing or a

; fn 64 - stop all three. Each pair is left alone: a real-seconds count the
; author can inspect, or a minute deadline that stops being watched. Only the
; three states clear.
stopall:
    xor a
    ld (XBN_FLAGS + FLAG_STATE), a
    ld (XBN_FLAGS + FLAG_STATE + 1), a
    ld (XBN_FLAGS + FLAG_STATE + 2), a
    ret

; HL = day*1440 + hh*60 + mm, taken mod 65536. Monotonic so long as the day
; byte itself does not wrap (255 -> 0, 255 in-game days away - about 4 days
; 6 hours of play at the default rate);
; that wrap is a discontinuity, not an odometer step, so do not leave a
; minute timer armed across it. A LOAD moves the total consistently with any
; deadline stored in flags. MUL D,E is Z80N, ED 30, 8T.
clock_total:
    ld a, (XBN_FLAGS + FLAG_CLOCK_DAY)
    ld d, a
    ld e, 180
    mul d, e                     ; DE = day*180
    ex de, hl
    add hl, hl
    add hl, hl
    add hl, hl                   ; HL = day*1440
    ld a, (XBN_FLAGS + FLAG_CLOCK_HH)
    ld d, a
    ld e, 60
    mul d, e                     ; DE = hh*60
    add hl, de
    ld a, (XBN_FLAGS + FLAG_CLOCK_MM)
    ld e, a
    ld d, 0
    add hl, de
    ret

; Foreground callers use this, never clock_total directly - the hook can tick
; between its flag reads and a midnight tick would leave the total a day out.
clock_total_safe:
    call clock_total
    ld (cttemp), hl
    call clock_total
    ld de, (cttemp)
    or a
    sbc hl, de
    jr nz, clock_total_safe
    ld hl, (cttemp)
    ret

cttemp:  dw 0

; fn 65 - convert slot param1's pair from a DURATION in minutes to an absolute
; deadline, and set it counting. The pair holds a deadline from here on.
; Slot and total are parked in memory, not registers: this is foreground code
; and the register juggling is where an earlier draft of this plan went wrong.
; Re-arming a live slot sets it idle before touching the pair: the hook writes
; both bytes of a deadline in one interrupt-off breath, but this routine does
; not, so a tick between the high and low byte writes must not see state 2.
arm_minutes:
    ld a, (param)
    cp 3
    ret nc                       ; only slots 0-2 exist
    ld (armslot), a
    ld h, high XBN_FLAGS         ; page-aligned flags: L is the flag number
    add a, FLAG_STATE
    ld l, a
    ld (hl), ST_IDLE             ; quiesce first: closes the write-tear window
    call clock_total_safe        ; foreground: must be the retrying reader
    ld (armtotal), hl
    ld a, (armslot)
    add a, a
    add a, FLAG_REM
    ld h, high XBN_FLAGS
    ld l, a                      ; HL -> the slot's low byte
    ld e, (hl)
    inc l
    ld d, (hl)                   ; DE = the author's duration, HL -> high byte
    ld a, d
    and $80
    jr nz, .refuse                ; duration >= 32768: refuse, pair untouched
    push hl
    ld hl, (armtotal)
    add hl, de                   ; HL = deadline, wrapping mod 65536
    ex de, hl                    ; DE = deadline
    pop hl                       ; HL -> high byte
    ld (hl), d
    dec l
    ld (hl), e
    ld a, (armslot)
    add a, FLAG_STATE            ; 235 + 0..2: no carry, so CF is clear at ret
    ld l, a                      ; H is still the flags page
    ld (hl), ST_MINUTES          ; window closed above: safe to go live now
    ret
.refuse:
    scf                          ; CF set: duration out of range, nothing
    ret                          ; armed - documented meaning of the failure

armslot:  db 0
armtotal: dw 0

; Frame hook. Idle cost is one load and test. Interrupt context: no services,
; no EI, no DMA.
int:
    ld a, (armed)
    or a
    ret z
    ; Re-prime BEFORE anything else can return early: the accumulator must
    ; track "now" every frame, whether or not a second is due this pass.
    call SVC_FRAMES
    ld de, (lastFrames)
    ld (lastFrames), hl
    or a
    sbc hl, de                   ; HL = frames elapsed since the last pass
    ld de, (frameAcc)
    add hl, de
    ld (frameAcc), hl

    ; One real second per 50 accumulated frames - a loop, not a single
    ; test, so a multi-second delta (a paused hook resuming) steps every
    ; second it owes rather than just one.
.secloop:
    ld hl, (frameAcc)
    ld de, FRAMES_PER_SEC
    or a
    sbc hl, de
    jr c, .minutecheck
    ld (frameAcc), hl
    ld c, ST_SECONDS              ; C = which state this pass advances
    call step_all
    jr .secloop

; A minute timer expires when the clock's total reaches or passes its
; deadline. Wrap-safe: the difference is read as passed once it exceeds
; 32767, which covers any duration up to about 22 in-game days.
.minutecheck:
    ld a, (XBN_FLAGS + FLAG_STATE)
    cp ST_MINUTES
    jr z, .haveminutes
    ld a, (XBN_FLAGS + FLAG_STATE + 1)
    cp ST_MINUTES
    jr z, .haveminutes
    ld a, (XBN_FLAGS + FLAG_STATE + 2)
    cp ST_MINUTES
    ret nz                       ; no minute timer armed: three reads and out
.haveminutes:
    call clock_total
    ex de, hl                    ; DE = clock total
    ld b, 0                      ; B = slot
.mloop:
    ld h, high XBN_FLAGS
    ld a, FLAG_STATE
    add a, b
    ld l, a
    ld a, (hl)
    cp ST_MINUTES
    jr nz, .mnext
    ld a, b
    add a, a
    add a, FLAG_REM
    ld l, a                      ; HL -> the slot's low byte
    ld a, (hl)
    inc l
    ld h, (hl)
    ld l, a                      ; HL = deadline
    or a
    sbc hl, de                   ; HL = deadline - now
    jr z, .mexpire               ; reached exactly
    bit 7, h
    jr z, .mnext                 ; still in the future
.mexpire:
    ld h, high XBN_FLAGS
    ld a, FLAG_STATE
    add a, b
    ld l, a
    ld (hl), ST_EXPIRED
.mnext:
    inc b
    ld a, b
    cp 3
    jr c, .mloop
    ret

; Subtracts one from every timer whose state equals C, clamping at zero and
; expiring there. Corrupts all but C. No stack use: a frame-hook routine.
step_all:
    ld b, 0                      ; B = slot index 0..2
.slot:
    ld h, high XBN_FLAGS
    ld a, FLAG_STATE
    add a, b
    ld l, a
    ld a, (hl)
    cp c
    jr nz, .next
    ld a, b
    add a, a
    add a, FLAG_REM
    ld l, a                      ; HL -> the slot's low byte
    ld e, (hl)
    inc l
    ld d, (hl)                   ; DE = remaining
    ex de, hl                    ; HL = remaining, DE -> the high byte
    ld a, h
    or l
    jr z, .zero                  ; already 0: expired
    dec hl
    ld a, h
    or l
    jr z, .zero                  ; reached 0: expired
    ex de, hl                    ; HL -> high byte, DE = new remaining
    ld (hl), d
    dec l
    ld (hl), e
    jr .next
.zero:
    ex de, hl                    ; HL -> high byte
    ld (hl), 0
    dec l
    ld (hl), 0
    ld a, FLAG_STATE
    add a, b
    ld l, a                      ; H is still the flags page
    ld (hl), ST_EXPIRED
.next:
    inc b
    ld a, b
    cp 3
    jr c, .slot
    ret

armed:      db 0
frameAcc:   dw 0
lastFrames: dw 0
param:      db 0

    ENDMODULE

    IFNDEF XBN_MODULE
xbn_end:
    SAVEBIN "GAME.XBN", XBN_ORG, xbn_end - XBN_ORG
    XBN_SCRATCH_END
    ENDIF
