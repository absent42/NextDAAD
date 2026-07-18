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
; with interrupts off. Consumption order is 7 (stop sample), 6 (start
; sample), 5 (init effects), 3 (stop music), 4 (start music), 2 (stop
; effect), 1 (play effect), 0 (beep) so that a stale stop filed while
; audio was off can never kill a same-frame start. The sample refeed
; (aud_smp_tick) runs every tick regardless of audFlags.
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
    ; bit 7: stop sample (before bit 6: a stale stop must not kill a
    ; same-frame start - mirrors the bit 3/4 music rule)
    bit 7, (hl)
    jr z, .no7
    res 7, (hl)
    call aud_smp_stop
    ld hl, audRequest
.no7:
    ; bit 6: start the sample staged in the smpPageTab pages
    bit 6, (hl)
    jr z, .no6
    res 6, (hl)
    call aud_smp_start
    ld hl, audRequest
.no6:
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
    ; An explicit stop must silence PSG 3 now. The player only re-asserts
    ; PSG 3 volumes from a subsequent PLY_AKY_PLAY, and that runs only
    ; when audFlags still has music (bit 0) or effect (bit 2) set - an
    ; effect-only stop drops audFlags to 0 and aud_tick returns before
    ; the play gate, leaving the effect's last registers ringing. Mirror
    ; the effect-end watch's no-music branch, but unconditionally: PSG 3
    ; ($FD) carries only music channels 7-9, so this cannot dent channels
    ; 1-6 (PSG 1/2), and when music IS playing the same-frame play gate
    ; overwrites this with the correct music state.
    ld a, $FD
    call aud_psg_silence
    ld hl, audRequest
.no2:
    ; bit 1: play effect audReqSfx on PSG 3 channel 0, full volume
    bit 1, (hl)
    jr z, .no1
    res 1, (hl)
    ; no GAME.SFB loaded: the effect-table operand is still 0 and a
    ; play would install a wild stream pointer (audible garbage) -
    ; consume the request as the documented no-op instead
    ld hl, (PLY_AKY_PTSOUNDEFFECTTABLE+1)
    ld a, h
    or l
    ld hl, audRequest               ; flags survive the reload
    jr z, .no1
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
    bit 2, a                        ; deliberately redundant with
    jr nz, .noreq                   ; aud_beep_start's own bit-2 guard:
                                    ; this copy also skips the stale
                                    ; audFlags/audBeepFrames writes
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
    call aud_smp_tick           ; sample refeed (self-gated on smpFlags)
    ld a, (audFlags)
    or a
    ret z
    ; terminal watch: a play-once song that has reached the built-in
    ; silence pattern is over. The player's linker position lives in
    ; the PLY_AKY_PATTERNFRAMECOUNTER_OVER+1 operand (PLY_AKY_INIT
    ; seeds it, each linker entry read stores the advanced SP there);
    ; when it points inside audSilenceSong, clear the music bits,
    ; silence the music PSGs and stop calling the player for music -
    ; this both restores BEEP after a play-once tune (an open gate
    ; re-sends PSG 3 over any beep every tick) and stops burning a
    ; 9-channel player tick on silence forever. Effects gate
    ; unaffected (bit 2 keeps PLY_AKY_PLAY running while needed).
    bit 0, a
    jr z, .gate
    ld hl, (PLY_AKY_PATTERNFRAMECOUNTER_OVER+1)
    ld de, audSilenceSong
    or a
    sbc hl, de
    jr c, .gate                     ; below the pattern: song still on
    ld de, audSilenceEnd-audSilenceSong
    sbc hl, de                      ; CF clear from the jr c above
    jr nc, .gate                    ; above the pattern: song still on
    ld hl, audFlags
    res 0, (hl)
    res 1, (hl)
    ld a, $FF                       ; PSG 1/2 are music-only: park
    call aud_psg_silence            ; them (PSG 3 is left to any beep
    ld a, $FE                       ; or effect; the silence song has
    call aud_psg_silence            ; already zeroed its volumes)
