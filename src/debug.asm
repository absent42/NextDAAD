; Debug-build-only 32-column ULA console. Replaced for user-facing
; output by the Timex text engine in sub-project 2. All numbers hex.

 IFDEF DEBUG

dbg_cls:
    call ula_cls
    xor a
    ld (dbgX), a
    ld (dbgY), a
    ret

; B = row 0-23, C = col 0-31. Only touches A.
dbg_at:
    ld a, b
    ld (dbgY), a
    ld a, c
    ld (dbgX), a
    ret

; A = character. 13 = newline. Corrupts AF, BC, DE, HL.
dbg_putc:
    ld l, a                     ; keep the char across the flag test
    ld a, (dbgTilemap)
    or a
    ld a, l
    jp nz, dbg_putc_tm
    cp 13
    jr nz, .print
.newline:
    xor a
    ld (dbgX), a
    ld a, (dbgY)
    inc a
    cp 24
    jr c, .sety
    ld a, 23                ; clamp at bottom, no scrolling
.sety:
    ld (dbgY), a
    ret
.print:
    ; DE = glyph address = dbg_font + char*8
    ld l, a
    ld h, 0
    add hl, hl
    add hl, hl
    add hl, hl
    ld de, dbg_font
    add hl, de
    ex de, hl
    ; HL = screen address: H = $40 + (y AND $18), L = ((y AND 7)<<5) + x
    ld a, (dbgY)
    and $18
    add a, $40
    ld h, a
    ld a, (dbgY)
    and 7
    rrca
    rrca
    rrca                    ; (y AND 7) << 5
    ld l, a
    ld a, (dbgX)
    add a, l
    ld l, a
    ; copy 8 glyph rows, one per pixel line
    ld b, 8
.row:
    ld a, (de)
    ld (hl), a
    inc de
    inc h
    djnz .row
    ; advance cursor with wrap
    ld a, (dbgX)
    inc a
    cp 32
    jr c, .setx
    jr .newline
.setx:
    ld (dbgX), a
    ret

; Tilemap debug output: raw glyphs, white on black, 80 columns.
dbg_putc_tm:
    cp 13
    jr nz, .char
    xor a
    ld (dbgX), a
    ld a, (dbgY)
    inc a
    cp TM_ROWS
    jr c, .sety
    ld a, TM_ROWS-1
.sety:
    ld (dbgY), a
    ret
.char:
    push af
    ld a, (dbgX)
    ld c, a
    ld a, (dbgY)
    ld b, a
    ld e, 7*2                   ; pair 7: white ink (7) on black paper, always
    pop af
    call tm_putc_at
    ld a, (dbgX)
    inc a
    cp TM_COLS
    jr c, .setx
    xor a
    ld (dbgX), a
    ld a, (dbgY)
    inc a
    cp TM_ROWS
    jr c, .sety2
    ld a, TM_ROWS-1
.sety2:
    ld (dbgY), a
    ret
.setx:
    ld (dbgX), a
    ret

; Flip dbg output to the tilemap and re-print the boot diagnostics.
dbg_engage_tilemap:
    ld a, 1
    ld (dbgTilemap), a
    call boot_banner
    call ram_diag
    call ddb_diag
    ld a, (chrStatus)
    or a
    ret z
    push af                     ; dbg_at leaves A = C, preserve chrStatus
    ld b, 11
    ld c, 0
    call dbg_at
    pop af
    dec a
    jr nz, .bad
    ld hl, msgChrOverride
    jp dbg_puts
.bad:
    ld hl, msgChrBad
    jp dbg_puts

msgChrOverride: db "CHR OVERRIDE", 0
msgChrBad:      db "CHR BAD", 0
dbgTilemap:     db 0

; HL = ASCIIZ string
dbg_puts:
.loop:
    ld a, (hl)
    or a
    ret z
    inc hl
    push hl
    call dbg_putc
    pop hl
    jr .loop

; A = byte, prints two hex digits
dbg_hex8:
    push af
    rrca
    rrca
    rrca
    rrca
    call .nib
    pop af
.nib:
    and $0F
    add a, '0'
    cp '9'+1
    jr c, .out
    add a, 7                ; 'A'-'9'-1
