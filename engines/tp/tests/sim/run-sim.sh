#!/usr/bin/env bash
# =============================================================================
#  run-sim.sh — execute ct-migrate.sh against fake pvesm/pct/ssh/rsync
# -----------------------------------------------------------------------------
#  Why this exists: the engine can only be run on the storage-node, against 50
#  live CTs. That is a terrible place to find out a guard moved. The fakes in
#  sim/bin implement the same *invariants* the guards protect, and scream into
#  sim/violations when one is broken:
#
#    - rsync into a destination that is not mounted   (CT lands on the root fs)
#    - pvesm alloc into an unmounted pool             (G1)
#    - loop-mounting one image twice                  (G2)
#    - truncate/e2fsck/resize2fs on a mounted image   (G3)
#
#  A scenario can therefore FAIL in two different ways: wrong observable
#  behaviour (log/exit code), or a broken invariant (violations file non-empty).
#  The second one is the one that matters.
#
#  usage:  ./tests/sim/run-sim.sh            run every scenario
#          ./tests/sim/run-sim.sh 5          run scenario 5 only
#          KEEP=1 ./tests/sim/run-sim.sh 5   keep the sandbox and print where it is
#          make test                         same thing, from the repo root
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"        # repo root: the engine lives there
# overridable so tests/mutation/run-mutation.sh can point the whole suite at a
# deliberately broken copy of the engine and check that scenarios actually die
ENGINE="${ENGINE:-$ROOT/ct-migrate.sh}"

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
  SIMROOT="$(mktemp -d /tmp/ctmig-sim.XXXXXX)"
  export SIMROOT SIMLIB="$HERE/lib.sh"
  WORK="$SIMROOT/work"; mkdir -p "$WORK" "$SIMROOT/storage" "$SIMROOT/pools" "$SIMROOT/mnt"
  : > "$SIMROOT/mounted"; : > "$SIMROOT/violations"; : > "$SIMROOT/trace"; : > "$SIMROOT/ctlpath"
  : > "$SIMROOT/loopmap"; : > "$SIMROOT/umount.fail"; : > "$SIMROOT/mount.fail"
  : > "$SIMROOT/storage.cfg"; : > "$SIMROOT/cfgwrite.trunc"
  echo 0 > "$SIMROOT/rsync.n"; echo "0 0 0 0 0 0" > "$SIMROOT/rsync.rc"
  # files literal sent total - what the fake rsync reports in its --stats block
  echo "161 2469606195 2470127483 118111600640" > "$SIMROOT/rsync.stats"

  # Two local dir storages, both usable, but deliberately of DIFFERENT shape:
  #   tank-hdd-nas : its own mount, and it tells PVE so (is_mountpoint)
  #   tank-ssd-nas : a subdirectory inside a bigger mounted filesystem
  # Both are legitimate in the real fleet, and G1 has to accept both.
  add_storage tank-hdd-nas "$SIMROOT/pool/tank/hosting"          ismp
  add_storage tank-ssd-nas "$SIMROOT/pool/tank-ssd/hosting-ssd"

  add_node 10.100.1.11; add_node 10.100.1.12
  add_node 10.100.1.31; add_node 10.100.1.32
  for n in 10.100.1.31 10.100.1.32; do
    echo active > "$SIMROOT/nodes/$n/storage/tank-hdd-nas"
    echo active > "$SIMROOT/nodes/$n/storage/tank-ssd-nas"
  done

  add_ct 10.100.1.11 251 running 1251 $(( 10 * 1024**3 )) "20G"
  add_ct 10.100.1.12 253 running 1253 $((  5 * 1024**3 )) "10G"

  # the engine resolves BASE from its own path; a symlink keeps BASE in the sandbox
  ln -s "$ENGINE" "$WORK/ct-migrate.sh"
  cat > "$WORK/ctmig.conf" <<EOF
BW_TOTAL_MB=230
LANES=1
BW_MIN_MB=20
USAGE_FACTOR_PCT=185
HEADROOM_PCT=30
GROW_PCT=5
GROW_MAX_RETRY=3
POOL_RESERVE_GIB=100
MNT_BASE=$SIMROOT/mnt
STORAGE_CFG=$SIMROOT/storage.cfg
EOF
  inventory \
    "10.100.1.11	251	251	10.100.1.31	tank-hdd-nas" \
    "10.100.1.12	253	253	10.100.1.32	tank-ssd-nas"
}
add_storage(){ # id path [ismp]
  mkdir -p "$2"; echo "$2" > "$SIMROOT/storage/$1.path"; echo "$2" >> "$SIMROOT/mounted"
  printf 'dir: %s\n\tpath %s\n\tcontent images,rootdir\n' "$1" "$2" >> "$SIMROOT/storage.cfg"
  [[ "${3:-}" == ismp ]] && printf '\tis_mountpoint 1\n' >> "$SIMROOT/storage.cfg"
  return 0; }
