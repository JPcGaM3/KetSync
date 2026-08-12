#!/usr/bin/env bash
# =============================================================================
#  run-sim-distribute.sh — execute ct-distribute.sh against a fake cluster.
# -----------------------------------------------------------------------------
#  Why this exists: this engine only ever runs during the worst hour this fleet
#  will have, on machines whose containers are down and whose customers are
#  waiting. There is no second chance to find out that a guard moved.
#
#  It is also the only engine here that runs on NEITHER end of its own
#  transfer, so the failures it can produce are different in kind: a volume
#  allocated on a machine that then could not be reached, a config written for
#  a container nobody filled, an rsync into a directory that was never a
#  mountpoint. The fake refuses to pretend about each of those and records a
#  VIOLATION instead:
#
#    - pvesm alloc into a storage PVE says is INACTIVE   (D4: fills the root fs)
#    - mkfs on a device something already mounted        (D3/G3: destroys it)
#    - rsync into a path that is not a mountpoint        (D4: fills the root fs)
#    - a config written before a good transfer           (D6: empty container)
#    - pct start, anywhere, ever                         (D7)
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
#  usage:  ./tests/sim/distribute/run-sim-distribute.sh          every scenario
#          ./tests/sim/distribute/run-sim-distribute.sh 7        scenario 7 only
#          KEEP=1 ./tests/sim/distribute/run-sim-distribute.sh 7 keep the sandbox
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
ENGINE="${ENGINE:-$ROOT/ct-distribute.sh}"

if [[ ! -f "$ENGINE" ]]; then
  echo "engine not found: $ENGINE" >&2; exit 2
elif [[ ! -x "$ENGINE" ]]; then
  echo "engine is not executable: $ENGINE" >&2
  echo "  every scenario would die with exit 126. fix it with:  chmod +x $ENGINE" >&2
  exit 2
fi
ONLY="${1:-}"
PASS=0; FAIL=0; FAILED_NAMES=()

BKP_HOST=100.100.100.35
T1=10.100.1.32          # a compute node with local-lvm
T2=10.100.1.33          # a second one, deliberately of a different shape

new_world(){
  SIMROOT="$(mktemp -d /tmp/ctdist-sim.XXXXXX)"
  export SIMROOT SIMLIB="$HERE/lib.sh" SIMBIN="$HERE/bin" SIM_BKP_HOST="$BKP_HOST"
  WORK="$SIMROOT/work"; BKP="$SIMROOT/bkp"; PVE="$SIMROOT/pve"
  mkdir -p "$WORK/state" "$WORK/logs" "$BKP/ct" "$BKP/data" "$PVE/nodes" "$SIMROOT/nodes"
  : > "$SIMROOT/violations"; : > "$SIMROOT/trace"; : > "$BKP/zfs.tsv"
  echo 0 > "$SIMROOT/rsync.rc"

  printf 'bkp02\n' > "$BKP/node"

  # Two production nodes that are DOWN, because that is the situation: the
  # storage node died and took their images with it. One scenario brings one
  # back up, which is what D1 is for.
  add_prod_node pve01; add_prod_node pve02
  node_down pve01; node_down pve02

  # Two compute targets of deliberately different shape. local-lvm hands back a
  # block device; local-zfs hands back a dataset that is already a directory
  # and needs neither mkfs nor mount. Both are real, and the engine has to
  # handle them without a branch anywhere except dst_shape().
  add_target "$T1" pve01
  add_storage "$T1" local-lvm  lvmthin active $(( 200 * 1024 * 1024 ))
  add_target "$T2" pve02
  add_storage "$T2" local-zfs  zfspool active $(( 200 * 1024 * 1024 ))
  add_storage "$T2" local-dir  dir     active $(( 200 * 1024 * 1024 ))

  # Three containers, their copies, and the copies' data.
  add_copy 300 hdd 20G
  add_copy 113 hdd 40G
  add_copy 121 ssd 10G

  ln -s "$ENGINE" "$WORK/ct-distribute.sh"
  write_conf
  write_nodemap
  inventory "300" "113" "121	ssd"
  fleet "300	hdd	10.100.1.31	$T1	local-lvm" "113	hdd	10.100.1.31	$T2	local-zfs"
}

