; streamfx.asm - SP18 item 7: sampled-effect SD streaming machinery.
; Lives on SFX_PAGE (71, upper 8K of bank 35 - the same withdrawn bank
; VID_PAGE2 uses for its lower 8K, page 70). Mapped into MMU slot 7
; ($E000) by its callers, both of which are live: the mainline open and
; window staging (sfx_stream_open, reached through the resident
; sfx_open_tramp from overlay1's aud_load_wav) and the per-frame burst
; refiller (aud_sfx_refill, dispatched from im2_isr right after
; aud_tick).
;
; EVERYTHING here follows the video player's silicon-proven wire rules
; (video.asm's SD streaming cluster, the vid_*_h routines cloned below):
; 16 T-nominal $EB ($EB = PORT_SPI_DAT) spacing, ini trains with A as
; the outer counter, bounded polls only, Multiface disabled for the
; duration of an open window, interrupts stay ON throughout (no DI/EI
; anywhere in this file). Routine bodies are cloned byte-for-byte from
; video.asm with only the cell names changed (see each routine's header
; below for its source line range at commit 29be065) - do not "improve"
; any instruction sequence here: these are silicon-proven wire shapes
; and any deviation is a new shape needing its own bench row.
;
; MECHANISM DEVIATION FROM THE TASK BRIEF: the brief sketched a boot-
; time bank_alloc pin into a resident sfxPageVar cell. That does not
; match how the only other pool-excluded, content-bearing pages
; (VID_PAGE 59, VID_PAGE2 70) actually work: they are FIXED page
; numbers, excluded from the allocator by never being marked BT_FREE in
; bank_table_init (banks.asm), and their content reaches the built .nex
; only because SAVENEX AUTO (main.asm) bakes in any page with assembled
; bytes - no runtime allocation call, no pin, no resident page-number
; cell. Bank 35 is already wholly excluded from the pool that way
; (nextdaad.inc's own comment: bank 35 is "ALSO withdrawn" for
; VID_PAGE2's page 70 - the free-pool loop in bank_table_init starts at
; BANK_POOL_B=36), so this page's sibling upper 8K, page 71, is already
; unreachable to bank_alloc with ZERO further changes to banks.asm.
; SFX_PAGE is therefore a plain equ (nextdaad.inc), this file is
; included from main.asm exactly like video.asm, and there is no boot
; pin step, no sfxPageVar cell and no bank_alloc call - the page is
; permanent from assembly time on, same as VID_PAGE2.
    MMU 7, SFX_PAGE, OVL_ORG
sfx_page_base:

; Advance to the next hot filemap run. CF set = map exhausted.
; Corrupts AF, C, DE, HL.
; Clone of video.asm's vid_next_run_h (:2955-2988, commit 29be065).
; Cells: vidHotMap -> sfxHotMap, vidStrmEntryIdx/Cnt -> sfxRunIdx/Cnt,
; vidRunAddrLoH/HiH -> sfxRunAddrLo/Hi, vidStrmRunBlkH -> sfxRunBlk.
sfx_next_run:
    ld a, (sfxRunIdx)
    ld c, a
    ld a, (sfxRunCnt)
    cp c
    jr z, .out
    ld a, c
    add a, a
    add a, c                     ; idx * 3
    add a, a                     ; idx * 6 (<= 42: 8-entry hot map)
    ld hl, sfxHotMap
    add hl, a                    ; Z80N (doc 05)
    ld e, (hl)
    inc hl
    ld d, (hl)
    inc hl
    ld (sfxRunAddrLo), de
    ld e, (hl)
    inc hl
    ld d, (hl)
    inc hl
    ld (sfxRunAddrHi), de
    ld e, (hl)
    inc hl
    ld d, (hl)
    ld (sfxRunBlk), de
    ld a, c
    inc a
    ld (sfxRunIdx), a
    or a
    ret
.out:
    scf
    ret

; Ensure the CMD18 window is open at the hot run cursor (idempotent).
; CF set = command rejected (MF restored, card deselected). Corrupts
; AF, BC, DE, HL.
; Clone of video.asm's vid_win_open_h (:2993-3013, commit 29be065).
; Cells: vidRunAddrLoH/HiH -> sfxRunAddrLo/Hi, vidWinOpenH -> sfxWinOpen,
; vidCardFlagsH -> sfxCardFlags.
sfx_win_open:
    ld a, (sfxWinOpen)
    or a
    ret nz
    call sfx_mf_disable
    ld a, (sfxCardFlags)
    and 1                        ; Z = card select (sfx_sd_cmd reads)
    ld hl, (sfxRunAddrHi)
    ld de, (sfxRunAddrLo)
    ld a, CMD18_READ_MULTIPLE_BLOCK
    call sfx_sd_cmd
    jr nz, .rej
    ld a, 1
    ld (sfxWinOpen), a
    or a
    ret
.rej:
    call sfx_card_desel
    call sfx_mf_restore
    scf
    ret

; Close the window if open: CMD12 + flush + deselect + MF restore.
; Idempotent. Corrupts AF, BC, DE, HL.
; Clone of video.asm's vid_win_close_h (:3017-3033, commit 29be065).
; Cells: vidWinOpenH -> sfxWinOpen, vidCardFlagsH -> sfxCardFlags.
sfx_win_close:
    ld a, (sfxWinOpen)
    or a
    ret z
    ld a, (sfxCardFlags)
    and 1
    ld a, CMD12_STOP_TRANSMISSION
    call sfx_sd_cmd_np
    ld b, 8+1
.tail:
    in a, (PORT_SPI_DAT)
    djnz .tail
    call sfx_card_desel
    call sfx_mf_restore
    xor a
    ld (sfxWinOpen), a
    ret

; Clone of video.asm's vid_card_desel_h (:3035-3041, commit 29be065).
; No cells renamed.
sfx_card_desel:
    ld a, $FF
    out (PORT_SPI_CS), a
    in a, (PORT_SPI_DAT)
    nop
    in a, (PORT_SPI_DAT)
    ret

; SD SPI command (streaming clone of the video hot SD command; Z on
; entry = card select from the caller's `and 1`). Bounded R1 poll
; (rubric 6). Clone of video.asm's vid_sd_cmd_np_h/vid_sd_cmd_h
; (:3050-3083, commit 29be065 - the np entry immediately precedes at
; :3045-3049 and is cloned with it, since sfx_win_close needs the
; zeroed-HL/DE fallthrough exactly as vid_win_close_h does). No cells
; renamed (register-parameterised).
sfx_sd_cmd_np:
    ld h, 0
    ld l, 0
    ld d, 0
    ld e, 0
sfx_sd_cmd:
    ld b, $FF
    ld c, a
    ld a, SD_CS0
    jr z, .cs
    ld a, SD_CS1
.cs:
    out (PORT_SPI_CS), a
    in a, (PORT_SPI_DAT)
    ld a, c
    ld c, PORT_SPI_DAT
    out (c), a
    ld a, h
    out (c), a
    ld a, l
    out (c), a
    ld a, d
    out (c), a
    ld a, e
    out (c), a
    ld a, b
    out (c), a
    nop
    ld b, 0                      ; bounded R1 poll: 256 tries
.resp:
    in a, (PORT_SPI_DAT)
    inc a
    jr nz, .got
    djnz .resp
    or 1                         ; timeout: NZ (treated as reject)
    ret
.got:
    dec a                        ; Z iff R1 == 0
    ret

; Wait for the $FE data token (hot; bounded 65536 polls - rubric 6).
; CF set = bad/absent token. Corrupts AF, BC. Shared by every SFX
; block-read call site (only sfx_sd_blk, below - streamfx has no
; direct-serve variant). Clone of video.asm's vid_sd_tok_h
; (:3088-3137, commit 29be065). Cells: DEBUG counters vidTokPolls/Calls
; -> sfxTokPolls/Calls.
sfx_sd_tok:
    ld bc, 0                     ; bounded token wait: 65536 polls
.wt:
    in a, (PORT_SPI_DAT)
    inc a
    jr nz, .got
    dec bc
    ld a, b
    or c
    jr nz, .wt
    jr .bad
.got:
 IFDEF DEBUG
    ; SP18 item 7 TOKEN-POLL INSTRUMENT, cloned from the video player's
    ; SP17 bench row group 1a instrument (vid_sd_tok_h): the card's
    ; data-token wait is not timeable at raster resolution, but it IS
    ; exactly COUNTABLE - BC is the countdown from 0, so -BC is the
    ; number of poll iterations that returned $FF. Accumulated HERE, at
    ; .got, strictly OUTSIDE the poll loop: the loop itself is byte-
    ; identical to Release, so the counted quantity is undistorted.
    ; 16-bit accumulators: zeroed at bench entry. Polls per call =
    ; (accumulated) + 1 per call, since the successful poll does not
    ; decrement.
    push af
    push de
    push hl
    ld hl, 0
    or a
    sbc hl, bc                   ; HL = -BC = failed polls this call
    ex de, hl
    ld hl, (sfxTokPolls)
    add hl, de
    ld (sfxTokPolls), hl
    ld hl, (sfxTokCalls)
    inc hl
    ld (sfxTokCalls), hl
    pop hl
    pop de
    pop af
 ENDIF
    dec a
    cp $FE
    ret z                        ; CF clear from the cp
.bad:
    scf
    ret

; Read one 512-byte block into (HL) (hot clone; 32-ini sixteenths in
; both build variants - same shape as the video hot block reader it is
; cloned from, see video.asm's vid_sd_blk_h header for the tradeoff
; rationale). A is the outer counter (rubric 2 - ini consumes B). CF
; set = bad token. Clone of video.asm's vid_sd_blk_h (:3143-3158,
; commit 29be065). No cells renamed (HL dest).
sfx_sd_blk:
    call sfx_sd_tok
    ret c
    ld c, PORT_SPI_DAT
    ld a, 16                     ; sixteen 32-byte chunks
.blk:
    DUP 32
      ini
    EDUP
    dec a
    jp nz, .blk
    in a, (c)                    ; skip the 2-byte CRC
    nop
    in a, (c)
    or a
    ret

; Multiface disable/restore, SFX streaming clone. NR $06 audio-chip-
; mode note: see video.asm's vid_mf_disable_h/vid_mf_disable - the same
; %11110111 mask, same verdict applies here. Clone of video.asm's
; vid_mf_disable_h/vid_mf_restore_h (:3162-3172, commit 29be065). Cells:
; vidMfSaveH -> sfxMfSave.
sfx_mf_disable:
    ld e, NR_PERIPH2
    call nr_read
    ld (sfxMfSave), a
    and %11110111
    nextreg NR_PERIPH2, a
    ret
sfx_mf_restore:
    ld a, (sfxMfSave)
    nextreg NR_PERIPH2, a
    ret

; ---------------------------------------------------------------------
; sfx_stream_open - the open ritual, window staging and the free hybrid
; (SP18 item 7 Task 5). Turns an already-open, already-header-validated
; WAV file into a staged channel window.
;
; Runs from MAINLINE (overlay1's aud_load_wav, through the resident
; sfx_open_tramp - overlay1 shares this slot-7 window, so the map/call/
; unmap has to happen from resident code). Slot 6 holds AUD_PAGE_LO on
; entry; this routine borrows it for the window pages while staging and
; hands it back as AUD_PAGE_LO on every exit path.
;
; In:  A  = effect number 1-254 (this channel's keep-last key)
;      L  = the open esxDOS handle
;      H  = payload length, bits 16-23 (the WAV data chunk's own size)
;      BC = payload length, bits 0-15
;      DE = data offset - the file offset of the FIRST PAYLOAD BYTE,
;           which overlay1's chunk walk tracked while it validated
;      IX = channel block (page 48)
; The payload length comes in because the staging loop reads the file's
; REAL size, not the data chunk's claimed size, so a lying chunk header
; can no longer be caught by a short read the way the old loader caught
; it. It is checked against F_FSTAT below instead.
; Out: CF clear = window staged, consumer anchored, flags committed.
;      CF set   = refused; the handle is closed and the block's cache
;                 bits (STREAMING, COMPLETE, REWIND) are all clear, so
;                 aud_load_wav falls back to the AY effect exactly as it
;                 always has.
; Corrupts everything.
;
; STAGING IS VERBATIM FROM FILE OFFSET 0 - the WAV header stages with the
; payload. The card side of this feature reads whole 512-byte blocks at
; addresses taken from the filemap, so no byte-shifting is possible on
; the wire; the CONSUMER skips the header instead, by starting at the
; data offset (the window descriptor's anchor, nextdaad.inc SFXW_STIDX).
;
; THE FREE HYBRID: a file that fits the window stages whole, is flagged
; COMPLETE and has its handle closed - it is resident, costs no further
; card traffic, and a repeat trigger of the same number rewinds for free
; through overlay1's keep-last check. A larger file stages its first
; SFX_WIN_BYTES, is flagged STREAMING, and keeps its handle and hot
; filemap as this channel's cached stream for the refiller.
sfx_stream_open:
    ld (sfxOpenNum), a
    ld (sfxChanPtr), ix
    ld (sfxDataOff0), de
    ld (sfxPayLen), bc
    ld a, h
    ld (sfxPayLenHi), a
    ld a, l
    ld (sfxNewHandle), a
    ; cache eviction: a previous STREAMING open on this channel left its
    ; handle cached (one cached stream per channel). Close it before
    ; adopting the new one - esxDOS handles are a small pool and a
    ; re-trigger must not leak one per open.
    ld a, (sfxHandle0)
    inc a
    jr z, .fresh
    dec a
    call esx_fclose
.fresh:
    ld a, (sfxNewHandle)
    ld (sfxHandle0), a
    ; --- filemap ritual, in the sector-cache ordering law's exact order:
    ; F_SEEK 0, a one-byte F_READ to prime the touched-file cache, F_SEEK
    ; 0 again, DISK_FILEMAP, and only THEN F_FSTAT. video.asm's
    ; vid_raw_setup / vid_stream_open_body are the proven template. Every
    ; esxDOS call goes through a file.asm wrapper, so cardBusy brackets
    ; the lot and the frame-ISR refiller can never overlap one.
    call sfx_seek0
    jp c, .refuse
    ld a, (sfxHandle0)
    ld ix, sfxProbeByte
    ld bc, 1
    call esx_fread
    jp c, .refuse
    call sfx_seek0
    jp c, .refuse
    ld a, (sfxHandle0)
    ld ix, sfxColdMap
    ld de, SFX_COLD_ENT
    call esx_filemap
    jp c, .refuse
    ld (sfxCardFlags), a
    ld a, e
    or d
    jp z, .frag                  ; buffer full: completeness unprovable.
                                 ; The buffer holds one more entry than
                                 ; the 32-extent case, so a 32-extent
                                 ; file always leaves DE >= 1 and only
                                 ; 33+ extents land here
    ld de, sfxColdMap
    or a
    sbc hl, de                   ; HL = bytes written (an exact x6)
    jp z, .refuse                ; empty map: nothing to stream
    ld b, 0
    ld de, 6
.count:
    inc b
    or a
    sbc hl, de
    jr nz, .count                ; B = run count (1..SFX_COLD_ENT)
    ld a, b
    cp SFX_HOT_ENT+1
    jp nc, .frag                 ; more than 8 runs: refuse and let the
                                 ; caller fall back to the AY effect -
                                 ; the file stays playable by loading
                                 ; nothing, and authors defrag
    ld (sfxRunCnt), a
    xor a
    ld (sfxRunIdx), a
    ; the hot map is what the refiller walks: copy the runs across
    ld a, b
    add a, a
    add a, b
    add a, a                     ; entries * 6 (<= 48)
    ld c, a
    ld b, 0
    ld hl, sfxColdMap
    ld de, sfxHotMap
    ldir
    ; F_FSTAT - legal only after the filemap, per the ordering law
    ld a, (sfxHandle0)
    ld ix, sfxFstatBuf
    call esx_fstat
    jp c, .refuse
    ld a, (sfxFstatBuf+10)       ; size >= 16 MB: absurd, refuse
    or a
    jp nz, .refuse
    ld hl, (sfxFstatBuf+7)
    ld a, (sfxFstatBuf+9)
    ld c, a
    or h
    or l
    jp z, .refuse                ; zero-length file
    ; total card blocks = ceil(size / 512). This is the CLAMP the
    ; refiller stops at: filemap runs cover whole FAT clusters and
    ; over-report the tail, so F_FSTAT's size is the authority.
    ld a, c
    ld de, 511
    add hl, de
    adc a, 0                     ; A:HL = size + 511 (24-bit)
    ld l, h
    ld h, a                      ; HL = (size + 511) >> 8
    srl h
    rr l                         ; HL = (size + 511) >> 9 (<= 32768)
    ld (sfxFileBlk0), hl
    ; the consumer anchor has to land INSIDE the window: a WAV whose
    ; payload starts more than a whole window into the file (pathological
    ; leading chunks) cannot be played by a design that stages verbatim
    ; from offset 0. Refuse rather than index off the end of the list.
    ld hl, (sfxDataOff0)
    ld de, SFX_WIN_BYTES
    or a
    sbc hl, de
    jp nc, .refuse
    ; PAYLOAD CONSISTENCY (Task 5 review I1): the data chunk's declared
    ; size has to fit inside the file that actually exists, i.e.
    ; dataOff + payload <= fileBytes. The old loader got this for free -
    ; it read exactly `payload` bytes and rejected the short read ("the
    ; data chunk lied"). The staging loop reads the file's REAL size
    ; instead, so its own short-read test can only catch a file that
    ; shrinks mid-load; without this test a WAV claiming 100000 bytes of
    ; payload in a 1000-byte file would stage COMPLETE and the pump would
    ; play 99000 bytes of stale window content. Refuse, exactly as
    ; before, which reaches the caller's AY fallback.
    ld hl, (sfxDataOff0)
    ld bc, (sfxPayLen)
    add hl, bc
    ld a, (sfxPayLenHi)
    adc a, 0                     ; A:HL = dataOff + payload (24-bit)
    jp c, .refuse                ; carried out of 24 bits: absurd
    ld c, a
    ld a, (sfxFstatBuf+9)        ; fileBytes bits 16-23
    cp c
    jp c, .refuse                ; fileHi < endHi: payload runs past EOF
    jp nz, .lenok                ; fileHi > endHi: fits with room over
    ld de, (sfxFstatBuf+7)       ; equal high bytes: compare low words
    ex de, hl                    ; HL = fileLo, DE = endLo
    or a
    sbc hl, de
    jp c, .refuse                ; fileLo < endLo: runs past EOF
.lenok:
    ; stage min(fileBytes, SFX_WIN_BYTES) - the whole file when it fits
    ld a, (sfxFstatBuf+9)
    or a
    jr nz, .partial              ; >= 64K: far past the window
    ld hl, (sfxFstatBuf+7)
    ld de, SFX_WIN_BYTES+1
    or a
    sbc hl, de
    jr nc, .partial              ; fileBytes > SFX_WIN_BYTES
    ld hl, (sfxFstatBuf+7)
    ld a, 1                      ; whole file: the free-hybrid path
    jr .setstage
.partial:
    ld hl, SFX_WIN_BYTES
    xor a
.setstage:
    ld (sfxWhole), a
    ld (sfxStageRem), hl
    ld (sfxStageLen), hl
    ; snapshot the window page list while page 48 is still in slot 6 -
    ; the staging loop below puts window pages there instead.
    ld ix, (sfxChanPtr)
    ld l, (ix+SMPB_WINTAB)
    ld h, (ix+SMPB_WINTAB+1)
    ld de, sfxWinPg
    ld bc, SFX_WIN_PAGES
    ldir
    ; --- staging: esxDOS F_READ, one 8K window page at a time through
    ; slot 6. Mainline esxDOS rather than raw CMD18 by design: nothing
    ; is playing yet so there is no jitter concern, it reuses the loader
    ; loop the sample engine has always used, and it keeps every effect
    ; that fits the window fully playable under CSpect, which has no raw
    ; SPI path at all. Only the in-playback refiller speaks CMD18.
    call sfx_seek0
    jp c, .refusemap
    xor a
    ld (sfxStgIdx), a
.stage:
    ld hl, (sfxStageRem)
    ld a, h
    or l
    jr z, .staged
    ld de, $2000
    or a
    sbc hl, de
    jr nc, .fullwin
    ld hl, (sfxStageRem)         ; partial final page
    jr .setwin
.fullwin:
    ld hl, $2000
.setwin:
    ld (sfxStgWin), hl
    ld hl, sfxWinPg
    ld a, (sfxStgIdx)
    add hl, a                    ; Z80N (doc 05)
    ld a, (hl)
    call data_map_page           ; slot 6 <- this window page
    ld a, (sfxHandle0)
    ld ix, DATA_WINDOW
    ld bc, (sfxStgWin)
    call esx_fread
    jp c, .refusemap
    ld hl, (sfxStgWin)
    or a
    sbc hl, bc                   ; requested - actually read
    jp nz, .refusemap            ; short read: the file lied about its
                                 ; own size between F_FSTAT and here
    ld hl, (sfxStageRem)
    ld bc, (sfxStgWin)
    or a
    sbc hl, bc
    ld (sfxStageRem), hl
    ld hl, sfxStgIdx
    inc (hl)
    jr .stage
.staged:
    ld a, AUD_PAGE_LO            ; slot 6 back for the block writes
    call data_map_page
    ld ix, (sfxChanPtr)
    ; staged blocks = ceil(stagedBytes / 512) (<= SFX_WIN_BLKS)
    ld hl, (sfxStageLen)
    ld de, 511
    add hl, de
    ld l, h
    ld h, 0
    srl l                        ; HL = (stagedBytes + 511) >> 9
    ld (sfxStagedBlk0), hl
    ; DEPTH = staged blocks MINUS the whole blocks the consumer skips
    ; outright (its anchor sits past them - the WAV header). The block
    ; the anchor sits INSIDE is counted: it is debited when the consumer
    ; crosses the next 512 boundary, exactly like any other block. See
    ; the invariant stated in full at aud_smp_copy's debit site.
    ld de, (sfxDataOff0)
    ld a, d
    srl a                        ; A = dataOff >> 9 = whole blocks
    ld e, a                      ;     skipped ((H:L) >> 9 == H >> 1)
    ld d, 0
    or a
    sbc hl, de
    jr nc, .depthok
    ld hl, 0                     ; anchor past everything staged: floor
.depthok:
    ld (ix+SMPB_DEPTH), l
    ld (ix+SMPB_DEPTH+1), h
    ld (sfxDepth0), hl           ; banked for the loop rewind: a COMPLETE
                                 ; window is permanent, so its rewind
                                 ; restores exactly this figure (it goes
                                 ; into the descriptor below, where the
                                 ; page-48 pump can reach it)
    ; consumer cursor AND the loop-rewind anchor: window page
    ; dataOff >> 13, offset dataOff & $1FFF. Both land in the window
    ; descriptor as well as the block, because the pump rewinds to them
    ; on every loop pass, long after this page is unmapped.
    ld de, (sfxDataOff0)
    ld a, d
    and $E0
    rlca
    rlca
    rlca                         ; A = dataOff >> 13
    ld c, a
    ld a, d
    and $1F
    ld d, a                      ; DE = dataOff & $1FFF
    ld (ix+SMPB_TABIDX), c
    ld (ix+SMPB_OFF), e
    ld (ix+SMPB_OFF+1), d
    ld l, (ix+SMPB_WINTAB)
    ld h, (ix+SMPB_WINTAB+1)
    ld bc, SFXW_STIDX
    add hl, bc                   ; HL -> the descriptor's anchor bytes
    ld a, (ix+SMPB_TABIDX)
    ld (hl), a
    inc hl
    ld (hl), e
    inc hl
    ld (hl), d
    inc hl
    ld de, (sfxDepth0)           ; SFXW_DEPTH0 follows the anchor
    ld (hl), e
    inc hl
    ld (hl), d
    ; flags: bits 2-4 are the loader's and the refiller's, bits 0/1 the
    ; pump's. Nothing can be active here (aud_load_wav stops and waits
    ; before it calls in), but preserve bits 0/1 rather than assume. A
    ; fresh open always clears bit 4 REWIND: this window has just been
    ; staged, so the refiller owes it no re-stage.
    ld a, (ix+SMPB_FLAGS)
    and %11100011
    ld c, a
    ld a, (sfxWhole)
    or a
    jr z, .streaming
    ld a, c
    or %00001000                 ; COMPLETE: the whole file is resident
    ld (ix+SMPB_FLAGS), a
    ld a, (sfxHandle0)           ; nothing more to read: release it
    call esx_fclose
    ld a, $FF
    ld (sfxHandle0), a
    ld a, (sfxOpenNum)
    ld (sfxKeep0), a
    ld (smpLoadedNum), a         ; arm the free rewind: a repeat trigger
    or a                         ; of this number costs zero card traffic
    ret
.streaming:
    ld a, c
    or %00000100                 ; STREAMING: the refiller owes blocks
    ld (ix+SMPB_FLAGS), a
    ; hand the refiller a virgin run cursor. Staging above went through
    ; esxDOS F_READ, not the run list, so sfxRunAddrLo/Hi and sfxRunBlk
    ; mean nothing yet: sfxSeek0 tells the first burst to seek the list
    ; to sfxStagedBlk0 before it opens a window. sfxDeliv0/sfxFailCnt0
    ; are this stream's failure state (see aud_sfx_refill's header).
    ld a, 1
    ld (sfxSeek0), a
    xor a
    ld (sfxDeliv0), a
    ld (sfxFailCnt0), a
    ld a, (sfxOpenNum)
    ld (sfxKeep0), a             ; handle + hot filemap stay open as this
                                 ; channel's cached stream (spec keep-open
                                 ; ruling), for the refiller
    ld a, $FF
    ld (smpLoadedNum), a         ; ...but the FREE-REWIND cache is not
                                 ; armed for a stream in flight in this
                                 ; task: a repeat trigger re-runs the
                                 ; whole open (Task 6's refiller settles
                                 ; rewind semantics for a live stream).
                                 ; The eviction at .fresh above closes
                                 ; the cached handle first, so re-opening
                                 ; leaks nothing.
    or a
    ret
.frag:
 IFDEF DEBUG
    ; inline marker, same idiom as h_sfx's unknown-sub-command block -
    ; the dbg_* helpers are resident, so they are as reachable from this
    ; page as they are from any overlay.
    ld b, 30
    ld c, 60
    call dbg_at
    ld hl, msgSfxFrag
    call dbg_puts
 ENDIF
.refusemap:
    ld a, AUD_PAGE_LO            ; a window page may still be in slot 6
    call data_map_page
.refuse:
    ld a, (sfxHandle0)
    inc a
    jr z, .noclose
    dec a
    call esx_fclose
.noclose:
    ld a, $FF
    ld (sfxHandle0), a
    ld (smpLoadedNum), a         ; nothing cached on this channel
    xor a
    ld (sfxKeep0), a
    ld ix, (sfxChanPtr)
    ld a, (ix+SMPB_FLAGS)
    and %11100011                ; the refusal funnel is one of the two
    ld (ix+SMPB_FLAGS), a        ; cache invalidations: STREAMING,
                                 ; COMPLETE and REWIND all off
    ld (ix+SMPB_DEPTH), 0
    ld (ix+SMPB_DEPTH+1), 0
    scf
    ret

; F_SEEK this channel's handle to absolute offset 0. Clone of the video
; player's vid_raw_seek0 - IXL is the seek-mode byte esxDOS reads; L is
; set belt-and-braces, matching that caller's posture.
sfx_seek0:
    ld bc, 0
    ld de, 0
    ld l, 0
    ld ix, 0
    ld a, (sfxHandle0)
    jp esx_fseek

 IFDEF DEBUG
msgSfxFrag: db "SFX FRAG?", 0
 ENDIF

; ---------------------------------------------------------------------
; THE REFILLER (SP18 item 7 Task 6) - channel 1 streaming becomes real.
;
; Called once per frame from aud_tick, AFTER the pump (aud_smp_tick), by
; a three-instruction dispatcher that maps this page into slot 7 and
; hands slot 7 back to AUD_PAGE_HI afterwards. On entry slot 6 holds
; AUD_PAGE_LO (page 48) - the channel block, its window descriptor and
; the pump's own scratch - and this code keeps it that way except for
; the few instructions around each block transfer, where a WINDOW page
; is mapped over slot 6 as the card's destination and restored the
; instant the transfer ends. Slot 6 is AUD_PAGE_LO on every exit path.
;
; WHAT ONE TICK DOES: at most SFX_BURST_CAP blocks for a channel and at
; most SFX_TICK_CAP across all channels, inside ONE CMD18 window that is
; opened at the run cursor and CLOSED before this routine returns. The
; window never outlives the tick, so mainline always finds the card free
; on the next frame boundary; that is also why the burst caps are small.
;
; THE WIRE RULES ARE THE VIDEO PLAYER'S, UNCHANGED: every $EB touch goes
; through the sfx_* clones above, interrupts stay ON throughout (no DI
; or EI anywhere in this file), A is the outer counter of the ini train,
; and every poll is bounded. Multiface bracketing is NOT done here -
; sfx_win_open disables MF when it actually opens and sfx_win_close
; restores it, and calling sfx_mf_disable a second time would save the
; ALREADY-MASKED NR $06 value over the real one and leave the Multiface
; disabled for good. The video player brackets it the same way, for the
; same reason.
;
; DEPTH IS SHARED WITH THE PUMP AND NEEDS NO LOCK. SMPB_DEPTH is a word,
; so a torn read would matter - but the pump (aud_smp_tick/aud_smp_copy)
; and this refiller are two calls in the SAME aud_tick chain and never
; run concurrently. The only interrupt that nests inside aud_tick is
; ctc_isr, which touches the resident ring cursors and the DAC port and
; nothing else. So the credits below are plain reads and writes.
;
; WHY THE VIDEO PLAYER CANNOT RACE THIS. The player is the tree's other
; raw-SD client and it holds a CMD18 window open across many blocks from
; MAINLINE, where cardBusy is clear - so the gate below would not see it.
; It does not have to: the player freezes audEnable for the whole of a
; video session (video.asm, the same freeze that stops the 50Hz tick
; remapping MMU6/7 under it), so im2_isr takes its fast path and neither
; aud_tick nor this refiller runs at all while a video is playing. It
; also waits for any sampled effect to stop before it starts.
;
; WHY THE OPEN CANNOT RACE THIS. sfx_stream_open runs from mainline with
; cardBusy set only inside each esxDOS call, so a frame ISR can land
; between two of them - but aud_load_wav stops the channel and waits
; before it calls in, and a stop clears bit 2 STREAMING and bit 4
; REWIND, so the channel gate below refuses for the whole of an open.
;
; THE FIRST-FAILURE LATCH (and the CSpect verdict). A wire failure on
; the FIRST block a stream ever asks for means the environment has no
; raw SD path at all rather than a transient - under CSpect there is no
; SPI engine behind port $EB, so CMD18's bounded R1 poll (256 tries,
; ~9k T) rejects and every subsequent tick would pay the same price for
; nothing. So that first failure latches the fail counter straight to
; SFX_FAIL_LIMIT and the channel is stopped after ONE cheap failed tick.
; A failure AFTER a block has been delivered is a genuine transient and
; is retried up to SFX_FAIL_LIMIT consecutive ticks.
;
; ERROR EVICTION. When the limit is reached the channel's stop is filed
; through the existing resident mailbox (audRequest bit 7, consumed at
; the top of the next aud_tick) and the cache is invalidated by clearing
; bits 2/4 and zeroing sfxKeep0. sfxHandle0 KEEPS the real handle: this
; runs in ISR context and esxDOS is mainline-only, so the refiller must
; not call F_CLOSE. sfx_stream_open's eviction step closes whatever
; handle it finds cached before it adopts a new one, so the next WAV
; load on this channel releases it - which is the same exposure the
; keep-open ruling already accepts for a stopped stream.
SFX_TICK_CAP   equ 4             ; blocks per tick, all channels
SFX_BURST_CAP  equ 2             ; blocks per channel per tick
SFX_FAIL_LIMIT equ 8             ; consecutive failed ticks -> stop

aud_sfx_refill:
 IFDEF DEBUG
    call sfx_dbg_row
 ENDIF
    ld a, (cardBusy)
    or a
    ret nz                       ; mainline owns the card this tick
    ld a, SFX_TICK_CAP
    ld (sfxTickBudget), a
    ld ix, sfxChan0
    jp sfx_chan_refill           ; Task 11 appends the sfxChan1 walk

; One channel's burst. IX = channel block (page 48, slot 6).
; Corrupts AF, BC, DE, HL; preserves IX.
sfx_chan_refill:
    ld a, (ix+SMPB_FLAGS)
    and %00010100                ; STREAMING or REWIND owed?
    ret z
    bit 4, (ix+SMPB_FLAGS)
    jr z, .cursor
    ; --- REWIND servicing (the Task 5 handoff at aud_smp_rewind_depth).
    ; A STREAMING loop rewind put the consumer back on the payload anchor
    ; and declared the window empty, because the producer had long since
    ; overwritten the payload start. Re-seek the run list to the anchor's
    ; file block, restart the producer there, and re-arm STREAMING. DEPTH
    ; is already 0; it is re-stated here so the two sides are committed
    ; together.
    call sfx_anchor_blk
    ld l, a
    ld h, 0
    push hl
    call sfx_run_seek
    pop hl
    jp c, .shortfile
    ld (sfxStagedBlk0), hl
    ld a, l                      ; window block == file block below 48,
    ld (sfxProdBlk0), a          ; and the open refuses a larger anchor
    ld (ix+SMPB_DEPTH), 0
    ld (ix+SMPB_DEPTH+1), 0
    res 4, (ix+SMPB_FLAGS)
    set 2, (ix+SMPB_FLAGS)
    xor a
    ld (sfxSeek0), a
    jr .burst
.cursor:
    ld a, (sfxSeek0)
    or a
    jr z, .burst                 ; the cursor is where the last tick left it
    ; first burst of this stream: the open staged through esxDOS, not
    ; through the run list, so the card cursor has to be seeked to the
    ; block the staging stopped at before a window may be opened.
    ld hl, (sfxStagedBlk0)
    call sfx_run_seek
    jp c, .shortfile
    ld hl, (sfxStagedBlk0)
.mod:
    ld de, SFX_WIN_BLKS          ; producer window block = staged mod 48.
    or a                         ; Bounded: the open sets STREAMING only
    sbc hl, de                   ; after staging exactly one full window,
    jr nc, .mod                  ; so this runs at most twice.
    add hl, de
    ld a, l
    ld (sfxProdBlk0), a
    xor a
    ld (sfxSeek0), a
.burst:
    ld a, SFX_BURST_CAP
    ld (sfxBurstBudget), a
.blk:
    ; window room: SMPB_DEPTH counts blocks staged and not yet finished
    ; with, so the free part of the 48-block window is SFX_WIN_BLKS-DEPTH
    ; and the write frontier is (consumer block + DEPTH) mod 48, which is
    ; what sfxProdBlk0 tracks.
    ld a, (ix+SMPB_DEPTH+1)
    or a
    jp nz, .done                 ; DEPTH never exceeds 48 - belt and braces
    ld a, (ix+SMPB_DEPTH)
    cp SFX_WIN_BLKS
    jp nc, .done                 ; window full
    ; blocks left in the FILE. F_FSTAT's ceil(size/512) is the authority:
    ; filemap runs cover whole clusters and over-report the tail.
    ld hl, (sfxFileBlk0)
    ld de, (sfxStagedBlk0)
    or a
    sbc hl, de
    jp z, .eof
    jp c, .eof
    ld a, (sfxBurstBudget)
    or a
    jp z, .done
    ld a, (sfxTickBudget)
    or a
    jp z, .done
    ; run boundary: close the window, step the run list, reopen at the
    ; next run's card address (the video producer's own shape).
    ld hl, (sfxRunBlk)
    ld a, h
    or l
    jr nz, .open
    call sfx_win_close
    call sfx_next_run
    jr c, .shortfile             ; map exhausted with blocks still owed
.open:
    call sfx_win_open            ; CMD18 at the run cursor (idempotent)
    jr c, .wirefail
    ; destination: window page list[prod >> 4], byte (prod & 15) * 512.
    ; The page NUMBER is read out of the descriptor while page 48 is
    ; still in slot 6; only then is the window page mapped over it.
    ld a, (sfxProdBlk0)
    rrca
    rrca
    rrca
    rrca
    and 3                        ; prod < 48, so prod >> 4 is 0..2
    ld l, (ix+SMPB_WINTAB)
    ld h, (ix+SMPB_WINTAB+1)
    add hl, a                    ; Z80N (doc 05)
    ld a, (hl)
    nextreg NR_MMU6, a           ; window page over slot 6 (page 48 out)
    ld a, (sfxProdBlk0)
    and 15                       ; 16 blocks per 8K page - a block never
    add a, a                     ; straddles one, so block*512 is just a
    add a, DATA_WINDOW >> 8      ; high byte
    ld h, a
    ld l, 0
    call sfx_sd_blk              ; 512 bytes + CRC skip, interrupts ON
    nextreg NR_MMU6, AUD_PAGE_LO ; page 48 back before anything reads it;
    jr c, .wirefail              ; nextreg leaves F alone, so the CF from
                                 ; sfx_sd_blk survives the restore
    ; --- credit the block on both sides
    inc (ix+SMPB_DEPTH)
    jr nz, .dhi
    inc (ix+SMPB_DEPTH+1)
.dhi:
    ld hl, (sfxStagedBlk0)
    inc hl
    ld (sfxStagedBlk0), hl
    ld hl, (sfxRunBlk)
    dec hl
    ld (sfxRunBlk), hl
    call sfx_addr_next
    ld a, (sfxProdBlk0)
    inc a
    cp SFX_WIN_BLKS
    jr c, .pok
    xor a                        ; the window is CIRCULAR
.pok:
    ld (sfxProdBlk0), a
    ld a, 1
    ld (sfxDeliv0), a            ; this stream has now delivered a block
    xor a
    ld (sfxFailCnt0), a          ; success ends any run of failed ticks
    ld hl, sfxBurstBudget
    dec (hl)
    ld hl, sfxTickBudget
    dec (hl)
 IFDEF DEBUG
    ld hl, (sfxRefillBlks0)
    inc hl
    ld (sfxRefillBlks0), hl
 ENDIF
    jp .blk
.eof:
    ; every block of the file is staged and the window holds the tail, so
    ; the refiller owes this channel nothing more: clear bit 2. Bit 3
    ; COMPLETE is NOT set - the file never fitted the window, and the
    ; documented discrimination test still finds the cached stream by
    ; sfxHandle0 != $FF. Playback ends the usual way, off SMPB_REMAIN. A
    ; loop rewind raises bit 4 and the servicing above re-arms bit 2.
    res 2, (ix+SMPB_FLAGS)
.done:
    call sfx_win_close           ; the window NEVER outlives the tick
    ret
.shortfile:
    ; the run list ran out with blocks still owed: the filemap and the
    ; F_FSTAT block count disagree (a stale map, or the file shrank).
    ; Nothing about that is retryable.
    ld a, SFX_FAIL_LIMIT
    ld (sfxFailCnt0), a
    jr .funnel
.wirefail:
    ld a, (sfxDeliv0)
    or a
    jr nz, .bump
    ld a, SFX_FAIL_LIMIT         ; first block of the stream: no raw SD
    ld (sfxFailCnt0), a          ; path here (see the header)
    jr .funnel
.bump:
    ld hl, sfxFailCnt0
    inc (hl)
.funnel:
 IFDEF DEBUG
    ld hl, sfxFails0
    inc (hl)
    jr nz, .nowrap
    dec (hl)                     ; saturate rather than wrap to 0
.nowrap:
 ENDIF
    call sfx_win_close           ; a rejected open already deselected the
                                 ; card and restored MF, and this is
                                 ; idempotent, so it cannot double-restore
    ld a, (sfxFailCnt0)
    cp SFX_FAIL_LIMIT
    ret c
    res 2, (ix+SMPB_FLAGS)       ; error eviction (see the header)
    res 4, (ix+SMPB_FLAGS)
    ld hl, audRequest
    set 7, (hl)                  ; stop sample - the existing mailbox path,
                                 ; consumed at the top of the next aud_tick
    xor a
    ld (sfxKeep0), a             ; no effect number is cached any more
    ret

; A = the file block holding this channel's payload anchor. The anchor is
; SFXW_STIDX*$2000 + SFXW_STOFF and the block is that over 512, i.e.
; STIDX*16 + STOFF>>9 - and (H:L)>>9 == H>>1 for any STOFF below $2000.
; The open refuses an anchor outside the window, so the answer is 0..47,
; which makes it the WINDOW block index as well (blocks stage verbatim
; from file offset 0 into a 48-block circular window, so window block ==
; file block mod 48, and below 48 the two are the same number).
; Reads page-48 data. Corrupts AF, DE, HL; preserves BC, IX.
sfx_anchor_blk:
    ld l, (ix+SMPB_WINTAB)
    ld h, (ix+SMPB_WINTAB+1)
    ld de, SFXW_STIDX
    add hl, de
    ld a, (hl)
    add a, a
    add a, a
    add a, a
    add a, a                     ; STIDX * 16
    inc hl
    inc hl                       ; -> SFXW_STOFF high byte
    ld e, (hl)
    srl e                        ; STOFF >> 9 (0..15)
    add a, e
    ret

; Advance the run cursor's card address by one 512-byte block.
; THE UNIT IS NOT FIXED: DISK_FILEMAP's returned flags byte carries it
; in bit 1 - clear means the card is BYTE addressed and one block is
; +512, set means it is BLOCK addressed and one block is +1. Bit 0 of
; the same byte is the card id, which is what the command helpers use to
; pick the chip select. The video player never needed this because its
; window stays open for a whole session and it only ever opens at run
; STARTS; this one closes every tick and must reopen mid-run.
; Corrupts AF, DE, HL.
sfx_addr_next:
    ld a, (sfxCardFlags)
    and 2
    ld de, 1                     ; bit 1 set: block addressing
    jr nz, .add
    ld de, 512                   ; bit 1 clear: byte addressing
.add:
    ld hl, (sfxRunAddrLo)
    add hl, de
    ld (sfxRunAddrLo), hl
    ret nc
    ld hl, (sfxRunAddrHi)
    inc hl
    ld (sfxRunAddrHi), hl
    ret

; Seek the hot run cursor so that the next block read off the card is
; file block HL: walk the run list from entry 0 skipping whole runs, then
; step the surviving run's card address over the remainder.
; CF set = the run list does not cover that block (short/stale filemap).
; Both callers seek at most SFX_WIN_BLKS blocks in - the open sets
; STREAMING only after staging exactly one window, and a payload anchor
; outside the window is refused - so the address walk below runs at most
; 48 times and the run walk at most SFX_HOT_ENT times.
; Corrupts AF, BC, DE, HL; preserves IX.
sfx_run_seek:
    ld (sfxSeekBlk), hl
    xor a
    ld (sfxRunIdx), a            ; always from the first run
.run:
    call sfx_next_run
    ret c
    ld hl, (sfxSeekBlk)
    ld de, (sfxRunBlk)
    or a
    sbc hl, de
    jr c, .inside
    ld (sfxSeekBlk), hl          ; the target lies past this whole run
    jr .run
.inside:
    ld hl, (sfxRunBlk)
    ld de, (sfxSeekBlk)
    or a
    sbc hl, de
    ld (sfxRunBlk), hl           ; blocks left from the seek position
    ld hl, (sfxSeekBlk)
.adv:
    ld a, h
    or l
    ret z                        ; CF clear from the or
    dec hl
    push hl
    call sfx_addr_next
    pop hl
    jr .adv

 IFDEF DEBUG
; SFX= report row: refilled blocks / consumer-clamp underruns / failed
; ticks, in the project's dbg_at + dbg_puts + dbg_hex idiom (the dbg_*
; helpers are resident, so they are as reachable from this page as the
; SFX FRAG marker above proves). Printed once per tick from the
; refiller's entry, and only once one of the three counters is nonzero,
; so a build that never streams keeps its screen. Every counter is
; accumulated strictly OUTSIDE the wire polls, so the instrument cannot
; distort a bounded wait. sfxUnderrun0 is page-48 data (the pump writes
; it and cannot see this page); slot 6 still holds page 48 here.
;
; CURSOR DISCIPLINE. This is the first ISR-context user of the dbg_*
; console, and dbgX/dbgY are a SHARED cursor pair: a mainline dbg_puts
; in flight when the frame ISR lands would otherwise resume wherever
; this row left the cursor (row 31, past column 71) and wrap its text
; into this row. So the pair is saved on entry and restored on exit,
; taken/put as one 16-bit access because dbgY immediately follows dbgX.
; The .show path is the only one that moves the cursor, so the save sits
; there rather than at the counter gate.
sfx_dbg_row:
    ld hl, (sfxRefillBlks0)
    ld a, h
    or l
    jr nz, .show
    ld hl, (sfxUnderrun0)
    ld a, h
    or l
    jr nz, .show
    ld a, (sfxFails0)
    or a
    ret z
