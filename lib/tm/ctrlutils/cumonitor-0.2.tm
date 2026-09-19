# cumonitor -- a provider-agnostic directory monitor.
# Description: a provider-agnostic directory monitor (polling)
# Category: Tk · controllers
#
# Watches one directory through the provider interface and fires a callback
# when its contents change (a file added, removed, resized, or re-timed). It
# polls `list` on an interval and diffs a signature of the entries, rather than
# using an OS watch (inotify): polling is the only mechanism that works the
# same over a local filesystem, a ZIP, or a remote provider, none of which
# share a change-notification API. A local-only fast path could be added later
# for providers that can push events, but the poll is the portable floor.
#
# Like cufileops this is a CONTROLLER, not a widget and not pure logic: it
# wires a timer + provider polling to a refresh callback on an existing view.
# It depends only on the provider interface, so it lives in ctrlutils.
#
#   ctrlutils::cumonitor::install $f $prov ?-interval ms? ?-onchange script?
#     $f          an identity token for this view (e.g. a tab frame)
#     $prov       the provider
#     -interval   poll period in ms (default 2000)
#     -onchange   script run when the watched dir changes (appended: the dir)
#   ctrlutils::cumonitor::watch $f $dir     -- (re)point the monitor at a dir
#   ctrlutils::cumonitor::poke  $f          -- re-snapshot now without firing
#   ctrlutils::cumonitor::stop  $f          -- stop polling, forget state
#
# The monitor never fires on the first snapshot of a directory (that is the
# baseline), only on a real change from it. Switching directories re-baselines
# silently, so navigating does not look like a change.

namespace eval ::ctrlutils::cumonitor {
    variable state
}

proc ::ctrlutils::cumonitor::install {f prov args} {
    variable state
    set interval 2000
    set onchange ""
    foreach {k v} $args {
        switch -- $k {
            -interval { set interval $v }
            -onchange { set onchange $v }
            default   {
                return -code error -errorcode [list CTRLUTILS CUMONITOR OPTION $k] \
                    "unknown option \"$k\"\nKnown: -interval -onchange"
            }
        }
    }
    dict set state $f prov     $prov
    dict set state $f interval $interval
    dict set state $f onchange $onchange
    dict set state $f dir      ""
    dict set state $f sig      ""
    dict set state $f after    ""
    return
}

# Point the monitor at a directory. Takes a fresh baseline snapshot (no fire)
# and (re)starts the poll loop.
proc ::ctrlutils::cumonitor::watch {f dir} {
    variable state
    if {![dict exists $state $f]} { error "cumonitor: $f not installed" }
    _cancel $f
    dict set state $f dir $dir
    dict set state $f sig [_snapshot $f $dir]
    _arm $f
    return
}

# Re-baseline the current directory now, without firing the callback. Call this
# after the app itself changes the directory (create/delete/paste) so the
# monitor does not then report the app's own change back to it.
proc ::ctrlutils::cumonitor::poke {f} {
    variable state
    if {![dict exists $state $f]} return
    set dir [dict get $state $f dir]
    if {$dir eq ""} return
    dict set state $f sig [_snapshot $f $dir]
    return
}

proc ::ctrlutils::cumonitor::stop {f} {
    variable state
    if {![dict exists $state $f]} return
    _cancel $f
    dict unset state $f
    return
}

# ---- internals ------------------------------------------------------------

# A signature of a directory: a sorted list of name/type/size/mtime per entry,
# so any add, remove, rename, resize or mtime change alters it. Sorting makes
# it order-independent (list order from a provider is not guaranteed stable).
proc ::ctrlutils::cumonitor::_snapshot {f dir} {
    variable state
    set prov [dict get $state $f prov]
    if {[catch {$prov list $dir} entries]} {
        # a vanished or unreadable dir is itself a change vs a readable one;
        # represent it with a sentinel so the diff notices.
        return "<unreadable>"
    }
    set rows {}
    foreach e $entries {
        set name [dict get $e name]
        set type [dict get $e type]
        set size [expr {[dict exists $e size] ? [dict get $e size] : ""}]
        set mt   [expr {[dict exists $e mtime] ? [dict get $e mtime] : ""}]
        lappend rows [list $name $type $size $mt]
    }
    return [lsort $rows]
}

proc ::ctrlutils::cumonitor::_arm {f} {
    variable state
    if {![dict exists $state $f]} return
    set ms [dict get $state $f interval]
    dict set state $f after [after $ms [list ::ctrlutils::cumonitor::_tick $f]]
    return
}

proc ::ctrlutils::cumonitor::_cancel {f} {
    variable state
    if {![dict exists $state $f]} return
    set a [dict get $state $f after]
    if {$a ne ""} { after cancel $a }
    dict set state $f after ""
    return
}

proc ::ctrlutils::cumonitor::_tick {f} {
    variable state
    if {![dict exists $state $f]} return
    set dir [dict get $state $f dir]
    if {$dir eq ""} { _arm $f ; return }
    set now [_snapshot $f $dir]
    set old [dict get $state $f sig]
    if {$now ne $old} {
        dict set state $f sig $now
        set cb [dict get $state $f onchange]
        if {$cb ne ""} {
            # fire outside the tick's own error scope; a broken callback must
            # not kill the poll loop.
            if {[catch {uplevel #0 [list {*}$cb $dir]} err]} {
                # keep monitoring; surface nothing here (controller stays quiet)
            }
        }
    }
    _arm $f
    return
}

package provide ctrlutils::cumonitor 0.2
