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
; BANK_POOL_B=37), so this page's sibling upper 8K, page 71, is already
; unreachable to bank_alloc with ZERO further changes to banks.asm.
; SFX_PAGE is therefore a plain equ (nextdaad.inc), this file is
; included from main.asm exactly like video.asm, and there is no boot
; pin step, no sfxPageVar cell and no bank_alloc call - the page is
; permanent from assembly time on, same as VID_PAGE2.
    MMU 7, SFX_PAGE, OVL_ORG
sfx_page_base:

; --- per-channel stream cell group (SP18 item 7 Tasks 5/6, parameterised
; by Task 11) ----------------------------------------------------------
; One group per channel, both on this page. SMPB_STRM in the channel
; block holds the group's address (seeded by aud_sfx_init), and IY holds
; it for the duration of any routine here that touches per-channel state
; - which is how one body serves both channels rather than being forked.
;
; The group has two halves. The FRONT half is the channel's own stream
; bookkeeping. The BACK half (SFXS_CTX) is its RUN CONTEXT: the hot
; filemap plus the card-side cursor. That has to be per-channel because
; the two channels stream different files, but the SD routines below are
; byte-for-byte clones of the video player's silicon-proven bodies and
; address their cells absolutely - so instead of rewriting them, the
; refiller SWAPS one channel's context into those shared working cells
; for the duration of its leg and copies it back out (sfx_ctx_load /
; sfx_ctx_save). The working cells are therefore ISR-only scratch, and
; sfx_stream_open (mainline) writes the channel's context DIRECTLY, never
; through them - which is what keeps a mainline open on one channel from
; corrupting a live refill on the other.
SFX_HOT_ENT   equ 8              ; same streaming ceiling as video
SFXS_HANDLE   equ 0              ; db: open handle while a stream is
                                 ;     cached on this channel; $FF none
SFXS_KEEP     equ 1              ; db: effect number cached here
SFXS_FILEBLK  equ 2              ; dw: total card blocks in the file,
                                 ;     from F_FSTAT (16 bits covers any
                                 ;     file up to 32 MB; the open refuses
                                 ;     anything from 16 MB up as absurd)
SFXS_STAGED   equ 4              ; dw: blocks staged so far (producer)
SFXS_DATAOFF  equ 6              ; dw: file offset of the first payload
                                 ;     byte
SFXS_PROD     equ 8              ; db: window block (0-47) the producer
                                 ;     writes next; equals (consumer
                                 ;     block + DEPTH) mod 48 and staged
                                 ;     mod 48, both of which the credit
                                 ;     step keeps true
SFXS_SEEK     equ 9              ; db: 1 = the run cursor still has to be
                                 ;     seeked to SFXS_STAGED (set by the
                                 ;     open, whose staging bypassed the
                                 ;     run list)
SFXS_DELIV    equ 10             ; db: 1 = this stream has delivered at
                                 ;     least one block through the wire
SFXS_FAILCNT  equ 11             ; db: consecutive failed ticks
 IFDEF DEBUG
SFXS_BLKS     equ 12             ; dw: blocks refilled (SFX= row)
SFXS_FAILS    equ 14             ; db: failed ticks, saturating (SFX= row)
SFXS_CTX      equ 15
 ELSE
SFXS_CTX      equ 12
 ENDIF
; Run context, laid out to match the shared working cells EXACTLY (the
; swap is one LDIR each way, so the orders must not drift; the ASSERT at
; the working cells pins it).
SFXC_MAP      equ 0                    ; ds SFX_HOT_ENT*6
SFXC_IDX      equ SFX_HOT_ENT*6        ; db
SFXC_CNT      equ SFX_HOT_ENT*6+1      ; db
SFXC_ADDRLO   equ SFX_HOT_ENT*6+2      ; dw
SFXC_ADDRHI   equ SFX_HOT_ENT*6+4      ; dw
SFXC_BLK      equ SFX_HOT_ENT*6+6      ; dw
SFXC_FLAGS    equ SFX_HOT_ENT*6+8      ; db (card id + addressing unit)
SFX_CTX_SIZE  equ SFX_HOT_ENT*6+9
SFX_STRM_SIZE equ SFXS_CTX + SFX_CTX_SIZE
    ASSERT SFXS_CTX + SFXC_FLAGS < 128  ; IY displacements are signed

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
;
; PER-CHANNEL ADDRESSING (Task 11). Every cell this routine owns lives in
; the channel's own group, reached IY-relative through SMPB_STRM - that
; is what makes one body serve both channels. Two riders:
;   - IY IS RELOADED FROM sfxCellPtr AFTER EVERY esxDOS CALL. The esxDOS
;     register contract does not promise IY back, and this path makes a
;     dozen calls. IX gets the same treatment through sfxChanPtr, for the
;     different reason that esxDOS reads IX as its buffer register.
;   - the handle is read from sfxNewHandle, not from the group, once it
;     has been adopted at .fresh: the two hold the same value from there
;     to the end, and the plain absolute read needs no live IY.
; The RUN CONTEXT (hot filemap, run cursor) is written straight into the
; channel's group here, NEVER into the shared working cells the refiller
; swaps through. That is load-bearing: this runs from mainline with
; cardBusy clear between esxDOS calls, so a frame ISR can land in the
; middle of it and refill the OTHER channel, which owns those working
; cells while it does.
sfx_stream_open:
    ld (sfxOpenNum), a
    ld (sfxChanPtr), ix
    ld (sfxPayLen), bc
    ld a, h
    ld (sfxPayLenHi), a
    ld a, l
    ld (sfxNewHandle), a
    ld l, (ix+SMPB_STRM)         ; IY = this channel's stream cell group
    ld h, (ix+SMPB_STRM+1)
    ld (sfxCellPtr), hl
    push hl
    pop iy
    ld (iy+SFXS_DATAOFF), e
    ld (iy+SFXS_DATAOFF+1), d
    ; cache eviction: a previous STREAMING open on this channel left its
    ; handle cached (one cached stream per channel). Close it before
    ; adopting the new one - esxDOS handles are a small pool and a
    ; re-trigger must not leak one per open.
    ld a, (iy+SFXS_HANDLE)
    inc a
    jr z, .fresh
    dec a
    call esx_fclose
    ld iy, (sfxCellPtr)