.out:
    jp dbg_putc

; HL = word, prints four hex digits
dbg_hex16:
    push hl                 ; dbg_hex8 corrupts HL via dbg_putc
    ld a, h
    call dbg_hex8
    pop hl
    ld a, l
    jr dbg_hex8

dbg_space:
    ld a, ' '
    jp dbg_putc

boot_banner:
    ld b, 0
    ld c, 0
    call dbg_at
    ld hl, msgTitle
    call dbg_puts
    ld b, 1
    ld c, 0
    call dbg_at
    ld hl, msgCore
    call dbg_puts
    ld e, NR_CORE_MAJOR
    call nr_read
    call dbg_hex8
    ld a, '.'
    call dbg_putc
    ld e, NR_CORE_SUB
    call nr_read
    call dbg_hex8
    ld hl, msgMachine
    call dbg_puts
    ld e, NR_MACHINE_ID
    call nr_read
    call dbg_hex8
    ld hl, msgSpeed
    call dbg_puts
    ld e, NR_CPU_SPEED
    call nr_read
    jp dbg_hex8

SELFTEST_FREE_2MB equ 85    ; 14,15 + 29-47 + 48-111
SELFTEST_FREE_1MB equ 21    ; 14,15 + 29-47

ram_diag:
    ld b, 2
    ld c, 0
    call dbg_at
    ld a, (ramExpanded)
    or a
    jr z, .base
    ld hl, msgRam2M
    jr .print
.base:
    ld hl, msgRam1M
.print:
    call dbg_puts
    call bank_count_free
    jp dbg_hex8

; Exercises the allocator. Prints BANKS OK on row 10, or
; BANKS FAIL nn where nn is the failing check number.
; Relies on helpers not touching D (expected free count).
bank_selftest:
    ld b, 10
    ld c, 0
    call dbg_at
    ld a, (ramExpanded)
    or a
    jr z, .exp1mb
    ld d, SELFTEST_FREE_2MB
    jr .check1
.exp1mb:
    ld d, SELFTEST_FREE_1MB
.check1:
    call bank_count_free    ; check 1: initial free count
    cp d
    ld a, 1
    jr nz, .fail
    call bank_alloc         ; check 2: first alloc is bank 14
    cp BANK_POOL_A
    ld a, 2
    jr nz, .fail
    call bank_alloc         ; check 3: then bank 15
    cp BANK_POOL_A_END
    ld a, 3
    jr nz, .fail
    call bank_alloc         ; check 4: then bank 30 (29 withdrawn for overlay 2)
    cp BANK_POOL_B
    ld a, 4
    jr nz, .fail
    ld a, BANK_POOL_A_END   ; check 5: freed bank is reused first
    call bank_free
    call bank_alloc
    cp BANK_POOL_A_END
    ld a, 5
    jr nz, .fail
    call data_save           ; checks 6,7: write/read through the window
    ld a, BANK_POOL_A*2
    call data_map_page
    ld hl, DATA_WINDOW
    ld (hl), $AA
    inc hl
    ld (hl), $55
    dec hl
    ld a, (hl)
    cp $AA
    ld a, 6
    jr nz, .failrestore
    inc hl
    ld a, (hl)
    cp $55
    ld a, 7
    jr nz, .failrestore
    call data_restore
    ld a, BANK_POOL_A       ; check 8: count restored after frees
    call bank_free
    ld a, BANK_POOL_A_END
    call bank_free
    ld a, BANK_POOL_B
    call bank_free
    call bank_count_free
    cp d
    ld a, 8
    jr nz, .fail
    ld hl, msgBanksOk
    jp dbg_puts
.failrestore:
    push af
    call data_restore
    pop af
.fail:
    push af
    ld hl, msgBanksFail
    call dbg_puts
    pop af
    jp dbg_hex8

