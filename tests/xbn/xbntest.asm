; xbntest.asm - fixture XBN for the sd\XBN leg. Not shipped.
; DEVICE ZXSPECTRUMNEXT (not in the Task 1 brief's fragment): sjasmplus
; only allows SAVEBIN in "real device emulation mode" (See DEVICE) -
; without it the assembler refuses the SAVEBIN below outright. Same
; device src\main.asm's own DEVICE line declares.
    DEVICE ZXSPECTRUMNEXT
    INCLUDE "../../authoring-kit/xbn.inc"
    ORG XBN_ORG
    XBN_HEADER ext_main, int_tick

ext_main:
    ; Contract on entry: A=B=param1, C=fn, HL=flags+param1,
    ; DE=objTable+param1*6, IX=flags base.
    ld (XBN_FLAGS+200), a       ; param1
    ld a, c
    ld (XBN_FLAGS+201), a       ; fn code
    ld a, (hl)
    ld (XBN_FLAGS+202), a       ; *(flags+param1)
    ld a, (de)
    ld (XBN_FLAGS+203), a       ; object location byte
    push ix
    pop hl
    ld a, h
    ld (XBN_FLAGS+204), a       ; IX high byte - expect $A2
    ld a, l
    ld (XBN_FLAGS+205), a       ; IX low byte - expect $00
    ld a, c
    cp 21
    jr z, .fn21
    cp 22
    jr z, .fn22
    cp 23
    jr z, .fn23
    cp 24
    jr z, .fn24
    cp 25
    jr z, .fn25
    cp 26
    jr z, .fn26
    cp 27
    jr z, .fn27
    cp 28
    jr z, .fn28
    cp 29
    jr z, .fn29
    cp 35
    jr z, .fn35
    cp 36
    jr z, .fn36
    cp 37
    jr z, .fn37
    ; unrecognised fn (incl. 30/31 mis-typed off-leg): CF discipline -
    ; deliberate clear, not whatever cp 27 left behind.
    or a
    ret
.fn37:
    jp busy_probe                 ; Task 7: SVC_BUSY probe
.fn36:
    jp getdate_probe              ; Task 6: SVC_GETDATE presence probe
.fn35:
    jp rng_soak_arm               ; Task 5: arm/disarm the SVC_RANDOM soak
.fn29:
    jp frames_delta               ; Task 4
.fn28:
    jp frames_snap                ; Task 4
.fn27:                          ; control: explicit success
    or a
    ret
.fn26:                          ; condition probe: ALWAYS fails the entry
    scf
    ret
.fn25:
    jp msg_multi                 ; GETMSG multi-fetch regression (the
                                 ; HL-clobber corruption, 2026-08-15)
.fn24:
    jp msg_probe_bad             ; Task 8: out-of-range check
.fn23:
    jp msg_probe                 ; Task 8: GETMSG probe
.fn22:
    jp fio_probe                ; Task 7
.fn21:
    jp svc_probe                 ; Task 6

svc_probe:
    call SVC_VERSION
    ld (XBN_FLAGS+206), a       ; expect 2
    call SVC_RANDOM
    ld b, a
    call SVC_RANDOM
    cp b                        ; two draws differing is probabilistic
    ld a, 1                     ;  but a frozen PRNG returning equal
    jr nz, .ok                  ;  bytes twice is the failure being
    dec a                       ;  hunted (stuck rng) - accept rare 0
.ok:
    ld (XBN_FLAGS+207), a       ; expect 1 (almost always)
    ld hl, .msg
    call SVC_PUTS                ; visible banner on screen
    or a
    ret
.msg: db "XBN SVC OK ", 0

; Task 5: arm/disarm the int_tick SVC_RANDOM soak. p1 nonzero arms (int_tick
; then draws once per tick and tracks the sticky-changed bit, flag 219);
; zero disarms. Echoed p1 already sits at XBN_FLAGS+200 (ext_main's entry
; preamble) - read it from there, not from A/C, which the fn dispatch chain
; above has since overwritten.
rng_soak_arm:
    ld a, (XBN_FLAGS+200)
    ld (XBN_FLAGS+217), a
    or a
    ret

; Task 6 probe: SVC_GETDATE presence. Flag 223 arrives poisoned to 9
; (XDAT's LET 223 9) and must never keep that value - 1 = RTC present
; (date/time also stored to 224-227, low byte first per SVC_GETDATE's
; BC/DE/H/L order), 0 = no RTC. Either outcome is a valid pass; only a
; surviving 9 (a hang or an unset flag) is a failure. CF cleared on
; this fn's own ret regardless of the call's own CF.
getdate_probe:
    call SVC_GETDATE
    jr c, .none
    ld a, 1
    ld (XBN_FLAGS+223), a
    ld a, b
    ld (XBN_FLAGS+224), a
    ld a, c
    ld (XBN_FLAGS+225), a
    ld a, d
    ld (XBN_FLAGS+226), a
    ld a, e
    ld (XBN_FLAGS+227), a
    or a
    ret
.none:
    xor a
    ld (XBN_FLAGS+223), a
    ret

; Task 7 probe: SVC_BUSY, the foreground-invisibility contract. Every
; busy source (vidPlaying, cardBusy, palBusy) is synchronous with the
; mainline - a foreground read is ALWAYS 0. Flag 228 arrives poisoned
; to 9 (XBSY's LET 228 9) and must never keep that value.
busy_probe:
    call SVC_BUSY
    ld (XBN_FLAGS+228), a
    or a
    ret

call_target:
    ; COUPLED to tests\extern.dsf's XCAL entry (CALL lsb msb) - the
    ; address here must match the literal bytes in that DSF's PRO 5
    ; XCAL entry. Do not copy an address from a comment: read
    ; tests\out\xbn\xbntest.sym after assembly. build-tests.ps1 now
    ; enforces the coupling and fails the build if this label (or
    ; tail_marker) moves without the DSF being re-encoded.
    ld a, $77
    ld (XBN_FLAGS+220), a
    ret

int_tick:
    ; 50Hz: increment flag 221, wrapping. IX = flags base per contract,
    ; but +221 is outside Z80's (ix+d) signed-displacement range (max
    ; +127 from IX) - the Task 1 brief's "inc (ix+221)" does not
    ; assemble (sjasmplus: "Offset out of range"). Same target byte
    ; (XBN_FLAGS+221) reached via absolute addressing instead; 8-bit
    ; INC wraps 255->0 the same as the ix+d form would have.
    ld a, (XBN_FLAGS+221)
    inc a
    ld (XBN_FLAGS+221), a
    ; Task 5 soak: while armed (fn 35, flag 217 nonzero), draw SVC_RANDOM
    ; once per tick and compare to the previous draw - any two differing
    ; sets the sticky "alive" bit (219); 125 hook draws (XRSK's PAUSE 250)
    ; all equal has probability ~0 for a live PRNG, so 219 staying 0
    ; flags a wedged or torn shared stream. svc_random's DI/EI bracket
    ; samples/restores the caller's own interrupt state - hook context
    ; is not unconditionally interrupts-off (the frame ISR's audio path
    ; EIs before reaching the hook, interrupts.asm:282); this fixture
    ; leg happens to arrive disabled (no audio armed). AF/HL clobber
    ; here is already established practice in this hook - .xbnhook_fast
    ; (interrupts.asm) saves full context before the call.
    ld a, (XBN_FLAGS+217)
    or a
    ret z
    call SVC_RANDOM              ; A = new draw; svc_random's bracket
                                 ; restores this call's own entry state
    ld hl, XBN_FLAGS+218
    cp (hl)
    ld (hl), a                   ; store new draw either way; cp did not
                                 ; clobber A
    ret z                        ; unchanged: leave the sticky bit as-is
    ld a, 1
    ld (XBN_FLAGS+219), a
    ret

; Task 7 probe: write 8 bytes to XBNFIO.TMP, close, reopen, read them
; back and compare. ESX_MODE_W/ESX_MODE_READ are esxDOS's own F_OPEN mode
; byte values (not re-exported by xbn.inc, which documents only the
; service calling convention) - defined locally here matching
; src\nextdaad.inc's ESX_MODE_W ($0E, write/create/truncate) and
; ESX_MODE_READ ($01).
ESX_MODE_READ equ $01
ESX_MODE_W    equ $0E
fio_probe:
    ld ix, .fname
    ld b, ESX_MODE_W
    call SVC_FOPEN
    jr c, .fail
    ld (.hnd), a
    ld ix, .wbuf
    ld bc, 8
    call SVC_FWRITE
    ld a, (.hnd)
    call SVC_FCLOSE
    ld ix, .fname
    ld b, ESX_MODE_READ
    call SVC_FOPEN
    jr c, .fail
    ld (.hnd), a
    ld ix, .rbuf
    ld bc, 8
    call SVC_FREAD
    ld a, (.hnd)
    call SVC_FCLOSE
    ld b, 8
    ld hl, .wbuf
    ld de, .rbuf
.cmp:
    ld a, (de)
    cp (hl)
    jr nz, .fail
    inc hl
    inc de
    djnz .cmp
    ld a, 1
    ld (XBN_FLAGS+208), a
    or a                         ; CF discipline: deliberate clear, not
                                 ; whatever the last cp (hl) left behind
    ret
.fail:
    xor a
    ld (XBN_FLAGS+208), a
    ret
.fname: db "XBNFIO.TMP", 0
.hnd:   db 0
.wbuf:  db $11,$22,$33,$44,$55,$66,$77,$88
.rbuf:  ds 8

; Task 8 probe: decode user message 0 ("TICKER MESSAGE FOR GETMSG",
; MTX, Task 1's extern.dsf) into GETMSG's staging buffer, then echo it
; back through SVC_PUTCHAR - GETMSG returns a length-counted buffer,
; NOT an ASCIIZ string, so SVC_PUTS (which scans for a NUL) is wrong
; here; the bounded loop below prints exactly BC bytes.
msg_probe:
    xor a                       ; message 0
    call SVC_GETMSG
    jr c, .fail
    ld a, b
    or a                        ; length < 256 expected here
    jr nz, .len_ok
    ld a, c
    or a
    jr z, .fail                 ; zero length = decode failed
.len_ok:
    ld a, c
    ld (XBN_FLAGS+209), a       ; observed length
    ld a, (hl)
    ld (XBN_FLAGS+210), a       ; first char - 'T' (84) from Task 1's MTX
.print:
    ld a, b                     ; bounded print loop over the full BC
    or c                        ; count (up to 256, so B alone can't be
    jr z, .print_done           ; trusted - BC=0 is the only stop test)
    ld a, (hl)
    push hl                     ; SVC_PUTCHAR -> prn_decoded is free to
    push bc                     ; corrupt HL/BC (svc_puts brackets its
    call SVC_PUTCHAR             ; own call the same way) - without this
    pop bc                      ; the loop pointer/counter get scrambled
    pop hl                      ; after the first character
    inc hl
    dec bc
    jr .print
.print_done:
    ld a, 1
    ld (XBN_FLAGS+211), a
    or a                         ; CF discipline: deliberate clear (the
                                 ; loop-exit OR already cleared it, but
                                 ; state that explicitly, not by accident)
    ret
.fail:
    xor a
    ld (XBN_FLAGS+211), a
    ret

; Task 8 probe: GETMSG must report CF set, A=$FF.
; 255: the highest message number, out of range while the MTX holds
; fewer than 256 messages. NOT a small number: DRC compiles every
; inline MES "literal" into the MTX, so the count grows with the
; fixture (66 as shipped; the ceiling is 255) and a small probe rots
; into range - message 50 did exactly that.
msg_probe_bad:
    ld a, 255
    call SVC_GETMSG              ; sets CF on out-of-range (esxDOS-style
                                 ; convention) - that CF is DATA here, not
                                 ; this fn's own verdict; must not leak
                                 ; through to the split-return check
    ld a, 0
    jr nc, .store
    ld a, 1
.store:
    ld (XBN_FLAGS+212), a       ; expect 1 (CF set = out of range)
    or a                         ; CF discipline: explicit clear, so the
                                 ; probe's own out-of-range CF does not
                                 ; also fail the calling entry
    ret

; fn 25: the SVC_GETMSG multi-fetch regression (svc-getmsg HL-clobber
; corruption, found in the field 2026-08-15). Fetches the six
; TOKEN-COMPRESSED messages 1-6 in one call and checks, per message,
; the returned length and first two characters against MSGTAB (which
; mirrors the texts authored in tests/extern.dsf - change either,
; change both). Flag 213 = number of messages that verified (expect
; 6). The original defect wrote decoded characters into the DDB's own
; token table from the second token reference onward, so with it
; present this probe reports 1 (message 1's first fetch decodes before
; the damage compounds - or fewer) and the interpreter's own text
; garbles afterwards; the DSF entry prints a system message after this
; probe precisely to make that visible.
msg_multi:
    xor a
    ld (XBN_FLAGS+213), a
    ld a, 1
    ld (mmCur), a
.next:
    ld a, (mmCur)
    call SVC_GETMSG              ; out HL = buffer, BC = length
    jr c, .done                  ; out of range = past the corpus
    ; expected row: MSGTAB + (msg-1)*3 = len, char1, char2
    ld a, (mmCur)
    dec a
    ld e, a
    add a, a
    add a, e                     ; *3
    ld e, a
    ld d, 0
    push hl
    ld hl, MSGTAB
    add hl, de
    ld a, (hl)                   ; expected length (all < 256, so B
    inc hl                       ; must be 0 and C must equal this)
    ld d, (hl)                   ; expected char 1
    inc hl
    ld e, (hl)                   ; expected char 2
    pop hl
    cp c
    jr nz, .mismatch
    ld a, b
    or a
    jr nz, .mismatch
    ld a, (hl)
    cp d
    jr nz, .mismatch
    inc hl
    ld a, (hl)
    cp e
    jr nz, .mismatch
    ld a, (XBN_FLAGS+213)
    inc a
    ld (XBN_FLAGS+213), a
.mismatch:
    ld a, (mmCur)
    inc a
    ld (mmCur), a
    cp 7
    jr c, .next
    or a                         ; CF discipline: deliberate clear - the
                                 ; corpus (messages 1-6) was exhausted
                                 ; normally, all six verified
    ret
.done:
    ret                          ; CF discipline: deliberate, inherited -
                                 ; SVC_GETMSG's out-of-range CF (corpus
                                 ; overrun) passed straight through;
                                 ; unreachable at the fixture's current
                                 ; MTX size, kept as documented failure

; Task 4 probe: snapshot SVC_FRAMES to flags 214 (L) / 215 (H), stash the
; word for frames_delta below.
frames_snap:
    call SVC_FRAMES
    ld (frmSnap), hl
    ld a, l
    ld (XBN_FLAGS+214), a
    ld a, h
    ld (XBN_FLAGS+215), a
    or a                         ; CF discipline: deliberate clear
    ret

; Task 4 probe: delta since frames_snap, low byte to flag 216 - the
; delta is what XFRM's PAUSE window asserts; a stub row (CF/$FF) or a
; dead counter yields a wild or zero delta.
frames_delta:
    call SVC_FRAMES
    ld de, (frmSnap)
    or a
    sbc hl, de
    ld a, l
    ld (XBN_FLAGS+216), a
    or a                         ; CF discipline: deliberate clear
    ret

frmSnap: dw 0

mmCur:  db 0
; len, first char, second char - per tests/extern.dsf MTX 1-6
MSGTAB:
    db 51, 'N', 'o'
    db 51, 'S', 'o'
    db 53, 'E', 'a'
    db 53, 'W', 'e'
    db 54, 'M', 'i'
    db 52, 'M', 'o'

    ; pad proves >8K binaries load into both pages
    ds $2100, $E5
tail_marker:
    ld a, $99
    ld (XBN_FLAGS+222), a       ; callable via CALL to prove page 2 mapped
    ret
xbn_end:

    SAVEBIN "tests/out/xbn/GAME.XBN", XBN_ORG, xbn_end - XBN_ORG
