# Raw direct video sitting 1 - playback readouts (legs B and C)

Returned 2026-11-22. Leg B: sd folder LEGRAW1B, DEBUG build, staged at 3918c62. Leg C: sd folder LEGRAW1C, the kit's Release interpreter as on main.

## Recording notes (owner clarifications)

- The owner typed GO for every leg B step. Steps B.23 and B.24 (the sheet asked for LOOP) and B.26 (the sheet asked for GO with the stop key) are plain GO runs of clips 060, 063 and 062. They are recorded as repeat GO runs. Looping and the stop key were not exercised in this sitting.
- Clip 074 (B.18) never played on seven tries. The owner wrote "BLIP BLIP BLIP BLIP BLIP BLIP BLIP" and no rows were recorded. The card copy of 074.VID was verified byte-identical to the staged file afterwards. It is recorded as a FAILURE under investigation, with no interpretation.
- Clip 004 (B.28) printed RUNS=01 where the sheet expected 00. It is recorded as observed.
- The seven refusal clips (B.29 to B.35, clips 080 to 086) each printed `VID FMT?`.
- Picture and sound remarks: not recorded. Display socket: not recorded.

## Leg B readouts

Values as the owner wrote them. Every row with values also read ERR=00 OP=00 POS=000000, RING=0000/0000/00, SNAP=00. The Model columns are the gate's verdict for the clip (Release instructions, palette frame, stall term, sound period), from `python tests\raw_fit.py NXBENCH.TXT`. The comparison with LATE and URUN, and the predicted PLAY, are in report.md under "Playback (leg B)".

