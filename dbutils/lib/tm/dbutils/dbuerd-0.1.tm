# dbuerd-0.1.tm -- turn a neutral database-schema dict into Mermaid erDiagram
# markup. The output is rendered by tclutils::tuer (parse -> tudiagram model ->
# SVG/PNG); this module produces only text and therefore has no Tk, no DB and
# no tclutils dependency of its own.
#
# Schema dict:
#   tables -> { <TABLE> {cols {{name type notnull pk fk} ...}} ... }  (first-seen order)
#   fks    -> { {child childcol parent parentcol notnull identifying} ... }
#   notnull / pk / fk / identifying are 0 or 1.
#
# Mapping (one relationship line per FK):
#   <child> }o<sep><parentMark> <parent> : <childcol>
#     sep        = "--" if identifying else ".."   (solid = identifying)
#     parentMark = "||" if notnull     else "o|"   (parent: exactly-one / zero-or-one)
#     child side is always "}o" (zero-or-many) in v1.
# Entity block, one per table: a "type name [PK|FK]" line per column.
#
# The per-backend introspection layer (catalogue -> schema dict) will live
# alongside this module once the dbutils driver core exists; see SPEC-dbkit-erd.
#
# Namespace: ::dbutils::dbuerd   Package: dbutils::dbuerd 0.1
# Errors:    {DBUTILS DBUERD <REASON>}   REASON in EMPTY | ARG

package require Tcl 8.6 9

namespace eval ::dbutils::dbuerd {
    namespace export generate
}

proc ::dbutils::dbuerd::_err {reason msg} {
    return -code error -errorcode [list DBUTILS DBUERD $reason] $msg
}

# Normalise a catalogue name to a tuer-safe id ([A-Za-z0-9_-]).
proc ::dbutils::dbuerd::_normName {n} {
    regsub -all {[^A-Za-z0-9_-]} $n _ n
    return $n
}

# Build Mermaid erDiagram markup from a schema dict.
proc ::dbutils::dbuerd::generate {schema} {
    if {![dict exists $schema tables] || ![llength [dict get $schema tables]]} {
        _err EMPTY "schema has no tables"
    }
    set out "erDiagram\n"

    if {[dict exists $schema fks]} {
        foreach fk [dict get $schema fks] {
            if {[llength $fk] < 6} {
                _err ARG "fk entry needs {child childcol parent parentcol notnull identifying}: $fk"
            }
            lassign $fk child cc parent pc notnull identifying
            set sep        [expr {$identifying ? "--" : ".."}]
            set parentMark [expr {$notnull ? "||" : "o|"}]
            append out "    [_normName $child] \}o$sep$parentMark [_normName $parent] : $cc\n"
        }
    }

    dict for {tbl info} [dict get $schema tables] {
        append out "    [_normName $tbl] \{\n"
        if {[dict exists $info cols]} {
            foreach c [dict get $info cols] {
                lassign $c name type notnull pk fk
                set key ""
                if {$pk} {
                    set key " PK"
                } elseif {$fk} {
                    set key " FK"
                }
                append out "        $type $name$key\n"
            }
        }
        append out "    \}\n"
    }
    return $out
}

package provide dbutils::dbuerd 0.1
