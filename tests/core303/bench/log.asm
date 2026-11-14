; Row log: built in RAM pages LOG_PAGE.. during the run, appended to CORE303.LOG by
; log_flush at the end (no file I/O inside any timed window), then read back.

LOG_PAGE         equ 82      ; 82-87: past the bench's buffers, inside a 1 MB board
LOG_PAGES        equ 6
LOG_WIN          equ $C000   ; MMU6, mapped on every access: rows remap it
LOG_LIMIT        equ LOG_PAGES * $2000 - 256   ; offset: putc refuses at or past this
LOG_CAP          equ LOG_LIMIT
    ASSERT low LOG_LIMIT == 0 && LOG_PAGES <= 8 && LOG_PAGE + LOG_PAGES <= SRAM_PROBE_PAGE
LOG_HDR_MAX      equ 128     ; #CORE303, #NR, #SRAM
LOG_ROW_MAX      equ 72      ; a row with Q, CK, L and E, or a #SKIP line
LOG_END_MAX      equ 16
LOG_RD_LEN       equ 256

; esxDOS API, as src/nextdaad.inc
ESX_GETSETDRV    equ $89
ESX_F_OPEN       equ $9A
ESX_F_CLOSE      equ $9B
ESX_F_READ       equ $9D
ESX_F_WRITE      equ $9E
ESX_F_SEEK       equ $9F
ESX_F_FSTAT      equ $A1     ; +7 (4 B) = file size
ESX_MODE_READ    equ $01
LOG_WMODE        equ $0B     ; open or create, read + write: append by seeking to the size

; LOG FAIL hh: bits 7-5 the step, bits 4-0 the esxDOS error, or 0 for a short
; count, a position or size off, or a mismatch. 1F = the buffer filled.
LOG_E_FULL       equ $1F     ; step 0 makes no esxDOS call, so 1F is unique
LOG_S_OPEN       equ $20
LOG_S_END        equ $40
LOG_S_WR         equ $60
LOG_S_CLW        equ $80
LOG_S_REOP       equ $A0
LOG_S_RD         equ $C0
LOG_S_CMP        equ $E0

; Start the buffer: #CORE303, #NR and #SRAM lines. Needs hdr_read first.
log_header:
    ld hl, 0
    ld (logPtr), hl
    ld hl, 0
    ld (logRows), hl
    xor a
    ld (logOver), a
    ld hl, logTxtHdr
    call log_puts
    ld hl, logTxtStamp
    call log_puts
    call log_eol
    ld hl, logTxtNr
    call log_puts
    ld hl, nrList
    ld de, nrVals
    ld b, NR_COUNT
.nr:
    ld a, ' '
    call log_putc
    ld a, (hl)
    inc hl
    call log_hex8
    ld a, '='
    call log_putc
    ld a, (de)
    inc de
    call log_hex8
    djnz .nr
    call log_eol
    ld hl, logTxtSram
    call log_puts
    ld hl, logTxtKb1
    ld a, (sramExp)
    or a
    jr z, .kb
    ld hl, logTxtKb2
.kb:
    call log_puts
    jp log_eol

; "#SKIP <tag> <reason>": HL = 4-byte tag, DE = reason (0-terminated).
log_skip:
    push de
    push hl
    ld hl, logTxtSkip
    call log_puts
    pop hl
    call log_tag
    ld a, ' '
    call log_putc
    pop hl
    call log_puts
    jp log_eol

; End a row line and count it for #END. Corrupts AF, HL.
log_row_end:
    ld hl, (logRows)
    inc hl
    ld (logRows), hl
log_eol:
    ld a, 10
; A -> buffer (logPtr = offset); at LOG_LIMIT the byte is dropped and logOver set.
; Corrupts F; MMU6 = the byte's page.
log_putc:
    push hl
    ld hl, (logPtr)
    push af
    ld a, h
    cp high LOG_LIMIT
    jr nc, .full
    call log_map
    pop af
    ld (hl), a
    ld hl, (logPtr)
    inc hl
    ld (logPtr), hl
    pop hl
    ret
.full:
    pop af
    ld hl, logOver
    ld (hl), 1
    pop hl
    ret

