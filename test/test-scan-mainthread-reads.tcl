#!/usr/bin/env tclsh9.0
# The pool scan's contract with the main thread: a browse pass opens no
# transcript and no subagent sidecar in the main interp - every read happens
# in a worker. `open` is renamed to a counting wrapper before the pass; the
# wrapper first proves it counts (the positive control), then a full pass
# over a corpus with subagents must leave the counter untouched. Run:
#   tclsh9.0 test/test-scan-mainthread-reads.tcl
package require Tcl 9
package require TclOO
set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add [file join $ROOT modules]
::tcl::tm::path add [file join $ROOT vendor]
package require leash
set ::questlog_config_only 1; source [file join $ROOT questlog]
source [file join $ROOT lib path.tcl]
package require logman
source [file join $ROOT lib match.tcl]
source [file join $ROOT lib scan.tcl]
source [file join $ROOT lib search.tcl]
source [file join $ROOT lib jobpool.tcl]

if {[catch {package require Thread}]} {
    puts "skip: Thread package unavailable"
    exit 0
}

set FIX /tmp/questlog-test-mainreads
proc ::questlog::path::projects_root {} { return $::FIX }

set fails 0
proc check {name expected actual} {
    if {$expected ne $actual} {
        puts "FAIL: $name  expected=<$expected>  actual=<$actual>"
        incr ::fails
    } else {
        puts "ok:   $name"
    }
}

# ---- fixture: sessions plus one with a subagent and sidecar -------------
::questlog::path::_real_file delete -force $FIX
::questlog::path::_real_file mkdir $FIX/-home-test-code-foo
for {set i 0} {$i < 5} {incr i} {
    set fh [open $FIX/-home-test-code-foo/s$i.jsonl w]
    puts $fh "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"prompt $i\"},\"cwd\":\"/home/test/code/foo\",\"timestamp\":\"2026-04-25T10:0$i:00.000Z\"}"
    close $fh
}
set subdir $FIX/-home-test-code-foo/[set u 22222222-2222-2222-2222-222222222222]/subagents
::questlog::path::_real_file mkdir $subdir
set fh [open $FIX/-home-test-code-foo/$u.jsonl w]
puts $fh {{"type":"user","message":{"role":"user","content":"parent"},"cwd":"/home/test/code/foo","timestamp":"2026-04-25T11:00:00.000Z"}}
close $fh
set fh [open $subdir/agent-abc.jsonl w]
puts $fh {{"type":"user","message":{"role":"user","content":"child"}}}
close $fh
set fh [open $subdir/agent-abc.meta.json w]
puts $fh {{"agentType":"helper","description":"a child"}}
close $fh

::questlog::jobpool::init $ROOT

# ---- the counting wrapper, armed after the fixture is written -----------
rename ::open ::__mainreads_real_open
set ::main_opens 0
proc ::open {args} {
    set f [lindex $args 0]
    if {[string match *.jsonl $f] || [string match *.meta.json $f]} {
        incr ::main_opens
    }
    tailcall ::__mainreads_real_open {*}$args
}

# Positive control: the wrapper counts a main-interp transcript open.
set fh [open $FIX/-home-test-code-foo/s0.jsonl r]; close $fh
check "the counter counts a main-interp open" 1 $::main_opens
set ::main_opens 0

# ---- a full pool pass, peek off as the GUI runs it ----------------------
set ::rows [list]
set ::done ""
set s [::questlog::Scan new \
    {apply {{row} { lappend ::rows $row }}} \
    {apply {{n} { set ::done $n }}} {} {} {} 0]
$s extend [dict create since all]
vwait ::done

check "the pass published every session" 6 [llength $::rows]
set with_children [lsearch -inline -index 1 [lmap r $::rows {list [dict get $r path] [dict exists $r children]}] 1]
check "the subagent parent carries its children" 1 [expr {$with_children ne ""}]
check "zero transcript or sidecar opens on the main thread" 0 $::main_opens

$s destroy
::questlog::jobpool::release
rename ::open {}
rename ::__mainreads_real_open ::open
::questlog::path::_real_file delete -force $FIX
if {$fails > 0} { puts "$fails failures"; exit 1 }
puts "all tests passed"
exit 0
