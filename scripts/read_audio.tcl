# Dump the core's internal audio capture buffer over JTAG (instance "A",
# rtl/psikyo_core.sv, DEBUG_ISSP builds only).
#
# WHY: the crackle in the YM2610 games had resisted three rounds of reasoning
# (SDRAM starvation -- measured and ruled out; an upstream ADPCM-B nibble
# gating fix -- real but inapplicable, Samurai Aces has no ADPCM-B; an ADPCM-A
# accumulator overflow -- real and fixed, but not the audible fault). Every one
# of those was a hypothesis about a signal nobody had looked at. This dumps the
# actual digital samples the core generates, which separates the two cases a
# recording off the analogue or HDMI output cannot:
#
#   * the samples themselves are wrong  -> the fault is in the sound chip or
#     its ROM feed, inside the core
#   * the samples are clean             -> the core is fine and the fault is
#     downstream (framework resampler, HDMI/analogue path, MiSTer.ini)
#
# The buffer free-runs as a ring at one entry per generated sample (jt10's
# snd_sample), so freezing it captures the ~295 ms LEADING UP TO the freeze.
#
# TRIGGER (changed 2026-09-02): the ring now freezes itself on a BURST OF LATE
# ADPCM-A FETCHES, not on a large sample-to-sample delta. jt10's sample bus is
# fixed-latency -- it reloads `data` every cen and decodes it one cen6 later,
# with no handshake -- so a fetch still outstanding 1.375 us after roe_n falls
# is not waited for, it is silently replaced by the previous byte. psikyo_top's
# deadline monitor counts those; the ring arms on them. The delta trigger only
# ever caught the SYMPTOM; this catches the suspected CAUSE, so a dump that
# contains the artefact proves the mechanism end to end.
#
# Usage:
#   quartus_stp -t scripts/read_audio.tcl dump <outfile.bin>
#       Freezes the buffer, reads all 16384 entries in one JTAG session, and
#       writes them as little-endian pairs of signed 16-bit samples (left,
#       right) starting at the OLDEST entry, so the file is already in
#       chronological order. Feed it to scripts/decode_audio.py.
#   quartus_stp -t scripts/read_audio.tcl peek
#       One read: reports the write pointer, frozen state and the running
#       count of LATE ADPCM-A fetches. That count is the whole experiment --
#       if it stays 0 while the noise is audible, the deadline hypothesis is
#       dead and no dump is needed. Use it also to confirm the probe is alive
#       before spending ~6 minutes on a dump (16384 reads at 20 ms each).
#   quartus_stp -t scripts/read_audio.tcl arm [n]
#       Arm, freezing on a burst of n late fetches (default 1). n is latched
#       at arm time, so the threshold retunes over JTAG without a rebuild.
#       The burst estimator decays one per audio sample (55.5 kHz), so
#       isolated late bytes drain away and only a real cluster trips it.
#
# The buffer keeps filling until frozen, so there is no need to pause the core
# (unlike read_spriteram.tcl, which borrows the CPU's address bus).

proc bits_to_int {s lo hi} {
    set n [string length $s]
    set v 0
    for {set i $hi} {$i >= $lo} {incr i -1} {
        set c [string index $s [expr {$n - 1 - $i}]]
        set v [expr {$v * 2 + ($c eq "1" ? 1 : 0)}]
    }
    return $v
}

