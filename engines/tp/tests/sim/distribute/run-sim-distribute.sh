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
  # What the fake rsync reports out of its --stats block, with the thousands
  # separators a real one prints. The traffic is on the RECEIVED line: this
  # engine's rsync runs on the target and pulls.
  printf 'Number of regular files transferred: 161\nTotal file size: 118,111,600,640 bytes\nLiteral data: 2,469,606,195 bytes\nTotal bytes sent: 3,271\nTotal bytes received: 2,470,127,483 bytes\n' \
    > "$SIMROOT/rsync.stats"

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
  add_copy 300 replica-hdd 20G
  add_copy 113 replica-hdd 40G
  add_copy 121 replica-ssd 10G

  ln -s "$ENGINE" "$WORK/ct-distribute.sh"
  write_conf
  write_nodemap
  inventory "300	replica-hdd" "113	replica-hdd" "121	replica-ssd"
  fleet "300	10.100.1.31	$T1	local-lvm" "113	10.100.1.31	$T2	local-zfs"
}

# ---------- the cluster ----------
# Every production node has the two bridges a real one has: a customer bridge
# with a physical port on it, and the isolated bridge with nothing on it. D1
# reads both - which bridge each veth is on, and whether that bridge reaches a
# wire - so a node without them cannot answer the question the guard asks.
add_prod_node(){ mkdir -p "$SIMROOT/nodes/$1/ct" "$SIMROOT/nodes/$1/bridges"
                 node_bridge "$1" vmbr0 eno1,nic
                 node_bridge "$1" vmbr99; }
node_bridge(){ # node bridge [port,kind[,member,member]]...  nic|bond is an UPLINK
  local n="$1" b="$2" p _port _kind _rest; shift 2
  mkdir -p "$SIMROOT/nodes/$n/bridges"; : > "$SIMROOT/nodes/$n/bridges/$b"
  # An ovsbond has members, and nothing else does: it is one OVS port with no
  # kernel netdev of its own, hiding the NICs that actually reach the wire.
  for p in "$@"; do
    IFS=, read -r _port _kind _rest <<<"$p"
    printf '%s %s %s\n' "$_port" "$_kind" "${_rest:-}" >> "$SIMROOT/nodes/$n/bridges/$b"
  done; }
node_nobridge(){ rm -f "$SIMROOT/nodes/$1/bridges/$2"; }
node_down(){ : > "$SIMROOT/nodes/$1/.down"; }
node_up(){   rm -f "$SIMROOT/nodes/$1/.down"; }
prod_ct(){   # ctid node status - a production CT that exists in pmxcfs
  mkdir -p "$PVE/nodes/$2/lxc" "$SIMROOT/nodes/$2/ct"
  printf 'arch: amd64\nhostname: ct%s\nrootfs: tank-hdd-nas:%s/vm-%s-disk-0.raw,size=20G\n' "$1" "$1" "$1" \
    > "$PVE/nodes/$2/lxc/$1.conf"
  printf '%s\n' "$3" > "$SIMROOT/nodes/$2/ct/$1.status"
  printf '%s\n' "${4:-0}" > "$SIMROOT/nodes/$2/ct/$1.onboot"
  # One customer interface, and - if it is running - the veth that interface
  # actually has in the kernel. A stopped container has no veth at all, which
  # is why D1 never asks this of one.
  ct_nets "$1" "$2" vmbr0
  if [[ "$3" == running ]]; then ct_veths "$1" "$2" vmbr0; else ct_veths "$1" "$2"; fi; }
# What the CONFIG declares. Kept separate from the kernel on purpose: a config
# can record a bridge change that the running container never received, and D1
# exists because only one of those two sources can be trusted.
ct_nets(){   # ctid node bridge...   one net line per bridge named
  local id="$1" n="$2" i=0 b; shift 2
  : > "$SIMROOT/nodes/$n/ct/$id.nets"
  for b in "$@"; do
    printf 'net%s: name=eth%s,bridge=%s,hwaddr=BC:24:11:00:00:%02d,ip=10.100.2.%s/24\n' \
      "$i" "$i" "$b" "$(( id % 100 ))" "$(( id % 250 ))" >> "$SIMROOT/nodes/$n/ct/$id.nets"
    i=$(( i + 1 ))
  done; }
