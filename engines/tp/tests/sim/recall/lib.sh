#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
#  lib.sh — shared state for the recall simulator's one fake.
# -----------------------------------------------------------------------------
#  ct-recall.sh does almost nothing locally: it orchestrates, and every
#  operation that touches a disk happens on a machine it reached over ssh. So
#  this simulator has ONE fake instead of a dozen, and the whole cluster lives
#  under $SIMROOT. Same layout as the distribute simulator, because it is the
#  same three-machine shape run backwards - and two simulators that model one
#  cluster differently would each be proving something about a fleet that does
#  not exist.
#
#    $SIMROOT/pve/nodes/<node>/lxc/<id>.conf   pmxcfs, shared by every member
#    $SIMROOT/bkp/                             the backup node: the DESTINATION
#    $SIMROOT/srcs/<ip>/                       a compute node: the SOURCE
#
#  A violation is not a failed assertion, it is the fake refusing to pretend.
#  Anything recorded here means the engine did something that would have had a
#  consequence on a real machine, whatever the log said afterwards.
# =============================================================================
violation(){ printf 'VIOLATION: %s\n' "$*" >> "$SIMROOT/violations"; }
trace(){     printf '%s\n' "$*" >> "$SIMROOT/trace"; }

# A dry run may READ anything and must WRITE nothing. Armed from the engine's
# own arguments by run_engine, not by the scenario, so every dry scenario is
# policed whether or not its author thought about it.
dry_forbids(){
  [[ "${SIM_DRY:-0}" == 1 ]] || return 0
  violation "DRY RUN did this anyway: $*"
  return 1
}

src_dir(){ printf '%s/srcs/%s' "$SIMROOT" "$1"; }

# mounted is one line per mountpoint: <path><TAB><backing dir><TAB><options>. A
# path with no line is not a mountpoint, and rsync OUT of one reads an empty
# directory - which --delete on the far end then makes the DR copy match. That
# is the disaster this fake exists to catch, and it is silent on a real node.
is_mounted(){     awk -F'\t' -v p="$1" '$1==p{f=1} END{exit !f}' "$(src_dir "$2")/mounted" 2>/dev/null; }
mount_backing(){  awk -F'\t' -v p="$1" '$1==p{print $2; exit}'   "$(src_dir "$2")/mounted" 2>/dev/null; }
mount_opts(){     awk -F'\t' -v p="$1" '$1==p{print $3; exit}'   "$(src_dir "$2")/mounted" 2>/dev/null; }
add_mount(){ printf '%s\t%s\t%s\n' "$1" "$3" "${4:-}" >> "$(src_dir "$2")/mounted"; }
del_mount(){ local d; d="$(src_dir "$2")"
             awk -F'\t' -v p="$1" '$1!=p' "$d/mounted" > "$d/.m" 2>/dev/null
             mv -f "$d/.m" "$d/mounted" 2>/dev/null; return 0; }

st_field(){ cat "$(src_dir "$1")/storage/$2.$3" 2>/dev/null; }