.fresh:
    ld a, (sfxNewHandle)
    ld (iy+SFXS_HANDLE), a
    ; --- filemap ritual, in the sector-cache ordering law's exact order:
    ; F_SEEK 0, a one-byte F_READ to prime the touched-file cache, F_SEEK
    ; 0 again, DISK_FILEMAP, and only THEN F_FSTAT. video.asm's
    ; vid_raw_setup / vid_stream_open_body are the proven template. Every
    ; esxDOS call goes through a file.asm wrapper, so cardBusy brackets
    ; the lot and the frame-ISR refiller can never overlap one.
    call sfx_seek0
    jp c, .refuse
    ld a, (sfxNewHandle)
    ld ix, sfxProbeByte
    ld bc, 1
    call esx_fread
    jp c, .refuse
    call sfx_seek0
    jp c, .refuse
    ld a, (sfxNewHandle)
    ld ix, sfxColdMap
    ld de, SFX_COLD_ENT
    call esx_filemap
    jp c, .refuse
    ld iy, (sfxCellPtr)
    ld (iy+SFXS_CTX+SFXC_FLAGS), a
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
    ld (iy+SFXS_CTX+SFXC_CNT), a
    xor a
    ld (iy+SFXS_CTX+SFXC_IDX), a
    ; the hot map is what the refiller walks: copy the runs into THIS
    ; channel's run context (never the shared working cells - see the
    ; routine header)
    ld a, b
    add a, a
    add a, b
    add a, a                     ; entries * 6 (<= 48)
    ld c, a
    ld b, 0
    push iy
    pop de
    ld hl, SFXS_CTX+SFXC_MAP
    add hl, de
    ex de, hl                    ; DE = this channel's hot filemap
    ld hl, sfxColdMap
    ldir
    ; F_FSTAT - legal only after the filemap, per the ordering law
    ld a, (sfxNewHandle)
    ld ix, sfxFstatBuf
    call esx_fstat
    jp c, .refuse
    ld iy, (sfxCellPtr)
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
    ld (iy+SFXS_FILEBLK), l
    ld (iy+SFXS_FILEBLK+1), h
    ; the consumer anchor has to land INSIDE the window: a WAV whose
    ; payload starts more than a whole window into the file (pathological
    ; leading chunks) cannot be played by a design that stages verbatim
    ; from offset 0. Refuse rather than index off the end of the list.
    ld l, (iy+SFXS_DATAOFF)
    ld h, (iy+SFXS_DATAOFF+1)
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
    ld l, (iy+SFXS_DATAOFF)
    ld h, (iy+SFXS_DATAOFF+1)
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
    ld a, (sfxNewHandle)
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
    ld iy, (sfxCellPtr)
    ; staged blocks = ceil(stagedBytes / 512) (<= SFX_WIN_BLKS)
    ld hl, (sfxStageLen)
    ld de, 511
    add hl, de
    ld l, h
    ld h, 0
    srl l                        ; HL = (stagedBytes + 511) >> 9
    ld (iy+SFXS_STAGED), l
    ld (iy+SFXS_STAGED+1), h
    ; DEPTH = staged blocks MINUS the whole blocks the consumer skips
    ; outright (its anchor sits past them - the WAV header). The block
    ; the anchor sits INSIDE is counted: it is debited when the consumer
    ; crosses the next 512 boundary, exactly like any other block. See
    ; the invariant stated in full at aud_smp_copy's debit site.
    ld e, (iy+SFXS_DATAOFF)
    ld d, (iy+SFXS_DATAOFF+1)
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
    ld (sfxDepthTmp), hl         ; banked for the loop rewind: a COMPLETE
                                 ; window is permanent, so its rewind
                                 ; restores exactly this figure (it goes
                                 ; into the descriptor below, where the
                                 ; page-48 pump can reach it)
    ; consumer cursor AND the loop-rewind anchor: window page
    ; dataOff >> 13, offset dataOff & $1FFF. Both land in the window
    ; descriptor as well as the block, because the pump rewinds to them
    ; on every loop pass, long after this page is unmapped.
    ld e, (iy+SFXS_DATAOFF)
    ld d, (iy+SFXS_DATAOFF+1)
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
    ld de, (sfxDepthTmp)         ; SFXW_DEPTH0 follows the anchor
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
    ld a, (sfxNewHandle)         ; nothing more to read: release it
    call esx_fclose
    ld iy, (sfxCellPtr)
    ld (iy+SFXS_HANDLE), $FF
    ld a, (sfxOpenNum)
    ld (iy+SFXS_KEEP), a
    ld (ix+SMPB_KEEP), a         ; arm THIS CHANNEL's free rewind: with bit
                                 ; 3 COMPLETE just set above, a repeat
                                 ; trigger of this number on this channel
                                 ; costs zero card traffic (sfx_alloc's
                                 ; own test). The block copy is what the
                                 ; allocator reads - it runs on SFX_PAGE
                                 ; but is called from overlay1, which
                                 ; cannot see SFXS_KEEP
    or a
    ret
.streaming:
    ld a, c
    or %00000100                 ; STREAMING: the refiller owes blocks
    ld (ix+SMPB_FLAGS), a
    ; hand the refiller a virgin run cursor. Staging above went through
    ; esxDOS F_READ, not the run list, so the context's run address and
    ; block count mean nothing yet: SFXS_SEEK tells the first burst to
    ; seek the list to SFXS_STAGED before it opens a window.
    ; SFXS_DELIV/SFXS_FAILCNT are this stream's failure state (see
    ; aud_sfx_refill's header).
    ld (iy+SFXS_SEEK), 1
    ld (iy+SFXS_DELIV), 0
    ld (iy+SFXS_FAILCNT), 0
    ld a, (sfxOpenNum)
    ld (iy+SFXS_KEEP), a         ; handle + hot filemap stay open as this
    ld (ix+SMPB_KEEP), a         ; channel's cached stream (spec keep-open
                                 ; ruling), for the refiller, and the
                                 ; block copy tells the allocator which
                                 ; channel to prefer for a re-trigger of
                                 ; this number.
                                 ; NOT a free rewind: bit 3 COMPLETE is
                                 ; clear on this arm, and sfx_alloc's
                                 ; free-rewind test demands both. A repeat
                                 ; trigger of this number on this channel
                                 ; takes the CACHED REWIND instead
                                 ; (sfx_stream_rewind): the handle left
                                 ; held here and the hot filemap beside it
                                 ; are exactly what lets it skip F_OPEN,
                                 ; the chunk walk, DISK_FILEMAP and
                                 ; F_FSTAT and re-stage the window alone.
                                 ; A trigger of a DIFFERENT number re-runs
                                 ; the whole open, and the eviction at
                                 ; .fresh above closes this handle first,
                                 ; so re-opening leaks nothing.
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
    ld a, (sfxNewHandle)
    inc a
    jr z, .noclose
    dec a
    call esx_fclose
