; hints.asm - NextDAAD XBN worked example: the file services.
;
;   EXTERN n 50    print the next hint for topic n
;   EXTERN n 51    level count for topic n, into flag 243
;   EXTERN 0 52    preflight: is the hint file present and readable
;   EXTERN 0 53    clear all progress
;
; Flag 242 = level override (0 = automatic), flag 243 = status or count.
; Nothing prints on failure: per the Release policy a player never sees an
; advisory error code, so every fault reports in flag 243 only.

    IFNDEF XBN_MODULE
    DEVICE ZXSPECTRUMNEXT
    INCLUDE "xbn.inc"
    INCLUDE "xbnmod.inc"
    ORG XBN_ORG
    XBN_BEGIN hints.ext, hints.int
    ENDIF

    MODULE hints

FLAG_LEVEL      equ 242          ; author's override: 0 = use GAME.HPR
FLAG_STATUS     equ 243          ; status for fn 50/52/53, count for fn 51

ST_OK           equ 0
ST_NOFILE       equ 1            ; missing, unreadable or truncated GAME.HNT
ST_NOTOPIC      equ 2            ; topic absent or above maxTopic
ST_NOLEVEL      equ 3            ; level past this topic's ceiling
ST_OLDAPI       equ 4            ; interpreter older than this extern needs

MIN_API         equ 1            ; lowest SVC_VERSION that serves this module

; esxDOS open modes (NextZXOS esxapi.def): read $01, write $02,
; open-existing $00, open-or-create $08, create+truncate $0C.
MODE_R          equ $01
MODE_RW         equ $03          ; existing file, read/write, no truncate
MODE_WNEW       equ $0E          ; write, create or truncate

ext:
    ld a, b
    ld (topic), a                ; park param1 NOW. open_hnt loads B with a
                                 ; mode, and every file service is documented
                                 ; to clobber BC, so B does not survive.
    ld a, c
    cp 52
    jp z, preflight              ; jp, not jr: later tasks put several hundred
    ret                          ; bytes between here and the handlers

; fn 52 - open GAME.HNT, validate its header, leave the result in flag 243.
; Also the graceful-degrade example: an interpreter whose API predates the
; file services cannot serve us, so say so rather than calling into it.
preflight:
    call SVC_VERSION
    cp MIN_API
    jr nc, .versionok
    ld a, ST_OLDAPI
    jp status
.versionok:
    call open_hnt
    jr c, .nofile
    call close_hnt
    xor a
    jp status
.nofile:
    ld a, ST_NOFILE
    jp status

; Opens GAME.HNT read-only and validates magic and version. Out: CF set on
; any failure, handle in (handle) on success.
open_hnt:
    ld ix, name_hnt
    ld b, MODE_R
    call SVC_FOPEN
    ret c
    ld (handle), a
    ld ix, hdr
    ld bc, 6
    call SVC_FREAD
    jr c, .bad
    ld a, b                      ; short read means a truncated file
    or a
    jr nz, .bad
    ld a, c
    cp 6
    jr nz, .bad
    ld a, (hdr)
    cp 'H'
    jr nz, .bad
    ld a, (hdr+1)
    cp 'N'
    jr nz, .bad
    ld a, (hdr+2)
    cp 'T'
    jr nz, .bad
    ld a, (hdr+3)
    cp 1
    jr nz, .bad
    or a                         ; CF = 0
    ret
.bad:
    call close_hnt
    scf
    ret

close_hnt:
    ld a, (handle)
    cp $FF
    ret z
    call SVC_FCLOSE
    ld a, $FF
    ld (handle), a
    ret

; Mirrors close_hnt for the progress file. Every exit path calls BOTH, so a
; failure part-way through cannot strand an esxDOS handle.
close_hpr:
    ld a, (hprh)
    cp $FF
    ret z
    call SVC_FCLOSE
    ld a, $FF
    ld (hprh), a
    ret

; Writes A to flag 243 and returns.
status:
    ld (XBN_FLAGS + FLAG_STATUS), a
    ret

int:
    ret                          ; no frame work; the chain calls this anyway

name_hpr:   db "GAME.HPR", 0
hprh:       db $FF

name_hnt:   db "GAME.HNT", 0
handle:     db $FF
topic:      db 0                 ; param1, parked before anything clobbers B
hdr:        ds 6                 ; magic, version, seed, maxTopic

    ENDMODULE

    IFNDEF XBN_MODULE
xbn_end:
    SAVEBIN "GAME.XBN", XBN_ORG, xbn_end - XBN_ORG
    ENDIF
