#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
#  lib.sh — shared state for the sync simulator's two fakes.
# -----------------------------------------------------------------------------
#  `ketsync sync` does nothing locally either: it reads its own files, asks
#  every other machine what generation it holds, and pushes. Both halves of
#  that go over ssh, so there are two fakes - ssh and rsync - and the whole
#  fleet lives under $SIMROOT.
#
#    $SIMROOT/master/            this machine's install. KS_BASE points here
#    $SIMROOT/hosts/<ip>/fs/...  another machine's WHOLE filesystem, so a path
#                                that exists here and not there behaves the way
#                                it really does: the push fails
#    $SIMROOT/hosts/<ip>/.down   unreachable
#
#  Modelling the remote as a filesystem rather than as "the same directory
#  again" is the entire point. Every install in this fleet is at a different
#  absolute path - /root/script/KetSync on one machine, /root/github/KetSync on
#  another - and a simulator that assumes they match cannot see the bug that
#  causes.
#
#  A violation is not a failed assertion, it is the fake refusing to pretend.
#  Anything recorded here means sync did something that would have had a
#  consequence on a real fleet, whatever it printed afterwards.
# =============================================================================
violation(){ printf 'VIOLATION: %s\n' "$*" >> "$SIMROOT/violations"; }
trace(){     printf '%s\n' "$*" >> "$SIMROOT/trace"; }

host_dir(){ printf '%s/hosts/%s' "$SIMROOT" "$1"; }
host_up(){  [[ ! -f "$(host_dir "$1")/.down" ]]; }

# An absolute path on machine $1, resolved into this sandbox.
remote_path(){ printf '%s/fs%s' "$(host_dir "$1")" "$2"; }

# The files that are per-machine and must never arrive from anywhere else.
# ketsync.conf carries KS_ROLE: one copy of it on every node makes every node
# believe it may write, which is the split brain the whole design exists to
# prevent. The fake refuses to pretend a push of one of these was harmless,
# whatever the engine's own denylist did or did not do.
is_per_machine(){
  case "$(basename "$1")" in
    ketsync.conf|ctrep.conf|ctmig.conf|nodes.map) return 0;;
    *) return 1;;
  esac
}

gen_of(){ sed -n 's/^#[[:space:]]*generation:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$1" 2>/dev/null | head -1; }
