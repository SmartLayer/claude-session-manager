#!/usr/bin/env wish9.0
# The arrow keys walk the session list.
#
# The rows are drawn by the base class, which moves a cursor over them and says
# so; what the app does with a move is highlight the row, the same one-of
# selection a plain click makes. A move opens nothing - Return, already bound to
# open_selected, is what reads a session - so walking a long list costs no
# transcript renders. The walk is over the drawn rows at every depth: a nested
# folder's heading is a row, its sessions are rows only while it is open, and
# Right and Left open and shut the folder under the cursor the way a click on
# its marker does, marker and all.
#
# The corpus, under a sandbox $HOME (every name fictional): ~/proj/loom with a
# session of its own, and ~/proj/loom/shuttle nested beneath it with two.

package require Tcl 9
package require Tk

set SAND [file join [pwd] _listkeys_sandbox]

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
set ::env(HOME) $SAND
unset -nocomplain ::env(CLAUDE_CONFIG_DIR)

proc noop {args} {}

# A session that ran in cwd, filed under the folder Claude Code names for it,
# mtime `ago` days back.
proc write_session {cwd name ago} {
    ::questlog::path::_real_file mkdir $cwd
    set folder [::questlog::path::encode_cwd $cwd]
    set dir [file join $::SAND .claude projects $folder]
    ::questlog::path::_real_file mkdir $dir
    set path [file join $dir $name.jsonl]
    set secs [expr {[clock seconds] - $ago * 86400}]
    set ts [clock format $secs -format "%Y-%m-%dT%H:%M:%S" -gmt 1]
    set fh [open $path w]
    fconfigure $fh -encoding utf-8
    puts $fh [string map [list @TS@ $ts @CWD@ $cwd] {{"type":"user","promptSource":"typed","cwd":"@CWD@","timestamp":"@TS@Z","message":{"role":"user","content":"a prompt"}}}]
    puts $fh [string map [list @TS@ $ts] {{"type":"assistant","timestamp":"@TS@Z","message":{"role":"assistant","model":"claude-x","content":[{"type":"text","text":"a reply"}],"usage":{"input_tokens":5,"output_tokens":5}}}}]
    close $fh
    file mtime $path $secs
    return $path
}

set LOOM    [file join $SAND proj loom]
set SHUTTLE [file join $LOOM shuttle]
set loom1    [write_session $LOOM    loom-1    1]
set shuttle1 [write_session $SHUTTLE shuttle-1 2]
set shuttle2 [write_session $SHUTTLE shuttle-2 3]
set F_LOOM    [::questlog::path::encode_cwd $LOOM]
set F_SHUTTLE [::questlog::path::encode_cwd $SHUTTLE]

set SL ""
set ::Scan [::questlog::Scan new [list apply {{r} { $::SL on_scan_row $r }}] noop {} {} {} 0]
proc scanpath {path}   { return [$::Scan scan_path $path] }
proc resolvef {f}      { return [$::Scan folder_cwd $f] }
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
proc rendered {p} { return [expr {[$::SL sflag $p rendered] ? 1 : 0}] }
proc marker {f} {
    set m [$::SL node_field [$::SL fid $f] start]
    return [string index [string trim [$::TX get "$m linestart" "$m lineend"]] 0]
}

$SL apply_filter [dict create since 30d]
set ::scan_done 0
$::Scan extend [dict create since 30d]
after 300 [list set ::scan_done 1]
vwait ::scan_done
update
check "the root opened on arrival, the nested folder shut inside it" \
    [list [$SL folder_expanded $F_LOOM] [$SL folder_expanded $F_SHUTTLE]] {1 0}

# --- Down walks the drawn rows: the root's heading, the nested heading, then
#     the root's own session; the shut folder's sessions are not on the walk.
press <Key-Down>
check "the first Down lands on the root heading" [$SL is_folder_selected $F_LOOM] 1
press <Key-Down>
check "the next lands on the nested folder's heading" [$SL is_folder_selected $F_SHUTTLE] 1
press <Key-Down>
check "a shut folder's sessions are not on the walk" [selected] $loom1
press <Key-Up>
check "Up steps back to the nested heading" [$SL is_folder_selected $F_SHUTTLE] 1

# --- Right opens the folder under the cursor, marker and all; the walk then
#     steps through its sessions in the order they are drawn.
press <Key-Right>
check "Right opened the nested folder" [rendered $shuttle1] 1
check "and turned its marker" [marker $F_SHUTTLE] "▾"
press <Key-Down>
check "Down selects its first session" [selected] $shuttle1
press <Key-Down>
check "Down steps to the next" [selected] $shuttle2
press <Key-Down>
check "and on past the folder to the root's own session" [selected] $loom1
press <Key-Up>
check "Up steps back" [selected] $shuttle2
check "the selection is one row, not a range" [$SL selection_count] 1

# --- End and Home reach the ends of the walk.
press <Key-End>
check "End reaches the last session" [selected] $loom1
press <Key-Home>
check "Home reaches the root heading" [$SL is_folder_selected $F_LOOM] 1

# --- Nothing was read along the way, and the witness that says so is live:
#     Return, bound to open_selected, opens what the cursor reached.
check "no session was opened by a move" {} $::opened
press <Key-End>
$SL open_selected
check "Return opens the row the walk reached" $::opened [list $loom1]

# --- Left shuts the folder under the cursor, from its heading, at any depth.
press <Key-Home>
press <Key-Down>
press <Key-Left>
check "Left shut the nested folder" [rendered $shuttle1] 0
check "and turned its marker back" [marker $F_SHUTTLE] "▸"
press <Key-Up>
press <Key-Left>
check "Left shut the root" [rendered $loom1] 0
check "with its marker" [marker $F_LOOM] "▸"
press <Key-Right>
check "Right reopens it with the nested folder still shut" \
    [list [rendered $loom1] [rendered $shuttle1]] {1 0}

::questlog::path::_real_file delete -force $SAND
puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
