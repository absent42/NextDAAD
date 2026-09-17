; NextDAAD video: NXV v2 delta-video player (resident load + ring
; streaming + direct-serve/column-hop). v1 player deleted, git holds it.
;
; PAGE LAYOUT:
;   VID_PAGE (59, MMU7, $E000-OVL_LIMIT) - HOT: everything that runs while
;     the video CTC ISR is armed (dispatch, decode/op handlers, DMA/chunk
;     bodies, PAL/KSTART/KFLIP/FEND handlers, frame loop + pacing, audio
;     CTC ISRs, streaming/direct-serve clusters, hot session/filemap
;     cells - audio buffer NOT here, see RULE 4).
;   VID_PAGE2 (70, $E000-$F7FF) - COLD (pre-arm/post-disarm only):
;     nxv2_open_body, entry/l2setup/restore body, L2 snapshot + esxDOS
;     open clusters, cold SD streaming (pre-arm only - the armed session
;     runs on the hot clones), DEBUG failure/timeline.
;
; RULES:
;   1. MMU7 = VID_PAGE for the whole window the CTC ISR can fire (from
;      vid_run's time-constant write to the CTC reset in .restore); every
;      cross-page hop happens strictly pre-arm or post-disarm.
;   2. MMU2 ($4000-$5FFF) is the decode loop's borrowed L2 dest window;
;      both sample DAC channels are aborted first, so their ISRs stay
;      silent for the session.
;   3. While streaming/direct-serve is armed the CMD18 window may stay
;      open across frames; Multiface is disabled per window, not session
;      (an NMI in a re-enabled gap always hits a closed window).
;   4. MMU3 ($6000-$7FFF) is the session's borrowed audio window (the
;      circular feed ring, whole 8KB pool bank), safe as RULE 2 - only
;      the CPU mapping is borrowed, bank 5's content untouched.
; Format: nextdaad.inc's NXV2_* block is the player-side transcription;
; authoring-kit/lib/nxv2dec.py is the executable spec.
; DECODER CONTRACTS: (1) dispatch masks the fetched byte with AND $C3,
; rejects nonzero (VID_ERR_OP) - only offsets $00-$3C (multiples of 4)
; reach the stub block. (2) early-FEND tail: the decoder only writes
; what ops write, so an early FEND leaves the untouched tail as-is.
; (3) DMA chunks <= NXV2_DMA_CHUNK (240B), capped before a DMA kernel
; sees them. CORRUPT-INPUT DIVERGENCE: a RUN8/COPY8 with n=0 is a silent
; no-op here (structural zero-count guards) where nxv2dec raises -
; reachable only on corrupt input; contract is abort-or-no-op, never
; UB. KSTART does no visible->hidden inherit copy - keyframe spans are
; encoder-guaranteed full repaints, so none is needed.

    MMU 7, VID_PAGE, OVL_ORG

