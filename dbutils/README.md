# dbutils

Database utilities for Tcl 8.6 and Tcl 9.x. The database companion to
[tclutils](https://github.com/gregnix) (pure-Tcl utilities) and tkutils (Tk
widgets): dbutils is the home for everything database-related -- schema tools,
diagram generators, and (later) a unified driver core over Oracle and TDBC
backends.

## Modules

| Module | Kind | Summary |
|--------|------|---------|
| `dbuerd` | generator | Build a Mermaid `erDiagram` from a neutral schema dict; rendered by `tclutils::tuer`. DB-free -- text only. |

The per-backend schema introspection layer (SQLite / PostgreSQL / Oracle
catalogue -> schema dict) and the unified driver core are planned; see
`docs/` and the ER-diagram spec.

## Conventions

- Modules: `lib/tm/dbutils/<name>-<ver>.tm` (pure tm-discovery, no pkgIndex).
  Requiring `dbutils` loads the core via the umbrella `lib/tm/dbutils-<ver>.tm`.
- Tests: `tests/<name>.test` (tcltest, run on Tcl 8.6 and 9.x).
- Docs: `docs/<name>.md`.
- Identifiers, code and comments in English.
- Error codes: `{DBUTILS <MOD> <REASON>}`.

## Dependencies

Pure Tcl. `dbuerd` itself needs nothing beyond Tcl; rendering its output is done
by the caller via `tclutils::tuer`. Future driver modules will load their
backend (TDBC / Oratcl) lazily, so callers only pay for the backend they use.

## Running the tests

```sh
tclsh tests/dbuerd.test
# optional erDiagram round-trip against a tclutils checkout:
TCLUTILS_TM=/path/to/tclutils/lib/tm tclsh tests/dbuerd.test
```
