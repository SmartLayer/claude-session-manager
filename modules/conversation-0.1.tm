package require Tcl 9
package require Tk
package require logman
package require showman
package provide conversation 0.1

# conversation - a Claude conversation as one composed surface: the
# showman transcript above, a prompt strip for the two prompts a
# session raises mid-turn (a tool-use permission, a question), and an
# input strip for the operator's typed line below. Driver-agnostic on
# purpose: this module spawns nothing, reads nothing and speaks no
# protocol. A host owns the driver (helmsman's live CLI, a daemon wire,
# a replay) and connects it at two points:
#
#   inward:  the host calls the render methods as its driver's events
#            arrive, carrying the record-grade shapes below.
#   outward: everything the operator does here leaves through ONE
#            callback, the -on_send seam.
#
# THE ON-SEND SEAM. -on_send is a command prefix invoked at global
# level with one dict carrying `type`:
#
#   {type send text T}                    the operator's typed line.
#   {type permission req_id R allow 0|1}  a permission prompt decided.
#   {type question req_id R answers D}    a question answered: a dict
#           mapping each question's text to the chosen option label
#           (a multi-select's labels joined ", "), the shape
#           helmsman's answer_question takes.
#
# The surface renders NO echo of a sent line: the driver echoes it
# back as the operator's turn (helmsman's send does so synchronously),
# so the transcript shows what the driver accepted, not what the entry
# hoped.
#
# THE RENDER SURFACE, record-grade and repaint-idempotent. Every
# method is safe to call again with the same key - a frame repeated by
# a replaying wire or a self-healing repaint renders nothing twice:
#
#   turn turn_id role text done ?ts?
#           a text turn. role operator|user opens a new exchange (its
#           header line and prompt body), once per turn_id. Any other
#           role streams into the open exchange through the viewer's
#           live_set, so frames that repeat the turn's whole text so
#           far replace instead of double; done=1 is authoritative and
#           finalizes the message - later frames for that turn_id are
#           dropped. A non-operator turn with no open exchange is an
#           error: the driver echoes the operator's turn first.
#   tool_use turn_id k name ?input? ?ts?
#           a tool call inside the open exchange, k its ordinal within
#           the turn; folds as detail behind the turn's stub. input is
#           the full input dict when the driver carries it (rendered
#           NAME(key=value, ...) exactly as questlog's viewer renders
#           a transcript's); {} when it carries only a label - pass
#           the label as name.
#   tool_result turn_id k content is_error ?ts?
#           the call's result, detail like the transcript's own.
#   thinking turn_id j text ?ts?
#           a thinking block, detail.
#   working on
#           the working… marker on the open exchange's stub line.
#   note text ?ts?
#           a SYSTEM line for the host's own notices (a driver error).
#   closed
#           the session ended, however it ended: seals the open
#           exchange, drops every parked prompt (nobody will answer
#           them), disables the input. A host reopening a session
#           calls input_enable 1.
#
# THE PROMPT STRIP, between transcript and input:
#
#   prompt_permission req_id tool_name input   parks one row naming
#           the call, with Allow / Deny. Deciding removes the row and
#           emits the permission intent through the seam.
#   prompt_question req_id questions           parks one row per the
#           AskUserQuestion input's questions array (dicts of
#           question, header, options, multiSelect): radiobuttons per
#           option, checkbuttons under multiSelect, one Answer button
#           for the whole prompt. Answer refuses (bell) while any
#           question stands unanswered.
#   prompt_dismiss req_id                      removes a row without
#           answering (the driver withdrew the prompt).
#   prompts                                    the parked req_ids.
#
# OTHER SURFACE. `viewer` is the composed Showman, for a host that
# binds or themes it; `input_show 0|1` is the view-only toggle (a
# transcript being read, not continued); `input_enable 0|1` greys the
# strip without hiding it; `focus_input` puts the caret in the entry.
#
# SYNOPSIS - helmsman behind the seam (the continue-a-session window):
#
#   set c [::conversation::Conversation new .f -on_send {glue_send}]
#   set s [MySession new $dir $logs {glue_event}]   ;# helmsman::Session
#   proc glue_send {ev} {
#       switch -- [dict get $ev type] {
#           send       { $::s send [dict get $ev text] }
#           permission { $::s answer_permission [dict get $ev req_id] \
#                            [dict get $ev allow] }
#           question   { $::s answer_question [dict get $ev req_id] \
#                            [dict get $ev answers] }
#       }
#   }
#   proc glue_event {ev} {
#       set c $::c
#       switch -- [dict get $ev type] {
#           turn       { $c turn [dict get $ev turn_id] \
#                            [dict get $ev role] [dict get $ev text] \
#                            [dict get $ev done]
#                        $c working [expr {![dict get $ev done]}] }
#           tool       { $c tool_use [dict get $ev turn_id] \
#                            [dict get $ev k] [dict get $ev name] \
#                            [dict get $ev input] }
#           permission { $c prompt_permission [dict get $ev req_id] \
#                            [dict get $ev tool_name] [dict get $ev input] }
#           question   { $c prompt_question [dict get $ev req_id] \
#                            [dict get $ev questions] }
#           permission_resolved { $c prompt_dismiss [dict get $ev req_id] }
#           error      { $c note [dict get $ev message] }
#           closed     { $c closed }
#       }
#   }
#
# CONSTRUCTOR {parent ?options?}. parent is a frame the host owns and
# packs; the surface grids into it. Options: -on_send (the seam; ""
# renders view-only in effect), -input 0|1 (start with the input strip
# hidden), -view {opts} (passed to the Showman constructor:
# -palette, -fonts, -idle_gap and streamdoc's own).

