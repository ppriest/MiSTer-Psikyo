#!/usr/bin/env python3
# Converts test_maincpu.bin (vasm -Fbin output, byte-ordered/big-endian per
# 68000 convention) into a $readmemh-compatible hex file, one 16-bit word
# per line -- for tb_maincpu.sv to load directly into its word-addressed
# rom[] array, avoiding hand-transcribing 129 individual assignment lines.
import sys

with open("sim/maincpu_tb/test_maincpu.bin", "rb") as f:
    data = f.read()

if len(data) % 2:
    data += b"\x00"

with open("sim/maincpu_tb/test_maincpu.hex", "w") as f:
    for i in range(0, len(data), 2):
        word = (data[i] << 8) | data[i + 1]
        f.write(f"{word:04x}\n")

print(f"wrote {len(data)//2} words to sim/maincpu_tb/test_maincpu.hex")