.noclose:
    ld iy, (sfxCellPtr)
    ld (iy+SFXS_HANDLE), $FF
    ld (iy+SFXS_KEEP), 0
    ld ix, (sfxChanPtr)
    ld (ix+SMPB_KEEP), 0         ; nothing cached on this channel
    ld a, (ix+SMPB_FLAGS)
    and %11100011                ; the refusal funnel is one of the two
    ld (ix+SMPB_FLAGS), a        ; cache invalidations: STREAMING,
                                 ; COMPLETE and REWIND all off (bit 5
                                 ; PINNED is the allocator's and stays)
    ld (ix+SMPB_DEPTH), 0
    ld (ix+SMPB_DEPTH+1), 0
    scf
    ret

; F_SEEK the handle this open is working with to absolute offset 0. Clone
; of the video player's vid_raw_seek0 - IXL is the seek-mode byte esxDOS
; reads; L is set belt-and-braces, matching that caller's posture.
; sfxNewHandle rather than the channel's own cell so this needs no live
; IY (see sfx_stream_open's header): from .fresh onward the two hold the
; same value, and every call site is past .fresh.
sfx_seek0:
    ld bc, 0
    ld de, 0
    ld l, 0
    ld ix, 0
    ld a, (sfxNewHandle)
    jp esx_fseek

 IFDEF DEBUG
msgSfxFrag: db "SFX FRAG?", 0
 ENDIF

; ---------------------------------------------------------------------
; sfx_stream_rewind - the CACHED REWIND of a STREAMED effect (owner
; ruling, SP18 item 7 Task 12 fix).
;
; A file that fits the window is COMPLETE and its re-trigger costs
; nothing at all. A file that does NOT fit used to pay the whole open
; ritual again on every trigger - F_OPEN, the RIFF/fmt/data chunk walk,
; F_SEEK, the priming read, F_SEEK, DISK_FILEMAP, F_FSTAT - even though
; the channel was still holding the handle and the hot filemap of that
; exact file. The spec's cached-rewind says it should not: reuse what is
; held and pay only the window re-staging.
;
; That is what this entry does. It skips every one of those calls and
; rejoins the ordinary open at its staging loop, so the staging itself,
; the depth arithmetic, the consumer anchor, the window descriptor write
; and the STREAMING commit are the SAME CODE, not a copy.
;
; VALIDITY - the test, stated. sfx_alloc decides it, because it is
; already walking both channels' blocks: the effect number must equal
; the candidate channel's SMPB_KEEP, the channel must NOT be COMPLETE
; (that case has its own, cheaper free rewind), and SFXS_HANDLE must not
; be $FF. That last one is the whole condition, and it is sufficient
; rather than merely suggestive:
;   - only sfx_stream_open's .streaming arm leaves a handle held; the
;     COMPLETE arm closes it and writes $FF, and so does the refusal
;     funnel. So a held handle means "this channel is carrying a cached
;     STREAM", which in turn means the file exceeded the window;
;   - the hot filemap and the run cursor live in the same channel's
;     SFXS_CTX and are only ever rewritten by an open ON THIS CHANNEL or
;     by this channel's own refiller leg, so a held handle and a matching
;     SMPB_KEEP mean the cached map belongs to the cached file;
;   - the refiller's error eviction clears SMPB_KEEP (leaving the handle
;     held for the funnel to close later), so an evicted stream fails the
;     number test and takes the full open, which closes the stale handle
;     at .fresh.
; SFXS_FILEBLK and SFXS_DATAOFF are likewise still the cached file's, so
; neither F_FSTAT nor the chunk walk has anything to re-establish.
;
; STAGING RESTARTS AT FILE OFFSET 0, not at the payload: blocks stage
; VERBATIM from 0 in this design (the WAV header stages with the payload
; and the CONSUMER skips it, see sfx_stream_open's header), so "the start
; of payload staging" is offset 0 and sfx_seek0 is exactly the right
; seek. The consumer's anchor is rebuilt from SFXS_DATAOFF by the shared
; tail, as on a fresh open.
;
; The caller must have STOPPED THIS CHANNEL AND WAITED, exactly as
; aud_load_wav does before a fresh stage - h_sfx calls sfx_stop_wait
; first. That is not politeness: the re-stage overwrites the window the
; pump is reading, and the stop is also what shuts sfx_chan_refill's gate
; (aud_smp_stop clears bit 2 STREAMING) for the whole of the staging,
; which is only re-raised at .streaming after the last write.
;
; In:  A bit 0 = channel index (0 = channel 1). Slot 6 = AUD_PAGE_LO,
;      slot 7 = SFX_PAGE, mainline.
; Out: CF clear = window re-staged and STREAMING re-armed; the caller
;      files its normal start, and the refiller carries on from
;      SFXS_STAGED (SFXS_SEEK = 1 makes its first burst re-seek the run
;      cursor there through sfx_run_seek).
;      CF set = the re-stage failed. The refusal funnel has already
;      closed the handle and invalidated both keep cells, so THE CALLER
;      MUST RETRY THE FULL OPEN ONCE and only fall back to the AY effect
;      if that fails too - a card hiccup on the cached path must not cost
;      the effect. h_sfx implements exactly that retry shape.
; Corrupts everything.
sfx_stream_rewind:
    rrca                             ; bit 0 -> CF
    ld ix, sfxChan0
    jr nc, .chosen
    ld ix, sfxChan1
.chosen:
    ld (sfxChanPtr), ix
    ld l, (ix+SMPB_STRM)
    ld h, (ix+SMPB_STRM+1)
    ld (sfxCellPtr), hl
    push hl
    pop iy
    ld a, (iy+SFXS_HANDLE)
    ld (sfxNewHandle), a             ; THE HELD HANDLE - no F_OPEN, and
                                     ; sfx_seek0 and the staging loop both
                                     ; read it from here, so they need no
                                     ; change at all
    ld a, (ix+SMPB_KEEP)
    ld (sfxOpenNum), a               ; the same number the tail re-writes
                                     ; into both keep cells
    ld hl, SFX_WIN_BYTES             ; a cached stream is over the window
    xor a                            ; by definition, so the stage length
                                     ; is the full window and sfxWhole is
                                     ; 0 - the .partial arm's own constants
    jp sfx_stream_open.setstage

; aud_ctc_params: DE = sample rate (validated AUD_RATE_MIN..MAX). Derives the
; CTC control word (audReqSmpCtrl) and time constant (audReqSmpTc) for the rate
; at the LIVE video-timing mode. The CTC input clock IS the FPGA system clock,
; 27-33 MHz by video mode (nextreg $11 bits 2:0), so a fixed constant would
; drift pitch across VGA/HDMI - aud_clk16_tab holds clock/16 per mode (like
; em00k CTCAudio's table). Prescaler /16 for rate >= clk16>>8 (the PER-MODE
; crossover where the /16 TC would reach 256); else /256 (TC = (clk16>>4)/rate).
; TC is floored and clamped to 255 (the boundary rate that divides to 256 lands
; on 255, a <0.5% nudge); residual error is <= one TC step, largest at low rates
; on fast clocks (see the hardware checklist). Corrupts AF,BC,HL; preserves DE.
;
; MOVED HERE FROM OVERLAY1 (2026-08-10 fresh-TC ruling). Two callers: this
; page's own sfx_alloc (.hit, below - a plain same-page call, no hop needed)
; and overlay1's aud_load_wav, which reaches it through the resident
; sfx_page_call trampoline exactly as it reaches sfx_stream_open. Moving
; here rather than duplicating kept ONE derivation: overlay1 was the
; tightest code pool this sub-project touches and this page has thousands
; of bytes free, and a rewind re-commit runs with SFX_PAGE already mapped
; in slot 7 (sfx_alloc's own precondition), so a nested hop back out to
; overlay1 just to reach this would have been the ugly option.
aud_ctc_params:
    push de                     ; save the rate; nr_read takes the reg in E
    ld e, NR_VIDEO_TIMING
    call nr_read                ; A = nextreg $11 (IFF-preserving)
    and $07                     ; video timing mode 0-7 (7 = HDMI)
    ld l, a
    add a, a
    add a, l                    ; A = mode * 3 (3 bytes per clk16 entry)
    ld l, a
    ld h, 0
    ld bc, aud_clk16_tab
    add hl, bc                  ; HL -> clk16[mode] (24-bit little-endian)
    ld a, (hl)                  ; byte0 (low)
    inc hl
    ld b, (hl)                  ; byte1 (mid)
    inc hl
    ld c, (hl)                  ; byte2 (high) -> C = dividend high
    ld h, b
    ld l, a                     ; HL = clk16 low 16 bits; C:HL = clk16 (24-bit)
    pop de                      ; DE = rate
    ; per-mode crossover = clk16 >> 8 (the rate at which the /16 TC reaches 256).
    ; A fixed constant only holds for VGA0; on faster clocks (up to VGA6 33 MHz)
    ; a 6836 crossover would leave a band where /16 TC overflows 255 and clamps
    ; sharply (+18% on VGA6). clk16 is in C:HL, so clk16 >> 8 = C:H.
    push hl                     ; protect clk16 low word (restored after the test)
    ld l, h
    ld h, c                     ; HL = C:H = clk16 >> 8 = crossover
    or a
    sbc hl, de                  ; crossover - rate: CF (borrow) when rate > crossover
    pop hl                      ; restore clk16 low16 (C:HL = clk16 again)
    jr c, .p16                  ; rate > crossover -> /16
    jr z, .p16                  ; rate == crossover -> /16 (TC 256 -> clamps to 255)
    ld a, AUD_CTC_CW256         ; /256: control word + dividend = clk16 >> 4
    ld (audReqSmpCtrl), a
    srl c                       ; clk16 >> 4 (24-bit C:HL), four right shifts
    rr h
    rr l
    srl c
    rr h
    rr l
    srl c
    rr h
    rr l
    srl c
    rr h
    rr l
    jr .divide
.p16:
    ld a, AUD_CTC_CW16
    ld (audReqSmpCtrl), a
.divide:
    ; TC = C:HL / DE (floor, clamp 255). 24-bit repeated subtraction, B counts.
    ld b, 0
.sub:
    or a
    sbc hl, de
    jr nc, .ok
    dec c
    bit 7, c                    ; borrowed past zero: dividend exhausted
    jr nz, .done
.ok:
    inc b
    jr nz, .sub
    ld b, 255                   ; 256 rounds (rate 6836 only): clamp to 255
.done:
    ld a, b
    ld (audReqSmpTc), a
    ret

; clock/16 per video-timing mode (nextreg $11 bits 2:0), 24-bit little-endian.
; System clock from the Next hardware / em00k CTCAudio table; /16 folds the
; prescaler in so the /16-prescaler divide is a plain clk16/rate (and /256 is
; clk16>>4 / rate). VGA1/VGA2 clocks are non-integer/16 - floored here, matching
; em00k's own inexact entries for those two modes.
aud_clk16_tab:
    db $F0,$B3,$1A              ; VGA0 28000000/16 = 1750000
    db $72,$3F,$1B              ; VGA1 28571429/16 = 1785714
    db $6D,$19,$1C              ; VGA2 29464286/16 = 1841517
    db $38,$9C,$1C              ; VGA3 30000000/16 = 1875000
    db $8C,$90,$1D              ; VGA4 31000000/16 = 1937500
    db $80,$84,$1E              ; VGA5 32000000/16 = 2000000
    db $A4,$78,$1F              ; VGA6 33000000/16 = 2062500
    db $CC,$BF,$19              ; HDMI 27000000/16 = 1687500

; ---------------------------------------------------------------------
; THE CHANNEL ALLOCATOR (SP18 item 7 Task 12)
;
; One entry point serves every channel decision the SFX condact makes:
; picking a channel for a play trigger (subs 1/2 auto, 11-14 pinned) and
; releasing a pin (subs 15/16 and 5). It lives HERE rather than in
; overlay1 for space - overlay1 is the tightest code pool this
; sub-project touches and this page has thousands of bytes free - and it
; can live here because everything it reads is either page-48 data
; (sfxChan0, in slot 6 for the whole call) or resident (sfxChan1, the
; mailbox parameter cells, frameCounter). overlay1 reaches it through
; sfx_page_call (main.asm, resident), because overlay1 and this page
; share the slot-7 window.
;
; In:  A = request. 0 = auto-allocate, 1 = pin channel 1, 2 = pin
;          channel 2, 3 = unpin channel 1, 4 = unpin channel 2,
;          5 = unpin both.
;      B = effect number (1-254), for the play requests.
; Out: CF set   = the trigger is DROPPED. Both channels are pinned by
;                 the other subs and auto-allocation may not touch
;                 either, so there is nowhere to put this effect. A
;                 DEBUG marker says so; the condact is a no-op.
;      CF clear = allocated (or unpinned). A bit 0 = the channel index
;                 (0 = channel 1, 1 = channel 2), plus at most one of:
;                 bit 7 = FREE REWIND - that channel's window already
;                   holds this exact effect WHOLE (COMPLETE). No card
;                   traffic at all: the caller must NOT call
;                   aud_load_wav, it just files the start.
;                 bit 6 = CACHED REWIND - that channel is still holding
;                   the handle and hot filemap of this exact STREAMED
;                   file. The caller calls sfx_stream_rewind instead of
;                   aud_load_wav: no F_OPEN, no chunk walk, no
;                   DISK_FILEMAP, no F_FSTAT, only the window re-stage.
;                 On BOTH of those the shared audReqSmp* start parameters
;                 have already been re-committed here from the channel's
;                 own latches. Neither bit set = the ordinary full open.
; Preserves B. Corrupts AF, C, DE, HL, IX.
; Preconditions: slot 6 = AUD_PAGE_LO, slot 7 = SFX_PAGE, mainline
; context (it takes no interrupt-sensitive action and does not halt).
;
; THE DECISION TREE, in order:
;   explicit (subs 11-14) - the named channel, always, whatever is
;     playing on it and whether or not it is already pinned. The pin is
;     set here; from now on auto-allocation may not touch that channel.
;   auto (subs 1/2)
;     (a) a channel that already CACHES this effect number and is not
;         pinned. Cheapest possible outcome: a free rewind (COMPLETE) or
;         a cached rewind (a held stream), and at worst a re-open that
;         evicts nothing else.
;     (b) an IDLE, unpinned channel (SMPB_FLAGS bit 0 clear). A pinned
;         channel is skipped EVEN WHEN IDLE - the pin is a reservation,
;         not a busy flag (owner ruling).
;     (c) STEAL an unpinned ACTIVE channel: a ONE-SHOT (bit 1 clear)
;         before a LOOP, and between two of the same kind the one whose
;         SMPB_STAMP is oldest.
;     (d) nothing left - drop, with the DEBUG marker.
; Channel 1 is the fixed preference at every tie in (a) and (b).
;
; STEALING AND THE MAILBOX. Nothing is filed here. The caller stops the
; victim through aud_load_wav, which files the chosen channel's stop bit
; and HALT-WAITS for it to be consumed before a single byte is staged -
; so the victim's playback is provably over before its window is
; overwritten, and its stop and the new start land in different frames.
; A same-tick stop-then-start on ONE channel would be legal anyway
; (aud_tick consumes audRequest2 bit 2 before bit 3 and audRequest bit 7
; before bit 6, all in one pass - see aud_tick's header), but no path
; here relies on it.
sfx_alloc:
    ld c, b                          ; C = effect number; B is the
                                     ; caller's and must survive (its AY
                                     ; fallback still needs it)
    cp 3
    jp nc, .unpin
    or a
    jp nz, .explicit
    ; ---- (a) a channel that already caches this number ---------------
    ld ix, sfxChan0
    ld e, 0
    call .cached
    jp z, .take
    ld ix, sfxChan1
    inc e
    call .cached
    jp z, .take
    ; ---- (b) an idle, unpinned channel -------------------------------
    ld ix, sfxChan0
    ld e, 0
    call .idle
    jp z, .take
    ld ix, sfxChan1
    inc e
    call .idle
    jp z, .take
    ; ---- (c) steal ---------------------------------------------------
    ld d, 0                          ; D = the stealable mask
    ld ix, sfxChan0
    call .victim
    jr nz, .nv0
    inc d
.nv0:
    ld ix, sfxChan1
    call .victim
    jr nz, .nv1
    set 1, d
.nv1:
    ld a, d
    dec a
    jr z, .take0                     ; mask 1: only channel 1
    dec a
    jr z, .take1                     ; mask 2: only channel 2
    dec a
    jp nz, .drop                     ; mask 0: both pinned - dropped
    ; both stealable: a one-shot goes before a loop
    ld a, (sfxChan0+SMPB_FLAGS)
    and %00000010
    ld e, a
    ld a, (sfxChan1+SMPB_FLAGS)
    and %00000010
    cp e
    jr z, .oldest
    or a
    jr z, .take1                     ; channel 2 is the one-shot
    jr .take0
.oldest:
    ; age = frameCounter - stamp, unsigned, so the 16-bit wrap is
    ; handled by the subtraction itself. Bigger age = older = victim.
    ld hl, (frameCounter)
    ld de, (sfxChan0+SMPB_STAMP)
    or a
    sbc hl, de
    push hl
    ld hl, (frameCounter)
    ld de, (sfxChan1+SMPB_STAMP)
    or a
    sbc hl, de
    pop de                           ; DE = channel 1's age
    or a
    sbc hl, de                       ; channel 2's age - channel 1's
    jr c, .take0                     ; channel 2 is the younger, so
                                     ; channel 1 is the older victim
.take1:
    ld ix, sfxChan1
    ld e, 1
    jr .take
.take0:
    ld ix, sfxChan0
    ld e, 0
    jr .take
    ; ---- explicit pin (subs 11-14) -----------------------------------
.explicit:
    dec a                            ; 0 = channel 1, 1 = channel 2
    ld e, a
    ld ix, sfxChan0
    jr z, .expin
    ld ix, sfxChan1
.expin:
    set 5, (ix+SMPB_FLAGS)           ; the reservation. An explicit pin
                                     ; always takes its channel, so there
                                     ; is nothing to test first
    ; ---- commit: IX = the chosen block, E = its index ----------------
    ; Three outcomes, cheapest first. The number must match either way -
    ; a different effect always takes the full open, which evicts.
.take:
    ld a, (ix+SMPB_KEEP)
    cp c
    jr nz, .fresh
    ld a, (ix+SMPB_FLAGS)
    and %00001000                    ; COMPLETE: the whole effect is
    ld a, $80                        ; already in this channel's window -
    jr nz, .hit                      ; a FREE REWIND, no card traffic
    ; not COMPLETE, but the number matches: this channel may still be
    ; holding the handle and hot filemap of that same file from a
    ; STREAMING open. SFXS_HANDLE is $FF unless it is (the COMPLETE arm
    ; and the refusal funnel both write $FF), so one test settles it -
    ; the full validity argument is at sfx_stream_rewind's header.
    ld l, (ix+SMPB_STRM)
    ld h, (ix+SMPB_STRM+1)
    ld a, (hl)                       ; SFXS_HANDLE is offset 0
    inc a
    jr z, .fresh                     ; $FF: nothing held, full open
    ld a, $40                        ; a CACHED REWIND: re-stage only
.hit:
    ld d, a                          ; the verdict bit survives the call
                                     ; and the parameter copy below
    ; Reached by BOTH rewind verdicts, and both need this. The audReqSmp*
    ; start parameters are SHARED by the two channels (aud_tick's header
    ; states the limitation), so the values standing in them may be the
    ; OTHER channel's last load. aud_load_wav is what would ordinarily
    ; re-commit them, and neither rewind goes through it - the free one
    ; touches nothing at all, the cached one enters the staging tail past
    ; the point where aud_ctc_params would have run. So re-commit here -
    ; but from this channel's OWN RATE (SMPB_RATE, aud_smp_start's own
    ; latch), re-derived through aud_ctc_params against the LIVE video
    ; mode, not by replaying the SMPB_CTCCTRL/CTCTC snapshot the effect's
    ; last start left behind (owner ruling 2026-08-10): a video-mode
    ; change between two triggers of the same effect must not replay at
    ; the old pitch. aud_ctc_params corrupts AF,BC,HL and preserves DE -
    ; B is the caller's effect number (sfx_alloc's own contract preserves
    ; it) and D/E are this verdict and the channel index, both still
    ; needed below, so all three are banked across the call.
    push bc
    push de
    ld e, (ix+SMPB_RATE)
    ld d, (ix+SMPB_RATE+1)
    call aud_ctc_params               ; sets audReqSmpCtrl + audReqSmpTc
    ld (audReqSmpRate), de            ; close the SAME round trip SMPB_LEN
                                       ; closes 3 lines below: aud_smp_start
                                       ; latches the MAILBOX's rate into
                                       ; SMPB_RATE unconditionally on every
                                       ; start (its own tail, symmetric with
                                       ; Ctrl/Tc), so leaving the mailbox
                                       ; holding a DIFFERENT channel's rate
                                       ; here would corrupt THIS channel's
                                       ; SMPB_RATE on the very start this
                                       ; re-commit is about to cause - DE
                                       ; still holds this channel's own rate
                                       ; (aud_ctc_params preserves DE)
    pop de
    pop bc
    ld a, (ix+SMPB_LEN)
    ld (audReqSmpLen), a
    ld a, (ix+SMPB_LEN+1)
    ld (audReqSmpLen+1), a
    ld a, (ix+SMPB_LEN+2)
    ld (audReqSmpLenHi), a
    ld a, d                          ; $80 free rewind / $40 cached rewind
    or e                             ; also clears CF
    ret
.fresh:
    ld a, e                          ; A = index, CF clear (ld sets none,
    or a                             ; but be explicit - the caller reads
    ret                              ; CF as the drop verdict)
.drop:
 IFDEF DEBUG
    ; inline marker, same idiom as .frag above and h_sfx's unknown
    ; sub-command block. B is the caller's effect number and is clobbered
    ; here, which is safe on exactly this path: a dropped trigger returns
    ; from h_sfx without reading it again.
    ld b, 30
    ld c, 50
    call dbg_at
    ld hl, msgSfxBusy
    call dbg_puts
 ENDIF
    scf
    ret
    ; ---- pin release (subs 15/16 and 5) ------------------------------
.unpin:
    sub 2                            ; 1 = channel 1, 2 = channel 2,
    ld e, a                          ; 3 = both
    bit 0, e
    jr z, .unp2
    ld hl, sfxChan0+SMPB_FLAGS
    res 5, (hl)
.unp2:
    bit 1, e
    jr z, .unpd
    ld hl, sfxChan1+SMPB_FLAGS
    res 5, (hl)
.unpd:
    or a                             ; A is the non-zero mask, so this
    ret                              ; clears CF: not a drop
; Z = this channel caches effect C and is not pinned. SMPB_KEEP 0 means
; "nothing cached" and effect numbers start at 1, so no special case.
.cached:
    ld a, (ix+SMPB_FLAGS)
    and %00100000
    ret nz
    ld a, (ix+SMPB_KEEP)
    cp c
    ret
; Z = this channel is ACTIVE and not pinned (a stealable victim).
.victim:
    call .idle
    dec a
    ret
; Z = this channel is idle and not pinned.
.idle:
    ld a, (ix+SMPB_FLAGS)
    and %00100001
    ret

 IFDEF DEBUG
msgSfxBusy: db "SFX BUSY?", 0
 ENDIF

; ---------------------------------------------------------------------
; sfx_vid_resume - THE VIDEO AUTO-RESUME (owner ruling, 2026-08-10).
;
; A LOOPING sampled effect comes back BY ITSELF when a cutscene ends; a
; one-shot stays stopped. vid_run_entry_body aborts both channels before
; the clip starts (stop bits filed and waited, cache kept) and the
; teardown used to leave them idle, so the author had to re-trigger by
; hand. video.asm captures which channels were looping before the abort
; clears bits 0/1 and hops here with the mask once teardown is over.
;
; THE RESTART IS THE ORDINARY RE-TRIGGER LADDER, not a copy of it: the
; allocator re-commits this channel's own start parameters from its
; latches, a COMPLETE window rewinds for free and a cached STREAM
; re-stages through sfx_stream_rewind - exactly what h_sfx does for a
; repeat trigger of the same number on the same channel.
;
; ONE CHANNEL PER TICK, DELIBERATELY. The per-channel re-commit does NOT
; make the two channels independent within a tick: sfx_alloc reads this
; channel's SMPB_RATE/LEN, derives Ctrl/Tc fresh through aud_ctc_params
; against the LIVE video mode, and writes all four into
; audReqSmpRate/Ctrl/Tc/Len/LenHi, which are SHARED (aud_tick's own header
; states the limitation). A second alloc before the first start had been
; consumed would therefore hand channel 1's start channel 2's rate and
; length. The drain below is h_sfx's own .pend rule and is what puts the
; two restarts in different ticks.
;
; THE PIN IS NOT A SIDE EFFECT. Allocator requests 1/2 name a channel and
; set SMPB_FLAGS bit 5 in doing so; a bed that was not pinned before the
; video must not come back pinned, so the bit is put back exactly as the
; video found it. A bed that WAS pinned resumes still pinned.
;
; A cached STREAM whose re-stage FAILS is left stopped. h_sfx retries the
; full open at that point, but aud_load_wav is overlay1 code and overlay1
; shares the slot-7 window with this page, so the honest answer here is
; to drop the resume rather than fake a retry. The refusal funnel has
; already invalidated the cache, so the author's next trigger of that
; number takes the full open and plays normally.
;
; In:  D = mask, bit 0 = channel 1, bit 1 = channel 2 - the channels that
;      were ACTIVE and LOOPING when vid_run captured them. Mainline,
;      interrupts on, slot 7 = SFX_PAGE (video.asm's .restore_tail hopped
;      here), any slot 6, card free.
; Out: plain ret - to the condact dispatcher, in the video's place.
;      Corrupts everything.
; ---------------------------------------------------------------------
sfx_vid_resume:
    ld a, (audEnable)
    or a
    ret z                            ; the tick is frozen: a start would
                                     ; never be consumed and the drain
                                     ; below would never end
    ld a, d
    ld (sfxResMask), a               ; sfx_alloc corrupts DE
    call data_save
    ld a, AUD_PAGE_LO                ; channel 1's block and both window
    call data_map_page               ; descriptors are page-48 data
    ld a, (sfxResMask)
    rrca                             ; channel 1's bit -> CF
    ld e, 0                          ; (ld writes no flag)
    call c, .chan
    ld a, (sfxResMask)
    rrca
    rrca                             ; channel 2's bit -> CF
    ld e, 1
    call c, .chan
    jp data_restore

; One channel. E = channel index (0 = channel 1), preserved.
.chan:
    call .block                      ; IX = this channel's block
    ld b, (ix+SMPB_KEEP)             ; the number its window holds
    ld a, b
    or a
    ret z                            ; nothing cached (a refiller error
                                     ; eviction clears it): nothing to
                                     ; resume
    ld a, (ix+SMPB_FLAGS)
    and %00100000
    ld (sfxResPin), a                ; the pin, as the video found it
    ; drain a start not yet consumed before sfx_alloc re-commits the
    ; shared parameter cells (the one-channel-per-tick rule above)
.pend:
    ld a, (audRequest)
    and %01000000
    ld c, a
    ld a, (audRequest2)
    and %00001000
    or c
    jr z, .go
    halt
    jr .pend
.go:
    ld a, 1
    ld (audReqSmpLoop), a            ; a resume is always a loop resume
    ld a, e
    inc a                            ; request 1/2: THIS channel, named -
    push de                          ; auto-allocation could pick the
    call sfx_alloc                   ; other one, or the same one twice
    pop de
    ld c, a                          ; bit 7 free rewind / bit 6 cached
    call .block
    ld a, (sfxResPin)
    or a
    jr nz, .pinned
    res 5, (ix+SMPB_FLAGS)
.pinned:
    bit 7, c
    jr nz, .file                     ; COMPLETE: free rewind, no card
    bit 6, c
    ret z                            ; neither: the cache is gone and the
                                     ; full open is out of reach (header)
    ld a, e                          ; a cached STREAM: re-stage the
    push de                          ; window from the held handle and
    call sfx_stream_rewind           ; hot filemap
    pop de
    ret c                            ; re-stage failed - left stopped
.file:
    bit 0, e
    jr nz, .file2
    ld hl, audRequest
    set 6, (hl)                      ; channel 1's start
    ret
.file2:
    ld hl, audRequest2
    set 3, (hl)                      ; channel 2's start, the mirror
    ret
; IX = the block E names. Corrupts AF, IX.
.block:
    ld ix, sfxChan0
    bit 0, e
    ret z
    ld ix, sfxChan1
    ret

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
; through the existing resident mailbox (channel 1: audRequest bit 7;
; channel 2: audRequest2 bit 2 - both consumed at the top of the next
; aud_tick) and the cache is invalidated by clearing bits 2/4 and zeroing
; SFXS_KEEP. SFXS_HANDLE KEEPS the real handle: this
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
    ld (sfxTickBudget), a        ; ONE budget for both channels; the
    ld ix, sfxChan0              ; per-channel SFX_BURST_CAP is re-armed
    call sfx_chan_refill         ; inside each leg. Channel 1 is served
    ld ix, sfxChan1              ; FIRST, so on a tick where the shared
    jp sfx_chan_refill           ; budget runs out it is channel 2 that
                                 ; waits - a fixed, stated priority
                                 ; rather than an emergent one

; One channel's leg. IX = channel block (sfxChan0 is page-48 data in
; slot 6, sfxChan1 is resident; both are reached IX-relative, so neither
; placement matters here).
;
; The gate is tested BEFORE the run context is swapped in, so an idle or
; COMPLETE channel costs three instructions and no copying. Everything
; past the gate runs with IY = this channel's stream cell group and its
; run context in the shared working cells; sfx_ctx_save on the way out is
; unconditional, which is why the body's every exit is a plain ret.
; Corrupts AF, BC, DE, HL, IY; preserves IX.
sfx_chan_refill:
    ld a, (ix+SMPB_FLAGS)
    and %00010100                ; STREAMING or REWIND owed?
    ret z
    ld l, (ix+SMPB_STRM)         ; IY = this channel's stream cell group
    ld h, (ix+SMPB_STRM+1)
    push hl
    pop iy
    call sfx_ctx_load
    call sfx_chan_body
    ; fall through to sfx_ctx_save