namespace eval ::conversation {}

oo::class create ::conversation::Conversation {
    variable Top          ;# the host frame the surface grids into
    variable V            ;# the composed ::showman::Showman
    variable OnSend       ;# the seam: a command prefix, "" for none
    variable Entry        ;# the input strip's entry
    variable SendBtn      ;# the input strip's Send button
    variable PromptFrame  ;# the prompt strip (rows pack into it)
    variable InputFrame   ;# the input strip
    variable Seen         ;# dict: rendered frame keys, the idempotency ledger
    variable Prompts      ;# dict: req_id -> its parked row frame
    variable PromptSeq    ;# row counter, names row widgets and their vars

    constructor {parent args} {
        set OnSend ""
        set show_input 1
        set vopts {}
        foreach {k v} $args {
            switch -- $k {
                -on_send { set OnSend $v }
                -input   { set show_input $v }
                -view    { set vopts $v }
                default  { error "conversation: unknown option \"$k\"" }
            }
        }
        set Top $parent
        set Seen [dict create]
        set Prompts [dict create]
        set PromptSeq 0
        ttk::frame $parent.view
        set V [::showman::Showman new $parent.view {*}$vopts]
        set PromptFrame [ttk::frame $parent.prompts]
        set InputFrame  [ttk::frame $parent.input]
        set Entry   [ttk::entry $InputFrame.e]
        set SendBtn [ttk::button $InputFrame.send -text "Send" \
            -command [list [self] send_click]]
        pack $Entry   -side left -fill x -expand 1 -padx {4 2} -pady 4
        pack $SendBtn -side left -padx {2 4} -pady 4
        bind $Entry <Return> [list [self] send_click]
        grid $parent.view -row 0 -column 0 -sticky nsew
        grid $PromptFrame -row 1 -column 0 -sticky ew
        grid $InputFrame  -row 2 -column 0 -sticky ew
        grid columnconfigure $parent 0 -weight 1
        grid rowconfigure    $parent 0 -weight 1
        if {!$show_input} { grid remove $InputFrame }
    }

    destructor {
        catch {$V destroy}
    }

    # ---- the composed pieces -----------------------------------------------

    method viewer {} { return $V }

    # The view-only toggle: a transcript being read, not continued.
    method input_show {on} {
        if {$on} { grid $InputFrame } else { grid remove $InputFrame }
    }

    # Grey the strip without hiding it: the session cannot take a line
    # right now (it closed), but the surface still admits one exists.
    method input_enable {on} {
        set st [expr {$on ? "!disabled" : "disabled"}]
        $Entry   state $st
        $SendBtn state $st
    }

    method focus_input {} { focus $Entry }

    # ---- outward: the seam -------------------------------------------------

    method send_click {} {
        if {"disabled" in [$Entry state]} return
        set text [string trim [$Entry get]]
        if {$text eq ""} return
        $Entry delete 0 end
        my emit [dict create type send text $text]
    }

    method emit {ev} {
        if {$OnSend eq ""} return
        uplevel #0 [linsert $OnSend end $ev]
    }

    # ---- inward: the render surface ----------------------------------------

    # A text turn frame; see the header for the contract. The operator's
    # turn opens the exchange through live_open (which seals the previous
    # one); every other role rides live_set, whose replace-not-append is
    # what makes whole-text repaint frames safe.
    method turn {turn_id role text done {ts ""}} {
        if {[dict exists $Seen turn.$turn_id]} return
        if {$role in {operator user}} {
            $V live_open $text $ts
            dict set Seen turn.$turn_id 1
            return
        }
        if {[$V live] < 0} {
            error "conversation: $role turn with no open exchange"
        }
        $V live_set $turn_id $text $role
        if {$done} {
            $V live_flush
            dict set Seen turn.$turn_id 1
        }
    }

    method tool_use {turn_id k name {input {}} {ts ""}} {
        my detail_record turn.$turn_id.tool.$k [dict create \
            type assistant timestamp $ts message [dict create \
                role assistant content [list [dict create \
                    type tool_use name $name input $input]]]]
    }

    method tool_result {turn_id k content is_error {ts ""}} {
        my detail_record turn.$turn_id.toolresult.$k [dict create \
            type user timestamp $ts message [dict create \
                role user content [list [dict create \
                    type tool_result content $content is_error $is_error]]]]
    }

    method thinking {turn_id j text {ts ""}} {
        my detail_record turn.$turn_id.think.$j [dict create \
            type assistant timestamp $ts message [dict create \
                role assistant content [list [dict create \
                    type thinking thinking $text]]]]
    }

    # Append one finished record into the open exchange, once per key:
    # the synthesized dict is shaped exactly as logman parses the
    # session JSONL, so the viewer's record path (detail elide, stub
    # tallies, search) treats a live conversation and a read transcript
    # identically.
    method detail_record {key rec} {
        if {[dict exists $Seen $key]} return
        dict set Seen $key 1
        $V append_records [list $rec]
    }

    method working {on} { $V live_working $on }

    # A SYSTEM line, outside any driver record: the host's own notices.
    method note {text {ts ""}} {
        $V append_records [list [dict create type system \
            timestamp $ts content $text]]
    }

    method closed {} {
        $V live_close
        foreach rid [dict keys $Prompts] { my prompt_dismiss $rid }
        my input_enable 0
    }

    # ---- the prompt strip --------------------------------------------------

    # One parked row per req_id; "" when that req_id already stands (a
    # repeated frame parks nothing twice).
    method prompt_row {req_id} {
        if {[dict exists $Prompts $req_id]} { return "" }
        set f [ttk::frame $PromptFrame.p[incr PromptSeq] -padding 2]
        dict set Prompts $req_id $f
        pack $f -fill x
        return $f
    }

    method prompt_permission {req_id tool_name input} {
        set f [my prompt_row $req_id]
        if {$f eq ""} return
        set line [::logman::format_tool_use_full $tool_name $input]
        if {[string length $line] > 160} {
            set line "[string range $line 0 159]…"
        }
        ttk::label  $f.lbl -text "Permission: $line"
        ttk::button $f.allow -text "Allow" -command [list [self] \
            prompt_answer $req_id [dict create type permission \
                req_id $req_id allow 1]]
        ttk::button $f.deny -text "Deny" -command [list [self] \
            prompt_answer $req_id [dict create type permission \
                req_id $req_id allow 0]]
        pack $f.lbl  -side left -padx 4
        pack $f.deny $f.allow -side right -padx 2
    }

    method prompt_question {req_id questions} {
        set f [my prompt_row $req_id]
        if {$f eq ""} return
        set seq $PromptSeq
        set qi 0
        foreach q $questions {
            set qf [ttk::frame $f.q$qi]
            pack $qf -fill x
            set head  [dict getdef $q header ""]
            set shown [dict getdef $q question ""]
            if {$head ne ""} { set shown "$head: $shown" }
            ttk::label $qf.lbl -text $shown
            pack $qf.lbl -side left -padx 4
            set multi [dict getdef $q multiSelect 0]
            set oi 0
            foreach o [dict getdef $q options {}] {
                set lab [dict getdef $o label ""]
                if {$multi} {
                    set var [my varname QSel${seq}_${qi}_$oi]
                    set $var 0
                    ttk::checkbutton $qf.o$oi -text $lab -variable $var
                } else {
                    set var [my varname QSel${seq}_$qi]
                    if {$oi == 0} { set $var "" }
                    ttk::radiobutton $qf.o$oi -text $lab -variable $var \
                        -value $lab
                }
                pack $qf.o$oi -side left -padx 2
                incr oi
            }
            incr qi
        }
        ttk::button $f.answer -text "Answer" \
            -command [list [self] question_answer $req_id $seq $questions]
        pack $f.answer -side right -padx 4
    }

    # Collect the row's selections into the answers dict the seam
    # carries; refuse while any question stands unanswered, so a
    # half-answered prompt cannot leave.
    method question_answer {req_id seq questions} {
        set answers [dict create]
        set qi 0
        foreach q $questions {
            set qtext [dict getdef $q question ""]
            if {[dict getdef $q multiSelect 0]} {
                set chosen {}
                set oi 0
                foreach o [dict getdef $q options {}] {
                    if {[set [my varname QSel${seq}_${qi}_$oi]]} {
                        lappend chosen [dict getdef $o label ""]
                    }
                    incr oi
                }
                if {![llength $chosen]} { catch {bell}; return }
                dict set answers $qtext [join $chosen ", "]
            } else {
                set sel [set [my varname QSel${seq}_$qi]]
                if {$sel eq ""} { catch {bell}; return }
                dict set answers $qtext $sel
            }
            incr qi
        }
        my prompt_answer $req_id [dict create type question \
            req_id $req_id answers $answers]
    }

    # A prompt decided: the row leaves first (a second click must find
    # nothing), then the decision leaves through the seam.
    method prompt_answer {req_id ev} {
        if {![dict exists $Prompts $req_id]} return
        my prompt_dismiss $req_id
        my emit $ev
    }

    method prompt_dismiss {req_id} {
        if {![dict exists $Prompts $req_id]} return
        destroy [dict get $Prompts $req_id]
        dict unset Prompts $req_id
    }

    method prompts {} { return [dict keys $Prompts] }
}
