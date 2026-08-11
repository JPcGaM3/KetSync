#!/usr/bin/env bash
# =============================================================================
#  run-sim-failback.sh — execute ct-failback.sh against a fake storage node, a
#  fake backup node and fake production nodes
# -----------------------------------------------------------------------------
#  Why this exists: the engine can only be run for real during a disaster, on
#  nfs01, writing into the rootfs images of customers whose containers are down
#  and waiting. That is the worst imaginable place to find out a guard moved.
#  The fakes in failback/bin implement the same *invariants* B1..B6 protect, and
#  scream into sim/violations when one breaks:
#
#    - rsync into the image of a CT that is RUNNING      (B1: live corruption)
#    - rsync into a path that is not the loop-mount      (B5: a plain directory)
#    - rsync into an image on the node root filesystem   (B3)
#    - a pull from a stopped copy with no PAUSE in place (B2: R2 stopped
#      shielding it, so the next cron tick has already staled the data)
#    - loop-mount of an image that does not exist        (B4: that is a rebuild)
#    - truncate/e2fsck/resize2fs on a MOUNTED image      (B5: the G3 disaster)
#
#  A scenario can therefore FAIL in two different ways: wrong observable
#  behaviour (log, exit code, what ended up in the image), or a broken invariant
#  (the violations file is non-empty). The second one is the one that matters.
#
#  An image here is a one-file archive, "name<TAB>contents" per line, with zero
#  padding after a --PAD-- marker so it has a plausible size. Mounting unpacks
#  it, unmounting packs it back. That is what lets a scenario assert which
#  generation of a customer's rootfs the run left behind.
#
#  The engine sets its own PATH (cron gives it a useless one), so a fake cannot
#  reach it by prepending a directory. run_engine exports shell FUNCTIONS
#  instead: bash looks those up before PATH and inherits them through the
#  environment, which is the one hook left on an engine that owns its PATH.
#  stat, date, find, sed, awk, flock and mktemp stay real - they work on real
#  files inside the sandbox, and lying about them would only weaken the test.
#
#  usage:  ./tests/sim/failback/run-sim-failback.sh            every scenario
#          ./tests/sim/failback/run-sim-failback.sh 7          scenario 7 only
#          KEEP=1 ./tests/sim/failback/run-sim-failback.sh 7   keep the sandbox
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"       # repo root: the engine lives there
ENGINE="${ENGINE:-$ROOT/ct-failback.sh}"   # overridable, the way run-sim.sh is

# An engine that is present but not executable produces "exit code 126" in
# every scenario at once, which reads like a bug in the engine and is not one.
# A repo copied off a filesystem that does not carry the mode bit is enough to
# cause it. Say what actually happened, once, instead of 50 times.
if [[ ! -f "$ENGINE" ]]; then
  echo "engine not found: $ENGINE" >&2; exit 2
elif [[ ! -x "$ENGINE" ]]; then
  echo "engine is not executable: $ENGINE" >&2
  echo "  every scenario would die with exit 126. fix it with:  chmod +x $ENGINE" >&2
  exit 2
fi
ONLY="${1:-}"
PASS=0; FAIL=0; FAILED_NAMES=()

IMG_BYTES=20971520          # 20MiB per image: small enough to be a sandbox
                            # file, big enough that the ENOSPC arithmetic and
                            # hsize() print something an operator would read

# ---------- sandbox ----------
new_world(){
  SIMROOT="$(mktemp -d /tmp/ctback-sim.XXXXXX)"
  export SIMROOT SIMLIB="$HERE/lib.sh" SIMBIN="$HERE/bin"
  WORK="$SIMROOT/work"; BKP="$SIMROOT/bkp"
  mkdir -p "$WORK" "$SIMROOT/mnt" "$SIMROOT/storage" "$SIMROOT/nodes" \
           "$BKP/fs/etc/pve/nodes" "$BKP/ct"
  : > "$SIMROOT/mounted";    : > "$SIMROOT/violations"; : > "$SIMROOT/trace"
  : > "$SIMROOT/loopmap";    : > "$SIMROOT/fs.tsv";     : > "$SIMROOT/zfs.tsv"
  : > "$SIMROOT/mount.fail"; : > "$SIMROOT/umount.fail"; : > "$SIMROOT/zfs.fail"
  : > "$SIMROOT/mount.silent"
  # which loop-mounts were read-only, so umount knows whether packing the
  # mountpoint back into the image is a write it is allowed to make
  : > "$SIMROOT/ro-mounts"
  : > "$BKP/zfs.tsv"
  echo 0 > "$SIMROOT/rsync.n"; echo "0 0 0 0 0 0" > "$SIMROOT/rsync.rc"
  # files literal wire total - what the fake rsync reports in its --stats block
  echo "161 2469606195 2470127483 118111600640" > "$SIMROOT/rsync.stats"

  # The node root filesystem. Anything with no mounted ancestor lands here, and
  # an image that lands here is exactly what B3 refuses to write into.
  add_fs / ext4 rpool/ROOT/pve-1

  # Two production storages of deliberately different shape, both real on this
  # fleet: tank-hdd-nas IS its dataset's mountpoint, tank-ssd-nas is a
  # subdirectory inside one. The safety snapshot has to find the dataset either
  # way, and B3 has to accept both.
  add_zfs tank/hosting "$SIMROOT/pool/tank/hosting"
  add_storage tank-hdd-nas "$SIMROOT/pool/tank/hosting"
  add_zfs tank-ssd "$SIMROOT/pool/tank-ssd"
  add_storage tank-ssd-nas "$SIMROOT/pool/tank-ssd/hosting-ssd"

  bkp_identity bkp02

  # The world mid-disaster: production is down, the copies are up and serving.
  add_prod_ct pve01 105 tank-hdd-nas 20G
  add_prod_ct pve02 113 tank-ssd-nas 40G
  add_prod_ct pve01 121 tank-ssd-nas 10G
  add_copy 8105 hdd running 105
  add_copy 8113 ssd running 113
  add_copy 9121 ssd running 121

  # the engine resolves BASE from its own path; a symlink keeps BASE in the
  # sandbox, because ${BASH_SOURCE[0]} is not symlink-resolved
  ln -s "$ENGINE" "$WORK/ct-failback.sh"
  write_conf
  inventory "105" "113	ssd" "121	9121	ssd"
}

