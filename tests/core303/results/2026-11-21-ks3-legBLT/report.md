# CORE303 report

## STANDALONE 989ce72

NR: 01=33 0E=03 0F=03 03=33 05=5B 07=33  SRAM: 2048 KB

### Part 0

| tag | op | method | size | T/rep | T/unit | notes |
|---|---|---|---|---|---|---|
| CAL0 | poll | CPU | - | 337.05 | - |  |

### Part 1b

| tag | op | method | size | T/rep | T/unit | notes |
|---|---|---|---|---|---|---|
| D0DT Q=003 | zxnDDMA detect | BLT | - | 972.97 | 635.92 |  |

### Part 3X

| tag | op | method | size | T/rep | T/unit | notes |
|---|---|---|---|---|---|---|
| XCP0 | span | CPU | 1 | 489.02 | 151.97 |  |
| XCP1 | span | CPU | 4 | 537.06 | 50.00 |  |
| XCP2 | span | CPU | 8 | 601.03 | 33.00 |  |
| XCP3 | span | CPU | 16 | 729.07 | 24.50 |  |
| XCP4 | span | CPU | 53 | 1350.98 | 19.13 |  |
| XCP5 | span | CPU | 71 | 1649.03 | 18.48 |  |
| XCP6 | span | CPU | 128 | 2590.99 | 17.61 |  |
| XCP7 | span | CPU | 240 | 4452.95 | 17.15 |  |
| XLN0 Q=002 | span | BLT linear | 1 | 1160.05 | 823.00 |  |
| XLN1 Q=002 | span | BLT linear | 4 | 1175.10 | 209.51 |  |
| XLN2 Q=002 | span | BLT linear | 8 | 1195.12 | 107.26 |  |
| XLN3 Q=002 | span | BLT linear | 16 | 1235.06 | 56.13 |  |
| XLN4 Q=002 | span | BLT linear | 53 | 1433.06 | 20.68 |  |
| XLN5 Q=002 | span | BLT linear | 71 | 1523.06 | 16.70 |  |
| XLN6 Q=002 | span | BLT linear | 128 | 1821.03 | 11.59 |  |
| XLN7 Q=002 | span | BLT linear | 240 | 2407.07 | 8.63 |  |
| XRF0 Q=002 | span | BLT row | 1 | 1159.99 | 822.94 |  |
| XRF1 Q=002 | span | BLT row | 4 | 1175.10 | 209.51 |  |
| XRF2 Q=002 | span | BLT row | 8 | 1195.06 | 107.25 |  |
| XRF3 Q=002 | span | BLT row | 16 | 1235.06 | 56.13 |  |
| XRF4 Q=002 | span | BLT row | 53 | 1432.99 | 20.68 |  |
| XRF5 Q=002 | span | BLT row | 71 | 1523.06 | 16.70 |  |
| XRF6 Q=002 | span | BLT row | 128 | 1821.11 | 11.59 |  |
| XRF7 Q=002 | span | BLT row | 240 | 2407.07 | 8.63 |  |
| XRR0 Q=002 | span | BLT row reload | 1 | 698.04 | 360.99 |  |
| XRR1 Q=002 | span | BLT row reload | 4 | 713.09 | 94.01 |  |
| XRR2 Q=002 | span | BLT row reload | 8 | 733.02 | 49.50 |  |
| XRR3 Q=002 | span | BLT row reload | 16 | 773.01 | 27.25 |  |
| XRR4 Q=002 | span | BLT row reload | 53 | 971.07 | 11.96 |  |
| XRR5 Q=002 | span | BLT row reload | 71 | 1061.06 | 10.20 |  |
| XRR6 Q=002 | span | BLT row reload | 128 | 1359.07 | 7.98 |  |
| XRR7 Q=002 | span | BLT row reload | 240 | 1945.08 | 6.70 |  |
| XKF0 Q=002 | span | BLT column | 1 | 1159.99 | 822.94 |  |
| XKF1 Q=002 | span | BLT column | 4 | 1175.10 | 209.51 |  |
| XKF2 Q=002 | span | BLT column | 8 | 1195.06 | 107.25 |  |
| XKF3 Q=002 | span | BLT column | 16 | 1235.06 | 56.13 |  |
| XKF4 Q=002 | span | BLT column | 53 | 1432.99 | 20.68 |  |
| XKF5 Q=002 | span | BLT column | 71 | 1523.06 | 16.70 |  |
| XKF6 Q=002 | span | BLT column | 128 | 1821.03 | 11.59 |  |
| XKF7 Q=002 | span | BLT column | 240 | 2407.07 | 8.63 |  |
| XKR0 Q=002 | span | BLT column reload | 1 | 698.00 | 360.95 |  |
| XKR1 Q=002 | span | BLT column reload | 4 | 713.09 | 94.01 |  |
| XKR2 Q=002 | span | BLT column reload | 8 | 733.02 | 49.50 |  |
| XKR3 Q=002 | span | BLT column reload | 16 | 773.05 | 27.25 |  |
| XKR4 Q=002 | span | BLT column reload | 53 | 971.07 | 11.96 |  |
| XKR5 Q=002 | span | BLT column reload | 71 | 1061.11 | 10.20 |  |
| XKR6 Q=002 | span | BLT column reload | 128 | 1359.07 | 7.98 |  |
| XKR7 Q=002 | span | BLT column reload | 240 | 1945.08 | 6.70 |  |
| XSP0 Q=002 | row 256, reload, pad 320 | BLT | - | 2051.05 | 6.70 |  |
| XSP1 Q=002 | block 256x16, reload, pad 4096 | BLT | - | 22186.85 | 5.33 |  |
| XSP2 Q=002 | block 256x16, full program, pad 4096 | BLT | - | 22649.09 | 5.45 |  |
| XSP3 Q=002 | column 320, reload, pad 320 | BLT | - | 2370.98 | 6.36 |  |
| XSP4 Q=002 | column 320, full program, pad 320 | BLT | - | 2833.03 | 7.80 |  |
| XSP5 Q=002 | row 256, full program, pad 320 | BLT | - | 2512.97 | 8.50 |  |

