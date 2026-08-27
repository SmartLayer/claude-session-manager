#!/usr/bin/env wish9.0
# The arrow keys walk the session list.
#
# The rows are drawn by the base class, which moves a cursor over them and says
# so; what the app does with a move is highlight the row, the same one-of
# selection a plain click makes. A move opens nothing - Return, already bound to
# open_selected, is what reads a session - so walking a long list costs no
# transcript renders.

package require Tcl 9
package require Tk

set SAND [file join [pwd] _listkeys_sandbox]
set FA "-tmp-listkeys"

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
::questlog::path::_real_file mkdir $DIRA
set ::env(HOME) $SAND
unset -nocomplain ::env(CLAUDE_CONFIG_DIR)

proc noop {args} {}

# Three sessions a day apart, so their order in the list is known.
set paths [list]
for {set i 0} {$i < 3} {incr i} {
    set p [file join $DIRA [format "s%02d.jsonl" $i]]
    set when [expr {[clock seconds] - ($i + 1) * 24 * 3600}]
    set ts [clock format $when -format "%Y-%m-%dT%H:%M:%S" -gmt 1]
    set fh [open $p w]
    fconfigure $fh -encoding utf-8
    puts $fh [string map [list @TS@ $ts] {{"type":"user","promptSource":"typed","cwd":"/tmp/proj","timestamp":"@TS@Z","message":{"role":"user","content":"a prompt"}}}]
    puts $fh [string map [list @TS@ $ts] {{"type":"assistant","timestamp":"@TS@Z","message":{"role":"assistant","model":"claude-x","content":[{"type":"text","text":"a reply"}],"usage":{"input_tokens":5,"output_tokens":5}}}}]
    close $fh
    file mtime $p $when
    lappend paths $p
}

set SL ""
set ::Scan [::questlog::Scan new [list apply {{r} { $::SL on_scan_row $r }}] noop]
proc scanpath {path} { return [$::Scan scan_path $path] }
proc resolvef {f}    { return "/tmp/proj" }
proc subagentsf {path} { return [$::Scan subagents_for $path] }

# The open callback is the witness that a move never reads a session.
set ::opened [list]
proc record_open {path args} { lappend ::opened $path }

set SL [::questlog::ui::SessionList new .s resolvef record_open noop noop noop \
            noop noop scanpath noop subagentsf noop noop noop]
pack .s -fill both -expand 1
set TX .s.body.t

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
proc press {key} {
    focus -force $::TX
    update
    event generate $::TX $key
    update
}
proc selected {} { return [$::SL selection_paths] }

$SL apply_filter [dict create since 30d]
set ::scan_done 0
$::Scan extend [dict create since 30d]
after 300 [list set ::scan_done 1]
vwait ::scan_done
update
check "the folder heading is drawn" [expr {[$SL has_folder $FA] ? 1 : 0}] 1

# --- The folder is shut, so the walk sees the heading alone.
press <Key-Down>
check "the first Down lands on the folder heading" [$SL is_folder_selected $FA] 1
press <Key-Down>
check "a shut folder's sessions are not on the walk" [$SL is_folder_selected $FA] 1

# --- Right opens the folder; the walk then steps through its sessions in the
#     order they are drawn.
press <Key-Right>
check "Right opened the folder" [expr {[$SL sflag [lindex $paths 0] rendered] ? 1 : 0}] 1
press <Key-Down>
check "Down selects the first session" [selected] [lindex $paths 0]
press <Key-Down>
check "Down steps to the next" [selected] [lindex $paths 1]
press <Key-Up>
check "Up steps back" [selected] [lindex $paths 0]
check "the selection is one row, not a range" [$SL selection_count] 1

# --- End and Home reach the ends of the walk.
press <Key-End>
check "End reaches the last session" [selected] [lindex $paths 2]
press <Key-Home>
check "Home reaches the folder heading" [$SL is_folder_selected $FA] 1

# --- Nothing was read along the way, and the witness that says so is live:
#     Return, bound to open_selected, opens what the cursor reached.
check "no session was opened by a move" {} $::opened
press <Key-End>
$SL open_selected
check "Return opens the row the walk reached" $::opened [list [lindex $paths 2]]

# --- Left shuts the folder again, from its heading.
press <Key-Home>
press <Key-Left>
check "Left shut the folder" \
    [expr {[$SL sflag [lindex $paths 0] rendered] ? 1 : 0}] 0

::questlog::path::_real_file delete -force $SAND
puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
