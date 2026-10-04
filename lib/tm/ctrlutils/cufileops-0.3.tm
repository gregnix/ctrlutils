# cufileops -- a capability-driven file-operations controller for a file list.
# Description: capability-driven file operations (menu, keys, copy/paste, dialogs) for a file list
# Category: Tk · controllers
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
package require tkutils::tkudialog 0.3
# tuopen (open a file with the OS default app) is optional: if it is not on the
# path, the "Open" entry falls back to launching via exec, and only "Open
# with..." (which uses exec directly) is offered.
catch {package require tclutils::tuopen}

namespace eval ::ctrlutils::cufileops {
    variable state
    # "Open with" app registry, keyed by lowercase file extension (with dot):
    #   ext -> {default CMD apps {CMD CMD ...}}
    # where each CMD is a launcher command string (may contain arguments, e.g.
    # "code -w"). Persisted as a plain Tcl dict via tuopen's config dir, so it
    # survives restarts and lives in the platform's standard config location.
    variable owApp   "explorer"        ;# app name for the config dir (override-able)
    variable owFile  ""                ;# explicit config file path (tests set this)
    variable owCache ""                ;# in-memory copy of the registry dict
    variable owLoaded 0
    variable workdir ""                ;# process-private temp dir for Open
    variable exitHook 0
}

# Path to the registry file. Uses an explicit override if set, else tuopen's
# per-application config dir (XDG on Linux, AppData on Windows, Application
# Support on macOS). Falls back to a temp path if tuopen is unavailable.
proc ::ctrlutils::cufileops::_owFile {} {
    variable owFile ; variable owApp
    if {$owFile ne ""} { return $owFile }
    if {[llength [info commands ::tclutils::tuopen::configFile]]} {
        return [::tclutils::tuopen::configFile $owApp openwith.dict]
    }
    return [file join [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}] \
                ${owApp}-openwith.dict]
}

# Load the registry dict (cached). A missing or unreadable file yields an empty
# registry rather than an error.
proc ::ctrlutils::cufileops::_owLoad {} {
    variable owCache ; variable owLoaded
    if {$owLoaded} { return $owCache }
    set owCache {}
    set path [_owFile]
    if {[file exists $path]} {
        catch {
            set fh [open $path r] ; fconfigure $fh -encoding utf-8
            set data [read $fh] ; close $fh
            if {[string trim $data] ne "" && [string is list $data] \
                    && [expr {[llength $data] % 2 == 0}]} {
                set owCache $data
            }
        }
    }
    set owLoaded 1
    return $owCache
}

# Persist the registry dict, creating the config dir if needed. Returns 1 on
# success, 0 on failure (the in-memory copy is updated either way).
proc ::ctrlutils::cufileops::_owSave {d} {
    variable owCache ; variable owLoaded
    set owCache $d ; set owLoaded 1
    set path [_owFile]
    if {[catch {
        file mkdir [file dirname $path]
        set fh [open $path w] ; fconfigure $fh -encoding utf-8
        puts -nonewline $fh $d ; close $fh
    }]} { return 0 }
    return 1
}

# Normalise an extension to the registry key: lowercase, keep the dot. A file
# with no extension maps to the empty key "".
proc ::ctrlutils::cufileops::_owKey {name} {
    return [string tolower [file extension $name]]
}

# The list of registered app commands for a file's extension.
proc ::ctrlutils::cufileops::owApps {ext} {
    set d [_owLoad]
    if {[dict exists $d $ext apps]} { return [dict get $d $ext apps] }
    return {}
}

# The default app command for an extension, or "" if none set.
proc ::ctrlutils::cufileops::owDefault {ext} {
    set d [_owLoad]
    if {[dict exists $d $ext default]} { return [dict get $d $ext default] }
    return ""
}

# Add an app command to an extension's list (no duplicates). Persists.
proc ::ctrlutils::cufileops::owAddApp {ext app} {
    set app [string trim $app]
    if {$app eq ""} return
    set d [_owLoad]
    set apps [expr {[dict exists $d $ext apps] ? [dict get $d $ext apps] : {}}]
    if {$app ni $apps} { lappend apps $app }
    dict set d $ext apps $apps
    _owSave $d
}

