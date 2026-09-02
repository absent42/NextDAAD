; realtime.asm - NextDAAD XBN worked example: the wall clock.
;
;   EXTERN 0 66    refresh the snapshot from the Next's RTC
;   EXTERN f 67    field f of that snapshot into flag 238
;   EXTERN 0 68    stamp today's date into GAME.HST
;   EXTERN 0 69    days since that stamp into flag 238
;
; Flag 238 carries fn 67's field and fn 69's count; flag 239 is fn 66's
; availability verdict (1 = snapshot taken, 0 = no RTC). Every other
; outcome is CF: set is the fn's one documented failure, clear is success.
; fns 68 and 69 take their own SVC_GETDATE reading, so neither depends on
; fn 66 - the snapshot serves fn 67 only.

    IFNDEF XBN_MODULE
    DEVICE ZXSPECTRUMNEXT
    INCLUDE "xbn.inc"
    INCLUDE "xbnmod.inc"
    ORG XBN_ORG
    XBN_BEGIN realtime.ext, realtime.int
    ENDIF

    MODULE realtime

FLAG_RESULT     equ 238          ; fn 67's field, fn 69's day count
FLAG_AVAIL      equ 239          ; fn 66 only: 1 = snapshot taken, 0 = no RTC

; esxDOS open modes (NextZXOS esxapi.def), as hints.asm uses them.
MODE_R          equ $01
MODE_WNEW       equ $0E          ; write, create or truncate

ext:
    ld a, b
    ld (param), a                ; park param1: every file service clobbers B
    ld a, c
    cp 66
    jp z, refresh
    cp 67
    jp z, field
    cp 68
    jp z, stamp
    cp 69
    jp z, dayssince
.notmine:
    or a                         ; CF clear: unrecognised fn, no failure
    ret

; fn 66 - refresh the snapshot. CF set = no RTC or an invalid reading;
; HL is undefined on that path, so the seconds byte is read on success
; only. A failed refresh INVALIDATES the snapshot as well as clearing
; flag 239, so fn 67 reads 0 until the next successful refresh.
refresh:
    call SVC_GETDATE
    jr c, .nortc
    ld (snapDate), bc
    ld (snapTime), de
    ld a, h                      ; H = seconds; L (hundredths) unused
    ld (snapSec), a
    ld a, 1
    ld (valid), a
    ld (XBN_FLAGS + FLAG_AVAIL), a
    or a                         ; CF clear: success
    ret
.nortc:
    xor a
    ld (XBN_FLAGS + FLAG_AVAIL), a
    ld (valid), a                ; stale fields must not outlive the reading
    scf
    ret

; fn 67 - field param1 of the snapshot into flag 238. An ACTION: CF is
; always clear. A field above 6, or any call before a successful fn 66,
; writes 0.
field:
    ld a, (valid)
    or a
    jr z, .zero
    ld a, (param)
    or a
    jr z, .sec
    cp 1
    jr z, .min
    cp 2
    jr z, .hour
    cp 3
    jr z, .day
    cp 4
    jr z, .month
    cp 5
    jr z, .year
    cp 6
    jr z, .wday
.zero:
    xor a
.store:
    ld (XBN_FLAGS + FLAG_RESULT), a
    or a                         ; CF clear: fn 67 never fails
    ret
.sec:
    ld a, (snapSec)
    jr .store
.min:
    ld hl, (snapTime)
    ld b, 5
    ld c, 63
    jr .extract
.hour:
    ld hl, (snapTime)
    ld b, 11
    ld c, 31
    jr .extract
.day:
    ld hl, (snapDate)
    ld b, 0
    ld c, 31
    jr .extract
.month:
    ld hl, (snapDate)
    ld b, 5
    ld c, 15
.extract:
    call shr_mask
    jr .store
.year:
    ld hl, (snapDate)
    call year_field
    cp 20
    jr c, .zero                  ; 1980-1999 has no 2000-2099 offset: 0
    sub 20
    jr .store
.wday:
    ld hl, (snapDate)
    call daynum
    inc hl
    inc hl                       ; 1980-01-01 was a Tuesday, so +2 makes
    call mod7                    ; 0 Sunday
    jr .store

; fn 68 - stamp today's packed date into GAME.HST, 2 bytes, low byte
; first. CF set = no RTC, or the file could not be created or written.
stamp:
    call SVC_GETDATE
    ret c
    ld (stampbuf), bc
    ld ix, name_hst
    ld b, MODE_WNEW
    call SVC_FOPEN
    ret c
    ld (handle), a
    ld ix, stampbuf
    ld bc, 2
    ld a, (handle)
    call SVC_FWRITE
    push af                      ; hold the write verdict: SVC_FCLOSE
    call close_hst               ; clobbers AF
    pop af
    ret

