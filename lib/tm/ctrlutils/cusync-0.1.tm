# cusync-0.1.tm -- directory comparison and one-way mirroring over tuproviders.
#
# Compares two directory trees (each on its own provider, so local <-> ZIP <->
# SFTP <-> WebDAV all work) and mirrors newer/missing entries from one side to
# the other. One-way and non-destructive by default: it copies and updates, it
# never deletes on the target unless explicitly asked.
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

proc ::ctrlutils::cusync::_cmpDir {provL dirL provR dirR rel outVar} {
    upvar 1 $outVar out
    set le [dict create] ; set re [dict create]
    catch { foreach e [$provL list $dirL] { dict set le [dict get $e name] $e } }
    catch { foreach e [$provR list $dirR] { dict set re [dict get $e name] $e } }
    set names [lsort -dictionary -unique [concat [dict keys $le] [dict keys $re]]]
    foreach n $names {
        set r [expr {$rel eq "" ? $n : "$rel/$n"}]
        set hasL [dict exists $le $n] ; set hasR [dict exists $re $n]
        if {$hasL && !$hasR} {
            set t [dict get [dict get $le $n] type]
            lappend out [dict create rel $r name $n status onlyLeft ltype $t rtype ""]
            if {$t eq "dir"} {
                # enumerate the left-only subtree so every file gets mirrored
                _cmpDir $provL [_join $dirL $n] $provR [_join $dirR $n] $r out
            }
        } elseif {!$hasL && $hasR} {
            set t [dict get [dict get $re $n] type]
            lappend out [dict create rel $r name $n status onlyRight ltype "" rtype $t]
            if {$t eq "dir"} {
                _cmpDir $provL [_join $dirL $n] $provR [_join $dirR $n] $r out
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
    # Preserve source mtime (best-effort, local <-> local) so mirrors are
    # idempotent; silently skipped for zip/dav/sftp targets.
    catch {file mtime $to [file mtime $from]}
    return [dict create ok 1]
}

# Parent of a "/"-path (works regardless of provider; forward-slash safe).
proc ::ctrlutils::cusync::_parent {p} {
    set i [string last / $p]
    if {$i <= 0} { return "/" }
    return [string range $p 0 [expr {$i - 1}]]
}

package provide ctrlutils::cusync 0.1
