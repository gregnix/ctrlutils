# cuundo -- undo/redo for cufileops file operations.
#
# cufileops emits an operation record after each successful op (via its -onop
# callback). cuundo records those on an undo stack and reverses them on request;
# reversing pushes onto a redo stack so the reversal itself can be redone.
#
# It reverses each operation through the provider:
#   rename from->to   undo: move to->from
#   mkdir path        undo: delete path
#   paste path        undo: delete path        (the newly created target)
#   delete path saved undo: restore saved at path (bytes for a file, the whole
#                            subtree for a directory -- captured before deleting)
#
# Like the other ctrlutils controllers this is a CONTROLLER: it wires behavior
# (the undo/redo stacks and keybindings) onto an existing file view, driven by
# the operation records cufileops emits. It does not know about widgets beyond
# the file list it binds keys to, and it reverses through the same provider.
#
#   set u [ctrlutils::cuundo::install $f $prov]
#   # wire cufileops to feed it:
#   ctrlutils::cufileops::install $f $prov $list $refresh \
#       -onop [list ctrlutils::cuundo::record $f]
#   ctrlutils::cuundo::undo $f
#   ctrlutils::cuundo::redo $f
#   ctrlutils::cuundo::canUndo $f  ;# / canRedo
#
# Binds Ctrl+Z / Ctrl+Shift+Z (and Ctrl+Y) on the list body when a widget is
# given.

package require Tcl 8.6-
package require tclutils::tuprovider

namespace eval ::ctrlutils::cuundo {
    variable state
}

proc ::ctrlutils::cuundo::install {f prov args} {
    variable state
    array set o {-list ""}
    array set o $args
    set state($f,prov) $prov
    set state($f,undo) {}
    set state($f,redo) {}
    set state($f,list) $o(-list)
    if {$o(-list) ne ""} {
        set b $o(-list).tbl.body
        bind $b <Control-z>       "[list ::ctrlutils::cuundo::undo $f] ; break"
        bind $b <Control-y>       "[list ::ctrlutils::cuundo::redo $f] ; break"
        bind $b <Control-Shift-Z> "[list ::ctrlutils::cuundo::redo $f] ; break"
    }
    return $f
}

# Record an operation (the -onop callback target). New activity clears redo.
proc ::ctrlutils::cuundo::record {f rec} {
    variable state
    if {![info exists state($f,undo)]} return
    lappend state($f,undo) $rec
    set state($f,redo) {}
    return
}

proc ::ctrlutils::cuundo::canUndo {f} {
    variable state
    expr {[info exists state($f,undo)] && [llength $state($f,undo)] > 0}
}
proc ::ctrlutils::cuundo::canRedo {f} {
    variable state
    expr {[info exists state($f,redo)] && [llength $state($f,redo)] > 0}
}

proc ::ctrlutils::cuundo::undo {f} {
    variable state
    if {![canUndo $f]} return
    set rec [lindex $state($f,undo) end]
    set state($f,undo) [lrange $state($f,undo) 0 end-1]
    # _reverse may annotate rec (e.g. snapshot a created path) so redo is exact.
    if {[catch {_reverse $f rec} e]} {
        catch {::tkutils::tkudialog::showError "Undo failed:\n$e"}
        # put it back so the stack is not lost on a failed undo
        lappend state($f,undo) $rec
        return
    }
    lappend state($f,redo) $rec
    _refresh $f
}

proc ::ctrlutils::cuundo::redo {f} {
    variable state
    if {![canRedo $f]} return
    set rec [lindex $state($f,redo) end]
    set state($f,redo) [lrange $state($f,redo) 0 end-1]
    if {[catch {_apply $f $rec} e]} {
        catch {::tkutils::tkudialog::showError "Redo failed:\n$e"}
        return
    }
    lappend state($f,undo) $rec
    _refresh $f
}

proc ::ctrlutils::cuundo::clear {f} {
    variable state
    set state($f,undo) {}
    set state($f,redo) {}
}

