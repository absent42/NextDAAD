; AKY: MUSIC.AKY (SongToAky at $C000, at most 16K) in pages 40 and 41,
; mapped at slots 6/7 for PLY_AKY_INIT and every tick. The player runs in
; the frame ISR; the interpreter's nest-safe player is included unchanged.
    ASSERT PG_MUSIC+1 <= PG_MUSIC_LAST
aky_open:
    ld hl, akyName
    call name_intro
    call esx_open_name
    jr nc, .ok
    ld a, ERR_MUS_OPEN
    jp dbg_code
.ok:
    ld (akyHandle), a
    ld a, PG_MUSIC
    call map6
    ld a, (akyHandle)
    ld de, 0
    ld bc, 8192
    call esx_read6                   ; song is variable length up to 16K;
    jr c, .bad                       ; CF alone flags a real I/O failure
    ld hl, 8192
    or a
    sbc hl, bc
    jr nz, .onepage                  ; short read: song fit in page 40, skip page 41
    ld a, PG_MUSIC+1
    call map6
    ld a, (akyHandle)
    ld de, 0
    ld bc, 8192
    call esx_read6
    jr c, .bad
.onepage:
    ld a, (akyHandle)
    call esx_close_a
    ld a, PG_MUSIC
    call map6
    ld a, (WIN6+1)
    cp 9
    jr nz, .hdr
    nextreg NR_MMU6, PG_MUSIC
    nextreg NR_MMU7, PG_MUSIC+1
    ld hl, WIN6
    call PLY_AKY_INIT
    ld a, 1
    ld (isrAudio), a
    ret
.bad:
    ld a, (akyHandle)
    call esx_close_a
    ld a, ERR_MUS_OPEN
    jp dbg_code
.hdr:
    ld a, ERR_MUS_HDR
    jp dbg_code
akyName:   db "MUSIC.AKY", 0
akyHandle: db 0

; ISR tick: song pages in, play, fade pass.
aky_tick:
    nextreg NR_MMU6, PG_MUSIC
    nextreg NR_MMU7, PG_MUSIC+1
    call PLY_AKY_PLAY
 IFDEF DEBUG
    ld hl, akyTicks
    inc (hl)
 ENDIF
    jp psg_fade_pass