### Part 3Y

| tag | op | method | size | T/rep | T/unit | notes |
|---|---|---|---|---|---|---|
| YCP0 Q=202 | span | CPU | 1 | 534.72 | 197.67 |  |
| YCP1 Q=202 | span | CPU | 4 | 587.21 | 62.54 |  |
| YCP2 Q=202 | span | CPU | 8 | 657.22 | 40.02 |  |
| YCP3 Q=202 | span | CPU | 16 | 797.20 | 28.76 |  |
| YCP4 Q=202 | span | CPU | 53 | 1477.23 | 21.51 |  |
| YCP5 Q=202 | span | CPU | 71 | 1803.12 | 20.65 |  |
| YCP6 Q=202 | span | CPU | 128 | 2833.11 | 19.50 |  |
| YCP7 Q=202 | span | CPU | 240 | 4869.07 | 18.88 |  |
| YLN0 Q=202 | span | BLT linear | 1 | 1268.48 | 931.43 |  |
| YLN1 Q=202 | span | BLT linear | 4 | 1284.89 | 236.96 |  |
| YLN2 Q=202 | span | BLT linear | 8 | 1306.89 | 121.23 |  |
| YLN3 Q=202 | span | BLT linear | 16 | 1350.65 | 63.35 |  |
| YLN4 Q=202 | span | BLT linear | 53 | 1567.90 | 23.22 |  |
| YLN5 Q=202 | span | BLT linear | 71 | 1666.69 | 18.73 |  |
| YLN6 Q=202 | span | BLT linear | 128 | 1993.38 | 12.94 |  |
| YLN7 Q=202 | span | BLT linear | 240 | 2635.92 | 9.58 |  |
| YRF0 Q=202 | span | BLT row | 1 | 1268.48 | 931.43 |  |
| YRF1 Q=202 | span | BLT row | 4 | 1284.89 | 236.96 |  |
| YRF2 Q=202 | span | BLT row | 8 | 1306.89 | 121.23 |  |
| YRF3 Q=202 | span | BLT row | 16 | 1350.65 | 63.35 |  |
| YRF4 Q=202 | span | BLT row | 53 | 1567.90 | 23.22 |  |
| YRF5 Q=202 | span | BLT row | 71 | 1666.69 | 18.73 |  |
| YRF6 Q=202 | span | BLT row | 128 | 1993.38 | 12.94 |  |
| YRF7 Q=202 | span | BLT row | 240 | 2635.92 | 9.58 |  |
| YRR0 Q=202 | span | BLT row reload | 1 | 763.31 | 426.26 |  |
| YRR1 Q=202 | span | BLT row reload | 4 | 779.73 | 110.67 |  |
| YRR2 Q=202 | span | BLT row reload | 8 | 801.65 | 58.08 |  |
| YRR3 Q=202 | span | BLT row reload | 16 | 845.52 | 31.78 |  |
| YRR4 Q=202 | span | BLT row reload | 53 | 1062.74 | 13.69 |  |
| YRR5 Q=202 | span | BLT row reload | 71 | 1161.42 | 11.61 |  |
| YRR6 Q=202 | span | BLT row reload | 128 | 1488.20 | 8.99 |  |
| YRR7 Q=202 | span | BLT row reload | 240 | 2130.81 | 7.47 |  |
| YKF0 Q=202 | span | BLT column | 1 | 1268.48 | 931.43 |  |
| YKF1 Q=202 | span | BLT column | 4 | 1284.89 | 236.96 |  |
| YKF2 Q=202 | span | BLT column | 8 | 1306.95 | 121.24 |  |
| YKF3 Q=202 | span | BLT column | 16 | 1350.65 | 63.35 |  |
| YKF4 Q=202 | span | BLT column | 53 | 1567.90 | 23.22 |  |
| YKF5 Q=202 | span | BLT column | 71 | 1666.69 | 18.73 |  |
| YKF6 Q=202 | span | BLT column | 128 | 1993.38 | 12.94 |  |
| YKF7 Q=202 | span | BLT column | 240 | 2635.92 | 9.58 |  |
| YKR0 Q=202 | span | BLT column reload | 1 | 763.27 | 426.22 |  |
| YKR1 Q=202 | span | BLT column reload | 4 | 779.73 | 110.67 |  |
| YKR2 Q=202 | span | BLT column reload | 8 | 801.65 | 58.08 |  |
| YKR3 Q=202 | span | BLT column reload | 16 | 845.52 | 31.78 |  |
| YKR4 Q=202 | span | BLT column reload | 53 | 1062.74 | 13.69 |  |
| YKR5 Q=202 | span | BLT column reload | 71 | 1161.47 | 11.61 |  |
| YKR6 Q=202 | span | BLT column reload | 128 | 1488.26 | 8.99 |  |
| YKR7 Q=202 | span | BLT column reload | 240 | 2130.81 | 7.47 |  |
| YSP0 Q=202 | row 256, reload, pad 320 | BLT | - | 2246.96 | 7.46 |  |
| YSP1 Q=202 | block 256x16, reload, pad 4096 | BLT | - | 24328.78 | 5.86 |  |
| YSP2 Q=202 | block 256x16, full program, pad 4096 | BLT | - | 24834.53 | 5.98 |  |
| YSP3 Q=202 | column 320, reload, pad 320 | BLT | - | 2598.07 | 7.07 |  |
| YSP4 Q=202 | column 320, full program, pad 320 | BLT | - | 3103.13 | 8.64 |  |
| YSP5 Q=202 | row 256, full program, pad 320 | BLT | - | 2752.25 | 9.43 |  |
| YPF0 Q=202 | pad proof: block 256x16, full program | BLT | - | 24923.96 | 6.00 |  |
| YPF1 Q=202 | pad proof: block 256x16, reload | BLT | - | 24418.71 | 5.88 |  |
| YPF2 Q=202 | pad proof: row 256, reload | BLT | - | 2336.63 | 7.81 |  |
| YPF3 Q=202 | pad proof: column 320, reload | BLT | - | 2687.69 | 7.35 |  |
| YPF4 Q=202 | pad proof: column 320, full program | BLT | - | 3192.54 | 8.92 |  |

