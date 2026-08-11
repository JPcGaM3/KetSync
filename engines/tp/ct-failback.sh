#!/usr/bin/env bash
# =============================================================================
#  ct-failback.sh  —  run on the STORAGE NODE (the same one ct-replica runs on)
# -----------------------------------------------------------------------------
#  The reverse of ct-replica: pulls copies that were PROMOTED on the backup
#  node back into the production CTs' raw images on this node.
#
#  It is a PRESYNC tool, like ct-migrate. Run it as often as you like while the
#  copies are still serving traffic; each round only moves what changed, so the
#  cutover window shrinks to seconds instead of the whole rootfs. The "changed="
#  number per CT is the thing to watch: when it stops shrinking, you are ready.
#
#  usage:
#    ct-failback.sh --list                  who is where, what state - read only
#    ct-failback.sh --all                   presync every CT in the inventory
#    ct-failback.sh --ctid 110              presync one CT
#    ct-failback.sh --all --dry-run         show what would move, touch nothing
#    ct-failback.sh --all --final           LAST delta, copies must be STOPPED
#    ct-failback.sh --all --dest ssd        only CTs whose copy is on that pool
#
#  A real disaster promotes many CTs at once, so --all is the normal form and
#  a per-CT guard failure SKIPS that CT instead of stopping the batch: one
#  container nobody remembered to shut down must not strand the other twenty.
#  Only conditions that are wrong for the whole run (bad config, missing PAUSE)
#  refuse up front.
#
#  It reads ctrep.conf and inventory-replica.tsv from its own folder - the same
#  pair ct-replica.sh reads, never ct-migrate.sh's inventory-migrate.tsv - so
#  the backup node, the dest pools and any custom tgt_ctid are exactly what
#  ct-replica uses. Nothing is configured twice.
#
#  This tool does NOT do cutover. Stopping copies, starting production CTs,
#  putting each copy's network back on the mock bridge and removing PAUSE are
#  done by hand - it prints the list when it finishes.
#
#  BEFORE YOU NEED THIS, run `ct-failback.sh --list` on an ordinary day. B1 has
#  to know whether each production CT is stopped, and this host is outside the
#  cluster on purpose - it has neither the cluster's /etc/hosts nor a key to any
#  compute node, and it never will. So it asks the BACKUP node, which is a
#  member, over the cluster API. That makes the ssh to the backup node the one
#  connection this engine cannot work without: it carries the CT configs, the
#  statuses, the node's own identity and the data itself. --list is where you
#  find out that it is missing, on a Tuesday rather than mid-incident, and it
#  exits 1 rather than 0 while saying so.
#
#  exit code: 0 = all ok, 1 = at least one CT failed or was skipped,
#             2 = refused before touching anything.
# -----------------------------------------------------------------------------
#  THE GUARDS (B1..B6). Failback is the one direction where a mistake destroys
#  PRODUCTION data rather than a copy, so these refuse rather than warn.
#
#   B1  the production CT must be STOPPED on its own node. Its rootfs is a raw
#       image; this tool loop-mounts that image here. Mounted twice - once by
#       the running CT, once by us - is instant ext4 corruption, and it is the
#       live customer container that gets corrupted. If the node cannot be
#       reached to verify, that is also a refusal: unverified is not stopped.
#
#   B2  the copy's state must match the mode, because the two modes rely on
#       different things to keep ct-replica off the copy:
#         presync -> copy RUNNING. That is what makes ct-replica's R2 skip it,
#                    and it is also what makes the copy the newer data.
#         final   -> copy STOPPED *and* ct-replica's PAUSE file present. Once
#                    the copy stops, R2 stops protecting it, and the next cron
#                    tick would overwrite the DR data with the stale original.
#                    PAUSE is the only thing standing there, so it is checked
#                    once for the whole run, before any CT is touched.
#
#   B3  the image must live on a mounted filesystem, never on the node root.
#       Identical to ct-replica R1: an unmounted dataset leaves an ordinary
#       empty directory behind, and writing "into the image" then fills the
#       node's root disk instead.
#
#   B4  the image must already exist. This restores INTO a container that is
#       still configured and still owns its volume. A missing image means the
#       CT was destroyed or the storage is wrong - that is a rebuild, a
#       different operation, and guessing at it here would create a volume
#       nobody asked for.
#
#   B5  the loop mount must be verified as a real mountpoint before rsync, and
#       the unmount must succeed before any resize. Same reasoning as ct-migrate
#       G1/G3, in the same order, for the same two disasters.
#
#   B6  ENOSPC grows the image instead of leaving a half-restored rootfs. Data
#       written during DR can exceed the original quota; refusing there would
#       strand the failback at the worst moment. Bounded, and it says loudly
#       that the CT config's size= no longer matches.
# =============================================================================
set -uo pipefail

# A login shell without sbin in PATH hides pvesm exactly the way cron does;
# keep this environment identical to ct-replica's.
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="$BASE/ctrep.conf"
INV="$BASE/inventory-replica.tsv"

