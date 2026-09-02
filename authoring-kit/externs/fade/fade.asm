; fade.asm - NextDAAD XBN worked example: fade the Layer 2 picture to
; a colour and back. The narrative-storytelling device: fade the scene
; to black (or any RRRGGGBB colour) while the text window stays live,
; then fade back up.
;
; Author interface (from DSF):
;   EXTERN colour 40   start a fade OUT to `colour` (RRRGGGBB byte:
;                      0 = black, 255 = white, %11100000 = red, ...).
;                      Refused while another module holds the palette:
;                      no fade runs and flag 240 is set to 1.
;   EXTERN 0 41        start a fade IN back to the original picture
;   EXTERN 0 42        re-snapshot the STAGED palette (buffer mode
;                      only): the PICTURE changed while faded out. Also
;                      solids BOTH Layer 2 palette banks, so a following
;                      GFX 0 2 reveal (below) is invisible.
;   EXTERN 0 43        block until the running fade finishes
;   flag 241           frames per fade step, 0 = default (6, so a fade
;                      is 8 steps x 6 frames, roughly one second) -
;                      the pass-parameters-via-flags idiom
;   flag 240           completion flag: cleared when a fade starts,
;                      set to 1 by the interrupt hook when it finishes.
;                      fn 43 waits on it for you; poll it yourself only
;                      when the fade should overlap other work
;
;   The three lines below are interpreter condacts (GFX, condact 87),
;   not part of this extern, but fn 42 exists to pair with them:
;   GFX 0 4            open Layer 2 buffer mode: drawing and DISPLAY
;                      target the hidden surface only, screen
;                      untouched. Transient only - a bracket for one
;                      scene change, always closed with GFX 0 3 after
;                      the reveal, never left set across a room/turn
;                      boundary.
;   GFX 0 2            reveal: flips the buffered surface onto screen.
;                      Pair with fn 42 first (above) so both palette
;                      banks are already solid and the flip is
;                      invisible.
;   GFX 0 3            close buffer mode: drawing and DISPLAY target
;                      the screen again
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
;   - reading the live palette back through the interpreter's own
;     service (SVC_PALREAD), which reads either Layer 2 bank on request
;   - the register-select bracket: ALL hardware access here goes
;     through the $243B/$253B port pair, saving and restoring both the
;     select latch (port $243B is documented read/write) and NR $43
;     around every burst, because the interpreter's own foreground
;     code uses the same indexed interface and the #int hook can fire
;     in the middle of anything
;   - precompute in the foreground, keep the interrupt hook cheap: the
;     EXTERN call builds all eighteen 256-byte palette tables up front;
;     the 50Hz hook only ever streams one prebuilt pair to the ports
;   - interpolating at the depth the hardware actually has, not the
;     depth its convenience register offers. Blue is 3 bits like red
;     and green, but the packed RRRGGGBB byte carries only its top
;     two and $41 derives the third as B2 OR B1 - four levels. Lerping
;     the packed byte therefore moved blue in steps twice the size of
;     red's, and floor division put the error on both sides of the
;     true ramp: fading in, blue stayed black two steps longer, then
;     overshot red at step 5. Every step is streamed as a $44 pair
;     instead, so all three channels walk the same eight levels
;
; RULES this example obeys (see the externs chapter of the manual):
;   - do not fade while a PICTURE/DISPLAY is drawing or a video clip
;     is playing, or while GFX 0 2/0 3 (the reveal subs) are running -
;     the palette interface is shared with the interpreter's
;     foreground graphics machinery. A still-stepping fade overlapping
;     GFX n 2 can land the interrupt hook's apply mid-mirror, and its
;     NR $43 write resets the NR $44 byte toggle mid-pair, corrupting
;     one mirrored palette entry. Wait on fn 43 or flag 240 first.
;     Moving the steps from $41 to $44 pairs does NOT widen this
;     exposure, tempting as it is to assume it does. The damage to a
;     foreground sequence is done by the NR $43 write that opens and
;     closes every burst, and both kinds of burst have always made it.
;   - one XBN per game: to use fade with other collection externs use
;     the prebuilt all/GAME.XBN or an EXTERNS.BAT subset build; fn
;     codes and flags are disjoint across the collection
;
; INTERPRETER DEPENDENCIES
; ------------------------
; Things this extern relies on that are NOT part of the frozen XBN
; contract. The XBN API and the flag/object anchors never move; these
; are ordinary interpreter internals that may change in any release.
; When a future interpreter breaks this extern, start here - and note
; that the fix belongs in THIS file, not in the interpreter.
;
;   1. DISPLAY 0 programs the new picture's palette as it swaps
;      surfaces - unless GFX 87 sub 4 (buffer mode, "GFX 0 4" in DSF)
;      is open, in which case DISPLAY 0 stages pixels and palette into
;      the hidden surface only and does not swap; the swap and reveal
;      wait for GFX 87 sub 2 ("GFX 0 2"). fn 42 exists because of this:
;      it re-takes the snapshot from the STAGED palette and solids the
;      hidden bank so the GFX 0 2 reveal is invisible.
;
;      THE scene-change sequence (buffered, zero-window reveal):
;        EXTERN 0 40        ; fade out to the target colour
;        EXTERN 0 43        ; wait
;        PICTURE @room      ; CONDITION - aborts the entry on missing
;                           ; art, leaving the draw target untouched
;        GFX 0 4            ; open buffer mode - AFTER the PICTURE
;                           ; condition, so a failing PICTURE never
;                           ; strands buffer mode with GFX 0 3 unreached
;        DISPLAY 0          ; pixels + palette staged; screen untouched
;        EXTERN 0 42        ; read the staged palette, rebuild tables,
;                           ; solid into both banks
;        GFX 0 2            ; reveal: flip surface; all palettes solid
;        GFX 0 3            ; close buffer mode; drawing targets the
;                           ; screen again
;        EXTERN 0 41        ; fade up to the new picture
;        EXTERN 0 43
;
;      Buffer mode is REQUIRED, not an optimisation: fn 42 reads the
;      bank the display is not showing, and only buffer mode stages the
;      new picture's palette there.
;
;      IF IT CHANGES so that DISPLAY leaves the palette alone until
;      asked, fn 42 becomes unnecessary and fn 41 can fade straight up
;      to the new picture.
;
;   2. The transparency convention: Layer 2 colour $E3 (TRANSP below)
;      and palette index 255 are reserved for punched holes, and the
;      interpreter's art loader keeps real art off that value.
;      USED BY: precalc's pin and dodge rules.
;      IF IT CHANGES: TRANSP here must change with
;      src/nextdaad.inc's L2_TRANSP_COLOUR or holes will seal over
;      mid-fade.
;
;   3. Layer 2 art is displayed through the Layer 2 palette, with edit
;      and display parked on the SAME bank between operations.
;      USED BY: the WRITE paths, pal_edit_ctl and its sibling
;      pal_other_ctl, which read NR $43 and follow whichever bank is
;      live. The READ path is SVC_PALREAD's and derives the same thing
;      inside the interpreter.