# ---------- this node ----------
add_fs(){   # mountpoint fstype source - one row of what findmnt -T can answer
  local m="${1%/}"; [[ -z "$m" ]] && m=/
  printf '%s\t%s\t%s\n' "$m" "$2" "$3" >> "$SIMROOT/fs.tsv"
  printf '%s\n' "$m" >> "$SIMROOT/mounted"; }
add_zfs(){  # dataset mountpoint
  mkdir -p "$2"
  printf '%s\tfs\t%s\n' "$1" "${2%/}" >> "$SIMROOT/zfs.tsv"
  add_fs "$2" zfs "$1"; }
retype_fs(){ # mountpoint fstype source - a storage that is not on ZFS at all,
             # which is legal here: only the safety snapshot needs a dataset
  awk -F'\t' -v m="${1%/}" '$1!=m' "$SIMROOT/fs.tsv" > "$SIMROOT/.f"
  mv -f "$SIMROOT/.f" "$SIMROOT/fs.tsv"
  awk -F'\t' -v n="$3" '$1!=n' "$SIMROOT/zfs.tsv" > "$SIMROOT/.z"
  mv -f "$SIMROOT/.z" "$SIMROOT/zfs.tsv"
  printf '%s\t%s\t%s\n' "${1%/}" "$2" "$3" >> "$SIMROOT/fs.tsv"; }
unmount_fs(){ grep -vxF "${1%/}" "$SIMROOT/mounted" > "$SIMROOT/.m"
              mv -f "$SIMROOT/.m" "$SIMROOT/mounted"; }
add_storage(){ mkdir -p "$2"; printf '%s\n' "$2" > "$SIMROOT/storage/$1.path"; }
img_path(){ printf '%s/images/%s/vm-%s-disk-0.raw\n' "$(cat "$SIMROOT/storage/$1.path")" "$2" "$2"; }
add_image(){ # storage-id ctid [name=contents ...]
  local p f
  # a CT whose rootfs names a storage THIS node does not have gets no image
  # here, which is the situation itself and not a harness problem
  [[ -f "$SIMROOT/storage/$1.path" ]] || return 0
  p="$(img_path "$1" "$2")"; mkdir -p "${p%/*}"
  : > "$p"
  for f in "${@:3}"; do printf '%s\t%s\n' "${f%%=*}" "${f#*=}" >> "$p"; done
  printf -- '--PAD--\n' >> "$p"
  truncate -s "$IMG_BYTES" "$p"; }
add_prod_ct(){ # node ctid storage size - a production CT, stopped, with an image
  local node="$1" id="$2" sid="$3" size="$4"
  mkdir -p "$BKP/fs/etc/pve/nodes/$node/lxc" "$SIMROOT/nodes/$node/ct"
  { printf 'arch: amd64\ncores: 2\nhostname: ct%s.example\nmemory: 2048\n' "$id"
    printf 'rootfs: %s:%s/vm-%s-disk-0.raw,size=%s\nswap: 512\n' "$sid" "$id" "$id" "$size"
    printf 'net0: name=eth0,bridge=vmbr0,ip=10.100.50.%s/24\nonboot: 1\n' "$id"
    # a snapshot section: everything below the first [name] must be ignored, or
    # the rootfs of some week-old snapshot decides where the restore goes
    printf '[before-dr]\nrootfs: tank-old-nas:%s/vm-%s-disk-0.raw,size=8G\n' "$id" "$id"
  } > "$BKP/fs/etc/pve/nodes/$node/lxc/$id.conf"
  printf 'stopped\n' > "$SIMROOT/nodes/$node/ct/$id.status"
  add_image "$sid" "$id" "rootfs.txt=rootfs of CT $id, generation 1" \
                         "stale.log=written before the disaster"; }
prod_state(){ # ctid state - what the production node answers for it
  local f; for f in "$SIMROOT"/nodes/*/ct/"$1".status; do printf '%s\n' "$2" > "$f"; done; }
node_down(){ : > "$SIMROOT/nodes/$1/.down"; }
fail_zfs(){ printf '%s\n' "$1" >> "$SIMROOT/zfs.fail"; }   # e.g. "snapshot tank/hosting"

# ---------- the backup node ----------
bkp_identity(){ printf '%s\n' "$1" > "$BKP/node"; }
bkp_down(){ : > "$BKP/.down"; }
add_copy(){ # tgt_vmid dest status src_ctid - a promoted copy, serving traffic
  local tgt="$1" st="$3" src="$4" ds="replica-$2/ct/subvol-$1-disk-0"
  printf '%s\n' "$st" > "$BKP/ct/$tgt.status"
  printf '%s\tyes\t/%s\n' "$ds" "$ds" >> "$BKP/zfs.tsv"
  mkdir -p "$BKP/fs/$ds"
  printf 'rootfs of CT %s, generation 7 - promoted on bkp02\n' "$src" > "$BKP/fs/$ds/rootfs.txt"
  printf 'orders taken during the outage\n' > "$BKP/fs/$ds/dr.log"; }
copy_state(){ printf '%s\n' "$2" > "$BKP/ct/$1.status"; }
copy_unmounted(){ # the dataset exists over there but is not mounted
  awk -F'\t' -v n="$1" '$1==n{$2="no"}1' OFS='\t' "$BKP/zfs.tsv" > "$BKP/.z"
  mv -f "$BKP/.z" "$BKP/zfs.tsv"; }
copy_nomount(){   # zfs get mountpoint answers "none" - nothing to read from
  awk -F'\t' -v n="$1" '$1==n{$3="none"}1' OFS='\t' "$BKP/zfs.tsv" > "$BKP/.z"
  mv -f "$BKP/.z" "$BKP/zfs.tsv"; }
bkp_cfg(){ # node ctid - move a production config to another node in the cluster
  mkdir -p "$BKP/fs/etc/pve/nodes/$1/lxc"
  mv "$BKP/fs/etc/pve/nodes"/*/lxc/"$2".conf "$BKP/fs/etc/pve/nodes/$1/lxc/$2.conf"; }

