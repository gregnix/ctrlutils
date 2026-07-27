# cufileops -- a capability-driven file-operations controller for a file list.
#
# New Folder / Rename / Delete / Copy / Paste, each shown only when the provider
# actually supports the underlying operation (mkdir / move / delete / get+put).
# A read-only provider (a ZIP archive) therefore offers none of the writing
# ones -- the caps of the provider drive the menu, so the UI never offers
# something that would fail.
#
# Delete asks for confirmation. Rename and New Folder prompt for a name.
# After any change the list is refreshed so the result is visible at once.
#
# This is a CONTROLLER, not a widget and not pure logic: it wires events
# (right-click, keys) on an existing list widget to provider operations. It
# depends only on the provider interface (any tclutils provider) and on
# tkutils widgets (context menu, dialogs, the file list) -- never on a specific
# application. It therefore lives in ctrlutils, the glue layer between the
# tclutils logic and the tkutils widgets, and is reusable by any app built on
# the provider abstraction.
#
#   ctrlutils::cufileops::install $f $prov $listwidget {refreshcmd}
#     $f          an identity token for this view (e.g. a tab frame)
#     $prov       the provider
#     $listwidget the tkufilelist path
#     refreshcmd  a script run after a successful change (re-reads the dir)

package require tkutils::tkucontextmenu
package require tkutils::tkudialog
# tuopen (open a file with the OS default app) is optional: if it is not on the
# path, the "Open" entry falls back to launching via exec, and only "Open
# with..." (which uses exec directly) is offered.
catch {package require tclutils::tuopen}

namespace eval ::ctrlutils::cufileops {
    variable state
}

# Attach a right-click menu to the list. The menu is rebuilt on each show from
# the provider's caps, so it always reflects what is actually possible.
proc ::ctrlutils::cufileops::install {f prov listwidget refreshcmd args} {
    variable state
    set state($f,prov)    $prov
    set state($f,list)    $listwidget
    set state($f,refresh) $refreshcmd
    # optional -onop callback: called with an operation-record dict after each
    # successful op, so an observer (e.g. ctrlutils::cuundo) can record it for
    # undo. cufileops stays unaware of who observes -- it just emits records.
    array set o {-onop ""}
    array set o $args
    set state($f,onop) $o(-onop)

    # tkufilelist creates the tablelist at its own path, so the table body is
    # $listwidget.tbl. A right-click first selects the row under the pointer
    # (so the menu acts on what was clicked, not on a stale selection), then
    # pops up. %x/%y are widget-relative (for row lookup); %X/%Y are screen
    # coordinates (for placing the menu).
    set tbl $listwidget.tbl
    set handler [list ::ctrlutils::cufileops::_rightclick $f $tbl]
    bind $tbl.body <Button-3> "$handler %x %y %X %Y ; break"

    # Keyboard shortcuts on the list body, routed to the same operations. Each
    # handler checks caps and the selection, so a key that does not apply here
    # simply does nothing. Delete still asks for confirmation.
    bind $tbl.body <Delete>    "[list ::ctrlutils::cufileops::_keyDelete $f] ; break"
    bind $tbl.body <F2>        "[list ::ctrlutils::cufileops::_keyRename $f] ; break"
    bind $tbl.body <Control-c> "[list ::ctrlutils::cufileops::_keyCopy   $f] ; break"
    bind $tbl.body <Control-v> "[list ::ctrlutils::cufileops::_keyPaste  $f] ; break"
    return
}

# ---- keyboard handlers (caps- and selection-aware) ------------------------
proc ::ctrlutils::cufileops::_keyDelete {f} {
    variable state
    if {"delete" ni [$state($f,prov) caps]} return
    set e [::tkutils::tkufilelist::selectedEntry $state($f,list)]
    if {$e ne ""} { delete $f $e }
}
proc ::ctrlutils::cufileops::_keyRename {f} {
    variable state
    if {"move" ni [$state($f,prov) caps]} return
    set e [::tkutils::tkufilelist::selectedEntry $state($f,list)]
    if {$e ne ""} { rename $f $e }
}
proc ::ctrlutils::cufileops::_keyCopy {f} {
    variable state
    if {"get" ni [$state($f,prov) caps]} return
    set e [::tkutils::tkufilelist::selectedEntry $state($f,list)]
    if {$e ne "" && [dict get $e type] eq "file"} { copy $f $e }
}
proc ::ctrlutils::cufileops::_keyPaste {f} {
    variable state
    if {[_haveClip] && "put" in [$state($f,prov) caps]} { paste $f }
}

