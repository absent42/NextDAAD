# Raw direct video - KS3 sitting 1b (2026-11-23)

Sitting: KS3, the 2026-11-21 sitting's board (core 3.03.03 read then; the core was not read at this sitting). Legs staged from 2b75eed (interpreter source 95cd894). Leg A: -BenchQuiet build, log NXBENCH.TXT in this folder, 17 captures (NXBW on 060-072, 074, 088, 089; NXBD on 010). Leg B: DEBUG build; part 1 (B.3 to B.19) replays sitting 1's order with GOX (no log) and ends with B.19's logged GO of 074; part 2, after a power cycle, logs every GO and LOOP. NXPLAY.TXT in this folder holds 31 captures (capture 1 is B.19, captures 2-31 part 2; table in playback.md). Details and the owner's notes in sitting.txt.

Produced by:

- `python tests\core303\playlog.py NXPLAY.TXT --out playback.md` (exit 0)
- `python tests\raw_fit.py NXBENCH.TXT --clips <leg A folder> --playback playback.md` (exit 0: residuals, sound-term rule, no RE-RUN row). The fit reads only NXBENCH.TXT; the clip files are read to check their headers and frame tags; playback.md supplies the leg B readouts. Its output is the second half of this file, unedited.

The control, projection, attribution, capture and CHK tables in the first half are computed from the two sittings' logs (this folder and 2026-11-21-ks3-legRAW1), raw_fit's fit of each, the clip files and the instruction counts named beside them.

## Summary

