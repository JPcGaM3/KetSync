#!/usr/bin/env bash
# =============================================================================
#  run-sim-watch.sh — execute `ketsync watch` against a fake fleet and a fake
#  mail system.
# -----------------------------------------------------------------------------
#  watch is the one command whose OUTPUT is not for the person running it: it
#  is a mail arriving at three in the morning, and everything that can go
#  wrong with it is invisible on a terminal. What this suite pins down:
#
#    - edge-triggering: a standing problem mails ONCE, and mails again only
#      when it clears. A watcher that repeats itself gets its mail filtered,
#      and a filtered alert is no alert
#    - tiering: infra facts go to the infra address, node facts to the node
#      address. A page sent to the wrong person is a page nobody acts on
#    - hierarchy suppression: while stand-ins are placed, the evacuate and
#      isolate records under them are ONE story, already told
#    - unknown is not gone: an unreadable cluster CARRIES its previous
#      answers. "recovered" about a thing merely lost sight of is the most
#      expensive false positive this tool could send
#    - delivered-and-remembered or neither: a failed send leaves the state
#      file alone, exits red, and does not ping the dead-man - the silence IS
#      the alert about the alerting
#
#  sendmail and curl are shell functions recording into the sandbox; the
#  cluster is the same fake-ssh arrangement every other suite here uses.
#
#  usage:  ./tests/sim/watch/run-sim-watch.sh          every scenario
#          ./tests/sim/watch/run-sim-watch.sh 7        scenario 7 only
#          KEEP=1 ./tests/sim/watch/run-sim-watch.sh 7 keep the sandbox
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
KS="${KS:-$ROOT/ketsync}"

if [[ ! -f "$KS" ]]; then
  echo "ketsync not found: $KS" >&2; exit 2
elif [[ ! -x "$KS" ]]; then
  echo "ketsync is not executable: $KS" >&2; exit 2
fi
ONLY="${1:-}"
PASS=0; FAIL=0; FAILED_NAMES=()
ME=10.100.1.17
BKP=10.100.1.9
N1=10.100.1.32
N2=10.100.1.33

