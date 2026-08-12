#!/usr/bin/env bash
# =============================================================================
#  ct-distribute.sh  —  DISASTER ONLY. Put a DR copy onto a compute node's own
#                       storage so it can run there while the storage node is
#                       gone. Run it from the storage node or the backup node.
# -----------------------------------------------------------------------------
#  The storage node holds every container's disk, so when it dies nothing can
#  run: not on the compute nodes, whose images have gone, and not on the backup
#  node, which has the data but nowhere near the CPU and RAM for the fleet. The
#  data therefore has to move a second time, onto the one storage in the
#  building that does not depend on the machine that died - the compute node's
#  own disk.
#
#      300     production. A raw image on the storage node, NFS-mounted by the
#              compute node that runs it. Gone for the duration.
#      8300    the DR copy on the backup node. Written by ct-replica every
#              round, stopped, on a bridge with no uplink. OFFSET=8000
#      9300    what this engine makes: a TEMPORARY container on a compute
#              node's own storage. DR_OFFSET=9000
#
#  The digit in front is the whole point. Seeing 9300 in a `pct list` tells you
#  without asking that this is temporary, that its data is not replicated
#  anywhere, and that somebody has to unwind it deliberately.
#
#  usage:
#    ct-distribute.sh --list                    what would go where - read only
#    ct-distribute.sh --all                     every CT with a row in fleet.tsv
#    ct-distribute.sh --ctid 300                one container
#    ct-distribute.sh --ctid 300 --to 10.100.1.32     override the placement
#    ct-distribute.sh --ctid 300 --dst local-lvm      override the storage
#    ct-distribute.sh --all --dry-run           every guard runs, nothing moves
#
#  exit code: 0 = all ok, 1 = at least one CT failed or was skipped,
#             2 = refused before touching anything.
#
#  FLAGS EVERY ENGINE TAKES, spelled the same way on purpose:
#    --all               every row in the inventory
#    --ctid <id>         one container only
#    --dry-run           run every guard, write nothing, print the plan
#    -h | --help         this header
#  A filter that matches no row exits NON-ZERO: under cron, exit 0 with no work
#  done looks exactly like a healthy night.
# -----------------------------------------------------------------------------
#  WHERE THE BYTES GO, and why this engine is shaped differently
#
#  Every other engine in this repo runs ON one end of its own transfer. This
#  one runs on NEITHER: the data is on the backup node and it is going to a
#  compute node, and the machine typing the commands is a third one. rsync
#  cannot do remote-to-remote, so the transfer is issued ON the target, pulling
#  from the backup node:
#
#      ssh <target> "rsync root@<backup>:<copy>/ <local mount>/"
#
#  That needs root ssh from the target to the backup node. Between two cluster
#  members it already exists - it is how PVE migration works - but it is
#  checked before anything is allocated rather than assumed, because finding
#  out afterwards means an allocated volume and a half-written config.
#
#  THREE DESTINATION SHAPES, because "local storage" is not one thing:
#
#    lvmthin / lvm   pvesm alloc makes a block device. mkfs, mount, rsync in
#    dir / nfs       pvesm alloc makes a .raw file. mkfs, loop-mount, rsync in
#    zfspool         pvesm alloc makes a dataset that is already a directory.
#                    No mkfs and no mount at all - rsync straight into it
#
#  Everything below is written against those three and refuses anything else
#  by name. A storage type nobody has thought about is not a storage type to
#  guess at.
# -----------------------------------------------------------------------------
#  THE GUARDS (D1..D7). This engine runs during the worst hour this fleet will
#  have, so every one of them refuses rather than warns.
#
#   D1  the PRODUCTION container must be verifiably down, and must STAY down.
#       The copy carries the production IP and MAC on purpose, so a 9xxx placed
#       while 300 can still answer puts two machines on one address. Three
#       things are checked on the node itself, and each of them refuses:
#         running        the obvious one
#         unreachable    not-verified is not stopped. This used to log a reason
#                        and carry on, which is the guess every other guard here
#                        refuses to make
#         onboot: 1      stopped today, and it starts ITSELF the moment the
#                        storage node comes back or the node reboots. Nobody
#                        types a command for that, PAUSE cannot help because the
#                        machine holding it is the machine that died, and the
#                        result is production and the 9xxx both live on one IP,
#                        each writing a rootfs that can never be merged
#       This is B1, restated for the other direction, plus the half B1 does not
#       need: failback runs when the storage node is back, so nothing re-arms
#       behind it.
#
#   D2  the source copy must exist on the backup node and be STOPPED. Copying
#       out of a rootfs that something is writing to is a torn copy, and the
#       torn part is whatever the customer touched last.
#
#   D3  9<id> must be free on the target: no config anywhere in the cluster,
#       and no volume already allocated. This is G7/R4 again, and it is the
#       guard that stops a DR from emptying a container somebody else owns.
#
#   D4  the destination storage must be ACTIVE on the target and must not sit
#       on the node root filesystem. An unmounted dataset is an ordinary empty
#       directory, and filling one fills the node's root disk instead.
#
#   D5  free space is checked BEFORE anything is allocated. A thin pool that
#       fills does not merely fail the write - it can take the whole pool
#       read-only, and every container already running on that node with it.
#       That is the difference between one container that did not come back and
#       a compute node that fell over during a disaster.
#
#   D6  the config is written only after a good transfer (rsync 0 or 24), and
#       read back afterwards. A truncated config is permanent: nothing here
#       ever rewrites one.
#
#   D7  nothing is started, ever. It prints the `pct start` for a human. Same
#       rule as every engine in this repo, and it matters most here - this is
#       the moment a customer's service either comes back or collides with
#       something.
# =============================================================================
set -uo pipefail