; The run-context swap. sfx_ctx_load copies this channel's saved context
; (hot filemap + card cursor) into the shared working cells the SD clones
; address absolutely; sfx_ctx_save copies whatever the leg left there
; back. The two layouts are identical by construction (the SFXC_* block
; at the top of this file, ASSERTed against the working cells), so each
; direction is one LDIR - 57 bytes, about 1.2k T. A tick in which BOTH
; channels are streaming therefore pays four of them, under 5k T, which
; is well inside 1% of a 28 MHz frame; a tick in which neither is pays
; none, because the gate is upstream.
; Corrupts AF, BC, DE, HL; preserves IX, IY.
sfx_ctx_save:
    push iy
    pop de
    ld hl, SFXS_CTX
    add hl, de
    ex de, hl                    ; DE = this channel's saved context
    ld hl, sfxHotMap
    ld bc, SFX_CTX_SIZE
    ldir
    ret
sfx_ctx_load:
    push iy
    pop hl
    ld de, SFXS_CTX
    add hl, de                   ; HL = this channel's saved context
    ld de, sfxHotMap
    ld bc, SFX_CTX_SIZE
    ldir
    ret

; The body of one channel's leg. IX = channel block, IY = stream cell
; group, run context already in the shared working cells.
; Corrupts AF, BC, DE, HL; preserves IX, IY.
sfx_chan_body:
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
    ld (iy+SFXS_STAGED), l
    ld (iy+SFXS_STAGED+1), h
    ld (iy+SFXS_PROD), l         ; window block == file block below 48,
                                 ; and the open refuses a larger anchor
    ld (ix+SMPB_DEPTH), 0
    ld (ix+SMPB_DEPTH+1), 0
    res 4, (ix+SMPB_FLAGS)
    set 2, (ix+SMPB_FLAGS)
    ld (iy+SFXS_SEEK), 0
    jr .burst