mount_fs(){ echo "${1%/}" >> "$SIMROOT/mounted"; }   # pretend $1 is a mounted filesystem
declare_ismp(){ # id value - set is_mountpoint inside that storage's block (value may be a PATH)
  awk -v id="$1" -v v="$2" '
    /^[a-z]+:[[:space:]]/          { inblk = ($2 == id) }
    inblk && $1 == "is_mountpoint" { next }
                                   { print }
    inblk && /^[a-z]+:[[:space:]]/ { print "\tis_mountpoint " v }
  ' "$SIMROOT/storage.cfg" > "$SIMROOT/.cfg" && mv "$SIMROOT/.cfg" "$SIMROOT/storage.cfg"; }
add_node(){ mkdir -p "$SIMROOT/nodes/$1/ct" "$SIMROOT/nodes/$1/storage" "$SIMROOT/nodes/$1/etc/pve/lxc"; }
add_ct(){ # node id status pid usedbytes quota
  local d="$SIMROOT/nodes/$1/ct"
  echo "$3" > "$d/$2.status"; echo "$4" > "$d/$2.pid"; echo "$5" > "$d/$2.used"
  cat > "$d/$2.config" <<EOF
arch: amd64
cores: 2
hostname: ct$2.example
memory: 2048
rootfs: local-lvm:vm-$2-disk-0,size=$6
swap: 512
net0: name=eth0,bridge=vmbr0,ip=10.0.0.$2/24
onboot: 1
EOF
}
inventory(){ printf '%s\n' "$@" > "$WORK/inventory-migrate.tsv"; }
# the same, but the last line gets NO trailing newline: the shape some editors
# leave behind, and the one that used to make the engine lose its last row
inventory_nonl(){ local IFS=$'\n'; printf '%s' "$*" > "$WORK/inventory-migrate.tsv"; }
unmount_pool(){ grep -vxF "$(cat "$SIMROOT/storage/$1.path")" "$SIMROOT/mounted" > "$SIMROOT/.m"; mv "$SIMROOT/.m" "$SIMROOT/mounted"; }
rsync_stats(){ echo "$1 $2 $3 $4" > "$SIMROOT/rsync.stats"; }   # files literal sent total
kill_next_rsync(){ : > "$SIMROOT/rsync.kill"; }   # Ctrl-C the engine mid-transfer, once
truncate_cfg_write(){ echo "$1 $2" >> "$SIMROOT/cfgwrite.trunc"; }   # node ctid
# write a config for <ctid> on <node> whose rootfs points somewhere else: the id
# is already taken by another container, which is what G7 exists to notice
foreign_cfg(){ # node ctid rootfs-volid
  mkdir -p "$SIMROOT/nodes/$1/etc/pve/lxc"
  printf 'arch: amd64\nhostname: someone-else\nrootfs: %s,size=8G\nonboot: 1\n' "$3" \
    > "$SIMROOT/nodes/$1/etc/pve/lxc/$2.conf"; }
# nothing may still be loop-mounted when the engine is gone, however it left
# ---------- ssh control socket ----------
ctl_paths(){ awk -F'\t' '$2 != "none" && $2 != "<none>" {print $2}' "$SIMROOT/ctlpath" 2>/dev/null | sort -u | tr '\n' ' '; }
ctl_reset(){ : > "$SIMROOT/ctlpath"; }
ctl_per_pid(){   # every socket this run asked for has to be its own
  local bad
  [[ -s "$SIMROOT/ctlpath" ]] || { _err "no ssh ControlPath was recorded at all"; return 0; }
  # 'none' is the rsync data transport, which shares nothing on purpose
  bad="$(awk -F'\t' '$2 != "none" && $2 != "<none>" && $2 !~ /^\/run\/ctmig-[0-9]+-/ {print $1 " -> " $2}' \
           "$SIMROOT/ctlpath" | sort -u)"
  [[ -z "$bad" ]] || { _err "ssh control socket with no pid in it - two lanes would share one master:"
                       sed 's/^/         /' <<<"$bad"; }
  return 0; }

nothing_mounted(){ local m; m=$(grep -F "$SIMROOT/mnt/" "$SIMROOT/mounted" 2>/dev/null)
  [[ -z "$m" ]] || _err "still mounted after the run: $m"; return 0; }

# pretend another lane is already syncing something off that source node
HOLDER_PID=""
hold_node_lock(){
  local key="${1//[^A-Za-z0-9._-]/_}"
  rm -f "$SIMROOT/holder.ready"
  ( exec 7>"$WORK/.node-$key.lock"; flock -n 7 || exit 1
    : > "$SIMROOT/holder.ready"; sleep 120 ) &
  HOLDER_PID=$!
  local i=0
  while [[ ! -f "$SIMROOT/holder.ready" && $i -lt 200 ]]; do sleep 0.02; i=$((i+1)); done
  [[ -f "$SIMROOT/holder.ready" ]] || echo "      x could not take the node lock in the harness"
}
drop_node_lock(){ [[ -n "$HOLDER_PID" ]] && kill "$HOLDER_PID" 2>/dev/null; HOLDER_PID=""; wait 2>/dev/null; return 0; }

hide_cmd(){ SIM_MISSING="$1"; }   # make one tool genuinely absent for the next run

run_engine(){
  ( export SIMROOT SIM_MISSING SIMBIN="$HERE/bin" SIMLIB="$HERE/lib.sh"
    # Armed from the ENGINE's own arguments, not from a scenario flag, so every
    # scenario that runs a dry engine is policed whether or not its author
    # thought about it. The fakes read it through dry_forbids in lib.sh.
    SIM_DRY=0
    for _a in "$@"; do [[ "$_a" == --dry-run ]] && SIM_DRY=1; done
    export SIM_DRY
    # The engine sets its own PATH (it has to: cron hands it /usr/bin:/bin and
    # pvesm lives in sbin), so prepending a directory here reaches nothing.
    # Exported functions do reach it - bash resolves a function before PATH -
    # and each one is a one-line shim onto sim/bin. PATH is still prepended as
    # well, for anything the engine execs indirectly.
    export PATH="$HERE/bin:$PATH"
    pvesm(){       "$SIMBIN/pvesm"       "$@"; }
    ssh(){         "$SIMBIN/ssh"         "$@"; }
    rsync(){       "$SIMBIN/rsync"       "$@"; }
    mount(){       "$SIMBIN/mount"       "$@"; }
    umount(){      "$SIMBIN/umount"      "$@"; }
    mountpoint(){  "$SIMBIN/mountpoint"  "$@"; }
    findmnt(){     "$SIMBIN/findmnt"     "$@"; }
    df(){          "$SIMBIN/df"          "$@"; }
    fuser(){       "$SIMBIN/fuser"       "$@"; }
    losetup(){     "$SIMBIN/losetup"     "$@"; }
    truncate(){    "$SIMBIN/truncate"    "$@"; }
    resize2fs(){   "$SIMBIN/resize2fs"   "$@"; }
    e2fsck(){      "$SIMBIN/e2fsck"      "$@"; }
    mkfs.ext4(){   "$SIMBIN/mkfs.ext4"   "$@"; }
    sync(){        "$SIMBIN/sync"        "$@"; }
    export -f pvesm ssh rsync mount umount mountpoint findmnt df fuser \
              losetup truncate resize2fs e2fsck sync
    # a dot is legal in a bash function name and it must be exported like any
    # other. Leaving it out is silent: the engine falls through to the real
    # mkfs.ext4 if the host has one, and scenario 53 stops testing anything.
    export -f mkfs.ext4
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
    "$WORK/ct-migrate.sh" "$@" ) > "$SIMROOT/out" 2>&1
  RC=$?
  OUT="$(cat "$SIMROOT/out")"
  TRACE="$(cat "$SIMROOT/trace")"
  VIO="$(cat "$SIMROOT/violations")"
}

# ---------- assertions ----------
# Each engine writes state/<tool>-<ctid>.json so two tools can hold history
# for the same container at once. One place decides the path here too, so
# the next rename is one edit rather than a dozen.
st_file(){ printf '%s\n' "$WORK/state/migrate-$1.json"; }
st_hist(){ printf '%s\n' "$WORK/state/migrate-$1.runs.jsonl"; }
_err(){ echo "      x $*"; SCEN_OK=0; }
has(){    grep -qF -- "$1" <<<"$OUT" || _err "expected in log: $1"; }
hasnt(){  grep -qF -- "$1" <<<"$OUT" && _err "should NOT be in log: $1"; return 0; }
traced(){ grep -qF -- "$1" <<<"$TRACE" || _err "expected command: $1"; }
untraced(){ grep -qF -- "$1" <<<"$TRACE" && _err "command must NOT have run: $1"; return 0; }
rc_is(){ [[ "$RC" == "$1" ]] || _err "exit code $RC, expected $1"; }
clean(){ [[ -z "$VIO" ]] || { _err "INVARIANT BROKEN:"; sed 's/^/         /' <<<"$VIO"; }; }
cfg_exists(){ [[ -f "$SIMROOT/nodes/$1/etc/pve/lxc/$2.conf" ]] || _err "config $2 missing on $1"; }
cfg_absent(){ [[ -f "$SIMROOT/nodes/$1/etc/pve/lxc/$2.conf" ]] && _err "config $2 must NOT exist on $1"; return 0; }
cfg_has(){ grep -qF -- "$3" "$SIMROOT/nodes/$1/etc/pve/lxc/$2.conf" 2>/dev/null || _err "config $2: expected '$3'"; }
cfg_hasnt(){ grep -qE -- "$3" "$SIMROOT/nodes/$1/etc/pve/lxc/$2.conf" 2>/dev/null && _err "config $2: must not match '$3'"; return 0; }

# ---------- state file assertions ----------
# The engine writes state/<ctid>.json next to itself, and BASE lands inside the
# sandbox because ${BASH_SOURCE[0]} is not symlink-resolved. python3 is fine to
# use HERE - the engine itself must stay python-free, a Proxmox node has no jq
# and no guaranteed python3. Parsing with a real JSON parser is the point: it
# proves the hand-rolled writer emits something a reader can actually load.
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
st_is(){    # $1=ctid $2=dotted path $3=expected value
  local got; got="$(_st_get "$1" "$2")"
  [[ "$got" == "$3" ]] || _err "state $1: $2 = '$got', expected '$3'"
}
st_valid(){ # $1=ctid - the snapshot must exist, parse, and match schema/
  [[ -f "$(st_file "$1")" ]] || { _err "state file for $1 is missing"; return 0; }
  local out
  out="$(python3 - "$(st_file "$1")" "$ROOT/schema/state.schema.json" 2>&1 <<'PY'
import json, sys
inst = json.load(open(sys.argv[1]))          # a parse error here is the first failure
try:
    import jsonschema
except ImportError:
    sys.exit(0)                              # no validator installed: parsing is all we can check
schema = json.load(open(sys.argv[2]))
errs = sorted(jsonschema.Draft202012Validator(schema).iter_errors(inst), key=lambda e: e.path)
for e in errs:
    print("%s: %s" % ("/".join(str(p) for p in e.path) or "<root>", e.message))
sys.exit(1 if errs else 0)
PY
)" || _err "state file for $1 does not match the schema:
$(sed 's/^/         /' <<<"$out")"
  return 0
}
st_absent(){ [[ -f "$(st_file "$1")" ]] && _err "state file for $1 must NOT exist"; return 0; }
runs_count(){  # $1=ctid $2=expected number of history records
  local n; n=$(wc -l < "$(st_hist "$1")" 2>/dev/null || echo 0)
  [[ "$n" == "$2" ]] || _err "history $1: $n runs, expected $2"
}
runs_valid(){  # every line of the history must stand alone as JSON
  local f; f="$(st_hist "$1")"
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
  return 0
}
runs_last(){   # $1=ctid $2=dotted path $3=expected, read from the LAST history line
  local got
  got="$(tail -n 1 "$(st_hist "$1")" 2>/dev/null | python3 -c '
import json, sys
d = json.loads(sys.stdin.read() or "{}")
for k in sys.argv[1].split("."):
    d = d.get(k, "MISSING") if isinstance(d, dict) else "MISSING"
print(d)' "$2" 2>/dev/null)"
  [[ "$got" == "$3" ]] || _err "history $1 last: $2 = '$got', expected '$3'"
}

