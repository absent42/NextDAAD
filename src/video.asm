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
 IFDEF DEBUG
    xor a                        ; DIAG scaffolding (SP13 T1b hw token bug):
    ld (vidDiagOByte), a          ; clear the token-error capture at the start
    ld hl, 0                      ; of each raw open so a stale value from a
    ld (vidDiagData), hl          ; prior VIDBENCH is never mistaken for this
    ld (vidDiagData+2), hl        ; run's data
    ld (vidDiagBlks), hl
 ENDIF
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
    ld a, (vidCardFlags)          ; per-block card-address step
    and %00000010
    ld hl, 512                    ; bit 1 = 0: byte addressing, +512/block
    jr z, .stepset
    ld hl, 1                      ; bit 1 = 1: block addressing, +1/block
.stepset:
    ld (vidStrmStep), hl
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
; (Raw mode deselects the card at the end of every read, so no card
; transaction is ever left open - close is just F_CLOSE in both modes.)
; Corrupts AF.
vid_stream_close:
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
; The whole pass is bracketed by data_save/data_map_page/data_restore
; (dest in the MMU6 window) and by a Multiface disable/restore; each
; contiguous run is read inside its own CMD18/CMD12 card transaction, and
; the card is always CMD12-stopped and deselected before returning, so the
; game's normal file I/O between reads is never disturbed (no OS streaming
; state exists to poison - only the physical card selection, which we
; always release). Corrupts AF, BC, DE, HL, IX.
vid_stream_read_raw:
    ld (vidStrmNeed), de          ; bytes still to serve this call
    ld (vidReadCountSaved), de    ; original count (for the served figure)
    call data_save
    ld a, (vidReadPage)
    call data_map_page            ; MMU6 = dest page
    call vid_mf_disable           ; save + clear Multiface enable
    ld hl, DATA_WINDOW
    ld (vidStrmDest), hl
.outer:
    ld hl, (vidStrmNeed)          ; served every requested byte?
    ld a, h
    or l
    jp z, .done
    call vid_remain_zero          ; file exhausted?
    jp z, .done
    ld hl, (vidStrmBlkLen)        ; drain a buffered tail before streaming
    ld de, (vidStrmBlkPos)
    or a
    sbc hl, de
    jr z, .needstream
    call vid_drain
    jp .outer
.needstream:
    ld hl, (vidStrmRunBlocks)     ; current run empty? load the next one
    ld a, h
    or l
    jr nz, .haverun
    call vid_next_run
    jp c, .done                   ; no more runs (defensive EOF)
.haverun:
    call vid_strm_start           ; open a window on the current run
    jp c, .strmerr
.inner:
    ld hl, (vidStrmNeed)
    ld a, h
    or l
    jp z, .endwin
    call vid_remain_zero
    jp z, .endwin
    ld hl, (vidStrmRunBlocks)
    ld a, h
    or l
    jp z, .endwin                 ; run exhausted mid-window: close, next run
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
    ld hl, (vidStrmRunBlocks)     ; one card block consumed
    dec hl
    ld (vidStrmRunBlocks), hl
    ld hl, (vidStrmRunAddrLo)     ; advance card address by the step
    ld de, (vidStrmStep)
    add hl, de
    ld (vidStrmRunAddrLo), hl
    jr nc, .noaddrcarry
    ld hl, (vidStrmRunAddrHi)
    inc hl
    ld (vidStrmRunAddrHi), hl
.noaddrcarry:
 IFDEF DEBUG
    ld hl, (vidDiagBlks)         ; DIAG: one more block consumed this window
    inc hl
    ld (vidDiagBlks), hl
 ENDIF
    jp .inner
.endwin:
    call vid_strm_end
    jp c, .strmerr
    jp .outer
.done:
    call vid_mf_restore
    call data_restore
    ld hl, (vidReadCountSaved)    ; served = original count - need left
    ld de, (vidStrmNeed)
    or a
    sbc hl, de
    push hl
    pop bc                        ; BC = bytes delivered
    or a                          ; CF clear
    ret