# cron hands a script PATH=/usr/bin:/bin, and pvesm and zfs live in sbin. Same
# reason as every other engine here - see CLAUDE.md rule 8.
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="$BASE/ctrep.conf"
INV="$BASE/inventory-replica.tsv"
# ketsync's two tables, read where ketsync KEEPS them rather than from a copy.
# There used to be a mirror: `ketsync doctor` cp'd both files down here and the
# engines read the copies. It failed exactly where it mattered - `ketsync sync`
# delivers fleet.tsv to a slave's repo root and nothing down here was refreshed,
# and the copy is gitignored so a fresh clone did not have one at all. The
# backup node therefore answered "CT 110 has no row in fleet.tsv" 43 seconds
# after being sent a fleet.tsv, which is a sentence you would first read during
# the incident. One file, one truth, and no window in which they disagree.
#
# Guarded the same way LOGDIR is: a tp that is not inside a ketsync - and every
# simulator sandbox - reads its own copies, which is what --to is for.
FLEET="$BASE/fleet.tsv"      # ketsync's placement table
NODEMAP="$BASE/nodes.map"    # ip <TAB> pve node name, generated by ketsync
if [[ -f "$BASE/../../ketsync" && -f "$BASE/../../lib/common.sh" ]]; then
  _ks="$(cd "$BASE/../.." && pwd)"
  [[ -f "$_ks/fleet.tsv" ]] && FLEET="$_ks/fleet.tsv"
  [[ -f "$_ks/nodes.map" ]] && NODEMAP="$_ks/nodes.map"
fi

# ---------- defaults (ctrep.conf wins; they are the same knobs) ----------
BKP_SSH="root@100.100.100.35"
BKP_NODE=""                      # pmxcfs name, discovered - see ct-replica.sh
# storage-id : dataset. The KEY is the PVE storage id itself - there is no
# short alias any more. "hdd" and "ssd" meant nothing to anybody who had not
# read this file.
BKP_DESTS="replica-hdd:replica-hdd/ct replica-ssd:replica-ssd/ct"
DEFAULT_DEST="replica-hdd"
OFFSET=8000                      # production id -> DR copy id
DR_OFFSET=9000                   # production id -> temporary compute-node id
DR_DST="local-lvm"               # default destination storage on the target
DR_HEADROOM_PCT=25               # refuse if the target would be left tighter
BW_TOTAL_MB=230
LANES=1
BW_MIN_MB=20
LOG_KEEP_DAYS=14                 # same knob, same ctrep.conf, as ct-replica.sh
SSH_CIPHERS=aes128-gcm@openssh.com,aes256-gcm@openssh.com,aes128-ctr
# -------------------------------------------------------------------------

ONLY_CTID=""; ALL=0; LIST=0; DRY=0; TO_IP=""; DST_SID=""
while (( $# )); do
  case "$1" in
    --ctid)    [[ $# -ge 2 ]] || { echo "--ctid needs a value" >&2; exit 2; }
               ONLY_CTID="$2"; shift 2;;
    --to)      [[ $# -ge 2 ]] || { echo "--to needs a value" >&2; exit 2; }
               TO_IP="$2"; shift 2;;
    --dst)     [[ $# -ge 2 ]] || { echo "--dst needs a value" >&2; exit 2; }
               DST_SID="$2"; shift 2;;
    --all)     ALL=1; shift;;
    --list)    LIST=1; shift;;
    --dry-run) DRY=1; shift;;
    -h|--help) awk 'NR>1{ if (/^#/) { sub(/^#[ ]?/,""); print } else exit }' "${BASH_SOURCE[0]}"; exit 0;;
    *) echo "unknown argument: $1" >&2; exit 2;;
  esac
done
if (( ! LIST )) && (( ! ALL )) && [[ ! "$ONLY_CTID" =~ ^[0-9]+$ ]]; then
  echo "usage: ct-distribute.sh --list | --all | --ctid <production_ctid>" >&2
  echo "       [--to <compute-ip>] [--dst <storage-id>] [--dry-run]" >&2
  exit 2
fi

if [[ -f "$CONF" ]]; then
  # shellcheck source=/dev/null
  . "$CONF" || { echo "failed to read $CONF" >&2; exit 2; }
fi
for _v in OFFSET DR_OFFSET DR_HEADROOM_PCT BW_TOTAL_MB LANES BW_MIN_MB LOG_KEEP_DAYS; do
  [[ "${!_v}" =~ ^[0-9]+$ ]] || { echo "$CONF: $_v must be a plain integer, got '${!_v}'" >&2; exit 2; }
done

# ---------- where the log goes ----------
# ONE tree for both layers. tp is vendored inside ketsync and has no upstream,
# so the dispatcher is two directories up - but that is CHECKED rather than
# assumed: a tp that has been copied somewhere else, and every simulator
# sandbox, keeps its own logs/ instead of writing outside its own tree. A bad
# night should be one directory to read and one tarball to send, and every file
# in it is named after the verb an operator typed.
LOGDIR="$BASE/logs"
if [[ -f "$BASE/../../ketsync" && -f "$BASE/../../lib/common.sh" ]]; then
  LOGDIR="$(cd "$BASE/../.." && pwd)/logs"
fi

mkdir -p "$LOGDIR" "$BASE/state" 2>/dev/null
LOG="$LOGDIR/distribute-$(date +%F).log"
# This engine had no pruning at all, which the other three have had from the
# start. Only distribute-*.log at depth 1, so nothing else in the shared
# directory is collateral damage.
if (( LOG_KEEP_DAYS > 0 )); then
  find "$LOGDIR" -maxdepth 1 -type f -name 'distribute-*.log' \
       -mtime +"$LOG_KEEP_DAYS" -delete 2>/dev/null || true
