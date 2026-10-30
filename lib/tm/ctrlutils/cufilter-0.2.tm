# cufilter -- a live filter box for a file list.
# Description: a live filter box for a file list
# Category: Tk · controllers
#
# Wires a text entry to a tkufilelist's name filter: as the user types, the list
# shows only matching files (directories always stay, so navigation still
# works). The typed text becomes a glob: bare text is wrapped as *text* so a
# substring matches; a text containing * or ? is used as-is for full glob power.
#
# Like cufileops and cumonitor this is a CONTROLLER, not a widget and not pure
# logic: it wires an entry's keystrokes to a widget method. It depends only on
# tkufilelist (a tkutils widget), so it lives in ctrlutils.
#
#   ctrlutils::cufilter::widget $path $listwidget   -- build the filter box
#     $path        the entry widget path to create
#     $listwidget  the tkufilelist to filter
#   ctrlutils::cufilter::clear $path                -- empty the box, show all
#
# The box also clears on Escape and refocuses the list, so filtering never traps
# keyboard focus.
#
#   ctrlutils::cufilter::lastError $path            -- message of the last failure
#
# A filter that cannot be applied puts the entry into the ttk state "invalid",
# sends <<CufilterError>> to $path and keeps the message for lastError; the
# next successful filter clears it. Up to 0.1 the error was caught silently
# (no dialog on purpose: the filter runs on every keystroke).

catch {package require msgcat}

namespace eval ::ctrlutils::cufilter {
    variable state
}

# _ text -- user-visible text through msgcat when loaded (as cufileops); an
# application sets translations with ::msgcat::mcset in ::ctrlutils.
proc ::ctrlutils::cufilter::_ {s args} {
    if {[llength [info commands ::msgcat::mc]]} {
        return [::msgcat::mc $s {*}$args]
    }
    if {[llength $args]} { return [format $s {*}$args] }
    return $s
}

proc ::ctrlutils::cufilter::widget {path listwidget} {
    variable state
    ttk::frame $path
    ttk::label $path.l -text [_ "Filter:"]
    ttk::entry $path.e -textvariable ::ctrlutils::cufilter::state($path,text)
    ttk::button $path.x -text [_ "x"] -width 2 \
        -command [list ::ctrlutils::cufilter::clear $path]
    pack $path.l -side left -padx {4 2}
    pack $path.e -side left -fill x -expand 1
    pack $path.x -side left -padx {2 4}

    set state($path,list) $listwidget
    set state($path,text) ""

    # live update on every keystroke; Escape clears and returns focus to list
    bind $path.e <KeyRelease> [list ::ctrlutils::cufilter::_apply $path]
    bind $path.e <Escape>     [list ::ctrlutils::cufilter::clear $path]
    return $path
}

proc ::ctrlutils::cufilter::clear {path} {
    variable state
    set state($path,text) ""
    _apply $path
    catch {focus [set state($path,list)]}
    return
}

# ---- internals ------------------------------------------------------------
proc ::ctrlutils::cufilter::_apply {path} {
    variable state
    if {![info exists state($path,list)]} return
    set txt [string trim $state($path,text)]
    if {$txt eq ""} {
        set glob ""
    } elseif {[string match {*[*?]*} $txt]} {
        set glob $txt        ;# user typed a real glob, honor it
    } else {
        set glob *$txt*      ;# bare text -> substring match
    }
    if {[catch {::tkutils::tkufilelist::setFilter [set state($path,list)] $glob} e]} {
        set state($path,error) $e
        catch {$path.e state invalid}
        event generate $path <<CufilterError>> -when tail
    } else {
        set state($path,error) ""
        catch {$path.e state !invalid}
    }
    return
}

proc ::ctrlutils::cufilter::lastError {path} {
    variable state
    if {[info exists state($path,error)]} { return $state($path,error) }
    return ""
}

package provide ctrlutils::cufilter 0.2
