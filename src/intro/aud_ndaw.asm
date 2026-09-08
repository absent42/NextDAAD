; NextDAW runtime player (E000 build) in page 40, mapped at slot 7 around
; each call; the song in pages 41-48 named by ndrPages. Update runs from the
; main loop once per frame.
NDAW_INIT_SONG   equ WIN7+0
NDAW_UPDATE      equ WIN7+3
NDAW_PLAY        equ WIN7+6
NDAW_STOP        equ WIN7+9
NDAW_STOP_HARD   equ WIN7+12
NDAW_INIT_SYSTEM equ WIN7+21

    ASSERT PG_MUSIC+8 <= PG_MUSIC_LAST   ; the 8-page song cap (rubric 8)
ndaw_open:
    ld hl, ndawName
    call name_intro
    call esx_open_name
    jr nc, .p
    ld a, ERR_MUS_NDAW
    jp dbg_code
.p:
    ld (ndawHandle), a
    ld a, PG_MUSIC
    call map6
    ld a, (ndawHandle)
    ld de, 0
    ld bc, 8192
    call esx_read6
    push bc
    push af
    ld a, (ndawHandle)
    call esx_close_a
    pop af
    pop bc
    jr c, .nobin
    ld hl, 39
    or a
    sbc hl, bc
    jr c, .song
    jr z, .song
.nobin:
    ld a, ERR_MUS_NDAW
    jp dbg_code
.song:
    ld hl, ndrName
    call name_intro
    call esx_open_name
    jr nc, .s
    ld a, ERR_MUS_OPEN
    jp dbg_code
.s:
    ld (ndawHandle), a
    xor a
    ld (ndrCount), a
.pg:
    ld a, (ndrCount)
    cp 8
    jr z, .peek                      ; 8 pages already: check for a spurious 9th
    add a, PG_MUSIC+1
    call map6
    ld hl, ndrPages
    ld a, (ndrCount)
    add hl, a
    ld a, (ndrCount)
    add a, PG_MUSIC+1
    ld (hl), a
    ld a, (ndawHandle)
    ld de, 0
    ld bc, 8192
    call esx_read6
    jr c, .bad
    ld a, b
    or c
    jr z, .eof                       ; nothing read: previous page was the last
    ld hl, ndrCount
    inc (hl)
    ld a, b
    cp $20
    jr z, .pg                        ; a full page: there may be more
    jr .eof
.peek:                                ; a scratch page past the 8-page cap; discard
    ld a, PG_MUSIC+9                  ; the bytes, only the count matters
    call map6
    ld a, (ndawHandle)
    ld de, 0
    ld bc, 8192
    call esx_read6
    jr c, .bad
    ld a, b
    or c
    jr nz, .toobig                   ; a real 9th page exists: over the cap
.eof:
    ld a, (ndawHandle)
    call esx_close_a
    ld a, (ndrCount)
    or a
    jr z, .hdr
    ; init: system slots, song table, play; then save the slot mappings
    ld a, PG_MUSIC
    call map7
    push ix
    ld l, 2
    ld h, 3
    ld c, 6
    call NDAW_INIT_SYSTEM
    ld de, ndrPages
    xor a
    call NDAW_INIT_SONG
    call NDAW_PLAY
    pop ix
    call ndaw_slots_save
    ld a, 1
    ld (ndawOn), a
    jp map_bank5
.toobig:
.bad:
    ld a, (ndawHandle)
    call esx_close_a
.hdr:
    ld a, ERR_MUS_HDR
    jp dbg_code
ndawName:   db "NDAW.BIN", 0
ndrName:    db "MUSIC.NDR", 0
ndawHandle: db 0
ndrCount:   db 0
ndawOn:     db 0

; Once per frame from the main loop.
ndaw_frame:
    ld a, (ndawOn)
    or a
    ret z
    call ndaw_slots_load
    ld a, PG_MUSIC
    call map7
    push ix
    call NDAW_UPDATE
    pop ix
    call ndaw_slots_save
    jp map_bank5

; END fade: soft stop, keep updating so the notes release.
ndaw_fade_begin:
    ld a, (ndawOn)
    or a
    ret z
    call ndaw_slots_load
    ld a, PG_MUSIC
    call map7
    push ix
    call NDAW_STOP
    pop ix
    call ndaw_slots_save
    jp map_bank5

ndaw_stop:
    ld a, (ndawOn)
    or a
    ret z
    xor a
    ld (ndawOn), a
    call ndaw_slots_load
    ld a, PG_MUSIC
    call map7
    push ix
    call NDAW_STOP_HARD
    pop ix
    jp map_bank5

ndaw_slots_save:
    ld e, NR_MMU2
    call nr_read
    ld (ndawSlots+0), a
    ld e, NR_MMU3
    call nr_read
    ld (ndawSlots+1), a
    ld e, NR_MMU6
    call nr_read
    ld (ndawSlots+2), a
    ret
ndaw_slots_load:
    ld a, (ndawSlots+0)
    nextreg NR_MMU2, a
    ld a, (ndawSlots+1)
    nextreg NR_MMU3, a
    ld a, (ndawSlots+2)
    nextreg NR_MMU6, a
    ret
