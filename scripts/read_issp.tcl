# Read the SDRAM debug probes over JTAG (In-System Sources and Probes).
#
#   quartus_stp -t scripts/read_issp.tcl [clear]
#
# SignalTap acquisition is GUI-only in Quartus Prime Lite 17.0 -- there are no
# *signaltap* Tcl commands -- so ISSP is what a headless workflow can drive.
# See rtl/debug/issp_probe.sv for why counters answer this failure better than
# a waveform would.
#
# probe_bus layout (LSB first), from issp_probe.sv:
#   [15:0]  writes issued      [31:16] writes acked
#   [47:32] CPU reads acked    [48] sdram_ready
#   [49] dl_req seen           [50] ioctl_download seen
#   [51] a CPU read returned non-zero
#   [54:52] boot_n            [73:55] first post-reset read address
#   [89:74] [105:90] [121:106] [137:122] first four post-reset data words

proc bits_to_int {s lo hi} {
    # read_probe_data returns MSB-first; index from the right.
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
puts "hardware: $hw"

set dev ""
foreach d [get_device_names -hardware_name $hw] {
    if {[string match "*5CSEBA6*" $d] || [string match "*5CSE*" $d] || $dev eq ""} { set dev $d }
}
puts "device:   $dev"

# Query instance info BEFORE opening a session: with a session already active
# this errors with "There is already an active In-System Sources and Probes
# session started."
set insts [get_insystem_source_probe_instance_info -hardware_name $hw -device_name $dev]
puts "instances: $insts"

set idx 0
foreach inst $insts { set idx [lindex $inst 0]; break }

# End any session left behind by an earlier failed run.
catch {end_insystem_source_probe}
if {[catch {start_insystem_source_probe -hardware_name $hw -device_name $dev} e]} {
    puts "start failed: $e"; exit 1
}

if {[lindex $argv 0] eq "clear"} {
    # Clear EVERY instance present, not just $idx (which was picked
    # arbitrarily -- the first entry in an unordered list, not necessarily
    # the one intended). Clearing an instance's counters that aren't
    # currently being read is harmless, and this removes the ambiguity
    # entirely rather than requiring the caller to know instance ordering.
    foreach inst $insts {
        set ii [lindex $inst 0]
        write_source_data -instance_index $ii -value 1 -value_in_hex
        after 20
        write_source_data -instance_index $ii -value 0 -value_in_hex
    }
    puts "counters cleared on all instances: $insts"
}

# Two instances share issp_probe, with the generic counters repurposed. The
# instance_id distinguishes them: "S" is the SDRAM path, "A" the sound chain.
foreach inst $insts {
    set ii [lindex $inst 0]
    set p [read_probe_data -instance_index $ii]
    puts ""
    puts "---- instance $ii ----"
    puts "raw: $p"
    # instance info is {index ? width id}; the id distinguishes them, which
    # matters because only one probe may be built in a given revision.
    set iid [lindex $inst 3]
    if {$iid eq "S"} {
        puts [format "writes issued        : %d" [bits_to_int $p 0 15]]
        puts [format "writes acked         : %d" [bits_to_int $p 16 31]]
        puts [format "CPU reads acked      : %d" [bits_to_int $p 32 47]]
        puts [format "sdram_ready          : %d" [bits_to_int $p 48 48]]
        puts [format "dl_req seen          : %d" [bits_to_int $p 49 49]]
        puts [format "ioctl_download seen  : %d" [bits_to_int $p 50 50]]
        puts [format "a read returned != 0 : %d" [bits_to_int $p 51 51]]
        puts [format "boot reads captured  : %d" [bits_to_int $p 52 54]]
        puts [format "first read address   : %05X (word)" [bits_to_int $p 55 73]]
        puts [format "boot data words      : %04X %04X %04X %04X"                 [bits_to_int $p 74 89] [bits_to_int $p 90 105]                 [bits_to_int $p 106 121] [bits_to_int $p 122 137]]
    } elseif {$iid eq "J"} {
        puts "JOYSTICK sticky (bits set since last clear):"
        set bits {}
        for {set b 0} {$b < 32} {incr b} {
            if {[bits_to_int $p $b $b]} { lappend bits $b }
        }
        if {[llength $bits] == 0} {
            puts "  (none - press the button, then read again)"
        } else {
            puts "  bits set: $bits"
        }
    } elseif {$iid eq "V"} {
        puts "L1 VRAM fetch-pipeline probe -- use scripts/read_l1_probe.tcl to decode this one"
    } elseif {$iid eq "A"} {
        puts "SOUND CHAIN (issp_probe ports repurposed, see psikyo_top.sv):"
        puts [format "  Z80 ROM fetches    : %d" [bits_to_int $p 0 15]]
        puts [format "  YM register writes : %d" [bits_to_int $p 16 31]]
        puts [format "  sound latch writes : %d" [bits_to_int $p 32 47]]
        puts [format "  snd_left non-zero  : %d" [bits_to_int $p 48 48]]
        puts [format "  Z80 ISR completed (latch ack seen) : %d" [bits_to_int $p 49 49]]
        puts [format "  adpcma valid seen  : %d" [bits_to_int $p 50 50]]
        puts [format "  adpcma bytes read  : %d" [bits_to_int $p 52 54]]
        puts [format "  last adpcma byte   : %02X" [expr {[bits_to_int $p 74 89] & 0xFF}]]
    } else {
        puts "unknown instance id '$iid' -- no decoder for this probe"
    }
}

end_insystem_source_probe
