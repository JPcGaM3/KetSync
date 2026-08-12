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

  say "== this machine"
  say "  role=$KS_ROLE  master=${KS_MASTER_IP:-<unset>}"
  [[ -n "$KS_MASTER_IP" ]] || { say "  KS_MASTER_IP is unset - nothing knows who to receive from"; rc=1; }

  # Discovery first: everything below wants the map, and this is the one place
  # that is allowed to go and get it.
  say "== PVE node names, from the cluster"
  if nodemap_refresh; then
    say "  refreshed $(basename "$KS_NODEMAP") from the backup node"
  elif [[ -f "$KS_NODEMAP" ]]; then
    say "  could not reach the cluster - using the cached $(basename "$KS_NODEMAP")"
    say "  (that is fine for today; it is not fine for a month)"
    rc=1
  else
    say "  could not reach the cluster and there is no cache."
    say "  Nothing can write a guest config until this works once. Fix the ssh"
    say "  to the backup node first - every other name in this system comes"
    say "  from that one connection."
    rc=1
  fi

  say "== nodes.tsv"
  if [[ ! -f "$KS_NODES" ]]; then
    say "  missing - every address in this system comes from that file"; rc=1
  else
    local row verdict
    while read -r ip role _; do
      [[ "$ip" =~ ^# || -z "${ip:-}" ]] && continue
      name="$(node_name "$ip")"
      # Composed, not printf'd in two halves. Half a line on the screen and the
      # other half in the log is a log that says "SSH FAILS" without saying
      # which machine, which is worth nothing at all a week later.
      row="$(printf '  %-15s %-8s %-12s' "$ip" "${role:-?}" "${name:-<name unknown>}")"
      if ks_ssh "$ip" true 2>/dev/null; then verdict="ssh ok"
      elif [[ "$role" == compute ]]; then
        # Not a fault. The storage node is outside the cluster and has no key
        # to a compute node - ct-failback.sh stopped needing one when B1 moved
        # to the cluster API. Say so, so nobody goes and "fixes" it by opening
        # a path that does not need to exist.
        verdict="no ssh (expected - asked through the cluster API instead)"
      else
        verdict="SSH FAILS"; rc=1
      fi
      say "$row $verdict"
    done < "$KS_NODES"
  fi

  # The one connection everything else is built on. It carries the config sync,
  # the node-name discovery, and every question ct-failback.sh asks about a
  # production CT.
  say "== the backup node, which everything else leans on"
  ip="$(ip_of_role backup)"
  if [[ -z "$ip" ]]; then
    say "  no row with role 'backup' in $(basename "$KS_NODES")"; rc=1
  elif ! ks_ssh "$ip" true 2>/dev/null; then
    say "  $ip UNREACHABLE - node names cannot be discovered and a failback"
    say "  cannot ask whether a production CT is stopped. Fix this one first."; rc=1
  else
    say "  $ip ok  (node $(node_name "$ip" || echo '?'))"
  fi

  say "== the files that must carry a generation"
  for f in nodes.tsv fleet.tsv engines/tp/inventory-replica.tsv engines/tp/inventory-migrate.tsv; do
    [[ -f "$KS_BASE/$f" ]] || { say "  $f: missing"; rc=1; continue; }
    gen="$(sed -n 's/^#[[:space:]]*generation:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$KS_BASE/$f" | head -1)"
    [[ -n "$gen" ]] && say "  $f: generation $gen" || { say "  $f: NO generation line - sync cannot order it"; rc=1; }
  done

  # Every address written in fleet.tsv has to be one this machine knows about,
  # or a DR lands a customer somewhere nobody planned for.
  say "== fleet.tsv addresses"
  if [[ -f "$KS_INV" ]]; then
    local ct _tier home dr bad=0
    while read -r ct _tier home dr _; do
      [[ "$ct" =~ ^# || -z "${ct:-}" ]] && continue
      for ip in "$home" "$dr"; do
        [[ -n "$ip" ]] || continue
        [[ -n "$(node_role "$ip")" ]] || { say "  CT $ct: $ip has no row in nodes.tsv"; bad=1; }
      done
    done < "$KS_INV"
    (( bad )) && rc=1 || say "  every home and dr address is in nodes.tsv"
  fi

  # There is no mirror any more, and a leftover one is worth naming: it is not
  # read, but somebody will find it during an incident and believe it.
  for f in fleet.tsv nodes.map; do
    [[ -e "$KS_BASE/engines/tp/$f" ]] \
      && say "  engines/tp/$f is a LEFTOVER from the old mirror - nothing reads it, delete it"
  done

  say "== the engines"
  if [[ ! -f "$KS_BASE/engines/tp/tp" ]]; then
    say "  engines/tp is missing - ketsync decides, tp does. Nothing can run."; rc=1
  else
    # Not "does the file exist" but "can cron actually run it". A checkout that
    # crossed a filesystem which drops the mode bit - a network share, a FUSE
    # mount, an unzip on Windows - leaves every one of these readable and not
    # executable, and the first anybody hears of it is exit 126 at 02:00.
    # ct-distribute.sh was missing from this list, which meant the one engine
    # you reach for while the storage node is dead was the one nobody checked
    # was runnable.
    for f in tp ct-migrate.sh ct-replica.sh ct-failback.sh ct-distribute.sh; do
      if [[ -x "$KS_BASE/engines/tp/$f" ]]; then say "  $f ok"
      else say "  $f is NOT EXECUTABLE - cron would exit 126. chmod +x engines/tp/$f"; rc=1; fi
    done

    echo
    "$KS_BASE/engines/tp/tp" doctor || rc=1
  fi

  return $rc
}