.cursor:
    ld a, (iy+SFXS_SEEK)
    or a
    jr z, .burst                 ; the cursor is where the last tick left it
    ; first burst of this stream: the open staged through esxDOS, not
    ; through the run list, so the card cursor has to be seeked to the
    ; block the staging stopped at before a window may be opened.
    ld l, (iy+SFXS_STAGED)
    ld h, (iy+SFXS_STAGED+1)
    call sfx_run_seek
    jp c, .shortfile
    ld l, (iy+SFXS_STAGED)
    ld h, (iy+SFXS_STAGED+1)
.mod:
    ld de, SFX_WIN_BLKS          ; producer window block = staged mod 48.
    or a                         ; Bounded: the open sets STREAMING only
    sbc hl, de                   ; after staging exactly one full window,
    jr nc, .mod                  ; so this runs at most twice.
    add hl, de
    ld (iy+SFXS_PROD), l
    ld (iy+SFXS_SEEK), 0
.burst:
    ld a, SFX_BURST_CAP
    ld (sfxBurstBudget), a
.blk:
    ; window room: SMPB_DEPTH counts blocks staged and not yet finished
    ; with, so the free part of the 48-block window is SFX_WIN_BLKS-DEPTH
    ; and the write frontier is (consumer block + DEPTH) mod 48, which is
    ; what SFXS_PROD tracks.
    ld a, (ix+SMPB_DEPTH+1)
    or a
    jp nz, .done                 ; DEPTH never exceeds 48 - belt and braces
    ld a, (ix+SMPB_DEPTH)
    cp SFX_WIN_BLKS
    jp nc, .done                 ; window full
    ; blocks left in the FILE. F_FSTAT's ceil(size/512) is the authority:
    ; filemap runs cover whole clusters and over-report the tail.
    ld l, (iy+SFXS_FILEBLK)
    ld h, (iy+SFXS_FILEBLK+1)
    ld e, (iy+SFXS_STAGED)
    ld d, (iy+SFXS_STAGED+1)
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
    jp c, .shortfile             ; map exhausted with blocks still owed
