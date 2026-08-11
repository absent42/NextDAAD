; Program the two pairs reserved for system text, in the FIRST palette
; (the displayed one). Pair 0 = paper 0 / ink 7, pair 1 = paper 3 /
; ink 7. Their bits are set in pairUsed at boot and never cleared, so
; neither reclaim nor eviction can take them. Both use classic colours
; only, so tm_pal_write9 (which indexes dadPalette) serves directly.
; Corrupts AF, BC, DE, HL.
tm_reserved_pairs:
    nextreg NR_PAL_CTRL, PAL_TM_FIRST
    nextreg NR_PAL_INDEX, 0
    ld a, 0                     ; pair 0 paper
    call tm_pal_write9
    ld a, 7                     ; pair 0 ink
    call tm_pal_write9
    ld a, 3                     ; pair 1 paper
    call tm_pal_write9
    ld a, 7                     ; pair 1 ink
    call tm_pal_write9
    ret

; A = logical colour 0-255. Out: DE = its 9-bit value, D = RRRGGGBB and
; E = blue LSB in bit 0. There is no colour table anywhere: colours 0-15
; are the classic ULA entries already resident in dadPalette, and 16-255
; ARE their own RRRGGGBB value, so the answer is computed. The ninth bit
; for a computed colour is (B1 OR B0), which is exactly what the core
; derives on an NR $41 write (zxnext.vhd line 5425) - reproduced here so
; every palette write in this module can go through NR $44 uniformly.
; Touches no palette register at all, so NR $43 is left alone.
; Preserves BC. Corrupts AF, HL.
pal_colour:
    cp 16
    jr nc, .computed
    add a, a                    ; classic: two bytes per entry
    ld l, a
    ld h, 0
    ld de, dadPalette
    add hl, de
    ld d, (hl)                  ; byte 0 = RRRGGGBB
    inc hl
    ld e, (hl)                  ; byte 1 = blue LSB
    ret
.computed:
    ld d, a                     ; RRRGGGBB is the number itself
    and 3                       ; the two blue bits
    jr z, .noblue                ; both clear: ninth bit clear
    ld a, 1                      ; either set: ninth bit set (B1 OR B0)
.noblue:
    ld e, a
    ret
