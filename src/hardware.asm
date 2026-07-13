; Next hardware setup and register access.

hw_init:
    nextreg NR_CPU_SPEED, 3         ; 28MHz
    nextreg NR_SPRITES, 0           ; sprites off
    nextreg NR_DISPLAY_CTRL, 0      ; Layer 2 off, Timex off
    nextreg NR_ULA_CTRL, 0          ; ULA output enabled
    xor a
    out ($FE), a                    ; black border
    jp ula_cls

; Clear ULA pixels, set attrs to white ink on black paper.
ula_cls:
    ld hl, $4000
    ld de, $4001
    ld bc, $17FF
    ld (hl), 0
    ldir
    ld hl, $5800
    ld de, $5801
    ld bc, $02FF
    ld (hl), $07                    ; paper 0 (black), ink 7 (white)
    ldir
    ret

; Read a Next register. E = register, returns A = value. Preserves BC.
nr_read:
    push bc
    ld bc, TBBLUE_REG_SEL
    out (c), e
    ld bc, TBBLUE_REG_ACC
    in a, (c)
    pop bc
    ret
