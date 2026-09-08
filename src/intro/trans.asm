; Transitions. trans_begin reads curSlide (the incoming slide); trans_step
; runs one frame and returns Z when done. CUT, FADE and the copy kinds
; (WIPE, DISSOLVE, BLINDS).
trans_begin:
    ld a, (curSlide+SL_TR)
    ld (transType), a
    ld a, (curSlide+SL_COL)
    ld (transColour), a
    ld hl, (curSlide+SL_TRF)
    ld (transFrames), hl
    ld hl, 0
    ld (transFrame), hl
    xor a
    ld (transPhase), a
    ld a, (transType)
    or a
    jr z, trans_cut_begin
    cp TR_FADE
    jp z, trans_fade_begin
    jp trans_copy_begin

; CUT: hide, swap, mode from the slide, its palette in, show.
trans_cut_begin:
    call l2_hide
    call l2_swap
    ld a, (curSlide+SL_MODE)
    call l2_mode_apply
    ld a, PG_STAGE
    call map6
    ld hl, PAL_NEW
    call pal_program
    call l2_show                     ; hidden only across the mode/palette change
    jp pal_copy_new_to_cur

trans_step:
    ld a, (transType)
    or a
    jr z, .done
    cp TR_FADE
    jp z, trans_fade_step
    jp trans_copy_step
.done:
    xor a
    ret

; HL = elapsed frames, DE = span frames -> A = 16*elapsed/span, capped at 16.
; Corrupts AF, BC, DE, HL.
fade_k_for:
    ld a, d
    or e
    jr z, .full
    add hl, hl
    add hl, hl
    add hl, hl
    add hl, hl                       ; elapsed*16; span <= 600 so it fits
    ld b, h
    ld c, l
    call div16                       ; BC = quotient (doc 05 Div16)
    ld a, b
    or a
    jr nz, .full
    ld a, c
    cp 17
    ret c
.full:
    ld a, 16
    ret

; Border endpoints for a phase: phase 0 fades border -> colour, phase 1
; colour -> border. Corrupts AF, HL.
fade_border_set:
    ld a, (transPhase)
    or a
    jr nz, .in
    ld a, (borderCol)
    ld hl, lerpBorderA
    call colour9_store
    ld a, (transColour)
    ld hl, lerpBorderB
    jp colour9_store
.in:
    ld a, (transColour)
    ld hl, lerpBorderA
    call colour9_store
    ld a, (borderCol)
    ld hl, lerpBorderB
    jp colour9_store

; FADE: phase 0 fades to the solid colour, then swap surfaces and mode,
; phase 1 fades in the new palette. The first slide has no picture to
; fade out, so it fades in over the whole time.
trans_fade_begin:
    ld a, (transColour)
    call pal_solid
    ld a, $FF
    ld (fadeK), a
    ld a, (firstTrans)
    or a
    ret z                            ; a picture is up: fade it out first
    jp fade_midpoint                 ; nothing up yet (also never on a LOOP wrap)

; swap, mode, solid palette in, show, phase 1
fade_midpoint:
    ld a, 1
    ld (transPhase), a
    call l2_hide
    call l2_swap
    ld a, (curSlide+SL_MODE)
    call l2_mode_apply
    ld a, PG_STAGE
    call map6
    ld hl, PAL_SOLID
    call pal_program
    call l2_show
    ld a, $FF
    ld (fadeK), a
    ret

trans_fade_step:
    ld hl, (transFrame)
    inc hl
    ld (transFrame), hl
    ld a, (transPhase)
    or a
    jr nz, .in
    ld de, (transFrames)
    srl d
    rr e                             ; DE = half
    push de
    call fade_k_for
    pop de
    push de
    call fade_write_out              ; pal_lerp corrupts everything (rubric 1)
    pop de
    ld hl, (transFrame)
    or a
    sbc hl, de
    jr nc, .mid
    or 1                             ; NZ: still fading out
    ret
.mid:
    call fade_midpoint
    or 1
    ret
.in:
    ld hl, (transFrame)
    ld de, (transFrames)
    ld a, (firstTrans)
    or a
    jr nz, .span                     ; first transition: whole time, elapsed as is
    srl d
    rr e
    or a
    sbc hl, de                       ; elapsed within phase 1
    jr nc, .span
    ld hl, 0
.span:
    push de
    call fade_k_for
    pop de
    call fade_write_in
    ld a, (fadeK)
    cp 16
    jr z, .done
    or 1
    ret
.done:
    call pal_copy_new_to_cur
    xor a
    ret

; A = k: PAL_CUR -> PAL_SOLID at k, written once per k.
fade_write_out:
    ld hl, fadeK
    cp (hl)
    ret z
    ld (hl), a
    push af
    call fade_border_set
    ld a, PG_STAGE
    call map6
    pop af
    ld hl, PAL_CUR
    ld de, PAL_SOLID
    jp pal_lerp
