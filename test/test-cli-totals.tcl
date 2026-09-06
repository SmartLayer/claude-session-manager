#!/usr/bin/env tclsh9.0
# Tests for the CLI's result totals: the accumulator in cli/main.tcl that turns
# a query's answer ("which sessions match") into its sum ("what they came to"),
# and the three surfaces that render it - the folder object --json emits, the
# folder heading line --markdown prints, and --shortstat's whole-plus-folders
# block. Also drives the real ./questlog over a fixture corpus, so the wiring
# from the output loop to each surface is exercised, not just the formatters.
# Run:
#   tclsh9.0 test/test-cli-totals.tcl
package require Tcl 9
package require json

# UTC, so the local calendar day a stamp falls on is a fixed expectation; one
# case below flips the zone to prove the day is the reader's, not the corpus's.
set ::env(TZ) UTC

set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add [file join $ROOT modules]
::tcl::tm::path add [file join $ROOT vendor]
source [file join $ROOT lib cost.tcl]
source [file join $ROOT cli main.tcl]
set failures 0
proc check {name got want} {
    if {$got eq $want} {
        puts "ok   - $name"
    } else {
        puts "FAIL - $name"
        puts "       got:  $got"
        puts "       want: $want"
        incr ::failures
    }
}

# A cost dict in the shape tallyman's build_cost_dict returns.
proc ci {cost turns dur human {in 0} {out 0}} {
    return [dict create cost_usd $cost turns $turns duration_secs $dur \
        human_secs $human input_tokens $in output_tokens $out \
        cache_write_tokens 0 cache_read_tokens 0]
}

# ---- local_day: the reader's calendar day, not the corpus's UTC one --------

check "local_day: a UTC stamp under UTC" \
    [::questlog::cli::main::local_day 2026-06-20T22:00:00.000Z] 2026-06-20
set ::env(TZ) :Australia/Sydney
check "local_day: the same stamp is the next day east of UTC" \
    [::questlog::cli::main::local_day 2026-06-20T22:00:00.000Z] 2026-06-21
set ::env(TZ) UTC
check "local_day: an empty stamp is no day" [::questlog::cli::main::local_day ""] ""
check "local_day: an unparseable stamp is no day" \
    [::questlog::cli::main::local_day "not a timestamp"] ""

# ---- totals_add: one fold, counting by kind --------------------------------

set z [::questlog::cli::main::totals_zero]
check "totals_zero: nothing counted" \
    [list [dict get $z sessions] [dict get $z cost_usd] [dict get $z first_ts]] {0 0.0 {}}

set t [::questlog::cli::main::totals_add $z [ci 0.25 4 600 120 100 50] \
    sessions 2026-06-20T10:00:00.000Z]
set t [::questlog::cli::main::totals_add $t [ci 0.10 2 60 0] subagents]
check "totals_add: a session counts as one session" [dict get $t sessions] 1
check "totals_add: a subagent counts apart from its session" [dict get $t subagents] 1
check "totals_add: turns sum across both kinds" [dict get $t turns] 6
check "totals_add: cost sums" [format %.2f [dict get $t cost_usd]] 0.35
check "totals_add: machine time sums" [dict get $t duration_secs] 660
check "totals_add: human time sums" [dict get $t human_secs] 120
check "totals_add: tokens sum" [dict get $t input_tokens] 100
check "totals_add: the span opens at the first session" \
    [dict get $t first_ts] 2026-06-20T10:00:00.000Z
check "totals_add: a subagent carries no stamp, so the day set counts sessions" \
    [dict size [dict get $t days]] 1

# The unpriced sentinel (-1.0, no rate matched any model) adds no cost, as the
# shortstat total has always had it, but its turns and time still count.
set u [::questlog::cli::main::totals_add $z [ci -1.0 3 300 60] sessions \
    2026-06-21T10:00:00.000Z]
check "totals_add: the -1.0 cost sentinel adds nothing to cost" [dict get $u cost_usd] 0.0
check "totals_add: an unpriced session still counts its turns" [dict get $u turns] 3

# Two sessions on one day are one day; an earlier arrival widens the span open.
set d [::questlog::cli::main::totals_add $t [ci 0.05 1 60 30] sessions \
    2026-06-20T18:00:00.000Z]
set d [::questlog::cli::main::totals_add $d [ci 0.05 1 60 30] sessions \
    2026-06-19T08:00:00.000Z]
check "totals_add: two sessions on one calendar day count one day" \
    [dict size [dict get $d days]] 2
