#!/usr/bin/env bash
# =============================================================================
#  run-sim-replica.sh — execute ct-replica.sh against a fake storage node and a
#  fake backup node
# -----------------------------------------------------------------------------
#  Why this exists: the engine can only be run on nfs01, against live customer
#  CTs, with a real backup node on the other end of the ssh. That is a terrible
#  place to find out a guard moved. The fakes in replica/bin implement the same
#  *invariants* R1..R11 protect, and scream into sim/violations when one breaks:
#
#    - rsync into a destination no MOUNTED dataset owns  (R3: fills bkp root fs)
#    - rsync into a copy that is RUNNING                 (R2: DR was promoted)
#    - rsync --delete into another guest's rootfs        (R4, G7's analogue)
#    - loop-mounting the live image instead of the clone (R1: a torn copy)
#    - loop-mounting rw, without noload, or twice        (R6)
#    - a copy config on a bridge that is not the island  (R9/R11)
#    - zfs destroy of anything this run did not create
#
#  A scenario can therefore FAIL in two different ways: wrong observable
#  behaviour (log/exit code/state file), or a broken invariant (the violations
#  file is non-empty). The second one is the one that matters.
#
#  The engine sets its own PATH (cron gives it a useless one), so a fake cannot
#  reach it by prepending a directory. run_engine exports shell FUNCTIONS
#  instead: bash looks those up before PATH and inherits them through the
#  environment, which is the one hook left on an engine that owns its PATH.
#
#  usage:  ./tests/sim/replica/run-sim-replica.sh            every scenario
#          ./tests/sim/replica/run-sim-replica.sh 7          scenario 7 only
#          KEEP=1 ./tests/sim/replica/run-sim-replica.sh 7   keep the sandbox
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"      # repo root: the engine lives there
ENGINE="${ENGINE:-$ROOT/ct-replica.sh}"   # overridable, the way run-sim.sh is

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

