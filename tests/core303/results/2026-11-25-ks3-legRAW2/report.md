# Raw direct video - KS3 sitting 2 (2026-11-25)

Sitting: KS3, core 3.03.03 as stated for the sitting. Both legs staged from 4edad59 (clean tree). Leg A: DEBUG build, external card, log NXPLAY.TXT in this folder, 30 captures (table in playback.md). Leg B: Release build in a game screen, no log, checked by eye and ear. Clip 123 was written to the card in four pieces by the card fragmenting script (FRAGCARD.TXT in this folder). Fixture table: vidraw-pairs.txt. Details and the owner's note in sitting.txt.

Produced by:

- `python tests\core303\playlog.py NXPLAY.TXT --out playback.md` (exit 0)
- Model figures: the fixtures' projections made before the sitting with tests/raw_fit.py's model 1c functions (`debug_1c`, `ring_play`, `file_chk`; stereo and mono CTC 1792 T a sample, mono DMA 1799.64 T). raw_fit.py's own playback table scores only sitting 1c's leg B clips (060-088), so it was not used to score this log.

Definitions, as sitting 1c: model on time = DEBUG utilisation (pixels-only frame) <= 1.00; logged on time = LATE 0000 and URUN 0000. On-rate PLAY = frames x samples a frame x sample T / 567,264 (fields); window = the whole fields either side. Projected PLAY for a late clip from `ring_play`. CHK compared only on full plays of 256-surface clips (320-surface clips sum bar bytes left by earlier clips).

## Summary

- Every scored capture agrees with the DEBUG model: 21 on time as predicted (3 of them stopped by the key), 5 late as predicted (106 twice, 130, 132 on both sound paths), and the refusal. Every on-time PLAY lies in its on-rate window; every late PLAY is within one field of its projection.
- Fragmented clip 123: RUNS 04, two of the three boundaries inside the pixel sectors, PLAY equal to the unfragmented copy (125).
- Long clip 120: RUNS 05, 3000 frames, PLAY in its window, LATE and URUN 0000.
- Refusal 134: VID FMT? on DEBUG; silent on Release, no exception reported.
- Regression controls 010, 004: readouts as at sitting 1c except CHK (CHK on these clips differed between captures at sittings 1b and 1c too). 007: first logged play.
- Leg B: passed by the owner, no exception reported.
- Re-run requests: none.
- Stall budget: every budget-on fixture was byte-identical to its budget-off pair at every target shape (vidraw-pairs.txt, "Cost of the stall budget": 0 bytes), so nothing was compared on the board and the default stays `off`.

## Playback (leg A)

Shape is picture size and rate (surface in brackets). Path: S stereo, D mono DMA, C mono CTC, - not raw. Var: T column train, I inline. PLAY, NOM in fields (hex as logged, decimal in brackets for PLAY).