# ---------- what the engine reads out of its own folder ----------
write_conf(){
  cat > "$WORK/ctrep.conf" <<EOF
BKP_SSH="root@100.100.100.35"
BKP_NODE="bkp02"
BKP_DESTS="hdd=replica-hdd/ct:replica-hdd ssd=replica-ssd/ct:replica-ssd"
DEFAULT_DEST="hdd"
OFFSET=8000
BW_TOTAL_MB=230
LANES=1
BW_MIN_MB=20
LOG_KEEP_DAYS=14
GROW_PCT=5
GROW_MAX_RETRY=3
MNT_BASE=$SIMROOT/mnt
EOF
  SIM_BKP_HOST=100.100.100.35; }
conf_set(){ # key value
  { grep -v "^$1=" "$WORK/ctrep.conf" || true; } > "$WORK/.conf"
  mv -f "$WORK/.conf" "$WORK/ctrep.conf"
  printf '%s=%s\n' "$1" "$2" >> "$WORK/ctrep.conf"; return 0; }
inventory(){ printf '%s\n' "$@" > "$WORK/inventory-replica.tsv"; }
pause_replica(){ : > "$WORK/PAUSE"; }
kill_next_rsync(){ : > "$SIMROOT/rsync.kill"; }
rsync_rc(){ printf '%s\n' "$*" > "$SIMROOT/rsync.rc"; echo 0 > "$SIMROOT/rsync.n"; }
rsync_stats(){ printf '%s %s %s %s\n' "$1" "$2" "$3" "$4" > "$SIMROOT/rsync.stats"; }
fail_umount(){ printf '%s\n' "$SIMROOT/mnt/failback-$1" >> "$SIMROOT/umount.fail"; }
fail_mount(){  printf '%s\n' "$SIMROOT/mnt/failback-$1" >> "$SIMROOT/mount.fail"; }
# mount exits 0 and the target is still a plain directory - the case the exit
# status cannot tell you about
mount_silent(){ printf '%s\n' "$SIMROOT/mnt/failback-$1" >> "$SIMROOT/mount.silent"; }
stale_mount(){ mkdir -p "$SIMROOT/mnt/failback-$1"
               printf '%s\n' "$SIMROOT/mnt/failback-$1" >> "$SIMROOT/mounted"; }

# pretend another failback already holds the per-CT lock
HOLDER_PID=""
hold_lock(){ # $1 = ctid
  rm -f "$SIMROOT/holder.ready"
  ( exec 7>"$WORK/.failback-$1.lock"; flock -n 7 || exit 1
    : > "$SIMROOT/holder.ready"; sleep 120 ) &
  HOLDER_PID=$!
  local i=0
  while [[ ! -f "$SIMROOT/holder.ready" && $i -lt 200 ]]; do sleep 0.02; i=$((i+1)); done
  [[ -f "$SIMROOT/holder.ready" ]] || echo "      x could not take the lock in the harness"; }
drop_lock(){ [[ -n "$HOLDER_PID" ]] && kill "$HOLDER_PID" 2>/dev/null
             HOLDER_PID=""; wait 2>/dev/null; return 0; }

run_engine(){
  ( export SIMROOT SIMLIB SIMBIN SIM_BKP_HOST SIMWORK="$WORK"
    # Armed from the ENGINE's own arguments, not from a scenario flag, so every
    # scenario that runs a dry engine is policed whether or not its author
    # thought about it. The fakes read it through dry_forbids in lib.sh.
    SIM_DRY=0
    for _a in "$@"; do [[ "$_a" == --dry-run ]] && SIM_DRY=1; done
    export SIM_DRY
    # see the header: PATH cannot reach an engine that sets its own, exported
    # functions can. Each one is a one-line shim onto failback/bin.
    pvesm(){      "$SIMBIN/pvesm"      "$@"; }
    zfs(){        "$SIMBIN/zfs"        "$@"; }
    ssh(){        "$SIMBIN/ssh"        "$@"; }
    rsync(){      "$SIMBIN/rsync"      "$@"; }
    mount(){      "$SIMBIN/mount"      "$@"; }
    umount(){     "$SIMBIN/umount"     "$@"; }
    mountpoint(){ "$SIMBIN/mountpoint" "$@"; }
    findmnt(){    "$SIMBIN/findmnt"    "$@"; }
    losetup(){    "$SIMBIN/losetup"    "$@"; }
    truncate(){   "$SIMBIN/truncate"   "$@"; }
    resize2fs(){  "$SIMBIN/resize2fs"  "$@"; }
    e2fsck(){     "$SIMBIN/e2fsck"     "$@"; }
    df(){         "$SIMBIN/df"         "$@"; }
    hostname(){   "$SIMBIN/hostname"   "$@"; }
    sync(){       "$SIMBIN/sync"       "$@"; }
    export -f pvesm zfs ssh rsync mount umount mountpoint findmnt losetup \
              truncate resize2fs e2fsck df hostname sync
    "$WORK/ct-failback.sh" "$@" ) > "$SIMROOT/out" 2>&1
  RC=$?
  OUT="$(cat "$SIMROOT/out")"
  TRACE="$(cat "$SIMROOT/trace")"
  VIO="$(cat "$SIMROOT/violations")"
}

