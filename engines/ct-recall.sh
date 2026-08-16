#!/usr/bin/env bash
# =============================================================================
#  ct-recall.sh  —  DISASTER ONLY. Bring a temporary DR container's data back
#                   from a compute node's own storage to its copy on the backup
#                   node. Run it from the storage node or the backup node.
# -----------------------------------------------------------------------------
#  ct-distribute.sh put a container on a compute node's local disk as 9<id> so
#  it could serve customers while the storage node was gone. From that moment
#  the only copy of everything the customer does is on ONE compute node's local
#  disk, with nothing replicating it. This is the engine that fixes that.
#
#      300     production. A raw image on the storage node, NFS-mounted by the
#              compute node that runs it. Stale from the moment 9300 started.
#      8300    the DR copy on the backup node. What this engine WRITES.
#              OFFSET=8000
#      9300    the temporary container on a compute node, serving traffic.
#              What this engine READS.                     DR_OFFSET=9000
#
#  It is a PRESYNC tool, like ct-migrate and ct-failback. Run it as often as
#  you like while 9300 is still serving; each round moves only what changed, so
#  the cutover window shrinks to seconds instead of the whole rootfs. Watch the
#  "changed=" number per container: when it stops shrinking, you are ready.
#
#  usage:
#    ct-recall.sh --list                    what would move where - read only
#    ct-recall.sh --all                     every container with a live 9<id>
#    ct-recall.sh --ctid 300                one container
#    ct-recall.sh --all --dry-run           every guard runs, nothing moves
#    ct-recall.sh --ctid 300 --final        LAST delta, 9<id> must be STOPPED
#
#  exit code: 0 = all ok, 1 = at least one container failed or was skipped,
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
#  WHY THIS IS THE MOST DANGEROUS ENGINE HERE
#
#  Every other engine writes into a copy, or into an image whose container is
#  verifiably stopped. This one writes into the DR copy - and the DR copy is
#  the only thing standing between the fleet and a second failure while the
#  storage node is down.
#
#  One inverted direction destroys every hour of customer work since the
#  disaster, and there is nothing to restore it from. So this engine does not
#  take a direction as an argument, and it does not decide which side is newer
#  by looking at timestamps: rsync preserves mtimes, so the copy's files can be
#  NEWER on disk than the DR container's while holding older data.
#
#  It uses provenance instead. ct-distribute.sh writes a marker line into the
#  9<id> config naming the container and the copy it came out of, and that line
#  is a fact PVE is holding: this rootfs descends from that copy. A 9<id>
#  without it was not made by ct-distribute out of this copy, its relationship
#  to the copy is unknown, and this engine refuses rather than guesses (C3).
#
#  WHERE THE BYTES GO, and why this engine is shaped like ct-distribute
#
#  Like ct-distribute it runs on NEITHER end of its own transfer: the data is
#  on a compute node and it is going to the backup node, and the machine typing
#  the commands is a third one. rsync cannot do remote-to-remote, so the
#  transfer is issued ON the compute node, pushing to the backup node:
#
#      ssh <compute> "rsync <local mount>/ root@<backup>:<copy dataset>/"
#
#  That needs root ssh from the compute node to the backup node - the same path
#  ct-distribute needed to pull, checked here before anything is mounted rather
#  than assumed.
#
#  THREE SOURCE SHAPES, because "local storage" is not one thing:
#
#    lvmthin / lvm   the volume is a block device. mount it, rsync out
#    dir / nfs       the volume is a .raw file. loop-mount it, rsync out
#    zfspool         the volume is a dataset, already a directory. rsync out
#
#  Anything else is refused by name. A storage type nobody has thought about is
#  not a storage type to guess at.
# -----------------------------------------------------------------------------
#  THE GUARDS (C1..C8). Same contract as every engine here: each one refuses
#  rather than warns, and the ORDER is part of the design.
#
#   C1  the 9<id> must exist, and this engine finds out WHERE it is by asking
#       the cluster - never from a typed argument. pmxcfs is cluster-shared, so
#       one `ls /etc/pve/nodes/*/lxc/9<id>.conf` through the backup node names
#       the holder. A node typed by a human is a node that can be wrong, and
#       being wrong here means reading an empty directory and then deleting a
#       customer's DR copy to match it.
#
#   C2  the copy 8<id> on the backup node must be STOPPED. A running copy means
#       somebody promoted it, so two containers are writing two rootfs that
#       both claim to be this customer - which is a decision for a human, not a
#       thing to overwrite.
#
#   C3  the 9<id> config must carry ct-distribute's marker naming THIS
#       container and THIS copy. That is how direction is established. See the
#       block above; docs/decisions.md section 6 is the argument.
#
#   C4  the mode must match the state of the 9<id>:
#         presync -> 9<id> RUNNING. Reading a live rootfs gives a slightly torn
#                    copy, which is exactly what a presync round is for; the
#                    round that matters is the last one.
#         final   -> 9<id> STOPPED. The last delta has to be consistent, and it
#                    is the one that will be started from.
#       A stopped 9<id> without --final is refused rather than treated as a
#       final round: "it happens to be down right now" and "we are cutting over"
#       are different intentions and only one of them is yours.
#
#       There is deliberately no PAUSE requirement, unlike ct-failback's B2.
#       What keeps ct-replica off the copy here is R13, and R13 keys on the
#       9<id> CONFIG existing rather than on it running - so it holds through
#       the shutdown, through --final, and until a human runs the `pct destroy`
#       this engine prints. PAUSE would add a second thing to remember for a
#       window that is already covered.
#
#   C5  the destination dataset on the backup node must report mounted=yes.
#       An unmounted dataset is an ordinary empty directory, and rsync --delete
#       into one fills the backup node's root filesystem. Identical to
#       ct-replica R3, for the identical reason.
#
#   C6  the source must be a real, already-mounted filesystem before rsync
#       runs - and WHOSE mount it is depends on the state, not just the shape:
#         zfspool          the storage's own mount. The container bind-mounts
#                          it, so there is one mount and both read it
#         running, block   the CONTAINER'S mount, reached through its mount
#         or image         namespace at /proc/<pid>/root. A second mount of a
#                          device LXC already has is not possible and must not
#                          be: ext4 refuses ro against its rw mount outright,
#                          and rw would be two kernels writing one journal
#         stopped          the device is nobody's, so mount it ro,noload
#       rsync out of a path nothing mounted copies an empty directory, and
#       --delete on the far end then empties the DR copy - which is why this
#       verifies rather than assumes, in all three cases.
#
#   C7  nothing is started, stopped or destroyed, ever. When the last round is
#       done this prints the `pct destroy 9<id>` and the `pct set <id>
#       --onboot 1` for a human to run. Same rule as every engine here, and it
#       matters most in this one: destroying the 9<id> is what releases R13,
#       and doing it automatically would release the shield on data nobody has
#       checked yet.
#
#   C8  both ends are locked on the machines that hold them - 9<id> on the
#       compute node first, then 8<id> on the backup node. A fixed order,
#       because this is the only engine that takes two and the other three take
#       exactly one each; a different order here is a deadlock waiting for the
#       night everything runs at once. docs/decisions.md section 2.
# =============================================================================
set -uo pipefail