; Standalone build emits its own header and binary; a combined build
; defines XBN_MODULE and supplies both.
    IFNDEF XBN_MODULE
    DEVICE ZXSPECTRUMNEXT
    INCLUDE "xbn.inc"
    INCLUDE "xbnmod.inc"
    ORG XBN_ORG
    XBN_BEGIN fade.ext, fade.int
    ENDIF

    MODULE fade

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
NR_PAL_VAL      equ $41          ; 8-bit RRRGGGBB, reads AND writes. The
                                 ; byte's two blue bits are the TOP two of
                                 ; the hardware's 3-bit blue (the dev guide
                                 ; names them B2 and B1), and it fills in
                                 ; the third itself: "Least significant bit
                                 ; of blue is set to OR between B2 and B1".
                                 ; So this register can only express blue
                                 ; 0, 3, 5 and 7 of 8 - four levels against
                                 ; red and green's eight, which is why the
                                 ; fade interpolates through $44 instead
                                 ; (see precalc and int).
                                 ; A write here also ZEROES the entry's
                                 ; priority bits: the core issues the same
                                 ; palette write as a $44 pair does but
                                 ; drives the priority field to 0, and its
                                 ; own register list says "any other bits
                                 ; associated with the index will be
                                 ; zeroed". That is settled, not assumed -
                                 ; int leans on it at the solid end.
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
TRANSP_DODGE    equ TRANSP+4     ; substitute for a collision: one step
                                 ; up the green field ($E7), matching
                                 ; the interpreter's l2_palette_load
                                 ; dodge (L2_TRANSP_DODGE). +4 is a
                                 ; green step only while TRANSP's green
                                 ; field is 000 - asserted:
    ASSERT (TRANSP & %00011100) == 0

