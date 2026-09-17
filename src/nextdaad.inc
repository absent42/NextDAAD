; NextDAAD constants - single source of truth for the memory map
; and hardware registers. All later modules include this file.

; --- Version ---
; Boot-time version stamp: DEBUG's msgTitle and RELEASE's boot_banner
; (both debug.asm) print this exact string, so update it here only -
; the two build variants must never drift apart.
    DEFINE VERSION_STR "NEXTDAAD V0.10.0"

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
; Which interrupters may interrupt a RUNNING zxnDMA (hardware IM2 only) -
; the $C4/$C5/$C6 enable trio's exact mirror at +8. NO RESET VALUE IS
; DOCUMENTED for any of the three, so im2_init writes all three explicitly.
NR_DMA_INT_EN_1 equ $CC     ; DMA pre-emption: bit 0 ULA, bit 1 line
NR_DMA_INT_EN_2 equ $CD     ; DMA pre-emption: bit n = CTC channel n
NR_DMA_INT_EN_3 equ $CE     ; DMA pre-emption: UART Rx/Tx

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
IM2_CTC2_STUB   equ $BEC5   ; RESERVED beside IM2_CTC_STUB ($BEC2-4) for layout
                            ; symmetry - im2_init does NOT write a JP here.
                            ; Channel 2's table entry (IM2_TABLE + IM2_CTC2_VEC)
                            ; points straight at ctc2_isr instead (im2_init's
                            ; own comment there has the byte-cost reasoning
                            ; and the asymmetry against channel 1's stub).
                            ; A future runtime hijack of channel 2 (mirroring
                            ; video.asm's channel 1/IM2_CTC_STUB+1 swap) must
                            ; either install a JP here first and repoint the
                            ; table at it, or keep writing
                            ; IM2_TABLE + IM2_CTC2_VEC directly on each
                            ; hijack/release - either works, but doing
                            ; nothing does not: this slot is inert today.
IM2_CTC2_VEC    equ 8       ; CTC channel 1 vector byte: 2*(3+channel) = 2*4 = 8,
                            ; same formula as IM2_CTC_VEC one channel over.
NR_INT_C0_VAL   equ %00000001 ; hardware IM2 mode: vector base (bits 7:5) 0, bit 0 = 1.
                            ; Relocates ALL sources incl. ULA (index 11 -> byte 22)
                            ; into the $BD00 table; the uniform fill routes every
                            ; non-carved source to $BEBE -> im2_isr unchanged.

; --- Physical bank map (16K banks) ---
; SETTLED 2026-08-12. Every range below is either hardware-fixed or
; derived from a limit stated at its own constant - none is a guess with
; room to spare, so a range that looks generous is load-bearing. The
; allocator pool is whatever is left: banks 14-15, 20-23, 37-47 (37-46
; in DEBUG) and, when the RAM is there, 48-111. bank_table_init is the one
; place that decides what is free, and debug.asm's bank_selftest asserts
; both the count and the allocation ORDER - update those expectations
; whenever anything here moves, never loosen them.
BANK_SYS_LAST   equ 8       ; 0-8 reserved: system, ULA bank 5, code bank 2
BANK_L2_FIRST   equ 9       ; 9-13 Layer 2 boot FRONT surface (5 banks covers
BANK_L2_LAST    equ 13      ; 320x256); flips swap roles with 30-34
BANK_POOL_A     equ 14      ; 14-15 allocator pool
BANK_POOL_A_END equ 15
BANK_DDB_FIRST  equ 16      ; 16-19 DDB, 64K maximum. FOUR banks because
BANK_DDB_LAST   equ 19      ; 64K is the interpreter's addressable extent,
                            ; not a capacity choice: rd_seek (ddbtext.asm)
                            ; masks the page index with AND 7, so a DDB
                            ; pointer reaches 8 pages of 8K and no more,
                            ; whatever the file size. This was 16-23/128K
                            ; until 2026-08-12; the upper four banks could
                            ; never hold an addressable byte. Do not
                            ; "restore" them - raising this without also
                            ; widening rd_seek's mask achieves nothing.
BANK_POOL_C     equ 20      ; 20-23 allocator pool, released from the old
BANK_POOL_C_END equ 23      ; DDB over-reservation
BANK_AUDIO_FIRST equ 24     ; 24-27 reserved for music and SFX
BANK_AUDIO_LAST equ 27
BANK_L2BACK_FIRST equ 30    ; 30-34 Layer 2 boot BACK surface (double buffer:
BANK_L2BACK_LAST equ 34     ; gfx_blit renders here, then flips NR $12)
; 35-47 allocator pool (base model ends at 47); bank 28 withdrawn for
; overlay 0/1, bank 29 for overlay 2, banks 30-34 for the Layer 2 back
; surface, bank 47 in DEBUG builds only for the bench (BANK_NXB below).
; Bank 35 is ALSO withdrawn, for VID_PAGE2 below - originally
; (SP14a T1) a DEBUG-only report-print page; SP14a T3 wave 1 makes the
; withdrawal UNCONDITIONAL in both build variants, since VID_PAGE2 now
; also carries Release-reachable COLD video code (vid_classify, the
; open/filemap-setup cluster) evicted off VID_PAGE under the one-rule
; invariant (MMU7 = VID_PAGE whenever the video CTC ISR can fire) - see
; video.asm's own eviction comments at each moved routine.
BANK_VID2       equ 35      ; withdrawn from the pool for the two pages
                            ; below - see the paragraph above
BANK_SPR        equ 36      ; withdrawn: sprite animation pages, the
                            ; BANK_VID2 pattern - excluded from bank_alloc
                            ; because bank_table_init's pool B starts at 37
BANK_POOL_B     equ 37
SPR_PAGE        equ BANK_SPR*2      ; lower 8K, slot 7: code, records, maps, cache
SPR_TAB_PAGE    equ BANK_SPR*2+1    ; upper 8K, slot 6: 8 frame tables of 1K
VID_PAGE2       equ BANK_VID2*2      ; lower 8K of the withdrawn bank
SFX_PAGE        equ BANK_VID2*2+1    ; upper 8K of the SAME withdrawn
                            ; bank (SP18 item 7 T3: SD-streamed sampled-
                            ; effect transport clones). Bank 35 is
                            ; already wholly excluded from bank_alloc
                            ; (the comment above; bank_table_init's free-
                            ; pool loop starts at BANK_POOL_B), so
                            ; this sibling page needs no further banks
                            ; .asm change - it is unreachable to the
                            ; allocator from assembly time, exactly like
                            ; VID_PAGE2. Populated by src/audio/streamfx
                            ; .asm's own `MMU 7, SFX_PAGE, OVL_ORG` +
                            ; main.asm's INCLUDE, picked up by SAVENEX
                            ; AUTO - same zero-resident-cost mechanism as
                            ; VID_PAGE/VID_PAGE2 above.
BANK_BASE_LAST  equ 47
BANK_NXB        equ 47      ; DEBUG only: the bench bank, reserved by
                            ; bank_table_init after its pool B loop
NXB_PAGE        equ BANK_NXB*2      ; lower 8K, slot 6: bench tables
    ASSERT BANK_NXB == BANK_BASE_LAST
BANK_EXP_FIRST  equ 48      ; 48-111 expansion pool when detected
BANK_EXP_LAST   equ 111
BANK_TABLE_SIZE equ 112

; --- bankTable entry values ---
BT_RESERVED     equ 0
BT_FREE         equ 1
BT_USED         equ 2

; --- DDB ---
DDB_MAX_BANKS   equ 4       ; 64K. ddb_load's chunk cap is DDB_MAX_BANKS*2
                            ; 8K chunks, so a larger file returns
                            ; DDB_E_SIZE instead of loading a part of
                            ; itself that no pointer could reach. Tied to
                            ; BANK_DDB_FIRST/LAST above - see the note
                            ; there before changing either.
DDB_HEADER_SIZE equ 34
DDB_VERSION     equ 2       ; lowest accepted header version; ddb_load
                            ; takes 2 AND 3 (SP16 A1 - DAAD-READY's own
                            ; ZXNEXT.BAT compiles with -v3). ddbVer is
                            ; the resident copy of header byte 0 and the
                            ; ONE V3 gate in the interpreter: 2 and 3
                            ; differ in bit 0 alone, so every gate is a
                            ; single BIT 0 test, never a CP (doc 06).
DDB_MAGIC       equ 95      ; header offset 2. HISTORICALLY the /CTL null
                            ; word (hence 95 = '_'), but DRC does not read
                            ; /CTL at all any more: drb.php:1811-1813
                            ; ("This byte stored the null character,
                            ; usually underscore, as set in /CTL section.
                            ; That's why all classic DDBs have same value:
                            ; 95. For new targets (MSX2) we use that byte
                            ; for subtarget information.") writes
                            ; getSubMachineIDByTarget(), which returns 95
                            ; for every target but MSX2. It is a magic
                            ; number here, NOT a substitution character to
                            ; read - see print.asm's prn_decoded. jDAAD
                            ; agrees: it parses byte 2 as "the95" and
                            ; never reads it again (jdaad.js:470).
; header byte 1: HIGH nibble = target machine, LOW nibble = language
; (drb.php writes getMachineIDByTarget << 4, then ORs bit 0 for ES/PT).
; The low nibble MUST be masked off before comparing - print.asm and
; ddbtext.asm read its bit 0 as "Spanish", so a whole-byte compare would
; refuse every Spanish database.
;
; NextDAAD accepts its OWN machine and nothing else. The classic ZX
; nibble (1) was accepted until 2026-08-12 with a per-database pointer
; base; that is gone, and with it DDB_ZX_BASE, ddb_base_resolve and the
; rebase arithmetic in rd_seek and eng_ptr_abs. A NextDAAD database's
; pointers ARE file offsets, so the reader needs no base at all.
;
; What a refusal saves is not tuning but legibility: DRC bases pointers
; at each target's own load address (drb.php - ZX $8400, MSX $0100, CPC
; $2880, C64 $3880, CP/M $2000, CP4 $7080, PC/ST/Amiga/HTML/MSX2 zero),
; ST and Amiga byte-swap every word, and PC/ST/Amiga/HTML pad tables to
; even addresses. None of those is readable here, and a classic ZX
; database would additionally lay itself out for a 32 or 42 column
; screen. All of them now raise E4 at load.
DDB_MACHINE_NXD equ $0C     ; NextDAAD's own machine nibble. PROVISIONAL
                            ; until DRC upstream ratifies it - the fork
                            ; branch `nextdaad` proposes 0x0C, free after
                            ; ZX81 took 0x08. If a different value is
                            ; allocated, THIS LINE IS THE WHOLE CHANGE.

; --- ddb_load result codes ---
DDB_OK          equ 0
DDB_E_FILE      equ 1       ; missing or read error
DDB_E_SIZE      equ 2       ; over 128K
DDB_E_HDR       equ 3       ; failed validation
DDB_E_MACHINE   equ 4       ; built for another target machine

; --- XBN extern binary (authoring-kit/xbn.inc is the authoring side) ---
XBN_MAX_SIZE    equ $4000    ; one 16K bank, header included
XBN_HDR_LEN     equ 14       ; "XBN" + version + extEntry + intEntry + size + 4 reserved (zero)

; Service jump table: FROZEN address, from the first release with XBN
; support - authoring-kit/xbn.inc mirrors this exact value for SVC_*;
; append-only (never move, never shrink a row) once shipped. Runtime-
; poked territory like IM2_STUB/IM2_CTC_STUB above, not part of the
; assembled resident image - main.asm's xbn_api_init ldirs the table
; template here at boot. Sanity: below IM2_CTC2_STUB ($BEC5-$BEC7) ends
; clear at $BEC7, so the 15-row table ($BEC8-$BEF4) does not collide;
; re-grep src/ for $BEC8-$BFFF literals before every commit that touches
; this block (only $BFFD, the AY data I/O port, is expected below $C000).
XBN_API         equ $BEC8       ; FROZEN from first release with XBN
                                ; support - see xbn.inc; append-only
XBN_API_ROWS    equ 15

; --- Error border colours ---
ERR_BORDER_MISSING  equ 2   ; red
ERR_BORDER_OVERSIZE equ 3   ; magenta
ERR_BORDER_BADHDR   equ 6   ; yellow
ERR_BORDER_MACHINE  equ 5   ; cyan

; --- esxDOS API ---
ESX_GETSETDRV   equ $89
ESX_F_OPEN      equ $9A
ESX_F_CLOSE     equ $9B
ESX_F_READ      equ $9D
ESX_F_WRITE     equ $9E
ESX_F_SEEK      equ $9F
ESX_F_FSTAT     equ $A1     ; A=handle, IX=11-byte buffer; +7(4)=file size
                            ; (esxDOS API odt: F_FSTAT ($a1)) - used by
                            ; vid_stream_open (video.asm, SP13 T1) instead
                            ; of the F_SEEK-to-end idiom, since it needs no
                            ; seek-back before the first read.
ESX_F_CHDIR     equ $A9     ; A=drive spec ('*'=default), IX=path, null-
                            ; terminated; Fc=1/A=error on failure (esxDOS
                            ; API odt/PDF, "F_CHDIR ($a9)": does NOT also
                            ; change the current drive - M_GETSETDRV is
                            ; separate). Used by file.asm's DEBUG-only
                            ; ddb_load_debug_retry.
ESX_MODE_READ   equ $01
ESX_MODE_W      equ $0E     ; F_OPEN: write, create or truncate
ESX_ENOENT      equ 5       ; F_OPEN: file not found
ESX_DISK_FILEMAP  equ $85   ; card-address map of a file's fragment runs
ESX_M_GETDATE   equ $8E     ; out BC=date DE=time H=secs L=hundredths;
                            ; CF set = no RTC fitted (esxDOS API odt,
                            ; "M_GETDATE ($8e)")

; DEBUG-only boot fallback (DeZog quality-of-life): a dezogif/serial
; DeZog launch inherits cwd at the SD ROOT, not wherever the debug
; payload actually lives, so ddb_load's first attempt can miss GAME.DDB
; even though the card genuinely has it - a real hardware session hit
; this. file.asm's ddb_load_debug_retry (DEBUG-only, main.asm's boot path
; calls it in place of plain ddb_load) F_CHDIRs here and retries once
; before falling through to the ordinary E1 fatal. ONE place to edit if
; the owner's debug payload directory ever moves - text substitution
; only (sjasmplus DEFINE), the string is emitted where it's declared
; (file.asm), not here.
 DEFINE DBG_DDB_FALLBACK_DIR "/nextdaad/debug"
; --- raw SD SPI transport (video page, SP13 T1c). DISK_STRMSTART/END are
;     NOT used - we drive the card directly, transcribed from Garry
;     Lancaster's inlined playvid SD code (MIT-cleared). No OS streaming
;     window is opened, so nothing needs ending beyond deselecting the card.
PORT_SPI_CS     equ $E7     ; SD card-select port
PORT_SPI_DAT    equ $EB     ; SD data port (read/write; 16T/byte via OUT (C))
SD_CS0          equ $FE     ; select card 0
SD_CS1          equ $FD     ; select card 1
CMD12_STOP_TRANSMISSION   equ 12|$40   ; = $4C
CMD18_READ_MULTIPLE_BLOCK equ 18|$40   ; = $52
; --- distinct open/stream failure codes, chosen outside the esxDOS error
;     range so the bench can name them on the STRM row.
VID_ERR_FRAG    equ $FE     ; file needs > 32 runs (run .defrag)
VID_ERR_NOMAP   equ $FF     ; DISK_FILEMAP returned no entries
VID_ERR_TOKEN   equ $FD     ; SD data token was not $FE (bad block token)
VID_ERR_CMD     equ $FC     ; SD command R1 response was not 0 (CMD18 reject)
VID_FILEMAP_ENT equ 33      ; filemap buffer capacity, 6 bytes/entry (198 B).
                            ; 33, DELIBERATELY one above the documented
                            ; 32-fragment ceiling (SP13 T1b Minor 3 fix):
                            ; DISK_FILEMAP reports a FULL buffer (0 unused
                            ; entries) identically for "exactly filled" and
                            ; "truncated", so a full buffer can never prove
                            ; the map complete and must refuse. With 32
                            ; entries that falsely refused a file in EXACTLY
                            ; 32 extents; with 33, a 32-extent file leaves
                            ; one entry unused (provably complete) and only
                            ; 33+ extents refuse - which is what the docs
                            ; promise ("more than 32 fragments refuses").

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
; Copper co-processor (SP14a escalation bench wave, VBENCH-COPPER) - the
; border colour is NOT NextReg-addressable (legacy I/O port $FE bits 2:0
; only - confirmed the escalation research doc's own "MOVE to the border
; register" premise is wrong), so NR_FALLBACK above is VBENCH-COPPER's
; substitute visible probe target instead.
NR_COPPER_DATA        equ $60 ; copper RAM data port, auto-increments
NR_COPPER_ADDR_LO     equ $61 ; copper RAM write-index, low 8 bits
NR_COPPER_ADDR_HI_CTRL equ $62 ; bits 7-6 = control (00 STOP/01 RESET/
                            ; 10 START/11 FRAME - PC resets to 0 every
                            ; vblank in FRAME mode), bits 2-0 = index
                            ; high bits
TM_CTRL_ON      equ %11001000   ; enable, 80x32, attributes, text mode
PAL_TM_FIRST    equ $30     ; auto-increment on, tilemap first palette
NR_PAL_VALUE8   equ $41     ; 8-bit RRRGGGBB palette register. Only READ
                            ; here - pair matching compares the stored
                            ; RRRGGGBB byte. Named for what it is because
                            ; the core's WRITE path on this register sets
                            ; the 9th bit to (B1 OR B0), which is the rule
                            ; pal_colour reproduces in software.
TM_MAP          equ $6000   ; 80x32x2 = 5120 bytes, $6000-$73FF
TM_MAP_MSB      equ $20     ; ($6000-$4000)>>8
TM_DEFS         equ $7400   ; 256 glyphs x 8 = 2048 bytes
TM_DEFS_MSB     equ $34     ; ($7400-$4000)>>8
TM_COLS         equ 80         ; 80-column/maximum width at assemble time
                                ; (buffer sizing, full-map extents); runtime
                                ; width lives in tmCols (gfxcache.asm)
TM_ROWS         equ 32
GLYPH_SPACE     equ $20
TM_ATTR_DEFAULT equ 0       ; reserved pair 0 = paper 0 (black), ink 7
                            ; (white). Pairs are allocated on demand now,
                            ; so the default, error and cursor attributes
                            ; are the three pairs reserved at boot and
                            ; never reclaimed - see tm_reserved_pairs.
TM_ATTR_ERROR   equ 2       ; reserved pair 1 = paper 3 (magenta), ink 7
                            ; (white). The fatal error bar must render
                            ; whatever state the tilemap is in, which is
                            ; exactly why it cannot depend on allocation.
TM_ATTR_CURSOR  equ 4       ; reserved pair 2 = paper 7 (white), ink 0
                            ; (black) - the block cursor's boot inverse.
                            ; Reserved for the same reason as the other
                            ; two: the cursor must be visible before any
                            ; INK/PAPER condact runs.
ULA_OFF         equ $80     ; NR_ULA_CTRL bit 7
NR_TM_TRANSP    equ $4C     ; NORMAL tilemap mode's transparent index -
                            ; an INDEX compare, applied before the
                            ; palette offset. NOT what we use: text mode
                            ; (TM_CTRL_ON bit 3) checks NR_L2_TRANSP
                            ; ($14) as a COLOUR instead. We rely on
                            ; neither - the tilemap has no transparency
                            ; at all now, see tm_clear_blank.

; --- Layer 2 transparency: a COLOUR and an INDEX, deliberately separate ---
; These were one constant (TM_TRANSP_ATTR) doing both jobs plus a third,
; which is what tied Layer 2's transparent colour to a tilemap attribute
; encoding. Never merge them again.
;
; THESE VALUES ARE SYNC-CHECKED - this file is canonical, and if any
; value moves, all its copies move together. tests/build-tests.ps1
; (Assert-TranspConstantsInSync) parses every site and fails on drift:
;   colour: here / authoring-kit/lib/nxv2enc.py L2_TRANSPARENT_BYTE0 /
;     authoring-kit/lib/palcheck.ps1 $TRANSP /
;     authoring-kit/externs/fade/fade.asm TRANSP
;   index:  here / palcheck.ps1 $RESERVED
;   dodge:  here / fade.asm TRANSP_DODGE / nxv2enc.py L2_DODGE_BYTE0 /
;     palcheck.ps1 $DODGE / tests/art/mkpalcard.py TRANSP_DODGE
L2_TRANSP_COLOUR equ $E3    ; RGB332 COLOUR written to NR_L2_TRANSP, and
                            ; stamped into L2_TRANSP_INDEX. $E3 is the
                            ; hardware reset value and 24-bit 0xE000C0
                            ; in a paint program. The compare is against
                            ; the TOP 8 BITS of the 9-bit entry, so TWO of the 512
                            ; RGB333 colours are transparent - the 9th bit
                            ; cannot rescue an entry, which is why
                            ; l2_palette_load must dodge colliding art.
                            ; Sprites already use $E3 via NR $4B's own
                            ; reset default (overlay0.asm), so this makes
                            ; the whole interpreter consistent.
L2_TRANSP_INDEX  equ 255    ; PIXEL VALUE the interpreter writes to punch
                            ; a hole in a Layer 2 surface. NOT a colour
                            ; and NOT related to any tilemap attribute.
                            ; Authors supply art quantized to 255 colours,
                            ; so index 255 stays free for transparency.
L2_TRANSP_DODGE  equ L2_TRANSP_COLOUR+4
                            ; substitute COLOUR written wherever art
                            ; would collide with L2_TRANSP_COLOUR: one
                            ; step up the 3-bit green field (0 -> 1,
                            ; displayed 0 -> 36), hue and blue kept.
                            ; Perceptually closer than the blue axis
                            ; can get (any blue-high change is two
                            ; steps of 0-7 blue), and the same escape
                            ; nxv2enc.py's lattice remap picks for
                            ; pure magenta. +4 is a green step ONLY
                            ; while the green field of
                            ; L2_TRANSP_COLOUR is 000 - asserted:
    ASSERT (L2_TRANSP_COLOUR & %00011100) == 0
                            ; And the low two bits (blue 2-1) must
                            ; be non-zero: pal_colour's exempt path
                            ; hardcodes E=1 for the ninth blue bit,
                            ; which is (B1 OR B0) and so is only
                            ; correct while those bits are set.
    ASSERT (L2_TRANSP_COLOUR & 3) != 0

TXT_TRANSP_COLOUR equ L2_TRANSP_COLOUR
                            ; The ONE logical INK/PAPER value that is
                            ; allowed to reach the transparent colour,
                            ; so text can ask for transparent paper.
                            ; Derived, not a magic 227: logical colours
                            ; 16-255 encode to their own RRRGGGBB, so
                            ; the number that produces the transparent
                            ; colour IS that colour's byte. If
                            ; L2_TRANSP_COLOUR ever moves this follows
                            ; it. Every OTHER route to the transparent
                            ; value is shifted to L2_TRANSP_DODGE by
                            ; pal_colour, which is what stops classic
                            ; colour 11 (bright magenta) rendering as a
                            ; hole. BORDER is unaffected in practice:
                            ; NR $4A is final output and is never
                            ; compared against NR $14, so BORDER 227
                            ; renders magenta rather than transparent.

; --- Banking skeleton (sub-project 3) ---
DDB_PAGE_FIRST  equ BANK_DDB_FIRST*2  ; 8K pages 32..39
BANK_OVL0       equ 28      ; overlay page 0 lives in bank 28 (lower 8K)
OVL0_PAGE       equ BANK_OVL0*2
OVL_ORG         equ $E000
OVL_LIMIT       equ $FE00   ; overlay ASSERT bound. $F800 was a first-day margin
                            ; (b2a93ca), never a reservation: nothing is placed above
                            ; it in any page. 512 bytes to $FFFF kept back on purpose.
OVL1_PAGE       equ BANK_OVL0*2+1     ; overlay page 1: upper 8K of the same bank
BANK_OVL2       equ 29      ; overlay page 2 lives in bank 29 (lower 8K)
OVL2_PAGE       equ BANK_OVL2*2
VID_PAGE        equ BANK_OVL2*2+1     ; video code page (SP13 T1): the upper 8K of
                            ; bank 29, the ONLY page in the overlay-
                            ; reserved bank range (28/29) with no equate
                            ; yet - bank_table_init (banks.asm) never
                            ; marks banks 28/29 BT_FREE (the pool starts
                            ; at BANK_POOL_B), so this page is outside
                            ; the allocator entirely, exactly like 56-58.
                            ; Costs zero resident bytes: SAVENEX AUTO
                            ; (main.asm) picks up any page with assembled
                            ; content, so populating it via video.asm's
                            ; own `MMU 7, VID_PAGE, OVL_ORG` + `INCLUDE`
                            ; is the whole main.asm change needed - see
                            ; the SP13 Task 1 report for the verification.
DATA_WINDOW     equ $C000   ; slot 6 window base (8K)

; --- Layer 2 (sub-project 4) ---
NR_L2_BANK      equ $12     ; starting 16K bank of Layer 2 (bits 6-0)
NR_L2_CTRL      equ $70     ; bits 5-4 resolution, bits 3-0 palette offset
NR_L2_TRANSP    equ $14     ; transparent COLOUR (Layer 2/ULA/LoRes), compared
                            ; against the top 8 bits of the final colour, so
                            ; 2 of 512 RGB333 colours match any value - NOT
                            ; an index despite how some register tables
                            ; label it
NR_LAYERS       equ $15     ; bits 4-2 S/L/U layer priority (alias of
                            ; NR_SPRITES - same register, different role here)
L2_PORT         equ $123B   ; bit 1 Layer 2 visible, bit 0 write paging slot0
                            ; - NOT used for enable/disable (see l2_enable's
                            ; comment, overlay2.asm): a bare enable write also
                            ; zeroes this port's other live bits (video-RAM
                            ; bank select etc) every time; NR_DISPLAY_CTRL
                            ; bit 7 is the alias actually used instead
PAL_L2_FIRST    equ $10     ; NR_PAL_CTRL: auto-inc on, Layer 2 first palette
                            ; (edit + active display)
; SP14a T2: true palette double-buffering. NR $43 bits 6-4 = edit target
; (which bank $44 writes land in), bit 2 = display select (which bank is
; scanned out) - INDEPENDENT fields. The two "locked" constants below
; mirror PAL_L2_FIRST's shape (edit==display,
; both pointed at the same bank) so vidPalCtrl (video.asm) always holds
; one of these two values between frames - "the bank currently on screen,
; also the edit target if nothing else is asked". EDIT_SECOND/EDIT_FIRST
; are the "invisible write" values (edit the OTHER bank, display left
; alone): note EDIT_SECOND = PAL_L2_FIRST XOR $40 and EDIT_FIRST =
; PAL_L2_SECOND XOR $40 - flipping only the edit-target field's top bit
; (bit6, 001<->101) never touches bit2 (display) - video.asm's vid_apply_
; palette uses this XOR instead of a branch (smaller, and it is exactly
; the "leave display untouched" operation the design note calls for).
; Flipping vidPalCtrl XOR $44 (bit6+bit2 together) moves BOTH edit and
; display to the other bank in one step - the flip site's own toggle.
PAL_L2_SECOND      equ $54  ; edit=L2 second, display=L2 second (locked)
PAL_L2_EDIT_SECOND equ $50  ; edit=L2 second, display=L2 first (unchanged)
PAL_L2_EDIT_FIRST  equ $14  ; edit=L2 first, display=L2 second (unchanged)
NR_L2_CLIP      equ $18     ; Layer 2 clip window (X1,X2,Y1,Y2 - index-
                            ; sequenced); guide: "reads and writes"
