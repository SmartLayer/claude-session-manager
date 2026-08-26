#!/usr/bin/env wish9.0
# Cheap-live running rows: a session running while questlog is open appends in
# place, moving its file mtime but never its folder's, so poll_arrivals's
# directory gate alone would leave the row frozen at its first-scanned values.
# run_tick forces a bounded-tail re-scan of each modelled running path whose
# file moved, and freshen_attached carries the priced fields (cost, ctx%)
# through that refresh, lagged, instead of resetting them to a per-tick
# re-price. On the quit tick reconcile_running freshens the just-quit session
# from disk (so a short window reads the quit instant's mtime, not the frozen
# one) and asks for the one completion re-price.
#
# Drives the real ::questlog::ui::app::run_tick over a real Scan + SessionList,
# with the live registry faked by records naming this test's own pid.
# Runs under wish; run-audit routes it to wish9.0 on the private Xvfb.

package require Tcl 9
if {[catch {package require Tk} e]} { puts "SKIP - no Tk/display ($e)"; exit 0 }

set SAND [file join [pwd] _running_refresh_sandbox]
set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add [file join $ROOT modules]
::tcl::tm::path add [file join $ROOT vendor]
package require leash
package require streamtree
set ::questlog_config_only 1; source [file join $ROOT questlog]
foreach f {lib/cost.tcl ui/theme.tcl lib/path.tcl lib/listfilter.tcl \
           lib/match.tcl ui/terminal.tcl ui/live.tcl lib/scan.tcl lib/search.tcl \
           ui/drag.tcl ui/toolbar.tcl ui/reveal.tcl ui/sessions.tcl ui/app.tcl} {
    source [file join $ROOT $f]
}
::questlog::ui::theme::init

::questlog::path::_real_file delete -force $SAND
set ::env(HOME) $SAND

set ::bgerr ""
proc bgerror {msg} { set ::bgerr $msg }

proc noop {args} {}

proc write_session {path cwd prompts secs} {
    ::questlog::path::_real_file mkdir [file dirname $path]
    set ts [clock format $secs -format "%Y-%m-%dT%H:%M" -gmt 1]
    set fh [open $path w]
    set t 0
    foreach p $prompts {
        puts $fh "{\"type\":\"user\",\"cwd\":\"$cwd\",\"timestamp\":\"${ts}:0${t}Z\",\"message\":{\"role\":\"user\",\"content\":\"$p\"}}"
        puts $fh "{\"type\":\"assistant\",\"timestamp\":\"${ts}:0${t}Z\",\"message\":{\"model\":\"claude-3-5-sonnet-20241022\",\"usage\":{\"input_tokens\":100,\"output_tokens\":50}}}"
        incr t
    }
    close $fh
}

# ---- fake live registry: records naming this test's own pid, so the real
# proc_alive_matching accepts them (the test-live idiom).
proc real_procstart {pid} {
    set fh [open /proc/$pid/stat r]
    set s [read $fh]
    close $fh
    set rest [string range $s [expr {[string last ) $s] + 2}] end]
    return [lindex $rest 19]
}
set SDIR [file join $SAND .claude sessions]
::questlog::path::_real_file mkdir $SDIR
proc set_running {fname uuid cwd} {
    set fh [open [file join $::SDIR $fname] w]
    puts $fh "{\"pid\":[pid],\"sessionId\":\"$uuid\",\"cwd\":\"$cwd\",\"procStart\":\"[real_procstart [pid]]\"}"
    close $fh
}
proc set_quit {fname} { ::questlog::path::_real_file delete [file join $::SDIR $fname] }

set PROOT [file join $SAND .claude projects]
set cwdA [file normalize [file join $SAND w projA]]
::questlog::path::_real_file mkdir $cwdA
set folderA [::questlog::path::encode_cwd $cwdA]
set dirA [file join $PROOT $folderA]
set Ap [file join $dirA aaaa.jsonl]
set Qp [file join $dirA qqqq.jsonl]

set SL ""
set ::Scan [::questlog::Scan new [list apply {{r} { $::SL on_scan_row $r }}] noop \
    {} {} [list apply {{p} { $::SL stored_mtime $p }}]]
set ::SCANS 0
oo::objdefine $::Scan method scan_one {path} { incr ::SCANS; next $path }
proc scanpath {path}   { return [$::Scan scan_path $path] }
proc subagentsf {path} { return [$::Scan subagents_for $path] }
proc resolvef {f}      { return "" }
set ::COSTQ [list]
proc costq {path} { lappend ::COSTQ $path }