check "totals_add: an earlier session moves the span's opening" \
    [dict get $d first_ts] 2026-06-19T08:00:00.000Z
check "totals_add: the closing stays the latest" \
    [dict get $d last_ts] 2026-06-20T18:00:00.000Z

# ---- totals_merge: the whole is the sum of its folders ---------------------

set a [::questlog::cli::main::totals_add $z [ci 1.0 5 600 300] sessions \
    2026-06-20T09:00:00.000Z]
set b [::questlog::cli::main::totals_add $z [ci 2.0 7 900 400] sessions \
    2026-06-20T15:00:00.000Z]
set b [::questlog::cli::main::totals_add $b [ci 3.0 1 100 50] sessions \
    2026-06-25T15:00:00.000Z]
set m [::questlog::cli::main::totals_merge $a $b]
check "totals_merge: sessions add" [dict get $m sessions] 3
check "totals_merge: cost adds" [format %.2f [dict get $m cost_usd]] 6.00
check "totals_merge: human time adds" [dict get $m human_secs] 750
check "totals_merge: a day two folders share counts once" \
    [dict size [dict get $m days]] 2
check "totals_merge: the span spans both" \
    [list [dict get $m first_ts] [dict get $m last_ts]] \
    {2026-06-20T09:00:00.000Z 2026-06-25T15:00:00.000Z}
check "totals_merge: merging a zero accumulator changes nothing" \
    [dict get [::questlog::cli::main::totals_merge $m $z] sessions] 3

# ---- the rendered surfaces -------------------------------------------------

set j [::questlog::cli::main::format_totals_json $m]
check "format_totals_json: valid JSON" [expr {![catch {::json::json2dict $j}]}] 1
set jd [::json::json2dict $j]
check "format_totals_json: the day count is a number, not the set" \
    [dict get $jd days] 2
check "format_totals_json: subagent sessions are named in full" \
    [dict exists $jd subagent_sessions] 1
check "format_totals_json: the span rides as the ISO stamps --json speaks" \
    [dict get $jd last_ts] 2026-06-25T15:00:00.000Z
check "format_totals_json: the time caveat travels with the figures" \
    [expr {[string match "*double count*" [dict get $jd time_basis]]
        && [string match "*counts whole*" [dict get $jd time_basis]]}] 1

set line [::questlog::cli::main::totals_line $m]
check "totals_line: counts, times, cost, span and days on one line" $line \
    "3 sessions · 13 turns · human 12:30 · machine 26:40 · \$6.00 · 2026-06-20 to 2026-06-25 · 2 days"
check "totals_line: a single-day result prints the day once, and counts singly" \
    [::questlog::cli::main::totals_line $a] \
    "1 session · 5 turns · human 05:00 · machine 10:00 · \$1.00 · 2026-06-20 · 1 day"

# --shortstat: the whole, its caveat, then the folders dearest first.
set ss [::questlog::cli::main::format_shortstat $m 0 \
    [list [list /home/user/cheap $a [dict get $a cost_usd]] \
          [list /home/user/dear $b [dict get $b cost_usd]]]]
check "shortstat: human time is named and formatted" \
    [regexp -- {(?m)^human time         12:30$} $ss] 1
check "shortstat: machine time is named and formatted" \
    [regexp -- {(?m)^machine time       26:40$} $ss] 1
check "shortstat: the first and last matching session are dated" \
    [regexp -- {(?m)^first session      2026-06-20\nlast session       2026-06-25$} $ss] 1
check "shortstat: the days holding a session are counted" \
    [regexp -- {(?m)^days with sessions 2$} $ss] 1
check "shortstat: the caveat stands with the numbers, not in the manual" \
    [regexp -- {double count.*counts whole} $ss] 1
check "shortstat: the folder breakdown leads with the dearest" \
    [regexp -- {(?s)/home/user/dear.*/home/user/cheap} $ss] 1
check "shortstat: one folder needs no breakdown of itself" \
    [regexp -- {by folder} [::questlog::cli::main::format_shortstat $m 0 \
        [list [list /home/user/only $a [dict get $a cost_usd]]]]] 0
check "shortstat: a limit still names itself" \
    [regexp -- {limit applied} [::questlog::cli::main::format_shortstat $m 5 {}]] 1

