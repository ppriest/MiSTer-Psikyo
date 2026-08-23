#!/usr/bin/env python3
"""Reconstructs the REAL samuraia maincpu+audiocpu ROM content from
roms/samuraia.zip, using the exact same byte-level rules as MiSTer's own
MRA loader (confirmed against
github.com/MiSTer-devel/Main_MiSTer/wiki/Arcade-Roms-and-MRA-files during
real-hardware bring-up: a part's own `map` attribute reorders bytes WITHIN
that part's own stream -- e.g. map="10" swaps each 2-byte pair -- files are
then interleaved in <interleave> listing order), matching
releases/Samurai Aces (World).mra's maincpu <interleave> block exactly.

Outputs two flat binary files with ONLY real content (no 0xFF padding --
unlike the .mra's full download blob, this doesn't need to reach the next
region's base address, since sim/psikyo_top_tb/tb_psikyo_top.sv's
dl_write_byte() task takes an explicit address per byte and can jump freely):
  maincpu_real.bin  -- 0x80000 bytes, load at absolute address 0x000000
  audiocpu_real.bin -- 0x20000 bytes, load at absolute address 0x200000

Then converts both to $readmemh-compatible one-byte-per-line hex (matching
gen_rom_bytes_hex.py's own convention) so a testbench can $readmemh them
directly, since tb_psikyo_top.sv's dl_write_byte() feeds one byte at a time
through the real ioctl_wr/ioctl_addr path, same as real HPS hardware.
"""
import zipfile

ZIP_PATH = "roms/samuraia.zip"


def swap_pairs(data: bytes) -> bytes:
    out = bytearray(len(data))
    for i in range(0, len(data), 2):
        out[i] = data[i + 1]
        out[i + 1] = data[i]
    return bytes(out)


def interleave_words(a: bytes, b: bytes) -> bytes:
    """Round-robin a's 2-byte words then b's 2-byte words, matching
    <interleave output="16"> with 2 parts listed in order a, b."""
    assert len(a) == len(b)
    out = bytearray(len(a) + len(b))
    for i in range(0, len(a), 2):
        out[2 * i:2 * i + 2] = a[i:i + 2]
        out[2 * i + 2:2 * i + 4] = b[i:i + 2]
    return bytes(out)


def write_hex(path, data: bytes):
    with open(path, "w") as f:
        for byte in data:
            f.write(f"{byte:02x}\n")


def main():
    with zipfile.ZipFile(ZIP_PATH) as z:
        u127 = z.read("4-u127.bin")  # map="01" -- no internal swap
        u126 = z.read("5-u126.bin")  # map="10" -- swap each byte pair
        audiocpu = z.read("3-u58.bin")

    u126_swapped = swap_pairs(u126)
    maincpu = interleave_words(u127, u126_swapped)

    assert len(maincpu) == 0x80000, hex(len(maincpu))
    assert len(audiocpu) == 0x20000, hex(len(audiocpu))

    with open("sim/psikyo_top_tb/maincpu_real.bin", "wb") as f:
        f.write(maincpu)
    with open("sim/psikyo_top_tb/audiocpu_real.bin", "wb") as f:
        f.write(audiocpu)

    write_hex("sim/psikyo_top_tb/maincpu_real_bytes.hex", maincpu)
    write_hex("sim/psikyo_top_tb/audiocpu_real_bytes.hex", audiocpu)

    # Print the reconstructed reset vector for a quick sanity cross-check
    # against the hardware-bring-up analysis (SP=0xffff8000, PC=0x00000400).
    sp = int.from_bytes(maincpu[0:4], "big")
    pc = int.from_bytes(maincpu[4:8], "big")
    print(f"Reset vector: SP=0x{sp:08x} PC=0x{pc:08x}")
    print(f"maincpu: {len(maincpu)} bytes, audiocpu: {len(audiocpu)} bytes")


if __name__ == "__main__":
    main()
