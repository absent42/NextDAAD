# CORE303 report

## PI f050fed

NR: 01=33 0E=03 0F=03 03=33 05=5B 07=33 A0=00  SRAM: 2048 KB

### Part 0

| tag | op | method | size | T/rep | T/unit | notes |
|---|---|---|---|---|---|---|
| CAL0 | poll | CPU | - | 337.05 | - |  |

### Part P3

| tag | op | method | size | T/rep | T/unit | notes |
|---|---|---|---|---|---|---|
| P3NP | NOP | CPU | - | 16720.84 | 4.00 |  |
| U3NP | NOP | CPU | - | 16720.84 | 4.00 |  |
| S3NP | NOP | CPU | - | 16720.84 | 4.00 |  |
| B3NP | NOP | CPU | - | 16721.68 | 4.00 |  |
| P3RS | LD A,(HL) SRAM | CPU | - | 26980.56 | 13.01 |  |
| U3RS | LD A,(HL) SRAM | CPU | - | 26980.56 | 13.01 |  |
| S3RS | LD A,(HL) SRAM | CPU | - | 26980.56 | 13.01 |  |
| B3RS | LD A,(HL) SRAM | CPU | - | 26980.56 | 13.01 |  |
| P3R5 | LD A,(HL) bank 5 | CPU | - | 26980.56 | 13.01 |  |
| U3R5 | LD A,(HL) bank 5 | CPU | - | 26980.56 | 13.01 |  |
| S3R5 | LD A,(HL) bank 5 | CPU | - | 26980.56 | 13.01 |  |
| B3R5 | LD A,(HL) bank 5 | CPU | - | 26980.56 | 13.01 |  |
| P3LR | LDIR SRAM | CPU | - | 21866.04 | 21.02 |  |
| U3LR | LDIR SRAM | CPU | - | 21866.04 | 21.02 |  |
| S3LR | LDIR SRAM | CPU | - | 21866.04 | 21.02 |  |
| B3LR | LDIR SRAM | CPU | - | 21866.04 | 21.02 |  |
| P3BF Q=002 | blitter fill | BLT | - | 8714.86 | 2.05 |  |
| U3BF Q=002 | blitter fill | BLT | - | 8714.86 | 2.05 |  |
| S3BF Q=002 | blitter fill | BLT | - | 8714.86 | 2.05 |  |
| B3BF Q=002 | blitter fill | BLT | - | 8714.86 | 2.05 |  |
| P3B7 | bank 7 restore | CPU | - | 21888.00 | 21.05 | SHORT |
| P3B5 | bank 5 restore | CPU | - | 21888.00 | 21.05 | SHORT |


# CORE303 Pi report

Next log: PI f050fed

## pi303_spi 5f165f33ea7c

ENV: model=Raspberry_Pi_Zero_Rev_1.3 governor=ondemand arm_khz=700000 kernel=6.12.67-0-rpi py=3.12.12 numpy=2.3.5 pil=11.3.0 gcc=15.2.0 bufsiz=4096 spi_max_saved=2000000 spi_max_stale=0 spi_open=2198,2626
SPI: version=10 caps=FF core_clk=0 core_clk_src=none spi_max_restored=2000000