fi
log(){ printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG"; }
# Three widths of rule, because a daily log holds dozens of rounds and dozens
# of containers and they are not the same kind of edge. Somebody scrolling at
# 2am is looking for where THEIR container starts, and a wall of identical
# rules makes every boundary a candidate.
#
#   #  the run itself opens here
#   =  the container list opens and closes
#   -  one container ends and the next begins
#
# Deliberately no timestamp on any of them: they are furniture, not events.
LOGSEP='##############################################################################'
LOGSEP2='=============================================================================='
LOGSEP3='------------------------------------------------------------------------------'
hr(){  printf '%s\n' "$LOGSEP"  | tee -a "$LOG"; }
hr2(){ printf '%s\n' "$LOGSEP2" | tee -a "$LOG"; }
hr3(){ printf '%s\n' "$LOGSEP3" | tee -a "$LOG"; }

# The first container opens the block, the rest are separated from the one
# before. The state lives here rather than at the call site, so a loop that
# grows a `continue` on the day somebody adds a guard cannot get it wrong.
HR_CT_SEEN=0
hr_ct(){ if (( HR_CT_SEEN )); then hr3; else hr2; HR_CT_SEEN=1; fi; }

hsize(){
  local b=${1:-0}
  if   (( b >= 1073741824 )); then printf '%d.%01dGiB' $(( b/1073741824 )) $(( (b%1073741824)*10/1073741824 ))
  elif (( b >= 1048576    )); then printf '%d.%01dMiB' $(( b/1048576 ))    $(( (b%1048576)*10/1048576 ))
  elif (( b >= 1024       )); then printf '%dKiB' $(( b/1024 ))
  else                             printf '%dB' "$b"; fi
}
# "20G" / "20480M" / "21474836480" -> bytes. A size this cannot read is refused
# rather than defaulted: allocating a guessed size is how a rootfs arrives 90%
# copied.
tobytes(){
  local s="${1:-}" n u
  n="${s%%[!0-9]*}"; u="${s:${#n}}"
  [[ -n "$n" ]] || { printf ''; return 1; }
  case "${u^^}" in
    T|TB|TIB) printf '%s' $(( n * 1099511627776 ));;
    G|GB|GIB) printf '%s' $(( n * 1073741824 ));;
    M|MB|MIB) printf '%s' $(( n * 1048576 ));;
    K|KB|KIB) printf '%s' $(( n * 1024 ));;
    "")       printf '%s' "$n";;
    *) printf ''; return 1;;
  esac
}

SSH_COMMON="-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o ServerAliveInterval=15 -c $SSH_CIPHERS"
SSH_OPT="$SSH_COMMON -o ControlMaster=auto -o ControlPath=/run/ctdist-$$-%r@%h.sock -o ControlPersist=120"

# A pmxcfs node name -> the address to reach it on. Empty when there is no map
# or no row, and the caller decides: this never guesses an address, because a
# guess here asks the wrong machine whether a container is running.
node_ip(){ awk -v n="$1" '$1!~/^#/ && $2==n{print $1; exit}' "$NODEMAP" 2>/dev/null; }

ST_PREFIX="distribute-"
json_str(){ local s="${1//\\/\\\\}"; s="${s//\"/\\\"}"; printf '"%s"' "$s"; }
json_num(){ [[ "${1:-}" =~ ^-?[0-9]+$ ]] && printf '%s' "$1" || printf '0'; }

st_write(){   # $1=ctid $2=status $3=reason $4=rc
  local id="$1" f t
  [[ -n "$id" ]] || return 0
  (( DRY )) && return 0
  f="$BASE/state/$ST_PREFIX$id.json"; t="$BASE/state/.$ST_PREFIX$id.json.$$"
  {
    printf '{\n'
    printf '  "schema_version": 1,\n'
    printf '  "tool": "distribute",\n'
    printf '  "ctid": %s,\n'      "$(json_str "$id")"
    printf '  "copy_vmid": %s,\n' "$(json_str "${CT_SRC:-}")"
    printf '  "dr_vmid": %s,\n'   "$(json_str "${CT_DR:-}")"
    printf '  "target_ip": %s,\n' "$(json_str "${CT_TO:-}")"
    printf '  "target_node": %s,\n' "$(json_str "${CT_TONODE:-}")"
    printf '  "storage": %s,\n'   "$(json_str "${CT_DST:-}")"
    printf '  "storage_type": %s,\n' "$(json_str "${CT_DSTTYPE:-}")"
    printf '  "last": {"ts":%s,"epoch":%s,"mode":%s,"status":%s,"reason":%s,"rc":%s,"secs":%s,"files":%s,"literal_bytes":%s,"bytes_received":%s}\n' \
      "$(json_str "$(date '+%FT%T%z')")" "$(json_num "$(date +%s)")" \
      "$(json_str "$MODE")" "$(json_str "$2")" "$(json_str "$3")" \
      "$(json_num "$4")" "$(json_num "${RS_SECS:-0}")" "$(json_num "${RS_FILES:-0}")" \
      "$(json_num "${RS_LITERAL:-0}")" "$(json_num "${RS_RECV:-0}")"
    printf '}\n'
  } > "$t" 2>/dev/null && mv -f "$t" "$f" 2>/dev/null && { st_history "$id"; return 0; }
  rm -f "$t" 2>/dev/null
  log "[$id] WARN: could not write state file $f"
  return 1
}
st_history(){
  local id="$1" n
  local h="$BASE/state/$ST_PREFIX$id.runs.jsonl"
  sed -n 's/^  "last": //p' "$BASE/state/$ST_PREFIX$id.json" >> "$h" 2>/dev/null || true
  n=$(wc -l < "$h" 2>/dev/null || echo 0)
  if [[ "$n" =~ ^[0-9]+$ ]] && (( n > 200 )); then
    tail -n 200 "$h" > "$h.tmp.$$" 2>/dev/null \
      && mv -f "$h.tmp.$$" "$h" 2>/dev/null || rm -f "$h.tmp.$$" 2>/dev/null
  fi
}

