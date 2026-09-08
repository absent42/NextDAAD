; Launcher equates. Bank 2 code, bank 5 text map/defs/stub, surfaces in
; banks 9-13 and 14-18, page 38 script, 39 palette staging, 40+ music.
; Slot 6 = main-loop load window, slot 7 = audio page.
CODE_ORG        equ $8000
RESIDENT_LIMIT  equ $BA00
STACK_TOP       equ $BD00
IM2_TABLE       equ $BD00       ; 257 bytes $BD00-$BE00
IM2_VECTOR_BYTE equ $BE
IM2_STUB        equ $BEBE       ; JP frame_isr
IM2_CTC_STUB    equ $BEC2       ; JP pcm isr
IM2_CTC_VEC     equ 6

PG_CODE_LO      equ 4
PG_MAP          equ 10
PG_DEFS         equ 11
BANK_SURF_A     equ 9           ; pages 18-27
BANK_SURF_B     equ 14          ; pages 28-37
PG_SCRIPT       equ 38
PG_STAGE        equ 39
PG_MUSIC        equ 40
PG_MUSIC_LAST   equ 87

LERP_K          equ 17           ; lerp_init k range 0..16
LERP_D          equ 15           ; lerp_init d range -7..7

TM_MAP          equ $4000
TM_MAP_MSB      equ $00
DBG_MIRROR      equ $5400
STUB_ORG        equ $6000
STUB_HDR        equ $7800
STUB_SP         equ $7FE0
TM_DEFS         equ $6000
TM_DEFS_MSB     equ $20
FATAL_DEFS      equ $7000
FATAL_DEFS_MSB  equ $30
WIN6            equ $C000
WIN7            equ $E000
PCM_RING        equ $E000       ; 8K ring, page 40 in slot 7 (PCM leg)
PAL_CUR         equ $C000       ; page 39 in slot 6
PAL_NEW         equ $C200
PAL_SOLID       equ $C400

NR_VERSION      equ $01
NR_CORE_VERSION equ $0E
NR_PERIPH1      equ $05
NR_PERIPH2      equ $06
NR_CPU_SPEED    equ $07
NR_PERIPH3      equ $08
NR_VIDEO_TIMING equ $11
NR_L2_BANK      equ $12
NR_L2_SHADOW    equ $13
NR_L2_TRANSP    equ $14
NR_LAYERS       equ $15
NR_L2_XOFS      equ $16
NR_L2_YOFS      equ $17
NR_L2_CLIP      equ $18
NR_SPR_CLIP     equ $19
NR_ULA_CLIP     equ $1A
NR_TM_CLIP      equ $1B
NR_CLIP_IDX     equ $1C
NR_RASTER_MSB   equ $1E
NR_RASTER_LSB   equ $1F
NR_TM_XOFS_MSB  equ $2F
NR_TM_XOFS      equ $30
NR_TM_YOFS      equ $31
NR_PAL_INDEX    equ $40
NR_PAL_VALUE    equ $41
NR_PAL_FMT      equ $42
NR_PAL_CTRL     equ $43
NR_PAL_VALUE9   equ $44
NR_FALLBACK     equ $4A
NR_SPR_TRANSP   equ $4B
NR_TM_TRANSP    equ $4C
NR_MMU0         equ $50
NR_MMU1         equ $51
NR_MMU2         equ $52
NR_MMU3         equ $53
NR_MMU4         equ $54
NR_MMU5         equ $55
NR_MMU6         equ $56
NR_MMU7         equ $57
NR_COPPER_LO    equ $61
NR_COPPER_HI    equ $62
NR_ULA_CTRL     equ $68
NR_DISPLAY_CTRL equ $69
NR_TM_CTRL      equ $6B
NR_TM_ATTR      equ $6C
NR_TM_MAP_BASE  equ $6E
NR_TM_DEF_BASE  equ $6F
NR_L2_CTRL      equ $70
NR_L2_XOFS_MSB  equ $71
NR_EXPBUS       equ $80
NR_INT_CTRL     equ $C0
NR_INT_EN_1     equ $C4
NR_INT_EN_2     equ $C5
NR_INT_EN_3     equ $C6
NR_DMA_INT_EN_1 equ $CC
NR_DMA_INT_EN_2 equ $CD
NR_DMA_INT_EN_3 equ $CE
TBBLUE_REG_SEL  equ $243B
TBBLUE_REG_ACC  equ $253B
PORT_L2         equ $123B
DMA_PORT        equ $6B
ULA_OFF         equ $80
PAL_ULA_FIRST   equ %00000000
PAL_L2_FIRST    equ %00010000
PAL_TM_FIRST    equ %00110000
L2_TRANSP_COLOUR equ $E3
LAYERS_TEXT_TOP equ %00001000   ; S U L, sprites off