.show:
    ld hl, (dbgX)                ; dbgY follows dbgX: one word is the
    push hl                      ; whole mainline cursor
    ld b, 31
    ld c, 56
    call dbg_at
    ld hl, msgSfxRow
    call dbg_puts
    ld hl, (sfxRefillBlks0)
    call dbg_hex16
    ld a, '/'
    call dbg_putc
    ld hl, (sfxUnderrun0)
    call dbg_hex16
    ld a, '/'
    call dbg_putc
    ld a, (sfxFails0)
    call dbg_hex8
    pop hl
    ld (dbgX), hl                ; mainline resumes exactly where it was
    ret
msgSfxRow: db "SFX=", 0
 ENDIF

; Seed the channels' CONSTANT block members (SP18 item 7 Task 2, moved
; here from page 48 by Task 11): ring base/mask, the resident cursor
; addresses, the CTC port, the DAC port, the window descriptor and the
; stream cell group. These never change across a start/stop cycle
; (unlike FLAGS/TABIDX/OFF/P/W/LEN/REMAIN, which aud_smp_start
; reinitialises every call) and CTCCTRL/CTCTC (which aud_smp_start
; latches from the mailbox every call), so a one-shot seed at boot is
; enough.
;
; WHY IT LIVES ON SFX_PAGE. It is cold, boot-only code - it runs once per
; (warm or cold) boot and never again - and page-48 code space is the
; binding budget of this sub-project, competed for by the per-frame pump.
; This page has thousands of bytes free. The cost is the resident
; aud_sfx_init_tramp (main.asm), needed because overlay1's aud_boot_probe
; is the only caller and overlay1 shares the slot-7 window with this page.
;
; Called with slot 6 = AUD_PAGE_LO (channel 1's block and both window
; descriptors are page-48 data) and slot 7 = SFX_PAGE. Runs with
; interrupts enabled, mainline context. Corrupts AF, BC, DE, HL, IX.
aud_sfx_init:
    ld ix, sfxChan0
    ld (ix+SMPB_RINGH), AUD_STAGE0 >> 8
    ld (ix+SMPB_RINGM), (AUD_STAGE_RING-1) >> 8
    ld hl, smpPlayPtr
    ld (ix+SMPB_PLAYPTR), l
    ld (ix+SMPB_PLAYPTR+1), h
    ld hl, smpWritePtr
    ld (ix+SMPB_WRITEPTR), l
    ld (ix+SMPB_WRITEPTR+1), h
    ld hl, AUD_CTC_PORT
    ld (ix+SMPB_CTCPORT), l
    ld (ix+SMPB_CTCPORT+1), h
    ld (ix+SMPB_DACPORT), DAC_PORT
    ld hl, sfxWin0                   ; this channel's window descriptor
    ld (ix+SMPB_WINTAB), l
    ld (ix+SMPB_WINTAB+1), h
    ld hl, sfxStrm0                  ; and its stream cell group, on this
    ld (ix+SMPB_STRM), l             ; page - every per-channel stream
    ld (ix+SMPB_STRM+1), h           ; access is made through this pointer
    ld (ix+SMPB_DEPTH), 0            ; nothing staged until a load runs
    ld (ix+SMPB_DEPTH+1), 0
    ; Withdraw the audio floor from the bank allocator, once, at boot.
    ; Banks 25-27 are the two channels' effect windows PERMANENTLY as of
    ; SP18 item 7 Task 5; before that they were a first-come floor
    ; aud_banks_claim handed to whichever audio client asked first. The
    ; AYS stream client still calls aud_banks_claim, whose floor pass
    ; takes any bank still marked BT_RESERVED - so mark all three
    ; BT_USED here and that pass finds them taken and falls through to
    ; the pool, which is exactly its own documented "already claimed by
    ; the other client: skip" path. This runs from aud_boot_probe,
    ; before the GAME.AYS probe, and bank_table_init has already reset
    ; the table by then on every (warm or cold) boot. bankTable is
    ; resident, so it is writable from this page with no mapping.
    ; THIS PIN IS THE ONLY THING KEEPING THE WINDOWS OUT OF THE
    ; ALLOCATOR: nothing may hand banks 25-27 back to BT_RESERVED or
    ; BT_FREE while the interpreter runs. aud_banks_release's old floor
    ; branch, which did exactly that, is deleted for this reason
    ; (overlay1.asm).
    ld hl, bankTable+SMP_FLOOR_FIRST
    ld b, SMP_FLOOR_LAST-SMP_FLOOR_FIRST+1
    ld a, BT_USED