scenario(){
  N="${1%%:*}"
  [[ -n "$ONLY" && "$ONLY" != "$N" ]] && return 1
  # Reset here, not in the helper: a scenario that hides a tool must not hide it
  # from every scenario that follows. This leaked once and the symptom was
  # scenarios that pass alone and fail in the suite, which is the worst kind.
  SIM_MISSING=""
  echo "  [$1]"; SCEN_OK=1; new_world; return 0
}
done_scenario(){
  drop_node_lock
  if (( SCEN_OK )); then PASS=$((PASS+1)); echo "      ok"
  else FAIL=$((FAIL+1)); FAILED_NAMES+=("$N"); fi
  if [[ -n "${KEEP:-}" ]]; then echo "      sandbox: $SIMROOT"; else rm -rf "$SIMROOT"; fi
}

echo "=== ct-migrate.sh simulator ==="

if scenario "1: happy path, two CTs on two storages"; then
  run_engine
  rc_is 0; clean
  has "ok=2 skipped=0 frozen=0 failed=0"
  # the log is a deliverable, not a side effect: a rule between operations so
  # the boundaries are findable at 2am, a header naming the migration, and the
  # convergence number the whole presync workflow is steered by. That last one
  # was computed and filed into state/<ctid>.json and never shown to anybody.
  has "##############################################################################"
  has "[251] CT 251 on 10.100.1.11  ->  CT 251 on 10.100.1.31, storage 'tank-hdd-nas'"
  has "[251] stats: files=161 changed="
  # The rsync option set, which nothing checked until now: stripping -x,
  # --delete, --numeric-ids, --sparse and all six excludes left this suite
  # 61/61 green. -x is the one that keeps a 2T mp0 out of the rootfs image.
  traced "rsyncopt -x"
  traced "rsyncopt --delete"
  traced "rsyncopt --numeric-ids"
  traced "rsyncopt --sparse"
  traced "rsyncopt --exclude=/proc/*"
  traced "rsyncopt --bwlimit=230m"
  cfg_exists 10.100.1.31 251; cfg_exists 10.100.1.32 253
  cfg_has 10.100.1.31 251 "rootfs: tank-hdd-nas:251/vm-251-disk-0.raw"
  cfg_has 10.100.1.31 251 "onboot: 0"
  cfg_hasnt 10.100.1.31 251 '^net[0-9]+:'     # no network, by decision
  cfg_hasnt 10.100.1.31 251 '^mp[0-9]+:'
  done_scenario
fi

if scenario "2: G1 pool dataset not mounted -> nothing is written"; then
  unmount_pool tank-hdd-nas
  run_engine
  rc_is 1; clean
  has "GUARD G1"; has "sits on the ROOT filesystem"
  untraced "alloc tank-hdd-nas"
  cfg_absent 10.100.1.31 251
  cfg_exists 10.100.1.32 253          # the other storage keeps working
  done_scenario
fi

if scenario "3: G2 copy already running on the new node"; then
  echo running > "$SIMROOT/nodes/10.100.1.31/ct/251.status"
  run_engine
  rc_is 0; clean
  has "GUARD G2"; has "skipped=1"
  untraced "alloc tank-hdd-nas"
  done_scenario
fi

if scenario "4: G4 ENOSPC grows the image and retries"; then
  echo "11 0" > "$SIMROOT/rsync.rc"
  run_engine --ctid 251
  rc_is 0; clean                      # clean == resize happened while UNMOUNTED
  has "ENOSPC - grow attempt 1/3"
  traced "resize2fs"
  has "rootfs synced (rsync rc=0)"
  cfg_exists 10.100.1.31 251
  done_scenario
