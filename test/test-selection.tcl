#!/usr/bin/env wish9.0
# Multi-selection model for the session list.
#
# The list holds a set of selected sessions (SelectedSet) with an anchor, keyed
# by the stable node id (sid). A plain click selects one; Control toggles one
# across folders; Shift selects the sessions among the drawn rows between the
# anchor and the click, whatever folders the run crosses: the headings in it
# are held apart, and a shut folder in it contributes none of its sessions,
# since nothing undrawn enters a selection. Because the id does not change,
# the set survives a move for free (the node re-parents) and a delete drops it
# (forget_session purges by id). This drives the model directly over a
# three-folder sandbox and asserts each gesture and each survival path.

package require Tcl 9
package require Tk

set SAND [file join [pwd] _selection_sandbox]
set FA "-tmp-sel-a"
set FM "-tmp-sel-m"
set FB "-tmp-sel-b"

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
set DIRA [file join $SAND .claude projects $FA]
set DIRM [file join $SAND .claude projects $FM]
set DIRB [file join $SAND .claude projects $FB]
::questlog::path::_real_file mkdir $DIRA
::questlog::path::_real_file mkdir $DIRM
::questlog::path::_real_file mkdir $DIRB
set ::env(HOME) $SAND
unset -nocomplain ::env(CLAUDE_CONFIG_DIR)

proc noop {args} {}

proc write_session {path ts} {
    set fh [open $path w]
    puts $fh "{\"type\":\"user\",\"cwd\":\"/tmp/proj\",\"timestamp\":\"${ts}Z\",\"message\":{\"role\":\"user\",\"content\":\"hello\"}}"
    puts $fh "{\"type\":\"assistant\",\"timestamp\":\"${ts}Z\",\"message\":{\"model\":\"claude-3-5-sonnet-20241022\",\"usage\":{\"input_tokens\":100,\"output_tokens\":50}}}"
    puts $fh "{\"type\":\"user\",\"timestamp\":\"${ts}Z\",\"message\":{\"role\":\"user\",\"content\":\"more\"}}"
    close $fh
}

# Folder A: a01 newest .. a03 oldest, so date-descending display order is
# a01, a02, a03. Folder M: m01, older. Folder B: b01, b02, older still, so the
# roots read A, M, B by recency. Session moments are offsets from now, not
# calendar dates: the scan below filters with `since 30d`, and a fixed date
# silently ages out of that window and starves the sandbox (it happened; the
# streamed-in counts collapsed to 1 and 0).
proc session_moment {days_ago} { return [expr {[clock seconds] - $days_ago*24*3600}] }
proc write_at {dir name days_ago} {
    set p [file join $dir $name.jsonl]
    set when [session_moment $days_ago]
    write_session $p [clock format $when -format "%Y-%m-%dT%H:%M:%S" -gmt 1]
    file mtime $p $when
    return $p
}
set a01 [write_at $DIRA a01 1]
set a02 [write_at $DIRA a02 2]
set a03 [write_at $DIRA a03 3]
set m01 [write_at $DIRM m01 4]
set b01 [write_at $DIRB b01 5]
set b02 [write_at $DIRB b02 6]

set SL ""
set ::Scan [::questlog::Scan new [list apply {{r} { $::SL on_scan_row $r }}] noop]
proc scanpath {path} { return [$::Scan scan_path $path] }
proc resolvef {f}    { return "/tmp/proj" }
proc subagentsf {path} { return [$::Scan subagents_for $path] }
proc folderboundf {f} { set ::folder_bound_seen $f }

set SL [::questlog::ui::SessionList new .s resolvef noop noop noop noop noop \
            noop scanpath noop subagentsf noop noop folderboundf]
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
# Selection as a sorted list, so order of toggles does not make the test flap.
proc sel {} { return [lsort [$::SL selection_paths]] }

$SL apply_filter [dict create since 30d]
set ::scan_done 0
$::Scan extend [dict create since 30d]
after 200 [list set ::scan_done 1]
vwait ::scan_done
# The first root opened on arrival; the other two are opened here.
$SL toggle_folder $FM
$SL toggle_folder $FB
update

