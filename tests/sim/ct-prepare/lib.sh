#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
#  lib.sh — shared state for the prepare simulator's one fake.
# -----------------------------------------------------------------------------
#  ct-prepare.sh touches nothing locally: it reads a container's config and
#  writes its network, both on a machine it reached over ssh. So there is ONE
#  fake and the whole cluster lives under $SIMROOT.
#
#    $SIMROOT/pve/nodes/<node>/lxc/<id>.conf   pmxcfs, shared by every member
#    $SIMROOT/pve/ketsync/isolate/<id>.tsv     the record - pmxcfs, so ONE copy
#                                              no matter which node wrote it
#    $SIMROOT/nodes/<node>/                    a production node: its
#                                              containers, its bridges, its
#                                              storages
#
#  A violation is not a failed assertion, it is the fake refusing to pretend.
#  This engine exists to be run against containers whose disk has already gone,
#  and the disaster it could cause is being run against one whose disk is fine -
#  so that is what the fake refuses to simulate, whatever the log said.
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

node_dir(){ printf '%s/nodes/%s' "$SIMROOT" "$1"; }
ct_dir(){   printf '%s/nodes/%s/ct' "$SIMROOT" "$1"; }
rec_file(){  printf '%s/pve/ketsync/isolate/%s.tsv' "$SIMROOT" "$1"; }
evac_file(){ printf '%s/pve/ketsync/evacuate/%s.tsv' "$SIMROOT" "$1"; }

# alive | dead | gone, as the WORD a scenario set - not a boolean, because the
# engine distinguishes three cases and a boolean would let two of them collapse
# into one without any test noticing.
storage_verdict_of(){ cat "$(node_dir "$1")/storage/$2.verdict" 2>/dev/null; }

# What `timeout N stat` would exit with, which is what the engine actually
# reads. A live mount answers (0) and a dead one blocks until timeout kills
# it (124). An UNMOUNTED one also answers 0, instantly - `umount` takes the
# mount out of the namespace and leaves PVE's mountpoint DIRECTORY behind, an
# empty dir on the node's root filesystem, and a stat on an empty local dir
# succeeds.
#
# This function said ENOENT for that case for a month. The engine's verdict
# read the real thing as ALIVE, every scenario passed against the lie, and a
# live drill watched P2 refuse to isolate a container four minutes after the
# same run's own `umount -f -l`. A fake models what the world does, not what
# would be convenient for the code under test - the world's answer here is
# "the stat succeeds and only /proc/mounts knows the difference", so that is
# what this fake says, and mounted_of below is the /proc/mounts half.
# A fourth state, `stale`: still IN the mount table, and stat fails instantly
# instead of blocking - ESTALE, the shape an NFS export rebuilt underneath its
# clients produces. I/O against it errors rather than hangs, so it behaves
# like `gone` for everything that matters here, and it is the one state left
# that reaches the verdict's stat arm rather than its mount-table arm.
stat_rc_of(){
  [[ -f "$(node_dir "$1")/storage/$2.unmounted" ]] && { printf '0'; return; }
  case "$(storage_verdict_of "$1" "$2")" in
    alive) printf '0';;
    dead)  printf '124';;
    stale) printf '1';;
    *)     printf '0';;
  esac
}
mounted_of(){
  [[ -f "$(node_dir "$1")/storage/$2.unmounted" ]] && { printf '0'; return; }
  # A plain directory storage is never in the mount table, healthy or not -
  # its path is just a directory on the node's root filesystem. That is the
  # case that keeps "not mounted" from meaning "dead" on its own.
  [[ "$(cat "$(node_dir "$1")/storage/$2.type" 2>/dev/null)" == dir ]] \
    && { printf '0'; return; }
  case "$(storage_verdict_of "$1" "$2")" in
    alive|dead|stale) printf '1';;
    *)                printf '0';;
  esac
}

# The record exists in pmxcfs, so every node sees the same one. A test that let
# each node keep its own copy would pass while the real thing lost the record
# the moment the operator ran the restore from a different machine.
rec_exists(){ [[ -f "$(rec_file "$1")" ]]; }
