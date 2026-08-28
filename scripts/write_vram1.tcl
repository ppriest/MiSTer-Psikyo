# Write a word into layer-1 VRAM over JTAG (instance "W" in psikyo_core.sv),
# to test whether the render engine reads a DIFFERENT word than the VRAM map
# says it should for a given screen position.
#
# SAFETY: the write only takes effect while the core's CPU-pause input is
# asserted -- it's muxed onto the same physical write port the CPU itself
# uses, so a debug write landing the same cycle as a real CPU write would be
# an undefined race. Pause the game (the Pause button, joystick bit 12)
# BEFORE running this. If you forget, the probe still reports the attempt
# (wr_attempted_unpaused) so it's visible rather than silently doing nothing.
#
# Usage:
#   quartus_stp -t scripts/write_vram1.tcl <addr_hex> <data_hex>
#       e.g. write_vram1.tcl 081 2010  -- writes 0x2010 to word index 0x081
#       (byte address 0x802102).
#   quartus_stp -t scripts/write_vram1.tcl read
#       Reads back confirmation: whether pause was seen, how many writes
#       have actually been applied, and the last address/data written.

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
    if {[lindex $inst 3] eq "W"} { set idx [lindex $inst 0] }
}
if {$idx < 0} { puts "instance W not found -- is this the vram-write-probe build? instances: $insts"; exit 1 }

catch {end_insystem_source_probe}
if {[catch {start_insystem_source_probe -hardware_name $hw -device_name $dev} e]} {
    puts "start failed: $e"; exit 1
}

set cmd [lindex $argv 0]

if {$cmd eq "read"} {
    set p [read_probe_data -instance_index $idx]
    puts "raw: $p"
    set last_data      [bits_to_int $p 0 15]
    set last_addr      [bits_to_int $p 16 27]
    set apply_count    [bits_to_int $p 28 43]
    set pause_now      [bits_to_int $p 44 44]
    set attempted_unpaused [bits_to_int $p 45 45]
    puts [format "pause currently asserted     : %d" $pause_now]
    puts [format "write attempted while UNPAUSED : %d  %s" $attempted_unpaused \
            [expr {$attempted_unpaused ? "<-- pause first, then retry" : ""}]]
    puts [format "writes actually applied       : %d" $apply_count]
    puts [format "last address written (word)   : 0x%03X" $last_addr]
    puts [format "last data written              : 0x%04X" $last_data]
} else {
    set addr_hex $cmd
    set data_hex [lindex $argv 1]
    if {$addr_hex eq "" || $data_hex eq ""} {
        puts "usage: write_vram1.tcl <addr_hex> <data_hex>  |  write_vram1.tcl read"
        exit 1
    }
    set addr [expr {"0x$addr_hex"}]
    set data [expr {"0x$data_hex"}]
    # source[28]=trigger, [27:12]=data, [11:0]=addr
    set clear_val [format %X [expr {($addr) | ($data << 12) | (0 << 28)}]]
    set armed_val [format %X [expr {($addr) | ($data << 12) | (1 << 28)}]]
    write_source_data -instance_index $idx -value $clear_val -value_in_hex
    after 20
    write_source_data -instance_index $idx -value $armed_val -value_in_hex
    after 20
    write_source_data -instance_index $idx -value $clear_val -value_in_hex
    puts "wrote 0x$data_hex to word 0x[format %03X $addr] (byte 0x[format %06X [expr {0x802000 + $addr*2}]])"
    puts "-- if the CPU wasn't paused, this had no effect. Run 'read' to confirm."
}

end_insystem_source_probe
