# cusync-0.3.tm -- directory comparison and one-way mirroring over tuproviders.
# Description: directory compare and one-way mirroring over providers, no Tk
# Category: Archive · filesystem
#
# Compares two directory trees (each on its own provider, so local <-> ZIP <->
# SFTP <-> WebDAV all work) and mirrors newer/missing entries from one side to
# the other. One-way and non-destructive: it copies and updates, it never
# deletes on the target (there is no option for that).
#
# Model/controller layer (cu*). No Tk here; the Explorer supplies the dialog.
#
# Public API:
#   compare provL dirL provR dirR      -> list of diff dicts (see below)
#   plan    diffs direction            -> list of action dicts for a direction
#   apply   srcProv srcDir dstProv dstDir actions ?-ondir cb? ?-onfile cb?
#                                      -> dict {done N errors {..}}
#
# A diff dict has: rel (path relative to the roots, "/"-separated), name,
# status, ltype, rtype. status is one of:
#   onlyLeft onlyRight newerLeft newerRight diff same conflict
# ("diff" = same mtime but different size; "conflict" = file vs dir mismatch).
#
# direction is LR (left is source) or RL (right is source).
#
# Errors: a directory that exists on a side but cannot be listed raises
# {CTRLUTILS CUSYNC LIST side dir} (side L or R). Up to 0.2 the error was
# caught and the side counted as empty: a failed listing of the target
# looked like an empty target, and every source file became a copy over it.

package require Tcl 8.6-

namespace eval ::ctrlutils {}
namespace eval ::ctrlutils::cusync {
    namespace export compare plan apply applyOne
}

# Universal path join for provider paths. All providers accept "/"-separated
# paths (local paths too: Tcl accepts forward slashes on Windows). Keeps the
# code provider-agnostic instead of switching on the provider class.
proc ::ctrlutils::cusync::_join {base name} {
    set b [string trimright $base /]
    if {$b eq ""} { return "/$name" }
    return "$b/$name"
}

# Compare two trees. Returns a flat list of diff dicts, parents before children.
proc ::ctrlutils::cusync::compare {provL dirL provR dirR} {
    set out {}
    _cmpDir $provL $dirL $provR $dirR "" out
    return $out
}

# Entries of DIR as a dict name -> entry. A side whose directory does not
# exist there (exists 0: the subtree is only on the other side) is empty; a
# listing error of an existing directory is an error, not an empty side.
proc ::ctrlutils::cusync::_entries {prov dir exists side} {
    set out [dict create]
    if {!$exists} { return $out }
    if {[catch {$prov list $dir} entries]} {
        return -code error -errorcode [list CTRLUTILS CUSYNC LIST $side $dir] \
            "cannot list \"$dir\" ($side): $entries"
    }
    foreach e $entries { dict set out [dict get $e name] $e }
    return $out
}

proc ::ctrlutils::cusync::_cmpDir {provL dirL provR dirR rel outVar {existsL 1} {existsR 1}} {
    upvar 1 $outVar out
    set le [_entries $provL $dirL $existsL L]
    set re [_entries $provR $dirR $existsR R]
    set names [lsort -dictionary -unique [concat [dict keys $le] [dict keys $re]]]
    foreach n $names {
        set r [expr {$rel eq "" ? $n : "$rel/$n"}]
        set hasL [dict exists $le $n] ; set hasR [dict exists $re $n]
        if {$hasL && !$hasR} {
            set t [dict get [dict get $le $n] type]
            lappend out [dict create rel $r name $n status onlyLeft ltype $t rtype ""]
            if {$t eq "dir"} {
                # enumerate the left-only subtree so every file gets mirrored
                _cmpDir $provL [_join $dirL $n] $provR [_join $dirR $n] $r out 1 0
            }
        } elseif {!$hasL && $hasR} {
            set t [dict get [dict get $re $n] type]
            lappend out [dict create rel $r name $n status onlyRight ltype "" rtype $t]
            if {$t eq "dir"} {
                _cmpDir $provL [_join $dirL $n] $provR [_join $dirR $n] $r out 0 1
            }
        } else {
            set el [dict get $le $n] ; set er [dict get $re $n]
            set tl [dict get $el type] ; set tr [dict get $er type]
            if {$tl eq "dir" && $tr eq "dir"} {
                _cmpDir $provL [_join $dirL $n] $provR [_join $dirR $n] $r out
            } elseif {$tl eq "file" && $tr eq "file"} {
                set ml [dict get $el mtime] ; set mr [dict get $er mtime]
                set sl [dict get $el size]  ; set sr [dict get $er size]
                if {$ml ne "" && $mr ne "" && $ml > $mr} {
                    set st newerLeft
                } elseif {$ml ne "" && $mr ne "" && $mr > $ml} {
                    set st newerRight
                } elseif {$sl ne $sr} {
                    set st diff
                } else {
                    set st same
                }
                lappend out [dict create rel $r name $n status $st ltype file rtype file]
            } else {
                lappend out [dict create rel $r name $n status conflict ltype $tl rtype $tr]
            }
        }
    }
    return
}

