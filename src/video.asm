; NextDAAD code page: video (NXV v2 delta-video player, SP15 Task 3
; stage 3a - the v1 player is DELETED; git holds it).
;
; PAGE LAYOUT (SP15 3a redesign - this header is the layout authority):
;
;   VID_PAGE (59, MMU7 while any video code runs, $E000-$F7FF) - HOT:
;     everything that can execute while the video CTC ISR is armed.
;     $E000        vid_stub - 64-byte 256-aligned dispatch block (16
;                  4-byte JP slots; the wire opcode IS the offset)
;     $E040..      decode kernels (computed-entry fill/LDI blocks,
;                  ALIGN 64), fast op handlers (flat + gapped sets),
;                  central dispatch, chunked bodies, DMA arm blocks,
;                  seam walkers, PAL/KSTART/KFLIP/FEND handlers
;     then         vid_decode_frame / vid_src_seek / vid_aud_copy,
;                  vid_play / vid_run + the frame loop, vid_key_any,
;                  the two audio CTC ISRs, DEBUG timeline stamp
;     then         hot cells (vidAudBuf 2560B, ring bank list, vidSv*)
;
;   VID_PAGE2 (70, $E000-$F7FF) - COLD (pre-arm / post-disarm only):
;     nxv2_open_body (v2 header validate + ring alloc + resident
;     load), vid_run_entry_body / vid_run_l2setup_body /
;     vid_run_restore_body (EXIT ORDER FIX lives there), the esxDOS
;     open cluster (vid_open_video_body / vid_stream_open_body /
;     vid_raw_setup), and the WHOLE SD streaming cluster
;     (vid_stream_read + raw CMD18 machinery) - moved off the hot
;     page wholesale: stage 3a plays RESIDENT ONLY, so no SD code
;     ever runs while the CTC is armed. 3b PARTS BIN: the streaming
;     cluster is kept intact and clearly marked - the 3b prefetch
;     producer re-hots what it needs (see the cluster's own banner).
;     DEBUG: the timeline report body.
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
;      untaken JR 7T; ~+16T at 28MHz with wait states) - ~1.5-4% of
;      the settled per-op envelopes, bounded by design.
;   2. Early-FEND tail semantics: the decoder only writes what ops
;      write - no surface clears anywhere - so an early FEND leaves
;      the untouched frame tail exactly as it stands (patch-in-place).
;   3. DMA chunks <= 256B: every chunk path is capped at NXV2_DMA_CHUNK
;      by vid_chunk_dst/vid_chunk_all before a DMA kernel can see it.
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
vid_dec_abort:
 IFDEF DEBUG
    ld (vidErrCode), a
 ENDIF
    ld sp, (vidDecSp)
    jp vid_run.decfail

; ---------------------------------------------------------------------
; Fast op handlers - GAPPED set (mode-1 letterbox: content height
; 1-255, columns are 256-aligned in the dest window so E IS the
; within-column offset; a whole column always sits inside one window
; page). Fast condition: E + count < height (strictly inside the
; column - no hop, no seam, D untouched). The height immediate at
; each .hcmp is a per-file SMC constant (nxv2_open_body patches it,
; doc 08 through the MMU6 window - rubric 3).
; ---------------------------------------------------------------------
vg_op_skip8:
    ld c, (hl)
    inc hl
    ld a, e
    add a, c
    jr c, .slow
.hcmp:
    cp 0                         ; SMC: content height (1-255)
    jr nc, .slow
    ld e, a                      ; same column, same page
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
    jr nc, .slow
    ld a, c
    cp NXV2_RUN_DMA_MIN
    jr nc, .slow
    ld a, (hl)
    inc hl                       ; A = colour
    ld b, 0
    call vid_fill_cpu
    NXVNEXT vg_edge_relay, vg_bad_relay
.slow:
    ld a, (hl)
    inc hl                       ; A = colour
    ld b, 0
    jp vid_run_body

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
    jr nc, .slow
    ld a, c
    cp NXV2_COPY_DMA_MIN
    jr nc, .slow
    call vid_copy_ldi
    NXVNEXT vg_edge_relay, vg_bad_relay
