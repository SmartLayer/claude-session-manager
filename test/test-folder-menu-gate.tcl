#!/usr/bin/env wish9.0
# The two right-click menus gate their entries on the resolved project cwd.
#
# The folder heading's: "Search within this folder" bounds the search to that
# cwd, so a folder whose directory cannot be resolved ("" from the resolver)
# must grey it out like "Reveal folder". A folder whose directory is gone
# resolves to the path it had: the search still bounds by it, the reveal has
# nowhere to go.
#
# The session row's: a resume runs `cd` into the project directory, so the
# three resume entries and the Ctrl+R copy need a directory that exists; a
# gone directory's recorded path greys them as it greys the reveal.

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
           ui/drag.tcl ui/toolbar.tcl ui/reveal.tcl ui/session_actions.tcl \
           ui/sessions.tcl} {
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
proc entry_state {label {menu FMenu}} {
    set m [set [info object namespace $::SL]::$menu]
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

# --- The session menu and the Ctrl+R copy: live on a directory that exists,
# grey on a gone one, whose recorded path the resolver still answers.
set ::RESOLVED $SAND
$SL on_session_right $Sp 100 100
update
check "session, resolved: Resume in new terminal tab enabled" \
    [entry_state "Resume in new terminal tab" Menu] normal
check "session, resolved: Copy resume command enabled" \
    [entry_state "Copy resume command" Menu] normal
[set [info object namespace $SL]::Menu] unpost
clipboard clear
$SL copy_selected_resume
check "resolved: Ctrl+R copies a resume command into the directory" \
    [string match "cd '$SAND'*" [clipboard get]] 1

set ::RESOLVED [file join $SAND no-longer-here]
$SL on_session_right $Sp 100 100
update
check "session, gone: Resume in new terminal tab disabled" \
    [entry_state "Resume in new terminal tab" Menu] disabled
check "session, gone: Resume forked disabled" \
    [entry_state "Resume forked" Menu] disabled
check "session, gone: Copy resume command disabled" \
    [entry_state "Copy resume command" Menu] disabled
check "session, gone: Reveal folder stays on the folder alone" \
    [entry_state "Reveal folder" Menu] normal
[set [info object namespace $SL]::Menu] unpost
clipboard clear
clipboard append "untouched"
$SL copy_selected_resume
check "gone: Ctrl+R leaves the clipboard alone" [clipboard get] untouched

::questlog::path::_real_file delete -force $SAND
puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
