#!/usr/bin/env wish9.0
# The folder heading's figures agree with each other under a list filter:
# the count reads "(N of M)" with M the store's count, and the bytes, money,
# machine time and A/H beside it are the sums of the N shown rows, so a
# heading never prices rows it is not showing. The hidden count is the
# store's fold less the shown fold. Each of the three filters is exercised
# in turn, the model filter included: it hides loaded rows like the other
# two even though member_filters excludes it (it claims no membership
# outside the list), which is why the list-global FilterNote goes blank
# under it while the heading still narrows.

package require Tcl 9
package require Tk

set SAND [file join [pwd] _headingtot_sandbox]
set FOLDER "-tmp-headingtot-proj"

set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add [file join $ROOT modules]
::tcl::tm::path add [file join $ROOT vendor]
package require leash
package require streamtree
set ::questlog_config_only 1; source [file join $ROOT questlog]
foreach f {lib/cost.tcl ui/theme.tcl lib/path.tcl lib/listfilter.tcl \
           lib/match.tcl ui/terminal.tcl ui/live.tcl lib/scan.tcl lib/search.tcl \
           ui/drag.tcl ui/toolbar.tcl ui/reveal.tcl ui/sessions.tcl} {
    source [file join $ROOT $f]
}
::questlog::ui::theme::init
::questlog::cost::load_rates $ROOT

::questlog::path::_real_file delete -force $SAND
set PROJDIR [file join $SAND .claude projects $FOLDER]
::questlog::path::_real_file mkdir $PROJDIR
set ::env(HOME) $SAND
unset -nocomplain ::env(CLAUDE_CONFIG_DIR)

proc noop {args} {}

# Two user turns clear a min-turns floor; the model is per-session so the
# model filter can split the corpus.
proc write_session {path model prompts ts} {
    set fh [open $path w]
    set t 0
    foreach p $prompts {
        puts $fh "{\"type\":\"user\",\"cwd\":\"/tmp/proj\",\"timestamp\":\"${ts}:0${t}Z\",\"message\":{\"role\":\"user\",\"content\":\"$p\"}}"
        puts $fh "{\"type\":\"assistant\",\"timestamp\":\"${ts}:0${t}Z\",\"message\":{\"model\":\"$model\",\"usage\":{\"input_tokens\":100,\"output_tokens\":50}}}"
        incr t
    }
    close $fh
}

# The corpus: A runs (below), B is bookmarked, C is the odd model out. Every
# filter leaves a different remainder, and always hides at least one row.
set Ap [file join $PROJDIR aaaa.jsonl]
set Bp [file join $PROJDIR bbbb.jsonl]
set Cp [file join $PROJDIR cccc.jsonl]
write_session $Ap claude-sonnet-4-6 {a-first a-second}                "2026-06-10T17:00"
write_session $Bp claude-sonnet-4-6 {b-first b-second b-third}        "2026-06-09T10:00"
write_session $Cp claude-opus-4-8   {c-first c-second}                "2026-06-08T09:00"
file mtime $Ap [clock scan "2026-06-10 17:01:00" -gmt 1]
file mtime $Bp [clock scan "2026-06-09 10:01:00" -gmt 1]
file mtime $Cp [clock scan "2026-06-08 09:01:00" -gmt 1]
::questlog::path::set_bookmark $Bp

set SL ""
set ::Scan [::questlog::Scan new [list apply {{r} { $::SL on_scan_row $r }}] noop]
proc scanpath {path} { return [$::Scan scan_path $path] }
proc resolvef {f}    { return "/tmp/proj" }
proc subagentsf {path} { return [$::Scan subagents_for $path] }
proc subagent_cost_cb {path} {}

set SL [::questlog::ui::SessionList new .s resolvef noop noop noop noop noop \
            noop scanpath noop subagentsf subagent_cost_cb]
pack .s -fill both -expand 1

set fails 0
proc check {name got want} {
    if {$got eq $want} {
        puts "ok   - $name"
    } else {
        puts "FAIL - $name"
        puts "       got:  $got"
        puts "       want: $want"
        incr ::fails
    }
}

