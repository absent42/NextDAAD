; NextDAAD constants - single source of truth for the memory map
; and hardware registers. All later modules include this file.

; --- Version (SP10 Task 10) ---
; Single source of truth for the boot-time version stamp text: DEBUG's
; msgTitle and RELEASE's boot_banner (both debug.asm) print this exact
; string, so the two build variants cannot drift apart. v0.3.0 was the
; SP15 milestone (NXV v2 delta video with resident/streamed/direct
; delivery, L2 snapshot/restore - automatic picture return after a
; cutscene). v0.3.1 is the DAAD compliance sweep plus DAAD V3 database
; support, the SP17 video motion work (file ceiling 16 MB -> 256 MB,
; mid-clip pause removed, half-rate clips at true rate, mono cutscene
; audio dropped) and the sampled-sound fix - effects no longer distort
; while a picture is drawn. v0.3.2 moves Layer 2 transparency to the
; Next's standard scheme (reserved palette INDEX 255 stamped with the
; global transparency COLOUR $E3, no dependence on tilemap transparency
; attributes), fixes the white background that showed before a game's
; first picture, and replaces the kit's stand-alone guides with a
; generated HTML manual. The "0.x" line runs until public testing
; earns v1.0 (see RELEASE.md).
    DEFINE VERSION_STR "NEXTDAAD V0.3.2"

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
; the $C4/$C5/$C6 enable trio's exact mirror at +8. Dev guide
; chapter-next-interrupts.tex:296-301 (the feature) and :512-564 (the bit
; layouts). NO RESET VALUE IS DOCUMENTED for any of the three, so im2_init
; writes all three explicitly - see the comment there.
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
; 35-47 allocator pool (base model ends at 47); bank 28 withdrawn for
; overlay 0/1, bank 29 for overlay 2, banks 30-34 for the Layer 2 back
; surface. Bank 35 is ALSO withdrawn, for VID_PAGE2 below - originally
; (SP14a T1) a DEBUG-only report-print page; SP14a T3 wave 1 makes the
; withdrawal UNCONDITIONAL in both build variants, since VID_PAGE2 now
; also carries Release-reachable COLD video code (vid_classify, the
; open/filemap-setup cluster) evicted off VID_PAGE under the one-rule
; invariant (MMU7 = VID_PAGE whenever the video CTC ISR can fire) - see
; video.asm's own eviction comments at each moved routine.
BANK_POOL_B     equ 36
VID_PAGE2       equ 70      ; = 35*2, lower 8K of the withdrawn bank
SFX_PAGE        equ 71      ; = 35*2+1, upper 8K of the SAME withdrawn
                            ; bank (SP18 item 7 T3: SD-streamed sampled-
                            ; effect transport clones). Bank 35 is
                            ; already wholly excluded from bank_alloc
                            ; (the comment above; bank_table_init's free-
                            ; pool loop starts at BANK_POOL_B=36), so
                            ; this sibling page needs no further banks
                            ; .asm change - it is unreachable to the
                            ; allocator from assembly time, exactly like
                            ; VID_PAGE2. Populated by src/audio/streamfx
                            ; .asm's own `MMU 7, SFX_PAGE, OVL_ORG` +
                            ; main.asm's INCLUDE, picked up by SAVENEX
                            ; AUTO - same zero-resident-cost mechanism as
                            ; VID_PAGE/VID_PAGE2 above.
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
;     NOT used - we drive the card directly, transcribed from playvid
;     (tools/ZXNextOS/.../playvid/video_stream_postamble.asm, Garry
;     Lancaster's inlined SD code; MIT-cleared). No OS streaming window is
;     opened, so nothing needs ending beyond deselecting the card.
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
TM_MAP          equ $6000   ; 80x32x2 = 5120 bytes, $6000-$73FF
TM_MAP_MSB      equ $20     ; ($6000-$4000)>>8
TM_DEFS         equ $7400   ; 256 glyphs x 8 = 2048 bytes
TM_DEFS_MSB     equ $34     ; ($7400-$4000)>>8
TM_COLS         equ 80
TM_ROWS         equ 32
GLYPH_SPACE     equ $20
TM_ATTR_DEFAULT equ 7*2     ; pair 7 = paper 0 (black), ink 7 (white) -
                            ; what txt_init sets and every print path
                            ; re-sets, so a blanked cell matches a
                            ; printed one instead of showing paper
ULA_OFF         equ $80     ; NR_ULA_CTRL bit 7
NR_TM_TRANSP    equ $4C     ; NORMAL tilemap mode's transparent index -
                            ; an INDEX compare, applied before the
                            ; palette offset (chapter-next-tilemap.tex
                            ; :294-303). NOT what we use: text mode
                            ; (TM_CTRL_ON bit 3) checks NR_L2_TRANSP
                            ; ($14) as a COLOUR instead (:357). We rely
                            ; on neither - the tilemap has no
                            ; transparency at all now, see tm_clear_blank.

; --- Layer 2 transparency: a COLOUR and an INDEX, deliberately separate ---
; These were one constant (TM_TRANSP_ATTR) doing both jobs plus a third,
; which is what tied Layer 2's transparent colour to a tilemap attribute
; encoding. Never merge them again.
;
; THREE FILES CARRY THESE VALUES - this one is canonical, and if either
; moves, all three move:
;   src/nextdaad.inc          L2_TRANSP_COLOUR / L2_TRANSP_INDEX (here)
;   authoring-kit/lib/nxv2enc.py    L2_TRANSPARENT_BYTE0
;   authoring-kit/lib/palcheck.ps1  $TRANSP / $RESERVED
; tests/build-tests.ps1 parses all three and fails if they disagree.
L2_TRANSP_COLOUR equ $E3    ; RGB332 COLOUR written to NR_L2_TRANSP, and
                            ; stamped into L2_TRANSP_INDEX. $E3 is the
                            ; hardware reset value (chapter-next-layer2
                            ; .tex:619) and 24-bit 0xE000C0 in a paint
                            ; program. The compare is against the TOP 8
                            ; BITS of the 9-bit entry, so TWO of the 512
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

; --- Banking skeleton (sub-project 3) ---
DDB_PAGE_FIRST  equ 32      ; DDB bank 16 = 8K pages 32..47
BANK_OVL0       equ 28      ; overlay page 0 lives in bank 28 (lower 8K)
OVL0_PAGE       equ 56      ; = BANK_OVL0*2
OVL_ORG         equ $E000
OVL_LIMIT       equ $F800   ; overlay ASSERT bound (512 bytes spare)
OVL1_PAGE       equ 57      ; overlay page 1: upper 8K of bank 28
BANK_OVL2       equ 29      ; overlay page 2 lives in bank 29 (lower 8K)
OVL2_PAGE       equ 58      ; = BANK_OVL2*2
VID_PAGE        equ 59      ; video code page (SP13 T1): the upper 8K of
                            ; bank 29, the ONLY page in the overlay-
                            ; reserved bank range (28/29) with no equate
                            ; yet - bank_table_init (banks.asm) never
                            ; marks banks 28/29 BT_FREE (the pool starts
                            ; at BANK_POOL_B=36), so this page is outside
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
                            ; 2 of 512 RGB333 colours match any value - the
                            ; guide's register table (chapter-next-layer2
                            ; .tex:619) calls this an "index" and is wrong
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
; SP14a T2: true palette double-buffering. NR $43 bits 6-4 = edit target
; (which bank $44 writes land in), bit 2 = display select (which bank is
; scanned out) - INDEPENDENT fields (sp13-task-4-report.md addendum). The
; two "locked" constants below mirror PAL_L2_FIRST's shape (edit==display,
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
; The 9th X bit. Guide chapter-next-layer2.tex 745-756: NR $71 bit 0 =
; "MSB for X pixel offset", "only used for 320x256 and 640x256 modes.
; Together with [$16] full 319 pixels offsets are available"; the port
; table (chapter-next-ports.tex 192) marks it RW, so it reads back.
; Bits 7-1 are reserved and must be 0. Mode-0 (256x192) ignores it.
NR_L2_XOFS_MSB  equ $71
; Read-only raster position (chapter-next-ports.tex 128-129): $1E =
; MSB, $1F = the eight LSBs of the line currently being drawn. Used by
; the DEBUG scroll probes to place a register write at a known point
; on the visible raster instead of a CPU-speed-dependent delay loop.
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
; DAC signedness: UNSIGNED everywhere on the CPU-OUT path. The DAC silence/park
; value is the unsigned midpoint $80, unconditionally - there is no build toggle.
;
; WHY unsigned is now empirically pinned (the -DacCSpect signed accommodation was
; retired here, SP11): three independent lines of evidence agree the CPU
; `out (n),a` DAC path is unsigned on BOTH real silicon and CSpect -
;   1. FPGA source: soundrive.vhd resets the DACs to $80 and sums UNSIGNED.
;   2. Hardware listens: the owner's two real-Next listens play clean unsigned,
;      and em00k's CTCAudio + playwav32 feed raw unsigned WAV bytes (CTCAudio
;      README "PCM unsigned" - em00k-audio-engines-analysis.md).
;   3. CSpect CTC-path listen (this engine): the DEFAULT unsigned build plays the
;      sample CLEAN on CSpect; the old XOR $80 build was the DISTORTED one.
; The DMA-era observation that CSpect wanted SIGNED data was path-specific to the
; retired zxnDMA write path, NOT the CPU-OUT path this engine uses - so it retired
; with the DMA engine. One convention now, no IFDEF, no -DacCSpect.
DAC_SILENCE     equ $80
NR_PERIPH2      equ $06     ; peripheral 2: bit 3 = Multiface enable - the raw
                            ; streaming path (video.asm) clears it for the
                            ; duration of a stream (a Multiface trap could
                            ; issue filesystem I/O mid-SD-transaction and
                            ; lock up)
