#!/usr/bin/env bash
# =============================================================================
#  run-sim-recall.sh — execute ct-recall.sh against a fake cluster.
# -----------------------------------------------------------------------------
#  Why this exists: this engine writes into the DR copy, and the DR copy is the
#  only thing standing between the fleet and a second failure while the storage
#  node is down. It only ever runs during a disaster, on machines whose
#  customers are already waiting. There is no second chance to discover that a
#  guard moved.
#
#  Like ct-distribute it runs on NEITHER end of its own transfer, so the
#  failures it can produce are different in kind: an rsync out of a directory
#  nothing mounted, a mount that replays a live container's journal, a
#  direction established from nothing. The fake refuses to pretend about each
#  and records a VIOLATION instead:
#
#    - rsync OUT of a path that is not a mountpoint    (C6: --delete then
#      empties the copy to match an empty directory)
#    - rsync without --delete                          (the copy keeps files
#      the DR container deleted, forever)
#    - a mount that is rw, or ro without noload        (C6: journal replay on a
#      filesystem a live container is writing)
#    - a loop mount on a block device, or a plain mount on a raw file
#    - umount of a dataset this engine never mounted   (takes the copy offline)
#    - pct start / shutdown / stop / destroy, anywhere (C7)
#    - any write at all while --dry-run is in force
#
#  A scenario can therefore FAIL two ways: wrong observable behaviour, or a
#  broken invariant. The second is the one that matters.
#
#  The engine sets its own PATH (cron gives it a useless one), so the fake
#  cannot be reached by prepending a directory - run_engine exports a shell
#  FUNCTION, which bash resolves first. Only `ssh` is faked, because only `ssh`
#  reaches a disk.
#
#  usage:  ./tests/sim/recall/run-sim-recall.sh          every scenario
#          ./tests/sim/recall/run-sim-recall.sh 7        scenario 7 only
#          KEEP=1 ./tests/sim/recall/run-sim-recall.sh 7 keep the sandbox
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
ENGINE="${ENGINE:-$ROOT/ct-recall.sh}"

if [[ ! -f "$ENGINE" ]]; then
  echo "engine not found: $ENGINE" >&2; exit 2
elif [[ ! -x "$ENGINE" ]]; then
  echo "engine is not executable: $ENGINE" >&2
  echo "  every scenario would die with exit 126. fix it with:  chmod +x $ENGINE" >&2
  exit 2
fi
ONLY="${1:-}"
PASS=0; FAIL=0; FAILED_NAMES=()

# The number in front of a scenario name is its selector, and the mutation
# suite is the thing that selects. Two scenarios sharing one number make
# `run-sim-recall.sh <n>` ambiguous, and a mutation aimed at one can be
# "killed" by the other failing for an unrelated reason. Reported through the
# summary rather than as an exit: a filtered run IS the mutation runner, and
# exiting non-zero there reads to it as "the scenario died", which would turn
# every mutation green at once.
_dups="$(grep -o 'scenario "[0-9a-z]*:' "$HERE/run-sim-recall.sh" \
          | sed 's/.*"//; s/:$//' | sort | uniq -d | tr '\n' ' ')"
if [[ -z "$ONLY" && -n "${_dups// /}" ]]; then
  FAIL=$((FAIL+1)); FAILED_NAMES+=("duplicate scenario numbers: $_dups")
fi

# The fake and this runner share one model of what is mounted where, so the
# helpers come from the same file rather than being written twice. A world set
# up by a harness that disagreed with the fake would test the disagreement.
# shellcheck source=tests/sim/recall/lib.sh
SIMLIB_FNS="$HERE/lib.sh"

BKP_HOST=100.100.100.35
S1=10.100.1.32          # a compute node with local-lvm  (block)
S2=10.100.1.33          # a second one, deliberately of a different shape

new_world(){
  SIMROOT="$(mktemp -d /tmp/ctrec-sim.XXXXXX)"
  export SIMROOT SIMLIB="$HERE/lib.sh" SIMBIN="$HERE/bin" SIM_BKP_HOST="$BKP_HOST"
  # shellcheck source=tests/sim/recall/lib.sh
  . "$SIMLIB_FNS"
  WORK="$SIMROOT/work"; BKP="$SIMROOT/bkp"; PVE="$SIMROOT/pve"
  mkdir -p "$WORK/state" "$WORK/logs" "$BKP/ct" "$BKP/fs" "$PVE/nodes/bkp02"
  : > "$SIMROOT/violations"; : > "$SIMROOT/trace"; : > "$BKP/zfs.tsv"
  echo 0 > "$SIMROOT/rsync.rc"
  # files, literal, sent - what the fake rsync reports out of its --stats block,
  # with the thousands separators PVE's rsync really prints
  printf 'Number of regular files transferred: 161\nLiteral data: 2,469,606,195 bytes\nTotal bytes sent: 2,470,127,483 bytes\n' \
    > "$SIMROOT/rsync.stats"

  printf 'bkp02\n' > "$BKP/node"

  # Two compute nodes of deliberately different shape. local-lvm hands back a
  # block device that has to be mounted; local-zfs hands back a dataset that is
  # already a directory and must never be mounted or unmounted by this engine.
  add_src "$S1" pve01
  add_storage "$S1" local-lvm lvmthin active
  add_src "$S2" pve02
  add_storage "$S2" local-zfs zfspool active
  add_storage "$S2" local-dir dir     active

  # Three containers mid-disaster: distribute placed them, they are running on
  # compute nodes, and their copies on the backup node are stopped and stale.
  add_copy 300 replica-hdd
  add_copy 113 replica-hdd
  add_copy 121 replica-ssd
  place 300 "$S1" pve01 local-lvm  running
  place 113 "$S2" pve02 local-zfs  running

  ln -s "$ENGINE" "$WORK/ct-recall.sh"
  write_conf
  write_nodemap
  inventory "300	replica-hdd" "113	replica-hdd" "121	replica-ssd"
}