# --json and --markdown carry a folder's totals; a folder without them (an
# older caller, a serializer fixture) emits the shape it always did.
set folders [dict create f1 [dict create project_path /home/user/proj totals $a \
    sessions [list [dict create uuid s1 path /p/s1.jsonl title T \
        first_ts 2026-06-20T09:00:00.000Z cost_usd 1.0 turns 5 duration_secs 600 \
        human_secs 300 matches {} subagents {}]]]]
set fj [::json::json2dict [::questlog::cli::main::format_json $folders]]
check "format_json: the folder object carries its totals" \
    [dict get [lindex $fj 0] totals sessions] 1
check "format_json: the sessions array is untouched beside them" \
    [llength [dict get [lindex $fj 0] sessions]] 1
check "format_json: a totals-less folder emits the shape it always did" \
    [dict exists [lindex [::json::json2dict [::questlog::cli::main::format_json \
        [dict replace $folders f1 [dict remove [dict get $folders f1] totals]]]] 0] totals] 0
set md [::questlog::cli::main::format_markdown $folders]
check "markdown: the folder's totals sit under its heading" \
    [regexp -- {(?m)^\*1 session · 5 turns} $md] 1
check "markdown: the caveat closes the document once" \
    [llength [regexp -all -inline -- {counts whole} $md]] 1

# ---- end to end: the real CLI over a fixture corpus ------------------------

# The corpus is per-process: two runs of this file at once (two suite runs on
# one host) would otherwise share the directory, and the first to finish
# deletes it under the second.
set TMP /tmp/questlog-totals-test-[pid]
set CORPUS [file join $TMP .claude projects]
set ::env(HOME) $TMP
unset -nocomplain ::env(CLAUDE_CONFIG_DIR)
file delete -force $TMP
proc write_session {path lines} {
    file mkdir [file dirname $path]
    set fh [open $path w]
    chan configure $fh -encoding utf-8 -translation lf
    foreach l $lines { puts $fh $l }
    close $fh
    file mtime $path [clock seconds]
}
set usage {"model":"claude-sonnet-4-5-20250929","usage":{"input_tokens":1000,"output_tokens":500}}
write_session [file join $CORPUS -home-test-code-proj \
        11111111-1111-1111-1111-111111111111.jsonl] [list \
    "{\"type\":\"user\",\"cwd\":\"/home/test/code/proj\",\"timestamp\":\"2026-06-20T10:00:00.000Z\",\"message\":{\"content\":\"shibboleth open\"}}" \
    "{\"type\":\"assistant\",\"timestamp\":\"2026-06-20T10:04:00.000Z\",\"message\":{$usage,\"content\":\"shibboleth one\"}}"]
write_session [file join $CORPUS -home-test-code-other \
        22222222-2222-2222-2222-222222222222.jsonl] [list \
    "{\"type\":\"user\",\"cwd\":\"/home/test/code/other\",\"timestamp\":\"2026-06-22T09:00:00.000Z\",\"message\":{\"content\":\"shibboleth open\"}}" \
    "{\"type\":\"assistant\",\"timestamp\":\"2026-06-22T09:10:00.000Z\",\"message\":{$usage,\"content\":\"shibboleth two\"}}"]

proc run_cli {args} {
    global ROOT
    return [exec [file join $ROOT questlog] {*}$args 2> /dev/null]
}
set out [::json::json2dict [run_cli --json --keyword shibboleth --since all]]
check "cli --json: every folder carries totals" \
    [lmap f $out {dict get $f totals sessions}] {1 1}
check "cli --json: a folder's machine time is its session's" \
    [lsort -integer [lmap f $out {dict get $f totals duration_secs}]] {240 600}
set sstat [run_cli --shortstat --keyword shibboleth --since all]
check "cli --shortstat: the whole result is two sessions" \
    [regexp -- {(?m)^sessions           2$} $sstat] 1
check "cli --shortstat: the span covers both" \
    [regexp -- {(?m)^first session      2026-06-20\nlast session       2026-06-22$} $sstat] 1
check "cli --shortstat: two days hold a session" \
    [regexp -- {(?m)^days with sessions 2$} $sstat] 1
check "cli --shortstat: machine time is the sum of both sessions" \
    [regexp -- {(?m)^machine time       14:00$} $sstat] 1
check "cli --shortstat: both folders appear in the breakdown" \
    [expr {[regexp -- {-home-test-code-proj} $sstat]
        && [regexp -- {-home-test-code-other} $sstat]}] 1
file delete -force $TMP

if {$failures > 0} {
    puts "$failures failures"
    exit 1
}
puts "All tests passed"
exit 0