fi

if scenario "4b: a grown image stays grown, and the config drift is reported"; then
  # asked directly: after 20G -> +5% -> +5%, does the NEXT sync start from 20G
  # again? It must not. The image is allocated once (`if [[ ! -f "$IMG" ]]`),
  # truncate is persistent, and every later grow computes from stat(2) on the
  # file rather than from the config. What does NOT follow the image is the
  # config's size= field: G6 refuses to rewrite a config that exists, because a
  # human may have added net0 to it by now. So from the grow onwards every run
  # reports the drift instead of hiding it.
  IMGF="$SIMROOT/pool/tank/hosting/images/251/vm-251-disk-0.raw"

  run_engine --ctid 251                       # first run: allocates, writes the config
  rc_is 0; clean
  has "alloc 20G"
  cfg_has 10.100.1.31 251 "size=20G"
  first=$(stat -c%s "$IMGF")

  # the rc list is consumed by a counter that the first run already advanced;
  # rewind it so this run really does see 11, 11, 0
  echo "11 11 0" > "$SIMROOT/rsync.rc"        # a later run runs out of room twice
  echo 0         > "$SIMROOT/rsync.n"
  run_engine --ctid 251
  rc_is 0; clean
  has "ENOSPC - grow attempt 2/3"
  grown=$(stat -c%s "$IMGF")
  (( grown > first )) || _err "the image did not actually grow: $first -> $grown"
  has "NOTE: config says size=20G but the image is now"
  st_is 251 size_drift true

  echo "0 0" > "$SIMROOT/rsync.rc"            # and the run after that
  echo 0     > "$SIMROOT/rsync.n"
  run_engine --ctid 251
  rc_is 0; clean
  untraced "pvesm alloc"                      # never re-allocated
  again=$(stat -c%s "$IMGF")
  [[ "$again" == "$grown" ]] || _err "image restarted at $again, expected to stay $grown"
  has "NOTE: config says size=20G but the image is now"
  st_is 251 size_drift true                   # reported every round until a human fixes it
  done_scenario
fi

if scenario "5: G3 umount fails DURING an ENOSPC run -> no resize, no config"; then
  # the regression test for the bug found in review: if the umount gate sat
  # after the grow loop, this scenario would resize a mounted image.
  echo "11 0" > "$SIMROOT/rsync.rc"
  echo "$SIMROOT/mnt/ctmig-251" > "$SIMROOT/umount.fail"
  run_engine --ctid 251
  rc_is 1; clean
  has "GUARD G3"; has "never resize a mounted image"
  untraced "truncate"; untraced "resize2fs"
  cfg_absent 10.100.1.31 251
  done_scenario
fi

if scenario "6: G5 rc=23 is a failure -> no config"; then
  echo "23" > "$SIMROOT/rsync.rc"
  run_engine --ctid 251
  rc_is 1; clean
  has "GUARD G5"; has "do NOT start this CT"
  cfg_absent 10.100.1.31 251
  done_scenario
fi

if scenario "7: rc=24 (files vanished on a live CT) is normal -> config written"; then
  echo "24" > "$SIMROOT/rsync.rc"
  run_engine --ctid 251
  rc_is 0; clean
  has "rootfs synced (rsync rc=24)"
  cfg_exists 10.100.1.31 251
  done_scenario
fi

if scenario "8: legacy 4-column row is refused, not guessed"; then
  inventory "10.100.1.11	251	251	10.100.1.31"
  run_engine
  rc_is 1; clean
  has "row is incomplete"; has "add-storage-column.sh"
  untraced "alloc"
  done_scenario
fi

if scenario "9: storage missing on the target node -> caught before transfer"; then
  rm -f "$SIMROOT/nodes/10.100.1.31/storage/tank-hdd-nas"
  run_engine --ctid 251
  rc_is 1; clean
  has "is not active on 10.100.1.31"
  untraced "rsync"
  done_scenario
fi

if scenario "10: mp0 is migrated without data and every empty path is named"; then
  sed -i 's|^swap: 512|swap: 512\nmp0: tank:subvol-253-disk-1,mp=/var/www/data,size=2T|' \
    "$SIMROOT/nodes/10.100.1.12/ct/253.config"
  run_engine --ctid 253
  rc_is 0; clean
  has "DATA IS NOT COPIED"
  has "mp0 -> /var/www/data will be an EMPTY directory after boot"
  cfg_exists 10.100.1.32 253
  cfg_hasnt 10.100.1.32 253 '^mp0:'
  done_scenario
fi

if scenario "11: --storage runs one lane only"; then
  run_engine --storage tank-ssd-nas
  rc_is 0; clean
  has "lane=tank-ssd-nas"; has "ok=1"
  cfg_exists 10.100.1.32 253
  cfg_absent 10.100.1.31 251
  done_scenario
fi

if scenario "12: LANES splits the tool-wide bandwidth ceiling"; then
  sed -i 's/^LANES=1/LANES=2/' "$WORK/ctmig.conf"
  run_engine --storage tank-hdd-nas
  rc_is 0
  has "bw=115m (total 230m / 2 lanes)"
  done_scenario
fi

if scenario "13: --stopped refuses a CT that is still running"; then
  run_engine --ctid 251 --stopped
  rc_is 1; clean
  has "--stopped needs CT 251"; has "does not touch CT lifecycle"
  untraced "rsync"
  done_scenario
fi

if scenario "14: --stopped final delta mounts, syncs, and always unmounts"; then
  run_engine --ctid 251                                  # normal sync first
  echo stopped > "$SIMROOT/nodes/10.100.1.11/ct/251.status"
  echo 0 > "$SIMROOT/rsync.n"
  run_engine --ctid 251 --stopped
  rc_is 0; clean
  has "FINAL delta from a STOPPED CT"
  traced "SRCMOUNT 10.100.1.11 251"
  traced "SRCUMOUNT 10.100.1.11 251"
  [[ -f "$SIMROOT/nodes/10.100.1.11/ct/251.mounted" ]] && _err "source CT left mounted on the old node"
  done_scenario
fi

if scenario "15: --stopped unmounts the source even when the sync fails"; then
  run_engine --ctid 251
  echo stopped > "$SIMROOT/nodes/10.100.1.11/ct/251.status"
  echo 0 > "$SIMROOT/rsync.n"; echo "23" > "$SIMROOT/rsync.rc"
  run_engine --ctid 251 --stopped
  rc_is 1; clean
  traced "SRCUMOUNT 10.100.1.11 251"
  [[ -f "$SIMROOT/nodes/10.100.1.11/ct/251.mounted" ]] && _err "source CT left mounted after a failed sync"
  done_scenario
fi

if scenario "16: .done freezes a finished CT"; then
  mkdir -p "$WORK/done"; touch "$WORK/done/251.done"
  run_engine
  rc_is 0; clean
  has "frozen=1"; has "ok=1"
  cfg_absent 10.100.1.31 251
  done_scenario
