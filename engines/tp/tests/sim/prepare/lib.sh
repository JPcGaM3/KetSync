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
#    $SIMROOT/pve/ketsync/isolate-<id>.tsv     the record - pmxcfs, so ONE copy
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
rec_file(){ printf '%s/pve/ketsync/isolate-%s.tsv' "$SIMROOT" "$1"; }

# alive | dead | gone, as the WORD a scenario set - not a boolean, because the
# engine distinguishes three cases and a boolean would let two of them collapse
# into one without any test noticing.
storage_verdict_of(){ cat "$(node_dir "$1")/storage/$2.verdict" 2>/dev/null; }

# What `timeout N stat` would exit with, which is what the engine actually
# reads. A live mount answers (0), a dead one blocks until timeout kills it
# (124), and a mountpoint nobody mounted is simply not there (1).
stat_rc_of(){
  case "$(storage_verdict_of "$1" "$2")" in
    alive) printf '0';;
    dead)  printf '124';;
    *)     printf '1';;
  esac
}

# The record exists in pmxcfs, so every node sees the same one. A test that let
# each node keep its own copy would pass while the real thing lost the record
# the moment the operator ran the restore from a different machine.
rec_exists(){ [[ -f "$(rec_file "$1")" ]]; }
