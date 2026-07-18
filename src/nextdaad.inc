; NextDAAD constants - single source of truth for the memory map
; and hardware registers. All later modules include this file.

; --- Next registers ---
NR_MACHINE_ID   equ $00
NR_CORE_MAJOR   equ $01     ; bits 7-4 major, 3-0 minor
NR_CORE_SUB     equ $0E     ; sub-minor
NR_CPU_SPEED    equ $07     ; 0=3.5, 1=7, 2=14, 3=28MHz
NR_SPRITES      equ $15
NR_ULA_CTRL     equ $68
NR_DISPLAY_CTRL equ $69     ; bit7 Layer2, bit6 ULA shadow, bits Timex
NR_MMU6         equ $56     ; 8K page at $C000
NR_MMU7         equ $57     ; 8K page at $E000
TBBLUE_REG_SEL  equ $243B
TBBLUE_REG_ACC  equ $253B
NR_INT_CTRL     equ $C0     ; maskable int mode: bits 7-5 IM2 vector base,
                            ; bit 0 = 1 hardware IM2 (daisy-chain), 0 = pulse
NR_INT_EN_1     equ $C4     ; int enables: bit 0 ULA, bit 1 line, bit 7 expansion
NR_INT_EN_2     equ $C5     ; int enables: bit n = CTC channel n
NR_INT_EN_3     equ $C6     ; int enables: UART Rx/Tx

; --- Resident memory layout (in 16K bank 2, $8000-$BFFF) ---
CODE_ORG        equ $8000
RESIDENT_LIMIT  equ $BA00   ; code+data must end below this
STACK_TOP       equ $BD00   ; SP; grows down toward RESIDENT_LIMIT
IM2_TABLE       equ $BD00   ; 257 bytes $BD00-$BE00
IM2_VECTOR_BYTE equ $BE
IM2_STUB        equ $BEBE   ; 3-byte JP written at runtime
IM2_CTC_STUB    equ $BEC2   ; 3-byte JP ctc_isr, runtime-written beside IM2_STUB.
                            ; High byte $BE == IM2_VECTOR_BYTE fill, so only the
                            ; carved table[V] low byte differs from the uniform fill.
IM2_CTC_VEC     equ 6       ; CTC channel 0 vector byte in Next hardware-IM2 mode
                            ; with NR C0 base 0: 2*(3+channel) = 2*3 = 6 (even; the
                            ; controller supplies word-index<<1). Matches CTCAudio's
                            ; "ld l,6 ; CTC vectors 3*2 (WORDS)".
NR_INT_C0_VAL   equ %00000001 ; hardware IM2 mode: vector base (bits 7:5) 0, bit 0 = 1.
                            ; Relocates ALL sources incl. ULA (index 11 -> byte 22)
                            ; into the $BD00 table; the uniform fill routes every
                            ; non-carved source to $BEBE -> im2_isr unchanged.

; --- Physical bank map (16K banks) ---
BANK_SYS_LAST   equ 8       ; 0-8 reserved: system, ULA bank 5, code bank 2
BANK_L2_FIRST   equ 9       ; 9-13 Layer 2 boot FRONT surface (5 banks covers
BANK_L2_LAST    equ 13      ; 320x256); flips swap roles with 30-34
BANK_POOL_A     equ 14      ; 14-15 allocator pool
BANK_POOL_A_END equ 15
BANK_DDB_FIRST  equ 16      ; 16-23 DDB, 128K maximum
BANK_DDB_LAST   equ 23
BANK_AUDIO_FIRST equ 24     ; 24-27 reserved for music and SFX
BANK_AUDIO_LAST equ 27
BANK_L2BACK_FIRST equ 30    ; 30-34 Layer 2 boot BACK surface (double buffer:
BANK_L2BACK_LAST equ 34     ; gfx_blit renders here, then flips NR $12)
BANK_POOL_B     equ 35      ; 35-47 allocator pool (base model ends at 47); bank 28
                            ; withdrawn for overlay 0/1, bank 29 for overlay 2,
                            ; banks 30-34 for the Layer 2 back surface
BANK_BASE_LAST  equ 47
BANK_EXP_FIRST  equ 48      ; 48-111 expansion pool when detected
BANK_EXP_LAST   equ 111
BANK_TABLE_SIZE equ 112

; --- bankTable entry values ---
BT_RESERVED     equ 0
BT_FREE         equ 1
BT_USED         equ 2

; --- DDB ---
DDB_MAX_BANKS   equ 8
DDB_HEADER_SIZE equ 34
DDB_VERSION     equ 2
DDB_MAGIC       equ 95      ; '_' at header offset 2
DDB_ZX_BASE     equ $8400   ; classic ZX load base; pointers are absolute

