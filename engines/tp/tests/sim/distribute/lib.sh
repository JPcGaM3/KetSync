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

# ---- D1's isolation probe -------------------------------------------------
# Reproduces what the engine's remote snippet does on a real node, including
# the part that matters: a missing bridge exits BEFORE it can echo OK, so
# "unverified" stays distinguishable from "isolated".
#
# It reads TWO sources on purpose, because the engine's whole argument is that
# they can disagree. <id>.nets is what pct config says the container has;
# <id>.veth is which bridge the kernel has each veth actually enslaved to. A
# config records a change that a running container never received; the master
# of a veth cannot.
#
# A compute node is both a production node and a placement target, so both
# branches of the fake call this one function - if they could answer
# differently, a scenario would be proving something about the fake.
#
# The honest limit: this reproduces what the snippet DOES, not what it says. No
# scenario and no mutation can notice the snippet's own text changing, so the
# two are kept in step by hand - if the engine starts asking a different
# question, this has to be taught to answer it.
d1_probe(){ # $1 = the node's dir under nodes/, $2 = the command string
  local n="$1" flat id br f ifn master port kind
  flat="$(printf '%s' "$2" | tr '\n' ' ')"
  id="$(sed -n 's|.*/sys/class/net/veth\([0-9][0-9]*\)i\*.*|\1|p' <<<"$flat")"
  br="$(sed -n 's|.*ip -br link show \([^ ]*\).*|\1|p' <<<"$flat")"
  printf 'NETS %s\n' "$(grep -c . "$n/ct/$id.nets" 2>/dev/null || echo 0)"
  f="$n/ct/$id.veth"
  if [[ -f "$f" ]]; then
    while read -r ifn master; do
      [[ -n "${ifn:-}" ]] && printf 'VETH %s %s\n' "$ifn" "$master"
    done < "$f"
  fi
  [[ -f "$n/bridges/$br" ]] || { echo BRMISSING; return 0; }
  while read -r port kind _; do
    [[ -z "${port:-}" ]] && continue
    case "$kind" in nic|bond) printf 'UPLINK %s\n' "$port";; esac
  done < "$n/bridges/$br"
  echo OK; return 0
}

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