; HL = log offset -> HL = its address in LOG_WIN, its page in MMU6. Corrupts AF.
log_map:
    ld a, h
    rlca
    rlca
    rlca
    and 7                        ; offset >> 13
    add a, LOG_PAGE
    nextreg NR_MMU6, a
    ld a, h
    and $1F
    or high LOG_WIN
    ld h, a
    ret

; HL = 0-terminated string. Out: HL past the 0. Corrupts AF.
log_puts:
    ld a, (hl)
    inc hl
    or a
    ret z
    call log_putc
    jr log_puts

; HL = 4-byte tag. Corrupts AF, HL.
log_tag:
    push bc
    ld b, 4
.ch:
    ld a, (hl)
    inc hl
    call log_putc
    djnz .ch
    pop bc
    ret

; Corrupts AF.
log_hex16:
    ld a, h
    call log_hex8
    ld a, l
log_hex8:
    push af
    swapnib
    call hex_digit
    call log_putc
    pop af
    call hex_digit
    jp log_putc

; Append "#END hhhh" and the buffer to CORE303.LOG, close, reopen, check the
; size grew by exactly the buffer, read it back and compare. Shows LOG OK or
; LOG FAIL hh (red border). Corrupts everything.
log_flush:
    ld (logSp), sp               ; every failure unwinds to here
    ld a, $FF
    ld (logH), a                 ; no handle open
    ld hl, logTxtEnd
    call log_puts
    ld hl, (logRows)
    call log_hex16
    call log_eol
    xor a
    ld (logStep), a
    ld a, (logOver)
    or a
    ld a, LOG_E_FULL
    jp nz, log_fail
    ld hl, (logPtr)
    ld (logLen), hl
    ei                           ; esxDOS under the IM2 stub, as NextDAAD calls it
    ld a, LOG_S_OPEN
    ld (logStep), a
    ld b, LOG_WMODE
    call log_open
    ld a, LOG_S_END
    ld (logStep), a
    call log_size
    ld hl, logStat + 7           ; the size is the append offset
    ld de, logOfs
    ld bc, 4
    ldir
    call log_seek
    ld a, LOG_S_WR
    ld (logStep), a
    ld hl, 0
    ld (logCmp), hl              ; offset written so far
    ld hl, (logLen)
    ld (logLeft), hl
.wr:                             ; one page a write: offsets stay page-aligned
    ld hl, (logLeft)
    ld a, h
    or l
    jr z, .wrote
    ld bc, $2000
    sbc hl, bc                   ; CF = 0 from or l
    jr nc, .wfull
    ld bc, (logLeft)             ; under a page: the rest
    ld hl, 0
.wfull:
    ld (logLeft), hl
    ld (logChunk), bc
    ld hl, (logCmp)
    call log_map
    push hl
    pop ix
    ld a, (logH)
    rst $08
    db ESX_F_WRITE
    jp c, log_fail
    ld hl, (logChunk)            ; Fc = 0 can still return a short BC
    or a
    sbc hl, bc
    jp nz, log_short
    ld hl, (logCmp)
    add hl, bc
    ld (logCmp), hl
    jr .wr
.wrote:
    ld a, LOG_S_CLW
    ld (logStep), a
    call log_close               ; written data persists only once closed
    jp c, log_fail
    ld a, LOG_S_REOP
    ld (logStep), a
    ld b, ESX_MODE_READ
    call log_open
    call log_size
    ld hl, (logStat + 7)         ; size - offset must equal logLen
    ld de, (logOfs)
    or a
    sbc hl, de
    ex de, hl
    ld hl, (logStat + 9)
    ld bc, (logOfs + 2)
    sbc hl, bc
    jp nz, log_short
    ld hl, (logLen)
    or a
    sbc hl, de
    jp nz, log_short
    call log_seek
    ld a, LOG_S_RD
    ld (logStep), a
    ld hl, 0
    ld (logCmp), hl              ; offset compared so far
    ld hl, (logLen)
    ld (logLeft), hl
.chunk:
    ld hl, (logLeft)
    ld a, h
    or l
    jr z, .done
    ld bc, LOG_RD_LEN
    ld a, h
    or a
    jr nz, .take
    ld c, l
    ld b, 0
.take:
    or a
    sbc hl, bc
    ld (logLeft), hl
    ld (logChunk), bc
    ld a, (logH)
    ld ix, logRd
    rst $08
    db ESX_F_READ
    jp c, log_fail
    ld hl, (logChunk)            ; EOF before the count
    or a
    sbc hl, bc
    jp nz, log_short
    ld hl, (logCmp)              ; 256-byte chunks from 0 never cross a page
    call log_map
    ex de, hl
    ld hl, logRd
