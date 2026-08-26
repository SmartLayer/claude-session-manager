#!/usr/bin/env wish9.0
# Removing a bookmark while "bookmarked only" is on must take effect at the
# toggle, not at the next poll: the +x bit is the filter's attribute, so
# reconcile_one (the bookmark toggle's refresh path) re-derives that one row's
# hidden flag and leaves through the debounced view rebuild, which also
# recounts the heading. The heavy pass is not allowed: apply_attr_filters
# re-derives every loaded row and rebuilds unconditionally, and a single
# bookmark flip must not pay for it. The marker-only redraw with no filter on
# survives unchanged.

package require Tcl 9
package require Tk

set SAND [file join [pwd] _bmtoggle_sandbox]
set FOLDER "-tmp-bmtoggle-proj"

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

::questlog::path::_real_file delete -force $SAND
set PROJDIR [file join $SAND .claude projects $FOLDER]
::questlog::path::_real_file mkdir $PROJDIR
set ::env(HOME) $SAND

proc noop {args} {}

proc write_session {path prompts ts} {
    set fh [open $path w]
    set t 0
    foreach p $prompts {
        puts $fh "{\"type\":\"user\",\"cwd\":\"/tmp/proj\",\"timestamp\":\"${ts}:0${t}Z\",\"message\":{\"role\":\"user\",\"content\":\"$p\"}}"
        puts $fh "{\"type\":\"assistant\",\"timestamp\":\"${ts}:0${t}Z\",\"message\":{\"model\":\"claude-sonnet-4-6\",\"usage\":{\"input_tokens\":100,\"output_tokens\":50}}}"
        incr t
    }
    close $fh
}

# A is plain; B and C carry the bookmark bit, so clearing B's still leaves a
# shown row and a live heading to read the count from.
set Ap [file join $PROJDIR aaaa.jsonl]
set Bp [file join $PROJDIR bbbb.jsonl]
set Cp [file join $PROJDIR cccc.jsonl]
write_session $Ap {a-first a-second}         "2026-06-10T17:00"
write_session $Bp {b-first b-second b-third} "2026-06-09T10:00"
write_session $Cp {c-first c-second}         "2026-06-08T09:00"
file mtime $Ap [clock scan "2026-06-10 17:01:00" -gmt 1]
file mtime $Bp [clock scan "2026-06-09 10:01:00" -gmt 1]
file mtime $Cp [clock scan "2026-06-08 09:01:00" -gmt 1]
::questlog::path::set_bookmark $Bp
::questlog::path::set_bookmark $Cp

set SL ""
set ::Scan [::questlog::Scan new [list apply {{r} { $::SL on_scan_row $r }}] noop]
proc scanpath {path} { return [$::Scan scan_path $path] }
proc resolvef {f}    { return "/tmp/proj" }
proc subagentsf {path} { return [$::Scan subagents_for $path] }

set SL [::questlog::ui::SessionList new .s resolvef noop noop noop noop noop \
            noop scanpath noop subagentsf noop]
pack .s -fill both -expand 1

set fails 0
proc check {name got want} {
    if {$got eq $want} { puts "ok   - $name" } else {
        puts "FAIL - $name"; puts "       got:  $got"; puts "       want: $want"
        incr ::fails
    }
}
proc counts {} {
    set subj [dict get [$::SL folder_subject [$::SL fid $::FOLDER]] subject]
    regexp {\(([^)]*)\)} $subj -> got
    return $got
}
# Ride out the debounced view rebuild reconcile_one asks for.
proc settle {} {
    after [expr {[::questlog::config::get resort_debounce_ms] + 100}] \
        {set ::settled 1}
    vwait ::settled
    update
}

$SL apply_filter [dict create since all]
set ::scan_done 0
$::Scan extend [dict create since all]
after 200 [list set ::scan_done 1]
vwait ::scan_done
$SL toggle_folder $FOLDER
update

$SL attr_filter_set bookmarked 1
update
check "bookmarked only: two rows shown" [$SL folder_visible_count $FOLDER] 2
check "bookmarked only: heading reads 2 of 3" [counts] "2 of 3"
check "B is rendered" [$SL sflag $Bp rendered] 1

# The heavy pass is off-limits from here: count every call.
set ::applies 0
oo::objdefine $SL method apply_attr_filters {} { incr ::applies; next }

# --- Remove B's bookmark and refresh through the toggle's own path.
::questlog::path::clear_bookmark $Bp
$SL reconcile_one $Bp
check "hidden re-derived at the toggle itself" [$SL sflag $Bp hidden] 1
settle
check "B left the view"                 [$SL sflag $Bp rendered] 0
check "one shown row remains"           [$SL folder_visible_count $FOLDER] 1
check "heading recounts to 1 of 3"      [counts] "1 of 3"
check "no apply_attr_filters pass ran"  $::applies 0

# --- With no filter on, the toggle is still the marker-only redraw.
$SL attr_filter_set bookmarked 0
update
check "filter off: B shows again" [$SL sflag $Bp rendered] 1
::questlog::path::set_bookmark $Bp
$SL reconcile_one $Bp
check "marker field refreshed from the bit" [$SL sget $Bp bookmarked] 1
check "row stays visible"                   [$SL sflag $Bp hidden] 0
check "row stays rendered"                  [$SL sflag $Bp rendered] 1

::questlog::path::_real_file delete -force $SAND
puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
