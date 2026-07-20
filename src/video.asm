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
    rla
    cp d
    jr c, .skip
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
; vid_stream_* - the F_READ-backed streaming interface (Task 1 ships
; this implementation behind the interface; the bench below measures
; IT, and the streaming-mechanism decision may swap the internals later
; without changing these three signatures - see the task report).
; ---------------------------------------------------------------------

; In: IX = ASCIIZ filename pointer (root name; no PARTn\ probing - that
;     is Task 2's job once vid_play knows the active part; this bench-
;     only entry always opens exactly the name it is given).
; Out: CF clear = opened; vidHandle holds the esxDOS handle; vidSizeLo/
;      vidSizeHi hold the 32-bit byte size read via F_FSTAT (low word/
;      high word - feed straight into vid_classify as HL/DE).
;      CF set = failed (A = esxDOS error code); vidHandle left at $FF.
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
    push af                      ; A = handle, about to be needed again
    ld ix, vidFstatBuf
    pop af
    rst $08
    db ESX_F_FSTAT
    jr c, .statfail
    ld hl, (vidFstatBuf+7)
    ld (vidSizeLo), hl
    ld hl, (vidFstatBuf+9)
    ld (vidSizeHi), hl
    or a
    ret
.statfail:
    push af
    ld a, (vidHandle)
    call esx_fclose
    ld a, $FF
    ld (vidHandle), a
    pop af
    scf
    ret
.fail:
    scf
    ret

; In: A = destination 8K page, mapped into the MMU6 window ($C000) for
;     the duration of this read only (the established data_save/
;     data_map_page/data_restore bracket - see ext_xmes/font_load,
;     overlay0.asm/overlay2.asm); DE = requested byte count, <= $2000
;     (one MMU6 window's worth - callers chunk larger transfers into
;     repeated calls, exactly like ddb_load/ext_xmes/font_load's own
;     $2000-per-call reads).
; Out: CF set = esxDOS I/O error, A = esxDOS error code.
;      CF clear = BC = bytes actually read. esxDOS F_READ clears CF on a
;      short/EOF read too (only a real error sets it) - callers MUST
;      compare BC against the requested DE themselves, the established
;      BC-discipline count-check law (file.asm's sav_read comment;
;      font_load's "BC discipline" comment, overlay2.asm).
; Corrupts AF, BC, DE, HL, IX.
vid_stream_read:
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
; Corrupts AF.
vid_stream_close:
    ld a, (vidHandle)
    cp $FF
    ret z
    call esx_fclose
    ld a, $FF
    ld (vidHandle), a
    ret

vidHandle:   db $FF
vidSizeLo:   dw 0
vidSizeHi:   dw 0
vidFstatBuf: ds 11             ; F_FSTAT buffer: +0 '*' +1 $81 +2 attr
                                ; +3 time +5 date +7(4) size (esxDOS API)

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
; Opens sd\001.VID (root only), streams it end-to-end through
; vid_stream_read in maximal ($2000) MMU6-window chunks, times the pass
; via frameCounter (interrupts.asm, incremented once per 50Hz interrupt),
; then prints total bytes, elapsed frames, computed KB/s, and
; vid_classify's verdict for the file. One shot per call - re-invoking
; VIDBENCH re-opens and re-measures from scratch (the spec's RE-RUNNABLE
; requirement: a new NextZXOS/Next-core release is expected to change
; the numbers). Output uses the DEBUG dbg_at/dbg_puts/dbg_hex8/dbg_hex16
; console helpers (debug.asm; release-safe stubs, but this whole routine
; is IFDEF DEBUG anyway) - hex only, matching every existing use of
; those helpers in this codebase (no decimal printer exists).
 IFDEF DEBUG

VIDBENCH_ROW1 equ 28            ; two report rows near the bottom of the
VIDBENCH_ROW2 equ 29            ; 32-row tilemap, clear of rows 30-31
                                 ; (debug.asm's own reserved status lines
                                 ; - see l2_testcard's header comment,
                                 ; overlay2.asm) and clear of a typical
                                 ; game window's rows

vid_bench:
    call bank_alloc              ; transient scratch bank for the MMU6
    jr nc, .havebank              ; read target (banks.asm)
    ld b, VIDBENCH_ROW1
    ld c, 0
    call dbg_at
    ld hl, msgVidNoBank
    jp dbg_puts
.havebank:
    ld (vidBenchBank), a
    add a, a                     ; 16K bank -> its lower 8K page
    ld (vidBenchPage), a
    ld ix, vidBenchName
    call vid_stream_open
    jr nc, .opened
    push af
    ld b, VIDBENCH_ROW1
    ld c, 0
    call dbg_at
    ld hl, msgVidOpenFail
    call dbg_puts
    pop af
    call dbg_hex8
    ld a, (vidBenchBank)
    jp bank_free
.opened:
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
    jr z, .readloop               ; BC == $2000: full window, more likely
                                   ; follows - keep streaming
    ; BC < $2000: short/EOF read (esxDOS clears CF on this - see the
    ; vid_stream_read header) - the file is exhausted
    ld hl, (frameCounter)
    ld (vidBenchEnd), hl
    call vid_stream_close
    ld a, (vidBenchBank)
    call bank_free
    jp vid_bench_report
.readfail:
    push af
    call vid_stream_close
    ld a, (vidBenchBank)
    call bank_free
    ld b, VIDBENCH_ROW1
    ld c, 0
    call dbg_at
    ld hl, msgVidReadFail
    call dbg_puts
    pop af
    jp dbg_hex8

; Derives and prints the four report values. vidSizeLo/vidSizeHi are
; still the size vid_stream_open captured for THIS file, so the
; classification printed here is for the exact bytes just streamed.
; Corrupts everything.
vid_bench_report:
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
    ; --- print ---
    ld b, VIDBENCH_ROW1
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
    ld b, VIDBENCH_ROW2
    ld c, 0
    call dbg_at
    ld hl, msgVidKbps
    call dbg_puts
    ld hl, (vidBenchKbps)
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
msgVidOpenFail: db "VID OPEN FAIL ", 0
msgVidReadFail: db "VID READ FAIL ", 0
msgVidBytes:    db "VID BYTES=", 0
msgVidFrames:   db " FRAMES=", 0
msgVidKbps:     db "VID KB/S=", 0
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
vidDivLo:        db 0
vidDivHi:        db 0
vidDivB2:        db 0

 ENDIF ; DEBUG

    DISPLAY "video ends at ", $, " headroom ", /D, OVL_LIMIT - $
    ASSERT $ <= OVL_LIMIT