new_world(){
  SIMROOT="$(mktemp -d /tmp/kswatch-sim.XXXXXX)"
  MASTER="$SIMROOT/master"
  PVE="$SIMROOT/pve"
  mkdir -p "$MASTER/lib" "$MASTER/conf" "$MASTER/engines" "$MASTER/logs" \
           "$PVE/ketsync/evacuate" "$PVE/ketsync/isolate" \
           "$PVE/nodes/pve-r32/lxc" "$PVE/nodes/pve-r33/lxc"
  : > "$SIMROOT/trace"
  : > "$SIMROOT/pings"
  local ksdir; ksdir="$(cd "$(dirname "$KS")" && pwd)"
  cp "$KS" "$MASTER/ketsync"; chmod +x "$MASTER/ketsync"
  cp "$ksdir"/lib/*.sh "$MASTER/lib/"
  cat > "$MASTER/conf/ketsync.conf" <<CONF
KS_ROLE=master
KS_MASTER_IP=$ME
KS_MAIL_FROM=ketsync@sim
KS_MAIL_INFRA=infra@sim
KS_MAIL_NODE=node@sim
KS_MAIL_DIGEST=digest@sim
KS_WATCH_HEALTHCHECK=https://hc.sim/ping
CONF
  printf '# generation: 1\n%s\tstorage\n%s\tbackup\n%s\tcompute\n%s\tcompute\n' \
    "$ME" "$BKP" "$N1" "$N2" > "$MASTER/conf/nodes.tsv"
  printf '%s\tpbs-r09\n%s\tpve-r32\n%s\tpve-r33\n' "$BKP" "$N1" "$N2" > "$MASTER/conf/nodes.map"
  printf '# generation: 1\n110\t%s\t%s\tlocal-lvm\n120\t%s\t%s\tlocal-lvm\n' \
    "$N1" "$N1" "$N2" "$N2" > "$MASTER/conf/fleet.tsv"
}

# ---------- world knobs ----------
host_down(){     : > "$SIMROOT/down.$1"; }
host_up(){       rm -f "$SIMROOT/down.$1"; }
place_nine(){    printf 'x\n' > "$PVE/nodes/$2/lxc/9$1.conf"; }   # ct, node name
evac_rec(){      printf 'x\n' > "$PVE/ketsync/evacuate/$1.tsv"; }
iso_rec(){       printf 'x\n' > "$PVE/ketsync/isolate/$1.tsv"; }
pause_on(){      : > "$MASTER/engines/PAUSE"; }
sendmail_fails(){ printf '1\n' > "$SIMROOT/rc.sendmail"; }
sendmail_works(){ rm -f "$SIMROOT/rc.sendmail"; }
no_healthcheck(){ sed -i '/KS_WATCH_HEALTHCHECK/d' "$MASTER/conf/ketsync.conf"; }
no_mailconf(){   sed -i '/KS_MAIL/d' "$MASTER/conf/ketsync.conf"; }
slave_role(){    sed -i 's/^KS_ROLE=master/KS_ROLE=slave/' "$MASTER/conf/ketsync.conf"; }
# A role nobody recognises - a typo in the one line an operator edits by hand.
# Deleting the line instead would prove nothing: common.sh defaults it to slave.
bogus_role(){    sed -i 's/^KS_ROLE=.*/KS_ROLE=maser/' "$MASTER/conf/ketsync.conf"; }
no_master_ip(){  sed -i '/^KS_MASTER_IP=/d' "$MASTER/conf/ketsync.conf"; }
no_node_addr(){  sed -i '/^KS_MAIL_NODE=/d' "$MASTER/conf/ketsync.conf"; }
# answers on attempt N+1: the blip, not a dead machine
host_flaps(){    printf '%s\n' "$2" > "$SIMROOT/flap.$1"; }
clear_mail(){    rm -f "$SIMROOT"/mail.*; : > "$SIMROOT/pings"; }

run_ks(){
  ( export SIMROOT SIMBIN="$HERE/bin"
    # the master-probe knobs exist exactly for this: the simulator must not
    # sit through real waits. The fleet runs the defaults (3 tries x 5s).
    export KS_MASTER_TRIES=3 KS_MASTER_GAP=0
    ssh(){ "$SIMBIN/ssh" "$@"; }
    # sendmail swallows stdin into a numbered file - the mails ARE the output
    # under test. curl records the dead-man ping the same way.
    sendmail(){
      local n; n="$(ls "$SIMROOT"/mail.* 2>/dev/null | wc -l)"
      { printf 'ARGS %s\n' "$*"; cat; } > "$SIMROOT/mail.$((n+1))"
      return "$(cat "$SIMROOT/rc.sendmail" 2>/dev/null || echo 0)"
    }
    curl(){ printf 'curl %s\n' "$*" >> "$SIMROOT/pings"; }
    export -f ssh sendmail curl
    cd "$MASTER" && ./ketsync "$@" -y ) > "$SIMROOT/out" 2>&1
  RC=$?
  OUT="$(cat "$SIMROOT/out")"
}

_err(){ echo "      x $*"; SFAIL=1; }
has(){   grep -qF -- "$1" <<<"$OUT" || _err "expected in log: $1"; }
hasnt(){ grep -qF -- "$1" <<<"$OUT" && _err "should NOT be in log: $1"; return 0; }
rc_is(){ [[ "$RC" == "$1" ]] || _err "exit code $RC, expected $1"; }
mails(){ cat "$SIMROOT"/mail.* 2>/dev/null; }
mail_count(){ local c; c="$(ls "$SIMROOT"/mail.* 2>/dev/null | wc -l)"
  [[ "$c" -eq "$1" ]] || _err "expected $1 mail(s), got $c"; }
mail_has(){   mails | grep -qF -- "$1" || _err "expected in mail: $1"; }
mail_hasnt(){ mails | grep -qF -- "$1" && _err "should NOT be in mail: $1"; return 0; }
pinged(){  [[ -s "$SIMROOT/pings" ]] || _err "expected a healthcheck ping"; }
no_ping(){ [[ -s "$SIMROOT/pings" ]] && _err "must NOT have pinged the healthcheck"; return 0; }
state_there(){ [[ -f "$MASTER/state/watch.tsv" ]] || _err "state file should exist"; }
state_gone(){  [[ -f "$MASTER/state/watch.tsv" ]] && _err "state file should NOT exist"; return 0; }

SFAIL=0; SNAME=""
scenario(){
  [[ -n "$ONLY" && "$ONLY" != "${1%%:*}" ]] && return 1
  echo "  [$1]"; SFAIL=0; SNAME="${1%%:*}"; new_world; return 0
}
done_scenario(){
  if (( SFAIL )); then FAIL=$((FAIL+1)); FAILED_NAMES+=("$SNAME")
  else echo "      ok"; PASS=$((PASS+1)); fi
  [[ -n "${KEEP:-}" ]] && echo "      sandbox: $SIMROOT" || rm -rf "$SIMROOT"
  return 0
}

echo "=== ketsync watch simulator ==="

if scenario "1: a healthy fleet mails nothing, remembers, and pings the dead-man"; then
  run_ks watch
  rc_is 0
  mail_count 0
  has "no change - the fleet looks the way it looked last run"
  state_there
  pinged
  done_scenario
fi

if scenario "2: no addresses, no run - a watch that cannot speak is not watching"; then
  no_mailconf
  run_ks watch
  rc_is 2
  has "refused: KS_MAIL_FROM, KS_MAIL_INFRA and KS_MAIL_NODE must be set"
  mail_count 0
  state_gone
  no_ping
  done_scenario
fi

if scenario "3: a node that stops answering is one NODE mail"; then
  host_down "$N1"
  run_ks watch
  rc_is 0
  mail_count 1
  mail_has "To: node@sim"
  # the envelope sender is what relays validate - a From: header alone leaves
  # it as root@<hostname>, which no provider has verified
  mail_has "ARGS -t -i -f ketsync@sim"
  mail_has "RAISED"
  mail_has "node-unreachable:$N1"
  mail_has "does not answer ssh"
  pinged
  done_scenario
fi

if scenario "4: the same problem twice is ONE mail - the edge, not the level"; then
  host_down "$N1"
  run_ks watch
  clear_mail
  run_ks watch
  rc_is 0
  mail_count 0
  has "no change"
  pinged
  done_scenario
fi

if scenario "5: a problem that goes away mails CLEARED, with when it was raised"; then
  host_down "$N1"
  run_ks watch
  host_up "$N1"
  clear_mail
  run_ks watch
  rc_is 0
  mail_count 1
  mail_has "To: node@sim"
  mail_has "CLEARED"
  mail_has "node-unreachable:$N1 (was raised"
  done_scenario
fi

if scenario "6: PAUSE is an infra fact - every copy ages while it exists"; then
  pause_on
  run_ks watch
  rc_is 0
  mail_count 1
  mail_has "To: infra@sim"
  mail_has "pause"
  mail_has "replication is paused"
  done_scenario
fi

if scenario "7: the backup node down is INFRA, not one more node line"; then
  host_down "$BKP"
  run_ks watch
  rc_is 0
  mail_count 1
  mail_has "To: infra@sim"
  mail_has "backup-unreachable"
  mail_hasnt "To: node@sim"
  done_scenario
fi

if scenario "8: stand-ins placed is ONE story - the records under it stay quiet"; then
  place_nine 110 pve-r32
  evac_rec pve-r32
  iso_rec 110
  run_ks watch
  rc_is 0
  mail_count 1
  mail_has "To: infra@sim"
  mail_has "dr-standins"
  mail_has "stand-ins are placed: 9110"
  mail_hasnt "evacuated:pve-r32"
  mail_hasnt "isolated:110"
  mail_hasnt "To: node@sim"
  done_scenario
fi

if scenario "9: an evacuate left behind with no disaster in progress is a NODE fact"; then
  evac_rec pve-r32
  run_ks watch
  rc_is 0
  mail_count 1
  mail_has "To: node@sim"
  mail_has "evacuated:pve-r32"
  mail_has "restore --node"
  done_scenario
fi

if scenario "10: an unreadable cluster CARRIES its answers - unknown is not gone"; then
  # The false positive this forbids: backup node reboots, watch mails
  # "CLEARED dr-standins", somebody stands down - and the disaster is still on.
  place_nine 110 pve-r32
  run_ks watch
  host_down "$BKP"
  clear_mail
  run_ks watch
  rc_is 0
  mail_has "backup-unreachable"
  mail_hasnt "CLEARED"
  host_up "$BKP"
  clear_mail
  run_ks watch
  rc_is 0
  mail_has "CLEARED"
  mail_has "backup-unreachable (was raised"
  mail_hasnt "dr-standins"
  done_scenario
fi

if scenario "11: --dry-run mails nothing, remembers nothing, pings nothing"; then
  host_down "$N1"
  run_ks watch --dry-run
  rc_is 0
  mail_count 0
  has "DRY: would mail node@sim"
  has "dry-run - no mail was sent, nothing was remembered, nothing was pinged"
  state_gone
  no_ping
  run_ks watch
  mail_count 1
  done_scenario
fi

if scenario "12: a failed send is a red run - not delivered, not remembered, not pinged"; then
  host_down "$N1"
  sendmail_fails
  run_ks watch
  rc_is 1
  has "nothing is marked delivered"
  no_ping
  sendmail_works
  clear_mail
  run_ks watch
  rc_is 0
  mail_count 1
  mail_has "node-unreachable:$N1"
  done_scenario
fi

if scenario "13: no healthcheck configured means no ping and no complaint"; then
  no_healthcheck
  run_ks watch
  rc_is 0
  no_ping
  done_scenario
fi

if scenario "14: --digest mails doctor's whole report to the digest address"; then
  run_ks watch --digest
  rc_is 0
  mail_count 1
  mail_has "To: digest@sim"
  mail_has "[ketsync] daily digest: doctor exit"
  mail_has "== this machine"
  state_gone
  no_ping
  done_scenario
fi

if scenario "15: --list shows what is standing, and changes nothing"; then
  host_down "$N1"
  run_ks watch
  clear_mail
  run_ks watch --list
  rc_is 0
  has "node-unreachable:$N1"
  has "since"
  mail_count 0
  no_ping
  done_scenario
fi

if scenario "16: a slave watches the MASTER, and says nothing about anything else"; then
  # The machine that reports the fleet cannot report its own death, so the
  # backup node asks one question. Everything else is deliberately NOT its
  # business - the assertions below are mostly about what does not arrive,
  # because a second full watcher is two half-tuned alert streams.
  slave_role
  host_down "$ME"
  host_down "$N1"          # a node is down too, and that is the master's story
  pause_on                 # so is PAUSE
  run_ks watch
  rc_is 0
  mail_count 1
  mail_has "master-unreachable"
  mail_has "$ME"
  mail_has "the DR is driven from here"
  mail_has "To: infra@sim"
  mail_hasnt "node-unreachable"
  mail_hasnt "pause"
  state_there
  pinged
  done_scenario
fi

if scenario "18: a slave with a master that answers mails nothing at all"; then
  slave_role
  run_ks watch
  rc_is 0
  mail_count 0
  has "no change - the fleet looks the way it looked last run"
  has "scope=master-only"
  state_there
  pinged
  done_scenario
fi

if scenario "19: a blip is not a dead master - it is asked again before it is believed"; then
  # Two failed attempts, then an answer. One try would have mailed, and a
  # RAISED/CLEARED pair per flap is how an inbox learns to ignore this key.
  slave_role
  host_flaps "$ME" 2
  run_ks watch
  rc_is 0
  mail_count 0
  done_scenario
fi

if scenario "20: a slave refuses --digest - doctor's answers are the master's"; then
  slave_role
  run_ks watch --digest
  rc_is 2
  has "A slave watch has one question in it"
  mail_count 0
  done_scenario
fi

if scenario "21: a role nobody recognises is a refusal, not a guessed one"; then
  bogus_role
  run_ks watch
  rc_is 2
  has "watch runs on a master"
  mail_count 0
  done_scenario
fi

if scenario "22: a slave needs its own FROM and INFRA, and does not need NODE"; then
  slave_role
  no_node_addr
  host_down "$ME"
  run_ks watch
  rc_is 0
  mail_count 1
  mail_has "master-unreachable"
  clear_mail
  no_mailconf
  run_ks watch
  rc_is 2
  has "a slave watch mails one thing"
  mail_count 0
  done_scenario
fi

if scenario "23: a slave with no master address has nothing to watch"; then
  slave_role
  no_master_ip
  run_ks watch
  rc_is 2
  has "KS_MASTER_IP is unset"
  mail_count 0
  done_scenario
fi

if scenario "24: the master's own watch never claims the master is unreachable"; then
  # The other half of the split scope: whatever the master sees, this key is
  # not its to raise - it is the one fact it cannot observe.
  host_down "$N1"
  run_ks watch
  rc_is 0
  mail_has "node-unreachable"
  mail_hasnt "master-unreachable"
  done_scenario
fi

if scenario "17: an argument it does not know is a refusal, not a guess"; then
  run_ks watch --nope
  rc_is 2
  has "watch: unknown argument '--nope'"
  mail_count 0
  state_gone
  done_scenario
fi

echo
echo "=== $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then echo "failed: ${FAILED_NAMES[*]}"; exit 1; fi
exit 0
