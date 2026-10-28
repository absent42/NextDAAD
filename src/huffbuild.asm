; Text format 2 block validation and decode-table build (overlay0, run once
; per ddb_load through text2_load). Reads the block with rd_seek/rd_next.

; Out: A = DDB_OK, or DDB_E_TEXT2 with text2Err = T2E_*. Corrupts all.
t2_build:
    ld hl, (ddbHeader+HDR_TOKENS)
    ld (text2Block), hl
    call rd_seek
    call rd_next
    cp 'H'
    jr nz, .magic
    call rd_next
    cp '2'
.magic:
    ld c, T2E_MAGIC
    jp nz, .fail
    call rd_next                ; flags: bit 0 only
    ld c, T2E_FLAGS
    cp 2
    jp nc, .fail
    ld (text2Alpha), a
    call rd_next
    ld l, a
    call rd_next
    ld h, a
    ld (text2Ntok), hl
    ld c, T2E_NTOK
    ld a, h
    or l
    jp z, .fail
    ld de, TEXT2_NTOK_MAX0+1
    ld a, (text2Alpha)
    or a                        ; CF clear for the sbc
    jr z, .range
    ld de, TEXT2_NTOK_MAX1+1
.range:
    sbc hl, de
    jp nc, .fail
    call rd_next
    ld l, a
    call rd_next
    ld h, a
    ld (text2Fp), hl
    ; lengths field: 128 bytes << alpha; B = 0 counts 256 in t2_walk
    ld a, (text2Alpha)
    ld d, a
    rrca
    xor $80
    ld (t2Bytes), a
    ld e, a
    ld hl, (text2Block)
    ld bc, TEXT2_LENGTHS
    add hl, bc
    ld (t2Lens), hl
    add hl, de
    ld (text2Index), hl
    ld hl, hfOffs               ; per-length counts accumulate here first
    ld b, HF_MAXLEN*2
.zero:
    ld (hl), 0
    inc hl
    djnz .zero
    ld ix, t2_count
    call t2_walk
    ld hl, (t2Crc)
    ld de, (text2Fp)
    or a
    sbc hl, de
    ld c, T2E_FP
    jr nz, .fail
    ld hl, (t2Lens)             ; symbol 10 = lengths byte 5, low nibble
    ld de, 5
    add hl, de
    call rd_seek
    call rd_next
    and $0F
    ld c, T2E_EOM
    jr z, .fail
    ld hl, (text2Ntok)          ; highest coded symbol < 128 + ntok
    ld de, 128
    add hl, de
    ex de, hl
    ld hl, (t2Last)
    or a
    sbc hl, de
    ld c, T2E_SYM
    jr nc, .fail
    call t2_tables
    ld c, T2E_KRAFT
    jr c, .fail
    ld de, HF_SYM_MAX+1
    sbc hl, de                  ; CF clear from t2_tables
    ld c, T2E_BUDGET
    jr nc, .fail
    ld hl, 0
    ld (t2Pos), hl
    ld a, 1
.pass:                          ; one walk per length: canonical order
    ld (t2CurL), a
    ld ix, t2_place
    call t2_walk
    ld a, (t2CurL)
    inc a
    cp HF_MAXLEN+1
    jr c, .pass
    xor a                       ; DDB_OK
    ret
.fail:
    ld a, c
    ld (text2Err), a
    ld a, DDB_E_TEXT2
    ret

; Walk the lengths field: IX(A = length, DE = symbol) for every symbol,
; and the field's CRC-16 into t2Crc. IX must preserve DE and IX.
t2_walk:
    ld hl, (t2Lens)
    call rd_seek
    ld hl, $FFFF
    ld (t2Crc), hl
    ld de, 0
    ld a, (t2Bytes)
    ld b, a
.byte:
    push bc
    call rd_next
    push af
    call t2_crc
    pop af
    push af
    and $0F
    call .call
    inc de
    pop af
    swapnib
    and $0F
    call .call
    inc de
    pop bc
    djnz .byte
    ret
.call:
    jp (ix)

; CRC-16 CCITT step, poly $1021 (NDRC src/huff.c crc16_ccitt). A = byte.
; Corrupts AF, B, HL.
t2_crc:
    ld hl, (t2Crc)
    xor h
    ld h, a
    ld b, 8
.bit:
    add hl, hl
    jr nc, .next
    ld a, h
    xor $10
    ld h, a
    ld a, l
    xor $21
    ld l, a
.next:
    djnz .bit
    ld (t2Crc), hl
    ret

; Walk handler: count symbols per length, track the highest coded symbol.
t2_count:
    or a
    ret z
    ld (t2Last), de
    dec a
    add a, a
    ld hl, hfOffs
    add hl, a
    inc (hl)
    ret nz
    inc hl
    inc (hl)
    ret

; Counts (in hfOffs) -> hfLimit/hfOffs; hfHi = none. Out: CF set when a
; length over-subscribes its 2^L codes, else HL = symbols used, CF clear.
t2_tables:
    ld hl, 0
    ld (t2First), hl
    ld (t2Base), hl
    inc hl
    ld (t2Cap), hl
    ld ix, hfLimit
    ld b, HF_MAXLEN
.len:
    push bc
    ld hl, (t2Cap)
    add hl, hl
    ld (t2Cap), hl              ; 2^L
    ld c, (ix+HF_MAXLEN*2)
    ld b, (ix+HF_MAXLEN*2+1)    ; BC = count
    ld hl, (t2Base)
    ld de, (t2First)
    or a
    sbc hl, de
    ld (ix+HF_MAXLEN*2), l
    ld (ix+HF_MAXLEN*2+1), h    ; offs = base - first
    ld hl, (t2Base)
    add hl, bc
    ld (t2Base), hl
    ex de, hl
    add hl, bc                  ; limit = first + count
    ld (ix+0), l
    ld (ix+1), h
    ex de, hl
    ld hl, (t2Cap)
    or a
    sbc hl, de
    pop bc
    ret c                       ; limit > 2^L
    ex de, hl
    add hl, hl
    ld (t2First), hl
    inc ix
    inc ix
    djnz .len
    ld hl, hfHi
    ld b, HF_MAXLEN*2
.none:
    ld (hl), $FF
    inc hl
    djnz .none
    ld hl, (t2Base)
    or a                        ; first*2 at L = 15 can carry out
    ret

; Walk handler: append symbol DE of length t2CurL to hfSym; the first
; symbol >= 256 of the length sets hfHi. Preserves DE.
t2_place:
    ld hl, t2CurL
    cp (hl)
    ret nz
    ld hl, (t2Pos)
    ld b, h
    ld c, l
    inc hl
    ld (t2Pos), hl
    ld hl, hfSym
    add hl, bc
    ld (hl), e
    ld a, d
    or a
    ret z
    ld a, (t2CurL)
    dec a
    add a, a
    ld hl, hfHi
    add hl, a
    ld a, (hl)
    inc a
    ret nz                      ; already set: index < 256 keeps the high byte 0
    ld (hl), c
    inc hl
    ld (hl), b
    ret

t2Lens:   dw 0                  ; absolute address of the lengths field
t2Bytes:  db 0                  ; lengths size, 0 = 256
t2Crc:    dw 0
t2Last:   dw 0
t2First:  dw 0
t2Base:   dw 0
t2Cap:    dw 0
t2Pos:    dw 0
t2CurL:   db 0