- Control: PASS. NXBD on 010 against sitting 1, row by row: largest difference 0.158 percent (DTI0, one raster line); limit 0.5 percent.
- Acceptance: PASS. Largest |residual| 0.081 percent (clip 068); 16 clips, 8 a form (stereo 060-065, 072, 089; mono 066-071, 074, 088).
- Sound-term rule: PASS. Pad-aware d = +2.45 T a sound byte (mono) and +1.21 (stereo, now determined: 089 holds 1562 sound bytes in 4 sectors against 064/065's 1874); every listed layout's gate minus fit is within 0.055 percent of the period (limit 0.15). The plan expected d near +1.7. One term a sound sector holds.
- Anomalies for a RE-RUN request: none.
- Utilisation of the six target shapes (sound period, glue added, no stall term; RAW_STALL_T 23.49 T moves only 320x160@25 mono palette, to 0.8266), palette frame / pixels-only frame:

  | shape | stereo | mono |
  |---|---|---|
  | 256x192@25 | 0.8033 / 0.7916 | 0.7836 / 0.7724 |
  | 320x160@25 | 0.8467 / 0.8350 | 0.8265 / 0.8153 |
  | 320x192@25 | 1.0055 / 0.9938 | 0.9832 / 0.9720 |
  | 280x224@25 | 1.0278 / 1.0161 | 1.0053 / 0.9941 |
  | 320x240@16.67 | 0.8361 / 0.8283 | 0.8126 / 0.8051 |
  | 256x240@16.67 | 0.6757 / 0.6679 | 0.6543 / 0.6468 |

  - Over 1.00 on a palette frame: stereo 320x192@25 and 280x224@25; mono 280x224@25.
  - Over 1.00 on a pixels-only frame: stereo 280x224@25 only.
  - Within 10 percent of the limit (0.90 < util <= 1.00): mono 320x192@25 (palette frame).
  - Every figure is within 0.0031 of the plan's projection ("Utilisation against the projection").
- Largest admitted height at 25 fps, palette frame (pixels-only frame): 320 wide stereo 190 (192), mono 195 (196); 280 wide stereo 217 (219), mono 223 (224); 256 wide stereo 238 (242), mono 244 (246). Sitting 1: 182 (187), 185 (190); 208 (213), 212 (219); 228 (234), 234 (240).
- The trims did what was counted. Sitting 1's ARSW' less the counted unarmed savings of O3, O5, O6 and O7, with O4 through the measured handlers, predicts every clip's ARSW' within 0.013 percent. ts 284.25 to 134.62 T (counted 133); handlers 124.08 / 102.06 to 114.29 / 92.14 T an interrupt (counted 114.23 / 92.11); tp 28,473 / 27,528 to 13,093 / 12,531 T (counted 12,890 / 12,722 armed).
- First poll at 18 T: every token wait in RHST, RH39, AHST and AH39 is in bin 1 (exactly one $FF poll) on all 16 clips, at 18 T after CRC 2 and at the prototype's 39 T alike; RH39 - RHST measures 20.99 T a rep (counted 21). VR_POLL_PAD_N = 1 costs nothing measurable; no alternative is indicated.
- Leg B (DEBUG build) against the model: every clip the gate admits played with LATE 0000 and URUN 0000; no clip it refuses played on time. 062, 063 and 069 (DEBUG utilisation 1.0068, 1.0295, 1.0070) were late on 249 of 250 frames, as the plan projected (1.0067, 1.0293, 1.0048); 068 (0.9847, projected 0.9826) played on time, where it was late at sitting 1. The ring-wait model's PLAY against the log: 062 498.9 / 499, 063 512.0 / 512, 069 499.1 / 499, 063 LOOP 2379.5 / 2380, 062 to SPACE 157.0 / 157.
- 074 played every time in 1b: B.17 (GOX, the 15th session, as at sitting 1) "played all way through"; B.19, B.36 and B.37 logged FRM 0099/0099, PLAY 01EF (on time 494.9 fields), LATE and URUN 0000, pool 50. The sitting-1 failure (seven tries, no picture) did not recur; its cause is not established.
- 004 logged RUNS=00 on both captures (pool 50), on time. Sitting 1's hand copy read RUNS=01. See "004".
- CHK: on every clip without bars (the 256 surface, and 072 at 320x256) CHK equals the sum of the clip file's last two frames' pixels, in both sittings. On the barred 320-surface clips CHK also sums bar bytes no code writes; 1b's is 1417 above sitting 1's on 064, 065, 067, 068, 069, 070 and 071 (899 on 061) because those bytes held different content from power-on. Not a player defect. See "CHK".

## Control: NXBD on 010 against sitting 1

T a rep = (F x 311 + D) x 1824 / R, rows as printed (harness included).

| row | sitting 1 O R F D | lines | T/rep | sitting 1b O R F D | lines | T/rep | diff % |
|---|---|---|---|---|---|---|---|
| IDEN | 02 250 256 167 | | | 02 250 256 167 | | | equal |
| DSWP | 10 1 24 -19 | 7445 | 13579680.00 | 10 1 24 -20 | 7444 | 13577856.00 | -0.013 |
| ADSW | 10 1 27 -145 | 8252 | 15051648.00 | 10 1 27 -144 | 8253 | 15053472.00 | +0.012 |
| DTI0 | 00 128 2 10 | 632 | 9006.00 | 00 128 2 9 | 631 | 8991.75 | -0.158 |
| DTB0 | 00 128 4 127 | 1371 | 19536.75 | 00 128 4 126 | 1370 | 19522.50 | -0.073 |
| DTC0 | 00 128 2 59 | 681 | 9704.25 | 00 128 2 59 | 681 | 9704.25 | +0.000 |
| DTD0 | 00 128 2 123 | 745 | 10616.25 | 00 128 2 123 | 745 | 10616.25 | +0.000 |
| ADTI | 00 128 2 78 | 700 | 9975.00 | 00 128 2 78 | 700 | 9975.00 | +0.000 |
| ADTC | 00 128 2 133 | 755 | 10758.75 | 00 128 2 133 | 755 | 10758.75 | +0.000 |

Largest |difference| 0.158 percent: PASS. Every row is within one raster line of sitting 1; the board, card and clock are taken as unchanged.

## Sound term

1. Each form now has two sound-byte counts inside one Ssnd group (mono Ssnd 2: 625 and 937 B; Ssnd 3: 1024 and 1250 B. Stereo Ssnd 4: 1874 and 1562 B), so the pad-aware fit fixes d in both forms on the measured points.
2. d = +2.45 (mono) and +1.21 (stereo) T a sound byte: a sound byte costs slightly more than a pad byte. The code agrees in sign and size: vid_raw_apad reads the pad and tag through the INI slide at 16 T a byte; vid_ds_xfer moves a sound byte at about 17.6 T in 256-byte arms (16 T ini, 14 T a 32-byte pass, about 300 T an arm). Sitting 1's d was -19.26, from vid_ds_pad's 37 T discard loop, which O3 replaced on the raw path.
3. Gate minus pad-aware fit over 256x192 at 30, 25, 20, 16.67, 15.26, 12.5 and 10.5 fps: largest 0.055 percent of the period (mono 30 fps), 0.024 percent in stereo.
4. The fitted constants hold without sitting 1's mono artefacts: mono tf +1,304 T (was -552), mono tsnd 0.92 x stereo's (was 1.69). Stereo tf is now -1,019 T: one term a sector over sound bytes that cost 1.2 T more than pad bytes puts part of the byte cost in the slope; the rule above bounds what that costs at any listed layout.
5. Fitted pairs: stereo at 25, 20, 16.67 and 12.5 fps; mono at 25, 16.67, 15.26 and 12.5 fps.

## Utilisation against the projection

Sitting 1 and 1b from raw_fit's fits; the projection is the plan's (sitting 1's model less the counted unarmed savings, times the armed factor after O4). Palette frame / pixels-only frame.

| shape | form | sitting 1 | projected | sitting 1b | 1b - projected |
|---|---|---|---|---|---|
| 256x192@25 | stereo | 0.8415 / 0.8161 | 0.8040 / 0.7915 | 0.8033 / 0.7916 | -0.0007 / +0.0001 |
| 256x192@25 | mono | 0.8214 / 0.7968 | 0.7822 / 0.7705 | 0.7836 / 0.7724 | +0.0014 / +0.0019 |
| 320x160@25 | stereo | 0.8860 / 0.8606 | 0.8474 / 0.8350 | 0.8467 / 0.8350 | -0.0007 / +0.0000 |
| 320x160@25 | mono | 0.8652 / 0.8406 | 0.8250 / 0.8132 | 0.8265 / 0.8153 | +0.0015 / +0.0021 |
| 320x192@25 | stereo | 1.0485 / 1.0231 | 1.0061 / 0.9936 | 1.0055 / 0.9938 | -0.0006 / +0.0002 |
| 320x192@25 | mono | 1.0256 / 1.0010 | 0.9817 / 0.9699 | 0.9832 / 0.9720 | +0.0015 / +0.0021 |
| 280x224@25 | stereo | 1.0714 / 1.0459 | 1.0284 / 1.0160 | 1.0278 / 1.0161 | -0.0006 / +0.0001 |
| 280x224@25 | mono | 1.0482 / 1.0236 | 1.0037 / 0.9919 | 1.0053 / 0.9941 | +0.0016 / +0.0022 |
| 320x240@16.67 | stereo | 0.8671 / 0.8502 | 0.8365 / 0.8282 | 0.8361 / 0.8283 | -0.0004 / +0.0001 |
| 320x240@16.67 | mono | 0.8446 / 0.8282 | 0.8156 / 0.8078 | 0.8126 / 0.8051 | -0.0030 / -0.0027 |
| 256x240@16.67 | stereo | 0.7029 / 0.6860 | 0.6762 / 0.6679 | 0.6757 / 0.6679 | -0.0005 / -0.0000 |
| 256x240@16.67 | mono | 0.6825 / 0.6661 | 0.6574 / 0.6496 | 0.6543 / 0.6468 | -0.0031 / -0.0028 |

The mono differences follow the sound term: the projection started from sitting 1's mono constants, which the refit replaces.

## Attribution: measured against counted

Counts are base Zilog T from src/video.asm at 95cd894.

- Pixel sector open, one $FF poll (vr_sector_n, VR_ENT_FAST): `call` 17, CRC pair 26, VR_POLL_PAD 7, poll 1 (`in` 11, `inc a` 4, `jr nz` 7), poll 2 (`in` 11, `cp n` 7, `ret z` 11), the slide's call and exit 27: 128 T; sitting 1's rows ran 5 T over their counts (clock bracket), so RSEC' - 8192 is expected at about 133.
- Palette frame over a pixels-only frame: `call nz, vid_raw_pal` taken +7, `call vr_sector` 17, vr_sector's head 51, vr_sector_n 84, vid_raw_pal's choreography 123, VR_PALTRAIN 512 x 23 = 11,776, its `ret` 10: 12,068 T unarmed. The plan estimated about 14,000 T armed.
- RH39 / AH39 against RHST / AHST: nxb_rh_sec39 puts poll 1 39 T after CRC 2 against 18 T: 21 T a wait, unarmed.

| figure | sitting 1 | sitting 1b | change | counted |
|---|---|---|---|---|
| ts = RSEC' - 8192, unarmed (16 clips) | 284.25 | 134.62 | -149.62 | -151 (O5 -97, O6 -54); 128 + 5 = 133 |
| handler stereo, T an interrupt (ASPN - SPN0) | 124.08 | 114.29 | -9.79 | O4: 114.23 |
| handler mono, T an interrupt | 102.06 | 92.14 | -9.91 | O4: 92.11 |
| tp stereo, armed: (RFR0' - RSWP') x ARSW'/RSWP' | 28,473.2 | 13,093.0 | -15,380.2 | 12,068 x 1.0681 = 12,890 |
| tp mono, armed | 27,528.2 | 12,530.6 | -14,997.7 | 12,068 x 1.0542 = 12,722 |
| RH39 - RHST, T a rep (16 clips) | - | 20.99 | | 21 |
| AH39 - AHST, stereo / mono, T a rep | - | 22.49 / 22.04 | | 21 x 1.0681 / 1.0542 = 22.43 / 22.14 |
| RHST, T a rep (mean) | 8,700.52 | 8,580.39 | -120.12 | |

tp per clip (one RFR0 rep on the 1824 T line clock): stereo 060 14,129, 061 12,788, 062 12,787, 063 12,299, 064 13,032, 065 11,693, 072 14,251, 089 13,764; mono 066 12,501, 067 11,179, 068 13,101, 069 12,741, 070 11,899, 071 12,379, 074 12,502, 088 13,944. The means sit +203 (stereo) and -191 (mono) T from the count, inside the per-clip spread.

### ARSW' per clip: sitting 1 less the counted trims

U = unarmed counted saving a frame = Spix x 151 (O5 97 and O6 54 an open) - 7 (O5: vr_sector's `ld c,n`) - 80 (O6: the frame's run charge in vid_raw_frame) + (21n - 147) (O3: pad and tag 64 + 37n to 211 + 16n, n = pad plus tag bytes) + 117 + 50 x page ends (O7). Predicted = (ARSW'_1 / A_1 - U) x A_1b, with A = 1 / (1 - handler / 1792) from each sitting's ASPN: A_1 1.07439 / 1.06039, A_1b 1.06812 / 1.05421 (stereo / mono). Page ends: 9 at 320 and 280 wide, 7 at 256x240, 5 at 256x192.

| clip | form | Spix | n | page ends | ARSW' sitting 1 | U | predicted | measured | measured - predicted T | % |
|---|---|---|---|---|---|---|---|---|---|---|
| 060 | stereo | 96 | 286 | 5 | 913370.3 | 20635 | 886001.7 | 886011.6 | +10 | +0.001 |
| 061 | stereo | 100 | 286 | 9 | 962504.4 | 21439 | 933990.4 | 934005.7 | +15 | +0.002 |
| 062 | stereo | 120 | 286 | 9 | 1144220.3 | 24459 | 1111420.6 | 1111275.7 | -145 | -0.013 |
| 063 | stereo | 123 | 286 | 9 | 1170554.3 | 24912 | 1137117.2 | 1137039.7 | -77 | -0.007 |
| 064 | stereo | 150 | 174 | 9 | 1426370.3 | 26637 | 1389598.5 | 1389777.6 | +179 | +0.013 |
| 065 | stereo | 120 | 174 | 7 | 1150490.3 | 22007 | 1120273.1 | 1120395.6 | +123 | +0.011 |
| 066 | mono | 96 | 399 | 5 | 893651.3 | 23008 | 864185.2 | 864240.6 | +55 | +0.006 |
| 067 | mono | 100 | 399 | 9 | 942329.3 | 23812 | 911731.7 | 911778.6 | +47 | +0.005 |
| 068 | mono | 120 | 399 | 9 | 1121537.3 | 26832 | 1086711.1 | 1086654.6 | -56 | -0.005 |
| 069 | mono | 123 | 399 | 9 | 1147415.3 | 27285 | 1111960.6 | 1112076.6 | +116 | +0.010 |
| 070 | mono | 150 | 87 | 9 | 1385675.3 | 24810 | 1351440.4 | 1351362.6 | -78 | -0.006 |
| 071 | mono | 120 | 87 | 7 | 1113215.3 | 20180 | 1085450.2 | 1085400.6 | -50 | -0.005 |
| 072 | stereo | 160 | 60 | 9 | 1512782.3 | 25753 | 1476450.6 | 1476417.6 | -33 | -0.002 |
| 074 | mono | 96 | 512 | 5 | 905963.3 | 25381 | 873923.7 | 873930.6 | +7 | +0.001 |

Largest |measured - predicted| 0.013 percent (179 T a frame): every counted saving arrived on silicon. 088 and 089 have no sitting-1 row.

### 320x192@25 palette frame, model terms

| term | stereo 1 | stereo 1b | change | mono 1 | mono 1b | change |
|---|---|---|---|---|---|---|
| pixel bytes | 1057990 | 1050516 | -7475 | 1043967 | 1036762 | -7205 |
| per-sector | 34110 | 16155 | -17955 | 34110 | 16155 | -17955 |
| column ends | 13433 | 13109 | -324 | 13108 | 12967 | -141 |
| sound sectors | 26054 | 33118 | +7064 | 29369 | 20347 | -9022 |
| frame remainder | 13106 | -1019 | -14126 | -552 | 1304 | +1856 |
| palette | 28473 | 13093 | -15380 | 27528 | 12531 | -14998 |
| total incl. glue | 1174306 | 1126110 | -48196 | 1148670 | 1101205 | -47465 |

- Change of the model frame: stereo -4.30 percent of the period, mono -4.24. The plan's counted armed savings at this shape sum to 47,484 (stereo) and 49,220 (mono) T (-4.24 / -4.39 percent).
- The mono model's change is 1,755 T short of the counted sum while the per-clip ARSW' check above holds within 0.013 percent: sitting 1's mono model sat under its measurement at this shape (068 residual +0.137 percent) and the refit sits over it (068 -0.081 percent).
- The sound-sector and frame-remainder rows move together (stereo +7,064 / -14,126): the new points (089, 088) move the split between slope and intercept; their sum is the term to read (stereo -7,062, mono -7,166).

### First poll: 18 T against 39 T

| histogram | bin 1 (one $FF poll) | other bins |
|---|---|---|
| RHST (18 T), 16 clips | 32768 | 0 |
| RH39 (39 T), 16 clips | 32768 | 0 |
| AHST (18 T), stereo / mono | 16384 / 16384 | 0 |
| AH39 (39 T), stereo / mono | 16384 / 16384 | 0 |

Every wait at both spacings saw one $FF then the token, as sitting 1 saw at 48 T and the prototype at 39 T. Moving poll 1 to 18 T after CRC 2 did not add a poll. The per-rep difference of the 39 T rows (20.99 T unarmed against 21 counted) is the padding alone.

## Playback (leg B)

### Captures and sheet steps

Log order: capture 1 is B.19 (part 1), captures 2-31 part 2. Capture is the NXPLAY.TXT capture number (raw_fit's Step column below). LOOP is read from PASS above 01 and FRM above the clip's frames; the log header does not record the verb. On-time PLAY = frames x samples a frame x 1792 / 567,264 (fields); NOM is the two-field nominal. Gate util: Release instructions, palette frame, stall term, sound period.

| capture | step | clip | pool | row 23 | FRM | PASS | PLAY | on-time PLAY | NOM | LATE | MAXL | URUN | RUNS | gate util | model | owner's note |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | B.19 GO | 074 | 50 | - | 0099/0099 | 01 | 01EF | 494.9 | 01F3 | 0000 | 0000 | 0000 | 01 | 0.4838 | admitted | "played all way through" |
| 2 | B.21 GO | 004 | 50 | - | 002B/002B | 01 | 0055 | - | 0056 | 0000 | 0000 | 0000 | 00 | - | not modelled | |
| 3 | B.22 GO | 060 | 50 | - | 00FA/00FA | 01 | 01EE | 493.6 | 01F4 | 0000 | 0000 | 0000 | 01 | 0.8033 | admitted | |
| 4 | B.23 GO | 061 | 50 | - | 00FA/00FA | 01 | 01EE | 493.6 | 01F4 | 0000 | 0000 | 0000 | 01 | 0.8467 | admitted | |
| 5 | B.24 GO | 062 | 50 | - | 00FA/00FA | 01 | 01F3 | 493.6 | 01F4 | 00F9 | 0500 | 00F9 | 01 | 1.0055 | refused | "STUTTER" |
| 6 | B.25 GO | 063 | 50 | - | 00FA/00FA | 01 | 0200 | 493.6 | 01F4 | 00F9 | 06FE | 00F9 | 01 | 1.0278 | refused | "STUTTER" |
| 7 | B.26 GO | 064 | 50 | - | 00A7/00A7 | 01 | 01EF | 494.3 | 01F3 | 0000 | 0000 | 0000 | 01 | 0.8361 | admitted | |
| 8 | B.27 GO | 065 | 50 | - | 00A7/00A7 | 01 | 01EF | 494.3 | 01F3 | 0000 | 0000 | 0000 | 01 | 0.6757 | admitted | |
| 9 | B.28 GO | 066 | 50 | - | 00FA/00FA | 01 | 01EE | 493.6 | 01F4 | 0000 | 0000 | 0000 | 01 | 0.7836 | admitted | |
| 10 | not a sheet step | 057 | FF (no open) | VID FILE? | - | - | - | - | - | - | - | - | - | - | - | stated after the sitting: a mistyped PICK (57 for 67) before B.29 |
| 11 | B.29 GO | 067 | 50 | - | 00FA/00FA | 01 | 01EE | 493.6 | 01F4 | 0000 | 0000 | 0000 | 01 | 0.8266 | admitted | |
| 12 | B.30 GO | 068 | 50 | - | 00FA/00FA | 01 | 01EE | 493.6 | 01F4 | 0000 | 0000 | 0000 | 01 | 0.9832 | admitted | |
| 13 | B.31 GO | 069 | 50 | - | 00FA/00FA | 01 | 01F3 | 493.6 | 01F4 | 00F9 | 028A | 00F9 | 01 | 1.0053 | refused | "STUTTER" |
| 14 | B.32 GO | 070 | 50 | - | 00A7/00A7 | 01 | 01EF | 494.3 | 01F3 | 0000 | 0000 | 0000 | 01 | 0.8126 | admitted | |
| 15 | B.33 GO | 071 | 50 | - | 00A7/00A7 | 01 | 01EF | 494.3 | 01F3 | 0000 | 0000 | 0000 | 01 | 0.6543 | admitted | |
| 16 | B.34 GO | 072 | 50 | - | 007D/007D | 01 | 01EE | 493.6 | 01F4 | 0000 | 0000 | 0000 | 01 | 0.6655 | admitted | |
| 17 | B.35 GO | 073 | 50 | - | 00FA/00FA | 01 | 01EE | 493.6 | 01F4 | 0000 | 0000 | 0000 | 01 | 0.8033 | admitted | |
| 18 | B.36 GO | 074 | 50 | - | 0099/0099 | 01 | 01EF | 494.9 | 01F3 | 0000 | 0000 | 0000 | 01 | 0.4838 | admitted | |
| 19 | B.37 GO | 074 | 50 | - | 0099/0099 | 01 | 01EF | 494.9 | 01F3 | 0000 | 0000 | 0000 | 01 | 0.4838 | admitted | |
| 20 | B.38 GO | 075 | 50 | - | 00F9/00F9 | 01 | 01EC | 491.6 | 01F2 | 0000 | 0000 | 0000 | 01 | 0.8033 | admitted | |
| 21 | B.39 GO | 076 | 50 | - | 00F9/00F9 | 01 | 01EC | 491.6 | 01F2 | 0000 | 0000 | 0000 | 01 | 0.7836 | admitted | |
| 22 | B.40 GO | 077 | 50 | - | 00C8/00C8 | 01 | 018B | 394.9 | 0190 | 0000 | 0000 | 0000 | 01 | 0.8033 | admitted | |
| 23 | B.41 GO | 078 | 50 | - | 00C8/00C8 | 01 | 018B | 394.9 | 0190 | 0000 | 0000 | 0000 | 01 | 0.7836 | admitted | |
| 24 | B.42 GO | 088 | 50 | - | 00FA/00FA | 01 | 03DB | 987.2 | 03E8 | 0000 | 0000 | 0000 | 01 | 0.3964 | admitted | |
| 25 | B.43 GO | 089 | 50 | - | 00C8/00C8 | 01 | 01EE | 493.4 | 01F4 | 0000 | 0000 | 0000 | 01 | 0.6507 | admitted | |
| 26 | B.44 GO | 010 | 50 | - | 00FA/00FA | 01 | 01EE | - | 01F4 | 0000 | 0000 | 0000 | 01 | - | not modelled | |
| 27 | B.45 GO | 080 | 50 | VID FMT? | - | - | - | - | - | - | - | - | - | - | refusal clip | |
| 28 | B.46 LOOP, SPACE | 060 | 50 | - | 0315/0315 | 04 | 0616 | 1557.8 | 062A | 0000 | 0000 | 0000 | 01 | 0.8033 | admitted | |
| 29 | B.47 LOOP, SPACE | 063 | 50 | - | 048C/048C | 05 | 094C | 2298.2 | 0918 | 048B | 071A | 048C | 01 | 1.0278 | refused | "LOOPED BUT STUTTER (NOT AT LOOP POINT)" |
| 30 | B.48 GO, SPACE | 062 | 50 | - | 004E/004E | 01 | 009D | 154.0 | 009C | 004D | 0500 | 004E | 01 | 1.0055 | refused | |
| 31 | B.49 GO | 004 | 50 | - | 002B/002B | 01 | 0055 | - | 0056 | 0000 | 0000 | 0000 | 00 | - | not modelled | |

- Every capture with a report reads ERR=00 OP=00 POS=000000, RING=0000/0000/00, SNAP=00 (playback.md).
- B.46 stopped 789 frames in (3 restarts, then 39 frames: banner about 00:00:01); B.47 stopped 1164 frames in (4 restarts, then 164 frames: about 00:00:06). The sheet asked for SPACE at 00:00:05 after three restarts. Both ended with a report and no exception noted.
- B.48 stopped 78 frames in (3.1 s; the sheet asked for 00:00:03).
- The owner wrote STUTTER at B.24, B.25, B.31 and B.47: the logged plays of 062, 063 and 069, each late on every frame but one (LATE 00F9 of 00FA frames; B.47 048B of 048C). Part 1 played the same clips at B.5, B.6 and B.12 with no note. The sheet said stutters were expected at all seven steps and asked for exceptions only.

### Late clips: model against the log

DEBUG utilisation, ring-wait prediction and waits from raw_fit's "Late clips" table (captures 5, 6, 13, 29, 30); 068 for comparison.

| clip | form | DEBUG util (pixels-only + DEBUG) | plan projection | PLAY 1b | predicted | waits | PLAY sitting 1 |
|---|---|---|---|---|---|---|---|
| 062 | stereo | 1.0068 | 1.0067 | 499 | 498.9 | 1 | 527 |
| 063 | stereo | 1.0295 | 1.0293 | 512 | 512.0 | 2 | 541 |
| 068 | mono | 0.9847 | 0.9826 | 494 (on time) | 493.6 | 0 | 513 |
| 069 | mono | 1.0070 | 1.0048 | 499 | 499.1 | 1 | 527 |
| 063 LOOP (1164 frames) | stereo | 1.0295 | | 2380 | 2379.5 | 7 | - |
| 062 to SPACE (78 frames) | stereo | 1.0068 | | 157 | 157.0 | 1 | - |

- The ring model treats a LOOP run as one 1164-frame clip: it does not price the palette sector and the rewind at each pass start.
- PLAY resolution is one field (2269 T a frame over 250 frames).
- These are DEBUG figures. In Release the gate puts 062 at 0.9938 and 069 at 0.9941 on a pixels-only frame (1.0055 and 1.0053 on a palette frame); no Release leg was run in this sitting.

### 074

- Leg A: NXBW on 074 normal (15 rows, four histograms, in the fit).
- Leg B part 1: B.17 (GOX, the 15th session after 060-073 with no log, as sitting 1's B.18) "played all way through"; B.18 not needed.
- Logged: B.19 (capture 1, the last step before the power cycle), B.36 and B.37 (captures 18, 19): each FRM 0099/0099, PASS 01, PLAY 01EF (495 fields; on time 494.9), NOM 01F3, LATE / MAXL / URUN 0000, RUNS 01, CHK 0050507E, pool 50 (80 free pool banks at the open).
- Sitting 1: seven tries at B.18, no picture, no rows recorded. Not reproduced in four plays here. A clean rerun does not establish the sitting-1 cause.

### 004

- Captures 2 (B.21) and 31 (B.49): FRM 002B/002B, PASS 01, FILL 001A, PLAY 0055 (85 fields) against NOM 0056, LATE / URUN 0000, RUNS 00, pool 50. CHK 006A8424 and 006748B5 (they differ).
- The report prints RUNS as 0 when the session was neither streamed nor direct (vidDeliverStrm and vidDeliverDir both zero), else the file's run count: RUNS=00 is the resident path, which the sitting-1 sheet expected.
- Sitting 1's B.28 was copied by hand as RUNS=01 (CHK 00302CC8). The code that prints RUNS is the same in both builds. The two sittings disagree; this log cannot say which delivery path sitting 1's play took.

### CHK

CHK (DEBUG) is the byte sum of both Layer 2 decode sets at teardown. Below, the clip file's last two frames' pixel sums against CHK: sitting 1 as copied by hand, 1b as logged.

| clip | shape | surface | last two frames' pixel sum | CHK sitting 1 | CHK 1b | sitting 1 - sum | 1b - sum |
|---|---|---|---|---|---|---|---|
| 060 | 256x192 | 256 | 5361721 | 5361721 | 5361721 | +0 | +0 |
| 066 | 256x192 | 256 | 5361721 | 5361721 | 5361721 | +0 | +0 |
| 073 | 256x192 | 256 | 1376354 | 1376354 | 1376354 | +0 | +0 |
| 074 | 256x192 | 256 | 5263486 | - | 5263486 | - | +0 |
| 075 | 256x192 | 256 | 1384867 | 1384867 | 1384867 | +0 | +0 |
| 076 | 256x192 | 256 | 1384867 | 1384867 | 1384867 | +0 | +0 |
| 077 | 256x192 | 256 | 4634019 | 4634019 | 4634019 | +0 | +0 |
| 078 | 256x192 | 256 | 4634019 | 4634019 | 4634019 | +0 | +0 |
| 088 | 256x192 | 256 | 5189169 | - | 5189169 | - | +0 |
| 089 | 256x192 | 256 | 5249018 | - | 5249018 | - | +0 |
| 072 | 320x256 | 320 | 7899155 | 7899155 | 7899155 | +0 | +0 |
| 061 | 320x160 | 320 | 5177836 | 9243924 | 9244823 | +4066088 | +4066987 |
| 067 | 320x160 | 320 | 5177836 | 8013865 | 8015282 | +2836029 | +2837446 |
| 068 | 320x192 | 320 | 6930523 | 9177827 | 9179244 | +2247304 | +2248721 |
| 069 | 280x224 | 320 | 6164280 | 8622736 | 8624153 | +2458456 | +2459873 |
| 064 | 320x240 | 320 | 7546345 | 8359790 | 8361207 | +813445 | +814862 |
| 070 | 320x240 | 320 | 7546345 | 8359790 | 8361207 | +813445 | +814862 |
| 065 | 256x240 | 320 | 5250016 | 7688733 | 7690150 | +2438717 | +2440134 |
| 071 | 256x240 | 320 | 5250016 | 7688733 | 7690150 | +2438717 | +2440134 |

- Without bars, CHK is exactly the last two frames' pixels in both sittings: the final surfaces are byte-exact on the 256 surface (five page ends a frame) and on 072 (320x256, nine page ends, every 320-surface page), on the build with O2-O7.
- With bars, CHK also sums bytes outside the picture. vid_chk_surface (the same in both builds) sums every byte of the surface pages of both sets, 6 or 10 8K pages a set by vidP_Shape, bars included; raw clips play in a centred Layer 2 clip window (the open's vidP_ClipX1/X2/Y1/Y2) and the player never clears the bars. So bar bytes hold earlier content: 064's excess is not a whole multiple of its 10,240 bar bytes, and same-shape 061 and 067 differ in one sitting.
- The 1b - sitting 1 offset: the 4096 bytes at surface rows 240-255, columns 192-319 of both sets (banks 12-13 and 33-34) are written by no clip before 072 and by no code in either build. On 064-071 CHK therefore includes whatever RAM held there since power-on, and both leg B sessions started from a power-on. CHK minus the modelled written bytes is one constant per sitting across 064, 065, 067, 068, 069, 070 and 071: 374,495 at sitting 1, 375,912 at 1b (difference 1417). 061 exposes rows 160-255 of those columns (+899). 062 and 063 differ from sitting 1 for the same reason, not because they were late. The residual is 0 on 060, 066 and 072.
- A harness run of the staged DEBUG image over seven geometries with random-filled surfaces changed no byte outside the clip window. Not a player defect and nothing visible: those rows are outside the clip window, and Layer 2 is hidden at teardown. Not established: whether that content is RAM power-up state or left by NextZXOS.
- 004 and 010 (other formats) also differ from sitting 1; they are not compared here.

## Leg A log notes

- The first capture (060) has no LOG OK line before its #HIST lines; every later capture has one. The log step captures the screen before it prints its own LOG OK / LOG ERR on row 31, so a capture's LOG line is the previous step's status, and the first step after launch has none. Sitting 1's first capture (060) has none either. The last step's (010) own status is not in the file; the owner reported no LOG ERR.
- Rows: 16 NXBW captures of 15 rows and four #HIST lines each, no NXB SHORT / RUN / GEO marker, no O=01 walk mark, every histogram sums to its row's reps, nothing in bin 9 or above; one NXBD capture of 9 rows.

## Anomalies and observations

RE-RUN request: none (no BAD, SHORT or missing row, no O=01, no row 3 percent from its peers, no histogram count in bin 9 or above).

Observations, not explained away:

1. 004 RUNS=00 (both captures) against sitting 1's hand-copied RUNS=01.
2. The owner noted stutters on the logged plays of 062, 063 and 069 only, not on part 1's plays of the same clips.
3. Stereo RAW_FRAME_T is negative (-1,019 T); the sound-term rule passes.

Explained:

- NXPLAY.TXT capture 10 ("#PLAY 057 FF 4B24", VID FILE?, no open ran) is not a sheet step: a mistyped PICK (57 for 67) before B.29, as the owner stated after the sitting. Not used.
- CHK on barred 320-surface clips (+1417 against sitting 1, +899 on 061): bar bytes no code writes, holding different content from power-on in the two sittings (see "CHK").

The rest of this file is the script's output, unedited.

raw_fit: NXBENCH.TXT
timing: +3, 311 lines x 1824 T a field (parse.timing); T = (F x 311 + D) x 1824
CTC 0 period: 16 x 112 = 1792 T (AUD_CTC_CW16 prescaler, vidCtcTcNxvStereo[NR $11 = 0])
harness: card h = 88 T a rep, frame g = 210 T a frame (nxv2_bench_rows)

## Sections

 1 #NXB 04D8 NXBW clip 060 stereo 256x192@25: 15 rows, 4 histograms
 2 #NXB 0915 NXBW clip 061 stereo 320x160@25: 15 rows, 4 histograms
 3 #NXB 0D96 NXBW clip 062 stereo 320x192@25: 15 rows, 4 histograms
 4 #NXB 10E5 NXBW clip 063 stereo 280x224@25: 15 rows, 4 histograms
 5 #NXB 1405 NXBW clip 064 stereo 320x240@16.67: 15 rows, 4 histograms
 6 #NXB 16E4 NXBW clip 065 stereo 256x240@16.67: 15 rows, 4 histograms
 7 #NXB 19F6 NXBW clip 066 mono 256x192@25: 15 rows, 4 histograms
 8 #NXB 1D12 NXBW clip 067 mono 320x160@25: 15 rows, 4 histograms
 9 #NXB 2036 NXBW clip 068 mono 320x192@25: 15 rows, 4 histograms
10 #NXB 2327 NXBW clip 069 mono 280x224@25: 15 rows, 4 histograms
11 #NXB 265E NXBW clip 070 mono 320x240@16.67: 15 rows, 4 histograms
12 #NXB 292D NXBW clip 071 mono 256x240@16.67: 15 rows, 4 histograms
13 #NXB 2C5B NXBW clip 072 stereo 320x256@12.5: 15 rows, 4 histograms
14 #NXB 2F46 NXBW clip 074 mono 256x192@15.2588: 15 rows, 4 histograms
15 #NXB 321E NXBW clip 088 mono 256x192@12.5: 15 rows, 4 histograms
16 #NXB 3505 NXBW clip 089 stereo 256x192@20: 15 rows, 4 histograms
17 #NXB 36FC NXBD clip 10: old direct rows (9)

## Decoded rows

T/rep = (F x 311 + D) x 1824 / R. Primed (harness removed): RSEC' = RSEC - h, RCOL' = RCOL - h, ARSE' = ARSE - h x ARSE/RSEC, ARCO' = ARCO - h x ARCO/RCOL, RSWP' = RSWP/16 - g, ARSW' = ARSW/16 - g x ARSW/RSWP, RFR0' = RFR0 - g.

clip 060 stereo 256x192@25: Spix 96, Ssnd 3, C 0 (section 1)

| tag | O | R | F | D | lines | T | T/rep | primed |
|---|---|---|---|---|---|---|---|---|
| IDEN | 02 | 250 | 256 | 192 | | | | |
| RFR0 | 00 | 1 | 1 | 151 | 462 | 842688 | 842688.00 | 842478.00 |
| RSWP | 00 | 16 | 24 | -188 | 7276 | 13271424 | 829464.00 | 829254.00 |
| ARSW | 00 | 16 | 25 | -1 | 7774 | 14179776 | 886236.00 | 886011.63 |
| RSEC | 00 | 128 | 2 | -31 | 591 | 1077984 | 8421.75 | 8333.75 |
| RCOL | 00 | 128 | 2 | -10 | 612 | 1116288 | 8721.00 | 8633.00 |
| RHST | 00 | 2048 | 31 | -7 | 9634 | 17572416 | 8580.28 | - |
| RH39 | 00 | 2048 | 31 | 16 | 9657 | 17614368 | 8600.77 | - |
| SPN0 | 00 | 512 | 47 | 17 | 14634 | 26692416 | 52133.62 | - |
| ARSE | 00 | 128 | 2 | 8 | 630 | 1149120 | 8977.50 | 8883.69 |
| ARCO | 00 | 128 | 2 | 31 | 653 | 1191072 | 9305.25 | 9211.35 |
| AHST | 00 | 2048 | 33 | 27 | 10290 | 18768960 | 9164.53 | - |
| AH39 | 00 | 2048 | 33 | 53 | 10316 | 18816384 | 9187.69 | - |
| ASPN | 00 | 512 | 50 | 81 | 15631 | 28510944 | 55685.44 | - |
| OSPN | 00 | 512 | 52 | 48 | 16220 | 29585280 | 57783.75 | - |

#HIST RHST: bin 1 = 2048

#HIST RH39: bin 1 = 2048

#HIST AHST: bin 1 = 2048

#HIST AH39: bin 1 = 2048

clip 061 stereo 320x160@25: Spix 100, Ssnd 3, C 320 (section 2)

| tag | O | R | F | D | lines | T | T/rep | primed |
|---|---|---|---|---|---|---|---|---|
| IDEN | 02 | 250 | 320 | 160 | | | | |
| RFR0 | 00 | 1 | 2 | -136 | 486 | 886464 | 886464.00 | 886254.00 |
| RSWP | 00 | 16 | 24 | 207 | 7671 | 13991904 | 874494.00 | 874284.00 |
| ARSW | 00 | 16 | 26 | 109 | 8195 | 14947680 | 934230.00 | 934005.66 |
| RSEC | 00 | 128 | 2 | -32 | 590 | 1076160 | 8407.50 | 8319.50 |
| RCOL | 00 | 128 | 2 | -10 | 612 | 1116288 | 8721.00 | 8633.00 |
| RHST | 00 | 2048 | 31 | -7 | 9634 | 17572416 | 8580.28 | - |
| RH39 | 00 | 2048 | 31 | 17 | 9658 | 17616192 | 8601.66 | - |
| SPN0 | 00 | 512 | 47 | 16 | 14633 | 26690592 | 52130.06 | - |
| ARSE | 00 | 128 | 2 | 8 | 630 | 1149120 | 8977.50 | 8883.53 |
| ARCO | 00 | 128 | 2 | 31 | 653 | 1191072 | 9305.25 | 9211.35 |
| AHST | 00 | 2048 | 33 | 27 | 10290 | 18768960 | 9164.53 | - |
| AH39 | 00 | 2048 | 33 | 52 | 10315 | 18814560 | 9186.80 | - |
| ASPN | 00 | 512 | 50 | 80 | 15630 | 28509120 | 55681.88 | - |
| OSPN | 00 | 512 | 52 | 48 | 16220 | 29585280 | 57783.75 | - |

#HIST RHST: bin 1 = 2048

#HIST RH39: bin 1 = 2048

#HIST AHST: bin 1 = 2048

#HIST AH39: bin 1 = 2048

clip 062 stereo 320x192@25: Spix 120, Ssnd 3, C 320 (section 3)

| tag | O | R | F | D | lines | T | T/rep | primed |
|---|---|---|---|---|---|---|---|---|
| IDEN | 02 | 250 | 320 | 192 | | | | |
| RFR0 | 00 | 1 | 1 | 266 | 577 | 1052448 | 1052448.00 | 1052238.00 |
| RSWP | 00 | 16 | 29 | 108 | 9127 | 16647648 | 1040478.00 | 1040268.00 |
| ARSW | 00 | 16 | 32 | -202 | 9750 | 17784000 | 1111500.00 | 1111275.67 |
| RSEC | 00 | 128 | 2 | -32 | 590 | 1076160 | 8407.50 | 8319.50 |
| RCOL | 00 | 128 | 2 | -10 | 612 | 1116288 | 8721.00 | 8633.00 |
| RHST | 00 | 2048 | 31 | -6 | 9635 | 17574240 | 8581.17 | - |
| RH39 | 00 | 2048 | 31 | 17 | 9658 | 17616192 | 8601.66 | - |
| SPN0 | 00 | 512 | 47 | 16 | 14633 | 26690592 | 52130.06 | - |
| ARSE | 00 | 128 | 2 | 8 | 630 | 1149120 | 8977.50 | 8883.53 |
| ARCO | 00 | 128 | 2 | 31 | 653 | 1191072 | 9305.25 | 9211.35 |
| AHST | 00 | 2048 | 33 | 27 | 10290 | 18768960 | 9164.53 | - |
| AH39 | 00 | 2048 | 33 | 53 | 10316 | 18816384 | 9187.69 | - |
| ASPN | 00 | 512 | 50 | 80 | 15630 | 28509120 | 55681.88 | - |
| OSPN | 00 | 512 | 52 | 48 | 16220 | 29585280 | 57783.75 | - |

#HIST RHST: bin 1 = 2048

#HIST RH39: bin 1 = 2048

#HIST AHST: bin 1 = 2048

#HIST AH39: bin 1 = 2048

clip 063 stereo 280x224@25: Spix 123, Ssnd 3, C 280 (section 4)

| tag | O | R | F | D | lines | T | T/rep | primed |
|---|---|---|---|---|---|---|---|---|
| IDEN | 02 | 250 | 280 | 224 | | | | |
| RFR0 | 00 | 1 | 1 | 279 | 590 | 1076160 | 1076160.00 | 1075950.00 |
| RSWP | 00 | 16 | 30 | 9 | 9339 | 17034336 | 1064646.00 | 1064436.00 |
| ARSW | 00 | 16 | 32 | 24 | 9976 | 18196224 | 1137264.00 | 1137039.68 |
| RSEC | 00 | 128 | 2 | -32 | 590 | 1076160 | 8407.50 | 8319.50 |
| RCOL | 00 | 128 | 2 | -10 | 612 | 1116288 | 8721.00 | 8633.00 |
| RHST | 00 | 2048 | 31 | -7 | 9634 | 17572416 | 8580.28 | - |
| RH39 | 00 | 2048 | 31 | 16 | 9657 | 17614368 | 8600.77 | - |
| SPN0 | 00 | 512 | 47 | 16 | 14633 | 26690592 | 52130.06 | - |
| ARSE | 00 | 128 | 2 | 8 | 630 | 1149120 | 8977.50 | 8883.53 |
| ARCO | 00 | 128 | 2 | 31 | 653 | 1191072 | 9305.25 | 9211.35 |
| AHST | 00 | 2048 | 33 | 28 | 10291 | 18770784 | 9165.42 | - |
| AH39 | 00 | 2048 | 33 | 53 | 10316 | 18816384 | 9187.69 | - |
| ASPN | 00 | 512 | 50 | 81 | 15631 | 28510944 | 55685.44 | - |
| OSPN | 00 | 512 | 52 | 48 | 16220 | 29585280 | 57783.75 | - |

#HIST RHST: bin 1 = 2048

#HIST RH39: bin 1 = 2048

#HIST AHST: bin 1 = 2048

#HIST AH39: bin 1 = 2048

clip 064 stereo 320x240@16.67: Spix 150, Ssnd 4, C 320 (section 5)

| tag | O | R | F | D | lines | T | T/rep | primed |
|---|---|---|---|---|---|---|---|---|
| IDEN | 02 | 167 | 320 | 240 | | | | |
| RFR0 | 00 | 1 | 2 | 98 | 720 | 1313280 | 1313280.00 | 1313070.00 |
| RSWP | 00 | 16 | 37 | -94 | 11413 | 20817312 | 1301082.00 | 1300872.00 |
| ARSW | 00 | 16 | 39 | 64 | 12193 | 22240032 | 1390002.00 | 1389777.65 |
| RSEC | 00 | 128 | 2 | -31 | 591 | 1077984 | 8421.75 | 8333.75 |
| RCOL | 00 | 128 | 2 | -10 | 612 | 1116288 | 8721.00 | 8633.00 |
| RHST | 00 | 2048 | 31 | -7 | 9634 | 17572416 | 8580.28 | - |
| RH39 | 00 | 2048 | 31 | 17 | 9658 | 17616192 | 8601.66 | - |
| SPN0 | 00 | 512 | 47 | 17 | 14634 | 26692416 | 52133.62 | - |
| ARSE | 00 | 128 | 2 | 9 | 631 | 1150944 | 8991.75 | 8897.79 |
| ARCO | 00 | 128 | 2 | 32 | 654 | 1192896 | 9319.50 | 9225.46 |
| AHST | 00 | 2048 | 33 | 27 | 10290 | 18768960 | 9164.53 | - |
| AH39 | 00 | 2048 | 33 | 52 | 10315 | 18814560 | 9186.80 | - |
| ASPN | 00 | 512 | 50 | 81 | 15631 | 28510944 | 55685.44 | - |
| OSPN | 00 | 512 | 52 | 48 | 16220 | 29585280 | 57783.75 | - |

#HIST RHST: bin 1 = 2048

#HIST RH39: bin 1 = 2048

#HIST AHST: bin 1 = 2048

#HIST AH39: bin 1 = 2048

clip 065 stereo 256x240@16.67: Spix 120, Ssnd 4, C 256 (section 6)

| tag | O | R | F | D | lines | T | T/rep | primed |
|---|---|---|---|---|---|---|---|---|
| IDEN | 02 | 167 | 256 | 240 | | | | |
| RFR0 | 00 | 1 | 2 | -41 | 581 | 1059744 | 1059744.00 | 1059534.00 |
| RSWP | 00 | 16 | 29 | 181 | 9200 | 16780800 | 1048800.00 | 1048590.00 |
| ARSW | 00 | 16 | 31 | 189 | 9830 | 17929920 | 1120620.00 | 1120395.62 |
| RSEC | 00 | 128 | 1 | 280 | 591 | 1077984 | 8421.75 | 8333.75 |
| RCOL | 00 | 128 | 2 | -10 | 612 | 1116288 | 8721.00 | 8633.00 |
| RHST | 00 | 2048 | 31 | -7 | 9634 | 17572416 | 8580.28 | - |
| RH39 | 00 | 2048 | 31 | 17 | 9658 | 17616192 | 8601.66 | - |
| SPN0 | 00 | 512 | 47 | 17 | 14634 | 26692416 | 52133.62 | - |
| ARSE | 00 | 128 | 2 | 9 | 631 | 1150944 | 8991.75 | 8897.79 |
| ARCO | 00 | 128 | 2 | 32 | 654 | 1192896 | 9319.50 | 9225.46 |
| AHST | 00 | 2048 | 33 | 27 | 10290 | 18768960 | 9164.53 | - |
| AH39 | 00 | 2048 | 33 | 52 | 10315 | 18814560 | 9186.80 | - |
| ASPN | 00 | 512 | 50 | 80 | 15630 | 28509120 | 55681.88 | - |
| OSPN | 00 | 512 | 52 | 48 | 16220 | 29585280 | 57783.75 | - |

#HIST RHST: bin 1 = 2048

#HIST RH39: bin 1 = 2048

#HIST AHST: bin 1 = 2048

#HIST AH39: bin 1 = 2048

clip 066 mono 256x192@25: Spix 96, Ssnd 2, C 0 (section 7)

| tag | O | R | F | D | lines | T | T/rep | primed |
|---|---|---|---|---|---|---|---|---|
| IDEN | 02 | 250 | 256 | 192 | | | | |
| RFR0 | 00 | 1 | 1 | 145 | 456 | 831744 | 831744.00 | 831534.00 |
| RSWP | 00 | 16 | 23 | 39 | 7192 | 13118208 | 819888.00 | 819678.00 |
| ARSW | 00 | 16 | 24 | 119 | 7583 | 13831392 | 864462.00 | 864240.58 |
| RSEC | 00 | 128 | 1 | 279 | 590 | 1076160 | 8407.50 | 8319.50 |
| RCOL | 00 | 128 | 2 | -10 | 612 | 1116288 | 8721.00 | 8633.00 |
| RHST | 00 | 2048 | 31 | -7 | 9634 | 17572416 | 8580.28 | - |
| RH39 | 00 | 2048 | 31 | 17 | 9658 | 17616192 | 8601.66 | - |
| SPN0 | 00 | 512 | 47 | 17 | 14634 | 26692416 | 52133.62 | - |
| ARSE | 00 | 128 | 2 | 0 | 622 | 1134528 | 8863.50 | 8770.73 |
| ARCO | 00 | 128 | 2 | 23 | 645 | 1176480 | 9191.25 | 9098.50 |
| AHST | 00 | 2048 | 33 | -106 | 10157 | 18526368 | 9046.08 | - |
| AH39 | 00 | 2048 | 33 | -81 | 10182 | 18571968 | 9068.34 | - |
| ASPN | 00 | 512 | 49 | 188 | 15427 | 28138848 | 54958.69 | - |
| OSPN | 00 | 512 | 52 | 48 | 16220 | 29585280 | 57783.75 | - |

#HIST RHST: bin 1 = 2048

#HIST RH39: bin 1 = 2048

#HIST AHST: bin 1 = 2048

#HIST AH39: bin 1 = 2048

clip 067 mono 320x160@25: Spix 100, Ssnd 2, C 320 (section 8)

| tag | O | R | F | D | lines | T | T/rep | primed |
|---|---|---|---|---|---|---|---|---|
| IDEN | 02 | 250 | 320 | 160 | | | | |
| RFR0 | 00 | 1 | 1 | 169 | 480 | 875520 | 875520.00 | 875310.00 |
| RSWP | 00 | 16 | 24 | 123 | 7587 | 13838688 | 864918.00 | 864708.00 |
| ARSW | 00 | 16 | 26 | -86 | 8000 | 14592000 | 912000.00 | 911778.57 |
| RSEC | 00 | 128 | 2 | -31 | 591 | 1077984 | 8421.75 | 8333.75 |
| RCOL | 00 | 128 | 2 | -10 | 612 | 1116288 | 8721.00 | 8633.00 |
| RHST | 00 | 2048 | 31 | -7 | 9634 | 17572416 | 8580.28 | - |
| RH39 | 00 | 2048 | 31 | 16 | 9657 | 17614368 | 8600.77 | - |
| SPN0 | 00 | 512 | 47 | 17 | 14634 | 26692416 | 52133.62 | - |
| ARSE | 00 | 128 | 2 | 1 | 623 | 1136352 | 8877.75 | 8784.99 |
| ARCO | 00 | 128 | 2 | 23 | 645 | 1176480 | 9191.25 | 9098.50 |
| AHST | 00 | 2048 | 33 | -107 | 10156 | 18524544 | 9045.19 | - |
| AH39 | 00 | 2048 | 33 | -81 | 10182 | 18571968 | 9068.34 | - |
| ASPN | 00 | 512 | 49 | 188 | 15427 | 28138848 | 54958.69 | - |
| OSPN | 00 | 512 | 52 | 48 | 16220 | 29585280 | 57783.75 | - |

#HIST RHST: bin 1 = 2048

#HIST RH39: bin 1 = 2048

#HIST AHST: bin 1 = 2048

#HIST AH39: bin 1 = 2048

clip 068 mono 320x192@25: Spix 120, Ssnd 2, C 320 (section 9)

| tag | O | R | F | D | lines | T | T/rep | primed |
|---|---|---|---|---|---|---|---|---|
| IDEN | 02 | 250 | 320 | 192 | | | | |
| RFR0 | 00 | 1 | 1 | 261 | 572 | 1043328 | 1043328.00 | 1043118.00 |
| RSWP | 00 | 16 | 29 | 24 | 9043 | 16494432 | 1030902.00 | 1030692.00 |
| ARSW | 00 | 16 | 31 | -107 | 9534 | 17390016 | 1086876.00 | 1086654.60 |
| RSEC | 00 | 128 | 2 | -32 | 590 | 1076160 | 8407.50 | 8319.50 |
| RCOL | 00 | 128 | 2 | -10 | 612 | 1116288 | 8721.00 | 8633.00 |
| RHST | 00 | 2048 | 31 | -7 | 9634 | 17572416 | 8580.28 | - |
| RH39 | 00 | 2048 | 31 | 17 | 9658 | 17616192 | 8601.66 | - |
| SPN0 | 00 | 512 | 47 | 16 | 14633 | 26690592 | 52130.06 | - |
| ARSE | 00 | 128 | 2 | 0 | 622 | 1134528 | 8863.50 | 8770.73 |
| ARCO | 00 | 128 | 2 | 23 | 645 | 1176480 | 9191.25 | 9098.50 |
| AHST | 00 | 2048 | 32 | 204 | 10156 | 18524544 | 9045.19 | - |
| AH39 | 00 | 2048 | 33 | -81 | 10182 | 18571968 | 9068.34 | - |
| ASPN | 00 | 512 | 50 | -123 | 15427 | 28138848 | 54958.69 | - |
| OSPN | 00 | 512 | 52 | 48 | 16220 | 29585280 | 57783.75 | - |

#HIST RHST: bin 1 = 2048

#HIST RH39: bin 1 = 2048

#HIST AHST: bin 1 = 2048

#HIST AH39: bin 1 = 2048

clip 069 mono 280x224@25: Spix 123, Ssnd 2, C 280 (section 10)

| tag | O | R | F | D | lines | T | T/rep | primed |
|---|---|---|---|---|---|---|---|---|
| IDEN | 02 | 250 | 280 | 224 | | | | |
| RFR0 | 00 | 1 | 1 | 274 | 585 | 1067040 | 1067040.00 | 1066830.00 |
| RSWP | 00 | 16 | 29 | 235 | 9254 | 16879296 | 1054956.00 | 1054746.00 |
| ARSW | 00 | 16 | 31 | 116 | 9757 | 17796768 | 1112298.00 | 1112076.59 |
| RSEC | 00 | 128 | 1 | 279 | 590 | 1076160 | 8407.50 | 8319.50 |
| RCOL | 00 | 128 | 2 | -10 | 612 | 1116288 | 8721.00 | 8633.00 |
| RHST | 00 | 2048 | 31 | -7 | 9634 | 17572416 | 8580.28 | - |
| RH39 | 00 | 2048 | 31 | 17 | 9658 | 17616192 | 8601.66 | - |
| SPN0 | 00 | 512 | 47 | 17 | 14634 | 26692416 | 52133.62 | - |
| ARSE | 00 | 128 | 2 | 0 | 622 | 1134528 | 8863.50 | 8770.73 |
| ARCO | 00 | 128 | 2 | 23 | 645 | 1176480 | 9191.25 | 9098.50 |
| AHST | 00 | 2048 | 33 | -106 | 10157 | 18526368 | 9046.08 | - |
| AH39 | 00 | 2048 | 33 | -82 | 10181 | 18570144 | 9067.45 | - |
| ASPN | 00 | 512 | 49 | 188 | 15427 | 28138848 | 54958.69 | - |
| OSPN | 00 | 512 | 52 | 48 | 16220 | 29585280 | 57783.75 | - |

#HIST RHST: bin 1 = 2048

#HIST RH39: bin 1 = 2048

#HIST AHST: bin 1 = 2048

#HIST AH39: bin 1 = 2048

clip 070 mono 320x240@16.67: Spix 150, Ssnd 2, C 320 (section 11)

| tag | O | R | F | D | lines | T | T/rep | primed |
|---|---|---|---|---|---|---|---|---|
| IDEN | 02 | 167 | 320 | 240 | | | | |
| RFR0 | 00 | 1 | 2 | 87 | 709 | 1293216 | 1293216.00 | 1293006.00 |
| RSWP | 00 | 16 | 36 | 49 | 11245 | 20510880 | 1281930.00 | 1281720.00 |
| ARSW | 00 | 16 | 38 | 38 | 11856 | 21625344 | 1351584.00 | 1351362.59 |
| RSEC | 00 | 128 | 2 | -31 | 591 | 1077984 | 8421.75 | 8333.75 |
| RCOL | 00 | 128 | 2 | -10 | 612 | 1116288 | 8721.00 | 8633.00 |
| RHST | 00 | 2048 | 31 | -7 | 9634 | 17572416 | 8580.28 | - |
| RH39 | 00 | 2048 | 31 | 17 | 9658 | 17616192 | 8601.66 | - |
| SPN0 | 00 | 512 | 47 | 17 | 14634 | 26692416 | 52133.62 | - |
| ARSE | 00 | 128 | 2 | 1 | 623 | 1136352 | 8877.75 | 8784.99 |
| ARCO | 00 | 128 | 2 | 23 | 645 | 1176480 | 9191.25 | 9098.50 |
| AHST | 00 | 2048 | 32 | 205 | 10157 | 18526368 | 9046.08 | - |
| AH39 | 00 | 2048 | 32 | 229 | 10181 | 18570144 | 9067.45 | - |
| ASPN | 00 | 512 | 49 | 188 | 15427 | 28138848 | 54958.69 | - |
| OSPN | 00 | 512 | 52 | 48 | 16220 | 29585280 | 57783.75 | - |

#HIST RHST: bin 1 = 2048

#HIST RH39: bin 1 = 2048

#HIST AHST: bin 1 = 2048

#HIST AH39: bin 1 = 2048

clip 071 mono 256x240@16.67: Spix 120, Ssnd 2, C 256 (section 12)

| tag | O | R | F | D | lines | T | T/rep | primed |
|---|---|---|---|---|---|---|---|---|
| IDEN | 02 | 167 | 256 | 240 | | | | |
| RFR0 | 00 | 1 | 2 | -51 | 571 | 1041504 | 1041504.00 | 1041294.00 |
| RSWP | 00 | 16 | 29 | 14 | 9033 | 16476192 | 1029762.00 | 1029552.00 |
| ARSW | 00 | 16 | 30 | 193 | 9523 | 17369952 | 1085622.00 | 1085400.61 |
| RSEC | 00 | 128 | 2 | -31 | 591 | 1077984 | 8421.75 | 8333.75 |
| RCOL | 00 | 128 | 2 | -10 | 612 | 1116288 | 8721.00 | 8633.00 |
| RHST | 00 | 2048 | 31 | -7 | 9634 | 17572416 | 8580.28 | - |
| RH39 | 00 | 2048 | 31 | 16 | 9657 | 17614368 | 8600.77 | - |
| SPN0 | 00 | 512 | 47 | 17 | 14634 | 26692416 | 52133.62 | - |
| ARSE | 00 | 128 | 2 | 0 | 622 | 1134528 | 8863.50 | 8770.88 |
| ARCO | 00 | 128 | 2 | 23 | 645 | 1176480 | 9191.25 | 9098.50 |
| AHST | 00 | 2048 | 33 | -106 | 10157 | 18526368 | 9046.08 | - |
| AH39 | 00 | 2048 | 32 | 229 | 10181 | 18570144 | 9067.45 | - |
| ASPN | 00 | 512 | 49 | 188 | 15427 | 28138848 | 54958.69 | - |
| OSPN | 00 | 512 | 52 | 48 | 16220 | 29585280 | 57783.75 | - |

#HIST RHST: bin 1 = 2048

#HIST RH39: bin 1 = 2048

#HIST AHST: bin 1 = 2048

#HIST AH39: bin 1 = 2048

clip 072 stereo 320x256@12.5: Spix 160, Ssnd 5, C 0 (section 13)

| tag | O | R | F | D | lines | T | T/rep | primed |
|---|---|---|---|---|---|---|---|---|
| IDEN | 02 | 125 | 320 | 0 | | | | |
| RFR0 | 00 | 1 | 2 | 143 | 765 | 1395360 | 1395360.00 | 1395150.00 |
| RSWP | 00 | 16 | 39 | -6 | 12123 | 22112352 | 1382022.00 | 1381812.00 |
| ARSW | 00 | 16 | 42 | -109 | 12953 | 23626272 | 1476642.00 | 1476417.62 |
| RSEC | 00 | 128 | 1 | 280 | 591 | 1077984 | 8421.75 | 8333.75 |
| RCOL | 00 | 128 | 2 | -10 | 612 | 1116288 | 8721.00 | 8633.00 |
| RHST | 00 | 2048 | 31 | -7 | 9634 | 17572416 | 8580.28 | - |
| RH39 | 00 | 2048 | 31 | 17 | 9658 | 17616192 | 8601.66 | - |
| SPN0 | 00 | 512 | 47 | 17 | 14634 | 26692416 | 52133.62 | - |
| ARSE | 00 | 128 | 2 | 9 | 631 | 1150944 | 8991.75 | 8897.79 |
| ARCO | 00 | 128 | 2 | 32 | 654 | 1192896 | 9319.50 | 9225.46 |
| AHST | 00 | 2048 | 33 | 27 | 10290 | 18768960 | 9164.53 | - |
| AH39 | 00 | 2048 | 33 | 52 | 10315 | 18814560 | 9186.80 | - |
| ASPN | 00 | 512 | 50 | 80 | 15630 | 28509120 | 55681.88 | - |
| OSPN | 00 | 512 | 52 | 48 | 16220 | 29585280 | 57783.75 | - |

#HIST RHST: bin 1 = 2048

#HIST RH39: bin 1 = 2048

#HIST AHST: bin 1 = 2048

#HIST AH39: bin 1 = 2048

clip 074 mono 256x192@15.2588: Spix 96, Ssnd 3, C 0 (section 14)

| tag | O | R | F | D | lines | T | T/rep | primed |
|---|---|---|---|---|---|---|---|---|
| IDEN | 02 | 153 | 256 | 192 | | | | |
| RFR0 | 00 | 1 | 1 | 150 | 461 | 840864 | 840864.00 | 840654.00 |
| RSWP | 00 | 16 | 23 | 119 | 7272 | 13264128 | 829008.00 | 828798.00 |
| ARSW | 00 | 16 | 25 | -107 | 7668 | 13986432 | 874152.00 | 873930.56 |
| RSEC | 00 | 128 | 1 | 279 | 590 | 1076160 | 8407.50 | 8319.50 |
| RCOL | 00 | 128 | 2 | -10 | 612 | 1116288 | 8721.00 | 8633.00 |
| RHST | 00 | 2048 | 31 | -7 | 9634 | 17572416 | 8580.28 | - |
| RH39 | 00 | 2048 | 31 | 17 | 9658 | 17616192 | 8601.66 | - |
| SPN0 | 00 | 512 | 47 | 17 | 14634 | 26692416 | 52133.62 | - |
| ARSE | 00 | 128 | 2 | 0 | 622 | 1134528 | 8863.50 | 8770.73 |
| ARCO | 00 | 128 | 2 | 23 | 645 | 1176480 | 9191.25 | 9098.50 |
| AHST | 00 | 2048 | 33 | -106 | 10157 | 18526368 | 9046.08 | - |
| AH39 | 00 | 2048 | 33 | -82 | 10181 | 18570144 | 9067.45 | - |
| ASPN | 00 | 512 | 49 | 188 | 15427 | 28138848 | 54958.69 | - |
| OSPN | 00 | 512 | 52 | 48 | 16220 | 29585280 | 57783.75 | - |

#HIST RHST: bin 1 = 2048

#HIST RH39: bin 1 = 2048

#HIST AHST: bin 1 = 2048

#HIST AH39: bin 1 = 2048

clip 088 mono 256x192@12.5: Spix 96, Ssnd 3, C 0 (section 15)

| tag | O | R | F | D | lines | T | T/rep | primed |
|---|---|---|---|---|---|---|---|---|
| IDEN | 02 | 250 | 256 | 192 | | | | |
| RFR0 | 00 | 1 | 2 | -160 | 462 | 842688 | 842688.00 | 842478.00 |
| RSWP | 00 | 16 | 23 | 123 | 7276 | 13271424 | 829464.00 | 829254.00 |
| ARSW | 00 | 16 | 24 | 208 | 7672 | 13993728 | 874608.00 | 874386.57 |
| RSEC | 00 | 128 | 2 | -32 | 590 | 1076160 | 8407.50 | 8319.50 |
| RCOL | 00 | 128 | 2 | -11 | 611 | 1114464 | 8706.75 | 8618.75 |
| RHST | 00 | 2048 | 31 | -6 | 9635 | 17574240 | 8581.17 | - |
| RH39 | 00 | 2048 | 31 | 17 | 9658 | 17616192 | 8601.66 | - |
| SPN0 | 00 | 512 | 47 | 16 | 14633 | 26690592 | 52130.06 | - |
| ARSE | 00 | 128 | 2 | 0 | 622 | 1134528 | 8863.50 | 8770.73 |
| ARCO | 00 | 128 | 2 | 23 | 645 | 1176480 | 9191.25 | 9098.35 |
| AHST | 00 | 2048 | 33 | -107 | 10156 | 18524544 | 9045.19 | - |
| AH39 | 00 | 2048 | 33 | -82 | 10181 | 18570144 | 9067.45 | - |
| ASPN | 00 | 512 | 49 | 188 | 15427 | 28138848 | 54958.69 | - |
| OSPN | 00 | 512 | 52 | 48 | 16220 | 29585280 | 57783.75 | - |

#HIST RHST: bin 1 = 2048

#HIST RH39: bin 1 = 2048

#HIST AHST: bin 1 = 2048

#HIST AH39: bin 1 = 2048

clip 089 stereo 256x192@20: Spix 96, Ssnd 4, C 0 (section 16)

| tag | O | R | F | D | lines | T | T/rep | primed |
|---|---|---|---|---|---|---|---|---|
| IDEN | 02 | 200 | 256 | 192 | | | | |
| RFR0 | 00 | 1 | 1 | 156 | 467 | 851808 | 851808.00 | 851598.00 |
| RSWP | 00 | 16 | 23 | 206 | 7359 | 13422816 | 838926.00 | 838716.00 |
| ARSW | 00 | 16 | 25 | 88 | 7863 | 14342112 | 896382.00 | 896157.62 |
| RSEC | 00 | 128 | 2 | -31 | 591 | 1077984 | 8421.75 | 8333.75 |
| RCOL | 00 | 128 | 2 | -10 | 612 | 1116288 | 8721.00 | 8633.00 |
| RHST | 00 | 2048 | 31 | -7 | 9634 | 17572416 | 8580.28 | - |
| RH39 | 00 | 2048 | 31 | 16 | 9657 | 17614368 | 8600.77 | - |
| SPN0 | 00 | 512 | 47 | 17 | 14634 | 26692416 | 52133.62 | - |
| ARSE | 00 | 128 | 2 | 8 | 630 | 1149120 | 8977.50 | 8883.69 |
| ARCO | 00 | 128 | 2 | 31 | 653 | 1191072 | 9305.25 | 9211.35 |
| AHST | 00 | 2048 | 33 | 28 | 10291 | 18770784 | 9165.42 | - |
| AH39 | 00 | 2048 | 33 | 53 | 10316 | 18816384 | 9187.69 | - |
| ASPN | 00 | 512 | 50 | 81 | 15631 | 28510944 | 55685.44 | - |
| OSPN | 00 | 512 | 52 | 48 | 16220 | 29585280 | 57783.75 | - |

#HIST RHST: bin 1 = 2048

#HIST RH39: bin 1 = 2048

#HIST AHST: bin 1 = 2048

#HIST AH39: bin 1 = 2048

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
- clip 088 file: header matches (channels 1, sound bytes 1250, Ssnd 3); palette sectors in frames 0-32: 0
- clip 089 file: header matches (channels 2, sound bytes 1562, Ssnd 4); palette sectors in frames 0-32: 0
- histograms: 64, every one sums to its row's reps unless listed
- peers RSEC (all clips)       16 clips, largest deviation 0.08%
- peers RCOL (all clips)       16 clips, largest deviation 0.16%
- peers RHST (all clips)       16 clips, largest deviation 0.01%
- peers SPN0 (all clips)       16 clips, largest deviation 0.01%
- peers OSPN (all clips)       16 clips, largest deviation 0.00%
- peers RHST polls (all clips) 16 clips, largest deviation 0.00%
- peers ARSE (stereo)           8 clips, largest deviation 0.16%
- peers ARCO (stereo)           8 clips, largest deviation 0.15%
- peers AHST (stereo)           8 clips, largest deviation 0.01%
- peers ASPN (stereo)           8 clips, largest deviation 0.00%
- peers AHST polls (stereo)     8 clips, largest deviation 0.00%
- peers ARSE (mono)             8 clips, largest deviation 0.16%
- peers ARCO (mono)             8 clips, largest deviation 0.00%
- peers AHST (mono)             8 clips, largest deviation 0.01%
- peers ASPN (mono)             8 clips, largest deviation 0.00%
- peers AHST polls (mono)       8 clips, largest deviation 0.00%
- order RSWP/16 < ARSW/16      16/16 clips
- order RSWP/16 < RFR0         16/16 clips
- peers handler (stereo)        8 clips, largest deviation 0.10%
- peers handler (mono)          8 clips, largest deviation 0.13%
- walk marks (O=01): none

Anomalies (RE-RUN request): none

## Constants

RAW_SECTOR_T (ts) = 134.62 T: mean (RSEC' - 8192) over 16 clips [RSEC]

stereo:
  RAW_T_PER_B (tb)      = 17.0982 T: (mean ARSE' - ts) / 512 over 8 clips [ARSE, RSEC]
  RAW_COL_T (tc)        = 40.97 T: mean (ARCO' - ARSE') / 8 over 8 clips [ARCO, ARSE, RCOL, RSEC]
  RAW_SND_SECTOR_T (tsnd) = 11039.40 T: least squares slope over 8 clips [ARSW, RSWP, ARSE, ARCO]
  RAW_FRAME_T (tf)      = -1019.32 T: least squares intercept, same points
  RAW_PAL_T (tp)        = 13092.96 T: mean (RFR0' - RSWP') x ARSW'/RSWP' over 8 clips [RFR0, RSWP, ARSW]
  least squares points (clip, Ssnd, y = ARSW' - Spix x mean ARSE' - C x tc): 060 3 32675.2; 061 3 32004.6; 062 3 31496.2; 063 3 32232.1; 064 4 43330.5; 065 4 43237.9; 072 5 54190.2; 089 4 42821.2
  tp per clip: 060 14129.1; 061 12787.7; 062 12787.1; 063 12299.4; 064 13031.6; 065 11693.4; 072 14251.2; 089 13764.3
note: stereo sound constants rest on 3 groups for two constants, 1 degree(s) of freedom (Ssnd 3: 060 061 062 063, Ssnd 4: 064 065 089, Ssnd 5: 072); valid for the fitted pairs only (stereo at 25, 20, 16.67, 12.5 fps); elsewhere allow about 0.5 percent

mono:
  RAW_T_PER_B (tb)      = 16.8744 T: (mean ARSE' - ts) / 512 over 8 clips [ARSE, RSEC]
  RAW_COL_T (tc)        = 40.52 T: mean (ARCO' - ARSE') / 8 over 8 clips [ARCO, ARSE, RCOL, RSEC]
  RAW_SND_SECTOR_T (tsnd) = 10173.66 T: least squares slope over 8 clips [ARSW, RSWP, ARSE, ARCO]
  RAW_FRAME_T (tf)      = 1303.72 T: least squares intercept, same points
  RAW_PAL_T (tp)        = 12530.59 T: mean (RFR0' - RSWP') x ARSW'/RSWP' over 8 clips [RFR0, RSWP, ARSW]
  least squares points (clip, Ssnd, y = ARSW' - Spix x mean ARSE' - C x tc): 066 2 21906.7; 067 2 21380.5; 068 2 20770.3; 069 2 21490.2; 070 2 22248.9; 071 2 22109.7; 074 3 31596.7; 088 3 32052.7
  tp per clip: 066 12500.6; 067 11179.1; 068 13100.7; 069 12740.8; 070 11899.2; 071 12379.0; 074 12501.6; 088 13943.7
note: mono sound constants are fixed exactly by the two groups' means (Ssnd 2: 066 067 068 069 070 071, Ssnd 3: 074 088); valid for the fitted pairs only (mono at 25, 16.67, 15.2588, 12.5 fps); elsewhere allow about 0.5 percent

RAW_STALL_T = 23.49 T: highest occupied AHST bin 1 (1-1 polls), upper edge 1 polls (22 + 47 x 0 T) x ARSE/RSEC (clip 063) [AHST, ARSE, RSEC]
mean token wait (bins at their mean poll count): unarmed 22.00 T [RHST]; armed stereo 23.48 T, mono 23.19 T [AHST x ARSE/RSEC]
mean stall per frame = armed mean wait x tokens a frame (Spix + Ssnd + 1):
  256x192@25: stereo 2348 T (100 tokens), mono 2296 T (99 tokens)
  320x160@25: stereo 2442 T (104 tokens), mono 2388 T (103 tokens)
  320x192@25: stereo 2912 T (124 tokens), mono 2852 T (123 tokens)
  280x224@25: stereo 2982 T (127 tokens), mono 2922 T (126 tokens)
  320x240@16.67: stereo 3639 T (155 tokens), mono 3548 T (153 tokens)
  256x240@16.67: stereo 2935 T (125 tokens), mono 2852 T (123 tokens)

Paste form:

```
RAW_K = {
    "stereo": {
        "tb": 17.0982,  # RAW_T_PER_B [ARSE, RSEC] 8 clips
        "ts": 134.62,  # RAW_SECTOR_T [RSEC] 16 clips
        "tsnd": 11039.40,  # RAW_SND_SECTOR_T [ARSW, RSWP, ARSE, ARCO] 8 clips
        "tc": 40.97,  # RAW_COL_T [ARCO, ARSE, RCOL, RSEC] 8 clips
        "tf": -1019.32,  # RAW_FRAME_T [ARSW, RSWP, ARSE, ARCO] 8 clips
        "tp": 13092.96,  # RAW_PAL_T [RFR0, RSWP, ARSW] 8 clips
    },
    "mono": {
        "tb": 16.8744,  # RAW_T_PER_B [ARSE, RSEC] 8 clips
        "ts": 134.62,  # RAW_SECTOR_T [RSEC] 16 clips
        "tsnd": 10173.66,  # RAW_SND_SECTOR_T [ARSW, RSWP, ARSE, ARCO] 8 clips
        "tc": 40.52,  # RAW_COL_T [ARCO, ARSE, RCOL, RSEC] 8 clips
        "tf": 1303.72,  # RAW_FRAME_T [ARSW, RSWP, ARSE, ARCO] 8 clips
        "tp": 12530.59,  # RAW_PAL_T [RFR0, RSWP, ARSW] 8 clips
    },
}
RAW_STALL_T = 23.49  # AHST bin 1 upper edge x ARSE/RSEC [AHST, ARSE, RSEC]
```

## Residuals

residual = 100 x (measured - model) / model; measured = ARSW' (ARSW/16, harness removed); model = raw_model_t(..., palette=False). Acceptance: every |residual| <= 1.0%.

| clip | form | Spix | Ssnd | C | sound B | pad B | measured ARSW' | model | residual % |
|---|---|---|---|---|---|---|---|---|---|
| 060 | stereo | 96 | 3 | 0 | 1250 | 286 | 886011.6 | 885435.3 | +0.065 |
| 061 | stereo | 100 | 3 | 320 | 1250 | 286 | 934005.7 | 934099.9 | -0.010 |
| 062 | stereo | 120 | 3 | 320 | 1250 | 286 | 1111275.7 | 1111878.3 | -0.054 |
| 063 | stereo | 123 | 3 | 280 | 1250 | 286 | 1137039.7 | 1136906.5 | +0.012 |
| 064 | stereo | 150 | 4 | 320 | 1874 | 174 | 1389777.6 | 1389585.4 | +0.014 |
| 065 | stereo | 120 | 4 | 256 | 1874 | 174 | 1120395.6 | 1120296.0 | +0.009 |
| 066 | mono | 96 | 2 | 0 | 625 | 399 | 864240.6 | 863984.9 | +0.030 |
| 067 | mono | 100 | 2 | 320 | 625 | 399 | 911778.6 | 912049.1 | -0.030 |
| 068 | mono | 120 | 2 | 320 | 625 | 399 | 1086654.6 | 1087535.4 | -0.081 |
| 069 | mono | 123 | 2 | 280 | 625 | 399 | 1112076.6 | 1112237.4 | -0.014 |
| 070 | mono | 150 | 2 | 320 | 937 | 87 | 1351362.6 | 1350764.7 | +0.044 |
| 071 | mono | 120 | 2 | 256 | 937 | 87 | 1085400.6 | 1084942.0 | +0.042 |
| 072 | stereo | 160 | 5 | 0 | 2500 | 60 | 1476417.6 | 1476405.1 | +0.001 |
| 074 | mono | 96 | 3 | 0 | 1024 | 512 | 873930.6 | 874158.6 | -0.026 |
| 088 | mono | 96 | 3 | 0 | 1250 | 286 | 874386.6 | 874158.6 | +0.026 |
| 089 | stereo | 96 | 4 | 0 | 1562 | 486 | 896157.6 | 896474.7 | -0.035 |

pad B: the sound sectors' pad bytes a frame, the tag byte included.

acceptance: PASS (largest |residual| 0.081%)

## Sound term (diagnostic; the gate is unchanged)

- stereo sound constants rest on 3 groups for two constants, 1 degree(s) of freedom (Ssnd 3: 060 061 062 063, Ssnd 4: 064 065 089, Ssnd 5: 072); valid for the fitted pairs only (stereo at 25, 20, 16.67, 12.5 fps); elsewhere allow about 0.5 percent
- mono sound constants are fixed exactly by the two groups' means (Ssnd 2: 066 067 068 069 070 071, Ssnd 3: 074 088); valid for the fitted pairs only (mono at 25, 16.67, 15.2588, 12.5 fps); elsewhere allow about 0.5 percent
- pad-aware fit y = A + S x Ssnd + d x real bytes, on the gate fit's points (d: T a sound byte costs over a pad byte):
  - mono, all three free: A 1517.2, S 9172.5, d +2.45 T a sound byte (condition number 5220; d determined: one Ssnd group holds two sound-byte counts); residuals -511 +15 +626 -94 -87 +52 -49 +49 T
  - stereo, all three free: A -350.7, S 10321.7, d +1.21 T a sound byte (condition number 15576; d determined: one Ssnd group holds two sound-byte counts); residuals -552 +119 +627 -109 -132 -40 +86 +1 T
  - stereo with d = mono d x armed ratio = +2.49: A 357.8, S 9561.3; residuals -526 +145 +653 -83 -68 +24 +190 -335 T
  - code: vid_raw_apad (video.asm:5258) reads the pad and tag through the INI slide, 16 T a byte; vid_ds_xfer (video.asm:3328) moves a sound byte by ini, 16 T plus 14 T a 32-byte pass and about 300 T an arm, about 17.6 T in 256-byte arms: a sound byte about 1.6 T over a pad byte, unarmed
- mono RAW_FRAME_T 1303.72 T, mono RAW_SND_SECTOR_T 10173.66 T (0.92 x stereo's 11039.40 T).

gate sound term (Ssnd x tsnd + tf) against the pad-aware fit, 256x192 (mono: its own fit; stereo: its own fit); err = gate - fit, negative = the gate under-prices:

| form | fps | sound B | Ssnd | pad B | gate T | fit T | err T | err % of period | fitted pair |
|---|---|---|---|---|---|---|---|---|---|
| mono | 30 | 521 | 2 | 503 | 21651 | 21141 | +510 | +0.055 | no |
| mono | 25 | 625 | 2 | 399 | 21651 | 21396 | +255 | +0.023 | yes |
| mono | 20 | 781 | 2 | 243 | 21651 | 21779 | -128 | -0.009 | no |
| mono | 16.67 | 937 | 2 | 87 | 21651 | 22161 | -510 | -0.030 | yes |
| mono | 15.2588 | 1024 | 3 | 512 | 31825 | 31547 | +277 | +0.015 | yes |
| mono | 12.5 | 1250 | 3 | 286 | 31825 | 32102 | -277 | -0.012 | yes |
| mono | 10.5 | 1488 | 3 | 48 | 31825 | 32686 | -861 | -0.032 | no |
| stereo | 30 | 1042 | 3 | 494 | 32099 | 31872 | +227 | +0.024 | no |
| stereo | 25 | 1250 | 3 | 286 | 32099 | 32123 | -25 | -0.002 | yes |
| stereo | 20 | 1562 | 4 | 486 | 43138 | 42822 | +317 | +0.023 | yes |
| stereo | 16.67 | 1874 | 4 | 174 | 43138 | 43198 | -60 | -0.004 | yes |
| stereo | 15.2588 | 2048 | 5 | 512 | 54178 | 53730 | +448 | +0.024 | no |
| stereo | 12.5 | 2500 | 5 | 60 | 54178 | 54276 | -98 | -0.004 | yes |
| stereo | 10.5 | 2976 | 6 | 96 | 65217 | 65172 | +45 | +0.002 | no |

largest |err| outside the fitted pairs: 0.055 percent of the period
sound-term rule (one term a sector holds: |d| <= 3.0 T a sound byte in both forms and every layout above within 0.15 percent): PASS (largest |d| 2.45 T, largest |err| 0.055 percent)

## Utilisation of the target shapes

period = samples a frame x 1792 T: vid_run releases a frame when the CTC reader has consumed the previous frame's sound (vid_pace_poll at .pace, video.asm:2352; the deficit clamp at .paced, video.asm:2374), not on fields. Worst frame (palette sector) + glue 1138.7 T (glue_t / audio_factor); F = 1.0. The last column is the two-field period 28363200 / fps, for reference only.

| shape | form | Spix | Ssnd | C | model T | period T | util | util with stall | util, pixels-only frame | ref: util at two fields |
|---|---|---|---|---|---|---|---|---|---|---|
| 256x192@25 | stereo | 96 | 3 | 0 | 898528 | 1120000 | 0.8033 | 0.8033 | 0.7916 | 0.7930 |
| 256x192@25 | mono | 96 | 2 | 0 | 876516 | 1120000 | 0.7836 | 0.7836 | 0.7724 | 0.7736 |
| 320x160@25 | stereo | 100 | 3 | 320 | 947193 | 1120000 | 0.8467 | 0.8467 | 0.8350 | 0.8359 |
| 320x160@25 | mono | 100 | 2 | 320 | 924580 | 1120000 | 0.8265 | 0.8266 | 0.8153 | 0.8160 |
| 320x192@25 | stereo | 120 | 3 | 320 | 1124971 | 1120000 | 1.0055 | 1.0055 | 0.9938 | 0.9926 |
| 320x192@25 | mono | 120 | 2 | 320 | 1100066 | 1120000 | 0.9832 | 0.9832 | 0.9720 | 0.9706 |
| 280x224@25 | stereo | 123 | 3 | 280 | 1149999 | 1120000 | 1.0278 | 1.0278 | 1.0161 | 1.0146 |
| 280x224@25 | mono | 123 | 2 | 280 | 1124768 | 1120000 | 1.0053 | 1.0053 | 0.9941 | 0.9924 |
| 320x240@16.67 | stereo | 150 | 4 | 320 | 1402678 | 1679104 | 0.8361 | 0.8361 | 0.8283 | 0.8251 |
| 320x240@16.67 | mono | 150 | 2 | 320 | 1363295 | 1679104 | 0.8126 | 0.8126 | 0.8051 | 0.8019 |
| 256x240@16.67 | stereo | 120 | 4 | 256 | 1133389 | 1679104 | 0.6757 | 0.6757 | 0.6679 | 0.6668 |
| 256x240@16.67 | mono | 120 | 2 | 256 | 1097473 | 1679104 | 0.6543 | 0.6543 | 0.6468 | 0.6457 |

stereo over 1.00: 320x192@25, 320x192@25 (with stall), 280x224@25, 280x224@25 (with stall)
stereo within 10 percent of the limit (0.90 < util <= 1.00): none
mono over 1.00: 280x224@25, 280x224@25 (with stall)
mono within 10 percent of the limit (0.90 < util <= 1.00): 320x192@25, 320x192@25 (with stall)

## Largest admitted height at 25 fps

Heights 256 down to 1, util <= 1.00 at the sound period, glue added, F = 1.0.

| width | form | palette frame: height | util | pixels-only frame: height | util |
|---|---|---|---|---|---|
| 320 | stereo | 190 | 0.9975 | 192 | 0.9938 |
| 320 | mono | 195 | 0.9989 | 196 | 0.9955 |
| 280 | stereo | 217 | 0.9961 | 219 | 0.9923 |
| 280 | mono | 223 | 0.9974 | 224 | 0.9941 |
| 256 | stereo | 238 | 0.9952 | 242 | 0.9994 |
| 256 | mono | 244 | 0.9966 | 246 | 0.9932 |

## Budget of a 320x192@25 frame

Period 1120000 T (625 samples x 1792 T). Palette frame, F = 1.0.

| term | stereo T | stereo % | mono T | mono % |
|---|---|---|---|---|
| pixel bytes, Spix x 512 x tb | 1050516 | 93.80 | 1036762 | 92.57 |
|   of which the sound handler: (byte T / 1792) interrupts x handler T | 66999 | 5.98 | 53310 | 4.76 |
| per-sector overhead, Spix x ts | 16155 | 1.44 | 16155 | 1.44 |
| column ends, C x tc | 13109 | 1.17 | 12967 | 1.16 |
| sound sectors, Ssnd x tsnd | 33118 | 2.96 | 20347 | 1.82 |
| frame remainder, tf | -1019 | -0.09 | 1304 | 0.12 |
| palette sector, tp | 13093 | 1.17 | 12531 | 1.12 |
| glue | 1139 | 0.10 | 1139 | 0.10 |
| total | 1126110 | 100.55 | 1101205 | 98.32 |

- stereo handler: one interrupt a sample, 625 a frame, 114.29 T each = 71431 T a frame (6.38 percent of the period, all terms together)
- mono handler: one interrupt a sample, 625 a frame, 92.14 T each = 57590 T a frame (5.14 percent of the period, all terms together)
- 1.0 percent of a 25 fps period is 11200 T a frame.

## Handlers, sectors, column ends

handler cost per interrupt = (armed - SPN0) / interrupts a rep; interrupts a rep = armed rep T / 1792 T
- raw stereo (ASPN, stereo clips): 114.29 T (31.07 interrupts a rep; 8 clips, 114.19-114.41)
- raw mono (ASPN, mono clips): 92.14 T (30.67 interrupts a rep; 8 clips, 92.11-92.23)
- existing video_ctc_isr_stereo (OSPN, all clips): 175.26 T (32.25 interrupts a rep; 16 clips, 175.22-175.33)
- per-sector overhead, unarmed: ts = 134.62 T (RSEC - 8192 as printed: 222.62 T)
- per-sector overhead, armed stereo: ARSE' - 8192 = 696.92 T (ARSE as printed 8982.84 T, ARSE/RSEC 1.0673)
- per-sector overhead, armed mono: ARSE' - 8192 = 582.31 T (ARSE as printed 8867.06 T, ARSE/RSEC 1.0540)
- column end, unarmed: (RCOL - RSEC) / 8 = 38.19 T against the 38 T design figure
- column end, armed stereo: tc = 40.97 T
- column end, armed mono: tc = 40.52 T

## Histograms (summed over clips)

bin k counts token waits of 2^(k-1) to 2^k - 1 $FF polls (bin 0: the token on the first read; bin 9: 256 or more); n polls wait 22 + 47 x (n - 1) T unarmed, that x ARSE/RSEC armed (wait shape inline).

| histogram | bin | polls | wait T | count |
|---|---|---|---|---|
| AHST stereo | 1 | 1-1 | 23.5-23.5 | 16384 |
| AHST stereo | all | | | 16384 |
| AHST mono | 1 | 1-1 | 23.2-23.2 | 16384 |
| AHST mono | all | | | 16384 |
| RHST | 1 | 1-1 | 22.0-22.0 | 32768 |
| RHST | all | | | 32768 |
| RH39 | 1 | 1-1 | 22.0-22.0 | 32768 |
| RH39 | all | | | 32768 |
| AH39 stereo | 1 | 1-1 | 23.5-23.5 | 16384 |
| AH39 stereo | all | | | 16384 |
| AH39 mono | 1 | 1-1 | 23.2-23.2 | 16384 |
| AH39 mono | all | | | 16384 |

First poll at the benched image's production spacing (RHST/AHST: 11 + 7 x VR_POLL_PAD_N T after CRC 2; the log does not record VR_POLL_PAD_N) against the prototype's 39 T (RH39/AH39), the same clips, mean $FF polls a wait (bins at their mean): unarmed 1.000 against 1.000 (16 clips); armed stereo 1.000 against 1.000 (8 clips); armed mono 1.000 against 1.000 (8 clips). Used in no constant; the wait T columns above count from poll 1 for both.

## Old layout vs raw

old: NXBD on clip 10 (old direct layout), per block, rows as printed (the DS1 harness is not tracked); raw: RW1 means, per sector, as printed.

| what | old row | old T | raw row | raw T |
|---|---|---|---|---|
| open + 512 bare INI, unarmed | DTI0 | 8991.75 | RSEC | 8414.62 |
| open + 512 bare INI, armed | ADTI (old handler) | 9975.00 | ARSE stereo / mono (raw handlers) | 8982.84 / 8867.06 |
| open + 512 B to the destination, unarmed | DTC0 (vid_ds_xfer) | 9704.25 | RSEC (the slide is the transfer) | 8414.62 |
| open + 512 B to the destination, armed | ADTC (old handler) | 10758.75 | ARSE stereo / mono | 8982.84 / 8867.06 |
| open + split transfer | DTD0 (4 x xfer 128) | 10616.25 | RCOL (8 x 64, column ends) | 8720.11 |
| open + pad discard | DTB0 (vid_ds_pad) | 19522.50 | - (raw pad bytes are INI) | - |
| per-block overhead, unarmed | DTI0 - 8192 | 799.75 | RSEC - 8192 (ts) | 222.62 (134.62) |
| T per byte, armed, transfer included | ADTC / 512 | 21.013 | ARSE / 512 stereo / mono | 17.545 / 17.318 |
| gate T per byte | DIRECT_T_PER_B (section byte, wire included) | 24.2 | tb stereo / mono | 17.0982 / 16.8744 |

## Playback (leg B)

### Step 6: the model's verdict against LATE and URUN

model: the gate (Release instructions, palette frame, stall term) at the sound period; admitted = util <= 1.00. On time = LATE 0000 and URUN 0000.

| step | clip | shape | form | util | model | LATE | URUN | on time |
|---|---|---|---|---|---|---|---|---|
| 1 | 074 | 256x192@15.2588 | mono | 0.4838 | admitted | 0000 | 0000 | yes |
| 3 | 060 | 256x192@25 | stereo | 0.8033 | admitted | 0000 | 0000 | yes |
| 4 | 061 | 320x160@25 | stereo | 0.8467 | admitted | 0000 | 0000 | yes |
| 5 | 062 | 320x192@25 | stereo | 1.0055 | refused | 00F9 | 00F9 | no |
| 6 | 063 | 280x224@25 | stereo | 1.0278 | refused | 00F9 | 00F9 | no |
| 7 | 064 | 320x240@16.67 | stereo | 0.8361 | admitted | 0000 | 0000 | yes |
| 8 | 065 | 256x240@16.67 | stereo | 0.6757 | admitted | 0000 | 0000 | yes |
| 9 | 066 | 256x192@25 | mono | 0.7836 | admitted | 0000 | 0000 | yes |
| 11 | 067 | 320x160@25 | mono | 0.8266 | admitted | 0000 | 0000 | yes |
| 12 | 068 | 320x192@25 | mono | 0.9832 | admitted | 0000 | 0000 | yes |
| 13 | 069 | 280x224@25 | mono | 1.0053 | refused | 00F9 | 00F9 | no |
| 14 | 070 | 320x240@16.67 | mono | 0.8126 | admitted | 0000 | 0000 | yes |
| 15 | 071 | 256x240@16.67 | mono | 0.6543 | admitted | 0000 | 0000 | yes |
| 16 | 072 | 320x256@12.5 | stereo | 0.6655 | admitted | 0000 | 0000 | yes |
| 17 | 073 | 256x192@25 | stereo | 0.8033 | admitted | 0000 | 0000 | yes |
| 18 | 074 | 256x192@15.2588 | mono | 0.4838 | admitted | 0000 | 0000 | yes |
| 19 | 074 | 256x192@15.2588 | mono | 0.4838 | admitted | 0000 | 0000 | yes |
| 20 | 075 | 256x192@25 | stereo | 0.8033 | admitted | 0000 | 0000 | yes |
| 21 | 076 | 256x192@25 | mono | 0.7836 | admitted | 0000 | 0000 | yes |
| 22 | 077 | 256x192@25 | stereo | 0.8033 | admitted | 0000 | 0000 | yes |
| 23 | 078 | 256x192@25 | mono | 0.7836 | admitted | 0000 | 0000 | yes |
| 24 | 088 | 256x192@12.5 | mono | 0.3964 | admitted | 0000 | 0000 | yes |
| 25 | 089 | 256x192@20 | stereo | 0.6507 | admitted | 0000 | 0000 | yes |
| 28 | 060 | 256x192@25 | stereo | 0.8033 | admitted | 0000 | 0000 | yes |
| 29 | 063 | 280x224@25 | stereo | 1.0278 | refused | 048B | 048C | no |
| 30 | 062 | 320x192@25 | stereo | 1.0055 | refused | 004D | 004E | no |

admitted clips that showed LATE or URUN: none
refused clips that played on time: none
fixture clips with no readout row: 079
readout rows outside the raw model: 004, 010

### Late clips: waits for ring room

A frame is released when the CTC reader has consumed the previous frame's sound (vid_pace_poll at .pace, video.asm:2352); .paced (video.asm:2374) adds one frame's bytes and drops a deficit of a whole frame. The reader never stops: when the frame loop runs late it plays on into stale ring bytes and passes the writer. vid_aud_pump's room test (video.asm:1882: room = ring - guard - (writer - reader) mod ring, with a 256-byte floor) then sees a nearly full ring, so .qnext (video.asm:2445) leaves the next frame's sound unwritten and .ffin (video.asm:2394) waits until the reader has freed room for it, up to one frame period. So a late clip is slowed by more than its utilisation. The bench rows never see this: nxb_aud_body.ptr (video.asm:4776) puts the writer half a ring ahead of the reader on every rep. ring_play runs the loop with the frame work below and counts the waits.

Frame work = the gate's pixels-only frame + glue + plain DEBUG work (leg B runs the DEBUG build; IFNDEF NXB_QUIET code the bench image does not carry), on a late frame's path, base T x the armed factor 1 / (1 - handler / 1792) (stereo 1.0681, mono 1.0542). Frame 0 adds the palette sector and its DEBUG sector work.
- per pixel sector 100.4 T: vr_sector_n's PLAY divider 86 T (.nocrc, video.asm:5175) and vid_rl_poll (video.asm:795) 231 T once per 16 arms = 14.4 T; vid_sd_tok_h's poll counter (177 T, .got, video.asm:3040) runs only on a wait past the open's djnz loop (257 or more polls, a RE-RUN), so it is not priced (wait shape inline)
- per sound sector 231.4 T: vid_ds_blkopen's arm 40 T (video.asm:3224), the poll counter 177 T, 14.4 T of vid_rl_poll
- per frame: vid_play_frame 179 T (video.asm:845); the .pace poll's arm 40 + 14.4 T (vid_pace_poll, video.asm:1810); vid_dbg_late 174 T (video.asm:5365); vid_dbg_urun 402 T with its own vid_pace_poll through vid_raw_rd_hl (video.asm:5388) + 14.4 T; vid_aud_pump's .next arm 40 + 14.4 T a pass (video.asm:1846) x 2 + sound bytes / 8192 passes
- counted from the instructions (Zilog T, NEXTREG A,n read 13 T): every T figure above. Estimated: the 1-in-16 share of vid_rl_poll at each arm, and the pump passes a frame (one chunk, a second when the ring tail wraps, the final pass).

| step | clip | form | frames | DEBUG T a frame | util, pixels-only + DEBUG | PLAY | on-time PLAY | measured slowdown | predicted PLAY | waits | predicted slowdown | residual T a frame |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | 074 | mono | 153 | 11887 | 0.4835 | 495 | 494.9 | 1.0001 | 494.9 | 0 | 1.0000 | +258 |
| 3 | 060 | stereo | 250 | 12046 | 0.8023 | 494 | 493.6 | 1.0008 | 493.6 | 0 | 1.0000 | +914 |
| 4 | 061 | stereo | 250 | 12475 | 0.8462 | 494 | 493.6 | 1.0008 | 493.6 | 0 | 1.0000 | +914 |
| 5 | 062 | stereo | 250 | 14620 | 1.0068 | 499 | 493.6 | 1.0109 | 498.9 | 1 | 1.0108 | +115 |
| 6 | 063 | stereo | 250 | 14942 | 1.0295 | 512 | 493.6 | 1.0373 | 512.0 | 2 | 1.0373 | -58 |
| 7 | 064 | stereo | 167 | 18090 | 0.8390 | 495 | 494.3 | 1.0014 | 494.3 | 0 | 1.0000 | +2307 |
| 8 | 065 | stereo | 167 | 14872 | 0.6767 | 495 | 494.3 | 1.0014 | 494.3 | 0 | 1.0000 | +2307 |
| 9 | 066 | mono | 250 | 11640 | 0.7828 | 494 | 493.6 | 1.0008 | 493.6 | 0 | 1.0000 | +914 |
| 11 | 067 | mono | 250 | 12064 | 0.8261 | 494 | 493.6 | 1.0008 | 493.6 | 0 | 1.0000 | +914 |
| 12 | 068 | mono | 250 | 14181 | 0.9847 | 494 | 493.6 | 1.0008 | 493.6 | 0 | 1.0000 | +914 |
| 13 | 069 | mono | 250 | 14499 | 1.0070 | 499 | 493.6 | 1.0109 | 499.1 | 1 | 1.0111 | -180 |
| 14 | 070 | mono | 167 | 17360 | 0.8155 | 495 | 494.3 | 1.0014 | 494.3 | 0 | 1.0000 | +2307 |
| 15 | 071 | mono | 167 | 14184 | 0.6553 | 495 | 494.3 | 1.0014 | 494.3 | 0 | 1.0000 | +2307 |
| 16 | 072 | stereo | 125 | 19415 | 0.6683 | 494 | 493.6 | 1.0008 | 493.6 | 0 | 1.0000 | +1827 |
| 17 | 073 | stereo | 250 | 12046 | 0.8023 | 494 | 493.6 | 1.0008 | 493.6 | 0 | 1.0000 | +914 |
| 18 | 074 | mono | 153 | 11887 | 0.4835 | 495 | 494.9 | 1.0001 | 494.9 | 0 | 1.0000 | +258 |
| 19 | 074 | mono | 153 | 11887 | 0.4835 | 495 | 494.9 | 1.0001 | 494.9 | 0 | 1.0000 | +258 |
| 20 | 075 | stereo | 249 | 12046 | 0.8023 | 492 | 491.6 | 1.0008 | 491.6 | 0 | 1.0000 | +859 |
| 21 | 076 | mono | 249 | 11640 | 0.7828 | 492 | 491.6 | 1.0008 | 491.6 | 0 | 1.0000 | +859 |
| 22 | 077 | stereo | 200 | 12046 | 0.8023 | 395 | 394.9 | 1.0003 | 394.9 | 0 | 1.0000 | +346 |
| 23 | 078 | mono | 200 | 11640 | 0.7828 | 395 | 394.9 | 1.0003 | 394.9 | 0 | 1.0000 | +346 |
| 24 | 088 | mono | 250 | 11889 | 0.3961 | 987 | 987.2 | 0.9998 | 987.2 | 0 | 1.0000 | -442 |
| 25 | 089 | stereo | 200 | 12295 | 0.6501 | 494 | 493.4 | 1.0011 | 493.4 | 0 | 1.0000 | +1590 |
| 28 | 060 | stereo | 789 | 12046 | 0.8023 | 1558 | 1557.8 | 1.0001 | 1557.8 | 0 | 1.0000 | +149 |
| 29 | 063 | stereo | 1164 | 14942 | 1.0295 | 2380 | 2298.2 | 1.0356 | 2379.5 | 7 | 1.0354 | +238 |
| 30 | 062 | stereo | 78 | 14620 | 1.0068 | 157 | 154.0 | 1.0195 | 157.0 | 1 | 1.0197 | -282 |

PLAY counts whole fields of 567264 T: its resolution is 2269 T a frame over 250 frames, 3397 over 167, 4538 over 125.