# Directory currently shown, via tkufilelist's public accessor (no reaching
# into another module's private state).
proc ::ctrlutils::cufileops::_curDir {f} {
    variable state
    return [::tkutils::tkufilelist::dir $state($f,list)]
}

# Right-click: select the row under the pointer first (tablelist 'containing'
# maps a widget-y to a row, or -1 for none), so the menu acts on the clicked
# item, then pop up at the screen coordinates.
# Right-click: let tablelist's own click handling select the row under the
# pointer (a native Button-1 at the same spot), then pop up the menu on that
# selection. Using $tbl containing $y directly is off by one row here, because
# containing measures without the header while native click selection does
# not -- the classic tablelist coordinate mismatch. Deferring to tablelist's
# own selection avoids guessing the offset.
proc ::ctrlutils::cufileops::_rightclick {f tbl x y X Y} {
    event generate $tbl.body <Button-1> -x $x -y $y
    event generate $tbl.body <ButtonRelease-1> -x $x -y $y
    # the selection change is processed in the event loop; pop up after it has
    # settled so the menu reflects the row actually clicked.
    after idle [list ::ctrlutils::cufileops::_popup $f $X $Y]
}

proc ::ctrlutils::cufileops::_popup {f X Y} {
    variable state ; variable clip
    set prov $state($f,prov)
    set caps [$prov caps]

    # (re)build a fresh menu reflecting current caps
    set menu $f.ctxmenu
    catch {destroy $menu}
    ::tkutils::tkucontextmenu::create $menu

    set any 0
    if {"mkdir" in $caps} {
        ::tkutils::tkucontextmenu::addItem $menu "New Folder" \
            -command [list ::ctrlutils::cufileops::newFolder $f]
        set any 1
    }
    set entry [::tkutils::tkufilelist::selectedEntry $state($f,list)]
    if {$entry ne ""} {
        # Open / Open with -- for files the provider can read. tuopen launches
        # the OS default (or a chosen program). A local path opens directly; a
        # provider-backed file is written to a temp file first.
        if {[dict get $entry type] eq "file" && "get" in $caps} {
            ::tkutils::tkucontextmenu::addItem $menu "Open" \
                -command [list ::ctrlutils::cufileops::openFile $f $entry]
            ::tkutils::tkucontextmenu::addItem $menu "Open with..." \
                -command [list ::ctrlutils::cufileops::openWith $f $entry]
            ::tkutils::tkucontextmenu::addSeparator $menu
            set any 1
        }
        if {"move" in $caps} {
            ::tkutils::tkucontextmenu::addItem $menu "Rename" \
                -command [list ::ctrlutils::cufileops::rename $f $entry]
            set any 1
        }
        # Copy is app-level get+put (recursive for directories), so it works
        # across providers -- e.g. pull a file or a whole folder out of a ZIP.
        # A file needs source get; a directory needs source list and get.
        set etype [dict get $entry type]
        set canCopy [expr {
            ($etype eq "file" && "get" in $caps) ||
            ($etype eq "dir"  && "list" in $caps && "get" in $caps)
        }]
        if {$canCopy} {
            ::tkutils::tkucontextmenu::addItem $menu "Copy" \
                -command [list ::ctrlutils::cufileops::copy $f $entry]
            set any 1
        }
        if {"delete" in $caps} {
            ::tkutils::tkucontextmenu::addItem $menu "Delete" \
                -command [list ::ctrlutils::cufileops::delete $f $entry]
            set any 1
        }
    }
    # Paste appears when something is on the clipboard and THIS provider can
    # write it. A file needs put; a directory needs put and mkdir (to recreate
    # the tree). Cross-provider: read via the source, write here.
    if {[_haveClip]} {
        set clipDir [expr {[dict get $clip type] eq "dir"}]
        set canPaste [expr {
            (!$clipDir && "put" in $caps) ||
            ( $clipDir && "put" in $caps && "mkdir" in $caps)
        }]
        if {$canPaste} {
            ::tkutils::tkucontextmenu::addItem $menu "Paste" \
                -command [list ::ctrlutils::cufileops::paste $f]
            set any 1
        }
    }
    if {!$any} {
        ::tkutils::tkucontextmenu::addItem $menu "(read-only)" -state disabled
    }
    ::tkutils::tkucontextmenu::show $menu $X $Y
}

# ---- operations -----------------------------------------------------------

