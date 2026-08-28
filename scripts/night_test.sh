#!/bin/bash
# Consolidated overnight test: relaunch Gunbird, catch the Psikyo-logo bug
# scene by polling screenshots for its red+green signature, then immediately
# read both the display-correlated L1 VRAM probe (at word 0x080, the
# confirmed-bad cell) and the sound-chain probe, in one pass.
set -a && . ./mister.env && set +a
Q=/c/intelFPGA_lite/17.0/quartus/bin64/quartus_stp.exe

MSYS_NO_PATHCONV=1 python scripts/mister_hw_test.py launch --mra "/media/fat/menu.rbf" >/dev/null 2>&1
sleep 8
MSYS_NO_PATHCONV=1 python scripts/mister_hw_test.py launch --mra "/media/fat/_Arcade/_Psikyo/Gunbird (World).mra" >/dev/null 2>&1

"$Q" -t scripts/read_l1_probe.tcl arm 080 2>&1 | grep -vE "^Info|^\s*Info" | tail -1

found=0
for i in $(seq 1 12); do
  MSYS_NO_PATHCONV=1 python scripts/mister_hw_test.py screenshot --core gunbird --out debug/night_$i.png --settle-seconds 0 >/dev/null 2>&1
  read_result=$(python3 -c "
import sys
sys.path.insert(0,'scripts')
from decode_vram import load_png
W,H,rows = load_png('debug/night_$i.png')
red=green=0
for y in range(0,H,3):
    row=rows[y]
    for x in range(0,W,3):
        r,g,b=row[x*3],row[x*3+1],row[x*3+2]
        if r>150 and g<100 and b<100: red+=1
        if g>150 and r<100 and b<100: green+=1
print(red, green)
")
  echo "night_$i: red,green=$read_result"
  set -- $read_result
  if [ "$1" -gt 5 ] && [ "$2" -gt 0 ]; then
    found=1
    echo ">>> logo scene at night_$i"
    break
  fi
done

echo "=== L1 DISPLAY-CORRELATION PROBE (word 0x080) ==="
"$Q" -t scripts/read_l1_probe.tcl read 2>&1 | grep -vE "^Info|^\s*Info"

echo "=== SOUND CHAIN PROBE ==="
"$Q" -t scripts/read_issp.tcl 2>&1 | grep -vE "^Info|^\s*Info"