# ---------- defaults (ctrep.conf wins; they are the same knobs) ----------
BKP_SSH="root@100.100.100.35"
BKP_NODE=""                      # pmxcfs name, discovered - see ct-replica.sh
BKP_DESTS="hdd=replica-hdd/ct:replica-hdd ssd=replica-ssd/ct:replica-ssd"
DEFAULT_DEST="hdd"
OFFSET=8000
BW_TOTAL_MB=230
LANES=1
BW_MIN_MB=20
LOG_KEEP_DAYS=14
MNT_BASE=/mnt/ct-replica
GROW_PCT=5               # grow step per ENOSPC retry
GROW_MAX_RETRY=3
SSH_CIPHERS=aes128-gcm@openssh.com,aes256-gcm@openssh.com,aes128-ctr
# -------------------------------------------------------------------------

ONLY_CTID=""; ALL=0; LIST=0; FINAL=0; DRY=0; ONLY_DEST=""; NO_SNAPSHOT=0
# A value-taking flag whose value was lost to a copy-paste used to hang here
# forever: `shift 2` fails when only one argument is left, the old `|| true`
# swallowed that failure, and $# never reached zero. This one is typed by hand
# during an incident, which is exactly when a hung command with no output is
# worst. Refuse instead. "$2" is deliberately not "${2:-}", so that deleting
# the check below dies on set -u rather than spinning again.
while (( $# )); do
  case "$1" in
    --ctid)    [[ $# -ge 2 ]] || { echo "--ctid needs a value" >&2; exit 2; }
               ONLY_CTID="$2"; shift 2;;
    --dest)    [[ $# -ge 2 ]] || { echo "--dest needs a value" >&2; exit 2; }
               ONLY_DEST="$2"; shift 2;;
    --all)     ALL=1; shift;;
    --list)    LIST=1; shift;;
    --final)   FINAL=1; shift;;
    --dry-run) DRY=1; shift;;
    # B7's escape hatch. Typed by hand, during an incident, by somebody who has
    # read the refusal and decided the risk is acceptable. Nobody reaches it by
    # accident, and the run record says it was used.
    --no-snapshot) NO_SNAPSHOT=1; shift;;
    # Walks the comment block instead of counting lines: a fixed range used to
    # stop short of the exit-code contract, which is the half of the header
    # anything running under cron needs most. Strips the # the way tp does.
    -h|--help) awk 'NR>1{ if (/^#/) { sub(/^#[ ]?/,""); print } else exit }' "${BASH_SOURCE[0]}"; exit 0;;
    *) echo "unknown argument: $1" >&2; exit 2;;
  esac
done
if (( ! LIST )) && (( ! ALL )) && [[ ! "$ONLY_CTID" =~ ^[0-9]+$ ]]; then
  echo "usage: ct-failback.sh --list | --all | --ctid <production_ctid>" >&2
  echo "       [--dest hdd|ssd] [--dry-run] [--final]" >&2
  exit 2
fi

if [[ -f "$CONF" ]]; then
  # shellcheck source=/dev/null
  . "$CONF" || { echo "failed to read $CONF" >&2; exit 2; }
fi
for _v in OFFSET BW_TOTAL_MB LANES BW_MIN_MB GROW_PCT GROW_MAX_RETRY LOG_KEEP_DAYS; do
  [[ "${!_v}" =~ ^[0-9]+$ ]] || { echo "ctrep.conf: $_v='${!_v}' is not a plain integer" >&2; exit 2; }
done
if [[ -n "$SSH_CIPHERS" && ! "$SSH_CIPHERS" =~ ^[A-Za-z0-9@.,+-]+$ ]]; then
  echo "ctrep.conf: SSH_CIPHERS is not a plain cipher list" >&2; exit 2
fi

# only the dataset half of BKP_DESTS matters here: the copy is read as a
# directory over ssh, never through PVE, so its storage id is irrelevant.
declare -A DEST_DS=()
for _kv in $BKP_DESTS; do
  _k="${_kv%%=*}"; _rest="${_kv#*=}"
  DEST_DS[$_k]="${_rest%%:*}"
done
if [[ -n "$ONLY_DEST" && -z "${DEST_DS[$ONLY_DEST]:-}" ]]; then
  echo "--dest '$ONLY_DEST' is not a key in BKP_DESTS ($BKP_DESTS)" >&2; exit 2
fi

_bw=$(( BW_TOTAL_MB / LANES )); (( _bw < BW_MIN_MB )) && _bw=$BW_MIN_MB
BWLIMIT="${_bw}m"

SSH_COMMON="-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
-o GSSAPIAuthentication=no -o ServerAliveInterval=30 -o ServerAliveCountMax=6"
SSH_OPT="$SSH_COMMON -o ControlMaster=auto -o ControlPath=/run/ctback-$$-%r@%h.sock -o ControlPersist=120"
SSH_DATA="$SSH_COMMON -o ControlMaster=no -o ControlPath=none -o Compression=no"
[[ -n "$SSH_CIPHERS" ]] && SSH_DATA="$SSH_DATA -c $SSH_CIPHERS"

mkdir -p "$BASE/logs" "$BASE/state" "$MNT_BASE"
LOG="$BASE/logs/failback-$(date +%F).log"
if (( LOG_KEEP_DAYS > 0 )); then
  find "$BASE/logs" -maxdepth 1 -type f -name 'failback-*.log' \
       -mtime +"$LOG_KEEP_DAYS" -delete 2>/dev/null || true
