; NextDAAD code page: video (NXV v2 delta-video player, SP15 Task 3
; stages 3a resident + 3b ring streaming + 3c direct-serve/column-hop
; - the v1 player is DELETED; git holds it).
;
; PAGE LAYOUT (SP15 3a redesign + 3b streaming + 3c - the layout
; authority):
;
;   VID_PAGE (59, MMU7 while any video code runs, $E000-$F7FF) - HOT:
;     everything that can execute while the video CTC ISR is armed.
;     $E000        vid_stub - 64-byte 256-aligned dispatch block (16
;                  4-byte JP slots; the wire opcode IS the offset;
;                  3c: FEND/PAL/KFLIP slots are per-session SMC too)
;     $E040..      decode kernels (computed-entry fill/LDI blocks,
;                  ALIGN 64), fast op handlers (flat + gapped sets,
;                  3c inline column hop), central dispatch, chunked
;                  bodies (SMC exits), DMA arm blocks, seam walkers
;                  (streaming-aware: circular wrap + walk bound),
;                  PAL/KSTART/KFLIP/FEND handlers, vid_pos24
;     then         vid_decode_frame/_ds + vid_dst_setup,
;                  vid_src_seek / vid_aud_copy + vid_aud_queue,
;                  vid_play / vid_run + the frame loop, vid_key_any,
;                  the two audio CTC ISRs (3b double-buffer swap
;                  tails), the 3b STREAMING PRODUCER + hot SD cluster
;                  (gate/prod_step/win/cmd/tok/block - see its
;                  banner), the 3c DIRECT-SERVE cluster (ds_next/
;                  byte/blkopen/pad/xfer/copy_body/pal/terminals/
;                  aud_copy - see its banner), DEBUG timeline stamp
;     then         hot cells (ring bank list, streaming + direct
;                  session cells, hot filemap, vidSvMmu6/7; the
;                  AUDIO BUFFER is NOT here any more - FOURTH RULE)
;
;   VID_PAGE2 (70, $E000-$F7FF) - COLD (pre-arm / post-disarm only):
;     vid_run_orch_body (3c: the whole pre-arm ladder as plain calls)
;     -> nxv2_open_body (v2 header validate + audio bank + snapshot
;     bank reservation + ring alloc + delivery decision by hint/size
;     + resident load / streaming
;     ring PREFILL / direct rewind-and-handoff + hot staging incl.
;     the per-session decode vectors), vid_run_entry_body /
;     vid_run_l2setup_body / vid_run_restore_body (EXIT ORDER FIX
;     lives there), the SP15 L2 snapshot cluster (vid_snap_save_body /
;     vid_snap_restore_body / vid_snap_copy + the 512B palette
;     readback buffer), the esxDOS open cluster (vid_open_video_body /
;     vid_stream_open_body / vid_raw_setup), the cold SD streaming
;     cluster (vid_stream_read raw CMD18 machinery - pre-arm
;     load/prefill only; the ARMED session runs on the hot clones),
;     the cold-only vidSv* cells (3c move). DEBUG: the failure
;     prints + the timeline report body.
;
; ONE RULE (unchanged from every prior video task): MMU7 = VID_PAGE for
; the entire window the video CTC ISR can fire (from the time-constant
; write in vid_run through the CTC reset in .restore) - every cross-page
; hop in this file happens strictly pre-arm or post-disarm.
;
; SECOND RULE (new, 3a): MMU2 ($4000-$5FFF) is the decode loop's
; borrowed Layer 2 dest window for the whole playback session (saved in
; vid_run_entry_body, restored in vid_run_restore_body - the NXBEN
; precedent: nothing else touches $4000-$5FFF during playback; the 50Hz
; im2_isr fast path is AF/HL/frameCounter only, the video CTC ISR is
; AF/IX only, and nothing prints while a video plays).
;
; THIRD RULE (new, 3b; extended 3c): while a STREAMING or DIRECT-SERVE
; session is armed, the CMD18 window may be open across frames and the
; Multiface is disabled for each open span - no other filesystem/SD
; access can happen (structurally true: audEnable is frozen, nothing
; else runs), and the hot side owns every window/run/MF cell (the cold
; twins hand off at .strm_loaded / .direct_setup and take nothing back
; until teardown). MF protection is per-window, not per-session:
; vid_win_close_h restores MF, so brief re-enabled gaps exist at
; fragment boundaries and rewinds until the next vid_win_open_h
; re-disables it (v1's shape - an NMI in a gap hits with the window
; CLOSED, which is safe).
;
; FOURTH RULE (new, 3c): MMU3 ($6000-$7FFF) is the session's borrowed
; AUDIO window - one pool bank holding the 2560-byte double buffer
; (vidAudBuf = VID_AUD_WIN), mapped in vid_run_l2setup_body and
; restored in the restore body (the MMU2 pattern). Safe by the same
; freeze arguments as the SECOND RULE: the tilemap (bank 5) is hidden
; and isolated, the sample machinery (its $7C00 stage ring included)
; is aborted with its CTC vector replaced, and nothing else reads
; slot 3 while a video plays; bank 5's CONTENT is untouched - only
; the CPU mapping is borrowed. This is the 2560-byte hot-page reclaim
; that funds the 3c direct-serve + column-hop features.
;
; Format authority: docs/superpowers/plans/2026-07-23-sp15-nxv2.md
; (FROZEN 2026-07-25); nextdaad.inc's NXV2_* block is the player-side
; transcription; authoring-kit/lib/nxv2dec.py is the executable spec.
; Silicon coefficients: .superpowers/sdd/task-2-final-settlement.md.
;
; THE THREE DECODER CONTRACTS (freeze caveat (c)) and where they live:
;   1. Misaligned-opcode validation: dispatch masks the fetched byte
;      with AND $C3 and rejects nonzero (VID_ERR_OP) - only offsets
;      $00-$3C, multiples of 4, can reach the stub block, whose $24/
;      $2C/$30-$3C slots are error stubs. Cost: +14T per op (AND 7T +
;      untaken JR 7T; ~+16T at 28MHz with wait states) = 3.6-5.2% of
;      the settled 267-387T per-op envelopes (and ~0.5% of a
;      transfer-dominated real frame), bounded by design.
;   2. Early-FEND tail semantics: the decoder only writes what ops
;      write - no surface clears anywhere - so an early FEND leaves
;      the untouched frame tail exactly as it stands (patch-in-place).
;   3. DMA chunks <= 256B: every chunk path is capped at NXV2_DMA_CHUNK
;      by vid_chunk_dst/vid_chunk_all before a DMA kernel can see it.
; CORRUPT-INPUT DIVERGENCE NOTE (3b carried minor): a RUN8/COPY8 with
; n = 0 is a SILENT NO-OP here (the kernels' structural zero-count
; guards) where nxv2dec raises. The encoder never emits n = 0, so the
; divergence is reachable only on corrupt input, where this player's
; contract is "abort or benign no-op, never UB" - not output equality.
; KF-INHERIT CAVEAT (freeze caveat (a)): KSTART performs NO visible->
; hidden inherit copy - keyframe spans are encoder-guaranteed FULL
; repaints (every pixel covered across the span), so the composition
; needs none and the ~0.44-frame copy cost is designed OUT.
;
; docs/Z80 citations (per the plans-cite-docs convention): doc 07
; (dense dispatch via the 256-aligned stub block + JP (IY)), doc 01
; (all instruction costs; JP cc vs JR cc choices), doc 05 (Z80N ADD
; rr,A / ADD rr,nn pointer math; 24-bit carry chains), doc 04 via the
; NXBEN-graduated kernels (computed-entry unrolled fill/LDI), doc 08
; (SMC: per-file stub/height patches, written cold through the MMU6
; window - rubric 3), doc 11 (MMU model, zxnDMA one-shot law, DI
; brackets), doc 13 (all eight rubrics - sweep in the task report).

    MMU 7, VID_PAGE, OVL_ORG

; ---------------------------------------------------------------------
; Dispatch stub block - 64 bytes at the page base ($E000, 256-aligned
; so IYL = opcode byte addresses it; doc 07 taken to its floor: zero
; multiply, zero table walk). Slots $08/$10/$1C (RUN8/COPY8/SKIP8) are
; SMC-patched per file by nxv2_open_body: flat fast handlers for
; mode-0 / mode-1 native-height files, gapped fast handlers (column-
; room checks) for mode-1 letterbox files. Contract 1's AND $C3 mask
; in the dispatch guarantees only offsets $00-$3C (multiples of 4)
; ever land here; $24 (old $09), $2C (SCROLL), $30-$3C are error
; stubs. Rubric 8: alignment + size asserted below.
; ---------------------------------------------------------------------
vid_stub:
    jp vid_op_fend               ; $00 FEND
    nop
    jp vid_op_skip16             ; $04 SKIP16
    nop
    jp vf_op_run8                ; $08 RUN8   (SMC: flat/gap per file)
    nop
    jp vid_op_run16              ; $0C RUN16
    nop
    jp vf_op_copy8               ; $10 COPY8  (SMC: flat/gap per file)
    nop
    jp vid_op_copy16             ; $14 COPY16
    nop
    jp vid_op_pal                ; $18 PAL
    nop
    jp vf_op_skip8               ; $1C SKIP8  (SMC: flat/gap per file)
    nop
    jp vid_op_kflip              ; $20 KFLIP
    nop
    jp vid_op_bad                ; $24 reserved (old $09)
    nop
    jp vid_op_kstart             ; $28 KSTART
    nop
    jp vid_op_bad                ; $2C SCROLL (reserved, errors)
    nop
    jp vid_op_bad                ; $30 reserved
    nop
    jp vid_op_bad                ; $34 reserved
    nop
    jp vid_op_bad                ; $38 reserved
    nop
    jp vid_op_bad                ; $3C reserved
    nop
    ASSERT (low vid_stub) == 0
    ASSERT $ - vid_stub == 64

; ---------------------------------------------------------------------
; RUN fill kernel, CPU: computed-entry unrolled ld (hl),e stores
; (graduated NXBEN nxb_fill_unrolled - doc 04 block shape, doc 05
; ADD BC,nn; 17.0 T/B body + the ~230T entry the settlement's 387T
; RUN envelope carries). In: A = colour, DE = dest, BC = chunk
; (1..8192). Out: DE += chunk, BC corrupt. Preserves HL (src).
; The low-byte SMC is same-page (MMU7 pinned - doc 08 / rubric 3).
; ---------------------------------------------------------------------
vid_fill_cpu:
    push hl                      ; src
    ex de, hl                    ; HL = dest
    ld e, a                      ; E = colour
    ld a, c
    and 15
    jr z, .full
    add a, a                     ; rem * 2 (store+inc = 2 bytes)
    neg
    add a, low (vid_fill_blk + 32)
    jr .set
.full:
    ld a, low vid_fill_blk
.set:
    ld (.fe+1), a                ; low-byte SMC (page-asserted below)
    add bc, 15                   ; Z80N ADD BC,nn (doc 05)
    srl b
    rr c
    srl b
    rr c
    srl b
    rr c
    srl b
    rr c                         ; BC = passes = (chunk+15)/16
    ld a, b
    or c
    jr z, vid_fill_done          ; structural: zero chunk is a no-op
.fe:
    jp vid_fill_blk              ; low byte SMC-patched
    ALIGN 64
vid_fill_blk:
    DUP 16
      ld (hl), e
      inc hl
    EDUP
    dec bc
    ld a, b
    or c
    jr nz, vid_fill_blk
vid_fill_done:                   ; global: the ALIGNed block label
    ex de, hl                    ; above rescopes dot-locals
    pop hl                       ; src
    ret
    ASSERT (low vid_fill_blk) <= 256-40

; ---------------------------------------------------------------------
; COPY kernel, CPU: computed-entry unrolled LDI (graduated NXBEN
; nxb_copy_ldi - doc 04; rubric 2: LDI's own BC countdown is the only
; counter). In: HL = src, DE = dest, BC = chunk (both windows valid).
; Out: HL/DE advanced, BC = 0. 20.25 T/B body + 267T envelope
; (settlement C8/C16 joint solve). Zero-count guarded.
; ---------------------------------------------------------------------
vid_copy_ldi:
    ld a, b
    or c
    ret z                        ; zero count: structural no-op
    ld a, c
    and 15
    jr z, .full
    add a, a                     ; rem * 2 (LDI = 2 bytes)
    neg
    add a, 32 + low vid_ldi_blk
    jr .set
.full:
    ld a, low vid_ldi_blk
.set:
    ld (.ce+1), a
.ce:
    jp vid_ldi_blk               ; low byte SMC-patched
    ALIGN 64
vid_ldi_blk:
    DUP 16
      ldi
    EDUP
    jp pe, vid_ldi_blk           ; P/V set = BC != 0
    ret
    ASSERT (low vid_ldi_blk) <= 256-36