ddb_diag:
    ld b, 5
    ld c, 0
    call dbg_at
    ld hl, msgDdb
    call dbg_puts
    ld a, (ddbSizeHi)       ; six hex digits: full 24-bit size
    call dbg_hex8
    ld hl, (ddbSize)
    call dbg_hex16
    ld b, 6
    ld c, 0
    call dbg_at
    ld hl, msgVer
    call dbg_puts
    ld a, (ddbHeader+0)
    call dbg_hex8
    ld hl, msgTgt
    call dbg_puts
    ld a, (ddbHeader+1)
    call dbg_hex8
    ld b, 7
    ld c, 0
    call dbg_at
    ld hl, ddbHeader+8      ; 13 pointer words, wrap fills rows 7-9
    ld b, 13
.ptr:
    push bc
    push hl
    ld e, (hl)
    inc hl
    ld d, (hl)
    ex de, hl
    call dbg_hex16
    call dbg_space
    pop hl
    inc hl
    inc hl
    pop bc
    djnz .ptr
    ret

; --- Layer 2 bring-up hook (Task 2, temporary) ---
; Holding T through boot (from power-on until windows_init completes,
; where main.asm calls l2_dbg_hook) shows overlay2's l2_testcard in
; 256x192, then - on the next T press - in 320x256, then disables
; Layer 2 and returns so normal boot continues into eng_init_game/
; eng_run unaffected. Not held: returns immediately, untouched. This
; is a raw port read rather than overlay0's key_scan/kb_raw, since
; those live in an overlay this resident code has no reason to page
; in just to poll one key.

; ZF set if T was seen held on any of up to 10 consecutive frame ticks
; (row $FB, bit 4 - see kbRows/keyRows in overlay0/overlay1 for the
; same matrix layout). A single-shot port read is timing-sensitive -
; it can land on a frame where the matrix read races the border/
; interrupt work CSpect or real hardware are doing that instant, and a
; boot-time check only gets one shot at a key the owner is holding
; from power-on. Polling across ~10 frames (roughly 200ms at 50Hz),
; returning the instant a held frame is seen, makes a false "not
; held" verdict far less likely while a genuinely-released key still
; correctly reports not held (it never samples as pressed on any of
; the 10 frames). Corrupts AF, BC, DE.
l2dbg_t_held:
    ld d, 10
.frame:
    ld bc, $FBFE
    in a, (c)
    bit 4, a
    ret z                        ; held on this sample: done, ZF set
    ld a, (frameCounter)
    ld e, a
.tick:
    ld a, (frameCounter)
    cp e
    jr z, .tick                  ; wait for the next frame before resampling
    dec d
    jr nz, .frame
    ld a, 1
    or a                         ; guarantee ZF clear: not held on any sample
    ret

; A round-8 strobe/DI-probe experiment lived here briefly and was
; superseded by the bare-metal isolation ladder below (l2_bareprobe_
; hook) before any owner ever ran it - the ladder subsumes what it was
; for. Back to the plain release/press wait the T-hook always used.
l2dbg_wait_release:
    call l2dbg_t_held
    jr z, l2dbg_wait_release
    ret
l2dbg_wait_press:
    call l2dbg_t_held
    jr nz, l2dbg_wait_press
    ret

; Blank the bottom tilemap row (TM_ROWS-1, left opaque by overlay2's
; l2_testcard) with plain white-on-black spaces, then print the
; ASCIIZ string at HL there via the existing dbg_puts/dbg_at console -
; a fixed clear-then-print avoids stale trailing characters when a new
; status line is shorter than the one it replaces. Corrupts everything.
l2dbg_status:
    push hl
    ld b, TM_ROWS-1
    ld c, 0
    ld d, 1
    ld e, TM_COLS
    ld a, 7*2                    ; pair 7: white ink on black paper
    ld (tmAttr), a
    ld a, GLYPH_SPACE
    call tm_fill_rect
    ld b, TM_ROWS-1
    ld c, 0
    call dbg_at
    pop hl
    jp dbg_puts