fi
log(){ printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG"; }

# A daily log holds dozens of rounds and dozens of containers. Operations are
# separated by a rule so the eye can find where one ends and the next begins
# without reading timestamps - which is what somebody is actually doing at 2am,
# scrolling for the container that failed. Deliberately no timestamp on the
# rule itself: it is furniture, not an event.
LOGSEP='##############################################################################'
hr(){ printf '%s\n' "$LOGSEP" | tee -a "$LOG"; }

hsize(){
  local b=${1:-0}
  if   (( b >= 1073741824 )); then printf '%d.%01dGiB' $(( b/1073741824 )) $(( (b%1073741824)*10/1073741824 ))
  elif (( b >= 1048576    )); then printf '%d.%01dMiB' $(( b/1048576 ))    $(( (b%1048576)*10/1048576 ))
  elif (( b >= 1024       )); then printf '%dKiB' $(( b/1024 ))
  else                             printf '%dB' "$b"; fi
}
_rs_num(){ sed -n "s/.*$1: *\([0-9,][0-9,]*\).*/\1/p" "$2" 2>/dev/null | tr -d ',' | tail -1; }

# ---------- state: what this run did to this CT, so it can be read back ------
# This engine wrote nothing at all until now. Every value below was already in
# hand - it was simply never written down, so `tp status` could never show a
# failback and an incident could not be reconstructed afterwards. A failback is
# the run you are most likely to have to explain to somebody later.
#
# Its own prefix, like the other two: state/failback-<ctid>.json. A restore and
# a replica round both concern the same container, and the second writer must
# not erase the first one's record.
ST_PREFIX="failback-"
json_str(){ local s="${1//\\/\\\\}"; s="${s//\"/\\\"}"; printf '"%s"' "$s"; }
json_num(){ [[ "${1:-}" =~ ^-?[0-9]+$ ]] && printf '%s' "$1" || printf '0'; }

st_write(){   # $1=ctid $2=status $3=reason $4=rc  - replaced atomically
  local id="$1" f t
  [[ -n "$id" ]] || return 0
  (( DRY )) && return 0          # a dry run records nothing, like the other two
  f="$BASE/state/$ST_PREFIX$id.json"; t="$BASE/state/.$ST_PREFIX$id.json.$$"
  {
    printf '{\n'
    printf '  "schema_version": 1,\n'
    printf '  "tool": "failback",\n'
    printf '  "ctid": %s,\n'      "$(json_str "$id")"
    printf '  "copy_vmid": %s,\n' "$(json_str "${CT_TGT:-}")"
    printf '  "dest": %s,\n'      "$(json_str "${CT_DEST:-}")"
    printf '  "prod_node": %s,\n' "$(json_str "${CT_NODE:-}")"
    printf '  "storage": %s,\n'   "$(json_str "${CT_SID:-}")"
    printf '  "image": %s,\n'     "$(json_str "${CT_IMG:-}")"
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

# One line per run, append-only, so "has this CT been failed back before, and
# how did it go" is answerable months later. Trimmed rarely and atomically.
st_history(){
  local id="$1"
  local h="$BASE/state/$ST_PREFIX$id.runs.jsonl" n
  # one stderr redirect, not two: the second silently wins and the first is a
  # lie the reader has to work out for themselves
  sed -n 's/^  "last": //p' "$BASE/state/$ST_PREFIX$id.json" >> "$h" 2>/dev/null || true
  n=$(wc -l < "$h" 2>/dev/null || echo 0)
  if [[ "$n" =~ ^[0-9]+$ ]] && (( n > 200 )); then
    tail -n 200 "$h" > "$h.tmp.$$" 2>/dev/null \
      && mv -f "$h.tmp.$$" "$h" 2>/dev/null || rm -f "$h.tmp.$$" 2>/dev/null
  fi
}


# ---------- the CT list, from the same inventory ct-replica reads ----------
declare -a CTS=(); declare -A TGT_MAP=() DEST_MAP=(); declare -a UNREACHABLE=()
if [[ -f "$INV" ]]; then
  while IFS= read -r line || [[ -n "${line:-}" ]]; do
    line="${line%%#*}"; read -r c rest <<<"$line" || true
    [[ "${c:-}" =~ ^[0-9]+$ ]] || continue
    t=""; dd=""
    for f in ${rest:-}; do
      if   [[ "$f" =~ ^[0-9]+$ ]];      then t="$f"
      elif [[ -n "${DEST_DS[$f]:-}" ]]; then dd="$f"
      fi
    done
    TGT_MAP[$c]=${t:-$(( c + OFFSET ))}
    DEST_MAP[$c]=${dd:-$DEFAULT_DEST}
    CTS+=("$c")
  done < "$INV"
fi
if [[ -n "$ONLY_CTID" ]]; then
  # a CT that is not in the inventory is still failback-able: it may have been
  # removed from replication already. Fall back to the derived defaults.
  [[ -n "${TGT_MAP[$ONLY_CTID]:-}" ]] || { TGT_MAP[$ONLY_CTID]=$(( ONLY_CTID + OFFSET )); DEST_MAP[$ONLY_CTID]=$DEFAULT_DEST; }
  CTS=("$ONLY_CTID")
fi
if (( ! ${#CTS[@]} )); then
  # Already an error rather than a quiet exit 0, but say which of the two it is:
  # a missing file is a deployment mistake, an empty one is a choice.
  if [[ -f "$INV" ]]; then log "ERROR: $INV names no CT, and no --ctid was given - nothing to do"
  else                     log "ERROR: no inventory at $INV (and no --ctid) - NOTHING was run"
                           log "ERROR:   this is ct-replica's file, not ct-migrate's inventory-migrate.tsv"
  fi
  exit 2
fi

MODE=presync; (( FINAL )) && MODE=final; (( DRY )) && MODE="$MODE/dry-run"; (( LIST )) && MODE=list
hr
log "=== $(hostname) failback mode=$MODE bw=$BWLIMIT candidates: ${CTS[*]} ==="

_missing=()
for _c in pvesm zfs ssh rsync flock mount umount mountpoint e2fsck resize2fs truncate mktemp; do
  command -v "$_c" >/dev/null 2>&1 || _missing+=("$_c")
done
if (( ${#_missing[@]} )); then
  log "ERROR: required command(s) not found: ${_missing[*]} (PATH=$PATH) - NOTHING was run"; exit 2
fi


# ---------- B2, whole-run half: PAUSE must exist before any final delta -----
# The dry run checks this too. Every other DRY gate in this file skips a WRITE;
# this one used to skip the CHECK, which is the one thing a dry run must never
# do - it printed a clean plan for a run that was going to refuse, so the
# operator learned about the missing PAUSE from the real --final instead, in
# the cutover window. A dry run that cannot be trusted about tonight is worth
# less than no dry run at all. It reports and continues; only the real run
# stops.
if (( FINAL )) && [[ ! -f "$BASE/PAUSE" ]]; then
  if (( DRY )); then
    log "GUARD B2: DRY: --final would REFUSE - ct-replica is not paused ($BASE/PAUSE is missing)"
    log "GUARD B2:   the plan below is what would happen once you have run:  touch $BASE/PAUSE"
  else
    log "GUARD B2: --final without ct-replica paused - NOTHING was run"
    log "GUARD B2:   R2 only shields a copy while it RUNS. With the copies down, the next cron"
    log "GUARD B2:   tick (every 15 min) overwrites the DR data with the stale production images."
    log "GUARD B2:   fix, then run again:  touch $BASE/PAUSE"
    exit 2
  fi
fi

# ---------- who the backup node actually is ---------------------------------
# Same rule as ct-replica.sh: nobody types a pmxcfs name. /etc/pve/local is a
# symlink to nodes/<this node>, so it is the authoritative identity - safer
# than hostname, which can drift from it after a badly done rename. This engine
# uses the name to tell "a CT that lives on the backup node" (a copy, not a
# source) from a production CT, and getting that backwards points a restore at
# the wrong side of the transfer.
_bknode=$(ssh $SSH_OPT "$BKP_SSH" 'readlink /etc/pve/local 2>/dev/null | sed "s|.*/||"' \
          </dev/null 2>/dev/null | head -1)
if [[ -z "$_bknode" ]]; then
  log "ERROR: cannot read the PVE node identity of $BKP_SSH - NOTHING was run"
  log "ERROR:   every question this engine asks about a production CT goes through"
  log "ERROR:   that node, so there is nothing it can safely do without it."
  log "ERROR:   check: ssh $BKP_SSH 'readlink /etc/pve/local'"
  exit 2
fi
if [[ -z "$BKP_NODE" ]]; then
  BKP_NODE="$_bknode"
elif [[ "$_bknode" != "$BKP_NODE" ]]; then
  log "ERROR: BKP_NODE='$BKP_NODE' but $BKP_SSH is really node '$_bknode' - NOTHING was run"
  log "ERROR:   a copy would be mistaken for a production CT, or the other way round"
  log "ERROR:   fix BKP_NODE in $CONF (set it to '$_bknode', or remove the line)"
  exit 2
fi

# ---------- per-CT plumbing ----------
CUR_MNT=""
# CUR_MNT is cleared ONLY when the image is really down. It used to be cleared
# unconditionally, including on the umount-failure path - which quietly disarmed
# the B5 gate in the ENOSPC loop below, because that gate is "is CUR_MNT still
# set". truncate, e2fsck and resize2fs then ran against a mounted customer
# image and the run reported ok. This is ct-migrate's G3, relearned here.
cleanup_ct(){
  [[ -n "$CUR_MNT" ]] || return 0
  sync
  if mountpoint -q "$CUR_MNT" 2>/dev/null; then
    if ! umount "$CUR_MNT" >>"$LOG" 2>&1; then
      log "WARN: $CUR_MNT is STILL MOUNTED - do NOT start that CT until it is down"
      return 1                      # leaves CUR_MNT set: nothing may resize now
    fi
  fi
  CUR_MNT=""
  return 0
}
CT_LOCK=""
take_ct_lock(){   # keep two invocations off the same CT, same idea as R10
  exec 8>"$BASE/.failback-$1.lock" 2>/dev/null || return 1
  if flock -n 8; then CT_LOCK="$1"; return 0; fi
  exec 8>&-; return 1
}
release_ct_lock(){ [[ -n "$CT_LOCK" ]] || return 0; exec 8>&-; CT_LOCK=""; }
cleanup(){
  cleanup_ct; release_ct_lock
  for s in /run/ctback-$$-*.sock; do
    [[ -S "$s" ]] && ssh -O exit -o ControlPath="$s" x >/dev/null 2>&1
  done
}
trap cleanup EXIT

# resolve identity + both states for one CT; sets the CT_* globals.
# returns 1 when the CT cannot be resolved at all.
CT_TGT=""; CT_DEST=""; CT_NODE=""; CT_SID=""; CT_VOL=""; CT_IMG=""
CT_PSTAT=""; CT_CSTAT=""; CT_SRCDS=""
probe_ct(){
  local ct="$1" cfgpath srccfg
  CT_TGT="${TGT_MAP[$ct]}"; CT_DEST="${DEST_MAP[$ct]:-$DEFAULT_DEST}"
  CT_NODE=""; CT_SID=""; CT_VOL=""; CT_IMG=""; CT_PSTAT=""; CT_CSTAT=""
  CT_SRCDS="${DEST_DS[$CT_DEST]}/subvol-$CT_TGT-disk-0"
  cfgpath=$(ssh $SSH_OPT "$BKP_SSH" "ls /etc/pve/nodes/*/lxc/$ct.conf 2>/dev/null" </dev/null 2>/dev/null | head -1)
  [[ -n "$cfgpath" ]] || return 1
  CT_NODE="${cfgpath#/etc/pve/nodes/}"; CT_NODE="${CT_NODE%%/*}"
  [[ "$CT_NODE" != "$BKP_NODE" ]] || return 1
  srccfg=$(ssh $SSH_OPT "$BKP_SSH" "cat $cfgpath" </dev/null 2>/dev/null | sed '/^\[/,$d')
  CT_SID=$(printf '%s\n' "$srccfg" | sed -n 's/^rootfs:[[:space:]]*\([^:]*\):.*/\1/p' | head -1)
  CT_VOL=$(printf '%s\n' "$srccfg" | sed -n 's/^rootfs:[[:space:]]*[^:]*:\([^,]*\).*/\1/p' | head -1)
  [[ -n "$CT_SID" && -n "$CT_VOL" ]] || return 1
  CT_IMG=$(pvesm path "$CT_SID:$CT_VOL" 2>/dev/null) || CT_IMG=""
  CT_PSTAT=$(ssh $SSH_OPT "$BKP_SSH" "pvesh get /nodes/$CT_NODE/lxc/$ct/status/current --output-format yaml 2>/dev/null" </dev/null 2>/dev/null | awk '/^status:/ {print $2}')
  CT_CSTAT=$(ssh $SSH_OPT "$BKP_SSH" "pct status $CT_TGT 2>/dev/null" </dev/null 2>/dev/null | awk '{print $2}')
  return 0
}

run_back(){   # -> rsync rc; fills RS_*
  local sf rc t0 mnt="$1"
  sf=$(mktemp "${TMPDIR:-/tmp}/ctback-stats.XXXXXX" 2>/dev/null) || sf=""
  local opts=("${RS[@]}")
  [[ -n "$sf" ]] && opts+=(--stats "--log-file=$sf" '--log-file-format=')
  t0=$SECONDS
  if [ -t 1 ]; then
    rsync "${opts[@]}" --info=progress2 --no-inc-recursive "$BKP_SSH:$CT_SRCMNT/" "$mnt/"
  else
    rsync "${opts[@]}" "$BKP_SSH:$CT_SRCMNT/" "$mnt/" >>"$LOG" 2>&1
  fi
  rc=$?
  RS_SECS=$(( SECONDS - t0 )); RS_FILES=0; RS_LITERAL=0; RS_RECV=0
  if [[ -n "$sf" && -s "$sf" ]]; then
    RS_FILES=$(_rs_num 'Number of .*files transferred' "$sf")
    RS_LITERAL=$(_rs_num 'Literal data' "$sf")
    RS_RECV=$(_rs_num 'Total bytes received' "$sf")     # we are the receiver now
    local n; for n in RS_FILES RS_LITERAL RS_RECV; do [[ "${!n}" =~ ^[0-9]+$ ]] || printf -v "$n" 0; done
  fi
  [[ -n "$sf" ]] && rm -f "$sf"
  return $rc
}

# one CT, end to end. 0 = ok, 1 = failed, 2 = skipped by a guard.
failback_one(){
  local ct="$1" holder ds snap attempt cur new rc newsize
  local TGT="$CT_TGT" DEST="$CT_DEST"

  # --- B1 ---
  if [[ -z "$CT_PSTAT" ]]; then
    log "[$ct] GUARD B1: cannot reach $CT_NODE via cluster API to check the CT - 'unverified' is not 'stopped'"
    log "[$ct] GUARD B1:   writing into the image of a CT that turns out to be running corrupts"
    log "[$ct] GUARD B1:   the LIVE container. Ensure node $CT_NODE is online in the cluster, then run again."
    return 2
  fi
  if [[ "$CT_PSTAT" != "stopped" ]]; then
    log "[$ct] GUARD B1: production CT is '$CT_PSTAT' on $CT_NODE, must be stopped"
    log "[$ct] GUARD B1:   (Stop it via GUI, or run: ssh $BKP_SSH pvesh create /nodes/$CT_NODE/lxc/$ct/status/stop)"
    return 2
  fi
  # --- B2, per-CT half ---
  if (( FINAL )); then
    if [[ "$CT_CSTAT" != "stopped" ]]; then
      log "[$ct] GUARD B2: --final needs copy $TGT stopped (it is '${CT_CSTAT:-unknown}')"
      log "[$ct] GUARD B2:   ssh $BKP_SSH pct shutdown $TGT"
      return 2
    fi
  else
    if [[ "$CT_CSTAT" != "running" ]]; then
      log "[$ct] GUARD B2: presync expects copy $TGT RUNNING (it is '${CT_CSTAT:-unknown}')"
      log "[$ct] GUARD B2:   while it runs, ct-replica R2 skips it and it stays the newest data."
      log "[$ct] GUARD B2:   already stopped for cutover? use --final (with PAUSE in place)."
      st_write "$ct" skipped b2_copy_not_running -1
      return 2
    fi
  fi
  # --- B3 / B4 ---
  if [[ -z "$CT_IMG" || "$CT_IMG" != /*/images/* ]]; then
    log "[$ct] ERROR: storage '$CT_SID' unknown on THIS node, or not a dir storage (got '${CT_IMG:-none}')"
    st_write "$ct" failed storage_unknown -1
    return 1
  fi
  # B4 before B3, deliberately. findmnt -T on a path that does not exist exits
  # 1 with no output, which B3 reads as "the dataset is not mounted" - so a
  # missing image used to be reported as a mount problem and the operator was
  # sent to run `zfs mount -a` against a filesystem that was fine.
  if [[ ! -f "$CT_IMG" ]]; then
    log "[$ct] GUARD B4: no image at $CT_IMG"
    log "[$ct] GUARD B4:   this restores INTO an existing volume; a missing one is a rebuild,"
    log "[$ct] GUARD B4:   which is a different operation and not this tool's to guess at."
    st_write "$ct" failed b4_no_image -1
    return 1
  fi
  holder=$(findmnt -no TARGET -T "$CT_IMG" 2>/dev/null | head -1)
  if [[ -z "$holder" || "$holder" == "/" ]]; then
    log "[$ct] GUARD B3: $CT_IMG sits on the ROOT filesystem (holder: ${holder:-unresolvable})"
    log "[$ct] GUARD B3:   the backing dataset is not mounted - restoring now would fill the node root"
    log "[$ct] GUARD B3:   check: findmnt -T $CT_IMG ; zfs mount -a"
    st_write "$ct" failed b3_root_fs -1
    return 1
  fi
  CT_SRCMNT=$(ssh $SSH_OPT "$BKP_SSH" "zfs get -H -o value mountpoint $CT_SRCDS 2>/dev/null" </dev/null 2>/dev/null)
  if [[ -z "$CT_SRCMNT" || "$CT_SRCMNT" == "none" ]]; then
    log "[$ct] ERROR: cannot resolve the mountpoint of $CT_SRCDS on $BKP_NODE"
    st_write "$ct" failed src_mountpoint -1
    return 1
  fi

  # --- safety net, only before the first write of the final round ---
  if (( FINAL )) && (( ! DRY )); then
    ds=$(findmnt -no SOURCE -T "$CT_IMG" 2>/dev/null | head -1)
    if [[ -n "$ds" ]] && zfs list -H "$ds" >/dev/null 2>&1; then
      snap="$ds@ctback-$ct-$(date +%Y%m%d-%H%M%S)"
      if zfs snapshot "$snap" >>"$LOG" 2>&1; then
        log "[$ct] safety net: $snap"
        log "[$ct] safety net:   to recover the pre-failback image, COPY it out - do NOT roll the"
        log "[$ct] safety net:   dataset back, that reverts every other CT on it too:"
        log "[$ct] safety net:   ${holder}/.zfs/snapshot/${snap#*@}${CT_IMG#"$holder"}"
      elif (( NO_SNAPSHOT )); then
        log "[$ct] WARN: no undo point for this CT - --no-snapshot was given"
      else
        log "[$ct] GUARD B7: could not snapshot $ds - NOTHING was written for CT $ct"
        log "[$ct] GUARD B7:   --final overwrites the production image, and that snapshot"
        log "[$ct] GUARD B7:   is the only way back from it. Every other guard in this file"
        log "[$ct] GUARD B7:   refuses rather than warns; this one used to be the exception."
        log "[$ct] GUARD B7:   usually a full pool or a busy dataset: zpool list ; zfs list -t snapshot $ds"
        log "[$ct] GUARD B7:   fix it, or decide the risk is acceptable and say so:"
        log "[$ct] GUARD B7:     ./ct-failback.sh --ctid $ct --final --no-snapshot"
        st_write "$ct" failed no_undo_point -1
        return 1
      fi
    elif (( ! NO_SNAPSHOT )); then
      # Not on ZFS, so there is no snapshot to take and nothing to refuse - but
      # the operator should know they are working without an undo point.
      log "[$ct] NOTE: $CT_IMG is not on ZFS - no undo point is possible here"
    fi
  fi

  # --- B5: mount read-write, verified ---
  local MNT="$MNT_BASE/failback-$ct"
  mkdir -p "$MNT"
  if mountpoint -q "$MNT"; then
    umount "$MNT" >>"$LOG" 2>&1 || { log "[$ct] ERROR: stale mount at $MNT would not unmount"; return 1; }
  fi
  # A dry run mounts read-only. A real one cannot: this tool restores INTO the
  # image. Mounting ext4 read-write replays the journal and updates the
  # superblock, so the old unconditional `-o loop` made "dry-run - nothing was
  # written" false at the byte level, against a customer's production image, at
  # the one moment B1 has established nobody is watching it. ct-replica.sh has
  # mounted ro,noload since R6; this is that lesson carried across at last.
  # rsync -n only reads the destination, so the delta it reports is unchanged.
  MOPT=loop; (( DRY )) && MOPT=loop,ro,noload
  if ! mount -o "$MOPT" "$CT_IMG" "$MNT" >>"$LOG" 2>&1; then
    log "[$ct] ERROR: loop-mount failed ($CT_IMG)"
    st_write "$ct" failed loop_mount -1; return 1
  fi
  if ! mountpoint -q "$MNT"; then
    log "[$ct] GUARD B5: $MNT is not a mountpoint after mount - refusing to write into a plain directory"
    return 1
  fi
  CUR_MNT="$MNT"

  log "[$ct] RESTORE <= $BKP_SSH:$CT_SRCMNT/  =>  image $CT_IMG (copy $TGT, dest=$DEST)"
  run_back "$MNT"; rc=$?
  cleanup_ct

  # --- B6: ENOSPC -> grow, bounded, only ever on an unmounted image ---
  attempt=0
  while [[ $rc -eq 11 && $attempt -lt $GROW_MAX_RETRY ]] && (( ! DRY )); do
    if [[ -n "$CUR_MNT" ]]; then log "[$ct] GUARD B5: still mounted after ENOSPC - refusing to resize"; break; fi
    attempt=$(( attempt + 1 ))
    cur=$(stat -c%s "$CT_IMG"); new=$(( cur / 100 * (100 + GROW_PCT) ))
    log "[$ct] B6: out of space - grow $attempt/$GROW_MAX_RETRY: $(hsize "$cur") -> $(hsize "$new")"
    truncate -s "$new" "$CT_IMG" >>"$LOG" 2>&1
    e2fsck -fp "$CT_IMG"         >>"$LOG" 2>&1
    resize2fs "$CT_IMG"          >>"$LOG" 2>&1
    mount -o loop "$CT_IMG" "$MNT" >>"$LOG" 2>&1 || { log "[$ct] ERROR: remount failed during grow"; break; }
    mountpoint -q "$MNT" || { log "[$ct] GUARD B5: $MNT not a mountpoint after remount"; break; }
    CUR_MNT="$MNT"
    run_back "$MNT"; rc=$?
    cleanup_ct
  done
  if (( attempt )); then
    newsize="$(( ( $(stat -c%s "$CT_IMG") + 1073741823 ) / 1073741824 ))G"
    log "[$ct] NOTE: image grown to $newsize - the CT config still says the old size"
    log "[$ct] NOTE:   fix the rootfs line on $CT_NODE when convenient:"
    log "[$ct] NOTE:   rootfs: $CT_SID:$CT_VOL,size=$newsize"
  fi

  log "[$ct] stats: files=${RS_FILES:-0} changed=$(hsize "${RS_LITERAL:-0}") wire=$(hsize "${RS_RECV:-0}") time=${RS_SECS:-0}s"

  if (( DRY )); then log "[$ct] dry-run - nothing was written"; return 0; fi
  if [[ $rc -ne 0 && $rc -ne 24 ]]; then
    [[ $rc -eq 23 ]] && log "[$ct] HINT: rc=23 = some files on the copy could not be read; rerun, and if the SAME files fail twice, check the copy's dataset"
    log "[$ct] ERROR: restore FAILED (rsync rc=$rc) - do NOT start CT $ct"
    st_write "$ct" failed rsync "$rc"
    return 1
  fi
  log "[$ct] OK <= $TGT (rc=$rc)"
  st_write "$ct" ok "" "$rc"
  return 0
}

# ---------- list mode: read-only triage ----------
if (( LIST )); then
  printf '%-7s %-7s %-5s %-14s %-11s %-11s %s\n' CT COPY DEST PROD-NODE PROD COPY-STATE IMAGE | tee -a "$LOG"
  for ct in "${CTS[@]}"; do
    if ! probe_ct "$ct"; then
      printf '%-7s %-7s %-5s %-14s %-11s %-11s %s\n' \
        "$ct" "${TGT_MAP[$ct]}" "${DEST_MAP[$ct]:-?}" "?" "?" "?" "cannot resolve" | tee -a "$LOG"
      continue
    fi
    [[ -n "$ONLY_DEST" && "$CT_DEST" != "$ONLY_DEST" ]] && continue
    printf '%-7s %-7s %-5s %-14s %-11s %-11s %s\n' \
      "$ct" "$CT_TGT" "$CT_DEST" "$CT_NODE" "${CT_PSTAT:-unreachable}" "${CT_CSTAT:-unknown}" "${CT_IMG:-?}" | tee -a "$LOG"
    [[ -z "$CT_PSTAT" ]] && UNREACHABLE+=("$ct:$CT_NODE")
  done
  # This is the whole reason --list exists: to be run on an ordinary Tuesday,
  # not during the incident. B1 asks the production node whether the container
  # is stopped, and it asks over ssh, by the pmxcfs node NAME. This machine is
  # deliberately outside the cluster, so it gets neither /etc/hosts nor the
  # cluster's keys for free - and the day you find that out must not be the day
  # the copies are already serving customers.
  if (( ${#UNREACHABLE[@]} )); then
    log ""
    log "PROD unreachable for ${#UNREACHABLE[@]} CT - a failback would refuse at GUARD B1:"
    for u in "${UNREACHABLE[@]}"; do log "  CT ${u%%:*} lives on ${u#*:}"; done
    log "  this host needs root ssh to each of those nodes, BY NAME, before you need it:"
    for u in "${UNREACHABLE[@]}"; do log "    ssh -o BatchMode=yes root@${u#*:} true"; done
    log "  if that says 'could not resolve hostname', add the node to /etc/hosts here;"
    log "  if it asks for a password, ssh-copy-id root@<node> from here."
    exit 1
  fi
  exit 0
fi

# ---------- main loop ----------
RS=(-aHAX --numeric-ids --delete --inplace "--bwlimit=$BWLIMIT" --timeout=300
    '--exclude=/tmp/*' '--exclude=/run/*' '--exclude=/var/tmp/systemd-private-*'
    -e "ssh $SSH_DATA")
(( DRY )) && RS+=(-n)

ok=0; skipped=0; failed=0; matched=0; FAILED_IDS=(); DONE_IDS=()
for ct in "${CTS[@]}"; do
  cleanup_ct; release_ct_lock
  # One rule per container, at the top of its block. A disaster runs --all
  # over twenty CTs and every per-CT guard SKIPS rather than stopping the
  # batch, so the log is long and the reader is hunting for the two that
  # did not come back.
  hr
  if ! take_ct_lock "$ct"; then
    log "[$ct] NOTE: another failback owns this CT right now - skip"
    skipped=$(( skipped + 1 )); continue
  fi
  if ! probe_ct "$ct"; then
    log "[$ct] ERROR: cannot resolve this CT in the cluster (wrong id, or it lives on $BKP_NODE) - skip"
    # The copy id is the number on the screen during a DR, so it is the number
    # that gets typed. Say which one this tool wants instead of making somebody
    # work it out at 3am.
    for _s in "${!TGT_MAP[@]}"; do
      [[ "${TGT_MAP[$_s]}" == "$ct" ]] || continue
      log "[$ct] ERROR:   $ct is the COPY of CT $_s. This tool is driven by the SOURCE id:"
      log "[$ct] ERROR:     ./$(basename "${BASH_SOURCE[0]}") --ctid $_s${FINAL:+ --final}"
      break
    done
    failed=$(( failed + 1 )); FAILED_IDS+=("$ct"); continue
  fi
  if [[ -n "$ONLY_DEST" && "$CT_DEST" != "$ONLY_DEST" ]]; then continue; fi
  matched=$(( matched + 1 ))
  failback_one "$ct"; r=$?
  case $r in
    0) ok=$(( ok + 1 )); DONE_IDS+=("$ct");;
    2) skipped=$(( skipped + 1 ));;
    *) failed=$(( failed + 1 )); FAILED_IDS+=("$ct");;
  esac
done
cleanup_ct; release_ct_lock

hr
log "=== failback finished: ok=$ok skipped=$skipped failed=$failed ==="
(( failed )) && log "NEEDS ATTENTION -> CT: ${FAILED_IDS[*]}"

# A --dest nobody uses matches nothing, does nothing and would exit 0 - which
# during a failback reads as "all done". Say it instead.
if (( matched == 0 )) && [[ -n "$ONLY_DEST" ]]; then
  log "ERROR: no CT in $INV has dest '$ONLY_DEST' - nothing was failed back"
  exit 1
fi

if (( DRY )); then
  log "dry-run only - nothing was written"
elif (( FINAL )) && (( ok )); then
  log "next, by hand, for: ${DONE_IDS[*]}"
  log "  1) start each production CT:   ssh root@<its node> pct start <ctid>"
  log "  2) put each copy's network back on the mock bridge (ct-replica R11 nags until you do)"
  log "  3) rm $BASE/PAUSE"
  log "  4) $BASE/ct-replica.sh          # first round back, must end failed=0"
elif (( ok )); then
  log "presync done. run it again until 'changed=' stops shrinking, then cut over:"
  log "  1) touch $BASE/PAUSE"
  log "  2) shut down each copy:  ssh $BKP_SSH pct shutdown <copy id>"
  _again="$0"
  [[ -n "$ONLY_CTID" ]] && _again="$_again --ctid $ONLY_CTID"
  (( ALL ))             && _again="$_again --all"
  [[ -n "$ONLY_DEST" ]] && _again="$_again --dest $ONLY_DEST"
  log "  3) $_again --final"
fi

(( failed || skipped )) && exit 1
exit 0