| tag | fields |
|---|---|
| P3TE | est_s=3138 rates=21 |
| P3EF | req_hz=2000000 eff_hz=1248334 t512=3571000 t4000=25924000 merged=0 |
| P3EF | req_hz=2500000 eff_hz=1555841 t512=2910000 t4000=20845000 merged=0 |
| P3EF | req_hz=3000000 eff_hz=1853101 t512=2503000 t4000=17561000 merged=0 |
| P3EF | req_hz=3500000 eff_hz=2135783 t512=2232000 t4000=15297000 merged=0 |
| P3EF | req_hz=4000000 eff_hz=2497002 t512=1971000 t4000=13146000 merged=0 |
| P3EF | req_hz=4500000 eff_hz=2767979 t512=1747000 t4000=11828000 merged=0 |
| P3EF | req_hz=5000000 eff_hz=3113938 t512=1592000 t4000=10553000 merged=0 |
| P3EF | req_hz=5500000 eff_hz=3367202 t512=1498000 t4000=9785000 merged=0 |
| P3EF | req_hz=6000000 eff_hz=3644723 t512=1400000 t4000=9056000 merged=0 |
| P3EF | req_hz=6500000 eff_hz=4017855 t512=1349000 t4000=8294000 merged=0 |
| P3EF | req_hz=7000000 eff_hz=4266667 t512=1269000 t4000=7809000 merged=0 |
| P3EF | req_hz=7500000 eff_hz=4609184 t512=1211000 t4000=7265000 merged=0 |
| P3EF | req_hz=8000000 eff_hz=4970431 t512=1098000 t4000=6712000 merged=0 |
| P3EF | req_hz=8500000 eff_hz=5181801 t512=1072000 t4000=6457000 merged=0 |
| P3EF | req_hz=9000000 eff_hz=5403563 t512=1038000 t4000=6202000 merged=0 |
| P3EF | req_hz=9500000 eff_hz=5604338 t512=1005000 t4000=5984000 merged=0 |
| P3EF | req_hz=10000000 eff_hz=6195382 t512=975000 t4000=5479000 merged=0 |
| P3EF | req_hz=10500000 eff_hz=6202267 t512=976000 t4000=5475000 merged=1 |
| P3EF | req_hz=11000000 eff_hz=6445830 t512=896000 t4000=5225000 merged=0 |
| P3EF | req_hz=11500000 eff_hz=6972514 t512=909000 t4000=4911000 merged=0 |
| P3EF | req_hz=12000000 eff_hz=7333509 t512=845000 t4000=4650000 merged=0 |
| P3WS | req_hz=2000000 eff_hz=1248334 bytes=1048576 ns=6796888000 mis=0 bad_tx=0 first_tx=-1 first=-1 shift=0 rep=0 |
| P3WS | req_hz=2000000 eff_hz=1248334 bytes=1048576 ns=6795462000 mis=0 bad_tx=0 first_tx=-1 first=-1 shift=0 rep=1 |
| P3WS | req_hz=2000000 eff_hz=1248334 bytes=1048576 ns=6797198000 mis=0 bad_tx=0 first_tx=-1 first=-1 shift=0 rep=2 |
| P3WS | req_hz=2500000 eff_hz=1555841 bytes=1048576 ns=5452798000 mis=0 bad_tx=0 first_tx=-1 first=-1 shift=0 rep=0 |
| P3WS | req_hz=2500000 eff_hz=1555841 bytes=1048576 ns=5453628000 mis=0 bad_tx=0 first_tx=-1 first=-1 shift=0 rep=1 |
| P3WS | req_hz=2500000 eff_hz=1555841 bytes=1048576 ns=5452217000 mis=0 bad_tx=0 first_tx=-1 first=-1 shift=0 rep=2 |
| P3WS | req_hz=3000000 eff_hz=1853101 bytes=1048576 ns=4579870000 mis=0 bad_tx=0 first_tx=-1 first=-1 shift=0 rep=0 |
| P3WS | req_hz=3000000 eff_hz=1853101 bytes=1048576 ns=4583630000 mis=0 bad_tx=0 first_tx=-1 first=-1 shift=0 rep=1 |
| P3WS | req_hz=3000000 eff_hz=1853101 bytes=1048576 ns=4580872000 mis=0 bad_tx=0 first_tx=-1 first=-1 shift=0 rep=2 |
| P3WS | req_hz=3500000 eff_hz=2135783 bytes=1048576 ns=3975492000 mis=0 bad_tx=0 first_tx=-1 first=-1 shift=0 rep=0 |
| P3WS | req_hz=3500000 eff_hz=2135783 bytes=1048576 ns=3974973000 mis=0 bad_tx=0 first_tx=-1 first=-1 shift=0 rep=1 |
| P3WS | req_hz=3500000 eff_hz=2135783 bytes=1048576 ns=3976423000 mis=0 bad_tx=0 first_tx=-1 first=-1 shift=0 rep=2 |
| P3WS | req_hz=4000000 eff_hz=2497002 bytes=1048576 ns=3437824000 mis=0 bad_tx=0 first_tx=-1 first=-1 shift=0 rep=0 |
| P3WS | req_hz=4000000 eff_hz=2497002 bytes=1048576 ns=3440016000 mis=0 bad_tx=0 first_tx=-1 first=-1 shift=0 rep=1 |
| P3WS | req_hz=4000000 eff_hz=2497002 bytes=1048576 ns=3440709000 mis=0 bad_tx=0 first_tx=-1 first=-1 shift=0 rep=2 |
| P3WS | req_hz=4500000 eff_hz=2767979 bytes=1048576 ns=3103089000 mis=0 bad_tx=0 first_tx=-1 first=-1 shift=0 rep=0 |
| P3WS | req_hz=4500000 eff_hz=2767979 bytes=1048576 ns=3102042000 mis=0 bad_tx=0 first_tx=-1 first=-1 shift=0 rep=1 |
| P3WS | req_hz=4500000 eff_hz=2767979 bytes=1048576 ns=3102232000 mis=0 bad_tx=0 first_tx=-1 first=-1 shift=0 rep=2 |
| P3WS | req_hz=5000000 eff_hz=3113938 bytes=1048576 ns=2765712000 mis=0 bad_tx=0 first_tx=-1 first=-1 shift=0 rep=0 |
| P3WS | req_hz=5000000 eff_hz=3113938 bytes=1048576 ns=2765612000 mis=0 bad_tx=0 first_tx=-1 first=-1 shift=0 rep=1 |
| P3WS | req_hz=5000000 eff_hz=3113938 bytes=1048576 ns=2766874000 mis=0 bad_tx=0 first_tx=-1 first=-1 shift=0 rep=2 |
| P3WS | req_hz=5500000 eff_hz=3367202 bytes=1048576 ns=2564219000 mis=0 bad_tx=0 first_tx=-1 first=-1 shift=0 rep=0 |
| P3WS | req_hz=5500000 eff_hz=3367202 bytes=1048576 ns=2563660000 mis=0 bad_tx=0 first_tx=-1 first=-1 shift=0 rep=1 |
| P3WS | req_hz=5500000 eff_hz=3367202 bytes=1048576 ns=2567789000 mis=0 bad_tx=0 first_tx=-1 first=-1 shift=0 rep=2 |
| P3WS | req_hz=6000000 eff_hz=3644723 bytes=1048576 ns=2365972000 mis=0 bad_tx=0 first_tx=-1 first=-1 shift=0 rep=0 |
| P3WS | req_hz=6000000 eff_hz=3644723 bytes=1048576 ns=2365860000 mis=0 bad_tx=0 first_tx=-1 first=-1 shift=0 rep=1 |
| P3WS | req_hz=6000000 eff_hz=3644723 bytes=1048576 ns=2373312000 mis=0 bad_tx=0 first_tx=-1 first=-1 shift=0 rep=2 |
| P3WS | req_hz=6500000 eff_hz=4017855 bytes=1048576 ns=2159754000 mis=0 bad_tx=0 first_tx=-1 first=-1 shift=0 rep=0 |
| P3WS | req_hz=6500000 eff_hz=4017855 bytes=1048576 ns=2167550000 mis=0 bad_tx=0 first_tx=-1 first=-1 shift=0 rep=1 |
| P3WS | req_hz=6500000 eff_hz=4017855 bytes=1048576 ns=2161787000 mis=0 bad_tx=0 first_tx=-1 first=-1 shift=0 rep=2 |
| P3WS | req_hz=7000000 eff_hz=4266667 bytes=1048576 ns=2026999000 mis=0 bad_tx=0 first_tx=-1 first=-1 shift=0 rep=0 |
| P3WS | req_hz=7000000 eff_hz=4266667 bytes=1048576 ns=2031797000 mis=0 bad_tx=0 first_tx=-1 first=-1 shift=0 rep=1 |
| P3WS | req_hz=7000000 eff_hz=4266667 bytes=1048576 ns=2021263000 mis=0 bad_tx=0 first_tx=-1 first=-1 shift=0 rep=2 |
| P3WS | req_hz=7500000 eff_hz=4609184 bytes=1048576 ns=1901724000 mis=0 bad_tx=0 first_tx=-1 first=-1 shift=0 rep=0 |
| P3WS | req_hz=7500000 eff_hz=4609184 bytes=1048576 ns=1897741000 mis=0 bad_tx=0 first_tx=-1 first=-1 shift=0 rep=1 |
| P3WS | req_hz=7500000 eff_hz=4609184 bytes=1048576 ns=1886221000 mis=0 bad_tx=0 first_tx=-1 first=-1 shift=0 rep=2 |
| P3WS | req_hz=8000000 eff_hz=4970431 bytes=1048576 ns=1761904000 mis=0 bad_tx=0 first_tx=-1 first=-1 shift=0 rep=0 |
| P3WS | req_hz=8000000 eff_hz=4970431 bytes=1048576 ns=1766382000 mis=0 bad_tx=0 first_tx=-1 first=-1 shift=0 rep=1 |
| P3WS | req_hz=8000000 eff_hz=4970431 bytes=1048576 ns=1754802000 mis=0 bad_tx=0 first_tx=-1 first=-1 shift=0 rep=2 |
| P3WS | req_hz=8500000 eff_hz=5181801 bytes=1048576 ns=1685167000 mis=0 bad_tx=0 first_tx=-1 first=-1 shift=0 rep=0 |
| P3WS | req_hz=8500000 eff_hz=5181801 bytes=1048576 ns=1696482000 mis=0 bad_tx=0 first_tx=-1 first=-1 shift=0 rep=1 |
| P3WS | req_hz=8500000 eff_hz=5181801 bytes=1048576 ns=1697173000 mis=0 bad_tx=0 first_tx=-1 first=-1 shift=0 rep=2 |
| P3WS | req_hz=9000000 eff_hz=5403563 bytes=1048576 ns=1622196000 mis=0 bad_tx=0 first_tx=-1 first=-1 shift=0 rep=0 |
| P3WS | req_hz=9000000 eff_hz=5403563 bytes=1048576 ns=1617392000 mis=0 bad_tx=0 first_tx=-1 first=-1 shift=0 rep=1 |
| P3WS | req_hz=9000000 eff_hz=5403563 bytes=1048576 ns=1619902000 mis=0 bad_tx=0 first_tx=-1 first=-1 shift=0 rep=2 |
| P3WS | req_hz=9500000 eff_hz=5604338 bytes=1048576 ns=1560168000 mis=0 bad_tx=0 first_tx=-1 first=-1 shift=0 rep=0 |
| P3WS | req_hz=9500000 eff_hz=5604338 bytes=1048576 ns=1565609000 mis=0 bad_tx=0 first_tx=-1 first=-1 shift=0 rep=1 |
| P3WS | req_hz=9500000 eff_hz=5604338 bytes=1048576 ns=1558954000 mis=0 bad_tx=0 first_tx=-1 first=-1 shift=0 rep=2 |
| P3WS | req_hz=10000000 eff_hz=6195382 bytes=1048576 ns=1415764000 mis=0 bad_tx=0 first_tx=-1 first=-1 shift=0 rep=0 |
| P3WS | req_hz=10000000 eff_hz=6195382 bytes=1048576 ns=1415565000 mis=0 bad_tx=0 first_tx=-1 first=-1 shift=0 rep=1 |
| P3WS | req_hz=10000000 eff_hz=6195382 bytes=1048576 ns=1415224000 mis=0 bad_tx=0 first_tx=-1 first=-1 shift=0 rep=2 |
| P3WS | req_hz=11000000 eff_hz=6445830 bytes=1048576 ns=1348139000 mis=0 bad_tx=0 first_tx=-1 first=-1 shift=0 rep=0 |
| P3WS | req_hz=11000000 eff_hz=6445830 bytes=1048576 ns=1348757000 mis=0 bad_tx=0 first_tx=-1 first=-1 shift=0 rep=1 |
| P3WS | req_hz=11000000 eff_hz=6445830 bytes=1048576 ns=1352619000 mis=0 bad_tx=0 first_tx=-1 first=-1 shift=0 rep=2 |
| P3WS | req_hz=11500000 eff_hz=6972514 bytes=1048576 ns=1289725000 mis=1043862 bad_tx=264 first_tx=0 first=2 shift=0 rep=0 |
| C3TX | req_hz=11500000 pass=0 tx=0 mis=3985 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=0 tx=1 mis=3981 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=0 tx=2 mis=3989 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=0 tx=3 mis=3982 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=0 tx=4 mis=3984 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=0 tx=5 mis=3980 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=0 tx=6 mis=3981 first=4 shift=0 |
| C3TX | req_hz=11500000 pass=0 tx=7 mis=3980 first=4 shift=0 |
| C3TX | req_hz=11500000 pass=0 tx=8 mis=3977 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=0 tx=9 mis=3984 first=4 shift=0 |
| C3TX | req_hz=11500000 pass=0 tx=10 mis=3980 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=0 tx=11 mis=3982 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=0 tx=12 mis=3980 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=0 tx=13 mis=3983 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=0 tx=14 mis=3983 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=0 tx=15 mis=3983 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=1 tx=0 mis=3979 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=1 tx=1 mis=3985 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=1 tx=2 mis=3983 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=1 tx=3 mis=3984 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=1 tx=4 mis=3973 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=1 tx=5 mis=3979 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=1 tx=6 mis=3982 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=1 tx=7 mis=3984 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=1 tx=8 mis=3983 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=1 tx=9 mis=3981 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=1 tx=10 mis=3981 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=1 tx=11 mis=3971 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=1 tx=12 mis=3982 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=1 tx=13 mis=3975 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=1 tx=14 mis=3984 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=1 tx=15 mis=3979 first=4 shift=0 |
| C3TX | req_hz=11500000 pass=2 tx=0 mis=3983 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=2 tx=1 mis=3989 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=2 tx=2 mis=3985 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=2 tx=3 mis=3984 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=2 tx=4 mis=3986 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=2 tx=5 mis=3982 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=2 tx=6 mis=3982 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=2 tx=7 mis=3974 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=2 tx=8 mis=3984 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=2 tx=9 mis=3985 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=2 tx=10 mis=3980 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=2 tx=11 mis=3987 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=2 tx=12 mis=3985 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=2 tx=13 mis=3971 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=2 tx=14 mis=3991 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=2 tx=15 mis=3986 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=3 tx=0 mis=3975 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=3 tx=1 mis=3986 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=3 tx=2 mis=3975 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=3 tx=3 mis=3976 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=3 tx=4 mis=3989 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=3 tx=5 mis=3976 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=3 tx=6 mis=3989 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=3 tx=7 mis=3971 first=4 shift=0 |
| C3TX | req_hz=11500000 pass=3 tx=8 mis=3978 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=3 tx=9 mis=3984 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=3 tx=10 mis=3984 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=3 tx=11 mis=3986 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=3 tx=12 mis=3986 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=3 tx=13 mis=3982 first=4 shift=0 |
| C3TX | req_hz=11500000 pass=3 tx=14 mis=3991 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=3 tx=15 mis=3987 first=1 shift=0 |
| P3WS | req_hz=12000000 eff_hz=7333509 bytes=1048576 ns=1224960000 mis=1044410 bad_tx=264 first_tx=0 first=0 shift=0 rep=0 |
| C3TX | req_hz=12000000 pass=0 tx=0 mis=3985 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=0 tx=1 mis=3986 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=0 tx=2 mis=3988 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=0 tx=3 mis=3986 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=0 tx=4 mis=3981 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=0 tx=5 mis=3986 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=0 tx=6 mis=3985 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=0 tx=7 mis=3984 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=0 tx=8 mis=3988 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=0 tx=9 mis=3990 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=0 tx=10 mis=3974 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=0 tx=11 mis=3986 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=0 tx=12 mis=3976 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=0 tx=13 mis=3979 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=0 tx=14 mis=3985 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=0 tx=15 mis=3986 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=1 tx=0 mis=3986 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=1 tx=1 mis=3982 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=1 tx=2 mis=3985 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=1 tx=3 mis=3984 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=1 tx=4 mis=3982 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=1 tx=5 mis=3986 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=1 tx=6 mis=3981 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=1 tx=7 mis=3991 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=1 tx=8 mis=3981 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=1 tx=9 mis=3987 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=1 tx=10 mis=3984 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=1 tx=11 mis=3982 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=1 tx=12 mis=3981 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=1 tx=13 mis=3985 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=1 tx=14 mis=3989 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=1 tx=15 mis=3984 first=1 shift=0 |
| C3TX | req_hz=12000000 pass=2 tx=0 mis=3980 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=2 tx=1 mis=3980 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=2 tx=2 mis=3984 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=2 tx=3 mis=3977 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=2 tx=4 mis=3990 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=2 tx=5 mis=3981 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=2 tx=6 mis=3982 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=2 tx=7 mis=3989 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=2 tx=8 mis=3983 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=2 tx=9 mis=3985 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=2 tx=10 mis=3986 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=2 tx=11 mis=3984 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=2 tx=12 mis=3987 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=2 tx=13 mis=3991 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=2 tx=14 mis=3990 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=2 tx=15 mis=3979 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=3 tx=0 mis=3977 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=3 tx=1 mis=3982 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=3 tx=2 mis=3987 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=3 tx=3 mis=3992 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=3 tx=4 mis=3986 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=3 tx=5 mis=3982 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=3 tx=6 mis=3985 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=3 tx=7 mis=3988 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=3 tx=8 mis=3987 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=3 tx=9 mis=3985 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=3 tx=10 mis=3986 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=3 tx=11 mis=3985 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=3 tx=12 mis=3986 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=3 tx=13 mis=3988 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=3 tx=14 mis=3980 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=3 tx=15 mis=3991 first=0 shift=0 |
| P3WB | req_hz=2000000 eff_hz=1248334 passes=128 badpasses=0 first_pass=-1 |
| P3WB | req_hz=2500000 eff_hz=1555841 passes=128 badpasses=0 first_pass=-1 |
| P3WB | req_hz=3000000 eff_hz=1853101 passes=128 badpasses=0 first_pass=-1 |
| P3WB | req_hz=3500000 eff_hz=2135783 passes=128 badpasses=0 first_pass=-1 |
| P3WB | req_hz=4000000 eff_hz=2497002 passes=128 badpasses=0 first_pass=-1 |
| P3WB | req_hz=4500000 eff_hz=2767979 passes=128 badpasses=0 first_pass=-1 |
| P3WB | req_hz=5000000 eff_hz=3113938 passes=128 badpasses=0 first_pass=-1 |
| P3WB | req_hz=5500000 eff_hz=3367202 passes=128 badpasses=0 first_pass=-1 |
| P3WB | req_hz=6000000 eff_hz=3644723 passes=128 badpasses=0 first_pass=-1 |
| P3WB | req_hz=6500000 eff_hz=4017855 passes=128 badpasses=0 first_pass=-1 |
| P3WB | req_hz=7000000 eff_hz=4266667 passes=128 badpasses=0 first_pass=-1 |
| P3WB | req_hz=7500000 eff_hz=4609184 passes=128 badpasses=0 first_pass=-1 |
| P3WB | req_hz=8000000 eff_hz=4970431 passes=128 badpasses=0 first_pass=-1 |
| P3WB | req_hz=8500000 eff_hz=5181801 passes=128 badpasses=0 first_pass=-1 |
| P3WB | req_hz=9000000 eff_hz=5403563 passes=128 badpasses=0 first_pass=-1 |
| P3WB | req_hz=9500000 eff_hz=5604338 passes=128 badpasses=0 first_pass=-1 |
| P3WB | req_hz=10000000 eff_hz=6195382 passes=128 badpasses=0 first_pass=-1 |
| P3WB | req_hz=11000000 eff_hz=6445830 passes=128 badpasses=0 first_pass=-1 |
| P3WB | req_hz=11500000 eff_hz=6972514 passes=128 badpasses=128 first_pass=0 |
| C3TX | req_hz=11500000 pass=0 tx=0 mis=3986 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=0 tx=1 mis=3983 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=0 tx=2 mis=191 first=0 shift=0 |
| C3BP | req_hz=11500000 pass=0 seed=808454835 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10190000 mis=8160 bad_tx=3 first_tx=0 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=1 tx=0 mis=3988 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=1 tx=1 mis=3984 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=1 tx=2 mis=189 first=3 shift=0 |
| C3BP | req_hz=11500000 pass=1 seed=808454836 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10915000 mis=8161 bad_tx=3 first_tx=0 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=2 tx=0 mis=3985 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=2 tx=1 mis=3988 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=2 tx=2 mis=188 first=3 shift=0 |
| C3BP | req_hz=11500000 pass=2 seed=808454837 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10121000 mis=8161 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=3 tx=0 mis=3983 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=3 tx=1 mis=3984 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=3 tx=2 mis=191 first=1 shift=0 |
| C3BP | req_hz=11500000 pass=3 seed=808454838 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10186000 mis=8158 bad_tx=3 first_tx=0 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=4 tx=0 mis=3982 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=4 tx=1 mis=3983 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=4 tx=2 mis=190 first=1 shift=0 |
| C3BP | req_hz=11500000 pass=4 seed=808454839 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10147000 mis=8155 bad_tx=3 first_tx=0 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=5 tx=0 mis=3982 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=5 tx=1 mis=3986 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=5 tx=2 mis=191 first=0 shift=0 |
| C3BP | req_hz=11500000 pass=5 seed=808454840 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10131000 mis=8159 bad_tx=3 first_tx=0 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=6 tx=0 mis=3988 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=6 tx=1 mis=3983 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=6 tx=2 mis=188 first=3 shift=0 |
| C3BP | req_hz=11500000 pass=6 seed=808454841 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10145000 mis=8159 bad_tx=3 first_tx=0 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=7 tx=0 mis=3982 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=7 tx=1 mis=3983 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=7 tx=2 mis=189 first=2 shift=0 |
| C3BP | req_hz=11500000 pass=7 seed=808454842 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10158000 mis=8154 bad_tx=3 first_tx=0 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=8 tx=0 mis=3981 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=8 tx=1 mis=3971 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=8 tx=2 mis=192 first=0 shift=0 |
| C3BP | req_hz=11500000 pass=8 seed=808454843 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10638000 mis=8144 bad_tx=3 first_tx=0 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=9 tx=0 mis=3983 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=9 tx=1 mis=3984 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=9 tx=2 mis=188 first=3 shift=0 |
| C3BP | req_hz=11500000 pass=9 seed=808454844 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10183000 mis=8155 bad_tx=3 first_tx=0 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=10 tx=0 mis=3976 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=10 tx=1 mis=3985 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=10 tx=2 mis=191 first=1 shift=0 |
| C3BP | req_hz=11500000 pass=10 seed=808454845 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10119000 mis=8152 bad_tx=3 first_tx=0 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=11 tx=0 mis=3987 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=11 tx=1 mis=3979 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=11 tx=2 mis=188 first=3 shift=0 |
| C3BP | req_hz=11500000 pass=11 seed=808454846 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10210000 mis=8154 bad_tx=3 first_tx=0 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=12 tx=0 mis=3979 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=12 tx=1 mis=3987 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=12 tx=2 mis=190 first=1 shift=0 |
| C3BP | req_hz=11500000 pass=12 seed=808454847 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10139000 mis=8156 bad_tx=3 first_tx=0 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=13 tx=0 mis=3984 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=13 tx=1 mis=3979 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=13 tx=2 mis=189 first=2 shift=0 |
| C3BP | req_hz=11500000 pass=13 seed=808454848 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10676000 mis=8152 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=14 tx=0 mis=3989 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=14 tx=1 mis=3981 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=14 tx=2 mis=190 first=1 shift=0 |
| C3BP | req_hz=11500000 pass=14 seed=808454849 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10069000 mis=8160 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=15 tx=0 mis=3984 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=15 tx=1 mis=3985 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=15 tx=2 mis=189 first=3 shift=0 |
| C3BP | req_hz=11500000 pass=15 seed=808454850 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10084000 mis=8158 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=16 tx=0 mis=3988 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=16 tx=1 mis=3981 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=16 tx=2 mis=188 first=3 shift=0 |
| C3BP | req_hz=11500000 pass=16 seed=808454851 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10062000 mis=8157 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=17 tx=0 mis=3987 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=17 tx=1 mis=3983 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=17 tx=2 mis=190 first=0 shift=0 |
| C3BP | req_hz=11500000 pass=17 seed=808454852 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10083000 mis=8160 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=18 tx=0 mis=3989 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=18 tx=1 mis=3985 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=18 tx=2 mis=191 first=1 shift=0 |
| C3BP | req_hz=11500000 pass=18 seed=808454853 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10091000 mis=8165 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=19 tx=0 mis=3988 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=19 tx=1 mis=3989 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=19 tx=2 mis=189 first=3 shift=0 |
| C3BP | req_hz=11500000 pass=19 seed=808454854 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10058000 mis=8166 bad_tx=3 first_tx=0 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=20 tx=0 mis=3988 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=20 tx=1 mis=3987 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=20 tx=2 mis=187 first=3 shift=0 |
| C3BP | req_hz=11500000 pass=20 seed=808454855 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10051000 mis=8162 bad_tx=3 first_tx=0 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=21 tx=0 mis=3981 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=21 tx=1 mis=3979 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=21 tx=2 mis=192 first=0 shift=0 |
| C3BP | req_hz=11500000 pass=21 seed=808454856 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10062000 mis=8152 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=22 tx=0 mis=3987 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=22 tx=1 mis=3986 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=22 tx=2 mis=190 first=2 shift=0 |
| C3BP | req_hz=11500000 pass=22 seed=808454857 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10061000 mis=8163 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=23 tx=0 mis=3983 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=23 tx=1 mis=3977 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=23 tx=2 mis=189 first=1 shift=0 |
| C3BP | req_hz=11500000 pass=23 seed=808454858 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10115000 mis=8149 bad_tx=3 first_tx=0 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=24 tx=0 mis=3972 first=4 shift=0 |
| C3TX | req_hz=11500000 pass=24 tx=1 mis=3986 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=24 tx=2 mis=189 first=3 shift=0 |
| C3BP | req_hz=11500000 pass=24 seed=808454859 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10495000 mis=8147 bad_tx=3 first_tx=0 first=4 shift=0 |
| C3TX | req_hz=11500000 pass=25 tx=0 mis=3978 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=25 tx=1 mis=3981 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=25 tx=2 mis=189 first=3 shift=0 |
| C3BP | req_hz=11500000 pass=25 seed=808454860 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10068000 mis=8148 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=26 tx=0 mis=3983 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=26 tx=1 mis=3981 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=26 tx=2 mis=192 first=0 shift=0 |
| C3BP | req_hz=11500000 pass=26 seed=808454861 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10119000 mis=8156 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=27 tx=0 mis=3986 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=27 tx=1 mis=3982 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=27 tx=2 mis=189 first=2 shift=0 |
| C3BP | req_hz=11500000 pass=27 seed=808454862 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10071000 mis=8157 bad_tx=3 first_tx=0 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=28 tx=0 mis=3977 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=28 tx=1 mis=3981 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=28 tx=2 mis=191 first=0 shift=0 |
| C3BP | req_hz=11500000 pass=28 seed=808454863 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10205000 mis=8149 bad_tx=3 first_tx=0 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=29 tx=0 mis=3980 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=29 tx=1 mis=3990 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=29 tx=2 mis=190 first=2 shift=0 |
| C3BP | req_hz=11500000 pass=29 seed=808454864 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10211000 mis=8160 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=30 tx=0 mis=3980 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=30 tx=1 mis=3983 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=30 tx=2 mis=191 first=1 shift=0 |
| C3BP | req_hz=11500000 pass=30 seed=808454865 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10115000 mis=8154 bad_tx=3 first_tx=0 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=31 tx=0 mis=3986 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=31 tx=1 mis=3975 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=31 tx=2 mis=192 first=0 shift=0 |
| C3BP | req_hz=11500000 pass=31 seed=808454866 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10183000 mis=8153 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=32 tx=0 mis=3985 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=32 tx=1 mis=3981 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=32 tx=2 mis=191 first=0 shift=0 |
| C3BP | req_hz=11500000 pass=32 seed=808454867 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10315000 mis=8157 bad_tx=3 first_tx=0 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=33 tx=0 mis=3984 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=33 tx=1 mis=3976 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=33 tx=2 mis=189 first=2 shift=0 |
| C3BP | req_hz=11500000 pass=33 seed=808454868 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10685000 mis=8149 bad_tx=3 first_tx=0 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=34 tx=0 mis=3991 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=34 tx=1 mis=3986 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=34 tx=2 mis=190 first=1 shift=0 |
| C3BP | req_hz=11500000 pass=34 seed=808454869 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10157000 mis=8167 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=35 tx=0 mis=3982 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=35 tx=1 mis=3980 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=35 tx=2 mis=191 first=0 shift=0 |
| C3BP | req_hz=11500000 pass=35 seed=808454870 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10202000 mis=8153 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=36 tx=0 mis=3983 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=36 tx=1 mis=3984 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=36 tx=2 mis=191 first=1 shift=0 |
| C3BP | req_hz=11500000 pass=36 seed=808454871 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10234000 mis=8158 bad_tx=3 first_tx=0 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=37 tx=0 mis=3981 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=37 tx=1 mis=3984 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=37 tx=2 mis=189 first=3 shift=0 |
| C3BP | req_hz=11500000 pass=37 seed=808454872 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10193000 mis=8154 bad_tx=3 first_tx=0 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=38 tx=0 mis=3985 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=38 tx=1 mis=3979 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=38 tx=2 mis=186 first=3 shift=0 |
| C3BP | req_hz=11500000 pass=38 seed=808454873 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10156000 mis=8150 bad_tx=3 first_tx=0 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=39 tx=0 mis=3990 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=39 tx=1 mis=3988 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=39 tx=2 mis=190 first=2 shift=0 |
| C3BP | req_hz=11500000 pass=39 seed=808454874 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10650000 mis=8168 bad_tx=3 first_tx=0 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=40 tx=0 mis=3985 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=40 tx=1 mis=3984 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=40 tx=2 mis=189 first=3 shift=0 |
| C3BP | req_hz=11500000 pass=40 seed=808454875 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10134000 mis=8158 bad_tx=3 first_tx=0 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=41 tx=0 mis=3977 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=41 tx=1 mis=3986 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=41 tx=2 mis=191 first=0 shift=0 |
| C3BP | req_hz=11500000 pass=41 seed=808454876 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10265000 mis=8154 bad_tx=3 first_tx=0 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=42 tx=0 mis=3981 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=42 tx=1 mis=3984 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=42 tx=2 mis=188 first=3 shift=0 |
| C3BP | req_hz=11500000 pass=42 seed=808454877 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10209000 mis=8153 bad_tx=3 first_tx=0 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=43 tx=0 mis=3981 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=43 tx=1 mis=3980 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=43 tx=2 mis=189 first=3 shift=0 |
| C3BP | req_hz=11500000 pass=43 seed=808454878 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10155000 mis=8150 bad_tx=3 first_tx=0 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=44 tx=0 mis=3976 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=44 tx=1 mis=3984 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=44 tx=2 mis=190 first=1 shift=0 |
| C3BP | req_hz=11500000 pass=44 seed=808454879 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10074000 mis=8150 bad_tx=3 first_tx=0 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=45 tx=0 mis=3986 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=45 tx=1 mis=3985 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=45 tx=2 mis=191 first=1 shift=0 |
| C3BP | req_hz=11500000 pass=45 seed=808454880 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10067000 mis=8162 bad_tx=3 first_tx=0 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=46 tx=0 mis=3979 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=46 tx=1 mis=3988 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=46 tx=2 mis=189 first=2 shift=0 |
| C3BP | req_hz=11500000 pass=46 seed=808454881 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10034000 mis=8156 bad_tx=3 first_tx=0 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=47 tx=0 mis=3985 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=47 tx=1 mis=3979 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=47 tx=2 mis=191 first=1 shift=0 |
| C3BP | req_hz=11500000 pass=47 seed=808454882 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10135000 mis=8155 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=48 tx=0 mis=3984 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=48 tx=1 mis=3983 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=48 tx=2 mis=189 first=3 shift=0 |
| C3BP | req_hz=11500000 pass=48 seed=808454883 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10066000 mis=8156 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=49 tx=0 mis=3969 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=49 tx=1 mis=3982 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=49 tx=2 mis=191 first=0 shift=0 |
| C3BP | req_hz=11500000 pass=49 seed=808454884 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10077000 mis=8142 bad_tx=3 first_tx=0 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=50 tx=0 mis=3977 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=50 tx=1 mis=3993 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=50 tx=2 mis=189 first=2 shift=0 |
| C3BP | req_hz=11500000 pass=50 seed=808454885 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10100000 mis=8159 bad_tx=3 first_tx=0 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=51 tx=0 mis=3980 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=51 tx=1 mis=3982 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=51 tx=2 mis=192 first=0 shift=0 |
| C3BP | req_hz=11500000 pass=51 seed=808454886 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10074000 mis=8154 bad_tx=3 first_tx=0 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=52 tx=0 mis=3989 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=52 tx=1 mis=3980 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=52 tx=2 mis=190 first=0 shift=0 |
| C3BP | req_hz=11500000 pass=52 seed=808454887 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10069000 mis=8159 bad_tx=3 first_tx=0 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=53 tx=0 mis=3985 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=53 tx=1 mis=3975 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=53 tx=2 mis=189 first=3 shift=0 |
| C3BP | req_hz=11500000 pass=53 seed=808454888 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10071000 mis=8149 bad_tx=3 first_tx=0 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=54 tx=0 mis=3978 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=54 tx=1 mis=3985 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=54 tx=2 mis=191 first=1 shift=0 |
| C3BP | req_hz=11500000 pass=54 seed=808454889 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10045000 mis=8154 bad_tx=3 first_tx=0 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=55 tx=0 mis=3984 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=55 tx=1 mis=3979 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=55 tx=2 mis=192 first=0 shift=0 |
| C3BP | req_hz=11500000 pass=55 seed=808454890 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10097000 mis=8155 bad_tx=3 first_tx=0 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=56 tx=0 mis=3984 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=56 tx=1 mis=3982 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=56 tx=2 mis=190 first=2 shift=0 |
| C3BP | req_hz=11500000 pass=56 seed=808454891 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10058000 mis=8156 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=57 tx=0 mis=3984 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=57 tx=1 mis=3987 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=57 tx=2 mis=190 first=2 shift=0 |
| C3BP | req_hz=11500000 pass=57 seed=808454892 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10070000 mis=8161 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=58 tx=0 mis=3978 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=58 tx=1 mis=3989 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=58 tx=2 mis=190 first=2 shift=0 |
| C3BP | req_hz=11500000 pass=58 seed=808454893 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10059000 mis=8157 bad_tx=3 first_tx=0 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=59 tx=0 mis=3980 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=59 tx=1 mis=3990 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=59 tx=2 mis=189 first=3 shift=0 |
| C3BP | req_hz=11500000 pass=59 seed=808454894 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10183000 mis=8159 bad_tx=3 first_tx=0 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=60 tx=0 mis=3990 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=60 tx=1 mis=3990 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=60 tx=2 mis=190 first=2 shift=0 |
| C3BP | req_hz=11500000 pass=60 seed=808454895 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10638000 mis=8170 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=61 tx=0 mis=3980 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=61 tx=1 mis=3983 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=61 tx=2 mis=188 first=3 shift=0 |
| C3BP | req_hz=11500000 pass=61 seed=808454896 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10153000 mis=8151 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=62 tx=0 mis=3979 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=62 tx=1 mis=3984 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=62 tx=2 mis=190 first=1 shift=0 |
| C3BP | req_hz=11500000 pass=62 seed=808454897 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10198000 mis=8153 bad_tx=3 first_tx=0 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=63 tx=0 mis=3980 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=63 tx=1 mis=3981 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=63 tx=2 mis=189 first=3 shift=0 |
| C3BP | req_hz=11500000 pass=63 seed=808454898 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10181000 mis=8150 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=64 tx=0 mis=3984 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=64 tx=1 mis=3987 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=64 tx=2 mis=188 first=2 shift=0 |
| C3BP | req_hz=11500000 pass=64 seed=808454899 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10161000 mis=8159 bad_tx=3 first_tx=0 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=65 tx=0 mis=3986 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=65 tx=1 mis=3984 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=65 tx=2 mis=190 first=1 shift=0 |
| C3BP | req_hz=11500000 pass=65 seed=808454900 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10188000 mis=8160 bad_tx=3 first_tx=0 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=66 tx=0 mis=3979 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=66 tx=1 mis=3981 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=66 tx=2 mis=189 first=3 shift=0 |
| C3BP | req_hz=11500000 pass=66 seed=808454901 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10149000 mis=8149 bad_tx=3 first_tx=0 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=67 tx=0 mis=3983 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=67 tx=1 mis=3986 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=67 tx=2 mis=189 first=1 shift=0 |
| C3BP | req_hz=11500000 pass=67 seed=808454902 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10174000 mis=8158 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=68 tx=0 mis=3987 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=68 tx=1 mis=3982 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=68 tx=2 mis=191 first=0 shift=0 |
| C3BP | req_hz=11500000 pass=68 seed=808454903 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10126000 mis=8160 bad_tx=3 first_tx=0 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=69 tx=0 mis=3987 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=69 tx=1 mis=3981 first=4 shift=0 |
| C3TX | req_hz=11500000 pass=69 tx=2 mis=191 first=0 shift=0 |
| C3BP | req_hz=11500000 pass=69 seed=808454904 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10158000 mis=8159 bad_tx=3 first_tx=0 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=70 tx=0 mis=3978 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=70 tx=1 mis=3979 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=70 tx=2 mis=190 first=2 shift=0 |
| C3BP | req_hz=11500000 pass=70 seed=808454905 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10190000 mis=8147 bad_tx=3 first_tx=0 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=71 tx=0 mis=3981 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=71 tx=1 mis=3978 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=71 tx=2 mis=189 first=2 shift=0 |
| C3BP | req_hz=11500000 pass=71 seed=808454906 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10157000 mis=8148 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=72 tx=0 mis=3984 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=72 tx=1 mis=3981 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=72 tx=2 mis=189 first=2 shift=0 |
| C3BP | req_hz=11500000 pass=72 seed=808454907 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10158000 mis=8154 bad_tx=3 first_tx=0 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=73 tx=0 mis=3982 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=73 tx=1 mis=3986 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=73 tx=2 mis=191 first=1 shift=0 |
| C3BP | req_hz=11500000 pass=73 seed=808454908 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10142000 mis=8159 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=74 tx=0 mis=3986 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=74 tx=1 mis=3982 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=74 tx=2 mis=191 first=1 shift=0 |
| C3BP | req_hz=11500000 pass=74 seed=808454909 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10672000 mis=8159 bad_tx=3 first_tx=0 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=75 tx=0 mis=3984 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=75 tx=1 mis=3984 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=75 tx=2 mis=190 first=1 shift=0 |
| C3BP | req_hz=11500000 pass=75 seed=808454910 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10064000 mis=8158 bad_tx=3 first_tx=0 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=76 tx=0 mis=3984 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=76 tx=1 mis=3980 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=76 tx=2 mis=189 first=2 shift=0 |
| C3BP | req_hz=11500000 pass=76 seed=808454911 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10046000 mis=8153 bad_tx=3 first_tx=0 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=77 tx=0 mis=3984 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=77 tx=1 mis=3978 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=77 tx=2 mis=189 first=1 shift=0 |
| C3BP | req_hz=11500000 pass=77 seed=808454912 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10068000 mis=8151 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=78 tx=0 mis=3979 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=78 tx=1 mis=3976 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=78 tx=2 mis=191 first=0 shift=0 |
| C3BP | req_hz=11500000 pass=78 seed=808454913 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10295000 mis=8146 bad_tx=3 first_tx=0 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=79 tx=0 mis=3983 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=79 tx=1 mis=3984 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=79 tx=2 mis=190 first=1 shift=0 |
| C3BP | req_hz=11500000 pass=79 seed=808454914 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10061000 mis=8157 bad_tx=3 first_tx=0 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=80 tx=0 mis=3975 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=80 tx=1 mis=3978 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=80 tx=2 mis=189 first=3 shift=0 |
| C3BP | req_hz=11500000 pass=80 seed=808454915 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10065000 mis=8142 bad_tx=3 first_tx=0 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=81 tx=0 mis=3982 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=81 tx=1 mis=3987 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=81 tx=2 mis=190 first=2 shift=0 |
| C3BP | req_hz=11500000 pass=81 seed=808454916 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10064000 mis=8159 bad_tx=3 first_tx=0 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=82 tx=0 mis=3987 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=82 tx=1 mis=3982 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=82 tx=2 mis=187 first=4 shift=0 |
| C3BP | req_hz=11500000 pass=82 seed=808454917 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10103000 mis=8156 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=83 tx=0 mis=3985 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=83 tx=1 mis=3977 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=83 tx=2 mis=192 first=0 shift=0 |
| C3BP | req_hz=11500000 pass=83 seed=808454918 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10067000 mis=8154 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=84 tx=0 mis=3977 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=84 tx=1 mis=3983 first=4 shift=0 |
| C3TX | req_hz=11500000 pass=84 tx=2 mis=188 first=2 shift=0 |
| C3BP | req_hz=11500000 pass=84 seed=808454919 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10093000 mis=8148 bad_tx=3 first_tx=0 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=85 tx=0 mis=3988 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=85 tx=1 mis=3980 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=85 tx=2 mis=189 first=2 shift=0 |
| C3BP | req_hz=11500000 pass=85 seed=808454920 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10077000 mis=8157 bad_tx=3 first_tx=0 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=86 tx=0 mis=3988 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=86 tx=1 mis=3987 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=86 tx=2 mis=188 first=2 shift=0 |
| C3BP | req_hz=11500000 pass=86 seed=808454921 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10064000 mis=8163 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=87 tx=0 mis=3984 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=87 tx=1 mis=3985 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=87 tx=2 mis=191 first=1 shift=0 |
| C3BP | req_hz=11500000 pass=87 seed=808454922 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10177000 mis=8160 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=88 tx=0 mis=3977 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=88 tx=1 mis=3974 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=88 tx=2 mis=191 first=1 shift=0 |
| C3BP | req_hz=11500000 pass=88 seed=808454923 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10069000 mis=8142 bad_tx=3 first_tx=0 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=89 tx=0 mis=3980 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=89 tx=1 mis=3978 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=89 tx=2 mis=190 first=0 shift=0 |
| C3BP | req_hz=11500000 pass=89 seed=808454924 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10203000 mis=8148 bad_tx=3 first_tx=0 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=90 tx=0 mis=3977 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=90 tx=1 mis=3987 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=90 tx=2 mis=190 first=2 shift=0 |
| C3BP | req_hz=11500000 pass=90 seed=808454925 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10148000 mis=8154 bad_tx=3 first_tx=0 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=91 tx=0 mis=3983 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=91 tx=1 mis=3976 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=91 tx=2 mis=191 first=0 shift=0 |
| C3BP | req_hz=11500000 pass=91 seed=808454926 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10160000 mis=8150 bad_tx=3 first_tx=0 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=92 tx=0 mis=3983 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=92 tx=1 mis=3978 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=92 tx=2 mis=192 first=0 shift=0 |
| C3BP | req_hz=11500000 pass=92 seed=808454927 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10171000 mis=8153 bad_tx=3 first_tx=0 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=93 tx=0 mis=3976 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=93 tx=1 mis=3983 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=93 tx=2 mis=191 first=0 shift=0 |
| C3BP | req_hz=11500000 pass=93 seed=808454928 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10204000 mis=8150 bad_tx=3 first_tx=0 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=94 tx=0 mis=3983 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=94 tx=1 mis=3982 first=4 shift=0 |
| C3TX | req_hz=11500000 pass=94 tx=2 mis=189 first=1 shift=0 |
| C3BP | req_hz=11500000 pass=94 seed=808454929 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10638000 mis=8154 bad_tx=3 first_tx=0 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=95 tx=0 mis=3984 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=95 tx=1 mis=3986 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=95 tx=2 mis=188 first=3 shift=0 |
| C3BP | req_hz=11500000 pass=95 seed=808454930 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10159000 mis=8158 bad_tx=3 first_tx=0 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=96 tx=0 mis=3981 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=96 tx=1 mis=3987 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=96 tx=2 mis=188 first=3 shift=0 |
| C3BP | req_hz=11500000 pass=96 seed=808454931 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10181000 mis=8156 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=97 tx=0 mis=3974 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=97 tx=1 mis=3985 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=97 tx=2 mis=188 first=4 shift=0 |
| C3BP | req_hz=11500000 pass=97 seed=808454932 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10689000 mis=8147 bad_tx=3 first_tx=0 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=98 tx=0 mis=3980 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=98 tx=1 mis=3986 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=98 tx=2 mis=190 first=2 shift=0 |
| C3BP | req_hz=11500000 pass=98 seed=808454933 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10110000 mis=8156 bad_tx=3 first_tx=0 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=99 tx=0 mis=3987 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=99 tx=1 mis=3977 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=99 tx=2 mis=188 first=3 shift=0 |
| C3BP | req_hz=11500000 pass=99 seed=808454934 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10153000 mis=8152 bad_tx=3 first_tx=0 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=100 tx=0 mis=3988 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=100 tx=1 mis=3985 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=100 tx=2 mis=191 first=1 shift=0 |
| C3BP | req_hz=11500000 pass=100 seed=808454935 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10137000 mis=8164 bad_tx=3 first_tx=0 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=101 tx=0 mis=3986 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=101 tx=1 mis=3977 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=101 tx=2 mis=189 first=3 shift=0 |
| C3BP | req_hz=11500000 pass=101 seed=808454936 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10173000 mis=8152 bad_tx=3 first_tx=0 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=102 tx=0 mis=3979 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=102 tx=1 mis=3991 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=102 tx=2 mis=188 first=3 shift=0 |
| C3BP | req_hz=11500000 pass=102 seed=808454937 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10162000 mis=8158 bad_tx=3 first_tx=0 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=103 tx=0 mis=3987 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=103 tx=1 mis=3984 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=103 tx=2 mis=185 first=3 shift=0 |
| C3BP | req_hz=11500000 pass=103 seed=808454938 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10182000 mis=8156 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=104 tx=0 mis=3981 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=104 tx=1 mis=3984 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=104 tx=2 mis=189 first=2 shift=0 |
| C3BP | req_hz=11500000 pass=104 seed=808454939 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10475000 mis=8154 bad_tx=3 first_tx=0 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=105 tx=0 mis=3980 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=105 tx=1 mis=3983 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=105 tx=2 mis=191 first=1 shift=0 |
| C3BP | req_hz=11500000 pass=105 seed=808454940 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10068000 mis=8154 bad_tx=3 first_tx=0 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=106 tx=0 mis=3978 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=106 tx=1 mis=3986 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=106 tx=2 mis=191 first=1 shift=0 |
| C3BP | req_hz=11500000 pass=106 seed=808454941 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10126000 mis=8155 bad_tx=3 first_tx=0 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=107 tx=0 mis=3984 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=107 tx=1 mis=3986 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=107 tx=2 mis=187 first=3 shift=0 |
| C3BP | req_hz=11500000 pass=107 seed=808454942 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10065000 mis=8157 bad_tx=3 first_tx=0 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=108 tx=0 mis=3984 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=108 tx=1 mis=3978 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=108 tx=2 mis=189 first=1 shift=0 |
| C3BP | req_hz=11500000 pass=108 seed=808454943 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10141000 mis=8151 bad_tx=3 first_tx=0 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=109 tx=0 mis=3985 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=109 tx=1 mis=3975 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=109 tx=2 mis=189 first=3 shift=0 |
| C3BP | req_hz=11500000 pass=109 seed=808454944 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10100000 mis=8149 bad_tx=3 first_tx=0 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=110 tx=0 mis=3982 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=110 tx=1 mis=3981 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=110 tx=2 mis=192 first=0 shift=0 |
| C3BP | req_hz=11500000 pass=110 seed=808454945 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10069000 mis=8155 bad_tx=3 first_tx=0 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=111 tx=0 mis=3977 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=111 tx=1 mis=3984 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=111 tx=2 mis=188 first=3 shift=0 |
| C3BP | req_hz=11500000 pass=111 seed=808454946 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10110000 mis=8149 bad_tx=3 first_tx=0 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=112 tx=0 mis=3984 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=112 tx=1 mis=3983 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=112 tx=2 mis=190 first=2 shift=0 |
| C3BP | req_hz=11500000 pass=112 seed=808454947 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10097000 mis=8157 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=113 tx=0 mis=3983 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=113 tx=1 mis=3984 first=4 shift=0 |
| C3TX | req_hz=11500000 pass=113 tx=2 mis=189 first=3 shift=0 |
| C3BP | req_hz=11500000 pass=113 seed=808454948 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10055000 mis=8156 bad_tx=3 first_tx=0 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=114 tx=0 mis=3983 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=114 tx=1 mis=3984 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=114 tx=2 mis=190 first=1 shift=0 |
| C3BP | req_hz=11500000 pass=114 seed=808454949 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10103000 mis=8157 bad_tx=3 first_tx=0 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=115 tx=0 mis=3978 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=115 tx=1 mis=3978 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=115 tx=2 mis=190 first=2 shift=0 |
| C3BP | req_hz=11500000 pass=115 seed=808454950 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10070000 mis=8146 bad_tx=3 first_tx=0 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=116 tx=0 mis=3989 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=116 tx=1 mis=3986 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=116 tx=2 mis=190 first=2 shift=0 |
| C3BP | req_hz=11500000 pass=116 seed=808454951 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10059000 mis=8165 bad_tx=3 first_tx=0 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=117 tx=0 mis=3975 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=117 tx=1 mis=3984 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=117 tx=2 mis=190 first=2 shift=0 |
| C3BP | req_hz=11500000 pass=117 seed=808454952 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10071000 mis=8149 bad_tx=3 first_tx=0 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=118 tx=0 mis=3976 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=118 tx=1 mis=3984 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=118 tx=2 mis=187 first=3 shift=0 |
| C3BP | req_hz=11500000 pass=118 seed=808454953 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10064000 mis=8147 bad_tx=3 first_tx=0 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=119 tx=0 mis=3982 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=119 tx=1 mis=3987 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=119 tx=2 mis=190 first=2 shift=0 |
| C3BP | req_hz=11500000 pass=119 seed=808454954 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10231000 mis=8159 bad_tx=3 first_tx=0 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=120 tx=0 mis=3991 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=120 tx=1 mis=3984 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=120 tx=2 mis=191 first=1 shift=0 |
| C3BP | req_hz=11500000 pass=120 seed=808454955 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10337000 mis=8166 bad_tx=3 first_tx=0 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=121 tx=0 mis=3991 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=121 tx=1 mis=3986 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=121 tx=2 mis=187 first=3 shift=0 |
| C3BP | req_hz=11500000 pass=121 seed=808454956 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10163000 mis=8164 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=122 tx=0 mis=3986 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=122 tx=1 mis=3985 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=122 tx=2 mis=189 first=1 shift=0 |
| C3BP | req_hz=11500000 pass=122 seed=808454957 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10653000 mis=8160 bad_tx=3 first_tx=0 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=123 tx=0 mis=3984 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=123 tx=1 mis=3982 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=123 tx=2 mis=187 first=3 shift=0 |
| C3BP | req_hz=11500000 pass=123 seed=808454958 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10158000 mis=8153 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=124 tx=0 mis=3983 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=124 tx=1 mis=3983 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=124 tx=2 mis=192 first=0 shift=0 |
| C3BP | req_hz=11500000 pass=124 seed=808454959 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10204000 mis=8158 bad_tx=3 first_tx=0 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=125 tx=0 mis=3985 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=125 tx=1 mis=3986 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=125 tx=2 mis=191 first=1 shift=0 |
| C3BP | req_hz=11500000 pass=125 seed=808454960 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10736000 mis=8162 bad_tx=3 first_tx=0 first=3 shift=0 |
| C3TX | req_hz=11500000 pass=126 tx=0 mis=3985 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=126 tx=1 mis=3990 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=126 tx=2 mis=187 first=3 shift=0 |
| C3BP | req_hz=11500000 pass=126 seed=808454961 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10152000 mis=8162 bad_tx=3 first_tx=0 first=2 shift=0 |
| C3TX | req_hz=11500000 pass=127 tx=0 mis=3981 first=0 shift=0 |
| C3TX | req_hz=11500000 pass=127 tx=1 mis=3986 first=1 shift=0 |
| C3TX | req_hz=11500000 pass=127 tx=2 mis=189 first=1 shift=0 |
| C3BP | req_hz=11500000 pass=127 seed=808454962 hz=11500000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10163000 mis=8156 bad_tx=3 first_tx=0 first=0 shift=0 |
| P3WB | req_hz=12000000 eff_hz=7333509 passes=128 badpasses=128 first_pass=0 |
| C3TX | req_hz=12000000 pass=0 tx=0 mis=3991 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=0 tx=1 mis=3980 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=0 tx=2 mis=191 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=0 seed=808454963 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9520000 mis=8162 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=1 tx=0 mis=3979 first=1 shift=0 |
| C3TX | req_hz=12000000 pass=1 tx=1 mis=3980 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=1 tx=2 mis=192 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=1 seed=808454964 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9650000 mis=8151 bad_tx=3 first_tx=0 first=1 shift=0 |
| C3TX | req_hz=12000000 pass=2 tx=0 mis=3982 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=2 tx=1 mis=3987 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=2 tx=2 mis=191 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=2 seed=808454965 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9635000 mis=8160 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=3 tx=0 mis=3986 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=3 tx=1 mis=3984 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=3 tx=2 mis=192 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=3 seed=808454966 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9648000 mis=8162 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=4 tx=0 mis=3991 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=4 tx=1 mis=3984 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=4 tx=2 mis=191 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=4 seed=808454967 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9688000 mis=8166 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=5 tx=0 mis=3985 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=5 tx=1 mis=3988 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=5 tx=2 mis=192 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=5 seed=808454968 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9653000 mis=8165 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=6 tx=0 mis=3987 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=6 tx=1 mis=3983 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=6 tx=2 mis=192 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=6 seed=808454969 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9724000 mis=8162 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=7 tx=0 mis=3988 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=7 tx=1 mis=3991 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=7 tx=2 mis=189 first=1 shift=0 |
| C3BP | req_hz=12000000 pass=7 seed=808454970 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9668000 mis=8168 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=8 tx=0 mis=3988 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=8 tx=1 mis=3989 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=8 tx=2 mis=191 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=8 seed=808454971 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10192000 mis=8168 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=9 tx=0 mis=3984 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=9 tx=1 mis=3983 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=9 tx=2 mis=191 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=9 seed=808454972 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9780000 mis=8158 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=10 tx=0 mis=3978 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=10 tx=1 mis=3992 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=10 tx=2 mis=191 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=10 seed=808454973 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9640000 mis=8161 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=11 tx=0 mis=3988 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=11 tx=1 mis=3984 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=11 tx=2 mis=192 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=11 seed=808454974 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9675000 mis=8164 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=12 tx=0 mis=3989 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=12 tx=1 mis=3991 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=12 tx=2 mis=191 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=12 seed=808454975 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9703000 mis=8171 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=13 tx=0 mis=3982 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=13 tx=1 mis=3982 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=13 tx=2 mis=192 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=13 seed=808454976 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10133000 mis=8156 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=14 tx=0 mis=3981 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=14 tx=1 mis=3985 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=14 tx=2 mis=192 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=14 seed=808454977 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9644000 mis=8158 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=15 tx=0 mis=3991 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=15 tx=1 mis=3986 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=15 tx=2 mis=191 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=15 seed=808454978 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9625000 mis=8168 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=16 tx=0 mis=3988 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=16 tx=1 mis=3982 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=16 tx=2 mis=190 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=16 seed=808454979 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9547000 mis=8160 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=17 tx=0 mis=3983 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=17 tx=1 mis=3971 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=17 tx=2 mis=192 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=17 seed=808454980 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9629000 mis=8146 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=18 tx=0 mis=3982 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=18 tx=1 mis=3976 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=18 tx=2 mis=191 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=18 seed=808454981 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9585000 mis=8149 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=19 tx=0 mis=3985 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=19 tx=1 mis=3981 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=19 tx=2 mis=192 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=19 seed=808454982 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9555000 mis=8158 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=20 tx=0 mis=3983 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=20 tx=1 mis=3986 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=20 tx=2 mis=191 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=20 seed=808454983 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9556000 mis=8160 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=21 tx=0 mis=3986 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=21 tx=1 mis=3982 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=21 tx=2 mis=192 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=21 seed=808454984 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9545000 mis=8160 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=22 tx=0 mis=3979 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=22 tx=1 mis=3991 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=22 tx=2 mis=191 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=22 seed=808454985 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9517000 mis=8161 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=23 tx=0 mis=3987 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=23 tx=1 mis=3980 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=23 tx=2 mis=191 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=23 seed=808454986 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9586000 mis=8158 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=24 tx=0 mis=3985 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=24 tx=1 mis=3979 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=24 tx=2 mis=190 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=24 seed=808454987 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9673000 mis=8154 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=25 tx=0 mis=3986 first=1 shift=0 |
| C3TX | req_hz=12000000 pass=25 tx=1 mis=3980 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=25 tx=2 mis=191 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=25 seed=808454988 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9552000 mis=8157 bad_tx=3 first_tx=0 first=1 shift=0 |
| C3TX | req_hz=12000000 pass=26 tx=0 mis=3990 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=26 tx=1 mis=3987 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=26 tx=2 mis=192 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=26 seed=808454989 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9550000 mis=8169 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=27 tx=0 mis=3984 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=27 tx=1 mis=3987 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=27 tx=2 mis=189 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=27 seed=808454990 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9552000 mis=8160 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=28 tx=0 mis=3982 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=28 tx=1 mis=3981 first=1 shift=0 |
| C3TX | req_hz=12000000 pass=28 tx=2 mis=192 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=28 seed=808454991 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9539000 mis=8155 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=29 tx=0 mis=3989 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=29 tx=1 mis=3982 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=29 tx=2 mis=190 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=29 seed=808454992 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9547000 mis=8161 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=30 tx=0 mis=3987 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=30 tx=1 mis=3984 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=30 tx=2 mis=192 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=30 seed=808454993 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9550000 mis=8163 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=31 tx=0 mis=3988 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=31 tx=1 mis=3987 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=31 tx=2 mis=192 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=31 seed=808454994 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9710000 mis=8167 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=32 tx=0 mis=3988 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=32 tx=1 mis=3979 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=32 tx=2 mis=192 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=32 seed=808454995 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9629000 mis=8159 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=33 tx=0 mis=3986 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=33 tx=1 mis=3984 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=33 tx=2 mis=190 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=33 seed=808454996 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10165000 mis=8160 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=34 tx=0 mis=3986 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=34 tx=1 mis=3982 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=34 tx=2 mis=191 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=34 seed=808454997 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9753000 mis=8159 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=35 tx=0 mis=3982 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=35 tx=1 mis=3981 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=35 tx=2 mis=191 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=35 seed=808454998 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9654000 mis=8154 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=36 tx=0 mis=3983 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=36 tx=1 mis=3990 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=36 tx=2 mis=192 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=36 seed=808454999 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9684000 mis=8165 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=37 tx=0 mis=3980 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=37 tx=1 mis=3979 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=37 tx=2 mis=189 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=37 seed=808455000 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9709000 mis=8148 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=38 tx=0 mis=3989 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=38 tx=1 mis=3989 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=38 tx=2 mis=191 first=1 shift=0 |
| C3BP | req_hz=12000000 pass=38 seed=808455001 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9704000 mis=8169 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=39 tx=0 mis=3986 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=39 tx=1 mis=3987 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=39 tx=2 mis=191 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=39 seed=808455002 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9663000 mis=8164 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=40 tx=0 mis=3979 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=40 tx=1 mis=3986 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=40 tx=2 mis=191 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=40 seed=808455003 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9656000 mis=8156 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=41 tx=0 mis=3984 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=41 tx=1 mis=3985 first=1 shift=0 |
| C3TX | req_hz=12000000 pass=41 tx=2 mis=191 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=41 seed=808455004 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9606000 mis=8160 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=42 tx=0 mis=3987 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=42 tx=1 mis=3984 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=42 tx=2 mis=190 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=42 seed=808455005 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9696000 mis=8161 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=43 tx=0 mis=3983 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=43 tx=1 mis=3990 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=43 tx=2 mis=192 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=43 seed=808455006 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9753000 mis=8165 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=44 tx=0 mis=3979 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=44 tx=1 mis=3974 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=44 tx=2 mis=191 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=44 seed=808455007 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9611000 mis=8144 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=45 tx=0 mis=3989 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=45 tx=1 mis=3981 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=45 tx=2 mis=192 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=45 seed=808455008 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9665000 mis=8162 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=46 tx=0 mis=3979 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=46 tx=1 mis=3984 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=46 tx=2 mis=191 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=46 seed=808455009 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9545000 mis=8154 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=47 tx=0 mis=3982 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=47 tx=1 mis=3977 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=47 tx=2 mis=192 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=47 seed=808455010 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9555000 mis=8151 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=48 tx=0 mis=3992 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=48 tx=1 mis=3979 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=48 tx=2 mis=192 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=48 seed=808455011 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9583000 mis=8163 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=49 tx=0 mis=3987 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=49 tx=1 mis=3985 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=49 tx=2 mis=191 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=49 seed=808455012 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9551000 mis=8163 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=50 tx=0 mis=3986 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=50 tx=1 mis=3990 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=50 tx=2 mis=192 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=50 seed=808455013 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9546000 mis=8168 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=51 tx=0 mis=3979 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=51 tx=1 mis=3987 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=51 tx=2 mis=190 first=1 shift=0 |
| C3BP | req_hz=12000000 pass=51 seed=808455014 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9679000 mis=8156 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=52 tx=0 mis=3984 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=52 tx=1 mis=3988 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=52 tx=2 mis=190 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=52 seed=808455015 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9550000 mis=8162 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=53 tx=0 mis=3983 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=53 tx=1 mis=3983 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=53 tx=2 mis=192 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=53 seed=808455016 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9578000 mis=8158 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=54 tx=0 mis=3990 first=1 shift=0 |
| C3TX | req_hz=12000000 pass=54 tx=1 mis=3986 first=1 shift=0 |
| C3TX | req_hz=12000000 pass=54 tx=2 mis=190 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=54 seed=808455017 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9549000 mis=8166 bad_tx=3 first_tx=0 first=1 shift=0 |
| C3TX | req_hz=12000000 pass=55 tx=0 mis=3986 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=55 tx=1 mis=3989 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=55 tx=2 mis=192 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=55 seed=808455018 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9546000 mis=8167 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=56 tx=0 mis=3987 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=56 tx=1 mis=3987 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=56 tx=2 mis=192 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=56 seed=808455019 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9545000 mis=8166 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=57 tx=0 mis=3981 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=57 tx=1 mis=3979 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=57 tx=2 mis=192 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=57 seed=808455020 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9572000 mis=8152 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=58 tx=0 mis=3980 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=58 tx=1 mis=3987 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=58 tx=2 mis=190 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=58 seed=808455021 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9585000 mis=8157 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=59 tx=0 mis=3982 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=59 tx=1 mis=3980 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=59 tx=2 mis=192 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=59 seed=808455022 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9546000 mis=8154 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=60 tx=0 mis=3984 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=60 tx=1 mis=3983 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=60 tx=2 mis=191 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=60 seed=808455023 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9609000 mis=8158 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=61 tx=0 mis=3983 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=61 tx=1 mis=3982 first=1 shift=0 |
| C3TX | req_hz=12000000 pass=61 tx=2 mis=192 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=61 seed=808455024 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9608000 mis=8157 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=62 tx=0 mis=3984 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=62 tx=1 mis=3985 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=62 tx=2 mis=191 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=62 seed=808455025 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9639000 mis=8160 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=63 tx=0 mis=3980 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=63 tx=1 mis=3981 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=63 tx=2 mis=188 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=63 seed=808455026 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10178000 mis=8149 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=64 tx=0 mis=3985 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=64 tx=1 mis=3983 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=64 tx=2 mis=190 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=64 seed=808455027 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9678000 mis=8158 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=65 tx=0 mis=3987 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=65 tx=1 mis=3986 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=65 tx=2 mis=192 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=65 seed=808455028 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9624000 mis=8165 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=66 tx=0 mis=3978 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=66 tx=1 mis=3979 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=66 tx=2 mis=192 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=66 seed=808455029 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9688000 mis=8149 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=67 tx=0 mis=3981 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=67 tx=1 mis=3984 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=67 tx=2 mis=191 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=67 seed=808455030 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9656000 mis=8156 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=68 tx=0 mis=3988 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=68 tx=1 mis=3984 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=68 tx=2 mis=192 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=68 seed=808455031 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9710000 mis=8164 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=69 tx=0 mis=3982 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=69 tx=1 mis=3986 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=69 tx=2 mis=190 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=69 seed=808455032 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9624000 mis=8158 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=70 tx=0 mis=3985 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=70 tx=1 mis=3986 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=70 tx=2 mis=190 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=70 seed=808455033 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9625000 mis=8161 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=71 tx=0 mis=3987 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=71 tx=1 mis=3987 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=71 tx=2 mis=192 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=71 seed=808455034 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9607000 mis=8166 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=72 tx=0 mis=3980 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=72 tx=1 mis=3980 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=72 tx=2 mis=192 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=72 seed=808455035 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9678000 mis=8152 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=73 tx=0 mis=3986 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=73 tx=1 mis=3986 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=73 tx=2 mis=191 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=73 seed=808455036 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9717000 mis=8163 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=74 tx=0 mis=3988 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=74 tx=1 mis=3981 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=74 tx=2 mis=191 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=74 seed=808455037 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9619000 mis=8160 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=75 tx=0 mis=3995 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=75 tx=1 mis=3986 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=75 tx=2 mis=191 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=75 seed=808455038 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9644000 mis=8172 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=76 tx=0 mis=3984 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=76 tx=1 mis=3991 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=76 tx=2 mis=192 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=76 seed=808455039 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9510000 mis=8167 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=77 tx=0 mis=3981 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=77 tx=1 mis=3985 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=77 tx=2 mis=191 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=77 seed=808455040 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9562000 mis=8157 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=78 tx=0 mis=3980 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=78 tx=1 mis=3986 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=78 tx=2 mis=192 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=78 seed=808455041 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9561000 mis=8158 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=79 tx=0 mis=3976 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=79 tx=1 mis=3986 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=79 tx=2 mis=191 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=79 seed=808455042 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9557000 mis=8153 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=80 tx=0 mis=3979 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=80 tx=1 mis=3987 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=80 tx=2 mis=192 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=80 seed=808455043 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9674000 mis=8158 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=81 tx=0 mis=3986 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=81 tx=1 mis=3981 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=81 tx=2 mis=191 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=81 seed=808455044 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9551000 mis=8158 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=82 tx=0 mis=3989 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=82 tx=1 mis=3982 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=82 tx=2 mis=190 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=82 seed=808455045 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9544000 mis=8161 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=83 tx=0 mis=3986 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=83 tx=1 mis=3981 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=83 tx=2 mis=192 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=83 seed=808455046 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9557000 mis=8159 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=84 tx=0 mis=3983 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=84 tx=1 mis=3985 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=84 tx=2 mis=191 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=84 seed=808455047 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9552000 mis=8159 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=85 tx=0 mis=3985 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=85 tx=1 mis=3985 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=85 tx=2 mis=190 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=85 seed=808455048 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9560000 mis=8160 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=86 tx=0 mis=3983 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=86 tx=1 mis=3990 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=86 tx=2 mis=192 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=86 seed=808455049 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9575000 mis=8165 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=87 tx=0 mis=3983 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=87 tx=1 mis=3981 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=87 tx=2 mis=191 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=87 seed=808455050 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9536000 mis=8155 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=88 tx=0 mis=3982 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=88 tx=1 mis=3978 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=88 tx=2 mis=191 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=88 seed=808455051 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9552000 mis=8151 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=89 tx=0 mis=3989 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=89 tx=1 mis=3985 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=89 tx=2 mis=192 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=89 seed=808455052 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9549000 mis=8166 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=90 tx=0 mis=3986 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=90 tx=1 mis=3988 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=90 tx=2 mis=191 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=90 seed=808455053 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9551000 mis=8165 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=91 tx=0 mis=3981 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=91 tx=1 mis=3985 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=91 tx=2 mis=192 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=91 seed=808455054 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9610000 mis=8158 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=92 tx=0 mis=3987 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=92 tx=1 mis=3987 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=92 tx=2 mis=190 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=92 seed=808455055 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9629000 mis=8164 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=93 tx=0 mis=3987 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=93 tx=1 mis=3979 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=93 tx=2 mis=190 first=1 shift=0 |
| C3BP | req_hz=12000000 pass=93 seed=808455056 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9737000 mis=8156 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=94 tx=0 mis=3985 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=94 tx=1 mis=3986 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=94 tx=2 mis=188 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=94 seed=808455057 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9661000 mis=8159 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=95 tx=0 mis=3986 first=1 shift=0 |
| C3TX | req_hz=12000000 pass=95 tx=1 mis=3976 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=95 tx=2 mis=190 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=95 seed=808455058 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9664000 mis=8152 bad_tx=3 first_tx=0 first=1 shift=0 |
| C3TX | req_hz=12000000 pass=96 tx=0 mis=3983 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=96 tx=1 mis=3990 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=96 tx=2 mis=191 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=96 seed=808455059 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10115000 mis=8164 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=97 tx=0 mis=3989 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=97 tx=1 mis=3988 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=97 tx=2 mis=190 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=97 seed=808455060 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9653000 mis=8167 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=98 tx=0 mis=3982 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=98 tx=1 mis=3995 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=98 tx=2 mis=192 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=98 seed=808455061 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9689000 mis=8169 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=99 tx=0 mis=3978 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=99 tx=1 mis=3983 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=99 tx=2 mis=191 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=99 seed=808455062 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9659000 mis=8152 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=100 tx=0 mis=3987 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=100 tx=1 mis=3985 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=100 tx=2 mis=191 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=100 seed=808455063 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9625000 mis=8163 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=101 tx=0 mis=3983 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=101 tx=1 mis=3988 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=101 tx=2 mis=191 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=101 seed=808455064 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10175000 mis=8162 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=102 tx=0 mis=3984 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=102 tx=1 mis=3988 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=102 tx=2 mis=189 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=102 seed=808455065 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9617000 mis=8161 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=103 tx=0 mis=3983 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=103 tx=1 mis=3983 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=103 tx=2 mis=192 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=103 seed=808455066 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9671000 mis=8158 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=104 tx=0 mis=3984 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=104 tx=1 mis=3985 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=104 tx=2 mis=191 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=104 seed=808455067 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9694000 mis=8160 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=105 tx=0 mis=3985 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=105 tx=1 mis=3988 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=105 tx=2 mis=192 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=105 seed=808455068 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9668000 mis=8165 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=106 tx=0 mis=3982 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=106 tx=1 mis=3985 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=106 tx=2 mis=192 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=106 seed=808455069 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10095000 mis=8159 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=107 tx=0 mis=3982 first=1 shift=0 |
| C3TX | req_hz=12000000 pass=107 tx=1 mis=3981 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=107 tx=2 mis=192 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=107 seed=808455070 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9540000 mis=8155 bad_tx=3 first_tx=0 first=1 shift=0 |
| C3TX | req_hz=12000000 pass=108 tx=0 mis=3989 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=108 tx=1 mis=3990 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=108 tx=2 mis=191 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=108 seed=808455071 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9558000 mis=8170 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=109 tx=0 mis=3990 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=109 tx=1 mis=3974 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=109 tx=2 mis=192 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=109 seed=808455072 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9562000 mis=8156 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=110 tx=0 mis=3986 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=110 tx=1 mis=3991 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=110 tx=2 mis=191 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=110 seed=808455073 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9584000 mis=8168 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=111 tx=0 mis=3985 first=1 shift=0 |
| C3TX | req_hz=12000000 pass=111 tx=1 mis=3991 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=111 tx=2 mis=192 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=111 seed=808455074 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9586000 mis=8168 bad_tx=3 first_tx=0 first=1 shift=0 |
| C3TX | req_hz=12000000 pass=112 tx=0 mis=3985 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=112 tx=1 mis=3983 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=112 tx=2 mis=192 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=112 seed=808455075 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9567000 mis=8160 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=113 tx=0 mis=3987 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=113 tx=1 mis=3989 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=113 tx=2 mis=192 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=113 seed=808455076 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9514000 mis=8168 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=114 tx=0 mis=3987 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=114 tx=1 mis=3983 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=114 tx=2 mis=191 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=114 seed=808455077 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9550000 mis=8161 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=115 tx=0 mis=3976 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=115 tx=1 mis=3986 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=115 tx=2 mis=192 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=115 seed=808455078 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9552000 mis=8154 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=116 tx=0 mis=3978 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=116 tx=1 mis=3987 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=116 tx=2 mis=191 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=116 seed=808455079 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9587000 mis=8156 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=117 tx=0 mis=3980 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=117 tx=1 mis=3984 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=117 tx=2 mis=189 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=117 seed=808455080 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9537000 mis=8153 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=118 tx=0 mis=3986 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=118 tx=1 mis=3988 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=118 tx=2 mis=190 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=118 seed=808455081 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9556000 mis=8164 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=119 tx=0 mis=3987 first=1 shift=0 |
| C3TX | req_hz=12000000 pass=119 tx=1 mis=3987 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=119 tx=2 mis=192 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=119 seed=808455082 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9559000 mis=8166 bad_tx=3 first_tx=0 first=1 shift=0 |
| C3TX | req_hz=12000000 pass=120 tx=0 mis=3991 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=120 tx=1 mis=3986 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=120 tx=2 mis=191 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=120 seed=808455083 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9558000 mis=8168 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=121 tx=0 mis=3983 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=121 tx=1 mis=3992 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=121 tx=2 mis=190 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=121 seed=808455084 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9584000 mis=8165 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=122 tx=0 mis=3991 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=122 tx=1 mis=3982 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=122 tx=2 mis=191 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=122 seed=808455085 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9657000 mis=8164 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=123 tx=0 mis=3983 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=123 tx=1 mis=3985 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=123 tx=2 mis=192 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=123 seed=808455086 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9685000 mis=8160 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=124 tx=0 mis=3984 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=124 tx=1 mis=3986 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=124 tx=2 mis=190 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=124 seed=808455087 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9665000 mis=8160 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=125 tx=0 mis=3983 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=125 tx=1 mis=3985 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=125 tx=2 mis=190 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=125 seed=808455088 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9665000 mis=8158 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=126 tx=0 mis=3985 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=126 tx=1 mis=3987 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=126 tx=2 mis=191 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=126 seed=808455089 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=10104000 mis=8163 bad_tx=3 first_tx=0 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=127 tx=0 mis=3980 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=127 tx=1 mis=3980 first=0 shift=0 |
| C3TX | req_hz=12000000 pass=127 tx=2 mis=192 first=0 shift=0 |
| C3BP | req_hz=12000000 pass=127 seed=808455090 hz=12000000 base=32768 bytes=8192 chunk=4000 ntx=3 ns=9684000 mis=8152 bad_tx=3 first_tx=0 first=0 shift=0 |
| P3RD | req_hz=2000000 eff_hz=1248334 bytes=1048576 mis=0 ns=6811283000 bad_tx=0 shift=0 |
| P3RD | req_hz=2500000 eff_hz=1555841 bytes=1048576 mis=0 ns=5467556000 bad_tx=0 shift=0 |
| P3RD | req_hz=3000000 eff_hz=1853101 bytes=1048576 mis=0 ns=4593996000 bad_tx=0 shift=0 |
| P3RD | req_hz=3500000 eff_hz=2135783 bytes=1048576 mis=0 ns=3989009000 bad_tx=0 shift=0 |
| P3RD | req_hz=4000000 eff_hz=2497002 bytes=1048576 mis=0 ns=3452010000 bad_tx=0 shift=0 |
| P3RD | req_hz=4500000 eff_hz=2767979 bytes=1048576 mis=0 ns=3116907000 bad_tx=0 shift=0 |
| P3RD | req_hz=5000000 eff_hz=3113938 bytes=1048576 mis=479194 ns=2854714000 bad_tx=264 shift=0 |
| C3TX | req_hz=5000000 pass=0 tx=0 mis=1850 first=0 shift=0 |
| C3TX | req_hz=5000000 pass=0 tx=1 mis=1812 first=0 shift=0 |
| C3TX | req_hz=5000000 pass=0 tx=2 mis=1839 first=2 shift=0 |
| C3TX | req_hz=5000000 pass=0 tx=3 mis=1844 first=1 shift=0 |
| C3TX | req_hz=5000000 pass=0 tx=4 mis=1831 first=2 shift=0 |
| C3TX | req_hz=5000000 pass=0 tx=5 mis=1803 first=1 shift=0 |
| C3TX | req_hz=5000000 pass=0 tx=6 mis=1817 first=1 shift=0 |
| C3TX | req_hz=5000000 pass=0 tx=7 mis=1814 first=2 shift=0 |
| C3TX | req_hz=5000000 pass=0 tx=8 mis=1855 first=1 shift=0 |
| C3TX | req_hz=5000000 pass=0 tx=9 mis=1823 first=0 shift=0 |
| C3TX | req_hz=5000000 pass=0 tx=10 mis=1805 first=0 shift=0 |
| C3TX | req_hz=5000000 pass=0 tx=11 mis=1855 first=0 shift=0 |
| C3TX | req_hz=5000000 pass=0 tx=12 mis=1827 first=0 shift=0 |
| C3TX | req_hz=5000000 pass=0 tx=13 mis=1807 first=2 shift=0 |
| C3TX | req_hz=5000000 pass=0 tx=14 mis=1847 first=0 shift=0 |
| C3TX | req_hz=5000000 pass=0 tx=15 mis=1819 first=2 shift=0 |
| C3TX | req_hz=5000000 pass=1 tx=0 mis=1827 first=1 shift=0 |
| C3TX | req_hz=5000000 pass=1 tx=1 mis=1825 first=0 shift=0 |
| C3TX | req_hz=5000000 pass=1 tx=2 mis=1834 first=1 shift=0 |
| C3TX | req_hz=5000000 pass=1 tx=3 mis=1829 first=1 shift=0 |
| C3TX | req_hz=5000000 pass=1 tx=4 mis=1812 first=0 shift=0 |
| C3TX | req_hz=5000000 pass=1 tx=5 mis=1806 first=2 shift=0 |
| C3TX | req_hz=5000000 pass=1 tx=6 mis=1834 first=2 shift=0 |
| C3TX | req_hz=5000000 pass=1 tx=7 mis=1835 first=2 shift=0 |
| C3TX | req_hz=5000000 pass=1 tx=8 mis=1833 first=0 shift=0 |
| C3TX | req_hz=5000000 pass=1 tx=9 mis=1827 first=2 shift=0 |
| C3TX | req_hz=5000000 pass=1 tx=10 mis=1833 first=1 shift=0 |
| C3TX | req_hz=5000000 pass=1 tx=11 mis=1828 first=1 shift=0 |
| C3TX | req_hz=5000000 pass=1 tx=12 mis=1824 first=0 shift=0 |
| C3TX | req_hz=5000000 pass=1 tx=13 mis=1825 first=1 shift=0 |
| C3TX | req_hz=5000000 pass=1 tx=14 mis=1821 first=0 shift=0 |
| C3TX | req_hz=5000000 pass=1 tx=15 mis=1828 first=2 shift=0 |
| C3TX | req_hz=5000000 pass=2 tx=0 mis=1844 first=1 shift=0 |
| C3TX | req_hz=5000000 pass=2 tx=1 mis=1803 first=2 shift=0 |
| C3TX | req_hz=5000000 pass=2 tx=2 mis=1841 first=0 shift=0 |
| C3TX | req_hz=5000000 pass=2 tx=3 mis=1839 first=3 shift=0 |
| C3TX | req_hz=5000000 pass=2 tx=4 mis=1830 first=0 shift=0 |
| C3TX | req_hz=5000000 pass=2 tx=5 mis=1820 first=0 shift=0 |
| C3TX | req_hz=5000000 pass=2 tx=6 mis=1822 first=1 shift=0 |
| C3TX | req_hz=5000000 pass=2 tx=7 mis=1813 first=1 shift=0 |
| C3TX | req_hz=5000000 pass=2 tx=8 mis=1832 first=0 shift=0 |
| C3TX | req_hz=5000000 pass=2 tx=9 mis=1829 first=2 shift=0 |
| C3TX | req_hz=5000000 pass=2 tx=10 mis=1806 first=0 shift=0 |
| C3TX | req_hz=5000000 pass=2 tx=11 mis=1824 first=0 shift=0 |
| C3TX | req_hz=5000000 pass=2 tx=12 mis=1847 first=2 shift=0 |
| C3TX | req_hz=5000000 pass=2 tx=13 mis=1839 first=1 shift=0 |
| C3TX | req_hz=5000000 pass=2 tx=14 mis=1847 first=2 shift=0 |
| C3TX | req_hz=5000000 pass=2 tx=15 mis=1833 first=2 shift=0 |
| C3TX | req_hz=5000000 pass=3 tx=0 mis=1834 first=2 shift=0 |
| C3TX | req_hz=5000000 pass=3 tx=1 mis=1827 first=0 shift=0 |
| C3TX | req_hz=5000000 pass=3 tx=2 mis=1808 first=0 shift=0 |
| C3TX | req_hz=5000000 pass=3 tx=3 mis=1834 first=1 shift=0 |
| C3TX | req_hz=5000000 pass=3 tx=4 mis=1846 first=2 shift=0 |
| C3TX | req_hz=5000000 pass=3 tx=5 mis=1816 first=0 shift=0 |
| C3TX | req_hz=5000000 pass=3 tx=6 mis=1841 first=2 shift=0 |
| C3TX | req_hz=5000000 pass=3 tx=7 mis=1861 first=2 shift=0 |
| C3TX | req_hz=5000000 pass=3 tx=8 mis=1848 first=2 shift=0 |
| C3TX | req_hz=5000000 pass=3 tx=9 mis=1831 first=2 shift=0 |
| C3TX | req_hz=5000000 pass=3 tx=10 mis=1810 first=2 shift=0 |
| C3TX | req_hz=5000000 pass=3 tx=11 mis=1827 first=1 shift=0 |
| C3TX | req_hz=5000000 pass=3 tx=12 mis=1845 first=0 shift=0 |
| C3TX | req_hz=5000000 pass=3 tx=13 mis=1836 first=2 shift=0 |
| C3TX | req_hz=5000000 pass=3 tx=14 mis=1825 first=2 shift=0 |
| C3TX | req_hz=5000000 pass=3 tx=15 mis=1832 first=1 shift=0 |
| P3RD | req_hz=5500000 eff_hz=3367202 bytes=1048576 mis=1003632 ns=2653535000 bad_tx=264 shift=0 |
| C3TX | req_hz=5500000 pass=0 tx=0 mis=3818 first=0 shift=0 |
| C3TX | req_hz=5500000 pass=0 tx=1 mis=3828 first=0 shift=0 |
| C3TX | req_hz=5500000 pass=0 tx=2 mis=3825 first=0 shift=0 |
| C3TX | req_hz=5500000 pass=0 tx=3 mis=3816 first=0 shift=0 |
| C3TX | req_hz=5500000 pass=0 tx=4 mis=3812 first=0 shift=0 |
| C3TX | req_hz=5500000 pass=0 tx=5 mis=3818 first=0 shift=0 |
| C3TX | req_hz=5500000 pass=0 tx=6 mis=3829 first=0 shift=0 |
| C3TX | req_hz=5500000 pass=0 tx=7 mis=3846 first=0 shift=0 |
| C3TX | req_hz=5500000 pass=0 tx=8 mis=3830 first=0 shift=0 |
| C3TX | req_hz=5500000 pass=0 tx=9 mis=3818 first=0 shift=0 |
| C3TX | req_hz=5500000 pass=0 tx=10 mis=3814 first=0 shift=0 |
| C3TX | req_hz=5500000 pass=0 tx=11 mis=3848 first=0 shift=0 |
| C3TX | req_hz=5500000 pass=0 tx=12 mis=3826 first=0 shift=0 |
| C3TX | req_hz=5500000 pass=0 tx=13 mis=3828 first=0 shift=0 |
| C3TX | req_hz=5500000 pass=0 tx=14 mis=3837 first=0 shift=0 |
| C3TX | req_hz=5500000 pass=0 tx=15 mis=3841 first=0 shift=0 |
| C3TX | req_hz=5500000 pass=1 tx=0 mis=3853 first=0 shift=0 |
| C3TX | req_hz=5500000 pass=1 tx=1 mis=3828 first=0 shift=0 |
| C3TX | req_hz=5500000 pass=1 tx=2 mis=3833 first=0 shift=0 |
| C3TX | req_hz=5500000 pass=1 tx=3 mis=3840 first=0 shift=0 |
| C3TX | req_hz=5500000 pass=1 tx=4 mis=3817 first=0 shift=0 |
| C3TX | req_hz=5500000 pass=1 tx=5 mis=3817 first=0 shift=0 |
| C3TX | req_hz=5500000 pass=1 tx=6 mis=3831 first=0 shift=0 |
| C3TX | req_hz=5500000 pass=1 tx=7 mis=3825 first=0 shift=0 |
| C3TX | req_hz=5500000 pass=1 tx=8 mis=3834 first=0 shift=0 |
| C3TX | req_hz=5500000 pass=1 tx=9 mis=3813 first=0 shift=0 |
| C3TX | req_hz=5500000 pass=1 tx=10 mis=3822 first=1 shift=0 |
| C3TX | req_hz=5500000 pass=1 tx=11 mis=3851 first=0 shift=0 |
| C3TX | req_hz=5500000 pass=1 tx=12 mis=3801 first=0 shift=0 |
| C3TX | req_hz=5500000 pass=1 tx=13 mis=3837 first=1 shift=0 |
| C3TX | req_hz=5500000 pass=1 tx=14 mis=3837 first=0 shift=0 |
| C3TX | req_hz=5500000 pass=1 tx=15 mis=3839 first=0 shift=0 |
| C3TX | req_hz=5500000 pass=2 tx=0 mis=3829 first=0 shift=0 |
| C3TX | req_hz=5500000 pass=2 tx=1 mis=3827 first=0 shift=0 |
| C3TX | req_hz=5500000 pass=2 tx=2 mis=3818 first=0 shift=0 |
| C3TX | req_hz=5500000 pass=2 tx=3 mis=3825 first=0 shift=0 |
| C3TX | req_hz=5500000 pass=2 tx=4 mis=3802 first=0 shift=0 |
| C3TX | req_hz=5500000 pass=2 tx=5 mis=3818 first=0 shift=0 |
| C3TX | req_hz=5500000 pass=2 tx=6 mis=3825 first=0 shift=0 |
| C3TX | req_hz=5500000 pass=2 tx=7 mis=3844 first=0 shift=0 |
| C3TX | req_hz=5500000 pass=2 tx=8 mis=3827 first=0 shift=0 |
| C3TX | req_hz=5500000 pass=2 tx=9 mis=3825 first=0 shift=0 |
| C3TX | req_hz=5500000 pass=2 tx=10 mis=3823 first=1 shift=0 |
| C3TX | req_hz=5500000 pass=2 tx=11 mis=3844 first=0 shift=0 |
| C3TX | req_hz=5500000 pass=2 tx=12 mis=3852 first=0 shift=0 |
| C3TX | req_hz=5500000 pass=2 tx=13 mis=3828 first=0 shift=0 |
| C3TX | req_hz=5500000 pass=2 tx=14 mis=3848 first=0 shift=0 |
| C3TX | req_hz=5500000 pass=2 tx=15 mis=3831 first=0 shift=0 |
| C3TX | req_hz=5500000 pass=3 tx=0 mis=3842 first=1 shift=0 |
| C3TX | req_hz=5500000 pass=3 tx=1 mis=3838 first=0 shift=0 |
| C3TX | req_hz=5500000 pass=3 tx=2 mis=3814 first=0 shift=0 |
| C3TX | req_hz=5500000 pass=3 tx=3 mis=3838 first=0 shift=0 |
| C3TX | req_hz=5500000 pass=3 tx=4 mis=3822 first=0 shift=0 |
| C3TX | req_hz=5500000 pass=3 tx=5 mis=3820 first=0 shift=0 |
| C3TX | req_hz=5500000 pass=3 tx=6 mis=3843 first=0 shift=0 |
| C3TX | req_hz=5500000 pass=3 tx=7 mis=3828 first=0 shift=0 |
| C3TX | req_hz=5500000 pass=3 tx=8 mis=3839 first=0 shift=0 |
| C3TX | req_hz=5500000 pass=3 tx=9 mis=3837 first=0 shift=0 |
| C3TX | req_hz=5500000 pass=3 tx=10 mis=3811 first=0 shift=0 |
| C3TX | req_hz=5500000 pass=3 tx=11 mis=3834 first=0 shift=0 |
| C3TX | req_hz=5500000 pass=3 tx=12 mis=3803 first=0 shift=0 |
| C3TX | req_hz=5500000 pass=3 tx=13 mis=3844 first=0 shift=0 |
| C3TX | req_hz=5500000 pass=3 tx=14 mis=3852 first=0 shift=0 |
| C3TX | req_hz=5500000 pass=3 tx=15 mis=3837 first=0 shift=0 |
| P3RD | req_hz=6000000 eff_hz=3644723 bytes=1048576 mis=1041956 ns=2448765000 bad_tx=264 shift=0 |
| C3TX | req_hz=6000000 pass=0 tx=0 mis=3982 first=0 shift=0 |
| C3TX | req_hz=6000000 pass=0 tx=1 mis=3979 first=0 shift=0 |
| C3TX | req_hz=6000000 pass=0 tx=2 mis=3970 first=0 shift=0 |
| C3TX | req_hz=6000000 pass=0 tx=3 mis=3979 first=0 shift=0 |
| C3TX | req_hz=6000000 pass=0 tx=4 mis=3967 first=0 shift=0 |
| C3TX | req_hz=6000000 pass=0 tx=5 mis=3962 first=0 shift=0 |
| C3TX | req_hz=6000000 pass=0 tx=6 mis=3978 first=0 shift=0 |
| C3TX | req_hz=6000000 pass=0 tx=7 mis=3974 first=0 shift=0 |
| C3TX | req_hz=6000000 pass=0 tx=8 mis=3976 first=0 shift=0 |
| C3TX | req_hz=6000000 pass=0 tx=9 mis=3978 first=0 shift=0 |
| C3TX | req_hz=6000000 pass=0 tx=10 mis=3977 first=0 shift=0 |
| C3TX | req_hz=6000000 pass=0 tx=11 mis=3971 first=0 shift=0 |
| C3TX | req_hz=6000000 pass=0 tx=12 mis=3970 first=0 shift=0 |
| C3TX | req_hz=6000000 pass=0 tx=13 mis=3983 first=0 shift=0 |
| C3TX | req_hz=6000000 pass=0 tx=14 mis=3982 first=0 shift=0 |
| C3TX | req_hz=6000000 pass=0 tx=15 mis=3978 first=0 shift=0 |
| C3TX | req_hz=6000000 pass=1 tx=0 mis=3980 first=0 shift=0 |
| C3TX | req_hz=6000000 pass=1 tx=1 mis=3977 first=0 shift=0 |
| C3TX | req_hz=6000000 pass=1 tx=2 mis=3973 first=0 shift=0 |
| C3TX | req_hz=6000000 pass=1 tx=3 mis=3980 first=0 shift=0 |
| C3TX | req_hz=6000000 pass=1 tx=4 mis=3972 first=0 shift=0 |
| C3TX | req_hz=6000000 pass=1 tx=5 mis=3972 first=0 shift=0 |
| C3TX | req_hz=6000000 pass=1 tx=6 mis=3976 first=0 shift=0 |
| C3TX | req_hz=6000000 pass=1 tx=7 mis=3976 first=0 shift=0 |
| C3TX | req_hz=6000000 pass=1 tx=8 mis=3978 first=0 shift=0 |
| C3TX | req_hz=6000000 pass=1 tx=9 mis=3975 first=0 shift=0 |
| C3TX | req_hz=6000000 pass=1 tx=10 mis=3974 first=0 shift=0 |
| C3TX | req_hz=6000000 pass=1 tx=11 mis=3969 first=0 shift=0 |
| C3TX | req_hz=6000000 pass=1 tx=12 mis=3974 first=0 shift=0 |
| C3TX | req_hz=6000000 pass=1 tx=13 mis=3977 first=0 shift=0 |
| C3TX | req_hz=6000000 pass=1 tx=14 mis=3984 first=0 shift=0 |
| C3TX | req_hz=6000000 pass=1 tx=15 mis=3983 first=0 shift=0 |
| C3TX | req_hz=6000000 pass=2 tx=0 mis=3982 first=0 shift=0 |
| C3TX | req_hz=6000000 pass=2 tx=1 mis=3974 first=0 shift=0 |
| C3TX | req_hz=6000000 pass=2 tx=2 mis=3969 first=0 shift=0 |
| C3TX | req_hz=6000000 pass=2 tx=3 mis=3979 first=0 shift=0 |
| C3TX | req_hz=6000000 pass=2 tx=4 mis=3967 first=0 shift=0 |
| C3TX | req_hz=6000000 pass=2 tx=5 mis=3967 first=0 shift=0 |
| C3TX | req_hz=6000000 pass=2 tx=6 mis=3976 first=0 shift=0 |
| C3TX | req_hz=6000000 pass=2 tx=7 mis=3982 first=0 shift=0 |
| C3TX | req_hz=6000000 pass=2 tx=8 mis=3970 first=0 shift=0 |
| C3TX | req_hz=6000000 pass=2 tx=9 mis=3975 first=0 shift=0 |
| C3TX | req_hz=6000000 pass=2 tx=10 mis=3977 first=0 shift=0 |
| C3TX | req_hz=6000000 pass=2 tx=11 mis=3969 first=0 shift=0 |
| C3TX | req_hz=6000000 pass=2 tx=12 mis=3975 first=0 shift=0 |
| C3TX | req_hz=6000000 pass=2 tx=13 mis=3980 first=0 shift=0 |
| C3TX | req_hz=6000000 pass=2 tx=14 mis=3976 first=0 shift=0 |
| C3TX | req_hz=6000000 pass=2 tx=15 mis=3986 first=0 shift=0 |
| C3TX | req_hz=6000000 pass=3 tx=0 mis=3976 first=0 shift=0 |
| C3TX | req_hz=6000000 pass=3 tx=1 mis=3973 first=0 shift=0 |
| C3TX | req_hz=6000000 pass=3 tx=2 mis=3974 first=0 shift=0 |
| C3TX | req_hz=6000000 pass=3 tx=3 mis=3980 first=0 shift=0 |
| C3TX | req_hz=6000000 pass=3 tx=4 mis=3972 first=0 shift=0 |
| C3TX | req_hz=6000000 pass=3 tx=5 mis=3969 first=0 shift=0 |
| C3TX | req_hz=6000000 pass=3 tx=6 mis=3975 first=0 shift=0 |
| C3TX | req_hz=6000000 pass=3 tx=7 mis=3977 first=0 shift=0 |
| C3TX | req_hz=6000000 pass=3 tx=8 mis=3973 first=0 shift=0 |
| C3TX | req_hz=6000000 pass=3 tx=9 mis=3981 first=0 shift=0 |
| C3TX | req_hz=6000000 pass=3 tx=10 mis=3974 first=0 shift=0 |
| C3TX | req_hz=6000000 pass=3 tx=11 mis=3977 first=0 shift=0 |
| C3TX | req_hz=6000000 pass=3 tx=12 mis=3972 first=0 shift=0 |
| C3TX | req_hz=6000000 pass=3 tx=13 mis=3978 first=0 shift=0 |
| C3TX | req_hz=6000000 pass=3 tx=14 mis=3978 first=0 shift=0 |
| C3TX | req_hz=6000000 pass=3 tx=15 mis=3985 first=0 shift=0 |
| P3CE | sram_hz=11000000 b7_hz=11000000 read_hz=4500000 |
| P3CH | chunk=64 bytes=262144 ns=1106775000 hz=11000000 mis=0 |
| P3CH | chunk=256 bytes=262144 ns=547324000 hz=11000000 mis=0 |
| P3CH | chunk=1024 bytes=262144 ns=382316000 hz=11000000 mis=0 |
| P3CH | chunk=4000 bytes=262144 ns=338103000 hz=11000000 mis=0 |
| P3WP | req_hz=2000000 eff_hz=1248334 bytes=1048576 ns=7320041000 mis=0 bad_tx=0 first_tx=-1 first=-1 shift=0 |
| P3WP | req_hz=2500000 eff_hz=1555841 bytes=1048576 ns=5977317000 mis=0 bad_tx=0 first_tx=-1 first=-1 shift=0 |
| P3WP | req_hz=3000000 eff_hz=1853101 bytes=1048576 ns=5087329000 mis=0 bad_tx=0 first_tx=-1 first=-1 shift=0 |
| P3WP | req_hz=3500000 eff_hz=2135783 bytes=1048576 ns=4509748000 mis=0 bad_tx=0 first_tx=-1 first=-1 shift=0 |
| P3WP | req_hz=4000000 eff_hz=2497002 bytes=1048576 ns=3938679000 mis=0 bad_tx=0 first_tx=-1 first=-1 shift=0 |
| P3WP | req_hz=4500000 eff_hz=2767979 bytes=1048576 ns=3629311000 mis=0 bad_tx=0 first_tx=-1 first=-1 shift=0 |
| P3WP | req_hz=5000000 eff_hz=3113938 bytes=1048576 ns=3284187000 mis=0 bad_tx=0 first_tx=-1 first=-1 shift=0 |
| P3WP | req_hz=5500000 eff_hz=3367202 bytes=1048576 ns=3101917000 mis=0 bad_tx=0 first_tx=-1 first=-1 shift=0 |
| P3WP | req_hz=6000000 eff_hz=3644723 bytes=1048576 ns=2896446000 mis=0 bad_tx=0 first_tx=-1 first=-1 shift=0 |
| P3WP | req_hz=6500000 eff_hz=4017855 bytes=1048576 ns=2673153000 mis=0 bad_tx=0 first_tx=-1 first=-1 shift=0 |
| P3WP | req_hz=7000000 eff_hz=4266667 bytes=1048576 ns=2566360000 mis=0 bad_tx=0 first_tx=-1 first=-1 shift=0 |
| P3WP | req_hz=7500000 eff_hz=4609184 bytes=1048576 ns=2422480000 mis=0 bad_tx=0 first_tx=-1 first=-1 shift=0 |
| P3WP | req_hz=8000000 eff_hz=4970431 bytes=1048576 ns=2280915000 mis=0 bad_tx=0 first_tx=-1 first=-1 shift=0 |
| P3WP | req_hz=8500000 eff_hz=5181801 bytes=1048576 ns=2205991000 mis=0 bad_tx=0 first_tx=-1 first=-1 shift=0 |
| P3WP | req_hz=9000000 eff_hz=5403563 bytes=1048576 ns=2163295000 mis=0 bad_tx=0 first_tx=-1 first=-1 shift=0 |
| P3WP | req_hz=9500000 eff_hz=5604338 bytes=1048576 ns=2068243000 mis=0 bad_tx=0 first_tx=-1 first=-1 shift=0 |
| P3WP | req_hz=10000000 eff_hz=6195382 bytes=1048576 ns=1941733000 mis=0 bad_tx=0 first_tx=-1 first=-1 shift=0 |
| P3WP | req_hz=11000000 eff_hz=6445830 bytes=1048576 ns=1888426000 mis=0 bad_tx=0 first_tx=-1 first=-1 shift=0 |
| P3CP | chunk=64 bytes=262144 ns=6358694000 hz=11000000 mis=0 |
| P3CP | chunk=256 bytes=262144 ns=1950520000 hz=11000000 mis=0 |
| P3CP | chunk=1024 bytes=262144 ns=735151000 hz=11000000 mis=0 |
| P3CP | chunk=4000 bytes=262144 ns=465350000 hz=11000000 mis=0 |
| P3HQ | row=5 us=1250018 |
| P3HQ | row=0 us=2066774 |
| P3HS | row=0 tgt=0 hz=11000000 bytes=16384 passes=61 ntx=309 ns=1354363000 stop=0 |
| P3HS | row=0 tgt=1 hz=11000000 bytes=4096 passes=226 ntx=452 ns=1251537000 stop=0 |
| P3HS | row=0 tgt=2 hz=11000000 bytes=8192 passes=122 ntx=366 ns=1302002000 stop=0 |
| P3HQ | row=1 us=2036456 |
| P3HS | row=1 tgt=0 hz=11000000 bytes=16384 passes=61 ntx=309 ns=1347384000 stop=0 |
| P3HS | row=1 tgt=1 hz=11000000 bytes=2048 passes=432 ntx=432 ns=1222162000 stop=0 |
| P3HS | row=1 tgt=2 hz=11000000 bytes=8192 passes=121 ntx=363 ns=1309332000 stop=0 |
| P3HQ | row=2 us=2036456 |
| P3HS | row=2 tgt=0 hz=11000000 bytes=16384 passes=60 ntx=303 ns=1330310000 stop=0 |
| P3HS | row=2 tgt=1 hz=11000000 bytes=2048 passes=452 ntx=452 ns=1231184000 stop=0 |
| P3HS | row=2 tgt=2 hz=11000000 bytes=8192 passes=122 ntx=366 ns=1301703000 stop=0 |
| P3HQ | row=3 us=1897179 |
| P3HS | row=3 tgt=0 hz=11000000 bytes=16384 passes=61 ntx=308 ns=1341930000 stop=0 |
| P3HS | row=3 tgt=1 hz=11000000 bytes=1024 passes=735 ntx=735 ns=1151206000 stop=0 |
| P3HS | row=3 tgt=2 hz=11000000 bytes=8192 passes=122 ntx=366 ns=1316956000 stop=0 |
| P3HQ | row=4 us=2450602 |
| P3HS | row=4 tgt=0 hz=11000000 bytes=16384 passes=58 ntx=294 ns=1291314000 stop=0 |
| P3HS | row=4 tgt=1 hz=11000000 bytes=4096 passes=228 ntx=456 ns=1268368000 stop=0 |
| P3HS | row=4 tgt=2 hz=11000000 bytes=8192 passes=122 ntx=366 ns=1299767000 stop=0 |
| P3SV | prof=0 hz=11000000 bytes=1048576 ns=1358664000 mis=0 bad_tx=0 first_tx=-1 shift=0 |
| P3SV | prof=0 hz=4000000 bytes=1048576 ns=3438685000 mis=0 bad_tx=0 first_tx=-1 shift=0 |
| P3SV | prof=0 hz=2000000 bytes=1048576 ns=6795485000 mis=0 bad_tx=0 first_tx=-1 shift=0 |
| P3SR | prof=0 req_hz=2000000 eff_hz=1248334 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=0 req_hz=2000000 eff_hz=1248334 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=0 req_hz=2000000 eff_hz=1248334 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=0 req_hz=2500000 eff_hz=1555841 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=0 req_hz=2500000 eff_hz=1555841 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=0 req_hz=2500000 eff_hz=1555841 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=0 req_hz=3000000 eff_hz=1853101 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=0 req_hz=3000000 eff_hz=1853101 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=0 req_hz=3000000 eff_hz=1853101 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=0 req_hz=3500000 eff_hz=2135783 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=0 req_hz=3500000 eff_hz=2135783 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=0 req_hz=3500000 eff_hz=2135783 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=0 req_hz=4000000 eff_hz=2497002 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=0 req_hz=4000000 eff_hz=2497002 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=0 req_hz=4000000 eff_hz=2497002 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=0 req_hz=4500000 eff_hz=2767979 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=0 req_hz=4500000 eff_hz=2767979 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=0 req_hz=4500000 eff_hz=2767979 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=0 req_hz=5000000 eff_hz=3113938 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=0 req_hz=5000000 eff_hz=3113938 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=0 req_hz=5000000 eff_hz=3113938 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=0 req_hz=5500000 eff_hz=3367202 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=0 req_hz=5500000 eff_hz=3367202 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=0 req_hz=5500000 eff_hz=3367202 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=0 req_hz=6000000 eff_hz=3644723 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=0 req_hz=6000000 eff_hz=3644723 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=0 req_hz=6000000 eff_hz=3644723 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=0 req_hz=6500000 eff_hz=4017855 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=0 req_hz=6500000 eff_hz=4017855 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=0 req_hz=6500000 eff_hz=4017855 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=0 req_hz=7000000 eff_hz=4266667 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=0 req_hz=7000000 eff_hz=4266667 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=0 req_hz=7000000 eff_hz=4266667 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=0 req_hz=7500000 eff_hz=4609184 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=0 req_hz=7500000 eff_hz=4609184 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=0 req_hz=7500000 eff_hz=4609184 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=0 req_hz=8000000 eff_hz=4970431 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=0 req_hz=8000000 eff_hz=4970431 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=0 req_hz=8000000 eff_hz=4970431 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=0 req_hz=8500000 eff_hz=5181801 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=0 req_hz=8500000 eff_hz=5181801 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=0 req_hz=8500000 eff_hz=5181801 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=0 req_hz=9000000 eff_hz=5403563 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=0 req_hz=9000000 eff_hz=5403563 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=0 req_hz=9000000 eff_hz=5403563 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=0 req_hz=9500000 eff_hz=5604338 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=0 req_hz=9500000 eff_hz=5604338 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=0 req_hz=9500000 eff_hz=5604338 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=0 req_hz=10000000 eff_hz=6195382 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=0 req_hz=10000000 eff_hz=6195382 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=0 req_hz=10000000 eff_hz=6195382 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=0 req_hz=11000000 eff_hz=6445830 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=0 req_hz=11000000 eff_hz=6445830 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=0 req_hz=11000000 eff_hz=6445830 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=0 req_hz=11500000 eff_hz=6972514 mis=1044184 bad_tx=264 shift=0 rep=0 |
| C3TX | req_hz=11500000 prof=0 pass=0 tx=0 mis=3981 first=2 shift=0 |
| C3TX | req_hz=11500000 prof=0 pass=0 tx=1 mis=3987 first=1 shift=0 |
| C3TX | req_hz=11500000 prof=0 pass=0 tx=2 mis=3981 first=2 shift=0 |
| C3TX | req_hz=11500000 prof=0 pass=0 tx=3 mis=3988 first=0 shift=0 |
| C3TX | req_hz=11500000 prof=0 pass=0 tx=4 mis=3983 first=3 shift=0 |
| C3TX | req_hz=11500000 prof=0 pass=0 tx=5 mis=3990 first=0 shift=0 |
| C3TX | req_hz=11500000 prof=0 pass=0 tx=6 mis=3984 first=3 shift=0 |
| C3TX | req_hz=11500000 prof=0 pass=0 tx=7 mis=3989 first=0 shift=0 |
| C3TX | req_hz=11500000 prof=0 pass=0 tx=8 mis=3988 first=1 shift=0 |
| C3TX | req_hz=11500000 prof=0 pass=0 tx=9 mis=3978 first=2 shift=0 |
| C3TX | req_hz=11500000 prof=0 pass=0 tx=10 mis=3981 first=0 shift=0 |
| C3TX | req_hz=11500000 prof=0 pass=0 tx=11 mis=3987 first=3 shift=0 |
| C3TX | req_hz=11500000 prof=0 pass=0 tx=12 mis=3977 first=4 shift=0 |
| C3TX | req_hz=11500000 prof=0 pass=0 tx=13 mis=3977 first=3 shift=0 |
| C3TX | req_hz=11500000 prof=0 pass=0 tx=14 mis=3984 first=1 shift=0 |
| C3TX | req_hz=11500000 prof=0 pass=0 tx=15 mis=3983 first=2 shift=0 |
| C3TX | req_hz=11500000 prof=0 pass=1 tx=0 mis=3976 first=0 shift=0 |
| C3TX | req_hz=11500000 prof=0 pass=1 tx=1 mis=3978 first=2 shift=0 |
| C3TX | req_hz=11500000 prof=0 pass=1 tx=2 mis=3986 first=1 shift=0 |
| C3TX | req_hz=11500000 prof=0 pass=1 tx=3 mis=3985 first=1 shift=0 |
| C3TX | req_hz=11500000 prof=0 pass=1 tx=4 mis=3986 first=0 shift=0 |
| C3TX | req_hz=11500000 prof=0 pass=1 tx=5 mis=3986 first=1 shift=0 |
| C3TX | req_hz=11500000 prof=0 pass=1 tx=6 mis=3980 first=3 shift=0 |
| C3TX | req_hz=11500000 prof=0 pass=1 tx=7 mis=3984 first=0 shift=0 |
| C3TX | req_hz=11500000 prof=0 pass=1 tx=8 mis=3984 first=3 shift=0 |
| C3TX | req_hz=11500000 prof=0 pass=1 tx=9 mis=3981 first=3 shift=0 |
| C3TX | req_hz=11500000 prof=0 pass=1 tx=10 mis=3981 first=3 shift=0 |
| C3TX | req_hz=11500000 prof=0 pass=1 tx=11 mis=3980 first=2 shift=0 |
| C3TX | req_hz=11500000 prof=0 pass=1 tx=12 mis=3982 first=1 shift=0 |
| C3TX | req_hz=11500000 prof=0 pass=1 tx=13 mis=3980 first=3 shift=0 |
| C3TX | req_hz=11500000 prof=0 pass=1 tx=14 mis=3988 first=3 shift=0 |
| C3TX | req_hz=11500000 prof=0 pass=1 tx=15 mis=3985 first=2 shift=0 |
| C3TX | req_hz=11500000 prof=0 pass=2 tx=0 mis=3986 first=2 shift=0 |
| C3TX | req_hz=11500000 prof=0 pass=2 tx=1 mis=3984 first=3 shift=0 |
| C3TX | req_hz=11500000 prof=0 pass=2 tx=2 mis=3987 first=0 shift=0 |
| C3TX | req_hz=11500000 prof=0 pass=2 tx=3 mis=3977 first=2 shift=0 |
| C3TX | req_hz=11500000 prof=0 pass=2 tx=4 mis=3977 first=1 shift=0 |
| C3TX | req_hz=11500000 prof=0 pass=2 tx=5 mis=3986 first=3 shift=0 |
| C3TX | req_hz=11500000 prof=0 pass=2 tx=6 mis=3989 first=3 shift=0 |
| C3TX | req_hz=11500000 prof=0 pass=2 tx=7 mis=3982 first=0 shift=0 |
| C3TX | req_hz=11500000 prof=0 pass=2 tx=8 mis=3987 first=0 shift=0 |
| C3TX | req_hz=11500000 prof=0 pass=2 tx=9 mis=3985 first=0 shift=0 |
| C3TX | req_hz=11500000 prof=0 pass=2 tx=10 mis=3980 first=3 shift=0 |
| C3TX | req_hz=11500000 prof=0 pass=2 tx=11 mis=3978 first=0 shift=0 |
| C3TX | req_hz=11500000 prof=0 pass=2 tx=12 mis=3981 first=2 shift=0 |
| C3TX | req_hz=11500000 prof=0 pass=2 tx=13 mis=3982 first=2 shift=0 |
| C3TX | req_hz=11500000 prof=0 pass=2 tx=14 mis=3988 first=1 shift=0 |
| C3TX | req_hz=11500000 prof=0 pass=2 tx=15 mis=3983 first=3 shift=0 |
| C3TX | req_hz=11500000 prof=0 pass=3 tx=0 mis=3987 first=1 shift=0 |
| C3TX | req_hz=11500000 prof=0 pass=3 tx=1 mis=3982 first=0 shift=0 |
| C3TX | req_hz=11500000 prof=0 pass=3 tx=2 mis=3982 first=3 shift=0 |
| C3TX | req_hz=11500000 prof=0 pass=3 tx=3 mis=3983 first=0 shift=0 |
| C3TX | req_hz=11500000 prof=0 pass=3 tx=4 mis=3982 first=0 shift=0 |
| C3TX | req_hz=11500000 prof=0 pass=3 tx=5 mis=3987 first=1 shift=0 |
| C3TX | req_hz=11500000 prof=0 pass=3 tx=6 mis=3987 first=3 shift=0 |
| C3TX | req_hz=11500000 prof=0 pass=3 tx=7 mis=3979 first=2 shift=0 |
| C3TX | req_hz=11500000 prof=0 pass=3 tx=8 mis=3982 first=2 shift=0 |
| C3TX | req_hz=11500000 prof=0 pass=3 tx=9 mis=3988 first=1 shift=0 |
| C3TX | req_hz=11500000 prof=0 pass=3 tx=10 mis=3986 first=0 shift=0 |
| C3TX | req_hz=11500000 prof=0 pass=3 tx=11 mis=3988 first=0 shift=0 |
| C3TX | req_hz=11500000 prof=0 pass=3 tx=12 mis=3975 first=1 shift=0 |
| C3TX | req_hz=11500000 prof=0 pass=3 tx=13 mis=3981 first=2 shift=0 |
| C3TX | req_hz=11500000 prof=0 pass=3 tx=14 mis=3982 first=1 shift=0 |
| C3TX | req_hz=11500000 prof=0 pass=3 tx=15 mis=3988 first=0 shift=0 |
| P3SR | prof=0 req_hz=12000000 eff_hz=7333509 mis=1044505 bad_tx=264 shift=0 rep=0 |
| C3TX | req_hz=12000000 prof=0 pass=0 tx=0 mis=3983 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=0 pass=0 tx=1 mis=3978 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=0 pass=0 tx=2 mis=3984 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=0 pass=0 tx=3 mis=3983 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=0 pass=0 tx=4 mis=3978 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=0 pass=0 tx=5 mis=3977 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=0 pass=0 tx=6 mis=3980 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=0 pass=0 tx=7 mis=3979 first=1 shift=0 |
| C3TX | req_hz=12000000 prof=0 pass=0 tx=8 mis=3986 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=0 pass=0 tx=9 mis=3985 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=0 pass=0 tx=10 mis=3990 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=0 pass=0 tx=11 mis=3986 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=0 pass=0 tx=12 mis=3989 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=0 pass=0 tx=13 mis=3982 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=0 pass=0 tx=14 mis=3992 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=0 pass=0 tx=15 mis=3986 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=0 pass=1 tx=0 mis=3989 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=0 pass=1 tx=1 mis=3981 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=0 pass=1 tx=2 mis=3980 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=0 pass=1 tx=3 mis=3975 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=0 pass=1 tx=4 mis=3986 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=0 pass=1 tx=5 mis=3981 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=0 pass=1 tx=6 mis=3977 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=0 pass=1 tx=7 mis=3984 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=0 pass=1 tx=8 mis=3979 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=0 pass=1 tx=9 mis=3987 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=0 pass=1 tx=10 mis=3983 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=0 pass=1 tx=11 mis=3981 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=0 pass=1 tx=12 mis=3988 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=0 pass=1 tx=13 mis=3984 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=0 pass=1 tx=14 mis=3984 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=0 pass=1 tx=15 mis=3979 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=0 pass=2 tx=0 mis=3993 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=0 pass=2 tx=1 mis=3988 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=0 pass=2 tx=2 mis=3980 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=0 pass=2 tx=3 mis=3992 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=0 pass=2 tx=4 mis=3985 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=0 pass=2 tx=5 mis=3985 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=0 pass=2 tx=6 mis=3985 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=0 pass=2 tx=7 mis=3982 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=0 pass=2 tx=8 mis=3983 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=0 pass=2 tx=9 mis=3986 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=0 pass=2 tx=10 mis=3990 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=0 pass=2 tx=11 mis=3987 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=0 pass=2 tx=12 mis=3977 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=0 pass=2 tx=13 mis=3990 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=0 pass=2 tx=14 mis=3986 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=0 pass=2 tx=15 mis=3988 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=0 pass=3 tx=0 mis=3982 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=0 pass=3 tx=1 mis=3985 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=0 pass=3 tx=2 mis=3983 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=0 pass=3 tx=3 mis=3990 first=1 shift=0 |
| C3TX | req_hz=12000000 prof=0 pass=3 tx=4 mis=3987 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=0 pass=3 tx=5 mis=3990 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=0 pass=3 tx=6 mis=3986 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=0 pass=3 tx=7 mis=3982 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=0 pass=3 tx=8 mis=3981 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=0 pass=3 tx=9 mis=3982 first=1 shift=0 |
| C3TX | req_hz=12000000 prof=0 pass=3 tx=10 mis=3988 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=0 pass=3 tx=11 mis=3983 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=0 pass=3 tx=12 mis=3982 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=0 pass=3 tx=13 mis=3988 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=0 pass=3 tx=14 mis=3986 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=0 pass=3 tx=15 mis=3976 first=0 shift=0 |
| P3SC | prof=0 ceiling_hz=11000000 |
| P3SV | prof=1 hz=11000000 bytes=1048576 ns=1348550000 mis=0 bad_tx=0 first_tx=-1 shift=0 |
| P3SV | prof=1 hz=4000000 bytes=1048576 ns=3437944000 mis=0 bad_tx=0 first_tx=-1 shift=0 |
| P3SV | prof=1 hz=2000000 bytes=1048576 ns=6797603000 mis=0 bad_tx=0 first_tx=-1 shift=0 |
| P3SR | prof=1 req_hz=2000000 eff_hz=1248334 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=1 req_hz=2000000 eff_hz=1248334 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=1 req_hz=2000000 eff_hz=1248334 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=1 req_hz=2500000 eff_hz=1555841 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=1 req_hz=2500000 eff_hz=1555841 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=1 req_hz=2500000 eff_hz=1555841 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=1 req_hz=3000000 eff_hz=1853101 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=1 req_hz=3000000 eff_hz=1853101 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=1 req_hz=3000000 eff_hz=1853101 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=1 req_hz=3500000 eff_hz=2135783 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=1 req_hz=3500000 eff_hz=2135783 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=1 req_hz=3500000 eff_hz=2135783 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=1 req_hz=4000000 eff_hz=2497002 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=1 req_hz=4000000 eff_hz=2497002 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=1 req_hz=4000000 eff_hz=2497002 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=1 req_hz=4500000 eff_hz=2767979 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=1 req_hz=4500000 eff_hz=2767979 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=1 req_hz=4500000 eff_hz=2767979 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=1 req_hz=5000000 eff_hz=3113938 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=1 req_hz=5000000 eff_hz=3113938 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=1 req_hz=5000000 eff_hz=3113938 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=1 req_hz=5500000 eff_hz=3367202 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=1 req_hz=5500000 eff_hz=3367202 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=1 req_hz=5500000 eff_hz=3367202 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=1 req_hz=6000000 eff_hz=3644723 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=1 req_hz=6000000 eff_hz=3644723 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=1 req_hz=6000000 eff_hz=3644723 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=1 req_hz=6500000 eff_hz=4017855 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=1 req_hz=6500000 eff_hz=4017855 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=1 req_hz=6500000 eff_hz=4017855 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=1 req_hz=7000000 eff_hz=4266667 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=1 req_hz=7000000 eff_hz=4266667 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=1 req_hz=7000000 eff_hz=4266667 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=1 req_hz=7500000 eff_hz=4609184 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=1 req_hz=7500000 eff_hz=4609184 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=1 req_hz=7500000 eff_hz=4609184 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=1 req_hz=8000000 eff_hz=4970431 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=1 req_hz=8000000 eff_hz=4970431 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=1 req_hz=8000000 eff_hz=4970431 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=1 req_hz=8500000 eff_hz=5181801 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=1 req_hz=8500000 eff_hz=5181801 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=1 req_hz=8500000 eff_hz=5181801 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=1 req_hz=9000000 eff_hz=5403563 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=1 req_hz=9000000 eff_hz=5403563 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=1 req_hz=9000000 eff_hz=5403563 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=1 req_hz=9500000 eff_hz=5604338 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=1 req_hz=9500000 eff_hz=5604338 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=1 req_hz=9500000 eff_hz=5604338 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=1 req_hz=10000000 eff_hz=6195382 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=1 req_hz=10000000 eff_hz=6195382 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=1 req_hz=10000000 eff_hz=6195382 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=1 req_hz=11000000 eff_hz=6445830 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=1 req_hz=11000000 eff_hz=6445830 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=1 req_hz=11000000 eff_hz=6445830 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=1 req_hz=11500000 eff_hz=6972514 mis=1044110 bad_tx=264 shift=0 rep=0 |
| C3TX | req_hz=11500000 prof=1 pass=0 tx=0 mis=3978 first=2 shift=0 |
| C3TX | req_hz=11500000 prof=1 pass=0 tx=1 mis=3991 first=0 shift=0 |
| C3TX | req_hz=11500000 prof=1 pass=0 tx=2 mis=3980 first=3 shift=0 |
| C3TX | req_hz=11500000 prof=1 pass=0 tx=3 mis=3983 first=1 shift=0 |
| C3TX | req_hz=11500000 prof=1 pass=0 tx=4 mis=3988 first=3 shift=0 |
| C3TX | req_hz=11500000 prof=1 pass=0 tx=5 mis=3982 first=2 shift=0 |
| C3TX | req_hz=11500000 prof=1 pass=0 tx=6 mis=3974 first=3 shift=0 |
| C3TX | req_hz=11500000 prof=1 pass=0 tx=7 mis=3982 first=3 shift=0 |
| C3TX | req_hz=11500000 prof=1 pass=0 tx=8 mis=3978 first=3 shift=0 |
| C3TX | req_hz=11500000 prof=1 pass=0 tx=9 mis=3989 first=0 shift=0 |
| C3TX | req_hz=11500000 prof=1 pass=0 tx=10 mis=3987 first=2 shift=0 |
| C3TX | req_hz=11500000 prof=1 pass=0 tx=11 mis=3988 first=3 shift=0 |
| C3TX | req_hz=11500000 prof=1 pass=0 tx=12 mis=3979 first=2 shift=0 |
| C3TX | req_hz=11500000 prof=1 pass=0 tx=13 mis=3982 first=1 shift=0 |
| C3TX | req_hz=11500000 prof=1 pass=0 tx=14 mis=3987 first=1 shift=0 |
| C3TX | req_hz=11500000 prof=1 pass=0 tx=15 mis=3979 first=2 shift=0 |
| C3TX | req_hz=11500000 prof=1 pass=1 tx=0 mis=3982 first=3 shift=0 |
| C3TX | req_hz=11500000 prof=1 pass=1 tx=1 mis=3989 first=0 shift=0 |
| C3TX | req_hz=11500000 prof=1 pass=1 tx=2 mis=3985 first=1 shift=0 |
| C3TX | req_hz=11500000 prof=1 pass=1 tx=3 mis=3985 first=1 shift=0 |
| C3TX | req_hz=11500000 prof=1 pass=1 tx=4 mis=3991 first=1 shift=0 |
| C3TX | req_hz=11500000 prof=1 pass=1 tx=5 mis=3986 first=2 shift=0 |
| C3TX | req_hz=11500000 prof=1 pass=1 tx=6 mis=3977 first=2 shift=0 |
| C3TX | req_hz=11500000 prof=1 pass=1 tx=7 mis=3979 first=3 shift=0 |
| C3TX | req_hz=11500000 prof=1 pass=1 tx=8 mis=3980 first=2 shift=0 |
| C3TX | req_hz=11500000 prof=1 pass=1 tx=9 mis=3977 first=4 shift=0 |
| C3TX | req_hz=11500000 prof=1 pass=1 tx=10 mis=3990 first=0 shift=0 |
| C3TX | req_hz=11500000 prof=1 pass=1 tx=11 mis=3990 first=0 shift=0 |
| C3TX | req_hz=11500000 prof=1 pass=1 tx=12 mis=3986 first=2 shift=0 |
| C3TX | req_hz=11500000 prof=1 pass=1 tx=13 mis=3983 first=2 shift=0 |
| C3TX | req_hz=11500000 prof=1 pass=1 tx=14 mis=3985 first=3 shift=0 |
| C3TX | req_hz=11500000 prof=1 pass=1 tx=15 mis=3976 first=2 shift=0 |
| C3TX | req_hz=11500000 prof=1 pass=2 tx=0 mis=3978 first=2 shift=0 |
| C3TX | req_hz=11500000 prof=1 pass=2 tx=1 mis=3981 first=2 shift=0 |
| C3TX | req_hz=11500000 prof=1 pass=2 tx=2 mis=3975 first=3 shift=0 |
| C3TX | req_hz=11500000 prof=1 pass=2 tx=3 mis=3984 first=2 shift=0 |
| C3TX | req_hz=11500000 prof=1 pass=2 tx=4 mis=3981 first=1 shift=0 |
| C3TX | req_hz=11500000 prof=1 pass=2 tx=5 mis=3988 first=0 shift=0 |
| C3TX | req_hz=11500000 prof=1 pass=2 tx=6 mis=3977 first=2 shift=0 |
| C3TX | req_hz=11500000 prof=1 pass=2 tx=7 mis=3974 first=2 shift=0 |
| C3TX | req_hz=11500000 prof=1 pass=2 tx=8 mis=3976 first=3 shift=0 |
| C3TX | req_hz=11500000 prof=1 pass=2 tx=9 mis=3992 first=0 shift=0 |
| C3TX | req_hz=11500000 prof=1 pass=2 tx=10 mis=3982 first=3 shift=0 |
| C3TX | req_hz=11500000 prof=1 pass=2 tx=11 mis=3973 first=4 shift=0 |
| C3TX | req_hz=11500000 prof=1 pass=2 tx=12 mis=3978 first=2 shift=0 |
| C3TX | req_hz=11500000 prof=1 pass=2 tx=13 mis=3983 first=0 shift=0 |
| C3TX | req_hz=11500000 prof=1 pass=2 tx=14 mis=3979 first=3 shift=0 |
| C3TX | req_hz=11500000 prof=1 pass=2 tx=15 mis=3981 first=1 shift=0 |
| C3TX | req_hz=11500000 prof=1 pass=3 tx=0 mis=3984 first=1 shift=0 |
| C3TX | req_hz=11500000 prof=1 pass=3 tx=1 mis=3976 first=1 shift=0 |
| C3TX | req_hz=11500000 prof=1 pass=3 tx=2 mis=3983 first=0 shift=0 |
| C3TX | req_hz=11500000 prof=1 pass=3 tx=3 mis=3985 first=1 shift=0 |
| C3TX | req_hz=11500000 prof=1 pass=3 tx=4 mis=3986 first=1 shift=0 |
| C3TX | req_hz=11500000 prof=1 pass=3 tx=5 mis=3983 first=2 shift=0 |
| C3TX | req_hz=11500000 prof=1 pass=3 tx=6 mis=3986 first=2 shift=0 |
| C3TX | req_hz=11500000 prof=1 pass=3 tx=7 mis=3987 first=1 shift=0 |
| C3TX | req_hz=11500000 prof=1 pass=3 tx=8 mis=3980 first=2 shift=0 |
| C3TX | req_hz=11500000 prof=1 pass=3 tx=9 mis=3985 first=1 shift=0 |
| C3TX | req_hz=11500000 prof=1 pass=3 tx=10 mis=3984 first=1 shift=0 |
| C3TX | req_hz=11500000 prof=1 pass=3 tx=11 mis=3985 first=2 shift=0 |
| C3TX | req_hz=11500000 prof=1 pass=3 tx=12 mis=3986 first=1 shift=0 |
| C3TX | req_hz=11500000 prof=1 pass=3 tx=13 mis=3981 first=3 shift=0 |
| C3TX | req_hz=11500000 prof=1 pass=3 tx=14 mis=3982 first=3 shift=0 |
| C3TX | req_hz=11500000 prof=1 pass=3 tx=15 mis=3983 first=3 shift=0 |
| P3SR | prof=1 req_hz=12000000 eff_hz=7333509 mis=1044457 bad_tx=264 shift=0 rep=0 |
| C3TX | req_hz=12000000 prof=1 pass=0 tx=0 mis=3983 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=1 pass=0 tx=1 mis=3981 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=1 pass=0 tx=2 mis=3987 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=1 pass=0 tx=3 mis=3988 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=1 pass=0 tx=4 mis=3990 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=1 pass=0 tx=5 mis=3983 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=1 pass=0 tx=6 mis=3987 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=1 pass=0 tx=7 mis=3983 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=1 pass=0 tx=8 mis=3986 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=1 pass=0 tx=9 mis=3988 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=1 pass=0 tx=10 mis=3987 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=1 pass=0 tx=11 mis=3982 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=1 pass=0 tx=12 mis=3986 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=1 pass=0 tx=13 mis=3987 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=1 pass=0 tx=14 mis=3984 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=1 pass=0 tx=15 mis=3985 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=1 pass=1 tx=0 mis=3982 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=1 pass=1 tx=1 mis=3986 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=1 pass=1 tx=2 mis=3982 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=1 pass=1 tx=3 mis=3988 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=1 pass=1 tx=4 mis=3980 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=1 pass=1 tx=5 mis=3987 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=1 pass=1 tx=6 mis=3983 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=1 pass=1 tx=7 mis=3983 first=1 shift=0 |
| C3TX | req_hz=12000000 prof=1 pass=1 tx=8 mis=3984 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=1 pass=1 tx=9 mis=3984 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=1 pass=1 tx=10 mis=3987 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=1 pass=1 tx=11 mis=3982 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=1 pass=1 tx=12 mis=3986 first=1 shift=0 |
| C3TX | req_hz=12000000 prof=1 pass=1 tx=13 mis=3988 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=1 pass=1 tx=14 mis=3982 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=1 pass=1 tx=15 mis=3987 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=1 pass=2 tx=0 mis=3986 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=1 pass=2 tx=1 mis=3978 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=1 pass=2 tx=2 mis=3986 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=1 pass=2 tx=3 mis=3986 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=1 pass=2 tx=4 mis=3988 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=1 pass=2 tx=5 mis=3986 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=1 pass=2 tx=6 mis=3988 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=1 pass=2 tx=7 mis=3987 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=1 pass=2 tx=8 mis=3988 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=1 pass=2 tx=9 mis=3988 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=1 pass=2 tx=10 mis=3981 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=1 pass=2 tx=11 mis=3973 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=1 pass=2 tx=12 mis=3983 first=1 shift=0 |
| C3TX | req_hz=12000000 prof=1 pass=2 tx=13 mis=3984 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=1 pass=2 tx=14 mis=3984 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=1 pass=2 tx=15 mis=3982 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=1 pass=3 tx=0 mis=3986 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=1 pass=3 tx=1 mis=3987 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=1 pass=3 tx=2 mis=3979 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=1 pass=3 tx=3 mis=3987 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=1 pass=3 tx=4 mis=3988 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=1 pass=3 tx=5 mis=3980 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=1 pass=3 tx=6 mis=3984 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=1 pass=3 tx=7 mis=3983 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=1 pass=3 tx=8 mis=3992 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=1 pass=3 tx=9 mis=3985 first=1 shift=0 |
| C3TX | req_hz=12000000 prof=1 pass=3 tx=10 mis=3988 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=1 pass=3 tx=11 mis=3982 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=1 pass=3 tx=12 mis=3983 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=1 pass=3 tx=13 mis=3977 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=1 pass=3 tx=14 mis=3986 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=1 pass=3 tx=15 mis=3988 first=0 shift=0 |
| P3SC | prof=1 ceiling_hz=11000000 |
| P3SV | prof=2 hz=11000000 bytes=1048576 ns=1357488000 mis=0 bad_tx=0 first_tx=-1 shift=0 |
| P3SV | prof=2 hz=4000000 bytes=1048576 ns=3437939000 mis=0 bad_tx=0 first_tx=-1 shift=0 |
| P3SV | prof=2 hz=2000000 bytes=1048576 ns=6795855000 mis=0 bad_tx=0 first_tx=-1 shift=0 |
| P3SR | prof=2 req_hz=2000000 eff_hz=1248334 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=2 req_hz=2000000 eff_hz=1248334 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=2 req_hz=2000000 eff_hz=1248334 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=2 req_hz=2500000 eff_hz=1555841 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=2 req_hz=2500000 eff_hz=1555841 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=2 req_hz=2500000 eff_hz=1555841 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=2 req_hz=3000000 eff_hz=1853101 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=2 req_hz=3000000 eff_hz=1853101 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=2 req_hz=3000000 eff_hz=1853101 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=2 req_hz=3500000 eff_hz=2135783 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=2 req_hz=3500000 eff_hz=2135783 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=2 req_hz=3500000 eff_hz=2135783 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=2 req_hz=4000000 eff_hz=2497002 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=2 req_hz=4000000 eff_hz=2497002 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=2 req_hz=4000000 eff_hz=2497002 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=2 req_hz=4500000 eff_hz=2767979 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=2 req_hz=4500000 eff_hz=2767979 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=2 req_hz=4500000 eff_hz=2767979 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=2 req_hz=5000000 eff_hz=3113938 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=2 req_hz=5000000 eff_hz=3113938 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=2 req_hz=5000000 eff_hz=3113938 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=2 req_hz=5500000 eff_hz=3367202 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=2 req_hz=5500000 eff_hz=3367202 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=2 req_hz=5500000 eff_hz=3367202 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=2 req_hz=6000000 eff_hz=3644723 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=2 req_hz=6000000 eff_hz=3644723 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=2 req_hz=6000000 eff_hz=3644723 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=2 req_hz=6500000 eff_hz=4017855 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=2 req_hz=6500000 eff_hz=4017855 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=2 req_hz=6500000 eff_hz=4017855 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=2 req_hz=7000000 eff_hz=4266667 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=2 req_hz=7000000 eff_hz=4266667 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=2 req_hz=7000000 eff_hz=4266667 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=2 req_hz=7500000 eff_hz=4609184 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=2 req_hz=7500000 eff_hz=4609184 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=2 req_hz=7500000 eff_hz=4609184 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=2 req_hz=8000000 eff_hz=4970431 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=2 req_hz=8000000 eff_hz=4970431 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=2 req_hz=8000000 eff_hz=4970431 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=2 req_hz=8500000 eff_hz=5181801 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=2 req_hz=8500000 eff_hz=5181801 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=2 req_hz=8500000 eff_hz=5181801 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=2 req_hz=9000000 eff_hz=5403563 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=2 req_hz=9000000 eff_hz=5403563 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=2 req_hz=9000000 eff_hz=5403563 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=2 req_hz=9500000 eff_hz=5604338 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=2 req_hz=9500000 eff_hz=5604338 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=2 req_hz=9500000 eff_hz=5604338 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=2 req_hz=10000000 eff_hz=6195382 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=2 req_hz=10000000 eff_hz=6195382 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=2 req_hz=10000000 eff_hz=6195382 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=2 req_hz=11000000 eff_hz=6445830 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=2 req_hz=11000000 eff_hz=6445830 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=2 req_hz=11000000 eff_hz=6445830 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=2 req_hz=11500000 eff_hz=6972514 mis=1044144 bad_tx=264 shift=0 rep=0 |
| C3TX | req_hz=11500000 prof=2 pass=0 tx=0 mis=3986 first=3 shift=0 |
| C3TX | req_hz=11500000 prof=2 pass=0 tx=1 mis=3984 first=3 shift=0 |
| C3TX | req_hz=11500000 prof=2 pass=0 tx=2 mis=3986 first=1 shift=0 |
| C3TX | req_hz=11500000 prof=2 pass=0 tx=3 mis=3981 first=0 shift=0 |
| C3TX | req_hz=11500000 prof=2 pass=0 tx=4 mis=3979 first=0 shift=0 |
| C3TX | req_hz=11500000 prof=2 pass=0 tx=5 mis=3979 first=0 shift=0 |
| C3TX | req_hz=11500000 prof=2 pass=0 tx=6 mis=3985 first=0 shift=0 |
| C3TX | req_hz=11500000 prof=2 pass=0 tx=7 mis=3981 first=1 shift=0 |
| C3TX | req_hz=11500000 prof=2 pass=0 tx=8 mis=3977 first=3 shift=0 |
| C3TX | req_hz=11500000 prof=2 pass=0 tx=9 mis=3984 first=1 shift=0 |
| C3TX | req_hz=11500000 prof=2 pass=0 tx=10 mis=3985 first=1 shift=0 |
| C3TX | req_hz=11500000 prof=2 pass=0 tx=11 mis=3984 first=1 shift=0 |
| C3TX | req_hz=11500000 prof=2 pass=0 tx=12 mis=3985 first=0 shift=0 |
| C3TX | req_hz=11500000 prof=2 pass=0 tx=13 mis=3975 first=3 shift=0 |
| C3TX | req_hz=11500000 prof=2 pass=0 tx=14 mis=3985 first=0 shift=0 |
| C3TX | req_hz=11500000 prof=2 pass=0 tx=15 mis=3986 first=3 shift=0 |
| C3TX | req_hz=11500000 prof=2 pass=1 tx=0 mis=3980 first=3 shift=0 |
| C3TX | req_hz=11500000 prof=2 pass=1 tx=1 mis=3981 first=2 shift=0 |
| C3TX | req_hz=11500000 prof=2 pass=1 tx=2 mis=3976 first=2 shift=0 |
| C3TX | req_hz=11500000 prof=2 pass=1 tx=3 mis=3985 first=2 shift=0 |
| C3TX | req_hz=11500000 prof=2 pass=1 tx=4 mis=3983 first=1 shift=0 |
| C3TX | req_hz=11500000 prof=2 pass=1 tx=5 mis=3976 first=2 shift=0 |
| C3TX | req_hz=11500000 prof=2 pass=1 tx=6 mis=3983 first=0 shift=0 |
| C3TX | req_hz=11500000 prof=2 pass=1 tx=7 mis=3981 first=1 shift=0 |
| C3TX | req_hz=11500000 prof=2 pass=1 tx=8 mis=3981 first=2 shift=0 |
| C3TX | req_hz=11500000 prof=2 pass=1 tx=9 mis=3981 first=3 shift=0 |
| C3TX | req_hz=11500000 prof=2 pass=1 tx=10 mis=3982 first=1 shift=0 |
| C3TX | req_hz=11500000 prof=2 pass=1 tx=11 mis=3977 first=2 shift=0 |
| C3TX | req_hz=11500000 prof=2 pass=1 tx=12 mis=3987 first=1 shift=0 |
| C3TX | req_hz=11500000 prof=2 pass=1 tx=13 mis=3979 first=4 shift=0 |
| C3TX | req_hz=11500000 prof=2 pass=1 tx=14 mis=3975 first=3 shift=0 |
| C3TX | req_hz=11500000 prof=2 pass=1 tx=15 mis=3985 first=3 shift=0 |
| C3TX | req_hz=11500000 prof=2 pass=2 tx=0 mis=3987 first=3 shift=0 |
| C3TX | req_hz=11500000 prof=2 pass=2 tx=1 mis=3988 first=1 shift=0 |
| C3TX | req_hz=11500000 prof=2 pass=2 tx=2 mis=3981 first=2 shift=0 |
| C3TX | req_hz=11500000 prof=2 pass=2 tx=3 mis=3989 first=0 shift=0 |
| C3TX | req_hz=11500000 prof=2 pass=2 tx=4 mis=3978 first=3 shift=0 |
| C3TX | req_hz=11500000 prof=2 pass=2 tx=5 mis=3988 first=0 shift=0 |
| C3TX | req_hz=11500000 prof=2 pass=2 tx=6 mis=3989 first=0 shift=0 |
| C3TX | req_hz=11500000 prof=2 pass=2 tx=7 mis=3987 first=1 shift=0 |
| C3TX | req_hz=11500000 prof=2 pass=2 tx=8 mis=3984 first=1 shift=0 |
| C3TX | req_hz=11500000 prof=2 pass=2 tx=9 mis=3987 first=2 shift=0 |
| C3TX | req_hz=11500000 prof=2 pass=2 tx=10 mis=3985 first=3 shift=0 |
| C3TX | req_hz=11500000 prof=2 pass=2 tx=11 mis=3985 first=2 shift=0 |
| C3TX | req_hz=11500000 prof=2 pass=2 tx=12 mis=3974 first=4 shift=0 |
| C3TX | req_hz=11500000 prof=2 pass=2 tx=13 mis=3980 first=3 shift=0 |
| C3TX | req_hz=11500000 prof=2 pass=2 tx=14 mis=3984 first=3 shift=0 |
| C3TX | req_hz=11500000 prof=2 pass=2 tx=15 mis=3975 first=3 shift=0 |
| C3TX | req_hz=11500000 prof=2 pass=3 tx=0 mis=3978 first=0 shift=0 |
| C3TX | req_hz=11500000 prof=2 pass=3 tx=1 mis=3983 first=1 shift=0 |
| C3TX | req_hz=11500000 prof=2 pass=3 tx=2 mis=3990 first=1 shift=0 |
| C3TX | req_hz=11500000 prof=2 pass=3 tx=3 mis=3977 first=3 shift=0 |
| C3TX | req_hz=11500000 prof=2 pass=3 tx=4 mis=3980 first=2 shift=0 |
| C3TX | req_hz=11500000 prof=2 pass=3 tx=5 mis=3980 first=1 shift=0 |
| C3TX | req_hz=11500000 prof=2 pass=3 tx=6 mis=3987 first=3 shift=0 |
| C3TX | req_hz=11500000 prof=2 pass=3 tx=7 mis=3984 first=0 shift=0 |
| C3TX | req_hz=11500000 prof=2 pass=3 tx=8 mis=3989 first=2 shift=0 |
| C3TX | req_hz=11500000 prof=2 pass=3 tx=9 mis=3985 first=2 shift=0 |
| C3TX | req_hz=11500000 prof=2 pass=3 tx=10 mis=3991 first=1 shift=0 |
| C3TX | req_hz=11500000 prof=2 pass=3 tx=11 mis=3987 first=3 shift=0 |
| C3TX | req_hz=11500000 prof=2 pass=3 tx=12 mis=3980 first=3 shift=0 |
| C3TX | req_hz=11500000 prof=2 pass=3 tx=13 mis=3978 first=1 shift=0 |
| C3TX | req_hz=11500000 prof=2 pass=3 tx=14 mis=3980 first=2 shift=0 |
| C3TX | req_hz=11500000 prof=2 pass=3 tx=15 mis=3986 first=2 shift=0 |
| P3SR | prof=2 req_hz=12000000 eff_hz=7333509 mis=1044527 bad_tx=264 shift=0 rep=0 |
| C3TX | req_hz=12000000 prof=2 pass=0 tx=0 mis=3985 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=2 pass=0 tx=1 mis=3989 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=2 pass=0 tx=2 mis=3985 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=2 pass=0 tx=3 mis=3983 first=1 shift=0 |
| C3TX | req_hz=12000000 prof=2 pass=0 tx=4 mis=3987 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=2 pass=0 tx=5 mis=3984 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=2 pass=0 tx=6 mis=3984 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=2 pass=0 tx=7 mis=3980 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=2 pass=0 tx=8 mis=3989 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=2 pass=0 tx=9 mis=3984 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=2 pass=0 tx=10 mis=3988 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=2 pass=0 tx=11 mis=3985 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=2 pass=0 tx=12 mis=3988 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=2 pass=0 tx=13 mis=3988 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=2 pass=0 tx=14 mis=3983 first=1 shift=0 |
| C3TX | req_hz=12000000 prof=2 pass=0 tx=15 mis=3982 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=2 pass=1 tx=0 mis=3979 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=2 pass=1 tx=1 mis=3981 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=2 pass=1 tx=2 mis=3989 first=1 shift=0 |
| C3TX | req_hz=12000000 prof=2 pass=1 tx=3 mis=3980 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=2 pass=1 tx=4 mis=3985 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=2 pass=1 tx=5 mis=3986 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=2 pass=1 tx=6 mis=3976 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=2 pass=1 tx=7 mis=3987 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=2 pass=1 tx=8 mis=3988 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=2 pass=1 tx=9 mis=3990 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=2 pass=1 tx=10 mis=3985 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=2 pass=1 tx=11 mis=3983 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=2 pass=1 tx=12 mis=3983 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=2 pass=1 tx=13 mis=3977 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=2 pass=1 tx=14 mis=3984 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=2 pass=1 tx=15 mis=3989 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=2 pass=2 tx=0 mis=3977 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=2 pass=2 tx=1 mis=3982 first=1 shift=0 |
| C3TX | req_hz=12000000 prof=2 pass=2 tx=2 mis=3980 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=2 pass=2 tx=3 mis=3986 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=2 pass=2 tx=4 mis=3984 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=2 pass=2 tx=5 mis=3985 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=2 pass=2 tx=6 mis=3983 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=2 pass=2 tx=7 mis=3982 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=2 pass=2 tx=8 mis=3984 first=1 shift=0 |
| C3TX | req_hz=12000000 prof=2 pass=2 tx=9 mis=3987 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=2 pass=2 tx=10 mis=3991 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=2 pass=2 tx=11 mis=3988 first=1 shift=0 |
| C3TX | req_hz=12000000 prof=2 pass=2 tx=12 mis=3980 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=2 pass=2 tx=13 mis=3984 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=2 pass=2 tx=14 mis=3978 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=2 pass=2 tx=15 mis=3984 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=2 pass=3 tx=0 mis=3981 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=2 pass=3 tx=1 mis=3984 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=2 pass=3 tx=2 mis=3979 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=2 pass=3 tx=3 mis=3983 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=2 pass=3 tx=4 mis=3989 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=2 pass=3 tx=5 mis=3981 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=2 pass=3 tx=6 mis=3981 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=2 pass=3 tx=7 mis=3993 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=2 pass=3 tx=8 mis=3979 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=2 pass=3 tx=9 mis=3979 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=2 pass=3 tx=10 mis=3987 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=2 pass=3 tx=11 mis=3983 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=2 pass=3 tx=12 mis=3985 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=2 pass=3 tx=13 mis=3984 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=2 pass=3 tx=14 mis=3986 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=2 pass=3 tx=15 mis=3985 first=0 shift=0 |
| P3SC | prof=2 ceiling_hz=11000000 |
| P3SV | prof=3 hz=11000000 bytes=1048576 ns=1348313000 mis=0 bad_tx=0 first_tx=-1 shift=0 |
| P3SV | prof=3 hz=4000000 bytes=1048576 ns=3437249000 mis=0 bad_tx=0 first_tx=-1 shift=0 |
| P3SV | prof=3 hz=2000000 bytes=1048576 ns=6796226000 mis=0 bad_tx=0 first_tx=-1 shift=0 |
| P3SR | prof=3 req_hz=2000000 eff_hz=1248334 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=3 req_hz=2000000 eff_hz=1248334 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=3 req_hz=2000000 eff_hz=1248334 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=3 req_hz=2500000 eff_hz=1555841 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=3 req_hz=2500000 eff_hz=1555841 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=3 req_hz=2500000 eff_hz=1555841 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=3 req_hz=3000000 eff_hz=1853101 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=3 req_hz=3000000 eff_hz=1853101 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=3 req_hz=3000000 eff_hz=1853101 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=3 req_hz=3500000 eff_hz=2135783 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=3 req_hz=3500000 eff_hz=2135783 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=3 req_hz=3500000 eff_hz=2135783 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=3 req_hz=4000000 eff_hz=2497002 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=3 req_hz=4000000 eff_hz=2497002 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=3 req_hz=4000000 eff_hz=2497002 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=3 req_hz=4500000 eff_hz=2767979 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=3 req_hz=4500000 eff_hz=2767979 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=3 req_hz=4500000 eff_hz=2767979 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=3 req_hz=5000000 eff_hz=3113938 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=3 req_hz=5000000 eff_hz=3113938 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=3 req_hz=5000000 eff_hz=3113938 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=3 req_hz=5500000 eff_hz=3367202 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=3 req_hz=5500000 eff_hz=3367202 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=3 req_hz=5500000 eff_hz=3367202 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=3 req_hz=6000000 eff_hz=3644723 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=3 req_hz=6000000 eff_hz=3644723 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=3 req_hz=6000000 eff_hz=3644723 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=3 req_hz=6500000 eff_hz=4017855 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=3 req_hz=6500000 eff_hz=4017855 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=3 req_hz=6500000 eff_hz=4017855 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=3 req_hz=7000000 eff_hz=4266667 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=3 req_hz=7000000 eff_hz=4266667 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=3 req_hz=7000000 eff_hz=4266667 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=3 req_hz=7500000 eff_hz=4609184 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=3 req_hz=7500000 eff_hz=4609184 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=3 req_hz=7500000 eff_hz=4609184 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=3 req_hz=8000000 eff_hz=4970431 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=3 req_hz=8000000 eff_hz=4970431 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=3 req_hz=8000000 eff_hz=4970431 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=3 req_hz=8500000 eff_hz=5181801 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=3 req_hz=8500000 eff_hz=5181801 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=3 req_hz=8500000 eff_hz=5181801 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=3 req_hz=9000000 eff_hz=5403563 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=3 req_hz=9000000 eff_hz=5403563 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=3 req_hz=9000000 eff_hz=5403563 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=3 req_hz=9500000 eff_hz=5604338 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=3 req_hz=9500000 eff_hz=5604338 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=3 req_hz=9500000 eff_hz=5604338 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=3 req_hz=10000000 eff_hz=6195382 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=3 req_hz=10000000 eff_hz=6195382 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=3 req_hz=10000000 eff_hz=6195382 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=3 req_hz=11000000 eff_hz=6445830 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=3 req_hz=11000000 eff_hz=6445830 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=3 req_hz=11000000 eff_hz=6445830 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=3 req_hz=11500000 eff_hz=6972514 mis=1044080 bad_tx=264 shift=0 rep=0 |
| C3TX | req_hz=11500000 prof=3 pass=0 tx=0 mis=3990 first=0 shift=0 |
| C3TX | req_hz=11500000 prof=3 pass=0 tx=1 mis=3986 first=2 shift=0 |
| C3TX | req_hz=11500000 prof=3 pass=0 tx=2 mis=3987 first=2 shift=0 |
| C3TX | req_hz=11500000 prof=3 pass=0 tx=3 mis=3989 first=1 shift=0 |
| C3TX | req_hz=11500000 prof=3 pass=0 tx=4 mis=3983 first=1 shift=0 |
| C3TX | req_hz=11500000 prof=3 pass=0 tx=5 mis=3985 first=4 shift=0 |
| C3TX | req_hz=11500000 prof=3 pass=0 tx=6 mis=3982 first=2 shift=0 |
| C3TX | req_hz=11500000 prof=3 pass=0 tx=7 mis=3972 first=1 shift=0 |
| C3TX | req_hz=11500000 prof=3 pass=0 tx=8 mis=3989 first=1 shift=0 |
| C3TX | req_hz=11500000 prof=3 pass=0 tx=9 mis=3983 first=1 shift=0 |
| C3TX | req_hz=11500000 prof=3 pass=0 tx=10 mis=3989 first=1 shift=0 |
| C3TX | req_hz=11500000 prof=3 pass=0 tx=11 mis=3984 first=0 shift=0 |
| C3TX | req_hz=11500000 prof=3 pass=0 tx=12 mis=3980 first=1 shift=0 |
| C3TX | req_hz=11500000 prof=3 pass=0 tx=13 mis=3985 first=1 shift=0 |
| C3TX | req_hz=11500000 prof=3 pass=0 tx=14 mis=3980 first=3 shift=0 |
| C3TX | req_hz=11500000 prof=3 pass=0 tx=15 mis=3980 first=2 shift=0 |
| C3TX | req_hz=11500000 prof=3 pass=1 tx=0 mis=3978 first=1 shift=0 |
| C3TX | req_hz=11500000 prof=3 pass=1 tx=1 mis=3989 first=1 shift=0 |
| C3TX | req_hz=11500000 prof=3 pass=1 tx=2 mis=3987 first=1 shift=0 |
| C3TX | req_hz=11500000 prof=3 pass=1 tx=3 mis=3985 first=2 shift=0 |
| C3TX | req_hz=11500000 prof=3 pass=1 tx=4 mis=3987 first=2 shift=0 |
| C3TX | req_hz=11500000 prof=3 pass=1 tx=5 mis=3989 first=1 shift=0 |
| C3TX | req_hz=11500000 prof=3 pass=1 tx=6 mis=3982 first=1 shift=0 |
| C3TX | req_hz=11500000 prof=3 pass=1 tx=7 mis=3983 first=1 shift=0 |
| C3TX | req_hz=11500000 prof=3 pass=1 tx=8 mis=3982 first=3 shift=0 |
| C3TX | req_hz=11500000 prof=3 pass=1 tx=9 mis=3989 first=3 shift=0 |
| C3TX | req_hz=11500000 prof=3 pass=1 tx=10 mis=3990 first=0 shift=0 |
| C3TX | req_hz=11500000 prof=3 pass=1 tx=11 mis=3978 first=3 shift=0 |
| C3TX | req_hz=11500000 prof=3 pass=1 tx=12 mis=3986 first=0 shift=0 |
| C3TX | req_hz=11500000 prof=3 pass=1 tx=13 mis=3984 first=3 shift=0 |
| C3TX | req_hz=11500000 prof=3 pass=1 tx=14 mis=3986 first=0 shift=0 |
| C3TX | req_hz=11500000 prof=3 pass=1 tx=15 mis=3985 first=2 shift=0 |
| C3TX | req_hz=11500000 prof=3 pass=2 tx=0 mis=3979 first=3 shift=0 |
| C3TX | req_hz=11500000 prof=3 pass=2 tx=1 mis=3989 first=2 shift=0 |
| C3TX | req_hz=11500000 prof=3 pass=2 tx=2 mis=3979 first=1 shift=0 |
| C3TX | req_hz=11500000 prof=3 pass=2 tx=3 mis=3980 first=2 shift=0 |
| C3TX | req_hz=11500000 prof=3 pass=2 tx=4 mis=3986 first=1 shift=0 |
| C3TX | req_hz=11500000 prof=3 pass=2 tx=5 mis=3985 first=1 shift=0 |
| C3TX | req_hz=11500000 prof=3 pass=2 tx=6 mis=3985 first=2 shift=0 |
| C3TX | req_hz=11500000 prof=3 pass=2 tx=7 mis=3984 first=2 shift=0 |
| C3TX | req_hz=11500000 prof=3 pass=2 tx=8 mis=3979 first=3 shift=0 |
| C3TX | req_hz=11500000 prof=3 pass=2 tx=9 mis=3988 first=2 shift=0 |
| C3TX | req_hz=11500000 prof=3 pass=2 tx=10 mis=3990 first=0 shift=0 |
| C3TX | req_hz=11500000 prof=3 pass=2 tx=11 mis=3981 first=2 shift=0 |
| C3TX | req_hz=11500000 prof=3 pass=2 tx=12 mis=3975 first=3 shift=0 |
| C3TX | req_hz=11500000 prof=3 pass=2 tx=13 mis=3981 first=3 shift=0 |
| C3TX | req_hz=11500000 prof=3 pass=2 tx=14 mis=3982 first=3 shift=0 |
| C3TX | req_hz=11500000 prof=3 pass=2 tx=15 mis=3980 first=3 shift=0 |
| C3TX | req_hz=11500000 prof=3 pass=3 tx=0 mis=3987 first=1 shift=0 |
| C3TX | req_hz=11500000 prof=3 pass=3 tx=1 mis=3975 first=3 shift=0 |
| C3TX | req_hz=11500000 prof=3 pass=3 tx=2 mis=3977 first=4 shift=0 |
| C3TX | req_hz=11500000 prof=3 pass=3 tx=3 mis=3985 first=2 shift=0 |
| C3TX | req_hz=11500000 prof=3 pass=3 tx=4 mis=3992 first=2 shift=0 |
| C3TX | req_hz=11500000 prof=3 pass=3 tx=5 mis=3982 first=4 shift=0 |
| C3TX | req_hz=11500000 prof=3 pass=3 tx=6 mis=3990 first=0 shift=0 |
| C3TX | req_hz=11500000 prof=3 pass=3 tx=7 mis=3980 first=3 shift=0 |
| C3TX | req_hz=11500000 prof=3 pass=3 tx=8 mis=3982 first=2 shift=0 |
| C3TX | req_hz=11500000 prof=3 pass=3 tx=9 mis=3977 first=2 shift=0 |
| C3TX | req_hz=11500000 prof=3 pass=3 tx=10 mis=3986 first=2 shift=0 |
| C3TX | req_hz=11500000 prof=3 pass=3 tx=11 mis=3978 first=3 shift=0 |
| C3TX | req_hz=11500000 prof=3 pass=3 tx=12 mis=3981 first=1 shift=0 |
| C3TX | req_hz=11500000 prof=3 pass=3 tx=13 mis=3983 first=0 shift=0 |
| C3TX | req_hz=11500000 prof=3 pass=3 tx=14 mis=3981 first=1 shift=0 |
| C3TX | req_hz=11500000 prof=3 pass=3 tx=15 mis=3985 first=2 shift=0 |
| P3SR | prof=3 req_hz=12000000 eff_hz=7333509 mis=1044547 bad_tx=264 shift=0 rep=0 |
| C3TX | req_hz=12000000 prof=3 pass=0 tx=0 mis=3985 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=3 pass=0 tx=1 mis=3981 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=3 pass=0 tx=2 mis=3984 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=3 pass=0 tx=3 mis=3992 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=3 pass=0 tx=4 mis=3987 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=3 pass=0 tx=5 mis=3985 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=3 pass=0 tx=6 mis=3980 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=3 pass=0 tx=7 mis=3989 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=3 pass=0 tx=8 mis=3984 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=3 pass=0 tx=9 mis=3987 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=3 pass=0 tx=10 mis=3983 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=3 pass=0 tx=11 mis=3979 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=3 pass=0 tx=12 mis=3984 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=3 pass=0 tx=13 mis=3986 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=3 pass=0 tx=14 mis=3984 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=3 pass=0 tx=15 mis=3986 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=3 pass=1 tx=0 mis=3988 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=3 pass=1 tx=1 mis=3983 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=3 pass=1 tx=2 mis=3985 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=3 pass=1 tx=3 mis=3987 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=3 pass=1 tx=4 mis=3986 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=3 pass=1 tx=5 mis=3986 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=3 pass=1 tx=6 mis=3985 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=3 pass=1 tx=7 mis=3985 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=3 pass=1 tx=8 mis=3989 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=3 pass=1 tx=9 mis=3976 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=3 pass=1 tx=10 mis=3985 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=3 pass=1 tx=11 mis=3983 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=3 pass=1 tx=12 mis=3992 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=3 pass=1 tx=13 mis=3984 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=3 pass=1 tx=14 mis=3984 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=3 pass=1 tx=15 mis=3980 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=3 pass=2 tx=0 mis=3988 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=3 pass=2 tx=1 mis=3985 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=3 pass=2 tx=2 mis=3989 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=3 pass=2 tx=3 mis=3984 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=3 pass=2 tx=4 mis=3984 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=3 pass=2 tx=5 mis=3984 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=3 pass=2 tx=6 mis=3981 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=3 pass=2 tx=7 mis=3988 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=3 pass=2 tx=8 mis=3982 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=3 pass=2 tx=9 mis=3983 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=3 pass=2 tx=10 mis=3981 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=3 pass=2 tx=11 mis=3985 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=3 pass=2 tx=12 mis=3984 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=3 pass=2 tx=13 mis=3988 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=3 pass=2 tx=14 mis=3987 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=3 pass=2 tx=15 mis=3984 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=3 pass=3 tx=0 mis=3980 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=3 pass=3 tx=1 mis=3982 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=3 pass=3 tx=2 mis=3982 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=3 pass=3 tx=3 mis=3984 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=3 pass=3 tx=4 mis=3985 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=3 pass=3 tx=5 mis=3984 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=3 pass=3 tx=6 mis=3985 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=3 pass=3 tx=7 mis=3980 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=3 pass=3 tx=8 mis=3974 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=3 pass=3 tx=9 mis=3982 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=3 pass=3 tx=10 mis=3987 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=3 pass=3 tx=11 mis=3987 first=1 shift=0 |
| C3TX | req_hz=12000000 prof=3 pass=3 tx=12 mis=3985 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=3 pass=3 tx=13 mis=3986 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=3 pass=3 tx=14 mis=3983 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=3 pass=3 tx=15 mis=3986 first=0 shift=0 |
| P3SC | prof=3 ceiling_hz=11000000 |
| P3SV | prof=4 hz=11000000 bytes=1048576 ns=1357504000 mis=0 bad_tx=0 first_tx=-1 shift=0 |
| P3SV | prof=4 hz=4000000 bytes=1048576 ns=3438019000 mis=0 bad_tx=0 first_tx=-1 shift=0 |
| P3SV | prof=4 hz=2000000 bytes=1048576 ns=6796065000 mis=0 bad_tx=0 first_tx=-1 shift=0 |
| P3SR | prof=4 req_hz=2000000 eff_hz=1248334 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=4 req_hz=2000000 eff_hz=1248334 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=4 req_hz=2000000 eff_hz=1248334 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=4 req_hz=2500000 eff_hz=1555841 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=4 req_hz=2500000 eff_hz=1555841 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=4 req_hz=2500000 eff_hz=1555841 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=4 req_hz=3000000 eff_hz=1853101 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=4 req_hz=3000000 eff_hz=1853101 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=4 req_hz=3000000 eff_hz=1853101 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=4 req_hz=3500000 eff_hz=2135783 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=4 req_hz=3500000 eff_hz=2135783 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=4 req_hz=3500000 eff_hz=2135783 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=4 req_hz=4000000 eff_hz=2497002 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=4 req_hz=4000000 eff_hz=2497002 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=4 req_hz=4000000 eff_hz=2497002 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=4 req_hz=4500000 eff_hz=2767979 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=4 req_hz=4500000 eff_hz=2767979 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=4 req_hz=4500000 eff_hz=2767979 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=4 req_hz=5000000 eff_hz=3113938 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=4 req_hz=5000000 eff_hz=3113938 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=4 req_hz=5000000 eff_hz=3113938 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=4 req_hz=5500000 eff_hz=3367202 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=4 req_hz=5500000 eff_hz=3367202 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=4 req_hz=5500000 eff_hz=3367202 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=4 req_hz=6000000 eff_hz=3644723 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=4 req_hz=6000000 eff_hz=3644723 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=4 req_hz=6000000 eff_hz=3644723 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=4 req_hz=6500000 eff_hz=4017855 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=4 req_hz=6500000 eff_hz=4017855 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=4 req_hz=6500000 eff_hz=4017855 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=4 req_hz=7000000 eff_hz=4266667 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=4 req_hz=7000000 eff_hz=4266667 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=4 req_hz=7000000 eff_hz=4266667 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=4 req_hz=7500000 eff_hz=4609184 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=4 req_hz=7500000 eff_hz=4609184 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=4 req_hz=7500000 eff_hz=4609184 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=4 req_hz=8000000 eff_hz=4970431 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=4 req_hz=8000000 eff_hz=4970431 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=4 req_hz=8000000 eff_hz=4970431 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=4 req_hz=8500000 eff_hz=5181801 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=4 req_hz=8500000 eff_hz=5181801 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=4 req_hz=8500000 eff_hz=5181801 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=4 req_hz=9000000 eff_hz=5403563 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=4 req_hz=9000000 eff_hz=5403563 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=4 req_hz=9000000 eff_hz=5403563 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=4 req_hz=9500000 eff_hz=5604338 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=4 req_hz=9500000 eff_hz=5604338 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=4 req_hz=9500000 eff_hz=5604338 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=4 req_hz=10000000 eff_hz=6195382 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=4 req_hz=10000000 eff_hz=6195382 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=4 req_hz=10000000 eff_hz=6195382 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=4 req_hz=11000000 eff_hz=6445830 mis=0 bad_tx=0 shift=0 rep=0 |
| P3SR | prof=4 req_hz=11000000 eff_hz=6445830 mis=0 bad_tx=0 shift=0 rep=1 |
| P3SR | prof=4 req_hz=11000000 eff_hz=6445830 mis=0 bad_tx=0 shift=0 rep=2 |
| P3SR | prof=4 req_hz=11500000 eff_hz=6972514 mis=1044082 bad_tx=264 shift=0 rep=0 |
| C3TX | req_hz=11500000 prof=4 pass=0 tx=0 mis=3989 first=0 shift=0 |
| C3TX | req_hz=11500000 prof=4 pass=0 tx=1 mis=3980 first=1 shift=0 |
| C3TX | req_hz=11500000 prof=4 pass=0 tx=2 mis=3981 first=2 shift=0 |
| C3TX | req_hz=11500000 prof=4 pass=0 tx=3 mis=3979 first=3 shift=0 |
| C3TX | req_hz=11500000 prof=4 pass=0 tx=4 mis=3980 first=3 shift=0 |
| C3TX | req_hz=11500000 prof=4 pass=0 tx=5 mis=3983 first=2 shift=0 |
| C3TX | req_hz=11500000 prof=4 pass=0 tx=6 mis=3980 first=3 shift=0 |
| C3TX | req_hz=11500000 prof=4 pass=0 tx=7 mis=3983 first=1 shift=0 |
| C3TX | req_hz=11500000 prof=4 pass=0 tx=8 mis=3988 first=1 shift=0 |
| C3TX | req_hz=11500000 prof=4 pass=0 tx=9 mis=3977 first=4 shift=0 |
| C3TX | req_hz=11500000 prof=4 pass=0 tx=10 mis=3972 first=3 shift=0 |
| C3TX | req_hz=11500000 prof=4 pass=0 tx=11 mis=3984 first=0 shift=0 |
| C3TX | req_hz=11500000 prof=4 pass=0 tx=12 mis=3985 first=3 shift=0 |
| C3TX | req_hz=11500000 prof=4 pass=0 tx=13 mis=3987 first=0 shift=0 |
| C3TX | req_hz=11500000 prof=4 pass=0 tx=14 mis=3982 first=1 shift=0 |
| C3TX | req_hz=11500000 prof=4 pass=0 tx=15 mis=3988 first=0 shift=0 |
| C3TX | req_hz=11500000 prof=4 pass=1 tx=0 mis=3977 first=3 shift=0 |
| C3TX | req_hz=11500000 prof=4 pass=1 tx=1 mis=3982 first=4 shift=0 |
| C3TX | req_hz=11500000 prof=4 pass=1 tx=2 mis=3988 first=0 shift=0 |
| C3TX | req_hz=11500000 prof=4 pass=1 tx=3 mis=3982 first=2 shift=0 |
| C3TX | req_hz=11500000 prof=4 pass=1 tx=4 mis=3982 first=3 shift=0 |
| C3TX | req_hz=11500000 prof=4 pass=1 tx=5 mis=3983 first=3 shift=0 |
| C3TX | req_hz=11500000 prof=4 pass=1 tx=6 mis=3981 first=3 shift=0 |
| C3TX | req_hz=11500000 prof=4 pass=1 tx=7 mis=3980 first=2 shift=0 |
| C3TX | req_hz=11500000 prof=4 pass=1 tx=8 mis=3981 first=1 shift=0 |
| C3TX | req_hz=11500000 prof=4 pass=1 tx=9 mis=3983 first=0 shift=0 |
| C3TX | req_hz=11500000 prof=4 pass=1 tx=10 mis=3985 first=2 shift=0 |
| C3TX | req_hz=11500000 prof=4 pass=1 tx=11 mis=3988 first=2 shift=0 |
| C3TX | req_hz=11500000 prof=4 pass=1 tx=12 mis=3979 first=3 shift=0 |
| C3TX | req_hz=11500000 prof=4 pass=1 tx=13 mis=3978 first=2 shift=0 |
| C3TX | req_hz=11500000 prof=4 pass=1 tx=14 mis=3983 first=0 shift=0 |
| C3TX | req_hz=11500000 prof=4 pass=1 tx=15 mis=3984 first=3 shift=0 |
| C3TX | req_hz=11500000 prof=4 pass=2 tx=0 mis=3989 first=2 shift=0 |
| C3TX | req_hz=11500000 prof=4 pass=2 tx=1 mis=3988 first=2 shift=0 |
| C3TX | req_hz=11500000 prof=4 pass=2 tx=2 mis=3981 first=3 shift=0 |
| C3TX | req_hz=11500000 prof=4 pass=2 tx=3 mis=3978 first=2 shift=0 |
| C3TX | req_hz=11500000 prof=4 pass=2 tx=4 mis=3989 first=1 shift=0 |
| C3TX | req_hz=11500000 prof=4 pass=2 tx=5 mis=3995 first=0 shift=0 |
| C3TX | req_hz=11500000 prof=4 pass=2 tx=6 mis=3985 first=2 shift=0 |
| C3TX | req_hz=11500000 prof=4 pass=2 tx=7 mis=3983 first=2 shift=0 |
| C3TX | req_hz=11500000 prof=4 pass=2 tx=8 mis=3983 first=0 shift=0 |
| C3TX | req_hz=11500000 prof=4 pass=2 tx=9 mis=3985 first=2 shift=0 |
| C3TX | req_hz=11500000 prof=4 pass=2 tx=10 mis=3986 first=2 shift=0 |
| C3TX | req_hz=11500000 prof=4 pass=2 tx=11 mis=3981 first=3 shift=0 |
| C3TX | req_hz=11500000 prof=4 pass=2 tx=12 mis=3971 first=3 shift=0 |
| C3TX | req_hz=11500000 prof=4 pass=2 tx=13 mis=3978 first=3 shift=0 |
| C3TX | req_hz=11500000 prof=4 pass=2 tx=14 mis=3980 first=2 shift=0 |
| C3TX | req_hz=11500000 prof=4 pass=2 tx=15 mis=3986 first=1 shift=0 |
| C3TX | req_hz=11500000 prof=4 pass=3 tx=0 mis=3985 first=0 shift=0 |
| C3TX | req_hz=11500000 prof=4 pass=3 tx=1 mis=3983 first=0 shift=0 |
| C3TX | req_hz=11500000 prof=4 pass=3 tx=2 mis=3986 first=3 shift=0 |
| C3TX | req_hz=11500000 prof=4 pass=3 tx=3 mis=3986 first=2 shift=0 |
| C3TX | req_hz=11500000 prof=4 pass=3 tx=4 mis=3973 first=1 shift=0 |
| C3TX | req_hz=11500000 prof=4 pass=3 tx=5 mis=3985 first=1 shift=0 |
| C3TX | req_hz=11500000 prof=4 pass=3 tx=6 mis=3982 first=3 shift=0 |
| C3TX | req_hz=11500000 prof=4 pass=3 tx=7 mis=3975 first=3 shift=0 |
| C3TX | req_hz=11500000 prof=4 pass=3 tx=8 mis=3985 first=1 shift=0 |
| C3TX | req_hz=11500000 prof=4 pass=3 tx=9 mis=3987 first=1 shift=0 |
| C3TX | req_hz=11500000 prof=4 pass=3 tx=10 mis=3978 first=0 shift=0 |
| C3TX | req_hz=11500000 prof=4 pass=3 tx=11 mis=3982 first=0 shift=0 |
| C3TX | req_hz=11500000 prof=4 pass=3 tx=12 mis=3988 first=0 shift=0 |
| C3TX | req_hz=11500000 prof=4 pass=3 tx=13 mis=3983 first=2 shift=0 |
| C3TX | req_hz=11500000 prof=4 pass=3 tx=14 mis=3983 first=2 shift=0 |
| C3TX | req_hz=11500000 prof=4 pass=3 tx=15 mis=3979 first=0 shift=0 |
| P3SR | prof=4 req_hz=12000000 eff_hz=7333509 mis=1044534 bad_tx=264 shift=0 rep=0 |
| C3TX | req_hz=12000000 prof=4 pass=0 tx=0 mis=3980 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=4 pass=0 tx=1 mis=3988 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=4 pass=0 tx=2 mis=3983 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=4 pass=0 tx=3 mis=3987 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=4 pass=0 tx=4 mis=3984 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=4 pass=0 tx=5 mis=3987 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=4 pass=0 tx=6 mis=3985 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=4 pass=0 tx=7 mis=3982 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=4 pass=0 tx=8 mis=3982 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=4 pass=0 tx=9 mis=3987 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=4 pass=0 tx=10 mis=3986 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=4 pass=0 tx=11 mis=3978 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=4 pass=0 tx=12 mis=3982 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=4 pass=0 tx=13 mis=3986 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=4 pass=0 tx=14 mis=3983 first=1 shift=0 |
| C3TX | req_hz=12000000 prof=4 pass=0 tx=15 mis=3989 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=4 pass=1 tx=0 mis=3985 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=4 pass=1 tx=1 mis=3985 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=4 pass=1 tx=2 mis=3983 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=4 pass=1 tx=3 mis=3983 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=4 pass=1 tx=4 mis=3988 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=4 pass=1 tx=5 mis=3989 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=4 pass=1 tx=6 mis=3984 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=4 pass=1 tx=7 mis=3981 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=4 pass=1 tx=8 mis=3981 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=4 pass=1 tx=9 mis=3984 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=4 pass=1 tx=10 mis=3977 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=4 pass=1 tx=11 mis=3978 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=4 pass=1 tx=12 mis=3988 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=4 pass=1 tx=13 mis=3989 first=1 shift=0 |
| C3TX | req_hz=12000000 prof=4 pass=1 tx=14 mis=3989 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=4 pass=1 tx=15 mis=3985 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=4 pass=2 tx=0 mis=3986 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=4 pass=2 tx=1 mis=3980 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=4 pass=2 tx=2 mis=3989 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=4 pass=2 tx=3 mis=3984 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=4 pass=2 tx=4 mis=3978 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=4 pass=2 tx=5 mis=3982 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=4 pass=2 tx=6 mis=3984 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=4 pass=2 tx=7 mis=3991 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=4 pass=2 tx=8 mis=3994 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=4 pass=2 tx=9 mis=3987 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=4 pass=2 tx=10 mis=3983 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=4 pass=2 tx=11 mis=3989 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=4 pass=2 tx=12 mis=3985 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=4 pass=2 tx=13 mis=3984 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=4 pass=2 tx=14 mis=3988 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=4 pass=2 tx=15 mis=3984 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=4 pass=3 tx=0 mis=3983 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=4 pass=3 tx=1 mis=3991 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=4 pass=3 tx=2 mis=3984 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=4 pass=3 tx=3 mis=3985 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=4 pass=3 tx=4 mis=3985 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=4 pass=3 tx=5 mis=3987 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=4 pass=3 tx=6 mis=3985 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=4 pass=3 tx=7 mis=3975 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=4 pass=3 tx=8 mis=3987 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=4 pass=3 tx=9 mis=3985 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=4 pass=3 tx=10 mis=3981 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=4 pass=3 tx=11 mis=3980 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=4 pass=3 tx=12 mis=3988 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=4 pass=3 tx=13 mis=3992 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=4 pass=3 tx=14 mis=3985 first=0 shift=0 |
| C3TX | req_hz=12000000 prof=4 pass=3 tx=15 mis=3986 first=0 shift=0 |
| P3SC | prof=4 ceiling_hz=11000000 |
| P3RF | state=2 phys=933888 len=1113 saved=1 |



PI-READ MATCH PI303.LOG

## Gates