# ---------- the compute nodes ----------
add_src(){ # ip nodename
  local d="$SIMROOT/srcs/$1"
  mkdir -p "$d/storage" "$d/vols" "$d/ct"; : > "$d/mounted"
  printf '%s\n' "$2" > "$d/node"
  mkdir -p "$PVE/nodes/$2/lxc"; }
# The status is the WORD pvesm prints - active, inactive or disabled - not a
# boolean. It was a boolean once in ct-distribute, which is how an engine
# comparing the column against 1 passed every scenario and refused every
# storage on the fleet.
add_storage(){ # ip sid type status
  local d="$SIMROOT/srcs/$1/storage"
  case "$4" in active|inactive|disabled) ;;
    *) echo "add_storage: status must be active|inactive|disabled, got '$4'" >&2; exit 2;; esac
  printf '%s\n' "$3" > "$d/$2.type"
  printf '%s\n' "$4" > "$d/$2.status"; }
storage_set(){ printf '%s\n' "$4" > "$SIMROOT/srcs/$1/storage/$2.$3"; }
src_down(){ : > "$SIMROOT/srcs/$1/.down"; }
no_backup_ssh(){ : > "$SIMROOT/srcs/$1/.nobkpssh"; }
bkp_down(){ : > "$BKP/.down"; }
mount_fails(){ : > "$SIMROOT/srcs/$1/mount.fail"; }

# What ct-distribute.sh left behind: a 9<id> config in pmxcfs carrying the
# marker that says which copy it came out of, a volume on that node's storage,
# and some content that only exists because the container has been serving
# customers since the outage.
place(){ # src_ctid ip node storage status [marker-ctid] [marker-copy]
  local ct="$1" ip="$2" node="$3" sid="$4" st="$5"
  local dr=$(( ct + 9000 )) copy=$(( ct + 8000 )) vol
  local mct="${6:-$ct}" mcopy="${7:-$copy}"
  case "$(cat "$SIMROOT/srcs/$ip/storage/$sid.type")" in
    lvmthin|lvm)  vol="vm-$dr-disk-0";;
    dir|nfs|cifs) vol="vm-$dr-disk-0.raw";;
    zfspool)      vol="subvol-$dr-disk-0";;
  esac
  mkdir -p "$SIMROOT/srcs/$ip/vols/$sid/$vol"
  printf '%s\n' "$(cat "$SIMROOT/srcs/$ip/storage/$sid.type")" \
    > "$SIMROOT/srcs/$ip/vols/$sid/.$vol.type"
  printf 'rootfs of CT %s, generation 9 - written on %s during the outage\n' "$ct" "$node" \
    > "$SIMROOT/srcs/$ip/vols/$sid/$vol/rootfs.txt"
  printf 'orders taken while the storage node was down\n' \
    > "$SIMROOT/srcs/$ip/vols/$sid/$vol/dr.log"
  printf '%s\n' "$st" > "$SIMROOT/srcs/$ip/ct/$dr.status"
  { printf 'arch: amd64\nhostname: ct%s.example\nmemory: 2048\n' "$ct"
    printf 'rootfs: %s:%s,size=20G\nonboot: 0\n' "$sid" "$vol"
    printf 'net0: name=eth0,bridge=vmbr0,hwaddr=BC:24:11:00:00:%02d\n' "$(( ct % 100 ))"
    printf '# ct-distribute: temporary DR copy of CT %s, from %s on bkp02\n' "$mct" "$mcopy"
  } > "$PVE/nodes/$node/lxc/$dr.conf"
  # A zfspool volume is the storage's own mount - the engine never mounts it
  # and must never unmount it, so the world declares it mounted from the start.
  [[ "$(cat "$SIMROOT/srcs/$ip/storage/$sid.type")" == zfspool ]] \
    && add_mount "$SIMROOT/srcs/$ip/vols/$sid/$vol" "$ip" "$SIMROOT/srcs/$ip/vols/$sid/$vol" own
  # A RUNNING container has its rootfs mounted already, by LXC, and the host
  # reaches that mount through the container's mount namespace. That mount is
  # the only one there will ever be for this device - which is the whole point
  # of the running branch of C6 - so the world holds it the same way, with the
  # volume's directory standing in for what is behind /proc/<pid>/root.
  if [[ "$st" == running ]]; then
    printf '%s\n' "$(( 4000 + dr % 1000 ))" > "$SIMROOT/srcs/$ip/ct/$dr.pid"
    mkdir -p "$SIMROOT/srcs/$ip/vols/$sid/$vol/etc"
    add_mount "/proc/$(( 4000 + dr % 1000 ))/root" "$ip" "$SIMROOT/srcs/$ip/vols/$sid/$vol" own
  fi
  return 0; }
