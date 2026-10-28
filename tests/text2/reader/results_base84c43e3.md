# Task 6 reader legs (CSpect 4.3 MCP) _base84c43e3

Interpreter: Release build at 84c43e3

| test | expect | got | result | evidence |
|---|---|---|---|---|

Notes:

- Walk screens are the 80x32 tilemap text after each step settles (screens.json per leg folder, stepNN.png at the end of each step). The four SM2-SM5 prompt lines are compared as one placeholder: DAAD picks one at random (flag 42 = 0), so they differ between runs of the same build.
- More... is detected as tilemap text and answered with press_keys SPACE; the count must match between the two legs as well.
- Timing: print_msg entry (breakpoint, A = 1, E = 48) to its return address, frameCounter and the raster line (NR $1E/$1F) read at both stops; ms = lines x 64 us. CSpect 4.3, emulated core timing: not a silicon figure; re-measure on hardware, and again after the core that drops the 28 MHz wait states.
- f1_identity: the format 1 controls walked on the 84c43e3 Release build (_base84c43e3) and on this Release build (_release) give equal screens at every step.
- Launch records: launches*.log (each CSpect killed by PID).
- xmb_part_fallback (TEXT2X2): NDPARTA (format 1, -v3) boots, XPARTs to GAME2.DDB = NEST4 format 2; no PART2 folder, so READ's 0.XMB comes from the root (format 1).
