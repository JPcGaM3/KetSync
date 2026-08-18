#!/usr/bin/env bash
# =============================================================================
#  run-sim-recover.sh — execute `ketsync recover` against fake engines.
# -----------------------------------------------------------------------------
#  recover is the second command this layer composes, and like distribute the
#  whole of what it can get wrong lives in the joins: the ORDER of the steps,
#  which containers each step is allowed to touch after an earlier one failed,
#  and what may happen only when everything went green. No engine's own
#  simulator can see any of it.
#
#  The failures this exists to catch:
#
#    - the failback running before the fsck, so the repair happens after the
#      write it existed to protect
#    - a 9<id> that is still RUNNING being failed back over - which writes the
#      PRE-outage copy into production and loses everything the stand-in served
#    - PAUSE being removed, or replication restarted, over a return that
#      partly failed
#    - --destroy leaking into a run that did not ask for it
#    - a failed container's later steps running anyway
#    - the exit code reading green while a container was left behind
#
#  The engines are stubs that record their argv - the argv IS the composition -
#  and mutate the same records the real ones consume, because recover is
#  state-driven and the second run of a scenario is part of the first one's
#  assertion.
#
#  usage:  ./tests/sim/recover/run-sim-recover.sh          every scenario
#          ./tests/sim/recover/run-sim-recover.sh 7        scenario 7 only
#          KEEP=1 ./tests/sim/recover/run-sim-recover.sh 7 keep the sandbox
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
  SIMROOT="$(mktemp -d /tmp/ksrec-sim.XXXXXX)"
  MASTER="$SIMROOT/master"
  PVE="$SIMROOT/pve"
  mkdir -p "$MASTER/lib" "$MASTER/conf" "$MASTER/engines" "$MASTER/logs" \
           "$PVE/ketsync/evacuate" "$PVE/ketsync/isolate" \
           "$PVE/nodes/pve-r32/lxc" "$PVE/nodes/pve-r33/lxc" \
           "$SIMROOT/ct" "$SIMROOT/img"
  : > "$SIMROOT/trace"
  # lib/ comes from beside the DISPATCHER, not from the repo, so the mutation
  # suite can hand this harness a tree with one broken file in it.
  local ksdir; ksdir="$(cd "$(dirname "$KS")" && pwd)"
  cp "$KS" "$MASTER/ketsync"; chmod +x "$MASTER/ketsync"
  cp "$ksdir"/lib/*.sh "$MASTER/lib/"
  cat > "$MASTER/conf/ketsync.conf" <<CONF
KS_ROLE=master
KS_MASTER_IP=$ME
CONF
  printf '# generation: 1\n%s\tstorage\n%s\tbackup\n%s\tcompute\n%s\tcompute\n' \
    "$ME" "$BKP" "$N1" "$N2" > "$MASTER/conf/nodes.tsv"
  printf '%s\tpbs-r09\n%s\tpve-r32\n%s\tpve-r33\n' "$BKP" "$N1" "$N2" > "$MASTER/conf/nodes.map"
  printf '# generation: 1\n110\t%s\t%s\tlocal-lvm\n120\t%s\t%s\tlocal-lvm\n' \
    "$N1" "$N1" "$N2" "$N2" > "$MASTER/conf/fleet.tsv"
  stub_engines

  # The mid-return fleet, the way the 2026-08-15 drill actually left it:
  # both nodes evacuated, both containers isolated and stopped, both
  # stand-ins placed and stopped, PAUSE not yet created.
  printf 'x\n' > "$PVE/ketsync/evacuate/pve-r32.tsv"
  printf 'x\n' > "$PVE/ketsync/evacuate/pve-r33.tsv"
  printf 'x\n' > "$PVE/ketsync/isolate/110.tsv"
  printf 'x\n' > "$PVE/ketsync/isolate/120.tsv"
  printf 'x\n' > "$PVE/nodes/pve-r32/lxc/9110.conf"
  printf 'x\n' > "$PVE/nodes/pve-r33/lxc/9120.conf"
  printf 'stopped\n' > "$SIMROOT/ct/110.status"
  printf 'stopped\n' > "$SIMROOT/ct/120.status"
  printf 'stopped\n' > "$SIMROOT/ct/9110.status"
  printf 'stopped\n' > "$SIMROOT/ct/9120.status"
}

# Each stub records its argv - one line, in run order - and then DOES what the
# real engine's success does to the records, because recover reads those
# records to decide what is left. A stub that recorded and changed nothing
# would make every idempotency scenario pass vacuously.
stub_engines(){
  cat > "$MASTER/engines/ct-prepare.sh" <<'STUB'
#!/usr/bin/env bash
printf 'ct-prepare.sh %s\n' "$*" >> "$SIMROOT/trace"
PVE="$SIMROOT/pve"
dry=0; [[ " $* " == *" --dry-run "* ]] && dry=1
ip=""; ct=""; prev=""
for a in "$@"; do
  [[ "$prev" == --node ]] && ip="$a"
  [[ "$prev" == --ctid ]] && ct="$a"
  prev="$a"
done
if [[ " $* " == *" --restore "* && -n "$ip" ]]; then
  rc="$(cat "$SIMROOT/rc.prep-node" 2>/dev/null || echo 0)"
  if (( rc == 0 && ! dry )); then
    name="$(awk -v i="$ip" '$1==i{print $2; exit}' "$SIMROOT/master/conf/nodes.map")"
    rm -f "$PVE/ketsync/evacuate/$name.tsv"
  fi
  exit "$rc"
elif [[ " $* " == *" --restore "* && -n "$ct" ]]; then
  rc="$(cat "$SIMROOT/rc.prep-ctid.$ct" 2>/dev/null || echo 0)"
  (( rc == 0 && ! dry )) && rm -f "$PVE/ketsync/isolate/$ct.tsv"
  exit "$rc"
elif [[ " $* " == *" --cleanup "* && -n "$ct" ]]; then
  rc="$(cat "$SIMROOT/rc.cleanup.$ct" 2>/dev/null || echo 0)"
  if (( rc == 0 && ! dry )) && [[ " $* " == *" --destroy "* ]]; then
    rm -f "$PVE"/nodes/*/lxc/"9$ct.conf"
  fi
  exit "$rc"
