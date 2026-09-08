; AYS resident applier (aysconv.ps1 format). Whole file in pages 40..87,
; read through slot 6 only - a page crossing remaps NR_MMU6 and resumes
; at WIN6. Header layout: intro.inc AYS_HDR_* equates.
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
    ld hl, WIN6+AYS_HDR_MAGIC
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
    ld a, (WIN6+AYS_HDR_PSGS)
    or a
    jp z, .hdr
    cp 4
    jp nc, .hdr
    ld (aysPsgs), a
    ; 16 + streamLength must fit inside the loaded pages: reject a
    ; header/file-size disagreement, matching overlay1.asm's own check.
    ld hl, (WIN6+AYS_HDR_STREAMLEN)
    ld de, 16
    add hl, de
    ld a, (WIN6+AYS_HDR_STREAMLEN+2)
    adc a, 0                         ; A:HL = needed (16 + streamLength)
    ex de, hl                        ; DE = needed low16
    push af
    ld a, (aysPages)
    ld c, a
    and 7
    add a, a
    add a, a
    add a, a
    add a, a
    add a, a                         ; A = (pages&7)<<5 = capacity low16 hi byte
    ld h, a
    ld l, 0                          ; HL = capacity low16 (pages*8192 mod 65536)
    or a
    sbc hl, de                       ; capacity low16 - needed low16
    ld a, c
    srl a
    srl a
    srl a                            ; A = pages>>3 = capacity high byte
    pop de                           ; D = needed high byte
    sbc a, d                         ; capacity - needed (24-bit)
    jp c, .hdr                       ; needed > capacity: reject
    ; stream length -> remain
    ld hl, (WIN6+AYS_HDR_STREAMLEN)
    ld (aysRemain), hl
    ld a, (WIN6+AYS_HDR_STREAMLEN+2)
    ld (aysRemainHi), a
    ; loopOffset must be < streamLength (matches overlay1.asm's own header
    ; check; loopOffset >= streamLength would compute a negative loop
    ; remainder below)
    ld hl, (WIN6+AYS_HDR_LOOPOFF)
    ld de, (WIN6+AYS_HDR_STREAMLEN)
    or a
    sbc hl, de
    ld a, (WIN6+AYS_HDR_LOOPOFF+2)
    ld hl, WIN6+AYS_HDR_STREAMLEN+2
    sbc a, (hl)
    jp nc, .hdr
    ; loop position: absolute offset 16 + loopOffset -> page and pointer
    ld hl, (WIN6+AYS_HDR_LOOPOFF)
    ld a, (WIN6+AYS_HDR_LOOPOFF+2)
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
    ld hl, (WIN6+AYS_HDR_STREAMLEN)
    ld de, (WIN6+AYS_HDR_LOOPOFF)
    or a
    sbc hl, de
    ld (aysLoopRemain), hl
    ld a, (WIN6+AYS_HDR_STREAMLEN+2)
    ld hl, WIN6+AYS_HDR_LOOPOFF+2
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
aysLoopPage: db 0
aysLoopPtr:  dw 0
aysLoopRemain: dw 0
aysLoopRemainHi: db 0
aysSel:    db 0
aysLeft:   db 0
aysShadow: ds 9                      ; last written R8-R10 per PSG
aysStart:  dw 0                      ; stream pointer at the frame's start
aysCross:  db 0                      ; page crossings this frame (0 or 1)

; AY register write from the frame ISR: A = value, B = register.
; Preserves main AF, BC, DE, HL (both ex af,af'/exx pairs balance);
; corrupts AF' and BC' only (the alternate port-select scratch).
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

; ISR tick: HL=pointer, DE=mask, B=register, C=value; walk one frame,
; remap slot 6 on a page crossing, loop at end-of-stream, fade pass.
; Bounded to 48 ays_rdb calls/frame; corrupts everything (ISR saves all).
ays_tick:
 IFDEF DEBUG
    ld hl, akyTicks                  ; shared tick probe (Task 14), DEBUG-only
    inc (hl)
 ENDIF
    ld a, (aysPage)
    add a, PG_MUSIC
    nextreg NR_MMU6, a
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
    jr c, .rewind                    ; borrow: consumed more than remained
    ld a, h
    or l
    ld hl, aysRemainHi
    or (hl)
    jr nz, .fade
.rewind:
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

; Read one stream byte at HL, out A. HL reaching $E000 means slot 6's
; page is exhausted: remap to the next page and continue at $C000.
; Corrupts AF only; HL advances.
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
    ld a, (aysCross)
    inc a
    ld (aysCross), a
    jr .read