# What the KERNEL shows: one veth per line and the bridge it is enslaved to. No
# arguments means the container is running and none of its interfaces can be
# found, which is not the same as "it has none".
ct_veths(){  # ctid node bridge...
  local id="$1" n="$2" i=0 b; shift 2
  : > "$SIMROOT/nodes/$n/ct/$id.veth"
  for b in "$@"; do
    printf 'veth%si%s %s\n' "$id" "$i" "$b" >> "$SIMROOT/nodes/$n/ct/$id.veth"
    i=$(( i + 1 ))
  done; }
# The same container on an Open vSwitch node - which is what this fleet runs.
# OVS enslaves every port of every bridge to ONE datapath device, ovs-system,
# so the kernel's master is ovs-system for all of them and the bridge exists
# only in ovsdb. Both facts are written down separately, because the engine has
# to ask two different questions to put them back together.
ct_veths_ovs(){ # ctid node bridge...
  local id="$1" n="$2" i=0 b; shift 2
  : > "$SIMROOT/nodes/$n/ct/$id.veth"
  for b in "$@"; do
    printf 'veth%si%s ovs-system\n' "$id" "$i" >> "$SIMROOT/nodes/$n/ct/$id.veth"
    printf 'veth%si%s %s\n' "$id" "$i" "$b"    >> "$SIMROOT/nodes/$n/ovs"
    i=$(( i + 1 ))
  done; }
# ovsdb cannot answer: ovs-vsctl is not installed, or openvswitch-switch is
# down. The kernel still says ovs-system, and nothing can turn that into a
# bridge name.
node_ovs_mute(){ rm -f "$SIMROOT/nodes/$1/ovs"; }
# What ct-prepare.sh --isolate leaves in pmxcfs: which bridge each interface
# was on BEFORE it was moved onto the isolated one. `ketsync distribute` runs
# isolate first, so on a real DR every container reaching D6 has vmbr99 in its
# config and this file is the only thing that knows better.
iso_rec(){ # ctid node netN,bridge...
  local id="$1" n="$2" p; shift 2
  mkdir -p "$PVE/ketsync/isolate"
  { printf 'ctid\t%s\nnode\t%s\nwhen\t2026-01-01T00:00:00+0700\nby\tct-prepare.sh pid 1\nonboot\t1\n' "$id" "$n"
    for p in "$@"; do printf '%s\t%s\n' "${p%%,*}" "${p##*,}"; done
  } > "$PVE/ketsync/isolate/$id.tsv"; }

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
# D8. A lock left by somebody else on the target - which during a DR is either
# a distribute in flight from the other machine, or one that was killed. The
# engine cannot tell those apart and must not try, so these do not either.
tgt_lock(){ # ip vmid owner
  mkdir -p "$SIMROOT/targets/$1/run"
  printf '%s\n' "$3" > "$SIMROOT/targets/$1/run/ketsync-ct-$2.lock"; }
# Somebody clears a lock that looks stale while the run holding it is alive,
# and the next run takes it for real. This run must leave that file alone.
tgt_lock_steal(){ printf '%s\n' "$2" > "$SIMROOT/targets/$1/lock.steal"; }
tgt_lock_unreachable(){ : > "$SIMROOT/targets/$1/lock.fail"; }
lock_held(){ [[ -f "$SIMROOT/targets/$1/run/ketsync-ct-$2.lock" ]] \
               || _err "the 9<id> lock for $2 is gone from $1"; }
lock_free(){ [[ -f "$SIMROOT/targets/$1/run/ketsync-ct-$2.lock" ]] \
               && _err "the 9<id> lock for $2 was left on $1: $(cat "$SIMROOT/targets/$1/run/ketsync-ct-$2.lock")"
             return 0; }
lock_owner(){ grep -qF -- "$3" "$SIMROOT/targets/$1/run/ketsync-ct-$2.lock" 2>/dev/null \
                || _err "the 9<id> lock for $2 on $1 no longer says '$3'"; }
no_backup_ssh(){ : > "$SIMROOT/targets/$1/.nobkpssh"; }
bkp_down(){ : > "$BKP/.down"; }