# ---- reversing and re-applying -------------------------------------------
# Undo removes the effect; to keep redo symmetric, undo of a create (paste/
# mkdir) snapshots what it removes into the record so redo can put it back.
proc ::ctrlutils::cuundo::_reverse {f recVar} {
    variable state
    upvar 1 $recVar r
    set p $state($f,prov)
    switch -- [dict get $r op] {
        rename { $p move [dict get $r to] [dict get $r from] }
        mkdir  {
            dict set r snap [::ctrlutils::cuundo::_snapshot $p [dict get $r path] dir]
            $p delete [dict get $r path]
        }
        paste  {
            dict set r snap [::ctrlutils::cuundo::_snapshot $p \
                                 [dict get $r path] [dict get $r type]]
            $p delete [dict get $r path]
        }
        movex  {
            # cross-provider move: undo = delete at destination, restore source.
            # Providers are carried in the record (they may differ from the tab
            # provider). The source snapshot was taken by cufileops at cut time.
            set sp [dict get $r srcprov] ; set dp [dict get $r dstprov]
            set saved [dict get $r saved]
            if {$saved eq ""} { error "no saved content to restore the source" }
            $dp delete [dict get $r to]
            ::ctrlutils::cuundo::_restore $sp [dict get $r from] $saved
        }
        delete {
            set saved [dict get $r saved]
            if {$saved eq ""} { error "no saved content to restore" }
            ::ctrlutils::cuundo::_restore $p [dict get $r path] $saved
        }
        default { error "cannot undo op [dict get $r op]" }
    }
}

# Re-apply an operation (redo): the forward direction again.
proc ::ctrlutils::cuundo::_apply {f rec} {
    variable state
    set p $state($f,prov)
    switch -- [dict get $rec op] {
        rename { $p move [dict get $rec from] [dict get $rec to] }
        mkdir  {
            if {[dict exists $rec snap]} {
                ::ctrlutils::cuundo::_restore $p [dict get $rec path] [dict get $rec snap]
            } else { $p mkdir [dict get $rec path] }
        }
        paste  {
            if {![dict exists $rec snap]} { error "cannot redo paste (no snapshot)" }
            ::ctrlutils::cuundo::_restore $p [dict get $rec path] [dict get $rec snap]
        }
        movex  {
            # redo cross-provider move: put the content back at the destination
            # (from the source snapshot) and delete it at the source again.
            set sp [dict get $rec srcprov] ; set dp [dict get $rec dstprov]
            set saved [dict get $rec saved]
            if {$saved eq ""} { error "cannot redo move (no snapshot)" }
            ::ctrlutils::cuundo::_restore $dp [dict get $rec to] $saved
            $sp delete [dict get $rec from]
        }
        delete { $p delete [dict get $rec path] }
        default { error "cannot redo op [dict get $rec op]" }
    }
}

proc ::ctrlutils::cuundo::_refresh {f} {
    variable state
    # reuse cufileops' refresh path if the app wired one through the list
    catch {::ctrlutils::cufileops::_refresh $f}
}

# Snapshot / restore a path's content through the provider. These are pure
# provider logic (no Tk), kept here so cuundo can run without loading the GUI
# side of cufileops. A file -> {type file bytes B}; a directory -> {type dir
# children {name -> snapshot ...}}.
proc ::ctrlutils::cuundo::_snapshot {prov path type} {
    if {$type eq "file"} {
        return [dict create type file bytes [$prov get $path]]
    }
    set children {}
    foreach e [$prov list $path] {
        set nm [dict get $e name]
        if {$nm eq "." || $nm eq ".."} continue
        dict set children $nm [_snapshot $prov [dict get $e path] [dict get $e type]]
    }
    return [dict create type dir children $children]
}

proc ::ctrlutils::cuundo::_restore {prov path snap} {
    if {[dict get $snap type] eq "file"} {
        $prov put $path [dict get $snap bytes]
    } else {
        $prov mkdir $path
        dict for {nm sub} [dict get $snap children] {
            _restore $prov [_join $path $nm] $sub
        }
    }
}

proc ::ctrlutils::cuundo::_join {dir name} {
    if {$dir eq "/" || $dir eq ""} { return "/$name" }
    return "[string trimright $dir /]/$name"
}

package provide ctrlutils::cuundo 0.1