fi

if scenario "17: G6 an existing config is never rewritten"; then
  run_engine --ctid 251
  # a human added net0 by hand, the way go-live actually works
  echo "net0: name=eth0,bridge=vmbr0,ip=10.9.9.9/24" >> "$SIMROOT/nodes/10.100.1.31/etc/pve/lxc/251.conf"
  echo 0 > "$SIMROOT/rsync.n"
  run_engine --ctid 251
  rc_is 0; clean
  cfg_has 10.100.1.31 251 "ip=10.9.9.9/24"
  done_scenario
fi

if scenario "18: the old node being unreachable is a clear, distinct error"; then
  touch "$SIMROOT/nodes/10.100.1.11/.down"
  run_engine --ctid 251
  rc_is 1; clean
  has "SSH to 10.100.1.11 FAILED"
  done_scenario
fi

if scenario "19: a dir storage INSIDE a mounted filesystem is legitimate"; then
  # the real tank-ssd-nas: XFS mounted at /tank-ssd, storage at /tank-ssd/hosting-ssd.
  # The pool is not a mountpoint itself and never will be - that must not be an error.
  unmount_pool tank-ssd-nas
  mount_fs "$SIMROOT/pool/tank-ssd"
  run_engine --ctid 253
  rc_is 0; clean
  has "is not a mountpoint itself"; has "declares no is_mountpoint"
  hasnt "GUARD G1"
  traced "alloc tank-ssd-nas"
  cfg_exists 10.100.1.32 253
  done_scenario
fi

if scenario "20: is_mountpoint declared but not mounted -> refuse (lands on the parent)"; then
  # tank-hdd-nas declares is_mountpoint. Its parent pool IS mounted, so tier 1
  # is happy: a write would land on the parent dataset, not the node root. Only
  # the admin's own declaration catches this, so G1 has to honour it.
  unmount_pool tank-hdd-nas
  mount_fs "$SIMROOT/pool/tank"
  run_engine --ctid 251
  rc_is 1; clean
  has "GUARD G1"; has "declares is_mountpoint"
  untraced "alloc tank-hdd-nas"
  cfg_absent 10.100.1.31 251
  done_scenario
fi

if scenario "21: no is_mountpoint does NOT excuse a pool on the root filesystem"; then
  # the permissive tier must not open a hole: tank-ssd-nas declares nothing, and
  # with no mounted ancestor at all this is still the fill-the-node-root case.
  unmount_pool tank-ssd-nas
  run_engine --ctid 253
  rc_is 1; clean
  has "GUARD G1"; has "sits on the ROOT filesystem"
  untraced "alloc tank-ssd-nas"
  cfg_absent 10.100.1.32 253
  done_scenario
fi

if scenario "22: a storage path that does not exist is named as such"; then
  rm -rf "$SIMROOT/pool/tank-ssd/hosting-ssd"
  run_engine --ctid 253
  rc_is 1; clean
  has "GUARD G1"; has "does not exist"
  untraced "alloc tank-ssd-nas"
  done_scenario
fi

if scenario "23: is_mountpoint given as a PATH (storage in a subdir of that mount)"; then
  # The docs' own BTRFS shape, and the fix offered for the real tank-ssd-nas:
  #     path          /tank-ssd/hosting-ssd
  #     is_mountpoint /tank-ssd
  # Reading is_mountpoint as a boolean here would check the POOL path, find an
  # ordinary directory, and reject exactly the layout the path form exists for.
  unmount_pool tank-ssd-nas
  mount_fs "$SIMROOT/pool/tank-ssd"
  declare_ismp tank-ssd-nas "$SIMROOT/pool/tank-ssd"
  run_engine --ctid 253
  rc_is 0; clean
  hasnt "GUARD G1"
  hasnt "is not a mountpoint itself"   # PVE polices it now, so the advisory NOTE is gone
  traced "alloc tank-ssd-nas"
  cfg_exists 10.100.1.32 253
  done_scenario
fi

if scenario "24: is_mountpoint PATH not mounted -> refuse, naming that path"; then
  # the declared mount is absent but its parent is present, so tier 1 sees a
  # perfectly ordinary non-root filesystem. Only the declaration catches it.
  unmount_pool tank-ssd-nas
  mount_fs "$SIMROOT/pool"
  declare_ismp tank-ssd-nas "$SIMROOT/pool/tank-ssd"
  run_engine --ctid 253
  rc_is 1; clean
  has "GUARD G1"; has "$SIMROOT/pool/tank-ssd is NOT a mountpoint"
  untraced "alloc tank-ssd-nas"
  cfg_absent 10.100.1.32 253
  done_scenario
fi

if scenario "25: the per-node lock keeps two lanes off the same source node"; then
  # LANES=1 in the sandbox, so the contention is simulated by a holder process
  # taking the lock the way a second lane would.
  hold_node_lock 10.100.1.11
  run_engine --ctid 251
  rc_is 0; clean                      # busy is not an error: the next run picks it up
  has "source node 10.100.1.11 is busy"
  has "ok=0 skipped=1 frozen=0 failed=0"
  untraced "rsync"                    # nothing was pulled off the busy node
  untraced "alloc tank-hdd-nas"
  cfg_absent 10.100.1.31 251
  st_valid 251; st_is 251 last.status skipped; st_is 251 last.reason node_busy
  done_scenario
fi

if scenario "26: the lock is released, so the very next run proceeds"; then
  hold_node_lock 10.100.1.11
  run_engine --ctid 251
  has "ok=0 skipped=1"
  drop_node_lock
  run_engine --ctid 251
  rc_is 0; clean
  has "ok=1 skipped=0 frozen=0 failed=0"
  cfg_exists 10.100.1.31 251
  st_is 251 last.status ok
  runs_count 251 2                    # both runs are in the history
  done_scenario
fi

if scenario "27: a node lock never blocks a DIFFERENT source node"; then
  hold_node_lock 10.100.1.11          # 251 lives here; 253 lives on .12
  run_engine
  rc_is 0; clean
  has "ok=1 skipped=1 frozen=0 failed=0"
  cfg_absent 10.100.1.31 251
  cfg_exists 10.100.1.32 253
  st_is 251 last.reason node_busy
  st_is 253 last.status ok
  done_scenario
fi

if scenario "28: a successful run publishes a complete state snapshot"; then
  run_engine --ctid 251
  rc_is 0; clean
  st_valid 251
  st_is 251 schema_version 1
  st_is 251 new_ctid 251;   st_is 251 old_ctid 251
  st_is 251 old_node 10.100.1.11
  st_is 251 new_node 10.100.1.31
  st_is 251 storage  tank-hdd-nas
  st_is 251 image_size_gib 20         # quota 20G beats used 10G x185% = 19G
  st_is 251 config_present true
  st_is 251 config_size 20G
  st_is 251 size_drift false
  st_is 251 mp_empty ""
  st_is 251 last.mode presync
  st_is 251 last.status ok
  st_is 251 last.reason ""
  st_is 251 last.rc 0
  st_is 251 last.grow_attempts 0
  done_scenario