# A DR copy on the backup node: its config in pmxcfs, its status, its dataset
# and some content to move.
add_copy(){ # src_ctid dest-storage-id size
  local id=$(( $1 + 8000 )) ds
  case "$2" in
    replica-hdd|replica-ssd) ds="$2/ct";;
    *) echo "add_copy: dest must be a storage id like replica-hdd, got '$2'" >&2; exit 2;;
  esac
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
BKP_DESTS="replica-hdd:replica-hdd/ct replica-ssd:replica-ssd/ct"
OFFSET=8000
DR_OFFSET=9000
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
fleet(){     { printf '# ct\thome\tdr\tdst\n'; printf '%s\n' "$@"; } > "$WORK/fleet.tsv"; }
no_fleet(){  rm -f "$WORK/fleet.tsv"; }
rsync_rc(){  printf '%s\n' "$1" > "$SIMROOT/rsync.rc"; }
# The state file's "last" object, without a JSON parser: the engine writes it
# one field per printf with no spaces, and the sim has no business depending on
# python to read four integers.
st_file(){ printf '%s/state/distribute-%s.json' "$WORK" "$1"; }
st_is(){ # $1=ctid $2=last.<field> $3=expected
  local f k got; f="$(st_file "$1")"; k="${2#last.}"
  got="$(sed -n "s/.*\"$k\":\([^,}]*\).*/\1/p" "$f" 2>/dev/null | head -1 | tr -d '\"')"
  [[ "$got" == "$3" ]] || _err "state $1: $2 = '${got:-<none>}', expected '$3'"; }
no_rsync_stats(){ : > "$SIMROOT/rsync.stats"; }
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
    # Overridable so one scenario can run the engine from a VENDORED layout -
    # <repo>/engines/tp/ - and prove it reads ketsync's own tables rather than
    # stale copies sitting beside itself.
    "${ENGINE_PATH:-$WORK/ct-distribute.sh}" "$@" ) > "$SIMROOT/out" 2>&1
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
# Two net0 lines is a config PVE reads the wrong half of, and it is what
# appending the production net without removing the copy's produces. Content
# assertions cannot see it - only counting can.
cfg_net_count(){ # node vmid expected
  local n; n=$(grep -cE '^net[0-9]+:' "$PVE/nodes/$1/lxc/$2.conf" 2>/dev/null || echo 0)
  [[ "$n" == "$3" ]] || _err "$1/lxc/$2.conf has $n net lines, expected $3"; }
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
  has "still on the wire: veth300i0(vmbr0)"
  untraced "pvesm alloc"
  no_vol "$T1" local-lvm vm-9300-disk-0
  no_cfg pve01 9300
  done_scenario
fi

if scenario "4b: D1 accepts a RUNNING production CT once it is on the isolated bridge"; then
  # The shape the fleet actually produced. The NFS storage vanished, CT 300's
  # processes went into uninterruptible sleep waiting on I/O that will never
  # return, and SIGKILL does not reach a task in D state - so `pct shutdown`
  # hangs and `pct stop` queues behind it. There is no way to stop it until the
  # storage comes back, and the DR cannot wait for that.
  #
  # Moving every interface onto the bridge with no uplink needs nothing from
  # the dead storage: it is a write to /etc/pve that hotplugs live. It also
  # removes the only thing that made "running" dangerous, because what D1 is
  # actually defending is one address, not one process.
  prod_ct 300 pve01 running; node_up pve01
  ct_nets  300 pve01 vmbr99
  ct_veths 300 pve01 vmbr99
  run_engine --ctid 300
  rc_is 0; clean
  has "D1: production CT 300 is RUNNING on pve01"
  has "IT IS STILL A PENDING WRITER"
  has "pct set 300 --onboot 0"
  hasnt "GUARD D1"
  cfg_exists pve01 9300
  vol_exists "$T1" local-lvm vm-9300-disk-0
  done_scenario
fi

if scenario "4c: D1 counts EVERY interface, not just the one somebody remembered"; then
  # net0 moved, net1 forgotten. The container is still on the customer's
  # network through the interface nobody thought about, and it is precisely
  # the forgotten one that answers when the copy comes up on the same IP.
  prod_ct 300 pve01 running; node_up pve01
  ct_nets  300 pve01 vmbr99 vmbr0
  ct_veths 300 pve01 vmbr99 vmbr0
  run_engine --ctid 300
  rc_is 1; clean
  has "GUARD D1: production CT 300 is RUNNING on pve01"
  has "still on the wire: veth300i1(vmbr0)"
  untraced "pvesm alloc"
  no_cfg pve01 9300
  done_scenario
fi

