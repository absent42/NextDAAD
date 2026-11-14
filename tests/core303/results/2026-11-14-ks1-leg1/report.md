# CORE303 report

## STANDALONE ffeb784

NR: 01=33 0E=03 0F=00 03=33 05=5B 07=33  SRAM: 2048 KB

### Part 0

| tag | op | method | size | T/rep | T/unit | notes |
|---|---|---|---|---|---|---|
| CAL0 | poll | CPU | - | 337.05 | - |  |
| CAL1 | poll | CPU | - | 337.11 | - | 14MHz |

### Part 1a

| tag | op | method | size | T/rep | T/unit | notes |
|---|---|---|---|---|---|---|
| P1NP | NOP | CPU | - | 16720.84 | 4.00 | [documented=4 old-core=5] |
| P1RD | LD A,(HL) | CPU | - | 14682.72 | 7.00 | [documented=7.00 old-core=9.01] |
| P1WR | LD (HL),A | CPU | - | 14682.72 | 7.00 | [documented=7.00 old-core=8.01] |
| P1LI | LDI | CPU | - | 16740.60 | 16.02 | [documented=16.02 old-core=19.03] |
| P1LR | LDIR | CPU | - | 21866.04 | 21.02 | [documented=21.02 old-core=24.03] |
| P1OT | OTIR $FE | CPU | - | 21840.84 | 21.00 | [documented=21 old-core=24.01] |
| P1IN | IN A,(C) $FE | CPU | - | 12634.72 | 12.01 | [documented=12.01 old-core=14.01] |
| P1PP | PUSH+POP | CPU | - | 21840.84 | 21.00 | [documented=21 old-core=25] |
| P1JR | JR | CPU | - | 12625.30 | 12.00 | [documented=12 old-core=14] |
| P1X5 | NOP bank 5 | CPU | - | 16720.84 | 4.00 | [documented=4 old-core=5] |
| P1R5 | LD A,(HL) bank 5 | CPU | - | 14682.72 | 7.00 | [documented=7.00 old-core=9.01] |
| P1R7 | LD A,(HL) bank 7 | CPU | - | 14682.72 | 7.00 | [documented=7.00 old-core=8.01] |
| P1C1 | NOP | CPU | - | 16720.84 | 4.00 | 14MHz [documented=4 old-core=4] |
| P1C2 | LDIR | CPU | - | 21866.05 | 21.02 | 14MHz [documented=21.02 old-core=21.02] |

14 MHZ CONTROL P1C1: 4.00 T vs documented 4.00: OK
14 MHZ CONTROL P1C2: 21.02 T vs documented 21.02: OK

### Part 1b

