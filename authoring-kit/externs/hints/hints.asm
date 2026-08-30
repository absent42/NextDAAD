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
    cp 50
    jp z, show
    cp 51
    jp z, query
    cp 52
    jp z, preflight              ; jp, not jr: several hundred bytes sit
    ret                          ; between here and the handlers

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

; Seeks the open handle to the 16-bit offset in HL. BC is always zero: every
; offset here fits 16 bits, and SVC_FSEEK takes a 32-bit offset in BCDE.
seek_hl:
    ex de, hl
    ld bc, 0
    ld a, (handle)
    call SVC_FSEEK
    ret

; Primes the keystream for file offset HL: stores the running S value and
; high byte for ks_next. MUL D,E (Z80N, ED 30, T=8, B=2; also used at
; src/gfxcache.asm:29) computes S's low-byte product in one op.
ks_start:
    ld a, l
    ld d, 167
    ld e, a
    mul d, e                     ; DE = lo * 167
    ld a, e
    add a, 89
    ld (ks_acc), a
    ld a, h
    ld (ks_hi), a
    ld a, l
    ld (ks_lo), a                ; the offset's low byte IS the page counter
    ret

; Out: A = the key byte for the current offset, then advances one byte.
; Clobbers B.
ks_next:
    ld a, (ks_acc)
    ld b, a
    ld a, (ks_hi)
    xor b
    ld b, a
    ld a, (hdr+4)                ; seed
    xor b
    push af
    ld a, (ks_acc)
    add a, 167
    ld (ks_acc), a
    ld a, (ks_lo)
    inc a
    ld (ks_lo), a
    jr nz, .same
    ld a, (ks_hi)
    inc a
    ld (ks_hi), a
.same:
    pop af
    ret

ks_acc:  db 0
ks_hi:   db 0
ks_lo:   db 0

; Reads the directory entry for topic B. Out: CF set if absent or out of
; range; else (tbl) = level table offset, (levels) = level count.
read_dir:
    ld a, (hdr+5)                ; maxTopic
    ld hl, topic
    cp (hl)
    jr c, .absent                ; topic > maxTopic
    ld a, (topic)
    ld h, 0
    ld l, a
    ld d, h
    ld e, l
    add hl, hl                   ; *2
    add hl, de                   ; *3
    ld de, 6
    add hl, de                   ; 6 + 3*topic
    push hl
    call seek_hl
    pop hl
    ret c
    push hl
    ld ix, buf3
    ld bc, 3
    ld a, (handle)
    call SVC_FREAD
    pop hl
    ret c
    ld a, b
    or a
    jr nz, .absent
    ld a, c
    cp 3
    jr nz, .absent               ; short read: treat as absent, print nothing
    call deob3                   ; HL still holds the entry's file offset
    ld a, (buf3+2)
    or a
    jr z, .absent
    ld (levels), a
    ld a, (buf3)
    ld (tbl), a
    ld a, (buf3+1)
    ld (tbl+1), a
    or a
    ret
.absent:
    scf
    ret

; Deobfuscates the 3 bytes in buf3, which were read from file offset HL.
deob3:
    call ks_start
    ld b, 3
    ld hl, buf3
.loop:
    push bc
    call ks_next
    xor (hl)
    ld (hl), a
    pop bc
    inc hl
    djnz .loop
    ret

; fn 51 - level count for topic B into flag 243. Zero means absent, which
; also doubles as "no more hints for this puzzle" for the author.
; Reports a COUNT only: a status code here would collide with a real count.
query:
    call open_hnt
    jr c, .none
    call read_dir
    jr c, .none
    ld a, (levels)
    push af
    call close_hnt
    pop af
    jp status
.none:
    call close_hnt
    xor a
    jp status

; fn 50 - print one hint. B = topic. Flag 242 selects the level, 1-based.
; Automatic mode (flag 242 = 0) is added in the next task.
show:
    ld a, (XBN_FLAGS + FLAG_LEVEL)
    or a
    ret z                        ; automatic mode not yet implemented
    dec a                        ; to 0-based
    ld (want), a
    call open_hnt
    jr c, .nofile
    call read_dir
    jr c, .notopic
    ld a, (want)
    ld hl, levels
    cp (hl)
    jr nc, .nolevel              ; want >= levels
    call read_entry
    jr c, .notopic
    call print_text
    jr c, .nofile                ; stopped partway or failed to start: no ST_OK
    xor a
    jr fail                      ; the epilogue closes both handles