.gate:
    ld a, (audFlags)
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
    ; with no music the player stops ticking here, so an effect whose
    ; final cell is not volume-0 would leave PSG 3 ringing - silence
    ; it now (music, when playing, rewrites PSG 3 every frame anyway)
    bit 0, (hl)
    jr nz, .beep
    ld a, $FD
    call aud_psg_silence
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

; --- sampled sound engine (SP8) --------------------------------------

; Start the sample staged in the smpPageTab pages by aud_load_wav, using
; the resident audReqSmp* parameters. Runs in ISR context. Source position
; starts at table index 0 (smpTabIdx), offset 0; length is 24-bit.
aud_smp_start:
    ld a, (audReqSmpPre)
    ld (smpPre), a
    ld hl, (audReqSmpChunk)
    ld (smpChunk), hl
    ld a, (audReqSmpFrac)
    ld (smpFrac), a
    xor a
    ld (smpAcc), a
    ld (smpHalf), a
    ld (smpTabIdx), a           ; start at the first page-table entry
    ld hl, (audReqSmpLen)       ; 24-bit payload length
    ld (smpLen), hl
    ld (smpRemain), hl
    ld a, (audReqSmpLenHi)
    ld (smpLenHi), a
    ld (smpRemainHi), a
    ld hl, 0
    ld (smpOff), hl
    ld (smpLast), hl            ; nothing in flight yet
    ld a, (audReqSmpLoop)
    and 1
    add a, a                    ; -> bit 1
    or 1                        ; bit 0 active
    ld (smpFlags), a
    ret

; Stop: disable the DMA, park the DAC at centre, clear the state.
; Idempotent. Runs in ISR context (also reachable via aud_smp_tick's
; play-once end).
aud_smp_stop:
    xor a
    ld (smpFlags), a
    ld (smpLast), a
    ld (smpLast+1), a           ; no in-flight baseline survives a stop
    ld a, $83                   ; WR6: disable DMA
    ld bc, DMA_PORT
    out (c), a
    ld a, $80                   ; DAC centre = silence
    ld bc, DAC_PORT
    out (c), a
    ret

; Per-frame refeed, CONSUMED-BASED (probe-driven design change): the
; source position advances only by bytes the DMA actually transferred
; last frame (read from its byte counter), so an under-nominal DMA
; (bus contention measured ~5% worst case) re-sends the unplayed tail
; instead of clipping it - gapless, self-regulating, pitch = true
; effective rate. Flow per tick with a sample active:
;   1. disable the DMA ($83), read the byte counter, clamp to the
;      length programmed last tick (smpLast; counter semantics near
;      end-of-block are model-fuzzy, the clamp caps any excess),
;   2. advance smpOff/smpTabIdx/smpRemain by CONSUMED (smpRemain is
;      24-bit; it hits 0 only when every payload byte has truly played;
;      smpTabIdx steps to the next smpPageTab entry on each $2000 cross),
;   3. on smpRemain = 0: play-once -> aud_smp_stop; loop -> rewind,
;   4. compute this frame's chunk (whole + fractional carry, clamped
;      to remain), copy it from (smpPageTab[smpTabIdx], smpOff) into the
;      idle staging half THROUGH MMU SLOT 7 (this code executes from slot
;      6 - see the task header; slot 7 restored to AUD_PAGE_HI before
;      any state writeback), program the DMA, record smpLast. The page
;      table lives in page-48 code space (slot 6), which stays mapped
;      throughout the tick, so it is readable even while slot 7 windows
;      a source page.
; A first-start tick has smpLast = 0 (aud_smp_start zeroes it), so
; step 1-2 advance by nothing and step 4 programs the first chunk.
aud_smp_tick:
    ld a, (smpFlags)
    rrca
    ret nc                      ; bit 0 clear: nothing active
    ; --- consume last frame's transfer ---
    ld a, $83                   ; disable the DMA: freezes the counter
    ld bc, DMA_PORT             ; and makes the reprogram below safe
    out (c), a
    ld hl, (smpLast)
    ld a, h
    or l
    jr z, .advanced             ; nothing in flight (first tick)
    ld a, $BB                   ; WR6 read-mask command
    ld bc, DMA_PORT
    out (c), a
    ld a, %00000110             ; mask: byte counter low + high
    out (c), a
    in a, (c)                   ; counter low
    ld e, a
    in a, (c)                   ; counter high
    ld d, a                     ; DE = bytes transferred last frame
    ld hl, (smpLast)
    or a
    sbc hl, de
    jr nc, .clamped             ; counter <= programmed: take it
    ld de, (smpLast)            ; counter overran (end-of-block
.clamped:                       ; semantics): clamp to programmed
    ; advance source by DE consumed: remain -= DE (24-bit), off += DE
    ; (smpTabIdx steps to the next table page on the $2000 crossing)
    ld hl, (smpRemain)
    or a
    sbc hl, de                  ; low word -= consumed, CF = borrow
    ld a, (smpRemainHi)
    sbc a, 0                    ; high byte -= borrow
    jr nc, .remstore            ; no underflow past the high byte
    ld hl, 0                    ; defensive floor: cannot truly underflow
    xor a                       ; while DE stays clamped to smpLast <= remain