# ---------- sandbox ----------
new_world(){
  SIMROOT="$(mktemp -d /tmp/ctrep-sim.XXXXXX)"
  export SIMROOT SIMLIB="$HERE/lib.sh" SIMBIN="$HERE/bin"
  WORK="$SIMROOT/work"; BKP="$SIMROOT/bkp"
  mkdir -p "$WORK" "$SIMROOT/mnt" "$SIMROOT/z" "$SIMROOT/storage" \
           "$BKP/fs/etc/pve/nodes" "$BKP/ct" "$BKP/storage" "$BKP/bridges"
  : > "$SIMROOT/mounted";     : > "$SIMROOT/violations";  : > "$SIMROOT/trace"
  : > "$SIMROOT/loopmap";     : > "$SIMROOT/fs.tsv";      : > "$SIMROOT/zfs.tsv"
  : > "$SIMROOT/mount.fail";  : > "$SIMROOT/umount.fail"; : > "$SIMROOT/zfs.fail"
  : > "$SIMROOT/cfgwrite.trunc"; : > "$BKP/zfs.tsv";     : > "$SIMROOT/ctlpath"
  echo 0 > "$SIMROOT/rsync.n"; echo "0 0 0 0 0 0" > "$SIMROOT/rsync.rc"
  # files literal sent total - what the fake rsync reports in its --stats block
  echo "161 2469606195 2470127483 118111600640" > "$SIMROOT/rsync.stats"

  # The node root filesystem. Anything with no mounted ancestor lands here, and
  # a storage that lands here is exactly what R1 refuses to read.
  add_fs / ext4 rpool/ROOT/pve-1

  # Two source storages of deliberately different shape, both real on this
  # fleet: tank-hdd-nas IS its dataset's mountpoint, tank-ssd-nas is a
  # subdirectory inside one. R1 has to re-root both into the clone correctly.
  add_zfs tank/hosting "$SIMROOT/pool/tank/hosting"
  add_storage tank-hdd-nas "$SIMROOT/pool/tank/hosting"
  add_zfs tank-ssd "$SIMROOT/pool/tank-ssd"
  add_storage tank-ssd-nas "$SIMROOT/pool/tank-ssd/hosting-ssd"
  add_image tank-hdd-nas 105
  add_image tank-ssd-nas 113

  # the backup node: identity, the island bridge, both dest tiers
  bkp_identity bkp02 "bkp02 pve01 pve02"
  bkp_node_dir bkp02; bkp_node_dir pve01; bkp_node_dir pve02
  bkp_bridge vmbr99 "vlan99 internal"
  bkp_storage replica-hdd active; bkp_storage replica-ssd active
  bkp_dataset replica-hdd/ct yes /replica-hdd/ct
  bkp_dataset replica-ssd/ct yes /replica-ssd/ct

  add_src_ct pve01 105 tank-hdd-nas 20G \
    "net0: name=eth0,bridge=vmbr0,hwaddr=BC:24:11:00:01:05,ip=10.100.50.5/24,gw=10.100.50.1,tag=50,type=veth"
  add_src_ct pve02 113 tank-ssd-nas 40G \
    "net0: name=eth0,bridge=vmbr0,hwaddr=BC:24:11:00:01:13,ip=10.100.60.13/24,tag=60,type=veth"

  # the engine resolves BASE from its own path; a symlink keeps BASE in the
  # sandbox, because ${BASH_SOURCE[0]} is not symlink-resolved
  ln -s "$ENGINE" "$WORK/ct-replica.sh"
  write_conf
  inventory "105" "113	ssd"
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
unmount_fs(){ grep -vxF "${1%/}" "$SIMROOT/mounted" > "$SIMROOT/.m"
              mv -f "$SIMROOT/.m" "$SIMROOT/mounted"; }
retype_fs(){  # mountpoint fstype source - turn a dataset into something with no
              # snapshots, which is the whole of the LIVE_FALLBACK question
  awk -F'\t' -v m="${1%/}" '$1!=m' "$SIMROOT/fs.tsv" > "$SIMROOT/.f"
  mv -f "$SIMROOT/.f" "$SIMROOT/fs.tsv"
  awk -F'\t' -v n="$3" '$1!=n' "$SIMROOT/zfs.tsv" > "$SIMROOT/.z"
  mv -f "$SIMROOT/.z" "$SIMROOT/zfs.tsv"
  printf '%s\t%s\t%s\n' "${1%/}" "$2" "$3" >> "$SIMROOT/fs.tsv"; }
add_storage(){ mkdir -p "$2"; printf '%s\n' "$2" > "$SIMROOT/storage/$1.path"; }
add_image(){   # storage-id ctid [generation]
  local p; p="$(cat "$SIMROOT/storage/$1.path")"
  mkdir -p "$p/images/$2"
  printf 'rootfs of CT %s, generation %s\n' "$2" "${3:-1}" > "$p/images/$2/vm-$2-disk-0.raw"; }
fail_zfs(){ printf '%s\n' "$1" >> "$SIMROOT/zfs.fail"; }   # e.g. "snapshot tank/hosting"

# ---------- the backup node ----------
bkp_identity(){ printf '%s\n' "$1" > "$BKP/node"; printf '%s\n' "$2" > "$BKP/nodes"; }
bkp_node_dir(){ mkdir -p "$BKP/fs/etc/pve/nodes/$1/lxc" "$BKP/fs/etc/pve/nodes/$1/qemu-server"; }
bkp_bridge(){   local b="$1"; shift; printf '%s\n' "$@" > "$BKP/bridges/$b"; }
bkp_storage(){  printf '%s\n' "$2" > "$BKP/storage/$1"; }
bkp_dataset(){  # dataset mounted(yes|no) mountpoint
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$BKP/zfs.tsv"
  [[ "$2" == yes ]] && mkdir -p "$BKP/fs$3"; return 0; }
bkp_ct(){ printf '%s\n' "$2" > "$BKP/ct/$1.status"; }      # vmid status
bkp_cfg(){ # node vmid <<<text - a guest config that is already over there
  mkdir -p "$BKP/fs/etc/pve/nodes/$1/lxc"; cat > "$BKP/fs/etc/pve/nodes/$1/lxc/$2.conf"; }
add_src_ct(){ # node ctid storage size [extra config lines...]
  local node="$1" id="$2" sid="$3" size="$4"; shift 4
  mkdir -p "$BKP/fs/etc/pve/nodes/$node/lxc"
  { printf 'arch: amd64\ncores: 2\nhostname: ct%s.example\nmemory: 2048\n' "$id"
    printf 'rootfs: %s:%s/vm-%s-disk-0.raw,size=%s\nswap: 512\n' "$sid" "$id" "$id" "$size"
    (( $# )) && printf '%s\n' "$@"
    printf 'onboot: 1\n'; } > "$BKP/fs/etc/pve/nodes/$node/lxc/$id.conf"; }
cluster_resources(){ # vmid:type... - what pvesh answers under AUTO_DISCOVER
  local out="[" first=1 e
  for e in "$@"; do
    (( first )) || out+=","; first=0
    out+="{\"vmid\":${e%%:*},\"type\":\"${e#*:}\",\"node\":\"pve01\",\"status\":\"running\"}"
  done
  printf '%s]\n' "$out" > "$BKP/resources.json"; }

# ---------- what the engine reads out of its own folder ----------
write_conf(){
  cat > "$WORK/ctrep.conf" <<EOF
BKP_SSH="root@100.100.100.35"
BKP_DESTS="hdd=replica-hdd/ct:replica-hdd ssd=replica-ssd/ct:replica-ssd"
DEFAULT_DEST="hdd"
SRC_STORAGES="tank-hdd-nas tank-ssd-nas"
LIVE_FALLBACK=0
MOCKNET=1
MOCKNET_BRIDGE=vmbr99
MOCKNET_TAG=""
OFFSET=8000
AUTO_DISCOVER=0
BW_TOTAL_MB=230
LANES=1
BW_MIN_MB=20
LOG_KEEP_DAYS=14
RUNS_KEEP=200
MNT_BASE=$SIMROOT/mnt
EOF
  SIM_MOCK_BRIDGE=vmbr99; }
conf_set(){ # key value
  { grep -v "^$1=" "$WORK/ctrep.conf" || true; } > "$WORK/.conf"
  mv -f "$WORK/.conf" "$WORK/ctrep.conf"
  printf '%s=%s\n' "$1" "$2" >> "$WORK/ctrep.conf"
  [[ "$1" == MOCKNET_BRIDGE ]] && SIM_MOCK_BRIDGE="$2"
  return 0; }
inventory(){ printf '%s\n' "$@" > "$WORK/inventory-replica.tsv"; }
exclude(){   printf '%s\n' "$@" > "$WORK/exclude.tsv"; }
truncate_cfg_write(){ printf '%s\n' "$1" >> "$SIMROOT/cfgwrite.trunc"; }   # tgt vmid
kill_next_rsync(){ : > "$SIMROOT/rsync.kill"; }
rsync_rc(){ printf '%s\n' "$*" > "$SIMROOT/rsync.rc"; echo 0 > "$SIMROOT/rsync.n"; }
rsync_stats(){ printf '%s %s %s %s\n' "$1" "$2" "$3" "$4" > "$SIMROOT/rsync.stats"; }

# pretend another lane already holds a lock this run wants
HOLDER_PID=""
hold_lock(){ # $1 = lock file name inside BASE, e.g. .ct-8105.lock
  rm -f "$SIMROOT/holder.ready"
  ( exec 7>"$WORK/$1"; flock -n 7 || exit 1
    : > "$SIMROOT/holder.ready"; sleep 120 ) &
  HOLDER_PID=$!
  local i=0
  while [[ ! -f "$SIMROOT/holder.ready" && $i -lt 200 ]]; do sleep 0.02; i=$((i+1)); done
  [[ -f "$SIMROOT/holder.ready" ]] || echo "      x could not take $1 in the harness"; }
drop_lock(){ [[ -n "$HOLDER_PID" ]] && kill "$HOLDER_PID" 2>/dev/null
             HOLDER_PID=""; wait 2>/dev/null; return 0; }

pause_ct(){ mkdir -p "$WORK/pause"; printf '%s\n' "${2:-}" > "$WORK/pause/$1"; }
break_storage(){ unmount_fs "$SIMROOT/pool/tank/hosting"; }   # the node holding it is gone

hide_cmd(){ SIM_MISSING="$1"; }   # make one tool genuinely absent for the next run

run_engine(){
  ( export SIMROOT SIM_MISSING SIMLIB SIMBIN SIM_MOCK_BRIDGE
    # Armed from the ENGINE's own arguments, not from a scenario flag, so every
    # scenario that runs a dry engine is policed whether or not its author
    # thought about it. The fakes read it through dry_forbids in lib.sh.
    SIM_DRY=0
    for _a in "$@"; do [[ "$_a" == --dry-run ]] && SIM_DRY=1; done
    export SIM_DRY
    # see the header: PATH cannot reach an engine that sets its own, exported
    # functions can. Each one is a one-line shim onto replica/bin.
    pvesm(){      "$SIMBIN/pvesm"      "$@"; }
    zfs(){        "$SIMBIN/zfs"        "$@"; }
    ssh(){        "$SIMBIN/ssh"        "$@"; }
    rsync(){      "$SIMBIN/rsync"      "$@"; }
    mount(){      "$SIMBIN/mount"      "$@"; }
    umount(){     "$SIMBIN/umount"     "$@"; }
    mountpoint(){ "$SIMBIN/mountpoint" "$@"; }
    findmnt(){    "$SIMBIN/findmnt"    "$@"; }
    df(){         "$SIMBIN/df"         "$@"; }
    hostname(){   "$SIMBIN/hostname"   "$@"; }
    losetup(){    "$SIMBIN/losetup"    "$@"; }
    truncate(){   "$SIMBIN/truncate"   "$@"; }
    resize2fs(){  "$SIMBIN/resize2fs"  "$@"; }
    e2fsck(){     "$SIMBIN/e2fsck"     "$@"; }
    export -f pvesm zfs ssh rsync mount umount mountpoint findmnt df hostname \
              losetup truncate resize2fs e2fsck
    # A scenario can make one tool genuinely absent. `command -v` finds an
    # exported function, so hiding a tool means shadowing `command` itself -
    # and the tool must also behave the way a missing one does, which is exit
    # 127, because that is what turns `flock -n 9` into "the lock is held".
    if [[ -n "${SIM_MISSING:-}" ]]; then
      command(){ if [[ "$1" == -v && "$2" == "${SIM_MISSING}" ]]; then return 1; fi
                 builtin command "$@"; }
      eval "${SIM_MISSING}(){ echo \"bash: ${SIM_MISSING}: command not found\" >&2; return 127; }"
      # shellcheck disable=SC2163  # exporting the function NAMED by the var, on purpose
      export -f command "${SIM_MISSING}"
    fi
    "$WORK/ct-replica.sh" "$@" ) > "$SIMROOT/out" 2>&1
  RC=$?
  OUT="$(cat "$SIMROOT/out")"
  TRACE="$(cat "$SIMROOT/trace")"
  VIO="$(cat "$SIMROOT/violations")"
}

# ---------- assertions ----------
# Each engine writes state/<tool>-<ctid>.json so two tools can hold history
# for the same container at once. One place decides the path here too, so
# the next rename is one edit rather than a dozen.
st_file(){ printf '%s\n' "$WORK/state/replica-$1.json"; }
st_hist(){ printf '%s\n' "$WORK/state/replica-$1.runs.jsonl"; }
_err(){ echo "      x $*"; SCEN_OK=0; }
has(){    grep -qF -- "$1" <<<"$OUT" || _err "expected in log: $1"; }
hasnt(){  grep -qF -- "$1" <<<"$OUT" && _err "should NOT be in log: $1"; return 0; }
traced(){ grep -qF -- "$1" <<<"$TRACE" || _err "expected command: $1"; }
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
clean(){ [[ -z "$VIO" ]] || { _err "INVARIANT BROKEN:"; sed 's/^/         /' <<<"$VIO"; }; }
# the daily log file, for the lines that deliberately bypass log()
log_has(){ grep -qF -- "$1" "$WORK"/logs/replica-*.log 2>/dev/null \
             || _err "expected in the log file: $1"; }

_cfg(){ printf '%s\n' "$BKP/fs/etc/pve/nodes/${2:-bkp02}/lxc/$1.conf"; }
cfg_exists(){ [[ -f "$(_cfg "$1")" ]] || _err "copy config $1 is missing on bkp02"; }
cfg_absent(){ [[ -f "$(_cfg "$1")" ]] && _err "copy config $1 must NOT exist on bkp02"; return 0; }
cfg_has(){   grep -qF -- "$2" "$(_cfg "$1")" 2>/dev/null || _err "copy config $1: expected '$2'"; }
cfg_hasnt(){ grep -qE -- "$2" "$(_cfg "$1")" 2>/dev/null && _err "copy config $1: must not match '$2'"; return 0; }

# what actually landed in the copy's dataset on the backup node
copy_has(){ [[ -f "$BKP/fs$1/$2" ]] || _err "$1/$2 did not reach the backup"; }
copy_absent(){ [[ -f "$BKP/fs$1/$2" ]] && _err "$1/$2 must NOT be on the backup"; return 0; }
copy_file_has(){ grep -qF -- "$3" "$BKP/fs$1/$2" 2>/dev/null \
                   || _err "$1/$2: expected '$3', got '$(cat "$BKP/fs$1/$2" 2>/dev/null)'"; }

# ---------- ssh control sockets ----------
# The fake ssh records the -o ControlPath it was handed, once per invocation.
ctl_paths(){ awk -F'\t' '{print $2}' "$SIMROOT/ctlpath" 2>/dev/null | sort -u; }
ctl_reset(){ : > "$SIMROOT/ctlpath"; }
ctl_per_pid(){   # every socket this run asked for must be its own
  local bad
  [[ -s "$SIMROOT/ctlpath" ]] || { _err "no ssh ControlPath was recorded at all"; return 0; }
  # 'none' is the rsync transport, which deliberately shares nothing
  bad="$(awk -F'\t' '$2 != "none" && $2 !~ /^\/run\/ctrep-[0-9]+-/ {print $1 " -> " $2}' \
           "$SIMROOT/ctlpath" | sort -u)"
  [[ -z "$bad" ]] || { _err "ssh control socket with no pid in it - two lanes would share one master:"
                       sed 's/^/         /' <<<"$bad"; }
  return 0; }

# nothing may still be loop-mounted, and no point-in-time source may be left
# behind, however the run ended
nothing_mounted(){ local m; m="$(grep -F "$SIMROOT/mnt/" "$SIMROOT/mounted" 2>/dev/null)"
  [[ -z "$m" ]] || _err "still mounted after the run: $m"; return 0; }
no_zfs_leftovers(){ local l; l="$(awk -F'\t' '$2=="clone"||$2=="snap"{print $1}' "$SIMROOT/zfs.tsv")"
  [[ -z "$l" ]] || _err "snapshot/clone left behind: $l"; return 0; }

# ---------- state file assertions ----------
# The engine writes state/<src_ctid>.json next to itself, and BASE lands inside
# the sandbox. python3 is fine HERE - the engine itself must stay python-free,
# a Proxmox node has neither jq nor a guaranteed python3. Parsing with a real
# JSON parser is the point: it proves the hand-rolled writer emits something a
# reader can actually load.
_st_get(){  # $1=ctid $2=dotted path -> the value, or the literal string MISSING
  python3 - "$(st_file "$1")" "$2" <<'PY' 2>/dev/null || echo MISSING
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("MISSING"); sys.exit(0)
for k in sys.argv[2].split('.'):
    if isinstance(d, dict) and k in d:
        d = d[k]
    else:
        print("MISSING"); sys.exit(0)
if d is True:      print("true")
elif d is False:   print("false")
elif isinstance(d, list): print(",".join(str(x) for x in d))
else:              print(d)
PY
}
st_is(){ # $1=ctid $2=dotted path $3=expected
  local got; got="$(_st_get "$1" "$2")"
  [[ "$got" == "$3" ]] || _err "state $1: $2 = '$got', expected '$3'"; }
# The snapshot must exist and load. It is deliberately NOT checked against
# schema/state.schema.json: that schema describes ct-migrate's snapshot with
# additionalProperties:false, and a replica snapshot carries different identity
# fields - see the state/ namespace note in CLAUDE.md.
st_parses(){
  [[ -f "$(st_file "$1")" ]] || { _err "state file for $1 is missing"; return 0; }
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$(st_file "$1")" 2>/dev/null \
    || _err "state file for $1 is not valid JSON"; return 0; }
st_absent(){ [[ -f "$(st_file "$1")" ]] && _err "state file for $1 must NOT exist"; return 0; }
runs_count(){ local n; n="$(wc -l < "$(st_hist "$1")" 2>/dev/null || echo 0)"
  [[ "$n" == "$2" ]] || _err "history $1: $n runs, expected $2"; }
runs_valid(){ local f; f="$(st_hist "$1")"
  [[ -f "$f" ]] || { _err "history for $1 is missing"; return 0; }
  python3 - "$f" <<'PY' || _err "history for $1 has a line that is not valid JSON"
import json, sys
for i, line in enumerate(open(sys.argv[1]), 1):
    line = line.strip()
    if not line:
        continue
    try:
        json.loads(line)
    except Exception as e:
        print("         line %d: %s" % (i, e)); sys.exit(1)
PY
  return 0; }
runs_last(){ local got
  got="$(tail -n 1 "$(st_hist "$1")" 2>/dev/null | python3 -c '
import json, sys
d = json.loads(sys.stdin.read() or "{}")
for k in sys.argv[1].split("."):
    d = d.get(k, "MISSING") if isinstance(d, dict) else "MISSING"
print(d)' "$2" 2>/dev/null)"
  [[ "$got" == "$3" ]] || _err "history $1 last: $2 = '$got', expected '$3'"; }

scenario(){
  N="${1%%:*}"
  [[ -n "$ONLY" && "$ONLY" != "$N" ]] && return 1
  # Reset here, not in the helper: a scenario that hides a tool must not hide it
  # from every scenario that follows. This leaked once and the symptom was
  # scenarios that pass alone and fail in the suite, which is the worst kind.
  SIM_MISSING=""
  echo "  [$1]"; SCEN_OK=1; new_world; return 0; }
done_scenario(){
  drop_lock
  if (( SCEN_OK )); then PASS=$((PASS+1)); echo "      ok"
  else FAIL=$((FAIL+1)); FAILED_NAMES+=("$N"); fi
  if [[ -n "${KEEP:-}" ]]; then echo "      sandbox: $SIMROOT"; else rm -rf "$SIMROOT"; fi; }

# the clone names the engine derives, spelled out once so the scenarios read
CLONE_HDD="tank/ctrep-clone-all-tank_hosting"
CLONE_SSD="tank-ssd/ctrep-clone-all-tank-ssd"

echo "=== ct-replica.sh simulator ==="

if scenario "1: happy path, two CTs, two source storages, two dest tiers"; then
  run_engine
  rc_is 0; clean
  has "R9: vmbr99 ok on bkp02 (no uplink)"
  has "=== lane 'all' finished: ok=2 skipped=0 failed=0 ==="
  cfg_exists 8105; cfg_exists 8113
  cfg_has 8105 "rootfs: replica-hdd:subvol-8105-disk-0,size=20G"
  cfg_has 8113 "rootfs: replica-ssd:subvol-8113-disk-0,size=40G"
  cfg_has 8105 "onboot: 0"
  cfg_has 8105 "hostname: ct105.example"
  # the copy keeps the source's real address and MAC, on the island bridge
  cfg_has 8105 "net0: name=eth0,bridge=vmbr99,hwaddr=BC:24:11:00:01:05,ip=10.100.50.5/24,gw=10.100.50.1,tag=50,type=veth"
  cfg_hasnt 8105 'bridge=vmbr0'
  # the log is a deliverable: a rule between containers, and a header naming
  # which copy this block is about.
  has "##############################################################################"
  # the run, the container list, and between containers - three edges, three
  # rules, so a boundary says which kind it is
  has "=============================================================================="
  has "------------------------------------------------------------------------------"
  has "[105] CT 105 on tank-hdd-nas  ->  copy 8105 on bkp02, dest=hdd"
  copy_has /replica-hdd/ct/subvol-8105-disk-0 rootfs.txt
  copy_has /replica-ssd/ct/subvol-8113-disk-0 rootfs.txt
  # the option set: --delete is what makes the copy identical rather than
  # additive, and --bwlimit is the 2 Gbps ceiling this fleet runs on
  traced "rsyncopt --delete"
  traced "rsyncopt --numeric-ids"
  traced "rsyncopt --inplace"
  traced "rsyncopt --bwlimit=230m"
  traced "rsyncopt --timeout=300"
  nothing_mounted; no_zfs_leftovers
    log_lands_here replica
done_scenario
fi

if scenario "2: R1 the bytes come out of the clone, and the clone does not outlive the run"; then
  run_engine --ctid 105
  rc_is 0; clean
  has "R1: 'tank-hdd-nas' point-in-time ready (tank/hosting@ctrep-all -> $CLONE_HDD)"
  traced "zfs snapshot tank/hosting@ctrep-all"
  traced "zfs clone tank/hosting@ctrep-all $CLONE_HDD"
  traced "mount -o loop,ro,noload $SIMROOT/z/$CLONE_HDD/images/105/vm-105-disk-0.raw"
  # what landed on the backup names where it was read from
  copy_file_has /replica-hdd/ct/subvol-8105-disk-0 .image "$SIMROOT/z/$CLONE_HDD/"
  copy_file_has /replica-hdd/ct/subvol-8105-disk-0 rootfs.txt "rootfs of CT 105, generation 1"
  no_zfs_leftovers; nothing_mounted
  done_scenario
fi

if scenario "3: R1 a storage that is a SUBDIR of its dataset is re-rooted, not guessed"; then
  # tank-ssd-nas is /tank-ssd/hosting-ssd inside the dataset tank-ssd. Losing
  # that suffix would read the wrong path out of the clone, or nothing at all.
  run_engine --ctid 113
  rc_is 0; clean
  traced "mount -o loop,ro,noload $SIMROOT/z/$CLONE_SSD/hosting-ssd/images/113/vm-113-disk-0.raw"
  has "[113] OK -> 8113 (rc=0)"
  done_scenario
fi

if scenario "4: R1 a storage whose backing filesystem is not mounted is refused"; then
  unmount_fs "$SIMROOT/pool/tank/hosting"
  run_engine
  rc_is 1; clean
  has "GUARD R1: $SIMROOT/pool/tank/hosting sits on the ROOT filesystem"
  has "[105] source 'tank-hdd-nas' is down - skip"
  untraced "mount -o loop,ro,noload $SIMROOT/pool/tank/hosting"
  cfg_absent 8105
  cfg_exists 8113                      # the other storage keeps working
  st_is 105 last.reason source_down
  done_scenario
fi

if scenario "5: R1 a non-ZFS source has no point in time, so it is refused"; then
  retype_fs "$SIMROOT/pool/tank-ssd" xfs /dev/sdc1 tank-ssd
  run_engine --ctid 113
  rc_is 1; clean
  has "GUARD R1: 'tank-ssd-nas' is on xfs - no snapshots, point-in-time copy impossible"
  has "set LIVE_FALLBACK=1"
  untraced "rsync"
  cfg_absent 8113
  st_is 113 last.reason source_down
  done_scenario
fi

if scenario "6: R1 LIVE_FALLBACK=1 reads the live image and says so every round"; then
  retype_fs "$SIMROOT/pool/tank-ssd" xfs /dev/sdc1 tank-ssd
  conf_set LIVE_FALLBACK 1
  run_engine --ctid 113
  rc_is 0; clean                       # a live read on a non-ZFS fs is not a violation
  has "WARN R1: 'tank-ssd-nas' is on xfs - syncing from LIVE images (no point-in-time; LIVE_FALLBACK=1)"
  traced "mount -o loop,ro,noload $SIMROOT/pool/tank-ssd/hosting-ssd/images/113/vm-113-disk-0.raw"
  untraced "zfs snapshot"
  cfg_exists 8113
  done_scenario
fi

if scenario "7: R1 a snapshot that cannot be taken stops that storage, not the run"; then
  fail_zfs "snapshot tank/hosting"
  run_engine
  rc_is 1; clean
  has "GUARD R1: snapshot/clone failed for tank/hosting - see log"
  cfg_absent 8105
  cfg_exists 8113
  has "ok=1 skipped=1 failed=0"
  done_scenario
fi

if scenario "8: R1 a clone that is not mounted is refused before anything is read"; then
  : > "$SIMROOT/clone.nomount"
  run_engine --ctid 105
  rc_is 1; clean
  has "GUARD R1: clone $CLONE_HDD not mounted"
  untraced "rsync"
  cfg_absent 8105
  done_scenario
fi

if scenario "9: R2 a RUNNING copy is skipped, never overwritten"; then
  # a running copy means DR was promoted: that filesystem is the live system now
  bkp_ct 8105 running
  bkp_dataset replica-hdd/ct/subvol-8105-disk-0 yes /replica-hdd/ct/subvol-8105-disk-0
  printf 'promoted\n' > "$BKP/fs/replica-hdd/ct/subvol-8105-disk-0/rootfs.txt"
  run_engine --ctid 105
  rc_is 0; clean                       # skipped, not failed: a human is on it
  has "GUARD R2: copy 8105 is RUNNING on bkp02 (DR active?) - SKIP + check by hand"
  untraced "rsync"
  copy_file_has /replica-hdd/ct/subvol-8105-disk-0 rootfs.txt promoted
  has "ok=0 skipped=1 failed=0"
  st_is 105 last.status skipped; st_is 105 last.reason r2_running
  done_scenario
fi

if scenario "10: R3 a destination dataset that is not mounted is refused"; then
  bkp_dataset replica-hdd/ct/subvol-8105-disk-0 no /replica-hdd/ct/subvol-8105-disk-0
  run_engine --ctid 105
  rc_is 1; clean
  has "GUARD R3: replica-hdd/ct/subvol-8105-disk-0 NOT MOUNTED on backup (mounted=no)"
  untraced "rsync"
  cfg_absent 8105
  st_is 105 last.status failed; st_is 105 last.reason r3_not_mounted
  done_scenario
fi

if scenario "11: R3 a missing destination dataset is created once, then synced"; then
  run_engine --ctid 105
  rc_is 0; clean
  traced "bkp zfs create replica-hdd/ct/subvol-8105-disk-0"
  has "[105] OK -> 8105 (rc=0)"
  st_is 105 dest_dataset replica-hdd/ct/subvol-8105-disk-0
  done_scenario
fi

if scenario "12: R4 a target VMID that belongs to another guest gets no copy"; then
  # one wrong digit in the tgt_ctid column points a row at an id somebody else
  # owns - and that guest's rootfs is the dataset this row would --delete into.
  # R4 is the R-series' G7, and it has to run BEFORE anything is transferred:
  # R2 above only sees a copy that is RUNNING on the backup node and R8 only
  # reads that node's own config directory, so a STOPPED guest on ANOTHER node
  # is invisible to both.
  bkp_cfg pve01 8105 <<'EOF'
arch: amd64
hostname: someone-else
rootfs: replica-hdd:subvol-8105-disk-0,size=8G
onboot: 1
EOF
  bkp_dataset replica-hdd/ct/subvol-8105-disk-0 yes /replica-hdd/ct/subvol-8105-disk-0
  printf 'the other guest rootfs\n' > "$BKP/fs/replica-hdd/ct/subvol-8105-disk-0/rootfs.txt"
  run_engine --ctid 105
  rc_is 1
  has "GUARD R4: VMID 8105 already belongs to another guest - NOT syncing"
  has "GUARD R4:   /etc/pve/nodes/pve01/lxc/8105.conf"
  has "rsync --delete into that guest's volume would empty its rootfs"
  cfg_absent 8105
  st_is 105 last.status failed; st_is 105 last.reason r4_vmid_taken
  untraced "rsync"                     # nothing may move before the id is cleared
  copy_file_has /replica-hdd/ct/subvol-8105-disk-0 rootfs.txt "the other guest rootfs"
  clean
  done_scenario
fi

if scenario "13: R5 rc=23 once is the ro,noload transient - loud, but still a failure"; then
  rsync_rc 23
  run_engine --ctid 105
  rc_is 1; clean
  has "HINT: rc=23 once is usually the ro,noload transient"
  has "GUARD R5: sync FAILED (rc=23) - copy config NOT created"
  hasnt "TWICE IN A ROW"
  cfg_absent 8105
  st_is 105 last.status failed; st_is 105 last.reason r5_rsync; st_is 105 last.rc 23
  done_scenario
fi

if scenario "14: R5 rc=23 twice on the same CT is a damaged image, not a transient"; then
  rsync_rc 23
  run_engine --ctid 105
  st_is 105 last.rc 23                 # the run before is the only witness
  rsync_rc 23
  run_engine --ctid 105
  rc_is 1; clean
  has "ERROR: rc=23 TWICE IN A ROW - not a transient any more"
  has "e2fsck -fn $SIMROOT/pool/tank/hosting/images/105/vm-105-disk-0.raw"
  untraced "e2fsck"                    # it tells the operator; it never repairs
  st_is 105 last.reason r5_rsync_repeat
  runs_count 105 2
  done_scenario
fi

if scenario "15: R5 rc=24 (files vanished on a live CT) is success"; then
  rsync_rc 24
  run_engine --ctid 105
  rc_is 0; clean
  has "[105] OK -> 8105 (rc=24)"
  cfg_exists 8105
  st_is 105 last.status ok; st_is 105 last.rc 24
  done_scenario
fi

if scenario "16: rc=11 is a plain failure here - nothing grows and nothing retries"; then
  # ct-migrate grows the image 5% and retries (G4). There is no image to grow on
  # this side: the destination is a ZFS dataset, so out-of-space is somebody
  # adding disks, not something the engine can work around.
  rsync_rc 11 0 0 0
  run_engine --ctid 105
  rc_is 1; clean
  has "GUARD R5: sync FAILED (rc=11) - copy config NOT created"
  untraced "truncate"; untraced "resize2fs"
  cfg_absent 8105
  st_is 105 last.rc 11; st_is 105 last.reason r5_rsync
  done_scenario
fi

if scenario "17: a config that does not read back as sent is cfg_write, not a warning"; then
  truncate_cfg_write 8105
  run_engine --ctid 105
  rc_is 1; clean
  has "ERROR: the config on bkp02 does not match what was sent (truncated write)"
  has "the rootfs data is fine"        # the transfer is not lost, so say so
  st_is 105 last.status failed; st_is 105 last.reason cfg_write; st_is 105 last.rc 0
  done_scenario
fi

if scenario "18: R5 an existing copy config is never rewritten"; then
  run_engine --ctid 105
  # a human edited the copy during a drill, the way DR actually goes
  printf 'description: touched by hand during the drill\n' >> "$(_cfg 8105)"
  rsync_rc 0
  run_engine --ctid 105
  rc_is 0; clean
  cfg_has 8105 "touched by hand during the drill"
  hasnt "INIT: created copy config"
  # the config the first run wrote is already on the island, so R11 has nothing
  # to say about it - a warning here every round would train the operator to
  # ignore the one round where it means something
  hasnt "WARN R11"
  st_is 105 config_present true
  st_is 105 mocknet true
  runs_count 105 2
  done_scenario
fi

if scenario "19: R8 an existing copy config pointing at another dest refuses the row"; then
  bkp_cfg bkp02 8105 <<'EOF'
arch: amd64
hostname: ct105.example
rootfs: replica-ssd:subvol-8105-disk-0,size=20G
onboot: 0
EOF
  run_engine --ctid 105
  rc_is 1; clean
  has "GUARD R8: copy 8105 config points at 'replica-ssd' but this row's dest 'hdd' means 'replica-hdd'"
  untraced "rsync"                     # refused before a byte moves either way
  st_is 105 last.status failed; st_is 105 last.reason r8_dest_changed
  done_scenario
fi

if scenario "20: R9 an uplink on the island bridge refuses the WHOLE run"; then
  bkp_bridge vmbr99 "vlan99 internal" "enp3s0f0 nic"
  run_engine
  rc_is 2; clean
  has "GUARD R9: vmbr99 on bkp02 HAS AN UPLINK - NOTHING was run"
  has "port 'enp3s0f0' is a physical NIC or a bond"
  has "MAY BE COLLIDING WITH PRODUCTION NOW"
  untraced "rsync"; untraced "zfs snapshot"
  st_absent 105
  done_scenario
fi

if scenario "21: R9 a bond on the island bridge counts as an uplink too"; then
  bkp_bridge vmbr99 "bond0 bond"
  run_engine --ctid 105
  rc_is 2; clean
  has "port 'bond0' is a physical NIC or a bond"
  untraced "rsync"
  done_scenario
fi

if scenario "22: R9 a mock bridge that does not exist is named as missing"; then
  # the operator has not built the island yet. The engine has a message for
  # exactly this, telling them what to create - see the MISSING branch.
  rm -f "$BKP/bridges/vmbr99"
  run_engine
  rc_is 2; clean
  has "GUARD R9: bridge vmbr99 does not exist on bkp02 - NOTHING was run"
  has "or set MOCKNET=0 in ctrep.conf"
  untraced "rsync"
  done_scenario
fi

if scenario "23: R9 an unreachable backup node is not mistaken for a clean bridge"; then
  : > "$BKP/r9.fail"
  run_engine
  rc_is 2; clean
  has "GUARD R9: cannot inspect vmbr99 on bkp02 (ssh failed?) - NOTHING was run"
  untraced "rsync"
  done_scenario
fi

if scenario "24: MOCKNET=0 skips the bridge check and makes a copy with no network"; then
  conf_set MOCKNET 0
  rm -f "$BKP/bridges/vmbr99"           # irrelevant when no copy gets a net line
  run_engine --ctid 105
  rc_is 0; clean
  hasnt "GUARD R9"
  cfg_exists 8105
  cfg_hasnt 8105 '^net[0-9]+:'
  cfg_has 8105 "onboot: 0"
  st_is 105 mocknet false
  done_scenario
fi

if scenario "25: MOCKNET_TAG forces every copy onto one VLAN"; then
  conf_set MOCKNET_TAG 99
  run_engine --ctid 105
  rc_is 0; clean
  cfg_has 8105 "bridge=vmbr99"
  cfg_has 8105 ",tag=99"
  cfg_hasnt 8105 'tag=50'
  done_scenario
fi

if scenario "26: R10 a target another lane is already syncing is skipped, not doubled"; then
  # two rsyncs with --delete into one dataset is how a hand-run meets cron
  hold_lock .ct-8105.lock
  run_engine --ctid 105
  rc_is 0; clean                        # busy is not an error: the next run gets it
  has "NOTE: copy 8105 is being synced by another lane right now - skip"
  has "ok=0 skipped=1 failed=0"
  untraced "rsync"
  cfg_absent 8105
  st_is 105 last.status skipped; st_is 105 last.reason target_busy
  done_scenario
fi

if scenario "27: R10 the target lock is released, so the very next run proceeds"; then
  hold_lock .ct-8105.lock
  run_engine --ctid 105
  has "skipped=1"
  drop_lock
  rsync_rc 0
  run_engine --ctid 105
  rc_is 0; clean
  has "ok=1 skipped=0 failed=0"
  cfg_exists 8105
  runs_count 105 2
  done_scenario
fi

if scenario "28: R7 another run in the same lane just leaves"; then
  hold_lock .replica-all.lock
  run_engine
  rc_is 0
  has "another run active in lane 'all' - skip"
  untraced "ssh"                        # it does not even reach the backup node
  st_absent 105
  done_scenario
fi

if scenario "29: R7 the snapshot and the clone carry the lane name"; then
  # an 'all' run and a per-storage run overlap by design, so they must never be
  # able to destroy each other's point-in-time source
  run_engine --storage tank-hdd-nas
  rc_is 0; clean
  has "lane=tank-hdd-nas"
  traced "zfs snapshot tank/hosting@ctrep-tank-hdd-nas"
  traced "zfs clone tank/hosting@ctrep-tank-hdd-nas tank/ctrep-clone-tank-hdd-nas-tank_hosting"
  untraced "zfs snapshot tank/hosting@ctrep-all"
  no_zfs_leftovers
  done_scenario
fi

if scenario "30: R11 a stopped copy left on a production bridge is warned about"; then
  bkp_cfg bkp02 8105 <<'EOF'
arch: amd64
hostname: ct105.example
rootfs: replica-hdd:subvol-8105-disk-0,size=20G
onboot: 0
net0: name=eth0,bridge=vmbr0,hwaddr=BC:24:11:00:01:05,ip=10.100.50.5/24,tag=50,type=veth
EOF
  bkp_ct 8105 stopped
  run_engine --ctid 105
  rc_is 0; clean
  has "WARN R11: copy 8105 is STOPPED but its net is NOT on vmbr99"
  has "a DR promotion was not reverted"
  has "fix: put every net line back on bridge=vmbr99"
  cfg_has 8105 "bridge=vmbr0"           # never silently fixed: it is theirs
  st_is 105 mocknet false
  st_is 105 last.status ok              # the sync itself still ran
  done_scenario
fi

if scenario "31: PAUSE stops everything before the engine touches the backup node"; then
  : > "$WORK/PAUSE"
  run_engine
  rc_is 0
  has "PAUSED by $WORK/PAUSE - nothing will be synced until that file is removed"
  untraced "ssh"
  untraced "zfs snapshot"
  st_absent 105
  done_scenario
fi

if scenario "31b: a MISSING inventory is a wiring mistake, not an empty workload"; then
  # This is the one that would have bitten on deployment day. The file was
  # renamed - inventory-migrate.tsv is ct-migrate's now - and without this guard the
  # parse block is simply skipped, the CT list comes out empty, and every cron
  # tick logs "nothing to do" and exits 0 while the whole fleet goes
  # unreplicated. Fifteen minutes at a time, looking healthy.
  rm -f "$WORK/inventory-replica.tsv"
  run_engine
  rc_is 2; clean
  has "ERROR: no inventory at"
  has "NOT ct-migrate's inventory-migrate.tsv"
  has "cp"
  untraced "rsync"; untraced "zfs snapshot"
  st_absent 105
  done_scenario
fi

if scenario "31c: an inventory that exists but names nobody is a warning, not an error"; then
  # somebody commented every row out. That is a choice, and a non-zero exit
  # every fifteen minutes would train them to filter the mail. Say which file.
  inventory "# everything is paused for the maintenance window"
  run_engine
  rc_is 0; clean
  has "WARN:"
  has "names no CT - nothing is being replicated"
  untraced "rsync"
  done_scenario
fi

if scenario "31d: AUTO_DISCOVER=1 needs no inventory file at all"; then
  conf_set AUTO_DISCOVER 1
  rm -f "$WORK/inventory-replica.tsv"
  cluster_resources 105:lxc
  run_engine
  rc_is 0; clean
  hasnt "no inventory at"
  has "ok=1 skipped=0 failed=0"
  done_scenario
fi

if scenario "32: a duplicate src_ctid refuses the whole file, naming both lines"; then
  # the comment and the blank line are here so the reported line numbers have to
  # be real file lines; an off-by-one makes the message worse than useless
  inventory "# src_ctid  [tgt] [dest] [storage]" "" "105" "113	ssd" "105	9105"
  run_engine
  rc_is 2; clean
  has "ERROR: inventory is broken - NOTHING was run"
  has "line 5: src_ctid 105 already on line 3"
  untraced "rsync"; untraced "zfs snapshot"
  st_absent 105; st_absent 113
  done_scenario
fi

if scenario "33: two rows resolving to one target VMID refuse the whole file"; then
  # 105 defaults to 8105 and 113 is pointed at it by hand: two live CTs would
  # take turns overwriting one copy, and neither would ever be complete
  inventory "105" "113	8105"
  run_engine
  rc_is 2; clean
  has "line 2: target VMID 8105 already produced by line 1 - two sources would sync into one copy"
  untraced "rsync"
  done_scenario
fi

if scenario "34: a --storage or --ctid that matches nothing is loud, not a quiet success"; then
  # under cron, exit 0 with no work done is indistinguishable from a healthy
  # run: a lane can look fine for weeks while nothing at all is being copied
  inventory "105"
  run_engine --storage tank-ssd-nas
  rc_is 1
  has "ERROR: no CT matched --storage tank-ssd-nas - nothing was replicated"
  untraced "rsync"
  run_engine --ctid 9999
  rc_is 1
  has "ERROR: no CT matched --ctid 9999 - nothing was replicated"
  untraced "rsync"
  done_scenario
fi

if scenario "35: --storage runs one lane only, and the lane is the CT's real storage"; then
  run_engine --storage tank-ssd-nas
  rc_is 0; clean
  has "lane=tank-ssd-nas"; has "ok=1 skipped=0 failed=0"
  cfg_exists 8113
  cfg_absent 8105
  st_absent 105                         # this lane leaves the other lane's state alone
  done_scenario
fi

if scenario "36: an inventory storage assertion that no longer holds refuses the row"; then
  inventory "105	tank-ssd-nas"
  run_engine
  rc_is 1; clean
  has "ERROR: inventory asserts 'tank-ssd-nas' but the CT really lives on 'tank-hdd-nas'"
  untraced "rsync"
  st_is 105 last.reason storage_assert_mismatch
  done_scenario
fi

if scenario "37: AUTO_DISCOVER=1 that finds nothing is an ERROR, never a quiet exit 0"; then
  conf_set AUTO_DISCOVER 1
  cluster_resources 100:qemu 101:qemu
  run_engine
  rc_is 2; clean
  has "ERROR: AUTO_DISCOVER=1 but the cluster returned no container - NOTHING was run"
  untraced "rsync"
  done_scenario
fi

if scenario "38: AUTO_DISCOVER=1 skips the copies and the storages it may not read"; then
  conf_set AUTO_DISCOVER 1
  cluster_resources 105:lxc 113:lxc 900:lxc 8105:lxc 100:qemu
  add_src_ct pve01 900 local-lvm 8G
  bkp_cfg bkp02 8105 <<'EOF'
arch: amd64
hostname: ct105.example
rootfs: replica-hdd:subvol-8105-disk-0,size=20G
onboot: 0
EOF
  exclude "113"
  run_engine
  rc_is 0; clean
  has "candidates: 105 900 8105"
  has "[8105] NOTE: lives on bkp02 (a copy?) - auto-discover skips it"
  has "[900] NOTE: rootfs on 'local-lvm' (not in SRC_STORAGES) - auto-discover skips it"
  has "ok=1 skipped=0 failed=0"
  cfg_absent 8113                       # excluded, so never even a candidate
  st_absent 900; st_absent 8105         # a NOTE is not a verdict about a CT
  done_scenario
fi

if scenario "39: one broken row does not stop the rest of the run"; then
  inventory "105" "113	ssd" "150"
  run_engine
  rc_is 1; clean
  has "[150] ERROR: no config for CT 150 anywhere in the cluster - skip"
  has "ok=2 skipped=0 failed=1"
  has "NEEDS ATTENTION -> CT: 150"
  cfg_exists 8105; cfg_exists 8113
  st_is 150 last.reason no_source_config
  done_scenario
fi

if scenario "40: a dest that is not active on the backup node is caught before any data moves"; then
  bkp_storage replica-hdd inactive
  run_engine --ctid 105
  rc_is 1; clean
  has "ERROR: dest 'hdd': storage 'replica-hdd' is not active on bkp02"
  has "pvesm add zfspool replica-hdd --pool replica-hdd/ct"
  untraced "rsync"; untraced "zfs snapshot"
  st_is 105 last.reason dest_inactive
  done_scenario
fi

if scenario "41a: --all means the same thing here as it does in ct-failback.sh"; then
  # A no-op for this engine, on purpose: one command shape across all three.
  run_engine --all
  rc_is 0; clean
  traced "rsync"
  done_scenario
fi

if scenario "41b: an unset BKP_NODE is the normal case - the node is asked, and says so"; then
  # Nobody should have to type a pmxcfs name into a config file. write_conf no
  # longer sets one, so every other scenario in this file is running this path
  # too; this is the one that states it out loud.
  run_engine --ctid 105
  rc_is 0; clean
  has "backup node identifies itself as 'bkp02' (BKP_NODE is unset in"
  traced "rsync"
  done_scenario
fi

if scenario "41c: a node that will not say who it is refuses the run"; then
  bkp_identity "" ""
  run_engine
  rc_is 2; clean
  has "ERROR: cannot read the PVE node identity of root@100.100.100.35 - NOTHING was run"
  untraced "rsync"; untraced "zfs snapshot"
  done_scenario
fi

if scenario "41: the backup node not being the node ctrep.conf names refuses the run"; then
  # every check below this would pass, the whole rootfs would transfer, and only
  # the config write would fail - or worse, succeed on a compute node.
  # Pinning BKP_NODE is optional now, and this is what pinning it is FOR: it
  # means "refuse if this is not the machine I think it is".
  conf_set BKP_NODE '"bkp02"'
  bkp_identity pve03 "bkp02 pve01 pve02 pve03"
  run_engine
  rc_is 2; clean
  has "ERROR: BKP_NODE='bkp02' but root@100.100.100.35 is really node 'pve03' - NOTHING was run"
  has "nodes visible there: bkp02 pve01 pve02 pve03"
  untraced "rsync"; untraced "zfs snapshot"
  done_scenario
fi

if scenario "42: a backup node that cannot be reached at all says so and runs nothing"; then
  : > "$BKP/.down"
  run_engine
  rc_is 2; clean
  has "ERROR: cannot read the PVE node identity of root@100.100.100.35 - NOTHING was run"
  untraced "zfs snapshot"
  done_scenario
fi

if scenario "43: extra mountpoints are not replicated, and every empty path is named"; then
  add_src_ct pve01 105 tank-hdd-nas 20G \
    "net0: name=eth0,bridge=vmbr0,hwaddr=BC:24:11:00:01:05,ip=10.100.50.5/24,tag=50,type=veth" \
    "mp0: tank-hdd-nas:105/vm-105-disk-1.raw,mp=/var/www/data,size=2T"
  run_engine --ctid 105
  rc_is 0; clean
  has "WARN: mp0 -> /var/www/data is NOT replicated - empty dir on the copy"
  cfg_hasnt 8105 '^mp0:'
  st_is 105 mp_empty /var/www/data
  done_scenario
fi

if scenario "44: a net line with no bridge= refuses the CT instead of dropping it"; then
  # a line with no bridge= cannot be moved onto the island, and the old
  # behaviour was to drop it and carry on - so the copy came up with one
  # interface missing and every report called it healthy. It is refused now,
  # and refused BEFORE the transfer: there is no point moving a rootfs for a
  # copy that must not be created. The check cannot live inside mocknet_lines,
  # whose stdout is the config file being written.
  add_src_ct pve01 105 tank-hdd-nas 20G \
    "net0: name=eth0,bridge=vmbr0,hwaddr=BC:24:11:00:01:05,ip=10.100.50.5/24,tag=50,type=veth" \
    "net1: name=eth1,hwaddr=BC:24:11:00:01:06,type=veth"
  run_engine --ctid 105
  rc_is 1; clean
  has "ERROR: source config has a net line with no bridge= - NOT copying this CT"
  has "ERROR:   net1: name=eth1"
  has "look healthy"
  untraced "rsync"                      # refused before a byte moves
  cfg_absent 8105
  st_is 105 last.status failed; st_is 105 last.reason net_no_bridge
  done_scenario
fi

if scenario "44b: MOCKNET=0 does not care about a net line with no bridge="; then
  # with no network on the copy at all there is nothing to move onto a bridge,
  # so the refusal above must not fire and cost the CT its copy
  conf_set MOCKNET 0
  add_src_ct pve01 105 tank-hdd-nas 20G \
    "net1: name=eth1,hwaddr=BC:24:11:00:01:06,type=veth"
  run_engine --ctid 105
  rc_is 0; clean
  hasnt "net line has no bridge="
  cfg_exists 8105
  cfg_hasnt 8105 '^net[0-9]+:'
  done_scenario
fi

if scenario "45: a killed run brings the loop-mount and the point-in-time source down anyway"; then
  # Ctrl-C during a multi-hour transfer is the ordinary way an operator changes
  # their mind, and the line after the killed rsync never runs. If the unmount
  # and the clone teardown are not in the exit trap they do not happen at all.
  kill_next_rsync
  run_engine --ctid 105
  rc_is 130                             # killed by SIGINT: never mistaken for success
  clean
  nothing_mounted; no_zfs_leftovers
  cfg_absent 8105
  st_is 105 last.status interrupted; st_is 105 last.reason interrupted
  st_parses 105
  done_scenario
fi

if scenario "46: a run publishes a complete state snapshot and one history line"; then
  run_engine --ctid 105
  rc_is 0; clean
  st_parses 105
  st_is 105 schema_version 1
  st_is 105 tool ct-replica
  st_is 105 src_ctid 105;  st_is 105 tgt_ctid 8105
  st_is 105 src_node pve01; st_is 105 bkp_node bkp02
  st_is 105 src_storage tank-hdd-nas
  st_is 105 dest hdd
  st_is 105 dest_dataset replica-hdd/ct/subvol-8105-disk-0
  st_is 105 config_present true
  st_is 105 mocknet true
  st_is 105 mp_empty ""
  st_is 105 last.lane all
  st_is 105 last.mode replica
  st_is 105 last.status ok
  st_is 105 last.reason ""
  st_is 105 last.rc 0
  runs_count 105 1; runs_valid 105; runs_last 105 status ok
  done_scenario
fi

if scenario "47: rsync --stats reach the state file with the commas stripped"; then
  rsync_stats 4211 987654321 991111222 118111600640
  run_engine --ctid 105
  rc_is 0; clean
  has "[105] stats: files=4211 changed=941.9MiB"
  st_is 105 last.files         4211
  st_is 105 last.literal_bytes 987654321
  st_is 105 last.bytes_sent    991111222
  st_is 105 last.total_bytes   118111600640
  done_scenario
fi

if scenario "48: the history accumulates one line per run and each line stands alone"; then
  run_engine --ctid 105
  rsync_rc 23
  run_engine --ctid 105
  rsync_rc 0
  run_engine --ctid 105
  runs_count 105 3
  runs_valid 105
  runs_last 105 status ok               # the newest record is last in the file
  st_is 105 last.status ok
  done_scenario
fi

if scenario "50: the ssh control socket is per-process, so one lane cannot kill another's"; then
  # 21:00, two cron lanes. The lane with nothing to do finished in 0s, and its
  # cleanup loop closed the mux master the other lane was still using - that
  # lane then died mid-run with "storage 'replica-hdd' is not active", which
  # says nothing about the real cause. The pid in the socket name is the whole
  # fix, and it is invisible everywhere except in the ssh command line.
  run_engine --ctid 105
  rc_is 0; clean
  ctl_per_pid
  first="$(ctl_paths)"
  # ControlPersist keeps a master alive for two minutes after the run that made
  # it, so the path has to be unique per RUN, not merely per lane
  ctl_reset
  rsync_rc 0
  run_engine --ctid 105
  rc_is 0
  ctl_per_pid
  [[ "$first" != "$(ctl_paths)" ]] \
    || _err "both runs used the same control socket: $first"
  done_scenario
fi

if scenario "52: --dry-run over every row runs every guard and writes nothing"; then
  # The full dry pass. `clean` is the assertion that matters: run_engine saw
  # --dry-run in the engine's argv and armed SIM_DRY, so every fake that would
  # change the fleet records a violation instead of pretending - a snapshot, a
  # clone, a destroy, a zfs create on the backup node, a config write, an rsync
  # without -n. Nobody has to remember to assert on the write they added.
  run_engine --dry-run
  rc_is 0; clean
  has "mode=dry-run"
  has "dry-run only - nothing was written"
  # R1 degrades honestly: it checks the storage shape it can check and says
  # plainly that it took no snapshot, rather than printing a zero delta.
  has "R1: DRY: would snapshot"
  has "there is no transfer estimate"
  has "[105] DRY: would create dataset"
  has "[105] DRY: would create copy config 8105"
  untraced "zfs snapshot"
  untraced "zfs clone"
  untraced "rsync"
  cfg_absent 8105
  cfg_absent 8113
  st_absent 105
  no_zfs_leftovers
  nothing_mounted
  done_scenario
fi

if scenario "52b: a dry run does not disturb the copy a real round already made"; then
  # The operator's real sequence during an incident: look, then decide. A dry
  # run that destroyed the leftover snapshot of a previous round, or rewrote the
  # copy config, would be doing exactly what it promised not to.
  run_engine
  rc_is 0; clean
  copy_has /replica-hdd/ct/subvol-8105-disk-0 rootfs.txt
  run_engine --dry-run
  rc_is 0; clean
  has "[105] DRY: copy config 8105 already exists on bkp02 - R5 would leave it untouched"
  copy_file_has /replica-hdd/ct/subvol-8105-disk-0 rootfs.txt "rootfs of CT 105, generation 1"
  # the real round left one snapshot and one history line. A dry run that
  # added either would be claiming a round that never happened.
  st_is 105 last.status ok
  runs_count 105 1
  no_zfs_leftovers
  nothing_mounted
  done_scenario
fi

if scenario "51: a flag whose value is missing is refused, not spun on forever"; then
  # `shift 2` fails when only one argument is left, and the old `|| true`
  # swallowed that failure - $# never reached zero and the engine span at 100%
  # CPU with nothing in any log. This lane runs every fifteen minutes, so that
  # is a new spinning process per tick and no replication at all. A scenario
  # that hangs here rather than failing is telling you the bug is back.
  run_engine --storage
  rc_is 2; clean
  has "--storage needs a value"
  untraced "zfs snapshot"
  untraced "rsync"
  done_scenario
fi

if scenario "51b: the same holds for --ctid"; then
  run_engine --ctid
  rc_is 2; clean
  has "--ctid needs a value"
  untraced "zfs snapshot"
  done_scenario
fi

if scenario "58: a missing flock is named, not mistaken for a lock somebody else holds"; then
  # `flock -n 9` on a host without flock is command-not-found, which is a
  # non-zero exit, which is indistinguishable from "the lock is held" - so the
  # engine used to say it was skipping and return 0. A missing tool producing a
  # green run is the one outcome this repo refuses everywhere else. The fix is
  # ordering: the preflight that names the tool has to run BEFORE the lock.
  hide_cmd flock
  run_engine
  rc_is 2
  has "ERROR: required command(s) not found: flock - NOTHING was run"
  hasnt "another run active"
  untraced "ssh"; untraced "rsync"; untraced "zfs snapshot"
  st_absent 105
  done_scenario
fi

if scenario "59: --help prints the whole header, exit-code contract included"; then
  # It used to print a fixed line range that stopped short of the exit codes,
  # in all three engines. Anything running under cron is read by its exit code
  # before anybody reads a log, so that is the half of the header an operator
  # most needs and the half they could not see. It walks the comment block now
  # instead of counting lines, so editing the header cannot silently truncate
  # it again.
  out="$("$WORK/ct-replica.sh" --help 2>&1)"; rc=$?
  [[ "$rc" == 0 ]] || _err "--help exit code $rc, expected 0"
  grep -q "exit code" <<<"$out" || _err "--help does not reach the exit-code contract"
  grep -q "^#" <<<"$out" && _err "--help should print the header without its # markers"
  done_scenario
fi

if scenario "60: one CT can be held back by hand without stopping the fleet"; then
  # PAUSE stops everything, which is right during a failback and far too blunt
  # for "this one is being fsck'd". The reason written in the file comes back
  # every round, because at 3am the first question is why this one is not
  # copying and the file should answer it.
  pause_ct 105 "waiting for e2fsck after rc=23 twice"
  run_engine
  rc_is 0; clean
  has "[105] PAUSED by pause/105 - waiting for e2fsck after rc=23 twice"
  has "ok=1 skipped=1 failed=0"
  cfg_absent 8105
  cfg_exists 8113                       # the rest of the fleet is untouched
  st_is 105 last.status skipped; st_is 105 last.reason paused
  done_scenario
fi

if scenario "61: a paused CT with no reason still says it is paused"; then
  pause_ct 105
  run_engine --ctid 105
  rc_is 0; clean
  has "[105] PAUSED by pause/105"
  untraced "rsync"
  done_scenario
fi

if scenario "62: a whole storage being down is ONE fact, and it is not a failure"; then
  # The node holding tank-hdd-nas is gone. That is one fact, not one fact per
  # CT: saying it forty times buries the CT that failed for its own reason.
  # Nothing about these containers is wrong, so they are SKIPPED, and the run
  # still refuses to exit 0 because they are not being replicated.
  break_storage
  run_engine
  rc_is 1; clean
  has "GUARD R1"
  has "source 'tank-hdd-nas' is down - skip"
  has "SOURCE DOWN: 'tank-hdd-nas'"
  has "1 CT not replicated this round"
  has "they resume by themselves when the storage is back - nothing to undo"
  hasnt "NEEDS ATTENTION"              # skipped, not failed
  has "ok=1 skipped=1 failed=0"        # the OTHER storage still worked
  st_is 105 last.status skipped; st_is 105 last.reason source_down
  done_scenario
fi


# ---------- R13: a live DR placement owns the newest data --------------------
if scenario "49: R13 a live 9xxx placement stops the copy being overwritten"; then
  # The hole PAUSE could never cover. The storage node dies with no warning, so
  # nobody types `touch PAUSE` and the file would have been on the machine that
  # died anyway. distribute puts the container on a compute node as 9105, the
  # customer works there for hours, the storage node comes back, and cron fires
  # on schedule. R2 does not shield 8105 - a DR copy is stopped by design - so
  # the PRE-DISASTER production image lands on top of it. Nothing is lost that
  # second, but 8105 now LOOKS like a fresh copy while holding data from before
  # the outage, and the next person to read a green status skips the recall.
  bkp_cfg pve01 9105 <<'EOF'
arch: amd64
hostname: ct105-dr
rootfs: local-lvm:vm-9105-disk-0,size=8G
EOF
  run_engine --ctid 105
  rc_is 1; clean
  has "GUARD R13: CT 9105 exists - a DR placement for this container is live"
  has "/etc/pve/nodes/pve01/lxc/9105.conf"
  has "recall 9105 first, then destroy it"
  st_is 105 last.reason r13_dr_active
  untraced "rsync"
  done_scenario
fi

if scenario "50: R13 blocks only the containers that moved, not the whole fleet"; then
  # A DR is rarely all-or-nothing: the important containers get placed and the
  # rest stay where they are. Those still have their production image as the
  # newest copy, and they must keep being replicated - during a long outage
  # that is the only thing standing between them and a second failure.
  bkp_cfg pve01 9105 <<'EOF'
arch: amd64
hostname: ct105-dr
rootfs: local-lvm:vm-9105-disk-0,size=8G
EOF
  run_engine
  rc_is 1
  has "GUARD R13: CT 9105 exists"
  hasnt "GUARD R13: CT 9113 exists"
  traced "rsync"                       # 113 went, 105 did not
  done_scenario
fi

echo
echo "=== $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then echo "failed: ${FAILED_NAMES[*]}"; exit 1; fi
exit 0