MODE=distribute; (( DRY )) && MODE="distribute/dry-run"; (( LIST )) && MODE=list

# ---------- the destination pool map, the same one ct-replica reads ----------
declare -A DEST_DS=()
for _e in $BKP_DESTS; do
  _k="${_e%%:*}"; DEST_DS[$_k]="${_e#*:}"
done

# ---------- the CT list, from ct-replica's inventory ----------
declare -a CTS=(); declare -A SRC_MAP=() DEST_MAP=()
if [[ ! -f "$INV" ]]; then
  log "ERROR: no inventory at $INV - NOTHING was run"
  log "ERROR:   this is ct-replica's file, not ct-migrate's inventory-migrate.tsv"
  log "ERROR:   start from the sample:  cp $BASE/inventory-replica.sample.tsv $INV"
  exit 2
fi
while IFS= read -r line || [[ -n "${line:-}" ]]; do
  line="${line%%#*}"; read -r c rest <<<"$line" || true
  [[ "${c:-}" =~ ^[0-9]+$ ]] || continue
  t=""; dd=""
  for f in ${rest:-}; do
    if   [[ "$f" =~ ^[0-9]+$ ]];      then t="$f"
    elif [[ -n "${DEST_DS[$f]:-}" ]]; then dd="$f"
    fi
  done
  SRC_MAP[$c]=${t:-$(( c + OFFSET ))}
  DEST_MAP[$c]=${dd:-$DEFAULT_DEST}
  CTS+=("$c")
done < "$INV"

