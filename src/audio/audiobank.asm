; Audio bank (bank 24, 8K pages 48/49, MMU slots 6/7 at $C000-$FFFF).
; Converted Arkos AKY multi-PSG player + per-frame tick + BEEP tone
; engine + AY period table + state block. Mapped at $C000-$FFFF only
; inside the ISR and the mainline audio-load brackets - never
; resident. Layout per the AUD_* equates in nextdaad.inc:
;   $C000 AUD_PLAYER_ORG  player, aud_tick, BEEP engine, period table
;   $D000 AUD_SFB_ORG     sound-effects bank (2K)
;   $D800 AUD_SONG_ORG    current song (AUD_SONG_MAX bytes)
;   $FFE0 AUD_STATE       audFlags / beep state / song number

    MMU 6 7, AUD_PAGE_LO, AUD_PLAYER_ORG

    include "player_aky.asm"

; --- per-frame tick --------------------------------------------------

; Per-frame audio tick. Called by the ISR with interrupts off, bank 24
; mapped, ALL registers already saved by the caller. Corrupts anything
; (PLY_AKY_PLAY repoints SP internally; it restores it before ret).
;
; PLY_AKY_INIT entry contract, verified against the converted source:
; its first instructions are "inc hl / ld a,(hl)" - HL = song address;
; the entry value of A is overwritten immediately, so the AKY player
; has no subsong parameter (AKY exports bake in one subsong). Callers
; load HL only.
;
; Request consumption (Task 4): audRequest and the audReq* parameter
; bytes are resident at $8xxx, visible from ISR context regardless of
; the slot 6/7 mapping. Each set bit is consumed with a single res on
; the resident byte - atomic against mainline because the ISR runs
; with interrupts off. Consumption order is 5 (init effects), 3 (stop
; music), 4 (start music), 2 (stop effect), 1 (play effect), 0 (beep)
; so that a stale stop filed while audio was off can never kill a
; same-frame start.
;
; Player gate: PLY_AKY_PLAY runs when audFlags bit 0 (music) OR bit 2
; (effect active) is set - the player is also what advances PSG-3
; effects. The music machinery must be initialised before the first
; PLAY (an un-initialised linker pointer would pop garbage), so
; effect-only use lazy-inits to the built-in silence song
; (aud_ensure_player).
;
; Effect-end detection: a finished non-looping effect zeroes its
; channel stream pointer (PLY_AKY_PSES_S_ENDORLOOP writes 0 to
; PLY_AKY_CHANNEL1_SOUNDEFFECTDATA). aud_tick watches that word while
; audFlags bit 2 is set and clears the bit when it goes zero, so the
; play gate narrows again and BEEP regains PSG 3.
aud_tick:
    ld hl, audRequest
    ld a, (hl)
    or a
    jp z, .noreq
    ; bit 5: init the sound-effects table (GAME.SFB at AUD_SFB_ORG)
    bit 5, (hl)
    jr z, .no5
    res 5, (hl)
    ld hl, AUD_SFB_ORG
    call PLY_AKY_INITSOUNDEFFECTS
    ld hl, audRequest
.no5:
    ; bit 3: stop music - BEFORE bit 4, see the header
    bit 3, (hl)
    jr z, .no3
    res 3, (hl)
    call aud_music_stop
    ld hl, audRequest
.no3:
    ; bit 4: start the song already loaded at AUD_SONG_ORG
    bit 4, (hl)
    jr z, .no4
    res 4, (hl)
    ld hl, AUD_SONG_ORG
    call PLY_AKY_INIT               ; also zeroes the effect channels
    ld a, 1
    ld (audPlayerUp), a
    ld a, (audFlags)
    and %00001000                   ; keep beep; effect died with INIT
    or %00000001                    ; music playing
    ld hl, audReqLoop
    bit 0, (hl)
    jr z, .noloop
    or %00000010                    ; music looping
.noloop:
    ld (audFlags), a
    ld hl, audRequest
.no4:
    ; bit 2: stop any effect (channels 0-2 for completeness)
    bit 2, (hl)
    jr z, .no2
    res 2, (hl)
    xor a
    call PLY_AKY_STOPSOUNDEFFECTFROMCHANNEL
    ld a, 1
    call PLY_AKY_STOPSOUNDEFFECTFROMCHANNEL
    ld a, 2
    call PLY_AKY_STOPSOUNDEFFECTFROMCHANNEL
    ld hl, audFlags
    res 2, (hl)
    ld hl, audRequest
.no2:
    ; bit 1: play effect audReqSfx on PSG 3 channel 0, full volume
    bit 1, (hl)
    jr z, .no1
    res 1, (hl)
    call aud_ensure_player
    ld a, (audReqSfx)
    ld bc, $0000                    ; B = inverted volume (0 = max),
                                    ; C = channel 0
    call PLY_AKY_PLAYSOUNDEFFECT
    ld hl, audFlags
    set 2, (hl)
    ld hl, audRequest
