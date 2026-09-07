; Spike 1: NextDAW runtime player under the launcher's slot policy.
; Player at $E000 (page 40), song in pages 41-43, data slots 2, 3, 6.
; Key 1 = restore the three slots before every update (launcher policy).
; Key 2 = leave junk pages mapped (informational). Border: green = 1, red = 2.
    DEVICE ZXSPECTRUMNEXT
    ORG $8000
main:
    di
    ld sp, $BD00
    nextreg $07, 3                 ; 28 MHz
    ld bc, $243B
    ld a, $08
    out (c), a
    inc b
    in a, (c)
    or %00001010                   ; Turbo Sound + DACs, like hw_init
    nextreg $08, a
    ; IM2: table $BD00 of $BE, stub JP at $BEBE
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
    ld hl, isr
    ld ($BEBF), hl
    ld a, $BD
    ld i, a
    im 2
    ; player calls: slots 2, 3, 6 for song data
    nextreg $57, 40
    push ix
    ld l, 2
    ld h, 3
    ld c, 6
    call $E015                     ; InitSystem
    ld de, pages
    xor a
    call $E000                     ; InitSong
    call $E006                     ; PlaySong
    pop ix
    call save3
    ld a, 4
    out ($FE), a                   ; green border = restore policy
    xor a
    ld (mode), a
    ei
loop:
    ld a, (frame)
.w:
    ld b, a
    ld a, (frame)
    cp b
    jr z, .w
    ; scribble junk into the three slots between calls
    nextreg $52, 60
    nextreg $53, 61
    nextreg $56, 62
    ld a, $AA
    ld ($4000), a
    ld ($6000), a
    ld ($C000), a
    ld a, (mode)
    or a
    call z, restore3               ; policy: restore before the call
    nextreg $57, 40
    push ix
    call $E003                     ; UpdateSong
    pop ix
    call save3
    ; keys 1 and 2 (row $F7: bit 0 = 1, bit 1 = 2)
    ld bc, $F7FE
    in a, (c)
    bit 0, a
    jr nz, .not1
    xor a
    ld (mode), a
    ld a, 4
    out ($FE), a
.not1:
    bit 1, a
    jr nz, loop
    ld a, 1
    ld (mode), a
    ld a, 2
    out ($FE), a
    jr loop

save3:
    ld bc, $243B
    ld a, $52
    out (c), a
    inc b
    in a, (c)
    ld (slots+0), a
    dec b
    ld a, $53
    out (c), a
    inc b
    in a, (c)
    ld (slots+1), a
    dec b
    ld a, $56
    out (c), a
    inc b
    in a, (c)
    ld (slots+2), a
    ret
restore3:
    ld a, (slots+0)
    nextreg $52, a
    ld a, (slots+1)
    nextreg $53, a
    ld a, (slots+2)
    nextreg $56, a
    ret

isr:
    push af
    ld a, (frame)
    inc a
    ld (frame), a
    pop af
    ei
    reti

frame:  db 0
mode:   db 0
slots:  ds 3
pages:  db 41, 42, 43

    MMU 7, 40, $E000
    INCBIN "../../../tools/NextDAW/RuntimePlayer/NextDAW_RuntimePlayer_E000.bin"
    MMU 6, 41, $C000
    INCBIN "../../../tools/NextDAW/DemoCode/z88dk_asm/Silver-Surfer.NDR", 0, 8192
    MMU 6, 42, $C000
    INCBIN "../../../tools/NextDAW/DemoCode/z88dk_asm/Silver-Surfer.NDR", 8192, 8192
    MMU 6, 43, $C000
    INCBIN "../../../tools/NextDAW/DemoCode/z88dk_asm/Silver-Surfer.NDR", 16384, 8100

    SAVENEX OPEN "spike.nex", main, $BD00
    SAVENEX CORE 3, 0, 0
    SAVENEX CFG 0
    SAVENEX AUTO
    SAVENEX CLOSE
