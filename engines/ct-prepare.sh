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
#      cleanup   the OTHER end of the disaster, and the only mode that runs
#                after it is over. The failback has put the newest data back
#                into the production image; this puts the production network
#                back if nobody has yet, stops the 9<id> that was serving in
#                its place, and moves that one onto MOCKNET_BRIDGE so a
#                compute node rebooting cannot put the address back on the
#                wire. `--destroy` also removes it, which is what releases
#                ct-replica's R13.
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
#    ct-prepare.sh --cleanup --ctid 300        after the failback: put 9300 away
#    ct-prepare.sh --cleanup --all --destroy   and remove them, releasing R13
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
#       moved. On an Open vSwitch node the master is the datapath and not the
#       bridge, so the probe asks ovsdb too - see veth_bridge().
#
#  Nothing here starts a container, ever. Two modes stop one - `--evacuate`,
#  which does a whole machine, and `--cleanup`, which puts away the stand-in
#  after the disaster is over - and they are separate from the rest for that
#  reason: everything else here is safe to point at a container that is
#  serving customers, in the sense that it will refuse.
#
#  ONE mode destroys, and only with `--destroy`, and only a 9<id>: the
#  temporary container this fleet's own DR created, whose data has been carried
#  back and verified. A production id can never reach that command - the number
#  is worked out from DR_OFFSET rather than typed - and destroying it is what
#  releases ct-replica's R13, which is why it is a flag and not the default.
#
#  The evacuate guards are E1..E5 and the cleanup guards K1..K4; both are
#  documented where they run.
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
if [[ -f "$BASE/../bin/ketsync" && -f "$BASE/../lib/common.sh" && -f "$BASE/../conf/nodes.map" ]]; then
  NODEMAP="$(cd "$BASE/.." && pwd)/conf/nodes.map"
fi

# ---------- defaults; ctrep.conf wins ----------------------------------------
BKP_SSH="root@10.100.1.9"
MOCKNET_BRIDGE=vmbr99            # the isolated bridge. Same knob, same file,
                                 # as ct-replica R9 and ct-distribute D1
SHUTDOWN_TIMEOUT=180             # cleanup's patience: seconds to wait for a
                                 # 9<id> on HEALTHY storage to shut down. That
                                 # path is after the disaster, nothing is
                                 # waiting on it, and a database flushing for
                                 # two minutes deserves its two minutes.
SHUTDOWN_GRACE=30                # the DISASTER path's patience - evacuate and
                                 # the stop after an isolate - and it is short
                                 # on purpose. This engine used to wait 180
                                 # here too, sized against the fleet's measured
                                 # I/O-error horizon (hard,timeo=600,retrans=2:
                                 # the write fails at ~132s, ext4 aborts, the
                                 # kill lands - measured 15:47:11 unmount,
                                 # 15:49:18 error, 15:49:23 gone). The
                                 # 2026-08-15 drill showed what that patience
                                 # actually buys during a real outage: nothing.
                                 # Whether the EIO ever comes is a race with
                                 # the RPCs in flight at unmount time, and the
                                 # drill lost it on every container, 210
                                 # seconds each. What the DR needs is OFF THE
                                 # WIRE, which isolate delivers in about three
                                 # seconds and D1 accepts; and the shutdown
                                 # request is a SIGNAL, delivered in the first
                                 # second, that OUTLIVES the wait - the same
                                 # drill watched both containers shut
                                 # themselves down hours later, the moment the
                                 # storage returned, on the strength of that
                                 # queued signal. So the ask is made, a guest
                                 # whose writes already fail fast gets long
                                 # enough to run an orderly shutdown, and
                                 # everything else is isolated instead of
                                 # waited on. At two hundred containers the
                                 # difference is eleven hours of customer
                                 # downtime against two.
STAT_TIMEOUT=5                   # seconds to wait for a storage to answer. A
                                 # live mount answers in microseconds; this is
                                 # not a tuning knob, it is the difference
                                 # between "answered" and "blocked forever"
LOG_KEEP_DAYS=14                 # same knob, same ctrep.conf, as ct-replica.sh
DR_OFFSET=9000                   # production id -> the temporary container on a
                                 # compute node's own storage. Same knob, same
                                 # file, as ct-distribute and ct-recall: --cleanup
                                 # is the only mode here that touches a 9<id>,
                                 # and it works the number out rather than being
                                 # told it
SSH_CIPHERS=aes128-gcm@openssh.com,aes256-gcm@openssh.com,aes128-ctr
# -------------------------------------------------------------------------

ONLY_CTID=""; ONLY_NODE=""; ALL=0; LIST=0; DRY=0; ISOLATE=0; RESTORE=0; EVACUATE=0
CLEANUP=0; DESTROY=0
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
    --cleanup) CLEANUP=1; shift;;
    --destroy) DESTROY=1; shift;;
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
# --cleanup is the end of the disaster and every other mode is the middle of
# one. Asking for both in one command is asking to put a container away and
# take it out again, and there is no order that makes that mean something.
if (( CLEANUP && (ISOLATE || RESTORE || EVACUATE) )); then
  echo "--cleanup is the end of a disaster; --isolate/--restore/--evacuate are the middle" >&2
  echo "       of one. Pick one. --cleanup restores the production network itself." >&2
  exit 2
