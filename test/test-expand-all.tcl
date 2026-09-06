#!/usr/bin/env wish9.0
# The expand-all button: one press opens every folder at every depth, in one
# anchored batch, and a second press is a no-op. The button lives flush left
# in the list-view strip and drives SessionList expand_all_folders; a folder
# already open is skipped, a folder closed by hand re-opens on the next press,
# and a nested folder's marker turns with its body.
#
# The corpus, under a sandbox $HOME (every name fictional): ~/proj/kiln with
# two sessions, ~/proj/kiln/glaze nested beneath it with one, and ~/proj/anvil
# apart with one. The kiln root opens on arrival (the opening view); glaze and
# anvil arrive shut.

package require Tcl 9
package require Tk

set SAND [file join [pwd] _expall_sandbox]
set ::env(STREAMTREE_AUDIT) 1

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
    set ts [clock format $secs -format "%Y-%m-%dT%H:%M" -gmt 1]
    set fh [open $path w]
    puts $fh "{\"type\":\"user\",\"cwd\":\"$cwd\",\"timestamp\":\"${ts}:00Z\",\"message\":{\"role\":\"user\",\"content\":\"hello from $name\"}}"
    puts $fh "{\"type\":\"assistant\",\"timestamp\":\"${ts}:01Z\",\"message\":{\"model\":\"claude-3-5-sonnet-20241022\",\"usage\":{\"input_tokens\":100,\"output_tokens\":50}}}"
    close $fh
    file mtime $path $secs
    return $path
}

set KILN  [file join $SAND proj kiln]
set GLAZE [file join $KILN glaze]
set ANVIL [file join $SAND proj anvil]
set Ap [write_session $KILN  aaaa 1]
set Bp [write_session $KILN  bbbb 2]
set Dp [write_session $GLAZE dddd 3]
set Cp [write_session $ANVIL cccc 4]
set F_KILN  [::questlog::path::encode_cwd $KILN]
set F_GLAZE [::questlog::path::encode_cwd $GLAZE]
set F_ANVIL [::questlog::path::encode_cwd $ANVIL]

set SL ""
set ::Scan [::questlog::Scan new [list apply {{r} { $::SL on_scan_row $r }}] noop {} {} {} 0]
proc scanpath {path}   { return [$::Scan scan_path $path] }
proc resolvef {f}      { return [$::Scan folder_cwd $f] }
proc subagentsf {path} { return [$::Scan subagents_for $path] }
proc subagent_cost_cb {path} {}

set SL [::questlog::ui::SessionList new .s resolvef noop noop noop noop noop \
            noop scanpath noop subagentsf subagent_cost_cb]
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
proc marker {f} {
    set m [$::SL node_field [$::SL fid $f] start]
    return [string index [string trim [$::TX get "$m linestart" "$m lineend"]] 0]
}

# --- 1. Stream all rows in: the first root opens, the rest arrive shut.
$SL apply_filter [dict create since all]
set ::scan_done 0
$::Scan extend [dict create since all]
after 200 [list set ::scan_done 1]
vwait ::scan_done
update

check "button in the strip" [winfo exists .s.lvt.expandall] 1
check "A rendered before, under the open first root" [$SL sflag $Ap rendered] 1
check "D unrendered before, in the shut nested folder" [$SL sflag $Dp rendered] 0
check "C unrendered before, in the shut second root" [$SL sflag $Cp rendered] 0
check "the nested folder's marker reads shut" [marker $F_GLAZE] "▸"

# --- 2. One press opens every folder at every depth.
.s.lvt.expandall invoke
update
foreach {p name} [list $Ap A $Bp B $Dp D $Cp C] {
    check "$name rendered after expand-all" [$SL sflag $p rendered] 1
}
foreach f [list $F_KILN $F_GLAZE $F_ANVIL] {
    check "$f expanded" [$SL node_field [$SL fid $f] expanded] 1
}
check "the nested folder's marker turned with its body" [marker $F_GLAZE] "▾"

# --- 3. A second press is a no-op (every folder already open): nothing is
#        drawn twice, so the row count holds.
set lines [$TX count -lines 1.0 end]
.s.lvt.expandall invoke
update
check "the row count holds" [$TX count -lines 1.0 end] $lines
check "D still rendered" [$SL sflag $Dp rendered] 1
check "C still rendered" [$SL sflag $Cp rendered] 1

# --- 4. A folder closed by hand re-opens on the next press; the open ones
#        are left alone. A nested folder shut by hand, and one shut away
#        behind its parent, alike.
$SL toggle_folder $F_GLAZE
update
check "D unrendered after the nested folder's manual collapse" [$SL sflag $Dp rendered] 0
.s.lvt.expandall invoke
update
check "D re-rendered" [$SL sflag $Dp rendered] 1
check "C untouched"   [$SL sflag $Cp rendered] 1
$SL toggle_folder $F_KILN
update
check "shutting the root takes the nested folder off the view" \
    [$SL folder_attached $F_GLAZE] 0
.s.lvt.expandall invoke
update
check "the press reopens the root and draws the nested folder open" \
    [list [$SL sflag $Ap rendered] [$SL sflag $Dp rendered]] {1 1}

check "no audit trip" [info exists ::STREAMTREE_AUDIT_TRIPPED] 0

::questlog::path::_real_file delete -force $SAND
puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