# ---------- the cluster ----------
add_prod_node(){ mkdir -p "$SIMROOT/nodes/$1/ct"; }
node_down(){ : > "$SIMROOT/nodes/$1/.down"; }
node_up(){   rm -f "$SIMROOT/nodes/$1/.down"; }
prod_ct(){   # ctid node status - a production CT that exists in pmxcfs
  mkdir -p "$PVE/nodes/$2/lxc" "$SIMROOT/nodes/$2/ct"
  printf 'arch: amd64\nhostname: ct%s\nrootfs: tank-hdd-nas:%s/vm-%s-disk-0.raw,size=20G\n' "$1" "$1" "$1" \
    > "$PVE/nodes/$2/lxc/$1.conf"
  printf '%s\n' "$3" > "$SIMROOT/nodes/$2/ct/$1.status"; }

add_target(){ # ip nodename
  local d="$SIMROOT/targets/$1"
  mkdir -p "$d/storage" "$d/vols"; : > "$d/mounted"
  printf '%s\n' "$2" > "$d/node"
  mkdir -p "$PVE/nodes/$2/lxc"; }
# The status is the WORD pvesm prints - active, inactive or disabled - not a
# boolean. It was a boolean once, which is how an engine comparing the column
# against 1 passed every scenario here and refused every storage on the fleet.
add_storage(){ # ip sid type status availKiB
  local d="$SIMROOT/targets/$1/storage"
  case "$4" in active|inactive|disabled) ;;
    *) echo "add_storage: status must be active|inactive|disabled, got '$4'" >&2; exit 2;; esac
  printf '%s\n' "$3" > "$d/$2.type"
  printf '%s\n' "$4" > "$d/$2.status"
  printf '%s\n' "$5" > "$d/$2.avail"; }
storage_set(){ printf '%s\n' "$4" > "$SIMROOT/targets/$1/storage/$2.$3"; }
target_down(){ : > "$SIMROOT/targets/$1/.down"; }
no_backup_ssh(){ : > "$SIMROOT/targets/$1/.nobkpssh"; }
bkp_down(){ : > "$BKP/.down"; }

# A DR copy on the backup node: its config in pmxcfs, its status, its dataset
# and some content to move.
add_copy(){ # src_ctid dest size
  local id=$(( $1 + 8000 )) ds
  [[ "$2" == hdd ]] && ds="replica-hdd/ct" || ds="replica-ssd/ct"
  mkdir -p "$PVE/nodes/bkp02/lxc" "$BKP/data/subvol-$id-disk-0"
  printf 'arch: amd64\ncores: 2\nhostname: ct%s.example\nmemory: 2048\nrootfs: %s:subvol-%s-disk-0,size=%s\nonboot: 1\nnet0: name=eth0,bridge=vmbr99,hwaddr=BC:24:11:00:00:%02d,ip=10.100.2.%s/24\n' \
    "$1" "${ds%%/*}" "$id" "$3" "$(( $1 % 100 ))" "$(( $1 % 250 ))" > "$PVE/nodes/bkp02/lxc/$id.conf"
  printf 'stopped\n' > "$BKP/ct/$id.status"
  printf '%s/subvol-%s-disk-0\t%s/mnt/subvol-%s-disk-0\n' "$ds" "$id" "$BKP" "$id" >> "$BKP/zfs.tsv"
  printf 'generation 1\n' > "$BKP/data/subvol-$id-disk-0/marker"
  printf 'customer data for %s\n' "$1" > "$BKP/data/subvol-$id-disk-0/payload"; }