.floor:
    ld (hl), a
    inc hl
    djnz .floor
    ret

; --- refiller cells (SP18 item 7 Task 6) ------------------------------
sfxSeekBlk:     dw 0             ; sfx_run_seek working block counter
sfxTickBudget:  db 0             ; blocks left this tick, all channels
sfxBurstBudget: db 0             ; blocks left this channel this tick
sfxProdBlk0:    db 0             ; window block (0-47) the producer writes
                                 ; next; equals (consumer block + DEPTH)
                                 ; mod 48 and staged mod 48, both of which
                                 ; the credit step keeps true
sfxSeek0:       db 0             ; 1 = the run cursor still has to be
                                 ; seeked to sfxStagedBlk0 (set by the
                                 ; open, whose staging bypassed the list)
sfxDeliv0:      db 0             ; 1 = this stream has delivered at least
                                 ; one block through the wire
sfxFailCnt0:    db 0             ; consecutive failed ticks

 IFDEF DEBUG
sfxRefillBlks0: dw 0             ; blocks refilled this session
sfxFails0:      db 0             ; failed ticks (saturating)
 ENDIF

; --- streaming cells (SP18 item 7 Task 3) -----------------------------
SFX_HOT_ENT   equ 8              ; same streaming ceiling as video
sfxHotMap:    ds SFX_HOT_ENT*6   ; 6-byte runs: addrLo(2) addrHi(2) blocks(2)
sfxRunIdx:    db 0
sfxRunCnt:    db 0
sfxRunAddrLo: dw 0
sfxRunAddrHi: dw 0
sfxRunBlk:    dw 0               ; blocks left in the open/current run
sfxWinOpen:   db 0
sfxCardFlags: db 0
sfxMfSave:    db 0

