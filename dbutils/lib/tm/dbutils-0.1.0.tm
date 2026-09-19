# dbutils-0.1.0.tm -- umbrella package for the dbutils library, the database
# companion to tclutils (pure Tcl) and tkutils (Tk widgets). Requiring `dbutils`
# loads the library's core modules; individual modules can also be required on
# their own. Pure tm-discovery, no pkgIndex.

package require Tcl 8.6 9

package require dbutils::dbuerd 0.1

package provide dbutils 0.1.0
