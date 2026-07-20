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
; Corrupts AF, BC, DE, HL, IX.
vid_classify:
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
    scf
    ret
.found:
    ld a, c
    or a                         ; CF clear
    ret

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
; Corrupts AF, BC, DE, HL, IX.
vid_stream_open:
    ld a, $FF
    ld (vidHandle), a
    call esx_getsetdrv
    jr c, .fail
    ld b, ESX_MODE_READ
    call esx_fopen               ; IX = caller's filename, untouched
    jr c, .fail                  ; since esx_getsetdrv/the ld b above
    ld (vidHandle), a
    ; DISK_FILEMAP MUST run first - before F_FSTAT or any other file access
    ; (a prior access perturbs the sector-cache state the map walks, giving
    ; a wrong card address the card rejects; playvid parity - it FILEMAPs
    ; straight after F_OPEN and never F_FSTATs). F_READ mode never maps.
    ld a, (vidStrmMode)
    or a
    jr z, .fstat
    call vid_raw_setup           ; raw: capture + validate the filemap NOW
    jr c, .openfail
.fstat:
    ld a, (vidHandle)            ; F_FSTAT (both modes) - legal AFTER FILEMAP,
    ld ix, vidFstatBuf            ; before opening the card for streaming
    rst $08
    db ESX_F_FSTAT
    jr c, .openfail
    ld hl, (vidFstatBuf+7)
    ld (vidSizeLo), hl
    ld hl, (vidFstatBuf+9)
    ld (vidSizeHi), hl
    ld a, (vidStrmMode)
    or a
    ret z                        ; F_READ mode: CF clear (from or a), done
    ld hl, (vidSizeLo)           ; raw: prime remain from the captured size
    ld (vidStrmRemainLo), hl      ; (the map + run/tail cursor were set by
    ld hl, (vidSizeHi)            ; vid_raw_setup above)
    ld (vidStrmRemainHi), hl
    or a                         ; CF clear
    ret
.openfail:
    push af                      ; close the handle, propagating A (esxDOS
    ld a, (vidHandle)             ; code or VID_ERR_* from the filemap step)
    call esx_fclose
    ld a, $FF
    ld (vidHandle), a
    pop af
    scf
    ret
.fail:
    scf
    ret

; Raw-mode filemap capture: runs IMMEDIATELY after F_OPEN, BEFORE F_FSTAT
; or any other video-file access (F_FSTAT alone is metadata-only, but the
; map still walks the GLOBAL sector cache, which prior game/file I/O
; leaves pointing mid-file). So we apply stream.asm's touched-file reset
; unconditionally first (seek 0, read 1 byte, seek 0) to repoint the
; cache at the file's first sector, THEN DISK_FILEMAP - the production-
; normal case is a hot cache (T2 opens videos after arbitrary game I/O).
; Fails (CF set, A = code) if the map came back empty
; (VID_ERR_NOMAP) or the file needs more runs than the 32-entry buffer
; holds (VID_ERR_FRAG - DISK_FILEMAP reported zero unused entries, i.e.
; it filled the buffer and may have had more; the kit's defrag advice
; applies). Records the card granularity (cardflags bit 1: 0 = byte
; addresses, +512/block; 1 = block addresses, +1/block) as the per-block
; step and resets the run/tail cursor; remain is primed by the caller
; after F_FSTAT yields the size. Corrupts AF, BC, DE, HL, IX.
vid_raw_setup:
    ; stream.asm touched-file reset (global sector cache): repoint it at
    ; the first sector before mapping, else DISK_FILEMAP walks from wherever
    ; the last file access left it and returns a wrong card address the card
    ; rejects. Required before EVERY map - the cache is process-wide.
    call vid_raw_seek0           ; F_SEEK -> offset 0
    ret c
    ld a, (vidHandle)            ; F_READ one byte (the cache primer)
    ld ix, vidRawResetByte
    ld bc, 1
    call esx_fread
    ret c
    call vid_raw_seek0           ; F_SEEK back -> offset 0
    ret c
    ld a, (vidHandle)
    ld ix, vidFilemapBuf
    ld de, VID_FILEMAP_ENT       ; buffer capacity in 6-byte entries
    rst $08
    db ESX_DISK_FILEMAP
    ret c                        ; A = esxDOS error, CF set
    ; DE = unused entries, HL = address past last written entry, A = flags
    ld (vidCardFlags), a
    ld a, e                      ; unused == 0 -> buffer was full, treat as
    or d                          ; over-fragmented (cannot prove complete)
    jr nz, .roomok
    ld a, VID_ERR_FRAG
    scf
    ret