.open:
    call sfx_win_open            ; CMD18 at the run cursor (idempotent)
    jp c, .wirefail
    ; destination: window page list[prod >> 4], byte (prod & 15) * 512.
    ; The page NUMBER is read out of the descriptor while page 48 is
    ; still in slot 6; only then is the window page mapped over it.
    ld a, (iy+SFXS_PROD)
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
    ld a, (iy+SFXS_PROD)
    and 15                       ; 16 blocks per 8K page - a block never
    add a, a                     ; straddles one, so block*512 is just a
    add a, DATA_WINDOW >> 8      ; high byte
    ld h, a
    ld l, 0
    call sfx_sd_blk              ; 512 bytes + CRC skip, interrupts ON
    nextreg NR_MMU6, AUD_PAGE_LO ; page 48 back before anything reads it;
    jp c, .wirefail              ; nextreg leaves F alone, so the CF from
                                 ; sfx_sd_blk survives the restore
    ; --- credit the block on both sides
    inc (ix+SMPB_DEPTH)
    jr nz, .dhi
    inc (ix+SMPB_DEPTH+1)
.dhi:
    ld l, (iy+SFXS_STAGED)
    ld h, (iy+SFXS_STAGED+1)
    inc hl
    ld (iy+SFXS_STAGED), l
    ld (iy+SFXS_STAGED+1), h
    ld hl, (sfxRunBlk)
    dec hl
    ld (sfxRunBlk), hl
    call sfx_addr_next
    ld a, (iy+SFXS_PROD)
    inc a
    cp SFX_WIN_BLKS
    jr c, .pok
    xor a                        ; the window is CIRCULAR
