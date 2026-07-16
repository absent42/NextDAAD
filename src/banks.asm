; Bank allocator and MMU paging helpers.
; Static map (see nextdaad.inc): 0-8 system, 9-13 Layer 2, 14-15 pool,
; 16-23 DDB, 24-27 audio, 28 overlay 0, 29-47 pool, 48-111 expansion
; pool if present.

; Map 8K physical page A into slot 6 ($C000-$DFFF).
; Corrupts AF only. Never touches D.
data_map_page:
    nextreg NR_MMU6, a
    ret

; Save/restore slot 6 only. Preserves DE.
data_save:
    push de                     ; nr_read needs E as scratch; callers
    ld e, NR_MMU6               ; must not lose their DE - this closed
    call nr_read                ; a five-incident defect class
    ld (savedMMU6), a
    pop de
    ret

data_restore:
    ld a, (savedMMU6)
    nextreg NR_MMU6, a
    ret

; Map 8K page A into slot 7 (code overlay). DISPATCHER/ISR ONLY.
; Corrupts AF only. Never touches D.
ovl_map_page:
    nextreg NR_MMU7, a
    ret

; Detect expansion RAM (banks 48-111) by write/read-back of two
; patterns in bank 48. Preserves the probed byte. CSpect always has
; expansion; real unexpanded hardware is the FORCE_1MB code path.
ram_detect:
 IFDEF FORCE_1MB
    xor a
    ld (ramExpanded), a
    ret
 ELSE
    call data_save
    ld a, BANK_EXP_FIRST*2
    call data_map_page
    ld hl, DATA_WINDOW
    ld a, (hl)
    ld c, a                 ; original byte
    ld a, $A5
    ld (hl), a
    ld a, (hl)
    cp $A5
    jr nz, .absent
    ld a, $5A
    ld (hl), a
    ld a, (hl)
    cp $5A
    jr nz, .absent
    ld a, 1
    jr .store
.absent:
    xor a
.store:
    ld (ramExpanded), a
    ld (hl), c              ; restore probed byte
    call data_restore
    ret
 ENDIF

bank_table_init:
    ld hl, bankTable
    ld b, BANK_TABLE_SIZE
    xor a                   ; BT_RESERVED
.zero:
    ld (hl), a
    inc hl
    djnz .zero
    ld a, BT_FREE
    ld (bankTable+BANK_POOL_A), a
    ld (bankTable+BANK_POOL_A_END), a
    ld hl, bankTable+BANK_POOL_B
    ld b, BANK_BASE_LAST-BANK_POOL_B+1
.pool:
    ld (hl), a
    inc hl
    djnz .pool
    ld a, (ramExpanded)
    or a
    ret z
    ld hl, bankTable+BANK_EXP_FIRST
    ld b, BANK_EXP_LAST-BANK_EXP_FIRST+1
    ld a, BT_FREE
.exp:
    ld (hl), a
    inc hl
    djnz .exp
    ret

; Allocate the lowest free bank. Out: A = bank, CF clear.
; CF set when nothing is free - A is then undefined. Never touches D.
bank_alloc:
    ld hl, bankTable
    ld b, BANK_TABLE_SIZE
    ld c, 0
.scan:
    ld a, (hl)
    cp BT_FREE
    jr z, .got
    inc hl
    inc c
    djnz .scan
    scf
    ret
.got:
    ld a, BT_USED
    ld (hl), a
    ld a, c
    or a                    ; clear CF
    ret

; Free bank A.
; No bounds check - bankTable is followed by code; an out-of-range free corrupts it. Never touches D.
bank_free:
    push hl
    push de
    ld e, a
    ld d, 0
    ld hl, bankTable
    add hl, de
    ld (hl), BT_FREE
    pop de
    pop hl
    ret

; Out: A = number of free banks.
; Corrupts AF. Never touches D.
bank_count_free:
    push hl
    push bc
    ld hl, bankTable
    ld b, BANK_TABLE_SIZE
    ld c, 0
.scan:
    ld a, (hl)
    cp BT_FREE
    jr nz, .next
    inc c
.next:
    inc hl
    djnz .scan
    ld a, c
    pop bc
    pop hl
    ret

savedMMU6:   db 0
ramExpanded: db 0
bankTable:   ds BANK_TABLE_SIZE
