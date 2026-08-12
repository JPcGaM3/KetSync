#!/usr/bin/env bash
# shellcheck shell=bash disable=SC1090,SC1091
# =============================================================================
#  ketsync sync — push the fleet-wide tables to every node that has a ketsync
# -----------------------------------------------------------------------------
#  One writer, always. The machine holding the master role edits the tables;
#  everybody else receives them. That is what removes the whole class of
#  conflict-resolution problems, and it is why promotion is a decision a human
#  makes rather than a protocol - see docs/decisions.md section 2.
#
#  Each pushed file carries a generation line, and a slave handed something
#  OLDER than what it already holds refuses it, so a master that was promoted
#  by mistake and then demoted cannot walk its stale tables back over everyone.
#
#  THREE THINGS THIS GOT WRONG, all of them silent, all of them found on a real
#  fleet rather than here:
#
#  1. The remote path was assumed to be the local one. $KS_BASE is where THIS
#     machine's install lives; it was used as the destination as well, so a
#     fleet whose clones are at /root/script/KetSync and /root/github/KetSync
#     pushed into a directory that did not exist on the far side. rsync failed,
#     the run said "4 file(s) pushed", and the slave held last month's
#     inventory. The install path is now something this command CHECKS, and a
#     node that does not have one is named rather than written into the dark.
#
#  2. Every row in nodes.tsv was a target, including compute nodes, which have
#     no ketsync and are not supposed to. Four failed pushes per compute node
#     per run trains an operator to ignore the exit code, and an exit code
#     nobody reads is the same as not having one.
#
#  3. Equal generations were treated as identical files. They are not: every
#     install starts at the generation the .sample shipped with, so two
#     machines both saying "generation 1" and holding different content is the
#     NORMAL state of a fleet that has never synced - which is exactly when
#     somebody runs this for the first time. sync skipped the file, reported
#     success, and the disagreement survived every run after that. Content is
#     compared now, and a disagreement at the same generation is a FORK: it
#     stops, because which side is right is not something a tool can know.
#
#  usage:
#    ketsync sync              push
#    ketsync sync --dry-run    say what would go, send nothing
#    ketsync sync --diff       show what differs, send nothing
#    ketsync sync --bump       raise this machine's generation on the files
#                              that have forked, then push. Typing it is the
#                              human saying "my copy is the right one"
#    ketsync sync --to <ip>    one machine only
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

ks_generation(){  # $1 = file -> its generation, or empty
  sed -n 's/^#[[:space:]]*generation:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$1" 2>/dev/null | head -1
}
ks_generation_of_text(){
  sed -n 's/^#[[:space:]]*generation:[[:space:]]*\([0-9][0-9]*\).*/\1/p' <<<"$1" | head -1
}

# Everything about the far side comes through here, once per file per node.
# One round trip that answers both questions - what generation, and what
# content - because asking only the first is what let a fork hide.
ks_remote_read(){ ks_ssh "$1" "cat '$2' 2>/dev/null" 2>/dev/null; }

# Where the OTHER machine keeps its install. Not assumed to be ours: it is
# asked for, and a machine that does not answer is not written to.
ks_remote_base(){ # $1 = ip -> the base if ketsync is there, empty if not
  ks_ssh "$1" "test -f '$KS_BASE/ketsync' && echo '$KS_BASE'" 2>/dev/null
}

