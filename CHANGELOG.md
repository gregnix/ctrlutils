# Changelog

## 0.5 - Unreleased

Recommended pairing: tclutils 0.69.0 + tkutils 0.49.0 + ctrlutils 0.5.

Module versions: `cusync` 0.3, `cufileops` 0.6, `cuundo` 0.5, `cufilter` 0.2.
When copying over an older tree, delete `ctrlutils-0.4.tm`, `cusync-0.2.tm`,
`cufileops-0.5.tm`, `cuundo-0.4.tm`, `cufilter-0.1.tm`; from 0.3 also
`cufileops-0.4.tm`, `cuundo-0.3.tm`, `cusync-0.1.tm` (they were still in the
0.4 tree).

- `cusync::compare`: a directory that cannot be listed is an error
  `{CTRLUTILS CUSYNC LIST side dir}` (was an empty side; a failed listing of
  the target turned every source file into a copy over it). Tests
  `cusync-4.1`–`4.3`.
- `cufileops::paste`: entries of a cut that could not be copied stay on the
  clipboard (the whole cut was gone). New public `refresh`. Tests
  `cufileops-13.1`, `13.2`.
- `cuundo`: option `-refresh`; default `cufileops::refresh`; a failing
  refresh is an error `{CTRLUTILS CUUNDO REFRESH}` (was the private
  `_refresh` inside `catch`). Tests `cuundo-12.1`, `12.2`.
- `cufilter`: a filter that cannot be applied marks the entry `invalid`,
  sends `<<CufilterError>>` and keeps the message for `lastError` (was
  caught silently). Tests `cufilter-10.1`, `10.2`.
- Docs: `cusync` `same` compares size and mtime, not contents.
- Explorer: the messages for a missing `cusync` or `tkutlfind` name the
  module, not a file version (they said `cusync-0.2.tm`,
  `tkutlfind-0.2.tm`).

## 0.4 - 2026-10-20

Recommended pairing: tclutils 0.66.0 + tkutils 0.47.0 + ctrlutils 0.4.

Module versions: `cuundo` 0.4, `cusync` 0.2, `cufileops` 0.5. When copying
over an older tree, delete `cuundo-0.3.tm`, `cusync-0.1.tm` and
`cufileops-0.4.tm`.
The umbrella now requires these versions (it asked for `cufileops` 0.3
and no version for `cuundo`/`cusync`).

Note on the section 0.3 below: `cufileops` 0.4 and `cuundo` 0.3 came after
the umbrella 0.3 had been named and were never given an umbrella number of
their own; they belong to 0.3 as delivered. From 0.4 on, every module bump
goes with an umbrella bump.

- `cuundo`: a failed redo kept the step on neither stack -- it was lost. It
  goes back on the redo stack, as a failed undo does. Test `cuundo-1.10`.
- `cufileops`: `package require tkutils::tkufilelist 0.2`. It called
  `tkufilelist` without loading it and worked only when the caller had.
- `cusync::apply`: unknown options are an error naming the known ones
  (`-onfile -ondir`), as in the other controllers. Test `cusync-3.6`.
- `cusync::applyOne`: copies the source mtime only when both providers are
  the local provider. For a ZIP/DAV/SFTP target `file mtime` set the mtime
  of a local file that merely had the target's path. Test `cusync-3.7`.
- Tests: `cumonitor.test` works in the system temp directory (a run cut
  short left `cumon/` in the tree); the Explorer smoke test skips its load
  test without a display.
- Comments and docs: `cusync` (no delete option), `cumonitor` (no Tk),
  Explorer (one provider per tab), `cuundo.n` 0.3, `docs/cufileops.md`
  (tkudialog 0.3, tkufilelist 0.2), README pairing.

