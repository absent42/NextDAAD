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
    ; SP10 audRequest2 (banked-stream mailbox) is consumed BEFORE the
    ; audRequest chain: streams are music, so bit 0 (stop stream) before
    ; bit 1 (start stream) mirrors the bit 3/4 music rule - a stale stop
    ; must never kill a same-frame start. Each res is one instruction,
    ; atomic against mainline (the ISR runs with interrupts off).
    ld hl, audRequest2
    bit 0, (hl)
    jr z, .no2stop
    res 0, (hl)
    call aud_ays_stop
    ld hl, audRequest2
.no2stop:
    bit 1, (hl)
    jr z, .no2start
    res 1, (hl)
    call aud_ays_start
.no2start:
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
    di                              ; player repoints SP - no CTC nest (see .gate)
    call PLY_AKY_INITSOUNDEFFECTS
    ei
    ld hl, audRequest
.no5:
    ; bit 3: stop music - BEFORE bit 4, see the header
    bit 3, (hl)
    jr z, .no3
    res 3, (hl)
    di                              ; aud_music_stop -> PLY_AKY_INIT repoints SP
    call aud_music_stop
    ei
    ld hl, audRequest
.no3:
    ; bit 4: start the song already loaded at AUD_SONG_ORG
    bit 4, (hl)
    jr z, .no4
    res 4, (hl)
    ld hl, AUD_SONG_ORG
    di                              ; player repoints SP - no CTC nest
    call PLY_AKY_INIT               ; also zeroes the effect channels
    ei
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
    di                              ; player repoints SP - bracket the triple stop once
    xor a
    call PLY_AKY_STOPSOUNDEFFECTFROMCHANNEL
    ld a, 1
    call PLY_AKY_STOPSOUNDEFFECTFROMCHANNEL
    ld a, 2
    call PLY_AKY_STOPSOUNDEFFECTFROMCHANNEL
    ei
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
    di                              ; ensure_player (INIT) + PLAYSOUNDEFFECT repoint SP
    call aud_ensure_player
    ld a, (audReqSfx)
    ld bc, $0000                    ; B = inverted volume (0 = max),
                                    ; C = channel 0
    call PLY_AKY_PLAYSOUNDEFFECT
    ei
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
    call aud_ays_tick           ; stream replay (self-gated on aysFlags);
                                ; runs regardless of audFlags, like the
                                ; sample refeed - the stream drives its
                                ; own PSGs independently of the AKY player
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
    ; PLY_AKY_PLAY repoints the real SP into the song linker/track pointers and
    ; the static RETTABLE for essentially its whole body (its documented contract:
    ; "call with interrupts disabled"). Under the frame ISR's early-EI a nested
    ; ctc_isr would push PC/AF/HL at the repointed SP and corrupt song data /
    ; RETTABLE -> ret-to-garbage crash. So mask CTC for the player's duration.
    ; This is the ONLY per-frame bracket (the others are one-shot request
    ; handlers); during sample+music COEXISTENCE it holds the DAC for an
    ; ESTIMATED ~5.5k T (~200us; ~1.0% duty at 50Hz / 28 MHz) once per frame -
    ; ~1.85k T of that is instruction-counted (the PSG register send), the
    ; rest is unpinned until a hardware/scope measurement - a documented v0.1.0
    ; compromise pending the owner's ear verdict. Sample-only and music-only are
    ; unaffected (this call only runs when audFlags has music or effect set).
    di
    call nz, PLY_AKY_PLAY           ; music + effects on PSG 3
    ei
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

; --- sampled sound engine (SP10 CTC per-sample DAC feed) -------------

