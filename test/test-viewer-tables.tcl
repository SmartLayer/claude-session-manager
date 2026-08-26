#!/usr/bin/env wish9.0
# GFM tables render as embedded grid widgets whose cells word-wrap.
#
# Tab-aligned table lines clipped wide cells at the pane edge; each table is
# now one embedded window holding a frame of per-cell text widgets. This
# drives a real Viewer over a two-table synthetic session and asserts the
# contract around the widget route: cells wrap and the grid fits the pane,
# search still finds table content (band and Ctrl-F) through the recorded
# payload, a jump spotlights the whole table, the table ⧉ copies the table
# as round-tripping markdown, the message copy still yields the raw body,
# and a reload leaves no orphaned table widgets.
#
# Runs under wish (it builds a Viewer, so it needs Tk); run-audit routes it to
# wish9.0 on the private Xvfb. Standalone: DISPLAY=:95 wish9.0 test-viewer-tables.tcl

package require Tcl 9
package require Tk

set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add [file join $ROOT modules]
::tcl::tm::path add [file join $ROOT vendor]
package require leash
package require streamtree
# Mirror the launcher's GUI source order for the subset the Viewer needs: config
# and the Tk-free libs it reads, the theme (named fonts + palette), then the
# class itself.
set ::questlog_config_only 1; source [file join $ROOT questlog]
foreach f {lib/debug.tcl lib/path.tcl lib/match.tcl \
           lib/cost.tcl ui/theme.tcl ui/reveal.tcl ui/viewer.tcl} {
    source [file join $ROOT $f]
}
::questlog::ui::theme::init

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

# ---- pure procs ---------------------------------------------------------------

check "colwidths: naturals kept when they fit" \
    [::questlog::ui::table_colwidths {100 200 300} 1000 50] {100 200 300}
check "colwidths: proportional shrink above the floor" \
    [::questlog::ui::table_colwidths {100 400 500} 500 120] {100 177 222}
check "colwidths: a floor-width column is never squeezed" \
    [::questlog::ui::table_colwidths {10 990} 200 100] {10 190}
check "colwidths: shrink clamps at the floor" \
    [::questlog::ui::table_colwidths {200 800} 300 150] {150 240}

set md [::questlog::ui::table_to_markdown \
    [dict create align {left center right} rows {{a b c} {d {e | f} g}}]]
check "to_markdown: delimiter row from align, cells re-escaped" $md \
    "| a | b | c |\n| --- | :---: | ---: |\n| d | e \\| f | g |"

# ---- synthetic session: two tables in one assistant turn -----------------------
set tmpbase [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}]
set TMP [file join $tmpbase ql-table-test-[pid]]
# lib/path.tcl wraps `file` to refuse callers outside ::questlog::path::*; reach
# the unwrapped command for the sandbox dir under /tmp, as the other UI tests do.
::questlog::path::_real_file mkdir $TMP
set JP [file join $TMP session.jsonl]
set fh [open $JP w]
fconfigure $fh -encoding utf-8
# Table one: three columns with mixed alignment, a **bold** header span, the
# search token in a body cell, and an escaped \| whose round trip the copy
# test asserts. Table two: a cell long enough that it must wrap once its
# column shrinks to the pane. PLAINWORD sits in ordinary prose so a jump can
# land off-table and clear the spotlight.
puts $fh {{"type":"user","cwd":"/tmp/proj","timestamp":"2026-07-12T09:00:00Z","message":{"role":"user","content":"show me tables PLAINWORD"}}}
puts $fh {{"type":"assistant","timestamp":"2026-07-12T09:00:05Z","message":{"role":"assistant","model":"claude-3-5-sonnet-20241022","content":"Intro line.\n\n| Name | **Qty** | Price |\n| :--- | :---: | ---: |\n| alpha | TBLTOKEN mid | 9 |\n| pipe a \\| b | x | 1 |\n\nBetween tables.\n\n| Dimension | Detail |\n| --- | --- |\n| horizon | this is a very long sentence that must wrap across several display lines because its natural width is far beyond what a small reading pane can give one column |\n\nAfter text.","usage":{"input_tokens":10,"output_tokens":5}}}}
puts $fh {{"type":"user","cwd":"/tmp/proj","timestamp":"2026-07-12T09:00:09Z","message":{"role":"user","content":"thanks"}}}
close $fh

# ---- build a real Viewer and show the session ----------------------------------
set V [::questlog::ui::Viewer new .v]
pack .v -fill both -expand 1
$V show $JP 0 [dict create terms {TBLTOKEN} nocase 0]
update idletasks
update

