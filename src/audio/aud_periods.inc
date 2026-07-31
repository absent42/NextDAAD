; GENERATED - AY periods for jdaad FREQ_TABLE (clock 1773400Hz)
; Entries 100-107 are an extrapolated octave jdaad lacks (its own
; FREQ_TABLE stops at 100 entries while its range check still accepts
; tones up to 238, so jdaad reads past the end of its array there).
; LIVE since SP16 A4 raised h_beep's tone ceiling from 222 to 238 -
; DRC emits tones up to 238, so all 108 entries (tones 24..238, index
; (tone-24)/2) are reachable.
audPeriods:
    dw 4095, 4095, 4095, 4095, 4095, 4095
    dw 4095, 4095, 4095, 4030, 3804, 3590
    dw 3390, 3200, 3020, 2849, 2690, 2539
    dw 2397, 2262, 2135, 2015, 1902, 1795
    dw 1695, 1600, 1510, 1425, 1345, 1269
    dw 1199, 1131, 1067, 1008, 951, 898
    dw 847, 800, 755, 712, 673, 635
    dw 599, 565, 534, 504, 475, 449
    dw 424, 400, 378, 356, 336, 317
    dw 300, 283, 267, 252, 238, 224
    dw 212, 200, 189, 178, 168, 159
    dw 150, 141, 133, 126, 119, 112
    dw 106, 100, 94, 89, 84, 79
    dw 75, 71, 67, 63, 59, 56
    dw 53, 50, 47, 45, 42, 40
    dw 37, 35, 33, 31, 30, 28
    dw 26, 25, 24, 22, 21, 20
    dw 19, 18, 17, 16, 15, 14