| cap | step | clip | shape | path | var | PLAY | NOM | LATE | MAXL | URUN | RUNS | CHK | model (DEBUG util px / pal) | expected PLAY | agrees |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | A.4 | 123 | 256x192@25 (256) | S | I | 01EC (492) | 01F2 | 0000 | 0000 | 0000 | 04 | 001521A3 = file | on time 0.7934 / 0.8053 | 491.6 (01EB-01EC) | yes |
| 2 | A.5 | 120 | 256x192@25 (256) | S | I | 1723 (5923) | 1770 | 0000 | 0000 | 0000 | 05 | 000F86F1 = file | on time 0.7934 / 0.8053 | 5923.2 (1723-1724) | yes |
| 3 | A.6 | 100 | 256x192@25 (256) | S | I | 01EE (494) | 01F4 | 0000 | 0000 | 0000 | 01 | 00150062 = file | on time 0.7934 / 0.8053 | 493.6 (01ED-01EE) | yes |
| 4 | A.7 | 102 | 320x160@25 (320) | S | T | 01EE (494) | 01F4 | 0000 | 0000 | 0000 | 01 | 003E60D9 barred | on time 0.8270 / 0.8389 | 493.6 (01ED-01EE) | yes |
| 5 | A.8 | 104 | 320x192@25 (320) | S | T | 01EE (494) | 01F4 | 0000 | 0000 | 0000 | 01 | 00344CE5 barred | on time 0.9863 / 0.9983 | 493.6 (01ED-01EE) | yes |
| 6 | A.9 | 106 | 280x224@25 (320) | S | T | 01F5 (501) | 01F4 | 00F9 | 051C | 00F9 | 01 | 002C8781 barred | late 1.0098 / 1.0217 | projected 500.4 | yes |
| 7 | A.9 | 106 | 280x224@25 (320) | S | T | 01F5 (501) | 01F4 | 00F9 | 051C | 00F9 | 01 | 002C8781 barred | late 1.0098 / 1.0217 | projected 500.4 | yes |
| 8 | A.10 | 108 | 320x240@16.67 (320) | S | I | 01EF (495) | 01F3 | 0000 | 0000 | 0000 | 01 | 002ACC33 barred | on time 0.8293 / 0.8372 | 494.3 (01EE-01EF) | yes |
| 9 | A.11 | 110 | 256x240@16.67 (320) | S | I | 01EF (495) | 01F3 | 0000 | 0000 | 0000 | 01 | 002ACC0A barred | on time 0.6683 / 0.6762 | 494.3 (01EE-01EF) | yes |
| 10 | A.12 LOOP, SPACE | 100 | 256x192@25 (256) | S | I | 08DC (2268) | 08FA | 0000 | 0000 | 0000 | 01 | 001581E2 not predicted | on time 0.7934 | 2268.6 for 1149 frames | yes |
| 11 | A.13 GO, SPACE | 104 | 320x192@25 (320) | S | T | 0132 (306) | 0136 | 0000 | 0000 | 0000 | 01 | 002454E7 not predicted | on time 0.9863 | 306.0 for 155 frames | yes |
| 12 | A.14 | 125 | 256x192@25 (256) | S | I | 01EC (492) | 01F2 | 0000 | 0000 | 0000 | 01 | 001521A3 = file | on time 0.7934 / 0.8053 | 491.6 (01EB-01EC) | yes |
| 13 | A.15 | 126 | 256x192@25 (256) | D | I | 01EE (494) | 01F2 | 0000 | 0000 | 0000 | 01 | 001521A3 = file | on time 0.7430 / 0.7540 | 493.7 (01ED-01EE) | yes |
| 14 | A.16 | 127 | 256x192@25 (256) | S | I | 018B (395) | 0190 | 0000 | 0000 | 0000 | 01 | 0046B5A3 = file | on time 0.7934 / 0.8053 | 394.9 (018A-018B) | yes |
| 15 | A.17 | 128 | 256x192@25 (256) | D | I | 018D (397) | 0190 | 0000 | 0000 | 0000 | 01 | 0046B5A3 = file | on time 0.7430 / 0.7540 | 396.6 (018C-018D) | yes |
| 16 | A.18 | 129 | 320x192@25 (320) | S | T | 01EC (492) | 01F2 | 0000 | 0000 | 0000 | 01 | 00340CFA barred | on time 0.9863 / 0.9983 | 491.6 (01EB-01EC) | yes |
| 17 | A.19 | 130 | 280x224@25 (320) | S | T | 01F3 (499) | 01F2 | 00F8 | 051C | 00F8 | 01 | 00581AE3 barred | late 1.0098 / 1.0217 | projected 498.4 | yes |
| 18 | A.20 | 131 | 320x192@25 (320) | S | T | 0251 (593) | 0258 | 0000 | 0000 | 0000 | 01 | 004D2924 barred | on time 0.9863 / 0.9983 | 592.3 (0250-0251) | yes |
| 19 | A.20 | 131 | 320x192@25 (320) | S | T | 0251 (593) | 0258 | 0000 | 0000 | 0000 | 01 | 004D2924 barred | on time 0.9863 / 0.9983 | 592.3 (0250-0251) | yes |
| 20 | A.21 | 132 | 320x208@25 (320) | D | I | 01F5 (501) | 01F2 | 00F8 | 0290 | 00F8 | 01 | 002FCEAD barred | late 1.0098 / 1.0208 | projected 500.6 | yes |
| 21 | A.22 | 133 | 280x224@25 (320) | D | T | 01EE (494) | 01F2 | 0000 | 0000 | 0000 | 01 | 002DCB95 barred | on time 0.9475 / 0.9585 | 493.7 (01ED-01EE) | yes |
| 22 | A.23 | 134 | width word 324 | - | - | - | - | - | - | - | - | - | refused at open | row 23 VID FMT? | yes |
| 23 | A.25 | 126 | 256x192@25 (256) | C | I | 01EC (492) | 01F2 | 0000 | 0000 | 0000 | 01 | 001521A3 = file | on time 0.7750 / 0.7865 | 491.6 (01EB-01EC) | yes |
| 24 | A.26 | 128 | 256x192@25 (256) | C | I | 018B (395) | 0190 | 0000 | 0000 | 0000 | 01 | 0046B5A3 = file | on time 0.7750 / 0.7865 | 394.9 (018A-018B) | yes |
| 25 | A.27 | 132 | 320x208@25 (320) | C | I | 020A (522) | 01F2 | 00F8 | 0474 | 00F8 | 01 | 002F817B barred | late 1.0538 / 1.0653 | projected 522.0 (2 ring waits) | yes |
| 26 | A.28 | 133 | 280x224@25 (320) | C | T | 01EC (492) | 01F2 | 0000 | 0000 | 0000 | 01 | 002DCB95 barred | on time 0.9887 / 1.0002 | 491.6 (01EB-01EC) | yes |
| 27 | A.30 GO, SPACE | 126 | 256x192@25 (256) | D | I | 0115 (277) | 0118 | 0000 | 0000 | 0000 | 01 | 0010B002 not predicted | on time 0.7430 | 277.6 for 140 frames | yes |
| 28 | A.31 | 004 | delta 320x144@25 | S | - | 0055 | 0056 | 0000 | 0000 | 0000 | 00 | 00210D3C | outside the raw model | - | - |
| 29 | A.32 | 010 | old direct 256x167@25 | S | - | 01EE | 01F4 | 0000 | 0000 | 0000 | 01 | 00143D9C | outside the raw model | - | - |
| 30 | A.33 | 007 | streamed delta 256x192@25 | S | - | 01EE | 01F4 | 0000 | 0000 | 0000 | 01 | 0012C126 | outside the raw model | - | - |