set Text [$V textwidget]
set NS [info object namespace $V]

# 1. Two tables emitted: registry, window segments, marks.
check "two tables registered" [llength [dict keys [set ${NS}::Tables]]] 2
check "two tblwin segments" [llength [$Text tag ranges tblwin]] 4
check "table marks stand" \
    [expr {[lsearch [$Text mark names] tbl#m1] >= 0 && [lsearch [$Text mark names] tbl#m2] >= 0}] 1

# 2. Realization and fit: bring each table into view, let the two idle fit
#    stages run, then read the geometry.
foreach id {1 2} {
    $Text see tbl#m$id
    update idletasks
    update
}
set F1 [dict get [set ${NS}::Tables] 1 frame]
set F2 [dict get [set ${NS}::Tables] 2 frame]
check "table 1 realized" [winfo exists $F1] 1
check "table 2 realized" [winfo exists $F2] 1
check "table 2 fits the pane" \
    [expr {[winfo reqwidth $F2] <= [winfo width $Text]}] 1

# 3. The long cell wraps: more than one display line, and -height tracks it.
set LONG ""
foreach c [dict get [set ${NS}::Tables] 2 cells] {
    if {[string first "very long sentence" [$c get 1.0 "end -1c"]] >= 0} { set LONG $c }
}
check "long cell found" [expr {$LONG ne ""}] 1
set dl [$LONG count -update -displaylines 1.0 end]
check "long cell wraps" [expr {$dl > 1}] 1
check "long cell height tracks its wrap" [$LONG cget -height] $dl

# 4. The opening search found the table-only token: its match record is the
#    table's mark and its band excerpt reads from the cell, not the widget.
check "band search finds the table token" \
    [expr {[lsearch [set ${NS}::FindMatches] tbl#m1] >= 0}] 1
set mi [lsearch [set ${NS}::FindMatches] tbl#m1]
check "band excerpt is the cell text" \
    [expr {[string first "TBLTOKEN" [lindex [set ${NS}::MatchLabels] $mi]] >= 0}] 1

# 5. Jumping to the table match spotlights the whole table; a jump to a plain
#    index clears it.
set FIND  [::questlog::ui::theme::c find]
set FAINT [::questlog::ui::theme::c faint]
$V jump_to_match $mi
update idletasks
update
check "jump lights the table" [$F1 cget -background] $FIND
$V reveal_index 1.0
check "off-table jump clears the spotlight" [$F1 cget -background] $FAINT

# 6. Ctrl-F reaches table content: the token exists only in the payload, and
#    find_next lands on it (re-lighting the table).
set ${NS}::FindVar "tbltoken"
$V find_next
update idletasks
check "Ctrl-F finds the table-only token" \
    [expr {[lsearch [set ${NS}::FindMatches] tbl#m1] >= 0}] 1
check "Ctrl-F jump lights the table" [$F1 cget -background] $FIND

# 7. The table ⧉ copies markdown that round-trips to the same payload,
#    escaped pipe included.
clipboard clear
clipboard append "sentinel-before"
$V table_copy 1
set segs [::tkdown::segment_tables [clipboard get]]
check "copied markdown is one table" \
    [list [llength $segs] [lindex $segs 0 0]] {1 table}
check "copy round-trips the payload" \
    [lindex $segs 0 1] [dict get [set ${NS}::Tables] 1 payload]

# 8. The message copy still yields the raw markdown body, pipes intact.
set ${NS}::MenuTarget [dict create line 2]
$V menu_copy_message
check "message copy keeps the raw table source" \
    [expr {[string first "| Name | **Qty** | Price |" [clipboard get]] >= 0}] 1

# 9. Reload: the previous document's table widgets are destroyed, the registry
#    refills to the same two tables, nothing accumulates.
$V show $JP 0 {}
update idletasks
update
check "registry does not accumulate across reload" \
    [llength [dict keys [set ${NS}::Tables]]] 2
check "tblwin segments do not accumulate" [llength [$Text tag ranges tblwin]] 4
set stale 0
foreach w [winfo children $Text] {
    if {[string match *.tbl* $w] && ![dict exists [set ${NS}::Tables] \
        [string range [file extension $w] 4 end]]} { incr stale }
}
check "no orphaned table frames" $stale 0

# ---- clean up ------------------------------------------------------------------
::questlog::path::_real_file delete -force $TMP
puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