; Start the sample staged in smpPageTab by aud_load_wav. Runs in ISR context.
; SP10 CTC pivot (supersedes the SP8/f-prime DMA ring - three DMA designs died
; on 50Hz block-quantisation gaps): a 1K power-of-two ring at $7C00 is played
; one byte per CTC interrupt by ctc_isr (raw out to $DF) and refilled from the
; banked page-table source by aud_smp_tick at 50Hz. No DMA, no byte-counter
; reads, no per-frame reprogram gap - the CTC self-paces the DAC. smpW is the
; producer offset (owned by the copy); smpPlayPtr/smpWritePtr (resident) are
; the ISR's absolute cursors. aud_smp_start seeds an empty ring, fills it once,
; publishes the write pointer, then programs and starts CTC channel 0.
aud_smp_start:
    xor a
    ld (smpTabIdx), a           ; source at the first page-table entry
    ld hl, 0
    ld (smpOff), hl
    ld (smpP), hl               ; ring empty: play offset == write offset == 0
    ld (smpW), hl
    ld hl, (audReqSmpLen)       ; 24-bit payload length (bytes not yet copied)
    ld (smpLen), hl
    ld (smpRemain), hl
    ld a, (audReqSmpLenHi)
    ld (smpLenHi), a
    ld (smpRemainHi), a
    ld a, (audReqSmpLoop)
    and 1
    add a, a                    ; -> bit 1 (loop)
    or 1                        ; bit 0 (active)
    ld (smpFlags), a            ; set BEFORE the copy (it reads the loop bit)
    ld hl, AUD_STAGE0           ; play starts at the ring base; the CTC is not
    ld (smpPlayPtr), hl         ; running yet, so this needs no DI bracket
    ; fill the ring from the source (backpressure caps the copy at ring-1)
    call aud_smp_copy           ; advances smpW
    ld hl, (smpW)
    ld de, AUD_STAGE0
    add hl, de
    ld (smpWritePtr), hl        ; write = ring base + bytes filled
    ld hl, (smpW)               ; nothing staged (zero-length sample): leave CTC off
    ld a, h
    or l
    ret z
    ; program CTC channel 0: unknown-state reset, control word, time constant.
    ; The channel int is gated open in NR C5 by im2_init; loading the TC starts
    ; the timer and ctc_isr begins feeding the DAC at the sample rate.
    ld bc, AUD_CTC_PORT
    ld a, AUD_CTC_RESET
    out (c), a
    out (c), a                  ; double soft-reset (unknown -> clean)
    ld a, (audReqSmpCtrl)
    out (c), a                  ; int en, timer, /16 or /256, TC follows
    ld a, (audReqSmpTc)
    out (c), a                  ; time constant -> timer starts, interrupts begin
    ret