fi

if scenario "29: rsync --stats reach the state file with the commas stripped"; then
  rsync_stats 4211 987654321 991111222 118111600640
  run_engine --ctid 251
  rc_is 0; clean
  st_is 251 last.files          4211
  st_is 251 last.literal_bytes  987654321
  st_is 251 last.bytes_sent     991111222
  st_is 251 last.total_bytes    118111600640
  done_scenario
fi

if scenario "30: an ENOSPC grow sums its transfers into one run record"; then
  echo "11 0" > "$SIMROOT/rsync.rc"
  rsync_stats 100 1000 1100 118111600640
  run_engine --ctid 251
  rc_is 0; clean
  st_is 251 last.status ok
  st_is 251 last.grow_attempts 1
  st_is 251 last.files          200    # two passes, added up
  st_is 251 last.literal_bytes  2000
  st_is 251 last.bytes_sent     2200
  st_is 251 last.total_bytes    118111600640   # a dataset property: NOT summed
  st_is 251 image_size_gib 21          # 20G grown by GROW_PCT=5
  st_is 251 config_size 21G            # config follows the real image
  done_scenario
fi

if scenario "31: a failed sync is recorded as failed, with the guard that fired"; then
  echo "23" > "$SIMROOT/rsync.rc"
  run_engine --ctid 251
  rc_is 1; clean
  st_valid 251
  st_is 251 last.status failed
  st_is 251 last.reason g5_rsync
  st_is 251 last.rc 23
  st_is 251 config_present false       # G5 held: no config was written
  cfg_absent 10.100.1.31 251
  done_scenario
fi

if scenario "32: still-ENOSPC after every retry is reported as g4_enospc"; then
  echo "11 11 11 11" > "$SIMROOT/rsync.rc"
  run_engine --ctid 251
  rc_is 1; clean
  st_is 251 last.status failed
  st_is 251 last.reason g4_enospc
  st_is 251 last.grow_attempts 3       # GROW_MAX_RETRY
  done_scenario
fi

if scenario "33: a guard that fires before the transfer still leaves a snapshot"; then
  unmount_pool tank-hdd-nas
  run_engine --ctid 251
  rc_is 1; clean
  st_valid 251
  st_is 251 last.status failed
  st_is 251 last.reason g1_pool
  st_is 251 last.rc -1                 # never got as far as rsync
  st_is 251 image_size_gib 0
  done_scenario
fi

if scenario "34: a frozen CT is left completely alone, snapshot included"; then
  # .done is human-owned. A later run must not overwrite the snapshot that
  # recorded the real work, so a frozen row writes nothing at all.
  run_engine --ctid 251                # first: a real run, a real snapshot
  st_is 251 last.status ok
  mkdir -p "$WORK/done"; : > "$WORK/done/251.done"
  rsync_stats 999 999 999 999          # would be visible if it wrote again
  run_engine --ctid 251
  rc_is 0
  has "frozen=1"
  st_is 251 last.status ok             # untouched
  st_is 251 last.files 161
  runs_count 251 1                     # and no second history record
  done_scenario
fi

if scenario "35: an incomplete row is loud but keyless, so it writes no state"; then
  inventory "10.100.1.11	251	251	10.100.1.31"
  run_engine
  rc_is 1
  has "row is incomplete"
  st_absent 251
  done_scenario
fi

if scenario "36: history accumulates one line per run and each line stands alone"; then
  run_engine --ctid 251
  echo "23" > "$SIMROOT/rsync.rc"; echo 0 > "$SIMROOT/rsync.n"
  run_engine --ctid 251
  echo "0" > "$SIMROOT/rsync.rc";  echo 0 > "$SIMROOT/rsync.n"
  run_engine --ctid 251
  runs_count 251 3
  runs_valid 251
  runs_last 251 status ok              # the newest record is last in the file
  st_is 251 last.status ok
  done_scenario
fi

if scenario "37: a storage id full of JSON-hostile characters still parses"; then
  # the engine hand-rolls JSON with no jq and no python. Quotes, backslashes and
  # control characters in a value are exactly how that goes wrong.
  inventory "$(printf '10.100.1.11\t251\t251\t10.100.1.31\tbad"id\\with\tsep')"
  run_engine
  rc_is 1                              # the storage does not exist: that is fine
  st_valid 251                         # what matters is that the file PARSES
  st_is 251 last.status failed
  st_is 251 last.reason storage_unknown
  st_is 251 storage 'bad"id\with'
  done_scenario
fi

if scenario "38: --stopped records the mode it ran in"; then
  run_engine --ctid 251                                  # presync first, as designed
  echo stopped > "$SIMROOT/nodes/10.100.1.11/ct/251.status"
  echo 0 > "$SIMROOT/rsync.n"
  run_engine --stopped --ctid 251
  rc_is 0; clean
  st_is 251 last.mode stopped
  st_is 251 last.status ok
  done_scenario
fi

if scenario "39: mp0 paths that will be empty are named in the state file too"; then
  cat >> "$SIMROOT/nodes/10.100.1.12/ct/253.config" <<'EOF'
mp0: local-lvm:vm-253-disk-1,mp=/var/www/data,size=50G
EOF
  run_engine --ctid 253
  rc_is 0; clean
  st_is 253 mp_empty /var/www/data
  st_is 253 last.status ok
  done_scenario
fi

if scenario "40: the node lock is released between rows, so one run is not blocked by itself"; then
  # both CTs come off the SAME source node. If the lock outlived its row the
  # tool would deadlock against itself and only ever migrate one CT per run.
  add_ct 10.100.1.11 253 running 1253 $(( 5 * 1024**3 )) "10G"
  inventory \
    "10.100.1.11	251	251	10.100.1.31	tank-hdd-nas" \
    "10.100.1.11	253	253	10.100.1.32	tank-ssd-nas"
  run_engine
  rc_is 0; clean
  has "ok=2 skipped=0 frozen=0 failed=0"
  hasnt "is busy"
  st_is 251 last.status ok
  st_is 253 last.status ok
  done_scenario
fi

if scenario "41: a duplicate new_ctid is refused before anything runs"; then
  # the comment and the blank line are here so the reported line numbers have to
  # be real file lines. An off-by-one makes the message worse than useless.
  inventory \
    "# old_node	old_ctid	new_ctid	new_node	storage" \
    "" \
    "10.100.1.11	251	251	10.100.1.31	tank-hdd-nas" \
    "10.100.1.12	253	251	10.100.1.32	tank-ssd-nas"
  run_engine
  rc_is 2; clean
  has "new_ctid 251 is on line 3 and again on line 4"
  has "NOTHING was run"
  untraced "rsync"
  untraced "pvesm alloc"
  st_absent 251
  st_absent 253
  done_scenario
fi