# The marker line is the only thing that says which side is newer. A scenario
# can strip it, or make it name a different container, and the engine has to
# refuse both rather than guess a direction.
no_marker(){ # src_ctid node
  local f="$PVE/nodes/$2/lxc/$(( $1 + 9000 )).conf"
  grep -v '^# ct-distribute:' "$f" > "$f.n" && mv -f "$f.n" "$f"; }
dr_state(){ # src_ctid ip status
  printf '%s\n' "$3" > "$SIMROOT/srcs/$2/ct/$(( $1 + 9000 )).status"; }
unplace(){ # src_ctid node - distribute never ran for this one
  rm -f "$PVE/nodes/$2/lxc/$(( $1 + 9000 )).conf"; }

# ---------- the backup node ----------
# A DR copy: its status and its dataset, which is where this engine writes.
add_copy(){ # src_ctid dest-storage-id
  local id=$(( $1 + 8000 )) ds
  case "$2" in
    replica-hdd|replica-ssd) ds="$2/ct/subvol-$id-disk-0";;
    *) echo "add_copy: dest must be a storage id like replica-hdd, got '$2'" >&2; exit 2;;
  esac
  printf 'stopped\n' > "$BKP/ct/$id.status"
  printf '%s\tyes\t/%s\n' "$ds" "$ds" >> "$BKP/zfs.tsv"
  mkdir -p "$BKP/fs/$ds"
  printf 'rootfs of CT %s, generation 7 - the last replica round before the outage\n' "$1" \
    > "$BKP/fs/$ds/rootfs.txt"
  printf 'this file only ever existed on the copy\n' > "$BKP/fs/$ds/stale.log"; }
copy_state(){ printf '%s\n' "$2" > "$BKP/ct/$1.status"; }
copy_unmounted(){ # the dataset exists over there but is not mounted
  awk -F'\t' -v n="$1" '$1==n{$2="no"}1' OFS='\t' "$BKP/zfs.tsv" > "$BKP/.z"
  mv -f "$BKP/.z" "$BKP/zfs.tsv"; }

# ---------- the locks, on the machines that hold each end ----------
bkp_lock(){ mkdir -p "$BKP/run"; printf '%s\n' "$2" > "$BKP/run/ketsync-ct-$1.lock"; }
src_lock(){ mkdir -p "$SIMROOT/srcs/$1/run"
            printf '%s\n' "$3" > "$SIMROOT/srcs/$1/run/ketsync-ct-$2.lock"; }
bkp_lock_steal(){ printf '%s\n' "$1" > "$BKP/lock.steal"; }
bkp_lock_unreachable(){ : > "$BKP/lock.fail"; }
src_lock_unreachable(){ : > "$SIMROOT/srcs/$1/lock.fail"; }
bkp_lock_held(){ [[ -f "$BKP/run/ketsync-ct-$1.lock" ]] \
                   || _err "the copy lock for $1 is gone from the backup node"; }
bkp_lock_free(){ [[ -f "$BKP/run/ketsync-ct-$1.lock" ]] \
                   && _err "the copy lock for $1 was left behind: $(cat "$BKP/run/ketsync-ct-$1.lock")"
                 return 0; }
src_lock_free(){ [[ -f "$SIMROOT/srcs/$1/run/ketsync-ct-$2.lock" ]] \
                   && _err "the 9<id> lock for $2 was left on $1"
                 return 0; }
lock_owner(){ grep -qF -- "$2" "$BKP/run/ketsync-ct-$1.lock" 2>/dev/null \
                || _err "the copy lock for $1 no longer says '$2'"; }

# ---------- what the engine reads out of its own folder ----------
write_conf(){
  cat > "$WORK/ctrep.conf" <<EOF
BKP_SSH="root@$BKP_HOST"
BKP_DESTS="replica-hdd:replica-hdd/ct replica-ssd:replica-ssd/ct"
OFFSET=8000
DR_OFFSET=9000
BW_TOTAL_MB=230
LANES=1
BW_MIN_MB=20
EOF
}
conf_set(){ { grep -v "^$1=" "$WORK/ctrep.conf" || true; } > "$WORK/.c"
            mv -f "$WORK/.c" "$WORK/ctrep.conf"
            printf '%s=%s\n' "$1" "$2" >> "$WORK/ctrep.conf"; return 0; }
write_nodemap(){ printf '# ip\tpve node name\n%s\tpve01\n%s\tpve02\n' "$S1" "$S2" > "$WORK/nodes.map"; }
no_nodemap(){ rm -f "$WORK/nodes.map"; }
inventory(){ printf '%s\n' "$@" > "$WORK/inventory-replica.tsv"; }
rsync_rc(){  printf '%s\n' "$1" > "$SIMROOT/rsync.rc"; }