.remstore:
    ld (smpRemain), hl
    ld (smpRemainHi), a
    ld hl, (smpOff)
    add hl, de
    ld a, h
    cp $20
    jr c, .offok                ; still inside the 8K page
    sub $20                     ; rolled: off -= $2000, next table page
    ld h, a
    ld a, (smpTabIdx)
    inc a
    ld (smpTabIdx), a
.offok:
    ld (smpOff), hl
    xor a
    ld (smpLast), a
    ld (smpLast+1), a
.advanced:
    ; --- end of payload? (24-bit remain drained) ---
    ld hl, (smpRemain)
    ld a, (smpRemainHi)
    or h
    or l
    jr z, .drained              ; all three bytes zero: payload played out
    ; defensive: smpTabIdx must index a live table entry before the copy
    ; maps a source page. In normal flow the drained test above fires on
    ; the same tick the index would overrun; a >= here means corrupted
    ; state, so treat it as drained (stop or rewind).
    ld a, (smpTabIdx)
    ld hl, smpPageCnt
    cp (hl)
    jr c, .sized                ; idx < count: normal
.drained:
    ld a, (smpFlags)
    bit 1, a
    jp z, aud_smp_stop          ; play-once: everything has played (jp:
                                ; out of jr range from here)
    ld hl, (smpLen)             ; loop: rewind to the payload start
    ld (smpRemain), hl
    ld a, (smpLenHi)
    ld (smpRemainHi), a
    xor a
    ld (smpTabIdx), a           ; back to the first table page
    ld hl, 0
    ld (smpOff), hl
.sized:
    ; chunk = smpChunk + (carry from smpAcc += smpFrac overflowing 50)
    ld a, (smpAcc)
    ld e, a
    ld a, (smpFrac)
    add a, e
    cp 50
    ld hl, (smpChunk)
    jr c, .noc
    sub 50
    inc hl
.noc:
    ld (smpAcc), a
    ; clamp to what remains: BC = copy length. smpRemain is NOT
    ; decremented here - consumption is what decrements it (step 2).
    ; smpRemain is 24-bit: a nonzero high byte means remain far exceeds
    ; the chunk (chunk <= AUD_STAGE_HALF), so the whole chunk always fits
    ; and the low-word compare must be skipped (it would misclamp).
    ld a, (smpRemainHi)
    or a
    jr nz, .fullchunk
    ld de, (smpRemain)
    or a
    sbc hl, de
    jr c, .restorechunk         ; chunk < remain: full chunk
    ld b, d                     ; final stretch: program exactly the
    ld c, e                     ; rest
    jr .copy
