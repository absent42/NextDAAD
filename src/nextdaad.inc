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

; --- Resident memory layout (in 16K bank 2, $8000-$BFFF) ---
CODE_ORG        equ $8000
RESIDENT_LIMIT  equ $BA00   ; code+data must end below this
STACK_TOP       equ $BD00   ; SP; grows down toward RESIDENT_LIMIT
IM2_TABLE       equ $BD00   ; 257 bytes $BD00-$BE00
IM2_VECTOR_BYTE equ $BE
IM2_STUB        equ $BEBE   ; 3-byte JP written at runtime

; --- Paging window ---
WINDOW_ADDR     equ $C000

; --- Physical bank map (16K banks) ---
BANK_SYS_LAST   equ 8       ; 0-8 reserved: system, ULA bank 5, code bank 2
BANK_L2_FIRST   equ 9       ; 9-13 Layer 2 (5 banks covers 320x256)
BANK_L2_LAST    equ 13
BANK_POOL_A     equ 14      ; 14-15 allocator pool
BANK_POOL_A_END equ 15
BANK_DDB_FIRST  equ 16      ; 16-23 DDB, 128K maximum
BANK_DDB_LAST   equ 23
BANK_AUDIO_FIRST equ 24     ; 24-27 reserved for music and SFX
BANK_AUDIO_LAST equ 27
BANK_POOL_B     equ 28      ; 28-47 allocator pool (base model ends at 47)
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

; --- Tilemap text mode (sub-project 2) ---
NR_TM_CTRL      equ $6B
NR_TM_MAP_BASE  equ $6E     ; MSB of map offset in bank 5
NR_TM_DEF_BASE  equ $6F     ; MSB of tile definitions offset in bank 5
NR_PAL_INDEX    equ $40
NR_PAL_VALUE    equ $41     ; 8-bit RRRGGGBB, auto-increment via $43
NR_PAL_CTRL     equ $43
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