run_engine(){
  ( export SIMROOT SIMLIB SIMBIN SIM_BKP_HOST SIMWORK="$WORK"
    SIM_DRY=0
    for _a in "$@"; do [[ "$_a" == --dry-run ]] && SIM_DRY=1; done
    export SIM_DRY
    ssh(){ "$SIMBIN/ssh" "$@"; }
    export -f ssh
    "${ENGINE_PATH:-$WORK/ct-recall.sh}" "$@" ) > "$SIMROOT/out" 2>&1
  RC=$?
  OUT="$(cat "$SIMROOT/out")"
  TRACE="$(cat "$SIMROOT/trace")"
  VIO="$(cat "$SIMROOT/violations")"
}

# ---------- assertions ----------
_err(){ echo "      x $*"; SFAIL=1; }
has(){    grep -qF -- "$1" <<<"$OUT" || _err "expected in log: $1"; }
hasnt(){  grep -qF -- "$1" <<<"$OUT" && _err "should NOT be in log: $1"; return 0; }
traced(){ grep -qF -- "$1" <<<"$TRACE" || _err "command should have run: $1"; }
untraced(){ grep -qF -- "$1" <<<"$TRACE" && _err "command must NOT have run: $1"; return 0; }
rc_is(){ [[ "$RC" == "$1" ]] || _err "exit code $RC, expected $1"; }
clean(){ [[ -z "$VIO" ]] || { _err "INVARIANT BROKEN:"; sed 's/^/         /' <<<"$VIO"; }; return 0; }
# The log has to land in the engine's OWN logs/, because a sandbox has no
# ketsync above it. The engine walks two directories up when - and only when -
# it finds a dispatcher there, so a sandbox exercises the guarded path.
log_lands_here(){
  local g=( "$WORK/logs/$1"*.log )
  [[ -e "${g[0]}" ]] || _err "no log file under $WORK/logs matching $1*.log"
  [[ -d "$WORK/../logs" ]] && _err "the engine wrote a logs/ OUTSIDE its own tree"
  return 0
}
# what actually landed in the copy's dataset on the backup node
copy_has(){ # copy_vmid dest text
  grep -rqF -- "$3" "$BKP/fs/$2/ct/subvol-$1-disk-0" 2>/dev/null \
    || _err "copy $1 does not contain '$3'"; }
copy_hasnt(){ grep -rqF -- "$3" "$BKP/fs/$2/ct/subvol-$1-disk-0" 2>/dev/null \
    && _err "copy $1 must NOT contain '$3'"; return 0; }
nothing_mounted(){ local m
  m="$(awk -F'\t' '$3!="own"' "$SIMROOT"/srcs/*/mounted 2>/dev/null)"
  [[ -z "$m" ]] || _err "still mounted after the run: $m"; return 0; }
# The top-level keys are written with a space after the colon and the ones
# inside "last" are not, because that object is appended verbatim to the
# history file where every byte is a line. Match either.
state_says(){ # ctid key value
  grep -qE -- "\"$2\": ?\"$3\"" "$WORK/state/recall-$1.json" 2>/dev/null \
    || _err "state for $1: expected $2 = $3, got: $(tr '\n' ' ' < "$WORK/state/recall-$1.json" 2>/dev/null)"; }

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

echo "=== ct-recall.sh simulator ==="

# ---------------------------------------------------------------- happy paths
if scenario "1: the happy path - a block-backed 9<id> comes back into its copy"; then
  run_engine --ctid 300
  rc_is 0; clean
  has "plan: CT 9300 on pve01 ($S1)  ->  copy 8300 on bkp02"
  has "source   local-lvm (lvmthin, block), volume local-lvm:vm-9300-disk-0, CT is running"
  has "dest     replica-hdd/ct/subvol-8300-disk-0 mounted at /replica-hdd/ct/subvol-8300-disk-0"
  has "[300] OK -> 8300 (rc=0)"
  copy_has 8300 replica-hdd "generation 9"
  copy_hasnt 8300 replica-hdd "this file only ever existed on the copy"
  nothing_mounted
  log_lands_here recall
  done_scenario
fi

if scenario "2: a zfspool 9<id> is read where it already lives, never mounted"; then
  # The dataset is the storage's own mount. Mounting it would be a second mount
  # of a live filesystem and unmounting it would take the container offline.
  run_engine --ctid 113
  rc_is 0; clean
  has "source   local-zfs (zfspool, dataset)"
  has "[113] OK -> 8113 (rc=0)"
  untraced "mount -o"
  untraced "umount"
  copy_has 8113 replica-hdd "generation 9"
  done_scenario
fi

if scenario "3: --all does every container that has a live 9<id>"; then
  run_engine --all
  rc_is 1; clean            # 121 was never placed, which --all must not hide
  has "[300] OK -> 8300"
  has "[113] OK -> 8113"
  has "GUARD C1: no CT 9121 anywhere in this cluster"
  has "=== recall finished: ok=2 skipped=1 failed=0 ==="
  done_scenario
fi