; ---------------------------------------------------------------------
; Dispatch stub block - 64 bytes at the page base ($E000, 256-aligned
; so IYL = opcode byte addresses it; doc 07 taken to its floor: zero
; multiply, zero table walk). Slots $08/$10/$1C (RUN8/COPY8/SKIP8) are
; SMC-patched per file by nxv2_open_body: flat fast handlers for
; mode-0 / mode-1 native-height files, gapped fast handlers (column-
; room checks) for mode-1 letterbox files. Contract 1's AND $C3 mask
; in the dispatch guarantees only offsets $00-$3C (multiples of 4)
; ever land here; $24/$30 (the retired T5a OCOPY8/OCOPY16 - a file
; that declares them is refused at OPEN, see NXV2_FLAG_OCOPY),
; $2C (SCROLL, kept for T5b) and $34-$3C are error stubs.
; Rubric 8: alignment + size asserted below.
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
    jp vid_op_bad                ; $24 reserved (retired T5a OCOPY8)
    nop
    jp vid_op_kstart             ; $28 KSTART
    nop
    jp vid_op_bad                ; $2C SCROLL (reserved, errors)
    nop
    jp vid_op_bad                ; $30 reserved (retired T5a OCOPY16)
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
; (graduated NXBEN nxb_fill_unrolled - unrolled store block, pass count
; by SWAPNIB). In: A = colour, DE = dest, C = chunk (0..240, B ignored).
; Out: DE += chunk; AF, BC and IYL corrupt. Preserves HL (src).
; The entry jumps through IY (IYH = high vid_stub).
; ---------------------------------------------------------------------
vid_fill_cpu:                    ; A colour, DE dest, C chunk 0..240 (B ignored)
    push hl                      ; src
    ex de, hl                    ; HL = dest
    ld e, a                      ; E = colour
    ld a, c
    neg
    and 15
    add a, a
    add a, low vid_fill_blk
    ld iyl, a                    ; computed entry (vid_copy_ldi's shape)
    ld a, c
    add a, 15
    swapnib
    and 15                       ; A = passes = (C+15)>>4, Z if 0
    ld b, a
    jr z, vid_fill_done          ; structural: zero chunk is a no-op
    jp (iy)
    ALIGN 64
vid_fill_blk:
    DUP 16
      ld (hl), e
      inc hl
    EDUP
    djnz vid_fill_blk
vid_fill_done:                   ; global: the ALIGNed block label
    ex de, hl                    ; above rescopes dot-locals
    pop hl                       ; src
    ret
    ASSERT (low vid_fill_blk) <= 256-40
    ASSERT (high vid_fill_blk) == (high vid_stub)
    ASSERT NXV2_DMA_CHUNK <= 240 && NXV2_RUN_DMA_MIN <= 241

; ---------------------------------------------------------------------
; COPY kernel, CPU: computed-entry unrolled LDI (graduated NXBEN
; nxb_copy_ldi - doc 04; rubric 2: LDI's own BC countdown is the only
; counter). In: HL = src, DE = dest, BC = chunk (both windows valid).
; Out: HL/DE advanced, BC = 0; corrupts AF, IYL. 20.25 T/B body
; (settlement C8/C16 joint solve). Zero-count guarded.
; ---------------------------------------------------------------------
vid_copy_ldi:
    ld a, b
    or c
    ret z                        ; zero count: structural no-op
    ld a, c
    neg
    and 15                       ; (16 - r) & 15: r = 0 -> 0 -> full block
    add a, a                     ; entry = blk + 2 * (16 - r): r = 1 lands
    add a, low vid_ldi_blk       ; on the 16th LDI, r = 15 on the 2nd
    ld iyl, a
    jp (iy)                      ; IYH = high vid_stub = high vid_ldi_blk
    ALIGN 64
vid_ldi_blk:
    DUP 16
      ldi
    EDUP
    jp pe, vid_ldi_blk           ; P/V set = BC != 0
    ret
    ASSERT (low vid_ldi_blk) <= 256-36
    ASSERT (high vid_ldi_blk) == (high vid_stub)

; HL = cold body. Push it, hop to VID_PAGE2 (the body returns there).
vid_hop2:
    push hl
    ld a, VID_PAGE2
    jp ovl_map_page

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
.rthr equ $+1                    ; DEBUG writer: nxb_sel_set
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
.thr equ $+1                     ; DEBUG writer: nxb_sel_set
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
    ; opcode at $DFxx: if fewer than NXV2_MAX_OPERANDS (4) operand
    ; bytes remain in the window ($DFFC-$DFFF), take the byte-fetch
    ; slow path; otherwise the fast fetch is safe for every op HEADER
    ; (the live set carries at most 3; the bound is held at the
    ; conservative 4 - counted bodies re-check their own rooms).
    ld a, l
    cp $100 - NXV2_MAX_OPERANDS
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
                                 ; routine is three shipping-value stores
                                 ; and a no-op unless a standalone
                                 ; bench row is live.
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
    ld a, c
.rthr equ $+1                    ; DEBUG writer: nxb_sel_set
    cp NXV2_RUN_DMA_MIN
    jr nc, .slow                 ; at/over the crossover: the body, which
                                 ; selects the kernel per chunk
    ld a, e
    add a, c
    jr c, .slow
.hcmp:
    cp 0                         ; SMC: content height
    jr c, .in
    jr z, .in
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
    ld a, c
.thr equ $+1                     ; DEBUG writer: nxb_sel_set
    cp NXV2_COPY_DMA_MIN
    jr nc, .slow                 ; at/over the crossover: the body
    ld a, e
    add a, c
    jr c, .slow
.hcmp:
    cp 0                         ; SMC: content height
    jr c, .in
    jr z, .in
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
; the derived crossovers (RUN >= NXV2_RUN_DMA_MIN 71B and COPY >=
; NXV2_COPY_DMA_MIN 53B go DMA, chunks <= NXV2_DMA_CHUNK 240B, run
; unbracketed - see the zxnDMA kernel header).
; ---------------------------------------------------------------------
vid_skip_body:
    ld (vidRemain), bc
.seg:
    ld bc, (vidRemain)
    ld a, b
    or c
.next:
    jp z, vid_next               ; SMC: vid_ds_next when direct (3c)
    ; per-session SMC: _flat or _gap, the geometry test hoisted out of
    ; the chunk loop (patched by vid_stage_common / nxb_geo_setup)
.dn:
    call vid_dst_norm_flat
.cd:
    call vid_chunk_dst_nocap_flat ; BC = min(remain, dest/col room) -
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
.dn:
    call vid_dst_norm_flat       ; per-session SMC: _flat or _gap
.cd:
    call vid_chunk_dst_flat      ; BC = chunk (rooms + the DMA cap)
    push hl
    ld hl, (vidRemain)
    or a
    sbc hl, bc
    ld (vidRemain), hl
    pop hl
    ; kernel select (derived crossover, nextdaad.inc): >= 71 -> DMA
    ; fill. B is 0 by vid_chunk_dst_*'s post-condition (cap <= 255).
    ld a, c
.rthr equ $+1                    ; DEBUG writer: nxb_sel_set
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
.dn:
    call vid_dst_norm_flat       ; per-session SMC: _flat or _gap
    call vid_chunk_all           ; BC = chunk (src+dest rooms + cap)
    push hl
    ld hl, (vidRemain)
    or a
    sbc hl, bc
    ld (vidRemain), hl
    pop hl
    ld a, c                      ; B is 0 by vid_chunk_all's post-
                                 ; condition (cap <= 255)
.thr equ $+1                     ; DEBUG writer: nxb_sel_set
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
; means "column finished, hop deferred to the next normalize"; a chunk
; therefore never crosses a column boundary or the window seam - this
; lands both, the sizer below clips to whichever room is left.
; Per-session SMC pair: the geometry test and the height read are
; hoisted out of the chunk loop, every caller's call operand patched
; to one entry at open. The Z80N has no I-cache, so a patched operand
; is seen on the next fetch.
; The DEBUG raster arm is INLINE in BOTH entries - a shared helper
; would add a call/ret to every chunk in exactly the builds the
; per-chunk timings are measured on.
; ---------------------------------------------------------------------
vid_dst_norm_gap:
 IFDEF DEBUG
  IFNDEF NXB_QUIET
    ; PLAY= raster clock (see vid_rl_poll). Decode has no wait loop in
    ; it, so the clock has to be read from inside it or a long decode
    ; outlives a field and the wrap is missed. Divided by VID_RL_DIV:
    ; one call per CHUNK, and every RAM kernel caps a chunk at
    ; NXV2_DMA_CHUNK (240 B), so 16 of them is under ~1.7 ms - the
    ; poll-gap table in vid_rl_poll carries the bound for every site,
    ; this one included.
    ld a, (vidRlDiv)
    dec a
    ld (vidRlDiv), a
    call z, vid_rl_poll
  ENDIF
 ENDIF
.h1:
    ld a, 0                      ; SMC: content height (1-255)
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

vid_dst_norm_flat:
 IFDEF DEBUG
  IFNDEF NXB_QUIET
    ld a, (vidRlDiv)             ; PLAY= clock: the same arm and the
    dec a                        ; same VID_RL_DIV cadence as the
    ld (vidRlDiv), a             ; gapped entry - exactly one entry is
    call z, vid_rl_poll          ; live per session, so still per chunk
  ENDIF
 ENDIF
    ld a, d
    cp $60
    ret c
    jp vid_dst_next              ; maps the next surface page, D -= $20

 IFDEF DEBUG
; ---------------------------------------------------------------------
; PLAY= WALL-CLOCK INSTRUMENT (DEBUG only). Ticks elsewhere in the
; timeline (vidTlTicks) count video-CTC ISR firings and go blind when a
; DI bracket swallows one; PLAY instead counts field wraps off the
; free-running raster counter NR_RASTER_MSB/LSB (no interrupt in its
; path, so no DI bracket can lose a count). frameCounter is not usable
; here - im2_isr increments it and shares the same blind spot.
;
; Resolution is one field (20ms); the count is 16-bit, so PLAY wraps
; after 65536 fields (21.8 min).
;
; Poll density is the whole contract: a wrap is inferred from the raster
; value decreasing, so two field boundaries between polls under-count by
; one. Poll intervals, all bounded well under one field:
;   vid_pace_poll   every VID_RL_DIV = 16 wait-loop passes    ~6.4 ms
;   vid_dst_norm_*  every VID_RL_DIV = 16 decode chunks       ~1.7 ms
;   vid_ds_blkopen  one blkopen per 512B on the direct-serve wire ~5.6 ms
;   vid_aud_pump    every VID_RL_DIV = 16 feed chunks          ~2.6 ms
; The pump poll also bounds the one-pass audio feed at
; <= NXV_AUD_FRAME_MAX (the ring is the whole 8KB bank, so every legal
; feed completes in one pass).
;
; Out: nothing. Preserves BC, DE, HL, IX. Corrupts AF only.
; ---------------------------------------------------------------------
vid_rl_poll:
    push bc
    push de
    push hl
    ld a, VID_RL_DIV
    ld (vidRlDiv), a
    ld (vidRlSpinDiv), a         ; Phase 2-POLL: SPIN divider shares
                                 ; this reset, same pattern as vidRlDiv
                                 ; (decode/ds pair) - see vidRlSpinDiv
    ld bc, TBBLUE_REG_SEL
    di                           ; the select/read pair must not be
                                 ; split by an ISR that selects its own
                                 ; register (nr_read's own rule); this
                                 ; bracket is ~30 T, far below the DMA
                                 ; brackets already in the frame
.sample:
    ld a, NR_RASTER_MSB
    out (c), a
    inc b                        ; TBBLUE_REG_ACC (low byte is shared)
    in a, (c)
    and 1
    ld h, a
    dec b
    ld a, NR_RASTER_LSB
    out (c), a
    inc b
    in a, (c)
    ld l, a                      ; HL = 9-bit raster line
    dec b
    ld a, NR_RASTER_MSB
    out (c), a
    inc b
    in a, (c)
    and 1
    cp h
    jr nz, .sample               ; the line crossed 256 mid-read - the
                                 ; MSB/LSB pair would be inconsistent
                                 ; and could fake or hide a wrap
    ei
    ld de, (vidRlLast)
    ld (vidRlLast), hl
    or a
    sbc hl, de
    jr nc, .out                  ; line advanced (or stood still)
    ld hl, (vidRlFields)         ; went DOWN = one more field elapsed
    inc hl
    ld (vidRlFields), hl
.out:
    pop hl
    pop de
    pop bc
    ret

; PLAY=/NOM= per-DELIVERED-FRAME hook, called from the TOP of the frame
; loop - so it counts every frame the player delivers, keyframe-span
; HOLD frames included, because a held frame occupies its frame period
; exactly like a presented one. That is the whole of the NOM fix: the
; first cut accumulated per PRESENTED frame while PLAY bracketed real
; time INCLUDING the holds, so NOM under-read by however much a clip
; held (row 059: NOM 0x194 = 404 against a true 500 - it holds 48 of
; its 250 frames) and the ratio meant nothing. NOM is now exactly
; FRM x (50/fps), and the PLAY bracket runs from this same first frame
; to teardown, i.e. over the SAME FRM frame periods - so PLAY/NOM is
; the rate ratio directly, whatever a clip holds.
; Open, load and ring prefill stay outside the bracket (they run before
; the loop) - the owner's requirement: time the playback, not the
; launch. Residuals: a key exit truncates the last frame's period, and
; NOM counts 50 Hz fields while the machine timing sets the real rate -
; 49.36 Hz on the default +3 timing (NOM ~1.3% long), 50.08 Hz on 48K.
; Corrupts AF, BC, DE, HL.
vid_play_frame:
    ld hl, (vidTlFrames)         ; FRM=. Counted HERE since v0.5.0 - it
    inc hl                       ; used to ride on vid_tl_stamp's PACE
    ld (vidTlFrames), hl         ; transition, and this routine is called
                                 ; from that same site, once per frame,
                                 ; so the count is unchanged. It has to
                                 ; stay live: PLAY/NOM is a rate ratio
                                 ; over exactly these FRM frame periods.
    ld hl, (vidNomStep)          ; 8.8 fixed fields/frame, staged at open
    ld de, (vidNomAcc)
    add hl, de
    ld (vidNomAcc), hl
    ld a, (vidNomAcc+2)
    adc a, 0
    ld (vidNomAcc+2), a
    ld a, (vidPlayArmed)
    or a
    ret nz
    inc a
    ld (vidPlayArmed), a
    call vid_rl_poll             ; frame 0's period starts HERE
    ld hl, (vidRlFields)
    ld (vidPlayStart), hl
    ret

; PLAY= bracket close: the last delivered frame's period has just
; ended. Every exit - drain-tail release, key press, decode abort -
; lands at .restore, and this runs there before the CTC is parked.
; Corrupts AF, BC, DE, HL.
vid_play_close:
    call vid_rl_poll
    ld hl, (vidRlFields)
    ld (vidPlayEnd), hl
    ret
 ENDIF

; ---------------------------------------------------------------------
; Chunk sizing. In: HL = src, DE = dest (normalized), BC = remaining.
; Out: BC = chunk >= 1. Preserves HL, DE. Corrupts AF (+ stack temp).
; The geometry select and the gapped height are per-session SMC (the
; _flat/_gap pairs below), so the chunk loop pays neither. The DMA
; transfer size cap itself is UNTOUCHED - NXV2_DMA_CHUNK still bounds
; every kernel-visible chunk, so the interval a DMA runs for, and the
; frame ISR's hold-off with it, is exactly as it was.
; NXV2_DMA_CHUNK is 240 - a single-byte cap - so the
; test is a plain "> cap" and the post-condition is B == 0 ALWAYS on
; every capped exit, which is what lets vid_run_body's and
; vid_copy_body's kernel selects drop their high-byte test.
    ASSERT NXV2_DMA_CHUNK <= 255
; ---------------------------------------------------------------------
; COPY: dest room + cap first, then the src window room - min() is
; commutative, so BC is identical to the old src-first order. After
; the dest step B == 0 and BC <= 240, so H <= $DE means src room
; >= $E000-$DEFF = 257 > BC and nothing can bind; $DFxx takes the
; exact routine, which also serves vid_op_pal.straddle uncapped.
    ASSERT $E000 - $DEFF > NXV2_DMA_CHUNK
vid_chunk_all:
.dj:
    call vid_chunk_dst_flat      ; per-session SMC: _flat or _gap
    ld a, h
    cp $DF
    ret c
    jp vid_chunk_src

; RUN/COPY dest step: dest room + the DMA cap (contract 3).
    ASSERT $6000 - $5EFF > NXV2_DMA_CHUNK && $6000 - $5EFF > 255
vid_chunk_dst_flat:
    ld a, d
    cp $5F
    jr nc, .exact
    ; D <= $5E: window room >= $6000-$5EFF = 257, over both 255 and
    ; the cap, so only the cap can bind (same test as vf_op_copy8)
    ld a, b
    or a
    jr nz, .cap                  ; >= 256
    ld a, c
    cp NXV2_DMA_CHUNK+1
    ret c                        ; <= cap: keep BC
.cap:
    ld bc, NXV2_DMA_CHUNK
    ret
.exact:
    call vid_chunk_dst_nocap_flat
    ld a, b
    or a
    jr nz, .clip                 ; >= 256
    ld a, c
    cp NXV2_DMA_CHUNK+1
    ret c                        ; <= cap: keep BC
.clip:
    ld bc, NXV2_DMA_CHUNK
    ret

vid_chunk_dst_gap:
.h1:
    ld a, 0                      ; SMC: content height (1-255)
    sub e                        ; A = column room (1..255; normalized)
    inc b
    dec b                        ; Z = (B == 0), A preserved
    jr nz, .takea                ; BC >= 256 > room: take the room
    cp c
    jr nc, .cap                  ; room >= count: keep BC
.takea:
    ld c, a
    ld b, 0
.cap:
    ld a, c                      ; B is 0 on every arm above
    cp NXV2_DMA_CHUNK+1
    ret c                        ; <= cap: keep BC
    ld bc, NXV2_DMA_CHUNK
    ret

; SKIP and direct-serve COPY: dest room only - column room when
; gapped, window room when flat - and no DMA cap (neither path arms a
; DMA; the direct transport holds no bracket of any kind).
vid_chunk_dst_nocap_gap:
.h1:
    ld a, 0                      ; SMC: content height (1-255)
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

vid_chunk_dst_nocap_flat:
    push hl
    ld hl, $6000
    or a
    sbc hl, de                   ; HL = window room (1..$2000), CF clear
    sbc hl, bc                   ; room - count
    jr nc, .keep                 ; room >= count: keep BC
    add hl, bc                   ; HL = room
    ld b, h
    ld c, l
.keep:
    pop hl
    ret

; PAL/COPY tail: BC = min(BC, src window room). Preserves HL, DE.
; EXACT and standalone - vid_op_pal.straddle calls it with BC = 512
; and no cap ahead of it, so the high-byte arm in vid_chunk_all (which
; is only sound behind that cap) must never be folded in here.
vid_chunk_src:
    push hl
    push de
    ex de, hl                    ; DE = src
    ld hl, $E000
    or a
    sbc hl, de                   ; HL = src room (1..$2000), CF clear
    sbc hl, bc                   ; room - count
    jr nc, .keep
    add hl, bc                   ; HL = room
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
    res 5, h                     ; H = $E0 at every seam -> $C0
    pop bc
    ret
.ovr:
    ld a, VID_ERR_SRCOVR
    jp vid_dec_abort             ; SP anchor absorbs the pushed BC

; Advance to the next dest surface page (bounds-checked). Preserves
; BC, HL; corrupts AF; DE rebased by -$2000.
vid_dst_next:
    push bc
    ld a, (vidDstEnd)
    ld c, a
    ld a, (vidDstPage)
    inc a
    ld (vidDstPage), a
    cp c
    jr nc, .ovr                  ; page >= end: past the surface
    nextreg NR_MMU2, a
    res 5, d                     ; D = $60 at every seam -> $40
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
; src room. Safe without DI: the frame hook is suspended for the session
; (vid_run's arm point) so the 50Hz ISR runs its AF/HL-only fast path, and
; the video CTC ISR is AF/IX/DAC only - nothing else touches the $243B pair
; or NR $44.
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
    call vid_dst_base            ; hidden surface, cursor 0 (KSTART's
                                 ; own effect)
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
    jr vid_term_exit
.stray:
    ld a, VID_ERR_OP
    jp vid_dec_abort

; FEND: frame end - terminal. Mid-span hold frames spill the dest
; cursor so the span CONTINUES across the chunk-frame boundary
; (nxv2dec's span_cursor rule); nothing here writes the surface (contract 2).
vid_op_fend:
    ld a, (vidInSpan)
    or a
    jr z, .plain
    ld a, (vidDstPage)
    ld (vidSpanDstPage), a
    ld (vidSpanDE), de
.plain:
    ld a, VOP_FEND
vid_term_exit:
    jp vid_dec_done              ; SMC: vid_ds_done when direct
; Shared terminal tail: advance vidFramePos past this frame's payload
; (consumed bytes rounded up to the 512-byte block - valid absolute
; rounding because every frame section is block-aligned), bounds-check
; against the file end, return A = terminal op to the frame loop.
; CEILING LIFT: the FILE unit is the 512-byte BLOCK. The
; bound check and vidFileEnd count blocks, so the same 3-byte cells
; address 8 GB instead of the 16 MB the old 24-bit BYTE quantities
; reached. vidFramePos keeps BYTE granularity on the RESIDENT path
; only - there it addresses the RAM image and vid_aud_pump advances it
; by arbitrary chunk counts; the streaming cursor counts blocks.
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
    ; RESIDENT: B:HL is the file position in BYTES and is stored that
    ; way; the bound runs in the file unit. pos is block-aligned here,
    ; so pos >> 9 is exact and the comparison is the byte one verbatim.
    ld (vidFramePos), hl
    ld a, b
    ld (vidFramePos+2), a
    ld l, h
    ld h, b
    srl h
    rr l
    ld b, 0                      ; B:HL = pos >> 9 (resident is ring-
                                 ; bounded: B is always 0 here)
.bound:
    call vid_bound_chk           ; CF set = past the file end
    jr c, .ovr
    pop af                       ; A = terminal op
    ret                          ; -> vid_decode_frame's caller
.ovr:
    pop af
 IFDEF DEBUG
    ld (vidErrPos), hl           ; breadcrumb: the already-rounded
    ld a, b                      ; BLOCK position this bound trip
    ld (vidErrPos+2), a          ; rejected (the file unit; the
 ENDIF                           ; vid_dec_abort breadcrumb stays a
                                 ; byte cursor)
    ld a, VID_ERR_SRCOVR
    jp vid_dec_abort_pos

; File-position bound in the file unit (512-byte BLOCKS). In: B:HL =
; candidate file position, blocks. Out: CF set = past vidFileEnd (the
; SRCOVR trip); CF clear = at or inside the end (== on the last
; frame). Corrupts AF, DE. Preserves B and HL.
vid_bound_chk:
    ld a, (vidFileEnd+2)
    cp b
    ret c                        ; endHi < posHi: over
    jr nz, .in                   ; endHi > posHi: inside
    ld de, (vidFileEnd)
    push hl
    or a
    sbc hl, de
    pop hl
    ret z                        ; exactly the end: the last frame
    ccf                          ; pos < end -> CF clear (inside);
    ret                          ; pos > end -> CF set (over)
.in:
    or a
    ret

; Streaming terminal tail: B:HL = the rounded-up RING-linear position
; the payload ended at (<= ringBytes: the round-up may land exactly on
; the wrap point - the mod folds it to 0). Derives the consumed byte
; count (mod ringBytes, valid because rlStart is block-aligned and one
; payload is far smaller than the ring), advances the ring cursor and
; the depth gauge, then hands the FILE-relative candidate position -
; in BLOCKS, the file unit since the ceiling lift - to vid_dec_done's
; shared bound check (the terminal op stays pushed).
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
    ld b, a                      ; blocks = consumed >> 9 = (A:H) >> 1
    ld a, h
    srl b
    rra
    ld c, a                      ; BC = consumed blocks
    call vid_depth_debit         ; depth -= consumed, floored (DEPTH
                                 ; FLOOR, 3c hardening; DEBUG counts a
                                 ; clamp on the RING row)
    ; the STREAMING file cursor counts BLOCKS (no byte cursor exists
    ; here - vid_src_seek reads vidRingRl): framePos += consumed
    ; blocks, then the shared bound check (B:HL candidate).
    ld hl, (vidFramePos)
    add hl, bc
    ld a, (vidFramePos+2)
    adc a, 0
    ld b, a
    ld (vidFramePos), hl
    ld (vidFramePos+2), a
    jp vid_dec_done.bound

; BC = blocks. vidRingDepth -= BC, floored at 0 (DEBUG counts a clamp
; in vidDepthClip - a clamp is a bookkeeping bug). Corrupts AF, HL.
vid_depth_debit:
    ld hl, (vidRingDepth)
    or a
    sbc hl, bc
    jr nc, .ok
 IFDEF DEBUG
    ld a, (vidDepthClip)
    inc a
    ld (vidDepthClip), a
 ENDIF
    ld hl, 0
.ok:
    ld (vidRingDepth), hl
    ret

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
    rla                          ; A = carry
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
; 11's one-shot law minus its DI clause: CONTINUOUS one-shots,
; programmed once, run to completion, the $87 enable is the last
; byte. The DI-bracket clause is SUPERSEDED - interrupts are live and
; the governing contract is the INTERRUPTS ARE LIVE THROUGHOUT block
; below: the CPU normally stalls at the enable until the transfer
; ends, but a yield can run tail instructions mid-transfer, so "the
; upload returns only when the transfer is done" is no longer
; absolute; chunks <= NXV2_DMA_CHUNK - contract 3). WR2 (port
; B memory/increment/timing) + WR5 (stop on end) + WR1 (port A
; INCREMENTING/timing) are programmed once per session (vidDmaInit,
; sent by vid_run_l2setup_body; nxbDmaInit is the bench's twin).
;
; DESCRIPTOR SPLIT: WR1 (port A mode - FIXED for fill, INCREMENTING for
; copy - sets D6, obliging its timing byte, a 2-byte pair) lives in the
; session init as INCREMENTING; the copy arm no longer carries it.
; vid_fill_dma sends WR1 = FIXED inside its own arm and re-sends
; INCREMENTING after the arm train, so the DMA is idle (a register
; write, not a transfer) by the time the CPU reaches restore.
; Behaviour-neutral by construction: no state cell, no runtime test.
; vidSnapDmaArm and overlay2's dma_copy both leave WR1 = INCREMENTING
; and re-send their own pair in their per-CALL prefix, so neither can
; break the invariant.
;
; UPLOAD PRIMITIVE. The arm goes out with an unrolled OUTINB run
; (Z80N ED 90, out (BC),(HL); HL++, B untouched) instead of OTIR -
; the shape vid_op_pal already uses on NR $44. At 28 MHz (doc 01: +1
; wait on every opcode fetch and every memory read, none on I/O) OTIR
; is 24 T/byte repeating and 19 T final; OUTINB is a flat 19 T/byte.
; This is a DMA-CONTROLLER port ($6B), NOT an SD/SPI read train - the
; 16 T spacing floor that reverted vid_ds_pad (commit 01466ec, ERR=FD)
; governs PORT_SPI_DAT reads and has nothing to say here.
;
; INTERRUPTS ARE LIVE THROUGHOUT - arm and transfer (overlay2's dma_copy
; takes the same treatment). ctc_isr /
; video_ctc_isr_stereo are admitted mid-chunk by nextreg $CD bit 0 and
; service the DAC on time; the frame ISR is barred from a running DMA
; by $CC = 0 and a pending frame tick runs when the chunk ends. Both
; permitted ISRs are MMU-free, never touch port $6B, and exit via
; RETI (which is what hands the bus back to the DMA - dev guide
; interrupts chapter, Alvin Albrecht).
;
; THE ONE CONSEQUENCE TO KNOW ABOUT: when the DMA yields for an
; interrupt the CPU executes ONE mainline instruction before the
; interrupt is seen, and RETI returns the bus to the DMA. The copy
; tail (pop/pop/ret) is harmless at any depth. The fill tail reaches
; a DMA-port write (the WR1 restore otir) THREE instructions past its
; arm, so it would take three yields inside one bracket to touch the
; port mid-transfer - and the tightest CTC period the format can
; select (VGA0 stereo, 1792 T) admits at most two edges against a
; fill bracket of 1664 T (1745.6 T even at a 256 cap). Anything that
; shortens either tail, or moves a DMA write earlier, must be
; re-checked against that bound. tests/dma_contract.py pins the
; emitted shape (no F3/FB around the arm trains).
;
; ---------------------------------------------------------------------

; Arm lengths as assembly-time constants: the DUP counts below need
; them before the blocks exist. The ASSERTs after the blocks pin them
; to the real lengths, so an edit to either arm that forgets its
; unroll count fails the build instead of desyncing the DMA.
VID_CPARM_LEN   equ 11
VID_FIARM_LEN   equ 13

; RUN fill via DMA: port A FIXED at vidRunColour (this page - always
; mapped at MMU7 while armed), port B incrementing across the chunk.
; In: HL src (preserved), DE dest, BC chunk (71..NXV2_DMA_CHUNK). Out:
; DE += chunk. 5.1 T/B + 849T/chunk (settlement RD rows).
vid_fill_dma:
    ld (vidDmaFiArm.blen), bc
    ld (vidDmaFiArm.bdst), de
    ex de, hl
    add hl, bc
    ex de, hl                    ; DE += chunk (before BC dies)
    push hl
    ld hl, vidDmaFiArm
    ld bc, DMA_PORT              ; B is OUTINB's spare (address high
    DUP VID_FIARM_LEN            ; byte only; OTIR ran this port with
      outinb                     ; B = 12..0 already) - arm + run:
    EDUP                         ; continuous one-shot, interrupts LIVE
    ld hl, vidDmaWr1Inc          ; put port A back to INCREMENTING for
    ld b, 2                      ; the copy arm (descriptor split); the
    otir                         ; DMA is idle by the time the CPU gets
                                 ; here - three-yields bound, header
    pop hl
    ret

; COPY via DMA: mem-to-mem, source = MMU6 ring window, dest = MMU2
; surface window (both pinned across the transfer - the custodian is
; $CC = 0 barring the frame ISR from a running DMA plus the permitted
; ISRs' MMU-free contract, not a DI). In: HL src, DE dest, BC chunk
; (53..NXV2_DMA_CHUNK). Out: HL/DE advanced. 5.082 T/B + 1092T/chunk
; (settlement CD rows).
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
    ld bc, DMA_PORT
    DUP VID_CPARM_LEN
      outinb                     ; arm + run, interrupts LIVE (header)
    EDUP
    pop de
    pop hl
    ret

; Arm programs (zxndma.txt WR bit tables; overlay2.asm's dma_prog +
; dma_prog_static pair is the canonical full program these derive from,
; carrying the same descriptor split). WR1/WR2/WR5 persist from the
; session init (vidDmaInit, sent by vid_run_l2setup_body).
vidDmaFiArm:                     ; per-chunk fill arm (13 bytes)
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
    ASSERT vidDmaFiArm_len == VID_FIARM_LEN

; The WR1 pair the copy arm no longer carries: the session default
; (vidDmaInit / nxbDmaInit send it), and vid_fill_dma's restore.
vidDmaWr1Inc:
    db %01010100                 ; WR1: A memory, INCREMENTING, timing
    db %00000010                 ; A cycle length 2

vidDmaCpArm:                     ; per-chunk copy arm (11 bytes)
    db $83                       ; WR6: disable
    db %01111101                 ; WR0: A->B; A addr + length follow
.asrc:
    dw 0                         ; port A = source (patched)
.blen:
    dw 0                         ; block length, exact count (patched)
    db %10101101                 ; WR4: CONTINUOUS, port B addr follows
.bdst:
    dw 0                         ; port B = dest (patched)
    db $CF                       ; WR6: load
    db $87                       ; WR6: enable - LAST byte
vidDmaCpArm_len equ $ - vidDmaCpArm
    ASSERT vidDmaCpArm_len == VID_CPARM_LEN

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
    ld a, (l2BackBank)           ; continue the hidden-surface span:
    call vid_dst_base            ; End from the back bank ...
    ld a, (vidSpanDstPage)       ; ... cursor page from the spill
    ld (vidDstPage), a
    nextreg NR_MMU2, a
    ld de, (vidSpanDE)
    ret
.fresh:
    ld a, (l2FrontBank)          ; delta frames patch the VISIBLE
                                 ; surface in place, cursor 0
    ASSERT $ == vid_dst_base     ; falls into vid_dst_base

; A = 16K bank. Sets vidDstPage/vidDstEnd, maps MMU2, DE = cursor 0.
; Corrupts AF, C.
vid_dst_base:
    add a, a
    ld (vidDstPage), a
    nextreg NR_MMU2, a
    ld c, a
    ld a, (vidDstPages)
    add a, c
    ld (vidDstEnd), a
    ld de, VID_DST_WIN
    ret

; Direct-serve frame decode (3c): the payload arrives ONE BYTE AT A
; TIME off the open CMD18 stream - HL carries the open block's
; remaining byte count for the whole decode (every frame section is
; 512-aligned, so HL is 0 at every section boundary and no cell is
; needed). Ops parse through the always-slow path (vid_fetch is
; vectored to vid_ds_byte); COPY literals ride vid_ds_copy_body's
; unrolled-ini transport straight to the surface; SKIP/RUN reuse the shared
; dest-side bodies; PAL lands on the ds handler via its per-session
; stub slot, FEND/KFLIP through vid_term_exit's patched operand.
; Terminal handlers ret to our caller.
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
; CIRCULAR AUDIO FEED (SP17 T10). One 8192-byte ring (vidAudBuf,
; NXV_AUD_RING - the whole session audio bank): the ISR's read pointer
; (IX) free-runs around it and the frame loop WRITES BEHIND the reader
; - a byte of frame f+1 lands in a cell only after the reader has
; consumed the frame-f byte that occupied it. Capacity per frame is
; therefore the whole ring (minus NXV_AUD_GUARD), not one fixed half:
; the 24.40 fps stereo floor moves to 10.17 (the playvid differential).
;
; At the full ring, every legal file's frame feed fits the single
; post-present pump (2*NXV_AUD_FRAME_MAX = 6144 against 8176), so the
; .pace trickle path below is a backstop rather than the normal
; low-fps regime. See the nextdaad.inc constant block.
;
; PROTOCOL (three pieces, no ISR involvement beyond the ring wrap):
;   vid_aud_stage - after present: arm the feed (vidAudFeedRem =
;     real bytes of the NEXT frame's audio; ds: block-remain 0).
;   vid_aud_pump  - copy up to BC bytes of the staged feed into the
;     ring at vidAudWr, source-side seam-walked (ring/SD exactly as
;     the old vid_aud_copy) and dest-side bounded by ROOM =
;     ring - guard - (wr - rd mod ring). Called with a big budget
;     right after staging (which now completes the WHOLE feed for any
;     legal file - the pre-T10 shape, restored at every fps), with
;     NXV_AUD_PUMP_CHUNK from the .pace spin (the chasing writer, now
;     only reachable if the reader is behind), and to completion at
;     .paced (the force-finish backstop). The rd snapshot (push ix)
;     only goes stale in the safe direction - the reader advances,
;     so true room only grows while a chunk runs.
;   the .pace consumption integrator - pacing (see the frame loop).
;
; Source-cursor bookkeeping is INCREMENTAL: each chunk advances the
; live BYTE cursor (resident vidFramePos / streaming vidRingRl, mod)
; by the bytes copied, so vid_src_seek needs no offset variant; the
; pad slack (aBytesPad - aBytes) and the streaming depth debit land
; once, at completion - the final cursor state is byte-identical to
; the old one-shot copy. The streaming FILE cursor is the one
; exception: it counts BLOCKS (ceiling lift), so the whole padded
; section is charged in one step at completion.
; UNDERRUN MODE: if the feed is late (chronically slow decode), the
; reader plays STALE ring data (the previous lap) until the writer
; catches up - bounded, self-recovering, the circular analogue of the
; old held-last-sample. Corrupts AF, BC, DE, HL. Preserves IX (read
; only - the ISR owns it). Errors abort via vid_src_next / the ds
; fault funnels, exactly as before.
; ---------------------------------------------------------------------
vid_aud_stage:
    ld hl, (vidABytes)
    ld (vidAudFeedRem), hl
    ld hl, 0
    ld (vidDsAudBlkRem), hl      ; ds: the wire sits at a section
    ret                          ; boundary here (vid_ds_done padded)

; The consumption integrator (T10 pacing core): debit vidPaceRem by
; the bytes the ISR consumed since the last call (read-pointer delta,
; mod ring). Out: CF set = released (rem reached 0 or went negative,
; short of its most negative value - rem stays stored either way; the
; ack at .paced carries sub-frame deficit as catch-up). Only a degraded
; SD stall can drive rem that low: a streaming ring-gate hold, or
; direct-serve .ffin on a failing card. Called from every wait loop
; that can hold for a while (.pace, .drainlast, the ring gate's
; force-fill, the .paced force-finish) so the reader can never advance
; more than one ring lap between calls in any non-degraded regime -
; the delta stays mod-ring-unambiguous.
;
; Margin: the reader laps the ring in NXV_AUD_RING / 31250 s, which
; must clear one whole frame period (worst case AUDIO+DECODE+FLIP+tail)
; with room to spare - at 8192 bytes that is 3.3x the period.
; Corrupts AF, DE, HL. Preserves BC, IX.
vid_pace_poll:
 IFDEF DEBUG
  IFNDEF NXB_QUIET
    ; Phase 2-POLL causation probe: divided 1-in-16 via vidRlSpinDiv
    ; (was every pass - see the safety-floor arithmetic there).
    ld a, (vidRlSpinDiv)
    dec a
    ld (vidRlSpinDiv), a
    call z, vid_rl_poll           ; PLAY= clock: this routine is called
                                 ; from every wait loop the frame loop
                                 ; has, so the raster is read far more
                                 ; often than once a field there
  ENDIF
 ENDIF
    push ix
    pop hl                       ; HL = read pointer (atomic snapshot)
    ld de, (vidAudRdPrev)
    ld (vidAudRdPrev), hl
    or a
    sbc hl, de
    jr nc, .d
    ld de, NXV_AUD_RING          ; the reader wrapped the ring end
    add hl, de
.d:
    ex de, hl                    ; DE = consumed bytes
    ld hl, (vidPaceRem)
    or a
    sbc hl, de
    ld (vidPaceRem), hl
    dec hl                       ; CF = bit 15 of rem-1: rem <= 0 releases, bar
    add hl, hl                   ; the most negative rem, which only a degraded
    ret                          ; SD stall reaches (ring gate, direct .ffin)

vid_aud_pump:
    ld (vidAudBudget), bc
.next:
 IFDEF DEBUG
  IFNDEF NXB_QUIET
    ; Phase 2-POLL causation probe: divided 1-in-16 via vidRlSpinDiv,
    ; shared with vid_pace_poll's cell (was every pass).
    ld a, (vidRlSpinDiv)
    dec a
    ld (vidRlSpinDiv), a
    call z, vid_rl_poll           ; PLAY= clock. With an unbounded budget
                                 ; and a full ring this loop chases the
                                 ; READER, so one call runs for tens of
                                 ; ms at low fps - the single biggest
                                 ; poll gap in the player (vid_rl_poll)
  ENDIF
 ENDIF
    ld bc, (vidAudFeedRem)
    ld a, b
    or c
    ret z                        ; feed complete (or nothing staged)
    ; n = min(feedRem, budget, room, ring tail) - BC rides the min
    ld hl, (vidAudBudget)
    or a
    sbc hl, bc
    jr nc, .bud                  ; budget >= feedRem: BC stands
    ld bc, (vidAudBudget)
.bud:
    ; room = ring - guard - unplayed; unplayed = (wr - rd) mod ring
    push ix
    pop de                       ; DE = rd (single-instruction snap)
    ld hl, (vidAudWr)
    or a
    sbc hl, de
    jr nc, .unp
    ld de, NXV_AUD_RING
    add hl, de
.unp:
    ex de, hl                    ; DE = unplayed
    ld hl, NXV_AUD_RING - NXV_AUD_GUARD
    or a
    sbc hl, de
    ret c                        ; writer already at the guard: no room
    or a
    sbc hl, bc
    jr nc, .room                 ; room >= wanted: the whole chunk
    add hl, bc                   ; HL = room (< wanted: ROOM-LIMITED)
    ; ROOM FLOOR: below chunk size, return and let the caller poll - the
    ; reader frees room at ~896 T/byte, so entering the pump path for a
    ; few bytes wastes the ~1950 T pump cost. Floor is
    ; min(NXV_AUD_PUMP_CHUNK, feedRem), not the raw constant, so a small
    ; remaining feed is not held out waiting for room it will never
    ; need. Unreachable on any legal file (the frame-size ASSERT below
    ; guarantees every feed fits a single pass) but kept correct as a
    ; degraded-regime backstop.
    ASSERT NXV_AUD_PUMP_CHUNK == 256
    ld a, h
    or a
    jr nz, .rlim                 ; room >= 256: a whole chunk is there
    ld a, (vidAudFeedRem+1)
    or a
    ret nz                       ; feed still wants >= 256: hold out
.rlim:
    ld b, h
    ld c, l                      ; BC = room
.room:
    ld a, b
    or c
    ret z                        ; no room this call (reader frees it
                                 ; at the sample rate - callers re-poll)
    ; clip to the ring tail: one chunk never straddles the wrap (the
    ; write cursor wraps between chunks instead)
    ld hl, vidAudBuf + NXV_AUD_RING
    ld de, (vidAudWr)
    or a
    sbc hl, de                   ; HL = tail room (>= 1 by wrap rule)
    or a
    sbc hl, bc
    jr nc, .tail
    add hl, bc
    ld b, h
    ld c, l                      ; BC = tail room
.tail:
    push bc                      ; chunk byte count n, for accounting
    ld a, (vidDirect)
    or a
    jr z, .ram
    ; --- ds chunk: SD wire -> ring (vid_ds_xfer holds the CMD18
    ; stream mid-block across calls via the block-remain cell) ---
    ld de, (vidAudWr)
    ld hl, (vidDsAudBlkRem)
    call vid_ds_xfer             ; DE advanced, HL = block remain
    ld (vidDsAudBlkRem), hl
    jr .account
.ram:
    ; --- ring-source chunk: seek the consumer cursor, seam-walked
    ; copy (the old vid_aud_copy segment loop, bounded by n) ---
    call vid_src_seek            ; HL = src window cursor, MMU6 mapped
    ld de, (vidAudWr)            ; (the seek corrupts BC - reload n
    pop bc                       ; from the accounting save)
    push bc
.seg:
    ld (vidAudNeed), bc
    ; src room = $E000 - HL (never 0: seek/next leave HL < $E000)
    xor a
    sub l
    ld c, a
    ld a, $E0
    sbc a, h
    ld b, a                      ; BC = src room
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
    jr .account
.last:
    pop hl
    ld bc, (vidAudNeed)
    ldir
.account:
    pop bc                       ; BC = n
    ; budget -= n; feedRem -= n
    ld hl, (vidAudBudget)
    or a
    sbc hl, bc
    ld (vidAudBudget), hl
    ld hl, (vidAudFeedRem)
    or a
    sbc hl, bc
    ld (vidAudFeedRem), hl
    ; wr += n, wrap at the ring end (tail clip bounds the sum)
    ld hl, (vidAudWr)
    add hl, bc
    ld de, vidAudBuf + NXV_AUD_RING
    or a
    sbc hl, de
    jr z, .wrap                  ; landed exactly on the end
    add hl, de
    jr .wr
.wrap:
    ld hl, vidAudBuf
.wr:
    ld (vidAudWr), hl
    ; consumer source cursor += n. RESIDENT: the byte cursor into the
    ; RAM image. STREAMING: the ring-linear byte cursor only - the
    ; FILE cursor counts BLOCKS since the ceiling lift and is charged
    ; once, at feed completion (.strmdone). DIRECT: neither (the open
    ; wire is the cursor).
    ld a, (vidStreaming)
    or a
    jr nz, .rlonly
    ld a, (vidDirect)
    or a
    jr nz, .fed
    ld hl, (vidFramePos)
    add hl, bc
    ld (vidFramePos), hl
    jr nc, .fed
    ld hl, vidFramePos+2
    inc (hl)
    jr .fed
.rlonly:
    ld hl, (vidRingRl)
    add hl, bc                   ; last BC use - vid_rl_mod corrupts it
    ld a, (vidRingRl+2)
    adc a, 0
    call vid_rl_mod              ; A:HL mod ringBytes -> vidRingRl
.fed:
    ld hl, (vidAudFeedRem)
    ld a, h
    or l
    jr z, .done
    ld hl, (vidAudBudget)
    ld a, h
    or l
    ret z                        ; budget spent - trickle continues
    jp .next
.done:
    ; --- completion accounting, once per staged frame (the old .adv
    ; tail): pad slack onto the cursors, streaming depth debit ---
    ld a, (vidDirect)
    or a
    jr z, .ramdone
    ld hl, (vidDsAudBlkRem)      ; ds: discard the section pad to the
    call vid_ds_pad              ; block boundary (HL = 0 on exit)
    ld (vidDsAudBlkRem), hl
    ret
.ramdone:
    ld hl, (vidABytesPad)
    ld de, (vidABytes)
    or a
    sbc hl, de
    ld b, h
    ld c, l                      ; BC = pad slack (0..511)
    ld a, (vidStreaming)
    or a
    jr nz, .strmdone
    ld hl, (vidFramePos)         ; resident: the byte cursor takes the
    add hl, bc                   ; pad slack
    ld (vidFramePos), hl
    ret nc
    ld hl, vidFramePos+2
    inc (hl)
    ret
.strmdone:
    ld hl, (vidRingRl)
    add hl, bc
    ld a, (vidRingRl+2)
    adc a, 0
    call vid_rl_mod              ; A:HL mod ringBytes -> vidRingRl
    ; the STREAMING file cursor counts BLOCKS: one whole audio section
    ; is apadBlk blocks (== aBytesPad >> 9), charged once here - the
    ; per-chunk byte advance the resident path takes has no meaning in
    ; the file unit. BC then serves the depth debit unchanged.
    ld a, (vidApadBlk)
    ld c, a
    ld b, 0
    ld hl, (vidFramePos)
    add hl, bc
    ld (vidFramePos), hl
    jr nc, .fpnc
    ld hl, vidFramePos+2
    inc (hl)
.fpnc:
    ; depth -= audio-pad blocks (the gate's staged need covered them)
    jp vid_depth_debit

; ---------------------------------------------------------------------
; vid_play - the player core entry. B = video number, C = 0 play-once
; / 1 loop (h_gfx/h_sfx translate GFX n 13/14 / SFX n 9/10 before the
; cross-page hop - the game-facing surface is UNCHANGED). Probes
; PARTn\NNN.VID then root NNN.VID (cold body), then hands off to
; vid_run. Always returns via vid_run's restore paths; the caller
; never resumes (the dispatch trampoline's stacked return).
; ---------------------------------------------------------------------
vid_play:
    ld a, c
    ld (vidLoopMode), a
    ld c, b                      ; video number travels in C
    ld hl, vid_open_video_body   ; cold: name build + PARTn probe +
                                 ; esx open + filemap capture (+ DEBUG
                                 ; missing print)
    jp vid_hop2                  ; push HL (the body), map VID_PAGE2
.openret:
 IFDEF DEBUG
    ld a, b                      ; D1: neither name opened - vid_run is
    or a                         ; never reached, so nothing would ever
    call nz, nxb_ds_unsel        ; clear the bench selector
 ENDIF
    ld a, b
    or a
    ret nz                       ; neither name opened
    jp vid_run

; Flip display+edit to the pending palette bank; no-op when none
; pends. Corrupts AF.
vid_pal_present:
    ld a, (vidPalPending)
    or a
    ret z
    ld a, (vidPalCtrl)
    xor $44                      ; display+edit both to the new bank
    ld (vidPalCtrl), a
    nextreg NR_PAL_CTRL, a
    xor a
    ld (vidPalPending), a
    ret

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
    ; vidPlaying: set at the single entry (video.asm is the only caller
    ; of vid_run - vid_play's tail jump), before any page hop; cleared
    ; at the single restore tail (.restore_tail below) - a missed clear
    ; wedges every busy-aware hook effect.
    ld a, 1
    ld (vidPlaying), a
    call spr_stop_all            ; sprites are off during video (NR $15 saved
                                 ; and zeroed below, restored on exit); no set
                                 ; survives, so the restore brings back only
                                 ; the pointer's own state
    ; MMU6/MMU7 MUST be captured HERE, hot, before ANY hop (a cold
    ; hop's own bracket would capture its own temporary value). The
    ; stop-all above is not a hop: spr_call brackets MMU6/7 and restores
    ; them, so this still reads the caller's own mapping.
    ld e, NR_MMU6
    call nr_read
    ld (vidSvMmu6), a
    ld e, NR_MMU7
    call nr_read
    ld (vidSvMmu7), a
 IFDEF DEBUG
    ; SP17 BENCH (A2): capture the PRE-BORROW MMU3 here too, hot, for
    ; exactly the reason above. vid_run_l2setup_body borrows MMU3
    ; ($6000-$7FFF) for the session audio window and only gives it back
    ; at teardown - and VID_AUD_WIN IS TM_MAP, so the bench rows would
    ; otherwise print into the audio bank and vanish. l2setup's own save
    ; (vidSvMmu3) is a VID_PAGE2 cell the bench cannot reach from here,
    ; hence this hot mirror. Used ONLY by nxb_tm_in/nxb_tm_out, which
    ; bracket the row PRINTS - never a measured loop.
    ld e, NR_MMU3
    call nr_read
    ld (nxbSvTm3), a
 ENDIF
    ; AUTO-RESUME CAPTURE: a LOOPING sampled effect must resume itself
    ; when the clip ends (a one-shot stays stopped), so which channels
    ; were looping is recorded here, hot, before vid_run_entry_body's
    ; abort clears SMPB_FLAGS bits 0/1 - equivalent to capturing at the
    ; abort site since nothing between them can change a looping
    ; channel's active bit. Gated on audEnable exactly as the abort is.
    ld c, 0                      ; C = the pending-resume mask
    ld a, (audEnable)
    or a
    jr z, .sfxresdone
    ld a, (sfxChan1+SMPB_FLAGS)  ; channel 2's block is resident
    and %00000011                ; ACTIVE and LOOPING
    cp %00000011
    jr nz, .sfxres1
    set 1, c
.sfxres1:
    call data_save               ; channel 1's block is page-48 data
    ld a, AUD_PAGE_LO
    call data_map_page
    ld a, (sfxChan0+SMPB_FLAGS)
    ld b, a                      ; data_restore corrupts AF
    call data_restore
    ld a, b
    and %00000011
    cp %00000011
    jr nz, .sfxresdone
    set 0, c
.sfxresdone:
    ld a, c
    ld (vidSvSfxRes), a
    ld hl, vid_run_orch_body
    jp vid_hop2                  ; push HL (the body), map VID_PAGE2
.orchret:
    ; B = 0: ready to arm (entry captured, file loaded/prefilled,
    ; L2/ISRs/session cells all set). B != 0: failed open - the orch
    ; body already unwound (ring freed, stream closed, music tick
    ; restored, DEBUG verdict printed); nothing armed, so the only exit
    ; work left is the sampled-channel resume: the entry body ALREADY
    ; aborted both channels before the open was attempted, and a clip
    ; that never played must not be what permanently kills a looping
    ; bed. Same tail as a real teardown.
 IFDEF DEBUG
    ld a, b                      ; D1: this bail returns BEFORE the hook
    or a                         ; below, so the selector would survive
    call nz, nxb_ds_unsel        ; and hijack the next video verb
 ENDIF
    ld a, b
    or a
    jr z, .hooksusp
    xor a
    ld (vidPlaying), a           ; this bail skips .restore_tail: clear it here
    jp .sfxresume
.hooksusp:
    ; Suspend the frame hook for the clip: the hook body's $243B/$253B save
    ; would split vid_op_pal's undefended $44 burst. HOOK_SPR is already off.
    ld a, (xbnIntOn)
    and HOOK_XBN+HOOK_CYC
    ld (vidSvHook), a
    ld a, (xbnIntOn)
    and $FF-(HOOK_XBN+HOOK_CYC)
    ld (xbnIntOn), a
 IFDEF DEBUG
    ; Session bench hook: flags+248 = session mode (nxb_sess). The session is
    ; staged and the CTC is not armed; playback is replaced by the rows.
    ld a, (flags+248)
    or a
    jr z, .nobench
    ld (vidDecSp), sp            ; abort anchor = the session anchor
    call nxb_sess                ; NC: a direct session
    jr c, .benchend
    call nxb_ds_rows
.benchend:
    jp .restore
.nobench:
 ENDIF
    ; --- audio-0 preload (T10 circular feed): prime the ring cells
    ; and pump frame 0's audio into the empty ring in one go (room =
    ; the whole ring minus the guard >= any legal frame). IX is set
    ; here too - pre-arm it is just the pump's read-pointer snapshot
    ; source; the CTC arm below re-primes it for the ISR.
    ld (vidDecSp), sp            ; abort anchor: the preload's ring
                                 ; walk / SD read can abort on corrupt
                                 ; input (.restore is safe pre-arm -
                                 ; the CTC park no-ops on an unarmed
                                 ; CTC)
    ld ix, vidAudBuf
    ld hl, vidAudBuf
    ld (vidAudWr), hl
    ld (vidAudRdPrev), hl
    ld hl, 0
    ld (vidPaceRem), hl          ; frame 0's release is pre-paid: the
                                 ; first .pace poll passes immediately
    call vid_aud_stage
    ld bc, $FFFF
    call vid_aud_pump            ; completes: the ring was empty
    ; --- CTC retune (v1-proven sequence, carried verbatim): double
    ; soft-reset, control word, IX primed BEFORE the time constant
    ; starts the timer (the postmortem ordering rule); the IM2 stub
    ; was patched cold, above; the ISRs' ring-end wrap compares are
    ; assembly constants now (T10) - nothing per-file to patch. ---
    ld bc, AUD_CTC_PORT
    ld a, AUD_CTC_RESET
    out (c), a
    out (c), a                   ; double soft-reset (unknown -> clean)
    ld a, AUD_CTC_CW16
    out (c), a                   ; control word - timer not running yet
    ld ix, vidAudBuf             ; the ISR's exclusive play pointer
    ; --- SP17 T9: frame-clock VBLANK PHASE LOCK. The time-constant
    ; write below starts the whole playback clock (the CTC audio timer
    ; that everything else paces from), and until now it started at a
    ; RANDOM point in the 50Hz field - so the tear line of E7 DRIFTED
    ; session to session. playvid parks a `halt` immediately before its
    ; time-constant write (video_256x192_m_palette.asm:210-213) to
    ; phase-lock the clock to the field. The v2 CTC rates are playvid's
    ; own exact-divide rate (vidCtcTcNxvStereo tracks the field rate
    ; per video mode), so only the INITIAL phase was wrong - this
    ; wait makes the tear position deterministic.
    ; MECHANISM: a frameCounter change poll, NOT halt, chosen with the
    ; code read the charter asked for. Interrupts ARE enabled here (no
    ; DI anywhere on the .orchret->arm path; the DI/EI pairs in the
    ; orch bodies are closed brackets), so halt would work - but halt
    ; wakes on ANY enabled source, and im2_init enables the expansion-
    ; bus INT (NR $C4 bit 7, its own belt-and-braces note) alongside
    ; the ULA, so a stray bus edge would end a halt OFF-phase.
    ; frameCounter increments in exactly one place, the im2_isr ULA
    ; field tick (interrupts.asm), and audEnable is frozen for the
    ; session so that ISR runs its constant-time AF/HL fast path -
    ; polling it waits for the FIELD specifically, with deterministic
    ; release latency (ISR fast path + one poll iteration + the fixed
    ; 35T to the OUT below, well under a scanline). Low byte only: it
    ; changes every field, wrap included.
    ld a, (frameCounter)
    ld d, a
.phase:
    ld a, (frameCounter)
    cp d
    jr z, .phase                 ; released by the ULA field tick
    ld a, (vidCtcTc)
    ld bc, AUD_CTC_PORT
    out (c), a                   ; time constant -> timer starts NOW,
                                 ; phase-locked to the field (T9)

; ---------------------------------------------------------------------
; The frame loop (T10 circular-feed phasing). Per frame f: pace on
; CONSUMPTION of frame f-1's audio - the circular feed has no half-
; boundary event, so the boundary detection moved from the ISR to a
; MAINLINE CONSUMPTION INTEGRATOR: each .pace poll snapshots the
; ISR's free-running read pointer (push ix - atomic), accumulates the
; consumed delta (mod ring) and releases the frame when one frame's
; real audio bytes have been consumed. PACING HANDOFF (T9+T10 design,
; documented per the charter): the pacing SOURCE remains the audio
; clock (the v1 principle - pacing derives from audio bytes, exact
; for every legal file, zero long-run drift), and T9's field phase
; lock makes that clock START at a fixed field phase; the per-mode
; CTC tables are exact-divide against the field rate, so the release
; cadence is field-locked end to end. Pure vblank COUNTING was
; considered and rejected: the 8-bit header fps*10 field would have
; become load-bearing (a format reinterpretation), and any rounding
; between fps and bytes-per-frame would drift the free-running
; reader/writer pair apart over long loops - consumption integration
; has neither problem. While waiting, the spin TRICKLES the staged
; next-frame audio into the ring behind the reader (the chasing
; writer that funds the low-fps floor) and (streaming) produces SD
; blocks. Then: force-finish the feed (normally a no-op) -> ring
; gate -> decode/paint -> present -> STAGE frame f+1's audio + pump
; what fits (aBytes <= NXV_AUD_FRAME_MAX 3072, open rejects more; loop
; mode rewinds the cursors first, so pass N+1's frame-0 audio feeds
; seamlessly; play-once skips staging on the last frame and the
; drain tail waits the audio out) -> key check -> frame accounting.
; DEBUG: 5-phase stamps, one per transition. TIMELINE SEMANTICS
; (T10): AUDIO brackets the stage + initial pump after present; the ring
; holds two whole frames (ASSERT 2*NXV_AUD_FRAME_MAX <= ring-guard), so
; the pump completes in one pass, PACE is a backstop, TOT is unchanged.
; ---------------------------------------------------------------------
.frameloop:
 IFDEF DEBUG
  IFNDEF NXB_QUIET
    call vid_play_frame          ; PLAY= bracket arm (first frame),
                                 ; FRM++ and
                                 ; NOM += one frame's nominal fields -
                                 ; HERE, not at the present, so that
                                 ; held frames count (see its banner)
  ENDIF
 ENDIF
    ld (vidDecSp), sp            ; abort anchor for this iteration
.pace:
.pacecall equ $+1                ; DEBUG bench LOOP row: nxb_lp_pace
    call vid_pace_poll           ; integrate consumption; CF = this
    jr c, .paced                 ; frame's audio consumed (or past)
    ; not yet: chase the reader with the staged feed, and (streaming)
    ; produce SD blocks into the source ring
    ld bc, NXV_AUD_PUMP_CHUNK
    call vid_aud_pump            ; bounded chunk keeps the poll tight
    ld a, (vidStreaming)
    or a
    jr z, .pace                  ; resident/direct: poll + pump only
    call vid_prod_step           ; one 512B block max, then re-check
    jr .pace                     ; (the 099 vidProdThrottle lever was
                                 ; RETIRED in 3c - its deliberate-
                                 ; underrun verdict is on record in
                                 ; Cards #3/#4; git holds the lever)
.paced:
    ; ack: the next release needs one more frame's worth consumed.
    ; Sub-frame lateness carries (bounded catch-up); a deficit of a
    ; whole frame or more is dropped - the old Done-flag's collapsed-
    ; boundary semantics (video runs late, audio stays continuous).
    ld hl, (vidPaceRem)
    ld de, (vidABytes)
    add hl, de
    dec hl                       ; HL-1 negative <=> HL <= 0: clamp. The one
    bit 7, h                     ; exception, the most negative HL, is never
    inc hl                       ; a released rem plus aBytes
    jr z, .remok
.rclamp:
    ex de, hl                    ; rem = aBytes (excess deficit dropped)
.remok:
    ld (vidPaceRem), hl
    ; the reader is entering the staged frame's audio NOW: force-
    ; finish any outstanding feed. Normally a no-op (the pace spin
    ; completed it); when late it is bounded - the armed CTC frees
    ; ring room at the sample rate, so every pass makes progress.
.ffin:
    ld hl, (vidAudFeedRem)
    ld a, h
    or l
    jr z, .fed
    ld bc, $FFFF
    call vid_aud_pump
    call vid_pace_poll           ; keep the integrator honest across
    jr .ffin                     ; a long finish (CF ignored - already
                                 ; released; the debit carries)
.fed:
    ld a, (vidStreaming)
    or a
    call nz, vid_ring_gate       ; streaming: hold until frame served
    call vid_decode_any          ; A = terminal (errors -> .decfail)
    ; --- present ---
    cp VOP_KFLIP
    jr nz, .delta
    ; keyframe present: palette swap (if a PAL rode the span) then
    ; the pixel-bank flip - two back-to-back nextreg writes, the
    ; v1-proven CPU choreography (no copper, no independent writer)
    call vid_pal_present
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
    call z, vid_pal_present      ; delta-frame PAL presents with its
                                 ; frame; a span hold frame presents
                                 ; nothing
.present_done:
    ; --- stage the NEXT frame's audio feed (T10) ---
    ld hl, (vidFramesLeft)
    dec hl
    ld a, h
    or l
    jr nz, .qnext                ; frames follow: stage frame f+1
    ld a, (vidLoopMode)
    or a
    jr z, .qskip                 ; last frame, play-once: nothing to
                                 ; stage - the drain tail waits
    ; loop restart: rewind the consumer BEFORE staging pass N+1's
    ; frame-0 audio (resident: RAM cursor only - no SD, no reopen,
    ; seam-free; streaming: ring cursor + the pass header block)
    call vid_loop_rewind
.qnext:
    call vid_aud_stage           ; arm the feed, then pump what fits
    ld bc, $FFFF                 ; ask for the whole staged feed: it fits in
    call vid_aud_pump            ; one pass for every legal file
                                 ; (2*NXV_AUD_FRAME_MAX <= ring-guard)
.qskip:
    call vid_key_any             ; any key ends playback (<= 1 frame
    jr nz, .restore              ; latency; the frame just presented)
    ld hl, (vidFramesLeft)
    dec hl
    ld (vidFramesLeft), hl
    ld a, h
    or l
.loopj equ $+1                   ; DEBUG bench LOOP row: nxb_lp_next
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
    ; play-once: the last frame is showing; wait its audio out with
    ; the same consumption integrator as .pace (nothing staged, so no
    ; pump - vidPaceRem still holds this frame's unconsumed bytes).
    ; After release the reader free-runs into stale ring data for the
    ; few instructions until .restore parks the CTC: a sample or two,
    ; against the old tail's held last sample - both inaudible.
    call vid_pace_poll
    jr nc, .drainlast
    jr .restore
.decfail:
    ; vid_dec_abort lands here, SP already reset to vidDecSp (A =
    ; VID_ERR_*, stored to vidErrCode in DEBUG for the report)
.restore:
 IFDEF DEBUG
    ld a, (nxbSessLive)
    or a
    jr z, .nosess
    ld sp, (nxbSessSp)           ; a session exit tears down at the hook's depth
    call nxb_reclaim
.nosess:
    call vid_play_close          ; PLAY= bracket close, before the CTC
                                 ; is parked (every exit lands here)
 ENDIF
    ; --- CTC off first (mirrors aud_smp_stop): the ISR cannot fire
    ; once this completes, so everything after may hop cold. ---
    ld bc, AUD_CTC_PORT
    ld a, AUD_CTC_RESET
    out (c), a
    out (c), a
    ld a, DAC_SILENCE
    out (DAC_PORT), a            ; park all four DAC ports: the video
    out (VID_DAC_LEFT), a        ; ISR drives the stereo pair, and the
    out (VID_DAC_RIGHT), a       ; aborted sample engine held DAC_PORT
    out (DAC2_PORT), a           ; SP18 item 7 Task 10: channel 2's DAC park.
                                 ; DAC2_PORT $B3 drives DACs B+C - exactly
                                 ; VID_DAC_LEFT ($F3, B) and VID_DAC_RIGHT
                                 ; ($F9, C), the two DACs the video stereo
                                 ; feed uses. This teardown never seizes CTC
                                 ; channel 1 (only channel 0's vector is
                                 ; repointed, above), so a LIVE channel 2
                                 ; would write DACs B/C underneath a running
                                 ; clip - which is why the requirement is met
                                 ; at ENTRY, not here: vid_run_entry_body
                                 ; files audRequest2 bit 2 and waits for it,
                                 ; so the channel is provably stopped before
                                 ; the clip starts (Task 11). This park is
                                 ; the belt to that braces - it leaves the
                                 ; pair at silence for whatever comes next.
    call vid_win_close_h         ; the CMD18 window is HOT property
                                 ; when a session held one (streaming/
                                 ; direct): CMD12 + deselect + MF
                                 ; restore before the cold body
                                 ; F_CLOSEs the handle. Idempotent on
                                 ; vidWinOpenH (staged 0 resident), so
                                 ; the call is unconditional (3c).
    ld hl, vid_run_restore_body  ; stub/L2/presentation/MMU2 restore +
                                 ; ring free (EXIT ORDER FIX inside)
    jp vid_hop2                  ; push HL (the body), map VID_PAGE2
.restore_tail:
    ; vidPlaying: cleared here, the single restore tail (reached only
    ; via vid_run_restore_body's jp back to this label) - dominates
    ; both exits below; the failed-open bail clears it itself before
    ; its jump into .sfxresume.
    xor a
    ld (vidPlaying), a
 IFDEF DEBUG
    call vid_tl_report           ; fully-torn-down print (hot/cold/hot)
 ENDIF
    ld a, (vidSvMmu6)
    nextreg NR_MMU6, a
    ld a, (vidSvMmu7)
    nextreg NR_MMU7, a
    ld a, (vidSvHook)            ; resume the hook AFTER vidPlaying is clear:
    ld hl, xbnIntOn              ; a hook never observes bit 0 set
    or (hl)
    ld (xbnIntOn), a
    xor a
    ld (vidSvHook), a            ; consumed, like vidSvSfxRes: a bench abort must not OR a stale mask back
    ; --- AUTO-RESUME. The teardown is over:
    ; audEnable, the IM2 stub and the CTC/DAC parks are all back, the
    ; CMD18 window is closed and the video handle is F_CLOSEd, so the
    ; card is free and this is ordinary mainline. Hand the mask to the
    ; restart driver on SFX_PAGE, which is where the allocator and the
    ; cached-stream rewind already live; it rets to the condact
    ; dispatcher in our place. Slot 7 is left on SFX_PAGE rather than
    ; VID_PAGE, which is harmless: every condact dispatch maps its own
    ; handler page, and the frame ISR saves and restores MMU6/7 around
    ; its own remap. ovl_map_page never touches D, so the mask rides
    ; there. Shared with the failed-open bail at .orchret, which reaches
    ; it with nothing armed and nothing else left to unwind.
.sfxresume:
    ld a, (vidSvSfxRes)
    or a
    ret z
    ld d, a
    xor a
    ld (vidSvSfxRes), a          ; consumed
    ld hl, sfx_vid_resume
    push hl
    ld a, SFX_PAGE
    jp ovl_map_page

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
; Audio CTC ISR - the v1 per-tick shape (IX-exclusivity / banking-
; invariant design unchanged) on the T10 CIRCULAR FEED: IX free-runs
; around the whole 8192-byte ring and the ONLY boundary work left is
; the wrap back to the ring base - an assembly-constant compare (the
; ring geometry never changes), so the 3b per-file end-marker SMC and
; the whole queued-half swap tail are GONE. The per-tick fast path is
; byte-identical to 3b; the boundary path SHRANK from the ~150T swap
; tail (Rdy test + IX reload + two SMC patches + the vidAudDone
; store, once per frame) to a 26T wrap (ld ix,nn + jr, once per ring
; LAP - now every ~6 frames at 25 fps stereo).
;
; THE TWO WRAP COMPARES ARE THE MOST TIMING-CRITICAL INSTRUCTIONS IN
; THE PLAYER, hand-verified when the ring grew to 8192 from its earlier
; 2560-byte size. The INSTRUCTION SHAPE is unchanged and so is its cost -
; the ring size moves only the two 8-bit IMMEDIATES:
;   ring end-2 $69FE -> $7FFE: cp $FE unchanged / cp $69 -> $7F
; The base sits at $..00 and the size is a whole number of pages, so
; the ring end keeps its $FE low byte: the high compare is still
; reached on exactly 1 tick in 128 (ixl even), no compare widened to
; 16 bits, and nothing became a `ld hl`/`sbc` pair.
; Hand count at 28 MHz (nominal +1 per opcode fetch and per memory
; read, doc 01), IM2 acknowledge 22 T + the JP stub 13 T included:
;
;   path                     before/after
;   fast (compare+advance)   57 T / 57 T
;   low hit, high miss       85 T / 85 T
;   wrap                     88 T / 88 T
;   WHOLE ISR, typical      212 T / 212 T
;   WHOLE ISR, worst        243 T / 243 T
;
; Not one T-state moved; the only change is that the 88 T wrap arrives
; once per 8192 ticks instead of once per 2560, so the MEAN ISR is
; 0.01 T cheaper. Against the TIGHTEST period the format can select -
; stereo VGA0 1792 T - the worst tick is 13.6%
; of the period, margin 86%.
; WHY 8192 AND NOT 7680: 7680 ($1E00) is equally page-aligned and
; would have cost exactly the same compares, so the cheap-compare test
; does not separate them. 8192 wins on the other two: it is the WHOLE
; bank (bank_alloc hands vidAudBuf an exclusive 8 KB pool bank -
; nothing else lives in that page), and it ends flush at the MMU3
; window top so `vidAudBuf + NXV_AUD_RING` is the page boundary
; $8000, a compile-time constant that is compared against but never
; dereferenced. The 512-byte cushion 7680 would leave buys nothing:
; every write into the ring goes through vid_aud_pump's tail clip
; (BC = min(..., vidAudBuf + NXV_AUD_RING - vidAudWr)) and both
; transports below it - the seam-walked LDIR and vid_ds_xfer - move
; EXACTLY BC bytes, so no writer can reach the boundary in the first
; place. That is the same rule that already guarantees a chunk never
; straddles the wrap.
; Pacing moved OUT of the ISR entirely: the frame loop integrates
; consumption from IX (see the frame-loop banner); vidAudDone no
; longer exists. Feed-late behaviour: the reader plays STALE ring
; data (previous lap) instead of holding the last sample - bounded,
; self-recovering, documented at the pump banner. Installed by
; vid_run_l2setup_body patching IM2_CTC_STUB; MMU7 = VID_PAGE for the
; whole armed window (doc 11 / rubric 3).
;
; ONE ISR, because the format carries ONE channel count. The mono
; twin (one DAC write per SAMPLE at 23325 Hz) was withdrawn with mono
; itself - see nextdaad.inc NXV2_OFF_ACHAN. The routine below is
; UNCHANGED by that removal, byte for byte.
; DMA-PRE-EMPTION CONTRACT (SP18 item 5): this ISR may run INSIDE a
; suspended video DMA transfer ($CD bit 0). It is MMU-free, never
; touches port $6B, and MUST EXIT VIA RETI - the RETI is what returns
; the bus to the DMA (dev guide interrupts chapter). A RET exit, an
; MMU write, or a DMA-port touch here corrupts a resumed transfer.
; ---------------------------------------------------------------------
video_ctc_isr_stereo:
    push af
    ld a, (ix+0)
    out (VID_DAC_LEFT), a
    ld a, (ix+1)
    out (VID_DAC_RIGHT), a
    ld a, ixl
    cp low (vidAudBuf + NXV_AUD_RING - 2)
    jr nz, .adv                  ; last PAIR address (ring size even -
    ld a, ixh                    ; pairs never straddle the wrap)
    cp high (vidAudBuf + NXV_AUD_RING - 2)
    jr nz, .adv
    ld ix, vidAudBuf             ; ring wrap - the only boundary work
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
  IFNDEF NXB_QUIET
    ld hl, (vidRingDepth)        ; RING= row: minimum frame-top depth
    ld de, (vidRingMin)
    or a
    sbc hl, de
    jr nc, .nomin
    ld hl, (vidRingDepth)
    ld (vidRingMin), hl
.nomin:
  ENDIF
 ENDIF
    call .served
    ret nc
 IFDEF DEBUG
  IFNDEF NXB_QUIET
    ld hl, (vidRingUnder)        ; one event per gated frame
    inc hl
    ld (vidRingUnder), hl
  ENDIF
 ENDIF
.fill:
    call vid_prod_step
    call vid_pace_poll           ; T10: an uncapped force-fill can
                                 ; hold for frames - keep the
                                 ; consumption integrator mod-ring-
                                 ; unambiguous (CF ignored: the debit
                                 ; against the coming frame carries)
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
    ld hl, (vidStrmRemainBlk)    ; 24-bit block remain (ceiling lift)
    ld a, (vidStrmRemainBlk+2)
    or h
    or l
    jr nz, .owe
    ld a, (vidLoopMode)
    or a
    jr nz, .owe                  ; loop: rewind pending - still owed
    ret                          ; play-once: tail drain, CF clear
.owe:
    scf
    ret

; Fragment boundary or rewind: close the window, next filemap run, reopen.
; CF set = fault, A = VID_ERR_SHORT (map exhausted) / VID_ERR_CMD;
; CF clear = HL = the fresh run's blocks. Corrupts AF, BC, DE, HL.
vid_run_walk_h:
    call vid_win_close_h         ; CMD12
    call vid_next_run_h
    ld a, VID_ERR_SHORT          ; map exhausted with blocks owed
    ret c
    call vid_win_open_h          ; CMD18 at the fresh run's cursor
    ld a, VID_ERR_CMD
    ret c
    ld hl, (vidStrmRunBlkH)      ; the fresh run's count
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
    ld a, (vidStrmRemainBlk+2)   ; 24-bit blocks (ceiling lift): a low
    or a                         ; word of 0 with the high byte set is
    jr nz, .have                 ; not "fully streamed"
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
    ld a, (vidTotalBlk+2)
    ld (vidStrmRemainBlk+2), a
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
    call vid_run_walk_h          ; fragment boundary / producer rewind
    jr c, .fault
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
    ld hl, (vidStrmRemainBlk)    ; 24-bit block remain (> 0 here)
    ld a, h
    or l
    jr z, .remb                  ; low word 0: borrow the high byte
.remd:
    dec hl
    ld (vidStrmRemainBlk), hl
    ret
.remb:
    ld a, (vidStrmRemainBlk+2)
    dec a
    ld (vidStrmRemainBlk+2), a
    jr .remd                     ; HL = 0 -> dec -> $FFFF
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
  IFNDEF NXB_QUIET
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

; Multiface disable/restore, streaming half. NR $06 audio-chip-mode
; note: see vid_mf_disable - the same %11110111 mask, same verdict.
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
    ld hl, 512                   ; RESIDENT: the BYTE cursor past the
    ld a, (vidStreaming)         ; header block. STREAMING: the file
    or a                         ; cursor counts BLOCKS (ceiling lift),
    jr z, .fp0                   ; so block 1. DIRECT: unused.
    ld hl, 1
.fp0:
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
    ld bc, 1
    call vid_depth_debit         ; depth -= 1, floored (DEPTH FLOOR, 3c
                                 ; hardening: the loop-tail underflow
                                 ; class dies here structurally)
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
    ld a, (vidTotalBlk+2)
    ld (vidStrmRemainBlk+2), a
    ld hl, 0
    call vid_ds_blkopen          ; run 0 reopened + the header block
    jp vid_ds_pad                ; discard all 512 header bytes

; =====================================================================
; DIRECT-SERVE DECODE (SP15 3c) - the header hint's delivery mode:
; literal-heavy (raw-equivalent) streams are served STRAIGHT from the
; SD wire to the Layer 2 surface, v1-style - no ring, no RAM pass.
; Composition: the whole decode runs the ALWAYS-SLOW op path
; (vid_fetch vectored to vid_ds_byte; SKIP/RUN reuse the shared
; dest-side chunked bodies via the SMC exits; COPY literals through
; the unrolled-ini transport port->surface below; PAL via its stub slot,
; KSTART's exit via vid_op_kstart.next, FEND/KFLIP's via vid_term_exit, all
; patched per session). HL is the open block's remaining byte count for the
; entire armed session phase (frame sections are 512-aligned, so it
; is 0 at every section boundary). The CMD18 window is hot property
; exactly as in streaming (THIRD RULE); the filemap runs/fragment
; boundaries reuse the producer's own hot machinery
; (vid_win_open/close_h + vid_next_run_h). Bounds (rubric 6): every
; block open decrements the whole-pass remain (0 = corrupt payload,
; abort) and counts against the per-frame section bound
; (cap + apad + 1 blocks, staged at open) - a corrupt payload cannot
; read unboundedly; the token/R1 polls carry the settled bounds.
; TRANSPORT IS CPU-BOUND (measured): the unrolled-ini transport replaced
; inir here because the inir arms measured 26.75 T/B against 19.55 T/B
; for a 32x-unrolled ini block over the same open CMD18 window, and the
; SD data-token wait is only ~96 T/block (~3.1% of the glue) - refuting
; the "wire-bound by design" assumption. DMA-from-SPI was
; measured-rejected: the ini arms stay <= 256B and IRQ-open (ini accepts
; an interrupt between instructions exactly as inir does between
; iterations), so the audio ISR is never starved.
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
 IFDEF DEBUG
  IFNDEF NXB_QUIET
    ld a, (vidRlDiv)             ; PLAY= clock, same divider as
    dec a                        ; vid_dst_norm_*: one blkopen per 512 B
    ld (vidRlDiv), a             ; of ds wire bounds the UNCAPPED ds
    call z, vid_rl_poll          ; chunk that vid_dst_norm_* cannot
  ENDIF
 ENDIF
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
    ld hl, (vidStrmRemainBlk)    ; whole-pass accounting (24-bit
    ld a, h                      ; blocks since the ceiling lift; the
    or l                         ; borrow arm is out of line, so the
    jr z, .remb                  ; per-block path costs nothing extra)
.remd:
    dec hl
    ld (vidStrmRemainBlk), hl
    ld hl, (vidStrmRunBlkH)
    ld a, h
    or l
    jr nz, .rundec
    call vid_run_walk_h          ; fragment boundary / rewind resume
    jr c, .fault
    ; HL = run count on both arms: vid_run_walk_h ends by reloading it
.rundec:
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
.remb:
    ld a, (vidStrmRemainBlk+2)
    or a
    jr z, .ovr                   ; truly 0: reading past the file
    dec a
    ld (vidStrmRemainBlk+2), a
    jr .remd                     ; HL = 0 -> dec -> $FFFF
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
; SILICON CONSTRAINT: reads spaced below the SD shifter's restart
; interval can return without consuming a wire byte - a sub-15T read
; train (an 11T computed-entry unroll tried here) is measured to fail
; on hardware (ERR=FD/VID_ERR_TOKEN at a section boundary after a pad).
; Proven spacings are >= 15T (blkopen's CRC pair) and the 16T ini train
; (vid_sd_blk_h / bench DTI); the measured wire floor is ~21-22 T/B
; regardless, so a sub-16T pad buys nothing even where it works. This
; routine uses the byte loop (~37 T/B CPU, wire-bound in practice) for
; that reason. The T8 xfer unroll below KEEPS its win: its ini train is
; the silicon-proven DTI shape.
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

; Transfer BC bytes from the stream to (DE): computed-entry
; unrolled-ini arms <= 256 bytes, interrupts open throughout (ini
; accepts an IRQ between instructions exactly as inir did between
; iterations - the audio ISR rides through the arms unchanged). In:
; HL = block remain, DE = dest, BC = count. Out: DE advanced, HL
; updated, BC = 0. Corrupts AF.
; T8 primitive swap (NXBD-measured): the old inir arms ran 26.75 T/B
; while the identical open CMD18 window served the 32x-unrolled ini
; block shape at 19.55 T/B - the transport is CPU-bound, not
; wire-bound, so this is the doc 08/04 computed-entry kernel idiom
; (vid_fill_cpu/vid_copy_ldi's own shape) pointed at the SD port:
; ini 16T/B + 14T per 32-byte pass + the arm entry.
; ~5.1KB payload + ~28.5KB raw-equivalent frames make this the
; measured 7.19 ms/frame recovery.
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
    ld a, b                      ; clip n to 256 (one transport arm)
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
    ; --- the computed-entry unrolled-ini arm (header note) ---
    ld c, a                      ; C = n low, scratch across the entry
    neg
    and 31                       ; (32 - r) & 31: r = 0 -> full block
    add a, a                     ; entry = blk + 2 * (32 - r)
    add a, low vid_ds_iblk
    ld (.ie+1), a                ; low-byte SMC (page-asserted below)
    ld a, c
    dec a
    rrca
    rrca
    rrca
    rrca
    rrca
    and 7
    inc a                        ; A = passes = ((n-1) mod 256)/32 + 1
                                 ; (1..8; n = 256 -> 8)
    ld c, PORT_SPI_DAT           ; ini port (B is ini's own scrap -
                                 ; rubric 2, exactly as vid_sd_blk_h)
    ex de, hl                    ; HL = dest (ini writes (HL))
.ie:
    jp vid_ds_iblk               ; low byte SMC-patched
    ALIGN 64
vid_ds_iblk:
    DUP 32
      ini
    EDUP
    dec a
    jp nz, vid_ds_iblk
    ex de, hl                    ; HL = block remain, DE = dest'
    pop bc                       ; remaining
    jp vid_ds_xfer.loop
    ASSERT (low vid_ds_iblk) <= 256-64

; Direct COPY body: dest-normalized chunks (column hop + window seam
; via the shared walkers), each served by the unrolled-ini transport.
; No 256-byte chunk cap here - that cap is the DMA DI-bracket contract
; (contract 3), and this transport holds no DI at all (the ini arms
; are internally <= 256 and IRQ-open). In: BC = literal count.
vid_ds_copy_body:
    ld (vidRemain), bc
.seg:
    ld bc, (vidRemain)
    ld a, b
    or c
    jp z, vid_ds_next
.dn:
    call vid_dst_norm_flat       ; SMC _flat/_gap; preserves BC, HL
.cd:
    call vid_chunk_dst_nocap_flat ; BC = min(remain, dest/column room)
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

; Direct terminal tail: the shared KFLIP/FEND handlers reach here through
; vid_term_exit; discards the section pad, A = terminal op.
vid_ds_done:
    push af
    call vid_ds_pad              ; discard to the block boundary
    pop af
    ret                          ; A = terminal, to the frame loop

; Direct audio feed (T10): the ds chunk transport lives INSIDE
; vid_aud_pump (the vidDirect dispatch there) - the wire holds the
; CMD18 stream mid-block across pump calls via vidDsAudBlkRem, and
; the section pad is discarded once, at feed completion. No separate
; ds copy routine remains.

; ---------------------------------------------------------------------
; Hot cells.
; ---------------------------------------------------------------------
vidLoopMode:     db 0            ; 0 = play once, 1 = loop

; Header-derived parameter block - staged by vid_stage_common as ONE
; MMU6-translated LDIR from its cold twin on VID_PAGE2. ORDER AND SIZES
; MUST MATCH vidP_HeightB..vidP_FileEnd exactly (VIDP_LEN asserted there).
vidHeightB:      db 0            ; height byte (0 = 256)
vidGapFlag:      db 0            ; 1 = mode-1 letterbox (column gaps).
                                 ; Both are STAGING cells only - the
                                 ; decode path reads the per-session
                                 ; SMC copies vid_stage_common patches
                                 ; from vidP_HeightB / vidP_GapFlag
vidDstPages:     db 0            ; dest surface span: 10 (mode-1) / 6
vidABytes:       dw 0            ; REAL audio bytes/frame
vidABytesPad:    dw 0            ; = (real + 511) & ~511 (wire block)
vidFrames:       dw 0            ; container frame count
vidFileEnd:      ds 3            ; file size in 512-byte BLOCKS (24-bit
                                 ; == last frame's rounded payload end;
                                 ; blocks, not bytes, for the 8GB reach
                                 ; - see CEILING LIFT above)

; Resident ring (source): allocated pool banks, in load order. The
; seam walker derives page = bank*2 + parity, so only banks are
; listed (80 bytes hot instead of 160).
vidRingBankCnt:  db 0
vidRingBanks:    ds VID_RING_MAX

; Decode session state.
vidFramePos:     ds 3            ; linear file position of the current
                                 ; frame section (24-bit). RESIDENT: a
                                 ; BYTE offset into the RAM image (the
                                 ; ring bounds it at 1.25MB, and
                                 ; vid_src_seek/vid_aud_pump need byte
                                 ; granularity). STREAMING: 512-byte
                                 ; BLOCKS (ceiling lift). DIRECT: unused
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
vidApadBlk:      db 0            ; audio section blocks (1..6 - the
                                 ; NXV_AUD_FRAME_MAX 3072 bound is
                                 ; PINNED to keep this <= 6; see the
                                 ; .inc's block-arithmetic derivation)
vidWalkMax:      db 0            ; per-seek source page-walk bound
vidSrcWalks:     db 0
vidRingPageCnt:  db 0            ; cnt * 2 (producer wrap modulus)
vidWrPageLin:    db 0            ; producer write cursor: ring page +
vidWrOfs:        dw 0            ; offset (0..$1FFF, 512-aligned)
vidTotalBlk:     ds 3            ; whole-file blocks (producer rewind;
                                 ; 24-bit since the ceiling lift - the
                                 ; 16-bit form capped a file at 32MB)
vidStrmRemainBlk: ds 3           ; blocks still to stream this pass
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

; --- circular audio feed cells (SP17 T10) ---
vidAudWr:        dw 0            ; ring write cursor (absolute; wraps
                                 ; at vidAudBuf + NXV_AUD_RING)
vidAudRdPrev:    dw 0            ; pace integrator: previous read-
                                 ; pointer snapshot (IX is live)
vidPaceRem:      dw 0            ; bytes of audio still to consume
                                 ; before the next frame releases
                                 ; (16-bit signed; <= 0 = released)
vidAudFeedRem:   dw 0            ; staged frame's audio bytes still
                                 ; to fetch into the ring
vidAudBudget:    dw 0            ; vid_aud_pump per-call byte budget
vidDsAudBlkRem:  dw 0            ; ds feed: open block remain carried
                                 ; across resumable pump chunks

; Circular play feed (T10) - the ISR free-runs IX around the whole
; NXV_AUD_RING; the pump writes behind it (NXV_AUD_FRAME_MAX bounds
; the header field at open). 3c: the buffer lives in the session's
; AUDIO BANK, pinned at MMU3 for the whole armed window (VID_AUD_WIN
; - the hot-page reclaim; see the FOURTH RULE in the file header).
; The ring is the WHOLE bank now, so the assert below is tight: it
; ends flush at the MMU3 window top and nothing else lives in the page
; (bank_alloc hands it out exclusively, nxv2_open_body .audbok).
vidAudBuf        equ VID_AUD_WIN
    ASSERT NXV_AUD_BUF_MAX <= $2000
    ASSERT NXV_AUD_RING == NXV_AUD_BUF_MAX

; Entry/exit symmetry captures (hot pair only - MMU6/7 are written
; hot pre-hop and read hot in .restore_tail; every other vidSv* cell
; is touched exclusively by the cold entry/l2setup/restore bodies and
; moved to VID_PAGE2 in the 3c reclaim - dropping their bracket
; translations with them).
vidSvMmu6:       db 0
vidSvMmu7:       db 0
; Sampled channels that were LOOPING when this session started, bit 0 =
; channel 1, bit 1 = channel 2 (SP18 item 7 auto-resume). Hot for the
; same reason the pair above is: written pre-hop in vid_run, read in
; .restore_tail. ZEROED WHEN CONSUMED - the same idempotent sentinel
; vidSnapCnt uses, and what keeps the DEBUG standalone bench modes
; (which reach .restore_tail without ever running vid_run's capture -
; see nxb_reclaim) from resuming a previous session's effect.
vidSvSfxRes:     db 0
vidSvHook:       db 0            ; HOOK_XBN|HOOK_CYC bits suspended for the clip, zeroed when consumed

 IFDEF DEBUG
; DEBUG session-report state. vidTlFrames..vidLoopPass is zeroed at
; session start (l2setup body); vidTlFillFrames sits AFTER the zero
; span (it is written by nxv2_open_body BEFORE the wipe runs) and
; inside the report's copy span. The cells must stay contiguous and in
; this exact order (the LDIR + indexed access), and any change here
; must be mirrored EXACTLY in the page-local block at the foot of
; VID_PAGE2 - the ASSERT there is what enforces it.
;
; The tick-based phase timeline this block used to carry is gone
; (vidTlTicks/LastTick/LastPhase/Acc, the vidLn* raster sums,
; vid_tl_stamp and its five frame-loop call sites): it measured phase
; occupancy in video-CTC ISR ticks, which the PLAY= banner below
; explains is structurally blind to a suppressed interrupt - the
; instrument itself proved to be the artifact (vid_rl_poll merging ~1
; edge per 8 polls), inflating every per-phase figure. PLAY= replaced
; it on that strength and is what survives here. Do not reintroduce a
; tick-derived wall measurement without reading vid_rl_poll's divider
; first.
vidTlFrames:     dw 0            ; delivered frames (FRM=); counted by
                                 ; vid_play_frame, once per frame
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
; PLAY= wall-clock instrument (see vid_rl_poll). Inside the report copy
; span, OUTSIDE the zero span - vidRlDiv/vidRlLast/vidRlFields are
; staged by the l2setup body with the rest of the session, and the
; PLAY cells must survive the wipe for the same reason.
vidRlDiv:        db 1            ; decode/ds poll divider (counts down)
vidRlLast:       dw 0            ; previous raster line (9-bit)
vidRlFields:     dw 0            ; free-running 50Hz field count
vidPlayArmed:    db 0            ; 0 until the first frame is DELIVERED
vidPlayStart:    dw 0            ; field count at the first frame
vidPlayEnd:      dw 0            ; field count at teardown
vidNomStep:      dw 0            ; nominal fields per frame, 8.8 fixed
vidNomAcc:       ds 3            ; nominal fields accumulator, 8.8
VID_TL_ZERO_LEN  equ vidLoopPass + 1 - vidTlFrames
VID_TL_BLOCK_LEN equ vidNomAcc + 3 - vidTlFrames
; SPIN-side poll divider: vid_pace_poll (the .pace/.ffin/.drainlast/
; ring-gate wait-loop sites) and vid_aud_pump's .next chunk loop both
; called vid_rl_poll on EVERY pass; poll density that high measurably
; costs CTC ticks, while the decode path, already divided 1-in-16 via
; vidRlDiv, loses ~0. This cell applies the same VID_RL_DIV = 16 divider
; to the two SPIN sites, sharing one budget between them (mirrors
; vidRlDiv, shared between vid_dst_norm_* and vid_ds_blkopen) and reset
; by vid_rl_poll alongside vidRlDiv.
;
; SAFETY FLOOR: vid_rl_poll infers a field wrap from a 9-bit raster
; DECREASE, so a poll must land at least once per field (the shortest
; field, 48K timing's 20 ms) or PLAY undercounts. A spin pass is ~0.4 ms
; streamed (faster resident), so 16 passes between polls is a worst case of
; 16 x 0.4 ms = ~6.4 ms streamed - inside the 20 ms floor with ~3x
; margin (20 / 6.4 ~ 3.1x). Not applied to the decode-path divider
; either (vidRlDiv, unchanged).
;
; This cell sits AFTER vidNomAcc, outside VID_TL_BLOCK_LEN (the
; report's mirrored span) - nothing reads it for the report, so it
; needs no page-local mirror entry; it only drives a poll/no-poll
; decision. Zeroed (seeded to 1, like vidRlDiv) with the other PLAY=
; cells at session init.
vidRlSpinDiv:    db 1            ; SPIN poll divider (counts down);
                                 ; shares the VID_RL_DIV cadence and
                                 ; the vid_rl_poll reset with vidRlDiv
vid_tl_report:
    ld hl, vid_tl_report_body
    jp vid_hop2                  ; push HL (the body), map VID_PAGE2
vid_tl_report_ret:
    ret

; =====================================================================
; NXB - player-path silicon bench. DEBUG builds only; Release carries
; none of it (byte-identity is a commit-time gate).
; NXB_QUIET image: FRM=, PLAY=, NOM=, TOK= and the RING= counters are not measured.
; Instrument (raster frame clock, raw-count rows, the F/D reporting
; convention, the flags+250 mode entry) points every measured loop at
; the PRODUCTION routines - vid_ds_blkopen / vid_ds_pad / vid_ds_xfer /
; vid_sd_blk_h / vid_stub / vid_copy_ldi / vid_fill_cpu / vid_copy_dma /
; vid_fill_dma are CALLED, never re-implemented. The bench lives HERE,
; on VID_PAGE, because those routines are MMU7-resident on this page
; and no other page can reach them.
; NXB_PAGE (DEBUG bank 47, MMU6) holds the tables and untimed session code
; entered through nxb_hop6. Anything that decodes, pumps, produces, seeks,
; maps MMU6 or runs inside a measured window stays on VID_PAGE.
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
;   1 direct-serve frames and transport - session mode 1, DS1 (nxb_ds_rows).
;   2 op dispatch envelope - the shipping vid_stub / NXVNEXT path.
;   3 COPY kernel across the size distribution real streams produce
;     (census: COPY p50 = 1-5 B, 61-99% of COPY ops are 1-8 B).
;   4 fill crossover + the DMA DI-window margin.
;   5 COPY path pairs (fast-handler LDI vs body + DMA) for
;     NXV2_COPY_DMA_MIN.
;   6 group 5's pairs and the chunk rows on the gapped surface.
;   7 long multi-chunk COPY16 ops, in window and across one dest seam.
;   8 rows at a simulated NXV2_COPY_DMA_MIN of 59.
;   9 the long-clock calibration row, DMA chunk tails and 16-bit entries.
;  10 COPY path pairs on the gapped surface at height 144.
;  11 RUN path pairs (CPU fill against DMA), flat and gapped.
;  12 events: dest-edge bails, SKIP body passes, a dest seam, columns.
; SESSION MODES (flags+248, nxb_sess) ride a staged clip at vid_run's hook:
;   1 DS1 (direct: frame sweeps, then the transport rows), 2 REAL (real
;   frames, audio, the frame loop, the producer, an armed pass), 3 SYN and
;   4 SYS (synthetic frames written into a resident / streaming clip).
;
; STANDALONE MODES (2-12) synthesize their op streams into a pool bank
; at MMU6 and paint a second pool bank at MMU2 - NOT Layer 2, so no
; display state is disturbed and no session is needed. Streams are
; sized so the source cursor never reaches $DF00 (vid_src_next is never
; exercised) and the dest cursor stays in the 8K window, except rows at
; dest codes 1-3, which may take one vid_dst_next into the dest bank's
; second page.
; vidDecSp is anchored at entry: a structural fault therefore unwinds
; into the ordinary abort path and prints ERR= rather than hanging.
; =====================================================================

NXB_ROW0         equ 8       ; bench rows start here (the timeline
                             ; report owns 24-29)
NXB_BLANK_ROWS   equ 21      ; entry blanks text rows 8-28
NXB_LINE_MSB     equ $1E     ; active video line, bit 8
NXB_LINE_LSB     equ $1F     ; active video line, bits 7:0
NXB_MID_DST      equ $5000   ; geo dest code 1 (gapped: column $50)
NXB_EDGE_DST     equ $5F00   ; geo dest code 2 (gapped: column $5F)
NXB_SEAM_DST     equ $5F80   ; geo dest code 3, flat rows only
    ASSERT (low NXB_MID_DST) == 0 && (low VID_DST_WIN) == 0
    ASSERT (low NXB_EDGE_DST) == 0
NXB_MODE_FIRST   equ 2       ; standalone modes, nxbTabDir order
NXB_MODE_LAST    equ 12
NXB_MODE_LOG     equ 15      ; the log step (nxb_log, NXB_PAGE)
NXB_TAB_MAX      equ 560     ; nxbTabBuf: every table asserts it fits
NXB_ROW_LEN      equ 12      ; ds 4 tag, db opc, dw count, db ops,
                             ; dw reps, db thr, db geo
NXB_OPC_CAL      equ $FF     ; row opcode: the long-clock calibration row
NXB_LINE_OFS     equ $64     ; NR $64 line offset (the clock basis needs 0)
NXB_LC_LO        equ 8       ; long clock read window: lines 8-239, clear
NXB_LC_HI        equ 239     ; of the frameCounter tick at line 248
NXB_CAL_POLLS    equ 15      ; CAL body: raster polls per rep
NXB_CAL_SPAN     equ 12      ; CAL body: 256-pass djnz loops per poll
    ; one poll gap at 28 MHz (+1 wait per fetch/read): 3863 T a loop plus
    ; about 400 T of poll; at least one poll every 1/8 field
    ASSERT NXB_CAL_SPAN * 3863 + 400 < 311 * 1824 / 8
NXB_SROW_LEN     equ 10      ; session row: ds 4 tag, db kind, dw param,
                             ; dw reps, db thr
NXB_YROW_LEN     equ 25      ; SYNTH row: ds 4 tag, db kind, dw reps, d24 frame,
                             ; db preset, then two sites
NXB_YSITE1       equ 11      ; the first site: d24 offset, db length, ds 3 bytes
    ASSERT NXB_YSITE1 == 4 + 1 + 2 + 3 + 1 && NXB_YROW_LEN == NXB_YSITE1 + 2 * 7
NXB_SESS_LAST    equ 4       ; session modes 1..NXB_SESS_LAST (nxbSessDir)
NXB_SESS_ROWS    equ 16      ; session rows per column (rows 8-23)
NXB_SESS_COL2    equ 40      ; the second column
NXB_RUN_REF      equ 71      ; RUN select for the session decode rows
NXB_CELLS_LEN    equ 12      ; the decode start cells (nxb_cells_get)
NXB_SLOT         equ 3 + NXB_CELLS_LEN   ; top-3 slot: dw lines, db index, cells
; Session row kinds; NXB_K_STRM marks a streaming-only row.
NXB_K_ID         equ 0
NXB_K_RING       equ 1
NXB_K_REMN       equ 2
NXB_K_SCAN       equ 3
NXB_K_SWEEP      equ 4
NXB_K_FRAME      equ 5
NXB_K_AUD        equ 6
NXB_K_PACE       equ 7
NXB_K_LOOP       equ 8
NXB_K_ARM        equ 9
NXB_K_DISARM     equ 10
NXB_K_PROD       equ 11
NXB_K_DSWEEP     equ 12
NXB_K_DSBLK      equ 13
NXB_K_DSKIP      equ 14
NXB_K_SYNTH      equ 15      ; the SYNTH kinds are the NXB_YROW_LEN rows
NXB_K_SYNTH_NOCALL equ 16
NXB_K_COUNT      equ 17
NXB_K_STRM       equ $80
    ASSERT NXB_K_SYNTH_NOCALL == NXB_K_COUNT - 1 && NXB_K_STRM == $80
    ; nxb_aud_body/nxb_lp_pace put the writer half a ring ahead of IX with xor
    ASSERT vidAudBuf == $6000 && NXV_AUD_RING == $2000

; ---------------------------------------------------------------------
; Entry from nxb_trampoline (debug.asm, EXTERN vector 12). Mode in
; flags+250 (self-clearing, the established stage-ladder convention).
; Modes 2-12 run standalone; direct-serve is session mode 1 (flags+248, nxb_sess).
; Mode 15 (the log step) is tested first: no blank, bank or table.
; Order: blank, stage the table (NXB_PAGE at MMU6 for the copy only),
; allocate the row banks, walk the table. Corrupts everything.
; ---------------------------------------------------------------------
nxb_entry:
    ld hl, flags+250
    ld a, (hl)
    ld (hl), 0
    ld (nxbMode), a
    cp NXB_MODE_LOG
    jr z, .log
    ld (vidDecSp), sp            ; abort anchor for the standalone
                                 ; modes (block header). The direct
                                 ; rows keep vid_run's own anchor -
                                 ; theirs is a live session's.
    call nxb_blank
    ld a, (nxbMode)
    sub NXB_MODE_FIRST
    cp NXB_MODE_LAST - NXB_MODE_FIRST + 1
    jr c, .stage
    xor a                        ; unknown mode: the dispatch table
.stage:
    call nxb_tab_stage
    ld a, NXB_ROW0
    ld (nxbRow), a
    call nxb_ops_setup
    jr c, .nobank
    ld hl, nxbTabBuf
    call nxb_run_table
    jp nxb_ops_restore
.nobank:
    ld hl, nxbMsgBank            ; setup may already hold one bank -
    call nxb_fail_row            ; the restore frees whatever it took
    jp nxb_ops_restore
.log:
    ld hl, nxb_log
    jp nxb_hop6

; Blank text rows NXB_ROW0-28 across the tilemap. Corrupts everything.
nxb_blank:
    ld a, (tmCols)
    ld e, a
    ld d, NXB_BLANK_ROWS
    ld bc, NXB_ROW0 << 8         ; B = top row, C = column 0
    jp tm_clear_blank

; Copy table A (an nxbTabDir index) into nxbTabBuf. MMU6 holds NXB_PAGE
; for the copy only and is put back before the return (rubric 3: the
; directory and tables are NXB_PAGE labels). Corrupts AF, BC, DE, HL.
nxb_tab_stage:
    ld c, a                      ; nr_read preserves BC
    ld e, NR_MMU6
    call nr_read
    push af                      ; the caller's MMU6
    nextreg NR_MMU6, NXB_PAGE
    ld a, c
    add a, a
    add a, a                     ; 4-byte directory entries
    ld hl, nxbTabDir
    add hl, a
    ld e, (hl)
    inc hl
    ld d, (hl)
    inc hl
    ld c, (hl)
    inc hl
    ld b, (hl)                   ; BC = length, 1..NXB_TAB_MAX (asserted,
    ex de, hl                    ; so never the BC = 0 LDIR - rubric 2)
    ld de, nxbTabBuf
    ldir
    pop af
    nextreg NR_MMU6, a
    ret

; ---------------------------------------------------------------------
; Standalone setup: two pool banks (source stream / paint target), the
; decode loop's session cells staged flat, the per-session SMC slots
; pointed at the RAM set (a previous video session may have left the
; direct-serve set; geometry is per row, nxb_geo_setup), the terminal
; exit diverted to nxb_term (vid_dec_done's file-position accounting is
; meaningless with no session; vid_op_fend's plain path still runs), and
; the zxnDMA WR1/WR2/WR5 one-time program sent (the shipping vidDmaInit
; lives on VID_PAGE2, unreachable from here - nxbDmaInit below is its
; 6-byte twin).
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
    ld (nxbSessLive), a
    ; per-session SMC: RAM fetch, RAM bodies
    ld hl, vid_fetch_ram
    ld (vid_fetch.vec + 1), hl
    ld hl, vid_next
    ld (vid_skip_body.next + 1), hl
    ld (vid_run_body.next + 1), hl
    ld (vid_op_kstart.next + 1), hl
    ld hl, vid_copy_body
    ld (vid_slow_op.cj + 1), hl
    ld hl, nxb_term              ; FEND -> the bench terminal (through
    ld (vid_term_exit + 1), hl   ; vid_op_fend's plain path, vidInSpan = 0)
    ld hl, nxbDmaInit
    ld bc, (nxbDmaInit_len << 8) | DMA_PORT
    otir
    or a
    ret

; Undo the setup: the terminal exit back to vid_dec_done, then the
; shared reclaim. The other SMC slots are re-patched by every video
; open, so they are left as staged (the same rule the player's own
; vid_stage_common follows).
nxb_ops_restore:
    ld hl, vid_dec_done
    ld (vid_term_exit + 1), hl
    ; falls into nxb_reclaim

; Shared standalone reclaim - called on the CLEAN exit above and from
; vid_dec_abort_pos on a structural fault (review fix). nxbBankCnt is
; the ownership flag and is zeroed here, so the routine is idempotent
; and a plain video session's own abort runs it as a no-op (the six
; RUN/COPY select and nxb_ops_body.dst operands are rewritten ahead of
; the ownership test, so every exit leaves their shipping values).
; The abort case ALSO has to stage vidSvMmu6/vidSvMmu7: the standalone
; modes never went through vid_run, so those cells hold a previous
; session's values (or none), and vid_run.restore_tail - which the
; abort chain reaches - would otherwise map two arbitrary pages and
; leave MMU7 off VID_PAGE for the ret that follows.
; A live session is ended here too: the LOOP row's frame-loop operands go
; back, and vidDecSp takes the session anchor so an abort unwinds to the hook.
nxb_reclaim:
    call nxb_lp_unpatch
    ld a, (nxbSessLive)
    or a
    jr z, .nosess
    xor a
    ld (nxbSessLive), a
    ld hl, (nxbSessSp)
    ld (vidDecSp), hl
.nosess:
    ld bc, (NXV2_RUN_DMA_MIN << 8) | NXV2_COPY_DMA_MIN
    call nxb_sel_set
    ld hl, VID_DST_WIN
    ld (nxb_ops_body.dst), hl
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

; The bench's frame terminal: vid_term_exit's operand points here
; instead of vid_dec_done. The op loop keeps the stack level between ops,
; so this ret returns straight to nxb_row's `call nxb_body`.
nxb_term:
    ret

; ---------------------------------------------------------------------
; Row table walker. HL = a staged table (nxbTabBuf); NXB_ROW_LEN rows:
;   ds 4 tag, db opcode, dw count, db ops-per-rep, dw reps, db thr, db geo
; ended by a zero first tag byte. thr: nxb_sel_row. geo: nxb_geo_setup;
; an invalid code prints the row as NXB GEO and runs nothing.
; Operands, geometry and stream are set per row, untimed.
; ---------------------------------------------------------------------
nxb_run_table:
    ld a, (hl)
    or a
    ret z                        ; end of table
    ld (nxbTag), hl              ; tag: 4 bytes in the buffer
    add hl, 4
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
    ld c, (hl)                   ; thr
    inc hl
    ld a, (hl)                   ; geo
    inc hl
    ld (nxbGeo), a
    push hl
    ld a, (nxbOpc)
    ASSERT NXB_OPC_CAL == $FF
    inc a
    jr nz, .oprow
    call nxb_cal                 ; count/ops/thr/geo unused
    jr .next
.oprow:
    call nxb_sel_row
    call nxb_geo_setup
    jr c, .badgeo
    call nxb_build
    ld hl, nxb_ops_body
    ld (nxb_body + 1), hl
    call nxb_row
.next:
    pop hl
    jr nxb_run_table
.badgeo:
    call nxb_at
    call nxb_puttag
    ld hl, nxbMsgGeo
    call dbg_puts
    jr .next

; Kernel select operands for one row (untimed). C = the row's thr, the
; opcode in nxbOpc. RUN8/RUN16 rows put thr in the RUN select (0 =
; NXV2_RUN_DMA_MIN), COPY8/COPY16 rows in the COPY select (0 =
; NXV2_COPY_DMA_MIN); the other select, and both for any other opcode,
; take the shipping value. Corrupts AF, BC.
nxb_sel_row:
    ld b, NXV2_RUN_DMA_MIN
    ld a, (nxbOpc)
    cp VOP_RUN8
    jr z, .run
    cp VOP_RUN16
    jr z, .run
    cp VOP_COPY8
    jr z, .copy
    cp VOP_COPY16
    jr z, .copy
    ld c, NXV2_COPY_DMA_MIN
    jr nxb_sel_set
.run:
    ld a, c
    or a
    jr z, .runship
    ld b, a
.runship:
    ld c, NXV2_COPY_DMA_MIN
    jr nxb_sel_set
.copy:
    ld a, c
    or a
    jr nz, nxb_sel_set
    ld c, NXV2_COPY_DMA_MIN
    ; falls into nxb_sel_set

; B = RUN select, C = COPY select, into all six operands. Corrupts A.
nxb_sel_set:
    ld a, b
    ld (vf_op_run8.rthr), a
    ld (vg_op_run8.rthr), a
    ld (vid_run_body.rthr), a
    ld a, c
    ld (vf_op_copy8.thr), a
    ld (vg_op_copy8.thr), a
    ld (vid_copy_body.thr), a
    ret

; Per-row surface geometry (untimed), from nxbGeo:
;   bit 0 gapped; bits 3:2 gapped height 192/144/72 (3 invalid);
;   bits 5:4 dest start VID_DST_WIN/NXB_MID_DST/NXB_EDGE_DST/NXB_SEAM_DST;
;   bits 7:6 and 1 zero; a gapped row may not use dest code 3 (E = 0).
; CF set = invalid, nothing written. Corrupts AF, BC, HL.
nxb_geo_setup:
    ld a, (nxbGeo)
    ld c, a
    and $C2
    scf
    ret nz                       ; reserved bits
    ld a, c
    rrca
    rrca
    and 3                        ; height code
    cp 3
    ccf
    ret c
    ld hl, nxbGeoH
    add hl, a
    ld b, (hl)                   ; B = height
    ld a, c
    swapnib
    and 3                        ; dest code
    bit 0, c
    jr z, .dcode
    cp 3
    ccf
    ret c                        ; gapped at NXB_SEAM_DST
.dcode:
    add a, a
    ld hl, nxbGeoDst
    add hl, a
    ld a, (hl)
    inc hl
    ld h, (hl)
    ld l, a
    ld (nxb_ops_body.dst), hl
    or a                         ; CF clear: valid (LD leaves F alone)
    bit 0, c
    jr nz, .gap
    ld hl, vf_op_skip8
    ld (vid_stub + VOP_SKIP8 + 1), hl
    ld hl, vf_op_run8
    ld (vid_stub + VOP_RUN8 + 1), hl
    ld hl, vf_op_copy8
    ld (vid_stub + VOP_COPY8 + 1), hl
    ld hl, vid_dst_norm_flat
    ld (vid_skip_body.dn + 1), hl
    ld (vid_run_body.dn + 1), hl
    ld (vid_copy_body.dn + 1), hl
    ld (vid_ds_copy_body.dn + 1), hl
    ld hl, vid_chunk_dst_nocap_flat
    ld (vid_skip_body.cd + 1), hl
    ld (vid_ds_copy_body.cd + 1), hl
    ld hl, vid_chunk_dst_flat
    ld (vid_run_body.cd + 1), hl
    ld (vid_chunk_all.dj + 1), hl
    ret
.gap:
    ld hl, vg_op_skip8
    ld (vid_stub + VOP_SKIP8 + 1), hl
    ld hl, vg_op_run8
    ld (vid_stub + VOP_RUN8 + 1), hl
    ld hl, vg_op_copy8
    ld (vid_stub + VOP_COPY8 + 1), hl
    ld a, b                      ; the row's height
    ld (vg_op_skip8.hcmp + 1), a
    ld (vg_op_skip8.hsub + 1), a
    ld (vg_op_skip8.hcmp2 + 1), a
    ld (vg_op_run8.hcmp + 1), a
    ld (vg_op_run8.hsub + 1), a
    ld (vg_op_run8.hcmp2 + 1), a
    ld (vg_op_copy8.hcmp + 1), a
    ld (vg_op_copy8.hsub + 1), a
    ld (vg_op_copy8.hcmp2 + 1), a
    ld (vid_dst_norm_gap.h1 + 1), a
    ld (vid_chunk_dst_gap.h1 + 1), a
    ld (vid_chunk_dst_nocap_gap.h1 + 1), a
    ld hl, vid_dst_norm_gap
    ld (vid_skip_body.dn + 1), hl
    ld (vid_run_body.dn + 1), hl
    ld (vid_copy_body.dn + 1), hl
    ld (vid_ds_copy_body.dn + 1), hl
    ld hl, vid_chunk_dst_nocap_gap
    ld (vid_skip_body.cd + 1), hl
    ld (vid_ds_copy_body.cd + 1), hl
    ld hl, vid_chunk_dst_gap
    ld (vid_run_body.cd + 1), hl
    ld (vid_chunk_all.dj + 1), hl
    ret

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
.dst equ $+1                     ; SMC: nxb_geo_setup per row, nxb_reclaim
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
    ; A2 bracket opens HERE, after nxbL1 is already latched: the
    ; measured window is closed before either half of it runs.
    call nxb_tm_in
    call nxb_at
    call nxb_puttag
    ld a, (nxbOps)
    ld hl, (nxbFrames)
    call nxb_ofrd
    jp nxb_tm_out
nxb_body:
    jp 0                         ; SMC: the row's per-rep body

; Print " O=hh R=hhhh F=hhhh D=hhhh": A = O, HL = F, R = nxbReps -
; nxbLeft, D = nxbL1 - nxbL0 (two's complement). Corrupts everything.
nxb_ofrd:
    push hl
    push af
    ld hl, nxbMsgO
    call dbg_puts
    pop af
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
    pop hl
    call dbg_hex16
    ld hl, nxbMsgD
    call dbg_puts
    ld hl, (nxbL1)
    ld de, (nxbL0)
    or a
    sbc hl, de
    jp dbg_hex16

; Long clock (+3 timing, NR $64 = 0): line 0 is vc 64, stepping at hc 124;
; frameCounter ticks at vc 1 hc 126, 8 T into line 248. Start: wait for
; lines 8-239, then fc0, then line0 (nxbL0, HL). Corrupts AF, BC, DE, HL.
nxb_lc_start:
    xor a
    ld (nxbLcBad), a
    call nxb_lc_wait
    ld hl, (frameCounter)
    ld (nxbFc0), hl
    call nxb_line
    ld (nxbL0), hl
    ret

; End: line1 (nxbL1), then fc1 at once at lines 8-239, else after the wait.
; nxbLcF = F = fc1 - fc0 - [line1 in 240-310], $FFFF after a wait timeout.
; Corrupts AF, BC, DE, HL.
nxb_lc_end:
    call nxb_line
    ld (nxbL1), hl
    ld a, h
    or a
    jr nz, .late                 ; 256-310
    ld a, l
    cp NXB_LC_HI + 1
    jr nc, .late                 ; 240-255
    cp NXB_LC_LO
    call c, nxb_lc_wait          ; 0-7
    ld hl, (frameCounter)
    jr .f
.late:
    call nxb_lc_wait
    ld hl, (frameCounter)
    dec hl
.f:
    ld de, (nxbFc0)
    or a
    sbc hl, de
    ld a, (nxbLcBad)
    or a
    jr z, .ok
    ld hl, $FFFF
.ok:
    ld (nxbLcF), hl
    ret

; Poll the raster until lines NXB_LC_LO-NXB_LC_HI, at most 65536 polls
; (about 30 fields): a timeout sets nxbLcBad instead of hanging. Corrupts
; AF, BC, DE, HL.
nxb_lc_wait:
    ld de, 0
.poll:
    push de
    call nxb_line
    pop de
    ld a, h
    or a
    jr nz, .next
    ld a, l
    sub NXB_LC_LO
    cp NXB_LC_HI - NXB_LC_LO + 1
    ret c
.next:
    dec de
    ld a, d
    or e
    jr nz, .poll
    dec a
    ld (nxbLcBad), a
    ret

; CAL row: nxbReps reps of nxb_cal_body on the long clock. The wrap count
; (nxbFrames) is seeded with line0, spans every rep and closes on line1:
; CALL (O = NR $11) and CALR (O = NR $64) print the same F and D.
nxb_cal:
    ld hl, (nxbReps)
    ld (nxbLeft), hl
    ld hl, 0
    ld (nxbFrames), hl
    call nxb_lc_start
    ld (nxbPrev), hl             ; the wrap counter's seed: line0
.rep:
    call nxb_cal_body
    ld hl, (nxbLeft)
    dec hl
    ld (nxbLeft), hl
    ld a, h
    or l
    jr nz, .rep
    call nxb_lc_end
    ld hl, (nxbL1)
    call nxb_tick.cmp            ; the final compare against line1
    call nxb_at
    call nxb_puttag
    ld e, NR_VIDEO_TIMING
    call nr_read
    ld hl, (nxbLcF)
    call nxb_ofrd
    call nxb_at
    ld hl, nxbTagCALR
    call dbg_puts
    ld e, NXB_LINE_OFS
    call nr_read
    ld hl, (nxbFrames)
    jp nxb_ofrd

; About 1.25 fields: NXB_CAL_POLLS x (NXB_CAL_SPAN 256-pass djnz loops,
; then nxb_tick). Corrupts AF, BC, DE, HL.
nxb_cal_body:
    ld e, NXB_CAL_POLLS
.poll:
    ld c, NXB_CAL_SPAN
.span:
    ld b, 0
.d:
    djnz .d
    dec c
    jr nz, .span
    push de
    call nxb_tick                ; nxb_line takes D
    pop de
    dec e
    jr nz, .poll
    ret

; Cursor to the next bench row, column 0. Corrupts AF, BC.
nxb_at:
    ld a, (nxbRow)
    ld b, a
    inc a
    ld (nxbRow), a
    ld c, 0
    jp dbg_at

; Print the 4-byte tag at (nxbTag). Corrupts AF, BC, DE, HL.
nxb_puttag:
    ld hl, (nxbTag)
    ld b, 4
.ch:
    ld a, (hl)
    inc hl
    push bc
    push hl
    call dbg_putc
    pop hl
    pop bc
    djnz .ch
    ret

; ---------------------------------------------------------------------
; A2 - MMU3 PRINT BRACKET (session rows only).
; vid_run_l2setup_body borrows MMU3 ($6000-$7FFF) for the session audio
; window and only restores it at teardown, and VID_AUD_WIN IS TM_MAP -
; so every cell tm_putc_at writes during a session row lands in the
; audio bank and is thrown away with it. Put the real tilemap page back
; for the PRINT and take it away again immediately after.
; Both halves run OUTSIDE every measured window (every row opens the
; bracket only after its clock has closed), so no row's raster delta can
; see either of them. Mapping a different page into the SAME slot is
; timing-neutral in any case.
; The standalone rows never borrowed MMU3 -
; nxb_ops_setup zeroes nxbSessLive, which gates both halves to a no-op.
; nxbSvTm3 is captured hot in vid_run; nxbSvAud3 in nxb_sess_setup.
; Corrupts AF; preserves BC, DE, HL.
; ---------------------------------------------------------------------
nxb_tm_in:
    ld a, (nxbSessLive)
    or a
    ret z
    ld a, (nxbSvTm3)
    nextreg NR_MMU3, a
    ret
nxb_tm_out:
    ld a, (nxbSessLive)
    or a
    ret z
    ld a, (nxbSvAud3)
    nextreg NR_MMU3, a
    ret

; D1 - the direct-serve bench selector must never outlive the run that
; set it: a stuck flags+248 diverts the NEXT VDIR/VDIRL/DPACE/DPACL into
; the bench instead of playing. nxb_sess_setup self-clears on the taken
; path; this is what the bails call. Corrupts AF.
nxb_ds_unsel:
    xor a
    ld (flags+248), a
    ret

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
.cmp:                            ; HL = a line read elsewhere (nxb_cal)
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
; ROW GROUP 1 - DIRECT-SERVE (session mode 1, table DS1).
; The hook fires after a good open and BEFORE the audio preload and CTC
; arm: the CMD18 window is open at frame 0's audio block, vidDsCrcDue is
; 0 and the run/pass counters are live. DSKP reads frame 0 untimed, DSWP/ADSW
; sweep frames 1-32 off the wire; the DT rows then consume real blocks.
; Playback is REPLACED.
;
; THE DECOMPOSITION (each transport row is one term):
;   DTI0 = vid_ds_blkopen + 512 raw ini  = crc + book + tok + 512*wire + ovh
;   DTB0 = vid_ds_blkopen + vid_ds_pad   = crc + book + tok + pad512 + ovh
;   DTC0 = vid_ds_blkopen + xfer(512)    = crc + book + tok + xfer512 + ovh
;   DTD0 = vid_ds_blkopen + 4 x xfer(128)
; so DTB0 - DTI0 = vid_ds_pad's excess over a bare ini (the byte loop,
; expected positive), DTC0 - DTI0 = vid_ds_xfer's chain and arm entry over
; the same 32x-ini shape, DTD0 - DTC0 = 2 extra arms and 3 extra entries.
; Every rep opens one block, so blkopen's own terms cancel.
;
; CRC ORDER RULE: vidDsCrcDue is wire truth and is never reset here. A
; row that reads through vid_ds_blkopen consumes a pending CRC itself; a
; row that bypasses it may only run where the flag is 0. Every DS1 row
; reads through blkopen (the sweeps via vid_ds_byte and vid_ds_xfer).
; =====================================================================
NXB_DS_REPS      equ 128     ; blocks per transport row

; --- the four transport bodies (nxb_kind_dsblk param 0-3) ---
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

; =====================================================================
; SESSION BENCH (flags+248). vid_run's hook anchors vidDecSp and calls
; nxb_sess. nxb_sess_setup (NXB_PAGE) sets the entry state and stages the
; mode's table; nxb_srow_next loads each row and nxb_srow_go runs it, its
; kinds jumping to the timed loops below. Every exit reaches
; vid_run.restore and nxb_reclaim.
; =====================================================================

; Call HL on NXB_PAGE: MMU6 maps NXB_PAGE, then gets the caller's page back.
; Out: the callee's F, BC, DE, HL. Corrupts A and E on entry.
nxb_hop6:
    ld e, NR_MMU6
    call nr_read                 ; preserves HL
    push af
    nextreg NR_MMU6, NXB_PAGE
    call .go
    ex (sp), hl                  ; H = the saved MMU6
    ld a, h
    nextreg NR_MMU6, a           ; F kept: NEXTREG has no ALU save in the core
    pop hl
    ret
.go:
    jp (hl)

; Mode 1 (DS1): the per-frame section bound lifted for the visit (the
; transport rows' block runs are not frame sections), then the table.
nxb_ds_rows:
    ld a, 255
    ld (vidDsBound), a
    jr nxb_sess_walk

; Out: NC = a direct session, DS1 staged (the hook runs nxb_ds_rows); CF = done.
nxb_sess:
    ld hl, nxb_sess_setup
    call nxb_hop6                ; NC direct; C and Z mismatch; C and NZ table
    ret nc
    ret z
    ; falls into nxb_sess_walk

; Walk the staged table: nxb_srow_next loads a row (Z and C at the
; terminator), nxb_srow_go runs it. Corrupts everything.
nxb_sess_walk:
    ld hl, nxb_srow_next
    call nxb_hop6
    ret z
    ld hl, nxb_srow_go
    call nxb_hop6
    jr nxb_sess_walk

; DSBLK (from nxb_kind_dsblk): the transport bodies land in the hidden Layer 2
; surface's first page, never displayed and restored by the teardown.
nxb_ds_go:
    ld a, (l2BackBank)
    add a, a
    nextreg NR_MMU6, a
    ; falls into nxb_lrow

; nxbReps reps of nxb_body on the long clock, then the row print. Entered
; from a kind that set nxb_body and nxbSO.
nxb_lrow:
    ld hl, (nxbReps)
    ld (nxbLeft), hl
    call nxb_lc_start
.rep:
    call nxb_body
    ld hl, (nxbLeft)
    dec hl
    ld (nxbLeft), hl
    ld a, h
    or l
    jr nz, .rep
    call nxb_lc_end
    ld hl, nxb_sprint
    jp nxb_hop6

; AUD rep: S0 cursors, the writer half a ring ahead of the reader (an armed
; reader moves on before the pump reads it), then .qnext's stage and pump.
nxb_aud_body:
    ld hl, nxbS0
    call nxb_cells_put
.feed:                           ; DSWEEP: the live cursors
    push ix
    pop hl
    ld a, h
    xor high (NXV_AUD_RING / 2)
    ld h, a
    ld (vidAudWr), hl
    call vid_aud_stage
    ld bc, $FFFF
    call vid_aud_pump
    ret

; FRAME and SYNTH rep: the chosen frame's start cells, then its decode.
nxb_frame_body:
    ld hl, nxbCells
    call nxb_cells_put
    jp vid_decode_any

; SYNTH-NOCALL rep: the start cells alone (NUL0: the frame body without
; the decode call).
nxb_nul_body:
    ld hl, nxbCells
    jp nxb_cells_put

; The decode start cells: vidFramePos, the span cells, vidRingRl and
; vidRingDepth. nxb_cells_put: HL = 12-byte buffer -> the cells.
; nxb_cells_get: the cells -> DE. Corrupts F, BC, DE, HL.
nxb_cells_put:
    ld de, vidFramePos
    ld bc, 3
    ldir
    ld de, vidInSpan
    ld c, 4
    ldir
    ld de, vidRingRl
    ld c, 3
    ldir
    ld de, vidRingDepth
    ld c, 2
    ldir
    ret
nxb_cells_get:
    ld hl, vidFramePos
    ld bc, 3
    ldir
    ld hl, vidInSpan
    ld c, 4
    ldir
    ld hl, vidRingRl
    ld c, 3
    ldir
    ld hl, vidRingDepth
    ld c, 2
    ldir
    ret
    ASSERT vidSpanDE + 2 - vidInSpan == 4 && 3 + 4 + 3 + 2 == NXB_CELLS_LEN

; Frame walk stop test. CF = stop: nxbWLeft is 0, or a streaming ring holds
; less than FRAMECAP plus the audio blocks. Else nxbWLeft -= 1.
; Corrupts AF, DE, HL.
nxb_wstop:
    ld hl, (nxbWLeft)
    ld a, h
    or l
    scf
    ret z
    ld a, (vidStreaming)
    or a
    jr z, .go
    ld hl, (vidRingDepth)
    inc hl
    ld de, (vidNeedBlk)          ; cap + apad + 1
    sbc hl, de                   ; CF clear from or a
    ret c
    ld hl, (nxbWLeft)
.go:
    dec hl
    ld (nxbWLeft), hl
    ret

; Audio skip: the cursors vid_aud_pump's completion leaves - the real bytes
; as its chunks add them, then its own .ramdone. Corrupts AF, BC, DE, HL.
nxb_askip:
    ld bc, (vidABytes)
    ld a, (vidStreaming)
    or a
    jr nz, .strm
    ld hl, (vidFramePos)
    add hl, bc
    ld (vidFramePos), hl
    jr nc, .done
    ld hl, vidFramePos+2
    inc (hl)
    jr .done
.strm:
    ld hl, (vidRingRl)
    add hl, bc
    ld a, (vidRingRl+2)
    adc a, 0
    call vid_rl_mod
.done:
    jp vid_aud_pump.ramdone

; SWEEP: the frame walk under one long clock (from nxb_kind_sweep).
nxb_sweep_run:
    call nxb_lc_start
.f:
    call nxb_wstop
    jr c, .end
    call nxb_askip
    call vid_decode_any
    jr .f
.end:
    call nxb_lc_end
    ld hl, nxb_walk_done
    jp nxb_hop6

; DSWEEP: the direct frame walk on one long clock from the live wire position,
; each frame's audio staged and pumped off the wire before its decode.
nxb_dsw_run:
    call nxb_lc_start
.f:
    call nxb_wstop
    jr c, nxb_sweep_run.end
    call nxb_aud_body.feed
    call vid_decode_any
    jr .f

; DSKIP (silent, from nxb_srow_go): one DSWEEP frame outside any clock.
nxb_kind_dskip:
    call nxb_aud_body.feed
    jp vid_decode_any

; SCAN: each frame's decode alone on the long clock; nxb_scan_keep keeps
; the three longest (from nxb_kind_scan).
nxb_scan_run:
    call nxb_wstop
    jr c, .end
    call nxb_askip
    ld de, nxbCells
    call nxb_cells_get
    call nxb_lc_start
    call vid_decode_any
    call nxb_lc_end
    ld hl, nxb_scan_keep
    call nxb_hop6
    jr nxb_scan_run
.end:
    ld hl, nxb_scan_done
    jp nxb_hop6

; SYNTH (from nxb_kind_synth): the row's site bytes swapped into the clip,
; its reps on nxb_lrow, then the same swap puts the clip's bytes back.
nxb_syn_run:
    call nxb_syn_sites
    call nxb_lrow
    ; falls into nxb_syn_sites

; Swap both sites of the SYNTH row at nxbTag with the clip. A site is d24 offset,
; db length 0-3, ds 3 bytes: the offset goes to the source cursor (nxbSynCur)
; and vid_src_seek maps it. Corrupts everything but IX.
nxb_syn_sites:
    ld hl, (nxbTag)
    ld bc, NXB_YSITE1
    add hl, bc
    call .site
.site:
    ld de, (nxbSynCur)
    ld bc, 3
    ldir
    ld b, (hl)                   ; length
    inc hl
    push hl
    inc b
    dec b
    jr z, .next
    push bc
    call vid_src_seek            ; HL = the window cursor, MMU6 mapped
    pop bc
    pop de
    push de
.sw:
    ld a, (de)
    ld c, (hl)
    ld (hl), a
    ld a, c
    ld (de), a
    inc hl
    inc de
    djnz .sw
.next:
    pop hl
    inc hl
    inc hl
    inc hl                       ; the next site
    ret

; LOOP: open the clock and run the shipping frame loop, its pace call and
; loop-back jump patched by nxb_kind_loop.
nxb_lp_go:
    call nxb_lc_start
    jp vid_run.frameloop

; vid_run.pacecall target: IX into vidAudRdPrev, the writer half a ring
; ahead, released at once.
nxb_lp_pace:
    push ix
    pop hl
    ld (vidAudRdPrev), hl
    ld a, h
    xor high (NXV_AUD_RING / 2)
    ld h, a
    ld (vidAudWr), hl
    scf
    ret

; vid_run.loopj target: back to the frame loop until nxbLoopLeft reaches 0;
; then close the clock, unpatch, re-anchor vidDecSp, restore the L2 roles, print.
nxb_lp_next:
    ld hl, nxbLoopLeft
    dec (hl)
    jp nz, vid_run.frameloop
    call nxb_lc_end
    call nxb_lp_unpatch
    ld hl, (nxbSessSp)
    ld (vidDecSp), hl
    ld hl, nxb_loop_done
    jp nxb_hop6

; The frame loop's shipping pace call and loop-back jump. Corrupts HL.
nxb_lp_unpatch:
    ld hl, vid_pace_poll
    ld (vid_run.pacecall), hl
    ld hl, vid_run.frameloop
    ld (vid_run.loopj), hl
    ret

; zxnDMA WR1/WR2/WR5 one-time program - the VID_PAGE-local twin of
; vidDmaInit (VID_PAGE2, unreachable from here). Byte-for-byte the
; same six bytes; if that block ever changes, this one moves with it.
; The bench CALLS vid_copy_dma/vid_fill_dma, so it inherits the
; descriptor split and must establish the same WR1 default.
nxbDmaInit:
    db $83                       ; WR6: disable (clean slate)
    db %01010100                 ; WR1: A memory, INCREMENTING, timing
    db %00000010                 ; A cycle length 2
    db %01010000                 ; WR2: B memory, incrementing, timing
    db %00000010                 ; B cycle length 2 (no prescaler)
    db %10000010                 ; WR5: stop on end of block (one-shot)
nxbDmaInit_len equ $ - nxbDmaInit

nxbMsgO:   db " O=", 0
nxbMsgR:   db " R=", 0
nxbMsgF:   db " F=", 0
nxbMsgD:   db " D=", 0
nxbMsgBank: db "NXB NO BANK", 0
nxbMsgGeo:  db " NXB GEO", 0
nxbTagCALR: db "CALR", 0

nxbMode:     db 0
nxbRow:      db 0
nxbTag:      dw 0
nxbOpc:      db 0
nxbCnt:      dw 0
nxbOps:      db 0
nxbKind:     db 0            ; session row: kind, param, reps, thr (nxbGeo)
nxbParam:    dw 0
nxbReps:     dw 0
nxbGeo:      db 0
nxbLeft:     dw 0
nxbFrames:   dw 0
nxbPrev:     dw 0
nxbL0:       dw 0
nxbL1:       dw 0
nxbFc0:      dw 0            ; long clock: frameCounter at the start
nxbLcF:      dw 0            ; long clock: F
nxbLcBad:    db 0            ; long clock: nonzero after a wait timeout
nxbSrcBank:  db 0
nxbDstBank:  db 0
nxbDstP:     db 0
nxbBankCnt:  db 0
nxbSvMmu6:   db 0
nxbSvMmu2:   db 0
nxbSvAudEn:  db 0
nxbSvTm3:    db 0            ; A2: pre-borrow MMU3 (the real tilemap
                             ; page), captured hot in vid_run
nxbSvAud3:   db 0            ; A2: the session's borrowed audio page
nxbSessLive: db 0            ; a session is running (print bracket, exits)
nxbSessSp:   dw 0            ; the hook's SP: vid_run.restore reloads it
nxbSO:       db 0            ; session row O value
nxbWLeft:    dw 0            ; frame walk: frames still to run
nxbLoopLeft: db 0            ; LOOP row: frame loop passes still to run
nxbSynCur:   dw 0            ; SYNTH site cursor: vidFramePos, or vidRingRl streaming
nxbS0:       ds NXB_CELLS_LEN   ; decode start cells at session entry
nxbCells:    ds NXB_CELLS_LEN   ; SCAN's current frame, FRAME's chosen frame
vidPoolAtOpen: db 0          ; free pool banks before nxv2_open_body allocates
; nxb_geo_setup lookups by code: gapped height, dest start.
nxbGeoH:     db 192, 144, 72
nxbGeoDst:   dw VID_DST_WIN, NXB_MID_DST, NXB_EDGE_DST, NXB_SEAM_DST
nxbTabBuf:   ds NXB_TAB_MAX     ; the staged table (nxb_tab_stage)

; Token-poll instrument accumulators (vid_sd_tok_h, above).
vidTokPolls: dw 0
vidTokCalls: dw 0
 ENDIF

    DISPLAY "video ends at ", $, " headroom ", /D, OVL_LIMIT - $
    ASSERT $ <= OVL_LIMIT

 IFDEF DEBUG
; ---------------------------------------------------------------------
; NXB_PAGE - the DEBUG bench bank's lower 8K, at $C000. MMU6 holds it
; only inside nxb_tab_stage and nxb_hop6: tables and untimed session steps.
; ---------------------------------------------------------------------
    MMU 6, NXB_PAGE, DATA_WINDOW

; One NXB_ROW_LEN row for nxb_run_table; the ASSERT holds tags to 4 bytes.
    MACRO NXBROW tag, opc, cnt, ops, reps, thr, geo
NXB_ROW_AT defl $
      db tag
      db opc
      dw cnt
      db ops
      dw reps
      db thr, geo
      ASSERT $ - NXB_ROW_AT == NXB_ROW_LEN
    ENDM

; nxb_tab_stage index: dw table, dw length (terminator included); the
; standalone modes NXB_MODE_FIRST-NXB_MODE_LAST first, in mode order.
    MACRO NXBDIR tab, tabend
      dw tab, tabend - tab
      ASSERT tabend - tab >= 1 && tabend - tab <= NXB_TAB_MAX
      ASSERT (tabend - tab) % NXB_ROW_LEN == 1   ; rows plus one terminator
    ENDM
nxbTabDir:
    NXBDIR nxbTabOpd, nxbTabOpdEnd       ; mode 2
    NXBDIR nxbTabCpy, nxbTabCpyEnd       ; mode 3
    NXBDIR nxbTabKrn, nxbTabKrnEnd       ; mode 4
    NXBDIR nxbTabThr, nxbTabThrEnd       ; mode 5
    NXBDIR nxbTabGap, nxbTabGapEnd       ; mode 6
    NXBDIR nxbTabLong, nxbTabLongEnd     ; mode 7
    NXBDIR nxbTabNew, nxbTabNewEnd       ; mode 8
    NXBDIR nxbTabTail, nxbTabTailEnd     ; mode 9
    NXBDIR nxbTabH144, nxbTabH144End     ; mode 10
    NXBDIR nxbTabFill, nxbTabFillEnd     ; mode 11
    NXBDIR nxbTabEvt, nxbTabEvtEnd       ; mode 12
    ASSERT $ - nxbTabDir == (NXB_MODE_LAST - NXB_MODE_FIRST + 1) * 4

; ---------------------------------------------------------------------
; Row tables, at most 20 rows each (rows 8-27). Every row: ops*(header+
; body) < 7900 (source cursor stays below $DF00); flat at dest code 0,
; ops*count <= 7936; gapped, ops*count <= 31*height with E = 0 (dest
; cursor stays in the window); dest codes 1-3 may cross one dest seam.
; ---------------------------------------------------------------------
; GROUP 2 - op dispatch envelope. SK00 is the floor: SKIP8 with a zero
; count runs the fast handler and NOTHING else, so it IS the dispatch
; cost. The RU01/RU17 and CP01/CP17 pairs are the settlement's own
; joint-solve shape - the 16-byte difference gives the kernel's T/B
; and back-solves the per-op envelope. S160/R161/C161 price the
; 16-bit-operand ops, which take the slow parser and the chunked bodies.
nxbTabOpd:
    NXBROW "SK00", VOP_SKIP8, 0, 255, 64, 0, 0
    NXBROW "S160", VOP_SKIP16, 0, 255, 64, 0, 0
    NXBROW "RU01", VOP_RUN8, 1, 255, 32, 0, 0
    NXBROW "RU17", VOP_RUN8, 17, 255, 32, 0, 0
    NXBROW "CP01", VOP_COPY8, 1, 255, 32, 0, 0
    NXBROW "CP17", VOP_COPY8, 17, 255, 32, 0, 0
    NXBROW "R161", VOP_RUN16, 1, 255, 32, 0, 0
    NXBROW "C161", VOP_COPY16, 1, 255, 32, 0, 0
    db 0
nxbTabOpdEnd:
    ASSERT nxbTabOpdEnd - nxbTabOpd <= 20 * NXB_ROW_LEN + 1

; GROUP 3 - the COPY size ladder, weighted where real content lives.
; Delta-stream census (250/252-frame Sintel and Big Buck Bunny
; encodes, both geometries): COPY p50 = 1 B (BBB) to 5 B (Sintel);
; 61-99% of all COPY ops are 1-8 B; p90 = 4-38 B; p99 = 8-103 B.
; C080/C081 straddled the COPY kernel select through sitting 5 (81,
; placed at the 81.4 B break-even measured before the current
; chunk-loop shape; these two rows put the break-even at 58.8 B.
; C073/C074 found the old 74's missing +128 T/op path difference and
; were retired with it); C256 is the COPY16 bulk-repaint path (40
; keyframe ops carry 16-21% of Sintel's copied bytes).
nxbTabCpy:
    NXBROW "C001", VOP_COPY8, 1, 255, 64, 0, 0
    NXBROW "C004", VOP_COPY8, 4, 255, 64, 0, 0
    NXBROW "C008", VOP_COPY8, 8, 255, 48, 0, 0
    NXBROW "C016", VOP_COPY8, 16, 255, 48, 0, 0
    NXBROW "C038", VOP_COPY8, 38, 197, 48, 0, 0
    NXBROW "C080", VOP_COPY8, 80, 96, 64, 0, 0
    NXBROW "C081", VOP_COPY8, 81, 95, 64, 0, 0
    NXBROW "C103", VOP_COPY8, 103, 75, 64, 0, 0
    NXBROW "C256", VOP_COPY16, 256, 30, 96, 0, 0
    db 0
nxbTabCpyEnd:
    ASSERT nxbTabCpyEnd - nxbTabCpy <= 20 * NXB_ROW_LEN + 1

; GROUP 4 - fill crossover + the DMA DI window. F070/F071 straddle
; the derived RUN crossover (NXV2_RUN_DMA_MIN = 71); F063 is the CPU
; fill at the census's RUN p99 neighbourhood (every observed RUN is
; short - RUN carries 0.003-6% of painted bytes and RUN16 is never
; emitted at all, so this group is a CONFIRMATION, not a lever).
; F256/K256 are full 256-byte DMA chunks: one arm each, so the row's
; per-op T IS the DI bracket the audio ISR has to survive - the
; measured answer to the stale ~38% margin claim.
nxbTabKrn:
    NXBROW "F063", VOP_RUN8, 63, 125, 64, 0, 0
    NXBROW "F070", VOP_RUN8, 70, 112, 64, 0, 0
    NXBROW "F071", VOP_RUN8, 71, 111, 64, 0, 0
    NXBROW "F256", VOP_RUN16, 256, 30, 96, 0, 0
    NXBROW "K256", VOP_COPY16, 256, 30, 96, 0, 0
    db 0
nxbTabKrnEnd:
    ASSERT nxbTabKrnEnd - nxbTabKrn <= 20 * NXB_ROW_LEN + 1

; GROUP 5 - COPY path pairs, run back to back, at explicit select values
; wherever NXV2_COPY_DMA_MIN sits: Lnnn and D081 thr 81 (fast-handler LDI
; below 81), Dnnn thr 1 (body + DMA for every nonzero count).
nxbTabThr:
    NXBROW "L048", VOP_COPY8, 48, 157, 64, 81, 0
    NXBROW "D048", VOP_COPY8, 48, 157, 64, 1, 0
    NXBROW "L056", VOP_COPY8, 56, 136, 64, 81, 0
    NXBROW "D056", VOP_COPY8, 56, 136, 64, 1, 0
    NXBROW "L060", VOP_COPY8, 60, 127, 64, 81, 0
    NXBROW "D060", VOP_COPY8, 60, 127, 64, 1, 0
    NXBROW "L064", VOP_COPY8, 64, 119, 64, 81, 0
    NXBROW "D064", VOP_COPY8, 64, 119, 64, 1, 0
    NXBROW "L072", VOP_COPY8, 72, 106, 64, 81, 0
    NXBROW "D072", VOP_COPY8, 72, 106, 64, 1, 0
    NXBROW "L080", VOP_COPY8, 80, 96, 64, 81, 0
    NXBROW "D080", VOP_COPY8, 80, 96, 64, 1, 0
    NXBROW "D081", VOP_COPY8, 81, 95, 64, 81, 0
    db 0
nxbTabThrEnd:
    ASSERT nxbTabThrEnd - nxbTabThr <= 20 * NXB_ROW_LEN + 1

; GROUP 6 - gapped surface, height 192 (the 320x192 fixtures). GLnn/GDnn
; as group 5 but GDnn at thr = L; vg_op_copy8's fast path includes
; single-crossing inline hops. GC03/GK56/GF71/GF56: C103/K256/F071/F256.
nxbTabGap:
    NXBROW "GL48", VOP_COPY8, 48, 124, 64, 81, 1
    NXBROW "GD48", VOP_COPY8, 48, 124, 64, 48, 1
    NXBROW "GL56", VOP_COPY8, 56, 106, 64, 81, 1
    NXBROW "GD56", VOP_COPY8, 56, 106, 64, 56, 1
    NXBROW "GL60", VOP_COPY8, 60, 99, 64, 81, 1
    NXBROW "GD60", VOP_COPY8, 60, 99, 64, 60, 1
    NXBROW "GL64", VOP_COPY8, 64, 93, 64, 81, 1
    NXBROW "GD64", VOP_COPY8, 64, 93, 64, 64, 1
    NXBROW "GL72", VOP_COPY8, 72, 82, 64, 81, 1
    NXBROW "GD72", VOP_COPY8, 72, 82, 64, 72, 1
    NXBROW "GL80", VOP_COPY8, 80, 74, 64, 81, 1
    NXBROW "GD80", VOP_COPY8, 80, 74, 64, 80, 1
    NXBROW "GD81", VOP_COPY8, 81, 73, 64, 81, 1
    NXBROW "GC03", VOP_COPY8, 103, 57, 64, 81, 1
    NXBROW "GK56", VOP_COPY16, 256, 23, 96, 81, 1
    NXBROW "GF71", VOP_RUN8, 71, 83, 64, 0, 1
    NXBROW "GF56", VOP_RUN16, 256, 23, 96, 0, 1
    db 0
nxbTabGapEnd:
    ASSERT nxbTabGapEnd - nxbTabGap <= 20 * NXB_ROW_LEN + 1

; GROUP 7 - long COPY16 ops at 81: LF1K/LF4K/LF7K flat and LG1K/LG4K gapped
; in window; LFDS (flat) and LGDS (gapped) start at NXB_MID_DST (dest
; code 1) and cross the dest seam into the bank's second page.
nxbTabLong:
    NXBROW "LF1K", VOP_COPY16, 1000, 7, 64, 81, 0
    NXBROW "LF4K", VOP_COPY16, 4000, 1, 512, 81, 0
    NXBROW "LF7K", VOP_COPY16, 7680, 1, 512, 81, 0
    NXBROW "LFDS", VOP_COPY16, 7680, 1, 512, 81, $10
    NXBROW "LG1K", VOP_COPY16, 1000, 5, 64, 81, 1
    NXBROW "LG4K", VOP_COPY16, 4000, 1, 512, 81, 1
    NXBROW "LGDS", VOP_COPY16, 4000, 1, 512, 81, $11
    db 0
nxbTabLongEnd:
    ASSERT nxbTabLongEnd - nxbTabLong <= 20 * NXB_ROW_LEN + 1

; GROUP 8 - rows at a simulated NXV2_COPY_DMA_MIN of 59: E058/E059 the
; 8-bit edge, Tnnn 16-bit ops whose tail after a 240 B chunk falls either
; side of it, Unnn/V300 the same ops at 81; S299/V300/S300 gapped (192).
nxbTabNew:
    NXBROW "E058", VOP_COPY8, 58, 131, 64, 59, 0
    NXBROW "E059", VOP_COPY8, 59, 129, 64, 59, 0
    NXBROW "T298", VOP_COPY16, 298, 26, 96, 59, 0
    NXBROW "T299", VOP_COPY16, 299, 26, 96, 59, 0
    NXBROW "U300", VOP_COPY16, 300, 26, 96, 81, 0
    NXBROW "T300", VOP_COPY16, 300, 26, 96, 59, 0
    NXBROW "U320", VOP_COPY16, 320, 24, 96, 81, 0
    NXBROW "T320", VOP_COPY16, 320, 24, 96, 59, 0
    NXBROW "S299", VOP_COPY16, 299, 19, 96, 59, 1
    NXBROW "V300", VOP_COPY16, 300, 19, 96, 81, 1
    NXBROW "S300", VOP_COPY16, 300, 19, 96, 59, 1
    db 0
nxbTabNewEnd:
    ASSERT nxbTabNewEnd - nxbTabNew <= 20 * NXB_ROW_LEN + 1

; GROUP 9 - CALL first (prints CALL and CALR: long clock against the
; body's own wraps). C250-C240 and R250-R240: one tail pass plus 10 B;
; Q240-C240 and W240-R240: the 16-bit entries; P200-P071: DMA fill per B.
nxbTabTail:
    NXBROW "CALL", NXB_OPC_CAL, 0, 0, 16, 0, 0
    NXBROW "C240", VOP_COPY8, 240, 32, 64, 0, 0
    NXBROW "C250", VOP_COPY8, 250, 31, 64, 0, 0
    NXBROW "Q240", VOP_COPY16, 240, 32, 64, 0, 0
    NXBROW "R240", VOP_RUN8, 240, 33, 64, 0, 0
    NXBROW "R250", VOP_RUN8, 250, 31, 64, 0, 0
    NXBROW "W240", VOP_RUN16, 240, 33, 64, 0, 0
    NXBROW "P071", VOP_RUN8, 71, 111, 64, 0, 0
    NXBROW "P200", VOP_RUN8, 200, 39, 64, 0, 0
    db 0
nxbTabTailEnd:
    ASSERT nxbTabTailEnd - nxbTabTail <= 19 * NXB_ROW_LEN + 1   ; CAL prints 2

; GROUP 10 - COPY path pairs, gapped at height 144 (geo $05): HLnn thr 255
; (fast-handler LDI), HDnn thr 1 (body + DMA); HC03/HK56 thr 0 (the
; shipping select).
nxbTabH144:
    NXBROW "HL56", VOP_COPY8, 56, 79, 64, 255, $05
    NXBROW "HD56", VOP_COPY8, 56, 79, 64, 1, $05
    NXBROW "HL60", VOP_COPY8, 60, 74, 64, 255, $05
    NXBROW "HD60", VOP_COPY8, 60, 74, 64, 1, $05
    NXBROW "HL64", VOP_COPY8, 64, 69, 64, 255, $05
    NXBROW "HD64", VOP_COPY8, 64, 69, 64, 1, $05
    NXBROW "HL68", VOP_COPY8, 68, 65, 64, 255, $05
    NXBROW "HD68", VOP_COPY8, 68, 65, 64, 1, $05
    NXBROW "HL76", VOP_COPY8, 76, 58, 64, 255, $05
    NXBROW "HD76", VOP_COPY8, 76, 58, 64, 1, $05
    NXBROW "HL80", VOP_COPY8, 80, 55, 64, 255, $05
    NXBROW "HD80", VOP_COPY8, 80, 55, 64, 1, $05
    NXBROW "HL88", VOP_COPY8, 88, 50, 64, 255, $05
    NXBROW "HD88", VOP_COPY8, 88, 50, 64, 1, $05
    NXBROW "HL96", VOP_COPY8, 96, 46, 64, 255, $05
    NXBROW "HD96", VOP_COPY8, 96, 46, 64, 1, $05
    NXBROW "HC03", VOP_COPY8, 103, 43, 64, 0, $05
    NXBROW "HK56", VOP_COPY16, 256, 17, 96, 0, $05
    db 0
nxbTabH144End:
    ASSERT nxbTabH144End - nxbTabH144 <= 20 * NXB_ROW_LEN + 1

; GROUP 11 - RUN path pairs: FCnn/VCnn thr 241 (vid_fill_cpu takes at most
; 240 B, so 241 forces the CPU fill), FDnn/VDnn thr 1 (DMA). FC/FD flat,
; the last op ending at or below $5F00; VC/VD gapped at height 192.
nxbTabFill:
    NXBROW "FC56", VOP_RUN8, 56, 141, 64, 241, 0
    NXBROW "FD56", VOP_RUN8, 56, 141, 64, 1, 0
    NXBROW "FC60", VOP_RUN8, 60, 132, 64, 241, 0
    NXBROW "FD60", VOP_RUN8, 60, 132, 64, 1, 0
    NXBROW "FC64", VOP_RUN8, 64, 124, 64, 241, 0
    NXBROW "FD64", VOP_RUN8, 64, 124, 64, 1, 0
    NXBROW "FC68", VOP_RUN8, 68, 116, 64, 241, 0
    NXBROW "FD68", VOP_RUN8, 68, 116, 64, 1, 0
    NXBROW "FC72", VOP_RUN8, 72, 110, 64, 241, 0
    NXBROW "FD72", VOP_RUN8, 72, 110, 64, 1, 0
    NXBROW "FC76", VOP_RUN8, 76, 104, 64, 241, 0
    NXBROW "FD76", VOP_RUN8, 76, 104, 64, 1, 0
    NXBROW "VC60", VOP_RUN8, 60, 99, 64, 241, 1
    NXBROW "VD60", VOP_RUN8, 60, 99, 64, 1, 1
    NXBROW "VC68", VOP_RUN8, 68, 87, 64, 241, 1
    NXBROW "VD68", VOP_RUN8, 68, 87, 64, 1, 1
    NXBROW "VC76", VOP_RUN8, 76, 78, 64, 241, 1
    NXBROW "VD76", VOP_RUN8, 76, 78, 64, 1, 1
    db 0
nxbTabFillEnd:
    ASSERT nxbTabFillEnd - nxbTabFill <= 20 * NXB_ROW_LEN + 1

; GROUP 12 - events: Exx at NXB_EDGE_DST against Nxx at $4000 (dest-edge
; bails); S256 SKIP passes; SDS1 - S2D0 a dest seam; Jxx gapped at 72 per
; column (JC72 LDI, JD72 DMA); GS3C gapped 192, three SKIP16 passes.
nxbTabEvt:
    NXBROW "EC16", VOP_COPY8, 16, 15, 64, 0, $20
    NXBROW "NC16", VOP_COPY8, 16, 15, 64, 0, 0
    NXBROW "ER16", VOP_RUN8, 16, 15, 64, 0, $20
    NXBROW "NR16", VOP_RUN8, 16, 15, 64, 0, 0
    NXBROW "ES16", VOP_SKIP8, 16, 15, 64, 0, $20
    NXBROW "NS16", VOP_SKIP8, 16, 15, 64, 0, 0
    NXBROW "S256", VOP_SKIP16, 256, 31, 64, 0, 0
    NXBROW "S2D0", VOP_SKIP16, 256, 1, 1024, 0, 0
    NXBROW "SDS1", VOP_SKIP16, 256, 1, 1024, 0, $30
    NXBROW "JC72", VOP_COPY16, 720, 3, 128, 81, $09
    NXBROW "JD72", VOP_COPY16, 720, 3, 128, 59, $09
    NXBROW "JR72", VOP_RUN16, 720, 3, 128, 0, $09
    NXBROW "JS72", VOP_SKIP16, 720, 3, 128, 0, $09
    NXBROW "JK72", VOP_SKIP8, 200, 11, 128, 0, $09
    NXBROW "JN72", VOP_SKIP8, 60, 37, 128, 0, $09
    NXBROW "GS3C", VOP_SKIP16, 576, 10, 64, 0, $01
    db 0
nxbTabEvtEnd:
    ASSERT nxbTabEvtEnd - nxbTabEvt <= 20 * NXB_ROW_LEN + 1

; ---------------------------------------------------------------------
; SESSION STEPS - untimed, entered through nxb_hop6 (MMU6 = NXB_PAGE).
; Nothing here decodes, pumps, produces, seeks or maps MMU6: every timed
; loop is a VID_PAGE routine this code jumps to.
; ---------------------------------------------------------------------

; Session entry: the selector cleared, the entry state, S0, the mode's
; delivery check and table. Out: NC = direct, DS1 staged; C with Z = a
; mismatch, printed; C with NZ = the table is staged in nxbTabBuf.
nxb_sess_setup:
    ld hl, (vidDecSp)
    ld (nxbSessSp), hl
    ld a, (flags+248)
    ld (nxbMode), a
    xor a
    ld (flags+248), a            ; self-clearing
    inc a
    ld (nxbSessLive), a
    ld e, NR_MMU3
    call nr_read
    ld (nxbSvAud3), a            ; the session's audio page (print bracket)
    ld a, NXB_ROW0
    ld (nxbRow), a
    call nxb_tm_in
    call nxb_blank
    call nxb_tm_out
    ld ix, vidAudBuf             ; as the preload: the open leaves IX stale
    ld hl, vidAudBuf
    ld (vidAudWr), hl
    ld (vidAudRdPrev), hl
    ld hl, 0
    ld (vidAudFeedRem), hl
    ld (vidPaceRem), hl
    ld de, nxbS0
    call nxb_cells_get
    ld a, (nxbMode)
    dec a
    cp NXB_SESS_LAST
    jr nc, .bad
    ld b, a
    add a, a
    add a, a
    add a, b                     ; 5-byte directory entries
    ld hl, nxbSessDir
    add hl, a
    push hl
    call nxb_deliv
    ld hl, nxbDelivBit
    add hl, a
    ld a, (hl)
    pop hl
    and (hl)
    jr z, .bad
    inc hl
    ld e, (hl)
    inc hl
    ld d, (hl)
    inc hl
    ld c, (hl)
    inc hl
    ld b, (hl)
    ex de, hl
    ld de, nxbTabBuf
    ldir                         ; BC = 1..NXB_TAB_MAX (NXBSDIR)
    ld hl, nxbTabBuf
    ld (nxbRowNext), hl
    ld hl, vidFramePos           ; SYNTH sites: the resident byte cursor,
    ld a, (vidStreaming)         ; or the ring cursor (ring position =
    or a                         ; file offset on the first lap)
    jr z, .cur
    ld hl, vidRingRl
.cur:
    ld (nxbSynCur), hl
    ld a, (vidDirect)
    or a                         ; NC
    ret nz                       ; direct: nxb_ds_rows walks DS1
    inc a                        ; NZ
    scf
    ret
.bad:
    call nxb_tm_in
    ld bc, NXB_ROW0 << 8
    call dbg_at
    ld hl, nxbMsgSess
    call dbg_puts
    call nxb_tm_out
    xor a                        ; Z
    scf
    ret

; A = 0 resident, 1 streaming, 2 direct. Corrupts F, HL.
nxb_deliv:
    ld a, (vidDirect)
    add a, a
    ld hl, vidStreaming
    add a, (hl)
    ret
nxbDelivBit: db %001, %010, %100

; The row at nxbRowNext: nxbTag, then kind/param/reps/thr into nxbKind..nxbGeo;
; a SYNTH row keeps its fields in nxbTabBuf and takes thr 0 (the shipping
; selects). Out: Z and C at the terminator, else NZ. Corrupts AF, BC, DE, HL.
nxb_srow_next:
    ld hl, (nxbRowNext)
    ld a, (hl)
    or a
    scf
    ret z                        ; the terminator
    ld (nxbTag), hl
    ld bc, 4
    add hl, bc
    ld de, nxbKind
    ld a, (hl)
    and $7F                      ; NXB_K_STRM off
    cp NXB_K_SYNTH
    jr nc, .synth
    ld c, NXB_SROW_LEN - 4       ; B = 0
    ldir
    jr .adv
.synth:
    ld (de), a
    xor a
    ld (nxbGeo), a
    ld c, NXB_YROW_LEN - 4
    add hl, bc
.adv:
    ld (nxbRowNext), hl
    or h                         ; NZ: HL is a VID_PAGE address
    ret
    ASSERT nxbReps == nxbKind + 3 && nxbGeo == nxbKind + NXB_SROW_LEN - 5
    ASSERT nxbTabBuf >= $100 && nxbTabBuf + NXB_TAB_MAX <= $10000

; One row, nxbKind..nxbGeo loaded: a streaming-only row is skipped by a
; resident or direct session; a nonzero thr goes to the COPY selects,
; NXB_RUN_REF to the RUN selects.
nxb_srow_go:
    ld a, (nxbKind)
    rlca                         ; CF = NXB_K_STRM
    jr nc, .run
    ld b, a
    ld a, (vidStreaming)
    or a
    ret z
    ld a, b
.run:
    and $FE                      ; kind * 2
    ld hl, nxbKindTab
    add hl, a
    ld a, (hl)
    inc hl
    ld h, (hl)
    ld l, a
    ld a, (nxbGeo)               ; thr
    or a
    jr z, .go
    ld c, a
    ld b, NXB_RUN_REF
    call nxb_sel_set
.go:
    jp (hl)
nxbKindTab:
    dw nxb_kind_id, nxb_kind_ring, nxb_kind_remn, nxb_kind_scan
    dw nxb_kind_sweep, nxb_kind_frame, nxb_kind_aud, nxb_kind_pace
    dw nxb_kind_loop, nxb_kind_arm, nxb_kind_disarm, nxb_kind_prod
    dw nxb_kind_dsweep, nxb_kind_dsblk, nxb_kind_dskip, nxb_kind_synth
    dw nxb_kind_synth_nocall
    ASSERT $ - nxbKindTab == NXB_K_COUNT * 2

; Field rows: nxbSO, nxbLcF (F) and nxbReps (R) set, HL = D.
nxb_fprint:
    ld (nxbL1), hl
    ld hl, 0
    ld (nxbL0), hl
    jr nxb_sprint0
; One-shot rows: R = 0001.
nxb_sprint1:
    ld hl, 1
    ld (nxbReps), hl
nxb_sprint0:
    ld hl, 0
    ld (nxbLeft), hl
; TAG O=(nxbSO) R=nxbReps-nxbLeft F=(nxbLcF) D=nxbL1-nxbL0 on the next
; session row: rows 8-23 at column 0, then at column NXB_SESS_COL2.
nxb_sprint:
    call nxb_tm_in
    ld a, (nxbRow)
    ld b, a
    inc a
    ld (nxbRow), a
    ld c, 0
    ld a, b
    sub NXB_ROW0 + NXB_SESS_ROWS
    jr c, .at
    add a, NXB_ROW0
    ld b, a
    ld c, NXB_SESS_COL2
.at:
    call dbg_at
    call nxb_puttag
    ld a, (nxbSO)
    ld hl, (nxbLcF)
    call nxb_ofrd
    jp nxb_tm_out

; ID: O = delivery, R = vidFrames, F = width, D = the height byte.
nxb_kind_id:
    call nxb_deliv
    ld (nxbSO), a
    ld hl, (vidFrames)
    ld (nxbReps), hl
    ld hl, $0100
    ld a, (vidDstPages)
    cp 10                        ; mode-1 dest span: 320 wide
    jr nz, .w
    ld l, $40
.w:
    ld (nxbLcF), hl
    ld a, (vidHeightB)
    ld l, a
    ld h, 0
    jr nxb_fprint

; RING: O = 00, R = vidRingDepth at entry (0 resident), F = vidTlFillFrames,
; D = vidPoolAtOpen.
nxb_kind_ring:
    xor a
    ld (nxbSO), a
    ld hl, (nxbS0 + NXB_CELLS_LEN - 2)   ; S0's vidRingDepth
    ld a, (vidStreaming)
    or a
    jr nz, .s
    ld h, a
    ld l, a
.s:
    ld (nxbReps), hl
    ld hl, (vidTlFillFrames)
    ld (nxbLcF), hl
    ld a, (vidPoolAtOpen)
    ld l, a
    ld h, 0
    jp nxb_fprint

; REMN: O = 00, R = vidStrmRemainBlk's low word, F = its high byte, D = 0.
nxb_kind_remn:
    xor a
    ld (nxbSO), a
    ld hl, (vidStrmRemainBlk)
    ld (nxbReps), hl
    ld a, (vidStrmRemainBlk+2)
    ld l, a
    ld h, 0
    ld (nxbLcF), hl
    ld l, h
    jp nxb_fprint

; SCAN and SWEEP: S0, then nxbWLeft = param frames, or every frame when
; param is 0 or over vidFrames; the ret enters the walk loop.
nxb_kind_scan:
    ld hl, 0
    ld (nxbScanF), hl
    ld (nxbScanD), hl
    ld hl, nxb_scan_run
    jr nxb_walk0
; DSWEEP (direct): param frames, at most vidFrames, from the live wire position
; and span state (no S0: the wire cannot rewind).
nxb_kind_dsweep:
    ld hl, nxb_dsw_run
    push hl
    jr nxb_walk0.frames
nxb_kind_sweep:
    ld hl, nxb_sweep_run
nxb_walk0:
    push hl
    ld hl, nxbS0
    call nxb_cells_put
.frames:
    ld hl, (vidFrames)
    ld de, (nxbParam)
    ld a, d
    or e
    jr z, .set
    sbc hl, de                   ; CF clear from or e
    ld hl, (vidFrames)
    jr c, .set
    ex de, hl
.set:
    ld (nxbWLeft), hl
    ld (nxbWLim), hl
    ret

; End of a walk: O = frames walked, R = 0001.
nxb_walk_done:
    ld hl, (nxbWLim)
    ld de, (nxbWLeft)
    or a
    sbc hl, de
.so:
    ld a, l
    ld (nxbSO), a
    jp nxb_sprint1
; End of SCAN: F/D = the per-frame decode windows summed; m kept for LOOP.
nxb_scan_done:
    ld hl, (nxbScanF)
    ld (nxbLcF), hl
    ld hl, (nxbScanD)
    ld (nxbL1), hl
    ld hl, 0
    ld (nxbL0), hl
    ld hl, (nxbWLim)
    ld de, (nxbWLeft)
    or a
    sbc hl, de
    ld (nxbScanM), hl
    jr nxb_walk_done.so

; After one SCAN frame: lines = F*311 + D (a clock timeout reads $FFFF) into
; the sums and slot 3, with the frame index and nxbCells. Frame 0 fills slot 0
; and gives slots 1-2 its cells at 0 lines; later frames bubble up past shorter.
nxb_scan_keep:
    ld hl, (nxbL1)
    ld de, (nxbL0)
    or a
    sbc hl, de                   ; HL = D
    ld a, (nxbLcF+1)
    or a
    jr nz, .max
    ld a, (nxbLcF)
    ld d, a
    ld e, 311 - 256
    mul d, e                     ; Z80N: DE = F * 55
    add hl, de
    add a, h                     ; + F * 256
    ld h, a
    jr .lines
.max:
    ld hl, $FFFF
.lines:
    ld (nxbTopCur), hl
    ex de, hl
    ld hl, (nxbScanD)
    add hl, de
    ld de, 311
.div:
    or a
    sbc hl, de
    jr c, .rem
    push hl
    ld hl, (nxbScanF)
    inc hl
    ld (nxbScanF), hl
    pop hl
    jr .div
.rem:
    add hl, de
    ld (nxbScanD), hl            ; 0-310
    ld hl, (nxbWLim)
    ld de, (nxbWLeft)
    or a
    sbc hl, de
    dec hl                       ; this frame's index
    ld a, l
    ld (nxbTopCur + 2), a
    push hl
    ld hl, nxbCells
    ld de, nxbTopCur + 3
    ld bc, NXB_CELLS_LEN
    ldir
    pop hl
    ld a, h
    or l
    jr nz, nxb_top_ins
    ld hl, nxbTopCur             ; frame 0 fills every slot
    ld de, nxbTop
    ld bc, NXB_SLOT
    ldir
    ld hl, nxbTop
    ld bc, 2 * NXB_SLOT          ; overlapping: slot 0 repeats forward
    ldir
    ld hl, 0                     ; slots 1-2 keep frame 0's cells at 0 lines,
    ld (nxbTop + NXB_SLOT), hl   ; so any timed frame can bubble past them
    ld (nxbTop + 2 * NXB_SLOT), hl
    ret

; Bubble slot 3 up past every slot with fewer lines (ties stay below).
nxb_top_ins:
    ld de, nxbTopCur
.up:
    ld hl, nxbTop
    or a
    sbc hl, de
    ret z                        ; reached slot 0
    ld hl, -NXB_SLOT
    add hl, de                   ; the slot above
    push hl
    ld a, (de)
    ld c, a
    inc de
    ld a, (de)
    ld b, a                      ; BC = this frame's lines
    dec de
    ld a, (hl)
    inc hl
    ld h, (hl)
    ld l, a
    or a
    sbc hl, bc                   ; CF = the slot above is shorter
    pop hl
    ret nc
    push hl
    ld b, NXB_SLOT
.sw:
    ld a, (de)
    ld c, (hl)
    ld (hl), a
    ld a, c
    ld (de), a
    inc hl
    inc de
    djnz .sw
    pop de                       ; the frame now sits in the slot above
    jr .up

; FRAME: slot nxbParam (0 = the longest) into nxbCells, O = its index.
nxb_kind_frame:
    ld a, (nxbParam)
    ld d, a
    ld e, NXB_SLOT
    mul d, e
    ld hl, nxbTop + 2
    add hl, de
    ld a, (hl)
    ld (nxbSO), a
    inc hl
    ld de, nxbCells
    ld bc, NXB_CELLS_LEN
    ldir
    ld hl, nxb_frame_body
    jr nxb_lrow_hl

; AUD, PACE and PROD: O = 00, nxbReps reps of the body on nxb_lrow.
nxb_kind_prod:
    ld hl, 0
    ld (vidRingDepth), hl        ; the whole ring is room for the producer
    ld hl, vid_prod_step
    jr nxb_lrow0
nxb_kind_pace:
    ld hl, vid_pace_poll
    jr nxb_lrow0
nxb_kind_aud:
    ld hl, nxb_aud_body
nxb_lrow0:
    xor a
    ld (nxbSO), a
nxb_lrow_hl:
    ld (nxb_body + 1), hl
    jp nxb_lrow

; LOOP: the L2 bank roles saved (its KFLIP presents swap them); S0 and one
; audio skip, as the preload leaves it; n = param, at most frames - 1 (vidFrames,
; or SCAN's m when streaming) and at least 1; vidFramesLeft = n + 1.
nxb_kind_loop:
    ld hl, (l2FrontBank)
    ld (nxbSvL2), hl
    ld hl, nxbS0
    call nxb_cells_put
    call nxb_askip
    ld hl, (vidFrames)
    ld a, (vidStreaming)
    or a
    jr z, .cap
    ld hl, (nxbScanM)            ; streaming: with m >= n + 1 the ring gate
.cap:                            ; never produces over ring data later rows read
    dec hl                       ; the last pass stages frame n's audio
    ld de, (nxbParam)
    push hl
    or a
    sbc hl, de
    pop hl
    jr c, .n
    ex de, hl
.n:
    ld a, l
    or a
    jr nz, .n1
    inc a
.n1:
    ld (nxbLoopLeft), a
    ld (nxbSO), a
    ld l, a
    ld h, 0
    inc hl
    ld (vidFramesLeft), hl
    ld hl, 0
    ld (vidAudFeedRem), hl
    ld (vidPaceRem), hl          ; .paced sums from 0, as after a release
    ld hl, nxb_lp_pace
    ld (vid_run.pacecall), hl
    ld hl, nxb_lp_next
    ld (vid_run.loopj), hl
    jp nxb_lp_go
    ASSERT l2BackBank == l2FrontBank + 1

; End of LOOP (after its clock): the L2 bank roles back, so later span frames
; find the back bank the SCAN cells were taken on.
nxb_loop_done:
    ld hl, (nxbSvL2)
    ld (l2FrontBank), hl
    jp nxb_sprint1

; ARM: a silent ring, then vid_run's CTC start without the field-phase wait.
nxb_kind_arm:
    ld hl, vidAudBuf
    ld de, vidAudBuf + 1
    ld bc, NXV_AUD_RING - 1
    ld (hl), DAC_SILENCE
    ldir
    call nxb_ctc_rst             ; BC = AUD_CTC_PORT
    ld a, AUD_CTC_CW16
    out (c), a
    ld ix, vidAudBuf             ; before the time constant starts the timer
    ld a, (vidCtcTc)
    out (c), a
    ret
; DISARM: vid_run.restore's CTC stop and DAC park.
nxb_kind_disarm:
    call nxb_ctc_rst
    ld a, DAC_SILENCE
    out (DAC_PORT), a
    out (VID_DAC_LEFT), a
    out (VID_DAC_RIGHT), a
    out (DAC2_PORT), a
    ret
nxb_ctc_rst:
    ld bc, AUD_CTC_PORT
    ld a, AUD_CTC_RESET
    out (c), a
    out (c), a
    ret

; DSBLK (direct): nxbReps reps of the transport body param selects (0-3 =
; DTI0/DTB0/DTC0/DTD0), O = 00.
nxb_kind_dsblk:
    ld a, (nxbParam)
    add a, a
    ld hl, nxbDsBody
    add hl, a
    ld a, (hl)
    inc hl
    ld h, (hl)
    ld l, a
    ld (nxb_body + 1), hl
    xor a
    ld (nxbSO), a
    jp nxb_ds_go
nxbDsBody:   dw nxb_ds_i, nxb_ds_b, nxb_ds_c, nxb_ds_d

; SYNTH and SYNTH-NOCALL (the NXB_YROW_LEN row at nxbTag): nxbReps, O = the
; span preset, nxbCells = S0 with the frame offset (streaming: its block and
; the ring cursor there) and the preset's span cells; then nxb_syn_run.
nxb_kind_synth:
    ld hl, nxb_frame_body
    jr nxb_kind_syn
nxb_kind_synth_nocall:
    ld hl, nxb_nul_body
nxb_kind_syn:
    ld (nxb_body + 1), hl
    ld hl, nxbS0
    ld de, nxbCells
    ld bc, NXB_CELLS_LEN
    ldir
    ld hl, (nxbTag)
    ld c, 5                      ; B = 0
    add hl, bc
    ld de, nxbReps
    ld c, 2
    ldir
    ld de, nxbCells              ; vidFramePos = the frame offset
    ld c, 3
    ldir
    ld a, (vidStreaming)
    or a
    jr z, .span
    push hl
    ld hl, nxbCells
    ld de, nxbCells + 7          ; vidRingRl = the offset
    ld c, 3
    ldir
    ld hl, (nxbCells + 1)
    srl h
    rr l                         ; vidFramePos = the offset's block
    ld (nxbCells), hl
    xor a
    ld (nxbCells + 2), a
    pop hl
.span:
    ld a, (hl)                   ; the preset
    ld (nxbSO), a
    ld hl, nxbCells + 3          ; vidInSpan
    ld (hl), 0
    or a
    jp z, nxb_syn_run            ; 0: fresh
    ld (hl), 1
    inc hl
    ld a, (l2BackBank)
    add a, a
    ld (hl), a                   ; vidSpanDstPage
    inc hl
    ld (hl), low VID_DST_WIN
    inc hl
    ld (hl), high VID_DST_WIN    ; 1: vidSpanDE = $4000
    ld a, (nxbSO)
    dec a
    jp z, nxb_syn_run
    ld (hl), $58                 ; 2: $5800
    jp nxb_syn_run
    ASSERT VID_DST_WIN == $4000 && vidSpanDstPage == vidInSpan + 1 && vidSpanDE == vidInSpan + 2

nxbMsgSess:  db "NXB SESSION", 0
nxbTop:      ds 3 * NXB_SLOT    ; the three longest SCAN frames, longest first
nxbTopCur:   ds NXB_SLOT        ; the frame just scanned
nxbScanF:    dw 0               ; SCAN sums: F, and D kept below 311
nxbScanD:    dw 0
nxbWLim:     dw 0               ; frame walk: frames asked for
nxbScanM:    dw 0               ; SCAN's m, frames walked
nxbSvL2:     dw 0               ; LOOP: l2FrontBank, l2BackBank at entry
nxbRowNext:  dw 0               ; the walker's next row in nxbTabBuf

; Session modes from 1: db delivery mask (resident %001, streaming %010,
; direct %100), dw table, dw length.
    MACRO NXBSDIR mask, tab, tabend
      db mask
      dw tab, tabend - tab
      ASSERT tabend - tab >= 1 && tabend - tab <= NXB_TAB_MAX
    ENDM
nxbSessDir:
    NXBSDIR %100, nxbSesDs1, nxbSesDs1End       ; mode 1: DS1
    NXBSDIR %011, nxbSesReal, nxbSesRealEnd     ; mode 2: REAL
    NXBSDIR %001, nxbSesSyn, nxbSesSynEnd       ; mode 3: SYN
    NXBSDIR %010, nxbSesSys, nxbSesSysEnd       ; mode 4: SYS
    ASSERT $ - nxbSessDir == NXB_SESS_LAST * 5

; A session table opens with NXBSTAB (strm 1: every SYNTH frame offset is a
; 512 multiple) and closes with db 0 and an ASSERT on NXB_STAB_B + 1.
    MACRO NXBSTAB strm
NXB_STAB_B defl 0
NXB_STAB_STRM defl strm
    ENDM

; One NXB_SROW_LEN session row; kind may carry NXB_K_STRM.
    MACRO NXBSROW tag, kind, param, reps, thr
NXB_ROW_AT defl $
      db tag
      db kind
      dw param, reps
      db thr
      ASSERT $ - NXB_ROW_AT == NXB_SROW_LEN
      ASSERT (kind & ~NXB_K_STRM) < NXB_K_SYNTH
      ASSERT kind != NXB_K_DSBLK || param < 4
NXB_STAB_B defl NXB_STAB_B + NXB_SROW_LEN
    ENDM

; One NXB_YROW_LEN SYNTH row: reps, frame offset, span preset 0-2, then two
; sites (offset, length 0-3, three bytes, unused bytes 0). A site stays inside
; one 8K page and the two never overlap (nxb_syn_sites swaps them in order).
    MACRO NXBYROW tag, kind, reps, frame, preset, o1, n1, a1, b1, c1, o2, n2, a2, b2, c2
NXB_ROW_AT defl $
      db tag
      db kind
      dw reps
      d24 frame
      db preset
      d24 o1
      db n1, a1, b1, c1
      d24 o2
      db n2, a2, b2, c2
      ASSERT $ - NXB_ROW_AT == NXB_YROW_LEN
      ASSERT kind == NXB_K_SYNTH || kind == NXB_K_SYNTH_NOCALL
      ASSERT reps >= 1 && preset <= 2 && n1 <= 3 && n2 <= 3
      ASSERT (o1 & $1FFF) + n1 <= $2000 && (o2 & $1FFF) + n2 <= $2000
      ASSERT n1 == 0 || n2 == 0 || o1 + n1 <= o2 || o2 + n2 <= o1
      ASSERT !NXB_STAB_STRM || (frame & 511) == 0
NXB_STAB_B defl NXB_STAB_B + NXB_YROW_LEN
    ENDM

; DS1: direct-serve. DSKP reads frame 0 (and its PAL section) untimed; DSWP
; and ADSW sweep frames 1-16 and 17-32 (thr pins RUN 71; direct COPY has no
; select); the DT rows are the transport breakdown (ROW GROUP 1).
nxbSesDs1:
    NXBSTAB 0
    NXBSROW "IDEN", NXB_K_ID, 0, 0, 0
    NXBSROW "DSKP", NXB_K_DSKIP, 0, 0, 0
    NXBSROW "DSWP", NXB_K_DSWEEP, 16, 0, 65
    NXBSROW "ARM1", NXB_K_ARM, 0, 0, 0
    NXBSROW "ADSW", NXB_K_DSWEEP, 16, 0, 65
    NXBSROW "DSRM", NXB_K_DISARM, 0, 0, 0
    NXBSROW "DTI0", NXB_K_DSBLK, 0, NXB_DS_REPS, 0
    NXBSROW "DTB0", NXB_K_DSBLK, 1, NXB_DS_REPS, 0
    NXBSROW "DTC0", NXB_K_DSBLK, 2, NXB_DS_REPS, 0
    NXBSROW "DTD0", NXB_K_DSBLK, 3, NXB_DS_REPS, 0
    NXBSROW "ARM2", NXB_K_ARM, 0, 0, 0
    NXBSROW "ADTI", NXB_K_DSBLK, 0, NXB_DS_REPS, 0
    NXBSROW "ADTC", NXB_K_DSBLK, 2, NXB_DS_REPS, 0
    db 0
nxbSesDs1End:
    ASSERT nxbSesDs1End - nxbSesDs1 == NXB_STAB_B + 1

; REAL: real frames of the staged clip. SCAN keeps the three longest for the
; FRAME rows; W0tt sweep every frame at COPY select tt; the A and X rows
; repeat after ARM with the audio ISR live. Resident sessions stop at ALOP.
nxbSesReal:
    NXBSTAB 0
    NXBSROW "IDEN", NXB_K_ID, 0, 0, 0
    NXBSROW "RING", NXB_K_RING, 0, 0, 0
    NXBSROW "SCAN", NXB_K_SCAN, 0, 0, 65
    NXBSROW "W055", NXB_K_SWEEP, 0, 0, 55
    NXBSROW "W060", NXB_K_SWEEP, 0, 0, 60
    NXBSROW "W065", NXB_K_SWEEP, 0, 0, 65
    NXBSROW "W070", NXB_K_SWEEP, 0, 0, 70
    NXBSROW "W075", NXB_K_SWEEP, 0, 0, 75
    NXBSROW "W081", NXB_K_SWEEP, 0, 0, 81
    NXBSROW "FA65", NXB_K_FRAME, 0, 8, 65
    NXBSROW "FB65", NXB_K_FRAME, 1, 8, 65
    NXBSROW "FC65", NXB_K_FRAME, 2, 8, 65
    NXBSROW "WL16", NXB_K_SWEEP, 16, 0, 65
    NXBSROW "AUD1", NXB_K_AUD, 0, 64, 0
    NXBSROW "PACE", NXB_K_PACE, 0, 1024, 0
    NXBSROW "LOOP", NXB_K_LOOP, 16, 0, 65
    NXBSROW "ARM1", NXB_K_ARM, 0, 0, 0
    NXBSROW "A065", NXB_K_SWEEP, 0, 0, 65
    NXBSROW "XA65", NXB_K_FRAME, 0, 8, 65
    NXBSROW "XB65", NXB_K_FRAME, 1, 8, 65
    NXBSROW "XC65", NXB_K_FRAME, 2, 8, 65
    NXBSROW "AW16", NXB_K_SWEEP, 16, 0, 65
    NXBSROW "AAUD", NXB_K_AUD, 0, 64, 0
    NXBSROW "ALOP", NXB_K_LOOP, 16, 0, 65
    NXBSROW "DSRM", NXB_K_DISARM | NXB_K_STRM, 0, 0, 0
    NXBSROW "REMN", NXB_K_REMN | NXB_K_STRM, 0, 0, 0
    NXBSROW "PROD", NXB_K_PROD | NXB_K_STRM, 0, 128, 0
    NXBSROW "ARM2", NXB_K_ARM | NXB_K_STRM, 0, 0, 0
    NXBSROW "APRD", NXB_K_PROD | NXB_K_STRM, 0, 128, 0
    db 0
nxbSesRealEnd:
    ASSERT nxbSesRealEnd - nxbSesReal == NXB_STAB_B + 1

; SYN: synthetic frames in a resident clip (header bytes 24-511 are 0 = FEND).
; NUL0 is the harness floor; FE/KS/KF frame types, PAL palettes, SE source
; seams, C4K COPY16 chunks (P parity seam, B bank seam, S/D span dest), K long
; keyframe chunks; the A rows repeat armed.
nxbSesSyn:
    NXBSTAB 0
    NXBSROW "IDEN", NXB_K_ID, 0, 0, 0
    NXBSROW "RING", NXB_K_RING, 0, 0, 0
    NXBYROW "NUL0", NXB_K_SYNTH_NOCALL, 1024, 24, 0,  0, 0, 0, 0, 0,  0, 0, 0, 0, 0
    NXBYROW "FE00", NXB_K_SYNTH, 1024, 24, 0,  0, 0, 0, 0, 0,  0, 0, 0, 0, 0
    NXBYROW "FE01", NXB_K_SYNTH, 1024, 24, 1,  0, 0, 0, 0, 0,  0, 0, 0, 0, 0
    NXBYROW "KS01", NXB_K_SYNTH, 1024, 24, 0,  24, 2, $28, $20, 0,  0, 0, 0, 0, 0
    NXBYROW "KS02", NXB_K_SYNTH, 1024, 24, 0,  24, 2, $28, $00, 0,  0, 0, 0, 0, 0
    NXBYROW "KF01", NXB_K_SYNTH, 1024, 24, 1,  24, 1, $20, 0, 0,  0, 0, 0, 0, 0
    NXBYROW "PAL1", NXB_K_SYNTH, 256, 24, 0,  24, 1, $18, 0, 0,  537, 1, $00, 0, 0
    NXBYROW "PAL2", NXB_K_SYNTH, 256, 7900, 0,  7900, 1, $18, 0, 0,  8413, 1, $00, 0, 0
    NXBYROW "SE00", NXB_K_SYNTH, 1024, 7000, 0,  7000, 2, $10, $01, 0,  7003, 1, $00, 0, 0
    NXBYROW "SE01", NXB_K_SYNTH, 1024, 8000, 0,  8000, 2, $10, $01, 0,  8003, 1, $00, 0, 0
    NXBYROW "SE02", NXB_K_SYNTH, 1024, 8190, 0,  8190, 2, $10, $01, 0,  8193, 1, $00, 0, 0
    NXBYROW "C4K0", NXB_K_SYNTH, 1024, 512, 0,  512, 3, $14, $00, $10,  4611, 1, $00, 0, 0
    NXBYROW "C4KP", NXB_K_SYNTH, 1024, 6144, 0,  6144, 3, $14, $00, $10,  10243, 1, $00, 0, 0
    NXBYROW "C4KB", NXB_K_SYNTH, 1024, 14336, 0,  14336, 3, $14, $00, $10,  18435, 1, $00, 0, 0
    NXBYROW "C4KS", NXB_K_SYNTH, 1024, 512, 1,  512, 3, $14, $00, $10,  4611, 1, $00, 0, 0
    NXBYROW "C4KD", NXB_K_SYNTH, 1024, 512, 2,  512, 3, $14, $00, $10,  4611, 1, $00, 0, 0
    NXBYROW "K24K", NXB_K_SYNTH, 64, 512, 0,  512, 3, $14, $C0, $5D,  24515, 1, $00, 0, 0
    NXBYROW "K43K", NXB_K_SYNTH, 64, 512, 0,  512, 3, $14, $00, $A8,  43523, 1, $00, 0, 0
    NXBSROW "ARM1", NXB_K_ARM, 0, 0, 0
    NXBYROW "AK43", NXB_K_SYNTH, 64, 512, 0,  512, 3, $14, $00, $A8,  43523, 1, $00, 0, 0
    NXBYROW "AFE0", NXB_K_SYNTH, 1024, 24, 0,  0, 0, 0, 0, 0,  0, 0, 0, 0, 0
    NXBYROW "AC4K", NXB_K_SYNTH, 1024, 512, 0,  512, 3, $14, $00, $10,  4611, 1, $00, 0, 0
    db 0
nxbSesSynEnd:
    ASSERT nxbSesSynEnd - nxbSesSyn == NXB_STAB_B + 1

; SYS: synthetic frames in a streaming clip at 512-multiple offsets; the rows
; at offset 0 swap the magic bytes out and back.
nxbSesSys:
    NXBSTAB 1
    NXBSROW "IDEN", NXB_K_ID, 0, 0, 0
    NXBSROW "RING", NXB_K_RING, 0, 0, 0
    NXBYROW "NUL0", NXB_K_SYNTH_NOCALL, 1024, 512, 0,  0, 0, 0, 0, 0,  0, 0, 0, 0, 0
    NXBYROW "FE00", NXB_K_SYNTH, 1024, 0, 0,  0, 1, $00, 0, 0,  0, 0, 0, 0, 0
    NXBYROW "FE01", NXB_K_SYNTH, 1024, 0, 1,  0, 1, $00, 0, 0,  0, 0, 0, 0, 0
    NXBYROW "KS01", NXB_K_SYNTH, 1024, 0, 0,  0, 2, $28, $20, 0,  0, 0, 0, 0, 0
    NXBYROW "KS02", NXB_K_SYNTH, 1024, 0, 0,  0, 2, $28, $00, 0,  0, 0, 0, 0, 0
    NXBYROW "KF01", NXB_K_SYNTH, 1024, 0, 1,  0, 1, $20, 0, 0,  0, 0, 0, 0, 0
    NXBYROW "C4K0", NXB_K_SYNTH, 1024, 512, 0,  512, 3, $14, $00, $10,  4611, 1, $00, 0, 0
    NXBYROW "C4KP", NXB_K_SYNTH, 1024, 6144, 0,  6144, 3, $14, $00, $10,  10243, 1, $00, 0, 0
    NXBYROW "C4KB", NXB_K_SYNTH, 1024, 14336, 0,  14336, 3, $14, $00, $10,  18435, 1, $00, 0, 0
    NXBYROW "K24K", NXB_K_SYNTH, 64, 512, 0,  512, 3, $14, $C0, $5D,  24515, 1, $00, 0, 0
    NXBSROW "ARM1", NXB_K_ARM, 0, 0, 0
    NXBYROW "AK24", NXB_K_SYNTH, 64, 512, 0,  512, 3, $14, $C0, $5D,  24515, 1, $00, 0, 0
    NXBYROW "AFE0", NXB_K_SYNTH, 1024, 0, 0,  0, 1, $00, 0, 0,  0, 0, 0, 0, 0
    db 0
nxbSesSysEnd:
    ASSERT nxbSesSysEnd - nxbSesSys == NXB_STAB_B + 1

; ---------------------------------------------------------------------
; LOG STEP (mode 15, via nxb_hop6): "#NXB <frameCounter>" and text rows 0-31
; appended to NXBENCH.TXT, read back and compared, then LOG OK or LOG ERR xx
; on row 31. Untimed. Corrupts everything.
; ---------------------------------------------------------------------
NXB_LOG_WMODE    equ $0B     ; F_OPEN open_creat + read/write: the API append (.extract -a)
; LOG ERR xx: bits 7-5 the step below, bits 4-0 the esxDOS code (1-31), or 0 for
; a short count, a seek or size off the offset (+ bytes written), or a mismatch.
NXB_LOG_OPEN     equ $20     ; drive, open for append
NXB_LOG_END      equ $40     ; FSTAT, seek to the end
NXB_LOG_WR       equ $60     ; write
NXB_LOG_CLW      equ $80     ; close after writing
NXB_LOG_REOP     equ $A0     ; drive, reopen for read, size, seek back
NXB_LOG_RD       equ $C0     ; read
NXB_LOG_CMP      equ $E0     ; compare, final close

nxb_log:
    ld (nxbLogSp), sp            ; every failure unwinds to here
    ld hl, (frameCounter)
    ld (nxbLogFc), hl
    ld hl, 0
    ld (nxbLogLen), hl
    ld a, $FF
    ld (nxbLogH), a              ; no handle open
    ld a, NXB_LOG_OPEN
    ld (nxbLogStep), a
    call esx_getsetdrv           ; A = the default drive
    jp c, nxb_log_fail
    ld ix, nxbLogName
    ld b, NXB_LOG_WMODE
    call esx_fopen
    jp c, nxb_log_fail
    ld (nxbLogH), a
    ld hl, nxbLogStep
    ld (hl), NXB_LOG_END
    call nxb_log_size            ; nxbLogStat+7 = the size, the append offset
    ld hl, nxbLogStat + 7
    ld de, nxbLogOfs
    ld bc, 4
    ldir
    call nxb_log_seek
    ld hl, nxbLogStep
    ld (hl), NXB_LOG_WR
    ld hl, nxb_log_put
    call nxb_log_pass
    ld hl, nxbLogStep
    ld (hl), NXB_LOG_CLW
    call nxb_log_close           ; written data persists only once closed
    jp c, nxb_log_fail
    ld hl, nxbLogStep
    ld (hl), NXB_LOG_REOP
    call esx_getsetdrv
    jp c, nxb_log_fail
    ld ix, nxbLogName
    ld b, ESX_MODE_READ
    call esx_fopen
    jp c, nxb_log_fail
    ld (nxbLogH), a
    call nxb_log_size            ; the capture must end the file:
    ld hl, (nxbLogStat + 7)      ; size - offset = nxbLogLen
    ld de, (nxbLogOfs)
    or a
    sbc hl, de
    ex de, hl
    ld hl, (nxbLogStat + 9)
    ld bc, (nxbLogOfs + 2)
    sbc hl, bc
    jp nz, nxb_log_short
    ld hl, (nxbLogLen)
    or a
    sbc hl, de
    jp nz, nxb_log_short
    call nxb_log_seek
    ld hl, nxbLogStep
    ld (hl), NXB_LOG_RD
    ld hl, nxb_log_get
    call nxb_log_pass
    ld hl, nxbLogStep
    ld (hl), NXB_LOG_CMP
    call nxb_log_close
    jp c, nxb_log_fail
    xor a
    jr nxb_log_show

; A short count or a mismatch at the current step.
nxb_log_short:
    xor a
; A = the esxDOS code at the current step: close any open handle, then show.
nxb_log_fail:
    and $1F
    ld hl, nxbLogStep
    or (hl)
    ld sp, (nxbLogSp)
    ld (nxbLogErr), a
    ld a, (nxbLogH)
    inc a                        ; $FF: no handle
    call nz, nxb_log_close       ; its result is not the one reported
    ld a, (nxbLogErr)
; A = 0 (LOG OK) or the code (LOG ERR xx), on a blanked row 31.
nxb_log_show:
    push af
    ld bc, (TM_ROWS - 1) << 8
    ld d, 1
    ld a, (tmCols)
    ld e, a
    call tm_clear_blank
    ld bc, (TM_ROWS - 1) << 8
    call dbg_at
    ld hl, nxbLogMsg
    call dbg_puts
    pop af
    or a
    ld hl, nxbLogOk
    jp z, dbg_puts
    push af
    ld hl, nxbLogErrMsg
    call dbg_puts
    pop af
    jp dbg_hex8

; Seek the open handle to nxbLogOfs from the start (IXL = 0). F_SEEK returns
; BCDE = the position; any other than nxbLogOfs fails before a byte moves.
nxb_log_seek:
    ld de, (nxbLogOfs)
    ld bc, (nxbLogOfs + 2)
    ld a, (nxbLogH)
    ld ix, 0
    call esx_fseek
    jr c, nxb_log_fail
    ld hl, (nxbLogOfs)
    or a
    sbc hl, de
    jr nz, nxb_log_short
    ld hl, (nxbLogOfs + 2)
    sbc hl, bc                   ; CF = 0: the low words matched
    ret z
    jr nxb_log_short

; F_FSTAT the open handle into nxbLogStat (+7: the size, 4 B).
nxb_log_size:
    ld a, (nxbLogH)
    ld ix, nxbLogStat
    call esx_fstat
    ret nc
    jr nxb_log_fail

; Close the handle and mark it closed. Out: F_CLOSE's CF and A.
nxb_log_close:
    ld hl, nxbLogH
    ld a, (hl)
    ld (hl), $FF
    jp esx_fclose

; One pass: the header, then every non-empty row, each line built in
; nxbLogLine and handed to HL (nxb_log_put or nxb_log_get) with BC = its length.
nxb_log_pass:
    ld (.io + 1), hl
    ld hl, nxbLogHdr
    ld de, nxbLogLine
    ld bc, NXB_LOG_HDR_LEN
    ldir
    ld hl, (nxbLogFc)
    ld a, h
    call nxb_log_hex
    ld a, l
    call nxb_log_hex
    ld c, NXB_LOG_HDR_LEN + 4    ; B = 0
    call .line
    ld b, 0                      ; the row
.row:
    push bc
    ld c, 0
    call tm_cell_addr            ; HL = the row's first cell; BC, DE kept
    ld a, (tmCols)
    ld b, a
    ld de, nxbLogLine
    ld c, 0                      ; the trimmed length
.ch:
    ld a, (hl)
    ld (de), a
    inc hl
    inc hl                       ; past the attribute
    inc de
    cp GLYPH_SPACE
    jr z, .sp
    ld a, (tmCols)
    sub b
    inc a
    ld c, a                      ; the length through this character
.sp:
    djnz .ch
    inc c
    dec c
    call nz, .line               ; an empty row writes nothing
    pop bc
    inc b
    ld a, b
    cp TM_ROWS
    jr c, .row
    ret
; C = the content length (B = 0): CRLF after it, then the pass's routine.
.line:
    ld hl, nxbLogLine
    add hl, bc
    ld (hl), 13
    inc hl
    ld (hl), 10
    inc bc
    inc bc
.io:
    jp 0                         ; SMC: nxb_log_put or nxb_log_get

; A -> two hex digits at DE. Corrupts AF.
nxb_log_hex:
    push af
    swapnib
    call .nib
    pop af
.nib:
    and $0F
    add a, '0'
    cp '9' + 1
    jr c, .put
    add a, 7
.put:
    ld (de), a
    inc de
    ret

; Write BC bytes of nxbLogLine: F_WRITE's Fc=0 can still return a short BC.
nxb_log_put:
    push bc
    ld a, (nxbLogH)
    ld ix, nxbLogLine
    call esx_fwrite
    pop hl
    jp c, nxb_log_fail
    or a
    sbc hl, bc
    jp nz, nxb_log_short
    ld hl, (nxbLogLen)
    add hl, bc
    ld (nxbLogLen), hl           ; the bytes written this capture
    ret

; Read BC bytes into nxbLogRd and compare them with nxbLogLine.
nxb_log_get:
    push bc
    ld a, (nxbLogH)
    ld ix, nxbLogRd
    call esx_fread
    pop hl
    jp c, nxb_log_fail
    or a
    sbc hl, bc
    jp nz, nxb_log_short         ; EOF before the count
    ld hl, nxbLogRd
    ld de, nxbLogLine
.cmp:
    ld a, (de)
    cp (hl)
    jr nz, .bad
    inc hl
    inc de
    dec c                        ; B = 0, C = 3 to TM_COLS + 2
    jr nz, .cmp
    ret
.bad:
    ld a, NXB_LOG_CMP
    ld (nxbLogStep), a
    jp nxb_log_short

nxbLogName:   db "NXBENCH.TXT", 0
nxbLogHdr:    db "#NXB "
NXB_LOG_HDR_LEN equ $ - nxbLogHdr
nxbLogMsg:    db "LOG ", 0
nxbLogOk:     db "OK", 0
nxbLogErrMsg: db "ERR ", 0
nxbLogSp:     dw 0
nxbLogFc:     dw 0
nxbLogH:      db $FF
nxbLogStep:   db 0
nxbLogErr:    db 0
nxbLogLen:    dw 0
nxbLogOfs:    ds 4
nxbLogStat:   ds 11
nxbLogLine:   ds TM_COLS + 2
nxbLogRd:     ds TM_COLS + 2
    ASSERT TM_COLS + 2 < 256 && TM_ROWS == 32 && GLYPH_SPACE == ' '

    DISPLAY "nxb page ends at ", $, " headroom ", /D, DATA_WINDOW + $2000 - $
    ASSERT $ <= DATA_WINDOW + $2000
 ENDIF

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
; streamed frame's need + slack; the file-size arm is RETIRED by the
; ceiling lift - see vid_file_blocks); B = 4 too
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
    call data_save               ; bench RING row: the pool before any bank
    ld a, VID_PAGE               ; this session allocates
    call data_map_page
    call bank_count_free
    ld (vidPoolAtOpen + DATA_WINDOW - OVL_ORG), a
    call data_restore
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
    ; session's circular audio feed ring (vidAudBuf = $6000 - moved
    ; OFF the hot code page; the reclaim that funds the 3c features).
    ; The ring is the WHOLE 8 KB bank - it is exclusive, so all of it
    ; is usable. Allocated
    ; before the ring sizing so the delivery decision sees the
    ; reduced pool naturally. ---
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
    ; channels + rate must pair. STEREO IS THE ONLY SUPPORTED PAIRING
    ; (mono withdrawn) and this test is what enforces it:
    ; a channels = 1 header falls through cp 2 to .badu -> B = 1 ->
    ; "VID FMT?" at OPEN, before the CTC is programmed, before the ISR
    ; vector is patched and before a byte of payload is decoded. It
    ; MUST stay: without it a mono file would be accepted and played
    ; through the stereo ISR, which would interleave the single
    ; channel across both DACs at the wrong rate.
    ld a, (DATA_WINDOW + NXV2_OFF_ACHAN)
    cp 2
    jp nz, .badu
    ld de, NXV_RATE_STEREO
    ld hl, (DATA_WINDOW + NXV2_OFF_ARATE)
    or a
    sbc hl, de
    jp nz, .badu
 IFDEF DEBUG
    ; PLAY=/NOM= (DEBUG): nominal 50Hz fields per frame in 8.8 fixed
    ; point = 50*256 / fps = 128000 / (fps*10), from the header's own
    ; fps*10 byte. Long division by repeated subtraction - at most 1024
    ; passes, once per open, on the cold path. A zero/garbage fps byte
    ; leaves the step at 0, which prints NOM=0000 rather than lying.
    ld hl, 0                     ; quotient
    ld a, (DATA_WINDOW + NXV2_OFF_FPSX10)
    or a
    jr z, .nomdone
    ld c, a
    ld b, 0                      ; BC = fps*10
    ld de, 128000 % 65536
    ld a, 128000 / 65536         ; A:DE = 128000
.nomdiv:
    push hl
    ld h, d
    ld l, e
    or a
    sbc hl, bc
    ld d, h
    ld e, l
    pop hl
    jr nc, .nomstep
    dec a                        ; borrowed out of the high byte
    jp m, .nomdone               ; underflow: the quotient is complete
.nomstep:
    inc hl
    jr .nomdiv
.nomdone:
    ld (vidNomStepC), hl
 ENDIF
    ; flags: delta stream set; bit1 = the direct-serve hint - HONOURED
    ; from 3c (captured here, drives the delivery decision at
    ; .geodone); EVERY other bit is reserved-zero and REFUSED when set.
    ; bit3 (NXV2_FLAG_OCOPY) is deliberately inside that refusal since
    ; the T5a decode was withdrawn: a file carrying OCOPY payload
    ; declares bit3, so it must fail cleanly at OPEN (VID FMT?) rather
    ; than reach a decoder that no longer implements the op. Same clean
    ; refusal a pre-T5a player always gave it - forward hygiene, and the
    ; next extension inherits it.
    ld a, (DATA_WINDOW + NXV2_OFF_FLAGS)
    and %11111101                ; leave only the direct-serve hint free
    cp NXV2_FLAG_DELTA
    jp nz, .badu
    ld a, (DATA_WINDOW + NXV2_OFF_FLAGS)
    and NXV2_FLAG_DIRECT
    ld (vidHdrDirectC), a        ; 0 / NXV2_FLAG_DIRECT
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
    ; audio bytes/frame: nonzero, <= NXV_AUD_FRAME_MAX (SP17 T10
    ; circular feed: 3072 B, the largest section the streaming/direct
    ; gates' 8-bit block arithmetic admits - fps floor 10.17; two of
    ; these still fit the 8192 B ring, which is what keeps the feed
    ; one-pass at every legal fps); pad = round-up-512
    ld hl, (DATA_WINDOW + NXV2_OFF_ABYTES)
    ld a, h
    or l
    jp z, .badu                  ; zero would wrap the copy LDIR
    ld (vidP_ABytes), hl
    ld de, NXV_AUD_FRAME_MAX
    or a
    sbc hl, de
    jr c, .abok                  ; real < bound
    jp nz, .badu                 ; real > bound: overflow guard
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
    ld (vidDeliverStrm), a       ; cleared for EVERY delivery, direct
                                 ; included: the session init reads it
                                 ; to pick the file cursor's UNIT, so a
                                 ; previous session's 1 must not leak in
    ld a, (vidHdrDirectC)
    or a
    jp nz, .direct_setup
    ld a, (vidSizeHi+1)          ; CEILING LIFT: >= 16MB is no longer
    or a                         ; a refusal - it is simply far past
    jr nz, .ringmax              ; any ring, so it streams. The
    ld a, (vidSizeHi)            ; size >> 14 arithmetic below is only
    cp $20                       ; reached under 2MB, where its 24-bit
    jr c, .needcalc              ; form is exact.
.ringmax:
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
    ret                          ; 3c: plain return to the orchestrator

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
    call vid_strm_validate       ; header cap, margin, apad/need, filemap
    jp c, .fail                  ; fit + entry count; B = verdict on CF
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
    jp .loadgo

.strm_loaded:
    ; STREAMING: the CMD18 window STAYS OPEN - ownership moves to the
    ; hot producer (the cold flag is cleared below so the cold close
    ; path will not CMD12 a window it no longer owns; the esxDOS
    ; handle stays open for the session and the restore body F_CLOSEs
    ; it at teardown).
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
    ; totals: file blocks + blocks still owed this pass (24-bit
    ; blocks since the ceiling lift)
    ld hl, (vidTotalBlkC)
    ld a, (vidTotalBlkC+2)
    ld (vidTotalBlk + DATA_WINDOW - OVL_ORG), hl
    ld (vidTotalBlk+2 + DATA_WINDOW - OVL_ORG), a
    ld de, (vidRingCapBlkC)
    or a
    sbc hl, de                   ; received == ringBytes
    sbc a, 0
    ld (vidStrmRemainBlk + DATA_WINDOW - OVL_ORG), hl
    ld (vidStrmRemainBlk+2 + DATA_WINDOW - OVL_ORG), a
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
 IFDEF DEBUG
    ld hl, (vidRingCapBlkC)
    dec hl                       ; vidRingMin seed = cap - 1
 ENDIF
.handoff:                        ; DEBUG: HL = vidRingMin seed. Bracket open.
 IFDEF DEBUG
    ld (vidRingMin + DATA_WINDOW - OVL_ORG), hl
    ld hl, 0
    ld (vidRingUnder + DATA_WINDOW - OVL_ORG), hl
    xor a
    ld (vidDepthClip + DATA_WINDOW - OVL_ORG), a
 ENDIF                           ; (099 throttle lever RETIRED in 3c)
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
    call data_restore
    xor a                        ; window ownership is HOT now
    ld (vidStrmWinOpen), a
    ld b, 0                      ; verdict: loaded (streaming or direct)
    ret

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
    call vid_strm_validate
    jp c, .fail
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
    ld hl, (vidTotalBlkC)        ; 24-bit blocks (ceiling lift)
    ld a, (vidTotalBlkC+2)
    ld (vidTotalBlk + DATA_WINDOW - OVL_ORG), hl
    ld (vidTotalBlk+2 + DATA_WINDOW - OVL_ORG), a
    ld de, 1                     ; the header block is consumed
    or a
    sbc hl, de
    sbc a, 0
    ld (vidStrmRemainBlk + DATA_WINDOW - OVL_ORG), hl
    ld (vidStrmRemainBlk+2 + DATA_WINDOW - OVL_ORG), a
    ; run-cursor handoff: window OPEN one block into run 0
    ld a, (vidEntCntC)
    ld (vidStrmEntryCnt + DATA_WINDOW - OVL_ORG), a
    ld a, 1
    ld (vidStrmEntryIdx + DATA_WINDOW - OVL_ORG), a
 IFDEF DEBUG
    ld hl, 0                     ; vidRingMin seed (no ring)
 ENDIF
    jp .handoff                  ; same local scope (nxv2_open_body)

.badu:
    call data_restore            ; the parse bracket was open
.badc:
    ld b, 1                      ; verdict: bad header / bad read
    jr .fail
.toobig:
    ld b, 3                      ; verdict: no ring fits (pool below
                                 ; one streamed frame's need - the old
                                 ; ">= 16MB" arm of this verdict is
                                 ; RETIRED by the ceiling lift)
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

; HL = hot body. Push it, hop back to VID_PAGE.
vid_hop1:
    push hl
    ld a, VID_PAGE
    jp ovl_map_page

; Shared contract validation (streaming + direct). CF set = refuse,
; B = verdict (1 bad header/read, 4 too fragmented); CF clear = Total/
; Cap/Apad/Need/EntCnt staged. Corrupts AF, B, DE, HL.
vid_strm_validate:
    call vid_file_blocks         ; size -> vidTotalBlkC (blocks); CF =
    jr c, .bad                   ; not whole blocks
    ld hl, (vidHdrCapC)
    ld a, h
    or a
    jr nz, .bad
    ld a, l
    or a
    jr z, .bad
    cp NXV2_STRM_CAP_MAX+1
    jr nc, .bad
    ld (vidCapBlkC), a
    ld hl, (vidP_ABytesPad)
    ld a, h
    srl a                        ; pad >> 9 (1..6 blocks; the 3072 pin)
    ld (vidApadBlkC), a
    ld b, a
    ld a, (vidCapBlkC)
    add a, b
    inc a                        ; <= 247: no carry
    ld (vidNeedBlkC), a
    ld a, (vidTotalBlkC+2)       ; > 65535 blocks: any 16-bit margin
    or a                         ; is inside the file by construction
    jr nz, .marok
    ld hl, (vidTotalBlkC)
    ld de, (vidHdrMarginC)
    or a
    sbc hl, de
    jr c, .bad                   ; margin > file blocks: corrupt header
.marok:
    ld hl, (vidStrmEntryEnd)     ; the filemap must fit the hot copy
    ld de, vidFilemapBuf
    or a
    sbc hl, de                   ; HL = entries * 6 (<= 192)
    ld a, l
    cp VID_STRM_HOT_ENT*6+1
    jr nc, .frag
    ld b, 0
.div:
    sub 6
    jr c, .divd
    inc b
    jr .div
.divd:
    ld a, b
    ld (vidEntCntC), a
    or a                         ; the loop exits with CF set - clear it
    ret
.bad:
    ld b, 1
    scf
    ret
.frag:
    ld b, 4
    scf
    ret

; Common hot staging (both deliveries): fileEnd, the parameter block,
; ring count + bank list, DEBUG fill row, per-file SMC patches (stub
; dispatch targets, the chunk loop's geometry-selected call operands
; and the gap height immediates - written through the window,
; rubric 3). OPENS the MMU6 bracket and RETURNS WITH IT
; OPEN - the caller stages its delivery extras then closes with
; data_restore. Corrupts everything.
vid_stage_common:
    call vid_file_blocks         ; fileEnd = size in BLOCKS, the file
    ld hl, (vidTotalBlkC)        ; unit since the ceiling lift (staged
    ld (vidP_FileEnd), hl        ; with the block, one LDIR). CF is
    ld a, (vidTotalBlkC+2)       ; IGNORED here: resident never
    ld (vidP_FileEnd+2), a       ; required whole blocks, and a
                                 ; truncating >>9 reproduces its old
                                 ; byte compare exactly (the payload
                                 ; position is rounded UP to a block
                                 ; before every compare, so a ragged
                                 ; tail failed the bound then too)
    call data_save
    ld a, VID_PAGE
    call data_map_page
    ld hl, vidP_HeightB
    ld de, vidHeightB + DATA_WINDOW - OVL_ORG
    ld bc, VIDP_LEN
    ldir
    ld a, (vidRingCntC)
    ld (vidRingBankCnt + DATA_WINDOW - OVL_ORG), a
    ld hl, vidRingBanksC
    ld de, vidRingBanks + DATA_WINDOW - OVL_ORG
    ld bc, VID_RING_MAX
    ldir
 IFDEF DEBUG
    ld hl, (frameCounter)        ; FILL= row: frames since vidFillT0
    ld de, (vidFillT0)           ; (prefill / ring fill / direct probe)
    or a
    sbc hl, de
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
    ld (vid_dst_norm_gap.h1 + 1 + DATA_WINDOW - OVL_ORG), a
    ld (vid_chunk_dst_gap.h1 + 1 + DATA_WINDOW - OVL_ORG), a
    ld (vid_chunk_dst_nocap_gap.h1 + 1 + DATA_WINDOW - OVL_ORG), a
    ; chunk-loop geometry select: the call operands, not a per-chunk
    ; test (both sets patched every open - a previous file may have
    ; left the other one)
    ld hl, vid_dst_norm_gap
    ld (vid_skip_body.dn + 1 + DATA_WINDOW - OVL_ORG), hl
    ld (vid_run_body.dn + 1 + DATA_WINDOW - OVL_ORG), hl
    ld (vid_copy_body.dn + 1 + DATA_WINDOW - OVL_ORG), hl
    ld (vid_ds_copy_body.dn + 1 + DATA_WINDOW - OVL_ORG), hl
    ld hl, vid_chunk_dst_nocap_gap
    ld (vid_skip_body.cd + 1 + DATA_WINDOW - OVL_ORG), hl
    ld (vid_ds_copy_body.cd + 1 + DATA_WINDOW - OVL_ORG), hl
    ld hl, vid_chunk_dst_gap
    ld (vid_run_body.cd + 1 + DATA_WINDOW - OVL_ORG), hl
    ld (vid_chunk_all.dj + 1 + DATA_WINDOW - OVL_ORG), hl
    jr .vec
.flatset:
    ld hl, vf_op_skip8
    ld (vid_stub + VOP_SKIP8 + 1 + DATA_WINDOW - OVL_ORG), hl
    ld hl, vf_op_run8
    ld (vid_stub + VOP_RUN8 + 1 + DATA_WINDOW - OVL_ORG), hl
    ld hl, vf_op_copy8
    ld (vid_stub + VOP_COPY8 + 1 + DATA_WINDOW - OVL_ORG), hl
    ld hl, vid_dst_norm_flat
    ld (vid_skip_body.dn + 1 + DATA_WINDOW - OVL_ORG), hl
    ld (vid_run_body.dn + 1 + DATA_WINDOW - OVL_ORG), hl
    ld (vid_copy_body.dn + 1 + DATA_WINDOW - OVL_ORG), hl
    ld (vid_ds_copy_body.dn + 1 + DATA_WINDOW - OVL_ORG), hl
    ld hl, vid_chunk_dst_nocap_flat
    ld (vid_skip_body.cd + 1 + DATA_WINDOW - OVL_ORG), hl
    ld (vid_ds_copy_body.cd + 1 + DATA_WINDOW - OVL_ORG), hl
    ld hl, vid_chunk_dst_flat
    ld (vid_run_body.cd + 1 + DATA_WINDOW - OVL_ORG), hl
    ld (vid_chunk_all.dj + 1 + DATA_WINDOW - OVL_ORG), hl
.vec:
    ; --- per-session decode vectoring (3c direct-serve): the fetch
    ; vector, the shared bodies' exit jumps, slow-op's COPY body
    ; target, the PAL stub slot and the terminal exit all point at the
    ; RAM decode (resident/streaming) or the SD-stream decode (direct).
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
    ld hl, vid_op_pal
    ld (vid_stub + VOP_PAL + 1 + DATA_WINDOW - OVL_ORG), hl
    ld hl, vid_dec_done
    ld (vid_term_exit + 1 + DATA_WINDOW - OVL_ORG), hl
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
    ld hl, vid_ds_pal
    ld (vid_stub + VOP_PAL + 1 + DATA_WINDOW - OVL_ORG), hl
    ld hl, vid_ds_done
    ld (vid_term_exit + 1 + DATA_WINDOW - OVL_ORG), hl
    ret

; ---------------------------------------------------------------------
; vid_file_blocks - the CEILING LIFT's one conversion point: the
; F_FSTAT byte size -> the FILE UNIT, 512-byte BLOCKS, stored 24-bit
; to vidTotalBlkC. Every file-level cursor in the player counts blocks
; now (vidTotalBlk / vidStrmRemainBlk / vidFileEnd / the streaming
; vidFramePos), so the same 3-byte cells that capped a .VID at 16MB in
; bytes reach 8GB. No size ceiling remains in the player: F_FSTAT's own
; 32-bit byte size shifts down to at most 23 significant block bits, so
; the whole addressable file space fits with a bit to spare (what binds
; in practice is the fragment ceiling - VID_STRM_HOT_ENT extents of at
; most 65535 blocks each, VID FRAG? above that).
; Out: CF set = the size is NOT a whole number of 512-byte blocks
; (every v2 frame section is block-aligned, so a valid encode's size
; always is - this is the contract check both delivery setups used to
; inline). vidTotalBlkC is stored either way. Corrupts AF, HL.
; ---------------------------------------------------------------------
vid_file_blocks:
    ld a, (vidSizeHi+1)          ; size[31:24]
    ld h, a
    ld a, (vidSizeHi)            ; size[23:16]
    ld l, a
    ld a, (vidSizeLo+1)          ; size[15:8]
    srl h
    rr l
    rra                          ; H:L:A = size >> 9, big-endian in
    ld (vidTotalBlkC), a         ; registers - store little-endian
    ld a, l
    ld (vidTotalBlkC+1), a
    ld a, h
    ld (vidTotalBlkC+2), a
    ld a, (vidSizeLo)            ; whole-block contract check
    or a
    scf
    ret nz                       ; low byte set: not a block multiple
    ld a, (vidSizeLo+1)
    and 1
    scf
    ret nz                       ; bit 8 set: not a block multiple
    or a                         ; CF clear
    ret

nxvMagic: db "NXVID"

; Cold staging twin of the hot parameter block (order/sizes MUST
; match vidHeightB.. exactly - one LDIR stages it). Shape/Clip/Yofs
; have only cold readers on this page and are not staged.
vidP_HeightB:  db 0
vidP_GapFlag:  db 0
vidP_DstPages: db 0
vidP_ABytes:   dw 0
vidP_ABytesPad: dw 0
vidP_Frames:   dw 0
vidP_FileEnd:  ds 3
VIDP_LEN equ $ - vidP_HeightB
    ASSERT VIDP_LEN == vidFileEnd + 3 - vidHeightB
vidP_Shape:    db 0
vidP_ClipY1:   db 0
vidP_ClipY2:   db 0
vidP_Yofs:     db 0

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
vidTotalBlkC:  ds 3              ; file blocks, 24-bit (vid_file_blocks
                                 ; writes it; both setups + the common
                                 ; stager read it)
vidLoadTgt:    ds 3              ; prefill byte target (size / ring)
vidHdrCapC:    dw 0              ; header per-frame payload cap
vidHdrMarginC: dw 0              ; header ring start-margin (advisory;
                                 ; range-checked only, never a fill
                                 ; target - the prefill fills the ring)
 IFDEF DEBUG
vidNomStepC:   dw 0              ; PLAY=/NOM= nominal fields per frame
 ENDIF                            ; (8.8 fixed) - staged at open
vidCapBlkC:    db 0              ; validated cap (blocks)
vidApadBlkC:   db 0
vidNeedBlkC:   db 0
vidRingCapBlkC: dw 0
vidEntCntC:    db 0              ; filemap entries in use
 IFDEF DEBUG
vidFillT0:     dw 0
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
    jp vid_hop1
.fail:
 IFDEF DEBUG
    push bc
    call vid_open_fail_print     ; per-verdict message (plain call;
    pop bc                       ; DEBUG only - Release fails silently,
                                 ; owner ruling 2026-08-27, see the
                                 ; print block below)
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

    ; --- samples abort, BOTH channels (SSTOP request path, waited).
    ; audEnable = 0 means aud_tick never runs - skip the wait entirely
    ; (neither bit would ever clear). B holds the just-captured
    ; audEnable.
    ;
    ; CHANNEL 2 IS NOT TIDINESS, IT IS REQUIRED. Its DAC port ($B3)
    ; drives DACs B+C, which are exactly VID_DAC_LEFT and VID_DAC_RIGHT
    ; - the pair this player's own stereo feed writes. And unlike
    ; channel 1, whose CTC channel 0 this session seizes and repoints,
    ; channel 2's CTC channel 1 is never touched here: a live channel 2
    ; would keep firing its own ISR and writing DACs B/C underneath the
    ; clip for its whole duration. So it is stopped up front, through
    ; audRequest2 bit 2 (the exact mirror of channel 1's audRequest bit
    ; 7), and the wait below does not end until BOTH bits have been
    ; consumed. The teardown's DAC2 park (.restore) is the belt to this
    ; braces, not a substitute for it.
    ;
    ; Stopping channel 2 also settles the SECOND RULE for its ring: it
    ; plays out of AUD_STAGE2, which sits in the $4000-$5FFF window this
    ; session borrows through MMU2. The ring is dead for the whole
    ; session because the channel is aborted here, before the borrow.
    ;
    ; A PENDING START IS CLEARED FIRST, not just stopped over. aud_tick
    ; consumes stop-then-start in ONE pass, so a start filed and not yet
    ; consumed would fire in the very tick that serves the stop below and
    ; leave the channel running under the clip - with the wait none the
    ; wiser, since its bit did clear. sfx_stop_wait (overlay1) guards its
    ; own stage with exactly this res-then-set pair, for exactly this
    ; reason. Reachable in one turn (a play condact then a video condact
    ; inside 20 ms) and, since the teardown now files a resume start of
    ; its own, back-to-back videos too.
    ld a, b
    or a
    jr z, .noaudsave
    ld hl, audRequest
    res 6, (hl)
    set 7, (hl)
    ld hl, audRequest2
    res 3, (hl)
    set 2, (hl)
.waitstop:
    halt
    ld a, (audRequest)
    bit 7, a
    jr nz, .waitstop
    ld a, (audRequest2)
    bit 2, a
    jr nz, .waitstop
.noaudsave:
    ; --- music tick frozen (also stops the frame ISR's MMU6/7 remap
    ; around aud_tick - the banking invariant's structural guarantee)
    xor a
    ld (audEnable), a

    ; --- AY park. ENTRY ORDER (load-bearing): capture -> samples abort
    ; (waited, needs the tick alive) -> audEnable=0 (tick frozen) ->
    ; park. The park MUST follow the freeze: a park before it would be
    ; re-latched by the very next 50Hz music tick. audEnable=0 leaves
    ; every PSG latched on its last tone, so park ALL THREE - PSG 3
    ; carries music channels 7-9 plus beep/effect/AYS streams (audiobank
    ; aud_music_stop parks it for the same reason), so it must freeze
    ; too, not just PSG 1/2. Resume needs nothing for music: the
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
vidSvNr6b:       db 0            ; presentation isolation: tilemap
vidSvNr4a:       db 0            ; presentation isolation: fallback
vidSvNr14:       db 0            ; presentation isolation: transparency
                                 ; colour - restored on every real exit

; SP15 L2 snapshot cells (page-local like vidSv*): the reserved pool
; bank list + the first-palette readback. vidSnapCnt = 0 means no
; snapshot this session (Layer 2 hidden pre-video / nothing held -
; the idempotent-free sentinel, like vidAudBankC).
vidSnapCnt:      db 0
vidSnapBanks:    ds VID_SNAP_MAX
vidSnapDE:       dw 0            ; copy engine direction: the port-A (D)
                                 ; and port-B (E) window high bytes
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
    ; NR $43 is not reliably readable: the game's convention is
    ; PAL_L2_FIRST (every L2 palette writer asserts it); prime the
    ; double-buffer tracker to match, restore the constant at teardown
    ld a, PAL_L2_FIRST
    ld (vidPalCtrl+DATA_WINDOW-OVL_ORG), a
    ld e, NR_L2_TRANSP
    call nr_read
    ld (vidSvNr14), a            ; page-local (3c cell move)
    ; mode + full-width clip (v2 width code: 1 = 320/mode-1)
    ld a, (vidP_Shape)
    or a
    jr z, .l2mode0
    ld a, NXV_NR70_MODE1
    nextreg NR_L2_CTRL, a
    nextreg NR_L2_TRANSP, L2_TRANSP_COLOUR
    nextreg NR_CLIP_IDX, 1
    xor a
    nextreg NR_L2_CLIP, a        ; X1 = 0 (full-bleed)
    ld a, NXV_CLIP_X2_MODE1
    nextreg NR_L2_CLIP, a
    jr .clipY
.l2mode0:
    xor a
    nextreg NR_L2_CTRL, a
    nextreg NR_L2_TRANSP, L2_TRANSP_COLOUR
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
    ; L2_TRANSP_COLOUR value, so the surface stays fully opaque.
    call vid_pal_black
    ; zxnDMA session init: the never-changing WR2 (port B memory/
    ; increment/cycle-2) + WR5 (stop on end) - register writes only,
    ; the DMA is idle here. Each chunk's arm block (hot) carries its
    ; own WR0/WR1 and runs with interrupts live (kernel header)
    ld hl, vidDmaInit
    ld bc, (vidDmaInit_len << 8) | DMA_PORT
    di
    otir
    ei
    ; CTC time constant: table-driven from the live video-timing mode
    ; (carried v1 table/derivation). ONE table since mono went - the
    ; open path refuses any channel count but 2, so the rate is always
    ; NXV_RATE_STEREO.
    ld e, NR_VIDEO_TIMING
    call nr_read
    and 7
    ld c, a
    ld b, 0
    ld hl, vidCtcTcNxvStereo
    add hl, bc
    ld a, (hl)
    ld (vidCtcTc+DATA_WINDOW-OVL_ORG), a
    ; IM2_CTC_STUB (ISR vector) - RESIDENT memory, single atomic
    ; LD (nn),HL; strictly before the CTC arm (hot, after this body)
    ld hl, video_ctc_isr_stereo
    ld (IM2_CTC_STUB+1), hl
    ; T10: no per-file ISR end markers any more - both ISRs' ring-end
    ; wrap compares are assembly constants (the ring geometry never
    ; changes); the feed cells are primed hot by the .orchret preload
    ; (vidAudWr/RdPrev/PaceRem), and the feed state is zeroed below
    ; with the rest of the session init
 IFDEF DEBUG
    ; session baseline: zero vidTlFrames..vidLoopPass (vidTlFillFrames
    ; sits outside the span - the open body already staged it)
    ld hl, vidTlFrames+DATA_WINDOW-OVL_ORG
    ld (hl), 0
    ld de, vidTlFrames+1+DATA_WINDOW-OVL_ORG
    ld bc, VID_TL_ZERO_LEN-1
    ldir
    ; PLAY= baseline: its cells live after the zero span (so the open
    ; body can stage vidNomStep before this runs), so they are cleared
    ; here by name. vidRlDiv starts at 1 so the first divided poll of
    ; the session fires at once; vidRlLast is seeded by whichever poll
    ; runs first (normally vid_play_frame at the frame-loop top, which
    ; is also where the bracket arms), and a zero seed can only ever
    ; read "the line advanced" - never a false wrap.
    ld hl, vidRlLast+DATA_WINDOW-OVL_ORG
    ld (hl), 0
    ld de, vidRlLast+1+DATA_WINDOW-OVL_ORG
    ld bc, vidPlayEnd+2-vidRlLast-1
    ldir
    ld a, 1
    ld (vidRlDiv+DATA_WINDOW-OVL_ORG), a
    ld (vidRlSpinDiv+DATA_WINDOW-OVL_ORG), a  ; Phase 2-POLL: seeded
                                 ; the same way, for the same reason
    xor a
    ld (vidNomAcc+DATA_WINDOW-OVL_ORG), a
    ld (vidNomAcc+1+DATA_WINDOW-OVL_ORG), a
    ld (vidNomAcc+2+DATA_WINDOW-OVL_ORG), a
    ld hl, (vidNomStepC)
    ld (vidNomStep+DATA_WINDOW-OVL_ORG), hl
 ENDIF
    ; --- decode session init (3c: moved cold into this bracket -
    ; strictly pre-arm; the hot .orchret side arms right after; the
    ; audio-0 preload there consumes these cursors) ---
    xor a
    ld (vidInSpan+DATA_WINDOW-OVL_ORG), a
    ld (vidPalPending+DATA_WINDOW-OVL_ORG), a
    ld (vidFramePos+2+DATA_WINDOW-OVL_ORG), a
    ld (vidAudFeedRem+DATA_WINDOW-OVL_ORG), a
    ld (vidAudFeedRem+1+DATA_WINDOW-OVL_ORG), a
    ld (vidDsAudBlkRem+DATA_WINDOW-OVL_ORG), a
    ld (vidDsAudBlkRem+1+DATA_WINDOW-OVL_ORG), a
    ld hl, 512                   ; frame 0's audio follows the header:
    ld a, (vidDeliverStrm)       ; a BYTE offset for resident, ONE
    or a                         ; BLOCK for streaming (its file cursor
    jr z, .fp0                   ; counts blocks - ceiling lift; direct
    ld hl, 1                     ; never reads the cell)
.fp0:
    ld (vidFramePos+DATA_WINDOW-OVL_ORG), hl
    ld hl, (vidFrames+DATA_WINDOW-OVL_ORG)
    ld (vidFramesLeft+DATA_WINDOW-OVL_ORG), hl
    jp data_restore              ; 3c: plain return to the orchestrator

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

; zxnDMA session init program (WR1 + WR2 + WR5; see the hot arm
; blocks). WR1 lives here per the descriptor split above: the hot COPY
; arm no longer carries port A's mode, so the session default IS
; incrementing and only vid_fill_dma ever departs from it (and restores
; it immediately).
vidDmaInit:
    db $83                       ; WR6: disable (clean slate)
    db %01010100                 ; WR1: A memory, INCREMENTING, timing
    db %00000010                 ; A cycle length 2
    db %01010000                 ; WR2: B memory, incrementing, timing
    db %00000010                 ; B cycle length 2 (no prescaler)
    db %10000010                 ; WR5: stop on end of block (one-shot)
vidDmaInit_len equ $ - vidDmaInit

; Per-video-mode CTC time constants for the ONE supported audio rate
; (carried verbatim from v1 - same rate, same derivation; see git
; history for the full per-mode error tables and for the mono table
; that used to stand beside this one).
vidCtcTcNxvStereo:
    db 112, 114, 117, 120, 124, 128, 132, 108
    ; index 7 (108) is the mode-7 entry; a write of 7 to NR $11 stores 0
    ; on core 3.02.04, so NR $11 never reads back 7 and this is unreachable

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
    nextreg NR_PAL_CTRL, PAL_L2_FIRST   ; the game convention (v1 finding)
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
    ld a, (vidSvNr14)
    nextreg NR_L2_TRANSP, a
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
    jp vid_hop1

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
; asserts (the NR $43 readback finding); the explicit NR $43 select makes
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

 IFDEF DEBUG
; ---------------------------------------------------------------------
; CHK= (SP18 item 5): 32-bit byte sum of BOTH Layer 2 decode
; surfaces, taken at teardown BEFORE the snapshot restore repaints
; the game set. Cross-build instrument: identical CHK on two builds
; for the same clip means the final surfaces are byte-identical - the
; binary verdict on whether a pre-empted DMA transfer resumed
; uncorrupted. The player double-buffers (KFLIP swaps NR $12 between
; the two bank sets captured at entry), so a single-set sum would
; miss corruption confined to the other decode buffer since its last
; keyframe repaint. Walk order, fixed for determinism: the game set
; first (vidSvNr12 == vidSvL2Front by the game's NR $12 = front
; invariant), then the player back set (vidSvL2Back) - each as
; ascending 8K pages, $4000-$5FFF via MMU2, the same walk
; vid_snap_copy uses. Summing both sets also makes CHK independent
; of the session's KFLIP parity. The page count is keyed to the
; CLIP's own mode (vidP_Shape, staged at open, unclobbered through
; teardown), NOT the snapshot geometry: vidSnapCnt describes the
; GAME's pre-video screen and is 0 whenever Layer 2 was hidden
; pre-video, but the player's surfaces exist in every armed session.
; So CHK runs in EVERY armed session, independent of whether a game
; picture was on screen (SNAP= does not gate it; the bank bases are
; captured unconditionally at entry) - a CHK of 00000000 is a
; failure signature, not an idle reading. Runs only on the teardown
; path, so cost (~74 T/byte nominal + M1 waits, both sets: ~12-14M T
; at 320x256, ~0.45-0.5 s at 28 MHz - a visible pause on DEBUG
; teardown) is invisible to playback and lands AFTER the PLAY= end
; stamp. MMU2 is left on the last walked page - vid_snap_copy
; immediately re-drives MMU2 per page and the exit bracket restores
; the game mapping, same as today.
; ---------------------------------------------------------------------
vid_chk_surface:
    xor a
    ld (vidChkSumL), a
    ld (vidChkSumL+1), a
    ld (vidChkSumL+2), a
    ld (vidChkSumL+3), a
    exx
    ld hl, 0                     ; HL' = sum low 16
    ld d, h
    ld e, l                      ; DE' = sum high 16
    ld b, h                      ; B'  = 0 (C' is the byte carrier)
    exx
    ld a, (vidP_Shape)           ; clip width code: 0 = 256/mode-0
    or a
    ld a, 6                      ; mode 0: 3 banks = 6 pages per set
    jr z, .cnt
    ld a, 10                     ; mode 1: 5 banks = 10 pages per set
.cnt:
    ld d, a                      ; D = pages remaining (set 1)
    push af
    ld a, (vidSvNr12)
    call .walkset                ; game set first
    pop af
    ld d, a                      ; D = pages remaining (set 2)
    ld a, (vidSvL2Back)
    call .walkset                ; then the player back set
    exx
    ld (vidChkSumL), hl
    ld (vidChkSumL+2), de
    exx
    ret
.walkset:                        ; A = 16K bank base, D = 8K pages
    add a, a
    ld e, a                      ; E = current 8K page
.page:
    ld a, e
    nextreg NR_MMU2, a           ; page E of the set into $4000
    ld hl, $4000
    ld bc, $2000
.byte:
    ld a, (hl)
    inc hl
    exx
    ld c, a
    add hl, bc                   ; low16 += byte
    jr nc, .nc
    inc de                       ; carry into high16
.nc:
    exx
    dec bc
    ld a, b
    or c
    jr nz, .byte
    inc e
    dec d
    jr nz, .page
    ret
vidChkSumL: ds 4                 ; little-endian 32-bit sum (report
                                 ; prints high word first)
 ENDIF

; ---------------------------------------------------------------------
; vid_snap_restore_body - restore matrix step 4b (SP15): pixels then
; palette written back while Layer 2 is still hidden (called between
; step 4 and the step-5 re-show). No-op when vidSnapCnt = 0 -
; restore-to-hidden is already exact. NR $43 = PAL_L2_FIRST here
; (step 4 just wrote NR $43: edit = first palette, auto-inc on).
; audEnable was restored at step 1, so the 50Hz frame ISR's MMU6/7
; remap around aud_tick is LIVE - the copy engine's DI-bracketed
; one-shot discipline covers it (doc 11's law). ~14ms mode-1 (~9ms
; mode-0): under one field, invisible inside the hidden bracket.
; Corrupts everything.
; ---------------------------------------------------------------------
vid_snap_restore_body:
 IFDEF DEBUG
    call vid_chk_surface         ; CHK= snapshot of the final surface,
 ENDIF                           ; before the restore repaints it
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
    or a                         ; A != 0 save: port A = L2, port B = pool
    ld de, (high VID_DST_WIN << 8) | high DATA_WINDOW
    jr nz, .dir                  ; A = 0 restore: the other way round
    ld de, (high DATA_WINDOW << 8) | high VID_DST_WIN
.dir:
    ld (vidSnapDE), de           ; per-session direction, read per page
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
    ld de, (vidSnapDE)           ; D = port-A chunk high byte, E = port-B
    ld b, 32                     ; 32 x 256B chunks per 8K page
.chunk:
    push bc
    push de
    ld l, 0                      ; chunks are 256-aligned
    ld h, d
    ld (vidSnapDmaArm.asrc), hl  ; port A = this side's chunk
    ld h, e
    ld (vidSnapDmaArm.bdst), hl  ; port B = the other side's chunk
.arm:
    ld hl, vidSnapDmaArm
    ld bc, (vidSnapDmaArm_len << 8) | DMA_PORT
    di
    otir                         ; program + run to completion in ONE
    ei                           ; DI bracket - THE LAST ONE LEFT, and
                                 ; deliberate: the snapshot runs
                                 ; strictly pre-CTC-arm / post-CTC-park
                                 ; (orch order: entry -> open -> snap
                                 ; save -> l2setup arms; .restore parks
                                 ; before snap restore), so no
                                 ; permitted edge exists and dropping
                                 ; the DI would only admit the frame
                                 ; ISR mid-arm for zero gain. That
                                 ; ordering is load-bearing - do not
                                 ; reshuffle. dma_contract.py asserts
                                 ; this bracket PRESENT.
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
    ld (hl), a                   ; ".VID",0 is the template's tail
    ld a, (curPart)
    dec a
    jr z, .openroot
    add a, '1'                   ; digit = curPart + '0'
    ld (vidNamePart+4), a        ; "PARTn\" template, digit patched;
    ld ix, vidNamePart           ; vidName is its tail
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
    call vid_play_missing_print  ; "VID FILE?" (plain call, 3c; DEBUG
    pop bc                       ; only - Release fails silently, owner
                                 ; ruling 2026-08-27, see the print
                                 ; block below)
 ENDIF
.haveresult:
    ld hl, vid_play.openret
    jp vid_hop1

; Open-failure diagnostic prints - DEBUG ONLY (owner ruling 2026-08-27:
; a player must never see error codes mid-game) - an SFX/GFX-triggered
; stream refused on a platform without SD streaming fails silently in
; Release; authors diagnose with the DEBUG build. Printed via the
; resident tm_putc_at instead of the dbg console (one route, no double
; print in DEBUG).
; Safe from here because both call sites fire strictly pre-arm: the
; video never started, no L2/mode switch happened (vid_run_l2setup_body
; runs only on success), the game's tilemap at TM_MAP ($6000, MMU3) is
; still live and mapped - the open path only brackets MMU6 (data_save/
; data_restore, closed on every failure exit) and MMU7 (this page);
; MMU2/MMU3 are captured, never remapped, pre-arm. Row 23 col 0 is the
; position the old DEBUG dbg_at path used; reserved pair 0 (white ink
; on black paper) is the attr dbg_putc_tm also uses. The game
; continues after the print (non-fatal, unchanged) and its own window
; scrolling may later overwrite the text - a diagnostic, not a HUD.
 IFDEF DEBUG
vid_play_missing_print:
    ld hl, msgVidMissing
    jr vid_fail_puts

; Open/load failure print: B = 1 VID FMT / 2 no bank / 3 no ring fits
; (pool below one streamed frame's need) / 4 too fragmented to stream
; (filemap exceeds the hot copy - and the file-size ceiling that a
; too-long clip now meets: VID_STRM_HOT_ENT extents of 65535 blocks).
; Corrupts B - the caller brackets it.
vid_open_fail_print:
    ld a, b
    cp 2
    ld hl, msgVidBadFmt
    jr c, vid_fail_puts          ; B = 1
    ld hl, msgVidNoBank2
    jr z, vid_fail_puts          ; B = 2
    cp 4
    ld hl, msgVidTooBig
    jr c, vid_fail_puts          ; B = 3
    ld hl, msgVidFrag            ; B = 4
; HL = ASCIIZ. Prints at row 23 col 0, white on black (reserved pair 0),
; straight through the resident tm_putc_at (overlay1 calls it the same
; way). Corrupts AF, BC, DE, HL.
vid_fail_puts:
    ld bc, 23*256+0              ; B = row 23, C = col 0
    ld e, TM_ATTR_DEFAULT        ; reserved pair 0: white ink, black paper
.loop:
    ld a, (hl)
    or a
    ret z
    push hl
    call tm_putc_at              ; preserves BC, DE
    pop hl
    inc hl
    inc c
    jr .loop

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
    call esx_fstat                ; bracketed (fix wave, SP18 item 7
                                 ; final review Finding 1): the Task 4
                                 ; exemption claimed vid_run_orch_body
                                 ; only reaches this open cluster AFTER
                                 ; vid_run_entry_body's sample-channel
                                 ; abort - false, vid_play runs the
                                 ; whole open cluster FIRST and only
                                 ; then jp vid_run, so a STREAMING
                                 ; channel's refiller could burst CMD18
                                 ; here with cardBusy clear
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
    call esx_filemap              ; bracketed (fix wave, SP18 item 7
                                 ; final review Finding 1 - see the
                                 ; F_FSTAT call above for the corrected
                                 ; ordering); esx_filemap preserves
                                 ; A/F/DE/HL exactly as raw esxDOS would
    ret c                        ; A = esxDOS error, CF set
    ; DE = unused entries, HL = address past last written entry
    ld (vidCardFlags), a
    ld a, e
    or d
    jr nz, .roomok
    ld a, VID_ERR_FRAG           ; buffer full: cannot prove complete.
                                 ; NOT a false reject at 32 extents any
                                 ; more - the buffer holds 33 entries
                                 ; (VID_FILEMAP_ENT comment), so a
                                 ; 32-extent file always leaves DE >= 1
                                 ; and only 33+ extents land here
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
vidNamePart: db "PART0", 92      ; digit at +4 patched; 92 = '\' (the
                                 ; assembler does not escape char literals)
vidName:     ds 3                ; "NNN" patched
             db ".VID", 0        ; the root name IS the PART name's tail
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
;
; NR $06 IS ALSO THE AUDIO CHIP MODE REGISTER (bits 1:0), and this pair
; plus vid_mf_disable_h / vid_mf_restore_h are the only writes to it in
; the tree. Recorded here because SP16 Task 7's clock grep was scoped
; to the audio path and never reached video.asm - do not re-derive it.
; VERIFIED against tools/NextZXOS/docs/extra-hw/io-port-system/
; registers.txt, "0x06 (06) => Peripheral 2 Setting": "and %11110111"
; clears bit 3 (enable multiface nmi by M1 button) and nothing else, so
; bits 1:0 (audio chip mode) and bit 6 (divert BEEP to internal
; speaker) survive a raw SD window intact. No live audio bug here.
; vid_mf_restore writes the whole saved byte back and is equally
; mode-preserving PROVIDED it is paired: vidMfSave / vidMfSaveH are
; static 0 slots, so an unpaired restore would write $00 and set audio
; chip mode %00. Every call site is paired - latent shape, not a bug.
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
; DEBUG session report (carried mechanism: the VID_PAGE block is
; LDIR-copied across the page hop into the page-local mirror BEFORE
; any print - the copy-across contract, rubric 3). Three rows since
; v0.5.0, when the five per-phase tick rows, the TOT total and the
; LNF/LNL raster probe were removed with the tick timeline itself:
; STATUS carries FRM/ERR/OP/POS/PASS, RING carries the ring triple +
; FILL (the resident ring load's 50Hz-frame count), and PLAY carries
; the wall-clock bracket against NOM. FRM prints as live/mirror - the
; Card #5 trap, see vid_tl_frames_live.
; ---------------------------------------------------------------------
VID_TL_ROW0 equ 24

vid_tl_report_body:
    ; clear Layer 2 over the report rows (carried v1 fix: stale video
    ; pixels would otherwise show through the tilemap's transparency)
    ld e, NR_DISPLAY_CTRL
    call nr_read
    ld (vidTlNr69), a            ; re-asserted at .done: since the SP15
                                 ; snapshot the restore has already
                                 ; repainted the game picture
    and %01111111
    nextreg NR_DISPLAY_CTRL, a
    ; copy the hot instrument block across (rubric 3)
    call data_save
    ld a, VID_PAGE
    call data_map_page
    ld hl, vidTlFrames + DATA_WINDOW - OVL_ORG
    ld de, vidTlFramesL
    ld bc, VID_TL_BLOCK_LEN
    ldir
    call data_restore
    ; STATUS row. This was the tail of the OTHER phase row until the
    ; tick timeline went (v0.5.0); the five phase rows, the TOT tick
    ; total and the LNF/LNL raster probe went with it, these
    ; breadcrumbs did not - they are what localizes an intermittent
    ; decode abort, and they cost nothing to keep.
    ld b, VID_TL_ROW0
    ld c, 0
    call dbg_at
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
    ld b, VID_TL_ROW0+1
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
    ; PLAY row: the ONLY wall-clock figure in this report. Every other
    ; number here is counted in video-CTC ISR ticks and is therefore
    ; blind to a suppressed interrupt (see vid_rl_poll). PLAY is the
    ; elapsed 50Hz FIELD count across the WHOLE frame loop - first
    ; delivered frame to teardown - and NOM is what that same delivered
    ; frame count is worth at the header fps, i.e. FRM x (50/fps).
    ; Both therefore cover the same FRM frame periods whether a frame
    ; presented or was HELD by a keyframe span, so PLAY/NOM is the rate
    ; ratio directly: PLAY > NOM = the clip ran SLOW by that ratio,
    ; PLAY == NOM = at rate, and PLAY < NOM is not physically possible
    ; (a clip cannot outrun its own frame rate - that reading means the
    ; field clock lost a wrap, see vid_rl_poll's poll-gap table).
    ; Open, load and ring prefill are outside the bracket. Both fields
    ; wrap at 65536 fields (21.8 min).
    ld b, VID_TL_ROW0+2
    ld c, 0
    call dbg_at
    ld hl, msgTlPlay
    call dbg_puts
    ld hl, (vidPlayEndL)
    ld de, (vidPlayStartL)
    or a
    sbc hl, de
    call dbg_hex16
    ld hl, msgTlNom
    call dbg_puts
    ld hl, (vidNomAccL+1)        ; 8.8 fixed point -> whole fields
    call dbg_hex16
    ld hl, msgTlChk
    call dbg_puts
    ld hl, (vidChkSumL+2)        ; high word first - the row reads as
    call dbg_hex16               ; one big-endian 8-digit number
    ld hl, (vidChkSumL)
    call dbg_hex16
    jr .done
.done:
    ld a, (vidTlNr69)            ; hand the picture back
    nextreg NR_DISPLAY_CTRL, a
    ld hl, vid_tl_report_ret
    jp vid_hop1

; FRM=live/mirror TRAP (Card #5): catches whether an intermittent
; FRM=0000 report row is a mirror-path fault or a live-cell fault - left
; deliberately instrumented rather than resolved. Re-reads vidTlFrames
; from the hot page, in its own MMU6 bracket, after the block LDIR has
; already snapshotted it:
;   FRM=xxxx/xxxx (equal, nonzero) - normal.
;   FRM=xxxx/0000 - the MIRROR side is wrong: the LDIR or the mirror
;                   layout dropped it (the hot counter was fine).
;   FRM=0000/xxxx - the LIVE cell was zeroed BETWEEN the LDIR and this
;                   read, i.e. something is still writing post-park.
;   FRM=0000/0000 - the counter was already zero when the report ran:
;                   the fault is upstream of the report path, not mirror.
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

msgTlFrm:  db " FRM=", 0
msgTlErr:  db " ERR=", 0
msgTlOp:   db " OP=", 0
msgTlPos:  db " POS=", 0
msgTlPass: db " PASS=", 0
msgTlFill: db " FILL=", 0
msgTlRing: db "RING   =", 0
msgTlSlash: db "/", 0
msgTlSnap: db " SNAP=", 0
msgTlPlay: db "PLAY   =", 0
msgTlNom:  db " NOM=", 0
msgTlChk:  db " CHK=", 0
vidSnapCntL: db 0                ; SNAP= mirror - written at open (the
                                 ; live vidSnapCnt is zeroed by the
                                 ; teardown free before the report)

vidTlNr69:        db 0    ; NR $69 as the report found it

; Page-local mirror of the hot instrument block (same order/sizes -
; one LDIR; the length is computed so it can never drift).
vidTlFramesL:     dw 0
vidErrCodeL:      db 0
vidErrOpL:        db 0
vidErrPosL:       ds 3
vidLoopPassL:     db 0
vidRingMinL:      dw 0
vidRingUnderL:    dw 0
vidDepthClipL:    db 0
vidTlFillFramesL: dw 0
vidRlDivL:        db 0
vidRlLastL:       dw 0
vidRlFieldsL:     dw 0
vidPlayArmedL:    db 0
vidPlayStartL:    dw 0
vidPlayEndL:      dw 0
vidNomStepL:      dw 0
vidNomAccL:       ds 3
    ASSERT vidNomAccL + 3 - vidTlFramesL == VID_TL_BLOCK_LEN
 ENDIF

    DISPLAY "video2 ends at ", $, " headroom ", /D, OVL_LIMIT - $
    ASSERT $ <= OVL_LIMIT
