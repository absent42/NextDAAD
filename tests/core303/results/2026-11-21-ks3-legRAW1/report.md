# Raw direct video - KS3 sitting 1 (leg A 2026-11-21; legs B and C returned 2026-11-22)

Sitting: KS3, core 3.03.03 (register line 51 3 3 3 0 0: NR $01 $33, NR $0E 3, NR $0F 3, +3 timing, 50 Hz, NR $11 0). Leg A: -BenchQuiet build from 3918c62 (interpreter source 09ba34b), log NXBENCH.TXT in this folder, 16 captures. Legs B and C: readouts in playback.md. Details in sitting.txt.

Produced by `python tests\raw_fit.py NXBENCH.TXT --clips <leg A folder> --playback playback.md`. The fit reads only NXBENCH.TXT. The clip files are read to check their headers and frame tags, and playback.md supplies the leg B readouts. ingest.py does not take this leg (no GATES.TXT in the leg folder; an NXB-only leg takes its timing from a same-date leg1, and there is none), so this folder follows the legBLT shape by hand and the timing comes from the register line through parse.timing.

## Summary

- Acceptance: PASS. Largest |residual| 0.373 percent (clip 071, mono). Stereo residuals are within 0.06 percent, mono within 0.38 percent. Acceptance tests nothing of the mono sound term (see "Sound term" below).
- Period: a frame is released on sound consumption, so the gate period is samples a frame x 1792 T (1,120,000 T at 25 fps), not two fields.
  - Code: vid_pace_poll at .pace and the deficit clamp at .paced in src/video.asm.
  - Leg B: an on-time 250-frame clip reads PLAY 01EE = 494 fields = 250 x 1,120,000 / 567,264; pacing on two fields would read 500.
  - The two-field figure is kept only as a reference column.
- Over 1.00 (palette frame, sound period):
  - stereo: 320x192@25 (1.0485), 280x224@25 (1.0714);
  - mono: 320x192@25 (1.0256), 280x224@25 (1.0482).
  - The stall term adds at most 0.0001. All four are over 1.00 on a pixels-only frame too (1.0231, 1.0459, 1.0010, 1.0236).
- Within 10 percent of the limit (0.90 < util <= 1.00): none in stereo, none in mono.
- Below 0.90 in both forms (stereo / mono): 256x192@25 (0.8415 / 0.8214), 320x160@25 (0.8860 / 0.8652), 320x240@16.67 (0.8671 / 0.8446), 256x240@16.67 (0.7029 / 0.6825).
- Largest admitted height at 25 fps (palette frame; pixels-only frame in brackets):

  | width | stereo | mono |
  |---|---|---|
  | 320 | 182 (187) | 185 (190) |
  | 280 | 208 (213) | 212 (219) |
  | 256 | 228 (234) | 234 (240) |

- Step 6: no clip the model admits showed LATE or URUN, and no clip it refuses played on time.
  - Clip 074 never played (seven tries, no rows). It is listed as a failure outside the model, under investigation.
  - 010 and 004 are outside the raw model.
- A late clip is slowed by more than its utilisation: once the reader passes the pump's writer, the next frame waits for ring room ("Playback (leg B)" below). With that wait, the model's PLAY matches leg B within one field for every late clip except 069, which is 1.3 fields off.
- Excluded: capture 10 (PICK 59, no such clip). It printed VID FILE?, its rows are clip 068's previous screen, and it has no #HIST lines.
- Anomalies for a RE-RUN request: none.

## Sound term

1. The mono sound constants are fixed exactly by 074 and the mean of the six 2-sector clips (two Ssnd groups for two constants). 074's residual is 0 by construction, so acceptance tests nothing of the mono sound term.
2. Stereo has three Ssnd groups for two constants, one degree of freedom, with 072 alone at 5 sound sectors.
3. The cost follows sound bytes against pad bytes. In the pad-aware fit (mono, sector count held), a pad byte costs 19.26 T more than a sound byte. In the code, vid_ds_pad discards a pad byte in 37 T, against about 16.4 T for a sound byte through vid_ds_xfer's ini train.
4. Mono RAW_FRAME_T (-552.06 T) is negative, and mono RAW_SND_SECTOR_T is 1.69 x stereo's. Both are artefacts of fitting one term a sector to that pattern; they must not be read as physical costs.
5. Gate error for sound layouts outside the fitted pairs (gate minus the pad-aware fit): mono 30 fps -4.0k T, mono 12.5 fps +4.4k T, stereo 20 fps -6.1k T, stereo 15.26 fps -8.8k T, stereo 30 fps -4.1k T. The largest is 0.48 percent of the period.
6. Rule: the constants are valid for the fitted pairs only (stereo at 25, 16.67 and 12.5 fps; mono at 25, 16.67 and 15.26 fps). Elsewhere, allow about 0.5 percent. The equation is unchanged; the diagnostic fit below is information for a later decision.