.restorechunk:
    add hl, de                  ; HL = chunk again
.fullchunk:
    ld b, h
    ld c, l
    ; fall through to .copy
.copy:
    ; Stage the copy parameters in scratch while slot 7 still holds
    ; the state page, then do the whole copy with registers only.
    ; The copy is a pure READ of the source window: smpOff/smpTabIdx
    ; are NOT advanced here (consumption advances them next tick).
    ; Fetch the current and next source pages from smpPageTab (page 48,
    ; slot 6 - readable now and throughout the slot-7 remap below).
    ; smpTabIdx < smpPageCnt is guaranteed here (drained test above); the
    ; +1 read is in-bounds because a crossing (part2 > 0) only happens
    ; while a further payload page exists, and smpPageCnt (the adjacent
    ; byte) backstops the table's last entry regardless.
    ld (smpTickLen), bc
    ld hl, (smpOff)
    ld (smpTickOff), hl
    ld a, (smpTabIdx)
    ld e, a
    ld d, 0
    ld hl, smpPageTab
    add hl, de
    ld a, (hl)                  ; current page = smpPageTab[smpTabIdx]
    ld (smpTickPage), a
    inc hl
    ld a, (hl)                  ; next page = smpPageTab[smpTabIdx+1]
    ld (smpTickPage2), a
    ld a, (smpHalf)
    ld de, AUD_STAGE0
    or a
    jr z, .dset
    ld de, AUD_STAGE1
.dset:
    ld (smpTickDst), de
    ; part 1 length = min(len, $2000 - off)
    ld hl, $2000
    ld bc, (smpTickOff)
    or a
    sbc hl, bc                  ; HL = room in this page
    ld bc, (smpTickLen)
    or a
    sbc hl, bc
    jr nc, .onepart             ; room >= len: single copy
    ; two parts: part1 = room, part2 = len - room
    ld hl, $2000
    ld bc, (smpTickOff)
    or a
    sbc hl, bc                  ; HL = part1
    ld b, h
    ld c, l
    push bc                     ; part1
    ld hl, (smpTickLen)
    or a
    sbc hl, bc                  ; HL = part2
    push hl                     ; part2
    ; copy part1 from (page, off) to dest
    ld a, (smpTickPage)
    nextreg $57, a
    ld hl, (smpTickOff)
    ld a, h
    add a, $E0
    ld h, a
    ld de, (smpTickDst)
    pop ix                      ; IX = part2 (parked)
    pop bc                      ; BC = part1
    ld a, b
    or c
    jr z, .p2
    ldir
.p2:
    ; copy part2 from (next table page, 0); DE already past part1.
    ; Reading one table entry ahead cannot walk off the payload: part2
    ; > 0 only when off+len > $2000, and len <= remain keeps off+len
    ; within the loaded payload, so smpTabIdx+1 is a live table entry.
    ld a, (smpTickPage2)
    nextreg $57, a
    ld hl, $E000
    push ix
    pop bc                      ; BC = part2 (non-zero: crossing case)
    ldir
    jr .program
.onepart:
    ld a, (smpTickPage)
    nextreg $57, a
    ld hl, (smpTickOff)
    ld a, h
    add a, $E0
    ld h, a
    ld de, (smpTickDst)
    ld bc, (smpTickLen)
    ld a, b
    or c
    jr z, .program              ; zero-length: nothing to copy
    ldir
