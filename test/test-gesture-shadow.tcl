#!/usr/bin/env wish9.0
# No row binding may name a sequence <<ContextMenu>> carries.
#
# macOS has two secondary clicks, the right button and Control+click, and the
# app adds the second to <<ContextMenu>> there. A row that also binds that
# sequence literally takes it: bind(n) MULTIPLE MATCHES rule (d) hands a
# sequence to a physical binding in preference to a virtual event carrying it,
# so the menu never opens and the row toggles out of the selection instead. The
# row's add-to-selection click therefore rides Tk's own <<ToggleSelection>>,
# Control-Button-1 here and Command-Button-1 on Aqua, which leaves Control-click
# to the menu.
#
# The collision is invisible on the windowing system this suite runs on, so the
# Aqua event table is simulated: under both tables, no physical sequence bound
# on any tag in the list may appear in either virtual event's sequence list.

package require Tcl 9
package require Tk

set SAND [file join [pwd] _gesture_sandbox]
set FA "-tmp-gestures"

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

set SP [file join $DIRA s01.jsonl]
set when [expr {[clock seconds] - 24*3600}]
set ts [clock format $when -format "%Y-%m-%dT%H:%M:%S" -gmt 1]
set fh [open $SP w]
fconfigure $fh -encoding utf-8
puts $fh [string map [list @TS@ $ts] {{"type":"user","promptSource":"typed","cwd":"/tmp/proj","timestamp":"@TS@Z","message":{"role":"user","content":"a prompt"}}}]
puts $fh [string map [list @TS@ $ts] {{"type":"assistant","timestamp":"@TS@Z","message":{"role":"assistant","model":"claude-x","content":[{"type":"text","text":"a reply"}],"usage":{"input_tokens":5,"output_tokens":5}}}}]
close $fh
file mtime $SP $when

set ::TARGET ""
set ::Scan [::questlog::Scan new [list apply {{r} { $::TARGET on_scan_row $r }}] noop]
proc scanpath {path} { return [$::Scan scan_path $path] }
proc resolvef {f}    { return "/tmp/proj" }
proc subagentsf {path} { return [$::Scan subagents_for $path] }

# A list built and filled from scratch, the way a launch builds one: its rows
# are wired once, from the virtual event table in force at that moment.
proc build_list {w} {
    set sl [::questlog::ui::SessionList new $w resolvef noop noop noop noop noop \
                noop scanpath noop subagentsf noop noop noop]
    pack $w -fill both -expand 1
    set ::TARGET $sl
    $sl apply_filter [dict create since 30d]
    set ::scan_done 0
    $::Scan extend [dict create since 30d]
    after 200 [list set ::scan_done 1]
    vwait ::scan_done
    update
    return $sl
}

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

# Every tag in the list against every sequence the two virtual events carry. A
# tag binding the virtual events themselves is not a collision; a tag naming a
# sequence one of them carries is the whole fault.
proc shadows {tx} {
    set claimed [list]
    foreach ev {<<ContextMenu>> <<ToggleSelection>>} {
        foreach seq [event info $ev] { lappend claimed $seq }
    }
    set found [list]
    foreach tag [$tx tag names] {
        foreach seq [$tx tag bind $tag] {
            if {[string match "<<*" $seq]} continue
            if {$seq in $claimed} { lappend found "$tag $seq" }
        }
    }
    return [lsort -unique $found]
}

# The sequences the two gestures share, which must be none: bound on one tag,
# two virtual events triggered by the same sequence resolve to one of the two at
# random (bind(n) MULTIPLE MATCHES, rule (e)).
proc overlap {} {
    set toggle [event info <<ToggleSelection>>]
    set both [list]
    foreach seq [event info <<ContextMenu>>] {
        if {$seq in $toggle} { lappend both $seq }
    }
    return $both
}

# The row tag of the one session in a list.
proc rowtag {sl} {
    set ns [info object namespace $sl]
    return [$sl node_field [dict get [set ${ns}::PathNode] $::SP] tag]
}

# --- The table this suite runs under: <<ToggleSelection>> is Control-Button-1
#     and <<ContextMenu>> is the right button, so the two name no sequence in
#     common. The row must still resolve its toggle on the platform's release.
set SL [build_list .s]
set TX .s.body.t
set stag [rowtag $SL]
check "the session rendered" [$SL sflag $SP rendered] 1
check "the row binds the platform toggle press" \
    [expr {[$TX tag bind $stag <<ToggleSelection>>] ne ""}] 1
check "the toggle resolves on Control-ButtonRelease-1 here" \
    [string match "*on_session_toggle_release*" \
        [$TX tag bind $stag <Control-ButtonRelease-1>]] 1
check "nothing shadows either gesture under this table" [shadows $TX] {}
check "the two gestures share no sequence under this table" [overlap] {}

# --- The Aqua table: Control-click joins the menu and the toggle moves to
#     Command. A list built under it is a Mac's first launch.
event add <<ContextMenu>> <Control-Button-1>
event delete <<ToggleSelection>> <Control-Button-1>
event add <<ToggleSelection>> <Command-Button-1>

set SL2 [build_list .s2]
set TX2 .s2.body.t
set stag2 [rowtag $SL2]
check "the toggle resolves on Command-ButtonRelease-1 on Aqua" \
    [string match "*on_session_toggle_release*" \
        [$TX2 tag bind $stag2 <Command-ButtonRelease-1>]] 1
check "Control-ButtonRelease-1 is left to the menu on Aqua" \
    [$TX2 tag bind $stag2 <Control-ButtonRelease-1>] {}
check "nothing shadows either gesture under the Aqua table" [shadows $TX2] {}
check "the two gestures share no sequence on Aqua" [overlap] {}

event delete <<ContextMenu>> <Control-Button-1>
event delete <<ToggleSelection>> <Command-Button-1>
event add <<ToggleSelection>> <Control-Button-1>

::questlog::path::_real_file delete -force $SAND
puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
