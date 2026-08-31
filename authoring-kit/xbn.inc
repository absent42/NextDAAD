; xbn.inc - NextDAAD extern binary (XBN) authoring include.
; Assemble your extern with sjasmplus:  ORG XBN_ORG, XBN_HEADER first,
; SAVEBIN the range XBN_ORG..xbn_end. See the kit manual's externs
; chapter (docs\externs.html here; manual/externs.md in the repository).

XBN_ORG         equ $C000

; Emits the 10-byte XBN header. ext_entry/int_entry: label or 0.
; The author MUST define a label named xbn_end after their last byte.
    MACRO XBN_HEADER ext_entry, int_entry
        db "XBN"
        db 1                    ; format version
        dw ext_entry
        dw int_entry
        dw xbn_end - XBN_ORG    ; total size, header included
    ENDM

; Frozen interpreter data anchors (never move between releases)
XBN_FLAGS       equ $A200       ; 256 DAAD flags; IX also points here
XBN_OBJTABLE    equ $A300       ; object table, OBJ_SIZE bytes per object
OBJ_SIZE        equ 6           ; +0 location, +1 weight/attrs, +2/+3
                                ; extended attrs, +4 noun, +5 adjective

; Service jump table (frozen address, append-only; call directly)
XBN_API         equ $BEC8
SVC_VERSION     equ XBN_API+0   ; out A = API version
SVC_PUTCHAR     equ XBN_API+3   ; in A = char
SVC_PUTS        equ XBN_API+6   ; in HL = ASCIIZ (may be in your bank)
SVC_FOPEN       equ XBN_API+9   ; in IX = ASCIIZ name, B = mode; out A/CF
SVC_FREAD       equ XBN_API+12  ; in A = handle, IX = buf, BC = len; out BC/CF
SVC_FWRITE      equ XBN_API+15  ; in A = handle, IX = buf, BC = len; out CF
SVC_FSEEK       equ XBN_API+18  ; in A = handle, BCDE = offset; out CF
SVC_FCLOSE      equ XBN_API+21  ; in A = handle
SVC_RANDOM      equ XBN_API+24  ; out A = random byte
SVC_GETMSG      equ XBN_API+27  ; in A = user msg no; out HL = buf, BC = len
