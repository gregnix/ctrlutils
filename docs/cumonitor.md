# ctrlutils::cumonitor

A controller that watches one directory through the provider interface and fires
a callback when its contents change. It **polls** rather than using an OS watch
(inotify), because polling is the only mechanism that works the same over a local
filesystem, a ZIP, or a remote provider.

## API

```tcl
package require ctrlutils::cumonitor

::ctrlutils::cumonitor::install $f $prov ?-interval ms? ?-onchange script?
::ctrlutils::cumonitor::watch   $f $dir
::ctrlutils::cumonitor::poke    $f
::ctrlutils::cumonitor::stop    $f
```

- `install` -- set up a monitor for the view `$f` over `$prov`. `-interval` is
  the poll period in ms (default 2000); `-onchange script` is appended the
  changed directory. An unknown option is an error listing the known ones,
  `{CTRLUTILS CUMONITOR OPTION <opt>}` (0.2; before, a plain error without
  errorcode).
- `watch $f $dir` -- watch `$dir` (re-baselines silently on each call, so
  navigating between directories does not look like a change).
- `poke $f` -- absorb the current state as the new baseline, without firing. Call
  it after the application's own edits so the monitor does not report them back.
- `stop $f` -- stop watching and drop the state (idempotent).

## How it detects change

Each poll reads the directory via the provider's `list` and diffs a signature of
the entries (name, type, size, mtime). The first snapshot of a directory is the
baseline and does not fire; only a real difference from it fires. Because it goes
through the provider, it is storage-agnostic -- the same watcher works over any
backend.

## Typical wiring

```tcl
::ctrlutils::cumonitor::install $f $prov -interval 2000 \
    -onchange {apply {d {reloadList $d}}}
::ctrlutils::cumonitor::watch $f $currentDir
# after the app changes files itself:
::ctrlutils::cumonitor::poke $f
```

## See also

`cufileops`, `cufilter`, `cuundo`, `tclutils::tuprovider`