fi
if (( DESTROY && ! CLEANUP )); then
  echo "--destroy is a flag of --cleanup, not a mode: it decides what happens to the" >&2
  echo "       9<id> once its data is home. Nothing else here destroys anything." >&2
  exit 2
fi
if (( ! LIST && ! ISOLATE && ! RESTORE && ! EVACUATE && ! CLEANUP )); then
  echo "usage: ct-prepare.sh --list | --isolate | --restore | --evacuate | --cleanup" >&2
  echo "       [--all | --ctid <production_ctid> | --node <ip>] [--dry-run]" >&2
  exit 2
fi
if (( CLEANUP )) && (( ! ALL )) && [[ ! "$ONLY_CTID" =~ ^[0-9]+$ ]]; then
  echo "usage: ct-prepare.sh --cleanup --all | --ctid <production_ctid> [--destroy]" >&2
  echo "       the id is the PRODUCTION one. The 9<id> is worked out from it -" >&2
  echo "       nobody types the number of the container that gets stopped." >&2
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
if (( ! LIST )) && (( ! CLEANUP )) && (( ! ALL )) && [[ ! "$ONLY_CTID" =~ ^[0-9]+$ ]] && [[ -z "$ONLY_NODE" ]]; then
  echo "usage: ct-prepare.sh --isolate|--restore --all | --ctid <production_ctid>" >&2
  echo "       ct-prepare.sh --evacuate|--restore --node <ip>" >&2
  exit 2
fi

if [[ -f "$CONF" ]]; then
  # shellcheck source=/dev/null
  . "$CONF" || { echo "failed to read $CONF" >&2; exit 2; }
fi
for _v in STAT_TIMEOUT SHUTDOWN_TIMEOUT SHUTDOWN_GRACE LOG_KEEP_DAYS DR_OFFSET; do
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
(( CLEANUP ))  && MODE=cleanup
(( CLEANUP && DESTROY )) && MODE=cleanup/destroy
(( DRY ))     && MODE="$MODE/dry-run"

SSH_COMMON="-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o ServerAliveInterval=15 -c $SSH_CIPHERS"
SSH_OPT="$SSH_COMMON -o ControlMaster=auto -o ControlPath=/run/ctprep-$$-%r@%h.sock -o ControlPersist=120"

node_ip(){ awk -v n="$1" '$1!~/^#/ && $2==n{print $1; exit}' "$NODEMAP" 2>/dev/null; }
rsh(){ ssh $SSH_OPT "root@$1" "${@:2}" </dev/null 2>/dev/null; }

# The bridge named by one net line. Split on commas and take the field, rather
# than matching bridge=vmbr99 inside a string - which also matches vmbr990, and
# the whole point of the checks that use this is that they are exact.
net_bridge(){ printf '%s' "$1" | tr ',' '\n' | sed -n 's/^bridge=//p' | head -1; }

