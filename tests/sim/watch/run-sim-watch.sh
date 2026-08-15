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
clear_mail(){    rm -f "$SIMROOT"/mail.*; : > "$SIMROOT/pings"; }

run_ks(){
  ( export SIMROOT SIMBIN="$HERE/bin"
    ssh(){ "$SIMBIN/ssh" "$@"; }
    # sendmail swallows stdin into a numbered file - the mails ARE the output
    # under test. curl records the dead-man ping the same way.
    sendmail(){
      local n; n="$(ls "$SIMROOT"/mail.* 2>/dev/null | wc -l)"
      cat > "$SIMROOT/mail.$((n+1))"
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

if scenario "16: on a slave this refuses - one watcher, one state, one ping"; then
  slave_role
  run_ks watch
  rc_is 2
  has "watch runs on the MASTER"
  mail_count 0
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
