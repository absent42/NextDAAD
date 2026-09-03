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
; with interrupts off. Consumption order across BOTH mailbox bytes is
; audRequest2 0 (stop stream), 1 (start stream), 2 (stop sample ch2),
; 3 (start sample ch2), then audRequest 7 (stop sample ch1), 6 (start
; sample ch1), 5 (init effects), 3 (stop music), 4 (start music), 2
; (stop effect), 1 (play effect), 0 (beep) so that a stale stop filed
; while audio was off can never kill a same-frame start - the rule is
; per channel and per client, and both sample channels obey it.
; The sample refeed (aud_smp_tick, once per channel) runs every tick
; regardless of audFlags.
;
; SHARED START PARAMETERS - A STATED LIMITATION (SP18 item 7 Task 11).
; The start bits are per channel but the parameter cells they read are
; NOT: audReqSmpCtrl/Tc/Len/LenHi/Loop are single copies. Both start
; bits are consumed in ONE pass through this chain, reading the same
; cells, so two starts filed in the same frame would take the same
; rate, length and loop mode. Nothing does that today (mainline files
; one start per condact execution) and the allocator that picks a
; channel files one start at a time, so the ordering that matters -
; stop before start, per channel - holds regardless. Filing two starts
; in one frame would need a second parameter set first.
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
    ld hl, audRequest2
.no2start:
    ; bits 2/3: SAMPLE CHANNEL 2 stop/start (SP18 item 7 Task 11), the
    ; exact mirror of audRequest bits 7/6 for channel 1 below - same
    ; stop-before-start rule, same single-res consumption, same
    ; halt-wait compatibility for a mainline filer that waits for its
    ; bit to clear (video.asm's entry abort files bits from BOTH bytes
    ; and waits on both). IX is seeded once for the pair: aud_smp_stop
    ; and aud_smp_start both preserve it, and nothing between them
    ; touches it.
    ld ix, sfxChan1
    bit 2, (hl)
    jr z, .no2s2
    res 2, (hl)
    call aud_smp_stop
    ld hl, audRequest2
.no2s2:
    bit 3, (hl)
    jr z, .no2s3
    res 3, (hl)
    call aud_smp_start
.no2s3:
    ld hl, audRequest
    ld a, (hl)
    or a
    jp z, .noreq
    ; bit 7: stop sample (before bit 6: a stale stop must not kill a
    ; same-frame start - mirrors the bit 3/4 music rule). IX is seeded
    ; once for the pair, as for channel 2 above.
    ld ix, sfxChan0
    bit 7, (hl)
    jr z, .no7
    res 7, (hl)
    call aud_smp_stop
    ld hl, audRequest
.no7:
    ; bit 6: start the sample staged in the channel's page window
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
    call aud_env_arm                ; and force the first envelope
    ei                              ; retrigger (see aud_env_arm)
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
    ld ix, sfxChan0             ; both sampled-effect channels are pumped
    call aud_smp_tick           ; every tick, each self-gated on its own
    ld ix, sfxChan1             ; SMPB_FLAGS bit 0. IX must be reseeded:
    call aud_smp_tick           ; aud_smp_tick preserves it, but the AKY
                                ; player calls above do not, so neither
                                ; seed can be hoisted out of this chain.
                                ; (the SFX stream refiller runs after this
                                ; tick returns - the dispatch is sited in
                                ; im2_isr, see its comment there)
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
    ; No DI bracket: the player is nest-safe (player_aky.asm header). Its
    ; only DI is the linker read, ~350 T once per pattern, under one CTC
    ; period, so the sample feed is delayed there, never dropped. The old
    ; whole-call bracket masked the CTC for the player's 5.5k-15k T every
    ; frame; hw IM2 keeps ONE pending request per source (im2_peripheral
    ; im2_int_req), so every further edge in that window was lost - the
    ; 50 Hz notch heard on the 880 Hz sine under a three-PSG tune.
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
    call aud_env_arm
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
    call aud_env_arm
    ld a, 1
    ld (audPlayerUp), a
    ret

; --- envelope retrigger arm (SP16 Task 7 follow-up) ------------------