; fn 69 - days from the GAME.HST stamp to today, into flag 238. CF set =
; no RTC, no stamp file, or a truncated one; flag 238 is left alone on
; those paths. A clock set back reads 0, more than 255 days reads 255.
dayssince:
    call SVC_GETDATE
    ret c
    ld (today), bc
    ld ix, name_hst
    ld b, MODE_R
    call SVC_FOPEN
    ret c
    ld (handle), a
    ld ix, stampbuf
    ld bc, 2
    ld a, (handle)
    call SVC_FREAD
    jr c, .fail
    ld a, b
    or a
    jr nz, .fail                 ; short read: a truncated stamp file
    ld a, c
    cp 2
    jr nz, .fail
    call close_hst
    ld hl, (stampbuf)
    call daynum
    ld (dn_then), hl
    ld hl, (today)
    call daynum
    ld de, (dn_then)
    or a
    sbc hl, de
    jr c, .zero                  ; clock set back since the stamp
    ld a, h
    or a
    ld a, l                      ; ld does not touch F: the test is on H
    jr z, .store
    ld a, 255                    ; more than 255 days
.store:
    ld (XBN_FLAGS + FLAG_RESULT), a
    or a                         ; CF clear: success
    ret
.zero:
    xor a
    jr .store
.fail:
    call close_hst               ; never strand an esxDOS handle
    scf
    ret

close_hst:
    ld a, (handle)
    cp $FF
    ret z
    call SVC_FCLOSE
    ld a, $FF
    ld (handle), a
    ret

; Out: A = (HL >> B) AND C. B = 0 is a plain mask - djnz would otherwise
; loop 256 times.
shr_mask:
    ld a, b
    or a
    jr z, .mask
.loop:
    srl h
    rr l
    djnz .loop
.mask:
    ld a, l
    and c
    ret

; HL = packed MS-DOS date; out A = its year field, years since 1980.
year_field:
    ld b, 9
    ld c, 127
    jp shr_mask

; HL = packed MS-DOS date (year-1980 bits 15-9, month 8-5, day 4-0); out
; HL = days since 1980-01-01. days = 365*Y + ((Y+3)>>2) + cum[M] + leap +
; (D-1), leap = 1 iff (Y AND 3) = 0 and M > 2. Valid 1980-2099, where
; every fourth year is a leap year. Corrupt month/day fields are clamped,
; never indexed with.
daynum:
    ld (dn_date), hl
    call year_field
    ld (dn_y), a
    ld hl, (dn_date)
    ld b, 5
    ld c, 15
    call shr_mask
    dec a                        ; 0-based month; 0 and 13-15 land NC and
    cp 12                        ; clamp to January
    jr c, .mok
    xor a
.mok:
    ld (dn_m), a
    ld hl, (dn_date)
    ld b, 0
    ld c, 31
    call shr_mask
    sub 1                        ; D-1; a zero day field clamps to 0
    jr nc, .dok
    xor a
.dok:
    ld (dn_d), a
    ld a, (dn_y)
    ld d, 109
    ld e, a
    mul d, e                     ; DE = 109*Y; MUL D,E is Z80N (ED 30) and
    ld h, a                      ; leaves A alone
    ld l, 0                      ; HL = 256*Y, so HL+DE = 365*Y
    add hl, de
    ld a, (dn_y)
    add a, 3
    srl a
    srl a                        ; (Y+3)>>2 = leap days in the years before
    ld e, a
    ld d, 0
    add hl, de
    ld a, (dn_m)
    add a, a                     ; word table
    ld e, a
    ld d, 0
    push hl
    ld hl, cum
    add hl, de
    ld e, (hl)
    inc hl
    ld d, (hl)
    pop hl
    add hl, de                   ; += days before this month
    ld a, (dn_y)
    and 3
    jr nz, .noleap
    ld a, (dn_m)
    cp 2                         ; 0-based: March or later
    jr c, .noleap
    inc hl
.noleap:
    ld a, (dn_d)
    ld e, a
    ld d, 0
    add hl, de
    ret

cum:
    dw 0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334

; Out: A = HL mod 7. Destroys HL - the quotient is shifted out and
; discarded. The remainder stays under 7, so 2r+1 always fits A.
mod7:
    xor a
    ld b, 16
.loop:
    add hl, hl
    rla
    cp 7
    jr c, .next
    sub 7
.next:
    djnz .loop
    ret

int:
    ret                          ; no frame work; the chain calls this anyway

param:      db 0                 ; param1, parked before anything clobbers B
valid:      db 0                 ; 1 once fn 66 has taken a snapshot
snapDate:   dw 0
snapTime:   dw 0
snapSec:    db 0
today:      dw 0
stampbuf:   dw 0
dn_date:    dw 0
dn_then:    dw 0
dn_y:       db 0
dn_m:       db 0                 ; 0-based, clamped
dn_d:       db 0                 ; already D-1
name_hst:   db "GAME.HST", 0
handle:     db $FF

    ENDMODULE

    IFNDEF XBN_MODULE
xbn_end:
    SAVEBIN "GAME.XBN", XBN_ORG, xbn_end - XBN_ORG
    XBN_SCRATCH_END
    ENDIF