; --- ddb_load result codes ---
DDB_OK          equ 0
DDB_E_FILE      equ 1       ; missing or read error
DDB_E_SIZE      equ 2       ; over 128K
DDB_E_HDR       equ 3       ; failed validation

; --- Error border colours ---
ERR_BORDER_MISSING  equ 2   ; red
ERR_BORDER_OVERSIZE equ 3   ; magenta
ERR_BORDER_BADHDR   equ 6   ; yellow

; --- esxDOS API ---
ESX_GETSETDRV   equ $89
ESX_F_OPEN      equ $9A
ESX_F_CLOSE     equ $9B
ESX_F_READ      equ $9D
ESX_F_WRITE     equ $9E
ESX_F_SEEK      equ $9F
ESX_MODE_READ   equ $01
ESX_MODE_W      equ $0E     ; F_OPEN: write, create or truncate
ESX_ENOENT      equ 5       ; F_OPEN: file not found

; --- Tilemap text mode (sub-project 2) ---
NR_TM_CTRL      equ $6B
NR_TM_MAP_BASE  equ $6E     ; MSB of map offset in bank 5
NR_TM_DEF_BASE  equ $6F     ; MSB of tile definitions offset in bank 5
NR_PAL_INDEX    equ $40
NR_PAL_VALUE    equ $41     ; 8-bit RRRGGGBB, auto-increment via $43
NR_PAL_VALUE9   equ $44     ; 9-bit value, two writes (RRRGGGBB then B0); index
                            ; auto-increments after the second write
NR_PAL_CTRL     equ $43
NR_FALLBACK     equ $4A     ; global fallback colour: output wherever
                            ; every layer is transparent
TM_CTRL_ON      equ %11001000   ; enable, 80x32, attributes, text mode
PAL_TM_FIRST    equ $30     ; auto-increment on, tilemap first palette
TM_MAP          equ $6000   ; 80x32x2 = 5120 bytes, $6000-$73FF
TM_MAP_MSB      equ $20     ; ($6000-$4000)>>8
TM_DEFS         equ $7400   ; 256 glyphs x 8 = 2048 bytes
TM_DEFS_MSB     equ $34     ; ($7400-$4000)>>8
TM_COLS         equ 80
TM_ROWS         equ 32
GLYPH_SPACE     equ $20
ULA_OFF         equ $80     ; NR_ULA_CTRL bit 7
NR_TM_TRANSP    equ $4C     ; normal tilemap mode's transparent index -
                            ; NOT what we use: text mode (TM_CTRL_ON bit3)
                            ; checks NR_L2_TRANSP ($14) instead - see
                            ; chapter-next-tilemap.tex line 357
TM_TRANSP_PAIR  equ 127     ; reserved SP6 pair (paper=7, ink=15) - the
                            ; one (paper,ink) combo sacrificed as the
                            ; transparent-cell marker (bright-white-on-
                            ; white is unreadable anyway, so losing it as
                            ; an opaque combo costs nothing practical)
TM_TRANSP_ATTR  equ TM_TRANSP_PAIR*2  ; = 254: attribute byte for a
                            ; transparent cell (paired with GLYPH_SPACE,
                            ; whose all-zero bitmap keeps every pixel on
                            ; the pair's even/paper index) AND the value
                            ; programmed into NR_L2_TRANSP so hardware
                            ; treats that exact index as transparent

; --- Banking skeleton (sub-project 3) ---
DDB_PAGE_FIRST  equ 32      ; DDB bank 16 = 8K pages 32..47
BANK_OVL0       equ 28      ; overlay page 0 lives in bank 28 (lower 8K)
OVL0_PAGE       equ 56      ; = BANK_OVL0*2
OVL_ORG         equ $E000
OVL_LIMIT       equ $F800   ; overlay ASSERT bound (512 bytes spare)
OVL1_PAGE       equ 57      ; overlay page 1: upper 8K of bank 28
BANK_OVL2       equ 29      ; overlay page 2 lives in bank 29 (lower 8K)
OVL2_PAGE       equ 58      ; = BANK_OVL2*2
DATA_WINDOW     equ $C000   ; slot 6 window base (8K)

; --- Layer 2 (sub-project 4) ---
NR_L2_BANK      equ $12     ; starting 16K bank of Layer 2 (bits 6-0)
NR_L2_CTRL      equ $70     ; bits 5-4 resolution, bits 3-0 palette offset
NR_L2_TRANSP    equ $14     ; transparent colour index (Layer 2/ULA/LoRes)
NR_LAYERS       equ $15     ; bits 4-2 S/L/U layer priority (alias of
                            ; NR_SPRITES - same register, different role here)
L2_PORT         equ $123B   ; bit 1 Layer 2 visible, bit 0 write paging slot0
                            ; - NOT used for enable/disable (see l2_enable's
                            ; comment, overlay2.asm): a bare enable write also
                            ; zeroes this port's other live bits (video-RAM
                            ; bank select etc) every time; NR_DISPLAY_CTRL
                            ; bit 7 is the alias actually used instead
