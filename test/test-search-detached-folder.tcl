#!/usr/bin/env wish9.0
# A search result whose folder heading is not on screen must not crash the flush.
#
# The rebuild drops a folder with no visible rows: render_skip returns 1 for it,
# so mass_unrender's cleared start/end marks are never re-laid and the node sits
# in the store expanded but unrendered. render_session_matches then decided
# whether to draw an arriving session from folder_expanded, which is true for
# every folder under a search, so it drew a row whose parent's append point was
# the empty string and streamtree's render_row threw "bad text index """ out of
# the idle flush.
#
# The fixture is one folder holding a session the turns floor hides and a
# session it admits, matched in that order. The first schedules the view
# rebuild that detaches the folder; the second arrives into it.
#
# Runs under wish (it builds a SessionList); run-audit routes it to wish9.0 on
# the private Xvfb. Standalone: DISPLAY=:95 wish9.0 test-search-detached-folder.tcl

package require Tcl 9
package require Tk

set SAND [file join [pwd] _detachedfolder_sandbox]
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

::questlog::path::_real_file delete -force $SAND
set ::env(HOME) $SAND

set ::bgerr ""
proc bgerror {msg} { set ::bgerr $msg }

proc noop {args} {}

# A session of N answered prompts, so its turn count is N exactly.
proc write_session {path prompts secs} {
    ::questlog::path::_real_file mkdir [file dirname $path]
    set ts [clock format $secs -format "%Y-%m-%dT%H:%M" -gmt 1]
    set fh [open $path w]
    set t 0
    foreach p $prompts {
        puts $fh "{\"type\":\"user\",\"cwd\":\"/tmp/proj\",\"timestamp\":\"${ts}:0${t}Z\",\"message\":{\"role\":\"user\",\"content\":\"$p\"}}"
        puts $fh "{\"type\":\"assistant\",\"timestamp\":\"${ts}:0${t}Z\",\"message\":{\"model\":\"claude-3-5-sonnet-20241022\",\"usage\":{\"input_tokens\":100,\"output_tokens\":50}}}"
        incr t
    }
    close $fh
}

set PROOT [file join $SAND .claude projects]
set FOLDER -tmp-df-p1
set P1 [file join $PROOT $FOLDER]
set THIN  [file join $P1 aaaa.jsonl]   ;# one turn: below a floor of 2
set THICK [file join $P1 bbbb.jsonl]   ;# three turns: above it
set NOW [clock seconds]
write_session $THIN  {only-one} $NOW
write_session $THICK {one two three} $NOW
file mtime $THIN  $NOW
file mtime $THICK $NOW

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
        puts "FAIL - $name"; puts "       got:  $got"; puts "       want: $want"; incr ::fails
    }
}

# A search snapshot with the GUI's own starting turns floor, which is what puts
# the thin session out of view.
set snap [dict create since all turns_view 2 search needle]
$SL set_query [list needle] 1
$SL apply_filter $snap
update

proc match_for {path} {
    return [list [dict create path $path folder $::FOLDER line 1 \
        btype user content "a needle here" lineoff 0 is_child 0]]
}

# The thin session matches first. It is hidden, so the flush schedules the view
# rebuild, and the rebuild finds the folder with nothing visible under it.
$SL begin_batch
$SL render_session_matches [match_for $THIN] [$::Scan scan_path $THIN]
$SL end_batch
update
check "the hidden session is in the model" [$SL has_session $THIN] 1
check "the turns floor hides it" [$SL sflag $THIN hidden] 1

# Let the debounced rebuild run: it drops the folder heading, because no row
# under it is visible.
after 600 [list set ::settled 1]
vwait ::settled
update
check "the folder with nothing visible is detached" [$SL folder_attached $FOLDER] 0

# The admitted session now arrives into that detached folder. This is the flush
# that threw.
set ::bgerr ""
check "the detached folder is still expanded" [$SL folder_expanded $FOLDER] 1
$SL begin_batch
if {[catch {$SL render_session_matches [match_for $THICK] [$::Scan scan_path $THICK]} err]} {
    set ::bgerr $err
}
$SL end_batch
update
check "a match into a detached folder raises nothing" $::bgerr ""
check "the admitted session is in the model" [$SL has_session $THICK] 1

# Once the rebuild has run again the folder is back, with its visible row.
after 600 [list set ::settled2 1]
vwait ::settled2
update
check "the folder is drawn again" [$SL folder_attached $FOLDER] 1
check "the admitted session is drawn" [$SL sflag $THICK rendered] 1

::questlog::path::_real_file delete -force $SAND
puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
