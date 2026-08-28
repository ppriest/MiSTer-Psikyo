# Read a word from spriteram over JTAG (instance "S" in psikyo_core.sv), for
# spot-checking a specific sprite's live attribute word (e.g. its priority
# field, bits 7:6 of word offset +0x4) without needing a full debug-overlay
# dump -- the overlay's 224-line row budget has no room left for a spriteram
# band (see decode_vram.py). Reads the CPU-VISIBLE buffer, the SAME one
# MAME's own debugger/memory viewer shows, so a value read here is directly
# comparable to a MAME-side dump at the same word address -- no
# double-buffering translation needed.
#
# SAFETY: the read only reflects the requested address while the core's
# CPU-pause input is asserted -- otherwise cpu_addr is left driven by the
# live game, and you'll read whatever address the CPU/render pipeline
# happens to be touching that cycle, not the one you asked for. The probe
# echoes back whether pause was seen, so this is visible rather than
# silently wrong. Pause the game (the Pause button, joystick bit 12) BEFORE
# reading.
#
# Spriteram word map (docs/phase1_memory_map.md):
#   0x000-0xBFF  attribute table, 768 entries x 4 words (Y, X, flags/color/
#                priority/code-hi, code-lo) -- entry N starts at word N*4
#   0xC00-0xFFE  display list (1023 max, sprite-table indices, 0xFFFF-terminated)
#   0xFFF        control word (bit0 sprites-disable, bits 2-3 transpen select)
#
# Usage:
#   quartus_stp -t scripts/read_spriteram.tcl <addr_hex>
#       e.g. read_spriteram.tcl 344   -- word 0x344 = entry (0x344/4)=0xD1,
#       word offset 0 (Y position) of sprite attribute entry 0xD1.
#   quartus_stp -t scripts/read_spriteram.tcl entry <index_hex>
#       Convenience: reads all 4 words of attribute entry <index_hex> in one
#       go (word*4 .. word*4+3) and decodes them (Y/X/flags/color/priority/code).
#   quartus_stp -t scripts/read_spriteram.tcl dump <outfile.bin>
#       Reads ALL 4096 words in one JTAG session (the session setup dominates
#       cost; per-word reads inside it are ~20ms) and writes them as 8KB of
#       little-endian 16-bit words -- the same shape as a MAME
#       save-binary dump of the CPU-visible spriteram, so the two are
#       byte-comparable. Aborts if pause is not asserted.

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
    if {[lindex $inst 3] eq "S"} { set idx [lindex $inst 0] }
}
if {$idx < 0} { puts "instance S not found -- is this the spriteram-read-probe build? instances: $insts"; exit 1 }

catch {end_insystem_source_probe}
if {[catch {start_insystem_source_probe -hardware_name $hw -device_name $dev} e]} {
    puts "start failed: $e"; exit 1
}

proc read_word {idx addr} {
    write_source_data -instance_index $idx -value [format %X $addr] -value_in_hex
    after 20
    set p [read_probe_data -instance_index $idx]
    set data  [bits_to_int $p 0 15]
    set pause [bits_to_int $p 16 16]
    return [list $data $pause]
}

set cmd [lindex $argv 0]

if {$cmd eq "dump"} {
    set out [lindex $argv 1]
    if {$out eq ""} { puts "usage: read_spriteram.tcl dump <outfile.bin>"; exit 1 }
    # Pause gate first: one probe read, abort before wasting 80s on garbage.
    lassign [read_word $idx 0] d0 p0
    if {!$p0} {
        puts "ABORT: pause not asserted -- every word would be garbage. Pause first."
        end_insystem_source_probe
        exit 1
    }
    set f [open $out wb]
    fconfigure $f -translation binary
    set pause_lost 0
    for {set a 0} {$a < 4096} {incr a} {
        lassign [read_word $idx $a] d p
        if {!$p} { set pause_lost 1 }
        puts -nonewline $f [binary format s $d]
        if {$a % 512 == 0} { puts "  word 0x[format %03X $a]..." }
    }
    close $f
    if {$pause_lost} {
        puts "WARNING: pause dropped mid-dump -- rerun, the file is suspect."
    } else {
        puts "dumped 4096 words (8KB) -> $out   (pause held throughout)"
    }
} elseif {$cmd eq "entry"} {
    set entry_hex [lindex $argv 1]
    if {$entry_hex eq ""} { puts "usage: read_spriteram.tcl entry <index_hex>"; exit 1 }
    set entry [expr {"0x$entry_hex"}]
    set base [expr {$entry * 4}]
    set words {}
    set pause_seen 1
    for {set i 0} {$i < 4} {incr i} {
        lassign [read_word $idx [expr {$base + $i}]] d p
        lappend words $d
        if {!$p} { set pause_seen 0 }
    }
    lassign $words w0 w1 w2 w3
    if {!$pause_seen} {
        puts "WARNING: pause was not asserted for at least one word -- data below may be garbage. Pause first."
    }
    puts [format "sprite entry 0x%03X (words 0x%03X-0x%03X):" $entry $base [expr {$base+3}]]
    puts [format "  w0 (Y+ysize)     = 0x%04X" $w0]
    puts [format "  w1 (X+xsize)     = 0x%04X" $w1]
    puts [format "  w2 (flags/etc)   = 0x%04X" $w2]
    puts [format "  w3 (code lo)     = 0x%04X" $w3]
    set flip_y   [expr {($w2 >> 15) & 1}]
    set flip_x   [expr {($w2 >> 14) & 1}]
    set color    [expr {($w2 >> 8) & 0xF}]
    set priority [expr {($w2 >> 6) & 0x3}]
    set code     [expr {(($w2 & 1) << 16) | $w3}]
    puts [format "  flip_y=%d flip_x=%d color=%d priority=%d code=0x%05X" \
            $flip_y $flip_x $color $priority $code]
} else {
    set addr_hex $cmd
    if {$addr_hex eq ""} {
        puts "usage: read_spriteram.tcl <addr_hex>  |  read_spriteram.tcl entry <index_hex>"
        exit 1
    }
    set addr [expr {"0x$addr_hex"}]
    lassign [read_word $idx $addr] data pause
    puts [format "word 0x%03X = 0x%04X   (pause asserted: %d%s)" $addr $data $pause \
            [expr {$pause ? "" : "  <-- pause first, this is NOT the requested word"}]]
}

end_insystem_source_probe
