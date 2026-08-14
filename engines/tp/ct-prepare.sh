#!/usr/bin/env bash
# =============================================================================
#  ct-prepare.sh  —  DISASTER ONLY. Get a production container out of the way
#                    so its DR copy can take over, and put it back afterwards.
#                    Moves no customer data. Run it from the storage node or
#                    the backup node.
# -----------------------------------------------------------------------------
#  Everything this engine does used to be a line printed for a human to type.
#  At four containers that was a runbook. At two hundred it is seven hours of
#  typing at four in the morning, and the person doing it gets one of them
#  wrong. So it is a command now - but the thing that makes it safe is not that
#  it is faster, it is that it refuses unless it can PROVE the container it is
#  about to touch is one whose disk has already gone.
#
#      isolate   move every net line of a production container onto
#                MOCKNET_BRIDGE, which has no uplink, so it cannot answer.
#                Writes to /etc/pve and hotplugs live: it needs nothing at all
#                from the storage that died, which is the whole point. What it
#                CHANGED is written down, because the operator's own bridge
#                names are about to be overwritten and nothing else records
#                them.
#
#      restore   put those bridges back, and onboot with them, from that
#                record. Then delete it, because a record that outlives the
#                thing it describes is the next incident's wrong answer.
#
#      evacuate  the same disaster, taken a node at a time: disable the dead
#                storage, force its mount to fail, restart pvestatd, and only
#                THEN stop the containers that were on it. That order is the
#                whole trick - see the guards below. Whatever will not stop
#                gets isolated instead. `--restore --node` switches the
#                storages back on afterwards, from what this wrote down.
#
#  usage:
#    ct-prepare.sh --list                    what each container's state is
#    ct-prepare.sh --isolate --all           every container in the inventory
#    ct-prepare.sh --isolate --ctid 300      one container
#    ct-prepare.sh --restore --ctid 300      put 300's network back
#    ct-prepare.sh --isolate --all --dry-run every guard runs, nothing written
#    ct-prepare.sh --evacuate --node 10.0.0.1  one node: disable, unmount, stop
#    ct-prepare.sh --evacuate --all            every node holding an inventory CT
#    ct-prepare.sh --restore --node 10.0.0.1   switch those storages back on
#
#  exit code: 0 = all ok, 1 = at least one container failed or was skipped,
#             2 = refused before touching anything.
#
#  FLAGS EVERY ENGINE TAKES, spelled the same way on purpose:
#    --all               every row in the inventory
#    --ctid <id>         one container only
#    --node <ip>         one machine only - the scope --evacuate takes
#    --dry-run           run every guard, write nothing, print the plan
#    -h | --help         this header
#  A filter that matches no row exits NON-ZERO: under cron, exit 0 with no work
#  done looks exactly like a healthy night.
# -----------------------------------------------------------------------------
#  WHY ISOLATING IS NOT THE SAME AS STOPPING
#
#  What D1 in ct-distribute.sh defends is one ADDRESS, not one process. The DR
#  copy carries the production container's IP and MAC deliberately - that is
#  what makes it a replacement rather than a new machine - so the thing that
#  must never happen is two of them answering at once. A container whose every
#  veth is enslaved to a bridge with no uplink cannot answer, and D1 accepts
#  that.
#
#  It is still RUNNING, though, and that costs something: its I/O is blocked
#  now because its storage is gone, and the instant that storage comes back it
#  resumes writing into an image the fleet has moved on from. So isolating is
#  the second choice. Stopping is better and `--evacuate` gets there by freeing
#  the blocked I/O first; this exists for the container that will not stop even
#  then, and for the operator who wants the network gone before anything else.
#  ct-failback's B1 refuses to write into the production image while the
#  container is up, isolated or not, so the debt cannot be forgotten silently.
# -----------------------------------------------------------------------------
#  THE GUARDS (P1..P6). This engine writes to a live container's config, so
#  every one of them refuses rather than warns.
#
#   P1  the production container must exist and its node must ANSWER. A node
#       that did not reply is not a node whose container is safe to change -
#       the same rule as D1's "unreachable is not stopped".
#
#   P2  its rootfs storage must be PROVABLY DEAD. This is the guard the whole
#       engine hangs off. `ketsync distribute` was run against a healthy fleet
#       on the afternoon this was written; had it isolated on sight, it would
#       have cut two live customers off their network from one command.
#
#       The proof is not an inference from "I cannot reach the storage node".
#       It is a `stat` on that storage's own mountpoint, on the node that
#       mounts it, with a timeout - and a HANG is the positive result. A live
#       NFS mount answers instantly; one whose server is gone blocks in the
#       kernel until the timeout kills it. A mountpoint that is not there any
#       more counts too: something already unmounted it.
#
#       A storage that answers is a hard refusal, and it is not overridable.
#
#   P3  the container must be RUNNING. A stopped one has nothing to isolate,
#       and its config still holds the operator's real bridge names - rewriting
#       those would destroy the only copy of them for no gain at all.
#
#   P4  MOCKNET_BRIDGE must exist on that node and have no uplink. Same probe,
#       same bridge, same reason as ct-replica R9 and ct-distribute D1: a
#       bridge with a physical port on it is not an isolated bridge, it is a
#       second customer bridge with a confusing name.
#
#   P5  there must be no record already. A second isolate would write vmbr99
#       down as the bridge to go back to, and the real one would be gone for
#       good - from every machine, permanently, with nothing to reconstruct it
#       from. This is the guard that protects the record itself.
#
#   P6  the KERNEL has to agree afterwards. `pct set` writing a config is not
#       the same as PVE applying it to a running container, and this engine
#       claims to have taken something off the network. So it re-reads the
#       master of every veth and refuses to report success until they have all
#       moved.
#
#  Nothing here starts, creates or destroys a container, ever. `--evacuate` is
#  the one mode that stops one, and it is separate for a reason: everything
#  else here is safe to point at a container that is serving customers, in the
#  sense that it will refuse. That one changes a whole machine.
#
#  The evacuate guards are E1..E5 and they are documented where they run.
# -----------------------------------------------------------------------------
#  WHERE THE RECORD LIVES, AND WHY NOT IN THE CONFIG
#
#      /etc/pve/ketsync/isolate/<ctid>.tsv     written on the container's node
#
#  pmxcfs, so every member of the cluster sees the same bytes and a reboot
#  cannot lose them. One directory per kind of record and the file named only
#  by the id, so `ls` of that directory IS the list of containers this tool has
#  taken off the wire - which is the question doctor asks, and the question an
#  operator asks at the end of a DR. Two hundred containers in one flat folder
#  with a prefix in each name is a folder nobody reads.
#
#  Not the guest's description field, which was the first idea: PVE owns that
#  field, re-encodes it on every write, and it is where the operator keeps their
#  own notes. A tool that round-trips somebody's notes through a parser will
#  eventually eat them.
#
#  One key per line, tab separated, `grep`-readable - CLAUDE.md rule 6, the
#  same reason the state files are. Deleting the file is how the debt clears,
#  which is the same self-clearing shape as ct-distribute's 9<id> config: there
#  is no timestamp anybody has to reason about, only a file that is there or is
#  not.
# =============================================================================
set -uo pipefail

