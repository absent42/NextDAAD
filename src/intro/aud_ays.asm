; AYS resident applier (aysconv.ps1 format). Whole file in pages 40..87.
; Format: "AYS1", psgCount at 4, loopOffset d24 at 8, streamLength d24 at
; 11, stream from file offset 16, matching src\overlay1.asm's own reader.
    ASSERT PG_MUSIC_LAST - PG_MUSIC + 1 == 48    ; the .page loop's literal cap
ays_open:
    ld hl, aysName
    call name_intro
    call esx_open_name
    jr nc, .ok
    ld a, ERR_MUS_OPEN
    jp dbg_code
.ok:
    ld (aysHandle), a
    xor a
    ld (aysPages), a
.page:
    ld a, (aysPages)
    add a, PG_MUSIC
    call map6
    ld a, (aysHandle)
    ld de, 0
    ld bc, 8192
    call esx_read6
    jp c, .bad
    ld hl, aysPages
    inc (hl)
    ld a, b
    cp $20
    jr nz, .eof                      ; short read: last page
    ld a, (hl)
    cp 48
    jr c, .page
    ; 48 full pages: the file must end exactly here (probe one byte into page 39)
    ld a, PG_STAGE
    call map6
    ld a, (aysHandle)
    ld de, $1F00
    ld bc, 1
    call esx_read6
    jp c, .bad
    ld a, b
    or c
    jp nz, .bad                      ; over 48 pages
.eof:
    ld a, (aysHandle)
    call esx_close_a
    ld a, PG_MUSIC
    call map6
    ld hl, WIN6
    ld a, (hl)
    cp 'A'
    jp nz, .hdr
    inc hl
    ld a, (hl)
    cp 'Y'
    jp nz, .hdr
    inc hl
    ld a, (hl)
    cp 'S'
    jp nz, .hdr
    inc hl
    ld a, (hl)
    cp '1'
    jp nz, .hdr
    ld a, (WIN6+4)
    or a
    jp z, .hdr
    cp 4
    jp nc, .hdr
    ld (aysPsgs), a
    ; stream length -> remain and total
    ld hl, (WIN6+11)
    ld (aysRemain), hl
    ld (aysLen), hl
    ld a, (WIN6+13)
    ld (aysRemainHi), a
    ld (aysLenHi), a
    ; loopOffset must be < streamLength (matches overlay1.asm's own header
    ; check; loopOffset >= streamLength would compute a negative loop
    ; remainder below)
    ld hl, (WIN6+8)
    ld de, (WIN6+11)
    or a
    sbc hl, de
    ld a, (WIN6+10)
    ld hl, WIN6+13
    sbc a, (hl)
    jp nc, .hdr
    ; loop position: absolute offset 16 + loopOffset -> page and pointer
    ld hl, (WIN6+8)
    ld a, (WIN6+10)
    ld de, 16
    add hl, de
    adc a, 0                         ; A:HL = absolute offset
    ; page = offset >> 13, pointer = WIN6 + (offset & $1FFF)
    ld c, a
    ld a, h
    and $1F
    or high WIN6
    ld (aysLoopPtr+1), a
    ld a, l
    ld (aysLoopPtr), a
    ld a, h
    rlca
    rlca
    rlca
    and 7
    ld b, a
    ld a, c
    rrca
    rrca
    rrca
    rrca
    rrca
    and %11111000
    or b
    ld (aysLoopPage), a
    ; loop remain = streamLength - loopOffset
    ld hl, (WIN6+11)
    ld de, (WIN6+8)
    or a
    sbc hl, de
    ld (aysLoopRemain), hl
    ld a, (WIN6+13)
    ld hl, WIN6+10
    sbc a, (hl)
    ld (aysLoopRemainHi), a
    xor a
    ld (aysPage), a
    ld hl, WIN6+16
    ld (aysPtr), hl
    ld hl, aysShadow
    ld de, aysShadow+1
    ld bc, 8
    ld (hl), 0
    ldir
    ld a, 1
    ld (isrAudio), a
    ret
.bad:
    ld a, (aysHandle)
    call esx_close_a
    ld a, ERR_MUS_OPEN
    jp dbg_code
.hdr:
    ld a, ERR_MUS_HDR
    jp dbg_code
aysName:   db "MUSIC.AYS", 0
aysHandle: db 0
aysPages:  db 0
aysPsgs:   db 0
aysPage:   db 0
aysPtr:    dw 0
aysRemain: dw 0
aysRemainHi: db 0
aysLen:    dw 0
aysLenHi:  db 0
aysLoopPage: db 0
aysLoopPtr:  dw 0
aysLoopRemain: dw 0
aysLoopRemainHi: db 0
aysSel:    db 0
aysLeft:   db 0
aysShadow: ds 9                      ; last written R8-R10 per PSG
aysStart:  dw 0                      ; stream pointer at the frame's start
aysCross:  db 0                      ; page crossings this frame (0 or 1)

