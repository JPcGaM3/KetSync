#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
#  lib.sh — shared state for the distribute simulator's one fake.
# -----------------------------------------------------------------------------
#  ct-distribute.sh does almost nothing locally: it orchestrates, and every
#  operation that touches a disk happens on a machine it reached over ssh. So
#  this simulator has ONE fake instead of a dozen, and the whole cluster lives
#  under $SIMROOT.
#
#    $SIMROOT/pve/nodes/<node>/lxc/<id>.conf   pmxcfs, shared by every member
#    $SIMROOT/bkp/                             the backup node
#    $SIMROOT/nodes/<node>/                    a production node
#    $SIMROOT/targets/<ip>/                    a compute node, the destination
#
#  A violation is not a failed assertion, it is the fake refusing to pretend.
#  Anything recorded here means the engine did something that would have had a
#  consequence on a real machine, whatever the log said afterwards.
# =============================================================================
violation(){ printf 'VIOLATION: %s\n' "$*" >> "$SIMROOT/violations"; }
trace(){     printf '%s\n' "$*" >> "$SIMROOT/trace"; }

# A dry run may READ anything and must WRITE nothing. Armed from the engine's
# own arguments by run_engine, not by the scenario, so every dry scenario is
# policed whether or not its author thought about it - including the ones
# written by somebody who never read this file.
dry_forbids(){
  [[ "${SIM_DRY:-0}" == 1 ]] || return 0
  violation "DRY RUN did this anyway: $*"
  return 1
}

tgt_dir(){ printf '%s/targets/%s' "$SIMROOT" "$1"; }

# mounted is one line per mountpoint: <path><TAB><backing dir>. A path with no
# line is not a mountpoint, and rsync into one is the disaster this fake exists
# to catch - on a real node it fills the root filesystem instead of the volume.
is_mounted(){ awk -F'\t' -v p="$1" '$1==p{f=1} END{exit !f}' "$(tgt_dir "$2")/mounted" 2>/dev/null; }
mount_backing(){ awk -F'\t' -v p="$1" '$1==p{print $2; exit}' "$(tgt_dir "$2")/mounted" 2>/dev/null; }
add_mount(){ printf '%s\t%s\n' "$1" "$3" >> "$(tgt_dir "$2")/mounted"; }
del_mount(){ local d; d="$(tgt_dir "$2")"
             awk -F'\t' -v p="$1" '$1!=p' "$d/mounted" > "$d/.m" 2>/dev/null
             mv -f "$d/.m" "$d/mounted" 2>/dev/null; return 0; }

st_field(){ cat "$(tgt_dir "$1")/storage/$2.$3" 2>/dev/null; }
