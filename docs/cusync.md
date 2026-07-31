# ctrlutils::cusync

A controller that compares two directory trees and mirrors one onto the other.
Each tree lives on its own `tuprovider`, so `local <-> ZIP <-> SFTP <-> WebDAV`
combinations all work. Sync is **one-way** and **non-destructive** by default:
it copies missing entries and updates newer/differing ones, but it never deletes
on the target. There is no Tk here -- the Explorer supplies the dialog and the
progress bar; cusync is pure model/controller logic.

## API

```tcl
package require ctrlutils::cusync

::ctrlutils::cusync::compare  $provL $dirL $provR $dirR        ;# -> list of diff dicts
::ctrlutils::cusync::plan     $diffs $direction               ;# -> list of action dicts
::ctrlutils::cusync::apply    $srcProv $srcDir $dstProv $dstDir $actions \
                              ?-ondir cb? ?-onfile cb?         ;# -> {done N errors {..}}
::ctrlutils::cusync::applyOne $srcProv $srcDir $dstProv $dstDir $action ;# -> {ok 0|1 ?error msg?}
```

The flow is always **compare -> plan -> apply**: compare tells you how the two
sides differ, plan turns that into a copy list for one direction, apply (or
`applyOne` in a loop) executes it.

## compare

`compare $provL $dirL $provR $dirR` walks both trees and returns a flat list of
diff dicts, parents before children. Each diff dict has:

| Key | Meaning |
|-----|---------|
| `rel`    | path relative to the two roots, `/`-separated, no leading slash |
| `name`   | leaf name |
| `status` | see below |
| `ltype`  | `file`, `dir`, or `""` if absent on the left |
| `rtype`  | `file`, `dir`, or `""` if absent on the right |

`status` is one of:

| Status | Meaning |
|--------|---------|
| `onlyLeft`   | present only on the left |
| `onlyRight`  | present only on the right |
| `newerLeft`  | on both, left mtime is newer |
| `newerRight` | on both, right mtime is newer |
| `diff`       | on both, same mtime but different size |
| `same`       | on both, same mtime and size |
| `conflict`   | one side is a file, the other a directory |

Left-only directories are recursed into, so every file underneath gets its own
diff entry (and can be mirrored).

## plan

`plan $diffs $direction` turns diffs into a list of action dicts for one
direction. `direction` is `LR` (left is the source) or `RL` (right is the
source). Each action dict is `{op copy rel <path> type file|dir}`.

A plan copies, in the chosen direction, the entries that are **missing** on the
target plus the ones that are **newer or differing** on the source. It never
emits a delete and never pulls the target-only side across -- an `LR` plan
ignores `onlyRight`, an `RL` plan ignores `onlyLeft`. That is what makes sync
non-destructive: run it and the target only ever gains or refreshes files.

## apply / applyOne

`apply $srcProv $srcDir $dstProv $dstDir $actions` executes a plan: directories
are created, files are read from the source and written to the target (parent
directories are created as needed). It returns `{done N errors {msg ...}}` --
`done` counts successful actions, `errors` collects per-action messages so a
partial failure does not abort the whole run.

Optional `-ondir` / `-onfile` callbacks receive the `rel` path before each
action, for progress reporting. They are invoked at global scope; errors in a
callback are ignored.

`applyOne $srcProv $srcDir $dstProv $dstDir $action` runs a single action and
returns `{ok 1}` or `{ok 0 error <msg>}`. It is factored out so a UI can step
through a plan one action at a time (via `after`), keeping the event loop live
for a progress bar and a Cancel button instead of freezing. `apply` is just a
loop over `applyOne`.

For local-to-local copies the source mtime is preserved on a best-effort basis
so repeated mirrors are idempotent; this is silently skipped for zip/dav/sftp
targets.

## Example

```tcl
package require ctrlutils::cusync

set L [tclutils::tuprovider open local]
set R [tclutils::tuprovider open local]

set diffs [::ctrlutils::cusync::compare $L /home/me/src $R /backup/src]
set plan  [::ctrlutils::cusync::plan $diffs LR]
set res   [::ctrlutils::cusync::apply $L /home/me/src $R /backup/src $plan \
              -onfile [list puts]]
puts "copied [dict get $res done], errors: [dict get $res errors]"
```

## See also

`cufileops`, `cuundo`, `tclutils::tuprovider`