set SL [::questlog::ui::SessionList new .s resolvef noop noop noop noop noop noop \
            scanpath noop subagentsf costq]
pack .s -fill both -expand 1

set fails 0
proc check {name got want} {
    if {$got eq $want} { puts "ok   - $name" } else {
        puts "FAIL - $name"; puts "       got:  $got"; puts "       want: $want"; incr ::fails
    }
}

# Seed the app namespace with the pieces run_tick reads, then drive the real
# tick, cancelling its re-arm each time.
set SNAP [dict create since 1h]
set ::questlog::ui::app::SessionList $SL
set ::questlog::ui::app::Scan $::Scan
set ::questlog::ui::app::PrevSnapshot $SNAP
set ::questlog::ui::app::RunTimer ""
proc tick {} {
    ::questlog::ui::app::run_tick
    after cancel $::questlog::ui::app::RunTimer
    update
}

set NOW [clock seconds]
set mA [expr {$NOW - 600}]
set mQ [expr {$NOW - 7200}]

# --- setup: A is in the 1h window and streams in by extend; Q is outside it
# and enters only through the running import.
write_session $Ap $cwdA {a-first a-second} $mA
file mtime $Ap $mA
write_session $Qp $cwdA {q-first q-second} $mQ
file mtime $Qp $mQ
$SL apply_filter $SNAP
set ::scan_done 0
$::Scan extend $SNAP
after 300 [list set ::scan_done 1]
vwait ::scan_done
update
check "A modelled by extend" [$SL has_session $Ap] 1
check "Q outside the window not modelled" [$SL has_session $Qp] 0

set_running a.json aaaa $cwdA
set_running q.json qqqq $cwdA
tick
check "running Q imported by reconcile" [$SL has_session $Qp] 1

# Price both rows as the cost pass would, then quiet the project dir so the
# arrival poll's directory gate genuinely skips it (backdate past the
# same-second guard and warm the memo).
$SL sset $Ap cost 1.23
$SL sset $Ap own_cost 1.23
$SL sset $Ap context_pct 42
$SL sset $Qp cost 4.56
$SL sset $Qp own_cost 4.56
file mtime $dirA [expr {$NOW - 100}]
file mtime $PROOT [expr {$NOW - 100}]
tick

# --- 1. A live append: the file mtime moves, the folder's does not. The tick
# re-scans the running row (fresh mtime/turns) and carries its priced fields.
set mA2 [expr {$NOW - 10}]
write_session $Ap $cwdA {a-first a-second a-third} $mA2
file mtime $Ap $mA2
file mtime $dirA [expr {$NOW - 100}]
set ::SCANS 0
tick
check "running row re-scanned on the tick" [$SL sget $Ap mtime] $mA2
check "turn count freshened" [$SL sget $Ap nturns] 3
check "only the changed file was read" $::SCANS 1
check "cost carried lagged through the refresh" [$SL sget $Ap cost] 1.23
check "ctx% carried lagged through the refresh" [$SL sget $Ap context_pct] 42

# --- 2. Quiescent tick: nothing moved, nothing is read.
set ::SCANS 0
tick
check "quiescent tick reads nothing" $::SCANS 0

# --- 3. Q quits with a final append the poll never saw: the quit tick
# freshens it from disk, so the fresh mtime (in window) retains the row that
# the frozen mtime (out of window) would have dropped.
set mQ2 [expr {$NOW - 20}]
file mtime $Qp $mQ2
set_quit q.json
tick
check "just-quit session retained by its fresh mtime" [$SL has_session $Qp] 1
check "quit tick freshened the mtime" [$SL sget $Qp mtime] $mQ2
check "quit freshen reset cost for the re-price" [$SL sget $Qp cost] ""

# --- 4. A quits with its file unchanged since the last live refresh: no
# freshen fires, so the completion re-price is asked for directly.
set_quit a.json
set ::COSTQ [list]
tick
check "A retained after quitting" [$SL has_session $Ap] 1
check "unchanged quit asked for the completion re-price" [expr {$Ap in $::COSTQ}] 1
check "lagged cost still shown until the re-price lands" [$SL sget $Ap cost] 1.23

# --- 5. No background error the whole way through.
check "no background error" $::bgerr ""

::questlog::path::_real_file delete -force $SAND
puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