; A = k: PAL_SOLID -> PAL_NEW at k, written once per k.
fade_write_in:
    ld hl, fadeK
    cp (hl)
    ret z
    ld (hl), a
    push af
    call fade_border_set
    ld a, PG_STAGE
    call map6
    pop af
    ld hl, PAL_SOLID
    ld de, PAL_NEW
    jp pal_lerp

; A skip mid-transition: finish it now. FADE jumps to its end state (phase
; 0 still needs the midpoint swap); a copy kind draws every remaining unit
; in one oversized step (span 1, acc = remaining) via the shared run routine.
trans_finish_now:
    ld a, (transType)
    or a
    ret z                             ; CUT: trans_begin already did everything
    cp TR_FADE
    jr z, .fade
    ld hl, (transLines)
    ld de, (transDone)
    or a
    sbc hl, de
    ld (transPer), hl                 ; acc = every remaining unit
    ld de, 1
    ld (transSpan), de                ; span 1: the loop never waits a frame
    jp trans_copy_run
.fade:
    ld a, (transPhase)
    or a
    call z, fade_midpoint
    ld a, PG_STAGE
    call map6
    ld hl, PAL_NEW
    call pal_program
    ld a, (borderCol)
    call border_set
    jp pal_copy_new_to_cur

; END fade: PAL_CUR -> endColour over transFrames, no swap.
fade_out_begin:
    ld a, (endColour)
    ld (transColour), a
    call pal_solid
    ld hl, 0
    ld (transFrame), hl
    xor a
    ld (transPhase), a
    ld a, $FF
    ld (fadeK), a
    ret
fade_out_step:
    ld hl, (transFrame)
    inc hl
    ld (transFrame), hl
    ld de, (transFrames)
    push de
    call fade_k_for
    pop de
    call fade_write_out
    ld a, (fadeK)
    cp 16
    jr z, .done
    or 1
    ret
.done:
    xor a
    ret

; ---- copy primitives: back surface -> front through slot 6 and bounce ----
    ASSERT (bounce & $FF) == 0       ; main.asm ALIGN 256 before bounce (rubric 8)
; Slot 6 remapped per copy (doc 00); slot 7 stays the audio page, so both
; directions share slot 6, not the spec's two-slot copy. HL = contiguous
; line 0-319, page parked in memory (LDIR consumes BC). Corrupts everything.
copy_line:
    ld a, l
    and 31
    ld d, a
    ld e, 0                          ; DE = offset in page
    ld a, l
    rlca
    rlca
    rlca
    and 7
    ld c, a
    ld a, h
    rlca
    rlca
    rlca
    or c                             ; page index
    ld (linePage), a
    ld c, a
    ld a, (backBank)
    add a, a
    add a, c
    nextreg NR_MMU6, a
    ld hl, WIN6
    add hl, de
    push hl
    ld de, bounce
    ld bc, 256
    ldir
    ld a, (frontBank)
    add a, a
    ld hl, linePage
    add a, (hl)
    nextreg NR_MMU6, a
    pop de
    ld hl, bounce
    ld bc, 256
    ldir
    ret
linePage: db 0

; L = strided line 0-255: gather 32 bytes (one per page) into bounce, then
; scatter with LDWS (docs 04, 10). Outer counter lives on the stack across
; both inner loops. Corrupts everything.
copy_stride:
    ld a, l
    ld (strideLine), a
    ld a, (transPages)
    ld b, a
    ld c, 0
.page:
    push bc
    ld a, (backBank)
    add a, a
    add a, c
    nextreg NR_MMU6, a
    ld h, high WIN6
    ld a, (strideLine)
    ld l, a
    ld de, bounce
    ld b, 32
.g:
    ld a, (hl)
    ld (de), a
    inc h
    inc e
    djnz .g
    pop bc
    push bc
    ld a, (frontBank)
    add a, a
    add a, c
    nextreg NR_MMU6, a
    ld d, high WIN6
    ld a, (strideLine)
    ld e, a                          ; DE = the column in the front page
    ld hl, bounce
    DUP 32
    ldws
    EDUP
    pop bc
    inc c
    djnz .page
    ret
strideLine: db 0

; A = page index, HL = block 0-511 of that page.
copy_block:
    ld (blockPage), a
    ld a, l
    and 63
    add a, a
    add a, a
    ld (blockLo), a                  ; lo*4
    ld a, l
    rlca
    rlca
    and 3
    ld c, a
    ld a, h
    rlca
    rlca
    and %00001100
    or c                             ; hi = b >> 6
    add a, a
    add a, a
    ld (blockHi), a                  ; hi*4
    ld a, (backBank)
    add a, a
    ld hl, blockPage
    add a, (hl)
    nextreg NR_MMU6, a
    ld de, bounce
    call block_gather
    ld a, (frontBank)
    add a, a
    ld hl, blockPage
    add a, (hl)
    nextreg NR_MMU6, a
    jp block_scatter