if scenario "42: the same old CT twice on one node is refused, naming both lines"; then
  inventory \
    "10.100.1.11	251	251	10.100.1.31	tank-hdd-nas" \
    "10.100.1.11	251	252	10.100.1.31	tank-ssd-nas"
  run_engine
  rc_is 2; clean
  has "old CT 251 on 10.100.1.11 is on line 1 and again on line 2"
  untraced "rsync"
  done_scenario
fi

if scenario "43: the same old_ctid on two DIFFERENT old nodes is legitimate"; then
  # standalone nodes all start numbering at 100, so this is the normal case on
  # this fleet. Keying the source check on old_ctid alone would refuse it and
  # the tool would be unusable against a correct inventory.
  add_ct 10.100.1.12 251 running 1291 $(( 5 * 1024**3 )) "10G"
  inventory \
    "10.100.1.11	251	251	10.100.1.31	tank-hdd-nas" \
    "10.100.1.12	251	253	10.100.1.32	tank-ssd-nas"
  run_engine
  rc_is 0; clean
  hasnt "more than once"
  has "ok=2 skipped=0 frozen=0 failed=0"
  st_is 251 last.status ok
  st_is 253 last.status ok
  done_scenario
fi

if scenario "44: --ctid does not excuse a duplicate in an unrelated row"; then
  # the verdict is a property of the FILE, not of how the run was invoked. A
  # broken inventory that passes at 2am because of the flag you happened to use
  # is the worst possible behaviour here.
  inventory \
    "10.100.1.11	251	251	10.100.1.31	tank-hdd-nas" \
    "10.100.1.12	253	253	10.100.1.32	tank-ssd-nas" \
    "10.100.1.12	253	254	10.100.1.32	tank-ssd-nas"
  run_engine --ctid 251
  rc_is 2; clean
  has "old CT 253 on 10.100.1.12 is on line 2 and again on line 3"
  untraced "rsync"
  st_absent 251
  done_scenario
fi

if scenario "45: a last row with no trailing newline is still a row"; then
  inventory_nonl \
    "10.100.1.11	251	251	10.100.1.31	tank-hdd-nas" \
    "10.100.1.12	253	253	10.100.1.32	tank-ssd-nas"
  run_engine
  rc_is 0; clean
  has "ok=2 skipped=0 frozen=0 failed=0"
  st_is 253 last.status ok
  done_scenario
fi

if scenario "46: the preflight sees that last row too"; then
  # if the preflight stopped one row short it would pass a file the main loop
  # then went on to migrate twice. Same read shape in both, proved here.
  inventory_nonl \
    "10.100.1.11	251	251	10.100.1.31	tank-hdd-nas" \
    "10.100.1.12	253	251	10.100.1.32	tank-ssd-nas"
  run_engine
  rc_is 2; clean
  has "new_ctid 251 is on line 1 and again on line 2"
  untraced "rsync"
  done_scenario
fi

if scenario "47: a killed run does not leave the image loop-mounted"; then
  # Ctrl-C during a multi-hour transfer is the ordinary way an operator changes
  # their mind, and the line after the killed rsync never runs. If the unmount
  # does not happen in the exit trap it does not happen at all - and the image
  # stays mounted here while somebody boots that CT on the new node.
  kill_next_rsync
  run_engine --ctid 251
  rc_is 130                           # killed by SIGINT: never mistaken for success
  clean
  nothing_mounted
  st_is 251 last.status interrupted
  st_is 251 last.reason interrupted
  st_valid 251
  cfg_absent 10.100.1.31 251          # G5: no config, the sync never finished
  done_scenario
fi

if scenario "48: a --storage or --ctid that matches nothing is loud, not a quiet success"; then
  # under cron, exit 0 with no work done is indistinguishable from a healthy
  # run: a lane can look fine for weeks while nothing at all is migrating.
  run_engine --storage tank-hdd-nsa           # transposed, the way it is really typed
  rc_is 1
  has "no row in"; has "--storage tank-hdd-nsa"
  untraced "rsync"
  run_engine --ctid 2511
  rc_is 1
  has "--ctid 2511"
  untraced "rsync"
  done_scenario
fi

if scenario "49: a lane whose CTs are all frozen is not mistaken for a typo"; then
  mkdir -p "$WORK/done"; touch "$WORK/done/253.done"
  run_engine --storage tank-ssd-nas
  rc_is 0; clean
  has "frozen=1"
  hasnt "no row in"
  done_scenario
fi

if scenario "50: G7 refuses a new_ctid that already belongs to another container"; then
  # one wrong digit in inventory-migrate.tsv points a row at an id somebody else owns.
  foreign_cfg 10.100.1.31 251 "local-lvm:vm-999-disk-0"
  run_engine --ctid 251
  rc_is 1; clean
  has "GUARD G7"; has "already belongs to something else"
  untraced "alloc tank-hdd-nas"; untraced "rsync"
  st_is 251 last.status failed
  st_is 251 last.reason g7_ctid_taken
  st_valid 251
  done_scenario
fi

if scenario "51: G7 also refuses a config with no rootfs line at all"; then
  # what an earlier truncated write leaves behind. G6 never rewrites a config
  # that exists, so this CT could be resynced forever and still never boot.
  mkdir -p "$SIMROOT/nodes/10.100.1.31/etc/pve/lxc"
  printf 'arch: amd64\nhostna' > "$SIMROOT/nodes/10.100.1.31/etc/pve/lxc/251.conf"
  run_engine --ctid 251
  rc_is 1; clean
  has "GUARD G7"; has "the config is truncated"
  untraced "rsync"
  st_is 251 last.reason g7_ctid_taken
  done_scenario
fi

if scenario "52: a config write that is silently truncated is caught by reading it back"; then
  truncate_cfg_write 10.100.1.31 251
  run_engine --ctid 251
  rc_is 1; clean
  has "does not match what was sent"
  has "the rootfs data is fine"        # the transfer is not lost, say so
  st_is 251 last.status failed
  st_is 251 last.reason cfg_write
  st_is 251 last.rc 0                  # the sync itself was clean
  st_valid 251
  done_scenario
fi

if scenario "53: mkfs failing is caught, not discovered by the loop-mount"; then
  : > "$SIMROOT/mkfs.fail"
  run_engine --ctid 251
  rc_is 1; clean
  has "mkfs.ext4 failed"; has "pvesm free"
  untraced "rsync"
  st_is 251 last.status failed
  st_is 251 last.reason mkfs_failed
  st_valid 251
  done_scenario
fi

if scenario "54: pvesm alloc failing is caught where the fix is still one command"; then
  : > "$SIMROOT/alloc.fail"
  run_engine --ctid 251
  rc_is 1; clean
  has "pvesm alloc failed"
  untraced "rsync"
  st_is 251 last.status failed
  st_is 251 last.reason alloc_failed
  st_valid 251
  done_scenario
fi