copy_state(){ printf '%s\n' "$2" > "$BKP/ct/$(( $1 + 8000 )).status"; }
copy_gone(){  rm -f "$PVE/nodes/bkp02/lxc/$(( $1 + 8000 )).conf"; }
# somebody else already owns the 9xxx id, on any node in the cluster
foreign_dr(){ mkdir -p "$PVE/nodes/$2/lxc"
              printf 'arch: amd64\nhostname: someone-else\n' > "$PVE/nodes/$2/lxc/$(( $1 + 9000 )).conf"; }

write_conf(){
  cat > "$WORK/ctrep.conf" <<EOF
BKP_SSH="root@$BKP_HOST"
BKP_DESTS="hdd=replica-hdd/ct:replica-hdd ssd=replica-ssd/ct:replica-ssd"
DEFAULT_DEST="hdd"
OFFSET=8000
DR_OFFSET=9000
DR_DST="local-lvm"
DR_HEADROOM_PCT=25
BW_TOTAL_MB=230
LANES=1
BW_MIN_MB=20
EOF
}
conf_set(){ { grep -v "^$1=" "$WORK/ctrep.conf" || true; } > "$WORK/.c"
            mv -f "$WORK/.c" "$WORK/ctrep.conf"
            printf '%s=%s\n' "$1" "$2" >> "$WORK/ctrep.conf"; return 0; }
write_nodemap(){ printf '# ip\tpve node name\n%s\tpve01\n%s\tpve02\n' "$T1" "$T2" > "$WORK/nodes.map"; }
inventory(){ printf '%s\n' "$@" > "$WORK/inventory-replica.tsv"; }
fleet(){     { printf '# ct\ttier\thome\tdr\tdr_storage\n'; printf '%s\n' "$@"; } > "$WORK/fleet.tsv"; }
no_fleet(){  rm -f "$WORK/fleet.tsv"; }
rsync_rc(){  printf '%s\n' "$1" > "$SIMROOT/rsync.rc"; }
truncate_cfg(){ : > "$SIMROOT/cfgwrite.trunc"; }

