package require Tcl 9

# ::questlog::jobpool - the one persistent worker pool for per-file background
# work. The browse scan's row extraction and the cost pass's transcript pricing
# both post here; the main thread never opens a transcript on either path. One
# pool rather than one per pass: both passes read the same corpus on the same
# cores, so a second pool would only double the resident interps and split the
# width. Search keeps its own thread::create fan-out - its per-file work is
# unbounded in duration and would head-of-line-block a FIFO queue like this one.
#
# Cancellation is a tsv epoch, not tpool::cancel: jobs post -detached (so no
# result is retained in the pool awaiting a reap that never comes) and carry
# the epoch they were posted under; a job's first act is comparing it against
# the shared tsv slot, so a bumped epoch turns the whole queued backlog into
# microsecond no-ops. The two sides of the gate: the worker checks tsv before
# reading the file, and the main-thread arrival handler checks its own epoch
# copy before applying the result.
#
# A namespace of procs over one pool handle, not a class: one instance per
# process by design, no joint state beyond the handle and the epochs.

namespace eval ::questlog::jobpool {
    variable Pool ""
}

# Worker-side job procs, evaluated in each worker interp after the shared
# prelude (tm paths, logman, lib/match.tcl - see search::worker_prelude).
# job_cost prices one transcript: parse on the worker, send the raw result
# home; the caller's reply prefix receives {path epoch result} and does the
# pricing against the main interp's rate table. lib/cost.tcl (and tallyman
# behind it) loads lazily on the first cost job, so building the pool costs
# no package loads beyond the prelude's.
set ::questlog::jobpool::WorkerProcs {
    proc job_cost {path tid epoch reply} {
        if {[tsv::get questlog cost_epoch] != $epoch} return
        if {![info exists ::questlog_cost_loaded]} {
            source [file join $::questlog_root lib cost.tcl]
            set ::questlog_cost_loaded 1
        }
        set r [::questlog::cost::parse_file $path]
        thread::send -async $tid [list {*}$reply $path $epoch $r]
    }
}

# Build the pool: fixed-size (minworkers = maxworkers, so the pass
# parallelises past the single worker a min-0 pool would lazily grow,
# issue #56), workers initialised with the same prelude the search fan-out
# uses plus the job procs registered by this file and, when the scan layer
# is loaded, its chunk worker. No-op without the Thread package; available
# then reports false and callers fall back to their single-thread paths.
proc ::questlog::jobpool::init {root} {
    variable Pool
    if {![::questlog::search::thread_available]} { return 0 }
    if {$Pool ne ""} { return 1 }
    tsv::set questlog scan_epoch 0
    tsv::set questlog cost_epoch 0
    set initcmd "package require Tcl 9\npackage require Thread\n"
    append initcmd "set ::questlog_root [list $root]\n"
    append initcmd [::questlog::search::worker_prelude $root]
    append initcmd $::questlog::jobpool::WorkerProcs
    if {[info exists ::questlog::scan::WorkerScript]} {
        append initcmd \n $::questlog::scan::WorkerScript
    }
    set n [::questlog::config::get pool_workers]
    set Pool [tpool::create -minworkers $n -maxworkers $n -initcmd $initcmd]
    return 1
}

proc ::questlog::jobpool::available {} {
    variable Pool
    return [expr {$Pool ne ""}]
}

# Post one job. -detached: the pool retains no result for an unreaped
# tpool::get, since replies travel by thread::send from the job body.
proc ::questlog::jobpool::post {script} {
    variable Pool
    tpool::post -detached -nowait $Pool $script
}

# Bump a pass's shared epoch (which = scan|cost): every job queued or running
# under the old epoch no-ops at its next check. Returns the new epoch.
proc ::questlog::jobpool::bump {which} {
    return [tsv::incr questlog ${which}_epoch]
}

proc ::questlog::jobpool::epoch {which} {
    return [tsv::get questlog ${which}_epoch]
}

proc ::questlog::jobpool::release {} {
    variable Pool
    if {$Pool eq ""} return
    catch {tpool::release $Pool}
    set Pool ""
}