.tokerr:
    call vid_strm_end             ; CMD12-stop + deselect before bailing
    ld a, VID_ERR_TOKEN
    jr .failrestore
.strmerr:
    ; A = VID_ERR_CMD from vid_strm_start (card already deselected there)
.failrestore:
    push af
    call vid_mf_restore
    call data_restore
    pop af
    scf
    ret

; Copy min(vidStrmNeed, buffered) bytes from vidStrmBlkBuf+BlkPos to the
; MMU6 window (vidStrmDest), advancing need/dest/BlkPos and taking that
; many off remain (buffered bytes were counted into remain when read, so
; they subtract here as delivered). Corrupts AF, BC, DE, HL.
vid_drain:
    ld hl, (vidStrmBlkLen)        ; avail = BlkLen - BlkPos
    ld de, (vidStrmBlkPos)
    or a
    sbc hl, de
    ld de, (vidStrmNeed)          ; count = min(avail, need)
    push hl                       ; avail
    or a
    sbc hl, de                    ; avail - need
    pop hl                        ; avail
    jr c, .count                  ; avail < need: count = avail
    jr z, .count                  ; avail == need: count = avail
    ld hl, (vidStrmNeed)          ; avail > need: count = need
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

; Open a read window on the current run via raw SD SPI - CMD18
; READ_MULTIPLE_BLOCK at the run's card address (transcribed from
; playvid's nf_ open sequence). NO OS streaming window is opened: we drive
; the card directly, so nothing needs "ending" beyond deselecting the card
; in vid_strm_end. The card address goes on the wire big-endian (H,L,D,E)
; in card-native units, the exact value DISK_FILEMAP gave us. Out: CF set =
; R1 rejected the command (A = VID_ERR_CMD, card released); CF clear = card
; selected and ready to stream. Corrupts AF, BC, DE, HL.
vid_strm_start:
 IFDEF DEBUG
    ld hl, 0                     ; DIAG: blocks-consumed counter is per-window
    ld (vidDiagBlks), hl
 ENDIF
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
    jr nz, .tokbad
    ld c, PORT_SPI_DAT
    ld b, 0
    inir                          ; 256 bytes (B wraps 0 -> 256 iterations)
    inir                          ; next 256 bytes; HL now +512
 IFDEF DEBUG
    push de                       ; DIAG: first 4 bytes of the block just read
    push hl                       ; (HL points 512 past the block start)
    ld de, -512
    add hl, de
    ld a, (hl)
    ld (vidDiagData+0), a
    inc hl
    ld a, (hl)
    ld (vidDiagData+1), a
    inc hl
    ld a, (hl)
    ld (vidDiagData+2), a
    inc hl
    ld a, (hl)
    ld (vidDiagData+3), a
    pop hl
    pop de
 ENDIF
    in a, (c)                     ; skip the 2-byte CRC (the nops pad the
    nop                           ; in/in to the 16T/byte interface timing)
    in a, (c)
    nop
    or a                          ; CF clear: block read
    ret
.tokbad:
 IFDEF DEBUG
    ld (vidDiagOByte), a          ; DIAG: the offending non-$FF/$FE byte
 ENDIF
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
vidRawResetByte:   db 0          ; F_READ target for the pre-map cache primer
vidReadCountSaved: dw 0          ; original requested count (served calc)
vidStrmNeed:       dw 0          ; bytes still to serve this call
vidStrmDest:       dw 0          ; next dest address in the MMU6 window
vidStrmEntryPtr:   dw 0          ; next filemap entry to consume
vidStrmEntryEnd:   dw 0          ; one past the last written entry
vidStrmRunAddrLo:  dw 0          ; current run card address, low word
vidStrmRunAddrHi:  dw 0          ; current run card address, high word
vidStrmRunBlocks:  dw 0          ; 512-byte blocks left in the current run
vidStrmStep:       dw 0          ; card-address step per block (1 or 512)
vidStrmRemainLo:   dw 0          ; file bytes not yet delivered, low word
vidStrmRemainHi:   dw 0          ; file bytes not yet delivered, high word
vidStrmBlkPos:     dw 0          ; drain cursor into vidStrmBlkBuf
vidStrmBlkLen:     dw 0          ; valid bytes held in vidStrmBlkBuf
vidFilemapBuf:     ds VID_FILEMAP_ENT*6   ; DISK_FILEMAP entries (192 bytes)
vidStrmBlkBuf:     ds 512        ; one card block held for sub-block drains

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
    call vid_bench_diag           ; raw failed: dump the hw-diagnosis rows
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