# The heading through the paths the render uses: the laid cells and the
# subject's count string.
proc cell {col} {
    foreach pair [$::SL cell_values [$::SL fid $::FOLDER]] {
        lassign $pair id v
        if {$id eq $col} { return $v }
    }
}
proc counts {} {
    set subj [dict get [$::SL folder_subject [$::SL fid $::FOLDER]] subject]
    regexp {\(([^)]*)\)} $subj -> got
    return $got
}
proc hidden {} {
    return [expr {[dict get [$::SL node_aggregate [$::SL fid $::FOLDER]] count] \
                  - [dict get [$::SL node_aggregate [$::SL fid $::FOLDER] 1] count]}]
}

$SL apply_filter [dict create since all]
set ::scan_done 0
$::Scan extend [dict create since all]
after 200 [list set ::scan_done 1]
vwait ::scan_done
$SL toggle_folder $FOLDER
# The cost pass is what puts a model label (and a cost) on a row; run it so
# the model filter has labels to shut off, as the app's worker would. The
# transcripts' stamps are too close to time, so the times are set here.
foreach path [list $Ap $Bp $Cp] dur {600 1200 300} hum {100 400 300} {
    set d [::questlog::cost::build_cost_dict [::questlog::cost::parse_file $path]]
    $SL refresh_cost $path [dict replace $d duration_secs $dur human_secs $hum]
}
update

foreach p [list $Ap $Bp $Cp] {
    set sz($p) [file size $p]
    set cost($p) [$SL sget $p cost]
}

# What the heading should read over a set of shown rows: each laid cell as
# a session row would format the same sums.
proc want {paths} {
    set sz 0; set cost 0.0; set dur 0; set hum 0
    foreach p $paths {
        incr sz $::sz($p); set cost [expr {$cost + $::cost($p)}]
        incr dur [$::SL sget $p duration_secs]; incr hum [$::SL sget $p human_secs]
    }
    return [list [$::SL fmt_size $sz] [::questlog::cost::format_usd $cost] \
                [::questlog::cost::fmt_dur $dur] [format %.1f [expr {double($dur) / $hum}]]]
}
proc cells {} { return [list [cell size] [cell cost] [cell duration] [cell ah]] }

# --- no filter: the heading sums all three and shows a bare count.
check "no filter: count" [counts] 3
check "no filter: size, cost and time cells sum all rows" [cells] [want [list $Ap $Bp $Cp]]
check "no filter: nothing hidden" [hidden] 0

# --- bookmarked: only B shows, and every figure on the heading says so.
$SL attr_filter_set bookmarked 1
update
check "bookmarked: visible count" [dict get [$SL node_aggregate [$SL fid $FOLDER] 1] count] 1
check "bookmarked: count reads shown of total" [counts] "1 of 3"
check "bookmarked: size, cost and time cells sum the shown rows" [cells] [want [list $Bp]]
check "bookmarked: hidden = model count - visible" [hidden] 2
$SL attr_filter_set bookmarked 0
update

# --- model: shutting off C's label hides C; A and B are what sums.
$SL attr_filter_set model [list [::questlog::cost::model_label claude-opus-4-8]]
update
check "model: visible count" [dict get [$SL node_aggregate [$SL fid $FOLDER] 1] count] 2
check "model: count reads shown of total" [counts] "2 of 3"
check "model: size, cost and time cells sum the shown rows" [cells] [want [list $Ap $Bp]]
check "model: hidden = model count - visible" [hidden] 1
$SL attr_filter_set model [list]
update

# --- running: only A runs, so only A is counted and summed.
$SL reconcile_running [dict create aaaa $Ap]
$SL attr_filter_set running 1
update
check "running: visible count" [dict get [$SL node_aggregate [$SL fid $FOLDER] 1] count] 1
check "running: count reads shown of total" [counts] "1 of 3"
check "running: size, cost and time cells sum the shown rows" [cells] [want [list $Ap]]
check "running: hidden = model count - visible" [hidden] 2
$SL attr_filter_set running 0
$SL reconcile_running [dict create]
update

# --- filters off again: the store never moved, so the heading recovers whole.
check "released: count back to bare" [counts] 3
check "released: the cells sum all rows again" [cells] [want [list $Ap $Bp $Cp]]

::questlog::path::_real_file delete -force $SAND
puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
