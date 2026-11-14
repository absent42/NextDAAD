# CORE303 report

## BENCH 5e4b8b5

NR: 01=33 0E=03 0F=00 03=33 05=5B 07=33  SRAM: 2048 KB

### Part 0

| tag | op | method | size | T/rep | T/unit | notes |
|---|---|---|---|---|---|---|
| B0CL | poll | CPU | - | 152.13 | - |  |
| B1CL | poll | CPU | - | 152.19 | - | 14MHz |
| BRHD | Huffman decode | CPU | - | 979.69 | 827.56 |  |
| BRHD | Huffman decode | CPU | - | 980.13 | 827.94 | 14MHz |
| BRPR | print | CPU | - | 7235.44 | 7083.31 |  |
| BRPR | print | CPU | - | 7240.78 | 7088.59 | 14MHz |
| BRSC | window scroll | CPU | - | 47274.38 | 47122.24 |  |
| BRSC | window scroll | CPU | - | 47306.44 | 47154.25 | 14MHz |
| BRPB | NX3 blit | CPU | - | 199.50 | 47.37 |  |
| BRPB | NX3 blit | CPU | - | 206.62 | 54.44 | 14MHz |
| BRPL | NX3 SD load | CPU | - | 5016.00 | 4863.87 |  |
| BRI0 | frame ISR idle | CPU | - | 52466.12 | 52313.99 |  |
| BRGT | game turn | CPU | - | 19586.62 | 19434.49 |  |
| BRGT | game turn | CPU | - | 19592.56 | 19440.37 | 14MHz |
| BRIM | frame ISR AKY | CPU | - | 52466.12 | 52313.99 |  |
| BRIS | frame ISR SFX | CPU | - | 52466.12 | 52313.99 |  |

### Part 2

ISR share: row F x B2I0 T/frame, taken out of the row and its companion (359.66 T/frame).

| tag | op | method | size | T/rep | T/unit | T/unit ex-ISR | notes |
|---|---|---|---|---|---|---|---|
| B2HD | Huffman decode | CPU | - | 121936.36 | 1061.02 | 1060.35 |  |
| B3HD | Huffman decode | CPU | - | 122010.28 | 1061.67 | 1060.32 | 14MHz |
| B2PR | print | CPU | - | 133549.22 | 1108.02 | 1107.31 |  |
| B3PR | print | CPU | - | 133631.16 | 1108.69 | 1107.28 | 14MHz |
| B2SC | window scroll | CPU | - | 99372.38 | 52098.00 | 52064.98 |  |
| B3SC | window scroll | CPU | - | 99434.72 | 52128.28 | 52062.25 | 14MHz |
| B2PB | NX3 blit | CPU | - | 589408.50 | 589209.00 | 588835.29 |  |
| B3PB | NX3 blit | CPU | - | 540552.38 | 540345.75 | 539660.14 | 14MHz |
| B2PL | NX3 SD load | CPU | - | 2195488.00 | 2190472.00 | 2189078.31 |  |
| B2I0 | frame ISR idle | CPU | - | 52499.38 | 359.66 | - | T/frame |
| B2GT | game turn | CPU | - | 155004.38 | 135417.75 | 135331.58 |  |
| B3GT | game turn | CPU | - | 155100.56 | 135508.00 | 135336.13 | 14MHz |
| B2IM | frame ISR AKY | CPU | - | 53238.00 | 8233.33 | - | T/frame |
| B2IS | frame ISR SFX | CPU | - | 62094.38 | 88029.71 | - | T/frame |

B2/B3 HD: 28MHz 1061.02 14MHz 1061.67 T/char, ex-ISR 1060.35 / 1060.32; E 2A40 EQUAL
B2/B3 PR: 28MHz 1108.02 14MHz 1108.69 T/char, ex-ISR 1107.31 / 1107.28; E 302C EQUAL
B2/B3 SC: 28MHz 52098.00 14MHz 52128.28 T/scroll, ex-ISR 52064.98 / 52062.25; E 8F87 EQUAL
B2/B3 PB: 28MHz 589209.00 14MHz 540345.75 T/picture, ex-ISR 588835.29 / 539660.14; E 3B3E EQUAL
B2/B3 GT: 28MHz 135417.75 14MHz 135508.00 T/turn, ex-ISR 135331.58 / 135336.13; E 078A EQUAL



## Gates

- quiet_check: OK: quiet timed paths are instruction-identical to release
- bench_check: OK: bench image is instruction-identical to release outside IFDEF BENCH
