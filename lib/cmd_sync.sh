#!/usr/bin/env bash
# shellcheck shell=bash disable=SC1090,SC1091
# =============================================================================
#  ketsync sync — push the config and the inventory to every node in nodes.tsv
# -----------------------------------------------------------------------------
#  One writer, always. The machine holding the master role edits the inventory;
#  everybody else receives it. That is what removes the whole class of conflict
#  resolution problems, and it is why promotion is a decision a human makes
#  rather than a protocol - see docs/decisions.md section 2.
#
#  Each pushed file carries a generation line. A slave that is handed something
#  OLDER than what it already has refuses it, so a master that was promoted by
#  mistake and then demoted cannot walk its stale inventory back over everyone.
# =============================================================================
KS_SYNCED=(ketsync.conf nodes.tsv inventory.tsv)

ks_generation(){  # $1 = file -> its generation, or 0
  sed -n 's/^#[[:space:]]*generation:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$1" 2>/dev/null | head -1
}

cmd_sync(){
  local dry=0 target="" f ip gen rgen n=0 bad=0
  while (( $# )); do
    case "$1" in
      --dry-run) dry=1; shift;;
      --to)      [[ $# -ge 2 ]] || die "--to needs an IP"; target="$2"; shift 2;;
      *) die "unknown argument: $1";;
    esac
  done

  [[ "$KS_ROLE" == master ]] || die "this machine is '$KS_ROLE'; only the master pushes. Promote it first (ketsync role)."
  [[ -f "$KS_NODES" ]] || die "no $(basename "$KS_NODES") - there is nowhere to push to"

  hr
  log "=== sync from $(hostname) (role=$KS_ROLE)$( (( dry )) && echo ' mode=dry-run' ) ==="

  for f in "${KS_SYNCED[@]}"; do
    [[ -f "$KS_BASE/$f" ]] || { log "WARN: $f does not exist here - not pushing it"; continue; }
    gen="$(ks_generation "$KS_BASE/$f")"
    [[ -n "$gen" ]] || { log "ERROR: $f has no '# generation: N' line - refusing to push a file nobody can order"; bad=1; }
  done
  (( bad )) && exit 2

  for ip in $( [[ -n "$target" ]] && echo "$target" || all_node_ips ); do
    [[ "$ip" == "$KS_MASTER_IP" ]] && continue          # do not push to ourselves
    if ! ks_ssh "$ip" true 2>/dev/null; then
      log "  $ip UNREACHABLE - skipped (it will be behind until it is back)"
      bad=1; continue
    fi
    for f in "${KS_SYNCED[@]}"; do
      [[ -f "$KS_BASE/$f" ]] || continue
      gen="$(ks_generation "$KS_BASE/$f")"
      rgen="$(ks_ssh "$ip" "sed -n 's/^#[[:space:]]*generation:[[:space:]]*\\([0-9][0-9]*\\).*/\\1/p' '$KS_BASE/$f' 2>/dev/null | head -1")"
      rgen="${rgen:-0}"
      if (( rgen > gen )); then
        log "  $ip $f REFUSED: it has generation $rgen, we have $gen - we are the stale one"
        bad=1; continue
      fi
      if (( rgen == gen )); then log "  $ip $f already at generation $gen"; continue; fi
      if (( dry )); then log "  $ip $f would go from generation $rgen to $gen"; n=$(( n + 1 )); continue; fi
      if rsync -a -e "ssh $KS_SSH_OPTS" "$KS_BASE/$f" "root@$ip:$KS_BASE/$f" >>"$KS_LOG" 2>&1; then
        log "  $ip $f generation $rgen -> $gen"
        n=$(( n + 1 ))
      else
        log "  $ip $f PUSH FAILED - see the log"
        bad=1
      fi
    done
  done

  hr
  log "=== sync finished: $n file(s) pushed$( (( dry )) && echo ' (dry-run: none really were)' ) ==="
  (( bad )) && exit 1
  exit 0
}
