#!/usr/bin/env tclsh9.0
# The shared worker pool (::questlog::jobpool) must parallelise, not funnel
# (issue #56): a min-0 tpool spawns one worker for the first post and never
# grows, so every job runs in series through that single thread. This builds
# the pool the app builds and asserts N concurrent jobs land on N distinct
# threads, that posts are detached (no result retained for a reap that never
# comes), and that an epoch bump turns queued jobs into no-ops. Run:
#   tclsh9.0 test/test-jobpool.tcl
package require Tcl 9
set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add [file join $ROOT modules]
::tcl::tm::path add [file join $ROOT vendor]
set ::questlog_config_only 1; source [file join $ROOT questlog]

set fails 0
proc check {name got want} {
    if {$got eq $want} {
        puts "ok   - $name"
    } else {
        puts "FAIL - $name (got <$got> want <$want>)"
        incr ::fails
    }
}

if {[catch {package require Thread}]} {
    puts "skip: Thread package unavailable"
    exit 0
}
source [file join $ROOT lib search.tcl]
source [file join $ROOT lib jobpool.tcl]

set n [::questlog::config::get pool_workers]
# A fixed-size pool needs at least two workers to parallelise at all. A min-0
# default (the bug) is exactly what this guards.
check "pool_workers is a parallel width" [expr {$n >= 2}] 1

check "init builds the pool" [::questlog::jobpool::init $ROOT] 1
check "pool reports available" [::questlog::jobpool::available] 1

# n jobs that each hold their worker long enough to overlap. A funnelling pool
# completes them in series on one thread; a parallel pool spreads them. Results
# land in tsv because posts are detached (nothing to tpool::get).
tsv::set questlog test_tids [list]
set t0 [clock milliseconds]
for {set i 0} {$i < $n} {incr i} {
    set r [::questlog::jobpool::post {
        after 300
        tsv::lappend questlog test_tids [thread::id]
    }]
    if {$i == 0} { check "posts are detached (no job handle)" $r "" }
}
while {[llength [tsv::get questlog test_tids]] < $n \
        && [clock milliseconds] - $t0 < 5000} {
    after 20
}
set wall [expr {[clock milliseconds] - $t0}]
check "n jobs run on n distinct workers" \
    [llength [lsort -unique [tsv::get questlog test_tids]]] $n
# Parallel, not serial: n * 300ms in series would be well past 2 * 300ms.
check "the pass overlaps rather than funnels" [expr {$wall < $n * 300 - 200}] 1

# Epoch gate: saturate the pool so the epoch-checked jobs queue, bump the
# epoch while they wait, and assert none of them did its work.
tsv::set questlog test_fired 0
for {set i 0} {$i < $n} {incr i} {
    ::questlog::jobpool::post {after 200}
}
set e [::questlog::jobpool::epoch scan]
for {set i 0} {$i < 3} {incr i} {
    ::questlog::jobpool::post [list apply {{e} {
        if {[tsv::get questlog scan_epoch] != $e} return
        tsv::incr questlog test_fired
    }} $e]
}
::questlog::jobpool::bump scan
after 600 {set ::done 1}; vwait ::done
check "a bump no-ops every queued job" [tsv::get questlog test_fired] 0

::questlog::jobpool::release
check "release empties the handle" [::questlog::jobpool::available] 0

if {$fails > 0} { puts "$fails failures"; exit 1 }
puts "all tests passed"
exit 0
