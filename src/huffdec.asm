; Text format 2 state and canonical decode tables (indexed L-1, words LE),
; built at load by t2_build (huffbuild.asm). Length-L code c hits when
; c < hfLimit; index = c + hfOffs; symbol = hfSym[index] + 256 if index >= hfHi.

; ddb_load's tail. Out: A = DDB_OK or DDB_E_TEXT2 (text2Err says why).
; Maps overlay0 at slot 7: ddb_load runs at boot (slot 7 free) or from
; overlay0's XPART, so the mapping is left as found.
text2_load:
    xor a
    ld (text2Err), a
    ld a, (ddbHeader)
    rlca
    and 1
    ld (textFormat), a
    ret z                       ; format 1: A = DDB_OK
    call data_save
    nextreg NR_MMU7, OVL0_PAGE
    call t2_build
    push af
    call data_restore
    pop af
    ret

textFormat: db 0                ; 0 = format 1 text, 1 = format 2
text2Alpha: db 0                ; flags bit 0: 1 = 511-symbol alphabet
text2Err:   db 0                ; T2E_* of the refusing check, 0 = none
text2Ntok:  dw 0
text2Block: dw 0                ; absolute DDB address of the text block
text2Index: dw 0                ; text2Block + TEXT2_LENGTHS + lengths size
text2Fp:    dw 0                ; block fingerprint (XMB header check)
hfLimit:    ds HF_MAXLEN*2      ; first code + count, per length
hfOffs:     ds HF_MAXLEN*2      ; list base - first code (mod 65536)
hfHi:       ds HF_MAXLEN*2      ; first index holding a symbol >= 256, $FFFF = none
hfSym:      ds HF_SYM_MAX       ; symbols low byte, canonical order
    ASSERT hfOffs == hfLimit + HF_MAXLEN*2

; Next format 2 symbol: canonical bit-serial decode, MSB first, from hfBuf
; (unread bits, then a 1 sentinel; $80 = empty). Out: HL = symbol 0-510,
; EOM if no code matches by length 15. Preserves BC. Corrupts AF, DE.
hf_sym:
    push bc
    ld de, 0
    ld hl, hfLimit
    ld b, 7
hfBuf equ $+1
    ld c, $80                   ; SMC: the bit buffer, held in C meanwhile
.short:                         ; lengths 1-7: code and limit fit a byte
    sla c
    call z, hf_fill
    rl e
    ld a, e
    cp (hl)
    jr c, .hit
    inc hl
    inc hl
    djnz .short
    ld b, HF_MAXLEN-7
.long:                          ; lengths 8-15: 16-bit compare (limit 256 at 8)
    sla c
    call z, hf_fill
    rl e
    rl d
    ld a, e
    sub (hl)
    inc hl
    ld a, d
    sbc a, (hl)
    jr c, .hitl
    inc hl
    djnz .long
    ld hl, 10
    pop bc
    ret
.hitl:
    dec hl
.hit:                           ; HL -> hfLimit[L-1], DE = code
    ld a, c
    ld (hfBuf), a
    ld a, HF_MAXLEN*2
    add hl, a                   ; -> hfOffs[L-1]
    ld a, (hl)
    add a, e
    ld e, a
    inc hl
    ld a, (hl)
    adc a, d
    ld d, a                     ; DE = list index
    ld a, HF_MAXLEN*2-1
    add hl, a                   ; -> hfHi[L-1]
    ld a, e
    sub (hl)
    inc hl
    ld a, d
    sbc a, (hl)
    sbc a, a
    inc a                       ; 1 = index at or past hfHi
    ld hl, hfSym
    add hl, de
    ld l, (hl)
    ld h, a
    pop bc
    ret

; Refill C: CF = top bit of the next stream byte, sentinel shifted in below.
hf_fill:
    call rd_next
    scf
    adc a, a
    ld c, a
    ret

