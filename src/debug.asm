; Debug-build-only 32-column ULA console. Replaced for user-facing
; output by the Timex text engine in sub-project 2. All numbers hex.

 IFDEF DEBUG

dbg_cls:
    call ula_cls
    xor a
    ld (dbgX), a
    ld (dbgY), a
    ret

; SP14c batch B DBG4: shared entry stub for the common "row N, column
; 0" call shape (ten sites in this file, one more in errors.asm).
; B = row 0-23. Only touches A.
dbg_at0:
    ld c, 0
    jr dbg_at

; B = row 0-23, C = col 0-31. Only touches A.
dbg_at:
    ld a, b
    ld (dbgY), a
    ld a, c
    ld (dbgX), a
    ret

; DEBUG marker column into C: tmCols-10 (was literal 70 at 80 cols).
; Corrupts A; preserves B, DE, HL.
dbg_markcol:
    ld a, (tmCols)
    sub 10
    ld c, a
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
    ; The console draws from fontData, the resident embedded font shared
    ; with the tilemap, rather than its own copy of the stock DAAD charset.
    ; The two agree up to glyph 32 and diverge from '!' onward, so console
    ; text renders in the shipped face - cosmetic, and worth 2048 bytes of
    ; DEBUG resident space.
    ; DE = glyph address = fontData + char*8
    ; SP14c batch B DBG1: Z80N MUL D,E replaces the *8 shift chain
    ld e, a
    ld d, 8
    mul d, e
    ld hl, fontData             ; the resident embedded font (tilemap.asm)
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
; SP14c batch B DBG3: the column-wrap path used to re-type this same
; row-advance/clamp body verbatim (.sety2); it now shares .rowadv/
; .sety via a jump, matching dbg_putc's own .print-tail fold above.
dbg_putc_tm:
    cp 13
    jr nz, .char
.rowadv:
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
    ld e, TM_ATTR_DEFAULT        ; reserved pair 0: white ink on black paper, always
    pop af
    call tm_putc_at
    ld a, (tmCols)
    ld e, a                     ; E free: attr already consumed by tm_putc_at
    ld a, (dbgX)
    inc a
    cp e
    jr c, .setx
    jr .rowadv
.setx:
    ld (dbgX), a
    ret

; Flip dbg output to the tilemap and re-print the boot diagnostics.
dbg_engage_tilemap:
    ld a, 1
    ld (dbgTilemap), a
    call boot_banner
    call ram_diag
    call bank_selftest_show
    call ddb_diag
    ld a, (chrStatus)
    or a
    ret z
    push af                     ; dbg_at leaves A = C, preserve chrStatus
    ld b, 11
    call dbg_at0
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
bankSelfRes:    db 255      ; bank_selftest verdict: 0 = OK,
                            ; 1-8 = failing check, 255 = not run

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
    swapnib                     ; SP14c batch B DBG2: Z80N nibble swap
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

; (The SP14c E6 histogram report row dbg_hist_row lived here until the
; SP17 T8 wave: the histogram's verdict landed in-code - Rabenstein
; owner session, buckets 00 00 FF 00 00 00 00 00 - and the instrument
; was stripped with eng_ptr_abs_hist at batch close, as promised.)

; SP14c gate follow-up (OV0-3 + OBJ1 measurement instrument): session-
; cumulative 16-bit iteration counter across the five deferred obj-
; table scan-hoist sites - obj_find_pass/h_dropall/owf_core/
; weight_total (overlay0.asm, OV0-3) and list_at's two passes
; (objname.asm, the OBJ1 site). Every site calls this unconditionally
; (Release gets the no-op stub below, matching this file's own
; dbg_at/dbg_puts convention - no IFDEF DEBUG needed at any of the six
; call sites). Not auto-reset per turn: a resident per-turn zero hook
; would need touching engine.asm's own turn loop, outside this task's
; authorized scope (list_at only) - the owner instead reads
; objScanCount before and after one command of interest and takes the
; difference. Peek address: grep OBJSCANCOUNT in the build map.
; Corrupts HL, F only - every call site's own liveness was checked
; against exactly that (see the report).
objscan_tick:
    ld hl, objScanCount
    inc (hl)
    ret nz
    inc hl
    inc (hl)
    ret

