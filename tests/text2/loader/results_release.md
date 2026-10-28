# Task 5 loader legs (CSpect 4.3 MCP)

| card | expect | got | result | screenshot |
|---|---|---|---|---|
| TEXT2 | textFormat 1, tables = t2model (187 symbols), no E-code | all 11 fields match; ntok 128 alpha 0 block $017F index $0206 | PASS | shot_release_TEXT2.png |
| TEXT2C | textFormat 0, no E-code, game screen | textFormat 0 text2Err 0 row0 'OBJVERIF - compressed object' | PASS | shot_release_TEXT2C.png |
| TEXT2BAD\FP | E5 screen, text2Err 4 | text2Err 4 row0 'NextDAAD: DDB text format - E5' | PASS | shot_release_TEXT2BAD_FP.png |

Launches:

- launch `D:\ZXNextDev\cspect\CSpect.exe -w2 -zxnext -esc -mcp=23456 -mmc=D:\NextDAAD\sd\TEXT2\ D:\NextDAAD\build\nextdaad.nex` PID 69180
  killed PID 69180
- launch `D:\ZXNextDev\cspect\CSpect.exe -w2 -zxnext -esc -mcp=23456 -mmc=D:\NextDAAD\sd\TEXT2C\ D:\NextDAAD\build\nextdaad.nex` PID 43732
  killed PID 43732
- launch `D:\ZXNextDev\cspect\CSpect.exe -w2 -zxnext -esc -mcp=23456 -mmc=D:\NextDAAD\sd\TEXT2BAD\FP\ D:\NextDAAD\build\nextdaad.nex` PID 66712
  killed PID 66712
