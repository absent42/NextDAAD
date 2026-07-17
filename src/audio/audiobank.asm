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
aud_tick:
    ld a, (audFlags)
    ; audRequest consumption lands in Task 4
    or a
    ret z
    bit 0, a
    call nz, PLY_AKY_PLAY           ; music (+ effects on PSG 3)
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
    ASSERT audFlags == AUD_STATE
    ASSERT $ <= $10000               ; bank ends inside the 64K map