.srcedge:
    ld a, l
    add a, c
    jr nc, .sok
    jr z, .sok
.slow:
    jp vid_copy_body

; jr-range relays for the gapped set's inline tails (the central hub
; sits past jr's -128 from here).
vg_edge_relay:
    jp vid_op_edge
vg_bad_relay:
    jp vid_op_bad

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
.c8:
    call vid_fetch
    ld c, a
    ld b, 0
    jp vid_copy_body
.c16:
    call vid_fetch
    ld c, a
    call vid_fetch
    ld b, a
    jp vid_copy_body

; Fetch one source byte across the window seam. Out: A = byte, HL
; advanced. Preserves BC, DE. Corrupts F.
vid_fetch:
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
; the settled crossovers (RUN >= 64B and COPY >= 90B go DMA, capped
; at 256B per DI bracket - contracts noted in the file header).
; ---------------------------------------------------------------------
vid_skip_body:
    ld (vidRemain), bc
.seg:
    ld bc, (vidRemain)
    ld a, b
    or c
    jp z, vid_next
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
    jp z, vid_next
    call vid_dst_norm
    call vid_chunk_dst           ; BC = chunk (rooms + 256 cap)
    push hl
    ld hl, (vidRemain)
    or a
    sbc hl, bc
    ld (vidRemain), hl
    pop hl
    ; kernel select (settlement crossover): >= 64 -> zxnDMA fill
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
; through the allocated bank list; running off the list = the payload
; overran the loaded file (clean abort - rubric 6: every walk bounded).
vid_src_next:
    push bc
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
    ld (vidSrcBankIdx), a
    ld c, a
    ld a, (vidRingBankCnt)
    dec a
    cp c
    jr c, .ovr                   ; idx > last bank
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
    jp vid_next
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
    ; pos24 = (bankIdx*2 + parity) * 8192 + (HL - $C000)
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
    ld a, VID_ERR_SRCOVR
    jp vid_dec_abort

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
    jr .go
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
.go:
    ld iy, vid_stub              ; IYH pinned for the whole payload
    jp vid_next                  ; terminal handlers ret to our caller

; ---------------------------------------------------------------------
; vid_src_seek - map the ring page holding vidFramePos and derive the
; window cursor. Out: HL = VID_SRC_WIN + (pos & $1FFF), MMU6 mapped,
; vidSrcBankIdx/Parity/CurPage current. Corrupts AF, BC.
; ---------------------------------------------------------------------
vid_src_seek:
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

; ---------------------------------------------------------------------
; vid_aud_copy - copy this frame's REAL audio bytes from the ring at
; vidFramePos into the ISR-resident vidAudBuf (LDIR, seam-walked),
; then advance vidFramePos by the padded block size. Safe with no DI
; (the ISR is holding at the end marker - pace already passed; a torn
; read is at most one imperceptible tick, the v1-proven argument).
; Corrupts AF, BC, DE, HL. Errors (a corrupt file whose audio runs
; off the ring) abort via vid_src_next's own bounds check.
; ---------------------------------------------------------------------
vid_aud_copy:
    call vid_src_seek
    ld de, vidAudBuf
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
    ret nc
    ld hl, vidFramePos+2
    inc (hl)
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
    call vid_open_video
    jr c, .missing
    jp vid_run
.missing:
 IFDEF DEBUG
    ld hl, vid_play_missing_body ; cold print (pre-arm - safe hop)
    push hl
    ld a, VID_PAGE2
    jp ovl_map_page
.missingret:
 ENDIF
    ret

; Hot stub for the cold open cluster (name build + PARTn probe + esx
; open + filemap capture live on VID_PAGE2; C = video number).
vid_open_video:
    ld hl, vid_open_video_body
    push hl
    ld a, VID_PAGE2
    jp ovl_map_page
vid_open_video_ret:
    ld a, b
    or a
    jr z, .ok
    scf
    ret
.ok:
    or a
    ret