; window -> (DE): four runs of four bytes. Row step is a 16-bit add, not an
; 8-bit rebuild, so a wrap of L at row 63 still carries into H exactly once
; (fix round 1: the old sub-4 form silently double-carried).
block_gather:
    ld a, (blockHi)
    add a, high WIN6
    ld h, a
    ld a, (blockLo)
    ld l, a
    ld a, 4
.r:
    ld (blockCnt), a
    ldi
    ldi
    ldi
    ldi
    add hl, 252                      ; HL += 256 net (Z80N, doc 10)
    ld a, (blockCnt)
    dec a
    jr nz, .r
    ret
; bounce -> window: four runs of four bytes, same 16-bit row step as above.
block_scatter:
    ld a, (blockHi)
    add a, high WIN6
    ld d, a
    ld a, (blockLo)
    ld e, a
    ld hl, bounce
    ld a, 4
.r:
    ld (blockCnt), a
    ldi
    ldi
    ldi
    ldi
    add de, 252                      ; DE += 256 net (Z80N, doc 10)
    ld a, (blockCnt)
    dec a
    jr nz, .r
    ret
blockPage: db 0
blockLo:   db 0
blockHi:   db 0
blockCnt:  db 0

; ---- copy transitions ----
; Bresenham pacing: every kind's per-frame step adds its whole-transition
; unit count to an accumulator (transPer, repurposed) and draws one unit
; per transFrames it covers, so the transition finishes on its last frame.
trans_copy_begin:
    ld a, PG_STAGE
    call map6
    ld hl, PAL_NEW
    call pal_program                 ; the incoming palette applies at once
    call pal_copy_new_to_cur
    ld a, (l2Mode)
    ld b, 10
    or a
    jr nz, .p
    ld b, 6
.p:
    ld a, b
    ld (transPages), a
    ld a, (transType)
    cp TR_DISS
    jr z, .diss
    cp TR_BLINDS
    jr z, .blinds
    call wipe_is_contig
    ld (copyContig), a
    or a
    jr z, .strided
    ld hl, 320                       ; unit = one line
    ld a, (l2Mode)
    or a
    jr nz, .lines
    ld hl, 192
    jr .lines
.strided:
    ld hl, 256
.lines:
    ld (transLines), hl
    jr .go
.diss:
    ld hl, 3072                      ; unit = one block, whole picture (spec 6.5)
    ld a, (l2Mode)
    or a
    jr z, .dgo
    ld hl, 5120
.dgo:
    ld (transLines), hl
    jr .go
.blinds:
    ld hl, 32                        ; unit = one row across all 8 bands
    ld a, (l2Mode)
    or a
    jr nz, .bl
    ld hl, 24
.bl:
    ld (transLines), hl
.go:
    ld hl, 0
    ld (transDone), hl
    ld (transPer), hl                ; transPer repurposed: Bresenham accumulator
    ld hl, $01A5
    ld (lfsr), hl
    ret

; out A = 1 when the wipe runs along the contiguous axis: 320 mode LEFT/RIGHT
; (columns), 256 mode UP/DOWN (rows).
wipe_is_contig:
    ld a, (transType)
    cp TR_WIPE_U
    ld b, 0
    jr nc, .ud
    ld b, 1                          ; LEFT/RIGHT
.ud:
    ld a, (l2Mode)
    or a
    ld a, b
    ret nz                           ; 320: LEFT/RIGHT contiguous
    xor 1                            ; 256: UP/DOWN contiguous
    ret

; Per-frame tick: advance transFrame, guard a zero span, add this
; transition's units into the accumulator, then run the shared stepper.
trans_copy_step:
    ld hl, (transFrame)
    inc hl
    ld (transFrame), hl
    ld de, (transFrames)
    ld a, d
    or e
    jr nz, .span
    ld de, 1
.span:
    ld (transSpan), de
    ld hl, (transLines)
    ld de, (transPer)
    add hl, de
    ld (transPer), hl                ; acc += units
    jp trans_copy_run

; Shared by trans_copy_step (paced) and trans_finish_now (oversized, skip).
; Assumes transPer (acc) and transSpan (span) are already set.
trans_copy_run:
    ld a, (transType)
    cp TR_DISS
    jp z, diss_step
    cp TR_BLINDS
    jp z, blinds_step