if scenario "55: the ssh control socket is per-process, so one lane cannot kill another's"; then
  # 21:00, two cron lanes. The lane with nothing to do finished in seconds, and
  # its cleanup loop closed the mux master the other lane was still using; that
  # lane then died mid-transfer with "storage is not active", which says nothing
  # at all about the real cause. The pid in the socket name is the whole fix,
  # and it is visible nowhere except on the ssh command line.
  run_engine --ctid 251
  rc_is 0; clean
  ctl_per_pid
  first="$(ctl_paths)"
  # ControlPersist keeps a master alive for two minutes after the run that made
  # it, so the path has to be unique per RUN, not merely per lane
  ctl_reset
  run_engine --ctid 251
  ctl_per_pid
  [[ "$first" != "$(ctl_paths)" ]] || _err "both runs used the same control socket: $first"
  done_scenario
fi

if scenario "57: --dry-run over every row runs every guard and writes nothing"; then
  # The full dry pass. `clean` is the assertion that matters: run_engine saw
  # --dry-run in the engine's argv and armed SIM_DRY, so every fake that would
  # change the fleet records a violation instead of pretending - pvesm alloc,
  # mkfs.ext4, a loop-mount that is not ro, an rsync without -n, a config write
  # over ssh. Nobody has to remember to assert on the write they added.
  run_engine --dry-run
  rc_is 0; clean
  has "mode=dry-run"
  has "dry-run only - nothing was written"
  # both rows are first contact here: no image, so nothing to mount and nothing
  # for rsync -n to compare against. The plan is the sizing the engine already
  # computes, plus the config it would write.
  has "[251] DRY: would alloc"
  has "[251] DRY: first sync - the whole rootfs would transfer"
  has "[251] DRY: would create /etc/pve/lxc/251.conf on 10.100.1.31"
  has "onboot: 0, and no net line"
  untraced "alloc"
  untraced "mkfs.ext4"
  untraced "rsync"
  cfg_absent 10.100.1.31 251
  cfg_absent 10.100.1.32 253
  st_absent 251
  st_absent 253
  nothing_mounted
  done_scenario
fi

if scenario "57b: a dry resync mounts read-only and reports a real delta"; then
  # The other path: the image already exists, so the dry run CAN answer "how
  # much would move tonight". It mounts ro,noload and lets rsync -n read the
  # destination - which writes nothing, and is why the number is free.
  run_engine --ctid 251                       # a real run first, to make the image
  rc_is 0; clean
  run_engine --ctid 251 --dry-run
  rc_is 0; clean
  has "[251] rsync <="
  has "[251] DRY: a config already exists on 10.100.1.31 - G6 would leave it untouched"
  has "dry-run only - nothing was written"
  # the point of this scenario: the second mount was read-only. The trace spans
  # both runs, so assert on what the dry pass DID rather than on what the real
  # pass did not - the first run legitimately allocated and mounted rw.
  traced "mount -o loop,ro,noload"
  # st_begin publishes "running" before the transfer, so this is the one path
  # where a dry run could clobber the record of the real run that preceded it.
  # `tp status` would then show a CT as in-flight, or ok, for a run that moved
  # nothing at all.
  st_is 251 last.status ok
  st_is 251 last.rc 0
  nothing_mounted
  done_scenario
fi

if scenario "57c: --stopped and --dry-run together are refused, not reconciled"; then
  # --stopped needs `pct mount` on the old node to expose the source. That is a
  # write on somebody else's machine, and without it there is no source at all -
  # so the delta would be invented on the one run where a wrong number costs a
  # cutover window.
  run_engine --ctid 251 --stopped --dry-run
  rc_is 2
  has "--stopped needs 'pct mount' on the old node"
  untraced "rsync"
  done_scenario
fi

if scenario "56: a flag whose value is missing is refused, not spun on forever"; then
  # `shift 2` fails when only one argument is left, and the old `|| true`
  # swallowed that failure - $# never reached zero and the engine span at 100%
  # CPU with nothing in any log, one fresh process per cron tick. A scenario
  # that ever hangs here rather than failing is telling you the same bug is
  # back.
  run_engine --storage
  rc_is 2; clean
  has "--storage needs a value"
  untraced "pvesm alloc"
  untraced "rsync"
  done_scenario
fi

if scenario "56b: the same holds for --ctid, which is the one typed by hand"; then
  run_engine --ctid
  rc_is 2; clean
  has "--ctid needs a value"
  untraced "pvesm alloc"
  done_scenario
fi

if scenario "62: a missing flock is named, not mistaken for a lock somebody else holds"; then
  # Same hole as scenario 58 in the replica suite, and this engine had no
  # required-command preflight at all until now - so a missing pvesm surfaced
  # three steps later as "storage unknown", which is the wrong thing to go and
  # fix at 2am.
  hide_cmd flock
  run_engine
  rc_is 2
  has "ERROR: required command(s) not found: flock - NOTHING was run"
  hasnt "another sync is running"
  untraced "rsync"; untraced "pvesm alloc"
  st_absent 251
  done_scenario
fi

if scenario "63: --help prints the whole header, exit-code contract included"; then
  # It used to print a fixed line range that stopped short of the exit codes,
  # in all three engines. Anything running under cron is read by its exit code
  # before anybody reads a log, so that is the half of the header an operator
  # most needs and the half they could not see. It walks the comment block now
  # instead of counting lines, so editing the header cannot silently truncate
  # it again.
  out="$("$WORK/ct-migrate.sh" --help 2>&1)"; rc=$?
  [[ "$rc" == 0 ]] || _err "--help exit code $rc, expected 0"
  grep -q "exit code" <<<"$out" || _err "--help does not reach the exit-code contract"
  grep -q "^#" <<<"$out" && _err "--help should print the header without its # markers"
  done_scenario
fi

if scenario "64: an install still holding the OLD inventory.tsv is told what to rename"; then
  # The rename this scenario guards: one folder now holds three engines whose
  # inventories have entirely different columns, so the generic name went to
  # nobody. An upgrade that copies the new engines over an old install leaves
  # inventory.tsv sitting there, and "inventory not found" alone would send an
  # operator looking for a file that is in front of them. Under cron this is
  # every fifteen minutes until somebody reads a log.
  rm -f "$WORK/inventory-migrate.tsv"
  printf '10.100.1.11\t251\t251\t10.100.1.31\ttank-hdd-nas\n' > "$WORK/inventory.tsv"
  run_engine
  rc_is 1
  has "inventory not found"
  has "That is the OLD name for this file."
  has "mv $WORK/inventory.tsv $WORK/inventory-migrate.tsv"
  untraced "rsync"; untraced "pvesm alloc"
  rm -f "$WORK/inventory.tsv"
  done_scenario
fi

if scenario "64b: with neither file, it points at the sample instead"; then
  rm -f "$WORK/inventory-migrate.tsv" "$WORK/inventory.tsv"
  run_engine
  rc_is 1
  has "inventory not found"
  has "cp $WORK/inventory-migrate.sample.tsv"
  untraced "rsync"
  done_scenario
fi

echo
echo "=== $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then echo "failed: ${FAILED_NAMES[*]}"; exit 1; fi
exit 0