.program:
    nextreg $57, AUD_PAGE_HI    ; state page back FIRST - every state
                                ; access below needs it
    ; (re)program the DMA: staging half -> DAC, burst, prescaler.
    ; Zero-length chunk (exact drain boundary): leave the DMA stopped;
    ; smpLast stays 0 and the next tick resolves end-or-loop.
    ld bc, (smpTickLen)
    ld a, b
    or c
    ret z
    ld hl, (smpTickDst)
    ld (audDmaProg.aaddr), hl
    ld (audDmaProg.alen), bc
    ld a, (smpPre)
    ld (audDmaProg.pre), a
    ld hl, audDmaProg
    ld b, audDmaProgLen
    ld c, DMA_PORT
    otir
    ld hl, (smpTickLen)
    ld (smpLast), hl            ; consumption baseline for next tick
    ; toggle the staging half for the next tick
    ld a, (smpHalf)
    xor 1
    ld (smpHalf), a
    ret

; IMPORTANT: smpTickLen/Off/Dst/Page/Page2 are written before the slot-7
; remap and only read while the source page is mapped (they live in
; page 48 CODE space at $C000-$CFFF, which stays mapped in slot 6
; throughout); smpLast and all smp* state live in the $FFE0 block and
; are only touched while slot 7 holds AUD_PAGE_HI. smpTickPage2 holds the
; NEXT source page (smpPageTab[smpTabIdx+1]) for the page-crossing copy -
; consecutive table entries are not consecutive pages (pool banks are
; non-contiguous), so the crossing branch reads it instead of page+1.
smpTickLen:   dw 0
smpTickOff:   dw 0
smpTickDst:   dw 0
smpTickPage:  db 0
smpTickPage2: db 0

; Sample stream page list + count, in page-48 CODE space (slot 6). The
; ISR reads them from slot 6, which stays mapped throughout aud_tick, so
; they are readable even while slot 7 windows a source page. aud_load_wav
; fills them (bank 24 page 48 mapped into slot 6) via aud_banks_claim;
; aud_boot_probe zeroes smpPageCnt on warm boot. smpPageCnt sits at
; smpPageTab+AUD_STRTAB_MAX - aud_banks_claim/release address it there.
smpPageTab:   ds AUD_STRTAB_MAX
smpPageCnt:   db 0

; zxnDMA program template (register encodings per zxndma.txt):
; disable, WR0 transfer A->B with A address + length, WR1 A memory
; incrementing cycle 2, WR2 B IO fixed cycle 2 + prescaler, WR4 BURST
; with B address (DAC), WR5 stop on end of block, load, enable.
audDmaProg:
    db $83
    db %01111101
.aaddr:
    dw 0
.alen:
    dw 0
    db %01010100
    db %00000010
    db %01101000
    db %00100010
.pre:
    db 0
    db $CD
    dw DAC_PORT
    db %10000010                ; WR5 $82: /ce only, stop on end of block
    db $CF
    db $87
audDmaProgLen equ $ - audDmaProg

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
audSilenceEnd:                      ; aud_tick's terminal watch treats
                                    ; [audSilenceSong, audSilenceEnd)
                                    ; as "the song is over"

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
smpFlags:      db 0                  ; bit 0 sample active, bit 1 looping
smpTabIdx:     db 0                  ; current index into smpPageTab (page 48)
smpOff:        dw 0                  ; read offset inside that page (0-$1FFF)
smpRemain:     dw 0                  ; payload bytes left this pass, low word
smpRemainHi:   db 0                  ; payload bytes left this pass, high byte
smpLen:        dw 0                  ; payload length (loop rewind), low word
smpLenHi:      db 0                  ; payload length (loop rewind), high byte
smpPre:        db 0                  ; DMA prescaler
smpChunk:      dw 0                  ; whole bytes per frame
smpFrac:       db 0                  ; rate mod 50
smpAcc:        db 0                  ; fractional accumulator (0-49)
smpHalf:       db 0                  ; staging half to fill next (0/1)
smpLast:       dw 0                  ; bytes programmed last tick (the
                                     ; consumption baseline; 0 = none
                                     ; in flight)
    ASSERT audFlags == AUD_STATE
    ASSERT $ <= $10000               ; bank ends inside the 64K map
