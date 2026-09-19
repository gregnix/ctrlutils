# Changelog

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

### Not changed in this release

Temp files written by "Open" for provider-backed files are still not removed;
`_copyTree` still leaves a partial folder when it fails midway; `dbutils/` is
still in this repository. See the review of 2026-09-19.

## 0.1

Initial set of controllers: `cufileops`, `cumonitor`, `cufilter`, `cuundo`,
`cusync`, and the Explorer reference application.
