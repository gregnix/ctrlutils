#!/usr/bin/env wish
# explorer.tcl -- the reference application for the provider framework.
#
# Deliberately thin: it wires together tkufiletree (tree), tkufilelist (list),
# tkupath (breadcrumb) and tkutab (tabs) over tuproviders. The
# framework does the work; this file connects the parts and holds the session.
#
# Multiple directories open at once, one per tab. Each tab has its own tree,
# list, breadcrumb, current directory and provider: "+" opens a fresh local
# provider, a ZIP or remote URL its own. The same app works over local files
# or a ZIP archive --
# nothing here knows the difference.
#
#   wish explorer.tcl ?directory?
#   wish explorer.tcl -zip archive.zip

package require Tk 8.6-

# Make bundled external packages discoverable. Two sources are searched:
#
#  1. Pure-Tcl packages (Tablelist, Scrollutil) bundled INSIDE the zipkit with
#     build-app's `-include SRC=pkgs/...`. They land in a "pkgs" directory next
#     to this script inside the zip; build-app does not always put that on
#     auto_path, so we add it. (Harmless from source: the dir just is not there.)
#
#  2. NATIVE packages (e.g. pdfiumtcl, which loads tcl9pdfiumtcl060.dll and the
#     PDFium library) placed in a real "pkgs" directory NEXT TO THE .EXE. A DLL
#     cannot be reliably loaded out of the zip on Windows -- the loader needs a
#     real path, and a bundled DLL's own dependency (pdfium.dll) would not be
#     found next to the temp-extracted copy. So we also put the executable's real
#     directory (and an adjacent pkgs/) on auto_path: drop the DLLs in a folder
#     beside explorer.exe and they load from a real path, with pdfium.dll right
#     there next to the wrapper DLL.
apply {{} {
    set here [file dirname [file normalize [info script]]]
    set exe  [file dirname [file normalize [info nameofexecutable]]]
    foreach cand [list [file join $here pkgs] \
                       [file join $here lib pkgs] \
                       [file join $here .. pkgs] \
                       [file join $exe pkgs] \
                       $exe] {
        if {[file isdirectory $cand] && $cand ni $::auto_path} {
            lappend ::auto_path $cand
        }
    }
}}

# Essential packages. If one is missing, a Windows GUI exe would otherwise show
# a blank screen with NO error at all. So load each one guarded: on failure,
# pop a message box naming the missing package and the places that were
# searched, then stop. Fail visibly instead of vanishing. The required
# packages are Tcl modules (.tm), found through the module path, not through
# auto_path -- so both are listed (until 2026-10-20 only auto_path was).
foreach pkg {
    tkutils::tkufiletree tkutils::tkufilelist tkutils::tkupath
    tkutils::tkutab tclutils::tuprovider tkutils::tkupreview
    ctrlutils::cufileops ctrlutils::cumonitor ctrlutils::cufilter
    ctrlutils::cuundo
} {
    if {[catch {package require $pkg} err]} {
        catch {tk_messageBox -icon error -title "Explorer cannot start" \
            -message "Missing package:\n  $pkg\n\n$err\n\nSearched module path (tcl::tm::path):\n[join [::tcl::tm::path list] \n]\n\nSearched auto_path:\n[join $::auto_path \n]"}
        exit 1
    }
}
# Sync is optional: if its module is missing, the Explorer must still start.
# A hard "package require" here would abort loading -- and on a Windows GUI exe
# (no console) that means a blank screen with no error. So load it softly and
# let the Sync menu entry report the problem visibly when used.
namespace eval ::explorer { variable haveSync }
set ::explorer::haveSync [expr {![catch {package require ctrlutils::cusync}]}]

# Search building blocks (all pure Tcl, normally always present). Loaded softly
# so a missing module disables the feature visibly instead of blanking the app.
#   tufind/tugrep -> recursive file find + content grep (local filesystem)
#   tkutlfind     -> incremental find within the current list (a tablelist)
namespace eval ::explorer { variable haveFind ; variable haveListFind }
set ::explorer::haveFind [expr {![catch {
    package require tclutils::tufind
    package require tclutils::tugrep
}]}]
set ::explorer::haveListFind [expr {![catch {package require tkutils::tkutlfind}]}]

# ---------------------------------------------------------------------------
# Optional backends -- detected ONCE, here, explicitly, and reported.
#
# The explorer runs without any of these (it degrades to text/hex previews),
# but a SILENT degrade is a trap: you discover a missing library only when you
# click a file and nothing happens. So every optional backend is probed up front
# into ::explorer::caps, with a reason recorded on failure, and the result is
# printed at startup (and via `-check`). Missing pieces are visible immediately,
# not hours later.
#
# caps: name -> {ok 0|1  detail "..."}  where name is one of
#   img_jpeg img_tiff img_bmp img_ico  svg  pdf  sqlite
# ---------------------------------------------------------------------------
namespace eval ::explorer {
    variable imgFormats {}      ;# kept for the existing image code
    variable haveSvg 0          ;# kept for the existing SVG code
    variable havePdf 0          ;# NEW: decided at startup, not per-click
    variable haveSqlite 0
    variable caps {}            ;# name -> dict {ok detail}
}

