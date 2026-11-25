# Raw direct video - KS3 sitting 1c (2026-11-25)

Sitting: KS3, core 3.03.03 as stated for the sitting. Both legs staged from 14c9f79 (clean tree). Leg A: -BenchQuiet build, log NXBENCH.TXT in this folder, 29 captures (NXBW on 060-072, 074, 088, 089; NXBM on 066-071, 074, 088; NXBD on 010; NXBP on 060, 063, 068, 088). Leg B: DEBUG build, log NXPLAY.TXT in this folder, 22 captures (table in playback.md). Details and the owner's note in sitting.txt.

Produced by:

- `python tests\core303\playlog.py NXPLAY.TXT --out playback.md` (exit 0)
- `python tests\raw_fit.py NXBENCH.TXT --clips <leg A folder> --playback playback.md --prev <sitting 1b NXBENCH.TXT> --play-clips <leg B folder>` (exit 1: the sound-term rule fails on the mono_dma form; residuals, variant pattern and RE-RUN list pass). Its output is the second half of this file, unedited.

The first half is written from that output, the two logs, sitting.txt and sitting 1b's folder.

## Summary

STOP conditions for the owner, before any constant is adopted:

1. Pitch. The DMA sample period is 1799.64 T, not 1792: the mono DMA form plays 0.425 percent (7.37 cents) low and slow. The limit for folding it in without a decision is 0.05 percent. See "Pitch".
2. Sound-term rule, mono_dma form only. The pad-aware fit gives d = -3.52 T a sound byte (standard error 1.28) against a limit of 3.0; the rule's other clause passes (largest gate minus fit 0.078 percent of the period, limit 0.15). A pad term is an owner decision. Stereo and mono_ctc pass (d +0.75 and +0.23; 0.015 and 0.005 percent). See "Sound term" below and "What does not match".

Neither is a NO-GO row. No constant, preset or player code was changed.

### Control

PASS. NXBD on 010 against sitting 1b, row by row: largest difference 0.158 percent (DTI0, one raster line; ADTI 0.143, DTB0 0.073, the rest equal); limit 0.5.

### DMA mono sound: go or no-go rows

| Row | Verdict | Figures |
|---|---|---|
| R1 rate | GO | sample T by load: MRSW (frames) 1799.41, MSPN (spin) 1799.51, MHST (sector reads) 1800.00; spread between loads 0.033 percent (GO to 0.1); mean 1799.64 T, 0.426 percent over 1792 (limit 0.5) |
| R2 steal | GO | 10.01 T a sample under the spin (9.97-10.09), 13.99 T under the sector read (13.97-14.15); limit 16 |
| R3 card | GO | MSUM equals the file's sum on all 8 clips; no ERR; MHST and RHST bins equal on every clip (2048 waits in bin 1 each) |
| R4 pointer | GO | MPTR on 8 clips: F 0, D 0, flags 01 (bit 0 set, bits 1 and 2 clear); 2 to 5 of 65535 reads retried. Ear, 078: no click reported |
| R5 ticks | GO | MTCK R 250 over 250 raster wraps on all 8 clips |
| R6 teardown | GO | MCPY / CPY0 0.992 to 1.000 (limit 1.02) |
| Leg B | GO by the log, with one open point | every mono DMA capture (066, 068 twice, 069, 074, 076, 078, 088, 066 LOOP) reads LATE 0000 and URUN 0000, and the DEBUG model puts each on time; CHK equals the file-derived sum on every full play of a clip without bars, on both mono paths (076 and 078 on the CTC path; 066, 074, 076, 078, 088 on the DMA path); 004 at B.24 reads as at B.3 except CHK (see "004"). Exceptions: none reported. Open point: B.23 (see "What does not match", 6) |

- R4 flag bit 1 is clear on every clip: $8000 was never read at the ring end in 8 x 65535 reads.
- "None reported" for the ear checks is the absence of a note, not an observation.
- By the rows, the DMA form is a GO. Whether it ships is the owner's, with the pitch decision.

### Pitch

- sample_t[mono_dma] = 1799.640 T: mean of 24 figures (MRSW, MSPN, MHST on 8 clips), range 1798.90 to 1800.17. Standard error of the mean 0.071 T (0.004 percent); one figure resolves 0.24 to 0.42 T (a raster line and one sample).
- Offset 1792 / 1799.640 - 1 = -0.425 percent = -7.37 cents; 15,558.7 Hz against 15,625.0 Hz. Over the 0.05 percent limit.
- Owner at B.19 (076, film) and B.20 (078, tones) against the CTC plays B.12 and B.13: "same" and "same".
- Leg B PLAY, independent of the bench counts: the DMA plays ran longer than the CTC plays of the same clips - 068 496 against 494 fields (+0.40 percent), 076 494 against 492 (+0.41), 078 397 against 395 (+0.51), 088 992 against 987 at sitting 1b (+0.51); the 066 LOOP ran 902 frames in 1788 fields against 1780.9 at 1792 T (+0.40). One field is 0.20 to 0.25 percent of the 8 to 10 second plays, 0.10 of 088, 0.06 of the LOOP.
- Fixed-prescaler hypotheses, by load (MRSW, MSPN, MHST means):

  | Period | MRSW | MSPN | MHST | Verdict |
  |---|---|---|---|---|
  | 1792 T (the prescaler alone) | +7.41 | +7.51 | +8.00 | excluded |
  | 1799 T (+7) | +0.41 | +0.51 | +1.00 | excluded as a fixed figure: MHST reads 1799.82 to 1800.17 on all 8 clips |
  | 1800 T (+8) | -0.59 | -0.49 | -0.00 | holds under the sector-read load only; MSPN reads 1799.33 to 1799.57 on all 8 clips |
  | 1824 T (57 units of 32) | -24.59 | -24.49 | -24.00 | excluded |