; txt_next_decoded for format 2 text (same contract). Token k (symbol
; 128+k) is entry text2Block + index[k]: a length byte, then bytes; a byte
; >= 128 there fetches entry (byte-128) in place, one level, no rd_push.
t2_next:
    ld a, (tokActive)
    or a
    jr nz, .intok
    call hf_sym
    ld a, l
    inc h
    dec h
    jr nz, .tok
    or a
    jp p, txt_next_decoded.lit  ; literal: format 1's EOM test and return
.tok:
    ex de, hl
    call rd_push                ; preserves BC, DE
    ld hl, tokActive
    inc (hl)
    ex de, hl
    call t2_entry
.intok:
    call rd_next
    or a                        ; CF clear
    jp m, .ref
    ld hl, tokRemain
    dec (hl)
    ret nz
    push af                     ; last byte of the entry: unwind first
    call t2_unwind
    pop af
    ret
.ref:
    ld e, a
    ld hl, tokRemain
    dec (hl)
    jr z, .tail                 ; reference ends the entry: target replaces it
    ld a, (hl)
    ld (tokOuterRemain), a      ; park the outer entry
    ld a, (rdPage)
    ld (tokOuterPage), a
    ld hl, (rdPtr)
    ld (tokOuterPtr), hl
    ld hl, tokActive
    inc (hl)                    ; 2 = nested
.tail:
    ld l, e
    ld h, 0
    call t2_entry
    jr .intok

; HL = 128 + token number. Seeks its entry; tokRemain = its length.
; Corrupts AF, DE, HL.
t2_entry:
    add hl, hl
    ld de, (text2Index)
    add hl, de
    dec h                       ; index + 2*(HL-128)
    call rd_seek
    call rd_next
    ld e, a
    call rd_next
    ld d, a
    ld hl, (text2Block)
    add hl, de
    call rd_seek
    call rd_next
    ld (tokRemain), a
    ret

; An entry ran out: back to the parked outer entry (tokActive 2 -> 1) or
; to the message (1 -> 0). Corrupts AF, HL; preserves BC, DE.
t2_unwind:
    ld hl, tokActive
    dec (hl)
    jp z, rd_pop
    ld a, (tokOuterRemain)
    ld (tokRemain), a
    ld a, (tokOuterPage)
    ld hl, (tokOuterPtr)
    jp rd_seek_page

; rd_push/rd_pop: format 2 state for level A, then rd_slot. Preserves DE.
t2_push:
    call t2_save
    jp rd_slot

t2_pop:
    call t2_load
    jp rd_slot

; prn_more_check: tokActive and the format 2 state around SM32.
more_save:
    ld a, (tokActive)
    ld (moreSaveRdSv+4), a
    xor a
    ld (tokActive), a
    ld a, T2_MORE
; A = slot -> t2Save[A] = hfBuf, token cells. Preserves A, BC, DE.
t2_save:
    push bc
    push de
    call t2_slot
    ex de, hl
    ld hl, hfBuf
    ldi
    ld hl, tokRemain
    jr t2_copy

more_load:
    ld a, (moreSaveRdSv+4)
    ld (tokActive), a
    ld a, T2_MORE
; A = slot -> hfBuf, token cells = t2Save[A]. Preserves A, BC, DE.
t2_load:
    push bc
    push de
    call t2_slot
    ld de, hfBuf
    ldi
    ld de, tokRemain
t2_copy:
    ld bc, T2_CELLS
    ldir
    pop de
    pop bc
    ret

; A = slot -> HL = t2Save + A*T2_SLOT. Corrupts DE; keeps A.
t2_slot:
    ld d, T2_SLOT
    ld e, a
    mul d, e
    ld hl, t2Save
    add hl, de
    ret

T2_CELLS equ 5
T2_SLOT  equ T2_CELLS+1         ; hfBuf + cells
T2_MORE  equ 4                  ; slot after the four reader levels
tokRemain:      db 0            ; bytes left in the entry being read
tokOuterRemain: db 0            ; nested fetch: the outer entry's count,
tokOuterPage:   db 0            ; page and pointer past the reference
tokOuterPtr:    dw 0
    ASSERT tokOuterPtr+2-tokRemain == T2_CELLS
t2Save:         ds (T2_MORE+1)*T2_SLOT