; Like l2dbg_status, but appends a live hex dump of NR $69 (Layer 2
; enable)/$70 (resolution)/$12 (bank)/$15 (S/L/U priority) after the
; message, read back via nr_read rather than assumed - so the owner
; can report the actual register state alongside what's on screen.
; Round 1's enable path ($123B port) left Layer 2 invisible despite a
; correct-looking write; this dump exists to catch that class of bug
; immediately instead of guessing from the visual symptom alone.
; Corrupts everything.
l2dbg_status_regs:
    call l2dbg_status
    ld hl, msgRegDump
    call dbg_puts
    ld e, NR_DISPLAY_CTRL
    call nr_read
    call dbg_hex8
    call dbg_space
    ld e, NR_L2_CTRL
    call nr_read
    call dbg_hex8
    call dbg_space
    ld e, NR_L2_BANK
    call nr_read
    call dbg_hex8
    call dbg_space
    ld e, NR_LAYERS
    call nr_read
    jp dbg_hex8

; Second status row (TM_ROWS-2, also reserved by overlay2's
; l2_testcard): NR $14 (global transparency index, expect $FE), the
; Layer 2 clip window SHADOW (labelled clipW= - NOT a hardware
; readback of NR $18, see below), the Layer 2 scroll offset (NR $16/
; $17, expect $00 $00 - zeroed by l2_mode_set/l2_clip_set), and one
; live pixel read back from the drawn surface (overlay2's
; l2_peek_marker - the actual top-left corner-marker byte).
;
; The clip field used to be a live $18 readback (index-reset via $1C
; then four reads). Dropped: per wiki.specnext.dev/NextReg:$18, a
; WRITE to $18 auto-increments the index but a READ does not - so
; that old sequence re-read index 0 (X1) four times instead of
; X1,X2,Y1,Y2, which alone explains a spurious "00 00 00 00" (X1 is
; legitimately 0 in both modes) independent of whether the real
; window was fine. The owner also reported a flash of correct colour
; before the screen went grey, i.e. something about touching $18/$1C
; disturbed the live window beyond what that misread alone accounts
; for. Rather than chase the exact mechanism further, this field now
; prints overlay2's software shadow of what it actually wrote
; (l2ClipX1/X2/Y1/Y2), and l2_dbg_hook re-asserts the real clip
; window (l2_clip_set) immediately after this prints, right before
; the wait loop, so even a still-misbehaving diagnostic can't leave
; the window degenerate. Corrupts everything.
l2dbg_status2:
    ld b, TM_ROWS-2
    ld c, 0
    ld d, 1
    ld e, TM_COLS
    ld a, 7*2
    ld (tmAttr), a
    ld a, GLYPH_SPACE
    call tm_fill_rect
    ld b, TM_ROWS-2
    ld c, 0
    call dbg_at
    ld hl, msgReg14
    call dbg_puts
    ld e, NR_L2_TRANSP
    call nr_read
    call dbg_hex8
    ld hl, msgClipW
    call dbg_puts
    ld a, (l2ClipX1)
    call dbg_hex8
    call dbg_space
    ld a, (l2ClipX2)
    call dbg_hex8
    call dbg_space
    ld a, (l2ClipY1)
    call dbg_hex8
    call dbg_space
    ld a, (l2ClipY2)
    call dbg_hex8
    ld hl, msgScroll
    call dbg_puts
    ld e, NR_L2_XOFS
    call nr_read
    call dbg_hex8
    call dbg_space
    ld e, NR_L2_YOFS
    call nr_read
    call dbg_hex8
    ld hl, msgPx
    call dbg_puts
    call l2_peek_marker
    jp dbg_hex8

msgTestcardHold: db "TESTCARD - HOLD T", 0
msgTestcard256:  db "TESTCARD 256x192 - RELEASE THEN PRESS T FOR NEXT", 0
msgTestcard320:  db "TESTCARD 320x256 - RELEASE THEN PRESS T TO EXIT", 0
msgTestcardDone: db "TESTCARD DONE", 0
msgRegDump:      db " 69/70/12/15=", 0
msgReg14:        db "14=", 0
msgClipW:        db " clipW=", 0
msgScroll:       db " scroll=", 0
msgPx:           db " px=", 0