- `cuundo`: error dialogs get `-parent` (the list's toplevel), as in
  cufileops; the reasons ("no saved content to restore", ...) go through
  msgcat. No longer requires `tclutils::tuprovider` (it only calls the
  provider object it is given). Test `cuundo-11.1`.
- `cufileops::owSetApp name`: the application name for the "Open with"
  registry. Every application stored under "explorer" and so shared one
  registry; setting the variable after the first access did not reload.
  Test `cufileops-12.1`.
- `cufilter`: label "Filter:" and the clear button go through msgcat. Test
  `cufilter-9.1`.
- Explorer: a missing module at start names the module path as well as
  auto_path (the modules are found through the module path).

## 0.3

Recommended pairing: tclutils 0.64.0 + tkutils 0.46.0 + ctrlutils 0.3
(`cufileops` needs `tkutils::tkudialog` 0.3).

### `cufileops` 0.3 — multi-select on right-click (2026-10-02)

Right-click used to synthesize Button-1 and shrink an extended selection to one
row. Now: if the row under the pointer was already selected, the multi-selection
is kept (file-manager behaviour). Requires `tkudialog` 0.3.

### `cufileops` 0.4, `cuundo` 0.3 — texts through msgcat (2026-10-07)

Menu items, prompts and error messages go through `msgcat` when loaded, like
`tkudialog` 0.3; messages with a detail take `%s`. An application sets its
language in `::ctrlutils`. Without a catalog nothing changes. The delete
prompt is now one text per case ("Delete file '%s'?", "Delete folder
'%s'?"). Tests `cufileops-10.1/10.2`, `cuundo-10.1`.

### Tests / runner (2026-10-03)

- `tests/all.tcl`: per-file wall-clock limit (`CTRLUTILS_TESTGRENZE`, default 120 s).
- `tests/all.tcl` now calls `tclutils::tutestrun` (tclutils 0.64.0).
- `cufileops-3.7`: the fake `alited` is a `.bat` on Windows and PATH uses `;`.

## 0.2

First release with a changelog. Recommended pairing: tclutils 0.63.0 +
tkutils 0.44.0 + ctrlutils 0.2 (`cufileops` needs `tkutils::tkudialog` 0.2).


### The test runner says where the modules come from

Before the tests run, `tests/all.tcl` prints which file each library
(ctrlutils, tkutils and tclutils) resolves to -- found without loading anything -- and which
module-path variables are set; an old file beside a new one shows as
`(also: <version>)`. (Idea 5 of ideen-tclutils-tkutils.md.)

Own trees first: when the tree is already listed in `TCL8_6_TM_PATH` /
`TCL9_0_TM_PATH` behind a directory with an installed copy of the same version
(e.g. `site-tcl`), `tcl::tm::path add` does nothing and the installed copy
wins -- the suite then tests that copy, not the tree (reproduced with Tcl 8.6:
`TCL8_6_TM_PATH=<tree>:<site-tcl>`). The runner now removes its own trees from
those variables for the test processes and puts them in front in its own
interpreter, so the banner shows what the tests load. A test file started
directly, without the runner, is still exposed to this.

### Dialogs open over the Explorer's window (`cufileops` 0.2)

No dialog got a `-parent` up to 0.1, and `tkutils::tkudialog` 0.1 put every
one in the middle of the screen — with the Explorer on a second monitor,
prompts, confirmations and errors appeared on the other one. All 16 dialog
calls now go through `_dlg`, which passes the toplevel of the view's list as
`-parent`. Measured 2026-09-19: Explorer window at 860,560, the New Folder
prompt centred over it and transient to it — checked under openbox, xfwm4
and without a window manager, against the Explorer window's actual position
(under a decorating window manager its content does not sit at the requested
+x+y). With the old `cufileops` that test
stays red even with the fixed `tkudialog` — both libraries had to change.

### Explorer: errors you can read and copy

A startup error went to `tk_messageBox`, with the message and the whole Tcl
stack in one label: long, cramped, not selectable (reported 2026-09-19).
Errors now go to `tkudialog`: the message on top, the stack under "Details"
(scrolls, at most 12 lines high), both selectable, with a Copy button.
Background errors (event bindings, `after` scripts) use the same dialog
(`interp bgerror`, installed by `main`, so the test suite is not affected).
`tk_messageBox` remains only as the last resort when tkutils itself cannot be
loaded. The "Sync"/"Find unavailable" messages now open over their window.

The startup error in question was `unknown option "-provider"` from
`tkufiletree` (fixed in tkutils 0.44.0). It also left a second error: the
first tab-change event arrived before any tab was registered and found no
`tab` variable at all. `::explorer::tab` now starts as an empty dict.

### Descriptions and categories

None of the five controllers had a `# Description:` or `# Category:` header,
so `tools/check-modules.tcl` and its GUI showed empty columns. Added:
`Tk · controllers` for `cufileops`, `cufilter`, `cumonitor`, `cuundo`, and
`Archive · filesystem` for `cusync`, which needs no Tk. `tests/headers.test`
(new) checks both lines for every module. `tools/check-modules.tcl` is now
the same file as in tclutils; report and manifest here are unchanged by that.

### Man pages

`man/` did not exist although the README points to `man/mann/<module>.n` and
`check-modules` requires them; ctrlutils had no `tools/md2man.tcl`. The script
is now in `tools/` (the same file as in tclutils) and runs here unchanged:
`tclsh tools/md2man.tcl` writes the five pages to `man/mann/` (tried into a
scratch directory: cufileops 0.2, cufilter 0.1, cumonitor 0.2, cusync 0.1,
cuundo 0.2). The pages themselves are not part of this change.

### Versions and runner

- The umbrella said `package provide ctrlutils 0.2` next to
  `variable version 0.1` (review of 2026-09-19). Aligned, and
  `tests/versions.test` now checks file name, `package provide` and
  `variable version` of every module; with the old value it fails.
- `tests/all.tcl` used tcltest's `runAllTests`, which exits 0 even when tests
  fail. It now runs each file, reads its `Failed` count and exits 1 on failed
  tests, a missing summary or an error (counter-checked).
- `cufileops-9.1` measures the Explorer window where it really is. With the
  decoration correction in `tkudialog` 0.2 the prompt sits centred over the
  window under icewm, fluxbox, metacity, openbox, xfwm4 and without a window
  manager (Tcl/Tk 9.0.4 and 8.6.14).

### Options are checked

`cufileops::install`, `cuundo::install` and `cumonitor::install` reject an
unknown option with a message that lists the known ones and an errorcode
`{CTRLUTILS <MODULE> OPTION <opt>}`. Up to 0.1 the first two swallowed it
(`-onpo` silently disabled undo, `-lst` lost the Ctrl+Z binding);
`cumonitor` raised a plain error without errorcode.

### Explorer smoke test: one file, no hang

- There was a second, hand-synchronised copy of the Explorer smoke suite in
  `tests/`; the two had already drifted. `tests/smoke.test` now sources
  `apps/explorer/tests/smoke.test`, so there is one file.
- The suite relied on `TCLUTILS_TM`/`TKUTILS_TM`. Without them explorer.tcl
  could not find its packages, showed a **modal** `tk_messageBox` — and the
  test run hung there (measured). The test now adds the sibling module trees
  itself, and while explorer.tcl is sourced `tk_messageBox` and `exit` are
  replaced (the box records its text, `exit` raises it) and restored
  afterwards. Counter-check with `tkufiletree` hidden: `explorer-0-load`
  fails with "Missing package: tkutils::tkufiletree" instead of hanging.

### Test fixes

- `cufileops-3.7` called `auto_reset` to clear the `auto_execok` cache. That
  also deletes every auto-loaded proc, Tablelist's among them; the next
  tablelist widget in the same interpreter failed with `can't set
  "scalingpct": the variable is read-only`. Found because a new test only
  failed after 3.7. It now clears `::auto_execs` only and restores `PATH`.
- `cufileops.test`: a failed module load under Tk is now a failing test
  (`cufileops-0.0`) rather than a skipped "haveTk" constraint.

Measured 2026-09-19 without any module path in the environment, under
`xvfb-run` without a window manager and under icewm (8 test files): 67 passed, 0 skipped,
0 failed on Tcl/Tk 9.0.4 and 8.6.14, `all.tcl` exit 0.

### Open uses the local disk only for the local provider (2026-09-23)

`_localPath` used `file exists` on the provider path. A ZIP or remote path that
also existed on disk opened **that local file**. Saving from the opener then
changed the wrong file. Only `::tclutils::tuprovider::Local` may return a
disk path; every other provider writes `get` bytes into a process directory
`cufileops-<pid>-…`. The directory is removed on `exit`; stale sibling
directories are removed at first use (dead pid, or older than a day). The
`explorer-<pid>-<clicks>` name is gone.

`_copyTree` removes the paths it created on the destination if a later
`get`/`put`/`mkdir` fails, so a half-copied folder does not stay behind.

Cut (`cut`, Ctrl+X) and Delete on a source without `delete` show an error
dialog instead of a silent return.

Closing an Explorer tab (or a secondary window) destroys that tab's
provider unless another tab still holds the same object.

`dbutils/` is not part of this repository.

## 0.1

Initial set of controllers: `cufileops`, `cumonitor`, `cufilter`, `cuundo`,
`cusync`, and the Explorer reference application.
