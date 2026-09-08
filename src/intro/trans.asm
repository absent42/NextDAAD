; Transitions. trans_begin reads curSlide (the incoming slide); trans_step
; runs one frame and returns Z when done. CUT here; FADE in Task 9; the
; copy kinds in Task 10.
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
    call pal_copy_new_to_cur
    jp l2_show

trans_step:
    ld a, (transType)
    or a
    jr z, .done
    or 1                             ; NZ: other kinds arrive in Tasks 9 and 10
    ret
.done:
    xor a
    ret
