; streamfx.asm - SP18 item 7: sampled-effect SD streaming machinery.
; Lives on SFX_PAGE (71, upper 8K of bank 35 - the same withdrawn bank
; VID_PAGE2 uses for its lower 8K, page 70). Mapped into MMU slot 7
; ($E000) by its callers: mainline open/prefill (overlay1 trampoline,
; Task 5) and the aud_tick refiller (Task 6). No callers yet - this
; task lands the transport shapes plus the page itself; Tasks 5-6 wire
; the calls.
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

 IFDEF DEBUG
; Token-poll instrument accumulators (sfx_sd_tok, above).
sfxTokPolls: dw 0
sfxTokCalls: dw 0
 ENDIF

    ASSERT $ <= OVL_ORG + $1800   ; stay inside the mapped 6K of the page
    DISPLAY "streamfx ends at ", $, " headroom ", /D, OVL_ORG + $1800 - $
