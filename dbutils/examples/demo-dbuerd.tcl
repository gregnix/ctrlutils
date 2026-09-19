# demo-dbuerd.tcl -- build an erDiagram from a schema dict and, if a tclutils
# checkout is reachable, render it to PNG.
#
#   tclsh demo-dbuerd.tcl
#
# To render, the demo needs tclutils. It looks for it in two places, in order:
#   1. $TCLUTILS_TM (explicit module path)
#   2. a sibling checkout at ../../tclutils/lib/tm -- e.g. ~/lib/tcltk/tclutils
#      sitting next to ~/lib/tcltk/dbutils
# If neither is found it just prints the markup (dbutils has no hard tclutils
# dependency).

set here [file normalize [file dirname [info script]]]
tcl::tm::path add [file join $here .. lib tm]

# make a tclutils checkout discoverable without forcing a hard dependency
set tclutilsCandidates {}
if {[info exists ::env(TCLUTILS_TM)]} { lappend tclutilsCandidates $::env(TCLUTILS_TM) }
lappend tclutilsCandidates [file normalize [file join $here .. .. tclutils lib tm]]
foreach path $tclutilsCandidates {
    if {$path ne "" && [file isdirectory $path]} { catch {tcl::tm::path add $path} }
}

package require dbutils::dbuerd

set schema {
  tables {
    region    {cols {{id INTEGER 1 1 0} {name VARCHAR 1 0 0}}}
    customer  {cols {{id INTEGER 1 1 0} {name VARCHAR 1 0 0} {email VARCHAR 0 0 0} {region_id INTEGER 0 0 1}}}
    orders    {cols {{id INTEGER 1 1 0} {customer_id INTEGER 1 0 1} {created DATE 0 0 0}}}
    orderline {cols {{order_id INTEGER 1 1 1} {line_no INTEGER 1 1 0} {product VARCHAR 1 0 0} {qty NUMERIC 1 0 0}}}
  }
  fks {
    {customer region_id region id 0 0}
    {orders customer_id customer id 1 0}
    {orderline order_id orders id 1 1}
  }
}

set erd [::dbutils::dbuerd::generate $schema]
puts $erd

if {![catch {package require tclutils::tuer}]} {
    set model [::tclutils::tuer::parse $erd]
    set png [file join $here erd-demo.png]
    ::tclutils::tudiagram::writePng $model $png -scale 2
    puts "rendered: $png"
} else {
    puts "(tclutils not found -- set TCLUTILS_TM or put a tclutils checkout next to dbutils)"
}
