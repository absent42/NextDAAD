; Spike 2: chain-load nextdaad.nex via an embedded loader, after timing
; 48 x 2K esxDOS reads of that file under a 15625 Hz CTC stereo tone.
; Frame count shown as 8 binary blocks (MSB left), then the chain runs.
    DEVICE ZXSPECTRUMNEXT
    ORG $8000
main:
    di
    ld sp, $BD00
    nextreg $07, 3
    ld bc, $243B
    ld a, $08
    out (c), a
    inc b
    in a, (c)
    or %00001010
    nextreg $08, a
    ; ULA screen: clear pixels, attrs white on black
    ld hl, $4000
    ld de, $4001
    ld bc, $17FF
    ld (hl), 0
    ldir
    ld hl, $5800
    ld de, $5801
    ld bc, $02FF
    ld (hl), $07
    ldir
    ; hardware IM2: table $BD00, frame stub $BEBE, CTC stub $BEC2, vector 6
    ld hl, $BD00
    ld a, $BE
    ld b, 0
.fill:
    ld (hl), a
    inc hl
    djnz .fill
    ld (hl), a
    ld a, $C3
    ld ($BEBE), a
    ld hl, frame_isr
    ld ($BEBF), hl
    ld a, $C3
    ld ($BEC2), a
    ld hl, ctc_isr
    ld ($BEC3), hl
    ld a, $C2
    ld ($BD06), a
    ld a, $BD
    ld i, a
    im 2
    nextreg $C0, 1
    nextreg $C4, %10000001
    nextreg $C5, %00000011
    nextreg $CC, 0
    nextreg $CD, 0
    nextreg $CE, 0
    ; CTC channel 0 at 15625 Hz for the live video mode
    ld bc, $243B
    ld a, $11
    out (c), a
    inc b
    in a, (c)
    and 7
    ld hl, tctab
    add hl, a
    ld a, (hl)
    ld (tc), a
    ld bc, $183B
    ld a, 3
    out (c), a
    out (c), a
    ld a, $85
    out (c), a
    ld a, (tc)
    out (c), a
    ei
    ; --- read timing: 48 x 2K of nextdaad.nex into $C000 window (page 60)
    nextreg $56, 60
    xor a
    rst 8
    db $89                          ; M_GETSETDRV
    ld ix, nexname
    ld b, 1
    rst 8
    db $9A                          ; F_OPEN
    jp c, fail
    ld (hnd), a
    ld a, (frames)
    ld (f0), a
    ld d, 48
.rd:
    push de
    ld a, (hnd)
    ld ix, $C000
    ld bc, 2048
    rst 8
    db $9D                          ; F_READ
    pop de
    jp c, fail
    dec d
    jr nz, .rd
    ld a, (frames)
    ld hl, f0
    sub (hl)
    ld (result), a
    ld a, (hnd)
    rst 8
    db $9B                          ; F_CLOSE
    ; show result as 8 blocks of 8x8 at row 0 (block n at column n*2)
    ld a, (result)
    ld b, 8
    ld hl, $4000
.blk:
    rlca
    push af
    jr nc, .skip
    push hl
    push bc
    ld b, 8
.rows:
    ld (hl), $FF
    inc h
    djnz .rows
    pop bc
    pop hl
.skip:
    inc hl
    inc hl
    pop af
    djnz .blk
    ; hold 150 frames then chain
    ld a, (frames)
    add a, 150
    ld b, a
.hold:
    ld a, (frames)
    cp b
    jr nz, .hold
    ; teardown: CTC off, DACs parked, DI, copy the stub, run it
    di
    ld bc, $183B
    ld a, 3
    out (c), a
    out (c), a
    ld a, $80
    out ($F3), a
    out ($F9), a
    ld hl, stub_img
    ld de, $6000
    ld bc, stub_len
    ldir
    jp $6000
fail:
    ld a, 2
    out ($FE), a
    di
    halt

frame_isr:
    push af
    ld a, (frames)
    inc a
    ld (frames), a
    pop af
    ei
    reti
ctc_isr:
    push af
    ld a, (sq)
    inc a
    ld (sq), a
    and 32                          ; toggles every 32 samples = 488 Hz
    add a, $60
    out ($F3), a
    out ($F9), a
    pop af
    ei
    reti

frames: db 0
f0:     db 0
sq:     db 0
tc:     db 0
hnd:    db 0
result: db 0
tctab:  db 112, 114, 117, 120, 124, 128, 132, 108
    ASSERT $ - tctab == 8               ; indexed by NR $11 and 7
nexname: db "nextdaad.nex", 0

; ---- the stub, assembled for $6000, copied there at run time ----
stub_img:
    DISP $6000
stub:
    di
    ld sp, $7FE0
    xor a
    rst 8
    db $89
    ld ix, s_name
    ld b, 1
    rst 8
    db $9A
    jp c, s_fail
    ld (s_hnd), a
    ld ix, $7800
    ld bc, 512
    rst 8
    db $9D
    jp c, s_fail
    ; header checks: "Next", "V1.x" with x in 1..3, no screen, entry bank 0,
    ; no kept handle, bank 5 not flagged
    ld hl, $7800
    ld a, (hl)
    cp 'N'
    jp nz, s_fail
    inc hl
    ld a, (hl)
    cp 'e'
    jp nz, s_fail
    ld a, ($7804)
    cp 'V'
    jp nz, s_fail
    ld a, ($7807)
    sub '1'
    cp 3
    jp nc, s_fail
    ld a, ($780A)
    or a
    jp nz, s_fail
    ld a, ($7800+139)
    or a
    jp nz, s_fail
    ld hl, ($7800+140)
    ld a, h
    or l
    jp nz, s_fail
    ld a, ($7800+18+5)
    or a
    jp nz, s_fail
    ; banks in file order: 5,2,0,1,3,4,6,7 then 8..111
    ld hl, s_order
    ld b, 8
