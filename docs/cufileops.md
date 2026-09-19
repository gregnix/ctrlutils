# ctrlutils::cufileops

A controller that adds capability-driven file operations -- New Folder, Rename,
Delete, Copy, Cut, Paste -- to a `tkufilelist`, via a right-click context menu and
keyboard shortcuts. It is not a widget: it wires behavior onto a list that
already exists, and acts through a `tuprovider`, so what it offers depends on
what the provider can do.

## Install

```tcl
package require ctrlutils::cufileops

::ctrlutils::cufileops::install $f $prov $listwidget $refreshcmd ?-onop script?
```

- `$f` -- an identity token for this view (e.g. a tab frame path); all state is
  keyed by it, so several views can each have their own.
- `$prov` -- the storage provider.
- `$listwidget` -- the `tkufilelist` path.
- `$refreshcmd` -- a script run after any successful change (to re-read the
  directory into the list).
- `-onop script` -- optional; called with an operation-record dict after each
  successful operation, so an observer such as `cuundo` can record it for undo.

An unknown option is an error that lists the known ones,
`{CTRLUTILS CUFILEOPS OPTION <opt>}` (0.2; up to 0.1 a typo such as `-onpo`
was swallowed and silently disabled undo).

## Operations

The context menu and shortcuts route to these (also callable directly):

```tcl
::ctrlutils::cufileops::newFolder $f
::ctrlutils::cufileops::openFile  $f $entry   ;# open with the OS default app
::ctrlutils::cufileops::openWith  $f $entry   ;# open with a program the user names
::ctrlutils::cufileops::openWithDefault $f $entry  ;# open with the default app registered for the extension, no dialog
::ctrlutils::cufileops::rename    $f $entry
::ctrlutils::cufileops::delete    $f ?$entry ...?
::ctrlutils::cufileops::copy      $f ?$entry ...?   ;# one or more entries (multi-select)
::ctrlutils::cufileops::cut       $f ?$entry ...?
::ctrlutils::cufileops::paste     $f
```

For a file the provider can read, the menu also offers **Open** (launch the OS
default application via `tclutils::tuopen`, falling back to xdg-open/open/start)
and **Open with...** (prompt for a program and run it with the file). A local
file opens in place; a provider-backed file (in a ZIP, on WebDAV/FTP) is first
written to a temp file that keeps the original extension, so the opener picks the
right application.

Shortcuts on the list: Delete, F2 (rename), Ctrl+C (copy), Ctrl+X (cut), Ctrl+V (paste).

## Dialogs belong to the view's window (0.2)

Every prompt, confirmation and error dialog (New Folder, Rename, Delete, paste
and open failures) is opened with `-parent` set to the toplevel of the view's
list, so it is transient to that window and centred over it. Up to 0.1 no
dialog got a parent and `tkudialog` 0.1 put each one in the middle of the
screen — with the Explorer on a second monitor, on the other one. Measured
2026-09-19: Explorer window at 860,560, the New Folder prompt centred over it.
Needs `tkutils::tkudialog` 0.2.

## Capability-driven

Each menu entry appears only when the provider supports the underlying operation
(`mkdir` / `move` / `delete` / `get`+`put`). A read-only provider (a ZIP) offers
none of the writing ones, so the UI never presents an action that would fail.

## Open with: per-type app registry

"Open with..." remembers applications per file extension instead of asking for a
command every time. The registry is stored as a plain Tcl dict in the platform's
config directory (via `tuopen configFile`): XDG on Linux, AppData on Windows,
Application Support on macOS.

Each extension maps to a list of launcher commands and one optional default:

```
.txt {apps {gedit {code -w}} default {code -w}}
.pdf {apps {evince okular}   default evince}
```

Even before anything is registered the dialog is not empty: it lists **detected
applications** installed on the system that suit the file's type (editors for
text, image viewers for images, PDF viewers for `.pdf`, browsers for HTML, ...),
found via `auto_execok`. Tcl source files (`.tcl`, `.tm`, `.test`, ...) suggest
a Tcl editor (alited) first, then the general editors. These appear marked "(suggested)"; picking one opens the
file and promotes it to a permanent entry for that type. There is also a
"Browse..." button to choose any executable from disk.

A command may include its own arguments (e.g. `code -w`); the file path is
appended when launching. The "Open with..." dialog lists the apps for the
selected file's type, marks the default, and lets you Open, Add, Remove, or Set
as default. When a default is set for a type, the right-click menu shows an
"Open with <app>" entry that opens it in one click. That entry calls
`openWithDefault`, which launches the registered default for the file's
extension directly. If no default is registered it does nothing (the menu
only offers the entry when there is one). Double-click still uses the
OS default opener (this registry is a menu-only convenience).

Registry API (pure, no Tk needed once loaded):

```tcl
::ctrlutils::cufileops::owApps       $ext          ;# list of commands
::ctrlutils::cufileops::owDefault    $ext          ;# default command or ""
::ctrlutils::cufileops::owAddApp     $ext $cmd
::ctrlutils::cufileops::owRemoveApp  $ext $cmd
::ctrlutils::cufileops::owSetDefault $ext $cmd
```

`$ext` is a lowercase extension with the dot (".txt"); a file with no extension
uses the empty key. Set `::ctrlutils::cufileops::owApp` to change the config
sub-directory name, or `owFile` to point at an explicit file (tests do this).

## Cross-provider move (cut)

Cut marks a file or folder for **move**: the next paste writes it at the
destination (the same `get`+`put`, recursive for folders) and then removes the
source. Because it deletes the source, cut is only offered when the source
provider supports `delete` -- you cannot cut out of a read-only ZIP (copy still
works). The move is emitted as a single `movex` operation record carrying both
providers and a snapshot of the source, so undo restores the source and removes
the target, and redo re-applies the move. A cut is consumed by its paste.

## Cross-provider copy

Copy/Paste runs `get`+`put` at the controller level, not the provider's internal
`copy`, so it works **across** providers: a file (or a whole directory, copied
recursively) can be pulled out of a ZIP into a local directory. The clipboard
remembers the *source* provider, so pasting into a view backed by a different
provider triggers the cross-provider path. On a name collision, paste picks a
free `name (copy).ext` rather than overwriting.

## See also

`cumonitor`, `cufilter`, `cuundo`, `tclutils::tuprovider`, `tkutils::tkufilelist`