.pok:
    ld (iy+SFXS_PROD), a
    ld (iy+SFXS_DELIV), 1        ; this stream has now delivered a block
    ld (iy+SFXS_FAILCNT), 0      ; success ends any run of failed ticks
    ld hl, sfxBurstBudget
    dec (hl)
    ld hl, sfxTickBudget
    dec (hl)
 IFDEF DEBUG
    ld l, (iy+SFXS_BLKS)
    ld h, (iy+SFXS_BLKS+1)
    inc hl
    ld (iy+SFXS_BLKS), l
    ld (iy+SFXS_BLKS+1), h
 ENDIF
    jp .blk
.eof:
    ; every block of the file is staged and the window holds the tail, so
    ; the refiller owes this channel nothing more: clear bit 2. Bit 3
    ; COMPLETE is NOT set - the file never fitted the window, and the
    ; documented discrimination test still finds the cached stream by
    ; SFXS_HANDLE != $FF. Playback ends the usual way, off SMPB_REMAIN. A
    ; loop rewind raises bit 4 and the servicing above re-arms bit 2.
    res 2, (ix+SMPB_FLAGS)
.done:
    call sfx_win_close           ; the window NEVER outlives the tick
    ret
.shortfile:
    ; the run list ran out with blocks still owed: the filemap and the
    ; F_FSTAT block count disagree (a stale map, or the file shrank).
    ; Nothing about that is retryable.
    ld (iy+SFXS_FAILCNT), SFX_FAIL_LIMIT
    jr .funnel
.wirefail:
    ld a, (iy+SFXS_DELIV)
    or a
    jr nz, .bump
    ld (iy+SFXS_FAILCNT), SFX_FAIL_LIMIT   ; first block of the
    jr .funnel                             ; stream: no raw SD path
                                           ; here (see the header)
.bump:
    inc (iy+SFXS_FAILCNT)
.funnel:
 IFDEF DEBUG
    inc (iy+SFXS_FAILS)
    jr nz, .nowrap
    dec (iy+SFXS_FAILS)          ; saturate rather than wrap to 0
.nowrap:
 ENDIF
    call sfx_win_close           ; a rejected open already deselected the
                                 ; card and restored MF, and this is
                                 ; idempotent, so it cannot double-restore
    ld a, (iy+SFXS_FAILCNT)
    cp SFX_FAIL_LIMIT
    ret c
    res 2, (ix+SMPB_FLAGS)       ; error eviction (see the header)
    res 4, (ix+SMPB_FLAGS)
    ; File the stop in THIS channel's mailbox bit - the existing resident
    ; path, consumed at the top of the next aud_tick: channel 1 is
    ; audRequest bit 7, channel 2 is audRequest2 bit 2. Which block IX
    ; points at is the only thing that distinguishes them, so compare it
    ; rather than infer anything from where the two blocks happen to sit.
    push ix
    pop hl
    ld de, sfxChan0
    or a
    sbc hl, de
    jr nz, .ev2
    ld hl, audRequest
    set 7, (hl)                  ; one instruction, so it cannot tear
    jr .evfiled                  ; against anything - the same discipline
.ev2:                            ; every other filer here uses
    ld hl, audRequest2
    set 2, (hl)
.evfiled:
    ld (iy+SFXS_KEEP), 0         ; no effect number is cached any more -
    ld (ix+SMPB_KEEP), 0         ; both copies, or the allocator would
                                 ; keep steering re-triggers at a channel
                                 ; whose stream has just been evicted
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
; refiller's entry, and only once one of the six counters is nonzero, so
; a build that never streams keeps its screen. Every counter is
; accumulated strictly OUTSIDE the wire polls, so the instrument cannot
; distort a bounded wait. The underrun counters are page-48 data (the
; pump writes them and cannot see this page); slot 6 still holds page 48
; here.
;
; Task 11 made the row DUAL: "SFX=rrrr/uuuu/ff rrrr/uuuu/ff", channel 1
; then channel 2, 29 columns starting at column 43 (it was 16 columns at
; 56 with one channel). Row 31 is otherwise unused by the game.
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
    ld hl, (sfxStrm0+SFXS_BLKS)
    ld a, h
    or l
    jr nz, .show
    ld hl, (sfxStrm1+SFXS_BLKS)
    ld a, h
    or l
    jr nz, .show
    ld hl, (sfxUnderrun0)
    ld a, h
    or l
    jr nz, .show
    ld hl, (sfxUnderrun1)
    ld a, h
    or l
    jr nz, .show
    ld a, (sfxStrm0+SFXS_FAILS)
    or a
    jr nz, .show
    ld a, (sfxStrm1+SFXS_FAILS)
    or a
    ret z
.show:
    ld hl, (dbgX)                ; dbgY follows dbgX: one word is the
    push hl                      ; whole mainline cursor
    ld b, 31
    ld c, 43
    call dbg_at
    ld hl, msgSfxRow
    call dbg_puts
    ld iy, sfxStrm0
    ld hl, sfxUnderrun0
    call .one
    ld a, ' '
    call dbg_putc
    ld iy, sfxStrm1
    ld hl, sfxUnderrun1
    call .one
    pop hl
    ld (dbgX), hl                ; mainline resumes exactly where it was
    ret
