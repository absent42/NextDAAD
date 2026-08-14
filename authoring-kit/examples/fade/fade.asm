; fade.asm - NextDAAD XBN worked example: fade the Layer 2 picture to
; a colour and back. The narrative-storytelling device: fade the scene
; to black (or any RRRGGGBB colour) while the text window stays live,
; then fade back up.
;
; Author interface (from DSF):
;   EXTERN colour 40   start a fade OUT to `colour` (RRRGGGBB byte:
;                      0 = black, 255 = white, %11100000 = red, ...)
;   EXTERN 0 41        start a fade IN back to the original picture
;   flag 241           frames per fade step, 0 = default (6, so a fade
;                      is 8 steps x 6 frames, roughly one second) -
;                      the pass-parameters-via-flags idiom
;   flag 240           completion flag: cleared when a fade starts,
;                      set to 1 by the interrupt hook when it finishes;
;                      wait on it with a PAUSE or poll it
;
; Lifecycle (kept deliberately strict so the example stays honest):
;   fn 40 acts only from the fully-faded-IN state: it snapshots the
;   live palette, builds the interpolation tables, and runs to the
;   target. fn 41 acts only from the fully-faded-OUT state: it runs
;   back to the snapshot and then FORGETS it, so the next fn 40
;   re-snapshots whatever picture is on screen by then. Calls in any
;   other state are ignored - wait on flag 240 between fades.
;
; What this teaches beyond the ticker example:
;   - reading Next hardware state back (the palette is readable, dev
;     guide NR $41: "reads or writes 8-bit colour data")
;   - the register-select bracket: ALL hardware access here goes
;     through the $243B/$253B port pair, saving and restoring both the
;     select latch (port $243B is documented read/write) and NR $43
;     around every burst, because the interpreter's own foreground
;     code uses the same indexed interface and the #int hook can fire
;     in the middle of anything
;   - precompute in the foreground, keep the interrupt hook cheap: the
;     EXTERN call builds all nine 256-byte palette tables up front;
;     the 50Hz hook only ever streams one prebuilt table to the ports
;
; RULES this example obeys (see the externs chapter of the manual):
;   - do not fade while a PICTURE/DISPLAY is drawing or a video clip
;     is playing - the palette interface is shared with the
;     interpreter's foreground graphics machinery
;   - one XBN per game: to use fade AND ticker, merge the example
;     sources into one binary (their fn codes, 40/41 and 30/31, and
;     their flags do not overlap)

    DEVICE ZXSPECTRUMNEXT        ; required for SAVEBIN, matching the
                                 ; interpreter's own DEVICE line
    INCLUDE "xbn.inc"            ; build.ps1 passes the kit root as -I
    ORG XBN_ORG
    XBN_HEADER ext_main, int_fade

; ---- author-editable contract ----
FLAG_DONE       equ 240          ; 1 = fade complete, 0 = running
FLAG_SPEED      equ 241          ; frames per step, 0 = DEF_SPEED
DEF_SPEED       equ 6
STEPS           equ 8            ; 3-bit channels: 8 steps is full
                                 ; resolution, more would repeat frames

; ---- hardware (dev guide chapter "Ports and Registers" / "Palette") ----
TB_SELECT       equ $243B        ; TBBlue register select - documented RW,
                                 ; so the latch can be saved and restored
TB_ACCESS       equ $253B        ; TBBlue register access (select+1 in B)
NR_PAL_IDX      equ $40          ; colour index for read/write
NR_PAL_VAL      equ $41          ; 8-bit RRRGGGBB, reads AND writes
NR_PAL_CTL      equ $43          ; palette control - bit 7 DISABLES write
                                 ; auto-inc, bits 6-4 select the palette
                                 ; for editing, low bits select palettes
                                 ; for DISPLAY - hence the read-modify
                                 ; save/restore below, per the dev
                                 ; guide's own warning on this register
PAL_L2_EDIT     equ $10          ; edit Layer 2 first palette, auto-inc
                                 ; on - the interpreter's own standing
                                 ; convention value for this register

ext_main:
    ; Contract: A=B=param1, C=fn. This example uses C (fn) and, for
    ; fn 40, B (the target colour).
    ld a, (active)
    or a
    ret nz                       ; mid-fade: every call ignored; the
                                 ; author waits on FLAG_DONE
    ld a, c
    cp 40
    jr z, .fadeout
    cp 41
    ret nz                       ; not ours
    ; ---- fn 41: fade back in ----
    ld a, (valid)
    or a
    ret z                        ; nothing snapshotted: nothing to
                                 ; restore, ignore
    xor a
    ld (dir), a                  ; 0 = stepping DOWN towards step 0,
                                 ; the snapshot
    jr .go
