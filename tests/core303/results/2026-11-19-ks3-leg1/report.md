# CORE303 report

## STANDALONE ffeb784

NR: 01=33 0E=03 0F=03 03=33 05=5B 07=33  SRAM: 2048 KB

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
| D0DT Q=003 | zxnDDMA detect | BLT | - | 973.02 | 635.97 |  |
| D0CP Q=002 | copy smoke | DMA | 256 | 1818.99 | 5.79 |  |
| DRC0 | rect 256x192 mode | CPU | 256 | 12551.05 | 47.71 |  |
| DRC1 | rect 256x192 mode | CPU | 1024 | 35446.65 | 34.29 |  |
| DRC2 | rect 256x192 mode | CPU | 4096 | 28646.06 | 27.65 |  |
| DRC3 | rect 256x192 mode | CPU | 12288 | 25258.55 | 24.34 |  |
| DRC4 | rect 256x192 mode | CPU | 49152 | 23565.27 | 22.68 |  |
| DRZ0 Q=002 | rect 256x192 mode | DMA | 256 | 19431.32 | 74.59 |  |
| DRZ1 Q=002 | rect 256x192 mode | DMA | 1024 | 41014.30 | 39.72 |  |
| DRZ2 Q=002 | rect 256x192 mode | DMA | 4096 | 23239.45 | 22.37 |  |
| DRZ3 Q=002 | rect 256x192 mode | DMA | 12288 | 14362.20 | 13.70 |  |
| DRZ4 Q=002 | rect 256x192 mode | DMA | 49152 | 9925.51 | 9.36 |  |
| DRB0 Q=003 | rect 256x192 mode | BLT | 256 | 2011.15 | 6.54 |  |
| DRB0 Q=002 | rect 256x192 mode | BLT | 256 | 1755.07 | 5.54 |  |
| DRB1 Q=003 | rect 256x192 mode | BLT | 1024 | 6619.23 | 6.13 |  |
| DRB1 Q=002 | rect 256x192 mode | BLT | 1024 | 5594.93 | 5.13 |  |
| DRB2 Q=003 | rect 256x192 mode | BLT | 4096 | 25050.44 | 6.03 |  |
| DRB2 Q=002 | rect 256x192 mode | BLT | 4096 | 20954.42 | 5.03 |  |
| DRB3 Q=003 | rect 256x192 mode | BLT | 12288 | 74203.30 | 6.01 |  |
| DRB3 Q=002 | rect 256x192 mode | BLT | 12288 | 61916.33 | 5.01 |  |
| DRB4 Q=003 | rect 256x192 mode | BLT | 49152 | 295384.20 | 6.00 |  |
| DRB4 Q=002 | rect 256x192 mode | BLT | 49152 | 246240.00 | 5.00 |  |
| DRB0 Q=102 | rect 256x192 mode | BLT | 256 | 1758.14 | 5.55 |  |
| DRB0 Q=112 | rect 256x192 mode | BLT | 256 | 1767.37 | 5.59 |  |
| DRB0 Q=202 | rect 256x192 mode | BLT | 256 | 1923.31 | 6.20 |  |
| DRB0 Q=212 | rect 256x192 mode | BLT | 256 | 2285.76 | 7.61 |  |
| DRB1 Q=102 | rect 256x192 mode | BLT | 1024 | 5604.79 | 5.14 |  |
| DRB1 Q=112 | rect 256x192 mode | BLT | 1024 | 5634.15 | 5.17 |  |
| DRB1 Q=202 | rect 256x192 mode | BLT | 1024 | 6135.04 | 5.66 |  |
| DRB1 Q=212 | rect 256x192 mode | BLT | 1024 | 7292.33 | 6.79 |  |
| DRB2 Q=102 | rect 256x192 mode | BLT | 4096 | 20991.66 | 5.04 |  |
| DRB2 Q=112 | rect 256x192 mode | BLT | 4096 | 21103.38 | 5.07 |  |
| DRB2 Q=202 | rect 256x192 mode | BLT | 4096 | 22981.55 | 5.53 |  |
| DRB2 Q=212 | rect 256x192 mode | BLT | 4096 | 27317.68 | 6.59 |  |
| DRB3 Q=102 | rect 256x192 mode | BLT | 12288 | 62025.97 | 5.02 |  |
| DRB3 Q=112 | rect 256x192 mode | BLT | 12288 | 62352.39 | 5.05 |  |
| DRB3 Q=202 | rect 256x192 mode | BLT | 12288 | 67906.62 | 5.50 |  |
| DRB3 Q=212 | rect 256x192 mode | BLT | 12288 | 80721.97 | 6.54 |  |
| DRB4 Q=102 | rect 256x192 mode | BLT | 49152 | 246673.82 | 5.01 |  |
| DRB4 Q=112 | rect 256x192 mode | BLT | 49152 | 247965.41 | 5.04 |  |
| DRB4 Q=202 | rect 256x192 mode | BLT | 49152 | 270080.17 | 5.49 |  |
| DRB4 Q=212 | rect 256x192 mode | BLT | 49152 | 321033.86 | 6.52 |  |
| DRZ0 Q=102 | rect 256x192 mode | DMA | 256 | 19464.88 | 74.72 |  |
| DRZ0 Q=112 | rect 256x192 mode | DMA | 256 | 19567.53 | 75.12 |  |
| DRZ0 Q=202 | rect 256x192 mode | DMA | 256 | 21251.38 | 81.70 |  |
| DRZ0 Q=212 | rect 256x192 mode | DMA | 256 | 25249.77 | 97.32 |  |
| DRZ1 Q=102 | rect 256x192 mode | DMA | 1024 | 41088.32 | 39.80 |  |
| DRZ1 Q=112 | rect 256x192 mode | DMA | 1024 | 41304.24 | 40.01 |  |
| DRZ1 Q=202 | rect 256x192 mode | DMA | 1024 | 44865.88 | 43.49 |  |
| DRZ1 Q=212 | rect 256x192 mode | DMA | 1024 | 53305.22 | 51.73 |  |
| DRZ2 Q=102 | rect 256x192 mode | DMA | 4096 | 23279.40 | 22.40 |  |
| DRZ2 Q=112 | rect 256x192 mode | DMA | 4096 | 23401.53 | 22.52 |  |
| DRZ2 Q=202 | rect 256x192 mode | DMA | 4096 | 25427.56 | 24.50 |  |
| DRZ2 Q=212 | rect 256x192 mode | DMA | 4096 | 30212.43 | 29.18 |  |
| DRZ3 Q=102 | rect 256x192 mode | DMA | 12288 | 14387.51 | 13.72 |  |
| DRZ3 Q=112 | rect 256x192 mode | DMA | 12288 | 14464.79 | 13.80 |  |
| DRZ3 Q=202 | rect 256x192 mode | DMA | 12288 | 15721.83 | 15.02 |  |
| DRZ3 Q=212 | rect 256x192 mode | DMA | 12288 | 18681.12 | 17.91 |  |
| DRZ4 Q=102 | rect 256x192 mode | DMA | 49152 | 9942.80 | 9.38 |  |
| DRZ4 Q=112 | rect 256x192 mode | DMA | 49152 | 9995.14 | 9.43 |  |
| DRZ4 Q=202 | rect 256x192 mode | DMA | 49152 | 10869.82 | 10.29 |  |
| DRZ4 Q=212 | rect 256x192 mode | DMA | 49152 | 12916.81 | 12.28 |  |
| DRB0 Q=103 | rect 256x192 mode | BLT | 256 | 2014.58 | 6.55 |  |
| DRB0 Q=113 | rect 256x192 mode | BLT | 256 | 2025.16 | 6.59 |  |
| DRB0 Q=203 | rect 256x192 mode | BLT | 256 | 2204.15 | 7.29 |  |
| DRB0 Q=213 | rect 256x192 mode | BLT | 256 | 2619.86 | 8.92 |  |
| DRB1 Q=103 | rect 256x192 mode | BLT | 1024 | 6630.85 | 6.15 |  |
| DRB1 Q=113 | rect 256x192 mode | BLT | 1024 | 6665.74 | 6.18 |  |
| DRB1 Q=203 | rect 256x192 mode | BLT | 1024 | 7258.12 | 6.76 |  |
| DRB1 Q=213 | rect 256x192 mode | BLT | 1024 | 8627.29 | 8.10 |  |
| DRB2 Q=103 | rect 256x192 mode | BLT | 4096 | 25095.72 | 6.04 |  |
| DRB2 Q=113 | rect 256x192 mode | BLT | 4096 | 25227.81 | 6.08 |  |
| DRB2 Q=203 | rect 256x192 mode | BLT | 4096 | 27474.47 | 6.63 |  |
| DRB2 Q=213 | rect 256x192 mode | BLT | 4096 | 32658.41 | 7.89 |  |
| DRB3 Q=103 | rect 256x192 mode | BLT | 12288 | 74333.58 | 6.02 |  |
| DRB3 Q=113 | rect 256x192 mode | BLT | 12288 | 74724.44 | 6.05 |  |
| DRB3 Q=203 | rect 256x192 mode | BLT | 12288 | 81383.90 | 6.60 |  |
| DRB3 Q=213 | rect 256x192 mode | BLT | 12288 | 96739.00 | 7.85 |  |
| DRB4 Q=103 | rect 256x192 mode | BLT | 49152 | 295918.05 | 6.01 |  |
| DRB4 Q=113 | rect 256x192 mode | BLT | 49152 | 297475.12 | 6.05 |  |
| DRB4 Q=203 | rect 256x192 mode | BLT | 49152 | 323989.85 | 6.58 |  |
| DRB4 Q=213 | rect 256x192 mode | BLT | 49152 | 385116.10 | 7.83 |  |
| DTC0 | transparent rect | CPU | 256 | 12662.94 | 48.15 |  |
| DTC1 | transparent rect | CPU | 1024 | 35669.74 | 34.50 |  |
| DTC2 | transparent rect | CPU | 4096 | 28757.86 | 27.75 |  |
| DTC3 | transparent rect | CPU | 12288 | 25314.60 | 24.39 |  |
| DTC4 | transparent rect | CPU | 49152 | 23593.82 | 22.71 |  |
| DTB0 Q=003 | transparent rect | BLT | 256 | 2011.26 | 6.54 |  |
| DTB0 Q=002 | transparent rect | BLT | 256 | 1755.07 | 5.54 |  |
| DTB1 Q=003 | transparent rect | BLT | 1024 | 6619.23 | 6.13 |  |
| DTB1 Q=002 | transparent rect | BLT | 1024 | 5595.16 | 5.13 |  |
| DTB2 Q=003 | transparent rect | BLT | 4096 | 25051.70 | 6.03 |  |
| DTB2 Q=002 | transparent rect | BLT | 4096 | 20954.42 | 5.03 |  |
| DTB3 Q=003 | transparent rect | BLT | 12288 | 74199.58 | 6.01 |  |
| DTB3 Q=002 | transparent rect | BLT | 12288 | 61913.84 | 5.01 |  |
| DTB4 Q=003 | transparent rect | BLT | 49152 | 295384.20 | 6.00 |  |
| DTB4 Q=002 | transparent rect | BLT | 49152 | 246230.14 | 5.00 |  |
| DCC0 | rect 320 row-major source | CPU | 256 | 26491.03 | 102.16 |  |
| DCC1 | rect 320 row-major source | CPU | 4096 | 23761.72 | 45.75 |  |
| DCC2 | rect 320 row-major source | CPU | 20480 | 28745.87 | 44.39 |  |
| DCC3 | rect 320 row-major source | CPU | 81920 | 26219.11 | 40.44 |  |
| DCB0 Q=003 | rect 320 row-major source | BLT | 256 | 9524.31 | 35.89 |  |
| DCB0 Q=002 | rect 320 row-major source | BLT | 256 | 9267.89 | 34.89 |  |
| DCB1 Q=003 | rect 320 row-major source | BLT | 4096 | 7220.91 | 13.45 |  |
| DCB1 Q=002 | rect 320 row-major source | BLT | 4096 | 6709.02 | 12.45 |  |
| DCB2 Q=003 | rect 320 row-major source | BLT | 20480 | 6094.75 | 9.00 |  |
| DCB2 Q=002 | rect 320 row-major source | BLT | 20480 | 5454.69 | 8.00 |  |
| DCB3 Q=003 | rect 320 row-major source | BLT | 81920 | 5148.74 | 7.52 |  |
| DCB3 Q=002 | rect 320 row-major source | BLT | 81920 | 4508.87 | 6.52 |  |
| DKC0 | rect 320 col-major source | CPU | 256 | 12551.05 | 47.71 |  |
| DKC1 | rect 320 col-major source | CPU | 4096 | 28647.53 | 27.65 |  |
| DKC2 | rect 320 col-major source | CPU | 20480 | 25257.26 | 24.34 |  |
| DKC3 | rect 320 col-major source | CPU | 81920 | 23565.27 | 22.68 |  |
| DKZ0 Q=002 | rect 320 col-major source | DMA | 256 | 19430.34 | 74.58 |  |
| DKZ1 Q=002 | rect 320 col-major source | DMA | 4096 | 23239.45 | 22.37 |  |
| DKZ2 Q=002 | rect 320 col-major source | DMA | 20480 | 14361.52 | 13.70 |  |
| DKZ3 Q=002 | rect 320 col-major source | DMA | 81920 | 9925.05 | 9.36 |  |
| DKB0 Q=003 | rect 320 col-major source | BLT | 256 | 2011.15 | 6.54 |  |
| DKB0 Q=002 | rect 320 col-major source | BLT | 256 | 1755.07 | 5.54 |  |
| DKB1 Q=003 | rect 320 col-major source | BLT | 4096 | 25051.70 | 6.03 |  |
| DKB1 Q=002 | rect 320 col-major source | BLT | 4096 | 20954.42 | 5.03 |  |
| DKB2 Q=003 | rect 320 col-major source | BLT | 20480 | 123351.86 | 6.01 |  |
| DKB2 Q=002 | rect 320 col-major source | BLT | 20480 | 102876.08 | 5.01 |  |
| DKB3 Q=003 | rect 320 col-major source | BLT | 81920 | 246363.24 | 6.01 |  |
| DKB3 Q=002 | rect 320 col-major source | BLT | 81920 | 205402.21 | 5.01 |  |
| DFC0 | fill | CPU | 64 | 1665.01 | 20.75 |  |
| DFC1 | fill | CPU | 256 | 4602.01 | 16.66 |  |
| DFC2 | fill | CPU | 1024 | 16064.92 | 15.36 |  |
| DFC3 | fill | CPU | 4096 | 31346.65 | 15.14 |  |
| DFC4 | fill | CPU | 16384 | 31343.50 | 15.14 |  |
| DFZ0 Q=002 | fill | DMA | 64 | 1256.03 | 14.36 |  |
| DFZ1 Q=002 | fill | DMA | 256 | 2749.04 | 9.42 |  |
| DFZ2 Q=002 | fill | DMA | 1024 | 8188.07 | 7.67 |  |
| DFZ3 Q=002 | fill | DMA | 4096 | 30476.11 | 7.36 |  |
| DFZ4 Q=002 | fill | DMA | 16384 | 119099.49 | 7.25 |  |
| DFB0 Q=003 | fill | BLT | 64 | 715.05 | 5.91 |  |
| DFB0 Q=002 | fill | BLT | 64 | 651.06 | 4.91 |  |
| DFB1 Q=003 | fill | BLT | 256 | 1291.00 | 3.73 |  |
| DFB1 Q=002 | fill | BLT | 256 | 1035.14 | 2.73 |  |
| DFB2 Q=003 | fill | BLT | 1024 | 3595.17 | 3.18 |  |
| DFB2 Q=002 | fill | BLT | 1024 | 2571.05 | 2.18 |  |
| DFB3 Q=003 | fill | BLT | 4096 | 12811.09 | 3.05 |  |
| DFB3 Q=002 | fill | BLT | 4096 | 8714.86 | 2.05 |  |
| DFB4 Q=003 | fill | BLT | 16384 | 49674.68 | 3.01 |  |
| DFB4 Q=002 | fill | BLT | 16384 | 33291.76 | 2.01 |  |
| DFB0 Q=102 | fill | BLT | 64 | 652.19 | 4.92 |  |
| DFB0 Q=112 | fill | BLT | 64 | 655.79 | 4.98 |  |
| DFB0 Q=202 | fill | BLT | 64 | 712.40 | 5.86 |  |
| DFB0 Q=212 | fill | BLT | 64 | 846.33 | 7.96 |  |
| DFB1 Q=102 | fill | BLT | 256 | 1037.06 | 2.73 |  |
| DFB1 Q=112 | fill | BLT | 256 | 1042.33 | 2.75 |  |
| DFB1 Q=202 | fill | BLT | 256 | 1133.47 | 3.11 |  |
| DFB1 Q=212 | fill | BLT | 256 | 1347.19 | 3.95 |  |
| DFB2 Q=102 | fill | BLT | 1024 | 2575.56 | 2.19 |  |
| DFB2 Q=112 | fill | BLT | 1024 | 2589.09 | 2.20 |  |
| DFB2 Q=202 | fill | BLT | 1024 | 2818.22 | 2.42 |  |
| DFB2 Q=212 | fill | BLT | 1024 | 3349.67 | 2.94 |  |
| DFB3 Q=102 | fill | BLT | 4096 | 8730.61 | 2.05 |  |
| DFB3 Q=112 | fill | BLT | 4096 | 8776.55 | 2.06 |  |
| DFB3 Q=202 | fill | BLT | 4096 | 9557.08 | 2.25 |  |
| DFB3 Q=212 | fill | BLT | 4096 | 11359.64 | 2.69 |  |
| DFB4 Q=102 | fill | BLT | 16384 | 33350.28 | 2.01 |  |
| DFB4 Q=112 | fill | BLT | 16384 | 33525.82 | 2.03 |  |
| DFB4 Q=202 | fill | BLT | 16384 | 36511.77 | 2.21 |  |
| DFB4 Q=212 | fill | BLT | 16384 | 43401.50 | 2.63 |  |
| DFZ0 Q=102 | fill | DMA | 64 | 1258.26 | 14.39 |  |
| DFZ0 Q=112 | fill | DMA | 64 | 1264.90 | 14.50 |  |
| DFZ0 Q=202 | fill | DMA | 64 | 1374.53 | 16.21 |  |
| DFZ0 Q=212 | fill | DMA | 64 | 1633.39 | 20.26 |  |
| DFZ1 Q=102 | fill | DMA | 256 | 2753.81 | 9.44 |  |
| DFZ1 Q=112 | fill | DMA | 256 | 2768.23 | 9.50 |  |
| DFZ1 Q=202 | fill | DMA | 256 | 3010.11 | 10.44 |  |
| DFZ1 Q=212 | fill | DMA | 256 | 3577.28 | 12.66 |  |
| DFZ2 Q=102 | fill | DMA | 1024 | 8202.43 | 7.68 |  |
| DFZ2 Q=112 | fill | DMA | 1024 | 8245.53 | 7.72 |  |
| DFZ2 Q=202 | fill | DMA | 1024 | 8974.19 | 8.43 |  |
| DFZ2 Q=212 | fill | DMA | 1024 | 10661.01 | 10.08 |  |
| DFZ3 Q=102 | fill | DMA | 4096 | 30530.22 | 7.37 |  |
| DFZ3 Q=112 | fill | DMA | 4096 | 30691.24 | 7.41 |  |
| DFZ3 Q=202 | fill | DMA | 4096 | 33392.93 | 8.07 |  |
| DFZ3 Q=212 | fill | DMA | 4096 | 39688.50 | 9.61 |  |
| DFZ4 Q=102 | fill | DMA | 16384 | 119310.15 | 7.26 |  |
| DFZ4 Q=112 | fill | DMA | 16384 | 119942.13 | 7.30 |  |
| DFZ4 Q=202 | fill | DMA | 16384 | 130500.78 | 7.94 |  |
| DFZ4 Q=212 | fill | DMA | 16384 | 155127.35 | 9.45 |  |
| DFB0 Q=103 | fill | BLT | 64 | 716.26 | 5.93 |  |
| DFB0 Q=113 | fill | BLT | 64 | 720.11 | 5.99 |  |
| DFB0 Q=203 | fill | BLT | 64 | 782.52 | 6.96 |  |
| DFB0 Q=213 | fill | BLT | 64 | 929.74 | 9.26 |  |
| DFB1 Q=103 | fill | BLT | 256 | 1293.32 | 3.74 |  |
| DFB1 Q=113 | fill | BLT | 256 | 1300.03 | 3.76 |  |
| DFB1 Q=203 | fill | BLT | 256 | 1414.37 | 4.21 |  |
| DFB1 Q=213 | fill | BLT | 256 | 1680.81 | 5.25 |  |
| DFB2 Q=103 | fill | BLT | 1024 | 3601.48 | 3.19 |  |
| DFB2 Q=113 | fill | BLT | 1024 | 3620.41 | 3.21 |  |
| DFB2 Q=203 | fill | BLT | 1024 | 3941.36 | 3.52 |  |
| DFB2 Q=213 | fill | BLT | 1024 | 4684.59 | 4.25 |  |
| DFB3 Q=103 | fill | BLT | 4096 | 12833.60 | 3.05 |  |
| DFB3 Q=113 | fill | BLT | 4096 | 12901.13 | 3.07 |  |
| DFB3 Q=203 | fill | BLT | 4096 | 14049.17 | 3.35 |  |
| DFB3 Q=213 | fill | BLT | 4096 | 16699.63 | 3.99 |  |
| DFB4 Q=103 | fill | BLT | 16384 | 49762.01 | 3.02 |  |
| DFB4 Q=113 | fill | BLT | 16384 | 50024.01 | 3.03 |  |
| DFB4 Q=203 | fill | BLT | 16384 | 54482.95 | 3.30 |  |
| DFB4 Q=213 | fill | BLT | 16384 | 64763.23 | 3.93 |  |
| DSC0 | tilemap scroll | CPU | 1120 | 26706.37 | 23.54 |  |
| DSC1 | tilemap scroll | CPU | 3680 | 30461.72 | 23.53 |  |
| DSZ0 Q=002 | tilemap scroll | DMA | 1120 | 13589.08 | 11.83 |  |
| DSZ1 Q=002 | tilemap scroll | DMA | 3680 | 43699.83 | 11.78 |  |
| DSB0 Q=003 | tilemap scroll | BLT | 1120 | 7210.94 | 6.14 |  |
| DSB0 Q=002 | tilemap scroll | BLT | 1120 | 6091.06 | 5.14 |  |
| DSB1 Q=003 | tilemap scroll | BLT | 3680 | 22570.44 | 6.04 |  |
| DSB1 Q=002 | tilemap scroll | BLT | 3680 | 18890.77 | 5.04 |  |
| DVC0 | video COPY | CPU | 1 | 489.02 | 151.97 |  |
| DVC1 | video COPY | CPU | 4 | 537.06 | 50.00 |  |
| DVC2 | video COPY | CPU | 8 | 601.03 | 33.00 |  |
| DVC3 | video COPY | CPU | 16 | 729.07 | 24.50 |  |
| DVC4 | video COPY | CPU | 53 | 1351.05 | 19.13 |  |
| DVC5 | video COPY | CPU | 71 | 1649.03 | 18.48 |  |
| DVC6 | video COPY | CPU | 128 | 2590.99 | 17.61 |  |
| DVC7 | video COPY | CPU | 240 | 4452.95 | 17.15 |  |
| DVZ0 Q=002 | video COPY | DMA | 1 | 739.06 | 402.01 |  |
| DVZ1 Q=002 | video COPY | DMA | 4 | 754.02 | 104.24 |  |
| DVZ2 Q=002 | video COPY | DMA | 8 | 774.04 | 54.62 |  |
| DVZ3 Q=002 | video COPY | DMA | 16 | 814.08 | 29.81 |  |
| DVZ4 Q=002 | video COPY | DMA | 53 | 999.06 | 12.49 |  |
| DVZ5 Q=002 | video COPY | DMA | 71 | 1089.06 | 10.59 |  |
| DVZ6 Q=002 | video COPY | DMA | 128 | 1374.03 | 8.10 |  |
| DVZ7 Q=002 | video COPY | DMA | 240 | 1933.99 | 6.65 |  |
| DVB0 Q=003 | video COPY | BLT | 1 | 528.98 | 191.93 |  |
| DVB0 Q=002 | video COPY | BLT | 1 | 528.04 | 190.99 |  |
| DVB1 Q=003 | video COPY | BLT | 4 | 547.02 | 52.49 |  |
| DVB1 Q=002 | video COPY | BLT | 4 | 543.04 | 51.50 |  |
| DVB2 Q=003 | video COPY | BLT | 8 | 571.04 | 29.25 |  |
| DVB2 Q=002 | video COPY | BLT | 8 | 563.05 | 28.25 |  |
| DVB3 Q=003 | video COPY | BLT | 16 | 619.04 | 17.62 |  |
| DVB3 Q=002 | video COPY | BLT | 16 | 603.07 | 16.63 |  |
| DVB4 Q=003 | video COPY | BLT | 53 | 841.00 | 9.51 |  |
| DVB4 Q=002 | video COPY | BLT | 53 | 788.08 | 8.51 |  |
| DVB5 Q=003 | video COPY | BLT | 71 | 949.00 | 8.62 |  |
| DVB5 Q=002 | video COPY | BLT | 71 | 878.14 | 7.62 |  |
| DVB6 Q=003 | video COPY | BLT | 128 | 1291.06 | 7.45 |  |
| DVB6 Q=002 | video COPY | BLT | 128 | 1163.04 | 6.45 |  |
| DVB7 Q=003 | video COPY | BLT | 240 | 1963.02 | 6.77 |  |
| DVB7 Q=002 | video COPY | BLT | 240 | 1723.01 | 5.77 |  |
| DVB0 Q=102 | video COPY | BLT | 1 | 528.96 | 191.90 |  |
| DVB0 Q=112 | video COPY | BLT | 1 | 531.74 | 194.69 |  |
| DVB0 Q=202 | video COPY | BLT | 1 | 577.41 | 240.36 |  |
| DVB0 Q=212 | video COPY | BLT | 1 | 685.99 | 348.94 |  |
| DVB1 Q=102 | video COPY | BLT | 4 | 543.99 | 51.73 |  |
| DVB1 Q=112 | video COPY | BLT | 4 | 546.88 | 52.46 |  |
| DVB1 Q=202 | video COPY | BLT | 4 | 593.97 | 64.23 |  |
| DVB1 Q=212 | video COPY | BLT | 4 | 705.58 | 92.13 |  |
| DVB2 Q=102 | video COPY | BLT | 8 | 564.00 | 28.37 |  |
| DVB2 Q=112 | video COPY | BLT | 8 | 567.03 | 28.75 |  |
| DVB2 Q=202 | video COPY | BLT | 8 | 615.77 | 34.84 |  |
| DVB2 Q=212 | video COPY | BLT | 8 | 731.66 | 49.33 |  |
| DVB3 Q=102 | video COPY | BLT | 16 | 604.12 | 16.69 |  |
| DVB3 Q=112 | video COPY | BLT | 16 | 607.30 | 16.89 |  |
| DVB3 Q=202 | video COPY | BLT | 16 | 659.61 | 20.16 |  |
| DVB3 Q=212 | video COPY | BLT | 16 | 783.70 | 27.92 |  |
| DVB4 Q=102 | video COPY | BLT | 53 | 789.47 | 8.54 |  |
| DVB4 Q=112 | video COPY | BLT | 53 | 793.61 | 8.61 |  |
| DVB4 Q=202 | video COPY | BLT | 53 | 862.61 | 9.92 |  |
| DVB4 Q=212 | video COPY | BLT | 53 | 1024.86 | 12.98 |  |
| DVB5 Q=102 | video COPY | BLT | 71 | 879.58 | 7.64 |  |
| DVB5 Q=112 | video COPY | BLT | 71 | 884.21 | 7.71 |  |
| DVB5 Q=202 | video COPY | BLT | 71 | 961.24 | 8.79 |  |
| DVB5 Q=212 | video COPY | BLT | 71 | 1142.25 | 11.34 |  |
| DVB6 Q=102 | video COPY | BLT | 128 | 1165.11 | 6.47 |  |
| DVB6 Q=112 | video COPY | BLT | 128 | 1171.16 | 6.52 |  |
| DVB6 Q=202 | video COPY | BLT | 128 | 1273.88 | 7.32 |  |
| DVB6 Q=212 | video COPY | BLT | 128 | 1513.92 | 9.19 |  |
| DVB7 Q=102 | video COPY | BLT | 240 | 1726.13 | 5.79 |  |
| DVB7 Q=112 | video COPY | BLT | 240 | 1735.25 | 5.83 |  |
| DVB7 Q=202 | video COPY | BLT | 240 | 1888.04 | 6.46 |  |
| DVB7 Q=212 | video COPY | BLT | 240 | 2244.14 | 7.95 |  |
| DVZ0 Q=102 | video COPY | DMA | 1 | 740.31 | 403.26 |  |
| DVZ0 Q=112 | video COPY | DMA | 1 | 744.32 | 407.27 |  |
| DVZ0 Q=202 | video COPY | DMA | 1 | 808.05 | 471.00 |  |
| DVZ0 Q=212 | video COPY | DMA | 1 | 960.09 | 623.03 |  |
| DVZ1 Q=102 | video COPY | DMA | 4 | 755.32 | 104.57 |  |
| DVZ1 Q=112 | video COPY | DMA | 4 | 759.36 | 105.58 |  |
| DVZ1 Q=202 | video COPY | DMA | 4 | 824.55 | 121.87 |  |
| DVZ1 Q=212 | video COPY | DMA | 4 | 979.60 | 160.64 |  |
| DVZ2 Q=102 | video COPY | DMA | 8 | 775.42 | 54.80 |  |
| DVZ2 Q=112 | video COPY | DMA | 8 | 779.51 | 55.31 |  |
| DVZ2 Q=202 | video COPY | DMA | 8 | 846.48 | 63.68 |  |
| DVZ2 Q=212 | video COPY | DMA | 8 | 1005.70 | 83.58 |  |
| DVZ3 Q=102 | video COPY | DMA | 16 | 815.43 | 29.90 |  |
| DVZ3 Q=112 | video COPY | DMA | 16 | 819.77 | 30.17 |  |
| DVZ3 Q=202 | video COPY | DMA | 16 | 890.47 | 34.59 |  |
| DVZ3 Q=212 | video COPY | DMA | 16 | 1057.79 | 45.05 |  |
| DVZ4 Q=102 | video COPY | DMA | 53 | 1000.81 | 12.52 |  |
| DVZ4 Q=112 | video COPY | DMA | 53 | 1006.10 | 12.62 |  |
| DVZ4 Q=202 | video COPY | DMA | 53 | 1093.23 | 14.27 |  |
| DVZ4 Q=212 | video COPY | DMA | 53 | 1299.04 | 18.15 |  |
| DVZ5 Q=102 | video COPY | DMA | 71 | 1090.94 | 10.62 |  |
| DVZ5 Q=112 | video COPY | DMA | 71 | 1096.79 | 10.70 |  |
| DVZ5 Q=202 | video COPY | DMA | 71 | 1192.12 | 12.04 |  |
| DVZ5 Q=212 | video COPY | DMA | 71 | 1416.39 | 15.20 |  |
| DVZ6 Q=102 | video COPY | DMA | 128 | 1376.46 | 8.12 |  |
| DVZ6 Q=112 | video COPY | DMA | 128 | 1383.68 | 8.18 |  |
| DVZ6 Q=202 | video COPY | DMA | 128 | 1504.60 | 9.12 |  |
| DVZ6 Q=212 | video COPY | DMA | 128 | 1788.49 | 11.34 |  |
| DVZ7 Q=102 | video COPY | DMA | 240 | 1937.47 | 6.67 |  |
| DVZ7 Q=112 | video COPY | DMA | 240 | 1947.65 | 6.71 |  |
| DVZ7 Q=202 | video COPY | DMA | 240 | 2118.78 | 7.42 |  |
| DVZ7 Q=212 | video COPY | DMA | 240 | 2518.13 | 9.09 |  |
| DVB0 Q=103 | video COPY | BLT | 1 | 529.99 | 192.93 |  |
| DVB0 Q=113 | video COPY | BLT | 1 | 532.77 | 195.72 |  |
| DVB0 Q=203 | video COPY | BLT | 1 | 578.50 | 241.45 |  |
| DVB0 Q=213 | video COPY | BLT | 1 | 687.32 | 350.27 |  |
| DVB1 Q=103 | video COPY | BLT | 4 | 548.02 | 52.74 |  |
| DVB1 Q=113 | video COPY | BLT | 4 | 550.89 | 53.46 |  |
| DVB1 Q=203 | video COPY | BLT | 4 | 598.34 | 65.32 |  |
| DVB1 Q=213 | video COPY | BLT | 4 | 710.79 | 93.43 |  |
| DVB2 Q=103 | video COPY | BLT | 8 | 572.03 | 29.37 |  |
| DVB2 Q=113 | video COPY | BLT | 8 | 575.07 | 29.75 |  |
| DVB2 Q=203 | video COPY | BLT | 8 | 624.55 | 35.94 |  |
| DVB2 Q=213 | video COPY | BLT | 8 | 742.07 | 50.63 |  |
| DVB3 Q=103 | video COPY | BLT | 16 | 620.11 | 17.69 |  |
| DVB3 Q=113 | video COPY | BLT | 16 | 623.38 | 17.90 |  |
| DVB3 Q=203 | video COPY | BLT | 16 | 677.15 | 21.26 |  |
| DVB3 Q=213 | video COPY | BLT | 16 | 804.41 | 29.21 |  |
| DVB4 Q=103 | video COPY | BLT | 53 | 842.51 | 9.54 |  |
| DVB4 Q=113 | video COPY | BLT | 53 | 846.91 | 9.62 |  |
| DVB4 Q=203 | video COPY | BLT | 53 | 920.70 | 11.01 |  |
| DVB4 Q=213 | video COPY | BLT | 53 | 1094.01 | 14.28 |  |
| DVB5 Q=103 | video COPY | BLT | 71 | 950.71 | 8.64 |  |
| DVB5 Q=113 | video COPY | BLT | 71 | 955.68 | 8.71 |  |
| DVB5 Q=203 | video COPY | BLT | 71 | 1039.16 | 9.89 |  |
| DVB5 Q=213 | video COPY | BLT | 71 | 1234.78 | 12.64 |  |
| DVB6 Q=103 | video COPY | BLT | 128 | 1293.32 | 7.47 |  |
| DVB6 Q=113 | video COPY | BLT | 128 | 1300.03 | 7.52 |  |
| DVB6 Q=203 | video COPY | BLT | 128 | 1414.31 | 8.42 |  |
| DVB6 Q=213 | video COPY | BLT | 128 | 1680.68 | 10.50 |  |
| DVB7 Q=103 | video COPY | BLT | 240 | 1966.56 | 6.79 |  |
| DVB7 Q=113 | video COPY | BLT | 240 | 1976.79 | 6.83 |  |
| DVB7 Q=203 | video COPY | BLT | 240 | 2151.40 | 7.56 |  |
| DVB7 Q=213 | video COPY | BLT | 240 | 2556.86 | 9.25 |  |
| DUZ0 Q=002 | setup | DMA | 1 | 721.99 | 384.94 |  |
| DUZ1 Q=002 | setup | DMA | 1 | 544.10 | 207.05 |  |
| DUB0 Q=003 | setup | BLT | 1 | 721.06 | 384.01 |  |
| DUB0 Q=002 | setup | BLT | 1 | 720.05 | 383.00 |  |
| DUB1 Q=003 | setup | BLT | 1 | 497.09 | 160.04 |  |
| DUB1 Q=002 | setup | BLT | 1 | 496.06 | 159.01 |  |

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
BREAK-EVEN part 1b rect 256x192 mode DMA Q=002: 2583
BREAK-EVEN part 1b rect 256x192 mode DMA Q=102: 2599
BREAK-EVEN part 1b rect 256x192 mode DMA Q=112: 2645
BREAK-EVEN part 1b rect 256x192 mode DMA Q=202: 3314
BREAK-EVEN part 1b rect 256x192 mode DMA Q=212: 5672
BREAK-EVEN part 1b rect 320 col-major source BLT Q=002: below 256
BREAK-EVEN part 1b rect 320 col-major source BLT Q=003: below 256
BREAK-EVEN part 1b rect 320 col-major source DMA Q=002: 3466
BREAK-EVEN part 1b rect 320 row-major source BLT Q=002: below 256
BREAK-EVEN part 1b rect 320 row-major source BLT Q=003: below 256
BREAK-EVEN part 1b tilemap scroll BLT Q=002: below 1120
BREAK-EVEN part 1b tilemap scroll BLT Q=003: below 1120
BREAK-EVEN part 1b tilemap scroll DMA Q=002: below 1120
BREAK-EVEN part 1b transparent rect BLT Q=002: below 256
BREAK-EVEN part 1b transparent rect BLT Q=003: below 256
BREAK-EVEN part 1b video COPY BLT Q=002: 5
BREAK-EVEN part 1b video COPY BLT Q=003: 6
BREAK-EVEN part 1b video COPY BLT Q=102: 6
BREAK-EVEN part 1b video COPY BLT Q=103: 6
BREAK-EVEN part 1b video COPY BLT Q=112: 6
BREAK-EVEN part 1b video COPY BLT Q=113: 7
BREAK-EVEN part 1b video COPY BLT Q=202: 11
BREAK-EVEN part 1b video COPY BLT Q=203: 12
BREAK-EVEN part 1b video COPY BLT Q=212: 30
BREAK-EVEN part 1b video COPY BLT Q=213: 35
BREAK-EVEN part 1b video COPY DMA Q=002: 33
BREAK-EVEN part 1b video COPY DMA Q=102: 33
BREAK-EVEN part 1b video COPY DMA Q=112: 34
BREAK-EVEN part 1b video COPY DMA Q=202: 41
BREAK-EVEN part 1b video COPY DMA Q=212: 52
WAIT STATES: ABSENT


