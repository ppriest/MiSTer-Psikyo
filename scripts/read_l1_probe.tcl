# Layer-1 tilemap SELF-CONSISTENCY snapshot probe (instance "V" in
# psikyo_core.sv).
#
# Four trigger designs, in order -- the first three are dead ends, kept here
# so they don't get re-tried:
#   1. Scanline-triggered -- fired on the first h_active pixel of a raster
#      line. Given ~32 tiles of prefetch run-ahead, that captures whatever
#      the FETCH side happens to be doing, never the specific cell of
#      interest. Measured twice: never hit it.
#   2. Fetch-address-triggered -- reliably hit the target address, but
#      pixel_color/pal_addr were captured from the DISPLAY side at the same
#      instant, a DIFFERENT tile (same run-ahead reason). Measured 7 times,
#      including once during the visually-confirmed bug frame: fetch+decode
#      was correct every time. Real evidence the bug is not in fetch/decode,
#      but the comparison itself was invalid -- two unrelated tiles.
#   3. Display-address-triggered -- buf_src_addr[] tags each slot with its
#      fetch address, giving a true same-tile correlation. Correct design,
#      but still needs the RIGHT MOMENT: caught the Gunbird logo scene
#      precisely and measured pixel_color=70 -- neither the "correct" (65)
#      nor "bug" (64) value expected from the one paused-frame reproduction,
#      because the logo turned out to be animated and the target address's
#      content changes across the sequence. No way to pause the game
#      without a user present to press the button.
#   4. Self-consistency-triggered (this version) -- tilemap_line_engine.sv
#      ALSO tags each slot with the raw word it was fetched from
#      (buf_src_word[]), so the trigger fires automatically the instant
#      buf_color[slot] (what's actually displayed) disagrees with what
#      buf_src_word[slot]'s OWN color field predicts. Needs no external
#      reference, no address guess, no timing coordination with anything --
#      it catches a genuine buffer-level corruption on ITS OWN, on whatever
#      tile, whenever it happens. If this has fired, src_addr/src_word below
#      are exactly the tile it happened to, and it is definitive.
#
# fetch_vram_addr/vram_data/cell_tile_number/cell_color below remain the
# UNRELATED fetch-side activity at snapshot time (whatever the pipeline
# happens to be prefetching) -- context only, not comparable to anything else.
#
# Usage:
#   quartus_stp -t scripts/read_l1_probe.tcl arm [addr_hex]
#       Clears any previous snapshot and re-arms. The optional address is
#       purely informational now (shown in the readout as trig_addr) -- the
#       trigger condition no longer depends on it; pass anything, e.g. 000.
#   quartus_stp -t scripts/read_l1_probe.tcl read
#       Reads back the last snapshot.

proc bits_to_int {s lo hi} {
    set n [string length $s]
    set v 0
    for {set i $hi} {$i >= $lo} {incr i -1} {
        set c [string index $s [expr {$n - 1 - $i}]]
        set v [expr {$v * 2 + ($c eq "1" ? 1 : 0)}]
    }
    return $v
}

set hw ""
foreach h [get_hardware_names] { if {$hw eq ""} { set hw $h } }
if {$hw eq ""} { puts "NO JTAG HARDWARE FOUND"; exit 1 }
set dev ""
foreach d [get_device_names -hardware_name $hw] {
    if {[string match "*5CSE*" $d] || $dev eq ""} { set dev $d }
}

set insts [get_insystem_source_probe_instance_info -hardware_name $hw -device_name $dev]
set idx -1
foreach inst $insts {
    if {[lindex $inst 3] eq "V"} { set idx [lindex $inst 0] }
}
if {$idx < 0} { puts "instance V not found -- is this the l1-probe build? instances: $insts"; exit 1 }

catch {end_insystem_source_probe}
if {[catch {start_insystem_source_probe -hardware_name $hw -device_name $dev} e]} {
    puts "start failed: $e"; exit 1
}

set cmd [lindex $argv 0]

if {$cmd eq "arm"} {
    set addr_arg [lindex $argv 1]
    if {$addr_arg eq ""} { set addr_arg "000" }
    set trig_addr [expr {"0x$addr_arg"}]
    # source[12:1] = trig_addr, source[0] = clear.
    set armed_val [format %X [expr {($trig_addr << 1) | 0}]]
    set clear_val [format %X [expr {($trig_addr << 1) | 1}]]
    write_source_data -instance_index $idx -value $clear_val -value_in_hex
    after 20
    write_source_data -instance_index $idx -value $armed_val -value_in_hex
    puts "armed: trig_addr=0x[format %03X $trig_addr]"
} elseif {$cmd eq "read"} {
    set p [read_probe_data -instance_index $idx]
    puts "raw: $p"
    set taken [bits_to_int $p 117 117]
    puts [format "snapshot taken       : %d" $taken]
    if {!$taken} {
        puts "(not yet triggered -- no self-inconsistency has occurred since arming."
        puts " This is the expected/good outcome if left running a while: it means"
        puts " every displayed pixel has matched its own tagged source word.)"
    } else {
        set trigaddr [bits_to_int $p 105 116]
        set saddr [bits_to_int $p 93 104]
        set sword [bits_to_int $p 77 92]
        set vaddr [bits_to_int $p 65 76]
        set vdata [bits_to_int $p 49 64]
        set tnum  [bits_to_int $p 34 48]
        set color [bits_to_int $p 27 33]
        set mode  [bits_to_int $p 25 26]
        set bank  [bits_to_int $p 23 24]
        set pidx  [bits_to_int $p 19 22]
        set pcol  [bits_to_int $p 12 18]
        set paddr [bits_to_int $p 0 11]
        puts ""
        puts "*** SELF-INCONSISTENCY CAUGHT -- this is the bug, live ***"
        puts [format "trig_addr (informational, from arm) : 0x%03X" $trigaddr]
        puts [format "src_addr  (the tile it happened to)  : 0x%03X" $saddr]
        puts [format "src_word  (raw word tagged for it)   : 0x%04X" $sword]
        puts [format "  -> tile field  \[12:0\]              : 0x%04X" [expr {$sword & 0x1FFF}]]
        puts [format "  -> color field \[15:13\]             : %d"    [expr {$sword >> 13}]]
        puts [format "  -> predicted color (field+64)       : %d" [expr {($sword >> 13) + 64}]]
        puts [format "pixel_color actually displayed        : %d (0x%02X)  <-- disagrees with the above" $pcol $pcol]
        puts [format "pal_addr actually looked up           : 0x%03X" $paddr]
        puts ""
        puts "Context (fetch side, unrelated tile at the same instant -- ignore for"
        puts "interpreting the bug above, kept only in case it's separately useful):"
        puts [format "  fetch_vram_addr=0x%03X vram_word=0x%04X tile_number=0x%04X" $vaddr $vdata $tnum]
        puts [format "  cell_color=%d mode=%d bank=%d pixel_index=%d" $color $mode $bank $pidx]
    }
} else {
    puts "usage: read_l1_probe.tcl {arm \[addr_hex\] | read}"
}

end_insystem_source_probe
