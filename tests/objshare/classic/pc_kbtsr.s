# KBTSR.COM - INT 16h key feeder and mode 13h screen dumper for DOSBox.
# "x+O" = COM offset of x (drive_pc.py rewrites it). Polled from the game's own INT 16h calls (game idle), once per BIOS tick:
# CMD.TXT = 4-byte seq, op, data. New seq -> op K: queue (ascii, scan)
# pairs; op D: write A000:0000 64000 bytes + 768-byte DAC to SCR.BIN.
# ACK.TXT <- seq once the op is done and the queue has drained.
.intel_syntax noprefix
.code16
base:
        jmp     install

old16:   .long  0
lasttick: .word 0xffff
qhead:   .word  0
qlen:    .word  0
ackpend: .byte  0
busy:    .byte  0
lastseq: .ascii "----"
cmdname: .asciz "CMD.TXT"
ackname: .asciz "ACK.TXT"
scrname: .asciz "SCR.BIN"


int16:
        cmp     ah, 0
        je      h_read
        cmp     ah, 0x10
        je      h_read
        cmp     ah, 1
        je      h_peek
        cmp     ah, 0x11
        je      h_peek
        jmp     dword ptr cs:[old16+O]

h_peek:
        call    service
        cmp     word ptr cs:[qlen+O], 0
        je      peek_none
        push    si
        mov     si, cs:[qhead+O]
        add     si, si
        mov     ax, cs:[queue+O+si]
        pop     si
        sti
        or      ax, ax                  # pairs are never 0000 -> ZF=0
        jnz     1f
        inc     ax
1:      retf    2
peek_none:
        xor     ax, ax
        sti
        cmp     ax, ax                  # ZF=1
        retf    2

h_read:
        sti
        call    service
        cmp     word ptr cs:[qlen+O], 0
        jne     2f
        hlt
        jmp     h_read
2:      push    si
        mov     si, cs:[qhead+O]
        add     si, si
        mov     ax, cs:[queue+O+si]
        pop     si
        inc     word ptr cs:[qhead+O]
        dec     word ptr cs:[qlen+O]
        iret

service:
        cmp     byte ptr cs:[busy+O], 0
        je      3f
        ret
3:      inc     byte ptr cs:[busy+O]
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        push    ds
        push    es
        push    cs
        pop     ds
        mov     ax, 0x40
        mov     es, ax
        mov     ax, es:[0x6c]
        cmp     ax, [lasttick+O]
        je      s_done
        mov     [lasttick+O], ax
        cmp     byte ptr [ackpend+O], 0
        je      s_cmd
        cmp     word ptr [qlen+O], 0
        jne     s_done
        call    write_ack
s_cmd:
        mov     ax, 0x3d00
        mov     dx, offset cmdname+O
        int     0x21
        jc      s_done
        mov     bx, ax
        mov     ah, 0x3f
        mov     cx, 1024
        mov     dx, offset buf+O
        int     0x21
        mov     si, ax
        jnc     4f
        xor     si, si
4:      mov     ah, 0x3e
        int     0x21
        cmp     si, 5
        jb      s_done
        mov     ax, word ptr [buf+O]
        cmp     ax, word ptr [lastseq+O]
        jne     5f
        mov     ax, word ptr [buf+O+2]
        cmp     ax, word ptr [lastseq+O+2]
        je      s_done
5:      mov     ax, word ptr [buf+O]
        mov     word ptr [lastseq+O], ax
        mov     ax, word ptr [buf+O+2]
        mov     word ptr [lastseq+O+2], ax
        mov     byte ptr [ackpend+O], 1
        mov     al, [buf+O+4]
        cmp     al, 'K'
        je      s_keys
        cmp     al, 'D'
        jne     s_done
        call    dump
        call    write_ack
        jmp     s_done
s_keys:
        push    cs
        pop     es
        mov     cx, si
        sub     cx, 5
        shr     cx, 1
        mov     [qlen+O], cx
        mov     word ptr [qhead+O], 0
        mov     si, offset buf+O+5
        mov     di, offset queue+O
        cld
        rep     movsw
s_done:
        pop     es
        pop     ds
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        dec     byte ptr cs:[busy+O]
        ret

write_ack:
        mov     byte ptr [ackpend+O], 0
        mov     ah, 0x3c
        xor     cx, cx
        mov     dx, offset ackname+O
        int     0x21
        jc      6f
        mov     bx, ax
        mov     ah, 0x40
        mov     cx, 4
        mov     dx, offset lastseq+O
        int     0x21
        mov     ah, 0x3e
        int     0x21
6:      ret

dump:
        mov     dx, 0x3c7
        xor     al, al
        out     dx, al
        mov     dx, 0x3c9
        mov     di, offset pal+O
        mov     cx, 768
7:      in      al, dx
        mov     [di], al
        inc     di
        loop    7b
        mov     ah, 0x3c
        xor     cx, cx
        mov     dx, offset scrname+O
        int     0x21
        jc      8f
        mov     bx, ax
        push    ds
        mov     ax, 0xa000
        mov     ds, ax
        xor     dx, dx
        mov     cx, 64000
        mov     ah, 0x40
        int     0x21
        pop     ds
        mov     ah, 0x40
        mov     cx, 768
        mov     dx, offset pal+O
        int     0x21
        mov     ah, 0x3e
        int     0x21
8:      ret

buf:    .space  1032
queue:  .space  1032
pal:    .space  768
resend:

install:
        mov     ax, 0x3516
        int     0x21
        mov     word ptr [old16+O], bx
        mov     word ptr [old16+O+2], es
        mov     ax, 0x2516
        mov     dx, offset int16+O
        int     0x21
        mov     ah, 0x09
        mov     dx, offset msg+O
        int     0x21
        mov     ax, 0x3100
        mov     dx, (resend - base + 0x100 + 15) / 16
        int     0x21
msg:    .ascii  "KBTSR installed\r\n$"
