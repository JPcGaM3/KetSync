#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034,SC1090,SC1091
# =============================================================================
#  common.sh — log, config, and the two tables everything reads.
#  Sourced, never executed. KS_BASE is set by the dispatcher.
# =============================================================================
KS_LOGDIR="$KS_BASE/logs"
KS_LOG="$KS_LOGDIR/ketsync-$(date +%F).log"
mkdir -p "$KS_LOGDIR" 2>/dev/null

log(){ printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$KS_LOG"; }
hr(){  printf '%s\n' "##############################################################################" | tee -a "$KS_LOG"; }
die(){ log "ERROR: $*"; exit 2; }

# ---------- config -----------------------------------------------------------
# Defaults live here so the sample config can stay short; a value in the file
# always wins. Same split as tp's ctmig.conf / ctrep.conf, for the same reason:
# re-delivering the code must never overwrite a calibrated value.
KS_ROLE=slave                 # master | slave. Changed by hand. See section 2.
KS_MASTER_IP=""               # the machine that owns the inventory
KS_SSH_OPTS="-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"
KS_CONF="$KS_BASE/ketsync.conf"
KS_NODES="$KS_BASE/nodes.tsv"
KS_INV="$KS_BASE/inventory.tsv"
# these are read by the cmd_* files that source this one
[[ -f "$KS_CONF" ]] && . "$KS_CONF"

# ---------- nodes.tsv --------------------------------------------------------
# The ONLY place a PVE node name becomes an address. PVE stores configs under
# /etc/pve/nodes/<name>/, so the name is unavoidable; resolving it is not this
# machine's business, and it is outside the cluster so it has neither the
# cluster's /etc/hosts nor its DNS. One table, checked in, edited by hand.
#
#   <name> <TAB> <ip> <TAB> <role>      role: storage | compute | backup
node_ip(){      awk -v n="$1" '$1!~/^#/ && $1==n{print $2; exit}' "$KS_NODES" 2>/dev/null; }
node_role(){    awk -v n="$1" '$1!~/^#/ && $1==n{print $3; exit}' "$KS_NODES" 2>/dev/null; }
nodes_of_role(){ awk -v r="$1" '$1!~/^#/ && $3==r{print $2}'      "$KS_NODES" 2>/dev/null; }
all_node_ips(){ awk '$1!~/^#/ && NF>=2{print $2}'                 "$KS_NODES" 2>/dev/null; }

# A name with no row is a hard stop, never a guess. Guessing an address puts a
# customer's rootfs on a machine nobody meant.
require_ip(){   # $1 = node name -> its ip, or refuse
  local ip; ip="$(node_ip "$1")"
  [[ -n "$ip" ]] || die "node '$1' is not in $(basename "$KS_NODES") - add it, do not guess its address"
  printf '%s' "$ip"
}

ks_ssh(){ ssh $KS_SSH_OPTS "root@$1" "${@:2}" </dev/null; }
