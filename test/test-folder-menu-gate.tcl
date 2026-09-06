#!/usr/bin/env wish9.0
# The folder heading's right-click menu gates both entries on the resolved
# project cwd. "Search within this folder" bounds the search to that cwd, so a
# folder whose directory cannot be resolved ("" from the resolver) must grey
# it out like "Reveal folder" - the old gate checked only the callback's
# presence, which in the wired app is always true, and the click then fell
# into on_folder_bound's silent empty-cwd return. A folder whose directory is
# gone resolves to the path it had: the search still bounds by it, the reveal
# has nowhere to go.

package require Tcl 9
package require Tk

set SAND [file join [pwd] _fmenu_sandbox]
set FOLDER "-tmp-fmenu-proj"

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
set PROJDIR [file join $SAND .claude projects $FOLDER]
::questlog::path::_real_file mkdir $PROJDIR
set ::env(HOME) $SAND
unset -nocomplain ::env(CLAUDE_CONFIG_DIR)

proc noop {args} {}
set Sp [file join $PROJDIR aaaa.jsonl]
set fh [open $Sp w]
puts $fh {{"type":"user","cwd":"/tmp/proj","timestamp":"2026-06-10T17:00:00Z","message":{"role":"user","content":"hello"}}}
close $fh

# The resolver's answer is the gate under test; flip it per call.
set ::RESOLVED $SAND
proc resolvef {f} { return $::RESOLVED }
set SL ""
set ::Scan [::questlog::Scan new [list apply {{r} { $::SL on_scan_row $r }}] noop]
proc scanpath {path} { return [$::Scan scan_path $path] }
proc subagentsf {path} { return [$::Scan subagents_for $path] }

# on_folder_bound wired non-empty, as in the real app: the callback's presence
# must not be what enables the entry.
set SL [::questlog::ui::SessionList new .s resolvef noop noop noop noop noop \
            noop scanpath noop subagentsf noop noop noop]
pack .s -fill both -expand 1

set fails 0
proc check {name got want} {
    if {$got eq $want} { puts "ok   - $name" } else {
        puts "FAIL - $name"; puts "       got:  $got"; puts "       want: $want"
        incr ::fails
    }
}
proc entry_state {label} {
    set m [set [info object namespace $::SL]::FMenu]
    for {set i 0} {$i <= [$m index end]} {incr i} {
        if {[$m type $i] eq "command" && [$m entrycget $i -label] eq $label} {
            return [$m entrycget $i -state]
        }
    }
    return "(absent)"
}

$SL apply_filter [dict create since all]
set ::scan_done 0
$::Scan extend [dict create since all]
after 200 [list set ::scan_done 1]
vwait ::scan_done
update

# --- Resolvable folder: both entries live.
$SL on_folder_right $FOLDER 100 100
update
check "resolved: Search within this folder enabled" \
    [entry_state "Search within this folder"] normal
check "resolved: Reveal folder enabled" [entry_state "Reveal folder"] normal
[set [info object namespace $SL]::FMenu] unpost

# --- Gone directory: the search bounds by the path it had, the reveal greys.
set ::RESOLVED [file join $SAND no-longer-here]
$SL on_folder_right $FOLDER 100 100
update
check "gone: Search within this folder enabled" \
    [entry_state "Search within this folder"] normal
check "gone: Reveal folder disabled" [entry_state "Reveal folder"] disabled
[set [info object namespace $SL]::FMenu] unpost

# --- Unresolvable folder: both grey out, search included.
set ::RESOLVED ""
$SL on_folder_right $FOLDER 100 100
update
check "unresolved: Search within this folder disabled" \
    [entry_state "Search within this folder"] disabled
check "unresolved: Reveal folder disabled" [entry_state "Reveal folder"] disabled
[set [info object namespace $SL]::FMenu] unpost

::questlog::path::_real_file delete -force $SAND
puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