# Remove an app from an extension's list; clears the default if it was that app.
proc ::ctrlutils::cufileops::owRemoveApp {ext app} {
    set d [_owLoad]
    if {![dict exists $d $ext apps]} return
    set apps [lsearch -all -inline -not -exact [dict get $d $ext apps] $app]
    dict set d $ext apps $apps
    if {[dict exists $d $ext default] && [dict get $d $ext default] eq $app} {
        dict set d $ext default ""
    }
    _owSave $d
}

# Set the default app for an extension (adds it to the list if new). Persists.
proc ::ctrlutils::cufileops::owSetDefault {ext app} {
    set app [string trim $app]
    set d [_owLoad]
    set apps [expr {[dict exists $d $ext apps] ? [dict get $d $ext apps] : {}}]
    if {$app ne "" && $app ni $apps} { lappend apps $app }
    dict set d $ext apps $apps
    dict set d $ext default $app
    _owSave $d
}

# Category catalog for suggestions: candidate launcher commands per kind of
# file. Only the ones actually installed (found on PATH) are offered, so the
# "Open with" list is useful out of the box instead of empty. Order = rough
# preference. Each entry's first word is what gets probed with auto_execok.
proc ::ctrlutils::cufileops::_owCatalog {} {
    return {
        tcleditor {alited tkcon}
        editor {{code -w} subl gedit kate mousepad geany gvim {emacs} nano vim nvim vi kwrite pluma notepad}
        image  {gimp eog gwenview eom ristretto feh nomacs {display} krita inkscape}
        pdf    {evince okular zathura qpdfview mupdf xpdf firefox}
        html   {firefox chromium chromium-browser google-chrome brave-browser epiphany}
        media  {vlc mpv totem}
    }
}

# Map an extension to one or more suggestion categories (most specific first).
proc ::ctrlutils::cufileops::_owCats {ext} {
    switch -- $ext {
        .tcl - .tm - .itcl - .itk - .tk - .test - .msg - .wish { return {tcleditor editor} }
        .png - .jpg - .jpeg - .gif - .bmp - .tif - .tiff - .ico - .webp - .ppm - .pgm { return {image editor} }
        .svg                                              { return {image editor} }
        .pdf                                              { return {pdf} }
        .html - .htm - .xhtml                             { return {html editor} }
        .mp4 - .mkv - .avi - .mov - .webm - .mp3 - .flac - .ogg - .wav { return {media} }
        default                                           { return {editor} }
    }
}

# Suggested launcher commands for an extension: the catalog entries for its
# category (or categories) that are actually installed. Cross-platform via
# auto_execok (checks PATH / known extensions). Excludes apps already registered.
proc ::ctrlutils::cufileops::_owSuggest {ext} {
    set out {}
    set have {}
    foreach cat [_owCats $ext] {
        if {![dict exists [_owCatalog] $cat]} continue
        foreach cmd [dict get [_owCatalog] $cat] {
            set exe [lindex $cmd 0]
            if {$exe in $have} continue
            if {[auto_execok $exe] ne ""} {
                lappend out $cmd
                lappend have $exe
            }
        }
    }
    # drop apps that are already registered for this extension
    set reg [owApps $ext]
    set res {}
    foreach cmd $out { if {$cmd ni $reg} { lappend res $cmd } }
    return $res
}

# Attach a right-click menu to the list. The menu is rebuilt on each show from
# the provider's caps, so it always reflects what is actually possible.
# _dlgParent f -- the toplevel of this view's list, or "" (tkudialog then
# falls back to the focus toplevel).
proc ::ctrlutils::cufileops::_dlgParent {f} {
    variable state
    if {$f ne "" && [info exists state($f,list)] && [winfo exists $state($f,list)]} {
        return [winfo toplevel $state($f,list)]
    }
    return ""
}

# _dlg f cmd ?arg ...? -- a tkudialog call with -parent set to this view's
# window. Up to 0.1 no dialog got -parent, and tkudialog 0.1 centred every one
# on the screen: with the Explorer on a second monitor, errors, prompts and
# confirmations opened on the other one.
proc ::ctrlutils::cufileops::_dlg {f cmd args} {
    set p [_dlgParent $f]
    if {$p ne ""} { lappend args -parent $p }
    return [::tkutils::tkudialog::$cmd {*}$args]
}