AUD_CTC_PORT    equ $183B
AUD_CTC_RESET   equ $03
AUD_CTC_CW16    equ $85
DAC_PORT        equ $DF
DAC2_PORT       equ $B3
VID_DAC_LEFT    equ $F3
VID_DAC_RIGHT   equ $F9
DAC_SILENCE     equ $80
PSG_SEL_PORT    equ $FFFD
PSG_DATA_PORT   equ $BFFD

ESX_GETSETDRV   equ $89
ESX_F_OPEN      equ $9A
ESX_F_CLOSE     equ $9B
ESX_F_READ      equ $9D
ESX_F_SEEK      equ $9F
ESX_MODE_READ   equ $01

LOAD_CHUNK      equ 2048        ; bytes per esxDOS read (spike 2 may halve it)
    ASSERT (8192 % LOAD_CHUNK) == 0  ; load.asm's page-full test (cp $20) assumes this

DAT_MAGIC       equ 0
DAT_VER         equ 4
DAT_FLAGS       equ 5
DAT_MUSIC       equ 6
DAT_SKIPWIN     equ 7
DAT_ENDTR       equ 8
DAT_ENDCOL      equ 9
DAT_ENDFR       equ 10
DAT_NSLIDES     equ 12
DAT_NITEMS      equ 13
DAT_STROFF      equ 14
DAT_STRLEN      equ 16
DAT_BORDER      equ 18
DAT_PAL         equ 32
DAT_SLIDES      equ 544
DAT_ITEMS       equ 1568
DAT_STRINGS     equ 4628
DAT_MAX         equ 8128
    ASSERT DAT_PAL + 512 == DAT_SLIDES
    ASSERT DAT_SLIDES + 64*16 == DAT_ITEMS
    ASSERT DAT_ITEMS + 255*12 == DAT_STRINGS
    ASSERT DAT_STRINGS + 3500 == DAT_MAX
SL_PIC          equ 0
SL_MODE         equ 1
SL_TR           equ 2
SL_COL          equ 3
SL_TRF          equ 4
SL_HOLD         equ 6
SL_ITEM0        equ 8
SL_NITEM        equ 9
SL_SPEED        equ 10
SL_SATTR        equ 11
IT_TYPE         equ 0
IT_ROW          equ 1
IT_COL          equ 2
IT_ATTR         equ 3
IT_FLAGS        equ 4
IT_AT           equ 5
IT_STR          equ 7
FL_LOOP         equ 1
FL_SKIPMASK     equ %00000110
FL_COLS40       equ 8
FL_COLFONT      equ 16
MUS_NONE        equ 0
MUS_AKY         equ 1
MUS_AYS         equ 2
MUS_PCM         equ 3
MUS_NDR         equ 4
TR_CUT          equ 0
TR_FADE         equ 1
TR_WIPE_L       equ 2
TR_WIPE_R       equ 3
TR_WIPE_U       equ 4
TR_WIPE_D       equ 5
TR_DISS         equ 6
TR_BLINDS       equ 7
HOLD_KEY        equ $FFFF
HOLD_SCROLL     equ $FFFE
SS_LOAD1        equ 0
SS_TRANS        equ 1
SS_HOLD         equ 2
SS_KEY          equ 3
SS_SCROLL       equ 4
SS_WAIT         equ 5
SS_END          equ 6
LS_IDLE         equ 0
LS_OPEN         equ 1
LS_PAL          equ 2
LS_PIX          equ 3
LS_DONE         equ 4
LS_FAIL         equ 5
SKIP_ANY        equ 0
SKIP_SLIDE      equ 1
SKIP_NONE       equ 2

ERR_DAT_MISSING equ $11
ERR_DAT_MAGIC   equ $12
ERR_DAT_COUNTS  equ $13
ERR_PIC_OPEN    equ $21
ERR_PIC_SHORT   equ $22
ERR_PIC_SIZE    equ $23
ERR_FONT_CHR    equ $31
ERR_FONT_TIL    equ $32
ERR_MUS_OPEN    equ $41
ERR_MUS_HDR     equ $42
ERR_MUS_NDAW    equ $43
ERR_NEX_OPEN    equ $51
ERR_NEX_HDR     equ $52
ERR_NEX_BANK5   equ $53
ERR_NEX_SHORT   equ $54
