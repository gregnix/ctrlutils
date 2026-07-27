# ctrlutils::cufileops

A controller that adds capability-driven file operations -- New Folder, Rename,
Delete, Copy, Paste -- to a `tkufilelist`, via a right-click context menu and
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

## Operations

The context menu and shortcuts route to these (also callable directly):

```tcl
::ctrlutils::cufileops::newFolder $f
::ctrlutils::cufileops::openFile  $f $entry   ;# open with the OS default app
::ctrlutils::cufileops::openWith  $f $entry   ;# open with a program the user names
::ctrlutils::cufileops::rename    $f $entry
::ctrlutils::cufileops::delete    $f $entry
::ctrlutils::cufileops::copy      $f $entry
::ctrlutils::cufileops::paste     $f
```

For a file the provider can read, the menu also offers **Open** (launch the OS
default application via `tclutils::tuopen`, falling back to xdg-open/open/start)
and **Open with...** (prompt for a program and run it with the file). A local
file opens in place; a provider-backed file (in a ZIP, on WebDAV/FTP) is first
written to a temp file that keeps the original extension, so the opener picks the
right application.

Shortcuts on the list: Delete, F2 (rename), Ctrl+C (copy), Ctrl+V (paste).

## Capability-driven

Each menu entry appears only when the provider supports the underlying operation
(`mkdir` / `move` / `delete` / `get`+`put`). A read-only provider (a ZIP) offers
none of the writing ones, so the UI never presents an action that would fail.

## Cross-provider copy

Copy/Paste runs `get`+`put` at the controller level, not the provider's internal
`copy`, so it works **across** providers: a file (or a whole directory, copied
recursively) can be pulled out of a ZIP into a local directory. The clipboard
remembers the *source* provider, so pasting into a view backed by a different
provider triggers the cross-provider path. On a name collision, paste picks a
free `name (copy).ext` rather than overwriting.

## See also

`cumonitor`, `cufilter`, `cuundo`, `tclutils::tuprovider`, `tkutils::tkufilelist`