KS1/KS3 P1NP ks1=4.00 ks3=4.00
KS1/KS3 P1RD ks1=7.00 ks3=7.00
KS1/KS3 P1WR ks1=7.00 ks3=7.00
KS1/KS3 P1LI ks1=16.02 ks3=16.02
KS1/KS3 P1LR ks1=21.02 ks3=21.02
KS1/KS3 P1OT ks1=21.00 ks3=21.00
KS1/KS3 P1IN ks1=12.01 ks3=12.01
KS1/KS3 P1PP ks1=21.00 ks3=21.00
KS1/KS3 P1JR ks1=12.00 ks3=12.00
KS1/KS3 P1X5 ks1=4.00 ks3=4.00
KS1/KS3 P1R5 ks1=7.00 ks3=7.00
KS1/KS3 P1R7 ks1=7.00 ks3=7.00
KS1/KS3 P1C1 ks1=4.00 ks3=4.00
KS1/KS3 P1C2 ks1=21.02 ks3=21.02
KS1/KS3 D0DT ks1=635.00 ks3=635.97
KS1/KS3 D0CP ks1=5.79 ks3=5.79
KS1/KS3 DRC0 ks1=47.71 ks3=47.71
KS1/KS3 DRC1 ks1=34.29 ks3=34.29
KS1/KS3 DRC2 ks1=27.65 ks3=27.65
KS1/KS3 DRC3 ks1=24.34 ks3=24.34
KS1/KS3 DRC4 ks1=22.68 ks3=22.68
KS1/KS3 DRZ0 ks1=74.53 ks3=74.59
KS1/KS3 DRZ1 ks1=39.69 ks3=39.72
KS1/KS3 DRZ2 ks1=22.35 ks3=22.37
KS1/KS3 DRZ3 ks1=13.69 ks3=13.70
KS1/KS3 DRZ4 ks1=9.36 ks3=9.36
KS1/KS3 DRB0 ks1=6.54 ks3=6.54
KS1/KS3 DRB1 ks1=6.13 ks3=6.13
KS1/KS3 DRB2 ks1=6.03 ks3=6.03
KS1/KS3 DRB3 ks1=6.01 ks3=6.01
KS1/KS3 DRB4 ks1=6.00 ks3=6.00
KS1/KS3 DTC0 ks1=48.15 ks3=48.15
KS1/KS3 DTC1 ks1=34.51 ks3=34.50
KS1/KS3 DTC2 ks1=27.75 ks3=27.75
KS1/KS3 DTC3 ks1=24.39 ks3=24.39
KS1/KS3 DTC4 ks1=22.71 ks3=22.71
KS1/KS3 DTB0 ks1=6.53 ks3=6.54
KS1/KS3 DTB1 ks1=6.13 ks3=6.13
KS1/KS3 DTB2 ks1=6.03 ks3=6.03
KS1/KS3 DTB3 ks1=6.01 ks3=6.01
KS1/KS3 DTB4 ks1=6.00 ks3=6.00
KS1/KS3 DCC0 ks1=102.16 ks3=102.16
KS1/KS3 DCC1 ks1=45.75 ks3=45.75
KS1/KS3 DCC2 ks1=44.39 ks3=44.39
KS1/KS3 DCC3 ks1=40.44 ks3=40.44
KS1/KS3 DCB0 ks1=35.82 ks3=35.89
KS1/KS3 DCB1 ks1=13.43 ks3=13.45
KS1/KS3 DCB2 ks1=8.99 ks3=9.00
KS1/KS3 DCB3 ks1=7.52 ks3=7.52
KS1/KS3 DKC0 ks1=47.71 ks3=47.71
KS1/KS3 DKC1 ks1=27.65 ks3=27.65
KS1/KS3 DKC2 ks1=24.34 ks3=24.34
KS1/KS3 DKC3 ks1=22.68 ks3=22.68
KS1/KS3 DKZ0 ks1=74.52 ks3=74.58
KS1/KS3 DKZ1 ks1=22.35 ks3=22.37
KS1/KS3 DKZ2 ks1=13.69 ks3=13.70
KS1/KS3 DKZ3 ks1=9.36 ks3=9.36
KS1/KS3 DKB0 ks1=6.54 ks3=6.54
KS1/KS3 DKB1 ks1=6.03 ks3=6.03
KS1/KS3 DKB2 ks1=6.01 ks3=6.01
KS1/KS3 DKB3 ks1=6.01 ks3=6.01
KS1/KS3 DFC0 ks1=20.75 ks3=20.75
KS1/KS3 DFC1 ks1=16.66 ks3=16.66
KS1/KS3 DFC2 ks1=15.36 ks3=15.36
KS1/KS3 DFC3 ks1=15.14 ks3=15.14
KS1/KS3 DFC4 ks1=15.14 ks3=15.14
KS1/KS3 DFZ0 ks1=14.34 ks3=14.36
KS1/KS3 DFZ1 ks1=9.41 ks3=9.42
KS1/KS3 DFZ2 ks1=7.66 ks3=7.67
KS1/KS3 DFZ3 ks1=7.35 ks3=7.36
KS1/KS3 DFZ4 ks1=7.24 ks3=7.25
KS1/KS3 DFB0 ks1=5.89 ks3=5.91
KS1/KS3 DFB1 ks1=3.72 ks3=3.73
KS1/KS3 DFB2 ks1=3.18 ks3=3.18
KS1/KS3 DFB3 ks1=3.05 ks3=3.05
KS1/KS3 DFB4 ks1=3.01 ks3=3.01
KS1/KS3 DSC0 ks1=23.55 ks3=23.54
KS1/KS3 DSC1 ks1=23.53 ks3=23.53
KS1/KS3 DSZ0 ks1=11.83 ks3=11.83
KS1/KS3 DSZ1 ks1=11.78 ks3=11.78
KS1/KS3 DSB0 ks1=6.14 ks3=6.14
KS1/KS3 DSB1 ks1=6.04 ks3=6.04
KS1/KS3 DVC0 ks1=151.97 ks3=151.97
KS1/KS3 DVC1 ks1=50.01 ks3=50.00
KS1/KS3 DVC2 ks1=33.00 ks3=33.00
KS1/KS3 DVC3 ks1=24.50 ks3=24.50
KS1/KS3 DVC4 ks1=19.13 ks3=19.13
KS1/KS3 DVC5 ks1=18.48 ks3=18.48
KS1/KS3 DVC6 ks1=17.61 ks3=17.61
KS1/KS3 DVC7 ks1=17.15 ks3=17.15
KS1/KS3 DVZ0 ks1=400.98 ks3=402.01
KS1/KS3 DVZ1 ks1=104.00 ks3=104.24
KS1/KS3 DVZ2 ks1=54.50 ks3=54.62
KS1/KS3 DVZ3 ks1=29.75 ks3=29.81
KS1/KS3 DVZ4 ks1=12.47 ks3=12.49
KS1/KS3 DVZ5 ks1=10.58 ks3=10.59
KS1/KS3 DVZ6 ks1=8.09 ks3=8.10
KS1/KS3 DVZ7 ks1=6.65 ks3=6.65
KS1/KS3 DVB0 ks1=190.96 ks3=191.93
KS1/KS3 DVB1 ks1=52.25 ks3=52.49
KS1/KS3 DVB2 ks1=29.12 ks3=29.25
KS1/KS3 DVB3 ks1=17.56 ks3=17.62
KS1/KS3 DVB4 ks1=9.49 ks3=9.51
KS1/KS3 DVB5 ks1=8.61 ks3=8.62
KS1/KS3 DVB6 ks1=7.45 ks3=7.45
KS1/KS3 DVB7 ks1=6.77 ks3=6.77
KS1/KS3 DUZ0 ks1=384.01 ks3=384.94
KS1/KS3 DUZ1 ks1=205.99 ks3=207.05
KS1/KS3 DUB0 ks1=383.00 ks3=384.01
KS1/KS3 DUB1 ks1=158.98 ks3=160.04

## Gates

- quiet_check: OK: quiet timed paths are instruction-identical to release
- bench_check: OK: bench image is instruction-identical to release outside IFDEF BENCH