NR_PERIPH3      equ $08     ; peripheral 3: bit 3 = 8-bit DACs on,
                            ; bit 1 = Turbo Sound on (both hard-reset 0)
NR_VIDEO_TIMING equ $11     ; bits 2:0 = video timing mode 0-6 (VGA0-6), 7 = HDMI;
                            ; selects the FPGA system clock the CTC divides
; SP10 CTC per-sample DAC feed (replaces the SP8 DMA sample engine). The CTC
; channel input clock IS the video-mode-dependent FPGA system clock (27-33 MHz,
; nextreg $11), NOT a fixed reference - so the time constant is derived per
; video mode at load time (aud_clk16_tab in overlay1). Prescaler /16 when the
; /16 time constant fits 8 bits (rate >= clk16>>8, per-mode), /256 below - see
; aud_ctc_params. Inherent worst-case pitch error ~6% (1/16) in the narrow
; TC=16 band just below each mode's crossover - CTC 8-bit-TC quantisation,
; shared by the reference engines. Confirmed against playvid + em00k CTCAudio:
; "28,000,000 / 16 / 15625 = 112".
AUD_CTC_PORT    equ $183B   ; CTC channel 0 (lowest = highest IM2 priority; ch3=joystick)
AUD_CTC_RESET   equ $03     ; control word: soft reset (D1) + no TC (D2=0); written
                            ; twice = the Next's unknown-state channel reset (ports.txt)