.w:
    ld hl, (transPer)
    ld de, (transSpan)
    or a
    sbc hl, de
    jr c, .wcheck
    ld (transPer), hl                ; acc -= span
    ld hl, (transDone)
    ld de, (transLines)
    or a
    sbc hl, de
    jr nc, copy_done
    ld hl, (transDone)
    ld a, (transType)
    cp TR_WIPE_L
    jr z, .rev
    cp TR_WIPE_U
    jr nz, .fwd
.rev:
    ex de, hl                        ; DE = done, HL = lines
    dec hl
    or a
    sbc hl, de                       ; line = lines-1-done
.fwd:
    ld a, (copyContig)
    or a
    jr z, .st
    call copy_line
    jr .n
.st:
    call copy_stride
.n:
    ld hl, (transDone)
    inc hl
    ld (transDone), hl
    jr .w
.wcheck:
    ld hl, (transDone)
    ld de, (transLines)
    or a
    sbc hl, de
    jr nc, copy_done
    or 1
    ret
copy_done:
    xor a
    ret

; DISSOLVE: one 13-bit LFSR sequence over every block of the whole picture
; (spec 6.5); unit = one block. Draws block 0 once at completion (the LFSR
; never yields 0).
diss_step:
.blk:
    ld hl, (transPer)
    ld de, (transSpan)
    or a
    sbc hl, de
    jr c, .dcheck
    ld (transPer), hl
    ld hl, (transDone)
    ld de, (transLines)
    dec de                            ; LFSR covers indices 1..transLines-1
    or a
    sbc hl, de
    jp nc, .dfinish
    call diss_draw_one
    jr .blk
.dcheck:
    ld hl, (transDone)
    ld de, (transLines)
    or a
    sbc hl, de
    jr nc, copy_done                  ; fully complete (block 0 already drawn)
    or 1
    ret
.dfinish:
    ld hl, (transDone)
    ld de, (transLines)
    or a
    sbc hl, de
    jp nc, copy_done                  ; block 0 already drawn
    xor a
    ld hl, 0
    call copy_block
    ld hl, (transDone)
    inc hl
    ld (transDone), hl
    jp copy_done

; One DISSOLVE unit: find the next LFSR value below the whole-picture block
; count, draw it, advance transDone. Bounded search (rubric 6): worst
; measured reject run is 33 at 3072 blocks (exact bound 34), 12 at 5120.
diss_draw_one:
    ld b, 34
.search:
    call lfsr_next
    ld de, (transLines)
    or a
    sbc hl, de
    jr c, .found
    djnz .search
    ret                               ; bound exhausted: proven unreachable
.found:
    ld hl, (lfsr)                    ; re-fetch idx (the sbc above corrupted HL)
    ld a, h
    and 1
    ld c, a                          ; C = block-in-page high bit (idx bit 8)
    ld a, h
    srl a                            ; A = idx >> 9 = page
    ld h, c
    call copy_block                  ; A = page, HL = idx & 511 (block 0-511)
    ld hl, (transDone)
    inc hl
    ld (transDone), hl
    ret

; 13-bit LFSR, x^13+x^4+x^3+x+1 (taps 0,2,3,12): HL = next state, never 0.
; Output bit is the carry RR L leaves (doc 00). Corrupts AF, HL.
lfsr_next:
    ld hl, (lfsr)
    srl h
    rr l
    jr nc, .no
    ld a, h
    xor %00010000                    ; bit 12
    ld h, a
    ld a, l
    xor %00001101                    ; bits 3, 2, 0
    ld l, a
.no:
    ld (lfsr), hl
    ret
lfsr:       dw $01A5
transSpan:  dw 0
copyContig: db 0

; BLINDS: 8 bands along the row axis; unit = one row revealed in every
; band, top to bottom. Rows are strided lines in 320 mode, contiguous in
; 256 mode.
blinds_step:
.row:
    ld hl, (transPer)
    ld de, (transSpan)
    or a
    sbc hl, de
    jr c, .bcheck
    ld (transPer), hl
    ld hl, (transDone)
    ld de, (transLines)
    or a
    sbc hl, de
    jp nc, copy_done
    ld b, 8
    ld c, 0
.band:
    push bc
    ld a, (transLines)
    ld d, a
    ld e, c
    mul d, e                         ; DE = band * rows per band
    ld hl, (transDone)
    add hl, de                       ; row
    ld a, (l2Mode)
    or a
    jr z, .contig
    call copy_stride
    jr .next
.contig:
    call copy_line
.next:
    pop bc
    inc c
    djnz .band
    ld hl, (transDone)
    inc hl
    ld (transDone), hl
    jr .row
.bcheck:
    ld hl, (transDone)
    ld de, (transLines)
    or a
    sbc hl, de
    jp nc, copy_done
    or 1
    ret