.roomok:
    ld de, vidFilemapBuf
    ld (vidStrmEntryPtr), de      ; cursor starts at the first entry
    or a
    sbc hl, de                    ; HL = bytes of entries written
    jr nz, .haveentries
    ld a, VID_ERR_NOMAP           ; empty map: nothing to stream
    scf
    ret
.haveentries:
    add hl, de                    ; re-form the end address
    ld (vidStrmEntryEnd), hl
    ; Card granularity (cardflags bit 1: byte vs 512-byte-block addresses)
    ; needs no handling: DISK_FILEMAP already returns each run's start address
    ; in the card's native CMD18 units, and the persistent CMD18 window
    ; streams successive blocks internally - we never compute a per-block
    ; address, so no step is derived. (bit 0 = card id is still used, for the
    ; CS0/CS1 select in vid_sd_cmd.)
    xor a
    ld (vidStrmWinOpen), a         ; no SD window open on a fresh raw open
    ld hl, 0                      ; no run loaded, no buffered tail yet
    ld (vidStrmRunBlocks), hl
    ld (vidStrmBlkPos), hl
    ld (vidStrmBlkLen), hl
    or a                          ; CF clear (remain is primed by the caller
    ret                           ; once F_FSTAT has read the size)

; F_SEEK the video handle to absolute offset 0. NextZXOS F_SEEK: A=handle,
; BCDE=offset, IXL=mode (0 = from start; IX is the register that matters,
; L set too belt-and-braces - see overlay0.asm's xmes seek). Out: CF set =
; esxDOS error (A = code). Corrupts AF, BC, DE, HL, IX.
vid_raw_seek0:
    ld bc, 0
    ld de, 0
    ld l, 0
    ld ix, 0
    ld a, (vidHandle)
    jp esx_fseek

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

vidStrmMode: db 0              ; 0 = F_READ, 1 = raw card streaming
vidHandle:   db $FF
vidSizeLo:   dw 0
vidSizeHi:   dw 0
vidReadPage: db 0
vidFstatBuf: ds 11             ; F_FSTAT buffer: +0 '*' +1 $81 +2 attr
                                ; +3 time +5 date +7(4) size (esxDOS API)

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
; many off remain (buffered bytes were counted into remain when read, so
; they subtract here as delivered). Corrupts AF, BC, DE, HL.
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
; An NMI/Multiface trap mid-SD-transaction could issue file I/O (which
; re-selects the card) and corrupt the read or hang the machine. Corrupts
; AF, E.
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
vidRawResetByte:   db 0          ; F_READ target for the pre-map cache primer
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
; vid_play - the player core (SP13 Task 2 mono, Task 3 stereo). Formats
; 2-5 (256x240 stereo, 256x192 mono); any other classification (0/1,
; 320x240 - a later task) is a fail-silent no-op. Entry: B = video number,
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
    ld a, b
    call vid_open_video
    jr c, .missing
    ld hl, (vidSizeLo)
    ld de, (vidSizeHi)
    call vid_classify
    jr c, .badfmt
    cp 2
    jr c, .badfmt          ; formats 0/1 (320x240) - out of scope, later task
    cp 6
    jr nc, .badfmt          ; defensive (vid_classify never returns > 5)
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

; Build vidName ("NNN.VID",0) from A = video number (3-digit zero-padded
; decimal, the project's repeated-subtraction decade idiom - aud_load_song
; overlay1.asm, gfx_open_chain overlay2.asm). curPart > 1 also builds
; vidNamePart ("PARTn\NNN.VID",0) and tries it FIRST, root as fallback -
; the established PARTn probe idiom (SP11 T5's four other sites); curPart
; == 1 skips straight to root, zero new opens. Sets vidStrmMode = 1 (raw)
; before every open attempt - the player always uses raw mode (T1's pinned
; contract; F_READ mode is bench-only). Out: CF clear = opened (vidHandle/
; vidSizeLo/Hi set by vid_stream_open); CF set = neither name opened.
; Corrupts AF, BC, DE, HL, IX.
vid_open_video:
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
    ld (vidStrmMode), a           ; raw streaming, always (T1 pinned contract)
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
    call vid_stream_open
    ret nc                        ; PARTn open succeeded
.openroot:
    ld ix, vidName
    jp vid_stream_open

vidExtVid: db ".VID", 0

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

    ; --- CTC retune: 23.3kHz for mono formats 4/5, ~10.37kHz (downsampled
    ; 3:1 from the source's 31.1kHz - see nextdaad.inc's VID_STEREO_
    ; DOWNSAMPLE header for why: a full-rate resident stereo buffer does
    ; not fit the video page) for stereo formats 2/3 - table-driven from
    ; the live video-timing mode (NR $11 bits 2:0). Every mode's /16-vs-
    ; /256 crossover is BELOW both rates on every mode, so the control
    ; word is always CW16 (see vidCtcTcTab/vidCtcTcTab2's headers).
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
    ld hl, vidCtcTcTab             ; mono table (formats 4/5)
    cp 4
    jr nc, .gottctab
    ld hl, vidCtcTcTab2            ; stereo/downsampled table (formats 2/3)
.gottctab:
    add hl, bc
    ld a, (hl)
    ld (vidCtcTc), a
    ld bc, AUD_CTC_PORT
    ld a, AUD_CTC_RESET
    out (c), a
    out (c), a                    ; double soft-reset (unknown -> clean)
    ld a, AUD_CTC_CW16
    out (c), a                    ; control word - timer not running yet

    ; --- IM2_CTC_STUB patched to the video audio ISR (mono or stereo),
    ; BEFORE the time constant starts the timer below. Single atomic
    ; LD (nn),HL (doc 08's "interrupt atomicity" - one instruction, no DI
    ; needed); MMU7 = VID_PAGE for the whole playback from here, the
    ; banking invariant both ISRs depend on (their own headers). ---
    ld a, (vidFmt)
    ld hl, video_ctc_isr
    cp 4
    jr nc, .gotisr
    ld hl, video_ctc_isr_stereo
.gotisr:
    ld (IM2_CTC_STUB+1), hl

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
    nextreg NR_L2_CLIP, VID_L2_CLIP_X2_M1
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

.frameloop:
    ld a, (l2BackBank)             ; draw target = the currently-hidden
    add a, a                        ; back surface (idle during playback)
    ld (vidDrawPage), a
    call vid_stream_frame
    jr c, .eof
    call vid_key_any
    ld a, 0
    jr z, .nokey
    ld a, 1
.nokey:
    ld (vidExitReq), a
.pace:
    ld a, (vidAudDone)             ; wait for the CURRENTLY VISIBLE
    or a                            ; frame's audio to finish (pacing:
    jr z, .pace                    ; samples-per-frame count exhausted)
    ; launch the frame just streamed: copy the landing-page audio into
    ; the ISR-resident buffer (safe with no DI - see video_ctc_isr's own
    ; header for why a torn read here is at most one imperceptible tick).
    ; Stereo (formats 2/3) downsamples 3:1 while copying (every 3rd
    ; sample PAIR kept, the other two dropped) - nextdaad.inc's VID_
    ; STEREO_DOWNSAMPLE header explains why (page-space finding, not a
    ; casual quality cut).
    call data_save
    ld a, (vidAudPoolPage)
    call data_map_page
    ld a, (vidFmt)
    cp 4
    jr nc, .monocopy
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
    ; flip (l2_flip_swap's own variable-swap + NR $12 write, duplicated
    ; here since overlay2 is unreachable while MMU7 = VID_PAGE). NR $12
    ; takes the 16K bank number RAW (l2_mode_set/h_gfx.swap precedent,
    ; overlay2.asm) - no *2 here (that shift is ONLY for deriving an 8K
    ; MMU PAGE number, e.g. vidDrawPage above; NR $12 is not a page).
    ld a, (l2FrontBank)
    ld b, a
    ld a, (l2BackBank)
    ld (l2FrontBank), a
    ld a, b
    ld (l2BackBank), a
    ld a, (l2FrontBank)
    nextreg NR_L2_BANK, a
    ; palette formats (even: 2, 4) only: apply the palette streamed
    ; earlier this frame (still resident at vidAudPoolPage+1, untouched
    ; since) NOW - synchronised with the pixel flip just above, not when
    ; it was read (vid_stream_frame's header explains why: applying it
    ; early would recolour the frame that was VISIBLE at read time, not
    ; the one just flipped in).
    ld a, (vidFmt)
    and 1
    call z, vid_apply_palette
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
    ; --- CTC-park bracket (SP13 T3 review fix, B1 - critical) ---
    ; vid_open_video (via vid_stream_open/vid_raw_setup) loads IX with
    ; esxDOS buffer/argument pointers (vidNamePart/vidName for esx_fopen,
    ; vidFstatBuf for F_FSTAT, vidRawResetByte then vidFilemapBuf for the
    ; raw filemap setup) across several BLOCKING esxDOS calls - and BOTH
    ; video ISRs (video_ctc_isr/video_ctc_isr_stereo, below) treat IX as
    ; their own private play pointer, `inc ix`-ing it on EVERY tick
    ; whenever it is not EXACTLY vidAudBufLast/vidAudBufLastStereo (the
    ; compare-and-hold-last branch, both ISRs' bodies). This is NOT made
    ; safe by waiting for the previous frame's audio to drain first: once
    ; mainline repoints IX to an esxDOS buffer, that value is (correctly)
    ; never equal to vidAudBufLast either, so the VERY NEXT tick's
    ; compare fails and the ISR falls straight into `inc ix` on
    ; mainline's esxDOS pointer - drained or not. The only safe fix is to
    ; stop the ISR from firing at all for the duration: park the CTC
    ; (the same double soft-reset teardown idiom `.restore` uses, below)
    ; before vid_stream_close/vid_open_video, re-arm (the same CW16+TC
    ; program this routine's own entry sequence uses - vidCtcTc and the
    ; IM2_CTC_STUB patch are both still correct, format never changes
    ; mid-session, so neither is recomputed) after a successful reopen.
    ; On resume the ISR replays the still-resident LAST FRAME's buffer
    ; from the top into the gap (see the `ld ix, vidAudBuf` re-seat
    ; below) - brief and bounded (ends at the marker exactly like any
    ; other frame, setting vidAudDone normally), then the new frame's
    ; audio takes over at the next `.pace` relaunch. Not silent, not an
    ; unbounded hold.
    ld bc, AUD_CTC_PORT
    ld a, AUD_CTC_RESET
    out (c), a
    out (c), a                     ; CTC parked - the ISR cannot fire
                                    ; again until re-armed below
    call vid_stream_close
    ld a, (vidNum)
    call vid_open_video
    jr c, .restore                 ; reopen failed: .restore's own CTC
                                    ; reset (double soft-reset again) is
                                    ; a harmless repeat from here - the
                                    ; CTC is already parked
    ; --- B2 fix (review of the B1 fix, critical): vid_open_video's
    ; success path returns with IX = vidFstatBuf (vid_stream_open's own
    ; F_FSTAT call, "ld ix,vidFstatBuf" immediately before its `rst $08`
    ; - the LAST IX assignment before that routine returns). Re-arming
    ; the CTC with THAT still live in IX would resume the ISR reading/
    ; inc-ix-walking from an esxDOS buffer address instead of audio -
    ; mono: garbage DAC output until IX random-walks onto the marker by
    ; chance (unbounded in practice); stereo: IX steps by 2 with a fixed
    ; parity, so if vidFstatBuf's address parity never matches vidAud
    ; BufLastStereo's, the marker is NEVER hit, vidAudDone never sets,
    ; and .pace (no key-check) hangs forever. Re-seat IX to the resident
    ; last-frame buffer BEFORE re-arming - the ISR then resumes its
    ; normal, already-proven compare-and-hold behaviour against the
    ; SAME fixed end marker every other tick in this file uses, bounded
    ; and correct for both mono and stereo (this is the shared loop-mode
    ; path - the re-seat lands before EITHER isr can next fire, since
    ; the CTC is still parked at this point).
    ld ix, vidAudBuf
    ld bc, AUD_CTC_PORT
    ld a, AUD_CTC_CW16
    out (c), a
    ld a, (vidCtcTc)
    ld bc, AUD_CTC_PORT
    out (c), a                     ; re-armed - ISR resumes next tick
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
    call vid_stream_close
    ld a, (vidAudPoolBank)
    call bank_free
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
; Stereo (2/3) audio+pad is bigger (VID_F2_AUDIO+VID_F23_AUDPAD=4096) than
; mono's (VID_F4_AUDIO+VID_F45_AUDPAD=1024) - select the right read size
; up front, then share the palette-check and pixel-dispatch tails.
vid_stream_frame:
    ld a, (vidFmt)
    cp 4
    jr nc, .monoaud
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
    ld a, (vidFmt)
    cp 4
    jr nc, .monopix
    ; stereo (2/3): column-major direct-INI blit (vid_stream_pixels_col,
    ; below) - no landing-page relocate, see that routine's own header
    ; for the double-copy cost this avoids.
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
; Task 3). See nextdaad.inc's VID_COL_* header for the stride/gap/
; reference derivation (tools/ZXNextOS/.../playvid/video_256x240.asm,
; column-major, 240 real bytes/column against a fixed 256-byte hardware
; stride). Streams VID_PIX_PAGES23 (8) consecutive 8K L2 pages, 32
; columns/page, DIRECTLY via raw SD INI bursts into the MMU6 window - NOT
; through vid_stream_read's landing-page contract, because a landing-
; then-relocate design costs an extra ~21T/byte LDIR pass over the WHOLE
; 61440-byte pixel payload (~46ms) to re-insert the per-column gaps,
; which alone would exceed the 60ms fmt2/3 pace period - see the task
; report's budget table. vidColRemain16/vidBlkRemain16/vidPixRealRemain
; are all in units that stay exact multiples of 16 bytes throughout
; (GCD(VID_COL_STRIDE against one 512-byte SD block, VID_COL_HEIGHT) =
; 16), so the transfer loop is one uniform 16-byte-unrolled inner block
; for every chunk - column-complete, block-complete, or both at once -
; with no remainder handling anywhere.
; RESYNC PRECONDITION: this routine starts with vidBlkRemain16=0,
; forcing a fresh 512-byte SD block boundary (token-wait) on its first
; chunk - correct ONLY because the audio+pad and palette reads that
; precede it (vid_stream_frame) are BOTH exact whole-block multiples
; (VID_F2_AUDIO+VID_F23_AUDPAD=4096=8 blocks, VID_PAL_BYTES=512=1 block,
; for formats 2/3), so vid_stream_read's own block-alignment cursor is
; already sitting exactly on a boundary when this routine takes over -
; no partial block is left buffered in vidStrmBlkBuf for it to miss. Any
; FUTURE format wired through this same direct-INI path MUST keep its
; own pre-pixel reads block-aligned, or route pixels through the
; buffered vid_stream_read path instead (accepting its relocate cost).
; In: A = starting destination 8K page (VID_PIX_PAGES23 consecutive
;     pages are streamed, incrementing after each).
; Out: CF clear = all 8 pages written; CF set = stream error/EOF (A =
;      code, matching vid_stream_read's contract).
; Corrupts everything.
vid_stream_pixels_col:
    ld (vidPxPage), a
    ld a, VID_PIX_PAGES23
    ld (vidPxCount), a
.pageloop:
    call data_save
    ld a, (vidPxPage)
    call data_map_page
    ld hl, DATA_WINDOW
    ld a, VID_COL_HEIGHT/16
    ld (vidColRemain16), a
    xor a
    ld (vidBlkRemain16), a         ; force a fresh block on the first chunk
    ld de, VID_COL_HEIGHT*VID_COL_PER_PAGE   ; 7680 real bytes/page
    ld (vidPixRealRemain), de
    ld c, PORT_SPI_DAT
.next:
    ld de, (vidPixRealRemain)
    ld a, d
    or e
    jp z, .pagedone
    ld a, (vidBlkRemain16)
    or a
    jr nz, .havesrc
    push hl                        ; HL = live destination pointer -
    call vid_col_newblock          ; vid_col_newblock corrupts it (its
    pop hl                         ; own "Corrupts AF, BC, DE, HL" contract)
    jr nc, .gotblock
    push af
    call data_restore
    pop af
    scf
    ret
.gotblock:
    ld c, PORT_SPI_DAT             ; vid_col_newblock may have used BC
.havesrc:
    ; chunk16 = min(colRemain16, blkRemain16), both in units of 16 bytes
    ld a, (vidColRemain16)
    ld b, a
    ld a, (vidBlkRemain16)
    cp b
    jr c, .usechunk
    ld a, b
.usechunk:
    ld d, a                        ; d = chunk16 (kept across the transfer)
    ld e, a                        ; e = loop counter (consumed)
.xfer:
    REPT 16
       ini
    ENDR
    dec e
    jr nz, .xfer
    ld a, (vidColRemain16)
    sub d
    jr nz, .colok
    ; column complete: jump the destination to the next 256-byte stride
    ; boundary, skipping the 16-byte hardware gap (playvid's own "ld
    ; l,a / inc h" trick, video_256x240.asm - a IS 0 here, from the sub)
    ld l, a
    inc h
    ld a, VID_COL_HEIGHT/16
.colok:
    ld (vidColRemain16), a
    ld a, (vidBlkRemain16)
    sub d
    ld (vidBlkRemain16), a
    push hl                        ; protect the destination pointer across
                                    ; vid_col_blockdone below (it corrupts
                                    ; HL - "Corrupts AF, BC, DE, HL")
    jr nz, .blkok
    call vid_col_blockdone         ; CRC skip + run/remain bookkeeping
.blkok:
    ; vidPixRealRemain -= chunk16*16 (chunk16 <= 15, so *16 <= 240, fits
    ; a byte-doubled shift into BC without overflow)
    ld b, 0
    ld c, d
    sla c
    rl b
    sla c
    rl b
    sla c
    rl b
    sla c
    rl b
    ld hl, (vidPixRealRemain)
    or a
    sbc hl, bc
    ld (vidPixRealRemain), hl
    pop hl                         ; restore the destination pointer
    ld c, PORT_SPI_DAT
    jp .next
.pagedone:
    call data_restore
    ld hl, vidPxPage
    inc (hl)
    ld hl, vidPxCount
    dec (hl)
    jp nz, .pageloop
    or a
    ret

; Ensure a fresh 512-byte SD block is ready to stream (window open, run
; available, data token seen) - mirrors vid_stream_read_raw's own
; .needstream/.haveblocks/vid_win_open/vid_next_run sequence, but leaves
; the 512 bytes UNCONSUMED (vid_stream_pixels_col's own INI bursts read
; them directly, split across column/block chunk boundaries). Out: CF
; clear, vidBlkRemain16 = 32; CF set = run/window/token error (A = code).
; Corrupts AF, BC, DE, HL.
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
    ld a, 32                       ; 512/16
    ld (vidBlkRemain16), a
    or a
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

; Apply the 512-byte 9-bit palette just landed at vidAudPoolPage+1
; (palette formats only: 2, 4) to Layer 2. Called from vid_run's flip
; section, NOT from vid_stream_frame where it was read (see that
; routine's header).
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
    nextreg NR_PAL_CTRL, PAL_L2_FIRST
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

; Stereo video audio ISR (SP13 T3). Fires at the downsampled rate (see
; nextdaad.inc's VID_STEREO_DOWNSAMPLE/VID_RATE_STEREO_PLAY headers) via
; CTC channel 0, same installation/banking-invariant/alternate-set/no-MMU
; discipline as video_ctc_isr above (see its header - identical
; reasoning applies here, not repeated). DAC ports: VID_DAC_LEFT ($F3,
; DAC channel B) / VID_DAC_RIGHT ($F9, DAC channel C) - ports.txt lines
; 266-274 ("A,B are directed to the left audio channel and C,D...
; right"), the exact pair the MakeVid reference ISR uses (interrupts-
; common.asm isr_ctc_stereo, lines 250-307) - confirming the interleave
; order too: L byte first (even offset), R second (odd offset) per
; sample pair, matching "(hl)" then "inc l / (hl)" there. IX addresses
; the CURRENT pair's L byte; R is (ix+1). End condition: IX has reached
; the LAST pair's L byte (vidAudBufLastStereo = vidAudBuf +
; VID_F2_PLAY_BYTES - 2), advancing by 2 per tick, not 1.
video_ctc_isr_stereo:
    push af
    ld a, (ix+0)
    out (VID_DAC_LEFT), a
    ld a, (ix+1)
    out (VID_DAC_RIGHT), a
    ld a, ixl
    cp low vidAudBufLastStereo
    jr nz, .adv
    ld a, ixh
    cp high vidAudBufLastStereo
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

vidNum:          db 0
vidLoopMode:      db 0             ; 0 = play once, 1 = loop
vidFmt:           db 0             ; 2-5 (vid_classify's verdict)
vidExitReq:       db 0
vidName:          ds 8             ; "NNN.VID",0
vidNamePart:      ds 14            ; "PARTn\NNN.VID",0
vidAudPoolBank:   db 0
vidAudPoolPage:   db 0
vidDrawPage:      db 0
vidPxPage:        db 0
vidPxCount:       db 0
vidCtcTc:         db 0
vidAudReadLen:    dw 0             ; this frame's audio+pad read size
                                    ; (mono VID_F4_AUDIO+VID_F45_AUDPAD or
                                    ; stereo VID_F2_AUDIO+VID_F23_AUDPAD)
vidColRemain16:   db 0             ; vid_stream_pixels_col: column-major
vidBlkRemain16:   db 0             ; blit state, units of 16 bytes (see
vidPixRealRemain: dw 0             ; that routine's own header)
; Shared mono/stereo play buffer, sized for the LARGER stereo need
; (VID_F2_PLAY_BYTES=1244 - 622 pairs, the 3:1-downsampled frame - see
; nextdaad.inc's VID_STEREO_DOWNSAMPLE header). Mono (933 bytes,
; VID_F4_AUDIO) uses only the front of it, unchanged from T2 - formats
; never play concurrently, so one shared buffer costs less page space
; than two separate ones (1244 vs 1244+933).
vidAudBuf:        ds VID_F2_PLAY_BYTES
vidAudBufLast       equ vidAudBuf + VID_F4_AUDIO - 1
vidAudBufLastStereo equ vidAudBuf + VID_F2_PLAY_BYTES - 2
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

 IFDEF DEBUG
msgVidBadFmt:  db "VID FMT?", 0
msgVidMissing: db "VID FILE?", 0
msgVidNoBank2: db "VID NOBANK2", 0
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
; mechanism verdicts at once. Prints three rows: F_READ KB/s, raw
; streaming KB/s (or its distinct error code if the raw open failed -
; the owner always still gets the F_READ number), and total bytes /
; elapsed frames / vid_classify verdict (from the streaming pass; from
; the F_READ pass if streaming never ran). One shot per call - re-
; invoking VIDBENCH re-opens and re-measures from scratch (the spec's
; RE-RUNNABLE requirement: a new NextZXOS/Next-core release is expected
; to change the numbers). Output uses the DEBUG dbg_at/dbg_puts/dbg_hex8/
; dbg_hex16 console helpers (debug.asm) - hex only, matching every
; existing use of those helpers in this codebase (no decimal printer
; exists).
 IFDEF DEBUG

VIDBENCH_ROW_FREAD equ 27       ; three report rows near the bottom of the
VIDBENCH_ROW_STRM  equ 28       ; 32-row tilemap, all clear of rows 30-31
VIDBENCH_ROW_INFO  equ 29       ; (debug.asm's reserved status lines - see
                                 ; l2_testcard's header comment, overlay2.asm)

vid_bench:
    call bank_alloc              ; one transient scratch bank, reused by
    jr nc, .havebank              ; both passes as the MMU6 read target
    ld b, VIDBENCH_ROW_FREAD
    ld c, 0
    call dbg_at
    ld hl, msgVidNoBank
    jp dbg_puts
.havebank:
    ld (vidBenchBank), a
    add a, a                     ; 16K bank -> its lower 8K page
    ld (vidBenchPage), a
    ; --- pass 1: F_READ ---
    xor a
    ld (vidStrmMode), a
    call vid_bench_pass
    jr c, .freadfail
    ld hl, (vidBenchKbps)        ; stash F_READ KB/s before pass 2 overwrites
    ld (vidFreadKbps), hl
    xor a
    ld (vidFreadErr), a          ; 0 = ok
    jr .pass2
.freadfail:
    ld (vidFreadErr), a          ; A = error (nonzero)
    ld hl, 0
    ld (vidFreadKbps), hl
.pass2:
    ; --- pass 2: raw streaming (direct SD SPI). This ERRORS on CSpect -
    ; its directory mode fakes the esxDOS API over host files with no SPI
    ; card behind it, so CMD18/the token wait get no data. Expected: the
    ; STRM row shows an error there; real hardware is the measurement. ---
    ld a, 1
    ld (vidStrmMode), a
    call vid_bench_pass
    jr c, .strmfail
    xor a
    ld (vidStrmErr), a           ; 0 = ok; vidBenchKbps now holds raw KB/s
    jr .freebank
.strmfail:
    ld (vidStrmErr), a           ; A = error (nonzero); vidBench* still hold
    ld hl, 0                      ; the F_READ pass's bytes/frames/fmt if the
    ld (vidBenchKbps), hl         ; raw open failed before resetting them
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
    ; KB/s = totalKB * 50 / elapsed (integer maths; guard elapsed == 0 -
    ; cannot happen for the real ~38MB fixture, but keeps this honest for
    ; any smaller file reused against this same harness later)
    ld hl, (vidBenchElapsed)
    ld a, h
    or l
    jr z, .nokbps
    call vid_kbps_calc
    ld (vidBenchKbps), hl
    jr .havekbps
.nokbps:
    ld hl, 0
    ld (vidBenchKbps), hl
.havekbps:
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

; Prints the three report rows from the values stashed by the two passes.
vid_bench_report:
    ; row 27: F_READ KB/s (or ERR)
    ld b, VIDBENCH_ROW_FREAD
    ld c, 0
    call dbg_at
    ld a, (vidFreadErr)
    or a
    jr z, .freadok
    ld hl, msgVidFreadErr
    call dbg_puts
    ld a, (vidFreadErr)
    call dbg_hex8
    jr .strmrow
.freadok:
    ld hl, msgVidFread
    call dbg_puts
    ld hl, (vidFreadKbps)
    call dbg_hex16
.strmrow:
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
    ld hl, (vidBenchKbps)
    call dbg_hex16
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

; totalKB (16-bit, vidBenchKB) * 50 / elapsed (16-bit, vidBenchElapsed,
; already confirmed nonzero by the caller) -> HL = KB/s.
; 16x8 multiply into a 24-bit accumulator (totalKB up to 65535 * 50 needs
; up to 22 bits) via 50 plain adds - a one-shot report computation, so
; the simplest correct approach wins over a shift-add multiply. Then a
; standard 24-by-16 restoring division (24 steps) for the quotient; the
; remainder is discarded. Corrupts AF, BC, DE, HL.
vid_kbps_calc:
    ld hl, (vidBenchKB)
    xor a
    ld (vidDivLo), a
    ld (vidDivHi), a
    ld (vidDivB2), a
    ld b, 50
.mulloop:
    push bc
    ld a, (vidDivLo)
    add a, l
    ld (vidDivLo), a
    ld a, (vidDivHi)
    adc a, h
    ld (vidDivHi), a
    jr nc, .noc
    ld a, (vidDivB2)
    inc a
    ld (vidDivB2), a
.noc:
    pop bc
    djnz .mulloop
    ld de, (vidBenchElapsed)
    call vid_div24by16
    ld hl, (vidDivLo)
    ret

; 24-bit dividend (vidDivB2:vidDivHi:vidDivLo, MSB first) / 16-bit
; divisor DE, in place - the same three bytes end up holding the
; quotient (low 16 bits readable as a plain word at vidDivLo). Standard
; 24-step shift/compare/subtract restoring division; the running
; remainder (HL) is discarded once the loop ends - only the quotient is
; wanted here. In: DE = divisor (nonzero - the caller guards elapsed==0).
; Corrupts AF, HL, B. Preserves DE (re-read every iteration).
vid_div24by16:
    ld hl, 0
    ld b, 24
.loop:
    ld a, (vidDivLo)
    add a, a
    ld (vidDivLo), a
    ld a, (vidDivHi)
    adc a, a
    ld (vidDivHi), a
    ld a, (vidDivB2)
    adc a, a
    ld (vidDivB2), a
    adc hl, hl                   ; remainder <<= 1, bringing in the bit
                                  ; just shifted out of the 24-bit dividend
    or a
    sbc hl, de
    jr nc, .commit
    add hl, de                   ; remainder < divisor: undo, quotient bit 0
    jr .qbit0
.commit:
    ld a, (vidDivLo)
    or 1                         ; quotient bit into the vacated LSB
    ld (vidDivLo), a
.qbit0:
    djnz .loop
    ret

vidBenchName:   db "001.VID", 0
msgVidNoBank:   db "VID NOBANK", 0
msgVidFread:    db "VID FREAD KB/S=", 0
msgVidFreadErr: db "VID FREAD ERR=", 0
msgVidStrm:     db "VID STRM  KB/S=", 0
msgVidStrmErr:  db "VID STRM  ERR=", 0
msgVidBytes:    db "VID BYTES=", 0
msgVidFrames:   db " FRAMES=", 0
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
vidBenchKbps:    dw 0
vidBenchFmt:     db 0
vidBenchFmtBad:  db 0
vidFreadKbps:    dw 0            ; pass-1 F_READ KB/s (pass 2 reuses vidBenchKbps)
vidFreadErr:     db 0            ; pass-1 error code, 0 = ok
vidStrmErr:      db 0            ; pass-2 raw error code, 0 = ok
vidDivLo:        db 0
vidDivHi:        db 0
vidDivB2:        db 0

 ENDIF ; DEBUG

    DISPLAY "video ends at ", $, " headroom ", /D, OVL_LIMIT - $
    ASSERT $ <= OVL_LIMIT
