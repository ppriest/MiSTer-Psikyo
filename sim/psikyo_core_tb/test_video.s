; psikyo_core end-to-end video-path exercise: assembled with vasm
; (vasmm68k_mot -m68020 -Fbin), same convention as
; sim/maincpu_tb/test_maincpu.s (see that file's header for why hand-encoded
; opcodes are avoided in this project).
;
; org $8 -- reset vectors (initial SP/PC) are supplied directly by the
; testbench's ROM preload, not by this file, same convention as
; test_maincpu.s.
;
; Writes just enough to put ONE known, non-transparent pixel on screen at
; tilemap layer 0's origin tile (VRAM cell 0, screen grid col=0/row=0 --
; every one of the 4 tilemap size modes maps col=0,row=0 to VRAM index 0,
; see docs/phase1_video_engine.md's "Tilemap addressing" table, so the mode
; bits don't matter for this): tile code 0 / color 0 in VRAM cell 0, a
; distinctive palette entry at the resulting pal_addr (0x800 -- see
; rtl/video/compositor.sv's palette address mux: 0x800 + color*16 + pixel,
; both 0 here), and layer 0's control word (enable=1, transpen_sel=0 so pen
; 15 -- not pen 0 -- is the transparent one, since the gfx ROM stub this
; testbench uses returns an all-zero row, i.e. every pixel decodes as pen
; 0). Scroll registers are left at their post-reset zero default.

        org     $8

start:
        ; layer 0 VRAM cell 0: tile code 0, color 0.
        move.w  #$0000,d0
        move.w  d0,$800000.l

        ; palette word 0x800 (byte 0x601000) -- distinctive test value.
        move.w  #$1234,d1
        move.w  d1,$601000.l

        ; layer 0 control word (byte 0x804412): bit0=enable, bit3=0 (pen 15
        ; transparent), mode bits 7:6=00 (mode doesn't matter here).
        move.w  #$0001,d2
        move.w  d2,$804412.l

done:
        bra.s   done
