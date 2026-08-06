; NextDAAD code overlay 2 (8K page 58 -> MMU slot 7 at $E000).
; Layer 2 bring-up: mode select, enable/disable, clear-to-transparent,
; palette load, and (DEBUG only) a hardware bring-up test card.
; Reached only via the engine dispatcher (cdisp page byte) or the
; DEBUG boot hook (debug.asm). Calls RESIDENT services only - never
; overlay0/overlay1.
;
; Register recipes below are cited against docs/zx-next-dev-guide-
; 2022-07-15/chapter-next-layer2.tex (section "Layer 2 Registers") and
; chapter-next-palette.tex, cross-checked against the guide's own
; samples/layer2-256x192 and samples/layer2-320x256 example code.

    MMU 7, OVL2_PAGE, OVL_ORG

; condition result helpers (CF contract, local to this overlay)
ovl2_true:
    or a
    ret
ovl2_false:
    scf
    ret

; --- mode / enable / disable ---

; A = 0 (256x192 256-colour) or 1 (320x256 256-colour) on entry.
; Programs the resolution (NR $70 bits 5-4, guide 728-744: 00 =
; 256x192, 01 = 320x256), the Layer 2 start bank (NR $12, guide
; 586-599: 16K units, guide line 41 "only use 16K banks 9 or
; greater") from l2FrontBank - the double-buffer flip (l2_flip_swap)
; swaps the surface roles FIRST and then calls here, so the
; resolution and the new front bank land back-to-back (see
; l2_flip_swap's header for the glitch-window math) - and the global
; transparent colour (NR $14 = TM_TRANSP_ATTR): with Layer 2 on top
; (l2_enable) a pixel whose palette output equals this colour falls
; through to the tilemap/ULA below, so the L2 recipe sets it itself.
; txt_init programs the same register/value for the tilemap - shared,
; harmless, last writer wins with an identical value. Then the clip
; window and scroll offset via l2_clip_set. Remembers the mode in
; l2Mode for l2_clear/l2_testcard. Corrupts AF.
l2_mode_set:
    ld (l2Mode), a
    push af
    or a
    jr z, .m256
    ld a, %00010000              ; NR $70: bits5-4=01 (320x256, 8bpp)
    jr .set
.m256:
    xor a                        ; NR $70: bits5-4=00 (256x192, 8bpp)
.set:
    nextreg NR_L2_CTRL, a
    ld a, (l2FrontBank)
    nextreg NR_L2_BANK, a
    nextreg NR_L2_TRANSP, TM_TRANSP_ATTR
    pop af
    jp l2_clip_set                ; also zeroes the scroll offset, then ret

; A = 0/1 as above. Programs the Layer 2 clip window (NR $1C index
; reset + 4x NR $18: X1,X2,Y1,Y2, guide 650-669) and zeroes the scroll
; offset (NR $16/$17, guide 623-639). Split from l2_mode_set so the
; DEBUG flow can re-assert the window after its diagnostic runs.
; Mirrors what it writes into l2ClipX1/X2/Y1/Y2 as a software shadow:
; NR $18 cannot be read back for a diagnostic - per wiki.specnext.dev/
; NextReg:$18 a WRITE auto-increments the index (guide 658) but a READ
; does not - so the shadow is the only reliable source of the window
; state. Corrupts AF.
l2_clip_set:
    ; X1/Y1 are always 0; X2/Y2 depend on the mode in A. Fill the shadow,
    ; then program the hardware from it - one shared write sequence.
    or a
    jr nz, .m320
    ld a, 255                     ; 256x192: X2 = 255
    ld (l2ClipX2), a
    ld a, 191                     ; Y2 = 191
    ld (l2ClipY2), a
    jr .prog
.m320:
    ld a, 159                     ; 320x256: X2 = 159 (X in 2-pixel units)
    ld (l2ClipX2), a
    ld a, 255                     ; Y2 = 255
    ld (l2ClipY2), a
.prog:
    xor a
    ld (l2ClipX1), a
    ld (l2ClipY1), a
    nextreg NR_CLIP_IDX, 1        ; bit0: reset the Layer 2 clip index
    nextreg NR_L2_CLIP, 0         ; X1
    ld a, (l2ClipX2)
    nextreg NR_L2_CLIP, a         ; X2
    nextreg NR_L2_CLIP, 0         ; Y1
    ld a, (l2ClipY2)
    nextreg NR_L2_CLIP, a         ; Y2
    ; NR $16/$17: X/Y pixel scroll offset (guide 623-639), zeroed so a
    ; stale offset can't shift/wrap the image.
    nextreg NR_L2_XOFS, 0
    nextreg NR_L2_YOFS, 0
    ret

l2ClipX1: db 0
l2ClipX2: db 0
l2ClipY1: db 0
l2ClipY2: db 0

; Enable Layer 2 display (NR $69 bit 7, guide 713-723) via read-modify-
; write, so bits 6-0 (ULA shadow / Timex video-mode aliases, all 0 from
; hw_init) are left undisturbed. NR $69 is used rather than the $123B
; I/O port because a bare `LD A,2 / OUT ($123B)` also zeroes that port's
; other live bits (video-RAM bank select, shadow select, CPU paging)
; every write, which leaves Layer 2 invisible.
;
; Sets the S/L/U layer priority (NR $15 bits 4-2) to %000 - per wiki.
; specnext.dev/NextReg:$15 (matches the local guide verbatim), %000 is
; "S L U": Sprites top, Layer 2 under sprites, Enhanced ULA at bottom -
; i.e. Layer 2 ABOVE the tilemap/ULA slot. (%110/%111 are blend modes,
; unused.) Only correct together with l2_mode_set's NR $14 transparent
; fill: without it, Layer 2 on top would hide the tilemap text instead
; of letting it show through. Corrupts AF, E (nr_read preserves BC;
; only the ld e register-select setup touches DE).
l2_enable:
    ld e, NR_DISPLAY_CTRL
    call nr_read
    or %10000000                 ; bit7: enable Layer 2
    nextreg NR_DISPLAY_CTRL, a
    nextreg NR_LAYERS, %00000000 ; bits4-2=000 "S L U": Layer 2 above
                                  ; the tilemap/ULA slot
    ret

; Disable Layer 2 display (NR $69 bit 7 = 0, other bits preserved).
; Layer priority (NR $15) is left as l2_enable set it - harmless,
; since with Layer 2 invisible the S/L/U order has nothing to
; prioritise. Corrupts AF, E (nr_read preserves BC; only the ld e
; register-select setup touches DE).
l2_disable:
    ld e, NR_DISPLAY_CTRL
    call nr_read
    and %01111111
    nextreg NR_DISPLAY_CTRL, a
    ret

; Fill a Layer 2 surface with the current NR $14 transparent colour
; (guide 616-620) - read back rather than assumed, though l2_mode_set
; always programs it to TM_TRANSP_ATTR first. With Layer 2 on top
; (l2_enable) a pixel whose palette output equals that colour lets the
; tilemap/ULA below show through. Page count per l2Mode: 256x192 = 6 x
; 8K pages, 320x256 = 10 x 8K pages (guide 160/306). A flat memset
; works for both regardless of the row-/column-major layout, since
; every byte gets the same value. Brackets the remap with data_save/
; data_restore so slot 6 is left as the caller found it. Three entry
; points - all corrupt AF, BC, DE, HL:
;   l2_clear      - the FRONT (displayed) surface: DEBUG diagnostics,
;                   which have no flip step;
;   l2_clear_back - the BACK (render target) surface: gfx_blit's
;                   pre-clear and h_display's instant clear, both
;                   invisible until the flip;
;   l2_clear_at   - A = first 8K page of any surface (internal).
l2_clear:
    ld a, (l2FrontBank)
    add a, a
    jr l2_clear_at
l2_clear_back:
    ld a, (l2BackBank)
    add a, a
l2_clear_at:
    ld (l2PageCur), a
    call data_save
    ld e, NR_L2_TRANSP
    call nr_read
    ld (l2FillByte), a
    ld a, (l2Mode)
    or a
    jr nz, .m320
    ld a, 6
    jr .cnt
.m320:
    ld a, 10
.cnt:
    ld (l2PageCnt), a
.loop:
    ld a, (l2PageCur)
    call data_map_page
    ld hl, DATA_WINDOW
    ld a, (l2FillByte)
    ld (hl), a
    ld de, DATA_WINDOW+1
    ld bc, 8191
    ldir
    ld hl, l2PageCur
    inc (hl)
    ld hl, l2PageCnt
    dec (hl)
    jr nz, .loop
    call data_restore
    ret

; HL = source (resident or already-banked) palette data, B = format:
; 0 = 256 x 1-byte 8-bit RRRGGGBB entries (NR $41, guide 152-179);
; 1 = 256 x 2-byte 9-bit entries (NR $44, guide 236-284: first byte
; RRRGGGBB, second byte bit0 = extra blue bit / bit7 = L2 priority).
; Programs the Layer 2 FIRST palette (NR $43 = PAL_L2_FIRST selects it
; for edit and as the active display palette, auto-increment on,
; guide 203-230), index reset to 0 (NR $40 = 0). Corrupts AF, BC, HL.
;
; Transparency invariant: NR $14 transparency is a COLOUR compare, not
; an index compare - the hardware matches each Layer 2 pixel's final
; RRRGGGBB palette output against the register (wiki.specnext.dev/
; NextReg:$14 "Global Transparency", and guide chapter-next-layer2.tex
; line 71 "transparent colour of Layer 2"; the guide's register table
; at line 619 says "index", but the owner's milestone run proved the
; colour reading: all 21 Rabenstein NX2 palettes map entry 254 to
; black, and the $FE surface fill rendered opaque black over the text
; rows). So a loaded palette must reserve one colour for punch-through:
; - copy loops dodge collisions: any entry whose FIRST byte equals
;   TM_TRANSP_ATTR ($FE) is written as $FF instead - one blue LSB off,
;   imperceptible; only the RRRGGGBB byte is compared, so dodging it
;   suffices (the 9-bit second byte passes through as supplied). Art
;   scan: 3/12/13.NX2 each carry one $FE-coloured entry that would
;   otherwise punch unintended holes;
; - entry 254 is then stamped $FE via the 9-bit pair (NR $44 = $FE,
;   then 0: blue LSB 0, priority 0 - chosen over an NR $41 write so
;   the priority bit is explicitly cleared), making index 254 the ONLY
;   transparent entry after ANY l2_palette_load. No Rabenstein art
;   uses pixel value $FE, so reserving the index costs nothing; the
;   DEBUG test card's identity palette already satisfied the invariant.
l2_palette_load:
    ld a, b
    push af
    nextreg NR_PAL_CTRL, PAL_L2_FIRST
    nextreg NR_PAL_INDEX, 0
    pop af
    or a
    jr nz, .fmt9
    ld b, 0                      ; B=0 -> djnz runs 256 times
.l8:
    ld a, (hl)
    inc hl
    cp TM_TRANSP_ATTR            ; colour collision with the reserved
    jr nz, .w8                   ; transparent colour: dodge to $FF
    ld a, $FF
.w8:
    nextreg NR_PAL_VALUE, a
    djnz .l8
    jr l2_pal9_stamp
.fmt9:
    ld b, 0
    call l2_pal9_run
    ; fall through to the stamp

; Force entry 254 = the reserved transparent colour (l2_palette_load
; header). Every palette-programming path ends here. Corrupts AF.
l2_pal9_stamp:
    nextreg NR_PAL_INDEX, TM_TRANSP_ATTR
    nextreg NR_PAL_VALUE9, TM_TRANSP_ATTR
    nextreg NR_PAL_VALUE9, 0     ; blue LSB 0, priority 0
    ret

; Program B 9-bit palette entries (0 = 256) from HL via NR $44, with
; the $FE collision dodge (l2_palette_load header). The caller owns
; the NR $43/$40 setup and the final l2_pal9_stamp - split out so
; gfx_direct_stream can feed the 512-byte palette through gfxRowBuf
; in two 256-byte halves. Corrupts AF, B, HL.
l2_pal9_run:
.l9:
    ld a, (hl)
    inc hl
    cp TM_TRANSP_ATTR            ; dodge the RRRGGGBB byte only - the
    jr nz, .w9                   ; compare ignores the second byte
    ld a, $FF
.w9:
    nextreg NR_PAL_VALUE9, a
    ld a, (hl)
    inc hl
    nextreg NR_PAL_VALUE9, a
    djnz .l9
    ret

l2Mode:     db 0                 ; last mode set by l2_mode_set
l2FillByte: db 0
l2PageCur:  db 0
l2PageCnt:  db 0

; --- picture loader / blitter / PICTURE / DISPLAY (Tasks 4+5) ---
; File format (Gfx2Next -pal-embed): 512-byte palette (256 x 2-byte
; 9-bit entries, NR $44 order) followed by width*height pixel bytes,
; emitted row by row. NNN.NX2 = 320 wide, NNN.NXI = 256 wide; the
; height is whatever the file size says: (size - 512) / width.
;
; Gfx2Next invocations (tools/gfx2next; source must be an 8-bit
; paletted PNG/BMP of the target width):
;   raw:        gfx2next -bitmap -pal-embed pic.png N.NX2   (320 wide)
;               gfx2next -bitmap -pal-embed pic.png N.NXI   (256 wide)
;   compressed: add -zx0 to either - Gfx2Next then APPENDS ".zx0" to
;               the given output name (N.NX2 -> N.NX2.zx0), hence the
;               double extension the probe chain tries first. Verified
;               against gfx2next.exe: the -zx0 -pal-embed output is TWO
;               sequential self-terminating ZX0 streams, palette (512
;               bytes decompressed) then pixels.
; A whole raw file compressed in one pass (tools/z88dk/bin/z88dk-zx0
; NNN.NX2 NNN.NX2.ZX0 - what build-tests.ps1 -GfxZx0 stages) is ONE
; stream; gfx_depack accepts both by depacking streams back to back
; until the compressed input is exhausted. Either way the decompressed
; bytes are identical to the raw file, so everything downstream of the
; load (gfx_derive_height, gfx_blit, l2_palette_load) is unchanged.

GFX_SRC_END equ DATA_WINDOW+$2000   ; first address past the slot 6 window

; 84 PICTURE (condition): stage picture B for a later DISPLAY 0.
; Semantics pinned against jdaad _PICTURE (jdaad.js 3505-3529): it
; stages only - "imageBufferID = Parameter1" on success, nothing is
; drawn; a missing image clears the stage ("imageBufferID = false")
; and fails the condition (condactResult = false). CF mirrors
; condactResult through ovl2_false. jdaad's fallback probe of
; jDAADSounds is not carried over - sampled SFX are a separate
; subsystem here. Corrupts everything.
;
; PICTURE MARKS THE TABLE DONE ON EVERY EXIT (owner ruling 2026-08-04).
; Both references do it unconditionally: msx2daad's condactList row is
; { do_PICTURE, 1 } and the dispatcher runs "isDone |= ce->flag" after
; EVERY handler (daad_condacts.c:44,204); jdaad's _PICTURE (jdaad.js
; :3505) ends with a trailing "done = true" at :3528, reached on all
; three of its branches. NextDAAD marked it NOWHERE - ovl2_true/ovl2_false
; touch carry only, and cprops row 84 is condition-typed so the
; dispatcher stamps nothing either.
;
; The row STAYS condition-typed. Bit 7 would also make the dispatcher
; ignore this handler's CF, which is what fails the entry when no
; loadable art exists - the half that deliberately matches jdaad. So
; the stamp is made here instead, at ENTRY: gfx_load returns by RET on
; every path (no error longjmp - see its own header), so entry and
; "every exit path" are the same set, and one call covers both. Legal
; from overlay2 because eng_set_done is RESIDENT (engine.asm, $8000-
; $BA00, mapped in slots 4/5 at all times); this overlay already calls
; resident services (data_save, bank_alloc, bank_free). eng_set_done
; corrupts A only, so B - the picture number - survives it.
h_picture:
    call eng_set_done
    ld a, b
    call gfx_load
    jp c, ovl2_false
    jp ovl2_true

; Swap the front/back Layer 2 surface roles - VARIABLES ONLY, no
; hardware write. The caller owns the NR $12 update: gfx_blit swaps
; and then calls l2_mode_set, so the resolution (NR $70) and the new
; front bank (NR $12) land back-to-back - two nextreg writes one
; register load apart, ~40 T-states = ~1.4us at 28MHz, so the worst
; case is the raster catching a sub-scanline sliver of the old
; surface in the new mode (one scanline is 64us), versus a full frame
; of wrong-mode flash if either register changed alone with the other
; waiting a frame; h_display's clear path writes NR $12
; directly (no mode change, no window at all). Corrupts AF, B.
l2_flip_swap:
    ld a, (l2FrontBank)
    ld b, a
    ld a, (l2BackBank)
    ld (l2FrontBank), a
    ld a, b
    ld (l2BackBank), a
    ret

; --- DMA-accelerated block copy (SP11 Task 2) ---
; HL = source, DE = dest, BC = length - all three within the currently-
; mapped windows (the zxnDMA reads the LIVE Z80 MMU map, exactly like a
; CPU access would).
;
; HAZARD: the frame ISR's full-context path (audEnable != 0 - sticky
; once set, so effectively true for the whole session after the first
; note of boot music) saves and REMAPS MMU6/7 around aud_tick
; (interrupts.asm) to reach the audio banks, then restores them before
; it returns. A DMA transfer left running across that tick would
; therefore run through the AUDIO banks' mapping instead of the
; caller's - corrupting the picture and trashing audio state. LDIR was
; immune (the CPU simply suspends mid-instruction; the ISR restores the
; map before LDIR resumes on the far side).
;
; THAT HAZARD IS NOW CLOSED BY HARDWARE, NOT BY A DI (2026-08-03).
; im2_init writes nextreg $CC = 0, which forbids the ULA frame interrupt
; (and the line interrupt) from EVER interrupting a running DMA, and
; nextreg $CD = %00000001, which admits exactly one source: CTC channel
; 0, the DAC sample timer, whose ISR is MMU-free by explicit contract.
; So the mapping a transfer was armed with is the mapping it finishes
; under, and the per-chunk di/ei that used to enforce that is DELETED.
; Every chunk is still a one-shot CONTINUOUS transfer: continuous holds
; the bus to completion (no burst hand-back) and completion is IMPLICIT
; - the final OUT (dma_prog's WR6 enable byte) does not return to the
; next instruction until the whole chunk has transferred, so there is no
; status poll anywhere. NEVER: burst mode, auto-restart, a live counter
; read, or a refeed while enabled.
;
; WHY THE DI HAD TO GO, AND WHY IT WAS NEVER THE GOVERNING QUANTITY.
; CONTINUOUS mode "runs to completion without allowing the CPU to run"
; (dev guide chapter-next-dma.tex WR4 bits 6-5; tools/NextZXOS/docs/
; extra-hw/dma/zxndma.txt). The CPU is BUS-STALLED for the whole
; transfer, so the window in which ctc_isr cannot reach the DAC was
; never the di/ei pair - it was A + r*chunk, of which the DI was only
; the ~219 T arm upload. Hardware IM2 CACHES a held request rather than
; losing it, so nothing was ever dropped and the PITCH was always exact;
; what the delay does is stretch one step of the reconstruction
; staircase and shorten the next, and that is an in-band error pulse.
; The owner heard it as gross distortion on tests/sfxdi.dsf, at constant
; pitch, on every leg - which is why four rounds of shortening the
; bracket never fixed it and why chunk size is no longer the knob.
; Confirmed on silicon 2026-08-03 (real Next, HDMI): this build stayed
; CLEAN through a forty-call GFX 0 0 burst under a 16 kHz effect, and an
; independent build with the DMA replaced by LDIR was clean too.
;
; PROVENANCE NOTE ON THE TRANSFER RATE r. The clean 16 kHz leg bounds
; the blocking window below one HDMI period, W(256) = A + 256r < 1680 T
; with A = 603 T, hence r < 4.21 T/byte on THIS path - the RTL-nominal
; 4 T/B for 2+2 cycle timing, not the 5.082 T/B fitted from the video
; kernels (those write Layer 2 and pay its auto-slowdown; dma_copy moves
; through an MMU window and does not). A stopwatch cross-check on the
; same run put a GFX 0 0 at roughly 25 ms against the ~44.5 ms the
; 5.082 figure predicts, which agrees. BOTH ARE BOUNDS, NOT FITS: every
; figure below is still quoted at 5.082 T/B, deliberately, because
; nothing is to be re-fitted on an ear-and-stopwatch reading. A proper
; re-fit needs a bench row with the CTC armed at a sample-engine TC
; (REDERIVATION.md recommendation #7).
;
; Chunks are capped at DMA_CHUNK_MAX. THE COST MODEL, HAND-COUNTED -
; still the right arithmetic for how LONG a chunk takes, now that it is
; no longer the arithmetic of a deadline. The figure for this path had
; been wrong four times ("roughly 1.1k T-states", SP14c T4's 1379 T, the
; 2026-08-02 re-derivation's 1802 T, this header's own ~1871 T) before
; it was re-counted; nothing below is inherited except ONE named
; measured constant, and that one reconciles against two shipped arms.
;
;     W(chunk) = A + 5.082 * chunk
;       5.082 T/B is the zxnDMA 2/2-cycle rate FITTED FROM THE VIDEO
;       KERNELS at 28 MHz (REDERIVATION.md 2.2). It is an upper bound
;       here - see the provenance note above, r < 4.21 T/B on this path
;       - and is kept deliberately, because a pessimistic cost model is
;       the safe direction and nothing is to be re-fitted on an ear.
;     A = (arm upload) + 183 T of zxnDMA disable/load/enable sequencing
;       latency, which elapses between the $CF load byte and transfer
;       completion. The 183 T is the one inherited quantity: A(video,
;       13-byte OTIR arm) = 500 +/- 20 T (REDERIVATION.md 2.2b,
;       four-point inversion of the bench tick-shortfall table) minus
;       that arm's own 317 T of code. It reproduces the SHIPPED video
;       fix's published A for BOTH its arms to the T - copy
;       5+11*19+5+183 = 402, fill 5+13*19+5+183 = 440 - so it is not a
;       free parameter here.
;     28 MHz rule (docs/Z80/01-instruction-timing.md): +1 T on every
;       opcode fetch and every memory read, none on I/O or writes.
;       OTIR = 24 T/byte repeating, 19 T final; OUTINB (Z80N ED 90) is
;       a flat 19 T/byte.
;
;     16-byte OTIR arm (before 4cda75e)   A = 603 T
;     11-byte OUTINB arm (now)            A = 402 T
;       W(128) = 402 + 650.5  = 1052.5 T (37.6 us)
;       W(256) = 402 + 1301.0 = 1703.0 T (60.8 us)
;
; WHAT THE PERIOD TABLE IS NOW FOR. ctc_isr feeds the DAC one byte per
; CTC zero-count; the period is 16 * TC T-states EXACTLY (the CTC input
; clock and the CPU clock are the same FPGA system clock, so this is
; clock-independent), with TC = floor(clk16/rate) from aud_ctc_params /
; aud_clk16_tab (overlay1):
;
;     rate       VGA0  VGA1  VGA2  VGA3  VGA4  VGA5  VGA6  HDMI
;     16000 Hz   1744  1776  1840  1872  1936  2000  2048  1680
;     20000 Hz   1392  1424  1472  1488  1536  1600  1648  1344
;
; 16000 Hz is the only rate this project has ever shipped (the kit's
; AUDIO/001.wav, the runbook's 002.WAV - aud_load_wav takes the rate
; verbatim from the WAV header and nothing in the pipeline resamples),
; and 20000 Hz = AUD_RATE_MAX is what README/SETUP.md publish as
; supported and what a DAAD-DOS SOUNDS set drops in at. THE INHERITED
; "1400 T" DEADLINE CORRESPONDED TO NEITHER: it assumed a flat 28 MHz
; and ignored both the TC floor and HDMI's 27 MHz clock.
;
; W VS P IS NO LONGER A CONSTRAINT AT ALL. It used to be read as "a
; chunk longer than one period costs a tick", and the whole 2026-08-03
; cap fit was built on it. That is retired: the pre-emption permission
; means the DAC feed is serviced INSIDE the transfer, so W may exceed P
; freely - a longer chunk simply admits more CTC edges, each of which is
; taken on time. The table stays because the period is still the right
; scale for reasoning about the path, not because anything must fit
; under it.
;
; NOTHING WAS EVER LOST OR CLICKED. The producer is consumption-paced
; (aud_smp_copy fills only the ring's free space), so it cannot lap the
; consumer, and hardware IM2 holds a request raised during a stall
; instead of losing it - so the sample COUNT, and therefore the pitch,
; were always exact. The defect was purely one of OUTPUT TIMING: each
; blocking window delayed one DAC update by a large fraction of a sample
; period and the next one caught up. That is inaudible to every
; automated check and invisible to every pitch-based model, which is
; exactly how it survived from SP11 to 2026-08-03 and why the first
; three explanations of it were all wrong.
;
; WHY THE CAP IS 256 AGAIN. It was cut to 128 earlier the same day to
; shorten the blocking window, on the model that a window longer than
; one CTC period cost a tick. That model is dead (see above): the DAC
; feed is now serviced INSIDE the transfer, so the window's length no
; longer buys anything and the 128 was pure cost. Both callers hand this
; routine exactly 256 bytes, so 256 makes every call ONE chunk instead
; of two, saving per call one arm upload (209 T), one zxnDMA sequencing
; residual (183 T) and one pass of the loop glue (~390 T) - about 780 T,
; or 27.9 us at 28 MHz. On the model that priced cap 128 at DISPLAY 0
; 66.8 ms and GFX 0/1 42.9 ms (256x192) / 71.5 ms (320x256):
;
;     DISPLAY 0, 256-wide art   192 calls   -5.4 ms  ->  61.4 ms
;     GFX 0/1, 256x192          384 calls  -10.7 ms  ->  32.2 ms
;     GFX 0/1, 320x256          640 calls  -17.8 ms  ->  53.7 ms
;
; and all three are UPPER bounds, because the model still prices the
; transfer at 5.082 T/B where silicon bounds this path under 4.21.
; 320-wide LOCATION art is untouched either way: gfx_blit routes it to
; gfx_row_scatter320, a CPU column scatter that never had a DMA branch
; (see its own header). The owner's ruling that made the 128 acceptable
; - "for sampled sound effects and location picture drawing the audio
; quality shouldn't suffer for a slight slow down in picture drawing" -
; no longer has to be spent: the audio is fixed AND the draw is faster.
;
; ANY CAP IN 1..256 IS NOW LEGAL, and that is deliberate. The routine
; used to hard-wire 256 by setting alen's low byte to 0 and its high
; byte to `high DMA_CHUNK_MAX`, which is ZERO for every cap below 256 -
; a zero-length block and a dead transfer - and its dispatch test ("B
; != 0, so remaining > 255, so chunk = 256") was wrong for a sub-256 cap
; too. The 2026-08-03 rewrite made the selection a general
; chunk = min(BC, cap) but paid for it with an alen high byte pinned to
; a constant 0, which barred 256. The form below is general in BOTH
; directions: one 16-bit compare, one 16-bit store, cap free anywhere
; in 1..256, three bytes dearer than the byte-wise version it replaces.
; NEITHER TRAP MAY RETURN. If a future change wants a different cap it
; is now genuinely a one-constant edit, and the ASSERTs enforce it.
;
; DESCRIPTOR SPLIT (2026-08-03), the same treatment the video kernels
; took in 446f33d. dma_prog's five STATIC bytes (the WR1 pair, the WR2
; pair, WR5) left the per-chunk arm for dma_prog_static, sent ONCE PER
; CALL at the top of this routine WITH INTERRUPTS LIVE - the DMA is
; idle there (WR5 = stop on end of block), so those are register
; writes, not a transfer; it is exactly the idiom vid_fill_dma uses to
; restore WR1 after its own bracket. PER-CALL, NEVER A SESSION INIT: a
; session init would make this overlay depend on video-player state and
; would break the invariant recorded at video.asm:1517 (the descriptors
; outside the video kernel leave WR1 = INCREMENTING). As written that
; invariant HOLDS - dma_copy sends WR1 = INCREMENTING on entry to every
; call and never departs from it, so WR1 is INCREMENTING both during
; and after any dma_copy, on every exit path. No state cell, no
; cross-module coupling, no runtime test.
;
; INTERRUPTS ARE LIVE THROUGHOUT, including across the transfer itself.
; ctc_isr is admitted mid-chunk by $CD bit 0 and services the DAC on
; time; a pending frame tick is held by $CC = 0 until the chunk ends and
; then runs with the DMA idle, exactly as it did between chunks before.
; ONE CONSEQUENCE TO KNOW ABOUT (dev guide, Alvin Albrecht): when the
; DMA yields for an interrupt the CPU executes ONE mainline instruction
; before the interrupt is seen, and RETI returns the bus to the DMA. The
; instruction that follows the arm here is `pop bc`, then pointer
; arithmetic that only reads dma_prog's own already-loaded fields - so a
; slip costs nothing. It would only matter if enough edges landed in one
; chunk to walk the mainline back round to .loop, where dma_prog is
; re-patched and re-armed; at the shipped rates a chunk sees at most one
; or two. Anything that shortens the tail below the arm, or moves a DMA
; write earlier, must be re-checked against that.
;
; Splits BC into <=DMA_CHUNK_MAX-byte chunks and loops; returns once the
; whole length has transferred. Corrupts AF, BC, DE, HL - matches LDIR's
; own end state exactly (HL/DE left just past the last byte moved,
; BC = 0), so it drops into any LDIR call site with no other change
; needed.
;
; Unconditional since SP14a T4's follow-up wave (was IFDEF DMA_GFX,
; A/B against a -NoDmaGfx CPU-only LDIR fallback) - the owner's DMA-
; during-samples question closed 2026-07-21 (real hardware, kit Release
; build: location-art DMA blit mid-sample-playback, clean draw), so
; -NoDmaGfx and its fallback retired together (build.ps1, and every
; call site below).

; Arm/prefix lengths as assembly-time constants: the DUP counts need
; them before the blocks exist. The ASSERTs after the blocks pin them to
; the real lengths, so an edit that forgets an unroll count fails the
; build instead of desyncing the DMA (video.asm's kernels, same shape).
DMA_ARM_LEN     equ 11           ; per-chunk arm (program + run)
DMA_STATIC_LEN  equ 5            ; per-call prefix (port modes + stop)
    ASSERT DMA_CHUNK_MAX >= 1    ; chunk = min(BC, cap): a zero cap would
                                  ; loop forever programming empty blocks
    ASSERT DMA_CHUNK_MAX <= 256  ; the arm's block length is a 16-bit
                                  ; field written whole, so the cap is
                                  ; free anywhere in 1..256 - including
                                  ; exactly 256, which the byte-wise
                                  ; selection this replaced could not
                                  ; express (see the header)
dma_copy:
    push hl                      ; THE CALLER'S SOURCE POINTER AND LENGTH
    push bc                      ; MUST SURVIVE THE PREFIX BELOW, which
                                  ; needs HL and BC for its own OUTINB
                                  ; stream. Omitting this pair is the
                                  ; 2026-08-03 regression (4cda75e): .loop
                                  ; then read HL = dma_prog and BC = $006B
                                  ; = DMA_PORT as its source and length, so
                                  ; every call copied 107 bytes of this
                                  ; overlay's own code instead of the
                                  ; caller's buffer AND returned DE only
                                  ; 107 further on. gfx_row_copy256 walks
                                  ; its destination by that returned DE, so
                                  ; the 256-wide picture blit marched past
                                  ; the slot 6 window and wrote 47 bytes
                                  ; over $E000 - overlay2's own entry, live
                                  ; in slot 7 - on row 76 of every draw.
    ld hl, dma_prog_static       ; per-call descriptor prefix, INTERRUPTS
    ld bc, DMA_PORT              ; LIVE (see header): the DMA is idle, so
    DUP DMA_STATIC_LEN           ; WR1/WR2/WR5 are plain register writes.
      outinb                     ; B is OUTINB's spare (address high byte
    EDUP                         ; only - $6B decodes on the low byte)
    pop bc                       ; back to the caller's length ...
    pop hl                       ; ... and source; DE was never touched
.loop:
    ld a, b
    or c
    ret z                        ; BC == 0: entire length transferred.
                                  ; `or c` also clears CF for the sbc
    push hl                      ; HL doubles as the 16-bit compare
    ld hl, DMA_CHUNK_MAX         ; scratch - the source pointer comes
    sbc hl, bc                   ; straight back below. CF <=> cap <
    ld hl, DMA_CHUNK_MAX         ; remaining, i.e. take the whole cap
    jr c, .len
    ld h, b
    ld l, c                      ; else chunk = remaining: the tail
.len:
    ld (dma_prog.alen), hl       ; chunk length, BOTH bytes - which is
    pop hl                       ; what makes a cap of exactly 256
                                  ; expressible; the tail below reads the
                                  ; same pair back as one ld de,(nn)
    ld (dma_prog.aaddr), hl      ; this chunk's source start
    ld (dma_prog.baddr), de      ; this chunk's dest start
    push bc                      ; only BC needs saving across the arm
                                  ; upload (BC carries the port); HL/DE
                                  ; are rebuilt below from dma_prog's own
                                  ; fields, which the upload only reads,
                                  ; never writes
    ld hl, dma_prog              ; INTERRUPTS STAY LIVE ACROSS THE ARM
    ld bc, DMA_PORT              ; (2026-08-03): the frame ISR is barred
                                  ; from a running DMA by nextreg $CC = 0
                                  ; and the DAC feed is deliberately let
                                  ; in by $CD bit 0 - see the header and
                                  ; im2_init
    DUP DMA_ARM_LEN
      outinb                     ; program + run to completion - the $87
    EDUP                          ; enable is the last byte and does not
                                  ; return until the chunk has moved
    pop bc
    ld h, b
    ld l, c                      ; HL = remaining length (pre-chunk)
    ld de, (dma_prog.alen)       ; DE = chunk length just transferred
    or a
    sbc hl, de                   ; HL = remaining length (post-chunk)
    ld b, h
    ld c, l                      ; BC = remaining length (post-chunk)
    ld hl, (dma_prog.aaddr)      ; HL = this chunk's source start
    add hl, de                   ; HL = next chunk's source start
    push hl
    ld hl, (dma_prog.baddr)      ; HL = this chunk's dest start
    add hl, de                   ; HL = next chunk's dest start
    ex de, hl                    ; DE = next chunk's dest start
    pop hl                       ; HL = next chunk's source start
    jp .loop

; zxnDMA one-shot program: mem-to-mem, port A (source) -> port B (dest),
; both memory/incrementing, CONTINUOUS mode, stop on end of block - no
; auto-restart, ever (WR5). SPLIT 2026-08-03 (see dma_copy's header):
; the five STATIC bytes are dma_prog_static, sent once per CALL with
; interrupts live; dma_prog below is the 11-byte per-CHUNK arm, the only
; thing re-sent per chunk. .aaddr/.alen/.baddr are patched in place
; first, each chunk.
;
; Bytes verified against docs/Z80_DMA_Chip__ps0179.pdf's WR0/WR1/WR2/
; WR4/WR5/WR6 bit tables (the PDF is scan-only in this checkout, no
; extractable text - cross-checked instead via tools/NextZXOS/docs/
; extra-hw/dma/zxndma.txt, which transcribes the same Zilog-convention
; tables AND ships a worked mem-to-mem CONTINUOUS example, "TransferDMA",
; that this template now matches byte for byte) and against the retired
; SP8/f-prime sample engine (git show d464951, audDmaProg), which cites
; the same PDF by page number. Two bytes the brief's sketch omitted were
; added back after that check - see sp11-task-2-report.md "Program bytes
; used" for the full derivation:
;   - WR1's base byte (%01010100) sets D6, which per the datasheet
;     requires an associated "port A timing byte" to follow; without it
;     every subsequent byte in the program desyncs. Added %00000010
;     (cycle length 2 - zxndma.txt: "cycle lengths... can be set to
;     their minimum values without ill effects", the auto-slowdown
;     handles Layer 2 contention transparently regardless of source).
;   - WR2's base byte (%01010000) sets the same D6 timing-byte flag for
;     port B; same fix, same cycle-length-2 byte, prescaler bit (D5)
;     left clear - a plain mem-to-mem copy has no fixed-rate
;     requirement, and this is the only DMA program in the codebase
;     (the SP8 sample engine that used a prescaler is fully retired),
;     so there is no stale prescaler state to inherit.
; WR5 = $82: zxndma.txt's own worked example mislabels this byte
; "Restart on end of block" in its comment, but its OWN formal bit
; table (D5=0) and the retired SP8 engine's code comment both agree
; $82 = STOP on end of block - the table and the field-tested reference
; outrank the prose typo. Block length is the EXACT byte count (not
; N-1): the datasheet's classic-Z80-DMA off-by-one does not apply to
; the zxnDMA (zxndma.txt states this explicitly; the retired SP8
; engine's own comment records the same empirical finding).
; The static half: port modes + the one-shot stop, sent once per
; dma_copy CALL with interrupts LIVE. These registers persist across the
; arm's own WR6 disable/load/enable, which is why the arm need not carry
; them. WR1 = INCREMENTING here is also what keeps video.asm:1517's
; invariant true from this side.
dma_prog_static:
    db %01010100                 ; WR1: A memory, incrementing, timing
                                  ; byte follows
    db %00000010                 ; A cycle length 2
    db %01010000                 ; WR2: B memory, incrementing, timing
                                  ; byte follows
    db %00000010                 ; B cycle length 2, no prescaler
    db %10000010                 ; WR5 $82: /ce only, STOP on end of
                                  ; block (see header: never auto-restart)
dma_prog_static_len equ $ - dma_prog_static
    ASSERT dma_prog_static_len == DMA_STATIC_LEN

; The per-chunk arm: everything that changes, plus load + enable.
dma_prog:
    db $83                       ; WR6: disable (clean slate before load)
    db %01111101                 ; WR0: A->B, port A addr + block length
                                  ; follow (D3-D6 all set: low,high,lenLo,
                                  ; lenHi, in that order)
.aaddr:
    dw 0                         ; port A start = source (patched)
.alen:
    dw 0                         ; block length, EXACT count, patched as
                                  ; one 16-bit field (dma_copy writes both
                                  ; bytes and its tail reads them back as
                                  ; one ld de,(nn)) - that is what lets
                                  ; DMA_CHUNK_MAX be 256
    db %10101101                 ; WR4: CONTINUOUS mode, port B addr
                                  ; (low+high) follows
.baddr:
    dw 0                         ; port B start = dest (patched)
    db $CF                       ; WR6: load
    db $87                       ; WR6: enable - this OUT does not return
                                  ; until the chunk has fully transferred
dma_prog_len equ $ - dma_prog
    ASSERT dma_prog_len == DMA_ARM_LEN

; --- DMA timing measurement (SP11 Task 2, diagnostic, OFF by default) ---
; frameCounter deltas (src/interrupts.asm - incremented once per frame
; by BOTH the frame ISR's fast and full-context paths) around the two
; DMA-eligible operations, printed via the DEBUG dbg_* console. OFF by
; default; assemble with -DDMA_MEASURE=1 ALONGSIDE the default DEBUG
; build. Verified this also assembles cleanly under a Release-style
; build (debug.asm's dbg_* Release stubs are shared no-op `ret`s, not
; missing labels - see debug.asm:791 "Release stubs: same entry points,
; no output, minimal size") but is pointless there: every dbg_* call
; silently discards its output, so the printed numbers never appear -
; DEBUG is where this diagnostic actually earns its ~94 bytes. Formerly
; an A/B leg (build once with DMA_GFX, once with -NoDmaGfx, compare the
; two printed deltas) - that question closed 2026-07-21 (owner hardware
; test, see dma_copy's own header) and -NoDmaGfx retired with its CPU-
; only fallback, so this now just measures the (sole) DMA path's own
; timing; there is no in-build CPU-vs-DMA runtime toggle to compare
; against any more.
;   C256/C320 (row 18) - one l2_copy_back_front call (GFX condact subs
;     0/1), labelled by l2Mode at the moment it runs (0 = 256x192, 6
;     pages; 1 = 320x256, 10 pages).
;   SCAT (row 19) - one full gfx_blit, ONLY when stagedMode = 1 (320-
;     wide, the gfx_row_scatter320 path - see that routine's own header
;     for why it never had a DMA branch to begin with, -NoDmaGfx or
;     not: the scatter pattern was always CPU-only on its own merits).
 IFDEF DMA_MEASURE
dma_meas_report:
    call dbg_puts                ; HL = label (ASCIIZ); advances past it
    ld hl, (frameCounter)
    ld de, (dmaMeasT0)
    or a
    sbc hl, de                   ; HL = frame delta since dmaMeasT0
    call dbg_hex16
    ld a, 13
    jp dbg_putc
dmaMeasT0:      dw 0
dmaMeasLblC256: db "C256 ", 0
dmaMeasLblC320: db "C320 ", 0
dmaMeasLblScat: db "SCAT ", 0
 ENDIF

; Copy one Layer 2 surface onto the other, page for page. Slot 6 is
; the ONLY data window available to this overlay - slot 7 holds this
; very code (see gfxRowBuf's header, and banks.asm's ovl_map_page
; "DISPATCHER/ISR ONLY") - so source and destination pages can never
; be mapped at once: unlike a dual-window LDIR, each GFX_COPY_CHUNK-
; byte slice bounces through gfxRowBuf (idle here - same "loads and
; blits never overlap" invariant gfxRowBuf's header already relies
; on), mirroring gfx_row_fetch/gfx_row_copy256's source-OR-dest shape.
; Page count follows l2Mode exactly as l2_clear_back sizes it: 6 x 8K
; pages (256x192, 3 banks) or 10 x 8K pages (320x256, 5 banks) - NOT a
; fixed 5-bank assumption, so a 256-wide surface never touches its
; unused banks 3-4. In: A = source surface's first bank number, D =
; dest surface's first bank number - GFX 0 (copy back->front) and GFX
; 1 (copy front->back) are h_gfx's only two callers, and pass
; l2FrontBank/l2BackBank in swapped order: that swap IS the entire
; difference between the two subs, this routine is otherwise
; direction-blind. Brackets data_save/data_restore itself (mainline,
; NON-NESTABLE - one bracket, opened and closed on every path - see
; banks.asm). Corrupts everything.
GFX_COPY_CHUNK equ 256                  ; divides 8192 evenly, fits
                                         ; inside gfxRowBuf (320 bytes)
GFX_COPY_CHUNKS_PER_PAGE equ 8192/GFX_COPY_CHUNK
l2_copy_back_front:
 IFDEF DMA_MEASURE
    ld hl, (frameCounter)
    ld (dmaMeasT0), hl
 ENDIF
    add a, a
    ld (l2CopySrcPage), a
    ld a, d
    add a, a
    ld (l2CopyDstPage), a
    call data_save
    ld a, (l2Mode)
    or a
    ld a, 6
    jr z, .cnt
    ld a, 10
.cnt:
    ld (l2CopyPageCnt), a
.page:
    ld hl, DATA_WINDOW
    ld (l2CopyPtr), hl
    ld a, GFX_COPY_CHUNKS_PER_PAGE
    ld (l2CopyChunkCnt), a
.chunk:
    ld a, (l2CopySrcPage)
    call data_map_page
    ld hl, (l2CopyPtr)
    ld de, gfxRowBuf
    ld bc, GFX_COPY_CHUNK
    call dma_copy                ; source page -> bounce buffer
    ld a, (l2CopyDstPage)
    call data_map_page
    ld hl, gfxRowBuf
    ld de, (l2CopyPtr)
    ld bc, GFX_COPY_CHUNK
    call dma_copy                ; bounce buffer -> dest page
    ld hl, (l2CopyPtr)
    ld de, GFX_COPY_CHUNK
    add hl, de
    ld (l2CopyPtr), hl
    ld hl, l2CopyChunkCnt
    dec (hl)
    jr nz, .chunk
    ld hl, l2CopySrcPage         ; page done: advance both cursors
    inc (hl)
    ld hl, l2CopyDstPage
    inc (hl)
    ld hl, l2CopyPageCnt
    dec (hl)
    jr nz, .page
    call data_restore
 IFDEF DMA_MEASURE
    ld a, (l2Mode)
    ld hl, dmaMeasLblC256
    or a
    jr z, .measl
    ld hl, dmaMeasLblC320
.measl:
    ld b, 18
    ld c, 0
    call dbg_at
    call dma_meas_report
 ENDIF
    ret

l2CopySrcPage:  db 0
l2CopyDstPage:  db 0
l2CopyPtr:      dw 0
l2CopyPageCnt:  db 0
l2CopyChunkCnt: db 0

; 28 DISPLAY (action): B = 0 draws the staged picture, B != 0 clears
; the picture plane. Semantics pinned against jdaad _DISPLAY
; (jdaad.js 2750-2754): jdaad IGNORES its argument entirely - it
; always draws the staged imageBufferID, and silently no-ops when
; nothing is staged ("if (imageBufferID === false) return;"). The
; DAAD reference (condacts table, row 28) is what gives the argument
; meaning: "If 0: show buffered picture. If non-0: clear window
; area". Pinned here: B = 0 follows both (blit the stage, no-op when
; empty, per the jdaad line above); B != 0 follows the DAAD
; reference, with "window area" read as the picture plane - the
; Layer 2 surface is cleared to the transparent colour so the tilemap
; text underneath shows through. (The old overlay0 stub's text-window
; CLS for non-zero was wrong on this architecture: pictures never
; occupy the text plane, so DISPLAY must never destroy text.)
; The clear goes through the BACK surface + flip rather than clearing
; the front in place: one NR $12 write makes it instantaneous, where
; a front clear would wipe 48-80K through the visible surface -
; exactly the progressive-paint artifact double buffering exists to
; kill. Mode, clip and palette are left as they stand. Corrupts
; everything.
h_display:
    ld a, b
    or a
    jp z, gfx_blit
    call l2_clear_back
    call l2_flip_swap
    ld a, (l2FrontBank)
    nextreg NR_L2_BANK, a
    ret

; 87 GFX (action): C = sub-command (P2); B (P1 = n) is unused - every
; implemented sub's buffer operation takes no meaningful P1 (jdaad
; parity: jdaad.js's _GFX() switches on Parameter2 alone - Parameter1
; only matters to its palette-store subs 9/10, which have no
; NextDAAD analogue, see below). Sub map pinned against the DAAD
; condact reference (GFX Routines, condact 87) and jdaad.js _GFX()/
; DB*() (ASSETS/HTML/jdaad.js ~3676/~4360):
;   0 = copy the BACK (render) surface onto FRONT (visible), in place
;       - l2_copy_back_front; jdaad's DBBuffertoScreen draws the back
;       canvas onto the visible one the same way, so this needs no NR
;       $12 write - the front bank's identity does not change, only
;       its contents, and it is already the one being displayed
;   1 = copy FRONT onto BACK, in place - same routine, source/dest
;       bank bases swapped (jdaad's DBScreentoBuffer)
;   2 = swap the front/back roles AND push the new front bank to NR
;       $12 immediately - l2_flip_swap is VARIABLES ONLY (see its own
;       header), so this dispatcher pairs it with the hardware write
;       itself, exactly as h_display's clear path above does, so the
;       swap is actually visible: jdaad's DBSwapBuffers exchanges the
;       visible canvas's pixels immediately, not on a later flip
;   5 = clear the FRONT surface in place - l2_clear (jdaad's
;       DBClearScreen fills the visible canvas directly)
;   6 = clear the BACK surface - l2_clear_back (jdaad's DBClearBuffer)
;   9/10 = jdaad's numbered-palette store/recall (flag-offset RGB
;       triples into a software colour table) - no NextDAAD analogue,
;       Layer 2 palette load is picture-driven only; documented no-op
;   3/4/7/8/11+ (and jdaad's 13/14 MP4-via-SFX redirect) = no
;       NextDAAD analogue either (graphics/text-buffer split, video
;       playback); documented no-op
; Every no-op sub falls to the shared DEBUG marker below rather than
; overlay0's h_unimpl - overlay2 must not call overlay0 (header
; discipline) - inline, resident dbg_* helpers only, mirrors h_sfx's
; unknown-sub idiom (SP7 Task 4, overlay1.asm). Corrupts everything.
h_gfx:
    ld a, c                     ; sub-command
    cp 0
    jr z, .backfront
    cp 1
    jr z, .frontback
    cp 2
    jr z, .swap
    cp 5
    jp z, l2_clear
    cp 6
    jp z, l2_clear_back
    cp GFX_SUB_VID_ONCE
    jr z, .vidonce
    cp GFX_SUB_VID_LOOP
    jr z, .vidloop
 IFDEF DEBUG                    ; no NextDAAD analogue: marker only.
    push bc                     ; Second push keeps C (the sub) safe
    push bc                     ; across dbg_puts (corrupts BC) for
    ld b, 29                    ; the dbg_hex8 below.
    ld c, 70
    call dbg_at
    ld hl, msgGfxUnk
    call dbg_puts
    pop bc
    ld a, c
    call dbg_hex8
    pop bc
 ENDIF
    ret
.backfront:
    ld a, (l2FrontBank)
    ld d, a
    ld a, (l2BackBank)
    jp l2_copy_back_front
.frontback:
    ld a, (l2BackBank)
    ld d, a
    ld a, (l2FrontBank)
    jp l2_copy_back_front
.swap:
    call l2_flip_swap
    ld a, (l2FrontBank)
    nextreg NR_L2_BANK, a
    ret
.vidonce:
    ld a, 0
    jr .vidgo
.vidloop:
    ld a, 1
.vidgo:
    ; B (video number) is untouched; C becomes vid_play's 0/1 loop
    ; contract. ovl_map_page corrupts AF only (banks.asm) - B/C survive
    ; the cross-page hop into video.asm, a different MMU7 page from this
    ; one (the established push-target/ovl_map_page trampoline idiom -
    ; xpart_load_fail's own hop, overlay0.asm).
    ld c, a
    ld hl, vid_play
    push hl
    ld a, VID_PAGE
    jp ovl_map_page

msgGfxUnk: db "GFX? ", 0

; A = picture number. Ensure its palette+pixels are in cache banks
; and stage it for DISPLAY 0. Cache hit: cache_touch + stage, no SD
; access. Miss: reserve a cache slot (evicting the coldest entry via
; gfx_evict_fix when every slot is committed), probe the extension
; chain (gfxExtTab order - ZX0-compressed variants win over raw),
; stream the file into freshly allocated 16K banks with count-checked
; reads - gfx_bank_get evicts cold entries as the pool runs dry - for
; a compressed variant depack those scratch banks into a fresh
; destination run (gfx_depack), derive the height from the
; (decompressed) byte total, then commit the entry and stage it.
; When even a full eviction pass cannot supply banks (or an evictable
; slot), a RAW file takes the direct-stream fallback instead
; (gfx_direct_stream: fused load+blit, nothing cached, stage cleared
; so a revisit reloads - but PICTURE itself still succeeds);
; compressed variants cannot (see gfx_direct_stream's header) and
; fail cleanly. Out: CF clear = staged (or fallback-drawn). CF set =
; failed (no file, depack error, malformed size, exhaustion with no
; fallback): every partially allocated bank is freed - scratch and
; destination alike, the arena cursor still covers both - the cursor
; rewound, and the stage cleared - jdaad unstages on a failed PICTURE
; too. Corrupts everything.
gfx_load:
    ld (gfxPicNum), a
    cp GFX_EMPTY                ; 255 = the empty-slot sentinel; passing it
    jp z, .failclean            ; to cache_find would false-match every
                                ; unused slot, so it is simply unloadable
    call cache_find
    jr c, .miss
    ld (gfxEntryIdx), a         ; hit: A = entry index
    call cache_touch
    jr .stage
.miss:
    xor a
    ld (gfxAllocFail), a
.slot:
    call gfx_find_empty         ; reserve a slot; not written until the
    jr nc, .gotslot             ; load has fully verified
    call gfx_evict_fix          ; every slot committed: evict the
    jr nc, .slot                ; coldest and rescan
    jr .exhausted               ; nothing evictable (only the staged
                                ; slot left - the GFX_CACHE_MAX=1
                                ; degradation shape): fallback territory
.gotslot:
    ld (gfxEntryIdx), a
    call gfx_open_chain
    jp c, .failclean
    call gfx_read_banks         ; closes the file on every path
    jr c, .failbanks
    ld a, (gfxCompressed)
    or a                        ; also clears CF for the skip case
    call nz, gfx_depack         ; scratch banks -> decompressed run
    jr c, .failbanks
    call gfx_derive_height
    jr c, .failbanks
    ; everything verified: commit the cache entry
    ld a, (gfxEntryIdx)
    call gce_ptr
    ld a, (gfxPicNum)
    ld (hl), a                  ; GCE_PIC
    inc hl
    ld a, (gfxArenaStart)
    ld (hl), a                  ; GCE_FIRST
    inc hl
    ld a, (gfxBankCount)
    ld (hl), a                  ; GCE_COUNT
    inc hl
    ld a, (gfxMode)
    ld (hl), a                  ; GCE_MODE
    inc hl
    ld a, (gfxHeight)
    ld (hl), a                  ; GCE_HEIGHT (0 encodes 256)
    ld a, (gfxEntryIdx)
    call cache_touch
.stage:
    ld a, (gfxEntryIdx)
    call gce_ptr
    ld bc, GCE_MODE
    add hl, bc
    ld a, (hl)
    ld (stagedMode), a
    inc hl
    ld a, (hl)                  ; GCE_HEIGHT
    ld (stagedHeight), a
    ld a, (gfxPicNum)
    ld (stagedPic), a
    ld a, (gfxEntryIdx)
    ld (stagedEntry), a
    or a
    ret
.failbanks:
    call gfx_load_rollback
    ld a, (gfxAllocFail)        ; exhaustion (banks/arena, post-eviction)
    or a                        ; is the only failure the fallback can
    jr z, .failclean            ; help; io/shape errors fail clean
    ld a, (gfxCompressed)
    or a
    jr nz, .failclean           ; compressed: no fallback (see
                                ; gfx_direct_stream's header)
.exhausted:
    ; pool exhausted even after a full eviction pass: direct-stream a
    ; RAW file. (Re)open via the probe chain - it deterministically
    ; re-finds the same file and re-sets gfxMode/gfxWidth/gfxCompressed,
    ; which the .slot-exhaustion path arrives here without.
    call gfx_open_chain
    jr c, .failclean
    ld a, (gfxCompressed)
    or a
    jr nz, .failcloseh          ; compressed: close + clean fail
    call gfx_direct_stream      ; closes the handle on every path
    jr c, .failclean
    ; drawn + flipped, transient: no cache entry claims it and the
    ; stage is cleared so a revisit reloads; PICTURE still succeeds
    ld a, GFX_EMPTY
    ld (stagedPic), a
    ld (stagedEntry), a
    or a
    ret
.failcloseh:
    ld a, (gfxHandle)
    call esx_fclose
    ld a, $FF
    ld (gfxHandle), a
.failclean:
    ld a, GFX_EMPTY
    ld (stagedPic), a
    ld (stagedEntry), a
    scf
    ret

; Find the first empty cache slot. Out: CF clear + A = entry index;
; CF set when every slot is committed (gfx_load then evicts and
; rescans). Corrupts AF, B, DE, HL.
gfx_find_empty:
    ld hl, gfxCache
    ld de, GFX_ENTRY_SIZE
    ld b, 0
.scan:
    ld a, (hl)
    cp GFX_EMPTY
    jr z, .got
    add hl, de
    inc b
    ld a, b
    cp GFX_CACHE_MAX
    jr c, .scan
    scf
    ret
.got:
    ld a, b
    or a
    ret

; Build gfxName's "NNN" digits from gfxPicNum (3-digit zero-padded
; decimal, the project's repeated-subtraction decade idiom - see
; prn_dec_digit, print.asm), then probe the extension chain: each
; gfxExtTab row is tried with esx_fopen until one opens. Out: CF
; clear with the handle in gfxHandle and gfxMode/gfxWidth/
; gfxCompressed set from the matching row; CF set when no candidate
; exists on SD. Corrupts everything.
;
; SP11 T5 PARTn probe - keep in step with the other four sites (WAV/
; songs/SFB in overlay1.asm, XMB in overlay0.asm). curPart >= 2: try
; the WHOLE chain under PARTn\ first (gfx_open_chain_part below);
; root (shared pool) fallback below runs the WHOLE chain again,
; unchanged. curPart == 1: skip straight to the root pass - zero new
; opens, byte-identical to pre-T5 code.
gfx_open_chain:
    ld a, (curPart)
    dec a
    jr z, .rootonly
    call gfx_open_chain_part
    ret nc                       ; opened under PARTn\: gfxHandle/
                                  ; gfxMode/gfxWidth/gfxCompressed
                                  ; already set by gfx_open_chain_part
.rootonly:
    ld a, (gfxPicNum)
    ld hl, gfxName
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
    ld hl, gfxExtTab
.row:
    ld (gfxExtPtr), hl
    ld de, gfxName+4            ; past "NNN."
    ld bc, GFX_EXT_NAME         ; 7 NUL-padded extension characters -
    ldir                        ; a short extension carries its own
                                ; terminator; gfxName's final NUL backs
                                ; the full-length "NX2.ZX0" rows
    ld a, (hl)                  ; row's mode byte
    ld (gfxMode), a
    inc hl
    ld a, (hl)                  ; row's compressed flag
    ld (gfxCompressed), a
    ld a, (gfxMode)
    or a
    ld de, 256
    jr z, .width
    ld de, 320
.width:
    ld (gfxWidth), de
    call esx_getsetdrv          ; A = default drive for esx_fopen
    jr c, .next
    ld ix, gfxName
    ld b, ESX_MODE_READ
    call esx_fopen
    jr nc, .opened
.next:
    ld hl, (gfxExtPtr)
    ld de, GFX_EXT_ROW
    add hl, de
    push hl
    ld de, gfxExtEnd
    or a
    sbc hl, de
    pop hl
    jr nz, .row
    scf                         ; chain exhausted
    ret
.opened:
    ld (gfxHandle), a
    or a
    ret

; gfx_open_chain_part: PARTn\ prefixed pass (curPart 2-9 only - the
; caller above gates part 1 before ever reaching here). Textually
; parallel to gfx_open_chain's own root-pass body just above: same
; gfxPicNum digit-build, same gfxExtTab row walk, same output contract
; (CF clear + gfxHandle/gfxMode/gfxWidth/gfxCompressed set; CF set =
; chain exhausted under PARTn\, caller falls back to the unchanged
; root pass) - but writing/probing gfxNamePart instead of gfxName.
; Runs the WHOLE chain before giving up. Corrupts everything.
gfx_open_chain_part:
    ld hl, gfxNamePart
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
    inc hl                       ; hl = gfxNamePart+6
    ld a, (gfxPicNum)
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
    ld (hl), '.'                 ; hl = gfxNamePart+9
    ld hl, gfxExtTab
.row:
    ld (gfxExtPtr), hl
    ld de, gfxNamePart+10        ; past "PARTn\NNN."
    ld bc, GFX_EXT_NAME
    ldir
    ld a, (hl)                   ; row's mode byte
    ld (gfxMode), a
    inc hl
    ld a, (hl)                   ; row's compressed flag
    ld (gfxCompressed), a
    ld a, (gfxMode)
    or a
    ld de, 256
    jr z, .width
    ld de, 320
.width:
    ld (gfxWidth), de
    call esx_getsetdrv           ; A = default drive for esx_fopen
    jr c, .next
    ld ix, gfxNamePart
    ld b, ESX_MODE_READ
    call esx_fopen
    jr nc, .opened
.next:
    ld hl, (gfxExtPtr)
    ld de, GFX_EXT_ROW
    add hl, de
    push hl
    ld de, gfxExtEnd
    or a
    sbc hl, de
    pop hl
    jr nz, .row
    scf                          ; chain exhausted
    ret
.opened:
    ld (gfxHandle), a
    or a
    ret

; Stream the open gfxHandle file into freshly allocated 16K cache
; banks through slot 6, 8K per esx_fread. Every read is count-checked
; against BC-out (esxDOS clears CF on a short/EOF read; only a real
; error sets CF), a short read being EOF. Bank numbers are appended
; to gfxBankList at gfxBankNext. The file is CLOSED on every path.
; Out: CF clear with gfxArenaStart/gfxBankCount/gfxSize* filled
; (an EOF landing exactly on a bank boundary can leave one appended
; bank empty - harmless, the blitter only reads height*width bytes);
; CF set on error or oversize, allocated banks NOT yet freed - the
; caller's rollback owns that, the arena cursor still covers them.
; Brackets slot 6 with data_save/data_restore. Corrupts everything.
gfx_read_banks:
    call data_save
    ld a, (gfxBankNext)
    ld (gfxArenaStart), a
    xor a
    ld (gfxBankCount), a
    ld (gfxSizeHi), a
    ld hl, 0
    ld (gfxSizeLo), hl
.bank:
    ; the largest acceptable file, a 320x256 NX2 (512 + 81920 =
    ; 82432 bytes), fits in 6 banks; needing a 7th means this is not
    ; a picture this interpreter accepts
    ld a, (gfxBankCount)
    cp 6
    jr nc, .fail
    call gfx_bank_get           ; out: A = 16K bank; evicts cold cache
    jr c, .fail                 ; entries before giving up (CF +
                                ; gfxAllocFail set = true exhaustion)
    ld e, a
    ld hl, gfxBankList
    ld a, (gfxBankNext)
    add hl, a
    ld (hl), e                  ; append the bank
    inc a
    ld (gfxBankNext), a
    ld hl, gfxBankCount
    inc (hl)
    ld a, e
    add a, a                    ; lower 8K page of the bank
    ld (gfxCurPage), a
    call gfx_read_page
    jr c, .fail
    jr nz, .eof                 ; short read = end of file
    ld hl, gfxCurPage
    inc (hl)                    ; upper 8K page
    ld a, (hl)
    call gfx_read_page
    jr c, .fail
    jr nz, .eof
    jr .bank
.eof:
    ld a, (gfxHandle)
    call esx_fclose
    ld a, $FF
    ld (gfxHandle), a
    call data_restore
    or a
    ret
.fail:
    ld a, (gfxHandle)
    cp $FF
    jr z, .noclose
    call esx_fclose
    ld a, $FF
    ld (gfxHandle), a
.noclose:
    call data_restore
    scf
    ret

; A = 8K page: map it into slot 6 and esx_fread up to $2000 bytes
; into the window, accumulating the actual count into the 24-bit
; gfxSizeHi:gfxSizeLo. Out: CF set = esxDOS error; else ZF clear =
; short read (EOF), ZF set = full page read. Corrupts everything
; (esxDOS makes no register promises); the caller keeps its own
; state in memory.
gfx_read_page:
    call data_map_page
    ld a, (gfxHandle)
    ld ix, DATA_WINDOW
    ld bc, $2000
    call esx_fread              ; out: BC = ACTUAL bytes read
    ret c
    ld hl, (gfxSizeLo)
    add hl, bc
    ld (gfxSizeLo), hl
    jr nc, .nocarry
    ld hl, gfxSizeHi
    inc (hl)
.nocarry:
    ld hl, $2000
    or a
    sbc hl, bc                  ; ZF = full read (CF impossible, BC <= $2000)
    ret

; Derive the pixel-row count: rows = (24-bit total - 512) / gfxWidth
; by repeated subtraction (at most 256 rounds - the tallest legal
; picture is one full 256-row surface). Out: CF clear + gfxHeight
; (0 encodes 256 rows, the GCE_HEIGHT convention); CF set when the
; size is malformed - shorter than the palette, zero rows, a partial
; trailing row, or taller than the mode's surface (192 rows in
; 256-wide mode, 256 rows in 320-wide mode). Corrupts everything.
gfx_derive_height:
    ld hl, (gfxSizeLo)
    ld de, 512
    or a
    sbc hl, de
    ld a, (gfxSizeHi)
    sbc a, 0
    jr c, .bad                  ; shorter than the palette
    ld c, a                     ; C:HL = pixel byte count
    or h
    or l
    jr z, .bad                  ; no pixel data at all
    ld de, (gfxWidth)
    ld b, 0                     ; completed rows, mod 256
.row:
    and a                       ; clear CF (A holds scan junk)
    sbc hl, de
    jr nc, .noborrow
    dec c
.noborrow:
    ld a, c                     ; C legitimately reaches at most 1
    inc a                       ; ($14000 = 320*256 pixels), so $FF can
    jr z, .bad                  ; only mean a partial trailing row
    inc b
    ld a, h
    or l
    or c
    jr z, .done
    ld a, b
    or a
    jr nz, .row
    jr .bad                     ; 256 rows consumed, bytes remain
.done:
    ld a, (gfxMode)
    or a
    jr nz, .m320                ; 320-wide surface: any row count fits
    ld a, b                     ; 256-wide surface holds 192 rows
    or a
    jr z, .bad                  ; B = 0 encodes 256 rows
    cp 193
    jr nc, .bad
.m320:
    ld a, b
    ld (gfxHeight), a
    or a
    ret
.bad:
    scf
    ret

; Free the banks a failed load appended (arena indices gfxArenaStart
; .. gfxBankNext-1) and rewind the arena cursor. The reserved cache
; slot was never written, so it is still empty - nothing else to
; drop. Corrupts AF, B, HL.
gfx_load_rollback:
    ld a, (gfxBankNext)
    ld hl, gfxArenaStart
    sub (hl)
    ld b, a                     ; banks to free
    ld a, (hl)
    ld (gfxBankNext), a         ; rewind
    ld hl, gfxBankList
    add hl, a
    ld a, b
    or a
    ret z
.free:
    ld a, (hl)
    call bank_free              ; preserves BC, DE, HL (banks.asm)
    inc hl
    djnz .free
    ret

; Allocate one 16K bank for the arena, evicting the coldest cache
; entry (and compacting the arena) as many times as it takes until
; both a free bank and arena room exist. Every eviction frees at
; least one bank and at least one arena slot (committed entries hold
; >= 1 bank), and the victim set only shrinks, so the loop
; terminates. Out: CF clear + A = bank (the caller appends it at
; gfxBankNext); CF set + gfxAllocFail = 1 when nothing evictable
; remains and the pool is still dry - TRUE exhaustion, gfx_load's
; fallback trigger. Corrupts AF, BC, DE, HL.
gfx_bank_get:
.try:
    ld a, (gfxBankNext)
    cp GFX_BANKLIST_MAX
    jr nc, .evict               ; bank-list arena full
    call bank_alloc             ; out: A = 16K bank, CF = none free
    ret nc
.evict:
    call gfx_evict_fix
    jr nc, .try
    ld a, 1
    ld (gfxAllocFail), a
    scf
    ret

; --- LRU eviction (moved from resident gfxcache.asm, SP8 Task 1: the
; only caller is gfx_evict_fix below; frees ~200 resident bytes) -----

; A = entry index. Frees every bank in the entry's bank-list range via
; bank_free, then clears the slot (picture# = GFX_EMPTY, counts/mode/
; height/tick zeroed). Safe to call on an already-empty slot (bankCount
; 0 skips the free loop). NOTE: this clears the ENTRY but leaves the
; entry's slots in gfxBankList behind - a caller must recompact the
; arena or the density invariant (see gfxBankNext) breaks. The only
; caller is cache_evict_lru below, which owns that compaction.
; Corrupts AF, BC, DE, HL.
; SP14c gate follow-up: A held firstBankIdx immediately after the read
; below, before bankCount's own read clobbered it - reordered so the
; Z80N ADD HL,A add runs while A still holds it, removing the C/D/E
; relay entirely (C is no longer read anywhere in this routine). This
; also removes the need for .clear's own pop: HL already sits at
; entry base+2 (the bankCount cell) when .clear is reached either way
; (fall-through from the bankCount==0 test, or after the .free loop -
; bank_free's own "preserves BC, DE, HL" contract keeps it there), so
; the two dec hl below land on entry base with no stack retrieval.
cache_drop:
    call gce_ptr                 ; HL -> entry base (picture#)
    inc hl                       ; -> firstBankIdx
    ld a, (hl)                   ; A = firstBankIdx
    push hl                      ; save pointer (entry base + 1)
    ld hl, gfxBankList
    add hl, a                    ; Z80N ED 31: HL = gfxBankList+firstBankIdx
    ex de, hl                    ; DE -> gfxBankList[firstBankIdx]
    pop hl                       ; HL -> entry base + 1 (firstBankIdx)
    inc hl                       ; -> bankCount
    ld a, (hl)
    ld b, a                      ; B = bankCount
    ld a, b
    or a
    jr z, .clear
.free:
    ld a, (de)
    call bank_free               ; preserves BC, DE, HL (banks.asm)
    inc de
    djnz .free
.clear:
    dec hl
    dec hl                       ; HL -> entry base
    ld (hl), GFX_EMPTY           ; picture#
    inc hl
    xor a
    ld (hl), a                   ; firstBankIdx
    inc hl
    ld (hl), a                   ; bankCount
    inc hl
    ld (hl), a                   ; mode
    inc hl
    ld (hl), a                   ; height
    inc hl
    ld (hl), a                   ; tick
    ret

; Evict the least-recently-used committed cache entry - the lowest
; tick among occupied slots, EXCLUDING the staged slot (stagedEntry):
; gfx_blit re-reads the staged entry's banks at DISPLAY time, so
; evicting it would be a use-after-free (a DISPLAYED-but-unstaged
; picture is safe to evict - its pixels already live on the Layer 2
; surface and its banks are never re-read). The in-flight load's
; reserved slot is still GFX_EMPTY (gfx_load commits only on success)
; so it is excluded naturally. Frees the victim's banks (cache_drop),
; then COMPACTS the arena: the victim's gfxBankList slots are closed
; up by sliding every higher slot down, every surviving entry's
; GCE_FIRST is rebased, and gfxBankNext shrinks - restoring the
; density invariant. The victim's run always sits strictly below any
; in-flight run (loads append at the cursor), so the caller rebases
; its own in-flight arena indices by the same rule: index > E means
; index -= D (overlay2's gfx_evict_fix).
; Out: CF clear with D = removed slot count, E = removed first index;
; CF set (D, E undefined) when nothing is evictable. Corrupts
; AF, BC, DE, HL.
cache_evict_lru:
    ld hl, gfxCache
    ld b, 0                      ; B = scan index
    ld c, GFX_EMPTY              ; C = victim index, none yet
    ld d, 0                      ; D = victim tick (valid once C set)
.scan:
    ld a, (hl)                   ; GCE_PIC
    cp GFX_EMPTY
    jr z, .next                  ; empty slot
    ld a, (stagedEntry)
    cp b
    jr z, .next                  ; staged: gfx_blit may re-read it
    push hl
    ld a, GCE_TICK
    add hl, a
    ld e, (hl)                   ; E = candidate tick
    pop hl
    ld a, c
    cp GFX_EMPTY
    jr z, .take                  ; first candidate is provisional victim
    ld a, e
    cp d
    jr nc, .next                 ; not older than the victim so far
.take:
    ld c, b
    ld d, e
.next:
    push de
    ld de, GFX_ENTRY_SIZE
    add hl, de
    pop de
    inc b
    ld a, b
    cp GFX_CACHE_MAX
    jr c, .scan
    ld a, c
    cp GFX_EMPTY
    jr z, .none
    ; victim found: capture its run before cache_drop clears it
    call gce_ptr                 ; A = victim index; HL -> entry base
    inc hl
    ld a, (hl)                   ; GCE_FIRST
    ld (gceDropFirst), a
    inc hl
    ld a, (hl)                   ; GCE_COUNT
    ld (gceDropCount), a
    ld a, c
    call cache_drop              ; free the banks, clear the slot
    ; slide gfxBankList[first+count .. gfxBankNext-1] down over the
    ; hole (forward LDIR: dest < src, overlap-safe)
    ld a, (gceDropFirst)
    ld hl, gfxBankList
    add hl, a                    ; Z80N ED 31 - gate follow-up, same
                                  ; class as OV1-3/OV1-4 (A already =
                                  ; gceDropFirst, nothing intervenes)
    ex de, hl                    ; DE = dest = list + first
    ld a, (gceDropCount)
    ld l, a
    ld h, 0
    add hl, de                   ; HL = src = list + first + count
    ld a, (gceDropFirst)
    ld b, a
    ld a, (gceDropCount)
    add a, b                     ; first + count (<= gfxBankNext <= 128)
    ld b, a
    ld a, (gfxBankNext)
    sub b                        ; slots above the hole
    jr z, .slid                  ; victim was the topmost run
    ld c, a
    ld b, 0
    ldir
.slid:
    ; rebase every surviving entry whose run sat above the hole
    ; (empty slots hold GCE_FIRST = 0, never > first, so no guard)
    ld a, (gceDropFirst)
    ld e, a
    ld a, (gceDropCount)
    ld d, a
    ld hl, gfxCache + GCE_FIRST
    ld b, GFX_CACHE_MAX
.rebase:
    ld a, (hl)
    cp e
    jr z, .keep                  ; == first: the cleared victim itself
    jr c, .keep                  ; below the hole: untouched
    sub d
    ld (hl), a
.keep:
    push de
    ld de, GFX_ENTRY_SIZE
    add hl, de
    pop de
    djnz .rebase
    ld a, (gfxBankNext)
    sub d
    ld (gfxBankNext), a
    or a                         ; CF clear; D = count, E = first
    ret
.none:
    scf
    ret

gceDropFirst: db 0               ; cache_evict_lru scratch: victim run
gceDropCount: db 0               ; (first index, slot count)

; Evict the LRU cache entry (cache_evict_lru: excludes the staged
; slot, frees the banks, compacts the arena, rebases the surviving
; entries) and rebase this load's own in-flight arena indices by the
; same rule - any index above the removed run slides down with it.
; The victim's run always sits strictly below the in-flight run (the
; density invariant, gfxcache.asm), so gfxArenaStart and the depack
; cursors always qualify when live; when no load/depack is in flight
; they hold stale values that the next load re-initialises before
; reading, so the blind rebase is harmless. Out: CF set = nothing
; evictable. Corrupts AF, BC, DE, HL.
gfx_evict_fix:
    call cache_evict_lru        ; out: D = removed count, E = first
    ret c
    ld hl, gfxArenaStart
    call .fix
    ld hl, zx0SrcIdx
    call .fix
    ld hl, zx0DstStart
    call .fix
    or a
    ret
.fix:
    ld a, (hl)
    cp e                        ; index <= removed first: untouched
    ret c
    ret z
    sub d
    ld (hl), a
    ret

; Fused load+blit fallback for pool exhaustion - RAW files only.
; In: gfxHandle = an OPEN read handle on gfxName at offset 0, with
; gfxMode/gfxWidth set by gfx_open_chain and gfxCompressed = 0 (the
; caller enforces it). Streams the file from SD straight onto the
; BACK Layer 2 surface: commit l2Mode (front's mode snapshotted for
; the failure restore - see the entry comment) + clear the back, skip
; the 512-byte embedded palette, then per
; row esx_fread gfxWidth bytes into gfxRowBuf and write it with the
; SAME row writers gfx_blit uses (gfx_row_copy256/gfx_row_scatter320
; - the walks cannot diverge), enforcing gfx_derive_height's shape
; rules on the fly (>= 1 row, no partial trailing row, <= 192 rows on
; the 256-wide surface, <= 256 on the 320-wide). Then the palette:
; the file cursor is past it and F_SEEK is unproven in this codebase,
; so the file is closed and REOPENED (gfx_open_chain deterministically
; re-finds the same file) and the 512 bytes are programmed in two
; 256-byte halves through the shared l2_pal9_run + l2_pal9_stamp (the
; same $FE dodge and entry-254 stamp as l2_palette_load). Finally the
; flip, exactly as gfx_blit ends. NOTHING is cached and the caller
; clears the stage: the result is transient, a revisit reloads.
; WHY RAW ONLY: a compressed fallback would have to depack directly
; into the Layer 2 banks, but ZX0 back-references read earlier OUTPUT
; bytes assuming the linear layout the depacker's dest window
; provides, and the 320-wide surface is COLUMN-MAJOR - the scatter
; reorders bytes, so match copies would read reordered data. A 256-
; wide surface is linear, but a single fallback shape keeps this
; corner simple: compressed loads that exhaust eviction fail cleanly
; in gfx_load instead (CF, no picture, session unharmed). On a 1MB
; machine any legal picture still fits after a full eviction pass, so
; this whole routine is single-load-bigger-than-everything territory.
; Out: CF clear = drawn, flipped, handle closed. CF set = failed,
; handle closed, l2Mode restored to the still-displayed front
; surface's mode; the back surface may hold partial paint - invisible,
; never flipped, so the session is unharmed. Corrupts everything.
gfx_direct_stream:
    ; l2Mode is committed to the NEW mode before the clear (it sizes
    ; l2_clear_back's page count) but the flip only happens on success:
    ; snapshot the front surface's mode and restore it on the failure
    ; funnel, or a later DISPLAY n!=0 would size its back clear for the
    ; wrong surface (front=320, failed 256 fallback: only 6 of the 10
    ; pages cleared - garbage band after that flip). Chosen over making
    ; l2_clear_back unconditionally clear 10 pages: the snapshot is
    ; smaller and costs successful draws nothing. gfx_blit shares the
    ; commit-before-flip shape but has no failure path after its
    ; commit, so it needs no snapshot.
    ld a, (l2Mode)
    ld (gfxModeSave), a
    ld a, (gfxMode)
    ld (l2Mode), a              ; variable only - sizes l2_clear_back;
                                ; NR $70/$12 wait for the flip
    ld a, (l2BackBank)
    add a, a
    ld (gfxSurfPage), a
    call l2_clear_back          ; own data_save/restore - run BEFORE
                                ; ours, exactly as gfx_blit orders it
                                ; (no nested data_save)
    call data_save
    ld b, 2                     ; skip the palette: 2 x 256-byte
.skip:                          ; discard reads through gfxRowBuf
    push bc
    call gfx_direct_read256
    pop bc
    jp c, .fail
    djnz .skip
    ; render state exactly as gfx_blit stages it
    ld a, (gfxSurfPage)         ; 256-wide linear dest stream init
    ld (gfxDstPage), a          ; (the 320-wide scatter reinitialises
    ld hl, DATA_WINDOW          ; gfxDstPage itself every row)
    ld (gfxDstPtr), hl
    xor a
    ld (gfxRowY), a             ; doubles as the written-row count
    ld (gfxRowFull), a
.row:
    ld a, (gfxHandle)
    ld ix, gfxRowBuf
    ld bc, (gfxWidth)
    call esx_fread              ; out: BC = ACTUAL bytes read
    jp c, .fail
    ld a, b
    or c
    jr z, .eof                  ; clean EOF on a row boundary
    ld hl, (gfxWidth)
    or a
    sbc hl, bc
    jp nz, .fail                ; partial trailing row: malformed
    ; enforce the surface's row capacity BEFORE writing
    ld a, (gfxRowFull)
    or a
    jp nz, .fail                ; 257th row on the 320-wide surface
    ld a, (gfxMode)
    or a
    jr nz, .fits
    ld a, (gfxRowY)
    cp 192
    jp nc, .fail                ; 193rd row on the 256-wide surface
.fits:
    ld a, (gfxMode)
    or a
    jr z, .linear
    call gfx_row_scatter320
    jr .wrote
.linear:
    call gfx_row_copy256
.wrote:
    ld hl, gfxRowY
    inc (hl)
    jr nz, .row
    ld a, 1                     ; row 255 written, counter wrapped: the
    ld (gfxRowFull), a          ; full 256-row surface is painted -
    jr .row                     ; only EOF may follow
.eof:
    ld a, (gfxRowY)
    ld hl, gfxRowFull
    or (hl)
    jr z, .fail                 ; no pixel rows at all
    ; palette pass: reopen at offset 0 (header comment)
    ld a, (gfxHandle)
    call esx_fclose
    ld a, $FF
    ld (gfxHandle), a
    call gfx_open_chain
    jr c, .faildone
    nextreg NR_PAL_CTRL, PAL_L2_FIRST
    nextreg NR_PAL_INDEX, 0
    ld b, 2
.pal:
    push bc
    call gfx_direct_read256
    jr c, .palfail
    ld hl, gfxRowBuf
    ld b, 128                   ; 128 9-bit entries per 256-byte half
    call l2_pal9_run            ; shared $FE-dodge programming loop
    pop bc
    djnz .pal
    call l2_pal9_stamp          ; entry 254 = the reserved transparent
    ld a, (gfxHandle)
    call esx_fclose
    ld a, $FF
    ld (gfxHandle), a
    call data_restore
    ; flip exactly as gfx_blit ends: swap the surface roles, then the
    ; resolution and new front bank back-to-back (l2_flip_swap header)
    call l2_flip_swap
    ld a, (gfxMode)
    call l2_mode_set
    call l2_enable
    or a
    ret
.palfail:
    pop bc
.fail:
    ld a, (gfxHandle)
    call esx_fclose
    ld a, $FF
    ld (gfxHandle), a
.faildone:
    call data_restore
    ld a, (gfxModeSave)         ; no flip happened: re-sync l2Mode with
    ld (l2Mode), a              ; the still-displayed front surface
    scf
    ret

; Read exactly 256 bytes from gfxHandle into gfxRowBuf. Out: CF set
; on an esxDOS error or a short read. Corrupts everything (esx_fread
; makes no register promises). Only gfx_direct_stream calls this.
gfx_direct_read256:
    ld a, (gfxHandle)
    ld ix, gfxRowBuf
    ld bc, 256
    call esx_fread              ; out: BC = ACTUAL bytes read
    ret c
    ld hl, 256
    or a
    sbc hl, bc
    ret z                       ; full read: ZF set, CF clear
    scf
    ret

; --- ZX0 depacker (Task 5) ---
; Core algorithm vendored from Einar Saukas's dzx0_standard.asm
; ("Standard" ZX0 decoder, https://github.com/einar-saukas/ZX0,
; BSD-licensed / freely reusable with attribution; the copy shipped
; with z88dk at tools/z88dk/libsrc/_DEVELOPMENT/compress/zx0/z80/
; dzx0_standard.asm was the vendoring source).
;
; FORMAT: ZX0 CLASSIC (v1), and that is a hard requirement - ZX0 v2
; changed the stream format and the two are mutually unreadable.
; Measured 2026-08-05, all three components agree:
;   - tools/z88dk/bin/z88dk-zx0.exe reports "ZX0 v1.5" and offers only
;     -f/-b/-q. The -classic switch that selects this format exists
;     only in ZX0 v2 and later, so a build without it PREDATES the
;     change and emits v1 unconditionally.
;   - gfx2next's built-in compressor is the same vintage (-zx0-back /
;     -zx0-quick mirror v1.5's -b/-q; there is no -zx0-classic), and
;     produces BYTE-IDENTICAL output to z88dk-zx0 on the same input:
;     30720 bytes of Rabenstein art -> 6563 bytes from both. ZX0 is an
;     optimal compressor, so two independent binaries agreeing exactly
;     means one format and one encoder generation.
;   - this decoder came from the z88dk tree shipping that same v1.5
;     tool, so encoder and decoder match by construction.
; A ZX0 stream carries NO magic number and NO version field, so
; upgrading either tool to v2 would break picture loading SILENTLY -
; corrupt output or a bare zx0_fail, with nothing pointing at the
; compressor. Re-run the byte-identical comparison above after any
; tool bump. Control flow, the
; interlaced-Elias reader and the negative-offset arithmetic are kept
; verbatim; only the three memory primitives differ, because here
; neither the source nor the destination is flat memory:
;
;   upstream                    this port
;   ld a,(hl)/inc hl (source) = zx0_src_byte  (resident-ish chunk buf)
;   ldir to DE       (dest)   = zx0_dst_write (slot 6 window, banked)
;   ldir from DE-off (match)  = zx0_ref_read  (slot 6 window, banked)
;
; Banked windowing scheme (the scheme the loader lives or dies by):
; slot 6 ($C000, the ONLY data window - slot 7 holds this overlay's
; code) belongs to the DESTINATION. DE walks the mapped 8K dest page;
; zx0DstOrd counts which ordinal page of the destination run that is,
; and zx0MapOrd remembers which ordinal is actually mapped so remaps
; are lazy. The compressed SOURCE never needs the window at the same
; time: zx0_src_byte hands out bytes from a chunk buffer (gfxRowBuf -
; idle during loads, addressable at $Exxx in this overlay page) which
; zx0_chunk_refill refills from the scratch banks, briefly stealing
; slot 6 and invalidating zx0MapOrd so the next dest access remaps.
; Invariants:
;   - slot 6 holds the zx0MapOrd-th dest page, except inside
;     zx0_chunk_refill (which sets zx0MapOrd = $FF on exit);
;   - DE is always inside $C000..$E000; $E000 means "page full, step
;     pending" and is normalised by the next write or match setup;
;   - back-references are served BYTE BY BYTE in ascending order -
;     exactly LDIR's semantics, so overlapped (RLE) matches are
;     correct - with zx0_ref_read/zx0_dst_write each remapping slot 6
;     to their own page only when zx0MapOrd says it is not theirs
;     (same-page matches, the common case, run remap-free);
;   - bit-accumulator reloads happen ONLY at Elias stop-bit reads,
;     exactly as upstream (whose plain add-a,a discriminator/data-bit
;     reads have no reload path either): a ZX0 stream never drains the
;     accumulator at those reads - verified over the whole Rabenstein
;     corpus plus gfx2next -zx0 output with an instrumented model
;     decoder before porting.
;
; Failure discipline: any fault (source exhausted mid-stream, output
; past the 6-bank cap, bank/arena exhaustion, match offset before the
; output start) jumps to zx0_fail, which rewinds SP to the snapshot
; gfx_depack took and exits CF set; gfx_load's rollback then frees
; scratch and destination banks alike. The compressed INPUT was capped
; by gfx_read_banks' own 6-bank (96K) ceiling - generous, since ZX0
; output is never usefully larger than the 82432-byte raw maximum.

GFX_ZX0_CHUNK   equ 320         ; chunk buffer size = gfxRowBuf's
GFX_DST_ORD_MAX equ 12          ; dest cap: 6 banks x 2 pages, the same
                                ; ceiling gfx_read_banks puts on raw art

; Depack the streamed compressed file. In: the scratch run described
; by gfxArenaStart/gfxBankCount/gfxSizeHi:Lo (gfx_read_banks' output).
; Decompresses every back-to-back ZX0 stream in it (gfx2next -zx0
; emits two - palette then pixels; a z88dk-zx0 whole-file pass emits
; one) into freshly allocated banks appended after the scratch run,
; then frees the scratch banks, slides the destination bank numbers
; down over their arena slots and rewinds the cursor - so on success
; gfxArenaStart/gfxBankCount/gfxSize* describe a decompressed run
; byte-identical to a raw file load. Out: CF clear on success; CF set
; on any failure, all appended banks (scratch + dest) left for
; gfx_load_rollback, which the caller runs. Brackets slot 6 with
; data_save/data_restore. Corrupts everything.
gfx_depack:
    call data_save
    ld (zx0DepackSP), sp        ; zx0_fail's longjmp target
    ; source stream = the scratch run, from its first byte
    ld a, (gfxArenaStart)
    ld (zx0SrcIdx), a
    xor a
    ld (zx0SrcHalf), a
    ld hl, DATA_WINDOW
    ld (zx0SrcRd), hl
    ld hl, (gfxSizeLo)
    ld (zx0SrcLeft), hl
    ld a, (gfxSizeHi)
    ld (zx0SrcLeft+2), a
    ld hl, gfxRowBuf            ; empty chunk: the first fetch refills
    ld (zx0ChunkPtr), hl
    ld (zx0ChunkEnd), hl
    ; destination run appends to the arena after the scratch run
    ld a, (gfxBankNext)
    ld (zx0DstStart), a
    xor a
    ld (zx0DstCount), a
    ld (zx0DstOrd), a
    call zx0_dst_bank_alloc     ; ordinal 0 needs its bank up front
    ld a, $FF
    ld (zx0MapOrd), a           ; nothing mapped yet
    ld de, DATA_WINDOW
.stream:
    call dzx0_banked            ; one self-terminating stream
    ; unconsumed compressed bytes mean another stream follows
    ld hl, (zx0ChunkEnd)
    push de
    ld de, (zx0ChunkPtr)
    or a
    sbc hl, de
    pop de
    jr nz, .stream              ; chunk buffer not drained
    ld a, (zx0SrcLeft+2)
    ld hl, (zx0SrcLeft)
    or h
    or l
    jr nz, .stream              ; scratch banks not drained
    ; success: decompressed total = zx0DstOrd*$2000 + (DE - $C000),
    ; a 24-bit value (max 98304)
    ld a, d
    sub high DATA_WINDOW
    ld h, a                     ; H:L = bytes into the current page
    ld l, e                     ; (H = $20 when DE sits at $E000)
    ld a, (zx0DstOrd)
    ld c, a
    and 7
    add a, a
    add a, a
    add a, a
    add a, a
    add a, a                    ; (ord & 7) << 5
    add a, h
    ld h, a
    ld a, 0                     ; keep the carry for the high byte
    adc a, a
    ld b, a
    ld a, c
    srl a
    srl a
    srl a                       ; ord >> 3
    add a, b
    ld (gfxSizeHi), a
    ld (gfxSizeLo), hl
    ; swap the arena runs: free the scratch banks, slide the dest bank
    ; numbers down over their slots, rewind the cursor - the committed
    ; entry then points at a dense run at the same gfxArenaStart
    ld a, (zx0DstStart)
    ld hl, gfxArenaStart
    sub (hl)
    ld b, a                     ; B = scratch bank count (>= 1)
    ld a, (gfxArenaStart)
    ld hl, gfxBankList
    add hl, a
    push hl                     ; slide destination
.freescratch:
    ld a, (hl)
    call bank_free              ; preserves BC, DE, HL (banks.asm)
    inc hl
    djnz .freescratch
    pop de                      ; HL ran up to the dest run's numbers
    ld a, (zx0DstCount)
    ld c, a
    ld b, 0
    ldir
    ld a, (gfxArenaStart)
    ld hl, zx0DstCount
    add a, (hl)
    ld (gfxBankNext), a
    ld a, (zx0DstCount)
    ld (gfxBankCount), a
    call data_restore
    or a
    ret
.fail:                          ; zx0_fail lands here, SP already rewound
    call data_restore
    scf
    ret

; Abort the depack from any depth: rewind SP to gfx_depack's snapshot
; and exit through its failure path. Never returns to the caller.
zx0_fail:
    ld sp, (zx0DepackSP)
    jr gfx_depack.fail

; One ZX0 stream (dzx0_standard's main loop, primitives swapped as per
; the scheme comment). In: DE = dest window cursor, dest/source state
; live. Out: DE advanced past the stream's output; BC = end-marker
; residue. A carries the bit accumulator throughout, parked in AF'
; around byte-copy loops and the new-offset arithmetic (upstream parks
; it there transiently too). Corrupts AF, AF', BC, HL.
dzx0_banked:
    ld hl, $FFFF                ; initial offset = 1, negative form -
    ld (zx0Offset), hl          ; upstream's `ld bc,$ffff / push bc`
    ld bc, 0
    ld a, $80                   ; empty accumulator: sentinel bit only
.literals:
    call zx0_elias              ; BC = literal count
    ex af, af'                  ; park the accumulator
.litcopy:
    call zx0_src_byte
    call zx0_dst_write
    dec bc
    ld a, b
    or c
    jr nz, .litcopy
    ex af, af'
    add a, a                    ; copy from last offset or new offset?
    jr c, .newoffset
    call zx0_elias              ; BC = copy length
    call .copy
    add a, a                    ; copy from literals or new offset?
    jr nc, .literals
.newoffset:
    call zx0_elias              ; BC = offset MSB (Elias value)
    ex af, af'                  ; park accumulator + its CF=1 (ret c)
    xor a
    sub c                       ; A = -MSB
    ret z                       ; C = 0 (value 256): end-of-stream
    ld b, a
    call zx0_src_byte           ; A = offset LSB (safe: the accumulator
    ld c, a                     ; and its carry sit parked in AF')
    ex af, af'                  ; accumulator back, CF = 1 again
    rr b                        ; BC = negative offset; the bit shifted
    rr c                        ; out of C = the first length bit
    ld (zx0Offset), bc
    ld bc, 1
    call nc, zx0_elias_bt       ; length gamma continues on a 0 bit
    inc bc
    call .copy
    add a, a                    ; copy from literals or new offset?
    jr c, .newoffset
    jr .literals
; copy BC match bytes from (write position + zx0Offset), strictly
; ascending byte order = LDIR semantics, overlap-safe
.copy:
    ex af, af'                  ; park the accumulator
    call zx0_ref_setup
.cploop:
    call zx0_ref_read
    call zx0_dst_write
    dec bc
    ld a, b
    or c
    jr nz, .cploop
    ex af, af'
    ret

; Interlaced Elias gamma read (upstream dzx0s_elias, source fetch
; through the chunk buffer). In: BC = 0 (zx0_elias) or 1 with the
; first data bit consumed (zx0_elias_bt), A = bit accumulator. Out:
; BC = value, CF set, accumulator updated. Corrupts F, HL.
zx0_elias:
    inc c
.loop:
    add a, a                    ; stop bit
    jr nz, .skip
    ; accumulator drained - the shifted-out bit was the bit-0 sentinel
    ; (always 1); fetch 8 fresh bits and re-supply the sentinel by scf,
    ; standing in for upstream's carried-over rla input
    call zx0_src_byte
    scf
    rla
.skip:
    ret c
zx0_elias_bt:
    add a, a                    ; data bit (never drains here - stream
    rl c                        ; invariant, see the scheme comment)
    rl b
    jr zx0_elias.loop

; Next compressed byte through the chunk buffer. Out: A = byte.
; Preserves BC, DE. Corrupts F, HL.
zx0_src_byte:
    ld hl, (zx0ChunkPtr)
    push de
    ld de, (zx0ChunkEnd)
    or a
    sbc hl, de
    pop de
    call z, zx0_chunk_refill
    ld hl, (zx0ChunkPtr)
    ld a, (hl)
    inc hl
    ld (zx0ChunkPtr), hl
    ret

; Refill gfxRowBuf (dual use: the blit row bounce buffer is idle
; during loads) with the next run of compressed bytes from the scratch
; banks. Steals slot 6 for the copy and invalidates zx0MapOrd so the
; next destination access remaps. Fails via zx0_fail when the stream
; demands bytes the file does not have. Preserves BC, DE. Corrupts
; AF, HL.
zx0_chunk_refill:
    push bc
    push de
    ld a, (zx0SrcLeft+2)
    ld hl, (zx0SrcLeft)
    or h
    or l
    jp z, zx0_fail              ; source exhausted mid-stream
    ld hl, (zx0SrcRd)
    ld a, h
    cp high GFX_SRC_END
    jr c, .have
    ; scratch page drained: upper half, then the run's next bank
    ld hl, zx0SrcHalf
    ld a, (hl)
    xor 1
    ld (hl), a
    jr nz, .rewind
    ld hl, zx0SrcIdx
    inc (hl)
.rewind:
    ld hl, DATA_WINDOW
    ld (zx0SrcRd), hl
.have:
    ld hl, gfxBankList
    ld a, (zx0SrcIdx)
    add hl, a
    ld a, (hl)
    add a, a
    ld hl, zx0SrcHalf
    add a, (hl)
    call data_map_page
    ld a, $FF
    ld (zx0MapOrd), a           ; slot 6 no longer holds a dest page
    ; count = min(page remainder, chunk capacity, source remainder)
    ld hl, GFX_SRC_END
    ld de, (zx0SrcRd)
    or a
    sbc hl, de                  ; page remainder (1..8192)
    ld de, GFX_ZX0_CHUNK
    or a
    sbc hl, de
    jr c, .cap1
    ld hl, 0                    ; min(HL, DE) idiom: HL-DE kept only
.cap1:                          ; when negative, DE added back
    add hl, de
    ld a, (zx0SrcLeft+2)
    or a
    jr nz, .fits                ; 64K+ unread: no source clamp needed
    ld de, (zx0SrcLeft)
    or a
    sbc hl, de
    jr c, .cap2
    ld hl, 0
.cap2:
    add hl, de
.fits:
    ld b, h                     ; BC = refill count (>= 1)
    ld c, l
    push bc
    ld hl, (zx0SrcRd)
    ld de, gfxRowBuf
    ldir
    ld (zx0SrcRd), hl           ; may land on GFX_SRC_END - the next
                                ; refill's page check advances then
    ld (zx0ChunkEnd), de
    ld hl, gfxRowBuf
    ld (zx0ChunkPtr), hl
    pop bc
    ld hl, (zx0SrcLeft)         ; 24-bit source remainder -= count
    or a
    sbc hl, bc
    ld (zx0SrcLeft), hl
    jr nc, .nb
    ld hl, zx0SrcLeft+2
    dec (hl)
.nb:
    pop de
    pop bc
    ret

; Write A to the destination stream through slot 6, stepping pages
; (and allocating destination banks) as the run grows. In/out: DE =
; window cursor. Preserves A, BC. Corrupts F, HL.
zx0_dst_write:
    push af
    ld a, d
    cp high GFX_SRC_END
    call nc, zx0_dst_advance    ; page full: step, DE = window base
    ld a, (zx0DstOrd)
    ld hl, zx0MapOrd
    cp (hl)
    call nz, zx0_map_ord
    pop af
    ld (de), a
    inc de
    ret

; Step the destination cursor to its next 8K page: the current bank's
; upper half on odd ordinals, a freshly allocated bank on even ones.
; Enforces the decompressed-output cap. Out: DE = DATA_WINDOW.
; Preserves BC. Corrupts AF, HL.
zx0_dst_advance:
    ld a, (zx0DstOrd)
    inc a
    ld (zx0DstOrd), a
    cp GFX_DST_ORD_MAX
    jp nc, zx0_fail             ; output overran the 6-bank cap
    bit 0, a
    call z, zx0_dst_bank_alloc  ; even ordinal: a new bank
    ld de, DATA_WINDOW
    ret

; Allocate one destination bank and append it to the arena run.
; gfx_bank_get may evict cache entries mid-depack: that only touches
; resident tables (the physical banks never move, slot 6's mapping
; stays valid), and gfx_evict_fix rebases zx0SrcIdx/zx0DstStart/
; gfxArenaStart to follow the compacted arena, so the depack cursors
; stay coherent. Preserves BC, DE. Corrupts AF, HL.
zx0_dst_bank_alloc:
    push bc
    push de                     ; eviction corrupts DE
    call gfx_bank_get           ; out: A = 16K bank; CF = exhausted
    pop de
    jp c, zx0_fail              ; (zx0_fail rewinds SP - the pushed BC
                                ; is reclaimed by the rewind)
    ld c, a
    ld hl, gfxBankList
    ld a, (gfxBankNext)
    add hl, a
    ld (hl), c
    inc a
    ld (gfxBankNext), a
    ld hl, zx0DstCount
    inc (hl)
    pop bc
    ret

; Map destination-run ordinal A (0-based 8K page) into slot 6 and
; remember it in zx0MapOrd. Preserves BC, DE. Corrupts AF, HL.
zx0_map_ord:
    ld (zx0MapOrd), a
    push bc
    ld b, a                     ; B = ordinal
    srl a
    ld c, a                     ; C = bank slot within the run
    ld a, (zx0DstStart)
    add a, c                    ; arena index
    ld hl, gfxBankList
    add hl, a
    ld a, (hl)
    add a, a                    ; the bank's lower 8K page
    bit 0, b
    jr z, .map
    inc a                       ; odd ordinal: upper half
.map:
    pop bc
    jp data_map_page

; Aim the back-reference cursor for the next match: ref position =
; 24-bit write position + zx0Offset (held negative, upstream form).
; A pending page step (DE = $E000) is normalised first so the write
; position is single-valued. Fails when the offset reaches before the
; output start (corrupt stream). Preserves BC, DE (bar the pending
; step). Corrupts AF, HL.
zx0_ref_setup:
    ld a, d
    cp high GFX_SRC_END
    call nc, zx0_dst_advance
    push bc
    push de
    ; W = zx0DstOrd*$2000 + (DE - $C000), built as hi:mid:lo = B:H:L
    ld a, (zx0DstOrd)
    ld c, a
    and 7
    add a, a
    add a, a
    add a, a
    add a, a
    add a, a                    ; (ord & 7) << 5
    ld h, a
    ld a, d
    sub high DATA_WINDOW        ; 0..31, disjoint from the field above
    or h
    ld h, a                     ; H = W mid byte
    ld l, e                     ; L = W low byte
    ld a, c
    srl a
    srl a
    srl a
    ld b, a                     ; B = W high byte (ord >> 3)
    ; R = W + negative offset, sign-extended to 24 bits ($FF high)
    ld de, (zx0Offset)
    ld a, l
    add a, e
    ld l, a
    ld a, h
    adc a, d
    ld h, a
    ld a, b
    adc a, $FF
    jp nc, zx0_fail             ; no wrap = offset before output start
    ; A:H:L = R; split into ordinal (R >> 13) and window offset
    add a, a
    add a, a
    add a, a
    ld c, a                     ; R hi << 3
    ld a, h
    and %11100000
    rlca
    rlca
    rlca                        ; R mid >> 5
    or c
    ld (zx0RefOrd), a
    ld a, h
    and $1F
    or high DATA_WINDOW         ; window base + (R & $1FFF)
    ld h, a
    ld (zx0RefPtr), hl
    pop de
    pop bc
    ret

; Read the next back-reference byte from the destination run through
; slot 6, remapping only when the cursor's page is not the mapped one.
; Out: A = byte, cursor advanced. Preserves BC, DE. Corrupts F, HL.
zx0_ref_read:
    ld hl, (zx0RefPtr)
    ld a, h
    cp high GFX_SRC_END
    jr c, .inpage
    ld hl, zx0RefOrd            ; cursor ran off the page: next ordinal
    inc (hl)                    ; (always already allocated - the ref
    ld hl, DATA_WINDOW          ; trails the write position)
    ld (zx0RefPtr), hl
.inpage:
    ld a, (zx0RefOrd)
    ld hl, zx0MapOrd
    cp (hl)
    call nz, zx0_map_ord
    ld hl, (zx0RefPtr)
    ld a, (hl)
    inc hl
    ld (zx0RefPtr), hl
    ret

; Draw the staged cache entry, double-buffered: everything renders to
; the BACK surface (invisible - the old picture stays intact on the
; front throughout), then the surfaces flip. Sequence: stage the mode
; in l2Mode (variable only - the hardware keeps displaying the old
; picture in the old mode), clear the back surface to the transparent
; colour (also pre-clears the remainder below a short picture to
; $FE), copy the pixel rows top-aligned, load the file's embedded
; 512-byte 9-bit palette (deliberately LAST before the flip: the
; palette is global, so the old picture wears the new colours only
; for the ~1ms the load takes instead of the whole render), then
; l2_flip_swap + l2_mode_set - resolution and new front bank land
; back-to-back, no wrong-mode flash (see l2_flip_swap) - and
; l2_enable. No-op when nothing is staged. Corrupts everything.
;
; Walk order: SOURCE-ROWS-SCATTER, chosen over dest-columns-gather.
; The source stream is row-major (Gfx2Next emits rows sequentially);
; the 320-wide surface is column-major (dest = x*256 + y). Slot 6
; remaps per 320x200 picture:
;   rows-scatter:   per row 1 src remap (the 320-byte row crosses an
;                   8K page every 8192/320 = 25.6 rows, +1 then) +
;                   10 dest remaps (page = x>>5 changes every 32
;                   pixels) = ~11.04; 200 rows -> ~2210 remaps, and
;                   both the fetch (LDIR) and the scatter (fixed row
;                   in E, INC D per pixel) are straight-line walks.
;   columns-gather: per column a stride-320 walk of the whole 64000-
;                   byte pixel area = ceil(64000/8192) = 8 src remaps
;                   + 1 dest remap (amortised 1/32 but the alternating
;                   src maps force it every column) = ~9; 320 columns
;                   -> ~2890 remaps, AND a 16-bit stride-add with a
;                   page-crossing test per pixel in the inner loop.
; Scatter wins on both remap count and inner-loop cost. With the back-
; buffer render the paint is no longer visible mid-blit - a DMA upgrade
; (SP8 rider) would now only shorten the redraw latency, not fix an
; artifact. 256-wide mode is trivially linear-to-linear (row-major
; both sides): 2 remaps per row.
gfx_blit:
 IFDEF DMA_MEASURE
    ld hl, (frameCounter)
    ld (dmaMeasT0), hl
 ENDIF
    ld a, (stagedEntry)
    cp GFX_EMPTY
    ret z
    ld a, (stagedMode)
    ld (l2Mode), a              ; variable only - sizes l2_clear_back's
                                ; page count; NR $70/$12 wait for the flip
    ld a, (l2BackBank)
    add a, a
    ld (gfxSurfPage), a         ; render target = the back surface
    call l2_clear_back          ; own data_save/restore - run BEFORE ours
    call data_save
    ; source stream = the entry's bank-list run, from its first page
    ld a, (stagedEntry)
    call gce_ptr
    inc hl
    ld a, (hl)                  ; GCE_FIRST
    ld (gfxSrcIdx), a
    xor a
    ld (gfxSrcHalf), a          ; (no remap needed here - gfx_row_fetch
    ld hl, DATA_WINDOW+512      ; re-asserts the source mapping itself)
    ld (gfxSrcPtr), hl          ; skip the palette (loaded after the rows)
    ld a, (stagedMode)
    or a
    ld de, 256
    jr z, .width
    ld de, 320
.width:
    ld (gfxWidth), de
    ld a, (gfxSurfPage)         ; 256-wide linear dest stream init
    ld (gfxDstPage), a          ; (320-wide scatter reinitialises
    ld hl, DATA_WINDOW          ; gfxDstPage itself every row)
    ld (gfxDstPtr), hl
    xor a
    ld (gfxRowY), a
    ld a, (stagedHeight)
    ld (gfxRowsLeft), a         ; 0 = 256 rows (djnz-style wrap)
.row:
    call gfx_row_fetch
    ld a, (stagedMode)
    or a
    jr z, .linear
    call gfx_row_scatter320
    jr .next
.linear:
    call gfx_row_copy256
.next:
    ld hl, gfxRowY
    inc (hl)
    ld hl, gfxRowsLeft
    dec (hl)
    jr nz, .row
    ; rows done: rewind the source stream to the file's 512-byte
    ; palette (offset 0, wholly inside the run's first page) and load
    ; it now, as late as possible before the flip (header comment)
    ld a, (stagedEntry)
    call gce_ptr
    inc hl
    ld a, (hl)                  ; GCE_FIRST again
    ld (gfxSrcIdx), a
    xor a
    ld (gfxSrcHalf), a
    call gfx_src_remap
    ld hl, DATA_WINDOW
    ld b, 1                     ; format 1 = 256 x 2-byte 9-bit entries
    call l2_palette_load
    call data_restore
    ; flip: swap surface roles, then program resolution + new front
    ; bank back-to-back via l2_mode_set (see l2_flip_swap header)
    call l2_flip_swap
    ld a, (stagedMode)
    call l2_mode_set
 IFDEF DMA_MEASURE
    ld a, (stagedMode)
    or a
    jr z, .measskip               ; only the 320-wide (scatter) path -
                                   ; see gfx_row_scatter320's own header
    ld hl, dmaMeasLblScat
    ld b, 19
    ld c, 0
    call dbg_at
    call dma_meas_report
.measskip:
 ENDIF
    jp l2_enable

; Map the current source page (gfxBankList[gfxSrcIdx]*2 + gfxSrcHalf)
; into slot 6 - the row writers leave slot 6 on a Layer 2 page, so
; each fetch re-asserts the source mapping. Corrupts AF, HL.
gfx_src_remap:
    ld hl, gfxBankList
    ld a, (gfxSrcIdx)
    add hl, a
    ld a, (hl)
    add a, a
    ld hl, gfxSrcHalf
    add a, (hl)
    jp data_map_page

; Advance the source stream to its next 8K page (the bank's upper
; half, then the next bank in the arena run), map it, and rewind
; gfxSrcPtr to the window base. Corrupts AF, HL.
gfx_src_advance:
    ld hl, gfxSrcHalf
    ld a, (hl)
    xor 1
    ld (hl), a
    jr nz, .map                 ; 0 -> 1: same bank, upper page
    ld hl, gfxSrcIdx
    inc (hl)                    ; 1 -> 0: next bank
.map:
    call gfx_src_remap
    ld hl, DATA_WINDOW
    ld (gfxSrcPtr), hl
    ret

; Stage one source row (gfxWidth bytes) from the cache-bank stream
; into gfxRowBuf, crossing 8K page boundaries as needed. Corrupts
; AF, BC, DE, HL.
gfx_row_fetch:
    call gfx_src_remap
    ld de, gfxRowBuf
    ld bc, (gfxWidth)           ; BC = bytes still to stage
.chunk:
    ld hl, (gfxSrcPtr)
    ld a, h
    cp high GFX_SRC_END
    jr c, .have
    call gfx_src_advance        ; previous row drained the page exactly
    ld hl, (gfxSrcPtr)          ; = DATA_WINDOW
.have:
    ; does the whole remainder fit before the window end?
    push hl
    add hl, bc                  ; HL = end = src + remaining (cannot
    ld a, h                     ; carry: src < $E000, remaining <= 320)
    cp high GFX_SRC_END
    jr c, .fits                 ; end < $E000
    jr nz, .nofit               ; end >= $E100
    ld a, l
    or a
    jr z, .fits                 ; end == $E000 exactly: still one page
.nofit:
    pop hl                      ; HL = src
.split:
    ; copy only what this page still holds, then advance
    push bc                     ; remaining
    push de                     ; dest
    ex de, hl
    ld hl, GFX_SRC_END
    or a
    sbc hl, de                  ; HL = bytes left in the page (>= 1)
    ld b, h
    ld c, l
    ex de, hl                   ; HL = src
    pop de                      ; dest
    push bc                     ; left
    ldir
    pop hl                      ; HL = left
    pop bc                      ; BC = remaining
    ld a, c                     ; remaining -= left
    sub l
    ld c, a
    ld a, b
    sbc a, h
    ld b, a
    call gfx_src_advance        ; preserves BC, DE
    jr .chunk
.fits:
    pop hl                      ; HL = src
    ldir
    ld (gfxSrcPtr), hl          ; may land exactly on GFX_SRC_END -
    ret                         ; the next fetch's .chunk check handles it

; Write the staged row to the row-major 256-wide surface: one LDIR to
; the linear destination stream, advancing the dest page every 32
; rows (8192/256; a 256-byte row never splits across pages). Corrupts
; AF, BC, DE, HL.
gfx_row_copy256:
    ld a, (gfxDstPage)
    call data_map_page
    ld hl, gfxRowBuf
    ld de, (gfxDstPtr)
    ld bc, 256                   ; 256 >= GFX_DMA_MIN_LEN unconditionally
    call dma_copy
    ld a, d
    cp high GFX_SRC_END
    jr c, .store
    ld a, (gfxDstPage)
    inc a
    ld (gfxDstPage), a
    ld de, DATA_WINDOW
.store:
    ld (gfxDstPtr), de
    ret

; Write the staged row to the column-major 320-wide surface. Dest
; address of pixel (x, y): 8K page gfxSurfPage + (x >> 5), in-page
; offset (x & 31)*256 + y - so with D = $C0 + (x & 31) and E = y, a
; step of +1 in x is INC D, and the page advances every 32 pixels:
; ten page runs per row. Reuses gfxDstPage as its page cursor (the
; linear 256-wide walk and this one never mix within a blit).
; Corrupts AF, BC, DE, HL.
;
; SP11 Task 2 (DMA): evaluated and rejected here, deliberately left on
; the CPU path unconditionally - no IFDEF, never was one even before
; -NoDmaGfx retired (SP14a T4 follow-up). The inner .px loop's
; destination is NOT contiguous: D (the address high byte) increments
; every byte while E (gfxRowY) stays fixed for all 32 iterations of a
; page, so successive writes land 256 bytes apart. There is no run
; longer than one byte to hand to dma_copy - the
; only "batching" possible would be one DMA chunk per PIXEL, and a
; length-1 chunk costs ~600T of program+dispatch overhead to move one
; byte the CPU's own per-pixel loop body moves for ~37T (ld/inc/ld/inc/
; djnz) - more than an order of magnitude worse, not just a wash. See
; sp11-task-2-report.md "320 scatter" for the full T-state comparison.
gfx_row_scatter320:
    ld hl, gfxRowBuf
    ld a, (gfxSurfPage)
    ld (gfxDstPage), a
    ld c, 10
.page:
    ld a, (gfxDstPage)
    call data_map_page
    ld a, (gfxRowY)
    ld e, a
    ld d, high DATA_WINDOW
    ld b, 32
.px:
    ld a, (hl)
    inc hl
    ld (de), a
    inc d
    djnz .px
    ld a, (gfxDstPage)
    inc a
    ld (gfxDstPage), a
    dec c
    jr nz, .page
    ret

; Extension probe chain, tried in gfx_open_chain order. Row = 7 ASCII
; extension characters (NUL-padded; 7 fits the longest, "NX2.ZX0") +
; the mode byte (0 = 256-wide row-major, 1 = 320-wide column-major;
; mirrors l2Mode's encoding) + the compressed flag (1 = ZX0, load via
; gfx_depack). Per shape the ZX0 variants probe before raw so
; compressed art wins, the Gfx2Next-emitted double extension before
; its 8.3 synonym (kept for plain-FAT/no-LFN setups).
gfxExtTab:
    db "NX2.ZX0",          1, 1
    db "N2Z", 0, 0, 0, 0,  1, 1
    db "NX2", 0, 0, 0, 0,  1, 0
    db "NXI.ZX0",          0, 1
    db "NXZ", 0, 0, 0, 0,  0, 1
    db "NXI", 0, 0, 0, 0,  0, 0
gfxExtEnd:
GFX_EXT_NAME equ 7
GFX_EXT_ROW  equ GFX_EXT_NAME+2

; SP11 T5: PARTn\ prefixed scratch for gfx_open_chain_part, overlay2-
; local. gfxName itself is resident (gfxcache.asm) and exactly 12
; bytes - "sized for the longest probe... the final NUL is never
; overwritten" per its own comment - no slack for a 6-byte "PARTn\"
; prefix, hence a separate buffer here rather than growing it. Layout
; mirrors gfxName exactly, shifted 6: +0-3 "PART", +4 part digit, +5
; '\', +6-8 NNN, +9 '.', +10-16 the 7-byte extension field, +17 the
; final NUL - baked in at assembly (never rewritten at runtime, same
; guarantee gfxName's own trailing NUL provides for the two 7-char
; rows "NX2.ZX0"/"NXI.ZX0" that fill the extension field with no
; internal NUL of their own). 6 (PARTn\) + 12 (gfxName's own size) = 18.
gfxNamePart: ds 17
             db 0

gfxPicNum:     db 0              ; picture being loaded/staged
gfxEntryIdx:   db 0              ; cache slot in use
gfxMode:       db 0              ; candidate mode from the chain row
gfxWidth:      dw 0              ; 320 or 256, per mode
gfxHandle:     db $FF            ; esxDOS handle, $FF = none open
gfxArenaStart: db 0              ; gfxBankNext at load start (rollback point)
gfxBankCount:  db 0              ; banks appended by this load
gfxCurPage:    db 0              ; 8K page being read into
gfxSizeLo:     dw 0              ; 24-bit byte total: gfxSizeHi:gfxSizeLo
gfxSizeHi:     db 0
gfxHeight:     db 0              ; derived rows (0 encodes 256)
gfxExtPtr:     dw 0              ; chain walk cursor
gfxSrcIdx:     db 0              ; blit source: arena index of current bank
gfxSrcHalf:    db 0              ; 0 = lower 8K page, 1 = upper
gfxSrcPtr:     dw 0              ; blit source: window-relative read cursor
gfxSurfPage:   db 0              ; blit dest: first 8K page of the BACK
                                 ; surface, latched at blit start
gfxDstPage:    db 0              ; blit dest: current 8K Layer 2 page
gfxDstPtr:     dw 0              ; blit dest: linear cursor (256-wide mode)
gfxRowY:       db 0              ; current pixel row
gfxRowsLeft:   db 0              ; rows still to copy (initial 0 = 256)
gfxCompressed: db 0              ; candidate row's compressed flag
gfxAllocFail:  db 0              ; 1 = the load failed on TRUE pool
                                 ; exhaustion (gfx_bank_get gave up
                                 ; post-eviction) - gfx_load's
                                 ; direct-stream fallback trigger
gfxRowFull:    db 0              ; direct stream: the 256th row was
                                 ; written (gfxRowY wrapped), only EOF
                                 ; may follow
gfxModeSave:   db 0              ; direct stream: front surface's mode
                                 ; at entry, restored to l2Mode on the
                                 ; failure funnel (no flip happened)
gfxRowBuf:     ds 320            ; row bounce buffer: slot 6 can only hold
                                 ; source OR dest, so each row stages here
                                 ; (in this overlay page - both users above
                                 ; run only with page 58 mapped; sized for
                                 ; the wider 320-pixel row). DUAL USE: the
                                 ; depacker borrows it as the compressed-
                                 ; source chunk buffer (zx0_chunk_refill) -
                                 ; loads and blits never overlap
    ASSERT GFX_ZX0_CHUNK <= 320

; ZX0 depack state (all cursors in memory: the registers belong to the
; vendored dzx0 loop)
zx0SrcIdx:   db 0                ; scratch stream: arena index of its bank
zx0SrcHalf:  db 0                ; 0 = lower 8K page, 1 = upper
zx0SrcRd:    dw 0                ; scratch stream: window read cursor
zx0SrcLeft:  db 0, 0, 0          ; 24-bit compressed bytes not yet chunked
zx0ChunkPtr: dw 0                ; next byte to hand out of gfxRowBuf
zx0ChunkEnd: dw 0                ; end of the chunk's valid bytes
zx0DstStart: db 0                ; arena index of the first dest bank
zx0DstCount: db 0                ; dest banks allocated so far
zx0DstOrd:   db 0                ; dest ordinal 8K page being written
zx0MapOrd:   db 0                ; dest ordinal mapped in slot 6, $FF = none
zx0RefOrd:   db 0                ; back-ref cursor: dest ordinal page
zx0RefPtr:   dw 0                ; back-ref cursor: window offset
zx0Offset:   dw 0                ; current match offset, negative form
zx0DepackSP: dw 0                ; SP snapshot for zx0_fail's rewind

; --- Boot title screen (SP11 Task 1) ---
; Probes for a game-supplied title image (DAAD.* - never numbered, so
; it never competes with the picture cache/numbered-art namespace) and,
; if one exists, shows it with music already playing (aud_boot_probe
; started it before chaining here - see overlay1.asm) until any key is
; pressed. Two entry points:
;   title_present - probe only, for debug.asm's release boot_banner
;     gate (self-contained: no overlay0/overlay1 dependency, esxDOS is
;     already up by boot_banner time - see its call site);
;   title_boot - the full sequence, chained from aud_boot_probe's tail.
; Both are UNCONDITIONAL (no IFDEF DEBUG): the DEBUG build shows its
; diagnostics first, then the title; only the release banner's PRINT is
; gated on title_present, in debug.asm.

TITLE_ROW equ 4                  ; word name ptr + mode byte + compressed byte

; DAAD.* probe order, first hit wins - exactly gfxExtTab's 6 shapes
; (same mode/compressed pairs, see its header for the ZX0-before-raw/
; wide-before-narrow reasoning) against the fixed base name "DAAD"
; instead of a per-picture number, since a title is never numbered.
titleTab:
    dw titleName0
    db 1, 1                       ; DAAD.NX2.ZX0: 320-wide, ZX0
    dw titleName1
    db 1, 1                       ; DAAD.N2Z: 320-wide, ZX0 (8.3 synonym)
    dw titleName2
    db 1, 0                       ; DAAD.NX2: 320-wide, raw
    dw titleName3
    db 0, 1                       ; DAAD.NXI.ZX0: 256-wide, ZX0
    dw titleName4
    db 0, 1                       ; DAAD.NXZ: 256-wide, ZX0 (8.3 synonym)
    dw titleName5
    db 0, 0                       ; DAAD.NXI: 256-wide, raw
titleTabEnd:

titleName0: db "DAAD.NX2.ZX0", 0
titleName1: db "DAAD.N2Z", 0
titleName2: db "DAAD.NX2", 0
titleName3: db "DAAD.NXI.ZX0", 0
titleName4: db "DAAD.NXZ", 0
titleName5: db "DAAD.NXI", 0

titleRowPtr: dw 0                 ; title_probe's table-walk cursor

; Try titleTab's 6 DAAD.* names in order, first hit wins. Out: CF clear
; + the open read handle in gfxHandle, gfxMode/gfxWidth/gfxCompressed
; set from the winning row - exactly what gfx_read_banks needs, and (via
; gfxMode/gfxWidth) what title_blit needs after it; CF set = none of the
; 6 exist, gfxHandle untouched. Touches only the shared gfx* load
; scratch, mirroring gfx_open_chain's own direct-overwrite style (no
; staging: a row that fails to open just gets overwritten by the next
; one) - never gfxCache/gfxBankList/staged* (a probe/load, not a cache
; commit). Corrupts everything.
title_probe:
    ld hl, titleTab
.row:
    ld (titleRowPtr), hl
    ld e, (hl)
    inc hl
    ld d, (hl)                    ; DE = name pointer
    inc hl
    ld a, (hl)                    ; row's mode byte
    ld (gfxMode), a
    inc hl
    ld a, (hl)                    ; row's compressed byte
    ld (gfxCompressed), a
    ld a, (gfxMode)
    ld hl, 256
    or a
    jr z, .width
    ld hl, 320
.width:
    ld (gfxWidth), hl
    push de
    call esx_getsetdrv            ; A = default drive, CF = error
    pop hl                        ; HL = name pointer
    jr c, .next
    push hl
    pop ix                        ; IX = name pointer
    ld b, ESX_MODE_READ
    call esx_fopen
    jr nc, .opened
.next:
    ld hl, (titleRowPtr)
    ld de, TITLE_ROW
    add hl, de
    push hl
    ld de, titleTabEnd
    or a
    sbc hl, de
    pop hl
    jr nz, .row
    scf                           ; chain exhausted
    ret
.opened:
    ld (gfxHandle), a
    or a
    ret

; Boot-banner presence gate (debug.asm's release boot_banner): probes
; the same 6 DAAD.* names as title_boot but only wants the verdict, so
; the handle title_probe opens is closed again immediately rather than
; carried into a load. Out: CF clear = a title is staged for boot (the
; banner print is skipped - the title itself becomes the first thing
; the player sees); CF set = none of the 6 exist (boot proceeds exactly
; as before). Corrupts AF, BC, DE, HL only - IX is saved/restored
; around title_probe's esxDOS calls so that holds regardless of what
; esx_fopen/esx_fclose do to it.
title_present:
    push ix
    call title_probe
    jr c, .none
    ld a, (gfxHandle)
    call esx_fclose
    ld a, $FF
    ld (gfxHandle), a
    or a
    jr .ret
.none:
    scf
.ret:
    pop ix
    ret

; Full boot title sequence, chained from aud_boot_probe's tail
; (overlay1.asm) via the ovl_map_page trampoline, entered with
; OVL2_PAGE freshly mapped at MMU7. Probes the 6 DAAD.* names
; (title_probe); CF set (none staged) is a normal, silent, fail-quiet
; return - a game shipping no title boots exactly as before, and no
; DEBUG marker fires (absence is normal here, unlike a numbered PICTURE
; miss). On a hit: streams into scratch banks (gfx_read_banks), depacks
; them if the row was ZX0 (gfx_depack - skipped for a raw hit, the same
; call-nz idiom gfx_load uses), derives the row count
; (gfx_derive_height), then title_blit (below) blits the run straight
; off gfxArenaStart to the Layer 2 BACK surface and flips - gfx_load's
; own cache-miss pipeline, stopping short of a cache commit.
; gfx_direct_stream (location art's OWN transient fallback) is
; deliberately NOT reused here, even for a raw hit: partway through, it
; closes and REOPENS the file via gfx_open_chain to reach the palette
; (F_SEEK unproven, see its own header) - and gfx_open_chain
; unconditionally rebuilds a "NNN.ext" 3-DIGIT name from gfxPicNum,
; which can never spell "DAAD". The bank-based path never reopens
; anything (gfxHandle is closed exactly once, by gfx_read_banks, and
; never touched again), so it has no such dependency. gfx_load_rollback
; frees the banks immediately after the blit either way - transient,
; nothing here ever touches gfxCache/stagedPic/stagedEntry. Ends with
; the picture flipped visible, then the any-key wait (wait_key,
; print.asm/SP4 - unconditional, no DAAD flag/timeout dependency, since
; flags/eng_init_game haven't run yet), then h_display's own non-zero
; (clear+flip) shape so the game starts on a clean Layer 2 with no
; title art left behind. Music keeps playing throughout -
; aud_boot_probe already started it, nothing here touches audio.
; Returns via a threaded one-way hop into overlay0's pointer_load (SP12
; T3, the shared .toPointer tail below), whose own plain ret then pops
; whatever was on the stack before this whole chain began - thanks to
; the chain's stack trick (overlay1.asm), that is still aud_boot_probe's
; own caller (main.asm), unchanged from before SP12 T3 - the same final
; ret target, just reached one hop later. MMU7 is left mapped OVL0_PAGE
; afterward, harmless (main.asm/eng_run don't care what overlay page is
; mapped - the same precedent as switch_to_part's own chain tail,
; overlay0.asm). Corrupts everything.
; SP12 T1: font_load is called on EVERY exit below (the title-absent
; early path via .noTitle, the mid-load-failure .rollback path also via
; .noTitle, and the after-keypress success path just before its own
; tail-jump) - the SP11 T1 exit-coverage lesson (an early ret that skips
; a chain call silently loses the feature for a whole class of games).
; SP12 T3 threads pointer_load the exact same way, through .toPointer:
; the after-keypress path now CALLs h_display (was a tail-jump) so its
; own ret lands back here in OVL2, letting it fall into the same shared
; trampoline the other two exits use, rather than needing a second,
; separate hop back from OVL0 into OVL2 just to reach h_display (which
; physically lives in this overlay page and cannot execute correctly
; while MMU7 holds pointer_load's OVL0_PAGE).
; The release banner and DEBUG diagnostics (debug.asm) render BEFORE
; this point, still in the embedded font by design - they are
; interpreter furniture, not game text; everything from here on
; (the title screen has no text of its own, so in practice this means
; the game's own first text) uses the custom font, once loaded.
title_boot:
    call title_probe
    jr c, .noTitle                ; no DAAD.* staged: silent, normal boot
    call gfx_read_banks            ; -> scratch banks (closes the
                                   ; handle on every path)
    jr c, .rollback
    ld a, (gfxCompressed)
    or a                          ; also clears CF for the skip case
    call nz, gfx_depack            ; scratch -> fresh decompressed run
                                   ; (skipped for a raw hit)
    jr c, .rollback
    call gfx_derive_height
    jr c, .rollback
    call title_blit                ; run -> BACK surface, flip (never
                                   ; fails, see its header)
    call gfx_load_rollback         ; transient: hand the banks straight
                                   ; back - no cache entry ever existed
    call wait_key                  ; block for any key (print.asm)
    call font_load                 ; after-keypress path (see header note)
    ld b, 1
    call h_display                 ; h_display's non-zero shape: clear
                                   ; BACK + flip + NR $12 - drops the
                                   ; title art before the game's first
                                   ; draw. SP12 T3: CALL, not the former
                                   ; tail-jump - its own ret now lands
                                   ; right below, still in OVL2, so this
                                   ; path can join the shared pointer-load
                                   ; tail like the other two exits do.
    jr .toPointer
.rollback:
    call gfx_load_rollback
.noTitle:                          ; common exit: title-absent early
                                   ; path falls in here directly, a mid-
                                   ; load failure falls in via .rollback
                                   ; just above - both silent, normal
                                   ; boot either way
    call font_load
.toPointer:                        ; SP12 T3: one-way OVL2->OVL0 hop -
                                   ; font_load/h_display are already this
                                   ; page, but pointer_load lives in
                                   ; overlay0, so it needs the established
                                   ; trampoline (push target, ld a,
                                   ; OVL0_PAGE, jp ovl_map_page - the
                                   ; switch_to_part precedent, overlay0.
                                   ; asm). See this routine's header for
                                   ; where pointer_load's own ret finally
                                   ; lands.
    ld hl, pointer_load
    push hl
    ld a, OVL0_PAGE
    jp ovl_map_page

; Blit a freshly loaded/depacked TRANSIENT run (gfxArenaStart,
; gfxBankCount banks; gfxMode/gfxHeight from title_probe/
; gfx_derive_height) to the Layer 2 BACK surface and flip - gfx_blit's
; body, minus the cache lookup: the run's first bank index is
; gfxArenaStart directly (exactly what gfx_load would have written as
; GCE_FIRST had it committed a cache entry - see gfx_load's commit
; block above), so no gce_ptr indirection and no cache slot is ever
; touched. Only called after gfx_read_banks + gfx_depack +
; gfx_derive_height have all succeeded. Corrupts everything.
title_blit:
    ld a, (gfxMode)
    ld (l2Mode), a                ; variable only - sizes l2_clear_back's
                                   ; page count; NR $70/$12 wait for the flip
    ld a, (l2BackBank)
    add a, a
    ld (gfxSurfPage), a
    call l2_clear_back             ; own data_save/restore - run BEFORE ours
    call data_save
    ld a, (gfxArenaStart)
    ld (gfxSrcIdx), a
    xor a
    ld (gfxSrcHalf), a
    ld hl, DATA_WINDOW+512         ; skip the palette (loaded after the rows)
    ld (gfxSrcPtr), hl
    ld a, (gfxMode)
    or a
    ld de, 256
    jr z, .width
    ld de, 320
.width:
    ld (gfxWidth), de
    ld a, (gfxSurfPage)            ; 256-wide linear dest stream init
    ld (gfxDstPage), a             ; (320-wide scatter reinitialises
    ld hl, DATA_WINDOW              ; gfxDstPage itself every row)
    ld (gfxDstPtr), hl
    xor a
    ld (gfxRowY), a
    ld a, (gfxHeight)
    ld (gfxRowsLeft), a            ; 0 = 256 rows (djnz-style wrap)
.row:
    call gfx_row_fetch
    ld a, (gfxMode)
    or a
    jr z, .linear
    call gfx_row_scatter320
    jr .next
.linear:
    call gfx_row_copy256
.next:
    ld hl, gfxRowY
    inc (hl)
    ld hl, gfxRowsLeft
    dec (hl)
    jr nz, .row
    ; rows done: rewind the source stream to the run's 512-byte palette
    ; (offset 0, wholly inside the run's first page) and load it now,
    ; as late as possible before the flip (mirrors gfx_blit)
    ld a, (gfxArenaStart)
    ld (gfxSrcIdx), a
    xor a
    ld (gfxSrcHalf), a
    call gfx_src_remap
    ld hl, DATA_WINDOW
    ld b, 1                       ; format 1 = 256 x 2-byte 9-bit entries
    call l2_palette_load
    call data_restore
    ; flip: swap surface roles, then program resolution + new front
    ; bank back-to-back via l2_mode_set (see l2_flip_swap header)
    call l2_flip_swap
    ld a, (gfxMode)
    call l2_mode_set
    jp l2_enable

; --- SP12 Task 1: custom font load (boot + part switch) ---
;
; Step 1 ground truth (tilemap.asm, read-only): tm_font_init installs
; the RESIDENT embedded font (fontData, an INCBIN of src/font.chr - 2048
; bytes, tracked in git, NOT the gitignored toolchain path a prior
; review suspected) into TM_DEFS ($7400, nextdaad.inc) via a plain ldir
; with no esxDOS involvement (its former root-only GAME.CHR overlay
; probe was retired in SP12 T1; this routine mirrors the 2048-byte
; exact-size validation that probe pioneered).
; TM_DEFS is 256 glyphs x 8 rows, 1bpp, stored verbatim - no expansion/
; conversion, so "install" is always a straight 2048-byte copy. TM_DEFS
; sits in bank 5, permanently mapped at CPU slot 3 ($6000-$7FFF)
; regardless of which overlay (0/1/2) MMU7 currently holds, so it is
; reachable by a plain ldir from here exactly as it is from tilemap.asm
; or overlay0.asm - no banking dance needed for the WRITE side. FONT.CHR
; below is the ONLY custom-font mechanism (the legacy boot-time GAME.CHR
; probe was retired in SP12 T1): a PARTn-aware override that replaces
; whatever tm_font_init installed (always the embedded font) - there is
; only ever one installed font (a later multi-font feature reloads,
; never multiplies), so no attribute/palette state needs re-deriving
; after the swap (tmAttr and the tilemap palette are independent of the
; glyph bitmaps).
;
; Load a custom font: PARTn\FONT.CHR (curPart >= 2) then FONT.CHR,
; standard DAAD 2048-byte charset (256 chars x 8 rows, 1bpp). Absent =
; silent (the embedded font stays); wrong size = silent + DEBUG
; marker. Never esx_fread's straight into TM_DEFS: a short/failed read
; must never corrupt the live glyph table the tilemap may be actively
; displaying (mid-game part switch), so the file lands in a transient
; bank_alloc'd 16K scratch bank first (mapped into slot 6/DATA_WINDOW
; via data_save/data_map_page - ext_xmes's own idiom, overlay0.asm) and
; is only ldir'd into TM_DEFS once the exact size is confirmed - scratch-
; then-install. Exact-size validation (BC checked, not CF alone - the
; F_READ/F_WRITE count lesson) plus the 1-byte-overshoot probe mirror
; tm_font_init's own GAME.CHR check byte for byte. Corrupts AF, BC, DE,
; HL, IX.
font_load:
    ld a, (curPart)
    dec a
    jr z, .rootonly              ; curPart == 1: skip straight to the
                                  ; root name (T5 idiom, gfx_open_chain)
    ld hl, fontNamePart
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
    inc hl                        ; hl = fontNamePart+6
    ex de, hl
    ld hl, fontName                ; copy "FONT.CHR",0 verbatim (9 bytes)
    ld bc, 9
    ldir
    call esx_getsetdrv
    jr c, .rootonly
    ld ix, fontNamePart
    ld b, ESX_MODE_READ
    call esx_fopen
    jr nc, .opened
.rootonly:                        ; ORIGINAL (non-PARTn) name, reached
                                  ; both when curPart == 1 and as the
                                  ; PARTn\ fallback above
    call esx_getsetdrv
    ret c                         ; no drive at all: silent, table untouched
    ld ix, fontName
    ld b, ESX_MODE_READ
    call esx_fopen
    ret c                         ; no FONT.CHR either: silent, table untouched
.opened:
    ld (fontHandle), a
    call bank_alloc                ; transient scratch bank (banks.asm)
    jr nc, .haveBank
    ld a, (fontHandle)
    call esx_fclose
    ret                            ; no free bank: silent, table untouched
.haveBank:
    ld (fontBank), a
    call data_save
    ld a, (fontBank)
    add a, a                       ; 16K bank -> its lower 8K page
    call data_map_page
    ld a, (fontHandle)
    ld ix, DATA_WINDOW
    ld bc, 2048
    call esx_fread
    jr c, .bad
    ld a, b                        ; exactly 2048 read? (BC discipline -
    cp 8                           ; CF alone lies, the F_READ/F_WRITE
    jr nz, .bad                    ; count lesson; mirrors tm_font_init)
    ld a, c
    or a
    jr nz, .bad
    ld a, (fontHandle)              ; probe for a 2049th byte - size must
    ld ix, DATA_WINDOW+2048         ; be exact, not just >= 2048 (same
    ld bc, 1                        ; probe tm_font_init itself runs)
    call esx_fread
    jr c, .bad
    ld a, b
    or c
    jr nz, .bad                     ; a successful 1-byte read here means
                                    ; the file is LONGER than 2048: reject
    ld hl, DATA_WINDOW               ; exact size confirmed - scratch ->
    ld de, TM_DEFS                   ; live table (the only write to
    ld bc, 2048                      ; TM_DEFS anywhere in this routine)
    ldir
    jr .close
.bad:
 IFDEF DEBUG                        ; wrong size: no-op with a marker,
    ld b, 29                        ; same idiom as h_sfx/h_mouse's
    ld c, 70                        ; unknown-sub-command markers (and
    call dbg_at                     ; the retired GAME.CHR probe's old
    ld hl, msgFontBad                ; wrong-size rejection idiom)
    call dbg_puts
 ENDIF
.close:
    ld a, (fontBank)
    call bank_free
    call data_restore
    ld a, (fontHandle)
    call esx_fclose
    ret

; Part-switch tail: reload the (possibly per-part) font, then chain to
; the SFB re-probe in overlay1; eng_run is already on the stack (pushed
; by switch_to_part, overlay0.asm) - the SFB routine's final ret lands
; there once this whole chain finishes (T3's chained-hop precedent).
; Corrupts everything.
font_load_switch:
    call font_load
    ld hl, aud_load_sfb
    push hl
    ld a, OVL1_PAGE
    jp ovl_map_page

; SP12 T1 font-load state, overlay2-local - parallel to gfxHandle/
; gfxNamePart's own PARTn machinery above, but see font_load's header
; for why the read never targets TM_DEFS directly.
fontHandle:   db $FF              ; esxDOS handle, $FF = none open
fontBank:     db $FF              ; transient scratch 16K bank while held
; "PARTn\FONT.CHR",0 = 6 ("PARTn\") + 9 ("FONT.CHR",0) = 15 bytes
fontNamePart: ds 15
fontName:     db "FONT.CHR", 0    ; root fallback name AND the PARTn\
                                  ; suffix (copied into fontNamePart+6,
                                  ; 9 bytes - the xmsName/ext_xmes reuse)
msgFontBad:   db "FONT BAD", 0

; --- DEBUG bring-up test card ---
; Owner-driven hardware verification hook, wired from debug.asm's
; l2_dbg_hook (holding T at boot, see that file for the key protocol).
; Not reached from anywhere else; safe to strip along with the rest
; of the IFDEF DEBUG block for a release build.
;
; Double-buffer split: these diagnostics draw to the CURRENT FRONT
; surface directly (l2FrontBank - immediately visible, no flip step);
; gfx_blit alone renders to the back surface and flips. Both boot
; hooks run before any game blit, so front here is always banks 9-13
; in practice - the variable (rather than the constant) just keeps a
; warm re-entry with a stale flip state coherent until boot_data_init
; resets it.

 IFDEF DEBUG

TC_MARK_COLOUR equ 255           ; distinct from the gradient's low end

; A = 0 (256x192) or 1 (320x256) on entry. Clears the tilemap over the
; card area to the reserved transparent attribute (tm_clear_transparent,
; tilemap.asm; the bottom TWO rows are left for debug.asm's status
; lines), then delegates to l2_bareprobe_draw for the L2 recipe + draw.
; Uses the Next's default identity Layer 2 palette (index N = colour N
; out of reset, chapter-next-palette.tex line 18) so no palette load is
; needed. The card-area clear and the 320-mode 240-line bound (see
; tc_gradient_320) keep Layer 2 transparent wherever the tilemap has
; real content, so text and picture coexist with the picture on top.
; Corrupts everything.
l2_testcard:
    push af
    ld b, 0
    ld c, 0
    ld d, TM_ROWS-2               ; card area only; bottom TWO rows are
    ld e, TM_COLS                 ; debug.asm's status lines, left opaque
    call tm_clear_transparent
    pop af
    jp l2_bareprobe_draw

; A = 0/1 as above. The L2 recipe (mode_set incl. clip+scroll, enable
; incl. priority, clear-to-transparent) plus the gradient + corner-
; marker draw - l2_testcard's guts MINUS the tilemap-transparent clear.
; Split out for the bare-metal isolation ladder (debug.asm's
; l2_bareprobe_hook): its stages 0-1 have no tilemap yet, so they call
; this directly instead of l2_testcard. Corrupts everything.
l2_bareprobe_draw:
    push af
    call l2_mode_set
    call l2_enable
    call l2_clear
    pop af
    or a
    jr nz, .tc320
    call tc_gradient_256
    call tc_mark_256
    ret
.tc320:
    call tc_gradient_320
    call tc_mark_320
    ret

; A = ladder stage (0-3). Draws (stage+1) filled 16x16-pixel blocks,
; TC_MARK_COLOUR, side by side (20px stride) in the top-left corner -
; the only way to show the stage number when stages 0-1 of the ladder
; have no tilemap. Works in both modes: a square block near the origin
; fits inside the front surface's first 8K page whether the surface
; is row- or column-major (see tc_mark). Corrupts everything.
l2_bareprobe_marker:
    inc a                        ; stage -> block count (1-4)
    ld (l2BpBlockCnt), a
    call data_save
    ld a, (l2FrontBank)
    add a, a
    call data_map_page
    ld hl, DATA_WINDOW
.block:
    push hl
    ld a, 16
    ld (l2BpRowCnt), a
.row:
    push hl
    ld b, 16
.px:
    ld (hl), TC_MARK_COLOUR
    inc hl
    djnz .px
    pop hl
    ld de, 256
    add hl, de
    ld a, (l2BpRowCnt)
    dec a
    ld (l2BpRowCnt), a
    jr nz, .row
    pop hl
    ld de, 20
    add hl, de
    ld a, (l2BpBlockCnt)
    dec a
    ld (l2BpBlockCnt), a
    jr nz, .block
    call data_restore
    ret

l2BpBlockCnt: db 0
l2BpRowCnt:   db 0

; Read back byte 0 of the front surface's first 8K page - where both
; modes' top-left corner marker lands (tc_mark_256/tc_mark_320 both
; write TC_MARK_COLOUR there). Lets the boot hook
; distinguish "content never made it into the banks" (reads back the
; transparent fill byte or garbage) from "the banks are right but
; another layer is hiding them" (reads back TC_MARK_COLOUR, $FF, even
; though the screen doesn't show it) regardless of what the display
; shows. Out: A = the byte read. Corrupts AF only.
l2_peek_marker:
    call data_save
    ld a, (l2FrontBank)
    add a, a
    call data_map_page
    ld a, (DATA_WINDOW)
    push af
    call data_restore            ; corrupts A - stash the peeked byte first
    pop af
    ret

; 256x192: 6 x 8K pages, row-major (guide 162: "upper byte Y, lower
; byte X"), 32 rows/page of 256 bytes. Every row is filled with X
; (0..255), giving a horizontal rainbow repeated on all 192 lines.
; Corrupts AF, BC, DE, HL.
tc_gradient_256:
    call data_save
    ld a, (l2FrontBank)
    add a, a
    ld (l2PageCur), a
    ld b, 6
.page:
    push bc
    ld a, (l2PageCur)
    call data_map_page
    ld hl, DATA_WINDOW
    ld b, 32                     ; rows in this page
.row:
    push bc
    push hl
    ld c, 0
.px:
    ld a, c
    ld (hl), a
    inc hl
    inc c
    jr nz, .px
    pop hl
    ld de, 256
    add hl, de
    pop bc
    djnz .row
    pop bc
    ld hl, l2PageCur
    inc (hl)
    djnz .page
    call data_restore
    ret

; 320x256: 10 x 8K pages, column-major (guide 310: upper byte X, lower
; byte Y; 8K page holds 32 columns). Every column (D = $C0..$DF, the
; in-page column) is filled with a colour that increments once per
; column across the whole 320-wide sweep, giving a vertical rainbow
; repeated left to right (wraps once at column 256 - still clearly a
; gradient). Only fills Y 0-239 (240 lines) per column, NOT the full
; 256: with Layer 2 on top (l2_enable), the bottom 16 lines - where
; debug.asm's two status rows sit (TM_ROWS-2..TM_ROWS-1, 8px/row) - are
; left at l2_clear's transparent fill so the text shows through instead
; of being covered by opaque gradient. Corrupts AF, BC, DE, HL.
tc_gradient_320:
    call data_save
    ld a, (l2FrontBank)
    add a, a
    ld (l2PageCur), a
    xor a
    ld (l2GradCol), a
    ld b, 10
.page:
    push bc
    ld a, (l2PageCur)
    call data_map_page
    ld d, $C0
    ld b, 32                     ; columns in this page
.col:
    push bc
    ld a, (l2GradCol)
    ld e, 0
    ld b, 240                    ; Y 0-239 only - see header comment
.row:
    ld (de), a
    inc e
    djnz .row
    ld hl, l2GradCol
    inc (hl)
    inc d
    pop bc
    djnz .col
    pop bc
    ld hl, l2PageCur
    inc (hl)
    djnz .page
    call data_restore
    ret

l2GradCol: db 0

; A = 8K page, HL = base address within the page ($C000-based), C =
; marker colour. Stamps a 4x4 block: 4 groups of 4 contiguous bytes,
; 256 bytes apart. A square block is symmetric under an X/Y axis
; swap, so the same routine marks a corner correctly whether the
; caller's HL offset was built row-major or column-major - only the
; four (page, offset) call sites below know which is which. Corrupts
; AF, BC, DE, HL.
tc_mark:
    call data_map_page
    ld b, 4
.outer:
    push hl
    push bc
    ld b, 4
.inner:
    ld (hl), c
    inc hl
    djnz .inner
    pop bc
    pop hl
    ld de, 256
    add hl, de
    djnz .outer
    ret

; 256x192 corners (row-major: page = Y>>5, offset = (Y&31)*256 + X).
; TL (X0-3,Y0-3) and TR (X252-255,Y0-3) fall in page 0; BL (X0-3,
; Y188-191) and BR (X252-255,Y188-191) fall in page 5 (188>>5 = 5).
; Corrupts AF, BC, DE, HL.
tc_mark_256:
    call data_save
    ld a, (l2FrontBank)
    add a, a
    ld hl, DATA_WINDOW                   ; TL
    ld c, TC_MARK_COLOUR
    call tc_mark
    ld a, (l2FrontBank)
    add a, a
    ld hl, DATA_WINDOW+252               ; TR
    ld c, TC_MARK_COLOUR
    call tc_mark
    ld a, (l2FrontBank)
    add a, a
    add a, 5
    ld hl, DATA_WINDOW+28*256            ; BL
    ld c, TC_MARK_COLOUR
    call tc_mark
    ld a, (l2FrontBank)
    add a, a
    add a, 5
    ld hl, DATA_WINDOW+28*256+252        ; BR
    ld c, TC_MARK_COLOUR
    call tc_mark
    call data_restore
    ret

; 320x256 corners (column-major: page = X>>5, offset = (X&31)*256 + Y).
; TL (X0-3,Y0-3) and BL (X0-3,Y236-239) fall in page 0; TR (X316-319,
; Y0-3) and BR (X316-319,Y236-239) fall in page 9 (316>>5 = 9). Note
; the page split runs left/right here, not top/bottom as in the
; 256x192 case above - exactly the stride difference this card exists
; to catch. BL/BR sit at Y236-239, not Y252-255 - the bottom of the
; 240-line drawable area (see tc_gradient_320's header comment), i.e.
; "bottom corner of the card", not "bottom of the physical screen"
; (Y240-255 there is reserved for the tilemap status rows showing
; through). Corrupts AF, BC, DE, HL.
tc_mark_320:
    call data_save
    ld a, (l2FrontBank)
    add a, a
    ld hl, DATA_WINDOW                   ; TL
    ld c, TC_MARK_COLOUR
    call tc_mark
    ld a, (l2FrontBank)
    add a, a
    add a, 9
    ld hl, DATA_WINDOW+28*256            ; TR
    ld c, TC_MARK_COLOUR
    call tc_mark
    ld a, (l2FrontBank)
    add a, a
    ld hl, DATA_WINDOW+236               ; BL
    ld c, TC_MARK_COLOUR
    call tc_mark
    ld a, (l2FrontBank)
    add a, a
    add a, 9
    ld hl, DATA_WINDOW+28*256+236        ; BR
    ld c, TC_MARK_COLOUR
    call tc_mark
    call data_restore
    ret

; Card #6 SNAP=03/00 sitting follow-up (.superpowers/sdd/sp14a-task-4-
; report.md section 41): EXTERN vector 8 (overlay0.asm's
; l2mod_trampoline, tests/test.dsf's L2MOD verb) lands here once
; OVL2_PAGE is mapped. Only reason this wrapper exists at all: A must
; be set to the mode AFTER the page switch, since ovl_map_page's own
; A-clobber (loading OVL2_PAGE for the NR_MMU7 write) would otherwise
; destroy it if the trampoline set A first. Tail-jumps into
; l2_testcard (this file, above) - draws the mode-0 (256x192) test
; card, distinct gradient + corner markers, over the current front
; surface, so a following VPLY1 exercises vid_snap_geom's 3-bank
; branch and the restore is visibly checkable. LHIDE/LSHOW (vectors
; 9/10) need no such wrapper - they trampoline straight to
; l2_disable/l2_enable below, unchanged. Corrupts everything
; (l2_testcard's own contract).
l2mod_run:
    xor a                       ; A = 0: 256x192 mode-0
    jp l2_testcard

; --- SP17 T5 Layer 2 SCROLL bring-up probes -------------------------
; Owner run sheet: .superpowers/sdd/sp14a-task-4-report.md section 41.4.
; T5 (global motion compensation) wants to encode a camera pan as "move
; the Layer 2 offset by (dx,dy), repaint only the newly exposed edge".
; Nothing about that can be designed until the offset registers'
; behaviour is proven on silicon: the 9th X bit (NR $71, see
; nextdaad.inc), whether the offset WRAPS cleanly at each mode's
; width/height, whether the letterbox clip window the video player
; programs stays fixed in SCREEN space while content scrolls under it,
; and whether an offset write placed mid-raster tears.
;
; One EXTERN vector (11) serves every probe: A/B = a config index into
; l2sCfg, so each owner verb is one table row, not one vector. The body
; only PANS an existing picture - it draws nothing new: l2_testcard
; (this file) paints the card and l2_bareprobe_marker stamps its four
; solid blocks near the origin, which is the actual motion reference
; (the gradient alone is featureless along one axis in each mode - flat
; vertically in mode-0, flat horizontally in mode-1 - so the blocks,
; not the ramp, are what makes a wrap unambiguous; they read as a
; horizontal row of 4 in mode-0 and a vertical column of 4 in mode-1,
; the stride difference the card exists to show).
;
; Every probe: draw, apply the config's clip window, program the start
; offset, print one status line + debug.asm's shared register/clip/
; scroll row, wait for the keyboard to clear (the ENTER that submitted
; the verb), then step the offset once per frame until ANY key is
; pressed. On exit the offsets go back to 0 and l2_clip_set re-asserts
; the mode's full window, so the game is left in a normal state with
; the card still on screen (the L2MOD precedent).

L2S_OPT_CLIP equ %00000001      ; program the inset clip window first
L2S_OPT_MID  equ %00000010      ; write the offset mid-raster, not in
                                 ; the vertical blanking interval
L2S_CFGLEN   equ 10             ; bytes per l2sCfg row
L2S_CFGN     equ 10             ; rows (owner verbs)

; The inset clip window used by the OPT_CLIP probes. All four sides are
; inset so BOTH axes are observable in one row: if the window is in
; screen space (what T5 needs) the rectangle stays nailed to the screen
; while the picture pans inside it; if it is in surface space the
; rectangle itself slides. X is in 2-pixel units for 320x256 (guide
; 655-669), so 16..143 = screen pixels 32..287; Y is in pixel rows.
L2S_CLIP_X1  equ 16
L2S_CLIP_X2  equ 143
L2S_CLIP_Y1  equ 48
L2S_CLIP_Y2  equ 207

; B = config index (h_extern leaves EXTERN's first parameter in BOTH A
; and B; the trampoline's ovl_map_page clobbers A, so B is the one that
; survives - the same reason l2mod_run exists). Out of range = silent
; no-op. Corrupts everything.
l2scr_run:
    ld a, b
    cp L2S_CFGN
    ret nc
    ld d, a
    ld e, L2S_CFGLEN
    mul d, e                     ; DE = index * row length (Z80N)
    ld hl, l2sCfg
    add hl, de
    ld de, l2sMode               ; copy the row into the live block -
    ld bc, L2S_CFGLEN            ; same field order, so one LDIR
    ldir
    ld a, (l2sMode)
    call l2_testcard             ; mode + full clip + offsets 0 + draw
    ld a, 3                      ; 4 marker blocks = the motion reference
    call l2_bareprobe_marker
    ld a, (l2sOpts)
    and L2S_OPT_CLIP
    call nz, l2scr_clip_inset
    call l2scr_write             ; the start offset (0, or 256 for LS256)
    ld hl, (l2sMsg)
    call l2dbg_status            ; bottom row: which probe is running
    ld hl, msgL2sX9
    call dbg_puts
    ld e, NR_L2_XOFS_MSB
    call nr_read                 ; NR $71 reads back (guide: RW) - shows
    call dbg_hex8                ; whether the 9th bit even latched
    call l2dbg_status2           ; row above: 14/clipW/scroll/px readback
    call l2scr_wait_release
.loop:
    ld a, (frameCounter)         ; one step per frame, IM2-paced
    ld c, a
.tick:
    ld a, (frameCounter)
    cp c
    jr z, .tick
    ld a, (l2sOpts)
    and L2S_OPT_MID
    jr z, .step                  ; default: write here, just after the
                                  ; frame interrupt = inside vblank
.mid:                             ; MID: spin until the raster is well
    ld bc, 0                     ; inside the visible field, so the
.midpoll:                         ; write lands mid-picture. A window
    ld e, NR_RASTER_LSB          ; (100-149), not an exact line, since
    call nr_read                 ; nr_read is not single-cycle (it
    cp 100                       ; preserves BC, so the counter is
    jr c, .midnext               ; safe). Raster readback beats a delay
    cp 150                       ; loop - no CPU-speed dependency; no
    jr c, .step                  ; MSB check needed either, since no
.midnext:                         ; supported timing has more than 356
    dec bc                       ; lines. The counter is a bail-out
    ld a, b                      ; only: a core that never returns a
    or c                         ; line in the window degrades this row
    jr nz, .midpoll              ; to "write wherever we are" instead
.step:                            ; of hanging the owner's sitting.
    ld hl, (l2sOfs)
    ld a, (l2sStep)
    add hl, a                    ; Z80N ADD HL,A
    ld de, (l2sLimit)
    or a
    sbc hl, de                   ; >= limit: keep the reduced value,
    jr nc, .wrapped              ; else undo the subtraction
    add hl, de
.wrapped:
    ld (l2sOfs), hl
    call l2scr_write
    call l2scr_anykey
    jr z, .loop                  ; Z = nothing pressed: keep panning
    xor a
    nextreg NR_L2_XOFS_MSB, a    ; l2_clip_set only knows $16/$17
    ld a, (l2sMode)
    call l2_clip_set             ; offsets 0 + the mode's full window
    call l2_disable              ; hand the screen back to the text
                                  ; layer: a mode-1 card covers all but
                                  ; the bottom 16 lines, so leaving it
                                  ; up (the L2MOD convention) would make
                                  ; the owner type the next row's verb
                                  ; blind. The next probe re-enables it
                                  ; (l2_testcard), and the game's next
                                  ; location redraw restores real art.
    ld hl, msgL2sDone
    call l2dbg_status
    jp l2scr_wait_release        ; don't leak the exit key into the parser

; Program the current offset for the configured axis. Mode-1 X needs
; two writes (low 8 bits then the NR $71 MSB) and they cannot be
; atomic - LSB FIRST here, which is what the LSTC row probes: crossing
; 256 mid-raster momentarily presents (old MSB, new LSB). Corrupts
; AF, HL.
l2scr_write:
    ld hl, (l2sOfs)
    ld a, (l2sAxis)
    or a
    jr nz, .yaxis
    ld a, l
    nextreg NR_L2_XOFS, a
    ld a, (l2sMode)
    or a
    ret z                        ; mode-0: 8 bits is the whole offset
    ld a, h
    and 1
    nextreg NR_L2_XOFS_MSB, a
    ret
.yaxis:
    ld a, l
    nextreg NR_L2_YOFS, a
    ret

; Program the inset window (constants above) and mirror it into the
; clip shadow, so debug.asm's l2dbg_status2 reports the window that is
; actually up - NR $18 cannot be read back (see l2_clip_set).
; Corrupts AF.
l2scr_clip_inset:
    ld a, L2S_CLIP_X1
    ld (l2ClipX1), a
    ld a, L2S_CLIP_X2
    ld (l2ClipX2), a
    ld a, L2S_CLIP_Y1
    ld (l2ClipY1), a
    ld a, L2S_CLIP_Y2
    ld (l2ClipY2), a
    nextreg NR_CLIP_IDX, 1
    nextreg NR_L2_CLIP, L2S_CLIP_X1
    nextreg NR_L2_CLIP, L2S_CLIP_X2
    nextreg NR_L2_CLIP, L2S_CLIP_Y1
    nextreg NR_L2_CLIP, L2S_CLIP_Y2
    ret

; ZF CLEAR if any key is down: B = 0 selects all eight half-rows at
; once, bits 4-0 are the key lines (1 = up). Raw port read for the
; same reason debug.asm's l2dbg_t_held uses one - the matrix helpers
; live in an overlay this code has no reason to page in. Corrupts
; AF, BC.
l2scr_anykey:
    ld bc, $00FE
    in a, (c)
    and $1F
    cp $1F
    ret
l2scr_wait_release:
    call l2scr_anykey
    jr nz, l2scr_wait_release
    ret

; Live config block - field order MUST match an l2sCfg row (LDIR).
l2sMode:  db 0                  ; 0 = 256x192 mode-0, 1 = 320x256 mode-1
l2sAxis:  db 0                  ; 0 = X, 1 = Y
l2sStep:  db 0                  ; pixels per frame (0 = static hold)
l2sOfs:   dw 0                  ; start offset, then the live one
l2sLimit: dw 0                  ; offset wraps back to 0 at this value
l2sOpts:  db 0                  ; L2S_OPT_*
l2sMsg:   dw 0                  ; status line

; Config rows - one per owner verb (tests/test.dsf, EXTERN n 11):
;   0 LSX0  X wrap, mode-0 (8-bit offset only)
;   1 LSX1  X wrap, mode-1 (9-bit offset: the NR $71 question)
;   2 LSY0  Y wrap, mode-0 (192)
;   3 LSY1  Y wrap, mode-1 (256)
;   4 LSCX  clip window + X pan, mode-1
;   5 LSCY  clip window + Y pan, mode-1
;   6 LSTA  tear baseline: coarse step, write in vblank
;   7 LSTB  tear probe: same step, write mid-raster
;   8 LSTC  tear probe: mode-1 mid-raster, the two-register 9-bit write
;   9 LS256 static hold at exactly 256 - the MSB proof, and the sign of
;           the pan (which way the picture moves for a positive offset)
l2sCfg:
    db 0, 0, 2
    dw 0, 256
    db 0
    dw msgL2s0
    db 1, 0, 1                   ; step 1: sweeps EVERY mode-1 X offset,
    dw 0, 320                    ; odd ones included (mode-1 clip X is in
    db 0                         ; 2px units - the OFFSET is not, so an
    dw msgL2s1                   ; odd-offset artifact would show here)
    db 0, 1, 2
    dw 0, 192
    db 0
    dw msgL2s2
    db 1, 1, 2
    dw 0, 256
    db 0
    dw msgL2s3
    db 1, 0, 2
    dw 0, 320
    db L2S_OPT_CLIP
    dw msgL2s4
    db 1, 1, 2
    dw 0, 256
    db L2S_OPT_CLIP
    dw msgL2s5
    db 0, 0, 8
    dw 0, 256
    db 0
    dw msgL2s6
    db 0, 0, 8
    dw 0, 256
    db L2S_OPT_MID
    dw msgL2s7
    db 1, 0, 8
    dw 0, 320
    db L2S_OPT_MID
    dw msgL2s8
    db 1, 0, 0
    dw 256, 320
    db 0
    dw msgL2s9

msgL2s0: db "LSX0 X-WRAP M0 W256 STEP2 VBLANK", 0
msgL2s1: db "LSX1 X-WRAP M1 W320 STEP1 VBLANK 9BIT", 0
msgL2s2: db "LSY0 Y-WRAP M0 H192 STEP2 VBLANK", 0
msgL2s3: db "LSY1 Y-WRAP M1 H256 STEP2 VBLANK", 0
msgL2s4: db "LSCX CLIP+X M1 W320 STEP2 VBLANK", 0
msgL2s5: db "LSCY CLIP+Y M1 H256 STEP2 VBLANK", 0
msgL2s6: db "LSTA X M0 STEP8 VBLANK WRITE", 0
msgL2s7: db "LSTB X M0 STEP8 MIDRASTER WRITE", 0
msgL2s8: db "LSTC X M1 STEP8 MIDRASTER 9BIT WRITE", 0
msgL2s9: db "LS256 STATIC XOFS 256 M1", 0
msgL2sX9: db " NR71=", 0
msgL2sDone: db "L2SCROLL DONE - OFFSETS 0, CLIP FULL", 0

 ENDIF

    DISPLAY "overlay2 ends at ", $, " headroom ", /D, OVL_LIMIT - $
    ASSERT $ <= OVL_LIMIT