if scenario "4d: D1 refuses the isolated bridge if that bridge reaches a wire"; then
  # vmbr99 with a physical port on it is not an isolated bridge, it is a second
  # customer bridge with a confusing name. R9 asks the backup node the same
  # question about the same bridge, and for the same reason.
  prod_ct 300 pve01 running; node_up pve01
  ct_nets  300 pve01 vmbr99
  ct_veths 300 pve01 vmbr99
  node_bridge pve01 vmbr99 eno2,nic
  run_engine --ctid 300
  rc_is 1; clean
  has "vmbr99 on pve01 HAS AN UPLINK: port 'eno2'"
  untraced "pvesm alloc"
  no_cfg pve01 9300
  done_scenario
fi

if scenario "4e: D1 refuses when the isolated bridge does not exist on that node"; then
  # The config was edited to name a bridge the node does not have, so the veth
  # is enslaved to nothing and the operator believes the container is off the
  # network. It is off THIS node's network; whether it is off the customer's
  # is not something the config can answer.
  prod_ct 300 pve01 running; node_up pve01
  node_nobridge pve01 vmbr99
  ct_nets  300 pve01 vmbr99
  ct_veths 300 pve01 ""
  run_engine --ctid 300
  rc_is 1; clean
  has "(vmbr99 does not exist on pve01)"
  untraced "pvesm alloc"
  no_cfg pve01 9300
  done_scenario
fi

if scenario "4f: D1 refuses when it finds fewer interfaces than the config declares"; then
  # Two net lines, one veth. The other one is somewhere this probe did not
  # look, and an interface nobody found is an interface nobody has ruled out.
  # Unverified is not isolated - the same rule as unreachable is not stopped.
  prod_ct 300 pve01 running; node_up pve01
  ct_nets  300 pve01 vmbr99 vmbr99
  ct_veths 300 pve01 vmbr99
  run_engine --ctid 300
  rc_is 1; clean
  has "found 1 of the 2 interfaces its config declares"
  has "unverified is not isolated"
  untraced "pvesm alloc"
  no_cfg pve01 9300
  done_scenario
fi

if scenario "4g: an accepted isolated CT is not then refused for onboot"; then
  # onboot: 1 is the normal state of a production container, so getting this
  # wrong would have refused every real use of 4b - and refused it by calling a
  # running container stopped. The check below it is about a container that is
  # DOWN and would come back by itself; this one is already up and was already
  # accepted, out loud, as something that resumes writing when the storage
  # returns. onboot cannot make it more of that.
  prod_ct 300 pve01 running 1; node_up pve01
  ct_nets  300 pve01 vmbr99
  ct_veths 300 pve01 vmbr99
  run_engine --ctid 300
  rc_is 0; clean
  hasnt "is stopped but has onboot: 1"
  has "IT IS STILL A PENDING WRITER"
  cfg_exists pve01 9300
  done_scenario
fi

if scenario "4h: on an OVS node the bridge comes from ovsdb, not from the master"; then
  # This is the bug this fleet actually hit. Open vSwitch enslaves every port
  # to one datapath device called ovs-system, so /sys/class/net/<if>/master
  # names the datapath and NEVER the bridge - and D1 refused every container on
  # the fleet with "still on the wire: veth110i0(ovs-system)" while they were
  # correctly isolated on vmbr99. On an OVS fleet that closes the only route
  # out of a dead storage node, which is the exact situation the guard is for.
  prod_ct 300 pve01 running; node_up pve01
  ct_nets     300 pve01 vmbr99
  ct_veths_ovs 300 pve01 vmbr99
  run_engine --ctid 300
  rc_is 0; clean
  has "IT IS STILL A PENDING WRITER"
  hasnt "GUARD D1"
  hasnt "ovs-system"
  cfg_exists pve01 9300
  done_scenario
fi

if scenario "4i: an OVS node whose ovsdb does not answer is unverified, not isolated"; then
  # ovs-vsctl missing or openvswitch-switch down. The kernel says ovs-system
  # and nothing can turn that into a bridge name, so which bridge the container
  # is on is unknown - and unknown is not isolated. The refusal names the word
  # rather than hiding it, because the operator has to know it was OVS that
  # went unanswered and not the container that moved.
  prod_ct 300 pve01 running; node_up pve01
  ct_nets     300 pve01 vmbr99
  ct_veths_ovs 300 pve01 vmbr99
  node_ovs_mute pve01
  run_engine --ctid 300
  rc_is 1; clean
  has "still on the wire: veth300i0(ovs-system)"
  has "ovs-system is Open vSwitch's datapath, not a bridge"
  untraced "pvesm alloc"
  no_cfg pve01 9300
  done_scenario
fi

