package require Tcl 8.6-

# Run every *.test in this directory, each in its own interpreter process, and
# exit 1 if any file reports failed tests, writes no summary, or dies.
#
# Up to tkutils 0.44.0 / ctrlutils 0.2 (first build) this runner looked only at
# the child's exit code. tcltest ends a file with exit code 0 even when tests
# FAILED, so the suite reported success with red tests in it (review of
# 2026-09-19: tkudialog-6.* and cufileops-9.1 red, all.tcl exit 0). Now the
# "Total ... Failed N" line of every file is read, as tclutils' runner does.
#
#   tclsh tests/all.tcl ?tcltest options, e.g. -match pattern?
set here [file dirname [file normalize [info script]]]

# --- where the modules come from (before any test runs) --------------------
# A green run says little if it loaded the wrong copy: an installed version, a
# module path from the environment, an old file beside a new one. So say
# where each library resolves -- found without loading anything -- and which
# module-path variables are set. (Idea 5 of ideen-tclutils-tkutils.md;
# 2026-09-19 a green suite depended on a TCL9_0_TM_PATH set in the shell.)
# tmFront dir -- put DIR at the front of the module path. A plain
# `tcl::tm::path add` does nothing when DIR is already listed -- e.g. from
# TCL8_6_TM_PATH, whose entries end up in reverse order. With the tree listed
# behind site-tcl, an installed copy of the same version then wins, and the
# suite tests that copy instead of the tree (reproduced 2026-09-19 with Tcl
# 8.6: TCL8_6_TM_PATH=<tree>:<site-tcl>).
proc tmFront {dir} {
    catch {tcl::tm::path remove $dir}
    tcl::tm::path add $dir
}

# ownTreesFirst root libs -- the module trees this suite is about: own lib/tm
# and the sibling libraries. Removed from TCL<ver>_TM_PATH so that the test
# processes started below put them in front themselves.
proc ownTrees {root libs} {
    set parent [file dirname $root]
    set dirs [list [file normalize [file join $root lib tm]]]
    foreach lib $libs {
        set var [string toupper $lib]_TM
        if {[info exists ::env($var)] && $::env($var) ne ""} {
            lappend dirs [file normalize $::env($var)]
        } else {
            foreach c [lsort -decreasing [glob -nocomplain -type d \
                    [file join $parent $lib* lib tm]]] {
                lappend dirs [file normalize $c]
                break
            }
        }
    }
    return [lsort -unique $dirs]
}
proc stripTreesFromEnv {dirs} {
    set sep [expr {$::tcl_platform(platform) eq "windows" ? ";" : ":"}]
    foreach var [array names ::env TCL*_TM_PATH] {
        set keep {}
        foreach d [split $::env($var) $sep] {
            if {$d ne "" && [file normalize $d] ni $dirs} { lappend keep $d }
        }
        set ::env($var) [join $keep $sep]
    }
}

proc showOrigins {root libs} {
    set dirs [ownTrees $root $libs]
    # the test processes: own trees not in the env path, so their own
    # `tcl::tm::path add` puts them in front
    stripTreesFromEnv $dirs
    # this interpreter: the same order the tests will see
    foreach d [lreverse $dirs] { tmFront $d }
    catch {package require __resolve_all_modules__}
    puts "Modules resolve to:"
    foreach lib $libs {
        set vers [lsort -dictionary [package versions $lib]]
        if {![llength $vers]} {
            puts [format "  %-10s NOT FOUND" $lib]
            continue
        }
        set v [lindex $vers end]
        set line [format "  %-10s %-8s %s" $lib $v [lindex [package ifneeded $lib $v] end]]
        if {[llength $vers] > 1} { append line "   (also: [lrange $vers 0 end-1])" }
        puts $line
    }
    foreach var {TCLUTILS_TM TKUTILS_TM TCL8_6_TM_PATH TCL9_0_TM_PATH TCLLIBPATH} {
        if {[info exists ::env($var)] && $::env($var) ne ""} {
            puts "  note: $var is set: $::env($var)"
        }
    }
    puts ""
}
showOrigins [file dirname $here] {ctrlutils tkutils tclutils}

set bad {}
foreach f [lsort [glob -nocomplain -directory $here *.test]] {
    set name [file tail $f]
    set rc [catch {exec [info nameofexecutable] $f {*}$argv 2>@1} out]
    puts $out
    set failed -1
    foreach line [split $out \n] {
        if {[regexp {\tTotal\t\d+\tPassed\t\d+\tSkipped\t\d+\tFailed\t(\d+)} $line -> n]} {
            set failed $n
        }
    }
    if {$failed < 0} {
        lappend bad "$name (no summary)"
    } elseif {$failed > 0} {
        lappend bad "$name ($failed failed)"
    } elseif {$rc} {
        lappend bad "$name (exit code / error)"
    }
}
if {[llength $bad]} {
    puts "\nFiles with problems:"
    foreach b $bad { puts "  $b" }
    exit 1
}
puts "\nAll test files passed"
exit 0
