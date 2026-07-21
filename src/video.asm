; NextDAAD code page: video (SP13 - MakeVid .VID cutscene playback).
; VID_PAGE (nextdaad.inc) = 59, the upper 8K of bank 29 - the only page
; in the overlay-reserved bank range (28/29) with no prior equate; see
; nextdaad.inc's VID_PAGE comment and this task's report for the full
; free-page derivation. Reached exactly like overlay0/1/2: MMU7 mapped
; to this page by whoever hops in (the engine dispatcher for condacts
; once Task 2 wires GFX/SFX; the DEBUG bench trampoline below for
; VIDBENCH), never resident code running in place.
;
; This file currently holds (Task 1): the format classifier, the
; F_READ-backed vid_stream_* streaming interface (Task 2's player
; consumes these three routines verbatim - signatures are pinned, see
; the task report), and a DEBUG-only benchmark harness. The player
; itself (vid_play, the CTC/Layer-2 machinery) is Task 2+.

    MMU 7, VID_PAGE, OVL_ORG

; ---------------------------------------------------------------------
; vid_classify
; ---------------------------------------------------------------------
; In: HL = file size low word, DE = file size high word (the 32-bit
;     "DEHL" convention - DE:HL, high:low; ext_xmes/ddb_load use the
;     narrower ddbSizeHi:ddbSize shape for the 128K-capped DDB, but video
;     files run far larger, so this takes the full word pair). Typical
;     caller sequence: ld hl,(vidSizeLo) / ld de,(vidSizeHi) after a
;     vid_stream_open.
; Out: CF clear, A = format 0-5 (priority order: 0 = 320x240 palette
;      (155 sectors/frame) .. 5 = 256x192 no-palette (98 sectors/frame) -
;      vidFormatSect below, VID_F0_SECT..VID_F5_SECT in nextdaad.inc).
;      CF set = unclassifiable (size not a whole number of 512-byte
;      sectors, or no format's frame-sector-count divides the sector
;      count exactly).
;
; Matches playvid's own algorithm exactly (tools/NextZXOS/src/c/
; DotCommands/playvid/sd.c: sd_classify_video_format / video_format_size)
; - classification works in 512-byte SECTORS, not raw bytes: reject any
; size that is not a whole number of sectors, then walk the six frame-
; sector-counts in priority order looking for an exact division.
;
; BLANK-FRAME-AMBIGUITY NOTE (spec, "Format classification"): a file
; whose sector count is ALSO an exact multiple of an EARLIER-priority
; format's frame-sector-count classifies as that earlier format instead
; - by design, matching playvid; the documented remedy is at ENCODE time
; (MakeVid appends one blank frame to break the coincidence), not here.
; This task's report cites a real example found in the tools/demo-files
; fixture matrix (one file collides with an earlier format's divisor;
; another fails to classify as itself at all - both are fixture-encoding
; properties, not classifier defects).
;
; SP14a T3 wave 1: COLD (VID_PAGE2). Provably never runs while the video
; CTC ISR is armed - vid_classify's only two callers are vid_play (calls
; it BEFORE `jp vid_run`, i.e. before the CTC ever arms this session) and
; the DEBUG-only vid_bench_compute (VIDBENCH never touches the CTC at
; all). This hot-page stub is the ONLY part left resident here: it hops
; to vid_classify_body (VID_PAGE2, below) via the established push-
; target/ovl_map_page trampoline (vid_tl_report's own precedent, this
; file) and back, preserving the plain `call vid_classify` contract for
; both callers unchanged. Register-only I/O (HL/DE in, A/CF out) is
; carried across the hop via B - `ovl_map_page`'s own `ld a,<page>`
; clobbers A, and CF is reconstructed explicitly at the landing stub
; rather than assumed to survive `nextreg`/`ret` untouched. The IN
; registers (HL/DE) are stacked here BEFORE the trampoline's own `ld
; hl,<target>` would otherwise clobber them, and popped back first thing
; in vid_classify_body - the hop machinery itself needs HL as its jump-
; target vehicle, so the caller's real HL/DE cannot be loaded until after
; that push. Corrupts AF, BC, DE, HL, IX.
vid_classify:
    push hl                      ; caller's HL (size low) - preserved
    push de                      ; caller's DE (size high) - preserved
    ld hl, vid_classify_body
    push hl
    ld a, VID_PAGE2
    jp ovl_map_page
vid_classify_ret:
    ld a, b
    cp $FF
    jr z, .bad
    or a                         ; CF clear, A = format (already in A)
    ret
.bad:
    scf
    ret

; ---------------------------------------------------------------------
; vid_stream_* - dual-mechanism streaming interface. The three
; signatures and their register contracts are PINNED (Task 2's player
; consumes them verbatim); a one-byte selector vidStrmMode chooses the
; internals: 0 = plain esxDOS F_READ, 1 = raw card streaming (DISK_FILEMAP
; for the address map, then direct SD SPI CMD18/CMD12 - playvid's
; transport, not the OS DISK_STRM* API). The caller sets vidStrmMode
; BEFORE vid_stream_open; all three routines honour it internally. The
; bench below drives one pass in each mode so the owner's re-leg
; measures both mechanisms end-to-end in a single run.
; ---------------------------------------------------------------------

; In: IX = ASCIIZ filename pointer (root name; no PARTn\ probing - that
;     is Task 2's job once vid_play knows the active part; this bench-
;     only entry always opens exactly the name it is given). vidStrmMode
;     selects the mechanism (see above).
; Out: CF clear = opened; vidHandle holds the esxDOS handle; vidSizeLo/
;      vidSizeHi hold the 32-bit byte size read via F_FSTAT (low word/
;      high word - feed straight into vid_classify as HL/DE).
;      CF set = failed (A = error code); vidHandle left at $FF. In raw
;      mode the code may be an esxDOS code OR VID_ERR_FRAG/VID_ERR_NOMAP
;      (nextdaad.inc - distinct so the bench can name the fragmentation
;      failure the kit's defrag guidance is written for).
;
; SP14a T3 wave 1: the real body (vid_stream_open_body, VID_PAGE2) is
; COLD - open-time only, provably never running while the video CTC ISR
; is armed (both real callers run before any CTC arm: vid_open_video_
; body's own two attempts, same VID_PAGE2 page, and the DEBUG-only vid_
; bench_pass, which never touches the CTC). vid_open_video_body calls
; vid_stream_open_body directly (same page, plain call, no hop). This
; hot-page stub exists ONLY for vid_bench_pass's sake, hopping to a small
; VID_PAGE2 wrapper (vid_stream_open_hopbody) that calls vid_stream_
; open_body and hops back - the same push-target/ovl_map_page trampoline
; as vid_classify's stub above, same B-carries-CF/A convention. Corrupts
; AF, BC, DE, HL, IX.
;
; vid_raw_setup/vid_raw_seek0 also moved to VID_PAGE2 (see below) - this
; hot-page stub itself is IFDEF DEBUG - its ONLY caller (vid_bench_pass)
; is DEBUG-only (VIDBENCH); vid_open_video_body's own two attempts go
; straight to vid_stream_open_body (same VID_PAGE2 page, no hop, no stub
; needed), so Release never reaches this trampoline at all - space
; recovered accordingly (see the task report's page arithmetic).
 IFDEF DEBUG
vid_stream_open:
    ld hl, vid_stream_open_hopbody
    push hl
    ld a, VID_PAGE2
    jp ovl_map_page
vid_stream_open_ret:
    ld a, b
    or a
    jr z, .ok
    ld a, c                      ; C = real error code (see vid_stream_
    scf                          ; open_hopbody's own carry)
    ret
.ok:
    or a
    ret
 ENDIF ; DEBUG

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
vid_read_block:
.wt:
    in a, (PORT_SPI_DAT)          ; poll for the block's data token
    inc a
    jr z, .wt                     ; $FF -> not ready yet, keep polling
    dec a                         ; recover the raw byte
    cp $FE                        ; $FE = valid data token
    jp nz, .tokbad                ; jp: .tokbad is past the 1024-byte unroll
    ld c, PORT_SPI_DAT
    DUP 512                       ; 512 unrolled INI at 16T/byte (playvid
      ini                          ; parity - the interface's peak rate; INIR
    EDUP                           ; would be 21T/byte). HL now += 512.
    in a, (c)                     ; skip the 2-byte CRC (the nops pad the
    nop                           ; in/in to the 16T/byte interface timing)
    in a, (c)
    nop
    or a                          ; CF clear: block read
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
; vid_play - the player core (SP13 Task 2 mono, Task 3 stereo, Task 4
; 320x240 full-bleed). All six formats 0-5 play (320x240 palette/no-
; palette, 256x240 stereo, 256x192 mono); vid_classify's CF (unclassifiable
; size) is the only fail-silent no-op left. Entry: B = video number,
; C = 0 play-once / 1 loop
; (h_gfx/h_sfx translate their own sub-command numbers into this before
; the cross-page hop - see nextdaad.inc's GFX_SUB_VID_*/SFX_SUB_VID_*).
; Probes PARTn\NNN.VID (curPart > 1) then root NNN.VID, classifies,
; plays, and ALWAYS returns via the restore path (vid_run's .restore/
; .restore_noplay) on every exit - key, EOF, or a read error. Corrupts
; everything; the caller (h_gfx.vidgo/h_sfx.vidgo) never resumes - this
; IS the tail of the dispatch, and the return lands directly on the
; engine dispatcher via the trampoline's stacked return address (the
; xpart_load_entry/vid_bench_trampoline push-target idiom).
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
    ld hl, (vidSizeLo)
    ld de, (vidSizeHi)
    call vid_classify
    jr c, .badfmt
    cp 6
    jr nc, .badfmt          ; defensive (vid_classify never returns > 5) -
                            ; SP13 T4: all six formats (0-5) now play; the
                            ; old cp2/jr c reject for 0/1 is gone
.haveformat:
    ld (vidFmt), a
    jp vid_run                    ; tail: vid_run's own restore paths ret
.badfmt:
 IFDEF DEBUG
    ld b, 23
    ld c, 0
    call dbg_at
    ld hl, msgVidBadFmt
    call dbg_puts
 ENDIF
    call vid_stream_close
    ret
.missing:
 IFDEF DEBUG
    ld b, 23
    ld c, 0
    call dbg_at
    ld hl, msgVidMissing
    call dbg_puts
 ENDIF
    ret

; Build vidName ("NNN.VID",0) from the video number, probe PARTn\ then
; root, open the winner. Out: CF clear = opened (vidHandle/vidSizeLo/Hi
; set); CF set = neither name opened.
;
; SP14a T3 wave 1: COLD (VID_PAGE2) - the whole name-build/PARTn-probe/
; open cluster runs exactly once per vid_play invocation, entirely before
; vid_run ever arms the CTC (provably: vid_play calls this, then vid_
; classify, then `jp vid_run` - the CTC's own first arm is deep inside
; vid_run, well after this cluster's work is done; the loop-mode restart
; no longer calls this at all - see vid_run's own restart redesign). This
; hot-page stub is the only part left resident: it hops to vid_open_
; video_body (VID_PAGE2, below) via the established push-target/ovl_map_
; page trampoline and back - same B-carries-CF convention as vid_classify
; above. The video number travels via C (set by vid_play, above) rather
; than memory, so vid_open_video_body needs no MMU6 translation just to
; learn which file to open. Corrupts AF, BC, DE, HL, IX.
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
; vid_run - entry/exit symmetry: everything vid_run touches is captured
; into a vidSv*-prefixed cell here and reversed on EVERY exit path via
; .restore (or .restore_noplay if the pool-bank claim itself failed).
; Sequence (brief Step 2): save state -> samples abort (SSTOP, waited)
; -> music tick frozen (audEnable=0 - the least invasive freeze: it also
; stops the frame ISR's OWN MMU6/7 remap around aud_tick, which is
; exactly what keeps MMU7=VID_PAGE stable for video_ctc_isr's banking
; invariant, doc 11) -> CTC retuned -> IM2_CTC_STUB patched -> the loop
; -> reverse-order restore on any exit (key, EOF in play-once, or a read
; error), banks released, ret through the dispatcher's normal path.
; ---------------------------------------------------------------------
vid_run:
    ; --- save state (vidSaved) ---
    ld e, NR_MMU6
    call nr_read
    ld (vidSvMmu6), a
    ld e, NR_MMU7
    call nr_read
    ld (vidSvMmu7), a
    ld e, NR_L2_BANK
    call nr_read
    ld (vidSvNr12), a
    ld e, NR_L2_CTRL
    call nr_read
    ld (vidSvNr70), a
    ld e, NR_DISPLAY_CTRL
    call nr_read
    ld (vidSvNr69), a
    ld e, NR_LAYERS
    call nr_read
    ld (vidSvNr15), a
    ld hl, (IM2_CTC_STUB+1)
    ld (vidSvCtcStub), hl
    ld a, (audEnable)
    ld (vidSvAudEnable), a
    ld a, (l2FrontBank)
    ld (vidSvL2Front), a
    ld a, (l2BackBank)
    ld (vidSvL2Back), a
    ; NR $43 (palette ctrl): the dev guide's per-register spec (chapter-
    ; next-palette.tex, "Register $43") never states it is readable - NR
    ; $40/$41/$44 each say "Reads or writes ..." explicitly, $43's own
    ; entry only describes what each bit DOES when written, no read
    ; mention. nr_read is therefore NOT used here; the game's own
    ; convention is captured instead (sp13-task-4-report.md addendum:
    ; every Layer 2 palette writer in this codebase, including this
    ; file's own vid_identity_palette below, uses PAL_L2_FIRST
    ; unconditionally - it is the only value NR $43 can hold on entry).
    ; vidPalCtrl (the double-buffer's own "which bank is on screen right
    ; now" tracker, kept in software for the same readability reason) is
    ; primed to the same value - frame 0 starts believing the first bank
    ; is displayed, matching what vid_identity_palette/l2_palette_load's
    ; own convention actually left on the hardware.
    ld a, PAL_L2_FIRST
    ld (vidSvNr43), a
    ld (vidPalCtrl), a

    ; --- samples abort (SSTOP request path, waited) ---
    ; audEnable = 0 means aud_tick never runs - the ISR never reaches the
    ; request chain, so a bit set here would never clear (aud_load_song's
    ; own documented hazard, overlay1.asm) - skip the wait in that case.
    ; Re-read from vidSvAudEnable (A has since been reloaded twice above
    ; for the l2Front/BackBank saves) rather than trust a stale register.
    ld a, (vidSvAudEnable)
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

    ; --- pool bank: the audio landing page (lower 8K) + palette landing
    ; page (upper 8K of the SAME bank) - not two full frame pairs; pixels
    ; are the existing Layer 2 back-surface banks (zero-copy, no pool
    ; allocation needed for them at all). ---
    call bank_alloc
    jr nc, .havebank
 IFDEF DEBUG
    ld b, 23
    ld c, 0
    call dbg_at
    ld hl, msgVidNoBank2
    call dbg_puts
 ENDIF
    jp .restore_noplay
.havebank:
    ld (vidAudPoolBank), a
    add a, a
    ld (vidAudPoolPage), a

    ; --- CTC retune: 23.3kHz for mono formats 4/5; ~10.37kHz (downsampled
    ; 3:1 from the source's 31.1kHz - nextdaad.inc's VID_STEREO_DOWNSAMPLE
    ; header) for stereo formats 2/3; ~7.78kHz (downsampled 2:1 from
    ; 15.55kHz - VID_STEREO01_DOWNSAMPLE header, SP13 T4) for stereo
    ; formats 0/1 - table-driven from the live video-timing mode (NR $11
    ; bits 2:0). For formats 4/5 and 2/3 the /16-vs-/256 crossover stays
    ; below the rate on every mode, so the control word is always CW16
    ; (vidCtcTcTab/vidCtcTcTab2's own headers). Formats 0/1 are the
    ; EXCEPTION: VGA5/VGA6's crossover (7812/8056 Hz) exceeds 7783 Hz, so
    ; those two modes need CW256/TC=16 instead - vidCtcTcTab0 stores a 0
    ; sentinel at those two slots (never a valid CW16 TC) and the `or a`
    ; check below detects it (see nextdaad.inc's vidCtcTcTab0 header).
    ; Mirrors aud_smp_start's exact CTC program sequence (unknown-state
    ; double reset, control word, time constant - audiobank.asm), EXCEPT
    ; the stub is patched between the control word and the time constant
    ; (not after) - the time-constant byte is what starts the timer
    ; (aud_smp_start's own comment: "loading the TC starts the timer"),
    ; so patching the stub first guarantees the FIRST possible tick
    ; already dispatches the right ISR, never a stale ctc_isr. ---
    ld e, NR_VIDEO_TIMING
    call nr_read
    and 7
    ld c, a
    ld b, 0
    ld a, (vidFmt)
    ld hl, vidCtcTcTab              ; mono table (formats 4/5)
    cp 4
    jr nc, .gottctab
    ld hl, vidCtcTcTab2              ; stereo table, fmt2/3 rate (~10.37kHz)
    cp 2
    jr nc, .gottctab
    ld hl, vidCtcTcTab0              ; stereo table, fmt0/1 rate (~7.78kHz)
.gottctab:
    add hl, bc
    ld a, (hl)
    ld d, AUD_CTC_CW16               ; default; overridden below only for
                                      ; fmt0/1's VGA5/VGA6 sentinel (0) hit
    or a
    jr nz, .havetc
    ld a, 16                         ; sentinel: TC=16 under CW256
    ld d, AUD_CTC_CW256
.havetc:
    ld (vidCtcTc), a
    ld a, d
    ; SP14a T3 wave 1: no longer stashed into vidCtcCw - the loop-mode
    ; restart no longer re-arms the CTC at all (it stays continuously
    ; armed through the restart, see vid_run's .eof: redesign), so the
    ; only historical reader of that stash is gone; vidCtcCw itself is
    ; removed below (would otherwise be a dead write-only cell).
    ld bc, AUD_CTC_PORT
    ld a, AUD_CTC_RESET
    out (c), a
    out (c), a                    ; double soft-reset (unknown -> clean)
    ld a, d
    out (c), a                    ; control word - timer not running yet

    ; --- IM2_CTC_STUB patched to the video audio ISR (mono or stereo -
    ; ONE stereo ISR body serves formats 0/1/2/3 alike, see below),
    ; BEFORE the time constant starts the timer further down. Single
    ; atomic LD (nn),HL (doc 08's "interrupt atomicity" - one instruction,
    ; no DI needed); MMU7 = VID_PAGE for the whole playback from here, the
    ; banking invariant both ISRs depend on (their own headers). ---
    ld a, (vidFmt)
    ld hl, video_ctc_isr
    cp 4
    jr nc, .gotisr
    ld hl, video_ctc_isr_stereo
.gotisr:
    ld (IM2_CTC_STUB+1), hl

    ; --- stereo formats only (0-3): patch video_ctc_isr_stereo's own two
    ; end-marker immediate operand bytes (self-modifying code - the SAME
    ; idiom as the IM2_CTC_STUB patch just above, doc 11) so the ONE ISR
    ; body serves both downsampled buffer lengths (fmt2/3's 622 pairs /
    ; fmt0/1's 467 pairs, SP13 T4) at ZERO ISR byte or T-state cost - only
    ; this one-time mainline setup pays. MUST happen before the time-
    ; constant write below starts the timer (same ordering rule as the
    ; stub patch). ---
    ld a, (vidFmt)
    cp 4
    jr nc, .noisrmark              ; mono: no marker to patch
    ld hl, vidAudBufLastStereo23
    cp 2
    jr nc, .gotmark
    ld hl, vidAudBufLastStereo01
.gotmark:
    ld a, l
    ld (video_ctc_isr_stereo.cmplo+1), a
    ld a, h
    ld (video_ctc_isr_stereo.cmphi+1), a
.noisrmark:

    ld a, (vidCtcTc)
    ld bc, AUD_CTC_PORT
    out (c), a                    ; time constant -> timer starts NOW,
                                   ; already dispatching the right ISR

    ; --- Layer 2 setup for playback: mode 0/row-major (256x192, formats
    ; 4/5) or mode 1/column-major (256x240 subset of 320x256, formats
    ; 2/3 - VID_L2_MODE1, nextdaad.inc, matching l2_mode_set's own %10
    ; literal for 320x256), full-height clip (no playvid-style scroll/
    ; crop inset - the brief's "no paper inset"), transparent colour left
    ; at TM_TRANSP_ATTR (the engine-wide convention every l2_mode_set
    ; call also uses - vid_apply_palette/vid_identity_palette dodge it
    ; exactly like l2_palette_load). NR $18/$1C (clip) and $16/$17
    ; (scroll) are NOT saved/restored - any picture the game shows after
    ; video re-programs them in full via its own l2_mode_set/l2_clip_set
    ; (gfx_blit calls it unconditionally on every DISPLAY), exactly like
    ; the palette below. ---
    ld a, (vidFmt)
    cp 4
    jr nc, .l2mode0
    ld a, VID_L2_MODE1
    nextreg NR_L2_CTRL, a
    nextreg NR_L2_TRANSP, TM_TRANSP_ATTR
    nextreg NR_CLIP_IDX, 1
    nextreg NR_L2_CLIP, 0
    ; X2: full-bleed 320-wide (fmt0/1, SP13 T4) vs fmt2/3's 256-of-320
    ; pillarboxed subset - VID_L2_CLIP_X2_M1_01/VID_L2_CLIP_X2_M1
    ; (nextdaad.inc). Y1/Y2/scroll are format-agnostic (unchanged below).
    ld a, (vidFmt)
    cp 2
    ld a, VID_L2_CLIP_X2_M1_01
    jr c, .gotx2
    ld a, VID_L2_CLIP_X2_M1
.gotx2:
    nextreg NR_L2_CLIP, a
    nextreg NR_L2_CLIP, 0
    nextreg NR_L2_CLIP, VID_COL_HEIGHT-1
    jr .l2clipdone
.l2mode0:
    xor a
    nextreg NR_L2_CTRL, a
    nextreg NR_L2_TRANSP, TM_TRANSP_ATTR
    nextreg NR_CLIP_IDX, 1
    nextreg NR_L2_CLIP, 0
    nextreg NR_L2_CLIP, 255
    nextreg NR_L2_CLIP, 0
    nextreg NR_L2_CLIP, 191
.l2clipdone:
    nextreg NR_L2_XOFS, 0
    nextreg NR_L2_YOFS, 0
    ld e, NR_DISPLAY_CTRL
    call nr_read
    or %10000000
    nextreg NR_DISPLAY_CTRL, a
    nextreg NR_LAYERS, 0

    ; no-palette formats (odd: 3, 5) - the pixel byte IS its own RRRGGGBB
    ; colour - program a fixed identity table once, no per-frame block.
    ld a, (vidFmt)
    and 1
    call nz, vid_identity_palette

    ; prime pacing so the first iteration's wait passes immediately (no
    ; prior frame is playing yet). IX is the resident play pointer for
    ; BOTH ISRs (mitigation - see the task report's Step 0: dedicating IX
    ; removes the mono ISR's HL push/pop AND its 16-bit memory round-trip;
    ; IX is proven free of mainline/other-ISR use throughout playback -
    ; im2_isr's fast path, taken whenever audEnable=0 as it is for the
    ; whole session, never touches ix/iy; the raw streaming internals are
    ; documented IX/IY-free by their own "golden rules 1 and 2" header).
    ld ix, vidAudBuf
    ld a, 1
    ld (vidAudDone), a

 IFDEF DEBUG
    ; SP14a T1: fresh timeline baseline for THIS playback session (not
    ; cumulative across calls) - zero-fills vidTlTicks..vidTlAcc's last
    ; byte (see that block's own header, below vidSvL2Back). Safe here
    ; despite the CTC already being armed above: only IX is off-limits
    ; during the armed window (T3's own proven constraint, this file's
    ; ISR headers); this touches AF/HL/DE/BC only, exactly like the
    ; L2-setup/vid_identity_palette calls immediately above already do.
    ld hl, vidTlTicks
    ld (hl), 0
    ld de, vidTlTicks+1
    ld bc, vidTlAcc + VID_TL_PHASES*4 - vidTlTicks - 1
    ldir
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
    ; Stereo formats 2/3 downsample 3:1 while copying (every 3rd sample
    ; PAIR kept, the other two dropped - VID_STEREO_DOWNSAMPLE header);
    ; stereo formats 0/1 (SP13 T4) downsample 2:1 (every other pair kept -
    ; VID_STEREO01_DOWNSAMPLE header) - both are page-space findings, not
    ; casual quality cuts.
    call data_save
    ld a, (vidAudPoolPage)
    call data_map_page
    ld a, (vidFmt)
    cp 4
    jr nc, .monocopy
    cp 2
    jr nc, .stereocopy23
    ld hl, DATA_WINDOW
    ld de, vidAudBuf
    ld bc, VID_F0_PLAY_SAMPLES      ; > 255: a 16-bit down-count, not djnz
.ds01loop:
    ld a, (hl)                     ; keep this pair's L
    ld (de), a
    inc hl
    inc de
    ld a, (hl)                     ; keep this pair's R
    ld (de), a
    inc hl
    inc de
    ; VID_STEREO01_DOWNSAMPLE=2: drop the NEXT ONE pair (2 bytes)
    inc hl
    inc hl
    dec bc
    ld a, b
    or c
    jr nz, .ds01loop
    jr .copydone
.stereocopy23:
    ld hl, DATA_WINDOW
    ld de, vidAudBuf
    ld bc, VID_F2_PLAY_SAMPLES      ; > 255: a 16-bit down-count, not djnz
.dsloop:
    ld a, (hl)                     ; keep this pair's L
    ld (de), a
    inc hl
    inc de
    ld a, (hl)                     ; keep this pair's R
    ld (de), a
    inc hl
    inc de
    ; VID_STEREO_DOWNSAMPLE=3: drop the NEXT TWO pairs (2*2=4 bytes -
    ; NOT 8: a "pair" is 2 bytes, L+R, not 4)
    inc hl
    inc hl
    inc hl
    inc hl
    dec bc
    ld a, b
    or c
    jr nz, .dsloop
    jr .copydone
.monocopy:
    ld hl, DATA_WINDOW
    ld de, vidAudBuf
    ld bc, VID_F4_AUDIO
    ldir
.copydone:
    call data_restore
    ld ix, vidAudBuf
    xor a
    ld (vidAudDone), a
    ; SP14a T2: palette EDIT (invisible write to the currently NON-
    ; displayed Layer 2 palette bank) - MOVED here, ahead of both flip
    ; writes below (pre-SP14a this ran AFTER the NR $12 write, into the
    ; SAME bank being scanned out - the ~0.4ms race that caused the
    ; sparkle, sp13-task-4-report.md's addendum). It must finish before
    ; EITHER flip write fires (NR $43 bit 2 or NR $12 - see the flip
    ; block below for why both, not just one) so the 256-entry write
    ; happens while the OLD frame is still fully, consistently on screen
    ; (old pixels under the old palette, nothing changing) instead of
    ; being visible mid-write. Still the palette streamed EARLIER this
    ; frame (resident at vidAudPoolPage+1, untouched since) - same "apply
    ; late, not at read time" reasoning as before (vid_stream_frame's own
    ; header), just applied to the hidden bank instead of the live one.
 IFDEF DEBUG
    ld a, VID_TL_PALETTE            ; closes phase 3 (flip/pace-wait: the
    call vid_tl_stamp               ; .pace spin + downsample copy-out -
 ENDIF                               ; SP14a T2 moved the flip swap/NR $12
                                     ; write out of this phase, see below)
    ld a, (vidFmt)
    and 1
    call z, vid_apply_palette
 IFDEF DEBUG
    ld a, VID_TL_OTHER              ; closes phase 2 (palette apply, or
    call vid_tl_stamp               ; ~0 for non-palette formats)
 ENDIF
    ; flip (l2_flip_swap's own variable-swap + NR $12 write, duplicated
    ; here since overlay2 is unreachable while MMU7 = VID_PAGE). NR $12
    ; takes the 16K bank number RAW (l2_mode_set/h_gfx.swap precedent,
    ; overlay2.asm) - no *2 here (that shift is ONLY for deriving an 8K
    ; MMU PAGE number, e.g. vidDrawPage above; NR $12 is not a page).
    ;
    ; SP14a T2: palette display-select (NR $43 bit 2) flips in lockstep
    ; with the pixel bank (NR $12) - both express the SAME "which buffer
    ; is live" decision, one for pixels, one for the palette that colours
    ; them; the edit above already made the target bank correct, so all
    ; that is left is to point the display at it. DEFAULT order shipped
    ; here: palette-select FIRST, pixel bank SECOND, back-to-back with no
    ; branch/call between them (design note's reasoning: new pixels
    ; briefly under a stale-but-still-CORRECT palette is the more jarring
    ; failure mode of the two, the same logic that made the original bug
    ; visible as sparkle rather than a subtler blend). ALTERNATIVE order
    ; is one move away: relocate the pixel-bank block (the 7 lines from
    ; "ld a, (l2FrontBank)" to "nextreg NR_L2_BANK, a") to BEFORE this
    ; comment, ahead of the palette-select block below - the owner's
    ; hardware leg adjudicates if either flip order shows an artifact.
    ; Palette-format-only (vidFmt and 1 == 0) - non-palette formats never
    ; touch NR $43 bit 2, so vid_identity_palette's one programmed-at-
    ; entry bank stays the displayed one for the whole session (design
    ; note item 6: an unconditional flip here would show garbage/stale
    ; colour on every odd frame for formats 1/3/5, which were never
    ; programmed into the second bank).
    ld a, (vidFmt)
    and 1
    jr nz, .nopalflip
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
    jp .frameloop
.eof:
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
    jp c, .restore                 ; defensive: empty map (should not
                                    ; happen - the same map just played)
    call vid_win_open              ; reopen at run 0 via the existing raw
                                    ; CMD18 path
    jp c, .restore                 ; defensive: card rejected the reopen
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
    ld bc, AUD_CTC_PORT
    ld a, AUD_CTC_RESET
    out (c), a
    out (c), a
    ld a, DAC_SILENCE
    out (DAC_PORT), a
    out (VID_DAC_LEFT), a          ; format-agnostic: always park all
    out (VID_DAC_RIGHT), a         ; three DAC ports used by either ISR
    ld hl, (vidSvCtcStub)
    ld (IM2_CTC_STUB+1), hl
    ld a, (vidSvAudEnable)
    ld (audEnable), a
    ld a, (vidSvL2Front)
    ld (l2FrontBank), a
    ld a, (vidSvL2Back)
    ld (l2BackBank), a
    ld a, (vidSvNr12)
    nextreg NR_L2_BANK, a
    ld a, (vidSvNr70)
    nextreg NR_L2_CTRL, a
    ld a, (vidSvNr69)
    nextreg NR_DISPLAY_CTRL, a
    ld a, (vidSvNr15)
    nextreg NR_LAYERS, a
    ; SP14a T2: NR $43 restored to the game's own convention (captured as
    ; PAL_L2_FIRST at entry, not read back - see the entry-capture
    ; comment). l2_palette_load unconditionally re-asserts PAL_L2_FIRST
    ; before every picture display anyway (design note), but restoring it
    ; here too keeps this routine's own symmetry doctrine exact, matching
    ; NR $12/$70/$69/$15 immediately above.
    ld a, (vidSvNr43)
    nextreg NR_PAL_CTRL, a
    call vid_stream_close
    ld a, (vidAudPoolBank)
    call bank_free
 IFDEF DEBUG
    ; SP14a T1: the frame-timeline report - fully torn-down playback only
    ; (CTC parked/stub restored above, DAC parked, L2/NR state restored) -
    ; no window/ISR constraint on printing here. Hops to VID_PAGE2 and
    ; back (vid_tl_report's own header) - MMU7 == VID_PAGE again by the
    ; time it returns, so the plain MMU6/7 restore below is unaffected.
    call vid_tl_report
 ENDIF
    ld a, (vidSvMmu6)
    nextreg NR_MMU6, a
    ld a, (vidSvMmu7)
    nextreg NR_MMU7, a
    ret
.restore_noplay:
    ; reached only if bank_alloc failed - CTC/stub/L2 were never touched,
    ; so only the freeze needs reversing.
    ld a, (vidSvAudEnable)
    ld (audEnable), a
    call vid_stream_close
    ret

; Stream one frame's worth of data for the CURRENT vidFmt into: the pool
; landing page (audio + its sector-alignment padding - 1024B total for
; mono formats 4/5, 4096B for stereo formats 2/3, both always at
; vidAudPoolPage - the MakeVid frame layout is audio + pad +
; [palette, even formats only] + pixels, playvid's own "pad ... for
; sector alignment"; the pad is read here and simply left unread past
; the real audio bytes by the copy-out in vid_run, never touched again -
; the palette's 512B lands at vidAudPoolPage+1, a DIFFERENT page so it
; cannot overwrite the audio, since vid_stream_read always lands at the
; start of its destination page), and the pixel surface: mono's
; vidDrawPage VID_PIX_PAGES consecutive 8K pages (zero-copy - vid_stream_
; read's dest IS the shadow Layer 2 surface, no staging copy), or
; stereo's vid_stream_pixels_col (below - a different, direct-INI
; mechanism, not vid_stream_read at all - see its own header for why).
;
; Palette-format frames (even: 2, 4) have their palette READ here but
; deliberately NOT APPLIED here - vid_apply_palette runs later, from
; vid_run's flip section, synchronised
; with the pixel-bank flip (see that call site's own comment for why:
; NR $43=PAL_L2_FIRST is "edit + active display", the SAME palette that
; is CURRENTLY ON SCREEN, so applying it immediately here would recolour
; the STILL-VISIBLE previous frame's pixels for this whole routine's
; ~36-46ms run time, every frame - playvid avoids this with a genuinely
; double-buffered palette (its frame_wait toggles NR $43 in lockstep with
; NR $12); this task's fix is cheaper - defer the apply to the flip
; instant instead, shrinking the mismatch window to the ~0.3-0.5ms the
; 512 nextreg writes themselves take. The landing page holding the raw
; palette bytes is not reused for anything else before that call, so
; deferring the READ's raw bytes costs nothing - only the byte data
; itself is deferred, not re-streamed.
;
; Out: CF clear = the whole frame streamed; CF set = end of file (the
; audio+pad read was short - the classifier-clean T2 fixtures are
; truncated to a whole number of frames, so EOF always lands here, never
; mid-frame) or a genuine read error - both treated identically by the
; caller. Corrupts everything.
; Three sizes: fmt0/1's VID_F0_AUDIO+VID_F01_AUDPAD=2048 (SP13 T4),
; fmt2/3's VID_F2_AUDIO+VID_F23_AUDPAD=4096, mono's VID_F4_AUDIO+
; VID_F45_AUDPAD=1024 - select the right read size up front, then share
; the palette-check and pixel-dispatch tails.
vid_stream_frame:
 IFDEF DEBUG
    ld a, VID_TL_STREAM              ; closes phase 4 (other: the tail of
    call vid_tl_stamp                ; the previous iteration - exit-flag
 ENDIF                                ; check, loop-back, this call's own
                                      ; overhead) and increments vidTlFrames
    ld a, (vidFmt)
    cp 4
    jr nc, .monoaud
    cp 2
    jr nc, .stereoaud23
    ld de, VID_F0_AUDIO + VID_F01_AUDPAD
    jr .readaud
.stereoaud23:
    ld de, VID_F2_AUDIO + VID_F23_AUDPAD
    jr .readaud
.monoaud:
    ld de, VID_F4_AUDIO + VID_F45_AUDPAD
.readaud:
    ld (vidAudReadLen), de
    ld a, (vidAudPoolPage)
    call vid_stream_read
    jr c, .eof
    ld hl, (vidAudReadLen)
    or a
    sbc hl, bc
    jr nz, .eof
    ; palette formats (even: 2, 4) only - streamed here, NOT applied
    ; (see this routine's header): vid_run's flip section applies it
    ; (vidAudPoolPage+1 still holds it, untouched).
    ld a, (vidFmt)
    and 1
    jr nz, .nopalette
    ld a, (vidAudPoolPage)
    inc a                          ; upper 8K of the same bank
    ld de, VID_PAL_BYTES
    call vid_stream_read
    jr c, .err
    ld hl, VID_PAL_BYTES
    or a
    sbc hl, bc
    jr nz, .err
.nopalette:
 IFDEF DEBUG
    ld a, VID_TL_BLIT               ; closes phase 0 (stream: the audio+
    call vid_tl_stamp               ; pad read, plus the palette read above
 ENDIF                               ; for even formats)
    ld a, (vidFmt)
    cp 4
    jr nc, .monopix
    ; stereo (0/1/2/3): column-major direct-INI blit (vid_stream_
    ; pixels_col, below) - no landing-page relocate, see that routine's
    ; own header for the double-copy cost this avoids.
    ld a, (vidDrawPage)
    call vid_stream_pixels_col
    jr c, .err
    or a
    ret
.monopix:
    ld a, (vidDrawPage)
    ld (vidPxPage), a
    ld a, VID_PIX_PAGES
    ld (vidPxCount), a
.pxloop:
    ld a, (vidPxPage)
    ld de, $2000
    call vid_stream_read
    jr c, .err
    ld hl, $2000
    or a
    sbc hl, bc
    jr nz, .err
    ld hl, vidPxPage
    inc (hl)
    ld hl, vidPxCount
    dec (hl)
    jr nz, .pxloop
    or a
    ret
.eof:
    scf
    ret
.err:
    scf
    ret

; ---------------------------------------------------------------------
; vid_stream_pixels_col - column-major pixel blit (formats 2/3, SP13
; Task 3; formats 0/1, SP13 Task 4 - same mode-1 addressing, full-bleed
; 320-wide instead of a 256-of-320 subset, only the PAGE COUNT differs).
; See nextdaad.inc's VID_COL_* header for the stride/gap/reference
; derivation (tools/ZXNextOS/.../playvid/video_256x240.asm/video_320x240.
; asm, column-major, real pixel bytes/column against a fixed 256-byte
; hardware stride). Streams VID_PIX_PAGES23 (8, fmt2/3) or VID_PIX_
; PAGES01 (10, fmt0/1 - both EXACT, no partial final page, see nextdaad.
; inc's VID_PIX_PAGES01 header) consecutive 8K L2 pages, 32 columns/page
; in either case (the stride/page-size relationship is a Layer 2 mode
; property, not format-specific), DIRECTLY via raw SD INI bursts into the
; MMU6 window - NOT through vid_stream_read's landing-page contract,
; because a landing-then-relocate design costs an extra ~21T/byte LDIR
; pass over the WHOLE pixel payload to re-insert the per-column gaps,
; which alone would exceed the 60ms fmt2/3 pace period - see the task
; report's budget table.
;
; SP14a T3 wave 2: STATIC CASE SEQUENCE (playvid parity - tools/ZXNextOS/
; src/c/DotCommands/playvid/video_256x240.asm and video_320x240.asm's
; case_0..case_14, confirmed structurally identical between the two
; formats, only the page COUNT differs, 8 vs 10). One 8K page is always
; 32 columns x 240 real bytes = 7680 bytes = exactly fifteen 512-byte SD
; blocks (GCD(512,240)=16 - this file's own long-standing header already
; derived this), so the column/block misalignment pattern is a FIXED,
; ASSEMBLE-TIME-KNOWN sequence, identical on every page of every format
; using this path - not a per-frame runtime quantity. Each of the 15
; per-page cases below is a straight-line sequence of calls to vid_
; xfer16n (a shared 16-byte-group INI burst, below) with an IMMEDIATE
; group count per segment - no vidColRemain16/vidBlkRemain16/vidPix
; RealRemain tracking, no runtime chunk16=min() computation, no running-
; remainder subtraction: the old dynamic bookkeeping is GONE, replaced
; by which case executes. This also deletes the whole register-liveness
; class the D-clobber lesson (SP13, vid_col_blockdone's documented DE
; corruption meeting a live chunk16 in D after three clean reviews) lived
; in - no chunk-size value is ever carried live across a vid_col_
; newblock/vid_col_blockdone call anymore; only the destination pointer
; (HL) is, via the same push/pop bracket the old code already used.
;
; RESYNC PRECONDITION (unchanged from the pre-wave-2 design): this
; routine's first case always opens a FRESH 512-byte SD block - correct
; ONLY because the audio+pad and palette reads that precede it (vid_
; stream_frame) are BOTH exact whole-block multiples (see nextdaad.inc's
; VID_F0/F2_AUDIO+AUDPAD headers) - vid_stream_read's own block-alignment
; cursor is already sitting exactly on a boundary when this routine takes
; over. Any FUTURE format wired through this same direct-INI path MUST
; keep its own pre-pixel reads block-aligned, or route pixels through the
; buffered vid_stream_read path instead (accepting its relocate cost).
; In: A = starting destination 8K page (VID_PIX_PAGES23/01 consecutive
;     pages, by vidFmt, are streamed, incrementing after each).
; Out: CF clear = all pages written; CF set = stream error/EOF (A =
;      code, matching vid_stream_read's contract).
; Corrupts everything.
vid_stream_pixels_col:
    ld (vidPxPage), a
    ld a, (vidFmt)
    cp 2
    ld a, VID_PIX_PAGES01
    jr c, .gotpages
    ld a, VID_PIX_PAGES23
.gotpages:
    ld (vidPxCount), a
.pageloop:
    call data_save
    ld a, (vidPxPage)
    call data_map_page
    ld hl, DATA_WINDOW
    ; --- case 0 (SD block 0: real bytes 0..512, column boundaries at
    ; 240 and 480 - two full 240-byte columns then 32 bytes into a third) ---
    call vid_col_block_start
    jp c, .colerr
    xor a
    ld b, 15
    call vid_xfer16n
    ld l, a
    inc h
    ld b, 15
    call vid_xfer16n
    ld l, a
    inc h
    ld b, 2
    call vid_xfer16n
    call vid_col_block_end
    ; --- case 1 (block 1: 512..1024; boundaries at 720, 960) ---
    call vid_col_block_start
    jp c, .colerr
    xor a
    ld b, 13
    call vid_xfer16n
    ld l, a
    inc h
    ld b, 15
    call vid_xfer16n
    ld l, a
    inc h
    ld b, 4
    call vid_xfer16n
    call vid_col_block_end
    ; --- case 2 (block 2: 1024..1536; boundaries at 1200, 1440) ---
    call vid_col_block_start
    jp c, .colerr
    xor a
    ld b, 11
    call vid_xfer16n
    ld l, a
    inc h
    ld b, 15
    call vid_xfer16n
    ld l, a
    inc h
    ld b, 6
    call vid_xfer16n
    call vid_col_block_end
    ; --- case 3 (block 3: 1536..2048; boundaries at 1680, 1920) ---
    call vid_col_block_start
    jp c, .colerr
    xor a
    ld b, 9
    call vid_xfer16n
    ld l, a
    inc h
    ld b, 15
    call vid_xfer16n
    ld l, a
    inc h
    ld b, 8
    call vid_xfer16n
    call vid_col_block_end
    ; --- case 4 (block 4: 2048..2560; boundaries at 2160, 2400) ---
    call vid_col_block_start
    jp c, .colerr
    xor a
    ld b, 7
    call vid_xfer16n
    ld l, a
    inc h
    ld b, 15
    call vid_xfer16n
    ld l, a
    inc h
    ld b, 10
    call vid_xfer16n
    call vid_col_block_end
    ; --- case 5 (block 5: 2560..3072; boundaries at 2640, 2880) ---
    call vid_col_block_start
    jp c, .colerr
    xor a
    ld b, 5
    call vid_xfer16n
    ld l, a
    inc h
    ld b, 15
    call vid_xfer16n
    ld l, a
    inc h
    ld b, 12
    call vid_xfer16n
    call vid_col_block_end
    ; --- case 6 (block 6: 3072..3584; boundaries at 3120, 3360) ---
    call vid_col_block_start
    jp c, .colerr
    xor a
    ld b, 3
    call vid_xfer16n
    ld l, a
    inc h
    ld b, 15
    call vid_xfer16n
    ld l, a
    inc h
    ld b, 14
    call vid_xfer16n
    call vid_col_block_end
    ; --- case 7 (block 7: 3584..4096; boundaries at 3600, 3840, 4080 -
    ; the ONE case per page whose block spans THREE column boundaries) ---
    call vid_col_block_start
    jp c, .colerr
    xor a
    ld b, 1
    call vid_xfer16n
    ld l, a
    inc h
    ld b, 15
    call vid_xfer16n
    ld l, a
    inc h
    ld b, 15
    call vid_xfer16n
    ld l, a
    inc h
    ld b, 1
    call vid_xfer16n
    call vid_col_block_end
    ; --- case 8 (block 8: 4096..4608; boundaries at 4320, 4560) ---
    call vid_col_block_start
    jp c, .colerr
    xor a
    ld b, 14
    call vid_xfer16n
    ld l, a
    inc h
    ld b, 15
    call vid_xfer16n
    ld l, a
    inc h
    ld b, 3
    call vid_xfer16n
    call vid_col_block_end
    ; --- case 9 (block 9: 4608..5120; boundaries at 4800, 5040) ---
    call vid_col_block_start
    jp c, .colerr
    xor a
    ld b, 12
    call vid_xfer16n
    ld l, a
    inc h
    ld b, 15
    call vid_xfer16n
    ld l, a
    inc h
    ld b, 5
    call vid_xfer16n
    call vid_col_block_end
    ; --- case 10 (block 10: 5120..5632; boundaries at 5280, 5520) ---
    call vid_col_block_start
    jp c, .colerr
    xor a
    ld b, 10
    call vid_xfer16n
    ld l, a
    inc h
    ld b, 15
    call vid_xfer16n
    ld l, a
    inc h
    ld b, 7
    call vid_xfer16n
    call vid_col_block_end
    ; --- case 11 (block 11: 5632..6144; boundaries at 5760, 6000) ---
    call vid_col_block_start
    jp c, .colerr
    xor a
    ld b, 8
    call vid_xfer16n
    ld l, a
    inc h
    ld b, 15
    call vid_xfer16n
    ld l, a
    inc h
    ld b, 9
    call vid_xfer16n
    call vid_col_block_end
    ; --- case 12 (block 12: 6144..6656; boundaries at 6240, 6480) ---
    call vid_col_block_start
    jp c, .colerr
    xor a
    ld b, 6
    call vid_xfer16n
    ld l, a
    inc h
    ld b, 15
    call vid_xfer16n
    ld l, a
    inc h
    ld b, 11
    call vid_xfer16n
    call vid_col_block_end
    ; --- case 13 (block 13: 6656..7168; boundaries at 6720, 6960) ---
    call vid_col_block_start
    jp c, .colerr
    xor a
    ld b, 4
    call vid_xfer16n
    ld l, a
    inc h
    ld b, 15
    call vid_xfer16n
    ld l, a
    inc h
    ld b, 13
    call vid_xfer16n
    call vid_col_block_end
    ; --- case 14 (block 14: 7168..7680, the page's LAST block; boundaries
    ; at 7200, 7440 - ends exactly at the 32nd column, real byte 7680) ---
    call vid_col_block_start
    jp c, .colerr
    xor a
    ld b, 2
    call vid_xfer16n
    ld l, a
    inc h
    ld b, 15
    call vid_xfer16n
    ld l, a
    inc h
    ld b, 15
    call vid_xfer16n
    call vid_col_block_end
.pagedone:
    call data_restore
    ld hl, vidPxPage
    inc (hl)
    ld hl, vidPxCount
    dec (hl)
    jp nz, .pageloop
    or a
    ret
.colerr:
    push af
    call data_restore
    pop af
    scf
    ret

; Ensure a fresh 512-byte SD block is ready to stream (window open, run
; available, data token seen) - mirrors vid_stream_read_raw's own
; .needstream/.haveblocks/vid_win_open/vid_next_run sequence, but leaves
; the 512 bytes UNCONSUMED (vid_stream_pixels_col's own INI bursts read
; them directly, split across the case sequence's own segment
; boundaries). Out: CF clear (a fresh block is ready - SP14a T3 wave 2:
; no longer stamps vidBlkRemain16=32, since the case sequence tracks
; block position at ASSEMBLE time now, not via that runtime cell - see
; vid_stream_pixels_col's own header); CF set = run/window/token error
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
.wt:
    in a, (PORT_SPI_DAT)
    inc a
    jr z, .wt
    dec a
    cp $FE
    jr z, .ok
    ld a, VID_ERR_TOKEN
    scf
    ret
.ok:
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

; SP14a T3 wave 2: shared static-case transfer primitive - vid_stream_
; pixels_col's own case_0..case_14 sequence (above) calls this with an
; IMMEDIATE B (group count, 1-15) per segment instead of the old runtime
; chunk16=min(colRemain16,blkRemain16) computation. In: B = group count,
; C = PORT_SPI_DAT, HL = destination. Out: HL advanced by B*16 bytes.
; Corrupts F, B; PRESERVES A - the case bodies' column-gap trick (xor a
; at case top, ld l,a after each column) DEPENDS on A surviving every
; call (ini does not touch A). Never add an A-clobbering instruction
; here without reworking every case's gap handling.
vid_xfer16n:
    REPT 16
        ini
    ENDR
    djnz vid_xfer16n
    ret

; Shared per-case-block prologue (SP14a T3 wave 2 - byte-budget lever):
; opens the next SD block (vid_col_newblock's own token-wait) and readies
; C=PORT_SPI_DAT, folding the push/pop-HL protection bracket and the
; post-newblock BC reload into ONE call site per case instead of five
; inline instructions each. In: HL = live destination pointer (preserved
; across the call). Out: CF clear, C=PORT_SPI_DAT, HL unchanged, ready
; for the caller's own vid_xfer16n bursts; CF set = error (A = code, HL
; still unchanged - vid_stream_pixels_col's own .colerr tail does not
; need it). Corrupts AF, BC, DE.
vid_col_block_start:
    push hl
    call vid_col_newblock
    pop hl
    ret c                          ; error: CF/A propagate, HL restored
    ld c, PORT_SPI_DAT             ; vid_col_newblock may have used BC
    ret                            ; CF clear (vid_col_newblock's own)

; Shared per-case-block epilogue: the same push/pop-HL protection bracket
; around vid_col_blockdone (CRC-skip + run-block-count + remain-subtract)
; that vid_col_block_start's own header describes, folded into one call
; site per case. In/Out: HL preserved across the call (the ONLY register
; kept live across a block boundary now - the wave 2 header's own "no
; chunk-size value ever carried live across this call" design property).
; Corrupts AF, BC, DE.
vid_col_block_end:
    push hl
    call vid_col_blockdone
    pop hl
    ret

; Apply the 512-byte 9-bit palette just landed at vidAudPoolPage+1
; (palette formats only: 0, 2, 4) to Layer 2. Called from vid_run's flip
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

; Program a fixed identity RRRGGGBB palette (value[i] = i) once at entry
; for no-palette formats (odd: 3, 5 - their pixel bytes ARE their own
; colour). Dodges TM_TRANSP_ATTR the same way (entry 254 -> colour $FF
; instead of its "natural" identity value $FE) and, like vid_apply_
; palette, does NOT also force-stamp entry 254 to genuinely BE
; TM_TRANSP_ATTR afterward - see vid_apply_palette's header for why: no
; MakeVid content is guaranteed to avoid pixel value 254, so reserving it
; as transparent would punch real content through to the tilemap.
; Byte1 (the expanded 9th blue bit) is computed, not hardcoded 0 - SP13
; T3 ride-along fix: this now matches the Next's own 8-bit->9-bit
; hardware expansion rule ("least significant bit of blue is set to OR
; between B2 and B1", docs/zx-next-dev-guide-2022-07-15/chapter-next-
; palette.tex:176 - byte1 = 1 iff the index's two blue bits, i&3, are
; nonzero), the SAME rule tests/gen_vid_synth.py's synthetic palette
; blocks already use - T2's report disclosed this as a known asymmetry
; (a "very slight blue-channel shading difference" between formats 4/5);
; reconciled here rather than left for a future task.
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
    cp low vidAudBufLast
    jr nz, .adv
    ld a, ixh
    cp high vidAudBufLast
    jr nz, .adv
    ld a, 1
    ld (vidAudDone), a
    jr .ret
.adv:
    inc ix
.ret:
    pop af
    ei
    reti

; Stereo video audio ISR (SP13 T3; T4 generalizes it to serve formats 0/1
; too). Fires at the downsampled rate (VID_STEREO_DOWNSAMPLE/VID_RATE_
; STEREO_PLAY for fmt2/3, VID_STEREO01_DOWNSAMPLE/VID_RATE0_PLAY for
; fmt0/1 - nextdaad.inc) via CTC channel 0, same installation/banking-
; invariant/alternate-set/no-MMU discipline as video_ctc_isr above (see
; its header - identical reasoning applies here, not repeated). DAC
; ports: VID_DAC_LEFT ($F3, DAC channel B) / VID_DAC_RIGHT ($F9, DAC
; channel C) - ports.txt lines 266-274 ("A,B are directed to the left
; audio channel and C,D... right"), the exact pair the MakeVid reference
; ISR uses (interrupts-common.asm isr_ctc_stereo, lines 250-307) -
; confirming the interleave order too: L byte first (even offset), R
; second (odd offset) per sample pair, matching "(hl)" then "inc l /
; (hl)" there. IX addresses the CURRENT pair's L byte; R is (ix+1).
; End condition: IX has reached the LAST pair's L byte - ONE shared body
; serves BOTH downsampled buffer lengths (fmt2/3's vidAudBufLastStereo23
; / fmt0/1's vidAudBufLastStereo01) via a self-modifying-code patch to
; the two `cp n` immediate operands below (video_ctc_isr_stereo.cmplo+1/
; .cmphi+1), poked once per session by vid_run BEFORE the CTC time
; constant starts the timer (SP13 T4 - see that call site's own comment)
; - zero ISR byte or T-state cost versus a hardcoded single-format
; constant, and zero risk to the T3-proven fmt2/3 path (the ISR body
; itself is textually unchanged except for the two new poke-target
; labels). Advances by 2 per tick, not 1.
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
    cp low vidAudBufLastStereo23
    jr nz, .adv
    ld a, ixh
.cmphi:
    cp high vidAudBufLastStereo23
    jr nz, .adv
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

; Per-video-mode (NR $11 bits 2:0) CTC time constant for 23300 Hz (VID_
; RATE4_X10 * 100, shared by formats 4/5), mirroring aud_ctc_params'
; algorithm (overlay1.asm) collapsed to this one fixed rate - duplicated
; rather than cross-called since overlay1 is a different MMU7 page,
; unreachable during playback. Derived from the SAME per-mode clock
; table (aud_clk16_tab) at assemble time: TC = floor(clk16[mode] / rate),
; floored, control word always AUD_CTC_CW16 - every mode's /16-vs-/256
; crossover (clk16>>8, roughly 6835-8056) sits WELL BELOW 23300 (aud_
; ctc_params picks /16 whenever the rate EXCEEDS the crossover), so the
; /256 branch never applies at this rate. VGA0 75, VGA1 76, VGA2 79,
; VGA3 80, VGA4 83, VGA5 85, VGA6 88, HDMI 72.
vidCtcTcTab:
    db 75, 76, 79, 80, 83, 85, 88, 72

; Same derivation, for VID_RATE_STEREO_PLAY (~10366 Hz, the downsampled
; stereo rate - nextdaad.inc). Crossover stays well below 10366 on every
; mode too, so CW16 throughout, same as the table above. VGA0 168,
; VGA1 172, VGA2 177, VGA3 180, VGA4 186, VGA5 192, VGA6 198, HDMI 162.
vidCtcTcTab2:
    db 168, 172, 177, 180, 186, 192, 198, 162

; Same derivation, for VID_RATE0_PLAY (~7783 Hz, formats 0/1's own
; downsampled rate, SP13 T4). UNLIKE the two tables above, the crossover
; does NOT stay below this (lower) rate on every mode: VGA5 (crossover
; 7812 Hz) and VGA6 (crossover 8056 Hz) both exceed 7783, so those two
; slots store 0 - a sentinel vid_run's own CTC-arm code detects (never a
; valid CW16 TC) and substitutes CW256/TC=16 for at runtime (see that
; call site). VGA0 224, VGA1 229, VGA2 236, VGA3 240, VGA4 248, VGA5
; 0(sentinel), VGA6 0(sentinel), HDMI 216.
vidCtcTcTab0:
    db 224, 229, 236, 240, 248, 0, 0, 216

vidNum:          db 0
vidLoopMode:      db 0             ; 0 = play once, 1 = loop
vidFmt:           db 0             ; 0-5 (vid_classify's verdict)
vidExitReq:       db 0
; vidName/vidNamePart moved to VID_PAGE2 (SP14a T3 wave 1) - only the now-
; cold vid_open_video_body/vid_stream_open_body touch them (vid_open_
; video_body builds them; vid_stream_open_body's esx_fopen reads them via
; IX - see the VID_PAGE2 section's own declarations).
vidAudPoolBank:   db 0
vidAudPoolPage:   db 0
vidDrawPage:      db 0
vidPxPage:        db 0
vidPxCount:       db 0
vidCtcTc:         db 0
vidAudReadLen:    dw 0             ; this frame's audio+pad read size
                                    ; (mono VID_F4_AUDIO+VID_F45_AUDPAD or
                                    ; fmt0/1/2/3 VID_F0/2_AUDIO+VID_F01/23_
                                    ; AUDPAD)
; vidColRemain16/vidBlkRemain16/vidPixRealRemain removed (SP14a T3 wave
; 2) - the static case sequence (vid_stream_pixels_col) tracks column/
; block/remaining-byte position at ASSEMBLE time now (which case is
; executing), not via these runtime cells.
; Shared mono/stereo play buffer, sized for the LARGEST need among all
; three groups: VID_F2_PLAY_BYTES=1244 (fmt2/3 - 622 pairs, 3:1-
; downsampled - VID_STEREO_DOWNSAMPLE header) is still the largest even
; after SP13 T4 added fmt0/1 (VID_F0_PLAY_BYTES=934 - 467 pairs, 2:1-
; downsampled - VID_STEREO01_DOWNSAMPLE header - fits inside the existing
; allocation with no growth). Mono (933 bytes, VID_F4_AUDIO) uses only
; the front of it, unchanged from T2 - formats never play concurrently,
; so one shared buffer costs less page space than separate ones.
vidAudBuf:        ds VID_F2_PLAY_BYTES
vidAudBufLast         equ vidAudBuf + VID_F4_AUDIO - 1
vidAudBufLastStereo23 equ vidAudBuf + VID_F2_PLAY_BYTES - 2
vidAudBufLastStereo01 equ vidAudBuf + VID_F0_PLAY_BYTES - 2
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
msgVidBadFmt:  db "VID FMT?", 0
msgVidMissing: db "VID FILE?", 0
msgVidNoBank2: db "VID NOBANK2", 0

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
; Fix wave 2: total span of the block above (vidTlTicks..end of
; vidTlAcc) that vid_tl_report_body must copy across the page hop before
; reading it (see that routine's own header) - computed, not hand-
; counted (2+2+1+2+20 = 27), so it can never drift if a field above is
; resized.
VID_TL_BLOCK_LEN equ vidTlAcc + VID_TL_PHASES*4 - vidTlTicks

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
; (vid_bench_trampoline, overlay0.asm; xpart_load_entry, overlay0.asm).
; Corrupts everything.
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

; ---------------------------------------------------------------------
; VIDBENCH - DEBUG-only dev harness (SP13 Task 1).
; ---------------------------------------------------------------------
; Reached only via extVec vector 6's DEBUG-conditional trampoline
; (overlay0.asm) - see this task's report for the exact dispatch route
; and why vector 6 was chosen. Entered with VID_PAGE already mapped at
; MMU7 (the trampoline's own hop, the established push-target/ovl_map_page
; idiom); B/C on entry (h_extern's EXTERN args) are unused. Ends with
; MMU7 still VID_PAGE - harmless, eng_exec (engine.asm) re-maps MMU7
; before dispatching the NEXT condact regardless (the same invariant
; h_xpart's cross-page failure hop already relies on).
;
; Opens sd\001.VID (root only) and streams it end-to-end through
; vid_stream_read in maximal ($2000) MMU6-window chunks, timing the pass
; via frameCounter (interrupts.asm, incremented once per 50Hz interrupt).
; ONE invocation runs TWO passes - pass 1 F_READ, pass 2 raw streaming
; (re-opening between passes) - so the owner's re-leg produces both
; mechanism verdicts at once. Prints three rows: F_READ OK/ERR, raw
; streaming OK/ERR (its distinct error code if the raw open failed - the
; owner always still gets the F_READ verdict), and total bytes / elapsed
; frames / vid_classify verdict (from the streaming pass; from the
; F_READ pass if streaming never ran) - KB/s is NOT computed on-device
; (SP13 T4 page-space recovery; a one-line hand calculation from the
; printed bytes/frames, KB/s = bytes*50/frames/1024). One shot per call -
; re-invoking VIDBENCH re-opens and re-measures from scratch (the spec's
; RE-RUNNABLE requirement: a new NextZXOS/Next-core release is expected
; to change the numbers). Output uses the DEBUG dbg_at/dbg_puts/dbg_hex8/
; dbg_hex16 console helpers (debug.asm) - hex only, matching every
; existing use of those helpers in this codebase (no decimal printer
; exists).
 IFDEF DEBUG

VIDBENCH_ROW_STRM  equ 28       ; two report rows near the bottom of the
VIDBENCH_ROW_INFO  equ 29       ; 32-row tilemap (debug.asm's reserved
                                 ; status lines - l2_testcard's header
                                 ; comment, overlay2.asm). SP14a T1: the
                                 ; F_READ comparison pass (row 27) is
                                 ; removed here to recover VID_PAGE
                                 ; headroom for the frame-timeline
                                 ; instrument (this task's report, Step 1)
                                 ; - it was comparison-only infrastructure
                                 ; from SP13 Task 1 (the player itself
                                 ; always uses raw mode, T1's pinned
                                 ; contract); the same lever SP13 T3 round
                                 ; 3 already used once for its own space
                                 ; crunch (that trim was later reverted
                                 ; when T3's own probe was stripped - this
                                 ; is a fresh, disclosed application of it,
                                 ; not a revert).

vid_bench:
    call bank_alloc              ; one transient scratch bank, the MMU6
    jr nc, .havebank              ; read target for the raw streaming pass
    ld b, VIDBENCH_ROW_STRM
    ld c, 0
    call dbg_at
    ld hl, msgVidNoBank
    jp dbg_puts
.havebank:
    ld (vidBenchBank), a
    add a, a                     ; 16K bank -> its lower 8K page
    ld (vidBenchPage), a
    ; raw streaming (direct SD SPI) - the player's only mechanism (T1's
    ; pinned contract). ERRORS on CSpect - its directory mode fakes the
    ; esxDOS API over host files with no SPI card behind it, so CMD18/the
    ; token wait get no data. Expected: the STRM row shows an error there;
    ; real hardware is the measurement.
    ld a, 1
    ld (vidStrmMode), a
    call vid_bench_pass
    jr c, .strmfail
    xor a
    ld (vidStrmErr), a           ; 0 = ok
    jr .freebank
.strmfail:
    ld (vidStrmErr), a           ; A = error (nonzero)
.freebank:
    ld a, (vidBenchBank)
    call bank_free
    jp vid_bench_report

; Runs one full timed streaming pass over vidBenchName into vidBenchPage
; using the currently selected vidStrmMode, then computes the pass's
; report values into vidBench*. Out: CF set = open/read failed (A = error
; code); CF clear = success. Corrupts everything.
vid_bench_pass:
    ld ix, vidBenchName
    call vid_stream_open
    ret c                         ; A = error, CF set (open failed)
    ld hl, 0
    ld (vidBenchLo), hl
    ld (vidBenchHi), hl
    ld hl, (frameCounter)
    ld (vidBenchStart), hl
.readloop:
    ld a, (vidBenchPage)
    ld de, $2000
    call vid_stream_read
    jr c, .readfail
    ld hl, (vidBenchLo)
    add hl, bc
    ld (vidBenchLo), hl
    jr nc, .nocarry
    ld hl, (vidBenchHi)
    inc hl
    ld (vidBenchHi), hl
.nocarry:
    ld hl, $2000
    or a
    sbc hl, bc
    jr z, .readloop               ; BC == $2000: full window, keep streaming
    ; BC < $2000: short/EOF read (CF clear on this - see the vid_stream_read
    ; header) - the file is exhausted
    ld hl, (frameCounter)
    ld (vidBenchEnd), hl
    call vid_stream_close
    call vid_bench_compute
    or a                         ; CF clear
    ret
.readfail:
    push af
    call vid_stream_close
    pop af
    scf
    ret

; Derives the report values for the pass just streamed. vidSizeLo/
; vidSizeHi are still the size vid_stream_open captured for THIS file, so
; the classification is for the exact bytes just streamed. Corrupts
; everything.
vid_bench_compute:
    ; elapsed = end - start (16-bit, wraps correctly via 2's complement -
    ; frameCounter is a plain dw, 50Hz, ~21.8 minutes before it wraps)
    ld hl, (vidBenchEnd)
    ld de, (vidBenchStart)
    or a
    sbc hl, de
    ld (vidBenchElapsed), hl
    ; totalKB = (vidBenchHi:vidBenchLo) >> 10. Assumes the total fits 16
    ; bits after the shift, true for any file under 64MB - comfortably
    ; covers the whole MakeVid format matrix (the largest demo fixture is
    ; ~38MB; see the task report).
    ld hl, (vidBenchLo)
    ld de, (vidBenchHi)
    ld b, 10
.kshr:
    srl d
    rr e
    rr h
    rr l
    djnz .kshr
    ld (vidBenchKB), hl
    ; KB/s is NOT computed on-device (SP13 T4 space recovery - see the
    ; task report; T3 round 3 precedent) - vid_bench_report's INFO row
    ; prints raw bytes/frames unchanged, a one-line hand calculation
    ; (KB/s = bytes*50/frames/1024) for the owner's re-leg.
    ld hl, (vidSizeLo)
    ld de, (vidSizeHi)
    call vid_classify
    ld (vidBenchFmt), a
    ld a, 0
    jr nc, .classok
    ld a, 1
.classok:
    ld (vidBenchFmtBad), a
    ret

; Prints the two report rows from the values stashed by the streaming pass.
vid_bench_report:
    ; row 28: raw streaming KB/s (or ERR = distinct fragmentation/API code)
    ld b, VIDBENCH_ROW_STRM
    ld c, 0
    call dbg_at
    ld a, (vidStrmErr)
    or a
    jr z, .strmok
    ld hl, msgVidStrmErr
    call dbg_puts
    ld a, (vidStrmErr)
    call dbg_hex8
    jr .inforow
.strmok:
    ld hl, msgVidStrm
    call dbg_puts
.inforow:
    ; row 29: bytes / frames / format (streaming pass, or F_READ fallback)
    ld b, VIDBENCH_ROW_INFO
    ld c, 0
    call dbg_at
    ld hl, msgVidBytes
    call dbg_puts
    ld hl, (vidBenchHi)
    call dbg_hex16
    ld hl, (vidBenchLo)
    call dbg_hex16
    ld hl, msgVidFrames
    call dbg_puts
    ld hl, (vidBenchElapsed)
    call dbg_hex16
    ld hl, msgVidFmt
    call dbg_puts
    ld a, (vidBenchFmtBad)
    or a
    jr nz, .printbad
    ld a, (vidBenchFmt)
    jp dbg_hex8
.printbad:
    ld hl, msgVidUnclass
    jp dbg_puts

; vidBenchName moved to VID_PAGE2 (SP14a T3 wave 1) - vid_bench_pass sets
; IX to it BEFORE calling vid_stream_open (the hot stub), and IX survives
; the hop unchanged, so it must resolve to real bytes once MMU7=VID_PAGE2
; (where vid_stream_open_body actually reads it via esx_fopen) - see the
; VID_PAGE2 section's own comment at its declaration.
; SP14a T2: five VIDBENCH message strings shortened (VID_PAGE space
; recovery for the palette double-buffer feature - see the task report's
; page-budget section) - same disclosed lever SP13 T4 Step 6 already used
; on this exact DEBUG-only dev harness (VIDBENCH's KB/s calc removal);
; this is a fresh application, not a revert. No information is lost -
; row 28/29 still print bank/error/bytes/frames/format, just with
; terser labels; no test or fixture reads these strings (grepped clean).
msgVidNoBank:   db "NOBANK", 0
msgVidStrm:     db "STRM OK", 0
msgVidStrmErr:  db "STRM ERR=", 0
msgVidBytes:    db "BYTES=", 0
msgVidFrames:   db " FR=", 0
msgVidFmt:      db " FMT=", 0
msgVidUnclass:  db "??", 0

vidBenchBank:    db 0
vidBenchPage:    db 0
vidBenchLo:      dw 0
vidBenchHi:      dw 0
vidBenchStart:   dw 0
vidBenchEnd:     dw 0
vidBenchElapsed: dw 0
vidBenchKB:      dw 0
vidBenchFmt:     db 0
vidBenchFmtBad:  db 0
vidStrmErr:      db 0            ; raw streaming pass error code, 0 = ok

 ENDIF ; DEBUG

    DISPLAY "video ends at ", $, " headroom ", /D, OVL_LIMIT - $
    ASSERT $ <= OVL_LIMIT

; ---------------------------------------------------------------------
; VID_PAGE2 - second video page. Originally (SP14a T1) a DEBUG-only
; overflow page hosting only the frame-timeline report's print body
; (SP13 T3's own crash-bisection-probe precedent: print-only, reached
; strictly AFTER playback is fully torn down, never while the CTC/ISR is
; armed). SP14a T3 wave 1 makes the page UNCONDITIONAL (both build
; variants) and adds a second kind of content: COLD video code evicted
; off VID_PAGE under the SAME one-rule invariant (MMU7 = VID_PAGE
; whenever the video CTC ISR can fire) - vid_classify, and the whole
; open/filemap-orchestration cluster (vid_open_video, vid_stream_open),
; both provably reachable only BEFORE any CTC arm (see each routine's own
; header, below, for the call-site evidence). The DEBUG-only report body
; (vid_tl_report_body etc) stays exactly as T1 left it, still guarded by
; its own IFDEF DEBUG within this now-unconditional page.
; ---------------------------------------------------------------------
    MMU 7, VID_PAGE2, OVL_ORG

; ------------------------------------------------------------------
; Cold video code (SP14a T3 wave 1) - both build variants.
; ------------------------------------------------------------------

; vid_classify body (hot stub: VID_PAGE, above). Identical logic to the
; pre-wave-1 vid_classify, just relocated and renamed; ends by hopping
; back to vid_classify_ret (VID_PAGE) with the result in B ($FF = bad,
; else the format 0-5) instead of a plain `ret` with CF/A. First restores
; HL/DE (the real In: HL/DE size argument) from the stub's own pushes -
; see vid_classify's header, VID_PAGE, for why the stub couldn't just
; leave them live across its own `ld hl,<hop target>`.
vid_classify_body:
    pop de                       ; caller's DE (size high)
    pop hl                       ; caller's HL (size low)
    ld a, l
    or a
    jr nz, .bad
    ld a, h
    and 1
    jr nz, .bad                 ; size not a multiple of 512: reject
    ld b, 9                     ; >>9 (=/512) -> 24-bit sector count in
.shr:                           ; E:H:L (D discarded - always 0 for any
    srl d                       ; file under 8GB, comfortably beyond the
    rr e                        ; format matrix)
    rr h
    rr l
    djnz .shr
    ld a, e
    ld (vidSectE), a
    ld a, h
    ld (vidSectH), a
    ld a, l
    ld (vidSectL), a
    ld ix, vidFormatSect
    ld c, 0
.tryfmt:
    ld a, (ix+0)
    ld d, a
    call vid_mod24
    or a
    jr z, .found
    inc ix
    inc c
    ld a, c
    cp VID_FORMATS
    jr nz, .tryfmt
.bad:
    ld b, $FF
    jr .ret
.found:
    ld b, c
.ret:
    ld hl, vid_classify_ret
    push hl
    ld a, VID_PAGE
    jp ovl_map_page

; 24-bit dividend (vidSectE:vidSectH:vidSectL, E=MSB) mod 8-bit divisor.
; In: D = divisor (1-155 - every format's sector count is under 256, so
;     an 8-bit remainder accumulator suffices). Out: A = remainder.
; Standard shift-compare-subtract restoring division, 24 steps. Reads
; the dividend fresh from memory each call so the six vid_classify
; iterations share one unmodified dividend. Corrupts AF, BC, HL, E.
vid_mod24:
    ld a, (vidSectE)
    ld e, a
    ld a, (vidSectH)
    ld h, a
    ld a, (vidSectL)
    ld l, a
    xor a
    ld b, 24
.loop:
    sla l
    rl h
    rl e
    rla                          ; A holds the running remainder r < d <= 155;
                                  ; the shifted 9-bit value v = 2r+bit <= 309
    jr c, .fsub                  ; bit 8 fell out of A into CF: true v = A+256,
                                  ; always >= any divisor here, so subtract
                                  ; unconditionally - sub d's 8-bit wraparound
                                  ; supplies the +256 (v-d = A-d mod 256, and
                                  ; 101 <= v-d <= 154 fits). The old `cp d`
                                  ; discarded this carry, corrupting every
                                  ; divisor 128..155 (r reaches 128+).
    cp d
    jr c, .skip
.fsub:
    sub d
.skip:
    djnz .loop
    ret

vidSectE: db 0
vidSectH: db 0
vidSectL: db 0

; Frame-sector-count table, priority order 0-5 (VID_F0_SECT..VID_F5_SECT,
; nextdaad.inc) - vid_classify's own divisor walk.
vidFormatSect:
    db VID_F0_SECT, VID_F1_SECT, VID_F2_SECT
    db VID_F3_SECT, VID_F4_SECT, VID_F5_SECT

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

; Hot-caller wrapper (vid_bench_pass only - see vid_stream_open's own hot
; stub, VID_PAGE, IFDEF DEBUG there too - mirrored here). Corrupts AF,
; BC, DE, HL, IX.
 IFDEF DEBUG
vid_stream_open_hopbody:
    ; vid_stream_open_body assumes MMU6 already maps VID_PAGE (the
    ; translated-address touches to vidHandle/vidStrmMode/vidSizeLo/Hi -
    ; see its own header). vid_open_video_body's internal calls inherit
    ; that mapping from their own already-open bracket; vid_bench_pass's
    ; call via THIS hop has no such bracket active, so it is opened here
    ; instead - not nested with vid_open_video_body's own (the two paths
    ; are mutually exclusive: vid_bench_pass never runs mid-vid_play).
    call data_save
    ld a, VID_PAGE
    call data_map_page
    call vid_stream_open_body
    ld b, 0
    jr nc, vid_stream_open_hopresult
    ld b, 1
    ld c, a                      ; preserve the error code (data_restore,
                                  ; below, clobbers A)
vid_stream_open_hopresult:
    call data_restore
    ld hl, vid_stream_open_ret
    push hl
    ld a, VID_PAGE
    jp ovl_map_page
 ENDIF ; DEBUG

vidName:     ds 8             ; "NNN.VID",0
vidNamePart: ds 14            ; "PARTn\NNN.VID",0
vidFstatBuf: ds 11             ; F_FSTAT buffer: +0 '*' +1 $81 +2 attr
                                ; +3 time +5 date +7(4) size (esxDOS API)

; ------------------------------------------------------------------
; DEBUG-only content below (unchanged in shape from SP14a T1/T2 - wave 1
; only made the PAGE unconditional, not this section's own guard).
; ------------------------------------------------------------------
 IFDEF DEBUG

VID_TL_ROW0 equ 24              ; rows 24-28 (this task's own report rows,
                                 ; distinct from VIDBENCH's 28-29 above -
                                 ; the two harnesses are never on screen at
                                 ; the same time, so the row overlap is
                                 ; cosmetic only, not a functional clash)

; Print the 32-bit little-endian value at (HL) as 8 hex digits (two
; dbg_hex16 calls, high word then low word) - matches VIDBENCH's own
; "(vidBenchHi) then (vidBenchLo)" idiom above. Report-only (called
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
    ; compile-time one). Fix: copy the whole VID_TL_BLOCK_LEN(27)-byte
    ; block across via the MMU6 window (data_save/data_map_page(VID_PAGE)/
    ; LDIR/data_restore - MMU6 is free here, post-teardown; the same
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
    cp VID_TL_OTHER
    jr nz, .nextrow
    ld hl, msgTlTot
    call dbg_puts
    ld hl, (vidTlTicksL)
    call dbg_hex16
    ld hl, msgTlFrm
    call dbg_puts
    ld hl, (vidTlFramesL)
    call dbg_hex16
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
vidTlRptRow: db 0
vidTlRptIdx: db 0

; Page-local mirror of the VID_PAGE-resident vidTlTicks..vidTlAcc block
; (fix wave 2, above) - same field order/sizes, filled by the pre-print
; LDIR, read by the report in place of the (unreachable-from-here)
; VID_PAGE originals. vidTlLastTickL/vidTlLastPhaseL are copied but never
; read here - kept only for exact layout parity with the source block,
; so the single LDIR's length (VID_TL_BLOCK_LEN) needs no special-casing.
vidTlTicksL:     dw 0
vidTlLastTickL:  dw 0
vidTlLastPhaseL: db 0
vidTlFramesL:    dw 0
vidTlAccL:       ds VID_TL_PHASES*4

 ENDIF ; DEBUG

; vidBenchName moved here from VID_PAGE (SP14a T3 wave 1): vid_bench_pass
; (VID_PAGE, DEBUG-only) sets IX to it BEFORE calling vid_stream_open
; (the hot stub); IX survives the hop unchanged (only A/HL are touched by
; the trampoline), so it must resolve to real bytes once MMU7=VID_PAGE2
; (where vid_stream_open_body actually reads it via esx_fopen) - it
; cannot stay on VID_PAGE, which would be unmapped at that point.
 IFDEF DEBUG
vidBenchName: db "001.VID", 0
 ENDIF

    DISPLAY "video2 ends at ", $, " headroom ", /D, OVL_LIMIT - $
    ASSERT $ <= OVL_LIMIT
