; Phase 0 spike: exercise actual 68020-only additions over base 68000.
; Assembled with vasm (vasmm68k_mot -m68020 -Fbin), not hand-encoded --
; see PROVENANCE.md for why hand-encoding opcodes was abandoned after two
; near-misses in the v1 testbench.
;
; Each result is written to a distinct, easy-to-recognize memory address so
; the ModelSim bus trace can confirm it directly, the same technique used
; in tb_tg68k_boot.vhd's CLR.L test.

        org     $8

start:
        ; Test 1: MULU.L (32x32->32, single-register long multiply -- not
        ; available at all on plain 68000/68010, and easy to silently get
        ; truncated to 16x16->32 if a core's "68020 mode" is incomplete).
        move.l  #70000,d0              ; D0 = 70000 = 0x00011170
        move.l  #2,d1
        mulu.l  d1,d0                   ; D0 = 140000 = 0x000222E0
        move.l  d0,$3000.l

        ; Test 2: DIVU.L (32/32->32 quotient, single-register long divide).
        move.l  #100000,d2              ; D2 = 100000 = 0x000186A0
        move.l  #7,d3
        divu.l  d3,d2                    ; D2 = 14285 = 0x000037CD
        move.l  d2,$3004.l

        ; Test 3: scaled-index addressing mode (d8,An,Xn.L*SCALE) -- a
        ; genuine 68020-only extended addressing mode (68000/68010 only
        ; support unscaled (d8,An,Xn)).
        lea     table,a0
        move.l  #2,d1
        move.l  (0,a0,d1.l*4),d4        ; D4 = table[2] = 0xCCCCCCCC
        move.l  d4,$3008.l

        ; Test 4: BFEXTU bitfield extract -- another 68020-only instruction
        ; class, absent on 68000/68010.
        move.l  #$12345678,d0
        bfextu  d0{8:8},d5               ; D5 = byte at bit offset 8..15 = 0x34
        move.l  d5,$300C.l

        bra.s   *

table:
        dc.l    $AAAAAAAA
        dc.l    $BBBBBBBB
        dc.l    $CCCCCCCC
        dc.l    $DDDDDDDD
