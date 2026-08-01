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

; SP14c batch B DBG5: same idea for aud_dmaprobe's "row N, column 10"
; sites. B = row 0-23. Only touches A.
dbg_atc10:
    ld c, 10
    jr dbg_at

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
    ; SP14c batch B DBG1: Z80N MUL D,E replaces the *8 shift chain
    ld e, a
    ld d, 8
    mul d, e
    ld hl, dbg_font
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
    ld e, 7*2                   ; pair 7: white ink (7) on black paper, always
    pop af
    call tm_putc_at
    ld a, (dbgX)
    inc a
    cp TM_COLS
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

SELFTEST_FREE_2MB equ 79    ; 14,15 + 35-47 + 48-111 (29 withdrawn for overlay
                            ; 2, 30-34 for the Layer 2 back surface)
SELFTEST_FREE_1MB equ 15    ; 14,15 + 35-47 (same withdrawals)

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
    ld b, 10
    call dbg_at0
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
    call bank_alloc         ; check 4: then bank 36 (29 withdrawn for
                            ; overlay 2, 30-34 for the L2 back surface)
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

; Frame-paced wait for T to be released, then pressed again (T-hook).
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
; SP14c batch B DBG6: B=row, D=height. Fills a TM_COLS-wide white-ink/
; black-paper, space-glyph bar - the exact 8-instruction sequence
; l2dbg_status/l2dbg_status2/l2_dbg_hook each repeated verbatim.
; Corrupts AF, BC, DE, HL (tm_fill_rect's own contract).
dbg_bar_white:
    ld c, 0
    ld e, TM_COLS
    ld a, 7*2                    ; pair 7: white ink on black paper
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
; l2_testcard): NR $14 (global transparency index, expect $FE), the
; Layer 2 clip window SHADOW (clipW= - overlay2's l2ClipX1/X2/Y1/Y2,
; NOT a hardware readback: NR $18 cannot be read back, see l2_clip_set),
; the scroll offset (NR $16/$17, expect $00 $00), and one live pixel
; read back from the drawn surface (l2_peek_marker - the top-left
; corner-marker byte). l2_dbg_hook re-asserts the clip window
; (l2_clip_set) right after this prints, as a guard. Corrupts
; everything.
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
    xor a                        ; re-assert the clip window after the
    call l2_clip_set             ; diagnostic, as a guard (l2dbg_status2)
    call l2dbg_wait_release
    call l2dbg_wait_press
    ld a, 1                      ; then 320x256
    call l2_testcard
    ld hl, msgTestcard320
    call l2dbg_status_regs
    call l2dbg_status2
    ld a, 1                      ; re-assert the clip window, same guard
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
    ld d, TM_ROWS
    call dbg_bar_white
    ret

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
;   Stage 2: + txt_init (tilemap on) + tm_clear_transparent over the
;            card area + one status line. 3 marker blocks.
;   Stage 3: the full testcard flow (as the T-hook's 256x192 leg,
;            including its register/clip-shadow dump).
; Each stage waits for P released then pressed before advancing. After
; stage 3 it wraps back to stage 0 rather than returning, so the ladder
; re-runs without a reset - a dead end by design, separate from the
; T-hook (l2_dbg_hook above). P not held: returns immediately, nothing
; touched.

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

; --- SP8 DMA prescaler probe (hold D at boot) ------------------------
; Measures what the zxnDMA prescaler actually counts. Transfers 8192
; bytes from resident RAM ($8000 - content irrelevant, expect a short
; noise burst) to the DAC in burst mode at two prescaler values and
; shows elapsed frames for each. Interpretation (28MHz CPU):
;   875kHz model: pre 87 -> 8192/(875000/87) = 0.81s = ~40-41 frames,
;                 pre 174 -> ~81 frames (double = linear confirm)
;   CPU-cycle model: both complete in 0-2 frames
; Polls the DMA byte counter via the WR6 $BB read mask; if the counter
; never advances the probe hangs with "DMA?" on screen - itself a
; result (CSpect not emulating the counter/prescaler).
; Never returns. Requires interrupts running (frameCounter).
aud_dmaprobe:
    ld b, 0
    call dbg_atc10
    ld hl, .msg
    call dbg_puts
    ld a, 87
    call .run                   ; HL = frames at prescaler 87
    push hl
    ld b, 1
    call dbg_atc10
    pop hl
    call dbg_hex16
    ld a, 174
    call .run
    push hl
    ld b, 2
    call dbg_atc10
    pop hl
    call dbg_hex16
.hang:
    jr .hang
.msg:
    db "DMAPROBE", 0
; A = prescaler. Out HL = elapsed frames. Corrupts everything.
.run:
    ld (.pre), a
    ld hl, (frameCounter)
    ld (.t0), hl
    ld hl, .prog
    ld b, .proglen
    ld c, DMA_PORT
    otir
.poll:
    ; read byte counter: WR6 read-mask command, mask = counter lo+hi
    ld a, $BB
    ld bc, DMA_PORT
    out (c), a
    ld a, %00000110
    out (c), a
    in a, (c)                   ; byte counter low
    ld e, a
    in a, (c)                   ; byte counter high
    ld d, a
    ld hl, 8192-2               ; near-complete threshold (end-of-
    or a                        ; block exact value is model-dependent)
    sbc hl, de
    jr nc, .poll
    ld hl, (frameCounter)
    ld de, (.t0)
    or a
    sbc hl, de
    ret
.t0: dw 0
.prog:
    db $83                      ; WR6: disable DMA
    db %01111101                ; WR0: transfer, A->B, A addr + len follow
    dw $8000                    ; port A: resident RAM (junk audio)
    dw 8192                     ; block length
    db %01010100                ; WR1: A = memory, incrementing, timing follows
    db %00000010                ; A cycle length 2
    db %01101000                ; WR2: B = IO, fixed, timing follows
    db %00100010                ; B cycle length 2 + prescaler follows
.pre:
    db 87                       ; prescaler (patched per run)
    db $CD                      ; WR4: burst mode, B addr follows
    dw DAC_PORT                 ; port B: DAC
    db %10000010                ; WR5 $82: /ce only, stop on end of
                                ; block ($92 would set D4, the doc's
                                ; unclear /ce+wait mux mode)
    db $CF                      ; WR6: load
    db $87                      ; WR6: enable
.proglen equ $ - .prog

dbg_font:
    INCBIN "../tools/DAAD-READY/ASSETS/CHARSET/AD8x8.CHR"   ; 2048 bytes, 256 glyphs

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

dbgX: db 0
dbgY: db 0
