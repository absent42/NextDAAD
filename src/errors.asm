; DAAD runtime errors 0-8. Debug: classic diagnostic on row 30.
; Both build types paint a magenta bar across tilemap row 0 - the
; classic border is INVISIBLE behind the full-coverage 640x256
; tilemap, so the border write alone signals nothing once the
; engine display is active (owner-discovered). The border write is
; kept for completeness. Both build types also print a legible
; "NextDAAD: RUNTIME ERROR - E<n>" into that same row-0 bar (via
; fatal_puts below) - previously that text was DEBUG-only, so a
; release build showed nothing but the bar. Never returns.
; Codes raised in SP3: 0 (obj_ptr), 2 (obj_move to 255), 3 (PROCESS
; depth), 4 (nested DOALL), 5 (illegal opcode), 6 (bad process),
; 7 (bad message/location number). Codes 1 and 8 are defined for
; parity and first raised by later sub-projects.
; Bar: tm_fill_rect row 0, full width, space glyph, pair 55
; (paper 3 magenta, ink 7 white) = attr 110 via tmAttr - classic ULA
; puts magenta at index 3 and white at index 7.
err_raise:
    ld (errCode), a
 IFDEF DEBUG
    ld b, 30
    ld c, 0
    call dbg_at
    ld hl, msgErr
    call dbg_puts
    ld a, (errCode)
    call dbg_hex8
    ld hl, msgErrP
    call dbg_puts
    ld a, (procSP)
    or a
    jr z, .nop
    dec a
    call eng_rec_ptr_a
    ld a, (hl)
.nop:
    call dbg_hex8
    ld hl, msgErrV
    call dbg_puts
    ld a, (flags+FLAG_VERB)
    call dbg_hex8
    ld hl, msgErrN
    call dbg_puts
    ld a, (flags+FLAG_NOUN1)
    call dbg_hex8
    ld hl, msgErrC
    call dbg_puts
    ld a, (curCondact)
    call dbg_hex8
 ENDIF
    ld a, 110                   ; pair 55: magenta paper (3), white ink (7)
    ld (tmAttr), a
    ld b, 0
    ld c, 0
    ld d, 1
    ld e, TM_COLS               ; magenta bar across row 0
    ld a, GLYPH_SPACE
    call tm_fill_rect
    ld hl, msgRuntimeErr
    call fatal_puts              ; release-safe; leaves B/C/E positioned
    ld a, (errCode)              ; right after the text (see fatal_puts)
    add a, '0'                   ; codes are single-digit decimal (0-8)
    call tm_putc_at              ; append the digit in the same spot
    ld a, 3                     ; border too (invisible under the
    out ($FE), a                ; tilemap, correct elsewhere)
    di
    ld hl, audRequest2          ; file a stream-stop alongside the silence,
    set 0, (hl)                 ; matching the stream-stop discipline. The
                                ; di + busy-halt below means the ISR never
                                ; ticks again, so audio_init's PSG silence
                                ; is what actually takes effect here and the
                                ; next boot's aud_boot_probe clears aysFlags;
                                ; the filed bit costs nothing and keeps the
                                ; reset paths consistent.
    call audio_init             ; a raised error must not leave the
                                ; music's last note droning through
                                ; the halt loop
.halt:
    jr .halt

errCode: db 0

; ddbName: relocated here from file.asm (SP11 Task 3 review fix 3 -
; CSpect's esxDOS emulation does not implement wildcard F_OPEN, so the
; earlier "GAMEn.D*" wildcard technique - correct against the
; documented esxDOS contract, but CSpect-incompatible - could not
; survive a real CSpect run; owner sweep caught it). The fix needs a
; 10-byte buffer ("GAMEn.DDB",0 - 9 characters + NUL) so
; xpart_build_name (overlay0.asm) can write the LITERAL target name for
; every part, no wildcard. file.asm's pre-flags region has no room for
; the extra byte a GROWTH there would cost (engine.asm's flags ALIGN
; 256 pad only absorbs a SHRINK, per T7's precedent - this task's own
; report), so the buffer lives post-flags instead, alongside curPart.
; ddb_load (file.asm, unchanged) still reads this exact label via its
; own hardcoded "ld ix, ddbName" - only the storage moved, the loader's
; contract did not. Compiled default below is "GAME.DDB\0" (9 bytes,
; byte-identical to file.asm's old default) plus one spare byte,
; totalling the 10-byte capacity; xpart_build_name overwrites all 10
; bytes every time (n=1 included - its own gameddb literal is this
; same 10-byte "GAME.DDB\0\0" content, so that path is a byte-identical
; full rewrite, not a partial one).
ddbName: db "GAME.DDB", 0, 0

; SP11 Task 3: active part number (1-9), 1-based like the DDB filename
; suffix (GAME.DDB = part 1, GAME2.DDB = part 2, ...). Compiled static
; db 1 is correct at cold boot (GAME.DDB is always part 1). A warm
; re-entry (nextreg 2,1) leaves it at whatever part was active when the
; reset fired - same documented staleness as the mouse statics
; (h_mouse's header comment, overlay0.asm). On real hardware nextreg
; 2,1 hands control back to NextZXOS, which reloads the .nex fresh
; (curPart and ddbName above both come back to their compiled
; GAME.DDB/part-1 defaults with the rest of the image); the CSpect dev
; loop's dirty-RAM re-entry (boot_data_init's own header comment,
; main.asm) is the only path where either can stay stale post-switch -
; neither boot_data_init nor main.asm's unconditional boot-time
; ddb_load call can be reached from this task's files (overlay0.asm/
; errors.asm only) to add a reset, so this rides with the same
; accepted, documented residual as the pre-existing mouse statics.
curPart: db 1
 IFDEF DEBUG
msgErr:  db "E", 0
msgErrP: db " P", 0
msgErrV: db " V", 0
msgErrN: db " N", 0
msgErrC: db " C", 0
 ENDIF

; HL = ASCIIZ message. Prints at row 0 from col 0, using the current
; tmAttr - fatal() and err_raise both set tmAttr and paint the row-0
; bar with it just before calling this, so the text lands on that same
; background. Release-safe: no DEBUG gate, no windows_init/tmUp
; dependency, just tm_putc_at (always resident) - the only precondition
; is txt_init having run at least once (fatal() forces this itself;
; err_raise only ever runs post-boot, long after boot's txt_init).
; Leaves B=0, C=column right after the last character, E=tmAttr, so a
; caller can chain a raw tm_putc_at immediately after (err_raise
; appends the error digit this way). Corrupts AF, HL.
fatal_puts:
    ; msgRuntimeErr/msgRdStack now live in overlay0.asm's free space (no
    ; post-flags room here - see there), so HL below needs overlay0's
    ; page mapped at MMU7 to be dereferenceable. No restore needed -
    ; both funnels (fatal/err_raise) are terminal and never return.
    nextreg NR_MMU7, OVL0_PAGE
    ld a, (tmAttr)
    ld e, a
    ld b, 0
    ld c, 0
.loop:
    ld a, (hl)
    or a
    ret z
    push hl
    call tm_putc_at
    pop hl
    inc hl
    inc c
    jr .loop

; msgRuntimeErr and msgRdStack relocated to overlay0.asm's free space
; (post-flags resident here had no room to grow) - see fatal_puts's
; MMU7 map above. Call sites (here and ddbtext.asm's rd_stack_fatal)
; are unchanged pointer-loads; only fatal_puts ever dereferences them.