cmd_sync(){
  local dry=0 diff=0 bump=0 target="" f ip gen rgen n=0 bad=0 forked=0
  while (( $# )); do
    case "$1" in
      --dry-run) dry=1; shift;;
      --diff)    diff=1; shift;;
      --bump)    bump=1; shift;;
      # NOT target="$(require_node "$2")". die() exits, and an exit inside a
      # command substitution ends the SUBSHELL - the refusal would be printed
      # and then the run would carry on with an empty target, which means every
      # node. The check has to happen in this shell.
      --to)      [[ $# -ge 2 ]] || die "--to needs an IP"
                 [[ -n "$(node_role "$2")" ]] \
                   || die "$2 is not in $(basename "$KS_NODES") - add it, do not guess what it is"
                 target="$2"; shift 2;;
      *) die "unknown argument: $1";;
    esac
  done
  (( diff && bump )) && die "--diff shows, --bump changes. Read before you write."

  [[ "$KS_ROLE" == master ]] || die "this machine is '$KS_ROLE'; only the master pushes. Promote it first (ketsync role)."
  [[ -f "$KS_NODES" ]] || die "no $(basename "$KS_NODES") - there is nowhere to push to"

  hr
  log "=== sync from $(hostname) (role=$KS_ROLE)$( (( dry )) && echo ' mode=dry-run' )$( (( diff )) && echo ' mode=diff' )$( (( bump )) && echo ' mode=bump' ) ==="

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

  # ---- who can actually receive -------------------------------------------
  # A compute node has no ketsync and should not have one; a storage or backup
  # node without one is a real finding. Both are said out loud, and only the
  # second one raises the exit code.
  local -a targets=()
  for ip in $( [[ -n "$target" ]] && echo "$target" || all_node_ips ); do
    [[ "$ip" == "$KS_MASTER_IP" ]] && continue          # do not push to ourselves
    if ! ks_ssh "$ip" true 2>/dev/null; then
      log "  $ip UNREACHABLE - skipped (it will be behind until it is back)"
      bad=1; continue
    fi
    if [[ -z "$(ks_remote_base "$ip")" ]]; then
      if [[ "$(node_role "$ip")" == compute ]]; then
        log "  $ip nothing installed (expected - a compute node runs no engine)"
      else
        log "  $ip has no ketsync at $KS_BASE - NOTHING was sent there"
        log "  $ip   this machine's install path is used on the far side too, so"
        log "  $ip   every node that receives has to keep it in the same place."
        log "  $ip   move it, or clone it there:  git clone <repo> $KS_BASE"
        bad=1
      fi
      continue
    fi
    targets+=("$ip")
  done

  # ---- read the far side once, then decide --------------------------------
  local -A RTEXT=() RGEN=()
  local key
  for ip in ${targets[@]+"${targets[@]}"}; do
    for f in "${KS_SYNCED[@]}"; do
      [[ -f "$KS_BASE/$f" ]] || continue
      key="$ip|$f"
      RTEXT[$key]="$(ks_remote_read "$ip" "$KS_BASE/$f")"
      RGEN[$key]="$(ks_generation_of_text "${RTEXT[$key]}")"
      [[ -n "${RGEN[$key]}" ]] || RGEN[$key]=0
    done
  done

  # A fork is the same generation with different content. It cannot be settled
  # by pushing, because pushing is what would destroy whichever side is right.
  local -A FORK=()
  local ltext
  for f in "${KS_SYNCED[@]}"; do
    [[ -f "$KS_BASE/$f" ]] || continue
    gen="$(ks_generation "$KS_BASE/$f")"
    ltext="$(cat "$KS_BASE/$f")"
    for ip in ${targets[@]+"${targets[@]}"}; do
      key="$ip|$f"
      (( ${RGEN[$key]} == gen )) || continue
      [[ "${RTEXT[$key]}" == "$ltext" ]] && continue
      FORK[$f]=1; forked=1
      log "  $ip $f FORKED: both say generation $gen and the contents differ"
    done
  done

  if (( diff )); then
    for f in "${KS_SYNCED[@]}"; do
      [[ -f "$KS_BASE/$f" ]] || continue
      for ip in ${targets[@]+"${targets[@]}"}; do
        key="$ip|$f"
        [[ "${RTEXT[$key]}" == "$(cat "$KS_BASE/$f")" ]] && continue
        log "--- $f: here (<) against $ip (>)"
        diff <(cat "$KS_BASE/$f") <(printf '%s\n' "${RTEXT[$key]}") \
          | while IFS= read -r _l; do log "    $_l"; done
        bad=1
      done
    done
    hr
    log "=== diff finished: nothing was sent ==="
    (( bad )) && exit 1
    exit 0
  fi

  if (( forked && ! bump )); then
    hr
    log "=== sync REFUSED: $((${#FORK[@]})) file(s) have forked, and nothing was sent ==="
    log "  Two machines hold the same generation and different content, so there"
    log "  is no version to prefer. A push here would delete whichever side is"
    log "  right, and this command cannot know which that is."
    log "  see it:     ketsync sync --diff"
    log "  settle it:  edit this machine's copy until it is the one you want,"
    log "              then  ketsync sync --bump  - which raises the generation"
    log "              here and sends it. Typing --bump is you saying so."
    exit 1
  fi

  # ---- --bump: raise the generation, once, before anything is sent ---------
  if (( bump )); then
    if (( ! forked )); then
      log "  nothing has forked - --bump had nothing to raise"
    fi
    local newgen top
    for f in "${!FORK[@]}"; do
      gen="$(ks_generation "$KS_BASE/$f")"
      top="$gen"
      for ip in ${targets[@]+"${targets[@]}"}; do
        (( ${RGEN[$ip|$f]:-0} > top )) && top="${RGEN[$ip|$f]}"
      done
      newgen=$(( top + 1 ))
      sed -i.bak "s/^#[[:space:]]*generation:[[:space:]]*[0-9][0-9]*/# generation: $newgen/" "$KS_BASE/$f" \
        && rm -f "$KS_BASE/$f.bak"
      log "  $f generation $gen -> $newgen (this machine's copy is now the one)"
    done
  fi

  # ---- push ---------------------------------------------------------------
  for ip in ${targets[@]+"${targets[@]}"}; do
    for f in "${KS_SYNCED[@]}"; do
      [[ -f "$KS_BASE/$f" ]] || continue
      key="$ip|$f"
      gen="$(ks_generation "$KS_BASE/$f")"
      rgen="${RGEN[$key]}"
      if (( rgen > gen )); then
        log "  $ip $f REFUSED: it has generation $rgen, we have $gen - we are the stale one"
        bad=1; continue
      fi
      # No content compare here on purpose. Equal generations reaching this
      # point have already been through the fork check above, which is the one
      # place that decides what a disagreement means - a second copy of that
      # decision here would be unreachable, and unreachable code is where a
      # rule goes to rot without anyone noticing it stopped matching the one
      # above it.
      if (( rgen == gen )); then
        log "  $ip $f already at generation $gen"; continue
      fi
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