; One channel's rrrr/uuuu/ff. IY = its stream cell group, HL = its
; page-48 underrun counter. The dbg_* helpers touch neither.
.one:
    push hl
    ld l, (iy+SFXS_BLKS)
    ld h, (iy+SFXS_BLKS+1)
    call dbg_hex16
    ld a, '/'
    call dbg_putc
    pop hl
    ld a, (hl)
    inc hl
    ld h, (hl)
    ld l, a
    call dbg_hex16
    ld a, '/'
    call dbg_putc
    ld a, (iy+SFXS_FAILS)
    jp dbg_hex8
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
; sfx_page_call trampoline (main.asm, shared with sfx_alloc and
; sfx_stream_rewind since Task 12), needed because overlay1's
; aud_boot_probe is the only caller here and overlay1 shares the slot-7
; window with this page.
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
    ld (ix+SMPB_KEEP), 0             ; and nothing cached: a warm re-entry
                                     ; must not offer a free rewind into a
                                     ; window this boot never staged
    ; Channel 2 (SP18 item 7 Task 11), the same members with its own
    ; hardware and its own window/cells: the AUD_STAGE2 ring (same 1K
    ; power-of-two shape, so the same wrap mask), the smp2* resident
    ; cursors ctc2_isr plays, CTC channel 1 and DAC2_PORT ($B3, DACs
    ; B+C), window descriptor sfxWin1 (pages 53/54/55) and cell group
    ; sfxStrm1. SMPB_FLAGS is cleared here for the same reason
    ; aud_boot_probe clears channel 1's: the block is RESIDENT, so a warm
    ; re-entry (nextreg 2,1 with dirty RAM) would otherwise resurrect a
    ; stale active or looping bit against a rebuilt bank table.
    ld ix, sfxChan1
    ld (ix+SMPB_FLAGS), 0
    ld (ix+SMPB_RINGH), AUD_STAGE2 >> 8
    ld (ix+SMPB_RINGM), (AUD_STAGE2_RING-1) >> 8
    ld hl, smp2PlayPtr
    ld (ix+SMPB_PLAYPTR), l
    ld (ix+SMPB_PLAYPTR+1), h
    ld hl, smp2WritePtr
    ld (ix+SMPB_WRITEPTR), l
    ld (ix+SMPB_WRITEPTR+1), h
    ld hl, AUD_CTC2_PORT
    ld (ix+SMPB_CTCPORT), l
    ld (ix+SMPB_CTCPORT+1), h
    ld (ix+SMPB_DACPORT), DAC2_PORT
    ld hl, sfxWin1
    ld (ix+SMPB_WINTAB), l
    ld (ix+SMPB_WINTAB+1), h
    ld hl, sfxStrm1
    ld (ix+SMPB_STRM), l
    ld (ix+SMPB_STRM+1), h
    ld (ix+SMPB_DEPTH), 0
    ld (ix+SMPB_DEPTH+1), 0
    ld (ix+SMPB_KEEP), 0
    ; SFXS_HANDLE cold-reset hardening (final review Minor 3): sfxStrm0/1's
    ; SFXS_HANDLE start at $FF via the assembly-time initialiser (below),
    ; which only applies to a true cold load - a warm re-entry (nextreg
    ; 2,1, dirty RAM) leaves whatever handle number the previous session
    ; last held. A stale handle here can alias an incoming one, and the
    ; eviction at sfx_stream_open:.fresh would then close the FRESH handle
    ; instead of the stale one. Poison both explicitly, every boot, for
    ; the same reason SMPB_FLAGS/KEEP are cleared above.
    ld a, $FF
    ld (sfxStrm0+SFXS_HANDLE), a
    ld (sfxStrm1+SFXS_HANDLE), a
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
; Channel-independent scratch only. Everything that used to live here per
; channel (producer block, seek/deliver/fail state, the DEBUG counters)
; moved into the per-channel groups below when Task 11 parameterised the
; refiller.
sfxSeekBlk:     dw 0             ; sfx_run_seek working block counter
sfxTickBudget:  db 0             ; blocks left this tick, all channels
sfxBurstBudget: db 0             ; blocks left this channel this tick
sfxCellPtr:     dw 0             ; the current channel's stream cell group
                                 ; (IY), parked here so it can be reloaded
                                 ; after an esxDOS call - see the reload
                                 ; note at sfx_stream_open
sfxResMask:     db 0             ; sfx_vid_resume: the channels to restart
sfxResPin:      db 0             ; and the pin state of the one in hand -
                                 ; both in cells because sfx_alloc and
                                 ; sfx_stream_rewind corrupt DE

; --- streaming cells (SP18 item 7 Task 3) -----------------------------
; sfxHotMap through sfxCardFlags are the SHARED RUN-CONTEXT WORKING SET:
; the SD clones below address them absolutely, so only one channel's
; context can be in them at a time. The refiller owns them - it swaps the
; channel it is about to serve in at the top of that channel's leg and
; back out at the bottom (sfx_ctx_load / sfx_ctx_save), so nothing
; outside a leg may rely on their contents. Their order and total size
; MUST match the SFXC_* layout above; the ASSERT below pins that.
; sfxWinOpen and sfxMfSave are deliberately OUTSIDE the swapped block:
; they describe the CARD, not a channel (one CMD18 window and one
; Multiface state exist at a time, and every leg closes its window before
; it returns), so swapping them would be wrong as well as wasteful.
sfxHotMap:    ds SFX_HOT_ENT*6   ; 6-byte runs: addrLo(2) addrHi(2) blocks(2)
sfxRunIdx:    db 0
sfxRunCnt:    db 0
sfxRunAddrLo: dw 0
sfxRunAddrHi: dw 0
sfxRunBlk:    dw 0               ; blocks left in the open/current run
sfxCardFlags: db 0
    ASSERT $ - sfxHotMap == SFX_CTX_SIZE
    ASSERT sfxRunIdx - sfxHotMap == SFXC_IDX
    ASSERT sfxRunCnt - sfxHotMap == SFXC_CNT
    ASSERT sfxRunAddrLo - sfxHotMap == SFXC_ADDRLO
    ASSERT sfxRunAddrHi - sfxHotMap == SFXC_ADDRHI
    ASSERT sfxRunBlk - sfxHotMap == SFXC_BLK
    ASSERT sfxCardFlags - sfxHotMap == SFXC_FLAGS
sfxWinOpen:   db 0
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
sfxDepthTmp:  dw 0               ; DEPTH at the anchor, on its way into
                                 ; the descriptor's SFXW_DEPTH0
sfxWhole:     db 0               ; 1 = the whole file fits the window
sfxStageLen:  dw 0               ; bytes this open stages (<= window)
sfxStageRem:  dw 0               ; staging loop: bytes still to read
sfxStgWin:    dw 0               ; staging loop: this page's byte count
sfxStgIdx:    db 0               ; staging loop: window page index

; The two per-channel stream cell groups. SMPB_STRM in each channel block
; points at its own group (seeded by aud_sfx_init) and every access here
; is IY-relative through that pointer, so one body serves both channels.
; Layout: the SFXS_*/SFXC_* equates at the top of this file.
; Assembly-time initialisers for the true cold load: $FF in SFXS_HANDLE is
; "no cached stream", the correct cold state, and everything else is
; zero. aud_sfx_init ALSO pokes SFXS_HANDLE to $FF explicitly on every
; boot (warm included) - the assembly-time value alone survives a true
; cold load but not a warm re-entry's dirty RAM, and a stale handle here
; could alias an incoming one (final review Minor 3).
sfxStrm0:
    db $FF                       ; SFXS_HANDLE
    db 0                         ; SFXS_KEEP
    dw 0, 0, 0                   ; SFXS_FILEBLK / SFXS_STAGED / SFXS_DATAOFF
    db 0, 0, 0, 0                ; SFXS_PROD / SEEK / DELIV / FAILCNT
 IFDEF DEBUG
    dw 0                         ; SFXS_BLKS
    db 0                         ; SFXS_FAILS
 ENDIF
    ASSERT $ - sfxStrm0 == SFXS_CTX
    ds SFX_CTX_SIZE              ; SFXS_CTX: this channel's run context
                                 ; (hot filemap + card cursor), swapped
                                 ; into the shared working cells above
                                 ; for the duration of its refiller leg
    ASSERT $ - sfxStrm0 == SFX_STRM_SIZE
sfxStrm1:
    db $FF
    db 0
    dw 0, 0, 0
    db 0, 0, 0, 0
 IFDEF DEBUG
    dw 0
    db 0
 ENDIF
    ds SFX_CTX_SIZE
    ASSERT sfxStrm1 - sfxStrm0 == SFX_STRM_SIZE

 IFDEF DEBUG
; Token-poll instrument accumulators (sfx_sd_tok, above).
sfxTokPolls: dw 0
sfxTokCalls: dw 0
 ENDIF

    ASSERT $ <= OVL_ORG + $1800   ; stay inside the mapped 6K of the page
    DISPLAY "streamfx ends at ", $, " headroom ", /D, OVL_ORG + $1800 - $