; --- open-ritual cells (SP18 item 7 Task 5) ---------------------------
SFX_COLD_ENT  equ 33             ; cold filemap capacity, 6 bytes/entry
                                 ; (198 B). One MORE than the 32-extent
                                 ; case, so a full buffer always means
                                 ; "33 runs or more" and never a false
                                 ; reject - the same sizing (and the same
                                 ; reasoning) as the video player's own
                                 ; filemap buffer. This buffer is the
                                 ; DISK_FILEMAP destination and so must
                                 ; sit at $4000 or above: it does, at
                                 ; $E000+, exactly as the video one does.
sfxColdMap:   ds SFX_COLD_ENT*6
sfxFstatBuf:  ds 11              ; F_FSTAT: +7 (4 bytes LE) = file size
sfxProbeByte: db 0               ; one-byte sector-cache primer target
sfxWinPg:     ds SFX_WIN_PAGES   ; window page list, snapshotted out of
                                 ; page 48 before staging borrows slot 6
sfxChanPtr:   dw 0               ; caller's channel block (IX is the
                                 ; esxDOS buffer register, so it cannot
                                 ; survive the reads)
sfxOpenNum:   db 0               ; effect number this open is for
sfxNewHandle: db 0               ; incoming handle, held across the
                                 ; stale-handle eviction