- Every capture with a report reads ERR=00 OP=00 POS=000000, SNAP=00, pool 50; RING=0000/0000/00 on every capture but 007 (002A/0000/00: streamed clip, minimum ring depth 002A, no underrun, no clamp).
- FRM equals the clip's frame count on every full play; PASS 01 except the loop (05).
- CHK on full plays of 256-surface clips against the file's last two frames' pixel sum: 9 compared (123, 120, 100, 125, 126 D, 127, 128 D, 126 C, 128 C), 9 equal. Barred 320-surface clips are not compared.
- Captures per clip: one play each of the A.6-A.11 clips except 106 (two); 131 two; the sheet asked three at A.6-A.11. Not treated as a fault.
- MCTC (A.24) and MDMA (A.29) play nothing and write no capture.

## Fragmented clip (123)

| boundary byte | file sector | frame | sector of the frame | kind |
|---|---|---|---|---|
| 3145728 | 6144 | 62 | 3 | pixel (the first pixel sector: sectors 0-2 are sound) |
| 6324224 | 12352 | 124 | 69 | inside the pixel sectors |
| 9502720 | 18560 | 187 | 37 | inside the pixel sectors |

- Card FAT32, cluster 32768 bytes; four chunks of 96, 97, 97 and 96 clusters with a one-byte pin file after each of the first three; the script compared the card copy with the source byte for byte (equal). Frame and sector count from 0.
- Logged: RUNS 04 (owner's note A.4: RUNS=04), FRM 00F9/00F9, PLAY 01EC, LATE / URUN 0000, CHK 001521A3 = file.
- Clip 125 (the same bytes, one piece on the card): PLAY 01EC, CHK 001521A3. The fragmented copy gives the same PLAY.
- Picture and sound across the boundary frames: no exception reported.

## Long clip (120)

- 3000 frames (2 minutes; Sintel, Big Buck Bunny, jellyfish in turn), stereo 256x192@25, inline.
- Logged: RUNS 05 (owner's note A.5: RUNS=05; 297,058 blocks / 65,535 gives 5 for a copy in one piece), FRM 0BB8/0BB8, PASS 01, PLAY 1723 (5923) against the on-rate 5923.2 (window 1723-1724), NOM 1770, LATE / MAXL / URUN 0000, CHK 000F86F1 = file.
- No exception reported (drift, click, hang).

## Warned stereo clip (106, 280x224@25)

- DEBUG (two plays, A.9): LATE 00F9 and URUN 00F9 of 250 frames, MAXL 051C (1308 bytes of sound, 41.9 ms at 2 bytes a sample and 15,625 Hz), PLAY 01F5 (501) against projected 500.4; both plays identical, CHK equal. The DEBUG model puts the whole clip late (1.0098 pixels-only), as at sitting 1c for 063 (the same shape: LATE 00F9, MAXL 051C, PLAY 01F5).
- Owner, by eye on DEBUG: "watched twice, didn't notice a stutter but it's hard to tell because the cuts are so fast."
- Release (B.7): reported "smooth". Release gate 0.9970 pixels-only / 1.0088 palette frame; the encoder warned of a stutter near frame 188 (2.0 percent of a frame).

## Tightest stereo shape (130, 280x224@25, one palette)

- DEBUG (A.19): LATE 00F8, URUN 00F8, MAXL 051C (41.9 ms), PLAY 01F3 (499) against projected 498.4. Model late (1.0098 / 1.0217): agrees.
- Release (B.23): no exception reported. Release gate 0.9970 / 1.0088 (palette on frame 0 only).

## Mono edge clips (132, 133) and their CTC plays

| clip | shape | path | DEBUG util px / pal | model | PLAY | expected | LATE | MAXL | URUN | agrees |
|---|---|---|---|---|---|---|---|---|---|---|
| 132 | 320x208@25 inline | D | 1.0098 / 1.0208 | late | 01F5 (501) | projected 500.6 | 00F8 | 0290 (656 B, 42.2 ms at 15,558.7 Hz) | 00F8 | yes |
| 132 | 320x208@25 inline | C | 1.0538 / 1.0653 | late | 020A (522) | projected 522.0 | 00F8 | 0474 (1140 B, 73.0 ms at 15,625 Hz) | 00F8 | yes |
| 133 | 280x224@25 train | D | 0.9475 / 0.9585 | on time | 01EE (494) | 493.7 (01ED-01EE) | 0000 | 0000 | 0000 | yes |
| 133 | 280x224@25 train | C | 0.9887 / 1.0002 | on time (palette frames at the edge) | 01EC (492) | 491.6 (01EB-01EC) | 0000 | 0000 | 0000 | yes |

- The Release gate admits 132 on the DMA path only (0.9971 / 1.0080; CTC path 1.0406 / 1.0521).
- Release B.25 (132) and B.26 (133), DMA path: no exception reported.

## Stop-key plays

| step | clip | path | FRM | PASS | PLAY | on-rate for the frames played |
|---|---|---|---|---|---|---|
| A.12 LOOP, SPACE in the fifth pass | 100 | S | 047D (1149) | 05 | 08DC (2268) | 2268.6 |
| A.13 GO, SPACE about 5 s in | 104 | S | 009B (155) | 01 | 0132 (306) | 306.0 |
| A.30 GO, SPACE about 3 s in, after MDMA | 126 | D | 008C (140) | 01 | 0115 (277) | 277.6 |

- No "full" note at A.13 or A.30; no buzz or sound after the stop reported.
- Release B.10 (100 LOOP, SPACE in the third pass, music running before): no exception reported.

## Refusal (134)

- DEBUG (A.23): header `#PLAY 134 50 97A4 - -`, row 23 `VID FMT?`, no report rows, as expected.
- Release (B.29): no exception reported (the refusal prints nothing in Release).

## Regression controls

| clip | sitting | FRM | PASS | FILL | PLAY | NOM | LATE | URUN | RUNS | CHK |
|---|---|---|---|---|---|---|---|---|---|---|
| 010 | 2 (A.32) | 00FA/00FA | 01 | 0000 | 01EE | 01F4 | 0000 | 0000 | 01 | 00143D9C |
| 010 | 1c (B.25) | 00FA/00FA | 01 | 0000 | 01EE | 01F4 | 0000 | 0000 | 01 | 0014C291 |
| 010 | 1b | - | - | - | - | - | - | - | - | 001AAD66 |
| 004 | 2 (A.31, after the A.30 mono DMA stop) | 002B/002B | 01 | 001A | 0055 | 0056 | 0000 | 0000 | 00 | 00210D3C |
| 004 | 1c (B.3) | 002B/002B | 01 | 001A | 0055 | 0056 | 0000 | 0000 | 00 | 006A6DA8 |
| 004 | 1c (B.24, after the DMA clips) | 002B/002B | 01 | 001A | 0055 | 0056 | 0000 | 0000 | 00 | 006E7C60 |
| 004 | 1b | - | - | - | - | - | - | - | - | 006A8424, 006748B5 |
| 007 | 2 (A.33) | 00FA/00FA | 01 | 0028 | 01EE | 01F4 | 0000 | 0000 | 01 | 0012C126 |

- 010 and 004 read as at sitting 1c in every field but CHK. CHK on these clips also sums bytes left by earlier clips and has differed between every pair of captures since sitting 1b.
- 007: first logged play; no earlier value to compare. RING 002A/0000/00 (streamed).
- Leg A ran the same DEBUG image bytes as sitting 1c leg B (sitting.txt).
- Release B.20 (004 after the mono DMA clip and the sample), B.27 (010), B.28 (007): no exception reported.

## Sound checks

| check | clips and steps | result |
|---|---|---|
| left / right order | 127: A.16 (DEBUG), B.13 (Release) | no exception reported |
| mono on both speakers, equal level | 128: A.17 (D), A.26 (C), B.15 (Release, D) | no exception reported |
| film soundtrack, clicks at seams | 125 (A.14, B.11), 126 (A.15 D, A.25 C, B.12 D), 129, 130, 131, 132, 133, 120 | no exception reported |
| stop click or buzz | A.30 (126, D) | no exception reported |
| sample across a DMA picture draw after a DMA clip (NR $CD restore) | B.15-B.18 | no exception reported |
| sampled effect after a raw clip (IM2 entry restore) | B.16 | no exception reported |
| music back after each clip | leg B | no exception reported |

"No exception reported" is the absence of a note, not an observation.

## Leg B (Release)

- Owner: "B.7 smooth. Leg B pass." No exception reported at B.1-B.30.
- Release NEX sha256 ddf96a3a... (sitting.txt): the same bytes as the kit interpreter refreshed with these results.

## Re-run requests

None. No capture disagrees with the model, no readout is outside its window, no exception was reported.

## Not tested in this sitting

- A 256-wide game picture restored after a 320-wide clip (every leg B picture is 320 wide).
- Three repeats per shape (one play of most A.6-A.11 clips, two of 106).
- A clip from the 320x192@16.67 preset (action-169); 320x192 was played at 25 fps only.
- The internal card slot (external card only).
- The budget-on clips 101-111 and 121 (byte-identical to 100-110 and 120; not staged).
- The -VidRawBench clips 073-086 and the over-rate clip 079.
- An abort (error) exit on a mono DMA clip; only the stop key.
- The previous kit interpreter against raw clips.
