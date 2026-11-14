; Wrap clock: raster line NR $1E:$1F, one backwards step = one frame.
; T = (F x LPF + D) x TPL; exact only while every rep is shorter than a frame.

CLK_NR_MSB       equ $1E     ; "0000000" & cvc(8), no latch (zxnext.vhd:6516)
CLK_NR_LSB       equ $1F     ; cvc(7 downto 0) (zxnext.vhd:6519)

; Per-rep T outside the body, 28 MHz worst case (+1 per opcode fetch and memory read):
; call 20 + body ret 13 + CLK_LINE 177 + wrap update 132 + rep count 70.
POLL_T           equ 412

; HL = line. MSB read either side of the LSB catches a carry between reads;
; retries are bounded so a stuck counter cannot hang. Exits CF = 0. Corrupts AF, BC, D.
    MACRO CLK_LINE
    ld d, 4
.rd:
    ld bc, NR_SEL
    ld a, CLK_NR_MSB
    out (c), a
    inc b
    in h, (c)
    dec b
    ld a, CLK_NR_LSB
    out (c), a
    inc b
    in l, (c)
    dec b
    ld a, CLK_NR_MSB
    out (c), a
    inc b
    in a, (c)
    cp h
    jr z, .ok                    ; equal: CF = 0
    dec d
    jr nz, .rd
    or a
.ok:
    ENDM

; Run the body at HL DE times (DE >= 1), one poll per rep; D spans the first
; poll to the last. Out: HL = F, DE = D. Body may corrupt every register but SP.
clk_run:
    ld (.body + 1), hl
    ld (clkLeft), de
    ld hl, 0
    ld (clkF), hl
    CLK_LINE
    ld (clkPrev), hl
    ld (clkL0), hl
.body:
    call 0                       ; SMC: the row's body
    CLK_LINE
    ld de, (clkPrev)
    ld (clkPrev), hl
    sbc hl, de                   ; CF = the line went back
    ld hl, (clkF)
    ld de, 0
    adc hl, de                   ; branchless: every rep costs the same
    ld (clkF), hl
    ld hl, (clkLeft)
    dec hl
    ld (clkLeft), hl
    ld a, h
    or l
    jp nz, .body
    ld hl, (clkPrev)
    ld de, (clkL0)
    or a
    sbc hl, de
    ex de, hl
    ld hl, (clkF)
    ret

clkLeft:  dw 0
clkF:     dw 0
clkPrev:  dw 0
clkL0:    dw 0
