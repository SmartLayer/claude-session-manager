#!/usr/bin/env wish9.0
# A drag-move relocates a session between two project folders through the
# exact path the GUI takes (app::move_one -> SessionList relocate_card, the
# one store move). The faults this guards against: a second node built under
# the new path (one key, two nodes, a row painted twice), and a move that
# leaves the folder count/size/cost behind, so the source heading keeps its
# old totals over the wrong set of rows.
#
# This drives real moves and asserts the store stays a bijection with correct
# derived totals: one node for the moved path, both folders' headings right, an emptied
# source folder dropped whole, and move_one's same-folder no-op leaving the store
# untouched. The whole-store domain audit is the referee at every step.

package require Tcl 9
package require Tk

set SAND [file join [pwd] _moveagg_sandbox]
set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add [file join $ROOT modules]
::tcl::tm::path add [file join $ROOT vendor]
package require leash
package require streamtree
set ::questlog_config_only 1; source [file join $ROOT questlog]
foreach f {lib/cost.tcl ui/theme.tcl lib/path.tcl lib/listfilter.tcl \
           lib/match.tcl ui/terminal.tcl ui/live.tcl lib/scan.tcl lib/search.tcl \
           ui/drag.tcl ui/toolbar.tcl ui/reveal.tcl ui/sessions.tcl ui/viewer.tcl ui/app.tcl} {
    source [file join $ROOT $f]
}
::questlog::ui::theme::init

::questlog::path::_real_file delete -force $SAND
set ::env(HOME) $SAND
unset -nocomplain ::env(CLAUDE_CONFIG_DIR)

proc noop {args} {}
proc write_session {path prompts ts} {
    ::questlog::path::_real_file mkdir [file dirname $path]
    set fh [open $path w]
    set t 0
    foreach p $prompts {
        puts $fh "{\"type\":\"user\",\"cwd\":\"/tmp/proj\",\"timestamp\":\"${ts}:0${t}Z\",\"message\":{\"role\":\"user\",\"content\":\"$p\"}}"
        puts $fh "{\"type\":\"assistant\",\"timestamp\":\"${ts}:0${t}Z\",\"message\":{\"model\":\"claude-3-5-sonnet-20241022\",\"usage\":{\"input_tokens\":100,\"output_tokens\":50}}}"
        incr t
    }
    close $fh
}

# Two real cwds (move_session refuses a destination that is not a real dir), and
# the encoded project folders that hold their sessions.
set CWDA [file join $SAND work proj-a]
set CWDB [file join $SAND work proj-b]
::questlog::path::_real_file mkdir $CWDA
::questlog::path::_real_file mkdir $CWDB
set FA [::questlog::path::encode_cwd $CWDA]
set FB [::questlog::path::encode_cwd $CWDB]
set PROOT [file join $SAND .claude projects]
set a1 [file join $PROOT $FA aaaa.jsonl]
set a2 [file join $PROOT $FA bbbb.jsonl]
set b1 [file join $PROOT $FB cccc.jsonl]
write_session $a1 {a1-one a1-two}     "2026-05-24T17:00"
write_session $a2 {a2-one a2-two a2-three} "2026-05-23T12:00"
write_session $b1 {b1-one b1-two}     "2026-05-22T09:00"
file mtime $a1 [clock scan "2026-05-24 17:01:00" -gmt 1]
file mtime $a2 [clock scan "2026-05-23 12:01:00" -gmt 1]
file mtime $b1 [clock scan "2026-05-22 09:01:00" -gmt 1]

set SL ""
set ::Scan [::questlog::Scan new [list apply {{r} { $::SL on_scan_row $r }}] noop]
proc scanpath {path} { return [$::Scan scan_path $path] }
proc resolvef {f}    { return "/tmp/proj" }
proc subagentsf {path} { return [$::Scan subagents_for $path] }

set SL [::questlog::ui::SessionList new .s resolvef noop noop noop noop noop \
            noop scanpath noop subagentsf noop]
pack .s -fill both -expand 1

# app::move_one reaches its collaborators through namespace variables; wire the
# live objects in so the real move path runs unchanged (guard included).
namespace eval ::questlog::ui::app {
    variable SessionList $::SL
    variable Running     [dict create]
}

set fails 0
proc check {name got want} {
    if {$got eq $want} { puts "ok   - $name" } else {
        puts "FAIL - $name"; puts "       got:  $got"; puts "       want: $want"; incr ::fails
    }
}
# How many store nodes carry a given path as their key, over the whole store -
# the direct count of the duplicate the OnRow re-emission used to create.
proc nodes_for {path} {
    global SL
    set ns [info object namespace $SL]
    set n 0
    foreach id [$SL all_node_ids] {
        if {[$SL node_field $id key] eq $path} { incr n }
    }
    return $n
}

