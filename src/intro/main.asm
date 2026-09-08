; NextDAAD loader intro launcher. Boots, plays INTRO\INTRO.DAT, chain-loads
; nextdaad.nex from the launch directory. Every failure before the hand-off
; ends at the game.
    DEVICE ZXSPECTRUMNEXT
    INCLUDE "intro.inc"
    ORG CODE_ORG
main:
    di
    ld sp, STACK_TOP
    call var_init                    ; before hw_init: hw_init records hz60
    call hw_init
    call audio_silence
    call lerp_init
    call im2_init
    call esx_init
 IFDEF DEBUG
    call dbg_init
 ENDIF
    jp chain_run

; Zero the variable block, then the few non-zero defaults.
var_init:
    ld hl, varStart
    ld de, varStart+1
    ld bc, varEnd-varStart-1
    ld (hl), 0
    ldir
    ld a, $FF
    ld (loadHandle), a
    ld (pcmHandle), a
    ld a, BANK_SURF_A
    ld (frontBank), a
    ld a, BANK_SURF_B
    ld (backBank), a
    ld a, 80
    ld (cols), a
    ld a, 160
    ld (tmStride), a
    ; identity sample translation table
    ld hl, pcmXlat
    xor a
.x:
    ld (hl), a
    inc l
    inc a
    jr nz, .x
    ret

    INCLUDE "hw.asm"
    INCLUDE "isr.asm"
    INCLUDE "esx.asm"
    INCLUDE "input.asm"
    INCLUDE "aud.asm"
    INCLUDE "dbg.asm"
    INCLUDE "chain.asm"

; ---- variables ----
varStart:
frameCounter:   dw 0
frameFlag:      db 0
hz60:           db 0
showState:      db 0
slideIdx:       db 0
slideCount:     db 0
holdLeft:       dw 0
holdFrame:      dw 0
curSlide:       ds 16
curItem:        ds 12
loadRec:        ds 16
frontBank:      db 0
backBank:       db 0
l2Mode:         db 0
loadState:      db 0
loadSlide:      db 0
loadHandle:     db 0
loadPage:       db 0
loadOfs:        dw 0
loadPages:      db 0
loadMode:       db 0
transType:      db 0
transFrames:    dw 0
transFrame:     dw 0
transColour:    db 0
transLines:     dw 0
transDone:      dw 0
transPer:       dw 0
transPhase:     db 0
transPages:     db 0
firstTrans:     db 0
failRun:        db 0
fadeK:          db 0
musicKind:      db 0
fadeFrames:     dw 0
fadeFrame:      dw 0
fading:         db 0
skipMode:       db 0
skipWindow:     dw 0
loopFlag:       db 0
keyEdge:        db 0
keyPrev:        db 0
keyCount:       db 0
lastCode:       db 0
scrollP:        dw 0
scrollLine:     db 0
scrollSpeed:    db 0
scrollAttr:     db 0
scrollLines:    db 0
scrollFirst:    db 0
borderCol:      db 0
fontKind:       db 0
cols:           db 0
tmStride:       db 0
endTrans:       db 0
endColour:      db 0
endFrames:      dw 0
dbgSeq:         db 0
pcmWr:          dw 0
pcmHandle:      db 0
isrAudio:       db 0
esxDrive:       db 0
ndawSlots:      ds 3
ndrPages:       ds 9
nameBuf:        ds 24
varEnd:
    ALIGN 256                        ; bounce on a page boundary: LDWS and INC E step it
bounce:         ds 1024
akyRetGuard:    ds 8
akyRetShadow:   ds 30
    ALIGN 256
pcmXlat:        ds 256
lerpTab:        ds 255
    ASSERT $ - lerpTab == 17*15       ; k 0..16 x d -7..7, hw.asm lerp_init (rubric 8)

    ASSERT $ <= RESIDENT_LIMIT
    DISPLAY "intro resident ends at ", $, " headroom ", /D, RESIDENT_LIMIT - $

    CSPECTMAP "build/intro.map"
    SAVENEX OPEN "build/intro.nex", main, STACK_TOP
    SAVENEX CORE 3, 0, 0
    SAVENEX CFG 0
    SAVENEX AUTO
    SAVENEX CLOSE