.no1:
    ; bit 0: beep. Effect priority: while an effect owns PSG 3
    ; (audFlags bit 2) the beep is dropped entirely - h_beep's wait
    ; is time-based and completes regardless.
    bit 0, (hl)
    jr z, .noreq
    res 0, (hl)
    ld a, (audFlags)
    bit 2, a
    jr nz, .noreq
    ld a, (audReqIdx)
    add a, a
    ld hl, audPeriods
    add hl, a
    ld e, (hl)
    inc hl
    ld d, (hl)
    call aud_beep_start
    ld hl, audFlags
    set 3, (hl)
    ld a, (audReqDur)
    ld l, a
    ld h, 0
    ld (audBeepFrames), hl
.noreq:
    ld a, (audFlags)
    or a
    ret z
    and %00000101                   ; music playing OR effect active
    call nz, PLY_AKY_PLAY           ; music + effects on PSG 3
    ; effect-end watch (see header)
    ld a, (audFlags)
    bit 2, a
    jr z, .beep
    ld hl, (PLY_AKY_CHANNEL1_SOUNDEFFECTDATA)
    ld a, h
    or l
    jr nz, .beep
    ld hl, audFlags
    res 2, (hl)
.beep:
    ld a, (audFlags)
    bit 3, a
    ret z
    ; BEEP countdown: period already programmed by aud_beep_start;
    ; count frames, silence on zero.
    ld hl, (audBeepFrames)
    dec hl
    ld (audBeepFrames), hl
    ld a, h
    or l
    ret nz
    call aud_beep_silence
    ld hl, audFlags
    res 3, (hl)
    ret

; Stop the music: re-point the player at the built-in silence song
; (so a later effect-only PLY_AKY_PLAY cannot resume the old song),
; preserving any active effect stream across PLY_AKY_INIT's channel
; wipe, then silence the PSGs the player will no longer refresh.
; Clears audFlags bits 0-1. Corrupts AF, BC, DE, HL.
aud_music_stop:
    ld hl, (PLY_AKY_CHANNEL1_SOUNDEFFECTDATA)
    push hl
    ld hl, audSilenceSong
    call PLY_AKY_INIT
    pop hl
    ld (PLY_AKY_CHANNEL1_SOUNDEFFECTDATA), hl
    ld a, 1
    ld (audPlayerUp), a
    ld hl, audFlags
    res 0, (hl)
    res 1, (hl)
    ; PSG 1/2 are music-only: silence them now (nothing rewrites them
    ; until the next start-music)
    ld a, $FF
    call aud_psg_silence
    ld a, $FE
    call aud_psg_silence
    ; PSG 3 carried music channels 7-9 too, but a beep or an effect
    ; may own it: leave it to them (the silence song re-silences
    ; channels 8/9 on every effect tick). Only silence it when free.
    ld a, (audFlags)
    and %00001100
    ret nz
    ld a, $FD
    jp aud_psg_silence

; Lazy player bring-up for effect-only use: PLY_AKY_PLAY must never
; run before some PLY_AKY_INIT (see aud_tick header). Corrupts
; AF, DE, HL.
aud_ensure_player:
    ld a, (audPlayerUp)
    or a
    ret nz
    ld hl, audSilenceSong
    call PLY_AKY_INIT
    ld a, 1
    ld (audPlayerUp), a
    ret

; Silence one PSG: A = Turbo Sound select value ($FF/$FE/$FD).
; Mixer R7 all off, volumes R8/R9/R10 = 0 - same recipe as boot's
; audio_init. Corrupts AF, BC.
aud_psg_silence:
    call aud_psg3_select
    ld b, 7
    ld c, $3F
    call aud_psg3_write
    ld b, 8
    ld c, 0
    call aud_psg3_write
    ld b, 9
    ld c, 0
    call aud_psg3_write
    ld b, 10
    ld c, 0
    jp aud_psg3_write

; --- BEEP tone engine ------------------------------------------------

; Program PSG 3: tone A on channel A(0) of PSG 3, volume 15.
; DE = AY period (from audPeriods). Returns without touching the
; registers when a sound effect is active on PSG 3 (audFlags bit 2) -
; the effect-priority rule. Caller sets audFlags bit 3 and
; audBeepFrames; aud_tick counts down and silences.
; Corrupts AF, BC. Preserves DE, HL.
aud_beep_start:
    ld a, (audFlags)
    bit 2, a
    ret nz
    ld a, $FD                        ; Turbo Sound select PSG 3 - same
                                     ; inlined value the player uses
                                     ; ("ld d,$fd", no named constant
                                     ; survives Disark)
    call aud_psg3_select
    ld b, 0                          ; R0 = tone A fine
    ld c, e
    call aud_psg3_write
    ld b, 1                          ; R1 = tone A coarse
    ld c, d
    call aud_psg3_write
    ld b, 7                          ; R7 mixer: tone A on, rest off
    ld c, %00111110
    call aud_psg3_write
    ld b, 8                          ; R8 volume A = 15
    ld c, 15
    jp aud_psg3_write

