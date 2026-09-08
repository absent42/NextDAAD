; Stereo stream: MUSIC.PCM, unsigned 8-bit L/R pairs at 15625 Hz, through
; an 8K ring in page 40. CTC channel 0 drives pcm_isr; the main loop refills.
pcm_open:
    ld hl, pcmName
    call name_intro
    call esx_open_name
    jr nc, .ok
    ld a, ERR_MUS_OPEN
    jp dbg_code
.ok:
    ld (pcmHandle), a
    ld a, PG_MUSIC
    call map7
    ld hl, PCM_RING
    ld (pcmWr), hl
    ld (pcmRd), hl
    ld (pcmRdPrev), hl
    ld b, 4
.fill:
    push bc
    call pcm_read_chunk
    pop bc
    jr c, .primefail
    djnz .fill
    ld hl, 8192
    ld (pcmAvail), hl
    ld hl, pcm_isr
    ld (IM2_CTC_STUB+1), hl
    ld e, NR_VIDEO_TIMING
    call nr_read
    and 7
    ld hl, pcmTcTab
    add hl, a
    ld a, (hl)
    ld (pcmTc), a
    ld bc, AUD_CTC_PORT
    ld a, AUD_CTC_RESET
    out (c), a
    out (c), a
    ld a, AUD_CTC_CW16
    out (c), a
    ld a, (pcmTc)
    out (c), a                       ; timer starts
    ret
.primefail:                          ; a prime read failed: close, stay silent
    ld a, (pcmHandle)
    call esx_close_a
    ld a, $FF
    ld (pcmHandle), a
    ld a, ERR_MUS_PCM
    jp dbg_code
pcmName:  db "MUSIC.PCM", 0
pcmTc:    db 0
pcmTcTab: db 112, 114, 117, 120, 124, 128, 132, 108
    ASSERT $ - pcmTcTab == 8         ; indexed by NR $11 and 7 (rubric 8)

; Reads LOAD_CHUNK bytes at pcmWr, rewinding at EOF (MUSIC.PCM is >= 8192
; bytes, even length - introc.ps1 - so the rewind read always completes).
; Out: CF set and pcmWr untouched on any read failure; else pcmWr advances.
pcm_read_chunk:
    ld a, PG_MUSIC
    call map6
    ld hl, (pcmWr)
    ld de, PCM_RING
    or a
    sbc hl, de
    ld (pcmOff), hl                  ; window offset
    ex de, hl
    ld a, (pcmHandle)
    ld bc, LOAD_CHUNK
    call esx_read6
    jr c, .fail
    ld hl, LOAD_CHUNK
    or a
    sbc hl, bc
    jr z, .adv
    ; short: rewind, read the remainder after the bytes we got
    push hl                          ; wanted = LOAD_CHUNK - got
    push bc                          ; got
    ld a, (pcmHandle)
    call esx_seek0
    pop bc
    ld hl, (pcmOff)
    add hl, bc
    ex de, hl                        ; DE = offset + got
    pop bc                           ; BC = wanted
    ld a, (pcmHandle)
    call esx_read6
    jr c, .fail
.adv:
    ld hl, (pcmWr)
    ld de, LOAD_CHUNK
    add hl, de
    ld a, h
    or a
    jr nz, .w
    ld hl, PCM_RING
.w:
    ld (pcmWr), hl
    or a                              ; CF clear: success
    ret
.fail:
    scf
    ret
pcmOff: dw 0
    ASSERT (PCM_RING & $1FFF) == 0   ; ring is page-aligned (doc 03 wrap idiom)
    ASSERT PCM_RING + 8192 == $10000 ; ring ends exactly at the 64K wrap
    ASSERT (pcmXlat & $FF) == 0      ; xlat is page-aligned (pcm_isr indexing)
    ASSERT (8192 % LOAD_CHUNK) == 0  ; the ring's mod-8192 accounting assumes this

; Main-loop refill: account the interrupt's consumption, read one chunk
; when there is room. Out NZ when a read happened; a failed read reports
; ERR_MUS_PCM (DEBUG) and returns Z, so the loader keeps its own frame.
pcm_refill:
    ld a, (pcmHandle)
    cp $FF
    jr z, .no
    ld hl, (pcmRd)
    ld de, (pcmRdPrev)
    ld (pcmRdPrev), hl
    or a
    sbc hl, de
    ld a, h
    and $1F
    ld h, a                          ; consumed = (rd - prev) mod 8192
    ex de, hl
    ld hl, (pcmAvail)
    or a
    sbc hl, de
    jr nc, .avail_ok                 ; clamp: a missed frame must not wrap avail
    ld hl, 0
.avail_ok:
    ld (pcmAvail), hl
    ld de, 8192-LOAD_CHUNK-64
    or a
    sbc hl, de                       ; avail - (8192-LOAD_CHUNK-64)
    jr nc, .no                       ; not enough room yet
    call pcm_read_chunk
    jr c, .readfail
    ld hl, (pcmAvail)
    ld de, LOAD_CHUNK
    add hl, de
    ld (pcmAvail), hl
    or 1
    ret
.readfail:
    ld a, ERR_MUS_PCM
    call dbg_code
.no:
    xor a
    ret

; CTC interrupt: one L/R pair through the translation table to the DACs.
pcm_isr:
    push af
    push hl
    push de
    ld hl, (pcmRd)
    ld d, high pcmXlat
    ld e, (hl)
    ld a, (de)
    out (VID_DAC_LEFT), a
    inc hl
    ld e, (hl)
    ld a, (de)
    out (VID_DAC_RIGHT), a
    inc hl
    ld a, h
    or $E0                           ; branchless ring wrap (doc 03): $00 -> $E0
    ld h, a
    ld (pcmRd), hl
    pop de
    pop hl
    pop af
    ei
    reti

; pcmXlat[s] = (s - 128) * fadeVol / 16 + 128. L is the index (the table
; is page-aligned, doc 03); BSRL does the shift (doc 10). Corrupts all.
pcm_xlat_build:
    ld hl, pcmXlat
.s:
    ld a, l
    sub 128
    ld c, a
    or a
    jp p, .pos
    neg
.pos:
    ld d, a
    ld a, (fadeVol)
    ld e, a
    mul d, e
    ld b, 4
    bsrl de, b                       ; DE >> 4
    ld a, e
    bit 7, c
    jr z, .p2
    neg
.p2:
    add a, 128
    ld (hl), a
    inc l
    jr nz, .s
    ret

pcm_stop:
    ld bc, AUD_CTC_PORT
    ld a, AUD_CTC_RESET
    out (c), a
    out (c), a
    ld hl, pcm_isr_idle
    ld (IM2_CTC_STUB+1), hl
    ld a, DAC_SILENCE
    out (VID_DAC_LEFT), a
    out (VID_DAC_RIGHT), a
    ld a, (pcmHandle)
    cp $FF
    ret z
    call esx_close_a
    ld a, $FF
    ld (pcmHandle), a
    ret
