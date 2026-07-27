#!/usr/bin/env wish
# explorer.tcl -- the reference application for the provider framework.
#
# Deliberately thin: it wires together tkufiletree (tree), tkufilelist (list),
# tkupath (breadcrumb) and tkutab (tabs) over a shared tuprovider. The
# framework does the work; this file connects the parts and holds the session.
#
# Multiple directories open at once, one per tab. Each tab has its own tree,
# list, breadcrumb and current directory; all tabs share one provider (one
# storage session). The same app works over local files or a ZIP archive --
# nothing here knows the difference.
#
#   wish explorer.tcl ?directory?
#   wish explorer.tcl -zip archive.zip

package require Tk 8.6-
package require tkutils::tkufiletree
package require tkutils::tkufilelist
package require tkutils::tkupath
package require tkutils::tkutab
package require tclutils::tuprovider
package require tkutils::tkupreview
package require ctrlutils::cufileops
package require ctrlutils::cumonitor
package require ctrlutils::cufilter
package require ctrlutils::cuundo

# Optional: the Img extension adds photo formats Tk lacks natively (JPEG, TIFF,
# BMP, ...). If present, `image create photo -file` decodes them, so the image
# preview covers those extensions too. Absent, only PNG/GIF/PPM/PGM work and
# the extra extensions fall through to the hex fallback -- no hard dependency.
# Each format package is loaded on its own: the umbrella "Img" pulls in every
# format at once, so one missing native lib (e.g. libjpeg for jpeg) would take
# them all down. Loading per-format keeps the formats whose libs are present.
namespace eval ::explorer { variable imgFormats {} }
foreach _fmt {jpeg tiff bmp ico} {
    if {![catch {package require img::$_fmt}]} {
        lappend ::explorer::imgFormats $_fmt
    }
}
unset -nocomplain _fmt

# Optional: tcllunasvg renders SVG to a PNG we then show as an image. Absent,
# .svg files fall back to their text source (they are XML, after all).
namespace eval ::explorer { variable haveSvg 0 }
if {![catch {package require tcllunasvg}]} {
    set ::explorer::haveSvg 1
}

namespace eval ::explorer {
    variable start "/"      ;# directory the first tab opens
    variable tab            ;# per-tab state, keyed by content-frame path
    variable statustext ""
    variable firstProv ""   ;# provider for the very first tab
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
    set dir [expr {[llength $args] ? [lindex $args 0] : [pwd]}]
    set prov [::tclutils::tuprovider open local]
    return [list $prov [file normalize $dir]]
}

# Kept for the initial launch: remember the first tab's source.
proc ::explorer::openSource {args} {
    variable firstProv ; variable start
    lassign [makeSource {*}$args] firstProv start
}

# The tree root for a given provider: OS root for local, "/" for ZIP/DAV.
proc ::explorer::_treeRoot {prov} {
    if {[namespace tail [info object class $prov]] eq "Local"} {
        return [expr {$::tcl_platform(platform) eq "windows" ? "C:/" : "/"}]
    }
    return "/"
}

# ---- top-level UI ---------------------------------------------------------
proc ::explorer::build {} {
    variable start ; variable firstProv
    wm title . "Explorer"
    wm geometry . 860x560

    _buildMenu

    ttk::label .status -textvariable ::explorer::statustext -anchor w \
        -padding {6 3} -relief sunken
    pack .status -side bottom -fill x

    ::tkutils::tkutab::widget .tabs \
        -onnew    {::explorer::newTab} \
        -onclose  {::explorer::onTabClose} \
        -onselect {::explorer::onTabSelect}
    pack .tabs -side top -fill both -expand 1

    newTabWith $firstProv $start
}

