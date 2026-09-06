#!/usr/bin/env wish9.0
# The move picker lists the session list's folders as the tree the list
# shows: each under its parent's item, labelled as its heading is, every
# branch open. The source folder is left out and the folders beneath it kept,
# since a session can move down into its own project; a folder with no
# directory to move into (gone) is left out. With no single source (a group
# move) every folder is offered. Beneath the roots, flat, sit the projects on
# disk the list is not showing (outside its since bound), labelled by their
#
# The corpus, under a sandbox $HOME (every name fictional):
#   ~/proj/forge            a session; the root
#   ~/proj/forge/bellows    nested, a session
#   ~/proj/forge/slag       nested, a session, the directory gone
#   ~/proj/anvil            an unrelated root
#   ~/proj/quench           a session outside the since bound, so no row
#   ~/proj/cinder           the same, its directory gone: the walk-only
#                           resolver cannot place it, so the roster leaves it out

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
set QUENCH  [file join $SAND proj quench]
set CINDER  [file join $SAND proj cinder]
write_session $FORGE   forge-1   1
write_session $BELLOWS bellows-1 2
write_session $SLAG    slag-1    3 0
write_session $ANVIL   anvil-1   4
write_session $QUENCH  quench-1  60
write_session $CINDER  cinder-1  60 0
foreach v {FORGE BELLOWS SLAG ANVIL QUENCH CINDER} { set F_$v [::questlog::path::encode_cwd [set $v]] }

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
# The picker's items top to bottom as the reader sees them, each label led
# by one ">" per level of nesting, and the directory each stands for.
proc picker_items {{parent {}} {depth 0}} {
    set tv $::questlog::ui::move_dialog::Tv
    set out [list]
    foreach iid [$tv children $parent] {
        lappend out [list "[string repeat > $depth][$tv item $iid -text]" \
                          [lindex [$tv item $iid -values] 0] [$tv item $iid -open]]
        lappend out {*}[picker_items $iid [expr {$depth + 1}]]
    }
    return $out
}
proc picker_rows {} { return [lmap it [picker_items] { lindex $it 0 }] }
proc picker_dirs {} { return [lmap it [picker_items] { lindex $it 1 }] }
proc picker_open {} { return [lmap it [picker_items] { lindex $it 2 }] }

$SL apply_filter [dict create since 30d]
set ::scan_done 0
$::Scan extend [dict create since 30d]
after 400 [list set ::scan_done 1]
vwait ::scan_done
update

# ---- the roster: the tree's folders, parents first, with label and depth ----
set roster [$SL folder_roster]
check "the roster walks the tree parents first, then the projects the list is not showing" \
    [lmap f $roster { dict get $f key }] \
    [list $F_FORGE $F_BELLOWS $F_SLAG $F_ANVIL $F_QUENCH]
check "each folder carries its heading's label and names its parent; a project outside the tree its path, at the root" \
    [lmap f $roster { list [dict get $f label] [dict get $f parent] }] \
    [list {~/proj/forge {}} [list bellows $F_FORGE] [list slag $F_FORGE] {~/proj/anvil {}} {~/proj/quench {}}]

# ---- one session moving out of the root ------------------------------------
::questlog::ui::move_dialog::open . 1 $F_FORGE $roster noop ""
update
check "the source folder is left out, its descendants hung above, the gone ones skipped, the unshown project beneath" \
    [picker_rows] [list "bellows" "~/proj/anvil" "~/proj/quench"]
check "each item stands for its folder's directory" [picker_dirs] [list $BELLOWS $ANVIL $QUENCH]
::questlog::ui::move_dialog::cancel
update

# ---- a group move names no source, so every living folder is offered ---------
::questlog::ui::move_dialog::open . 2 "" $roster noop ""
update
check "with no single source every living folder is offered, nested under its parent" \
    [picker_rows] [list "~/proj/forge" ">bellows" "~/proj/anvil" "~/proj/quench"]
check "every branch is open" [picker_open] {1 1 1 1}
::questlog::ui::move_dialog::cancel
update

::questlog::path::_real_file delete -force $SAND
puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