# ---------- assertions ----------
_err(){ echo "      x $*"; SCEN_OK=0; }
has(){    grep -qF -- "$1" <<<"$OUT" || _err "expected in log: $1"; }
hasnt(){  grep -qF -- "$1" <<<"$OUT" && _err "should NOT be in log: $1"; return 0; }
traced(){ grep -qF -- "$1" <<<"$TRACE" || _err "expected command: $1"; }
untraced(){ grep -qF -- "$1" <<<"$TRACE" && _err "command must NOT have run: $1"; return 0; }
rc_is(){ [[ "$RC" == "$1" ]] || _err "exit code $RC, expected $1"; }
clean(){ [[ -z "$VIO" ]] || { _err "INVARIANT BROKEN:"; sed 's/^/         /' <<<"$VIO"; }; }
# order matters for the safety net: a snapshot taken after the first write is
# not a safety net, it is a snapshot of the damage
traced_before(){ local a b
  a="$(grep -nF -- "$1" <<<"$TRACE" | head -1 | cut -d: -f1)"
  b="$(grep -nF -- "$2" <<<"$TRACE" | head -1 | cut -d: -f1)"
  [[ -n "$a" && -n "$b" && "$a" -lt "$b" ]] \
    || _err "'$1' (line ${a:-none}) must come before '$2' (line ${b:-none})"; }

# what the production image holds now that the run is over
image_has(){   grep -qF -- "$2" "$(img_path "$(_sid_of "$1")" "$1")" 2>/dev/null \
                 || _err "image $1 does not contain '$2'"; }
image_hasnt(){ grep -qF -- "$2" "$(img_path "$(_sid_of "$1")" "$1")" 2>/dev/null \
                 && _err "image $1 must not contain '$2'"; return 0; }
_sid_of(){ case "$1" in 105) echo tank-hdd-nas;; *) echo tank-ssd-nas;; esac; }
# the copies are the only surviving data in a disaster; nothing here may write
# to the backup node, ever
copy_intact(){ grep -qF -- "generation 7" "$BKP/fs/replica-$2/ct/subvol-$1-disk-0/rootfs.txt" 2>/dev/null \
                 || _err "copy $1 no longer holds the DR data"; }
snapshot_taken(){  grep -q "@ctback-$1-" "$SIMROOT/zfs.tsv" \
                     || _err "no safety snapshot for CT $1"; }
snapshot_absent(){ grep -q "@ctback-$1-" "$SIMROOT/zfs.tsv" \
                     && _err "a safety snapshot was taken for CT $1 and should not have been"; return 0; }
dir_empty(){ [[ -z "$(ls -A "$1" 2>/dev/null)" ]] || _err "$1 should be empty, holds: $(ls -A "$1" | tr '\n' ' ')"; }
# nothing may still be loop-mounted when the engine is gone, however it left:
# the next thing that happens is an operator starting that container
nothing_mounted(){ local m; m="$(grep -F "$SIMROOT/mnt/" "$SIMROOT/mounted" 2>/dev/null)"
  [[ -z "$m" ]] || _err "still mounted after the run: $m"; return 0; }

scenario(){
  N="${1%%:*}"
  [[ -n "$ONLY" && "$ONLY" != "$N" ]] && return 1
  echo "  [$1]"; SCEN_OK=1; new_world; return 0; }
done_scenario(){
  drop_lock
  if (( SCEN_OK )); then PASS=$((PASS+1)); echo "      ok"
  else FAIL=$((FAIL+1)); FAILED_NAMES+=("$N"); fi
  if [[ -n "${KEEP:-}" ]]; then echo "      sandbox: $SIMROOT"; else rm -rf "$SIMROOT"; fi; }

echo "=== ct-failback.sh simulator ==="

if scenario "1: happy path, three promoted copies come back into their images"; then
  run_engine --all
  rc_is 0; clean
  has "=== nfs01 failback mode=presync bw=230m candidates: 105 113 121 ==="
  has "=== failback finished: ok=3 skipped=0 failed=0 ==="
  has "[105] OK <= 8105 (rc=0)"
  has "[121] OK <= 9121 (rc=0)"
  # a disaster runs --all over twenty CTs and every per-CT guard skips rather
  # than stopping the batch; the rule is what makes the two that failed
  # findable in the log afterwards.
  has "##############################################################################"
  # the DR generation replaced the pre-disaster one, and --delete took the
  # files that only ever existed on the production side with it
  image_has 105 "generation 7"; image_hasnt 105 "stale.log"
  image_has 113 "generation 7"; image_has 121 "generation 7"
  copy_intact 8105 hdd; copy_intact 9121 ssd
  traced "rsyncopt --delete"
  traced "rsyncopt --numeric-ids"
  traced "rsyncopt --inplace"
  traced "rsyncopt --bwlimit=230m"
  nothing_mounted
  done_scenario
fi

if scenario "2: the copy is read over ssh from the dataset the inventory names"; then
  run_engine --ctid 121
  rc_is 0; clean
  # tgt 9121 comes from the row, dest ssd from the row, and the dataset from
  # BKP_DESTS - one wrong link there restores the wrong customer's data
  has "[121] RESTORE <= root@100.100.100.35:/replica-ssd/ct/subvol-9121-disk-0/"
  has "(copy 9121, dest=ssd)"
  traced "rsync root@100.100.100.35:/replica-ssd/ct/subvol-9121-disk-0 -> $SIMROOT/mnt/failback-121"
  has "[121] stats: files=161 changed=2.2GiB wire=2.3GiB"
  done_scenario
fi

if scenario "3: --list is read-only: it mounts nothing and moves nothing"; then
  run_engine --list
  rc_is 0; clean
  has "CT      COPY    DEST  PROD-NODE      PROD        COPY-STATE  IMAGE"
  has "105     8105    hdd   pve01          stopped     running"
  has "121     9121    ssd   pve01          stopped     running"
  untraced "rsync"; untraced "mount -o"
  image_has 105 "generation 1"          # the pre-disaster image, untouched
  nothing_mounted
  done_scenario
fi

if scenario "4: --list still exits 0 when not one CT could be failed back"; then
  # triage runs when everything is wrong; that is the point of it
  prod_state 105 running; prod_state 113 running; prod_state 121 running
  copy_state 8105 stopped; copy_state 8113 stopped; copy_state 9121 stopped
  run_engine --list
  rc_is 0; clean
  has "105     8105    hdd   pve01          running     stopped"
  untraced "rsync"
  done_scenario
fi

