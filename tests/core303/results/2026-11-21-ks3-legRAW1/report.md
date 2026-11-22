# Raw direct video bench - KS3 sitting 1, leg A (2026-11-21)

Sitting: KS3, core 3.03.03 (register line 51 3 3 3 0 0: NR $01 $33, NR $0E 3, NR $0F 3, +3 timing, 50 Hz, NR $11 0); -BenchQuiet build from 3918c62 (interpreter source 09ba34b). Details in sitting.txt. Log: NXBENCH.TXT in this folder, 16 captures.

Produced by `python tests\raw_fit.py NXBENCH.TXT --clips <leg folder>`. The fit reads only NXBENCH.TXT; the clip files are read to check their headers and frame tags. ingest.py does not take this leg (no GATES.TXT in the leg folder; an NXB-only leg takes its timing from a same-date leg1, and there is none), so this folder follows the legBLT shape by hand and the timing comes from the register line through parse.timing.

## Summary

- Acceptance: PASS. Largest |residual| 0.373 percent (clip 071, mono). Stereo residuals are within 0.06 percent, mono within 0.38 percent.
- Over 1.00, stereo: 320x192@25 (1.0351), 280x224@25 (1.0576). The stall term adds at most 0.0001.
- Over 1.00, mono: 320x192@25 (1.0125), 280x224@25 (1.0348).
- Within 10 percent of the limit (0.90 < util <= 1.00): none in stereo, none in mono.
- Below 0.90 in both forms: 256x192@25, 320x160@25, 320x240@16.67, 256x240@16.67.
- Excluded: capture 10 (PICK 59, no such clip). It printed VID FILE?, its rows are clip 068's previous screen, and it has no #HIST lines.
- Anomalies for a RE-RUN request: none. Every peer group is within 0.16 percent; no walk marks (O=01), no NXB SHORT or GEO, no missing rows; all 28 histograms sum to 2048.
- Legs B and C: not returned. The playback table at the end has the model's prediction per clip; its readout column is awaited.

## Observations