NR_CLIP_IDX     equ $1C     ; write bit0 = 1 resets the L2 clip index
NR_L2_XOFS      equ $16     ; Layer 2 X pixel scroll offset (low 8 bits)
NR_L2_YOFS      equ $17     ; Layer 2 Y pixel scroll offset
; The 9th X bit: NR $71 bit 0 = MSB for X pixel offset, used only for
; 320x256 and 640x256 modes (together with $16, full 319-pixel offsets
; are available); read-write. Bits 7-1 reserved, must be 0. Mode-0
; (256x192) ignores it.
NR_L2_XOFS_MSB  equ $71
; Read-only raster position: $1E = MSB, $1F = the eight LSBs of the
; line currently being drawn. Used by the DEBUG scroll probes to place
; a register write at a known point on the visible raster instead of a
; CPU-speed-dependent delay loop.
NR_RASTER_MSB   equ $1E
NR_RASTER_LSB   equ $1F
; DEBUG PLAY= instrument (src/video.asm vid_rl_poll): how many decode
; chunks pass between raster reads. Chunks are at most 256 bytes, so 16
; of them is well under a millisecond of decode - an order of magnitude
; inside one 50Hz field, which is what the wrap detection needs. Also
; drives vidRlSpinDiv, the same cadence applied to the pace-spin/pump
; wait-loop poll sites (Phase 2-POLL causation probe, 2026-08-09) - see
; the safety-floor arithmetic at vidRlSpinDiv in video.asm.
VID_RL_DIV      equ 16