# cron hands a script PATH=/usr/bin:/bin, and pvesm and zfs live in sbin. Same
# reason as every other engine here - see CLAUDE.md rule 8.
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="$BASE/ctrep.conf"
INV="$BASE/inventory-replica.tsv"
# ketsync's node map, read where ketsync KEEPS it rather than from a copy - the
# same walk-up, checked the same way, as every other engine here.
NODEMAP="$BASE/nodes.map"
if [[ -f "$BASE/../../ketsync" && -f "$BASE/../../lib/common.sh" && -f "$BASE/../../nodes.map" ]]; then
  NODEMAP="$(cd "$BASE/../.." && pwd)/nodes.map"
fi

# ---------- defaults; ctrep.conf wins ----------------------------------------
BKP_SSH="root@100.100.100.35"
MOCKNET_BRIDGE=vmbr99            # the isolated bridge. Same knob, same file,
                                 # as ct-replica R9 and ct-distribute D1
SHUTDOWN_TIMEOUT=90              # seconds to wait for one container to come
                                 # down before falling back to isolating it. At
                                 # two hundred containers, waiting the PVE
                                 # default each time is a night
STAT_TIMEOUT=5                   # seconds to wait for a storage to answer. A
                                 # live mount answers in microseconds; this is
                                 # not a tuning knob, it is the difference
                                 # between "answered" and "blocked forever"
LOG_KEEP_DAYS=14                 # same knob, same ctrep.conf, as ct-replica.sh
SSH_CIPHERS=aes128-gcm@openssh.com,aes256-gcm@openssh.com,aes128-ctr
# -------------------------------------------------------------------------

ONLY_CTID=""; ONLY_NODE=""; ALL=0; LIST=0; DRY=0; ISOLATE=0; RESTORE=0; EVACUATE=0
while (( $# )); do
  case "$1" in
    --ctid)    [[ $# -ge 2 ]] || { echo "--ctid needs a value" >&2; exit 2; }
               ONLY_CTID="$2"; shift 2;;
    --node)    [[ $# -ge 2 ]] || { echo "--node needs a value" >&2; exit 2; }
               ONLY_NODE="$2"; shift 2;;
    --all)     ALL=1; shift;;
    --list)    LIST=1; shift;;
    --isolate) ISOLATE=1; shift;;
    --restore) RESTORE=1; shift;;
    --evacuate) EVACUATE=1; shift;;
    --dry-run) DRY=1; shift;;
    -h|--help) awk 'NR>1{ if (/^#/) { sub(/^#[ ]?/,""); print } else exit }' "${BASH_SOURCE[0]}"; exit 0;;
    *) echo "unknown argument: $1" >&2; exit 2;;
  esac
done
if (( ISOLATE && RESTORE )); then
  echo "--isolate and --restore are opposite directions - pick one" >&2; exit 2
fi
if (( EVACUATE && (ISOLATE || RESTORE) )); then
  echo "--evacuate already isolates what it cannot stop - do not ask for both" >&2; exit 2
fi
if (( ! LIST && ! ISOLATE && ! RESTORE && ! EVACUATE )); then
  echo "usage: ct-prepare.sh --list | --isolate | --restore | --evacuate" >&2
  echo "       [--all | --ctid <production_ctid> | --node <ip>] [--dry-run]" >&2
  exit 2
fi
if (( EVACUATE )) && (( ! ALL )) && [[ -z "$ONLY_NODE" ]]; then
  echo "usage: ct-prepare.sh --evacuate --node <ip> | --all" >&2
  echo "       evacuating is per NODE: it disables a storage and unmounts it," >&2
  echo "       which every container on that node feels. Name the machine." >&2
  exit 2
fi
# A container verb needs a container scope. --node is a scope too, and it is
# the only one --evacuate takes, so naming a machine counts as having said
# which work to do.
if (( ! LIST )) && (( ! ALL )) && [[ ! "$ONLY_CTID" =~ ^[0-9]+$ ]] && [[ -z "$ONLY_NODE" ]]; then
  echo "usage: ct-prepare.sh --isolate|--restore --all | --ctid <production_ctid>" >&2
  echo "       ct-prepare.sh --evacuate|--restore --node <ip>" >&2
  exit 2
fi

if [[ -f "$CONF" ]]; then
  # shellcheck source=/dev/null
  . "$CONF" || { echo "failed to read $CONF" >&2; exit 2; }
fi
for _v in STAT_TIMEOUT SHUTDOWN_TIMEOUT LOG_KEEP_DAYS; do
  [[ "${!_v}" =~ ^[0-9]+$ ]] || { echo "$CONF: $_v must be a plain integer, got '${!_v}'" >&2; exit 2; }
