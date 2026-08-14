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


# ---- the same arrival, reached the other two ways ---------------------------
# A subagent match routes through add_subagent_matches before the guard above
# runs, and a browse-mode scan row through add_scan_row. All three share
# draw_arrival, so a detached folder defers in each.

proc settle {tag} {
    after 600 [list set ::$tag 1]
    vwait ::$tag
    update
}

# Raise the floor above every drawn row, so the folder empties and the rebuild
# drops its heading. It stays above them for the rest of the file: an arrival
# is admitted by carrying more turns than the floor, not by lowering it, since
# lowering it rebuilds and re-attaches the folder before the arrival lands.
$SL set_turns_view 5
settle d1
check "the folder detaches with every drawn row hidden" [$SL folder_attached $FOLDER] 0

# A subagent match whose parent the floor admits. The parent is not in the
# model yet, so it hydrates here, unrendered, into a detached folder - the
# arrangement add_subagent_matches drew into.
set PARENT [file join $P1 cccc.jsonl]
write_session $PARENT {one two three four five six} $NOW
set CHILD [file join $P1 cccc-child.jsonl]
set ::bgerr ""
if {[catch {
    $SL begin_batch
    $SL add_subagent_matches [list [dict create path $CHILD parent_path $PARENT \
        folder $FOLDER agent_id ag1 line 1 btype user \
        content "a needle here" lineoff 0 is_child 1]]
    $SL end_batch
} err]} { set ::bgerr $err }
update
check "the hydrated parent clears the floor" [$SL sflag $PARENT hidden] 0
check "a subagent match into a detached folder raises nothing" $::bgerr ""

# The browse stream reaches the same decision by its own door. add_scan_row
# attaches nothing while a search is on (the result index owns the list then),
# so this needs a browse snapshot, which clears the store and starts over.
# Browse folders open collapsed, so the folder is expanded by hand: an expanded
# folder emptied by a view floor is the arrangement that detaches one here.
set FRESH [file join $P1 dddd.jsonl]
write_session $FRESH {one two three four five six seven eight} $NOW
$SL set_query [list] 1
$SL apply_filter [dict create since all turns_view 1]
update
$SL add_scan_row [$::Scan scan_path $THIN]
$SL add_scan_row [$::Scan scan_path $PARENT]
update
$SL toggle_folder $FOLDER
update
check "the browsed folder is expanded and drawn" \
    [expr {[$SL folder_expanded $FOLDER] && [$SL folder_attached $FOLDER]}] 1
$SL set_turns_view 7
settle d2
check "the browsed folder detaches when the floor empties it" \
    [$SL folder_attached $FOLDER] 0
set ::bgerr ""
if {[catch {$SL add_scan_row [$::Scan scan_path $FRESH]} err]} { set ::bgerr $err }
update
check "the arriving scan row clears the floor" [$SL sflag $FRESH hidden] 0
check "a scan row into a detached folder raises nothing" $::bgerr ""

# The heading redraw a resize runs over every root, detached ones included,
# with the detached folder selected: the selection is model state and survives
# the rebuild that dropped the heading.
settle d3
$SL folder_select $FOLDER
$SL set_turns_view 99
settle d4
check "the selected folder is detached" [$SL folder_attached $FOLDER] 0
set ::bgerr ""
if {[catch {$SL relayout_content} err]} { set ::bgerr $err }
update
check "redrawing a detached selected heading raises nothing" $::bgerr ""

::questlog::path::_real_file delete -force $SAND
puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