run_engine(){
  ( export SIMROOT SIMLIB SIMBIN SIM_BKP_HOST SIMWORK="$WORK"
    # Armed from the ENGINE's own arguments, not from a scenario flag, so every
    # scenario that runs it dry is policed whether or not its author thought
    # about it. The fake reads it through dry_forbids in lib.sh.
    SIM_DRY=0
    for _a in "$@"; do [[ "$_a" == --dry-run ]] && SIM_DRY=1; done
    export SIM_DRY
    # The engine owns its PATH (rule 8), so a directory cannot be prepended.
    # An exported function is resolved before PATH and survives the exec.
    ssh(){ "$SIMBIN/ssh" "$@"; }
    export -f ssh
    "$WORK/ct-distribute.sh" "$@" ) > "$SIMROOT/out" 2>&1
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
# The log file has to land in the engine's OWN logs/, because a sandbox has no
# ketsync above it. The engine walks two directories up when - and only when -
# it finds a dispatcher there, so a sandbox exercises the guarded path: an
# engine that walks up unconditionally writes into somebody's home directory on
# a real machine, and one whose fallback is not its own tree scatters a night
# across two places. Neither is visible in stdout, which is why this looks at
# the filesystem.
log_lands_here(){   # $1 = filename prefix
  local g=( "$WORK/logs/$1"*.log )
  [[ -e "${g[0]}" ]] || _err "no log file under $WORK/logs matching $1*.log"
  [[ -d "$WORK/../logs" ]] && _err "the engine wrote a logs/ OUTSIDE its own tree"
  return 0
}
clean(){ [[ -z "$VIO" ]] || { _err "INVARIANT BROKEN:"; sed 's/^/         /' <<<"$VIO"; }; return 0; }
# what actually landed on the target
vol_has(){ # ip sid volname text
  local p="$SIMROOT/targets/$1/vols/$2/$3"
  grep -rqF -- "$4" "$p" 2>/dev/null || _err "$1:$2:$3 does not contain '$4'"; }
vol_exists(){ [[ -e "$SIMROOT/targets/$1/vols/$2/$3" ]] || _err "$1:$2:$3 was not allocated"; }
no_vol(){ [[ -e "$SIMROOT/targets/$1/vols/$2/$3" ]] && _err "$1:$2:$3 should NOT exist"; return 0; }
cfg_exists(){ [[ -f "$PVE/nodes/$1/lxc/$2.conf" ]] || _err "no config $1/lxc/$2.conf"; }
no_cfg(){ [[ -f "$PVE/nodes/$1/lxc/$2.conf" ]] && _err "config $1/lxc/$2.conf should NOT exist"; return 0; }
cfg_has(){ grep -qF -- "$3" "$PVE/nodes/$1/lxc/$2.conf" 2>/dev/null || _err "$1/lxc/$2.conf lacks '$3'"; }
nothing_mounted(){ local m
  m="$(cat "$SIMROOT"/targets/*/mounted 2>/dev/null)"
  [[ -z "$m" ]] || _err "still mounted after the run: $m"; return 0; }

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

echo "=== ct-distribute.sh simulator ==="

if scenario "1: the happy path - a copy lands on a compute node's local-lvm"; then
  run_engine --ctid 300
  rc_is 0; clean
  has "plan: copy 8300 on bkp02  ->  CT 9300 on pve01 ($T1)"
  has "storage  local-lvm (lvmthin, block)"
  vol_exists "$T1" local-lvm vm-9300-disk-0
  cfg_exists pve01 9300
  cfg_has pve01 9300 "rootfs: local-lvm:vm-9300-disk-0,size=20G"
  has "placed: CT 9300 on pve01"
  nothing_mounted
    log_lands_here distribute
done_scenario
fi

if scenario "2: a zfspool target needs neither mkfs nor a mount"; then
  # The whole point of doing this by SHAPE rather than by storage id: a dataset
  # is already a directory. mkfs on one would be a violation, and there is no
  # mountpoint to check because nothing was mounted.
  run_engine --ctid 113
  rc_is 0; clean
  has "storage  local-zfs (zfspool, dataset)"
  untraced "mkfs.ext4"
  vol_has "$T2" local-zfs subvol-9113-disk-0 "customer data for 113"
  cfg_exists pve02 9113
  nothing_mounted
  done_scenario
fi

if scenario "3: the data actually arrives, not just the config"; then
  run_engine --ctid 300
  rc_is 0; clean
  vol_has "$T1" local-lvm vm-9300-disk-0 "customer data for 300"
  vol_has "$T1" local-lvm vm-9300-disk-0 "generation 1"
  done_scenario
fi

if scenario "4: GUARD D1 - a production CT that is still RUNNING refuses the placement"; then
  # The copy carries the production IP and MAC on purpose. Two of them
  # answering at once is worse than the outage being fixed.
  prod_ct 300 pve01 running; node_up pve01
  run_engine --ctid 300
  rc_is 1; clean
  has "GUARD D1: production CT 300 is RUNNING on pve01"
  has "worse than the outage you are fixing"
  untraced "pvesm alloc"
  no_vol "$T1" local-lvm vm-9300-disk-0
  no_cfg pve01 9300
  done_scenario
fi

if scenario "5: D1 lets it through when production is stopped, not merely absent"; then
  prod_ct 300 pve01 stopped; node_up pve01
  run_engine --ctid 300
  rc_is 0; clean
  hasnt "GUARD D1"
  cfg_exists pve01 9300
  done_scenario
fi

if scenario "6: GUARD D2 - a copy that is RUNNING is not copied out of"; then
  copy_state 300 running
  run_engine --ctid 300
  rc_is 1; clean
  has "GUARD D2: copy 8300 is RUNNING on bkp02"
  untraced "pvesm alloc"
  no_cfg pve01 9300
  done_scenario
fi

if scenario "7: GUARD D3 - a 9xxx id somebody else owns refuses, and names them"; then
  foreign_dr 300 pve02
  run_engine --ctid 300
  rc_is 1; clean
  has "GUARD D3: VMID 9300 already belongs to a guest in this cluster"
  has "/etc/pve/nodes/pve02/lxc/9300.conf"
  has "would empty somebody else's rootfs"
  untraced "pvesm alloc"
  done_scenario
fi

if scenario "8: GUARD D4 - an INACTIVE storage refuses before anything is allocated"; then
  storage_set "$T1" local-lvm status inactive
  run_engine --ctid 300
  rc_is 1; clean
  has "GUARD D4: storage 'local-lvm' is not ACTIVE on pve01 (pvesm says 'inactive')"
  has "fills the root disk"
  untraced "pvesm alloc"
  done_scenario
fi

# The third word pvesm can print, and the one this fleet actually has: r32
# carries replica-hdd and replica-ssd as 'disabled', because those storages
# belong to the backup node and are restricted to it. Pointing --dst at one is
# an ordinary 2am mistake, and "not ACTIVE" alone sends you looking for a
# mount that was never supposed to be there. The word pvesm used is quoted
# back for that reason.
if scenario "8b: GUARD D4 - a DISABLED storage is refused, and says which word it got"; then
  storage_set "$T1" local-lvm status disabled
  run_engine --ctid 300
  rc_is 1; clean
  has "GUARD D4: storage 'local-lvm' is not ACTIVE on pve01 (pvesm says 'disabled')"
  untraced "pvesm alloc"
  done_scenario
fi

if scenario "9: GUARD D4 - a storage type nobody has thought about is refused by name"; then
  storage_set "$T1" local-lvm type iscsidirect
  run_engine --ctid 300
  rc_is 1; clean
  has "type 'iscsidirect', which this engine does not know"
  has "mkfs on something that was not a block device"
  untraced "pvesm alloc"
  done_scenario
fi

if scenario "10: GUARD D4 - a storage that does not exist there says which flag to use"; then
  run_engine --ctid 300 --dst nope-lvm
  rc_is 1; clean
  has "GUARD D4: storage 'nope-lvm' does not exist on pve01"
  has "name one that does with --dst"
  done_scenario
fi

if scenario "11: GUARD D5 - not enough room refuses, and says how much short"; then
  # 20G plus 25% headroom needs 25G. Give it 22G.
  storage_set "$T1" local-lvm avail $(( 22 * 1024 * 1024 ))
  run_engine --ctid 300
  rc_is 1; clean
  has "GUARD D5: local-lvm on pve01 has"
  has "a thin pool that fills goes READ-ONLY"
  untraced "pvesm alloc"
  no_vol "$T1" local-lvm vm-9300-disk-0
  done_scenario
fi

if scenario "12: D5 counts the headroom, not just the rootfs"; then
  # 26G is more than 20G and less than 25G+... it is enough. 24G is not.
  storage_set "$T1" local-lvm avail $(( 24 * 1024 * 1024 ))
  run_engine --ctid 300
  rc_is 1; clean
  has "GUARD D5"
  done_scenario
fi

if scenario "13: GUARD D6 - a failed transfer leaves NO config behind"; then
  rsync_rc 23
  run_engine --ctid 300
  rc_is 1; clean
  has "transfer failed rc=23"
  has "the volume is allocated but the config was NOT written"
  has "pvesm free local-lvm:vm-9300-disk-0"
  no_cfg pve01 9300
  nothing_mounted
  done_scenario
fi

if scenario "14: rsync 24 is success - files vanished mid-copy is normal"; then
  rsync_rc 24
  run_engine --ctid 300
  rc_is 0; clean
  has "rsync rc=24"
  cfg_exists pve01 9300
  done_scenario
fi

if scenario "15: GUARD D6 - a config that does not read back is refused, loudly"; then
  truncate_cfg
  run_engine --ctid 300
  rc_is 1; clean
  has "did not read back as what was sent"
  has "a truncated config is PERMANENT"
  done_scenario
fi

if scenario "16: GUARD D7 - nothing is ever started, only printed"; then
  run_engine --ctid 300
  rc_is 0; clean
  untraced "pct start"
  has "start it BY HAND"
  has "pct start 9300"
  done_scenario
fi

if scenario "17: no row in fleet.tsv and no --to is a refusal, not a guess"; then
  run_engine --ctid 121
  rc_is 1; clean
  has "no target - CT 121 has no row in fleet.tsv and no --to was given"
  has "nothing here picks a machine for you"
  untraced "pvesm alloc"
  done_scenario
fi

if scenario "18: --to overrides fleet.tsv on the day the written answer is wrong"; then
  run_engine --ctid 121 --to "$T2" --dst local-zfs
  :
  rc_is 0; clean
  has "CT 9121 on pve02"
  cfg_exists pve02 9121
  done_scenario
fi

if scenario "19: with no fleet.tsv at all, --to and --dst still work"; then
  # tp keeps working when the decision layer above it is not there. That is the
  # whole reason placement arrives as an argument as well as as a file.
  no_fleet
  run_engine --all --to "$T1" --dst local-lvm
  rc_is 0; clean
  cfg_exists pve01 9300
  cfg_exists pve01 9113
  done_scenario
fi

if scenario "20: --dry-run runs every guard and writes NOTHING"; then
  run_engine --ctid 300 --dry-run
  rc_is 0; clean
  has "plan: copy 8300 on bkp02"
  has "DRY: nothing was written"
  untraced "pvesm alloc"; untraced "mkfs.ext4"; untraced "rsync"
  no_vol "$T1" local-lvm vm-9300-disk-0
  no_cfg pve01 9300
  done_scenario
fi

if scenario "21: --dry-run over every row is read-only too"; then
  # The invariant, not an assertion: every fake that would change the fleet
  # calls dry_forbids, so a write added two months from now is caught the first
  # time it runs rather than the first time somebody thinks to assert on it.
  run_engine --all --to "$T1" --dry-run
  clean
  untraced "pvesm alloc"; untraced "rsync"; untraced "cat >"
  done_scenario
fi

if scenario "22: --list reports the plan and touches nothing"; then
  run_engine --list
  rc_is 1; clean          # CT 121 has no target, which --list must not hide
  has "plan: copy 8300 on bkp02"
  untraced "pvesm alloc"; untraced "rsync"
  done_scenario
fi

if scenario "23: a target that cannot reach the backup node refuses BEFORE allocating"; then
  # The transfer is issued on the target, pulling. Finding this out afterwards
  # means an allocated volume and a half-written config to unpick by hand.
  no_backup_ssh "$T1"
  run_engine --ctid 300
  rc_is 1; clean
  has "cannot ssh root@100.100.100.35 - the transfer is issued THERE"
  has "ssh-copy-id"
  untraced "pvesm alloc"
  done_scenario
fi

if scenario "24: an unreachable target fails that CT and the run carries on"; then
  # A real disaster is twenty containers and one compute node that did not come
  # back. It must not strand the other nineteen.
  target_down "$T1"
  run_engine --all
  rc_is 1; clean
  has "[300] ERROR: cannot ssh root@$T1 - NOTHING was allocated"
  cfg_exists pve02 9113          # the other one still went
  has "failed:  300 121"
  done_scenario
fi

if scenario "25: an unreachable backup node refuses the whole run"; then
  bkp_down
  run_engine --all
  rc_is 2; clean
  has "cannot read the PVE node identity"
  has "every byte this engine moves comes off that machine"
  untraced "pvesm alloc"
  done_scenario
fi

if scenario "26: a CT with no DR copy at all is a failure that says why"; then
  copy_gone 300
  run_engine --ctid 300
  rc_is 1; clean
  has "no DR copy 8300 on bkp02"
  has "ct-replica has never successfully copied this container"
  done_scenario
fi

if scenario "27: a --ctid that is not in the inventory refuses, it does not exit 0"; then
  run_engine --ctid 999
  rc_is 2; clean
  has "no row in"
  has "can only place a container that has a DR copy"
  done_scenario
fi

if scenario "28: the config keeps the production IP and MAC, and drops onboot"; then
  # This is rule 4 from the other direction: the copy is meant to answer for
  # the production container, so its address has to survive the move.
  run_engine --ctid 300
  rc_is 0; clean
  cfg_has pve01 9300 "hwaddr=BC:24:11:00:00:00"
  cfg_has pve01 9300 "ip=10.100.2.50/24"
  cfg_has pve01 9300 "onboot: 0"
  cfg_has pve01 9300 "temporary DR copy of CT 300"
  done_scenario
fi

if scenario "29: --all places every row that has a target and reports the rest"; then
  run_engine --all
  rc_is 1; clean            # 121 has no target
  cfg_exists pve01 9300
  cfg_exists pve02 9113
  has "ok=2 skipped=0 failed=1"
  # three levels, because they are three different kinds of edge: the run, the
  # container list, and one container giving way to the next. Only a multi-CT
  # run shows all three, which is why they are asserted here and not on the
  # single-container happy path.
  has "##############################################################################"
  has "=============================================================================="
  has "------------------------------------------------------------------------------"
  done_scenario
fi

if scenario "30: a second run while one is going is skipped, not doubled"; then
  ( exec 7>"$WORK/.distribute.lock"; flock -n 7 || exit 1; sleep 5 ) &
  _holder=$!
  sleep 0.3
  run_engine --ctid 300
  rc_is 0
  has "another distribute is already running - skip"
  untraced "pvesm alloc"
  kill "$_holder" 2>/dev/null; wait 2>/dev/null
  done_scenario
fi

if scenario "32: a dir target gets a raw file, mkfs'd and loop-mounted"; then
  # The third shape. A raw file mounted without -o loop fails on a real node,
  # and a block device mounted WITH it fails the other way - so the fake refuses
  # both rather than accepting whichever the engine happened to send.
  run_engine --ctid 300 --to "$T2" --dst local-dir
  rc_is 0; clean
  has "storage  local-dir (dir, image)"
  traced "mount -o loop"
  vol_has "$T2" local-dir vm-9300-disk-0.raw "customer data for 300"
  nothing_mounted
  done_scenario
fi

if scenario "33: a copy whose rootfs has no size is refused, not guessed at"; then
  # Allocating a guessed size is how a rootfs arrives 90 percent copied, and
  # the missing 10 percent is whatever the customer wrote most recently.
  sed -i 's/,size=20G//' "$PVE/nodes/bkp02/lxc/8300.conf"
  run_engine --ctid 300
  rc_is 1; clean
  has "cannot read a size from the copy's rootfs line"
  has "allocating a guessed size"
  untraced "pvesm alloc"
  done_scenario
fi

if scenario "31: --help prints the whole header, exit-code contract included"; then
  out="$("$WORK/ct-distribute.sh" --help 2>&1)"; rc=$?
  [[ "$rc" == 0 ]] || _err "--help exit code $rc, expected 0"
  grep -q "exit code" <<<"$out" || _err "--help does not reach the exit-code contract"
  grep -q "^#" <<<"$out" && _err "--help should print the header without its # markers"
  done_scenario
fi

echo
echo "=== $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then echo "failed: ${FAILED_NAMES[*]}"; exit 1; fi
exit 0
