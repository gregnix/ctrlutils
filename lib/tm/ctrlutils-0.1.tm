# ctrlutils -- the controller/glue layer.
#
# Loading this package pulls in every ctrlutils controller at once, for callers
# that want the whole layer without naming each module. Individual controllers
# can still be required on their own (package require ctrlutils::cufilter).
#
# ctrlutils is the third repo alongside tclutils (logic, no Tk) and tkutils
# (widgets). Its modules are CONTROLLERS: they wire events on existing widgets
# to logic (a provider, a timer), but are not themselves widgets and are not
# pure logic. In MVC terms: tclutils = Model, tkutils = View, ctrlutils =
# Controller.
#
#   cufileops  capability-driven file operations (New/Rename/Delete/Copy/Paste)
#   cumonitor  provider-agnostic directory watcher (polls, fires on change)
#   cufilter   live name-filter box wired to a file list
#   cuundo     undo/redo for cufileops operations
#   cusync     one-way directory compare and mirror (provider-agnostic, no Tk)
#
# Each depends only on the provider interface (any tclutils provider) and on
# tkutils widgets -- never on a specific application, so any app built on the
# provider abstraction can reuse them.

package require Tcl 8.6-

namespace eval ::ctrlutils {
    variable version 0.1
}

package require ctrlutils::cufileops
package require ctrlutils::cumonitor
package require ctrlutils::cufilter
package require ctrlutils::cuundo
package require ctrlutils::cusync

package provide ctrlutils 0.1
