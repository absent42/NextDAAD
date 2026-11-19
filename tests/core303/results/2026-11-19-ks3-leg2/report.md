# CORE303 report

## BENCH 5e4b8b5

NR: 01=33 0E=03 0F=03 03=33 05=5B 07=33  SRAM: 2048 KB

### Part 0

| tag | op | method | size | T/rep | T/unit | notes |
|---|---|---|---|---|---|---|
| B0CL | poll | CPU | - | 152.16 | - |  |
| B1CL | poll | CPU | - | 152.19 | - | 14MHz |
| BRHD | Huffman decode | CPU | - | 979.69 | 827.53 |  |
| BRHD | Huffman decode | CPU | - | 980.13 | 827.94 | 14MHz |
| BRPR | print | CPU | - | 7235.44 | 7083.28 |  |
| BRPR | print | CPU | - | 7240.78 | 7088.59 | 14MHz |
| BRSC | window scroll | CPU | - | 47277.94 | 47125.78 |  |
| BRSC | window scroll | CPU | - | 47304.66 | 47152.47 | 14MHz |
| BRPB | NX3 blit | CPU | - | 199.50 | 47.34 |  |
| BRPB | NX3 blit | CPU | - | 206.62 | 54.44 | 14MHz |
| BRPL | NX3 SD load | CPU | - | 4978.00 | 4825.84 |  |
| BRI0 | frame ISR idle | CPU | - | 52466.12 | 52313.96 |  |
| BRGT | game turn | CPU | - | 19581.88 | 19429.71 |  |
| BRGT | game turn | CPU | - | 19592.56 | 19440.37 | 14MHz |
| BRIM | frame ISR AKY | CPU | - | 52466.12 | 52313.96 |  |
| BRIS | frame ISR SFX | CPU | - | 52466.12 | 52313.96 |  |

### Part 2

ISR share: row F x B2I0 T/frame, taken out of the row and its companion (359.66 T/frame).

| tag | op | method | size | T/rep | T/unit | T/unit ex-ISR | notes |
|---|---|---|---|---|---|---|---|
| B2HD | Huffman decode | CPU | - | 121936.36 | 1061.02 | 1060.35 |  |
| B3HD | Huffman decode | CPU | - | 122010.28 | 1061.67 | 1060.32 | 14MHz |
| B2PR | print | CPU | - | 133549.22 | 1108.02 | 1107.31 |  |
| B3PR | print | CPU | - | 133631.16 | 1108.69 | 1107.28 | 14MHz |
| B2SC | window scroll | CPU | - | 99375.94 | 52098.00 | 52064.98 |  |
| B3SC | window scroll | CPU | - | 99434.72 | 52130.06 | 52064.03 | 14MHz |
| B2PB | NX3 blit | CPU | - | 589593.75 | 589394.25 | 589020.54 |  |
| B3PB | NX3 blit | CPU | - | 540552.38 | 540345.75 | 539660.14 | 14MHz |
| B2PL | NX3 SD load | CPU | - | 2210916.00 | 2205938.00 | 2204536.82 |  |
| B2I0 | frame ISR idle | CPU | - | 52499.38 | 359.66 | - | T/frame |
| B2GT | game turn | CPU | - | 155006.75 | 135424.88 | 135338.71 |  |
| B3GT | game turn | CPU | - | 155100.56 | 135508.00 | 135336.13 | 14MHz |
| B2IM | frame ISR AKY | CPU | - | 53238.00 | 8233.33 | - | T/frame |
| B2IS | frame ISR SFX | CPU | - | 62084.88 | 87942.86 | - | T/frame |

B2/B3 HD: 28MHz 1061.02 14MHz 1061.67 T/char, ex-ISR 1060.35 / 1060.32; E 2A40 EQUAL
B2/B3 PR: 28MHz 1108.02 14MHz 1108.69 T/char, ex-ISR 1107.31 / 1107.28; E 302C EQUAL
B2/B3 SC: 28MHz 52098.00 14MHz 52130.06 T/scroll, ex-ISR 52064.98 / 52064.03; E 8FD2 EQUAL
B2/B3 PB: 28MHz 589394.25 14MHz 540345.75 T/picture, ex-ISR 589020.54 / 539660.14; E 3B3E EQUAL
B2/B3 GT: 28MHz 135424.88 14MHz 135508.00 T/turn, ex-ISR 135338.71 / 135336.13; E 078A EQUAL



KS1/KS3 BRHD ks1=827.56 ks3=827.53
KS1/KS3 B2HD ks1=1061.02 ks3=1061.02
KS1/KS3 B3HD ks1=1061.67 ks3=1061.67
KS1/KS3 BRPR ks1=7083.31 ks3=7083.28
KS1/KS3 B2PR ks1=1108.02 ks3=1108.02
KS1/KS3 B3PR ks1=1108.69 ks3=1108.69
KS1/KS3 BRSC ks1=47122.24 ks3=47125.78
KS1/KS3 B2SC ks1=52098.00 ks3=52098.00
KS1/KS3 B3SC ks1=52128.28 ks3=52130.06
KS1/KS3 BRPB ks1=47.37 ks3=47.34
KS1/KS3 B2PB ks1=589209.00 ks3=589394.25
KS1/KS3 B3PB ks1=540345.75 ks3=540345.75
KS1/KS3 BRPL ks1=4863.87 ks3=4825.84
KS1/KS3 B2PL ks1=2190472.00 ks3=2205938.00
KS1/KS3 BRI0 ks1=52313.99 ks3=52313.96
KS1/KS3 B2I0 ks1=359.66 ks3=359.66
KS1/KS3 BRGT ks1=19434.49 ks3=19429.71
KS1/KS3 B2GT ks1=135417.75 ks3=135424.88
KS1/KS3 B3GT ks1=135508.00 ks3=135508.00
KS1/KS3 BRIM ks1=52313.99 ks3=52313.96
KS1/KS3 B2IM ks1=8233.33 ks3=8233.33
KS1/KS3 BRIS ks1=52313.99 ks3=52313.96
KS1/KS3 B2IS ks1=88029.71 ks3=87942.86

## Gates

- quiet_check: OK: quiet timed paths are instruction-identical to release
- bench_check: OK: bench image is instruction-identical to release outside IFDEF BENCH
