# dbutils::dbuerd

Turn a neutral database-schema dict into Mermaid `erDiagram` markup, ready to be
rendered by `tclutils::tuer`. This module produces only text -- it has no Tk, no
database and no `tclutils` dependency of its own. The per-backend introspection
layer (catalogue -> schema dict) will be added alongside it once the dbutils
driver core exists.

## Package

```tcl
package require dbutils::dbuerd 0.1
```

## Command

```tcl
::dbutils::dbuerd::generate schemaDict   ;# -> Mermaid erDiagram text
```

## Schema dict

```tcl
tables -> { <TABLE> {cols {{name type notnull pk fk} ...}} ... }   # first-seen order
fks    -> { {child childcol parent parentcol notnull identifying} ... }
```

`notnull`, `pk`, `fk` and `identifying` are `0` or `1`. `identifying` means the
FK's child column(s) are part of the child's primary key. Composite keys use one
`cols` row per key column and one `fks` row per FK column.

## Mapping

One relationship line per FK:

```
<child> }o<sep><parentMark> <parent> : <childcol>
```

- `sep` = `--` (solid) if `identifying`, else `..` (dashed)
- `parentMark` = `||` (exactly-one) if the FK is `notnull`, else `o|` (zero-or-one)
- the child side is always `}o` (zero-or-many) in v1

One entity block per table, with a `type name [PK|FK]` line per column (PK takes
precedence over FK). Catalogue names are normalised to tuer-safe ids via
`regsub -all {[^A-Za-z0-9_-]} name _`.

## Usage

```tcl
package require dbutils::dbuerd
set schema {
  tables {
    customer {cols {{id INTEGER 1 1 0} {name VARCHAR 1 0 0} {region_id INTEGER 0 0 1}}}
    region   {cols {{id INTEGER 1 1 0} {name VARCHAR 1 0 0}}}
  }
  fks {{customer region_id region id 0 0}}
}
set erd [::dbutils::dbuerd::generate $schema]

# render via tclutils (separate dependency, on the caller's side):
package require tclutils::tuer
set model [::tclutils::tuer::parse $erd]
::tclutils::tudiagram::writePng $model schema.png -scale 2
```

## v1 scope

In: tables -> entities, columns with type / name / PK / FK, FKs -> crow's-foot
relationships with identifying vs. non-identifying and parent optionality, name
normalisation. Out: introspection (separate layer), views, indexes,
unique/check constraints as relationships, junction-table collapsing, and
child-side optionality (fixed at `}o`).

## Error codes

`-errorcode {DBUTILS DBUERD <REASON>}` -- `EMPTY` (no tables), `ARG` (malformed
fk entry).