.cmp:
    ld a, (de)
    cp (hl)
    jr nz, .bad
    inc hl
    inc de
    dec bc
    ld a, b
    or c
    jr nz, .cmp
    ld hl, (logCmp)
    ld bc, (logChunk)
    add hl, bc
    ld (logCmp), hl
    jr .chunk
.bad:
    ld a, LOG_S_CMP
    ld (logStep), a
    jr log_short
.done:
    ld a, LOG_S_CMP
    ld (logStep), a
    call log_close
    jp c, log_fail
    xor a
    jr log_show

; A short count, a position or size off, or a mismatch at the current step.
log_short:
    xor a
; A = the esxDOS error at the current step: close any open handle, then show.
log_fail:
    and $1F
    ld hl, logStep
    or (hl)
    ld sp, (logSp)
    ld (logErr), a
    ld a, (logH)
    inc a                        ; $FF: no handle
    call nz, log_close           ; its result is not the one reported
    ld a, (logErr)
; A = 0 (LOG OK) or the code (LOG FAIL hh).
log_show:
    di
    push af
    ld bc, LOG_TXT_ROW << 8
    call ula_at
    ld hl, logTxtLog
    call ula_puts
    pop af
    or a
    ld hl, logTxtOk
    jp z, ula_puts
    push af
    ld a, 2
    out ($FE), a                 ; red border
    ld hl, logTxtFail
    call ula_puts
    pop af
    jp ula_hex8

; B = F_OPEN mode: default drive, open CORE303.LOG, keep the handle.
log_open:
    push bc
    xor a
    rst $08
    db ESX_GETSETDRV             ; A = the default drive
    pop bc
    jp c, log_fail
    ld ix, logName
    rst $08
    db ESX_F_OPEN
    jp c, log_fail
    ld (logH), a
    ret

; F_FSTAT the open handle into logStat.
log_size:
    ld a, (logH)
    ld ix, logStat
    rst $08
    db ESX_F_FSTAT
    ret nc
    jp log_fail

; Seek to logOfs from the start (IXL = 0); BCDE returned must equal it.
log_seek:
    ld de, (logOfs)
    ld bc, (logOfs + 2)
    ld a, (logH)
    ld ix, 0
    rst $08
    db ESX_F_SEEK
    jp c, log_fail
    ld hl, (logOfs)
    or a
    sbc hl, de
    jp nz, log_short
    ld hl, (logOfs + 2)
    sbc hl, bc                   ; CF = 0: the low words matched
    ret z
    jp log_short

; Close the handle and mark it closed. Out: F_CLOSE's CF and A.
log_close:
    ld hl, logH
    ld a, (hl)
    ld (hl), $FF
    rst $08
    db ESX_F_CLOSE
    ret

logTxtHdr:   db "#CORE303 STANDALONE ", 0
logTxtStamp: db STAMP_STR, 0
logTxtNr:    db "#NR", 0
logTxtSram:  db "#SRAM ", 0
logTxtKb1:   db "1024", 0
logTxtKb2:   db "2048", 0
logTxtSkip:  db "#SKIP ", 0
logTxtEnd:   db "#END ", 0
logTxtCW:    db " C=W S=", 0
logTxtR:     db " R=", 0
logTxtF:     db " F=", 0
logTxtD:     db " D=", 0
logTxtN:     db " N=", 0
logTxtQ:     db " Q=", 0
logTxtCK:    db " CK=", 0
logTxtL:     db " L=", 0
logTxtOK:    db " OK", 0
logTxtBAD:   db " BAD", 0
logName:     db "CORE303.LOG", 0
logTxtLog:   db "LOG ", 0
logTxtOk:    db "OK", 0
logTxtFail:  db "FAIL ", 0

logPtr:      dw 0
logRows:     dw 0
logOver:     db 0
logSp:       dw 0
logH:        db 0
logStep:     db 0
logErr:      db 0
logLen:      dw 0
logLeft:     dw 0
logChunk:    dw 0
logCmp:      dw 0
logOfs:      ds 4
logStat:     ds 11
logRd:       ds LOG_RD_LEN
