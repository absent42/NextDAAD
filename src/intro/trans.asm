; Transitions. trans_begin reads curSlide (the incoming slide); trans_step
; runs one frame and returns Z when done. CUT and FADE here; the copy
; kinds in Task 10.
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
    ret

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
    or 1                             ; NZ until Task 10 adds the copy kinds
    ret
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
; colour -> border. HL, DE are left pointing at the 512-byte sources.
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

; FADE: phase 0 = current palette to the solid colour over half the frames,
; then swap surfaces and mode under the solid colour, phase 1 = solid to the
; new palette over the other half. The first slide has no picture to fade
; out and fades in over the whole time.
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

; A skip during a FADE: jump to the transition's end state so the END fade
; starts from the incoming picture (phase 0 still needs the midpoint swap).
; Copy transitions need nothing: their palette is already the new one.
trans_finish_now:
    ld a, (transType)
    cp TR_FADE
    ret nz
    ld a, (transPhase)
    or a
    call z, fade_midpoint
    ld a, PG_STAGE
    call map6
    ld hl, PAL_NEW
    call pal_program
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