# 16-bit two's complement -> signed
proc s16 {v} {
    if {$v >= 32768} { return [expr {$v - 65536}] }
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
# Match on id AND widths. The instance id alone is NOT unique: this design
# reports two instances labelled "A" (ours at source 15 / probe 47, and an
# unrelated one at 1 / 138), and picking the wrong one fails silently and
# confusingly -- reads return another probe's bits, so the write pointer looks
# stuck, the freeze never appears to take, and the data looks almost plausible.
set idx -1
foreach inst $insts {
    if {[lindex $inst 3] eq "A" && [lindex $inst 1] == 16 && [lindex $inst 2] == 64} {
        set idx [lindex $inst 0]
    }
}
if {$idx < 0} {
    puts "audio probe (id A, source 16, probe 64) not found -- is this a DEBUG_ISSP"
    puts "(Psikyo_stp) build with the capture buffer? instances: $insts"
    exit 1
}
puts "audio probe at instance index $idx"

catch {end_insystem_source_probe}
if {[catch {start_insystem_source_probe -hardware_name $hw -device_name $dev} e]} {
    puts "start failed: $e"; exit 1
}

# source = {arm, freeze, addr[13:0]} -- addr doubles as the burst threshold on
# the arm edge (see psikyo_core.sv's aud_trig_n).
# probe  = {late_cnt[15:0], triggered, frozen, wr_ptr[13:0], sample[31:0]}
proc read_entry {idx addr freeze {arm 1}} {
    set src [expr {($arm << 15) | ($freeze << 14) | ($addr & 0x3FFF)}]
    write_source_data -instance_index $idx -value [format %X $src] -value_in_hex
    after 20
    set p [read_probe_data -instance_index $idx]
    set right  [bits_to_int $p 0 15]
    set left   [bits_to_int $p 16 31]
    set wrptr  [bits_to_int $p 32 45]
    set frozen [bits_to_int $p 46 46]
    set trigd  [bits_to_int $p 47 47]
    set late   [bits_to_int $p 48 63]
    return [list $left $right $wrptr $frozen $trigd $late]
}

set cmd [lindex $argv 0]

if {$cmd eq "peek"} {
    lassign [read_entry $idx 0 0] l r wrptr frozen trigd late
    puts "write pointer = $wrptr, triggered = $trigd, frozen = $frozen, entry\[0\] = [s16 $l] / [s16 $r]"
    puts "LATE ADPCM-A fetches (16-bit, wraps at 65536): $late"
    if {$late == 0} {
        puts "  -> zero so far. If the noise has been audible since the core"
        puts "     started, the fixed-latency deadline is NOT being missed and"
        puts "     the hypothesis is dead -- look elsewhere before dumping."
    }
    end_insystem_source_probe
    exit 0
}

if {$cmd eq "arm"} {
    # Disarm then re-arm: clears any previous capture so the next trigger is
    # a fresh one, and leaves the ring free-running. The threshold rides in
    # on the address field and is latched by the arm edge.
    set n [lindex $argv 1]
    if {$n eq ""} { set n 1 }
    read_entry $idx 0 0 0
    after 50
    read_entry $idx $n 0 1
    puts "armed at burst threshold $n -- the buffer will freeze itself around"
    puts "the next cluster of late ADPCM-A fetches"
    end_insystem_source_probe
    exit 0
}

if {$cmd ne "dump"} {
    puts "usage: read_audio.tcl arm \[n\] | peek | dump <outfile.bin> \[--force\]"
    end_insystem_source_probe
    exit 1
}

set out [lindex $argv 1]
if {$out eq ""} { puts "usage: read_audio.tcl dump <outfile.bin> \[--force\]"; end_insystem_source_probe; exit 1 }
set force [expr {[lsearch $argv "--force"] >= 0}]

# Normally the buffer has already frozen ITSELF around an artefact (see the
# auto-trigger in psikyo_core.sv). Dumping an unfrozen buffer would just
# capture whatever happens to be playing, which is what we already know is
# clean -- so refuse, unless --force is given for a deliberate baseline grab.
lassign [read_entry $idx 0 0] l r wrptr frozen trigd late
puts "late ADPCM-A fetches so far: $late"
if {!$frozen} {
    if {!$force} {
        puts "buffer has not triggered yet (triggered=$trigd, frozen=$frozen)."
        puts "Play until the distortion happens; the core freezes itself around it."
        puts "Use 'arm' first if you have not, or pass --force for a baseline capture."
        end_insystem_source_probe
        exit 1
    }
    puts "no trigger, --force given: freezing manually for a baseline capture"
    lassign [read_entry $idx 0 1] l r wrptr frozen trigd
}
puts "frozen (triggered=$trigd); write pointer = $wrptr (oldest entry is at wr_ptr)"
puts "the artefact should sit near the MIDDLE of the dump"

set fh [open $out wb]
fconfigure $fh -translation binary

# Start at the write pointer: that is the OLDEST entry in a full ring, so the
# file comes out in chronological order and needs no post-processing.
for {set i 0} {$i < 16384} {incr i} {
    set a [expr {($wrptr + $i) % 16384}]
    lassign [read_entry $idx $a 0] l r wp fz tg
    puts -nonewline $fh [binary format ss [s16 $l] [s16 $r]]
    if {($i % 2048) == 0} { puts "  ...$i/16384" }
}
close $fh

# Disarm, which also clears the freeze, so the next 'arm' starts clean.
read_entry $idx 0 0 0
end_insystem_source_probe
puts "wrote $out (16384 stereo samples, signed 16-bit LE, chronological)"