# Materialize an entry's bytes to a real local path so an external program can
# open it. If the path is already an existing local file (local provider), it is
# used as-is; otherwise the provider's bytes are written to a temp file whose
# name keeps the original extension (so the opener picks the right app).
proc ::ctrlutils::cufileops::_localPath {f entry} {
    variable state
    set path [dict get $entry path]
    if {[file exists $path]} { return $path }
    set data [$state($f,prov) get $path]
    set ext  [file extension [dict get $entry name]]
    set tmp  [file join [_tmpdir] \
                  "explorer-[pid]-[clock clicks]$ext"]
    set ch [::open $tmp wb] ; puts -nonewline $ch $data ; close $ch
    return $tmp
}

# a tiny temp-dir helper without extra deps
proc ::ctrlutils::cufileops::_tmpdir {} {
    foreach v {TMPDIR TEMP TMP} {
        if {[info exists ::env($v)] && [file isdirectory $::env($v)]} { return $::env($v) }
    }
    return [expr {[file isdirectory /tmp] ? "/tmp" : [pwd]}]
}

# Open a file with the OS default application.
proc ::ctrlutils::cufileops::openFile {f entry} {
    variable state
    if {[catch {_localPath $f $entry} path]} {
        ::tkutils::tkudialog::showError "Could not read file:\n$path" ; return
    }
    if {[llength [info commands ::tclutils::tuopen::launch]]} {
        if {[catch {::tclutils::tuopen::launch $path} e]} {
            ::tkutils::tkudialog::showError "Could not open:\n$e"
        }
        return
    }
    # fallback opener by platform
    set opener [expr {
        $::tcl_platform(platform) eq "windows" ? {cmd /c start ""} :
        ($::tcl_platform(os) eq "Darwin" ? {open} : {xdg-open})
    }]
    if {[catch {exec {*}$opener $path &} e]} {
        ::tkutils::tkudialog::showError "Could not open:\n$e"
    }
}

# Open a file with a program the user names.
proc ::ctrlutils::cufileops::openWith {f entry} {
    variable state
    set prog [::tkutils::tkudialog::input -title "Open with" \
        -message "Program to open '[dict get $entry name]' with:"]
    if {[string trim $prog] eq ""} return
    if {[catch {_localPath $f $entry} path]} {
        ::tkutils::tkudialog::showError "Could not read file:\n$path" ; return
    }
    # launch the chosen program detached, with the file as its argument
    if {[catch {exec {*}$prog $path &} e]} {
        ::tkutils::tkudialog::showError "Could not open with '$prog':\n$e"
    }
}

proc ::ctrlutils::cufileops::newFolder {f} {
    variable state
    set name [::tkutils::tkudialog::input -title "New Folder" \
        -message "Name of the new folder:"]
    if {$name eq ""} return
    set dir [_curDir $f]
    set path [_join $dir $name]
    if {[catch {$state($f,prov) mkdir $path} e]} {
        ::tkutils::tkudialog::showError "Could not create folder:\n$e"
        return
    }
    _notify $f [dict create op mkdir path $path]
    _refresh $f
}

proc ::ctrlutils::cufileops::rename {f entry} {
    variable state
    set old [dict get $entry name]
    set name [::tkutils::tkudialog::input -title "Rename" \
        -message "New name for '$old':" -initial $old]
    if {$name eq "" || $name eq $old} return
    set dir [_curDir $f]
    set from [dict get $entry path]
    set to   [_join $dir $name]
    if {[catch {$state($f,prov) move $from $to} e]} {
        ::tkutils::tkudialog::showError "Could not rename:\n$e"
        return
    }
    _notify $f [dict create op rename from $from to $to \
                    type [dict get $entry type]]
    _refresh $f
}

proc ::ctrlutils::cufileops::delete {f entry} {
    variable state
    set name [dict get $entry name]
    set what [expr {[dict get $entry type] eq "dir" ? "folder" : "file"}]
    if {![::tkutils::tkudialog::confirm "Delete $what '$name'?"]} return
    set path [dict get $entry path]
    set type [dict get $entry type]
    # Capture the content BEFORE deleting, so the op can be undone. For a file
    # that is its bytes; for a directory, the whole subtree as a nested record.
    # Only attempted if the provider can read (get/list); otherwise undo of this
    # delete will not be offered.
    set saved ""
    catch {set saved [_snapshot $state($f,prov) $path $type]}
    if {[catch {$state($f,prov) delete $path} e]} {
        ::tkutils::tkudialog::showError "Could not delete:\n$e"
        return
    }
    _notify $f [dict create op delete path $path type $type saved $saved]
    _refresh $f
}