ext:
    ; Contract: A=B=param1, C=fn. This example uses C (fn) and, for
    ; fn 40, B (the target colour).
    ;
    ; Dispatch on the function code FIRST, with each function's own
    ; state guard inside its branch. An "ignore everything while a fade
    ; is active" test at the top would also swallow fn 43, whose entire
    ; job is to be called while a fade is active.
    ;
    ; fns 40-43 are ACTIONS: every exit returns CF CLEAR. CF set fails
    ; the DAAD entry, which inside a GFX 0 4 .. GFX 0 3 bracket would
    ; strand buffer mode.
    ld a, c
    cp 40
    jr z, .fadeout
    cp 41
    jr z, .fadein
    cp 42
    jr z, .resnap
    cp 43
    jp z, wait_fade
.notmine:
    or a                         ; CF clear: unrecognised fn, no failure
    ret
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
    ld a, 1
    call xbn_pal_acquire         ; held from here until a fade IN ends
    jr c, .refused
    ld a, (active)
    or a
    ret nz                       ; mid-fade: ignored; wait on FLAG_DONE
    ld a, (valid)
    or a
    ret nz                       ; already faded out: re-fading out is
                                 ; a no-op; fade in first (fn 41)
    ld a, b
    ld (target), a
    xor a
    call snap_via_service        ; displayed bank -> table 0
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
    ld (active), a               ; arm LAST - int reads this first
    ret
.refused:
    ; Palette held by another module. Still an ACTION, and flag 240 must
    ; not promise a completion that never comes - fn 43 and a polling
    ; author would both wait forever on a 0.
    ld a, 1
    ld (XBN_FLAGS+FLAG_DONE), a  ; "nothing to wait for"
    or a
    ret

; ---------------------------------------------------------------
; fn 42: the PICTURE changed while we were faded out.
;
; The snapshot fn 40 took belongs to the old picture, so a plain fn 41
; would fade up to the OLD colours on the NEW pixels. This re-takes the
; snapshot from the palette DISPLAY 0 staged in the bank the display is
; not showing (SVC_PALREAD A=1), rebuilds the tables towards the SAME
; target colour, and solids that colour into both banks so the GFX 0 2
; reveal shows nothing. The author then calls fn 41 to fade up.
;
; Buffer mode (GFX 0 4) is required: nothing else stages the new
; picture's palette in the other bank.
.resnap:
    ld a, (active)
    or a
    ret nz                       ; mid-fade: ignored
    ld a, (valid)
    or a
    ret z                        ; not faded out: nothing to re-take,
                                 ; and no target colour to hold
    ; Blank FIRST, read second. The read takes the STAGED bank
    ; (SVC_PALREAD A=1), so nothing it does can widen a visible band.
    ld a, STEPS
    ld (step), a                 ; park at the solid end
    call apply                   ; BLANK NOW - one burst, nothing before
                                 ; it, using the solid table the previous
                                 ; fade out already built
    ld a, 1
    call snap_via_service        ; the NEW picture's palette, staged bank
    call precalc                 ; rebuild 1-7 and 8 - slow, and unseen
    ld a, STEPS
    call apply                   ; restream the solid end so its
                                ; transparency pins match the new art
    ; applyOther is only ever set here, briefly, and fn 42 itself only
    ; runs while active=0 (checked above) - so the interrupt hook's own
    ; apply calls (which run only while active=1) can never observe
    ; applyOther=1.
    ld a, 1
    ld (applyOther), a
    ld a, STEPS
    call apply                   ; solid into the HIDDEN bank too: at the
                                ; GFX n 2 reveal every palette the beam
                                ; can see then holds the fade colour.
                                ; 8-bit-only is deliberate - both banks
                                ; get the identical table, so the
                                ; derived 9-bit values match and the
                                ; reveal's mirror copy is write-of-
                                ; identical. Do not "fix" to apply9.
    xor a
    ld (applyOther), a
    ret

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
;
; The wait gates on SVC_FRAMES. HALT is only a wakeup - a sampled sound
; effect's per-sample CTC interrupt wakes it at the WAV rate - so the
; frame-counter compare, not the wakeup, steps the bound.
; Never-hang guard = the BC bound; a frozen frame counter means the
; interpreter ISR is dead (Ruling: TICK_CEILING dropped).
wait_fade:
    ld a, (active)
    or a
    jr z, .done                  ; nothing running
    ld a, (speed)
    ld l, a
    ld h, 0
    add hl, hl
    add hl, hl
    add hl, hl                   ; HL = 8 * speed
    ld de, 32                    ; + margin for the pickup frame
    add hl, de
    ld b, h
    ld c, l                      ; bound in BC: SVC_FRAMES returns HL
    call SVC_FRAMES
    ld e, l                      ; E = frame counter low byte