# cron hands a script PATH=/usr/bin:/bin, and pvesm and zfs live in sbin. Same
# reason as every other engine here - see CLAUDE.md rule 8.
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="$BASE/ctrep.conf"
INV="$BASE/inventory-replica.tsv"
# ketsync's node map, read where ketsync KEEPS it rather than from a copy - see
# the note at the top of ct-distribute.sh. A mirror only one command refreshed
# is how a machine ended up holding a table it had been sent and an engine
# reading a file nobody had written.
NODEMAP="$BASE/nodes.map"
if [[ -f "$BASE/../bin/ketsync" && -f "$BASE/../lib/common.sh" && -f "$BASE/../conf/nodes.map" ]]; then
  NODEMAP="$(cd "$BASE/.." && pwd)/conf/nodes.map"
fi

# ---------- defaults; ctrep.conf wins ----------------------------------------
BKP_SSH="root@10.100.1.9"
BKP_NODE=""                      # pmxcfs name, discovered - see ct-replica.sh
BKP_DESTS="replica-hdd:replica-hdd/ct replica-ssd:replica-ssd/ct"
OFFSET=8000                      # production id -> DR copy id
DR_OFFSET=9000                   # production id -> temporary compute-node id
BW_TOTAL_MB=230
LANES=1
BW_MIN_MB=20
LOG_KEEP_DAYS=14                 # same knob, same ctrep.conf, as ct-replica.sh
SSH_CIPHERS=aes128-gcm@openssh.com,aes256-gcm@openssh.com,aes128-ctr
# -------------------------------------------------------------------------

ONLY_CTID=""; ALL=0; LIST=0; DRY=0; FINAL=0
while (( $# )); do
  case "$1" in
    --ctid)    [[ $# -ge 2 ]] || { echo "--ctid needs a value" >&2; exit 2; }
               ONLY_CTID="$2"; shift 2;;
    --all)     ALL=1; shift;;
    --list)    LIST=1; shift;;
    --final)   FINAL=1; shift;;
    --dry-run) DRY=1; shift;;
    -h|--help) awk 'NR>1{ if (/^#/) { sub(/^#[ ]?/,""); print } else exit }' "${BASH_SOURCE[0]}"; exit 0;;
    *) echo "unknown argument: $1" >&2; exit 2;;
  esac
done
if (( ! LIST )) && (( ! ALL )) && [[ ! "$ONLY_CTID" =~ ^[0-9]+$ ]]; then
  echo "usage: ct-recall.sh --list | --all | --ctid <production_ctid>" >&2
  echo "       [--final] [--dry-run]" >&2
  exit 2
fi

if [[ -f "$CONF" ]]; then
  # shellcheck source=/dev/null
  . "$CONF" || { echo "failed to read $CONF" >&2; exit 2; }
fi
for _v in OFFSET DR_OFFSET BW_TOTAL_MB LANES BW_MIN_MB LOG_KEEP_DAYS; do
  [[ "${!_v}" =~ ^[0-9]+$ ]] || { echo "$CONF: $_v must be a plain integer, got '${!_v}'" >&2; exit 2; }
done

# ---------- where the log goes ----------
# ONE tree for both layers, and the walk-up is CHECKED rather than assumed: a
# tp copied somewhere else, and every simulator sandbox, keeps its own logs/
# instead of writing outside its own tree.
LOGDIR="$BASE/logs"
if [[ -f "$BASE/../../ketsync" && -f "$BASE/../../lib/common.sh" ]]; then
  LOGDIR="$(cd "$BASE/../.." && pwd)/logs"
fi

mkdir -p "$LOGDIR" "$BASE/state" 2>/dev/null
LOG="$LOGDIR/recall-$(date +%F).log"
if (( LOG_KEEP_DAYS > 0 )); then
  find "$LOGDIR" -maxdepth 1 -type f -name 'recall-*.log' \
       -mtime +"$LOG_KEEP_DAYS" -delete 2>/dev/null || true
