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
    jp dbg_hex8

SELFTEST_FREE_2MB equ 86    ; 14,15 + 28-47 + 48-111
SELFTEST_FREE_1MB equ 22    ; 14,15 + 28-47

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
    call bank_alloc         ; check 4: then bank 28
    cp BANK_POOL_B
    ld a, 4
    jr nz, .fail
    ld a, BANK_POOL_A_END   ; check 5: freed bank is reused first
    call bank_free
    call bank_alloc
    cp BANK_POOL_A_END
    ld a, 5
    jr nz, .fail
    call bank_window_save   ; checks 6,7: write/read through window
    ld a, BANK_POOL_A
    call bank_map_c000
    ld hl, WINDOW_ADDR
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
    call bank_window_restore
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
    call bank_window_restore
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

dbg_font:
    INCBIN "../tools/DAAD-READY/ASSETS/CHARSET/AD8x8.CHR"   ; 2048 bytes, 256 glyphs

msgTitle:   db "NEXTDAAD FOUNDATION", 0
msgCore:    db "CORE ", 0
msgMachine: db " MACHINE ", 0
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
    ret

 ENDIF

msgMissing:  db "ERROR: GAME.DDB NOT FOUND", 0
msgOversize: db "ERROR: GAME.DDB TOO BIG", 0
msgBadHdr:   db "ERROR: GAME.DDB BAD HEADER", 0

dbgX: db 0
dbgY: db 0