; ---------------------------------------------------------------------
; Fast op handlers - FLAT set (mode-0 any height, mode-1 at native
; 256: the surface is linear in the dest window, so the only dest
; hazard is the window seam; graduated NXBEN fast paths). Register
; file across the whole decode loop: HL = src cursor ($C000-$DFFF),
; DE = dest cursor ($4000-$5FFF), BC = per-op scratch, IY = vid_stub
; (IYH pinned; both live ISRs are IY-free). IX is NEVER touched (the
; audio ISR's exclusive play pointer - the standing exclusivity rule).
; ---------------------------------------------------------------------

; Inline dispatch tail (bench NXBNEXT + contract 1's validation).
; edgelbl/badlbl are jr-range relays chosen per handler cluster.
    MACRO NXVNEXT edgelbl, badlbl
      ld a, h
      cp $DF
      jr nc, edgelbl             ; rare: source window end approaching
      ld a, (hl)
      inc hl
      ld iyl, a                  ; opcode byte = stub offset
      and $C3                    ; contract 1: only $00-$3C mult-of-4
      jr nz, badlbl              ; may dispatch; all else = VID_ERR_OP
      jp (iy)
    ENDM

; SKIP8 flat: dest += n; fast when D <= $5E (any 8-bit count stays
; inside the window).
vf_op_skip8:
    ld a, d
    cp $5F
    jr nc, .edge
    ld a, (hl)
    inc hl
    add de, a                    ; Z80N: DE += count (doc 05)
    NXVNEXT vf_edge_relay, vf_bad_relay
.edge:
    ld c, (hl)
    inc hl
    ld b, 0
    jp vid_skip_body

; RUN8 flat: window-room fast when D <= $5E; counts >= the DMA
; crossover ride the chunked body (which selects the DMA kernel).
vf_op_run8:
    ld c, (hl)
    inc hl
    ld a, d
    cp $5F
    jr nc, .slow
    ld a, c
    cp NXV2_RUN_DMA_MIN
    jr nc, .slow
    ld a, (hl)
    inc hl                       ; A = colour (no cell round-trip)
    ld b, 0
    call vid_fill_cpu
    NXVNEXT vf_edge_relay, vf_bad_relay
.slow:
    ld a, (hl)
    inc hl                       ; A = colour
    ld b, 0
    jp vid_run_body

; COPY8 flat: src body is structurally safe when the opcode byte sat
; below $DF00; an edge-refined opcode at $DFxx needs the exact
; L+count check (bench logic verbatim). Dest fast when D <= $5E.
vf_op_copy8:
    ld c, (hl)
    inc hl
    ld b, 0
    ld a, h
    cp $DF
    jr nc, .srcedge
.sok:
    ld a, d
    cp $5F
    jr nc, .slow
    ld a, c
    cp NXV2_COPY_DMA_MIN
    jr nc, .slow
    call vid_copy_ldi
    NXVNEXT vf_edge_relay, vf_bad_relay
.srcedge:
    ld a, l
    add a, c
    jr nc, .sok                  ; L+count <= 255: body inside window
    jr z, .sok                   ; == 256 exactly: last read is $DFFF
.slow:
    jp vid_copy_body

; jr-range relays for the flat set's inline tails (the central hub
; sits past jr's +127 from the earliest handler).
vf_edge_relay:
    jp vid_op_edge
vf_bad_relay:
    jp vid_op_bad

; ---- central dispatch + edge machinery (jr-range hub) ----
vid_next:
    ld a, h
    cp $DF
    jr nc, vid_op_edge           ; rare: window end or header straddle
vid_next_fetch:
    ld a, (hl)
    inc hl
    ld iyl, a
    and $C3                      ; contract 1 (see file header)
    jr nz, vid_op_bad
    jp (iy)

vid_op_edge:
    ; A = H: $DF (last page bytes) or >= $E0 (wrap due).
    cp $E0
    jr c, .instr
    call vid_src_next
    jr vid_next
.instr:
    ; opcode at $DFxx: if fewer than 3 operand bytes remain in the
    ; window ($DFFD-$DFFF), take the byte-fetch slow path; otherwise
    ; the fast fetch is safe for every op HEADER (max 3 operand
    ; bytes; counted bodies re-check their own rooms).
    ld a, l
    cp $FD
    jr c, vid_next_fetch
    jp vid_slow_op

; Reserved/misaligned opcode (contract 1; IYL still holds the byte).
vid_op_bad:
 IFDEF DEBUG
    ld a, iyl
    ld (vidErrOp), a
 ENDIF
    ld a, VID_ERR_OP
    ; falls into vid_dec_abort
; Structural decode abort: A = VID_ERR_* code. Resets SP to the frame
; loop's anchor and jumps to its fail exit - safe from ANY depth
; (kernels, seam walkers, the audio copy).
; DEBUG breadcrumb (SP15 3a follow-up, intermittent-trap): capture the
; failing SOURCE position as the 24-bit linear file offset (the same
; bankIdx/parity/HL linearization vid_dec_done performs, unrounded),
; surfaced on the timeline report as POS= - a one-shot ERR=FA
; self-localizes to a byte position instead of being unreproducible.
; (PASS= is reported LIVE from vidLoopPass on every exit, clean or
; error - stage-3a calibration wave; POS= stays abort-only.)
; HL is the live source cursor in every abort
; context (op dispatch, seam walkers, audio copy, PAL/COPY bodies)
; except vid_dec_done's bound trip, which stores its already-rounded
; position itself and enters at vid_dec_abort_pos.
vid_dec_abort:
 IFDEF DEBUG
    push af
    call vid_pos24               ; B:HL = 24-bit linear position (3c
    ld a, b                      ; reclaim: shared with vid_dec_done)
    ld (vidErrPos+2), a
    ld (vidErrPos), hl
    pop af
 ENDIF
vid_dec_abort_pos:               ; entry with vidErrPos already stored
 IFDEF DEBUG
    ld (vidErrCode), a           ; PASS= needs no capture here: the loop
                                 ; stops at the abort, so the LIVE
                                 ; vidLoopPass IS the pass that failed
    push af                      ; SP17 bench reclaim (review fix): the
    call nxb_reclaim             ; abort chain never returns to the
    pop af                       ; bench, so its banks/audEnable/MMU
                                 ; state have to come back HERE. Whole
                                 ; routine is a 7-cycle no-op unless a
                                 ; standalone bench row is live.
 ENDIF
    ld sp, (vidDecSp)
    jp vid_run.decfail

; ---------------------------------------------------------------------
; Fast op handlers - GAPPED set (mode-1 letterbox: content height
; 1-255, columns are 256-aligned in the dest window so E IS the
; within-column offset; a whole column always sits inside one window
; page). Fast conditions (SP15 3c column-hop upgrade):
;   E + count <= height  - inside the column (== height lands on the
;                          deferred-hop invariant state, exactly what
;                          the chunked body used to produce);
;   single crossing      - E + count - height < height AND (RUN/COPY)
;                          count under the DMA crossover: the op is
;                          split INLINE into two fast segments around
;                          a `ld e,seg2 / inc d` column hop (the 3b
;                          report 1.6 design; window seam on the hop
;                          handled by the same vid_dst_next walker).
; Everything else (9-bit sums, multi-column, DMA-sized counts) still
; rides the chunked bodies, whose per-chunk machinery is the right
; engine there. The height immediates at .hcmp/.hsub/.hcmp2 are
; per-file SMC constants (nxv2_open_body patches all of them, doc 08
; through the MMU6 window - rubric 3).
; ---------------------------------------------------------------------
vg_op_skip8:
    ld c, (hl)
    inc hl
    ld a, e
    add a, c
    jr c, .slow
.hcmp:
    cp 0                         ; SMC: content height (1-255)
    jr c, .in                    ; strictly inside the column
    jr z, .in                    ; == height: column finished (the
                                 ; deferred-hop invariant state)
.hsub:
    sub 0                        ; SMC height: A = overshoot (>= 1)
.hcmp2:
    cp 0                         ; SMC height
    jr nc, .slow                 ; crosses 2+ columns: chunked body
    ld e, a                      ; INLINE HOP: land in the next
    inc d                        ; 256-aligned column
    ld a, d
    cp $60
    call nc, vid_dst_next        ; window seam on the hop (rare)
    jr .tail
.in:
    ld e, a                      ; same column, same page
.tail:
    NXVNEXT vg_edge_relay, vg_bad_relay
.slow:
    ld b, 0
    jp vid_skip_body

vg_op_run8:
    ld c, (hl)
    inc hl
    ld a, e
    add a, c
    jr c, .slow
.hcmp:
    cp 0                         ; SMC: content height
    jr c, .in
    jr z, .in
    ; crossing: hop-eligible only under the DMA crossover (segments
    ; are CPU-filled; at >= the crossover the body's DMA kernel is
    ; the right engine anyway)
    ld a, c
    cp NXV2_RUN_DMA_MIN
    jr nc, .slow
    ld a, e
    add a, c                     ; re-derive E+count (carry-free: the
                                 ; 9-bit case took .slow above)
.hsub:
    sub 0                        ; SMC height: A = seg2 (1..h-1)
.hcmp2:
    cp 0                         ; SMC height
    jr nc, .slow                 ; crosses 2+ columns
    ld b, a                      ; B = seg2
    ld a, c
    sub b
    ld c, a                      ; C = seg1 = height - E (>= 1)
    ld a, (hl)
    inc hl                       ; A = colour
    push bc                      ; seg2 rides in B
    ld b, 0
    call vid_fill_cpu            ; seg1: fills to the column end
    pop bc
    ld c, b
    ld b, 0                      ; BC = seg2
    ld e, 0
    inc d                        ; the hop
    ld a, d
    cp $60
    call nc, vid_dst_next
    dec hl
    ld a, (hl)                   ; colour again (operand byte behind
    inc hl                       ; the cursor - always in-window in a
                                 ; fast handler, see vid_op_edge)
    call vid_fill_cpu            ; seg2 into the new column
    jr .tail
.in:
    ld a, c
    cp NXV2_RUN_DMA_MIN
    jr nc, .slow
    ld a, (hl)
    inc hl                       ; A = colour (no cell round-trip)
    ld b, 0
    call vid_fill_cpu
.tail:
    NXVNEXT vg_edge_relay, vg_bad_relay
.slow:
    ld a, (hl)
    inc hl                       ; A = colour
    ld b, 0
    jp vid_run_body

; jr-range relays for the gapped set's inline tails (between run8 and
; copy8 so every NXVNEXT expansion in the grown handlers stays inside
; jr's +-127; the central hub itself sits further).
vg_edge_relay:
    jp vid_op_edge
vg_bad_relay:
    jp vid_op_bad

vg_op_copy8:
    ld c, (hl)
    inc hl
    ld b, 0
    ld a, h
    cp $DF
    jr nc, .srcedge
.sok:
    ld a, e
    add a, c
    jr c, .slow
.hcmp:
    cp 0                         ; SMC: content height
    jr c, .in
    jr z, .in
    ld a, c
    cp NXV2_COPY_DMA_MIN
    jr nc, .slow
    ld a, e
    add a, c                     ; re-derive (carry-free, as run8)
.hsub:
    sub 0                        ; SMC height: A = seg2 (1..h-1)
.hcmp2:
    cp 0                         ; SMC height
    jr nc, .slow
    ld b, a                      ; B = seg2
    ld a, c
    sub b
    ld c, a                      ; C = seg1 (>= 1)
    push bc
    ld b, 0
    call vid_copy_ldi            ; seg1 (HL/DE advance; src room for
    pop bc                       ; the WHOLE count proven at .srcedge)
    ld c, b
    ld b, 0                      ; BC = seg2
    ld e, 0
    inc d                        ; the hop
    ld a, d
    cp $60
    call nc, vid_dst_next
    call vid_copy_ldi            ; seg2
    jr .tail
.in:
    ld a, c
    cp NXV2_COPY_DMA_MIN
    jr nc, .slow
    call vid_copy_ldi
.tail:
    NXVNEXT vg_edge_relay, vg_bad_relay
.srcedge:
    ld a, l
    add a, c
    jr nc, .sok
    jr z, .sok
.slow:
    jp vid_copy_body

; ---- 16-bit ops: parse the header, ride the gap-aware chunked
; bodies unconditionally (real streams' 16-bit ops average hundreds
; of bytes - the body's per-chunk overhead amortizes; a fast path
; would buy nothing but bytes).
vid_op_skip16:
    ld c, (hl)
    inc hl
    ld b, (hl)
    inc hl
    jp vid_skip_body

vid_op_run16:
    ld c, (hl)
    inc hl
    ld b, (hl)
    inc hl
    ld a, (hl)
    inc hl                       ; A = colour
    jp vid_run_body

vid_op_copy16:
    ld c, (hl)
    inc hl
    ld b, (hl)
    inc hl
    jp vid_copy_body

; ---------------------------------------------------------------------
; Slow op path: opcode (and each operand byte) fetched through
; vid_fetch, which walks the window seam per byte (bench shape).
; Operand-less ops dispatch through the stub block after the same
; contract-1 validation; counted ops parse here and enter the bodies.
; ---------------------------------------------------------------------
vid_slow_op:
    call vid_fetch               ; A = opcode
    ld iyl, a
    and $C3                      ; contract 1
    jp nz, vid_op_bad
    ld a, iyl
    cp VOP_SKIP8
    jr z, .s8
    cp VOP_SKIP16
    jr z, .s16
    cp VOP_RUN8
    jr z, .r8
    cp VOP_RUN16
    jr z, .r16
    cp VOP_COPY8
    jr z, .c8
    cp VOP_COPY16
    jr z, .c16
    jp (iy)                      ; FEND/PAL/KFLIP/KSTART: no operands;
                                 ; reserved slots land on error stubs
.s8:
    call vid_fetch
    ld c, a
    ld b, 0
    jp vid_skip_body
.s16:
    call vid_fetch
    ld c, a
    call vid_fetch
    ld b, a
    jp vid_skip_body
.r8:
    call vid_fetch
    ld c, a
    ld b, 0
    call vid_fetch               ; colour
    jp vid_run_body
.r16:
    call vid_fetch
    ld c, a
    call vid_fetch
    ld b, a
    call vid_fetch               ; colour
    jp vid_run_body
.c16:
    call vid_fetch
    ld c, a
    call vid_fetch
    ld b, a
    jr .cj
.c8:
    call vid_fetch
    ld c, a
    ld b, 0
.cj:
    jp vid_copy_body             ; SMC: vid_ds_copy_body when the
                                 ; session is direct-serve (3c)

; Fetch one source byte - SMC-VECTORED per session (3c direct-serve):
; the RAM window walk (resident/streaming) or the SD stream byte
; (direct). vid_stage_common patches .vec+1 on every open. Out: A =
; byte, HL advanced (RAM cursor / block-remain). Preserves BC, DE.
; Corrupts F.
vid_fetch:
.vec:
    jp vid_fetch_ram             ; SMC: vid_fetch_ram / vid_ds_byte
vid_fetch_ram:
    ld a, h
    cp $E0
    call nc, vid_src_next
    ld a, (hl)
    inc hl
    ret

; ---------------------------------------------------------------------
; Chunked bodies (graduated NXBEN slow bodies + column-gap awareness).
; Contract at each body: HL = src after the op header, DE = dest,
; BC = count (vid_run_body also A = colour). Each iteration:
; normalize the dest (hop a finished column / cross a window seam),
; size a chunk against every binding room, run the kernel sized by
; the derived crossovers (RUN >= 71B and COPY >= 74B go DMA, capped
; at 256B per DI bracket - contracts noted in the file header).
; ---------------------------------------------------------------------
vid_skip_body:
    ld (vidRemain), bc
.seg:
    ld bc, (vidRemain)
    ld a, b
    or c
.next:
    jp z, vid_next               ; SMC: vid_ds_next when direct (3c)
    call vid_dst_norm
    call vid_chunk_dst_nocap     ; BC = min(remain, dest/col room) -
                                 ; skips move no bytes, so no DMA cap
    push hl
    ld hl, (vidRemain)
    or a
    sbc hl, bc
    ld (vidRemain), hl
    pop hl
    ex de, hl
    add hl, bc
    ex de, hl
    jr .seg

vid_run_body:
    ld (vidRunColour), a         ; the DMA fill's FIXED port A source
    ld (vidRemain), bc
.seg:
    ld bc, (vidRemain)
    ld a, b
    or c
.next:
    jp z, vid_next               ; SMC: vid_ds_next when direct (3c)
    call vid_dst_norm
    call vid_chunk_dst           ; BC = chunk (rooms + 256 cap)
    push hl
    ld hl, (vidRemain)
    or a
    sbc hl, bc
    ld (vidRemain), hl
    pop hl
    ; kernel select (derived crossover, nextdaad.inc): >= 71 -> DMA fill
    ld a, b
    or a
    jr nz, .dma                  ; chunk == 256
    ld a, c
    cp NXV2_RUN_DMA_MIN
    jr nc, .dma
    ld a, (vidRunColour)
    call vid_fill_cpu
    jr .seg
.dma:
    call vid_fill_dma
    jr .seg

vid_copy_body:
    ld (vidRemain), bc
.seg:
    ld bc, (vidRemain)
    ld a, b
    or c
    jp z, vid_next
    ld a, h
    cp $E0
    call nc, vid_src_next
    call vid_dst_norm
    call vid_chunk_all           ; BC = chunk (src+dest rooms + cap)
    push hl
    ld hl, (vidRemain)
    or a
    sbc hl, bc
    ld (vidRemain), hl
    pop hl
    ld a, b
    or a
    jr nz, .dma                  ; chunk == 256
    ld a, c
    cp NXV2_COPY_DMA_MIN
    jr nc, .dma
    call vid_copy_ldi
    jr .seg
.dma:
    call vid_copy_dma
    jr .seg

; ---------------------------------------------------------------------
; Dest normalize: hop a finished column (gapped) then cross the
; window seam if due. Preserves BC, HL; DE/pages updated. Corrupts AF.
; Gapped invariant: between ops/chunks 0 <= E <= height; E == height
; means "column finished, hop deferred to the next normalize".
; ---------------------------------------------------------------------
vid_dst_norm:
    ld a, (vidGapFlag)
    or a
    jr z, .win
    ld a, (vidHeightB)
    cp e
    jr nz, .win                  ; E < height: inside the column
    xor a
    ld e, a
    inc d                        ; next 256-aligned column base
.win:
    ld a, d
    cp $60
    ret c
    jp vid_dst_next              ; maps the next surface page, D -= $20

; ---------------------------------------------------------------------
; Chunk sizing. In: HL = src, DE = dest (normalized), BC = remaining.
; Out: BC = chunk >= 1. Preserves HL, DE. Corrupts AF (+ stack temp).
; ---------------------------------------------------------------------
; COPY: fold the src window room in, then dest room + DMA cap.
vid_chunk_all:
    call vid_chunk_src
    ; falls into vid_chunk_dst
; RUN: dest room + the 256B DMA cap (contract 3).
vid_chunk_dst:
    call vid_chunk_dst_nocap
    ld a, b
    or a
    ret z                        ; < 256
    dec a
    jr nz, .clip                 ; >= 512
    ld a, c
    or a
    ret z                        ; == 256 exactly
.clip:
    ld bc, NXV2_DMA_CHUNK
    ret

; SKIP (and the inner step for the others): dest room only - column
; room when gapped, window room when flat.
vid_chunk_dst_nocap:
    ld a, (vidGapFlag)
    or a
    jr z, .flat
    ld a, (vidHeightB)
    sub e                        ; A = column room (1..255; normalized)
    inc b
    dec b                        ; Z = (B == 0), A preserved
    jr nz, .takea                ; BC >= 256 > room: take the room
    cp c
    ret nc                       ; room >= count: keep BC
.takea:
    ld c, a
    ld b, 0
    ret
.flat:
    push hl
    ld hl, $6000
    or a
    sbc hl, de                   ; HL = window room (1..$2000)
    or a
    push hl
    sbc hl, bc
    pop hl
    jr nc, .keep                 ; room >= count: keep BC
    ld b, h
    ld c, l
.keep:
    pop hl
    ret

; PAL/COPY head: BC = min(BC, src window room). Preserves HL, DE.
vid_chunk_src:
    push hl
    push de
    ex de, hl                    ; DE = src
    ld hl, $E000
    or a
    sbc hl, de                   ; HL = src room (1..$2000)
    or a
    push hl
    sbc hl, bc
    pop hl
    jr nc, .keep
    ld b, h
    ld c, l
.keep:
    pop de
    pop hl
    ret

; ---------------------------------------------------------------------
; Seam walkers.
; ---------------------------------------------------------------------
; Advance to the next ring page (source). Preserves BC, DE; corrupts
; AF; HL rebased by -$2000. Ring pages alternate bank*2 / bank*2+1
; through the allocated bank list. RESIDENT: running off the list =
; the payload overran the loaded file (clean abort). STREAMING: the
; list is CIRCULAR (the producer guarantees the data ahead - the
; frame-top gate holds until a whole frame section is buffered), so
; the walk wraps to bank 0 instead; the per-seek walk counter bounds
; a corrupt payload that would otherwise orbit the ring forever
; (rubric 6: every walk bounded either way).
vid_src_next:
    push bc
    ld a, (vidStreaming)
    or a
    jr z, .step
    ld a, (vidSrcWalks)
    inc a
    ld (vidSrcWalks), a
    ld c, a
    ld a, (vidWalkMax)
    cp c
    jr c, .ovr                   ; walks > bound: corrupt payload
.step:
    ld a, (vidSrcParity)
    xor 1
    ld (vidSrcParity), a
    jr z, .nextbank
    ld a, (vidSrcCurPage)        ; parity 0 -> 1: same bank, upper page
    inc a
    jr .map
.nextbank:
    ld a, (vidSrcBankIdx)
    inc a
    ld c, a
    ld a, (vidRingBankCnt)
    dec a
    cp c
    jr nc, .idxok                ; idx <= last bank
    ld a, (vidStreaming)         ; past the list end: circular when
    or a                         ; streaming, overrun when resident
    jr z, .ovr                   ; (store stays dead: bank index
    ld c, 0                      ; unchanged on abort)
.idxok:
    ld a, c
    ld (vidSrcBankIdx), a
    push hl
    ld hl, vidRingBanks
    ld a, c
    add hl, a                    ; Z80N (doc 05)
    ld a, (hl)
    pop hl
    add a, a                     ; page = bank * 2
.map:
    ld (vidSrcCurPage), a
    nextreg NR_MMU6, a           ; data_map_page inlined (banks.asm:8)
    ld a, h
    sub $20
    ld h, a
    pop bc
    ret
.ovr:
    ld a, VID_ERR_SRCOVR
    jp vid_dec_abort             ; SP anchor absorbs the pushed BC

; Advance to the next dest surface page (bounds-checked). Preserves
; BC, HL; corrupts AF; DE rebased by -$2000.
vid_dst_next:
    push bc
    ld a, (vidDstPage)
    inc a
    ld (vidDstPage), a
    ld c, a
    ld a, (vidDstEnd)
    cp c
    jr z, .ovr                   ; page == end: past the surface
    jr c, .ovr
    ld a, c
    nextreg NR_MMU2, a
    ld a, d
    sub $20
    ld d, a
    pop bc
    ret
.ovr:
    ld a, VID_ERR_DSTOVR
    jp vid_dec_abort

; ---------------------------------------------------------------------
; PAL: 512-byte NR $44 palette block -> the currently HIDDEN Layer 2
; palette bank (the T2 double-buffer choreography: the edit is
; invisible - vidPalCtrl XOR $40 flips only the edit-target field,
; nextdaad.inc's PAL_L2_* note; the DISPLAY flips at present time via
; vidPalPending). Fast path (whole block inside the source window) is
; an 8-way outinb unroll (bench shape); the straddle chunks via the
; src room. Safe without DI: audEnable is frozen for the session so
; the 50Hz ISR runs its AF/HL-only fast path, and the video CTC ISR
; is AF/IX/DAC only - nothing else touches the $243B pair or NR $44.
; ---------------------------------------------------------------------
vid_op_pal:
    ld a, (vidPalCtrl)
    xor $40                      ; edit the OTHER bank, display as-is
    nextreg NR_PAL_CTRL, a
    nextreg NR_PAL_INDEX, 0
    ld a, 1
    ld (vidPalPending), a
    ld a, h
    cp $DE
    jr nc, .straddle             ; H <= $DD: HL+511 <= $DFFE, inside
    push de
    ld bc, TBBLUE_REG_SEL
    ld a, NR_PAL_VALUE9
    out (c), a
    ld b, high TBBLUE_REG_ACC    ; C stays $3B
    ld d, 64                     ; 64 x 8 = 512 bytes
.pb:
    DUP 8
      outinb                     ; out (BC),(HL); HL++ (B unchanged)
    EDUP
    dec d
    jr nz, .pb
    pop de
    jp vid_next
.straddle:
    ld bc, NXV_PAL_BYTES
    ld (vidRemain), bc
.seg:
    ld bc, (vidRemain)
    ld a, b
    or c
    jp z, vid_next
    ld a, h
    cp $E0
    call nc, vid_src_next
    call vid_chunk_src           ; BC = min(remain, src room)
    push hl
    ld hl, (vidRemain)
    or a
    sbc hl, bc
    ld (vidRemain), hl
    pop hl
    push de
    ld d, b
    ld e, c                      ; DE = chunk counter (dest parked)
    ld bc, TBBLUE_REG_SEL
    ld a, NR_PAL_VALUE9
    out (c), a
    ld b, high TBBLUE_REG_ACC
.pb2:
    outinb
    dec de
    ld a, d
    or e
    jr nz, .pb2
    pop de
    jr .seg

; ---------------------------------------------------------------------
; KSTART: begin keyframe span - paint target = the HIDDEN (back)
; surface, cursor reset to 0 (format reference). NO visible->hidden
; inherit copy (KF-inherit caveat: encoder-guaranteed full repaint -
; see the file header). Duplicate KSTART inside a span is structural
; (nxv2dec parity) - clean abort.
; ---------------------------------------------------------------------
vid_op_kstart:
    ld a, (vidInSpan)
    or a
    jr nz, .dup
    inc a
    ld (vidInSpan), a
    ld a, (l2BackBank)
    add a, a
    ld (vidDstPage), a
    nextreg NR_MMU2, a
    ld c, a
    ld a, (vidDstPages)
    add a, c
    ld (vidDstEnd), a
    ld de, VID_DST_WIN           ; cursor = 0 (KSTART's own effect)
.next:
    jp vid_next                  ; SMC: vid_ds_next when direct (3c -
                                 ; the handler itself is shared: it
                                 ; never touches HL, the direct
                                 ; session's live block-remain)
.dup:
    ld a, VID_ERR_OP
    jp vid_dec_abort

; KFLIP: end of the final keyframe chunk - terminal. The atomic
; flip+palette-swap itself happens at PRESENT time in the frame loop
; (the v1-proven CPU choreography); this handler only closes the
; span. KFLIP with no open span is structural (nxv2dec parity).
vid_op_kflip:
    ld a, (vidInSpan)
    or a
    jr z, .stray
    xor a
    ld (vidInSpan), a
    ld a, VOP_KFLIP
    jr vid_dec_done
.stray:
    ld a, VID_ERR_OP
    jp vid_dec_abort

; FEND: frame end - terminal. Mid-span hold frames spill the dest
; cursor so the span CONTINUES across the chunk-frame boundary
; (nxv2dec's span_cursor rule); the untouched frame tail persists by
; construction (contract 2 - nothing here writes the surface).
vid_op_fend:
    ld a, (vidInSpan)
    or a
    jr z, .plain
    ld a, (vidDstPage)
    ld (vidSpanDstPage), a
    ld (vidSpanDE), de
.plain:
    ld a, VOP_FEND
    ; falls into vid_dec_done
; Shared terminal tail: advance vidFramePos past this frame's payload
; (consumed bytes rounded up to the 512-byte block - valid absolute
; rounding because every frame section is block-aligned), bounds-check
; against the file end, return A = terminal op to the frame loop.
vid_dec_done:
    push af
    call vid_pos24               ; B:HL = pos24
    ; round up to the next 512-byte block
    ld de, 511
    add hl, de
    jr nc, .nc
    inc b
.nc:
    ld a, h
    and $FE
    ld h, a
    ld l, 0
    ld a, (vidStreaming)
    or a
    jp nz, vid_dec_done_strm     ; B:HL = rounded RING position there
.bound:
    ; bounds: pos <= fileEnd (== on the last frame)
    ld a, (vidFileEnd+2)
    cp b
    jr c, .ovr                   ; endHi < posHi
    jr nz, .store                ; endHi > posHi
    ld de, (vidFileEnd)
    push hl
    or a
    sbc hl, de
    pop hl
    jr z, .store
    jr nc, .ovr                  ; pos > end
.store:
    ld (vidFramePos), hl
    ld a, b
    ld (vidFramePos+2), a
    pop af                       ; A = terminal op
    ret                          ; -> vid_decode_frame's caller
.ovr:
    pop af
 IFDEF DEBUG
    ld (vidErrPos), hl           ; breadcrumb: the already-rounded
    ld a, b                      ; linear pos this bound trip rejected
    ld (vidErrPos+2), a
 ENDIF
    ld a, VID_ERR_SRCOVR
    jp vid_dec_abort_pos

; Streaming terminal tail: B:HL = the rounded-up RING-linear position
; the payload ended at (<= ringBytes: the round-up may land exactly on
; the wrap point - the mod folds it to 0). Derives the consumed byte
; count (mod ringBytes, valid because rlStart is block-aligned and one
; payload is far smaller than the ring), advances the ring cursor and
; the depth gauge, then hands the FILE-relative candidate position to
; vid_dec_done's shared bound check (the terminal op stays pushed).
vid_dec_done_strm:
    ld (vidRlNew), hl
    ld a, b
    ld (vidRlNew+2), a
    call vid_rl_mod              ; new ring cursor (mod) -> vidRingRl
    ; consumed = vidRlNew - vidRlStart (mod ringBytes)
    ld hl, (vidRlNew)
    ld de, (vidRlStart)
    or a
    sbc hl, de
    ld a, (vidRlStart+2)
    ld c, a
    ld a, (vidRlNew+2)
    sbc a, c                     ; A:HL = diff (borrow = wrapped)
    jr nc, .cons
    ld de, (vidRingBytes)
    add hl, de
    ld c, a
    ld a, (vidRingBytes+2)
    adc a, c
.cons:                           ; A:HL = consumed (512-multiple, > 0)
    ld d, a                      ; D = consumed[23:16] (kept)
    ld b, a                      ; blocks = consumed >> 9 = (A:H) >> 1
    ld a, h
    srl b
    rra
    ld c, a                      ; BC = consumed blocks
    push hl
    push de
    ld hl, (vidRingDepth)
    or a
    sbc hl, bc
    jr nc, .dok                  ; DEPTH FLOOR (3c hardening): the
 IFDEF DEBUG                     ; underflow class is impossible by
    ld a, (vidDepthClip)         ; construction now, not merely by
    inc a                        ; the gate contract - a clamp fires
    ld (vidDepthClip), a         ; only on a bookkeeping bug and is
 ENDIF                           ; counted on the RING row (DEBUG)
    ld hl, 0
.dok:
    ld (vidRingDepth), hl
    pop de
    pop hl
    ; framePos += consumed -> the shared bound check (B:HL candidate)
    ld bc, (vidFramePos)
    add hl, bc
    ld a, (vidFramePos+2)
    adc a, d
    ld b, a
    jp vid_dec_done.bound

; Fold a ring-linear position (A:HL, < 2*ringBytes) into the ring:
; one conditional ringBytes subtract, stored to vidRingRl. Corrupts
; AF, BC, DE, HL.
vid_rl_mod:
    ld de, (vidRingBytes)
    ld b, a
    ld a, (vidRingBytes+2)
    ld c, a                      ; C:DE = ringBytes
    ld a, b
    push hl
    or a
    sbc hl, de
    sbc a, c
    jr c, .keep                  ; pos < ringBytes: keep as-is
    pop de                       ; discard the saved copy
    jr .store                    ; A:HL = pos - ringBytes
.keep:
    pop hl
    ld a, b
.store:
    ld (vidRingRl), hl
    ld (vidRingRl+2), a
    ret

; pos24 = (bankIdx*2 + parity) * 8192 + (HL - $C000) - the source
; cursor's 24-bit linear position (ring-linear when streaming). In:
; HL = live window cursor. Out: B:HL = pos24. Corrupts A, C. Shared
; by vid_dec_done and the DEBUG abort breadcrumb (3c reclaim - the
; two copies were byte-identical arithmetic).
vid_pos24:
    ld a, (vidSrcBankIdx)
    add a, a
    ld c, a
    ld a, (vidSrcParity)
    or c
    ld c, a                      ; C = linear page index
    ld a, h
    sub $C0
    ld h, a                      ; HL = window offset (0..$2000)
    ld a, c
    and 7
    rrca
    rrca
    rrca                         ; (page & 7) << 5 = (page<<13) >> 8
    add a, h
    ld h, a                      ; HL = pos low16 (partial)
    ld a, 0
    adc a, 0
    ld b, a                      ; carry into the high byte
    ld a, c
    rrca
    rrca
    rrca
    and $1F                      ; page >> 3
    add a, b
    ld b, a                      ; B:HL = pos24
    ret

; ---------------------------------------------------------------------
; zxnDMA kernels (graduated NXBEN persistent-descriptor scheme; doc
; 11's one-shot law verbatim: DI-bracketed CONTINUOUS one-shots, the
; $87 enable is the last byte so the otir returns only when the
; transfer is done; chunks <= 256B - contract 3). The never-changing
; WR2 (port B memory/increment/timing) + WR5 (stop on end) are
; programmed once per session (vid_run_l2setup_body); each chunk's
; arm block carries its own WR0/WR1 (fill and copy interleave freely
; inside one frame, so the port A mode travels with every arm - +4
; otir bytes/chunk vs the bench's per-row split, ~84T against the
; 849/1092T measured setups).
; ---------------------------------------------------------------------

; RUN fill via DMA: port A FIXED at vidRunColour (this page - always
; mapped at MMU7 while armed), port B incrementing across the chunk.
; In: HL src (preserved), DE dest, BC chunk (64..256). Out: DE +=
; chunk. 5.1 T/B + 849T/chunk (settlement RD rows).
vid_fill_dma:
    ld (vidDmaFiArm.blen), bc
    ld (vidDmaFiArm.bdst), de
    ex de, hl
    add hl, bc
    ex de, hl                    ; DE += chunk (before BC dies)
    push hl
    ld hl, vidDmaFiArm
    ld bc, (vidDmaFiArm_len << 8) | DMA_PORT
    di
    otir                         ; arm + run: continuous one-shot
    ei
    pop hl
    ret

; COPY via DMA: mem-to-mem, source = MMU6 ring window, dest = MMU2
; surface window (both pinned across the DI bracket - doc 11's
; banking hazard rule). In: HL src, DE dest, BC chunk (90..256).
; Out: HL/DE advanced. 5.31 T/B + 1092T/chunk (settlement CD rows).
vid_copy_dma:
    ld (vidDmaCpArm.asrc), hl
    ld (vidDmaCpArm.blen), bc
    ld (vidDmaCpArm.bdst), de
    add hl, bc                   ; src += chunk
    ex de, hl
    add hl, bc
    ex de, hl                    ; dest += chunk
    push hl
    push de
    ld hl, vidDmaCpArm
    ld bc, (vidDmaCpArm_len << 8) | DMA_PORT
    di
    otir
    ei
    pop de
    pop hl
    ret

; Arm programs (zxndma.txt WR bit tables; overlay2.asm dma_prog is
; the canonical full program these derive from). WR2/WR5 persist
; from the session init (vidDmaInit, sent by vid_run_l2setup_body).
vidDmaFiArm:                     ; per-chunk fill arm (15 bytes)
    db $83                       ; WR6: disable (known-clean re-entry)
    db %01111101                 ; WR0: A->B; A addr + length follow
    dw vidRunColour              ; port A = the colour cell (FIXED)
.blen:
    dw 0                         ; block length, exact count (patched)
    db %01100100                 ; WR1: A memory, FIXED, timing follows
    db %00000010                 ; A cycle length 2
    db %10101101                 ; WR4: CONTINUOUS, port B addr follows
.bdst:
    dw 0                         ; port B = dest chunk (patched)
    db $CF                       ; WR6: load
    db $87                       ; WR6: enable - LAST byte; the CPU
                                 ; stalls here until the transfer ends
vidDmaFiArm_len equ $ - vidDmaFiArm

vidDmaCpArm:                     ; per-chunk copy arm (15 bytes)
    db $83                       ; WR6: disable
    db %01111101                 ; WR0: A->B; A addr + length follow
.asrc:
    dw 0                         ; port A = source (patched)
.blen:
    dw 0                         ; block length, exact count (patched)
    db %01010100                 ; WR1: A memory, INCREMENTING, timing
    db %00000010                 ; A cycle length 2
    db %10101101                 ; WR4: CONTINUOUS, port B addr follows
.bdst:
    dw 0                         ; port B = dest (patched)
    db $CF                       ; WR6: load
    db $87                       ; WR6: enable - LAST byte
vidDmaCpArm_len equ $ - vidDmaCpArm

; ---------------------------------------------------------------------
; vid_decode_frame - decode ONE frame payload from the ring at
; vidFramePos (already advanced past this frame's audio block).
; Out: A = terminal opcode (VOP_FEND / VOP_KFLIP), vidFramePos
; advanced to the next frame's audio block. Structural errors never
; return - they jump to vid_run.decfail via vid_dec_abort (SP anchor).
; Ordinary frames paint the VISIBLE surface from cursor 0 (patch in
; place); span-continuation frames restore the spilled hidden-surface
; cursor (nxv2dec's span_cursor rule). Corrupts everything but IX.
; ---------------------------------------------------------------------
vid_decode_frame:
    call vid_src_seek            ; HL = payload cursor, MMU6 mapped
    call vid_dst_setup
    ld iy, vid_stub              ; IYH pinned for the whole payload
    jp vid_next                  ; terminal handlers ret to our caller

; Frame-decode dispatcher (3c): the frame loop calls this; direct-
; serve sessions decode from the SD stream, everything else from the
; RAM ring.
vid_decode_any:
    ld a, (vidDirect)
    or a
    jp nz, vid_decode_frame_ds
    jp vid_decode_frame

; Dest-surface setup from the span state (extracted 3c - shared with
; the direct-serve decode): span-continuation frames restore the
; spilled hidden-surface cursor, ordinary frames start the VISIBLE
; surface at cursor 0. Sets vidDstPage/End, maps MMU2, DE = cursor.
; Corrupts AF, C.
vid_dst_setup:
    ld a, (vidInSpan)
    or a
    jr z, .fresh
    ld a, (vidSpanDstPage)       ; continue the hidden-surface span
    ld (vidDstPage), a
    nextreg NR_MMU2, a
    ld a, (l2BackBank)
    add a, a
    ld c, a
    ld a, (vidDstPages)
    add a, c
    ld (vidDstEnd), a
    ld de, (vidSpanDE)
    ret
.fresh:
    ld a, (l2FrontBank)          ; delta frames patch the VISIBLE
    add a, a                     ; surface in place
    ld (vidDstPage), a
    nextreg NR_MMU2, a
    ld c, a
    ld a, (vidDstPages)
    add a, c
    ld (vidDstEnd), a
    ld de, VID_DST_WIN           ; cursor 0
    ret

; Direct-serve frame decode (3c): the payload arrives ONE BYTE AT A
; TIME off the open CMD18 stream - HL carries the open block's
; remaining byte count for the whole decode (every frame section is
; 512-aligned, so HL is 0 at every section boundary and no cell is
; needed). Ops parse through the always-slow path (vid_fetch is
; vectored to vid_ds_byte); COPY literals ride vid_ds_copy_body's
; inir transport straight to the surface; SKIP/RUN reuse the shared
; dest-side bodies; FEND/PAL/KFLIP land on the ds handlers via the
; per-session stub slot patches. Terminal handlers ret to our caller.
vid_decode_frame_ds:
    xor a
    ld (vidDsFrmBlk), a          ; per-frame section bound reset
    call vid_dst_setup
    ld iy, vid_stub              ; slow_op's jp (iy) needs it
    ld hl, 0                     ; block-remain: at a boundary
    jp vid_ds_next

; ---------------------------------------------------------------------
; vid_src_seek - map the ring page holding the consumer cursor and
; derive the window cursor. RESIDENT: the cursor IS vidFramePos (the
; ring holds the whole file at identity offsets). STREAMING: the
; cursor is vidRingRl, the ring-linear offset (< ringBytes) the
; circular producer/consumer arithmetic maintains - the seek also
; spills it to vidRlStart (vid_dec_done's consumed-bytes base) and
; resets the per-seek source page-walk bound. Out: HL = VID_SRC_WIN +
; (cur & $1FFF), MMU6 mapped, vidSrcBankIdx/Parity/CurPage current.
; Corrupts AF, BC.
; ---------------------------------------------------------------------
vid_src_seek:
    ld a, (vidStreaming)
    or a
    jr nz, .ring
    ld a, (vidFramePos+2)
    add a, a
    add a, a
    ld b, a                      ; pos[23:16] << 2
    ld a, (vidFramePos+1)
    ld c, a
    rlca
    rlca
    and 3
    or b                         ; bank index = pos >> 14
    ld (vidSrcBankIdx), a
    ld b, a
    ld a, c
    rlca
    rlca
    rlca
    and 1                        ; parity = pos bit 13
    ld (vidSrcParity), a
    ld hl, vidRingBanks
    ld a, b
    add hl, a                    ; Z80N (doc 05)
    ld a, (hl)
    add a, a
    ld b, a
    ld a, (vidSrcParity)
    or b                         ; page = bank*2 + parity
    ld (vidSrcCurPage), a
    nextreg NR_MMU6, a
    ld a, c
    and $1F
    or $C0
    ld h, a
    ld a, (vidFramePos)
    ld l, a                      ; HL = window cursor
    ret
.ring:
    ; ring-linear cursor -> window (streaming). pageLin = rl >> 13.
    ld hl, (vidRingRl)           ; L = b0, H = b1
    ld a, (vidRingRl+2)
    ld (vidRlStart), hl
    ld (vidRlStart+2), a
    add a, a
    add a, a
    add a, a
    ld b, a                      ; b2 << 3
    ld a, h
    rlca
    rlca
    rlca
    and 7
    or b                         ; A = linear ring page (0..159)
    ld c, a
    srl a
    ld (vidSrcBankIdx), a        ; bank index = pageLin >> 1
    ld b, a
    ld a, c
    and 1
    ld (vidSrcParity), a
    push hl
    ld hl, vidRingBanks
    ld a, b
    add hl, a                    ; Z80N (doc 05)
    ld a, (hl)
    pop hl
    add a, a
    ld b, a
    ld a, (vidSrcParity)
    or b                         ; page = bank*2 + parity
    ld (vidSrcCurPage), a
    nextreg NR_MMU6, a
    ld a, h
    and $1F
    or $C0
    ld h, a                      ; HL = $C000 | (rl & $1FFF)
    xor a
    ld (vidSrcWalks), a          ; per-seek page-walk bound reset
    ret

; ---------------------------------------------------------------------
; vid_aud_copy - copy the NEXT-to-play frame's REAL audio bytes from
; the ring at vidFramePos into the IDLE vidAudBuf half (LDIR,
; seam-walked), advance the cursors (vidFramePos; streaming also the
; ring-linear cursor + depth), then QUEUE the filled half for the ISR
; (vidAudNextPtr/End, vidAudNextRdy LAST - the release store) and
; toggle the fill half. The ISR never reads the half being filled
; (double buffer), so the 3a torn-read argument is now structural.
; Corrupts AF, BC, DE, HL. Errors (a corrupt file whose audio runs
; off the ring) abort via vid_src_next's own bounds checks.
; ---------------------------------------------------------------------
vid_aud_copy:
    call vid_src_seek
    ld de, (vidAudFillPtr)
    ld bc, (vidABytes)
.seg:
    ld (vidAudNeed), bc
    ; room = $E000 - HL (never 0: seek/next leave HL < $E000)
    xor a
    sub l
    ld c, a
    ld a, $E0
    sbc a, h
    ld b, a                      ; BC = room
    push hl
    ld hl, (vidAudNeed)
    or a
    sbc hl, bc                   ; need - room
    jr c, .last                  ; need < room: final LDIR
    ld (vidAudNeed), hl          ; remainder (may be 0)
    pop hl
    ldir                         ; whole room; HL -> $E000
    call vid_src_next            ; next ring page (preserves BC, DE)
    ld bc, (vidAudNeed)
    ld a, b
    or c
    jr nz, .seg
    jr .adv
.last:
    pop hl
    ld bc, (vidAudNeed)
    ldir
.adv:
    ld hl, (vidFramePos)
    ld bc, (vidABytesPad)
    add hl, bc
    ld (vidFramePos), hl
    jr nc, .noc
    ld hl, vidFramePos+2
    inc (hl)
.noc:
    ld a, (vidStreaming)
    or a
    jr z, vid_aud_queue
    ; streaming: ring cursor += padded block (mod ringBytes), depth
    ; -= its blocks (the gate's staged need covered them)
    ld a, (vidApadBlk)
    ld c, a
    ld b, 0
    ld hl, (vidRingDepth)
    or a
    sbc hl, bc
    jr nc, .dok                  ; DEPTH FLOOR (3c hardening)
 IFDEF DEBUG
    ld a, (vidDepthClip)
    inc a
    ld (vidDepthClip), a
 ENDIF
    ld hl, 0
.dok:
    ld (vidRingDepth), hl
    ld hl, (vidRingRl)
    ld bc, (vidABytesPad)
    add hl, bc
    ld a, (vidRingRl+2)
    adc a, 0
    call vid_rl_mod              ; A:HL mod ringBytes -> vidRingRl
    ; falls into vid_aud_queue
; Hand the filled half to the ISR: Ptr/End first, Rdy LAST (the
; release store) + fill-half toggle. Shared tail (3c): the direct-
; serve audio read (vid_ds_aud_copy) queues through here too.
vid_aud_queue:
    ld hl, (vidAudFillPtr)
    ld (vidAudNextPtr), hl
    ld bc, (vidAudEndOff)        ; = real bytes - 1 (mono) / - 2
    add hl, bc
    ld (vidAudNextEnd), hl
    ; toggle: other = (halfA + halfB) - current (mod 2^16)
    ld de, (vidAudFillPtr)
    ld hl, $FFFF & (vidAudBuf*2 + NXV_AUD_HALF)
    or a
    sbc hl, de
    ld (vidAudFillPtr), hl
    ld a, 1
    ld (vidAudNextRdy), a
    ret

; ---------------------------------------------------------------------
; vid_play - the player core entry. B = video number, C = 0 play-once
; / 1 loop (h_gfx/h_sfx translate GFX n 13/14 / SFX n 9/10 before the
; cross-page hop - the game-facing surface is UNCHANGED). Probes
; PARTn\NNN.VID then root NNN.VID (cold body), then hands off to
; vid_run. Always returns via vid_run's restore paths; the caller
; never resumes (the dispatch trampoline's stacked return).
; ---------------------------------------------------------------------
vid_play:
    ld a, b
    ld (vidNum), a
    ld a, c
    ld (vidLoopMode), a
    ld c, b                      ; video number travels in C
    ld hl, vid_open_video_body   ; cold: name build + PARTn probe +
    push hl                      ; esx open + filemap capture (+ DEBUG
    ld a, VID_PAGE2              ; missing print) - 3c reclaim: the
    jp ovl_map_page              ; hot stub cluster moved cold
.openret:
    ld a, b
    or a
    ret nz                       ; neither name opened
    jp vid_run

; ---------------------------------------------------------------------
; vid_run - orchestration. Entry/exit symmetry: everything touched is
; captured into a vidSv* cell and reversed on every exit path.
; Sequence: save MMU6/7 (hot, before any hop) -> ONE hop to the cold
; orchestrator (3c reclaim: entry capture, open/load, L2 setup and
; the session init are all strictly pre-arm, so the whole ladder
; runs as plain calls on VID_PAGE2 - vid_run_orch_body) -> back hot
; with a verdict -> audio-0 preload + CTC arm (hot) -> the frame
; loop -> reverse-order restore on any exit.
; ---------------------------------------------------------------------
vid_run:
    ; MMU6/MMU7 MUST be captured HERE, hot, before ANY hop (a cold
    ; hop's own bracket would capture its own temporary value).
    ld e, NR_MMU6
    call nr_read
    ld (vidSvMmu6), a
    ld e, NR_MMU7
    call nr_read
    ld (vidSvMmu7), a
    ld hl, vid_run_orch_body
    push hl
    ld a, VID_PAGE2
    jp ovl_map_page
.orchret:
    ; B = 0: ready to arm (entry captured, file loaded/prefilled,
    ; L2/ISRs/session cells all set). B != 0: failed open - the orch
    ; body already unwound (ring freed, stream closed, music tick
    ; restored, DEBUG verdict printed); nothing armed: plain return.
    ld a, b
    or a
    ret nz
 IFDEF DEBUG
    ; SP17 BENCH HOOK (row group 1, direct-serve transport breakdown).
    ; flags+248 selects it; a DIRECT session only (the rows measure the
    ; ds routines and would consume a resident/streamed session's ring
    ; without meaning). Placed HERE deliberately: the session is fully
    ; armed (window open one block into run 0, counters live) but the
    ; CTC is NOT - no ISR, no DI windows, the quiet machine the
    ; settlement's unarmed rows were taken on. Playback is REPLACED:
    ; the rows run, then the ordinary teardown + timeline report.
    ld a, (flags+248)
    or a
    jr z, .nobench
    ld a, (vidDirect)
    or a
    jr z, .nobench               ; not direct: fall through and play
    ld (vidDecSp), sp            ; abort anchor for the bench rows
    call nxb_ds_rows
    jp .restore
.nobench:
 ENDIF
    ; --- audio-0 preload (double buffer): fill half A and consume
    ; the queue it posts - IX starts AT half A (the l2setup body
    ; initialised both ISRs' end markers to half A's end), so Rdy is
    ; re-cleared; the fill pointer is left on half B for frame 1.
    ld (vidDecSp), sp            ; abort anchor: the preload's ring
                                 ; walk / SD read can abort on corrupt
                                 ; input (.restore is safe pre-arm -
                                 ; the CTC park no-ops on an unarmed
                                 ; CTC)
    call vid_aud_copy_any
    xor a
    ld (vidAudNextRdy), a
    ; --- CTC retune (v1-proven sequence, carried verbatim): double
    ; soft-reset, control word, IX + vidAudDone primed BEFORE the
    ; time constant starts the timer (the postmortem ordering rule);
    ; the IM2 stub + ISR end markers were patched cold, above. ---
    ld bc, AUD_CTC_PORT
    ld a, AUD_CTC_RESET
    out (c), a
    out (c), a                   ; double soft-reset (unknown -> clean)
    ld a, AUD_CTC_CW16
    out (c), a                   ; control word - timer not running yet
    ld ix, vidAudBuf             ; the ISR's exclusive play pointer
    ld a, 1
    ld (vidAudDone), a           ; first .pace passes immediately
    ld a, (vidCtcTc)
    ld bc, AUD_CTC_PORT
    out (c), a                   ; time constant -> timer starts NOW

; ---------------------------------------------------------------------
; The frame loop (3b double-buffer phasing). Per frame f: pace on the
; boundary INTO frame f's audio (the ISR swapped into the half queued
; last iteration; while waiting, the streaming producer prefetches SD
; blocks into the ring) -> ring gate (streaming: frame f's payload +
; frame f+1's audio must be buffered - shortfall = the counted
; underrun pace-hold) -> decode/paint frame f's payload (delta:
; visible surface; span chunks: hidden) -> present (KFLIP: palette
; swap + bank flip; delta: palette swap if a PAL rode the frame) ->
; QUEUE frame f+1's audio into the idle half (the ISR swaps at the
; next boundary - no held-sample gap; loop mode rewinds the cursors
; first, so pass N+1's frame-0 audio queues seamlessly; play-once
; skips the queue on the last frame and the drain tail holds) -> key
; check -> frame accounting. DEBUG: 5-phase stamps, one per
; transition (AUDIO now brackets the queue copy AFTER present - the
; copy left the pace path, which is the whole point of the fix).
; ---------------------------------------------------------------------
.frameloop:
 IFDEF DEBUG
    ld a, VID_TL_PACE
    call vid_tl_stamp            ; closes OTHER, opens PACE, frames++
 ENDIF
    ld (vidDecSp), sp            ; abort anchor for this iteration
.pace:
    ld a, (vidAudDone)           ; boundary into this frame's audio?
    or a
    jr nz, .paced
    ld a, (vidStreaming)
    or a
    jr z, .pace                  ; resident: plain spin (v1-identical)
    call vid_prod_step           ; one 512B block max, then re-check
    jr .pace                     ; (the 099 vidProdThrottle lever was
                                 ; RETIRED in 3c - its deliberate-
                                 ; underrun verdict is on record in
                                 ; Cards #3/#4; git holds the lever)
.paced:
    xor a
    ld (vidAudDone), a           ; ack the boundary
    ld a, (vidStreaming)
    or a
    call nz, vid_ring_gate       ; streaming: hold until frame served
 IFDEF DEBUG
    ld a, VID_TL_DECODE
    call vid_tl_stamp
 ENDIF
    call vid_decode_any          ; A = terminal (errors -> .decfail)
 IFDEF DEBUG
    push af
    ld a, VID_TL_FLIP
    call vid_tl_stamp
    pop af
 ENDIF
    ; --- present ---
    cp VOP_KFLIP
    jr nz, .delta
    ; keyframe present: palette swap (if a PAL rode the span) then
    ; the pixel-bank flip - two back-to-back nextreg writes, the
    ; v1-proven CPU choreography (no copper, no independent writer)
    ld a, (vidPalPending)
    or a
    jr z, .kfnopal
    ld a, (vidPalCtrl)
    xor $44                      ; display+edit both to the new bank
    ld (vidPalCtrl), a
    nextreg NR_PAL_CTRL, a
    xor a
    ld (vidPalPending), a
.kfnopal:
    ld a, (l2FrontBank)
    ld b, a
    ld a, (l2BackBank)
    ld (l2FrontBank), a
    nextreg NR_L2_BANK, a        ; NR $12 takes the 16K bank RAW
    ld a, b
    ld (l2BackBank), a
    jr .present_done
.delta:
    ld a, (vidInSpan)
    or a
    jr nz, .present_done         ; span hold frame: nothing presents
    ld a, (vidPalPending)        ; delta-frame PAL presents with its
    or a                         ; frame (nxv2dec applies PAL to the
    jr z, .present_done          ; visible palette on delta frames)
    ld a, (vidPalCtrl)
    xor $44
    ld (vidPalCtrl), a
    nextreg NR_PAL_CTRL, a
    xor a
    ld (vidPalPending), a
.present_done:
 IFDEF DEBUG
    ld a, VID_TL_AUDIO
    call vid_tl_stamp
 ENDIF
    ; --- queue the NEXT frame's audio into the idle half ---
    ld hl, (vidFramesLeft)
    dec hl
    ld a, h
    or l
    jr nz, .qnext                ; frames follow: queue frame f+1
    ld a, (vidLoopMode)
    or a
    jr z, .qskip                 ; last frame, play-once: nothing to
                                 ; queue - the drain tail holds
    ; loop restart: rewind the consumer BEFORE queueing pass N+1's
    ; frame-0 audio (resident: RAM cursor only - no SD, no reopen,
    ; seam-free; streaming: ring cursor + the pass header block)
    call vid_loop_rewind
.qnext:
    call vid_aud_copy_any        ; fills + queues; ISR swaps at the
                                 ; next boundary - zero held samples
.qskip:
 IFDEF DEBUG
    ld a, VID_TL_OTHER
    call vid_tl_stamp
 ENDIF
    call vid_key_any             ; any key ends playback (<= 1 frame
    jr nz, .restore              ; latency; the frame just presented)
    ld hl, (vidFramesLeft)
    dec hl
    ld (vidFramesLeft), hl
    ld a, h
    or l
    jp nz, .frameloop
    ; --- EOF (loop mode already rewound + queued at .qnext) ---
    ld a, (vidLoopMode)
    or a
    jr z, .drainlast
    ld hl, (vidFrames)
    ld (vidFramesLeft), hl
 IFDEF DEBUG
    ld hl, vidLoopPass           ; breadcrumb: pass count for the
    inc (hl)                     ; report's live PASS= field
 ENDIF
    jp .frameloop
.drainlast:
    ; play-once: the last frame is showing; let its audio finish
    ; (nothing queued - the ISR sets done and holds at the end)
    ld a, (vidAudDone)
    or a
    jr z, .drainlast
    jr .restore
.decfail:
    ; vid_dec_abort lands here, SP already reset to vidDecSp (A =
    ; VID_ERR_*, stored to vidErrCode in DEBUG for the report)
.restore:
    ; --- CTC off first (mirrors aud_smp_stop): the ISR cannot fire
    ; once this completes, so everything after may hop cold. ---
    ld bc, AUD_CTC_PORT
    ld a, AUD_CTC_RESET
    out (c), a
    out (c), a
    ld a, DAC_SILENCE
    out (DAC_PORT), a
    out (VID_DAC_LEFT), a        ; park all three DAC ports either
    out (VID_DAC_RIGHT), a       ; ISR could have driven
    call vid_win_close_h         ; the CMD18 window is HOT property
                                 ; when a session held one (streaming/
                                 ; direct): CMD12 + deselect + MF
                                 ; restore before the cold body
                                 ; F_CLOSEs the handle. Idempotent on
                                 ; vidWinOpenH (staged 0 resident), so
                                 ; the call is unconditional (3c).
    ld hl, vid_run_restore_body  ; stub/L2/presentation/MMU2 restore +
    push hl                      ; ring free (EXIT ORDER FIX inside)
    ld a, VID_PAGE2
    jp ovl_map_page
.restore_tail:
 IFDEF DEBUG
    call vid_tl_report           ; fully-torn-down print (hot/cold/hot)
 ENDIF
    ld a, (vidSvMmu6)
    nextreg NR_MMU6, a
    ld a, (vidSvMmu7)
    nextreg NR_MMU7, a
    ret

; Any-key test: A = 0 selects all 8 half-rows via IN A,($FE) (playvid
; idiom; raw port read, no cross-page hop). Out: Z = no key down.
; Corrupts AF.
vid_key_any:
    xor a
    in a, ($FE)
    and %00011111
    cp %00011111
    ret

; ---------------------------------------------------------------------
; Audio CTC ISRs - the v1 per-tick shape (pacing / IX-exclusivity /
; banking-invariant design unchanged) plus the SP15 3b DOUBLE-BUFFER
; SWAP TAIL (the structural-slow fix): the last-sample tick no longer
; holds while the main loop copies the next frame's audio - if the
; other vidAudBuf half is queued (vidAudNextRdy), the ISR swaps INTO
; it in the same interrupt (IX + its own end-marker SMC) and the next
; tick plays the new frame's first sample: a true 625-tick / 40.000ms
; frame period (the 3a player held ~20 ticks per frame = 41.3ms, the
; calibration wave's finding 5). No queue (main loop late, or the
; drain tail after the last frame) = hold the last sample, exactly
; the old behaviour. The per-tick path is byte-identical to 3a; the
; swap tail runs once per frame. Handoff protocol: the main loop
; writes vidAudNextPtr/End first and vidAudNextRdy LAST (the release
; store); the ISR reads Rdy before either. Installed by
; vid_run_l2setup_body patching IM2_CTC_STUB (mono or stereo per the
; header's channel count); end markers initialised to half A + real
; bytes - 1 (mono) / - 2 (stereo) before the CTC time constant starts
; the timer, then owned by each ISR's own swap SMC (same-page - MMU7
; = VID_PAGE for the whole armed window, doc 11 / rubric 3).
; ---------------------------------------------------------------------
video_ctc_isr:
    push af
 IFDEF DEBUG
    ld a, (vidTlTicks)           ; timeline clock - A only, no HL/IX
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
    cp 0                         ; patched: end address low byte
    jr nz, .adv
    ld a, ixh
.cmphi:
    cp 0                         ; patched: end address high byte
    jr nz, .adv
    ; buffer end: swap into the queued half if the main loop has it
    ; ready; else hold the last sample (main late / drain tail)
    ld a, (vidAudNextRdy)
    or a
    jr z, .boundary
    xor a
    ld (vidAudNextRdy), a
    ld ix, (vidAudNextPtr)
    ld a, (vidAudNextEnd)
    ld (.cmplo+1), a
    ld a, (vidAudNextEnd+1)
    ld (.cmphi+1), a
.boundary:
    ld a, 1
    ld (vidAudDone), a
    jr .ret
.adv:
    inc ix
.ret:
    pop af
    ei
    reti

video_ctc_isr_stereo:
    push af
 IFDEF DEBUG
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
    cp 0                         ; patched: end address low byte
    jr nz, .adv
    ld a, ixh
.cmphi:
    cp 0                         ; patched: end address high byte
    jr nz, .adv
    ld a, (vidAudNextRdy)        ; swap tail - see the mono ISR
    or a
    jr z, .boundary
    xor a
    ld (vidAudNextRdy), a
    ld ix, (vidAudNextPtr)
    ld a, (vidAudNextEnd)
    ld (.cmplo+1), a
    ld a, (vidAudNextEnd+1)
    ld (.cmphi+1), a
.boundary:
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

; =====================================================================
; STREAMING PRODUCER (SP15 3b) - the hot half of the SD streaming
; machinery. The cold cluster (VID_PAGE2) opens the file, captures the
; filemap and prefills the whole ring pre-arm; these routines then own
; the CMD18 window for the armed session (the raw contract carried
; verbatim: the window persists across frames and closes only at a
; fragment boundary, a producer rewind, or teardown; while it is open
; NO other filesystem/SD access happens anywhere - structurally true:
; audEnable is frozen and nothing else runs during playback). The
; Multiface stays disabled while the window is open (an NMI would
; corrupt the SD wire); it is briefly re-enabled across each window
; close - fragment boundaries, producer rewinds - and re-disabled by
; the next open, matching v1's per-window shape.
; Every cell these routines touch is HOT (rubric 3); every hardware
; poll is bounded (rubric 6); ini's B consumption is respected - A is
; the block counter (rubric 2, the NXV first-contact lesson).
; =====================================================================

; ---------------------------------------------------------------------
; Streaming ring gate (frame top, post-pace): the staged need blocks
; (payload cap + next audio pad + 1 loop-pass header block) must be
; buffered ahead of the consumer before the frame proceeds. Shortfall
; with blocks still owed = a genuine UNDERRUN: counted once per gated
; frame (DEBUG, the RING= row) and served by an uncapped force-fill
; pace-hold - playback runs late, never corrupt. Bounded: every
; vid_prod_step call raises depth, lowers remain, or aborts through
; its own fault funnels; need <= ring capacity is validated at open.
; Corrupts AF, BC, DE, HL.
; ---------------------------------------------------------------------
vid_ring_gate:
 IFDEF DEBUG
    ld hl, (vidRingDepth)        ; RING= row: minimum frame-top depth
    ld de, (vidRingMin)
    or a
    sbc hl, de
    jr nc, .nomin
    ld hl, (vidRingDepth)
    ld (vidRingMin), hl
.nomin:
 ENDIF
    call .served
    ret nc
 IFDEF DEBUG
    ld hl, (vidRingUnder)        ; one event per gated frame
    inc hl
    ld (vidRingUnder), hl
 ENDIF
.fill:
    call vid_prod_step
    call .served
    jr c, .fill
    ret
.served:
    ; CF clear = frame served: depth >= need, or - PLAY-ONCE ONLY -
    ; the producer owes nothing this pass (the buffered tail is the
    ; whole remainder). In LOOP MODE remain==0 is TRANSIENT until
    ; vid_prod_step's lazy rewind runs, so it still counts as owed:
    ; the fill loop's prod_step rewinds and converges (sustained-late
    ; regime: without this, the unrewound producer let depth drain
    ; and vid_loop_rewind underflowed it past a header block never
    ; produced). Ring-full still terminates the fill: full ring =>
    ; depth >= need (validated at open).
    ld hl, (vidRingDepth)
    ld de, (vidNeedBlk)
    or a
    sbc hl, de
    ret nc
    ld hl, (vidStrmRemainBlk)
    ld a, h
    or l
    jr nz, .owe
    ld a, (vidLoopMode)
    or a
    jr nz, .owe                  ; loop: rewind pending - still owed
    ret                          ; play-once: tail drain, CF clear
.owe:
    scf
    ret

; ---------------------------------------------------------------------
; Produce ONE 512-byte block into the ring at the write cursor. No-op
; when the ring is full or the pass is fully streamed (loop mode
; rewinds the producer to file start and keeps going - the pass
; header block is re-streamed and later consumed by vid_loop_rewind).
; SD faults (CMD reject / bad token / short filemap) abort the whole
; session through the frame loop's SP anchor - clean error exit, the
; ring/window/handle all torn down by the normal restore path.
; Corrupts AF, BC, DE, HL. Preserves IX.
; ---------------------------------------------------------------------
vid_prod_step:
    ld hl, (vidStrmRemainBlk)
    ld a, h
    or l
    jr nz, .have
    ld a, (vidLoopMode)          ; pass fully streamed
    or a
    ret z                        ; play-once: producer done
    xor a                        ; loop: rewind to file start (the
    ld (vidStrmEntryIdx), a      ; runBlocks==0 path below re-opens
    ld h, a                      ; the window at run 0's address)
    ld l, a
    ld (vidStrmRunBlkH), hl
    ld hl, (vidTotalBlk)
    ld (vidStrmRemainBlk), hl
.have:
    ld hl, (vidRingCapBlk)
    ld de, (vidRingDepth)
    or a
    sbc hl, de
    ret z                        ; ring full
    ld hl, (vidStrmRunBlkH)
    ld a, h
    or l
    jr nz, .run
    call vid_win_close_h         ; fragment boundary / rewind: CMD12
    call vid_next_run_h
    jr c, .short                 ; map exhausted with blocks owed
.run:
    call vid_win_open_h          ; CMD18 at the run cursor (idempotent)
    jr c, .cmdfail
    ; write page = ringBanks[pageLin >> 1] * 2 + (pageLin & 1)
    ld a, (vidWrPageLin)
    srl a                        ; A = bank index, CF = parity
    push af
    ld hl, vidRingBanks
    add hl, a                    ; Z80N (doc 05)
    ld b, (hl)
    pop af                       ; CF = parity restored
    ld a, b
    adc a, b                     ; page = bank*2 + parity
    nextreg NR_MMU6, a
    ld hl, (vidWrOfs)
    ld a, h
    or $C0
    ld h, a                      ; HL = window dest (512-aligned)
    call vid_sd_blk_h
    jr c, .tokfail
    ; advance the write cursor (16 blocks per page - never straddles)
    ld hl, (vidWrOfs)
    ld bc, 512
    add hl, bc
    ld a, h
    cp $20
    jr c, .ofsok
    ld hl, 0
    ld a, (vidWrPageLin)
    inc a
    ld c, a
    ld a, (vidRingPageCnt)
    cp c
    jr nz, .pgok
    ld c, 0                      ; circular: wrap to ring page 0
.pgok:
    ld a, c
    ld (vidWrPageLin), a
.ofsok:
    ld (vidWrOfs), hl
    ld hl, (vidRingDepth)
    inc hl
    ld (vidRingDepth), hl
    ld hl, (vidStrmRunBlkH)
    dec hl
    ld (vidStrmRunBlkH), hl
    ld hl, (vidStrmRemainBlk)
    dec hl
    ld (vidStrmRemainBlk), hl
    ret
.short:
    ld a, VID_ERR_SHORT
    jr .fault
.cmdfail:
    ld a, VID_ERR_CMD
    jr .fault
.tokfail:
    ld a, VID_ERR_TOKEN
.fault:
    jp vid_dec_abort_pos         ; producer faults skip the source-pos
                                 ; capture (POS then holds the last
                                 ; decode value - noted in the card)

; Advance to the next hot filemap run. CF set = map exhausted.
; Corrupts AF, C, DE, HL.
vid_next_run_h:
    ld a, (vidStrmEntryIdx)
    ld c, a
    ld a, (vidStrmEntryCnt)
    cp c
    jr z, .out
    ld a, c
    add a, a
    add a, c                     ; idx * 3
    add a, a                     ; idx * 6 (<= 42: 8-entry hot map)
    ld hl, vidHotMap
    add hl, a                    ; Z80N (doc 05)
    ld e, (hl)
    inc hl
    ld d, (hl)
    inc hl
    ld (vidRunAddrLoH), de
    ld e, (hl)
    inc hl
    ld d, (hl)
    inc hl
    ld (vidRunAddrHiH), de
    ld e, (hl)
    inc hl
    ld d, (hl)
    ld (vidStrmRunBlkH), de
    ld a, c
    inc a
    ld (vidStrmEntryIdx), a
    or a
    ret
.out:
    scf
    ret

; Ensure the CMD18 window is open at the hot run cursor (idempotent).
; CF set = command rejected (MF restored, card deselected). Corrupts
; AF, BC, DE, HL.
vid_win_open_h:
    ld a, (vidWinOpenH)
    or a
    ret nz
    call vid_mf_disable_h
    ld a, (vidCardFlagsH)
    and 1                        ; Z = card select (vid_sd_cmd_h reads)
    ld hl, (vidRunAddrHiH)
    ld de, (vidRunAddrLoH)
    ld a, CMD18_READ_MULTIPLE_BLOCK
    call vid_sd_cmd_h
    jr nz, .rej
    ld a, 1
    ld (vidWinOpenH), a
    or a
    ret
.rej:
    call vid_card_desel_h
    call vid_mf_restore_h
    scf
    ret

; Close the window if open: CMD12 + flush + deselect + MF restore.
; Idempotent. Corrupts AF, BC, DE, HL.
vid_win_close_h:
    ld a, (vidWinOpenH)
    or a
    ret z
    ld a, (vidCardFlagsH)
    and 1
    ld a, CMD12_STOP_TRANSMISSION
    call vid_sd_cmd_np_h
    ld b, 8+1
.tail:
    in a, (PORT_SPI_DAT)
    djnz .tail
    call vid_card_desel_h
    call vid_mf_restore_h
    xor a
    ld (vidWinOpenH), a
    ret

vid_card_desel_h:
    ld a, $FF
    out (PORT_SPI_CS), a
    in a, (PORT_SPI_DAT)
    nop
    in a, (PORT_SPI_DAT)
    ret

; SD SPI command (hot clone of the cold vid_sd_cmd; Z on entry =
; card select from the caller's `and 1`). Bounded R1 poll (rubric 6).
vid_sd_cmd_np_h:
    ld h, 0
    ld l, 0
    ld d, 0
    ld e, 0
vid_sd_cmd_h:
    ld b, $FF
    ld c, a
    ld a, SD_CS0
    jr z, .cs
    ld a, SD_CS1
.cs:
    out (PORT_SPI_CS), a
    in a, (PORT_SPI_DAT)
    ld a, c
    ld c, PORT_SPI_DAT
    out (c), a
    ld a, h
    out (c), a
    ld a, l
    out (c), a
    ld a, d
    out (c), a
    ld a, e
    out (c), a
    ld a, b
    out (c), a
    nop
    ld b, 0                      ; bounded R1 poll: 256 tries
.resp:
    in a, (PORT_SPI_DAT)
    inc a
    jr nz, .got
    djnz .resp
    or 1                         ; timeout: NZ (treated as reject)
    ret
.got:
    dec a                        ; Z iff R1 == 0
    ret

; Wait for the $FE data token (hot; bounded 65536 polls - rubric 6).
; CF set = bad/absent token. Corrupts AF, BC. Shared by the block
; reader and the 3c direct-serve stream (the reclaim extraction).
vid_sd_tok_h:
    ld bc, 0                     ; bounded token wait: 65536 polls
.wt:
    in a, (PORT_SPI_DAT)
    inc a
    jr nz, .got
    dec bc
    ld a, b
    or c
    jr nz, .wt
    jr .bad
.got:
 IFDEF DEBUG
    ; SP17 TOKEN-POLL INSTRUMENT (bench row group 1a): the card's
    ; data-token wait is not timeable at raster resolution (~1824 T
    ; per line against a wait of a few hundred T), but it IS exactly
    ; COUNTABLE - BC is the countdown from 0, so -BC is the number of
    ; poll iterations that returned $FF. Accumulated HERE, at .got,
    ; strictly OUTSIDE the poll loop: the loop itself is byte-
    ; identical to Release, so the counted quantity is undistorted.
    ; The ~167 T this block costs lands once per block in EVERY bench
    ; row that opens a block, so it cancels in every row difference;
    ; only the absolute per-block figure carries it (card decode key
    ; subtracts it). 16-bit accumulators: zeroed at bench entry, and
    ; a 250-frame direct pass is ~3.3k blocks x a few polls - inside
    ; the range. Polls per call = (accumulated) + 1 per call, since
    ; the successful poll does not decrement.
    push af
    push de
    push hl
    ld hl, 0
    or a
    sbc hl, bc                   ; HL = -BC = failed polls this call
    ex de, hl
    ld hl, (vidTokPolls)
    add hl, de
    ld (vidTokPolls), hl
    ld hl, (vidTokCalls)
    inc hl
    ld (vidTokCalls), hl
    pop hl
    pop de
    pop af
 ENDIF
    dec a
    cp $FE
    ret z                        ; CF clear from the cp
.bad:
    scf
    ret

; Read one 512-byte block into (HL) (hot clone; 32-ini sixteenths in
; BOTH variants - the extra loop overhead ~434T is ~4% of one block
; read and buys ~65 hot bytes vs the cold Release unroll). A is the
; outer counter (rubric 2 - ini consumes B). CF set = bad token.
vid_sd_blk_h:
    call vid_sd_tok_h
    ret c
    ld c, PORT_SPI_DAT
    ld a, 16                     ; sixteen 32-byte chunks
.blk:
    DUP 32
      ini
    EDUP
    dec a
    jp nz, .blk
    in a, (c)                    ; skip the 2-byte CRC
    nop
    in a, (c)
    or a
    ret

vid_mf_disable_h:
    ld e, NR_PERIPH2
    call nr_read
    ld (vidMfSaveH), a
    and %11110111
    nextreg NR_PERIPH2, a
    ret
vid_mf_restore_h:
    ld a, (vidMfSaveH)
    nextreg NR_PERIPH2, a
    ret

; Loop-restart rewind (called before queueing pass N+1's frame-0
; audio). Resident: RAM cursor only - no SD, no reopen, seam-free.
; Streaming: the producer streamed the pass header block between the
; old tail and the new frames - consume it (ring cursor += 512, depth
; -= 1; the gate's staged +1 guaranteed it is buffered). Corrupts AF,
; BC, DE, HL.
vid_loop_rewind:
    ld hl, 512
    ld (vidFramePos), hl
    xor a
    ld (vidFramePos+2), a
    ld (vidInSpan), a            ; defensive (a valid file never ends
                                 ; mid-span - nxv2dec validates)
    ld a, (vidDirect)
    or a
    jr nz, .direct
    ld a, (vidStreaming)
    or a
    ret z
    ld hl, (vidRingDepth)
    ld a, h
    or l
    jr nz, .pos                  ; DEPTH FLOOR (3c hardening): the
 IFDEF DEBUG                     ; pre-review-fix loop-tail underflow
    ld a, (vidDepthClip)         ; class dies here structurally
    inc a
    ld (vidDepthClip), a
 ENDIF
    jr .dz                       ; hold at 0 (already stored)
.pos:
    dec hl
    ld (vidRingDepth), hl
.dz:
    ld hl, (vidRingRl)
    ld bc, 512
    add hl, bc
    ld a, (vidRingRl+2)
    adc a, 0
    jp vid_rl_mod
.direct:
    ; direct-serve rewind (3c): close the window, reset the producer
    ; run cursor to run 0, re-open and consume the pass header block
    ; through the ds machinery (the per-frame bound's +1 covers it,
    ; exactly the streamed loop's staged header block).
    call vid_win_close_h
    xor a
    ld (vidStrmEntryIdx), a
    ld (vidDsCrcDue), a          ; window closed: no CRC pending
    ld hl, 0
    ld (vidStrmRunBlkH), hl
    ld hl, (vidTotalBlk)
    ld (vidStrmRemainBlk), hl
    ld hl, 0
    call vid_ds_blkopen          ; run 0 reopened + the header block
    jp vid_ds_pad                ; discard all 512 header bytes

; =====================================================================
; DIRECT-SERVE DECODE (SP15 3c) - the header hint's delivery mode:
; literal-heavy (raw-equivalent) streams are served STRAIGHT from the
; SD wire to the Layer 2 surface, v1-style - no ring, no RAM pass.
; Composition: the whole decode runs the ALWAYS-SLOW op path
; (vid_fetch vectored to vid_ds_byte; SKIP/RUN reuse the shared
; dest-side chunked bodies via the SMC exits; COPY literals inir
; port->surface below; FEND/PAL/KFLIP/KSTART via the per-session stub
; slot patches). HL is the open block's remaining byte count for the
; entire armed session phase (frame sections are 512-aligned, so it
; is 0 at every section boundary). The CMD18 window is hot property
; exactly as in streaming (THIRD RULE); the filemap runs/fragment
; boundaries reuse the producer's own hot machinery
; (vid_win_open/close_h + vid_next_run_h). Bounds (rubric 6): every
; block open decrements the whole-pass remain (0 = corrupt payload,
; abort) and counts against the per-frame section bound
; (cap + apad + 1 blocks, staged at open) - a corrupt payload cannot
; read unboundedly; the token/R1 polls carry the settled bounds.
; docs/Z80 citations: doc 01 (inir 21T/B - at the ~22.1T/B SPI wire
; floor the transport is wire-bound by design), doc 05 (16-bit
; min/clip chains), doc 08 (the per-session SMC vectors, patched
; cold through the MMU6 window - rubric 3), doc 11 (no DMA-from-SPI
; - measured-rejected; the inir arms stay <= 256B and IRQ-open, so
; the audio ISR is never starved - the contract-3 concern class).
;
; LATCH HAZARD (review fix, 3c): any ds op that selects a NextReg on
; the $243B/$253B pair ONCE and then relies on the latch across MORE
; THAN ONE byte must re-select after every vid_ds_blkopen call in
; between. blkopen's fragment-boundary/rewind branch calls
; vid_win_open_h -> vid_mf_disable_h -> nr_read, which re-targets the
; SAME select latch (to NR_PERIPH2) to do its own read - a latch a
; caller assumed still pointed at its own register no longer does.
; vid_ds_pal was the one victim (fixed below, re-selects
; unconditionally after every blkopen); no other ds routine holds a
; select across a blkopen call today, but the next one that does must
; follow the same rule.
; =====================================================================

; The direct dispatch loop: every op through the slow parser (whose
; fetch is vectored here per session). 3 bytes - the SMC body exits
; and stub slots point at this.
vid_ds_next:
    jp vid_slow_op

; Fetch one stream byte. In/out: HL = open block's remaining count.
; Preserves BC, DE. Out: A = byte.
vid_ds_byte:
    ld a, h
    or l
    call z, vid_ds_blkopen
    dec hl
    in a, (PORT_SPI_DAT)
    ret

; Open the next 512-byte stream block: consume the previous block's
; CRC, enforce the per-frame section bound and the whole-pass remain,
; walk the filemap at fragment boundaries (close/next/open - the
; producer's own hot pieces), wait the data token (bounded). In: HL =
; 0. Out: HL = 512. Preserves BC, DE. Faults abort the session (SP
; anchor; POS= is not meaningful in direct mode - card decode key).
vid_ds_blkopen:
    push bc
    push de
    ld a, (vidDsCrcDue)
    or a
    jr z, .nocrc
    in a, (PORT_SPI_DAT)         ; the previous block's 2 CRC bytes
    nop
    in a, (PORT_SPI_DAT)
.nocrc:
    ld a, (vidDsFrmBlk)          ; per-frame section bound: payload f
    inc a                        ; + the next audio + a loop header
    ld (vidDsFrmBlk), a          ; block at most (cap + apad + 1)
    ld c, a
    ld a, (vidDsBound)
    cp c
    jr c, .ovr                   ; over the bound: corrupt payload
    ld hl, (vidStrmRemainBlk)    ; whole-pass accounting
    ld a, h
    or l
    jr z, .ovr                   ; reading past the file: corrupt
    dec hl
    ld (vidStrmRemainBlk), hl
    ld hl, (vidStrmRunBlkH)
    ld a, h
    or l
    jr nz, .run
    call vid_win_close_h         ; fragment boundary / rewind resume:
    call vid_next_run_h          ; CMD12, next filemap run, CMD18
    jr c, .short
    call vid_win_open_h
    jr c, .cmdfail
.run:
    ld hl, (vidStrmRunBlkH)
    dec hl
    ld (vidStrmRunBlkH), hl
    call vid_sd_tok_h            ; bounded token wait (shared)
    jr c, .tokfail
    ld a, 1
    ld (vidDsCrcDue), a
    pop de
    pop bc
    ld hl, 512
    ret
.short:
    ld a, VID_ERR_SHORT
    jr .fault
.cmdfail:
    ld a, VID_ERR_CMD
    jr .fault
.ovr:
    ld a, VID_ERR_SRCOVR
    jr .fault
.tokfail:
    ld a, VID_ERR_TOKEN
.fault:
    jp vid_dec_abort_pos         ; pushed BC/DE absorbed by the anchor

; Discard the rest of the open block (every frame section is
; 512-aligned: sections end by discarding to the boundary). In/out:
; HL = remaining count (0 on exit). Corrupts AF.
vid_ds_pad:
    ld a, h
    or l
    ret z
.d:
    in a, (PORT_SPI_DAT)
    dec hl
    ld a, h
    or l
    jr nz, .d
    ret

; Transfer BC bytes from the stream to (DE): inir arms <= 256 bytes,
; interrupts open throughout (the audio ISR rides between arms - the
; wire, not the CPU, is the floor). In: HL = block remain, DE = dest,
; BC = count. Out: DE advanced, HL updated, BC = 0. Corrupts AF.
vid_ds_xfer:
.loop:
    ld a, b
    or c
    ret z
    ld a, h
    or l
    call z, vid_ds_blkopen
    push bc                      ; remaining
    push hl                      ; n = min(remaining, block remain)
    or a
    sbc hl, bc
    pop hl
    jr nc, .nok                  ; remain >= count: n = count
    ld b, h
    ld c, l                      ; n = block remain
.nok:
    ld a, b                      ; clip n to 256 (one inir arm)
    or a
    jr z, .le                    ; < 256
    dec a
    jr nz, .clip                 ; >= 512
    ld a, c
    or a
    jr z, .le                    ; exactly 256
.clip:
    ld bc, 256
.le:
    ld a, c                      ; A = n low byte (0 iff n == 256)
    or a
    sbc hl, bc                   ; block remain -= n
    ex (sp), hl                  ; HL = remaining, TOS = block remain
    or a
    sbc hl, bc                   ; remaining -= n
    ex (sp), hl                  ; HL = block remain, TOS = remaining
    ld b, a                      ; inir count (0 = 256)
    ld c, PORT_SPI_DAT
    ex de, hl                    ; HL = dest (inir writes (HL))
    inir
    ex de, hl                    ; HL = block remain, DE = dest'
    pop bc                       ; remaining
    jr .loop

; Direct COPY body: dest-normalized chunks (column hop + window seam
; via the shared walkers), each served by the inir transport. No
; 256-byte chunk cap here - that cap is the DMA DI-bracket contract
; (contract 3), and this transport holds no DI at all (the inir arms
; are internally <= 256 and IRQ-open). In: BC = literal count.
vid_ds_copy_body:
    ld (vidRemain), bc
.seg:
    ld bc, (vidRemain)
    ld a, b
    or c
    jp z, vid_ds_next
    call vid_dst_norm            ; preserves BC, HL
    call vid_chunk_dst_nocap     ; BC = min(remain, dest/column room)
    push hl
    ld hl, (vidRemain)
    or a
    sbc hl, bc
    ld (vidRemain), hl
    pop hl
    call vid_ds_xfer
    jr .seg

; Direct PAL: 512 palette bytes port -> NR $44, same double-buffer
; choreography as vid_op_pal (edit the hidden bank, flip at present).
; LATCH HAZARD FIX (review, 3c): the select below targets NR_PAL_VALUE9
; on $243B ONCE, then every out (c),a in .pl relies on that latch
; across up to 512 bytes. vid_ds_blkopen's fragment-boundary/rewind
; branch calls vid_win_open_h -> vid_mf_disable_h -> nr_read, which
; re-targets the SAME latch to NR_PERIPH2 for its own read - any
; palette byte written after that (before this fix) landed on
; NR_PERIPH2 instead: silent palette corruption + spurious
; Peripheral-2 writes. Fix: re-select NR_PAL_VALUE9 unconditionally
; immediately after every blkopen call (chosen over an unconditional
; per-byte re-select: blkopen fires at most ~2 times across a 512-byte
; PAL block - roughly +35T total - vs 512 x ~19T unconditionally; both
; are cheap against this cold-ish op's SD-wire cost, but the
; per-blkopen form is exact rather than merely "affordable", doc 01
; T-state accounting).
vid_ds_pal:
    ld a, (vidPalCtrl)
    xor $40                      ; edit the OTHER bank, display as-is
    nextreg NR_PAL_CTRL, a
    nextreg NR_PAL_INDEX, 0
    ld a, 1
    ld (vidPalPending), a
    ld a, NR_PAL_VALUE9
    ld bc, TBBLUE_REG_SEL
    out (c), a
    ld b, high TBBLUE_REG_ACC    ; C stays $3B
    push de
    ld de, NXV_PAL_BYTES
.pl:
    ld a, h
    or l
    jr nz, .byte
    call vid_ds_blkopen           ; preserves BC, DE; MAY reopen the
                                  ; CMD18 window on a fragment boundary
                                  ; (nr_read latch hazard - banner above)
    ld bc, TBBLUE_REG_SEL         ; re-select NR_PAL_VALUE9 (cheap: this
    ld a, NR_PAL_VALUE9           ; branch is taken at most ~2x per PAL
    out (c), a                    ; block, never per-byte)
    ld b, high TBBLUE_REG_ACC     ; C stays $3B
.byte:
    in a, (PORT_SPI_DAT)
    dec hl
    out (c), a
    dec de
    ld a, d
    or e
    jr nz, .pl
    pop de
    jp vid_ds_next

; Direct terminals: the span logic mirrors the RAM handlers; the
; section pad is discarded to the block boundary before returning to
; the frame loop (vid_decode_frame_ds's caller).
vid_ds_kflip:
    ld a, (vidInSpan)
    or a
    jr z, .stray
    xor a
    ld (vidInSpan), a
    ld a, VOP_KFLIP
    jr vid_ds_done
.stray:
    ld a, VID_ERR_OP
    jp vid_dec_abort
vid_ds_fend:
    ld a, (vidInSpan)
    or a
    jr z, .plain
    ld a, (vidDstPage)           ; span hold frame: spill the cursor
    ld (vidSpanDstPage), a       ; (parity with the RAM handler; the
    ld (vidSpanDE), de           ; direct preset emits single-frame
.plain:                          ; spans, but the format allows more)
    ld a, VOP_FEND
vid_ds_done:
    push af
    call vid_ds_pad              ; discard to the block boundary
    pop af
    ret                          ; A = terminal, to the frame loop

; Direct audio read: the next frame's real bytes port -> the idle
; half, pad discarded, then the shared ISR queue handoff.
vid_ds_aud_copy:
    ld hl, 0                     ; sections are block-aligned
    ld de, (vidAudFillPtr)
    ld bc, (vidABytes)
    call vid_ds_xfer
    call vid_ds_pad
    jp vid_aud_queue

; Audio-copy dispatcher (3c): preload + the frame loop's queue call.
vid_aud_copy_any:
    ld a, (vidDirect)
    or a
    jp nz, vid_ds_aud_copy
    jp vid_aud_copy

; ---------------------------------------------------------------------
; Hot cells.
; ---------------------------------------------------------------------
vidNum:          db 0
vidLoopMode:     db 0            ; 0 = play once, 1 = loop

; Header-derived parameter block - staged by nxv2_open_body as ONE
; MMU6-translated LDIR from its cold staging twin (vidP_*, VID_PAGE2;
; the "copy-across" pattern, rubric 3). ORDER AND SIZES MUST MATCH
; the cold block exactly (VIDP_LEN asserted there).
vidShape:        db 0            ; width code: 0 = 256/mode-0, 1 = 320/mode-1
vidHeightB:      db 0            ; height byte (0 = 256)
vidGapFlag:      db 0            ; 1 = mode-1 letterbox (column gaps)
vidDstPages:     db 0            ; dest surface span: 10 (mode-1) / 6
vidClipY1:       db 0
vidClipY2:       db 0
vidYofs:         db 0
vidAChan:        db 0            ; 1 mono / 2 stereo
vidABytes:       dw 0            ; REAL audio bytes/frame
vidABytesPad:    dw 0            ; = (real + 511) & ~511 (wire block)
vidFrames:       dw 0            ; container frame count
vidFileEnd:      ds 3            ; file size (24-bit; == last frame's
                                 ; rounded payload end)

; Resident ring (source): allocated pool banks, in load order. The
; seam walker derives page = bank*2 + parity, so only banks are
; listed (80 bytes hot instead of 160).
vidRingBankCnt:  db 0
vidRingBanks:    ds VID_RING_MAX

; Decode session state.
vidFramePos:     ds 3            ; linear file position of the current
                                 ; frame section (24-bit, 512-aligned)
vidFramesLeft:   dw 0
vidSrcBankIdx:   db 0
vidSrcParity:    db 0            ; 0 = bank's lower 8K page, 1 = upper
vidSrcCurPage:   db 0
vidDstPage:      db 0
vidDstEnd:       db 0            ; one past the last valid dest page
vidInSpan:       db 0            ; inside a KSTART..KFLIP span
vidSpanDstPage:  db 0            ; span cursor spill (FEND-in-span)
vidSpanDE:       dw 0
vidPalPending:   db 0            ; a PAL block awaits its display flip
vidPalCtrl:      db 0            ; which L2 palette bank is DISPLAYED
                                 ; (PAL_L2_FIRST/SECOND; NR $43 is not
                                 ; reliably readable - tracked in SW)
vidRunColour:    db 0            ; DMA fill's FIXED port A source
vidRemain:       dw 0
vidAudNeed:      dw 0
vidDecSp:        dw 0            ; frame-loop SP anchor (abort path)
vidCtcTc:        db 0

; --- 3b streaming session cells (staged by nxv2_open_body; every
; producer/gate/consumer-wrap read is hot - rubric 3) ---
vidStreaming:    db 0            ; 0 = resident, 1 = ring streaming
vidRingRl:       ds 3            ; consumer ring-linear cursor
vidRlStart:      ds 3            ; payload-start spill (vid_src_seek)
vidRlNew:        ds 3            ; vid_dec_done_strm scratch
vidRingBytes:    ds 3            ; ring capacity in bytes (cnt << 14)
vidRingCapBlk:   dw 0            ; ring capacity in 512B blocks
vidRingDepth:    dw 0            ; buffered blocks (produced-consumed)
vidNeedBlk:      dw 0            ; gate need: cap + apad + 1 blocks
vidApadBlk:      db 0            ; audio section blocks (1..3)
vidWalkMax:      db 0            ; per-seek source page-walk bound
vidSrcWalks:     db 0
vidRingPageCnt:  db 0            ; cnt * 2 (producer wrap modulus)
vidWrPageLin:    db 0            ; producer write cursor: ring page +
vidWrOfs:        dw 0            ; offset (0..$1FFF, 512-aligned)
vidTotalBlk:     dw 0            ; whole-file blocks (producer rewind)
vidStrmRemainBlk: dw 0           ; blocks still to stream this pass
vidStrmEntryIdx: db 0            ; hot filemap cursor
vidStrmEntryCnt: db 0
vidStrmRunBlkH:  dw 0            ; blocks left in the current run
vidRunAddrLoH:   dw 0            ; current run's card address
vidRunAddrHiH:   dw 0
vidCardFlagsH:   db 0
vidMfSaveH:      db 0
vidWinOpenH:     db 0
vidHotMap:       ds VID_STRM_HOT_ENT*6

; --- 3c direct-serve session cells (staged by nxv2_open_body's
; .direct_setup; the run/remain/window cells above are SHARED with
; the streaming producer - only one delivery mode is ever armed) ---
vidDirect:       db 0            ; 1 = direct-serve session
vidDsCrcDue:     db 0            ; an open block's CRC pends on the wire
vidDsFrmBlk:     db 0            ; blocks consumed this frame section
vidDsBound:      db 0            ; per-frame bound: cap + apad + 1

; --- audio double-buffer cells (3b structural-slow fix) ---
vidAudFillPtr:   dw 0            ; the half the next copy fills
vidAudNextPtr:   dw 0            ; queued half (ISR swaps into it)
vidAudNextEnd:   dw 0            ; its end-marker value
vidAudNextRdy:   db 0            ; handoff release store, written LAST
vidAudEndOff:    dw 0            ; real bytes - 1 (mono) / - 2 (stereo)

; Double-buffered play feed - the ISR plays one NXV_AUD_HALF half via
; IX while the frame loop fills the other; full rate, no decimation
; (NXV_AUD_HALF bounds the header field at open). 3c: the buffer
; lives in the session's AUDIO BANK, pinned at MMU3 for the whole
; armed window (VID_AUD_WIN - the 2560-byte hot-page reclaim; see
; the FOURTH RULE in the file header).
vidAudBuf        equ VID_AUD_WIN
    ASSERT NXV_AUD_BUF_MAX <= $2000
vidAudDone:      db 0

; Entry/exit symmetry captures (hot pair only - MMU6/7 are written
; hot pre-hop and read hot in .restore_tail; every other vidSv* cell
; is touched exclusively by the cold entry/l2setup/restore bodies and
; moved to VID_PAGE2 in the 3c reclaim - dropping their bracket
; translations with them).
vidSvMmu6:       db 0
vidSvMmu7:       db 0

 IFDEF DEBUG
; DEBUG frame-timeline instrument state. vidTlTicks..vidLoopPass is
; zeroed at session start (l2setup body); vidTlFillFrames sits AFTER
; the zero span (it is written by nxv2_open_body BEFORE the wipe
; runs) and inside the report's copy span. The accumulators must stay
; contiguous and in this exact order (the LDIR + indexed access).
vidTlTicks:      dw 0            ; video-ISR tick count (the clock)
vidTlLastTick:   dw 0
vidTlLastPhase:  db 0
vidTlFrames:     dw 0
vidTlAcc:        ds VID_TL_PHASES*4
vidErrCode:      db 0            ; 0 = clean; VID_ERR_* on abort
vidErrOp:        db 0            ; the offending opcode byte (ERR=OP)
vidErrPos:       ds 3            ; breadcrumb: failing source position
                                 ; (24-bit linear file offset; only
                                 ; meaningful when ERR != 0)
vidLoopPass:     db 0            ; live loop-pass counter (0 = pass 1);
                                 ; reported as PASS= on EVERY exit
vidRingMin:      dw 0            ; RING= row: min frame-top depth (3b;
                                 ; staged by the open body like
                                 ; vidTlFillFrames - outside the zero
                                 ; span, inside the report copy)
vidRingUnder:    dw 0            ; RING= row: gate underrun events
vidDepthClip:    db 0            ; RING= row third field (3c): depth-
                                 ; floor clamp events - MUST be 00
                                 ; (a nonzero value = a bookkeeping
                                 ; bug the floor contained)
vidTlFillFrames: dw 0            ; ring load/prefill duration, 50Hz
                                 ; frames (frameCounter delta)
VID_TL_ZERO_LEN  equ vidLoopPass + 1 - vidTlTicks
VID_TL_BLOCK_LEN equ vidTlFillFrames + 2 - vidTlTicks

; DEBUG timeline stamp: A = new phase id (VID_TL_*). Accumulates the
; tick delta since the previous stamp into the phase that was active,
; then opens the new phase. Phase 0 (PACE) also counts a frame.
; Never touches IX (the ISR's pointer). Corrupts AF, BC, DE, HL.
vid_tl_stamp:
    push af
    ld hl, (vidTlTicks)
    ld de, (vidTlLastTick)
    ld (vidTlLastTick), hl
    or a
    sbc hl, de
    ex de, hl                    ; DE = delta ticks
    ld a, (vidTlLastPhase)
    add a, a
    add a, a
    ld l, a
    ld h, 0
    ld bc, vidTlAcc
    add hl, bc
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
    or a                         ; VID_TL_PACE == 0
    ret nz
    ld hl, (vidTlFrames)
    inc hl
    ld (vidTlFrames), hl
    ret

; Post-teardown report trampoline (hot/cold/hot - MMU7 back to
; VID_PAGE on return; reached only after the CTC is parked).
vid_tl_report:
    ld hl, vid_tl_report_body
    push hl
    ld a, VID_PAGE2
    jp ovl_map_page
vid_tl_report_ret:
    ret

; =====================================================================
; NXB - SP17 PLAYER-PATH SILICON BENCH (the SP15 3a NXBEN revival).
; DEBUG builds only; Release carries none of it (byte-identity is a
; commit-time gate). Owner card: .superpowers/sdd/sp14a-task-4-report
; .md section 42.
; =====================================================================
; WHAT CHANGED vs THE RETIRED NXBEN (commit 0c292ae, stripped at
; 08edaf5): that bench measured PROTOTYPE kernels to settle the format
; freeze, so it carried its own copies of everything (its own stub
; page, its own fill/copy kernels, its own SD primitives, ~2.4KB). The
; player has SHIPPED since; every question SP17 needs answered is
; about the code that actually runs. So this revival keeps NXBEN's
; INSTRUMENT (raster frame clock, raw-count rows, the F/D reporting
; convention, the flags+250 mode entry) and points every measured loop
; at the PRODUCTION routines - vid_ds_blkopen / vid_ds_pad /
; vid_ds_xfer / vid_sd_blk_h / vid_stub / vid_copy_ldi / vid_fill_cpu
; / vid_copy_dma / vid_fill_dma are CALLED, never re-implemented. That
; is also why the bench lives HERE, on VID_PAGE: those routines are
; MMU7-resident on this page and no other page can reach them.
;
; CLOCK (carried verbatim from NXBEN, so results stay on the settled
; scale): the raster line pair NR $1E/$1F. One wrap = one frame; rows
; report RAW counts in hex - R = reps completed, F = wraps, D =
; endline - startline (two's complement). T = (F*LPF + D) * TPL, the
; card carries LPF/TPL for the owner's timing mode (128K/+3 VGA 50Hz:
; LPF=311, TPL=1824 at 28MHz). Nothing here assumes a mode. One
; raster poll per rep only (poll cost is well under 1% of every row).
;
; ROW GROUPS (the card decodes each; every row is a DIFFERENCE that
; isolates ONE cost, or the row is not worth running):
;   1 direct-serve transport breakdown - rides the LIVE armed direct
;     session (see nxb_ds_rows); answers card5-settlement-report.md
;     :282-287, "~3,100 T/block is attributed, not measured".
;   2 op dispatch envelope - the shipping vid_stub / NXVNEXT path.
;   3 COPY kernel across the size distribution real streams produce
;     (census: COPY p50 = 1-5 B, 61-99% of COPY ops are 1-8 B).
;   4 fill crossover + the DMA DI-window margin.
;
; STANDALONE MODES (2-4) synthesize their op streams into a pool bank
; at MMU6 and paint a second pool bank at MMU2 - NOT Layer 2, so no
; display state is disturbed and no session is needed. Streams are
; sized so the source cursor never reaches $DF00 and the dest cursor
; never leaves the 8K window, so the seam walkers are deliberately NOT
; exercised here (they are their own question, not this one's).
; vidDecSp is anchored at entry: a structural fault therefore unwinds
; into the ordinary abort path and prints ERR= rather than hanging.
; =====================================================================

NXB_ROW0         equ 8       ; bench rows start here (the timeline
                             ; report owns 24-29)
NXB_LINE_MSB     equ $1E     ; active video line, bit 8
NXB_LINE_LSB     equ $1F     ; active video line, bits 7:0

; ---------------------------------------------------------------------
; Entry from nxb_trampoline (overlay0.asm, EXTERN vector 12). Mode in
; flags+250 (self-clearing, the established stage-ladder convention).
; Modes 2/3/4 run standalone; mode 1 is NOT reachable here - the
; direct-serve rows need a live armed session and ride the player
; instead (flags+248 + a VDIR-shaped verb; see nxb_ds_rows).
; Corrupts everything.
; ---------------------------------------------------------------------
nxb_entry:
    ld (vidDecSp), sp            ; abort anchor for the standalone
                                 ; modes (block header). The direct
                                 ; rows keep vid_run's own anchor -
                                 ; theirs is a live session's.
    ld a, (flags+250)
    ld (nxbMode), a
    xor a
    ld (flags+250), a
    ld a, NXB_ROW0
    ld (nxbRow), a
    call nxb_ops_setup
    jr c, .nobank
    ld a, (nxbMode)
    ld hl, nxbTabOpd
    cp 2
    jr z, .go
    ld hl, nxbTabCpy
    cp 3
    jr z, .go
    ld hl, nxbTabKrn
    cp 4
    jr z, .go
    ld hl, nxbTabOpd            ; unknown mode: the dispatch table
.go:
    call nxb_run_table
    jp nxb_ops_restore
.nobank:
    ld hl, nxbMsgBank            ; setup may already hold one bank -
    call nxb_fail_row            ; the restore frees whatever it took
    jp nxb_ops_restore

; ---------------------------------------------------------------------
; Standalone setup: two pool banks (source stream / paint target), the
; decode loop's session cells staged flat, the per-session SMC slots
; pointed at the RAM+flat set (a previous video session may have left
; the direct-serve set), the FEND stub slot diverted to nxb_term (the
; shipping vid_op_fend runs vid_dec_done's file-position accounting,
; which is meaningless with no session), and the zxnDMA WR2/WR5
; one-time program sent (the shipping vidDmaInit lives on VID_PAGE2,
; unreachable from here - nxbDmaInit below is its 4-byte twin).
; CF set = no free bank. Corrupts everything.
; ---------------------------------------------------------------------
nxb_ops_setup:
    ; audEnable FROZEN for the whole visit (vid_run's own music-tick
    ; freeze, and the retired bench's). Without it the 50Hz im2_isr
    ; takes its aud_tick branch, which SAVES AND REMAPS MMU6/MMU7 to
    ; reach the audio banks - a row's source window would vanish mid-
    ; kernel. The frame tick itself stays live and costs one ISR per
    ; 50Hz frame in every row alike (well under 1%, disclosed on the
    ; card). The direct rows need no freeze of their own: the player
    ; has already frozen audEnable by the time the hook fires.
    ld a, (audEnable)
    ld (nxbSvAudEn), a
    xor a
    ld (audEnable), a
    ld e, NR_MMU6
    call nr_read
    ld (nxbSvMmu6), a
    ld e, NR_MMU2
    call nr_read
    ld (nxbSvMmu2), a
    xor a
    ld (nxbBankCnt), a
    call bank_alloc
    ret c
    ld (nxbSrcBank), a
    ld hl, nxbBankCnt
    inc (hl)
    add a, a
    nextreg NR_MMU6, a
    call bank_alloc
    ret c
    ld (nxbDstBank), a
    ld hl, nxbBankCnt
    inc (hl)
    add a, a
    ld (nxbDstP), a
    ld (vidDstPage), a
    nextreg NR_MMU2, a
    add a, 2
    ld (vidDstEnd), a            ; one bank = two 8K pages
    xor a
    ld (vidGapFlag), a           ; flat: no column bookkeeping
    ld (vidStreaming), a
    ld (vidInSpan), a
    ld (vidDirect), a
    ; per-session SMC: RAM fetch, flat fast handlers, RAM bodies
    ld hl, vid_fetch_ram
    ld (vid_fetch.vec + 1), hl
    ld hl, vid_next
    ld (vid_skip_body.next + 1), hl
    ld (vid_run_body.next + 1), hl
    ld (vid_op_kstart.next + 1), hl
    ld hl, vid_copy_body
    ld (vid_slow_op.cj + 1), hl
    ld hl, vf_op_skip8
    ld (vid_stub + VOP_SKIP8 + 1), hl
    ld hl, vf_op_run8
    ld (vid_stub + VOP_RUN8 + 1), hl
    ld hl, vf_op_copy8
    ld (vid_stub + VOP_COPY8 + 1), hl
    ld hl, nxb_term              ; FEND -> the bench terminal
    ld (vid_stub + VOP_FEND + 1), hl
    ld hl, nxbDmaInit
    ld bc, (nxbDmaInit_len << 8) | DMA_PORT
    otir
    or a
    ret

; Undo the setup: FEND stub back to the shipping handler, then the
; shared reclaim. The other SMC slots are re-patched by every video
; open, so they are left as staged (the same rule the player's own
; vid_stage_common follows).
nxb_ops_restore:
    ld hl, vid_op_fend
    ld (vid_stub + VOP_FEND + 1), hl
    ; falls into nxb_reclaim

; Shared standalone reclaim - called on the CLEAN exit above and from
; vid_dec_abort_pos on a structural fault (review fix). nxbBankCnt is
; the ownership flag and is zeroed here, so the routine is idempotent
; and a plain video session's own abort runs it as a 7-cycle no-op.
; The abort case ALSO has to stage vidSvMmu6/vidSvMmu7: the standalone
; modes never went through vid_run, so those cells hold a previous
; session's values (or none), and vid_run.restore_tail - which the
; abort chain reaches - would otherwise map two arbitrary pages and
; leave MMU7 off VID_PAGE for the ret that follows.
nxb_reclaim:
    ld a, (nxbBankCnt)
    or a
    ret z
    ld a, (nxbSrcBank)
    call bank_free
    ld a, (nxbBankCnt)
    dec a
    jr z, .noban
    ld a, (nxbDstBank)
    call bank_free
.noban:
    xor a
    ld (nxbBankCnt), a           ; ownership released (idempotent)
    ld a, (nxbSvMmu6)
    nextreg NR_MMU6, a
    ld (vidSvMmu6), a
    ld a, VID_PAGE
    ld (vidSvMmu7), a
    ld a, (nxbSvMmu2)
    nextreg NR_MMU2, a
    ld a, (nxbSvAudEn)
    ld (audEnable), a
    ret

; The bench's frame terminal: FEND lands here instead of the shipping
; vid_dec_done chain. The op loop keeps the stack level between ops,
; so this ret returns straight to nxb_row's `call nxb_body`.
nxb_term:
    ret

; ---------------------------------------------------------------------
; Row table walker. HL = table; entries are 8 bytes:
;   dw tag, db opcode, dw count, db ops-per-rep, dw reps
; terminated by a zero tag pointer. Builds the stream once per row
; (untimed), then runs the row.
; ---------------------------------------------------------------------
nxb_run_table:
    ld a, (hl)
    inc hl
    ld d, (hl)
    inc hl
    ld e, a
    or d
    ret z                        ; end of table
    push hl
    ex de, hl
    ld (nxbTag), hl              ; tag
    pop hl
    ld a, (hl)
    inc hl
    ld (nxbOpc), a
    ld e, (hl)
    inc hl
    ld d, (hl)
    inc hl
    ld (nxbCnt), de
    ld a, (hl)
    inc hl
    ld (nxbOps), a
    ld e, (hl)
    inc hl
    ld d, (hl)
    inc hl
    ld (nxbReps), de
    push hl
    call nxb_build
    ld hl, nxb_ops_body
    ld (nxb_body + 1), hl
    call nxb_row
    pop hl
    jr nxb_run_table

; Build one rep's op stream at $C000: nxbOps copies of the row's op,
; then a FEND. COPY literal bodies are left as whatever the bank
; holds (their VALUES cannot change the cost - LDI and zxnDMA are
; data-independent).
nxb_build:
    ld hl, DATA_WINDOW
    ld a, (nxbOps)
    ld b, a
.op:
    push bc
    ld a, (nxbOpc)
    ld (hl), a
    inc hl
    ld bc, (nxbCnt)
    ld (hl), c
    inc hl
    cp VOP_SKIP16
    jr z, .hi
    cp VOP_RUN16
    jr z, .hi
    cp VOP_COPY16
    jr nz, .nohi
.hi:
    ld (hl), b
    inc hl
.nohi:
    cp VOP_RUN8
    jr z, .col
    cp VOP_RUN16
    jr z, .col
    cp VOP_COPY8
    jr z, .lit
    cp VOP_COPY16
    jr z, .lit
    jr .done
.col:
    ld (hl), $55                 ; fill colour (value-independent)
    inc hl
    jr .done
.lit:
    add hl, bc                   ; step over the literal body
.done:
    pop bc
    djnz .op
    ld (hl), VOP_FEND
    ret

; One rep of a standalone op row: reset both cursors and run the
; SHIPPING decode loop over the built stream.
nxb_ops_body:
    ld a, (nxbDstP)
    ld (vidDstPage), a
    nextreg NR_MMU2, a
    ld de, VID_DST_WIN
    ld hl, DATA_WINDOW
    ld iy, vid_stub              ; IYH pinned (the shipping contract)
    jp vid_next

; ---------------------------------------------------------------------
; Row runner: nxbReps reps of the SMC-vectored body, raster-timed,
; one printed row. In: nxbTag/nxbOps/nxbReps set, body vectored.
; ---------------------------------------------------------------------
nxb_row:
    ld hl, (nxbReps)
    ld (nxbLeft), hl
    ld hl, 0
    ld (nxbFrames), hl
    call nxb_line
    ld (nxbPrev), hl
    ld (nxbL0), hl
.rep:
    call nxb_body
    call nxb_tick
    ld hl, (nxbLeft)
    dec hl
    ld (nxbLeft), hl
    ld a, h
    or l
    jr nz, .rep
    call nxb_line
    ld (nxbL1), hl
    ; ---- print: TAG O=xx R=xxxx F=xxxx D=xxxx ----
    call nxb_at
    ld hl, (nxbTag)
    call dbg_puts
    ld hl, nxbMsgO
    call dbg_puts
    ld a, (nxbOps)
    call dbg_hex8
    ld hl, nxbMsgR
    call dbg_puts
    ld hl, (nxbReps)
    ld de, (nxbLeft)
    or a
    sbc hl, de
    call dbg_hex16
    ld hl, nxbMsgF
    call dbg_puts
    ld hl, (nxbFrames)
    call dbg_hex16
    ld hl, nxbMsgD
    call dbg_puts
    ld hl, (nxbL1)
    ld de, (nxbL0)
    or a
    sbc hl, de
    jp dbg_hex16                 ; line delta, two's complement
nxb_body:
    jp 0                         ; SMC: the row's per-rep body

; Cursor to the next bench row, column 0. Corrupts AF, BC.
nxb_at:
    ld a, (nxbRow)
    ld b, a
    inc a
    ld (nxbRow), a
    ld c, 0
    jp dbg_at

; Read the raster line (NR $1E:$1F) with a bounded stability retry.
; Out: HL = line (9 bits). Corrupts AF, BC, D.
nxb_line:
    ld d, 4                      ; bounded retries (rubric 6)
.rd:
    ld bc, TBBLUE_REG_SEL
    ld a, NXB_LINE_MSB
    out (c), a
    inc b
    in h, (c)
    dec b
    ld a, NXB_LINE_LSB
    out (c), a
    inc b
    in l, (c)
    dec b
    ld a, NXB_LINE_MSB
    out (c), a
    inc b
    in a, (c)
    cp h
    jr z, .ok
    dec d
    jr nz, .rd
.ok:
    ld a, h
    and 1
    ld h, a
    ret

; Frame tick: a non-monotonic line reading means the raster wrapped.
nxb_tick:
    call nxb_line
    ld de, (nxbPrev)
    ld (nxbPrev), hl
    or a
    sbc hl, de
    ret nc
    ld hl, (nxbFrames)
    inc hl
    ld (nxbFrames), hl
    ret

; Tagged failure row (HL = message).
nxb_fail_row:
    push hl
    call nxb_at
    pop hl
    jp dbg_puts

; =====================================================================
; ROW GROUP 1 - DIRECT-SERVE TRANSPORT BREAKDOWN.
; Entered from vid_run once the orchestrator reports a good open and
; BEFORE the audio preload / CTC arm, so the machine is quiet (no ISR,
; no DI windows) - the same unarmed condition the settlement's
; unarmed rows were taken in. The session is fully staged at that
; point: the CMD18 window is open one block into run 0, vidDsCrcDue
; is 0, and the run/pass counters are live. The bench consumes real
; blocks off the fixture and then leaves through the ordinary
; teardown - playback is REPLACED by the bench, not instrumented.
;
; THE DECOMPOSITION (this is the whole point - each row is one term):
;   DTA = vid_sd_blk_h                  = tok + 512*wire + crc + ovh
;   DTI = vid_ds_blkopen + 512 raw ini  = crc + book + tok + 512*wire
;                                         + ovh
;   DTB = vid_ds_blkopen + vid_ds_pad   = crc + book + tok + pad512
;                                         + ovh
;   DTC = vid_ds_blkopen + xfer(512)    = crc + book + tok + xfer512
;                                         + ovh
;   DTD = vid_ds_blkopen + 4 x xfer(128)
; so:
;   DTI - DTA = vid_ds_blkopen's BOOKKEEPING, absolutely, with no
;               modelled term anywhere in it (the token wait, the CRC
;               consume, the 512-byte wire cost and the loop overhead
;               are byte-identical on both sides and cancel).
;   DTB - DTI = vid_ds_pad's excess over a bare ini (the ~37 vs ~21
;               T/B claim, measured).
;   DTC - DTI = vid_ds_xfer's clip/min chain over a bare ini.
;   DTD - DTC = 2 extra inir arms + 3 extra call entries = the
;               per-arm price the ~144 arms/frame pay.
;   TOK row   = the poll counters (vid_sd_tok_h's DEBUG instrument):
;               the data-token wait in POLLS, which is the one term
;               that is hardware and immovable.
; Every row opens the same number of blocks, so the token instrument's
; ~167 T lands identically in all of them and cancels in every
; difference above.
;
; The per-frame section bound is lifted for the visit (vidDsBound =
; 255, vidDsFrmBlk reset per row) - the bench's block runs are not
; frame sections. Rows that bypass vid_ds_blkopen (DTA) settle the
; run/pass counters themselves afterwards, untimed, so the session
; stays honest for the teardown.
; =====================================================================
NXB_DS_REPS      equ 128     ; blocks per direct row

nxb_ds_rows:
    xor a
    ld (flags+248), a            ; self-clearing
    ld (nxbOps), a               ; no ops on these rows: O prints 00
    ld a, NXB_ROW0
    ld (nxbRow), a
    ld hl, 0
    ld (vidTokPolls), hl
    ld (vidTokCalls), hl
    ; Landing page for the block reads: the game's HIDDEN Layer 2 back
    ; surface, NOT a pool allocation. Review fix - every row here calls
    ; vid_ds_blkopen, whose SD faults jump to vid_dec_abort_pos and
    ; from there straight into vid_run's teardown, so ANY code after
    ; the row loop (a bank_free included) is unreachable on a fault
    ; and a pool bank would be stranded permanently. Borrowing the
    ; back surface owes nothing: it is guaranteed to exist (the gfx
    ; double buffer), it is not displayed, the teardown's snapshot
    ; restore puts it back, and the verb's own PROCESS 10 redraws the
    ; location afterwards either way. 512 bytes of stream data land in
    ; it and are never read.
    ld a, (l2BackBank)
    add a, a
    nextreg NR_MMU6, a
    ld a, 255
    ld (vidDsBound), a           ; the bench is not a frame section
    ld hl, NXB_DS_REPS
    ld (nxbReps), hl
    ; ---- DTA: the raw producer block read (also the ring prefill's
    ; own per-block cost - row group 4's ring-vs-direct question) ----
    call nxb_ds_pre
    ld hl, nxb_ds_a
    ld (nxb_body + 1), hl
    ld hl, nxbTagDTA
    ld (nxbTag), hl
    call nxb_row
    call nxb_ds_settle           ; DTA never called blkopen
    ; ---- DTI: shipping blkopen + the same 512-byte ini ----
    call nxb_ds_pre
    ld hl, nxb_ds_i
    ld (nxb_body + 1), hl
    ld hl, nxbTagDTI
    ld (nxbTag), hl
    call nxb_row
    ; ---- DTB: shipping blkopen + vid_ds_pad ----
    call nxb_ds_pre
    ld hl, nxb_ds_b
    ld (nxb_body + 1), hl
    ld hl, nxbTagDTB
    ld (nxbTag), hl
    call nxb_row
    ; ---- DTC: shipping blkopen + one 512-byte vid_ds_xfer ----
    call nxb_ds_pre
    ld hl, nxb_ds_c
    ld (nxb_body + 1), hl
    ld hl, nxbTagDTC
    ld (nxbTag), hl
    call nxb_row
    ; ---- DTD: shipping blkopen + four 128-byte vid_ds_xfers ----
    call nxb_ds_pre
    ld hl, nxb_ds_d
    ld (nxb_body + 1), hl
    ld hl, nxbTagDTD
    ld (nxbTag), hl
    call nxb_row
    ; ---- TOK: the token-poll instrument ----
    call nxb_at
    ld hl, nxbTagTOK
    call dbg_puts
    ld hl, nxbMsgP
    call dbg_puts
    ld hl, (vidTokPolls)
    call dbg_hex16
    ld hl, nxbMsgN
    call dbg_puts
    ld hl, (vidTokCalls)
    jp dbg_hex16                 ; no cleanup owed: the landing page
                                 ; is borrowed, not allocated, and
                                 ; MMU6 is restored by the teardown

; Per-row preamble (untimed): clear the section counter and the CRC
; flag. DTA's reader consumes its own CRC; every other row's blkopen
; consumes the previous block's, so the flag has to start clean.
nxb_ds_pre:
    xor a
    ld (vidDsFrmBlk), a
    ld (vidDsCrcDue), a
    ret

; DTA settle (untimed): DTA read blocks straight off the open window
; without going through vid_ds_blkopen, so the run and pass counters
; owe NXB_DS_REPS. Charge them here.
nxb_ds_settle:
    ld hl, (vidStrmRunBlkH)
    ld de, NXB_DS_REPS
    or a
    sbc hl, de
    ld (vidStrmRunBlkH), hl
    ld hl, (vidStrmRemainBlk)
    or a
    sbc hl, de
    ld (vidStrmRemainBlk), hl
    ret

; --- the five direct-row bodies ---
nxb_ds_a:
    ld hl, DATA_WINDOW
    jp vid_sd_blk_h              ; token + 512 ini + CRC (bounded)
nxb_ds_i:
    ld hl, 0
    call vid_ds_blkopen
    ld hl, DATA_WINDOW
    ld c, PORT_SPI_DAT
    ld a, 16                     ; A is the outer counter (rubric 2 -
.b:                              ; ini consumes B), the vid_sd_blk_h
    DUP 32                       ; shape byte-for-byte
      ini
    EDUP
    dec a
    jp nz, .b
    ret
nxb_ds_b:
    ld hl, 0
    call vid_ds_blkopen
    jp vid_ds_pad
nxb_ds_c:
    ld hl, 0
    call vid_ds_blkopen
    ld de, DATA_WINDOW
    ld bc, 512
    jp vid_ds_xfer
nxb_ds_d:
    ld hl, 0
    call vid_ds_blkopen
    ld b, 4
.x:
    push bc
    ld de, DATA_WINDOW
    ld bc, 128
    call vid_ds_xfer             ; preserves nothing but HL (remain)
    pop bc
    djnz .x
    ret

; ---------------------------------------------------------------------
; Row tables. Sizing rule for every entry: ops*(header+body) < 7900 so
; the source cursor never reaches $DF00, and ops*count <= 8192 so the
; dest cursor never leaves the window - the seam walkers are out of
; scope for these rows by construction (block header).
; ---------------------------------------------------------------------
; GROUP 2 - op dispatch envelope. SK00 is the floor: SKIP8 with a zero
; count runs the fast handler and NOTHING else, so it IS the dispatch
; cost. The RU01/RU17 and CP01/CP17 pairs are the settlement's own
; joint-solve shape - the 16-byte difference gives the kernel's T/B
; and back-solves the per-op envelope against the settled 387 (RUN8)
; / 267 (COPY8/16). S160/R161/C161 price the 16-bit-operand ops,
; which take the slow parser and the chunked bodies.
nxbTabOpd:
    dw nxbTagSK00
    db VOP_SKIP8
    dw 0
    db 255
    dw 64
    dw nxbTagS160
    db VOP_SKIP16
    dw 0
    db 255
    dw 64
    dw nxbTagRU01
    db VOP_RUN8
    dw 1
    db 255
    dw 32
    dw nxbTagRU17
    db VOP_RUN8
    dw 17
    db 255
    dw 32
    dw nxbTagCP01
    db VOP_COPY8
    dw 1
    db 255
    dw 32
    dw nxbTagCP17
    db VOP_COPY8
    dw 17
    db 255
    dw 32
    dw nxbTagR161
    db VOP_RUN16
    dw 1
    db 255
    dw 32
    dw nxbTagC161
    db VOP_COPY16
    dw 1
    db 255
    dw 32
    dw 0

; GROUP 3 - the COPY size ladder, weighted where real content lives.
; Delta-stream census (250/252-frame Sintel and Big Buck Bunny
; encodes, both geometries): COPY p50 = 1 B (BBB) to 5 B (Sintel);
; 61-99% of all COPY ops are 1-8 B; p90 = 4-38 B; p99 = 8-103 B.
; C073/C074 straddle the derived DMA crossover (NXV2_COPY_DMA_MIN =
; 74); C256 is the COPY16 bulk-repaint path (40 keyframe ops carry
; 16-21% of Sintel's copied bytes).
nxbTabCpy:
    dw nxbTagC001
    db VOP_COPY8
    dw 1
    db 255
    dw 64
    dw nxbTagC004
    db VOP_COPY8
    dw 4
    db 255
    dw 64
    dw nxbTagC008
    db VOP_COPY8
    dw 8
    db 255
    dw 48
    dw nxbTagC016
    db VOP_COPY8
    dw 16
    db 255
    dw 48
    dw nxbTagC038
    db VOP_COPY8
    dw 38
    db 197
    dw 48
    dw nxbTagC073
    db VOP_COPY8
    dw 73
    db 105
    dw 64
    dw nxbTagC074
    db VOP_COPY8
    dw 74
    db 103
    dw 64
    dw nxbTagC103
    db VOP_COPY8
    dw 103
    db 75
    dw 64
    dw nxbTagC256
    db VOP_COPY16
    dw 256
    db 30
    dw 96
    dw 0

; GROUP 4 - fill crossover + the DMA DI window. F070/F071 straddle
; the derived RUN crossover (NXV2_RUN_DMA_MIN = 71); F063 is the CPU
; fill at the census's RUN p99 neighbourhood (every observed RUN is
; short - RUN carries 0.003-6% of painted bytes and RUN16 is never
; emitted at all, so this group is a CONFIRMATION, not a lever).
; F256/K256 are full 256-byte DMA chunks: one arm each, so the row's
; per-op T IS the DI bracket the audio ISR has to survive - the
; measured answer to the stale ~38% margin claim.
nxbTabKrn:
    dw nxbTagF063
    db VOP_RUN8
    dw 63
    db 125
    dw 64
    dw nxbTagF070
    db VOP_RUN8
    dw 70
    db 112
    dw 64
    dw nxbTagF071
    db VOP_RUN8
    dw 71
    db 111
    dw 64
    dw nxbTagF256
    db VOP_RUN16
    dw 256
    db 30
    dw 96
    dw nxbTagK256
    db VOP_COPY16
    dw 256
    db 30
    dw 96
    dw 0

; zxnDMA WR2/WR5 one-time program - the VID_PAGE-local twin of
; vidDmaInit (VID_PAGE2, unreachable from here). Byte-for-byte the
; same four bytes; if that block ever changes, this one moves with it.
nxbDmaInit:
    db $83                       ; WR6: disable (clean slate)
    db %01010000                 ; WR2: B memory, incrementing, timing
    db %00000010                 ; B cycle length 2 (no prescaler)
    db %10000010                 ; WR5: stop on end of block (one-shot)
nxbDmaInit_len equ $ - nxbDmaInit

nxbMsgO:   db " O=", 0
nxbMsgR:   db " R=", 0
nxbMsgF:   db " F=", 0
nxbMsgD:   db " D=", 0
nxbMsgP:   db " P=", 0
nxbMsgN:   db " N=", 0
nxbMsgBank: db "NXB NO BANK", 0
nxbTagDTA: db "DTA", 0
nxbTagDTI: db "DTI", 0
nxbTagDTB: db "DTB", 0
nxbTagDTC: db "DTC", 0
nxbTagDTD: db "DTD", 0
nxbTagTOK: db "TOK", 0
nxbTagSK00: db "SK00", 0
nxbTagS160: db "S160", 0
nxbTagRU01: db "RU01", 0
nxbTagRU17: db "RU17", 0
nxbTagCP01: db "CP01", 0
nxbTagCP17: db "CP17", 0
nxbTagR161: db "R161", 0
nxbTagC161: db "C161", 0
nxbTagC001: db "C001", 0
nxbTagC004: db "C004", 0
nxbTagC008: db "C008", 0
nxbTagC016: db "C016", 0
nxbTagC038: db "C038", 0
nxbTagC073: db "C073", 0
nxbTagC074: db "C074", 0
nxbTagC103: db "C103", 0
nxbTagC256: db "C256", 0
nxbTagF063: db "F063", 0
nxbTagF070: db "F070", 0
nxbTagF071: db "F071", 0
nxbTagF256: db "F256", 0
nxbTagK256: db "K256", 0

nxbMode:     db 0
nxbRow:      db 0
nxbTag:      dw 0
nxbOpc:      db 0
nxbCnt:      dw 0
nxbOps:      db 0
nxbReps:     dw 0
nxbLeft:     dw 0
nxbFrames:   dw 0
nxbPrev:     dw 0
nxbL0:       dw 0
nxbL1:       dw 0
nxbSrcBank:  db 0
nxbDstBank:  db 0
nxbDstP:     db 0
nxbBankCnt:  db 0
nxbSvMmu6:   db 0
nxbSvMmu2:   db 0
nxbSvAudEn:  db 0

; Token-poll instrument accumulators (vid_sd_tok_h, above).
vidTokPolls: dw 0
vidTokCalls: dw 0
 ENDIF

    DISPLAY "video ends at ", $, " headroom ", /D, OVL_LIMIT - $
    ASSERT $ <= OVL_LIMIT

; ---------------------------------------------------------------------
; VID_PAGE2 - second video page. COLD code only: everything here runs
; strictly pre-arm (before vid_run's CTC time-constant write) or
; post-disarm (after .restore parks the CTC) - the one-rule invariant
; is honoured because no hop ever happens while the ISR can fire.
; Contents: the v2 open/load cluster, the entry/l2setup/restore
; bodies, the esxDOS open cluster, the SD streaming cluster (3b parts
; bin), and the DEBUG timeline report body.
; ---------------------------------------------------------------------
    MMU 7, VID_PAGE2, OVL_ORG

; ---------------------------------------------------------------------
; nxv2_open_body - NXV v2 header open + ring allocation + DELIVERY
; DECISION (3b): a file the pool holds whole loads RESIDENT (3a's
; proven path); anything bigger STREAMS - the ring becomes a circular
; prefetch buffer of every bank the pool gives, PREFILLED FULL here
; pre-arm (the full fill is >= any honorable header start-margin),
; with the CMD18 window left open and the whole producer state staged
; hot for the armed session. Runs entirely cold, entirely pre-arm,
; with the music tick already frozen (entry body) so the load is
; silent (~0.8s/1MB at the measured ~1264KB/s SD floor).
;
; In: the file is open (vid_open_video_body ran: vidHandle/vidSizeLo/
; Hi valid, raw cursor at file start). Out (via the hop back to
; vid_run.openret): B = 0 loaded/prefilled + every hot parameter
; staged; B = 1 bad header / read error (VID FMT - v1 files land
; here; streaming adds: size not whole blocks, bad payload cap);
; B = 2 no pool bank at all; B = 3 no ring fits (pool below one
; streamed frame's need + slack, or file >= 16MB); B = 4 too
; fragmented to stream (filemap exceeds the hot copy). On any failure
; the ring is freed and the stream closed. Corrupts everything.
; Rubric 3: every write to a VID_PAGE cell or code byte goes through
; the MMU6 window (+DATA_WINDOW-OVL_ORG) in the marked brackets;
; everything else here is VID_PAGE2-local.
; ---------------------------------------------------------------------
nxv2_open_body:
    xor a
    ld (vidRingCntC), a
    ld (vidAudBankC), a          ; 0 = none (bank 0 is reserved -
                                 ; never allocatable, safe sentinel)
    ld (vidSnapCnt), a           ; snapshot list empty (SP15 snapshot)
 IFDEF DEBUG
    ld hl, (frameCounter)        ; resident cell - ring-fill timing
    ld (vidFillT0), hl
 ENDIF
    ; --- ring bank 0 + the first 8K chunk (header rides in it) ---
    call bank_alloc
    jr nc, .bank0ok
    ld b, 2                      ; verdict: no bank
    jp .fail
.bank0ok:
    ld (vidRingBanksC), a
    ld a, 1
    ld (vidRingCntC), a
    ; --- the AUDIO BANK (3c): one pool bank pinned at MMU3 for the
    ; session's 2560-byte audio double buffer (vidAudBuf = $6000 -
    ; moved OFF the hot code page; the reclaim that funds the 3c
    ; features). Allocated before the ring sizing so the delivery
    ; decision sees the reduced pool naturally. ---
    call bank_alloc
    jr nc, .audbok
    ld b, 2                      ; verdict: no bank
    jp .fail
.audbok:
    ld (vidAudBankC), a
    ; --- the SNAPSHOT banks (SP15 L2 snapshot/restore): 0/3/5 pool
    ; banks reserved UP FRONT for the game's front L2 surface, so the
    ; post-video screen never depends on gfx-cache history - reserve-
    ; first, refuse-on-failure (VID NOBANK2), the audio-bank precedent.
    ; Count from the ENTRY capture (vid_run_entry_body ran before this
    ; body): 0 when Layer 2 was hidden, else 3 (256x192) / 5 (320x256).
    ; Allocated before the ring sizing, like the audio bank, so the
    ; delivery decision sees the reduced pool naturally. ---
    call vid_snap_geom           ; A = 0/3/5 (vidSvNr69/70)
    or a
    jr z, .snapok
    ld b, a
    ld hl, vidSnapBanks
.snapal:
    push hl
    push bc
    call bank_alloc              ; corrupts B AND C (doc 13 rubric 1 -
    pop bc                       ; the SP15 3a .alloc lesson)
    pop hl
    jr nc, .snapgot
    ld b, 2                      ; verdict: no bank (the partial list
    jp .fail                     ; is freed by the .fail cluster)
.snapgot:
    ld (hl), a
    inc hl
    ld a, (vidSnapCnt)
    inc a
    ld (vidSnapCnt), a
    djnz .snapal
.snapok:
 IFDEF DEBUG
    ld a, (vidSnapCnt)
    ld (vidSnapCntL), a          ; SNAP= on the timeline report
 ENDIF
    ld a, (vidRingBanksC)
    add a, a                     ; dest page = bank*2
    ld de, $2000
    call vid_stream_read
    jp c, .badc                  ; read/IO failure -> VID FMT
    ld a, b                      ; BC = bytes read; need >= 512
    cp 2
    jp c, .badc                  ; not even one block: not an NXV file
    ld (vidRecvLo), bc
    xor a
    ld (vidRecvHi), a
    ; --- parse + validate the frozen v2 header (ring page 0 via the
    ; MMU6 window; every .badu below restores the bracket first) ---
    call data_save
    ld a, (vidRingBanksC)
    add a, a
    call data_map_page
    ld hl, DATA_WINDOW + NXV2_OFF_MAGIC
    ld de, nxvMagic
    ld b, NXV_MAGIC_LEN
.magic:
    ld a, (de)
    cp (hl)
    jp nz, .badu
    inc hl
    inc de
    djnz .magic
    ld a, (DATA_WINDOW + NXV2_OFF_VERSION)
    cp NXV2_VERSION
    jp nz, .badu                 ; v1 files (version 1) rejected here
    ld a, (DATA_WINDOW + NXV2_OFF_WIDTH)
    cp 2
    jp nc, .badu                 ; width code 0/1 only
    ld (vidP_Shape), a
    ld a, (DATA_WINDOW + NXV2_OFF_HEIGHT)
    ld (vidP_HeightB), a
    ld b, a
    ld a, (vidP_Shape)
    or a
    jr nz, .h_ok                 ; mode-1: 1-255 and 0(=256) all valid
    ld a, b                      ; mode-0: 1..192 only
    or a
    jp z, .badu                  ; 0 = 256 lines: over mode-0's cap
    cp NXV_NATIVE_H_MODE0+1
    jp nc, .badu                 ; > 192
.h_ok:
    ; channels + rate must pair (the supported set)
    ld a, (DATA_WINDOW + NXV2_OFF_ACHAN)
    ld (vidP_AChan), a
    cp 1
    jr z, .mono
    cp 2
    jp nz, .badu
    ld de, NXV_RATE_STEREO
    jr .ratechk
.mono:
    ld de, NXV_RATE_MONO
.ratechk:
    ld hl, (DATA_WINDOW + NXV2_OFF_ARATE)
    or a
    sbc hl, de
    jp nz, .badu
    ; flags: delta stream set; bits 2-7 reserved-zero; bit1 = the
    ; direct-serve hint - HONOURED from 3c (captured here, drives the
    ; delivery decision at .geodone)
    ld a, (DATA_WINDOW + NXV2_OFF_FLAGS)
    ld c, a
    and NXV2_FLAG_DIRECT
    ld (vidHdrDirectC), a        ; 0 / NXV2_FLAG_DIRECT
    ld a, c
    and %11111101
    cp NXV2_FLAG_DELTA
    jp nz, .badu
    ; frame count: nonzero; < 65536 (a resident-size file cannot hold
    ; more frames than that - a bigger declared count is corrupt)
    ld a, (DATA_WINDOW + NXV2_OFF_FRAMES + 2)
    or a
    jp nz, .badu
    ld hl, (DATA_WINDOW + NXV2_OFF_FRAMES)
    ld a, h
    or l
    jp z, .badu
    ld (vidP_Frames), hl
    ; audio bytes/frame: nonzero, <= one vidAudBuf HALF (the 3b
    ; double buffer: the ISR plays one half while the loop fills the
    ; other - stereo 1250 / mono 933 both fit); pad = round-up-512
    ld hl, (DATA_WINDOW + NXV2_OFF_ABYTES)
    ld a, h
    or l
    jp z, .badu                  ; zero would wrap the copy LDIR
    ld (vidP_ABytes), hl
    ld de, NXV_AUD_HALF
    or a
    sbc hl, de
    jr c, .abok                  ; real < half
    jp nz, .badu                 ; real > half: overflow guard
.abok:
    ld hl, (vidP_ABytes)
    ld de, 511
    add hl, de
    ld a, h
    and $FE
    ld h, a
    ld l, 0
    ld (vidP_ABytesPad), hl
    ; per-frame payload cap (blocks): captured for the streaming
    ; gate; resident ignores it (informational there, as 3a did)
    ld hl, (DATA_WINDOW + NXV2_OFF_FRAMECAP)
    ld (vidHdrCapC), hl
    ; ring start-margin: ADVISORY - this player honors it by
    ; domination (full-ring prefill); captured only for the cheap
    ; corrupt-header range check in .stream_setup
    ld hl, (DATA_WINDOW + NXV2_OFF_RMARGIN)
    ld (vidHdrMarginC), hl
    call data_restore
    ; --- geometry derivation (free heights - no block math) ---
    xor a
    ld (vidP_GapFlag), a
    ld a, (vidP_Shape)
    or a
    jr z, .geo_m0
    ; mode-1: surface span 10 pages; Y1 = (256-h)/2, YOFS = -Y1
    ld a, 10
    ld (vidP_DstPages), a
    ld a, (vidP_HeightB)
    or a
    jr z, .m1full                ; height 256: flat, full surface
    ld b, a
    ld a, 1
    ld (vidP_GapFlag), a         ; column gaps exist
    xor a
    sub b
    srl a                        ; (256-h)/2 (mod-256 trick, h 1..255)
    ld (vidP_ClipY1), a
    ld c, a
    ld a, b
    add a, c
    dec a
    ld (vidP_ClipY2), a          ; Y2 = Y1 + h - 1
    ld a, c
    neg                          ; YOFS wraps against native 256
    ld (vidP_Yofs), a
    jr .geodone
.m1full:
    xor a
    ld (vidP_ClipY1), a
    ld (vidP_Yofs), a
    ld a, 255
    ld (vidP_ClipY2), a
    jr .geodone
.geo_m0:
    ; mode-0: always row-linear (never gapped); span 6 pages; YOFS
    ; wraps against the mode's own 192 native height (the owner's
    ; "N2 band addressing" fix, carried)
    ld a, 6
    ld (vidP_DstPages), a
    ld a, (vidP_HeightB)
    ld b, a
    ld a, NXV_NATIVE_H_MODE0
    sub b
    srl a
    ld (vidP_ClipY1), a
    ld c, a
    ld a, b
    add a, c
    dec a
    ld (vidP_ClipY2), a
    ld a, c
    or a
    jr z, .m0y0                  ; Y1 = 0: YOFS = 0 (192 is invalid)
    ld a, NXV_NATIVE_H_MODE0
    sub c
.m0y0:
    ld (vidP_Yofs), a
.geodone:
    ; --- DELIVERY DECISION (3b size split + 3c direct override): the
    ; header's direct-serve hint takes the whole file to the SD-to-
    ; surface path regardless of size; otherwise a file the pool
    ; holds whole loads RESIDENT (the proven 3a path; loop = RAM
    ; rewind); anything bigger STREAMS through a circular ring of
    ; every bank the pool will give, prefilled full before the CTC
    ; arms. ---
    xor a
    ld (vidDeliverDir), a
    ld a, (vidHdrDirectC)
    or a
    jp nz, .direct_setup
    xor a
    ld (vidDeliverStrm), a
    ld a, (vidSizeHi+1)
    or a
    jp nz, .toobig               ; >= 16MB: over the 24-bit cursors
    ld a, (vidSizeHi)
    cp $20
    jr c, .needcalc
    ld a, VID_RING_MAX           ; >= 2MB: no ring holds it - stream
    jr .strmneed
.needcalc:
    add a, a
    add a, a
    ld b, a                      ; size[20:16] << 2
    ld hl, (vidSizeLo)
    ld a, h
    rlca
    rlca
    and 3
    or b
    ld b, a                      ; B = size >> 14 (whole banks)
    ld a, h
    and $3F
    or l
    jr z, .exact
    inc b                        ; partial bank: one more
.exact:
    ld a, b
    or a
    jp z, .badc                  ; zero-size file: not a video
    cp VID_RING_MAX+1
    jr c, .needok                ; fits the list: try resident
    ld a, VID_RING_MAX           ; over the list capacity: stream
.strmneed:
    push af
    ld a, 1
    ld (vidDeliverStrm), a
    pop af
.needok:
    ld (vidRingNeed), a
.alloc:
    ld a, (vidRingCntC)
    ld b, a
    ld a, (vidRingNeed)
    cp b
    jr z, .allocdone
    call bank_alloc
    jr c, .allocshort            ; pool exhausted before the target
    ld hl, vidRingBanksC
    ld c, a
    ld a, (vidRingCntC)          ; re-read the slot index: bank_alloc
                                 ; corrupts B AND C (its table-scan
                                 ; djnz counter / bank counter) - the
                                 ; SP15 3a first-silicon defect: `ld
                                 ; a, b` here stored every bank at
                                 ; vidRingBanksC[112-bank], scrambling
                                 ; the ring list AND the count (doc 13
                                 ; rubric 1: register liveness across
                                 ; calls)
    add hl, a                    ; Z80N (doc 05)
    ld (hl), c
    inc a
    ld (vidRingCntC), a
    jr .alloc
.allocshort:
    ; the pool gave fewer banks than the target: a resident attempt
    ; falls back to streaming with the ring in hand; a streaming
    ; target simply takes the smaller ring (minimum checked below)
    ld a, 1
    ld (vidDeliverStrm), a
.allocdone:
    ld a, (vidDeliverStrm)
    or a
    jp nz, .stream_setup
    ; resident: prefill target = the whole file
    ld hl, (vidSizeLo)
    ld (vidLoadTgt), hl
    ld a, (vidSizeHi)
    ld (vidLoadTgt+2), a
.loadgo:
    ; --- load: ring pages in order until received == target (the
    ; whole file resident / the whole ring streaming - the streaming
    ; prefill IS the start margin, >= any honorable header value).
    ; vid_stream_read holds the CMD18 window open across calls (its
    ; own contract), so this is one continuous multi-block read. ---
    ld a, 1
    ld (vidLoadIdx), a
.load:
    ; remaining = target - received (24-bit); 0 -> loaded
    ld hl, (vidLoadTgt)
    ld de, (vidRecvLo)
    or a
    sbc hl, de
    ld a, (vidLoadTgt+2)
    ld d, a
    ld a, (vidRecvHi)
    ld e, a
    ld a, d
    sbc a, e                     ; A = high-byte remainder w/ borrow
    jp c, .badc                  ; received > size: corrupt bookkeeping
    or h
    or l
    jr z, .loaded
    ; next ring page = bank[idx>>1]*2 + (idx&1); running off the page
    ; list with bytes still owed = size/content mismatch
    ld a, (vidLoadIdx)
    ld b, a
    ld a, (vidRingCntC)
    add a, a
    cp b
    jp c, .badc
    jp z, .badc
    ld a, b
    srl a                        ; bank index, CF = parity
    push af
    ld hl, vidRingBanksC
    add hl, a                    ; Z80N (doc 05)
    ld a, (hl)
    add a, a
    ld b, a
    pop af                       ; CF = parity restored
    ld a, b
    adc a, 0                     ; page = bank*2 + parity
    ld de, $2000
    call vid_stream_read
    jp c, .badc
    ld a, b
    or c
    jp z, .badc                  ; 0 bytes with bytes owed: short file
    ld hl, (vidRecvLo)
    add hl, bc
    ld (vidRecvLo), hl
    jr nc, .noc
    ld a, (vidRecvHi)
    inc a
    ld (vidRecvHi), a
.noc:
    ld a, (vidLoadIdx)
    inc a
    ld (vidLoadIdx), a
    jr .load
.loaded:
    ld a, (vidDeliverStrm)
    or a
    jp nz, .strm_loaded
    ; RESIDENT: SD is DONE for the whole session - CMD12 + deselect +
    ; Multiface restore + F_CLOSE now, pre-arm (resident playback
    ; never streams)
    call vid_stream_close
 IFDEF DEBUG
    ld hl, (frameCounter)
    ld de, (vidFillT0)
    or a
    sbc hl, de
    ld (vidFillD), hl            ; ring-fill duration, 50Hz frames
 ENDIF
    call vid_stage_common        ; bracket returns OPEN
    ; resident extras: the streaming session cells parked off (a
    ; previous streaming run must not leak its flag/window into this
    ; session)
    xor a
    ld (vidStreaming + DATA_WINDOW - OVL_ORG), a
    ld (vidWinOpenH + DATA_WINDOW - OVL_ORG), a
 IFDEF DEBUG
    ld hl, 0
    ld (vidRingMin + DATA_WINDOW - OVL_ORG), hl
    ld (vidRingUnder + DATA_WINDOW - OVL_ORG), hl
    xor a
    ld (vidDepthClip + DATA_WINDOW - OVL_ORG), a
 ENDIF
    call data_restore
    ld b, 0                      ; verdict: loaded
    jp .backhop

.stream_setup:
    ; --- 3b RING STREAMING setup. Contract validation first: the
    ; file must be whole 512B blocks (every v2 frame section is
    ; block-aligned, so a valid encode's fstat size always is) and
    ; the header's per-frame payload cap must be a sane block count -
    ; the gate paces on it, so a lying/absent cap is a corrupt
    ; header. The header start-margin is honored by construction: the
    ; prefill fills the ENTIRE ring, which is >= any margin the ring
    ; could honor (a margin larger than the ring itself is served
    ; best-effort by the same full fill - documented in the report).
    ld a, (vidSizeLo)
    or a
    jp nz, .badc
    ld a, (vidSizeLo+1)
    and 1
    jp nz, .badc
    ld hl, (vidHdrCapC)
    ld a, h
    or a
    jp nz, .badc
    ld a, l
    or a
    jp z, .badc
    cp NXV2_STRM_CAP_MAX+1
    jp nc, .badc
    ld (vidCapBlkC), a
    ; advisory start-margin range check: this player never reads the
    ; margin as a fill target (full-ring prefill dominates any margin
    ; the ring could honor), but a margin claiming more blocks than
    ; the whole file is a corrupt header - reject it cheaply
    ld a, (vidSizeHi)
    ld h, a
    ld a, (vidSizeLo+1)
    ld l, a                      ; HL = size >> 8 (low byte 0, checked
    srl h                        ; above)
    rr l                         ; HL = file blocks (size >> 9)
    ld de, (vidHdrMarginC)
    or a
    sbc hl, de
    jp c, .badc                  ; margin > file blocks
    ; gate need = audio-pad blocks + cap + 1 (the loop-pass header
    ; block rides between passes)
    ld hl, (vidP_ABytesPad)
    ld a, h
    srl a                        ; pad >> 9 (pad <= 1536: 1..3 blocks)
    ld (vidApadBlkC), a
    ld b, a
    ld a, (vidCapBlkC)
    add a, b
    inc a                        ; <= 244: no carry possible
    ld (vidNeedBlkC), a
    ; ring geometry from the allocated count
    ld a, (vidRingCntC)
    ld l, a
    ld h, 0
    add hl, hl
    add hl, hl
    add hl, hl
    add hl, hl
    add hl, hl
    add hl, hl                   ; HL = cnt << 6
    xor a
    ld (vidLoadTgt), a           ; prefill target = ringBytes =
    ld a, l                      ; cnt << 14 (low byte 0 by shape)
    ld (vidLoadTgt+1), a
    ld a, h
    ld (vidLoadTgt+2), a
    srl h
    rr l                         ; HL = cnt * 32 = ring blocks
    ld (vidRingCapBlkC), hl
    ; the ring must hold one served frame + the next audio + slack
    ld a, (vidNeedBlkC)
    ld c, a
    ld a, (vidApadBlkC)
    add a, c
    add a, 2
    ld c, a
    ld b, 0
    or a
    sbc hl, bc
    jp c, .toobig                ; ring too small to stream this file
    ; the filemap must fit the hot copy (fragment ceiling)
    ld hl, (vidStrmEntryEnd)
    ld de, vidFilemapBuf
    or a
    sbc hl, de                   ; HL = entries * 6 (<= 192)
    ld a, l
    cp VID_STRM_HOT_ENT*6+1
    jp nc, .toofrag
    ld b, 0
.entdiv:
    sub 6
    jr c, .entdivd
    inc b
    jr .entdiv
.entdivd:
    ld a, b
    ld (vidEntCntC), a
    jp .loadgo

.strm_loaded:
    ; STREAMING: the CMD18 window STAYS OPEN - ownership moves to the
    ; hot producer (the cold flag is cleared below so the cold close
    ; path will not CMD12 a window it no longer owns; the esxDOS
    ; handle stays open for the session and the restore body F_CLOSEs
    ; it at teardown).
 IFDEF DEBUG
    ld hl, (frameCounter)
    ld de, (vidFillT0)
    or a
    sbc hl, de
    ld (vidFillD), hl            ; prefill duration, 50Hz frames
 ENDIF
    call vid_stage_common        ; bracket returns OPEN
    ; --- streaming extras (same bracket) ---
    ld a, 1
    ld (vidStreaming + DATA_WINDOW - OVL_ORG), a
    ; consumer cursor: first consumed byte = file offset 512 (the
    ; ring holds file offsets 0..ringBytes-1 at identity positions;
    ; block 0 = the header, consumed by construction - the producer
    ; may overwrite its slot on the first wrap)
    ld hl, 512
    ld (vidRingRl + DATA_WINDOW - OVL_ORG), hl
    xor a
    ld (vidRingRl+2 + DATA_WINDOW - OVL_ORG), a
    ld a, (vidRingCntC)
    add a, a
    ld (vidRingPageCnt + DATA_WINDOW - OVL_ORG), a
    ld hl, (vidRingCapBlkC)
    ld (vidRingCapBlk + DATA_WINDOW - OVL_ORG), hl
    dec hl                       ; depth = ring blocks - 1 (header)
    ld (vidRingDepth + DATA_WINDOW - OVL_ORG), hl
    ld a, (vidLoadTgt)
    ld (vidRingBytes + DATA_WINDOW - OVL_ORG), a
    ld a, (vidLoadTgt+1)
    ld (vidRingBytes+1 + DATA_WINDOW - OVL_ORG), a
    ld a, (vidLoadTgt+2)
    ld (vidRingBytes+2 + DATA_WINDOW - OVL_ORG), a
    ; producer write cursor: received == ringBytes exactly, i.e.
    ; wrapped to ring page 0 offset 0
    xor a
    ld (vidWrPageLin + DATA_WINDOW - OVL_ORG), a
    ld hl, 0
    ld (vidWrOfs + DATA_WINDOW - OVL_ORG), hl
    ld a, (vidNeedBlkC)
    ld l, a
    ld h, 0
    ld (vidNeedBlk + DATA_WINDOW - OVL_ORG), hl
    ld a, (vidApadBlkC)
    ld (vidApadBlk + DATA_WINDOW - OVL_ORG), a
    ld a, (vidCapBlkC)
    rrca
    rrca
    rrca
    rrca
    and $0F                      ; cap / 16
    add a, 3
    ld (vidWalkMax + DATA_WINDOW - OVL_ORG), a
    ; totals: file blocks + blocks still owed this pass
    ld a, (vidSizeHi)
    ld h, a
    ld a, (vidSizeLo+1)
    ld l, a                      ; HL = size >> 8 (low byte 0)
    srl h
    rr l                         ; HL = size >> 9
    ld (vidTotalBlk + DATA_WINDOW - OVL_ORG), hl
    ld de, (vidRingCapBlkC)
    or a
    sbc hl, de                   ; received == ringBytes
    ld (vidStrmRemainBlk + DATA_WINDOW - OVL_ORG), hl
    ; run-cursor handoff (the open window continues mid-run)
    ld a, (vidEntCntC)
    ld (vidStrmEntryCnt + DATA_WINDOW - OVL_ORG), a
    ld hl, (vidStrmEntryPtr)
    ld de, vidFilemapBuf
    or a
    sbc hl, de
    ld a, l                      ; (entryPtr - buf), <= 48 here
    ld c, 0
.eidx:
    sub 6
    jr c, .eidxd
    inc c
    jr .eidx
.eidxd:
    ld a, c
    ld (vidStrmEntryIdx + DATA_WINDOW - OVL_ORG), a
    ld hl, (vidStrmRunBlocks)
    ld (vidStrmRunBlkH + DATA_WINDOW - OVL_ORG), hl
    ld hl, (vidStrmRunAddrLo)
    ld (vidRunAddrLoH + DATA_WINDOW - OVL_ORG), hl
    ld hl, (vidStrmRunAddrHi)
    ld (vidRunAddrHiH + DATA_WINDOW - OVL_ORG), hl
    ld a, (vidCardFlags)
    ld (vidCardFlagsH + DATA_WINDOW - OVL_ORG), a
    ld a, (vidMfSave)
    ld (vidMfSaveH + DATA_WINDOW - OVL_ORG), a
    ld a, (vidStrmWinOpen)
    ld (vidWinOpenH + DATA_WINDOW - OVL_ORG), a
    ld hl, vidFilemapBuf
    ld de, vidHotMap + DATA_WINDOW - OVL_ORG
    ld bc, VID_STRM_HOT_ENT*6
    ldir
 IFDEF DEBUG
    ld hl, (vidRingCapBlkC)
    dec hl
    ld (vidRingMin + DATA_WINDOW - OVL_ORG), hl
    ld hl, 0
    ld (vidRingUnder + DATA_WINDOW - OVL_ORG), hl
    xor a
    ld (vidDepthClip + DATA_WINDOW - OVL_ORG), a
 ENDIF                           ; (099 throttle lever RETIRED in 3c)
    call data_restore
    xor a                        ; window ownership is HOT now
    ld (vidStrmWinOpen), a
    ld b, 0                      ; verdict: loaded (streaming)
    jp .backhop

.direct_setup:
    ; --- 3c DIRECT-SERVE setup: no ring, no prefill - the armed
    ; session serves the SD stream straight to the surface. Contract
    ; validation mirrors streaming: whole 512B blocks, sane payload
    ; cap (it prices the per-frame section bound cap + apad + 1),
    ; advisory margin range check, filemap fits the hot copy. Then
    ; the raw cursor REWINDS to file start (the header ate the first
    ; 16 blocks for the parse) and the header block is consumed cold,
    ; leaving the window open at frame 0's audio for the handoff. ---
    ld a, 1
    ld (vidDeliverDir), a
    ld a, (vidSizeLo)
    or a
    jp nz, .badc
    ld a, (vidSizeLo+1)
    and 1
    jp nz, .badc
    ld a, (vidSizeHi+1)
    or a
    jp nz, .badc                 ; >= 16MB: over the 24-bit sizes
    ld hl, (vidHdrCapC)
    ld a, h
    or a
    jp nz, .badc
    ld a, l
    or a
    jp z, .badc
    cp NXV2_STRM_CAP_MAX+1
    jp nc, .badc
    ld (vidCapBlkC), a
    ld hl, (vidP_ABytesPad)
    ld a, h
    srl a                        ; pad >> 9 (1..3 blocks)
    ld (vidApadBlkC), a
    ld b, a
    ld a, (vidCapBlkC)
    add a, b
    inc a                        ; <= 244: no carry
    ld (vidNeedBlkC), a          ; the per-frame section bound
    ; file blocks (also the margin range check's bound)
    ld a, (vidSizeHi)
    ld h, a
    ld a, (vidSizeLo+1)
    ld l, a
    srl h
    rr l                         ; HL = size >> 9
    ld (vidTotalBlkC), hl
    ld de, (vidHdrMarginC)
    or a
    sbc hl, de
    jp c, .badc                  ; margin > file blocks: corrupt
    ; filemap must fit the hot copy
    ld hl, (vidStrmEntryEnd)
    ld de, vidFilemapBuf
    or a
    sbc hl, de
    ld a, l
    cp VID_STRM_HOT_ENT*6+1
    jp nc, .toofrag
    ld b, 0
.dentdiv:
    sub 6
    jr c, .dentdivd
    inc b
    jr .dentdiv
.dentdivd:
    ld a, b
    ld (vidEntCntC), a
    ; rewind to file start + consume the header block cold (the
    ; armed session then starts exactly at frame 0's audio)
    call vid_win_close
    call vid_raw_reset_cursor
    call vid_next_run
    jp c, .badc                  ; cannot happen: map validated above
    call vid_win_open
    jp c, .badc
    ld hl, vidStrmBlkBuf
    call vid_read_block          ; the header block - discarded (CRC
    jp c, .badc                  ; consumed by the reader itself)
    ld hl, (vidStrmRunBlocks)
    dec hl
    ld (vidStrmRunBlocks), hl
    call vid_ring_free           ; bank 0 served the parse only -
                                 ; direct needs NO pool banks
 IFDEF DEBUG
    ld hl, (frameCounter)
    ld de, (vidFillT0)
    or a
    sbc hl, de
    ld (vidFillD), hl            ; FILL row = the header/probe time
 ENDIF
    call vid_stage_common        ; bracket returns OPEN (stages the
                                 ; ds decode vectors from vidDeliverDir)
    ; --- direct extras (same bracket) ---
    xor a
    ld (vidStreaming + DATA_WINDOW - OVL_ORG), a
    ld (vidDsCrcDue + DATA_WINDOW - OVL_ORG), a
    ld (vidDsFrmBlk + DATA_WINDOW - OVL_ORG), a
    ld a, (vidNeedBlkC)
    ld (vidDsBound + DATA_WINDOW - OVL_ORG), a
    ld a, (vidApadBlkC)
    ld (vidApadBlk + DATA_WINDOW - OVL_ORG), a
    ld hl, (vidTotalBlkC)
    ld (vidTotalBlk + DATA_WINDOW - OVL_ORG), hl
    dec hl                       ; the header block is consumed
    ld (vidStrmRemainBlk + DATA_WINDOW - OVL_ORG), hl
    ; run-cursor handoff: window OPEN one block into run 0
    ld a, (vidEntCntC)
    ld (vidStrmEntryCnt + DATA_WINDOW - OVL_ORG), a
    ld a, 1
    ld (vidStrmEntryIdx + DATA_WINDOW - OVL_ORG), a
    ld hl, (vidStrmRunBlocks)
    ld (vidStrmRunBlkH + DATA_WINDOW - OVL_ORG), hl
    ld hl, (vidStrmRunAddrLo)
    ld (vidRunAddrLoH + DATA_WINDOW - OVL_ORG), hl
    ld hl, (vidStrmRunAddrHi)
    ld (vidRunAddrHiH + DATA_WINDOW - OVL_ORG), hl
    ld a, (vidCardFlags)
    ld (vidCardFlagsH + DATA_WINDOW - OVL_ORG), a
    ld a, (vidMfSave)
    ld (vidMfSaveH + DATA_WINDOW - OVL_ORG), a
    ld a, (vidStrmWinOpen)
    ld (vidWinOpenH + DATA_WINDOW - OVL_ORG), a
    ld hl, vidFilemapBuf
    ld de, vidHotMap + DATA_WINDOW - OVL_ORG
    ld bc, VID_STRM_HOT_ENT*6
    ldir
 IFDEF DEBUG
    ld hl, 0
    ld (vidRingMin + DATA_WINDOW - OVL_ORG), hl
    ld (vidRingUnder + DATA_WINDOW - OVL_ORG), hl
    xor a
    ld (vidDepthClip + DATA_WINDOW - OVL_ORG), a
 ENDIF
    call data_restore
    xor a                        ; window ownership is HOT now
    ld (vidStrmWinOpen), a
    ld b, 0                      ; verdict: loaded (direct)
    jp .backhop

.badu:
    call data_restore            ; the parse bracket was open
.badc:
    ld b, 1                      ; verdict: bad header / bad read
    jr .fail
.toofrag:
    ld b, 4                      ; verdict: too fragmented to stream
    jr .fail
.toobig:
    ld b, 3                      ; verdict: no ring fits (pool below
                                 ; one streamed frame's need, or the
                                 ; file is >= 16MB)
.fail:
    push bc
    call vid_ring_free
    call vid_aud_bank_free
    call vid_snap_free
    call vid_stream_close
    pop bc
.backhop:
    ret                          ; 3c: plain return to the cold
                                 ; orchestrator (B = verdict)

; Common hot staging (both deliveries): fileEnd, the parameter block,
; ring count + bank list, DEBUG fill row, per-file SMC patches (stub
; dispatch targets + gap height immediates - doc 08, written through
; the window, rubric 3). OPENS the MMU6 bracket and RETURNS WITH IT
; OPEN - the caller stages its delivery extras then closes with
; data_restore. Corrupts everything.
vid_stage_common:
    ld hl, (vidSizeLo)           ; fileEnd = size (staged with the
    ld (vidP_FileEnd), hl        ; block, one LDIR)
    ld a, (vidSizeHi)
    ld (vidP_FileEnd+2), a
    call data_save
    ld a, VID_PAGE
    call data_map_page
    ld hl, vidP_Shape
    ld de, vidShape + DATA_WINDOW - OVL_ORG
    ld bc, VIDP_LEN
    ldir
    ld a, (vidRingCntC)
    ld (vidRingBankCnt + DATA_WINDOW - OVL_ORG), a
    ld hl, vidRingBanksC
    ld de, vidRingBanks + DATA_WINDOW - OVL_ORG
    ld bc, VID_RING_MAX
    ldir
 IFDEF DEBUG
    ld hl, (vidFillD)
    ld (vidTlFillFrames + DATA_WINDOW - OVL_ORG), hl
 ENDIF
    ld a, (vidP_GapFlag)
    or a
    jr z, .flatset
    ld hl, vg_op_skip8
    ld (vid_stub + VOP_SKIP8 + 1 + DATA_WINDOW - OVL_ORG), hl
    ld hl, vg_op_run8
    ld (vid_stub + VOP_RUN8 + 1 + DATA_WINDOW - OVL_ORG), hl
    ld hl, vg_op_copy8
    ld (vid_stub + VOP_COPY8 + 1 + DATA_WINDOW - OVL_ORG), hl
    ld a, (vidP_HeightB)
    ld (vg_op_skip8.hcmp + 1 + DATA_WINDOW - OVL_ORG), a
    ld (vg_op_skip8.hsub + 1 + DATA_WINDOW - OVL_ORG), a
    ld (vg_op_skip8.hcmp2 + 1 + DATA_WINDOW - OVL_ORG), a
    ld (vg_op_run8.hcmp + 1 + DATA_WINDOW - OVL_ORG), a
    ld (vg_op_run8.hsub + 1 + DATA_WINDOW - OVL_ORG), a
    ld (vg_op_run8.hcmp2 + 1 + DATA_WINDOW - OVL_ORG), a
    ld (vg_op_copy8.hcmp + 1 + DATA_WINDOW - OVL_ORG), a
    ld (vg_op_copy8.hsub + 1 + DATA_WINDOW - OVL_ORG), a
    ld (vg_op_copy8.hcmp2 + 1 + DATA_WINDOW - OVL_ORG), a
    jr .vec
.flatset:
    ld hl, vf_op_skip8
    ld (vid_stub + VOP_SKIP8 + 1 + DATA_WINDOW - OVL_ORG), hl
    ld hl, vf_op_run8
    ld (vid_stub + VOP_RUN8 + 1 + DATA_WINDOW - OVL_ORG), hl
    ld hl, vf_op_copy8
    ld (vid_stub + VOP_COPY8 + 1 + DATA_WINDOW - OVL_ORG), hl
.vec:
    ; --- per-session decode vectoring (3c direct-serve): the fetch
    ; vector, the shared bodies' exit jumps, slow-op's COPY body
    ; target and the FEND/PAL/KFLIP stub slots all point at the RAM
    ; decode (resident/streaming) or the SD-stream decode (direct).
    ; Patched EVERY open - a previous session may have left the other
    ; set. Same doc-08/rubric-3 bracket as the stub patches above. ---
    ld a, (vidDeliverDir)
    ld (vidDirect + DATA_WINDOW - OVL_ORG), a
    or a
    jr nz, .dsvec
    ld hl, vid_fetch_ram
    ld (vid_fetch.vec + 1 + DATA_WINDOW - OVL_ORG), hl
    ld hl, vid_next
    ld (vid_skip_body.next + 1 + DATA_WINDOW - OVL_ORG), hl
    ld (vid_run_body.next + 1 + DATA_WINDOW - OVL_ORG), hl
    ld (vid_op_kstart.next + 1 + DATA_WINDOW - OVL_ORG), hl
    ld hl, vid_copy_body
    ld (vid_slow_op.cj + 1 + DATA_WINDOW - OVL_ORG), hl
    ld hl, vid_op_fend
    ld (vid_stub + VOP_FEND + 1 + DATA_WINDOW - OVL_ORG), hl
    ld hl, vid_op_pal
    ld (vid_stub + VOP_PAL + 1 + DATA_WINDOW - OVL_ORG), hl
    ld hl, vid_op_kflip
    ld (vid_stub + VOP_KFLIP + 1 + DATA_WINDOW - OVL_ORG), hl
    ret
.dsvec:
    ld hl, vid_ds_byte
    ld (vid_fetch.vec + 1 + DATA_WINDOW - OVL_ORG), hl
    ld hl, vid_ds_next
    ld (vid_skip_body.next + 1 + DATA_WINDOW - OVL_ORG), hl
    ld (vid_run_body.next + 1 + DATA_WINDOW - OVL_ORG), hl
    ld (vid_op_kstart.next + 1 + DATA_WINDOW - OVL_ORG), hl
    ld hl, vid_ds_copy_body
    ld (vid_slow_op.cj + 1 + DATA_WINDOW - OVL_ORG), hl
    ld hl, vid_ds_fend
    ld (vid_stub + VOP_FEND + 1 + DATA_WINDOW - OVL_ORG), hl
    ld hl, vid_ds_pal
    ld (vid_stub + VOP_PAL + 1 + DATA_WINDOW - OVL_ORG), hl
    ld hl, vid_ds_kflip
    ld (vid_stub + VOP_KFLIP + 1 + DATA_WINDOW - OVL_ORG), hl
    ret

nxvMagic: db "NXVID"

; Cold staging twin of the hot parameter block (order/sizes MUST
; match vidShape.. exactly - one LDIR stages it).
vidP_Shape:    db 0
vidP_HeightB:  db 0
vidP_GapFlag:  db 0
vidP_DstPages: db 0
vidP_ClipY1:   db 0
vidP_ClipY2:   db 0
vidP_Yofs:     db 0
vidP_AChan:    db 0
vidP_ABytes:   dw 0
vidP_ABytesPad: dw 0
vidP_Frames:   dw 0
vidP_FileEnd:  ds 3
VIDP_LEN equ $ - vidP_Shape
    ASSERT VIDP_LEN == vidFileEnd + 3 - vidShape

; Ring bookkeeping (cold canonical copy - the allocator-facing list;
; the hot copy serves only the armed seam walker).
vidRingCntC:   db 0
vidRingBanksC: ds VID_RING_MAX
vidRingNeed:   db 0
vidLoadIdx:    db 0
vidRecvLo:     dw 0
vidRecvHi:     db 0
; 3b streaming-setup scratch (cold; staged hot by .strm_loaded)
vidDeliverStrm: db 0             ; 0 = resident, 1 = ring streaming
vidDeliverDir: db 0              ; 1 = direct-serve (3c; wins over both)
vidAudBankC:   db 0              ; the session audio bank (3c; 0 = none)
vidHdrDirectC: db 0              ; header flags bit1 capture
vidTotalBlkC:  dw 0              ; file blocks (direct setup scratch)
vidLoadTgt:    ds 3              ; prefill byte target (size / ring)
vidHdrCapC:    dw 0              ; header per-frame payload cap
vidHdrMarginC: dw 0              ; header ring start-margin (advisory;
                                 ; range-checked only, never a fill
                                 ; target - the prefill fills the ring)
vidCapBlkC:    db 0              ; validated cap (blocks)
vidApadBlkC:   db 0
vidNeedBlkC:   db 0
vidRingCapBlkC: dw 0
vidEntCntC:    db 0              ; filemap entries in use
 IFDEF DEBUG
vidFillT0:     dw 0
vidFillD:      dw 0
 ENDIF

; Free the session audio bank (idempotent; 3c). Corrupts AF, BC, HL.
vid_aud_bank_free:
    ld a, (vidAudBankC)
    or a
    ret z                        ; none held
    call bank_free
    xor a
    ld (vidAudBankC), a
    ret

; Free every ring bank (idempotent; cold callers only: the open
; body's failure paths + the restore body). Corrupts AF, B, HL.
vid_ring_free:
    ld a, (vidRingCntC)
    or a
    ret z
    ld b, a
    ld hl, vidRingBanksC
.f:
    ld a, (hl)
    call bank_free
    inc hl
    djnz .f
    xor a
    ld (vidRingCntC), a
    ret

; Free every snapshot bank (idempotent; cold callers only: the open
; body's .fail cluster + the restore body - SP15 snapshot). NOT on
; direct-serve's mid-open vid_ring_free path: snap banks survive a
; direct session, correctly. Corrupts AF, B, HL.
vid_snap_free:
    ld a, (vidSnapCnt)
    or a
    ret z
    ld b, a
    ld hl, vidSnapBanks
.f:
    ld a, (hl)
    call bank_free
    inc hl
    djnz .f
    xor a
    ld (vidSnapCnt), a
    ret

; Snapshot geometry (SP15): A = pool banks the captured game state
; needs - 0 (Layer 2 hidden pre-video), 3 (256x192) or 5 (320x256).
; Mode derivation = the restore body's own (vidSvNr70 bits 5:4).
; Plain same-page reads. Corrupts AF only.
vid_snap_geom:
    ld a, (vidSvNr69)
    and %10000000                ; bit7 = Layer 2 visible
    ret z                        ; hidden: A = 0, no snapshot
    ld a, (vidSvNr70)
    and %00110000                ; bits 5:4: 00 = 256x192, else 320x256
    ld a, 3
    ret z                        ; mode 0: 48KB = 3 banks
    ld a, 5
    ret                          ; mode 1: 80KB = 5 banks

; ---------------------------------------------------------------------
; vid_run_orch_body - the pre-arm ladder as ONE cold body (3c
; reclaim): entry capture -> open/load -> L2 setup + session init,
; all plain same-page calls. Out (via the hop back to
; vid_run.orchret): B = 0 ready-to-arm; B != 0 = the open verdict
; (already unwound + DEBUG-printed here). Corrupts everything.
; ---------------------------------------------------------------------
vid_run_orch_body:
    call vid_run_entry_body
    call nxv2_open_body          ; B verdict: 0 = ready, 1 = bad
                                 ; header/read (VID FMT), 2 = no bank,
                                 ; 3 = no ring fits, 4 = too
                                 ; fragmented; failure paths freed the
                                 ; ring and closed the stream already
    ld a, b
    or a
    jr nz, .fail
    call vid_snap_save_body      ; SP15 snapshot: capture the game's
                                 ; front surface + first palette -
                                 ; strictly BEFORE l2setup's
                                 ; vid_pal_black/mode switch clobber
                                 ; anything; only on a successful open
    call vid_run_l2setup_body
    ld b, 0
.back:
    ld hl, vid_run.orchret
    push hl
    ld a, VID_PAGE
    jp ovl_map_page
.fail:
 IFDEF DEBUG
    push bc
    call vid_open_fail_print     ; per-verdict message (plain call)
    pop bc
 ENDIF
    ; nothing armed, nothing displayed, ring freed: only the music
    ; freeze needs reversing (the PSG park recovers on the next tick)
    ld a, (vidSvAudEnable)
    ld (audEnable), a
    jr .back

; ---------------------------------------------------------------------
; vid_run_entry_body - entry state capture (carried from v1; MMU6/7
; stay hot in vid_run - the ordering hazard - everything else lands
; here). NEW (3a): MMU2 is captured too (the borrowed dest window).
; 3c: the vidSv* cells below are VID_PAGE2-local now, so the old MMU6
; bracket is gone. Then the samples abort (waited), the music-tick
; freeze, and the AY music park. Plain ret. Corrupts everything.
; ---------------------------------------------------------------------
vid_run_entry_body:
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
    ld e, NR_MMU2
    call nr_read
    ld (vidSvMmu2), a
    ld hl, (IM2_CTC_STUB+1)
    ld (vidSvCtcStub), hl
    ld a, (audEnable)
    ld (vidSvAudEnable), a
    ld b, a                      ; stash for the samples-abort test
    ld a, (l2FrontBank)
    ld (vidSvL2Front), a
    ld a, (l2BackBank)
    ld (vidSvL2Back), a

    ; --- samples abort (SSTOP request path, waited). audEnable = 0
    ; means aud_tick never runs - skip the wait (the bit would never
    ; clear). B holds the just-captured audEnable. ---
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
    ; --- music tick frozen (also stops the frame ISR's MMU6/7 remap
    ; around aud_tick - the banking invariant's structural guarantee)
    xor a
    ld (audEnable), a

    ; --- AY park (owner hardware finding + SP15 3a leg regression).
    ; ENTRY ORDER (load-bearing): capture -> samples abort (waited,
    ; needs the tick alive) -> audEnable=0 (tick frozen) -> park. The
    ; park MUST follow the freeze: a park before it would be re-latched
    ; by the very next 50Hz music tick. audEnable=0 leaves every PSG
    ; latched on its last tone, and nothing can rewrite ANY of them for
    ; the whole session - so park ALL THREE. The v1 park covered only
    ; PSG 1/2 ("PSG 3 left to beeps/effects", the explicit-stop
    ; convention); but the multi-PSG AKY player drives music channels
    ; 7-9 + effects on PSG 3 (audiobank aud_music_stop parks it for the
    ; same reason), and a frozen beep/effect/AYS stream holds PSG 3
    ; forever too - the 3a leg's "TONE HELD" was a held PSG-3 voice
    ; sounding under the video. Resume needs nothing for music: the
    ; AKY tick rewrites PSG 1-3 every frame once audEnable is
    ; restored. A beep straddling the video is TRUNCATED, not
    ; resumed: aud_beep_start programs PSG 3's tone/mixer/volume
    ; once at beep-start; aud_tick only counts audBeepFrames down
    ; and calls aud_beep_silence at zero, it never reprograms the
    ; tone - so the park's silence sticks for the rest of the beep's
    ; nominal duration. An AYS stream rewrites its registers each
    ; tick. DI-bracketed ($FFFD select latch must not interleave).
    di
    ld a, $FF                    ; Turbo Sound select: music PSG 1
    call .psgpark
    ld a, $FE                    ; music PSG 2
    call .psgpark
    ld a, $FD                    ; PSG 3: music channels 7-9 + beep/
    call .psgpark                ; effect/stream - all frozen too
    ei
    ret                          ; 3c: plain return to the orchestrator

; Park one PSG (A = Turbo Sound select): mixer all off, volumes 0.
; Corrupts BC, DE.
.psgpark:
    ld bc, $FFFD
    out (c), a
    ld d, 7
    ld e, $3F
    call .psgreg                 ; R7: mixer all off
    ld e, 0
    ld d, 8
    call .psgreg                 ; R8/9/10: volumes 0
    ld d, 9
    call .psgreg
    ld d, 10                     ; falls through for the last write
.psgreg:
    ld bc, $FFFD
    out (c), d
    ld b, $BF
    out (c), e
    ret

; Entry/exit symmetry captures (3c cell move: written by the entry/
; l2setup bodies, read by the restore body - all VID_PAGE2 code, so
; the cells live page-local and the old bracket translations are
; gone; only vidSvMmu6/7 stay hot, see the hot cells block).
vidSvMmu2:       db 0            ; the borrowed dest window (3a)
vidSvMmu3:       db 0            ; the borrowed audio window (3c)
vidSvNr12:       db 0
vidSvNr70:       db 0
vidSvNr69:       db 0
vidSvNr15:       db 0
vidSvCtcStub:    dw 0
vidSvAudEnable:  db 0
vidSvL2Front:    db 0
vidSvL2Back:     db 0
vidSvNr43:       db 0            ; captured constant (PAL_L2_FIRST) -
                                 ; NR $43 is not readable (v1 finding)
vidSvNr6b:       db 0            ; presentation isolation: tilemap
vidSvNr4a:       db 0            ; presentation isolation: fallback

; SP15 L2 snapshot cells (page-local like vidSv*): the reserved pool
; bank list + the first-palette readback. vidSnapCnt = 0 means no
; snapshot this session (Layer 2 hidden pre-video / nothing held -
; the idempotent-free sentinel, like vidAudBankC).
vidSnapCnt:      db 0
vidSnapBanks:    ds VID_SNAP_MAX
vidSnapDir:      db 0            ; copy engine direction (1 = save)
vidSnapPal:      ds NXV_PAL_BYTES ; 256 entries x NR $44 pair (512B)

; ---------------------------------------------------------------------
; vid_run_l2setup_body - Layer 2 mode/clip/scroll per the v2 header,
; presentation isolation, BLACK palettes, CTC time-constant lookup,
; ISR select + end markers, the DMA session init, and the DEBUG
; timeline zero. Reads the vidP_* staging block directly (same page);
; writes to hot cells/code go through the MMU6 bracket (rubric 3).
; Plain ret to the orchestrator (3c). Corrupts everything.
; ---------------------------------------------------------------------
vid_run_l2setup_body:
    call data_save
    ld a, VID_PAGE
    call data_map_page
    ; borrowed AUDIO window (3c): MMU3 -> the session audio bank for
    ; the whole armed window (vidAudBuf = VID_AUD_WIN; captured here,
    ; restored in step 8 with MMU2 - the same borrowed-window pattern;
    ; FOURTH RULE in the file header)
    ld e, NR_MMU3
    call nr_read
    ld (vidSvMmu3), a
    ld a, (vidAudBankC)
    add a, a
    nextreg NR_MMU3, a
    ; presentation isolation: tilemap off, fallback black (restored
    ; on every real exit - vid_run_restore_body)
    ld e, NR_TM_CTRL
    call nr_read
    ld (vidSvNr6b), a            ; page-local (3c cell move)
    and %01111111
    nextreg NR_TM_CTRL, a
    ld e, NR_FALLBACK
    call nr_read
    ld (vidSvNr4a), a            ; page-local (3c cell move)
    xor a
    nextreg NR_FALLBACK, a
    ; NR $43 is not reliably readable: capture the game's convention
    ; (PAL_L2_FIRST - every L2 palette writer asserts it) and prime
    ; the double-buffer tracker to match (v1 finding, carried)
    ld a, PAL_L2_FIRST
    ld (vidSvNr43), a            ; page-local (3c cell move)
    ld (vidPalCtrl+DATA_WINDOW-OVL_ORG), a
    ; mode + full-width clip (v2 width code: 1 = 320/mode-1)
    ld a, (vidP_Shape)
    or a
    jr z, .l2mode0
    ld a, NXV_NR70_MODE1
    nextreg NR_L2_CTRL, a
    nextreg NR_L2_TRANSP, TM_TRANSP_ATTR
    nextreg NR_CLIP_IDX, 1
    xor a
    nextreg NR_L2_CLIP, a        ; X1 = 0 (full-bleed)
    ld a, NXV_CLIP_X2_MODE1
    nextreg NR_L2_CLIP, a
    jr .clipY
.l2mode0:
    xor a
    nextreg NR_L2_CTRL, a
    nextreg NR_L2_TRANSP, TM_TRANSP_ATTR
    nextreg NR_CLIP_IDX, 1
    xor a
    nextreg NR_L2_CLIP, a
    ld a, NXV_CLIP_X2_MODE0
    nextreg NR_L2_CLIP, a
.clipY:
    ld a, (vidP_ClipY1)
    nextreg NR_L2_CLIP, a
    ld a, (vidP_ClipY2)
    nextreg NR_L2_CLIP, a
    ld a, (vidP_Yofs)
    nextreg NR_L2_YOFS, a
    nextreg NR_L2_XOFS, 0
    ld e, NR_DISPLAY_CTRL
    call nr_read
    or %10000000
    nextreg NR_DISPLAY_CTRL, a   ; Layer 2 on
    nextreg NR_LAYERS, 0
    ; BOTH Layer 2 palettes black: the screen shows black (never
    ; stale content misread in the new mode) until the first
    ; keyframe's PAL + KFLIP present real colour - kills the entry
    ; flash class outright. Black ($00) can never equal the
    ; TM_TRANSP_ATTR colour, so the surface stays fully opaque.
    call vid_pal_black
    ; zxnDMA session init: the never-changing WR2 (port B memory/
    ; increment/cycle-2) + WR5 (stop on end) - each chunk's arm block
    ; (hot) carries its own WR0/WR1 (doc 11 one-shot law; DI bracket)
    ld hl, vidDmaInit
    ld bc, (vidDmaInit_len << 8) | DMA_PORT
    di
    otir
    ei
    ; CTC time constant: table-driven from the live video-timing mode
    ; and the header's channel count (carried v1 tables/derivation)
    ld e, NR_VIDEO_TIMING
    call nr_read
    and 7
    ld c, a
    ld b, 0
    ld a, (vidP_AChan)
    ld hl, vidCtcTcNxvMono
    cp 2
    jr nz, .gottctab
    ld hl, vidCtcTcNxvStereo
.gottctab:
    add hl, bc
    ld a, (hl)
    ld (vidCtcTc+DATA_WINDOW-OVL_ORG), a
    ; IM2_CTC_STUB (ISR select) - RESIDENT memory, single atomic
    ; LD (nn),HL; strictly before the CTC arm (hot, after this body)
    ld a, (vidP_AChan)
    ld hl, video_ctc_isr
    cp 2
    jr nz, .isrpicked
    ld hl, video_ctc_isr_stereo
.isrpicked:
    ld (IM2_CTC_STUB+1), hl
    ; both ISRs' end markers: end = vidAudBuf + real - 1 (mono) / - 2
    ; (stereo pair) - VID_PAGE code bytes, translated writes
    ld hl, (vidP_ABytes)
    ld de, vidAudBuf
    add hl, de
    dec hl                       ; mono end (real-1)
    ld a, l
    ld (video_ctc_isr.cmplo+1+DATA_WINDOW-OVL_ORG), a
    ld a, h
    ld (video_ctc_isr.cmphi+1+DATA_WINDOW-OVL_ORG), a
    dec hl                       ; stereo end (real-2)
    ld a, l
    ld (video_ctc_isr_stereo.cmplo+1+DATA_WINDOW-OVL_ORG), a
    ld a, h
    ld (video_ctc_isr_stereo.cmphi+1+DATA_WINDOW-OVL_ORG), a
    ; double-buffer cells (3b): the first fill lands in half A (the
    ; end markers above already point there); the queue end offset =
    ; real bytes - 1 (mono) / - 2 (stereo pair)
    ld hl, vidAudBuf
    ld (vidAudFillPtr+DATA_WINDOW-OVL_ORG), hl
    ld hl, (vidP_ABytes)
    dec hl
    ld a, (vidP_AChan)
    cp 2
    jr nz, .endoff
    dec hl
.endoff:
    ld (vidAudEndOff+DATA_WINDOW-OVL_ORG), hl
 IFDEF DEBUG
    ; timeline baseline: zero vidTlTicks..vidLoopPass (vidTlFillFrames
    ; sits outside the span - the open body already staged it)
    ld hl, vidTlTicks+DATA_WINDOW-OVL_ORG
    ld (hl), 0
    ld de, vidTlTicks+1+DATA_WINDOW-OVL_ORG
    ld bc, VID_TL_ZERO_LEN-1
    ldir
 ENDIF
    ; --- decode session init (3c: moved cold into this bracket -
    ; strictly pre-arm; the hot .orchret side arms right after; the
    ; audio-0 preload there consumes these cursors) ---
    xor a
    ld (vidInSpan+DATA_WINDOW-OVL_ORG), a
    ld (vidPalPending+DATA_WINDOW-OVL_ORG), a
    ld (vidFramePos+2+DATA_WINDOW-OVL_ORG), a
    ld (vidAudNextRdy+DATA_WINDOW-OVL_ORG), a
    ld hl, 512                   ; frame 0's audio follows the header
    ld (vidFramePos+DATA_WINDOW-OVL_ORG), hl
    ld hl, (vidFrames+DATA_WINDOW-OVL_ORG)
    ld (vidFramesLeft+DATA_WINDOW-OVL_ORG), hl
    call data_restore
    ret                          ; 3c: plain return to the orchestrator

; Zero both Layer 2 palette banks (256 entries x 2 zero writes each;
; NR $44 9-bit pairs, index auto-increments after the second write).
; Leaves NR $43 = PAL_L2_FIRST (the game convention). Corrupts AF, B.
vid_pal_black:
    nextreg NR_PAL_CTRL, PAL_L2_FIRST
    nextreg NR_PAL_INDEX, 0
    call .fill
    nextreg NR_PAL_CTRL, PAL_L2_EDIT_SECOND
    nextreg NR_PAL_INDEX, 0
    call .fill
    nextreg NR_PAL_CTRL, PAL_L2_FIRST
    ret
.fill:
    ld b, 0                      ; 256 entries
    xor a
.l:
    nextreg NR_PAL_VALUE9, a
    nextreg NR_PAL_VALUE9, a
    djnz .l
    ret

; zxnDMA session init program (WR2 + WR5; see the hot arm blocks).
vidDmaInit:
    db $83                       ; WR6: disable (clean slate)
    db %01010000                 ; WR2: B memory, incrementing, timing
    db %00000010                 ; B cycle length 2 (no prescaler)
    db %10000010                 ; WR5: stop on end of block (one-shot)
vidDmaInit_len equ $ - vidDmaInit

; Per-video-mode CTC time constants for the two supported audio rates
; (carried verbatim from v1 - same rates, same derivation; see git
; history for the full per-mode error tables).
vidCtcTcNxvStereo:
    db 112, 114, 117, 120, 124, 128, 132, 108
vidCtcTcNxvMono:
    db 75, 76, 78, 80, 83, 85, 88, 72

; ---------------------------------------------------------------------
; vid_run_restore_body - the teardown (reached from vid_run's
; .restore AFTER the CTC is parked). EXIT ORDER FIX (SP15 3a,
; subsumed SP14a defect): Layer 2 is HIDDEN across the resolution/
; bank restore - the old order restored NR $12/$70 while Layer 2 was
; still visible in the video mode, and one field of the old surface
; scanned out through the new interpretation (the exit corruption
; flash). Symmetry matrix (restore order):
;   1. IM2 stub, audEnable, l2Front/Back cells (resident state)
;   2. NR $69 bit7 CLEARED - Layer 2 hidden, other bits held
;   3. NR $12 bank, NR $70 mode - restored invisibly
;   4. clip window (NR $1C/$18) + scroll (NR $16/$17) + NR $43
;      palette select - ALSO mode interpretation, ALSO restored
;      inside the hidden bracket (SP15 3a letterbox exit flash: the
;      l2setup body programs a letterbox clip band + a YOFS wrap that
;      were never restored at all, so the re-shown game surface
;      scanned out rolled/clipped for a field on 003/004/005; benign
;      on full-band shapes only because their YOFS is 0. Clip/scroll
;      are reconstructed by convention: l2_clip_set (overlay2) is the
;      game's only clip/scroll writer and always programs full-bleed
;      clip for its mode + zero scroll - the mode comes from the
;      saved NR $70 bits 5:4, the same derivation l2_clip_set uses.)
;   4b. SNAPSHOT restore (SP15): the game's front-surface pixels
;      (DMA one-shots out of the reserved snapshot banks) then the
;      first-palette contents (512 NR $44 writes from vidSnapPal) -
;      content writes only, still inside the hidden bracket, so the
;      re-show at step 5 presents the game's own picture. No-op when
;      vidSnapCnt = 0 (L2 was hidden - restore-to-hidden is exact).
;   5. NR $69 = saved value - re-shows iff it was on pre-video
;   6. NR $15 layers
;   7. NR $6B tilemap, NR $4A fallback (presentation isolation)
;   8. MMU2 (the borrowed dest window)
;   9. ring + audio + snapshot banks freed
; Hops back to vid_run.restore_tail. Corrupts everything.
; ---------------------------------------------------------------------
vid_run_restore_body:
    ld hl, (vidSvCtcStub)        ; vidSv* are VID_PAGE2-local (3c cell
    ld (IM2_CTC_STUB+1), hl      ; move) - the old MMU6 bracket is gone
    ld a, (vidSvAudEnable)
    ld (audEnable), a
    ld a, (vidSvL2Front)
    ld (l2FrontBank), a
    ld a, (vidSvL2Back)
    ld (l2BackBank), a
    ; EXIT ORDER FIX steps 2-5 (see the header matrix)
    ld e, NR_DISPLAY_CTRL
    call nr_read
    and %01111111
    nextreg NR_DISPLAY_CTRL, a   ; hide Layer 2
    ld a, (vidSvNr12)
    nextreg NR_L2_BANK, a
    ld a, (vidSvNr70)
    nextreg NR_L2_CTRL, a
    ; step 4: clip window + scroll + palette select, still hidden.
    ; Game convention (l2_clip_set): X1/Y1 = 0, X2/Y2 full-bleed for
    ; the game's mode, XOFS/YOFS = 0. Mode from the saved NR $70.
    ld a, (vidSvNr70)
    and %00110000                ; bits 5:4: 00 = 256x192, else 320x256
    ld d, 255
    ld e, 191                    ; 256x192: X2 = 255, Y2 = 191
    jr z, .clipgame
    ld d, 159                    ; 320x256: X2 = 159 (2-pixel units),
    ld e, 255                    ; Y2 = 255
.clipgame:
    nextreg NR_CLIP_IDX, 1       ; reset the Layer 2 clip index
    nextreg NR_L2_CLIP, 0        ; X1
    ld a, d
    nextreg NR_L2_CLIP, a        ; X2
    nextreg NR_L2_CLIP, 0        ; Y1
    ld a, e
    nextreg NR_L2_CLIP, a        ; Y2
    nextreg NR_L2_XOFS, 0
    nextreg NR_L2_YOFS, 0
    ld a, (vidSvNr43)
    nextreg NR_PAL_CTRL, a
    ; step 4b (SP15 snapshot): pixels + palette return while Layer 2
    ; is still hidden (see the matrix comment)
    call vid_snap_restore_body
    ld a, (vidSvNr69)
    nextreg NR_DISPLAY_CTRL, a   ; re-show (iff it was on pre-video)
    ld a, (vidSvNr15)
    nextreg NR_LAYERS, a
    ld a, (vidSvNr6b)
    nextreg NR_TM_CTRL, a
    ld a, (vidSvNr4a)
    nextreg NR_FALLBACK, a
    ld a, (vidSvMmu2)
    nextreg NR_MMU2, a
    ld a, (vidSvMmu3)            ; the borrowed audio window (3c)
    nextreg NR_MMU3, a
    call vid_ring_free
    call vid_aud_bank_free
    call vid_snap_free
    call vid_stream_close        ; streaming keeps the esxDOS handle
                                 ; open for the session (the hot side
                                 ; already CMD12'd its window before
                                 ; hopping here); resident closed at
                                 ; load time - idempotent either way
    ld hl, vid_run.restore_tail
    push hl
    ld a, VID_PAGE
    jp ovl_map_page

; ---------------------------------------------------------------------
; vid_snap_save_body - SP15 L2 SNAPSHOT capture (cold, strictly
; pre-arm): the game's front Layer 2 surface pixels into the reserved
; snapshot banks + the L2 FIRST palette contents into vidSnapPal.
; Called by vid_run_orch_body between open success and the l2setup
; body - before vid_pal_black / the mode switch clobber anything; a
; failed open never reaches it, so the copy needs no unwind of its
; own. No-op when vidSnapCnt = 0 (Layer 2 was hidden pre-video).
; Palette: hardware readback - per entry NR $40 index write (also
; resets the NR $44 two-byte latch), nr_read $41 (RRRGGGBB) +
; nr_read $44 (bit7 priority + bit0 blue LSB), stored exactly as the
; NR $44 replay pair. The readback goes through the FIRST-palette
; edit target, the convention every game-side L2 palette writer
; asserts (vidSvNr43's own finding); the explicit NR $43 select makes
; the target deterministic and equals the value the restore body
; rewrites anyway. NR $41/$44 VALUE readback is the design's one
; silicon unknown - the owner leg's colour-correct return is the
; proof (fallback on refutation: a shadow-tee in the overlay2 palette
; writers, recorded in the brief). Pixels: shared engine below.
; Corrupts everything.
; ---------------------------------------------------------------------
vid_snap_save_body:
    ld a, (vidSnapCnt)
    or a
    ret z
    nextreg NR_PAL_CTRL, PAL_L2_FIRST
    ld hl, vidSnapPal
    xor a
.palrd:
    push af
    nextreg NR_PAL_INDEX, a      ; index write resets the $44 latch
    ld e, NR_PAL_VALUE
    call nr_read                 ; preserves DE/HL (hardware.asm)
    ld (hl), a                   ; first byte: RRRGGGBB
    inc hl
    ld e, NR_PAL_VALUE9
    call nr_read
    ld (hl), a                   ; second: bit7 priority + bit0 B0
    inc hl
    pop af
    inc a
    jr nz, .palrd                ; 256 entries
    ld a, 1                      ; direction: save (L2 -> pool)
    jp vid_snap_copy             ; tail call - rets to the orch body

; ---------------------------------------------------------------------
; vid_snap_restore_body - restore matrix step 4b (SP15): pixels then
; palette written back while Layer 2 is still hidden (called between
; step 4 and the step-5 re-show). No-op when vidSnapCnt = 0 -
; restore-to-hidden is already exact. NR $43 = PAL_L2_FIRST here
; (step 4 just wrote vidSvNr43: edit = first palette, auto-inc on).
; audEnable was restored at step 1, so the 50Hz frame ISR's MMU6/7
; remap around aud_tick is LIVE - the copy engine's DI-bracketed
; one-shot discipline covers it (doc 11's law). ~14ms mode-1 (~9ms
; mode-0): under one field, invisible inside the hidden bracket.
; Corrupts everything.
; ---------------------------------------------------------------------
vid_snap_restore_body:
    ld a, (vidSnapCnt)
    or a
    ret z
    xor a                        ; direction: restore (pool -> L2)
    call vid_snap_copy
    ; palette replay: 512 NR $44 writes from the captured pairs; the
    ; index auto-increments after each entry's second write
    nextreg NR_PAL_INDEX, 0
    ld hl, vidSnapPal
    ld b, 0                      ; 256 entries
.pal:
    ld a, (hl)
    inc hl
    nextreg NR_PAL_VALUE9, a     ; first byte: RRRGGGBB
    ld a, (hl)
    inc hl
    nextreg NR_PAL_VALUE9, a     ; second: priority + blue LSB
    djnz .pal
    ret

; ---------------------------------------------------------------------
; vid_snap_copy - the shared snapshot page-pair copy engine. In: A =
; direction (nonzero = save: L2 -> pool; zero = restore: pool -> L2).
; Walks 2 x vidSnapCnt 8K pages (6 or 10): the L2 page (physical
; pages vidSvNr12*2.. - independent of the live NR $12) at MMU2/$4000
; (SECOND RULE - the window is session-owned from entry capture to
; restore step 8, free to retarget in both bodies), the snapshot pool
; page at MMU6/$C000 via the data_save bracket (rubric 3); MMU7 stays
; VID_PAGE2 (cold body). Transport: zxnDMA mem-to-mem per doc 11's
; law - WR2/WR5 programmed once per body (vidDmaInit, same page),
; then 32 fixed 256-byte CONTINUOUS one-shot chunks per page, each
; programmed AND run to completion inside its own DI bracket (the
; frame ISR remaps MMU6/7 around aud_tick; no transfer may be in
; flight outside DI). ~4T/B: 80KB ~= 11.7ms + arm overhead. LDIRX is
; NOT usable here - it skips writes where (HL) == A (the transparency
; copier, doc 01). Closes the MMU6 bracket on exit. Corrupts
; everything.
; ---------------------------------------------------------------------
vid_snap_copy:
    ld (vidSnapDir), a
    call data_save
    ; session WR2/WR5 (the never-changing halves - each chunk's arm
    ; below carries its own WR0/WR1, the hot kernels' scheme)
    ld hl, vidDmaInit
    ld bc, (vidDmaInit_len << 8) | DMA_PORT
    di
    otir
    ei
    ld a, (vidSnapCnt)
    add a, a
    ld b, a                      ; B = 8K pages (6 or 10)
    ld c, 0                      ; C = page index
.page:
    push bc
    ld a, (vidSvNr12)
    add a, a
    add a, c
    nextreg NR_MMU2, a           ; L2 page: front bank base + index
    ld a, c
    srl a                        ; snapshot list slot = index/2
    ld hl, vidSnapBanks
    add hl, a                    ; Z80N (doc 05)
    ld a, (hl)
    add a, a
    ld d, a
    ld a, c
    and 1
    add a, d                     ; pool page = bank*2 + (index & 1)
    call data_map_page           ; -> MMU6
    ld d, high VID_DST_WIN       ; D = L2-side chunk high byte ($40)
    ld e, high DATA_WINDOW       ; E = pool-side chunk high byte ($C0)
    ld b, 32                     ; 32 x 256B chunks per 8K page
.chunk:
    push bc
    push de
    ld l, 0                      ; chunks are 256-aligned
    ld a, (vidSnapDir)
    or a
    jr z, .rst
    ld h, d
    ld (vidSnapDmaArm.asrc), hl  ; save: port A = the L2 chunk
    ld h, e
    ld (vidSnapDmaArm.bdst), hl  ;       port B = the pool chunk
    jr .arm
.rst:
    ld h, e
    ld (vidSnapDmaArm.asrc), hl  ; restore: port A = the pool chunk
    ld h, d
    ld (vidSnapDmaArm.bdst), hl  ;          port B = the L2 chunk
.arm:
    ld hl, vidSnapDmaArm
    ld bc, (vidSnapDmaArm_len << 8) | DMA_PORT
    di
    otir                         ; program + run to completion in ONE
    ei                           ; DI bracket (doc 11's one-shot law)
    pop de
    pop bc
    inc d                        ; both windows advance 256
    inc e
    djnz .chunk
    pop bc
    inc c
    djnz .page
    jp data_restore              ; close the MMU6 bracket (tail ret)

; Per-chunk snapshot arm (the vidDmaCpArm shape, this page): WR0
; (A addr + length), WR1 incrementing + timing, WR4 CONTINUOUS +
; B addr, load, enable. WR2/WR5 persist from vidDmaInit (sent once
; per body). The length is the fixed 256-byte chunk - only the two
; addresses are patched.
vidSnapDmaArm:
    db $83                       ; WR6: disable (known-clean re-entry)
    db %01111101                 ; WR0: A->B; A addr + length follow
.asrc:
    dw 0                         ; port A = source chunk (patched)
    dw 256                       ; block length: exact count, fixed
    db %01010100                 ; WR1: A memory, INCREMENTING, timing
    db %00000010                 ; A cycle length 2
    db %10101101                 ; WR4: CONTINUOUS, port B addr follows
.bdst:
    dw 0                         ; port B = dest chunk (patched)
    db $CF                       ; WR6: load
    db $87                       ; WR6: enable - LAST byte; the CPU
                                 ; stalls here until the chunk is done
vidSnapDmaArm_len equ $ - vidSnapDmaArm

; ---------------------------------------------------------------------
; vid_open_video_body - build vidName ("NNN.VID",0) from the video
; number (C, set by vid_play), probe PARTn\ then root, open the
; winner raw (carried from v1; simplified: every cell this cluster
; touches now lives on THIS page, so the old MMU6 translations are
; gone). Out (via the hop back to vid_play.openret): B = 0 opened /
; 1 neither name opened. Corrupts everything.
; ---------------------------------------------------------------------
vid_open_video_body:
    ld a, c                      ; C = video number
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
    ex de, hl                    ; DE = vidName+3 (write cursor)
    ld hl, vidExtVid             ; ".VID",0 (5 bytes)
    ld bc, 5
    ldir
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
    ld (hl), 92                  ; '\' (decimal - rubric 8: sjasmplus
    inc hl                       ; does not escape char literals)
    ex de, hl                    ; DE = vidNamePart+6
    ld hl, vidName
    ld bc, 8                     ; "NNN.VID",0
    ldir
    ld ix, vidNamePart
    call vid_stream_open_body    ; same page - plain call
    jr nc, .done                 ; PARTn open succeeded
.openroot:
    ld ix, vidName
    call vid_stream_open_body
.done:
    ld b, 0
    jr nc, .haveresult
    ld b, 1
 IFDEF DEBUG
    push bc
    call vid_play_missing_print  ; "VID FILE?" (plain call, 3c)
    pop bc
 ENDIF
.haveresult:
    ld hl, vid_play.openret
    push hl
    ld a, VID_PAGE
    jp ovl_map_page

vidExtVid: db ".VID", 0

 IFDEF DEBUG
; DEBUG-only diagnostic prints - all reached strictly pre-arm, all
; plain same-page calls now (3c). Release stays silent on every
; failure, as v1 did.
vid_play_missing_print:
    ld b, 23
    ld c, 0
    call dbg_at
    ld hl, msgVidMissing
    jp dbg_puts

; Open/load failure print: B = 1 VID FMT / 2 no bank / 3 no ring fits
; (pool below one streamed frame's need, or the file is >= 16MB) / 4
; too fragmented to stream (filemap exceeds the hot copy - .defrag).
; Corrupts B - the caller brackets it.
vid_open_fail_print:
    push bc
    ld b, 23
    ld c, 0
    call dbg_at
    pop bc
    ld a, b
    cp 2
    ld hl, msgVidBadFmt
    jr c, .have                  ; B = 1
    ld hl, msgVidNoBank2
    jr z, .have                  ; B = 2
    cp 4
    ld hl, msgVidTooBig
    jr c, .have                  ; B = 3
    ld hl, msgVidFrag            ; B = 4
.have:
    jp dbg_puts

msgVidMissing:  db "VID FILE?", 0
msgVidNoBank2:  db "VID NOBANK2", 0
msgVidBadFmt:   db "VID FMT?", 0
msgVidTooBig:   db "VID SIZE?", 0
msgVidFrag:     db "VID FRAG?", 0
 ENDIF

; ---------------------------------------------------------------------
; vid_stream_open_body - the real open (carried; IX = filename in,
; CF/A out; called same-page from vid_open_video_body). DISK_FILEMAP
; runs FIRST (before F_FSTAT - the sector-cache ordering law), then
; F_FSTAT for the size, then the raw cursor reset. RAW ONLY (3b): the
; F_READ mode and its vidStrmMode selector are DELETED - the player
; always opened raw since 3a, the branch was dead code. Corrupts AF,
; BC, DE, HL, IX.
; ---------------------------------------------------------------------
vid_stream_open_body:
    ld a, $FF
    ld (vidHandle), a
    call esx_getsetdrv
    jr c, vid_stream_open_fail
    ld b, ESX_MODE_READ
    call esx_fopen               ; IX = caller's filename
    jr c, vid_stream_open_fail
    ld (vidHandle), a
    call vid_raw_setup           ; capture + validate the filemap
    jr c, vid_stream_open_openfail
    ld a, (vidHandle)            ; F_FSTAT - legal AFTER FILEMAP,
    ld ix, vidFstatBuf           ; before the card streams
    rst $08
    db ESX_F_FSTAT
    jr c, vid_stream_open_openfail
    ld hl, (vidFstatBuf+7)
    ld (vidSizeLo), hl
    ld hl, (vidFstatBuf+9)
    ld (vidSizeHi), hl
    call vid_raw_reset_cursor    ; same-page - no hop needed
    or a                         ; CF clear
    ret
vid_stream_open_openfail:
    push af                      ; close the handle, propagating A
    ld a, (vidHandle)
    call esx_fclose
    ld a, $FF
    ld (vidHandle), a
    pop af
    scf
    ret
vid_stream_open_fail:
    scf
    ret

; ---------------------------------------------------------------------
; vid_raw_setup - raw-mode filemap capture (carried; the sector-cache
; touched-file reset, then DISK_FILEMAP, granularity flags, entry-end
; bookkeeping - all page-local now). Corrupts AF, BC, DE, HL, IX.
; ---------------------------------------------------------------------
vid_raw_setup:
    call vid_raw_seek0           ; F_SEEK -> offset 0
    ret c
    ld a, (vidHandle)            ; F_READ one byte (cache primer)
    ld ix, vidRawResetByte
    ld bc, 1
    call esx_fread
    ret c
    call vid_raw_seek0           ; F_SEEK back -> offset 0
    ret c
    ld a, (vidHandle)
    ld ix, vidFilemapBuf
    ld de, VID_FILEMAP_ENT
    rst $08
    db ESX_DISK_FILEMAP
    ret c                        ; A = esxDOS error, CF set
    ; DE = unused entries, HL = address past last written entry
    ld (vidCardFlags), a
    ld a, e
    or d
    jr nz, .roomok
    ld a, VID_ERR_FRAG           ; buffer full: cannot prove complete
    scf
    ret
.roomok:
    ld de, vidFilemapBuf
    or a
    sbc hl, de
    jr nz, .haveentries
    ld a, VID_ERR_NOMAP          ; empty map: nothing to stream
    scf
    ret
.haveentries:
    add hl, de                   ; re-form the end address (page-local)
    ld (vidStrmEntryEnd), hl
    or a                         ; CF clear
    ret

; F_SEEK the video handle to absolute offset 0 (carried).
vid_raw_seek0:
    ld bc, 0
    ld de, 0
    ld l, 0
    ld ix, 0
    ld a, (vidHandle)
    jp esx_fseek

vidRawResetByte: db 0
vidName:     ds 8                ; "NNN.VID",0
vidNamePart: ds 14               ; "PARTn\NNN.VID",0
vidFstatBuf: ds 11               ; F_FSTAT: +7(4) = file size

; =====================================================================
; SD STREAMING CLUSTER - COLD SIDE (3b status update of the 3a parts
; bin): serves the PRE-ARM work only - the resident full load and the
; streaming ring prefill, both through vid_stream_read below (raw
; CMD18, window persisting across calls per the carried contract).
; The ARMED session never executes this page: stage 3b re-hotted the
; per-block pieces as clones on VID_PAGE (vid_prod_step + vid_*_h -
; win open/close, sd cmd, block read, next-run, MF), owning hot twins
; of every cell they touch; .strm_loaded stages the handoff and
; clears the cold window flag so this side never double-closes. The
; F_READ branch and its vidStrmMode selector are DELETED (dead since
; 3a - the player always opens raw). Everything else is UNCHANGED
; from the v1-proven shapes.
; =====================================================================

; vid_stream_read - raw CMD18 read (the F_READ branch and vidStrmMode
; are DELETED - dead since 3a, the player always opens raw). In: A =
; dest 8K page (mapped at MMU6 for this call), DE = count <= $2000.
; Out: CF clear, BC = bytes read (short = EOF - callers count-check,
; the BC discipline); CF set, A = error.
; RAW CONTRACT (carried verbatim): the CMD18 window persists ACROSS
; calls (closed only at a fragment boundary, EOF, error, or
; vid_stream_close); while open, NO other filesystem/SD access may
; happen anywhere. Corrupts AF, BC, DE, HL, IX.
vid_stream_read:
    ld (vidReadPage), a
    jp vid_stream_read_raw

; Close the stream: release any raw window (CMD12 + deselect + MF
; restore), close the esxDOS handle. Idempotent. Corrupts AF,BC,DE,HL.
vid_stream_close:
    call vid_win_close
    ld a, (vidHandle)
    cp $FF
    ret z
    call esx_fclose
    ld a, $FF
    ld (vidHandle), a
    ret

; Reset the raw streaming cursor to file start (carried; page-local).
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

; Raw read path (carried verbatim - the register-resident fast path,
; the tail-buffer drain, the persistent-window discipline; see git
; history for the full derivation comments).
vid_stream_read_raw:
    ld (vidStrmNeed), de
    ld (vidReadCountSaved), de
    call data_save
    ld a, (vidReadPage)
    call data_map_page
    ld hl, DATA_WINDOW
    ld (vidStrmDest), hl
.outer:
    ld hl, (vidStrmNeed)
    ld a, h
    or l
    jp z, .retopen
    call vid_remain_zero
    jp z, .eofclose
    ld hl, (vidStrmBlkLen)
    ld de, (vidStrmBlkPos)
    or a
    sbc hl, de
    jr z, .needstream
    call vid_drain
    jp .outer
.needstream:
    ld hl, (vidStrmRunBlocks)
    ld a, h
    or l
    jr nz, .haveblocks
    call vid_win_close
    call vid_next_run
    jp c, .eofclose
.haveblocks:
    call vid_win_open
    jp c, .strmerr
    ld bc, (vidStrmRunBlocks)
    ld de, (vidStrmRemainHi)
    ld hl, (vidStrmRemainLo)
    exx
    ld de, (vidStrmNeed)
    ld hl, (vidStrmDest)
.fast:
    ld a, d
    cp 2
    jr c, .fastexit
    exx
    ld a, d
    or e
    jr nz, .fastruns
    ld a, h
    cp 2
    jr c, .fastexits
.fastruns:
    ld a, b
    or c
    jr z, .fastexits
    exx
    call vid_read_block
    jr c, .fasttok
    ld a, d
    sub 2
    ld d, a
    exx
    ld a, h
    sub 2
    ld h, a
    jr nc, .fastnb
    dec de
.fastnb:
    dec bc
    exx
    jr .fast
.fasttok:
    call vid_fast_spill
    jp .tokerr
.fastexits:
    exx
.fastexit:
    call vid_fast_spill
.inner:
    ld hl, (vidStrmNeed)
    ld a, h
    or l
    jp z, .retopen
    call vid_remain_zero
    jp z, .eofclose
    ld hl, (vidStrmRunBlocks)
    ld a, h
    or l
    jp z, .outer
    ld hl, (vidStrmNeed)
    ld de, 512
    or a
    sbc hl, de
    jp c, .viabuf
    call vid_remain_ge512
    jp c, .viabuf
    ld hl, (vidStrmDest)
    call vid_read_block
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
    call vid_read_block
    jp c, .tokerr
    call vid_remain_ge512
    jr nc, .fullblk
    ld hl, (vidStrmRemainLo)
    jr .havelen
.fullblk:
    ld hl, 512
.havelen:
    ld (vidStrmBlkLen), hl
    ld hl, 0
    ld (vidStrmBlkPos), hl
    call vid_drain
.blockdone:
    ld hl, (vidStrmRunBlocks)
    dec hl
    ld (vidStrmRunBlocks), hl
    jp .inner
.retopen:
    call data_restore
    jr .served
.eofclose:
    call vid_win_close
    call data_restore
.served:
    ld hl, (vidReadCountSaved)
    ld de, (vidStrmNeed)
    or a
    sbc hl, de
    push hl
    pop bc
    or a
    ret
.tokerr:
    ld a, VID_ERR_TOKEN
.strmerr:
    push af
    call vid_win_close
    call data_restore
    pop af
    scf
    ret

; Fast-path register spill (carried).
vid_fast_spill:
    ld (vidStrmDest), hl
    ld (vidStrmNeed), de
    exx
    ld (vidStrmRunBlocks), bc
    ld (vidStrmRemainHi), de
    ld (vidStrmRemainLo), hl
    exx
    ret

; Tail-buffer drain (carried).
vid_drain:
    ld hl, (vidStrmBlkLen)
    ld de, (vidStrmBlkPos)
    or a
    sbc hl, de
    ld de, (vidStrmNeed)
    or a
    sbc hl, de
    jr nc, .useneed
    add hl, de
    jr .count
.useneed:
    ld hl, (vidStrmNeed)
.count:
    push hl
    pop bc
    ld hl, vidStrmBlkBuf
    ld de, (vidStrmBlkPos)
    add hl, de
    ld de, (vidStrmDest)
    push bc
    ldir
    pop bc
    ld (vidStrmDest), de
    ld hl, (vidStrmBlkPos)
    add hl, bc
    ld (vidStrmBlkPos), hl
    ld hl, (vidStrmNeed)
    or a
    sbc hl, bc
    ld (vidStrmNeed), hl
    ld d, b
    ld e, c
    jp vid_remain_sub

; Next filemap entry -> the run cursor (carried). CF set = exhausted.
vid_next_run:
    ld hl, (vidStrmEntryPtr)
    ld de, (vidStrmEntryEnd)
    or a
    sbc hl, de
    jr c, .more
    scf
    ret
.more:
    ld hl, (vidStrmEntryPtr)
    ld e, (hl)
    inc hl
    ld d, (hl)
    inc hl
    ld (vidStrmRunAddrLo), de
    ld e, (hl)
    inc hl
    ld d, (hl)
    inc hl
    ld (vidStrmRunAddrHi), de
    ld e, (hl)
    inc hl
    ld d, (hl)
    inc hl
    ld (vidStrmRunBlocks), de
    ld (vidStrmEntryPtr), hl
    or a
    ret

; Ensure the CMD18 window is open at the current run (carried).
vid_win_open:
    ld a, (vidStrmWinOpen)
    or a
    ret nz
    call vid_mf_disable
    call vid_strm_start
    jr c, .failed
    ld a, 1
    ld (vidStrmWinOpen), a
    or a
    ret
.failed:
    push af
    call vid_mf_restore
    pop af
    scf
    ret

; Close the window if open (carried; idempotent).
vid_win_close:
    ld a, (vidStrmWinOpen)
    or a
    ret z
    call vid_strm_end
    call vid_mf_restore
    xor a
    ld (vidStrmWinOpen), a
    ret

; CMD18 READ_MULTIPLE_BLOCK at the run's card address (carried).
vid_strm_start:
    ld a, (vidCardFlags)
    and 1
    ld hl, (vidStrmRunAddrHi)
    ld de, (vidStrmRunAddrLo)
    ld a, CMD18_READ_MULTIPLE_BLOCK
    call vid_sd_cmd
    jr nz, .cmdfail
    or a
    ret
.cmdfail:
    call vid_card_deselect
    ld a, VID_ERR_CMD
    scf
    ret

; CMD12 STOP_TRANSMISSION + flush + deselect (carried).
vid_strm_end:
    ld a, (vidCardFlags)
    and 1
    ld a, CMD12_STOP_TRANSMISSION
    call vid_sd_cmd_noparam
    ld b, 8+1
.tail:
    in a, (PORT_SPI_DAT)
    djnz .tail
vid_card_deselect:
    ld a, $FF
    out (PORT_SPI_CS), a
    in a, (PORT_SPI_DAT)
    nop
    in a, (PORT_SPI_DAT)
    or a
    ret

; Read one 512-byte block into (HL) (carried: bounded token wait -
; rubric 6; A as the unroll counter - rubric 2, ini consumes B; the
; DEBUG/Release unroll split is the v1 space/speed trade carried).
vid_read_block:
.wt:
    ld bc, 0                     ; bounded retry: 65536 polls
.wtloop:
    in a, (PORT_SPI_DAT)
    inc a
    jr nz, .wtgot
    dec bc
    ld a, b
    or c
    jr nz, .wtloop
    jp .tokbad
.wtgot:
    dec a
    cp $FE
    jp nz, .tokbad
    ld c, PORT_SPI_DAT
 IFDEF DEBUG
    ld a, 8                      ; eight 64-byte eighths
.halfloop:
    DUP 64
      ini
    EDUP
    dec a
    jp nz, .halfloop
 ELSE
    ld a, 2                      ; two 256-byte halves (the measured
.halfloop:                       ; 22.1T/byte sustained configuration)
    DUP 256
      ini
    EDUP
    dec a
    jp nz, .halfloop
 ENDIF
    in a, (c)                    ; skip the 2-byte CRC
    nop
    in a, (c)
    or a
    ret
.tokbad:
    scf
    ret

; SD SPI command (carried; Z = card select from caller's and 1).
vid_sd_cmd_noparam:
    ld h, 0
    ld l, 0
    ld d, 0
    ld e, 0
vid_sd_cmd:
    ld b, $FF
    ld c, a
    ld a, SD_CS0
    jr z, .cs
    ld a, SD_CS1
.cs:
    out (PORT_SPI_CS), a
    in a, (PORT_SPI_DAT)
    ld a, c
    ld c, PORT_SPI_DAT
    out (c), a
    ld a, h
    out (c), a
    ld a, l
    out (c), a
    ld a, d
    out (c), a
    ld a, e
    out (c), a
    ld a, b
    out (c), a
    nop
    ld b, 0                      ; bounded R1 poll: 256 tries (NCR <= 8
.resp:                           ; bytes - generous; rubric 6, the
    in a, (PORT_SPI_DAT)         ; nxb_sd_cmd precedent - v1's copy of
    inc a                        ; this loop was the last unbounded SD
    jr nz, .got                  ; poll left in the tree)
    djnz .resp
    or 1                         ; timeout: force NZ (treated as reject)
    ret
.got:
    dec a                        ; Z iff R1 == 0
    ret

; Multiface disable/restore around the raw window (carried).
vid_mf_disable:
    ld e, NR_PERIPH2
    call nr_read
    ld (vidMfSave), a
    and %11110111
    nextreg NR_PERIPH2, a
    ret
vid_mf_restore:
    ld a, (vidMfSave)
    nextreg NR_PERIPH2, a
    ret

; remain helpers (carried).
vid_remain_zero:
    ld hl, (vidStrmRemainLo)
    ld a, h
    or l
    ret nz
    ld hl, (vidStrmRemainHi)
    ld a, h
    or l
    ret

vid_remain_ge512:
    ld hl, (vidStrmRemainHi)
    ld a, h
    or l
    jr nz, .ge
    ld hl, (vidStrmRemainLo)
    ld de, 512
    or a
    sbc hl, de
    ret
.ge:
    or a
    ret

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

; Streaming cluster cells (page-local; the ARMED streaming session
; runs on the hot twins staged by .strm_loaded, not on these).
vidHandle:         db $FF
vidSizeLo:         dw 0
vidSizeHi:         dw 0
vidReadPage:       db 0
vidCardFlags:      db 0
vidMfSave:         db 0
vidStrmWinOpen:    db 0
vidReadCountSaved: dw 0
vidStrmNeed:       dw 0
vidStrmDest:       dw 0
vidStrmEntryPtr:   dw 0
vidStrmEntryEnd:   dw 0
vidStrmRunAddrLo:  dw 0
vidStrmRunAddrHi:  dw 0
vidStrmRunBlocks:  dw 0
vidStrmRemainLo:   dw 0
vidStrmRemainHi:   dw 0
vidStrmBlkPos:     dw 0
vidStrmBlkLen:     dw 0
vidFilemapBuf:     ds VID_FILEMAP_ENT*6
vidStrmBlkBuf:     ds 512

 IFDEF DEBUG
; ---------------------------------------------------------------------
; DEBUG timeline report (carried mechanism: the VID_PAGE block is
; LDIR-copied across the page hop into the page-local mirror BEFORE
; any print - the copy-across contract, rubric 3). v2 rows: the five
; frame-loop phases; the OTHER row carries TOT/FRM/ERR/OP/POS/PASS and
; the RING row carries the ring triple + FILL (the resident ring load's
; 50Hz-frame count). FRM prints as live/mirror - the Card #5 trap, see
; vid_tl_frames_live; FILL moved to the RING row in the same change
; because the pair pushed the OTHER row past 80 columns.
; ---------------------------------------------------------------------
VID_TL_ROW0 equ 24

vid_tl_print32:
    push hl
    inc hl
    inc hl
    ld e, (hl)
    inc hl
    ld d, (hl)
    ex de, hl
    call dbg_hex16               ; high word
    pop hl
    ld e, (hl)
    inc hl
    ld d, (hl)
    ex de, hl
    jp dbg_hex16                 ; low word, tail call

vid_tl_report_body:
    ; clear Layer 2 over the report rows (carried v1 fix: stale video
    ; pixels would otherwise show through the tilemap's transparency)
    ld e, NR_DISPLAY_CTRL
    call nr_read
    and %01111111
    nextreg NR_DISPLAY_CTRL, a
    ; copy the hot instrument block across (rubric 3)
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
    jp nz, .nextrow              ; jp: the OTHER-row tail outgrew jr
    ld hl, msgTlTot
    call dbg_puts
    ld hl, (vidTlTicksL)
    call dbg_hex16
    ld hl, msgTlFrm              ; FRM=live/mirror (SP15 Card #5 TRAP)
    call dbg_puts                ; - see vid_tl_frames_live's own banner
    call vid_tl_frames_live      ; a SECOND, independent read of the hot
    call dbg_hex16               ; cell, taken after the mirror LDIR
    ld hl, msgTlSlash
    call dbg_puts
    ld hl, (vidTlFramesL)
    call dbg_hex16
    ld hl, msgTlErr
    call dbg_puts
    ld a, (vidErrCodeL)
    call dbg_hex8
    ld hl, msgTlOp
    call dbg_puts
    ld a, (vidErrOpL)
    call dbg_hex8
    ld hl, msgTlPos              ; breadcrumb: failing source offset
    call dbg_puts                ; (24-bit hex; meaningful iff ERR!=0)
    ld a, (vidErrPosL+2)
    call dbg_hex8
    ld hl, (vidErrPosL)
    call dbg_hex16
    ld hl, msgTlPass             ; LIVE loop pass, printed 1-based on
    call dbg_puts                ; every exit (clean or error); 01 on a
    ld a, (vidLoopPassL)         ; play-once run, mod 256 on a long soak
    inc a
    call dbg_hex8
    ; RING row (3b): min frame-top ring depth / gate underrun events
    ; (streaming; a resident run prints 0000/0000 - staged so). FILL=
    ; moved here from the OTHER row (Card #5): the FRM=live/mirror trap
    ; pair pushed that row to 81 of the 80 tilemap columns.
    ld b, VID_TL_ROW0+5
    ld c, 0
    call dbg_at
    ld hl, msgTlRing
    call dbg_puts
    ld hl, (vidRingMinL)
    call dbg_hex16
    ld hl, msgTlSlash
    call dbg_puts
    ld hl, (vidRingUnderL)
    call dbg_hex16
    ld hl, msgTlSlash
    call dbg_puts
    ld a, (vidDepthClipL)            ; depth-floor clamps (3c) - MUST
    call dbg_hex8                    ; read 00 (see the cell comment)
    ld hl, msgTlFill
    call dbg_puts
    ld hl, (vidTlFillFramesL)
    call dbg_hex16
    ld hl, msgTlSnap             ; SNAP= reserved snapshot bank count
    call dbg_puts                ; (SP15: 00 hidden-L2 / 03 / 05; row
    ld a, (vidSnapCntL)          ; is 38 of 80 columns with it)
    call dbg_hex8
    jr .done
.nextrow:
    ld hl, vidTlRptRow
    inc (hl)
    ld hl, vidTlRptIdx
    inc (hl)
    jp .rowloop                  ; jr range: the OTHER-row tail grew
                                 ; past -128 with the POS=/PASS= print
.done:
    ld hl, vid_tl_report_ret
    push hl
    ld a, VID_PAGE
    jp ovl_map_page

; FRM=live/mirror TRAP (SP15 Card #5, item 3). The intermittent
; FRM=0000 row (3 occurrences in ~13 runs across VLOP0/vply3/vply4;
; every re-run reads correctly, playback and every other field sane -
; owner-assessed as transcription, kept instrumented rather than
; investigated) has two candidate sides: the hot cell itself, or the
; report path (the mirror LDIR / its layout). This routine re-reads
; vidTlFrames STRAIGHT from the hot page, in its own MMU6 bracket,
; AFTER the block LDIR has already snapshotted it - so the next
; occurrence localizes the fault by inspection:
;   FRM=xxxx/xxxx (equal, nonzero) - normal.
;   FRM=xxxx/0000 - the MIRROR side is wrong: the LDIR or the mirror
;                   layout dropped it (the hot counter was fine).
;   FRM=0000/xxxx - the LIVE cell was zeroed BETWEEN the LDIR and this
;                   read, i.e. something is still writing post-park.
;   FRM=0000/0000 - the counter was already zero when the report ran:
;                   the fault is upstream of the report path entirely
;                   (stamp path or an early zero), not in the mirror.
; Out: HL = live vidTlFrames. Corrupts AF; preserves DE (data_save's
; own contract).
vid_tl_frames_live:
    call data_save
    ld a, VID_PAGE
    call data_map_page
    ld hl, (vidTlFrames + DATA_WINDOW - OVL_ORG)
    push hl
    call data_restore
    pop hl
    ret

vidTlMsgTab:
    dw msgTl0, msgTl1, msgTl2, msgTl3, msgTl4
msgTl0: db "PACE   =", 0
msgTl1: db "AUDIO  =", 0
msgTl2: db "DECODE =", 0
msgTl3: db "FLIP   =", 0
msgTl4: db "OTHER  =", 0
msgTlTot:  db " TOT=", 0
msgTlFrm:  db " FRM=", 0
msgTlErr:  db " ERR=", 0
msgTlOp:   db " OP=", 0
msgTlPos:  db " POS=", 0
msgTlPass: db " PASS=", 0
msgTlFill: db " FILL=", 0
msgTlRing: db "RING   =", 0
msgTlSlash: db "/", 0
msgTlSnap: db " SNAP=", 0
vidTlRptRow: db 0
vidTlRptIdx: db 0
vidSnapCntL: db 0                ; SNAP= mirror - written at open (the
                                 ; live vidSnapCnt is zeroed by the
                                 ; teardown free before the report)

; Page-local mirror of the hot instrument block (same order/sizes -
; one LDIR; the length is computed so it can never drift).
vidTlTicksL:      dw 0
vidTlLastTickL:   dw 0
vidTlLastPhaseL:  db 0
vidTlFramesL:     dw 0
vidTlAccL:        ds VID_TL_PHASES*4
vidErrCodeL:      db 0
vidErrOpL:        db 0
vidErrPosL:       ds 3
vidLoopPassL:     db 0
vidRingMinL:      dw 0
vidRingUnderL:    dw 0
vidDepthClipL:    db 0
vidTlFillFramesL: dw 0
    ASSERT vidTlFillFramesL + 2 - vidTlTicksL == VID_TL_BLOCK_LEN
 ENDIF

    DISPLAY "video2 ends at ", $, " headroom ", /D, OVL_LIMIT - $
    ASSERT $ <= OVL_LIMIT