.wl:
    ld a, (active)
    or a
    jr z, .done                  ; finished: int cleared it
    dec bc
    ld a, b
    or c
    jr z, .done                  ; bound spent: never hang
.edge:
    halt                         ; a wakeup only - the compare gates
    ld a, (active)
    or a
    jr z, .done                  ; finished under us: done waiting
    call SVC_FRAMES
    ld a, l
    cp e
    jr z, .edge                  ; same frame: keep waiting
    ld e, l                      ; a real frame passed
    jr .wl
.done:
    or a                         ; CF clear: fn 43 is an action
    ret

; ---------------------------------------------------------------
; 50Hz hook: one cheap test when idle; when a fade is running, count
; down frames and stream the next prebuilt table when the interval
; expires. All the arithmetic happened in the foreground - the hook
; only moves bytes to ports.
int:
    ld a, (active)
    or a
    ret z
    ; Before the step advances, not after: another module holding the
    ; palette means skip the whole frame, count and step untouched.
    ld a, 1
    call xbn_pal_check
    ret c
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
    cp STEPS
    jr nz, .step9
    ; The solid end is streamed 8-bit, deliberately. fn 42 puts this
    ; same table into BOTH palette banks through the same 8-bit path so
    ; the GFX n 2 reveal's mirror copy is write-of-identical; routing it
    ; through apply9 here would make the two banks disagree in the blue
    ; LSB. It costs nothing: step 8 is one flat colour, exactly the byte
    ; the author asked for, and there is no ramp left to quantise.
    ;
    ; It also settles where the priority bit goes, and in the direction
    ; you want. Steps 0-7 carry the picture's own priority bits, so a
    ; priority colour keeps its standing over the text window for as
    ; long as the picture is still visible; this 8-bit write zeroes them,
    ; so the fully-faded solid colour sits UNDER the live text window,
    ; which is the whole point of fading with the window still up.
    call apply
    jr .chkdir
.step9:
    call apply9                  ; steps 0-7: true 9-bit pairs, so blue
                                 ; interpolates on all three of its bits
.chkdir:
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
    ; Reached step 0, and apply9 has just streamed the snapshot as true
    ; 9-bit pairs - blue LSB and priority bit included, the only write
    ; that reproduces what the interpreter's own loader put there. The
    ; endpoint is exact by construction now that every step takes that
    ; path; it used to need a second closing burst here because the
    ; steps were 8-bit and landed the picture a measured 3.3% low in
    ; blue. The snapshot is exactly back on screen, so forget it and let
    ; the next fn 40 re-snapshot whatever is displayed by then.
    xor a
    ld (valid), a
    ld a, 1
    call xbn_pal_release         ; the ONLY release: fade-in complete, so
                                 ; nothing is held any more (owner's own
                                 ; hook, which the interlock allows)
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
; pal_edit_ctl's sibling: edit the bank that is NOT being displayed,
; display bit again untouched. Reached from pal_apply_ctl for fn 42's
; both-banks-solid step. Corrupts AF only.
pal_other_ctl:
    ld a, (savectl)
    and %00001111
    push af
    and PAL_CTL_DISP2
    jr z, .disp1
    pop af
    or PAL_L2_EDIT               ; bank 2 displayed -> edit bank 1
    ret
