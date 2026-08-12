#!/usr/bin/env bash
# shellcheck shell=bash disable=SC1090,SC1091
# =============================================================================
#  ketsync doctor — the questions nobody remembers to ask, asked on a Tuesday
# -----------------------------------------------------------------------------
#  Everything here is read-only and everything here has been the cause of a
#  real incident somewhere in this fleet's history. Run it before you need it.
#
#  It finishes by running `tp doctor`, so one command covers both layers. The
#  exit code is the worse of the two: a healthy decision layer sitting on top of
#  a broken execution layer is not a healthy system.
# =============================================================================
cmd_doctor(){
  local rc=0 ip role f gen name

  echo "== this machine"
  echo "  role=$KS_ROLE  master=${KS_MASTER_IP:-<unset>}"
  [[ -n "$KS_MASTER_IP" ]] || { echo "  KS_MASTER_IP is unset - nothing knows who to receive from"; rc=1; }

  # Discovery first: everything below wants the map, and this is the one place
  # that is allowed to go and get it.
  echo "== PVE node names, from the cluster"
  if nodemap_refresh; then
    echo "  refreshed $(basename "$KS_NODEMAP") from the backup node"
  elif [[ -f "$KS_NODEMAP" ]]; then
    echo "  could not reach the cluster - using the cached $(basename "$KS_NODEMAP")"
    echo "  (that is fine for today; it is not fine for a month)"
    rc=1
  else
    echo "  could not reach the cluster and there is no cache."
    echo "  Nothing can write a guest config until this works once. Fix the ssh"
    echo "  to the backup node first - every other name in this system comes"
    echo "  from that one connection."
    rc=1
  fi

  echo "== nodes.tsv"
  if [[ ! -f "$KS_NODES" ]]; then
    echo "  missing - every address in this system comes from that file"; rc=1
  else
    while read -r ip role _; do
      [[ "$ip" =~ ^# || -z "${ip:-}" ]] && continue
      name="$(node_name "$ip")"
      printf '  %-15s %-8s %-12s ' "$ip" "${role:-?}" "${name:-<name unknown>}"
      if ks_ssh "$ip" true 2>/dev/null; then echo "ssh ok"
      elif [[ "$role" == compute ]]; then
        # Not a fault. The storage node is outside the cluster and has no key
        # to a compute node - ct-failback.sh stopped needing one when B1 moved
        # to the cluster API. Say so, so nobody goes and "fixes" it by opening
        # a path that does not need to exist.
        echo "no ssh (expected - asked through the cluster API instead)"
      else
        echo "SSH FAILS"; rc=1
      fi
    done < "$KS_NODES"
  fi

  # The one connection everything else is built on. It carries the config sync,
  # the node-name discovery, and every question ct-failback.sh asks about a
  # production CT.
  echo "== the backup node, which everything else leans on"
  ip="$(ip_of_role backup)"
  if [[ -z "$ip" ]]; then
    echo "  no row with role 'backup' in $(basename "$KS_NODES")"; rc=1
  elif ! ks_ssh "$ip" true 2>/dev/null; then
    echo "  $ip UNREACHABLE - node names cannot be discovered and a failback"
    echo "  cannot ask whether a production CT is stopped. Fix this one first."; rc=1
  else
    echo "  $ip ok  (node $(node_name "$ip" || echo '?'))"
  fi

  echo "== the files that must carry a generation"
  for f in nodes.tsv fleet.tsv engines/tp/inventory-replica.tsv engines/tp/inventory-migrate.tsv; do
    [[ -f "$KS_BASE/$f" ]] || { echo "  $f: missing"; rc=1; continue; }
    gen="$(sed -n 's/^#[[:space:]]*generation:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$KS_BASE/$f" | head -1)"
    [[ -n "$gen" ]] && echo "  $f: generation $gen" || { echo "  $f: NO generation line - sync cannot order it"; rc=1; }
  done

  # Every address written in fleet.tsv has to be one this machine knows about,
  # or a DR lands a customer somewhere nobody planned for.
  echo "== fleet.tsv addresses"
  if [[ -f "$KS_INV" ]]; then
    local ct _tier home dr bad=0
    while read -r ct _tier home dr _; do
      [[ "$ct" =~ ^# || -z "${ct:-}" ]] && continue
      for ip in "$home" "$dr"; do
        [[ -n "$ip" ]] || continue
        [[ -n "$(node_role "$ip")" ]] || { echo "  CT $ct: $ip has no row in nodes.tsv"; bad=1; }
      done
    done < "$KS_INV"
    (( bad )) && rc=1 || echo "  every home and dr address is in nodes.tsv"
  fi

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

    echo
    "$KS_BASE/engines/tp/tp" doctor || rc=1
  fi

  return $rc
}
