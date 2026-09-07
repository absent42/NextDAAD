; Music dispatcher. musicKind selects the leg; kind 0 is silent. Each leg
; task fills in its branch. isrAudio nonzero routes the frame ISR to aud_isr.
aud_open:
    ld a, (musicKind)
    or a
    ret z
    ret
aud_frame:
    ld a, (musicKind)
    or a
    ret z
    ret
aud_isr:
    ret
aud_fade_begin:                      ; HL = frames
    ld (fadeFrames), hl
    ld hl, 0
    ld (fadeFrame), hl
    ld a, 1
    ld (fading), a
    ret
aud_fade_step:
    ld a, (fading)
    or a
    ret z
    ld hl, (fadeFrame)
    inc hl
    ld (fadeFrame), hl
    ret
aud_stop:
    xor a
    ld (isrAudio), a
    ret