; Silence the BEEP channel: volume 0, mixer all off. Re-selects PSG 3
; first (cheap, and keeps this safe if other code ever leaves another
; PSG selected). Corrupts AF, BC. Preserves DE, HL.
aud_beep_silence:
    ld a, $FD
    call aud_psg3_select
    ld b, 8
    ld c, 0
    call aud_psg3_write
    ld b, 7
    ld c, %00111111
    jp aud_psg3_write

; Turbo Sound chip select: A = select value ($FF/$FE/$FD) to port
; $FFFD, mirroring the player's PLY_AKY_SENDPSGREGISTERS sequence
; ("ld bc,$fffd / out (c),d"). Corrupts BC. Preserves AF, DE, HL.
aud_psg3_select:
    ld bc, $FFFD
    out (c), a
    ret

; Write one AY register on the currently selected PSG: B = register
; number, C = value. Register number to $FFFD, data to $BFFD - the
; same two ports the player drives (its data writes go through outi
; with B = $C0, i.e. port $BFFD after outi's pre-decrement).
; Corrupts BC. Preserves AF, DE, HL.
aud_psg3_write:
    push de
    ld d, b                          ; register number
    ld e, c                          ; data value
    ld bc, $FFFD
    out (c), d                       ; register select
    ld b, $BF
    out (c), e                       ; data
    pop de
    ret

; --- AY period table -------------------------------------------------

; jdaad FREQ_TABLE periods, AY clock 1773400 Hz (see the generator in
; the SP7 plan). The lowest notes' true periods exceed the AY's
; 12-bit tone range and clamp to 4095, exactly as jdaad's table does.
    include "aud_periods.inc"

; --- built-in silence song -------------------------------------------

; A minimal, always-resident AKY song whose every frame programs
; volume 0 / no software / no hardware on all 9 channels. Two roles:
; 1. play-once terminal: aud_repoint_loop (overlay1) patches a loaded
;    song's terminal loop word to audSilenceLinker, so the tune plays
;    through once and then plays silence indefinitely;
; 2. safe player state: aud_music_stop/aud_ensure_player INIT the
;    player to audSilenceSong so effect-only PLY_AKY_PLAY runs real
;    (silent) music machinery instead of popping garbage.
; Layout verified against real SongToAky binary exports (Task 4
; report): header = format byte, channel-count byte, 4 bytes per PSG;
; the linker follows immediately (dw duration + one track pointer per
; channel per entry, dw 0 + dw loop pointer at the end); tracks are
; "db wait / dw register block" entries. PLY_AKY_INIT skips 2 + 12
; header bytes, so the linker must sit at song + 14 (3-PSG shape).
audSilenceSong:
    db $81                          ; format: version 1, little-endian
    db 9                            ; channels (3 PSGs; read + ignored)
    ds 12, 0                        ; per-PSG frequency bytes (skipped)
audSilenceLinker:
    dw 1                            ; duration 1 frame: the linker
                                    ; re-arms every tick, so only the
                                    ; block's initial state is ever read
    dw audSilentTrack, audSilentTrack, audSilentTrack
    dw audSilentTrack, audSilentTrack, audSilentTrack
    dw audSilentTrack, audSilentTrack, audSilentTrack
    dw 0                            ; end of song
    dw audSilenceLinker             ; loop to itself: silence forever
audSilentTrack:
    db 1                            ; wait count (moot at duration 1)
    dw audSilentBlock
audSilentBlock:
    db 0                            ; initial state: no software, no
                                    ; hardware, no noise, volume 0

    ASSERT $ <= AUD_SFB_ORG          ; player+tick+beep+table fit 4K

; --- effects bank / song / state ------------------------------------

    org AUD_SFB_ORG
audSfbArea: ds AUD_SONG_ORG - AUD_SFB_ORG
    org AUD_SONG_ORG
audSongArea: ds AUD_SONG_MAX
    ASSERT $ <= AUD_STATE            ; song area ends at the state block
    org AUD_STATE
audFlags:      db 0                  ; bit 0 music playing, bit 1 music
                                     ; looping, bit 2 effect active,
                                     ; bit 3 beep active
audBeepFrames: dw 0
audBeepPeriod: dw 0
audSongNum:    db $FF                ; $FF = none/GAME.AKY
audPlayerUp:   db 0                  ; 1 once PLY_AKY_INIT has run
                                     ; (aud_ensure_player gate; reset
                                     ; by aud_boot_probe on warm boot)
    ASSERT audFlags == AUD_STATE
    ASSERT $ <= $10000               ; bank ends inside the 64K map