; ---------------------------------------------------------------------
; vid_run - orchestration. Entry/exit symmetry: everything touched is
; captured into a vidSv* cell and reversed on every exit path.
; Sequence: save MMU6/7 (hot, before any hop) -> entry body (NR
; captures incl MMU2, samples abort, music freeze, PSG park) ->
; nxv2 open/load (header validate, ring alloc, RESIDENT full-file
; load, SMC config - all cold, all pre-arm) -> L2 setup (mode/clip/
; isolation/black palettes/CTC table/ISR select) -> CTC arm (hot) ->
; the frame loop -> reverse-order restore on any exit.
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
    ld hl, vid_run_entry_body
    push hl
    ld a, VID_PAGE2
    jp ovl_map_page
.entryret:
    ; --- v2 open + resident load (cold). B verdict: 0 = loaded,
    ; 1 = bad header/read (VID FMT), 2 = no bank, 3 = exceeds the
    ; ring (stage 3a's clean not-yet-supported error). On failure the
    ; body has already freed the ring and closed the stream. ---
    ld hl, nxv2_open_body
    push hl
    ld a, VID_PAGE2
    jp ovl_map_page
.openret:
    ld a, b
    or a
    jr z, .loaded
 IFDEF DEBUG
    ld hl, vid_open_fail_body    ; cold print, per-verdict message
    push hl
    ld a, VID_PAGE2
    jp ovl_map_page
.openfailret:
 ENDIF
.restore_noplay:
    ; nothing armed, nothing displayed, ring freed: only the music
    ; freeze needs reversing (the PSG park recovers on the next tick)
    ld a, (vidSvAudEnable)
    ld (audEnable), a
    ret
.loaded:
    ld hl, vid_run_l2setup_body
    push hl
    ld a, VID_PAGE2
    jp ovl_map_page
.l2setupret:
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
    ; --- decode session init ---
    xor a
    ld (vidInSpan), a
    ld (vidPalPending), a
    ld (vidFramePos+2), a
    ld hl, 512                   ; frame 0's audio follows the header
    ld (vidFramePos), hl
    ld hl, (vidFrames)
    ld (vidFramesLeft), hl

; ---------------------------------------------------------------------
; The frame loop. Per frame: pace on the PREVIOUS frame's audio ->
; copy + launch THIS frame's audio -> decode/paint THIS frame's
; payload (delta: visible surface; span chunks: hidden) -> present
; (KFLIP: palette swap + bank flip; delta: palette swap if a PAL
; rode the frame) -> key check -> frame accounting (loop mode
; restarts by rewinding the RAM cursor - no SD, seam-free by
; construction). DEBUG: 5-phase timeline stamps, one per transition.
; ---------------------------------------------------------------------
.frameloop:
 IFDEF DEBUG
    ld a, VID_TL_PACE
    call vid_tl_stamp            ; closes OTHER, opens PACE, frames++
 ENDIF
    ld (vidDecSp), sp            ; abort anchor for this iteration
.pace:
    ld a, (vidAudDone)           ; previous frame's audio finished?
    or a
    jr z, .pace
 IFDEF DEBUG
    ld a, VID_TL_AUDIO
    call vid_tl_stamp
 ENDIF
    call vid_aud_copy            ; ring -> vidAudBuf + cursor advance
    ld ix, vidAudBuf
    xor a
    ld (vidAudDone), a           ; this frame's audio launches
 IFDEF DEBUG
    ld a, VID_TL_DECODE
    call vid_tl_stamp
 ENDIF
    call vid_decode_frame        ; A = terminal (errors -> .decfail)
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
    ; --- EOF ---
    ld a, (vidLoopMode)
    or a
    jr z, .drainlast
    ; loop restart: rewind the RAM cursor to frame 0 - no SD access,
    ; no reopen, no seam (the whole file is resident)
    ld hl, (vidFrames)
    ld (vidFramesLeft), hl
    ld hl, 512
    ld (vidFramePos), hl
    xor a
    ld (vidFramePos+2), a
    ld (vidInSpan), a            ; defensive (a valid file never ends
                                 ; mid-span - nxv2dec validates)
    jp .frameloop
.drainlast:
    ; play-once: the last frame is showing; let its audio finish
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
; Audio CTC ISRs - CARRIED VERBATIM from the v1 player (the pacing /
; hold-last / IX-exclusivity / banking-invariant design is unchanged;
; see git history for the full derivation comments). Installed by
; vid_run_l2setup_body patching IM2_CTC_STUB (mono or stereo per the
; header's channel count); end markers self-modified to vidAudBuf +
; vidABytes - 1 (mono) / - 2 (stereo) before the CTC time constant
; starts the timer. MMU7 = VID_PAGE for the whole armed window keeps
; the stub's target resolving to THIS code (doc 11 / rubric 3).
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

; Resident play buffer - the ISR reads it via IX; full rate, no
; decimation (v1-proven sizing: NXV_AUD_BUF_MAX bounds the header
; field at open).
vidAudBuf:       ds NXV_AUD_BUF_MAX
vidAudDone:      db 0

; Entry/exit symmetry captures.
vidSvMmu6:       db 0
vidSvMmu7:       db 0
vidSvMmu2:       db 0            ; NEW (3a): the borrowed dest window
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

 IFDEF DEBUG
; DEBUG frame-timeline instrument state. vidTlTicks..vidErrOp is
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
vidTlFillFrames: dw 0            ; resident ring load duration, 50Hz
                                 ; frames (frameCounter delta)
VID_TL_ZERO_LEN  equ vidErrOp + 1 - vidTlTicks
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
; nxv2_open_body - NXV v2 header open + ring allocation + RESIDENT
; full-file load (stage 3a: resident is the ONLY delivery; files
; larger than the allocatable ring get the clean B=3 verdict - 3b
; adds streaming). Runs entirely cold, entirely pre-arm, with the
; music tick already frozen (entry body) so the load is silent (text
; adventure pre-roll, ~1s/1.5MB at the measured ~1264KB/s SD floor).
;
; In: the file is open (vid_open_video_body ran: vidHandle/vidSizeLo/
; Hi valid, raw cursor at file start). Out (via the hop back to
; vid_run.openret): B = 0 loaded + every hot parameter staged;
; B = 1 bad header / read error (VID FMT - v1 files land here);
; B = 2 no pool bank at all; B = 3 file exceeds the ring. On any
; failure the ring is freed and the stream closed. Corrupts
; everything. Rubric 3: every write to a VID_PAGE cell or code byte
; goes through the MMU6 window (+DATA_WINDOW-OVL_ORG) in the two
; marked brackets; everything else here is VID_PAGE2-local.
; ---------------------------------------------------------------------
nxv2_open_body:
    xor a
    ld (vidRingCntC), a
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
    ; flags: delta stream set; bits 2-7 reserved-zero (bit1 = the
    ; direct-serve hint is ACCEPTED and ignored in stage 3a)
    ld a, (DATA_WINDOW + NXV2_OFF_FLAGS)
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
    ; audio bytes/frame: nonzero, <= vidAudBuf; pad = round-up-512
    ld hl, (DATA_WINDOW + NXV2_OFF_ABYTES)
    ld a, h
    or l
    jp z, .badu                  ; zero would wrap the copy LDIR
    ld (vidP_ABytes), hl
    ld de, NXV_AUD_BUF_MAX
    or a
    sbc hl, de
    jr c, .abok                  ; real < max
    jp nz, .badu                 ; real > max: overflow guard
.abok:
    ld hl, (vidP_ABytes)
    ld de, 511
    add hl, de
    ld a, h
    and $FE
    ld h, a
    ld l, 0
    ld (vidP_ABytesPad), hl
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
    ; --- size -> needed banks; the ring must hold the WHOLE file ---
    ld a, (vidSizeHi+1)
    or a
    jp nz, .toobig               ; >= 16MB
    ld a, (vidSizeHi)
    cp $20
    jp nc, .toobig               ; >= 2MB: exceeds any ring
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
    jp nc, .toobig               ; over the list capacity
    ld (vidRingNeed), a
.alloc:
    ld a, (vidRingCntC)
    ld b, a
    ld a, (vidRingNeed)
    cp b
    jr z, .allocdone
    call bank_alloc
    jp c, .toobig                ; pool exhausted: exceeds the ring
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
.allocdone:
    ; --- load the rest: ring pages in order until received == size.
    ; vid_stream_read holds the CMD18 window open across calls (its
    ; own contract), so this is one continuous multi-block read. ---
    ld a, 1
    ld (vidLoadIdx), a
.load:
    ; remaining = size - received (24-bit); 0 -> loaded
    ld hl, (vidSizeLo)
    ld de, (vidRecvLo)
    or a
    sbc hl, de
    ld a, (vidSizeHi)
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
    ; SD is DONE for the whole session: CMD12 + deselect + Multiface
    ; restore + F_CLOSE now, pre-arm (resident playback never streams)
    call vid_stream_close
 IFDEF DEBUG
    ld hl, (frameCounter)
    ld de, (vidFillT0)
    or a
    sbc hl, de
    ld (vidFillD), hl            ; ring-fill duration, 50Hz frames
 ENDIF
    ; --- stage everything hot (ONE translated bracket - rubric 3):
    ; the parameter block, the ring bank list, the per-file SMC
    ; patches (stub dispatch targets + gap height immediates). ---
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
    ; stub dispatch targets: flat vs gapped fast handlers for the
    ; 8-bit ops (the 16-bit ops share the gap-aware bodies) - doc 08
    ; SMC, written through the window (rubric 3: VID_PAGE code bytes)
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
    ld (vg_op_run8.hcmp + 1 + DATA_WINDOW - OVL_ORG), a
    ld (vg_op_copy8.hcmp + 1 + DATA_WINDOW - OVL_ORG), a
    jr .patched
.flatset:
    ld hl, vf_op_skip8
    ld (vid_stub + VOP_SKIP8 + 1 + DATA_WINDOW - OVL_ORG), hl
    ld hl, vf_op_run8
    ld (vid_stub + VOP_RUN8 + 1 + DATA_WINDOW - OVL_ORG), hl
    ld hl, vf_op_copy8
    ld (vid_stub + VOP_COPY8 + 1 + DATA_WINDOW - OVL_ORG), hl
.patched:
    call data_restore
    ld b, 0                      ; verdict: loaded
    jr .backhop
.badu:
    call data_restore            ; the parse bracket was open
.badc:
    ld b, 1                      ; verdict: bad header / bad read
    jr .fail
.toobig:
    ld b, 3                      ; verdict: exceeds the resident ring
.fail:
    push bc
    call vid_ring_free
    call vid_stream_close
    pop bc
.backhop:
    ld hl, vid_run.openret
    push hl
    ld a, VID_PAGE
    jp ovl_map_page

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
 IFDEF DEBUG
vidFillT0:     dw 0
vidFillD:      dw 0
 ENDIF

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

; ---------------------------------------------------------------------
; vid_run_entry_body - entry state capture (carried from v1; MMU6/7
; stay hot in vid_run - the ordering hazard - everything else lands
; here). NEW (3a): MMU2 is captured too (the borrowed dest window).
; Then the samples abort (waited), the music-tick freeze, and the AY
; music park. Hops back to vid_run.entryret. Corrupts everything.
; ---------------------------------------------------------------------
vid_run_entry_body:
    call data_save
    ld a, VID_PAGE
    call data_map_page
    ld e, NR_L2_BANK
    call nr_read
    ld (vidSvNr12+DATA_WINDOW-OVL_ORG), a
    ld e, NR_L2_CTRL
    call nr_read
    ld (vidSvNr70+DATA_WINDOW-OVL_ORG), a
    ld e, NR_DISPLAY_CTRL
    call nr_read
    ld (vidSvNr69+DATA_WINDOW-OVL_ORG), a
    ld e, NR_LAYERS
    call nr_read
    ld (vidSvNr15+DATA_WINDOW-OVL_ORG), a
    ld e, NR_MMU2
    call nr_read
    ld (vidSvMmu2+DATA_WINDOW-OVL_ORG), a
    ld hl, (IM2_CTC_STUB+1)
    ld (vidSvCtcStub+DATA_WINDOW-OVL_ORG), hl
    ld a, (audEnable)
    ld (vidSvAudEnable+DATA_WINDOW-OVL_ORG), a
    ld b, a                      ; stash - data_restore corrupts A
    ld a, (l2FrontBank)
    ld (vidSvL2Front+DATA_WINDOW-OVL_ORG), a
    ld a, (l2BackBank)
    ld (vidSvL2Back+DATA_WINDOW-OVL_ORG), a
    call data_restore

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
    ; sounding under the video. Resume needs nothing: the AKY tick
    ; rewrites PSG 1-3 every frame once audEnable is restored, a
    ; resumed beep re-silences via its own countdown, and an AYS
    ; stream rewrites its registers each tick. DI-bracketed ($FFFD
    ; select latch must not interleave).
    di
    ld a, $FF                    ; Turbo Sound select: music PSG 1
    call .psgpark
    ld a, $FE                    ; music PSG 2
    call .psgpark
    ld a, $FD                    ; PSG 3: music channels 7-9 + beep/
    call .psgpark                ; effect/stream - all frozen too
    ei

    ld hl, vid_run.entryret
    push hl
    ld a, VID_PAGE
    jp ovl_map_page

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

; ---------------------------------------------------------------------
; vid_run_l2setup_body - Layer 2 mode/clip/scroll per the v2 header,
; presentation isolation, BLACK palettes, CTC time-constant lookup,
; ISR select + end markers, the DMA session init, and the DEBUG
; timeline zero. Reads the vidP_* staging block directly (same page);
; writes to hot cells/code go through the MMU6 bracket (rubric 3).
; Hops back to vid_run.l2setupret. Corrupts everything.
; ---------------------------------------------------------------------
vid_run_l2setup_body:
    call data_save
    ld a, VID_PAGE
    call data_map_page
    ; presentation isolation: tilemap off, fallback black (restored
    ; on every real exit - vid_run_restore_body)
    ld e, NR_TM_CTRL
    call nr_read
    ld (vidSvNr6b+DATA_WINDOW-OVL_ORG), a
    and %01111111
    nextreg NR_TM_CTRL, a
    ld e, NR_FALLBACK
    call nr_read
    ld (vidSvNr4a+DATA_WINDOW-OVL_ORG), a
    xor a
    nextreg NR_FALLBACK, a
    ; NR $43 is not reliably readable: capture the game's convention
    ; (PAL_L2_FIRST - every L2 palette writer asserts it) and prime
    ; the double-buffer tracker to match (v1 finding, carried)
    ld a, PAL_L2_FIRST
    ld (vidSvNr43+DATA_WINDOW-OVL_ORG), a
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
 IFDEF DEBUG
    ; timeline baseline: zero vidTlTicks..vidErrOp (vidTlFillFrames
    ; sits outside the span - the open body already staged it)
    ld hl, vidTlTicks+DATA_WINDOW-OVL_ORG
    ld (hl), 0
    ld de, vidTlTicks+1+DATA_WINDOW-OVL_ORG
    ld bc, VID_TL_ZERO_LEN-1
    ldir
 ENDIF
    call data_restore
    ld hl, vid_run.l2setupret
    push hl
    ld a, VID_PAGE
    jp ovl_map_page

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
;   4. NR $69 = saved value - re-shows iff it was on pre-video
;   5. NR $15 layers, NR $43 palette ctrl
;   6. NR $6B tilemap, NR $4A fallback (presentation isolation)
;   7. MMU2 (the borrowed dest window)
;   8. ring banks freed
; Hops back to vid_run.restore_tail. Corrupts everything.
; ---------------------------------------------------------------------
vid_run_restore_body:
    call data_save
    ld a, VID_PAGE
    call data_map_page
    ld hl, (vidSvCtcStub+DATA_WINDOW-OVL_ORG)
    ld (IM2_CTC_STUB+1), hl
    ld a, (vidSvAudEnable+DATA_WINDOW-OVL_ORG)
    ld (audEnable), a
    ld a, (vidSvL2Front+DATA_WINDOW-OVL_ORG)
    ld (l2FrontBank), a
    ld a, (vidSvL2Back+DATA_WINDOW-OVL_ORG)
    ld (l2BackBank), a
    ; EXIT ORDER FIX steps 2-4 (see the header matrix)
    ld e, NR_DISPLAY_CTRL
    call nr_read
    and %01111111
    nextreg NR_DISPLAY_CTRL, a   ; hide Layer 2
    ld a, (vidSvNr12+DATA_WINDOW-OVL_ORG)
    nextreg NR_L2_BANK, a
    ld a, (vidSvNr70+DATA_WINDOW-OVL_ORG)
    nextreg NR_L2_CTRL, a
    ld a, (vidSvNr69+DATA_WINDOW-OVL_ORG)
    nextreg NR_DISPLAY_CTRL, a   ; re-show (iff it was on pre-video)
    ld a, (vidSvNr15+DATA_WINDOW-OVL_ORG)
    nextreg NR_LAYERS, a
    ld a, (vidSvNr43+DATA_WINDOW-OVL_ORG)
    nextreg NR_PAL_CTRL, a
    ld a, (vidSvNr6b+DATA_WINDOW-OVL_ORG)
    nextreg NR_TM_CTRL, a
    ld a, (vidSvNr4a+DATA_WINDOW-OVL_ORG)
    nextreg NR_FALLBACK, a
    ld a, (vidSvMmu2+DATA_WINDOW-OVL_ORG)
    nextreg NR_MMU2, a
    call vid_ring_free
    call data_restore
    ld hl, vid_run.restore_tail
    push hl
    ld a, VID_PAGE
    jp ovl_map_page

; ---------------------------------------------------------------------
; vid_open_video_body - build vidName ("NNN.VID",0) from the video
; number (C, set by vid_play), probe PARTn\ then root, open the
; winner raw (carried from v1; simplified: every cell this cluster
; touches now lives on THIS page, so the old MMU6 translations are
; gone). Out (via the hop back to vid_open_video_ret): B = 0 opened /
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
    ld a, 1
    ld (vidStrmMode), a          ; the player always opens raw
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
.haveresult:
    ld hl, vid_open_video_ret
    push hl
    ld a, VID_PAGE
    jp ovl_map_page

vidExtVid: db ".VID", 0

 IFDEF DEBUG
; DEBUG-only diagnostic prints - all reached strictly pre-arm (safe
; cold hops). Release stays silent on every failure, as v1 did.
vid_play_missing_body:
    ld b, 23
    ld c, 0
    call dbg_at
    ld hl, msgVidMissing
    call dbg_puts
    ld hl, vid_play.missingret
    push hl
    ld a, VID_PAGE
    jp ovl_map_page

; Open/load failure print: B = 1 VID FMT / 2 no bank / 3 exceeds the
; ring (stage 3a's not-yet-supported size error). B survives the hop
; (ovl_map_page corrupts AF only) and must survive back for nothing -
; the hot side falls into .restore_noplay regardless.
vid_open_fail_body:
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
    ld hl, msgVidTooBig          ; B = 3
.have:
    call dbg_puts
    ld hl, vid_run.openfailret
    push hl
    ld a, VID_PAGE
    jp ovl_map_page

msgVidMissing:  db "VID FILE?", 0
msgVidNoBank2:  db "VID NOBANK2", 0
msgVidBadFmt:   db "VID FMT?", 0
msgVidTooBig:   db "VID SIZE?", 0
 ENDIF

; ---------------------------------------------------------------------
; vid_stream_open_body - the real open (carried; IX = filename in,
; CF/A out; called same-page from vid_open_video_body). DISK_FILEMAP
; runs FIRST (before F_FSTAT - the sector-cache ordering law), then
; F_FSTAT for the size, then the raw cursor reset. All cells are
; page-local now (the old hot/cold translation dance is gone with
; the cluster's move). Corrupts AF, BC, DE, HL, IX.
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
    ld a, (vidStrmMode)
    or a
    jr z, vid_stream_open_fstat
    call vid_raw_setup           ; raw: capture + validate the filemap
    jr c, vid_stream_open_openfail
vid_stream_open_fstat:
    ld a, (vidHandle)            ; F_FSTAT - legal AFTER FILEMAP,
    ld ix, vidFstatBuf           ; before the card streams
    rst $08
    db ESX_F_FSTAT
    jr c, vid_stream_open_openfail
    ld hl, (vidFstatBuf+7)
    ld (vidSizeLo), hl
    ld hl, (vidFstatBuf+9)
    ld (vidSizeHi), hl
    ld a, (vidStrmMode)
    or a
    ret z                        ; F_READ mode: done (CF clear)
    call vid_raw_reset_cursor    ; same-page now - no hop needed
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
; SD STREAMING CLUSTER - 3b PARTS BIN. Moved wholesale from the hot
; page (SP15 3a): stage 3a plays resident only, so none of this runs
; while the CTC is armed - it serves the pre-arm resident load and
; will feed stage 3b's prefetch ring producer (which must re-hot the
; per-frame pieces it needs; the CMD18-window-persistence contract
; and every routine below are UNCHANGED from the v1-proven shapes).
; =====================================================================

; vid_stream_read - dual-mechanism read. In: A = dest 8K page (mapped
; at MMU6 for this call), DE = count <= $2000. Out: CF clear, BC =
; bytes read (short = EOF - callers count-check, the BC discipline);
; CF set, A = error. vidStrmMode 0 = esxDOS F_READ, 1 = raw CMD18.
; RAW CONTRACT (carried verbatim): the CMD18 window persists ACROSS
; calls (closed only at a fragment boundary, EOF, error, or
; vid_stream_close); while open, NO other filesystem/SD access may
; happen anywhere. Corrupts AF, BC, DE, HL, IX.
vid_stream_read:
    ld (vidReadPage), a
    ld a, (vidStrmMode)
    or a
    ld a, (vidReadPage)
    jr z, .fread
    jp vid_stream_read_raw
.fread:
    push af
    call data_save
    pop af
    call data_map_page
    ld a, (vidHandle)
    ld ix, DATA_WINDOW
    push de
    pop bc
    call esx_fread
    jr c, .fail
    push bc
    call data_restore
    pop bc
    or a
    ret
.fail:
    push af
    call data_restore
    pop af
    scf
    ret

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

; Streaming cluster cells (page-local; the hot page carries none).
vidStrmMode:       db 0          ; 0 = F_READ, 1 = raw card streaming
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
; frame-loop phases, then TOT/FRM/ERR/OP/FILL (FILL = the resident
; ring load's 50Hz-frame count - the new ring-fill row).
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
    jr nz, .nextrow
    ld hl, msgTlTot
    call dbg_puts
    ld hl, (vidTlTicksL)
    call dbg_hex16
    ld hl, msgTlFrm
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
    ld hl, msgTlFill
    call dbg_puts
    ld hl, (vidTlFillFramesL)
    call dbg_hex16
    jr .done
.nextrow:
    ld hl, vidTlRptRow
    inc (hl)
    ld hl, vidTlRptIdx
    inc (hl)
    jr .rowloop
.done:
    ld hl, vid_tl_report_ret
    push hl
    ld a, VID_PAGE
    jp ovl_map_page

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
msgTlFill: db " FILL=", 0
vidTlRptRow: db 0
vidTlRptIdx: db 0

; Page-local mirror of the hot instrument block (same order/sizes -
; one LDIR; the length is computed so it can never drift).
vidTlTicksL:      dw 0
vidTlLastTickL:   dw 0
vidTlLastPhaseL:  db 0
vidTlFramesL:     dw 0
vidTlAccL:        ds VID_TL_PHASES*4
vidErrCodeL:      db 0
vidErrOpL:        db 0
vidTlFillFramesL: dw 0
    ASSERT vidTlFillFramesL + 2 - vidTlTicksL == VID_TL_BLOCK_LEN
 ENDIF

    DISPLAY "video2 ends at ", $, " headroom ", /D, OVL_LIMIT - $
    ASSERT $ <= OVL_LIMIT