fi
exit 0
STUB
  # The failback stub also writes down whether PAUSE existed when it ran,
  # because B2 needs it there and no assertion after the run can see back in
  # time to that moment.
  cat > "$MASTER/engines/ct-failback.sh" <<'STUB'
#!/usr/bin/env bash
p=absent; [[ -f "$(dirname "$0")/PAUSE" ]] && p=present
printf 'ct-failback.sh %s [pause=%s]\n' "$*" "$p" >> "$SIMROOT/trace"
ct=""; prev=""
for a in "$@"; do [[ "$prev" == --ctid ]] && ct="$a"; prev="$a"; done
exit "$(cat "$SIMROOT/rc.fb.$ct" 2>/dev/null || echo 0)"
STUB
  cat > "$MASTER/engines/ct-replica.sh" <<'STUB'
#!/usr/bin/env bash
printf 'ct-replica.sh %s\n' "$*" >> "$SIMROOT/trace"
exit "$(cat "$SIMROOT/rc.replica" 2>/dev/null || echo 0)"
STUB
  chmod +x "$MASTER"/engines/*.sh
}

# ---------- world knobs ----------
img_dirty(){    printf 'clean with errors\n' > "$SIMROOT/img/$1.state"; }
img_missing(){  printf '%s\n' -1  > "$SIMROOT/img/$1.gone"; }   # never comes back
img_late(){     printf '%s\n' "$2" > "$SIMROOT/img/$1.gone"; }  # back after $2 probes
e2fsck_fails(){ printf '8\n' > "$SIMROOT/img/e2fsck.rc"; }
ct_state(){     printf '%s\n' "$2" > "$SIMROOT/ct/$1.status"; }
fb_fails(){     printf '1\n' > "$SIMROOT/rc.fb.$1"; }
replica_fails(){ printf '1\n' > "$SIMROOT/rc.replica"; }
bkp_down(){     : > "$SIMROOT/bkp.down"; }
no_nine(){      rm -f "$PVE"/nodes/*/lxc/"9$1.conf"; }
slave_role(){   printf 'KS_ROLE=slave\nKS_MASTER_IP=%s\n' "$ME" > "$MASTER/conf/ketsync.conf"; }

