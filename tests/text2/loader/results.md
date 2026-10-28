# Task 5 loader legs (CSpect 4.3 MCP)

| card | expect | got | result | screenshot |
|---|---|---|---|---|
| TEXT2 | textFormat 1, tables = t2model (187 symbols), no E-code | all 11 fields match; ntok 128 alpha 0 block $017F index $0206 | PASS | shot_TEXT2.png |
| TEXT2W | textFormat 1, tables = t2model (299 symbols), no E-code | all 11 fields match; ntok 243 alpha 1 block $0172 index $0279 | PASS | shot_TEXT2W.png |
| TEXT2C | textFormat 0, no E-code, game screen | textFormat 0 text2Err 0 row0 'OBJVERIF - compressed object' | PASS | shot_TEXT2C.png |
| TEXT2BAD\MAGIC | E5 screen, text2Err 1 | text2Err 1 row0 'NextDAAD: DDB text format - E5' | PASS | shot_TEXT2BAD_MAGIC.png |
| TEXT2BAD\FLAGS | E5 screen, text2Err 2 | text2Err 2 row0 'NextDAAD: DDB text format - E5' | PASS | shot_TEXT2BAD_FLAGS.png |
| TEXT2BAD\NTOK | E5 screen, text2Err 3 | text2Err 3 row0 'NextDAAD: DDB text format - E5' | PASS | shot_TEXT2BAD_NTOK.png |
| TEXT2BAD\FP | E5 screen, text2Err 4 | text2Err 4 row0 'NextDAAD: DDB text format - E5' | PASS | shot_TEXT2BAD_FP.png |
| TEXT2BAD\EOM | E5 screen, text2Err 5 | text2Err 5 row0 'NextDAAD: DDB text format - E5' | PASS | shot_TEXT2BAD_EOM.png |
| TEXT2BAD\SYM | E5 screen, text2Err 6 | text2Err 6 row0 'NextDAAD: DDB text format - E5' | PASS | shot_TEXT2BAD_SYM.png |
| TEXT2BAD\KRAFT | E5 screen, text2Err 7 | text2Err 7 row0 'NextDAAD: DDB text format - E5' | PASS | shot_TEXT2BAD_KRAFT.png |

Launches:

- launch `D:\ZXNextDev\cspect\CSpect.exe -w2 -zxnext -esc -mcp=23456 -mmc=D:\NextDAAD\sd\TEXT2\ D:\NextDAAD\build\nextdaad.nex` PID 26036
  killed PID 26036
- launch `D:\ZXNextDev\cspect\CSpect.exe -w2 -zxnext -esc -mcp=23456 -mmc=D:\NextDAAD\sd\TEXT2W\ D:\NextDAAD\build\nextdaad.nex` PID 51720
  killed PID 51720
- launch `D:\ZXNextDev\cspect\CSpect.exe -w2 -zxnext -esc -mcp=23456 -mmc=D:\NextDAAD\sd\TEXT2C\ D:\NextDAAD\build\nextdaad.nex` PID 77552
  killed PID 77552
- launch `D:\ZXNextDev\cspect\CSpect.exe -w2 -zxnext -esc -mcp=23456 -mmc=D:\NextDAAD\sd\TEXT2BAD\MAGIC\ D:\NextDAAD\build\nextdaad.nex` PID 62976
  killed PID 62976
- launch `D:\ZXNextDev\cspect\CSpect.exe -w2 -zxnext -esc -mcp=23456 -mmc=D:\NextDAAD\sd\TEXT2BAD\FLAGS\ D:\NextDAAD\build\nextdaad.nex` PID 64408
  killed PID 64408
- launch `D:\ZXNextDev\cspect\CSpect.exe -w2 -zxnext -esc -mcp=23456 -mmc=D:\NextDAAD\sd\TEXT2BAD\NTOK\ D:\NextDAAD\build\nextdaad.nex` PID 69164
  killed PID 69164
- launch `D:\ZXNextDev\cspect\CSpect.exe -w2 -zxnext -esc -mcp=23456 -mmc=D:\NextDAAD\sd\TEXT2BAD\FP\ D:\NextDAAD\build\nextdaad.nex` PID 63956
  killed PID 63956
- launch `D:\ZXNextDev\cspect\CSpect.exe -w2 -zxnext -esc -mcp=23456 -mmc=D:\NextDAAD\sd\TEXT2BAD\EOM\ D:\NextDAAD\build\nextdaad.nex` PID 19548
  killed PID 19548
- launch `D:\ZXNextDev\cspect\CSpect.exe -w2 -zxnext -esc -mcp=23456 -mmc=D:\NextDAAD\sd\TEXT2BAD\SYM\ D:\NextDAAD\build\nextdaad.nex` PID 49500
  killed PID 49500
- launch `D:\ZXNextDev\cspect\CSpect.exe -w2 -zxnext -esc -mcp=23456 -mmc=D:\NextDAAD\sd\TEXT2BAD\KRAFT\ D:\NextDAAD\build\nextdaad.nex` PID 35176
  killed PID 35176

Notes (Task 5b, HEAD after the 511-symbol list):

- Interpreter: DEBUG build (build\nextdaad.nex, SHA-256 prefix 72F1B737658DB43C, staged as NEXTDAAD.NEX in every card); results_release.md repeats TEXT2, TEXT2W, TEXT2C and TEXT2BAD\FP on the Release build.
- TEXT2W is OBJVERIF3 (383-token alphabet, flags 1, ntok 243, 299 used symbols, 115 of them >= 256): hfHi = 163 at length 9 and 270 at length 10, $FFFF elsewhere; hfSym (299 bytes) and every other cell match tests/text2/t2model.py (tables_TEXT2W.json).
- The former BUDGET card (more than 256 used symbols) is retired: HF_SYM_MAX is now 511 and no valid block can exceed it; TEXT2W is the real-compile positive case.
- TEXT2C screenshot is still pixel-identical to baseline_TEXT2C_2779ca9.png.
- TEXT2 and TEXT2W print nothing legible: the format 1 reader cannot read format 2 text; printing is Task 6.
- An earlier run (Task 5, now superseded) found and fixed a carry out of t2_tables at length 15 that refused the good card at T2E_KRAFT.