PAL_L2_FIRST    equ $10     ; NR_PAL_CTRL: auto-inc on, Layer 2 first palette
                            ; (edit + active display), see chapter-next-palette
NR_L2_CLIP      equ $18     ; Layer 2 clip window (X1,X2,Y1,Y2 - index-
                            ; sequenced); guide: "reads and writes"
NR_CLIP_IDX     equ $1C     ; write bit0 = 1 resets the L2 clip index
NR_L2_XOFS      equ $16     ; Layer 2 X pixel scroll offset (low 8 bits)
NR_L2_YOFS      equ $17     ; Layer 2 Y pixel scroll offset

; --- Engine (sub-project 3) ---
PROC_DEPTH      equ 10
PREC_SIZE       equ 6       ; proc(1) entryPtr(2) condactPtr(2) done(1)
OBJ_SIZE        equ 6
OBJ_NOT_CREATED equ 252
OBJ_WORN        equ 253
OBJ_CARRIED     equ 254
LOC_HERE        equ 255
FLAG_CARRIED_CT equ 1
FLAG_VERB       equ 33
FLAG_NOUN1      equ 34
FLAG_ADJ1       equ 35
FLAG_ADVERB     equ 36
FLAG_MAXCARR    equ 37
FLAG_PLAYER     equ 38
FLAG_PREP       equ 43
FLAG_NOUN2      equ 44
FLAG_ADJ2       equ 45
FLAG_DOALL      equ 50
FLAG_CUROBJ     equ 51
FLAG_STRENGTH   equ 52
FLAG_OFLAGS     equ 53
FLAG_COLOC      equ 54
FLAG_COWEI      equ 55
FLAG_COCON      equ 56
FLAG_COWR       equ 57
FLAG_COATT      equ 58
FLAG_KEY1       equ 60
FLAG_CURWIN     equ 63
FLAG_O2NUM      equ 25
FLAG_O2CON      equ 26
FLAG_O2LOC      equ 27
FLAG_O2ATT      equ 39
FLAG_INPUTSTREAM equ 41
FLAG_PROMPT     equ 42
FLAG_CPNOUN     equ 46
FLAG_CPADJ      equ 47
FLAG_TIMEOUT    equ 48
FLAG_TIMECTL    equ 49
; header field offsets (resident ddbHeader)
HDR_NUMOBJ      equ 3
HDR_NUMLOC      equ 4
HDR_NUMMSG      equ 5
HDR_NUMSYS      equ 6
HDR_NUMPRC      equ 7
HDR_TOKENS      equ 8
HDR_PROCLST     equ 10
HDR_OBJLST      equ 12
HDR_LOCLST      equ 14
HDR_MSGLST      equ 16
HDR_SYSLST      equ 18
HDR_CONLST      equ 20
HDR_VOCAB       equ 22
HDR_OBJLOC      equ 24
HDR_OBJNAME     equ 26
HDR_OBJATTR     equ 28
HDR_OBJEXTR     equ 30

; --- Audio (sub-project 7) ---
AUD_PAGE_LO     equ 48      ; bank 24 lower 8K
AUD_PAGE_HI     equ 49      ; bank 24 upper 8K
AUD_PLAYER_ORG  equ $C000
AUD_SFB_ORG     equ $D000   ; effects bank (2K)
AUD_SONG_ORG    equ $D800   ; current song
AUD_SONG_MAX    equ $27E0   ; 10208 bytes ($D800-$FFDF)
AUD_STATE       equ $FFE0   ; audFlags/beep state/song number

; --- SP8 sampled sound ---
DMA_PORT        equ $6B     ; zxnDMA, datagear port decode
DAC_PORT        equ $DF     ; SpecDrum-compatible mono DAC (all 4 DACs)
; DAC signedness. SHIPPED DEFAULT = hardware-correct UNSIGNED: no load-time
; XOR, DAC silence/park = $80 (the unsigned midpoint). Evidence: the FPGA
; soundrive.vhd resets the DACs to $80 and sums UNSIGNED; em00k's CTCAudio and
; playwav32 both feed raw unsigned WAV bytes to the DAC (CTCAudio README:
; "PCM unsigned" - em00k-audio-engines-analysis.md); and the owner's two real-
; hardware listens. Build with -DDAC_CSPECT=1 (build.ps1 -DacCSpect) for the
; CSpect accommodation: aud_load_wav XORs $80 at load so the banks hold signed
; PCM and silence/park = $00 (CSpect's admitted-"not really tested" signed
; $FFDF path). See benbaker-dma-analysis.md. One define site, sense flipped
; post-em00k (SP10 CTC pivot) so the shippable default is silicon-correct.
 IFDEF DAC_CSPECT