objScanCount: dw 0

dbg_space:
    ld a, ' '
    jp dbg_putc

boot_banner:
    ld b, 0
    call dbg_at0
    ld hl, msgTitle
    call dbg_puts
    ld b, 1
    call dbg_at0
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

; Expected free-bank counts. These MUST match what bank_table_init
; actually frees - they are the allocator's tripwire, and a stale value
; here disables it. Both were one too high until 2026-08-12 because they
; still counted bank 35, which BANK_POOL_B stopped including when
; VID_PAGE2/SFX_PAGE took it (the withdrawal was made unconditional in
; both build variants, see nextdaad.inc's bank map). Check 1 had been
; failing ever since, on the ULA console where the verdict was never
; replayed to the tilemap and so was never seen.
SELFTEST_FREE_2MB equ 82    ; 14,15 + 20-23 + 36-47 + 48-111 (28,29 withdrawn
                            ; for the overlays, 30-34 for the Layer 2 back
                            ; surface, 35 for VID_PAGE2/SFX_PAGE)
SELFTEST_FREE_1MB equ 18    ; 14,15 + 20-23 + 36-47 (same withdrawals)

ram_diag:
    ld b, 2
    call dbg_at0
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
    call bank_alloc         ; check 4: then bank 20, the first of the
                            ; pool released from the DDB reservation
    cp BANK_POOL_C
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
    ld a, BANK_POOL_C
    call bank_free
    call bank_count_free
    cp d
    ld a, 8
    jr nz, .fail
    xor a                   ; 0 = every check passed
    jr .verdict
.failrestore:
    push af
    call data_restore
    pop af
.fail:
.verdict:
    ld (bankSelfRes), a
    ; falls into the printer

; Print the LATCHED verdict at row 10: "BANKS OK", or "BANKS FAIL nn"
; with the failing check number. Separate from the checks themselves so
; dbg_engage_tilemap can replay it onto the tilemap without re-running
; them - re-running is not safe once boot is past. The checks allocate,
; free and assert an exact free count, and by the time the tilemap comes
; up the audio banks are claimed and the picture cache may hold pool
; banks, so a second run would fail on state that is perfectly correct.
; Corrupts AF, BC, DE, HL.
bank_selftest_show:
    ld b, 10
    call dbg_at0
    ld a, (bankSelfRes)
    or a
    jr nz, .bad
    ld hl, msgBanksOk
    jp dbg_puts
.bad:
    push af
    ld hl, msgBanksFail
    call dbg_puts
    pop af
    jp dbg_hex8

ddb_diag:
    ld b, 5
    call dbg_at0
    ld hl, msgDdb
    call dbg_puts
    ld a, (ddbSizeHi)       ; six hex digits: full 24-bit size
    call dbg_hex8
    ld hl, (ddbSize)
    call dbg_hex16
    ld b, 6
    call dbg_at0
    ld hl, msgVer
    call dbg_puts
    ld a, (ddbHeader+0)
    call dbg_hex8
    ld hl, msgTgt
    call dbg_puts
    ld a, (ddbHeader+1)
    call dbg_hex8
    ld b, 7
    call dbg_at0
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

; Frame-paced wait for T to be released, then pressed again, built on
; l2dbg_t_held above.
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
;
; SP14c batch B DBG6: B=row, D=height. Fills a tmCols-wide white-ink/
; black-paper, space-glyph bar - the exact 8-instruction sequence
; l2dbg_status/l2dbg_status2 each repeated verbatim.
; Corrupts AF, BC, DE, HL (tm_fill_rect's own contract).
dbg_bar_white:
    ld c, 0
    ld a, (tmCols)
    ld e, a
    ld a, TM_ATTR_DEFAULT        ; reserved pair 0: white ink on black paper
    ld (tmAttr), a
    ld a, GLYPH_SPACE
    jp tm_fill_rect               ; tail call - returns to OUR caller

l2dbg_status:
    push hl
    ld b, TM_ROWS-1
    ld d, 1
    call dbg_bar_white
    ld b, TM_ROWS-1
    call dbg_at0
    pop hl
    jp dbg_puts

; Like l2dbg_status, but appends a live hex dump of NR $69 (Layer 2
; enable)/$70 (resolution)/$12 (bank)/$15 (S/L/U priority), read back
; via nr_read rather than assumed - so the owner can report the actual
; register state alongside what is on screen (a correct-looking enable
; write can still leave Layer 2 invisible). Corrupts everything.
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
; l2_testcard): NR $14 (global transparency colour, expect $E3), the
; Layer 2 clip window SHADOW (clipW= - overlay2's l2ClipX1/X2/Y1/Y2,
; NOT a hardware readback: NR $18 cannot be read back, see l2_clip_set),
; the scroll offset (NR $16/$17, expect $00 $00), and one live pixel
; read back from the drawn surface (l2_peek_marker - the top-left
; corner-marker byte). Called by the bare-metal isolation ladder's
; stage 3 straight after l2_testcard, which has already set the clip
; window (l2_mode_set -> l2_clip_set) as part of its own flow.
; Corrupts everything.
l2dbg_status2:
    ld b, TM_ROWS-2
    ld d, 1
    call dbg_bar_white
    ld b, TM_ROWS-2
    call dbg_at0
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

; --- Bare-metal isolation ladder ---
; Permanent bring-up diagnostic for Layer 2 regressions. Hold P from
; power-on (checked at the very top of main:, BEFORE hw_init/im2_init/
; txt_init/anything else) for a 4-stage ladder that adds exactly one
; piece per stage and redraws, isolating which layer/init step a fault
; belongs to:
;   Stage 0: hw_init only. No im2_init (interrupts stay off; main: did
;            `di`). No txt_init (no tilemap). Just the L2 recipe
;            (mode+clip+scroll+enable+priority+transparency) and the
;            gradient/marker draw, 1 marker block, top-left. hw_init's
;            ULA black shows through Layer 2's transparent fill outside
;            the card's drawable area (see tc_gradient_320's 240-line
;            bound) - that black border is expected, not a fault.
;   Stage 1: + im2_init (also EI - ISR live, frameCounter ticking).
;            Still no tilemap, same black surround. 2 marker blocks.
;   Stage 2: + txt_init (tilemap on) + tm_clear_blank over the
;            card area + one status line. 3 marker blocks.
;   Stage 3: the full testcard flow (l2_testcard's 256x192 leg,
;            including its register/clip-shadow dump).
; Each stage waits for P released then pressed before advancing. After
; stage 3 it wraps back to stage 0 rather than returning, so the ladder
; re-runs without a reset - a dead end by design. P not held: returns
; immediately, nothing touched.

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
    ld bc, 0
    ld d, TM_ROWS-1
    ld a, (tmCols)
    ld e, a
    call tm_clear_blank
    ld a, 2
    call l2_bareprobe_marker      ; 3 blocks
    ld hl, msgBareStage2
    call l2dbg_status
    call l2dbg_p_wait_release
    call l2dbg_p_wait_press