run_ks(){
  ( export SIMROOT SIMBIN="$HERE/bin"
    # the image-wait knobs exist exactly for this: the simulator must not sit
    # through a real mount wait. The fleet runs the defaults (8 tries x 3s).
    export KS_IMG_WAIT_TRIES=3 KS_IMG_WAIT_GAP=0
    ssh(){ "$SIMBIN/ssh" "$@"; }
    export -f ssh
    cd "$MASTER" && ./ketsync "$@" -y ) > "$SIMROOT/out" 2>&1
  RC=$?
  OUT="$(cat "$SIMROOT/out")"
  TRACE="$(cat "$SIMROOT/trace")"
}

_err(){ echo "      x $*"; SFAIL=1; }
has(){   grep -qF -- "$1" <<<"$OUT" || _err "expected in log: $1"; }
hasnt(){ grep -qF -- "$1" <<<"$OUT" && _err "should NOT be in log: $1"; return 0; }
rc_is(){ [[ "$RC" == "$1" ]] || _err "exit code $RC, expected $1"; }
ran(){   grep -q -- "^$1" <<<"$TRACE" || _err "expected in trace: $1
         got:
$(sed 's/^/           /' <<<"$TRACE")"; }
never_ran(){ grep -q -- "^$1" <<<"$TRACE" && _err "must NOT have run: $1"; return 0; }
before(){ local a b
  a=$(grep -n -- "^$1" <<<"$TRACE" | head -1 | cut -d: -f1)
  b=$(grep -n -- "^$2" <<<"$TRACE" | head -1 | cut -d: -f1)
  [[ -n "$a" && -n "$b" && "$a" -lt "$b" ]] || _err "'$1' should have run before '$2'"; }
pause_there(){ [[ -f "$MASTER/engines/PAUSE" ]] || _err "PAUSE should exist"; }
pause_gone(){  [[ -f "$MASTER/engines/PAUSE" ]] && _err "PAUSE should have been removed"; return 0; }
clean_trace(){ : > "$SIMROOT/trace"; }

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

echo "=== ketsync recover simulator ==="

if scenario "1: the complete return with --destroy, every step, in order"; then
  run_ks recover --all --destroy
  rc_is 0
  ran "ct-prepare.sh --restore --node $N1"
  ran "ct-prepare.sh --restore --node $N2"
  ran "ct-failback.sh --ctid 110 --final"
  ran "ct-failback.sh --ctid 120 --final"
  ran "ct-prepare.sh --restore --ctid 110"
  ran "ct-prepare.sh --cleanup --ctid 110 --destroy"
  ran "ct-replica.sh"
  before "ct-prepare.sh --restore --node $N1" "ct-failback.sh --ctid 110"
  before "ct-failback.sh --ctid 110" "ct-prepare.sh --restore --ctid 110"
  before "ct-prepare.sh --restore --ctid 110" "ct-prepare.sh --cleanup --ctid 110"
  before "ct-prepare.sh --cleanup --ctid 120" "ct-replica.sh"
  pause_gone
  has "removed PAUSE"
  has "replica round ok"
  has "ssh root@$N1 pct start 110"
  has "ssh root@$N2 pct start 120"
  hasnt "pct start 9110"
  done_scenario
fi

if scenario "2: without --destroy the stand-ins are kept and replication stays held"; then
  run_ks recover --all
  rc_is 0
  ran "ct-prepare.sh --cleanup --ctid 110$"
  never_ran "ct-prepare.sh --cleanup --ctid 110 --destroy"
  never_ran "ct-replica.sh"
  pause_there
  has "the stand-ins are KEPT (no --destroy)"
  has "./ketsync cleanup --ctid 110 --destroy"
  done_scenario
fi

if scenario "3: a second run finds nothing and touches nothing"; then
  # Idempotency is not a property of the code, it is a property of the records
  # the first run consumed - which is why the stubs consume them.
  run_ks recover --all --destroy
  rc_is 0
  clean_trace
  run_ks recover --all --destroy
  rc_is 0
  has "nothing to recover"
  never_ran "ct-prepare.sh"
  never_ran "ct-failback.sh"
  never_ran "ct-replica.sh"
  done_scenario
fi

if scenario "4: a dirty image is fscked before anything writes into it"; then
  img_dirty 110
  run_ks recover --all
  rc_is 0
  ran "e2fsck $N1 /mnt/pve/tank-hdd-nas/images/110/vm-110-disk-0.raw"
  before "e2fsck $N1" "ct-failback.sh --ctid 110"
  has "e2fsck done (rc=1) - the image is consistent again"
  done_scenario
fi

if scenario "4b: a clean image is not fscked"; then
  run_ks recover --all
  rc_is 0
  never_ran "e2fsck"
  has "image superblock is clean"
  done_scenario
fi

if scenario "5: an image e2fsck cannot repair blocks that container's failback"; then
  img_dirty 110
  e2fsck_fails
  run_ks recover --all --destroy
  rc_is 1
  has "e2fsck exited 8 - the image needs a human"
  never_ran "ct-failback.sh --ctid 110"
  ran "ct-failback.sh --ctid 120"
  # And a red run must not restart replication, --destroy or not.
  never_ran "ct-replica.sh"
  pause_there
  has "NOT removing PAUSE"
  done_scenario
fi

if scenario "6: a stand-in that is still RUNNING refuses - stopping it is the cutover"; then
  # Failing back over a running 9<id> writes the PRE-outage copy into
  # production and loses everything the stand-in served. The recall that
  # protects against it cannot be verified from this machine, but the stop it
  # requires can be, and is.
  ct_state 9110 running
  run_ks recover --all
  rc_is 1
  has "CT 9110 is running on pve-r32 - NOT failing back CT 110"
  has "ketsync recall --ctid 110 --final"
  never_ran "ct-failback.sh --ctid 110"
  never_ran "ct-prepare.sh --restore --ctid 110"
  never_ran "ct-prepare.sh --cleanup --ctid 110"
  ran "ct-failback.sh --ctid 120"
  done_scenario
fi

if scenario "7: a production container that is RUNNING is a human's to stop"; then
  # The storage is back, so the stat proof would call it alive and evacuate
  # would refuse - correctly. recover does not get a bigger hammer than the
  # engines have; it names the command and whose decision it is.
  ct_state 110 running
  run_ks recover --all
  rc_is 1
  has "production CT 110 is RUNNING on $N1"
  has "ssh root@$N1 pct shutdown 110"
  never_ran "ct-failback.sh --ctid 110"
  ran "ct-failback.sh --ctid 120"
  done_scenario
fi

if scenario "8: --dry-run reaches every engine and writes nothing itself"; then
  img_dirty 110
  run_ks recover --all --destroy --dry-run
  rc_is 0
  ran "ct-prepare.sh --restore --node $N1 --dry-run"
  ran "ct-failback.sh --ctid 110 --final --dry-run"
  ran "ct-prepare.sh --restore --ctid 110 --dry-run"
  ran "ct-prepare.sh --cleanup --ctid 110 --destroy --dry-run"
  never_ran "e2fsck"
  has "DRY: would e2fsck"
  has "DRY: would rm"
  never_ran "ct-replica.sh"
  pause_gone
  done_scenario
fi

if scenario "9: --list reads, prints the checklist, and runs nothing"; then
  img_dirty 110
  run_ks recover --list
  rc_is 0
  has "todo  restore --node $N1"
  has "todo  e2fsck -fy on CT 110's image"
  has "todo  failback --ctid 110 --final"
  has "todo  restore --ctid 120"
  has "NOT VERIFIABLE from here"
  never_ran "ct-prepare.sh"
  never_ran "ct-failback.sh"
  done_scenario
fi

if scenario "10: on a slave this refuses before reading anything"; then
  slave_role
  run_ks recover --all
  rc_is 2
  has "recover runs on the MASTER"
  never_ran "ct-prepare.sh"
  never_ran "ct-failback.sh"
  done_scenario
fi

if scenario "11: a bare recover is an incomplete instruction"; then
  run_ks recover
  rc_is 2
  has "refused"
  never_ran "ct-prepare.sh"
  done_scenario
fi

if scenario "12: a failed failback strands only its own container"; then
  fb_fails 110
  run_ks recover --all --destroy
  rc_is 1
  has "failback --final FAILED"
  never_ran "ct-prepare.sh --restore --ctid 110"
  never_ran "ct-prepare.sh --cleanup --ctid 110"
  ran "ct-prepare.sh --restore --ctid 120"
  ran "ct-prepare.sh --cleanup --ctid 120 --destroy"
  never_ran "ct-replica.sh"
  pause_there
  hasnt "pct start 110"
  has "ssh root@$N2 pct start 120"
  done_scenario
fi

if scenario "13: PAUSE exists before the first failback runs"; then
  # B2 requires it, and no assertion after the run can see back to that
  # moment - so the failback stub wrote down what it saw.
  run_ks recover --all
  rc_is 0
  has "created"
  ran "ct-failback.sh --ctid 110 --final \[pause=present\]"
  done_scenario
fi

if scenario "14: a container that was only isolated needs no failback"; then
  # The disaster stopped early for this one: taken off the wire, never placed.
  # Nothing served in its stead, so its image was never behind.
  no_nine 120
  run_ks recover --all
  rc_is 0
  ran "ct-prepare.sh --restore --ctid 120"
  never_ran "ct-failback.sh --ctid 120"
  never_ran "ct-prepare.sh --cleanup --ctid 120"
  ran "ct-failback.sh --ctid 110"
  done_scenario
fi

if scenario "15: a replica round that comes back red turns the run red"; then
  replica_fails
  run_ks recover --all --destroy
  rc_is 1
  ran "ct-replica.sh"
  has "the first replica round back did not end clean"
  done_scenario
fi

if scenario "16: an unreachable backup node stops everything before it starts"; then
  bkp_down
  run_ks recover --all
  rc_is 2
  has "cannot reach the backup node"
  has "Unanswered"
  never_ran "ct-prepare.sh"
  never_ran "ct-failback.sh"
  done_scenario
fi

if scenario "17: an image nobody can see is refused, never called clean"; then
  # The 2026-08-16 drill: restore --node switches the NFS storage back on and
  # the superblock probe runs seconds later, inside the window where the mount
  # has not reappeared. The old code read that absence as "clean (NOIMAGE) -
  # no fsck needed" and carried on toward the failback.
  img_missing 110
  run_ks recover --all
  rc_is 1
  has "cannot see CT 110's image"
  has "Absence is not cleanliness"
  hasnt "image superblock is clean (NOIMAGE)"
  never_ran "ct-failback.sh --ctid 110"
  never_ran "ct-prepare.sh --restore --ctid 110"
  ran "ct-failback.sh --ctid 120"
  done_scenario
fi

if scenario "18: a mount that comes back mid-wait is waited for, then judged"; then
  # Two NOIMAGE answers, then the mount is back. The wait exists so the normal
  # case - NFS taking a few seconds - ends in a verdict, not a refusal.
  img_late 110 2
  run_ks recover --all
  rc_is 0
  has "image superblock is clean (clean)"
  hasnt "cannot see CT 110's image"
  ran "ct-failback.sh --ctid 110 --final"
  done_scenario
fi

if scenario "19: a dry run says WHY it cannot see the image instead of calling it clean"; then
  # In a dry run step 1 was dry too, so the storage really is still off and
  # the image really is invisible. That is worth saying honestly - what it is
  # not worth is a green "clean (NOIMAGE)" that trains people to read absence
  # as health.
  img_missing 110
  run_ks recover --all --dry-run
  rc_is 0
  has "DRY: cannot see the image from here"
  has "refuses this container if the"
  hasnt "image superblock is clean (NOIMAGE)"
  ran "ct-failback.sh --ctid 110 --final --dry-run"
  done_scenario
fi


if scenario "21: --ctid recovers ONE container the records name, and only that one"; then
  # The 2026-08-18 return: one container's fleet row was missing, its fsck
  # errored, and the other two finished - leaving exactly one container to
  # recover. --all would walk the finished ones again; --ctid walks one.
  run_ks recover --ctid 110
  rc_is 0
  ran "ct-failback.sh --ctid 110 --final"
  never_ran "ct-failback.sh --ctid 120 --final"
  never_ran "ct-prepare.sh --restore --ctid 120"
  ran "ct-prepare.sh --restore --node $N1"
  never_ran "ct-prepare.sh --restore --node $N2"
  clean_trace
  # a container the records do not name is a refusal, not an empty run
  run_ks recover --ctid 999
  rc_is 2
  has "the disaster's records do not name CT 999"
  never_ran "ct-failback.sh"
  clean_trace
  # and the two scopes contradict
  run_ks recover --all --ctid 110
  rc_is 2
  has "pick one"
  done_scenario
fi

echo
echo "=== $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then echo "failed: ${FAILED_NAMES[*]}"; exit 1; fi
exit 0