; AY register write from the frame ISR: A = value, B = register. The
; alternate set carries the port pair (frame_isr saved it), so the main
; set's HL (stream pointer), DE (mask) and BC (register, value) survive.
; Corrupts AF and AF'.
    MACRO AYS_WRITE
    ex af, af'                       ; A' = value
    ld a, b                          ; register number
    exx
    ld bc, PSG_SEL_PORT
    out (c), a
    ex af, af'                       ; A = value
    ld b, high PSG_DATA_PORT
    out (c), a
    exx
    ENDM

; ISR tick: map the page pair, apply one frame, loop at the end, fade
; pass. Register-resident inner loop (doc 00 golden rules: no IX in an
; ISR loop, no memory counters): HL = stream pointer, DE = mask, B =
; register number, C = value. Consumption is the pointer delta plus 8K
; per page crossing, subtracted from the 24-bit remain once per frame.
; Bounded per frame: at most 3 PSGs x (2 mask bytes + 14 register
; values) = 48 ays_rdb calls, regardless of stream content - a corrupt
; mask can select all 14 registers but the register loop is hard capped
; at 14 by "cp 14", so no frame can spin past that fixed count.
; Corrupts everything (frame_isr saves and restores all of it).
ays_tick:
 IFDEF DEBUG
    ld hl, akyTicks                  ; shared tick probe (Task 14), DEBUG-only
    inc (hl)
 ENDIF
    ld a, (aysPage)
    add a, PG_MUSIC
    nextreg NR_MMU6, a
    inc a
    nextreg NR_MMU7, a
    xor a
    ld (aysCross), a
    ld hl, (aysPtr)
    ld (aysStart), hl
    ld a, (aysPsgs)
    ld (aysLeft), a
    ld a, $FF
    ld (aysSel), a
.psg:
    ld a, (aysSel)
    exx
    ld bc, PSG_SEL_PORT
    out (c), a                       ; Turbo Sound: select the PSG
    exx
    call ays_rdb
    ld e, a
    call ays_rdb
    ld d, a                          ; DE = 14-bit change mask
    ld b, 0                          ; register number
.reg:
    srl d
    rr e
    jr nc, .next
    call ays_rdb
    ld c, a                          ; value
    ld a, b
    sub 8
    cp 3
    jr nc, .write                    ; not a volume register
    push hl                          ; shadow[(FF - sel)*3 + reg - 8] = value
    push de
    ld e, a
    ld a, (aysSel)
    cpl
    ld d, a
    ld a, e
    ld e, 3
    mul d, e
    add a, e
    ld hl, aysShadow
    add hl, a
    ld (hl), c
    pop de
    pop hl
.write:
    ld a, c
    AYS_WRITE
.next:
    inc b
    ld a, b
    cp 14
    jr c, .reg
    ld a, (aysSel)
    dec a
    ld (aysSel), a
    ld a, (aysLeft)
    dec a
    ld (aysLeft), a
    jr nz, .psg
    ld (aysPtr), hl
    ; consumed = (HL - start + crossings*$2000) mod 64K (a frame is far
    ; below 64K); remain -= consumed
    ld de, (aysStart)
    or a
    sbc hl, de
    ld a, (aysCross)
    or a
    jr z, .sub
    ld a, h
    add a, $20
    ld h, a
.sub:
    ex de, hl                        ; DE = consumed
    ld hl, (aysRemain)
    or a
    sbc hl, de
    ld (aysRemain), hl
    ld a, (aysRemainHi)
    sbc a, 0
    ld (aysRemainHi), a
    ld a, h
    or l
    ld hl, aysRemainHi
    or (hl)
    jr nz, .fade
    ; end of stream: back to the loop position
    ld a, (aysLoopPage)
    ld (aysPage), a
    ld hl, (aysLoopPtr)
    ld (aysPtr), hl
    ld hl, (aysLoopRemain)
    ld (aysRemain), hl
    ld a, (aysLoopRemainHi)
    ld (aysRemainHi), a
.fade:
    ld a, (fading)
    or a
    ret z
    ; rewrite every shadowed volume scaled: HL walks aysShadow in PSG order
    ld hl, aysShadow
    ld e, $FF
.fp:
    ld a, e
    exx
    ld bc, PSG_SEL_PORT
    out (c), a
    exx
    ld b, 8
.fr:
    ld a, (hl)
    push bc
    push de
    push hl
    call fade_scale_vol               ; corrupts D and E
    pop hl
    pop de
    pop bc
    AYS_WRITE                        ; B = register 8-10, A = scaled value
    inc hl
    inc b
    ld a, b
    cp 11
    jr c, .fr
    dec e
    ld a, e
    cp $FC
    jr nz, .fp
    ret

; Read one stream byte at HL, advancing across the page pair. Out A.
; When HL reaches $E000 the pair advances one page and HL returns to
; $C000, which holds the same byte in the new mapping. Corrupts AF only
; (and HL advances).
ays_rdb:
    ld a, h
    cp high WIN7
    jr z, .cross
.read:
    ld a, (hl)
    inc hl
    ret
.cross:
    ld hl, WIN6
    ld a, (aysPage)
    inc a
    ld (aysPage), a
    add a, PG_MUSIC
    nextreg NR_MMU6, a
    inc a
    nextreg NR_MMU7, a
    ld a, (aysCross)
    inc a
    ld (aysCross), a
    jr .read