# --- Stream the three sessions in: two under A, one under B.
$SL apply_filter [dict create since all]
set ::scan_done 0
$::Scan extend [dict create since all]
after 300 [list set ::scan_done 1]
vwait ::scan_done
update
proc ftot {f k} { global SL; return [dict get [$SL node_aggregate [$SL fid $f]] $k] }
check "A holds two sessions" [ftot $FA count] 2
check "B holds one session"  [ftot $FB count] 1
check "store clean before any move" [$SL audit] {}

# A cost lands on the session about to move, so the derived totals cover
# cost as well as count and size.
$SL refresh_cost $a2 [dict create cost_usd 2.50 turns 4 duration_secs 40 \
    human_secs 12 model "claude-3-5-sonnet-20241022"]
update
set szMoved  [$SL sget $a2 size]
# The move renames the file, preserving mtime, so a later rescan is skipped and
# any field carried unchanged would be stale forever. Stage two disk facts that
# differ from what the move leaves in place - a +x bookmark bit the store does
# not know, and the source folder's cwd, which is not the destination's - so the
# move must re-read bookmarked from disk and re-stamp folder_cwd for the new
# residence rather than carry either across unchanged.
::questlog::path::_real_file attributes $a2 -permissions u+x
check "store's bookmarked is stale before the move" [$SL sget $a2 bookmarked] 0
check "store's folder_cwd is the source folder's before the move" \
    [$SL sget $a2 folder_cwd] $CWDA
set aSize0   [ftot $FA size]
set bSize0   [ftot $FB size]
set aCost0   [ftot $FA cost]
set bCost0   [ftot $FB cost]
check "the moving session's cost sits in A" [expr {abs($aCost0 - 2.50) < 1e-6}] 1

# --- Move a2 from A to B through the real GUI path.
set a2_new [file join $PROOT $FB bbbb.jsonl]
::questlog::ui::app::move_one $a2 $CWDB
update
check "moved path has exactly one node" [nodes_for $a2_new] 1
check "old path is gone from the store"  [$SL has_session $a2] 0
check "moved path is registered"         [$SL has_session $a2_new] 1
check "A count down to one"              [ftot $FA count] 1
check "B count up to two"                [ftot $FB count] 2
check "A size lost the moved session"    [ftot $FA size] [expr {$aSize0 - $szMoved}]
check "B size gained the moved session"  [ftot $FB size] [expr {$bSize0 + $szMoved}]
check "A cost lost the moved session"    [expr {abs([ftot $FA cost] - ($aCost0 - 2.50)) < 1e-6}] 1
check "B cost gained the moved session"  [expr {abs([ftot $FB cost] - ($bCost0 + 2.50)) < 1e-6}] 1
check "no path is painted twice"         [$SL audit] {}
check "bookmarked re-read from disk on move" [$SL sget $a2_new bookmarked] 1
check "folder_cwd re-stamped for the new residence" [$SL sget $a2_new folder_cwd] $CWDB

# --- Move the last remaining session out of A: the emptied folder is dropped
#     whole, the way forget_session drops one.
::questlog::ui::app::move_one $a1 $CWDB
update
check "A is dropped once it is empty"    [$SL has_folder $FA] 0
check "B now holds all three"            [ftot $FB count] 3
check "store clean after A empties"      [$SL audit] {}

# --- move_one into the folder a session already lives in is a silent no-op:
#     nothing relocates, and the store is untouched.
set bCountBefore [ftot $FB count]
::questlog::ui::app::move_one $b1 $CWDB
update
check "no-op leaves the session in place" [$SL has_session $b1] 1
check "no-op changes no count"            [ftot $FB count] $bCountBefore
check "no-op leaves the store clean"      [$SL audit] {}

# --- A session with a subagent sidecar dir: the move must carry the <uuid>/
#     directory with the jsonl (else its children orphan on disk and vanish on
#     rescan), re-key the child node, and keep the folded-up child cost. The
#     destination folder is unlisted before the move, so it also exercises the
#     single-creator label (an empty "(N)" heading is the bug this closes).
set CWDC [file join $SAND work proj-c]
set CWDD [file join $SAND work proj-d]
::questlog::path::_real_file mkdir $CWDC
::questlog::path::_real_file mkdir $CWDD
set FC [::questlog::path::encode_cwd $CWDC]
set FD [::questlog::path::encode_cwd $CWDD]
set pp [file join $PROOT $FC pppp.jsonl]
write_session $pp {p-one p-two} "2026-05-21T08:00"
file mtime $pp [clock scan "2026-05-21 08:01:00" -gmt 1]
set side_c [file join $PROOT $FC pppp subagents]
::questlog::path::_real_file mkdir $side_c
set child_old [file join $side_c agent-1.jsonl]
write_session $child_old {s-one} "2026-05-21T08:02"
$SL on_scan_row [scanpath $pp]
update
check "parent has_subagents modelled"        [$SL sget $pp has_subagents] 1
check "child modelled at its source path"     [$SL has_session $child_old] 1
# Give the child a cost so the fold-up has something to carry across the move.
$SL refresh_cost $child_old [dict create cost_usd 0.75 turns 1 duration_secs 5 \
    human_secs 2 model "claude-3-5-sonnet-20241022"]