if scenario "5: --list names a CT it cannot resolve instead of dropping the row"; then
  rm -f "$BKP/fs/etc/pve/nodes/pve02/lxc/113.conf"
  run_engine --list
  rc_is 0; clean
  has "113     8113    ssd   ?"
  has "cannot resolve"
  done_scenario
fi

if scenario "6: --ctid does one CT and leaves the other two alone"; then
  run_engine --ctid 113
  rc_is 0; clean
  has "=== failback finished: ok=1 skipped=0 failed=0 ==="
  image_has 113 "generation 7"
  image_has 105 "generation 1"; image_has 121 "generation 1"
  untraced "$SIMROOT/mnt/failback-105"
  done_scenario
fi

if scenario "7: --ctid works for a CT that is no longer in the inventory"; then
  # a CT pulled out of replication still has to be failed back by hand, so the
  # engine derives tgt and dest rather than refusing - and the derived dest is
  # DEFAULT_DEST, which is why a CT that was on the other tier fails loudly at
  # the mountpoint lookup instead of quietly restoring the wrong data
  inventory "113	ssd"
  run_engine --ctid 105
  rc_is 0; clean
  has "[105] RESTORE <= root@100.100.100.35:/replica-hdd/ct/subvol-8105-disk-0/"
  has "ok=1 skipped=0 failed=0"
  image_has 105 "generation 7"
  done_scenario
fi

if scenario "8: --dest runs one tier only"; then
  run_engine --all --dest ssd
  rc_is 0; clean
  has "ok=2 skipped=0 failed=0"
  image_has 113 "generation 7"; image_has 121 "generation 7"
  image_has 105 "generation 1"
  done_scenario
fi

if scenario "9: a --dest that matches no row is loud, not a quiet success"; then
  # under cron, exit 0 with no work done during a disaster reads as "all back"
  inventory "105"
  run_engine --all --dest ssd
  rc_is 1
  has "ERROR: no CT in"; has "has dest 'ssd' - nothing was failed back"
  untraced "rsync"
  done_scenario
fi

if scenario "10: a --dest key that is not in BKP_DESTS refuses before anything runs"; then
  run_engine --all --dest nvme
  rc_is 2; clean
  has "--dest 'nvme' is not a key in BKP_DESTS"
  untraced "ssh"
  done_scenario
fi

if scenario "11: a --ctid that is nowhere in the cluster is loud too"; then
  run_engine --ctid 999
  rc_is 1; clean
  has "[999] ERROR: cannot resolve this CT in the cluster"
  has "ok=0 skipped=0 failed=1"
  has "NEEDS ATTENTION -> CT: 999"
  untraced "rsync"
  done_scenario
fi

if scenario "12: a CT whose config lives on the backup node is not a production CT"; then
  # after a promotion the copy is the only thing running; failing back INTO it
  # would be a container overwriting itself
  bkp_cfg bkp02 105
  run_engine --ctid 105
  rc_is 1; clean
  has "[105] ERROR: cannot resolve this CT in the cluster (wrong id, or it lives on bkp02)"
  untraced "rsync"
  done_scenario
fi

if scenario "13: an empty inventory is exit 2, not a quiet success"; then
  inventory "# nothing here yet"
  run_engine --all
  rc_is 2; clean
  has "names no CT, and no --ctid was given"
  untraced "ssh"
  done_scenario
fi

if scenario "13b: a MISSING inventory says so, and says which file it wanted"; then
  # the file was renamed once - inventory-migrate.tsv belongs to ct-migrate now - and a
  # deployment that still has the old name would otherwise look like an empty
  # workload rather than a wiring mistake
  rm -f "$WORK/inventory-replica.tsv"
  run_engine --all
  rc_is 2; clean
  has "no inventory at"
  has "not ct-migrate's inventory-migrate.tsv"
  untraced "ssh"; untraced "rsync"
  done_scenario
fi

if scenario "13c: a missing inventory does not block an explicit --ctid"; then
  # during a disaster the CT being recovered may already have been taken out of
  # replication; refusing it because a list file is absent helps nobody
  rm -f "$WORK/inventory-replica.tsv"
  run_engine --ctid 105
  rc_is 0; clean
  has "[105] OK <= 8105"
  image_has 105 "generation 7"
  done_scenario
fi

if scenario "14: --dry-run reads everything and writes nothing"; then
  # The full dry pass: every row in the inventory, and `clean` is the assertion
  # that matters. run_engine sees --dry-run in the engine's argv and arms
  # SIM_DRY, so every fake that would change the fleet records a violation
  # instead of pretending - a read-write loop-mount, a snapshot, a resize, an
  # rsync without -n, a umount that rewrites the image. Nobody has to remember
  # to assert on the write they added; the fake does it for them.
  #
  # This scenario passed from the day it was written while the engine
  # loop-mounted the production image READ-WRITE, because the assertions
  # below check the image's content and a journal replay does not change it.
  # invariant found it the first time it ran.
  run_engine --all --dry-run
  rc_is 0; clean
  has "mode=presync/dry-run"
  has "[105] dry-run - nothing was written"
  has "dry-run only - nothing was written"
  traced "rsync root@100.100.100.35:/replica-hdd/ct/subvol-8105-disk-0 ->"
  image_has 105 "generation 1"; image_has 105 "stale.log"
  nothing_mounted
  done_scenario
fi

if scenario "15: B1 a production CT that is still running is skipped, image untouched"; then
  prod_state 105 running
  run_engine --ctid 105
  rc_is 1; clean
  has "[105] GUARD B1: production CT is 'running' on pve01, must be stopped"
  # The refusal has to say how to clear it, and the route changed: this host
  # cannot ssh a compute node, so the command it hands over goes through the
  # backup node's cluster API. What is being asserted is unchanged - a refusal
  # that does not tell the operator what to type is a refusal they work around.
  has "pvesh create /nodes/pve01/lxc/105/status/stop"
  untraced "rsync"; untraced "mount -o"
  image_has 105 "generation 1"
  has "ok=0 skipped=1 failed=0"
  done_scenario
fi