check "the three folders streamed in" \
    [lmap f [list $FA $FM $FB] { llength [$SL folder_session_paths $f] }] {3 1 2}
check "every row is drawn" \
    [lmap p [list $a01 $a02 $a03 $m01 $b01 $b02] { $SL sflag $p rendered }] {1 1 1 1 1 1}

# ---- folder selection: fid-keyed, exclusive with session selection ------
# A folder heading is selectable too, but held apart from the session set: the
# highlight keys by the folder's node id (fid), the session set by sid. The two
# selections are mutually exclusive.
$SL selection_set $a02
$SL folder_select $FA
check "folder_select highlights the folder" [$SL is_folder_selected $FA] 1
check "folder_select clears the session selection" [$SL selection_count] 0
$SL selection_set $a01
check "a session gesture clears the folder highlight" [$SL is_folder_selected $FA] 0
check "the session selection stands after clearing the folder" [sel] [list $a01]

# ---- folder-bound invokes the owner callback --------------------------
set ::folder_bound_seen ""
$SL folder_bound $FB
check "folder_bound calls OnFolderBound with the folder" $::folder_bound_seen $FB

# ---- plain select --------------------------------------------------------
$SL selection_set $a02
check "plain select picks exactly one" [sel] [list $a02]
check "is_selected true for the member" [$SL is_selected $a02] 1
check "is_selected false for a non-member" [$SL is_selected $a01] 0

# ---- Control toggle, same folder then across folders ---------------------
$SL selection_toggle $a01
check "ctrl-add a second in the same folder" [sel] [lsort [list $a01 $a02]]
$SL selection_toggle $b01
check "ctrl-add across folders (safe)" [sel] [lsort [list $a01 $a02 $b01]]
$SL selection_toggle $a01
check "ctrl-remove drops just that one" [sel] [lsort [list $a02 $b01]]

# ---- Shift range: the drawn rows between the two clicks -------------------
$SL selection_set $a01
$SL selection_range $a03
check "shift-range covers the run anchor..target in drawn order" [sel] [lsort [list $a01 $a02 $a03]]
$SL selection_set $a03
$SL selection_range $a01
check "shift-range is order-independent (target above anchor)" [sel] [lsort [list $a01 $a02 $a03]]

# The run crosses folders: the sessions of every folder it passes through are
# in, the headings it passes are not.
$SL selection_set $a03
$SL selection_range $b01
check "a cross-folder shift takes the drawn sessions between" [sel] [lsort [list $a03 $m01 $b01]]
check "the headings in the run stay apart from the selection" \
    [list [$SL is_folder_selected $FM] [$SL selection_count]] {0 3}

# A shut folder in the run contributes none of its sessions: nothing undrawn
# enters a selection.
$SL toggle_folder $FM
update
$SL selection_set $a03
$SL selection_range $b01
check "a shut folder between the clicks contributes nothing" [sel] [lsort [list $a03 $b01]]

# An anchor whose row has gone (its folder shut since) re-anchors at the click.
$SL toggle_folder $FM
update
$SL selection_set $m01
$SL toggle_folder $FM
update
$SL selection_range $b01
check "an anchor with no row re-anchors at the target alone" [sel] [list $b01]
$SL toggle_folder $FM
update

# ---- selection survives a move (the set is sid-keyed; the move keeps the id) --
$SL selection_set $a02
set moved [file join $DIRB moved.jsonl]
# The real move renames the file before relocate_card re-keys the store, so the
# new path is on disk when relocate_card re-reads its bookmarked/mtime/size and
# stamps the destination cwd move_one hands it.
::questlog::path::_real_file rename $a02 $moved
$SL relocate_card $a02 $moved $FB /tmp/proj
check "moved member follows to its new path" [$SL is_selected $moved] 1
check "old path is no longer selected" [$SL is_selected $a02] 0

# ---- selection survives a delete (forget_session drops the member) -------
$SL selection_set $a01
$SL forget_session $a01
check "deleting the selected session empties the set" [$SL selection_count] 0

check "domain audit clean at end" [$SL audit] {}
::questlog::path::_real_file delete -force $SAND
puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