# Which bridge a veth is REALLY on, out of the probe's own output.
#
# Open vSwitch does not enslave a port to the bridge it belongs to. Every port
# of every OVS bridge on a host is enslaved to one datapath device called
# ovs-system, so /sys/class/net/<if>/master names the datapath and never the
# bridge - the membership lives in ovsdb, and ovs-vsctl is the only thing that
# can answer for it. That is why the probe asks it, and this is where the
# answer is used.
#
# This is not theoretical. On an OVS fleet P6 would refuse every container it
# had just isolated correctly, and ct-distribute's D1 did: "still on the wire:
# veth110i0(ovs-system)", about a container that was on vmbr99. The one route
# out of a dead storage node, closed by a string comparison.
#
# An unresolved ovs-system is returned unchanged rather than blanked. It is
# not a bridge name, so every comparison against MOCKNET_BRIDGE still fails
# and nothing is reported as isolated - but the operator sees the word that
# tells them ovs-vsctl did not answer.
veth_bridge(){   # $1 = probe output, $2 = interface, $3 = its kernel master
  local b
  case "$3" in
    ""|ovs-system) b="$(awk -v i="$2" '$1=="OVSBR" && $2==i {print $3; exit}' <<<"$1")"
                   printf '%s' "${b:-$3}";;
    *)             printf '%s' "$3";;
  esac
}

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
#   VETH <if> <master>    what the KERNEL has, which is the one that cannot lie
#   OVSBR <if> <bridge>   what OVSDB has, for a node where the kernel's answer
#                         is the datapath rather than a bridge. Both are
#                         printed and veth_bridge() picks: deciding here would
#                         put the decision inside a remote snippet, where no
#                         simulator and no mutation can reach it
#   ONBOOT <0|1>
#   STATUS <word>
#   ROOTSID <storage-id>  where its rootfs lives
#   STATRC <rc>           124 = the storage blocked until the timeout: dead
#   ROOTTYPE <word>       the storage.cfg section header: nfs, cifs, dir ...
#   ROOTISMP <val>        is_mountpoint from that section, empty when unset
#   MOUNTED <0|1>         whether ROOTPATH is in /proc/mounts. A FACT, like
#                         OVSBR: reading /proc/mounts cannot block, and the
#                         verdict that needs it is made by the engine, where
#                         mutations can reach it
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
    echo \"ROOTTYPE \$(sed -n \"s/^\\([a-z]*\\): \$sid\$/\\1/p\" /etc/pve/storage.cfg 2>/dev/null | head -1)\"
    echo \"ROOTISMP \$(sed -n \"/^[a-z]*: \$sid\$/,/^\$/p\" /etc/pve/storage.cfg 2>/dev/null | sed -n 's/^[[:space:]]*is_mountpoint[[:space:]]\\{1,\\}//p' | head -1)\"
    if awk -v p=\"\$p\" '\$2==p{f=1} END{exit f?0:1}' /proc/mounts; then echo \"MOUNTED 1\"; else echo \"MOUNTED 0\"; fi
    echo \"DSTATE \$(ps -eo stat= 2>/dev/null | grep -c '^D')\"
    for i in /sys/class/net/veth${ct}i*; do
      [ -e \"\$i\" ] || continue
      n=\${i##*/}
      m=\$(readlink -f \"\$i/master\" 2>/dev/null)
      echo \"VETH \$n \${m##*/}\"
      b=\$(ovs-vsctl --timeout=5 iface-to-br \"\$n\" 2>/dev/null) && [ -n \"\$b\" ] && echo \"OVSBR \$n \$b\"
    done
    ip -br link show $MOCKNET_BRIDGE >/dev/null 2>&1 || { echo BRMISSING; exit 0; }
    ports=\$(ovs-vsctl --timeout=5 list-ifaces $MOCKNET_BRIDGE 2>/dev/null || ls /sys/class/net/$MOCKNET_BRIDGE/brif/ 2>/dev/null)
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
# and a hard refusal - PROVIDED the path is actually a mount. That proviso is
# the 2026-08-15 drill: `umount -f -l` takes the mount out of the namespace
# and leaves PVE's mountpoint DIRECTORY behind, an empty dir on the node's
# root filesystem, and a stat on an empty local dir answers instantly. This
# function read that instant answer as ALIVE - the engine's own unmount, read
# back four minutes later as the storage having recovered - and P2 refused
# the isolation that unmount existed to make possible. So for a storage that
# is only real when mounted - nfs, cifs, or a dir that declares is_mountpoint
# - the kernel's mount table overrules the stat: a path that is not in it is
# gone, however fast whatever is at that path answers. A plain dir storage
# stays with the stat alone; it was never a mount, and condemning it for not
# being one would refuse every healthy local-path storage on the fleet.
storage_verdict(){   # $1 = STATRC, $2 = MOUNTED, $3 = ROOTTYPE, $4 = ROOTISMP
  case "${3:-}" in
    nfs|cifs) [[ "${2:-1}" == 0 ]] && { printf 'gone'; return; };;
    *)        [[ -n "${4:-}" && "${4:-0}" != 0 && "${2:-1}" == 0 ]] \
                && { printf 'gone'; return; };;
  esac
  case "${1:-}" in
    124) printf 'dead';;
    0)   printf 'alive';;
    *)   printf 'gone';;
  esac
}

# What do_isolate found out on its way, for the caller that has to decide what
# to do next. Set on every path that gets as far as reading the node, because
# the answer "why can this container not be stopped" is the probe's answer and
# re-asking would be a second round trip for a fact already in hand.
ISO_PIP=""; ISO_PN=""; ISO_VERDICT=""

do_isolate(){   # $1 = ctid
  local ct="$1" pn pip out st nets rec _k _if _br _n _line _iso_bad="" _moved=""
  ISO_PIP=""; ISO_PN=""; ISO_VERDICT=""
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
  local sid path statrc verdict dstate mounted
  sid="$(awk '$1=="ROOTSID"{print $2; exit}' <<<"$out")"
  path="$(awk '$1=="ROOTPATH"{print $2; exit}' <<<"$out")"
  statrc="$(awk '$1=="STATRC"{print $2; exit}' <<<"$out")"
  dstate="$(awk '$1=="DSTATE"{print $2; exit}' <<<"$out")"
  mounted="$(awk '$1=="MOUNTED"{print $2; exit}' <<<"$out")"
  verdict="$(storage_verdict "$statrc" "$mounted" \
               "$(awk '$1=="ROOTTYPE"{print $2; exit}' <<<"$out")" \
               "$(awk '$1=="ROOTISMP"{print $2; exit}' <<<"$out")")"
  ISO_PIP="$pip"; ISO_PN="$pn"; ISO_VERDICT="$verdict"

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
  log "[$ct] P2: storage '$sid' is $verdict ($path, stat rc=$statrc, mounted=$mounted, $dstate procs in D state)"

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
    _br="$(veth_bridge "$out" "$_if" "$_br")"
    [[ "$_br" == "$MOCKNET_BRIDGE" ]] || _wired="$_wired $_if(${_br:-none})"
  done <<< "$out"
  if [[ -n "$_wired" ]]; then
    log "[$ct] GUARD P6: the config was written but the KERNEL still has:$_wired"
    log "[$ct] GUARD P6:   PVE hotplugs a bridge change onto a running container, and this one"
    log "[$ct] GUARD P6:   did not take. CT $ct is NOT isolated - do not place its copy."
    log "[$ct] GUARD P6:   check it by hand:  ssh root@$pip ls -l /sys/class/net/veth${ct}i*/master"
    if [[ "$_wired" == *"(ovs-system)"* ]]; then
      log "[$ct] GUARD P6:   ovs-system is Open vSwitch's datapath, not a bridge - every port"
      log "[$ct] GUARD P6:   on every OVS bridge is on it, so the kernel cannot name the bridge"
      log "[$ct] GUARD P6:   and ovs-vsctl on $pn did not answer either:"
      log "[$ct] GUARD P6:     ssh root@$pip ovs-vsctl iface-to-br veth${ct}i0"
      log "[$ct] GUARD P6:   the net lines ARE written - put them back with --restore."
    fi
    st_fail "$ct"; return 1
  fi
  log "[$ct] ISOLATED:$_moved now on $MOCKNET_BRIDGE, verified from /sys/class/net"
  log "[$ct]   put it back with:  ct-prepare.sh --restore --ctid $ct"
  st_ok "$ct"; return 0
}