if scenario "4j: a bond uplinking the isolated bridge counts, on OVS too"; then
  # An OVS bond is one PORT whose members are the NICs, and it has no kernel
  # netdev of its own - so asking OVS for the bridge's PORTS returns a name
  # with no /device and no /bonding, and vmbr99 reads as isolated while it
  # reaches the customer's wire through two cables. Asking for its IFACES
  # returns the members.
  prod_ct 300 pve01 running; node_up pve01
  ct_nets  300 pve01 vmbr99
  ct_veths 300 pve01 vmbr99
  node_bridge pve01 vmbr99 bond0,ovsbond,eno2,eno3
  run_engine --ctid 300
  rc_is 1; clean
  has "vmbr99 on pve01 HAS AN UPLINK: port 'eno2'"
  has "vmbr99 on pve01 HAS AN UPLINK: port 'eno3'"
  untraced "pvesm alloc"
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

if scenario "5b: GUARD D1 - a production node that does not answer is UNVERIFIED"; then
  # The header always claimed unreachable counted as not-verified; the code
  # logged "taking the storage outage as the reason" and carried on. That is
  # the guess every other guard here refuses, and it is the one that ends with
  # two containers on one IP. It refuses now.
  # A production node that is NOT also the placement target, so "cannot reach
  # the machine that runs it" is expressible on its own. pve01 and pve02 are
  # both targets here; pve03 is only ever a production node.
  add_prod_node pve03; node_down pve03
  prod_ct 300 pve03 stopped
  run_engine --ctid 300
  rc_is 1; clean
  has "production CT 300 is UNVERIFIED"
  has "unreachable is not stopped"
  untraced "pvesm alloc"
  no_cfg pve01 9300
  done_scenario
fi

if scenario "5c: GUARD D1 - stopped with onboot 1 is a container that comes back by itself"; then
  # The hole the fleet found: the storage node dies with no warning, the DR is
  # placed, and then the storage node comes back. An onboot: 1 container starts
  # itself the moment its rootfs is readable again - nobody types anything -
  # and now production and the 9xxx are both live on one IP, each writing a
  # rootfs that can never be merged with the other.
  prod_ct 300 pve01 stopped 1; node_up pve01
  run_engine --ctid 300
  rc_is 1; clean
  has "has onboot: 1 on pve01"
  has "start ITSELF the moment the storage node comes back"
  has "pct set 300 --onboot 0"
  untraced "pvesm alloc"
  no_cfg pve01 9300
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

if scenario "13b: a failed transfer carries rsync's own message back"; then
  # rc=23 and nothing else is a run nobody can diagnose without repeating it by
  # hand at four in the morning. The whole transfer used to go to /dev/null -
  # both what it copied and what it said when it could not.
  rsync_rc 23
  run_engine --ctid 300
  rc_is 1; clean
  has "rsync: rsync: [receiver] mkstemp"
  has "No space left on device"
  done_scenario
fi

if scenario "13c: the numbers reach the log and the state file"; then
  # The only evidence anybody gets that this container's rootfs arrived rather
  # than an empty directory. This engine filed files=0, literal_bytes=0 and
  # bytes_received=0 for every placement it ever made, because its rsync ran
  # with --stats off and its output thrown away.
  run_engine --ctid 300
  rc_is 0; clean
  has "stats: files=161 changed=2.2GiB wire=2.3GiB of 110.0GiB"
  st_is 300 last.files          161
  st_is 300 last.literal_bytes  2469606195
  st_is 300 last.bytes_received 2470127483
  done_scenario
fi

if scenario "13d: a transfer that reported nothing is not dressed up as one that did"; then
  # An rsync that copied an empty source exits 0. The numbers are the only
  # thing that tells those two apart, so they are printed as they came back -
  # zeros included - rather than left out when they are unflattering.
  no_rsync_stats
  run_engine --ctid 300
  rc_is 0; clean
  has "stats: files=0 changed=0B wire=0B of 0B"
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

if scenario "28b: the 9<id> gets the PRODUCTION container's net, not the copy's"; then
  # The copy's net line is on vmbr99 because ct-replica put it there - a copy
  # that could answer is a second machine on a customer's address. The 9<id> is
  # the opposite: it is placed in order to answer. The real bridge is in the
  # production config, which is readable even with the storage dead because it
  # lives in /etc/pve, and reading it beats printing a line for somebody to
  # retype at 4am.
  prod_ct 300 pve01 stopped; node_up pve01
  run_engine --ctid 300
  rc_is 0; clean
  cfg_has pve01 9300 "bridge=vmbr0"
  has "net: net0 on vmbr0 - taken from CT 300's own config"
  hasnt "bridge=vmbr99"
  cfg_net_count pve01 9300 1
  done_scenario