.fadeout:
    ; ---- fn 40: snapshot, build tables, fade towards the target ----
    ld a, (valid)
    or a
    ret nz                       ; already faded out: re-fading out is
                                 ; a no-op; fade in first (fn 41)
    ld a, b
    ld (target), a
    call snapshot                ; live palette -> table 0
    call precalc                 ; tables 1-7 interpolated, 8 = solid
    ld a, 1
    ld (valid), a
    ld (dir), a                  ; 1 = stepping UP towards step 8
.go:
    ld a, (XBN_FLAGS+FLAG_SPEED)
    or a
    jr nz, .spdok
    ld a, DEF_SPEED
.spdok:
    ld (speed), a
    ld (count), a
    xor a
    ld (XBN_FLAGS+FLAG_DONE), a
    inc a
    ld (active), a               ; arm LAST - int_fade reads this first
    ret

; ---------------------------------------------------------------
; 50Hz hook: one cheap test when idle; when a fade is running, count
; down frames and stream the next prebuilt table when the interval
; expires. All the arithmetic happened in the foreground - the hook
; only moves bytes to ports.
int_fade:
    ld a, (active)
    or a
    ret z
    ld hl, count
    dec (hl)
    ret nz
    ld a, (speed)
    ld (hl), a                   ; reload the interval
    ld a, (dir)
    or a
    ld a, (step)
    jr z, .down
    inc a                        ; towards the solid target
    jr .adv
.down:
    dec a                        ; towards the snapshot
.adv:
    ld (step), a
    call apply                   ; stream table (step) to the palette
    ld a, (dir)
    or a
    ld a, (step)
    jr z, .chkin
    cp STEPS
    ret c                        ; still on the way out
    jr .done                     ; reached step 8: solid colour
.chkin:
    or a
    ret nz                       ; still on the way in
    ; reached step 0: the exact snapshot is back on screen. Forget it,
    ; so the next fn 40 re-snapshots whatever is displayed by then.
    ld (valid), a                ; a = 0
.done:
    xor a
    ld (active), a
    ld a, 1
    ld (XBN_FLAGS+FLAG_DONE), a
    ret

; ---------------------------------------------------------------
; Stream table A (0-8) to the Layer 2 first palette. Interrupt-context
; safe: the select latch ($243B, documented readable) and NR $43 are
; saved first and restored after, so a foreground register sequence
; this hook lands in the middle of resumes unharmed. Single-byte $41
; writes only - never the two-write $44 protocol, which could not be
; made atomic against the foreground.
apply:
    add a, tables>>8             ; tables are ALIGN 256: high byte + step
    ld h, a
    ld l, 0
    ld bc, TB_SELECT
    in a, (c)
    ld (savesel), a              ; foreground's selected register
    ld a, NR_PAL_CTL
    out (c), a
    inc b
    in a, (c)
    ld (savectl), a              ; foreground's palette control
    ld a, PAL_L2_EDIT
    out (c), a                   ; edit L2 first palette, auto-inc on
    dec b
    ld a, NR_PAL_IDX
    out (c), a
    inc b
    xor a
    out (c), a                   ; start at colour 0
    dec b
    ld a, NR_PAL_VAL
    out (c), a
    inc b                        ; BC stays $253B for the burst
    ld e, 0                      ; 256 iterations
.wr:
    ld a, (hl)
    out (c), a                   ; auto-inc advances the colour index
    inc l
    dec e
    jr nz, .wr
    dec b
    ld a, NR_PAL_CTL
    out (c), a
    inc b
    ld a, (savectl)
    out (c), a                   ; NR $43 back to what the foreground had
    dec b
    ld a, (savesel)
    out (c), a                   ; select latch back too
    ret

; ---------------------------------------------------------------
; Foreground only: read the live 256 Layer 2 colours into table 0.
; Reads do not auto-increment (the dev guide scopes auto-inc to
; writes), so the index register is set per colour.
snapshot:
    ld bc, TB_SELECT
    in a, (c)
    ld (savesel), a
    ld a, NR_PAL_CTL
    out (c), a
    inc b
    in a, (c)
    ld (savectl), a
    ld a, PAL_L2_EDIT
    out (c), a
    dec b
    ld hl, tables                ; table 0 = the snapshot
    ld e, 0