if scenario "4: a RUNNING container's device is never mounted a second time"; then
  # LXC already has it mounted read-write. ext4 refuses to add a read-only
  # mount of the same device - "Can't mount, would change RO state" - and the
  # only way to make it succeed is a second rw mount, which is two kernels
  # writing one journal. So this engine reads the container's own mount, and
  # the fake records a violation for anything else.
  run_engine --ctid 300
  rc_is 0; clean
  untraced "mount -o"
  traced "lxc-info -n 9300"
  has "[300] OK -> 8300 (rc=0)"
  copy_has 8300 replica-hdd "generation 9"
  nothing_mounted
  done_scenario
fi

if scenario "4b: a STOPPED container's device IS mounted, read-only with noload"; then
  # Nobody has it now, so the device is this engine's to mount - and replaying
  # a journal that was not cleanly closed is a write into the one copy of the
  # customer's data, so noload is not optional.
  dr_state 300 "$S1" stopped
  run_engine --ctid 300 --final
  rc_is 0; clean
  traced "mount -o ro,noload"
  untraced "lxc-info"
  nothing_mounted
  done_scenario
fi

if scenario "5: rsync carries --delete, so the copy stops holding what the DR deleted"; then
  run_engine --ctid 300
  rc_is 0; clean
  copy_hasnt 8300 replica-hdd "this file only ever existed on the copy"
  done_scenario
fi

# ---------------------------------------------------------------- C1
if scenario "6: C1 a container ct-distribute never placed is skipped, not invented"; then
  unplace 300 pve01
  run_engine --ctid 300
  rc_is 1; clean
  has "GUARD C1: no CT 9300 anywhere in this cluster - nothing to recall"
  has "the newest data for CT 300 is still the copy"
  untraced "rsync"
  done_scenario
fi

if scenario "7: C1 finds the holder by asking the cluster, not from an argument"; then
  # The container was placed on pve02, not on the node anybody would guess. One
  # `ls` through the backup node names it, because pmxcfs is cluster-shared.
  unplace 300 pve01
  place 300 "$S2" pve02 local-zfs running
  run_engine --ctid 300
  rc_is 0; clean
  has "plan: CT 9300 on pve02 ($S2)"
  copy_has 8300 replica-hdd "generation 9"
  done_scenario
fi

if scenario "8: C1 a node with no row in nodes.map is named, never guessed at"; then
  no_nodemap
  run_engine --ctid 300
  rc_is 1; clean
  has "nothing maps that to an address"
  has "ketsync doctor"
  untraced "rsync"
  done_scenario
fi

# ---------------------------------------------------------------- C3
if scenario "9: C3 a 9<id> with no provenance marker is refused, not guessed at"; then
  # Without the marker there is nothing that says which side is newer, and this
  # engine writes with --delete. mtimes cannot answer it: rsync preserves them,
  # so the copy's files can be newer on disk while holding older data.
  no_marker 300 pve01
  run_engine --ctid 300
  rc_is 1; clean
  has "GUARD C3: CT 9300 on pve01 does not say it came from copy 8300"
  has "# ct-distribute: temporary DR copy of CT 300, from 8300 on bkp02"
  has "destroys every hour of work since the outage began"
  untraced "rsync"
  copy_has 8300 replica-hdd "generation 7"
  done_scenario
fi

if scenario "10: C3 a marker naming a DIFFERENT container is refused"; then
  # A 9300 whose config says it came out of some other customer's copy is not a
  # 9300 this engine may write back, whatever the number in front says.
  unplace 300 pve01
  place 300 "$S1" pve01 local-lvm running 999 8999
  run_engine --ctid 300
  rc_is 1; clean
  has "GUARD C3"
  untraced "rsync"
  done_scenario
fi

# ---------------------------------------------------------------- C4
if scenario "11: C4 a stopped 9<id> without --final is refused, and told what to type"; then
  # "it happens to be down right now" and "we are cutting over" are different
  # intentions, and reading a stopped rootfs as if it were the last delta is
  # how a cutover happens by accident.
  dr_state 300 "$S1" stopped
  run_engine --ctid 300
  rc_is 1; clean
  has "GUARD C4: presync expects CT 9300 RUNNING (it is 'stopped')"
  has "--ctid 300 --final"
  untraced "rsync"
  done_scenario
fi

if scenario "12: C4 --final on a RUNNING 9<id> is refused"; then
  # The last delta is the one that gets started from, so it has to be
  # consistent. A live rootfs cannot be.
  run_engine --ctid 300 --final
  rc_is 1; clean
  has "GUARD C4: --final needs CT 9300 STOPPED (it is 'running')"
  has "pct shutdown 9300"
  untraced "rsync"
  done_scenario
fi

if scenario "13: C4 --final on a stopped 9<id> runs, and prints the unwind for a human"; then
  dr_state 300 "$S1" stopped
  run_engine --ctid 300 --final
  rc_is 0; clean
  has "[300] OK -> 8300"
  has "FINAL round done. Copy 8300 on bkp02 now holds the newest data."
  has "pct destroy 9300"
  has "pct set 300 --onboot 1"
  copy_has 8300 replica-hdd "generation 9"
  done_scenario
