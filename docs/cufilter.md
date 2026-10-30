# ctrlutils::cufilter

A controller that provides a live filter box for a `tkufilelist`. As the user
types, the list shows only matching files; directories always stay, so
navigation still works while a filter is active.

## API

```tcl
package require ctrlutils::cufilter

::ctrlutils::cufilter::widget $path $listwidget   ;# build the filter box
::ctrlutils::cufilter::clear  $path               ;# empty it, show all
::ctrlutils::cufilter::lastError $path            ;# message of the last failure, or ""
```

- `widget $path $listwidget` -- create a filter entry at `$path`, wired to
  `$listwidget` (a `tkufilelist`). Returns `$path`.
- `clear $path` -- empty the box and return focus to the list.
- `lastError $path` -- the message of the last filter that could not be
  applied; empty after a successful one.

A filter that cannot be applied (the list is gone, or it is not a
`tkufilelist`) puts the entry into the ttk state `invalid`, sends
`<<CufilterError>>` to `$path` and keeps the message for `lastError`. There
is no dialog: the filter runs on every keystroke (0.2; up to 0.1 the error was
caught silently).

## Filtering

The typed text becomes a glob passed to `tkufilelist::setFilter`: bare text is
wrapped as `*text*` so it matches as a substring; text containing `*` or `?` is
used as a full glob. Matching is case-insensitive. Escape or the clear button
empties the box.

## Wiring

```tcl
::tkutils::tkufilelist::widget .list -dir [pwd]
::ctrlutils::cufilter::widget .filter .list
pack .filter -side top -fill x
pack .list   -side bottom -fill both -expand 1
```

Requires a `tkufilelist` with the `-filter` option / `setFilter` method.

## See also

`cufileops`, `cumonitor`, `cuundo`, `tkutils::tkufilelist`