DAC_SILENCE     equ $00
 ELSE
DAC_SILENCE     equ $80
 ENDIF
NR_PERIPH3      equ $08     ; peripheral 3: bit 3 = 8-bit DACs on,
                            ; bit 1 = Turbo Sound on (both hard-reset 0)
NR_VIDEO_TIMING equ $11     ; bits 2:0 = video timing mode 0-6 (VGA0-6), 7 = HDMI;
                            ; selects the FPGA system clock the CTC divides
; SP10 CTC per-sample DAC feed (replaces the SP8 DMA sample engine). The CTC
; channel input clock IS the video-mode-dependent FPGA system clock (27-33 MHz,
; nextreg $11), NOT a fixed reference - so the time constant is derived per
; video mode at load time (aud_clk16_tab in overlay1). Prescaler /16 for rate
; >= AUD_CTC_XOVER (TC = clock/16/rate <= 256); /256 below it. Confirmed against
; playvid + em00k CTCAudio: "28,000,000 / 16 / 15625 = 112".
AUD_CTC_PORT    equ $183B   ; CTC channel 0 (lowest = highest IM2 priority; ch3=joystick)
AUD_CTC_RESET   equ $03     ; control word: soft reset (D1) + no TC (D2=0); written
                            ; twice = the Next's unknown-state channel reset (ports.txt)
AUD_CTC_CW16    equ $85     ; %10000101: int en, timer, /16, auto-trig, TC follows, control
AUD_CTC_CW256   equ $A5     ; %10100101: as CW16 but prescaler /256
AUD_CTC_XOVER   equ 6836    ; rate >= this uses /16 (else TC = clock/16/rate > 256)
AUD_RATE_MIN    equ 3500    ; validated sample-rate floor (aud_load_wav)
AUD_RATE_MAX    equ 20000   ; the 1K ring holds > 1 frame of this rate
AUD_SMP_MAX     equ 1048576 ; sample payload sanity ceiling (1MB = 64
                            ; banks; allocator success is the real
                            ; bound - this just rejects absurd WAVs
                            ; before touching the allocator)
AUD_STRTAB_MAX  equ 128     ; stream page-table capacity (128 x 8K =
                            ; 1MB per stream; one table per client)
SMP_FLOOR_FIRST equ 25      ; reserved audio floor: banks 25-27 are
SMP_FLOOR_LAST  equ 27      ; claimed first so a 48K load ALWAYS
                            ; works regardless of pool pressure
SMP_PAGE_FIRST  equ 50      ; bank 25 lower 8K; floor banks' first page
AUD_STAGE0      equ $7C00   ; ring base, bank 5 upper region - ALWAYS mapped
                            ; (MMU3), above divMMC's $0000-$3FFF, free after
                            ; TM_DEFS ($7400-$7BFF); ends exactly at $8000
AUD_STAGE_RING  equ 1024    ; power-of-two ring $7C00-$7FFF: the CTC ISR plays
                            ; smpPlayPtr, the 50Hz tick refills smpW from the
                            ; page-table source. 1K = 51ms at 20kHz - ample vs
                            ; the 20ms refill period. Base $7C00 is 1K-aligned so
                            ; the ISR wraps with a branchless AND/OR mask on H.
    ASSERT AUD_STAGE0 + AUD_STAGE_RING == $8000   ; ISR wrap tests H == $80
    ASSERT AUD_STAGE_RING >= 2*(AUD_RATE_MAX/50)  ; ring > 1 frame of consumption
                            ; so a tick always refills before the ISR underruns

; --- Window system (sub-project 2) ---
WIN_X           equ 0
WIN_Y           equ 1
WIN_W           equ 2
WIN_H           equ 3
WIN_CURX        equ 4
WIN_CURY        equ 5
WIN_FLAGS       equ 6       ; bit 0 force upper charset, bit 1 disable More
WIN_INK         equ 7
WIN_PAPER       equ 8
WIN_LASTPIC     equ 9
WIN_LINES       equ 10      ; lines printed since last pause
WIN_SIZE        equ 11
WINDOW_COUNT    equ 8