proc ::explorer::_probe {name script} {
    variable caps
    if {[catch {uplevel #0 $script} e]} {
        dict set caps $name [dict create ok 0 detail $e]
        return 0
    }
    dict set caps $name [dict create ok 1 detail ""]
    return 1
}

proc ::explorer::_detectCapabilities {} {
    variable imgFormats ; variable haveSvg ; variable havePdf ; variable haveSqlite
    # image formats: probe each separately (the Img umbrella would take them all
    # down if a single native lib were missing).
    foreach fmt {jpeg tiff bmp ico} {
        if {[_probe img_$fmt [list package require img::$fmt]]} {
            lappend imgFormats $fmt
        }
    }
    # SVG via tcllunasvg
    set haveSvg [_probe svg {package require tcllunasvg}]
    # PDF via tclpdfium: require the package AND check the render command exists,
    # so a half-loaded extension (package present but native lib missing) is
    # reported as unavailable rather than crashing on first use.
    set havePdf [_probe pdf {
        package require pdfiumtcl
        if {![llength [info commands ::pdfium::render]]} {
            error "pdfiumtcl loaded but ::pdfium::render is missing (native lib not linked?)"
        }
    }]
    # SQLite
    set haveSqlite [_probe sqlite {package require sqlite3}]
}

# Human-readable capability report. Lines are stable and greppable.
proc ::explorer::capabilityReport {} {
    variable caps
    set order {img_jpeg img_tiff img_bmp img_ico svg pdf sqlite}
    set labels {
        img_jpeg "images: JPEG (img::jpeg)"
        img_tiff "images: TIFF (img::tiff)"
        img_bmp  "images: BMP  (img::bmp)"
        img_ico  "images: ICO  (img::ico)"
        svg      "SVG preview (tcllunasvg)"
        pdf      "PDF preview (pdfiumtcl)"
        sqlite   "SQLite preview (sqlite3)"
    }
    set out "Explorer optional backends:\n"
    foreach k $order {
        set lbl [dict get $labels $k]
        if {[dict exists $caps $k] && [dict get $caps $k ok]} {
            append out [format "  %-28s OK\n" $lbl]
        } else {
            set why ""
            if {[dict exists $caps $k]} { set why [dict get $caps $k detail] }
            append out [format "  %-28s MISSING%s\n" $lbl \
                            [expr {$why ne "" ? "  -- $why" : ""}]]
        }
    }
    return $out
}

# True if every optional backend loaded (used by -check to set the exit code).
proc ::explorer::allCapabilitiesOk {} {
    variable caps
    foreach k {img_jpeg img_tiff img_bmp img_ico svg pdf sqlite} {
        if {![dict exists $caps $k] || ![dict get $caps $k ok]} { return 0 }
    }
    return 1
}

# Try to write text to a console. On Windows a wish-built .exe is a GUI-subsystem
# program with NO console attached, so puts stdout/stderr goes nowhere (this is
# itself a silent-failure trap). Returns 1 if the text actually went to a real
# channel, 0 otherwise -- so the caller knows whether it still needs to show a
# window.
proc ::explorer::_toConsole {chan text} {
    if {[catch {
        # a detached GUI exe often has no std channels at all
        if {$chan ni [chan names]} { return -code error "no $chan" }
        puts -nonewline $chan $text ; flush $chan
    }]} { return 0 }
    return 1
}

# Show the capability report in a Tk window. This is the reliable way to surface
# it on Windows, where console output from a GUI exe is invisible. Modal-ish:
# used both from the Help menu and from -check (where closing it exits).
proc ::explorer::_showCapabilityDialog {{onClose ""}} {
    set dlg .capreport
    catch {destroy $dlg}
    toplevel $dlg
    wm title $dlg "Optional backends"
    set ok [allCapabilitiesOk]
    ttk::label $dlg.h -padding {10 8 10 4} \
        -text [expr {$ok ? "All optional backends are available." \
                          : "Some optional backends are MISSING (previews for those types are disabled)."}]
    grid $dlg.h -row 0 -column 0 -columnspan 2 -sticky w
    text $dlg.t -width 64 -height 9 -font TkFixedFont -wrap none \
        -yscrollcommand [list $dlg.sb set]
    ttk::scrollbar $dlg.sb -command [list $dlg.t yview]
    grid $dlg.t  -row 1 -column 0 -sticky nsew -padx {10 0} -pady 4
    grid $dlg.sb -row 1 -column 1 -sticky ns   -padx {0 10} -pady 4
    $dlg.t insert end [capabilityReport]
    $dlg.t configure -state disabled
    ttk::button $dlg.b -text "Close" -command [list destroy $dlg]
    grid $dlg.b -row 2 -column 0 -columnspan 2 -pady {4 10}
    grid columnconfigure $dlg 0 -weight 1
    grid rowconfigure    $dlg 1 -weight 1
    if {$onClose ne ""} { bind $dlg <Destroy> [list apply {{oc w dlg} {
        if {$w eq $dlg} { uplevel #0 $oc }
    }} $onClose %W $dlg] }
    return $dlg
}

::explorer::_detectCapabilities

namespace eval ::explorer {
    variable start "/"      ;# directory the first tab opens
    variable tab {}         ;# per-tab state, keyed by content-frame path (starts empty:
                            ;# a tab-change event can arrive before the first tab is
                            ;# registered -- it then found no variable at all)
    variable statustext        ;# array: statustext($w) per window
    variable firstProv ""   ;# provider for the very first tab
    variable hexCap 262144   ;# max bytes to read/hex-dump for a binary preview (256 KB)
    variable textCap 1048576 ;# max bytes to read for a text preview (1 MB)
    variable mediaCap 52428800 ;# max size for image/pdf/db preview (50 MB); above -> message
    variable previewOn 1     ;# master switch: is the preview pane shown at all?
    variable layoutMode columns  ;# pane arrangement: columns | list-bottom
    # per-kind switches: turn individual preview types off (e.g. skip heavy PDF
    # or SQLite rendering) while keeping the rest. All on by default.
    variable previewKind
    array set previewKind {text 1 image 1 pdf 1 sqlite 1 svg 1 hex 1}
}

# ---- sources --------------------------------------------------------------
# Build a provider + start directory from a source spec, WITHOUT storing it
# globally -- each tab keeps its own. Returns {prov start}.
proc ::explorer::makeSource {args} {
    if {[lindex $args 0] eq "-zip"} {
        package require tclutils::tuprovider::zip
        set prov [::tclutils::tuprovider open zip [lindex $args 1]]
        return [list $prov "/"]
    }
    # -remote URL ?provider-options?  -- open a remote provider (sftp/ftp/dav).
    # The scheme is taken from the URL; the matching provider package is loaded
    # on demand. The start directory is the URL's path, or "/".
    if {[lindex $args 0] eq "-remote"} {
        set url [lindex $args 1]
        set opts [lrange $args 2 end]
        return [openRemote $url {*}$opts]
    }
    set dir [expr {[llength $args] ? [lindex $args 0] : [pwd]}]
    set prov [::tclutils::tuprovider open local]
    return [list $prov [file normalize $dir]]
}

# Open a remote provider from a URL (sftp://, ftp://, dav://, davs://https...).
# Returns {prov startdir}. The provider package is required on demand so the app
# does not hard-depend on every backend.
proc ::explorer::openRemote {url args} {
    if {![regexp {^([a-z][a-z0-9+.-]*)://} $url -> scheme]} {
        error "not a remote URL (expected scheme://...): $url"
    }
    # davs/https map to the dav provider; normalise the scheme -> package name
    set pkgScheme $scheme
    switch -- $scheme {
        davs - https - http { set pkgScheme dav }
    }
    package require tclutils::tuprovider::$pkgScheme
    set prov [::tclutils::tuprovider open $pkgScheme $url {*}$args]
    # start directory: the URL path, else "/"
    set start "/"
    if {[regexp {^[a-z][a-z0-9+.-]*://[^/]*(/.*)$} $url -> path] && $path ne ""} {
        set start $path
    }
    return [list $prov $start]
}

# Kept for the initial launch: remember the first tab's source.
proc ::explorer::openSource {args} {
    variable firstProv ; variable start
    lassign [makeSource {*}$args] firstProv start
}

# The tree root for a given provider: OS root for local, "/" for ZIP/DAV.
proc ::explorer::_treeRoot {prov} {
    if {[namespace tail [info object class $prov]] eq "Local"} {
        # On Windows start the tree at the virtual "This PC" root so every drive
        # (C:/ D:/ ...) is reachable; "up" from a drive root returns here too.
        # Elsewhere the single filesystem root is fine.
        if {$::tcl_platform(platform) eq "windows"} {
            return [::tkutils::tkufiletree::volumesRoot]
        }
        return "/"
    }
    return "/"
}

# The drive roots for the local disk, for the drive selector. Empty on
# platforms/providers where a drive picker makes no sense (single root).
proc ::explorer::_drives {prov} {
    if {[namespace tail [info object class $prov]] ne "Local"} { return {} }
    set out {}
    foreach v [file volumes] {
        if {[string match //zipfs:* $v]} continue
        lappend out $v
    }
    # Only meaningful when there is a real choice (Windows with >1 drive).
    if {[llength $out] < 2} { return {} }
    return $out
}

# ---- top-level UI ---------------------------------------------------------
# The Explorer supports multiple independent windows in ONE process, so the
# clipboard (a cufileops namespace global) is shared and copy/move works across
# windows. Every window-specific widget is addressed relative to its toplevel
# root $w ("." for the first window, ".explorerN" for the others).

# Window-relative widget path: _wp . tabs -> .tabs ; _wp .explorer2 tabs ->
# .explorer2.tabs.
proc ::explorer::_wp {w child} {
    return [expr {$w eq "." ? ".$child" : "$w.$child"}]
}
# The window (toplevel) a tab frame lives in.
proc ::explorer::_win {f} { return [winfo toplevel $f] }

proc ::explorer::build {} {
    variable firstProv ; variable start
    buildWindow . $firstProv $start
}

# Build one Explorer window rooted at $w. For the first window $w is "." and
# ($prov,$dir) is the initial source; for a new window $prov is "" and a fresh
# local tab at $dir (or home) is opened.
proc ::explorer::buildWindow {w {prov ""} {dir ""}} {
    if {$w ne "."} { toplevel $w }
    set ::explorer::statustext($w) ""
    wm title $w "Explorer"
    wm geometry $w 860x560

    _buildMenu $w

    set status [_wp $w status]
    ttk::label $status -textvariable ::explorer::statustext($w) -anchor w \
        -padding {6 3} -relief sunken
    pack $status -side bottom -fill x

    set tabs [_wp $w tabs]
    ::tkutils::tkutab::widget $tabs \
        -onnew    [list ::explorer::newTab $w] \
        -onclose  {::explorer::onTabClose} \
        -onselect {::explorer::onTabSelect}
    pack $tabs -side top -fill both -expand 1

    if {$prov ne ""} {
        newTabWith $w $prov $dir
    } else {
        newTab $w $dir
    }

    if {$w ne "."} {
        wm protocol $w WM_DELETE_WINDOW [list ::explorer::_closeWindow $w]
    }
    return $w
}

# Open a second (third, ...) Explorer window in the same process. The shared
# clipboard means you can copy/cut in one window and paste in another.
proc ::explorer::_newWindow {{fromTab ""}} {
    # pick the first free .explorerN toplevel
    set n 2
    while {[winfo exists .explorer$n]} { incr n }
    set w .explorer$n
    # open the new window at the same directory as the current tab, if any
    set dir ""
    if {$fromTab ne "" && [dict exists $::explorer::tab $fromTab cur]} {
        set dir [dict get $::explorer::tab $fromTab cur]
    }
    buildWindow $w "" $dir
    return $w
}

# Close a secondary window: clean up its tabs' state directly (NOT via
# tkutab::close, whose "keep one tab open" logic would re-open a tab in a window
# we are destroying), then destroy it. The main window "." uses Quit instead.
proc ::explorer::_closeWindow {w} {
    if {$w eq "."} { return }
    variable tab
    foreach f [dict keys $tab] {
        if {[_win $f] ne $w} continue
        _releaseTab $f
    }
    unset -nocomplain ::explorer::statustext($w)
    catch {destroy $w}
    return
}

# A menu bar makes the operations discoverable -- especially undo/redo, which
# are otherwise keyboard-only. Each command acts on the CURRENT tab, fetching
# its selection from the tab's list, so the same cufileops/cuundo operations the
# context menu and shortcuts use are reachable from here too.
proc ::explorer::_buildMenu {w} {
    set m [_wp $w m]
    $w configure -menu [menu $m -tearoff 0]

    menu $m.file -tearoff 0
    $m add cascade -label "File" -menu $m.file
    $m.file add command -label "New Tab"     -accelerator "Ctrl+T" \
        -command [list ::explorer::newTab $w]
    $m.file add command -label "New Window"  -accelerator "Ctrl+N" \
        -command [list ::explorer::_newWindowFrom $w]
    $m.file add separator
    $m.file add command -label "Open ZIP..."    -command [list ::explorer::openZipTab $w]
    $m.file add command -label "Open Remote..." -command [list ::explorer::openRemoteTab $w]
    $m.file add command -label "Sync folders..." -command [list ::explorer::openSyncDialog $w]
    $m.file add separator
    $m.file add command -label "Close Tab"   -accelerator "Ctrl+W" \
        -command [list ::explorer::_menuCloseTab $w]
    $m.file add command -label "Close Window" -command [list ::explorer::_closeWindow $w]
    $m.file add separator
    $m.file add command -label "Quit"        -accelerator "Ctrl+Q" -command {exit}

    menu $m.edit -tearoff 0
    $m add cascade -label "Edit" -menu $m.edit
    $m.edit add command -label "Undo" -accelerator "Ctrl+Z" \
        -command [list ::explorer::_menuUndo $w]
    $m.edit add command -label "Redo" -accelerator "Ctrl+Y" \
        -command [list ::explorer::_menuRedo $w]
    $m.edit add separator
    $m.edit add command -label "New Folder" -command [list ::explorer::_menuOp $w newFolder]
    $m.edit add command -label "Rename"     -command [list ::explorer::_menuOp $w rename]
    $m.edit add command -label "Delete"     -command [list ::explorer::_menuOp $w delete]
    $m.edit add separator
    $m.edit add command -label "Copy"  -accelerator "Ctrl+C" -command [list ::explorer::_menuOp $w copy]
    $m.edit add command -label "Cut"   -accelerator "Ctrl+X" -command [list ::explorer::_menuOp $w cut]
    $m.edit add command -label "Paste" -accelerator "Ctrl+V" -command [list ::explorer::_menuOp $w paste]
    $m.edit add separator
    $m.edit add command -label "Find in list" -accelerator "Ctrl+F" \
        -command [list ::explorer::_findInList $w]
    $m.edit add command -label "Find files..." -accelerator "Ctrl+Shift+F" \
        -command [list ::explorer::openFindDialog $w]
    # keep Undo/Redo enabled state fresh when the Edit menu opens
    bind $m.edit <<MenuSelect>> [list ::explorer::_syncEditMenu $w]

    menu $m.view -tearoff 0
    $m add cascade -label "View" -menu $m.view
    $m.view add command -label "Refresh" -accelerator "F5" \
        -command [list ::explorer::_menuOp $w refresh]
    $m.view add separator
    $m.view add checkbutton -label "Show Preview" \
        -variable ::explorer::previewOn \
        -command {::explorer::_applyPreviewVisibility}
    # switch the pane arrangement (applies to all tabs)
    menu $m.view.layout -tearoff 0
    $m.view add cascade -label "Layout" -menu $m.view.layout
    $m.view.layout add radiobutton -label "Columns (tree | list | preview)" \
        -variable ::explorer::layoutMode -value columns \
        -command {::explorer::_applyLayoutAll}
    $m.view.layout add radiobutton -label "Tree + Preview on top, list below" \
        -variable ::explorer::layoutMode -value list-bottom \
        -command {::explorer::_applyLayoutAll}
    # a submenu to enable/disable individual preview types
    menu $m.view.prev -tearoff 0
    $m.view add cascade -label "Preview types" -menu $m.view.prev
    foreach {k lbl} {text "Text and code" image "Images" pdf "PDF"
                     sqlite "SQLite databases" svg "SVG" hex "Hex (unknown types)"} {
        $m.view.prev add checkbutton -label $lbl \
            -variable ::explorer::previewKind($k) \
            -command {::explorer::_refreshPreview}
    }

    # Help > Optional backends: shows which preview backends (PDF, SVG, image
    # formats, SQLite) actually loaded. This is the in-app, always-reachable way
    # to see it -- console output is invisible in a Windows GUI build.
    menu $m.help -tearoff 0
    $m add cascade -label "Help" -menu $m.help
    $m.help add command -label "Optional backends..." \
        -command {::explorer::_showCapabilityDialog}

    # global accelerators (the list-local ones from the controllers still work)
    bind $w <Control-t> "[list ::explorer::newTab $w] ; break"
    bind $w <Control-n> "[list ::explorer::_newWindowFrom $w] ; break"
    bind $w <Control-w> "[list ::explorer::_menuCloseTab $w] ; break"
    bind $w <Control-f> "[list ::explorer::_findInList $w] ; break"
    bind $w <Control-F> "[list ::explorer::openFindDialog $w] ; break"
    bind $w <Control-q> {exit}
}

# New Window seeded from $w's current tab (so it opens at the same directory).
proc ::explorer::_newWindowFrom {w} {
    _newWindow [_curTab $w]
}

# ---- menu handlers: act on the current tab --------------------------------
proc ::explorer::_curTab {w} {
    if {[catch {::tkutils::tkutab::current [_wp $w tabs]} f]} { return "" }
    variable tab
    if {![dict exists $tab $f]} { return "" }
    return $f
}

proc ::explorer::_menuUndo {w} {
    set f [_curTab $w] ; if {$f eq ""} return
    ::ctrlutils::cuundo::undo $f
}
proc ::explorer::_menuRedo {w} {
    set f [_curTab $w] ; if {$f eq ""} return
    ::ctrlutils::cuundo::redo $f
}

proc ::explorer::_syncEditMenu {w} {
    set f [_curTab $w]
    set canU [expr {$f ne "" && [::ctrlutils::cuundo::canUndo $f]}]
    set canR [expr {$f ne "" && [::ctrlutils::cuundo::canRedo $f]}]
    set m [_wp $w m]
    $m.edit entryconfigure "Undo" -state [expr {$canU ? "normal" : "disabled"}]
    $m.edit entryconfigure "Redo" -state [expr {$canR ? "normal" : "disabled"}]
}

proc ::explorer::_menuCloseTab {w} {
    set f [_curTab $w] ; if {$f eq ""} return
    ::tkutils::tkutab::close [_wp $w tabs] $f
}

# Route a menu operation to cufileops on the current tab, using its selection.
proc ::explorer::_menuOp {w op} {
    variable tab
    set f [_curTab $w] ; if {$f eq ""} return
    set lst [dict get $tab $f list]
    switch -- $op {
        newFolder { ::ctrlutils::cufileops::newFolder $f }
        paste     { ::ctrlutils::cufileops::paste $f }
        refresh   { ::explorer::afterOps $f }
        copy - cut - delete {
            set es [::tkutils::tkufilelist::selectedEntries $lst]
            if {![llength $es]} { setStatus "Select a file first." $w ; return }
            ::ctrlutils::cufileops::$op $f {*}$es
        }
        rename {
            set e [::tkutils::tkufilelist::selectedEntry $lst]
            if {$e eq ""} { setStatus "Select a file first." $w ; return }
            ::ctrlutils::cufileops::rename $f $e
        }
    }
}

# ---- a tab is one browse view ---------------------------------------------
# The "+" button calls this with no args: open a fresh LOCAL view at home, so a
# new tab is independent of whatever the current tab shows (which may be a ZIP).
proc ::explorer::newTab {w {dir ""}} {
    lassign [makeSource [expr {$dir eq "" ? [_homeDir] : $dir}]] prov start
    newTabWith $w $prov $start
}

proc ::explorer::_homeDir {} {
    if {[info exists ::env(HOME)]}        { return $::env(HOME) }
    if {[info exists ::env(USERPROFILE)]} { return $::env(USERPROFILE) }
    return [pwd]
}

# Open a new tab bound to a SPECIFIC provider + directory. This is the heart of
# per-tab providers: the provider lives in the tab's state, not globally, so one
# tab can be a ZIP and another the local disk, and cufileops can copy between
# them (its clipboard remembers the source provider).
proc ::explorer::newTabWith {w prov dir} {
    variable tab

    set f [::tkutils::tkutab::add [_wp $w tabs] [_label $dir]]

    ttk::frame $f.top
    ttk::button $f.top.zip -text "Open ZIP..." -width 11 \
        -command ::explorer::openZipTab
    pack $f.top.zip -side right -padx 4 -pady 2
    # Drive selector (Windows / multi-volume only): a read-only combobox of the
    # drive roots. Picking one navigates there. Hidden when there is only one
    # volume, so single-root platforms are unaffected.
    set drives [_drives $prov]
    if {[llength $drives]} {
        ttk::combobox $f.top.drive -width 4 -state readonly -values $drives
        bind $f.top.drive <<ComboboxSelected>> \
            [list ::explorer::onDriveSelect $f]
        pack $f.top.drive -side left -padx {4 0} -pady 2
    }
    ::tkutils::tkupath::widget $f.top.path -rootlabel "/" \
        -onnavigate [list ::explorer::onPathNavigate $f]
    pack $f.top.path -side left -fill x -expand 1 -padx 4 -pady 2
    pack $f.top -side top -fill x

    # The three views live in STABLE wrapper frames that are children of the tab
    # frame $f (not of any panedwindow). This lets the layout be rebuilt -- a
    # panedwindow can manage windows that are descendants of its own parent, so
    # the wrappers can be moved between different layouts by forget/add without
    # ever recreating the content widgets. All state (dir, selection, preview,
    # the cufileops/cuundo/cumonitor/cufilter controllers) is thus preserved
    # across a layout switch.
    set tf [ttk::frame $f.vtree -width 200]
    set lf [ttk::frame $f.vlist -width 280]
    set pf [ttk::frame $f.vprev -width 560 -height 300]

    ::tkutils::tkufiletree::widget $tf.t -root [_treeRoot $prov] -provider $prov \
        -files 0 -onselect [list ::explorer::onTreeSelect $f]
    pack $tf.t -fill both -expand 1

    ::tkutils::tkufilelist::widget $lf.l -provider $prov -dir $dir \
        -onactivate [list ::explorer::onListActivate $f] \
        -onselect [list ::explorer::onListSelect $f]
    # a live filter box above the list (a ctrlutils controller)
    ::ctrlutils::cufilter::widget $lf.filter $lf.l
    pack $lf.filter -side top -fill x -pady {0 2}

    # incremental find bar for the current list (Ctrl+F), hidden until invoked.
    # It highlights matching rows in place and steps through them -- distinct
    # from the filter above, which hides non-matching rows.
    _buildFindBar $f $lf.find
    pack $lf.l -side top -fill both -expand 1

    ::tkutils::tkupreview::widget $pf.v
    pack $pf.v -fill both -expand 1

    dict set tab $f prov $prov
    dict set tab $f tree $tf.t
    dict set tab $f list $lf.l
    dict set tab $f path $f.top.path
    dict set tab $f prev $pf.v
    dict set tab $f filter $lf.filter
    dict set tab $f cur  ""
    dict set tab $f sel  ""

    # build the initial pane layout (honours the global layout mode + preview
    # switch). This packs a panedwindow container and adds the wrappers to it.
    _applyLayout $f

    # undo/redo for file operations, per tab (Ctrl+Z / Ctrl+Y on the list).
    # cufileops emits an operation record via -onop after each change; cuundo
    # records it and can reverse it. The two stay decoupled -- cufileops does
    # not know cuundo exists, it just reports what it did.
    ::ctrlutils::cuundo::install $f $prov -list $lf.l

    # capability-driven right-click file operations on the list. Refresh
    # re-reads the current directory into the list after any change. -onop
    # feeds each operation to cuundo for undo.
    ::ctrlutils::cufileops::install $f $prov $lf.l \
        [list ::explorer::afterOps $f] \
        -onop [list ::ctrlutils::cuundo::record $f]

    # watch the current directory: if it changes underneath us (another program
    # adds/removes a file), reload the list. poke() after our own operations
    # keeps us from reporting our own changes back.
    ::ctrlutils::cumonitor::install $f $prov -interval 2000 \
        -onchange [list ::explorer::onDirChanged $f]

    # enable dragging files out of this list onto other tabs/windows
    _dndInstall $f

    goto $f $dir
}

# Run after cufileops makes a change: refresh the list, then re-baseline the
# monitor so our own edit is not re-reported as an external change.
proc ::explorer::afterOps {f} {
    variable tab
    ::tkutils::tkufilelist::refresh [dict get $tab $f list]
    # also re-populate the current directory's tree node, so a folder just
    # created/pasted/deleted shows up (or disappears) in the tree and can be
    # navigated into from there.
    catch {::tkutils::tkufiletree::refreshDir [dict get $tab $f tree] [dict get $tab $f cur]}
    catch {::ctrlutils::cumonitor::poke $f}
}

# The monitor saw the current directory change externally: reload the list.
proc ::explorer::onDirChanged {f dir} {
    variable tab
    if {![dict exists $tab $f]} return
    catch {::tkutils::tkufilelist::refresh [dict get $tab $f list]}
    catch {::tkutils::tkufiletree::refreshDir [dict get $tab $f tree] $dir}
    setStatus "reloaded [file tail $dir] (changed on disk)" [_win $f]
}

# Central navigation for a tab. The loop from reveal's async selection is
# broken on value: navigating to the already-current dir is a no-op.
proc ::explorer::goto {f dir} {
    variable tab
    set prov [dict get $tab $f prov]
    set dir [file normalize $dir]
    if {$dir eq [dict get $tab $f cur]} return
    dict set tab $f cur $dir
    catch {::ctrlutils::cufilter::clear [dict get $tab $f filter]}
    ::tkutils::tkufilelist::setDir [dict get $tab $f list] $dir
    catch {::tkutils::tkupath::setPath [dict get $tab $f path] $dir}
    catch {::tkutils::tkufiletree::reveal [dict get $tab $f tree] $dir}
    catch {_syncDrive $f $dir}
    ::tkutils::tkutab::setLabel [_wp [_win $f] tabs] $f [_label $dir]
    catch {::ctrlutils::cumonitor::watch $f $dir}
    setStatus "[llength [$prov list $dir]] entries in [file tail $dir]" [_win $f]
}

proc ::explorer::_label {dir} {
    set n [file tail $dir]
    return [expr {$n eq "" ? $dir : $n}]
}

# ---- coupling (all handlers carry their tab frame $f) ---------------------
proc ::explorer::onTreeSelect {f path} {
    variable tab
    set prov [dict get $tab $f prov]
    if {[catch {$prov stat $path} e]} return
    if {[dict get $e type] ne "dir"} return
    goto $f $path
}

proc ::explorer::onListActivate {f entry} {
    if {[dict get $entry type] eq "dir"} {
        goto $f [dict get $entry path]
    } else {
        setStatus "File: [dict get $entry name] ([dict get $entry size] bytes)" [_win $f]
    }
}

# Selecting a file previews it. The type->preview-kind policy lives here, in
# the app; the tkupreview widget only displays what it is handed.
# Show a short "turned off" note in the preview pane. Used when a specific
# preview kind is disabled via View > Preview types.
proc ::explorer::_previewOff {pv msg} {
    ::tkutils::tkupreview::message $pv $msg
}

# Master switch handler: show or hide the preview pane in every tab. The pane is
# removed from / re-added to each tab's paned window, so the tree and list get
# the freed space. Re-adding restores it after the list at the same weight.
proc ::explorer::_applyPreviewVisibility {} {
    # Preview on/off is now just a layout input: rebuild every tab's panes.
    _applyLayoutAll
    variable previewOn
    if {$previewOn} { _refreshPreview }
}

# Rebuild the pane layout for every open tab (after a mode or preview change).
proc ::explorer::_applyLayoutAll {} {
    variable tab
    foreach f [dict keys $tab] {
        if {[winfo exists $f]} { _applyLayout $f }
    }
}

# (Re)build the panedwindow container for one tab from the global layoutMode and
# previewOn. The three view wrappers ($f.vtree/$f.vlist/$f.vprev) are stable
# children of $f; here they are only detached from the old container and added
# to a freshly built one, so no content or controller state is lost.
proc ::explorer::_applyLayout {f} {
    variable layoutMode
    variable previewOn
    set tf $f.vtree ; set lf $f.vlist ; set pf $f.vprev
    set showPrev [expr {$previewOn && [winfo exists $pf]}]

    # detach wrappers from whatever manages them, then drop old containers
    foreach wchild [list $f.pw] {
        if {[winfo exists $wchild]} {
            catch { foreach p [$wchild panes] { $wchild forget $p } }
        }
    }
    foreach inner [list $f.pw.top] {
        if {[winfo exists $inner]} {
            catch { foreach p [$inner panes] { $inner forget $p } }
        }
    }
    foreach c [list $f.pw.top $f.pw] { catch {destroy $c} }
    # the wrappers may still be packed/managed directly -- forget that too
    foreach wr [list $tf $lf $pf] { catch {pack forget $wr} ; catch {grid forget $wr} }

    switch -- $layoutMode {
        list-bottom {
            # Tree (left) and Preview (right) on top; the file list spans the
            # bottom. Outer vertical split, inner horizontal split for the top.
            ttk::panedwindow $f.pw -orient vertical
            pack $f.pw -side top -fill both -expand 1
            if {$showPrev} {
                ttk::panedwindow $f.pw.top -orient horizontal
                $f.pw.top add $tf -weight 2
                $f.pw.top add $pf -weight 5
                $f.pw add $f.pw.top -weight 3
                $f.pw add $lf -weight 2
            } else {
                # no preview: just tree on top, list below
                $f.pw add $tf -weight 2
                $f.pw add $lf -weight 3
            }
        }
        default {
            # columns: Tree | List | Preview, all side by side (default)
            ttk::panedwindow $f.pw -orient horizontal
            pack $f.pw -side top -fill both -expand 1
            $f.pw add $tf -weight 1
            $f.pw add $lf -weight 2
            if {$showPrev} { $f.pw add $pf -weight 5 }
        }
    }

    # The wrappers are managed as SIBLINGS of the panedwindow (so they survive a
    # layout rebuild without recreating their content). Siblings stack BELOW the
    # panedwindow by default and get hidden behind its background -- only the
    # sash grips show. Raise each shown wrapper above the panedwindow so its
    # content is visible. (This is the step that was missing and left the panes
    # blank.)
    foreach wr [list $tf $lf $pf] {
        if {[winfo exists $wr] && [winfo manager $wr] ne ""} {
            raise $wr $f.pw
        }
    }
}

# Re-render the current selection in the active tab. Called after a preview
# preference changes so the effect is visible immediately (instead of only on
# the next selection).
proc ::explorer::_refreshPreview {} {
    variable tab
    variable previewOn
    if {!$previewOn} return
    set f [_curTab]
    if {$f eq "" || ![dict exists $tab $f]} return
    if {![dict exists $tab $f sel]} return
    set sel [dict get $tab $f sel]
    if {$sel eq ""} return
    onListSelect $f $sel
}

proc ::explorer::onListSelect {f entry} {
    variable tab
    variable previewOn
    variable previewKind
    if {![dict exists $tab $f]} return
    # remember the current file selection (an entry dict) so a preference
    # change can re-render it. Kept separate from "cur" (the current directory).
    dict set tab $f sel $entry
    if {!$previewOn} return
    set prov [dict get $tab $f prov]
    set pv [dict get $tab $f prev]
    if {[dict get $entry type] ne "file"} {
        ::tkutils::tkupreview::message $pv "Directories have no preview."
        return
    }
    set name  [dict get $entry name]
    set path  [dict get $entry path]
    set title "$name    [dict get $entry size] bytes"
    set ext   [string tolower [file extension $name]]
    # Extension -> preview kind. Text-based kinds read bytes and hand them to a
    # tkupreview method; path-based kinds (image/pdf) go through a temp file.
    # Unknown types fall back to a hex dump rather than "no preview".
    set textKinds {
        .md markdown  .markdown markdown
        .html html  .htm html
        .json json  .xml xml
        .ini ini  .cfg ini  .conf ini
        .csv csv
        .txt text  .tcl text  .c text  .h text  .sh text  .py text
        .css text  .log text  .md5 text  .tm text  .yaml text  .yml text
    }
    if {[dict exists $textKinds $ext]} {
        if {!$previewKind(text)} { _previewOff $pv "Text preview is turned off." ; return }
        set kind [dict get $textKinds $ext]
        _previewText $f $pv $title $prov $path [dict get $entry size] $kind
        return
    }
    # TSV is a table too, but tab-separated -- tell the csv viewer the delimiter
    # so a .tsv is not parsed as a single comma-less column. Large files are
    # capped like other text (shown as plain text head) to avoid a table freeze.
    if {$ext eq ".tsv"} {
        if {!$previewKind(text)} { _previewOff $pv "Text preview is turned off." ; return }
        variable textCap
        set size [dict get $entry size]
        if {[string is integer -strict $size] && $size > $textCap} {
            _previewText $f $pv $title $prov $path $size text
            return
        }
        if {[catch {$prov get $path} data]} {
            ::tkutils::tkupreview::message $pv "Cannot read: $data" ; return
        }
        set text [encoding convertfrom utf-8 $data]
        if {[string index $text 0] eq "\uFEFF"} {
            set text [string range $text 1 end]
        }
        ::tkutils::tkupreview::csv $pv $title $text -delimiter \t
        return
    }
    # SVG: render to an image via tcllunasvg if available, else show the source
    # (it is XML). Read as text since SVG is a text format.
    if {$ext eq ".svg"} {
        if {!$previewKind(svg)} { _previewOff $pv "SVG preview is turned off." ; return }
        if {[catch {$prov get $path} data]} {
            ::tkutils::tkupreview::message $pv "Cannot read: $data" ; return
        }
        set svgtext [encoding convertfrom utf-8 $data]
        if {$::explorer::haveSvg} {
            _previewSvg $f $pv $title $svgtext
        } else {
            ::tkutils::tkupreview::text $pv "$title  --  (SVG renderer not available, showing source)" $svgtext
        }
        return
    }
    # image / pdf / database previews must read the whole file (a truncated
    # image or PDF will not render), so guard by size: above mediaCap, show a
    # message instead of loading gigabytes and freezing the UI.
    if {[_tooBigMedia $pv $ext [dict get $entry size]]} { return }
    # image extensions: PNG/GIF/PPM/PGM are native to Tk; the rest need the
    # matching Img format package to have loaded (see imgFormats at startup).
    set nativeImg {.png .gif .ppm .pgm}
    set imgExts $nativeImg
    if {"jpeg" in $::explorer::imgFormats} { lappend imgExts .jpg .jpeg }
    if {"tiff" in $::explorer::imgFormats} { lappend imgExts .tif .tiff }
    if {"bmp"  in $::explorer::imgFormats} { lappend imgExts .bmp }
    if {"ico"  in $::explorer::imgFormats} { lappend imgExts .ico }
    if {$ext in $imgExts} {
        if {!$previewKind(image)} { _previewOff $pv "Image preview is turned off." ; return }
        set tmp [_toTemp $f $prov $path $ext]
        if {$tmp eq ""} {
            ::tkutils::tkupreview::message $pv "Cannot read image." ; return
        }
        ::tkutils::tkupreview::image $pv $title $tmp
        return
    }
    switch -- $ext {
        .pdf {
            if {!$previewKind(pdf)} { _previewOff $pv "PDF preview is turned off." ; return }
            set tmp [_toTemp $f $prov $path $ext]
            if {$tmp eq ""} {
                ::tkutils::tkupreview::message $pv "Cannot read PDF." ; return
            }
            _previewPdf $f $pv $title $tmp
        }
        .db - .sqlite - .sqlite3 {
            if {!$previewKind(sqlite)} { _previewOff $pv "SQLite preview is turned off." ; return }
            set tmp [_toTemp $f $prov $path $ext]
            if {$tmp eq ""} {
                ::tkutils::tkupreview::message $pv "Cannot read database." ; return
            }
            ::tkutils::tkupreview::sqlite $pv $title $tmp
        }
        default {
            # unknown type: show a hex dump so binaries are still inspectable.
            # Large files are read only up to a cap via the provider's head()
            # method -- reading and hex-formatting a whole large binary would
            # freeze the UI. The title notes when the dump is truncated.
            if {!$previewKind(hex)} { _previewOff $pv "Hex preview is turned off." ; return }
            _previewHex $f $pv $title $prov $path [dict get $entry size]
        }
    }
}

# For preview kinds that need the whole file (image, pdf, sqlite), refuse files
# above mediaCap with a message rather than loading them entirely. Returns 1 if
# it handled (too big), 0 to continue with the normal preview.
proc ::explorer::_tooBigMedia {pv ext size} {
    variable mediaCap
    set mediaExts {.png .gif .ppm .pgm .jpg .jpeg .tif .tiff .bmp .ico
                   .pdf .db .sqlite .sqlite3}
    if {$ext ni $mediaExts} { return 0 }
    if {[string is integer -strict $size] && $size > $mediaCap} {
        ::tkutils::tkupreview::message $pv \
            "File is [_kb $size] -- too large to preview (limit [_kb $mediaCap]).\nOpen it with an external program instead."
        return 1
    }
    return 0
}

# Text preview with a size cap. A file up to textCap is decoded and rendered
# with its proper viewer (markdown/json/xml/...). A larger file is read only up
# to textCap bytes via head() and shown as PLAIN text -- truncating a structured
# format (JSON/XML/HTML/CSV) mid-way would break its parser, and rendering a
# huge file would freeze the UI. The title says the view is partial.
proc ::explorer::_previewText {f pv title prov path size kind} {
    variable textCap
    set partial [expr {[string is integer -strict $size] && $size > $textCap}]
    if {$partial} {
        if {[catch {$prov head $path $textCap} data]} {
            if {[catch {$prov get $path} data]} {
                ::tkutils::tkupreview::message $pv "Cannot read: $data" ; return
            }
            if {[string length $data] > $textCap} {
                set data [string range $data 0 [expr {$textCap-1}]]
            }
        }
    } else {
        if {[catch {$prov get $path} data]} {
            ::tkutils::tkupreview::message $pv "Cannot read: $data" ; return
        }
    }
    # Providers return raw bytes; text viewers need a decoded string, or UTF-8
    # umlauts show up as mojibake. Strip a UTF-8 BOM if present.
    set text [encoding convertfrom utf-8 $data]
    if {[string index $text 0] eq "\uFEFF"} {
        set text [string range $text 1 end]
    }
    if {$partial} {
        # large file: show the head as plain text (a truncated structured format
        # would not parse). Note the truncation in the title.
        ::tkutils::tkupreview::text $pv \
            "$title    (showing first [_kb [string length $data]] of [_kb $size], as text)" $text
    } else {
        ::tkutils::tkupreview::$kind $pv $title $text
    }
}

# Hex preview with a size cap. Files up to hexCap are shown whole; larger files
# are read only up to hexCap bytes via the provider's head() (falling back to a
# capped get if a provider lacks head), and the title says the view is partial.
proc ::explorer::_previewHex {f pv title prov path size} {
    variable hexCap
    set partial 0
    if {[string is integer -strict $size] && $size > $hexCap} {
        set partial 1
    }
    if {$partial} {
        if {[catch {$prov head $path $hexCap} data]} {
            # provider without head(): fall back to get, then truncate
            if {[catch {$prov get $path} data]} {
                ::tkutils::tkupreview::message $pv "Cannot read file." ; return
            }
            if {[string length $data] > $hexCap} {
                set data [string range $data 0 [expr {$hexCap-1}]]
            }
        }
        set shown [string length $data]
        ::tkutils::tkupreview::hex $pv \
            "$title    (showing first [_kb $shown] of [_kb $size])" $data
    } else {
        if {[catch {$prov get $path} data]} {
            ::tkutils::tkupreview::message $pv "No preview for this file." ; return
        }
        ::tkutils::tkupreview::hex $pv $title $data
    }
}

proc ::explorer::_kb {n} {
    if {![string is integer -strict $n]} { return "$n bytes" }
    if {$n >= 1048576} { return [format "%.1f MB" [expr {$n/1048576.0}]] }
    if {$n >= 1024}    { return [format "%.0f KB" [expr {$n/1024.0}]] }
    return "$n bytes"
}

# Write a provider file's bytes to a temp file so path-based viewers (image,
# PDF) can open it -- providers give bytes, not a real path. One temp per tab;
# the previous one is removed on each new preview so they do not accumulate.
proc ::explorer::_toTemp {f prov path ext} {
    variable tab
    if {[catch {$prov get $path} data]} { return "" }
    if {[dict exists $tab $f tmpfile]} {
        catch {file delete [dict get $tab $f tmpfile]}
    }
    set tmp [file join [_tmpDir] "explorer-preview-[pid]-[clock clicks]$ext"]
    if {[catch {
        set fh [open $tmp wb]
        fconfigure $fh -translation binary
        puts -nonewline $fh $data
        close $fh
    }]} { return "" }
    dict set tab $f tmpfile $tmp
    return $tmp
}

proc ::explorer::_tmpDir {} {
    if {[info exists ::env(TMPDIR)]} { return $::env(TMPDIR) }
    if {[info exists ::env(TEMP)]}   { return $::env(TEMP) }
    return [expr {$::tcl_platform(platform) eq "windows" ? "C:/Temp" : "/tmp"}]
}

# Render an SVG (given as text) to a PNG via tcllunasvg, then show the PNG as an
# image. The rendered PNG is a per-tab temp file, cleaned up like the others.
# On any failure, fall back to showing the SVG source (it is XML).
proc ::explorer::_previewSvg {f pv title svgtext} {
    variable tab
    if {[catch {
        set doc [::tcllunasvg::load data $svgtext]
        if {[dict exists $tab $f tmpfile]} {
            catch {file delete [dict get $tab $f tmpfile]}
        }
        set tmp [file join [_tmpDir] "explorer-preview-[pid]-[clock clicks].png"]
        # render at a sensible width; lunasvg keeps the aspect ratio
        $doc to_png $tmp -width 800
        catch {rename $doc ""}
        dict set tab $f tmpfile $tmp
        ::tkutils::tkupreview::image $pv $title $tmp
    }]} {
        ::tkutils::tkupreview::text $pv "$title  --  (SVG render failed, showing source)" $svgtext
    }
}

# Show a PDF. Uses the render backend decided at startup (::explorer::havePdf).
# No re-detection here -- that is what hid the missing library until click time.
# If PDF rendering is unavailable, say so plainly (the structure inspector is a
# deliberate, named fallback, not a silent one).
proc ::explorer::_previewPdf {f pv title file} {
    variable havePdf
    if {$havePdf} {
        if {[_renderPdfPage $f $pv $title $file]} return
        # backend present but this file failed to render -- report, do not
        # silently fall through as if nothing happened.
        ::tkutils::tkupreview::message $pv \
            "PDF backend is present but could not render this file.\nShowing structure instead."
    }
    # named fallback: the structure inspector (or its own "unavailable" message)
    ::tkutils::tkupreview::pdf $pv $title $file
}

# Render page 0 to a photo and hand it to the preview. Returns 1 on success.
# The photo is tracked per tab and deleted on the next render / tab close.
proc ::explorer::_renderPdfPage {f pv title file} {
    variable tab
    set ok 0
    if {[catch {
        set doc [::pdfium::open $file]
        set imgname "explorer-pdf-[pid]-[clock clicks]"
        set img [::pdfium::render $doc 0 -width 800 -imagename $imgname]
        ::pdfium::close $doc
        # free a previous rendered page for this tab
        if {[dict exists $tab $f pdfimg]} {
            catch {image delete [dict get $tab $f pdfimg]}
        }
        dict set tab $f pdfimg $img
        ::tkutils::tkupreview::photo $pv $title $img
        set ok 1
    } e]} {
        set ok 0
    }
    return $ok
}

proc ::explorer::onPathNavigate {f dir} {
    goto $f $dir
}

# The drive combobox changed: navigate to the chosen drive root.
proc ::explorer::onDriveSelect {f} {
    set cb $f.top.drive
    if {![winfo exists $cb]} return
    set v [$cb get]
    if {$v ne ""} { goto $f $v }
}

# Keep the drive combobox showing the drive of the current directory.
proc ::explorer::_syncDrive {f dir} {
    set cb $f.top.drive
    if {![winfo exists $cb]} return
    # First element of the split is the volume, e.g. "C:/".
    set vol [lindex [file split $dir] 0]
    if {$vol ne "" && $vol in [$cb cget -values]} {
        $cb set $vol
    }
}

# Open a ZIP archive in a NEW tab. This is what makes cross-provider copy
# usable interactively: a ZIP tab and a local tab coexist, each with its own
# provider, and cufileops copies between them (get from ZIP, put to local).
proc ::explorer::openZipTab {w} {
    set file [tk_getOpenFile -title "Open ZIP archive" \
        -filetypes {{{ZIP archives} {.zip}} {{All files} *}}]
    if {$file eq ""} return
    if {[catch {makeSource -zip $file} res]} {
        ::tkutils::tkudialog::showError "Cannot open ZIP:\n$res"
        return
    }
    lassign $res prov start
    newTabWith $w $prov $start
}

# Open a remote connection (sftp/ftp/dav) in a new tab. A small dialog asks for
# the URL and, optionally, provider options (e.g. -identity ~/.ssh/id_ed25519
# for sftp, or -user/-password for ftp/dav). The scheme in the URL selects the
# provider; makeSource -remote loads it on demand.
proc ::explorer::openRemoteTab {w} {
    set dlg .remote
    catch {destroy $dlg}
    toplevel $dlg
    wm title $dlg "Open Remote"
    wm transient $dlg $w

    ttk::label $dlg.hint -justify left -text \
        "Connect to a remote location. Examples:\n  sftp://user@host/path\n  ftp://host/pub\n  https://host/dav  (WebDAV)"
    grid $dlg.hint -row 0 -column 0 -columnspan 2 -sticky w -padx 8 -pady {8 4}

    ttk::label $dlg.ul -text "URL:"
    ttk::entry $dlg.ue -width 46
    grid $dlg.ul -row 1 -column 0 -sticky w -padx {8 0} -pady 2
    grid $dlg.ue -row 1 -column 1 -sticky ew -padx {4 8} -pady 2

    ttk::label $dlg.ol -text "Options:"
    ttk::entry $dlg.oe -width 46
    grid $dlg.ol -row 2 -column 0 -sticky w -padx {8 0} -pady 2
    grid $dlg.oe -row 2 -column 1 -sticky ew -padx {4 8} -pady 2
    ttk::label $dlg.oh -foreground "#777777" -justify left -text \
        "e.g.  -identity ~/.ssh/id_ed25519   or   -user me -password secret"
    grid $dlg.oh -row 3 -column 1 -sticky w -padx {4 8} -pady {0 4}

    ttk::frame $dlg.b
    ttk::button $dlg.b.ok -text "Connect" -command {set ::explorer::_remoteResult ok}
    ttk::button $dlg.b.cancel -text "Cancel" -command {set ::explorer::_remoteResult cancel}
    pack $dlg.b.cancel $dlg.b.ok -side right -padx 2
    grid $dlg.b -row 4 -column 0 -columnspan 2 -sticky ew -padx 6 -pady 6
    grid columnconfigure $dlg 1 -weight 1

    set ::explorer::_remoteResult ""
    bind $dlg.ue <Return> {set ::explorer::_remoteResult ok}
    tkwait visibility $dlg ; grab $dlg ; focus $dlg.ue
    vwait ::explorer::_remoteResult
    set act $::explorer::_remoteResult
    set url [string trim [$dlg.ue get]]
    set opts [string trim [$dlg.oe get]]
    catch {grab release $dlg} ; destroy $dlg
    if {$act ne "ok" || $url eq ""} return

    # expand a leading ~ in an -identity path (Tcl 9 no longer expands ~)
    set optList {}
    foreach tok $opts {
        if {[string match "~/*" $tok]} {
            set home [expr {[info exists ::env(HOME)] ? $::env(HOME) : ""}]
            if {$home ne ""} { set tok [file join $home [string range $tok 2 end]] }
        }
        lappend optList $tok
    }
    if {[catch {makeSource -remote $url {*}$optList} res]} {
        _remoteError "Cannot connect to\n$url\n\n$res"
        return
    }
    lassign $res prov start
    newTabWith $w $prov $start
    setStatus "Connected: $url" $w
}

proc ::explorer::_remoteError {msg} {
    if {![catch {::tkutils::tkudialog::showError $msg}]} return
    catch {tk_messageBox -icon error -title "Remote" -message $msg}
    setStatus [string map {\n { }} $msg]
}

# ---- Sync folders dialog --------------------------------------------------
# Compare two directories and mirror newer/missing entries one way. The heavy
# lifting is in ctrlutils::cusync (provider-agnostic); this is just the UI. The
# dialog is a child of its window ([_wp $w syncdlg]) so each window can have its
# own. Defaults the left side to the current tab's directory.
proc ::explorer::openSyncDialog {w {leftDir ""}} {
    variable tab
    variable haveSync
    if {!$haveSync} {
        set msg "Sync needs the ctrlutils::cusync module.\n\nInstall the cusync module next to the other ctrlutils\nmodules (ctrlutils/lib/tm/ctrlutils/) and restart."
        if {[catch {::tkutils::tkudialog::showError $msg -parent $w}]} {
            catch {tk_messageBox -parent $w -icon error -title "Sync unavailable" -message $msg}
        }
        return
    }
    set dlg [_wp $w syncdlg]
    if {[winfo exists $dlg]} { raise $dlg ; focus $dlg ; return }

    if {$leftDir eq ""} {
        set f [_curTab $w]
        if {$f ne "" && [dict exists $tab $f cur]} { set leftDir [dict get $tab $f cur] }
    }

    toplevel $dlg
    wm title $dlg "Sync folders"
    wm transient $dlg $w
    wm geometry $dlg 640x460

    variable _syncLeft  ; variable _syncRight ; variable _syncDir
    set _syncLeft($dlg)  $leftDir
    set _syncRight($dlg) ""
    set _syncDir($dlg)   LR

    # -- folder pickers
    ttk::frame $dlg.top -padding 8
    pack $dlg.top -side top -fill x
    ttk::label $dlg.top.ll -text "Left folder:"
    ttk::entry $dlg.top.le -textvariable ::explorer::_syncLeft($dlg)
    ttk::button $dlg.top.lb -text "Browse..." \
        -command [list ::explorer::_syncBrowse $dlg left]
    ttk::label $dlg.top.rl -text "Right folder:"
    ttk::entry $dlg.top.re -textvariable ::explorer::_syncRight($dlg)
    ttk::button $dlg.top.rb -text "Browse..." \
        -command [list ::explorer::_syncBrowse $dlg right]
    grid $dlg.top.ll -row 0 -column 0 -sticky w -padx {0 6} -pady 2
    grid $dlg.top.le -row 0 -column 1 -sticky ew -pady 2
    grid $dlg.top.lb -row 0 -column 2 -sticky w -padx {6 0} -pady 2
    grid $dlg.top.rl -row 1 -column 0 -sticky w -padx {0 6} -pady 2
    grid $dlg.top.re -row 1 -column 1 -sticky ew -pady 2
    grid $dlg.top.rb -row 1 -column 2 -sticky w -padx {6 0} -pady 2
    grid columnconfigure $dlg.top 1 -weight 1

    # -- direction + compare
    ttk::frame $dlg.dir -padding {8 0 8 4}
    pack $dlg.dir -side top -fill x
    ttk::radiobutton $dlg.dir.lr -text "Left -> Right" \
        -variable ::explorer::_syncDir($dlg) -value LR
    ttk::radiobutton $dlg.dir.rl -text "Right -> Left" \
        -variable ::explorer::_syncDir($dlg) -value RL
    ttk::button $dlg.dir.cmp -text "Compare" \
        -command [list ::explorer::_syncCompare $dlg]
    pack $dlg.dir.lr $dlg.dir.rl -side left -padx {0 12}
    pack $dlg.dir.cmp -side right
    ttk::label $dlg.dir.hint -foreground "#777777" \
        -text "Copies missing and newer entries. Never deletes."
    pack $dlg.dir.hint -side left -padx 12

    # -- diff list
    ttk::frame $dlg.body -padding {8 0}
    pack $dlg.body -side top -fill both -expand 1
    ttk::treeview $dlg.body.tv -columns {status} -show {tree headings} \
        -yscrollcommand [list $dlg.body.sb set]
    $dlg.body.tv heading #0 -text "Path"
    $dlg.body.tv heading status -text "Status"
    $dlg.body.tv column status -width 130 -stretch 0
    ttk::scrollbar $dlg.body.sb -orient vertical -command [list $dlg.body.tv yview]
    pack $dlg.body.sb -side right -fill y
    pack $dlg.body.tv -side left -fill both -expand 1

    # -- buttons
    ttk::frame $dlg.btn -padding 8
    pack $dlg.btn -side bottom -fill x
    ttk::label $dlg.btn.status -textvariable ::explorer::_syncStatus($dlg) -anchor w
    ttk::progressbar $dlg.btn.pb -mode determinate
    ttk::button $dlg.btn.cancel -text "Cancel" \
        -command [list ::explorer::_syncCancelOp $dlg]
    ttk::button $dlg.btn.sync  -text "Sync" \
        -command [list ::explorer::_syncApply $dlg]
    ttk::button $dlg.btn.close -text "Close" \
        -command [list destroy $dlg]
    pack $dlg.btn.close -side right
    pack $dlg.btn.sync  -side right -padx {0 6}
    pack $dlg.btn.status -side left -fill x -expand 1
    set ::explorer::_syncStatus($dlg) ""
    set ::explorer::_syncBusy($dlg) 0

    # clean up per-dialog state on close
    bind $dlg <Destroy> [list ::explorer::_syncCleanup %W $dlg]
    return $dlg
}

proc ::explorer::_syncBrowse {dlg side} {
    variable _syncLeft ; variable _syncRight
    set var [expr {$side eq "left" ? "_syncLeft" : "_syncRight"}]
    set cur [set ::explorer::${var}($dlg)]
    set d [tk_chooseDirectory -parent $dlg -title "Choose folder" \
        -initialdir [expr {[file isdirectory $cur] ? $cur : [pwd]}]]
    if {$d ne ""} { set ::explorer::${var}($dlg) $d }
}

# Open a local provider for a dialog side and run the comparison, filling the
# treeview. Providers are kept in state so Sync reuses them.
proc ::explorer::_syncCompare {dlg} {
    variable _syncLeft ; variable _syncRight ; variable _syncProv
    set L $::explorer::_syncLeft($dlg)
    set R $::explorer::_syncRight($dlg)
    if {![file isdirectory $L] || ![file isdirectory $R]} {
        set ::explorer::_syncStatus($dlg) "Pick two existing folders first."
        return
    }
    # (re)create providers for these two local folders
    _syncFreeProv $dlg
    set pL [::tclutils::tuprovider open local]
    set pR [::tclutils::tuprovider open local]
    set _syncProv($dlg) [list $pL $pR]

    if {[catch {::ctrlutils::cusync::compare $pL $L $pR $R} diffs]} {
        set ::explorer::_syncStatus($dlg) "Compare failed: $diffs"
        return
    }
    variable _syncDiffs
    set _syncDiffs($dlg) $diffs

    set tv $dlg.body.tv
    $tv delete [$tv children {}]
    set nCopy 0
    foreach d $diffs {
        set st [dict get $d status]
        if {$st eq "same"} continue
        $tv insert {} end -text [dict get $d rel] -values [list [_syncLabel $st]]
        if {$st ni {same conflict}} { incr nCopy }
    }
    set nSame [_syncCount $diffs same]
    set nDiff [expr {[llength $diffs] - $nSame}]
    set ::explorer::_syncStatus($dlg) "$nDiff differences, $nSame identical."
}

proc ::explorer::_syncLabel {st} {
    return [dict get {
        onlyLeft   "only left"   onlyRight  "only right"
        newerLeft  "newer left"  newerRight "newer right"
        diff       "differs"     same       "same"
        conflict   "conflict"
    } $st]
}
proc ::explorer::_syncCount {diffs st} {
    set n 0 ; foreach d $diffs { if {[dict get $d status] eq $st} { incr n } }
    return $n
}

# Mirror in the chosen direction, then re-compare so the list reflects reality.
proc ::explorer::_syncApply {dlg} {
    variable _syncDiffs ; variable _syncProv ; variable _syncDir
    variable _syncLeft ; variable _syncRight ; variable _syncBusy
    if {![info exists _syncDiffs($dlg)] || ![info exists _syncProv($dlg)]} {
        set ::explorer::_syncStatus($dlg) "Compare first."
        return
    }
    if {[info exists _syncBusy($dlg)] && $_syncBusy($dlg)} return
    lassign $_syncProv($dlg) pL pR
    set L $::explorer::_syncLeft($dlg)
    set R $::explorer::_syncRight($dlg)
    set dir $::explorer::_syncDir($dlg)
    set acts [::ctrlutils::cusync::plan $_syncDiffs($dlg) $dir]
    if {[llength $acts] == 0} {
        set ::explorer::_syncStatus($dlg) "Nothing to copy for this direction."
        return
    }
    # resolve source/target provider+dir once, by direction
    if {$dir eq "LR"} {
        set ::explorer::_syncSP($dlg) $pL ; set ::explorer::_syncSD($dlg) $L
        set ::explorer::_syncDP($dlg) $pR ; set ::explorer::_syncDD($dlg) $R
    } else {
        set ::explorer::_syncSP($dlg) $pR ; set ::explorer::_syncSD($dlg) $R
        set ::explorer::_syncDP($dlg) $pL ; set ::explorer::_syncDD($dlg) $L
    }
    set ::explorer::_syncActs($dlg)  $acts
    set ::explorer::_syncIdx($dlg)   0
    set ::explorer::_syncDoneN($dlg) 0
    set ::explorer::_syncErrs($dlg)  {}
    set ::explorer::_syncCancel($dlg) 0
    set _syncBusy($dlg) 1

    # show progress + cancel, hide status, lock Sync/Compare
    $dlg.btn.pb configure -maximum [llength $acts] -value 0
    pack forget $dlg.btn.status
    pack $dlg.btn.pb -side left -fill x -expand 1 -padx {0 8}
    pack $dlg.btn.cancel -side right -padx {0 6} -before $dlg.btn.close
    catch {$dlg.btn.sync state disabled}
    catch {$dlg.dir.cmp state disabled}
    set ::explorer::_syncStatus($dlg) "0 / [llength $acts]"

    # step through the plan one action per event-loop tick, so the bar repaints
    # and Cancel stays responsive (no update-reentrancy, no frozen UI).
    after 0 [list ::explorer::_syncStep $dlg]
}

proc ::explorer::_syncStep {dlg} {
    if {![winfo exists $dlg]} return
    set acts  $::explorer::_syncActs($dlg)
    set i     $::explorer::_syncIdx($dlg)
    set total [llength $acts]
    if {$::explorer::_syncCancel($dlg) || $i >= $total} {
        _syncFinish $dlg
        return
    }
    set a [lindex $acts $i]
    set r [::ctrlutils::cusync::applyOne \
               $::explorer::_syncSP($dlg) $::explorer::_syncSD($dlg) \
               $::explorer::_syncDP($dlg) $::explorer::_syncDD($dlg) $a]
    if {[dict get $r ok]} {
        incr ::explorer::_syncDoneN($dlg)
    } else {
        lappend ::explorer::_syncErrs($dlg) [dict get $r error]
    }
    incr ::explorer::_syncIdx($dlg)
    catch {$dlg.btn.pb configure -value $::explorer::_syncIdx($dlg)}
    set ::explorer::_syncStatus($dlg) \
        "$::explorer::_syncIdx($dlg) / $total  ([dict get $a rel])"
    after 0 [list ::explorer::_syncStep $dlg]
}

proc ::explorer::_syncCancelOp {dlg} {
    if {[info exists ::explorer::_syncCancel($dlg)]} {
        set ::explorer::_syncCancel($dlg) 1
    }
}

proc ::explorer::_syncFinish {dlg} {
    variable _syncBusy
    if {![winfo exists $dlg]} {
        set _syncBusy($dlg) 0
        return
    }
    set done      $::explorer::_syncDoneN($dlg)
    set errs      $::explorer::_syncErrs($dlg)
    set cancelled $::explorer::_syncCancel($dlg)
    # restore UI
    catch {pack forget $dlg.btn.pb}
    catch {pack forget $dlg.btn.cancel}
    catch {pack $dlg.btn.status -side left -fill x -expand 1}
    catch {$dlg.btn.sync state !disabled}
    catch {$dlg.dir.cmp state !disabled}
    set _syncBusy($dlg) 0

    set msg [expr {$cancelled ? "Cancelled -- $done copied" : "Copied $done"}]
    if {[llength $errs] > 0} { append msg ", [llength $errs] error(s)" }
    set ::explorer::_syncStatus($dlg) $msg
    _syncCompare $dlg
    _syncRefreshTabs $dlg
}

# After a sync, reload any tab (in any window) whose directory is one of the two
# synced folders, so the change is visible immediately.
proc ::explorer::_syncRefreshTabs {dlg} {
    variable tab ; variable _syncLeft ; variable _syncRight
    set dirs [list [file normalize $::explorer::_syncLeft($dlg)] \
                   [file normalize $::explorer::_syncRight($dlg)]]
    foreach f [dict keys $tab] {
        if {![dict exists $tab $f cur]} continue
        if {[file normalize [dict get $tab $f cur]] in $dirs} {
            catch {::tkutils::tkufilelist::refresh [dict get $tab $f list]}
        }
    }
}

proc ::explorer::_syncFreeProv {dlg} {
    variable _syncProv
    if {[info exists _syncProv($dlg)]} {
        foreach p $_syncProv($dlg) { catch {$p destroy} }
        unset _syncProv($dlg)
    }
}

proc ::explorer::_syncCleanup {ww dlg} {
    if {$ww ne $dlg} return   ;# only the dialog toplevel's own <Destroy>
    _syncFreeProv $dlg
    foreach v {_syncLeft _syncRight _syncDir _syncDiffs _syncStatus
               _syncActs _syncIdx _syncDoneN _syncErrs _syncCancel _syncBusy
               _syncSP _syncSD _syncDP _syncDD} {
        unset -nocomplain ::explorer::${v}($dlg)
    }
}

# ---- Find in current list (Ctrl+F) ----------------------------------------
# Incremental find over the current tab's file list. Uses tkutils::tkutlfind,
# which highlights matching cells in the tablelist and steps through them (as
# opposed to the filter above the list, which hides non-matching rows).

# Build the (hidden) find bar for a tab, as a child of the list wrapper so it
# survives layout switches. Shown by _findInList, hidden by _findClose.
proc ::explorer::_buildFindBar {f bar} {
    variable findQuery ; variable findCount
    set findQuery($f) "" ; set findCount($f) ""
    ttk::frame $bar
    ttk::label  $bar.l -text "Find:"
    ttk::entry  $bar.e -textvariable ::explorer::findQuery($f)
    ttk::label  $bar.n -textvariable ::explorer::findCount($f) -width 10 -anchor e
    ttk::button $bar.prev -text "<" -width 3 -command [list ::explorer::_findStep $f -1]
    ttk::button $bar.next -text ">" -width 3 -command [list ::explorer::_findStep $f 1]
    ttk::button $bar.x    -text "x" -width 3 -command [list ::explorer::_findClose $f]
    pack $bar.l -side left -padx {4 4}
    pack $bar.e -side left -fill x -expand 1
    pack $bar.x    -side right -padx {2 4}
    pack $bar.next -side right
    pack $bar.prev -side right
    pack $bar.n    -side right -padx 6
    bind $bar.e <KeyRelease>       [list ::explorer::_findRun $f]
    bind $bar.e <Return>           [list ::explorer::_findStep $f 1]
    bind $bar.e <Shift-Return>     [list ::explorer::_findStep $f -1]
    bind $bar.e <Escape>           [list ::explorer::_findClose $f]
    return $bar
}

proc ::explorer::_findTbl {f} {
    variable tab
    if {![dict exists $tab $f list]} { return "" }
    return [::tkutils::tkutablelist::tableWidget [dict get $tab $f list]]
}

# Show the current tab's find bar and focus it.
proc ::explorer::_findInList {w} {
    variable haveListFind
    if {!$haveListFind} {
        set msg "Find in list needs the tkutils::tkutlfind module.\n\nInstall the tkutlfind module with the other tkutils modules."
        if {[catch {::tkutils::tkudialog::showError $msg -parent $w}]} {
            catch {tk_messageBox -parent $w -icon error -title "Find unavailable" -message $msg}
        }
        return
    }
    set f [_curTab $w] ; if {$f eq ""} return
    set bar $f.vlist.find
    if {![winfo exists $bar]} return
    if {[winfo manager $bar] eq ""} { pack $bar -side bottom -fill x -pady {2 0} }
    focus $bar.e
    $bar.e selection range 0 end
    _findRun $f
}

proc ::explorer::_findRun {f} {
    variable findQuery ; variable findCount
    set tbl [_findTbl $f] ; if {$tbl eq ""} return
    set q $findQuery($f)
    if {$q eq ""} {
        catch {::tkutils::tkutlfind::clear $tbl}
        set findCount($f) ""
        return
    }
    set n [::tkutils::tkutlfind::find $tbl $q -columns 0]
    set findCount($f) [expr {$n == 0 ? "no match" : "$n found"}]
    if {$n > 0} { _findSee $f [::tkutils::tkutlfind::next $tbl] }
}

proc ::explorer::_findStep {f dir} {
    set tbl [_findTbl $f] ; if {$tbl eq ""} return
    if {$dir > 0} {
        _findSee $f [::tkutils::tkutlfind::next $tbl]
    } else {
        _findSee $f [::tkutils::tkutlfind::prev $tbl]
    }
}

proc ::explorer::_findSee {f rc} {
    if {$rc eq ""} return
    set tbl [_findTbl $f] ; if {$tbl eq ""} return
    lassign $rc row col
    catch {
        $tbl selection clear 0 end
        $tbl selection set $row
        $tbl activate $row
        $tbl see $row
    }
}

proc ::explorer::_findClose {f} {
    variable findQuery ; variable findCount
    set tbl [_findTbl $f]
    if {$tbl ne ""} { catch {::tkutils::tkutlfind::clear $tbl} }
    set findQuery($f) "" ; set findCount($f) ""
    set bar $f.vlist.find
    if {[winfo exists $bar] && [winfo manager $bar] ne ""} { pack forget $bar }
    catch {focus [dict get $::explorer::tab $f list]}
}

# ---- Find files (recursive) -----------------------------------------------
# A dialog that finds files under a directory by name (glob) and optionally by
# content, using tclutils::tufind + tclutils::tugrep (local filesystem). Results
# open in the current tab (navigate to the file and select it).

proc ::explorer::openFindDialog {w {startDir ""}} {
    variable tab
    # Find files now walks the tab's provider cooperatively (no tufind/tugrep
    # needed), so it is always available -- only a provider is required.
    set dlg [_wp $w finddlg]
    if {[winfo exists $dlg]} { raise $dlg ; focus $dlg ; return }

    # Capture the provider and directory of the tab we were opened from, so the
    # search runs against THAT source (local, zip, sftp, dav) -- not just local.
    set srcTab [_curTab $w]
    set prov ""
    if {$srcTab ne "" && [dict exists $tab $srcTab prov]} {
        set prov [dict get $tab $srcTab prov]
        if {$startDir eq "" && [dict exists $tab $srcTab cur]} {
            set startDir [dict get $tab $srcTab cur]
        }
    }

    variable _findDir ; variable _findName ; variable _findText
    variable _findHidden ; variable _findWin ; variable _findProv ; variable _findSrcTab
    variable _findOwn
    # If there is no source tab (no provider), search the local filesystem with
    # our own provider, cleaned up when the dialog closes.
    if {$prov eq ""} { set prov [::tclutils::tuprovider open local] ; set _findOwn($dlg) 1 }
    set _findDir($dlg)    $startDir
    set _findName($dlg)   "*"
    set _findText($dlg)   ""
    set _findHidden($dlg) 0
    set _findWin($dlg)    $w
    set _findProv($dlg)   $prov
    set _findSrcTab($dlg) $srcTab

    toplevel $dlg
    wm title $dlg "Find files"
    wm transient $dlg $w
    wm geometry $dlg 660x470

    ttk::frame $dlg.top -padding 8
    pack $dlg.top -side top -fill x
    ttk::label  $dlg.top.dl -text "In folder:"
    ttk::entry  $dlg.top.de -textvariable ::explorer::_findDir($dlg)
    ttk::button $dlg.top.db -text "Browse..." -command [list ::explorer::_findFilesBrowse $dlg]
    ttk::label  $dlg.top.nl -text "Name (glob):"
    ttk::entry  $dlg.top.ne -textvariable ::explorer::_findName($dlg)
    ttk::label  $dlg.top.cl -text "Contains text:"
    ttk::entry  $dlg.top.ce -textvariable ::explorer::_findText($dlg)
    grid $dlg.top.dl -row 0 -column 0 -sticky w -padx {0 6} -pady 2
    grid $dlg.top.de -row 0 -column 1 -sticky ew -pady 2
    grid $dlg.top.db -row 0 -column 2 -sticky w -padx {6 0} -pady 2
    grid $dlg.top.nl -row 1 -column 0 -sticky w -padx {0 6} -pady 2
    grid $dlg.top.ne -row 1 -column 1 -sticky ew -pady 2
    grid $dlg.top.cl -row 2 -column 0 -sticky w -padx {0 6} -pady 2
    grid $dlg.top.ce -row 2 -column 1 -sticky ew -pady 2
    grid columnconfigure $dlg.top 1 -weight 1
    # Browse (tk_chooseDirectory) only makes sense for the local filesystem;
    # for zip/sftp/dav the folder is a provider path derived from the tab.
    if {$prov ne "" && ![_isLocalProv $prov]} { $dlg.top.db state disabled }

    ttk::frame $dlg.opt -padding {8 0 8 4}
    pack $dlg.opt -side top -fill x
    ttk::checkbutton $dlg.opt.h -text "Include hidden files" \
        -variable ::explorer::_findHidden($dlg)
    ttk::button $dlg.opt.go -text "Find" -command [list ::explorer::_findFilesRun $dlg]
    ttk::button $dlg.opt.stop -text "Stop" -command [list ::explorer::_findFilesStop $dlg]
    pack $dlg.opt.h -side left
    pack $dlg.opt.go -side right

    ttk::frame $dlg.body -padding {8 0}
    pack $dlg.body -side top -fill both -expand 1
    ttk::treeview $dlg.body.tv -columns {size} -show {tree headings} \
        -yscrollcommand [list $dlg.body.sb set]
    $dlg.body.tv heading #0 -text "File (relative to folder)"
    $dlg.body.tv heading size -text "Size"
    $dlg.body.tv column size -width 90 -stretch 0 -anchor e
    ttk::scrollbar $dlg.body.sb -orient vertical -command [list $dlg.body.tv yview]
    pack $dlg.body.sb -side right -fill y
    pack $dlg.body.tv -side left -fill both -expand 1
    bind $dlg.body.tv <Double-1> [list ::explorer::_findFilesOpen $dlg]
    bind $dlg.body.tv <Return>   [list ::explorer::_findFilesOpen $dlg]

    ttk::frame $dlg.btn -padding 8
    pack $dlg.btn -side bottom -fill x
    ttk::label  $dlg.btn.status -textvariable ::explorer::_findStatus($dlg) -anchor w
    ttk::button $dlg.btn.open  -text "Open"  -command [list ::explorer::_findFilesOpen $dlg]
    ttk::button $dlg.btn.close -text "Close" -command [list destroy $dlg]
    pack $dlg.btn.close -side right
    pack $dlg.btn.open  -side right -padx {0 6}
    pack $dlg.btn.status -side left -fill x -expand 1
    set ::explorer::_findStatus($dlg) ""

    bind $dlg <Destroy> [list ::explorer::_findFilesCleanup %W $dlg]
    focus $dlg.top.ne
    return $dlg
}

# True if a provider is the local filesystem provider.
proc ::explorer::_isLocalProv {prov} {
    return [expr {[namespace tail [info object class $prov]] eq "Local"}]
}

# Recursive file find over ANY provider (local, zip, sftp, dav), using the
# provider's list. Returns full provider paths of files whose name matches one
# of the glob patterns. Uses each entry's own path for recursion, so no manual
# path joining is needed.
proc ::explorer::_provFind {prov dir pats hidden} {
    set out {}
    if {[catch {$prov list $dir} entries]} { return $out }
    foreach e $entries {
        set name [dict get $e name]
        if {!$hidden && [string index $name 0] eq "."} continue
        set type [dict get $e type]
        set path [dict get $e path]
        if {$type eq "dir"} {
            lappend out {*}[_provFind $prov $path $pats $hidden]
        } else {
            foreach p $pats {
                if {[string match $p $name]} { lappend out $path ; break }
            }
        }
    }
    return $out
}

# Keep only files whose content contains $text (case-insensitive), read via the
# provider. Used for content search on non-local providers.
proc ::explorer::_provGrep {prov files text} {
    set out {} ; set needle [string tolower $text]
    foreach path $files {
        if {[catch {$prov get $path} data]} continue
        if {[string first $needle [string tolower $data]] >= 0} { lappend out $path }
    }
    return $out
}

# Parent directory of a provider path (file dirname for local; "/"-based split
# for the others, whose paths are always forward-slash).
proc ::explorer::_pathParent {prov path} {
    if {[_isLocalProv $prov]} { return [file dirname $path] }
    set i [string last / $path]
    if {$i <= 0} { return "/" }
    return [string range $path 0 [expr {$i - 1}]]
}

# Path of $path relative to $base (provider-agnostic string operation).
proc ::explorer::_relOf {base path} {
    set b [string trimright $base /]
    if {$b eq ""} { return [string trimleft $path /] }
    if {[string first "$b/" $path] == 0} {
        return [string range $path [expr {[string length $b] + 1}] end]
    }
    if {$path eq $b} { return [file tail $path] }
    return $path
}

proc ::explorer::_findFilesBrowse {dlg} {
    variable _findDir
    set cur $::explorer::_findDir($dlg)
    set d [tk_chooseDirectory -parent $dlg -title "Choose folder" \
        -initialdir [expr {[file isdirectory $cur] ? $cur : [pwd]}]]
    if {$d ne ""} { set ::explorer::_findDir($dlg) $d }
}

proc ::explorer::_findFilesRun {dlg} {
    variable _findRes ; variable _findBusy
    if {[info exists _findBusy($dlg)] && $_findBusy($dlg)} return
    set dir  $::explorer::_findDir($dlg)
    set name $::explorer::_findName($dlg)
    set prov $::explorer::_findProv($dlg)
    if {$name eq ""} { set name "*" }

    if {[_isLocalProv $prov]} {
        if {![file isdirectory $dir]} {
            set ::explorer::_findStatus($dlg) "Pick an existing folder first."
            return
        }
    } else {
        if {[catch {$prov list $dir}]} {
            set ::explorer::_findStatus($dlg) "Cannot list: $dir"
            return
        }
    }

    # reset results and set up the cooperative walk state
    set tv $dlg.body.tv
    $tv delete [$tv children {}]
    array unset _findRes ${dlg},*
    set ::explorer::_findWork($dlg)    [list $dir]
    set ::explorer::_findScanned($dlg) 0
    set ::explorer::_findMatches($dlg) 0
    set ::explorer::_findCancel($dlg)  0
    set ::explorer::_findPats($dlg)    [regexp -all -inline {\S+} $name]
    set ::explorer::_findTextV($dlg)   $::explorer::_findText($dlg)
    set ::explorer::_findHiddenV($dlg) $::explorer::_findHidden($dlg)
    set ::explorer::_findProvV($dlg)   $prov
    set ::explorer::_findBaseDir($dlg) $dir
    set _findBusy($dlg) 1

    catch {$dlg.opt.go state disabled}
    pack $dlg.opt.stop -side right -padx {0 6} -before $dlg.opt.go
    set ::explorer::_findStatus($dlg) "Searching..."
    after 0 [list ::explorer::_findWalkStep $dlg]
}

# One batch of the recursive walk per event-loop tick: pop directories from the
# worklist, list each via the provider, stream matching files into the results
# view, and push subdirectories back onto the worklist. Runs a small budget of
# directories per tick so the UI stays responsive and Stop works. Uniform over
# local/zip/sftp/dav because it only uses the provider's list/get.
proc ::explorer::_findWalkStep {dlg} {
    if {![winfo exists $dlg]} return
    if {$::explorer::_findCancel($dlg)} { _findFilesDone $dlg ; return }
    set work $::explorer::_findWork($dlg)
    if {[llength $work] == 0} { _findFilesDone $dlg ; return }

    set prov   $::explorer::_findProvV($dlg)
    set pats   $::explorer::_findPats($dlg)
    set text   $::explorer::_findTextV($dlg)
    set hidden $::explorer::_findHiddenV($dlg)
    set base   $::explorer::_findBaseDir($dlg)
    set tv     $dlg.body.tv
    set budget 15

    while {$budget > 0 && [llength $work] > 0} {
        set d [lindex $work 0]
        set work [lrange $work 1 end]
        incr ::explorer::_findScanned($dlg)
        incr budget -1
        if {[catch {$prov list $d} entries]} continue
        foreach e $entries {
            set nm [dict get $e name]
            if {!$hidden && [string index $nm 0] eq "."} continue
            set tp [dict get $e type]
            set pth [dict get $e path]
            if {$tp eq "dir"} {
                lappend work $pth
                continue
            }
            set match 0
            foreach p $pats { if {[string match $p $nm]} { set match 1 ; break } }
            if {$match && $text ne ""} {
                set match 0
                if {![catch {$prov get $pth} data]} {
                    if {[string first [string tolower $text] [string tolower $data]] >= 0} {
                        set match 1
                    }
                }
            }
            if {$match} {
                set id [$tv insert {} end -text [_relOf $base $pth] \
                            -values [list [dict get $e size]]]
                set ::explorer::_findRes($dlg,$id) $pth
                incr ::explorer::_findMatches($dlg)
            }
        }
    }
    set ::explorer::_findWork($dlg) $work
    set ::explorer::_findStatus($dlg) \
        "scanned $::explorer::_findScanned($dlg) folders, $::explorer::_findMatches($dlg) found..."
    after 0 [list ::explorer::_findWalkStep $dlg]
}

proc ::explorer::_findFilesStop {dlg} {
    if {[info exists ::explorer::_findCancel($dlg)]} {
        set ::explorer::_findCancel($dlg) 1
    }
}

proc ::explorer::_findFilesDone {dlg} {
    variable _findBusy
    if {![winfo exists $dlg]} { set _findBusy($dlg) 0 ; return }
    set m         $::explorer::_findMatches($dlg)
    set cancelled $::explorer::_findCancel($dlg)
    catch {pack forget $dlg.opt.stop}
    catch {$dlg.opt.go state !disabled}
    set _findBusy($dlg) 0
    set ::explorer::_findStatus($dlg) \
        [expr {$cancelled ? "Stopped -- $m found"
                          : "$m file[expr {$m==1?{}:{s}}] found."}]
}

proc ::explorer::_relpath {base path} {
    set b [file normalize $base] ; set p [file normalize $path]
    if {$p eq $b} { return [file tail $p] }
    set bp "$b/"
    if {[string first $bp $p] == 0} { return [string range $p [string length $bp] end] }
    return $p
}

# Open the selected result in the current tab: navigate to its folder and select
# the file.
proc ::explorer::_findFilesOpen {dlg} {
    variable _findRes ; variable _findWin ; variable _findProv ; variable _findSrcTab
    variable tab
    set tv $dlg.body.tv
    set id [lindex [$tv selection] 0]
    if {$id eq ""} { set id [$tv focus] }
    if {$id eq "" || ![info exists _findRes($dlg,$id)]} return
    set path $_findRes($dlg,$id)
    set prov $::explorer::_findProv($dlg)
    set w $::explorer::_findWin($dlg)
    if {![winfo exists $w]} { set w . }

    set parent [_pathParent $prov $path]
    set name   [file tail $path]

    # Prefer the tab we searched from (same provider); fall back to the current
    # tab if it shares the provider; for local, open a fresh tab if needed.
    set f $::explorer::_findSrcTab($dlg)
    if {$f eq "" || ![dict exists $tab $f]} { set f [_curTab $w] }
    if {$f eq "" || ($prov ne "" && [dict exists $tab $f prov] \
                    && [dict get $tab $f prov] ne $prov)} {
        if {$prov eq "" || [_isLocalProv $prov]} {
            newTab $w $parent
            return
        }
        set ::explorer::_findStatus($dlg) "Open the matching tab to navigate there."
        return
    }
    goto $f $parent
    after idle [list ::explorer::_selectInList $f $name]
    raise $w
}

# Select the row whose Name column equals $name in a tab's list.
proc ::explorer::_selectInList {f name} {
    set tbl [_findTbl $f] ; if {$tbl eq ""} return
    set rows [$tbl get 0 end]
    set idx 0
    foreach row $rows {
        if {[lindex $row 0] eq $name} {
            catch {
                $tbl selection clear 0 end
                $tbl selection set $idx
                $tbl activate $idx
                $tbl see $idx
            }
            return
        }
        incr idx
    }
}

proc ::explorer::_findFilesCleanup {ww dlg} {
    if {$ww ne $dlg} return
    variable _findRes ; variable _findOwn ; variable _findProv
    # cancel any running walk
    if {[info exists ::explorer::_findCancel($dlg)]} { set ::explorer::_findCancel($dlg) 1 }
    # destroy a provider we opened ourselves
    if {[info exists _findOwn($dlg)] && [info exists _findProv($dlg)]} {
        catch {[set _findProv($dlg)] destroy}
    }
    array unset _findRes ${dlg},*
    foreach v {_findDir _findName _findText _findHidden _findWin _findStatus _findProv _findSrcTab
               _findOwn _findWork _findScanned _findMatches _findCancel _findPats
               _findTextV _findHiddenV _findProvV _findBaseDir _findBusy} {
        unset -nocomplain ::explorer::${v}($dlg)
    }
}

# ---- Drag and drop between panes / tabs / windows -------------------------
# In-process drag and drop: drag a file from one list and drop it onto another
# tab's list or tree (in the same window or another window) to copy it there;
# hold Shift to move. It reuses cufileops copy/cut + paste, so the transfer is
# cross-provider and undoable, exactly like the clipboard path. No tkdnd needed
# because every Explorer window lives in one process.
#
# Bindings go on the tablelist body PATH (not its bodytag): the body path tag
# runs before Tablelist's own body bindings, so an active drag can return break
# to suppress range-selection while dragging.

proc ::explorer::_dndInstall {f} {
    variable tab
    set tbl  [::tkutils::tkutablelist::tableWidget [dict get $tab $f list]]
    set body [$tbl bodypath]
    bind $body <ButtonPress-1>   +[list ::explorer::_dndPress   %X %Y $f]
    bind $body <B1-Motion>       +[list ::explorer::_dndMotion  %X %Y %s $f]
    bind $body <ButtonRelease-1> +[list ::explorer::_dndRelease %X %Y %s $f]
}

proc ::explorer::_dndPress {X Y f} {
    variable dndArmed ; variable dndActive ; variable dndSrcF
    variable dndX0 ; variable dndY0
    set dndArmed 1 ; set dndActive 0 ; set dndSrcF $f
    set dndX0 $X ; set dndY0 $Y
    return
}

proc ::explorer::_dndMotion {X Y s f} {
    variable dndArmed ; variable dndActive ; variable dndX0 ; variable dndY0
    variable dndEntries ; variable tab
    if {!$dndArmed} return
    if {!$dndActive} {
        if {abs($X - $dndX0) + abs($Y - $dndY0) < 6} return
        # drag the whole selection; drop ".." (parent) entries
        set sel {}
        foreach e [::tkutils::tkufilelist::selectedEntries [dict get $tab $f list]] {
            if {[dict get $e name] ne ".."} { lappend sel $e }
        }
        if {![llength $sel]} { set dndArmed 0 ; return }
        set dndEntries $sel
        set dndActive 1
        _dndLabelCreate
    }
    _dndLabelUpdate [_dndMode $s $f] $X $Y
    return -code break
}

proc ::explorer::_dndRelease {X Y s f} {
    variable dndArmed ; variable dndActive ; variable dndEntries ; variable dndSrcF
    if {!$dndActive} { set dndArmed 0 ; return }
    _dndLabelDestroy
    lassign [_dndResolveTarget [winfo containing $X $Y] $X $Y] tgtF tgtDir
    set mode [_dndMode $s $dndSrcF]
    set entries $dndEntries ; set srcF $dndSrcF
    set dndArmed 0 ; set dndActive 0
    if {$tgtF ne ""} { _dndDrop $srcF $entries $mode $tgtF $tgtDir }
    return -code break
}

# Resolve the widget under the drop point to a {targetTab targetDir} pair.
# Three drop zones are understood:
#   * a notebook tab strip  -> that tab (its current dir); this is how a drop
#     onto a background tab in the SAME window works
#   * a tab's folder tree   -> the specific folder node under the cursor
#   * anything else in a tab -> that tab's current directory
# targetDir "" means "use the target tab's current directory".
proc ::explorer::_dndResolveTarget {W X Y} {
    variable tab
    if {$W eq ""} { return [list "" ""] }

    # 1) notebook tab strip: drop onto a tab label -> that tab
    if {[winfo class $W] eq "TNotebook"} {
        set tx [expr {$X - [winfo rootx $W]}]
        set ty [expr {$Y - [winfo rooty $W]}]
        set idx ""
        catch {set idx [$W identify tab $tx $ty]}
        if {$idx ne ""} {
            set frame [lindex [$W tabs] $idx]
            if {$frame ne "" && [dict exists $tab $frame]} { return [list $frame ""] }
        }
        return [list "" ""]
    }

    set frm [_dndTargetTab $W]
    if {$frm eq ""} { return [list "" ""] }

    # 2) dropped over this tab's tree -> the folder node under the cursor.
    # tkufiletree uses the directory path itself as the treeview item id, so
    # "identify item" hands us the target directory directly.
    if {[string match "$frm.vtree.*" $W] || $W eq "$frm.vtree"} {
        set treeW [dict get $tab $frm tree]
        set tv [::tkutils::tkufiletree::treeview $treeW]
        set tx [expr {$X - [winfo rootx $tv]}]
        set ty [expr {$Y - [winfo rooty $tv]}]
        set item ""
        catch {set item [$tv identify item $tx $ty]}
        if {$item ne "" && $item ne [::tkutils::tkufiletree::volumesRoot]} {
            return [list $frm $item]
        }
    }
    # 3) list or elsewhere in the tab -> its current directory
    return [list $frm ""]
}

# Perform the transfer by reusing cufileops. targetDir "" means the target tab's
# current directory; a non-empty targetDir (from a tree node) copies into that
# specific folder. The user's clipboard is saved and restored around it.
proc ::explorer::_dndDrop {srcF entries mode tgtF {tgtDir ""}} {
    variable tab
    if {![dict exists $tab $srcF] || ![dict exists $tab $tgtF]} return
    if {![llength $entries]} return
    set srcProv [dict get $tab $srcF prov]
    set tgtProv [dict get $tab $tgtF prov]
    set effDir  [expr {$tgtDir eq "" ? [dict get $tab $tgtF cur] : $tgtDir}]
    # no-op: same tab (same provider) dropped onto its own current directory
    if {$srcProv eq $tgtProv && $effDir eq [dict get $tab $srcF cur]} return

    set saved $::ctrlutils::cufileops::clip
    if {$mode eq "move"} {
        ::ctrlutils::cufileops::cut  $srcF {*}$entries
    } else {
        ::ctrlutils::cufileops::copy $srcF {*}$entries
    }
    ::ctrlutils::cufileops::paste $tgtF $tgtDir
    set ::ctrlutils::cufileops::clip $saved
    if {$mode eq "move"} { catch {afterOps $srcF} }
    set verb [expr {$mode eq "move" ? "Moved" : "Copied"}]
    set n [llength $entries]
    set what [expr {$n == 1 ? [dict get [lindex $entries 0] name] : "$n items"}]
    catch { setStatus "$verb $what -> [_label $effDir]" [_win $tgtF] }
}

# copy unless Shift is held; downgrade a requested move to copy when the source
# provider cannot delete (so it is never a silent half-move).
proc ::explorer::_dndMode {s f} {
    variable tab
    set want [expr {($s & 1) ? "move" : "copy"}]
    if {$want eq "move"} {
        set prov [dict get $tab $f prov]
        if {"delete" ni [$prov caps]} { set want copy }
    }
    return $want
}

# Map a widget under the pointer to the tab frame it belongs to (any window).
proc ::explorer::_dndTargetTab {W} {
    if {$W eq ""} { return "" }
    variable tab
    foreach f [dict keys $tab] {
        if {$W eq $f || [string match "$f.*" $W]} { return $f }
    }
    return ""
}

# Perform the transfer by reusing cufileops. The user's clipboard is saved and
# restored around it, so a drag does not clobber a pending Copy/Cut.
proc ::explorer::_dndLabelCreate {} {
    set t .dndlabel
    catch {destroy $t}
    toplevel $t
    wm overrideredirect $t 1
    catch {wm attributes $t -topmost 1}
    pack [label $t.l -bd 1 -relief solid -padx 6 -pady 2 \
              -background "#ffffcc" -foreground black]
}

proc ::explorer::_dndLabelUpdate {mode X Y} {
    set t .dndlabel
    if {![winfo exists $t]} return
    variable dndEntries
    set glyph [expr {$mode eq "move" ? "->" : "+"}]
    set n [llength $dndEntries]
    set what [expr {$n == 1 ? [dict get [lindex $dndEntries 0] name] : "$n items"}]
    $t.l configure -text "$glyph $what"
    catch {wm geometry $t +[expr {$X + 14}]+[expr {$Y + 10}]}
}

proc ::explorer::_dndLabelDestroy {} { catch {destroy .dndlabel} }

proc ::explorer::onTabSelect {f} {
    variable tab
    if {![dict exists $tab $f]} return
    set w [_win $f]
    set prov [dict get $tab $f prov]
    set dir [dict get $tab $f cur]
    wm title $w "Explorer -- [namespace tail [info object class $prov]]"
    if {$dir ne ""} {
        setStatus "[llength [$prov list $dir]] entries in [file tail $dir]" $w
    }
}

# Keep at least one tab open.
proc ::explorer::_provInUse {prov {except ""}} {
    variable tab
    foreach t [dict keys $tab] {
        if {$t eq $except} continue
        if {![dict exists $tab $t prov]} continue
        if {[dict get $tab $t prov] eq $prov} { return 1 }
    }
    return 0
}

# Drop one tab's monitor, preview temps and provider. The provider is destroyed
# only when no other tab still holds the same object (two tabs can share one).
proc ::explorer::_releaseTab {f} {
    variable tab
    if {![dict exists $tab $f]} return
    catch {::ctrlutils::cumonitor::stop $f}
    if {[dict exists $tab $f tmpfile]} {
        catch {file delete [dict get $tab $f tmpfile]}
    }
    if {[dict exists $tab $f pdfimg]} {
        catch {::image delete [dict get $tab $f pdfimg]}
    }
    if {[dict exists $tab $f prov]} {
        set prov [dict get $tab $f prov]
        if {![_provInUse $prov $f]} {
            catch {$prov destroy}
            variable firstProv
            if {$firstProv eq $prov} { set firstProv "" }
        }
    }
    dict unset tab $f
}

proc ::explorer::onTabClose {f} {
    set w ""
    catch {set w [_win $f]}
    _releaseTab $f
    if {$w ne "" && [winfo exists $w] && [::tkutils::tkutab::count [_wp $w tabs]] <= 1} {
        after idle [list ::explorer::newTab $w]
    }
}

# Per-window status line. $w defaults to the main window; handlers that hold a
# tab frame pass [_win $f] so the message lands in the right window.
proc ::explorer::setStatus {msg {w .}} { set ::explorer::statustext($w) $msg }

# ---- main -----------------------------------------------------------------
# _errorDialog title message ?detail? -- show an error the user can read,
# select and copy: the message on top, the Tcl stack under "Details", and a
# Copy button (tkudialog). Up to ctrlutils 0.2 (first build) a startup error
# went to tk_messageBox with message AND stack in one label: long, cramped,
# not selectable (reported 2026-09-19). tk_messageBox remains only as the last
# resort when tkutils itself could not be loaded -- then with the short
# message only; the stack goes to stderr.
proc ::explorer::_errorDialog {title message {detail ""}} {
    set opts [list -title $title]
    if {$detail ne ""} { lappend opts -detail $detail }
    if {![catch {::tkutils::tkudialog::showError $message {*}$opts}]} { return }
    if {$detail ne ""} { catch {puts stderr $detail} }
    catch {tk_messageBox -icon error -title $title -message $message}
}

# Background errors (event bindings, after scripts) end up in the same dialog
# instead of Tk's default one. Installed by main, so the test suite, which
# loads this file without running main, keeps tcltest's own handling.
proc ::explorer::_bgerror {message opts} {
    set info ""
    if {[dict exists $opts -errorinfo]} { set info [dict get $opts -errorinfo] }
    _errorDialog "Explorer error" $message $info
}

proc ::explorer::main {argv} {
    interp bgerror {} ::explorer::_bgerror
    # -check / --check: show the capability report and exit with 0 only if every
    # optional backend loaded, so a build can be verified right after building.
    # On a console (Linux) it also prints; on Windows (GUI exe, no console) the
    # Tk window is the only thing visible, so we always show it.
    if {"-check" in $argv || "--check" in $argv} {
        set code [expr {[allCapabilitiesOk] ? 0 : 1}]
        set shown [_toConsole stdout [capabilityReport]]
        # Always show the window too -- on Windows the console output is invisible.
        _showCapabilityDialog [list apply {{c} { exit $c }} $code]
        return
    }
    set argv [lsearch -all -inline -not -regexp $argv {^--?(check|quiet)$}]
    openSource {*}$argv
    build
    # Surface missing backends where they can actually be seen: the status bar
    # (console output is invisible in a Windows GUI exe). Set after idle so it is
    # not overwritten by the initial directory-load status. Full report is under
    # Help > Optional backends.
    if {![allCapabilitiesOk]} {
        after idle {::explorer::setStatus \
            "Some optional previews unavailable -- Help > Optional backends"}
    }
    # Also print to a console if one exists (harmless, helps on Linux/CI).
    _toConsole stderr [string trimright [capabilityReport]]\n
}

if {[info exists argv0] && [file tail [info script]] eq [file tail $argv0]} {
    # Any startup failure must be visible, not a blank screen (Windows GUI exe
    # has no console). Show the error and the stack in a dialog.
    if {[catch {::explorer::main $argv} err opts]} {
        ::explorer::_errorDialog "Explorer error" $err [dict get $opts -errorinfo]
        exit 1
    }
}
