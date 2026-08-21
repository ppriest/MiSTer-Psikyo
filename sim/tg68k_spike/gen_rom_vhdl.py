#!/usr/bin/env python3
"""Convert an assembled m68k binary (vasm -Fbin output) into VHDL mem_v
initialization lines for tb_tg68k_boot.vhd, prefixed with a reset vector
(SSP/PC). Avoids hand-transcribing opcodes into VHDL -- the whole point of
using vasm in the first place.

Usage: gen_rom_vhdl.py <code.bin> <load_addr_hex> <ssp_hex> <pc_hex>
"""
import sys

def main():
    binpath, load_addr_s, ssp_s, pc_s = sys.argv[1:5]
    load_addr = int(load_addr_s, 16)
    ssp = int(ssp_s, 16)
    pc = int(pc_s, 16)

    with open(binpath, "rb") as f:
        code = f.read()

    if load_addr % 2 != 0:
        raise SystemExit("load address must be word-aligned")
    if len(code) % 2 != 0:
        code += b"\x00"  # pad to a whole word

    mem = {}
    mem[0] = (ssp >> 16) & 0xFFFF
    mem[1] = ssp & 0xFFFF
    mem[2] = (pc >> 16) & 0xFFFF
    mem[3] = pc & 0xFFFF

    for i in range(0, len(code), 2):
        word = (code[i] << 8) | code[i + 1]
        addr = load_addr + i
        mem[addr // 2] = word

    max_idx = max(mem.keys())
    lines = []
    for idx in range(max_idx + 1):
        val = mem.get(idx, 0)
        addr = idx * 2
        lines.append(f'         mem_v({idx:<4d}) := x"{val:04X}";  -- byte addr 0x{addr:04X}')

    print("\n".join(lines))

if __name__ == "__main__":
    main()