# Snapshot a path's content for undo: a file -> {type file bytes B}, a directory
# -> {type dir children {name -> snapshot ...}}. Recurses via the provider.
proc ::ctrlutils::cufileops::_snapshot {prov path type} {
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

# Restore a snapshot at $path through the provider (the inverse of delete).
proc ::ctrlutils::cufileops::_restore {prov path snap} {
    if {[dict get $snap type] eq "file"} {
        $prov put $path [dict get $snap bytes]
    } else {
        $prov mkdir $path
        dict for {nm sub} [dict get $snap children] {
            _restore $prov [_join $path $nm] $sub
        }
    }
}

# ---- clipboard (module-wide, shared across tabs and providers) ------------
# Holds one copied file: the source provider, its path and name. Copy/Paste
# go through get+put, so a file can be pasted into any provider that can write
# -- including from a read-only ZIP into a local directory.
namespace eval ::ctrlutils::cufileops {
    variable clip {}   ;# {prov P path X name N} or empty
}

proc ::ctrlutils::cufileops::_haveClip {} {
    variable clip
    return [expr {[llength $clip] > 0}]
}

proc ::ctrlutils::cufileops::copy {f entry} {
    variable state ; variable clip
    set clip [list prov $state($f,prov) \
                   path [dict get $entry path] \
                   name [dict get $entry name] \
                   type [dict get $entry type]]
    return
}

proc ::ctrlutils::cufileops::paste {f} {
    variable state ; variable clip
    if {![_haveClip]} return
    set src   [dict get $clip prov]
    set from  [dict get $clip path]
    set name  [dict get $clip name]
    set type  [dict get $clip type]
    set dst   $state($f,prov)
    set dir   [_curDir $f]
    # avoid clobbering: pick a free "name (copy)" instead of overwriting.
    set to [_uniqueName $dst $dir $name]
    if {$type eq "dir"} {
        if {[catch {_copyTree $src $from $dst $to} e]} {
            ::tkutils::tkudialog::showError "Could not paste folder:\n$e"
            return
        }
    } else {
        if {[catch {$src get $from} data]} {
            ::tkutils::tkudialog::showError "Could not read source:\n$data"
            return
        }
        if {[catch {$dst put $to $data} e]} {
            ::tkutils::tkudialog::showError "Could not paste:\n$e"
            return
        }
    }
    _notify $f [dict create op paste path $to type $type]
    _refresh $f
}

# Recursively copy a directory subtree from one provider to another: create the
# destination directory, then copy each child (files via get+put, subdirs by
# recursion). Works across providers, so a whole folder can be pulled out of a
# ZIP into a local directory.
proc ::ctrlutils::cufileops::_copyTree {src from dst to} {
    $dst mkdir $to
    foreach e [$src list $from] {
        set nm [dict get $e name]
        if {$nm eq "." || $nm eq ".."} continue
        set childFrom [dict get $e path]
        set childTo   [_join $to $nm]
        if {[dict get $e type] eq "dir"} {
            _copyTree $src $childFrom $dst $childTo
        } else {
            $dst put $childTo [$src get $childFrom]
        }
    }
}

# Return a path in $dir for $name that does not already exist under $prov.
# If $name is free, use it; otherwise append " (copy)", " (copy 2)", ...
# before the extension.
proc ::ctrlutils::cufileops::_uniqueName {prov dir name} {
    set path [_join $dir $name]
    if {[catch {$prov stat $path}]} { return $path }   ;# free
    set ext  [file extension $name]
    set base [file rootname $name]
    set n 1
    while {1} {
        set suffix [expr {$n == 1 ? " (copy)" : " (copy $n)"}]
        set cand [_join $dir "$base$suffix$ext"]
        if {[catch {$prov stat $cand}]} { return $cand }
        incr n
    }
}

# ---- helpers --------------------------------------------------------------
proc ::ctrlutils::cufileops::_join {dir name} {
    if {$dir eq "/" || $dir eq ""} { return "/$name" }
    return "[string trimright $dir /]/$name"
}

# Emit an operation record to the -onop observer, if any. The record is a dict
# describing what was done, with enough to reverse it (see cuundo).
proc ::ctrlutils::cufileops::_notify {f record} {
    variable state
    if {[info exists state($f,onop)] && $state($f,onop) ne ""} {
        uplevel #0 [list {*}$state($f,onop) $record]
    }
}

proc ::ctrlutils::cufileops::_refresh {f} {
    variable state
    if {$state($f,refresh) ne ""} { uplevel #0 $state($f,refresh) }
}

package provide ctrlutils::cufileops 0.1
