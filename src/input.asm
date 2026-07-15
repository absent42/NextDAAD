; Resident parser/input state. Data only - code lives in overlay1
; (page 57) except wait_key_timeout (print.asm). Everything here must
; survive overlay swaps.

INP_MAX         equ 127

inpLine:    ds INP_MAX+1        ; editor line, ASCIIZ
inpPending: ds INP_MAX+1        ; orders after a separator, ASCIIZ
inpLast:    ds INP_MAX+1        ; last submitted order (recall), ASCIIZ
inpWord:    ds 6                ; current word, 5 chars + NUL, uppercase
inpLen:     db 0                ; editor: line length
inpCur:     db 0                ; editor: cursor index into inpLine
inpStartX:  db 0                ; editor: window cursor x at entry
inpStartY:  db 0                ; editor: window cursor y at entry
inpFromBuf: db 0                ; 1 = current order came from inpPending
prevVerb:   db 255              ; previousVerb for compound sentences
inpTOFrames: dw 0               ; timeout countdown, frames remaining
inpTOFrm:   db 0                ; editor countdown: last seen frame low byte
inpRepKey:  db 0                ; autorepeat: last raw key code
inpRepCnt:  db 0                ; autorepeat: frames until next repeat
inpRepFrm:  db 0                ; autorepeat: last seen frame low byte
inpPtr:     dw 0                ; parser: read cursor into inpPending
prnSeen:    db 0                ; parser: pronoun already seen this order
o2Pass:     db 0                ; parser: obj2_resolve pass (1 or 0)
inpRepFirst: db 0
