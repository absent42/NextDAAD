; Show state machine (spec 6.3). The current slide's record is refetched
; into curSlide whenever the loader may have replaced it.
show_boot:
    xor a
    ld (slideIdx), a
    ld (showState), a                ; SS_LOAD1
    ld a, 1
    ld (firstTrans), a
    xor a
    call slide_fetch
    call l2_setup
    ld a, (borderCol)
    call border_set
    call aud_open
    xor a
    jp load_begin

; A = colour. With the ULA output off the border shows the fallback colour
; NR $4A (the interpreter's BORDER record), so that is what is written.
border_set:
    nextreg NR_FALLBACK, a
    ret

; One read per frame: the sample ring first when it needs one, else the
; picture prefetch.
frame_reads:
    ld a, (musicKind)
    cp MUS_PCM
    jr nz, .pic
    call pcm_refill                  ; NZ = it read this frame
    ret nz
.pic:
    jp load_service

show_step:
    ld a, (showState)
    cp SS_END
    jp z, show_end_step
    ld a, (keyEdge)
    or a
    jr z, .nokey
    ld a, (showState)
    cp SS_KEY
    jp z, show_next
    ld a, (skipMode)
    cp SKIP_NONE
    jr z, .nokey
    cp SKIP_SLIDE
    jr z, .skipslide
    ld hl, (frameCounter)
    ld de, (skipWindow)
    or a
    sbc hl, de
    jr c, .nokey                     ; inside the no-skip window
    ld hl, 25
    jp show_end_begin
.skipslide:
    ld a, (showState)
    cp SS_HOLD
    jp z, show_next
    cp SS_SCROLL
    jp z, show_next
.nokey:
    ld a, (showState)
    cp SS_LOAD1
    jr z, .wait
    cp SS_WAIT
    jr z, .wait
    cp SS_TRANS
    jr z, .trans
    cp SS_HOLD
    jr z, .hold
    cp SS_KEY
    jp z, .key                       ; out of jr range from here
    cp SS_SCROLL
    jp z, .scroll
    ret
.wait:
    ld a, (loadState)
    cp LS_DONE
    jr z, .start
    cp LS_FAIL
    ret nz
    xor a
    ld (loadState), a                ; idle, so show_next starts the next load
    ld hl, failRun
    inc (hl)
    ld a, (slideCount)
    cp (hl)
    jp z, chain_run                  ; every slide failed: straight to the game
    jp show_next
.start:
    xor a
    ld (loadState), a
    ld (failRun), a
    ld a, (slideIdx)
    call slide_fetch
    call trans_begin
    ld a, SS_TRANS
    ld (showState), a
    ret
.trans:
    call trans_step
    ret nz
    xor a
    ld (firstTrans), a
    call show_prefetch_next
    ld a, (slideIdx)
    call slide_fetch
    ld hl, 0
    ld (holdFrame), hl
    ld hl, (curSlide+SL_HOLD)
    ld a, h
    cp $FF
    jr nz, .timed
    ld a, l
    cp $FF
    jr z, .keyhold
    call scroll_begin
    ld a, SS_SCROLL
    ld (showState), a
    ret
.keyhold:
    ld a, SS_KEY
    ld (showState), a
    ret
.timed:
    ld (holdLeft), hl
    ld a, SS_HOLD
    ld (showState), a
    ret
.hold:
    call caption_service
    ld hl, (holdFrame)
    inc hl
    ld (holdFrame), hl
    ld hl, (holdLeft)
    dec hl
    ld (holdLeft), hl
    ld a, h
    or l
    ret nz
    jp show_next
.key:
    call caption_service
    ld hl, (holdFrame)
    inc hl
    ld (holdFrame), hl
    ret
.scroll:
    call scroll_step
    ret nz
    jp show_next

; Start loading the slide after slideIdx (slide 0 under LOOP) into the back
; surface; nothing after the last slide without LOOP.
show_prefetch_next:
    ld a, (slideIdx)
    inc a
    ld hl, slideCount
    cp (hl)
    jr c, .go
    ld a, (loopFlag)
    or a
    ret z
    xor a
.go:
    jp load_begin

; The current slide is over: clear text, advance, wait for its load, or end.
show_next:
    call text_clear
    ld a, (slideIdx)
    inc a
    ld hl, slideCount
    cp (hl)
    jr c, .have
    ld a, (loopFlag)
    or a
    jr z, .end
    xor a
.have:
    ld (slideIdx), a
    ld a, (loadState)
    or a
    jr nz, .loading                  ; the prefetch is already on its way
    ld a, (slideIdx)
    call load_begin
.loading:
    ld a, SS_WAIT
    ld (showState), a
    ret
.end:
    ld hl, 0
    jp show_end_begin

; HL = frame cap (0 = none): END transition and the music fade.
show_end_begin:
    push hl
    call text_clear
    ld a, (showState)
    cp SS_TRANS
    call z, trans_finish_now         ; a skip mid-fade lands on the incoming picture first
    ld a, (loadHandle)
    cp $FF
    jr z, .noload
    call esx_close_a                 ; HL (frame cap) stays on the stack across this call
    ld a, $FF
    ld (loadHandle), a
.noload:
    pop hl
    xor a
    ld (loadState), a
    ld a, (endTrans)
    or a
    jp z, chain_run                  ; END CUT
    ld de, (endFrames)
    ld a, h
    or l
    jr z, .use
    push hl
    or a
    sbc hl, de                       ; cap - endFrames
    pop hl
    jr nc, .use                      ; cap >= endFrames: use endFrames
    ex de, hl                        ; DE = cap
.use:
    ld (transFrames), de
    ex de, hl
    call aud_fade_begin
    call fade_out_begin
    ld a, SS_END
    ld (showState), a
    ret

show_end_step:
    call aud_fade_step
    call fade_out_step
    ret nz
    jp chain_run

; Replaced by later tasks (Task 12/13 text, Task 9 fade, Task 16 stream).
text_clear:
    ret
caption_service:
    ret
scroll_begin:
    ret
scroll_step:
    xor a
    ret
fade_out_begin:
    ret
fade_out_step:
    xor a
    ret
trans_finish_now:
    ret
pcm_refill:
    xor a
    ret
