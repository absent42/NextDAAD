nrList:      db $01, $0E, $0F, $03, $05, $07
NR_COUNT     equ $ - nrList
nrVals:      ds NR_COUNT
sramExp:     db 0
rtTab:       dw 0
rtRow:       dw 0
rtNum:       dw 0
rtTotal:     dw 0
rtS:         db 0
rtF:         dw 0
rtD:         dw 0
rtCk:        dw 0
rtCkState:   db 0
rtKind:      db 0
rtL:         db 0
ulaPos:      dw 0
rowTxtBound: db "BOUND", 0
txtRow:      db "ROW ", 0
txtDone:     db "DONE", 0
font:
    INCBIN "../../../src/font.chr", 32 * 8, 96 * 8   ; ASCII 32-127
    ASSERT $ - font == 96 * 8