- Supported: 56 units of 32 T plus a bus re-acquire of 7.4 to 8.0 T a sample that depends on what the CPU is running (the three loads differ by 0.033 percent, more than a figure's resolution, the same way on every clip). No fixed integer period fits all three loads.
- The gate figures in this report use 1799.64 T for the mono_dma period (the frame period is 0.426 percent longer than the CTC forms'). That is the measured period, stated here so it is not folded in silently: if the owner does not accept the offset, the mono_dma columns do not apply.

### Constants (model 1c)

T = Spix x 512 x tb x F + a x OV + Ssnd x tsnd + tf + P x tp + stall; period = samples x sample_t.

| form | a | tb | tsnd | tf | tp | sample_t |
|---|---|---|---|---|---|---|
| stereo | 1.06181 | 16.9890 | 9069.23 | 1438.24 | 13270.26 | 1792 |
| mono_ctc | 1.04849 | 16.7758 | 8830.15 | 1315.63 | 12799.30 | 1792 |
| mono_dma | 1.00784 | 16.1254 | 9412.87 | 579.51 | 12322.48 | 1799.64 |

RAW_STALL_T 23.38. The paste form is in the script output ("Constants"). The mono_dma row is subject to the two STOP conditions.

### Residuals

- Acceptance PASS: largest |residual| 0.112 percent (066, mono_dma); limit 1.0.
- Worst per form: stereo 0.022 percent (089), mono_ctc 0.014 (066), mono_dma 0.112 (066).
- Pattern by program (train clips less inline clips): stereo +0.007 percent, mono_ctc +0.003, mono_dma +0.041; limit 0.2. The counted overhead holds on both programs.
- mono_dma scatters five to eight times wider than the CTC forms (residuals -982 to +920 T a frame against -197 to +113): see "What does not match", 2.

### Utilisation of the six target shapes (palette frame / pixels-only frame)

Sound period, glue added, no stall term (one poll's stall moves no figure by more than 0.0001). Projected = the figure made before the sitting, which took 1792 T a sample in every form.

| shape | stereo | projected | mono_ctc | projected | mono_dma | projected |
|---|---|---|---|---|---|---|
| 256x192@25 | 0.7950 / 0.7832 | 0.7944 / 0.7828 | 0.7765 / 0.7650 | 0.7759 / 0.7647 | 0.7443 / 0.7333 | 0.7437 / 0.7330 |
| 320x160@25 | 0.8282 / 0.8164 | 0.8281 / 0.8165 | 0.8092 / 0.7978 | 0.8092 / 0.7980 | 0.7757 / 0.7647 | 0.7756 / 0.7649 |
| 320x192@25 | 0.9857 / 0.9738 | 0.9861 / 0.9745 | 0.9647 / 0.9533 | 0.9652 / 0.9540 | 0.9245 / 0.9135 | 0.9251 / 0.9144 |
| 280x224@25 | 1.0088 / 0.9970 | 1.0087 / 0.9971 | 0.9876 / 0.9762 | 0.9874 / 0.9763 | 0.9464 / 0.9354 | 0.9464 / 0.9358 |
| 320x240@16.67 | 0.8269 / 0.8190 | 0.8273 / 0.8195 | 0.8054 / 0.7978 | 0.8050 / 0.7976 | 0.7717 / 0.7644 | 0.7716 / 0.7645 |
| 256x240@16.67 | 0.6678 / 0.6599 | 0.6681 / 0.6604 | 0.6483 / 0.6407 | 0.6479 / 0.6405 | 0.6213 / 0.6140 | 0.6210 / 0.6139 |

- Over 1.00: stereo 280x224@25 on a palette frame only (1.0088). On a pixels-only frame every target shape is under 1.00 in all three forms; stereo 280x224@25 has 0.30 percent of margin.
- Every figure is within 0.0009 of the projection. The mono_dma agreement is two differences cancelling: the steal is 14 T a sample where 8 was assumed (a 1.00784 against 1.00448), and the period is 0.426 percent longer than assumed.
- Not priced in the mono_dma column: the frame loop's own pointer reads cost about 91 T more on the DMA than on HL' (about three a frame, 0.02 percent).

### Largest admitted height at 25 fps, palette frame (pixels-only frame)

| width | stereo | mono_ctc | mono_dma | sitting 1b stereo | sitting 1b mono |
|---|---|---|---|---|---|
| 320 | 192 (195) | 196 (198) | 204 (208) | 190 (192) | 195 (196) |
| 280 | 219 (224) | 224 (226) | 235 (237) | 217 (219) | 223 (224) |
| 256 | 240 (244) | 246 (250) | 256 (256) | 238 (242) | 244 (246) |

### Attribution

- Handlers: stereo 104.26 T an interrupt, mono CTC 82.15 (expected 104.29 / 82.14; sitting 1b 114.29 / 92.14).
- RSEC' - 8192 = 133.73 T against 128 counted (open 101, slide call and ret 27): 5.73 over (sitting 1b 6.62 over the same count).
- ARSW' per clip against sitting 1b less the counted savings (pump, inline open, column train, the handler change through each sitting's measured factor): within 0.016 percent on 11 of 13 counted clips; 064 and 065 (stereo, 4 sound sectors, 1874 sound bytes) read 1010 and 923 T a frame under the prediction (0.073 and 0.083 percent). 072, 074 and 089 have no counted pump saving.
- Histograms: every token wait in RHST, RH39, AHST, AH39 (16 clips) and in MHST and RHST of session RD1 (8 clips) is in bin 1.

### Turbo read train (a finding, not a gate change)

- Turbo is there: TCHK read NR $07 back as $37 on all four captures, 64 spin reps took 1548 lines in turbo against 1829 (0.8464); TSPN / SPN0 0.8472 (the counted loop gives 22 / 26 = 0.8462).
- Usable: GO for the classic read shape. NSM0, TSTR, TSLO and TSUM equal the file's sums on 060, 063, 068 and 088; TSEC printed; no ERR; no step repeated.
- Cost: 16.00 T a byte in turbo (16.006, 15.999, 15.999, 15.999; one raster line is 0.007 T a byte). NSEC and TSEC read 8500.12 and 8500.12 / 8496.56 T a rep: the sector read with the open and the slide in turbo is 0 to 3.6 T shorter, not the 515 T that a 15 T `ini` and three shortened instructions would give. This contradicts the turbo document's INI row (16 to 15) for a read of the card's data port on this board.
- Timers: CTC period in turbo 1791.97 T (stereo) and 1791.96 (mono), expected 1792. Handler cost in turbo 104.28 and 82.18 T an interrupt, against 104.26 and 82.15 without it: no change.
- Projection, labelled as one: with the measured 16.00 T a byte, turbo reads change no target shape by more than 0.0003 (the one T a read or pass). Had the train run at 15 T a byte, 320x192@25 would read 0.9254 / 0.9141 (stereo), 0.9057 / 0.8948 (mono_ctc), 0.8680 / 0.8575 (mono_dma); that column is for reference and is not supported by the measurement.
- Not measured: the fast program in turbo, the prescaled DMA under turbo.

### RE-RUN request

- Bench rows: none (no BAD, SHORT, RUN or missing row, no O=01 on a timed row, no row 3 percent from its peers, no histogram count in bin 9 or above).
- Leg B step B.23 (PICK 68, GO, SPACE at 00:00:03, mono DMA): capture 19 logged a complete play (FRM 00FA/00FA, PASS 01, PLAY 01F0, LATE and URUN 0000). The stop of a GO on the DMA path is not in the log. A re-run of that one step, or the owner's word on what happened, settles it. The stop of a LOOP on the DMA path is in the log (B.22: 902 frames, pass 4).

### What does not match the model or the documents

1. DMA sample period 1799.64 T against 1792 (see "Pitch"); it differs by load by up to 0.59 T.
2. mono_dma frame rows scatter more than the CTC forms' and trip the sound-term rule: at 2 sound sectors the 25 fps clips (625 sound bytes: 066, 068, 069) sit +452 to +920 T over the model and 067 at -69, the 16.67 fps clips (937 bytes: 070, 071) -895 and -982. The same clips' CTC rows (ARSW) give d +0.23 and residuals within 119 T.
3. The sound section costs more under the DMA than the armed factor predicts: frame row' less pixel bytes and overhead is 19,405 T at 2 sound sectors and 28,818 at 3, against 18,976 and 27,806 on the CTC path, where the ratio of the armed factors (1.00784 / 1.04849) would give 18,240 and 26,728. About 1,170 and 2,090 T a frame are not accounted for; the DMA pointer read (91 T more than HL') is part of it.
4. The steal depends on the load: 10.0 T a sample under the spin, 14.0 under the sector read (the estimate was 8, range 6 to 16).
5. Turbo: `ini` on the card port measures 16.00 T a byte with the bit set, and the handlers cost the same with it.
6. B.23: the log shows a full play where the sheet has a stop (above).
7. 064 and 065 (stereo, 16.67 fps) are about 1,000 T a frame cheaper than sitting 1b less the counted savings.

## Playback (leg B)

### Captures and sheet steps

Captures are in sheet order. B.10 (MCTC) and B.14 (MDMA) play no clip and write no capture. SND: S stereo or non-raw, C mono from CTC 0, D mono from the zxnDMA. VAR: T column train, I inline, - non-raw.

| capture | step | clip | snd | var | row 23 | frm | pass | play | nom | late | maxl | urun | runs | chk | owner's note |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | B.3 GO | 004 | S | - | - | 002B/002B | 01 | 0055 | 0056 | 0000 | 0000 | 0000 | 00 | 006A6DA8 |  |
| 2 | B.4 GO | 060 | S | I | - | 00FA/00FA | 01 | 01EE | 01F4 | 0000 | 0000 | 0000 | 01 | 0051D039 |  |
| 3 | B.5 GO | 062 | S | T | - | 00FA/00FA | 01 | 01EE | 01F4 | 0000 | 0000 | 0000 | 01 | 0097F251 |  |
| 4 | B.6 GO | 063 | S | T | - | 00FA/00FA | 01 | 01F5 | 01F4 | 00F9 | 051C | 00F9 | 01 | 0089C024 |  |
| 5 | B.7 GO | 073 | S | I | - | 00FA/00FA | 01 | 01EE | 01F4 | 0000 | 0000 | 0000 | 01 | 00150062 |  |
| 6 | B.8 GO | 075 | S | I | - | 00F9/00F9 | 01 | 01EC | 01F2 | 0000 | 0000 | 0000 | 01 | 001521A3 |  |
| 7 | B.9 GO | 077 | S | I | - | 00C8/00C8 | 01 | 018B | 0190 | 0000 | 0000 | 0000 | 01 | 0046B5A3 |  |
| 8 | B.11 GO (MCTC) | 068 | C | T | - | 00FA/00FA | 01 | 01EE | 01F4 | 0000 | 0000 | 0000 | 01 | 008E2D49 |  |
| 9 | B.12 GO (MCTC) | 076 | C | I | - | 00F9/00F9 | 01 | 01EC | 01F2 | 0000 | 0000 | 0000 | 01 | 001521A3 |  |
| 10 | B.13 GO (MCTC) | 078 | C | I | - | 00C8/00C8 | 01 | 018B | 0190 | 0000 | 0000 | 0000 | 01 | 0046B5A3 |  |
| 11 | B.15 GO (MDMA) | 066 | D | I | - | 00FA/00FA | 01 | 01F0 | 01F4 | 0000 | 0000 | 0000 | 01 | 0051D039 |  |
| 12 | B.16 GO (MDMA) | 068 | D | T | - | 00FA/00FA | 01 | 01F0 | 01F4 | 0000 | 0000 | 0000 | 01 | 00917317 |  |
| 13 | B.17 GO (MDMA) | 069 | D | T | - | 00FA/00FA | 01 | 01F0 | 01F4 | 0000 | 0000 | 0000 | 01 | 0089C024 |  |
| 14 | B.18 GO (MDMA) | 074 | D | I | - | 0099/0099 | 01 | 01F1 | 01F3 | 0000 | 0000 | 0000 | 01 | 0050507E |  |
| 15 | B.19 GO (MDMA) | 076 | D | I | - | 00F9/00F9 | 01 | 01EE | 01F2 | 0000 | 0000 | 0000 | 01 | 001521A3 | "same" (pitch against B.12) |
| 16 | B.20 GO (MDMA) | 078 | D | I | - | 00C8/00C8 | 01 | 018D | 0190 | 0000 | 0000 | 0000 | 01 | 0046B5A3 | "same" (pitch against B.13) |
| 17 | B.21 GO (MDMA) | 088 | D | I | - | 00FA/00FA | 01 | 03E0 | 03E8 | 0000 | 0000 | 0000 | 01 | 004F2E31 |  |
| 18 | B.22 LOOP, SPACE | 066 | D | I | - | 0386/0386 | 04 | 06FC | 070C | 0000 | 0000 | 0000 | 01 | 00524447 |  |
| 19 | B.23 GO, SPACE | 068 | D | T | - | 00FA/00FA | 01 | 01F0 | 01F4 | 0000 | 0000 | 0000 | 01 | 0090A559 |  |
| 20 | B.24 GO | 004 | S | - | - | 002B/002B | 01 | 0055 | 0056 | 0000 | 0000 | 0000 | 00 | 006E7C60 |  |
| 21 | B.25 GO | 010 | S | - | - | 00FA/00FA | 01 | 01EE | 01F4 | 0000 | 0000 | 0000 | 01 | 0014C291 |  |
| 22 | B.26 GO | 080 | - | - | VID FMT? | - | - | - | - | - | - | - | - | - |  |

- Every capture with a report reads ERR=00 OP=00 POS=000000, RING=0000/0000/00, SNAP=00, pool 50 (playback.md).
- B.22 stopped 902 frames in (3 restarts, then 152 frames: banner about 00:00:06; the sheet asked for 00:00:05 after three restarts).
- B.23 logged all 250 frames (see RE-RUN request).
- B.26 (080): row 23 `VID FMT?`, no report rows, as the sheet expects; the capture's header reads `- -` (no session staged).

### Each clip's model verdict against the log

The script's "Playback (leg B)" table has every figure. All 18 scored captures agree with the DEBUG model:

- 063 (stereo 280x224@25, column train): DEBUG utilisation 1.0098, model late; logged LATE 00F9, URUN 00F9, PLAY 501 fields against 500.4 predicted (one ring wait; on time 493.6). Sitting 1b: PLAY 512. The Release gate puts 063 at 0.9970 on a pixels-only frame and 1.0088 on a palette frame; no Release leg was run.
- 062 (stereo 320x192@25): DEBUG utilisation 0.9863, model on time; logged LATE 0000, PLAY 494. Sitting 1b: late, PLAY 499.
- 068 on the CTC path 0.9656 and on the DMA path 0.9253; 069 on the DMA path 0.9475 (late at sitting 1b on the CTC path, PLAY 499); all on time.
- 060, 073, 075, 077 (stereo 256x192) 0.7934; 076, 078 on the CTC path 0.7750; 066, 076, 078 on the DMA path 0.7430; 074 0.4586; 088 0.3757: all on time.
- 004, 010 (other formats) and 080 (the refusal clip) are outside the raw model.

### 004

- B.3 (capture 1) and B.24 (capture 20, after the mono DMA clips and the B.23 play): FRM 002B/002B, PASS 01, FILL 001A, PLAY 0055, NOM 0056, LATE and URUN 0000, RUNS 00, pool 50 on both. CHK 006A6DA8 and 006E7C60 (they differ, as 004's two captures did at sitting 1b: 006A8424 and 006748B5).
- B.25 (010): FRM 00FA/00FA, PLAY 01EE, LATE and URUN 0000, RUNS 01, CHK 0014C291 (sitting 1b 001AAD66).
- No picture exception was reported at B.24 or B.25. CHK on these clips also sums bar bytes left by earlier clips, so it cannot show on its own that the engine was clean after a DMA session; R6 (MCPY) and the absence of a picture note are the evidence.

### CHK

- Clips without bars, full plays, CHK against the sum of the file's last two frames' pixels: 11 compared, 11 equal (060, 073, 075, 077 stereo; 076, 078 on the CTC path; 066, 074, 076, 078, 088 on the DMA path).
- Barred 320-surface clips are not compared: 062 0097F251; 063 0089C024; 068 008E2D49 (CTC), 00917317 and 0090A559 (DMA); 069 0089C024.

## Leg A log notes

- The first capture (060) has no LOG OK line; every later capture has one. A capture's LOG line is the previous step's status. The last step's own status is not in the file; no LOG ERR was reported.
- 16 NXBW captures of 15 rows and four #HIST lines; 8 NXBM captures of 15 rows and two #HIST lines; 4 NXBP captures of 12 rows; one NXBD capture of 9 rows. No NXB SHORT, RUN, GEO or NOTURBO marker, no O=01 walk mark on a timed row (MCN1-3 and MPTR carry O=01 as the base-read flag), every histogram sums to its row's reps.
- IDEN: O=12 (column train) on 061, 062, 063, 067, 068, 069; O=02 (inline program) on the rest; all with the H1C mark, as the fixture table gives.
- MTCK (R=00FA F=00FA) and MCPY repeat from clip to clip; they were read per capture.

The rest of this file is the script's output, unedited.

raw_fit: NXBENCH.TXT
timing: +3, 311 lines x 1824 T a field (parse.timing); T = (F x 311 + D) x 1824
CTC 0 period: 16 x 112 = 1792 T (AUD_CTC_CW16 prescaler, vidCtcTcNxvStereo[NR $11 = 0])
harness (nxv2_bench_rows, model 1c): card h = 88 T a rep, frame g = 220 T a frame; RD1 frame rep 633 T and 211 T on a row's first rep, both armed; RT1 card rep 175 T
model: T = Spix x 512 x tb x F + a x OV + Ssnd x tsnd + tf + P x tp + stall; OV = raw_frame_overhead (counted, unarmed); tb = 16 x a; period = samples x sample_t

## Sections

 1 #NXB 0836 NXBW clip 060 stereo 256x192@25, inline program: 15 rows, 4 histograms
 2 #NXB 0C4D NXBW clip 061 stereo 320x160@25, train program: 15 rows, 4 histograms
 3 #NXB 1036 NXBW clip 062 stereo 320x192@25, train program: 15 rows, 4 histograms
 4 #NXB 146A NXBW clip 063 stereo 280x224@25, train program: 15 rows, 4 histograms
 5 #NXB 17FD NXBW clip 064 stereo 320x240@16.67, inline program: 15 rows, 4 histograms
 6 #NXB 1B1F NXBW clip 065 stereo 256x240@16.67, inline program: 15 rows, 4 histograms
 7 #NXB 1DF3 NXBW clip 066 mono 256x192@25, inline program: 15 rows, 4 histograms
 8 #NXB 211D NXBW clip 067 mono 320x160@25, train program: 15 rows, 4 histograms
 9 #NXB 2424 NXBW clip 068 mono 320x192@25, train program: 15 rows, 4 histograms
10 #NXB 273C NXBW clip 069 mono 280x224@25, train program: 15 rows, 4 histograms
11 #NXB 2ABC NXBW clip 070 mono 320x240@16.67, inline program: 15 rows, 4 histograms
12 #NXB 2E0A NXBW clip 071 mono 256x240@16.67, inline program: 15 rows, 4 histograms
13 #NXB 30DD NXBW clip 072 stereo 320x256@12.5, inline program: 15 rows, 4 histograms
14 #NXB 33BD NXBW clip 074 mono 256x192@15.2588, inline program: 15 rows, 4 histograms
15 #NXB 36B8 NXBW clip 088 mono 256x192@12.5, inline program: 15 rows, 4 histograms
16 #NXB 3994 NXBW clip 089 stereo 256x192@20, inline program: 15 rows, 4 histograms
17 #NXB 3ED1 NXBM clip 066: 15 rows, 2 histograms
18 #NXB 43DB NXBM clip 067: 15 rows, 2 histograms
19 #NXB 4899 NXBM clip 068: 15 rows, 2 histograms
20 #NXB 4DB6 NXBM clip 069: 15 rows, 2 histograms
21 #NXB 52AF NXBM clip 070: 15 rows, 2 histograms
22 #NXB 57C7 NXBM clip 071: 15 rows, 2 histograms
23 #NXB 5C61 NXBM clip 074: 15 rows, 2 histograms
24 #NXB 61DF NXBM clip 088: 15 rows, 2 histograms
25 #NXB 6444 NXBD clip 10: old direct rows (9)
26 #NXB 6975 NXBP clip 060: 12 rows
27 #NXB 6E4B NXBP clip 063: 12 rows
28 #NXB 7281 NXBP clip 068: 12 rows
29 #NXB 768E NXBP clip 088: 12 rows

Anomalies (RE-RUN request): none

## Control: NXBD on 010 against the previous sitting

T a rep = (F x 311 + D) x 1824 / R, rows as printed.

| row | previous O R F D | T/rep | this sitting O R F D | T/rep | diff % |
|---|---|---|---|---|---|
| IDEN | 02 250 256 167 |  | 02 250 256 167 |  | equal |
| DSWP | 10 1 24 -20 | 13577856.00 | 10 1 24 -20 | 13577856.00 | +0.000 |
| ADSW | 10 1 27 -144 | 15053472.00 | 10 1 27 -144 | 15053472.00 | +0.000 |
| DTI0 | 00 128 2 9 | 8991.75 | 00 128 2 10 | 9006.00 | +0.158 |
| DTB0 | 00 128 4 126 | 19522.50 | 00 128 4 127 | 19536.75 | +0.073 |
| DTC0 | 00 128 2 59 | 9704.25 | 00 128 2 59 | 9704.25 | +0.000 |
| DTD0 | 00 128 2 123 | 10616.25 | 00 128 2 123 | 10616.25 | +0.000 |
| ADTI | 00 128 2 78 | 9975.00 | 00 128 3 -232 | 9989.25 | +0.143 |
| ADTC | 00 128 2 133 | 10758.75 | 00 128 2 133 | 10758.75 | +0.000 |

largest |difference| 0.158 percent (limit 0.5): PASS

## DMA mono sound: rows R1 to R6

| row | verdict | figures |
|---|---|---|
| R1 rate | GO | sample T by load MRSW 1799.41, MSPN 1799.51, MHST 1800.00; spread 0.033 percent (GO to 0.1); mean 1799.64 T, +0.426 percent from 1792 (limit 0.5) |
| R2 steal | GO | MSPN - SPN0 10.01 T a sample (9.97-10.09), MHST - RHST 13.99 (13.97-14.15); limit 16 |
| R3 card | GO | MSUM equal to the file's sum on 8 of 8 clips; ERR under the DMA: none; MHST bins equal to RHST's on every clip |
| R4 pointer | GO | MPTR on 8 clips: bad steps F [0], torn reads D [0], retried reads R 2-5 of 65535; flags ['01'] (bit 0 base read before the enable, bit 1 $8000 read, bit 2 out of range) |
| R5 ticks | GO | MTCK R (frameCounter change) [250] over F [250] raster wraps on 8 clips |
| R6 teardown | GO | MCPY / CPY0 0.9920-1.0000 (limit 1.02): CPY0 226176/228000 T, MCPY 226176 T a row |

| clip | sample T: MRSW | MSPN | MHST | samples: MRSW | MSPN | MHST | steal spin | steal hist | MHST/RHST | MSUM | file sum | MPTR O R F D | MCN O | MTCK R F | MCPY/CPY0 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 066 | 1798.901 | 1799.571 | 1800.174 | 7340 | 15008 | 10182 | 10.09 | 13.97 | 1.00782 | 070036AD | 070036AD | 01 3 0 0 | 01 01 01 | 250 250 | 0.9920 |
| 067 | 1799.890 | 1799.450 | 1799.998 | 7641 | 15008 | 10183 | 9.97 | 13.97 | 1.00782 | 06544C18 | 06544C18 | 01 2 0 0 | 01 01 01 | 250 250 | 0.9920 |
| 068 | 1799.640 | 1799.570 | 1799.998 | 9135 | 15007 | 10183 | 9.97 | 13.97 | 1.00782 | 07097B86 | 07097B86 | 01 3 0 0 | 01 01 01 | 250 250 | 0.9920 |
| 069 | 1799.436 | 1799.570 | 1799.821 | 9356 | 15007 | 10184 | 9.97 | 13.97 | 1.00782 | 065DC2AB | 065DC2AB | 01 3 0 0 | 01 01 01 | 250 250 | 0.9920 |
| 070 | 1799.778 | 1799.450 | 1800.000 | 11446 | 15008 | 10184 | 9.97 | 14.15 | 1.00792 | 0641949E | 0641949E | 01 4 0 0 | 01 01 01 | 250 250 | 1.0000 |
| 071 | 1799.593 | 1799.571 | 1799.821 | 9192 | 15008 | 10184 | 10.09 | 13.97 | 1.00782 | 0591F322 | 0591F322 | 01 3 0 0 | 01 01 01 | 250 250 | 0.9920 |
| 074 | 1798.906 | 1799.571 | 1800.174 | 7414 | 15008 | 10182 | 10.09 | 13.97 | 1.00782 | 06FA2D89 | 06FA2D89 | 01 5 0 0 | 01 01 01 | 250 250 | 1.0000 |
| 088 | 1799.159 | 1799.330 | 1799.998 | 7416 | 15009 | 10183 | 9.97 | 13.97 | 1.00782 | 06B1AB14 | 06B1AB14 | 01 3 0 0 | 01 01 01 | 250 250 | 1.0000 |

sample T = row T / the row's count (R + 65536 x F of its MCN row). Resolution of one figure: a raster line and one sample, 0.42 T on MRSW (the shortest row), 0.24 on MSPN, 0.36 on MHST.

## Pitch

- sample_t[mono_dma] = 1799.640 T: mean of 24 figures (MRSW, MSPN, MHST on 8 clips), range 1798.901-1800.174, standard deviation 0.348, standard error of the mean 0.071 T (0.0039 percent).
- by load: MRSW 1799.413 T, MSPN 1799.510 T, MHST 1799.998 T.
- pitch offset 1792 / sample_t - 1 = -0.425 percent = -7.37 cents (the DMA plays lower and slower than the CTC forms); rate 15558.7 Hz against 15625.0 Hz.
- over the 0.05 percent limit: an owner decision before the gate constants are adopted.
- period hypotheses, T a sample (excess over 1792): MRSW 1799.413 (+7.413); MSPN 1799.510 (+7.510); MHST 1799.998 (+7.998).
  - 1792 (the prescaler alone): MRSW +7.41 T, MSPN +7.51 T, MHST +8.00 T
  - 1799 (+7): MRSW +0.41 T, MSPN +0.51 T, MHST +1.00 T
  - 1800 (+8): MRSW -0.59 T, MSPN -0.49 T, MHST -0.00 T
  - 1824 (57 prescaler units of 32): MRSW -24.59 T, MSPN -24.49 T, MHST -24.00 T

## Constants

| form | a | from | tb = 16 a | tsnd | tf | tp | sample_t | clips |
|---|---|---|---|---|---|---|---|---|
| stereo | 1.06181 | mean ARSE / RSEC | 16.9890 | 9069.23 | 1438.24 | 13270.26 | 1792.000 | 060 061 062 063 064 065 072 089 |
| mono_ctc | 1.04849 | mean ARSE / RSEC | 16.7758 | 8830.15 | 1315.63 | 12799.30 | 1792.000 | 066 067 068 069 070 071 074 088 |
| mono_dma | 1.00784 | mean MHST / RHST | 16.1254 | 9412.87 | 579.51 | 12322.48 | 1799.640 | 066 067 068 069 070 071 074 088 |

- stereo points (clip, Ssnd, y = frame row' - Spix x 8192 x a - a x OV): 060 3 28625.7; 061 3 28596.6; 062 3 28701.5; 063 3 28758.7; 064 4 37751.4; 065 4 37679.0; 072 5 46883.1; 089 4 37517.7
- stereo tp per clip: 060 12831.9; 061 12346.1; 062 14163.2; 063 13437.9; 064 12345.9; 065 14405.6; 072 13074.1; 089 13557.3
- mono_ctc points (clip, Ssnd, y = frame row' - Spix x 8192 x a - a x OV): 066 2 18857.1; 067 2 18952.7; 068 2 18991.0; 069 2 19031.8; 070 2 19071.0; 071 2 18951.9; 074 3 27749.1; 088 3 27863.1
- mono_ctc tp per clip: 066 13978.6; 067 11589.4; 068 13262.0; 069 12425.2; 070 12784.8; 071 12783.7; 074 12905.8; 088 12665.0
- mono_dma points (clip, Ssnd, y = frame row' - Spix x 8192 x a - a x OV): 066 2 20325.1; 067 2 19336.7; 068 2 19857.2; 069 2 19978.9; 070 2 18510.2; 071 2 18423.4; 074 3 28647.1; 088 3 28989.1
- mono_dma tp per clip: 066 13472.5; 067 11154.6; 068 12767.7; 069 11962.6; 070 12290.8; 071 12290.5; 074 12434.9; 088 12206.3
- frame row': ARSW/16 - g x ARSW/RSWP (stereo, mono_ctc); (MRSW - 211 x a) / 16 - 633 x a (mono_dma). tp = (RFR0' - RSWP') x frame row' / RSWP', RFR0 and RSWP from the clip's NXBW capture.
- a by other rows, for comparison (not used): ASPN / SPN0 stereo 1.06177, mono_ctc 1.04805; AHST / RHST stereo 1.06181, mono_ctc 1.04803; mono_dma MSPN / SPN0 1.00559.
- one raster line on a 128-rep card row is 14.25 T a rep, 0.17 percent of a sector: the resolution of one ARSE / RSEC ratio.
- check of the count, used in no constant: mean RSEC' - 8192 - 101 (vr_sector_n's open) - 27 (the slide's call and ret) = +5.73 T over 16 clips.
- RAW_STALL_T = 23.38 T: highest occupied AHST bin 1 (clip 089), upper edge x ARSE/RSEC. One poll's wait by form (22 T x a): stereo 23.36, mono_ctc 23.07, mono_dma 22.17.

Paste form:

```
RAW_K = {
    "stereo": {
        "a": 1.06181,  # armed factor [ARSE, RSEC] 8 clips
        "tb": 16.9890,  # 16 x a
        "tsnd": 9069.23,  # sound sector [ARSW, RSWP, counted overhead] 8 clips
        "tf": 1438.24,  # frame remainder, same points
        "tp": 13270.26,  # palette sector [RFR0, RSWP, ARSW] 8 clips
    },
    "mono_ctc": {
        "a": 1.04849,  # armed factor [ARSE, RSEC] 8 clips
        "tb": 16.7758,  # 16 x a
        "tsnd": 8830.15,  # sound sector [ARSW, RSWP, counted overhead] 8 clips
        "tf": 1315.63,  # frame remainder, same points
        "tp": 12799.30,  # palette sector [RFR0, RSWP, ARSW] 8 clips
    },
    "mono_dma": {
        "a": 1.00784,  # armed factor [MHST, RHST] 8 clips
        "tb": 16.1254,  # 16 x a
        "tsnd": 9412.87,  # sound sector [MRSW, counted overhead] 8 clips
        "tf": 579.51,  # frame remainder, same points
        "tp": 12322.48,  # palette sector [RFR0, RSWP, MRSW] 8 clips
    },
}
RAW_SAMPLE_T = {"stereo": 1792, "mono_ctc": 1792, "mono_dma": 1799.64}
RAW_STALL_T = 23.38  # AHST bin 1 upper edge x ARSE/RSEC
```

## Residuals

residual = 100 x (frame row' - model) / model, pixels-only frame. Acceptance: every |residual| <= 1.0 percent; a train-against-inline pattern over 0.2 percent is a STOP.

| clip | form | program | Spix | Ssnd | sound B | OV T | frame row' | model | residual T | residual % |
|---|---|---|---|---|---|---|---|---|---|---|
| 060 | stereo | inline | 96 | 3 | 1250 | 11585 | 875970.4 | 875990.6 | -20 | -0.002 |
| 061 | stereo | train | 100 | 3 | 1250 | 13845 | 913134.4 | 913183.8 | -49 | -0.005 |
| 062 | stereo | train | 120 | 3 | 1250 | 16105 | 1089606.4 | 1089550.9 | +56 | +0.005 |
| 063 | stereo | train | 123 | 3 | 1250 | 15954 | 1115598.4 | 1115485.6 | +113 | +0.010 |
| 064 | stereo | inline | 150 | 4 | 1874 | 29694 | 1374036.4 | 1374000.2 | +36 | +0.003 |
| 065 | stereo | inline | 120 | 4 | 1874 | 23862 | 1106820.4 | 1106856.6 | -36 | -0.003 |
| 072 | stereo | inline | 160 | 5 | 2500 | 18945 | 1458738.4 | 1458639.7 | +99 | +0.007 |
| 089 | stereo | inline | 96 | 4 | 1562 | 11585 | 884862.4 | 885059.8 | -197 | -0.022 |
| 066 | mono_ctc | inline | 96 | 2 | 625 | 11585 | 855567.4 | 855686.3 | -119 | -0.014 |
| 067 | mono_ctc | train | 100 | 2 | 625 | 13845 | 892389.4 | 892412.7 | -23 | -0.003 |
| 068 | mono_ctc | train | 120 | 2 | 625 | 16105 | 1066581.4 | 1066566.3 | +15 | +0.001 |
| 069 | mono_ctc | train | 123 | 2 | 625 | 15954 | 1092231.4 | 1092175.6 | +56 | +0.005 |
| 070 | mono_ctc | inline | 150 | 2 | 937 | 29694 | 1338585.4 | 1338490.3 | +95 | +0.007 |
| 071 | mono_ctc | inline | 120 | 2 | 937 | 23862 | 1074675.4 | 1074699.4 | -24 | -0.002 |
| 074 | mono_ctc | inline | 96 | 3 | 1024 | 11585 | 864459.4 | 864516.4 | -57 | -0.007 |
| 088 | mono_ctc | inline | 96 | 3 | 1250 | 11585 | 864573.4 | 864516.4 | +57 | +0.007 |
| 066 | mono_dma | inline | 96 | 2 | 625 | 11585 | 824594.7 | 823674.9 | +920 | +0.112 |
| 067 | mono_dma | train | 100 | 2 | 625 | 13845 | 858908.7 | 858977.3 | -69 | -0.008 |
| 068 | mono_dma | train | 120 | 2 | 625 | 16105 | 1026830.7 | 1026378.8 | +452 | +0.044 |
| 069 | mono_dma | train | 123 | 2 | 625 | 15954 | 1051568.7 | 1050995.1 | +574 | +0.055 |
| 070 | mono_dma | inline | 150 | 2 | 937 | 29694 | 1286864.7 | 1287759.8 | -895 | -0.070 |
| 071 | mono_dma | inline | 120 | 2 | 937 | 23862 | 1033214.7 | 1034196.5 | -982 | -0.095 |
| 074 | mono_dma | inline | 96 | 3 | 1024 | 11585 | 832916.7 | 833087.7 | -171 | -0.021 |
| 088 | mono_dma | inline | 96 | 3 | 1250 | 11585 | 833258.7 | 833087.7 | +171 | +0.021 |

- stereo: largest |residual| 0.022 percent (clip 089); train clips mean +0.003 (3), inline -0.004 (5), train - inline +0.007 percent
- mono_ctc: largest |residual| 0.014 percent (clip 066); train clips mean +0.001 (3), inline -0.002 (5), train - inline +0.003 percent
- mono_dma: largest |residual| 0.112 percent (clip 066); train clips mean +0.030 (3), inline -0.011 (5), train - inline +0.041 percent

acceptance: PASS (largest |residual| 0.112 percent); variant pattern: PASS

## Sound term

pad-aware fit y = A + S x Ssnd + d x real bytes on each form's points (d: T a sound byte costs over a pad byte):

- stereo: A 1855.8, S 8621.0, d +0.75 T a sound byte, standard error 0.24 (condition number 15576; d determined); residuals +36 +65 -40 -97 +1 +74 -37 -0 T
- mono_ctc: A 1335.3, S 8738.0, d +0.23 T a sound byte, standard error 0.18 (condition number 5220; d determined); residuals +95 -0 -39 -79 -48 +71 +32 -32 T
- mono_dma: A 273.2, S 10849.5, d -3.52 T a sound byte, standard error 1.28 (condition number 5220; d determined); residuals -554 +435 -86 -207 +163 +249 +569 -569 T

gate sound term (Ssnd x tsnd + tf) against that fit, 256x192; err = gate - fit:

| form | fps | sound B | Ssnd | pad B | gate T | fit T | err T | err % of period | fitted pair |
|---|---|---|---|---|---|---|---|---|---|
| stereo | 30 | 1042 | 3 | 494 | 28646 | 28504 | +141 | +0.015 | no |
| stereo | 25 | 1250 | 3 | 286 | 28646 | 28661 | -15 | -0.001 | yes |
| stereo | 20 | 1562 | 4 | 486 | 37715 | 37518 | +198 | +0.014 | yes |
| stereo | 16.67 | 1874 | 4 | 174 | 37715 | 37753 | -38 | -0.002 | yes |
| stereo | 15.2588 | 2048 | 5 | 512 | 46784 | 46505 | +279 | +0.015 | no |
| stereo | 12.5 | 2500 | 5 | 60 | 46784 | 46846 | -61 | -0.003 | yes |
| stereo | 10.5 | 2976 | 6 | 96 | 55854 | 55826 | +28 | +0.001 | no |
| mono_ctc | 30 | 521 | 2 | 503 | 18976 | 18929 | +47 | +0.005 | no |
| mono_ctc | 25 | 625 | 2 | 399 | 18976 | 18952 | +23 | +0.002 | yes |
| mono_ctc | 20 | 781 | 2 | 243 | 18976 | 18988 | -12 | -0.001 | no |
| mono_ctc | 16.67 | 937 | 2 | 87 | 18976 | 19023 | -47 | -0.003 | yes |
| mono_ctc | 15.2588 | 1024 | 3 | 512 | 27806 | 27781 | +26 | +0.001 | yes |
| mono_ctc | 12.5 | 1250 | 3 | 286 | 27806 | 27832 | -26 | -0.001 | yes |
| mono_ctc | 10.5 | 1488 | 3 | 48 | 27806 | 27885 | -79 | -0.003 | no |
| mono_dma | 30 | 521 | 2 | 503 | 19405 | 20138 | -732 | -0.078 | no |
| mono_dma | 25 | 625 | 2 | 399 | 19405 | 19771 | -366 | -0.033 | yes |
| mono_dma | 20 | 781 | 2 | 243 | 19405 | 19222 | +183 | +0.013 | no |
| mono_dma | 16.67 | 937 | 2 | 87 | 19405 | 18673 | +732 | +0.043 | yes |
| mono_dma | 15.2588 | 1024 | 3 | 512 | 28818 | 29216 | -398 | -0.022 | yes |
| mono_dma | 12.5 | 1250 | 3 | 286 | 28818 | 28420 | +398 | +0.018 | yes |
| mono_dma | 10.5 | 1488 | 3 | 48 | 28818 | 27582 | +1236 | +0.046 | no |

sound-term rule (|d| <= 3.0 T a sound byte in each form, every layout within 0.15 percent of the period): FAIL (largest |d| 3.52 T, largest |err| 0.078 percent)

## Utilisation of the target shapes

util = (model frame + glue 1138.7 T) / (samples x sample_t). Projected: the figure made before the sitting, which took 1792 T a sample in every form. Stall: one poll's wait added.

| shape | form | program | OV T | model T, palette | period T | util palette | projected | util pixels-only | projected | pixels-only with stall |
|---|---|---|---|---|---|---|---|---|---|---|
| 256x192@25 | stereo | inline | 11585 | 890400 | 1120000 | 0.7950 | 0.7944 | 0.7832 | 0.7828 | 0.7832 |
| 256x192@25 | mono_ctc | inline | 11585 | 869624 | 1120000 | 0.7765 | 0.7759 | 0.7650 | 0.7647 | 0.7650 |
| 256x192@25 | mono_dma | inline | 11585 | 837136 | 1124775 | 0.7443 | 0.7437 | 0.7333 | 0.7330 | 0.7333 |
| 320x160@25 | stereo | train | 13845 | 927593 | 1120000 | 0.8282 | 0.8281 | 0.8164 | 0.8165 | 0.8164 |
| 320x160@25 | mono_ctc | train | 13845 | 906351 | 1120000 | 0.8092 | 0.8092 | 0.7978 | 0.7980 | 0.7978 |
| 320x160@25 | mono_dma | train | 13845 | 872439 | 1124775 | 0.7757 | 0.7756 | 0.7647 | 0.7649 | 0.7647 |
| 320x192@25 | stereo | train | 16105 | 1103960 | 1120000 | 0.9857 | 0.9861 | 0.9738 | 0.9745 | 0.9739 |
| 320x192@25 | mono_ctc | train | 16105 | 1080504 | 1120000 | 0.9647 | 0.9652 | 0.9533 | 0.9540 | 0.9533 |
| 320x192@25 | mono_dma | train | 16105 | 1039840 | 1124775 | 0.9245 | 0.9251 | 0.9135 | 0.9144 | 0.9136 |
| 280x224@25 | stereo | train | 15954 | 1129895 | 1120000 | 1.0088 | 1.0087 | 0.9970 | 0.9971 | 0.9970 |
| 280x224@25 | mono_ctc | train | 15954 | 1106114 | 1120000 | 0.9876 | 0.9874 | 0.9762 | 0.9763 | 0.9762 |
| 280x224@25 | mono_dma | train | 15954 | 1064456 | 1124775 | 0.9464 | 0.9464 | 0.9354 | 0.9358 | 0.9354 |
| 320x240@16.67 | stereo | inline | 29694 | 1388409 | 1679104 | 0.8269 | 0.8273 | 0.8190 | 0.8195 | 0.8190 |
| 320x240@16.67 | mono_ctc | inline | 29694 | 1352428 | 1679104 | 0.8054 | 0.8050 | 0.7978 | 0.7976 | 0.7978 |
| 320x240@16.67 | mono_dma | inline | 29694 | 1301221 | 1686263 | 0.7717 | 0.7716 | 0.7644 | 0.7645 | 0.7644 |
| 256x240@16.67 | stereo | inline | 23862 | 1121266 | 1679104 | 0.6678 | 0.6681 | 0.6599 | 0.6604 | 0.6599 |
| 256x240@16.67 | mono_ctc | inline | 23862 | 1088637 | 1679104 | 0.6483 | 0.6479 | 0.6407 | 0.6405 | 0.6407 |
| 256x240@16.67 | mono_dma | inline | 23862 | 1047658 | 1686263 | 0.6213 | 0.6210 | 0.6140 | 0.6139 | 0.6140 |

stereo over 1.00: 280x224@25 palette frame 1.0088
mono_ctc over 1.00: none
mono_dma over 1.00: none

## Largest admitted height at 25 fps

Heights 256 down to 1, util <= 1.00, glue added, F = 1.0, each height on the program raw_variant names for it.

| width | form | palette frame: height | util | pixels-only frame: height | util |
|---|---|---|---|---|---|
| 320 | stereo | 192 | 0.9857 | 195 | 0.9995 |
| 320 | mono_ctc | 196 | 0.9978 | 198 | 0.9942 |
| 320 | mono_dma | 204 | 0.9934 | 208 | 0.9971 |
| 280 | stereo | 219 | 0.9942 | 224 | 0.9970 |
| 280 | mono_ctc | 224 | 0.9876 | 226 | 0.9928 |
| 280 | mono_dma | 235 | 0.9995 | 237 | 0.9960 |
| 256 | stereo | 240 | 0.9930 | 244 | 0.9971 |
| 256 | mono_ctc | 246 | 0.9955 | 250 | 0.9996 |
| 256 | mono_dma | 256 | 0.9825 | 256 | 0.9715 |

## Budget of a 320x192@25 palette frame

| term | stereo T | % | mono_ctc T | % | mono_dma T | % |
|---|---|---|---|---|---|---|
| pixel bytes, Spix x 512 x tb | 1043804 | 93.20 | 1030704 | 92.03 | 990742 | 88.08 |
| overhead, a x OV | 17100 | 1.53 | 16886 | 1.51 | 16231 | 1.44 |
| sound sectors, Ssnd x tsnd | 27208 | 2.43 | 17660 | 1.58 | 18826 | 1.67 |
| frame remainder, tf | 1438 | 0.13 | 1316 | 0.12 | 580 | 0.05 |
| palette sector, tp | 13270 | 1.18 | 12799 | 1.14 | 12322 | 1.10 |
| glue | 1139 | 0.10 | 1139 | 0.10 | 1139 | 0.10 |
| total | 1103960 | 98.57 | 1080504 | 96.47 | 1039840 | 92.45 |
| period | 1120000 | 100.00 | 1120000 | 100.00 | 1124775 | 100.00 |

## Attribution

- handler, raw stereo (ASPN, stereo clips): 104.26 T an interrupt (8 clips, 104.26-104.26); counted 104 T on the common path
- handler, raw mono CTC (ASPN, mono clips): 82.15 T an interrupt (8 clips, 82.03-82.26); counted 82 T on the common path
- handler, existing video_ctc_isr_stereo (OSPN): 175.24 T (16 clips)
- DMA steal a sample: 10.01 T under the spin, 13.99 T under the binned sector read; armed factor from the pair MHST / RHST 1.00784, from MSPN / SPN0 1.00559

frame row' per clip against the previous sitting (model 1b) less the counted unarmed savings U: pump (by sound layout), inline open (Spix - 1) x 15 - 100, column train (the inline program's OV less this program's). Predicted = (ARSW'_prev / A_prev - U) x A, A = 1 / (1 - handler / 1792) from each sitting's ASPN.

| clip | form | program | ARSW' previous | pump | open | train | predicted | measured ARSW' | measured - predicted T | % |
|---|---|---|---|---|---|---|---|---|---|---|
| 060 | stereo | inline | 886011.6 | 3040 | 1325 | 0 | 876111.1 | 875970.4 | -141 | -0.016 |
| 061 | stereo | train | 934005.7 | 3040 | 1385 | 9929 | 913213.8 | 913134.4 | -79 | -0.009 |
| 062 | stereo | train | 1111275.7 | 3040 | 1685 | 9389 | 1089685.0 | 1089606.4 | -79 | -0.007 |
| 063 | stereo | train | 1137039.7 | 3040 | 1730 | 8990 | 1115671.8 | 1115598.4 | -73 | -0.007 |
| 064 | stereo | inline | 1389777.6 | 3960 | 2135 | 0 | 1375046.1 | 1374036.4 | -1010 | -0.073 |
| 065 | stereo | inline | 1120395.6 | 3960 | 1685 | 0 | 1107743.0 | 1106820.4 | -923 | -0.083 |
| 066 | mono | inline | 864240.6 | 2080 | 1325 | 0 | 855623.1 | 855567.4 | -56 | -0.007 |
| 067 | mono | train | 911778.6 | 2080 | 1385 | 9929 | 892414.4 | 892389.4 | -25 | -0.003 |
| 068 | mono | train | 1086654.6 | 2080 | 1685 | 9389 | 1066520.3 | 1066581.4 | +61 | +0.006 |
| 069 | mono | train | 1112076.6 | 2080 | 1730 | 8990 | 1092164.8 | 1092231.4 | +67 | +0.006 |
| 070 | mono | inline | 1351362.6 | 2370 | 2135 | 0 | 1338746.4 | 1338585.4 | -161 | -0.012 |
| 071 | mono | inline | 1085400.6 | 2370 | 1685 | 0 | 1074809.8 | 1074675.4 | -134 | -0.013 |
| 072 | stereo | inline | 1476417.6 | not counted | 2285 | 0 | - | 1458738.4 | - | - |
| 074 | mono | inline | 873930.6 | not counted | 1325 | 0 | - | 864459.4 | - | - |
| 088 | mono | inline | 874386.6 | 3040 | 1325 | 0 | 864703.6 | 864573.4 | -130 | -0.015 |
| 089 | stereo | inline | 896157.6 | not counted | 1325 | 0 | - | 884862.4 | - | - |

largest |measured - predicted| 0.083 percent

## Turbo read train (NR $07 bit 2 at 28 MHz): a measurement, not a gate input

| clip | TCHK O R F D | F/R | active | TSPN/SPN0 | CTC period in turbo | handler in turbo | NSEC T/rep | TSEC T/rep | NSEC - TSEC | T a byte in turbo | sums against the file | ERR | not printed |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 060 | 37 1829 1548 3 | 0.8464 | yes | 0.8472 | 1792.04 | 104.28 | 8500.12 | 8500.12 | +0.00 | 16.006 | equal (NSM0 TSTR TSLO TSUM) | 00 | none |
| 063 | 37 1829 1548 3 | 0.8464 | yes | 0.8472 | 1791.90 | 104.28 | 8500.12 | 8496.56 | +3.56 | 15.999 | equal (NSM0 TSTR TSLO TSUM) | 00 | none |
| 068 | 37 1829 1548 3 | 0.8464 | yes | 0.8472 | 1792.03 | 82.19 | 8500.12 | 8496.56 | +3.56 | 15.999 | equal (NSM0 TSTR TSLO TSUM) | 00 | none |
| 088 | 37 1829 1548 3 | 0.8464 | yes | 0.8472 | 1791.90 | 82.18 | 8500.12 | 8496.56 | +3.56 | 15.999 | equal (NSM0 TSTR TSLO TSUM) | 00 | none |

- is turbo there: TCHK active on 4 of 4 captures; TSPN / SPN0 0.8472, the counted loop gives 0.8462 (22 / 26 T) before the rep's harness.
- read train usable (the classic read shape: vr_sector_n and the slide): GO - NSM0, TSTR, TSLO and TSUM equal the file's sums, TSEC printed and no ERR on 4 of 4 captures.
- T a byte in turbo = 16 - (NSEC - TSEC - 3) / 512 = 16.001 (15.999-16.006); one raster line on a 512-rep row is 0.007 T a byte. Expected 15.00: NOT within 0.05 - the sector read is not shorter in turbo by the 512 T a 15 T ini would save.
- stereo handler armed in turbo (TCTC, TCN1 2 ring byte(s) a period): CTC period 1791.97 T (expected 1792); handler 104.28 T an interrupt in turbo against 104.26 measured without it (ASPN) and 104 counted.
- mono handler armed in turbo (TCTC, TCN1 1 ring byte(s) a period): CTC period 1791.96 T (expected 1792); handler 82.18 T an interrupt in turbo against 82.15 measured without it (ASPN) and 82 counted.

Projection, not a measurement: this sitting's model with every ini byte (pixel, sound, pad and palette sectors) at a turbo T a byte, a slide read and a period pass 27 -> 26 T, a taken page check 67 -> 66 T, 3 T a sound or palette sector; handlers and the DMA steal unchanged. Two columns: the measured 16.001 T a byte, and 15 T a byte for reference.

| shape | form | frame | util now | turbo, measured T a byte | turbo, 15 T a byte |
|---|---|---|---|---|---|
| 256x192@25 | stereo | palette | 0.7950 | 0.7949 | 0.7464 |
| 256x192@25 | stereo | pixels | 0.7832 | 0.7831 | 0.7350 |
| 256x192@25 | mono_ctc | palette | 0.7765 | 0.7764 | 0.7289 |
| 256x192@25 | mono_ctc | pixels | 0.7650 | 0.7650 | 0.7180 |
| 256x192@25 | mono_dma | palette | 0.7443 | 0.7442 | 0.6988 |
| 256x192@25 | mono_dma | pixels | 0.7333 | 0.7333 | 0.6883 |
| 320x160@25 | stereo | palette | 0.8282 | 0.8282 | 0.7777 |
| 320x160@25 | stereo | pixels | 0.8164 | 0.8164 | 0.7663 |
| 320x160@25 | mono_ctc | palette | 0.8092 | 0.8092 | 0.7598 |
| 320x160@25 | mono_ctc | pixels | 0.7978 | 0.7978 | 0.7489 |
| 320x160@25 | mono_dma | palette | 0.7757 | 0.7757 | 0.7284 |
| 320x160@25 | mono_dma | pixels | 0.7647 | 0.7647 | 0.7179 |
| 320x192@25 | stereo | palette | 0.9857 | 0.9857 | 0.9254 |
| 320x192@25 | stereo | pixels | 0.9738 | 0.9738 | 0.9141 |
| 320x192@25 | mono_ctc | palette | 0.9647 | 0.9647 | 0.9057 |
| 320x192@25 | mono_ctc | pixels | 0.9533 | 0.9533 | 0.8948 |
| 320x192@25 | mono_dma | palette | 0.9245 | 0.9245 | 0.8680 |
| 320x192@25 | mono_dma | pixels | 0.9135 | 0.9135 | 0.8575 |
| 280x224@25 | stereo | palette | 1.0088 | 1.0088 | 0.9472 |
| 280x224@25 | stereo | pixels | 0.9970 | 0.9970 | 0.9358 |
| 280x224@25 | mono_ctc | palette | 0.9876 | 0.9876 | 0.9272 |
| 280x224@25 | mono_ctc | pixels | 0.9762 | 0.9762 | 0.9162 |
| 280x224@25 | mono_dma | palette | 0.9464 | 0.9464 | 0.8885 |
| 280x224@25 | mono_dma | pixels | 0.9354 | 0.9354 | 0.8780 |
| 320x240@16.67 | stereo | palette | 0.8269 | 0.8266 | 0.7764 |
| 320x240@16.67 | stereo | pixels | 0.8190 | 0.8187 | 0.7688 |
| 320x240@16.67 | mono_ctc | palette | 0.8054 | 0.8052 | 0.7562 |
| 320x240@16.67 | mono_ctc | pixels | 0.7978 | 0.7976 | 0.7489 |
| 320x240@16.67 | mono_dma | palette | 0.7717 | 0.7714 | 0.7246 |
| 320x240@16.67 | mono_dma | pixels | 0.7644 | 0.7641 | 0.7176 |
| 256x240@16.67 | stereo | palette | 0.6678 | 0.6676 | 0.6271 |
| 256x240@16.67 | stereo | pixels | 0.6599 | 0.6597 | 0.6195 |
| 256x240@16.67 | mono_ctc | palette | 0.6483 | 0.6481 | 0.6088 |
| 256x240@16.67 | mono_ctc | pixels | 0.6407 | 0.6405 | 0.6015 |
| 256x240@16.67 | mono_dma | palette | 0.6213 | 0.6211 | 0.5834 |
| 256x240@16.67 | mono_dma | pixels | 0.6140 | 0.6138 | 0.5764 |

## Playback (leg B)

Gate util: Release instructions, palette frame, one poll's stall, glue. DEBUG util: pixels-only frame + glue + the plain DEBUG work of a late frame's path (leg B runs the DEBUG build), over samples x sample_t. Model on time = DEBUG util <= 1.00; logged on time = LATE 0000 and URUN 0000. On-time PLAY = frames x samples x sample_t / 567264 (fields); predicted PLAY from ring_play (all-or-nothing feed).

| capture | clip | SND | VAR | form | program | frames | gate util | DEBUG util | model on time | LATE | URUN | logged on time | agree | PLAY | on-time PLAY | predicted PLAY | waits | CHK | file sum |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 2 | 060 | S | I | stereo | inline | 250 | 0.7950 | 0.7934 | yes | 0000 | 0000 | yes | yes | 494 | 493.6 | 493.6 | 0 | 0051D039 | 0051D039 |
| 3 | 062 | S | T | stereo | train | 250 | 0.9857 | 0.9863 | yes | 0000 | 0000 | yes | yes | 494 | 493.6 | 493.6 | 0 | 0097F251 | - |
| 4 | 063 | S | T | stereo | train | 250 | 1.0089 | 1.0098 | no | 00F9 | 00F9 | no | yes | 501 | 493.6 | 500.4 | 1 | 0089C024 | - |
| 5 | 073 | S | I | stereo | inline | 250 | 0.7950 | 0.7934 | yes | 0000 | 0000 | yes | yes | 494 | 493.6 | 493.6 | 0 | 00150062 | 00150062 |
| 6 | 075 | S | I | stereo | inline | 249 | 0.7950 | 0.7934 | yes | 0000 | 0000 | yes | yes | 492 | 491.6 | 491.6 | 0 | 001521A3 | 001521A3 |
| 7 | 077 | S | I | stereo | inline | 200 | 0.7950 | 0.7934 | yes | 0000 | 0000 | yes | yes | 395 | 394.9 | 394.9 | 0 | 0046B5A3 | 0046B5A3 |
| 8 | 068 | C | T | mono_ctc | train | 250 | 0.9648 | 0.9656 | yes | 0000 | 0000 | yes | yes | 494 | 493.6 | 493.6 | 0 | 008E2D49 | - |
| 9 | 076 | C | I | mono_ctc | inline | 249 | 0.7765 | 0.7750 | yes | 0000 | 0000 | yes | yes | 492 | 491.6 | 491.6 | 0 | 001521A3 | 001521A3 |
| 10 | 078 | C | I | mono_ctc | inline | 200 | 0.7765 | 0.7750 | yes | 0000 | 0000 | yes | yes | 395 | 394.9 | 394.9 | 0 | 0046B5A3 | 0046B5A3 |
| 11 | 066 | D | I | mono_dma | inline | 250 | 0.7443 | 0.7430 | yes | 0000 | 0000 | yes | yes | 496 | 495.7 | 495.7 | 0 | 0051D039 | 0051D039 |
| 12 | 068 | D | T | mono_dma | train | 250 | 0.9245 | 0.9253 | yes | 0000 | 0000 | yes | yes | 496 | 495.7 | 495.7 | 0 | 00917317 | - |
| 13 | 069 | D | T | mono_dma | train | 250 | 0.9464 | 0.9475 | yes | 0000 | 0000 | yes | yes | 496 | 495.7 | 495.7 | 0 | 0089C024 | - |
| 14 | 074 | D | I | mono_dma | inline | 153 | 0.4594 | 0.4586 | yes | 0000 | 0000 | yes | yes | 497 | 497.0 | 497.0 | 0 | 0050507E | 0050507E |
| 15 | 076 | D | I | mono_dma | inline | 249 | 0.7443 | 0.7430 | yes | 0000 | 0000 | yes | yes | 494 | 493.7 | 493.7 | 0 | 001521A3 | 001521A3 |
| 16 | 078 | D | I | mono_dma | inline | 200 | 0.7443 | 0.7430 | yes | 0000 | 0000 | yes | yes | 397 | 396.6 | 396.6 | 0 | 0046B5A3 | 0046B5A3 |
| 17 | 088 | D | I | mono_dma | inline | 250 | 0.3763 | 0.3757 | yes | 0000 | 0000 | yes | yes | 992 | 991.4 | 991.4 | 0 | 004F2E31 | 004F2E31 |
| 18 | 066 | D | I | mono_dma | inline | 902 | 0.7443 | 0.7430 | yes | 0000 | 0000 | yes | yes | 1788 | 1788.5 | 1788.5 | 0 | 00524447 | partial or looped play |
| 19 | 068 | D | T | mono_dma | train | 250 | 0.9245 | 0.9253 | yes | 0000 | 0000 | yes | yes | 496 | 495.7 | 495.7 | 0 | 0090A559 | - |

- capture 1 clip 004: outside the raw model (FRM 002B/002B PLAY 0055 LATE 0000 URUN 0000 RUNS 00 CHK 006A6DA8)
- capture 20 clip 004: outside the raw model (FRM 002B/002B PLAY 0055 LATE 0000 URUN 0000 RUNS 00 CHK 006E7C60)
- capture 21 clip 010: outside the raw model (FRM 00FA/00FA PLAY 01EE LATE 0000 URUN 0000 RUNS 01 CHK 0014C291)
- mono DMA clips the DEBUG model puts on time that logged LATE or URUN: none
- CHK against the file's last two frames' pixel sum, full plays of clips without bars: 11 compared, mismatches: none

Sample period implied by PLAY on the on-time plays (PLAY x 567264 / samples played; PLAY counts whole fields, so each figure is good to about one field):

| capture | clip | form | frames | PLAY | implied sample T | one field is |
|---|---|---|---|---|---|---|
| 2 | 060 | stereo | 250 | 494 | 1793.46 | 3.63 T |
| 3 | 062 | stereo | 250 | 494 | 1793.46 | 3.63 T |
| 5 | 073 | stereo | 250 | 494 | 1793.46 | 3.63 T |
| 6 | 075 | stereo | 249 | 492 | 1793.37 | 3.65 T |
| 7 | 077 | stereo | 200 | 395 | 1792.55 | 4.54 T |
| 8 | 068 | mono_ctc | 250 | 494 | 1793.46 | 3.63 T |
| 9 | 076 | mono_ctc | 249 | 492 | 1793.37 | 3.65 T |
| 10 | 078 | mono_ctc | 200 | 395 | 1792.55 | 4.54 T |
| 11 | 066 | mono_dma | 250 | 496 | 1800.72 | 3.63 T |
| 12 | 068 | mono_dma | 250 | 496 | 1800.72 | 3.63 T |
| 13 | 069 | mono_dma | 250 | 496 | 1800.72 | 3.63 T |
| 14 | 074 | mono_dma | 153 | 497 | 1799.49 | 3.62 T |
| 15 | 076 | mono_dma | 249 | 494 | 1800.66 | 3.65 T |
| 16 | 078 | mono_dma | 200 | 397 | 1801.63 | 4.54 T |
| 17 | 088 | mono_dma | 250 | 992 | 1800.72 | 1.82 T |
| 18 | 066 | mono_dma | 902 | 1788 | 1799.15 | 1.01 T |
| 19 | 068 | mono_dma | 250 | 496 | 1800.72 | 3.63 T |
- stereo: mean implied sample T 1793.26 (weighted by play length 1793.29) over 5 plays; the fit uses 1792.00
- mono_ctc: mean implied sample T 1793.13 (weighted by play length 1793.17) over 3 plays; the fit uses 1792.00
- mono_dma: mean implied sample T 1800.51 (weighted by play length 1800.22) over 9 plays; the fit uses 1799.64

## Histograms (summed over clips)

bin k counts token waits of 2^(k-1) to 2^k - 1 $FF polls (bin 0: the token on the first read; bin 9: 256 or more); n polls wait 22 + 47 x (n - 1) T unarmed, that x ARSE/RSEC armed (wait shape inline).

| histogram | bin | polls | wait T | count |
|---|---|---|---|---|
| AHST stereo | 1 | 1-1 | 23.4-23.4 | 16384 |
| AHST stereo | all | | | 16384 |
| AHST mono | 1 | 1-1 | 23.1-23.1 | 16384 |
| AHST mono | all | | | 16384 |
| RHST | 1 | 1-1 | 22.0-22.0 | 32768 |
| RHST | all | | | 32768 |
| RH39 | 1 | 1-1 | 22.0-22.0 | 32768 |
| RH39 | all | | | 32768 |
| AH39 stereo | 1 | 1-1 | 23.4-23.4 | 16384 |
| AH39 stereo | all | | | 16384 |
| AH39 mono | 1 | 1-1 | 23.1-23.1 | 16384 |
| AH39 mono | all | | | 16384 |

First poll at the benched image's production spacing (RHST/AHST: 11 + 7 x VR_POLL_PAD_N T after CRC 2; the log does not record VR_POLL_PAD_N) against the prototype's 39 T (RH39/AH39), the same clips, mean $FF polls a wait (bins at their mean): unarmed 1.000 against 1.000 (16 clips); armed stereo 1.000 against 1.000 (8 clips); armed mono 1.000 against 1.000 (8 clips). Used in no constant; the wait T columns above count from poll 1 for both.

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
- peers RSEC (all clips)       16 clips, largest deviation 0.17%
- peers RCOL (all clips)       16 clips, largest deviation 0.16%
- peers RHST (all clips)       16 clips, largest deviation 0.00%
- peers SPN0 (all clips)       16 clips, largest deviation 0.01%
- peers OSPN (all clips)       16 clips, largest deviation 0.00%
- peers RHST polls (all clips) 16 clips, largest deviation 0.00%
- peers ARSE (stereo)           8 clips, largest deviation 0.00%
- peers ARCO (stereo)           8 clips, largest deviation 0.15%
- peers AHST (stereo)           8 clips, largest deviation 0.00%
- peers ASPN (stereo)           8 clips, largest deviation 0.00%
- peers AHST polls (stereo)     8 clips, largest deviation 0.00%
- peers ARSE (mono)             8 clips, largest deviation 0.00%
- peers ARCO (mono)             8 clips, largest deviation 0.00%
- peers AHST (mono)             8 clips, largest deviation 0.01%
- peers ASPN (mono)             8 clips, largest deviation 0.01%
- peers AHST polls (mono)       8 clips, largest deviation 0.00%
- order RSWP/16 < ARSW/16      16/16 clips
- order RSWP/16 < RFR0         16/16 clips
- peers handler (stereo)        8 clips, largest deviation 0.00%
- peers handler (mono)          8 clips, largest deviation 0.14%
- peers NXBM CPY0               8 clips, largest deviation 0.80%
- peers NXBM SPN0               8 clips, largest deviation 0.00%
- peers NXBM MSPN               8 clips, largest deviation 0.01%
- peers NXBM MHST               8 clips, largest deviation 0.01%
- peers NXBM RHST               8 clips, largest deviation 0.00%
- peers NXBM MCPY               8 clips, largest deviation 0.00%
- peers NXBM sample T, MRSW     8 clips, largest deviation 0.03%
- peers NXBM sample T, MSPN     8 clips, largest deviation 0.01%
- peers NXBM sample T, MHST     8 clips, largest deviation 0.01%
- peers NXBP SPN0               4 clips, largest deviation 0.01%
- peers NXBP TSPN               4 clips, largest deviation 0.00%
- peers NXBP TCTC (2 ch)        2 clips, largest deviation 0.00%
- peers NXBP TCTC (1 ch)        2 clips, largest deviation 0.00%
- peers NXBP NSEC               4 clips, largest deviation 0.00%
- peers NXBP TSEC               4 clips, largest deviation 0.04%
- walk marks (O=01): none

RD1 histograms (NXBM), summed over 8 clips: MHST bin 1 = 16384; RHST bin 1 = 16384

## Decoded rows

T/rep = (F x 311 + D) x 1824 / R. Primed (harness removed): RSEC' = RSEC - h, RCOL' = RCOL - h, ARSE' = ARSE - h x ARSE/RSEC, ARCO' = ARCO - h x ARCO/RCOL, RSWP' = RSWP/16 - g, ARSW' = ARSW/16 - g x ARSW/RSWP, RFR0' = RFR0 - g.

clip 060 stereo 256x192@25: Spix 96, Ssnd 3, C 0 (section 1)

| tag | O | R | F | D | lines | T | T/rep | primed |
|---|---|---|---|---|---|---|---|---|
| IDEN | 02 | 250 | 256 | 192 | | | | |
| RFR0 | 00 | 1 | 1 | 148 | 459 | 837216 | 837216.00 | 836996.00 |
| RSWP | 00 | 16 | 23 | 85 | 7238 | 13202112 | 825132.00 | 824912.00 |
| ARSW | 00 | 16 | 25 | -89 | 7686 | 14019264 | 876204.00 | 875970.38 |
| RSEC | 00 | 128 | 2 | -31 | 591 | 1077984 | 8421.75 | 8333.75 |
| RCOL | 00 | 128 | 2 | -10 | 612 | 1116288 | 8721.00 | 8633.00 |
| RHST | 00 | 2048 | 31 | -7 | 9634 | 17572416 | 8580.28 | - |
| RH39 | 00 | 2048 | 31 | 17 | 9658 | 17616192 | 8601.66 | - |
| SPN0 | 00 | 512 | 47 | 17 | 14634 | 26692416 | 52133.62 | - |
| ARSE | 00 | 128 | 2 | 5 | 627 | 1143648 | 8934.75 | 8841.39 |
| ARCO | 00 | 128 | 2 | 28 | 650 | 1185600 | 9262.50 | 9169.04 |
| AHST | 00 | 2048 | 33 | -33 | 10230 | 18659520 | 9111.09 | - |
| AH39 | 00 | 2048 | 33 | -8 | 10255 | 18705120 | 9133.36 | - |
| ASPN | 00 | 512 | 50 | -12 | 15538 | 28341312 | 55354.12 | - |
| OSPN | 00 | 512 | 52 | 48 | 16220 | 29585280 | 57783.75 | - |

#HIST RHST: bin 1 = 2048

#HIST RH39: bin 1 = 2048

#HIST AHST: bin 1 = 2048

#HIST AH39: bin 1 = 2048

clip 061 stereo 320x160@25: Spix 100, Ssnd 3, C 320 (section 2)

| tag | O | R | F | D | lines | T | T/rep | primed |
|---|---|---|---|---|---|---|---|---|
| IDEN | 12 | 250 | 320 | 160 | | | | |
| RFR0 | 00 | 1 | 1 | 167 | 478 | 871872 | 871872.00 | 871652.00 |
| RSWP | 00 | 16 | 24 | 82 | 7546 | 13763904 | 860244.00 | 860024.00 |
| ARSW | 00 | 16 | 26 | -74 | 8012 | 14613888 | 913368.00 | 913134.41 |
| RSEC | 00 | 128 | 2 | -31 | 591 | 1077984 | 8421.75 | 8333.75 |
| RCOL | 00 | 128 | 2 | -10 | 612 | 1116288 | 8721.00 | 8633.00 |
| RHST | 00 | 2048 | 31 | -7 | 9634 | 17572416 | 8580.28 | - |
| RH39 | 00 | 2048 | 31 | 16 | 9657 | 17614368 | 8600.77 | - |
| SPN0 | 00 | 512 | 47 | 17 | 14634 | 26692416 | 52133.62 | - |
| ARSE | 00 | 128 | 2 | 5 | 627 | 1143648 | 8934.75 | 8841.39 |
| ARCO | 00 | 128 | 2 | 27 | 649 | 1183776 | 9248.25 | 9154.93 |
| AHST | 00 | 2048 | 32 | 278 | 10230 | 18659520 | 9111.09 | - |
| AH39 | 00 | 2048 | 33 | -9 | 10254 | 18703296 | 9132.47 | - |
| ASPN | 00 | 512 | 50 | -12 | 15538 | 28341312 | 55354.12 | - |
| OSPN | 00 | 512 | 52 | 48 | 16220 | 29585280 | 57783.75 | - |

#HIST RHST: bin 1 = 2048

#HIST RH39: bin 1 = 2048

#HIST AHST: bin 1 = 2048

#HIST AH39: bin 1 = 2048

clip 062 stereo 320x192@25: Spix 120, Ssnd 3, C 320 (section 3)

| tag | O | R | F | D | lines | T | T/rep | primed |
|---|---|---|---|---|---|---|---|---|
| IDEN | 12 | 250 | 320 | 192 | | | | |
| RFR0 | 00 | 1 | 2 | -52 | 570 | 1039680 | 1039680.00 | 1039460.00 |
| RSWP | 00 | 16 | 29 | -16 | 9003 | 16421472 | 1026342.00 | 1026122.00 |
| ARSW | 00 | 16 | 31 | -81 | 9560 | 17437440 | 1089840.00 | 1089606.39 |
| RSEC | 00 | 128 | 2 | -31 | 591 | 1077984 | 8421.75 | 8333.75 |
| RCOL | 00 | 128 | 2 | -10 | 612 | 1116288 | 8721.00 | 8633.00 |
| RHST | 00 | 2048 | 31 | -7 | 9634 | 17572416 | 8580.28 | - |
| RH39 | 00 | 2048 | 31 | 16 | 9657 | 17614368 | 8600.77 | - |
| SPN0 | 00 | 512 | 47 | 17 | 14634 | 26692416 | 52133.62 | - |
| ARSE | 00 | 128 | 2 | 5 | 627 | 1143648 | 8934.75 | 8841.39 |
| ARCO | 00 | 128 | 2 | 28 | 650 | 1185600 | 9262.50 | 9169.04 |
| AHST | 00 | 2048 | 32 | 278 | 10230 | 18659520 | 9111.09 | - |
| AH39 | 00 | 2048 | 33 | -9 | 10254 | 18703296 | 9132.47 | - |
| ASPN | 00 | 512 | 50 | -12 | 15538 | 28341312 | 55354.12 | - |
| OSPN | 00 | 512 | 52 | 48 | 16220 | 29585280 | 57783.75 | - |

#HIST RHST: bin 1 = 2048

#HIST RH39: bin 1 = 2048

#HIST AHST: bin 1 = 2048

#HIST AH39: bin 1 = 2048

clip 063 stereo 280x224@25: Spix 123, Ssnd 3, C 280 (section 4)

| tag | O | R | F | D | lines | T | T/rep | primed |
|---|---|---|---|---|---|---|---|---|
| IDEN | 12 | 250 | 280 | 224 | | | | |
| RFR0 | 00 | 1 | 2 | -39 | 583 | 1063392 | 1063392.00 | 1063172.00 |
| RSWP | 00 | 16 | 30 | -113 | 9217 | 16811808 | 1050738.00 | 1050518.00 |
| ARSW | 00 | 16 | 31 | 147 | 9788 | 17853312 | 1115832.00 | 1115598.37 |
| RSEC | 00 | 128 | 1 | 279 | 590 | 1076160 | 8407.50 | 8319.50 |
| RCOL | 00 | 128 | 2 | -10 | 612 | 1116288 | 8721.00 | 8633.00 |
| RHST | 00 | 2048 | 31 | -7 | 9634 | 17572416 | 8580.28 | - |
| RH39 | 00 | 2048 | 31 | 17 | 9658 | 17616192 | 8601.66 | - |
| SPN0 | 00 | 512 | 47 | 17 | 14634 | 26692416 | 52133.62 | - |
| ARSE | 00 | 128 | 2 | 5 | 627 | 1143648 | 8934.75 | 8841.23 |
| ARCO | 00 | 128 | 2 | 28 | 650 | 1185600 | 9262.50 | 9169.04 |
| AHST | 00 | 2048 | 32 | 277 | 10229 | 18657696 | 9110.20 | - |
| AH39 | 00 | 2048 | 33 | -9 | 10254 | 18703296 | 9132.47 | - |
| ASPN | 00 | 512 | 50 | -12 | 15538 | 28341312 | 55354.12 | - |
| OSPN | 00 | 512 | 52 | 48 | 16220 | 29585280 | 57783.75 | - |

#HIST RHST: bin 1 = 2048

#HIST RH39: bin 1 = 2048

#HIST AHST: bin 1 = 2048

#HIST AH39: bin 1 = 2048

clip 064 stereo 320x240@16.67: Spix 150, Ssnd 4, C 320 (section 5)

| tag | O | R | F | D | lines | T | T/rep | primed |
|---|---|---|---|---|---|---|---|---|
| IDEN | 02 | 167 | 320 | 240 | | | | |
| RFR0 | 00 | 1 | 3 | -217 | 716 | 1305984 | 1305984.00 | 1305764.00 |
| RSWP | 00 | 16 | 36 | 158 | 11354 | 20709696 | 1294356.00 | 1294136.00 |
| ARSW | 00 | 16 | 38 | 237 | 12055 | 21988320 | 1374270.00 | 1374036.42 |
| RSEC | 00 | 128 | 1 | 279 | 590 | 1076160 | 8407.50 | 8319.50 |
| RCOL | 00 | 128 | 2 | -10 | 612 | 1116288 | 8721.00 | 8633.00 |
| RHST | 00 | 2048 | 31 | -7 | 9634 | 17572416 | 8580.28 | - |
| RH39 | 00 | 2048 | 31 | 17 | 9658 | 17616192 | 8601.66 | - |
| SPN0 | 00 | 512 | 47 | 17 | 14634 | 26692416 | 52133.62 | - |
| ARSE | 00 | 128 | 2 | 5 | 627 | 1143648 | 8934.75 | 8841.23 |
| ARCO | 00 | 128 | 2 | 28 | 650 | 1185600 | 9262.50 | 9169.04 |
| AHST | 00 | 2048 | 32 | 277 | 10229 | 18657696 | 9110.20 | - |
| AH39 | 00 | 2048 | 33 | -9 | 10254 | 18703296 | 9132.47 | - |
| ASPN | 00 | 512 | 50 | -12 | 15538 | 28341312 | 55354.12 | - |
| OSPN | 00 | 512 | 52 | 48 | 16220 | 29585280 | 57783.75 | - |

#HIST RHST: bin 1 = 2048

#HIST RH39: bin 1 = 2048

#HIST AHST: bin 1 = 2048

#HIST AH39: bin 1 = 2048

clip 065 stereo 256x240@16.67: Spix 120, Ssnd 4, C 256 (section 6)

| tag | O | R | F | D | lines | T | T/rep | primed |
|---|---|---|---|---|---|---|---|---|
| IDEN | 02 | 167 | 256 | 240 | | | | |
| RFR0 | 00 | 1 | 2 | -43 | 579 | 1056096 | 1056096.00 | 1055876.00 |
| RSWP | 00 | 16 | 29 | 126 | 9145 | 16680480 | 1042530.00 | 1042310.00 |
| ARSW | 00 | 16 | 31 | 70 | 9711 | 17712864 | 1107054.00 | 1106820.38 |
| RSEC | 00 | 128 | 2 | -31 | 591 | 1077984 | 8421.75 | 8333.75 |
| RCOL | 00 | 128 | 2 | -10 | 612 | 1116288 | 8721.00 | 8633.00 |
| RHST | 00 | 2048 | 31 | -7 | 9634 | 17572416 | 8580.28 | - |
| RH39 | 00 | 2048 | 31 | 17 | 9658 | 17616192 | 8601.66 | - |
| SPN0 | 00 | 512 | 47 | 17 | 14634 | 26692416 | 52133.62 | - |
| ARSE | 00 | 128 | 2 | 5 | 627 | 1143648 | 8934.75 | 8841.39 |
| ARCO | 00 | 128 | 2 | 27 | 649 | 1183776 | 9248.25 | 9154.93 |
| AHST | 00 | 2048 | 33 | -33 | 10230 | 18659520 | 9111.09 | - |
| AH39 | 00 | 2048 | 33 | -8 | 10255 | 18705120 | 9133.36 | - |
| ASPN | 00 | 512 | 50 | -12 | 15538 | 28341312 | 55354.12 | - |
| OSPN | 00 | 512 | 52 | 48 | 16220 | 29585280 | 57783.75 | - |

#HIST RHST: bin 1 = 2048

#HIST RH39: bin 1 = 2048

#HIST AHST: bin 1 = 2048

#HIST AH39: bin 1 = 2048

clip 066 mono 256x192@25: Spix 96, Ssnd 2, C 0 (section 7)

| tag | O | R | F | D | lines | T | T/rep | primed |
|---|---|---|---|---|---|---|---|---|
| IDEN | 02 | 250 | 256 | 192 | | | | |
| RFR0 | 00 | 1 | 2 | -167 | 455 | 829920 | 829920.00 | 829700.00 |
| RSWP | 00 | 16 | 23 | 10 | 7163 | 13065312 | 816582.00 | 816362.00 |
| ARSW | 00 | 16 | 24 | 43 | 7507 | 13692768 | 855798.00 | 855567.43 |
| RSEC | 00 | 128 | 2 | -32 | 590 | 1076160 | 8407.50 | 8319.50 |
| RCOL | 00 | 128 | 2 | -10 | 612 | 1116288 | 8721.00 | 8633.00 |
| RHST | 00 | 2048 | 31 | -7 | 9634 | 17572416 | 8580.28 | - |
| RH39 | 00 | 2048 | 31 | 17 | 9658 | 17616192 | 8601.66 | - |
| SPN0 | 00 | 512 | 47 | 16 | 14633 | 26690592 | 52130.06 | - |
| ARSE | 00 | 128 | 2 | -3 | 619 | 1129056 | 8820.75 | 8728.42 |
| ARCO | 00 | 128 | 2 | 19 | 641 | 1169184 | 9134.25 | 9042.08 |
| AHST | 00 | 2048 | 32 | 145 | 10097 | 18416928 | 8992.64 | - |
| AH39 | 00 | 2048 | 33 | -141 | 10122 | 18462528 | 9014.91 | - |
| ASPN | 00 | 512 | 49 | 98 | 15337 | 27974688 | 54638.06 | - |
| OSPN | 00 | 512 | 52 | 48 | 16220 | 29585280 | 57783.75 | - |

#HIST RHST: bin 1 = 2048

#HIST RH39: bin 1 = 2048

#HIST AHST: bin 1 = 2048

#HIST AH39: bin 1 = 2048

clip 067 mono 320x160@25: Spix 100, Ssnd 2, C 320 (section 8)

| tag | O | R | F | D | lines | T | T/rep | primed |
|---|---|---|---|---|---|---|---|---|
| IDEN | 12 | 250 | 320 | 160 | | | | |
| RFR0 | 00 | 1 | 1 | 162 | 473 | 862752 | 862752.00 | 862532.00 |
| RSWP | 00 | 16 | 24 | 7 | 7471 | 13627104 | 851694.00 | 851474.00 |
| ARSW | 00 | 16 | 25 | 55 | 7830 | 14281920 | 892620.00 | 892389.43 |
| RSEC | 00 | 128 | 2 | -32 | 590 | 1076160 | 8407.50 | 8319.50 |
| RCOL | 00 | 128 | 2 | -11 | 611 | 1114464 | 8706.75 | 8618.75 |
| RHST | 00 | 2048 | 31 | -7 | 9634 | 17572416 | 8580.28 | - |
| RH39 | 00 | 2048 | 31 | 17 | 9658 | 17616192 | 8601.66 | - |
| SPN0 | 00 | 512 | 47 | 16 | 14633 | 26690592 | 52130.06 | - |
| ARSE | 00 | 128 | 2 | -3 | 619 | 1129056 | 8820.75 | 8728.42 |
| ARCO | 00 | 128 | 2 | 19 | 641 | 1169184 | 9134.25 | 9041.93 |
| AHST | 00 | 2048 | 32 | 144 | 10096 | 18415104 | 8991.75 | - |
| AH39 | 00 | 2048 | 33 | -142 | 10121 | 18460704 | 9014.02 | - |
| ASPN | 00 | 512 | 49 | 98 | 15337 | 27974688 | 54638.06 | - |
| OSPN | 00 | 512 | 52 | 48 | 16220 | 29585280 | 57783.75 | - |

#HIST RHST: bin 1 = 2048

#HIST RH39: bin 1 = 2048

#HIST AHST: bin 1 = 2048

#HIST AH39: bin 1 = 2048

clip 068 mono 320x192@25: Spix 120, Ssnd 2, C 320 (section 9)

| tag | O | R | F | D | lines | T | T/rep | primed |
|---|---|---|---|---|---|---|---|---|
| IDEN | 12 | 250 | 320 | 192 | | | | |
| RFR0 | 00 | 1 | 2 | -57 | 565 | 1030560 | 1030560.00 | 1030340.00 |
| RSWP | 00 | 16 | 28 | 221 | 8929 | 16286496 | 1017906.00 | 1017686.00 |
| ARSW | 00 | 16 | 30 | 28 | 9358 | 17068992 | 1066812.00 | 1066581.43 |
| RSEC | 00 | 128 | 2 | -31 | 591 | 1077984 | 8421.75 | 8333.75 |
| RCOL | 00 | 128 | 2 | -10 | 612 | 1116288 | 8721.00 | 8633.00 |
| RHST | 00 | 2048 | 31 | -7 | 9634 | 17572416 | 8580.28 | - |
| RH39 | 00 | 2048 | 31 | 16 | 9657 | 17614368 | 8600.77 | - |
| SPN0 | 00 | 512 | 47 | 17 | 14634 | 26692416 | 52133.62 | - |
| ARSE | 00 | 128 | 2 | -3 | 619 | 1129056 | 8820.75 | 8728.58 |
| ARCO | 00 | 128 | 2 | 19 | 641 | 1169184 | 9134.25 | 9042.08 |
| AHST | 00 | 2048 | 32 | 145 | 10097 | 18416928 | 8992.64 | - |
| AH39 | 00 | 2048 | 33 | -142 | 10121 | 18460704 | 9014.02 | - |
| ASPN | 00 | 512 | 49 | 98 | 15337 | 27974688 | 54638.06 | - |
| OSPN | 00 | 512 | 52 | 48 | 16220 | 29585280 | 57783.75 | - |

#HIST RHST: bin 1 = 2048

#HIST RH39: bin 1 = 2048

#HIST AHST: bin 1 = 2048

#HIST AH39: bin 1 = 2048

clip 069 mono 280x224@25: Spix 123, Ssnd 2, C 280 (section 10)

| tag | O | R | F | D | lines | T | T/rep | primed |
|---|---|---|---|---|---|---|---|---|
| IDEN | 12 | 250 | 280 | 224 | | | | |
| RFR0 | 00 | 1 | 2 | -44 | 578 | 1054272 | 1054272.00 | 1054052.00 |
| RSWP | 00 | 16 | 29 | 125 | 9144 | 16678656 | 1042416.00 | 1042196.00 |
| ARSW | 00 | 16 | 31 | -58 | 9583 | 17479392 | 1092462.00 | 1092231.44 |
| RSEC | 00 | 128 | 2 | -31 | 591 | 1077984 | 8421.75 | 8333.75 |
| RCOL | 00 | 128 | 2 | -10 | 612 | 1116288 | 8721.00 | 8633.00 |
| RHST | 00 | 2048 | 31 | -7 | 9634 | 17572416 | 8580.28 | - |
| RH39 | 00 | 2048 | 31 | 16 | 9657 | 17614368 | 8600.77 | - |
| SPN0 | 00 | 512 | 47 | 17 | 14634 | 26692416 | 52133.62 | - |
| ARSE | 00 | 128 | 2 | -3 | 619 | 1129056 | 8820.75 | 8728.58 |
| ARCO | 00 | 128 | 2 | 19 | 641 | 1169184 | 9134.25 | 9042.08 |
| AHST | 00 | 2048 | 32 | 145 | 10097 | 18416928 | 8992.64 | - |
| AH39 | 00 | 2048 | 33 | -141 | 10122 | 18462528 | 9014.91 | - |
| ASPN | 00 | 512 | 49 | 97 | 15336 | 27972864 | 54634.50 | - |
| OSPN | 00 | 512 | 52 | 48 | 16220 | 29585280 | 57783.75 | - |

#HIST RHST: bin 1 = 2048

#HIST RH39: bin 1 = 2048

#HIST AHST: bin 1 = 2048

#HIST AH39: bin 1 = 2048

clip 070 mono 320x240@16.67: Spix 150, Ssnd 2, C 320 (section 11)

| tag | O | R | F | D | lines | T | T/rep | primed |
|---|---|---|---|---|---|---|---|---|
| IDEN | 02 | 167 | 320 | 240 | | | | |
| RFR0 | 00 | 1 | 2 | 85 | 707 | 1289568 | 1289568.00 | 1289348.00 |
| RSWP | 00 | 16 | 36 | 9 | 11205 | 20437920 | 1277370.00 | 1277150.00 |
| ARSW | 00 | 16 | 38 | -74 | 11744 | 21421056 | 1338816.00 | 1338585.42 |
| RSEC | 00 | 128 | 2 | -31 | 591 | 1077984 | 8421.75 | 8333.75 |
| RCOL | 00 | 128 | 2 | -10 | 612 | 1116288 | 8721.00 | 8633.00 |
| RHST | 00 | 2048 | 31 | -7 | 9634 | 17572416 | 8580.28 | - |
| RH39 | 00 | 2048 | 31 | 16 | 9657 | 17614368 | 8600.77 | - |
| SPN0 | 00 | 512 | 47 | 17 | 14634 | 26692416 | 52133.62 | - |
| ARSE | 00 | 128 | 2 | -3 | 619 | 1129056 | 8820.75 | 8728.58 |
| ARCO | 00 | 128 | 2 | 19 | 641 | 1169184 | 9134.25 | 9042.08 |
| AHST | 00 | 2048 | 32 | 144 | 10096 | 18415104 | 8991.75 | - |
| AH39 | 00 | 2048 | 33 | -142 | 10121 | 18460704 | 9014.02 | - |
| ASPN | 00 | 512 | 49 | 98 | 15337 | 27974688 | 54638.06 | - |
| OSPN | 00 | 512 | 52 | 48 | 16220 | 29585280 | 57783.75 | - |

#HIST RHST: bin 1 = 2048

#HIST RH39: bin 1 = 2048

#HIST AHST: bin 1 = 2048

#HIST AH39: bin 1 = 2048

clip 071 mono 256x240@16.67: Spix 120, Ssnd 2, C 256 (section 12)

| tag | O | R | F | D | lines | T | T/rep | primed |
|---|---|---|---|---|---|---|---|---|
| IDEN | 02 | 167 | 256 | 240 | | | | |
| RFR0 | 00 | 1 | 2 | -53 | 569 | 1037856 | 1037856.00 | 1037636.00 |
| RSWP | 00 | 16 | 29 | -22 | 8997 | 16410528 | 1025658.00 | 1025438.00 |
| ARSW | 00 | 16 | 30 | 99 | 9429 | 17198496 | 1074906.00 | 1074675.44 |
| RSEC | 00 | 128 | 1 | 279 | 590 | 1076160 | 8407.50 | 8319.50 |
| RCOL | 00 | 128 | 2 | -10 | 612 | 1116288 | 8721.00 | 8633.00 |
| RHST | 00 | 2048 | 31 | -7 | 9634 | 17572416 | 8580.28 | - |
| RH39 | 00 | 2048 | 31 | 17 | 9658 | 17616192 | 8601.66 | - |
| SPN0 | 00 | 512 | 47 | 17 | 14634 | 26692416 | 52133.62 | - |
| ARSE | 00 | 128 | 2 | -3 | 619 | 1129056 | 8820.75 | 8728.42 |
| ARCO | 00 | 128 | 2 | 19 | 641 | 1169184 | 9134.25 | 9042.08 |
| AHST | 00 | 2048 | 33 | -166 | 10097 | 18416928 | 8992.64 | - |
| AH39 | 00 | 2048 | 32 | 170 | 10122 | 18462528 | 9014.91 | - |
| ASPN | 00 | 512 | 49 | 98 | 15337 | 27974688 | 54638.06 | - |
| OSPN | 00 | 512 | 52 | 48 | 16220 | 29585280 | 57783.75 | - |

#HIST RHST: bin 1 = 2048

#HIST RH39: bin 1 = 2048

#HIST AHST: bin 1 = 2048

#HIST AH39: bin 1 = 2048

clip 072 stereo 320x256@12.5: Spix 160, Ssnd 5, C 0 (section 13)

| tag | O | R | F | D | lines | T | T/rep | primed |
|---|---|---|---|---|---|---|---|---|
| IDEN | 02 | 125 | 320 | 0 | | | | |
| RFR0 | 00 | 1 | 2 | 138 | 760 | 1386240 | 1386240.00 | 1386020.00 |
| RSWP | 00 | 16 | 39 | -77 | 12052 | 21982848 | 1373928.00 | 1373708.00 |
| ARSW | 00 | 16 | 41 | 47 | 12798 | 23343552 | 1458972.00 | 1458738.38 |
| RSEC | 00 | 128 | 1 | 279 | 590 | 1076160 | 8407.50 | 8319.50 |
| RCOL | 00 | 128 | 2 | -10 | 612 | 1116288 | 8721.00 | 8633.00 |
| RHST | 00 | 2048 | 31 | -7 | 9634 | 17572416 | 8580.28 | - |
| RH39 | 00 | 2048 | 31 | 17 | 9658 | 17616192 | 8601.66 | - |
| SPN0 | 00 | 512 | 47 | 17 | 14634 | 26692416 | 52133.62 | - |
| ARSE | 00 | 128 | 2 | 5 | 627 | 1143648 | 8934.75 | 8841.23 |
| ARCO | 00 | 128 | 2 | 28 | 650 | 1185600 | 9262.50 | 9169.04 |
| AHST | 00 | 2048 | 32 | 277 | 10229 | 18657696 | 9110.20 | - |
| AH39 | 00 | 2048 | 33 | -9 | 10254 | 18703296 | 9132.47 | - |
| ASPN | 00 | 512 | 50 | -12 | 15538 | 28341312 | 55354.12 | - |
| OSPN | 00 | 512 | 52 | 48 | 16220 | 29585280 | 57783.75 | - |

#HIST RHST: bin 1 = 2048

#HIST RH39: bin 1 = 2048

#HIST AHST: bin 1 = 2048

#HIST AH39: bin 1 = 2048

clip 074 mono 256x192@15.2588: Spix 96, Ssnd 3, C 0 (section 14)

| tag | O | R | F | D | lines | T | T/rep | primed |
|---|---|---|---|---|---|---|---|---|
| IDEN | 02 | 153 | 256 | 192 | | | | |
| RFR0 | 00 | 1 | 1 | 148 | 459 | 837216 | 837216.00 | 836996.00 |
| RSWP | 00 | 16 | 23 | 83 | 7236 | 13198464 | 824904.00 | 824684.00 |
| ARSW | 00 | 16 | 25 | -190 | 7585 | 13835040 | 864690.00 | 864459.39 |
| RSEC | 00 | 128 | 1 | 279 | 590 | 1076160 | 8407.50 | 8319.50 |
| RCOL | 00 | 128 | 2 | -10 | 612 | 1116288 | 8721.00 | 8633.00 |
| RHST | 00 | 2048 | 31 | -7 | 9634 | 17572416 | 8580.28 | - |
| RH39 | 00 | 2048 | 31 | 17 | 9658 | 17616192 | 8601.66 | - |
| SPN0 | 00 | 512 | 47 | 17 | 14634 | 26692416 | 52133.62 | - |
| ARSE | 00 | 128 | 2 | -3 | 619 | 1129056 | 8820.75 | 8728.42 |
| ARCO | 00 | 128 | 2 | 19 | 641 | 1169184 | 9134.25 | 9042.08 |
| AHST | 00 | 2048 | 33 | -166 | 10097 | 18416928 | 8992.64 | - |
| AH39 | 00 | 2048 | 32 | 170 | 10122 | 18462528 | 9014.91 | - |
| ASPN | 00 | 512 | 49 | 98 | 15337 | 27974688 | 54638.06 | - |
| OSPN | 00 | 512 | 52 | 48 | 16220 | 29585280 | 57783.75 | - |

#HIST RHST: bin 1 = 2048

#HIST RH39: bin 1 = 2048

#HIST AHST: bin 1 = 2048

#HIST AH39: bin 1 = 2048

clip 088 mono 256x192@12.5: Spix 96, Ssnd 3, C 0 (section 15)

| tag | O | R | F | D | lines | T | T/rep | primed |
|---|---|---|---|---|---|---|---|---|
| IDEN | 02 | 250 | 256 | 192 | | | | |
| RFR0 | 00 | 1 | 1 | 148 | 459 | 837216 | 837216.00 | 836996.00 |
| RSWP | 00 | 16 | 23 | 85 | 7238 | 13202112 | 825132.00 | 824912.00 |
| ARSW | 00 | 16 | 24 | 122 | 7586 | 13836864 | 864804.00 | 864573.42 |
| RSEC | 00 | 128 | 1 | 279 | 590 | 1076160 | 8407.50 | 8319.50 |
| RCOL | 00 | 128 | 2 | -10 | 612 | 1116288 | 8721.00 | 8633.00 |
| RHST | 00 | 2048 | 31 | -7 | 9634 | 17572416 | 8580.28 | - |
| RH39 | 00 | 2048 | 31 | 17 | 9658 | 17616192 | 8601.66 | - |
| SPN0 | 00 | 512 | 47 | 17 | 14634 | 26692416 | 52133.62 | - |
| ARSE | 00 | 128 | 2 | -3 | 619 | 1129056 | 8820.75 | 8728.42 |
| ARCO | 00 | 128 | 2 | 19 | 641 | 1169184 | 9134.25 | 9042.08 |
| AHST | 00 | 2048 | 33 | -166 | 10097 | 18416928 | 8992.64 | - |
| AH39 | 00 | 2048 | 32 | 170 | 10122 | 18462528 | 9014.91 | - |
| ASPN | 00 | 512 | 49 | 98 | 15337 | 27974688 | 54638.06 | - |
| OSPN | 00 | 512 | 52 | 48 | 16220 | 29585280 | 57783.75 | - |

#HIST RHST: bin 1 = 2048

#HIST RH39: bin 1 = 2048

#HIST AHST: bin 1 = 2048

#HIST AH39: bin 1 = 2048

clip 089 stereo 256x192@20: Spix 96, Ssnd 4, C 0 (section 16)

| tag | O | R | F | D | lines | T | T/rep | primed |
|---|---|---|---|---|---|---|---|---|
| IDEN | 02 | 200 | 256 | 192 | | | | |
| RFR0 | 00 | 1 | 2 | -158 | 464 | 846336 | 846336.00 | 846116.00 |
| RSWP | 00 | 16 | 23 | 159 | 7312 | 13337088 | 833568.00 | 833348.00 |
| ARSW | 00 | 16 | 24 | 300 | 7764 | 14161536 | 885096.00 | 884862.40 |
| RSEC | 00 | 128 | 1 | 279 | 590 | 1076160 | 8407.50 | 8319.50 |
| RCOL | 00 | 128 | 2 | -10 | 612 | 1116288 | 8721.00 | 8633.00 |
| RHST | 00 | 2048 | 31 | -7 | 9634 | 17572416 | 8580.28 | - |
| RH39 | 00 | 2048 | 31 | 17 | 9658 | 17616192 | 8601.66 | - |
| SPN0 | 00 | 512 | 47 | 17 | 14634 | 26692416 | 52133.62 | - |
| ARSE | 00 | 128 | 2 | 5 | 627 | 1143648 | 8934.75 | 8841.23 |
| ARCO | 00 | 128 | 2 | 28 | 650 | 1185600 | 9262.50 | 9169.04 |
| AHST | 00 | 2048 | 32 | 277 | 10229 | 18657696 | 9110.20 | - |
| AH39 | 00 | 2048 | 33 | -9 | 10254 | 18703296 | 9132.47 | - |
| ASPN | 00 | 512 | 50 | -12 | 15538 | 28341312 | 55354.12 | - |
| OSPN | 00 | 512 | 52 | 48 | 16220 | 29585280 | 57783.75 | - |

#HIST RHST: bin 1 = 2048

#HIST RH39: bin 1 = 2048

#HIST AHST: bin 1 = 2048

#HIST AH39: bin 1 = 2048

clip 066 NXBM (section 17)

| tag | O | R | F | D | lines | T | T/rep |
|---|---|---|---|---|---|---|---|
| IDEN | 02 | 00FA | 0100 | 00C0 | | | |
| CPY0 | 00 | 128 | 0 | 125 | 125 | 228000 | 1781.25 |
| RFR0 | 00 | 1 | 1 | 143 | 454 | 828096 | 828096.00 |
| SPN0 | 00 | 512 | 47 | 107 | 14724 | 26856576 | 52454.25 |
| MRSW | 00 | 16 | 23 | 86 | 7239 | 13203936 | 825246.00 |
| MCN1 | 01 | 1CAC | 0000 | 0000 | | | |
| MSPN | 00 | 512 | 48 | -121 | 14807 | 27007968 | 52749.94 |
| MCN2 | 01 | 3AA0 | 0000 | 0000 | | | |
| MHST | 00 | 2048 | 32 | 97 | 10049 | 18329376 | 8949.89 |
| MCN3 | 01 | 27C6 | 0000 | 0000 | | | |
| MSUM | 00 | 36AD | 0700 | 0000 | | | |
| MPTR | 01 | 0003 | 0000 | 0000 | | | |
| MTCK | 00 | 00FA | 00FA | 0000 | | | |
| MCPY | 00 | 128 | 0 | 124 | 124 | 226176 | 1767.00 |
| RHST | 00 | 2048 | 32 | 19 | 9971 | 18187104 | 8880.42 |

clip 067 NXBM (section 18)

| tag | O | R | F | D | lines | T | T/rep |
|---|---|---|---|---|---|---|---|
| IDEN | 12 | 00FA | 0140 | 00A0 | | | |
| CPY0 | 00 | 128 | 0 | 125 | 125 | 228000 | 1781.25 |
| RFR0 | 00 | 1 | 2 | -148 | 474 | 864576 | 864576.00 |
| SPN0 | 00 | 512 | 47 | 107 | 14724 | 26856576 | 52454.25 |
| MRSW | 00 | 16 | 24 | 76 | 7540 | 13752960 | 859560.00 |
| MCN1 | 01 | 1DD9 | 0000 | 0000 | | | |
| MSPN | 00 | 512 | 47 | 189 | 14806 | 27006144 | 52746.38 |
| MCN2 | 01 | 3AA0 | 0000 | 0000 | | | |
| MHST | 00 | 2048 | 32 | 97 | 10049 | 18329376 | 8949.89 |
| MCN3 | 01 | 27C7 | 0000 | 0000 | | | |
| MSUM | 00 | 4C18 | 0654 | 0000 | | | |
| MPTR | 01 | 0002 | 0000 | 0000 | | | |
| MTCK | 00 | 00FA | 00FA | 0000 | | | |
| MCPY | 00 | 128 | 0 | 124 | 124 | 226176 | 1767.00 |
| RHST | 00 | 2048 | 32 | 19 | 9971 | 18187104 | 8880.42 |

clip 068 NXBM (section 19)

| tag | O | R | F | D | lines | T | T/rep |
|---|---|---|---|---|---|---|---|
| IDEN | 12 | 00FA | 0140 | 00C0 | | | |
| CPY0 | 00 | 128 | 0 | 125 | 125 | 228000 | 1781.25 |
| RFR0 | 00 | 1 | 1 | 254 | 565 | 1030560 | 1030560.00 |
| SPN0 | 00 | 512 | 47 | 107 | 14724 | 26856576 | 52454.25 |
| MRSW | 00 | 16 | 29 | -6 | 9013 | 16439712 | 1027482.00 |
| MCN1 | 01 | 23AF | 0000 | 0000 | | | |
| MSPN | 00 | 512 | 48 | -122 | 14806 | 27006144 | 52746.38 |
| MCN2 | 01 | 3A9F | 0000 | 0000 | | | |
| MHST | 00 | 2048 | 32 | 97 | 10049 | 18329376 | 8949.89 |
| MCN3 | 01 | 27C7 | 0000 | 0000 | | | |
| MSUM | 00 | 7B86 | 0709 | 0000 | | | |
| MPTR | 01 | 0003 | 0000 | 0000 | | | |
| MTCK | 00 | 00FA | 00FA | 0000 | | | |
| MCPY | 00 | 128 | 0 | 124 | 124 | 226176 | 1767.00 |
| RHST | 00 | 2048 | 32 | 19 | 9971 | 18187104 | 8880.42 |

clip 069 NXBM (section 20)

| tag | O | R | F | D | lines | T | T/rep |
|---|---|---|---|---|---|---|---|
| IDEN | 12 | 00FA | 0118 | 00E0 | | | |
| CPY0 | 00 | 128 | 1 | -186 | 125 | 228000 | 1781.25 |
| RFR0 | 00 | 1 | 1 | 267 | 578 | 1054272 | 1054272.00 |
| SPN0 | 00 | 512 | 47 | 107 | 14724 | 26856576 | 52454.25 |
| MRSW | 00 | 16 | 30 | -100 | 9230 | 16835520 | 1052220.00 |
| MCN1 | 01 | 248C | 0000 | 0000 | | | |
| MSPN | 00 | 512 | 48 | -122 | 14806 | 27006144 | 52746.38 |
| MCN2 | 01 | 3A9F | 0000 | 0000 | | | |
| MHST | 00 | 2048 | 32 | 97 | 10049 | 18329376 | 8949.89 |
| MCN3 | 01 | 27C8 | 0000 | 0000 | | | |
| MSUM | 00 | C2AB | 065D | 0000 | | | |
| MPTR | 01 | 0003 | 0000 | 0000 | | | |
| MTCK | 00 | 00FA | 00FA | 0000 | | | |
| MCPY | 00 | 128 | 0 | 124 | 124 | 226176 | 1767.00 |
| RHST | 00 | 2048 | 32 | 19 | 9971 | 18187104 | 8880.42 |

clip 070 NXBM (section 21)

| tag | O | R | F | D | lines | T | T/rep |
|---|---|---|---|---|---|---|---|
| IDEN | 02 | 00A7 | 0140 | 00F0 | | | |
| CPY0 | 00 | 128 | 0 | 124 | 124 | 226176 | 1767.00 |
| RFR0 | 00 | 1 | 2 | 85 | 707 | 1289568 | 1289568.00 |
| SPN0 | 00 | 512 | 47 | 107 | 14724 | 26856576 | 52454.25 |
| MRSW | 00 | 16 | 36 | 98 | 11294 | 20600256 | 1287516.00 |
| MCN1 | 01 | 2CB6 | 0000 | 0000 | | | |
| MSPN | 00 | 512 | 47 | 189 | 14806 | 27006144 | 52746.38 |
| MCN2 | 01 | 3AA0 | 0000 | 0000 | | | |
| MHST | 00 | 2048 | 33 | -213 | 10050 | 18331200 | 8950.78 |
| MCN3 | 01 | 27C8 | 0000 | 0000 | | | |
| MSUM | 00 | 949E | 0641 | 0000 | | | |
| MPTR | 01 | 0004 | 0000 | 0000 | | | |
| MTCK | 00 | 00FA | 00FA | 0000 | | | |
| MCPY | 00 | 128 | 0 | 124 | 124 | 226176 | 1767.00 |
| RHST | 00 | 2048 | 32 | 19 | 9971 | 18187104 | 8880.42 |

clip 071 NXBM (section 22)

| tag | O | R | F | D | lines | T | T/rep |
|---|---|---|---|---|---|---|---|
| IDEN | 02 | 00A7 | 0100 | 00F0 | | | |
| CPY0 | 00 | 128 | 0 | 125 | 125 | 228000 | 1781.25 |
| RFR0 | 00 | 1 | 2 | -53 | 569 | 1037856 | 1037856.00 |
| SPN0 | 00 | 512 | 47 | 107 | 14724 | 26856576 | 52454.25 |
| MRSW | 00 | 16 | 29 | 50 | 9069 | 16541856 | 1033866.00 |
| MCN1 | 01 | 23E8 | 0000 | 0000 | | | |
| MSPN | 00 | 512 | 48 | -121 | 14807 | 27007968 | 52749.94 |
| MCN2 | 01 | 3AA0 | 0000 | 0000 | | | |
| MHST | 00 | 2048 | 32 | 97 | 10049 | 18329376 | 8949.89 |
| MCN3 | 01 | 27C8 | 0000 | 0000 | | | |
| MSUM | 00 | F322 | 0591 | 0000 | | | |
| MPTR | 01 | 0003 | 0000 | 0000 | | | |
| MTCK | 00 | 00FA | 00FA | 0000 | | | |
| MCPY | 00 | 128 | 0 | 124 | 124 | 226176 | 1767.00 |
| RHST | 00 | 2048 | 32 | 19 | 9971 | 18187104 | 8880.42 |

clip 074 NXBM (section 23)

| tag | O | R | F | D | lines | T | T/rep |
|---|---|---|---|---|---|---|---|
| IDEN | 02 | 0099 | 0100 | 00C0 | | | |
| CPY0 | 00 | 128 | 0 | 124 | 124 | 226176 | 1767.00 |
| RFR0 | 00 | 1 | 2 | -163 | 459 | 837216 | 837216.00 |
| SPN0 | 00 | 512 | 47 | 107 | 14724 | 26856576 | 52454.25 |
| MRSW | 00 | 16 | 23 | 159 | 7312 | 13337088 | 833568.00 |
| MCN1 | 01 | 1CF6 | 0000 | 0000 | | | |
| MSPN | 00 | 512 | 48 | -121 | 14807 | 27007968 | 52749.94 |
| MCN2 | 01 | 3AA0 | 0000 | 0000 | | | |
| MHST | 00 | 2048 | 32 | 97 | 10049 | 18329376 | 8949.89 |
| MCN3 | 01 | 27C6 | 0000 | 0000 | | | |
| MSUM | 00 | 2D89 | 06FA | 0000 | | | |
| MPTR | 01 | 0005 | 0000 | 0000 | | | |
| MTCK | 00 | 00FA | 00FA | 0000 | | | |
| MCPY | 00 | 128 | 0 | 124 | 124 | 226176 | 1767.00 |
| RHST | 00 | 2048 | 32 | 19 | 9971 | 18187104 | 8880.42 |

clip 088 NXBM (section 24)

| tag | O | R | F | D | lines | T | T/rep |
|---|---|---|---|---|---|---|---|
| IDEN | 02 | 00FA | 0100 | 00C0 | | | |
| CPY0 | 00 | 128 | 0 | 124 | 124 | 226176 | 1767.00 |
| RFR0 | 00 | 1 | 1 | 148 | 459 | 837216 | 837216.00 |
| SPN0 | 00 | 512 | 47 | 107 | 14724 | 26856576 | 52454.25 |
| MRSW | 00 | 16 | 24 | -149 | 7315 | 13342560 | 833910.00 |
| MCN1 | 01 | 1CF8 | 0000 | 0000 | | | |
| MSPN | 00 | 512 | 47 | 189 | 14806 | 27006144 | 52746.38 |
| MCN2 | 01 | 3AA1 | 0000 | 0000 | | | |
| MHST | 00 | 2048 | 32 | 97 | 10049 | 18329376 | 8949.89 |
| MCN3 | 01 | 27C7 | 0000 | 0000 | | | |
| MSUM | 00 | AB14 | 06B1 | 0000 | | | |
| MPTR | 01 | 0003 | 0000 | 0000 | | | |
| MTCK | 00 | 00FA | 00FA | 0000 | | | |
| MCPY | 00 | 128 | 0 | 124 | 124 | 226176 | 1767.00 |
| RHST | 00 | 2048 | 32 | 19 | 9971 | 18187104 | 8880.42 |

clip 060 NXBP (section 26)

| tag | O | R | F | D | lines | T | T/rep |
|---|---|---|---|---|---|---|---|
| IDEN | 02 | 00FA | 0100 | 00C0 | | | |
| TCHK | 37 | 0725 | 060C | 0003 | | | |
| SPN0 | 00 | 512 | 47 | 92 | 14709 | 26829216 | 52400.81 |
| TSPN | 00 | 512 | 40 | 22 | 12462 | 22730688 | 44395.88 |
| TCTC | 00 | 512 | 42 | 170 | 13232 | 24135168 | 47139.00 |
| TCN1 | 00 | 6938 | 0000 | 0000 | | | |
| NSEC | 00 | 512 | 8 | -102 | 2386 | 4352064 | 8500.12 |
| NSM0 | 00 | 5E88 | 01C5 | 0000 | | | |
| TSTR | 00 | CB02 | 0393 | 0000 | | | |
| TSLO | 00 | 556B | 01C8 | 0000 | | | |
| TSUM | 00 | 8D61 | 070F | 0000 | | | |
| TSEC | 00 | 512 | 7 | 209 | 2386 | 4352064 | 8500.12 |

clip 063 NXBP (section 27)

| tag | O | R | F | D | lines | T | T/rep |
|---|---|---|---|---|---|---|---|
| IDEN | 12 | 00FA | 0118 | 00E0 | | | |
| TCHK | 37 | 0725 | 060C | 0003 | | | |
| SPN0 | 00 | 512 | 47 | 92 | 14709 | 26829216 | 52400.81 |
| TSPN | 00 | 512 | 40 | 22 | 12462 | 22730688 | 44395.88 |
| TCTC | 00 | 512 | 42 | 170 | 13232 | 24135168 | 47139.00 |
| TCN1 | 00 | 693A | 0000 | 0000 | | | |
| NSEC | 00 | 512 | 7 | 209 | 2386 | 4352064 | 8500.12 |
| NSM0 | 00 | 9DD6 | 019B | 0000 | | | |
| TSTR | 00 | A040 | 0348 | 0000 | | | |
| TSLO | 00 | 4D56 | 01A1 | 0000 | | | |
| TSUM | 00 | 3742 | 066D | 0000 | | | |
| TSEC | 00 | 512 | 8 | -103 | 2385 | 4350240 | 8496.56 |

clip 068 NXBP (section 28)

| tag | O | R | F | D | lines | T | T/rep |
|---|---|---|---|---|---|---|---|
| IDEN | 12 | 00FA | 0140 | 00C0 | | | |
| TCHK | 37 | 0725 | 060C | 0003 | | | |
| SPN0 | 00 | 512 | 47 | 92 | 14709 | 26829216 | 52400.81 |
| TSPN | 00 | 512 | 40 | 22 | 12462 | 22730688 | 44395.88 |
| TCTC | 00 | 512 | 42 | -1 | 13061 | 23823264 | 46529.81 |
| TCN1 | 00 | 33EE | 0000 | 0000 | | | |
| NSEC | 00 | 512 | 7 | 209 | 2386 | 4352064 | 8500.12 |
| NSM0 | 00 | 4D00 | 01C3 | 0000 | | | |
| TSTR | 00 | 9868 | 037C | 0000 | | | |
| TSLO | 00 | 701B | 01BF | 0000 | | | |
| TSUM | 00 | D531 | 070B | 0000 | | | |
| TSEC | 00 | 512 | 8 | -103 | 2385 | 4350240 | 8496.56 |

clip 088 NXBP (section 29)

| tag | O | R | F | D | lines | T | T/rep |
|---|---|---|---|---|---|---|---|
| IDEN | 02 | 00FA | 0100 | 00C0 | | | |
| TCHK | 37 | 0725 | 060C | 0003 | | | |
| SPN0 | 00 | 512 | 47 | 93 | 14710 | 26831040 | 52404.38 |
| TSPN | 00 | 512 | 40 | 22 | 12462 | 22730688 | 44395.88 |
| TCTC | 00 | 512 | 42 | -1 | 13061 | 23823264 | 46529.81 |
| TCN1 | 00 | 33EF | 0000 | 0000 | | | |
| NSEC | 00 | 512 | 7 | 209 | 2386 | 4352064 | 8500.12 |
| NSM0 | 00 | 603F | 01AB | 0000 | | | |
| TSTR | 00 | E712 | 0358 | 0000 | | | |
| TSLO | 00 | 5249 | 01A6 | 0000 | | | |
| TSUM | 00 | AD84 | 06B3 | 0000 | | | |
| TSEC | 00 | 512 | 8 | -103 | 2385 | 4350240 | 8496.56 |
