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

; Format 3 header: two more entry points (label or 0). The line hook gets
; HL = the typed line (writable, ASCIIZ, up to 127), B = length, IX =
; flags; CF set on return consumes the line (silent re-prompt). The
; output hook gets C = one printed character ($0D = newline), IX =
; flags; it must call no service and must preserve AF', BC', DE', HL'
; (the trampoline does not save them). Needs a v0.10.1 interpreter; older
; loaders reject the header and the game plays with externs off.
    MACRO XBN_HEADER3 ext_entry, int_entry, line_entry, out_entry
        db "XBN"
        db 3                    ; format version
        dw ext_entry
        dw int_entry
        dw xbn_end - XBN_ORG    ; total size, header included
        dw line_entry
        dw out_entry
    ENDM

; Frozen interpreter data anchors (never move between releases)
XBN_FLAGS       equ $A200       ; 256 DAAD flags; IX also points here
XBN_OBJTABLE    equ $A300       ; object table, OBJ_SIZE bytes per object
OBJ_SIZE        equ 6           ; +0 location, +1 weight/attrs, +2/+3
                                ; extended attrs, +4 noun, +5 adjective
XBN_NUMOBJ      equ $A900       ; object count byte (frozen)

XBN_STATE       equ $BF80       ; 128-byte extern state area, FROZEN: saved
XBN_STATE_LEN   equ 128         ; with the game (SAVE, LOAD, RAMSAVE,
                                 ; RAMLOAD), zeroed at boot only. Claim
                                 ; offsets through xbnmod.inc's
                                 ; XBN_STATE_FREE. For state that must
                                 ; agree with the flags after a LOAD;
                                 ; session configuration stays bank state.

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
                                 ; CF, BC = bytes written (API 3 documents
                                 ; it; a short count with CF clear is the
                                 ; seek-then-extend hazard: treat it as
                                 ; failure). Foreground-only.
SVC_FSEEK       equ XBN_API+18  ; in A = handle, BCDE = offset; out CF.
                                 ; Foreground-only.
SVC_FCLOSE      equ XBN_API+21  ; in A = handle. Foreground-only.
SVC_RANDOM      equ XBN_API+24  ; out A = random byte; corrupts AF only;
                                 ; BC, DE, HL preserved. ISR-safe.
SVC_GETMSG      equ XBN_API+27  ; in A = user msg no; out HL = buf, BC =
                                 ; len. CF set = message out of range
                                 ; (A = $FF). Foreground-only.
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
                                 ; cardBusy, bit2 palBusy, bit3 colour
                                 ; cycle armed); CF clear; corrupts AF, L.
                                 ; bit0 reads 1 from the hook only during
                                 ; a clip's open and prefill; the hook is
                                 ; suspended from the arm point to the
                                 ; teardown. bit2 reads 0 from the
                                 ; foreground; bit3 reads the same from
                                 ; either context. ISR-safe.
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
SVC_PAIR        equ XBN_API+45  ; in B = paper, C = ink (0-255, the
                                 ; INK/PAPER values); out A = tilemap
                                 ; attribute byte, CF clear. Corrupts
                                 ; all registers. API version 3 and up
                                 ; (as are rows 16-19 below): check
                                 ; SVC_VERSION first. Foreground-only.
SVC_GETLINE     equ XBN_API+48  ; out HL = ASCIIZ line the player last
                                 ; typed (read-only, resident), BC =
                                 ; length; CF set = stale - before the
                                 ; first prompt, or after one that ended
                                 ; in a timeout or an empty ENTER (HL then
                                 ; holds the recall buffer as it was, the
                                 ; partial line after a timeout). CF is
                                 ; unchanged by SVC_INJECT: an injected
                                 ; turn keeps whatever it already was.
                                 ; API 3. Foreground-only.
SVC_GETPENDING  equ XBN_API+51  ; out HL = ASCIIZ orders after a
                                 ; conjunction not yet consumed (empty
                                 ; when none), BC = length, CF clear. Can
                                 ; start with blanks: the parser blanks
                                 ; the conjunction word in place.
                                 ; API 3. Foreground-only.
SVC_INJECT      equ XBN_API+54  ; in HL = ASCIIZ text (your bank is fine),
                                 ; A = options: bit 0 echo it as typed.
                                 ; The next PARSE 0 consumes it, no
                                 ; prompt, REPLACING any pending orders
                                 ; (read SVC_GETPENDING first to keep
                                 ; them). CF set + A = $FF: over 127
                                 ; chars or a line already parked. A
                                 ; rewriter called from a PARSE entry's
                                 ; remainder must ALWAYS inject (the
                                 ; original line when nothing matched) or
                                 ; the second PARSE 0 prompts again
                                 ; silently. API 3. Foreground-only.
SVC_VOCFIND     equ XBN_API+57  ; in HL = ASCIIZ word (any case, first 5
                                 ; chars count); HL points at ONE word - a
                                 ; space or punctuation counts as a
                                 ; character, so pass a single word. out
                                 ; D = word id, E = type, CF clear; CF set
                                 ; = not in the vocabulary. Corrupts AF,
                                 ; BC, DE, HL. API 3. Foreground-only;
                                 ; NEVER from the output hook.
SVC_FITWORD     equ XBN_API+60  ; in A = length of the word about to be
                                 ; printed (0 = flush only). Flushes any
                                 ; pending word, then starts a new line if
                                 ; the word will not fit the rest of the
                                 ; current window's line but fits the
                                 ; window (scroll, More paging). Out A =
                                 ; the current window's width, CF clear.
                                 ; Corrupts all registers. API 3.
                                 ; Foreground-only.

; SVC_FOPEN modes (esxDOS)
XBN_FMODE_R     equ $01         ; read
XBN_FMODE_RW    equ $03         ; existing file, read/write, no truncate
XBN_FMODE_W     equ $0E         ; write, create or truncate