; --- Engine (sub-project 3) ---
PROC_DEPTH      equ 10
PREC_SIZE       equ 5       ; proc(1) entryPtr(2) condactPtr(2)
                            ; the done state is NOT per level - it is the
                            ; single isDone cell (engine.asm), as in both
                            ; reference interpreters
OBJ_SIZE        equ 6
OBJ_NOT_CREATED equ 252
OBJ_WORN        equ 253
OBJ_CARRIED     equ 254
LOC_HERE        equ 255
FLAG_CARRIED_CT equ 1
FLAG_GFLAGS     equ 29           ; fGFlags: bit 7 graphics available,
                                 ; bit 0 mouse present. Tested as
                                 ; HASAT GMODE (247) / HASAT MOUSE (240)
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
; flag 53 bit masks. Bit 7 (something was listed) and bit 6 (continuous
; listing) are V2 and are handled where they are used; the five below
; are DAAD V3 (PRP013 V3-01, PCDAAD condacts.pas/parser.pas) and are
; live only when ddbVer says 3.
F53_DOALLNONE   equ $01     ; DOALL has not found an object yet
F53_ALTFLAGS    equ $02     ; attribute bank based at flag 91, not 59
F53_NOPRONOUN   equ $04     ; no enclitic pronouns for verbs >= 240
                            ; (deferred D3 - NextDAAD has no enclitic
                            ; pronoun machinery to suppress)
