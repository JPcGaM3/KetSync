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
# FLEET-WIDE files only: the same bytes are correct on every machine.
#
# ketsync.conf is deliberately NOT here and must never be added. It carries
# KS_ROLE, which is the one line that has to differ per machine - pushing the
# master's copy sets every node to KS_ROLE=master, and then every node believes
# it may write. That is the split brain this whole design exists to avoid, and
# it was live in this file until somebody read it out loud.
#
# The engines' inventories ARE here: they are the fleet's work lists, they are
# what a machine taking over needs, and a backup node holding a stale one is a
# backup node that replicates the wrong containers. ctrep.conf and ctmig.conf
# are not - they mix fleet-wide tuning with per-machine addresses (BKP_SSH is
# "the other machine", which is a different machine depending on who is asking),
# and splitting them is a separate job.
KS_SYNCED=(nodes.tsv fleet.tsv
           engines/tp/inventory-replica.tsv
           engines/tp/inventory-migrate.tsv)

# A denylist rather than a comment, because the comment above is exactly the
# kind of thing that gets skimmed. Anything per-machine that reaches KS_SYNCED
# stops the run instead of overwriting a role.
KS_NEVER_SYNC=(ketsync.conf ctrep.conf ctmig.conf nodes.map)

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

  local n2
  for f in "${KS_SYNCED[@]}"; do
    for n2 in "${KS_NEVER_SYNC[@]}"; do
      [[ "$(basename "$f")" == "$n2" ]] || continue
      log "ERROR: $f is a PER-MACHINE file and must not be pushed - NOTHING was sent"
      log "ERROR:   $n2 differs on every machine by design. Pushing it makes every"
      log "ERROR:   node agree about something that is only true of one of them."
      exit 2
    done
  done

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