.disp1:
    pop af
    or PAL_L2_EDIT2              ; bank 1 displayed -> edit bank 2
    ret

; apply targets the displayed bank normally, the hidden one when
; applyOther is set (fn 42's both-banks-solid step). Corrupts AF only.
pal_apply_ctl:
    ld a, (applyOther)
    or a
    jp nz, pal_other_ctl
    jp pal_edit_ctl

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
; Stream table A (0-8) to the Layer 2 palette bank that is on screen,
; or the hidden one when applyOther is set (fn 42's both-banks-solid
; step - see pal_apply_ctl). Interrupt-context safe: the select latch
; ($243B, documented readable) and NR $43 are saved first and restored
; after, so a foreground register sequence this hook lands in the
; middle of resumes unharmed.
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
    call pal_apply_ctl
    out (c), a                   ; edit the displayed bank, or the
                                 ; hidden one when applyOther is set
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
; Stream table A (0-7) as TRUE 9-bit colours: page A of tables supplies
; the RRRGGGBB byte, page A of tables9 the second byte (priority + blue
; LSB). Same save/restore bracket as apply, and interrupt-context safe
; for the same reasons.
;
; This is the fade's normal path - every step but the solid one goes
; through here, because blue cannot be interpolated at 3-bit depth
; through $41 (see NR_PAL_VAL above). Step 0 is the untouched snapshot
; in both tables, so a completed fade-in lands on the original picture
; bit for bit without any special case.
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
    ld d, a                      ; both pages are ALIGN 256: page = high
    add a, tables>>8             ; byte + step, low byte 0
    ld h, a
    ld l, 0                      ; HL = byte 0 source
    ld a, d
    add a, tables9>>8
    ld d, a
    ld e, 0                      ; DE = byte 1 source, E also the count
    ld bc, TB_SELECT
    in a, (c)
    ld (savesel), a
    ld a, NR_PAL_CTL
    out (c), a
    inc b
    in a, (c)
    ld (savectl), a
    call pal_apply_ctl           ; corrupts AF only - HL/DE stay live
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
.wr:
    ld a, (hl)
    out (c), a                   ; first write: RRRGGGBB
    ld a, (de)
    out (c), a                   ; second write: priority + blue LSB
    inc l                        ; auto-inc advances the index AFTER the
    inc e                        ; second write (dev guide, NR $44). Both
                                 ; pages are aligned, so one index serves
    jr nz, .wr                   ; as both offsets and the loop count
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
; Foreground only. A = bank (0 displayed, 1 the staged bank buffer mode
; fills). SVC_PALREAD writes 256 interleaved pairs into palStage;
; de-interleave them into tables page 0 (RRRGGGBB) and tables9 page 0
; (priority + blue LSB) - the snapshot both precalc and apply9 read.
snap_via_service:
    ld ix, palStage
    call SVC_PALREAD             ; corrupts AF, BC, E, IX; leaves HL/D
    ld hl, palStage
    ld de, tables                ; both pages are ALIGN 256, so the low
    ld bc, tables9               ; byte is the colour index and the count
.di:
    ld a, (hl)
    ld (de), a
    inc hl
    ld a, (hl)
    ld (bc), a
    inc hl
    inc e
    inc c
    jr nz, .di
    ret

; ---------------------------------------------------------------
; Foreground only: build tables 1-7 (linear interpolation between the
; snapshot and the target, per 3-bit channel) and table 8 (solid
; target), in both halves - the RRRGGGBB byte in tables, the priority
; and blue-LSB byte in tables9. Done once per fade-out, so the
; interrupt hook never has to do arithmetic. Channel k-lerp:
; out = s + (t-s)*k/8 with the division rounding towards minus infinity
; (arithmetic shifts) - endpoints are exact by construction (k=0 is the
; snapshot table itself, k=8 is written as the solid target).
;
; ALL THREE channels are lerped at 3 bits. Blue's third bit lives in
; the second byte, so it is read out of tables9 page 0 on the way in
; and written back to page kcur on the way out. Doing blue at the 2
; bits the packed byte offers is what made it fade at twice the rate
; of red and green - see the header note.
precalc:
    ; table 8: every entry = the target colour. DODGE rule: a target of
    ; exactly the transparency colour would make the whole layer vanish
    ; (and "fade to transparent" is not this example's contract), so it
    ; is nudged one green step up to $E7 - visually near-identical,
    ; never transparent, and the value the interpreter's own loader
    ; parks colliding art on. The same nudge guards every interpolated
    ; value below.
    ld a, (target)
    cp TRANSP
    jr nz, .tgtok
    ld a, TRANSP_DODGE           ; $E7: same magenta, one green step up
.tgtok:
    ld c, a                      ; C = the solid byte
    ; tables9 page 8 gets the blue LSB the hardware would derive from an
    ; $41 write of that byte (B0 = B2 OR B1), priority clear. int
    ; streams the solid end 8-bit and never reads this page, and neither
    ; does fn 42 - it exists so that a future edit routing step 8
    ; through apply9 stays write-of-identical with the 8-bit path
    ; instead of silently disagreeing with the other palette bank.
    rrca
    or c
    and 1
    ld b, a                      ; B = derived blue LSB
    ld hl, tables + 8*256
    ld e, 0
.solid:
    ld (hl), c
    inc l
    dec e
    jr nz, .solid
    ld hl, tables9 + 8*256
    ld e, 0
.solid9:
    ld (hl), b
    inc l
    dec e
    jr nz, .solid9
    ; tables 1-7
    ld a, 1
.ktab:
    ld (kcur), a
    ld e, 0                      ; colour index
.entry:
    ld h, tables9>>8             ; the snapshot's second byte first: bit
    ld l, e                      ; 7 priority, bit 0 the blue LSB, so A
    ld a, (hl)                   ; still holds the packed byte at the
    ld (s9cur), a                ; transparency test below
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
    ld a, b                      ; the second byte follows it: the
    cp STEPS                     ; snapshot's own, so a pinned entry is
    jr nc, .pinnext              ; the snapshot at every step. Page 8 is
    add a, tables9>>8            ; the flat fill above - leave that one
    ld h, a
    ld l, e
    ld a, (s9cur)
    ld (hl), a
.pinnext:
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
    ; blue: 3 bits, not the 2 the packed byte shows. Bits 1-0 are B2 and
    ; B1; B0 lives in the snapshot's second byte. Lerping only the pair
    ; moved blue a whole 2-bit quantum where red moved a 3-bit one, so
    ; it fell off twice as fast at step 1 and, with floor division,
    ; overshot red at step 5. Interpolating all three bits puts every
    ; channel on the same eight-level ramp.
    ld a, (scur)
    and 3
    add a, a                     ; B2 B1 -> bits 2-1
    ld d, a
    ld a, (s9cur)
    and 1                        ; B0 -> bit 0
    or d
    ld d, a                      ; D = source blue, 0-7
    ld a, (target)
    and 3
    ld c, a
    add a, a
    ld b, a                      ; the target is a plain RRRGGGBB byte,
    ld a, c                      ; so its own B0 is whatever $41 would
    rrca                         ; derive from it - B2 OR B1. Using that
    or c                         ; keeps the far end of the ramp equal
    and 1                        ; to the solid table the fade parks on
    or b
    call lerp_ch                 ; A = lerped blue 0-7
    ; split the result: B2 B1 back into the packed byte, B0 into the
    ; second byte next to the priority bit. Priority is carried from the
    ; snapshot at every step, so a priority colour keeps its standing
    ; through the fade instead of dropping out and popping back on at
    ; the end.
    ld b, a
    and 1
    ld c, a
    ld a, (s9cur)
    and $C0                      ; the priority FIELD is bits 7-6, not
                                 ; just bit 7: the core latches
                                 ; nr_wr_dat(7 downto 6) on a $44 write
                                 ; and stores both. Layer 2's display
                                 ; path reads only bit 7 today, so carry
                                 ; the pair rather than assume which one
                                 ; a later core will look at
    or c
    ld (r9cur), a
    ld a, b
    rrca                         ; blue 0-7 -> B2 B1 in bits 1-0
    and 3
    ld c, a
    ld a, (rcur)
    or c
    ld c, a
    ; DODGE rule: an interpolated value may pass THROUGH the
    ; transparency colour even though neither endpoint equals it (the
    ; interpreter's palette loader keeps art off $E3, but lerp
    ; intermediates answer to nobody). One frame of see-through shimmer
    ; per crossing entry otherwise - nudge green up one step instead,
    ; the same dodge the interpreter's own art loader applies. $E7
    ; differs from $E3 in the top eight bits the transparency compare
    ; reads whatever the blue LSB holds, so the lerped B0 in r9cur
    ; passes through unchanged.
    ld a, c
    cp TRANSP
    jr nz, .store
    ld c, TRANSP_DODGE           ; $E7: green 0 -> 1, blue untouched
.store:
    ; store into table kcur, both halves
    ld a, (kcur)
    add a, tables>>8
    ld h, a
    ld l, e
    ld (hl), c
    ld a, (kcur)
    add a, tables9>>8
    ld h, a
    ld l, e
    ld a, (r9cur)
    ld (hl), a
.next:
    inc e
    jp nz, .entry                ; jp: the loop body outgrew jr range
    ld a, (kcur)
    inc a
    cp STEPS
    jp c, .ktab                  ; jp: spans the whole entry loop
    ret

; A = target channel value t, D = source channel value s, (kcur) = k.
; Out: A = s + (t-s)*k/8. Values are 0-7 on all three channels - blue
; included, which is the point of the second byte - and k is 1-7, so
; the product fits comfortably in a signed byte and the result never
; leaves the s..t range.
lerp_ch:
    sub d                        ; t - s, signed
    ld l, a
    ld a, (kcur)
    ld b, a                      ; b = k (1-7)
    xor a
.mul:
    add a, l                     ; a += delta, k times
    djnz .mul
    ; divide by 8, rounding to nearest: the +4 is half a divisor, and
    ; the arithmetic shifts floor, so the pair rounds. Plain flooring
    ; biased every channel towards the source, which cost a fade-out its
    ; last step - a fade to black reached black at step 7 and spent step
    ; 8 already there. Endpoints are untouched either way: k is 1-7 here,
    ; k=0 is the snapshot table and k=8 is written as the solid target.
    add a, 4
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
applyOther: db 0                 ; 1 = apply streams to the hidden bank
savesel: db 0                    ; saved $243B select latch
savectl: db 0                    ; saved NR $43
kcur:    db 0                    ; precalc scratch
scur:    db 0                    ; snapshot entry, packed byte
s9cur:   db 0                    ; snapshot entry, second byte
rcur:    db 0                    ; result, packed byte
r9cur:   db 0                    ; result, second byte

    ALIGN 256
tables:  ds 9*256                ; packed RRRGGGBB byte of each colour:
                                 ; 0 = snapshot, 1-7 = lerp, 8 = solid
    ALIGN 256                    ; already aligned (9*256), stated so the
                                 ; tables9>>8 / ld l,e indexing above
                                 ; cannot be broken by an edit above it
tables9: ds 9*256                ; second byte of each colour, same page
                                 ; per step: bit 7 = Layer 2 per-pixel
                                 ; priority, bit 0 = blue LSB. Page 0 is
                                 ; the snapshot, 1-7 are interpolated
                                 ; alongside their packed bytes, and page
                                 ; 8 is unused - the solid end is streamed
                                 ; 8-bit so that fn 42 can put the same
                                 ; bytes in both palette banks (see
                                 ; int), and the page is filled with
                                 ; hardware-consistent values anyway so a
                                 ; future edit cannot make the banks
                                 ; disagree by accident

    ENDMODULE

    IFNDEF XBN_MODULE
xbn_end:
    SAVEBIN "GAME.XBN", XBN_ORG, xbn_end - XBN_ORG
    XBN_SCRATCH_END
    ENDIF

; SVC_PALREAD landing buffer, 512 bytes, claimed from XBN_SCRATCH (see
; xbnmod.inc). Written by the service before it is read.
    MODULE fade
palStage: equ XBN_SCRATCH + 256
    ENDMODULE
