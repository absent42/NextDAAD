; fade.asm - NextDAAD XBN worked example: fade the Layer 2 picture to
; a colour and back. The narrative-storytelling device: fade the scene
; to black (or any RRRGGGBB colour) while the text window stays live,
; then fade back up.
;
; Author interface (from DSF):
;   EXTERN colour 40   start a fade OUT to `colour` (RRRGGGBB byte:
;                      0 = black, 255 = white, %11100000 = red, ...)
;   EXTERN 0 41        start a fade IN back to the original picture
;   EXTERN 0 42        re-snapshot: the PICTURE changed while faded out
;   EXTERN 0 43        block until the running fade finishes
;   flag 241           frames per fade step, 0 = default (6, so a fade
;                      is 8 steps x 6 frames, roughly one second) -
;                      the pass-parameters-via-flags idiom
;   flag 240           completion flag: cleared when a fade starts,
;                      set to 1 by the interrupt hook when it finishes.
;                      fn 43 waits on it for you; poll it yourself only
;                      when the fade should overlap other work
;
; Lifecycle (kept deliberately strict so the example stays honest):
;   fn 40 acts only from the fully-faded-IN state: it snapshots the
;   live palette, builds the interpolation tables, and runs to the
;   target. fn 41 acts only from the fully-faded-OUT state: it runs
;   back to the snapshot and then FORGETS it, so the next fn 40
;   re-snapshots whatever picture is on screen by then. fn 42 also
;   acts only from the fully-faded-OUT state, and replaces the
;   snapshot without disturbing the target colour. Calls in any other
;   state are ignored - wait for the fade, with fn 43 or flag 240.
;
;   The snapshot is taken ONCE, when the fade out starts. That is why
;   changing the picture in between needs fn 42: without it the fade
;   in walks back to the palette of a picture that is no longer there.
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
NR_PAL_VAL9     equ $44          ; 9-bit colour, TWO writes: RRRGGGBB then
                                 ; a second byte holding bit 7 = Layer 2
                                 ; per-pixel priority and bit 0 = the blue
                                 ; LSB. Reading it returns that second byte
                                 ; and does NOT auto-increment the index
                                 ; (dev guide, NR $44). The interpreter
                                 ; loads Layer 2 art through this register,
                                 ; so a snapshot taken through $41 alone
                                 ; cannot round-trip a picture - it drops
                                 ; the blue LSB and the priority bit.
NR_PAL_CTL      equ $43          ; palette control - bit 7 DISABLES write
                                 ; auto-inc, bits 6-4 select the palette
                                 ; for editing, low bits select palettes
                                 ; for DISPLAY - hence the read-modify
                                 ; save/restore below, per the dev
                                 ; guide's own warning on this register
; NR $43 has two INDEPENDENT fields: bits 6-4 pick the bank that reads
; and writes land in, bit 2 picks the bank that is scanned out. The
; interpreter's standing convention is that both point at Layer 2's
; first bank, but it is only a convention - a picture load or a video
; clip can legitimately leave the second bank on screen.
;
; So never write a fixed value here. pal_edit_ctl derives the right one
; from whatever is already programmed: edit the bank that is being
; DISPLAYED, and leave the display bit exactly as found. Writing a
; constant $10 would drag the display back to bank 1 for the length of
; every burst, showing whatever stale palette bank 1 happened to hold.
PAL_L2_EDIT     equ $10          ; edit + display Layer 2 first bank
PAL_L2_EDIT2    equ $50          ; edit second bank, display bit untouched
PAL_CTL_DISP2   equ %00000100    ; NR $43 bit 2 = display the second bank
TRANSP          equ $E3          ; Layer 2 global transparency COLOUR
                                 ; (hardware reset value; the interpreter
                                 ; keeps it - src/nextdaad.inc's
                                 ; L2_TRANSP_COLOUR is the canonical
                                 ; definition, and index 255 is the
                                 ; designated hole-punch entry holding
                                 ; it). Transparency is a COLOUR compare
                                 ; on the entry's top 8 bits, so a fade
                                 ; must treat this value specially - see
                                 ; precalc's pin and dodge rules.