done
(( STAT_TIMEOUT >= 1 )) || { echo "$CONF: STAT_TIMEOUT must be at least 1 second" >&2; exit 2; }
if [[ ! "$MOCKNET_BRIDGE" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "ctrep.conf: MOCKNET_BRIDGE='$MOCKNET_BRIDGE' is not a plain interface name" >&2; exit 2
fi

# ---------- the tools this needs, checked BEFORE the lock --------------------
# CLAUDE.md rule 8, and the order is the point: `flock` missing is
# command-not-found, which is a non-zero exit, which is indistinguishable from
# "somebody else holds the lock" - so the engine would say it is skipping and
# return 0 having done nothing.
_missing=()
for _c in ssh flock awk sed date hostname; do
  command -v "$_c" >/dev/null 2>&1 || _missing+=("$_c")
done
if (( ${#_missing[@]} )); then
  echo "missing required commands: ${_missing[*]}" >&2
  echo "  nothing was run. A missing tool must not read as a healthy skip." >&2
  exit 2
fi

# ---------- where the log goes ----------
LOGDIR="$BASE/logs"
if [[ -f "$BASE/../../ketsync" && -f "$BASE/../../lib/common.sh" ]]; then
  LOGDIR="$(cd "$BASE/../.." && pwd)/logs"
fi
mkdir -p "$LOGDIR" "$BASE/state" 2>/dev/null
LOG="$LOGDIR/prepare-$(date +%F).log"
if (( LOG_KEEP_DAYS > 0 )); then
  find "$LOGDIR" -maxdepth 1 -type f -name 'prepare-*.log' \
       -mtime +"$LOG_KEEP_DAYS" -delete 2>/dev/null || true
fi
log(){ printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG"; }
LOGSEP='##############################################################################'
LOGSEP2='=============================================================================='
LOGSEP3='------------------------------------------------------------------------------'
hr(){  printf '%s\n' "$LOGSEP"  | tee -a "$LOG"; }
hr2(){ printf '%s\n' "$LOGSEP2" | tee -a "$LOG"; }
hr3(){ printf '%s\n' "$LOGSEP3" | tee -a "$LOG"; }
HR_CT_SEEN=0
hr_ct(){ if (( HR_CT_SEEN )); then hr3; else hr2; HR_CT_SEEN=1; fi; }

MODE=list
(( ISOLATE ))  && MODE=isolate
(( RESTORE ))  && MODE=restore
(( EVACUATE )) && MODE=evacuate
(( DRY ))     && MODE="$MODE/dry-run"

SSH_COMMON="-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o ServerAliveInterval=15 -c $SSH_CIPHERS"
SSH_OPT="$SSH_COMMON -o ControlMaster=auto -o ControlPath=/run/ctprep-$$-%r@%h.sock -o ControlPersist=120"

node_ip(){ awk -v n="$1" '$1!~/^#/ && $2==n{print $1; exit}' "$NODEMAP" 2>/dev/null; }
rsh(){ ssh $SSH_OPT "root@$1" "${@:2}" </dev/null 2>/dev/null; }

# The bridge named by one net line. Split on commas and take the field, rather
# than matching bridge=vmbr99 inside a string - which also matches vmbr990, and
# the whole point of the checks that use this is that they are exact.
net_bridge(){ printf '%s' "$1" | tr ',' '\n' | sed -n 's/^bridge=//p' | head -1; }

# ---------- the CT list -----------------------------------------------------
# ct-replica's inventory, because a container this engine prepares is by
# definition one that has a DR copy to hand over to.
#
# Unlike ct-replica and ct-distribute this does NOT require each row to name a
# dest. It never reads one: a row with no pool cannot make this engine touch
# the wrong machine, and refusing a DR because of a bookkeeping field that has
# nothing to do with what is about to happen would be a refusal for the wrong
# reason at the worst possible time. Duplicate ids ARE refused, because two
# rows for one container means one of them is a typo and this engine cannot
# tell which.
declare -a CTS=()
if [[ ! -f "$INV" ]]; then
  log "ERROR: no inventory at $INV - NOTHING was run"
  log "ERROR:   this is ct-replica's file, not ct-migrate's inventory-migrate.tsv"
  log "ERROR:   start from the sample:  cp $BASE/inventory-replica.sample.tsv $INV"
  exit 2
fi
declare -a INV_ERRS=(); declare -A SEEN_CT=(); ln=0
while IFS= read -r line || [[ -n "${line:-}" ]]; do
  ln=$(( ln + 1 ))
  line="${line%%#*}"
  [[ -z "${line// /}" ]] && continue
  read -r -a f <<<"$line"
  [[ "${f[0]}" =~ ^[0-9]+$ ]] || { INV_ERRS+=("line $ln: '${f[0]}' is not a container id"); continue; }
  if [[ -n "${SEEN_CT[${f[0]}]:-}" ]]; then
    INV_ERRS+=("line $ln: container ${f[0]} appears twice"); continue
  fi
  SEEN_CT[${f[0]}]=1
  CTS+=("${f[0]}")
done < "$INV"
if (( ${#INV_ERRS[@]} )); then
  log "ERROR: $(basename "$INV") is not usable - NOTHING was run"
  for _e in "${INV_ERRS[@]}"; do log "ERROR:   $_e"; done
  exit 2
fi
if [[ -n "$ONLY_CTID" ]]; then
  declare -a keep=()
  for _c in "${CTS[@]}"; do [[ "$_c" == "$ONLY_CTID" ]] && keep+=("$_c"); done
  CTS=("${keep[@]}")
  if (( ${#CTS[@]} == 0 )); then
    log "ERROR: CT $ONLY_CTID has no row in $(basename "$INV") - nothing was done"
    log "ERROR:   this engine prepares containers that have a DR copy to hand over to,"
    log "ERROR:   and that list is the inventory. Add the row, or check the number."
    exit 2
  fi
fi
if (( ${#CTS[@]} == 0 )); then
  log "ERROR: $(basename "$INV") has no container rows at all - nothing was done"
  exit 2
fi

# ---------- one prepare at a time on this machine ----------------------------
RUN_LOCK=""
exec 9>"$BASE/.prepare.lock" 2>/dev/null || true
if ! flock -n 9; then
  log "another prepare is already running - skip"
  exit 0
fi
RUN_LOCK=1

cleanup(){
  local s
  for s in /run/ctprep-$$-*.sock; do
    [[ -S "$s" ]] && ssh -O exit -o ControlPath="$s" x >/dev/null 2>&1
  done
  [[ -n "$RUN_LOCK" ]] && exec 9>&-
  return 0
}
trap cleanup EXIT INT TERM

# ---------- the record ------------------------------------------------------
REC_DIR=/etc/pve/ketsync/isolate
rec_path(){ printf '%s/%s.tsv' "$REC_DIR" "$1"; }

# Read it back as "key<TAB>value" lines. Empty output means there is no record,
# which is a different thing from a record that says nothing - the caller
# checks for the ctid key rather than for non-empty output, so a truncated file
# cannot read as a valid one.
rec_read(){ rsh "$1" "cat '$(rec_path "$2")' 2>/dev/null"; }
rec_field(){ awk -F'\t' -v k="$2" '$1==k{print $2; exit}' <<<"$1"; }

# ---------- the probe, one remote call --------------------------------------
# Everything about a container's network read in one round trip, because at two
# hundred containers the round trips are the run.
#
#   NETS <n>              how many net lines its config declares
#   NETLINE <netN> <line> each one, verbatim, so a bridge can be put back
#   VETH <if> <bridge>    what the KERNEL has, which is the one that cannot lie
#   ONBOOT <0|1>
#   STATUS <word>
#   ROOTSID <storage-id>  where its rootfs lives
#   STATRC <rc>           124 = the storage blocked until the timeout: dead
#   BRMISSING             MOCKNET_BRIDGE is not on this node
#   UPLINK <port>         MOCKNET_BRIDGE has a physical port on it
#   OK                    the probe ran to the end
probe(){   # $1 = ip, $2 = ctid
  local ip="$1" ct="$2"
  rsh "$ip" "
    cfg=\$(pct config $ct 2>/dev/null)
    [ -n \"\$cfg\" ] || { echo NOCONFIG; exit 0; }
    echo \"STATUS \$(pct status $ct 2>/dev/null | awk '{print \$2}')\"
    echo \"ONBOOT \$(printf '%s\n' \"\$cfg\" | sed -n 's/^onboot:[[:space:]]*//p' | head -1)\"
    echo \"NETS \$(printf '%s\n' \"\$cfg\" | grep -c '^net[0-9]')\"
    printf '%s\n' \"\$cfg\" | sed -n 's/^\\(net[0-9][0-9]*\\): \\(.*\\)/NETLINE \\1 \\2/p'
    sid=\$(printf '%s\n' \"\$cfg\" | sed -n 's/^rootfs:[[:space:]]*\\([^:,]*\\):.*/\\1/p' | head -1)
    echo \"ROOTSID \$sid\"
    p=\$(sed -n \"/^[a-z]*: \$sid\$/,/^\$/p\" /etc/pve/storage.cfg 2>/dev/null | sed -n 's/^[[:space:]]*path[[:space:]]\\{1,\\}//p' | head -1)
    [ -n \"\$p\" ] && echo \"ROOTPATH \$p\" || { p=/mnt/pve/\$sid; echo \"ROOTPATH \$p\"; }
    timeout $STAT_TIMEOUT stat -t \"\$p/.\" >/dev/null 2>&1
    echo \"STATRC \$?\"
    echo \"DSTATE \$(ps -eo stat= 2>/dev/null | grep -c '^D')\"
    for i in /sys/class/net/veth${ct}i*; do
      [ -e \"\$i\" ] || continue
      m=\$(readlink -f \"\$i/master\" 2>/dev/null)
      echo \"VETH \$(basename \$i) \${m##*/}\"
    done
    ip -br link show $MOCKNET_BRIDGE >/dev/null 2>&1 || { echo BRMISSING; exit 0; }
    ports=\$(ovs-vsctl list-ports $MOCKNET_BRIDGE 2>/dev/null || ls /sys/class/net/$MOCKNET_BRIDGE/brif/ 2>/dev/null)
    for p in \$ports; do
      if [ -e /sys/class/net/\$p/device ] || [ -d /sys/class/net/\$p/bonding ]; then echo \"UPLINK \$p\"; fi
    done
    echo OK
  "
}

# ---------- counters --------------------------------------------------------
ok=0; failed=0; skipped=0
declare -a OK_IDS=() FAILED_IDS=() SKIPPED_IDS=()
st_ok(){   ok=$(( ok + 1 ));           OK_IDS+=("$1"); }
st_fail(){ failed=$(( failed + 1 ));   FAILED_IDS+=("$1"); }
st_skip(){ skipped=$(( skipped + 1 )); SKIPPED_IDS+=("$1"); }

# Where a container's node is, from the cluster's own directory rather than
# from anything typed. Empty means no config anywhere, which is its own answer.
prod_node(){   # $1 = ctid -> "node<TAB>ip", empty if it is nowhere
  local n ip
  n=$(rsh "${BKP_SSH#*@}" "ls /etc/pve/nodes/*/lxc/$1.conf 2>/dev/null" | head -1)
  n="${n#/etc/pve/nodes/}"; n="${n%%/*}"
  [[ -n "$n" ]] || return 0
  ip="$(node_ip "$n")"; ip="${ip:-$n}"
  printf '%s\t%s\n' "$n" "$ip"
}

# ---------- P2, on its own because it is the guard everything hangs off ------
# rc 124 is `timeout` killing a `stat` that never returned, which is what a
# mount whose server has gone does. rc 0 is a storage that answered - alive,
# and a hard refusal. Anything else is a mountpoint that is not there, which
# means something already unmounted it, which is also not alive.
storage_verdict(){   # $1 = STATRC -> dead | alive | gone
  case "${1:-}" in
    124) printf 'dead';;
    0)   printf 'alive';;
    *)   printf 'gone';;
  esac
}

do_isolate(){   # $1 = ctid
  local ct="$1" pn pip out st nets rec _k _if _br _n _line _iso_bad="" _moved=""
  pn="$(prod_node "$ct")"
  if [[ -z "$pn" ]]; then
    log "[$ct] GUARD P1: CT $ct has no config anywhere in the cluster - nothing to isolate"
    st_skip "$ct"; return 1
  fi
  pip="${pn#*	}"; pn="${pn%%	*}"

  out="$(probe "$pip" "$ct")"
  if [[ -z "$out" ]]; then
    log "[$ct] GUARD P1: $pn ($pip) did not answer - NOT changing its network"
    log "[$ct] GUARD P1:   a node that cannot be asked is a node whose container cannot be"
    log "[$ct] GUARD P1:   verified. Same rule as D1: unreachable is not stopped."
    st_fail "$ct"; return 1
  fi
  if [[ "$out" == *NOCONFIG* ]]; then
    log "[$ct] GUARD P1: $pn says it has no config for CT $ct - the cluster directory disagrees"
    log "[$ct] GUARD P1:   nothing here writes into that disagreement."
    st_fail "$ct"; return 1
  fi

  st="$(awk '$1=="STATUS"{print $2; exit}' <<<"$out")"
  local sid path statrc verdict dstate
  sid="$(awk '$1=="ROOTSID"{print $2; exit}' <<<"$out")"
  path="$(awk '$1=="ROOTPATH"{print $2; exit}' <<<"$out")"
  statrc="$(awk '$1=="STATRC"{print $2; exit}' <<<"$out")"
  dstate="$(awk '$1=="DSTATE"{print $2; exit}' <<<"$out")"
  verdict="$(storage_verdict "$statrc")"

  # ---- GUARD P2: the storage must be provably dead ------------------------
  if [[ "$verdict" == alive ]]; then
    log "[$ct] GUARD P2: storage '$sid' on $pn ANSWERED - refusing to touch this container"
    log "[$ct] GUARD P2:   $path replied in under ${STAT_TIMEOUT}s, so the container's disk is"
    log "[$ct] GUARD P2:   fine and it is very likely serving customers right now. Moving its"
    log "[$ct] GUARD P2:   network onto $MOCKNET_BRIDGE would take it off the air by hand."
    log "[$ct] GUARD P2:   this refusal has no override. If the storage is dead and this says"
    log "[$ct] GUARD P2:   otherwise, that is a bug in the check, not a reason to skip it."
    st_skip "$ct"; return 1
  fi
  log "[$ct] P2: storage '$sid' is $verdict ($path, stat rc=$statrc, $dstate procs in D state)"

  # ---- GUARD P3: a stopped container has nothing to isolate ---------------
  if [[ "$st" != running ]]; then
    log "[$ct] GUARD P3: CT $ct is ${st:-<unknown>}, not running - nothing to take off the network"
    log "[$ct] GUARD P3:   and its config still holds the real bridge names. Rewriting those"
    log "[$ct] GUARD P3:   would destroy the only copy of them and buy nothing."
    st_skip "$ct"; return 1
  fi

  # ---- GUARD P4: the isolated bridge has to actually isolate --------------
  if [[ "$out" == *BRMISSING* ]]; then
    log "[$ct] GUARD P4: $MOCKNET_BRIDGE does not exist on $pn ($pip)"
    log "[$ct] GUARD P4:   moving a net line onto a bridge that is not there leaves the veth"
    log "[$ct] GUARD P4:   attached to nothing on THIS node, and says nothing about whether the"
    log "[$ct] GUARD P4:   container is off the customer's network. Create it first - a Linux"
    log "[$ct] GUARD P4:   bridge with bridge-ports none is enough - see the setup guide."
    st_fail "$ct"; return 1
  fi
  if [[ "$out" == *UPLINK* ]]; then
    log "[$ct] GUARD P4: $MOCKNET_BRIDGE on $pn HAS AN UPLINK - it does not isolate anything"
    printf '%s\n' "$out" | awk '$1=="UPLINK"{print $2}' | while read -r _p; do
      log "[$ct] GUARD P4:   port '$_p' reaches a wire"
    done
    log "[$ct] GUARD P4:   R9 asks the backup node the same question about the same bridge."
    st_fail "$ct"; return 1
  fi
  if [[ "$out" != *OK* ]]; then
    log "[$ct] GUARD P4: could not finish reading $pn's network - nothing was changed"
    st_fail "$ct"; return 1
  fi

  # ---- GUARD P5: never overwrite the record -------------------------------
  rec="$(rec_read "$pip" "$ct")"
  if [[ -n "$(rec_field "$rec" ctid)" ]]; then
    log "[$ct] GUARD P5: CT $ct is already isolated - $(rec_path "$ct") exists"
    log "[$ct] GUARD P5:   isolating twice would write $MOCKNET_BRIDGE down as the bridge to"
    log "[$ct] GUARD P5:   go back to, and the real one would be gone from every machine with"
    log "[$ct] GUARD P5:   nothing left to reconstruct it from."
    log "[$ct] GUARD P5:   it says:"
    printf '%s\n' "$rec" | while IFS= read -r _l; do [[ -n "$_l" ]] && log "[$ct] GUARD P5:     $_l"; done
    log "[$ct] GUARD P5:   to undo it:  ct-prepare.sh --restore --ctid $ct"
    st_skip "$ct"; return 1
  fi

  nets="$(awk '$1=="NETS"{print $2; exit}' <<<"$out")"
  if [[ ! "${nets:-0}" =~ ^[0-9]+$ ]] || (( nets == 0 )); then
    log "[$ct] GUARD P3: CT $ct has no net lines at all - it is already on no network"
    st_skip "$ct"; return 1
  fi

  # What is about to change, said before it changes. The net lines come from
  # the config; the bridge each veth is REALLY on comes from the kernel, and
  # the record keeps the config's, because that is what `pct set` will want
  # back.
  declare -a NETIDS=() NETBRS=() NETLINES=()
  while read -r _k _if _line; do
    [[ "$_k" == NETLINE ]] || continue
    NETIDS+=("$_if"); NETBRS+=("$(net_bridge "$_line")"); NETLINES+=("$_line")
    log "[$ct] isolate: $_if is on $(net_bridge "$_line") -> $MOCKNET_BRIDGE"
  done <<< "$out"
  if (( ${#NETIDS[@]} != nets )); then
    log "[$ct] GUARD P3: config says $nets net lines but only ${#NETIDS[@]} could be read"
    log "[$ct] GUARD P3:   moving some of them is worse than moving none: the one left behind"
    log "[$ct] GUARD P3:   is the one that answers."
    st_fail "$ct"; return 1
  fi
  for _br in "${NETBRS[@]}"; do
    [[ "$_br" == "$MOCKNET_BRIDGE" ]] && _iso_bad="$_iso_bad $_br"
  done
  if [[ -n "$_iso_bad" ]]; then
    log "[$ct] GUARD P5: one of CT $ct's net lines is already on $MOCKNET_BRIDGE, with no record"
    log "[$ct] GUARD P5:   somebody moved it by hand. This engine cannot write down a bridge"
    log "[$ct] GUARD P5:   nobody remembers, so it will not pretend to: move it back to the"
    log "[$ct] GUARD P5:   real bridge first, then let this do the whole container at once."
    st_skip "$ct"; return 1
  fi

  local ob; ob="$(awk '$1=="ONBOOT"{print $2; exit}' <<<"$out")"
  if (( DRY )); then
    log "[$ct] DRY: would write $(rec_path "$ct") on $pn (onboot=${ob:-0}, ${#NETIDS[@]} net lines)"
    log "[$ct] DRY: would move ${NETIDS[*]} onto $MOCKNET_BRIDGE and verify from /sys/class/net"
    st_ok "$ct"; return 0
  fi

  # The record goes down FIRST. If this run dies between the record and the
  # last `pct set`, restore has everything it needs and the container is at
  # worst half moved; the other order loses the bridge names for good.
  local body i
  body="$(printf 'ctid\t%s\nnode\t%s\nwhen\t%s\nby\t%s pid %s\nonboot\t%s\n' \
            "$ct" "$pn" "$(date '+%FT%T%z')" \
            "$(hostname 2>/dev/null | tr -cd 'A-Za-z0-9._-')" "$$" "${ob:-0}")"
  for (( i = 0; i < ${#NETIDS[@]}; i++ )); do
    body="$body$(printf '\n%s\t%s' "${NETIDS[$i]}" "${NETBRS[$i]}")"
  done
  if ! printf '%s\n' "$body" | ssh $SSH_OPT "root@$pip" \
        "mkdir -p $REC_DIR && cat > '$(rec_path "$ct")'" 2>/dev/null; then
    log "[$ct] ERROR: could not write $(rec_path "$ct") on $pn - NOTHING was moved"
    log "[$ct] ERROR:   that file is the only record of which bridge each interface came from."
    log "[$ct] ERROR:   is /etc/pve writable? A cluster without quorum is read-only."
    st_fail "$ct"; return 1
  fi
  local back; back="$(rec_read "$pip" "$ct")"
  if [[ "$(rec_field "$back" ctid)" != "$ct" ]]; then
    log "[$ct] ERROR: $(rec_path "$ct") did not read back as what was sent - NOTHING was moved"
    st_fail "$ct"; return 1
  fi
  log "[$ct] recorded: $(rec_path "$ct") on $pn"

  # From the lines read BEFORE the record was written, not from a fresh probe
  # per interface. Re-reading between each `pct set` would be one round trip per
  # interface for no gain, and it would read a config this loop is halfway
  # through changing.
  for (( i = 0; i < ${#NETIDS[@]}; i++ )); do
    _line="$(printf '%s' "${NETLINES[$i]}" | sed -E "s/bridge=[^,]*/bridge=$MOCKNET_BRIDGE/")"
    if ! rsh "$pip" "pct set $ct --${NETIDS[$i]} '$_line'"; then
      log "[$ct] ERROR: pct set $ct --${NETIDS[$i]} failed on $pn"
      log "[$ct] ERROR:   the record is in place, so the ones that DID move can be put back:"
      log "[$ct] ERROR:     ct-prepare.sh --restore --ctid $ct"
      st_fail "$ct"; return 1
    fi
    _moved="$_moved ${NETIDS[$i]}"
  done

  # ---- GUARD P6: the kernel has to agree ---------------------------------
  out="$(probe "$pip" "$ct")"
  local _wired=""
  while read -r _k _if _br; do
    [[ "$_k" == VETH ]] || continue
    [[ "$_br" == "$MOCKNET_BRIDGE" ]] || _wired="$_wired $_if(${_br:-none})"
  done <<< "$out"
  if [[ -n "$_wired" ]]; then
    log "[$ct] GUARD P6: the config was written but the KERNEL still has:$_wired"
    log "[$ct] GUARD P6:   PVE hotplugs a bridge change onto a running container, and this one"
    log "[$ct] GUARD P6:   did not take. CT $ct is NOT isolated - do not place its copy."
    log "[$ct] GUARD P6:   check it by hand:  ssh root@$pip ls -l /sys/class/net/veth${ct}i*/master"
    st_fail "$ct"; return 1
  fi
  log "[$ct] ISOLATED:$_moved now on $MOCKNET_BRIDGE, verified from /sys/class/net"
  log "[$ct]   it is STILL RUNNING and still a pending writer: its I/O is blocked now"
  log "[$ct]   because the storage is gone, and it resumes the moment that storage is"
  log "[$ct]   back. Stop it before then. ct-failback's B1 refuses until you have."
  log "[$ct]   put it back with:  ct-prepare.sh --restore --ctid $ct"
  st_ok "$ct"; return 0
}

do_restore(){   # $1 = ctid
  local ct="$1" pn pip rec out _k _v _n _line i _put=""
  pn="$(prod_node "$ct")"
  if [[ -z "$pn" ]]; then
    log "[$ct] GUARD P1: CT $ct has no config anywhere in the cluster - nothing to restore"
    st_skip "$ct"; return 1
  fi
  pip="${pn#*	}"; pn="${pn%%	*}"

  rec="$(rec_read "$pip" "$ct")"
  if [[ -z "$(rec_field "$rec" ctid)" ]]; then
    log "[$ct] GUARD P5: no record at $(rec_path "$ct") on $pn - nothing to put back"
    log "[$ct] GUARD P5:   this engine only restores what it wrote down. A container moved onto"
    log "[$ct] GUARD P5:   $MOCKNET_BRIDGE by hand has no record of where it came from, and"
    log "[$ct] GUARD P5:   guessing a bridge puts a customer on the wrong segment."
    st_skip "$ct"; return 1
  fi

  out="$(probe "$pip" "$ct")"
  if [[ -z "$out" || "$out" == *NOCONFIG* ]]; then
    log "[$ct] GUARD P1: $pn ($pip) did not answer, or has no config for CT $ct"
    st_fail "$ct"; return 1
  fi

  declare -a RIDS=() RBRS=()
  while IFS=$'\t' read -r _k _v; do
    [[ "$_k" =~ ^net[0-9]+$ ]] || continue
    RIDS+=("$_k"); RBRS+=("$_v")
  done <<< "$rec"
  if (( ${#RIDS[@]} == 0 )); then
    log "[$ct] ERROR: the record at $(rec_path "$ct") names no interfaces"
    log "[$ct] ERROR:   it is not this engine's to guess at. Read it and fix it by hand."
    st_fail "$ct"; return 1
  fi
  local rob; rob="$(rec_field "$rec" onboot)"

  if (( DRY )); then
    for (( i = 0; i < ${#RIDS[@]}; i++ )); do
      log "[$ct] DRY: would put ${RIDS[$i]} back on ${RBRS[$i]}"
    done
    log "[$ct] DRY: would set onboot ${rob:-0} and remove $(rec_path "$ct")"
    st_ok "$ct"; return 0
  fi

  for (( i = 0; i < ${#RIDS[@]}; i++ )); do
    _line="$(awk -v want="${RIDS[$i]}" '$1=="NETLINE" && $2==want{ $1=""; $2=""; sub(/^  /,""); print; exit }' <<<"$out")"
    if [[ -z "$_line" ]]; then
      log "[$ct] ERROR: ${RIDS[$i]} is in the record but not in CT $ct's config any more"
      log "[$ct] ERROR:   somebody removed an interface while it was isolated. The record is"
      log "[$ct] ERROR:   left in place so nothing is lost - sort it out by hand."
      st_fail "$ct"; return 1
    fi
    _line="$(printf '%s' "$_line" | sed -E "s/bridge=[^,]*/bridge=${RBRS[$i]}/")"
    if ! rsh "$pip" "pct set $ct --${RIDS[$i]} '$_line'"; then
      log "[$ct] ERROR: pct set $ct --${RIDS[$i]} failed on $pn - the record is left in place"
      st_fail "$ct"; return 1
    fi
    _put="$_put ${RIDS[$i]}(${RBRS[$i]})"
  done

  if [[ "${rob:-0}" =~ ^[0-9]+$ ]]; then
    rsh "$pip" "pct set $ct --onboot ${rob:-0}" || \
      log "[$ct] WARN: could not set onboot back to ${rob:-0} - do it by hand"
  fi

  # Only now. A record removed before the work is a container nobody can put
  # back, and this is the same reason the record is written first on the way in.
  if ! rsh "$pip" "rm -f '$(rec_path "$ct")'"; then
    log "[$ct] WARN: put everything back but could not remove $(rec_path "$ct")"
    log "[$ct] WARN:   doctor will keep reporting this container as isolated until it is gone."
    st_fail "$ct"; return 1
  fi
  log "[$ct] RESTORED:$_put, onboot ${rob:-0}, record removed"
  st_ok "$ct"; return 0
}

do_list(){   # $1 = ctid
  local ct="$1" pn pip out rec st sid statrc verdict nets
  pn="$(prod_node "$ct")"
  if [[ -z "$pn" ]]; then
    log "[$ct] LIST: no config anywhere in the cluster"
    st_skip "$ct"; return 1
  fi
  pip="${pn#*	}"; pn="${pn%%	*}"
  out="$(probe "$pip" "$ct")"
  if [[ -z "$out" || "$out" == *NOCONFIG* ]]; then
    log "[$ct] LIST: on $pn ($pip) - NO ANSWER, so nothing about it is known"
    st_fail "$ct"; return 1
  fi
  st="$(awk '$1=="STATUS"{print $2; exit}' <<<"$out")"
  sid="$(awk '$1=="ROOTSID"{print $2; exit}' <<<"$out")"
  statrc="$(awk '$1=="STATRC"{print $2; exit}' <<<"$out")"
  nets="$(awk '$1=="NETS"{print $2; exit}' <<<"$out")"
  verdict="$(storage_verdict "$statrc")"
  rec="$(rec_read "$pip" "$ct")"
  log "[$ct] LIST: on $pn ($pip), ${st:-?}, rootfs storage '$sid' is $verdict, $nets net line(s)"
  printf '%s\n' "$out" | awk '$1=="VETH"{print $2" -> "$3}' | while read -r _l; do
    log "[$ct]   kernel: $_l"
  done
  if [[ -n "$(rec_field "$rec" ctid)" ]]; then
    log "[$ct]   ISOLATED by this tool, $(rec_field "$rec" when) - restore puts it back:"
    printf '%s\n' "$rec" | awk -F'\t' '$1 ~ /^net[0-9]+$/{print "    "$1" was on "$2}' | while read -r _l; do
      log "[$ct] $_l"
    done
  fi
  case "$verdict" in
    alive) log "[$ct]   --isolate would REFUSE: that storage answered";;
    *)     [[ "$st" == running ]] && log "[$ct]   --isolate would move $nets net line(s) onto $MOCKNET_BRIDGE";;
  esac
  st_ok "$ct"; return 0
}


# ---------- --evacuate: the node, not the container -------------------------
# The order below is the whole thing, and it is the opposite of what anybody
# does by hand. Disable the storage FIRST so pvestatd stops walking into it,
# then force the mount to fail, and only THEN stop the containers - because a
# container whose NFS rootfs is still mounted and gone has its processes in
# uninterruptible sleep, `pct shutdown` waits for a guest that cannot answer,
# and SIGKILL does not reach a task in D state. Unmount first and the same
# shutdown returns in seconds. Everyone gets this backwards, including the
# runbook this replaces, because the instinct is to close the container before
# touching its disk.
#
#   E1  the node must answer
#   E2  every storage this touches must be PROVABLY DEAD - the same stat proof
#       as P2, asked per storage. A live one is left completely alone, and so
#       is every container on it: a compute node holding one dead NFS storage
#       and one healthy local-lvm must come out of this with its local
#       containers still running
#   E3  what was disabled is written down before it is disabled. `pvesm set
#       --disable` writes /etc/pve/storage.cfg, which is CLUSTER-WIDE - every
#       node stops seeing that storage - so the way back has to exist before
#       the way in
#   E4  a container that will not stop is isolated instead, not forced. There
#       is no escalation ladder past that: `pct stop` harder does not exist,
#       and this engine will say a container is still up rather than pretend
#   E5  the shutdown is verified by asking again, not by the exit code of the
#       command that asked
EVAC_DIR=/etc/pve/ketsync/evacuate
evac_path(){ printf '%s/%s.tsv' "$EVAC_DIR" "$1"; }
evac_read(){ rsh "$1" "cat '$(evac_path "$2")' 2>/dev/null"; }

do_evacuate(){   # $1 = node ip
  local pip="$1" pn out ct sid verdict st _s
  declare -a MINE=() DEADSIDS=() DEADPATHS=() TOSTOP=()
  declare -A SEEN_SID=()

  # Which of the inventory's containers live here, and what each one's rootfs
  # storage is doing. One probe per container: the same call, the same parsing
  # and the same three-way verdict the isolate path uses, so there is no second
  # opinion about what "dead" means.
  for ct in "${CTS[@]}"; do
    pn="$(prod_node "$ct")"; [[ -n "$pn" ]] || continue
    [[ "${pn#*	}" == "$pip" ]] || continue
    MINE+=("$ct")
  done
  if (( ${#MINE[@]} == 0 )); then
    log "[$pip] GUARD E1: no container from the inventory lives on this node - nothing to evacuate"
    st_skip "$pip"; return 1
  fi
  pn="$(prod_node "${MINE[0]}")"; pn="${pn%%	*}"

  for ct in "${MINE[@]}"; do
    out="$(probe "$pip" "$ct")"
    if [[ -z "$out" ]]; then
      log "[$pip] GUARD E1: $pn did not answer - NOTHING was disabled or unmounted"
      log "[$pip] GUARD E1:   this mode disables a storage for the whole cluster. A node that"
      log "[$pip] GUARD E1:   cannot be asked is not a node to do that on behalf of."
      st_fail "$pip"; return 1
    fi
    sid="$(awk '$1=="ROOTSID"{print $2; exit}' <<<"$out")"
    verdict="$(storage_verdict "$(awk '$1=="STATRC"{print $2; exit}' <<<"$out")")"
    st="$(awk '$1=="STATUS"{print $2; exit}' <<<"$out")"
    if [[ "$verdict" == alive ]]; then
      log "[$pip] E2: CT $ct is on '$sid', which answered - left alone, not touched"
      continue
    fi
    if [[ -z "${SEEN_SID[$sid]:-}" ]]; then
      SEEN_SID[$sid]=1
      DEADSIDS+=("$sid")
      DEADPATHS+=("$(awk '$1=="ROOTPATH"{print $2; exit}' <<<"$out")")
      log "[$pip] E2: storage '$sid' is $verdict here"
    fi
    [[ "$st" == running ]] && TOSTOP+=("$ct")
  done

  if (( ${#DEADSIDS[@]} == 0 )); then
    log "[$pip] GUARD E2: every storage this node's containers use ANSWERED - nothing to evacuate"
    log "[$pip] GUARD E2:   evacuating a healthy node would disable a working storage for the"
    log "[$pip] GUARD E2:   whole cluster and unmount it underneath running containers."
    st_skip "$pip"; return 1
  fi

  log "[$pip] evacuate: ${#DEADSIDS[@]} dead storage(s): ${DEADSIDS[*]}"
  log "[$pip] evacuate: ${#TOSTOP[@]} container(s) to stop: ${TOSTOP[*]:-<none>}"
  if (( DRY )); then
    log "[$pip] DRY: would write $(evac_path "$pn") then disable ${DEADSIDS[*]}"
    log "[$pip] DRY: would umount -f -l ${DEADPATHS[*]}, restart pvestatd, then stop the above"
    st_ok "$pip"; return 0
  fi

  # ---- E3: the way back, before the way in --------------------------------
  local body
  body="$(printf 'node\t%s\nip\t%s\nwhen\t%s\nby\t%s pid %s\n' \
            "$pn" "$pip" "$(date '+%FT%T%z')" \
            "$(hostname 2>/dev/null | tr -cd 'A-Za-z0-9._-')" "$$")"
  for _s in "${DEADSIDS[@]}"; do body="$body$(printf '\ndisabled\t%s' "$_s")"; done
  if ! printf '%s\n' "$body" | ssh $SSH_OPT "root@$pip" \
        "mkdir -p $EVAC_DIR && cat > '$(evac_path "$pn")'" 2>/dev/null; then
    log "[$pip] ERROR: could not write $(evac_path "$pn") - NOTHING was disabled"
    log "[$pip] ERROR:   that file is the list of storages somebody has to switch back on."
    st_fail "$pip"; return 1
  fi
  log "[$pip] recorded: $(evac_path "$pn")"

  local i
  for (( i = 0; i < ${#DEADSIDS[@]}; i++ )); do
    if rsh "$pip" "pvesm set ${DEADSIDS[$i]} --disable 1"; then
      log "[$pip] disabled storage ${DEADSIDS[$i]} (cluster-wide - pvestatd stops polling it)"
    else
      log "[$pip] WARN: could not disable ${DEADSIDS[$i]} - carrying on to the unmount"
    fi
    # -f makes the blocked requests return EIO, which is what frees the
    # processes; -l detaches the tree so a mount nothing can reach still comes
    # out of the namespace. Neither destroys anything: the data is on the
    # server that is not answering.
    if rsh "$pip" "umount -f -l '${DEADPATHS[$i]}'"; then
      log "[$pip] unmounted ${DEADPATHS[$i]}"
    else
      log "[$pip] WARN: umount -f -l ${DEADPATHS[$i]} did not return 0 - the stops below may hang"
    fi
  done
  rsh "$pip" "systemctl restart pvestatd" \
    && log "[$pip] restarted pvestatd - the node should answer for itself again" \
    || log "[$pip] WARN: could not restart pvestatd - the GUI will stay grey"

  # ---- E4/E5: stop what can be stopped, isolate what cannot ---------------
  local rc
  for ct in "${TOSTOP[@]}"; do
    rsh "$pip" "timeout $SHUTDOWN_TIMEOUT pct shutdown $ct"; rc=$?
    out="$(probe "$pip" "$ct")"
    st="$(awk '$1=="STATUS"{print $2; exit}' <<<"$out")"
    if [[ "$st" != running ]]; then
      log "[$ct] STOPPED on $pn - it can no longer answer and no longer writes"
      st_ok "$ct"; continue
    fi
    log "[$ct] did not come down within ${SHUTDOWN_TIMEOUT}s (rc=$rc) - isolating it instead"
    log "[$ct]   nothing here forces a stop. A container that will not go is one whose"
    log "[$ct]   processes are still waiting on something, and taking it off the wire"
    log "[$ct]   removes the hazard the DR actually cares about."
    do_isolate "$ct" || true
  done
  st_ok "$pip"; return 0
}

do_unevacuate(){   # $1 = node ip - put the storages back
  local pip="$1" pn rec _s
  pn="$(rsh "$pip" 'readlink /etc/pve/local 2>/dev/null | sed "s|.*/||"')"
  if [[ -z "$pn" ]]; then
    log "[$pip] GUARD E1: that node did not say which PVE node it is - nothing was changed"
    st_fail "$pip"; return 1
  fi
  rec="$(evac_read "$pip" "$pn")"
  if [[ -z "$rec" ]]; then
    log "[$pip] GUARD E3: no record at $(evac_path "$pn") - this tool did not evacuate $pn"
    log "[$pip] GUARD E3:   it only switches back on what it switched off. A storage somebody"
    log "[$pip] GUARD E3:   disabled by hand is theirs to enable, and enabling one that was"
    log "[$pip] GUARD E3:   disabled on purpose is how a half-repaired fleet goes back to work."
    st_skip "$pip"; return 1
  fi
  declare -a SIDS=()
  while IFS=$'\t' read -r _k _v; do
    [[ "$_k" == disabled ]] && SIDS+=("$_v")
  done <<< "$rec"
  if (( ${#SIDS[@]} == 0 )); then
    log "[$pip] ERROR: the record at $(evac_path "$pn") names no storages"
    st_fail "$pip"; return 1
  fi
  if (( DRY )); then
    log "[$pip] DRY: would enable ${SIDS[*]} and remove $(evac_path "$pn")"
    st_ok "$pip"; return 0
  fi
  local bad=""
  for _s in "${SIDS[@]}"; do
    if rsh "$pip" "pvesm set $_s --disable 0"; then
      log "[$pip] enabled storage $_s"
    else
      log "[$pip] ERROR: could not enable $_s - the record is left in place"
      bad=1
    fi
  done
  if [[ -n "$bad" ]]; then st_fail "$pip"; return 1; fi
  rsh "$pip" "rm -f '$(evac_path "$pn")'" \
    || log "[$pip] WARN: enabled everything but could not remove $(evac_path "$pn")"
  log "[$pip] RE-ENABLED: ${SIDS[*]} on $pn"
  st_ok "$pip"; return 0
}

# ---------- the run ---------------------------------------------------------
hr
if (( EVACUATE )) || { (( RESTORE )) && [[ -n "$ONLY_NODE" ]]; }; then
  # Per NODE. The container list is still the inventory - this never touches a
  # container nobody wrote down - but the unit of work is the machine, because
  # disabling a storage and unmounting it is not something one container has.
  declare -a NODES=()
  if [[ -n "$ONLY_NODE" ]]; then
    NODES=("$ONLY_NODE")
  else
    declare -A SEEN_NODE=()
    for _ct in "${CTS[@]}"; do
      _pn="$(prod_node "$_ct")"; [[ -n "$_pn" ]] || continue
      _pip="${_pn#*	}"
      [[ -n "${SEEN_NODE[$_pip]:-}" ]] && continue
      SEEN_NODE[$_pip]=1; NODES+=("$_pip")
    done
  fi
  if (( ${#NODES[@]} == 0 )); then
    log "ERROR: no node holds any container from the inventory - nothing was done"
    exit 1
  fi
  log "=== $(hostname) prepare mode=$MODE nodes: ${NODES[*]} ==="
  for _n in "${NODES[@]}"; do
    hr_ct
    if (( EVACUATE )); then do_evacuate   "$_n" || true
    else                    do_unevacuate "$_n" || true
    fi
  done
else
  log "=== $(hostname) prepare mode=$MODE containers: ${CTS[*]} ==="
  for _ct in "${CTS[@]}"; do
    hr_ct
    if   (( ISOLATE )); then do_isolate "$_ct" || true
    elif (( RESTORE )); then do_restore "$_ct" || true
    else                     do_list    "$_ct" || true
    fi
  done
fi

hr2
log "=== prepare $MODE finished: ok=$ok skipped=$skipped failed=$failed ==="
(( skipped )) && log "  skipped: ${SKIPPED_IDS[*]}"
(( failed ))  && log "  NEEDS ATTENTION -> CT: ${FAILED_IDS[*]}"
if (( ISOLATE || EVACUATE )) && (( ok )); then
  log "  next: ketsync distribute --all      # D1 will accept these now"
  log "  and when the storage is back:  ct-prepare.sh --restore --all"
  (( EVACUATE )) && log "  the storages this switched off:  ct-prepare.sh --restore --node <ip>"
fi
(( failed || skipped )) && exit 1
exit 0
