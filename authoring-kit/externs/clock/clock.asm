; clock.asm - NextDAAD XBN worked example: an in-game clock in the frame hook.
;
;   EXTERN 0 60    arm and start the clock, first call only - a repeat
;                  call while armed is a no-op, even if since stopped
;   EXTERN 0 61    stop it
;   EXTERN p 62    advance p in-game minutes, hour carry handled
;
; Flags 224 hours, 225 minutes, 226 running, 227/228 frames per in-game
; minute (16-bit), 244 days elapsed. The hook keeps ONLY the sub-minute
; frame residue in its own memory: the time itself lives in flags, so a LOAD
; restores it and the hook carries on with nothing to re-sync.

    IFNDEF XBN_MODULE
    DEVICE ZXSPECTRUMNEXT
    INCLUDE "xbn.inc"
    INCLUDE "xbnmod.inc"
    ORG XBN_ORG
    XBN_BEGIN clock.ext, clock.int
    ENDIF

    MODULE clock

FLAG_HH         equ 224
FLAG_MM         equ 225
FLAG_RUN        equ 226          ; 0 stopped, 1 running
FLAG_RATE       equ 227          ; frames per in-game minute, 16-bit at 227/228
FLAG_DAY        equ 244          ; days elapsed; rolls when the hour wraps

ext:
    ld a, b
    ld (param), a                ; park param1 before anything can clobber B
    ld a, c
    cp 60
    jp z, run
    cp 61
    jp z, stop
    cp 62
    jp z, advance
.notmine:
    or a                         ; CF clear: unrecognised fn, no failure
    ret

; fn 60 - arm and start. Arming is bank state: it survives RESTART, a part
; switch and a LOAD, so call it once from the start process - a repeat call
; while already armed is a no-op. A zero rate at first arm defaults to 50.
run:
    ld a, (armed)
    or a
    ret nz                       ; already armed: leave residue and RUN alone
    call SVC_FRAMES
    ld (lastFrames), hl          ; prime: the hook's first delta must count
                                 ; only frames since this arm, not since boot
    ld a, 1
    ld (armed), a
    ld hl, 0
    ld (residue), hl
    ld a, (XBN_FLAGS + FLAG_RATE)
    ld l, a
    ld a, (XBN_FLAGS + FLAG_RATE + 1)
    ld h, a
    ld a, h
    or l
    jr nz, .rateok
    ld a, 50
    ld (XBN_FLAGS + FLAG_RATE), a
    xor a
    ld (XBN_FLAGS + FLAG_RATE + 1), a
.rateok:
    ld a, 1
    ld (XBN_FLAGS + FLAG_RUN), a
    ret

; fn 61 - stop. The module stays armed; only the running flag clears, so the
; author can restart with a plain LET rather than another EXTERN.
stop:
    xor a
    ld (XBN_FLAGS + FLAG_RUN), a
    ret

; fn 62 - advance param1 in-game minutes. RUN cleared across the loop:
; tick_minute is shared with the hook, and an interrupt mid-loop interleaves
; two RMWs of mm/hh. The hook's RUN test is the lock; restore, do not set.
advance:
    ld a, (param)
    or a
    ret z
    ld b, a
    ld a, (XBN_FLAGS + FLAG_RUN)
    ld (runsave), a
    xor a
    ld (XBN_FLAGS + FLAG_RUN), a
.loop:
    call tick_minute
    djnz .loop
    ld a, (runsave)
    ld (XBN_FLAGS + FLAG_RUN), a
    or a                          ; CF clear: tick_minute's cp 60/cp 24 leaves
                                 ; CF set in the common case - fn 62 is an
                                 ; action and must not inherit it
    ret

; Adds one minute to flags 224/225 with the hour carry. Shared by fn 62 and
; the hook, so both agree about midnight.
tick_minute:
    ld a, (XBN_FLAGS + FLAG_MM)
    inc a
    cp 60
    jr c, .storemm
    xor a
    ld (XBN_FLAGS + FLAG_MM), a
    ld a, (XBN_FLAGS + FLAG_HH)
    inc a
    cp 24
    jr nc, .wrapday
    ld (XBN_FLAGS + FLAG_HH), a
    ret
.wrapday:
    xor a
    ld (XBN_FLAGS + FLAG_HH), a  ; hour zeroed BEFORE the day increments: an
    ld a, (XBN_FLAGS + FLAG_DAY) ; interrupt reading the flags between the two
    inc a                        ; stores UNDER-states the total, never over
    ld (XBN_FLAGS + FLAG_DAY), a
    ret
.storemm:
    ld (XBN_FLAGS + FLAG_MM), a
    ret

; Frame hook. Idle cost is one load and test, per the module contract. No
; services, no EI, no DMA - interrupt context.
int:
    ld a, (armed)
    or a
    ret z
    ; Re-prime BEFORE the RUN test (and before anything else can return
    ; early): a stopped clock must still track "now" every frame, so a
    ; later restart (fn 60's no-op path, or a plain LET 226 1) resumes
    ; from a fresh snapshot instead of bursting the whole stopped span.
    call SVC_FRAMES
    ld de, (lastFrames)
    ld (lastFrames), hl
    or a
    sbc hl, de                   ; HL = frames elapsed since the last pass
    ld (delta), hl               ; parked: RUN/rate tests below need A/D/E
    ld a, (XBN_FLAGS + FLAG_RUN)
    or a
    ret z
    ld a, (XBN_FLAGS + FLAG_RATE)
    ld e, a
    ld a, (XBN_FLAGS + FLAG_RATE + 1)
    ld d, a
    ld a, d                      ; rate 0 halts the clock outright - test it
    or e                         ; BEFORE touching residue, so a halted clock
    ret z                        ; accumulates nothing to burst on restart
    ld hl, (residue)
    ld bc, (delta)
    add hl, bc
    ld (residue), hl
.loop:                           ; while residue >= rate: residue -= rate;
    ld hl, (residue)             ; tick_minute - a multi-minute delta (a
    or a                         ; long blit, a paused hook) must tick the
    sbc hl, de                   ; right number of times, not just once.
    jr c, .done                  ; DE still holds rate: tick_minute (called
    ld (residue), hl             ; below) touches only A and flag memory,
    call tick_minute             ; so it never disturbs the cached rate.
    jr .loop
.done:
    ret

armed:      db 0
param:      db 0
runsave:    db 0
residue:    dw 0
lastFrames: dw 0
delta:      dw 0

    ENDMODULE

    IFNDEF XBN_MODULE
xbn_end:
    SAVEBIN "GAME.XBN", XBN_ORG, xbn_end - XBN_ORG
    XBN_SCRATCH_END
    ENDIF
