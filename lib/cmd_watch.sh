#!/usr/bin/env bash
# shellcheck shell=bash disable=SC1090,SC1091
# =============================================================================
#  ketsync watch — say when the fleet's shape changes, to the right address
# -----------------------------------------------------------------------------
#  Everything else in this repo answers a person who asked. watch is for the
#  hour nobody is asking: it runs from cron on the master, looks at the same
#  sources of truth doctor reads, and mails when something CHANGES - raised
#  when a problem appears, cleared when it goes away, and silence in between.
#  Edge-triggered on purpose: a mail per cron tick about the same dead node is
#  how a mailbox trains its owner to stop reading, and an alert nobody reads
#  is a fleet nobody is watching.
#
#  Three tiers were designed and this command sends to two of them:
#
#    infra   the floor everything stands on: the backup node unreachable,
#            replication paused, a disaster's stand-ins live in the cluster
#    node    one machine's problem: a node that stops answering ssh, a
#            storage an evacuate switched off with no disaster in progress
#    ct      per-container events belong in the DAILY DIGEST (--digest mails
#            doctor's full report), not in immediate mail - and customer-side
#            ct@ alerting lives inside the customers' own containers, off the
#            tool's transport entirely
#
#  Hierarchy suppression: an infra fact explains the node facts under it.
#  While stand-ins are placed, every evacuate and isolate record is part of
#  ONE story the infra mail already told, so they are not raised separately -
#  and while the backup node is unreachable the cluster records cannot be
#  read at all, so their previous state is CARRIED, not cleared: unknown is
#  not the same as gone, which is this repo's oldest rule.
#
#  The transport is the machine's own sendmail (postfix as a satellite,
#  relaying through SendGrid - contrib/mail-satellite.sh sets that up). This
#  command never sees an API key; the day the provider changes, the tool does
#  not.
#
#  The watcher itself is watched, twice over.
#
#  A green run pings KS_WATCH_HEALTHCHECK (healthchecks.io style), and ONLY a
#  green run - a run whose mail failed exits red, does not ping, does not mark
#  its events delivered, and the missing ping is what raises the alarm about
#  the alarm. That is also why a failed send must never update the state file:
#  edge-triggered means an event swallowed once is an event swallowed forever.
#  The ping is the only cover that survives the whole site going dark, and it
#  is external on purpose.
#
#  And a SLAVE may run watch too, with exactly one question in it: does the
#  master answer. The machine that reports the fleet cannot report its own
#  death - when the storage node dies, the watcher dies with it and every
#  check above stops running, silently. So the backup node asks that one
#  question and mails it INFRA. The two scopes do not overlap by design: the
#  master never says "the master is gone", the slave says nothing else, and
#  the objection this used to carry - two half-tuned alert streams - does not
#  apply to a stream with one event in it.
# =============================================================================
cmd_watch(){
  local dry=0 list=0 digest=0 a
  for a in "$@"; do
    case "$a" in
      --dry-run) dry=1;;
      --list)    list=1;;
      --digest)  digest=1;;
      *) say "watch: unknown argument '$a'"; return 2;;
    esac
  done

  # Which watch this is. A master watches the FLEET; a slave watches the
  # MASTER, and nothing else - see the header. A machine with no role at all
  # is neither, and guessing which it meant to be is how a fleet ends up with
  # two full watchers or none.
  local slave=0
  case "${KS_ROLE:-}" in
    master) ;;
    slave)  slave=1;;
    *) say "refused: KS_ROLE is '${KS_ROLE:-unset}' - watch runs on a master (the"
       say "  whole fleet) or on a slave (one question: does the master answer)."
       say "  set it in $(basename "$KS_CONF"); nothing here guesses a role."
       return 2;;
  esac
  if (( slave && digest )); then
    say "refused: --digest mails doctor's whole report, and doctor's answers are"
    say "  the master's - from here they would describe this machine's view and"
    say "  read like the fleet's. A slave watch has one question in it."
    return 2
  fi

  # No address, no run. A watch that cannot say what it saw is a state file
  # quietly going stale while everybody believes the fleet is watched.
  if (( digest )); then
    if [[ -z "${KS_MAIL_FROM:-}" || -z "${KS_MAIL_DIGEST:-}" ]]; then
      say "refused: KS_MAIL_FROM and KS_MAIL_DIGEST must be set in $(basename "$KS_CONF")."
      say "  the digest is a mail; without an address it is nothing at all."
      return 2
    fi
  elif (( slave )); then
    # A slave mails one INFRA fact and never a NODE one, so KS_MAIL_NODE is
    # not its business - requiring it would make an operator invent an address
    # for mail this machine will never send.
    if [[ -z "${KS_MAIL_FROM:-}" || -z "${KS_MAIL_INFRA:-}" ]]; then
      say "refused: KS_MAIL_FROM and KS_MAIL_INFRA must be set in $(basename "$KS_CONF")."
      say "  a slave watch mails one thing - the master does not answer - and that"
      say "  is an INFRA fact. Without an address it is a machine watching silently."
      return 2
    fi
  elif (( ! list )); then
    if [[ -z "${KS_MAIL_FROM:-}" || -z "${KS_MAIL_INFRA:-}" || -z "${KS_MAIL_NODE:-}" ]]; then
      say "refused: KS_MAIL_FROM, KS_MAIL_INFRA and KS_MAIL_NODE must be set in $(basename "$KS_CONF")."
      say "  see conf/ketsync.conf.sample - the tiers are addresses, and a watch"
      say "  with no address is a fleet nobody is actually watching."
      return 2
    fi
  fi
  if (( ! dry && ! list )); then
    command -v sendmail >/dev/null || {
      say "refused: no sendmail on this machine - install postfix as a satellite"
      say "  (contrib/mail-satellite.sh) before pointing cron at watch."
      return 2; }
    if [[ -n "${KS_WATCH_HEALTHCHECK:-}" ]] && ! command -v curl >/dev/null; then
      say "refused: KS_WATCH_HEALTHCHECK is set but there is no curl to ping it with."
      say "  a dead-man that is never pinged alarms forever; install curl or unset the key."
      return 2
    fi
  fi

  send_mail(){   # $1 = to, $2 = subject, $3 = body -> 0 sent, 1 not
    if (( dry )); then
      log "DRY: would mail $1: $2"
      return 0
    fi
    {
      printf 'From: %s\n' "$KS_MAIL_FROM"
      printf 'To: %s\n' "$1"
      printf 'Subject: %s\n' "$2"
      printf 'Content-Type: text/plain; charset=UTF-8\n'
      printf '\n%s\n' "$3"
    } | sendmail -t -i -f "$KS_MAIL_FROM"
  }
  # -f sets the ENVELOPE sender, which is what relays actually validate; the
  # From: header alone leaves the envelope as root@<hostname>, an address no
  # provider has verified - Brevo rejected exactly that on this fleet.

  # ---- the daily digest: doctor's whole report, mailed ----------------------
  # Per-container events live here by design: a copy one day stale is not a
  # 03:00 page, and doctor already says everything watch would repeat.
  if (( digest )); then
    hr
    log "=== $(hostname 2>/dev/null || echo '?') watch mode=digest$( ((dry)) && echo /dry-run ) ==="
    local dout drc
    dout="$("$KS_BASE/ketsync" doctor 2>&1)"; drc=$?
    if send_mail "$KS_MAIL_DIGEST" \
        "[ketsync] daily digest: doctor exit $drc on $(hostname 2>/dev/null || echo '?')" \
        "$dout"; then
      log "digest mailed to $KS_MAIL_DIGEST (doctor exit $drc)"
      return 0
    fi
    log "ERROR: the digest mail did not go out - doctor itself exited $drc"
    return 1
  fi

  local STATE="$KS_BASE/state/watch.tsv"

  # ---- --list: what watch is currently standing on, read-only ---------------
  if (( list )); then
    say "== watch --list: the events currently raised (mailed once, not cleared yet)"
    if [[ ! -s "$STATE" ]]; then
      say "  none - the last run saw a fleet with nothing raised (or watch has never run)"
      return 0
    fi
    local k t s x
    while IFS=$'\t' read -r k t s x; do
      [[ -n "$k" ]] && say "  $t  $k  since $s  - $x"
    done < "$STATE"
    return 0
  fi

  hr
  log "=== $(hostname 2>/dev/null || echo '?') watch mode=$( ((dry)) && echo dry-run || echo check ) scope=$( ((slave)) && echo master-only || echo fleet ) ==="

  # ---- what is true right now ------------------------------------------------
  declare -A NOWT=() NOWX=()
  add_event(){ NOWT["$1"]="$2"; NOWX["$1"]="$3"; }   # key, tier, text

  local cluster_unknown=0 nine="" evacn="" isol=""

  if (( slave )); then
    # The one question, asked properly. A single failed ssh is a blip as often
    # as it is a dead machine, and this key raises the loudest mail this tool
    # sends - so it is asked again before it is believed. Bounded, and the
    # knobs exist for the simulator, which must not sit through real waits.
    local mip="${KS_MASTER_IP:-}"
    if [[ -z "$mip" ]]; then
      say "ERROR: KS_MASTER_IP is unset in $(basename "$KS_CONF") - a slave watch has"
      say "ERROR:   nothing to watch. It is the one address this machine must know."
      return 2
    fi
    local tries="${KS_MASTER_TRIES:-3}" gap="${KS_MASTER_GAP:-5}" try=0 up=0
    while (( try < tries )); do
      if ks_ssh "$mip" true 2>/dev/null; then up=1; break; fi
      try=$((try+1))
      (( try < tries )) && sleep "$gap"
    done
    (( up )) || add_event master-unreachable INFRA \
      "the master ($mip) did not answer ssh in $tries tries over ~$(( (tries-1) * gap ))s. This mail comes from the BACKUP node, because the master cannot report its own death - and while it is gone nothing is watching the rest of the fleet. If the storage node is really down, the DR is driven from here:  ketsync distribute --all  (it evacuates and isolates first). See docs 05-disaster-day."
  else

    local bkp; bkp="$(ip_of_role backup)"
    [[ -n "$bkp" ]] || { say "ERROR: no backup node in $(basename "$KS_NODES") - cannot read the cluster"; return 2; }

    local PAUSE="$KS_BASE/engines/PAUSE"
    [[ -f "$PAUSE" ]] && add_event pause INFRA \
      "replication is paused ($PAUSE exists) - a failback is in progress, or a finished one was never unpaused. Every DR copy ages while this file exists."

    if ! ks_ssh "$bkp" true 2>/dev/null; then
      cluster_unknown=1
      add_event backup-unreachable INFRA \
        "the backup node ($bkp) does not answer ssh. Every DR copy, every cluster record and every recovery path goes through it."
    fi

    local ip role
    while IFS=$'\t' read -r ip role; do
      [[ -n "$ip" && "$ip" != "$bkp" ]] || continue
      ks_ssh "$ip" true 2>/dev/null || add_event "node-unreachable:$ip" NODE \
        "node $ip ($role) does not answer ssh."
    done < <(awk -F'\t' '$1!~/^#/ && NF>=2 {print $1"\t"$2}' "$KS_NODES")

    # ---- the cluster's own records, read through the backup node ---------------
    # Suppression lives here. Stand-ins placed is ONE infra fact that explains
    # every evacuate and isolate record under it; and an unreadable cluster
    # CARRIES its previous answers rather than clearing them - watch must never
    # mail "recovered" about a thing it merely lost sight of.
    if (( ! cluster_unknown )); then
      nine="$(ks_ssh "$bkp" "ls /etc/pve/nodes/*/lxc/9*.conf 2>/dev/null" \
              | sed 's|.*/||; s/\.conf$//' | sort -n | tr '\n' ' ')"
      nine="${nine% }"
      evacn="$(ks_ssh "$bkp" "ls /etc/pve/ketsync/evacuate/ 2>/dev/null" | sed 's/\.tsv$//')"
      isol="$(ks_ssh "$bkp" "ls /etc/pve/ketsync/isolate/ 2>/dev/null" | sed 's/\.tsv$//')"
      if [[ -n "$nine" ]]; then
        add_event dr-standins INFRA \
          "stand-ins are placed: $nine. A disaster is in progress, or its cleanup is unfinished - replication for those containers is held by R13 until each 9<id> is destroyed."
      else
        local n
        for n in $evacn; do
          add_event "evacuated:$n" NODE \
            "storages on $n are still disabled by an evacuate and no stand-in is placed. When the storage is back:  ketsync restore --node <ip>"
        done
        for n in $isol; do
          add_event "isolated:$n" NODE \
            "CT $n is on the isolation bridge with no stand-in placed - off the wire and nothing answering for it. Put it back:  ketsync restore --ctid $n"
        done
      fi
    fi

  fi   # end of the master's fleet-wide checks

  # ---- what the last run knew ------------------------------------------------
  declare -A OLDT=() OLDX=() OLDS=()
  local k t s x
  if [[ -s "$STATE" ]]; then
    while IFS=$'\t' read -r k t s x; do
      [[ -n "$k" ]] || continue
      OLDT["$k"]="$t"; OLDS["$k"]="$s"; OLDX["$k"]="$x"
    done < "$STATE"
  fi

  # Carry what could not be read: unknown is not gone. While the cluster is
  # unreadable every record-derived key keeps its previous answer, and while
  # stand-ins are placed the suppressed evacuate/isolate keys do too - they
  # were not cleared, they were explained.
  for k in "${!OLDT[@]}"; do
    case "$k" in
      dr-standins|evacuated:*|isolated:*)
        if (( cluster_unknown )) || { [[ -n "$nine" && "$k" != dr-standins ]]; }; then
          [[ -n "${NOWT[$k]:-}" ]] || { NOWT["$k"]="${OLDT[$k]}"; NOWX["$k"]="${OLDX[$k]}"; }
        fi;;
    esac
  done

  # ---- the edge: raised and cleared, one mail per tier -----------------------
  local now_date; now_date="$(date '+%F %T')"
  local -A RAISED=() CLEARED=()
  for k in "${!NOWT[@]}"; do [[ -n "${OLDT[$k]:-}" ]] || RAISED["$k"]=1; done
  for k in "${!OLDT[@]}"; do [[ -n "${NOWT[$k]:-}" ]] || CLEARED["$k"]=1; done

  local sendfail=0 tier addr
  for tier in INFRA NODE; do
    local rl="" cl="" nr=0 nc=0
    for k in "${!RAISED[@]}"; do
      [[ "${NOWT[$k]}" == "$tier" ]] || continue
      rl+="  $k"$'\n'"      ${NOWX[$k]}"$'\n'; nr=$((nr+1))
      log "RAISED $tier $k"
    done
    for k in "${!CLEARED[@]}"; do
      [[ "${OLDT[$k]}" == "$tier" ]] || continue
      cl+="  $k (was raised ${OLDS[$k]})"$'\n'; nc=$((nc+1))
      log "CLEARED $tier $k"
    done
    (( nr + nc )) || continue
    addr="$KS_MAIL_NODE"; [[ "$tier" == INFRA ]] && addr="$KS_MAIL_INFRA"
    local body
    body="watch on $(hostname 2>/dev/null || echo '?'), $now_date"$'\n'
    [[ -n "$rl" ]] && body+=$'\n'"RAISED"$'\n'"$rl"
    [[ -n "$cl" ]] && body+=$'\n'"CLEARED"$'\n'"$cl"
    if ! send_mail "$addr" "[ketsync] $tier: $nr raised, $nc cleared - $(hostname 2>/dev/null || echo '?')" "$body"; then
      log "ERROR: mail to $addr did not go out - nothing is marked delivered, every"
      log "ERROR:   event above raises again next run, and the missing dead-man ping"
      log "ERROR:   is what tells somebody the alerting itself is down."
      sendfail=1
    fi
  done
  (( ${#RAISED[@]} + ${#CLEARED[@]} )) || log "no change - the fleet looks the way it looked last run"

  # ---- remember, ping, exit --------------------------------------------------
  # State is written only when every mail went out, and the dead-man is pinged
  # only then too: delivered-and-remembered or neither.
  if (( ! dry && ! sendfail )); then
    mkdir -p "$KS_BASE/state"
    : > "$STATE"
    for k in "${!NOWT[@]}"; do
      s="${OLDS[$k]:-$now_date}"
      printf '%s\t%s\t%s\t%s\n' "$k" "${NOWT[$k]}" "$s" "${NOWX[$k]}" >> "$STATE"
    done
    if [[ -n "${KS_WATCH_HEALTHCHECK:-}" ]]; then
      curl -fsS -m 10 -o /dev/null "$KS_WATCH_HEALTHCHECK" \
        || log "healthcheck ping failed - healthchecks.io will read that as silence"
    fi
  fi
  (( dry )) && log "dry-run - no mail was sent, nothing was remembered, nothing was pinged"
  return $sendfail
}
