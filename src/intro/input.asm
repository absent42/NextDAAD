; Any key, Kempston fire or mouse button. Edge-detected per frame.
input_scan:                          ; out A nonzero = something down
    ld bc, $00FE
    in a, (c)
    cpl
    and $1F
    ld e, a
    in a, ($1F)
    and %00010000
    or e
    ld e, a
    ld bc, $FADF
    in a, (c)
    cpl
    and %00000011
    or e
    ret

input_poll:
    call input_scan
    ld e, a
    ld a, (keyPrev)
    ld d, a
    ld a, e
    ld (keyPrev), a
    xor a
    ld (keyEdge), a
    ld a, e
    or a
    ret z
    ld a, d
    or a
    ret nz                           ; still held
    ld a, 1
    ld (keyEdge), a
    ld hl, keyCount
    inc (hl)
    ret

; Wait, at most 50 fields, for every key and button to be released.
; Raster line 0 edge is the field clock, usable with interrupts off.
; Count lives on the stack across input_scan/raster_field (rubric 1). Corrupts AF, BC, DE.
input_release_wait:
    ld b, 50
.field:
    push bc
    call input_scan
    pop bc
    or a
    ret z
    push bc
    call raster_field
    pop bc
    djnz .field
    ret

; Block until raster line 0 has been seen after a nonzero line, bounded
; to 65536 polls each way (rubric 6). nr_read preserves BC, so BC counts.
; Corrupts AF, BC, E.
raster_field:
    ld bc, 0
.w1:
    ld e, NR_RASTER_LSB
    call nr_read
    or a
    jr z, .w2
    dec bc
    ld a, b
    or c
    jr nz, .w1
    ret
.w2:
    ld bc, 0
.w3:
    ld e, NR_RASTER_LSB
    call nr_read
    or a
    jr nz, .done
    dec bc
    ld a, b
    or c
    jr nz, .w3
.done:
    ret