## 320x192@25 budget, percent of the 1,120,000 T period (palette frame)

| term | stereo | mono |
|---|---|---|
| pixel bytes (of which the sound handler) | 94.46 (6.54) | 93.21 (5.31) |
| per-sector overhead | 3.05 | 3.05 |
| column ends | 1.20 | 1.17 |
| sound sectors | 2.33 | 2.62 |
| frame remainder | 1.17 | -0.05 |
| palette sector | 2.54 | 2.46 |
| glue | 0.10 | 0.10 |
| total | 104.85 | 102.56 |

1.0 percent of a 25 fps period is 11,200 T a frame. The T figures and the arithmetic are in "Budget of a 320x192@25 frame" below.

## Observations

1. Mono residuals fall in two groups: 066-069 (625 sound bytes, 399 pad bytes a frame) +0.14 to +0.27 percent; 070-071 (937 sound bytes, 87 pad bytes) -0.28 and -0.37 percent; 074 0.000.
2. tp per clip spans 26,829-29,773 T (stereo) and 26,112-28,533 T (mono). RFR0 is a single rep by design, read on the 1,824 T line clock.
3. Every token wait in RHST and AHST is in bin 1 (exactly one $FF poll), on all 14 clips. RAW_STALL_T = 51.59 T, 0.005 percent of a 25 fps period.

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
- peers handler (stereo)        7 clips, largest deviation 0.09%
- peers handler (mono)          7 clips, largest deviation 0.11%
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
note: stereo sound constants rest on 3 groups for two constants, 1 degree(s) of freedom (Ssnd 3: 060 061 062 063, Ssnd 4: 064 065, Ssnd 5: 072); valid for the fitted pairs only (stereo at 25, 16.67, 12.5 fps); elsewhere allow about 0.5 percent