AUD_CTC_CW16    equ $85     ; %10000101: int en, timer, /16, auto-trig, TC follows, control
AUD_CTC_CW256   equ $A5     ; %10100101: as CW16 but prescaler /256
; prescaler crossover is per-video-mode (clk16>>8), computed in aud_ctc_params -
; a fixed constant would clamp sharply on the faster clocks
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
                            ; smpPlayPtr, the 50Hz tick refills SMPB_W from the
                            ; page-table source. 1K = 51ms at 20kHz - ample vs
                            ; the 20ms refill period. Base $7C00 is 1K-aligned so
                            ; the ISR wraps with a branchless AND/OR mask on H.
    ASSERT AUD_STAGE0 + AUD_STAGE_RING == $8000   ; ISR wrap tests H == $80
    ASSERT AUD_STAGE_RING >= 2*(AUD_RATE_MAX/50)  ; ring > 1 frame of consumption
                            ; so a tick always refills before the ISR underruns

; --- SP18 item 7: per-channel sampled-effect pump state ----------------
; One block per channel, in AUD_PAGE_LO (48) data space - pinned in slot 6
; for the whole of aud_tick, so pump code may touch it at any point with
; no slot-restore ordering. IX = block base inside aud_smp_* routines.
SMPB_FLAGS    equ 0    ; bit0 active, bit1 looping (bits 2+ Task 5/12)
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
SMPB_SIZE     equ 25   ; (was 14 before SP18 item 7 Task 2's parameterisation)

; --- DMA picture copies (SP11 Task 2) ---
; zxnDMA one-shot mem-to-mem chunk copies for Layer 2 picture work
; (overlay2.asm: dma_copy, l2_copy_back_front, gfx_row_copy256),
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
                            ; still serviced on time. Both callers hand
                            ; dma_copy exactly 256 bytes, so 256 makes every
                            ; call ONE chunk: ~780 T saved per call, about
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
                            ; both current call sites move a fixed 256
                            ; bytes, comfortably over the line, so neither
                            ; needs a runtime length check)

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

