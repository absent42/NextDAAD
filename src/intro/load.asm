; Picture prefetch into the back surface: open, palette to PAL_NEW, then
; LOAD_CHUNK bytes per call into the surface pages through slot 6.

; A = slide index. The reads happen in load_service, one per call.
load_begin:
    ld (loadSlide), a
    ld a, LS_OPEN
    ld (loadState), a
    ret

load_service:
    ld a, (loadState)
    cp LS_OPEN
    jr z, .open
    cp LS_PAL
    jr z, .pal
    cp LS_PIX
    jr z, .pix
    ret
.open:
    ld a, (loadSlide)
    ld de, loadRec
    call slide_fetch_de              ; the loader's own copy of the record
    ld a, (loadRec+SL_MODE)
    ld (loadMode), a
    ld b, 10
    or a
    jr nz, .pg
    ld b, 6
.pg:
    ld a, b
    ld (loadPages), a
    ld a, (loadRec+SL_PIC)
    call name_picture
    call esx_open_name
    jr nc, .opened
    ld a, ERR_PIC_OPEN
    jp load_fail                     ; out of jr range from here
.opened:
    ld (loadHandle), a
    ld a, LS_PAL
    ld (loadState), a
    ret
.pal:
    ld a, PG_STAGE
    call map6
    ld a, (loadHandle)
    ld de, PAL_NEW-WIN6
    ld bc, 512
    call esx_read6
    jp c, .short                     ; out of jr range from here
    ld hl, 512
    or a
    sbc hl, bc
    jp nz, .short
    xor a
    ld (loadPage), a
    ld hl, 0
    ld (loadOfs), hl
    ld a, LS_PIX
    ld (loadState), a
    ret
.pix:
    ld a, (backBank)
    add a, a
    ld hl, loadPage
    add a, (hl)
    call map6
    ld a, (loadHandle)
    ld de, (loadOfs)
    ld bc, LOAD_CHUNK
    call esx_read6
    jr c, .short
    ld hl, LOAD_CHUNK
    or a
    sbc hl, bc
    jr nz, .short
    ld hl, (loadOfs)
    ld de, LOAD_CHUNK
    add hl, de
    ld (loadOfs), hl
    ld a, h
    cp $20
    ret nz                           ; page not yet full
    ld hl, 0
    ld (loadOfs), hl
    ld hl, loadPage
    inc (hl)
    ld a, (loadPages)
    cp (hl)
    ret nz
    ; whole surface in: the file must end here (one probe byte into page 39)
    ld a, PG_STAGE
    call map6
    ld a, (loadHandle)
    ld de, $1F00
    ld bc, 1
    call esx_read6
    jr c, .short
    ld a, b
    or c
    jr nz, .oversize
    ld a, (loadHandle)
    call esx_close_a
    ld a, $FF
    ld (loadHandle), a
    ld a, LS_DONE
    ld (loadState), a
    ret
.oversize:
    ld a, (loadHandle)
    call esx_close_a
    ld a, $FF
    ld (loadHandle), a
    ld a, ERR_PIC_SIZE
    jr load_fail
.short:
    ld a, (loadHandle)
    call esx_close_a
    ld a, $FF
    ld (loadHandle), a
    ld a, ERR_PIC_SHORT
load_fail:
    call dbg_code
    ld a, LS_FAIL
    ld (loadState), a
    ret

; A = picture number 1-64 -> nameBuf = "INTRO\NNN.NXC" (loadMode 1) or ".NXI".
name_picture:
    ld hl, picName
    ld c, '0'
.h:
    cp 100
    jr c, .t
    sub 100
    inc c
    jr .h
.t:
    ld (hl), c
    inc hl
    ld c, '0'
.t2:
    cp 10
    jr c, .u
    sub 10
    inc c
    jr .t2
.u:
    ld (hl), c
    inc hl
    add a, '0'
    ld (hl), a
    ld a, (loadMode)
    or a
    ld a, 'C'
    jr nz, .ext
    ld a, 'I'
.ext:
    ld (picName+6), a
    ld hl, picName
    jp name_intro
picName: db "000.NX?", 0