# A menu bar makes the operations discoverable -- especially undo/redo, which
# are otherwise keyboard-only. Each command acts on the CURRENT tab, fetching
# its selection from the tab's list, so the same cufileops/cuundo operations the
# context menu and shortcuts use are reachable from here too.
proc ::explorer::_buildMenu {} {
    . configure -menu [menu .m -tearoff 0]

    menu .m.file -tearoff 0
    .m add cascade -label "File" -menu .m.file
    .m.file add command -label "New Tab"     -accelerator "Ctrl+T" \
        -command {::explorer::newTab}
    .m.file add command -label "Open ZIP..." -command {::explorer::openZipTab}
    .m.file add separator
    .m.file add command -label "Close Tab"   -accelerator "Ctrl+W" \
        -command {::explorer::_menuCloseTab}
    .m.file add separator
    .m.file add command -label "Quit"        -accelerator "Ctrl+Q" -command {exit}

    menu .m.edit -tearoff 0
    .m add cascade -label "Edit" -menu .m.edit
    .m.edit add command -label "Undo" -accelerator "Ctrl+Z" \
        -command {::explorer::_menuUndo}
    .m.edit add command -label "Redo" -accelerator "Ctrl+Y" \
        -command {::explorer::_menuRedo}
    .m.edit add separator
    .m.edit add command -label "New Folder" -command {::explorer::_menuOp newFolder}
    .m.edit add command -label "Rename"     -command {::explorer::_menuOp rename}
    .m.edit add command -label "Delete"     -command {::explorer::_menuOp delete}
    .m.edit add separator
    .m.edit add command -label "Copy"  -accelerator "Ctrl+C" -command {::explorer::_menuOp copy}
    .m.edit add command -label "Paste" -accelerator "Ctrl+V" -command {::explorer::_menuOp paste}
    # keep Undo/Redo enabled state fresh when the Edit menu opens
    bind .m.edit <<MenuSelect>> {::explorer::_syncEditMenu}

    menu .m.view -tearoff 0
    .m add cascade -label "View" -menu .m.view
    .m.view add command -label "Refresh" -accelerator "F5" \
        -command {::explorer::_menuOp refresh}

    # global accelerators (the list-local ones from the controllers still work)
    bind . <Control-t> {::explorer::newTab ; break}
    bind . <Control-w> {::explorer::_menuCloseTab ; break}
    bind . <Control-q> {exit}
}

# ---- menu handlers: act on the current tab --------------------------------
proc ::explorer::_curTab {} {
    if {[catch {::tkutils::tkutab::current .tabs} f]} { return "" }
    variable tab
    if {![dict exists $tab $f]} { return "" }
    return $f
}

proc ::explorer::_menuUndo {} {
    set f [_curTab] ; if {$f eq ""} return
    ::ctrlutils::cuundo::undo $f
}
proc ::explorer::_menuRedo {} {
    set f [_curTab] ; if {$f eq ""} return
    ::ctrlutils::cuundo::redo $f
}

proc ::explorer::_syncEditMenu {} {
    set f [_curTab]
    set canU [expr {$f ne "" && [::ctrlutils::cuundo::canUndo $f]}]
    set canR [expr {$f ne "" && [::ctrlutils::cuundo::canRedo $f]}]
    .m.edit entryconfigure "Undo" -state [expr {$canU ? "normal" : "disabled"}]
    .m.edit entryconfigure "Redo" -state [expr {$canR ? "normal" : "disabled"}]
}

proc ::explorer::_menuCloseTab {} {
    set f [_curTab] ; if {$f eq ""} return
    ::tkutils::tkutab::close .tabs $f
}

# Route a menu operation to cufileops on the current tab, using its selection.
proc ::explorer::_menuOp {op} {
    variable tab
    set f [_curTab] ; if {$f eq ""} return
    set lst [dict get $tab $f list]
    switch -- $op {
        newFolder { ::ctrlutils::cufileops::newFolder $f }
        paste     { ::ctrlutils::cufileops::paste $f }
        refresh   { ::explorer::afterOps $f }
        rename - delete - copy {
            set e [::tkutils::tkufilelist::selectedEntry $lst]
            if {$e eq ""} { setStatus "Select a file first." ; return }
            ::ctrlutils::cufileops::$op $f $e
        }
    }
}