; Stop: reset the CTC channel (timer + interrupt off), park the DAC at silence,
; clear the active flag. Idempotent. Runs in ISR context (also reached from
; aud_smp_tick's play-once drain end). DAC_SILENCE tracks the signedness switch
; ($80 unsigned default / $00 signed -DacCSpect) - see nextdaad.inc.
aud_smp_stop:
    xor a
    ld (smpFlags), a
    ld a, AUD_CTC_RESET         ; double soft-reset: timer stops, no more CTC ints
    ld bc, AUD_CTC_PORT
    out (c), a
    out (c), a
    ld a, DAC_SILENCE           ; park the DAC at silence (after the last feed)
    ld bc, DAC_PORT
    out (c), a
    ret

; Per-frame refill tick (50Hz, ISR context). The CTC self-paces the DAC, so the
; tick's only job is to keep the ring fed: snapshot the ISR's play cursor, copy
; as much source as the free space allows (backpressure lives in aud_smp_copy),
; publish the new write pointer, and on play-once drain stop once the ring has
; emptied. The 16-bit accesses to the shared cursors are DI-bracketed (~20T, far
; under one CTC period) so a nested ctc_isr never reads a torn value. No DMA, no
; counter reads, no DAC-hold window - the old f-prime exchange is gone.
aud_smp_tick:
    ld a, (smpFlags)
    rrca
    ret nc                      ; bit 0 clear: nothing active
    ; snapshot the ISR's play cursor -> smpP offset (atomic vs a CTC nest)
    di
    ld hl, (smpPlayPtr)
    ei
    ld de, AUD_STAGE0
    or a
    sbc hl, de                  ; HL = smpPlayPtr - base = play offset (0..ring-1)
    ld (smpP), hl
    call aud_smp_copy           ; fill [W, P) from source; advance smpW
    ; drain handling BEFORE publish: on play-once exhaustion pad a DAC_SILENCE
    ; guard at the write slot so a nested ctc_isr that catches write reads
    ; silence, never a stale ring byte.
    ld a, (smpFlags)
    bit 1, a
    jr nz, .publish             ; loop mode: the copy rewinds, never drains
    ld hl, (smpRemain)
    ld a, (smpRemainHi)
    or h
    or l
    jr nz, .publish             ; source not exhausted yet
    ld hl, (smpW)               ; drained: silence guard at the write slot
    ld de, AUD_STAGE0
    add hl, de
    ld (hl), DAC_SILENCE
    ld hl, (smpP)               ; has play (snapshot) caught write?
    ld de, (smpW)
    or a
    sbc hl, de
    jr nz, .publish             ; tail still draining: publish + wait a tick
    jp aud_smp_stop             ; drained + emptied: stop (CTC off, DAC parked)
.publish:
    ld hl, (smpW)
    ld de, AUD_STAGE0
    add hl, de
    di
    ld (smpWritePtr), hl
    ei
    ret

; HL = min(HL, DE); DE preserved; corrupts AF. Segment-cap helper for the copy
; loop - a plain unsigned 16-bit compare (sbc + CF), exact for every offset and
; length it is handed here. Lives in page-48 code, touches no state - safe to
; call while slot 7 windows a source page.
aud_min16:
    push hl
    or a
    sbc hl, de
    pop hl
    ret c                       ; HL < DE: keep HL
    ld h, d
    ld l, e                     ; HL >= DE: HL = DE
    ret

; aud_smp_copy: copy source bytes into the staging ring at smpW, advancing
; smpW/smpOff/smpTabIdx/smpRemain. toFill starts at the whole ring and is
; clamped to source remain (play-once, so it stops exactly at the payload end)
; and to ring free space MINUS 1 (backpressure - guarantees the copy can never
; reach smpP, so it can never overwrite an unplayed byte ctc_isr is about to
; read). The copy wraps at the physical ring end exactly as it splits at source-
; page boundaries. Loop mode rewinds the source (off/idx/remain) mid-copy and
; keeps going - the ring never notices the seam.
;
; DISJOINTNESS: ctc_isr reads at smpPlayPtr, whose offset the tick snapshots into
; smpP before this runs; this writes [W, W+toFill) at W. With occupied = (W-P)
; mod ring, free = ring-occupied, the backpressure clamp caps toFill at free-1,
; so W+toFill never reaches P - the play cursor only moves further away while
; this runs (single-producer/single-consumer), so the write region stays
; disjoint from the byte the ISR is reading.
;
; SLOT DISCIPLINE (identical to the SP8/ring machinery): phase A snapshots the
; source position + copy plan into slot-6 (page 48) scratch while state is
; readable (slot 7 = AUD_PAGE_HI); phase B windows source pages at $E000 via
; slot 7 and copies to the bank-5 ring ($7C00.., MMU3 always mapped) reading
; the plan from scratch; phase C restores slot 7 = AUD_PAGE_HI and writes the
; advanced position back to $FFE0. smpPageTab stays in slot 6 throughout.
; Corrupts everything.
aud_smp_copy:
    ; --- phase A: toFill = the whole ring; the play-once and backpressure clamps
    ; below cut it to min(source remain, free-1). The CTC self-paces the DAC, so
    ; there is no per-frame chunk/fractional sizing any more - the tick just
    ; fills all free ring space each frame (smpChunk/Frac/Acc retired with it).
    ld hl, AUD_STAGE_RING
    ld (smpCpTo), hl            ; toFill = ring (pre-clamp)
    ; play-once: clamp toFill to source remain (24-bit hi-byte shortcut). Loop
    ; skips this - the fill loop rewinds mid-copy instead of stopping at remain.
    ld a, (smpFlags)
    bit 1, a
    jr nz, .bp                  ; loop mode
    ld a, (smpRemainHi)
    or a
    jr nz, .bp                  ; remain > 64K: chunk (<= ring) always fits
    ld hl, (smpCpTo)
    ld de, (smpRemain)
    or a
    sbc hl, de
    jr c, .bp                   ; toFill < remain: keep toFill
    ld (smpCpTo), de            ; else toFill = remain
.bp:
    ; backpressure: toFill = min(toFill, free-1); free = ring - occupied,
    ; occupied = (smpW - smpP) mod ring.
    ld hl, (smpW)
    ld de, (smpP)
    or a
    sbc hl, de                  ; W - P
    jr nc, .occ
    ld de, AUD_STAGE_RING
    add hl, de                  ; wrapped: + ring
.occ:
    ex de, hl                   ; DE = occupied
    ld hl, AUD_STAGE_RING - 1
    or a
    sbc hl, de                  ; HL = free - 1 (>= 0; occupied <= ring-1)
    ld de, (smpCpTo)
    ex de, hl                   ; HL = toFill, DE = free-1
    or a
    sbc hl, de
    jr c, .snap                 ; toFill < free-1: keep (smpCpTo already set)
    ld (smpCpTo), de            ; toFill >= free-1: clamp to free-1
.snap:
    ld a, (smpTabIdx)
    ld (smpCpIdx), a
    ld hl, (smpOff)
    ld (smpCpOff), hl
    ld hl, (smpRemain)
    ld (smpCpRemLo), hl
    ld a, (smpRemainHi)
    ld (smpCpRemHi), a
    ld hl, (smpLen)
    ld (smpCpLen), hl
    ld a, (smpLenHi)
    ld (smpCpLenHi), a
    ld hl, (smpW)
    ld (smpCpDst), hl           ; working ring dest offset (0-AUD_STAGE_RING)
    ld a, (smpFlags)
    and %00000010               ; loop bit
    ld (smpCpLoop), a
    ; --- phase B: fill loop (copies run through slot 7 = source page) ---
.fill:
    ld hl, (smpCpTo)
    ld a, h
    or l
    jp z, .filldone             ; chunk copied
    ld hl, (smpCpRemLo)         ; source exhausted?
    ld a, (smpCpRemHi)
    or h
    or l
    jr nz, .seg                 ; source has bytes
    ld a, (smpCpLoop)
    or a
    jp z, .filldone             ; play-once drained: stop (toFill is already 0)
    xor a                       ; loop: rewind to the payload start (seamless)
    ld (smpCpIdx), a
    ld hl, 0
    ld (smpCpOff), hl
    ld hl, (smpCpLen)
    ld (smpCpRemLo), hl
    ld a, (smpCpLenHi)
    ld (smpCpRemHi), a
    jr .fill
.seg:
    ; seg = min(toFill, srcRoom, dstRoom, remain); srcRoom = $2000 - off,
    ; dstRoom = ring - dstOff (each cap keeps one copy inside one page/window).
    ld hl, $2000
    ld de, (smpCpOff)
    or a
    sbc hl, de                  ; HL = srcRoom (1..$2000)
    ld de, (smpCpTo)
    call aud_min16              ; seg = min(srcRoom, toFill)
    ld de, (smpCpDst)
    push hl
    ld hl, AUD_STAGE_RING
    or a
    sbc hl, de                  ; HL = dstRoom (1..ring)
    pop de                      ; DE = seg so far
    call aud_min16              ; seg = min(dstRoom, seg)
    ld a, (smpCpRemHi)          ; cap to remain only if it fits 16 bits
    or a
    jr nz, .segok
    ld de, (smpCpRemLo)
    call aud_min16              ; seg = min(remain, seg)
.segok:
    ld (smpCpSeg), hl           ; seg (>= 1)
    ld hl, AUD_STAGE0           ; dest abs = AUD_STAGE0 + dstOff -> DE
    ld de, (smpCpDst)
    add hl, de
    ex de, hl                   ; DE = dest abs
    ld a, (smpCpIdx)            ; slot 7 <- smpPageTab[idx] (page 48, slot 6)
    ld l, a
    ld h, 0
    ld bc, smpPageTab
    add hl, bc
    ld a, (hl)
    nextreg $57, a              ; window the source page at $E000
    ld hl, (smpCpOff)           ; source abs = $E000 + off -> HL
    ld a, h
    add a, $E0
    ld h, a
    ld bc, (smpCpSeg)
    ldir                        ; copy seg bytes (src slot 7 -> ring bank 5)
    ; advance off (page roll at $2000), dstOff (ring wrap), toFill, remain
    ld bc, (smpCpSeg)
    ld hl, (smpCpOff)
    add hl, bc
    ld (smpCpOff), hl           ; off += seg
    ld a, h
    cp $20
    jr c, .noroll               ; off < $2000: same source page
    sub $20                     ; rolled: off -= $2000, next table page
    ld h, a
    ld (smpCpOff), hl
    ld a, (smpCpIdx)
    inc a
    ld (smpCpIdx), a
.noroll:
    ld bc, (smpCpSeg)
    ld hl, (smpCpDst)
    add hl, bc                  ; dstOff += seg
    ld de, AUD_STAGE_RING
    or a
    sbc hl, de
    jr nc, .dstwrap             ; dstOff >= ring: wrapped to HL-ring
    add hl, de                  ; else restore (< ring)
.dstwrap:
    ld (smpCpDst), hl
    ld bc, (smpCpSeg)
    ld hl, (smpCpTo)
    or a
    sbc hl, bc
    ld (smpCpTo), hl            ; toFill -= seg
    ld hl, (smpCpRemLo)
    or a
    sbc hl, bc
    ld (smpCpRemLo), hl
    ld a, (smpCpRemHi)
    sbc a, 0
    ld (smpCpRemHi), a          ; remain -= seg (24-bit)
    jp .fill
.filldone:
    nextreg $57, AUD_PAGE_HI    ; slot 7 back to the state page BEFORE $FFE0
    ld a, (smpCpIdx)            ; write back the advanced source position + W
    ld (smpTabIdx), a
    ld hl, (smpCpOff)
    ld (smpOff), hl
    ld hl, (smpCpRemLo)
    ld (smpRemain), hl
    ld a, (smpCpRemHi)
    ld (smpRemainHi), a
    ld hl, (smpCpDst)
    ld (smpW), hl              ; W advanced by the bytes actually copied
    ret

; Copy scratch, in page-48 CODE space (slot 6, mapped throughout aud_tick).
; aud_smp_copy stages the source position + copy plan here BEFORE it windows a
; source page through slot 7, so the walk survives the remap; the $FFE0 smp*
; state is only touched with slot 7 = AUD_PAGE_HI (phases A and C). All bytes
; here are transient per-copy scratch.
smpCpTo:    dw 0    ; bytes still to copy this call (toFill)
smpCpOff:   dw 0    ; working offset inside the source page (0-$1FFF)
smpCpIdx:   db 0    ; working source page-table index
smpCpRemLo: dw 0    ; working source remain, low word
smpCpRemHi: db 0    ; working source remain, high byte
smpCpLen:   dw 0    ; payload length low (loop rewind mid-copy)
smpCpLenHi: db 0    ; payload length high
smpCpDst:   dw 0    ; working ring dest offset (0-AUD_STAGE_RING)
smpCpLoop:  db 0    ; loop-mode snapshot for this copy
smpCpSeg:   dw 0    ; this segment's byte count (saved across LDIR)

; Sample stream page list + count, in page-48 CODE space (slot 6). The
; ISR reads them from slot 6, which stays mapped throughout aud_tick, so
; they are readable even while slot 7 windows a source page. aud_load_wav
; fills them (bank 24 page 48 mapped into slot 6) via aud_banks_claim;
; aud_boot_probe zeroes smpPageCnt on warm boot. smpPageCnt sits at
; smpPageTab+AUD_STRTAB_MAX - aud_banks_claim/release address it there.
smpPageTab:   ds AUD_STRTAB_MAX
smpPageCnt:   db 0

; (SP10 CTC pivot: the zxnDMA sample-program template retired here - the CTC
; per-sample ISR replaces DMA burst playback entirely. The DMA is now free for
; future use, e.g. GFX blits; audio_init still issues a harmless disable.)

; --- banked-stream engine (SP10 client 2: AYS streamed song) ---------
;
; Per-tick AY-register-delta replay of a song streamed from SD into a
; claimed page list (aysPageTab). Second client of the same banked-stream
; walker as the sample engine (aud_smp_*); it clones the page-table /
; 24-bit-counter / floor-then-pool idioms but is a READER: each tick it
; walks one frame of the stream and writes the changed AY registers.
;
; AYS stream layout (authoritative spec: authoring-kit/lib/aysconv.ps1):
;   per frame, per PSG 0..aysPsgs-1:
;     dw mask   ; 14-bit register-change mask (bit r = register r written
;               ; this frame; bits 14-15 always 0)
;     db values[popcount(mask)]  ; changed register values, ascending r
;   frame boundary is implicit after aysPsgs PSG blocks (masks self-size).
;
; ALL ays state and both tables live in page-48 CODE space ($C000-$CFFF,
; MMU slot 6). That slot stays mapped for the whole of aud_tick, so this
; state is legal to touch at ANY point in the tick - including while slot
; 7 windows a stream source page. This is REQUIRED, not a convenience:
; the frame read advances the position (aysTabIdx/aysOff) MID-FRAME as it
; crosses an 8K page, which the $FFE0 state block (slot 7 = page 49 only)
; could not support. The one page-49 datum the walk needs, audFlags (for
; PSG-3 suppression), is snapshotted into aysSup BEFORE slot 7 is remapped
; off page 49. overlay1 reaches this same state through a page-48 window
; (aud_load_ays / aud_boot_probe), exactly as it does smpPageTab.

; aud_ays_start: begin the stream loaded into aysPageTab. Position = 0,
; remain = aysLen; audReq2Loop (resident) selects loop (bit 1) vs once.
; Both loaders enforce the stream/AKY mutual exclusion (a stream and an AKY
; song never coexist - documented invariant, asserted nowhere): the stream
; loader's stop-wait halts any AKY song before this start bit is filed, and
; aud_load_song (T3 F1 fix) stops a playing stream before loading an AKY song.
; Runs in ISR context. Corrupts AF, HL.
aud_ays_start:
    xor a
    ld (aysTabIdx), a
    ld hl, 0
    ld (aysOff), hl
    ld hl, (aysLen)             ; 24-bit stream length -> remain this pass
    ld (aysRemain), hl
    ld a, (aysLenHi)
    ld (aysRemainHi), a
    ld a, (audReq2Loop)
    and 1
    add a, a                    ; -> bit 1 (loop)
    or 1                        ; bit 0 (active)
    ld (aysFlags), a
    ret

; aud_ays_stop: stop the stream and silence the PSGs it drove, respecting
; PSG-3 ownership exactly as aud_music_stop does (an effect or beep owning
; PSG 3 keeps it). Clears aysFlags. Idempotent. Runs in ISR context.
; Corrupts AF, BC.
aud_ays_stop:
    xor a
    ld (aysFlags), a
    ld a, $FF                   ; PSG 1 and PSG 2 carry stream/music only:
    call aud_psg_silence        ; silence them now (nothing else refreshes
    ld a, $FE                   ; them once the stream is gone)
    call aud_psg_silence
    ld a, (audFlags)            ; PSG 3 may be owned by an effect (bit 2)
    and %00001100               ; or a beep (bit 3): leave it to them, else
    ret nz                      ; silence it (the same test aud_music_stop
    ld a, $FD                   ; uses to protect PSG 3)
    jp aud_psg_silence

; aud_ays_tick: replay one frame. Called from aud_tick every tick (self-
; gated on aysFlags bit 0), regardless of audFlags. Slot 7 = AUD_PAGE_HI
; on entry (aud_smp_tick restored it). Slot 6 stays on page 48 throughout.
;
; Slot-7 walk, instruction by instruction:
;   [slot7=page49] read aysFlags gate; snapshot audFlags bits 2/3 -> aysSup
;                  (audFlags is $FFE0 = page 49, readable only here);
;   nextreg $57 <- aysPageTab[aysTabIdx]  ; slot7 now = current source page
;   [slot7=source] read the whole frame via aud_ays_rdb (byte-wise, rolls
;                  aysTabIdx/aysOff and remaps slot 7 on each 8K crossing);
;                  AY writes go to I/O ports, not memory, so they are legal
;                  under any slot-7 mapping; all loop state is page-48/regs;
;   nextreg $57 <- AUD_PAGE_HI            ; slot7 back to page 49
;   [slot7=page49] remain -= consumed (24-bit); on 0: loop (reload the
;                  precomputed aysLoop* position/remain) or stop.
; Worst-case frame = 3*(2+14) = 48 bytes read + up to 42 register writes,
; well within the ISR budget (the AKY player writes similar volumes).
; Corrupts everything.
aud_ays_tick:
    ld a, (aysFlags)
    bit 0, a
    ret z                       ; no stream active
    ; snapshot PSG-3 suppression state while page 49 is still in slot 7
    ld a, (audFlags)
    and %00001100               ; effect (bit 2) or beep (bit 3) owns PSG 3
    ld (aysSup), a
    ; slot 7 -> the current source page
    ld a, (aysTabIdx)
    ld e, a
    ld d, 0
    ld hl, aysPageTab
    add hl, de
    ld a, (hl)
    nextreg $57, a
    ; frame read setup
    xor a
    ld (aysConsumed), a
    ld a, (aysPsgs)             ; 1..3 (validated at load; only used with a
    ld (aysPsgLeft), a          ; live stream, so never 0 here)
    ld a, $FF                   ; PSG 1 select ($FF), then $FE, then $FD
    ld (aysSel), a
.psg:
    ld a, (aysSel)
    call aud_psg3_select        ; select this PSG chip (I/O only)
    ; is this PSG's write suppressed? only PSG 3 ($FD) while effect/beep
    ; owns it - consume its bytes but skip the register writes.
    xor a
    ld (aysSkip), a
    ld a, (aysSel)
    cp $FD
    jr nz, .mask
    ld a, (aysSup)
    or a
    jr z, .mask
    ld a, 1
    ld (aysSkip), a
.mask:
    call aud_ays_rdb            ; mask low byte
    ld e, a
    call aud_ays_rdb            ; mask high byte (bits 8-13; 14-15 = 0)
    ld d, a                     ; DE = 14-bit change mask
    xor a
    ld (aysReg), a             ; register counter 0..13
.reg:
    srl d
    rr e                        ; CF = mask bit for the current register;
    jr nc, .regnext             ; DE >>= 1 (bit 0 = register 0 first)
    call aud_ays_rdb            ; read the value byte (consumed regardless)
    ld c, a                     ; C = value
    ld a, (aysSkip)
    or a
    jr nz, .regnext             ; suppressed: byte consumed, no write
    ld a, (aysReg)
    ld b, a                     ; B = register number
    call aud_psg3_write         ; out reg B = value C on the selected PSG
.regnext:
    ld hl, aysReg
    inc (hl)
    ld a, (hl)
    cp 14
    jr c, .reg
    ld a, (aysSel)
    dec a                       ; $FF -> $FE -> $FD for the next PSG
    ld (aysSel), a
    ld hl, aysPsgLeft
    dec (hl)
    jp nz, .psg
    ; frame read complete: slot 7 back to the state page BEFORE any $FFE0
    ; access (aud_ays_stop below reads audFlags there)
    nextreg $57, AUD_PAGE_HI
    ; remain -= consumed (24-bit). consumed == 2*aysPsgs + sum(popcounts),
    ; the exact byte count aud_ays_rdb advanced the position by, so remain
    ; and position stay in lock-step.
    ld a, (aysConsumed)
    ld e, a
    ld d, 0
    ld hl, (aysRemain)
    or a
    sbc hl, de
    ld (aysRemain), hl
    ld a, (aysRemainHi)
    sbc a, 0
    ld (aysRemainHi), a
    jr c, .endpass              ; underflow (malformed frame align): end pass
    or h
    or l
    ret nz                      ; bytes still remain this pass
.endpass:
    ld a, (aysFlags)
    bit 1, a
    jp z, aud_ays_stop          ; play-once: end in silence (out of jr range)
    ; loop: reload the precomputed loop position and remaining count
    ld a, (aysLoopIdx)
    ld (aysTabIdx), a
    ld hl, (aysLoopInPage)
    ld (aysOff), hl
    ld hl, (aysLoopRem)
    ld (aysRemain), hl
    ld a, (aysLoopRemHi)
    ld (aysRemainHi), a
    ret

; aud_ays_rdb: read one stream byte -> A, advancing the position
; (aysTabIdx/aysOff) and counting it in aysConsumed. On the 8K page
; boundary it steps aysTabIdx and remaps slot 7 to the next source page -
; UNLESS the new index has reached aysPageCnt, in which case the stream
; ended exactly on the boundary and no further byte is read this pass
; (remain hits 0 and aud_ays_tick's loop/stop runs before any read), so
; slot 7 is left on the final page and never dereferenced past the table.
; This is the proven no-read-past-the-table invariant - not a reliance on
; the aysPageCnt byte sitting adjacent to aysPageTab (it does, mirroring
; smpPageTab, but the guard here means that adjacency is never reached).
; Slot 7 holds the live source page on entry and exit. Corrupts AF, HL.
; Preserves BC, DE, IX, IY.
aud_ays_rdb:
    ld hl, aysConsumed
    inc (hl)                    ; count this byte (frame-scoped)
    ld hl, (aysOff)
    ld a, h
    add a, $E0                  ; source page windows at slot 7 = $E000
    ld h, a
    ld a, (hl)                  ; A = the stream byte
    ld (aysByte), a             ; stash across the page-cross bookkeeping
    ld hl, (aysOff)
    inc hl
    ld (aysOff), hl
    bit 5, h                    ; new offset high byte $20 = crossed $2000
    jr nz, .cross
    ret                         ; no cross: A still holds the byte
.cross:
    push de
    ld hl, 0
    ld (aysOff), hl             ; offset wraps to 0 in the next page
    ld hl, aysTabIdx
    inc (hl)
    ld a, (hl)                  ; new table index
    ld hl, aysPageCnt
    cp (hl)
    jr nc, .crosspop            ; index reached the count: stream end, no map
    ld e, a
    ld d, 0
    ld hl, aysPageTab
    add hl, de
    ld a, (hl)                  ; next source page
    nextreg $57, a
.crosspop:
    pop de
    ld a, (aysByte)             ; A = the stream byte read above
    ret

; AYS state + page table, all in page-48 CODE space (slot 6). Reset on
; (warm) boot by aud_boot_probe (aysFlags + aysPageCnt zeroed through a
; page-48 window); filled + committed by aud_load_ays. aysPageCnt sits at
; aysPageTab+AUD_STRTAB_MAX so aud_banks_claim/release address it there.
aysFlags:     db 0             ; bit 0 stream active, bit 1 looping
aysPsgs:      db 0             ; 1..3 PSGs in the stream (from the header)
aysTabIdx:    db 0             ; current index into aysPageTab
aysOff:       dw 0             ; read offset inside that page (0-$1FFF)
aysRemain:    dw 0             ; stream bytes left this pass, low word
aysRemainHi:  db 0             ; stream bytes left this pass, high byte
aysLen:       dw 0             ; total stream length (loop reload), low word
aysLenHi:     db 0             ; total stream length, high byte
aysLoopIdx:   db 0             ; precomputed loop position: page-table index
aysLoopInPage:dw 0             ; precomputed loop position: offset in page
aysLoopRem:   dw 0             ; precomputed aysLen-loopOffset, low word
aysLoopRemHi: db 0             ; precomputed aysLen-loopOffset, high byte
aysConsumed:  db 0             ; bytes read this frame (aud_ays_rdb counts)
aysPsgLeft:   db 0             ; PSGs still to read this frame
aysSel:       db 0             ; current PSG select value ($FF/$FE/$FD)
aysReg:       db 0             ; current register number 0..13
aysSkip:      db 0             ; nonzero: suppress this PSG's writes
aysSup:       db 0             ; audFlags bits 2/3 snapshot (PSG-3 owner)
aysByte:      db 0             ; aud_ays_rdb return-byte stash across a cross
aysPageTab:   ds AUD_STRTAB_MAX
aysPageCnt:   db 0

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
smpTabIdx:     db 0                  ; current source index into smpPageTab (page 48)
smpOff:        dw 0                  ; source read offset inside that page (0-$1FFF)
smpRemain:     dw 0                  ; source bytes not yet copied, low word
smpRemainHi:   db 0                  ; source bytes not yet copied, high byte
smpLen:        dw 0                  ; payload length (loop rewind), low word
smpLenHi:      db 0                  ; payload length (loop rewind), high byte
smpP:          dw 0                  ; ring PLAY offset - per-tick snapshot of
                                     ; smpPlayPtr (0..AUD_STAGE_RING-1), read by
                                     ; the copy's backpressure and the drain check
smpW:          dw 0                  ; ring WRITE offset - next copy lands here
    ASSERT audFlags == AUD_STATE
    ASSERT $ <= $10000               ; bank ends inside the 64K map
