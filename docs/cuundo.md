# ctrlutils::cuundo

A controller that provides undo/redo for the file operations `cufileops`
performs. cufileops emits an operation record after each successful op (through
its `-onop` callback); cuundo records those on an undo stack and reverses them on
request, with a redo stack so a reversal can itself be redone. The two stay
decoupled -- cufileops does not know cuundo exists, it just reports what it did.

## API

```tcl
package require ctrlutils::cuundo

::ctrlutils::cuundo::install $f $prov ?-list widget? ?-refresh script?
::ctrlutils::cuundo::record  $f $recordDict     ;# the -onop target
::ctrlutils::cuundo::undo    $f
::ctrlutils::cuundo::redo    $f
::ctrlutils::cuundo::canUndo $f                 ;# / canRedo
::ctrlutils::cuundo::clear   $f
```

- `install $f $prov` -- set up undo/redo state for the view `$f`, reversing
  through `$prov`. `-list widget` binds Ctrl+Z / Ctrl+Y (and Ctrl+Shift+Z) on the
  list body. An unknown option is an error listing the known ones,
  `{CTRLUTILS CUUNDO OPTION <opt>}` (0.2; up to 0.1 a typo like `-lst` silently
  lost the key bindings). `-refresh script` runs after each undo and redo;
  without it cuundo calls `cufileops::refresh $f`, the refresh script given to
  cufileops for the same view. A failing refresh is an error
  `{CTRLUTILS CUUNDO REFRESH}`; the step itself is done (0.5; up to 0.4 cuundo
  called the private `cufileops::_refresh` inside `catch`).
- `record $f $rec` -- record an operation. Pass it to cufileops as
  `-onop [list ctrlutils::cuundo::record $f]`. New activity clears the redo stack.
- `undo` / `redo` -- reverse / re-apply the last operation.
- `canUndo` / `canRedo` -- whether a stack is non-empty (for enabling menu items).
- `clear` -- drop both stacks.

## What is reversed

Each operation is reversed through the provider:

| Operation | Undo |
|-----------|------|
| rename from->to | move to->from |
| mkdir path      | delete path |
| paste path      | delete path (the newly created target) |
| delete path     | restore from a snapshot taken *before* deleting |

For delete, cufileops captures the content before deleting (a file's bytes, or a
whole directory subtree), and cuundo restores it. Reversal of a delete is only
possible when the provider can read the content back; a snapshot is held in
memory, so this is best suited to ordinary file sizes.

## Wiring

```tcl
::ctrlutils::cuundo::install $f $prov -list $list
::ctrlutils::cufileops::install $f $prov $list $refresh \
    -onop [list ::ctrlutils::cuundo::record $f]
```

## See also

`cufileops`, `cumonitor`, `cufilter`, `tclutils::tuprovider`
