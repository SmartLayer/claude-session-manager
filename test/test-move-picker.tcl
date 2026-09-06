#!/usr/bin/env wish9.0
# The move picker lists the session list's folders as the list shows them:
# the tree's order, each labelled as its heading is and stepped in to its
# depth. The source folder is left out and the folders beneath it kept, since
# a session can move down into its own project; a folder with no directory to
# move into (gone) is left out. With no single source (a group move) every
# folder is offered.
#
# The corpus, under a sandbox $HOME (every name fictional):
#   ~/proj/forge            a session; the root
#   ~/proj/forge/bellows    nested, a session
#   ~/proj/forge/slag       nested, a session, the directory gone
#   ~/proj/anvil            an unrelated root

package require Tcl 9
package require Tk

set SAND [file join [pwd] _movepicker_sandbox]

set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add [file join $ROOT modules]
::tcl::tm::path add [file join $ROOT vendor]
package require leash
package require streamtree
set ::questlog_config_only 1; source [file join $ROOT questlog]
foreach f {lib/cost.tcl ui/theme.tcl lib/path.tcl lib/listfilter.tcl \
           lib/match.tcl ui/terminal.tcl ui/live.tcl lib/scan.tcl lib/search.tcl \
           ui/drag.tcl ui/toolbar.tcl ui/reveal.tcl ui/sessions.tcl ui/move_dialog.tcl} {
    source [file join $ROOT $f]
}
::questlog::ui::theme::init

::questlog::path::_real_file delete -force $SAND
set ::env(HOME) $SAND
unset -nocomplain ::env(CLAUDE_CONFIG_DIR)

proc noop {args} {}

proc write_session {cwd name ago {mkdir 1}} {
    if {$mkdir} { ::questlog::path::_real_file mkdir $cwd }
    set folder [::questlog::path::encode_cwd $cwd]
    set dir [file join $::SAND .claude projects $folder]
    ::questlog::path::_real_file mkdir $dir
    set path [file join $dir $name.jsonl]
    set secs [expr {[clock seconds] - $ago * 86400}]
    set ts [clock format $secs -format "%Y-%m-%dT%H:%M" -gmt 1]
    set fh [open $path w]
    puts $fh "{\"type\":\"user\",\"cwd\":\"$cwd\",\"timestamp\":\"${ts}:00Z\",\"message\":{\"role\":\"user\",\"content\":\"hello from $name\"}}"
    puts $fh "{\"type\":\"assistant\",\"timestamp\":\"${ts}:01Z\",\"message\":{\"model\":\"claude-3-5-sonnet-20241022\",\"usage\":{\"input_tokens\":100,\"output_tokens\":50}}}"
    close $fh
    file mtime $path $secs
    return $path
}

set FORGE   [file join $SAND proj forge]
set BELLOWS [file join $FORGE bellows]
set SLAG    [file join $FORGE slag]
set ANVIL   [file join $SAND proj anvil]
write_session $FORGE   forge-1   1
write_session $BELLOWS bellows-1 2
write_session $SLAG    slag-1    3 0
write_session $ANVIL   anvil-1   4
foreach v {FORGE BELLOWS SLAG ANVIL} { set F_$v [::questlog::path::encode_cwd [set $v]] }

set SL ""
set ::Scan [::questlog::Scan new [list apply {{r} { $::SL on_scan_row $r }}] noop {} {} {} 0]
proc scanpath {path}   { return [$::Scan scan_path $path] }
proc resolvef {f}      { return [$::Scan folder_cwd $f] }
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
# The picker's rows, top to bottom, as the reader sees them, and the
# directory each stands for.
proc picker_rows {} {
    set tv $::questlog::ui::move_dialog::Tv
    return [lmap iid [$tv children {}] { $tv item $iid -text }]
}
proc picker_dirs {} {
    set tv $::questlog::ui::move_dialog::Tv
    return [lmap iid [$tv children {}] { dict get $::questlog::ui::move_dialog::RowToCwd $iid }]
}

$SL apply_filter [dict create since 30d]
set ::scan_done 0
$::Scan extend [dict create since 30d]
after 400 [list set ::scan_done 1]
vwait ::scan_done
update

# ---- the roster: the tree's folders, parents first, with label and depth ----
set roster [$SL folder_roster]
check "the roster walks the tree parents first" \
    [lmap f $roster { dict get $f key }] [list $F_FORGE $F_BELLOWS $F_SLAG $F_ANVIL]
check "each folder carries its heading's label and its depth" \
    [lmap f $roster { list [dict get $f label] [dict get $f depth] }] \
    [list {~/proj/forge 0} {bellows 1} {slag 1} {~/proj/anvil 0}]

# ---- one session moving out of the root ------------------------------------
::questlog::ui::move_dialog::open . 1 $F_FORGE $roster noop ""
update
check "the source folder is left out, its descendants kept, the gone one skipped, stepped in by depth" \
    [picker_rows] [list "    bellows" "~/proj/anvil"]
check "each row stands for its folder's directory" [picker_dirs] [list $BELLOWS $ANVIL]
::questlog::ui::move_dialog::cancel
update

# ---- a group move names no source, so every living folder is offered ---------
::questlog::ui::move_dialog::open . 2 "" $roster noop ""
update
check "with no single source every living folder is offered" \
    [picker_rows] [list "~/proj/forge" "    bellows" "~/proj/anvil"]
::questlog::ui::move_dialog::cancel
update

::questlog::path::_real_file delete -force $SAND
puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
