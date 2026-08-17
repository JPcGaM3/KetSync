#!/usr/bin/env bash
# =============================================================================
#  run-sim-doctor.sh — execute `ketsync doctor` against a fake fleet.
# -----------------------------------------------------------------------------
#  doctor was the last command in this layer without a simulator, and the
#  reason it was last is the reason it needed one. It writes nothing, so
#  nothing it does can corrupt anything; what it can do is stop noticing.
#
#  Every section of it exists because something in this fleet's history was
#  true and invisible: a DR copy three days old, a container still on the
#  isolation bridge, a storage still disabled from an evacuate, a 9<id> that
#  outlived its disaster, a cron line that would refuse to run, an image whose
#  filesystem has already recorded an error. A check that quietly stops firing
#  does not fail a run - it prints the same clean fleet a clean fleet prints,
#  and the difference is found during the next incident.
#
#  So every scenario here is the same shape: put ONE thing wrong into a fleet
#  that is otherwise fine, and require that doctor says so and exits non-zero.
#  The fleet is modelled the way the sync simulator models it - each machine a
#  whole filesystem under $SIMROOT - because doctor asks other machines
#  questions and "did not answer" has to be distinguishable from "answered no".
#
#  usage:  ./tests/sim/doctor/run-sim-doctor.sh          every scenario
#          ./tests/sim/doctor/run-sim-doctor.sh 7        scenario 7 only
#          KEEP=1 ./tests/sim/doctor/run-sim-doctor.sh 7 keep the sandbox
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
KS="${KS:-$ROOT/ketsync}"

if [[ ! -f "$KS" ]]; then
  echo "ketsync not found: $KS" >&2; exit 2
elif [[ ! -x "$KS" ]]; then
  echo "ketsync is not executable: $KS" >&2
  echo "  every scenario would die with exit 126. fix it with:  chmod +x $KS" >&2
  exit 2
fi
ONLY="${1:-}"
PASS=0; FAIL=0; FAILED_NAMES=()

ME=10.100.1.17          # this machine, the storage node
BKP=10.100.1.9          # the backup node - the one connection everything leans on
C1=10.100.1.32          # a compute node
C2=10.100.1.33          # a second one