fi

if scenario "14: C4 a compute node that will not answer is refused, not assumed"; then
  src_down "$S1"
  run_engine --ctid 300
  rc_is 1; clean
  has "GUARD C4"
  has "unverified is not a state"
  untraced "rsync"
  done_scenario
fi

if scenario "15: C4 there is no PAUSE requirement - R13 covers the whole window"; then
  # ct-failback's --final needs PAUSE because R2 stops shielding the moment the
  # copy goes down. R13 keys on the 9<id> CONFIG, which is still there while it
  # is stopped, so it holds through the shutdown and until somebody destroys it.
  dr_state 300 "$S1" stopped
  run_engine --ctid 300 --final
  rc_is 0; clean
  hasnt "PAUSE"
  has "R13 keys on CT 9300's config"
  done_scenario
fi

# ---------------------------------------------------------------- C2
if scenario "16: C2 a copy somebody promoted is not overwritten"; then
  # Two containers taking customer writes, neither mergeable into the other.
  # Which one is real is a decision for a human.
  copy_state 8300 running
  run_engine --ctid 300
  rc_is 1; clean
  has "GUARD C2: copy 8300 is RUNNING on bkp02 - refusing to write into it"
  untraced "rsync"
  copy_has 8300 replica-hdd "generation 7"
  done_scenario
fi

# ---------------------------------------------------------------- C5
if scenario "17: C5 an unmounted destination dataset refuses before anything moves"; then
  # An unmounted dataset is an ordinary empty directory. Writing there fills the
  # backup node's root filesystem and leaves the copy looking present and empty.
  copy_unmounted replica-hdd/ct/subvol-8300-disk-0
  run_engine --ctid 300
  rc_is 1; clean
  has "GUARD C5: replica-hdd/ct/subvol-8300-disk-0 on bkp02 is not a mounted dataset"
  has "zfs mount -a"
  untraced "rsync"
  done_scenario
fi

if scenario "18: a row with no dest refuses the whole run, and names the line"; then
  # There is no DEFAULT_DEST any more. A row that does not say which pool its
  # copy is on used to land on whichever pool that variable named, and the row
  # that forgot looked exactly like the row that meant it.
  inventory "300" "113	replica-hdd"
  run_engine --ctid 300
  rc_is 2
  has "line 1: CT 300 has no dest column"
  has "Every row names its pool"
  untraced "rsync"
  done_scenario
fi

# ---------------------------------------------------------------- C6
if scenario "19: C6 a dataset that is not really mounted refuses before rsync"; then
  # zfspool is the one shape this engine does not mount itself, so it is the one
  # shape where an unmounted volume reaches rsync as an ordinary directory.
  del_mount "$SIMROOT/srcs/$S2/vols/local-zfs/subvol-9113-disk-0" "$S2"
  run_engine --ctid 113
  rc_is 1; clean
  has "GUARD C6"
  has "is not a mountpoint"
  untraced "rsync"
  done_scenario
fi

if scenario "20: C6 a mount that fails refuses, and nothing is transferred"; then
  # Only the stopped path mounts anything, so this is the stopped path.
  dr_state 300 "$S1" stopped
  mount_fails "$S1"
  run_engine --ctid 300 --final
  rc_is 1; clean
  has "GUARD C6: could not mount"
  untraced "rsync"
  nothing_mounted
  done_scenario
fi

if scenario "21: C6 a dir-backed volume is loop-mounted, a block one is not"; then
  # The one word of difference between the two read shapes, and it only comes
  # up on the stopped path - a running container's file is already loop-mounted
  # by LXC and this engine reads that mount instead.
  unplace 300 pve01
  place 300 "$S2" pve02 local-dir stopped
  run_engine --ctid 300 --final
  rc_is 0; clean
  traced "mount -o loop,ro,noload"
  nothing_mounted
  done_scenario
fi

if scenario "22: a storage type this engine does not know is refused by name"; then
  storage_set "$S1" local-lvm type btrfs
  run_engine --ctid 300
  rc_is 1; clean
  has "type 'btrfs', which this engine does not know"
  has "lvmthin, lvm, dir, nfs and zfspool"
  untraced "rsync"
  done_scenario
fi

if scenario "23: an INACTIVE source storage is refused - it reads as an empty directory"; then
  storage_set "$S1" local-lvm status inactive
  run_engine --ctid 300
  rc_is 1; clean
  has "is not ACTIVE on pve01 (pvesm says 'inactive')"
  has "--delete on the"
  untraced "rsync"
  done_scenario
fi

# ---------------------------------------------------------------- the transfer
if scenario "24: the compute node not being able to reach the backup node refuses first"; then
  # The transfer is issued there and pushes. Finding this out afterwards means
  # a mount left behind on a compute node during a DR.
  no_backup_ssh "$S1"
  run_engine --ctid 300
  rc_is 1; clean
  has "cannot ssh root@$BKP_HOST"
  has "ssh-copy-id"
  untraced "rsync"
  nothing_mounted
  done_scenario
fi