.stage3:
    xor a
    call l2_testcard               ; the full existing testcard flow
    ld hl, msgTestcard256
    call l2dbg_status_regs
    call l2dbg_status2
    call l2dbg_p_wait_release
    call l2dbg_p_wait_press
    jr .stage0                     ; wrap around for another pass

; --- DEBUG EXTERN probe routes (overlay0.asm's extVec vectors 6 and
; 8-14 point here) - relocated from overlay0.asm: its DEBUG headroom
; hit exactly 0 while this resident tail had ~1.2KB free, and h_extern
; dispatches with resident always mapped, so the extVec rows reach
; these bodies directly at zero overlay cost. Each trampoline is the
; established push-target/ovl_map_page idiom (font_load_switch,
; xpart_load_fail's own hop, the old vid_bench_trampoline, etc.);
; ovl_map_page is resident (banks.asm), and running the remap from
; resident rather than from within the $E000 window being remapped is
; if anything safer. --------------------------------------------------

; EXTERN vector 6 (silicon keyboard-defect task): DEBUG-only route to
; KTEST, the keyboard matrix/decode diagnostic (tests/test.dsf's KTEST
; verb; body lives in overlay1.asm/OVL1_PAGE alongside kb_raw/kb_char).
; Reuses vector 6 - free since VIDBENCH's retirement (see that commit's
; own note); avoids 3/4/7 (live: XMESSAGE/XPART/XUNDONE) and 5 (already
; forwards to a loaded XBN).
ktest_trampoline:
    ld hl, ktest_poll
    push hl
    ld a, OVL1_PAGE
    jp ovl_map_page