new_world(){
  SIMROOT="$(mktemp -d /tmp/ksdoc-sim.XXXXXX)"
  export SIMROOT SIMLIB="$HERE/lib.sh"
  MASTER="$SIMROOT/master"
  : > "$SIMROOT/violations"; : > "$SIMROOT/trace"

  mkdir -p "$MASTER/lib" "$MASTER/conf" "$MASTER/engines/state" "$MASTER/inventory" "$MASTER/logs"
  local ksdir; ksdir="$(cd "$(dirname "$KS")" && pwd)"
  cp "$KS" "$MASTER/ketsync"; chmod +x "$MASTER/ketsync"
  cp "$ksdir"/lib/*.sh "$MASTER/lib/"

  cat > "$MASTER/conf/ketsync.conf" <<CONF
KS_ROLE=master
KS_MASTER_IP=$ME
CONF
  table "$MASTER/conf/nodes.tsv" 1 \
    "$ME	storage" "$BKP	backup" "$C1	compute" "$C2	compute"
  table "$MASTER/conf/fleet.tsv" 5 "110	$C1	$C2	local-lvm" "120	$C2	$C1	local-lvm"
  table "$MASTER/inventory/inventory-replica.tsv" 5 "110	replica-hdd" "120	replica-hdd"
  table "$MASTER/inventory/inventory-migrate.tsv"  2 "251	tank-hdd-nas"

  # The engines have to exist and be runnable, because "cron would exit 126" is
  # one of the things doctor is for. tp itself is a stub: what the execution
  # layer reports is its own simulator's business, and this one is about
  # whether doctor passes its exit code through.
  local f
  for f in ct-migrate.sh ct-replica.sh ct-failback.sh ct-distribute.sh ct-recall.sh ct-prepare.sh; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$MASTER/engines/$f"
    chmod +x "$MASTER/engines/$f"
  done
  printf '#!/usr/bin/env bash\necho "  tp: nothing to report"\nexit 0\n' > "$MASTER/engines/tp"
  chmod +x "$MASTER/engines/tp"

  # Every machine, and what the cluster would say its name is.
  : > "$SIMROOT/cluster.tsv"
  add_host "$ME"  pve-storage-r17
  add_host "$BKP" pbs-r09
  add_host "$C1"  pve-r32
  add_host "$C2"  pve-r33

  # Both containers, healthy: a config, an image behind it, and a filesystem
  # that has nothing to say. A running container reports "not clean" and that
  # is not a fault - see scenario 14.
  ct_image 110 "$C1" clean
  ct_image 120 "$C2" clean

  # A copy of each, taken just now, so the staleness check has something to be
  # quiet about.
  replica_state 110 "$(date +%s)"
  replica_state 120 "$(date +%s)"

  # No cron at all. A scenario that wants one says so.
  : > "$SIMROOT/crontab"
}

# $1 = file, $2 = generation, rest = rows
table(){
  local f="$1" gen="$2"; shift 2
  { printf '# generation: %s\n' "$gen"; printf '%s\n' "$@"; } > "$f"
}
host_dir_local(){ printf '%s/hosts/%s' "$SIMROOT" "$1"; }
add_host(){   # ip name
  mkdir -p "$(host_dir_local "$1")/fs/etc/pve/ketsync/isolate" \
           "$(host_dir_local "$1")/fs/etc/pve/ketsync/evacuate" \
           "$(host_dir_local "$1")/ct"
  printf '%s\t%s\n' "$1" "$2" >> "$SIMROOT/cluster.tsv"
}
host_down(){  : > "$(host_dir_local "$1")/.down"; }
# The cluster stops answering for names, without any machine going down: a
# quorum that is gone, or a pvesh that fails. doctor falls back to the cache.
no_cluster_status(){ : > "$(host_dir_local "$BKP")/nostatus"; }

# What a node would say about one container's rootfs image.
#   clean | "clean with errors" | "not clean" | none   (none = dumpe2fs silent)
ct_image(){   # ctid node-ip state
  local d; d="$(host_dir_local "$2")/ct"; mkdir -p "$d"
  printf 'tank-hdd-nas:%s/vm-%s-disk-0.raw\n' "$1" "$1" > "$d/$1.rootfs"
  printf '/mnt/pve/tank-hdd-nas/images/%s/vm-%s-disk-0.raw\n' "$1" "$1" > "$d/$1.path"
  rm -f "$d/$1.fsstate"
  [[ "$3" == none ]] || printf '%s\n' "$3" > "$d/$1.fsstate"
}
ct_image_blocked(){   # ctid node-ip - the stat on its path blocks (dead mount)
  ct_image "$1" "$2" clean
  : > "$(host_dir_local "$2")/ct/$1.blocked"
}
ct_no_config(){ rm -f "$(host_dir_local "$2")/ct/$1.rootfs"; }
ct_no_image(){  rm -f "$(host_dir_local "$2")/ct/$1.path"; }

# A DR that was never finished, in each of the three shapes doctor looks for.
left_isolated(){ : > "$(host_dir_local "$BKP")/fs/etc/pve/ketsync/isolate/$1.tsv"; }
left_evacuated(){ : > "$(host_dir_local "$BKP")/fs/etc/pve/ketsync/evacuate/$1.tsv"; }
left_placed(){   # 9<id> on a node
  mkdir -p "$(host_dir_local "$BKP")/fs/etc/pve/nodes/$2/lxc"
  : > "$(host_dir_local "$BKP")/fs/etc/pve/nodes/$2/lxc/$1.conf"; }

replica_state(){  # ctid epoch
  printf '{\n  "ctid": %s,\n  "last": {"epoch":%s,"status":"ok"}\n}\n' "$1" "$2" \
    > "$MASTER/engines/state/replica-$1.json"
}
cron_line(){ printf '%s\n' "$1" >> "$SIMROOT/crontab"; }

# No arguments: doctor takes none, and a scenario that wanted to pass one
# would be testing a command this dispatcher does not have.
run_ks(){
  ( export SIMROOT SIMLIB SIMBIN="$HERE/bin"
    # The dispatcher sets its own PATH, so a fake cannot be reached by
    # prepending a directory - an exported FUNCTION is resolved first, and
    # survives into the child bash.
    ssh(){ "$SIMBIN/ssh" "$@"; }
    # doctor reads the crontab of the machine it is standing on. Faking it is
    # not optional: without this the suite would read whatever the developer's
    # own crontab says, pass on one machine and fail on another.
    crontab(){ cat "$SIMROOT/crontab" 2>/dev/null; }
    export -f ssh crontab
    "$MASTER/ketsync" doctor ) > "$SIMROOT/out" 2>&1
  RC=$?
  OUT="$(cat "$SIMROOT/out")"
  TRACE="$(cat "$SIMROOT/trace")"
  VIO="$(cat "$SIMROOT/violations")"
}

_err(){ echo "      x $*"; SCEN_OK=0; }
has(){    grep -qF -- "$1" <<<"$OUT" || _err "expected in output: $1"; }
hasnt(){  grep -qF -- "$1" <<<"$OUT" && _err "should NOT be in output: $1"; return 0; }
rc_is(){  [[ "$RC" == "$1" ]] || _err "exit code $RC, expected $1"; }
traced(){   grep -qF -- "$1" <<<"$TRACE" || _err "expected to run: $1"; }
untraced(){ grep -qF -- "$1" <<<"$TRACE" && _err "must NOT have run: $1"; return 0; }
clean(){ [[ -z "$VIO" ]] || { _err "INVARIANT BROKEN:"; sed 's/^/         /' <<<"$VIO"; }; return 0; }

scenario(){
  N="${1%%:*}"
  [[ -n "$ONLY" && "$ONLY" != "$N" ]] && return 1
  echo "  [$1]"; SCEN_OK=1; new_world; return 0
}
done_scenario(){
  if (( SCEN_OK )); then PASS=$((PASS+1)); echo "      ok"
  else FAIL=$((FAIL+1)); FAILED_NAMES+=("$N"); echo "      sandbox: $SIMROOT"; fi
  [[ -n "${KEEP:-}" ]] || { (( SCEN_OK )) && rm -rf "$SIMROOT"; }
}

echo "=== ketsync doctor simulator ==="

if scenario "1: a fleet with nothing wrong exits 0 and says so section by section"; then
  # The baseline every other scenario is one change away from. If this ever
  # starts failing, no other scenario here proves anything: they all assert
  # that ONE thing is reported, against a fleet that is otherwise quiet.
  run_ks
  rc_is 0; clean
  has "role=master"
  has "every row has an address, a dr node and a storage"
  has "nothing left over"
  has "none - no image reports an error in its superblock"
  has "== cron lines that call ketsync without -y"
  done_scenario
fi

if scenario "2: a node that does not answer is named, with its address"; then
  # Half a line on the screen and the other half in the log is a log that says
  # SSH FAILS without saying which machine.
  host_down "$C1"
  run_ks
  rc_is 1
  has "$C1"
  has "SSH FAILS"
  done_scenario
fi

if scenario "3: the backup node is the one whose loss stops everything else"; then
  host_down "$BKP"
  run_ks
  rc_is 1
  has "UNREACHABLE - node names cannot be discovered"
  has "Fix this one first"
  done_scenario
fi

if scenario "4: a cluster that cannot be asked falls back to the cache and says so"; then
  # The names are cached on purpose: discovery needs a quorate cluster, and the
  # run that needs the map most is the one during an incident.
  no_cluster_status
  printf '# ip\tname\n%s\tpve-r32\n' "$C1" > "$MASTER/conf/nodes.map"
  run_ks
  rc_is 1
  has "could not reach the cluster - using the cached nodes.map"
  has "it is not fine for a month"
  done_scenario
fi

if scenario "5: a table with no generation line cannot be ordered by sync"; then
  printf '110\t%s\t%s\tlocal-lvm\n' "$C1" "$C2" > "$MASTER/conf/fleet.tsv"
  run_ks
  rc_is 1
  has "fleet.tsv: NO generation line"
  done_scenario
fi

if scenario "6: the OLD five-column fleet.tsv is named, not read as the new one"; then
  # An old row has four fields too, so it parses as the new shape and means
  # something completely different: column 2 was a tier and is now an address.
  table "$MASTER/conf/fleet.tsv" 5 "110	gold	$C1	$C2	local-lvm"
  run_ks
  rc_is 1
  has "column 2 is 'gold', not an address"
  has "the tier column is gone"
  done_scenario
fi

if scenario "7: an address in fleet.tsv that nodes.tsv has never heard of"; then
  table "$MASTER/conf/fleet.tsv" 5 "110	$C1	10.100.1.99	local-lvm"
  run_ks
  rc_is 1
  has "10.100.1.99 has no row in nodes.tsv"
  done_scenario
fi

if scenario "8: a row with no dst, which distribute will refuse when it matters"; then
  table "$MASTER/conf/fleet.tsv" 5 "110	$C1	$C2"
  run_ks
  rc_is 1
  has "no dst - distribute will refuse it, there is no default"
  done_scenario
fi

if scenario "9: a copy old enough to have stopped being a backup"; then
  # "The backup node has been unreachable for three days" and "nothing has been
  # copied for three days" are the same fact, and nothing else in this system
  # says the second one out loud.
  replica_state 110 "$(( $(date +%s) - 5 * 86400 ))"
  run_ks
  rc_is 1
  has "CT 110: last successful copy was 5 day(s) ago"
  has "is not a backup, it is a memory"
  done_scenario
fi

if scenario "10: what a half-finished DR left behind, in all three shapes"; then
  left_isolated 110
  left_evacuated pve-r32
  left_placed 9120 pve-r33
  run_ks
  rc_is 1
  has "CT 110 is still ISOLATED"
  has "./ketsync restore --ctid 110"
  has "node pve-r32 still has storages DISABLED"
  has "CT 9120 is still placed"
  has "./ketsync cleanup --ctid 120"
  hasnt "nothing left over"
  done_scenario
fi

if scenario "11: a backup node that cannot be asked is not a fleet with nothing left over"; then
  # Unanswered is not the same as clean. This is the check whose false green
  # would be believed, because it is the one people run to decide the DR is
  # finished.
  host_down "$BKP"
  run_ks
  rc_is 1
  has "unanswered is not the same as clean"
  hasnt "nothing left over"
  done_scenario
fi

if scenario "12: an engine cron could not run is worth more than one that is missing"; then
  chmod -x "$MASTER/engines/ct-distribute.sh"
  run_ks
  rc_is 1
  has "ct-distribute.sh is NOT EXECUTABLE - cron would exit 126"
  done_scenario
fi

if scenario "13: an image whose superblock already recorded an error"; then
  # The container was not shut down, it was stopped by its own writes failing -
  # which is what forcing a dead mount to fail does, and the only thing that
  # gets a container down while its rootfs is gone. ext4 records that in the
  # image and then mounts it anyway, saying so once, in dmesg, where nobody
  # reads it on a Tuesday. A failback writes INTO that image.
  ct_image 120 "$C2" "clean with errors"
  run_ks
  rc_is 1
  has "CT 120: its image says \"clean with errors\""
  has "/mnt/pve/tank-hdd-nas/images/120/vm-120-disk-0.raw"
  has "e2fsck -fy /mnt/pve/tank-hdd-nas/images/120/vm-120-disk-0.raw"
  done_scenario
fi

if scenario "14: a RUNNING container reports not clean, and that is not a fault"; then
  # A mounted filesystem always says not clean - that is what mounted means.
  # Reporting it would put every running container in this section on every
  # run, which is how a check teaches people to skip it.
  ct_image 110 "$C1" "not clean"
  run_ks
  rc_is 0; clean
  has "none - no image reports an error in its superblock"
  hasnt "CT 110: its image says"
  done_scenario
fi

if scenario "15: a node that cannot be asked about an image is not a clean image"; then
  host_down "$C2"
  run_ks
  rc_is 1
  has "CT 120: could not ask $C2 - unanswered is not the same as clean"
  done_scenario
fi

if scenario "16: a container with no config, and one with no image, are both quiet"; then
  # Neither is this check's business. A container that has been removed and one
  # whose image is on a storage this node cannot see are both somebody else's
  # section, and a filesystem check that shouted about them would be noise in
  # the one place noise is expensive.
  ct_no_config 110 "$C1"
  ct_no_image  120 "$C2"
  run_ks
  rc_is 0; clean
  has "none - no image reports an error in its superblock"
  done_scenario
fi

if scenario "17: a cron line that would refuse to run at 02:00"; then
  # A command that writes asks first, and cron has nobody to ask, so it exits
  # 2 - correctly, and silently, until somebody reads the mail nobody set up.
  cron_line "0 2 * * * /root/ketsync/ketsync replica --all"
  run_ks
  rc_is 1
  has "these would REFUSE, because there is nobody there to answer"
  has "ketsync replica --all"
  has "add -y to each"
  done_scenario
fi

if scenario "18: a cron line that already says -y is not complained about"; then
  cron_line "0 2 * * * /root/ketsync/ketsync replica --all -y"
  run_ks
  rc_is 0; clean
  has "== cron lines that call ketsync without -y"
  hasnt "these would REFUSE"
  done_scenario
fi

if scenario "19: the exit code is the worse of the two layers"; then
  # A healthy decision layer on top of a broken execution layer is not a
  # healthy system, and doctor is the one command that reports both.
  printf '#!/usr/bin/env bash\necho "  tp: something is wrong"\nexit 1\n' > "$MASTER/engines/tp"
  chmod +x "$MASTER/engines/tp"
  run_ks
  rc_is 1
  has "tp: something is wrong"
  done_scenario
fi

if scenario "20: engines/tp missing at all is the end of the report, not a section of it"; then
  rm -f "$MASTER/engines/tp"
  run_ks
  rc_is 1
  has "engines/ is missing its dispatcher - ketsync decides, tp does"
  done_scenario
fi

if scenario "21: a cron line for a read-only verb needs no -y and is not nagged"; then
  # watch is DESIGNED to run from cron bare - it never asks, so -y would mean
  # nothing on it, and a nag here trains people to sprinkle -y everywhere.
  cron_line "*/10 * * * * /root/ketsync/ketsync watch"
  cron_line "30 7 * * * /root/ketsync/ketsync watch --digest"
  cron_line "0 8 * * * /root/ketsync/ketsync doctor"
  run_ks
  rc_is 0; clean
  hasnt "these would REFUSE"
  done_scenario
fi


if scenario "22: a dead mount is a BLOCKED probe and one timeout, not one per row"; then
  # The storage node dies and every image path it exported blocks. The first
  # row on a blocked node pays one 5s timeout and says BLOCKED; the remaining
  # rows on the SAME node are skipped OUT LOUD, because their answer would be
  # the same block one timeout at a time; a healthy node's rows are still
  # really probed. This is the check that took minutes per row on the
  # 2026-08-17 outage, run at exactly the moment nobody has minutes.
  table "$MASTER/conf/fleet.tsv" 6 \
    "110	$C1	$C2	local-lvm" "120	$C1	$C2	local-lvm" "130	$C2	$C1	local-lvm"
  ct_image_blocked 110 "$C1"
  ct_image_blocked 120 "$C1"
  ct_image 130 "$C2" clean
  run_ks
  rc_is 1
  has "CT 110: its storage did not answer within 5s - the mount is BLOCKED, not clean"
  has "CT 120: skipped - $C1's storage is already known to block"
  hasnt "CT 120: its storage did not answer"
  hasnt "CT 130: skipped"
  hasnt "CT 130: its storage did not answer"
  done_scenario
fi

echo
echo "=== $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then echo "failed: ${FAILED_NAMES[*]}"; exit 1; fi
exit 0