fi

if scenario "28c: every net line comes across, and the copy's are REMOVED not edited"; then
  # Two interfaces, and a config that ends up holding two net0 lines is one PVE
  # reads the wrong half of. Appending without removing is the easy way to
  # write one, so the count is asserted, not just the content.
  prod_ct 300 pve01 stopped; node_up pve01
  ct_nets 300 pve01 vmbr0 vmbr7
  run_engine --ctid 300
  rc_is 0; clean
  cfg_has pve01 9300 "bridge=vmbr0"
  cfg_has pve01 9300 "bridge=vmbr7"
  cfg_net_count pve01 9300 2
  done_scenario
fi

if scenario "28d: a production CT isolated by hand cannot say where its bridge was"; then
  # The operator moved it onto vmbr99 to get past D1 - which D1 now allows -
  # and by doing so overwrote the only record of the real bridge. Nothing here
  # invents one. The placement still happens, because the data is what matters
  # and the config is one command to fix, but the run says out loud that this
  # container cannot answer yet.
  prod_ct 300 pve01 running; node_up pve01
  ct_nets  300 pve01 vmbr99
  ct_veths 300 pve01 vmbr99
  run_engine --ctid 300
  rc_is 0; clean
  cfg_exists pve01 9300
  has "came across on vmbr99, which has no uplink"
  has "would come up UNABLE TO ANSWER"
  has "nothing recorded where it came from"
  done_scenario
fi

if scenario "28g: the record isolate wrote is where the real bridge comes back from"; then
  # This is the normal path, not an edge case. `ketsync distribute` isolates
  # before it places, so EVERY container that reaches D6 during a real DR has
  # vmbr99 in its production config by then - put there minutes earlier by this
  # same toolchain, which wrote down what it overwrote. Reading it back is the
  # difference between a 9<id> that answers and a person retyping a bridge per
  # container at four in the morning, which is the work the automation is for.
  prod_ct 300 pve01 running; node_up pve01
  ct_nets  300 pve01 vmbr99
  ct_veths 300 pve01 vmbr99
  iso_rec  300 pve01 net0,vmbr0
  run_engine --ctid 300
  rc_is 0; clean
  cfg_has pve01 9300 "bridge=vmbr0"
  has "came from the isolate record on pve01"
  hasnt "UNABLE TO ANSWER"
  cfg_net_count pve01 9300 1
  done_scenario
fi

if scenario "28h: a record that names another container is corrupt, not authoritative"; then
  # A file called 300.tsv that says it is about 113 cannot be trusted about
  # anything, and the thing it would be trusted about here is which customer
  # segment a container comes up on. Same check ct-prepare.sh makes when it
  # reads its own record back.
  prod_ct 300 pve01 running; node_up pve01
  ct_nets  300 pve01 vmbr99
  ct_veths 300 pve01 vmbr99
  iso_rec  113 pve01 net0,vmbr0
  mv "$PVE/ketsync/isolate/113.tsv" "$PVE/ketsync/isolate/300.tsv"
  run_engine --ctid 300
  rc_is 0; clean
  cfg_has pve01 9300 "bridge=vmbr99"
  has "would come up UNABLE TO ANSWER"
  hasnt "came from the isolate record"
  done_scenario
fi

if scenario "28i: a bridge name the record cannot have written is not pasted through"; then
  # The record is a file in /etc/pve and files get edited. What is read out of
  # it goes into a config PVE acts on, so anything that is not an interface
  # name is treated as no record at all - the warning is the correct outcome,
  # and a container that comes up on the isolated bridge is recoverable in a
  # way that one on a segment nobody chose is not.
  prod_ct 300 pve01 running; node_up pve01
  ct_nets  300 pve01 vmbr99
  ct_veths 300 pve01 vmbr99
  iso_rec  300 pve01 "net0,vmbr0 --tag=7"
  run_engine --ctid 300
  rc_is 0; clean
  cfg_has pve01 9300 "bridge=vmbr99"
  has "would come up UNABLE TO ANSWER"
  done_scenario
fi