F53_PREPFIRST   equ $10     ; a preposition arrived before noun1
F53_UNRECWRD    equ $20     ; an unrecognised word followed the verb
FLAG_COLOC      equ 54
FLAG_COWEI      equ 55
FLAG_COCON      equ 56
FLAG_COWR       equ 57
FLAG_COATT      equ 58
FLAG_KEY1       equ 60           ; INKEY key code; FLAG_KEY1+1 (61) is
                                 ; fKey2, cleared whenever 60 is written
FLAG_SCMODE     equ 62           ; fScMode: absolute screen mode byte
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
AUD_PAGE_LO     equ BANK_AUDIO_FIRST*2      ; audio bank, lower 8K
AUD_PAGE_HI     equ BANK_AUDIO_FIRST*2+1    ; audio bank, upper 8K
AUD_PLAYER_ORG  equ $C000
AUD_SFB_ORG     equ $D000   ; effects bank (2K)
AUD_SONG_ORG    equ $D800   ; current song
AUD_SONG_MAX    equ $27E0   ; 10208 bytes ($D800-$FFDF)
AUD_STATE       equ $FFE0   ; audFlags/beep state/song number

; --- SP8 sampled sound ---
DMA_PORT        equ $6B     ; zxnDMA, datagear port decode
DAC_PORT        equ $DF     ; SpecDrum-compatible mono DAC (all 4 DACs)
DAC2_PORT       equ $B3     ; DAC B+C combined - centered mono, the second
                            ; pair beside $DF (A+D); em00k's CTCAudio port
                            ; table lists it as valid. Channel 2's DAC port.
; DAC signedness: UNSIGNED everywhere on the CPU-OUT path. The DAC silence/park
; value is the unsigned midpoint $80, unconditionally - there is no build toggle.
; Confirmed by FPGA source (soundrive.vhd resets the DACs to $80, sums unsigned),
; real hardware listens, and CSpect (the old XOR $80 build was the distorted one).
; The retired zxnDMA write path wanted signed data; that path is gone with it.
DAC_SILENCE     equ $80
NR_PERIPH2      equ $06     ; peripheral 2: bit 3 = Multiface enable - the raw
                            ; streaming path (video.asm) clears it for the
                            ; duration of a stream (a Multiface trap could
                            ; issue filesystem I/O mid-SD-transaction and
                            ; lock up)
NR_PERIPH3      equ $08     ; peripheral 3: bit 3 = 8-bit DACs on,
                            ; bit 1 = Turbo Sound on (both hard-reset 0)
NR_VIDEO_TIMING equ $11     ; bits 2:0 = video timing mode 0-6 (VGA0-6); a write
                            ; of 7 stores 0, so this reads back 0-6 only -
                            ; selects the FPGA system clock the CTC divides
; SP10 CTC per-sample DAC feed (replaces the SP8 DMA sample engine). The CTC
; channel input clock IS the video-mode-dependent FPGA system clock (28-33 MHz,
; nextreg $11), NOT a fixed reference - so the time constant is derived per
; video mode at load time AND on every rewind re-commit (aud_ctc_params and
; aud_clk16_tab, SFX_PAGE - moved from overlay1 by the 2026-08-10 fresh-TC
; ruling so a re-commit can reach the table without a cross-page hop).
; Prescaler /16 when the /16 time constant fits 8 bits (rate >= clk16>>8,
; per-mode), /256 below - see aud_ctc_params. Inherent worst-case pitch
; error ~6% (1/16) in the narrow
; TC=16 band just below each mode's crossover - CTC 8-bit-TC quantisation,
; shared by the reference engines. Confirmed against playvid + em00k CTCAudio:
; "28,000,000 / 16 / 15625 = 112".
AUD_CTC_PORT    equ $183B   ; CTC channel 0 (lowest = highest IM2 priority; ch3=joystick)
AUD_CTC2_PORT   equ $193B   ; CTC channel 1 - SFX channel 2's per-sample timer
    ASSERT AUD_CTC2_PORT == AUD_CTC_PORT + $0100   ; audio_init's CTC2 reset
                            ; reaches this port by `inc b` off AUD_CTC_PORT's
                            ; already-loaded BC, not by loading AUD_CTC2_PORT
                            ; itself - this pins that shortcut's assumption so
                            ; a future edit to either constant fails the build
                            ; instead of silently resetting the wrong channel
AUD_CTC_RESET   equ $03     ; control word: soft reset (D1) + no TC (D2=0); written
                            ; twice = the Next's unknown-state channel reset (ports.txt)
AUD_CTC_CW16    equ $85     ; %10000101: int en, timer, /16, auto-trig, TC follows, control
AUD_CTC_CW256   equ $A5     ; %10100101: as CW16 but prescaler /256
; prescaler crossover is per-video-mode (clk16>>8), computed in aud_ctc_params -
; a fixed constant would clamp sharply on the faster clocks
AUD_RATE_MIN    equ 3500    ; validated sample-rate floor (aud_load_wav)
AUD_RATE_MAX    equ 20000   ; the 1K ring holds > 1 frame of this rate
; Effects stream through a fixed 24K window: no design element caps
; effect length against RAM (AUD_SMP_MAX, the old 1MB payload ceiling,
; went with it - SP18 item 7 Task 5). aud_load_wav keeps only the
; 24-bit sanity bound (data size byte 3 nonzero = absurd, size 0 =
; malformed).
AUD_STRTAB_MAX  equ 128     ; stream page-table capacity (128 x 8K =
                            ; 1MB per stream; one table per client)
SMP_FLOOR_FIRST equ 25      ; audio floor: banks 25-27. Since SP18 item 7
SMP_FLOOR_LAST  equ 27      ; Task 5 these hold the two channels' effect
                            ; windows PERMANENTLY (see SFX_WIN_PAGES
                            ; below); aud_sfx_init marks them
                            ; BT_USED at boot so aud_banks_claim's floor
                            ; pass (still used by the AYS stream client)
                            ; always skips them and takes pool banks
SMP_PAGE_FIRST  equ (BANK_AUDIO_FIRST+1)*2  ; next bank's lower 8K; floor banks' first page
AUD_STAGE0      equ $7C00   ; ring base, bank 5 upper region - ALWAYS mapped
                            ; (MMU3), above divMMC's $0000-$3FFF, free after
                            ; TM_DEFS ($7400-$7BFF); ends exactly at $8000
AUD_STAGE_RING  equ 1024    ; power-of-two ring $7C00-$7FFF: the CTC ISR plays
                            ; smpPlayPtr, the 50Hz tick refills SMPB_W from the
                            ; page-table source. 1K = 51ms at 20kHz - ample vs
                            ; the 20ms refill period. Base $7C00 is 1K-aligned so
                            ; the ISR wraps with a branchless AND/OR mask on H.
    ASSERT AUD_STAGE_RING >= 256 && (AUD_STAGE_RING & (AUD_STAGE_RING-1)) == 0   ; power of two, multiple of 256: wrap masks are (ring-1)>>8
    ASSERT AUD_STAGE0 + AUD_STAGE_RING == $8000   ; ISR wrap tests H == $80
    ASSERT AUD_STAGE_RING >= 2*(AUD_RATE_MAX/50)  ; ring > 1 frame of consumption
                            ; so a tick always refills before the ISR underruns

; SP18 item 7 Task 10: channel 2's own 1K DAC ring. AUD_STAGE2 is a
; CANDIDATE address, not yet pinned - Task 9's static sweep clears
; $4400-$47FF (inside the classic ULA pixel screen, believed dead once
; the tilemap/Layer 2 are up) as buildable, but OP1 stays open pending
; the owner's V1 silicon placement check on real hardware.
; Shippability gate, not a build gate: ctc2_isr reads/writes this
; range regardless, and nothing DRIVES channel 2 until Task 11.
AUD_STAGE2      equ $4400   ; candidate - OP1/V1 gate before shipping
AUD_STAGE2_RING equ 1024    ; same power-of-two ring shape as AUD_STAGE_RING
    ASSERT AUD_STAGE2_RING >= 256 && (AUD_STAGE2_RING & (AUD_STAGE2_RING-1)) == 0   ; power of two, multiple of 256: wrap masks are (ring-1)>>8
    ASSERT (AUD_STAGE2 & (AUD_STAGE2_RING-1)) == 0
    ASSERT AUD_STAGE2_RING >= 2*(AUD_RATE_MAX/50)

; --- SP18 item 7: per-channel sampled-effect pump state ----------------
; One block per channel, in AUD_PAGE_LO (48) data space - pinned in slot 6
; for the whole of aud_tick, so pump code may touch it at any point with
; no slot-restore ordering. IX = block base inside aud_smp_* routines.
SMPB_FLAGS    equ 0    ; bit0 active, bit1 looping, bits 2-5 below
SMPB_TABIDX   equ 1    ; consumer window-page index
SMPB_OFF      equ 2    ; dw: consumer offset in current page (0-$1FFF)
SMPB_REMAIN   equ 4    ; dw+db: 24-bit payload bytes remaining
SMPB_LEN      equ 7    ; dw+db: 24-bit payload length (loop rewind)
SMPB_P        equ 10   ; dw: DAC-ring PLAY offset snapshot
SMPB_W        equ 12   ; dw: DAC-ring WRITE offset
SMPB_RINGH    equ 14   ; DAC ring base high byte ($7C ch1 / $44 ch2 cand.)
SMPB_RINGM    equ 15   ; wrap mask high byte ((ring-1)>>8 = $03 for 1K)
SMPB_PLAYPTR  equ 16   ; dw: address of the channel's smpPlayPtr (resident)
SMPB_WRITEPTR equ 18   ; dw: address of the channel's smpWritePtr
SMPB_CTCPORT  equ 20   ; dw: CTC channel port ($183B / $193B)
SMPB_DACPORT  equ 22   ; db: DAC port ($DF / $B3)
SMPB_CTCCTRL  equ 23   ; db: latched CTC control word for this effect
SMPB_CTCTC    equ 24   ; db: latched CTC time constant
SMPB_WINTAB   equ 25   ; dw: address of this channel's window descriptor
SMPB_DEPTH    equ 27   ; dw: staged-minus-consumed 512-byte window blocks
SMPB_STRM     equ 29   ; dw: address of this channel's stream cell group
                       ;     (SFX_PAGE, SFXS_* layout in streamfx.asm);
                       ;     the open and the refiller hold it in IY, which
                       ;     is how one body serves both channels