proc ::ctrlutils::cufileops::install {f prov listwidget refreshcmd args} {
    variable state
    set state($f,prov)    $prov
    set state($f,list)    $listwidget
    set state($f,refresh) $refreshcmd
    # optional -onop callback: called with an operation-record dict after each
    # successful op, so an observer (e.g. ctrlutils::cuundo) can record it for
    # undo. cufileops stays unaware of who observes -- it just emits records.
    # unknown options are an error naming the known ones (up to 0.1 they were
    # swallowed by `array set`: a typo like -onpo simply disabled undo)
    foreach {k v} $args {
        if {$k ni {-onop}} {
            return -code error -errorcode [list CTRLUTILS CUFILEOPS OPTION $k] \
                "unknown option \"$k\"\nKnown: -onop"
        }
    }
    if {[llength $args] % 2} {
        return -code error -errorcode {CTRLUTILS CUFILEOPS OPTION} \
            "missing value for option \"[lindex $args end]\""
    }
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
    # handler checks caps and the selection. Cut and Delete say so when the
    # source cannot delete; other keys that do not apply simply do nothing.
    # Delete still asks for confirmation when the cap is there.
    bind $tbl.body <Delete>    "[list ::ctrlutils::cufileops::_keyDelete $f] ; break"
    bind $tbl.body <F2>        "[list ::ctrlutils::cufileops::_keyRename $f] ; break"
    bind $tbl.body <Control-c> "[list ::ctrlutils::cufileops::_keyCopy   $f] ; break"
    bind $tbl.body <Control-x> "[list ::ctrlutils::cufileops::_keyCut    $f] ; break"
    bind $tbl.body <Control-v> "[list ::ctrlutils::cufileops::_keyPaste  $f] ; break"
    return
}

# ---- keyboard handlers (caps- and selection-aware) ------------------------
proc ::ctrlutils::cufileops::_keyDelete {f} {
    variable state
    if {"delete" ni [$state($f,prov) caps]} {
        _dlg $f showError "Delete is not available here (the source cannot delete)."
        return
    }
    set es [::tkutils::tkufilelist::selectedEntries $state($f,list)]
    if {[llength $es]} { delete $f {*}$es }
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
    # match the context menu: copy the whole selection, files AND directories
    set es [::tkutils::tkufilelist::selectedEntries $state($f,list)]
    if {[llength $es]} { copy $f {*}$es }
}

proc ::ctrlutils::cufileops::_keyCut {f} {
    variable state
    set caps [$state($f,prov) caps]
    if {"get" ni $caps || "delete" ni $caps} {
        _dlg $f showError "Cut is not available here (the source cannot delete)."
        return
    }
    set es [::tkutils::tkufilelist::selectedEntries $state($f,list)]
    if {[llength $es]} { cut $f {*}$es }
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
    # Snapshot before the synthetic click: a plain Button-1 replaces an
    # extended multi-selection with one row. File-manager behaviour: if the
    # clicked row was already selected, keep the whole selection.
    set before [$tbl curselection]
    event generate $tbl.body <Button-1> -x $x -y $y
    event generate $tbl.body <ButtonRelease-1> -x $x -y $y
    after idle [list ::ctrlutils::cufileops::_rightclickIdle $f $tbl $before $X $Y]
}

