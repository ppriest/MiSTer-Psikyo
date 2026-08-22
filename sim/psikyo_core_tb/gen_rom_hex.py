#!/usr/bin/env python3
# Converts test_video.bin (vasm -Fbin output) into a $readmemh-compatible
# hex file, one 16-bit word per line -- same conversion
# sim/maincpu_tb/gen_rom_hex.py already does for that testbench.
with open("sim/psikyo_core_tb/test_video.bin", "rb") as f:
    data = f.read()

if len(data) % 2:
    data += b"\x00"

with open("sim/psikyo_core_tb/test_video.hex", "w") as f:
    for i in range(0, len(data), 2):
        word = (data[i] << 8) | data[i + 1]
        f.write(f"{word:04x}\n")

print(f"wrote {len(data)//2} words to sim/psikyo_core_tb/test_video.hex")
