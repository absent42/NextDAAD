; Resident parser/input state. Data only - code lives in overlay1
; (page 57) except wait_key_timeout (print.asm). Everything here must
; survive overlay swaps.

INP_MAX         equ 127

inpLine:    ds INP_MAX+1        ; editor line, ASCIIZ
; SP16 B21 - the quoted section split out of the current order lives
; here, ASCIIZ, empty when the order had no quote. It ALIASES inpLine
; deliberately: by the time quote_split runs (h_parse .extract), the
; typed line has already been ingested into inpPending and echoed by
; the flag-49 bit-4 reprint, so inpLine is dead until the next
; inp_edit refills it. That buys a full INP_MAX+1 store for zero
; resident bytes, which matters - the resident has 121 bytes of
; headroom and is frozen. The one thing it costs: SAVE/LOAD prompt
; through inp_edit (sav_prompt, overlay1.asm), so a SAVE between a
; PARSE 0 and a PARSE 1 would lose the quoted section. No reference
; game does that - SAVE ends the entry - but it is the aliasing's only
; observable edge, recorded here rather than discovered later.
inpQuoted   equ inpLine
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
capsLock:    db 0               ; caps-lock toggle state (letters only,
                                 ; classic semantics); CAPS+2 flips this
                                 ; in overlay1.asm's kb_char - see that
                                 ; routine for the audit/fix note
capsLockArmed: db 0             ; transient: set when CAPS+2 is freshly
                                 ; detected as a new keypress, consumed
                                 ; (cleared) at the settled emit so a
                                 ; long hold cannot re-toggle every
                                 ; autorepeat tick