if scenario "25: rsync 24 is success - a live container deletes its own temp files"; then
  rsync_rc 24
  run_engine --ctid 300
  rc_is 0; clean
  has "[300] OK -> 8300 (rc=24)"
  done_scenario
fi

if scenario "26: a failed transfer says the copy is part written and the DR is untouched"; then
  rsync_rc 23
  run_engine --ctid 300
  rc_is 1; clean
  has "transfer failed rc=23 - copy 8300 is now PART WRITTEN"
  has "CT 9300 still holds the newest data and is untouched"
  nothing_mounted
  done_scenario
fi

if scenario "27: the mount comes down even when the transfer fails"; then
  rsync_rc 23
  run_engine --ctid 300
  rc_is 1
  nothing_mounted
  done_scenario
fi

if scenario "28: the stats rsync printed reach the log and the state file"; then
  run_engine --ctid 300
  rc_is 0; clean
  has "changed=2.2GiB files=161"
  state_says 300 status ok
  state_says 300 tool recall
  done_scenario
fi

# ---------------------------------------------------------------- C7
if scenario "29: C7 nothing is started, stopped or destroyed - the commands are printed"; then
  dr_state 300 "$S1" stopped
  run_engine --ctid 300 --final
  rc_is 0; clean          # the fake records a violation for any pct lifecycle call
  has "pct destroy 9300"
  has "Nothing here does either"
  done_scenario
fi

# ---------------------------------------------------------------- C8
if scenario "30: C8 both ends are locked for the transfer, then both are released"; then
  run_engine --ctid 300
  rc_is 0; clean
  traced "src lock take $S1 /run/ketsync-ct-9300.lock"
  traced "bkp lock take /run/ketsync-ct-8300.lock"
  traced "src lock release $S1 /run/ketsync-ct-9300.lock"
  traced "bkp lock release /run/ketsync-ct-8300.lock"
  src_lock_free "$S1" 9300; bkp_lock_free 8300
  done_scenario
fi

if scenario "31: C8 the 9<id> is locked BEFORE the copy, always in that order"; then
  # This is the only engine that holds two locks, so it fixes the order. The
  # other three take exactly one each, and one fixed order means no cycle.
  run_engine --ctid 300
  rc_is 0; clean
  [[ "$(grep -nE 'src lock take|bkp lock take' <<<"$TRACE" | head -1)" == *"src lock take"* ]] \
    || _err "the copy on the backup node was locked before the 9<id> on the compute node"
  done_scenario
fi

if scenario "32: C8 a 9<id> another run is holding is skipped, and its lock left alone"; then
  src_lock "$S1" 9300 "distribute bkp02 pid 4211 started 2026-08-12 03:14:00"
  run_engine --ctid 300
  rc_is 1; clean
  has "GUARD C8: CT 9300 is locked on pve01 by another run"
  has "holder: distribute bkp02 pid 4211"
  untraced "rsync"
  untraced "bkp lock take"        # the second lock is never reached
  done_scenario
fi

if scenario "33: C8 a copy ct-replica is holding is skipped, and the 9<id> lock released"; then
  # ct-replica and ct-failback take this same lock. Losing the second one must
  # release the first, or the next round finds a 9<id> nobody is using locked.
  bkp_lock 8300 "replica nfs01 pid 4211 started 2026-08-12 03:14:00"
  run_engine --ctid 300
  rc_is 1; clean
  has "GUARD C8: copy 8300 is locked on bkp02 by another run"
  has "ct-replica and ct-failback take this same lock"
  untraced "rsync"
  src_lock_free "$S1" 9300
  bkp_lock_held 8300; lock_owner 8300 "replica nfs01 pid 4211"
  done_scenario
fi

if scenario "34: C8 an end that does not answer is refused, never assumed free"; then
  bkp_lock_unreachable
  run_engine --ctid 300
  rc_is 1; clean
  has "GUARD C8: could not take copy 8300 on bkp02"
  has "no answer is not 'nobody has it'"
  untraced "rsync"
  src_lock_free "$S1" 9300
  done_scenario
fi

if scenario "35: C8 the same holds for the compute end"; then
  src_lock_unreachable "$S1"
  run_engine --ctid 300
  rc_is 1; clean
  has "GUARD C8: could not take CT 9300 on pve01"
  untraced "rsync"
  done_scenario
fi

if scenario "36: C8 both locks come off when a later step fails"; then
  rsync_rc 23
  run_engine --ctid 300
  rc_is 1
  src_lock_free "$S1" 9300; bkp_lock_free 8300
  done_scenario
fi

if scenario "37: C8 a lock that stopped being ours is left where it is"; then
  bkp_lock_steal "failback nfs01 pid 7788 started 2026-08-12 04:00:00"
  run_engine --ctid 300
  rc_is 0; clean
  traced "bkp lock stolen /run/ketsync-ct-8300.lock"
  bkp_lock_held 8300; lock_owner 8300 "failback nfs01 pid 7788"
  done_scenario
fi

