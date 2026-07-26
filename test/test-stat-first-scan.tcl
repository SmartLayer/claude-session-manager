#!/usr/bin/env wish9.0
# Issue #11: stat-first two-stage browse scan.
#
# When scan_stat_first is on and the snapshot sets no min-turns floor, the browse
# scan paints each row in two stages: a stat-only pass emits a skeleton (date,
# size, folder, uuid, bookmark) from the filesystem alone, opening no file, and a
# content pass then opens each file and fills the subject preview, slug and turn
# count in place.
#
# Part A (ordering): every in-window row is modelled from stat alone before the
# content pass opens its first file, counted through the scan_one seam. The
# skeletons carry date and size; the content pass upgrades them, clears the
# stat_only flag, and the store stays audit-clean.
#
# Part B (the floor): with a min-turns floor set, the stat pass is suppressed and
# the single content pass runs, so a sub-floor session never flashes in then out -
# the list matches the single-pass content.
#
# Part C (a skeleton upgraded by its content pass): the acceptance's white-box
# case, observed between the two publishes - the row shows date/size with no
# subject while stat_only, then the content publish fills the subject/turns and
# clears the flag on the same node.
#
# Runs under wish (it builds a SessionList); run-audit routes it to wish9.0 on the
# private Xvfb.

package require Tcl 9
package require Tk

set SAND [file join [pwd] _stat_first_sandbox]
set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add [file join $ROOT modules]
::tcl::tm::path add [file join $ROOT vendor]
package require leash
package require streamtree
set ::questlog_config_only 1; source [file join $ROOT questlog]
foreach f {lib/cost.tcl ui/theme.tcl lib/path.tcl lib/listfilter.tcl \
           lib/match.tcl ui/terminal.tcl ui/live.tcl lib/scan.tcl lib/search.tcl \
           ui/drag.tcl ui/toolbar.tcl ui/sessions.tcl} {
    source [file join $ROOT $f]
}
::questlog::ui::theme::init

# Arm the two-stage scan for this run (default is off, pending evaluation).
namespace eval ::questlog::config { dict set Config scan_stat_first 1 }

::questlog::path::_real_file delete -force $SAND
set ::env(HOME) $SAND

set ::bgerr ""
proc bgerror {msg} { set ::bgerr $msg }

proc noop {args} {}
proc write_session {path prompts secs} {
    ::questlog::path::_real_file mkdir [file dirname $path]
    set ts [clock format $secs -format "%Y-%m-%dT%H:%M" -gmt 1]
    set fh [open $path w]
    set t 0
    foreach p $prompts {
        puts $fh "{\"type\":\"user\",\"cwd\":\"/tmp/proj\",\"timestamp\":\"${ts}:0${t}Z\",\"message\":{\"role\":\"user\",\"content\":\"$p\"}}"
        puts $fh "{\"type\":\"assistant\",\"timestamp\":\"${ts}:0${t}Z\",\"message\":{\"model\":\"claude-3-5-sonnet-20241022\",\"content\":\"reply\"}}"
        incr t
    }
    close $fh
}

set PROOT [file join $SAND .claude projects]
set P1 [file join $PROOT -tmp-ssf-p1]
set FOLDER [file tail $P1]
set Ap [file join $P1 aaaa.jsonl]     ;# 2 turns
set Bp [file join $P1 bbbb.jsonl]     ;# 1 turn  (below a floor of 2)
set Cp [file join $P1 cccc.jsonl]     ;# 3 turns
set NOW [clock seconds]
write_session $Ap {a-first a-second}          [expr {$NOW - 3600}]
write_session $Bp {b-only}                     [expr {$NOW - 2 * 3600}]
write_session $Cp {c-first c-second c-third}   [expr {$NOW - 3 * 3600}]
file mtime $Ap [expr {$NOW - 3600}]
file mtime $Bp [expr {$NOW - 2 * 3600}]
file mtime $Cp [expr {$NOW - 3 * 3600}]

set SL ""
set ::Scan [::questlog::Scan new [list apply {{r} { $::SL on_scan_row $r }}] noop \
    {} {} [list apply {{p} { $::SL stored_mtime $p }}]]

# Seams: count content opens (scan_one) and stat-only builds (scan_one_stat), and
# capture how many rows are already modelled the moment the first file is opened.
set ::OPENS 0
set ::STATS 0
set ::first_open_seen ""
oo::objdefine $::Scan method scan_one {path} {
    if {$::first_open_seen eq ""} { set ::first_open_seen [$::SL session_count] }
    incr ::OPENS
    next $path
}
oo::objdefine $::Scan method scan_one_stat {path} { incr ::STATS; next $path }