### Part 3Z

| tag | op | method | size | T/rep | T/unit | notes |
|---|---|---|---|---|---|---|
| ZCP0 Q=212 | span | CPU | 1 | 787.66 | 450.61 |  |
| ZCP1 Q=212 | span | CPU | 4 | 864.81 | 131.94 |  |
| ZCP2 Q=212 | span | CPU | 8 | 968.01 | 78.87 |  |
| ZCP3 Q=212 | span | CPU | 16 | 1174.33 | 52.33 |  |
| ZCP4 Q=212 | span | CPU | 53 | 2175.86 | 34.69 |  |
| ZCP5 Q=212 | span | CPU | 71 | 2655.93 | 32.66 |  |
| ZCP6 Q=212 | span | CPU | 128 | 4172.99 | 29.97 |  |
| ZCP7 Q=212 | span | CPU | 240 | 7171.39 | 28.48 |  |
| ZLN0 Q=212 | span | BLT linear | 1 | 1868.20 | 1531.15 |  |
| ZLN1 Q=212 | span | BLT linear | 4 | 1892.42 | 388.84 |  |
| ZLN2 Q=212 | span | BLT linear | 8 | 1925.24 | 198.52 |  |
| ZLN3 Q=212 | span | BLT linear | 16 | 1989.87 | 103.30 |  |
| ZLN4 Q=212 | span | BLT linear | 53 | 2310.54 | 37.24 |  |
| ZLN5 Q=212 | span | BLT linear | 71 | 2456.17 | 29.85 |  |
| ZLN6 Q=212 | span | BLT linear | 128 | 2939.05 | 20.33 |  |
| ZLN7 Q=212 | span | BLT linear | 240 | 3887.73 | 14.79 |  |
| ZRF0 Q=212 | span | BLT row | 1 | 1868.26 | 1531.20 |  |
| ZRF1 Q=212 | span | BLT row | 4 | 1892.48 | 388.86 |  |
| ZRF2 Q=212 | span | BLT row | 8 | 1925.13 | 198.51 |  |
| ZRF3 Q=212 | span | BLT row | 16 | 1990.11 | 103.32 |  |
| ZRF4 Q=212 | span | BLT row | 53 | 2310.47 | 37.23 |  |
| ZRF5 Q=212 | span | BLT row | 71 | 2456.17 | 29.85 |  |
| ZRF6 Q=212 | span | BLT row | 128 | 2939.05 | 20.33 |  |
| ZRF7 Q=212 | span | BLT row | 240 | 3887.73 | 14.79 |  |
| ZRR0 Q=212 | span | BLT row reload | 1 | 1124.15 | 787.10 |  |
| ZRR1 Q=212 | span | BLT row reload | 4 | 1148.62 | 202.89 |  |
| ZRR2 Q=212 | span | BLT row reload | 8 | 1180.90 | 105.48 |  |
| ZRR3 Q=212 | span | BLT row reload | 16 | 1246.08 | 56.81 |  |
| ZRR4 Q=212 | span | BLT row reload | 53 | 1566.38 | 23.19 |  |
| ZRR5 Q=212 | span | BLT row reload | 71 | 1712.23 | 19.37 |  |
| ZRR6 Q=212 | span | BLT row reload | 128 | 2194.78 | 14.51 |  |
| ZRR7 Q=212 | span | BLT row reload | 240 | 3144.01 | 11.70 |  |
| ZKF0 Q=212 | span | BLT column | 1 | 1868.14 | 1531.09 |  |
| ZKF1 Q=212 | span | BLT column | 4 | 1892.48 | 388.86 |  |
| ZKF2 Q=212 | span | BLT column | 8 | 1925.24 | 198.52 |  |
| ZKF3 Q=212 | span | BLT column | 16 | 1990.17 | 103.32 |  |
| ZKF4 Q=212 | span | BLT column | 53 | 2310.54 | 37.24 |  |
| ZKF5 Q=212 | span | BLT column | 71 | 2456.17 | 29.85 |  |
| ZKF6 Q=212 | span | BLT column | 128 | 2939.13 | 20.33 |  |
| ZKF7 Q=212 | span | BLT column | 240 | 3887.84 | 14.79 |  |
| ZKR0 Q=212 | span | BLT column reload | 1 | 1124.08 | 787.03 |  |
| ZKR1 Q=212 | span | BLT column reload | 4 | 1148.62 | 202.89 |  |
| ZKR2 Q=212 | span | BLT column reload | 8 | 1180.86 | 105.48 |  |
| ZKR3 Q=212 | span | BLT column reload | 16 | 1246.23 | 56.82 |  |
| ZKR4 Q=212 | span | BLT column reload | 53 | 1566.29 | 23.19 |  |
| ZKR5 Q=212 | span | BLT column reload | 71 | 1712.23 | 19.37 |  |
| ZKR6 Q=212 | span | BLT column reload | 128 | 2194.78 | 14.51 |  |
| ZKR7 Q=212 | span | BLT column reload | 240 | 3144.01 | 11.70 |  |
| ZSP0 Q=212 | row 256, reload, pad 320 | BLT | - | 3315.52 | 11.63 |  |
| ZSP1 Q=212 | block 256x16, reload, pad 4096 | BLT | - | 35927.71 | 8.69 |  |
| ZSP2 Q=212 | block 256x16, full program, pad 4096 | BLT | - | 36670.97 | 8.87 |  |
| ZSP3 Q=212 | column 320, reload, pad 320 | BLT | - | 3833.62 | 10.93 |  |
| ZSP4 Q=212 | column 320, full program, pad 320 | BLT | - | 4577.72 | 13.25 |  |
| ZSP5 Q=212 | row 256, full program, pad 320 | BLT | - | 4060.66 | 14.55 |  |
| ZPF0 Q=212 | pad proof: block 256x16, full program | BLT | - | 36805.12 | 8.90 |  |
| ZPF1 Q=212 | pad proof: block 256x16, reload | BLT | - | 36058.52 | 8.72 |  |
| ZPF2 Q=212 | pad proof: row 256, reload | BLT | - | 3447.68 | 12.15 |  |
| ZPF3 Q=212 | pad proof: column 320, reload | BLT | - | 3965.84 | 11.34 |  |
| ZPF4 Q=212 | pad proof: column 320, full program | BLT | - | 4710.12 | 13.67 |  |

BREAK-EVEN part 3X span BLT column reload Q=002: 27
BREAK-EVEN part 3X span BLT column Q=002: 62
BREAK-EVEN part 3X span BLT linear Q=002: 62
BREAK-EVEN part 3X span BLT row reload Q=002: 27
BREAK-EVEN part 3X span BLT row Q=002: 62
BREAK-EVEN part 3Y span BLT column reload Q=202: 27
BREAK-EVEN part 3Y span BLT column Q=202: 62
BREAK-EVEN part 3Y span BLT linear Q=202: 62
BREAK-EVEN part 3Y span BLT row reload Q=202: 27
BREAK-EVEN part 3Y span BLT row Q=202: 62
BREAK-EVEN part 3Z span BLT column reload Q=212: 27
BREAK-EVEN part 3Z span BLT column Q=212: 62
BREAK-EVEN part 3Z span BLT linear Q=212: 62
BREAK-EVEN part 3Z span BLT row reload Q=212: 27
BREAK-EVEN part 3Z span BLT row Q=212: 62


## Gates

- quiet_check: n/a: standalone bench, no interpreter image
- bench_check: n/a: standalone bench, no interpreter image