update
set pcost0 [$SL sget $pp cost]
check "child cost folded into the parent before the move" [expr {$pcost0 >= 0.75}] 1

::questlog::ui::app::move_one $pp $CWDD
update
set pp_new    [file join $PROOT $FD pppp.jsonl]
set child_new [file join $PROOT $FD pppp subagents agent-1.jsonl]
check "the subagent sidecar dir followed on disk"  [file isfile $child_new] 1
check "the source sidecar dir is gone"             [file isdirectory [file join $PROOT $FC pppp]] 0
check "the child node re-keyed to the new path"    [$SL has_session $child_new] 1
check "the child node left the old path"           [$SL has_session $child_old] 0
check "the folded-up child cost survived the move" \
    [expr {abs([$SL sget $pp_new cost] - $pcost0) < 1e-6}] 1
check "new destination folder carries a real label, not empty" \
    [expr {[$SL folder_label [$SL fid $FD]] ne ""}] 1
check "audit clean after a subagent move" [$SL audit] {}

# --- A pinned session survives a move: the pin is keyed by the stable sid, which
#     the re-parent keeps, so it is not dropped on the next reconcile tick.
set qq [file join $PROOT $FD qqqq.jsonl]
write_session $qq {q-one} "2026-05-20T07:00"
file mtime $qq [clock scan "2026-05-20 07:01:00" -gmt 1]
$SL on_scan_row [scanpath $qq]
update
set NS [info object namespace $SL]
namespace eval $NS [list dict set Pinned [$SL sid $qq] 1]
::questlog::ui::app::move_one $qq $CWDC
update
set qq_new [file join $PROOT $FC qqqq.jsonl]
check "pinned session followed the move" [$SL has_session $qq_new] 1
check "the pin followed to the moved node" \
    [dict exists [set ${NS}::Pinned] [$SL sid $qq_new]] 1
check "audit clean after a pinned move" [$SL audit] {}

# --- Two dirs whose encoded basenames collide (encode_cwd folds every
#     non-alphanumeric to '-', so work/coll-x and work/coll/x share one encoded
#     name and one on-disk folder). The old no-op check compared encoded
#     basenames and silently swallowed a real move between them; the move must
#     relocate - same file path, folder_cwd re-stamped to the destination -
#     while a move to the cwd the session already carries stays a no-op.
set CWDE [file join $SAND work coll-x]
set CWDF [file join $SAND work coll x]
::questlog::path::_real_file mkdir $CWDE
::questlog::path::_real_file mkdir $CWDF
set FE [::questlog::path::encode_cwd $CWDE]
check "the two cwds collide in one encoded basename" \
    [::questlog::path::encode_cwd $CWDF] $FE
set rr [file join $PROOT $FE rrrr.jsonl]
write_session $rr {r-one r-two} "2026-05-19T06:00"
file mtime $rr [clock scan "2026-05-19 06:01:00" -gmt 1]
$SL on_scan_row [scanpath $rr]
update
# The resolver cannot pick between colliding candidates; the premise is a
# session belonging to coll-x, so stamp its residence outright.
$SL sset $rr folder_cwd $CWDE
::questlog::ui::app::move_one $rr $CWDF
update
check "colliding move is not swallowed: folder_cwd re-stamped" \
    [$SL sget $rr folder_cwd] $CWDF
check "colliding move keeps the file in the shared folder" [file isfile $rr] 1
check "colliding move keeps one node" [nodes_for $rr] 1
check "audit clean after the colliding move" [$SL audit] {}
# Same cwd again: now a true no-op, judged on the cwd rather than the basename.
set ::relocs 0
oo::objdefine $SL method relocate_card {args} { incr ::relocs; next {*}$args }
::questlog::ui::app::move_one $rr $CWDF
update
check "same-cwd move in the colliding folder is a no-op" $::relocs 0

::questlog::path::_real_file delete -force $SAND
puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
