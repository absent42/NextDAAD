; xbn.inc - NextDAAD extern binary (XBN) authoring include.
; Assemble your extern with sjasmplus:  ORG XBN_ORG, XBN_HEADER first,
; SAVEBIN the range XBN_ORG..xbn_end. See the kit manual's externs
; chapter (docs\externs.html here; manual/externs.md in the repository).

XBN_ORG         equ $C000

; Emits the 14-byte XBN header. ext_entry/int_entry: label or 0.
; The author MUST define a label named xbn_end after their last byte.
    MACRO XBN_HEADER ext_entry, int_entry
        db "XBN"
        db 2                    ; format version
        dw ext_entry
        dw int_entry
        dw xbn_end - XBN_ORG    ; total size, header included
        ds 4, 0                 ; v2 reserved, must be zero
    ENDM

; Frozen interpreter data anchors (never move between releases)
XBN_FLAGS       equ $A200       ; 256 DAAD flags; IX also points here
XBN_OBJTABLE    equ $A300       ; object table, OBJ_SIZE bytes per object
OBJ_SIZE        equ 6           ; +0 location, +1 weight/attrs, +2/+3
                                ; extended attrs, +4 noun, +5 adjective
XBN_NUMOBJ      equ $A900       ; object count byte (frozen)

; Service jump table (frozen address, append-only; call directly)
; ISR-safe rows may be called from the #int hook; every other row is
; foreground-only.
XBN_API         equ $BEC8
SVC_VERSION     equ XBN_API+0   ; out A = API version. ISR-safe.
SVC_PUTCHAR     equ XBN_API+3   ; in A = char. Foreground-only.
SVC_PUTS        equ XBN_API+6   ; in HL = ASCIIZ (may be in your bank).
                                 ; Foreground-only.
SVC_FOPEN       equ XBN_API+9   ; in IX = ASCIIZ name, B = mode; out A/CF.
                                 ; Foreground-only.
SVC_FREAD       equ XBN_API+12  ; in A = handle, IX = buf, BC = len; out
                                 ; BC/CF. Foreground-only.
SVC_FWRITE      equ XBN_API+15  ; in A = handle, IX = buf, BC = len; out
                                 ; CF. Foreground-only.
SVC_FSEEK       equ XBN_API+18  ; in A = handle, BCDE = offset; out CF.
                                 ; Foreground-only.
SVC_FCLOSE      equ XBN_API+21  ; in A = handle. Foreground-only.
SVC_RANDOM      equ XBN_API+24  ; out A = random byte. ISR-safe.
SVC_GETMSG      equ XBN_API+27  ; in A = user msg no; out HL = buf, BC =
                                 ; len. Foreground-only.
SVC_FRAMES      equ XBN_API+30  ; out HL = frame counter (50Hz); CF
                                 ; clear. ISR-safe.
SVC_GETDATE     equ XBN_API+33  ; esx M_GETDATE wrapper: CF clear with
                                 ; BC = MS-DOS date, DE = MS-DOS time,
                                 ; H = seconds, L = hundredths ($FF if
                                 ; unsupported). CF set = no RTC/invalid:
                                 ; BC = DE = 0 and HL UNDEFINED - do not
                                 ; read seconds on the failure path.
                                 ; Foreground-only.
SVC_BUSY        equ XBN_API+36  ; out A = mask (bit0 vidPlaying, bit1
                                 ; cardBusy, bit2 palBusy); CF clear;
                                 ; corrupts L. Bits 0/2 read 0 from the
                                 ; foreground (playback/draws are
                                 ; foreground-synchronous) - hook-only.
                                 ; ISR-safe.
SVC_PALREAD     equ XBN_API+39  ; in IX = 512-byte buffer, A = bank
                                 ; select (0 displayed, 1 other/staged);
                                 ; out 256 x (RRRGGGBB, %11000001-masked
                                 ; second byte); corrupts AF, BC, E, IX
                                 ; (IX left at buffer+512); CF clear;
                                 ; foreground-only.
SVC_WINDOW      equ XBN_API+42  ; in A = 0-7 selects; out A = previous
                                 ; window number, CF clear. A > 7: CF
                                 ; set, no change. May flush and may
                                 ; raise the More prompt in the OLD
                                 ; window. Foreground-only.