1. Mono residuals fall in two groups: 066-069 (625 sound bytes, 399 pad bytes a frame) +0.14 to +0.27 percent; 070-071 (937 sound bytes, 87 pad bytes) -0.28 and -0.37 percent; 074 0.000 (the only 3-sector mono clip, so it fixes the slope). The 2-sector mono least squares points differ by about 6,000 T between the two groups (30,352-31,189 T against 24,651-24,970 T). The equation has one term per sound sector.
2. Mono RAW_FRAME_T is negative (-552.06 T). Mono RAW_SND_SECTOR_T (14,684.47 T) is 1.69 x the stereo figure (8,684.76 T). For the 2-sector mono shapes, 2 x tsnd + tf = 28,816.88 T enters the gate.
3. tp per clip spans 26,829-29,773 T (stereo) and 26,112-28,533 T (mono). RFR0 is a single rep by design, read on the 1,824 T line clock.
4. Every token wait in RHST and AHST is in bin 1 (exactly one $FF poll), on all 14 clips. RAW_STALL_T = 51.59 T, 0.005 percent of a 25 fps period.
5. Pixels-only frames (the reference column): mono 320x192@25 is 0.9882 without the palette sector. The other three over-limit cases stay over 1.00.
6. Reference table: against the period the frame loop paces on (samples x 1792 T: 1,120,000 T at 25 fps, 1.28 percent shorter than the plan's 1,134,528 T), every utilisation rises by about 1.3 percent. No shape changes class in this sitting.

The rest of this file is the script's output, unedited.

raw_fit: NXBENCH.TXT
timing: +3, 311 lines x 1824 T a field (parse.timing); T = (F x 311 + D) x 1824
CTC 0 period: 16 x 112 = 1792 T (AUD_CTC_CW16 prescaler, vidCtcTcNxvStereo[NR $11 = 0])
harness: card h = 88 T a rep, frame g = 210 T a frame (nxv2_bench_rows)

## Sections

 1 #NXB 066A NXBW clip 060 stereo 256x192@25: 13 rows, 2 histograms
 2 #NXB 254C NXBW clip 061 stereo 320x160@25: 13 rows, 2 histograms
 3 #NXB 2AB0 NXBW clip 062 stereo 320x192@25: 13 rows, 2 histograms
 4 #NXB 2DF6 NXBW clip 063 stereo 280x224@25: 13 rows, 2 histograms
 5 #NXB 3134 NXBW clip 064 stereo 320x240@16.67: 13 rows, 2 histograms
 6 #NXB 345E NXBW clip 065 stereo 256x240@16.67: 13 rows, 2 histograms
 7 #NXB 375D NXBW clip 066 mono 256x192@25: 13 rows, 2 histograms
 8 #NXB 3A4D NXBW clip 067 mono 320x160@25: 13 rows, 2 histograms
 9 #NXB 4024 NXBW clip 068 mono 320x192@25: 13 rows, 2 histograms
10 #NXB 41C5 NXBW clip 59: EXCLUDED - VID FILE? (an open failure: the rows on screen are the previous session's)
11 #NXB 459C NXBW clip 069 mono 280x224@25: 13 rows, 2 histograms
12 #NXB 4838 NXBW clip 070 mono 320x240@16.67: 13 rows, 2 histograms
13 #NXB 4ACF NXBW clip 071 mono 256x240@16.67: 13 rows, 2 histograms
14 #NXB 4D81 NXBW clip 072 stereo 320x256@12.5: 13 rows, 2 histograms
15 #NXB 4FF9 NXBW clip 074 mono 256x192@15.2588: 13 rows, 2 histograms
16 #NXB 522F NXBD clip 10: old direct rows (9)

## Decoded rows

T/rep = (F x 311 + D) x 1824 / R. Primed (harness removed): RSEC' = RSEC - h, RCOL' = RCOL - h, ARSE' = ARSE - h x ARSE/RSEC, ARCO' = ARCO - h x ARCO/RCOL, RSWP' = RSWP/16 - g, ARSW' = ARSW/16 - g x ARSW/RSWP, RFR0' = RFR0 - g.

clip 060 stereo 256x192@25: Spix 96, Ssnd 3, C 0 (section 1)

| tag | O | R | F | D | lines | T | T/rep | primed |
|---|---|---|---|---|---|---|---|---|
| IDEN | 02 | 250 | 256 | 192 | | | | |
| RFR0 | 00 | 1 | 1 | 169 | 480 | 875520 | 875520.00 | 875310.00 |
| RSWP | 00 | 16 | 24 | -7 | 7457 | 13601568 | 850098.00 | 849888.00 |
| ARSW | 00 | 16 | 25 | 239 | 8014 | 14617536 | 913596.00 | 913370.31 |
| RSEC | 00 | 128 | 2 | -21 | 601 | 1096224 | 8564.25 | 8476.25 |
| RCOL | 00 | 128 | 2 | 1 | 623 | 1136352 | 8877.75 | 8789.75 |
| RHST | 00 | 2048 | 31 | 128 | 9769 | 17818656 | 8700.52 | - |
| SPN0 | 00 | 512 | 47 | 17 | 14634 | 26692416 | 52133.62 | - |
| ARSE | 00 | 128 | 2 | 23 | 645 | 1176480 | 9191.25 | 9096.81 |
| ARCO | 00 | 128 | 2 | 47 | 669 | 1220256 | 9533.25 | 9438.75 |
| AHST | 00 | 2048 | 34 | -79 | 10495 | 19142880 | 9347.11 | - |
| ASPN | 00 | 512 | 50 | 172 | 15722 | 28676928 | 56009.62 | - |
| OSPN | 00 | 512 | 52 | 48 | 16220 | 29585280 | 57783.75 | - |

#HIST RHST: bin 1 = 2048

#HIST AHST: bin 1 = 2048

clip 061 stereo 320x160@25: Spix 100, Ssnd 3, C 320 (section 2)

| tag | O | R | F | D | lines | T | T/rep | primed |
|---|---|---|---|---|---|---|---|---|
| IDEN | 02 | 250 | 320 | 160 | | | | |
| RFR0 | 00 | 1 | 2 | -116 | 506 | 922944 | 922944.00 | 922734.00 |
| RSWP | 00 | 16 | 25 | 86 | 7861 | 14338464 | 896154.00 | 895944.00 |
| ARSW | 00 | 16 | 27 | 48 | 8445 | 15403680 | 962730.00 | 962504.40 |
| RSEC | 00 | 128 | 2 | -21 | 601 | 1096224 | 8564.25 | 8476.25 |
| RCOL | 00 | 128 | 2 | 1 | 623 | 1136352 | 8877.75 | 8789.75 |
| RHST | 00 | 2048 | 31 | 128 | 9769 | 17818656 | 8700.52 | - |
| SPN0 | 00 | 512 | 47 | 16 | 14633 | 26690592 | 52130.06 | - |
| ARSE | 00 | 128 | 2 | 24 | 646 | 1178304 | 9205.50 | 9110.91 |
| ARCO | 00 | 128 | 2 | 47 | 669 | 1220256 | 9533.25 | 9438.75 |
| AHST | 00 | 2048 | 34 | -78 | 10496 | 19144704 | 9348.00 | - |
| ASPN | 00 | 512 | 50 | 172 | 15722 | 28676928 | 56009.62 | - |
| OSPN | 00 | 512 | 52 | 48 | 16220 | 29585280 | 57783.75 | - |

#HIST RHST: bin 1 = 2048

#HIST AHST: bin 1 = 2048

clip 062 stereo 320x192@25: Spix 120, Ssnd 3, C 320 (section 3)

| tag | O | R | F | D | lines | T | T/rep | primed |
|---|---|---|---|---|---|---|---|---|
| IDEN | 02 | 250 | 320 | 192 | | | | |
| RFR0 | 00 | 1 | 1 | 287 | 598 | 1090752 | 1090752.00 | 1090542.00 |
| RSWP | 00 | 16 | 30 | 12 | 9342 | 17039808 | 1064988.00 | 1064778.00 |
| ARSW | 00 | 16 | 32 | 87 | 10039 | 18311136 | 1144446.00 | 1144220.33 |
| RSEC | 00 | 128 | 2 | -21 | 601 | 1096224 | 8564.25 | 8476.25 |
| RCOL | 00 | 128 | 2 | 0 | 622 | 1134528 | 8863.50 | 8775.50 |
| RHST | 00 | 2048 | 32 | -183 | 9769 | 17818656 | 8700.52 | - |
| SPN0 | 00 | 512 | 47 | 17 | 14634 | 26692416 | 52133.62 | - |
| ARSE | 00 | 128 | 2 | 24 | 646 | 1178304 | 9205.50 | 9110.91 |
| ARCO | 00 | 128 | 2 | 46 | 668 | 1218432 | 9519.00 | 9424.49 |
| AHST | 00 | 2048 | 33 | 232 | 10495 | 19142880 | 9347.11 | - |
| ASPN | 00 | 512 | 50 | 172 | 15722 | 28676928 | 56009.62 | - |
| OSPN | 00 | 512 | 52 | 48 | 16220 | 29585280 | 57783.75 | - |

#HIST RHST: bin 1 = 2048

#HIST AHST: bin 1 = 2048

clip 063 stereo 280x224@25: Spix 123, Ssnd 3, C 280 (section 4)

| tag | O | R | F | D | lines | T | T/rep | primed |
|---|---|---|---|---|---|---|---|---|
| IDEN | 02 | 250 | 280 | 224 | | | | |
| RFR0 | 00 | 1 | 1 | 300 | 611 | 1114464 | 1114464.00 | 1114254.00 |
| RSWP | 00 | 16 | 30 | 227 | 9557 | 17431968 | 1089498.00 | 1089288.00 |
| ARSW | 00 | 16 | 33 | 7 | 10270 | 18732480 | 1170780.00 | 1170554.33 |
| RSEC | 00 | 128 | 2 | -21 | 601 | 1096224 | 8564.25 | 8476.25 |
| RCOL | 00 | 128 | 2 | 1 | 623 | 1136352 | 8877.75 | 8789.75 |
| RHST | 00 | 2048 | 31 | 128 | 9769 | 17818656 | 8700.52 | - |
| SPN0 | 00 | 512 | 47 | 16 | 14633 | 26690592 | 52130.06 | - |
| ARSE | 00 | 128 | 2 | 23 | 645 | 1176480 | 9191.25 | 9096.81 |
| ARCO | 00 | 128 | 2 | 47 | 669 | 1220256 | 9533.25 | 9438.75 |
| AHST | 00 | 2048 | 33 | 232 | 10495 | 19142880 | 9347.11 | - |
| ASPN | 00 | 512 | 50 | 172 | 15722 | 28676928 | 56009.62 | - |
| OSPN | 00 | 512 | 52 | 48 | 16220 | 29585280 | 57783.75 | - |

#HIST RHST: bin 1 = 2048

#HIST AHST: bin 1 = 2048

clip 064 stereo 320x240@16.67: Spix 150, Ssnd 4, C 320 (section 5)

| tag | O | R | F | D | lines | T | T/rep | primed |
|---|---|---|---|---|---|---|---|---|
| IDEN | 02 | 167 | 320 | 240 | | | | |
| RFR0 | 00 | 1 | 3 | -190 | 743 | 1355232 | 1355232.00 | 1355022.00 |
| RSWP | 00 | 16 | 37 | 139 | 11646 | 21242304 | 1327644.00 | 1327434.00 |
| ARSW | 00 | 16 | 40 | 74 | 12514 | 22825536 | 1426596.00 | 1426370.35 |
| RSEC | 00 | 128 | 2 | -21 | 601 | 1096224 | 8564.25 | 8476.25 |
| RCOL | 00 | 128 | 2 | 1 | 623 | 1136352 | 8877.75 | 8789.75 |
| RHST | 00 | 2048 | 31 | 128 | 9769 | 17818656 | 8700.52 | - |
| SPN0 | 00 | 512 | 47 | 16 | 14633 | 26690592 | 52130.06 | - |
| ARSE | 00 | 128 | 2 | 23 | 645 | 1176480 | 9191.25 | 9096.81 |
| ARCO | 00 | 128 | 2 | 47 | 669 | 1220256 | 9533.25 | 9438.75 |
| AHST | 00 | 2048 | 34 | -79 | 10495 | 19142880 | 9347.11 | - |
| ASPN | 00 | 512 | 51 | -139 | 15722 | 28676928 | 56009.62 | - |
| OSPN | 00 | 512 | 52 | 48 | 16220 | 29585280 | 57783.75 | - |

#HIST RHST: bin 1 = 2048

#HIST AHST: bin 1 = 2048

clip 065 stereo 256x240@16.67: Spix 120, Ssnd 4, C 256 (section 6)

| tag | O | R | F | D | lines | T | T/rep | primed |
|---|---|---|---|---|---|---|---|---|
| IDEN | 02 | 167 | 256 | 240 | | | | |
| RFR0 | 00 | 1 | 2 | -20 | 602 | 1098048 | 1098048.00 | 1097838.00 |
| RSWP | 00 | 16 | 30 | 63 | 9393 | 17132832 | 1070802.00 | 1070592.00 |
| ARSW | 00 | 16 | 32 | 142 | 10094 | 18411456 | 1150716.00 | 1150490.33 |
| RSEC | 00 | 128 | 2 | -21 | 601 | 1096224 | 8564.25 | 8476.25 |
| RCOL | 00 | 128 | 2 | 0 | 622 | 1134528 | 8863.50 | 8775.50 |
| RHST | 00 | 2048 | 31 | 128 | 9769 | 17818656 | 8700.52 | - |
| SPN0 | 00 | 512 | 47 | 16 | 14633 | 26690592 | 52130.06 | - |
| ARSE | 00 | 128 | 2 | 23 | 645 | 1176480 | 9191.25 | 9096.81 |
| ARCO | 00 | 128 | 2 | 47 | 669 | 1220256 | 9533.25 | 9438.60 |
| AHST | 00 | 2048 | 33 | 232 | 10495 | 19142880 | 9347.11 | - |
| ASPN | 00 | 512 | 50 | 172 | 15722 | 28676928 | 56009.62 | - |
| OSPN | 00 | 512 | 52 | 48 | 16220 | 29585280 | 57783.75 | - |

#HIST RHST: bin 1 = 2048

#HIST AHST: bin 1 = 2048

clip 066 mono 256x192@25: Spix 96, Ssnd 2, C 0 (section 7)

| tag | O | R | F | D | lines | T | T/rep | primed |
|---|---|---|---|---|---|---|---|---|
| IDEN | 02 | 250 | 256 | 192 | | | | |
| RFR0 | 00 | 1 | 1 | 165 | 476 | 868224 | 868224.00 | 868014.00 |
| RSWP | 00 | 16 | 24 | -69 | 7395 | 13488480 | 843030.00 | 842820.00 |
| ARSW | 00 | 16 | 25 | 66 | 7841 | 14301984 | 893874.00 | 893651.33 |
| RSEC | 00 | 128 | 2 | -21 | 601 | 1096224 | 8564.25 | 8476.25 |
| RCOL | 00 | 128 | 2 | 1 | 623 | 1136352 | 8877.75 | 8789.75 |
| RHST | 00 | 2048 | 31 | 128 | 9769 | 17818656 | 8700.52 | - |
| SPN0 | 00 | 512 | 47 | 16 | 14633 | 26690592 | 52130.06 | - |
| ARSE | 00 | 128 | 2 | 15 | 637 | 1161888 | 9077.25 | 8983.98 |
| ARCO | 00 | 128 | 2 | 38 | 660 | 1203840 | 9405.00 | 9311.77 |
| AHST | 00 | 2048 | 33 | 96 | 10359 | 18894816 | 9225.98 | - |
| ASPN | 00 | 512 | 49 | 279 | 15518 | 28304832 | 55282.88 | - |
| OSPN | 00 | 512 | 52 | 48 | 16220 | 29585280 | 57783.75 | - |

#HIST RHST: bin 1 = 2048

#HIST AHST: bin 1 = 2048

clip 067 mono 320x160@25: Spix 100, Ssnd 2, C 320 (section 8)

| tag | O | R | F | D | lines | T | T/rep | primed |
|---|---|---|---|---|---|---|---|---|
| IDEN | 02 | 250 | 320 | 160 | | | | |
| RFR0 | 00 | 1 | 2 | -120 | 502 | 915648 | 915648.00 | 915438.00 |
| RSWP | 00 | 16 | 25 | 21 | 7796 | 14219904 | 888744.00 | 888534.00 |
| ARSW | 00 | 16 | 27 | -129 | 8268 | 15080832 | 942552.00 | 942329.29 |
| RSEC | 00 | 128 | 2 | -21 | 601 | 1096224 | 8564.25 | 8476.25 |
| RCOL | 00 | 128 | 2 | 0 | 622 | 1134528 | 8863.50 | 8775.50 |
| RHST | 00 | 2048 | 31 | 128 | 9769 | 17818656 | 8700.52 | - |
| SPN0 | 00 | 512 | 47 | 16 | 14633 | 26690592 | 52130.06 | - |
| ARSE | 00 | 128 | 2 | 15 | 637 | 1161888 | 9077.25 | 8983.98 |
| ARCO | 00 | 128 | 2 | 38 | 660 | 1203840 | 9405.00 | 9311.62 |
| AHST | 00 | 2048 | 34 | -215 | 10359 | 18894816 | 9225.98 | - |
| ASPN | 00 | 512 | 49 | 278 | 15517 | 28303008 | 55279.31 | - |
| OSPN | 00 | 512 | 52 | 48 | 16220 | 29585280 | 57783.75 | - |

#HIST RHST: bin 1 = 2048

#HIST AHST: bin 1 = 2048

clip 068 mono 320x192@25: Spix 120, Ssnd 2, C 320 (section 9)

| tag | O | R | F | D | lines | T | T/rep | primed |
|---|---|---|---|---|---|---|---|---|
| IDEN | 02 | 250 | 320 | 192 | | | | |
| RFR0 | 00 | 1 | 1 | 283 | 594 | 1083456 | 1083456.00 | 1083246.00 |
| RSWP | 00 | 16 | 29 | 260 | 9279 | 16924896 | 1057806.00 | 1057596.00 |
| ARSW | 00 | 16 | 31 | 199 | 9840 | 17948160 | 1121760.00 | 1121537.30 |
| RSEC | 00 | 128 | 2 | -21 | 601 | 1096224 | 8564.25 | 8476.25 |
| RCOL | 00 | 128 | 2 | 0 | 622 | 1134528 | 8863.50 | 8775.50 |
| RHST | 00 | 2048 | 31 | 128 | 9769 | 17818656 | 8700.52 | - |
| SPN0 | 00 | 512 | 47 | 17 | 14634 | 26692416 | 52133.62 | - |
| ARSE | 00 | 128 | 2 | 15 | 637 | 1161888 | 9077.25 | 8983.98 |
| ARCO | 00 | 128 | 2 | 38 | 660 | 1203840 | 9405.00 | 9311.62 |
| AHST | 00 | 2048 | 33 | 96 | 10359 | 18894816 | 9225.98 | - |
| ASPN | 00 | 512 | 50 | -33 | 15517 | 28303008 | 55279.31 | - |
| OSPN | 00 | 512 | 52 | 48 | 16220 | 29585280 | 57783.75 | - |

#HIST RHST: bin 1 = 2048

#HIST AHST: bin 1 = 2048

clip 069 mono 280x224@25: Spix 123, Ssnd 2, C 280 (section 11)

| tag | O | R | F | D | lines | T | T/rep | primed |
|---|---|---|---|---|---|---|---|---|
| IDEN | 02 | 250 | 280 | 224 | | | | |
| RFR0 | 00 | 1 | 1 | 297 | 608 | 1108992 | 1108992.00 | 1108782.00 |
| RSWP | 00 | 16 | 30 | 164 | 9494 | 17317056 | 1082316.00 | 1082106.00 |
| ARSW | 00 | 16 | 32 | 115 | 10067 | 18362208 | 1147638.00 | 1147415.33 |
| RSEC | 00 | 128 | 2 | -21 | 601 | 1096224 | 8564.25 | 8476.25 |
| RCOL | 00 | 128 | 2 | 1 | 623 | 1136352 | 8877.75 | 8789.75 |
| RHST | 00 | 2048 | 31 | 128 | 9769 | 17818656 | 8700.52 | - |
| SPN0 | 00 | 512 | 47 | 16 | 14633 | 26690592 | 52130.06 | - |
| ARSE | 00 | 128 | 2 | 15 | 637 | 1161888 | 9077.25 | 8983.98 |
| ARCO | 00 | 128 | 2 | 38 | 660 | 1203840 | 9405.00 | 9311.77 |
| AHST | 00 | 2048 | 34 | -215 | 10359 | 18894816 | 9225.98 | - |
| ASPN | 00 | 512 | 49 | 278 | 15517 | 28303008 | 55279.31 | - |
| OSPN | 00 | 512 | 52 | 48 | 16220 | 29585280 | 57783.75 | - |

#HIST RHST: bin 1 = 2048

#HIST AHST: bin 1 = 2048

clip 070 mono 320x240@16.67: Spix 150, Ssnd 2, C 320 (section 12)

| tag | O | R | F | D | lines | T | T/rep | primed |
|---|---|---|---|---|---|---|---|---|
| IDEN | 02 | 167 | 320 | 240 | | | | |
| RFR0 | 00 | 1 | 2 | 109 | 731 | 1333344 | 1333344.00 | 1333134.00 |
| RSWP | 00 | 16 | 37 | -43 | 11464 | 20910336 | 1306896.00 | 1306686.00 |
| ARSW | 00 | 16 | 39 | 28 | 12157 | 22174368 | 1385898.00 | 1385675.31 |
| RSEC | 00 | 128 | 2 | -21 | 601 | 1096224 | 8564.25 | 8476.25 |
| RCOL | 00 | 128 | 2 | 0 | 622 | 1134528 | 8863.50 | 8775.50 |
| RHST | 00 | 2048 | 32 | -183 | 9769 | 17818656 | 8700.52 | - |
| SPN0 | 00 | 512 | 47 | 17 | 14634 | 26692416 | 52133.62 | - |
| ARSE | 00 | 128 | 2 | 15 | 637 | 1161888 | 9077.25 | 8983.98 |
| ARCO | 00 | 128 | 2 | 38 | 660 | 1203840 | 9405.00 | 9311.62 |
| AHST | 00 | 2048 | 33 | 96 | 10359 | 18894816 | 9225.98 | - |
| ASPN | 00 | 512 | 50 | -33 | 15517 | 28303008 | 55279.31 | - |
| OSPN | 00 | 512 | 52 | 49 | 16221 | 29587104 | 57787.31 | - |

#HIST RHST: bin 1 = 2048

#HIST AHST: bin 1 = 2048

clip 071 mono 256x240@16.67: Spix 120, Ssnd 2, C 256 (section 13)

| tag | O | R | F | D | lines | T | T/rep | primed |
|---|---|---|---|---|---|---|---|---|
| IDEN | 02 | 167 | 256 | 240 | | | | |
| RFR0 | 00 | 1 | 2 | -32 | 590 | 1076160 | 1076160.00 | 1075950.00 |
| RSWP | 00 | 16 | 30 | -120 | 9210 | 16799040 | 1049940.00 | 1049730.00 |
| ARSW | 00 | 16 | 31 | 126 | 9767 | 17815008 | 1113438.00 | 1113215.30 |
| RSEC | 00 | 128 | 1 | 290 | 601 | 1096224 | 8564.25 | 8476.25 |
| RCOL | 00 | 128 | 2 | 0 | 622 | 1134528 | 8863.50 | 8775.50 |
| RHST | 00 | 2048 | 31 | 128 | 9769 | 17818656 | 8700.52 | - |
| SPN0 | 00 | 512 | 47 | 17 | 14634 | 26692416 | 52133.62 | - |
| ARSE | 00 | 128 | 2 | 15 | 637 | 1161888 | 9077.25 | 8983.98 |
| ARCO | 00 | 128 | 2 | 38 | 660 | 1203840 | 9405.00 | 9311.62 |
| AHST | 00 | 2048 | 33 | 96 | 10359 | 18894816 | 9225.98 | - |
| ASPN | 00 | 512 | 50 | -33 | 15517 | 28303008 | 55279.31 | - |
| OSPN | 00 | 512 | 52 | 48 | 16220 | 29585280 | 57783.75 | - |

#HIST RHST: bin 1 = 2048

#HIST AHST: bin 1 = 2048

clip 072 stereo 320x256@12.5: Spix 160, Ssnd 5, C 0 (section 14)

| tag | O | R | F | D | lines | T | T/rep | primed |
|---|---|---|---|---|---|---|---|---|
| IDEN | 02 | 125 | 320 | 0 | | | | |
| RFR0 | 00 | 1 | 2 | 165 | 787 | 1435488 | 1435488.00 | 1435278.00 |
| RSWP | 00 | 16 | 39 | 220 | 12349 | 22524576 | 1407786.00 | 1407576.00 |
| ARSW | 00 | 16 | 42 | 210 | 13272 | 24208128 | 1513008.00 | 1512782.30 |
| RSEC | 00 | 128 | 1 | 290 | 601 | 1096224 | 8564.25 | 8476.25 |
| RCOL | 00 | 128 | 2 | 0 | 622 | 1134528 | 8863.50 | 8775.50 |
| RHST | 00 | 2048 | 31 | 128 | 9769 | 17818656 | 8700.52 | - |
| SPN0 | 00 | 512 | 47 | 17 | 14634 | 26692416 | 52133.62 | - |
| ARSE | 00 | 128 | 2 | 23 | 645 | 1176480 | 9191.25 | 9096.81 |
| ARCO | 00 | 128 | 2 | 47 | 669 | 1220256 | 9533.25 | 9438.60 |
| AHST | 00 | 2048 | 34 | -79 | 10495 | 19142880 | 9347.11 | - |
| ASPN | 00 | 512 | 50 | 172 | 15722 | 28676928 | 56009.62 | - |
| OSPN | 00 | 512 | 52 | 48 | 16220 | 29585280 | 57783.75 | - |

#HIST RHST: bin 1 = 2048

#HIST AHST: bin 1 = 2048

clip 074 mono 256x192@15.2588: Spix 96, Ssnd 3, C 0 (section 15)

| tag | O | R | F | D | lines | T | T/rep | primed |
|---|---|---|---|---|---|---|---|---|
| IDEN | 02 | 153 | 256 | 192 | | | | |
| RFR0 | 00 | 1 | 1 | 171 | 482 | 879168 | 879168.00 | 878958.00 |
| RSWP | 00 | 16 | 24 | 32 | 7496 | 13672704 | 854544.00 | 854334.00 |
| ARSW | 00 | 16 | 25 | 174 | 7949 | 14498976 | 906186.00 | 905963.31 |
| RSEC | 00 | 128 | 2 | -21 | 601 | 1096224 | 8564.25 | 8476.25 |
| RCOL | 00 | 128 | 2 | 1 | 623 | 1136352 | 8877.75 | 8789.75 |
| RHST | 00 | 2048 | 32 | -183 | 9769 | 17818656 | 8700.52 | - |
| SPN0 | 00 | 512 | 47 | 16 | 14633 | 26690592 | 52130.06 | - |
| ARSE | 00 | 128 | 2 | 15 | 637 | 1161888 | 9077.25 | 8983.98 |
| ARCO | 00 | 128 | 2 | 38 | 660 | 1203840 | 9405.00 | 9311.77 |
| AHST | 00 | 2048 | 33 | 96 | 10359 | 18894816 | 9225.98 | - |
| ASPN | 00 | 512 | 50 | -33 | 15517 | 28303008 | 55279.31 | - |
| OSPN | 00 | 512 | 52 | 48 | 16220 | 29585280 | 57783.75 | - |

#HIST RHST: bin 1 = 2048

#HIST AHST: bin 1 = 2048

## Checks

- IDEN (O, frames, width, height byte) matches the fixture table on every used capture (a mismatch excludes the capture, listed above)
- clip 060 file: header matches (channels 2, sound bytes 1250, Ssnd 3); palette sectors in frames 0-32: 0
- clip 061 file: header matches (channels 2, sound bytes 1250, Ssnd 3); palette sectors in frames 0-32: 0
- clip 062 file: header matches (channels 2, sound bytes 1250, Ssnd 3); palette sectors in frames 0-32: 0
- clip 063 file: header matches (channels 2, sound bytes 1250, Ssnd 3); palette sectors in frames 0-32: 0
- clip 064 file: header matches (channels 2, sound bytes 1874, Ssnd 4); palette sectors in frames 0-32: 0
- clip 065 file: header matches (channels 2, sound bytes 1874, Ssnd 4); palette sectors in frames 0-32: 0
- clip 066 file: header matches (channels 1, sound bytes 625, Ssnd 2); palette sectors in frames 0-32: 0
- clip 067 file: header matches (channels 1, sound bytes 625, Ssnd 2); palette sectors in frames 0-32: 0
- clip 068 file: header matches (channels 1, sound bytes 625, Ssnd 2); palette sectors in frames 0-32: 0
- clip 069 file: header matches (channels 1, sound bytes 625, Ssnd 2); palette sectors in frames 0-32: 0
- clip 070 file: header matches (channels 1, sound bytes 937, Ssnd 2); palette sectors in frames 0-32: 0
- clip 071 file: header matches (channels 1, sound bytes 937, Ssnd 2); palette sectors in frames 0-32: 0
- clip 072 file: header matches (channels 2, sound bytes 2500, Ssnd 5); palette sectors in frames 0-32: 0
- clip 074 file: header matches (channels 1, sound bytes 1024, Ssnd 3); palette sectors in frames 0-32: 0
- histograms: 28, every one sums to its row's reps unless listed
- peers RSEC (all clips)       14 clips, largest deviation 0.00%
- peers RCOL (all clips)       14 clips, largest deviation 0.08%
- peers RHST (all clips)       14 clips, largest deviation 0.00%
- peers SPN0 (all clips)       14 clips, largest deviation 0.01%
- peers OSPN (all clips)       14 clips, largest deviation 0.01%
- peers RHST polls (all clips) 14 clips, largest deviation 0.00%
- peers ARSE (stereo)           7 clips, largest deviation 0.16%
- peers ARCO (stereo)           7 clips, largest deviation 0.15%
- peers AHST (stereo)           7 clips, largest deviation 0.01%
- peers ASPN (stereo)           7 clips, largest deviation 0.00%
- peers AHST polls (stereo)     7 clips, largest deviation 0.00%
- peers ARSE (mono)             7 clips, largest deviation 0.00%
- peers ARCO (mono)             7 clips, largest deviation 0.00%
- peers AHST (mono)             7 clips, largest deviation 0.00%
- peers ASPN (mono)             7 clips, largest deviation 0.01%
- peers AHST polls (mono)       7 clips, largest deviation 0.00%
- order RSWP/16 < ARSW/16      14/14 clips
- order RSWP/16 < RFR0         14/14 clips
- walk marks (O=01): none

Anomalies (RE-RUN request): none

## Constants

RAW_SECTOR_T (ts) = 284.25 T: mean (RSEC' - 8192) over 14 clips [RSEC]

stereo:
  RAW_T_PER_B (tb)      = 17.2199 T: (mean ARSE' - ts) / 512 over 7 clips [ARSE, RSEC]
  RAW_COL_T (tc)        = 41.98 T: mean (ARCO' - ARSE') / 8 over 7 clips [ARCO, ARSE, RCOL, RSEC]
  RAW_SND_SECTOR_T (tsnd) = 8684.76 T: least squares slope over 7 clips [ARSW, RSWP, ARSE, ARCO]
  RAW_FRAME_T (tf)      = 13106.40 T: least squares intercept, same points
  RAW_PAL_T (tp)        = 28473.15 T: mean (RFR0' - RSWP') x ARSW'/RSWP' over 7 clips [RFR0, RSWP, ARSW]
  least squares points (clip, Ssnd, y = ARSW' - Spix x mean ARSE' - C x tc): 060 3 39690.0; 061 3 38987.3; 062 3 38686.5; 063 3 39397.2; 064 4 47811.4; 065 4 47643.2; 072 5 56648.4
  tp per clip: 060 27320.9; 061 28780.3; 062 27686.2; 063 26828.6; 064 29644.2; 065 29279.4; 072 29772.5

mono:
  RAW_T_PER_B (tb)      = 16.9917 T: (mean ARSE' - ts) / 512 over 7 clips [ARSE, RSEC]
  RAW_COL_T (tc)        = 40.96 T: mean (ARCO' - ARSE') / 8 over 7 clips [ARCO, ARSE, RCOL, RSEC]
  RAW_SND_SECTOR_T (tsnd) = 14684.47 T: least squares slope over 7 clips [ARSW, RSWP, ARSE, ARCO]
  RAW_FRAME_T (tf)      = -552.06 T: least squares intercept, same points
  RAW_PAL_T (tp)        = 27528.25 T: mean (RFR0' - RSWP') x ARSW'/RSWP' over 7 clips [RFR0, RSWP, ARSW]
  least squares points (clip, Ssnd, y = ARSW' - Spix x mean ARSE' - C x tc): 066 2 31189.4; 067 2 30823.0; 068 2 30351.5; 069 2 30916.1; 070 2 24970.1; 071 2 24651.1; 074 3 43501.3
  tp per clip: 066 26713.5; 067 28532.9; 068 27200.8; 069 28286.0; 070 28046.8; 071 27805.7; 074 26112.1
note: mono RAW_SND_SECTOR_T rests on clip 074 alone (its third sector is nearly all pad); valid for 2-sector shapes, not general

RAW_STALL_T = 51.59 T: highest occupied AHST bin 1 (1-1 polls), upper edge 1 x 48 T x ARSE/RSEC (clip 062) [AHST, ARSE, RSEC]
mean token wait (bins at their mean poll count): unarmed 48.00 T [RHST]; armed stereo 51.54 T, mono 50.88 T [AHST x ARSE/RSEC]
mean stall per frame = armed mean wait x tokens a frame (Spix + Ssnd + 1):
  256x192@25: stereo 5154 T (100 tokens), mono 5037 T (99 tokens)
  320x160@25: stereo 5360 T (104 tokens), mono 5240 T (103 tokens)
  320x192@25: stereo 6391 T (124 tokens), mono 6258 T (123 tokens)
  280x224@25: stereo 6545 T (127 tokens), mono 6410 T (126 tokens)
  320x240@16.67: stereo 7988 T (155 tokens), mono 7784 T (153 tokens)
  256x240@16.67: stereo 6442 T (125 tokens), mono 6258 T (123 tokens)

Paste form:

```
RAW_K = {
    "stereo": {
        "tb": 17.2199,  # RAW_T_PER_B [ARSE, RSEC] 7 clips
        "ts": 284.25,  # RAW_SECTOR_T [RSEC] 14 clips
        "tsnd": 8684.76,  # RAW_SND_SECTOR_T [ARSW, RSWP, ARSE, ARCO] 7 clips
        "tc": 41.98,  # RAW_COL_T [ARCO, ARSE, RCOL, RSEC] 7 clips
        "tf": 13106.40,  # RAW_FRAME_T [ARSW, RSWP, ARSE, ARCO] 7 clips
        "tp": 28473.15,  # RAW_PAL_T [RFR0, RSWP, ARSW] 7 clips
    },
    "mono": {
        "tb": 16.9917,  # RAW_T_PER_B [ARSE, RSEC] 7 clips
        "ts": 284.25,  # RAW_SECTOR_T [RSEC] 14 clips
        "tsnd": 14684.47,  # RAW_SND_SECTOR_T [ARSW, RSWP, ARSE, ARCO] 7 clips
        "tc": 40.96,  # RAW_COL_T [ARCO, ARSE, RCOL, RSEC] 7 clips
        "tf": -552.06,  # RAW_FRAME_T [ARSW, RSWP, ARSE, ARCO] 7 clips
        "tp": 27528.25,  # RAW_PAL_T [RFR0, RSWP, ARSW] 7 clips
    },
}
RAW_STALL_T = 51.59  # AHST bin 1 upper edge x ARSE/RSEC [AHST, ARSE, RSEC]
```

## Residuals

residual = 100 x (measured - model) / model; measured = ARSW' (ARSW/16, harness removed); model = raw_model_t(..., palette=False). Acceptance: every |residual| <= 1.0%.

| clip | form | Spix | Ssnd | C | sound B | pad B | measured ARSW' | model | residual % |
|---|---|---|---|---|---|---|---|---|---|
| 060 | stereo | 96 | 3 | 0 | 1250 | 286 | 913370.3 | 912841.0 | +0.058 |
| 061 | stereo | 100 | 3 | 320 | 1250 | 286 | 962504.4 | 962677.8 | -0.018 |
| 062 | stereo | 120 | 3 | 320 | 1250 | 286 | 1144220.3 | 1144694.5 | -0.041 |
| 063 | stereo | 123 | 3 | 280 | 1250 | 286 | 1170554.3 | 1170317.9 | +0.020 |
| 064 | stereo | 150 | 4 | 320 | 1874 | 174 | 1426370.3 | 1426404.4 | -0.002 |
| 065 | stereo | 120 | 4 | 256 | 1874 | 174 | 1150490.3 | 1150692.6 | -0.018 |
| 066 | mono | 96 | 2 | 0 | 625 | 399 | 893651.3 | 891278.8 | +0.266 |
| 067 | mono | 100 | 2 | 320 | 625 | 399 | 942329.3 | 940323.1 | +0.213 |
| 068 | mono | 120 | 2 | 320 | 625 | 399 | 1121537.3 | 1120002.7 | +0.137 |
| 069 | mono | 123 | 2 | 280 | 625 | 399 | 1147415.3 | 1145316.1 | +0.183 |
| 070 | mono | 150 | 2 | 320 | 937 | 87 | 1385675.3 | 1389522.1 | -0.277 |
| 071 | mono | 120 | 2 | 256 | 937 | 87 | 1113215.3 | 1117381.0 | -0.373 |
| 072 | stereo | 160 | 5 | 0 | 2500 | 60 | 1512782.3 | 1512664.1 | +0.008 |
| 074 | mono | 96 | 3 | 0 | 1024 | 512 | 905963.3 | 905963.3 | +0.000 |

pad B: the sound sectors' pad bytes a frame, the tag byte included.

acceptance: PASS (largest |residual| 0.373%)

## Utilisation of the target shapes

worst frame (palette sector included) + glue 1138.7 T (glue_t / audio_factor), over the plan's period 28363200 / fps T; F = 1.0.

| shape | form | Spix | Ssnd | C | model T | period T | util | util with stall | ref: util, no palette sector |
|---|---|---|---|---|---|---|---|---|---|
| 256x192@25 | stereo | 96 | 3 | 0 | 941314 | 1134528 | 0.8307 | 0.8307 | 0.8056 |
| 256x192@25 | mono | 96 | 2 | 0 | 918807 | 1134528 | 0.8109 | 0.8109 | 0.7866 |
| 320x160@25 | stereo | 100 | 3 | 320 | 991151 | 1134528 | 0.8746 | 0.8747 | 0.8495 |
| 320x160@25 | mono | 100 | 2 | 320 | 967851 | 1134528 | 0.8541 | 0.8541 | 0.8298 |
| 320x192@25 | stereo | 120 | 3 | 320 | 1173168 | 1134528 | 1.0351 | 1.0351 | 1.0100 |
| 320x192@25 | mono | 120 | 2 | 320 | 1147531 | 1134528 | 1.0125 | 1.0125 | 0.9882 |
| 280x224@25 | stereo | 123 | 3 | 280 | 1198791 | 1134528 | 1.0576 | 1.0577 | 1.0325 |
| 280x224@25 | mono | 123 | 2 | 280 | 1172844 | 1134528 | 1.0348 | 1.0348 | 1.0105 |
| 320x240@16.67 | stereo | 150 | 4 | 320 | 1454878 | 1701452 | 0.8557 | 0.8558 | 0.8390 |
| 320x240@16.67 | mono | 150 | 2 | 320 | 1417050 | 1701452 | 0.8335 | 0.8335 | 0.8173 |
| 256x240@16.67 | stereo | 120 | 4 | 256 | 1179166 | 1701452 | 0.6937 | 0.6937 | 0.6770 |
| 256x240@16.67 | mono | 120 | 2 | 256 | 1144909 | 1701452 | 0.6736 | 0.6736 | 0.6574 |

stereo over 1.00: 320x192@25, 320x192@25 (with stall), 280x224@25, 280x224@25 (with stall)
stereo within 10 percent of the limit (0.90 < util <= 1.00): none
mono over 1.00: 320x192@25, 320x192@25 (with stall), 280x224@25, 280x224@25 (with stall)
mono within 10 percent of the limit (0.90 < util <= 1.00): none

For reference, not the plan's figure: the frame loop releases a frame on its sound (samples x CTC period):

| shape | form | samples | sound period T | util at the sound period |
|---|---|---|---|---|
| 256x192@25 | stereo | 625 | 1120000 | 0.8415 |
| 256x192@25 | mono | 625 | 1120000 | 0.8214 |
| 320x160@25 | stereo | 625 | 1120000 | 0.8860 |
| 320x160@25 | mono | 625 | 1120000 | 0.8652 |
| 320x192@25 | stereo | 625 | 1120000 | 1.0485 |
| 320x192@25 | mono | 625 | 1120000 | 1.0256 |
| 280x224@25 | stereo | 625 | 1120000 | 1.0714 |
| 280x224@25 | mono | 625 | 1120000 | 1.0482 |
| 320x240@16.67 | stereo | 937 | 1679104 | 0.8671 |
| 320x240@16.67 | mono | 937 | 1679104 | 0.8446 |
| 256x240@16.67 | stereo | 937 | 1679104 | 0.7029 |
| 256x240@16.67 | mono | 937 | 1679104 | 0.6825 |

## Handlers, sectors, column ends

handler cost per interrupt = (armed - SPN0) / interrupts a rep; interrupts a rep = armed rep T / 1792 T
- raw stereo (ASPN, stereo clips): 124.08 T (31.26 interrupts a rep; 7 clips, 124.01-124.12)
- raw mono (ASPN, mono clips): 102.06 T (30.85 interrupts a rep; 7 clips, 101.97-102.20)
- existing video_ctc_isr_stereo (OSPN, all clips): 175.29 T (32.25 interrupts a rep; 14 clips, 175.22-175.33)
- per-sector overhead, unarmed: ts = 284.25 T (RSEC - 8192 as printed: 372.25 T)
- per-sector overhead, armed stereo: ARSE' - 8192 = 908.84 T (ARSE as printed 9195.32 T, ARSE/RSEC 1.0737)
- per-sector overhead, armed mono: ARSE' - 8192 = 791.98 T (ARSE as printed 9077.25 T, ARSE/RSEC 1.0599)
- column end, unarmed: (RCOL - RSEC) / 8 = 38.30 T against the 38 T design figure
- column end, armed stereo: tc = 41.98 T
- column end, armed mono: tc = 40.96 T

## Histograms (summed over clips)

bin k counts token waits of 2^(k-1) to 2^k - 1 $FF polls (bin 0: the token on the first read); a poll is 48 T unarmed, 48 x ARSE/RSEC armed.

| histogram | bin | polls | wait T | count |
|---|---|---|---|---|
| AHST stereo | 1 | 1-1 | 51.5-51.5 | 14336 |
| AHST stereo | all | | | 14336 |
| AHST mono | 1 | 1-1 | 50.9-50.9 | 14336 |
| AHST mono | all | | | 14336 |
| RHST | 1 | 1-1 | 48.0-48.0 | 28672 |
| RHST | all | | | 28672 |

## Old layout vs raw

old: NXBD on clip 10 (old direct layout), per block, rows as printed (the DS1 harness is not tracked); raw: RW1 means, per sector, as printed.

| what | old row | old T | raw row | raw T |
|---|---|---|---|---|
| open + 512 bare INI, unarmed | DTI0 | 9006.00 | RSEC | 8564.25 |
| open + 512 bare INI, armed | ADTI (old handler) | 9975.00 | ARSE stereo / mono (raw handlers) | 9195.32 / 9077.25 |
| open + 512 B to the destination, unarmed | DTC0 (vid_ds_xfer) | 9704.25 | RSEC (the slide is the transfer) | 8564.25 |
| open + 512 B to the destination, armed | ADTC (old handler) | 10758.75 | ARSE stereo / mono | 9195.32 / 9077.25 |
| open + split transfer | DTD0 (4 x xfer 128) | 10616.25 | RCOL (8 x 64, column ends) | 8870.62 |
| open + pad discard | DTB0 (vid_ds_pad) | 19536.75 | - (raw pad bytes are INI) | - |
| per-block overhead, unarmed | DTI0 - 8192 | 814.00 | RSEC - 8192 (ts) | 372.25 (284.25) |
| T per byte, armed, transfer included | ADTC / 512 | 21.013 | ARSE / 512 stereo / mono | 17.960 / 17.729 |
| gate T per byte | DIRECT_T_PER_B (section byte, wire included) | 24.2 | tb stereo / mono | 17.2199 / 16.9917 |

## Playback prediction (leg B clips)

model: worst frame + glue over the plan's period; DEBUG column adds 86 T a pixel sector (plain DEBUG vr_sector_n PLAY divider; the DEBUG token-wait accumulator is not priced). Admitted = util <= 1.00.

| clip | shape | form | util | util with stall | DEBUG util | model | readout |
|---|---|---|---|---|---|---|---|
| 060 | 256x192@25 | stereo | 0.8307 | 0.8307 | 0.8380 | admitted | awaited |
| 061 | 320x160@25 | stereo | 0.8746 | 0.8747 | 0.8822 | admitted | awaited |
| 062 | 320x192@25 | stereo | 1.0351 | 1.0351 | 1.0442 | refused | awaited |
| 063 | 280x224@25 | stereo | 1.0576 | 1.0577 | 1.0670 | refused | awaited |
| 064 | 320x240@16.67 | stereo | 0.8557 | 0.8558 | 0.8633 | admitted | awaited |
| 065 | 256x240@16.67 | stereo | 0.6937 | 0.6937 | 0.6998 | admitted | awaited |
| 066 | 256x192@25 | mono | 0.8109 | 0.8109 | 0.8181 | admitted | awaited |
| 067 | 320x160@25 | mono | 0.8541 | 0.8541 | 0.8617 | admitted | awaited |
| 068 | 320x192@25 | mono | 1.0125 | 1.0125 | 1.0216 | refused | awaited |
| 069 | 280x224@25 | mono | 1.0348 | 1.0348 | 1.0441 | refused | awaited |
| 070 | 320x240@16.67 | mono | 0.8335 | 0.8335 | 0.8411 | admitted | awaited |
| 071 | 256x240@16.67 | mono | 0.6736 | 0.6736 | 0.6796 | admitted | awaited |
| 072 | 320x256@12.5 | stereo | 0.6797 | 0.6797 | 0.6858 | admitted | awaited |
| 073 | 256x192@25 | stereo | 0.8307 | 0.8307 | 0.8380 | admitted | awaited |
| 074 | 256x192@15.2588 | mono | 0.5028 | 0.5028 | 0.5073 | admitted | awaited |
| 075 | 256x192@25 | stereo | 0.8307 | 0.8307 | 0.8380 | admitted | awaited |
| 076 | 256x192@25 | mono | 0.8109 | 0.8109 | 0.8181 | admitted | awaited |
| 077 | 256x192@25 | stereo | 0.8307 | 0.8307 | 0.8380 | admitted | awaited |
| 078 | 256x192@25 | mono | 0.8109 | 0.8109 | 0.8181 | admitted | awaited |
| 079 | 320x256@25 | stereo | 1.3441 | 1.3441 | 1.3562 | refused | awaited |
