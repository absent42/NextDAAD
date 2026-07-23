; NextDAAD code page: video (native NXV cutscene playback, SP14a T4).
; VID_PAGE (nextdaad.inc) = 59, the upper 8K of bank 29 - the only page
; in the overlay-reserved bank range (28/29) with no prior equate; see
; nextdaad.inc's VID_PAGE comment. Reached exactly like overlay0/1/2:
; MMU7 mapped to this page by whoever hops in (the engine dispatcher for
; GFX/SFX condacts), never resident code running in place. ONE RULE,
; unchanged from every prior
; video task: MMU7 = VID_PAGE for the entire window the video CTC ISR can
; fire (from the time constant write in vid_run through the CTC's final
; reset in .restore) - every cross-page hop in this file respects it.
;
; SP14a T4 (docs/superpowers/specs/2026-07-21-sp14a-native-video-design.md)
; SCRAPPED MakeVid compatibility entirely and replaced it with NXV, a
; single native, block-aligned, header-classified container (see
; nextdaad.inc's NXV header layout comment). This file holds: nxv_open
; (header validate + geometry derivation, replacing the old sizeless
; sector-count classifier), the raw-SD-SPI vid_stream_* streaming
; interface (format-agnostic, unchanged across every video task to
; date), the player core (vid_play/vid_run - CTC/Layer 2/copper-flip/
; presentation-isolation machinery), the flat and gapped pixel blits, and
; a DEBUG-only frame-timeline instrument (vid_tl_stamp/vid_tl_report -
; the gate's evidence tool). VIDBENCH, the streaming-throughput dev
; harness that fed the SP13/SP14a native-format decision, is retired
; (owner decision, SP14a T4 follow-up - its job is done; git history
; holds the code).

    MMU 7, VID_PAGE, OVL_ORG

; ---------------------------------------------------------------------
; vid_stream_* - dual-mechanism streaming interface. The three
; signatures and their register contracts are PINNED (Task 2's player
; consumes them verbatim); a one-byte selector vidStrmMode chooses the
; internals: 0 = plain esxDOS F_READ, 1 = raw card streaming (DISK_FILEMAP
; for the address map, then direct SD SPI CMD18/CMD12 - playvid's
; transport, not the OS DISK_STRM* API). The caller sets vidStrmMode
; BEFORE opening; all three routines honour it internally.
; ---------------------------------------------------------------------

; vid_stream_open_body (VID_PAGE2, below) is the real open routine - COLD,
; open-time only, provably never running while the video CTC ISR is armed
; (vid_open_video_body's own two attempts run before any CTC arm). SP14a
; T4 owner decision: VIDBENCH (the only caller that ever needed a hot-
; page trampoline into this routine) is retired entirely - vid_open_
; video_body is the sole remaining caller, and it is already same-page
; (plain call, no hop needed). No hot-page stub exists here any more.

; In: A = destination 8K page, mapped into the MMU6 window ($C000) for
;     the duration of this read only (the established data_save/
;     data_map_page/data_restore bracket - see ext_xmes/font_load,
;     overlay0.asm/overlay2.asm); DE = requested byte count, <= $2000
;     (one MMU6 window's worth - callers chunk larger transfers into
;     repeated calls, exactly like ddb_load/ext_xmes/font_load's own
;     $2000-per-call reads).
; Out: CF set = I/O error, A = error code.
;      CF clear = BC = bytes actually read. A short/EOF read clears CF
;      too (both mechanisms) - callers MUST compare BC against the
;      requested DE themselves, the established BC-discipline count-check
;      law (file.asm's sav_read comment; font_load's "BC discipline"
;      comment, overlay2.asm).
; Corrupts AF, BC, DE, HL, IX.
;
; RAW-MODE CONTRACT (vidStrmMode=1): the CMD18 SD read window is held OPEN
; across successive vid_stream_read calls for throughput (it closes only at
; a fragment boundary, EOF, an error, or vid_stream_close). While it is
; open, NO filesystem or SD access may occur ANYWHERE in the machine between
; calls - the card is mid-transaction and the Multiface is disabled. This
; holds by design: the bench pass loop and the T2 player loop do only Layer
; 2 / audio / timing work between reads. vid_stream_close is the release.
vid_stream_read:
    ld (vidReadPage), a          ; A = dest page (must survive the mode
    ld a, (vidStrmMode)           ; test); DE = count untouched throughout
    or a
    ld a, (vidReadPage)
    jr z, .fread
    jp vid_stream_read_raw
.fread:
    push af                      ; A = dest page; data_save only promises
    call data_save                ; to preserve DE, so stash A ourselves
    pop af
    call data_map_page
    ld a, (vidHandle)
    ld ix, DATA_WINDOW
    push de
    pop bc
    call esx_fread
    jr c, .fail
    push bc                      ; bytes read - preserve across data_restore
    call data_restore
    pop bc
    or a                         ; CF clear (already clear; explicit)
    ret
.fail:
    push af
    call data_restore
    pop af
    scf
    ret

; Closes the handle opened by vid_stream_open. No-op if none is open.
; In raw mode a read window may persist across calls (see vid_stream_read's
; contract) - vid_win_close releases it here (CMD12 + deselect + Multiface
; restore); it is idempotent and a no-op in F_READ mode. This is the
; caller's release point for the persistent window. Corrupts AF, BC, DE, HL.
vid_stream_close:
    call vid_win_close            ; release any open raw SD window first
    ld a, (vidHandle)
    cp $FF
    ret z
    call esx_fclose
    ld a, $FF
    ld (vidHandle), a
    ret

; Reset the raw streaming cursor to file start: entry pointer -> the
; first filemap run, window-open flag and run/tail-buffer state cleared,
; remain <- vidSizeLo/Hi (the file's total byte size, already known).
; SP14a T3 wave 1: factored out of vid_raw_setup/vid_stream_open's own
; first-open tail so BOTH first-open (via the cold hop below) and vid_
; run's loop-mode restart (same-page call, no hop - see that call site)
; share ONE definition of "cursor at file start" (the brief's own
; requirement). HOT (VID_PAGE): the loop-restart caller cannot hop away
; from VID_PAGE while the CTC is armed (the one rule), so this routine
; must be reachable by a plain same-page call. Does not touch vidStrm
; EntryEnd/vidCardFlags (filemap-capture-time-only properties that never
; change across a restart) or vidFilemapBuf itself (persists for the
; whole session). Corrupts AF, DE, HL.
vid_raw_reset_cursor:
    ld de, vidFilemapBuf
    ld (vidStrmEntryPtr), de
    xor a
    ld (vidStrmWinOpen), a
    ld hl, 0
    ld (vidStrmRunBlocks), hl
    ld (vidStrmBlkPos), hl
    ld (vidStrmBlkLen), hl
    ld hl, (vidSizeLo)
    ld (vidStrmRemainLo), hl
    ld hl, (vidSizeHi)
    ld (vidStrmRemainHi), hl
    ret

; Hot-side trampoline: reached (via a hop) from vid_stream_open_body
; (VID_PAGE2, cold) so its own raw-mode tail can run vid_raw_reset_cursor
; while resident on VID_PAGE, then hop back to VID_PAGE2's own resume
; point - the SAME push-target/ovl_map_page idiom used everywhere else in
; this file, just in the cold-calls-hot direction. Corrupts everything.
vid_raw_reset_cursor_coldcall:
    call vid_raw_reset_cursor
    ld hl, vid_stream_open_resetret
    push hl
    ld a, VID_PAGE2
    jp ovl_map_page

; vidHandle/vidStrmMode/vidSizeLo/vidSizeHi stay VID_PAGE-resident (hot)
; despite being WRITTEN only by the now-cold open cluster: hot code reads
; them every session (vid_stream_read's mode dispatch, vid_stream_close's
; handle check, vid_play's own vidSizeLo/Hi read before vid_classify, vid_
; raw_reset_cursor's remain-priming at loop restart) - the cold cluster
; touches them via the established MMU6 data-window translation instead
; (data_save/data_map_page(VID_PAGE)/`label+DATA_WINDOW-OVL_ORG` - see
; vid_open_video_body's header, VID_PAGE2 section). vidFstatBuf moves to
; VID_PAGE2 with the cold cluster (no hot reader - see that section).
vidStrmMode: db 0              ; 0 = F_READ, 1 = raw card streaming
vidHandle:   db $FF
vidSizeLo:   dw 0
vidSizeHi:   dw 0
vidReadPage: db 0

; ---------------------------------------------------------------------
; Raw card streaming internals (vidStrmMode = 1). All state lives in the
; video page (bank space) - nothing here grows resident memory.
; ---------------------------------------------------------------------
; The streaming cursor persists across vid_stream_read calls so a large
; transfer chunked into repeated $2000 reads resumes exactly where it
; left off. Whole 512-byte card blocks are always pulled (the SD block
; protocol has no sub-block read); when a caller's count ends mid-block
; the tail is held in vidStrmBlkBuf and drained first on the next call.
; remain (file bytes not yet delivered) drives EOF; the last card block
; of an unaligned file yields a full 512 of which only remain are valid.
;
; vid_stream_read raw path.
; In:  vidReadPage = dest 8K page, DE = requested count <= $2000.
; Out: CF clear, BC = bytes delivered (< DE at EOF); CF set, A = code.
; Each call is bracketed by data_save/data_map_page/data_restore (dest in
; the MMU6 window). The CMD18 card window PERSISTS across calls: when the
; caller's count is exhausted mid-run the card stays selected mid-stream
; (Multiface stays disabled - both are window-scoped, see vid_win_open/
; vid_win_close) and the next call resumes it. NO filesystem or SD access
; may occur anywhere between calls while a window is open; vid_stream_close
; (or a run boundary/EOF/error inside a call) is what releases the card.
; Corrupts AF, BC, DE, HL, IX.
vid_stream_read_raw:
    ld (vidStrmNeed), de          ; bytes still to serve this call
    ld (vidReadCountSaved), de    ; original count (for the served figure)
    call data_save                ; per-call MMU6 bracket (dest page changes
    ld a, (vidReadPage)            ; between calls; the SD window persists)
    call data_map_page            ; MMU6 = dest page
    ld hl, DATA_WINDOW
    ld (vidStrmDest), hl
.outer:
    ld hl, (vidStrmNeed)          ; served every requested byte?
    ld a, h
    or l
    jp z, .retopen                ; yes: return, leaving the window OPEN
    call vid_remain_zero          ; file exhausted?
    jp z, .eofclose               ; yes: close the window
    ld hl, (vidStrmBlkLen)        ; drain a buffered tail before streaming
    ld de, (vidStrmBlkPos)
    or a
    sbc hl, de
    jr z, .needstream
    call vid_drain
    jp .outer
.needstream:
    ld hl, (vidStrmRunBlocks)     ; current run empty? close it, load the next
    ld a, h
    or l
    jr nz, .haveblocks
    call vid_win_close            ; CMD12 the finished run before advancing
    call vid_next_run
    jp c, .eofclose               ; no more runs (defensive EOF)
.haveblocks:
    call vid_win_open             ; open at the current run (no-op if already)
    jp c, .strmerr
    ; --- register-resident fast path (the hot loop): stream whole 512-byte
    ; blocks straight into the window while need >= 512, remain >= 512 and the
    ; run still has blocks. Hot state lives in registers - main HL = dest,
    ; DE = need; alternate BC' = runBlocks, DE' = remainHi, HL' = remainLo -
    ; and is written back to the vidStrm* cells only on exit (vid_fast_spill),
    ; so cross-call resume stays memory-backed exactly as the slow path leaves
    ; it. The alternate set is safe: both IM2 ISRs (interrupts.asm) fully
    ; preserve it, and vid_read_block preserves DE + the alternate set. No
    ; IX/IY, no per-block memory bookkeeping (golden rules 1 and 2). Any edge
    ; (need/remain < 512, run boundary, EOF) spills and drops to .inner. ---
    ld bc, (vidStrmRunBlocks)
    ld de, (vidStrmRemainHi)
    ld hl, (vidStrmRemainLo)
    exx
    ld de, (vidStrmNeed)
    ld hl, (vidStrmDest)
.fast:
    ld a, d                       ; need >= 512 ? (DE >= $0200 <=> d >= 2)
    cp 2
    jr c, .fastexit
    exx                           ; -> alternate: remain, runBlocks
    ld a, d                       ; remainHi (DE') != 0 -> remain huge, ok
    or e
    jr nz, .fastruns
    ld a, h                       ; remainHi == 0: remainLo (HL') >= 512 ?
    cp 2
    jr c, .fastexits
.fastruns:
    ld a, b                       ; runBlocks (BC') > 0 ?
    or c
    jr z, .fastexits
    exx                           ; -> main: HL = dest, DE = need
    call vid_read_block           ; 512 into (HL); HL += 512; preserves DE + alt
    jr c, .fasttok
    ld a, d                       ; need -= 512 (d -= 2; 512's low byte is 0 and
    sub 2                         ; d >= 2 was just checked, so no borrow)
    ld d, a
    exx                           ; -> alternate: remain -= 512, runBlocks -= 1
    ld a, h                       ; remainLo high byte (H') -= 2
    sub 2
    ld h, a
    jr nc, .fastnb
    dec de                        ; borrow into remainHi (DE')
.fastnb:
    dec bc                        ; runBlocks--
    exx                           ; -> main
    jr .fast
.fasttok:
    call vid_fast_spill           ; token error (main active): write back, bail
    jp .tokerr
.fastexits:
    exx                           ; exited in the alternate set: back to main
.fastexit:
    call vid_fast_spill
    ; fall into .inner to handle the edge with the memory-based path
.inner:
    ld hl, (vidStrmNeed)
    ld a, h
    or l
    jp z, .retopen                ; caller satisfied: window stays open
    call vid_remain_zero
    jp z, .eofclose
    ld hl, (vidStrmRunBlocks)
    ld a, h
    or l
    jp z, .outer                  ; run boundary: back to .needstream to close
    ld hl, (vidStrmNeed)          ; direct 512 only when a whole block both
    ld de, 512                    ; fits the request and is all valid data
    or a
    sbc hl, de
    jp c, .viabuf                 ; need < 512: buffer + prefix-copy
    call vid_remain_ge512
    jp c, .viabuf                 ; remain < 512: partial final block
    ld hl, (vidStrmDest)
    call vid_read_block           ; 512 straight into the window
    jp c, .tokerr
    ld (vidStrmDest), hl
    ld hl, (vidStrmNeed)
    ld de, 512
    or a
    sbc hl, de
    ld (vidStrmNeed), hl
    ld de, 512
    call vid_remain_sub
    jp .blockdone
.viabuf:
    ld hl, vidStrmBlkBuf
    call vid_read_block           ; full 512 into the tail buffer
    jp c, .tokerr
    call vid_remain_ge512         ; valid bytes = min(512, remain)
    jr nc, .fullblk
    ld hl, (vidStrmRemainLo)      ; remain < 512: only remain are valid
    jr .havelen
.fullblk:
    ld hl, 512
.havelen:
    ld (vidStrmBlkLen), hl
    ld hl, 0
    ld (vidStrmBlkPos), hl
    call vid_drain                ; copy min(need, blkLen) now; tail stays
.blockdone:
    ld hl, (vidStrmRunBlocks)     ; one card block consumed (the run address
    dec hl                         ; is NOT stepped per block - the open CMD18
    ld (vidStrmRunBlocks), hl      ; window advances the card internally; the
                                   ; next run's address comes fresh from the
                                   ; filemap at the boundary)
    jp .inner
.retopen:
    call data_restore             ; per-call MMU6 restore only - the SD window
    jr .served                    ; and the Multiface disable both persist
.eofclose:
    call vid_win_close            ; CMD12 + deselect + MF restore
    call data_restore
.served:
    ld hl, (vidReadCountSaved)    ; served = original count - need left
    ld de, (vidStrmNeed)
    or a
    sbc hl, de
    push hl
    pop bc                        ; BC = bytes delivered
    or a                          ; CF clear
    ret
.tokerr:
    ld a, VID_ERR_TOKEN
.strmerr:
    ; A = error code (VID_ERR_TOKEN, or VID_ERR_CMD from vid_win_open)
    push af
    call vid_win_close            ; close + MF restore (no-op if never opened)
    call data_restore
    pop af
    scf
    ret

; Write the fast-path hot registers back to the resume cells. In: main
; HL = dest, DE = need; alternate BC = runBlocks, DE = remainHi, HL =
; remainLo. Out: main set active, all cells consistent. Preserves the
; register contents; corrupts nothing (no flags).
vid_fast_spill:
    ld (vidStrmDest), hl
    ld (vidStrmNeed), de
    exx
    ld (vidStrmRunBlocks), bc
    ld (vidStrmRemainHi), de
    ld (vidStrmRemainLo), hl
    exx
    ret

; Copy min(vidStrmNeed, buffered) bytes from vidStrmBlkBuf+BlkPos to the
; MMU6 window (vidStrmDest), advancing need/dest/BlkPos and taking that
; many off remain (remain counts UNDELIVERED file bytes - buffering a
; block does not touch it; it decrements here, delivery time, exactly
; like the direct-512 path does). Corrupts AF, BC, DE, HL.
vid_drain:
    ld hl, (vidStrmBlkLen)        ; avail = BlkLen - BlkPos
    ld de, (vidStrmBlkPos)
    or a
    sbc hl, de                    ; HL = avail
    ld de, (vidStrmNeed)          ; count = min(avail, need)
    or a
    sbc hl, de                    ; avail - need (CF set = avail < need). No
    jr nc, .useneed               ; push/pop guard: restore avail with ADD only
    add hl, de                    ; in the avail < need branch, where CF is dead
    jr .count                     ; avail < need: count = avail (HL restored)
.useneed:
    ld hl, (vidStrmNeed)          ; avail >= need: count = need
.count:
    push hl
    pop bc                        ; BC = count (<= 511, <= need)
    ld hl, vidStrmBlkBuf          ; src = BlkBuf + BlkPos
    ld de, (vidStrmBlkPos)
    add hl, de
    ld de, (vidStrmDest)
    push bc
    ldir                          ; HL,DE advance; BC -> 0
    pop bc
    ld (vidStrmDest), de
    ld hl, (vidStrmBlkPos)        ; BlkPos += count
    add hl, bc
    ld (vidStrmBlkPos), hl
    ld hl, (vidStrmNeed)          ; need -= count
    or a
    sbc hl, bc
    ld (vidStrmNeed), hl
    ld d, b                       ; remain -= count
    ld e, c
    jp vid_remain_sub             ; tail-call, returns to vid_drain's caller

; Load the next filemap entry into the run cursor. Out: CF set = no more
; entries. Each entry: 4-byte card address (low word, high word) + 2-byte
; block count. Corrupts AF, DE, HL.
vid_next_run:
    ld hl, (vidStrmEntryPtr)
    ld de, (vidStrmEntryEnd)
    or a
    sbc hl, de
    jr c, .more
    scf                          ; EntryPtr >= EntryEnd: exhausted
    ret
.more:
    ld hl, (vidStrmEntryPtr)
    ld e, (hl)
    inc hl
    ld d, (hl)
    inc hl
    ld (vidStrmRunAddrLo), de     ; card address low word
    ld e, (hl)
    inc hl
    ld d, (hl)
    inc hl
    ld (vidStrmRunAddrHi), de     ; card address high word
    ld e, (hl)
    inc hl
    ld d, (hl)
    inc hl
    ld (vidStrmRunBlocks), de     ; number of 512-byte blocks in the run
    ld (vidStrmEntryPtr), hl
    or a                         ; CF clear
    ret

; Ensure the SD read window is open at the current run address. No-op if
; already open (the window persists ACROSS vid_stream_read calls - see the
; vid_stream_read contract). The first open disables the Multiface (it stays
; off for the whole window) and issues CMD18. Out: CF set = CMD18 rejected
; (A = VID_ERR_CMD, MF restored, window left closed). Corrupts AF, BC, DE, HL.
vid_win_open:
    ld a, (vidStrmWinOpen)
    or a
    ret nz                        ; already open (CF clear)
    call vid_mf_disable
    call vid_strm_start           ; CMD18 (deselects the card on failure)
    jr c, .failed
    ld a, 1
    ld (vidStrmWinOpen), a
    or a                          ; CF clear
    ret
.failed:
    push af                       ; keep VID_ERR_CMD
    call vid_mf_restore           ; window never opened - undo the MF disable
    pop af
    scf
    ret

; Close the SD read window if open: CMD12 stop, deselect, restore the
; Multiface. No-op (CF clear) if none is open (F_READ mode, or already
; closed) - idempotent, so vid_stream_close can always call it. Corrupts
; AF, BC, DE, HL.
vid_win_close:
    ld a, (vidStrmWinOpen)
    or a
    ret z                         ; not open
    call vid_strm_end             ; CMD12 + deselect (always CF clear)
    call vid_mf_restore
    xor a
    ld (vidStrmWinOpen), a         ; mark closed (A = 0, CF clear)
    ret

; Open a read window on the current run via raw SD SPI - CMD18
; READ_MULTIPLE_BLOCK at the run's card address (transcribed from
; playvid's nf_ open sequence). NO OS streaming window is opened: we drive
; the card directly, so nothing needs "ending" beyond deselecting the card
; in vid_strm_end. The card address goes on the wire big-endian (H,L,D,E)
; in card-native units, the exact value DISK_FILEMAP gave us. Out: CF set =
; R1 rejected the command (A = VID_ERR_CMD, card released); CF clear = card
; selected and ready to stream. Corrupts AF, BC, DE, HL.
vid_strm_start:
    ld a, (vidCardFlags)
    and 1                         ; Z = card 0, NZ = card 1 (survives to .cs)
    ld hl, (vidStrmRunAddrHi)     ; H:L = addr byte3 (MSB) : byte2
    ld de, (vidStrmRunAddrLo)     ; D:E = addr byte1 : byte0 (LSB)
    ld a, CMD18_READ_MULTIPLE_BLOCK
    call vid_sd_cmd
    jr nz, .cmdfail               ; R1 != 0: card rejected the read
    or a                          ; CF clear: window open, card selected
    ret
.cmdfail:
    call vid_card_deselect
    ld a, VID_ERR_CMD
    scf
    ret

; Close the current read: CMD12 STOP_TRANSMISSION, clock the stop tail,
; deselect the card. No OS streaming window exists, so deselecting is all
; that is needed to leave the filesystem usable again between reads - this
; is exactly what playvid does at every fragment boundary. Always CF clear.
; Corrupts AF, BC, DE, HL.
vid_strm_end:
    ld a, (vidCardFlags)
    and 1                         ; Z = card 0 (survives to .cs)
    ld a, CMD12_STOP_TRANSMISSION
    call vid_sd_cmd_noparam       ; R1 ignored (best-effort stop)
    ld b, 8+1                     ; clock 9 bytes to flush the stop response
.tail:
    in a, (PORT_SPI_DAT)
    djnz .tail
    ; fall through to deselect + tail clocks
; Deselect the SD card (CS high) and clock it twice (playvid parity).
; Always CF clear. Corrupts AF.
vid_card_deselect:
    ld a, $FF
    out (PORT_SPI_CS), a
    in a, (PORT_SPI_DAT)
    nop                           ; >= 16T between reads (interface pacing)
    in a, (PORT_SPI_DAT)
    or a                          ; CF clear
    ret

; Read one whole 512-byte block from the SD data port into (HL): wait the
; $FE data token FIRST (playvid order - poll until non-$FF, verify $FE),
; then the 512 bytes, then skip the 2-byte CRC. In: HL = destination, card
; already selected + streaming (CMD18 issued). Out: HL += 512; CF set = the
; token was not $FE (A = the offending byte). Corrupts AF, BC, HL.
;
; SP14a T4 owner follow-up (RELEASE-side VID_PAGE lever, coordinator
; directive): the transfer body is 256 unrolled INI executed TWICE
; (was 512 unrolled INI once, ~1KB hot) - halves this routine's own
; code size for ~507B freed, on EVERY build variant (this code is not
; IFDEF DEBUG - Release and DEBUG alike gain the same headroom). Cost:
; one extra loop-control (dec/jr) + one count-reload per block, ~30T
; against the interface's own 16T/byte x 512 = 8192T block transfer -
; folded into the per-profile margin restatement in the task report.
; SP14a gap-blit "full burst" wave: DEBUG-only, shrinks once more, 128x4
; -> 64x8 (see .halfloop's own comment below for the exact byte/T-state
; accounting and why this is DEBUG-only, unlike the first halving above -
; Release keeps 128x4 unchanged).
;
; Loop-counter register sweep: A, not B or DE. B is banned by the
; standing lesson (Z80 INI itself decrements B as a side effect - a
; B-based outer counter would be corrupted by the very instructions it
; is counting, the SP14a T3 fix-wave-3 regression this file already
; carries the scar of). DE is banned by THIS routine's own established
; contract - every call site (the register-resident fast path above
; especially: "preserves DE + alt") depends on vid_read_block leaving
; DE untouched; using E here would silently break that. IX/IY are
; banned by the wider streaming subsystem's own golden rules (this
; file's "IX/IY-free" invariant - IX is the video CTC ISR's exclusive
; resident play pointer for the whole armed window this routine runs
; inside; touching it here, even transiently, would race the ISR).
; A is the only register left, and it is provably free: INI's own
; operation is (HL)<-(C), HL++, B-- - it never reads or writes A at
; all - and A was ALREADY in this routine's own "Corrupts AF" contract
; before this change, so no caller relies on it surviving either. A
; genuinely idle memory cell would work too (E.g. a new byte alongside
; vidRawResetByte) but costs more bytes for zero extra safety once A is
; confirmed clear - the smaller of the two options this sweep found.
; Owner gate-leg audit follow-up (SP14a T4, VSTG2 hardware freeze): the
; token-wait below was UNBOUNDED (unconditional spin) - confirmed
; unchanged from the pre-T4 player (git history: byte-identical at
; commit 163d353~1), so not a T4 regression, but a genuine latent
; hazard this file never actually closed. A card that never answers
; (window desync, a run boundary the filemap did not expect, any other
; wedge) hangs here forever with no recovery - exactly the observed
; "freeze" signature. Bounded to 65536 polls (BC countdown, ~20T/poll -
; tens of milliseconds of real margin over any legitimate SD response
; latency) so a wedged card now falls through to .tokbad's own clean
; VID_ERR_TOKEN-style exit instead of hanging - unconditional (not
; IFDEF DEBUG): this hardens Release too, not just the diagnostic
; ladder. BC is already in this routine's own "Corrupts BC" contract,
; so the counter costs no new register-contract risk.
vid_read_block:
.wt:
    ld bc, 0                      ; bounded retry: 65536 polls
.wtloop:
    in a, (PORT_SPI_DAT)          ; poll for the block's data token
    inc a
    jr nz, .wtgot                 ; non-$FF: something arrived, check it
    dec bc
    ld a, b
    or c
    jr nz, .wtloop
    jp .tokbad                    ; exhausted: treat as a bad/missing token -
                                   ; jp: .tokbad is past the ~520-byte unroll
.wtgot:
    dec a                         ; recover the raw byte
    cp $FE                        ; $FE = valid data token
    jp nz, .tokbad                ; jp: .tokbad is past the ~520-byte unroll
    ld c, PORT_SPI_DAT
    ; SP14a gap-blit "full burst" wave (space fallback, coordinator-
    ; sanctioned "only if unavoidable" lever): DEBUG's own VID_PAGE
    ; headroom could not otherwise fund vid_gap_xfer's shared 192-`ini`
    ; full-burst run (vid_stream_pixels_gap, above) without touching
    ; unrelated DEBUG scaffolding this wave has no business in - DEBUG
    ; shrinks this unroll one step further, 128x4 -> 64x8 (frees 128B,
    ; against a ~60B need). RELEASE KEEPS 128x4 UNCHANGED: Release's own
    ; VID_PAGE headroom (392B before this wave) already covers the new
    ; run without shrinking anything, and N0/N1/N2 (the profiles that
    ; live in THIS routine, never vid_gap_xfer) are the ones actually
    ; shipped to players - there is no reason to pay a burst-length
    ; regression (even the small, well-understood CPU-side kind, let
    ; alone any less-certain silicon-side one - the burst-length-vs-T/
    ; byte curve is only measured at 64 bytes (fragmented, mixed with an
    ; 8-byte remainder - the old gap path) and 256+ bytes (flat's own
    ; sustained figure); a clean, UNIFORM 64-byte burst's own real rate
    ; is not directly measured, so a DEBUG-only trade avoids gambling
    ; Release's own already-healthy N0/N1/N2 margins on that gap) in the
    ; binary that ships. DEBUG builds are for development, not play.
 IFDEF DEBUG
    ld a, 8                            ; eight 64-byte eighths
.halfloop:
    DUP 64
      ini                              ; 16T/byte, unchanged - see this
    EDUP                               ; routine's own header.
    dec a                             ; A survives untouched across every
    jp nz, .halfloop                   ; INI above (see this routine's own
                                        ; header) - jp: within jr's -128
                                        ; range now but left as jp
                                        ; (harmless, byte-identical cost
                                        ; either way: JP cc is always
                                        ; 10T/3B, JR cc taken is 12T/2B -
                                        ; not changed to keep the diff
                                        ; minimal and obviously correct)
 ELSE
    ; Owner rider (SP14a gap-blit "full burst" wave, folded in after the
    ; main job's own space arithmetic settled): Release's own VID_PAGE
    ; headroom (392B before this rider) covers restoring the unroll
    ; toward 256x2 (+256B needed, 136B left after) - RELEASE ONLY, DEBUG
    ; stays at 64x8 above (its own budget cannot also fund this). This is
    ; not speculative: 256-byte bursts are the EXACT configuration the
    ; coordinator's own 22.1T/byte "silicon floor" figure was measured
    ; against (this routine's own "flat's sustained 1264KB/s" precedent,
    ; vid_stream_pixels_gap's header) - restoring it is a return to the
    ; measured-good shape, not a new gamble, worth ~0.5-1T/byte over the
    ; shipped 128x4 baseline (~1-2ms/frame on N0's own 320KB/frame).
    ld a, 2                            ; two 256-byte halves
.halfloop:
    DUP 256
      ini                              ; 16T/byte, unchanged - see this
    EDUP                               ; routine's own header.
    dec a                             ; A survives untouched across every
    jp nz, .halfloop                   ; INI above (see this routine's own
                                        ; header) - jp: .halfloop is ~512
                                        ; bytes back, past jr's -128 range
 ENDIF
    in a, (c)                     ; skip the 2-byte CRC (the nops pad the
    nop                           ; in/in to the 16T/byte interface timing)
    in a, (c)
    nop
    or a                          ; CF clear: block read (A's leftover CRC
                                   ; byte is discarded either way - matches
                                   ; the pre-existing behaviour exactly)
    ret
.tokbad:
    scf
    ret

; Send an SD SPI command (playvid sd_send_command). In: A = command byte
; (CMDn|$40); HLDE = 32-bit argument, sent big-endian (H first); the Z flag
; = card select (Z -> SD_CS0/card 0, NZ -> SD_CS1/card 1), set by the
; caller's `and 1` and preserved into here. Selects the card, clocks the
; 6-byte frame, polls R1. Out: Z set = R1 was 0 (accepted). Preserves
; DE/HL; corrupts AF, BC.
vid_sd_cmd_noparam:
    ld h, 0                       ; no address argument (flags-only commands)
    ld l, 0
    ld d, 0
    ld e, 0
vid_sd_cmd:
    ld b, $FF                     ; CRC placeholder (real CRC only CMD0/CMD8)
    ld c, a                       ; save the command byte
    ld a, SD_CS0
    jr z, .cs
    ld a, SD_CS1
.cs:
    out (PORT_SPI_CS), a          ; select the card
    in a, (PORT_SPI_DAT)          ; sync clock
    ld a, c                       ; command byte first
    ld c, PORT_SPI_DAT            ; OUT (C) => 16T/byte framing
    out (c), a
    ld a, h
    out (c), a                    ; arg byte 3 (MSB)
    ld a, l
    out (c), a                    ; arg byte 2
    ld a, d
    out (c), a                    ; arg byte 1
    ld a, e
    out (c), a                    ; arg byte 0 (LSB)
    ld a, b
    out (c), a                    ; CRC
    nop
.resp:
    in a, (PORT_SPI_DAT)          ; poll R1 (card holds $FF until it answers)
    inc a
    jr z, .resp
    dec a                         ; Z iff R1 == 0 (no error)
    ret

; Clear the Multiface enable (peripheral 2 bit 3), saving the prior value.
; A Multiface NMI mid-SD-transaction could issue file I/O that re-selects
; the card and desyncs the stream (recoverable-looking but wrong data);
; disabling it for the window removes the possibility. Corrupts AF
; (E is nr_read's select input, not written).
vid_mf_disable:
    ld e, NR_PERIPH2
    call nr_read                  ; A = current peripheral 2 (preserves BC)
    ld (vidMfSave), a
    and %11110111
    nextreg NR_PERIPH2, a
    ret

; Restore peripheral 2 to its pre-stream value. Corrupts AF.
vid_mf_restore:
    ld a, (vidMfSave)
    nextreg NR_PERIPH2, a
    ret

; remain == 0 test. Out: Z set if the file is exhausted. Corrupts AF only.
vid_remain_zero:
    ld a, (vidStrmRemainLo)
    or a
    ret nz
    ld a, (vidStrmRemainLo+1)
    or a
    ret nz
    ld a, (vidStrmRemainHi)
    or a
    ret nz
    ld a, (vidStrmRemainHi+1)
    or a
    ret

; remain >= 512 test. Out: CF set = remain < 512 (a partial final block).
; Corrupts AF, DE, HL.
vid_remain_ge512:
    ld hl, (vidStrmRemainHi)
    ld a, h
    or l
    jr nz, .ge                    ; any high-word bits: definitely >= 512
    ld hl, (vidStrmRemainLo)
    ld de, 512
    or a
    sbc hl, de                    ; CF set iff remain < 512
    ret
.ge:
    or a                         ; CF clear
    ret

; remain -= DE (16-bit, DE <= 512). Corrupts AF, HL.
vid_remain_sub:
    ld hl, (vidStrmRemainLo)
    or a
    sbc hl, de
    ld (vidStrmRemainLo), hl
    ret nc
    ld hl, (vidStrmRemainHi)
    dec hl
    ld (vidStrmRemainHi), hl
    ret

vidCardFlags:      db 0
vidMfSave:         db 0
vidStrmWinOpen:    db 0          ; 1 = an SD read window (CMD18) is open and
                                  ; persists across vid_stream_read calls
; vidRawResetByte moved to VID_PAGE2 with vid_raw_setup (SP14a T3 wave 2)
; - it is F_READ's discard target (never read back), so it has no reason
; to stay hot once its only writer does not.
vidReadCountSaved: dw 0          ; original requested count (served calc)
vidStrmNeed:       dw 0          ; bytes still to serve this call
vidStrmDest:       dw 0          ; next dest address in the MMU6 window
vidStrmEntryPtr:   dw 0          ; next filemap entry to consume
vidStrmEntryEnd:   dw 0          ; one past the last written entry
vidStrmRunAddrLo:  dw 0          ; current run card address, low word
vidStrmRunAddrHi:  dw 0          ; current run card address, high word
vidStrmRunBlocks:  dw 0          ; 512-byte blocks left in the current run
vidStrmRemainLo:   dw 0          ; file bytes not yet delivered, low word
vidStrmRemainHi:   dw 0          ; file bytes not yet delivered, high word
vidStrmBlkPos:     dw 0          ; drain cursor into vidStrmBlkBuf
vidStrmBlkLen:     dw 0          ; valid bytes held in vidStrmBlkBuf
vidFilemapBuf:     ds VID_FILEMAP_ENT*6   ; DISK_FILEMAP entries (192 bytes)
vidStrmBlkBuf:     ds 512        ; one card block held for sub-block drains

; ---------------------------------------------------------------------
; vid_play - the player core entry (SP14a T4: native NXV). Entry: B =
; video number, C = 0 play-once / 1 loop (h_gfx/h_sfx translate their own
; sub-command numbers into this before the cross-page hop - see
; nextdaad.inc's GFX_SUB_VID_*/SFX_SUB_VID_*). Probes PARTn\NNN.VID
; (curPart > 1) then root NNN.VID, opens, and unconditionally hands off to
; vid_run - the NXV header validate (nxv_open, below) now runs INSIDE
; vid_run's own early-bail sequence (after bank_alloc, before any CTC/
; Layer2/copper state is touched), not here - see vid_run's header for
; why. ALWAYS returns via vid_run's own restore path (.restore/
; .restore_noplay/.restore_badhdr) on every exit - key, EOF, read error,
; or a bad header. Corrupts everything; the caller (h_gfx.vidgo/h_sfx.
; vidgo) never resumes - this IS the tail of the dispatch, and the return
; lands directly on the engine dispatcher via the trampoline's stacked
; return address (the xpart_load_entry push-target idiom).
; ---------------------------------------------------------------------
vid_play:
    ld a, b
    ld (vidNum), a
    ld a, c
    ld (vidLoopMode), a
    ld c, b                       ; video number -> C (survives the hop
                                   ; below; A is consumed by ovl_map_page's
                                   ; own MMU7 value - see vid_open_video)
    call vid_open_video
    jr c, .missing
    jp vid_run                    ; tail: vid_run's own restore paths ret
.missing:
 IFDEF DEBUG
    ; SP14a T4 owner follow-up (VID_PAGE budget, post-VIDBENCH-retirement):
    ; hopped cold - this path is reached only when vid_open_video failed,
    ; strictly before vid_run/the CTC are ever touched, so it is safe to
    ; leave MMU7 pointed at VID_PAGE2 for the duration of the print (same
    ; pre-arm reasoning as every other cold hop in this file).
    ld hl, vid_play_missing_body
    push hl
    ld a, VID_PAGE2
    jp ovl_map_page
.missingret:
 ENDIF
    ret

; Build vidName ("NNN.VID",0) from the video number, probe PARTn\ then
; root, open the winner. Out: CF clear = opened (vidHandle/vidSizeLo/Hi
; set); CF set = neither name opened.
;
; SP14a T3 wave 1: COLD (VID_PAGE2) - the whole name-build/PARTn-probe/
; open cluster runs exactly once per vid_play invocation, entirely before
; vid_run ever arms the CTC (provably: vid_play calls this then `jp
; vid_run` unconditionally - the CTC's own first arm is deep inside
; vid_run, well after this cluster's work AND nxv_open's own header
; validate, below, are both done; the loop-mode restart no longer calls
; this at all - see vid_run's own restart redesign). This hot-page stub
; is the only part left resident: it hops to vid_open_video_body (VID_
; PAGE2, below) via the established push-target/ovl_map_page trampoline
; and back - same B-carries-CF convention this file uses everywhere else.
; The video number travels via C (set by vid_play, above) rather than
; memory, so vid_open_video_body needs no MMU6 translation just to learn
; which file to open. Corrupts AF, BC, DE, HL, IX.
vid_open_video:
    ld hl, vid_open_video_body
    push hl
    ld a, VID_PAGE2
    jp ovl_map_page
vid_open_video_ret:
    ld a, b
    or a
    jr z, .ok
    scf
    ret
.ok:
    or a
    ret

; ---------------------------------------------------------------------
; nxv_open - validate the NXV header (block 0) and derive every per-file
; playback parameter this player needs, straight from the header fields
; (nextdaad.inc's NXV_OFF_* layout comment is the authority for offsets/
; sizes). REPLACES the old sizeless sector-count vid_classify entirely -
; no divisor walk, no priority-order collision hazard, no six-format
; table.
;
; Split hot stub / cold body (VID_PAGE budget - the validation logic
; itself is sizeable and does not need MMU7=VID_PAGE for anything beyond
; the one vid_stream_read call): this hot stub does ONLY the actual 512-
; byte read off the SD card (vid_stream_read is VID_PAGE-resident and
; touches vidStrm* cells directly, untranslated), then hops to nxv_open_
; body (VID_PAGE2, below) for the parse/validate/derive, and back - the
; same push-target/ovl_map_page trampoline and B-carries-result
; convention this file uses everywhere else. Called from vid_run's own
; early sequence, AFTER bank_alloc has claimed the pool bank (block 0
; lands in vidAudPoolPage as one-time scratch - the SAME page frame 0's
; real audio will land in; no rewind is needed afterward, since the raw
; streaming cursor naturally continues from block 1 = frame 0's own
; first byte) and BEFORE any CTC/Layer2/copper/isolation state is
; touched - an invalid header bails out through vid_run's own .restore_
; badhdr path with zero teardown needed beyond freeing the bank and
; closing the stream. C carries the pool page across the hop (the hot
; stub's own A/BC are both consumed/corrupted by vid_stream_read, so it
; is reloaded fresh from vidAudPoolPage - cheap - rather than assumed to
; survive the call).
; Out: CF clear = valid NXV header; every vid* cell (vidShape/vidHeight/
;      vidAChan/vidABytesPad/vidABytesReal/vidPalFlag/vidPixBlocks/
;      vidGapNeeded/vidColUnits/vidClipY1/vidYofs) populated for the
;      frame loop to use every frame. CF set = invalid (bad magic/
;      version/shape/width/height-alignment/rate/pad-real/palette-flag/
;      pixel-block-count, or a read/IO failure on the header block
;      itself) - caller prints the existing "VID FMT?" message, same as
;      the old unclassifiable-size case. Corrupts everything.
nxv_open:
    ld a, (vidAudPoolPage)
    ld de, 512
    call vid_stream_read
    jr c, .ioerr
    ld hl, 512
    or a
    sbc hl, bc
    jr nz, .ioerr           ; short/EOF read on the header block itself
    ld a, (vidAudPoolPage)  ; reload fresh - vid_stream_read corrupts A
    ld c, a
    ld hl, nxv_open_body
    push hl
    ld a, VID_PAGE2
    jp ovl_map_page
.ioerr:
    scf
    ret
nxv_open_ret:
    ld a, b
    or a
    jr z, .ok
    scf
    ret
.ok:
    or a
    ret

; ---------------------------------------------------------------------
; Copper flip - RETIRED (owner fix, "PALETTE SPARKLE + MAGENTA
; REGRESSION" parity-chain audit). This block used to describe a 4-
; instruction/8-byte FRAME-mode list (WAIT <NXV_COPPER_LINE>,0 / MOVE
; NR_L2_BANK,<bank> / MOVE NR_PAL_CTRL,<palctl> / HALT) offloading the
; double-buffer flip to hardware (spec's Q2a design, docs/superpowers/
; specs/2026-07-21-sp14a-native-video-design.md). Sound in isolation,
; but UNSAFE in combination with vid_apply_palette (below): the copper's
; own MOVE to NR $43 fires unconditionally every field once CPC reaches
; it (dev guide, chapter-next-copper.tex, FRAME mode) - a second,
; independent writer to the exact register vid_apply_palette ALSO
; writes directly, 256 times per call, to select its own edit-target
; bank. A vblank landing mid-loop stomps the edit-target bit back to
; the "locked" state, corrupting the rest of that frame's palette write
; (sparkle) and leaving the bank it just flipped to only partially
; written the next time it's shown (magenta). T2 (git ffc5350) never
; had this hazard - its flip was a single immediate CPU write, no
; independent hardware writer racing it - and vid_run's own flip block
; (above) now uses that exact proven choreography again instead. The
; former per-frame poke routine (vid_copper_poke, hot/VID_PAGE) is
; deleted outright - nothing calls it any more, and hot-page budget is
; tight. vid_copper_init (below, VID_PAGE2, still owner-hardware-
; validated for its WAIT line - VBENCH-COPPER leg, SP14a T3) is left
; defined but uncalled: a future correct integration would need to
; bracket vid_apply_palette's own loop with a copper STOP/START (or
; equivalent mutual exclusion) rather than letting the two writers race
; unguarded - that redesign is out of this fix's scope.
; ---------------------------------------------------------------------

; ---------------------------------------------------------------------
; vid_run - entry/exit symmetry: everything vid_run touches is captured
; into a vidSv*-prefixed cell here and reversed on EVERY exit path via
; .restore (.restore_badhdr if the NXV header is invalid, .restore_noplay
; if the pool-bank claim itself failed). Sequence: save state -> samples
; abort (SSTOP, waited) -> music tick frozen (audEnable=0 - the least
; invasive freeze: it also stops the frame ISR's OWN MMU6/7 remap around
; aud_tick, which is exactly what keeps MMU7=VID_PAGE stable for video_
; ctc_isr's banking invariant, doc 11) -> pool bank claimed -> NXV header
; validated (nxv_open - an invalid header bails HERE, before any CTC/
; Layer2/copper/presentation state is touched) -> presentation isolation
; saved+disabled -> CTC retuned -> IM2_CTC_STUB patched -> Layer 2 set up
; -> the loop -> reverse-order restore on any
; exit (key, EOF in play-once, or a read error), banks released, ret
; through the dispatcher's normal path.
; ---------------------------------------------------------------------
vid_run:
    ; --- save state: MMU6/MMU7 MUST be captured HERE, hot, before ANY
    ; hop - a cold hop's own data_save/data_map_page bracket would
    ; otherwise capture that bracket's OWN temporary MMU6 value instead
    ; of the true pre-video one (and MMU7 is already VID_PAGE by
    ; definition the instant any hop runs, not vid_run's true caller-
    ; side value). VID_PAGE budget lever: everything ELSE this routine
    ; used to capture/do here (NR12/70/69/15, the IM2 stub, audEnable,
    ; l2Front/BackBank, the samples-abort wait, the music-tick freeze)
    ; has no such ordering hazard, so it moved to vid_run_entry_body
    ; (VID_PAGE2, below). ---
    ld e, NR_MMU6
    call nr_read
    ld (vidSvMmu6), a
    ld e, NR_MMU7
    call nr_read
    ld (vidSvMmu7), a
    ld hl, vid_run_entry_body
    push hl
    ld a, VID_PAGE2
    jp ovl_map_page
.entryret:

    ; --- pool bank: the audio landing page (lower 8K, doubles as nxv_
    ; open's one-time NXV header scratch buffer below) + palette landing
    ; page (upper 8K of the SAME bank) - not two full frame pairs; pixels
    ; are the existing Layer 2 back-surface banks (zero-copy, no pool
    ; allocation needed for them at all). ---
    call bank_alloc
    jr nc, .havebank
 IFDEF DEBUG
    ; SP14a T4 owner follow-up (VID_PAGE budget, post-VIDBENCH-retirement):
    ; hopped cold - reached only on a bank_alloc failure, strictly before
    ; the CTC/L2/presentation state is ever touched (matches this path's
    ; own existing .restore_noplay scope - see that label's own comment).
    ld hl, vid_run_nobank_body
    push hl
    ld a, VID_PAGE2
    jp ovl_map_page
.nobankret:
 ENDIF
    jp .restore_noplay
.havebank:
    ld (vidAudPoolBank), a
    add a, a
    ld (vidAudPoolPage), a

    ; --- SP14a T4: NXV header validate (nxv_open, above) - block 0 is
    ; read via the raw streaming cursor already sitting at file start
    ; (vid_open_video's own raw setup/reset). CF set = bad header: bail
    ; before ANY CTC/Layer2/presentation/copper state is touched - only
    ; the pool bank and the sample-freeze need reversing (.restore_
    ; badhdr, below) - REPLACES the old vid_classify's badfmt path. ---
    call nxv_open
    jp c, .restore_badhdr

    ; --- presentation isolation (spec requirement, owner 2026-07-21) +
    ; Layer 2 setup + identity palette + copper list load - ALL hopped
    ; cold (VID_PAGE2's vid_run_l2setup_body, below) since NONE of it
    ; depends on the CTC being armed, and this runs strictly BEFORE the
    ; CTC retune section below arms it - the one-rule invariant (MMU7 =
    ; VID_PAGE whenever the ISR can fire) is honoured because the hop
    ; happens entirely pre-arm. See vid_run_l2setup_body's own header
    ; (VID_PAGE2) for the full geometry derivation this used to do
    ; inline here. ---
    ld hl, vid_run_l2setup_body
    push hl
    ld a, VID_PAGE2
    jp ovl_map_page
.l2setupret:
    ; sjasmplus dot-local scoping note (vid_stream_open_body's own
    ; precedent, VID_PAGE2): a bare global landing label here would
    ; rescope every dot-local vid_run defines AFTER it (.restore,
    ; .frameloop, .eof, etc.) away from vid_run's own scope, breaking
    ; every earlier `jp .restore_badhdr`-style reference. `.l2setupret`
    ; stays a vid_run-scoped dot-local instead; vid_run_l2setup_body's
    ; own hop-back targets it via the qualified name `vid_run.l2setupret`.

 IFDEF DEBUG
    ; Owner gate-leg staged-entry ladder (SP14a T4 follow-up): Stage 1
    ; is "open+header+display setup+isolation ONLY" - display/palette/
    ; isolation are already fully done by the l2setup_body hop just
    ; above (which also skipped the copper init for stages 1-3 - see
    ; that body's own gate); nothing below this point (CTC arm, the
    ; frame loop, copper pokes) may run for stage 1, so it exits here,
    ; before any of that starts. vidStageFrameCnt is reset here (not at
    ; assemble time only - VID_PAGE is banked, not re-initialized
    ; between calls) regardless of stage, since every path that reaches
    ; this point either needs it fresh (stage 3) or doesn't care (0/4).
    xor a
    ld (vidStageFrameCnt), a
    ld a, (vidStageLimit)
    cp 1
    jr nz, .stg1cont
    ld c, 1
    jp .stagegate
.stg1cont:
 ENDIF

    ; --- CTC retune: vidCtcTc was already computed cold, in vid_run_
    ; l2setup_body above (table-driven from the live video-timing mode
    ; and the header's own audio channel count - a pure data lookup, no
    ; self-modifying code, so it is 100% safe pre-arm; moved there
    ; purely to save hot-page bytes, the SAME already-open cold hop, no
    ; new one). Both NXV tables (vidCtcTcNxvMono/Stereo) land CW16 on
    ; EVERY video mode - no sentinel/CW256 branch needed (unlike the old
    ; MakeVid-era fmt0/1 table). Mirrors aud_smp_start's exact CTC
    ; program sequence (unknown-state double reset, control word, time
    ; constant), stub patched BETWEEN the control word and the time
    ; constant (loading the TC starts the timer), same ordering rule
    ; every prior video task used. ---
    ld bc, AUD_CTC_PORT
    ld a, AUD_CTC_RESET
    out (c), a
    out (c), a                    ; double soft-reset (unknown -> clean)
 IFDEF DEBUG
    ; Owner gate-leg staged-entry ladder (SP14a T4 follow-up): Stage 2 is
    ; "no audio" - leave the CTC reset/stopped (never write CW16 or a
    ; time constant below), so the ISR never fires and no sound plays.
    ld a, (vidStageLimit)
    cp 2
    jr z, .stg2noarm
 ENDIF
    ld a, AUD_CTC_CW16
    out (c), a                    ; control word - timer not running yet

    ; --- IM2_CTC_STUB (ISR select) and both ISR bodies' end-marker were
    ; ALSO already patched cold, in vid_run_l2setup_body above (another
    ; VID_PAGE budget lever - same reasoning as the CTC table lookup
    ; just above: both writes target either RESIDENT memory (IM2_CTC_
    ; STUB) or VID_PAGE-resident code reached via the SAME MMU6-
    ; translated-write bracket that body already holds open, so nothing
    ; here needs to be hot). Both complete before this section's own
    ; time-constant write, below, starts the timer - the one real
    ; ordering rule (loading the TC starts the timer, so the stub/
    ; end-marker patches must land first) is honoured because the whole
    ; cold hop finishes and returns before this hot code ever runs. ---
    ; prime pacing so the first iteration's wait passes immediately (no
    ; prior frame is playing yet). IX is the resident play pointer for
    ; BOTH ISRs (mitigation - see the task report's Step 0: dedicating IX
    ; removes the mono ISR's HL push/pop AND its 16-bit memory round-trip;
    ; IX is proven free of mainline/other-ISR use throughout playback -
    ; im2_isr's fast path, taken whenever audEnable=0 as it is for the
    ; whole session, never touches ix/iy; the raw streaming internals are
    ; documented IX/IY-free by their own "golden rules 1 and 2" header).
    ; MOVED here, BEFORE the time-constant write below (owner gate-leg
    ; postmortem sweep, SP14a T4 follow-up): the old order wrote the TC
    ; first, arming the timer, and only THEN set IX - a narrow window
    ; where a premature tick (unlikely but not provably impossible) would
    ; read `(ix+0)` from whatever IX held on entry (stale/undefined),
    ; matching part of the observed hardware signature ("a split-second
    ; of corrupted sound... ISR ran garbage briefly"). Every shipped TC
    ; (72-132, CW16) gives a huge real-world margin before the first tick
    ; can possibly fire, so this was very unlikely to be the primary
    ; cause, but reordering costs nothing and closes the window outright.
    ld ix, vidAudBuf
    ld a, 1
    ld (vidAudDone), a

    ld a, (vidCtcTc)
    ld bc, AUD_CTC_PORT
    out (c), a                    ; time constant -> timer starts NOW,
                                   ; already dispatching the right ISR,
                                   ; with IX already valid
 IFDEF DEBUG
    jr .stg2armdone
.stg2noarm:
    ld ix, vidAudBuf               ; still prime IX/vidAudDone even with
    ld a, 1                        ; the CTC left stopped - .frameloop's
    ld (vidAudDone), a             ; own .pace check expects vidAudDone
                                    ; already true on the first iteration
.stg2armdone:
 ENDIF

.frameloop:
    ld a, (l2BackBank)             ; draw target = the currently-hidden
    add a, a                        ; back surface (idle during playback)
    ld (vidDrawPage), a
    call vid_stream_frame
    jp c, .eof                     ; jr (was in range pre-T4; the added
                                    ; fmt0/1 downsample loop between here
                                    ; and .eof pushed it out of jr's +127)
 IFDEF DEBUG
    ld a, VID_TL_OTHER             ; closes phase 1 (blit, stamped inside
    call vid_tl_stamp              ; vid_stream_frame at .nopalette below)
 ENDIF
    call vid_key_any
    ld a, 0
    jr z, .nokey
    ld a, 1
.nokey:
    ld (vidExitReq), a
 IFDEF DEBUG
    ld a, VID_TL_FLIPPACE          ; closes phase 4 (other: the key/exit
    call vid_tl_stamp              ; check just above)
 ENDIF
.pace:
    ld a, (vidAudDone)             ; wait for the CURRENTLY VISIBLE
    or a                            ; frame's audio to finish (pacing:
    jr z, .pace                    ; samples-per-frame count exhausted)
    ; launch the frame just streamed: copy the landing-page audio into
    ; the ISR-resident buffer (safe with no DI - see video_ctc_isr's own
    ; header for why a torn read here is at most one imperceptible tick).
    ; SP14a T4: FULL RATE, no decimation - a plain LDIR of vidABytesReal
    ; bytes (mono or stereo alike, channel-agnostic: it is just a byte
    ; count either way). Deletes the old 2:1/3:1 downsample loops
    ; entirely - NXV's own header-driven audio sizing (nextdaad.inc's
    ; NXV_RATE_STEREO/MONO) makes them unnecessary.
    call data_save
    ld a, (vidAudPoolPage)
    call data_map_page
    ld hl, DATA_WINDOW
    ld de, vidAudBuf
    ld bc, (vidABytesReal)
    ld a, b                       ; owner addendum ("convict the trampler"
    or c                          ; follow-up, belt-and-braces): BC=0 would
    jr z, .noaudcopy              ; wrap to a 65536-byte LDIR and obliterate
    ldir                          ; VID_PAGE - nxv_open_body already rejects
.noaudcopy:                       ; a zero header field, so this never fires
    call data_restore             ; on a validated file; guards the class.
    ld ix, vidAudBuf
    xor a
    ld (vidAudDone), a
 IFDEF DEBUG
    ; Stage 6 (fresh-eyes wave): real frame + audio copy-out ONLY, then
    ; stop - no palette apply, no flip. vidErrCode already reads clean
    ; here (the pixel serve just proved CF clear, above, or .eof would
    ; already have diverted away) - no extra capture needed.
    ld a, (vidStageLimit)
    cp 6
    jr nz, .sub6skip
    ld c, 9
    jp vid_run.stagegate
.sub6skip:
 ENDIF
    ; SP14a T2: palette EDIT (invisible write to the currently NON-
    ; displayed Layer 2 palette bank) - MOVED here, ahead of both flip
    ; pokes below (pre-SP14a this ran AFTER the NR $12 write, into the
    ; SAME bank being scanned out - the ~0.4ms race that caused the
    ; sparkle, sp13-task-4-report.md's addendum). It must finish before
    ; EITHER flip poke fires (NR $43 bit 2 or NR $12 - see the flip
    ; block below for why both, not just one) so the 256-entry write
    ; happens while the OLD frame is still fully, consistently on screen
    ; (old pixels under the old palette, nothing changing) instead of
    ; being visible mid-write. Still the palette streamed EARLIER this
    ; frame (resident at vidAudPoolPage+1, untouched since) - same "apply
    ; late, not at read time" reasoning as before (vid_stream_frame's own
    ; header), just applied to the hidden bank instead of the live one.
 IFDEF DEBUG
    ld a, VID_TL_PALETTE            ; closes phase 3 (flip/pace-wait: the
    call vid_tl_stamp               ; .pace spin + full-rate copy-out -
 ENDIF                               ; SP14a T2 moved the flip swap/NR $12
                                     ; write out of this phase, see below)
    ld a, (vidPalFlag)
    or a
    call nz, vid_apply_palette
 IFDEF DEBUG
    ld a, VID_TL_OTHER              ; closes phase 2 (palette apply, or
    call vid_tl_stamp               ; ~0 for non-palette formats)
    ; Stage 7 (fresh-eyes wave): + vid_apply_palette, then stop - no
    ; flip (stage 8 would be +flip, which is VSTG2 itself).
    ld a, (vidStageLimit)
    cp 7
    jr nz, .sub7skip
    ld c, 10
    jp vid_run.stagegate
.sub7skip:
 ENDIF
    ; owner fix (parity-chain audit, "PALETTE SPARKLE + MAGENTA
    ; REGRESSION"): REVERTS the SP14a T4 copper-poke flip back to T2's
    ; direct CPU nextreg NR_L2_BANK/NR_PAL_CTRL writes (git ffc5350) -
    ; the proven, hardware-confirmed choreography. The copper flip was
    ; not just deferred-by-a-frame-sometimes; it was ACTIVELY UNSAFE:
    ; the dev guide's own Copper chapter states MOVE fires unconditionally
    ; every field once CPC reaches it ("FRAME mode... will start executing
    ; ... continue until CPC reaches 1023... stop if HALT is encountered
    ; ... auto-wrap on every vertical blank") - the copper's own NR $43
    ; MOVE (nextdaad.inc's NXV_COPPER_LINE, line 257) fires EVERY field,
    ; unconditionally, using whatever data byte currently sits in copper
    ; RAM. vid_apply_palette (above) ALSO writes NR $43 directly, 256
    ; times per call, to select which bank its own writes land in (the
    ; edit-target bit, bit 6) - a SECOND, independent writer to the same
    ; register the copper periodically reasserts. If line 257 is reached
    ; WHILE vid_apply_palette's loop is mid-flight, the copper's own MOVE
    ; overwrites bit 6 back to the "locked" (edit==display) state,
    ; silently redirecting the REMAINDER of that 256-entry loop into the
    ; LIVE bank instead of the hidden one - interleaved live/hidden
    ; writes, exactly sparkle, and left the JUST-flipped-to bank only
    ; partially written, exactly magenta on the next frame it's shown.
    ; T2 never had this hazard because its flip was a single, immediate,
    ; CPU-driven write with no independent hardware writer racing it.
    ; Restoring that exact choreography removes the race outright rather
    ; than trying to time around it. l2_flip_swap's own variable-swap
    ; logic is unchanged (duplicated here since overlay2 is unreachable
    ; while MMU7 = VID_PAGE). NR $12 takes the 16K bank number RAW
    ; (l2_mode_set/h_gfx.swap precedent, overlay2.asm) - no *2 here (that
    ; shift is ONLY for deriving an 8K MMU PAGE number, e.g. vidDrawPage
    ; above; NR $12 is not a page). vid_copper_init/vid_copper_poke are
    ; left defined (VID_PAGE2/VID_PAGE) but uncalled - see vid_copper_
    ; init's own header for the reintroduction note; vid_copper_poke
    ; itself is removed outright below (nothing calls it any more, and
    ; it was hot/VID_PAGE - budget win).
    ;
    ; SP14a T2: palette display-select (NR $43 bit 2) flips in lockstep
    ; with the pixel bank (NR $12) - both express the SAME "which buffer
    ; is live" decision, one for pixels, one for the palette that colours
    ; them; the edit above already made the target bank correct, so all
    ; that is left is to point the display at it. Palette-format-only
    ; (vidPalFlag != 0) - non-palette files never touch NR $43 bit 2, so
    ; vid_identity_palette's one programmed-at-entry bank stays the
    ; displayed one for the whole session (an unconditional flip here
    ; would show garbage/stale colour on every odd frame for identity-
    ; palette files, which were never programmed into the second bank).
    ld a, (vidPalFlag)
    or a
    jr z, .nopalflip
    ld a, (vidPalCtrl)              ; currently-displayed bank's NR43 value
    xor $44                         ; flip both edit- and display-target to
    ld (vidPalCtrl), a              ; the bank the edit above just wrote
    nextreg NR_PAL_CTRL, a
.nopalflip:
    ld a, (l2FrontBank)
    ld b, a
    ld a, (l2BackBank)
    ld (l2FrontBank), a
    ld a, b
    ld (l2BackBank), a
    ld a, (l2FrontBank)
    nextreg NR_L2_BANK, a
    ld a, (vidExitReq)
    or a
    jr nz, .restore
 IFDEF DEBUG
    ; Owner gate-leg staged-entry ladder (SP14a T4 follow-up): stages 2
    ; and 3 never reach the ordinary key/EOF-only loop exit above -
    ; they are time/frame-boxed so the ladder always completes on its
    ; own, even if something is subtly wrong. Stage 1 never reaches
    ; here at all (it exits before the frame loop starts, above).
    ld a, (vidStageLimit)
    or a
    jr z, .stagecont
    cp 4
    jr nc, .stagecont
    cp 2
    jr nz, .stage3cap
    ; Stage 2: exactly one frame was just streamed and flipped (a direct
    ; CPU write, above - the copper poke this comment used to reference
    ; is retired, see the flip block's own header) - hold it on screen
    ; ~2s (100 x 50Hz halt) with nothing further streamed or flipped,
    ; then exit. This IS "flip once, hold" - never loops back.
    ld b, 100
.stg2hold:
    halt
    djnz .stg2hold
    ld c, 2
    jp .stagegate
.stage3cap:
    ; Stage 3: keep the ordinary streaming/CPU-flip loop running (CTC
    ; audio armed, copper bypassed) for ~100 frames (~2-4s depending on
    ; profile fps), then exit - the ladder's own "+CTC audio, CPU
    ; flips" stage, time-boxed the same way stage 2 is.
    ld hl, vidStageFrameCnt
    inc (hl)
    ld a, (hl)
    cp 100
    jr c, .stagecont
    ld c, 3
    jp .stagegate
.stagecont:
 ENDIF
    jp .frameloop
 IFDEF DEBUG
; Owner gate-leg staged-entry ladder (SP14a T4 follow-up): shared hot
; micro-stub, reached (tail-jumped, never called - it never returns
; here) from all three stage-exit sites above, the stage-1 gate near
; .l2setupret, and the sub-ladder 2a/2b/2c gates inside vid_stream_frame
; (qualified `jp vid_run.stagegate`). In: C = stage/sub-stage number
; just completed. Out (to vid_stage_marker_body): D = vidErrCode's
; CURRENT value, read HOT (this stub runs on VID_PAGE, same page
; vidErrCode lives on, so no translation is needed) and passed via a
; register - deliberately sidesteps the "copy-across" lesson rather
; than needing it, exactly like C already does. Every call site is
; responsible for vidErrCode already holding the right value by the
; time it jumps here (0 for a clean sub-stage boundary; the real code
; on a bounded-error exit) - owner directive: "STGn OK ERR=xx" on
; every marker, not just a bare pass/fail. Hops cold to print (vid_
; stage_marker_body, VID_PAGE2), then falls straight into .restore -
; the SAME teardown every ordinary exit already uses (CTC-off/copper-
; stop are idempotent no-ops if this stage never armed/started them;
; vid_stream_close/L2-restore/bank-free/presentation-restore are all
; unconditionally correct regardless of which stage got this far).
.stagegate:
    ld a, (vidErrCode)
    ld d, a
    ld a, (vidDrawPage)              ; owner addendum: settle the walk's
    ld e, a                          ; own base with one printed byte -
                                      ; E survives the hop (ovl_map_page
                                      ; corrupts AF only), same idiom as
                                      ; C/D already use. Meaningless for
                                      ; stage 1 (exits before .frameloop
                                      ; ever sets it) - meaningful for
                                      ; every stage that reaches here.
    ld ix, (vidPixBlocks)            ; owner addendum ("convict the
                                      ; trampler" follow-up): vacuous-pass
                                      ; guard - a real serve always shows
                                      ; a nonzero PIXBLK here; IX is free
                                      ; (unused by anything in this stub)
                                      ; and survives the hop same as E.
    ld hl, vid_stage_marker_body
    push hl
    ld a, VID_PAGE2
    jp ovl_map_page
.stagegateret:
    jp .restore
 ENDIF
.eof:
 IFDEF DEBUG
    ; SP14a T3 fix wave (owner hardware leg, vply0 regression audit): A
    ; here is vid_stream_frame's own return-time value (unchanged by the
    ; `jp c,.eof` above, and by the IFDEF DEBUG vid_tl_stamp block that
    ; runs LATER in .frameloop - this is the funnel point BEFORE that).
    ; Capture it before the very next instruction (`ld a,(vidLoopMode)`)
    ; overwrites A. See vidErrCode's own declaration for the 0=clean-EOF/
    ; nonzero=real-error convention.
    ld (vidErrCode), a
 ENDIF
    ld a, (vidLoopMode)
    or a
    jr z, .drainlast               ; play-once: EOF ends it
    ; loop mode: EOF restarts from the beginning (never ends the loop
    ; except by keypress, per the brief). Key-checked here too - without
    ; this, a persistently empty/corrupt file would EOF on every reopen
    ; attempt with no frame ever reaching the ordinary per-iteration key
    ; check below, making the loop unkillable.
    call vid_key_any
    jr nz, .restore
    ; --- SP14a T3 wave 1: cached-filemap raw restart (playvid parity,
    ; T1's own "Loop behaviour" finding - a cheap rewind, never a full
    ; esxDOS file reopen). Replaces the old vid_stream_close/vid_open_
    ; video esxDOS round-trip AND the CTC-park bracket + `ld ix,vidAudBuf`
    ; re-seat that used to guard it (SP13 T3 B1/B2). NO esxDOS call
    ; anywhere in this path - the file handle stays open from the
    ; original vid_open_video (F_CLOSE happens only at vid_stream_close's
    ; final call, .restore below); vidFilemapBuf persists for the whole
    ; session, never re-captured.
    ;
    ; IX sweep (re-verified from source, not assumed): vid_win_close
    ; (Corrupts AF, BC, DE, HL - no IX), vid_raw_reset_cursor (Corrupts
    ; AF, DE, HL - no IX), vid_next_run (Corrupts AF, DE, HL - no IX),
    ; vid_win_open (Corrupts AF, BC, DE, HL - no IX; its own vid_mf_
    ; disable/vid_strm_start/vid_sd_cmd chain is IX-free too, T1c's own
    ; finding, confirmed here) - EVERY routine this restart calls is
    ; provably IX-free. The CTC stays ARMED and TICKING throughout: IX
    ; (the ISR's exclusive resident play pointer) is never touched, never
    ; re-seated - the B1/B2 hazard (mainline repointing IX to an esxDOS
    ; buffer the ISR then walks) cannot occur because nothing here ever
    ; loads IX with anything. Audio drains seamlessly into the restart:
    ; the ISR keeps replaying the still-resident last frame's buffer
    ; (holding at the end marker once reached, exactly as it already does
    ; at any other quiet moment) while this sequence runs; if the reopen
    ; finishes before the drain would have, there is no gap at all; if it
    ; takes longer, the held last sample continues until the next frame's
    ; audio replaces vidAudBuf at the following `.pace` relaunch - no
    ; hard silence, unlike the old park (which stopped the CTC outright
    ; for the whole reopen). This is also NOT a new hazard: vid_win_close
    ; and vid_win_open are the SAME pair the hot streaming path already
    ; calls constantly, mid-frame, while just as armed.
    call vid_win_close             ; release the current SD window (CMD12
                                    ; + deselect) - as today
    call vid_raw_reset_cursor      ; cursor -> file start (entry ptr,
                                    ; remain, run/tail state) - the SAME
                                    ; state vid_raw_setup+vid_stream_open
                                    ; left after the very first open
    call vid_next_run              ; load run 0's card address
    jr c, .restore                 ; defensive: empty map (should not
                                    ; happen - the same map just played)
    call vid_win_open              ; reopen at run 0 via the existing raw
                                    ; CMD18 path
    jr c, .restore                 ; defensive: card rejected the reopen
    ; owner fix ("LOOP RESTART BROKEN" audit): the cursor reset above
    ; rewinds to byte 0 of the FILE - the start of the 512-byte NXV
    ; header, not the first pixel-bearing block. The original open
    ; consumed the header via nxv_open's own vid_stream_read call,
    ; BEFORE the frame loop ever ran; this restart jumped straight to
    ; .frameloop with no equivalent skip, so the next vid_stream_frame
    ; read the header bytes themselves as if they were frame data
    ; (audio samples, palette, pixels) - garbled DAC output (the
    ; reported audio distortion) and a garbage Layer 2/palette write
    ; (the reported red screen). Fix: replay nxv_open's own 512-byte
    ; throwaway read (same call shape: A=vidAudPoolPage, DE=512),
    ; discarding the header block, before resuming - reusing the
    ; SAME already-proven vid_stream_read bookkeeping the original
    ; open relied on (run/remain state consumed exactly as normal
    ; streaming would, so no run-boundary drift accumulates over
    ; repeated loops). Its contract corrupts IX ("Corrupts AF, BC, DE,
    ; HL, IX") - unlike every OTHER call in this restart, which are all
    ; provably IX-free (see this block's own header) - so this ONE
    ; call is bracketed with DI/EI: the CTC keeps ticking (a pending
    ; tick just latches, hardware IM2, and fires the instant EI
    ; re-enables it) but the ISR cannot be DISPATCHED mid-call, so it
    ; can never read IX while this call is transiently corrupting it.
    ; IX is reseated to vidAudBuf (a known-valid resident buffer,
    ; matching the CTC-arm sequence's own priming, above) before EI, so
    ; even an immediately-pending tick reads a well-defined address.
    ; Brief (one 512-byte SD transfer, a few hundred microseconds) -
    ; far short of a hard-silence gap, unlike the CTC-park-the-whole-
    ; reopen approach this restart replaced (see this block's own
    ; header for why that was removed).
    di
    ld a, (vidAudPoolPage)
    ld de, 512
    call vid_stream_read
    ld ix, vidAudBuf
    ei
    jr c, .restore                 ; defensive: I/O error on the header
                                    ; block itself (should not happen -
                                    ; the same header just validated it)
    jp .frameloop
.drainlast:
    ; the last successfully streamed frame (if any) is already showing
    ; from the previous iteration's flip - just let its audio finish.
.waitlast:
    ld a, (vidAudDone)
    or a
    jr z, .waitlast
.restore:
    ; CTC off - mirrors aud_smp_stop's own teardown exactly. No prior
    ; value is restored (the registers are write-only): any FUTURE
    ; sample-start recomputes its own control word/TC via aud_ctc_params
    ; as it always does, so there is nothing to reverse here beyond stop.
    ; The ISR cannot fire once this completes, so everything else this
    ; routine still needs to do (stub/L2/presentation restore, bank
    ; free, the DEBUG report, the final MMU6/7 restore) is safe to hop
    ; cold for (vid_run_restore_body, VID_PAGE2, below) - a real VID_
    ; PAGE budget lever (this tail was the single largest routine on the
    ; page). vid_stream_close stays hot first (below) since it is
    ; itself VID_PAGE-resident code, not reachable by a plain call from
    ; cold - genuinely a same-page call, unlike everything after it.
    ld bc, AUD_CTC_PORT
    ld a, AUD_CTC_RESET
    out (c), a
    out (c), a
    ld a, DAC_SILENCE
    out (DAC_PORT), a
    out (VID_DAC_LEFT), a          ; format-agnostic: always park all
    out (VID_DAC_RIGHT), a         ; three DAC ports used by either ISR
    ; copper: STOP suffices (the design doc's own guidance - program RAM
    ; is write-only and persists; nothing else in this codebase drives
    ; the copper, so there is no prior state to restore, only to stop).
    xor a
    nextreg NR_COPPER_ADDR_HI_CTRL, a
    call vid_stream_close
    ; hop cold for the stub/L2/presentation restore + bank_free trigger
    ; (vid_run_restore_body, VID_PAGE2, below), then back here for the
    ; DEBUG report (its OWN existing hot/cold/hot mechanism, unchanged)
    ; and the final MMU6/7 restore.
    ld hl, vid_run_restore_body
    push hl
    ld a, VID_PAGE2
    jp ovl_map_page
.restore_tail:
 IFDEF DEBUG
    ; Owner gate-leg staged-entry ladder (SP14a T4 follow-up): Stage 4
    ; ("full, copper") exits through this SAME ordinary path every non-
    ; ladder playback already uses (key/EOF), so it needs no stage-gate
    ; of its own - reaching here at all, followed by the timeline report
    ; below (which only ever prints after a fully clean teardown), is
    ; already the "ends clean" evidence. The one addition is a matching
    ; "STG4 OK" marker for ladder-convention consistency with STG1-3 -
    ; printed inline (dbg_at/dbg_puts are RESIDENT, no cold hop needed
    ; for a plain string literal that can live right here, hot).
    ld a, (vidStageLimit)
    cp 4
    jr nz, .stg4nomark
    ld b, 22
    ld c, 0
    call dbg_at
    ld hl, msgStg4
    call dbg_puts
    ld a, (vidErrCode)             ; owner directive: every marker shows
    call dbg_hex8                  ; ERR, not just a bare pass/fail
.stg4nomark:
    ; SP14a T1: the frame-timeline report - fully torn-down playback only
    ; (CTC parked/stub restored, DAC parked, L2/NR state restored) - no
    ; window/ISR constraint on printing here. Hops to VID_PAGE2 and back
    ; (vid_tl_report's own header) - MMU7 == VID_PAGE again by the time
    ; it returns, so the plain MMU6/7 restore below is unaffected.
    call vid_tl_report
 ENDIF
    ld a, (vidSvMmu6)
    nextreg NR_MMU6, a
    ld a, (vidSvMmu7)
    nextreg NR_MMU7, a
    ret
.restore_badhdr:
    ; nxv_open rejected the header - reached AFTER bank_alloc but BEFORE
    ; any CTC/Layer2/presentation/copper state was touched, so only the
    ; bank and the sample-freeze need reversing (matches the old vid_
    ; classify badfmt path's own scope, just relocated here since header
    ; validation itself moved into vid_run - see this routine's header).
 IFDEF DEBUG
    ; SP14a T4 owner follow-up (VID_PAGE budget, post-VIDBENCH-retirement):
    ; hopped cold - same pre-arm reasoning as this label's own header.
    ld hl, vid_run_badfmt_body
    push hl
    ld a, VID_PAGE2
    jp ovl_map_page
.badfmtret:
 ENDIF
    ld a, (vidAudPoolBank)
    call bank_free
    jr .restore_noplay_tail
.restore_noplay:
    ; reached only if bank_alloc failed - CTC/stub/L2/presentation were
    ; never touched, so only the freeze needs reversing (no bank to free
    ; either - falls into the SAME tail .restore_badhdr shares, below).
.restore_noplay_tail:
    ld a, (vidSvAudEnable)
    ld (audEnable), a
    call vid_stream_close
    ret

; Stream one frame's worth of data into: the pool landing page (audio,
; padded to a block multiple - vidABytesPad, header-derived) always at
; vidAudPoolPage; the palette block (512B, vidPalFlag files only) at
; vidAudPoolPage+1, a DIFFERENT page so it cannot overwrite the audio;
; and the pixel surface - vid_stream_pixels_flat (mode-0 always, or
; mode-1 at native height - zero column bookkeeping) or vid_stream_
; pixels_gap (mode-1, letterboxed height - the runtime column-gap loop),
; selected by vidGapNeeded (nxv_open's own derivation, see either
; routine's own header for the geometry reasoning).
;
; Palette-flag frames have their palette READ here but deliberately NOT
; APPLIED here - vid_apply_palette runs later, from vid_run's flip
; section, synchronised with the pixel-bank flip (see that call site's
; own comment for why: NR $43=PAL_L2_FIRST is "edit + active display",
; the SAME palette that is CURRENTLY ON SCREEN, so applying it
; immediately here would recolour the STILL-VISIBLE previous frame's
; pixels for this whole routine's own run time, every frame). The
; landing page holding the raw palette bytes is not reused for anything
; else before that call, so deferring the READ's raw bytes costs nothing.
;
; Out: CF clear = the whole frame streamed; CF set = end of file (the
; audio read was short - encoder-produced files are truncated to a whole
; number of frames, so EOF always lands here, never mid-frame) or a
; genuine read error - both treated identically by the caller. Corrupts
; everything.
vid_stream_frame:
 IFDEF DEBUG
    ld a, VID_TL_STREAM              ; closes phase 4 (other: the tail of
    call vid_tl_stamp                ; the previous iteration - exit-flag
 ENDIF                                ; check, loop-back, this call's own
                                      ; overhead) and increments vidTlFrames
    ld de, (vidABytesPad)
    ld (vidAudReadLen), de
    ld a, (vidAudPoolPage)
    call vid_stream_read
    jp c, .eof                    ; jp: .eof is now past jr's range (the
                                   ; sub-ladder gates grew this routine)
    ld hl, (vidAudReadLen)
    or a
    sbc hl, bc
    jr z, .audfull                ; exact match - not the short-read/EOF
                                   ; case; DO NOT insert anything between
                                   ; the sbc above and this jr - the Z
                                   ; flag it tests must survive untouched
 IFDEF DEBUG
    ; this IS the documented-normal short-read EOF (encoder-produced
    ; files are truncated to a whole number of frames, so a short AUDIO
    ; read - never a mismatched palette/pixel read - is the expected
    ; end-of-file signal). It carries no real error code (A here is
    ; whatever vid_stream_read's own success path left over) - force it
    ; to 0 so vid_run's .eof capture reports ERR=00 for the expected
    ; case, leaving genuine VID_ERR_*/esxDOS codes (from THIS call's own
    ; CF-set .eof branch above, or any .err branch below) visibly nonzero.
    xor a
 ENDIF
    jp .eof
.audfull:
    ; VS2A retired (owner follow-up 4, VID_PAGE budget - it had already
    ; served its purpose: proved audio+pad consumption clean before the
    ; fresh-eyes wave redirected the search to the serve loop/post-frame
    ; block instead). git history holds the code.
    ; palette-flag files only - streamed here, NOT applied (see this
    ; routine's header): vid_run's flip section applies it (vidAudPool
    ; Page+1 still holds it, untouched).
    ld a, (vidPalFlag)
    or a
    jr z, .nopalette
    ld a, (vidAudPoolPage)
    inc a                          ; upper 8K of the same bank
    ld de, NXV_PAL_BYTES
    call vid_stream_read
    jp c, .err                    ; jp: .err is past jr's range (the
                                   ; sub-ladder gates grew this routine)
    ld hl, NXV_PAL_BYTES
    or a
    sbc hl, bc
    jp nz, .err
.nopalette:
 IFDEF DEBUG
    ld a, VID_TL_BLIT               ; closes phase 0 (stream: the audio
    call vid_tl_stamp               ; read, plus the palette read above)
 ENDIF
    ; VS2B retired (owner follow-up 4, VID_PAGE budget) - see VS2A's own
    ; retirement note above; git history holds the code.
    ld a, (vidGapNeeded)
    or a
    jp nz, .gappath                ; jp: .gappath is now past jr's range
                                    ; (VS2F's own gate grew this routine)
 IFDEF DEBUG
    ; VS2C/VS2D retired (fresh-eyes round 2, VID_PAGE budget) - both
    ; superseded by VS2F/VS2G's own cleaner deconfounder program below.
    ; git history holds the code/verbs.
    ;
    ; VS2F (stage 8) / VS2G (stage 9, round 3): the deconfounder pair -
    ; both read 10 x $2000 via the OLD PROVEN .monopix shape (fixed-size
    ; read + a counted loop), bypassing vid_stream_pixels_flat's own
    ; block-based bookkeeping entirely, sharing ONE loop body. VS2F
    ; advances vidPxPage every iteration (the same 10-page walk VSTG2
    ; itself does); VS2G reads the SAME page 10 times over (NO advance
    ; at all) - splitting "10 sustained vid_stream_read calls in one
    ; CMD18 window" from "the MMU6 page walk between them" as two
    ; independent suspects for the first time (VS2D/VS2E only ever
    ; varied direct-read-vs-loop AND page-count at once). B is corrupted
    ; by vid_stream_read (raw path: "Corrupts AF, BC, DE, HL, IX") and
    ; so is DE - the standing ini-decrements-B lesson's own sibling for
    ; this call - so the loop counter lives in vidPxBlocksLeft's low
    ; byte instead (scratch-reused). Replaces vid_stream_pixels_flat's
    ; own call entirely when either is active - never both.
    ld a, (vidStageLimit)
    cp 8
    jr z, .sub89go
    cp 9
    jr nz, .sub89skip
.sub89go:
    ld a, (vidDrawPage)
    ld (vidPxPage), a
    ld a, 10
    ld (vidPxBlocksLeft), a
.sub8loop:
    ld a, (vidPxPage)
    ld de, $2000
    call vid_stream_read
    jr c, .sub8err
    ld a, (vidStageLimit)
    cp 9
    jr z, .sub8noadv                ; VS2G: same page every time
    ld hl, vidPxPage
    inc (hl)
.sub8noadv:
    ld hl, vidPxBlocksLeft
    dec (hl)
    jr nz, .sub8loop
    xor a
    jr .sub8done
.sub8err:
.sub8done:
    ld (vidErrCode), a
    ld c, 11                        ; assume VS2F (stage 8)
    ld a, (vidStageLimit)
    cp 9
    jr nz, .sub89mark
    ld c, 12                        ; VS2G (stage 9)
.sub89mark:
    jp vid_run.stagegate
.sub89skip:
 ENDIF
    ld a, (vidDrawPage)
    ld hl, (vidPixBlocks)
    ld (vidPxBlocksLeft), hl
    call vid_stream_pixels_flat
 IFDEF DEBUG
    ; VS2E (fresh-eyes wave, stage flag 5): stop HERE, immediately after
    ; the REAL vid_stream_pixels_flat loop (all chunks, the genuine
    ; multi-advance walk VS2C/D's own direct reads never exercised) -
    ; before ANY post-frame processing (audio copy-out/palette apply/
    ; flip) ever runs. Captures the REAL CF/error, not a synthetic ok -
    ; this is the loop-vs-postframe discriminator.
    push af
    ld a, (vidStageLimit)
    cp 5
    jr nz, .sub5skip
    pop af
    jr nc, .sub5ok
    ld (vidErrCode), a
    jr .sub5done
.sub5ok:
    xor a
    ld (vidErrCode), a
.sub5done:
    ld c, 8
    jp vid_run.stagegate
.sub5skip:
    pop af
 ENDIF
    jr c, .err
    or a
    ret
.gappath:
    ld a, (vidDrawPage)
    call vid_stream_pixels_gap
    jr c, .err
    or a
    ret
.eof:
    scf
    ret
.err:
    scf
    ret

; ---------------------------------------------------------------------
; vid_stream_pixels_flat - the flat serve (spec's headline design): mode
; 0 always (row-linear, no stride mismatch at ANY height), or mode 1 at
; native height (256 - the column stride itself, so no column-boundary
; gap exists either). ZERO column/block bookkeeping beyond vid_stream_
; read's own proven register-resident fast path (the SAME general-
; purpose reader the old mono path always used) - reused here in $2000
; (one MMU page)-sized chunks, generalized to an arbitrary total block
; count (header-derived vidPxBlocksLeft, primed by the caller) instead of
; a fixed per-format page count, and an arbitrary starting page. This
; REPLACES the old 15-case static-unroll blit entirely - the "T3 case
; table dies" per the spec: a block-aligned native-stride format needs no
; case table AND no runtime chunk bookkeeping, just a linear reader.
;
; In: A = starting destination 8K page; vidPxBlocksLeft (dw) = total
;     512-byte blocks remaining this frame (primed by vid_stream_frame
;     from the header's own vidPixBlocks).
; Out: CF clear = all pixel blocks streamed; CF set = error (A = code -
;      vid_stream_read's contract, or VID_ERR_SHORT on a short read - a
;      genuine anomaly here, unlike a short AUDIO read, which is the
;      documented-normal EOF signal - see vid_stream_frame's own header).
; Corrupts everything.
vid_stream_pixels_flat:
    ld (vidPxPage), a
.loop:
    ld hl, (vidPxBlocksLeft)
    ld a, h
    or l
    jr z, .done
    ld de, 16                      ; 16 blocks = one full $2000 page
    or a
    sbc hl, de
    jr nc, .fullpage               ; >=16 blocks left: take a full page
    add hl, de                     ; <16 blocks left: undo the sbc above
                                    ; (exact regardless of the borrow) to
                                    ; recover the real remaining count -
                                    ; the partial final page
    jr .havecount
.fullpage:
    ld hl, 16
.havecount:
    ld (vidPxBlocksReq), hl
    ; byte count = blocksReq*512 (blocksReq is 1-16, so the result is
    ; 512-8192, safely within a word) - L holds the count (H is 0 for
    ; these small values); DE = L*256, then doubled once more = L*512.
    ld d, l
    ld e, 0
    sla e
    rl d
    ld (vidPxChunkBytes), de
    ld a, (vidPxPage)
    call vid_stream_read
    jr c, .err
    ld hl, (vidPxChunkBytes)
    or a
    sbc hl, bc
    jr nz, .shortread               ; short/EOF read here is a genuine
                                     ; error - see this routine's header
    ld hl, (vidPxBlocksLeft)
    ld de, (vidPxBlocksReq)
    or a
    sbc hl, de
    ld (vidPxBlocksLeft), hl
    ld hl, vidPxPage
    inc (hl)
    jr .loop
.done:
    or a
    ret
.shortread:
    ld a, VID_ERR_SHORT
    scf
    ret
.err:
    scf
    ret

; ---------------------------------------------------------------------
; vid_stream_pixels_gap - mode-1 letterboxed column blit (content height
; < native 256 - a Layer 2 hardware property, not something the format
; can avoid: mode 1's column stride is FIXED at 256 bytes regardless of
; content height, so any height < 256 needs a per-column destination
; jump). Generalizes the pre-SP14a "dynamic" column-blit design (the
; chunk=min(colRemain,blkRemain) technique, proven correct in production
; before the SP14a T3 wave-2 case-unroll replaced it for the single
; highest-pressure format) to an ARBITRARY, header-derived column height
; instead of a compile-time-fixed one - a genuine architectural
; requirement here, not a simplification: NXV's own "HEIGHT IS A HEADER
; PARAMETER" design (the spec's own framing) means the column height is
; runtime DATA, so an assemble-time case-unroll (the old T3 technique) is
; not even possible for this path - only N0 (native height, zero gap)
; gets the true flat/zero-bookkeeping design (vid_stream_pixels_flat,
; above).
;
; SP14a gap-blit "full burst" wave: ZEsarUX-vs-hardware differential
; measurement (2026-07-23) found the CPU loop cycle-exact clean against
; the round-2 accounting (217T/column measured vs predicted) - the
; remaining ~14ms/frame gap is SILICON-ONLY: a real SD SPI burst reads at
; ~26T/byte effective in 64-byte-or-shorter bursts (the RTL's between-
; byte shifter halt/restart latency dominates short bursts), not the
; nominal 16T; the flat path's own sustained 1264KB/s (22.1T/byte, its
; 256-ini runs) is the measured silicon floor for LONG bursts. Chunk
; transfers here now go through vid_gap_xfer (below) - ONE fully
; unrolled 192-`ini` run (192 = N3's own max chunk, 24 units x 8 bytes;
; N4's 120-byte max chunk is served by ENTERING the same run partway
; through, below), entered via a computed offset so the run for ANY
; chunk size 1-24 units is one unbroken burst with ZERO loop-control
; instructions between bytes - the fragmentation the old 64-group+8-
; remainder design paid for at every group boundary is gone entirely.
;
; REGISTER RESIDENCY (SP14a gap-blit redesign wave, unchanged by this
; wave - GAPSPINS convicted the token-wait itself innocent, 2.0 polls/
; block; the overage was CPU-side per-block/per-column bookkeeping,
; closed with the flat path's own economics, vid_stream_read_raw above,
; as the template; this wave only replaces the transfer PRIMITIVE, not
; the residency design around it): run/block/column state lives in the
; ALTERNATE register set for the WHOLE call, spilled to memory only at
; genuinely rare boundaries (a page switch, an error, or routine entry/
; exit). Verified safe against every routine this loop calls: grepped,
; NONE of them (vid_col_block_start/end/newblock/blockdone, vid_win_
; open/close, vid_next_run, vid_remain_*, data_save/map_page/restore)
; contains a single `exx` anywhere in this whole file outside vid_
; stream_read_raw/vid_fast_spill - the alt set survives every one of
; these calls automatically, by construction. Also verified against both
; live ISRs: im2_isr's fast frame-tick path (the only im2_isr path
; reachable during video playback - audEnable is frozen at 0 for the
; whole session) push/pops AF/HL and never touches BC/DE/IY/the alt set
; at all; video_ctc_isr's own header already states "Preserves the
; alternate set (never touches it)" and touches only AF/IX - IY (newly
; used this wave, see vid_gap_xfer) is untouched by both.
;
;   MAIN:      HL = live destination pointer (the MMU6-window address
;              the next byte lands at) - resident across the WHOLE loop,
;              never round-tripped through memory except at the sync
;              points below (page switch, entry, error - for debugger
;              visibility, not correctness: nothing reads vidGapDest
;              back into this routine).
;   ALTERNATE: BC = columns remaining, whole frame (320 down to 0)
;              D  = 8-byte units remaining in the currently open SD
;                   block (0 = no block open)
;              E  = 8-byte units remaining in the CURRENT column
;              L  = vidColUnits, cached once at entry (a per-FILE
;                   constant) - reset target for E when a column
;                   finishes; nothing else needs it this wave (the old
;                   "is this a fresh column" fast/slow split is gone -
;                   every chunk now goes through the SAME transfer, see
;                   below, so there is nothing left to dispatch on)
;              H  = unused
; .loop is entered/left with MAIN active and HL correct; every `exx`
; pair below is balanced within its own basic block (rubric-1 sweep in
; the task report traces each one by hand) - EXX never touches flags, so
; a Z/C test computed on one side of an `exx` survives to be branched on
; the other side unchanged (used deliberately below to fold what would
; otherwise be two round trips into one).
;
; In: A = starting destination 8K page; header: vidColUnits (height/8,
;     nxv_open's own derivation - the gap blit's fixed per-column unit
;     count for this file, <= 24 - vid_gap_xfer's own 192-`ini` run
;     bound; see its header). Column count is 320 (NXV_WIDTH_MODE1) for
;     every shipped mode-1 letterbox profile (N3/N4 - full width, no
;     pillarbox); a hardcoded 320 is used rather than a header re-read
;     since nothing this wave ships needs any other mode-1 width.
; Out: CF clear = all columns written; CF set = error (A = code).
; Corrupts everything.
vid_stream_pixels_gap:
    ld (vidPxPage), a
    call data_save
    ld a, (vidPxPage)
    call data_map_page
    ld hl, DATA_WINDOW              ; MAIN: HL = dest, resident from here
    ld (vidGapDest), hl              ; entry sync (debugger visibility -
                                       ; see the routine header)
    ld a, (vidColUnits)
    exx                                ; -> alt: seed the whole-run state
    ld bc, 320                           ; colsLeft (NXV_WIDTH_MODE1)
    ld d, 0                                ; blkLeft = 0: forces a block-
                                             ; open on the very first .loop
    ld e, a                                   ; colLeft = colUnits (the
                                                ; first column starts fresh)
    ld l, a                                     ; colUnits, cached for the
                                                  ; whole call (see header)
    exx                                            ; -> main
; For the owner's debugger: a breakpoint at .loop lands at the top of
; every column/chunk decision with MAIN active and HL = the live dest
; for whatever comes next; `exx` once in the shadow-register view to see
; colsLeft(BC)/blkLeft(D)/colLeft(E)/colUnits(L).
.loop:
    exx
    ld a, b
    or c
    jp z, .alldone_x                 ; colsLeft == 0: whole frame served
                                       ; (jp: .alldone_x is past jr range)
    ld a, d
    or a
    jr nz, .haveblk_x                  ; block already open
    exx                                   ; -> main: block_start needs HL
    call vid_col_block_start                ; preserves HL; opens/waits
                                              ; token; alt set untouched
                                              ; (see the header)
    jp c, .err
    exx                                        ; -> alt
    ld d, 64                                     ; fresh block: 512/8 units
.haveblk_x:
    ; chunk = min(colLeft, blkLeft) - every transfer, fresh column or a
    ; straddle's continuation alike, goes through the SAME computation
    ; and the SAME transfer primitive now (vid_gap_xfer's own full-burst
    ; design serves any 1-24-unit chunk equally well, so the old fast/
    ; slow split - which existed only to pick between two DIFFERENT
    ; transfer primitives - has nothing left to dispatch on).
    ld a, e                                        ; colLeft
    cp d                                             ; vs blkLeft
    jr c, .havechunk_x                                 ; colLeft smaller:
                                                          ; chunk = colLeft
    ld a, d                                              ; blkLeft smaller
                                                           ; or equal: chunk
                                                           ; = blkLeft
.havechunk_x:
    ld h, a                                                ; H' = chunk
                                                             ; (units, 1-24)
    ld a, e
    sub h
    ld e, a                                                   ; colLeft -=
                                                                ; chunk
    ld a, d
    sub h
    ld d, a                                                      ; blkLeft
                                                                   ; -= chunk
    ld a, h                                                        ; A =
                                                                     ; chunk
    exx                                                               ; ->
                                                                        ; main
    call vid_gap_xfer                ; HL advances by chunk*8 bytes (the
                                       ; full-burst transfer, below);
                                       ; corrupts AF, BC, DE, IY
    exx                                 ; -> alt
.aftertransfer_x:
; For the owner's debugger: a breakpoint here catches every block/
; column-close decision, ALT active - D = new blkLeft, E = new colLeft.
    ld a, d
    or a
    exx                                ; -> main (HL needed either way,
                                         ; whether the call below fires)
    call z, vid_col_block_end            ; preserves HL + the alt set
    exx                                     ; -> alt
    ld a, e
    or a
    jr nz, .loop_from_alt                     ; column not finished (a
                                                ; straddle just closed its
                                                ; block, more to come next
                                                ; block): straight back,
                                                ; dest already correct
    dec bc                                       ; column finished NOW
    ld e, l                                        ; colLeft = colUnits:
                                                      ; the NEXT column
                                                      ; starts fresh (bug
                                                      ; caught by hand-
                                                      ; trace last wave:
                                                      ; without this the
                                                      ; next .haveblk_x
                                                      ; would see colLeft
                                                      ; still 0)
    exx                                             ; -> main: advance dest
    xor a                                             ; to the next 256-
    ld l, a                                            ; aligned column
    inc h                                              ; base, unconditio-
                                                         ; nally - valid
                                                         ; because a gapped
                                                         ; column NEVER
                                                         ; lets `ini` carry
                                                         ; L into H on its
                                                         ; own (height<256
                                                         ; means L never
                                                         ; reaches 256
                                                         ; within one
                                                         ; column)
    exx                                                  ; -> alt: page
                                                           ; switch due?
    ld a, c                                                ; colsLeft's own
                                                             ; low byte -
                                                             ; 320=10*32, so
                                                             ; "mod 32==0"
                                                             ; recurs every
                                                             ; 32nd column
                                                             ; with no
                                                             ; separate
                                                             ; counter
    and 31
    exx                                                       ; -> main
    jp nz, .loop
    ; page switch (rare, ~1/32 columns - afford the full memory-based
    ; sequence here; data_save/map_page/restore corrupt AF only per their
    ; own headers, so both HL and the alt set survive untouched)
    ld (vidGapDest), hl                                           ; sync
    call data_restore
    ld hl, vidPxPage
    inc (hl)
    call data_save
    ld a, (vidPxPage)
    call data_map_page
    ld hl, DATA_WINDOW
    jp .loop
.loop_from_alt:
    exx
    jp .loop
.alldone_x:
    exx
    jp .alldone
.alldone:
    call data_restore
    or a
    ret
.err:
    ld (vidGapDest), hl        ; debugger-visible: dest as of the failed
                                ; block-open attempt (vid_col_block_start's
                                ; own contract preserves HL even on error)
    push af
    call data_restore
    pop af
    scf
    ret

; Full-burst gap-column transfer (SP14a "maximize burst length" wave -
; see vid_stream_pixels_gap's own header for the ZEsarUX-vs-hardware
; finding this responds to). In: A = chunk (8-byte units, 1-24 - the
; caller's own min(colLeft,blkLeft), never wider than vidColUnits <= 24
; for any shipped or future mode-1 letterbox profile whose height stays
; under the native 256 - see nxv_open's own header derivation). HL =
; live destination pointer (preserved, advanced by chunk*8 bytes). Out:
; HL advanced. Corrupts AF, BC, DE, IY.
;
; ONE shared 192-`ini` unrolled run (192 = 24 units x 8 bytes, N3's own
; max chunk) serves every chunk size via a COMPUTED ENTRY POINT partway
; through the run, not a loop: entry = run_end - chunk*16 (chunk*8 bytes
; needed x 2 code-bytes/`ini`), so exactly chunk*8 bytes transfer as one
; unbroken burst regardless of where the entry lands - N4's own 120-byte
; (15-unit) max chunk enters 72 `ini`s in, N3's 192-byte (24-unit) max
; enters at the very start (chunk=24 -> entry = run_end - 384 = run_
; start). A straddle's smaller residues (1-23 units) enter further in,
; the identical mechanism. Rubric 2: the run itself consumes NO loop
; register at all (no B, no E, no counter of any kind) - the byte count
; actually transferred is driven purely by the ENTRY OFFSET, not by any
; runtime decrement; B/E are free for other use across this call (both
; corrupted here as ordinary scratch, not as loop state).
;
; Entry-offset arithmetic: chunk*16 via Z80N `MUL D,E` (D=chunk, E=16,
; DE=D*E) - one instruction instead of four `add hl,hl` doublings, and
; leaves HL untouched throughout (dest is parked in BC while HL computes
; the entry address, then restored - `MUL D,E` needs D/E as its own
; operands, so dest cannot live there during the multiply). IY (not IX -
; IX is the video CTC ISR's own exclusive resident play pointer for the
; whole armed window, see this file's established IX/IY-free/IX-
; exclusivity invariant) carries the computed jump target so HL is free
; to hold dest again before the burst starts; IY is untouched by both
; ISRs live during playback (im2_isr's fast path and video_ctc_isr both
; verified AF/HL/IX-only, this routine's own header).
vid_gap_xfer:
    ld b, h                    ; park dest (BC) - MUL D,E needs D/E
    ld c, l
    ld d, a                      ; D = chunk (units)
    ld e, 16                       ; E = 16 (8 bytes/unit x 2 code-bytes/
                                     ; `ini`)
    mul d, e                         ; DE = chunk*16 = the run's own byte-
                                       ; skip from its start
    ld hl, .run_end
    or a
    sbc hl, de                         ; HL = entry address
    push hl
    pop iy                                ; IY = entry address
    ld h, b                                 ; dest restored
    ld l, c
    ld c, PORT_SPI_DAT
    jp (iy)                                   ; enter the run at the
                                                ; computed offset
.run_start:
    DUP 192
      ini                                        ; ~22T/byte silicon-
    EDUP                                         ; effective in this long
                                                  ; a burst (measured, see
                                                  ; the routine header) -
                                                  ; no loop-control
                                                  ; instruction anywhere
                                                  ; between these, by
                                                  ; design
.run_end:
    ret

; Ensure a fresh 512-byte SD block is ready to stream (window open, run
; available, data token seen) - mirrors vid_stream_read_raw's own
; .needstream/.haveblocks/vid_win_open/vid_next_run sequence, but leaves
; the 512 bytes UNCONSUMED (the caller's own INI bursts read them
; directly - vid_stream_pixels_gap, above, and VBENCH-FLAT/DMA below).
; Out: CF clear (a fresh block is ready); CF set = run/window/token error
; (A = code). Corrupts AF, BC, DE, HL.
vid_col_newblock:
    ld hl, (vidStrmRunBlocks)
    ld a, h
    or l
    jr nz, .open
    call vid_win_close
    call vid_next_run
    jr nc, .open
    ld a, VID_ERR_NOMAP
    scf
    ret
.open:
    call vid_win_open
    ret c                          ; CF set, A = VID_ERR_CMD (its contract)
    ; owner fix (gap-blit perf audit, item 5 follow-up): bounded retry,
    ; mirroring vid_read_block's own fix earlier this session - this
    ; token-wait was still unconditional/unbounded (a different copy
    ; from vid_read_block's, missed by that fix since it lives in a
    ; separate routine). A wedged card must not hang the gap path
    ; either. BC is free here (routine's own "Corrupts AF, BC, DE, HL").
.wt:
    ld bc, 0                       ; bounded retry: 65536 polls
.wtloop:
    in a, (PORT_SPI_DAT)
    inc a
    jr nz, .wtgot
    dec bc
    ld a, b
    or c
    jr nz, .wtloop
    ld a, $FF                      ; exhausted: synthesize a non-$FE byte
    jr .checktok                   ; so the existing bad-token path below
                                    ; fires unchanged
.wtgot:
    dec a
.checktok:
    cp $FE
    jr z, .ok
 IFDEF DEBUG
    ; SP14a T3 fix wave 2 (owner hardware leg, vply0 ERR=FD follow-up):
    ; stash the RAW byte the token-wait actually saw (A, still the real
    ; wire byte here - not yet overwritten by the VID_ERR_TOKEN sentinel
    ; below) - see vidErrByte's own declaration for the decode. Corrupts
    ; nothing else; A is about to be overwritten by the very next
    ; instruction regardless.
    ld (vidErrByte), a
 ENDIF
    ld a, VID_ERR_TOKEN
    scf
    ret
.ok:
    ; SP14a T4: the SP13/T3-era vidBlkRemain16 stamp (a timing-margin
    ; experiment carried since the T3 fix-wave-2 owner leg - see git
    ; history for the full ERR=FD investigation) is dropped here: the
    ; ACTUAL root cause of that regression was vid_xfer16n's own B/`ini`
    ; double-count bug (SP14a T3 fix wave 3, fixed in vid_xfer16n's own
    ; header below), not a timing margin - confirmed on hardware once
    ; that fix shipped. This is a clean-break rewrite (NXV scraps MakeVid
    ; compatibility entirely), so the now-fully-explained, register-level
    ; -dead experimental write is not carried forward.
    or a                           ; CF clear
    ret

; A completed 512-byte SD block's bookkeeping (CRC skip, run-block
; count, file-remain accounting) - the DATA itself was already consumed
; by the caller's own INI bursts, split across chunks. In: C = PORT_SPI_
; DAT (the caller's own port register, reused). Corrupts AF, BC, DE, HL.
vid_col_blockdone:
    in a, (c)                      ; skip the 2-byte CRC (playvid parity,
    nop                            ; matches vid_read_block's own skip)
    in a, (c)
    ld hl, (vidStrmRunBlocks)
    dec hl
    ld (vidStrmRunBlocks), hl
    ld de, 512
    jp vid_remain_sub              ; tail call

; vid_xfer16n (the old 16-byte-group INI burst primitive) is GONE - SP14a
; T4's pixel paths no longer need it (vid_stream_pixels_flat goes through
; vid_stream_read; vid_stream_pixels_gap's own transfer, above, now goes
; through vid_gap_xfer's single shared full-burst run, entered at a
; computed offset - no outer loop, no B/E counter at all, see that
; routine's own header) and its last remaining caller, VBENCH-FLAT, is
; retired (see vid_bench_pass_ret's own neighbouring comment). Historical
; note preserved because the lesson still governs vid_read_block's own
; .halfloop, above, the last transfer primitive in this file that DOES
; still loop: SP14a T3 fix wave 3 found that B CANNOT be an outer loop
; counter wrapped around a REPT-unrolled `ini` block - the Z80 `ini`
; instruction (ED A2) decrements B as part of its OWN semantics, so a
; trailing `djnz` on top of that double-counts. A is the outer counter
; there instead (that routine's own header explains why not E either) -
; `ini` never reads or writes A, so it is provably free.

; Shared per-block prologue: opens the next SD block (vid_col_newblock's
; own token-wait) and readies C=PORT_SPI_DAT, folding the push/pop-HL
; protection bracket and the post-newblock BC reload into ONE call site.
; In: HL = live destination pointer (preserved across the call). Out: CF
; clear, C=PORT_SPI_DAT, HL unchanged, ready for the caller's own `ini`
; bursts; CF set = error (A = code, HL still unchanged).
; Used by vid_stream_pixels_gap (above) and VBENCH-FLAT/DMA (below).
; Corrupts AF, BC, DE.
vid_col_block_start:
    push hl
    call vid_col_newblock
    pop hl
    ret c                          ; error: CF/A propagate, HL restored
    ld c, PORT_SPI_DAT             ; vid_col_newblock may have used BC
    ret                            ; CF clear (vid_col_newblock's own)

; Shared per-block epilogue: the same push/pop-HL protection bracket
; around vid_col_blockdone (CRC-skip + run-block-count + remain-subtract)
; that vid_col_block_start's own header describes. In/Out: HL preserved
; across the call (the only register ever kept live across a block
; boundary in this design - no chunk-size value is carried live across
; this call, see vid_stream_pixels_gap's own header). Corrupts AF, BC, DE.
vid_col_block_end:
    push hl
    call vid_col_blockdone
    pop hl
    ret

; Apply the 512-byte 9-bit palette just landed at vidAudPoolPage+1
; (palette-flag files only) to Layer 2. Called from vid_run's flip
; section, NOT from vid_stream_frame where it was read (see that
; routine's header).
;
; SP14a T2: writes the NON-displayed Layer 2 palette bank (the "back"
; palette buffer, invisible until vid_run's own flip toggles NR $43 bit 2
; - the SAME frame's display-select write, done separately right after
; this returns). vidPalCtrl always holds PAL_L2_FIRST or PAL_L2_SECOND
; (whichever bank is CURRENTLY on screen); XOR $40 flips only the edit-
; target field's top bit (bits 6-4: 001<->101) and leaves bit 2 (display)
; untouched - PAL_L2_FIRST XOR $40 = PAL_L2_EDIT_SECOND, PAL_L2_SECOND
; XOR $40 = PAL_L2_EDIT_FIRST (nextdaad.inc's own header verifies both).
; This is the "invisible write" the design note calls for - no scan-out
; race, since the bank being written here is never the one being shown.
;
; Dodges the TM_TRANSP_ATTR collision on EVERY entry's RGB byte (any
; source value == TM_TRANSP_ATTR is written as $FF instead) - the same
; per-entry technique l2_palette_load uses (overlay2.asm, duplicated here
; since overlay2 is unreachable cross-page during playback). UNLIKE
; l2_palette_load, this does NOT also force-stamp index TM_TRANSP_ATTR
; (254) to genuinely BE the transparent colour afterward: l2_palette_load
; safely reserves that one index because "no Rabenstein art uses pixel
; value $FE" - a guarantee that holds only for THIS project's own hand-
; converted picture assets, never established for third-party MakeVid
; video content, which has no reason to avoid index 254. Forcing it
; anyway would have made every pixel legitimately assigned that index
; punch through to the tilemap instead of showing its real colour - a
; real defect, found during the owner's format-4 hardware leg (garbled/
; wrong-coloured video; format 5's vid_identity_palette carried the same
; bug but its specific test content happened not to trigger it visibly).
; With the per-entry dodge alone, NO entry can ever equal TM_TRANSP_ATTR,
; so Layer 2's NR $14 compare (left at TM_TRANSP_ATTR, the engine-wide
; convention) can never match ANY video pixel - genuinely opaque, as
; intended, with no reserved/sacrificed index at all. Corrupts everything.
vid_apply_palette:
    call data_save
    ld a, (vidAudPoolPage)
    inc a
    call data_map_page
    ld hl, DATA_WINDOW
    ld a, (vidPalCtrl)
    xor $40                         ; edit the OTHER bank, display untouched
    nextreg NR_PAL_CTRL, a
    nextreg NR_PAL_INDEX, 0
    ld b, 0                        ; 256 iterations
.loop:
    ld a, (hl)
    inc hl
    cp TM_TRANSP_ATTR
    jr nz, .w1
    ld a, $FF
.w1:
    nextreg NR_PAL_VALUE9, a
    ld a, (hl)
    inc hl
    nextreg NR_PAL_VALUE9, a
    djnz .loop
    call data_restore
    ret

; Any-key test: A = 0 selects ALL 8 keyboard half-rows simultaneously via
; IN A,($FE) (playvid's own idiom) - a raw port read needs no cross-page
; hop, matching debug.asm's l2dbg_t_held precedent ("a raw port read
; rather than overlay0's key_scan, since that lives in an overlay this
; code has no reason to page in"). Out: Z set = no key down, NZ = some
; key down. Corrupts AF.
vid_key_any:
    xor a
    in a, ($FE)
    and %00011111
    cp %00011111
    ret

; Mono video audio ISR (SP13 T2, IX mitigation SP13 T3). Fires at 23.3kHz
; via CTC channel 0, installed by patching IM2_CTC_STUB for the whole
; playback. BANKING INVARIANT (doc 11's SMC/DMA hazard, applied to the
; ISR body itself, not just a patch site): this code is entered through
; the IM2 table's fixed JP at IM2_CTC_STUB, but the JP's OWN target
; address only resolves to THIS code as long as MMU7 stays mapped to
; VID_PAGE for the entire playback - vid_run never remaps MMU7 (freezing
; audEnable also stops the frame ISR's own MMU6/7 remap around aud_tick,
; interrupts.asm, which is exactly what makes this safe). Preserves the
; alternate set (never touches it, docs/Z80/02) - compatible with T1d's
; register-resident fast streaming loop, which relies on the same
; guarantee from both existing IM2 ISRs. Touches NO MMU slot (mirrors
; ctc_isr's own "resident ring, no MMU" discipline, interrupts.asm) -
; vidAudBuf lives in THIS page, always reachable while the invariant
; holds, so streaming's own MMU6 traffic can never race it. Hold-last at
; the final byte (ctc_isr's own precedent) until mainline refills and
; relaunches.
;
; T3 mitigation (task report Step 0): IX is the resident play pointer,
; NOT a plain memory variable reloaded/stored every tick (T2's original
; design) - this removes both the `push hl`/`pop hl` pair AND the 16-bit
; memory round-trip (`ld hl,(nn)` / `ld (nn),hl`), the two cost centres
; T2's own report named as dominating the budget. IX is proven free for
; this exclusive use throughout playback: im2_isr's fast path (taken
; unconditionally while audEnable=0, which is the WHOLE playback session)
; never touches ix/iy at all (interrupts.asm - only its now-unreachable
; `.audio` branch does); the raw streaming internals this ISR runs
; alongside are documented ix/iy-free by their own "golden rules 1 and 2"
; header (vid_stream_read_raw); data_save/data_map_page/data_restore
; (banks.asm) and every DEBUG dbg_* helper (debug.asm) are ix/iy-free
; too (grepped). The `(ix+d)` read costs more per access than `(hl)`
; (doc 01's regime 2 - no way around that), but the round-trip + push/pop
; hl it replaces cost more still - net ISR body shrink, see the report's
; budget table for the exact T-state accounting. Budget: see the task
; report's Step 0 table (28MHz-adjusted T-states per docs/Z80/01).
;
; SP14a T4: the end-marker is now SELF-MODIFIED, like the stereo ISR
; already was (below) - NXV's audio-bytes/frame is a per-FILE header
; field (vidABytesReal), not one of a small fixed set of compile-time
; constants, so a hardcoded `cp low/high vidAudBufLast` no longer has a
; single correct value. vid_run pokes the real end address (vidAudBuf +
; vidABytesReal - 1) into .cmplo+1/.cmphi+1 BEFORE the CTC time constant
; starts the timer - same ordering rule, same mechanism the stereo ISR
; already used for its own two-buffer-length case.
video_ctc_isr:
    push af
 IFDEF DEBUG
    ; SP14a T1: timeline tick counter - A only (AF already saved above,
    ; A is about to be reloaded fresh below regardless of this value), NO
    ; HL/IX - the ISR's IX-exclusivity and HL-freedom invariants (this
    ; header, above) must not be disturbed by the instrument itself.
    ld a, (vidTlTicks)
    inc a
    ld (vidTlTicks), a
    jr nz, .tlnc
    ld a, (vidTlTicks+1)
    inc a
    ld (vidTlTicks+1), a
.tlnc:
 ENDIF
    ld a, (ix+0)
    out (DAC_PORT), a
    ld a, ixl
.cmplo:
    cp 0                            ; patched: low byte of the real end
    jr nz, .adv                     ; address (vid_run, before CTC arm)
    ld a, ixh
.cmphi:
    cp 0                            ; patched: high byte of the real end
    jr nz, .adv                     ; address
    ld a, 1
    ld (vidAudDone), a
    jr .ret
.adv:
    inc ix
.ret:
    pop af
    ei
    reti

; Stereo video audio ISR. Fires at the file's own full-rate header rate
; (NXV_RATE_STEREO = 15625 Hz, every stereo NXV profile - no downsample,
; unlike the old MakeVid-era player) via CTC channel 0, same
; installation/banking-invariant/alternate-set/no-MMU discipline as
; video_ctc_isr above (see its header - identical reasoning applies here,
; not repeated). DAC ports: VID_DAC_LEFT ($F3, DAC channel B) / VID_DAC_
; RIGHT ($F9, DAC channel C) - ports.txt lines 266-274 ("A,B are directed
; to the left audio channel and C,D... right"), the exact pair the
; MakeVid reference ISR used (interrupts-common.asm isr_ctc_stereo) -
; confirming the interleave order too: L byte first (even offset), R
; second (odd offset) per sample pair. IX addresses the CURRENT pair's L
; byte; R is (ix+1). End condition: IX has reached the LAST pair's L
; byte - the end address is self-modified into .cmplo+1/.cmphi+1 exactly
; like the mono ISR above, computed from vidABytesReal (vid_run, before
; the CTC time constant starts the timer). Advances by 2 per tick, not 1.
video_ctc_isr_stereo:
    push af
 IFDEF DEBUG
    ; SP14a T1: timeline tick counter - see video_ctc_isr's own comment
    ; (identical shape, A only, no HL/IX).
    ld a, (vidTlTicks)
    inc a
    ld (vidTlTicks), a
    jr nz, .tlnc
    ld a, (vidTlTicks+1)
    inc a
    ld (vidTlTicks+1), a
.tlnc:
 ENDIF
    ld a, (ix+0)
    out (VID_DAC_LEFT), a
    ld a, (ix+1)
    out (VID_DAC_RIGHT), a
    ld a, ixl
.cmplo:
    cp 0                            ; patched: low byte of the real end
    jr nz, .adv                     ; address
    ld a, ixh
.cmphi:
    cp 0                            ; patched: high byte of the real end
    jr nz, .adv                     ; address
    ld a, 1
    ld (vidAudDone), a
    jr .ret
.adv:
    inc ix
    inc ix
.ret:
    pop af
    ei
    reti

vidNum:          db 0
vidLoopMode:      db 0             ; 0 = play once, 1 = loop
vidExitReq:       db 0
; vidName/vidNamePart moved to VID_PAGE2 (SP14a T3 wave 1) - only the now-
; cold vid_open_video_body/vid_stream_open_body touch them (vid_open_
; video_body builds them; vid_stream_open_body's esx_fopen reads them via
; IX - see the VID_PAGE2 section's own declarations).
vidAudPoolBank:   db 0
vidAudPoolPage:   db 0
vidDrawPage:      db 0
vidPxPage:        db 0
; vid_stream_pixels_flat's own runtime state (flat-serve path, mode-0
; always or mode-1 at native height - see that routine's own header).
vidPxBlocksLeft:  dw 0             ; total 512B blocks remaining, frame
vidPxBlocksReq:   dw 0             ; this step's block count (1-16)
vidPxChunkBytes:  dw 0             ; vidPxBlocksReq*512 (the vid_stream_
                                    ; read call's own DE)
vidCtcTc:         db 0
vidAudReadLen:    dw 0             ; this frame's audio read size
                                    ; (== vidABytesPad, staged fresh each
                                    ; frame so vid_stream_frame's caller
                                    ; never re-derives it)
; --- SP14a T4: NXV header-derived playback parameters (nxv_open's own
; output, above) - populated once at open, read every frame. ---
vidShape:         db 0             ; NXV_SHAPE_MODE1/MODE0
vidHeight:        dw 0             ; content height (256 fits, so a word)
vidAChan:         db 0             ; 1 = mono, 2 = stereo
vidABytesPad:     dw 0             ; audio wire read size (block multiple)
vidABytesReal:    dw 0             ; audio played length (<= padded)
vidPalFlag:       db 0             ; 0 = identity/RGB332, 1 = per-frame
                                    ; 512B palette block
vidPixBlocks:     dw 0             ; pixel data, 512-byte blocks/frame
vidGapNeeded:     db 0             ; 1 = mode-1 column-gap blit needed
                                    ; (height < native 256); 0 = flat
vidColUnits:      db 0             ; gap blit only: height/8 (8-byte
                                    ; transfer units per column)
vidClipY1:        db 0             ; NR $18 Y1 (content band top)
vidYofs:          db 0             ; NR $17 (signed, = -vidClipY1)
; --- gap-blit runtime state (vid_stream_pixels_gap, above - see its own
; header for the algorithm). SP14a gap-blit redesign wave: columns-left/
; block-left/column-left/colUnits-cache are register-resident (ALTERNATE
; set) for the whole call, not memory-backed - only vidGapDest remains,
; kept as a debugger-visibility sync point (page-switch/entry/error),
; never read back by the routine itself. ---
vidGapDest:       dw 0             ; live destination pointer (MMU6
                                    ; window-relative) - write-only sync,
                                    ; see vid_stream_pixels_gap's header
; Resident play buffer - full rate, no decimation (SP14a T4 deletes the
; old 2:1/3:1 downsample entirely: NXV streams every real sample). Sized
; to NXV_AUD_BUF_MAX (2560B, N0 stereo's own real-byte figure rounded up
; to its padded size) - the largest per-frame real-audio length any
; shipped profile needs; formats needing less use only the front of it.
vidAudBuf:        ds NXV_AUD_BUF_MAX
vidAudDone:       db 0
vidSvMmu6:        db 0
vidSvMmu7:        db 0
vidSvNr12:        db 0
vidSvNr70:        db 0
vidSvNr69:        db 0
vidSvNr15:        db 0
vidSvCtcStub:     dw 0
vidSvAudEnable:   db 0
vidSvL2Front:     db 0
vidSvL2Back:      db 0
vidSvNr43:        db 0             ; SP14a T2: captured constant (PAL_L2_
                                    ; FIRST), NOT a read - see vid_run's
                                    ; entry-capture comment for why
vidSvNr6b:        db 0             ; SP14a T4: presentation isolation -
                                    ; saved NR_TM_CTRL (tilemap), disabled
                                    ; for the whole session, restored here
vidSvNr4a:        db 0             ; SP14a T4: presentation isolation -
                                    ; saved NR_FALLBACK, forced black for
                                    ; the whole session, restored here
vidPalCtrl:       db 0             ; SP14a T2: which Layer 2 palette bank
                                    ; is CURRENTLY DISPLAYED, always either
                                    ; PAL_L2_FIRST or PAL_L2_SECOND between
                                    ; frames - software-tracked because NR
                                    ; $43 is not reliably readable (same
                                    ; reason vidSvNr43 above is a captured
                                    ; constant, not a read). Persists
                                    ; unreset across loop-mode EOF restarts
                                    ; (see vid_run's flip-block comment) -
                                    ; the physical display state does not
                                    ; change just because playback reopens
                                    ; the file, exactly like l2FrontBank/
                                    ; l2BackBank's own persistent-across-
                                    ; restart behaviour.

 IFDEF DEBUG
; msgVidBadFmt/Missing/NoBank2 moved to VID_PAGE2 (SP14a T4 owner follow-
; up, VID_PAGE budget) - see vid_play_missing_body/vid_run_nobank_body/
; vid_run_badfmt_body, below the cold section's own DEBUG-only content.

; SP14a Task 1: DEBUG frame-timeline instrument state. Zeroed at every
; vid_run entry (see the IFDEF DEBUG block right before .frameloop) -
; a fresh measurement per playback session, not cumulative across calls.
; The five accumulators must stay contiguous and in this exact order -
; the entry reset (a single LDIR) and vid_tl_stamp's indexed access both
; depend on it.
vidTlTicks:     dw 0        ; video-ISR tick count (video_ctc_isr/_stereo
                            ; increment this every tick, A-only - see
                            ; either ISR's own header) - the timeline
                            ; clock, 43-128us resolution depending on
                            ; format (VID_RATE4_X10.../VID_RATE0_PLAY)
vidTlLastTick:  dw 0        ; vidTlTicks snapshot at the previous stamp
vidTlLastPhase: db 0        ; phase id (VID_TL_*, nextdaad.inc) active
                            ; since that snapshot
vidTlFrames:    dw 0        ; frame-loop iterations reached (vid_tl_stamp
                            ; increments this whenever phase VID_TL_STREAM
                            ; opens - vid_stream_frame's own entry stamp)
vidTlAcc:       ds VID_TL_PHASES*4   ; 5 phases x 32-bit (LE) tick total
; SP14a T3 fix wave (owner hardware leg, vply0 regression audit): the
; deepest error code seen at vid_run's .eof funnel point (see that
; label's own IFDEF DEBUG capture) - 0 = clean EOF (the documented-
; normal short-audio-read termination, explicitly zeroed there - see
; vid_stream_frame's own .audfull comment); nonzero = a genuine VID_ERR_*
; (nextdaad.inc) or esxDOS error code propagated from wherever the frame
; actually failed (vid_col_newblock's three codes are the ones a wave-2
; blit regression would show). Printed as ERR=xx in the timeline report.
vidErrCode:     db 0
; SP14a T3 fix wave 2 (owner hardware leg lead 2 fallback instrumentation):
; the RAW byte a failed vid_col_newblock token-wait actually read off the
; wire (captured only on the VID_ERR_TOKEN path, before A is overwritten
; with the sentinel - see that call site). Discriminates the two
; remaining candidates when ERR=FD: a plausible CRC/data byte (any value
; that is neither $FF nor $FE, but "looks like" wire content - e.g. often
; seen as part of a real 512-byte data pattern or a small CRC16 byte)
; supports a byte-accounting desync (lead 2 - one protocol step missing
; or doubled at the audio/palette-to-blit handoff); a value indistinguishable
; from noise, or repeatedly $00/$FF-adjacent, points at a wilder desync
; or a genuine card/timing fault instead. Printed as BYT=xx alongside
; ERR=xx. Meaningless (stays whatever a PRIOR failing call left it, or 0
; on a fresh session) when ERR is not FD.
vidErrByte:     db 0
; Fix wave 2: total span of the block above (vidTlTicks..end of
; vidErrByte) that vid_tl_report_body must copy across the page hop
; before reading it (see that routine's own header) - computed, not
; hand-counted, so it can never drift if a field above is resized.
VID_TL_BLOCK_LEN equ vidErrByte + 1 - vidTlTicks

; Owner gate-leg staged-entry ladder (SP14a T4 follow-up) - see vid_run's
; own stage-check sites and vid_stage_marker_body's header (VID_PAGE2)
; for the full mechanism. Deliberately OUTSIDE the vidTlTicks..vidErrByte
; span above (VID_TL_BLOCK_LEN must stay exactly that block's own size -
; the timeline report's copy-across, see that equ's own comment).
vidStageLimit:    db 0        ; 0 = ordinary (VPLY0-4/VLOP0-4), 1-4 = the
                               ; VSTG1-4 ladder stage cap, read once from
                               ; flags+250 at vid_run entry
vidStageFrameCnt: db 0        ; stage 3's own frame counter - explicitly
                               ; zeroed at the stage-1 check site (vid_run,
                               ; below) on EVERY entry, not just this
                               ; assemble-time initial value: VID_PAGE is
                               ; banked, not re-initialized between calls,
                               ; so a second VSTG3 in the same session
                               ; would otherwise inherit the first run's
                               ; own final count and cap out after 1 frame
vidStage2Sub:     db 0        ; stage-2 sub-ladder (VSTG2A/B/C, flag 249):
                               ; 0 = no sub-limit (ordinary stage 2 = "2d",
                               ; full frame + one CPU flip), 1/2/3 = stop
                               ; after audio+pad / +palette / +first 16
                               ; pixel blocks (vid_stream_frame's own
                               ; gates). Read once alongside vidStageLimit,
                               ; same self-clearing reasoning.
msgStg4: db "STG4 OK ERR=", 0 ; stays hot (.restore_tail's own inline
                               ; print, no hop) - STG1-3 print cold
                               ; instead (vid_stage_marker_body, VID_PAGE2)
                               ; since those exits hop there anyway

; DEBUG frame-timeline instrument. In: A = new phase id (VID_TL_STREAM..
; VID_TL_OTHER, nextdaad.inc). Snapshots vidTlTicks and accumulates the
; delta since the PREVIOUS stamp into the accumulator for the phase that
; was active over that interval (vidTlAcc[vidTlLastPhase]), then records
; the new phase/tick as current. A=VID_TL_STREAM (0) also increments
; vidTlFrames. Deliberately avoids IX (the ISR's exclusive resident play
; pointer for the whole CTC-armed window - see either ISR's header): this
; runs mainline, interruptible by the tick ISR at any point, so it must
; never touch IX. Every call site (this task's report has the full list)
; sits where nothing else is live across the call, so the AF/BC/DE/HL
; corruption below costs nothing beyond the call itself - see the
; report's perturbation-bound section for the per-call T-state cost.
; Corrupts AF, BC, DE, HL.
vid_tl_stamp:
    push af                        ; new phase id, needed again after the
                                    ; accumulator update below
    ld hl, (vidTlTicks)
    ld de, (vidTlLastTick)
    ld (vidTlLastTick), hl
    or a
    sbc hl, de                     ; hl = delta ticks since previous stamp
    ex de, hl                      ; de = delta
    ld a, (vidTlLastPhase)
    add a, a
    add a, a                       ; *4 - each accumulator is 4 bytes
    ld l, a
    ld h, 0
    ld bc, vidTlAcc
    add hl, bc                     ; hl = &vidTlAcc[vidTlLastPhase]
    ld a, e
    add a, (hl)
    ld (hl), a
    inc hl
    ld a, d
    adc a, (hl)
    ld (hl), a
    jr nc, .noc
    inc hl
    inc (hl)
    jr nz, .noc
    inc hl
    inc (hl)
.noc:
    pop af
    ld (vidTlLastPhase), a
    or a                            ; VID_TL_STREAM == 0
    ret nz
    ld hl, (vidTlFrames)
    inc hl
    ld (vidTlFrames), hl
    ret

; Hops to VID_PAGE2 to print the timeline report (rows 24-28: vid_tl_
; report_body, the VID_PAGE2 section at the end of this file), then hops
; back before returning - MMU7 == VID_PAGE both on entry and on return,
; matching every other call site's expectation (the SAME data_map_page-
; style bracket already used for MMU6, applied here to MMU7 instead,
; since the report body needs more space than VID_PAGE's own headroom -
; see the task report). Reached only from vid_run's .restore, strictly
; AFTER the CTC is parked and the stub restored (that call site's own
; comment) - no ISR can fire during the hop, honouring the SP13 T3 probe
; postmortem's lesson ("no second-page code reachable while the ISR is
; armed"). Uses the established push-target/ovl_map_page trampoline idiom
; (xpart_load_entry, overlay0.asm). Corrupts everything.
vid_tl_report:
    ld hl, vid_tl_report_body
    push hl
    ld a, VID_PAGE2
    jp ovl_map_page                ; nextreg NR_MMU7,VID_PAGE2 / ret ->
                                    ; vid_tl_report_body (VID_PAGE2 below)
vid_tl_report_ret:
    ret                             ; MMU7 == VID_PAGE already (the body's
                                    ; own hop back writes it before this)
 ENDIF

; VIDBENCH (SP13 Task 1's streaming-throughput dev harness) RETIRED in
; full - owner decision, SP14a T4 (this task's follow-up commit): its
; job is done (the SP13 streaming mechanism decision, the flat-rate
; measurement that sized the NXV matrix, are all in the historical task
; reports; git history holds the code if a future core ever warrants
; resurrection). Removed: this dispatcher (vid_bench/vid_bench_orig),
; vid_bench_pass/vid_bench_pass_ret, the vidBench* data cells, msgVidNoBank,
; the VID_PAGE2 cold bodies (vid_bench_compute/vid_bench_report and their
; own message strings/cells, below), the vid_stream_open hot stub +
; vid_stream_open_hopbody that existed only for vid_bench_pass's sake
; (see this file's own top-of-file comment), extVec vector 6's DEBUG row
; and vid_bench_trampoline (overlay0.asm), and the VIDBENCH/VBFLT/VBDMA/
; VBCOP/VBCU/VBCD test.dsf verbs (already-retired siblings from the
; prior wave - VIDBENCH itself was the last one standing). The frame-
; timeline instrument (vid_tl_stamp/vid_tl_report, above) is UNCHANGED -
; that is the active gate/evidence tool this task keeps.

    DISPLAY "video ends at ", $, " headroom ", /D, OVL_LIMIT - $
    ASSERT $ <= OVL_LIMIT

; ---------------------------------------------------------------------
; VID_PAGE2 - second video page. Originally (SP14a T1) a DEBUG-only
; overflow page hosting only the frame-timeline report's print body
; (SP13 T3's own crash-bisection-probe precedent: print-only, reached
; strictly AFTER playback is fully torn down, never while the CTC/ISR is
; armed). SP14a T3 wave 1 made the page UNCONDITIONAL (both build
; variants) and added a second kind of content: COLD video code evicted
; off VID_PAGE under the SAME one-rule invariant (MMU7 = VID_PAGE
; whenever the video CTC ISR can fire) - the open/filemap-orchestration
; cluster (vid_open_video, vid_stream_open), provably reachable only
; BEFORE any CTC arm (see each routine's own header, below, for the
; call-site evidence). SP14a T4 removes the old sizeless-classifier
; cluster entirely (vid_classify_body/vid_mod24/vidFormatSect/vidSectE-L)
; and adds NXV's own header validate (nxv_open_body, below - the bulk of
; nxv_open's logic; only the one vid_stream_read call stays on the hot
; stub, VID_PAGE - see that routine's own header for the split
; rationale). The DEBUG-only report body (vid_tl_report_body etc) stays
; exactly as T1 left it, still guarded by its own IFDEF DEBUG within this
; now-unconditional page.
; ---------------------------------------------------------------------
    MMU 7, VID_PAGE2, OVL_ORG

; ------------------------------------------------------------------
; Cold video code (SP14a T3 wave 1) - both build variants.
; ------------------------------------------------------------------

; nxv_open_body - the bulk of NXV header validation (see nxv_open's own
; header, VID_PAGE, for the hot-stub/cold-body split rationale). In: C =
; the pool page the hot stub already read block 0 into. Ends by hopping
; back to nxv_open_ret (VID_PAGE) with the verdict in B (0 = valid, 1 =
; bad) - the same B-carries-result convention this file uses throughout.
; Corrupts everything.
nxv_open_body:
    call data_save
    ld a, c
    call data_map_page
    ld hl, DATA_WINDOW + NXV_OFF_MAGIC
    ld de, nxvMagic
    ld b, NXV_MAGIC_LEN
.magic:
    ld a, (de)
    cp (hl)
    jp nz, .bad
    inc hl
    inc de
    djnz .magic
    ld a, (DATA_WINDOW + NXV_OFF_VERSION)
    cp NXV_VERSION
    jp nz, .bad
    ld a, (DATA_WINDOW + NXV_OFF_SHAPE)
    cp NXV_SHAPE_MODE0 + 1
    jp nc, .bad                     ; shape must be 0 or 1
    ld (vidShape), a
    ; width cross-check (shape implies width; reject a mismatched pair)
    ld hl, (DATA_WINDOW + NXV_OFF_WIDTH)
    ld de, NXV_WIDTH_MODE1
    ld a, (vidShape)
    or a
    jr z, .checkw
    ld de, NXV_WIDTH_MODE0
.checkw:
    or a
    sbc hl, de
    jp nz, .bad
    ; height: 0 < height <= native, alignment per shape (mode1: mod 8,
    ; mode0: mod 2) - height==native (256, mode1 only) is the one value
    ; whose high byte is set (H=1,L=0) and is exempt from the alignment
    ; test (it IS the stride, never a gapped case).
    ld hl, (DATA_WINDOW + NXV_OFF_HEIGHT)
    ld a, h
    or a
    jr z, .lowheight
    ld a, (vidShape)
    or a
    jp nz, .bad                     ; high byte set: mode0 never valid
    ld a, l
    or a
    jp nz, .bad                     ; must be exactly 256 (H=1,L=0)
    jr .heightok
.lowheight:
    ld a, l
    or a
    jp z, .bad                      ; height 0 never valid
    ld b, a                         ; stash height for the native-ceiling
                                     ; compare (A is about to be reused)
    ld a, (vidShape)
    or a
    jr nz, .mode0ceiling
    ; mode1: native height is 256, which cannot be loaded into an 8-bit
    ; register - but ANY value B can hold here (1-255, H was already
    ; confirmed 0 above) is by construction < 256, so the ceiling test
    ; is unconditionally satisfied - skip straight to the alignment mask.
    jr .gotmask
.mode0ceiling:
    ld a, NXV_NATIVE_H_MODE0        ; = 192, fits an 8-bit literal
    cp b
    jp c, .bad                      ; native < height: over the ceiling
.gotmask:
    ld a, (vidShape)
    or a
    ld c, 7                         ; mode1 mask: mod 8 -> low 3 bits
    jr z, .gotmaskval
    ld c, 1                         ; mode0 mask: mod 2 -> low 1 bit
.gotmaskval:
    ld a, b
    and c
    jp nz, .bad
.heightok:
    ld hl, (DATA_WINDOW + NXV_OFF_HEIGHT)
    ld (vidHeight), hl
    ; audio channels + rate (the supported set: NXV_RATE_STEREO paired
    ; with 2ch, NXV_RATE_MONO paired with 1ch - any other combination,
    ; including a "right" rate on the wrong channel count, rejected)
    ld a, (DATA_WINDOW + NXV_OFF_ACHAN)
    cp 1
    jr z, .mono
    cp 2
    jp nz, .bad
    ld hl, NXV_RATE_STEREO
    jr .havechan
.mono:
    ld hl, NXV_RATE_MONO
.havechan:
    ld (vidAChan), a
    ex de, hl                       ; DE = expected rate
    ld hl, (DATA_WINDOW + NXV_OFF_ARATE)
    or a
    sbc hl, de
    jp nz, .bad
    ; audio bytes/frame: padded must be a nonzero 512-byte multiple; real
    ; must be <= padded
    ld hl, (DATA_WINDOW + NXV_OFF_ABYTES_PAD)
    ld a, h
    or l
    jp z, .bad
    ld a, l
    or a
    jp nz, .bad                     ; low byte must be 0 (multiple of 256)
    ld a, h
    and 1
    jp nz, .bad                     ; bit 0 of high byte must be 0 too
                                     ; (together: multiple of 512)
    ; SP14a T4 owner follow-up (fresh-eyes finding #3b): upper-bound pad
    ; against NXV_AUD_BUF_MAX (2560) - vidAudBuf's own resident size. An
    ; unbounded pad would overflow vidAudBuf when the per-frame LDIR
    ; copy-out (vid_run's own .frameloop) later copies `real` (<=pad,
    ; enforced below) bytes into it - bounding pad alone closes both
    ; fields at once, since real can never exceed it.
    ld de, NXV_AUD_BUF_MAX
    or a
    sbc hl, de
    jr c, .padok                    ; pad < max
    jr z, .padok                    ; pad == max
    jp .bad                         ; pad > max: reject
.padok:
    add hl, de                      ; recover the original pad value (the
                                     ; sbc above was destructive - the
                                     ; same "subtract then add back"
                                     ; idiom vid_stream_pixels_flat
                                     ; already uses; exact regardless of
                                     ; which branch was taken, since DE
                                     ; is unchanged since the sbc)
    ld (vidABytesPad), hl
    ld hl, (DATA_WINDOW + NXV_OFF_ABYTES_REAL)
    ld de, (vidABytesPad)
    or a
    sbc hl, de
    jr c, .realok                   ; real < padded
    jr z, .realok                   ; real == padded
    jp .bad                         ; real > padded: reject
.realok:
    ld hl, (DATA_WINDOW + NXV_OFF_ABYTES_REAL)
    ld a, h
    or l
    jp z, .bad                      ; SP14a T4 owner follow-up (fresh-
                                     ; eyes finding #3a): real == 0
                                     ; rejected - a zero-length copy-out
                                     ; LDIR (vid_run's own .frameloop)
                                     ; would wrap BC to 65536 and
                                     ; obliterate VID_PAGE
    ld (vidABytesReal), hl
    ld a, (DATA_WINDOW + NXV_OFF_PALFLAG)
    cp 2
    jp nc, .bad
    ld (vidPalFlag), a
    ld hl, (DATA_WINDOW + NXV_OFF_PIXBLK)
    ld a, h
    or l
    jp z, .bad
    ld (vidPixBlocks), hl
    ; SP14a T4 owner follow-up (review finding): cross-check the header's
    ; own pixel-block count against width*height/512 derived from the
    ; already-validated shape+height - fail-clean hardening against a
    ; corrupt/malformed PIXBLK field that would otherwise blit the wrong
    ; amount of data (short or over-read) instead of cleanly rejecting
    ; the file as VID FMT?. Computed as a height-scaling (not a literal
    ; width*height/512) to dodge 16-bit overflow (320*256=81920 does not
    ; fit 16 bits): mode-1 expected = height*5/8 (320/512 reduces to
    ; 5/8; height is already validated as a multiple of 8, or exactly
    ; 256, so this is always exact); mode-0 expected = height/2 (256/512
    ; reduces to 1/2; height is already validated as a multiple of 2).
    ld a, (vidShape)
    or a
    jr nz, .pbmode0
    ld hl, (vidHeight)
    ld a, h
    or a
    jr z, .pbnotnative
    ld hl, 160                      ; height==256 (native): 256*5/8=160
    jr .pbgot
.pbnotnative:
    ld a, l                         ; height < 256, already a multiple of 8
    srl a
    srl a
    srl a                          ; a = height/8
    ld b, a
    add a, a
    add a, a                       ; a = 4*(height/8)
    add a, b                       ; a = 5*(height/8) = height*5/8
    ld l, a
    ld h, 0
    jr .pbgot
.pbmode0:
    ld hl, (vidHeight)
    ld a, l                         ; H is always 0 for mode-0 (<=192)
    srl a                          ; a = height/2
    ld l, a
    ld h, 0
.pbgot:
    ld de, (vidPixBlocks)
    or a
    sbc hl, de
    jp nz, .bad
    ; derive gap/Y-centering geometry from shape+height
    ld a, (vidShape)
    or a
    jr nz, .mode0derive
    ; mode 1: gap needed unless height == native (256, H=1 case handled
    ; separately - only L is meaningful for any OTHER valid height here)
    ld hl, (vidHeight)
    ld a, h
    or a
    jr nz, .flatnative              ; height==256: flat, no gap
    ; Y1 = (256-height)/2 - 256 does not fit an 8-bit literal, so this
    ; computes 0-L (mod 256), which equals 256-L exactly for any L in
    ; 1..255 (the only range reachable here - L=0/H=1 both handled above)
    xor a
    sub l
    srl a
    ld (vidClipY1), a
    ld a, 1
    ld (vidGapNeeded), a
    ld a, l
    srl a
    srl a
    srl a
    ld (vidColUnits), a             ; height/8, the gap blit's constant
    jr .derivedone
.flatnative:
    xor a
    ld (vidClipY1), a
    ld (vidGapNeeded), a
    jr .derivedone
.mode0derive:
    ; mode 0: never a gap - row-linear at any height
    ld hl, (vidHeight)
    ld a, NXV_NATIVE_H_MODE0
    sub l
    srl a
    ld (vidClipY1), a
    xor a
    ld (vidGapNeeded), a
.derivedone:
    ; owner fix ("N2 band addressing" audit - hardware-observed bottom-
    ; half-of-frame rendering on the top half of the screen, mode 0
    ; letterbox only): YOFS must wrap against the SURFACE's own native
    ; height, not unconditionally 256. Plain `neg` computes (256-
    ; vidClipY1) mod 256 - exactly correct for mode 1 (native height
    ; 256, the mode-1 branches above), but WRONG for mode 0 (native
    ; height 192): it overshoots the true 192-row modulus by 64
    ; whenever vidClipY1 != 0, landing YOFS outside the dev guide's own
    ; documented valid range (chapter-next-layer2.tex, port $17:
    ; "Valid range is: 256x192: 191") - e.g. vidClipY1=24 (256x144)
    ; gives neg=232 (invalid), not the correct 192-24=168. The zero
    ; case (native height, no letterbox) is exempt either way - neg(0)
    ; is already 0, and 192-0 would wrongly give 192 (itself out of
    ; range) if not special-cased.
    ld a, (vidClipY1)
    or a
    jr z, .yofszero
    ld b, a                          ; stash vidClipY1 (nonzero)
    ld a, (vidShape)
    or a
    jr z, .yofsmode1                 ; vidShape=0 -> mode 1 (native 256)
    ld a, NXV_NATIVE_H_MODE0         ; mode 0: wrap against 192
    sub b
    jr .yofsdone
.yofsmode1:
    ld a, b
    neg
    jr .yofsdone
.yofszero:
    xor a
.yofsdone:
    ld (vidYofs), a
    ; owner fix ("convict the trampler" - mechanism found live via ZEsarUX
    ; + map cross-check, not the original buffer-overrun hypothesis): this
    ; whole routine runs with MMU7 == VID_PAGE2 (nxv_open's own trampoline
    ; hop, above), but vidShape..vidYofs (the 15-byte contiguous block
    ; declared together, above, "NXV header-derived playback parameters")
    ; are VID_PAGE-resident labels - every `ld (vidXxx),a/hl` store just
    ; above compiled to a bare $Exxx address and landed on VID_PAGE2's own
    ; never-otherwise-written bytes at that offset, not on VID_PAGE's copy
    ; the hot player (vid_stream_frame, vid_stream_pixels_flat, etc.)
    ; actually reads - exactly the same "control flow crosses pages, data
    ; does not follow automatically" class vid_tl_report_body's own fix
    ; already documents in this file (see that routine's header, VID_
    ; PAGE2, below). Zeros on ZEsarUX's zeroed RAM masked it as vacuous
    ; sub-stage "passes"; uninitialized garbage on real hardware produced
    ; the white screen and, when vidABytesReal read back as a stale
    ; nonzero-but-wrong or zero value, the observed resets (a zero would
    ; wrap the .frameloop audio-copy LDIR's BC to 65536 - see that call
    ; site's own new guard). Fix: bulk-copy the whole block across via
    ; the MMU6/DATA_WINDOW window, the SAME translated-store pattern
    ; vid_raw_setup already uses correctly two screens above - one LDIR,
    ; since the block is already contiguous and in the right order.
    ld a, VID_PAGE
    call data_map_page
    ld hl, vidShape
    ld de, vidShape+DATA_WINDOW-OVL_ORG
    ld bc, vidYofs-vidShape+1
    ldir
    ld b, 0                          ; verdict: valid
    jr .backhop
.bad:
    ld b, 1                          ; verdict: bad
.backhop:
    call data_restore
    ld hl, nxv_open_ret
    push hl
    ld a, VID_PAGE
    jp ovl_map_page

nxvMagic: db "NXVID"

; ---------------------------------------------------------------------
; vid_run_entry_body - the bulk of vid_run's own entry state-capture
; (VID_PAGE budget lever - see vid_run's own header, above, for why
; MMU6/MMU7 specifically cannot move here). Captures NR12/70/69/15, the
; IM2 stub, audEnable, and l2Front/BackBank into the established MMU6-
; translated-address bracket, THEN runs the samples-abort wait and the
; music-tick freeze (both unchanged logic, just relocated - `halt`'s own
; interrupt wait does not care which page MMU7 currently maps, and the
; interrupt handler that can fire here is the pre-existing, RESIDENT
; game music/sample ISR, entirely unrelated to video). Hops back to
; vid_run.entryret (VID_PAGE) to continue with bank_alloc onward.
; Corrupts everything.
vid_run_entry_body:
    call data_save
    ld a, VID_PAGE
    call data_map_page
    ld e, NR_L2_BANK
    call nr_read
    ld (vidSvNr12+DATA_WINDOW-OVL_ORG), a
    ld e, NR_L2_CTRL
    call nr_read
    ld (vidSvNr70+DATA_WINDOW-OVL_ORG), a
    ld e, NR_DISPLAY_CTRL
    call nr_read
    ld (vidSvNr69+DATA_WINDOW-OVL_ORG), a
    ld e, NR_LAYERS
    call nr_read
    ld (vidSvNr15+DATA_WINDOW-OVL_ORG), a
    ld hl, (IM2_CTC_STUB+1)
    ld (vidSvCtcStub+DATA_WINDOW-OVL_ORG), hl
    ld a, (audEnable)
    ld (vidSvAudEnable+DATA_WINDOW-OVL_ORG), a
    ld b, a                          ; stash - data_restore corrupts A
    ld a, (l2FrontBank)
    ld (vidSvL2Front+DATA_WINDOW-OVL_ORG), a
    ld a, (l2BackBank)
    ld (vidSvL2Back+DATA_WINDOW-OVL_ORG), a
 IFDEF DEBUG
    ; Owner gate-leg staged-entry ladder (SP14a T4 follow-up): flags is
    ; RESIDENT (engine.asm, always mapped regardless of MMU7), so no
    ; translation is needed to read it; vidStageLimit IS VID_PAGE-
    ; resident, so ITS write uses this body's own already-open bracket,
    ; same as every other capture here. flag 250 (VIDBENCH's own retired
    ; slot, free since that verb's removal) - 0 = ordinary playback
    ; (VPLY0-4/VLOP0-4, untouched), 1-4 = the VSTG1-4 ladder verbs
    ; (test.dsf). See vid_stage_marker_body's own header for the full
    ; stage decode.
    ld a, (flags+250)
    ld (vidStageLimit+DATA_WINDOW-OVL_ORG), a
    xor a
    ld (flags+250), a             ; self-clearing: flag 250 is a plain
                                   ; session-persistent DDB flag, not
                                   ; auto-reset - without this, a VSTG3
                                   ; run would leave flag 250=3 and
                                   ; silently stage-cap the NEXT ordinary
                                   ; VPLY0 too. Cleared the instant it is
                                   ; read, so only THIS invocation ever
                                   ; sees a nonzero vidStageLimit.
    ; Stage-2 sub-ladder (VSTG2A/B/C, owner gate-leg follow-up): flag 249,
    ; same read/self-clear shape as flag 250 above.
    ld a, (flags+249)
    ld (vidStage2Sub+DATA_WINDOW-OVL_ORG), a
    xor a
    ld (flags+249), a
 ENDIF
    call data_restore

    ; --- samples abort (SSTOP request path, waited) ---
    ; audEnable = 0 means aud_tick never runs - the ISR never reaches the
    ; request chain, so a bit set here would never clear (aud_load_song's
    ; own documented hazard, overlay1.asm) - skip the wait in that case.
    ; B holds the just-captured audEnable (stashed above, since data_
    ; restore corrupts A).
    ld a, b
    or a
    jr z, .noaudsave
    ld hl, audRequest
    set 7, (hl)
.waitstop:
    halt
    ld a, (audRequest)
    bit 7, a
    jr nz, .waitstop
.noaudsave:
    ; --- music tick frozen ---
    xor a
    ld (audEnable), a

    ld hl, vid_run.entryret
    push hl
    ld a, VID_PAGE
    jp ovl_map_page

; ---------------------------------------------------------------------
; vid_run_l2setup_body - Layer 2 setup + identity palette, hopped cold
; from vid_run (VID_PAGE, above - see that call site's own comment for
; why this is safe pre-arm). Reads vidShape/vidClipY1/vidHeight/vidYofs/
; vidPalFlag (VID_PAGE-resident, nxv_open's own output) via the
; established MMU6-translated-address bracket (data_save/data_map_page
; (VID_PAGE), held for this whole body). vid_identity_palette (below) is
; a same-page plain call - no further hop needed, pure NextReg I/O with
; no VID_PAGE-resident memory reads of its own (safe to relocate here
; wholesale). Copper list load retired (owner fix - see vid_copper_
; poke's old header, VID_PAGE, for why). Ends by hopping back to vid_
; run_l2setup_ret (VID_PAGE). Corrupts everything.
;
; Mode 1/column-major (320-wide, NXV_NR70_MODE1) or mode 0/row-major
; (256-wide, NXV_NR70_MODE0) per the header's own shape field. Full-
; WIDTH clip always (X1=0, X2 = the shape's own native width-1 in its
; own clip units) - NXV has no pillarbox profile in the shipped matrix,
; unlike the old MakeVid-era fmt2/3's 256-of-320 subset. Y clip/scroll
; derived from the header's own content height (nxv_open's vidClipY1/
; vidYofs) instead of a fixed per-format pair - this is what makes
; height a genuine HEADER PARAMETER (spec's own framing), not a format
; property. Transparent colour left at TM_TRANSP_ATTR (the engine-wide
; convention every l2_mode_set call also uses - vid_apply_palette/vid_
; identity_palette dodge it exactly like l2_palette_load).
vid_run_l2setup_body:
    call data_save
    ld a, VID_PAGE
    call data_map_page
    ; presentation isolation (spec requirement, owner 2026-07-21): save +
    ; disable the tilemap layer, save + force the global fallback colour
    ; to black - moved here from vid_run's own hot code (another VID_
    ; PAGE budget lever; no CTC dependency, same reasoning as the rest of
    ; this body). Restored on every real exit (vid_run_restore_body,
    ; below).
    ld e, NR_TM_CTRL
    call nr_read
    ld (vidSvNr6b+DATA_WINDOW-OVL_ORG), a
    and %01111111                   ; disable (clear the enable bit)
    nextreg NR_TM_CTRL, a
    ld e, NR_FALLBACK
    call nr_read
    ld (vidSvNr4a+DATA_WINDOW-OVL_ORG), a
    xor a
    nextreg NR_FALLBACK, a          ; force black
    ; NR $43 (palette ctrl): the dev guide's per-register spec (chapter-
    ; next-palette.tex, "Register $43") never states it is readable - NR
    ; $40/$41/$44 each say "Reads or writes ..." explicitly, $43's own
    ; entry only describes what each bit DOES when written, no read
    ; mention. nr_read is therefore NOT used here; the game's own
    ; convention is captured instead (sp13-task-4-report.md addendum:
    ; every Layer 2 palette writer in this codebase, including vid_
    ; identity_palette, uses PAL_L2_FIRST unconditionally - it is the
    ; only value NR $43 can hold on entry). vidPalCtrl (the double-
    ; buffer's own "which bank is on screen right now" tracker) is
    ; primed to the same value - frame 0 starts believing the first bank
    ; is displayed, matching what vid_identity_palette/l2_palette_load's
    ; own convention actually left on the hardware.
    ld a, PAL_L2_FIRST
    ld (vidSvNr43+DATA_WINDOW-OVL_ORG), a
    ld (vidPalCtrl+DATA_WINDOW-OVL_ORG), a
    ld a, (vidShape+DATA_WINDOW-OVL_ORG)
    or a
    jr nz, .l2mode0
    ld a, NXV_NR70_MODE1
    nextreg NR_L2_CTRL, a
    nextreg NR_L2_TRANSP, TM_TRANSP_ATTR
    nextreg NR_CLIP_IDX, 1
    xor a
    nextreg NR_L2_CLIP, a            ; X1 = 0 (full-bleed)
    ld a, NXV_CLIP_X2_MODE1
    nextreg NR_L2_CLIP, a
    jr .clipY
.l2mode0:
    xor a
    nextreg NR_L2_CTRL, a
    nextreg NR_L2_TRANSP, TM_TRANSP_ATTR
    nextreg NR_CLIP_IDX, 1
    xor a
    nextreg NR_L2_CLIP, a            ; X1 = 0 (full-bleed)
    ld a, NXV_CLIP_X2_MODE0
    nextreg NR_L2_CLIP, a
.clipY:
    ; Y1 = vidClipY1 (nxv_open's own derivation); Y2 = Y1 + height - 1,
    ; special-cased when height==256 (H=1,L=0 - the one value that does
    ; not fit an 8-bit add: Y1 is already 0 there, so Y2 is simply 255).
    ld a, (vidClipY1+DATA_WINDOW-OVL_ORG)
    nextreg NR_L2_CLIP, a
    ld hl, (vidHeight+DATA_WINDOW-OVL_ORG)
    ld a, h
    or a
    jr z, .y2low
    ld a, 255
    jr .havey2
.y2low:
    ld a, (vidClipY1+DATA_WINDOW-OVL_ORG)
    add a, l
    dec a
.havey2:
    nextreg NR_L2_CLIP, a
    ld a, (vidYofs+DATA_WINDOW-OVL_ORG)
    nextreg NR_L2_YOFS, a
    nextreg NR_L2_XOFS, 0
    ld e, NR_DISPLAY_CTRL
    call nr_read
    or %10000000
    nextreg NR_DISPLAY_CTRL, a
    nextreg NR_LAYERS, 0

    ; no per-frame palette block (vidPalFlag=0): pixel bytes ARE their
    ; own RRRGGGBB colour - program a fixed identity table once.
    ld a, (vidPalFlag+DATA_WINDOW-OVL_ORG)
    or a
    call z, vid_identity_palette

    ; copper flip init - RETIRED (owner fix, palette sparkle/magenta
    ; parity-chain audit - see vid_copper_poke's old header, VID_PAGE,
    ; for the full mechanism). vid_run's flip block uses direct CPU
    ; writes again (T2's proven choreography); the copper is never
    ; started for video playback any more, so there is nothing to init
    ; here and no stage-gating needed - every stage now behaves like
    ; the old "stages 1-3, no copper" case uniformly.

    ; SP14a T4 (VID_PAGE budget lever): the CTC time-constant table
    ; lookup moved here from vid_run's own hot CTC-retune section - it
    ; is a pure data lookup (no self-modifying code, no timing
    ; dependency), 100% safe to compute pre-arm, and this cold body
    ; already has the exact MMU6-translated-write pattern (vidCtcTc,
    ; VID_PAGE-resident) it needs - riding the SAME hop already open
    ; here costs nothing extra, while the equivalent hot-page code (two
    ; 8-byte tables + the lookup instructions) would.
    ld e, NR_VIDEO_TIMING
    call nr_read
    and 7
    ld c, a
    ld b, 0
    ld a, (vidAChan+DATA_WINDOW-OVL_ORG)
    ld hl, vidCtcTcNxvMono
    cp 2
    jr nz, .gottctab
    ld hl, vidCtcTcNxvStereo
.gottctab:
    add hl, bc
    ld a, (hl)
    ld (vidCtcTc+DATA_WINDOW-OVL_ORG), a

    ; IM2_CTC_STUB (ISR select, mono or stereo per the header's channel
    ; count) - RESIDENT memory, no translation needed. Single atomic LD
    ; (nn),HL (doc 08's "interrupt atomicity"); safe to write from any
    ; page, any time before the CTC actually arms (vid_run's own hot
    ; code does that, strictly after this whole cold body returns).
    ld a, (vidAChan+DATA_WINDOW-OVL_ORG)
    ld hl, video_ctc_isr
    cp 2
    jr nz, .isrpicked
    ld hl, video_ctc_isr_stereo
.isrpicked:
    ld (IM2_CTC_STUB+1), hl

    ; BOTH ISR bodies' end-marker patched unconditionally (only the one
    ; actually installed above ever executes; patching the other is
    ; harmless dead bytes and avoids a branch) - end address = vidAudBuf
    ; + vidABytesReal - (1 for mono, 2 for stereo pairs). These operand
    ; bytes ARE VID_PAGE-resident code, so the writes use the SAME MMU6-
    ; translated-address bracket this whole body already holds open.
    ld hl, (vidABytesReal+DATA_WINDOW-OVL_ORG)
    ld de, vidAudBuf
    add hl, de                       ; one past the real audio's own end
    dec hl                           ; mono's own end address (real-1)
    ld a, l
    ld (video_ctc_isr.cmplo+1+DATA_WINDOW-OVL_ORG), a
    ld a, h
    ld (video_ctc_isr.cmphi+1+DATA_WINDOW-OVL_ORG), a
    dec hl                           ; stereo's own end address (real-2)
    ld a, l
    ld (video_ctc_isr_stereo.cmplo+1+DATA_WINDOW-OVL_ORG), a
    ld a, h
    ld (video_ctc_isr_stereo.cmphi+1+DATA_WINDOW-OVL_ORG), a

 IFDEF DEBUG
    ; SP14a T4 owner follow-up (VID_PAGE budget, post-VIDBENCH-retirement):
    ; the timeline baseline reset moved here from vid_run's own hot CTC-
    ; retune section - fresh-per-session zero-fill of vidTlTicks..
    ; vidTlAcc's last byte (see that block's own declaration, VID_PAGE),
    ; pure data zeroing with no CTC/timing dependency, so it is just as
    ; safe run here, strictly pre-arm, as it was safe run hot post-arm.
    ; Same MMU6-translated-write bracket this body already holds open -
    ; the "write 0 then LDIR propagates it forward" idiom is unaffected
    ; by the constant DATA_WINDOW-OVL_ORG offset on both HL and DE.
    ld hl, vidTlTicks+DATA_WINDOW-OVL_ORG
    ld (hl), 0
    ld de, vidTlTicks+1+DATA_WINDOW-OVL_ORG
    ld bc, vidErrByte - vidTlTicks   ; = VID_TL_BLOCK_LEN - 1 (also zeroes
                                      ; vidErrCode/vidErrByte - a fresh
                                      ; playback session starts ERR=00)
    ldir
 ENDIF

    call data_restore
    ld hl, vid_run.l2setupret
    push hl
    ld a, VID_PAGE
    jp ovl_map_page

; Owner gate-leg staged-entry ladder (SP14a T4 follow-up): prints the
; STGn marker (n = C, 1-3 for the main stages, 4-6 for the 2a/2b/2c sub-
; ladder) plus " ERR=xx" (D, the err byte .stagegate already read hot -
; owner directive: every marker shows ERR, not just a bare pass/fail),
; for whichever stage/sub-stage vid_run's own .stagegate stub (VID_PAGE)
; or vid_stream_frame's own sub-ladder gates (also VID_PAGE, qualified
; `jp vid_run.stagegate`) just tail-jumped from - then falls into
; .stagegateret (VID_PAGE) which does `jp .restore`, the same teardown
; every ordinary exit already uses. In: C = stage number, D = err byte -
; both REGISTERS, not a VID_PAGE memory read, so this deliberately
; sidesteps the "copy-across" translation lesson (vid_tl_report_body's
; own header, above) rather than needing it. D is stashed on the stack
; (push af/pop af) since it is about to be reused for the message-
; pointer table lookup below - no new memory cell needed for the swap.
; Corrupts everything (matches every other one-way hop in this file).
 IFDEF DEBUG
vid_stage_marker_body:
    push bc                      ; stash C=stage number (owner addendum:
                                  ; needed below, after C is reused as
                                  ; dbg_at's own column argument, to
                                  ; conditionally trigger the filemap
                                  ; dump for STG1 only)
    push ix                      ; stash IX=vidPixBlocks (owner addendum,
                                  ; "convict the trampler" follow-up) -
                                  ; printed below so a vacuous pass (zero
                                  ; or garbage block count) can never
                                  ; masquerade as a real one again. Pushed
                                  ; BEFORE de so the existing `pop de`
                                  ; below (unmoved) still matches its own
                                  ; push - LIFO order is bc,ix,de in, so
                                  ; de,ix,bc must come back out.
    push de                      ; stash D=err, E=vidDrawPage (owner
                                  ; addendum) - both about to be reused
                                  ; for the table lookup below
    ld a, c
    add a, a                     ; *2 (word-sized table entries)
    ld l, a
    ld h, 0
    ld de, vidStageMsgTab
    add hl, de
    ld e, (hl)
    inc hl
    ld d, (hl)                   ; DE = message pointer
    ld b, 22
    ld c, 0
    call dbg_at
    ex de, hl
    call dbg_puts
    ld hl, msgStgErr
    call dbg_puts
    pop de                       ; recover D=err, E=vidDrawPage
    ld a, d
    call dbg_hex8
    ld hl, msgStgDp
    call dbg_puts
    ld a, e
    call dbg_hex8
    pop ix                       ; recover PIXBLK
    ld hl, msgStgPb
    call dbg_puts
    push ix
    pop hl
    call dbg_hex16
    ; owner addendum (fresh-eyes round 3): filemap dump, STG1's own
    ; marker only - the cheapest correct place (the data is already
    ; valid by STG1's own exit point; printing it on every marker would
    ; be wasteful for no extra information - the filemap never changes
    ; mid-session).
    pop bc                       ; recover C=stage number
    ld a, c
    cp 1
    call z, vid_filemap_dump
    ld hl, vid_run.stagegateret
    push hl
    ld a, VID_PAGE
    jp ovl_map_page

; Indices 4/5 (formerly VS2A/VS2B) are dead - those gates retired (owner
; follow-up 4, VID_PAGE budget) but the table slots are left in place
; rather than reshuffling every other index; harmless (cold, unreferenced,
; C is never 4 or 5 any more).
; Index 7 (formerly VS2D) is dead too now (retired, fresh-eyes round 2 -
; superseded by VS2F) - same "leave the slot, don't reshuffle" reasoning
; as indices 4/5.
vidStageMsgTab: dw 0, msgStg1, msgStg2, msgStg3, msgStg2a, msgStg2b, msgStg2c, msgStg2d, msgStg2e, msgStg6, msgStg7, msgStg2f
                                                  ; index 0 unused - stages
                                                  ; are 1-based (C is
                                                  ; never 0 here)
msgStg1:  db "STG1 OK", 0
msgStg2:  db "STG2 OK", 0
msgStg3:  db "STG3 OK", 0
msgStg2a: db "STG2A OK", 0
msgStg2b: db "STG2B OK", 0
msgStg2c: db "STG2C OK", 0
msgStg2d: db "STG2D OK", 0
msgStg2e: db "STG5 OK", 0     ; C=8: VS2E (vidStageLimit=5) - full serve
                               ; loop, no post-frame
msgStg6:  db "STG6 OK", 0     ; C=9: vidStageLimit=6 - +audio copy-out
msgStg7:  db "STG7 OK", 0     ; C=10: vidStageLimit=7 - +palette apply
msgStg2f: db "STGF OK", 0     ; C=11: VS2F (vidStageLimit=8) - the
                               ; .monopix-shape deconfounder
msgStgErr: db " ERR=", 0
msgStgDp:  db " DRAWPG=", 0   ; owner addendum: settles the walk's own
                               ; base with one printed byte (vidDrawPage
                               ; at .stagegate time) - meaningless for
                               ; stage 1 (exits before .frameloop sets
                               ; it), meaningful for every other stage
msgStgPb:  db " PIXBLK=", 0   ; owner addendum ("convict the trampler"
                               ; follow-up): vidPixBlocks, 16-bit hex -
                               ; a real serve always shows a nonzero
                               ; count here; meaningful on every marker
                               ; (unlike DRAWPG, this field is populated
                               ; by nxv_open, strictly before any marker
                               ; can print, on every stage including 1)

; Owner addendum (fresh-eyes round 3): filemap dump - RUNS=nn (entry
; count) and RUN1=xxxx (first run's own block count, 16-bit hex) -
; converts run-boundary questions from inference to reading,
; permanently. vidFilemapBuf/vidStrmEntryEnd are VID_PAGE-resident
; (populated by vid_raw_setup at file-open time, already valid by the
; time ANY stage marker prints), read here via the established MMU6-
; translated-address bracket - this routine itself runs entirely cold
; (VID_PAGE2, called from vid_stage_marker_body, already cold), so it
; costs nothing against the hot-page budget. RUNS is computed by
; repeated subtraction (no divide instruction; at most 32 iterations,
; the buffer's own entry cap - cheap and one-shot, not hot). Row 23,
; directly below the STGn marker's own row 22. Corrupts everything.
vid_filemap_dump:
    call data_save
    ld a, VID_PAGE
    call data_map_page
    ld hl, (vidStrmEntryEnd+DATA_WINDOW-OVL_ORG)
    ; owner bug fix (address-space mismatch caught by the "convict the
    ; trampler" audit): the VALUE stored in the vidStrmEntryEnd CELL is a
    ; REAL VID_PAGE (OVL_ORG-space) address - vid_raw_setup converts it
    ; back with `ld de,OVL_ORG-DATA_WINDOW / add hl,de` before storing
    ; (above, this file) specifically so hot code (vid_next_run) can
    ; compare it directly against vidStrmEntryPtr with no translation.
    ; HL above is therefore already real-space. DE must match: the bare
    ; `vidFilemapBuf` label (real/OVL_ORG-space), NOT the +DATA_WINDOW-
    ; OVL_ORG translated form - that translated form is only correct
    ; when BOTH sides of a subtraction are translated (vid_raw_setup's
    ; own .roomok comment: "the translation cancels in the difference").
    ; Mixing one real address with one translated address here made HL
    ; run high by exactly DATA_WINDOW-OVL_ORG (8192), so the repeated
    ; -6 division below wrapped the 8-bit counter into a bogus RUNS
    ; value (observed: 0x57) - not file-map corruption, an instrument
    ; bug in this diagnostic itself.
    ld de, vidFilemapBuf
    or a
    sbc hl, de                      ; HL = bytes of entries written
    ld b, 0
.divloop:
    ld a, l
    sub 6
    ld l, a
    ld a, h
    sbc a, 0
    ld h, a
    jr c, .divdone
    inc b
    jr .divloop
.divdone:
    ld hl, (vidFilemapBuf+4+DATA_WINDOW-OVL_ORG)  ; RUN1 = entry 0's own
                                                    ; block count (offset
                                                    ; 4: AddrLo(2)+
                                                    ; AddrHi(2)+Blocks(2))
    push hl                          ; stash RUN1 across data_restore
    push bc                          ; stash RUNS (B) across data_restore
    call data_restore
    ld b, 23
    ld c, 0
    call dbg_at
    ld hl, msgFmRuns
    call dbg_puts
    pop bc
    ld a, b
    call dbg_hex8
    ld hl, msgFmRun1
    call dbg_puts
    pop hl
    call dbg_hex16
    ret

msgFmRuns: db "RUNS=", 0
msgFmRun1: db " RUN1=", 0
 ENDIF

; Per-video-mode (NR $11 bits 2:0) CTC time constant for the two
; supported NXV audio rates (nextdaad.inc's NXV_RATE_STEREO/MONO),
; mirroring aud_ctc_params' algorithm (overlay1.asm) collapsed to these
; two fixed rates - duplicated rather than cross-called since overlay1 is
; a different MMU7 page, unreachable during playback. Derived from the
; SAME per-mode clock table (aud_clk16_tab) at assemble time: TC =
; floor(clk16[mode] / rate). BOTH tables land CW16 (never CW256) on
; EVERY video mode - verified with a Python cross-check against aud_
; clk16_tab's own values (the T1 report's method), no sentinel needed
; (unlike the old fmt0/1-only vidCtcTcTab0): the /16-vs-/256 crossover
; (clk16>>8, ~6835-8056 across modes) stays below BOTH 15625 and 23325 on
; every mode, with margin. Achieved-rate error (TC quantization, the
; project's own accepted class of imprecision): stereo 0.00%-0.73% across
; modes, mono 0.04%-1.22% - both well inside the range every prior CTC
; table in this codebase already ships. VGA0 112, VGA1 114, VGA2 117,
; VGA3 120, VGA4 124, VGA5 128, VGA6 132, HDMI 108 (achieved Hz: 15625,
; 15664.16, 15739.46, 15625, 15625, 15625, 15625, 15625).
vidCtcTcNxvStereo:
    db 112, 114, 117, 120, 124, 128, 132, 108

; Same derivation, NXV_RATE_MONO (23325 Hz - the SAME true rate the old
; fmt4/5 mono format already derived, VID_RATE4_X10's own "23300, not
; exact" disclosure, sp13-task-2-report.md, reused verbatim). VGA0 75,
; VGA1 76, VGA2 78, VGA3 80, VGA4 83, VGA5 85, VGA6 88, HDMI 72 (achieved
; Hz: 23333.33, 23496.24, 23609.19, 23437.50, 23343.37, 23529.41,
; 23437.50, 23437.50).
vidCtcTcNxvMono:
    db 75, 76, 78, 80, 83, 85, 88, 72

; Loads the copper list and starts FRAME mode. Corrupts AF.
;
; OWNER GATE LEG POSTMORTEM (SP14a T4 follow-up, all-profile hardware
; crash, first-ever hardware execution of the NXV path): this routine
; USED TO send a "RESET pulse" (NR $62 = %01000000, mode 01 - resets
; CPC to 0 AND STARTS the copper running) BEFORE stopping it and
; loading fresh bytes - intended to "clear any stale mid-list PC from a
; prior run", per the removed comment. That reasoning was wrong on two
; counts: (1) mode 01/11 ALREADY resets CPC to 0 as an intrinsic part of
; starting - the final FRAME-mode start below does this unconditionally,
; making a separate reset step redundant regardless of any prior CPC
; value; (2) far worse, sending mode 01 BEFORE the fresh list is loaded
; makes the copper immediately START EXECUTING from CPC=0 on WHATEVER
; STALE OR UNINITIALIZED BYTES currently sit in copper RAM - two Z80
; instructions' worth of real time (the index-low write and its own
; dispatch) during which the copper, running at a comparable clock,
; can execute several of its own instructions. Copper MOVE covers NR
; $00-$7F, which INCLUDES the MMU registers ($50-$57) - one garbage
; MOVE hitting NR $50/$51 (MMU6/MMU7) at raster time corrupts the live
; memory map under the running CPU: freeze or reset, exactly the
; observed signature, on the FIRST-EVER hardware exercise of this list
; (copper RAM content at that point is unknown/unproven - this build
; had never driven the copper before). Fixed: go straight to STOP
; (mode 00 - "CPC keeps its current value", no execution happens in
; this mode, so stale content is inert) before touching the index or
; uploading anything, matching the dev guide's own safe example order
; (chapter-next-copper.tex "Example": NEXTREG &61 then &62=stop-mode,
; never a mode-01/11 write before the list is loaded). The final FRAME-
; mode start (unchanged, below) is what actually resets CPC for the
; fresh list - it always was, the removed pulse just did it redundantly
; and dangerously one step early.
;
; Initial MOVE data bytes are the CURRENT (pre-flip) bank/palctl -
; harmless status-quo values in the unlikely event a vblank lands
; before the first CPU poke overwrites them. l2FrontBank is RESIDENT
; (not VID_PAGE), so no MMU6 translation is needed to read it here.
;
; UNCALLED (owner fix, palette sparkle/magenta parity-chain audit): the
; per-frame poke this list was designed for (vid_copper_poke, formerly
; VID_PAGE) raced vid_apply_palette's own direct NR $43 writes - see
; the retired flip block's header (vid_run, VID_PAGE) for the full
; mechanism. Left defined, not deleted: the WAIT line (257) is real,
; owner-hardware-validated geometry (VBENCH-COPPER leg, SP14a T3) that
; a future correct integration could still use, PROVIDED it also
; brackets vid_apply_palette's 256-entry loop against this list's own
; MOVE (a copper STOP/START around the loop, or equivalent), which this
; routine alone does not provide.
vid_copper_init:
    xor a
    nextreg NR_COPPER_ADDR_LO, a    ; write-index low = 0 - safe regardless
                                     ; of current mode (only $62 controls
                                     ; execution state, never $61)
    nextreg NR_COPPER_ADDR_HI_CTRL, a  ; index hi = 0, control = STOP (00) -
                                        ; copper is inert from here until
                                        ; the FRAME-mode start below; no
                                        ; execution window on stale/
                                        ; uninitialized list content
    ld a, %10000001                 ; WAIT hi: H=0, V bit8=1 (257 >= 256)
    nextreg NR_COPPER_DATA, a
    ld a, NXV_COPPER_LINE & $FF
    nextreg NR_COPPER_DATA, a       ; WAIT lo: V low 8 bits (257&$FF=1)
    ld a, NR_L2_BANK
    nextreg NR_COPPER_DATA, a       ; MOVE1 hi: register $12
    ld a, (l2FrontBank)
    nextreg NR_COPPER_DATA, a       ; MOVE1 lo: initial bank
    ld a, NR_PAL_CTRL
    nextreg NR_COPPER_DATA, a       ; MOVE2 hi: register $43
    ld a, PAL_L2_FIRST
    nextreg NR_COPPER_DATA, a       ; MOVE2 lo: initial palctl
    ld a, $FF                        ; HALT (WAIT $FFFF)
    nextreg NR_COPPER_DATA, a
    nextreg NR_COPPER_DATA, a
    ld a, %11000000                  ; control = FRAME, start running
    nextreg NR_COPPER_ADDR_HI_CTRL, a
    ret

; Program a fixed identity RRRGGGBB palette (value[i] = i) once at entry
; for no-per-frame-palette files (vidPalFlag=0 - their pixel bytes ARE
; their own colour). Dodges TM_TRANSP_ATTR the same way (entry 254 ->
; colour $FF instead of its "natural" identity value $FE) and, like
; vid_apply_palette, does NOT also force-stamp entry 254 to genuinely BE
; TM_TRANSP_ATTR afterward - see vid_apply_palette's header for why: no
; source content is guaranteed to avoid pixel value 254, so reserving it
; as transparent would punch real content through to the tilemap. Byte1
; (the expanded 9th blue bit) matches the Next's own 8-bit->9-bit
; hardware expansion rule ("least significant bit of blue is set to OR
; between B2 and B1", docs/zx-next-dev-guide-2022-07-15/chapter-next-
; palette.tex:176 - byte1 = 1 iff the index's two blue bits, i&3, are
; nonzero), the SAME rule tests/videnc.py's palette builder uses.
; Corrupts AF, BC.
vid_identity_palette:
    nextreg NR_PAL_CTRL, PAL_L2_FIRST
    nextreg NR_PAL_INDEX, 0
    ld b, 0                        ; 256 iterations
    ld c, 0                        ; ascending palette index
.loop:
    ld a, c
    cp TM_TRANSP_ATTR
    jr nz, .w
    ld a, $FF
.w:
    nextreg NR_PAL_VALUE9, a
    ld a, c
    and 3
    jr z, .noblue
    ld a, 1
    jr .haveblue
.noblue:
    xor a
.haveblue:
    nextreg NR_PAL_VALUE9, a
    inc c
    djnz .loop
    ret

; ---------------------------------------------------------------------
; vid_run_restore_body - the bulk of vid_run's own teardown (VID_PAGE
; budget lever - this was the single largest hot routine before the
; split). Reached from vid_run's own .restore (VID_PAGE, above) AFTER
; the CTC has already been stopped and vid_stream_close has already run
; (both genuinely need to be hot - the CTC-off must happen before the
; ISR could fire again, and vid_stream_close is itself VID_PAGE-resident
; code) - everything left (IM2 stub restore, Layer 2/palette/
; presentation-isolation restore, freeing the pool bank) touches only
; RESIDENT memory (audEnable, l2FrontBank/l2BackBank, IM2_CTC_STUB) or
; NextReg I/O (no MMU-page dependency either way) or VID_PAGE-resident
; vidSv* cells read via the established MMU6-translated bracket - none
; of it needs MMU7 = VID_PAGE. Hops back to vid_run.restore_tail (VID_
; PAGE) for the DEBUG report (its own existing, unchanged hot/cold/hot
; mechanism) and the final MMU6/7 restore. Corrupts everything.
vid_run_restore_body:
    call data_save
    ld a, VID_PAGE
    call data_map_page
    ld hl, (vidSvCtcStub+DATA_WINDOW-OVL_ORG)
    ld (IM2_CTC_STUB+1), hl
    ld a, (vidSvAudEnable+DATA_WINDOW-OVL_ORG)
    ld (audEnable), a
    ld a, (vidSvL2Front+DATA_WINDOW-OVL_ORG)
    ld (l2FrontBank), a
    ld a, (vidSvL2Back+DATA_WINDOW-OVL_ORG)
    ld (l2BackBank), a
    ld a, (vidSvNr12+DATA_WINDOW-OVL_ORG)
    nextreg NR_L2_BANK, a
    ld a, (vidSvNr70+DATA_WINDOW-OVL_ORG)
    nextreg NR_L2_CTRL, a
    ld a, (vidSvNr69+DATA_WINDOW-OVL_ORG)
    nextreg NR_DISPLAY_CTRL, a
    ld a, (vidSvNr15+DATA_WINDOW-OVL_ORG)
    nextreg NR_LAYERS, a
    ; SP14a T2: NR $43 restored to the game's own convention (captured as
    ; PAL_L2_FIRST at entry, not read back - see vid_run's own entry-
    ; capture comment). l2_palette_load unconditionally re-asserts PAL_
    ; L2_FIRST before every picture display anyway (design note), but
    ; restoring it here too keeps the symmetry doctrine exact, matching
    ; NR $12/$70/$69/$15 immediately above.
    ld a, (vidSvNr43+DATA_WINDOW-OVL_ORG)
    nextreg NR_PAL_CTRL, a
    ; presentation isolation: restore the tilemap + fallback colour
    ; (symmetry-matrix rows, spec requirement) - reached only via a real
    ; playback session (.restore_badhdr/.restore_noplay never touch
    ; these, since they bail before this pair is ever saved/disabled).
    ld a, (vidSvNr6b+DATA_WINDOW-OVL_ORG)
    nextreg NR_TM_CTRL, a
    ld a, (vidSvNr4a+DATA_WINDOW-OVL_ORG)
    nextreg NR_FALLBACK, a
    ld a, (vidAudPoolBank+DATA_WINDOW-OVL_ORG)
    call bank_free                   ; resident, MMU6-independent - safe
                                      ; to call before data_restore, no
                                      ; stash needed
    call data_restore
    ld hl, vid_run.restore_tail
    push hl
    ld a, VID_PAGE
    jp ovl_map_page

; Build vidName ("NNN.VID",0) from the video number (passed via C, set
; by vid_play before the hop - see vid_open_video's own header, VID_PAGE)
; - 3-digit zero-padded decimal, the project's repeated-subtraction
; decade idiom. curPart > 1 also builds vidNamePart ("PARTn\NNN.VID",0)
; and tries it FIRST, root as fallback - the established PARTn probe
; idiom (SP11 T5's four other sites); curPart == 1 skips straight to
; root, zero new opens. curPart is RESIDENT (errors.asm, always mapped -
; no translation needed to read it here, unlike the VID_PAGE-resident
; cells below). Sets vidStrmMode = 1 (raw) before every open attempt -
; the player always uses raw mode (T1's pinned contract; F_READ mode is
; bench-only). Out (via the hop back to vid_open_video_ret): CF clear =
; opened; CF set = neither name opened. Corrupts everything.
vid_open_video_body:
    call data_save
    ld a, VID_PAGE
    call data_map_page            ; MMU6 window held for this WHOLE body -
                                   ; nothing else needs it during this
                                   ; pre-arm, single-threaded sequence
    ld a, c                       ; C = video number
    ld hl, vidName
    ld b, '0'-1
.hund:
    inc b
    sub 100
    jr nc, .hund
    add a, 100
    ld (hl), b
    inc hl
    ld b, '0'-1
.tens:
    inc b
    sub 10
    jr nc, .tens
    add a, 10
    ld (hl), b
    inc hl
    add a, '0'
    ld (hl), a
    inc hl
    ex de, hl                     ; de = vidName+3 (write cursor)
    ld hl, vidExtVid              ; ".VID",0 (5 bytes)
    ld bc, 5
    ldir
    ld a, 1
    ld (vidStrmMode+DATA_WINDOW-OVL_ORG), a  ; hot-resident - translated
    ld a, (curPart)
    dec a
    jr z, .openroot
    ld hl, vidNamePart
    ld (hl), 'P'
    inc hl
    ld (hl), 'A'
    inc hl
    ld (hl), 'R'
    inc hl
    ld (hl), 'T'
    inc hl
    ld a, (curPart)
    add a, '0'
    ld (hl), a
    inc hl
    ld (hl), '\'
    inc hl
    ex de, hl                     ; de = vidNamePart+6
    ld hl, vidName
    ld bc, 8                      ; "NNN.VID",0
    ldir
    ld ix, vidNamePart
    call vid_stream_open_body     ; same page - plain call, no hop
    jr nc, .done                  ; PARTn open succeeded
.openroot:
    ld ix, vidName
    call vid_stream_open_body
.done:
    ld b, 0
    jr nc, .haveresult
    ld b, 1
.haveresult:
    call data_restore
    ld hl, vid_open_video_ret
    push hl
    ld a, VID_PAGE
    jp ovl_map_page

vidExtVid: db ".VID", 0

; SP14a T4 owner follow-up (VID_PAGE budget, post-VIDBENCH-retirement):
; three small DEBUG-only diagnostic prints moved cold from VID_PAGE -
; vid_play's own missing-file bail (vid_open_video failed) and vid_run's
; own bank_alloc-failure and bad-header bails. All three are provably
; reached strictly BEFORE the CTC ever arms (each hot call site's own
; comment), so hopping cold for the print, then hopping straight back,
; is exactly as safe as every other pre-arm cold hop in this file.
; dbg_at/dbg_puts are resident (debug.asm), reachable unchanged from
; here. Each ends with a hop back to its own hot landing point.
 IFDEF DEBUG
vid_play_missing_body:
    ld b, 23
    ld c, 0
    call dbg_at
    ld hl, msgVidMissing
    call dbg_puts
    ld hl, vid_play.missingret
    push hl
    ld a, VID_PAGE
    jp ovl_map_page

vid_run_nobank_body:
    ld b, 23
    ld c, 0
    call dbg_at
    ld hl, msgVidNoBank2
    call dbg_puts
    ld hl, vid_run.nobankret
    push hl
    ld a, VID_PAGE
    jp ovl_map_page

vid_run_badfmt_body:
    ld b, 23
    ld c, 0
    call dbg_at
    ld hl, msgVidBadFmt
    call dbg_puts
    ld hl, vid_run.badfmtret
    push hl
    ld a, VID_PAGE
    jp ovl_map_page

msgVidMissing:  db "VID FILE?", 0
msgVidNoBank2:  db "VID NOBANK2", 0
msgVidBadFmt:   db "VID FMT?", 0
 ENDIF

; The real open body (renamed from vid_stream_open, moved cold - see
; that name's hot stub, VID_PAGE, for why and for the callers). Same
; contract as before: IX = filename pointer in; CF/A(error code) out
; (via the hop back for hot callers, or a plain ret for the same-page
; vid_open_video_body caller above). Touches vidHandle/vidStrmMode/
; vidSizeLo/vidSizeHi (all VID_PAGE-resident - hot code needs them, see
; their own declarations) via the MMU6 translation vid_open_video_body
; holds open for this whole cluster's execution. vidFstatBuf is VID_
; PAGE2-local (this page IS what MMU7 shows while this code runs), so
; F_FSTAT's own IX-target write needs no translation. vid_raw_setup
; (below, also VID_PAGE2 now - SP14a T3 wave 2's own byte-budget pass
; moved it here too, reusing this SAME already-open MMU6 bracket rather
; than the earlier cold-calls-hot hop) is a plain same-page call.
; NOTE: sjasmplus scopes a dot-local label (.foo) to the nearest PRECEDING
; global (non-dot) label - since this routine's own hop-out/hop-back
; needs an intervening global label (vid_stream_open_resetret, below -
; referenced from OTHER routines, so it must be global), the shared exit
; points below (fail/fstat/openfail) are given explicit global names
; instead of dot-locals, so every jr/jp to them resolves regardless of
; which global label precedes the jump site. Corrupts AF, BC, DE, HL, IX.
vid_stream_open_body:
    ld a, $FF
    ld (vidHandle+DATA_WINDOW-OVL_ORG), a
    call esx_getsetdrv
    jr c, vid_stream_open_fail
    ld b, ESX_MODE_READ
    call esx_fopen               ; IX = caller's filename, untouched
    jr c, vid_stream_open_fail   ; since esx_getsetdrv/the ld b above
    ld (vidHandle+DATA_WINDOW-OVL_ORG), a
    ; DISK_FILEMAP MUST run first - before F_FSTAT or any other file
    ; access (a prior access perturbs the sector-cache state the map
    ; walks, giving a wrong card address the card rejects; playvid
    ; parity). F_READ mode never maps.
    ld a, (vidStrmMode+DATA_WINDOW-OVL_ORG)
    or a
    jr z, vid_stream_open_fstat
    call vid_raw_setup            ; raw: capture + validate the filemap
    jr c, vid_stream_open_openfail ; NOW - same page, plain call
vid_stream_open_fstat:
    ld a, (vidHandle+DATA_WINDOW-OVL_ORG) ; F_FSTAT (both modes) - legal
    ld ix, vidFstatBuf                     ; AFTER FILEMAP, before opening
    rst $08                                ; the card for streaming
    db ESX_F_FSTAT
    jr c, vid_stream_open_openfail
    ld hl, (vidFstatBuf+7)
    ld (vidSizeLo+DATA_WINDOW-OVL_ORG), hl
    ld hl, (vidFstatBuf+9)
    ld (vidSizeHi+DATA_WINDOW-OVL_ORG), hl
    ld a, (vidStrmMode+DATA_WINDOW-OVL_ORG)
    or a
    ret z                        ; F_READ mode: CF clear (from or a), done
    ; raw: reset the whole cursor (entry ptr/remain/run/tail state) via
    ; the SAME routine the loop-mode restart shares - hot (VID_PAGE), so
    ; reaching it needs the cold-calls-hot hop too.
    ld hl, vid_raw_reset_cursor_coldcall
    push hl
    ld a, VID_PAGE
    jp ovl_map_page
vid_stream_open_resetret:
    or a                         ; CF clear
    ret
vid_stream_open_openfail:
    push af                      ; close the handle, propagating A (esxDOS
    ld a, (vidHandle+DATA_WINDOW-OVL_ORG) ; code or VID_ERR_* from the
    call esx_fclose                        ; filemap step)
    ld a, $FF
    ld (vidHandle+DATA_WINDOW-OVL_ORG), a
    pop af
    scf
    ret
vid_stream_open_fail:
    scf
    ret

; Raw-mode filemap capture: runs IMMEDIATELY after F_OPEN, BEFORE F_FSTAT
; or any other video-file access (F_FSTAT alone is metadata-only, but the
; map still walks the GLOBAL sector cache, which prior game/file I/O
; leaves pointing mid-file). So we apply stream.asm's touched-file reset
; unconditionally first (seek 0, read 1 byte, seek 0) to repoint the
; cache at the file's first sector, THEN DISK_FILEMAP - the production-
; normal case is a hot cache (T2 opens videos after arbitrary game I/O).
; Fails (CF set, A = code) if the map came back empty (VID_ERR_NOMAP) or
; the file needs more runs than the 32-entry buffer holds (VID_ERR_FRAG -
; DISK_FILEMAP reported zero unused entries, i.e. it filled the buffer
; and may have had more; the kit's defrag advice applies). Records the
; card granularity (cardflags bit 1: 0 = byte addresses, +512/block; 1 =
; block addresses, +1/block) as the per-block step. Does not reset the
; run/tail cursor itself (that is vid_raw_reset_cursor's job, shared with
; the loop-mode restart - VID_PAGE); remain is primed by the caller after
; F_FSTAT yields the size.
;
; SP14a T3 wave 2: COLD (VID_PAGE2, moved here from VID_PAGE - reached by
; a plain same-page call from vid_stream_open_body's raw-mode branch,
; above; this was kept hot through wave 1 for a conservative first pass,
; then moved once wave 2's own case-unroll needed the extra headroom -
; the DISK_FILEMAP call's multi-byte IX-target write and its HL address
; return use the SAME MMU6 data-window translation (DATA_WINDOW-OVL_ORG)
; vid_stream_open_body already relies on, held open by vid_open_video_
; body for this whole cluster's execution - no new technique, no new
; risk class). vidHandle/vidCardFlags/vidStrmEntryEnd/vidFilemapBuf stay
; VID_PAGE-resident (hot code needs them - vid_strm_start/vid_next_run);
; vidRawResetByte is VID_PAGE2-local (never read back, no hot reader).
; Corrupts AF, BC, DE, HL, IX.
vid_raw_setup:
    ; stream.asm touched-file reset (global sector cache): repoint it at
    ; the first sector before mapping, else DISK_FILEMAP walks from wherever
    ; the last file access left it and returns a wrong card address the card
    ; rejects. Required before EVERY map - the cache is process-wide.
    call vid_raw_seek0           ; F_SEEK -> offset 0
    ret c
    ld a, (vidHandle+DATA_WINDOW-OVL_ORG) ; F_READ one byte (cache primer)
    ld ix, vidRawResetByte
    ld bc, 1
    call esx_fread
    ret c
    call vid_raw_seek0           ; F_SEEK back -> offset 0
    ret c
    ld a, (vidHandle+DATA_WINDOW-OVL_ORG)
    ld ix, vidFilemapBuf+DATA_WINDOW-OVL_ORG ; hot-resident target - see
    ld de, VID_FILEMAP_ENT                    ; vid_next_run
    rst $08
    db ESX_DISK_FILEMAP
    ret c                        ; A = esxDOS error, CF set
    ; DE = unused entries, HL = address past last written entry (both in
    ; the MMU6-translated space, since IX was translated too), A = flags
    ld (vidCardFlags+DATA_WINDOW-OVL_ORG), a
    ld a, e                      ; unused == 0 -> buffer was full, treat as
    or d                          ; over-fragmented (cannot prove complete)
    jr nz, .roomok
    ld a, VID_ERR_FRAG
    scf
    ret
.roomok:
    ld de, vidFilemapBuf+DATA_WINDOW-OVL_ORG
    or a
    sbc hl, de                    ; HL = bytes of entries written (the
                                   ; translation cancels in the difference)
    jr nz, .haveentries
    ld a, VID_ERR_NOMAP           ; empty map: nothing to stream
    scf
    ret
.haveentries:
    add hl, de                    ; re-form the end address (still in the
                                   ; translated space, since DE is too)
    ld de, OVL_ORG - DATA_WINDOW  ; convert back to VID_PAGE's own real
    add hl, de                    ; address space - vid_next_run (hot)
                                   ; compares this directly against vidStrm
                                   ; EntryPtr, which vid_raw_reset_cursor
                                   ; always sets as a real address (it runs
                                   ; genuinely resident on VID_PAGE)
    ld (vidStrmEntryEnd+DATA_WINDOW-OVL_ORG), hl
    ; Card granularity (cardflags bit 1: byte vs 512-byte-block addresses)
    ; needs no handling: DISK_FILEMAP already returns each run's start address
    ; in the card's native CMD18 units, and the persistent CMD18 window
    ; streams successive blocks internally - we never compute a per-block
    ; address, so no step is derived. (bit 0 = card id is still used, for the
    ; CS0/CS1 select in vid_sd_cmd.)
    or a                          ; CF clear
    ret

; F_SEEK the video handle to absolute offset 0. NextZXOS F_SEEK: A=handle,
; BCDE=offset, IXL=mode (0 = from start; IX is the register that matters,
; L set too belt-and-braces - see overlay0.asm's xmes seek). Out: CF set =
; esxDOS error (A = code). Corrupts AF, BC, DE, HL, IX.
vid_raw_seek0:
    ld bc, 0
    ld de, 0
    ld l, 0
    ld ix, 0
    ld a, (vidHandle+DATA_WINDOW-OVL_ORG)
    jp esx_fseek

vidRawResetByte: db 0             ; F_READ target for the pre-map cache
                                   ; primer (discarded, never read back)

vidName:     ds 8             ; "NNN.VID",0
vidNamePart: ds 14            ; "PARTn\NNN.VID",0
vidFstatBuf: ds 11             ; F_FSTAT buffer: +0 '*' +1 $81 +2 attr
                                ; +3 time +5 date +7(4) size (esxDOS API)

; ------------------------------------------------------------------
; DEBUG-only content below (unchanged in shape from SP14a T1/T2 - wave 1
; only made the PAGE unconditional, not this section's own guard).
; ------------------------------------------------------------------
 IFDEF DEBUG

VID_TL_ROW0 equ 24              ; rows 24-28 (this task's own report rows;
                                 ; VIDBENCH, the harness that once used
                                 ; rows 28-29, is retired - SP14a T4)

; Print the 32-bit little-endian value at (HL) as 8 hex digits (two
; dbg_hex16 calls, high word then low word). Report-only (called
; strictly after playback teardown - see vid_tl_report's header) so the
; IX-avoidance constraint that applies to vid_tl_stamp/the ISRs does NOT
; apply here. Corrupts AF, DE, HL.
vid_tl_print32:
    push hl
    inc hl
    inc hl
    ld e, (hl)
    inc hl
    ld d, (hl)
    ex de, hl
    call dbg_hex16                  ; high word
    pop hl
    ld e, (hl)
    inc hl
    ld d, (hl)
    ex de, hl
    jp dbg_hex16                     ; low word, tail call

; The frame-timeline report - rows 24-27: one phase's 32-bit tick total
; per row (VID_TL_STREAM..VID_TL_FLIPPACE). Row 28: VID_TL_OTHER's total
; PLUS the timeline's own grand total (vidTlTicks, the absolute tick
; count since vid_run's entry reset) and vidTlFrames (frame-loop
; iterations reached). Reached only via vid_tl_report's own hop (VID_PAGE,
; above) - lands here with MMU7 == VID_PAGE2. Corrupts everything.
vid_tl_report_body:
    ; SP14a T1 fix wave (owner leg feedback): the leftover video frame
    ; remains on Layer 2 after teardown (content not preserved by
    ; design) - by this point NR $69 already holds its pre-video vidSv-
    ; captured value (vid_run's .restore path writes it back BEFORE this
    ; report is called, above), but if Layer 2 was on before playback
    ; started, the tilemap's transparent paper lets that stale L2
    ; content show through and makes these rows unreadable. Read-modify-
    ; write NR $69 (an already-established readable register in this
    ; exact file - vid_run's own entry sequence captures it via this
    ; same nr_read pattern) to clear bit 7 (Layer 2 enable) before
    ; printing. Deliberately NOT restored afterward - this path is
    ; DEBUG-only and reached after every other piece of game state is
    ; already back to normal; the next real GFX/picture load re-enables
    ; Layer 2 unconditionally (gfx_blit's own DISPLAY path), so nothing
    ; downstream depends on this bit's value surviving the report.
    ld e, NR_DISPLAY_CTRL
    call nr_read
    and %01111111
    nextreg NR_DISPLAY_CTRL, a

    ; SP14a T1 fix wave 2 (owner leg feedback): vidTlTicks/vidTlLastTick/
    ; vidTlLastPhase/vidTlFrames/vidTlAcc are VID_PAGE-resident data (see
    ; their declarations above vid_tl_stamp) - by this point MMU7 ==
    ; VID_PAGE2 (vid_tl_report's own trampoline hop already ran), so a
    ; DIRECT read of those labels' own $E0xx addresses hits VID_PAGE2's
    ; own never-written bytes at that offset instead of the real data -
    ; every field reads zero (the control-flow hop is fine; the DATA does
    ; not come along automatically - MMU7 is a runtime remap, not a
    ; compile-time one). Fix: copy the whole VID_TL_BLOCK_LEN-byte (29,
    ; since the SP14a T3 fix waves extended it through vidErrCode then
    ; vidErrByte - computed, not hand-counted, so this comment can't
    ; drift again) block across via the MMU6 window (data_save/data_map_
    ; page(VID_PAGE)/LDIR/data_restore - MMU6 is free here, post-teardown;
    ; the same
    ; convention this file uses everywhere else for a transient cross-
    ; page read) into a page-local mirror (vidTlTicksL.. below) BEFORE any
    ; real print runs. Source address: vidTlTicks's own VID_PAGE address
    ; translated to the MMU6 $C000 window (vidTlTicks + DATA_WINDOW -
    ; OVL_ORG = vidTlTicks - $2000). Dest: vidTlTicksL, an ordinary
    ; VID_PAGE2-local label - its own absolute address is already correct
    ; for THIS page, no translation needed (only the SOURCE crosses
    ; pages).
    call data_save
    ld a, VID_PAGE
    call data_map_page
    ld hl, vidTlTicks + DATA_WINDOW - OVL_ORG
    ld de, vidTlTicksL
    ld bc, VID_TL_BLOCK_LEN
    ldir
    call data_restore

    ld a, VID_TL_ROW0
    ld (vidTlRptRow), a
    xor a
    ld (vidTlRptIdx), a
.rowloop:
    ld a, (vidTlRptRow)
    ld b, a
    ld c, 0
    call dbg_at
    ld a, (vidTlRptIdx)
    add a, a
    ld l, a
    ld h, 0
    ld de, vidTlMsgTab
    add hl, de
    ld e, (hl)
    inc hl
    ld d, (hl)
    ex de, hl
    call dbg_puts
    ld a, (vidTlRptIdx)
    add a, a
    add a, a
    ld l, a
    ld h, 0
    ld de, vidTlAccL
    add hl, de
    call vid_tl_print32
    ld a, (vidTlRptIdx)
    cp VID_TL_OTHER                 ; last row (summary trails whichever
                                     ; row prints last, purely cosmetic)
    jr nz, .nextrow
    ld hl, msgTlTot
    call dbg_puts
    ld hl, (vidTlTicksL)
    call dbg_hex16
    ld hl, msgTlFrm
    call dbg_puts
    ld hl, (vidTlFramesL)
    call dbg_hex16
    ld hl, msgTlErr
    call dbg_puts
    ld a, (vidErrCodeL)
    call dbg_hex8
    ld hl, msgTlByt
    call dbg_puts
    ld a, (vidErrByteL)
    call dbg_hex8
    jr .done
.nextrow:
    ld hl, vidTlRptRow
    inc (hl)
    ld hl, vidTlRptIdx
    inc (hl)
    jr .rowloop
.done:
    ; hop back to VID_PAGE (vid_tl_report's own trampoline half) -
    ; MMU7 == VID_PAGE by the time vid_tl_report_ret executes there.
    ld hl, vid_tl_report_ret
    push hl
    ld a, VID_PAGE
    jp ovl_map_page

vidTlMsgTab:
    dw msgTl0, msgTl1, msgTl2, msgTl3, msgTl4
msgTl0: db "STREAM =", 0
msgTl1: db "BLIT   =", 0
msgTl2: db "PALETTE=", 0
msgTl3: db "PACE   =", 0
msgTl4: db "OTHER  =", 0
msgTlTot: db " TOT=", 0
msgTlFrm: db " FRM=", 0
msgTlErr: db " ERR=", 0
msgTlByt: db " BYT=", 0
vidTlRptRow: db 0
vidTlRptIdx: db 0

; Page-local mirror of the VID_PAGE-resident vidTlTicks..vidErrByte block
; (fix wave 2, above; SP14a T3 fix wave 2 extended it through vidErrByte -
; see that cell's own declaration) - same field order/sizes, filled by
; the pre-print LDIR, read by the report in place of the (unreachable-
; from-here) VID_PAGE originals. vidTlLastTickL/vidTlLastPhaseL are
; copied but never read here - kept only for exact layout parity with
; the source block, so the single LDIR's length (VID_TL_BLOCK_LEN) needs
; no special-casing.
vidTlTicksL:     dw 0
vidTlLastTickL:  dw 0
vidTlLastPhaseL: db 0
vidTlFramesL:    dw 0
vidTlAccL:       ds VID_TL_PHASES*4
vidErrCodeL:     db 0             ; mirrors vidErrCode - see that cell's
                                   ; own declaration for the ERR=xx
                                   ; convention (00 = clean EOF)
vidErrByteL:     db 0             ; mirrors vidErrByte - see that cell's
                                   ; own declaration for the BYT=xx decode

 ENDIF ; DEBUG

; VIDBENCH's cold-page bodies (vid_bench_compute/vid_bench_report),
; vidBenchName and their own message strings/cells are RETIRED along
; with the hot dispatcher (see that routine's own removal comment,
; VID_PAGE above) - owner decision, SP14a T4 follow-up.

    DISPLAY "video2 ends at ", $, " headroom ", /D, OVL_LIMIT - $
    ASSERT $ <= OVL_LIMIT