# ---- a tab is one browse view ---------------------------------------------
# The "+" button calls this with no args: open a fresh LOCAL view at home, so a
# new tab is independent of whatever the current tab shows (which may be a ZIP).
proc ::explorer::newTab {{dir ""}} {
    lassign [makeSource [expr {$dir eq "" ? [_homeDir] : $dir}]] prov start
    newTabWith $prov $start
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
proc ::explorer::newTabWith {prov dir} {
    variable tab

    set f [::tkutils::tkutab::add .tabs [_label $dir]]

    ttk::frame $f.top
    ttk::button $f.top.zip -text "Open ZIP..." -width 11 \
        -command ::explorer::openZipTab
    pack $f.top.zip -side right -padx 4 -pady 2
    ::tkutils::tkupath::widget $f.top.path -rootlabel "/" \
        -onnavigate [list ::explorer::onPathNavigate $f]
    pack $f.top.path -side left -fill x -expand 1 -padx 4 -pady 2
    pack $f.top -side top -fill x

    ttk::panedwindow $f.pw -orient horizontal
    pack $f.pw -side top -fill both -expand 1
    # width hints plus weights bias the initial split toward the preview, which
    # needs room for HTML/PDF/images; sash positions are set once below.
    set tf [ttk::frame $f.pw.tree -width 200]
    set lf [ttk::frame $f.pw.list -width 280]
    set pf [ttk::frame $f.pw.prev -width 560]
    $f.pw add $tf -weight 1
    $f.pw add $lf -weight 2
    $f.pw add $pf -weight 5

    ::tkutils::tkufiletree::widget $tf.t -root [_treeRoot $prov] -provider $prov \
        -files 0 -onselect [list ::explorer::onTreeSelect $f]
    pack $tf.t -fill both -expand 1

    ::tkutils::tkufilelist::widget $lf.l -provider $prov -dir $dir \
        -onactivate [list ::explorer::onListActivate $f] \
        -onselect [list ::explorer::onListSelect $f]
    # a live filter box above the list (a ctrlutils controller)
    ::ctrlutils::cufilter::widget $lf.filter $lf.l
    pack $lf.filter -side top -fill x -pady {0 2}
    pack $lf.l -side bottom -fill both -expand 1

    ::tkutils::tkupreview::widget $pf.v
    pack $pf.v -fill both -expand 1

    dict set tab $f prov $prov
    dict set tab $f tree $tf.t
    dict set tab $f list $lf.l
    dict set tab $f path $f.top.path
    dict set tab $f prev $pf.v
    dict set tab $f cur  ""

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

    goto $f $dir
}

# Run after cufileops makes a change: refresh the list, then re-baseline the
# monitor so our own edit is not re-reported as an external change.
proc ::explorer::afterOps {f} {
    variable tab
    ::tkutils::tkufilelist::refresh [dict get $tab $f list]
    catch {::ctrlutils::cumonitor::poke $f}
}

# The monitor saw the current directory change externally: reload the list.
proc ::explorer::onDirChanged {f dir} {
    variable tab
    if {![dict exists $tab $f]} return
    catch {::tkutils::tkufilelist::refresh [dict get $tab $f list]}
    setStatus "reloaded [file tail $dir] (changed on disk)"
}

# Central navigation for a tab. The loop from reveal's async selection is
# broken on value: navigating to the already-current dir is a no-op.
proc ::explorer::goto {f dir} {
    variable tab
    set prov [dict get $tab $f prov]
    set dir [file normalize $dir]
    if {$dir eq [dict get $tab $f cur]} return
    dict set tab $f cur $dir
    catch {::ctrlutils::cufilter::clear $f.pw.list.filter}
    ::tkutils::tkufilelist::setDir [dict get $tab $f list] $dir
    catch {::tkutils::tkupath::setPath [dict get $tab $f path] $dir}
    catch {::tkutils::tkufiletree::reveal [dict get $tab $f tree] $dir}
    ::tkutils::tkutab::setLabel .tabs $f [_label $dir]
    catch {::ctrlutils::cumonitor::watch $f $dir}
    setStatus "[llength [$prov list $dir]] entries in [file tail $dir]"
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
        setStatus "File: [dict get $entry name] ([dict get $entry size] bytes)"
    }
}

