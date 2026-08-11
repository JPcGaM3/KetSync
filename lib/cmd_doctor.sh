#!/usr/bin/env bash
# shellcheck shell=bash disable=SC1090,SC1091
# =============================================================================
#  ketsync doctor — the questions nobody remembers to ask, asked on a Tuesday
# -----------------------------------------------------------------------------
#  Everything here is read-only and everything here has been the cause of a
#  real incident somewhere in this fleet's history. Run it before you need it.
# =============================================================================
cmd_doctor(){
  local rc=0 ip name role f gen

  echo "== this machine"
  echo "  role=$KS_ROLE  master=${KS_MASTER_IP:-<unset>}"
  [[ -n "$KS_MASTER_IP" ]] || { echo "  KS_MASTER_IP is unset - nothing knows who to receive from"; rc=1; }

  echo "== nodes.tsv"
  if [[ ! -f "$KS_NODES" ]]; then
    echo "  missing - every address in this system comes from that file"; rc=1
  else
    while read -r name ip role _; do
      [[ "$name" =~ ^# || -z "${name:-}" ]] && continue
      printf '  %-16s %-15s %-8s ' "$name" "$ip" "${role:-?}"
      if ks_ssh "$ip" true 2>/dev/null; then echo "ssh ok"; else echo "SSH FAILS"; rc=1; fi
    done < "$KS_NODES"
  fi

  echo "== ssh to every compute node"
  # The one that stopped a real failback: this machine is outside the cluster,
  # so it has neither the cluster's hosts file nor its keys, and nothing said
  # that a failback needs root ssh to every compute node until the day it did.
  for ip in $(nodes_of_role compute); do
    if ks_ssh "$ip" true 2>/dev/null; then echo "  $ip ok"
    else echo "  $ip UNREACHABLE - a failback of anything living there would refuse at GUARD B1"; rc=1; fi
  done

  echo "== the files that must carry a generation"
  for f in ketsync.conf nodes.tsv fleet.tsv; do
    [[ -f "$KS_BASE/$f" ]] || { echo "  $f: missing"; rc=1; continue; }
    gen="$(sed -n 's/^#[[:space:]]*generation:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$KS_BASE/$f" | head -1)"
    [[ -n "$gen" ]] && echo "  $f: generation $gen" || { echo "  $f: NO generation line - sync cannot order it"; rc=1; }
  done

  echo "== the engines"
  if [[ ! -f "$KS_BASE/engines/tp/tp" ]]; then
    echo "  engines/tp is missing - ketsync decides, tp does. Nothing can run."; rc=1
  else
    # Not "does the file exist" but "can cron actually run it". A checkout that
    # crossed a filesystem which drops the mode bit - a network share, a FUSE
    # mount, an unzip on Windows - leaves every one of these readable and not
    # executable, and the first anybody hears of it is exit 126 at 02:00.
    for f in tp ct-migrate.sh ct-replica.sh ct-failback.sh; do
      if [[ -x "$KS_BASE/engines/tp/$f" ]]; then echo "  $f ok"
      else echo "  $f is NOT EXECUTABLE - cron would exit 126. chmod +x engines/tp/$f"; rc=1; fi
    done
  fi

  return $rc
}