proc scanpath {path}   { return [$::Scan scan_path $path] }
proc resolvef {f}      { return "/tmp/proj" }
proc subagentsf {path} { return [$::Scan subagents_for $path] }

set SL [::questlog::ui::SessionList new .s resolvef noop noop noop noop noop \
            noop scanpath noop subagentsf noop]
pack .s -fill both -expand 1

set fails 0
proc check {name got want} {
    if {$got eq $want} { puts "ok   - $name" } else {
        puts "FAIL - $name"; puts "       got:  $got"; puts "       want: $want"; incr ::fails
    }
}

proc switch_scope {snap} {
    $::SL apply_filter $snap
    set ::scan_done 0
    $::Scan extend $snap
    after 300 [list set ::scan_done 1]
    vwait ::scan_done
    update
}

# ---- Part A: rows before opens, then the content pass upgrades them ---------
switch_scope [dict create since 30d]
check "stat pass emitted a skeleton for every path" 3 $::STATS
check "content pass opened every path"              3 $::OPENS
check "every row modelled before the first open"    3 $::first_open_seen
check "Ap upgraded: turn count filled"    2  [$SL sget $Ap nturns]
check "Cp upgraded: turn count filled"    3  [$SL sget $Cp nturns]
check "Ap upgraded: subject filled"       1  [expr {[$SL sget $Ap first_user] ne ""}]
check "Ap upgraded: stat_only cleared"    0  [$SL sget $Ap stat_only]
check "Cp upgraded: stat_only cleared"    0  [$SL sget $Cp stat_only]
check "1-turn Bp kept under no floor"     1  [$SL has_session $Bp]
check "date survived the upgrade"         1  [expr {[$SL sget $Ap when] ne ""}]
check "size survived the upgrade"         1  [expr {[$SL sget $Ap size 0] > 0}]
check "no background error (Part A)"      "" $::bgerr
check "audit clean after two-stage scan"  {} [$SL audit]

# ---- Part B: a min-turns floor suppresses the stat pass ---------------------
set ::STATS 0; set ::OPENS 0; set ::first_open_seen ""
switch_scope [dict create since 30d min_turns 2]
check "stat pass suppressed under a floor"      0 $::STATS
check "content pass still opened each path"     3 $::OPENS
check "1-turn Bp absent under floor 2"          0 [$SL has_session $Bp]
check "2-turn Ap present under floor 2"         1 [$SL has_session $Ap]
check "3-turn Cp present under floor 2"         1 [$SL has_session $Cp]
set any_skel 0
foreach p [$SL all_session_paths] { if {[$SL sget $p stat_only 0]} { incr any_skel } }
check "no stat_only rows linger under a floor"  0 $any_skel
check "no background error (Part B)"            "" $::bgerr
check "audit clean under a floor"               {} [$SL audit]

# ---- Part C: a skeleton, observed, then upgraded by its content pass --------
# Push the two stages by hand so the intermediate skeleton state is visible: the
# row paints date and size from stat alone, with no subject and its turn count
# still unknown, then the content publish fills the subject/turns on the same node.
$SL apply_filter [dict create since 30d]
set skel [$::Scan scan_one_stat $Ap]
check "skeleton flagged stat_only"          1 [dict get $skel stat_only]
check "skeleton carries a size from stat"   1 [expr {[dict get $skel size] > 0}]
check "skeleton carries no subject (unread)" "" [dict get $skel first_user]
check "skeleton turn count unknown"         "" [dict get $skel nturns]

$SL on_scan_row $skel
check "skeleton modelled"                   1 [$SL has_session $Ap]
check "list shows the date from stat alone" 1 [expr {[$SL sget $Ap when] ne ""}]
check "list shows the size from stat alone" 1 [expr {[$SL sget $Ap size 0] > 0}]
check "folder heading sums the skeleton size" 1 \
    [expr {[dict get [$SL folder_totals $FOLDER] size] > 0}]
check "modelled row still awaits content"   1 [$SL sget $Ap stat_only]
check "subject empty before the content pass" "" [$SL sget $Ap first_user]

set full [$::Scan scan_one $Ap]
$SL on_scan_row $full
check "content pass filled the subject"     1 [expr {[$SL sget $Ap first_user] ne ""}]
check "content pass filled the turn count"  2 [$SL sget $Ap nturns]
check "content pass cleared stat_only"      0 [$SL sget $Ap stat_only]
check "one node throughout (audit clean)"   {} [$SL audit]
check "no background error (Part C)"        "" $::bgerr

$SL destroy
$::Scan destroy
::questlog::path::_real_file delete -force $SAND
puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