ext_main:
    ; Contract: A=B=param1, C=fn. This example uses C (fn) and, for
    ; fn 40, B (the target colour).
    ;
    ; Dispatch on the function code FIRST, with each function's own
    ; state guard inside its branch. An "ignore everything while a fade
    ; is active" test at the top would also swallow fn 43, whose entire
    ; job is to be called while a fade is active.
    ld a, c
    cp 40
    jr z, .fadeout
    cp 41
    jr z, .fadein
    cp 42
    jr z, .resnap
    cp 43
    jp z, wait_fade
    ret                          ; not ours
.fadein:
    ; ---- fn 41: fade back in ----
    ld a, (active)
    or a
    ret nz                       ; mid-fade: ignored; wait on FLAG_DONE
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
    ld a, (active)
    or a
    ret nz                       ; mid-fade: ignored; wait on FLAG_DONE
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
; fn 42: the PICTURE changed while we were faded out.
;
; The snapshot fn 40 took belongs to the picture that was on screen
; then, so a plain fn 41 would fade up to the OLD picture's colours on
; the NEW picture's pixels. Worse, DISPLAY 0 loads the new picture's
; palette as it flips (the interpreter's gfx_blit does both together),
; so the new scene appears at once, at full brightness, with no fade at
; all.
;
; This re-takes the snapshot from what DISPLAY just programmed, rebuilds
; the tables towards the SAME target colour, and puts that solid colour
; straight back on screen. The author then calls fn 41 to fade up to the
; new picture.
;
; Call it in the same process entry as the DISPLAY, so the two run
; inside one frame and the full-brightness flip is never displayed.
.resnap:
    ld a, (active)
    or a
    ret nz                       ; mid-fade: ignored
    ld a, (valid)
    or a
    ret z                        ; not faded out: nothing to re-take,
                                 ; and no target colour to hold
    ; ORDER MATTERS HERE. DISPLAY 0 leaves the new picture on screen at
    ; full brightness - the interpreter loads its palette immediately
    ; before the surface flip - so everything below is happening in
    ; plain view until the blank lands. precalc is seven interpolated
    ; tables of 256 entries with a multiply loop per channel: several
    ; frames of arithmetic. Running it before the blank showed the new
    ; scene for about 100ms, which reads as a bright flash between the
    ; fade out and the fade in.
    ;
    ; So: read the palette, blank, THEN do the slow part. The snapshot
    ; has to come first because it reads the very palette the blank
    ; overwrites, but it is only a few hundred port operations - well
    ; under a frame, where precalc is several.
    call snapshot                ; the NEW picture's live palette
    ld a, STEPS
    ld (step), a                 ; park at the solid end
    call apply                   ; blank NOW, with the solid table the
                                 ; previous fade out already built
    call precalc                 ; rebuild 1-7 and 8 from the new
                                 ; snapshot - slow, and now unseen
    ld a, STEPS
    jp apply                     ; restream the solid end so its
                                 ; transparency pins match the new art

; ---------------------------------------------------------------
; fn 43: block until the running fade finishes.
;
; The fade advances in the #int hook, which keeps running while
; foreground code sits in a HALT loop - so this simply waits, and the
; author gets a one-line alternative to polling FLAG_DONE through a
; DSF process loop. Returns immediately when no fade is running.
;
; Use the flag instead when the fade is meant to overlap something
; else: blocking here means nothing can print while the scene fades,
; which is the whole point of some fades.
;
; The wait is BOUNDED. A fade is 8 steps of (speed) frames, so the
; bound is that plus margin; if the hook were ever stopped mid-fade
; this returns rather than hanging the game forever.
wait_fade:
    ld a, (active)
    or a
    ret z                        ; nothing running
    ld a, (speed)
    ld l, a
    ld h, 0
    add hl, hl
    add hl, hl
    add hl, hl                   ; HL = 8 * speed
    ld de, 32                    ; + margin for the pickup frame
    add hl, de
.wl:
    ld a, (active)
    or a
    ret z                        ; finished: int_fade cleared it
    ld a, h
    or l
    ret z                        ; bound expired - give up, never hang
    dec hl
    halt                         ; one frame; the hook runs underneath
    jr .wl

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
    ; Reached step 0. apply has just streamed table 0, but only its
    ; 8-bit half: an $41 write re-derives the blue LSB as (B1 OR B0)
    ; and drops the priority bit, so the picture comes back a shade
    ; off. Measured on a red-heavy 256-colour photograph: red and
    ; green exact, blue 3.3% low - visible as a colour cast, not the
    ; "imperceptible" this example once claimed. Restream the
    ; endpoint as true 9-bit pairs, the only write that reproduces
    ; what the interpreter's own loader put there. One extra burst,
    ; on one frame, at the end of a fade-in.
    call apply9
    ; the snapshot is exactly back on screen. Forget it, so the next
    ; fn 40 re-snapshots whatever is displayed by then.
    xor a
    ld (valid), a
.done:
    xor a
    ld (active), a
    ld a, 1
    ld (XBN_FLAGS+FLAG_DONE), a
    ret

; ---------------------------------------------------------------
; savectl holds the NR $43 the foreground had when a burst started.
; Return the value that edits whichever bank is currently DISPLAYED,
; with every display-select bit left exactly as found and write
; auto-increment forced ON (bit 7 clear), which the bursts rely on.
; Corrupts AF only - BC is live in every caller.
pal_edit_ctl:
    ld a, (savectl)
    and %00001111                ; auto-inc on, edit field cleared, every
                                 ; display select preserved
    push af
    and PAL_CTL_DISP2
    jr z, .first
    pop af
    or PAL_L2_EDIT2              ; edit target = Layer 2 second bank
    ret
.first:
    pop af
    or PAL_L2_EDIT               ; edit target = Layer 2 first bank
    ret

; ---------------------------------------------------------------
; Stream table A (0-8) to the Layer 2 palette bank that is on screen.
; Interrupt-context safe: the select latch ($243B, documented readable)
; and NR $43 are saved first and restored after, so a foreground
; register sequence this hook lands in the middle of resumes unharmed.
; Single-byte $41 writes only - the 9-bit endpoint restore is apply9's
; job, and it has its own reason to be safe.
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
    call pal_edit_ctl
    out (c), a                   ; edit the bank being displayed
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
; Stream the snapshot back as TRUE 9-bit colours: table 0 supplies the
; RRRGGGBB byte, snap9 the second byte (priority + blue LSB). Same
; save/restore bracket as apply, and interrupt-context safe for the
; same reasons.
;
; The two-write $44 protocol is usable here despite being two writes:
; the dev guide's NR $43 entry states that writing $43 "will also reset
; the index of $44 so next write there will be considered as first byte
; of first colour". This burst writes $43 before its first $44 write,
; so the byte toggle is deterministically aligned whatever the
; foreground was doing.
;
; This does not weaken the standing rule below - do not fade while a
; PICTURE or DISPLAY is drawing. A foreground $44 pair interrupted by
; this burst is broken regardless, because the toggle is hardware state
; shared by both.
apply9:
    ld bc, TB_SELECT
    in a, (c)
    ld (savesel), a
    ld a, NR_PAL_CTL
    out (c), a
    inc b
    in a, (c)
    ld (savectl), a
    call pal_edit_ctl
    out (c), a                   ; edit the bank being displayed - and
                                 ; resets the $44 byte toggle
    dec b
    ld a, NR_PAL_IDX
    out (c), a
    inc b
    xor a
    out (c), a                   ; start at colour 0
    dec b
    ld a, NR_PAL_VAL9
    out (c), a
    inc b                        ; BC stays $253B for the burst
    ld hl, tables                ; byte 0 source (ALIGN 256)
    ld d, snap9>>8               ; byte 1 source page
    ld e, 0                      ; colour index / 256 iterations
.wr:
    ld a, (hl)
    out (c), a                   ; first write: RRRGGGBB
    push hl
    ld h, d
    ld l, e
    ld a, (hl)
    pop hl
    out (c), a                   ; second write: priority + blue LSB.
    inc l                        ; auto-inc advances the index AFTER the
    inc e                        ; second write (dev guide, NR $44)
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
; Foreground only: read the live 256 Layer 2 colours into table 0, and
; their second bytes into snap9. Reads do not auto-increment (the dev
; guide scopes auto-inc to writes), so the index register is set per
; colour and both reads see the same one.
snapshot:
    ld bc, TB_SELECT
    in a, (c)
    ld (savesel), a
    ld a, NR_PAL_CTL
    out (c), a
    inc b
    in a, (c)
    ld (savectl), a
    call pal_edit_ctl
    out (c), a                   ; edit the bank being displayed
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
    ld (hl), a                   ; byte 0: RRRGGGBB -> tables[0]
    ; Second byte (priority + blue LSB). The index has not moved -
    ; reads never auto-increment - so this is the same colour.
    ld a, NR_PAL_VAL9
    out (c), a
    inc b
    in a, (c)
    dec b
    push hl
    ld h, snap9>>8               ; snap9 is ALIGN 256, so the colour
    ld l, e                      ; index IS the low byte
    ld (hl), a
    pop hl
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
    ; table 8: every entry = the target colour. DODGE rule: a target of
    ; exactly the transparency colour would make the whole layer vanish
    ; (and "fade to transparent" is not this example's contract), so it
    ; is nudged one blue step to $E2 - visually identical, never
    ; transparent. The same nudge guards every interpolated value below.
    ld a, (target)
    cp TRANSP
    jr nz, .tgtok
    ld a, TRANSP ^ 1             ; $E2: one blue LSB off - imperceptible
.tgtok:
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
    ; PIN rule: an entry that IS the transparency colour is a punched
    ; hole (the interpreter's index-255 convention, and anything else
    ; the art left transparent). Holes must stay holes for the whole
    ; fade - fading one makes every cut-out turn opaque on the way out
    ; and pop back with a magenta flash on the way in (observed on the
    ; bench before this rule existed). Pin it to TRANSP in every table,
    ; including the solid table 8 written above.
    cp TRANSP
    jr nz, .lerp
    ld a, (kcur)
    ld b, a                      ; pin tables kcur..8 on the first pass
.pinall:                         ; (kcur=1): one walk covers 1-8; later
    ld a, b                      ; kcur passes re-pin harmlessly
    add a, tables>>8
    ld h, a
    ld l, e
    ld (hl), TRANSP
    inc b
    ld a, b
    cp STEPS + 1
    jr c, .pinall
    jp .next
.lerp:
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
    ; DODGE rule: an interpolated value may pass THROUGH the
    ; transparency colour even though neither endpoint equals it (the
    ; interpreter's palette loader keeps art off $E3, but lerp
    ; intermediates answer to nobody). One frame of see-through shimmer
    ; per crossing entry otherwise - nudge one blue step instead,
    ; the same dodge the interpreter's own art loader applies.
    ld a, c
    cp TRANSP
    jr nz, .store
    ld c, TRANSP ^ 1             ; $E2
.store:
    ; store into table kcur
    ld a, (kcur)
    add a, tables>>8
    ld h, a
    ld l, e
    ld (hl), c
.next:
    inc e
    jp nz, .entry                ; jp: the loop body outgrew jr range
    ld a, (kcur)
    inc a
    cp STEPS
    jp c, .ktab                  ; jp: spans the whole entry loop
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
    ALIGN 256                    ; already aligned (9*256), stated so the
                                 ; snap9>>8 / ld l,e indexing above cannot
                                 ; be broken by an edit above it
snap9:   ds 256                  ; second byte of each snapshotted colour:
                                 ; bit 7 = Layer 2 per-pixel priority,
                                 ; bit 0 = blue LSB. Only the fade-in
                                 ; endpoint uses it - the interpolated
                                 ; steps stay 8-bit, since nobody can see
                                 ; a blue LSB going past at 6 frames a step
xbn_end:

    SAVEBIN "GAME.XBN", XBN_ORG, xbn_end - XBN_ORG