; Corrupts everything (drives overlay2's l2_testcard/l2_disable).
l2_dbg_hook:
    call l2dbg_t_held
    ret nz                       ; T not held: leave boot untouched
    ld hl, msgTestcardHold        ; proves the hook fired, BEFORE any
    call l2dbg_status             ; Layer 2 register is touched
    ld a, OVL2_PAGE
    call ovl_map_page
    xor a                        ; 256x192 first
    call l2_testcard
    ld hl, msgTestcard256
    call l2dbg_status_regs
    call l2dbg_status2
    xor a                        ; re-assert the clip window (l2_clip_set)
    call l2_clip_set             ; AFTER the diagnostic, right before the
    call l2dbg_wait_release       ; wait loop - belt and braces against
    call l2dbg_wait_press         ; the diagnostic disturbing it (see
                                  ; l2dbg_status2's header comment)
    ld a, 1                      ; then 320x256
    call l2_testcard
    ld hl, msgTestcard320
    call l2dbg_status_regs
    call l2dbg_status2
    ld a, 1                      ; re-assert the clip window, same reason
    call l2_clip_set
    call l2dbg_wait_release
    call l2dbg_wait_press
    call l2_disable
    ld hl, msgTestcardDone
    call l2dbg_status
    ; restore the whole tilemap to a normal opaque blank (undoing the
    ; card-area transparent clear) so anything the game doesn't
    ; immediately overwrite reads as a plain blank screen, not a
    ; black hole where Layer 2 used to show through
    ld b, 0
    ld c, 0
    ld d, TM_ROWS
    ld e, TM_COLS
    ld a, 7*2                    ; pair 7: white ink on black paper
    ld (tmAttr), a
    ld a, GLYPH_SPACE
    call tm_fill_rect
    ret

; --- Round 8: bare-metal isolation ladder ---
; Built to find why the card rendered correctly for a flash then went
; permanently grey every round through round 7. It found the answer:
; stage 0 (below) came back flat BLACK, not the testcard - proof Layer
; 2 was rendering but sitting BEHIND CSpect's opaque zero-filled ULA
; screen at the NR $15 priority in use at the time. See l2_enable's
; header comment (overlay2.asm) for the architecture fix that came out
; of this (Layer 2 now on top, transparent outside the art). Kept as a
; general-purpose diagnostic for future Layer 2 regressions: hold P
; from power-on (checked here, at the very top of main:, BEFORE
; hw_init/im2_init/txt_init/anything else runs) for a 4-stage ladder,
; each stage adding exactly one more piece and redrawing:
;   Stage 0: hw_init only. No im2_init (interrupts stay off - main:
;            already did `di` before this runs; the ISR never fires).
;            No txt_init (no tilemap at all). Just the L2 recipe
;            (mode+clip+scroll+enable+priority+transparency) and the
;            gradient/marker draw, 1 marker block, top-left. Expected
;            appearance NOW: the card's drawable area (see tc_gradient_
;            320's header comment on 320 mode's 240-line bound), with
;            hw_init's ULA black showing through Layer 2's transparent
;            fill everywhere outside it (no txt_init yet to disable
;            the ULA output or clear it to anything else) - that black
;            border is expected here, not a fault.
;   Stage 1: + im2_init (also does EI - the ISR is now live and
;            ticking frameCounter every frame). Still no tilemap, same
;            expected black surround. 2 marker blocks.
;   Stage 2: + txt_init (tilemap on) + tm_clear_transparent over the
;            card area + one status line. 3 marker blocks (belt and
;            braces - costs nothing, tilemap text is the real stage
;            indicator from here on).
;   Stage 3: the full existing testcard flow (same as the T-hook's
;            256x192 leg, including its register/clip-shadow dump).
; Each stage waits for P to be released then pressed again before
; advancing. After stage 3, wraps back to stage 0 rather than
; returning, so the owner can re-run the whole ladder without a
; manual reset - this path is a dead end by design, entirely separate
; from and does not alter the existing T-hook (l2_dbg_hook above).
; P not held: returns immediately, nothing touched, normal boot
; proceeds exactly as if this code didn't exist.

; ZF set if P is currently held (row $DF, bit 0 - see keyRows in
; overlay0.asm for the same matrix layout). Samples up to 10 times
; with a short busy-wait between samples rather than a single read,
; for the same reason l2dbg_t_held polls repeatedly - except this
; runs BEFORE im2_init, so frameCounter isn't ticking yet and the
; pacing has to be a plain busy-wait, not frame-synced. Corrupts
; AF, BC, DE.
l2dbg_p_held:
    ld d, 10
.sample:
    ld bc, $DFFE
    in a, (c)
    bit 0, a
    ret z                         ; held on this sample: done, ZF set
    ld bc, $3000
.wait:
    dec bc
    ld a, b
    or c
    jr nz, .wait
    dec d
    jr nz, .sample
    ld a, 1
    or a                          ; guarantee ZF clear: not held
    ret

; Raw busy-wait press/release detection (row $DF, bit 0) - used
; throughout the ladder instead of l2dbg_t_held/wait_release/press
; because stage 0 has no ISR to pace against; kept the same in later
; stages too, for one consistent key-handling path across the whole
; ladder. Corrupts AF, BC.
l2dbg_p_wait_release:
    ld bc, $DFFE
    in a, (c)
    bit 0, a
    jr z, l2dbg_p_wait_release
    ret
l2dbg_p_wait_press:
    ld bc, $DFFE
    in a, (c)
    bit 0, a
    jr nz, l2dbg_p_wait_press
    ret

msgBareStage2: db "STAGE 2 - TILEMAP + TRANSPARENT CLEAR", 0

; Never returns if entered. Corrupts everything.
l2_bareprobe_hook:
    call l2dbg_p_held
    ret nz                        ; P not held: leave boot untouched
.stage0:
    call hw_init
    ld a, OVL2_PAGE
    call ovl_map_page
    xor a
    call l2_bareprobe_draw
    xor a
    call l2_bareprobe_marker      ; 1 block
    call l2dbg_p_wait_release
    call l2dbg_p_wait_press
.stage1:
    call im2_init                 ; also EI's - ISR now live
    xor a
    call l2_bareprobe_draw
    ld a, 1
    call l2_bareprobe_marker      ; 2 blocks
    call l2dbg_p_wait_release
    call l2dbg_p_wait_press
.stage2:
    call txt_init
    xor a
    call l2_bareprobe_draw
    ld b, 0
    ld c, 0
    ld d, TM_ROWS-1
    ld e, TM_COLS
    call tm_clear_transparent
    ld a, 2
    call l2_bareprobe_marker      ; 3 blocks
    ld hl, msgBareStage2
    call l2dbg_status
    call l2dbg_p_wait_release
    call l2dbg_p_wait_press
.stage3:
    xor a
    call l2_testcard               ; the full existing T-hook flow
    ld hl, msgTestcard256
    call l2dbg_status_regs
    call l2dbg_status2
    call l2dbg_p_wait_release
    call l2dbg_p_wait_press
    jr .stage0                     ; wrap around for another pass

dbg_font:
    INCBIN "../tools/DAAD-READY/ASSETS/CHARSET/AD8x8.CHR"   ; 2048 bytes, 256 glyphs

msgTitle:   db "NEXTDAAD FOUNDATION", 0
msgCore:    db "CORE ", 0
msgMachine: db " MACHINE ", 0
msgSpeed:   db " SPD ", 0
msgFrames:  db "FRAMES ", 0
msgRam2M:     db "RAM 1792K FREE ", 0
msgRam1M:     db "RAM 768K FREE ", 0
msgBanksOk:   db "BANKS OK", 0
msgBanksFail: db "BANKS FAIL ", 0
msgDdb:      db "GAME.DDB SIZE ", 0
msgVer:      db "VER ", 0
msgTgt:      db " TGT ", 0

 ELSE

; Release stubs: same entry points, no output, minimal size.
dbg_cls:
dbg_at:
dbg_putc:
dbg_puts:
dbg_hex8:
dbg_hex16:
dbg_space:
boot_banner:
ram_diag:
bank_selftest:
ddb_diag:
dbg_engage_tilemap:
    ret

 ENDIF

msgMissing:  db "ERROR: GAME.DDB NOT FOUND", 0
msgOversize: db "ERROR: GAME.DDB TOO BIG", 0
msgBadHdr:   db "ERROR: GAME.DDB BAD HEADER", 0

dbgX: db 0
dbgY: db 0