; --- Mouse (SP10 Task 5) ---
; Kempston mouse ports (tools/NextZXOS/docs/extra-hw/io-port-system/
; ports.txt 517-536; cross-checked against tools/CSpect/Mouse/
; includes.asm's identical equs and against ReadMe.txt/CSpectReadme.txt
; for CSpect's own emulation notes - see overlay0.asm's h_mouse header).
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
; Sprite hardware (docs/zx-next-dev-guide-2022-07-15/chapter-next-
; sprites.tex + chapter-next-tilemap.tex's NR $15 bit table).
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
SPRITE_IDX_PORT equ $303B  ; pattern/attribute upload slot select (full
                            ; 16-bit port, any value works for $57/$5B
                            ; below - low byte of THIS port is decoded
                            ; exactly, unlike the streaming ports)
SPRITE_PAT_PORT equ $005B  ; pattern upload stream (256 B/sprite, auto-
                            ; inc slot; low byte $5B only is decoded, so
                            ; B=0 here doubles as OTIR's 256-byte count)
SPRITE_BORDER   equ 32     ; sprite-space border offset: (32,32) is the
                            ; top-left coordinate at which a sprite is
                            ; fully on-screen (sprites chapter, Patterns)
MOUSE_X_MAX     equ 319    ; accumulated mouse position ceiling (320-
                            ; wide sprite/mouse plane)
MOUSE_Y_MAX     equ 255    ; accumulated mouse position ceiling (256-
                            ; tall plane, screen-downward)

; --- Video (NXV v2, SP15 - v1 DELETED; stage 3c player: resident +
; ring streaming + direct-serve) ---
; docs/superpowers/plans/2026-07-23-sp15-nxv2.md "Format reference" is
; the frozen authority (FORMAT FROZEN 2026-07-25, second NXBEN silicon
; settlement, core 3.02.04). This comment block and the constants below
; are the byte-identical player-side transcription; the encoder-side
; twin lives in authoring-kit/lib/nxv2enc.py (HDR_OFF_*), and
; authoring-kit/lib/nxv2dec.py is the executable spec every hand-trace
; cites.
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
NXV2_OFF_ACHAN   equ 9      ; MONO IS WITHDRAWN (2026-08-03, owner
                            ; ruling). This field is still READ and
                            ; still VALIDATED - nxv2_open_body refuses
                            ; anything but 2 with VID FMT?. That
                            ; refusal is load-bearing, not tidiness: a
                            ; channels = 1 file played through the
                            ; surviving stereo ISR would interleave its
                            ; single channel across both DACs at the
                            ; wrong rate. The offset is FROZEN wire
                            ; format and the value is only ever 2.
                            ; Mono's one advantage was a higher sample
                            ; rate (23325 vs 15625 Hz) for fewer bytes,
                            ; but both are 8-bit so quantisation, not
                            ; bandwidth, sets the floor - and it cost
                            ; 49% more interrupts plus (since the
                            ; tick-loss fix) a 128 B DMA burst cap
                            ; worth +92% decode on the one mono clip
                            ; ever built. Decode is the binding
                            ; constraint for picture; mono spent it
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
                            ; (SP17 T5a, withdrawn on owner ruling
                            ; 2026-08-02: both silicon arms were judged
                            ; worse than plain delta). The bit is kept
                            ; NAMED and kept REFUSED: a file carrying
                            ; OCOPY payload declares it, and the flags
                            ; byte is validated whole, so such a file
                            ; fails cleanly at OPEN with VID FMT? -
                            ; never reaching a decoder that no longer
                            ; implements the op. Do NOT re-use bit3 for
                            ; anything else.

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

; Kernel crossovers - DERIVED, not guessed (2026-07-28). Both are the
; break-even chunk length between the CPU body and the DMA body, from
; the task-2 silicon settlement's decomposed coefficients
; (.superpowers/sdd/task-2-final-settlement.md section 1, "Decomposed
; silicon coefficients (joint solves, FE-subtracted)", core 3.02.04):
;
;   CPU unrolled fill body  17.17 T/B   (R8U vs R6U joint solve)
;   DMA fill setup         849.4 T/chunk (RD1/RD2/RD3 chunk solve)
;   DMA fill per byte        5.11 T/B   (RD3 residual @ 249 T/op)
;   LDI copy body           20.25 T/B   (C8 vs C16 joint solve)
;   DMA copy setup        1091.8 T/chunk (CD1..CD4 chunk solve)
;   DMA copy per byte        5.31 T/B   (KF-vs-CD3 cross-row, UNARMED)
;
; A sub-256 chunk costs one setup, so DMA(L) = setup + per_b*L and
; CPU(L) = body*L. Break-even L = setup / (body - per_b):
;
;   RUN  fill: 849.4 / (17.17 - 5.11) = 849.4 / 12.06 = 70.43 B
;              L=70: CPU 1201.9 vs DMA 1207.1 -> CPU wins
;              L=71: CPU 1219.1 vs DMA 1212.2 -> DMA wins   => 71
;   COPY LDI : 1091.8 / (20.25 - 5.31) = 1091.8 / 14.94 = 73.08 B
;              (kernel-only - superseded for COPY, see below)
;
; COPY CORRECTION (SP17 NXBC silicon, C073/C074 rows): the kernel-only
; 73.08 derivation above priced the KERNELS and missed the
; fast-handler -> slow-body PATH DIFFERENCE - an at-threshold COPY8
; bails out of the fast handler into the slow chunked body to reach
; the DMA kernel, and that path measured +128 T/op on silicon (C074
; T_op markedly above C073's with the threshold at 74). Folding the
; path term in: (1091.8 + 128) / 14.94 = 81.65 B modeled; the C073/
; C074 pair measured the break-even at 81.4 B. => 81 (the measured
; placement; the +-14 T/block row resolution makes 81 vs 82
; indistinguishable, <= ~6 T/op either way).
;
; BOTH DENOMINATORS RE-DERIVED 2026-08-03 (REDERIVATION.md 6.2/6.3).
; NEITHER VALUE MOVES; both derivations were quoting the wrong
; quantity, which is the failure mode that drifts silently:
;
;   COPY: 14.94 is fetch_long 20.25 minus 5.31. fetch_long is the
;   >= 64 B LDI body, but the ops that DECIDE this crossover are
;   73-83 B and run fetch_short. At sitting-3 coefficients the honest
;   arithmetic is (1091.8 + 128) / (19.797 - 5.082) = 82.90 B. Cost of
;   holding 81: DMA taken ~2 B early, worst +28 T/op at L=81, on ~0.3%
;   of ops - inside the row resolution that placed it. HELD AT 81.
;
;   RUN: 17.17 and 5.11 are both superseded (fill_cpu is 16.703 and the
;   DMA fill rate ~5.0). Solving the two envelopes directly off the
;   fresh NXBK rows - CPU 476.7 + 16.703 L from F063/F070, DMA
;   1289.6 + 4.888 L from F071/F256 - gives 812.9/11.815 = 68.8 -> 69.
;   HELD AT 71: taking CPU for 69-70 B fills costs <= 34 T/op on a
;   class the delta-stream census shows barely executes (RUN =
;   0.003-6% of painted bytes, RUN16 never emitted, 0.00-0.08% of
;   corpus decode-T). Churning the player, the encoder mirror and the
;   NXBK straddle rows for that is not worth it.
;
; WHY RUN CHARGES NO PATH TERM AND COPY DOES - now MEASURED, not
; assumed. The same fresh rows give the RUN op envelopes on both
; sides: E_cpu = 1528.97 - 63*16.703 = 476.7 T, and E_dma =
; (1636.57 - 71*4.888) - 849.0 = 440.6 T. The DMA path's envelope is
; ~36 T BELOW the CPU path's - a NEGATIVE path difference - because
; t_op_run was fitted on CPU-fill rows and carries the computed-entry
; fill setup (ld a,c / and 15 / add a,a / neg / ...) that the DMA path
; never executes. So the COPY/RUN asymmetry is correct. Do not
; "fix" it.
;
; Two invariances make these the right numbers to compare against:
;  - AUDIO TAX. The armed-decode tax is a uniform 1.170-1.173 on the
;    per-op AND per-byte terms alike (settlement section 1, CD armed vs
;    unarmed at c64/c128/c256), and the CPU body is stolen from by the
;    same ISR, so both sides scale together and the crossover is
;    unchanged. The unarmed coefficients are therefore the correct ones.
;  - WINDOW SEAMS. Every 49152-byte solve row carries the same
;    +0.129 T/B seam term (6 seams x ~1055 T / 49152 B) in BOTH its CPU
;    and DMA per-byte figure, and it cancels in (body - per_b). Using
;    the do-not-regress anchors 17.0 / 20.2 with seam-free DMA rates
;    gives the same differences, hence the same crossovers.
;
; Previous values were 64 (RUN) and 90 (COPY) with no derivation
; recorded anywhere: 64 took DMA ~6 B early (worst +77.5 T at L=64,
; 7.1% of the body) and 90 took it 16 B late (worst +237.8 T at L=89,
; 15.2% of the body). The 2026-07-28 kernel-only values were 71/74;
; COPY's 74 took the DMA path 7 B early once the +128 T path
; difference is charged (worst +~104 T at L=74). At 71/81 the player
; sits on the measured break-evens (RUN's residual ~35 T worst case
; disclosed above).
;
; The encoder's T model MIRRORS these two constants
; (authoring-kit/lib/nxv2enc.py TMODEL_COEFFS run_dma_min/copy_dma_min,
; consumed by _fill_t/_copy_t): change one, change the other in the
; same commit or the model stops predicting the player.
;
; Every DMA burst is capped, because the transfer runs inside a DI
; bracket and a bracket longer than the audio ISR's period loses a
; tick per chunk (the Z80 CTC latches ONE pending interrupt; a second
; zero-count while the first is unacknowledged is lost). The lost tick
; does NOT skip a sample - the ISR simply does not run, the DAC holds,
; IX does not advance, and since the frame loop paces off IX the whole
; clip plays LONG AND FLAT with no click. That silence is why this
; shipped for months as an "accepted ~1.2% shortfall".
;
; RETIRED (SP18 item 5): the video kernels' DI brackets are gone, so
; this deadline mechanism is historical (silicon leg pending); the
; cap stays for the structural reasons stated at the end of this
; block (one fixed number, <= 255).
;
;   bracket  B(chunk) = A + 5.082 * chunk
;   deadline one ISR per L+R PAIR at 15625 Hz -> 1728..2112 T
;            (16 x the per-video-mode CTC time constant, exactly;
;            1728 T is HDMI, the tightest, and 2112 T is VGA6)
;
; A was measured 2026-08-02 by inverting the bench's own tick-
; shortfall table, four points on one free parameter, at
; A = 500 +/- 20 T (REDERIVATION.md 2.2b). AUD_RATE_MAX (20000) is the
; SAMPLE engine's ceiling and has never governed video: a video
; session repoints the CTC vector at video_ctc_isr_stereo.
;
; THE DEFECT, AND WHAT FIXED IT (2026-08-03). At the old cap
; B(256) = 1801 T, which is 4.2% OVER stereo HDMI's 1728 T - the
; owner's own display - so every chunk spanning a tick boundary
; suppressed that interrupt. The PLAY= instrument found five staged
; rows running long with TOT exactly nominal and zero ring underruns
; (039 +5.2%, 007 +2.4%, 019 +2.8%, 037 +2.9%, 038 +2.1%), which is
; this mechanism's signature.
;
; SIZE HONESTY - it is NOT the whole of those rows. An exact op-walk
; of those five shipped files counts their DMA chunks and prices the
; loss at nchunks * (B - P) / wall_T:
;
;   row  chunks@256  predicted  observed   residual
;   039     24,012     0.65%     +5.20%     +4.55%
;   007     21,581     0.58%     +2.40%     +1.82%
;   019     29,280     0.79%     +2.80%     +2.01%
;   037     17,470     0.53%     +2.93%     +2.40%
;   038     20,815     0.66%     +2.10%     +1.44%
;
; So this cap change removes 0.5-0.8 percentage points and takes THIS
; mechanism to a structural zero on every video timing mode. The
; residual 1.4-4.6 pp has a different cause and does NOT rank with DMA
; density (019 has the most chunks per unit time and the second-lowest
; overrun; 039 has fewer and the highest). Do not close the
; slow-and-flat playback question on this change alone.
;
; Two changes closed the DI exposure, and each alone would have been
; too thin (margins against HDMI 1728 T, at nominal A and at the
; pessimistic end of its +/-20 T band):
;
;   as shipped     A = 500, cap 256   B = 1801.0   -4.22% / -5.38%
;   code only      A = 402, cap 256   B = 1703.0   +1.45% / +0.29%
;   cap only       A = 500, cap 240   B = 1719.7   +0.48% / -0.68%
;   BOTH (shipped) A = 402, cap 240   B = 1621.7   +6.15% / +5.00%
;
; A fell 98 T because the per-chunk copy arm lost the WR1 pair to the
; session init (descriptor split - fill is 0.003% of ops and restores
; it) and now uploads with unrolled OUTINB at 19 T/B instead of OTIR
; at 24 T/B. Both are hand-counted from the source bytes in
; video.asm's zxnDMA kernel header; the arms are 11 B (copy) and 13 B
; (fill), NOT the 15 the old comments and REDERIVATION.md 2.1 claimed.
; The margin arithmetic lives HERE; that header now carries the
; live-interrupts contract (its DI-era margin table retired with the
; brackets).
;
; WHY 240 AND WHAT IT COSTS. 0.9% of worst-case margin is not enough
; for a defect that ships silently, and A's uncertainty is entirely in
; its LEVEL (inferred) not in the 98 T reduction (hand-counted), so
; the remaining slack was bought from the cap. Cost, measured by an
; exact op-walk of the shipped corpus wire bytes (not extrapolated
; from histograms): +0.609% of corpus decode-T and +1.35% chunks.
; Per clip it is +0.02..0.11% on every DECODE-bound clip (boat-048
; +0.068%, church-050 +0.045%, boat-169 +0.055%, anchor-004 +0.106%,
; fplane-full +0.375%); the only clips over 1% - snow-021 +1.97%,
; snow-024 +1.81%, boat-classic +1.68% - are exactly the three
; DECODE-COST.md classes as BYTE-bound (decode utilisation 0.79/0.81/
; 0.51 against byte utilisation 0.96/0.96/0.98), where decode-T is not
; the binding constraint. That is the mirror of REDERIVATION.md
; section 5's own finding that a decode SAVING on those clips buys no
; picture. Lowering is not the mirror of raising: the same walk prices
; 256 -> 128 at +13.3% decode-T / +34.0% chunks.
;
; STILL NOT REACHABLE UPWARDS: 384's transfer ALONE is 1951 T and its
; bracket 2453 T, over the LARGEST stereo period on any video mode
; (VGA6 2112 T) by 16%, and zxnDMA burst mode cannot release the bus
; on a memory-to-memory transfer (REDERIVATION.md 4.4). The prize was
; never there either - 1.9%/3.6% of corpus decode-T, concentrated in
; byte-bound clips that cannot spend it (REDERIVATION.md 5).
;
; ONE fixed number, not a per-video-mode derivation from the
; programmed CTC TC: the encoder's supply gate has to PRICE the cap
; and cannot know which timing mode the machine will run in, so a
; mode-dependent cap could only ever be priced at its worst case
; anyway - which is this. It must also be <= 255: vid_chunk_dst's
; single-byte compare and both kernel selects depend on it (ASSERTed
; in video.asm).
NXV2_DMA_CHUNK   equ 240      ; vid_chunk_all / vid_chunk_dst
NXV2_RUN_DMA_MIN equ 71
NXV2_COPY_DMA_MIN equ 81

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

; SP17 T10 - CIRCULAR AUDIO FEED. ONE ring: the ISR's read pointer
; (IX) free-runs around it (wrap at the fixed ring end - the only
; boundary work the ISR does now), and the frame loop's writer chases
; BEHIND the reader, so capacity per frame is the WHOLE buffer instead
; of one half - the playvid differential (video_256x192_m_palette.asm
; write pointer / interrupts-common.asm read pointer).
;
; RING SIZE = THE WHOLE AUDIO BANK (2026-08-02). The ring landed at
; 2560 bytes because that is what the pre-T10 double buffer occupied,
; but since SP15 3c vidAudBuf has owned a WHOLE 8 KB pool bank
; (bank_alloc -> vidAudBankC, pinned at MMU3 for the session), so
; 5632 of those bytes were allocated and idle. They are now the ring.
; The defect that spent them: at the pace release the ring already
; holds one whole frame, so the NEXT frame's feed fits the single
; post-present pump only if 2*aBytes <= NXV_AUD_RING-NXV_AUD_GUARD.
; At 25 fps stereo that is 2500 of 2544 and it fitted; at 12.5 fps it
; is 5000 and 98% of the feed trickled out of the `.pace` spin - which
; is the SD producer's only window - at the READER's byte rate. The
; owner's 12.5 fps silicon rows spent 24-26 ms per frame in there
; against 1.41 ms at 25 fps: ~8x pure waste, and the direct cause of
; their ring underruns. With the whole bank the condition holds for
; every legal file BY CONSTRUCTION (see NXV_AUD_FRAME_MAX).
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
; 8-bit adds over 512-byte blocks (nxv2_open_body: need = cap + apad
; + 1, and the ring-fit test need + apad + 2), and with the header cap
; at its own maximum NXV2_STRM_CAP_MAX = 240 they hold iff
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

; DAC ports (ports.txt, tools/ZXNextOS/docs/extra-hw/io-port-system/
; ports.txt lines 266-274: "four 8-bit dac channels... A,B are directed to
; the left audio channel and C,D are directed to the right"; the
; soundrive-2 column gives DAC B = $F3, DAC C = $F9 - the exact pair the
; MakeVid reference ISR uses (tools/ZXNextOS/.../playvid/interrupts-
; common.asm isr_ctc_stereo). NR_PERIPH3 bit 3 (already enabled elsewhere
; for the mono DAC) covers these too - same "8-bit DACs on" gate.
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

; --- DEBUG-only frame-timeline instrument (video.asm's vid_tl_stamp/
; vid_tl_report) - phase ids for the v2 frame loop's 5-phase closed
; loop, stamped once per frame: pace (audio-done spin) -> audio (ring
; -> vidAudBuf copy-out + launch) -> decode (the whole payload decode/
; paint) -> flip (present: NR $43/$12 pokes) -> other (key/exit check,
; loop-back) -> pace ... vid_tl_stamp increments the frame counter when
; phase 0 (PACE) opens. The report also prints FILL= (the resident ring
; load's duration in 50Hz frames, measured pre-arm via frameCounter).
; DEBUG-only: zero cost to Release.
 IFDEF DEBUG
VID_TL_PACE     equ 0
VID_TL_AUDIO    equ 1
VID_TL_DECODE   equ 2
VID_TL_FLIP     equ 3
VID_TL_OTHER    equ 4
VID_TL_PHASES   equ 5
 ENDIF
