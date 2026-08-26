package require Tcl 9
package require Tk

# ::questlog::ui::reveal - the panel that shows a clipped row in full, next to
# the pointer.
#
# The list draws one line per row and cuts it at the column's right edge: a
# session's name and preview are trimmed to the room between the title stop and
# the metadata block, a match snippet at the widget edge. The whole string is in
# the node store either way, and this is how the reader reaches it without
# opening the session.
#
# It sits at the pointer rather than on the app's bottom strip because the
# reader is comparing rows while scanning: a reveal at the far edge of a tall
# window costs the eye its place in the list. One panel serves every hover in
# the app - the list's rows and the viewer's path strip - so the reveal reads
# the same wherever it comes from.
#
# The panel is one reused toplevel, built on first reveal and withdrawn between
# them: hovering a list is a rapid succession of enters and leaves, and a
# per-reveal toplevel would map and destroy a window for each.
namespace eval ::questlog::ui::reveal {
    variable Win ""      ;# the panel toplevel, "" until the first reveal builds it
    variable Head ""     ;# the bold heading line, packed only when a reveal has one
    variable Lbl ""      ;# the wrapping body label
    variable Sub ""      ;# the muted trailing paragraph, packed only when a reveal has one
    variable Timer ""    ;# the armed show, cancelled by a leave that beats it
    # Long enough that sweeping the pointer across rows on the way somewhere
    # else reveals nothing, short enough to feel like part of the hover.
    variable DelayMs 250
}

# Arm a reveal of $text, under the optional heading $head - the row's name, or a
# snippet's badge word, whatever names the thing being revealed - and above the
# optional $sub, a second paragraph in the muted grey the list gives an answer
# (a session row puts its last prompt in $text and the head of the reply in
# $sub). The panel appears once the pointer has rested for the delay; hide
# cancels it. Empty text and no heading reveals nothing, so a caller with no
# stored string does not have to test for one.
proc ::questlog::ui::reveal::show {text {head ""} {sub ""}} {
    variable Timer
    variable DelayMs
    hide
    if {$text eq "" && $head eq ""} return
    set Timer [after $DelayMs [namespace code [list place $text $head $sub]]]
}

proc ::questlog::ui::reveal::hide {} {
    variable Timer
    variable Win
    if {$Timer ne ""} {
        after cancel $Timer
        set Timer ""
    }
    if {$Win ne "" && [winfo exists $Win]} { wm withdraw $Win }
}

# What the panel is showing, "" when it is not up. The one reader of the
# panel's own widgets, so a caller (a test, a later feature) does not have to
# know the toplevel's path.
proc ::questlog::ui::reveal::shown {} {
    variable Win
    variable Head
    variable Lbl
    variable Sub
    if {$Win eq "" || ![winfo exists $Win] || ![winfo ismapped $Win]} { return "" }
    set lines [list]
    foreach w [list $Head $Lbl $Sub] {
        set t [$w cget -text]
        if {$t ne ""} { lappend lines $t }
    }
    return [join $lines "\n"]
}

# Build the panel on first use. Deferred rather than built at startup so a
# headless test that never hovers never maps a window.
proc ::questlog::ui::reveal::build {} {
    variable Win
    variable Head
    variable Lbl
    variable Sub
    if {$Win ne "" && [winfo exists $Win]} return
    set Win .qlreveal
    destroy $Win
    toplevel $Win
    wm withdraw $Win
    wm overrideredirect $Win 1
    # X11 tells the window manager what kind of window this is, so a compositor
    # gives it a tooltip's treatment (no shadow of its own, no focus stealing).
    # Absent elsewhere, hence the catch.
    catch {wm attributes $Win -type tooltip}
    catch {wm attributes $Win -topmost 1}
    set wrap [expr {70 * [font measure QLList "0"]}]
    set Head $Win.h
    label $Head -justify left -anchor w \
        -background [::questlog::ui::theme::c chip_bg] \
        -foreground [::questlog::ui::theme::c sessionhead] \
        -font QLBold -padx 6 -pady 0 -wraplength $wrap
    set Lbl $Win.t
    label $Lbl -justify left -anchor w \
        -background [::questlog::ui::theme::c chip_bg] \
        -foreground [::questlog::ui::theme::c body] \
        -font QLList -padx 6 -pady 3 -wraplength $wrap
    set Sub $Win.s
    label $Sub -justify left -anchor w \
        -background [::questlog::ui::theme::c chip_bg] \
        -foreground [::questlog::ui::theme::c muted] \
        -font QLList -padx 6 -pady 0 -wraplength $wrap
    $Win configure -background [::questlog::ui::theme::c ctrl_border_hi]
    # The toplevel's own background showing through a one-pixel inset is the
    # panel's border: a label -borderwidth draws a relief, not a hairline.
    pack $Head -fill x -padx 1 -pady {3 0}
    pack $Lbl -fill both -expand 1 -padx 1 -pady {0 1}
    pack $Sub -fill x -padx 1 -pady {0 3}
}

# Place the panel below-right of the pointer, pulled back inside the screen
# where it would otherwise run off the right edge or the bottom. The offsets
# ride the list font's line height, so they keep clear of the cursor at the
# high display scalings this app is used at.
proc ::questlog::ui::reveal::place {text {head ""} {sub ""}} {
    variable Win
    variable Head
    variable Lbl
    variable Sub
    variable Timer
    set Timer ""
    build
    # The heading is a line of its own, in the list's own title weight: what the
    # row is called reads apart from what it says. A reveal with no heading
    # drops the line rather than leaving a blank one.
    $Head configure -text $head
    if {$head eq ""} { pack forget $Head } else { pack $Head -fill x -padx 1 -pady {1 0} -before $Lbl }
    $Lbl configure -text $text
    $Sub configure -text $sub
    if {$sub eq ""} { pack forget $Sub } else { pack $Sub -fill x -padx 1 -pady {0 3} -after $Lbl }
    update idletasks
    set w [winfo reqwidth $Win]
    set h [winfo reqheight $Win]
    lassign [winfo pointerxy .] px py
    set off [font metrics QLList -linespace]
    set x [expr {$px + $off}]
    set y [expr {$py + $off}]
    set sw [winfo screenwidth $Win]
    set sh [winfo screenheight $Win]
    if {$x + $w > $sw - 8} { set x [expr {$sw - 8 - $w}] }
    if {$x < 0} { set x 0 }
    # Below the pointer where it fits, above it where it does not, never
    # underneath the pointer itself.
    if {$y + $h > $sh - 8} { set y [expr {$py - $off - $h}] }
    if {$y < 0} { set y 0 }
    wm geometry $Win +$x+$y
    wm deiconify $Win
    raise $Win
}