| tag | op | method | size | T/rep | T/unit | notes |
|---|---|---|---|---|---|---|
| D0DT Q=003 | zxnDDMA detect | BLT | - | 972.05 | 635.00 |  |
| D0CP Q=002 | copy smoke | DMA | 256 | 1818.13 | 5.79 |  |
| DRC0 | rect 256x192 mode | CPU | 256 | 12551.05 | 47.71 |  |
| DRC1 | rect 256x192 mode | CPU | 1024 | 35446.65 | 34.29 |  |
| DRC2 | rect 256x192 mode | CPU | 4096 | 28646.06 | 27.65 |  |
| DRC3 | rect 256x192 mode | CPU | 12288 | 25258.55 | 24.34 |  |
| DRC4 | rect 256x192 mode | CPU | 49152 | 23565.27 | 22.68 |  |
| DRZ0 Q=002 | rect 256x192 mode | DMA | 256 | 19415.53 | 74.53 |  |
| DRZ1 Q=002 | rect 256x192 mode | DMA | 1024 | 40981.39 | 39.69 |  |
| DRZ2 Q=002 | rect 256x192 mode | DMA | 4096 | 23222.33 | 22.35 |  |
| DRZ3 Q=002 | rect 256x192 mode | DMA | 12288 | 14354.68 | 13.69 |  |
| DRZ4 Q=002 | rect 256x192 mode | DMA | 49152 | 9921.41 | 9.36 |  |
| DRB0 Q=003 | rect 256x192 mode | BLT | 256 | 2010.05 | 6.54 |  |
| DRB0 Q=002 | rect 256x192 mode | BLT | 256 | 1754.02 | 5.54 |  |
| DRB1 Q=003 | rect 256x192 mode | BLT | 1024 | 6617.90 | 6.13 |  |
| DRB1 Q=002 | rect 256x192 mode | BLT | 1024 | 5594.01 | 5.13 |  |
| DRB2 Q=003 | rect 256x192 mode | BLT | 4096 | 25050.44 | 6.03 |  |
| DRB2 Q=002 | rect 256x192 mode | BLT | 4096 | 20953.57 | 5.03 |  |
| DRB3 Q=003 | rect 256x192 mode | BLT | 12288 | 74199.58 | 6.01 |  |
| DRB3 Q=002 | rect 256x192 mode | BLT | 12288 | 61913.84 | 5.01 |  |
| DRB4 Q=003 | rect 256x192 mode | BLT | 49152 | 295384.20 | 6.00 |  |
| DRB4 Q=002 | rect 256x192 mode | BLT | 49152 | 246230.14 | 5.00 |  |
| DRB0 Q=102 | rect 256x192 mode | BLT | 256 | 1757.17 | 5.55 |  |
| DRB0 Q=112 | rect 256x192 mode | BLT | 256 | 1766.39 | 5.58 |  |
| DRB0 Q=202 | rect 256x192 mode | BLT | 256 | 1921.36 | 6.19 |  |
| DRB0 Q=212 | rect 256x192 mode | BLT | 256 | 2283.36 | 7.60 |  |
| DRB1 Q=102 | rect 256x192 mode | BLT | 1024 | 5603.87 | 5.14 |  |
| DRB1 Q=112 | rect 256x192 mode | BLT | 1024 | 5633.23 | 5.17 |  |
| DRB1 Q=202 | rect 256x192 mode | BLT | 1024 | 6130.46 | 5.66 |  |
| DRB1 Q=212 | rect 256x192 mode | BLT | 1024 | 7286.37 | 6.79 |  |
| DRB2 Q=102 | rect 256x192 mode | BLT | 4096 | 20990.81 | 5.04 |  |
| DRB2 Q=112 | rect 256x192 mode | BLT | 4096 | 21102.54 | 5.07 |  |
| DRB2 Q=202 | rect 256x192 mode | BLT | 4096 | 22967.16 | 5.52 |  |
| DRB2 Q=212 | rect 256x192 mode | BLT | 4096 | 27297.37 | 6.58 |  |
| DRB3 Q=102 | rect 256x192 mode | BLT | 12288 | 62023.48 | 5.02 |  |
| DRB3 Q=112 | rect 256x192 mode | BLT | 12288 | 62349.90 | 5.05 |  |
| DRB3 Q=202 | rect 256x192 mode | BLT | 12288 | 67864.26 | 5.50 |  |
| DRB3 Q=212 | rect 256x192 mode | BLT | 12288 | 80664.66 | 6.54 |  |
| DRB4 Q=102 | rect 256x192 mode | BLT | 49152 | 246673.82 | 5.01 |  |
| DRB4 Q=112 | rect 256x192 mode | BLT | 49152 | 247965.41 | 5.04 |  |
| DRB4 Q=202 | rect 256x192 mode | BLT | 49152 | 269912.56 | 5.48 |  |
| DRB4 Q=212 | rect 256x192 mode | BLT | 49152 | 320797.23 | 6.52 |  |
| DRZ0 Q=102 | rect 256x192 mode | DMA | 256 | 19449.09 | 74.66 |  |
| DRZ0 Q=112 | rect 256x192 mode | DMA | 256 | 19551.74 | 75.06 |  |
| DRZ0 Q=202 | rect 256x192 mode | DMA | 256 | 21233.61 | 81.63 |  |
| DRZ0 Q=212 | rect 256x192 mode | DMA | 256 | 25228.05 | 97.23 |  |
| DRZ1 Q=102 | rect 256x192 mode | DMA | 1024 | 41055.42 | 39.76 |  |
| DRZ1 Q=112 | rect 256x192 mode | DMA | 1024 | 41271.34 | 39.97 |  |
| DRZ1 Q=202 | rect 256x192 mode | DMA | 1024 | 44826.80 | 43.45 |  |
| DRZ1 Q=212 | rect 256x192 mode | DMA | 1024 | 53259.98 | 51.68 |  |
| DRZ2 Q=102 | rect 256x192 mode | DMA | 4096 | 23263.42 | 22.39 |  |
| DRZ2 Q=112 | rect 256x192 mode | DMA | 4096 | 23385.55 | 22.51 |  |
| DRZ2 Q=202 | rect 256x192 mode | DMA | 4096 | 25407.02 | 24.48 |  |
| DRZ2 Q=212 | rect 256x192 mode | DMA | 4096 | 30187.31 | 29.15 |  |
| DRZ3 Q=102 | rect 256x192 mode | DMA | 12288 | 14379.99 | 13.71 |  |
| DRZ3 Q=112 | rect 256x192 mode | DMA | 12288 | 14455.22 | 13.79 |  |
| DRZ3 Q=202 | rect 256x192 mode | DMA | 12288 | 15709.52 | 15.01 |  |
| DRZ3 Q=212 | rect 256x192 mode | DMA | 12288 | 18666.08 | 17.90 |  |
| DRZ4 Q=102 | rect 256x192 mode | DMA | 49152 | 9939.16 | 9.38 |  |
| DRZ4 Q=112 | rect 256x192 mode | DMA | 49152 | 9991.04 | 9.43 |  |
| DRZ4 Q=202 | rect 256x192 mode | DMA | 49152 | 10862.08 | 10.28 |  |
| DRZ4 Q=212 | rect 256x192 mode | DMA | 49152 | 12908.17 | 12.28 |  |
| DRB0 Q=103 | rect 256x192 mode | BLT | 256 | 2013.57 | 6.55 |  |
| DRB0 Q=113 | rect 256x192 mode | BLT | 256 | 2024.15 | 6.59 |  |
| DRB0 Q=203 | rect 256x192 mode | BLT | 256 | 2202.04 | 7.29 |  |
| DRB0 Q=213 | rect 256x192 mode | BLT | 256 | 2617.04 | 8.91 |  |
| DRB1 Q=103 | rect 256x192 mode | BLT | 1024 | 6629.86 | 6.15 |  |
| DRB1 Q=113 | rect 256x192 mode | BLT | 1024 | 6664.74 | 6.18 |  |
| DRB1 Q=203 | rect 256x192 mode | BLT | 1024 | 7252.81 | 6.75 |  |
| DRB1 Q=213 | rect 256x192 mode | BLT | 1024 | 8620.31 | 8.09 |  |
| DRB2 Q=103 | rect 256x192 mode | BLT | 4096 | 25094.47 | 6.04 |  |
| DRB2 Q=113 | rect 256x192 mode | BLT | 4096 | 25226.55 | 6.08 |  |
| DRB2 Q=203 | rect 256x192 mode | BLT | 4096 | 27456.86 | 6.62 |  |
| DRB2 Q=213 | rect 256x192 mode | BLT | 4096 | 32633.25 | 7.88 |  |
| DRB3 Q=103 | rect 256x192 mode | BLT | 12288 | 74333.58 | 6.02 |  |
| DRB3 Q=113 | rect 256x192 mode | BLT | 12288 | 74724.44 | 6.05 |  |
| DRB3 Q=203 | rect 256x192 mode | BLT | 12288 | 81335.51 | 6.59 |  |
| DRB3 Q=213 | rect 256x192 mode | BLT | 12288 | 96668.28 | 7.84 |  |
| DRB4 Q=103 | rect 256x192 mode | BLT | 49152 | 295918.05 | 6.01 |  |
| DRB4 Q=113 | rect 256x192 mode | BLT | 49152 | 297475.12 | 6.05 |  |
| DRB4 Q=203 | rect 256x192 mode | BLT | 49152 | 323782.24 | 6.58 |  |
| DRB4 Q=213 | rect 256x192 mode | BLT | 49152 | 384834.34 | 7.82 |  |
| DTC0 | transparent rect | CPU | 256 | 12662.94 | 48.15 |  |
| DTC1 | transparent rect | CPU | 1024 | 35671.59 | 34.51 |  |
| DTC2 | transparent rect | CPU | 4096 | 28757.86 | 27.75 |  |
| DTC3 | transparent rect | CPU | 12288 | 25314.60 | 24.39 |  |
| DTC4 | transparent rect | CPU | 49152 | 23593.82 | 22.71 |  |
| DTB0 Q=003 | transparent rect | BLT | 256 | 2009.95 | 6.53 |  |
| DTB0 Q=002 | transparent rect | BLT | 256 | 1754.09 | 5.54 |  |
| DTB1 Q=003 | transparent rect | BLT | 1024 | 6618.23 | 6.13 |  |
| DTB1 Q=002 | transparent rect | BLT | 1024 | 5594.01 | 5.13 |  |
| DTB2 Q=003 | transparent rect | BLT | 4096 | 25049.18 | 6.03 |  |
| DTB2 Q=002 | transparent rect | BLT | 4096 | 20953.57 | 5.03 |  |
| DTB3 Q=003 | transparent rect | BLT | 12288 | 74203.30 | 6.01 |  |
| DTB3 Q=002 | transparent rect | BLT | 12288 | 61913.84 | 5.01 |  |
| DTB4 Q=003 | transparent rect | BLT | 49152 | 295384.20 | 6.00 |  |
| DTB4 Q=002 | transparent rect | BLT | 49152 | 246230.14 | 5.00 |  |
| DCC0 | rect 320 row-major source | CPU | 256 | 26491.03 | 102.16 |  |
| DCC1 | rect 320 row-major source | CPU | 4096 | 23760.16 | 45.75 | SHORT |
| DCC2 | rect 320 row-major source | CPU | 20480 | 28745.87 | 44.39 |  |
| DCC3 | rect 320 row-major source | CPU | 81920 | 26219.11 | 40.44 |  |
| DCB0 Q=003 | rect 320 row-major source | BLT | 256 | 9507.76 | 35.82 |  |
| DCB0 Q=002 | rect 320 row-major source | BLT | 256 | 9251.77 | 34.82 |  |
| DCB1 Q=003 | rect 320 row-major source | BLT | 4096 | 7213.14 | 13.43 |  |
| DCB1 Q=002 | rect 320 row-major source | BLT | 4096 | 6701.06 | 12.43 |  |
| DCB2 Q=003 | rect 320 row-major source | BLT | 20480 | 6090.70 | 8.99 |  |
| DCB2 Q=002 | rect 320 row-major source | BLT | 20480 | 5450.73 | 7.99 |  |
| DCB3 Q=003 | rect 320 row-major source | BLT | 81920 | 5146.90 | 7.52 |  |
| DCB3 Q=002 | rect 320 row-major source | BLT | 81920 | 4506.88 | 6.52 |  |
| DKC0 | rect 320 col-major source | CPU | 256 | 12551.05 | 47.71 |  |
| DKC1 | rect 320 col-major source | CPU | 4096 | 28647.53 | 27.65 |  |
| DKC2 | rect 320 col-major source | CPU | 20480 | 25257.26 | 24.34 |  |
| DKC3 | rect 320 col-major source | CPU | 81920 | 23565.27 | 22.68 |  |
| DKZ0 Q=002 | rect 320 col-major source | DMA | 256 | 19414.55 | 74.52 |  |
| DKZ1 Q=002 | rect 320 col-major source | DMA | 4096 | 23222.33 | 22.35 |  |
| DKZ2 Q=002 | rect 320 col-major source | DMA | 20480 | 14354.00 | 13.69 |  |
| DKZ3 Q=002 | rect 320 col-major source | DMA | 81920 | 9920.96 | 9.36 |  |
| DKB0 Q=003 | rect 320 col-major source | BLT | 256 | 2010.05 | 6.54 |  |
| DKB0 Q=002 | rect 320 col-major source | BLT | 256 | 1754.02 | 5.54 |  |
| DKB1 Q=003 | rect 320 col-major source | BLT | 4096 | 25049.18 | 6.03 |  |
| DKB1 Q=002 | rect 320 col-major source | BLT | 4096 | 20954.42 | 5.03 |  |
| DKB2 Q=003 | rect 320 col-major source | BLT | 20480 | 123358.05 | 6.01 |  |
| DKB2 Q=002 | rect 320 col-major source | BLT | 20480 | 102871.95 | 5.01 |  |
| DKB3 Q=003 | rect 320 col-major source | BLT | 81920 | 246363.24 | 6.01 |  |
| DKB3 Q=002 | rect 320 col-major source | BLT | 81920 | 205402.21 | 5.01 |  |
| DFC0 | fill | CPU | 64 | 1665.01 | 20.75 |  |
| DFC1 | fill | CPU | 256 | 4602.01 | 16.66 |  |
| DFC2 | fill | CPU | 1024 | 16064.92 | 15.36 |  |
| DFC3 | fill | CPU | 4096 | 31346.65 | 15.14 |  |
| DFC4 | fill | CPU | 16384 | 31345.08 | 15.14 |  |
| DFZ0 Q=002 | fill | DMA | 64 | 1255.00 | 14.34 |  |
| DFZ1 Q=002 | fill | DMA | 256 | 2747.03 | 9.41 |  |
| DFZ2 Q=002 | fill | DMA | 1024 | 8183.04 | 7.66 |  |
| DFZ3 Q=002 | fill | DMA | 4096 | 30458.95 | 7.35 |  |
| DFZ4 Q=002 | fill | DMA | 16384 | 119027.56 | 7.24 |  |
| DFB0 Q=003 | fill | BLT | 64 | 714.02 | 5.89 |  |
| DFB0 Q=002 | fill | BLT | 64 | 650.05 | 4.89 |  |
| DFB1 Q=003 | fill | BLT | 256 | 1290.03 | 3.72 |  |
| DFB1 Q=002 | fill | BLT | 256 | 1034.06 | 2.72 |  |
| DFB2 Q=003 | fill | BLT | 1024 | 3593.91 | 3.18 |  |
| DFB2 Q=002 | fill | BLT | 1024 | 2570.15 | 2.18 |  |
| DFB3 Q=003 | fill | BLT | 4096 | 12810.45 | 3.05 |  |
| DFB3 Q=002 | fill | BLT | 4096 | 8713.99 | 2.05 |  |
| DFB4 Q=003 | fill | BLT | 16384 | 49674.68 | 3.01 |  |
| DFB4 Q=002 | fill | BLT | 16384 | 33290.09 | 2.01 |  |
| DFB0 Q=102 | fill | BLT | 64 | 651.19 | 4.91 |  |
| DFB0 Q=112 | fill | BLT | 64 | 654.62 | 4.96 |  |
| DFB0 Q=202 | fill | BLT | 64 | 711.20 | 5.85 |  |
| DFB0 Q=212 | fill | BLT | 64 | 844.90 | 7.94 |  |
| DFB1 Q=102 | fill | BLT | 256 | 1035.87 | 2.73 |  |
| DFB1 Q=112 | fill | BLT | 256 | 1041.24 | 2.75 |  |
| DFB1 Q=202 | fill | BLT | 256 | 1132.03 | 3.11 |  |
| DFB1 Q=212 | fill | BLT | 256 | 1345.18 | 3.94 |  |
| DFB2 Q=102 | fill | BLT | 1024 | 2574.53 | 2.19 |  |
| DFB2 Q=112 | fill | BLT | 1024 | 2588.06 | 2.20 |  |
| DFB2 Q=202 | fill | BLT | 1024 | 2815.77 | 2.42 |  |
| DFB2 Q=212 | fill | BLT | 1024 | 3346.45 | 2.94 |  |
| DFB3 Q=102 | fill | BLT | 4096 | 8729.74 | 2.05 |  |
| DFB3 Q=112 | fill | BLT | 4096 | 8775.24 | 2.06 |  |
| DFB3 Q=202 | fill | BLT | 4096 | 9550.51 | 2.25 |  |
| DFB3 Q=212 | fill | BLT | 4096 | 11350.89 | 2.69 |  |
| DFB4 Q=102 | fill | BLT | 16384 | 33348.60 | 2.01 |  |
| DFB4 Q=112 | fill | BLT | 16384 | 33524.15 | 2.03 |  |
| DFB4 Q=202 | fill | BLT | 16384 | 36488.36 | 2.21 |  |
| DFB4 Q=212 | fill | BLT | 16384 | 43368.07 | 2.63 |  |
| DFZ0 Q=102 | fill | DMA | 64 | 1257.35 | 14.38 |  |
| DFZ0 Q=112 | fill | DMA | 64 | 1263.93 | 14.48 |  |
| DFZ0 Q=202 | fill | DMA | 64 | 1373.14 | 16.19 |  |
| DFZ0 Q=212 | fill | DMA | 64 | 1631.52 | 20.23 |  |
| DFZ1 Q=102 | fill | DMA | 256 | 2751.93 | 9.43 |  |
| DFZ1 Q=112 | fill | DMA | 256 | 2766.35 | 9.49 |  |
| DFZ1 Q=202 | fill | DMA | 256 | 3007.23 | 10.43 |  |
| DFZ1 Q=212 | fill | DMA | 256 | 3573.39 | 12.64 |  |
| DFZ2 Q=102 | fill | DMA | 1024 | 8197.41 | 7.68 |  |
| DFZ2 Q=112 | fill | DMA | 1024 | 8240.50 | 7.72 |  |
| DFZ2 Q=202 | fill | DMA | 1024 | 8960.19 | 8.42 |  |
| DFZ2 Q=212 | fill | DMA | 1024 | 10649.52 | 10.07 |  |
| DFZ3 Q=102 | fill | DMA | 4096 | 30513.07 | 7.37 |  |
| DFZ3 Q=112 | fill | DMA | 4096 | 30672.76 | 7.41 |  |
| DFZ3 Q=202 | fill | DMA | 4096 | 33359.93 | 8.06 |  |
| DFZ3 Q=212 | fill | DMA | 4096 | 39644.94 | 9.60 |  |
| DFZ4 Q=102 | fill | DMA | 16384 | 119238.22 | 7.26 |  |
| DFZ4 Q=112 | fill | DMA | 16384 | 119875.34 | 7.30 |  |
| DFZ4 Q=202 | fill | DMA | 16384 | 130372.33 | 7.94 |  |
| DFZ4 Q=212 | fill | DMA | 16384 | 154932.10 | 9.44 |  |
| DFB0 Q=103 | fill | BLT | 64 | 715.34 | 5.91 |  |
| DFB0 Q=113 | fill | BLT | 64 | 719.04 | 5.97 |  |
| DFB0 Q=203 | fill | BLT | 64 | 781.27 | 6.94 |  |
| DFB0 Q=213 | fill | BLT | 64 | 928.31 | 9.24 |  |
| DFB1 Q=103 | fill | BLT | 256 | 1292.29 | 3.73 |  |
| DFB1 Q=113 | fill | BLT | 256 | 1299.13 | 3.76 |  |
| DFB1 Q=203 | fill | BLT | 256 | 1412.69 | 4.20 |  |
| DFB1 Q=213 | fill | BLT | 256 | 1678.81 | 5.24 |  |
| DFB2 Q=103 | fill | BLT | 1024 | 3600.40 | 3.19 |  |
| DFB2 Q=113 | fill | BLT | 1024 | 3619.33 | 3.21 |  |
| DFB2 Q=203 | fill | BLT | 1024 | 3938.30 | 3.52 |  |
| DFB2 Q=213 | fill | BLT | 1024 | 4680.45 | 4.24 |  |
| DFB3 Q=103 | fill | BLT | 4096 | 12832.96 | 3.05 |  |
| DFB3 Q=113 | fill | BLT | 4096 | 12900.49 | 3.07 |  |
| DFB3 Q=203 | fill | BLT | 4096 | 14040.17 | 3.35 |  |
| DFB3 Q=213 | fill | BLT | 4096 | 16687.41 | 3.99 |  |
| DFB4 Q=103 | fill | BLT | 16384 | 49762.01 | 3.02 |  |
| DFB4 Q=113 | fill | BLT | 16384 | 50024.01 | 3.03 |  |
| DFB4 Q=203 | fill | BLT | 16384 | 54448.02 | 3.30 |  |
| DFB4 Q=213 | fill | BLT | 16384 | 64713.32 | 3.93 |  |
| DSC0 | tilemap scroll | CPU | 1120 | 26707.71 | 23.55 |  |
| DSC1 | tilemap scroll | CPU | 3680 | 30461.72 | 23.53 |  |
| DSZ0 Q=002 | tilemap scroll | DMA | 1120 | 13581.58 | 11.83 |  |
| DSZ1 Q=002 | tilemap scroll | DMA | 3680 | 43677.78 | 11.78 |  |
| DSB0 Q=003 | tilemap scroll | BLT | 1120 | 7210.21 | 6.14 |  |
| DSB0 Q=002 | tilemap scroll | BLT | 1120 | 6090.06 | 5.14 |  |
| DSB1 Q=003 | tilemap scroll | BLT | 3680 | 22569.31 | 6.04 |  |
| DSB1 Q=002 | tilemap scroll | BLT | 3680 | 18890.01 | 5.04 |  |
| DVC0 | video COPY | CPU | 1 | 489.02 | 151.97 |  |
| DVC1 | video COPY | CPU | 4 | 537.08 | 50.01 |  |
| DVC2 | video COPY | CPU | 8 | 601.03 | 33.00 |  |
| DVC3 | video COPY | CPU | 16 | 729.07 | 24.50 |  |
| DVC4 | video COPY | CPU | 53 | 1351.05 | 19.13 |  |
| DVC5 | video COPY | CPU | 71 | 1648.95 | 18.48 |  |
| DVC6 | video COPY | CPU | 128 | 2590.99 | 17.61 |  |
| DVC7 | video COPY | CPU | 240 | 4452.95 | 17.15 |  |
| DVZ0 Q=002 | video COPY | DMA | 1 | 738.03 | 400.98 |  |
| DVZ1 Q=002 | video COPY | DMA | 4 | 753.04 | 104.00 |  |
| DVZ2 Q=002 | video COPY | DMA | 8 | 773.01 | 54.50 |  |
| DVZ3 Q=002 | video COPY | DMA | 16 | 813.04 | 29.75 |  |
| DVZ4 Q=002 | video COPY | DMA | 53 | 998.02 | 12.47 |  |
| DVZ5 Q=002 | video COPY | DMA | 71 | 1088.10 | 10.58 |  |
| DVZ6 Q=002 | video COPY | DMA | 128 | 1373.09 | 8.09 |  |
| DVZ7 Q=002 | video COPY | DMA | 240 | 1932.98 | 6.65 |  |
| DVB0 Q=003 | video COPY | BLT | 1 | 528.01 | 190.96 |  |
| DVB0 Q=002 | video COPY | BLT | 1 | 527.06 | 190.01 |  |
| DVB1 Q=003 | video COPY | BLT | 4 | 546.04 | 52.25 |  |
| DVB1 Q=002 | video COPY | BLT | 4 | 542.06 | 51.25 |  |
| DVB2 Q=003 | video COPY | BLT | 8 | 569.99 | 29.12 |  |
| DVB2 Q=002 | video COPY | BLT | 8 | 562.08 | 28.13 |  |
| DVB3 Q=003 | video COPY | BLT | 16 | 618.05 | 17.56 |  |
| DVB3 Q=002 | video COPY | BLT | 16 | 602.05 | 16.56 |  |
| DVB4 Q=003 | video COPY | BLT | 53 | 840.03 | 9.49 |  |
| DVB4 Q=002 | video COPY | BLT | 53 | 787.05 | 8.49 |  |
| DVB5 Q=003 | video COPY | BLT | 71 | 948.05 | 8.61 |  |
| DVB5 Q=002 | video COPY | BLT | 71 | 877.01 | 7.61 |  |
| DVB6 Q=003 | video COPY | BLT | 128 | 1290.03 | 7.45 |  |
| DVB6 Q=002 | video COPY | BLT | 128 | 1162.06 | 6.45 |  |
| DVB7 Q=003 | video COPY | BLT | 240 | 1961.94 | 6.77 |  |
| DVB7 Q=002 | video COPY | BLT | 240 | 1722.04 | 5.77 |  |
| DVB0 Q=102 | video COPY | BLT | 1 | 527.95 | 190.90 |  |
| DVB0 Q=112 | video COPY | BLT | 1 | 530.76 | 193.71 |  |
| DVB0 Q=202 | video COPY | BLT | 1 | 576.33 | 239.28 |  |
| DVB0 Q=212 | video COPY | BLT | 1 | 684.71 | 347.66 |  |
| DVB1 Q=102 | video COPY | BLT | 4 | 543.01 | 51.49 |  |
| DVB1 Q=112 | video COPY | BLT | 4 | 545.96 | 52.23 |  |
| DVB1 Q=202 | video COPY | BLT | 4 | 592.75 | 63.92 |  |
| DVB1 Q=212 | video COPY | BLT | 4 | 704.24 | 91.80 |  |
| DVB2 Q=102 | video COPY | BLT | 8 | 563.05 | 28.25 |  |
| DVB2 Q=112 | video COPY | BLT | 8 | 565.97 | 28.62 |  |
| DVB2 Q=202 | video COPY | BLT | 8 | 614.68 | 34.70 |  |
| DVB2 Q=212 | video COPY | BLT | 8 | 730.32 | 49.16 |  |
| DVB3 Q=102 | video COPY | BLT | 16 | 603.13 | 16.63 |  |
| DVB3 Q=112 | video COPY | BLT | 16 | 606.25 | 16.82 |  |
| DVB3 Q=202 | video COPY | BLT | 16 | 658.50 | 20.09 |  |
| DVB3 Q=212 | video COPY | BLT | 16 | 782.44 | 27.84 |  |
| DVB4 Q=102 | video COPY | BLT | 53 | 788.41 | 8.52 |  |
| DVB4 Q=112 | video COPY | BLT | 53 | 792.65 | 8.60 |  |
| DVB4 Q=202 | video COPY | BLT | 53 | 861.33 | 9.89 |  |
| DVB4 Q=212 | video COPY | BLT | 53 | 1023.40 | 12.95 |  |
| DVB5 Q=102 | video COPY | BLT | 71 | 878.58 | 7.63 |  |
| DVB5 Q=112 | video COPY | BLT | 71 | 883.25 | 7.69 |  |
| DVB5 Q=202 | video COPY | BLT | 71 | 959.91 | 8.77 |  |
| DVB5 Q=212 | video COPY | BLT | 71 | 1140.72 | 11.32 |  |
| DVB6 Q=102 | video COPY | BLT | 128 | 1164.08 | 6.46 |  |
| DVB6 Q=112 | video COPY | BLT | 128 | 1170.18 | 6.51 |  |
| DVB6 Q=202 | video COPY | BLT | 128 | 1272.33 | 7.31 |  |
| DVB6 Q=212 | video COPY | BLT | 128 | 1512.06 | 9.18 |  |
| DVB7 Q=102 | video COPY | BLT | 240 | 1725.09 | 5.78 |  |
| DVB7 Q=112 | video COPY | BLT | 240 | 1734.21 | 5.82 |  |
| DVB7 Q=202 | video COPY | BLT | 240 | 1886.11 | 6.45 |  |
| DVB7 Q=212 | video COPY | BLT | 240 | 2241.69 | 7.94 |  |
| DVZ0 Q=102 | video COPY | DMA | 1 | 739.35 | 402.30 |  |
| DVZ0 Q=112 | video COPY | DMA | 1 | 743.21 | 406.16 |  |
| DVZ0 Q=202 | video COPY | DMA | 1 | 806.98 | 469.93 |  |
| DVZ0 Q=212 | video COPY | DMA | 1 | 958.76 | 621.71 |  |
| DVZ1 Q=102 | video COPY | DMA | 4 | 754.32 | 104.32 |  |
| DVZ1 Q=112 | video COPY | DMA | 4 | 758.35 | 105.33 |  |
| DVZ1 Q=202 | video COPY | DMA | 4 | 823.43 | 121.59 |  |
| DVZ1 Q=212 | video COPY | DMA | 4 | 978.40 | 160.34 |  |
| DVZ2 Q=102 | video COPY | DMA | 8 | 774.43 | 54.67 |  |
| DVZ2 Q=112 | video COPY | DMA | 8 | 778.47 | 55.18 |  |
| DVZ2 Q=202 | video COPY | DMA | 8 | 845.41 | 63.54 |  |
| DVZ2 Q=212 | video COPY | DMA | 8 | 1004.71 | 83.46 |  |
| DVZ3 Q=102 | video COPY | DMA | 16 | 814.43 | 29.84 |  |
| DVZ3 Q=112 | video COPY | DMA | 16 | 818.81 | 30.11 |  |
| DVZ3 Q=202 | video COPY | DMA | 16 | 889.24 | 34.51 |  |
| DVZ3 Q=212 | video COPY | DMA | 16 | 1056.48 | 44.96 |  |
| DVZ4 Q=102 | video COPY | DMA | 53 | 999.82 | 12.51 |  |
| DVZ4 Q=112 | video COPY | DMA | 53 | 1005.06 | 12.60 |  |
| DVZ4 Q=202 | video COPY | DMA | 53 | 1092.00 | 14.24 |  |
| DVZ4 Q=212 | video COPY | DMA | 53 | 1297.53 | 18.12 |  |
| DVZ5 Q=102 | video COPY | DMA | 71 | 1089.98 | 10.60 |  |
| DVZ5 Q=112 | video COPY | DMA | 71 | 1095.72 | 10.69 |  |
| DVZ5 Q=202 | video COPY | DMA | 71 | 1190.75 | 12.02 |  |
| DVZ5 Q=212 | video COPY | DMA | 71 | 1414.81 | 15.18 |  |
| DVZ6 Q=102 | video COPY | DMA | 128 | 1375.46 | 8.11 |  |
| DVZ6 Q=112 | video COPY | DMA | 128 | 1382.75 | 8.17 |  |
| DVZ6 Q=202 | video COPY | DMA | 128 | 1503.04 | 9.11 |  |
| DVZ6 Q=212 | video COPY | DMA | 128 | 1786.31 | 11.32 |  |
| DVZ7 Q=102 | video COPY | DMA | 240 | 1936.45 | 6.66 |  |
| DVZ7 Q=112 | video COPY | DMA | 240 | 1946.63 | 6.71 |  |
| DVZ7 Q=202 | video COPY | DMA | 240 | 2116.92 | 7.42 |  |
| DVZ7 Q=212 | video COPY | DMA | 240 | 2515.67 | 9.08 |  |
| DVB0 Q=103 | video COPY | BLT | 1 | 528.96 | 191.90 |  |
| DVB0 Q=113 | video COPY | BLT | 1 | 531.74 | 194.69 |  |
| DVB0 Q=203 | video COPY | BLT | 1 | 577.41 | 240.36 |  |
| DVB0 Q=213 | video COPY | BLT | 1 | 685.99 | 348.94 |  |
| DVB1 Q=103 | video COPY | BLT | 4 | 547.02 | 52.49 |  |
| DVB1 Q=113 | video COPY | BLT | 4 | 549.91 | 53.22 |  |
| DVB1 Q=203 | video COPY | BLT | 4 | 598.12 | 65.27 |  |
| DVB1 Q=213 | video COPY | BLT | 4 | 709.42 | 93.09 |  |
| DVB2 Q=103 | video COPY | BLT | 8 | 571.04 | 29.25 |  |
| DVB2 Q=113 | video COPY | BLT | 8 | 574.08 | 29.63 |  |
| DVB2 Q=203 | video COPY | BLT | 8 | 623.44 | 35.80 |  |
| DVB2 Q=213 | video COPY | BLT | 8 | 740.68 | 50.45 |  |
| DVB3 Q=103 | video COPY | BLT | 16 | 619.16 | 17.63 |  |
| DVB3 Q=113 | video COPY | BLT | 16 | 622.36 | 17.83 |  |
| DVB3 Q=203 | video COPY | BLT | 16 | 676.01 | 21.19 |  |
| DVB3 Q=213 | video COPY | BLT | 16 | 803.33 | 29.14 |  |
| DVB4 Q=103 | video COPY | BLT | 53 | 841.54 | 9.52 |  |
| DVB4 Q=113 | video COPY | BLT | 53 | 845.95 | 9.60 |  |
| DVB4 Q=203 | video COPY | BLT | 53 | 919.36 | 10.99 |  |
| DVB4 Q=213 | video COPY | BLT | 53 | 1092.41 | 14.25 |  |
| DVB5 Q=103 | video COPY | BLT | 71 | 949.76 | 8.63 |  |
| DVB5 Q=113 | video COPY | BLT | 71 | 954.83 | 8.70 |  |
| DVB5 Q=203 | video COPY | BLT | 71 | 1037.78 | 9.87 |  |
| DVB5 Q=213 | video COPY | BLT | 71 | 1233.07 | 12.62 |  |
| DVB6 Q=103 | video COPY | BLT | 128 | 1292.29 | 7.46 |  |
| DVB6 Q=113 | video COPY | BLT | 128 | 1299.13 | 7.52 |  |
| DVB6 Q=203 | video COPY | BLT | 128 | 1412.63 | 8.40 |  |
| DVB6 Q=213 | video COPY | BLT | 128 | 1678.81 | 10.48 |  |
| DVB7 Q=103 | video COPY | BLT | 240 | 1965.58 | 6.79 |  |
| DVB7 Q=113 | video COPY | BLT | 240 | 1975.90 | 6.83 |  |
| DVB7 Q=203 | video COPY | BLT | 240 | 2149.24 | 7.55 |  |
| DVB7 Q=213 | video COPY | BLT | 240 | 2554.21 | 9.24 |  |
| DUZ0 Q=002 | setup | DMA | 1 | 721.06 | 384.01 |  |
| DUZ1 Q=002 | setup | DMA | 1 | 543.04 | 205.99 |  |
| DUB0 Q=003 | setup | BLT | 1 | 720.05 | 383.00 |  |
| DUB0 Q=002 | setup | BLT | 1 | 719.01 | 381.96 |  |
| DUB1 Q=003 | setup | BLT | 1 | 496.03 | 158.98 |  |
| DUB1 Q=002 | setup | BLT | 1 | 495.00 | 157.95 |  |