SMPB_STAMP    equ 31   ; dw: frameCounter when aud_smp_start last started
                       ;     an effect here. The allocator's tie-break -
                       ;     between two equally stealable channels the
                       ;     OLDEST start loses. Read as an unsigned
                       ;     frameCounter-minus-stamp age: ages beyond
                       ;     65535 frames (~21.8 min) alias, so oldest-
                       ;     first may steal the wrong channel - bounded
                       ;     (a steal, not a hang) and accepted, not a
                       ;     case needing special-casing here.
SMPB_KEEP     equ 33   ; db: effect number this channel's window holds
                       ;     (0 = nothing). The OVERLAY-visible half of
                       ;     the keep-last cache: SFXS_KEEP is the same
                       ;     number on SFX_PAGE, which overlay1 cannot
                       ;     read (they share the slot-7 window), so the
                       ;     allocator and the free-rewind test use this
                       ;     copy. With SMPB_FLAGS bit 3 set it means the
                       ;     WHOLE effect is resident - a re-trigger of
                       ;     that number costs no card traffic at all.
SMPB_RATE     equ 34   ; dw: this effect's WAV sample rate, latched by
                       ;     aud_smp_start from audReqSmpRate. A rewind
                       ;     re-commit re-derives audReqSmpCtrl/Tc from
                       ;     the LIVE video-timing mode instead of
                       ;     replaying stale SMPB_CTCCTRL/CTCTC: a mode
                       ;     change between triggers must not replay the
                       ;     old pitch.