| Step | Clip | Typed | Sheet | FRM | PASS | FILL | PLAY | NOM | CHK | LATE | MAXL | URUN | RUNS | Model util | Model | Note |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| B.4 | 060 | GO | GO | 00FA/00FA | 01 | 0000 | 01EE | 01F4 | 0051D039 | 0000 | 0000 | 0000 | 01 | 0.8415 | admitted | |
| B.5 | 061 | GO | GO | 00FA/00FA | 01 | 0001 | 01EE | 01F4 | 008D0D14 | 0000 | 0000 | 0000 | 01 | 0.8860 | admitted | |
| B.6 | 062 | GO | GO | 00FA/00FA | 01 | 0001 | 020F | 01F4 | 0097F694 | 00F9 | 077E | 00F9 | 01 | 1.0485 | refused | |
| B.7 | 063 | GO | GO | 00FA/00FA | 01 | 0001 | 021D | 01F4 | 0089BBBA | 00F9 | 0694 | 00F9 | 01 | 1.0714 | refused | |
| B.8 | 064 | GO | GO | 00A7/00A7 | 01 | 0001 | 01EF | 01F3 | 007F8F6E | 0000 | 0000 | 0000 | 01 | 0.8672 | admitted | |
| B.9 | 065 | GO | GO | 00A7/00A7 | 01 | 0001 | 01EF | 01F3 | 0075521D | 0000 | 0000 | 0000 | 01 | 0.7030 | admitted | |
| B.10 | 066 | GO | GO | 00FA/00FA | 01 | 0001 | 01EE | 01F4 | 0051D039 | 0000 | 0000 | 0000 | 01 | 0.8214 | admitted | |
| B.11 | 067 | GO | GO | 00FA/00FA | 01 | 0001 | 01EE | 01F4 | 007A4829 | 0000 | 0000 | 0000 | 01 | 0.8652 | admitted | |
| B.12 | 068 | GO | GO | 00FA/00FA | 01 | 0001 | 0201 | 01F4 | 008C0AE3 | 00F9 | 02A0 | 00F9 | 01 | 1.0256 | refused | |
| B.13 | 069 | GO | GO | 00FA/00FA | 01 | 0001 | 020F | 01F4 | 00839290 | 00F9 | 02AF | 00F9 | 01 | 1.0482 | refused | |
| B.14 | 070 | GO | GO | 00A7/00A7 | 01 | 0001 | 01EF | 01F3 | 007F8F6E | 0000 | 0000 | 0000 | 01 | 0.8446 | admitted | |
| B.15 | 071 | GO | GO | 00A7/00A7 | 01 | 0001 | 01EF | 01F3 | 0075521D | 0000 | 0000 | 0000 | 01 | 0.6826 | admitted | |
| B.16 | 072 | GO | GO | 007D/007D | 01 | 0001 | 01EE | 01F4 | 00788813 | 0000 | 0000 | 0000 | 01 | 0.6885 | admitted | |
| B.17 | 073 | GO | GO | 00FA/00FA | 01 | 0001 | 01EE | 01F4 | 00150062 | 0000 | 0000 | 0000 | 01 | 0.8415 | admitted | |
| B.18 | 074 | GO | GO | - | - | - | - | - | - | - | - | - | - | 0.5094 | admitted | FAILURE under investigation: never played on seven tries; owner wrote BLIP BLIP BLIP BLIP BLIP BLIP BLIP; no rows |
| B.19 | 075 | GO | GO | 00F9/00F9 | 01 | 0000 | 01EC | 01F2 | 001521A3 | 0000 | 0000 | 0000 | 01 | 0.8415 | admitted | |
| B.20 | 076 | GO | GO | 00F9/00F9 | 01 | 0001 | 01EC | 01F2 | 001521A3 | 0000 | 0000 | 0000 | 01 | 0.8214 | admitted | |
| B.21 | 077 | GO | GO | 00C8/00C8 | 01 | 0001 | 018B | 0190 | 0046B5A3 | 0000 | 0000 | 0000 | 01 | 0.8415 | admitted | |
| B.22 | 078 | GO | GO | 00C8/00C8 | 01 | 0001 | 018B | 0190 | 0046B5A3 | 0000 | 0000 | 0000 | 01 | 0.8214 | admitted | |
| B.23 | 060 | GO | LOOP | 00FA/00FA | 01 | 0000 | 01EE | 01F4 | 0051D039 | 0000 | 0000 | 0000 | 01 | 0.8415 | admitted | repeat GO run; every field equals B.4's |
| B.24 | 063 | GO | LOOP | 00FA/00FA | 01 | 0001 | 021D | 01F4 | 00845933 | 00F9 | 0649 | 00F9 | 01 | 1.0714 | refused | repeat GO run |
| B.25 | 079 | GO | GO | 00FA/00FA | 01 | 0001 | 02C6 | 01F4 | 0078F35F | 00F9 | 09AE | 00F9 | 01 | 1.3616 | refused | |
| B.26 | 062 | GO | GO + SPACE | 00FA/00FA | 01 | 0001 | 020F | 01F4 | 0085F0B4 | 00F9 | 077E | 00F9 | 01 | 1.0485 | refused | repeat GO run; the stop key was not pressed |
| B.27 | 010 | GO | GO | 00FA/00FA | 01 | 0000 | 01EE | 01F4 | 001320C4 | 0000 | 0000 | 0000 | 01 | - | not modelled | old direct layout |
| B.28 | 004 | GO | GO | 002B/002B | 01 | 001A | 0055 | 0056 | 00302CC8 | 0000 | 0000 | 0000 | 01 | - | not modelled | delta clip; RUNS=01 where the sheet expected 00, as observed |
| B.29 | 080 | GO | GO | - | - | - | - | - | - | - | - | - | - | - | refusal clip | VID FMT? |
| B.30 | 081 | GO | GO | - | - | - | - | - | - | - | - | - | - | - | refusal clip | VID FMT? |
| B.31 | 082 | GO | GO | - | - | - | - | - | - | - | - | - | - | - | refusal clip | VID FMT? |
| B.32 | 083 | GO | GO | - | - | - | - | - | - | - | - | - | - | - | refusal clip | VID FMT? |
| B.33 | 084 | GO | GO | - | - | - | - | - | - | - | - | - | - | - | refusal clip | VID FMT? |
| B.34 | 085 | GO | GO | - | - | - | - | - | - | - | - | - | - | - | refusal clip | VID FMT? |
| B.35 | 086 | GO | GO | - | - | - | - | - | - | - | - | - | - | - | refusal clip | VID FMT? |

## Leg C

Shipping kit interpreter (Release, as on main) with clip 060: nothing played and the prompt returned.
