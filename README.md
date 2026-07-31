# ctrlutils -- the controller layer

ctrlutils is the third repo alongside `tclutils` and `tkutils`. It holds
**controllers**: modules that wire events on existing widgets to operations on a
provider, but are neither widgets nor pure logic.

    tclutils   (tu*)   logic, no Tk           == Model
    tkutils    (tku*)  widgets                == View
    ctrlutils  (cu*)   controllers / glue     == Controller

A `tkutils` module *is* a widget: `tkufiletree $path ...`. A `ctrlutils` module
*wires behavior onto* widgets: `cufileops::install $f $prov $list $refresh`. It
has no widget path of its own; it installs behavior on widgets that already
exist. Every controller depends only on the provider interface (any tclutils
provider) and on tkutils widgets -- never on a specific application -- so any
app built on the provider abstraction can reuse them.

Load the whole layer with `package require ctrlutils`, or a single controller
with e.g. `package require ctrlutils::cufilter`.

## Documentation

Each module has a reference page under `docs/<module>.md` and a man page under
`man/mann/<module>.n`:
[cufileops](docs/cufileops.md), [cumonitor](docs/cumonitor.md),
[cufilter](docs/cufilter.md), [cuundo](docs/cuundo.md),
[cusync](docs/cusync.md). Tests live in
`tests/<module>.test` (run via `tests/all.tcl`).

## cufileops -- file operations

A capability-driven context menu and keyboard shortcuts on a file list: New
Folder, Rename, Delete, Copy, Paste. Each entry appears only when the provider
supports the underlying operation (`mkdir` / `move` / `delete` / `get`+`put`), so
a read-only provider (a ZIP) offers none of the writing ones -- the UI never
offers something that would fail.

    ctrlutils::cufileops::install $f $prov $listwidget $refreshcmd

- `$f` -- an identity token for this view (e.g. a tab frame)
- `$prov` -- the provider
- `$listwidget` -- the tkufilelist path
- `$refreshcmd` -- a script run after a successful change (re-reads the dir)

Copy/Paste runs via `get`+`put` at the controller level, not the provider's
internal `copy`, so it is **cross-provider**: a file (or a whole directory, via
recursion) can be pulled out of a ZIP into a local directory. The clipboard
remembers the source provider, so paste into a different provider works. Paste
never overwrites silently -- on a name collision it picks `name (copy).ext`.

## cumonitor -- directory watcher

Watches one directory through the provider interface and fires a callback when
its contents change. It **polls** `list` on an interval and diffs a signature of
the entries, rather than using an OS watch (inotify): polling is the only
mechanism that works the same over a local filesystem, a ZIP, or a remote
provider.

    ctrlutils::cumonitor::install $f $prov ?-interval ms? ?-onchange script?
    ctrlutils::cumonitor::watch   $f $dir
    ctrlutils::cumonitor::poke    $f
    ctrlutils::cumonitor::stop    $f

The first snapshot of a directory is the baseline (does not fire); only a real
change from it fires. `watch` re-baselines silently, so navigating does not look
like a change. Call `poke` after the app's own edits so the monitor does not
report them back.

## cufilter -- live filter box

Wires a text entry to a file list's name filter: as the user types, the list
shows only matching files (directories always stay, so navigation still works).

    ctrlutils::cufilter::widget $path $listwidget
    ctrlutils::cufilter::clear  $path

Bare text becomes a substring match (`*text*`); text containing `*` or `?` is
used as a glob. Escape or the clear button empties the box. Requires a
`tkufilelist` with the `-filter` option / `setFilter` method.


## cuundo -- undo/redo

Records the file operations cufileops performs and reverses them on request,
with a redo stack for reversing the reversal.

    set u [ctrlutils::cuundo::install $f $prov -list $listwidget]
    ctrlutils::cufileops::install $f $prov $listwidget $refresh \
        -onop [list ctrlutils::cuundo::record $f]
    ctrlutils::cuundo::undo $f     ;# also Ctrl+Z on the list
    ctrlutils::cuundo::redo $f     ;# also Ctrl+Y / Ctrl+Shift+Z

cufileops emits an operation record after each successful op through its `-onop`
callback; cuundo consumes those records, so the two stay decoupled -- cufileops
does not know cuundo exists. Each op is reversed through the provider: a rename
is renamed back, a mkdir/paste is deleted, and a delete is restored from a
snapshot cufileops captured *before* deleting (the file's bytes, or a whole
directory subtree). Reversal is only offered when the provider can read the
content back.

## cusync -- directory compare and mirror

Compares two directory trees, each on its own provider, and mirrors one onto the
other. **One-way** and **non-destructive** by default: it copies what is missing
and updates what is newer or differing, but never deletes on the target. No Tk --
the Explorer supplies the dialog and progress bar.

    set diffs [ctrlutils::cusync::compare $provL $dirL $provR $dirR]
    set plan  [ctrlutils::cusync::plan $diffs LR]
    set res   [ctrlutils::cusync::apply $provL $dirL $provR $dirR $plan]

The flow is compare -> plan -> apply. `compare` classifies every entry
(onlyLeft / onlyRight / newerLeft / newerRight / diff / same / conflict). `plan`
turns that into a copy list for one direction (`LR` or `RL`), copying only
missing and newer/differing entries and never the target-only side -- that is
what keeps it non-destructive. `apply` executes the plan through the providers
(`applyOne` runs a single action, so a UI can step through via `after` with a
progress bar and Cancel). Because it works entirely through the provider
interface, it mirrors across providers -- local, ZIP, WebDAV, SFTP.