# Selecting a file previews it. The type->preview-kind policy lives here, in
# the app; the tkupreview widget only displays what it is handed.
proc ::explorer::onListSelect {f entry} {
    variable tab
    if {![dict exists $tab $f]} return
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
        if {[catch {$prov get $path} data]} {
            ::tkutils::tkupreview::message $pv "Cannot read: $data" ; return
        }
        # Providers return raw bytes; text viewers need a decoded string, or
        # UTF-8 umlauts show up as mojibake. Strip a UTF-8 BOM if present.
        set text [encoding convertfrom utf-8 $data]
        if {[string index $text 0] eq "\uFEFF"} {
            set text [string range $text 1 end]
        }
        ::tkutils::tkupreview::[dict get $textKinds $ext] $pv $title $text
        return
    }
    # TSV is a table too, but tab-separated -- tell the csv viewer the delimiter
    # so a .tsv is not parsed as a single comma-less column.
    if {$ext eq ".tsv"} {
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
    # image extensions: PNG/GIF/PPM/PGM are native to Tk; the rest need the
    # matching Img format package to have loaded (see imgFormats at startup).
    set nativeImg {.png .gif .ppm .pgm}
    set imgExts $nativeImg
    if {"jpeg" in $::explorer::imgFormats} { lappend imgExts .jpg .jpeg }
    if {"tiff" in $::explorer::imgFormats} { lappend imgExts .tif .tiff }
    if {"bmp"  in $::explorer::imgFormats} { lappend imgExts .bmp }
    if {"ico"  in $::explorer::imgFormats} { lappend imgExts .ico }
    if {$ext in $imgExts} {
        set tmp [_toTemp $f $prov $path $ext]
        if {$tmp eq ""} {
            ::tkutils::tkupreview::message $pv "Cannot read image." ; return
        }
        ::tkutils::tkupreview::image $pv $title $tmp
        return
    }
    switch -- $ext {
        .pdf {
            set tmp [_toTemp $f $prov $path $ext]
            if {$tmp eq ""} {
                ::tkutils::tkupreview::message $pv "Cannot read PDF." ; return
            }
            _previewPdf $f $pv $title $tmp
        }
        .db - .sqlite - .sqlite3 {
            set tmp [_toTemp $f $prov $path $ext]
            if {$tmp eq ""} {
                ::tkutils::tkupreview::message $pv "Cannot read database." ; return
            }
            ::tkutils::tkupreview::sqlite $pv $title $tmp
        }
        default {
            # unknown type: show a hex dump so binaries are still inspectable
            if {[catch {$prov get $path} data]} {
                ::tkutils::tkupreview::message $pv "No preview for '$ext' files."
                return
            }
            ::tkutils::tkupreview::hex $pv $title $data
        }
    }
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

# Render the first PDF page to an image via tclpdfium (::pdfium::render, which
# produces a Tk photo) and show it. If tclpdfium is not available, fall back to
# the structure inspector so the file is still previewable.
proc ::explorer::_previewPdf {f pv title file} {
    variable tab
    if {![catch {package require pdfiumtcl}] || \
        [llength [info commands ::pdfium::render]]} {
        if {![_renderPdfPage $f $pv $title $file]} {
            ::tkutils::tkupreview::pdf $pv $title $file
        }
    } else {
        ::tkutils::tkupreview::pdf $pv $title $file
    }
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

# Open a ZIP archive in a NEW tab. This is what makes cross-provider copy
# usable interactively: a ZIP tab and a local tab coexist, each with its own
# provider, and cufileops copies between them (get from ZIP, put to local).
proc ::explorer::openZipTab {} {
    set file [tk_getOpenFile -title "Open ZIP archive" \
        -filetypes {{{ZIP archives} {.zip}} {{All files} *}}]
    if {$file eq ""} return
    if {[catch {makeSource -zip $file} res]} {
        ::tkutils::tkudialog::showError "Cannot open ZIP:\n$res"
        return
    }
    lassign $res prov start
    newTabWith $prov $start
}

proc ::explorer::onTabSelect {f} {
    variable tab
    if {![dict exists $tab $f]} return
    set prov [dict get $tab $f prov]
    set dir [dict get $tab $f cur]
    wm title . "Explorer -- [namespace tail [info object class $prov]]"
    if {$dir ne ""} {
        setStatus "[llength [$prov list $dir]] entries in [file tail $dir]"
    }
}

# Keep at least one tab open.
proc ::explorer::onTabClose {f} {
    variable tab
    catch {::ctrlutils::cumonitor::stop $f}
    # clean up this tab's preview temp file and rendered PDF page, if any
    if {[dict exists $tab $f tmpfile]} {
        catch {file delete [dict get $tab $f tmpfile]}
    }
    if {[dict exists $tab $f pdfimg]} {
        catch {::image delete [dict get $tab $f pdfimg]}
    }
    if {[::tkutils::tkutab::count .tabs] <= 1} {
        after idle [list ::explorer::newTab]
    }
    dict unset tab $f
}

proc ::explorer::setStatus {msg} { set ::explorer::statustext $msg }

# ---- main -----------------------------------------------------------------
proc ::explorer::main {argv} {
    openSource {*}$argv
    build
}

if {[info exists argv0] && [file tail [info script]] eq [file tail $argv0]} {
    ::explorer::main $argv
}
