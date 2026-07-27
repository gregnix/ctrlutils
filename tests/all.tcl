# Run all ctrlutils tests: tclsh ctrlutils-all.tcl  (or under wish for the
# Tk-constrained ones). GUI tests are skipped when Tk is unavailable.
package require tcltest
namespace import ::tcltest::*

set here [file dirname [file normalize [info script]]]
configure -testdir $here {*}$argv
runAllTests