# ---------- stopping the container that was just isolated -------------------
# Off the wire is not the end of it. An isolated container is still a PENDING
# WRITER: its I/O is blocked only because the storage is gone, and it resumes
# the instant that storage comes back, into an image the fleet has moved on
# from. ct-failback's B1 refuses the failback until it is down, so this debt
# cannot be forgotten silently - but somebody still has to pay it, and at two
# hundred containers that somebody is this.
#
# WHETHER IT CAN BE STOPPED AT ALL is decided by one thing, and the probe
# already knows it. A container whose dead mount is still there has processes
# in uninterruptible sleep: `pct shutdown` waits for a guest that cannot
# answer, SIGKILL does not reach a task in D state, and the command hangs until
# the timeout kills it having achieved nothing. Once the mount is gone - which
# is what `--evacuate` does with `umount -f -l` - the same pending I/O returns
# EIO, the processes are free, and the shutdown returns in seconds.
#
# So this asks only when the verdict is `gone`, and when it is `dead` it names
# the command that makes it gone. That command is per NODE and this one named a
# container: the dead mount is shared by everything on that storage, so freeing
# it is not something a --ctid run may do to a machine behind the operator's
# back.
#
# It never forces. There is no rung above asking, and being off the wire is
# already the thing the DR needs.
stop_after_isolate(){   # $1 = ctid. Uses what do_isolate just found out.
  local ct="$1" rc out st _l
  [[ -n "$ISO_PIP" ]] || return 0
  # A dry run reaches here with everything else pretended, and stopping a
  # customer's container is not something to pretend at.
  (( DRY )) && { log "[$ct] DRY: would ask it to stop if its dead mount were gone"; return 0; }
  if [[ "$ISO_VERDICT" != gone ]]; then
    log "[$ct]   it is STILL RUNNING, and stopping it needs its blocked I/O freed first."
    log "[$ct]   That is a NODE operation - the dead mount is shared by every container"
    log "[$ct]   on that storage - so this run, which named one container, will not do"
    log "[$ct]   it on its own:"
    log "[$ct]     ketsync evacuate --node $ISO_PIP"
    log "[$ct]   that disables the dead storage, unmounts it, restarts pvestatd and then"
    log "[$ct]   stops every container that was on it. Until then CT $ct is a pending"
    log "[$ct]   writer and ct-failback's B1 refuses to write into its image."
    return 0
  fi
  log "[$ct] its dead mount is already gone, so a shutdown can return: asking CT $ct to stop"
  # Its own exit code on its own line, for the same reason as evacuate above:
  # pct exits 255 when it dies and so does ssh when it cannot connect. And the
  # short grace, for the reason on SHUTDOWN_GRACE itself: the request is a
  # signal that outlives the wait, and off the wire is already done.
  out="$(rsh "$ISO_PIP" "timeout $((SHUTDOWN_GRACE+30)) pct shutdown $ct --timeout $SHUTDOWN_GRACE 2>&1; echo __rc=\$?")"
  rc="$(sed -n 's/^__rc=//p' <<<"$out" | tail -1)"
  while IFS= read -r _l; do
    [[ -n "$_l" && "$_l" != __rc=* ]] && log "[$ct]   pct: $_l"
  done <<< "$out"
  out="$(probe "$ISO_PIP" "$ct")"
  st="$(awk '$1=="STATUS"{print $2; exit}' <<<"$out")"
  if [[ "$st" != running ]]; then
    log "[$ct] STOPPED on $ISO_PN - off the wire and no longer writing"
    return 0
  fi
  # Same three answers as evacuate, and they are worth telling apart even here
  # where the container is already isolated and there is no fallback left to
  # skip: a wrong one sends somebody to look at a container when the thing that
  # broke was the connection to its node.
  if [[ -z "$rc" ]]; then
    log "[$ct] ssh to $ISO_PN FAILED while asking it to stop - not CT $ct"
    log "[$ct]   nothing came back, not even the exit code the command was told to print,"
    log "[$ct]   so the container was never asked and nothing here knows its state. It is"
    log "[$ct]   already off the wire; what is left is why that node stopped answering."
    return 0
  fi
  if [[ "$rc" == 124 ]]; then
    log "[$ct] pct itself never returned (rc=124) - it stays isolated"
  else
    log "[$ct] pct itself failed (rc=$rc) and CT $ct is still running - it stays isolated"
    log "[$ct]   what pct said is above."
  fi
  log "[$ct]   nothing here forces a stop. A container that will not go is one whose"
  log "[$ct]   processes are still waiting on something, and off the wire is what the"
  log "[$ct]   DR actually needs. B1 will refuse the failback until it is down."
  return 0
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

# ---------- --cleanup: the end of the disaster ------------------------------
# Everything else here happens while the storage node is dead. This one happens
# after it is back and `ct-failback --final` has put the newest data into the
# production image, and it deals with what the disaster left standing: a
# production container still on the isolated bridge, and a 9<id> on a compute
# node still holding the address it was placed to answer with.
#
# What it does, in this order:
#
#   1. puts the production network and onboot back, out of the isolate record
#      (skipped when there is no record - somebody already ran --restore)
#   2. stops the 9<id>, if it is still running
#   3. moves the 9<id>'s interfaces onto MOCKNET_BRIDGE, so a compute node
#      rebooting can never put that address back on the wire
#   4. with --destroy, destroys it
#
# THE GUARDS (K1..K4):
#
#   K1  the 9<id> must exist somewhere in the cluster. Asked of the cluster,
#       never of an argument - the same rule as ct-recall's C1
#
#   K2  `ct-failback --final` must have finished OK for this container, read
#       from the failback state file. That is the proof the production image
#       holds the newest data; without it, putting the 9<id> away is putting
#       away the only copy of everything the customer did during the outage.
#       The file is written by the machine that ran the failback, so this mode
#       is run there too, and says so when the file is missing rather than
#       assuming the worst or the best
#
#   K3  a RUNNING 9<id> is only stopped when the production container is
#       running. Stopping it otherwise means nothing answers that address at
#       all, which is an outage caused by the tidy-up. An already-stopped one
#       is a different question and is not asked: there is nothing left to take
#       away. `pct start` is a human's, always, so this refuses rather than
#       starting production itself
#
#   K4  --destroy is refused while the 9<id> is running, whatever K3 decided
#
# WHY STOPPING IS THE DEFAULT AND DESTROYING IS A FLAG. Stopping is reversible
# by one `pct start`; destroying is not reversible at all. But ct-replica's R13
# keys on the 9<id>'s CONFIG existing, not on it running, so a stopped one
# still holds replication for that container - deliberately, because that is
# what protects the pre-outage copy. Both facts are printed every run: the
# operator decides when the fallback has stopped being worth a paused nightly.
do_cleanup(){   # $1 = production ctid
  local ct="$1" dr=$(( $1 + DR_OFFSET ))
  local dn="" dip="" pn="" pip="" out="" st="" pst="" rec=""
  local _k _n _line _moved="" _fb

  # ---- K2 first: it is the cheapest, and it decides the whole run ---------
  _fb="$BASE/state/failback-$ct.json"
  if [[ ! -f "$_fb" ]]; then
    log "[$ct] GUARD K2: no failback state for CT $ct on this machine ($_fb)"
    log "[$ct] GUARD K2:   this mode puts away the container that has been serving customers,"
    log "[$ct] GUARD K2:   so it asks for proof the data is home first, and that proof is the"
    log "[$ct] GUARD K2:   failback's own record of its last run. Run this on the machine that"
    log "[$ct] GUARD K2:   ran ct-failback - the one that holds the production images."
    st_skip "$ct"; return 1
  fi
  local _fbmode _fbstatus
  _fbmode="$(sed -n 's/.*"mode":"\([^"]*\)".*/\1/p'     "$_fb" | tail -1)"
  _fbstatus="$(sed -n 's/.*"status":"\([^"]*\)".*/\1/p' "$_fb" | tail -1)"
  if [[ "$_fbmode" != final || "$_fbstatus" != ok ]]; then
    log "[$ct] GUARD K2: the last failback for CT $ct was mode='${_fbmode:-?}' status='${_fbstatus:-?}'"
    log "[$ct] GUARD K2:   only a FINAL round that ended ok says the production image holds"
    log "[$ct] GUARD K2:   everything the 9<id> served during the outage. A presync does not:"
    log "[$ct] GUARD K2:   it is a rehearsal that leaves the newest data where it was."
    log "[$ct] GUARD K2:     ct-failback.sh --ctid $ct --final"
    st_skip "$ct"; return 1
  fi
  log "[$ct] K2: failback --final finished ok - the production image is the newest data"

  # ---- step 1: the production network, out of the record ------------------
  pn="$(prod_node "$ct")"
  pip="${pn#*	}"; pn="${pn%%	*}"
  if [[ -n "$pn" ]]; then
    rec="$(rec_read "$pip" "$ct")"
    if [[ -n "$(rec_field "$rec" ctid)" ]]; then
      log "[$ct] cleanup: CT $ct still has an isolate record - putting its network back first"
      do_restore "$ct" || { log "[$ct] cleanup: the restore did not finish - stopping here"; return 1; }
    fi
    pst="$(awk '$1=="STATUS"{print $2; exit}' <<<"$(probe "$pip" "$ct")")"
  fi

  # ---- K1: where the 9<id> is, asked of the cluster -----------------------
  dn="$(prod_node "$dr")"
  if [[ -z "$dn" ]]; then
    log "[$ct] K1: no CT $dr anywhere in the cluster - nothing was left behind"
    log "[$ct]   ct-replica is free to replicate CT $ct again (R13 keys on that config)"
    st_ok "$ct"; return 0
  fi
  dip="${dn#*	}"; dn="${dn%%	*}"
  out="$(probe "$dip" "$dr")"
  if [[ -z "$out" || "$out" == *NOCONFIG* ]]; then
    log "[$ct] GUARD K1: $dn ($dip) did not answer about CT $dr - nothing was changed"
    log "[$ct] GUARD K1:   a node that cannot be asked is a node whose container cannot be"
    log "[$ct] GUARD K1:   put away safely. Same rule as P1."
    st_fail "$ct"; return 1
  fi
  st="$(awk '$1=="STATUS"{print $2; exit}' <<<"$out")"
  log "[$ct] cleanup: CT $dr is on $dn ($dip), ${st:-?}; production CT $ct is ${pst:-unknown}"

  if (( DRY )); then
    log "[$ct] DRY: would stop CT $dr if it were running, move its net lines onto"
    log "[$ct] DRY:   $MOCKNET_BRIDGE and set onboot 0"
    (( DESTROY )) && log "[$ct] DRY: would then destroy CT $dr on $dn"
    st_ok "$ct"; return 0
  fi

  # ---- K3: stopping the one thing that is answering right now -------------
  if [[ "$st" == running ]]; then
    if [[ "$pst" != running ]]; then
      log "[$ct] GUARD K3: CT $dr is RUNNING and production CT $ct is ${pst:-not running}"
      log "[$ct] GUARD K3:   CT $dr is what answers that address at this moment. Stopping it"
      log "[$ct] GUARD K3:   now takes the service down until somebody starts production, and"
      log "[$ct] GUARD K3:   nothing here starts a container - that is a decision with a"
      log "[$ct] GUARD K3:   customer on the other end. Start it, then run this again:"
      log "[$ct] GUARD K3:     ssh root@${pip:-<its node>} pct start $ct"
      st_skip "$ct"; return 1
    fi
    log "[$ct] cleanup: production CT $ct is running, so CT $dr is a second machine on one"
    log "[$ct] cleanup:   address - asking it to stop"
    rsh "$dip" "timeout $((SHUTDOWN_TIMEOUT+30)) pct shutdown $dr --timeout $SHUTDOWN_TIMEOUT"
    out="$(probe "$dip" "$dr")"
    st="$(awk '$1=="STATUS"{print $2; exit}' <<<"$out")"
    if [[ "$st" == running ]]; then
      log "[$ct] cleanup: CT $dr did not come down within ${SHUTDOWN_TIMEOUT}s - nothing forced"
      log "[$ct] cleanup:   its network is left alone too: moving it while it is up would take"
      log "[$ct] cleanup:   a running service off the air without stopping it."
      st_fail "$ct"; return 1
    fi
    log "[$ct] cleanup: CT $dr is stopped on $dn"
  fi

  # ---- step 3: the address, so a reboot cannot put it back on the wire ----
  while read -r _k _n _line; do
    [[ "$_k" == NETLINE ]] || continue
    [[ "$(net_bridge "$_line")" == "$MOCKNET_BRIDGE" ]] && continue
    _line="$(printf '%s' "$_line" | sed -E "s/bridge=[^,]*/bridge=$MOCKNET_BRIDGE/")"
    if ! rsh "$dip" "pct set $dr --$_n '$_line'"; then
      log "[$ct] ERROR: pct set $dr --$_n failed on $dn - CT $dr still holds a live address"
      st_fail "$ct"; return 1
    fi
    _moved="$_moved $_n"
  done <<< "$out"
  rsh "$dip" "pct set $dr --onboot 0" \
    || log "[$ct] WARN: could not set onboot 0 on CT $dr - do it by hand"
  if [[ -n "$_moved" ]]; then
    log "[$ct] cleanup:$_moved moved onto $MOCKNET_BRIDGE, onboot 0 - CT $dr cannot answer again"
  else
    log "[$ct] cleanup: CT $dr was already on $MOCKNET_BRIDGE, onboot 0"
  fi

  # ---- K4 and the destroy ------------------------------------------------
  if (( DESTROY )); then
    if [[ "$st" == running ]]; then
      log "[$ct] GUARD K4: CT $dr is running - not destroying it"
      st_fail "$ct"; return 1
    fi
    if ! rsh "$dip" "pct destroy $dr"; then
      log "[$ct] ERROR: pct destroy $dr failed on $dn - it is stopped and off the wire, so"
      log "[$ct] ERROR:   nothing is at risk; R13 still holds replication for CT $ct."
      st_fail "$ct"; return 1
    fi
    log "[$ct] DESTROYED: CT $dr is gone from $dn"
    log "[$ct]   ct-replica R13 is released: CT $ct is replicated again from tonight."
    st_ok "$ct"; return 0
  fi

  log "[$ct] CT $dr is kept, stopped and unable to answer - the data it served is still"
  log "[$ct]   on $dn if the failback turns out to have missed something."
  log "[$ct]   R13 STILL HOLDS: ct-replica leaves CT $ct's DR copy alone while that config"
  log "[$ct]   exists, so the nightly run keeps reporting it as DR ACTIVE and exiting"
  log "[$ct]   non-zero. That is what protects the copy from before the outage."
  log "[$ct]   when the fallback has stopped being worth that:"
  log "[$ct]     ct-prepare.sh --cleanup --ctid $ct --destroy"
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
  verdict="$(storage_verdict "$statrc" \
               "$(awk '$1=="MOUNTED"{print $2; exit}' <<<"$out")" \
               "$(awk '$1=="ROOTTYPE"{print $2; exit}' <<<"$out")" \
               "$(awk '$1=="ROOTISMP"{print $2; exit}' <<<"$out")")"
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
  local pip="$1" pn out ct sid verdict st _s _l
  declare -a MINE=() DEADSIDS=() DEADPATHS=() DEADMNT=() TOSTOP=()
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
    verdict="$(storage_verdict "$(awk '$1=="STATRC"{print $2; exit}' <<<"$out")" \
                 "$(awk '$1=="MOUNTED"{print $2; exit}' <<<"$out")" \
                 "$(awk '$1=="ROOTTYPE"{print $2; exit}' <<<"$out")" \
                 "$(awk '$1=="ROOTISMP"{print $2; exit}' <<<"$out")")"
    st="$(awk '$1=="STATUS"{print $2; exit}' <<<"$out")"
    if [[ "$verdict" == alive ]]; then
      log "[$pip] E2: CT $ct is on '$sid', which answered - left alone, not touched"
      continue
    fi
    if [[ -z "${SEEN_SID[$sid]:-}" ]]; then
      SEEN_SID[$sid]=1
      DEADSIDS+=("$sid")
      DEADPATHS+=("$(awk '$1=="ROOTPATH"{print $2; exit}' <<<"$out")")
      DEADMNT+=("$(awk '$1=="MOUNTED"{print $2; exit}' <<<"$out")")
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
  # And which containers this is about to stop. They are stopped by an I/O
  # ERROR rather than by a clean shutdown - that is what forcing the mount to
  # fail does - so every one of these images has an ext4 that was aborted
  # mid-write. Writing them down is what lets the way back name them instead of
  # leaving somebody to work out which of two hundred containers were up when
  # the storage died.
  #
  # A SECOND evacuate of the same node - a drill re-run, or a first run that
  # was interrupted - finds those containers already down, so they are not in
  # TOSTOP any more. Rewriting the record from TOSTOP alone would erase the
  # first run's list, and that list is the only record of which images were
  # killed mid-write. The old record's names are carried forward instead.
  declare -a RECSTOP=()
  (( ${#TOSTOP[@]} )) && RECSTOP=("${TOSTOP[@]}")
  local _prev _pv _q
  _prev="$(evac_read "$pip" "$pn")"
  while IFS=$'\t' read -r _s _pv; do
    [[ "$_s" == stopped && -n "$_pv" ]] || continue
    for _q in "${RECSTOP[@]}"; do [[ "$_q" == "$_pv" ]] && continue 2; done
    RECSTOP+=("$_pv")
  done <<< "$_prev"
  for _s in "${RECSTOP[@]}"; do body="$body$(printf '\nstopped\t%s' "$_s")"; done
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
    #
    # A path that is already out of the mount table has nothing to unmount -
    # which is what a SECOND evacuate of the same node finds, because the
    # first one unmounted it. Unmounting it again would fail, and the warning
    # below would tell the operator the stops may hang when they will not.
    if [[ "${DEADMNT[$i]:-1}" == 0 ]]; then
      log "[$pip] ${DEADPATHS[$i]} is already out of the namespace - nothing to unmount"
    elif rsh "$pip" "umount -f -l '${DEADPATHS[$i]}'"; then
      log "[$pip] unmounted ${DEADPATHS[$i]}"
    else
      log "[$pip] WARN: umount -f -l ${DEADPATHS[$i]} did not return 0 - the stops below may hang"
    fi
  done
  rsh "$pip" "systemctl restart pvestatd" \
    && log "[$pip] restarted pvestatd - the node should answer for itself again" \
    || log "[$pip] WARN: could not restart pvestatd - the GUI will stay grey"

  # ---- E4/E5: stop what can be stopped, isolate what cannot ---------------
  local rc sshrc sout=""
  for ct in "${TOSTOP[@]}"; do
    # What `pct shutdown` SAYS is the difference between "the guest ignored
    # us" and "lxc-stop could not even run", and it says it on stdout. It used
    # to go straight to the terminal with no timestamp and no container id
    # next to it - one bare line in the middle of a fleet-wide run, which on
    # the night this was written read as a message about the run rather than
    # about CT 110.
    #
    # THE REMOTE COMMAND REPORTS ITS OWN EXIT CODE ON ITS OWN LINE, which is
    # the shape ct-recall and ct-distribute already use, and this is why: on
    # PVE, `pct` is a perl program that dies, and a perl program that dies
    # exits 255. So does ssh when it cannot reach the host - and for one drill
    # this engine read the first as the second, announced that the node had
    # not answered and that the container "was never asked", and skipped the
    # isolation that is the entire fallback. It was reading pct's own words
    # out of the same run while it said so. Two facts that need different
    # answers cannot share one number.
    # pct hands the actual stopping to `lxc-stop --nokill --timeout 60` - its
    # own default - unless told otherwise, so the grace is passed down or it
    # never reaches the command doing the waiting. The grace is SHORT, and why
    # is written on SHUTDOWN_GRACE itself: the request is a signal that
    # outlives the wait, off the wire is what the DR needs and isolate
    # delivers it in seconds, and every minute spent standing here is a minute
    # the customer's service is down. The outer timeout is thirty seconds
    # longer: it exists only for a pct that never returns at all, and must not
    # fire first and shadow pct's own answer.
    sout="$(rsh "$pip" "timeout $((SHUTDOWN_GRACE+30)) pct shutdown $ct --timeout $SHUTDOWN_GRACE 2>&1; echo __rc=\$?")"
    sshrc=$?
    rc="$(sed -n 's/^__rc=//p' <<<"$sout" | tail -1)"
    while IFS= read -r _l; do
      [[ -n "$_l" && "$_l" != __rc=* ]] && log "[$ct]   pct: $_l"
    done <<< "$sout"
    out="$(probe "$pip" "$ct")"
    st="$(awk '$1=="STATUS"{print $2; exit}' <<<"$out")"
    if [[ "$st" != running ]]; then
      log "[$ct] STOPPED on $pn - it can no longer answer and no longer writes"
      st_ok "$ct"; continue
    fi
    # No line of our own back from the far side is the only thing that means
    # the far side was never reached. Not a number - a silence.
    if [[ -z "$rc" ]]; then
      log "[$ct] ssh to $pn FAILED while asking it to stop (ssh rc=$sshrc) - not CT $ct"
      log "[$ct]   nothing came back, not even the exit code the command was told to print,"
      log "[$ct]   so the container was never asked and nothing here knows its state."
      log "[$ct]   isolating needs the same connection, so it is not attempted either."
      st_fail "$ct"; continue
    fi
    if [[ "$rc" == 124 ]]; then
      log "[$ct] pct itself never returned (rc=124) - isolating CT $ct instead"
      log "[$ct]   it was given ${SHUTDOWN_GRACE}s to run the shutdown and 30 more to say"
      log "[$ct]   how that went, and said nothing. A guest refusing looks different: pct"
      log "[$ct]   reports that in its own words, with an exit code of its own."
    else
      log "[$ct] pct itself failed (rc=$rc) and CT $ct is still running - isolating it instead"
      log "[$ct]   what pct said is above. On this fleet that is usually lxc-stop giving up"
      log "[$ct]   after the ${SHUTDOWN_GRACE}s it was given, on a container whose rootfs is"
      log "[$ct]   a loop device with nothing behind it - and 'pct stop', which kills rather"
      log "[$ct]   than asks, does not return either: the wait is in the block layer, where"
      log "[$ct]   SIGKILL does not go. It may still come down on its own, when the mount's"
      log "[$ct]   outstanding I/O finally errors - or when the storage returns."
    fi
    log "[$ct]   nothing here forces a stop. Taking it off the wire removes the hazard the"
    log "[$ct]   DR actually cares about, and needs nothing from the dead storage."
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
  declare -a SIDS=() STOPPED=()
  while IFS=$'\t' read -r _k _v; do
    [[ "$_k" == disabled ]] && SIDS+=("$_v")
    [[ "$_k" == stopped  ]] && STOPPED+=("$_v")
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
  # What the containers on that storage went through, said once, here, because
  # this is the moment somebody is about to start them again. They were not
  # shut down - they were stopped by their own writes failing, which is what
  # forcing a dead mount to fail does. ext4 aborts the journal, remounts the
  # rootfs read-only, and records the error in the image; the next mount says
  # "Filesystem error recorded from previous mount" and asks for a check. It
  # mounts anyway, which is exactly why nobody notices until it matters.
  if (( ${#STOPPED[@]} )); then
    log "[$pip] the containers this stopped were killed by I/O errors, not by a shutdown:"
    log "[$pip]   ${STOPPED[*]}"
    log "[$pip]   their images have an ext4 that was aborted mid-write. Check each one"
    log "[$pip]   BEFORE starting it, while nothing is using it:"
    log "[$pip]     e2fsck -fy /mnt/pve/<storage>/images/<ctid>/vm-<ctid>-disk-0.raw"
    log "[$pip]   a failback writes INTO that image, so a filesystem with errors is worth"
    log "[$pip]   half an hour now rather than a rebuild later."
  fi
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
    # --isolate as a MODE does one thing more than the function does: it asks
    # the container to stop afterwards, when stopping can work at all. The
    # function itself must not, because --evacuate calls it for containers that
    # have just refused to come down, and asking a second time would wait out
    # the timeout again for an answer it already has.
    if   (( ISOLATE )); then do_isolate "$_ct" && stop_after_isolate "$_ct" || true
    elif (( RESTORE )); then do_restore "$_ct" || true
    elif (( CLEANUP )); then do_cleanup "$_ct" || true
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
if (( CLEANUP )) && (( ok )) && (( ! DESTROY )); then
  log "  the 9<id>s are stopped and off the wire, and still there. While their configs"
  log "  exist ct-replica's R13 holds replication for those containers on purpose."
  log "  when you no longer want the fallback:  ct-prepare.sh --cleanup --all --destroy"
fi
(( failed || skipped )) && exit 1
exit 0