if [[ -n "$ONLY_CTID" ]]; then
  _keep=()
  for c in "${CTS[@]}"; do [[ "$c" == "$ONLY_CTID" ]] && _keep+=("$c"); done
  # A --ctid that is not in the inventory is a typo or a container nobody
  # replicates. Either way it has no copy to distribute, and saying "0 done,
  # exit 0" during a disaster is the worst possible answer.
  if (( ! ${#_keep[@]} )); then
    log "ERROR: no row in $INV for CT $ONLY_CTID - NOTHING was run"
    log "ERROR:   this engine can only place a container that has a DR copy,"
    log "ERROR:   and the copies are the rows in that file."
    exit 2
  fi
  CTS=("${_keep[@]}")
fi
if (( ! ${#CTS[@]} )); then
  log "ERROR: $INV names no CT - nothing to place"
  exit 2
fi

hr
log "=== $(hostname) distribute mode=$MODE candidates: ${CTS[*]} ==="

# ---------- preflight: local tools, before any lock or any allocation -------
# Same order as every engine here, for the same reason: `flock -n` on a host
# with no flock is command-not-found, which is a non-zero exit, which is
# indistinguishable from "somebody else holds the lock" - so the engine would
# say it is skipping and return 0. Local commands only; pvesm and mkfs run on
# the TARGET over ssh, and requiring them here would refuse a perfectly good
# orchestrator for not being a compute node.
_missing=()
for _c in ssh flock awk sed mktemp; do
  command -v "$_c" >/dev/null 2>&1 || _missing+=("$_c")
done
if (( ${#_missing[@]} )); then
  log "ERROR: required command(s) not found: ${_missing[*]} (PATH=$PATH) - NOTHING was run"; exit 2
fi

RUN_LOCK=""
exec 9>"$BASE/.distribute.lock" 2>/dev/null || true
if ! flock -n 9; then
  log "another distribute is already running - skip"
  exit 0
fi
RUN_LOCK=1

cleanup(){
  local s
  for s in /run/ctdist-$$-*.sock; do
    [[ -S "$s" ]] && ssh -O exit -o ControlPath="$s" x >/dev/null 2>&1
  done
  [[ -n "$RUN_LOCK" ]] && exec 9>&-
  return 0
}
trap cleanup EXIT INT TERM

# ---------- who the backup node actually is ---------------------------------
# Nobody types a pmxcfs name. /etc/pve/local is a symlink to nodes/<this node>,
# which is the authoritative identity - safer than hostname, which can drift
# from it after a badly done rename. Every path this engine reads on the backup
# node is built from it.
_bknode=$(ssh $SSH_OPT "$BKP_SSH" 'readlink /etc/pve/local 2>/dev/null | sed "s|.*/||"' \
          </dev/null 2>/dev/null | head -1)
if [[ -z "$_bknode" ]]; then
  log "ERROR: cannot read the PVE node identity of $BKP_SSH - NOTHING was run"
  log "ERROR:   every byte this engine moves comes off that machine, so there"
  log "ERROR:   is nothing it can safely do without it."
  log "ERROR:   check: ssh $BKP_SSH 'readlink /etc/pve/local'"
  exit 2
fi
if [[ -z "$BKP_NODE" ]]; then
  BKP_NODE="$_bknode"
elif [[ "$_bknode" != "$BKP_NODE" ]]; then
  log "ERROR: BKP_NODE='$BKP_NODE' but $BKP_SSH is really node '$_bknode' - NOTHING was run"
  log "ERROR:   fix BKP_NODE in $CONF (set it to '$_bknode', or remove the line)"
  exit 2
fi

# ---------- placement: fleet.tsv first, --to overrides, never a guess -------
# ketsync owns placement and this file is its answer, mirrored next to the
# engines so a DR does not depend on the decision layer being reachable. --to
# is the override for the day the written answer is wrong. A container with
# neither is REFUSED rather than placed somewhere reasonable: choosing at 3am
# by what is nearest is how a customer lands on a machine nobody planned for.
fleet_dr(){    awk -v c="$1" '$1!~/^#/ && $1==c{print $4; exit}' "$FLEET" 2>/dev/null; }
# Column 5, optional: which storage on that node. A fleet is not homogeneous -
# one compute node's local storage is local-lvm and another's is local-zfs -
# so a single DR_DST cannot be right for both, and picking one by looking at
# what is there would be exactly the guess this repo refuses everywhere else.
fleet_dst(){   awk -v c="$1" '$1!~/^#/ && $1==c{print $5; exit}' "$FLEET" 2>/dev/null; }

target_of(){   # $1 = production ctid -> the ip to place it on, or empty
  [[ -n "$TO_IP" ]] && { printf '%s' "$TO_IP"; return 0; }
  fleet_dr "$1"
}
storage_of(){  # $1 = production ctid -> the storage to place it on
  [[ -n "$DST_SID" ]] && { printf '%s' "$DST_SID"; return 0; }
  local s; s="$(fleet_dst "$1")"
  printf '%s' "${s:-$DR_DST}"
}

# ---------- remote helpers, all against ONE machine at a time ---------------
rsh(){ ssh $SSH_OPT "root@$1" "${@:2}" </dev/null 2>/dev/null; }

# `pvesm status -storage <id>` on the target, as fields. This is the whole
# storage abstraction's read half: one uniform way to ask any storage type
# whether it is active and how much room is left, instead of one branch per
# type spread through the flow.
declare -A ST_TYPE=() ST_ACTIVE=() ST_AVAIL=()
probe_storage(){   # $1=ip $2=storage-id -> fills ST_* for "$1/$2", rc 1 if unknown
  local key="$1/$2" out
  [[ -n "${ST_TYPE[$key]:-}" ]] && return 0
  out=$(rsh "$1" "pvesm status -storage $2 2>/dev/null" | awk -v s="$2" '$1==s{print $2, $3, $6; exit}')
  [[ -n "$out" ]] || return 1
  read -r ST_TYPE[$key] ST_ACTIVE[$key] ST_AVAIL[$key] <<<"$out"
  return 0
}

# The three shapes, named once. Anything else is refused by name rather than
# guessed at, because guessing here means mkfs on something that was not a
# block device, or rsync into a path that was never mounted.
dst_shape(){   # $1 = pve storage type -> block | image | dataset | ""
  case "$1" in
    lvmthin|lvm)   printf 'block';;
    dir|nfs|cifs)  printf 'image';;
    zfspool)       printf 'dataset';;
    *)             printf '';;
  esac
}

PASS=0; FAILED=0; SKIPPED=0; declare -a FAILED_IDS=() SKIPPED_IDS=()
st_ok(){   PASS=$(( PASS + 1 )); st_write "$1" ok "$2" 0; }
st_fail(){ FAILED=$(( FAILED + 1 )); FAILED_IDS+=("$1"); st_write "$1" failed "$2" "${3:-1}"; }
st_skip(){ SKIPPED=$(( SKIPPED + 1 )); SKIPPED_IDS+=("$1"); st_write "$1" skipped "$2" 0; }

# =============================================================================
#  one container
# =============================================================================
CT_SRC=""; CT_DR=""; CT_TO=""; CT_TONODE=""; CT_DST=""; CT_DSTTYPE=""
CT_SIZE=""; CT_SRCMNT=""; CT_CFG=""; CUR_MNT=""; CUR_HOST=""

# The mount is on the TARGET, not here, so cleaning it up is a remote call. It
# is done in the per-CT path rather than the exit trap on purpose: the trap
# cannot know which of many targets was mid-flight, and a stale mount left on a
# compute node during a DR is a mount somebody trips over an hour later.
cleanup_ct(){
  [[ -n "$CUR_MNT" && -n "$CUR_HOST" ]] || return 0
  rsh "$CUR_HOST" "umount '$CUR_MNT' 2>/dev/null; rmdir '$CUR_MNT' 2>/dev/null" || true
  CUR_MNT=""; CUR_HOST=""
  return 0
}

do_ct(){   # $1 = production ctid
  local ct="$1" rc=0 out cfg
  CT_SRC="${SRC_MAP[$ct]}"; CT_DR=$(( ct + DR_OFFSET ))
  CT_TO=""; CT_TONODE=""; CT_DST=""; CT_DSTTYPE=""; CT_SIZE=""; CT_SRCMNT=""; CT_CFG=""

  CT_TO="$(target_of "$ct")"
  if [[ -z "$CT_TO" ]]; then
    log "[$ct] ERROR: no target - CT $ct has no row in $(basename "$FLEET") and no --to was given"
    log "[$ct] ERROR:   write the dr column down in advance, or say --to <ip> now."
    log "[$ct] ERROR:   nothing here picks a machine for you."
    st_fail "$ct" no_target; return 1
  fi
  CT_DST="$(storage_of "$ct")"

  # ---- the copy's config, read from the backup node's pmxcfs --------------
  cfg=$(rsh "${BKP_SSH#*@}" "cat /etc/pve/nodes/$BKP_NODE/lxc/$CT_SRC.conf 2>/dev/null")
  if [[ -z "$cfg" ]]; then
    log "[$ct] ERROR: no DR copy $CT_SRC on $BKP_NODE - nothing to place"
    log "[$ct] ERROR:   ct-replica has never successfully copied this container."
    st_fail "$ct" no_copy; return 1
  fi
  CT_SIZE=$(printf '%s\n' "$cfg" | sed -n 's/^rootfs:.*size=\([^,]*\).*/\1/p' | head -1)
  local bytes; bytes=$(tobytes "$CT_SIZE") || bytes=""
  if [[ -z "$bytes" || "$bytes" == 0 ]]; then
    log "[$ct] ERROR: cannot read a size from the copy's rootfs line ('${CT_SIZE:-<none>}')"
    log "[$ct] ERROR:   allocating a guessed size is how a rootfs arrives 90% copied."
    st_fail "$ct" bad_size; return 1
  fi

  # ---- GUARD D1: the PRODUCTION container must be verifiably down ---------
  local pnode pip pstat
  pnode=$(rsh "${BKP_SSH#*@}" "ls /etc/pve/nodes/*/lxc/$ct.conf 2>/dev/null" | head -1)
  pnode="${pnode#/etc/pve/nodes/}"; pnode="${pnode%%/*}"
  if [[ -n "$pnode" ]]; then
    pip="$(node_ip "$pnode")"; pip="${pip:-$pnode}"
    pstat=$(rsh "$pip" "pct status $ct 2>/dev/null" | awk '{print $2}')
    if [[ "$pstat" == running ]]; then
      log "[$ct] GUARD D1: production CT $ct is RUNNING on $pnode ($pip) - NOT placing a second copy"
      log "[$ct] GUARD D1:   the copy carries the same IP and MAC on purpose. Two of them"
      log "[$ct] GUARD D1:   answering at once is worse than the outage you are fixing."
      log "[$ct] GUARD D1:   stop it first:  ssh root@$pip pct shutdown $ct"
      st_skip "$ct" prod_running; return 1
    fi
    # Unreachable is NOT stopped. This used to log "taking the storage outage as
    # the reason" and carry on, which is the guess every other guard in this repo
    # refuses to make - and the header above has always claimed it refused.
    # The claim is now true. It also lines up with what the next check needs: a
    # node you cannot reach is a node on which you cannot have cleared onboot,
    # so proceeding means placing a second copy of a container that may still be
    # able to come back on its own.
    if [[ -z "$pstat" ]]; then
      log "[$ct] GUARD D1: $pnode ($pip) did not answer - production CT $ct is UNVERIFIED"
      log "[$ct] GUARD D1:   unreachable is not stopped. The copy carries the production IP"
      log "[$ct] GUARD D1:   and MAC, so placing one without knowing is how two machines end"
      log "[$ct] GUARD D1:   up on one address during the hour you can least afford it."
      log "[$ct] GUARD D1:   fix the ssh to $pip, or say so by hand with --to on a node you"
      log "[$ct] GUARD D1:   have checked yourself."
      st_skip "$ct" prod_unverified; return 1
    fi
    # Stopped is not enough: the storage node coming back re-arms an onboot=1
    # container the moment its rootfs is readable again, and nobody types a
    # command for that to happen. Then production and the 9xxx are both live,
    # on one IP and one MAC, writing into two rootfs that can never be merged.
    # PAUSE cannot help - the machine that holds it is the machine that died.
    local ponboot
    ponboot=$(rsh "$pip" "pct config $ct 2>/dev/null" | sed -n 's/^onboot:[[:space:]]*//p' | head -1)
    if [[ "${ponboot:-0}" == 1 ]]; then
      log "[$ct] GUARD D1: production CT $ct is stopped but has onboot: 1 on $pnode ($pip)"
      log "[$ct] GUARD D1:   it will start ITSELF the moment the storage node comes back, or"
      log "[$ct] GUARD D1:   the next time that node reboots. Two containers on one IP, each"
      log "[$ct] GUARD D1:   writing its own rootfs, and no way to merge them afterwards."
      log "[$ct] GUARD D1:   make it stay down first:  ssh root@$pip pct set $ct --onboot 0"
      log "[$ct] GUARD D1:   put it back to 1 after the recall - the DR guide says where."
      st_skip "$ct" prod_onboot; return 1
    fi
  fi

  # ---- GUARD D2: the source copy must be STOPPED -------------------------
  local sstat
  sstat=$(rsh "${BKP_SSH#*@}" "pct status $CT_SRC 2>/dev/null" | awk '{print $2}')
  if [[ "$sstat" == running ]]; then
    log "[$ct] GUARD D2: copy $CT_SRC is RUNNING on $BKP_NODE - refusing to copy out of a live rootfs"
    log "[$ct] GUARD D2:   whatever the customer touched last is the part that arrives torn."
    log "[$ct] GUARD D2:   either use the copy where it is, or stop it and place it."
    st_skip "$ct" copy_running; return 1
  fi

  # ---- where the copy's data actually is ---------------------------------
  local dest ds
  dest="${DEST_MAP[$ct]}"; ds="${DEST_DS[$dest]:-}"
  if [[ -z "$ds" ]]; then
    log "[$ct] ERROR: dest '$dest' is not in BKP_DESTS - cannot find the copy's data"
    st_fail "$ct" bad_dest; return 1
  fi
  CT_SRCMNT=$(rsh "${BKP_SSH#*@}" "zfs get -H -o value mountpoint $ds/subvol-$CT_SRC-disk-0 2>/dev/null")
  if [[ -z "$CT_SRCMNT" || "$CT_SRCMNT" == "-" || "$CT_SRCMNT" == none ]]; then
    log "[$ct] ERROR: cannot resolve the mountpoint of $ds/subvol-$CT_SRC-disk-0 on $BKP_NODE"
    st_fail "$ct" no_src_mount; return 1
  fi

  # ---- the target must answer, and must be able to reach the backup node --
  # Checked here rather than discovered mid-transfer: finding out afterwards
  # means an allocated volume and a half-written config to unpick by hand.
  if ! rsh "$CT_TO" true; then
    log "[$ct] ERROR: cannot ssh root@$CT_TO - NOTHING was allocated"
    st_fail "$ct" target_unreachable; return 1
  fi
  if ! rsh "$CT_TO" "ssh -o BatchMode=yes -o ConnectTimeout=10 $BKP_SSH true"; then
    log "[$ct] ERROR: $CT_TO cannot ssh $BKP_SSH - the transfer is issued THERE, pulling from here"
    log "[$ct] ERROR:   two cluster members normally already have this. Fix it with:"
    log "[$ct] ERROR:     ssh root@$CT_TO ssh-copy-id $BKP_SSH"
    st_fail "$ct" no_target_to_backup; return 1
  fi
  CT_TONODE=$(rsh "$CT_TO" 'readlink /etc/pve/local 2>/dev/null | sed "s|.*/||"' | head -1)
  if [[ -z "$CT_TONODE" ]]; then
    log "[$ct] ERROR: $CT_TO did not say which PVE node it is - cannot write a config for it"
    st_fail "$ct" target_no_identity; return 1
  fi

  # ---- GUARD D3: 9<id> must be free, everywhere ---------------------------
  local owners
  owners=$(rsh "${BKP_SSH#*@}" "ls /etc/pve/nodes/*/lxc/$CT_DR.conf /etc/pve/nodes/*/qemu-server/$CT_DR.conf 2>/dev/null")
  if [[ -n "$owners" ]]; then
    log "[$ct] GUARD D3: VMID $CT_DR already belongs to a guest in this cluster - NOTHING was allocated"
    while IFS= read -r _o; do [[ -n "$_o" ]] && log "[$ct] GUARD D3:   $_o"; done <<< "$owners"
    log "[$ct] GUARD D3:   placing on top of it would empty somebody else's rootfs."
    st_fail "$ct" dr_vmid_taken; return 1
  fi

  # ---- GUARD D4: the destination storage, by type -------------------------
  local key="$CT_TO/$CT_DST" shape
  if ! probe_storage "$CT_TO" "$CT_DST"; then
    log "[$ct] GUARD D4: storage '$CT_DST' does not exist on $CT_TONODE ($CT_TO)"
    log "[$ct] GUARD D4:   name one that does with --dst, or add it there first."
    st_fail "$ct" dst_unknown; return 1
  fi
  CT_DSTTYPE="${ST_TYPE[$key]}"
  shape="$(dst_shape "$CT_DSTTYPE")"
  if [[ -z "$shape" ]]; then
    log "[$ct] GUARD D4: storage '$CT_DST' on $CT_TONODE is type '$CT_DSTTYPE', which this engine does not know"
    log "[$ct] GUARD D4:   it handles lvmthin, lvm, dir, nfs and zfspool. Guessing at a type"
    log "[$ct] GUARD D4:   means mkfs on something that was not a block device."
    st_fail "$ct" dst_type_unknown; return 1
  fi
  # The Status column is a WORD - active, inactive or disabled - which is what
  # ct-replica.sh's dest_ready has always compared against. This read `!= 1`
  # for its first three weeks, because 1 is what the API returns and this moved
  # to the CLI without the comparison moving with it. A word is never equal to
  # 1, so D4 refused every storage on every node and distribute could not place
  # anything at all. Quote the word back: 'disabled' and 'inactive' are
  # different problems with different fixes, and reading "not ACTIVE" while
  # `pvesm status` plainly says active is how an hour disappears.
  if [[ "${ST_ACTIVE[$key]}" != active ]]; then
    log "[$ct] GUARD D4: storage '$CT_DST' is not ACTIVE on $CT_TONODE (pvesm says '${ST_ACTIVE[$key]}') - NOTHING was allocated"
    log "[$ct] GUARD D4:   an inactive storage is an empty directory that fills the root disk."
    st_fail "$ct" dst_inactive; return 1
  fi

  # ---- GUARD D5: free space, BEFORE anything is allocated -----------------
  # pvesm reports KiB. A thin pool that fills goes read-only and takes every
  # container already running on that node with it, so the headroom is checked
  # against the whole allocation rather than against what will actually be
  # written - a thin volume can grow to its full size later, in the middle of
  # the night, when nobody is looking.
  local availb needb
  availb=$(( ${ST_AVAIL[$key]:-0} * 1024 ))
  needb=$(( bytes + bytes * DR_HEADROOM_PCT / 100 ))
  if (( availb < needb )); then
    log "[$ct] GUARD D5: $CT_DST on $CT_TONODE has $(hsize "$availb") free, needs $(hsize "$needb")"
    log "[$ct] GUARD D5:   ($(hsize "$bytes") for the rootfs plus ${DR_HEADROOM_PCT}% headroom)"
    log "[$ct] GUARD D5:   a thin pool that fills goes READ-ONLY and takes every container"
    log "[$ct] GUARD D5:   on that node with it. Place this one somewhere else."
    st_fail "$ct" no_space; return 1
  fi

  # ---- the plan, printed whether or not anything is written ---------------
  log "[$ct] plan: copy $CT_SRC on $BKP_NODE  ->  CT $CT_DR on $CT_TONODE ($CT_TO)"
  log "[$ct]   storage  $CT_DST ($CT_DSTTYPE, $shape), $(hsize "$availb") free"
  log "[$ct]   rootfs   $CT_SIZE ($(hsize "$bytes"))"
  log "[$ct]   source   $BKP_SSH:$CT_SRCMNT"
  if (( LIST )); then st_ok "$ct" listed; return 0; fi
  if (( DRY )); then
    log "[$ct] DRY: would allocate, transfer and write /etc/pve/nodes/$CT_TONODE/lxc/$CT_DR.conf"
    log "[$ct] DRY: nothing was written"
    st_ok "$ct" dry; return 0
  fi

  # ---- allocate, by shape -------------------------------------------------
  local volname volid path mnt
  case "$shape" in
    block)   volname="vm-$CT_DR-disk-0";;
    image)   volname="vm-$CT_DR-disk-0.raw";;
    dataset) volname="subvol-$CT_DR-disk-0";;
  esac
  volid=$(rsh "$CT_TO" "pvesm alloc $CT_DST $CT_DR $volname ${CT_SIZE} 2>&1" | tail -1)
  if [[ "$volid" != *"$volname"* ]]; then
    log "[$ct] ERROR: pvesm alloc failed on $CT_TONODE: ${volid:-<no output>}"
    st_fail "$ct" alloc_failed; return 1
  fi
  path=$(rsh "$CT_TO" "pvesm path $CT_DST:$volname 2>/dev/null")
  if [[ -z "$path" ]]; then
    log "[$ct] ERROR: allocated $CT_DST:$volname on $CT_TONODE but pvesm cannot resolve its path"
    st_fail "$ct" no_path; return 1
  fi

  # ---- make it mountable, by shape ---------------------------------------
  # A dataset is already a directory and needs neither. Doing this by shape
  # rather than by storage id is the whole point of the abstraction: a new
  # storage of a known type needs no new code here.
  if [[ "$shape" == dataset ]]; then
    mnt="$path"
  else
    # A raw file needs a loop device; a block device does not. That is the only
    # difference between the two write shapes, and it is one word.
    local mopt=""; [[ "$shape" == image ]] && mopt="-o loop "
    mnt="/var/tmp/ctdist-$CT_DR"
    if ! rsh "$CT_TO" "mkfs.ext4 -F -q '$path' && mkdir -p '$mnt' && mount ${mopt}'$path' '$mnt' && mountpoint -q '$mnt'"; then
      log "[$ct] ERROR: could not make and mount a filesystem on $path ($CT_TONODE)"
      st_fail "$ct" mkfs_failed; return 1
    fi
    CUR_MNT="$mnt"; CUR_HOST="$CT_TO"
  fi

  # ---- the transfer, issued ON the target ---------------------------------
  # rsync cannot do remote-to-remote, and pulling everything through this
  # machine would double the traffic on the worst night of the year. The
  # target pulls; this engine only watches the exit code.
  local bw=$(( BW_TOTAL_MB / (LANES > 0 ? LANES : 1) ))
  (( bw < BW_MIN_MB )) && bw=$BW_MIN_MB
  local t0 t1
  t0=$(date +%s)
  rsh "$CT_TO" "rsync -aHAX --numeric-ids --sparse --delete --bwlimit=${bw}m \
      -e 'ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new' \
      '$BKP_SSH:$CT_SRCMNT/' '$mnt/' >/dev/null 2>&1; echo rc=\$?" \
    | sed -n 's/^rc=//p' > "$BASE/.dist-rc.$$" 2>/dev/null
  rc=$(cat "$BASE/.dist-rc.$$" 2>/dev/null); rm -f "$BASE/.dist-rc.$$"
  t1=$(date +%s); RS_SECS=$(( t1 - t0 ))
  [[ "$rc" =~ ^[0-9]+$ ]] || rc=1

  # 24 is "files vanished while copying", which is normal even on a stopped
  # rootfs because ct-replica may have been mid-round when the world ended.
  if [[ "$rc" != 0 && "$rc" != 24 ]]; then
    log "[$ct] ERROR: transfer failed rc=$rc - the volume is allocated but the config was NOT written"
    log "[$ct] ERROR:   nothing will use $CT_DST:$volname until you either retry or remove it:"
    log "[$ct] ERROR:     ssh root@$CT_TO pvesm free $CT_DST:$volname"
    cleanup_ct
    st_fail "$ct" xfer "$rc"; return 1
  fi
  cleanup_ct

  # ---- GUARD D6: the config, only now, and read back ----------------------
  # The copy's own config is the source: it already carries the production IP,
  # MAC and VLAN, which is exactly what has to come back up. Two lines change -
  # where the rootfs lives, and the bridge, because the copy sits on one with
  # no uplink by design and this container is meant to answer.
  local newcfg
  newcfg=$(printf '%s\n' "$cfg" \
    | sed -e "s|^rootfs:.*|rootfs: $CT_DST:$volname,size=$CT_SIZE|" \
          -e "s|^onboot:.*|onboot: 0|")
  newcfg=$(printf '%s\n' "$newcfg"; printf '# ct-distribute: temporary DR copy of CT %s, from %s on %s\n' "$ct" "$CT_SRC" "$BKP_NODE")
  CT_CFG="/etc/pve/nodes/$CT_TONODE/lxc/$CT_DR.conf"
  if ! printf '%s\n' "$newcfg" | ssh $SSH_OPT "root@$CT_TO" "cat > '$CT_CFG'" 2>/dev/null; then
    log "[$ct] ERROR: could not write $CT_CFG on $CT_TONODE"
    st_fail "$ct" cfg_write; return 1
  fi
  out=$(rsh "$CT_TO" "cat '$CT_CFG' 2>/dev/null")
  if [[ "$out" != "$newcfg" ]]; then
    log "[$ct] ERROR: $CT_CFG did not read back as what was sent - a truncated config is PERMANENT"
    log "[$ct] ERROR:   nothing here ever rewrites one. Remove it by hand and run again."
    st_fail "$ct" cfg_mismatch; return 1
  fi

  # ---- GUARD D7: a human starts it ---------------------------------------
  log "[$ct] placed: CT $CT_DR on $CT_TONODE, $CT_DST:$volname, rsync rc=$rc in ${RS_SECS}s"
  log "[$ct]   its network is still on the copy's bridge. Check it, then start it BY HAND:"
  log "[$ct]     ssh root@$CT_TO pct config $CT_DR"
  log "[$ct]     ssh root@$CT_TO pct set $CT_DR --net0 <the production bridge>"
  log "[$ct]     ssh root@$CT_TO pct start $CT_DR"
  st_ok "$ct" placed
  return 0
}

for _ct in "${CTS[@]}"; do
  hr_ct
  do_ct "$_ct" || true
  cleanup_ct
done

hr2
log "=== distribute finished: ok=$PASS skipped=$SKIPPED failed=$FAILED ==="
(( SKIPPED )) && log "  skipped: ${SKIPPED_IDS[*]}"
(( FAILED  )) && log "  failed:  ${FAILED_IDS[*]}"
if (( FAILED || SKIPPED )); then exit 1; fi
exit 0
