#!/usr/bin/env wish9.0
# Reveal-on-hover for a clipped row (issue #22).
#
# A list row is one line with -wrap none, so a match snippet wider than the
# column is cut at its right edge and the trailing context is unreachable from
# the list. Hovering the row reveals the model's full stored snippet - not the
# clipped display - on the panel beside the pointer, and leaving takes it down.
# This drives that path end to end over a one-session sandbox: the wired <Enter>
# binding carries only the reveal tag (the text waits in the registry, out of
# reach of bind's %-substitution), the panel shows what the registry resolves,
# and a wholesale clear takes the panel down with the row it was showing.

package require Tcl 9
package require Tk

set SAND [file join [pwd] _peek_sandbox]
set FA "-tmp-peek-a"

set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add [file join $ROOT modules]
::tcl::tm::path add [file join $ROOT vendor]
package require leash
package require streamtree
set ::questlog_config_only 1; source [file join $ROOT questlog]
foreach f {lib/cost.tcl ui/theme.tcl lib/path.tcl lib/listfilter.tcl \
           lib/match.tcl ui/terminal.tcl ui/live.tcl lib/scan.tcl lib/search.tcl \
           ui/drag.tcl ui/toolbar.tcl ui/reveal.tcl ui/sessions.tcl ui/app.tcl} {
    source [file join $ROOT $f]
}
::questlog::ui::theme::init

::questlog::path::_real_file delete -force $SAND
set DIRA [file join $SAND .claude projects $FA]
::questlog::path::_real_file mkdir $DIRA
set ::env(HOME) $SAND
unset -nocomplain ::env(CLAUDE_CONFIG_DIR)

# The panel is timed: it appears once the pointer has rested on the row. A test
# has no pointer to rest, so the delay goes to zero and an update runs the show
# the hover armed.
set ::questlog::ui::reveal::DelayMs 0

proc noop {args} {}

proc write_session {path ts} {
    set fh [open $path w]
    puts $fh "{\"type\":\"user\",\"cwd\":\"/tmp/proj\",\"timestamp\":\"${ts}Z\",\"message\":{\"role\":\"user\",\"content\":\"hello\"}}"
    puts $fh "{\"type\":\"assistant\",\"timestamp\":\"${ts}Z\",\"message\":{\"model\":\"claude-3-5-sonnet-20241022\",\"usage\":{\"input_tokens\":100,\"output_tokens\":50}}}"
    puts $fh "{\"type\":\"user\",\"timestamp\":\"${ts}Z\",\"message\":{\"role\":\"user\",\"content\":\"more\"}}"
    close $fh
}

proc session_moment {days_ago} { return [expr {[clock seconds] - $days_ago*24*3600}] }
set SP [file join $DIRA s01.jsonl]
set when [session_moment 1]
write_session $SP [clock format $when -format "%Y-%m-%dT%H:%M:%S" -gmt 1]
file mtime $SP $when

set SL ""
set ::Scan [::questlog::Scan new [list apply {{r} { $::SL on_scan_row $r }}] noop]
proc scanpath {path} { return [$::Scan scan_path $path] }
proc resolvef {f}    { return "/tmp/proj" }
proc subagentsf {path} { return [$::Scan subagents_for $path] }

set SL [::questlog::ui::SessionList new .s resolvef noop noop noop noop noop \
            noop scanpath noop subagentsf noop]
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
# Run the show the hover armed, then read what the panel holds.
proc revealed {} {
    update
    return [::questlog::ui::reveal::shown]
}

# --- Stream the one session in and open its folder so the row renders.
$SL apply_filter [dict create since 30d]
set ::scan_done 0
$::Scan extend [dict create since 30d]
after 200 [list set ::scan_done 1]
vwait ::scan_done
update
check "session rendered" [$SL sflag $SP rendered] 1

# --- Inject a match whose snippet is far wider than any list column, so the
#     rendered row is clipped and only a hover can surface the tail.
set LONG "the quick brown fox jumps over the lazy dog and then keeps running far\
 past the right edge of the narrow session-list column where a reader cannot see\
 the trailing context without this hover reveal working end to end"
set matches [list [dict create path $SP folder $FA btype tool_use content $LONG lineoff 5]]
$SL add_session_matches $matches
update

set stored [lindex [lindex [$SL sget $SP snippets] 0] 1]
check "model holds the full untruncated snippet" $stored $LONG

# The n# tag on the freshly-drawn snippet, and its wired <Enter>/<Leave> scripts.
set ntags [lsearch -all -inline -glob [$TX tag names] n#*]
check "exactly one snippet tag" [llength $ntags] 1
set ntag [lindex $ntags 0]
set enter [$TX tag bind $ntag <Enter>]
set leave [$TX tag bind $ntag <Leave>]

# The binding must NOT embed the content: bind %-substitutes its script at
# event time, so embedded text holding a % is corrupted in place ("printf %s"
# becomes the state field). The script carries only the machine-made tag; the
# content waits in the registry and resolves when the event fires.
check "enter binding does not splice content into bind's script" \
    [string match "*$LONG*" $enter] 0
set NS [info object namespace $SL]
check "the registry resolves the tag to the full model text" \
    [string match "*$LONG*" [dict get [set ${NS}::PeekByTag] $ntag]] 1

# --- Nothing is up until a hover asks for it.
check "no panel at rest" [revealed] ""

# --- <Enter>: the panel heads with the badge kind and carries the whole
#     snippet line under it.
eval $enter
check "reveal shows badge-led full snippet" [revealed] "tool_use\n$LONG"

# --- <Leave> takes it down.
eval $leave
check "leave takes the panel down" [revealed] ""

# --- Percent-laden content survives verbatim: the very characters bind's
#     %-substitution corrupts ("printf %s" -> the state field, "50%" -> "50\ ")
#     ride the registry untouched. Injected as a second match so the reveal
#     runs the same wire -> registry -> resolve path as any snippet. (eval
#     bypasses bind's %-pass, so this check alone cannot catch a splice
#     regression - the no-splice assertion above is the guard.)
set PCT {printf %s lands 50% done and %% stays doubled}
$SL add_session_matches \
    [list [dict create path $SP folder $FA btype tool_use content $PCT lineoff 9]]
update
set ptag [lindex [lsearch -all -inline -glob [$TX tag names] n#*] end]
eval [$TX tag bind $ptag <Enter>]
check "a percent-laden snippet reveals verbatim" [revealed] "tool_use\n$PCT"
eval [$TX tag bind $ptag <Leave>]

# --- A wholesale clear under a parked pointer: the hovered row is deleted with
#     no guarantee Tk synthesizes its <Leave>, so reset_nodes takes the panel
#     down itself - a reveal must not outlive its row.
eval $enter
check "panel up before the clear" [revealed] "tool_use\n$LONG"
$SL reset
update
check "a wholesale clear takes the panel down" [revealed] ""

::questlog::path::_real_file delete -force $SAND
puts [expr {$fails ? "FAILED ($fails)" : "PASS"}]
exit $fails