BREAK-EVEN part 1b fill BLT Q=002: below 64
BREAK-EVEN part 1b fill BLT Q=003: below 64
BREAK-EVEN part 1b fill BLT Q=102: below 64
BREAK-EVEN part 1b fill BLT Q=103: below 64
BREAK-EVEN part 1b fill BLT Q=112: below 64
BREAK-EVEN part 1b fill BLT Q=113: below 64
BREAK-EVEN part 1b fill BLT Q=202: below 64
BREAK-EVEN part 1b fill BLT Q=203: below 64
BREAK-EVEN part 1b fill BLT Q=212: below 64
BREAK-EVEN part 1b fill BLT Q=213: below 64
BREAK-EVEN part 1b fill DMA Q=002: below 64
BREAK-EVEN part 1b fill DMA Q=102: below 64
BREAK-EVEN part 1b fill DMA Q=112: below 64
BREAK-EVEN part 1b fill DMA Q=202: below 64
BREAK-EVEN part 1b fill DMA Q=212: below 64
BREAK-EVEN part 1b rect 256x192 mode BLT Q=002: below 256
BREAK-EVEN part 1b rect 256x192 mode BLT Q=003: below 256
BREAK-EVEN part 1b rect 256x192 mode BLT Q=102: below 256
BREAK-EVEN part 1b rect 256x192 mode BLT Q=103: below 256
BREAK-EVEN part 1b rect 256x192 mode BLT Q=112: below 256
BREAK-EVEN part 1b rect 256x192 mode BLT Q=113: below 256
BREAK-EVEN part 1b rect 256x192 mode BLT Q=202: below 256
BREAK-EVEN part 1b rect 256x192 mode BLT Q=203: below 256
BREAK-EVEN part 1b rect 256x192 mode BLT Q=212: below 256
BREAK-EVEN part 1b rect 256x192 mode BLT Q=213: below 256
BREAK-EVEN part 1b rect 256x192 mode DMA Q=002: 2576
BREAK-EVEN part 1b rect 256x192 mode DMA Q=102: 2592
BREAK-EVEN part 1b rect 256x192 mode DMA Q=112: 2639
BREAK-EVEN part 1b rect 256x192 mode DMA Q=202: 3308
BREAK-EVEN part 1b rect 256x192 mode DMA Q=212: 5649
BREAK-EVEN part 1b rect 320 col-major source BLT Q=002: below 256
BREAK-EVEN part 1b rect 320 col-major source BLT Q=003: below 256
BREAK-EVEN part 1b rect 320 col-major source DMA Q=002: 3463
BREAK-EVEN part 1b rect 320 row-major source BLT Q=002: below 256
BREAK-EVEN part 1b rect 320 row-major source BLT Q=003: below 256
BREAK-EVEN part 1b tilemap scroll BLT Q=002: below 1120
BREAK-EVEN part 1b tilemap scroll BLT Q=003: below 1120
BREAK-EVEN part 1b tilemap scroll DMA Q=002: below 1120
BREAK-EVEN part 1b transparent rect BLT Q=002: below 256
BREAK-EVEN part 1b transparent rect BLT Q=003: below 256
BREAK-EVEN part 1b video COPY BLT Q=002: 5
BREAK-EVEN part 1b video COPY BLT Q=003: 6
BREAK-EVEN part 1b video COPY BLT Q=102: 5
BREAK-EVEN part 1b video COPY BLT Q=103: 6
BREAK-EVEN part 1b video COPY BLT Q=112: 6
BREAK-EVEN part 1b video COPY BLT Q=113: 6
BREAK-EVEN part 1b video COPY BLT Q=202: 11
BREAK-EVEN part 1b video COPY BLT Q=203: 12
BREAK-EVEN part 1b video COPY BLT Q=212: 29
BREAK-EVEN part 1b video COPY BLT Q=213: 35
BREAK-EVEN part 1b video COPY DMA Q=002: 33
BREAK-EVEN part 1b video COPY DMA Q=102: 33
BREAK-EVEN part 1b video COPY DMA Q=112: 34
BREAK-EVEN part 1b video COPY DMA Q=202: 41
BREAK-EVEN part 1b video COPY DMA Q=212: 52
WAIT STATES: ABSENT


## Gates

- quiet_check: OK: quiet timed paths are instruction-identical to release
- bench_check: OK: bench image is instruction-identical to release outside IFDEF BENCH
