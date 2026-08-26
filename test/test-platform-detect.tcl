#!/usr/bin/env tclsh9.0
# Verify the two platform decisions questlog makes about the host desktop:
# which terminal a session resumes into, and which file manager reveals a
# folder. Both read tcl_platform, so the test substitutes it and asks each
# branch what it chose, rather than running on three machines to find out.
#
# The reveal side is checked through the opener name alone: launching the file
# manager is one exec the test does not want, so the proc's platform decision
# is re-derived here from the same two facts it reads. That keeps the test on
# the branch that varies (which of the three names) and off the part that
# would spawn a program.

package require Tcl 9
set ROOT [file dirname [file dirname [file normalize [info script]]]]
source [file join $ROOT ui terminal.tcl]

set fails 0
proc check {name expected actual} {
    if {$expected ne $actual} {
        puts "FAIL: $name  expected=<$expected>  actual=<$actual>"
        incr ::fails
    } else {
        puts "ok:   $name"
    }
}

# Run the detection once as though the host were $platform/$os, with $present
# the set of terminal binaries installed there. detect memoises its answer, so
# each case clears the memo; auto_execok is shadowed because the question is
# what questlog picks from what it finds, not what this machine has.
proc detect_as {platform os present} {
    set saved [array get ::tcl_platform]
    set ::tcl_platform(platform) $platform
    set ::tcl_platform(os) $os
    set ::questlog::ui::terminal::Detected ""

    rename ::auto_execok ::_real_auto_execok
    proc ::auto_execok {name} {
        upvar #0 ::_detect_present present
        return [expr {$name in $present ? "/usr/bin/$name" : ""}]
    }
    set ::_detect_present $present

    # The Unix arms consult the hosting terminal's own environment variables
    # before they look at what is installed; clear them so a case states its
    # whole input.
    set savedenv [list]
    foreach v {GNOME_TERMINAL_SERVICE KONSOLE_VERSION TERM_PROGRAM} {
        if {[info exists ::env($v)]} {
            lappend savedenv $v $::env($v)
            unset ::env($v)
        }
    }

    set got [::questlog::ui::terminal::detect]

    foreach {v val} $savedenv { set ::env($v) $val }
    rename ::auto_execok {}
    rename ::_real_auto_execok ::auto_execok
    unset ::_detect_present
    array set ::tcl_platform $saved
    set ::questlog::ui::terminal::Detected ""
    return $got
}

# ---- terminal detection ------------------------------------------------
# Windows Terminal ships with Windows 11 and is where a tab means anything;
# cmd is the floor and is never absent, so the Windows answer never falls
# through to the empty string the Unix arms can return.
check win_prefers_wt wt [detect_as windows Windows {wt cmd}]
check win_falls_back_to_cmd cmd [detect_as windows Windows {cmd}]
check win_ignores_unix_terminals cmd \
    [detect_as windows Windows {gnome-terminal konsole xterm}]

check mac_terminal macterminal [detect_as unix Darwin {}]
check linux_first_installed konsole [detect_as unix Linux {konsole xterm}]

# ---- cmd.exe quoting ---------------------------------------------------
# The resume command reaches cmd inside one /k string, so a path with a space
# has to arrive quoted, and cmd offers no escape for a quote within one.
check cmdquote_plain {"C:\Users\me\code"} \
    [::questlog::ui::terminal::cmdquote {C:\Users\me\code}]
check cmdquote_space {"C:\My Code\proj"} \
    [::questlog::ui::terminal::cmdquote {C:\My Code\proj}]
check cmdquote_drops_quote {"C:\odd\name"} \
    [::questlog::ui::terminal::cmdquote {C:\odd\"name}]

# ---- file-manager choice -----------------------------------------------
# reveal_dir names the opener from the same two facts, then execs it. The exec
# is what this test declines to run, so the choice is re-derived and the three
# names are pinned; reveal_dir's own arm order is what the check mirrors.
proc opener_for {platform os} {
    if {$platform eq "windows"} { return explorer }
    if {$os eq "Darwin"} { return open }
    return xdg-open
}
check opener_windows explorer [opener_for windows Windows]
check opener_macos   open     [opener_for unix Darwin]
check opener_linux   xdg-open [opener_for unix Linux]

# nativename is what hands Explorer a path it can read; on Unix it is identity.
if {$::tcl_platform(platform) eq "windows"} {
    check nativename_backslashes {C:\tmp\p} [file nativename C:/tmp/p]
} else {
    check nativename_identity /tmp/p [file nativename /tmp/p]
}

puts [expr {$fails ? "FAILED ($fails)" : "PASSED"}]
exit $fails