.notopic:
    ld a, ST_NOTOPIC
    jr fail
.nolevel:
    ld a, ST_NOLEVEL
    jr fail
.nofile:
    ld a, ST_NOFILE
    jr fail

; Every fn 50 exit lands here. Closing BOTH handles on every path is the
; point: the exhausted-topic case is reached on ordinary play, and leaking a
; handle per call runs esxDOS out of them.
fail:
    push af
    call close_hnt
    call close_hpr
    pop af
    jp status

; Reads the level table entry for level (want) of the current topic.
; Out: (toff) = text offset, (tlen) = text length, CF set on read failure.
read_entry:
    ld a, (want)
    ld h, 0
    ld l, a
    add hl, hl
    add hl, hl                   ; *4
    ld de, (tbl)
    add hl, de
    push hl
    call seek_hl
    pop hl
    ret c
    push hl
    ld ix, buf4
    ld bc, 4
    ld a, (handle)
    call SVC_FREAD
    pop hl
    ret c
    ld a, b
    or a
    scf
    ret nz                       ; short read on the level table
    ld a, c
    cp 4
    jr z, .lenok
    scf
    ret
.lenok:
    call ks_start
    ld b, 4
    ld hl, buf4
.loop:
    push bc
    call ks_next
    xor (hl)
    ld (hl), a
    pop bc
    inc hl
    djnz .loop
    ld hl, (buf4)
    ld (toff), hl
    ld hl, (buf4+2)
    ld (tlen), hl
    or a
    ret

CHUNK   equ 128                  ; rdbuf is 256 bytes, so CHUNK must not
                                 ; exceed 256; write_blank fills all 256

; Prints (tlen) bytes starting at file offset (toff), deobfuscating as it
; goes. SVC_PUTCHAR prints through the current DAAD window, so wrapping,
; colour and the More... prompt behave like ordinary game text.
print_text:
    ld hl, (toff)
    call seek_hl
    ret c
    ld hl, (toff)
    call ks_start
.chunk:
    ld hl, (tlen)
    ld a, h
    or l
    jr z, .flush                 ; done: flush exactly once, even on an
                                 ; exact multiple of CHUNK
    ld de, CHUNK
    or a
    sbc hl, de
    jr nc, .full
    ld hl, (tlen)                ; last partial chunk
    ld b, l
    jr .read
.full:
    ld (tlen), hl
    ld b, CHUNK
.read:
    ld a, b
    ld (thisrun), a
    ld ix, rdbuf
    ld c, a
    ld b, 0                      ; BC = byte count, NOT a*256
    ld a, (handle)
    call SVC_FREAD
    ret c
    ld a, b
    or a
    jr nz, .short                ; short read: rdbuf would be stale RAM
    ld a, (thisrun)
    cp c
    jr nz, .short
    ld b, a
    ld hl, rdbuf
.emit:
    push bc
    push hl
    call ks_next
    pop hl
    xor (hl)
    push hl
    call SVC_PUTCHAR             ; HL is NOT preserved across the print path
    pop hl
    pop bc
    inc hl
    djnz .emit
    ld a, (thisrun)
    cp CHUNK
    jr nz, .flush                ; partial chunk was the last
    jp .chunk

; A short read means a truncated GAME.HNT; print nothing further.
.short:
    scf
    ret

; A hint ends mid-word, so its last word sits unflushed in the print
; path's wrap buffer; SVC_PUTCHAR does not flush it. The $0D flushes via
; prn_newline and gives the trailing line break authors expect anyway.
.flush:
    ld a, $0D
    call SVC_PUTCHAR
    ret

thisrun: db 0
want:    db 0
levels:  db 0
tbl:     dw 0
toff:    dw 0
tlen:    dw 0
buf3:    ds 3
buf4:    ds 4

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

; Read buffer, 256 bytes, deliberately past xbn_end: the loader maps a full
; 16K bank, so this costs nothing against the size cap. Recycled RAM, so it
; is always written before it is read. Task 5's write_blank needs all 256.
    MODULE hints
rdbuf:   equ xbn_end
    ENDMODULE
