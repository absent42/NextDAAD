# Task 6 reader legs (CSpect 4.3 MCP) _release

Interpreter: Release build (build.ps1 -Release)

| test | expect | got | result | evidence |
|---|---|---|---|---|
| objverif_walk TEXT2 vs TEXT2C | 37 steps, screens equal per step | equal (8 More... prompts answered) | PASS | reader/TEXT2_release/, reader/TEXT2C_release/ |
| objverif_walk TEXT2W vs TEXT2WC | 37 steps, screens equal per step | equal (8 More... prompts answered) | PASS | reader/TEXT2W_release/, reader/TEXT2WC_release/ |
| nest4_walk TEXT2N vs TEXT2NC | 32 steps, screens equal per step | equal (10 More... prompts answered) | PASS | reader/TEXT2N_release/, reader/TEXT2NC_release/ |
| xmb_walk TEXT2N vs TEXT2NC | 3 steps, screens equal per step | equal (3 More... prompts answered) | PASS | reader/TEXT2N_xmb_release/, reader/TEXT2NC_xmb_release/ |
| xmb_mismatch_refused TEXT2X | LOOK plays; READ -> E5 screen, text2Err 8 | row0 'NextDAAD: DDB text format - E5' text2Err 8 | PASS | reader/TEXT2X_release/ |
| timing STORY (MESSAGE 48) print_msg | recorded, format 2 vs format 1 (311 lines x 64 us per frame) | TEXT2N [33.09, 33.09, 33.09] ms; TEXT2NC [53.31, 53.31, 53.31] ms | RECORDED | reader/timing_release.json |
| f1_identity TEXT2C _base84c43e3 vs _release | format 1 screens equal per step (37 steps) | equal | PASS | reader/TEXT2C_f1_base84c43e3/, reader/TEXT2C_f1_release/ |
| f1_identity TEXT2WC _base84c43e3 vs _release | format 1 screens equal per step (37 steps) | equal | PASS | reader/TEXT2WC_f1_base84c43e3/, reader/TEXT2WC_f1_release/ |
| f1_identity TEXT2NC _base84c43e3 vs _release | format 1 screens equal per step (34 steps) | equal | PASS | reader/TEXT2NC_f1_base84c43e3/, reader/TEXT2NC_f1_release/ |

Notes:

- Walk screens are the 80x32 tilemap text after each step settles (screens.json per leg folder, stepNN.png at the end of each step). The four SM2-SM5 prompt lines are compared as one placeholder: DAAD picks one at random (flag 42 = 0), so they differ between runs of the same build.
- More... is detected as tilemap text and answered with press_keys SPACE; the count must match between the two legs as well.
- Timing: print_msg entry (breakpoint, A = 1, E = 48) to its return address, frameCounter and the raster line (NR $1E/$1F) read at both stops; ms = lines x 64 us. CSpect 4.3, emulated core timing: not a silicon figure; re-measure on hardware, and again after the core that drops the 28 MHz wait states.
- f1_identity: the format 1 controls walked on the 84c43e3 Release build (_base84c43e3) and on this Release build (_release) give equal screens at every step.
- Launch records: launches*.log (each CSpect killed by PID).
- xmb_part_fallback (TEXT2X2): NDPARTA (format 1, -v3) boots, XPARTs to GAME2.DDB = NEST4 format 2; no PART2 folder, so READ's 0.XMB comes from the root (format 1).