# Build the action list for a direction. Copies missing entries and updates
# newer/differing files from the source side to the target side. Never deletes.
proc ::ctrlutils::cusync::plan {diffs direction} {
    set acts {}
    foreach d $diffs {
        set st  [dict get $d status]
        set rel [dict get $d rel]
        if {$direction eq "LR"} {
            switch -- $st {
                onlyLeft {
                    lappend acts [dict create op copy rel $rel type [dict get $d ltype]]
                }
                newerLeft - diff {
                    lappend acts [dict create op copy rel $rel type file]
                }
            }
        } elseif {$direction eq "RL"} {
            switch -- $st {
                onlyRight {
                    lappend acts [dict create op copy rel $rel type [dict get $d rtype]]
                }
                newerRight - diff {
                    lappend acts [dict create op copy rel $rel type file]
                }
            }
        }
    }
    return $acts
}

# Execute actions: copy from (srcProv,srcDir) to (dstProv,dstDir). Dirs are
# created; files are read from the source and written to the target, creating
# parent directories as needed. Returns {done N errors {msg ...}}. Optional
# -onfile/-ondir callbacks get the rel path (for progress).
proc ::ctrlutils::cusync::apply {srcProv srcDir dstProv dstDir actions args} {
    # unknown options are an error naming the known ones, as in the other
    # controllers (up to 2026-10-20 `array set` swallowed a typo like -onfiel)
    if {[llength $args] % 2} {
        return -code error -errorcode {CTRLUTILS CUSYNC OPTION} \
            "missing value for option \"[lindex $args end]\""
    }
    foreach {k v} $args {
        if {$k ni {-onfile -ondir}} {
            return -code error -errorcode [list CTRLUTILS CUSYNC OPTION $k] \
                "unknown option \"$k\"\nKnown: -onfile -ondir"
        }
    }
    array set o {-onfile "" -ondir ""}
    array set o $args
    set done 0 ; set errs {}
    foreach a $actions {
        set rel [dict get $a rel]
        if {[dict get $a type] eq "dir"} {
            if {$o(-ondir) ne ""} { catch {uplevel #0 [linsert $o(-ondir) end $rel]} }
        } else {
            if {$o(-onfile) ne ""} { catch {uplevel #0 [linsert $o(-onfile) end $rel]} }
        }
        set r [applyOne $srcProv $srcDir $dstProv $dstDir $a]
        if {[dict get $r ok]} {
            incr done
        } else {
            lappend errs [dict get $r error]
        }
    }
    return [dict create done $done errors $errs]
}

# Apply a SINGLE action. Returns {ok 1} or {ok 0 error msg}. Factored out so a
# UI can step through a plan one action at a time (via after), keeping the event
# loop live for a progress bar and a Cancel button instead of freezing.
proc ::ctrlutils::cusync::applyOne {srcProv srcDir dstProv dstDir action} {
    set rel  [dict get $action rel]
    set from [_join $srcDir $rel]
    set to   [_join $dstDir $rel]
    if {[dict get $action type] eq "dir"} {
        if {[catch {$dstProv mkdir $to} e]} {
            return [dict create ok 0 error "$rel: $e"]
        }
        return [dict create ok 1]
    }
    catch {$dstProv mkdir [_parent $to]}
    if {[catch {$srcProv get $from} data]} {
        return [dict create ok 0 error "$rel (read): $data"]
    }
    if {[catch {$dstProv put $to $data} e]} {
        return [dict create ok 0 error "$rel (write): $e"]
    }
    # Preserve source mtime (best-effort) so mirrors are idempotent. Only when
    # both sides are the local provider: $from and $to are provider paths, and
    # for a ZIP/DAV/SFTP side `file mtime` would read or touch a local file
    # that merely has the same name.
    if {[_isLocal $srcProv] && [_isLocal $dstProv]} {
        catch {file mtime $to [file mtime $from]}
    }
    return [dict create ok 1]
}

proc ::ctrlutils::cusync::_isLocal {prov} {
    expr {![catch {info object class $prov} c] \
        && $c eq "::tclutils::tuprovider::Local"}
}

# Parent of a "/"-path (works regardless of provider; forward-slash safe).
proc ::ctrlutils::cusync::_parent {p} {
    set i [string last / $p]
    if {$i <= 0} { return "/" }
    return [string range $p 0 [expr {$i - 1}]]
}

package provide ctrlutils::cusync 0.3