; Poison the AKY player's four R13 (envelope shape) shadow cells with
; $FF so the first hardware-envelope note of a newly started song is
; guaranteed to WRITE R13 and therefore RETRIGGER the envelope
; generator. Called after every PLY_AKY_INIT - all three sites, which
; are the only ones in the tree (aud_tick's start-music, aud_music_stop
; and aud_ensure_player above).
;
; THE DEFECT. PLY_AKY_SENDPSGREGISTERS_SPECTRUMRELATED pushes R0-R12
; out unconditionally through an outi chain, but writes R13 only when
; the value CHANGES (player_aky.asm:740 "ld a,(hl) / inc hl / cp (hl) /
; jr z,...REGISTER13_END"), because a write to R13 restarts the
; envelope generator on AY silicon and a per-frame rewrite would
; retrigger every envelope fifty times a second. The byte it compares
; against is the shadow cell immediately after R13 in each hardware
; register array. PLY_AKY_INIT does not clear those cells - its whole
; reset set is the linker position, the nine REGISTERBLOCKLINESTATE
; opcodes, the pattern frame counter and the three SOUNDEFFECTDATA
; words - and aud_psg_silence writes only R7/R8/R9/R10. So a restarted
; song whose first envelope note asks for the shape already sitting in
; the shadow never retriggers: a hold-type shape stays parked at its
; terminal level, the buzzer's content is gone and only the tone
; generator's fundamental remains, which is what "the tune came back at
; a lower tone" describes. Shape $0A is also a triangle one octave
; below $08 at the same envelope period.
;
; WHY A REGISTER DUMP CANNOT SEE IT. The discriminator is the WRITE
; EVENT, not a value: control (shadow differed, R13 written, envelope
; retriggered, shadow updated) and repro (shadow already matched, write
; skipped, envelope not retriggered) end the frame byte-identical, and
; the envelope generator's phase, direction and step counter are not
; registers on any AY. The SP16 T7 three-point dump returned 654 of 654
; byte-identical for exactly this reason; its dismissal of the R13
; residue rested on "the next PLY_AKY_PLAY rewrites R0-R13
; unconditionally" - true of R0-R12, false for R13.
;
; WHY $FF. R13 is a 4-bit register and the player masks every shape it
; stores ("and $f" on the hardware path, "and $7 / add a,$8" on the
; effects path), so a shadow of $FF can never equal a real shape and
; the cp always mismatches. This is not an invention: $FF is the
; player's OWN retrig idiom - a register block flagged retrig does
; "ld (iy+3),$ff" (player_aky.asm:495) and the effects stream does the
; same to PLY_AKY_SFXRETRIG (:134). This routine files exactly the
; event the song data files for a retrig-flagged note.
;
; CORRECT BY CONSTRUCTION, two ways.
; 1. It cannot cause an unwanted retrigger in normal play. The poison
;    is consumed by the first R13 write after it, which stores the real
;    shape into the shadow (player_aky.asm:744 "ld (hl),a"); from the
;    next frame on, the comparison is against a genuine value again and
;    the per-frame suppression works exactly as before. One forced
;    write per song start, zero per-frame cost, cold paths only.
; 2. It cannot mis-set an envelope. The VALUE written to R13 still
;    comes from the song data via the register array - only the "skip
;    the write" optimisation is defeated, and only for one note. The
;    poison byte is never sent to the chip: the shadow is compared and
;    overwritten, never output.
; The two silence-song sites force that one write on channels the
; silence song holds at volume 0, so nothing is audible. An effect live
; on PSG 3 across a STOPM gets one extra envelope restart on its next
; frame - the same event its own data files on any retrig-flagged note.
;
; THE FOUR CELLS. PSG 1's is named; PSG 2's and PSG 3's are the unnamed
; +3 offsets of their hardware register arrays (the Disark conversion
; named only PSG 1's); the fourth is PLY_AKY_SFXRETRIG. PSG 3's is the
; persistent one - each frame the player LDIRs PSG 3's software +
; hardware arrays into the SFX array (player_aky.asm:461) and copies
; the shadow back afterwards (:473), so PLY_AKY_SFXRETRIG is a
; per-frame working copy. Poisoning it too is belt-and-braces, 3 bytes.
;
; NOTHING ELSE LEAVES A STALE SHADOW that this misses. No other code in
; the tree writes R13 through the shadow: aud_psg_silence,
; aud_beep_start / aud_beep_silence and video.asm's video-entry
; .psgpark touch only R0/R1/R7/R8/R9/R10. The AYS stream engine
; (aud_ays_tick) writes whatever registers its frame mask selects
; straight to the chip with no shadow at all, so it CAN desynchronise
; chip from shadow - covered here, because a stream and an AKY song are
; mutually exclusive and the next song start comes through
; PLY_AKY_INIT.
;
; Corrupts AF. Preserves BC, DE, HL, IX, IY.
aud_env_arm:
    ld a, $FF
    ld (PLY_AKY_PSG1RETRIG), a                  ; PSG 1 (named cell)
    ld (PLY_AKY_PSG2HARDWAREREGISTERARRAY+3), a ; PSG 2
    ld (PLY_AKY_PSG3HARDWAREREGISTERARRAY+3), a ; PSG 3 (persistent)
    ld (PLY_AKY_SFXRETRIG), a                   ; PSG 3's frame copy
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

; Start the sample staged in the channel's page window by aud_load_wav /
; sfx_stream_open. Runs in ISR context.
; SP10 CTC pivot (supersedes the SP8/f-prime DMA ring - three DMA designs died
; on 50Hz block-quantisation gaps): a 1K power-of-two ring at $7C00 is played
; one byte per CTC interrupt by ctc_isr (raw out to $DF) and refilled from the
; banked page-table source by aud_smp_tick at 50Hz. No DMA, no byte-counter
; reads, no per-frame reprogram gap - the CTC self-paces the DAC. SMPB_W is
; the producer offset (owned by the copy); smpPlayPtr/smpWritePtr (resident)
; are the ISR's absolute cursors. aud_smp_start seeds an empty ring, fills it
; once, publishes the write pointer, then programs and starts CTC channel 0.
; Precondition: IX = channel block (sfxChan0 or sfxChan1).
aud_smp_start:
    xor a
    ld (ix+SMPB_P), a           ; ring empty: play offset == write offset == 0
    ld (ix+SMPB_P+1), a
    ld (ix+SMPB_W), a
    ld (ix+SMPB_W+1), a
    ; The consumer starts at the PAYLOAD, not at window byte 0: blocks
    ; stage verbatim from file offset 0, so the WAV header sits in front
    ; of it. sfx_stream_open wrote that anchor into the channel's window
    ; descriptor; loop rewind (aud_smp_copy) returns to the same place.
    call aud_smp_anchor
    ld (ix+SMPB_TABIDX), a
    ld (ix+SMPB_OFF), l
    ld (ix+SMPB_OFF+1), h
    ld hl, (audReqSmpLen)       ; 24-bit payload length (bytes not yet copied)
    ld (ix+SMPB_LEN), l
    ld (ix+SMPB_LEN+1), h
    ld (ix+SMPB_REMAIN), l
    ld (ix+SMPB_REMAIN+1), h
    ld a, (audReqSmpLenHi)
    ld (ix+SMPB_LEN+2), a
    ld (ix+SMPB_REMAIN+2), a
    ld a, (audReqSmpLoop)
    and 1
    add a, a                    ; -> bit 1 (loop)
    or 1                        ; bit 0 (active)
    ld c, a
    ld a, (ix+SMPB_FLAGS)
    and %00111100               ; bits 2-4 (STREAMING/COMPLETE/REWIND)
    or c                        ; belong to the loader and the refiller
                                ; and bit 5 (PINNED) to the allocator -
                                ; only bits 0/1 are the pump's
    ld (ix+SMPB_FLAGS), a       ; set BEFORE the copy (it reads the loop bit)
    ld hl, (frameCounter)       ; stamp the start: the allocator steals the
    ld (ix+SMPB_STAMP), l       ; OLDEST of two equally stealable channels,
    ld (ix+SMPB_STAMP+1), h     ; and this is what "oldest" is measured from
    ; play starts at the ring base; the CTC is not running yet on a cold
    ; start, OR mid-restart (a same-tick COMPLETE re-trigger files a start
    ; with no stop, so this can also run against a live CTC) where a torn
    ; cursor write stays inside the ring for both ring bases (high byte
    ; $7C-$7F / $44-$47, low 00) - at most a one-byte skip / one-tick-
    ; early audio, bounded - so the resident cursor write below needs no
    ; DI bracket either way. Ring base and the cursor address are both
    ; channel-block members (SMPB_RINGH/PLAYPTR).
    ld h, (ix+SMPB_RINGH)
    ld l, 0                     ; HL = ring base
    ld e, (ix+SMPB_PLAYPTR)
    ld d, (ix+SMPB_PLAYPTR+1)   ; DE = &smpPlayPtr (this channel's resident cursor)
    ld a, l
    ld (de), a
    inc de
    ld a, h
    ld (de), a
    ; fill the ring from the source (backpressure caps the copy at ring-1)
    call aud_smp_copy           ; advances SMPB_W
    ld l, (ix+SMPB_W)
    ld h, (ix+SMPB_W+1)
    ld d, (ix+SMPB_RINGH)
    ld e, 0                     ; DE = ring base
    add hl, de                  ; HL = ring base + bytes filled
    ld e, (ix+SMPB_WRITEPTR)
    ld d, (ix+SMPB_WRITEPTR+1)  ; DE = &smpWritePtr (this channel's resident cursor)
    ld a, l
    ld (de), a
    inc de
    ld a, h
    ld (de), a                  ; write = ring base + bytes filled
    ld l, (ix+SMPB_W)           ; nothing staged (zero-length sample): leave CTC off
    ld h, (ix+SMPB_W+1)
    ld a, h
    or l
    ret z
    ; program CTC channel 0: unknown-state reset, control word, time constant.
    ; The channel int is gated open in NR C5 by im2_init; loading the TC starts
    ; the timer and ctc_isr begins feeding the DAC at the sample rate. Port
    ; and latched control/TC are all channel-block members now; the mailbox
    ; cells (audReqSmpCtrl/Tc) are written by aud_ctc_params - from the WAV
    ; loader on a fresh open, or from sfx_alloc's rewind re-commit against
    ; this channel's own stored rate (SMPB_RATE, latched below) - and only
    ; copied into the block here.
    ld c, (ix+SMPB_CTCPORT)
    ld b, (ix+SMPB_CTCPORT+1)
    ld a, AUD_CTC_RESET
    out (c), a
    out (c), a                  ; double soft-reset (unknown -> clean)
    ld a, (audReqSmpCtrl)
    ld (ix+SMPB_CTCCTRL), a     ; latch this effect's control word in the block
    out (c), a                  ; int en, timer, /16 or /256, TC follows
    ld a, (audReqSmpTc)
    ld (ix+SMPB_CTCTC), a       ; latch this effect's time constant in the block
    out (c), a                  ; time constant -> timer starts, interrupts begin
    ld hl, (audReqSmpRate)
    ld (ix+SMPB_RATE), l        ; latch the rate too (owner ruling 2026-08-10):
    ld (ix+SMPB_RATE+1), h      ; a later rewind re-commit re-derives Ctrl/Tc
                                 ; fresh from this against the live video mode
                                 ; instead of replaying Ctrl/Tc as latched here
    ret

; Stop: reset the CTC channel (timer + interrupt off), park the DAC at silence,
; clear the active flag. Idempotent. Runs in ISR context (also reached from
; aud_smp_tick's play-once drain end). DAC_SILENCE is the unsigned midpoint $80
; (unsigned everywhere on the OUT path) - see nextdaad.inc.
; Precondition: IX = channel block (sfxChan0 or sfxChan1).
;
; FLAGS on a stop (SP18 item 7 Task 5 review ruling; full bit semantics
; at nextdaad.inc's SMPB_FLAGS block): bits 0/1 are playback and go;
; bit 2 STREAMING is the refiller's gate and must go too, or a stopped
; channel would keep being refilled; bit 4 REWIND is meaningless without
; bit 2. Bit 3 COMPLETE SURVIVES: the window still holds every byte of
; the file, so the re-trigger rewind is still free and the pump's own
; loop-rewind branch still needs to know its window is permanent after a
; stop/restart cycle. The cached STREAM (handle, hot filemap, keep-last
; number) survives in the stream cells, not in a flag - only the refusal
; funnel and an eviction by a different effect number invalidate it.
; Bit 5 PINNED survives too: a stop is not a release. Only SFX subs 15/16
; and sub 5 clear a pin, so the video abort and the refiller's error
; eviction (both of which come through here) leave the author's channel
; reservation standing.
aud_smp_stop:
    ld a, (ix+SMPB_FLAGS)
    and %00101000               ; keep COMPLETE and PINNED, drop active/
    ld (ix+SMPB_FLAGS), a       ; loop/STREAMING/REWIND
    ld a, AUD_CTC_RESET         ; double soft-reset: timer stops, no more CTC ints
    ld c, (ix+SMPB_CTCPORT)
    ld b, (ix+SMPB_CTCPORT+1)
    out (c), a
    out (c), a
    ld a, DAC_SILENCE           ; park the DAC at silence (after the last feed)
    ld c, (ix+SMPB_DACPORT)
    ld b, 0                     ; DAC ports decode on the low byte only, so the
                                 ; high byte is don't-care on real hardware, but
                                 ; B=0 matches the project's own out(c) idiom for
                                 ; this exact port (hardware.asm audio_init:
                                 ; "ld bc, DAC_PORT" zero-extends the 8-bit equ)
    out (c), a
    ret

; Per-frame refill tick (50Hz, ISR context). The CTC self-paces the DAC, so the
; tick's only job is to keep the ring fed: snapshot the ISR's play cursor, copy
; as much source as the free space allows (backpressure lives in aud_smp_copy),
; publish the new write pointer, and on play-once drain stop once the ring has
; emptied. The 16-bit accesses to the shared cursors are DI-bracketed (~20T, far
; under one CTC period) so a nested ctc_isr never reads a torn value. No DMA, no
; counter reads, no DAC-hold window - the old f-prime exchange is gone.
; Precondition: IX = channel block (sfxChan0 or sfxChan1).
aud_smp_tick:
    ld a, (ix+SMPB_FLAGS)
    rrca
    ret nc                      ; bit 0 clear: nothing active
    ; snapshot the ISR's play cursor -> SMPB_P offset (atomic vs a CTC nest).
    ; The resident cursor's address is a channel-block member (SMPB_PLAYPTR);
    ; loading it is ordinary IX-relative access to page-48 data and needs no
    ; DI - only the shared resident word it points at does.
    ld c, (ix+SMPB_PLAYPTR)
    ld b, (ix+SMPB_PLAYPTR+1)   ; BC = &smpPlayPtr (this channel's resident cursor)
    di
    ld a, (bc)
    ld l, a
    inc bc
    ld a, (bc)
    ld h, a                     ; HL = smpPlayPtr value
    ei
    ld d, (ix+SMPB_RINGH)
    ld e, 0                     ; DE = ring base
    or a
    sbc hl, de                  ; HL = smpPlayPtr - base = play offset (0..ring-1)
    ld (ix+SMPB_P), l
    ld (ix+SMPB_P+1), h
    call aud_smp_copy           ; fill [W, P) from source; advance SMPB_W
    ; drain handling BEFORE publish: on play-once exhaustion pad a DAC_SILENCE
    ; guard at the write slot so a nested ctc_isr that catches write reads
    ; silence, never a stale ring byte.
    ld a, (ix+SMPB_FLAGS)
    bit 1, a
    jr nz, .publish             ; loop mode: the copy rewinds, never drains
    ld l, (ix+SMPB_REMAIN)
    ld h, (ix+SMPB_REMAIN+1)
    ld a, (ix+SMPB_REMAIN+2)
    or h
    or l
    jr nz, .publish             ; source not exhausted yet
    ld l, (ix+SMPB_W)           ; drained: silence guard at the write slot
    ld h, (ix+SMPB_W+1)
    ld d, (ix+SMPB_RINGH)
    ld e, 0                     ; DE = ring base
    add hl, de
    ld (hl), DAC_SILENCE
    ld l, (ix+SMPB_P)           ; has play (snapshot) caught write?
    ld h, (ix+SMPB_P+1)
    ld e, (ix+SMPB_W)
    ld d, (ix+SMPB_W+1)
    or a
    sbc hl, de
    jr nz, .publish             ; tail still draining: publish + wait a tick
    jp aud_smp_stop             ; drained + emptied: stop (CTC off, DAC parked)
.publish:
    ld l, (ix+SMPB_W)
    ld h, (ix+SMPB_W+1)
    ld d, (ix+SMPB_RINGH)
    ld e, 0                     ; DE = ring base
    add hl, de                  ; HL = ring base + bytes filled (write pointer)
    ld c, (ix+SMPB_WRITEPTR)
    ld b, (ix+SMPB_WRITEPTR+1)  ; BC = &smpWritePtr (this channel's resident cursor)
    di
    ld a, l
    ld (bc), a
    inc bc
    ld a, h
    ld (bc), a
    ei
    ret

; Load this channel's payload-start anchor out of its window descriptor:
; A = window page index, HL = byte offset inside that page. Two callers
; (aud_smp_start's initial cursor, aud_smp_copy's loop rewind) is why
; this is a routine rather than the same six loads twice. Reads page-48
; data only, so it is legal at any point in the tick, including while
; slot 7 windows a source page. Corrupts AF, DE, HL; preserves BC, IX.
aud_smp_anchor:
    ld l, (ix+SMPB_WINTAB)
    ld h, (ix+SMPB_WINTAB+1)
    ld de, SFXW_STIDX
    add hl, de
    ld a, (hl)
    inc hl
    ld e, (hl)
    inc hl
    ld d, (hl)
    ex de, hl                    ; HL = start offset, A = start page idx
    ret

; Re-credit SMPB_DEPTH for a loop rewind (SP18 item 7 Task 5 review C1).
; The rewind un-consumes the whole payload, so leaving DEPTH where the
; forward pass drove it (0, for anything that reached its end) would
; break the accounting identity stated at the debit site: the consumer
; would read "nothing available" with a full window in front of it.
;
; COMPLETE channel: the window holds every byte of the file permanently
; and blocks are never re-staged, so the rewound position implies exactly
; the DEPTH the open computed for the anchor. sfx_stream_open banked that
; figure in the descriptor (SFXW_DEPTH0) precisely so this can restore it
; verbatim, with no arithmetic and no dependence on what the forward pass
; did.
;
; STREAMING channel: NOT serviceable from RAM. The producer has been
; overwriting the window all the way round while the consumer walked, so
; by definition the payload start is long gone. The honest answer is to
; declare the window empty (DEPTH = 0) and raise SMPB_FLAGS bit 4 REWIND.
; HANDOFF TO TASK 6: its refiller must treat bit 4 as "re-seek the run
; list to the block holding the anchor (window offset TABIDX*$2000+OFF,
; file block (TABIDX*$2000+OFF)/512), re-stage from there, then clear
; bit 4 and credit DEPTH as usual"; until it does, DEPTH stays 0 and the
; consumer clamp Task 6 adds will starve the channel rather than replay
; stale window bytes. Nothing else in Task 5 reads bit 4.
; Corrupts AF, DE, HL; preserves BC, IX.
aud_smp_rewind_depth:
    bit 3, (ix+SMPB_FLAGS)       ; COMPLETE?
    jr z, .streaming
    ld l, (ix+SMPB_WINTAB)
    ld h, (ix+SMPB_WINTAB+1)
    ld de, SFXW_DEPTH0
    add hl, de
    ld a, (hl)
    ld (ix+SMPB_DEPTH), a
    inc hl
    ld a, (hl)
    ld (ix+SMPB_DEPTH+1), a
    ret
.streaming:
    ld hl, 0
    ld (ix+SMPB_DEPTH), l
    ld (ix+SMPB_DEPTH+1), h
    ; AND END THIS COPY AT THE SEAM (SP18 item 7 Task 6). The caller is
    ; mid-fill: it rewound the cursor and is about to reload remain from
    ; LEN and keep copying. Every byte it would copy now comes from a
    ; window position the producer overwrote passes ago, and the frontier
    ; clamp cannot stop it - that clamp is computed once, before the
    ; copy, from the PRE-rewind DEPTH. Zeroing toFill drops the caller
    ; straight through its own top-of-loop test into .filldone, which
    ; commits the rewound position normally; the refiller re-stages from
    ; the anchor on the next tick and the clamp takes over from there.
    ; Without this the loop seam of a > 24K effect plays up to a ring's
    ; worth of stale window bytes.
    ;
    ; WHAT THE SEAM SOUNDS LIKE - NOT A SILENT GAP. The ring gets a
    ; shorter fill this frame, so play catches write and ctc_isr's
    ; natural hold-last takes over: it keeps re-outputting the LAST REAL
    ; SAMPLE, a DC level, until the refiller has staged enough for the
    ; clamp to release bytes again. The DAC_SILENCE guard pad is NOT
    ; involved - aud_smp_tick writes that pad only on the play-once
    ; drain path, and its loop-mode test returns before reaching it (see
    ; the bit-1 branch there). So a > 24K looping effect holds a brief
    ; DC level across the loop seam rather than falling silent. That is
    ; the established engine discipline (hold-last, not silence, for
    ; every mid-playback shortfall) and is deliberately unchanged here;
    ; what this fix buys is a DC hold instead of stale window content.
    ld (smpCpTo), hl
    set 4, (ix+SMPB_FLAGS)       ; the refiller owes a re-stage
    ret

; SMPB_DEPTH -= A (512-byte blocks the consumer has just finished with),
; floored at 0 - the video streaming discipline: each side owns its own
; cursor and the shared counter clamps rather than underflows.
; Corrupts AF, DE, HL; preserves BC, IX.
aud_smp_debit:
    ld e, a
    ld d, 0
    ld l, (ix+SMPB_DEPTH)
    ld h, (ix+SMPB_DEPTH+1)
    or a
    sbc hl, de
    jr nc, .store
    ld hl, 0
.store:
    ld (ix+SMPB_DEPTH), l
    ld (ix+SMPB_DEPTH+1), h
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

; aud_smp_copy: copy source bytes into the staging ring at SMPB_W, advancing
; SMPB_W/OFF/TABIDX/REMAIN. toFill starts at the whole ring and is clamped to
; source remain (play-once, so it stops exactly at the payload end) and to
; ring free space MINUS 1 (backpressure - guarantees the copy can never reach
; SMPB_P, so it can never overwrite an unplayed byte ctc_isr is about to
; read). The copy wraps at the physical ring end exactly as it splits at source-
; page boundaries. Loop mode rewinds the source (off/idx/remain) mid-copy and
; keeps going - the ring never notices the seam.
;
; DISJOINTNESS: ctc_isr reads at smpPlayPtr, whose offset the tick snapshots
; into SMPB_P before this runs; this writes [W, W+toFill) at W. With occupied
; = (W-P) mod ring, free = ring-occupied, the backpressure clamp caps toFill
; at free-1, so W+toFill never reaches P - the play cursor only moves further
; away while this runs (single-producer/single-consumer), so the write region
; stays disjoint from the byte the ISR is reading.
;
; SLOT DISCIPLINE: phase A snapshots the source position + copy plan into
; slot-6 (page 48) scratch, reading the channel block (also page 48, slot 6 -
; IX-relative, no slot dependency); phase B windows source pages at $E000 via
; slot 7 and copies to the bank-5 ring ($7C00.., MMU3 always mapped) reading
; the plan from scratch; phase C restores slot 7 = AUD_PAGE_HI (required by
; the rest of aud_tick, which reads audFlags/audBeep*/audSongNum/audPlayerUp
; at $FFE0 - not by this routine's own state any more) and writes the
; advanced position back to the channel block. Page 48 (the window page
; list, the channel block and this scratch) stays in slot 6 throughout.
; Precondition: IX = channel block (sfxChan0 or sfxChan1). Corrupts everything
; except IX.
aud_smp_copy:
    ; --- phase A: toFill = the whole ring; the play-once and backpressure clamps
    ; below cut it to min(source remain, free-1). The CTC self-paces the DAC, so
    ; there is no per-frame chunk/fractional sizing any more - the tick just
    ; fills all free ring space each frame (smpChunk/Frac/Acc retired with it).
    ld a, (ix+SMPB_RINGM)
    inc a
    ld h, a
    ld l, 0                      ; HL = ring size (RINGM+1):00 - ring is
                                 ; always a 256-aligned power of two)
    ld (smpCpTo), hl            ; toFill = ring (pre-clamp)
    ; play-once: clamp toFill to source remain (24-bit hi-byte shortcut). Loop
    ; skips this - the fill loop rewinds mid-copy instead of stopping at remain.
    ld a, (ix+SMPB_FLAGS)
    bit 1, a
    jr nz, .bp                  ; loop mode
    ld a, (ix+SMPB_REMAIN+2)
    or a
    jr nz, .bp                  ; remain > 64K: chunk (<= ring) always fits
    ld hl, (smpCpTo)
    ld e, (ix+SMPB_REMAIN)
    ld d, (ix+SMPB_REMAIN+1)
    or a
    sbc hl, de
    jr c, .bp                   ; toFill < remain: keep toFill
    ld (smpCpTo), de            ; else toFill = remain
.bp:
    ; backpressure: toFill = min(toFill, free-1); free = ring - occupied,
    ; occupied = (SMPB_W - SMPB_P) mod ring.
    ld l, (ix+SMPB_W)
    ld h, (ix+SMPB_W+1)
    ld e, (ix+SMPB_P)
    ld d, (ix+SMPB_P+1)
    or a
    sbc hl, de                  ; W - P
    jr nc, .occ
    ld a, (ix+SMPB_RINGM)
    inc a
    ld d, a
    ld e, 0                      ; DE = ring size
    add hl, de                  ; wrapped: + ring
.occ:
    ex de, hl                   ; DE = occupied
    ld h, (ix+SMPB_RINGM)
    ld l, $FF                    ; HL = ring-1 (RINGM:$FF - ring is 256-aligned)
    or a
    sbc hl, de                  ; HL = free - 1 (>= 0; occupied <= ring-1)
    ld de, (smpCpTo)
    ex de, hl                   ; HL = toFill, DE = free-1
    or a
    sbc hl, de
    jr c, .strm                 ; toFill < free-1: keep (smpCpTo already set)
    ld (smpCpTo), de            ; toFill >= free-1: clamp to free-1
.strm:
    ; STREAMING FRONTIER CLAMP (SP18 item 7 Task 6). A channel the
    ; refiller is still feeding may only be pumped as far as the refiller
    ; has actually STAGED, or a starved stream replays stale window bytes
    ; instead of underrunning cleanly and recovering. UNDERRUNNING
    ; CLEANLY IS NOT SILENCE: a short fill lets play catch write and
    ; ctc_isr holds the LAST REAL SAMPLE (a DC level) until the refiller
    ; catches up. The DAC_SILENCE guard pad belongs to the play-once
    ; drain path only - aud_smp_tick's loop-mode test returns before it -
    ; so a starved LOOPING stream is audibly a DC hold, not a gap. That
    ; hold-last behaviour is the engine's established discipline and is
    ; unchanged; the clamp only decides DC-hold versus stale bytes.
    ; The available figure is the identity recorded at the debit site
    ; below:
    ;     available = SMPB_DEPTH*512 - (SMPB_OFF & $1FF)
    ; i.e. whole staged blocks ahead of the consumer, less how far into
    ; the block it currently sits. Applied LAST, after the play-once and
    ; backpressure clamps, so "it bit" means the staged frontier - not
    ; the ring and not the payload - was the binding limit; that is what
    ; the DEBUG underrun counter records.
    ; GATED ON BITS 2/4 ONLY. A COMPLETE window (bit 3) holds the whole
    ; file permanently, and a stream whose refiller reached EOF (all
    ; three bits clear, window holding the tail) holds every byte the
    ; consumer can still want; neither may be penalised by a
    ; block-granular figure. DEPTH's high byte is not read: the
    ; refiller's room gate and the open both cap DEPTH at SFX_WIN_BLKS,
    ; and were it ever larger this would under-report and starve, which
    ; is the safe direction.
    ld a, (ix+SMPB_FLAGS)
    and %00010100               ; STREAMING or REWIND owed
    jr z, .snap
    ld a, (ix+SMPB_DEPTH)
    add a, a                    ; DEPTH*512 = (DEPTH*2) * 256
    ld h, a
    ld l, 0
    ld a, (ix+SMPB_OFF+1)
    and 1
    ld d, a
    ld e, (ix+SMPB_OFF)         ; DE = OFF & $1FF (bytes into the block)
    or a
    sbc hl, de                  ; HL = available (negative only when
    jr nc, .avail               ; DEPTH is 0 mid-block, i.e. a REWIND
    ld hl, 0                    ; the refiller has not serviced yet)
.avail:
    ld de, (smpCpTo)
    or a
    sbc hl, de
    jr nc, .snap                ; available >= toFill: nothing to clamp
    add hl, de                  ; restore HL = available
    ld (smpCpTo), hl
 IFDEF DEBUG
    ; Per-channel underrun counter. Which block IX points at is the only
    ; thing that distinguishes the two channels in here, so compare it
    ; rather than infer anything from where the blocks happen to sit
    ; (sfxChan0 is page-48 data, sfxChan1 is resident).
    push ix
    pop hl
    ld de, sfxChan0
    or a
    sbc hl, de
    ld hl, sfxUnderrun0
    jr z, .uctr
    ld hl, sfxUnderrun1
.uctr:
    inc (hl)                    ; 16-bit increment through (HL)
    jr nz, .snap
    inc hl
    inc (hl)
 ENDIF
.snap:
    ld a, (ix+SMPB_TABIDX)
    ld (smpCpIdx), a
    ld l, (ix+SMPB_OFF)
    ld h, (ix+SMPB_OFF+1)
    ld (smpCpOff), hl
    ld l, (ix+SMPB_REMAIN)
    ld h, (ix+SMPB_REMAIN+1)
    ld (smpCpRemLo), hl
    ld a, (ix+SMPB_REMAIN+2)
    ld (smpCpRemHi), a
    ld l, (ix+SMPB_LEN)
    ld h, (ix+SMPB_LEN+1)
    ld (smpCpLen), hl
    ld a, (ix+SMPB_LEN+2)
    ld (smpCpLenHi), a
    ld l, (ix+SMPB_W)
    ld h, (ix+SMPB_W+1)
    ld (smpCpDst), hl           ; working ring dest offset (0-AUD_STAGE_RING)
    ld a, (ix+SMPB_FLAGS)
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
    call aud_smp_anchor         ; loop: rewind to the payload start
    ld (smpCpIdx), a            ; (seamless - the ring never notices the
    ld (smpCpOff), hl           ; seam), NOT to window byte 0: the WAV
                                ; header stages in front of the payload
    call aud_smp_rewind_depth   ; and re-credit DEPTH for the new position
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
    ld a, (ix+SMPB_RINGM)
    inc a
    ld h, a
    ld l, 0                      ; HL = ring size
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
    ld h, (ix+SMPB_RINGH)       ; dest abs = ring base + dstOff -> DE
    ld l, 0
    ld de, (smpCpDst)
    add hl, de
    ex de, hl                   ; DE = dest abs
    ld a, (smpCpIdx)            ; slot 7 <- window page list[idx]; the
    ld l, a                     ; list is this channel's own (page 48,
    ld h, 0                     ; slot 6), reached through SMPB_WINTAB
    ld c, (ix+SMPB_WINTAB)
    ld b, (ix+SMPB_WINTAB+1)
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
    ;
    ; DEPTH INVARIANT (SP18 item 7 Task 5). SMPB_DEPTH counts 512-byte
    ; window blocks that the PRODUCER has staged and the CONSUMER has not
    ; yet finished with. The producer (sfx_stream_open here, the refiller
    ; from Task 6 on) credits one per block written; the consumer debits
    ; one per 512-byte boundary its window position crosses, which is
    ; what this block does. The open pre-debits the whole blocks the
    ; consumer skips outright - its anchor starts past the WAV header -
    ; so the two sides balance exactly even when the anchor sits in the
    ; MIDDLE of a block: that block stays credited and is debited here
    ; when the consumer crosses the NEXT boundary, like any other.
    ;
    ; The identity holds ACROSS A LOOP REWIND as well, which is the one
    ; case the debit alone cannot express: a rewind moves the consumer
    ; backwards by the whole payload, so DEPTH is RE-CREDITED there
    ; rather than debited (aud_smp_rewind_depth, above - a COMPLETE
    ; window restores the anchor's banked DEPTH, a STREAMING one
    ; declares itself empty and hands the re-stage to the refiller).
    ; DEPTH is therefore an exact "blocks staged and not yet finished
    ; with" figure at every point, not merely within one forward pass.
    ; Two riders for whoever adds the consumer clamp: DEPTH is
    ; block-granular, so it over-reports by up to 511 bytes at the tail
    ; of a payload (the last partial block stays credited) and must be
    ; combined with REMAIN, never trusted alone.
    ;
    ; Arithmetic: off is 0..$2000 and (H:L) >> 9 == H >> 1 for any such
    ; value (L < 256 can never carry into bit 9), so the crossings a
    ; segment makes are just the difference of the two halved high
    ; bytes. Blocks never straddle a window page (16 blocks per 8K page),
    ; so this stays exact across the roll below: a roll means the segment
    ; ended exactly on $2000 = boundary 16, and the next segment restarts
    ; at boundary 0 of the next page.
    ld hl, (smpCpOff)
    ld a, h
    srl a
    ld (smpCpBlk), a            ; block index before this segment
    ld bc, (smpCpSeg)
    add hl, bc
    ld (smpCpOff), hl           ; off += seg
    ld a, h
    srl a                       ; block index after it (0..16)
    ld hl, smpCpBlk
    sub (hl)                    ; A = boundaries crossed by this segment
    call nz, aud_smp_debit
    ld hl, (smpCpOff)
    ld a, h
    cp $20
    jr c, .noroll               ; off < $2000: same window page
    sub $20                     ; rolled: off -= $2000, next window page
    ld h, a
    ld (smpCpOff), hl
    ld a, (smpCpIdx)
    inc a
    cp SFX_WIN_PAGES
    jr c, .idxok
    xor a                       ; the window is CIRCULAR: wrap mod 3
.idxok:
    ld (smpCpIdx), a
.noroll:
    ld bc, (smpCpSeg)
    ld hl, (smpCpDst)
    add hl, bc                  ; dstOff += seg
    ld a, (ix+SMPB_RINGM)
    inc a
    ld d, a
    ld e, 0                      ; DE = ring size
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
    nextreg $57, AUD_PAGE_HI    ; slot 7 back to the state page - required by the
                                ; rest of aud_tick (audFlags/audBeep*/audSongNum/
                                ; audPlayerUp at $FFE0), not by the writes below
    ld a, (smpCpIdx)            ; write back the advanced source position + W
    ld (ix+SMPB_TABIDX), a
    ld hl, (smpCpOff)
    ld (ix+SMPB_OFF), l
    ld (ix+SMPB_OFF+1), h
    ld hl, (smpCpRemLo)
    ld (ix+SMPB_REMAIN), l
    ld (ix+SMPB_REMAIN+1), h
    ld a, (smpCpRemHi)
    ld (ix+SMPB_REMAIN+2), a
    ld hl, (smpCpDst)
    ld (ix+SMPB_W), l           ; W advanced by the bytes actually copied
    ld (ix+SMPB_W+1), h
    ret

; (SP18 item 7 Task 11: the cold boot-only seed routine that used to sit
; here - aud_smp_chan1_init - moved to SFX_PAGE as aud_sfx_init, where it
; also seeds channel 2. It runs once per boot and never again, so it had
; no business holding page-48 code space, which is this sub-project's
; binding budget; the move gave that space back to the per-frame pump.
; overlay1's aud_boot_probe now reaches it through the resident
; sfx_page_call trampoline (main.asm) - Task 12 generalised the old
; per-callee aud_sfx_init_tramp into this one shared (HL) routine.)

; Copy scratch, in page-48 CODE space (slot 6, mapped throughout aud_tick).
; aud_smp_copy stages the source position + copy plan here BEFORE it windows a
; source page through slot 7, so the walk survives the remap; the channel
; block (sfxChan0, IX-relative) is also page 48, so it needs no slot 7
; discipline at all - only phase B's source-page window does. All bytes
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
smpCpBlk:   db 0    ; 512-block index inside the page before a segment,
                    ; held across the advance for the DEPTH debit

 IFDEF DEBUG
; SFX= report row, second field of each channel's triple (SP18 item 7
; Task 6, per channel since Task 11). Counts the copies on which the
; streaming frontier clamp above was the binding limit - a real underrun,
; i.e. the refiller could not keep that channel's window ahead of its
; DAC. Page-48 data because the PUMP writes them and cannot reach
; SFX_PAGE; the row printer that reads them lives beside the other
; counters on SFX_PAGE and runs with page 48 still in slot 6.
sfxUnderrun0: dw 0
sfxUnderrun1: dw 0
 ENDIF

; Per-channel sampled-effect pump state (SP18 item 7), SMPB_* offsets
; in nextdaad.inc. Page-48 data space, pinned in slot 6 for the whole of
; aud_tick - no slot-restore ordering applies to these members. IX is
; seeded to the channel block by each call site before an aud_smp_*
; routine runs.
sfxChan0:  ds SMPB_SIZE           ; channel 1 pump state (SP18 item 7)

; Per-channel effect WINDOW DESCRIPTORS (SP18 item 7 Task 5), addressed
; through SMPB_WINTAB. Layout (nextdaad.inc SFXW_*): the SFX_WIN_PAGES
; window page numbers, then the consumer's payload-start anchor, which
; sfx_stream_open writes and the pump reads on start and on every loop
; rewind. Page-48 data, so the pump may touch it at any point in the
; tick.
;
; The pages ARE the audio floor, banks 25-27, split into plain low and
; high halves: channel 1 takes 50/51/52 (bank 25's two halves plus bank
; 26's lower), channel 2 takes 53/54/55 (bank 26's upper plus bank 27's
; two halves). Static initialisers rather than a boot-time fill: the
; floor is a fixed assembly-time map now, exactly like the DAC ring
; base, and it is withdrawn from the bank allocator once (see
; aud_sfx_init) instead of being claimed per load. This retires
; smpPageTab/smpPageCnt (129 bytes) with the whole claim-the-payload
; model they served.
sfxWin0:
    db SMP_PAGE_FIRST+0, SMP_PAGE_FIRST+1, SMP_PAGE_FIRST+2
    db 0                             ; start window-page index (anchor)
    dw 0                             ; start offset inside that page
    dw 0                             ; DEPTH implied by that anchor
sfxWin1:
    db SMP_PAGE_FIRST+3, SMP_PAGE_FIRST+4, SMP_PAGE_FIRST+5
    db 0
    dw 0
    dw 0
    ASSERT sfxWin1 - sfxWin0 == SFXW_SIZE

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
; (aud_load_ays / aud_boot_probe), exactly as it does the channel block.

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
; the aysPageCnt byte sitting adjacent to aysPageTab (it does, the shape
; aud_banks_claim expects, but the guard here means that adjacency is
; never reached).
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

; --- DEBUG AY / player state mirror (SP16 Task 7b) -------------------

 IFDEF DEBUG
; aud_dbg_snap: mirror the WHOLE audible AY state - all three PSGs read
; back off the chips, plus the AKY player's own register arrays and its
; self-modified position cells - into the always-mapped staging ring at
; AUD_STAGE0, once per frame, right after aud_tick (call site:
; src\interrupts.asm im2_isr). A scripted ZEsarUX/DeZog leg then reads
; AUD_DBG_LEN (203) plain bytes out of the 64K map with no bank juggling and no
; breakpoint choreography: the STOPM three-point dump (pre-STOPM,
; post-STOPM, post-restart-MUSIC) is three reads of this block, and the
; fresh-boot control is a fourth.
;
; WHY THE CHIP READBACK AND NOT JUST THE PLAYER ARRAYS. The player
; rewrites R0-R13 from its arrays every frame, so the arrays are what
; the player INTENDS; the chips are what is actually sounding. Anything
; that writes the AY outside the player (aud_psg_silence on STOPM,
; aud_beep_start, the AYS stream engine) shows up only in the readback.
; Both are captured so a divergence between them is itself evidence.
; ALL THREE PSGs, always - the PSG-park precedent (d79841c).
;
; WHY THE RING. AUD_STAGE0 is bank 5, MMU3, always mapped, so the block
; is readable from mainline context without mapping bank 24; and it is
; dead memory whenever no sample is playing. The SMPB_FLAGS guard below
; makes that conditional explicit - with a sample active the ring is the
; DAC's and this routine does nothing (the leg it serves plays no
; samples). ctc_isr is stopped whenever SMPB_FLAGS bit 0 is clear
; (aud_smp_stop resets the CTC), so nothing races these writes.
;
; DEBUG ONLY. Costs ~9.4k T per frame in the ISR - instruction-counted,
; not estimated: ~3.4k for the 42 chip selects+reads, ~4.2k for the
; 40-cell gather loop, ~1.4k for the 64-byte array LDIR, the rest
; header. That is ~1.7% of a 28 MHz frame, and it is why the Task 7 ear
; cards for audio QUALITY are specified as Release legs - an ear leg
; about distortion must not run with an extra instrument in the
; interrupt path. Also costs AUD_DBG_LEN (203) bytes of the sample
; ring. Neither cost exists in a Release build.
; Called with the audio bank mapped, all registers already saved by the
; ISR, so it corrupts freely.
AUD_DBG_SNAP  equ AUD_STAGE0     ; mirror base (the sample ring)
AUD_DBG_AY    equ $10            ; 3 x 14 chip registers
AUD_DBG_ARR   equ $3A            ; 64 bytes of player register arrays
AUD_DBG_CELL  equ $7A            ; AUD_DBG_NCELL words from the cell table
AUD_DBG_NCELL equ 40             ; entries in aud_dbg_cells (ASSERTed below)
AUD_DBG_SEQ2  equ AUD_DBG_CELL + 2*AUD_DBG_NCELL
AUD_DBG_LEN   equ AUD_DBG_SEQ2 + 1

aud_dbg_snap:
    ld ix, sfxChan0
    ld a, (ix+SMPB_FLAGS)
    rrca
    ret c                           ; a sample owns the ring - hands off
    ld hl, aud_dbg_sig
    ld de, AUD_DBG_SNAP
    ld bc, 4
    ldir                            ; +$00 signature "AYS1"
    ld hl, audDbgSeq
    inc (hl)
    ld a, (hl)
    ld (AUD_DBG_SNAP+$04), a        ; frame sequence (wraps at 256)
    ld a, (audFlags)
    ld (AUD_DBG_SNAP+$05), a
    ld a, (audSongNum)
    ld (AUD_DBG_SNAP+$06), a
    ld a, (audPlayerUp)
    ld (AUD_DBG_SNAP+$07), a
    ld a, (aysFlags)
    ld (AUD_DBG_SNAP+$08), a
    ld a, (ix+SMPB_FLAGS)
    ld (AUD_DBG_SNAP+$09), a
    ld a, (audRequest)
    ld (AUD_DBG_SNAP+$0A), a
    ld a, (audRequest2)
    ld (AUD_DBG_SNAP+$0B), a
    ld hl, (audBeepFrames)
    ld (AUD_DBG_SNAP+$0C), hl
    ld a, (audEnable)
    ld (AUD_DBG_SNAP+$0E), a
    ld a, (audReqLoop)
    ld (AUD_DBG_SNAP+$0F), a
    ; --- chip readback: select the PSG, then each register 0-13 on
    ; $FFFD and read the same port back. aud_psg3_select corrupts BC
    ; only (preserves AF/DE/HL), so D survives as the register counter.
    ld hl, AUD_DBG_SNAP+AUD_DBG_AY
    ld a, $FF                       ; PSG 1, then $FE (PSG 2), $FD (PSG 3)
.chip:
    ld (audDbgSel), a
    call aud_psg3_select
    ld d, 0
.reg:
    ld bc, $FFFD
    out (c), d                      ; register select
    in a, (c)                       ; register value back off the chip
    ld (hl), a
    inc hl
    inc d
    ld a, d
    cp 14
    jr c, .reg
    ld a, (audDbgSel)
    dec a
    cp $FC                          ; $FD was the last chip
    jr nz, .chip
    ; --- the player's four register arrays, one contiguous run
    ld hl, PLY_AKY_PSG1SOFTWAREREGISTERARRAY
    ld de, AUD_DBG_SNAP+AUD_DBG_ARR
    ld bc, 64
    ldir
    ; --- the self-modified position cells, gathered through a table of
    ; source addresses (doc 07, any-address word table). Two bytes are
    ; taken from every cell including the byte-wide ones; the second
    ; byte is then the following opcode, a constant, which is a free
    ; tell-tale that the table entry still points where it should.
    ld hl, aud_dbg_cells
    ld de, AUD_DBG_SNAP+AUD_DBG_CELL
    ld b, AUD_DBG_NCELL
.cell:
    ld c, (hl)
    inc hl
    ld a, (hl)
    inc hl
    push hl
    ld l, c
    ld h, a                         ; HL = the cell this entry names
    ld a, (hl)
    ld (de), a
    inc hl
    inc de
    ld a, (hl)
    ld (de), a
    inc de
    pop hl
    djnz .cell
    ; TEAR DETECTOR. The reader samples this block while the Z80 keeps
    ; running, so a read can straddle a frame update and splice two
    ; frames together - which shows up as a handful of "differences" in
    ; exactly the bytes that change on a note boundary, and would be
    ; mistaken for state residue. The sequence byte is written FIRST at
    ; +$04 and copied LAST here: a reader that sees the two disagree
    ; must discard the sample.
    ld a, (audDbgSeq)
    ld (AUD_DBG_SNAP+AUD_DBG_SEQ2), a
    ret

aud_dbg_sig:  db "AYS1"
audDbgSeq:    db 0
audDbgSel:    db 0

; Every cell the AKY player self-modifies that carries POSITION or
; PHASE, in the order the dump tables in the Task 7 report print them.
; Sources are the labels the Arkos converter emitted (player_aky.asm) -
; a rename there breaks the build here rather than dumping the wrong
; addresses silently.
aud_dbg_cells:
    dw PLY_AKY_PATTERNFRAMECOUNTER+1        ; frames left in this pattern
    dw PLY_AKY_PATTERNFRAMECOUNTER_OVER+1   ; linker read position
    dw PLY_AKY_PTSOUNDEFFECTTABLE+1         ; GAME.SFB table (0 = none)
    dw PLY_AKY_CHANNEL1_SOUNDEFFECTDATA     ; effect stream (0 = idle)
    dw PLY_AKY_CHANNEL1_PTTRACK+1
    dw PLY_AKY_CHANNEL2_PTTRACK+1
    dw PLY_AKY_CHANNEL3_PTTRACK+1
    dw PLY_AKY_CHANNEL4_PTTRACK+1
    dw PLY_AKY_CHANNEL5_PTTRACK+1
    dw PLY_AKY_CHANNEL6_PTTRACK+1
    dw PLY_AKY_CHANNEL7_PTTRACK+1
    dw PLY_AKY_CHANNEL8_PTTRACK+1
    dw PLY_AKY_CHANNEL9_PTTRACK+1
    dw PLY_AKY_CHANNEL1_PTREGISTERBLOCK+1
    dw PLY_AKY_CHANNEL2_PTREGISTERBLOCK+1
    dw PLY_AKY_CHANNEL3_PTREGISTERBLOCK+1
    dw PLY_AKY_CHANNEL4_PTREGISTERBLOCK+1
    dw PLY_AKY_CHANNEL5_PTREGISTERBLOCK+1
    dw PLY_AKY_CHANNEL6_PTREGISTERBLOCK+1
    dw PLY_AKY_CHANNEL7_PTREGISTERBLOCK+1
    dw PLY_AKY_CHANNEL8_PTREGISTERBLOCK+1
    dw PLY_AKY_CHANNEL9_PTREGISTERBLOCK+1
    dw PLY_AKY_CHANNEL1_WAITBEFORENEXTREGISTERBLOCK+1
    dw PLY_AKY_CHANNEL2_WAITBEFORENEXTREGISTERBLOCK+1
    dw PLY_AKY_CHANNEL3_WAITBEFORENEXTREGISTERBLOCK+1
    dw PLY_AKY_CHANNEL4_WAITBEFORENEXTREGISTERBLOCK+1
    dw PLY_AKY_CHANNEL5_WAITBEFORENEXTREGISTERBLOCK+1
    dw PLY_AKY_CHANNEL6_WAITBEFORENEXTREGISTERBLOCK+1
    dw PLY_AKY_CHANNEL7_WAITBEFORENEXTREGISTERBLOCK+1
    dw PLY_AKY_CHANNEL8_WAITBEFORENEXTREGISTERBLOCK+1
    dw PLY_AKY_CHANNEL9_WAITBEFORENEXTREGISTERBLOCK+1
    dw PLY_AKY_CHANNEL1_REGISTERBLOCKLINESTATE_OPCODE
    dw PLY_AKY_CHANNEL2_REGISTERBLOCKLINESTATE_OPCODE
    dw PLY_AKY_CHANNEL3_REGISTERBLOCKLINESTATE_OPCODE
    dw PLY_AKY_CHANNEL4_REGISTERBLOCKLINESTATE_OPCODE
    dw PLY_AKY_CHANNEL5_REGISTERBLOCKLINESTATE_OPCODE
    dw PLY_AKY_CHANNEL6_REGISTERBLOCKLINESTATE_OPCODE
    dw PLY_AKY_CHANNEL7_REGISTERBLOCKLINESTATE_OPCODE
    dw PLY_AKY_CHANNEL8_REGISTERBLOCKLINESTATE_OPCODE
    dw PLY_AKY_CHANNEL9_REGISTERBLOCKLINESTATE_OPCODE
    ASSERT ($ - aud_dbg_cells) / 2 == AUD_DBG_NCELL
    ; the four arrays the LDIR above copies as one run must BE one run
    ASSERT PLY_AKY_SFXREG6 + 1 - PLY_AKY_PSG1SOFTWAREREGISTERARRAY == 64
    ; and the whole mirror must fit inside the sample ring it borrows
    ASSERT AUD_DBG_LEN <= AUD_STAGE_RING
 ENDIF

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
    DISPLAY "page 48 ends at ", $, " headroom ", /D, AUD_SFB_ORG - $

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