.rd:
    ld a, NR_PAL_IDX
    out (c), a
    inc b
    ld a, e
    out (c), a
    dec b
    ld a, NR_PAL_VAL
    out (c), a
    inc b
    in a, (c)
    dec b
    ld (hl), a
    inc l
    inc e
    jr nz, .rd
    ld a, NR_PAL_CTL
    out (c), a
    inc b
    ld a, (savectl)
    out (c), a
    dec b
    ld a, (savesel)
    out (c), a
    ret

; ---------------------------------------------------------------
; Foreground only: build tables 1-7 (linear interpolation between the
; snapshot and the target, per 3-bit channel) and table 8 (solid
; target). Done once per fade-out, so the interrupt hook never has to
; do arithmetic. RRRGGGBB channel k-lerp: out = s + (t-s)*k/8 with
; the division rounding towards minus infinity (arithmetic shifts) -
; endpoints are exact by construction (k=0 is the snapshot table
; itself, k=8 is written as the solid target).
precalc:
    ; table 8: every entry = the target colour
    ld a, (target)
    ld hl, tables + 8*256
    ld e, 0
.solid:
    ld (hl), a
    inc l
    dec e
    jr nz, .solid
    ; tables 1-7
    ld a, 1
.ktab:
    ld (kcur), a
    ld e, 0                      ; colour index
.entry:
    ld h, tables>>8              ; snapshot entry
    ld l, e
    ld a, (hl)
    ld (scur), a
    ; red: bits 7-5
    ld a, (scur)
    rlca
    rlca
    rlca
    and 7
    ld d, a
    ld a, (target)
    rlca
    rlca
    rlca
    and 7
    call lerp_ch                 ; A = lerped red 0-7
    rrca
    rrca
    rrca
    and %11100000
    ld (rcur), a
    ; green: bits 4-2
    ld a, (scur)
    rrca
    rrca
    and 7
    ld d, a
    ld a, (target)
    rrca
    rrca
    and 7
    call lerp_ch
    add a, a
    add a, a                     ; back to bits 4-2
    ld c, a
    ld a, (rcur)
    or c
    ld (rcur), a
    ; blue: bits 1-0
    ld a, (scur)
    and 3
    ld d, a
    ld a, (target)
    and 3
    call lerp_ch
    and 3                        ; channel is 2-bit here
    ld c, a
    ld a, (rcur)
    or c
    ld c, a
    ; store into table kcur
    ld a, (kcur)
    add a, tables>>8
    ld h, a
    ld l, e
    ld (hl), c
    inc e
    jr nz, .entry
    ld a, (kcur)
    inc a
    cp STEPS
    jr c, .ktab
    ret

; A = target channel value t, D = source channel value s, (kcur) = k.
; Out: A = s + (t-s)*k/8. Values are 0-7 (or 0-3 for blue - the same
; maths holds), k is 1-7, so the product fits comfortably in a signed
; byte and the result never leaves the s..t range.
lerp_ch:
    sub d                        ; t - s, signed
    ld l, a
    ld a, (kcur)
    ld b, a                      ; b = k (1-7)
    xor a
.mul:
    add a, l                     ; a += delta, k times
    djnz .mul
    ; divide by 8, rounding towards minus infinity
    sra a
    sra a
    sra a
    add a, d                     ; + s
    ret

; ---- state (all in this bank; nothing here survives save/load,
; which is correct - a fade is a transient display effect) ----
active:  db 0                    ; 1 while a fade is stepping
valid:   db 0                    ; 1 while the snapshot/tables are live
dir:     db 0                    ; 1 = fading out (up), 0 = in (down)
step:    db 0                    ; current step 0-8
speed:   db 0                    ; frames per step (resolved)
count:   db 0                    ; frames until the next step
target:  db 0                    ; RRRGGGBB fade target
savesel: db 0                    ; saved $243B select latch
savectl: db 0                    ; saved NR $43
kcur:    db 0                    ; precalc scratch
scur:    db 0
rcur:    db 0

    ALIGN 256
tables:  ds 9*256                ; 0 = snapshot, 1-7 = lerp, 8 = solid
xbn_end:

    SAVEBIN "GAME.XBN", XBN_ORG, xbn_end - XBN_ORG