if scenario "28e: no production config anywhere - the copy's net stays, and it says why"; then
  # CT 300 has no config in this cluster at all, so there is nothing to read
  # the real bridge from. It keeps the copy's line rather than guessing, and
  # names the reason instead of leaving somebody to notice.
  run_engine --ctid 300
  rc_is 0; clean
  cfg_has pve01 9300 "bridge=vmbr99"
  has "there was nothing to read the real one from"
  done_scenario
fi

if scenario "28f: vmbr990 is not vmbr99, and a fleet big enough has both"; then
  # The isolation check compares the bridge FIELD, not the text of the line. A
  # substring match reads vmbr990 as vmbr99 and warns that a container which is
  # perfectly on the wire cannot answer - which teaches the operator to ignore
  # the warning, on the one night it means something.
  prod_ct 300 pve01 stopped; node_up pve01
  ct_nets 300 pve01 vmbr990
  run_engine --ctid 300
  rc_is 0; clean
  cfg_has pve01 9300 "bridge=vmbr990"
  hasnt "would come up UNABLE TO ANSWER"
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


# ---------- vendored inside ketsync -----------------------------------------
# The layout every real install has: <repo>/engines/tp/. ketsync keeps fleet.tsv
# and nodes.map at the top of the repo, and the engine has to read THOSE. There
# used to be a mirror instead - `ketsync doctor` copied both files down here and
# the engine read the copies - and it failed in the only place it mattered:
# `ketsync sync` delivers fleet.tsv to a slave's repo root, nothing on that
# machine refreshed the copy, and the copy is gitignored so a fresh clone never
# had one. The backup node answered "CT 110 has no row in fleet.tsv" 43 seconds
# after being sent a fleet.tsv. The stale copy is left in place here on purpose:
# if the engine reads it, it places the container on the wrong node and this
# scenario says so.
if scenario "35: vendored under a ketsync, its tables win over the copies beside the engine"; then
  REPO="$SIMROOT/repo"
  mkdir -p "$REPO/engines/tp" "$REPO/lib"
  : > "$REPO/ketsync"; : > "$REPO/lib/common.sh"
  cp "$WORK/ctrep.conf" "$WORK/inventory-replica.tsv" "$REPO/engines/tp/"
  ln -s "$ENGINE" "$REPO/engines/tp/ct-distribute.sh"
  # beside the engine: the wrong answer. At the top of the repo: the right one.
  printf '300\t10.100.1.31\t%s\tlocal-zfs\n' "$T2" > "$REPO/engines/tp/fleet.tsv"
  printf '# ip\tpve node name\n%s\tpve01\n%s\tpve02\n' "$T1" "$T2" > "$REPO/engines/tp/nodes.map"
  printf '300\t10.100.1.31\t%s\tlocal-lvm\n' "$T1" > "$REPO/fleet.tsv"
  printf '# ip\tpve node name\n%s\tpve01\n%s\tpve02\n' "$T1" "$T2" > "$REPO/nodes.map"
  ENGINE_PATH="$REPO/engines/tp/ct-distribute.sh" run_engine --ctid 300 --list
  rc_is 0; clean
  has "CT 9300 on pve01 ($T1)"
  hasnt "pve02"
  done_scenario
fi


# ---------- the fleet table's shape ------------------------------------------
if scenario "36: a CT with no dst column is refused, never given a default"; then
  # A fleet is not homogeneous: one compute node's local storage is local-lvm
  # and another's is local-zfs. There used to be a DR_DST fallback behind this
  # column, which meant a row somebody forgot to finish still allocated a
  # customer's rootfs - on whichever storage the default happened to name.
  fleet "300	10.100.1.31	$T1"
  run_engine --ctid 300
  rc_is 1; clean
  has "no destination storage"
  has "no default"
  untraced "pvesm alloc"
  no_cfg pve01 9300
  done_scenario
fi

if scenario "37: the OLD five-column fleet table is named, not read as the new one"; then
  # `110 hdd 10.100.1.32 10.100.1.32` has four fields in the new shape too, so
  # it parses without complaint and means something completely different -
  # home becomes `hdd` and the storage becomes an IP address. Everything a
  # human types here is an IP (rule 5), and `hdd` is not one.
  fleet "300	replica-hdd	10.100.1.31	$T1	local-lvm"
  run_engine --ctid 300
  rc_is 2; clean
  has "is in the OLD five-column format"
  has "column 2 must be the home node ADDRESS"
  untraced "pvesm alloc"
  done_scenario
fi

