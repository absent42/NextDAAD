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
