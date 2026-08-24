#!/usr/bin/env tclsh9.0
# The dialogue view's :roles suffix: --dialogue:user keeps the prompts alone,
# --dialogue:assistant the replies alone, and a bare --dialogue (or :any) both,
# on all three surfaces the suffix reaches - the grammar's query dict, the
# --json hits with their context windows, and `questlog show`. The prompts-only
# reading is what a study of how a session was driven wants: the human's part is
# a fraction of the tokens the replies cost, and the record-number anchors are
# the way back in for the replies worth reading. Runs the real ./questlog
# subprocess over an isolated corpus. Headless, no Tk. Run:
#   tclsh9.0 test/test-dialogue-roles.tcl
package require Tcl 9
package require json

set ROOT [file dirname [file dirname [file normalize [info script]]]]
::tcl::tm::path add [file join $ROOT modules]
::tcl::tm::path add [file join $ROOT vendor]
package require leash
set QUESTLOG_VERSION 0
set ::questlog_config_only 1; source [file join $ROOT questlog]
source [file join $ROOT lib path.tcl]
source [file join $ROOT lib scan.tcl]
source [file join $ROOT lib match.tcl]
source [file join $ROOT lib search.tcl]
source [file join $ROOT cli commandline.tcl]

# Isolated corpus; HOME points the exec'd CLI at it.
set TMP /tmp/questlog-dialogue-roles-test
set CORPUS [file join $TMP .claude projects]
set ::env(HOME) $TMP
::questlog::path::_real_file delete -force $TMP
set FOLDER [file join $CORPUS -home-test-code-proj]
::questlog::path::_real_file mkdir $FOLDER

set fails 0
proc check {name expected actual} {
    if {$expected eq $actual} {
        puts "ok:   $name"
    } else {
        puts "FAIL: $name"
        puts "      expected: $expected"
        puts "      actual:   $actual"
        incr ::fails
    }
}

proc write_lines {path lines} {
    set fh [open $path w]
    chan configure $fh -encoding utf-8 -translation lf
    foreach l $lines { puts $fh $l }
    close $fh
    file mtime $path [clock seconds]
}

proc run_cli {argv} {
    global ROOT
    return [exec [file join $ROOT questlog] {*}$argv 2> /dev/null]
}
# The refusal the launcher prints, or "" when the query is answered.
proc cli_refusal {argv} {
    global ROOT
    if {[catch {exec [file join $ROOT questlog] {*}$argv 2>@1} out]} {
        return [lindex [split $out "\n"] 0]
    }
    return ""
}
proc session_matches {json} {
    set folder [lindex [::json::json2dict $json] 0]
    set sess [lindex [dict get $folder sessions] 0]
    return [dict get $sess matches]
}

# ---- the grammar ----------------------------------------------------------

proc parse {args} { return [::questlog::cli::commandline::parse $args] }
proc refusal {args} {
    if {[catch {::questlog::cli::commandline::parse $args} e]} { return $e }
    return ""
}

check roles_absent {} [dict get [parse --json --keyword x] dialogue_roles]
check roles_bare   {} [dict get [parse --json --dialogue --keyword x] dialogue_roles]
check roles_any    {} [dict get [parse --json --dialogue:any --keyword x] dialogue_roles]
check roles_user   user [dict get [parse --json --dialogue:user --keyword x] dialogue_roles]
# The region vocabulary's prefixes carry over, so a side is abbreviated the same
# way here as after --keyword.
check roles_prefix assistant [dict get [parse --json --dialogue:assi --keyword x] dialogue_roles]
check roles_both {assistant user} \
    [dict get [parse --json --dialogue:user,assistant --keyword x] dialogue_roles]
# A bare --dialogue still turns the view on: the roles list says which sides, not
# whether the machinery is stripped.
check roles_bare_is_dialogue 1 [dict get [parse --json --dialogue --keyword x] dialogue]

