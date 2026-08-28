# Arm the frame-count auto-pause (instance "F" in psikyo_core.sv): pauses the
# CPU automatically N frames after arming. Complements write_vram1.tcl's
# write-triggered pause -- use this when the target SCREEN's frame offset
# from boot is known (e.g. from screenshot polling) but no specific VRAM
# address/value is.
#
# Needs "Frame-count auto-pause" turned ON in the OSD (P1 Debug page,
# status bit 54) -- this script does not touch that switch, only the JTAG
# side, so it fires silently doing nothing if the OSD switch is off (the
# probe read below can be used to check whether pause was ever asserted, but
# the intended check is simpler: does the game actually pause on screen).
#
# Usage:
#   quartus_stp -t scripts/arm_frame_pause.tcl arm <n_frames_decimal>
#       Arms a fresh count: pauses after N frames from THIS moment (not from
#       boot -- so time this call relative to a known reference, e.g. right
#       after launching the .mra, the same way screenshot polling was timed
#       overnight).
#   quartus_stp -t scripts/arm_frame_pause.tcl read
#       Reads back the current frame count reached so far -- useful for
#       calibrating: if it stopped increasing, the target was reached
#       (check whether the game is now actually paused on the right scene).

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
    if {[lindex $inst 3] eq "F"} { set idx [lindex $inst 0] }
}
if {$idx < 0} { puts "instance F not found -- is this the auto-pause build? instances: $insts"; exit 1 }

catch {end_insystem_source_probe}
if {[catch {start_insystem_source_probe -hardware_name $hw -device_name $dev} e]} {
    puts "start failed: $e"; exit 1
}

set cmd [lindex $argv 0]

if {$cmd eq "arm"} {
    set n [lindex $argv 1]
    if {$n eq ""} { puts "usage: arm_frame_pause.tcl arm <n_frames_decimal>"; exit 1 }
    # source[16]=rearm pulse, [15:0]=target. Pulse the rearm bit with the
    # new target already in place, then drop it -- the rising edge is what
    # (re)starts the count in the RTL.
    set clear_val [format %X $n]
    set armed_val [format %X [expr {$n | (1 << 16)}]]
    write_source_data -instance_index $idx -value $clear_val -value_in_hex
    after 20
    write_source_data -instance_index $idx -value $armed_val -value_in_hex
    after 20
    write_source_data -instance_index $idx -value $clear_val -value_in_hex
    puts "armed: will pause $n frames from now (assuming the OSD switch is on)"
} elseif {$cmd eq "read"} {
    set p [read_probe_data -instance_index $idx]
    puts [format "frame count reached so far: %d" [bits_to_int $p 0 15]]
} else {
    puts "usage: arm_frame_pause.tcl {arm <n_frames_decimal> | read}"
}

end_insystem_source_probe
