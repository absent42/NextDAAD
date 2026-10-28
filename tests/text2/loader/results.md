# Task 5 loader legs (CSpect 4.3 MCP)

| card | expect | got | result | screenshot |
|---|---|---|---|---|
| TEXT2 | textFormat 1, tables = t2model (187 symbols), no E-code | all 11 fields match; ntok 128 alpha 0 block $017F index $0206 | PASS | shot_TEXT2.png |
| TEXT2C | textFormat 0, no E-code, game screen | textFormat 0 text2Err 0 row0 'OBJVERIF - compressed object' | PASS | shot_TEXT2C.png |
| TEXT2BAD\MAGIC | E5 screen, text2Err 1 | text2Err 1 row0 'NextDAAD: DDB text format - E5' | PASS | shot_TEXT2BAD_MAGIC.png |
| TEXT2BAD\FLAGS | E5 screen, text2Err 2 | text2Err 2 row0 'NextDAAD: DDB text format - E5' | PASS | shot_TEXT2BAD_FLAGS.png |
| TEXT2BAD\NTOK | E5 screen, text2Err 3 | text2Err 3 row0 'NextDAAD: DDB text format - E5' | PASS | shot_TEXT2BAD_NTOK.png |
| TEXT2BAD\FP | E5 screen, text2Err 4 | text2Err 4 row0 'NextDAAD: DDB text format - E5' | PASS | shot_TEXT2BAD_FP.png |
| TEXT2BAD\EOM | E5 screen, text2Err 5 | text2Err 5 row0 'NextDAAD: DDB text format - E5' | PASS | shot_TEXT2BAD_EOM.png |
| TEXT2BAD\SYM | E5 screen, text2Err 6 | text2Err 6 row0 'NextDAAD: DDB text format - E5' | PASS | shot_TEXT2BAD_SYM.png |
| TEXT2BAD\KRAFT | E5 screen, text2Err 7 | text2Err 7 row0 'NextDAAD: DDB text format - E5' | PASS | shot_TEXT2BAD_KRAFT.png |
| TEXT2BAD\BUDGET | E5 screen, text2Err 8 | text2Err 8 row0 'NextDAAD: DDB text format - E5' | PASS | shot_TEXT2BAD_BUDGET.png |

Launches:

- launch `D:\ZXNextDev\cspect\CSpect.exe -w2 -zxnext -esc -mcp=23456 -mmc=D:\NextDAAD\sd\TEXT2\ D:\NextDAAD\build\nextdaad.nex` PID 20216
  killed PID 20216
- launch `D:\ZXNextDev\cspect\CSpect.exe -w2 -zxnext -esc -mcp=23456 -mmc=D:\NextDAAD\sd\TEXT2C\ D:\NextDAAD\build\nextdaad.nex` PID 45352
  killed PID 45352
- launch `D:\ZXNextDev\cspect\CSpect.exe -w2 -zxnext -esc -mcp=23456 -mmc=D:\NextDAAD\sd\TEXT2BAD\MAGIC\ D:\NextDAAD\build\nextdaad.nex` PID 64860
  killed PID 64860
- launch `D:\ZXNextDev\cspect\CSpect.exe -w2 -zxnext -esc -mcp=23456 -mmc=D:\NextDAAD\sd\TEXT2BAD\FLAGS\ D:\NextDAAD\build\nextdaad.nex` PID 74384
  killed PID 74384
- launch `D:\ZXNextDev\cspect\CSpect.exe -w2 -zxnext -esc -mcp=23456 -mmc=D:\NextDAAD\sd\TEXT2BAD\NTOK\ D:\NextDAAD\build\nextdaad.nex` PID 66188
  killed PID 66188
- launch `D:\ZXNextDev\cspect\CSpect.exe -w2 -zxnext -esc -mcp=23456 -mmc=D:\NextDAAD\sd\TEXT2BAD\FP\ D:\NextDAAD\build\nextdaad.nex` PID 38452
  killed PID 38452
- launch `D:\ZXNextDev\cspect\CSpect.exe -w2 -zxnext -esc -mcp=23456 -mmc=D:\NextDAAD\sd\TEXT2BAD\EOM\ D:\NextDAAD\build\nextdaad.nex` PID 28956
  killed PID 28956
- launch `D:\ZXNextDev\cspect\CSpect.exe -w2 -zxnext -esc -mcp=23456 -mmc=D:\NextDAAD\sd\TEXT2BAD\SYM\ D:\NextDAAD\build\nextdaad.nex` PID 22584
  killed PID 22584
- launch `D:\ZXNextDev\cspect\CSpect.exe -w2 -zxnext -esc -mcp=23456 -mmc=D:\NextDAAD\sd\TEXT2BAD\KRAFT\ D:\NextDAAD\build\nextdaad.nex` PID 38164
  killed PID 38164
- launch `D:\ZXNextDev\cspect\CSpect.exe -w2 -zxnext -esc -mcp=23456 -mmc=D:\NextDAAD\sd\TEXT2BAD\BUDGET\ D:\NextDAAD\build\nextdaad.nex` PID 65752
  killed PID 65752

Notes:

- Interpreter: DEBUG build of this commit's tree (build\nextdaad.nex, SHA-256 prefix 231DF922A5327119, the copy staged as NEXTDAAD.NEX in every card); results_release.md is the same check on the Release build for TEXT2, TEXT2C and TEXT2BAD\FP.
- First run of TEXT2: FAIL (E5 on the good card, every table right except hfSym all zero): t2_tables returned CF set because first*2 at length 15 carries out on a complete code, so t2_build refused at T2E_KRAFT before the list fill. Fixed with an explicit or a before the return; the run above is after the fix.
- TEXT2C screenshot is pixel-identical to baseline_TEXT2C_2779ca9.png (DEBUG build of 2779ca9, before this task, same card).
- TEXT2 boots with no E-code but prints nothing legible: the format 1 reader cannot read format 2 text; printing is Task 6.
- TEXT2BAD cards are patched copies of the TEXT2 DDB built by tests/build-tests.ps1 -Text2Bad; tests/text2/t2model.py predicts each refusal code.