if scenario "16: B1 a production node that cannot be reached counts as not stopped"; then
  node_down pve01
  run_engine --ctid 105
  rc_is 1; clean
  has "[105] GUARD B1: cannot reach pve01 via cluster API to check the CT - 'unverified' is not 'stopped'"
  untraced "rsync"
  image_has 105 "generation 1"
  done_scenario
fi

if scenario "17: B1 one running CT does not stop the other two"; then
  # a real disaster is twenty CTs and one nobody remembered to shut down
  prod_state 113 running
  run_engine --all
  rc_is 1; clean
  has "ok=2 skipped=1 failed=0"
  image_has 105 "generation 7"; image_has 121 "generation 7"
  image_has 113 "generation 1"
  done_scenario
fi

if scenario "18: B2 presync with the copy already stopped points at --final"; then
  copy_state 8105 stopped
  run_engine --ctid 105
  rc_is 1; clean
  has "[105] GUARD B2: presync expects copy 8105 RUNNING (it is 'stopped')"
  has "use --final (with PAUSE in place)"
  untraced "rsync"
  image_has 105 "generation 1"
  done_scenario
fi

if scenario "19: B2 --final with the copy still running is skipped"; then
  pause_replica
  run_engine --ctid 105 --final
  rc_is 1; clean
  has "[105] GUARD B2: --final needs copy 8105 stopped (it is 'running')"
  untraced "rsync"
  image_has 105 "generation 1"
  done_scenario
fi

if scenario "20: B2 --final without PAUSE refuses the WHOLE run before anything"; then
  copy_state 8105 stopped; copy_state 8113 stopped; copy_state 9121 stopped
  run_engine --all --final
  rc_is 2; clean
  has "GUARD B2: --final without ct-replica paused - NOTHING was run"
  untraced "ssh"; untraced "rsync"
  image_has 105 "generation 1"
  done_scenario
fi

if scenario "21: B2 --final with PAUSE and stopped copies is the case that works"; then
  copy_state 8105 stopped; copy_state 8113 stopped; copy_state 9121 stopped
  pause_replica
  run_engine --all --final
  rc_is 0; clean
  has "mode=final"
  has "ok=3 skipped=0 failed=0"
  image_has 105 "generation 7"
  # cutover is a human's job, and the engine hands it over rather than doing it
  has "next, by hand, for: 105 113 121"
  has "1) start each production CT"
  has "3) rm "
  done_scenario
fi

if scenario "22: B2 --final --dry-run REPORTS the missing PAUSE instead of skipping the check"; then
  # This used to assert the opposite - that a dry run needed no PAUSE - which
  # made it the one place where --dry-run changed what was CHECKED rather than
  # what was written. The plan then described a night that could not happen.
  copy_state 8105 stopped
  run_engine --ctid 105 --final --dry-run
  rc_is 0; clean
  has "mode=final/dry-run"
  has "GUARD B2: DRY: --final would REFUSE"
  has "dry-run only - nothing was written"
  image_has 105 "generation 1"
  snapshot_absent 105
  done_scenario
fi

if scenario "23: B3 an image whose dataset is not mounted is refused before it is mounted"; then
  unmount_fs "$SIMROOT/pool/tank/hosting"
  run_engine --all
  rc_is 1; clean
  has "[105] GUARD B3: $SIMROOT/pool/tank/hosting/images/105/vm-105-disk-0.raw sits on the ROOT filesystem"
  has "the backing dataset is not mounted - restoring now would fill the node root"
  untraced "mount -o loop $SIMROOT/pool/tank/hosting/images/105"
  has "ok=2 skipped=0 failed=1"      # the other storage keeps working
  done_scenario
fi

if scenario "24: B3 a storage id this node does not have is an error, not a guess"; then
  add_prod_ct pve01 131 tank-nvme-nas 10G
  add_copy 8131 hdd running 131
  inventory "131"
  run_engine --all
  rc_is 1; clean
  has "[131] ERROR: storage 'tank-nvme-nas' unknown on THIS node"
  untraced "rsync"
  done_scenario
fi

if scenario "25: B4 a missing image is a rebuild, not something to create here"; then
  # THIS SCENARIO FAILS against the engine as it stands, and it is left failing
  # on purpose. B3 runs first and asks findmnt which filesystem holds the image;
  # real findmnt cannot answer for a path that does not exist and exits 1 with
  # no output, so B3 sees an empty holder and reports "sits on the ROOT
  # filesystem ... the backing dataset is not mounted ... zfs mount -a". The
  # dataset is mounted; the image is simply gone. Nothing is damaged - the row
  # is refused either way - but at 3am the operator is sent to fix a mount that
  # is fine, and B4's message is unreachable in the one case it was written for.
  rm -f "$(img_path tank-hdd-nas 105)"
  run_engine --ctid 105
  rc_is 1; clean
  has "[105] GUARD B4: no image at"
  has "a missing one is a rebuild"
  hasnt "GUARD B3"
  untraced "rsync"
  untraced "truncate"
  done_scenario
fi

if scenario "26: B5 a loop-mount that does not take is refused, never written into"; then
  fail_mount 105
  run_engine --ctid 105
  rc_is 1; clean
  has "[105] ERROR: loop-mount failed"
  untraced "rsync"
  image_has 105 "generation 1"
  nothing_mounted
  done_scenario
fi

if scenario "27: B5 a stale mount from an earlier run is cleared before this one"; then
  stale_mount 105
  run_engine --ctid 105
  rc_is 0; clean
  traced "umount $SIMROOT/mnt/failback-105"
  has "[105] OK <= 8105 (rc=0)"
  nothing_mounted
  done_scenario
fi

if scenario "28: B5 a stale mount that will not unmount stops that CT"; then
  stale_mount 105; fail_umount 105
  run_engine --ctid 105
  rc_is 1; clean
  has "[105] ERROR: stale mount at $SIMROOT/mnt/failback-105 would not unmount"
  untraced "rsync"
  done_scenario
fi