; EXTERN vector 8: NXBEN (the SP15 T2 decode-kernel bench) is RETIRED
; with the v2 format freeze (SP15 3a page-layout redesign): its job -
; the silicon coefficients behind the freeze - is done, its kernels
; graduated into the production decoder (video.asm hot page), and its
; ~2.4KB of VID_PAGE2 DEBUG space now funds the v2 open/load cluster
; plus the streaming cluster's move off the hot page. git holds the
; bench (commits 5cc2c70/a63ccfd lineage) and the DMAT/DMACC
; precedent before it. Vector 8 is reused below (Card #6 fixture
; wave); 5 forwards to a loaded XBN (suite check 44 holds because the
; suite stages no XBN - the no-XBN fallback is inert), 6 is KTEST's.
;
; EXTERN vectors 8/9/10 (Card #6 SNAP=03/00 sitting follow-up,
; .superpowers/sdd/sp14a-task-4-report.md section 41): DEBUG-only
; routes for tests/test.dsf's L2MOD/LHIDE/LSHOW verbs, so the owner
; can drive the two snapshot branches the seven-leg sitting could not
; reach (the test template runs 320x256 mode-1 always, so
; vid_snap_geom's mode-0/hidden-L2 branches never ran on silicon).
; L2MOD (vector 8) drops the template into the mode-0 test-card state
; (l2_testcard, overlay2.asm) - a following VPLY1 should then read
; SNAP=03. LHIDE/LSHOW (vectors 9/10) trampoline straight to
; l2_disable/l2_enable (overlay2.asm) - the same NR $69 bit
; vid_snap_geom reads - so a following VPLY1 after LHIDE should read
; SNAP=00. Same push-target/ovl_map_page idiom as ktest_trampoline.
; l2mod_run's overlay2.asm wrapper exists only because l2_testcard
; needs A = mode on entry, which this trampoline cannot set before
; the page switch (ovl_map_page's own A-clobber, loading OVL2_PAGE);
; LHIDE/LSHOW need no such wrapper since l2_disable/l2_enable take no
; argument, so they push those routines directly.
l2mod_trampoline:
    ld hl, l2mod_run
    push hl
    ld a, OVL2_PAGE
    jp ovl_map_page
l2hide_trampoline:
    ld hl, l2_disable
    push hl
    ld a, OVL2_PAGE
    jp ovl_map_page
l2show_trampoline:
    ld hl, l2_enable
    push hl
    ld a, OVL2_PAGE
    jp ovl_map_page

; EXTERN vector 11 (SP17 T5 Layer 2 scroll bring-up, run sheet
; .superpowers/sdd/sp14a-task-4-report.md section 41.4): DEBUG-only
; route for tests/test.dsf's ten LSxxx owner verbs, which prove the
; Layer 2 offset registers on silicon (the 9th X bit NR $71, X/Y wrap
; at both modes, clip-window interaction, mid-raster write tearing)
; before T5 designs a pan around them. ONE vector for all ten: the
; EXTERN's first parameter selects a config row in overlay2's l2sCfg,
; so a new probe costs a table row, not a vector (11-15 are the last
; free ones - 5 forwards to a loaded XBN; suite check 44 holds because
; the suite stages no XBN, so the no-XBN fallback stays inert). Same
; push-target/ovl_map_page idiom as the trampolines above; the config
; index rides in B because ovl_map_page clobbers A (h_extern leaves
; the parameter in both).
l2scr_trampoline:
    ld hl, l2scr_run
    push hl
    ld a, OVL2_PAGE
    jp ovl_map_page

; EXTERN vector 12 (SP17 player bench - the NXBEN revival, card
; .superpowers/sdd/sp14a-task-4-report.md section 42): DEBUG-only
; route for tests/test.dsf's NXBO/NXBC/NXBK verbs. NXBEN's vector 8
; went to the Card #6 fixture wave while the bench was retired, so the
; revival takes 12 (12-15 are the last free ones; 5 forwards to a
; loaded XBN - suite check 44 holds because the suite stages no XBN,
; so the no-XBN fallback stays inert). ONE vector for all three modes:
; the mode rides flags+250 (the stage-ladder convention the retired
; bench used), set by the verb's LET before the shared EXTERN, so a
; new mode costs a table row rather than a vector. The bench's fourth
; row group (direct-serve transport) needs a LIVE armed session and
; cannot come through here at all - it rides the player instead
; (flags+248 + a GFX n 13 verb; see video.asm's vid_run bench hook).
; Same push-target/ovl_map_page idiom as the trampolines above.
nxb_trampoline:
    ld hl, nxb_entry
    push hl
    ld a, VID_PAGE
    jp ovl_map_page

; --- Ring-2 placement probe (SP18 item 7 Task 9, spec OP1) - back in
; its original home: Task 9 landed these here, Task 10 pushed them to
; overlay0.asm when this tail had only 3 bytes free, and the same
; squeeze in reverse (overlay0 at exactly 0 headroom, this tail ~1.2KB
; free) brings them back. extVec vectors 13/14 (overlay0.asm) point
; here directly - resident is always mapped, so dispatch needs no
; trampoline and a debugger CALL to either symbol works regardless of
; what slot 7 holds. ---------------------------------------------------
; V1 silicon instruments for the AUD_STAGE2 candidate: $4400-$47FF (1K)
; inside the classic ULA pixel screen ($4000-$57FF), believed dead once
; the tilemap/Layer 2 are up. RING2FILL primes the candidate with a
; $A5 sentinel; RING2CHK scans it back and reports the first mismatch
; (address + byte, via dbg_hex16/dbg_hex8) or "OK". Owner-invoked only,
; via a debugger CALL to the symbol or tests/sfxlong.dsf's R2FILL/
; R2CHK verbs - no automatic call site exists anywhere in the boot or
; engine flow, so Release carries none of this.
;
; TIMING PRECONDITION: only call these once dbgTilemap=1 (i.e. after
; dbg_engage_tilemap has run - boot has reached the parser). Before
; that point dbg_puts/dbg_putc route through the ULA-pixel fallback
; above, which plots at H = $40 + (y AND $18) .. +7 - rows 0-7 land
; on H=$40-$47, overlapping this exact candidate ($44-$47). An early
; call would have its OWN status print corrupt the region under test.
; Neither routine calls dbg_cls for the same reason: it unconditionally
; clears the WHOLE ULA screen via ula_cls (hardware.asm).
RING2_BASE equ $4400
RING2_LEN  equ $0400              ; 1K
RING2_ROW  equ 20                 ; fixed row: repeat calls overwrite,
                                  ; not scroll

; Fill RING2_BASE..+RING2_LEN-1 with $A5. No screen output (RING2CHK,
; called right after, both confirms the fill and reports it). Corrupts
; AF, BC, DE, HL.
ring2_fill:
    ld hl, RING2_BASE
    ld de, RING2_BASE+1
    ld bc, RING2_LEN-1
    ld (hl), $A5
    ldir
    ret

; Scan RING2_BASE..+RING2_LEN-1 for the first byte != $A5. Prints "OK"
; on row RING2_ROW if the whole range is intact, else the mismatching
; address (4 hex digits) then a space then its byte (2 hex digits) on
; that same row. Corrupts everything (dbg_* helpers' own contract).
ring2_chk:
    ld b, RING2_ROW
    call dbg_at0
    ld hl, RING2_BASE
    ld bc, RING2_LEN
.loop:
    ld a, (hl)
    cp $A5
    jr nz, .bad
    inc hl
    dec bc
    ld a, b
    or c
    jr nz, .loop
    ld hl, .msgok
    jp dbg_puts
.bad:
    push af                     ; mismatching byte value (dbg_hex16
                                 ; below would corrupt it otherwise)
    call dbg_hex16              ; HL is still the mismatch address
    call dbg_space
    pop af
    jp dbg_hex8
.msgok: db "OK", 0

msgTitle:   db VERSION_STR, 0
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
objscan_tick:
    ret

; Release-build version stamp. boot_banner is already called
; unconditionally from main.asm (both builds, zero call-site cost) -
; here it prints VERSION_STR (nextdaad.inc, shared with the DEBUG
; msgTitle above so the two builds cannot drift apart) at row 0, col 0
; on the tilemap, then returns. This runs BEFORE main.asm's own
; txt_init call (which follows a successful DDB load), so txt_init is
; forced here first - the same pattern errors.asm's fatal() already
; relies on to make tm_putc_at safe this early in boot; re-running
; txt_init a second time later is harmless (same idempotent register/
; palette/font programming + full clear DEBUG already pays for once
; more via dbg_engage_tilemap). The game's first screen draw
; overwrites this shortly after - a startup stamp, not a persistent
; HUD; confirming the on-screen result is an owner eye leg, not
; headlessly testable. Corrupts everything.
;
; SP11 Task 1: after txt_init, a presence gate - probe for a staged
; DAAD.* title (title_present, overlay2.asm) and skip the print
; entirely when one exists, so the title is the first thing the player
; sees rather than a version stamp that the title art immediately
; covers anyway. Placed AFTER txt_init (not before it) so the early
; "ret nc" never skips it - fatal()'s own safety (the paragraph above)
; stays intact regardless of which way this gate goes. This file has no
; MMU directive (resident, always mapped), so the nextreg + call below
; are just two ordinary sequential instructions - unlike aud_boot_
; probe's tail (overlay1.asm), which has to route its own OVL2 handoff
; through a trampoline because it executes FROM WITHIN the very $E000
; window it remaps (see that file for why the two cases differ).
boot_banner:
    call txt_init
    nextreg NR_MMU7, OVL2_PAGE   ; probe DAAD.* presence - a game
    call title_present           ; shipping a title gets a clean boot
    ret nc                       ; (title becomes the first thing seen)
    ld a, (tmAttr)
    ld e, a
    ld bc, 0
    ld hl, msgRelTitle
.loop:
    ld a, (hl)
    or a
    jr z, .hold
    push hl
    call tm_putc_at
    pop hl
    inc hl
    inc c
    jr .loop
; SP11 owner polish: hold ~1 second (50 frames @ 50Hz) after the print
; so the stamp is actually readable before the boot flow's later steps
; wipe it, instead of flashing for a couple of milliseconds. IM2 is
; live by this point (im2_init runs at main.asm:20, boot_banner at
; :29), so frameCounter is ticking. Only reached past the title-
; presence gate above (ret nc) - a shipped title's boot stays instant,
; unaffected. Stack is balanced here (no pending push - the gate above
; is checked before this loop's own push hl). Corrupts everything,
; same contract as the rest of this routine; the caller (main.asm's
; ram_detect) makes no assumptions about incoming registers.
.hold:
    ld hl, (frameCounter)
    add hl, 50                  ; Z80N ADD HL,nn: byte-neutral vs
                                 ; ld de,50/add hl,de, -5T
    ex de, hl                   ; DE = target frameCounter value
.wait:
    ld hl, (frameCounter)
    or a                        ; clear carry before sbc
    sbc hl, de
    jr c, .wait                 ; frameCounter still short of target
    ret

msgRelTitle: db VERSION_STR, 0

ram_diag:
bank_selftest:
ddb_diag:
dbg_engage_tilemap:
    ret

 ENDIF

; Shape matches errors.asm's runtime messages: "NextDAAD: <what> - E<n>"
; (n = the ddb_load result code returned to main.asm, DDB_E_* in
; nextdaad.inc). Printed via fatal() -> fatal_puts (errors.asm) in both
; builds - see main.asm's ddb_load branch for which message pairs with
; which border colour/ERR_BORDER_*.
msgMissing:  db "NextDAAD: DDB missing - E1", 0
msgOversize: db "NextDAAD: DDB oversize - E2", 0
msgBadHdr:   db "NextDAAD: DDB bad header - E3", 0
; E4 is a WELL-FORMED database compiled for another target machine, which
; E3 used to swallow: version and DDB_MAGIC pass, so it reads as valid
; right up until the first pointer is rebased against the wrong load
; address. Separated because the two need opposite responses - E3 says
; recopy the file, E4 says recompile it for ZX.
msgWrongMach: db "NextDAAD: DDB wrong machine - E4", 0

dbgX: db 0
dbgY: db 0
