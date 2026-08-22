; maincpu bus/memory-map exercise: assembled with vasm
; (vasmm68k_mot -m68020 -Fbin), matching sim/tg68k_spike/test020.s's own
; "don't hand-encode opcodes" practice (see that file's header for why).
;
; org $8 -- the reset vectors (initial SP/PC, bytes 0-7) are supplied
; directly by the testbench's ROM preload, not by this file, same
; convention as test020.s.
;
; Exercises every region in docs/phase1_memory_map.md's 68EC020 program
; address map in turn (ROM fetch is implicit throughout -- every
; instruction/immediate here comes from ROM), plus the sngkace board's
; sound-latch and input-port addresses. Each write uses a distinct,
; recognizable value so the testbench can confirm the right byte/word
; landed in the right region, not just "some write happened".

        org     $8

start:
        move.w  #$2000,sr              ; unmask interrupts (drop I2-0 to 0) --
                                         ; reset starts at mask 7, blocking the
                                         ; level-4 vblank IRQ tested later

        ; ---- sprite RAM (0x400000-0x401FFF), word write + read back ----
        move.w  #$1234,d0
        move.w  d0,$400000.l
        move.w  $400000.l,d1

        ; ---- palette RAM (0x600000-0x601FFF), word write ----
        move.w  #$5678,d2
        move.w  d2,$600000.l

        ; ---- tilemap layer 0 VRAM (0x800000-0x801FFF), word write ----
        move.w  #$9abc,d3
        move.w  d3,$800000.l

        ; ---- tilemap layer 1 VRAM (0x802000-0x803FFF), word write ----
        move.w  #$dcba,d3
        move.w  d3,$802000.l

        ; ---- video regs (0x804000-0x807FFF), word write ----
        move.w  #$def0,d4
        move.w  d4,$804000.l

        ; ---- work RAM (0xfe0000-0xffffff), word write ----
        move.w  #$1111,d5
        move.w  d5,$fe0000.l

        ; ---- input port read (sngkace overlay, 0xC00000-0xC00003, P1/P2) --
        ; written back to work RAM so the testbench can confirm the read
        ; value externally (this module has no other observable output for
        ; a plain register load) ----
        move.l  $c00000.l,d6
        move.l  d6,$fe0004.l

        ; ---- sound latch write (sngkace overlay, 0xC00013, byte) ----
        move.b  #$77,d7
        move.b  d7,$c00013.l

        ; ---- final marker write: confirms every instruction above ran to
        ; completion without the bus wedging (mirrors test020.s's own
        ; "watch for the last expected write" pass condition) ----
        move.w  #$cafe,$fe0002.l

wait_irq:
        bra.s   wait_irq                ; parked here until the vblank IRQ
                                          ; (tested externally by the
                                          ; testbench) diverts to irq4_isr

        ; ---- level-4 autovector ISR body. The vector TABLE entry (address
        ; 0x60, must hold this address, not code) is supplied directly by
        ; the testbench's ROM preload -- same convention as the reset
        ; vectors at 0x0-0x7, which also aren't part of this file -- since
        ; this fixed org placement keeps the address known and stable
        ; without needing precise layout coordination against the
        ; straight-line code above. ----
        org     $100
irq4_isr:
        move.w  #$beef,$400100.l        ; distinctive write, sprite RAM
        rte