if scenario "29: B6 ENOSPC grows the image and retries, always on an UNMOUNTED image"; then
  rsync_rc 11 0
  run_engine --ctid 105
  rc_is 0; clean                      # clean == every resize happened unmounted
  has "[105] B6: out of space - grow 1/3: 20.0MiB -> 20.9MiB"
  traced "resize2fs"
  traced_before "umount $SIMROOT/mnt/failback-105" "resize2fs"
  has "[105] NOTE: image grown to 1G - the CT config still says the old size"
  has "rootfs: tank-hdd-nas:105/vm-105-disk-0.raw,size=1G"
  has "[105] OK <= 8105 (rc=0)"
  image_has 105 "generation 7"
  nothing_mounted
  done_scenario
fi

if scenario "30: B6 still out of space after every retry fails clearly"; then
  rsync_rc 11 11 11 11
  run_engine --ctid 105
  rc_is 1; clean
  has "grow 1/3"; has "grow 2/3"; has "grow 3/3"
  hasnt "grow 4/3"
  has "[105] ERROR: restore FAILED (rsync rc=11) - do NOT start CT 105"
  nothing_mounted
  done_scenario
fi

if scenario "31: B5 a umount that fails during ENOSPC must not lead to a resize"; then
  # THIS SCENARIO FAILS against the engine as it stands, and it is left failing
  # on purpose. It is ct-migrate's G3 regression, reintroduced in the direction
  # where the image being resized under a live mount is a customer's rootfs.
  #
  # cleanup_ct clears CUR_MNT unconditionally - it logs a WARN when the umount
  # fails and then clears it anyway - so the grow loop's own gate,
  # `if [[ -n "$CUR_MNT" ]] ... refusing to resize`, is testing a variable that
  # was just emptied. It can never fire. truncate, e2fsck and resize2fs then all
  # run against a MOUNTED image, mount -o loop puts a second loop on it, and the
  # retry succeeds - so the run reports ok=1 and exit 0 over a corrupted image.
  rsync_rc 11 0
  fail_umount 105
  run_engine --ctid 105
  rc_is 1; clean
  has "STILL MOUNTED - do NOT start that CT until it is down"
  has "GUARD B5"
  untraced "truncate"; untraced "resize2fs"
  done_scenario
fi

if scenario "32: rc=24 (files vanished on a live copy) is success"; then
  rsync_rc 24
  run_engine --ctid 105
  rc_is 0; clean
  has "[105] OK <= 8105 (rc=24)"
  image_has 105 "generation 7"
  done_scenario
fi

if scenario "33: rc=23 is a partial transfer, so it is a failure with a hint"; then
  rsync_rc 23
  run_engine --ctid 105
  rc_is 1; clean
  has "[105] HINT: rc=23 = some files on the copy could not be read"
  has "[105] ERROR: restore FAILED (rsync rc=23) - do NOT start CT 105"
  has "ok=0 skipped=0 failed=1"
  copy_intact 8105 hdd                # whatever happened here, the DR data is safe
  done_scenario
fi

if scenario "34: the safety snapshot is taken before the final round writes anything"; then
  copy_state 8105 stopped; pause_replica
  run_engine --ctid 105 --final
  rc_is 0; clean
  snapshot_taken 105
  has "[105] safety net: tank/hosting@ctback-105-"
  has "COPY it out - do NOT roll the"
  traced_before "zfs snapshot tank/hosting@ctback-105-" "mount -o loop"
  done_scenario
fi

if scenario "35: no safety snapshot on a presync round - nothing is irreversible yet"; then
  run_engine --all
  rc_is 0; clean
  snapshot_absent 105; snapshot_absent 113
  untraced "zfs snapshot"
  done_scenario
fi

if scenario "36: B7 a safety snapshot that cannot be taken refuses the CT"; then
  # This used to assert the opposite, and the engine used to behave that way:
  # WARN, then write. The file's own header says this direction refuses rather
  # than warns, and B1..B6 all do. --final overwrites the production image and
  # that snapshot is the only way back, so a full pool or a busy dataset meant
  # an irreversible write at the exact moment somebody was already having a bad
  # day. It refuses now, and names the flag that gets you past it on purpose.
  copy_state 8105 stopped; pause_replica
  fail_zfs "snapshot tank/hosting"
  run_engine --ctid 105 --final
  rc_is 1; clean
  has "GUARD B7: could not snapshot"
  has "is the only way back from it"
  has "--final --no-snapshot"
  untraced "rsync"
  image_has 105 "generation 1"
  nothing_mounted
  done_scenario
fi

if scenario "37: a storage that is not on ZFS gets no snapshot and still restores"; then
  retype_fs "$SIMROOT/pool/tank/hosting" xfs /dev/sdb1 tank/hosting
  copy_state 8105 stopped; pause_replica
  run_engine --ctid 105 --final
  rc_is 0; clean
  hasnt "safety net"
  hasnt "WARN: could not snapshot"
  image_has 105 "generation 7"
  done_scenario
fi

if scenario "38: a copy whose dataset has no mountpoint is an error, not a guess"; then
  copy_nomount replica-hdd/ct/subvol-8105-disk-0
  run_engine --ctid 105
  rc_is 1; clean
  has "[105] ERROR: cannot resolve the mountpoint of replica-hdd/ct/subvol-8105-disk-0 on bkp02"
  untraced "rsync"; untraced "mount -o"
  done_scenario
fi

if scenario "39: an unreachable backup node fails every CT and restores none"; then
  bkp_down
  run_engine --all
  rc_is 1; clean
  has "[105] ERROR: cannot resolve this CT in the cluster"
  has "ok=0 skipped=0 failed=3"
  untraced "rsync"
  image_has 105 "generation 1"
  done_scenario
fi

if scenario "40: the per-CT lock keeps two failbacks off one image"; then
  hold_lock 105
  run_engine --ctid 105
  rc_is 1; clean
  has "[105] NOTE: another failback owns this CT right now - skip"
  untraced "rsync"
  done_scenario
fi