sfxPayLen:    dw 0               ; WAV data chunk size, bits 0-15 (from
sfxPayLenHi:  db 0               ; overlay1) and bits 16-23 - checked
                                 ; against the real file size, since the
                                 ; staging loop no longer reads exactly
                                 ; this many bytes
sfxDepth0:    dw 0               ; DEPTH at the anchor, on its way into
                                 ; the descriptor's SFXW_DEPTH0
sfxWhole:     db 0               ; 1 = the whole file fits the window
sfxStageLen:  dw 0               ; bytes this open stages (<= window)
sfxStageRem:  dw 0               ; staging loop: bytes still to read
sfxStgWin:    dw 0               ; staging loop: this page's byte count
sfxStgIdx:    db 0               ; staging loop: window page index

; Per-channel stream cell group. SMPB_STRM points here (seeded by
; aud_smp_chan1_init); Task 11 parameterises the accesses through it,
; which is why the group is contiguous. Task 5 has one channel, so it
; addresses these absolutely.
sfxStrm0:
sfxHandle0:    db $FF            ; open handle while STREAMING; $FF none
sfxKeep0:      db 0              ; effect number cached on this channel
sfxFileBlk0:   dw 0              ; total card blocks in the file, clamped
                                 ; to F_FSTAT's size (16 bits covers any
                                 ; file up to 32 MB; the open refuses
                                 ; anything from 16 MB up as absurd)
sfxStagedBlk0: dw 0              ; blocks staged so far (producer side)
sfxDataOff0:   dw 0              ; file offset of the first payload byte
SFX_STRM_SIZE  equ $ - sfxStrm0

 IFDEF DEBUG
; Token-poll instrument accumulators (sfx_sd_tok, above).
sfxTokPolls: dw 0
sfxTokCalls: dw 0
 ENDIF

    ASSERT $ <= OVL_ORG + $1800   ; stay inside the mapped 6K of the page
    DISPLAY "streamfx ends at ", $, " headroom ", /D, OVL_ORG + $1800 - $