proc ::ctrlutils::cufileops::_rightclickIdle {f tbl before X Y} {
    set clicked [lindex [$tbl curselection] 0]
    if {$clicked ne "" && [llength $before] > 1 && $clicked in $before} {
        $tbl selection clear 0 end
        foreach r $before {
            $tbl selection set $r
        }
        catch {$tbl activate $clicked}
    }
    ::ctrlutils::cufileops::_popup $f $X $Y
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
    set selEntries [::tkutils::tkufilelist::selectedEntries $state($f,list)]
    if {![llength $selEntries] && $entry ne ""} { set selEntries [list $entry] }
    if {$entry ne ""} {
        # Open / Open with -- for files the provider can read. tuopen launches
        # the OS default (or a chosen program). A local path opens directly; a
        # provider-backed file is written to a temp file first.
        if {[dict get $entry type] eq "file" && "get" in $caps} {
            ::tkutils::tkucontextmenu::addItem $menu "Open" \
                -command [list ::ctrlutils::cufileops::openFile $f $entry]
            # if a default app is registered for this file type, offer it by
            # name -- one click, no dialog. (Double-click still uses the OS
            # default; this is a menu-only convenience.)
            set defApp [owDefault [_owKey [dict get $entry name]]]
            if {[string trim $defApp] ne ""} {
                ::tkutils::tkucontextmenu::addItem $menu "Open with $defApp" \
                    -command [list ::ctrlutils::cufileops::openWithDefault $f $entry]
            }
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
                -command [list ::ctrlutils::cufileops::copy $f {*}$selEntries]
            set any 1
        }
        # Cut = move: same read requirement as copy, PLUS delete on the source
        # (the source is removed after a successful paste). Cross-provider safe.
        if {$canCopy && "delete" in $caps} {
            ::tkutils::tkucontextmenu::addItem $menu "Cut" \
                -command [list ::ctrlutils::cufileops::cut $f {*}$selEntries]
            set any 1
        }
        if {"delete" in $caps} {
            ::tkutils::tkucontextmenu::addItem $menu "Delete" \
                -command [list ::ctrlutils::cufileops::delete $f {*}$selEntries]
            set any 1
        }
    }
    # Paste appears when something is on the clipboard and THIS provider can
    # write it. A file needs put; a directory needs put and mkdir (to recreate
    # the tree). Cross-provider: read via the source, write here.
    if {[_haveClip]} {
        # need mkdir if ANY clipped item is a directory (its tree is recreated)
        set clipHasDir 0
        foreach it [dict get $clip items] {
            if {[dict get $it type] eq "dir"} { set clipHasDir 1 ; break }
        }
        set canPaste [expr {
            (!$clipHasDir && "put" in $caps) ||
            ( $clipHasDir && "put" in $caps && "mkdir" in $caps)
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

# True if $prov is the local-filesystem provider. A ZIP or remote path must
# never be treated as a disk path, even when the same string exists locally.
proc ::ctrlutils::cufileops::_isLocalProv {prov} {
    expr {![catch {info object class $prov} c] \
        && $c eq "::tclutils::tuprovider::Local"}
}

# Materialize an entry's bytes to a real local path so an external program can
# open it. Only the local provider may return the disk path as-is. Every other
# provider writes bytes from `get` into the process temp directory.
proc ::ctrlutils::cufileops::_localPath {f entry} {
    variable state
    set path [dict get $entry path]
    set prov $state($f,prov)
    if {[_isLocalProv $prov] && [file exists $path] && [file isfile $path]} {
        return $path
    }
    set data [$prov get $path]
    set name [file tail [dict get $entry name]]
    if {$name eq ""} { set name tmp }
    set dir [_workdir]
    set tmp [file join $dir $name]
    if {[file exists $tmp]} {
        set tmp [file join $dir [pid]-[clock clicks]-[file tail $name]]
    }
    set ch [::open $tmp wb] ; puts -nonewline $ch $data ; close $ch
    return $tmp
}

# Host temp (TMPDIR / TEMP / TMP / /tmp). Not the process workdir.
proc ::ctrlutils::cufileops::_tmpdir {} {
    foreach v {TMPDIR TEMP TMP} {
        if {[info exists ::env($v)] && [file isdirectory $::env($v)]} { return $::env($v) }
    }
    return [expr {[file isdirectory /tmp] ? "/tmp" : [pwd]}]
}

proc ::ctrlutils::cufileops::_pidAlive {p} {
    if {$p eq [pid]} { return 1 }
    if {[file isdirectory /proc]} {
        return [file isdirectory [file join /proc $p]]
    }
    return 0
}

# Drop leftover cufileops-* dirs from dead processes (or older than a day).
proc ::ctrlutils::cufileops::_reapOldWorkdirs {} {
    foreach d [glob -nocomplain -type d [file join [_tmpdir] cufileops-*]] {
        set tail [file tail $d]
        if {![regexp {^cufileops-([0-9]+)-} $tail -> p]} continue
        set stale 0
        if {![_pidAlive $p]} { set stale 1 }
        if {[clock seconds] - [file mtime $d] > 86400} { set stale 1 }
        if {$stale} { catch {file delete -force $d} }
    }
}

proc ::ctrlutils::cufileops::_wipeWorkdir {} {
    variable workdir
    if {$workdir ne ""} {
        catch {file delete -force $workdir}
        set workdir ""
    }
}

proc ::ctrlutils::cufileops::_hookExit {} {
    variable exitHook
    if {$exitHook} return
    set exitHook 1
    if {[llength [info commands ::exit]]} {
        trace add execution ::exit enter [list apply {args {
            catch {::ctrlutils::cufileops::_wipeWorkdir}
        }}]
    }
}

# One directory per process. Wiped on exit; stale siblings reaped at first use.
proc ::ctrlutils::cufileops::_workdir {} {
    variable workdir
    if {$workdir ne "" && [file isdirectory $workdir]} { return $workdir }
    _reapOldWorkdirs
    set workdir [file join [_tmpdir] cufileops-[pid]-[clock microseconds]]
    file mkdir $workdir
    _hookExit
    return $workdir
}

# Open a file with the OS default application.
proc ::ctrlutils::cufileops::openFile {f entry} {
    variable state
    if {[catch {_localPath $f $entry} path]} {
        _dlg $f showError "Could not read file:\n$path" ; return
    }
    if {[llength [info commands ::tclutils::tuopen::launch]]} {
        if {[catch {::tclutils::tuopen::launch $path} e]} {
            _dlg $f showError "Could not open:\n$e"
        }
        return
    }
    # fallback opener by platform
    set opener [expr {
        $::tcl_platform(platform) eq "windows" ? {cmd /c start ""} :
        ($::tcl_platform(os) eq "Darwin" ? {open} : {xdg-open})
    }]
    if {[catch {exec {*}$opener $path &} e]} {
        _dlg $f showError "Could not open:\n$e"
    }
}

# Open a file with a program the user names.
# Launch $path with a launcher command string $app (which may include its own
# arguments, e.g. "code -w"). Runs detached with the file as the final argument.
proc ::ctrlutils::cufileops::_owLaunch {app path {f ""}} {
    if {[catch {exec {*}$app $path &} e]} {
        _dlg $f showError "Could not open with '$app':\n$e"
        return 0
    }
    return 1
}

# Open with the type's default app directly (no dialog). Menu entry
# "Open with <default>" uses this. Does nothing if no default is set.
proc ::ctrlutils::cufileops::openWithDefault {f entry} {
    set app [owDefault [_owKey [dict get $entry name]]]
    if {[string trim $app] eq ""} return
    if {[catch {_localPath $f $entry} path]} {
        _dlg $f showError "Could not read file:\n$path" ; return
    }
    _owLaunch $app $path $f
}

# "Open with..." dialog: shows the apps registered for this file's extension,
# marks the default, and lets the user pick one, add a new command, set the
# default, or remove an app. Picking an app opens the file with it; a newly
# typed command is remembered for this extension.
proc ::ctrlutils::cufileops::openWith {f entry} {
    variable state
    set name [dict get $entry name]
    set ext  [_owKey $name]

    set dlg .cuopenwith
    catch {destroy $dlg}
    toplevel $dlg
    wm title $dlg "Open with"
    wm transient $dlg [winfo toplevel $state($f,list)]

    set extLabel [expr {$ext eq "" ? "(no extension)" : $ext}]
    ttk::label $dlg.msg -text "Open '$name' with:  (apps for $extLabel)"
    grid $dlg.msg -row 0 -column 0 -columnspan 2 -sticky w -padx 8 -pady {8 4}

    # list of registered apps for this extension
    set lb $dlg.lb
    listbox $lb -height 6 -width 44 -exportselection 0 -activestyle dotbox
    ttk::scrollbar $dlg.sb -command [list $lb yview]
    $lb configure -yscrollcommand [list $dlg.sb set]
    grid $lb    -row 1 -column 0 -sticky nsew -padx {8 0} -pady 2
    grid $dlg.sb -row 1 -column 1 -sticky ns  -padx {0 8} -pady 2

    _owFillList $lb $ext

    # entry to add a new command -- a combobox whose dropdown lists installed
    # apps for this file type, so the user can pick instead of typing. Plus a
    # Browse... button to choose any executable.
    ttk::label $dlg.al -text "New command:"
    ttk::combobox $dlg.ae -width 36 -values [_owSuggest $ext]
    ttk::button $dlg.br -text "Browse..." -width 9 \
        -command [list ::ctrlutils::cufileops::_owDlgBrowse $dlg]
    grid $dlg.al -row 2 -column 0 -columnspan 2 -sticky w -padx 8 -pady {6 0}
    grid $dlg.ae -row 3 -column 0 -sticky ew -padx {8 0} -pady 2
    grid $dlg.br -row 3 -column 1 -sticky w  -padx {4 8} -pady 2
    ttk::label $dlg.ah -foreground "#777777" \
        -text "Pick an installed app above, Browse for another, or type a command (e.g. code -w)."
    grid $dlg.ah -row 4 -column 0 -columnspan 2 -sticky w -padx 8 -pady {0 4}

    # buttons
    set bf $dlg.b
    ttk::frame $bf
    ttk::button $bf.open  -text "Open" \
        -command [list ::ctrlutils::cufileops::_owDlgOpen $f $entry $dlg $lb $ext]
    ttk::button $bf.def   -text "Set as default" \
        -command [list ::ctrlutils::cufileops::_owDlgSetDefault $dlg $lb $ext]
    ttk::button $bf.add   -text "Add" \
        -command [list ::ctrlutils::cufileops::_owDlgAdd $dlg $lb $ext]
    ttk::button $bf.rm    -text "Remove" \
        -command [list ::ctrlutils::cufileops::_owDlgRemove $dlg $lb $ext]
    ttk::button $bf.close -text "Close" -command [list destroy $dlg]
    pack $bf.open $bf.def $bf.add $bf.rm -side left -padx 2
    pack $bf.close -side right -padx 2
    grid $bf -row 5 -column 0 -columnspan 2 -sticky ew -padx 6 -pady 6

    grid columnconfigure $dlg 0 -weight 1
    grid rowconfigure    $dlg 1 -weight 1

    # double-click a list entry = Open; Enter in the new-command entry = Add
    bind $lb <Double-Button-1> \
        [list ::ctrlutils::cufileops::_owDlgOpen $f $entry $dlg $lb $ext]
    bind $dlg.ae <Return> \
        [list ::ctrlutils::cufileops::_owDlgAdd $dlg $lb $ext]

    catch {tkwait visibility $dlg ; grab $dlg}
    focus $dlg.ae
}

# Fill the dialog listbox from the registry for $ext, then append detected
# suggestions (installed apps for this file type) that are not yet registered,
# marked "(suggested)". This keeps the list useful even before the user has
# added anything. The raw command per line is kept in owListMap; whether a line
# is a suggestion (not yet saved) is kept in owSugMap.
proc ::ctrlutils::cufileops::_owFillList {lb ext} {
    variable owListMap ; variable owSugMap
    set owListMap($lb) {} ; set owSugMap($lb) {}
    $lb delete 0 end
    set def [owDefault $ext]
    foreach app [owApps $ext] {
        set label [expr {$app eq $def ? "$app    (default)" : $app}]
        $lb insert end $label
        lappend owListMap($lb) $app
        lappend owSugMap($lb) 0
    }
    foreach app [_owSuggest $ext] {
        $lb insert end "$app    (suggested)"
        lappend owListMap($lb) $app
        lappend owSugMap($lb) 1
    }
}

# The raw command for the currently selected list row (or "").
proc ::ctrlutils::cufileops::_owSelected {lb} {
    variable owListMap
    set sel [$lb curselection]
    if {$sel eq "" || ![info exists owListMap($lb)]} { return "" }
    return [lindex $owListMap($lb) [lindex $sel 0]]
}

proc ::ctrlutils::cufileops::_owDlgOpen {f entry dlg lb ext} {
    # prefer a typed command; else the selected list row (registering a picked
    # suggestion so it becomes a permanent entry for this type).
    set typed [string trim [$dlg.ae get]]
    if {$typed ne ""} {
        owAddApp $ext $typed
        set app $typed
    } else {
        set app [_owSelected $lb]
        if {$app ne "" && [_owSelectedIsSuggestion $lb]} { owAddApp $ext $app }
    }
    if {$app eq ""} return
    if {[catch {_localPath $f $entry} path]} {
        _dlg $f showError "Could not read file:\n$path" ; return
    }
    if {[_owLaunch $app $path $f]} { destroy $dlg }
}

# True if the currently selected list row is a suggestion (not yet registered).
proc ::ctrlutils::cufileops::_owSelectedIsSuggestion {lb} {
    variable owSugMap
    set sel [$lb curselection]
    if {$sel eq "" || ![info exists owSugMap($lb)]} { return 0 }
    return [lindex $owSugMap($lb) [lindex $sel 0]]
}

proc ::ctrlutils::cufileops::_owDlgAdd {dlg lb ext} {
    set app [string trim [$dlg.ae get]]
    if {$app eq ""} return
    owAddApp $ext $app
    $dlg.ae set ""
    _owFillList $lb $ext
    $dlg.ae configure -values [_owSuggest $ext]
}

# Browse for an executable and put its path in the command box. On Unix an
# executable has no fixed extension, so no filter is applied; on Windows we
# offer *.exe first.
proc ::ctrlutils::cufileops::_owDlgBrowse {dlg} {
    set types {}
    if {$::tcl_platform(platform) eq "windows"} {
        set types {{Programs {.exe .bat .cmd}} {{All files} *}}
    }
    set start [expr {$::tcl_platform(platform) eq "windows" ? "" : "/usr/bin"}]
    set f [tk_getOpenFile -title "Choose an application" \
               -parent $dlg {*}[expr {$types ne "" ? [list -filetypes $types] : {}}] \
               {*}[expr {[file isdirectory $start] ? [list -initialdir $start] : {}}]]
    if {$f ne ""} { $dlg.ae set $f }
}

proc ::ctrlutils::cufileops::_owDlgSetDefault {dlg lb ext} {
    # default = a typed/picked command (added), else the selected row (which is
    # registered first if it was only a suggestion).
    set typed [string trim [$dlg.ae get]]
    if {$typed ne ""} {
        owSetDefault $ext $typed ; $dlg.ae set ""
    } else {
        set app [_owSelected $lb]
        if {$app eq ""} return
        owSetDefault $ext $app
    }
    _owFillList $lb $ext
    $dlg.ae configure -values [_owSuggest $ext]
}

proc ::ctrlutils::cufileops::_owDlgRemove {dlg lb ext} {
    set app [_owSelected $lb]
    if {$app eq ""} return
    # only registered rows can be removed; a suggestion is not stored yet
    if {[_owSelectedIsSuggestion $lb]} return
    owRemoveApp $ext $app
    _owFillList $lb $ext
    $dlg.ae configure -values [_owSuggest $ext]
}

proc ::ctrlutils::cufileops::newFolder {f} {
    variable state
    set name [_dlg $f input -title "New Folder" \
        -message "Name of the new folder:"]
    if {$name eq ""} return
    set dir [_curDir $f]
    set path [_join $dir $name]
    if {[catch {$state($f,prov) mkdir $path} e]} {
        _dlg $f showError "Could not create folder:\n$e"
        return
    }
    _notify $f [dict create op mkdir path $path]
    _refresh $f
}

proc ::ctrlutils::cufileops::rename {f entry} {
    variable state
    set old [dict get $entry name]
    set name [_dlg $f input -title "Rename" \
        -message "New name for '$old':" -initial $old]
    if {$name eq "" || $name eq $old} return
    set dir [_curDir $f]
    set from [dict get $entry path]
    set to   [_join $dir $name]
    if {[catch {$state($f,prov) move $from $to} e]} {
        _dlg $f showError "Could not rename:\n$e"
        return
    }
    _notify $f [dict create op rename from $from to $to \
                    type [dict get $entry type]]
    _refresh $f
}

proc ::ctrlutils::cufileops::delete {f args} {
    variable state
    set entries {}
    foreach e $args { if {$e ne ""} { lappend entries $e } }
    if {![llength $entries]} return
    # one confirmation for the whole selection
    if {[llength $entries] == 1} {
        set entry [lindex $entries 0]
        set what [expr {[dict get $entry type] eq "dir" ? "folder" : "file"}]
        set msg "Delete $what '[dict get $entry name]'?"
    } else {
        set msg "Delete [llength $entries] items?"
    }
    if {![_dlg $f confirm $msg]} return
    set prov $state($f,prov)
    foreach entry $entries {
        set path [dict get $entry path]
        set type [dict get $entry type]
        # Capture the content BEFORE deleting so the op can be undone (bytes for
        # a file, the whole subtree for a directory). Best-effort.
        set saved ""
        catch {set saved [_snapshot $prov $path $type]}
        if {[catch {$prov delete $path} e]} {
            _dlg $f showError "Could not delete '[dict get $entry name]':\n$e"
            continue
        }
        _notify $f [dict create op delete path $path type $type saved $saved]
    }
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
    # clip holds one OR MORE items to paste, so multi-selection works:
    #   {items {{prov P path X name N type T} ...} cut 0/1}   or empty
    variable clip {}
}

proc ::ctrlutils::cufileops::_haveClip {} {
    variable clip
    return [expr {[dict exists $clip items] && [llength [dict get $clip items]] > 0}]
}

# Build clip items from one or more entries. Empty/blank entries are skipped.
proc ::ctrlutils::cufileops::_clipItems {f entries} {
    variable state
    set items {}
    foreach entry $entries {
        if {$entry eq ""} continue
        lappend items [list prov $state($f,prov) \
                            path [dict get $entry path] \
                            name [dict get $entry name] \
                            type [dict get $entry type]]
    }
    return $items
}

# copy/cut are variadic: "copy $f $entry" (one) still works, and
# "copy $f {*}$entries" copies a whole multi-selection.
proc ::ctrlutils::cufileops::copy {f args} {
    variable clip
    set clip [list items [_clipItems $f $args] cut 0]
    return
}

# Cut marks a file for MOVE: paste will write it at the destination and then
# delete the source. Requires the source provider to support delete (otherwise
# it would be a copy pretending to be a move). Cross-provider safe: the move is
# get+put into the destination followed by delete on the source.
proc ::ctrlutils::cufileops::cut {f args} {
    variable state ; variable clip
    if {"delete" ni [$state($f,prov) caps]} {
        _dlg $f showError "Cut is not available here (the source cannot delete)."
        return
    }
    set clip [list items [_clipItems $f $args] cut 1]
    return
}

proc ::ctrlutils::cufileops::paste {f {targetDir ""}} {
    variable state ; variable clip
    if {![_haveClip]} return
    set items [dict get $clip items]
    set isCut [expr {[dict exists $clip cut] && [dict get $clip cut]}]
    set dst   $state($f,prov)
    set dir   [expr {$targetDir eq "" ? [_curDir $f] : $targetDir}]

    foreach item $items {
        set src  [dict get $item prov]
        set from [dict get $item path]
        set name [dict get $item name]
        set type [dict get $item type]
        # A cut into the SAME directory of the SAME provider is a no-op move onto
        # itself; skip it (do not create "name (copy)").
        if {$isCut && $src eq $dst && [_join $dir $name] eq $from} { continue }
        set to [_uniqueName $dst $dir $name]
        if {$type eq "dir"} {
            if {[catch {_copyTree $src $from $dst $to} e]} {
                _dlg $f showError "Could not paste folder:\n$e"
                continue
            }
        } else {
            if {[catch {$src get $from} data]} {
                _dlg $f showError "Could not read source:\n$data"
                continue
            }
            if {[catch {$dst put $to $data} e]} {
                _dlg $f showError "Could not paste:\n$e"
                continue
            }
        }
        if {$isCut} {
            # Move = the copy above, then remove the source. Snapshot first so
            # undo can restore it. If the delete fails, keep the destination and
            # report -- the data is not lost.
            set saved ""
            catch {set saved [_snapshot $src $from $type]}
            if {[catch {$src delete $from} e]} {
                _dlg $f showError "Copied, but could not remove the source:\n$e"
                _notify $f [dict create op paste path $to type $type]
                continue
            }
            _notify $f [dict create op movex srcprov $src dstprov $dst \
                            from $from to $to type $type saved $saved]
        } else {
            _notify $f [dict create op paste path $to type $type]
        }
    }
    if {$isCut} { set clip {} }   ;# a cut is consumed by the paste
    _refresh $f
}

# Recursively copy a directory subtree from one provider to another: create the
# destination directory, then copy each child (files via get+put, subdirs by
# recursion). Works across providers, so a whole folder can be pulled out of a
# ZIP into a local directory.
proc ::ctrlutils::cufileops::_copyTree {src from dst to} {
    set created {}
    try {
        _copyTreeInto $src $from $dst $to created
    } on error {e} {
        foreach p [lreverse $created] {
            catch {$dst delete $p}
        }
        return -code error $e
    }
}

proc ::ctrlutils::cufileops::_copyTreeInto {src from dst to createdVar} {
    upvar 1 $createdVar created
    $dst mkdir $to
    lappend created $to
    foreach e [$src list $from] {
        set nm [dict get $e name]
        if {$nm eq "." || $nm eq ".."} continue
        set childFrom [dict get $e path]
        set childTo   [_join $to $nm]
        if {[dict get $e type] eq "dir"} {
            _copyTreeInto $src $childFrom $dst $childTo created
        } else {
            $dst put $childTo [$src get $childFrom]
            lappend created $childTo
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

package provide ctrlutils::cufileops 0.3