if scenario "38: C8 one blocked container does not stop the rest of the batch"; then
  bkp_lock 8300 "replica nfs01 pid 4211 started 2026-08-12 03:14:00"
  run_engine --all
  rc_is 1; clean
  has "GUARD C8: copy 8300 is locked"
  hasnt "GUARD C8: copy 8113 is locked"
  copy_has 8113 replica-hdd "generation 9"
  done_scenario
fi

# ---------------------------------------------------------------- --list, --dry-run
if scenario "39: --list reports the plan and touches nothing"; then
  run_engine --ctid 300 --list
  rc_is 0; clean
  has "plan: CT 9300 on pve01"
  untraced "rsync"
  untraced "src lock take"
  untraced "mount -o"
  copy_has 8300 replica-hdd "generation 7"
  done_scenario
fi

if scenario "40: --dry-run runs every guard and writes nothing at all"; then
  # Every fake that writes calls dry_forbids, so a write added two months from
  # now is caught the first time it runs rather than the first time somebody
  # thinks to assert on it.
  run_engine --all --dry-run
  clean
  has "DRY: would rsync"
  has "DRY: nothing was written"
  untraced "rsync"; untraced "mount -o"; untraced "src lock take"
  copy_has 8300 replica-hdd "generation 7"
  done_scenario
fi

if scenario "41: --dry-run reports a lock it cannot take, on either end"; then
  bkp_lock 8300 "replica nfs01 pid 900 started 2026-08-12 02:00:00"
  run_engine --ctid 300 --dry-run
  rc_is 1; clean
  has "GUARD C8: DRY: copy 8300 is locked on bkp02 - a real run would skip it"
  untraced "bkp lock take"
  lock_owner 8300 "pid 900"
  done_scenario
fi

# ---------------------------------------------------------------- the plumbing
if scenario "42: a --ctid with no row in the inventory refuses the run"; then
  run_engine --ctid 777
  rc_is 2
  has "no row in"
  has "A container with no copy has nowhere to come back to"
  done_scenario
fi

if scenario "43: no mode at all is a usage error, not a fleet-wide run"; then
  run_engine
  rc_is 2
  has "usage: ct-recall.sh"
  done_scenario
fi

if scenario "44: a flag whose value is missing is refused, not spun on forever"; then
  run_engine --ctid
  rc_is 2
  has "--ctid needs a value"
  done_scenario
fi

if scenario "45: a backup node that cannot be reached at all refuses the whole run"; then
  bkp_down
  run_engine --all
  rc_is 2
  has "cannot read the PVE node identity"
  untraced "rsync"
  done_scenario
fi

if scenario "46: --help prints the whole header, exit-code contract included"; then
  run_engine --help
  rc_is 0
  has "THE GUARDS (C1..C8)"
  has "exit code: 0 = all ok"
  done_scenario
fi

if scenario "47: a non-integer in ctrep.conf refuses before anything runs"; then
  conf_set DR_OFFSET '"nine thousand"'
  run_engine --ctid 300
  rc_is 2
  has "DR_OFFSET must be a plain integer"
  done_scenario
fi

if scenario "48: vendored under a ketsync, its nodes.map wins over the copy beside the engine"; then
  # The copy this replaced was refreshed by `ketsync doctor` and by nothing
  # else, so a machine that had been SENT the tables was still reading a file
  # nobody had written.
  REPO="$SIMROOT/repo"
  mkdir -p "$REPO/engines/tp" "$REPO/lib"
  : > "$REPO/ketsync"; : > "$REPO/lib/common.sh"
  cp "$WORK/ctrep.conf" "$WORK/inventory-replica.tsv" "$REPO/engines/tp/"
  mkdir -p "$REPO/engines/tp/state"
  ln -s "$ENGINE" "$REPO/engines/tp/ct-recall.sh"
  printf '# ip\tpve node name\n10.100.9.99\tpve01\n' > "$REPO/engines/tp/nodes.map"
  cp "$WORK/nodes.map" "$REPO/nodes.map"
  ENGINE_PATH="$REPO/engines/tp/ct-recall.sh" run_engine --ctid 300 --list
  clean
  hasnt "10.100.9.99"
  done_scenario
fi

if scenario "49: the OLD BKP_DESTS format is named, not read as a working map"; then
  conf_set BKP_DESTS '"hdd=replica-hdd/ct:replica-hdd ssd=replica-ssd/ct:replica-ssd"'
  run_engine --ctid 300
  rc_is 2
  has "is the OLD key=dataset:storage-id form"
  has 'BKP_DESTS="replica-hdd:replica-hdd/ct replica-ssd:replica-ssd/ct"'
  untraced "rsync"
  done_scenario
fi

if scenario "51: C6 a container root that is not one refuses before rsync"; then
  # The pid answered, the path exists, and there is nothing behind it - a
  # container that died between the status check and this one, or a pid that
  # was reused. Reading it and then running --delete on the far end empties
  # the copy to match an empty directory.
  del_mount "/proc/4300/root" "$S1"
  run_engine --ctid 300
  rc_is 1; clean
  has "GUARD C6"
  has "does not look like a root filesystem"
  untraced "rsync"
  done_scenario
fi

echo
echo "=== $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then echo "failed: ${FAILED_NAMES[*]}"; exit 1; fi
exit 0