if scenario "41: the lock is released between CTs, so one run never blocks itself"; then
  run_engine --all
  rc_is 0; clean
  has "ok=3 skipped=0 failed=0"
  hasnt "another failback owns this CT"
  done_scenario
fi

if scenario "42: a killed run does not leave a production image loop-mounted"; then
  # whatever else a Ctrl-C costs, the operator's next move is 'pct start', and
  # a rootfs that is still mounted here turns that into ext4 corruption
  kill_next_rsync
  run_engine --ctid 105
  rc_is 130; clean
  nothing_mounted
  image_has 105 "generation 1"
  done_scenario
fi

if scenario "43: B5 a mount that reports success but did not take is caught before rsync"; then
  # mount(8) returning 0 is not proof that anything is mounted - a loop device
  # exhausted, a stale entry, a filesystem that will not mount. The target is
  # then an ordinary directory under MNT_BASE, and one rsync later the node has
  # a customer's whole DR rootfs on its own root disk.
  mount_silent 105
  run_engine --ctid 105
  rc_is 1; clean
  has "[105] GUARD B5: $SIMROOT/mnt/failback-105 is not a mountpoint after mount - refusing to write into a plain directory"
  untraced "rsync"
  has "ok=0 skipped=0 failed=1"
  dir_empty "$SIMROOT/mnt/failback-105"
  image_has 105 "generation 1"
  nothing_mounted
  done_scenario
fi

if scenario "45: a dry run does not poison the real run that follows it"; then
  # The operator's actual sequence: look first, then do it. The dry pass mounts
  # the image read-only and the real pass mounts the same path read-write, so
  # the harness has to forget the read-only marker when the mount goes away. A
  # marker that outlived its mount would make the real run's umount skip the
  # repack: the run would report OK, the image would still hold the
  # pre-disaster generation, and whoever wrote the scenario would go hunting
  # for that in the engine.
  run_engine --ctid 105 --dry-run
  rc_is 0; clean
  has "[105] dry-run - nothing was written"
  image_has 105 "generation 1"          # untouched, as a dry run promises
  run_engine --ctid 105
  rc_is 0; clean
  has "[105] OK <= 8105 (rc=0)"
  image_has 105 "generation 7"          # and now it really came back
  image_hasnt 105 "stale.log"
  nothing_mounted
  done_scenario
fi

if scenario "44: a flag whose value is missing is refused, not spun on forever"; then
  # `shift 2` fails when only one argument is left, and the old `|| true`
  # swallowed that failure - $# never reached zero and the engine span at 100%
  # CPU with nothing in any log. This one is typed by hand during an incident,
  # which is the worst moment for a command that neither returns nor prints.
  # A scenario that hangs here rather than failing is telling you it is back.
  run_engine --ctid
  rc_is 2; clean
  has "--ctid needs a value"
  untraced "rsync"
  nothing_mounted
  done_scenario
fi

if scenario "44b: the same holds for --dest"; then
  run_engine --dest
  rc_is 2; clean
  has "--dest needs a value"
  untraced "rsync"
  done_scenario
fi

if scenario "49: --help prints the whole header, exit-code contract included"; then
  # It used to print a fixed line range that stopped short of the exit codes,
  # in all three engines. Anything running under cron is read by its exit code
  # before anybody reads a log, so that is the half of the header an operator
  # most needs and the half they could not see. It walks the comment block now
  # instead of counting lines, so editing the header cannot silently truncate
  # it again.
  out="$("$WORK/ct-failback.sh" --help 2>&1)"; rc=$?
  [[ "$rc" == 0 ]] || _err "--help exit code $rc, expected 0"
  grep -q "exit code" <<<"$out" || _err "--help does not reach the exit-code contract"
  grep -q "^#" <<<"$out" && _err "--help should print the header without its # markers"
  done_scenario
fi

if scenario "51: B7 --no-snapshot is the way past it, and it is loud"; then
  # Typed by hand during an incident by somebody who read the refusal. It must
  # work, and the run has to say there is no undo point.
  copy_state 8105 stopped; pause_replica
  fail_zfs "snapshot tank/hosting"
  run_engine --ctid 105 --final --no-snapshot
  rc_is 0; clean
  has "WARN: no undo point for this CT - --no-snapshot was given"
  hasnt "GUARD B7"
  image_has 105 "generation 7"
  done_scenario
fi

if scenario "52: B7 does not fire on a presync round - nothing is irreversible yet"; then
  fail_zfs "snapshot tank/hosting"
  run_engine --all
  rc_is 0; clean
  hasnt "GUARD B7"
  untraced "zfs snapshot"
  done_scenario
fi

if scenario "53: --list names the ssh that a failback would refuse on, and exits non-zero"; then
  # Reported from real hardware: the copies were up, production was down, and
  # every CT stopped at GUARD B1 with "cannot reach pve-r32". The storage node
  # is outside the cluster on purpose, so it has neither the cluster's hosts
  # file nor its keys, and nothing had ever said that failback needs root ssh
  # to every compute node BY NAME. --list is the place to find that out on an
  # ordinary Tuesday, so it has to say it, and it must not exit 0 while saying
  # it - a green --list is what somebody files as "checked".
  node_down pve01
  run_engine --list
  rc_is 1
  has "PROD unreachable for"
  has "a failback would refuse at GUARD B1"
  has "ssh -o BatchMode=yes root@pve01 true"
  has "ssh-copy-id"
  untraced "rsync"
  done_scenario
fi

if scenario "54: --list with every production node reachable stays quiet and exits 0"; then
  run_engine --list
  rc_is 0
  hasnt "PROD unreachable"
  done_scenario
fi

if scenario "55: a copy id typed instead of a source id is told which one to use"; then
  # 9110 is the number on the screen during a DR, so it is the number that gets
  # typed. The tool is driven by the SOURCE id.
  run_engine --ctid 8105
  rc_is 1
  has "8105 is the COPY of CT 105"
  has "--ctid 105"
  untraced "rsync"
  done_scenario
fi

echo
echo "=== $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then echo "failed: ${FAILED_NAMES[*]}"; exit 1; fi
exit 0