; SP13 T1b hardware-diagnosis dump (temporary scaffolding). Printed only
; when the raw pass failed (vidStrmErr != 0), on rows 24-26 (clear of
; debug.asm's reserved 30-31). Fields are decoded in the task report.
;   row 24: FLG=<DISK_FILEMAP flags byte> OBY=<offending token byte>
;           BLK=<blocks consumed in the failing window>
;   row 25: RUN0 A=<32-bit card address, hi word then lo word>
;           B=<run 0 block count> N=<number of runs parsed>
;   row 26: BLK0=<first 4 bytes of the last block INIR'd, memory order>
vid_bench_diag:
    ld b, 24
    ld c, 0
    call dbg_at
    ld hl, msgDiagFlg
    call dbg_puts
    ld a, (vidCardFlags)          ; the raw A returned by DISK_FILEMAP
    call dbg_hex8
    ld hl, msgDiagOby
    call dbg_puts
    ld a, (vidDiagOByte)
    call dbg_hex8
    ld hl, msgDiagBlk
    call dbg_puts
    ld hl, (vidDiagBlks)
    call dbg_hex16
    ld b, 25
    ld c, 0
    call dbg_at
    ld hl, msgDiagRun
    call dbg_puts
    ld hl, (vidFilemapBuf+2)      ; card address high word
    call dbg_hex16
    ld hl, (vidFilemapBuf+0)      ; card address low word
    call dbg_hex16
    ld hl, msgDiagRunB
    call dbg_puts
    ld hl, (vidFilemapBuf+4)      ; run 0 block count
    call dbg_hex16
    ld hl, msgDiagRunN
    call dbg_puts
    call vid_diag_runs            ; HL = (EntryEnd - FilemapBuf) / 6
    call dbg_hex16
    ld b, 26
    ld c, 0
    call dbg_at
    ld hl, msgDiagData
    call dbg_puts
    ld a, (vidDiagData+0)
    call dbg_hex8
    ld a, (vidDiagData+1)
    call dbg_hex8
    ld a, (vidDiagData+2)
    call dbg_hex8
    ld a, (vidDiagData+3)
    jp dbg_hex8

; Number of 6-byte filemap entries parsed. Out: HL = count. Corrupts
; AF, BC, DE, HL.
vid_diag_runs:
    ld hl, (vidStrmEntryEnd)
    ld de, vidFilemapBuf
    or a
    sbc hl, de                    ; HL = bytes of entries written
    ld de, 6
    ld bc, 0
.dl:
    or a
    sbc hl, de
    jr c, .fin
    inc bc
    jr .dl
.fin:
    ld h, b
    ld l, c
    ret

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
msgDiagFlg:     db "FLG=", 0
msgDiagOby:     db " OBY=", 0
msgDiagBlk:     db " BLK=", 0
msgDiagRun:     db "RUN0 A=", 0
msgDiagRunB:    db " B=", 0
msgDiagRunN:    db " N=", 0
msgDiagData:    db "BLK0=", 0

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
vidDiagOByte:    db 0            ; SP13 T1b hw-diag: offending token byte
vidDiagBlks:     dw 0            ; blocks consumed in the failing window
vidDiagData:     ds 4            ; first 4 bytes of the last block INIR'd
vidDivLo:        db 0
vidDivHi:        db 0
vidDivB2:        db 0

 ENDIF ; DEBUG

    DISPLAY "video ends at ", $, " headroom ", /D, OVL_LIMIT - $
    ASSERT $ <= OVL_LIMIT