if scenario "38: D8 the target holds the 9<id> lock for the placement, then drops it"; then
  # The lock has to exist while the volume is allocated and the bytes move, and
  # be gone afterwards. A lock never taken and a lock never released both look
  # like a clean run from the outside.
  run_engine --ctid 300
  rc_is 0; clean
  traced "tgt lock take $T1 /run/ketsync-ct-9300.lock"
  traced "tgt lock release $T1 /run/ketsync-ct-9300.lock"
  lock_free "$T1" 9300
  done_scenario
fi

if scenario "39: D8 a 9<id> another machine is placing is refused before D3 is asked"; then
  # The case the guard exists for. During a DR this engine is driven from two
  # machines - one on the storage node as it comes back, one on the backup node
  # - and its own lock is a flock that neither of them can see.
  tgt_lock "$T1" 9300 "distribute bkp02 pid 4211 started 2026-08-12 03:14:00"
  run_engine --ctid 300
  rc_is 1; clean
  has "GUARD D8: 9300 is locked on pve01 by another run - NOTHING was allocated"
  has "holder: distribute bkp02 pid 4211 started 2026-08-12 03:14:00"
  has "/run/ketsync-ct-9300.lock"
  untraced "pvesm alloc"
  no_cfg pve01 9300
  lock_held "$T1" 9300; lock_owner "$T1" 9300 "distribute bkp02 pid 4211"
  done_scenario
fi

if scenario "40: D8 a target that does not answer is refused, never assumed free"; then
  # Treating an empty answer as "nobody has it" allocates a second rootfs for a
  # container that already has one on the same node.
  tgt_lock_unreachable "$T1"
  run_engine --ctid 300
  rc_is 1; clean
  has "GUARD D8: could not take 9300 on pve01"
  has "NOTHING was allocated"
  untraced "pvesm alloc"
  done_scenario
fi

if scenario "41: D8 the lock is dropped when a later guard refuses the container"; then
  # A lock released only on the happy path wedges that 9<id> the first time a
  # guard fires - and during a DR every guard fires on somebody.
  storage_set "$T1" local-lvm status inactive     # D4 refuses
  run_engine --ctid 300
  rc_is 1; clean
  has "GUARD D4"
  traced "tgt lock take $T1 /run/ketsync-ct-9300.lock"
  lock_free "$T1" 9300
  done_scenario
fi

if scenario "42: D8 --list and --dry-run report the lock and create none"; then
  # --list is the command an operator runs first, from the machine that is not
  # doing the placing. It must not leave a lock behind on every target it read.
  tgt_lock "$T1" 9300 "distribute bkp02 pid 900 started 2026-08-12 02:00:00"
  run_engine --ctid 300 --list
  rc_is 1; clean
  has "GUARD D8: list: 9300 is locked on pve01 - a real run would refuse"
  has "holder: distribute bkp02 pid 900"
  untraced "tgt lock take"
  lock_owner "$T1" 9300 "pid 900"
  done_scenario
fi

if scenario "43: D8 --list against a free target creates no lock at all"; then
  run_engine --ctid 300 --list
  rc_is 0; clean
  traced "tgt lock peek $T1 /run/ketsync-ct-9300.lock"
  untraced "tgt lock take"
  lock_free "$T1" 9300
  done_scenario
fi

if scenario "44: D8 a lock that stopped being ours is left where it is"; then
  # Somebody decides this run is dead and clears its lock; the next run takes
  # the 9<id> legitimately. This run finishing must not remove a lock that a
  # live placement is relying on.
  tgt_lock_steal "$T1" "recall pve01 pid 7788 started 2026-08-12 04:00:00"
  run_engine --ctid 300
  rc_is 0; clean
  traced "tgt lock stolen $T1 /run/ketsync-ct-9300.lock"
  lock_held "$T1" 9300; lock_owner "$T1" 9300 "recall pve01 pid 7788"
  done_scenario
fi

if scenario "45: the OLD BKP_DESTS format is named, not read as a working map"; then
  conf_set BKP_DESTS '"hdd=replica-hdd/ct:replica-hdd ssd=replica-ssd/ct:replica-ssd"'
  run_engine --ctid 300
  rc_is 2
  has "is the OLD key=dataset:storage-id form"
  has 'BKP_DESTS="replica-hdd:replica-hdd/ct replica-ssd:replica-ssd/ct"'
  untraced "pvesm alloc"
  done_scenario
fi

echo
echo "=== $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then echo "failed: ${FAILED_NAMES[*]}"; exit 1; fi
exit 0