# A transcript slice with no side to it, and the names history, are refused
# where the region grammar would accept them.
check roles_refuse_tool \
    {--dialogue: 'tool-use' is not a side of the conversation (want: user, assistant, any)} \
    [refusal --json --dialogue:tool-use --keyword x]
check roles_refuse_names \
    {--dialogue: 'names' is not a side of the conversation (want: user, assistant, any)} \
    [refusal --json --dialogue:names --keyword x]
check roles_refuse_unknown \
    {unknown region 'bogus' (want: user, assistant, tool-use, tool-result, names, any)} \
    [refusal --json --dialogue:bogus --keyword x]

# ---- the corpus -----------------------------------------------------------

# One prompt, an assistant turn carrying thinking, prose and a tool call, the
# tool's result, and a second prompt. Every record says "watchword", so the
# only thing separating the hits is which side spoke.
set sess [file join $FOLDER 22222222-2222-2222-2222-222222222222.jsonl]
write_lines $sess [list \
    {{"type":"user","cwd":"/home/test/code/proj","timestamp":"2026-06-20T10:00:00.000Z","message":{"content":"watchword: read the file"}}} \
    {{"type":"assistant","timestamp":"2026-06-20T10:00:01.000Z","message":{"content":[{"type":"thinking","thinking":"watchword in thinking"},{"type":"text","text":"watchword: reading it now"},{"type":"tool_use","name":"Bash","input":{"command":"cat watchword"}}]}}} \
    {{"type":"user","timestamp":"2026-06-20T10:00:02.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"t","content":"watchword in the tool output"}]}}} \
    {{"type":"user","cwd":"/home/test/code/proj","timestamp":"2026-06-20T10:00:03.000Z","message":{"content":"watchword: now summarise"}}}]

proc hit_types {argv} {
    set out [list]
    foreach m [session_matches [run_cli $argv]] { lappend out [dict get $m type] }
    return $out
}
set base [list --json --keyword watchword --since all --limit-matches 20]

# Without the view every block type hits, machinery included.
check hits_plain {user thinking assistant tool_use tool_result user} [hit_types $base]
# The bare view drops the machinery, as it did before the suffix existed.
check hits_dialogue {user assistant user} [hit_types [concat $base --dialogue]]
check hits_any      {user assistant user} [hit_types [concat $base --dialogue:any]]
# One side alone.
check hits_user      {user user}  [hit_types [concat $base --dialogue:user]]
check hits_assistant {assistant}  [hit_types [concat $base --dialogue:assistant]]

# The window around a kept hit is drawn through the same selection, so a
# prompts-only answer shows prompts on both sides of the hit and not the reply
# that sat between them.
set windowed [session_matches [run_cli [concat $base --dialogue:user -C 2]]]
set roles [list]
foreach t [dict get [lindex $windowed 0] window] { lappend roles [dict get $t role] }
check window_user_only {USER USER} $roles

# ---- questlog show --------------------------------------------------------

set shown [run_cli [list show $sess --dialogue:user]]
check show_user_keeps_prompts \
    {1 1} [list [string match {*read the file*} $shown] \
                [string match {*now summarise*} $shown]]
check show_user_drops_the_rest \
    {0 0 0} [list [string match {*reading it now*} $shown] \
                  [string match {*in thinking*} $shown] \
                  [string match {*tool output*} $shown]]
# Anchors still cite each kept turn, so a reader can go back for the reply.
check show_user_anchored 1 [string match {*\[#4] USER*} $shown]

set shown_a [run_cli [list show $sess --dialogue:assistant]]
check show_assistant_keeps_prose 1 [string match {*reading it now*} $shown_a]
check show_assistant_drops_prompts 0 [string match {*now summarise*} $shown_a]

check show_refuses_a_non_side \
    {questlog: --dialogue: 'tool-result' is not a side of the conversation (want: user, assistant, any)} \
    [cli_refusal [list show $sess --dialogue:tool-result]]

::questlog::path::_real_file delete -force $TMP
if {$fails > 0} {
    puts "$fails failures"
    exit 1
} else {
    puts "all tests passed"
    exit 0
}