.first:
    ld a, (hl)
    inc hl
    push hl
    push bc
    call s_bank
    pop bc
    pop hl
    djnz .first
    ld a, 8
.rest:
    push af
    call s_bank
    pop af
    inc a
    cp 112
    jr nz, .rest
    ld a, (s_hnd)
    rst 8
    db $9B
    ; ---- nexload's post-load reset ----
    nextreg $62, 0
    nextreg $61, 0
    ld bc, $243B
    ld a, $06
    out (c), a
    inc b
    in a, (c)
    ld (s_p2), a
    and %11111100                   ; AYs in reset for one frame
    nextreg $06, a
    call s_frame
    ld a, (s_p2)
    and %11101111                   ; DivMMC auto paging off
    or %00001000                    ; Multiface on
    nextreg $06, a
    ld bc, $243B
    ld a, $08
    out (c), a
    inc b
    in a, (c)
    set 7, a                        ; locked paging off
    set 6, a                        ; contention off
    res 5, a                        ; ABC stereo
    set 3, a                        ; DACs
    set 2, a                        ; Timex
    set 1, a                        ; Turbo Sound
    res 0, a
    nextreg $08, a
    nextreg $07, 3
    nextreg $12, 9
    nextreg $13, 12
    nextreg $14, $E3
    nextreg $15, 1
    nextreg $16, 0
    nextreg $17, 0
    nextreg $1C, 15
    nextreg $18, 0
    nextreg $18, 255
    nextreg $18, 0
    nextreg $18, 191
    nextreg $19, 0
    nextreg $19, 255
    nextreg $19, 0
    nextreg $19, 191
    nextreg $1A, 0
    nextreg $1A, 255
    nextreg $1A, 0
    nextreg $1A, 191
    nextreg $1B, 0
    nextreg $1B, 159
    nextreg $1B, 0
    nextreg $1B, 255
    nextreg $2D, 0
    nextreg $32, 0
    nextreg $33, 0
    nextreg $42, 15
    nextreg $43, 0                  ; ULA palette: default 16 colours x2
    nextreg $40, 0
    call s_ulapal
    nextreg $40, 128
    call s_ulapal
    nextreg $43, 16                 ; Layer 2 palette identity
    call s_identity
    nextreg $43, 32                 ; sprite palette identity
    call s_identity
    nextreg $4A, 0
    nextreg $4B, $E3
    ld bc, $123B
    xor a
    out (c), a                      ; Layer 2 off
    xor a
    out ($FE), a                    ; border black, as nexload leaves it
    ld hl, $5800
    ld de, $5801
    ld bc, $02FF
    ld (hl), 0
    ldir
    nextreg $50, 255
    nextreg $51, 255
    nextreg $52, 10
    nextreg $53, 11
    nextreg $54, 4
    nextreg $55, 5
    nextreg $56, 0
    nextreg $57, 1
    ld sp, ($7800+12)
    ld hl, ($7800+14)
    jp (hl)

; A = bank number: load it if flagged (two 8K reads through slots 6/7)
s_bank:
    ld c, a
    ld b, 0
    ld hl, $7800+18
    add hl, bc
    ld a, (hl)
    or a
    ret z
    ld a, c
    add a, a
    nextreg $56, a
    inc a
    nextreg $57, a
    ld ix, $C000
    call s_read8k
    ld ix, $E000
s_read8k:
    ld bc, 8192
    ld a, (s_hnd)
    rst 8
    db $9D
    jp c, s_fail
    ld hl, 8192
    or a
    sbc hl, bc
    jp nz, s_fail
    ret
s_frame:                             ; one field by the raster line 0 edge,
    ld de, 0                         ; bounded (rubric 6): 65536 polls each way
.w1:
    ld bc, $243B
    ld a, $1F
    out (c), a
    inc b
    in a, (c)
    or a
    jr z, .w2
    dec de
    ld a, d
    or e
    jr nz, .w1
    ret
.w2:
    ld de, 0
.w3:
    ld bc, $243B
    ld a, $1F
    out (c), a
    inc b
    in a, (c)
    or a
    jr nz, .done
    dec de
    ld a, d
    or e
    jr nz, .w3
.done:
    ret
s_ulapal:                            ; the 16 default ULA colours, eight times
    ld c, 8
.o:
    ld hl, s_defpal
    ld b, 16
.p:
    ld a, (hl)
    inc hl
    nextreg $41, a
    djnz .p
    dec c
    jr nz, .o
    ret
s_identity:                          ; 256 entries, value = index
    nextreg $40, 0
    xor a
.i:
    nextreg $41, a
    inc a
    jr nz, .i
    ret
s_fail:
    ld a, 6
    out ($FE), a
    di
    halt
s_order: db 5, 2, 0, 1, 3, 4, 6, 7
    ASSERT $ - s_order == 8
s_defpal: db $00, $02, $A0, $A2, $14, $16, $B4, $B6, $00, $03, $E0, $E7, $1C, $1F, $FC, $FF
    ASSERT $ - s_defpal == 16
s_name:  db "nextdaad.nex", 0
s_hnd:   db 0
s_p2:    db 0
    ENT
stub_len equ $ - stub_img

    SAVENEX OPEN "spike.nex", main, $BD00
    SAVENEX CORE 3, 0, 0
    SAVENEX CFG 0
    SAVENEX AUTO
    SAVENEX CLOSE