mono:
  RAW_T_PER_B (tb)      = 16.9917 T: (mean ARSE' - ts) / 512 over 7 clips [ARSE, RSEC]
  RAW_COL_T (tc)        = 40.96 T: mean (ARCO' - ARSE') / 8 over 7 clips [ARCO, ARSE, RCOL, RSEC]
  RAW_SND_SECTOR_T (tsnd) = 14684.47 T: least squares slope over 7 clips [ARSW, RSWP, ARSE, ARCO]
  RAW_FRAME_T (tf)      = -552.06 T: least squares intercept, same points
  RAW_PAL_T (tp)        = 27528.25 T: mean (RFR0' - RSWP') x ARSW'/RSWP' over 7 clips [RFR0, RSWP, ARSW]
  least squares points (clip, Ssnd, y = ARSW' - Spix x mean ARSE' - C x tc): 066 2 31189.4; 067 2 30823.0; 068 2 30351.5; 069 2 30916.1; 070 2 24970.1; 071 2 24651.1; 074 3 43501.3
  tp per clip: 066 26713.5; 067 28532.9; 068 27200.8; 069 28286.0; 070 28046.8; 071 27805.7; 074 26112.1
note: mono sound constants are fixed exactly by the two groups' means (Ssnd 2: 066 067 068 069 070 071, Ssnd 3: 074); 074's residual is 0 by construction; valid for the fitted pairs only (mono at 25, 16.67, 15.2588 fps); elsewhere allow about 0.5 percent

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

## Sound term (diagnostic; the gate is unchanged)

- stereo sound constants rest on 3 groups for two constants, 1 degree(s) of freedom (Ssnd 3: 060 061 062 063, Ssnd 4: 064 065, Ssnd 5: 072); valid for the fitted pairs only (stereo at 25, 16.67, 12.5 fps); elsewhere allow about 0.5 percent
- mono sound constants are fixed exactly by the two groups' means (Ssnd 2: 066 067 068 069 070 071, Ssnd 3: 074); 074's residual is 0 by construction; valid for the fitted pairs only (mono at 25, 16.67, 15.2588 fps); elsewhere allow about 0.5 percent
- pad-aware fit y = A + S x Ssnd + d x real bytes, on the gate fit's points:
  - mono: A 2125.2, S 20366.4, d -19.26 T a sound byte (a pad byte costs 19.26 T more than a sound byte); residuals -369 -3 +469 -96 -159 +159 +0 T
  - stereo, all three free: A 133014.5, S -111282.4, d 192.02 (condition number 3518223: the clips' sound bytes, 1250, 1874, 2500, track Ssnd)
  - stereo with d = mono d x armed ratio = -19.52: A 920.0, S 20877.2; residuals -532 +170 +471 -239 +46 +214 -130 T
  - code: vid_ds_pad .d (video.asm:3306) discards a pad byte in 37 T (in 11, dec hl 6, ld a,h 4, or l 4, jr nz 12); vid_ds_xfer (video.asm:3328) moves a sound byte by ini, 16 T plus 14 T a 32-byte pass, about 16.4 T: about 20.6 T more a pad byte, unarmed
- mono RAW_FRAME_T -552.06 T and mono RAW_SND_SECTOR_T 14684.47 T (1.69 x stereo's 8684.76 T) come from one term a sector fitted to costs that follow sound against pad bytes: they are not physical costs.

gate sound term (Ssnd x tsnd + tf) against the pad-aware fit for other sound layouts (mono: its fit; stereo: d scaled); err = gate - fit, negative = the gate under-prices:

| form | fps | sound B | Ssnd | pad B | gate T | fit T | err T | err % of period | fitted pair |
|---|---|---|---|---|---|---|---|---|---|
| mono | 30 | 521 | 2 | 503 | 28817 | 32823 | -4006 | -0.43 | no |
| mono | 25 | 625 | 2 | 399 | 28817 | 30820 | -2003 | -0.18 | yes |
| mono | 20 | 781 | 2 | 243 | 28817 | 27815 | +1002 | +0.07 | no |
| mono | 16.67 | 937 | 2 | 87 | 28817 | 24811 | +4006 | +0.24 | yes |
| mono | 15.2588 | 1024 | 3 | 512 | 43501 | 43501 | -0 | -0.00 | yes |
| mono | 12.5 | 1250 | 3 | 286 | 43501 | 39148 | +4353 | +0.19 | no |
| mono | 10.5 | 1488 | 3 | 48 | 43501 | 34564 | +8937 | +0.34 | no |
| stereo | 30 | 1042 | 3 | 494 | 39161 | 43217 | -4056 | -0.43 | no |
| stereo | 25 | 1250 | 3 | 286 | 39161 | 39158 | +3 | +0.00 | yes |
| stereo | 20 | 1562 | 4 | 486 | 47845 | 53946 | -6101 | -0.44 | no |
| stereo | 16.67 | 1874 | 4 | 174 | 47845 | 47857 | -12 | -0.00 | yes |
| stereo | 15.2588 | 2048 | 5 | 512 | 56530 | 65339 | -8809 | -0.48 | no |
| stereo | 12.5 | 2500 | 5 | 60 | 56530 | 56518 | +12 | +0.00 | yes |
| stereo | 10.5 | 2976 | 6 | 96 | 65215 | 68106 | -2891 | -0.11 | no |

largest |err| outside the fitted pairs: 0.48 percent of the period

## Utilisation of the target shapes

period = samples a frame x 1792 T: vid_run releases a frame when the CTC reader has consumed the previous frame's sound (vid_pace_poll at .pace, video.asm:2352; the deficit clamp at .paced, video.asm:2374), not on fields. Worst frame (palette sector) + glue 1138.7 T (glue_t / audio_factor); F = 1.0. The last column is the two-field period 28363200 / fps, for reference only.

| shape | form | Spix | Ssnd | C | model T | period T | util | util with stall | util, pixels-only frame | ref: util at two fields |
|---|---|---|---|---|---|---|---|---|---|---|
| 256x192@25 | stereo | 96 | 3 | 0 | 941314 | 1120000 | 0.8415 | 0.8415 | 0.8161 | 0.8307 |
| 256x192@25 | mono | 96 | 2 | 0 | 918807 | 1120000 | 0.8214 | 0.8214 | 0.7968 | 0.8109 |
| 320x160@25 | stereo | 100 | 3 | 320 | 991151 | 1120000 | 0.8860 | 0.8860 | 0.8606 | 0.8746 |
| 320x160@25 | mono | 100 | 2 | 320 | 967851 | 1120000 | 0.8652 | 0.8652 | 0.8406 | 0.8541 |
| 320x192@25 | stereo | 120 | 3 | 320 | 1173168 | 1120000 | 1.0485 | 1.0485 | 1.0231 | 1.0351 |
| 320x192@25 | mono | 120 | 2 | 320 | 1147531 | 1120000 | 1.0256 | 1.0256 | 1.0010 | 1.0125 |
| 280x224@25 | stereo | 123 | 3 | 280 | 1198791 | 1120000 | 1.0714 | 1.0714 | 1.0459 | 1.0576 |
| 280x224@25 | mono | 123 | 2 | 280 | 1172844 | 1120000 | 1.0482 | 1.0482 | 1.0236 | 1.0348 |
| 320x240@16.67 | stereo | 150 | 4 | 320 | 1454878 | 1679104 | 0.8671 | 0.8672 | 0.8502 | 0.8557 |
| 320x240@16.67 | mono | 150 | 2 | 320 | 1417050 | 1679104 | 0.8446 | 0.8446 | 0.8282 | 0.8335 |
| 256x240@16.67 | stereo | 120 | 4 | 256 | 1179166 | 1679104 | 0.7029 | 0.7030 | 0.6860 | 0.6937 |
| 256x240@16.67 | mono | 120 | 2 | 256 | 1144909 | 1679104 | 0.6825 | 0.6826 | 0.6661 | 0.6736 |

stereo over 1.00: 320x192@25, 320x192@25 (with stall), 280x224@25, 280x224@25 (with stall)
stereo within 10 percent of the limit (0.90 < util <= 1.00): none
mono over 1.00: 320x192@25, 320x192@25 (with stall), 280x224@25, 280x224@25 (with stall)
mono within 10 percent of the limit (0.90 < util <= 1.00): none

## Largest admitted height at 25 fps

Heights 256 down to 1, util <= 1.00 at the sound period, glue added, F = 1.0.

| width | form | palette frame: height | util | pixels-only frame: height | util |
|---|---|---|---|---|---|
| 320 | stereo | 182 | 0.9997 | 187 | 0.9987 |
| 320 | mono | 185 | 0.9935 | 190 | 0.9930 |
| 280 | stereo | 208 | 0.9982 | 213 | 0.9972 |
| 280 | mono | 212 | 0.9920 | 219 | 0.9996 |
| 256 | stereo | 228 | 0.9973 | 234 | 0.9963 |
| 256 | mono | 234 | 0.9992 | 240 | 0.9987 |

## Budget of a 320x192@25 frame

Period 1120000 T (625 samples x 1792 T). Palette frame, F = 1.0.

| term | stereo T | stereo % | mono T | mono % |
|---|---|---|---|---|
| pixel bytes, Spix x 512 x tb | 1057990 | 94.46 | 1043967 | 93.21 |
|   of which the sound handler: (byte T / 1792) interrupts x handler T | 73254 | 6.54 | 59455 | 5.31 |
| per-sector overhead, Spix x ts | 34110 | 3.05 | 34110 | 3.05 |
| column ends, C x tc | 13433 | 1.20 | 13108 | 1.17 |
| sound sectors, Ssnd x tsnd | 26054 | 2.33 | 29369 | 2.62 |
| frame remainder, tf | 13106 | 1.17 | -552 | -0.05 |
| palette sector, tp | 28473 | 2.54 | 27528 | 2.46 |
| glue | 1139 | 0.10 | 1139 | 0.10 |
| total | 1174306 | 104.85 | 1148670 | 102.56 |

- stereo handler: one interrupt a sample, 625 a frame, 124.08 T each = 77547 T a frame (6.92 percent of the period, all terms together)
- mono handler: one interrupt a sample, 625 a frame, 102.06 T each = 63785 T a frame (5.70 percent of the period, all terms together)
- 1.0 percent of a 25 fps period is 11200 T a frame.

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

## Playback (leg B)

### Step 6: the model's verdict against LATE and URUN

model: the gate (Release instructions, palette frame, stall term) at the sound period; admitted = util <= 1.00. On time = LATE 0000 and URUN 0000.

| step | clip | shape | form | util | model | LATE | URUN | on time |
|---|---|---|---|---|---|---|---|---|
| B.4 | 060 | 256x192@25 | stereo | 0.8415 | admitted | 0000 | 0000 | yes |
| B.5 | 061 | 320x160@25 | stereo | 0.8860 | admitted | 0000 | 0000 | yes |
| B.6 | 062 | 320x192@25 | stereo | 1.0485 | refused | 00F9 | 00F9 | no |
| B.7 | 063 | 280x224@25 | stereo | 1.0714 | refused | 00F9 | 00F9 | no |
| B.8 | 064 | 320x240@16.67 | stereo | 0.8672 | admitted | 0000 | 0000 | yes |
| B.9 | 065 | 256x240@16.67 | stereo | 0.7030 | admitted | 0000 | 0000 | yes |
| B.10 | 066 | 256x192@25 | mono | 0.8214 | admitted | 0000 | 0000 | yes |
| B.11 | 067 | 320x160@25 | mono | 0.8652 | admitted | 0000 | 0000 | yes |
| B.12 | 068 | 320x192@25 | mono | 1.0256 | refused | 00F9 | 00F9 | no |
| B.13 | 069 | 280x224@25 | mono | 1.0482 | refused | 00F9 | 00F9 | no |
| B.14 | 070 | 320x240@16.67 | mono | 0.8446 | admitted | 0000 | 0000 | yes |
| B.15 | 071 | 256x240@16.67 | mono | 0.6826 | admitted | 0000 | 0000 | yes |
| B.16 | 072 | 320x256@12.5 | stereo | 0.6885 | admitted | 0000 | 0000 | yes |
| B.17 | 073 | 256x192@25 | stereo | 0.8415 | admitted | 0000 | 0000 | yes |
| B.19 | 075 | 256x192@25 | stereo | 0.8415 | admitted | 0000 | 0000 | yes |
| B.20 | 076 | 256x192@25 | mono | 0.8214 | admitted | 0000 | 0000 | yes |
| B.21 | 077 | 256x192@25 | stereo | 0.8415 | admitted | 0000 | 0000 | yes |
| B.22 | 078 | 256x192@25 | mono | 0.8214 | admitted | 0000 | 0000 | yes |
| B.23 | 060 | 256x192@25 | stereo | 0.8415 | admitted | 0000 | 0000 | yes |
| B.24 | 063 | 280x224@25 | stereo | 1.0714 | refused | 00F9 | 00F9 | no |
| B.25 | 079 | 320x256@25 | stereo | 1.3616 | refused | 00F9 | 00F9 | no |
| B.26 | 062 | 320x192@25 | stereo | 1.0485 | refused | 00F9 | 00F9 | no |

admitted clips that showed LATE or URUN: none
refused clips that played on time: none
fixture clips with no readout row: 074
readout rows outside the raw model: 004, 010

### Late clips: waits for ring room

A frame is released when the CTC reader has consumed the previous frame's sound (vid_pace_poll at .pace, video.asm:2352); .paced (video.asm:2374) adds one frame's bytes and drops a deficit of a whole frame. The reader never stops: when the frame loop runs late it plays on into stale ring bytes and passes the writer. vid_aud_pump's room test (video.asm:1882: room = ring - guard - (writer - reader) mod ring, with a 256-byte floor) then sees a nearly full ring, so .qnext (video.asm:2445) leaves the next frame's sound unwritten and .ffin (video.asm:2394) waits until the reader has freed room for it, up to one frame period. So a late clip is slowed by more than its utilisation. The bench rows never see this: nxb_aud_body.ptr (video.asm:4773) puts the writer half a ring ahead of the reader on every rep. ring_play runs the loop with the frame work below and counts the waits.

Frame work = the gate's pixels-only frame + glue + plain DEBUG work (leg B runs the DEBUG build; IFNDEF NXB_QUIET code the bench image does not carry), on a late frame's path, base T x the armed factor 1 / (1 - handler / 1792) (stereo 1.0744, mono 1.0604). Frame 0 adds the palette sector and its DEBUG sector work.
- per pixel sector 277.4 T: vr_sector_n's PLAY divider 86 T (.nocrc, video.asm:5145), vid_sd_tok_h's poll counter 177 T (.got, video.asm:3040), and vid_rl_poll (video.asm:795) 231 T once per 16 arms = 14.4 T
- per sound sector 231.4 T: vid_ds_blkopen's arm 40 T (video.asm:3224), the poll counter 177 T, 14.4 T of vid_rl_poll
- per frame: vid_play_frame 179 T (video.asm:845); the .pace poll's arm 40 + 14.4 T (vid_pace_poll, video.asm:1810); vid_dbg_late 174 T (video.asm:5300); vid_dbg_urun 402 T with its own vid_pace_poll through vid_raw_rd_hl (video.asm:5323) + 14.4 T; vid_aud_pump's .next arm 40 + 14.4 T a pass (video.asm:1846) x 2 + sound bytes / 8192 passes
- counted from the instructions (Zilog T, NEXTREG A,n read 13 T): every T figure above. Estimated: the 1-in-16 share of vid_rl_poll at each arm, and the pump passes a frame (one chunk, a second when the ring tail wraps, the final pass).

| step | clip | form | frames | DEBUG T a frame | util, pixels-only + DEBUG | PLAY | on-time PLAY | measured slowdown | predicted PLAY | waits | predicted slowdown | residual T a frame |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| B.4 | 060 | stereo | 250 | 30372 | 0.8432 | 494 | 493.6 | 1.0008 | 493.6 | 0 | 1.0000 | +914 |
| B.5 | 061 | stereo | 250 | 31565 | 0.8887 | 494 | 493.6 | 1.0008 | 493.6 | 0 | 1.0000 | +914 |
| B.6 | 062 | stereo | 250 | 37526 | 1.0566 | 527 | 493.6 | 1.0677 | 527.4 | 3 | 1.0685 | -897 |
| B.7 | 063 | stereo | 250 | 38420 | 1.0802 | 541 | 493.6 | 1.0960 | 540.6 | 4 | 1.0952 | +921 |
| B.8 | 064 | stereo | 167 | 46722 | 0.8780 | 495 | 494.3 | 1.0014 | 494.3 | 0 | 1.0000 | +2307 |
| B.9 | 065 | stereo | 167 | 37779 | 0.7085 | 495 | 494.3 | 1.0014 | 494.3 | 0 | 1.0000 | +2307 |
| B.10 | 066 | mono | 250 | 29727 | 0.8233 | 494 | 493.6 | 1.0008 | 493.6 | 0 | 1.0000 | +914 |
| B.11 | 067 | mono | 250 | 30904 | 0.8682 | 494 | 493.6 | 1.0008 | 493.6 | 0 | 1.0000 | +914 |
| B.12 | 068 | mono | 250 | 36787 | 1.0339 | 513 | 493.6 | 1.0393 | 512.3 | 1 | 1.0378 | +1654 |
| B.13 | 069 | mono | 250 | 37670 | 1.0573 | 527 | 493.6 | 1.0677 | 525.7 | 2 | 1.0650 | +2987 |
| B.14 | 070 | mono | 167 | 45615 | 0.8554 | 495 | 494.3 | 1.0014 | 494.3 | 0 | 1.0000 | +2307 |
| B.15 | 071 | mono | 167 | 36790 | 0.6881 | 495 | 494.3 | 1.0014 | 494.3 | 0 | 1.0000 | +2307 |
| B.16 | 072 | stereo | 125 | 49955 | 0.6981 | 494 | 493.6 | 1.0008 | 493.6 | 0 | 1.0000 | +1827 |
| B.17 | 073 | stereo | 250 | 30372 | 0.8432 | 494 | 493.6 | 1.0008 | 493.6 | 0 | 1.0000 | +914 |
| B.19 | 075 | stereo | 249 | 30372 | 0.8432 | 492 | 491.6 | 1.0008 | 491.6 | 0 | 1.0000 | +859 |
| B.20 | 076 | mono | 249 | 29727 | 0.8233 | 492 | 491.6 | 1.0008 | 491.6 | 0 | 1.0000 | +859 |
| B.21 | 077 | stereo | 200 | 30372 | 0.8432 | 395 | 394.9 | 1.0003 | 394.9 | 0 | 1.0000 | +346 |
| B.22 | 078 | mono | 200 | 29727 | 0.8233 | 395 | 394.9 | 1.0003 | 394.9 | 0 | 1.0000 | +346 |
| B.23 | 060 | stereo | 250 | 30372 | 0.8432 | 494 | 493.6 | 1.0008 | 493.6 | 0 | 1.0000 | +914 |
| B.24 | 063 | stereo | 250 | 38420 | 1.0802 | 541 | 493.6 | 1.0960 | 540.6 | 4 | 1.0952 | +921 |
| B.25 | 079 | stereo | 250 | 49449 | 1.3803 | 710 | 493.6 | 1.4384 | 709.4 | 17 | 1.4372 | +1399 |
| B.26 | 062 | stereo | 250 | 37526 | 1.0566 | 527 | 493.6 | 1.0677 | 527.4 | 3 | 1.0685 | -897 |

PLAY counts whole fields of 567264 T: its resolution is 2269 T a frame over 250 frames, 3397 over 167, 4538 over 125.