fi
log(){ printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG"; }
# Three widths of rule, because a daily log holds dozens of rounds and dozens
# of containers and they are not the same kind of edge.
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

HR_CT_SEEN=0
hr_ct(){ if (( HR_CT_SEEN )); then hr3; else hr2; HR_CT_SEEN=1; fi; }

hsize(){
  local b=${1:-0}
  if   (( b >= 1073741824 )); then printf '%d.%01dGiB' $(( b/1073741824 )) $(( (b%1073741824)*10/1073741824 ))
  elif (( b >= 1048576    )); then printf '%d.%01dMiB' $(( b/1048576 ))    $(( (b%1048576)*10/1048576 ))
  elif (( b >= 1024       )); then printf '%dKiB' $(( b/1024 ))
  else                             printf '%dB' "$b"; fi
}

SSH_COMMON="-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o ServerAliveInterval=15 -c $SSH_CIPHERS"
SSH_OPT="$SSH_COMMON -o ControlMaster=auto -o ControlPath=/run/ctrec-$$-%r@%h.sock -o ControlPersist=120"

# A pmxcfs node name -> the address to reach it on. Empty when there is no map
# or no row, and the caller decides: this never guesses an address, because a
# guess here reads the wrong machine's disk.
node_ip(){ awk -v n="$1" '$1!~/^#/ && $2==n{print $1; exit}' "$NODEMAP" 2>/dev/null; }

ST_PREFIX="recall-"
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
    printf '  "tool": "recall",\n'
    printf '  "ctid": %s,\n'      "$(json_str "$id")"
    printf '  "dr_vmid": %s,\n'   "$(json_str "${CT_DR:-}")"
    printf '  "copy_vmid": %s,\n' "$(json_str "${CT_TGT:-}")"
    printf '  "from_ip": %s,\n'   "$(json_str "${CT_FROM:-}")"
    printf '  "from_node": %s,\n' "$(json_str "${CT_FROMNODE:-}")"
    printf '  "storage": %s,\n'   "$(json_str "${CT_SID:-}")"
    printf '  "storage_type": %s,\n' "$(json_str "${CT_SIDTYPE:-}")"
    printf '  "last": {"ts":%s,"epoch":%s,"mode":%s,"status":%s,"reason":%s,"rc":%s,"secs":%s,"files":%s,"literal_bytes":%s,"bytes_sent":%s}\n' \
      "$(json_str "$(date '+%FT%T%z')")" "$(json_num "$(date +%s)")" \
      "$(json_str "$MODE")" "$(json_str "$2")" "$(json_str "$3")" \
      "$(json_num "$4")" "$(json_num "${RS_SECS:-0}")" "$(json_num "${RS_FILES:-0}")" \
      "$(json_num "${RS_LITERAL:-0}")" "$(json_num "${RS_SENT:-0}")"
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

MODE=presync; (( FINAL )) && MODE=final
(( DRY ))  && MODE="$MODE/dry-run"
(( LIST )) && MODE=list

# ---------- the destination pool map, the same one ct-replica reads ----------
declare -A DEST_DS=()
for _e in $BKP_DESTS; do
  _k="${_e%%:*}"; DEST_DS[$_k]="${_e#*:}"
  # The old form was key=dataset:storage-id - `hdd=replica-hdd/ct:replica-hdd`.
  # It still contains a colon, so nothing here noticed: the entry parsed as a
  # key of `hdd=replica-hdd/ct`, every row then fell through to DEFAULT_DEST,
  # and the run failed somewhere else entirely. An `=` is the old file every
  # time - a PVE storage id cannot contain one - and every fleet upgrading has
  # that line in ctrep.conf today. Refused here rather than three engines
  # deep, and worded identically in all four: it is one file.
  if [[ "$_e" == *=* ]]; then
    echo "ctrep.conf: BKP_DESTS entry '$_e' is the OLD key=dataset:storage-id form" >&2
    echo "ctrep.conf:   the short key ('hdd', 'ssd') is gone. The key IS the storage id now:" >&2
    echo "ctrep.conf:   BKP_DESTS=\"replica-hdd:replica-hdd/ct replica-ssd:replica-ssd/ct\"" >&2
    echo "ctrep.conf:   every row in inventory-replica.tsv names one of those, and" >&2
    echo "ctrep.conf:   a row without a dest is refused - there is no default." >&2
    exit 2
  fi
done

# ---------- the CT list, from ct-replica's inventory ----------
# The same file, read the same way, as ct-replica and ct-distribute. A
# container this engine can recall is by definition a container ct-replica
# copies, because the copy is where the data is going.
declare -a CTS=(); declare -A TGT_MAP=() DEST_MAP=()
if [[ ! -f "$INV" ]]; then
  log "ERROR: no inventory at $INV - NOTHING was run"
  log "ERROR:   this is ct-replica's file, not ct-migrate's inventory-migrate.tsv"
  log "ERROR:   start from the sample:  cp $BASE/inventory-replica.sample.tsv $INV"
  exit 2
fi
declare -a INV_ERRS=(); ln=0
while IFS= read -r line || [[ -n "${line:-}" ]]; do
  ln=$(( ln + 1 ))
  line="${line%%#*}"; read -r c rest <<<"$line" || true
  [[ "${c:-}" =~ ^[0-9]+$ ]] || continue
  t=""; dd=""
  for f in ${rest:-}; do
    if   [[ "$f" =~ ^[0-9]+$ ]];      then t="$f"
    elif [[ -n "${DEST_DS[$f]:-}" ]]; then dd="$f"
    fi
  done
  # No dest, no run. This used to fall through to DEFAULT_DEST, which pointed
  # this engine at whichever pool that variable named - and a copy that is not
  # there reads as "no copy", not as "wrong pool".
  if [[ -z "$dd" ]]; then
    INV_ERRS+=("line $ln: CT $c has no dest column. Every row names its pool: ${!DEST_DS[*]}")
    continue
  fi
  TGT_MAP[$c]=${t:-$(( c + OFFSET ))}
  DEST_MAP[$c]="$dd"
  CTS+=("$c")
done < "$INV"
if (( ${#INV_ERRS[@]} )); then
  log "ERROR: inventory is broken - NOTHING was run"
  for _e in "${INV_ERRS[@]}"; do log "ERROR:   $_e"; done
  log "ERROR: fix $INV, then run again"
  exit 2
fi

if [[ -n "$ONLY_CTID" ]]; then
  _keep=()
  for c in "${CTS[@]}"; do [[ "$c" == "$ONLY_CTID" ]] && _keep+=("$c"); done
  if (( ! ${#_keep[@]} )); then
    log "ERROR: no row in $INV for CT $ONLY_CTID - NOTHING was run"
    log "ERROR:   this engine writes into a DR copy, and the copies are the rows"
    log "ERROR:   in that file. A container with no copy has nowhere to come back to."
    exit 2
  fi
  CTS=("${_keep[@]}")
fi
if (( ! ${#CTS[@]} )); then
  log "ERROR: $INV names no CT - nothing to recall"
  exit 2
fi

hr
log "=== $(hostname) recall mode=$MODE candidates: ${CTS[*]} ==="

# ---------- preflight: local tools, before any lock and any transfer --------
# Local commands only: pvesm, zfs, mount and mkfs all run on other machines
# over ssh, and requiring them here would refuse a perfectly good orchestrator
# for not being a compute node. The order matters - `flock -n` on a host with
# no flock is command-not-found, which is indistinguishable from "somebody else
# holds the lock", so the engine would say it is skipping and return 0.
_missing=()
for _c in ssh flock awk sed mktemp; do
  command -v "$_c" >/dev/null 2>&1 || _missing+=("$_c")
done
if (( ${#_missing[@]} )); then
  log "ERROR: required command(s) not found: ${_missing[*]} (PATH=$PATH) - NOTHING was run"; exit 2
fi

RUN_LOCK=""
exec 9>"$BASE/.recall.lock" 2>/dev/null || true
if ! flock -n 9; then
  log "another recall is already running - skip"
  exit 0
fi
RUN_LOCK=1

# --- C8: the locks that live on the machines holding each end ----------------
# The lock above is a local flock and stops two recalls on THIS machine and
# nothing else. Both ends of this transfer are elsewhere, and both ends have
# other engines writing into them: ct-replica and ct-failback touch the 8<id>
# on the backup node, ct-distribute touches the 9<id> on the compute node.
#
# So the locks go where the data is, one per end, named after the VMID. `set
# -C` makes the redirect O_EXCL, so each destination's own kernel picks its
# winner. Same code, same file names, as ct-replica R14, ct-failback B8 and
# ct-distribute D8. docs/decisions.md section 2.
#
# This is the only engine that holds TWO, so it fixes the order: the 9<id> on
# the compute node first, then the 8<id> on the backup node. The other three
# take exactly one each, so a cycle needs two engines that each take two - and
# with one fixed order there is no such pair.
DST_LOCK_OWNER="recall $(hostname 2>/dev/null | tr -cd 'A-Za-z0-9._-') pid $$ started $(date '+%F %T')"
declare -a DST_LOCKS=()          # "host<TAB>vmid", in the order they were taken
DST_LOCK_WHO=""
dst_lock_file(){ printf '/run/ketsync-ct-%s.lock' "$1"; }

# 0 = ours, 1 = somebody else's, 2 = that machine could not be asked. Two is
# not one: an unanswered end is the case where carrying on puts two writers
# into one rootfs, which is the whole reason this exists.
take_dst_lock(){   # $1 = ssh destination, $2 = vmid
  local f out; f="$(dst_lock_file "$2")"; DST_LOCK_WHO=""
  out=$(ssh $SSH_OPT "$1" \
    "if (set -C; printf '%s\n' '$DST_LOCK_OWNER' > '$f') 2>/dev/null; then echo KETSYNC_LOCK_TAKEN; else echo KETSYNC_LOCK_HELD; cat '$f' 2>/dev/null; fi" \
    </dev/null 2>/dev/null)
  case "$out" in
    KETSYNC_LOCK_TAKEN*) DST_LOCKS+=("$1	$2"); return 0;;
    KETSYNC_LOCK_HELD*)  DST_LOCK_WHO="$(printf '%s\n' "$out" | sed -n '2p')"; return 1;;
  esac
  return 2
}
# Released in reverse, so the end taken last is the end freed first - the same
# discipline as taking them in a fixed order, and it keeps the window where
# this run holds only the 9<id> lock on the same side both times.
#
# The grep is not belt-and-braces. If a human clears a lock that looks stale
# while this run is alive, the next run takes it legitimately - and an
# unconditional rm here would delete a lock a live transfer is relying on.
release_dst_locks(){
  local i h v f
  for (( i = ${#DST_LOCKS[@]} - 1; i >= 0; i-- )); do
    IFS='	' read -r h v <<<"${DST_LOCKS[$i]}"
    f="$(dst_lock_file "$v")"
    ssh $SSH_OPT "$h" \
        "grep -qxF '$DST_LOCK_OWNER' '$f' 2>/dev/null && rm -f '$f'" \
        </dev/null >/dev/null 2>&1 || true
  done
  DST_LOCKS=()
}
# A dry run - and --list - reads and never creates. `exit 0` on the far end
# keeps "nothing is there" apart from "that machine did not answer"; without it
# an unreachable end reads exactly like a free lock.
peek_dst_lock(){   # $1 = ssh destination, $2 = vmid -> 0 free, 1 held, 2 no answer
  local out rc; DST_LOCK_WHO=""
  out=$(ssh $SSH_OPT "$1" "cat '$(dst_lock_file "$2")' 2>/dev/null; exit 0" </dev/null 2>/dev/null); rc=$?
  (( rc == 0 )) || return 2
  [[ -n "$out" ]] || return 0
  DST_LOCK_WHO="$(printf '%s\n' "$out" | sed -n '1p')"
  return 1
}

cleanup(){
  local s
  cleanup_ct
  release_dst_locks
  for s in /run/ctrec-$$-*.sock; do
    [[ -S "$s" ]] && ssh -O exit -o ControlPath="$s" x >/dev/null 2>&1
  done
  [[ -n "$RUN_LOCK" ]] && exec 9>&-
  return 0
}

# A signal is not a fleet problem, and it used to look like one. `trap cleanup
# EXIT INT TERM` runs the handler and then CARRIES ON from wherever the signal
# landed - and almost every remote call in this engine happens inside a command
# substitution, where SIGINT kills the subshell and leaves the parent to read
# an empty answer. So one Ctrl-C during a slow step produced a run that
# continued with "the node did not answer" for every machine it touched
# afterwards, on a night when that sentence means something specific and
# alarming. It is the operator's own keystroke, and the log has to say so.
on_signal(){   # $1 = the signal's name
  log "INTERRUPTED by SIG$1 - stopping here. Nothing after this line was attempted."
  log "  what has already been done stands: read the log above, and ./ketsync doctor"
  log "  lists anything this run left behind (records, disabled storages, stray 9<id>s)."
  cleanup
  exit $(( 128 + ${2:-2} ))
}
trap cleanup EXIT
trap 'on_signal INT 2' INT
trap 'on_signal TERM 15' TERM

# ---------- remote helpers, all against ONE machine at a time ---------------
rsh(){ ssh $SSH_OPT "root@$1" "${@:2}" </dev/null 2>/dev/null; }

# A `#` line in a PVE guest config is not a comment. It is the guest's
# DESCRIPTION field, PVE owns it, and PVE re-emits it URL-encoded every time it
# writes that config - `:` becomes %3A, and anything outside printable ASCII
# goes the same way. A file written directly, the way ct-distribute writes it,
# stays raw until the first `pct` command touches the container; after that it
# is encoded forever.
#
# So anything reading provenance out of a config decodes first. Backslashes are
# doubled before the substitution because printf %b would otherwise interpret
# whatever the description happened to contain.
pve_decode(){
  local s="${1//\\/\\\\}"
  printf '%b' "${s//%/\\x}"
}

# ---------- who the backup node actually is ---------------------------------
# Nobody types a pmxcfs name. /etc/pve/local is a symlink to nodes/<this node>,
# which is the authoritative identity - safer than hostname, which can drift
# from it after a badly done rename. Every path this engine writes on the
# backup node is built from it, and every cluster question goes through it.
_bknode=$(ssh $SSH_OPT "$BKP_SSH" 'readlink /etc/pve/local 2>/dev/null | sed "s|.*/||"' \
          </dev/null 2>/dev/null | head -1)
if [[ -z "$_bknode" ]]; then
  log "ERROR: cannot read the PVE node identity of $BKP_SSH - NOTHING was run"
  log "ERROR:   every byte this engine moves is going to that machine, so there"
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

# `pvesm status -storage <id>` on the compute node, as fields. The read half of
# the storage abstraction: one uniform way to ask any storage type whether it
# is active, instead of a branch per type spread through the flow.
declare -A ST_TYPE=() ST_ACTIVE=()
probe_storage(){   # $1=ip $2=storage-id -> fills ST_* for "$1/$2", rc 1 if unknown
  local key="$1/$2" out
  [[ -n "${ST_TYPE[$key]:-}" ]] && return 0
  out=$(rsh "$1" "pvesm status -storage $2 2>/dev/null" | awk -v s="$2" '$1==s{print $2, $3; exit}')
  [[ -n "$out" ]] || return 1
  read -r ST_TYPE[$key] ST_ACTIVE[$key] <<<"$out"
  return 0
}

# The three shapes, named once. Anything else is refused by name rather than
# guessed at, because guessing here means loop-mounting a block device, or
# rsyncing out of a path that was never mounted.
src_shape(){   # $1 = pve storage type -> block | image | dataset | ""
  case "$1" in
    lvmthin|lvm)   printf 'block';;
    dir|nfs|cifs)  printf 'image';;
    zfspool)       printf 'dataset';;
    *)             printf '';;
  esac
}

PASS=0; FAILED=0; SKIPPED=0; declare -a FAILED_IDS=() SKIPPED_IDS=() DONE_IDS=()
st_ok(){   PASS=$(( PASS + 1 )); DONE_IDS+=("$1"); st_write "$1" ok "$2" 0; }
st_fail(){ FAILED=$(( FAILED + 1 )); FAILED_IDS+=("$1"); st_write "$1" failed "$2" "${3:-1}"; }
st_skip(){ SKIPPED=$(( SKIPPED + 1 )); SKIPPED_IDS+=("$1"); st_write "$1" skipped "$2" 0; }

# =============================================================================
#  one container
# =============================================================================
CT_DR=""; CT_TGT=""; CT_FROM=""; CT_FROMNODE=""; CT_SID=""; CT_SIDTYPE=""
CT_DSTDS=""; CT_DSTMNT=""
CUR_MNT=""; CUR_HOST=""
RS_SECS=0; RS_FILES=0; RS_LITERAL=0; RS_SENT=0; RS_TOTAL=0

# The mount is on the COMPUTE node, not here, so cleaning it up is a remote
# call. It is done in the per-CT path rather than only in the exit trap: the
# trap cannot know which of many machines was mid-flight, and a stale mount
# left on a compute node during a DR is a mount somebody trips over an hour
# later. A dataset was never mounted by us and must never be unmounted by us -
# it is the storage's own, and unmounting it would take the copy offline.
cleanup_ct(){
  [[ -n "$CUR_MNT" && -n "$CUR_HOST" ]] || return 0
  rsh "$CUR_HOST" "umount '$CUR_MNT' 2>/dev/null; rmdir '$CUR_MNT' 2>/dev/null" || true
  CUR_MNT=""; CUR_HOST=""
  return 0
}

do_ct(){   # $1 = production ctid
  local ct="$1" rc=0 cfg marker mnt
  CT_DR=$(( ct + DR_OFFSET )); CT_TGT="${TGT_MAP[$ct]}"
  CT_FROM=""; CT_FROMNODE=""; CT_SID=""; CT_SIDTYPE=""
  CT_DSTDS=""; CT_DSTMNT=""
  RS_SECS=0; RS_FILES=0; RS_LITERAL=0; RS_SENT=0; RS_TOTAL=0

  # ---- GUARD C1: find the 9<id>, by asking the cluster --------------------
  # pmxcfs is shared, so the backup node can see a config that lives on a
  # compute node. Nobody types the holder: a node typed by a human is a node
  # that can be wrong, and wrong here reads an empty directory and then deletes
  # the customer's DR copy to match it.
  local path
  path=$(rsh "${BKP_SSH#*@}" "ls /etc/pve/nodes/*/lxc/$CT_DR.conf 2>/dev/null" | head -1)
  if [[ -z "$path" ]]; then
    log "[$ct] GUARD C1: no CT $CT_DR anywhere in this cluster - nothing to recall"
    log "[$ct] GUARD C1:   this engine reads a container ct-distribute.sh placed. If that"
    log "[$ct] GUARD C1:   never happened, the newest data for CT $ct is still the copy"
    log "[$ct] GUARD C1:   $CT_TGT on $BKP_NODE and there is nothing to bring back."
    st_skip "$ct" no_dr; return 1
  fi
  CT_FROMNODE="${path#/etc/pve/nodes/}"; CT_FROMNODE="${CT_FROMNODE%%/*}"
  CT_FROM="$(node_ip "$CT_FROMNODE")"
  if [[ -z "$CT_FROM" ]]; then
    log "[$ct] ERROR: CT $CT_DR is on node '$CT_FROMNODE' and nothing maps that to an address"
    log "[$ct] ERROR:   this host is outside the cluster, so it has neither the cluster's"
    log "[$ct] ERROR:   /etc/hosts nor its DNS. Run 'ketsync doctor' while the cluster is up"
    log "[$ct] ERROR:   to rebuild nodes.map, then run this again."
    st_fail "$ct" no_node_ip; return 1
  fi

  cfg=$(rsh "${BKP_SSH#*@}" "cat '$path' 2>/dev/null")
  if [[ -z "$cfg" ]]; then
    log "[$ct] ERROR: $path exists but could not be read through $BKP_NODE"
    st_fail "$ct" dr_cfg_unreadable; return 1
  fi

  # ---- GUARD C3: provenance, not timestamps -------------------------------
  # ct-distribute wrote this line when it made the container, and it names the
  # production id and the copy it came out of. That is the only fact available
  # that says which side is newer: mtimes cannot, because rsync preserves them
  # and the copy's files can be newer on disk while holding older data.
  #
  # The config is read through pve_decode() because a `#` line in a guest
  # config is NOT a comment - it is the guest's description field, and PVE owns
  # it. Every time PVE writes that config it re-emits the description
  # URL-encoded (PVE::Tools::encode_text escapes control characters and `:`),
  # so the colon in this marker becomes %3A the first time anybody starts or
  # stops the container. ct-distribute writes the file raw, so a fresh
  # placement matches and every one after a lifecycle change does not.
  #
  # That is not hypothetical: it is what the fleet hit. Two containers
  # presynced cleanly, were shut down for the cutover, and --final then refused
  # both with "does not say it came from copy 8110" - at the exact moment there
  # was nowhere else for the data to go.
  marker="# ct-distribute: temporary DR copy of CT $ct, from $CT_TGT on $BKP_NODE"
  if ! printf '%s\n' "$(pve_decode "$cfg")" | grep -qxF "$marker"; then
    log "[$ct] GUARD C3: CT $CT_DR on $CT_FROMNODE does not say it came from copy $CT_TGT"
    log "[$ct] GUARD C3:   expected this line in its config, written by ct-distribute.sh:"
    log "[$ct] GUARD C3:     $marker"
    log "[$ct] GUARD C3:   without it there is nothing to establish which side is newer, and"
    log "[$ct] GUARD C3:   this engine writes into the DR copy with --delete. Guessing the"
    log "[$ct] GUARD C3:   direction destroys every hour of work since the outage began."
    st_fail "$ct" no_provenance; return 1
  fi

  # ---- GUARD C4: the mode must match the state of the 9<id> ---------------
  local drstat
  drstat=$(rsh "$CT_FROM" "pct status $CT_DR 2>/dev/null" | awk '{print $2}')
  if [[ -z "$drstat" ]]; then
    log "[$ct] GUARD C4: $CT_FROMNODE ($CT_FROM) did not answer for CT $CT_DR"
    log "[$ct] GUARD C4:   unverified is not a state, and its state is what decides whether"
    log "[$ct] GUARD C4:   this round is a presync or a cutover. Fix the ssh to $CT_FROM."
    st_fail "$ct" dr_unverified; return 1
  fi
  if (( FINAL )); then
    if [[ "$drstat" != stopped ]]; then
      log "[$ct] GUARD C4: --final needs CT $CT_DR STOPPED (it is '$drstat')"
      log "[$ct] GUARD C4:   the last delta is the one that gets started from, so it has to"
      log "[$ct] GUARD C4:   be consistent. Stop it first, on the machine that runs it:"
      log "[$ct] GUARD C4:     ssh root@$CT_FROM pct shutdown $CT_DR"
      st_skip "$ct" final_dr_running; return 1
    fi
  else
    if [[ "$drstat" != running ]]; then
      log "[$ct] GUARD C4: presync expects CT $CT_DR RUNNING (it is '$drstat')"
      log "[$ct] GUARD C4:   a stopped DR container is not automatically a cutover. \"it is"
      log "[$ct] GUARD C4:   down right now\" and \"we are finishing\" are different intentions"
      log "[$ct] GUARD C4:   and only one of them is yours - say which:"
      log "[$ct] GUARD C4:     $(basename "${BASH_SOURCE[0]}") --ctid $ct --final"
      st_skip "$ct" dr_not_running; return 1
    fi
  fi

  # ---- GUARD C2: the copy on the backup node must be STOPPED --------------
  local cstat
  cstat=$(rsh "${BKP_SSH#*@}" "pct status $CT_TGT 2>/dev/null" | awk '{print $2}')
  if [[ "$cstat" == running ]]; then
    log "[$ct] GUARD C2: copy $CT_TGT is RUNNING on $BKP_NODE - refusing to write into it"
    log "[$ct] GUARD C2:   somebody promoted it, so that copy and CT $CT_DR are both taking"
    log "[$ct] GUARD C2:   customer writes and neither can be merged into the other. Which"
    log "[$ct] GUARD C2:   one is real is a decision for a human, not something to overwrite."
    st_skip "$ct" copy_running; return 1
  fi

  # ---- where the bytes are going, on the backup node ----------------------
  local dest="${DEST_MAP[$ct]}"
  CT_DSTDS="${DEST_DS[$dest]:-}/subvol-$CT_TGT-disk-0"
  # No check that $dest is a known key: it cannot be anything else. A field is
  # only classified as a dest when it IS a key, and a row with no dest is
  # refused when the inventory is read. The check that used to live here was
  # unreachable the moment DEFAULT_DEST - the one way an unknown value could
  # get this far - was removed.

  # ---- GUARD C5: that dataset must be MOUNTED ----------------------------
  # An unmounted dataset is an ordinary empty directory. rsync --delete into
  # one fills the backup node's root filesystem and leaves the copy looking
  # present and empty. ct-replica R3, for the identical reason.
  local dsinfo dsmounted
  dsinfo=$(rsh "${BKP_SSH#*@}" "zfs get -H -o value mounted,mountpoint $CT_DSTDS 2>/dev/null" | paste -sd' ')
  read -r dsmounted CT_DSTMNT <<<"${dsinfo:-}"
  if [[ "$dsmounted" != yes || -z "$CT_DSTMNT" || "$CT_DSTMNT" == none ]]; then
    log "[$ct] GUARD C5: $CT_DSTDS on $BKP_NODE is not a mounted dataset (mounted='${dsmounted:-none}')"
    log "[$ct] GUARD C5:   writing there now would fill the backup node's root filesystem"
    log "[$ct] GUARD C5:   and leave copy $CT_TGT looking present and empty."
    log "[$ct] GUARD C5:   check: ssh $BKP_SSH zfs mount -a"
    st_fail "$ct" dst_not_mounted; return 1
  fi

  # ---- the source volume on the compute node, by shape -------------------
  local rootfs volid
  rootfs=$(printf '%s\n' "$cfg" | sed -n 's/^rootfs:[[:space:]]*\([^,]*\).*/\1/p' | head -1)
  CT_SID="${rootfs%%:*}"; volid="$rootfs"
  if [[ -z "$CT_SID" || "$CT_SID" == "$rootfs" ]]; then
    log "[$ct] ERROR: cannot read a storage id from CT $CT_DR's rootfs line ('${rootfs:-<none>}')"
    st_fail "$ct" bad_rootfs; return 1
  fi
  if ! probe_storage "$CT_FROM" "$CT_SID"; then
    log "[$ct] ERROR: storage '$CT_SID' does not exist on $CT_FROMNODE ($CT_FROM)"
    log "[$ct] ERROR:   that is where CT $CT_DR says its rootfs lives."
    st_fail "$ct" src_storage_unknown; return 1
  fi
  CT_SIDTYPE="${ST_TYPE[$CT_FROM/$CT_SID]}"
  local shape; shape="$(src_shape "$CT_SIDTYPE")"
  if [[ -z "$shape" ]]; then
    log "[$ct] ERROR: storage '$CT_SID' on $CT_FROMNODE is type '$CT_SIDTYPE', which this engine does not know"
    log "[$ct] ERROR:   it handles lvmthin, lvm, dir, nfs and zfspool. Guessing at a type"
    log "[$ct] ERROR:   means loop-mounting a block device, or reading a path nothing mounted."
    st_fail "$ct" src_type_unknown; return 1
  fi
  # The Status column is a WORD - active, inactive or disabled. It was compared
  # against 1 in ct-distribute for three weeks, because 1 is what the API
  # returns and the engine moved to the CLI without the comparison moving with
  # it. A word is never equal to 1, so the guard refused every storage on the
  # fleet. Quote the word back: inactive and disabled are different problems.
  if [[ "${ST_ACTIVE[$CT_FROM/$CT_SID]}" != active ]]; then
    log "[$ct] ERROR: storage '$CT_SID' is not ACTIVE on $CT_FROMNODE (pvesm says '${ST_ACTIVE[$CT_FROM/$CT_SID]}')"
    log "[$ct] ERROR:   an inactive storage reads as an empty directory, and --delete on the"
    log "[$ct] ERROR:   far end would then empty copy $CT_TGT."
    st_fail "$ct" src_inactive; return 1
  fi

  # ---- the plan, printed whether or not anything moves --------------------
  log "[$ct] plan: CT $CT_DR on $CT_FROMNODE ($CT_FROM)  ->  copy $CT_TGT on $BKP_NODE"
  log "[$ct]   source   $CT_SID ($CT_SIDTYPE, $shape), volume $volid, CT is $drstat"
  log "[$ct]   dest     $CT_DSTDS mounted at $CT_DSTMNT"
  log "[$ct]   mode     $MODE"

  if (( LIST )); then st_ok "$ct" listed; return 0; fi

  # ---- C8: lock both ends, 9<id> first, then 8<id> -----------------------
  local _dl
  if (( DRY )); then
    peek_dst_lock "$CT_FROM" "$CT_DR"; _dl=$?
    (( _dl == 0 )) || {
      if (( _dl == 1 )); then
        log "[$ct] GUARD C8: DRY: CT $CT_DR is locked on $CT_FROMNODE - a real run would skip it"
        log "[$ct] GUARD C8: DRY:   holder: ${DST_LOCK_WHO:-<lock file unreadable>}"
        st_skip "$ct" c8_src_locked
      else
        log "[$ct] GUARD C8: DRY: $CT_FROMNODE did not answer - cannot say whether $CT_DR is free"
        st_fail "$ct" c8_src_unreachable
      fi
      return 1
    }
    peek_dst_lock "${BKP_SSH#*@}" "$CT_TGT"; _dl=$?
    (( _dl == 0 )) || {
      if (( _dl == 1 )); then
        log "[$ct] GUARD C8: DRY: copy $CT_TGT is locked on $BKP_NODE - a real run would skip it"
        log "[$ct] GUARD C8: DRY:   holder: ${DST_LOCK_WHO:-<lock file unreadable>}"
        st_skip "$ct" c8_dst_locked
      else
        log "[$ct] GUARD C8: DRY: $BKP_NODE did not answer - cannot say whether $CT_TGT is free"
        st_fail "$ct" c8_dst_unreachable
      fi
      return 1
    }
    log "[$ct] DRY: would rsync $shape source -> $CT_DSTDS on $BKP_NODE (--delete)"
    log "[$ct] DRY: nothing was written"
    st_ok "$ct" dry; return 0
  fi

  take_dst_lock "$CT_FROM" "$CT_DR"; _dl=$?
  if (( _dl == 1 )); then
    log "[$ct] GUARD C8: CT $CT_DR is locked on $CT_FROMNODE by another run - NOTHING was transferred"
    log "[$ct] GUARD C8:   holder: ${DST_LOCK_WHO:-<lock file unreadable>}"
    log "[$ct] GUARD C8:   file:   $CT_FROM:$(dst_lock_file "$CT_DR")"
    st_skip "$ct" c8_src_locked; return 1
  elif (( _dl == 2 )); then
    log "[$ct] GUARD C8: could not take CT $CT_DR on $CT_FROMNODE ($CT_FROM) - NOTHING was transferred"
    log "[$ct] GUARD C8:   no answer is not 'nobody has it'."
    st_fail "$ct" c8_src_unreachable; return 1
  fi
  take_dst_lock "${BKP_SSH#*@}" "$CT_TGT"; _dl=$?
  if (( _dl == 1 )); then
    log "[$ct] GUARD C8: copy $CT_TGT is locked on $BKP_NODE by another run - NOTHING was transferred"
    log "[$ct] GUARD C8:   holder: ${DST_LOCK_WHO:-<lock file unreadable>}"
    log "[$ct] GUARD C8:   file:   $BKP_SSH:$(dst_lock_file "$CT_TGT")"
    log "[$ct] GUARD C8:   ct-replica and ct-failback take this same lock. Whichever of them"
    log "[$ct] GUARD C8:   has it is mid-round on this copy right now."
    st_skip "$ct" c8_dst_locked; return 1
  elif (( _dl == 2 )); then
    log "[$ct] GUARD C8: could not take copy $CT_TGT on $BKP_NODE - NOTHING was transferred"
    log "[$ct] GUARD C8:   no answer is not 'nobody has it', and this run writes with --delete."
    st_fail "$ct" c8_dst_unreachable; return 1
  fi

  # ---- the compute node has to be able to reach the backup node ----------
  # The transfer is issued there, pushing. Finding this out afterwards means a
  # mount left behind on a compute node during a DR.
  if ! rsh "$CT_FROM" "ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 $BKP_SSH true"; then
    log "[$ct] ERROR: $CT_FROMNODE ($CT_FROM) cannot ssh $BKP_SSH - NOTHING was transferred"
    log "[$ct] ERROR:   the transfer is issued there and pushes, because rsync cannot do"
    log "[$ct] ERROR:   remote-to-remote and routing it through this machine would double"
    log "[$ct] ERROR:   the traffic on the worst night of the year. Fix it with:"
    log "[$ct] ERROR:     ssh root@$CT_FROM ssh-copy-id $BKP_SSH"
    st_fail "$ct" no_src_to_backup; return 1
  fi

  # ---- GUARD C6: a verified mountpoint, by shape -------------------------
  # A dataset is already a directory and is the storage's own mount - we never
  # mounted it, so we never unmount it. The other two we mount ourselves and
  # then CHECK, because rsync out of a path nothing mounted copies an empty
  # directory and --delete on the far end empties the copy.
  local vpath
  vpath=$(rsh "$CT_FROM" "pvesm path $volid 2>/dev/null")
  if [[ -z "$vpath" ]]; then
    log "[$ct] ERROR: pvesm on $CT_FROMNODE cannot resolve a path for $volid"
    st_fail "$ct" no_path; return 1
  fi
  if [[ "$shape" == dataset ]]; then
    # The storage's own mount, and the container reaches it by bind-mount, so
    # there is one mount and both of us read it. We never mounted it and we
    # never unmount it: doing so would take a live container's rootfs away.
    mnt="$vpath"
    if ! rsh "$CT_FROM" "mountpoint -q '$mnt'"; then
      log "[$ct] GUARD C6: $mnt on $CT_FROMNODE is not a mountpoint - NOTHING was transferred"
      log "[$ct] GUARD C6:   an unmounted dataset is an empty directory, and --delete on the"
      log "[$ct] GUARD C6:   far end would empty copy $CT_TGT to match it."
      st_fail "$ct" src_not_mounted; return 1
    fi
  elif [[ "$drstat" == running ]]; then
    # A block device or a loop-backed raw file is ALREADY mounted, by the
    # container, read-write. Mounting it a second time read-only does not work
    # and must not: ext4 refuses it outright -
    #
    #     mount warning: * dm-6: Can't mount, would change RO state
    #
    # and the only way to make it succeed would be to mount it rw a second
    # time, which is two kernels writing one journal. This engine did exactly
    # that on the first live presync round and C6 caught it - the guard held,
    # but it was refusing every running container, which is every presync round
    # there is.
    #
    # So the mount is not made at all: the container's own is reused, through
    # its mount namespace. That is what a presync round should read anyway - a
    # live filesystem, slightly torn, superseded by the --final round below
    # when the container is stopped and the device is free.
    local _pid
    _pid=$(rsh "$CT_FROM" "lxc-info -n $CT_DR -pH 2>/dev/null" | tr -cd '0-9')
    if [[ -z "$_pid" || "$_pid" == 0 ]]; then
      log "[$ct] GUARD C6: CT $CT_DR reports running but $CT_FROMNODE gave no pid for it"
      log "[$ct] GUARD C6:   its rootfs is reached through that process, so there is nothing"
      log "[$ct] GUARD C6:   to read. NOTHING was transferred."
      log "[$ct] GUARD C6:   check: ssh root@$CT_FROM lxc-info -n $CT_DR -pH"
      st_fail "$ct" no_dr_pid; return 1
    fi
    mnt="/proc/$_pid/root"
    if ! rsh "$CT_FROM" "test -d '$mnt/etc'"; then
      log "[$ct] GUARD C6: $mnt on $CT_FROMNODE does not look like a root filesystem"
      log "[$ct] GUARD C6:   NOTHING was transferred - reading the wrong path and then"
      log "[$ct] GUARD C6:   running --delete on the far end would empty copy $CT_TGT."
      st_fail "$ct" src_not_mounted; return 1
    fi
  else
    # Stopped, so the device is nobody's. A raw file needs a loop device; a
    # block device does not, and that is the only difference between the two
    # read shapes. Read-only with noload, because replaying a journal that was
    # not cleanly closed is a write into the one copy of the customer's data.
    local mopt="-o ro,noload"; [[ "$shape" == image ]] && mopt="-o loop,ro,noload"
    mnt="/var/tmp/ctrec-$CT_DR"
    if ! rsh "$CT_FROM" "mkdir -p '$mnt' && mount $mopt '$vpath' '$mnt' && mountpoint -q '$mnt'"; then
      log "[$ct] GUARD C6: could not mount $vpath read-only at $mnt on $CT_FROMNODE"
      log "[$ct] GUARD C6:   NOTHING was transferred. rsync out of an unmounted path copies"
      log "[$ct] GUARD C6:   an empty directory, and --delete would empty copy $CT_TGT."
      st_fail "$ct" src_mount_failed; return 1
    fi
    CUR_MNT="$mnt"; CUR_HOST="$CT_FROM"
  fi

  # ---- the transfer, issued ON the compute node --------------------------
  local bw=$(( BW_TOTAL_MB / (LANES > 0 ? LANES : 1) ))
  (( bw < BW_MIN_MB )) && bw=$BW_MIN_MB
  # --stats goes to rsync's STDOUT, which comes back over the same ssh as the
  # exit code - so one remote command, one shape, and no temporary file left on
  # a compute node when a run is killed. The numbers are parsed HERE rather
  # than in a compound remote command: a shell pipeline sent over ssh is a
  # shell pipeline nobody can read in a log, and the far side is the one place
  # a mistake in it would be invisible.
  local t0 t1 out
  t0=$(date +%s)
  # -x, one file system, and it is doing real work in the running case: the
  # path is the container's own root, so everything it has mounted is under it
  # - /proc, /sys, /dev, and any mp0 the operator added. A copy is the rootfs
  # and nothing else, which is the same rule ct-replica follows.
  out=$(rsh "$CT_FROM" "rsync -aHAX -x --numeric-ids --sparse --delete --bwlimit=${bw}m --stats \
      -e 'ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new' \
      '$mnt/' '$BKP_SSH:$CT_DSTMNT/' 2>/dev/null; echo rc=\$?")
  t1=$(date +%s); RS_SECS=$(( t1 - t0 ))
  rc=$(printf '%s\n' "$out" | sed -n 's/^rc=//p' | head -1)
  [[ "$rc" =~ ^[0-9]+$ ]] || rc=1
  # rsync prints these with thousands separators and a trailing " bytes".
  RS_FILES=$(printf   '%s\n' "$out" | sed -n 's/^Number of regular files transferred: *\([0-9,]*\).*/\1/p' | tr -d ',' | head -1)
  RS_LITERAL=$(printf '%s\n' "$out" | sed -n 's/^Literal data: *\([0-9,]*\).*/\1/p'                        | tr -d ',' | head -1)
  # SENT, because this rsync runs on the compute node and PUSHES to the backup
  # node - it is the sender, and its "received" line is the acknowledgements.
  # Each engine reads whichever line its own direction puts the traffic on.
  RS_SENT=$(printf    '%s\n' "$out" | sed -n 's/^Total bytes sent: *\([0-9,]*\).*/\1/p'                     | tr -d ',' | head -1)
  RS_TOTAL=$(printf   '%s\n' "$out" | sed -n 's/^Total file size: *\([0-9,]*\).*/\1/p'                      | tr -d ',' | head -1)
  for _n in RS_FILES RS_LITERAL RS_SENT RS_TOTAL; do [[ "${!_n}" =~ ^[0-9]+$ ]] || printf -v "$_n" 0; done

  cleanup_ct

  # 24 is "files vanished while copying", which is normal and expected on a
  # presync round: the container is live and deleting its own temporary files.
  if [[ "$rc" != 0 && "$rc" != 24 ]]; then
    log "[$ct] ERROR: transfer failed rc=$rc - copy $CT_TGT is now PART WRITTEN"
    log "[$ct] ERROR:   run this again before you rely on it. Nothing else has changed:"
    log "[$ct] ERROR:   CT $CT_DR still holds the newest data and is untouched."
    st_fail "$ct" xfer "$rc"; return 1
  fi

  log "[$ct] stats: files=$RS_FILES changed=$(hsize "$RS_LITERAL") wire=$(hsize "$RS_SENT") of $(hsize "$RS_TOTAL") time=${RS_SECS}s avg=$(hsize "$(( RS_SENT / (RS_SECS > 0 ? RS_SECS : 1) ))")/s"
  log "[$ct] OK -> $CT_TGT (rc=$rc)"
  if (( FINAL )); then
    # ---- GUARD C7: a human unwinds it -----------------------------------
    log "[$ct] FINAL round done. Copy $CT_TGT on $BKP_NODE now holds the newest data."
    log "[$ct]   ct-replica still leaves it alone, because R13 keys on CT $CT_DR's config"
    log "[$ct]   existing - not on it running. That holds until somebody destroys it."
    log "[$ct]   When the production image is back (ct-failback --ctid $ct --final):"
    log "[$ct]     ct-prepare.sh --cleanup --ctid $ct"
    log "[$ct]   puts CT $ct's own network and onboot back, stops CT $CT_DR and takes it off"
    log "[$ct]   the wire. Add --destroy when you no longer want it as a fallback: that is"
    log "[$ct]   what releases R13, and releasing it on data nobody has checked is the one"
    log "[$ct]   thing this cannot undo. Nothing here does either by itself."
  fi
  st_ok "$ct" recalled
  return 0
}

for _ct in "${CTS[@]}"; do
  hr_ct
  do_ct "$_ct" || true
  cleanup_ct
  # Both locks are per container, so they are dropped per container. Holding
  # one CT's locks while the next runs would look, to every other machine, like
  # one enormous transaction over the whole fleet.
  release_dst_locks
done

hr2
log "=== recall finished: ok=$PASS skipped=$SKIPPED failed=$FAILED ==="
(( SKIPPED )) && log "  skipped: ${SKIPPED_IDS[*]}"
(( FAILED  )) && log "  failed:  ${FAILED_IDS[*]}"
(( FAILED || SKIPPED )) && exit 1
exit 0