SMPB_SIZE     equ 36   ; (was 34 before the 2026-08-10 fresh-TC ruling
                       ;     added SMPB_RATE; 14 before SP18 item 7
                       ;     Task 2's parameterisation)
; SMPB_FLAGS bit semantics (settled by the SP18 item 7 Task 5 review
; ruling: bits 0/1 are PLAYBACK state, bits 2-4 describe the WINDOW and
; the channel's CACHE, and a deliberate stop must not throw the cache
; away or a re-trigger stops being cheap):
;   bit 0 ACTIVE   - playback. Set by aud_smp_start, cleared by any stop.
;   bit 1 LOOPING  - playback. Ditto.
;   bit 2 STREAMING- the refiller owes this channel blocks. Set by
;                    sfx_stream_open on a file too big for the window.
;                    CLEARED BY A STOP: it is the refiller's own gate and
;                    a stopped channel must not be refilled. The cached
;                    stream itself survives the stop and is recoverable
;                    from the stream cells - see below.
;   bit 3 COMPLETE - the whole file is staged in the window. PRESERVED
;                    ACROSS A STOP: the window keeps its contents, so the
;                    re-trigger rewind stays free, and the pump's rewind
;                    needs the bit after a stop/restart cycle.
;   bit 4 REWIND   - a loop rewind happened on a STREAMING channel, so
;                    the window no longer holds the payload start. The
;                    refiller must re-stage from the run list at the
;                    anchor block and clear this bit before the consumer
;                    may take another byte; SMPB_DEPTH is 0 meanwhile.
;                    Never set on a COMPLETE channel (its window is
;                    permanent, so its rewind is served from RAM).
;   bit 5 PINNED   - an SFX sub 11-14 reserved this channel for itself
;                    (SP18 item 7 Task 12). AUTO-ALLOCATION NEVER TOUCHES
;                    A PINNED CHANNEL, idle or not: the pin is a
;                    reservation, not a busy flag. Only subs 15/16 (stop
;                    that channel) and sub 5 (stop everything) clear it,
;                    so neither a stop from the video abort nor an error
;                    eviction releases it. Owned by the allocator alone -
;                    aud_smp_start and aud_smp_stop both preserve it.
; Bits 2-4 are the LOADER's and the REFILLER's, bit 5 the ALLOCATOR's;
; aud_smp_start preserves 2-5 when it writes bits 0/1; aud_smp_stop keeps
; bits 3 and 5 and clears the rest; only sfx_stream_open's refusal funnel
; and an eviction by a DIFFERENT effect number invalidate the cache
; (bits 2-4 all cleared, bit 5 untouched).
; Distinguishing a stopped-but-cached channel from an idle/empty one is
; therefore: bit 3 set = a COMPLETE window is cached; the channel's own
; SFXS_HANDLE != $FF = a stream (handle + hot filemap) is cached, with
; SFXS_KEEP holding its effect number; neither = idle/empty. Both stream
; cells are per channel, reached through SMPB_STRM. SMPB_KEEP above
; mirrors SFXS_KEEP for readers that cannot map SFX_PAGE.

; --- SP18 item 7: the per-channel effect window ------------------------
; Each channel consumes its effect through a CIRCULAR window of
; SFX_WIN_PAGES 8K pages out of the audio floor banks 25-27. This
; replaces "the whole payload is resident in a claimed page list": files
; up to SFX_WIN_BYTES stage whole (COMPLETE - the free hybrid, resident
; semantics and free re-trigger preserved), larger files stage their
; first SFX_WIN_BYTES and the refiller tops the window up while it plays
; (STREAMING). 512-byte card blocks never straddle a page: 16 per page.
SFX_WIN_PAGES equ 3
SFX_WIN_BYTES equ SFX_WIN_PAGES*$2000   ; 24576 = 1.5 s at 16 kHz
SFX_WIN_BLKS  equ SFX_WIN_PAGES*16      ; 48 card blocks in a full window
; Window descriptor, one per channel in page-48 data (SMPB_WINTAB points
; at it): the SFX_WIN_PAGES page numbers, then the consumer's payload
; START ANCHOR, then the DEPTH that anchor implies. Blocks stage VERBATIM
; from file offset 0 (WAV header included), so the consumer starts at the
; data chunk's own offset and every loop rewind returns to exactly that
; position. All three live here, not in the SFX_PAGE stream cells,
; because the pump is page-48 code and cannot see SFX_PAGE.
SFXW_STIDX    equ SFX_WIN_PAGES         ; db: start window-page index
SFXW_STOFF    equ SFX_WIN_PAGES+1       ; dw: start offset inside it
SFXW_DEPTH0   equ SFX_WIN_PAGES+3       ; dw: SMPB_DEPTH as it stood at
                                        ; the anchor when the open staged
                                        ; the window. A COMPLETE channel's
                                        ; window is permanent, so its loop
                                        ; rewind restores this figure
                                        ; verbatim (see aud_smp_copy).
SFXW_SIZE     equ SFX_WIN_PAGES+5

; --- DMA picture copies (SP11 Task 2) ---
; zxnDMA one-shot mem-to-mem chunk copies for Layer 2 picture work
; (overlay2.asm: dma_copy, l2_copy_back_front, gfx_row_copy256, gfx_row_fetch),
; unconditional since SP14a T4's follow-up wave retired the -NoDmaGfx
; CPU-only A/B lever (owner hardware test, 2026-07-21 - see dma_copy's
; own header, overlay2.asm). DMA_PORT ($6B, above) is the same physical
; port the retired SP8 sample engine used - that engine is fully gone
; (SP10 CTC pivot; see DAC_SILENCE's comment above), so dma_copy is now
; its only consumer. See dma_copy's own header comment (overlay2.asm)
; for the frame-ISR MMU6/7 hazard that forces every chunk into its own
; DI bracket, one-shot CONTINUOUS mode - never burst, auto-restart, or
; a live status/counter read.
DMA_CHUNK_MAX   equ 256     ; zxnDMA one-shot cap per arm - dma_copy splits
                            ; any longer request into pieces this size or
                            ; smaller. Cut to 128 on 2026-08-03 to shorten
                            ; the blocking window, then RESTORED to 256 the
                            ; same day once silicon showed the window's
                            ; length is not the governing quantity: the DAC
                            ; feed is admitted INSIDE a running transfer by
                            ; nextreg $CD bit 0 (im2_init), so a longer
                            ; chunk simply admits more CTC edges and each is
                            ; still serviced on time. The row copy and the
                            ; surface copy hand dma_copy exactly 256 bytes,
                            ; one chunk each; gfx_row_fetch hands a whole
                            ; row: 256 bytes for 256-wide art (one chunk,
                            ; never split), or 320 bytes for 320-wide art
                            ; (two chunks). A 320-wide row cut at a page
                            ; edge instead hands the leftover part: 64, 128,
                            ; 192 or 256 bytes, a multiple of 64 whose
                            ; shortest equals GFX_DMA_MIN_LEN (one chunk).
                            ; 256 still cuts the two 256-byte calls from two
                            ; chunks
                            ; to one: ~780 T saved per call, about
                            ; -5.4 ms on a location DISPLAY 0 and -10.7 ms
                            ; on GFX 0/1 at 256x192. A ONE-CONSTANT KNOB
                            ; NOW, but it did not use to be one - dma_copy
                            ; derived the block length as
                            ; `high DMA_CHUNK_MAX` (zero for any cap under
                            ; 256), and its 128-era replacement pinned the
                            ; high byte to a constant 0 (which barred 256).
                            ; The current 16-bit form is general over
                            ; 1..256 and ASSERTs both ends; read dma_copy's
                            ; header before changing it anyway.
GFX_DMA_MIN_LEN equ 64      ; design threshold: below this LDIR wins on
                            ; programming overhead (documentation only -
                            ; no call site moves fewer bytes than this, so
                            ; none needs a runtime length check)

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
WIN_LINES       equ 9       ; lines printed since last pause
WIN_ATTR        equ 10      ; resolved tilemap attribute for this window's
                            ; ink/paper. Written only when the colours
                            ; change, so win_attr - which runs for every
                            ; character printed - is a plain fetch and
                            ; never allocates.
WIN_ATTRINV     equ 11      ; the block cursor's resolved inverse (ink and
                            ; paper swapped) for this window. Per-window,
                            ; not global: WINDOW condacts and
                            ; inp_stream_push (flag 41) can make the input
                            ; cursor's window differ from whichever window
                            ; last set colours. Written alongside WIN_ATTR
                            ; by win_attr_resolve.
WIN_SIZE        equ 12
WINDOW_COUNT    equ 8

; --- Mouse (SP10 Task 5) ---
; Kempston mouse ports, cross-checked against CSpect's own emulation
; (see overlay0.asm's h_mouse header).
KMOUSE_X_PORT   equ $FBDF   ; IN: 0-255, wraps; increases on RIGHTWARD
                            ; movement
KMOUSE_Y_PORT   equ $FFDF   ; IN: 0-255, wraps; increases on UPWARD
                            ; movement - opposite of screen rows, invert.
                            ; Same 16-bit number as our sample-playback
                            ; DAC write in interrupts.asm's ctc_isr
                            ; ("out (DAC_PORT),a" is the Z80's raw
                            ; OUT (n),A form, which drives A on the
                            ; UPPER address byte - so whenever a played
                            ; sample byte equals $FF, that single OUT
                            ; cycle asserts bus address $FFDF too). No
                            ; conflict: OUT vs IN are different bus
                            ; cycles, and the DAC only decodes low byte
                            ; $DF (any upper byte) while the mouse Y
                            ; port only responds to IN reads.
KMOUSE_BTN_PORT equ $FADF  ; IN: bit0 right, bit1 left, bit2 middle,
                            ; bits7-4 wheel 0-15 (unused here)
NR_SPRITE_SEL   equ $34    ; select sprite ATTRIBUTE index for $35-$39
                            ; (independent of port $303B unless port
                            ; $09 bit4 "lockstep" is set - never is here)
NR_SPRITE_X     equ $35    ; low 8 bits of X (9th bit: NR_SPRITE_ATTR b0)
NR_SPRITE_Y     equ $36    ; low 8 bits of Y (9th bit: NR_SPRITE_ATTR2 b0)
NR_SPRITE_ATTR  equ $37    ; b7-4 palette offset, b3 Xmirror, b2 Ymirror,
                            ; b1 rotate, b0 = X coordinate bit 8
NR_SPRITE_PAT   equ $38    ; b7 visible, b6 byte4-enable, b5-0 pattern idx
NR_SPRITE_ATTR2 equ $39    ; byte 4: b7-6 00=8-bit anchor, b5 unified,
                            ; b4-1 scale (0=1x), b0 = Y coordinate bit 8
NR_SPRITE_ATTR2_INC equ $79 ; byte 4 with NR $34 auto-increment
SPRITE_IDX_PORT equ $303B  ; pattern/attribute upload slot select (full
                            ; 16-bit port, any value works for $57/$5B
                            ; below - low byte of THIS port is decoded
                            ; exactly, unlike the streaming ports)
SPRITE_PAT_PORT equ $005B  ; pattern upload stream (256 B/sprite, auto-
                            ; inc slot; low byte $5B only is decoded, so
                            ; B=0 here doubles as OTIR's 256-byte count)
MOUSE_X_MAX     equ 319    ; accumulated mouse position ceiling (320-
                            ; wide sprite/mouse plane)
MOUSE_Y_MAX     equ 255    ; accumulated mouse position ceiling (256-
                            ; tall plane, screen-downward)

; --- Video (NXV v2, SP15 - v1 DELETED; stage 3c player: resident +
; ring streaming + direct-serve) ---
; This comment block and the constants below are the byte-identical
; player-side transcription of the frozen NXV v2 format (core 3.02.04);
; the encoder-side twin lives in authoring-kit/lib/nxv2enc.py
; (HDR_OFF_*), and authoring-kit/lib/nxv2dec.py is the executable spec.
;
; --- NXV v2 header (block 0, 512 bytes; multi-byte fields LE) ---
;   offset  size  field
;     0      5    magic "NXVID"
;     5      1    version = 2 (v1 files, version 1, are rejected -
;                 VID FMT - the v1 player is deleted)
;     6      1    width code: 0 = 256 (mode-0), 1 = 320 (mode-1)
;                 (NOTE: INVERTED vs the old v1 shape byte)
;     7      1    height: 1-255 lines, 0 = 256 (free heights - no
;                 block-alignment rule any more)
;     8      1    fps*10 low byte - informational only (pacing derives
;                 from audio bytes, as v1 proved)
;     9      1    audio channels - MUST BE 2. Mono (1) was a supported
;                 pairing until 2026-08-03 and is now REFUSED at open
;                 (VID FMT?); see NXV2_OFF_ACHAN below. The field stays
;                 in the wire format at its frozen offset
;    10      2    audio rate Hz LE (15625, the stereo pair rate)
;    12      1    flags: bit0 = delta stream (always 1 in v2), bit1 =
;                 direct-serve hint (HONOURED from 3c: the file is
;                 served SD-to-surface, no ring - nxv2_open_body
;                 .direct_setup), bit2 = RESERVED band-palette
;                 experiment, bit3 = RETIRED OCOPY capability (see
;                 NXV2_FLAG_OCOPY), bits 4-7 reserved 0 (any bit other
;                 than 0/1 set = VID FMT? at open - forward hygiene)
;    13      1    keyframe policy byte (encoder bookkeeping, ignored)
;    14      3    frame count LE24
;    17      2    audio bytes/frame LE (REAL, pre-pad; the wire block
;                 is this rounded up to a 512 multiple). v2.0 PLAYER
;                 BOUND (SP17 T10, circular feed): the audio feed is
;                 ONE circular NXV_AUD_RING (8192-byte) buffer, so
;                 open REJECTS > NXV_AUD_FRAME_MAX (3072) real
;                 bytes/frame (VID FMT?) - which needs fps >= 10.17;
;                 the encoder enforces this at encode
;                 time (audio_layout + a pack_header defence-in-depth
;                 guard). Wire field 16 bits; player capability bound
;                 3072. (Pre-T10 the feed was two fixed 1280-byte
;                 halves and the bound was 1280 - stereo floor 24.40;
;                 the 2560-byte ring that replaced them bounded it at
;                 2544 - stereo floor 12.28.)
;    19      2    ring start-margin in 512B blocks LE. ADVISORY to
;                 the v2.0 player: it prefills the ENTIRE ring (which
;                 dominates any margin the ring could honor) and
;                 never reads the field as a fill target - it is only
;                 range-checked at open (margin <= file blocks;
;                 larger = corrupt header, VID FMT?).
;    21      2    per-frame payload cap in blocks LE. LOAD-BEARING
;                 for streaming AND direct-serve: the ring gate paces
;                 on it and the direct per-frame section bound is
;                 cap + apad + 1 blocks - open validates it in
;                 1..NXV2_STRM_CAP_MAX (a lying/absent cap is a
;                 corrupt header, VID FMT?); resident ignores it.
;    23..511      reserved 0
;
; Frame layout: [audio blocks (padded 512)] [payload blocks (padded
; 512)]. Payload = opcode stream; opcode byte VALUES are PRE-SCALED BY
; 4 so the wire byte IS the dispatch offset into the player's
; 256-aligned stub block (doc 07 dense dispatch at its floor).
NXV_MAGIC_LEN    equ 5
NXV2_VERSION     equ 2
NXV2_OFF_MAGIC   equ 0
NXV2_OFF_VERSION equ 5
NXV2_OFF_WIDTH   equ 6      ; width CODE (0/1), not a pixel count
NXV2_OFF_HEIGHT  equ 7
NXV2_OFF_FPSX10  equ 8
NXV2_OFF_ACHAN   equ 9      ; MONO IS WITHDRAWN (2026-08-03): refused at
                            ; open with VID FMT? if not 2. Load-bearing,
                            ; not tidiness - a mono file through the
                            ; stereo ISR would interleave one channel
                            ; across both DACs at the wrong rate. Offset
                            ; is FROZEN wire format; value is always 2.
NXV2_OFF_ARATE   equ 10
NXV2_OFF_FLAGS   equ 12
NXV2_OFF_KFPOL   equ 13
NXV2_OFF_FRAMES  equ 14     ; 3 bytes LE24
NXV2_OFF_ABYTES  equ 17     ; real (pre-pad) audio bytes/frame
NXV2_OFF_RMARGIN equ 19
NXV2_OFF_FRAMECAP equ 21

NXV2_FLAG_DELTA  equ 1      ; bit0 - must be set
NXV2_FLAG_DIRECT equ 2      ; bit1 - direct-serve hint (3c: honoured -
                            ; the delivery decision routes the file
                            ; SD-to-surface, no ring)
NXV2_FLAG_OCOPY  equ 8      ; bit3 - RETIRED offset-copy capability
                            ; (2026-08-02: both silicon arms measured
                            ; worse than plain delta). Kept NAMED and
                            ; REFUSED: a file declaring it fails cleanly
                            ; at OPEN with VID FMT?, never reaching a
                            ; decoder that no longer implements the op.
                            ; Do NOT re-use bit3 for anything else.

; Opcode values (v2 frozen set, x4-scaled). Reserved: $24/$30 (the
; retired T5a OCOPY8/OCOPY16 - decode withdrawn; a file declaring them
; is refused at open, see NXV2_FLAG_OCOPY), $2C (SCROLL, kept for
; T5b), $34-$3C, and every non-multiple-of-4/every value >= $40 - all
; rejected by the production decoder (decoder contract 1).
VOP_FEND         equ $00
VOP_SKIP16       equ $04
VOP_RUN8         equ $08
VOP_RUN16        equ $0C
VOP_COPY8        equ $10
VOP_COPY16       equ $14
VOP_PAL          equ $18
VOP_SKIP8        equ $1C
VOP_KFLIP        equ $20
VOP_KSTART       equ $28

; Max operand bytes any op header carries after its opcode byte - the
; live set carries at most 3 (RUN16: nl nh colour); the bound is held
; at the conservative 4 the T5a contract amendment introduced, so the
; window check is unchanged by the withdrawal. vid_op_edge's
; fast-fetch window check derives from this (an opcode byte at $DFxx
; takes the slow byte-fetch path unless all operand bytes provably sit
; inside the source window).
NXV2_MAX_OPERANDS equ 4

NXV_NATIVE_H_MODE1 equ 256  ; mode-1 column stride (hardware-fixed)
NXV_NATIVE_H_MODE0 equ 192  ; mode-0 line count

; Kernel crossovers - DERIVED from silicon-measured CPU/DMA timing
; coefficients (core 3.02.04), not guessed. A sub-256 chunk costs one
; DMA setup, so break-even chunk length L = setup / (body - per_byte):
;
;   RUN  fill: break-even ~70.4 B -> held at 71 (RUN is 0.003-6% of
;              painted bytes, RUN16 never emitted - low priority to
;              re-derive further)
;   COPY LDI : 53, one constant - sitting-5 crossovers 53.75 B flat,
;              67.88 / 68.61 B gapped at height 192 / 144; real-frame
;              sweeps save 1.568% of decode T against 81.
;
; The encoder's T model MIRRORS these two constants
; (authoring-kit/lib/nxv2enc.py TMODEL_COEFFS run_dma_min/copy_dma_min,
; consumed by _fill_t/_copy_t): change one, change the other in the
; same commit or the model stops predicting the player.
;
; NXV2_DMA_CHUNK: DMA burst cap per arm. The video kernels' DI brackets
; that once bounded this are gone (SP18 item 5), so the cap is now a
; byte-budget knob, not a deadline. Must stay <= 255: the single-byte
; compares in vid_chunk_dst_flat/_gap and both kernel selects depend on
; it (ASSERTed in video.asm). Held at 240 for margin against the retired
; DI mechanism; raising it further buys under 2% of corpus decode-T,
; concentrated in byte-bound clips that cannot spend it. Lowering costs
; more than raising gains: 256->128 would cost +13.3% decode-T /
; +34.0% chunks.
NXV2_DMA_CHUNK   equ 240      ; vid_chunk_all / vid_chunk_dst_flat/_gap
NXV2_RUN_DMA_MIN equ 71
NXV2_COPY_DMA_MIN equ 53
    ASSERT NXV2_COPY_DMA_MIN >= 1 && NXV2_COPY_DMA_MIN <= NXV2_DMA_CHUNK

; Ring (3a resident / 3b streaming): pool banks holding the whole
; file (resident) or the circular prefetch buffer (streaming). The
; bank list capacity covers every allocatable pool bank on a 2MB
; machine (14-15 + 36-47 + 48-111 = 78) with margin.
VID_RING_MAX     equ 80

; L2 SNAPSHOT/RESTORE (SP15, v0.3.0): the player snapshots the game's
; visible (front) Layer 2 surface + the L2 FIRST palette contents at
; open and restores both inside the exit bracket while Layer 2 is
; still hidden - a game's picture returns automatically after a
; cutscene, no post-video redraw needed. Contract:
;   - pool banks reserved UP FRONT at open, before the ring sizing:
;     0 (Layer 2 hidden pre-video - text-only games cost nothing),
;     3 (256x192 game) or 5 (320x256 game); reservation failure
;     refuses the video (verdict 2, "VID NOBANK2"), never a
;     history-dependent skip;
;   - the BACK surface is NOT snapshotted: gfx_blit renders whole
;     pictures to back then flips, so back content is scratch and is
;     UNDEFINED across a video;
;   - the palette payload is the FIRST L2 palette only (every game-
;     side palette writer targets PAL_L2_FIRST; the second palette is
;     video-only property), captured by NR $41/$44 hardware readback
;     into a page-local 512-byte buffer (vidSnapPal, video.asm);
;   - a game that hides L2, plays a video, then shows L2 without
;     drawing sees undefined pixels/palette (count 0 - was already
;     true before the snapshot existed).
VID_SNAP_MAX     equ 5      ; snapshot bank list capacity (mode-1 worst)

; 3b streaming limits: the hot filemap copy holds this many 6-byte
; DISK_FILEMAP runs (a file needing more is too fragmented to stream -
; "VID FRAG?", run .defrag); the header's per-frame payload cap is
; validated against NXV2_STRM_CAP_MAX blocks (the encoder's real caps
; top out around 110 blocks; a bigger value is a corrupt header).
VID_STRM_HOT_ENT equ 8
NXV2_STRM_CAP_MAX equ 240

NR_MMU2          equ $52    ; slot 2 ($4000-$5FFF): the decode loop's
                            ; borrowed dest window (saved/restored for
                            ; the whole playback session - the NXBEN
                            ; precedent; nothing else touches
                            ; $4000-$5FFF while a video plays)
NR_MMU3          equ $53    ; slot 3 ($6000-$7FFF): the session's
                            ; borrowed AUDIO window (SP15 3c - the
                            ; audio feed buffer moved OFF the
                            ; hot code page into one pool bank pinned
                            ; here; same capture/restore pattern as
                            ; MMU2. Safe by the same freeze arguments:
                            ; the tilemap (bank 5's TM_DEFS/map) is
                            ; hidden+isolated, the sample machinery
                            ; (AUD_STAGE0 $7C00 ring) is aborted and
                            ; its CTC vector replaced, and nothing
                            ; else reads slot 3 while a video plays;
                            ; bank 5's CONTENT is untouched - only
                            ; the CPU mapping is borrowed)
VID_DST_WIN      equ $4000  ; MMU2 dest window base
VID_AUD_WIN      equ $6000  ; MMU3 audio window base (vidAudBuf)
VID_SRC_WIN      equ DATA_WINDOW ; $C000 MMU6 source (ring) window

; Decode error codes (DEBUG report ERR=xx; outside the esxDOS range,
; alongside VID_ERR_FRAG/NOMAP/TOKEN/CMD above)
VID_ERR_OP       equ $FA    ; reserved/misaligned opcode (contract 1)
; VID_ERR_BIG ($F9) DROPPED (SP15 3b carried minor): nothing ever
; stored it - the size verdict is the open body's B=3 "VID SIZE?"
; exit, which never reaches the timeline report. 3b streaming removed
; most of the class, and the 2026-08-02 CEILING LIFT removed the rest:
; the file-level cursors count 512-byte BLOCKS now (video.asm
; vid_file_blocks), so there is NO size arm left - B=3 means only
; "the pool is below one streamed frame's need".
VID_ERR_SRCOVR   equ $F8    ; payload ran past the loaded file
                            ; (streaming: or the per-frame source
                            ; page-walk bound tripped - corrupt input)
VID_ERR_DSTOVR   equ $F7    ; cursor ran past the Layer 2 surface

; The supported audio rate - ONE since mono was withdrawn (T4 design
; step, T1's derivation method, CW16 across every video mode - see
; vidCtcTcNxvStereo, video.asm, and the task report's TC tables). Any
; other header rate = VID FMT?.
NXV_RATE_STEREO  equ 15625  ; 28,000,000/16/112 = 15625 exactly (VGA0) -
                            ; the same "nice" CTC rate em00k's CTCAudio
                            ; and this project's own SP10 music/SFX
                            ; engine already use (aud_clk16_tab.asm docs)

NXV_PAL_BYTES    equ 512    ; PAL opcode block size (NR $44 order)

; Circular audio feed: ONE ring. The ISR's read pointer (IX) free-runs
; around it (wraps at the fixed ring end), and the frame loop's writer
; chases BEHIND the reader, so capacity per frame is the WHOLE buffer
; instead of one half.
;
; RING SIZE = THE WHOLE AUDIO BANK: vidAudBuf owns a full 8 KB pool
; bank (bank_alloc -> vidAudBankC, pinned at MMU3 for the session), so
; the ring uses all of it. This keeps 2*aBytes <= NXV_AUD_RING-
; NXV_AUD_GUARD true for every legal file BY CONSTRUCTION (see
; NXV_AUD_FRAME_MAX) - a smaller ring left low-fps files room-limited,
; spending most of a frame trickling audio through the pace-spin
; instead of at the reader's own rate.
NXV_AUD_RING     equ 8192   ; the circular audio buffer (vidAudBuf) -
                            ; the entire MMU3 window $6000-$7FFF, so
                            ; the ring ends flush at the page top and
                            ; the ISR's wrap compares stay a plain
                            ; 8-bit low/high immediate pair (see
                            ; video_ctc_isr: the compare shape and its
                            ; T-state cost are IDENTICAL at any ring
                            ; size - only the two constants move)
NXV_AUD_GUARD    equ 16     ; writer keeps this many bytes clear of
                            ; the read pointer: the stereo ISR's
                            ; (ix+0)/(ix+1) pair fetch is not atomic
                            ; against the writer's LDIR byte stores,
                            ; so >= one pair (2 bytes) is REQUIRED;
                            ; the read-pointer snapshot the room
                            ; computation uses only goes stale in the
                            ; SAFE direction (the reader advances, so
                            ; true room only grows), hence 16 is a
                            ; deliberate 8x margin, not a lower bound
; Largest per-frame REAL audio size any header may declare (validated
; at open). It is NO LONGER ring-guard: the ring grew past the point
; where this bound is what limits the feed, and the binding constraint
; moved to the streaming/direct gates' BLOCK arithmetic. Those are
; 8-bit adds over 512-byte blocks (vid_strm_validate: need = cap + apad
; + 1; nxv2_open_body's ring-fit test: need + apad + 2), and with the
; header cap at its own maximum NXV2_STRM_CAP_MAX = 240 they hold iff
; apad <= 6 blocks, i.e. iff the padded audio section is <= 3072 B.
; That is a proven invariant with zero headroom today ("<= 247: no
; carry", "<= 255"), so the declarable bound is pinned to it rather
; than widened - a bound that keeps a proven invariant beats a bigger
; one that silently breaks it (ring-guard would be 8176, apad 16, and
; 240+16+1 wraps a byte).
; CONTENTION-FREE BY CONSTRUCTION: 2*3072 = 6144 <= 8176 = ring-guard,
; so EVERY legal file's next-frame feed fits the single post-present
; pump with 2032 bytes to spare. There is no room-limited regime left
; for any file the player will open.
NXV_AUD_FRAME_MAX equ 3072  ; Floor: fps > 2*15625/3072 -> >= 10.17
                            ; (was 12.28 at 2544). 320x256@12.5
                            ; (2500 B/frame) and native 24 fps
                            ; (1302) are both inside it
    ASSERT 2*NXV_AUD_FRAME_MAX <= NXV_AUD_RING-NXV_AUD_GUARD
NXV_AUD_PUMP_CHUNK equ 256  ; pace-spin trickle chunk: one pump call
                            ; copies at most this much, keeping the
                            ; release-poll latency bounded (~a block's
                            ; LDIR) while the writer chases the reader.
                            ; Also the pump's ROOM FLOOR: a room-
                            ; limited partial smaller than this is not
                            ; worth the ~1950 T pump path, so the pump
                            ; returns and lets the caller poll instead
                            ; (vid_aud_pump). Unreachable on any legal
                            ; file now - kept as the degraded-regime
                            ; and future-bound backstop
NXV_AUD_BUF_MAX  equ NXV_AUD_RING ; vidAudBuf's resident size - the
                            ; whole 8 KB session audio bank, nothing
                            ; else lives in that page

; Short-read failure during the resident ring load (the file ended
; before its own F_FSTAT size was served). Outside the esxDOS error
; range, alongside VID_ERR_FRAG/NOMAP/TOKEN/CMD above.
VID_ERR_SHORT    equ $FB

; --- Video player core - GFX/SFX dispatch (unchanged surface) ---
; GFX n 13/14 and SFX n 9/10 (PLAYFLI/PLAYFLIL) all dispatch to vid_play
; (video.asm): n = video number, sub selects play-once vs loop. h_gfx/
; h_sfx each translate their own sub-command range into vid_play's C =
; 0 (once) / 1 (loop) contract via a plain `sub base` before the cross-
; page hop (push-target/ovl_map_page trampoline, precedented by
; xpart_load_entry in overlay0.asm).
GFX_SUB_VID_ONCE equ 13
GFX_SUB_VID_LOOP equ 14
SFX_SUB_VID_ONCE equ 9
SFX_SUB_VID_LOOP equ 10

GFX_SUB_FONT     equ 16          ; NextDAAD: install font n (0 = base).
                                 ; 0-15 are all allocated by DAAD across
                                 ; its targets - 15 is XSPLITSCR on CPC
                                 ; and C64 (DRC rejects it on every other
                                 ; target) - so this starts past the
                                 ; classic block. MSX also uses 128/129.
GFX_SUB_LAYER    equ 17          ; NextDAAD: layer order. P1 0 = picture
                                 ; on top (Layer 2 above the tilemap,
                                 ; the default and what every existing
                                 ; game gets), 1 = text on top. Follows
                                 ; FONT past the classic 0-15 block.
GFX_SUB_TXTMODE  equ 18          ; NextDAAD: text width. P1 0 = 80x32
                                 ; (boot default), 1 = 40x32. Clean
                                 ; slate: map cleared, windows reset.
                                 ; Next free number past FONT/LAYER.
GFX_SUB_SPR_START equ 19    ; GFX n 19: start set n at its baked X,Y
GFX_SUB_SPR_FLAGS equ 20    ; GFX f 20: set = flag f, X = f+1 (lo) f+2 (hi), Y = f+3
GFX_SUB_SPR_STOP  equ 21    ; GFX n 21: stop set n; 255 = all

; DAC ports: four 8-bit DAC channels, A/B to the left audio channel and
; C/D to the right (soundrive-2 pairing); DAC B = $F3, DAC C = $F9 is
; the exact pair the MakeVid reference ISR uses. NR_PERIPH3 bit 3
; (already enabled elsewhere for the mono DAC) covers these too - same
; "8-bit DACs on" gate.
VID_DAC_LEFT    equ $F3
VID_DAC_RIGHT   equ $F9

; Layer 2 mode select (NR $70), matching l2_mode_set's own literals
; (overlay2.asm).
NXV_NR70_MODE1  equ %00010000  ; mode 1 (320x256/column-major)
NXV_NR70_MODE0  equ 0          ; mode 0 (256x192/row-major)

; NR $18 clip X (full-bleed, every NXV profile - no pillarbox anywhere in
; the new matrix, unlike the old fmt2/3's 256-of-320 subset): mode-1 X
; units are 2px/unit (X2=(320/2)-1=159), mode-0 X units are 1px/unit
; (X2=256-1=255) - both full width, X1=0 always.
NXV_CLIP_X2_MODE1 equ (320/2)-1   ; = 159
NXV_CLIP_X2_MODE0 equ 256-1        ; = 255

; NXV_COPPER_* constants retired with the v1 player (SP15 3a): the
; copper flip was already UNCALLED after the sparkle/magenta audit; v2
; flips are CPU-only by design. git holds the list geometry.

; The DEBUG frame-timeline instrument that owned this block - phase ids
; VID_TL_PACE/AUDIO/DECODE/FLIP/OTHER/PHASES for video.asm's
; vid_tl_stamp - was removed in v0.5.0. It measured phase occupancy in
; video-CTC ISR ticks, a clock the PLAY= instrument's banner
; (video.asm) shows is structurally blind to a suppressed interrupt,
; and the 2026-08-08 PACE-loss investigation ended by finding the
; instrument itself was the artifact. What survives of the DEBUG video
; report is page-local to video.asm and needs nothing here.

; ---- Sprite animation (SP20) ----
SPR_CHANS       equ 8
SPR_CACHE_MAX   equ 16
SPR_TAB_BASE    equ $C000   ; SPR_TAB_PAGE in slot 6
SPR_TAB_SIZE    equ 1024
SPR_SET_NONE    equ 255     ; free record, free cache entry, stop-all argument
HOOK_XBN        equ 1       ; xbnIntOn bit 0: XBN intEntry armed
HOOK_SPR        equ 2       ; xbnIntOn bit 1: sprite tick armed
HOOK_CYC        equ 4       ; xbnIntOn bit 2: colour cycle tick armed
PAL_SPR_EDIT    equ %00100000 ; NR $43 bits 6-4 = 010: sprite palette 0 for edit
SPR_NR15_ON     equ %01000011 ; NR $15: bit 6 sprite 0 on top, bit 1 over border, bit 0 enable
SPR_DBG_SNAP    equ $5000   ; DEBUG snapshot: dead ULA pixel window, always mapped
                            ; outside video playback, clear of the
                            ; AUD_STAGE2 ring ($4400-$47FF)
SPR_DBG_LEN     equ 495     ; snapshot bytes: sig 4, seq 1, block 488, hook 1, seq 1
SPR_STAGE       equ $5200   ; 1K frame-table staging while slot 6 holds the image;
                            ; dead ULA pixel window like SPR_DBG_SNAP and AUD_STAGE2
    ASSERT SPR_DBG_SNAP + SPR_DBG_LEN <= SPR_STAGE
    ASSERT SPR_STAGE + SPR_TAB_SIZE <= $5800
CYC_DBG_SNAP    equ $5600   ; DEBUG colour-cycle snapshot header, after SPR_STAGE's
                            ; 1K, same dead ULA pixel window and the same $5800
                            ; bound: the attribute area above is ula_cls's
CYC_DBG_LEN     equ 16      ; sig 4, seq 1, armed 1, state 4, steps 2, reason 1, pad 2, seq 1
    ASSERT SPR_STAGE + SPR_TAB_SIZE <= CYC_DBG_SNAP
    ASSERT CYC_DBG_SNAP + CYC_DBG_LEN <= $5800
; .ANI header (16 bytes, little-endian)
ANI_MAGIC       equ 0       ; 'N','A'
ANI_VER         equ 2       ; 1
ANI_FLAGS       equ 3       ; bit 0 loop, bit 1 4-bit
ANI_W           equ 4
ANI_H           equ 5
ANI_X           equ 6       ; word, 0-319
ANI_Y           equ 8
ANI_FRAMES      equ 9
ANI_PATS        equ 10
ANI_NBLK        equ 11
ANI_MASK        equ 12      ; word
ANI_TLEN        equ 14      ; word
ANI_HDR         equ 16
ANI_FLAG_LOOP   equ 1
ANI_FLAG_4BIT   equ 2
; set record (SR_SIZE bytes on SPR_PAGE; SR_SET written last on start, first on stop)
SR_SET          equ 0       ; set number, SPR_SET_NONE = free
SR_KIND         equ 1       ; 0 = 8-bit, 1 = 4-bit
SR_W            equ 2
SR_H            equ 3
SR_CELLS        equ 4       ; W*H
SR_ATTR         equ 5       ; anchor attribute slot; relatives follow
SR_PAT          equ 6       ; first pattern half-slot (even for 8-bit), 255 = none
SR_NBLK         equ 7       ; blocks taken so far
SR_FRAMES       equ 8
SR_FRAME        equ 9
SR_COUNT        equ 10      ; ticks left on this frame; 0 = holding
SR_LOOP         equ 11
SR_CACHE        equ 12      ; cache entry index
SR_ROW          equ 13      ; 1 + cells
SR_TAB          equ 14      ; word: frame table address in slot 6
SR_MASK         equ 16      ; word: 8-bit block mask
SR_BLKTAB       equ 18      ; word: per-pattern block numbers on SPR_PAGE
SR_BLOCKS       equ 20      ; 15 bytes: assigned blocks (4-bit)
SR_X8           equ 35      ; anchor X bit 8 (sprite plane)
SR_Y8           equ 36      ; anchor Y bit 8
SR_PATS         equ 37      ; pattern count from the header
SR_NBLKREQ      equ 38      ; blocks the header asks for
SR_CHAN         equ 39      ; channel index 0-7, written once at init
SR_XLO          equ 40      ; sprite-plane X low byte
SR_RESERVED41   equ 41      ; unused; X is SR_XLO + SR_X8
SR_Y            equ 42      ; sprite-plane Y low byte
SR_SIZE         equ 48
; cache entry
CE_SET          equ 0
CE_BANK0        equ 1
CE_BANK1        equ 2       ; 255 = single bank
CE_TICK         equ 3
CE_SIZE         equ 4
