#!/usr/bin/env bash
# =============================================================================
#  ct-migrate.sh  —  run on the STORAGE-NODE (nfs-server, e.g. pve-r740xd)
# -----------------------------------------------------------------------------
#  Zero-downtime pre-sync of RUNNING LXC CTs into raw images on local ZFS
#  (exported as NFS to the target nodes).
#
#  Also creates the target CT config on the new-node: mirrors the old CT,
#  with the source's real net lines moved onto MOCKNET_BRIDGE (the same
#  island ct-replica.sh uses - same IP, same MAC, no uplink, so nothing can
#  collide) and onboot=0, kept STOPPED. Config is created ONLY after a
#  successful sync (rc 0/24) — never from a failed one. Set MOCKNET=0 in
#  ctmig.conf for the old behaviour (no net lines at all).
#
#  This tool does NOT do cutover. Stopping the old CT, pointing each net
#  line back at its real bridge, starting the new CT - all done by hand.
#  The one exception is --final below, which is a data operation, not a
#  lifecycle one.
#
#  usage:
#    ct-migrate.sh                            all rows, one lane
#    ct-migrate.sh   --storage tank-ssd-nas   only rows on that storage (one lane)
#    ct-migrate.sh   --ctid 251               only that new_ctid
#    ct-migrate.sh   --ctid 251 --final       FINAL delta sync, old CT must be
#                                            stopped; reads it via `pct mount`.
#                                            With no image yet it takes the
#                                            FIRST full copy instead of a
#                                            delta - the one path in for a CT
#                                            that is already down
#                                            because /proc/<pid>/root is gone
#    ct-migrate.sh   --all --final            the announced-window shape: every
#                                            row, final delta each. A row whose
#                                            CT is still running is SKIPPED and
#                                            named, the rest keep moving, and
#                                            the run exits non-zero so the
#                                            stragglers cannot read as done
#    ct-migrate.sh   --dry-run                every guard, every number, no
#                                            write. Not valid with --final.
#
#  tuning lives in ctmig.conf next to this script — NOT in here. Anything this
#  script defines below is only a default.
#
#  what it writes, all next to this script:
#    ../../logs/migrate-<lane>-<date>.log   human log, in ketsync's one tree
#    state/<ctid>.json              machine-readable snapshot, replaced atomically
#    state/<ctid>.runs.jsonl        append-only run history, one JSON per run
#    .sync-<lane>.lock              one run per lane
#    .node-<old_node>.lock          one lane at a time per source node
#  it only READS done/<ctid>.done — that marker is created by a human.
#
#  before any row is touched it checks inventory-migrate.tsv for a CT named twice —
#  the same new_ctid on two rows, or the same old CT (old_node AND old_ctid)
#  on two rows. Either is a refusal: it names the lines and runs nothing.
#  The same old_ctid on two DIFFERENT old nodes is normal and is allowed.
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
#  THE GUARDS (G1..G7)
#  Each one exists because of a real incident on this fleet. The reason is not
#  visible from the code alone, which is exactly why it is written down here.
#  If you refactor this script, keep them and keep their ORDER.
#
#   G1  pool must not sit on the node root filesystem, checked BEFORE alloc;
#       plus: if PVE declares is_mountpoint for it, it must really be mounted.
#       If the ZFS dataset is not mounted, the pool path is just an empty dir
#       on the node root filesystem. pvesm alloc SUCCEEDS, mkfs SUCCEEDS, rsync
#       SUCCEEDS — straight into the root disk until it fills. Checking "does
#       the image exist after alloc" does NOT catch this. Only mountpoint does.
#
#   G2  never sync into a copy that is running on the new-node.
#       Same raw image mounted twice (here via loop, there by the running CT)
#       = ext4 corruption. This is how we got "Structure needs cleaning (117)".
#
#   G3  umount must succeed BEFORE the ENOSPC grow-retry loop, not after.
#       truncate + e2fsck + resize2fs on a still-mounted image is guaranteed
#       corruption. So a failed umount skips the whole CT — no grow, no config.
#       Do not "tidy" this by moving the umount below the retry loop.
#
#   G4  ENOSPC (rc=11) grows the image instead of leaving a half-copy.
#       Source usage is read from a compressed ZFS, so it under-reports what
#       ext4 will need. Bounded retries; then a loud error, never a silent pass.
#
#   G5  config is written only on rsync rc 0 or 24.
#       24 = "files vanished during transfer" and is NORMAL on a live sync
#       (exim4 rewrites its spool constantly). Anything else means the rootfs
#       is incomplete, and a config would invite someone to boot it.
#
#   G6  never overwrite an existing config on the new-node.
#       By the time a config exists, a human may have added net0 to it.
# =============================================================================
set -uo pipefail

# cron hands a script PATH=/usr/bin:/bin, and half of what this tool needs
# lives in sbin: pvesm, zfs, losetup, e2fsck. Interactively as root it all
# works; under cron `pvesm` is simply "command not found" and the empty result
# then looks exactly like a storage that was never configured - which is a
# diagnosis three steps away from the real fault. Set it here so the two cases
# cannot diverge.
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # everything lives next to this script
INV="$BASE/inventory-migrate.tsv"
CONF="$BASE/ctmig.conf"
# Repo shape: the per-site conf lives in conf/ and the work list in
# inventory/, one level up - the same walk-up as nodes.map. A flat tree (the
# simulators build one) keeps both beside the engine. A copy left at the OLD
# home is refused rather than ranked: two files with one name is two places
# to edit, and whichever one this engine did not read is the one somebody
# just edited.
if [[ -f "$BASE/../bin/ketsync" && -f "$BASE/../lib/common.sh" ]]; then
  _ksroot="$(cd "$BASE/.." && pwd)"
  if [[ -e "$CONF" ]]; then
    echo "ERROR: $CONF is the OLD home - the conf moved to conf/ctmig.conf." >&2
    echo "ERROR:   merge any local edits into $_ksroot/conf/ctmig.conf and remove" >&2
    echo "ERROR:   the old file. Two files with one name is how an edit gets lost." >&2
    exit 2
  fi
  if [[ -e "$INV" ]]; then
    echo "ERROR: $INV is the OLD home - the work lists moved to inventory/." >&2
    echo "ERROR:   mv $INV $_ksroot/inventory/inventory-migrate.tsv" >&2
    exit 2
  fi
  CONF="$_ksroot/conf/ctmig.conf"
  INV="$_ksroot/inventory/inventory-migrate.tsv"
fi

# ---------- defaults (override in ctmig.conf, never here) ----------
BW_TOTAL_MB=230          # tool-wide ceiling in MiB/s across ALL lanes (~1.93 Gbps)
LANES=1                  # how many lanes may run at once; each gets TOTAL/LANES
BW_MIN_MB=20             # floor, so a big LANES value cannot starve a transfer
USAGE_FACTOR_PCT=185     # target size = max(old quota, real usage x 1.85)
HEADROOM_PCT=30          # fallback (+% over old quota) when usage cannot be read
GROW_PCT=5               # grow step per ENOSPC retry
GROW_MAX_RETRY=3         # max ENOSPC grow-and-retry attempts per run
POOL_RESERVE_GIB=100     # never alloc if it would eat into this much pool headroom
RUNS_KEEP=200            # per-CT run history kept in state/<ctid>.runs.jsonl
LOG_KEEP_DAYS=30         # daily log files older than this are deleted; 0 disables
MOCKNET=1                # 1 = copy the source's net* onto the island bridge, so
                         # go-live is a bridge swap instead of retyping MAC and IP;
                         # 0 = the old behaviour, no net lines at all
MOCKNET_BRIDGE=vmbr99    # must exist on the NEW node, and have NO uplink (G8)
MNT_BASE=/mnt            # where images are loop-mounted; only moved by the simulator
STORAGE_CFG=/etc/pve/storage.cfg   # read-only, for is_mountpoint; only moved by the simulator
# Cipher list for the rsync transport. OpenSSH negotiates chacha20-poly1305
# first by default; it has no CPU instruction behind it and caps one stream at
# roughly 150-400 MB/s, which is exactly the ceiling a fast pool runs into. The
# AES-GCM ciphers use AES-NI and are typically twice as fast on the same link.
# Empty means "leave ssh to negotiate", if a peer ever refuses this list.
SSH_CIPHERS=aes128-gcm@openssh.com,aes256-gcm@openssh.com,aes128-ctr
# -------------------------------------------------------------------

# ---------- args ----------
LANE_STORAGE=""; ONLY_CTID=""; ALL=0; FINAL=0; DRY=0
# A value-taking flag whose value was lost to a copy-paste used to hang here
# forever: `shift 2` fails when only one argument is left, the old `|| true`
# swallowed that failure, and $# never reached zero. Under cron that is a
# process at 100% CPU that never logs and never dies - a fresh one every tick,
# none of them ever cleaned up. Refuse instead: a missing value is a typo, and
# this repo does not guess what was meant. "$2" is deliberately not "${2:-}",
# so that deleting the check below dies on set -u rather than spinning again.
while (( $# )); do
  case "$1" in
    --storage) [[ $# -ge 2 ]] || { echo "--storage needs a value" >&2; exit 2; }
               LANE_STORAGE="$2"; shift 2;;
    --ctid)    [[ $# -ge 2 ]] || { echo "--ctid needs a value" >&2; exit 2; }
               ONLY_CTID="$2";    shift 2;;
    # Accepted everywhere so one command shape works across all three engines.
    # For a presync it is what happens anyway. For --final it is LOAD-BEARING:
    # the whole-fleet final is real (an announced maintenance window moves
    # every container at once), and it must be asked for out loud - a --final
    # that fell off its --ctid must not quietly become the fleet.
    --all)     ALL=1; shift;;
    # --final, the same word recall and failback use for the same operation:
    # the LAST delta, taken from a source a human has already stopped. This
    # engine spent its first months calling it --stopped - one verb out of
    # five with a private name for the fleet-wide idea - and the old flag is
    # not kept as an alias: one operation, one name, and an unknown flag is
    # refused the same way every other engine refuses one.
    --final) FINAL=1; shift;;
    --dry-run) DRY=1; shift;;
    # Walks the comment block instead of counting lines: a fixed range used to
    # stop short of the exit-code contract, which is the half of the header
    # anything running under cron needs most. Strips the # the way tp does.
    -h|--help) awk 'NR>1{ if (/^#/) { sub(/^#[ ]?/,""); print } else exit }' "${BASH_SOURCE[0]}"; exit 0;;
    *) echo "unknown argument: $1" >&2; exit 2;;
  esac
done
# --final without a scope is refused, not defaulted to the fleet. --ctid picks
# one container; --all is the announced-window shape - every row, final delta
# each, unready rows skipped and named, non-zero at the end. What is NOT
# accepted is a bare --final: it is one lost argument away from either meaning,
# and the two differ by a whole fleet's downtime.
if (( FINAL )) && [[ -z "$ONLY_CTID" ]] && (( ! ALL )); then
  echo "--final needs its scope said out loud: --ctid <new_ctid> for one container, or --all for every row" >&2
  exit 2
fi
# --final exposes the source with `pct mount` on the old node, which is a
# write on somebody else's machine, and without it there is no source to
# compare against - the delta would be invented. A number that is wrong on the
# one run where being wrong costs a cutover window is worse than no number.
if (( FINAL )) && (( DRY )); then
  echo "--final needs 'pct mount' on the old node, which a dry run must not do" >&2
  echo "  dry-run the presync instead:  ct-migrate.sh --ctid $ONLY_CTID --dry-run" >&2
  exit 2
fi

# ---------- config ----------
if [[ -f "$CONF" ]]; then
  # `.` returns the LAST line's status, so a conf with one broken line splashes
  # an error onto the terminal, keeps going, and every value that line was
  # setting silently stays at the engine default - a bandwidth ceiling nobody
  # chose, running against a live fleet. That is the fallback rule again, in
  # disguise: half a conf must not run. The shell's own complaint is kept and
  # shown, because "failed to read" without the line sent somebody to look at
  # file permissions when the problem was a typo on line 1.
  _conferr="$(mktemp "${TMPDIR:-/tmp}/ctmig-conf.XXXXXX")"
  # shellcheck source=/dev/null
  . "$CONF" 2>"$_conferr" || echo "(the shell stopped reading at that point)" >>"$_conferr"
  if [[ -s "$_conferr" ]]; then
    echo "ERROR: $CONF did not read cleanly - NOTHING was run" >&2
    sed 's/^/ERROR:   /' "$_conferr" >&2
    echo "ERROR:   every value a broken line was setting silently stays at the engine" >&2
    echo "ERROR:   default, which is a setting nobody chose. Fix that line and run again." >&2
    rm -f "$_conferr"; exit 2
  fi
  rm -f "$_conferr"
fi
for _v in BW_TOTAL_MB LANES BW_MIN_MB USAGE_FACTOR_PCT HEADROOM_PCT \
          GROW_PCT GROW_MAX_RETRY POOL_RESERVE_GIB RUNS_KEEP LOG_KEEP_DAYS; do
  if [[ ! "${!_v}" =~ ^[0-9]+$ ]]; then
    echo "ctmig.conf: $_v='${!_v}' is not a plain integer" >&2; exit 1
  fi
done
(( LANES >= 1 )) || { echo "ctmig.conf: LANES must be >= 1" >&2; exit 1; }
# not an integer, and it is pasted into a command line unquoted, so it gets the
# only character set a cipher list can legitimately be made of.
if [[ -n "$SSH_CIPHERS" && ! "$SSH_CIPHERS" =~ ^[A-Za-z0-9@.,+-]+$ ]]; then
  echo "ctmig.conf: SSH_CIPHERS='$SSH_CIPHERS' is not a plain cipher list" >&2; exit 1
fi
# Same shapes ct-replica.sh enforces for its own island: the switch is a
# boolean, and the bridge name is pasted into a remote shell snippet unquoted,
# so it gets only the character set an interface name can be made of.
if [[ "$MOCKNET" != 0 && "$MOCKNET" != 1 ]]; then
  echo "ctmig.conf: MOCKNET='$MOCKNET' must be 0 or 1" >&2; exit 1
fi
if [[ ! "$MOCKNET_BRIDGE" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "ctmig.conf: MOCKNET_BRIDGE='$MOCKNET_BRIDGE' is not a plain interface name" >&2; exit 1
fi

# Static split, not dynamic. A lane that computed its share while alone would
# keep that share after a second lane starts, and the two together would break
# the ceiling. Predictable beats optimal when the ceiling is a hard constraint.
_bw=$(( BW_TOTAL_MB / LANES ))
(( _bw < BW_MIN_MB )) && _bw=$BW_MIN_MB
BWLIMIT="${_bw}m"

# ---------- ssh ----------
# keepalives make a dead peer fail in ~3 min instead of hanging forever
# (a hung run holds the lane lock and blocks every later cron run).
SSHOPT_COMMON="-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
-o GSSAPIAuthentication=no -o ServerAliveInterval=30 -o ServerAliveCountMax=6"
# control commands (pct status/config/exec, config write): ~8 short ssh sessions
# per CT, so multiplex them onto one connection per host. Socket lives in /run
# (tmpfs, wiped on boot -> no stale sockets after a crash/reboot).
# The socket path carries this run's pid. Without it two lanes share one mux
# master, and the cleanup loop at the bottom of a lane that finishes first
# tears down the master the other lane is still using - which surfaces several
# minutes later, mid-transfer, as a storage that is suddenly "not active".
# /run is tmpfs, so a crash cannot leave a stale one behind.
SSHOPT="$SSHOPT_COMMON -o ControlMaster=auto -o ControlPath=/run/ctmig-$$-%r@%h.sock -o ControlPersist=120"
# rsync transport: deliberately NOT multiplexed. A multi-hour transfer must not
# share its fate with short control commands (or die with their master process).
# Compression is off explicitly: it defends against a site-wide ssh_config that
# turned it on, where one gzip thread would become the ceiling on a fast link.
SSHOPT_DATA="$SSHOPT_COMMON -o ControlMaster=no -o ControlPath=none -o Compression=no"
[[ -n "$SSH_CIPHERS" ]] && SSHOPT_DATA="$SSHOPT_DATA -c $SSH_CIPHERS"

# ---------- lane identity ----------
# One lane per storage keeps the schedules independent: an HDD lane grinding
# through a 400G CT must not block the SSD lane behind the same lock.
LANE="${LANE_STORAGE:-all}"
(( FINAL )) && LANE="$LANE-final"
LANE="${LANE//[^A-Za-z0-9._-]/_}"

# ---------- where the log goes ----------
# ONE tree for both layers. tp is vendored inside ketsync and has no upstream,
# so the dispatcher is two directories up - but that is CHECKED rather than
# assumed: a tp that has been copied somewhere else, and every simulator
# sandbox, keeps its own logs/ instead of writing outside its own tree. A bad
# night should be one directory to read and one tarball to send, and every file
# in it is named after the verb an operator typed.
LOGDIR="$BASE/logs"
# ../bin/ketsync, ONE level up - the same walk-up the conf and the work list
# use, and it did not always match them: this check counted directories for
# the layout the restructure replaced, when the engines lived two levels deep
# under engines/tp/. At the new depth it never found the dispatcher, so every
# engine quietly kept a second log directory under engines/logs/ while the
# README promised one directory to read - and the promise only broke the day
# somebody went looking for a lane's log in the place it said.
if [[ -f "$BASE/../bin/ketsync" && -f "$BASE/../lib/common.sh" ]]; then
  LOGDIR="$(cd "$BASE/.." && pwd)/logs"
fi

mkdir -p "$LOGDIR" "$LOGDIR/ct" "$BASE/done" "$BASE/state"
# migrate-, not ctmig-: the file is named after the verb an operator typed, the
# way replica-, failback- and distribute- already were. One rule, four engines.
LOG="$LOGDIR/migrate-$LANE-$(date +%F).log"
# One log file per lane per day, forever, on the same pool the images are being
# written into. Prune before opening today's, so the run that finally fills the
# disk is not this one. Only migrate-*.log at depth 1: the other engines and the
# dispatcher keep their own days in this same directory now, and nothing an
# operator parked here is collateral damage either. logs/ct/ is pruned by the
# same clock and the same prefix - a per-CT file is the same day said again.
if (( LOG_KEEP_DAYS > 0 )); then
  find "$LOGDIR" "$LOGDIR/ct" -maxdepth 1 -type f -name 'migrate-*.log' \
       -mtime +"$LOG_KEEP_DAYS" -delete 2>/dev/null || true
fi

# ST_MSG is the headline the state file shows for this CT. It is captured here
# rather than passed around: the FIRST interesting line of an iteration is the
# real reason, every line after it is a how-to-fix hint. First one wins.
# Every tool keeps its own state files. Before this, ct-migrate.sh keyed on
# new_ctid and ct-replica.sh keyed on src_ctid - the SAME number for any CT
# that was migrated here and is now replicated - so the second writer won and
# the first tool's history was gone. Nothing was corrupted and no data moved
# wrongly; what was lost was the ability to look back, which is the whole
# reason the file exists.
ST_PREFIX="migrate-"
ST_MSG=""
# ---------- one container, one file ----------
# The day log above is the lane's narrative: every row, every round, in order.
# CT_LOG is ONE container's copy of the same lines - set when its row starts,
# cleared when it ends - so "what happened to this migration today" is one
# file to open and one file to tail, the way a vzdump task log reads.
# Everything that goes through log() and the rules lands in both files while
# CT_LOG is set, and a row whose turn never printed a line never gets a file.
CT_LOG=""
_tee(){ if [[ -n "$CT_LOG" ]]; then tee -a "$LOG" "$CT_LOG"; else tee -a "$LOG"; fi; }
log(){
  local m="$*"
  [[ -z "$ST_MSG" && "$m" =~ (ERROR|GUARD\ G[0-9]|WARN|HINT|NOTE): ]] && ST_MSG="$m"
  echo "$(date '+%F %T') $m" | _tee
}

# A daily log holds dozens of rounds and dozens of containers. Operations are
# separated by a rule so the eye can find where one ends and the next begins
# without reading timestamps - which is what somebody is actually doing at 2am,
# scrolling for the container that failed. Deliberately no timestamp on the
# rule itself: it is furniture, not an event.
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
hr(){  printf '%s\n' "$LOGSEP"  | _tee; }
hr2(){ printf '%s\n' "$LOGSEP2" | _tee; }
hr3(){ printf '%s\n' "$LOGSEP3" | _tee; }

# The first container opens the block, the rest are separated from the one
# before. The state lives here rather than at the call site, so a loop that
# grows a `continue` on the day somebody adds a guard cannot get it wrong.
HR_CT_SEEN=0
hr_ct(){ if (( HR_CT_SEEN )); then hr3; else hr2; HR_CT_SEEN=1; fi; }

# Byte counts a human reads. Identical in all three engines on purpose - when
# lib/ lands they collapse into one, and a divergence now would make that merge
# a judgement call instead of a deletion.
hsize(){
  local b=${1:-0}
  if   (( b >= 1073741824 )); then printf '%d.%01dGiB' $(( b/1073741824 )) $(( (b%1073741824)*10/1073741824 ))
  elif (( b >= 1048576    )); then printf '%d.%01dMiB' $(( b/1048576 ))    $(( (b%1048576)*10/1048576 ))
  elif (( b >= 1024       )); then printf '%dKiB' $(( b/1024 ))
  else                             printf '%dB' "$b"; fi
}

# --- progress, the way a backup task log reads -------------------------------
# Under cron the transfer used to run silent for however long it took. The
# numbers were already parsed and said in one readable line at the end, but the
# minutes in between were silence: nothing in the log answered "which CT is
# this run on, and how far". This filter sits on rsync's cron-mode output and
# turns it into what a vzdump task log does: one progress line per minute in
# human units - the first update immediately, because "the bytes are moving" is
# what somebody tailing the log is waiting for - rsync's own words (vanished
# files, IO errors) kept verbatim, and the raw --stats byte block dropped,
# because the stats: line already says it in units a person can read.
rs_progress(){  # stdin: rsync stdout+stderr (cron branch). $1 = the CT the lines belong to
  local _ct="$1"
  tr '\r' '\n' | {
    local _start=$SECONDS _last="" _l _b _el
    while IFS= read -r _l; do
      if [[ "$_l" =~ ^[[:space:]]*([0-9][0-9,]*)[[:space:]]+([0-9]+)%[[:space:]]+([0-9.]+[A-Za-z]*B/s) ]]; then
        [[ -n "$_last" ]] && (( SECONDS - _last < 60 )) && continue
        _last=$SECONDS; _b=${BASH_REMATCH[1]//,/}
        _el=$(( SECONDS - _start ))
        if (( _el >= 60 )); then _el="$(( _el / 60 ))m"; else _el="${_el}s"; fi
        log "[$_ct] progress: $(hsize "$_b") (${BASH_REMATCH[2]}%) in $_el at ${BASH_REMATCH[3]}"
      elif [[ -z "$_l" || "$_l" =~ ^(Number\ of|Total\ |Literal\ data|Matched\ data|File\ list|sent\ [0-9,]+\ bytes|total\ size\ is) ]]; then
        :  # the raw --stats block - parsed from the stats file, said once, in units
      else
        log "[$_ct] rsync: $_l"
      fi
    done
  }
}

# A missing binary must say so in one line, instead of surfacing three steps
# later as a wrong diagnosis ("storage unknown" is what a missing pvesm looks
# like from the call site).
#
# This runs BEFORE the lock, and the order is the point. `flock -n 9` on a host
# with no flock is command-not-found, which is a non-zero exit, which is
# indistinguishable from "somebody else holds the lock" - so the engine says it
# is skipping and returns 0. A missing tool producing a green run is the one
# outcome this repo refuses everywhere else, and putting the check that names
# the missing tool AFTER the lock meant it could never fire.
_missing=()
# Local commands only. `pct` and `lxc-info` are run on the OLD node over ssh
# and are not this host's problem; listing them here would refuse a perfectly
# good storage node for not being a compute node.
for _c in pvesm ssh rsync flock mount umount mountpoint findmnt df truncate e2fsck resize2fs mkfs.ext4 mktemp; do
  command -v "$_c" >/dev/null 2>&1 || _missing+=("$_c")
done
if (( ${#_missing[@]} )); then
  log "ERROR: required command(s) not found: ${_missing[*]} - NOTHING was run"
  log "ERROR:   PATH=$PATH"
  log "ERROR:   this script sets PATH itself, so a miss here means the tool is genuinely absent"
  exit 2
fi

exec 9>"$BASE/.sync-$LANE.lock"
if ! flock -n 9; then
  if (( FINAL )); then
    log "lane '$LANE' is busy - a sync is already running; pause the cron for this lane first"
    exit 1
  fi
  log "another sync is running in lane '$LANE' - skip"
  exit 0
fi
# A missing inventory is a deployment mistake, and after a rename it is usually
# THE deployment mistake. This file was called inventory.tsv until the three
# engines moved into one folder, where one generic name for three different
# column layouts was an accident waiting to happen. An install that still has
# the old file gets told exactly what to type rather than "not found", because
# under cron the difference is between a fix tonight and a fortnight of red.
if [[ ! -f "$INV" ]]; then
  log "ERROR: inventory not found: $INV - NOTHING was run"
  if [[ -f "$BASE/inventory.tsv" ]]; then
    log "ERROR:   $BASE/inventory.tsv exists. That is the OLD name for this file."
    log "ERROR:   rename it:  mv $BASE/inventory.tsv $INV"
  else
    log "ERROR:   start from the sample:  cp ${INV%/*}/inventory-migrate.sample.tsv $INV"
  fi
  exit 1
fi

hr
log "lane=$LANE bw=$BWLIMIT (total ${BW_TOTAL_MB}m / $LANES lanes) conf=$([[ -f $CONF ]] && echo yes || echo defaults)$( (( DRY )) && echo " mode=dry-run" )"

# ---------- preflight: the inventory must not name the same CT twice ---------
# Runs before any row is touched, and deliberately BEFORE the --storage/--ctid
# filters: a duplicate is a property of the file, so the verdict must not depend
# on how the run happened to be invoked. It is a refusal, not a per-row skip,
# because the harm is done by the OTHER row and there is no way to tell which of
# the two the operator meant.
#
#   new_ctid twice   both rows resolve to the same image, the same target config
#                    and the same state/<ctid>.json. The second row rsyncs a
#                    different container over the first one's rootfs and the
#                    state file keeps only the winner. This is the one that
#                    destroys a finished copy without anything looking wrong.
#   old CT twice     the same source read twice in one run: double the read load
#                    on the old node and double the bandwidth for a copy that is
#                    thrown away. Always a copy-paste slip.
#
# The source key is old_node PLUS old_ctid, never old_ctid alone. Standalone
# nodes all start numbering at 100, so the same id on two different old nodes is
# two different containers and is entirely normal on this fleet. Flagging that
# would refuse a correct inventory, which is a worse failure than not checking.
preflight_inventory(){
  # keys carry a prefix because a bare '*' or '@' subscript means something else
  # to bash, and a malformed row can put either in a field.
  local -A first_new=() first_src=()
  local -a dups=()
  local ln=0 a b c _rest k
  # only the first three columns matter here; new_node and storage fall into
  # _rest. Splitting is still on whitespace runs, exactly as the main loop
  # splits, so both see the same fields in the same places.
  # `|| [[ -n "$a" ]]` reads a final line that has no trailing newline. Without
  # it read reports EOF and the last row of the file is silently ignored.
  while read -r a b c _rest || [[ -n "${a:-}" ]]; do
    ln=$(( ln + 1 ))
    [[ -z "${a:-}" || "$a" == \#* ]] && continue
    if [[ -n "${c:-}" ]]; then
      k="n:$c"
      if [[ -n "${first_new[$k]:-}" ]]; then
        dups+=("new_ctid $c is on line ${first_new[$k]} and again on line $ln")
      else first_new[$k]=$ln; fi
    fi
    if [[ -n "${b:-}" ]]; then
      # a space is a safe separator: both fields came out of a whitespace split,
      # so neither can contain one, so two different rows cannot share a key.
      k="s:$a $b"
      if [[ -n "${first_src[$k]:-}" ]]; then
        dups+=("old CT $b on $a is on line ${first_src[$k]} and again on line $ln")
      else first_src[$k]=$ln; fi
    fi
  done < "$INV"
  (( ${#dups[@]} )) || return 0
  local d
  log "ERROR: inventory names the same CT more than once - NOTHING was run"
  for d in "${dups[@]}"; do log "ERROR:   $d"; done
  log "ERROR:   two rows sharing a new_ctid write the same image, the same target"
  log "ERROR:   config and the same state file - the second overwrites the first"
  log "ERROR:   (the same old_ctid on two DIFFERENT old nodes is normal and is"
  log "ERROR:   not reported here)"
  log "ERROR: fix $INV, then run again"
  return 1
}
preflight_inventory || exit 2

# ---------- helpers ----------

# size string (8G / 65G / 4.5G / 1T / 512M) -> GiB integer (decimals rounded UP)
to_gib(){
  local raw="$1" s v frac=0
  s="${raw: -1}"; v="${raw%[GgTtMm]}"
  [[ "$v" == *.* ]] && { frac=1; v="${v%%.*}"; }   # 4.5 -> 4 (+1 below)
  [[ "$v" =~ ^[0-9]+$ ]] || v=0
  case "$s" in
    T|t) v=$(( v * 1024 + frac * 512 ));;          # .x of a TiB ~ round up 512G
    M|m) v=$(( (v + 1023) / 1024 + frac ));;
    *)   v=$(( v + frac ));;
  esac
  echo "$v"
}

# --- rsync accounting -------------------------------------------------------
# Filled by run_rsync, consumed by the state file. All bytes, all integers.
#   RS_LITERAL is the one that answers "has the delta converged yet" - it is the
#   data rsync actually had to invent, i.e. what a --final run will cost.
#   RS_WIRE is wire bytes, which is what the bandwidth ceiling is about. It
#   comes off rsync's "Total bytes received" line because THIS ENGINE PULLS:
#   the source is root@<old node>:/..., so the local rsync is the receiver and
#   "Total bytes sent" is the file list and the checksums - a few kilobytes,
#   whatever the size of the container. It read that line for months, so every
#   migration logged wire=3KiB and filed the same into bytes_sent, on the
#   number the bandwidth ceiling is set from. The simulator's fake rsync put
#   the big number on the sent line too, which is how a wrong reading stayed
#   green: the fake was wrong in the same direction as the engine.

_rs_num(){  # $1=BRE for the label, $2=stats file -> the number, commas stripped
  sed -n "s/^$1: *\([0-9,][0-9,]*\).*/\1/p" "$2" 2>/dev/null | tr -d ',' | tail -1
}

run_rsync(){  # $1=src $2=mnt  -> returns rsync rc; progress bar on tty, quiet under cron
  # -x is load-bearing: it stops rsync at the mount boundary, which is what keeps
  # an mp0 volume out of the rootfs image. Without it a CT with a 2T mountpoint
  # would try to fit inside its rootfs image and fail on the first run.
  #
  # --log-file is how the numbers are captured. The obvious way (rsync | tee)
  # would put rsync in a pipeline, stdout stops being a tty, and the
  # --info=progress2 bar a human is watching changes shape. --log-file writes to
  # its own descriptor and touches neither branch below. --log-file-format=
  # (empty on purpose) drops the per-file lines, so the file stays ~16 lines of
  # pure stats even for a 500k-file transfer.
  local sf rc
  sf="$(mktemp "${TMPDIR:-/tmp}/ctmig-stats.XXXXXX" 2>/dev/null)" || sf=""
  local opts=(-aHAX --numeric-ids --sparse -x --delete "--bwlimit=$BWLIMIT"
    '--exclude=/proc/*' '--exclude=/sys/*' '--exclude=/dev/*'
    '--exclude=/run/*' '--exclude=/tmp/*' '--exclude=/lost+found'
    # Not a container path: an intake source on ZFS with snapdir=visible
    # exposes its own snapshot control directory, and without this the whole
    # of that node's retained history would be copied into the new image.
    '--exclude=/.zfs'
    -e "ssh $SSHOPT_DATA")
  [[ -n "$sf" ]] && opts+=(--stats "--log-file=$sf" '--log-file-format=')
  # -n on the shared option array, so both branches below get it. --delete is
  # on this list; without -n a dry run would empty the image it is measuring.
  (( DRY )) && opts+=(-n)
  local t0=$SECONDS
  if [ -t 1 ]; then
    rsync "${opts[@]}" --info=progress2 --no-inc-recursive "$1" "$2"
    rc=$?
  else
    # Same progress under cron that a tty gets, filtered to one line a minute.
    # PIPESTATUS[0] and not $?: the rc G4/G5 judge must be rsync's, never the
    # filter's. $new_ctid is the caller's - bash scoping makes it visible here.
    rsync "${opts[@]}" --info=progress2 --no-inc-recursive "$1" "$2" 2>&1 | rs_progress "$new_ctid"
    rc=${PIPESTATUS[0]}
  fi
  RS_SECS=$(( SECONDS - t0 ))
  RS_FILES=0; RS_LITERAL=0; RS_WIRE=0; RS_TOTAL=0
  if [[ -n "$sf" && -s "$sf" ]]; then
    # '.*' and not '\(regular \)\{0,1\}': a group here would become \1 in
    # _rs_num's sed and steal the capture from the number. rsync <3.1 says
    # "Number of files transferred", >=3.1 says "regular files transferred".
    RS_FILES=$(_rs_num 'Number of .*files transferred' "$sf")
    RS_LITERAL=$(_rs_num 'Literal data' "$sf")
    RS_WIRE=$(_rs_num 'Total bytes received' "$sf")   # this engine PULLS
    RS_TOTAL=$(_rs_num 'Total file size' "$sf")
  fi
  [[ -n "$sf" ]] && rm -f "$sf"
  local _n
  for _n in RS_FILES RS_LITERAL RS_WIRE RS_TOTAL; do
    [[ "${!_n}" =~ ^[0-9]+$ ]] || printf -v "$_n" '%s' 0
  done
  return $rc
}

safe_umount(){  # $1=mnt $2=img -> 0 only when the image is really unmounted
  local m="$1" img="$2" i
  sync
  mountpoint -q "$m" || return 0
  for i in 1 2 3; do
    umount "$m" >>"$LOG" 2>&1 && return 0
    sleep 3
    mountpoint -q "$m" || return 0
  done
  { echo "--- holders of $m ---"; fuser -vm "$m" 2>&1; losetup -j "$img" 2>&1; } >>"$LOG" 2>&1
  return 1
}

# G1 — cached per pool path, because several CTs share one storage
# Which path did PVE promise is an externally managed mount for this storage?
# is_mountpoint is absent, or a boolean, or a PATH - the path form is how you
# declare a storage that lives in a SUBDIRECTORY of a mount, e.g.
#   dir: tank-ssd-nas
#       path /tank-ssd/hosting-ssd
#       is_mountpoint /tank-ssd
# Prints the path that must be mounted, or nothing when nothing was promised.
storage_mountpoint_of(){   # $1=storage id  $2=pool path
  awk -v id="$1" -v pp="$2" '
    /^[a-z]+:[[:space:]]/        { inblk = ($2 == id); next }
    inblk && $1 == "is_mountpoint" {
      v = $2
      if (v == "0" || v == "no" || v == "") print ""
      else if (v == "1" || v == "yes")      print pp
      else                                  print v
      found = 1; exit
    }
    END { if (!found) print "" }
  ' "$STORAGE_CFG" 2>/dev/null
}

declare -A POOL_OK
pool_ready(){   # $1=pool path  $2=storage id
  local p="$1" sid="$2" holder ismp
  case "${POOL_OK[$p]:-}" in 1) return 0;; 0) return 1;; esac

  # --- G1 tier 1 (always): the pool must NOT live on the root filesystem -----
  # THE incident: a dataset failed to mount, its mountpoint stayed an ordinary
  # empty directory on /, and the sync filled the node root. Requiring the pool
  # path to be a mountpoint *itself* would also be wrong, because a dir storage
  # is legitimately allowed to be a subdirectory of a mounted filesystem
  # (e.g. /tank-ssd/hosting-ssd inside an XFS mount at /tank-ssd). So the real
  # invariant is the one this guard was always trying to express: whatever
  # filesystem holds this path, it must not be /.
  if [[ ! -d "$p" ]]; then
    POOL_OK["$p"]=0
    log "GUARD G1: $p does not exist - storage '$sid' points at a path that is not there"
    log "GUARD G1:   check: pvesm status --storage $sid ; grep -A5 \"^dir: $sid\$\" $STORAGE_CFG"
    return 1
  fi
  holder=$(findmnt -no TARGET -T "$p" 2>/dev/null | head -1)
  if [[ -z "$holder" || "$holder" == "/" ]]; then
    POOL_OK["$p"]=0
    log "GUARD G1: $p sits on the ROOT filesystem (holder: ${holder:-unresolvable})"
    log "GUARD G1:   the backing filesystem is not mounted - this is the fill-the-node-root case"
    log "GUARD G1:   check: findmnt -T $p ; zfs get -H -o value mounted <dataset> ; zfs mount <dataset>"
    log "GUARD G1:   refusing to write anything into the node root filesystem"
    return 1
  fi

  # --- G1 tier 2 (only when PVE declares it): honour is_mountpoint -----------
  # If the admin told PVE this path is an externally managed mount, then a path
  # that is merely a directory means the mount failed. Tier 1 cannot see that
  # when the parent pool is mounted but the child dataset is not: the write
  # would land on the parent instead of the node root - less catastrophic, but
  # still not where the data was supposed to go.
  ismp=$(storage_mountpoint_of "$sid" "$p")
  if [[ -n "$ismp" ]]; then
    if ! mountpoint -q "$ismp"; then
      POOL_OK["$p"]=0
      log "GUARD G1: storage '$sid' declares is_mountpoint, but $ismp is NOT a mountpoint"
      log "GUARD G1:   $p currently resolves to $holder instead - the mount did not happen"
      log "GUARD G1:   check: findmnt $ismp ; zfs get -H -o value mounted <dataset> ; zfs mount <dataset>"
      return 1
    fi
  elif ! mountpoint -q "$p"; then
    log "NOTE: $p is not a mountpoint itself; it lives on $holder"
    log "NOTE:   storage '$sid' declares no is_mountpoint, so this is accepted."
    log "NOTE:   to have PVE police it too: pvesm set $sid --is_mountpoint $holder"
  fi
  if [[ ! -d "$p/images" ]]; then
    if (( DRY )); then
      # the only part of G1 a dry run cannot finish: whether the directory is
      # creatable is only knowable by creating it. Say so rather than refuse.
      log "DRY: $p/images does not exist - the real run would create it (first use of this storage)"
    else
      log "NOTE: $p/images did not exist - creating it (first use of this storage)"
      mkdir -p "$p/images" 2>>"$LOG"
    fi
  fi
  if [[ ! -d "$p/images" ]] && (( ! DRY )); then
    POOL_OK["$p"]=0
    log "GUARD G1: $p/images missing and not creatable - skipping this storage"
    return 1
  fi
  POOL_OK["$p"]=1
  return 0
}

# =============================================================================
#  MACHINE-READABLE STATE  —  the data contract for everything that is not this
#  script (the TUI, a dashboard, a monitoring check). Two files per CT, both
#  under state/, both written here and nowhere else:
#
#    state/<new_ctid>.json         current snapshot, replaced atomically
#    state/<new_ctid>.runs.jsonl   append-only history, one JSON object per run
#
#  Why two files. "Has the delta converged yet" cannot be answered from a
#  snapshot: one run reporting 2.3 GB moved means nothing without the run before
#  it. And keeping that history inside the snapshot would mean read-modify-write
#  of a JSON array in bash, which is precisely how a half-written state file
#  gets created. Appending one sub-4KiB line to an O_APPEND fd is atomic; a
#  rewritten array is not.
#
#  Deliberately NOT represented here: done/<ctid>.done. A human creates that
#  marker when a CT has gone live, so a human owns it; this script only reads
#  it. A reader must check the marker itself instead of trusting a field here.
#
#  No jq and no python: Proxmox ships neither, and this has to run on a bare
#  node. Hence the hand-rolled escaper - the one correctness-critical piece in
#  this section, so it is strict rather than clever.
# =============================================================================
SCHEMA_VERSION=1

json_str(){  # any bash string -> a valid, quoted JSON string
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"; s="${s//$'\r'/\\r}"; s="${s//$'\t'/\\t}"
  if [[ "$s" =~ [[:cntrl:]] ]]; then       # rare, but anything left must be \uXXXX
    local out="" i c
    for (( i=0; i<${#s}; i++ )); do
      c="${s:i:1}"
      [[ "$c" =~ [[:cntrl:]] ]] && printf -v c '\\u%04x' "'$c"
      out+="$c"
    done
    s="$out"
  fi
  printf '"%s"' "$s"
}
json_num(){  [[ "${1:-}" =~ ^-?[0-9]+$ ]] && printf '%s' "$1" || printf '0'; }
json_bool(){ [[ "${1:-0}" == 1 ]] && printf 'true' || printf 'false'; }

# per-CT accumulator, reset at the top of every iteration
ST_CTID=""; ST_OLD_CTID=""; ST_OLD_NODE=""; ST_NEW_NODE=""; ST_STORAGE=""
ST_IMG=""; ST_IMG_GIB=0; ST_CFG_PRESENT=0; ST_CFG_SIZE=""; ST_DRIFT=0
ST_STATUS=""; ST_REASON=""; ST_RC=-1; ST_GROW=0; ST_MODE=presync; ST_MP=()
(( FINAL )) && ST_MODE=final

st_reset(){
  ST_CTID=""; ST_OLD_CTID=""; ST_OLD_NODE=""; ST_NEW_NODE=""; ST_STORAGE=""
  ST_IMG=""; ST_IMG_GIB=0; ST_CFG_PRESENT=0; ST_CFG_SIZE=""; ST_DRIFT=0
  ST_STATUS=""; ST_REASON=""; ST_RC=-1; ST_GROW=0; ST_MSG=""; ST_MP=()
  RS_FILES=0; RS_LITERAL=0; RS_WIRE=0; RS_TOTAL=0; RS_SECS=0
}

_st_run_json(){   # one run; goes into .runs.jsonl verbatim and into "last"
  printf '{"ts":%s,"epoch":%s,"lane":%s,"mode":%s,"status":%s,"reason":%s,"message":%s,' \
    "$(json_str "$(date '+%FT%T%z')")" "$(json_num "$(date +%s)")" \
    "$(json_str "$LANE")"      "$(json_str "$ST_MODE")" \
    "$(json_str "$ST_STATUS")" "$(json_str "$ST_REASON")" "$(json_str "$ST_MSG")"
  printf '"rc":%s,"secs":%s,"files":%s,"literal_bytes":%s,"bytes_sent":%s,"total_bytes":%s,"grow_attempts":%s}' \
    "$(json_num "$ST_RC")"     "$(json_num "$RS_SECS")"  "$(json_num "$RS_FILES")" \
    "$(json_num "$RS_LITERAL")" "$(json_num "$RS_WIRE")" "$(json_num "$RS_TOTAL")" \
    "$(json_num "$ST_GROW")"
}

_st_snapshot_json(){
  local mp="" p
  for p in ${ST_MP+"${ST_MP[@]}"}; do mp+="${mp:+,}$(json_str "$p")"; done
  printf '{\n'
  printf '  "schema_version": %s,\n'  "$(json_num "$SCHEMA_VERSION")"
  printf '  "new_ctid": %s,\n'        "$(json_str "$ST_CTID")"
  printf '  "old_ctid": %s,\n'        "$(json_str "$ST_OLD_CTID")"
  printf '  "old_node": %s,\n'        "$(json_str "$ST_OLD_NODE")"
  printf '  "new_node": %s,\n'        "$(json_str "$ST_NEW_NODE")"
  printf '  "storage": %s,\n'         "$(json_str "$ST_STORAGE")"
  printf '  "image": %s,\n'           "$(json_str "$ST_IMG")"
  printf '  "image_size_gib": %s,\n'  "$(json_num "$ST_IMG_GIB")"
  printf '  "config_present": %s,\n'  "$(json_bool "$ST_CFG_PRESENT")"
  printf '  "config_size": %s,\n'     "$(json_str "$ST_CFG_SIZE")"
  printf '  "size_drift": %s,\n'      "$(json_bool "$ST_DRIFT")"
  printf '  "mp_empty": [%s],\n'      "$mp"
  printf '  "last": %s\n'             "$(_st_run_json)"
  printf '}\n'
}

st_write(){   # replace the snapshot atomically - a reader never sees a half file
  [[ -n "$ST_CTID" ]] || return 0
  # A dry run writes no state. Two reasons: it must not overwrite the record
  # of the last REAL run - `tp status` would then show ok for a run that
  # moved nothing - and schema/state.schema.json is closed, so a snapshot
  # with a new mode would fail `make schema-check`.
  (( DRY )) && return 0
  local f="$BASE/state/$ST_PREFIX$ST_CTID.json" t="$BASE/state/.$ST_PREFIX$ST_CTID.json.$$"
  _st_snapshot_json > "$t" 2>/dev/null && mv -f "$t" "$f" 2>/dev/null && return 0
  rm -f "$t" 2>/dev/null
  log "[$ST_CTID] WARN: could not write state file $f"
  return 1
}

st_begin(){   # first write of an iteration, so a reader can see work in flight
  ST_STATUS=running; ST_REASON=""; ST_RC=-1
  st_write
}

st_flush(){   # last write of an iteration, plus exactly one history line
  [[ -n "$ST_CTID" ]] || return 0
  # see st_write: no snapshot and no history line either. ST_CTID is still
  # cleared, so the loop top and the EXIT trap do not try again.
  (( DRY )) && { ST_CTID=""; return 0; }
  [[ -n "$ST_STATUS" ]] || ST_STATUS=ok
  st_write
  local h="$BASE/state/$ST_PREFIX$ST_CTID.runs.jsonl" n
  printf '%s\n' "$(_st_run_json)" >> "$h" 2>/dev/null || true
  # bounded history, trimmed rarely and atomically: at RUNS_KEEP*2 lines it is
  # cut back to RUNS_KEEP, i.e. one rewrite every RUNS_KEEP runs.
  n=$(wc -l < "$h" 2>/dev/null || echo 0)
  if [[ "$n" =~ ^[0-9]+$ ]] && (( n > RUNS_KEEP * 2 )); then
    tail -n "$RUNS_KEEP" "$h" > "$h.tmp.$$" 2>/dev/null \
      && mv -f "$h.tmp.$$" "$h" 2>/dev/null || rm -f "$h.tmp.$$" 2>/dev/null
  fi
  ST_CTID=""    # flushed; the loop top and the EXIT trap must not write it twice
}

# outcome helpers: one call replaces "set the counter, remember the id, and say
# why" at each exit path, so a new exit path cannot forget half of it.
st_fail(){ ST_STATUS=failed;  ST_REASON="$1"; failed=$(( failed + 1 )); FAILED_IDS+=("$ST_CTID"); }
st_skip(){ ST_STATUS=skipped; ST_REASON="$1"; skipped=$(( skipped + 1 )); }
st_ok(){   ST_STATUS=ok;      ST_REASON="";   ok=$(( ok + 1 )); }

# ---------- mock network ------------------------------------------------------
# The source's net lines, verbatim, with ONE edit: the bridge becomes the
# isolated one. hwaddr, ip and the VLAN tag are kept - same reasoning as
# ct-replica.sh's island, where this function came from: same MAC means DHCP
# reservations and MAC-keyed rules still work, and go-live becomes a one-field
# edit (bridge back to the real one) instead of retyping a MAC where one wrong
# character is a whole subnet's ARP gone strange.
#
# stdout of this function IS config text - it is captured into the file being
# written. Nothing here may print anything else, not even through log(). That
# is why the "no bridge=" case is refused up in the main loop (G8), before the
# transfer and before this runs; by the time we are here every line has one.
mocknet_lines(){   # $1 = source config text
  printf '%s\n' "$1" | grep -E '^net[0-9]+:' | while IFS= read -r l; do
    [[ "$l" == *bridge=* ]] || continue     # unreachable: refused in the main loop
    printf '%s\n' "$l" | sed -E "s/bridge=[^,]*/bridge=$MOCKNET_BRIDGE/"
  done
}

# --- G8: the island bridge must exist on the NEW node, and reach no wire ------
# Same question R9 asks of the backup node, asked of every node this run will
# write a config on. The config carries the PRODUCTION IP and MAC on purpose;
# the only thing making that safe is the bridge those lines point at having no
# uplink. Cached per node - a lane with thirty rows onto one target asks once.
# Asked target-side, BEFORE any transfer: a refusal after 80G of rsync is the
# kind of refusal that teaches people to turn a guard off.
declare -A G8_SEEN=()
g8_bridge_ok(){   # $1 = new_node -> 0 ok, 1 refused (already logged)
  (( MOCKNET )) || return 0
  case "${G8_SEEN[$1]:-}" in ok) return 0;; bad) return 1;; esac
  local out
  out=$(ssh $SSHOPT "root@$1" "
    ip -br link show $MOCKNET_BRIDGE >/dev/null 2>&1 || { echo MISSING; exit 0; }
    ports=\$(ovs-vsctl --timeout=5 list-ifaces $MOCKNET_BRIDGE 2>/dev/null || ls /sys/class/net/$MOCKNET_BRIDGE/brif/ 2>/dev/null)
    for p in \$ports; do
      if [ -e /sys/class/net/\$p/device ] || [ -d /sys/class/net/\$p/bonding ]; then echo \"UPLINK \$p\"; fi
    done
    echo OK
  " </dev/null 2>/dev/null)
  if [[ "$out" == *MISSING* ]]; then
    log "GUARD G8: bridge $MOCKNET_BRIDGE does not exist on $1 - its rows are skipped"
    log "GUARD G8:   create it there (isolated island, NO uplink) - see the setup guide -"
    log "GUARD G8:   or set MOCKNET=0 in ctmig.conf to migrate with no network at all"
    G8_SEEN[$1]=bad; return 1
  fi
  if [[ "$out" != *OK* ]]; then
    log "GUARD G8: cannot inspect $MOCKNET_BRIDGE on $1 (ssh failed?) - its rows are skipped"
    G8_SEEN[$1]=bad; return 1
  fi
  if [[ "$out" == *UPLINK* ]]; then
    log "GUARD G8: $MOCKNET_BRIDGE on $1 HAS AN UPLINK - its rows are skipped"
    printf '%s\n' "$out" | grep UPLINK | while read -r _ p; do
      log "GUARD G8:   port '$p' is a physical NIC or a bond"
    done
    log "GUARD G8:   the config this would write carries the PRODUCTION IP and MAC;"
    log "GUARD G8:   the only thing making that safe is this bridge reaching no wire"
    G8_SEEN[$1]=bad; return 1
  fi
  G8_SEEN[$1]=ok; return 0
}

# What the config write WOULD do, printed where the real run would reach it.
# The probe is G6's own check and is read-only, so a dry run makes it for real
# - the answer is half the plan. Only the write below it is skipped.
dry_cfg_plan(){   # $1=ctid $2=new_node $3=storage $4=image size
  local cfgsize
  if ssh $SSHOPT "root@$2" "test -f /etc/pve/lxc/$1.conf" </dev/null 2>/dev/null; then
    cfgsize=$(ssh $SSHOPT "root@$2" "grep '^rootfs:' /etc/pve/lxc/$1.conf" </dev/null 2>/dev/null \
              | sed -n 's/.*size=\([^,]*\).*/\1/p')
    log "[$1] DRY: a config already exists on $2 - G6 would leave it untouched (size=${cfgsize:-?})"
    [[ -n "$cfgsize" && -n "$4" && "$cfgsize" != "$4" ]] \
      && log "[$1] DRY:   it disagrees with the image ($4); the real run would report the drift"
  else
    log "[$1] DRY: would create /etc/pve/lxc/$1.conf on $2:"
    log "[$1] DRY:   rootfs: $3:$1/vm-$1-disk-0.raw,size=$4"
    if (( MOCKNET )); then
      log "[$1] DRY:   onboot: 0, net kept from the source, moved onto $MOCKNET_BRIDGE:"
      while IFS= read -r _nl; do
        [[ -n "$_nl" ]] && log "[$1] DRY:     $_nl"
      done <<< "$(mocknet_lines "$oldcfg")"
      log "[$1] DRY:   at go-live: point each line back at its real bridge, then start it"
    else
      log "[$1] DRY:   onboot: 0, and no net line - you add net0 by hand at go-live"
    fi
  fi
  return 0
}

# --- one lane at a time per SOURCE node --------------------------------------
# Lanes are per storage, on purpose. Nothing stops two storages from holding CTs
# that live on the SAME old node, and then two lanes read that one node at once:
# its disks give half the throughput to each, and a bandwidth budget that was
# split per lane is suddenly doubled against a single source. So the source node
# gets its own lock. Non-blocking on purpose: a lane that cannot have the node
# right now moves on to its next row instead of sitting on the lane lock (and
# its share of the bandwidth) waiting. The next cron run picks the CT up.
NODE_LOCK=""
take_node_lock(){   # $1=old_node -> 0 when this run owns that node
  local key="${1//[^A-Za-z0-9._-]/_}"
  exec 8>"$BASE/.node-$key.lock" 2>/dev/null || return 1
  if flock -n 8; then NODE_LOCK="$1"; return 0; fi
  exec 8>&-
  return 1
}
release_node_lock(){  # closing the fd is what drops the flock
  [[ -n "$NODE_LOCK" ]] || return 0
  exec 8>&-
  NODE_LOCK=""
}

# --final mounts the source CT on the old node; it must come back down on
# EVERY exit path, including the ones that `continue` out of the loop.
SRC_MOUNT_NODE=""; SRC_MOUNT_CT=""
cleanup_src(){
  [[ -n "$SRC_MOUNT_NODE" ]] || return 0
  ssh $SSHOPT "root@$SRC_MOUNT_NODE" "pct unmount $SRC_MOUNT_CT" </dev/null >>"$LOG" 2>&1 \
    || log "WARN: pct unmount $SRC_MOUNT_CT on $SRC_MOUNT_NODE failed - check it by hand"
  SRC_MOUNT_NODE=""; SRC_MOUNT_CT=""
}

# The LOCAL loop-mount has to come down on every exit path too, and this is the
# dangerous one. Ctrl-C during a multi-hour rsync kills the child; bash then runs
# the EXIT trap and the line after the child never executes, so nothing else can
# unmount it. The image stays mounted HERE, on the storage node, invisible - and
# the next thing that happens is an operator starting that CT on the new node,
# which mounts the same filesystem a second time and destroys it.
MY_MNT=""; MY_IMG=""
arm_mnt(){   MY_MNT="$1"; MY_IMG="$2"; }
disarm_mnt(){ MY_MNT=""; MY_IMG=""; }
cleanup_mnt(){
  [[ -n "$MY_MNT" ]] || return 0
  local m="$MY_MNT" i="$MY_IMG"
  disarm_mnt
  safe_umount "$m" "$i" \
    || log "WARN: $m is STILL MOUNTED - do NOT boot this CT until it is down"
}

# every exit path, including a kill: unmount the image, unmount the source, drop
# the node lock, and record what happened. A CT still marked "running" here was
# interrupted, and saying so beats leaving a state file that claims a sync is
# still in progress.
end_iteration(){
  cleanup_mnt
  cleanup_src
  release_node_lock
  [[ "$ST_STATUS" == running ]] && { ST_STATUS=interrupted; ST_REASON=interrupted; }
  st_flush
  CT_LOG=""                     # this row's turn is over; the file stays
}
trap end_iteration EXIT
# Ctrl-C must end the RUN, not just the copy. Under cron rsync sits in a
# pipeline with the progress filter, and when the filter - the last element -
# exits cleanly, bash treats a SIGINT that killed rsync as handled and carries
# on to the next CT. This trap makes the interrupt mean what the person who
# sent it meant: the run stops, the EXIT trap cleans up, and 130 says why.
# Deferred by bash until the foreground job ends, so nothing is torn down
# under a live rsync - exactly the old behaviour, now stated instead of
# inherited from how bash happens to treat a child that died of SIGINT.
trap 'exit 130' INT

ok=0; skipped=0; frozen=0; failed=0
matched=0            # rows that survived --storage/--ctid; 0 means the flag is wrong
FAILED_IDS=()

# inventory columns (ALL required):
#   old_node  old_ctid  new_ctid  new_node  storage        (# = comment)
# The `|| [[ -n ... ]]` is what makes a last line with no trailing newline count
# as a row; plain `read` calls it EOF and drops it. preflight_inventory reads the
# file the same way, so both see exactly the same set of rows.
while read -r old_node old_ctid new_ctid new_node storage _rest <&3 \
      || [[ -n "${old_node:-}" ]]; do
  end_iteration          # closes out the PREVIOUS row: unmount, unlock, write state
  st_reset
  [[ -z "${old_node:-}" || "$old_node" == \#* ]] && continue

  if [[ -z "${new_node:-}" || -z "${storage:-}" ]]; then
    # no state file for this one: without a complete row there is nothing to key
    # it on, and a reader parsing inventory-migrate.tsv can see the broken row itself.
    log "[${new_ctid:-?}] ERROR: row is incomplete (need old_node old_ctid new_ctid new_node storage) - skip"
    log "[${new_ctid:-?}] ERROR:   four-column rows are from the old format; run tools/add-storage-column.sh"
    failed=$(( failed + 1 )); FAILED_IDS+=("${new_ctid:-?}"); continue
  fi

  # lane / single-CT filters
  [[ -n "$LANE_STORAGE" && "$storage" != "$LANE_STORAGE" ]] && continue
  [[ -n "$ONLY_CTID"    && "$new_ctid" != "$ONLY_CTID"   ]] && continue
  # counted BEFORE the .done check on purpose: a frozen CT is a row the flag
  # matched, so a lane whose CTs are all finished is not a typo.
  matched=$(( matched + 1 ))

  if [[ -f "$BASE/done/$new_ctid.done" ]]; then                 # frozen: finished / live
    # deliberately no state write: the .done marker is human-owned and this run
    # did nothing, so overwriting the last real snapshot would destroy history.
    frozen=$(( frozen + 1 )); continue
  fi

  # from here on the row is one this run intends to work on, so it gets a state
  # file. ST_CTID being set is what arms st_write/st_flush.
  ST_CTID="$new_ctid"; ST_OLD_CTID="$old_ctid"; ST_OLD_NODE="$old_node"
  ST_NEW_NODE="$new_node"; ST_STORAGE="$storage"
  # From here every line of this row's turn is said twice: once into the
  # lane's day log, once into this CT's own day file under logs/ct/.
  CT_LOG="$LOGDIR/ct/migrate-$new_ctid-$(date +%F).log"
  # The rule goes here, not further down: a guard that refuses this row has
  # to print INSIDE the block that names the row, or the reader is left with
  # a GUARD line and no idea which migration it belonged to.
  hr_ct
  log "[$new_ctid] CT $old_ctid on $old_node  ->  CT $new_ctid on $new_node, storage '$storage'"

  # --- resolve the image path from PVE itself, per row ---
  # pvesm path computes it from the storage config even before the file exists,
  # so there is no hand-maintained pool path to drift. A non-dir storage (lvm,
  # zfspool...) returns something that is not */images/*, and is rejected here:
  # this tool loop-mounts a raw FILE, it cannot work on a block-backed storage.
  IMG=$(pvesm path "$storage:$new_ctid/vm-$new_ctid-disk-0.raw" 2>>"$LOG") || IMG=""
  if [[ -z "$IMG" || "$IMG" != /*/images/* ]]; then
    log "[$new_ctid] ERROR: storage '$storage' unknown here, or not a file/dir storage (got: '${IMG:-none}') - skip"
    log "[$new_ctid] ERROR:   expected a dir storage: pvesm add dir $storage --path <dataset> --is_mountpoint yes"
    st_fail storage_unknown; continue
  fi
  ST_IMG="$IMG"
  POOLPATH="${IMG%/images/*}"
  if ! pool_ready "$POOLPATH" "$storage"; then
    log "[$new_ctid] ERROR: storage '$storage' ($POOLPATH) not usable - skip"
    st_fail g1_pool; continue
  fi
  MNT="$MNT_BASE/ctmig-$new_ctid"

  # --- G2: never touch a copy that is already running on the new-node ---
  newstat=$(ssh $SSHOPT "root@$new_node" "pct status $new_ctid 2>/dev/null" </dev/null 2>/dev/null || true)
  if [[ "$newstat" == *running* ]]; then
    log "[$new_ctid] GUARD G2: copy is RUNNING on $new_node - skip resync (double mount = corruption)"
    st_skip g2_running; continue
  fi

  # --- G7: the new_ctid must be free, or already be OUR copy ---
  # G2 only sees a running CT. The quiet disaster is a STOPPED one that already
  # owns this id: if its rootfs happens to be this exact volid the image below is
  # not allocated (it exists), and rsync --delete then empties somebody else's
  # container into ours. A typo of one digit in inventory-migrate.tsv is all it takes.
  # A config with no rootfs: line at all is a truncated write from an earlier run
  # - refuse that too, because G6 will never rewrite it and it can never boot.
  if ssh $SSHOPT "root@$new_node" "test -f /etc/pve/lxc/$new_ctid.conf" </dev/null 2>/dev/null; then
    exist_root=$(ssh $SSHOPT "root@$new_node" "cat /etc/pve/lxc/$new_ctid.conf" </dev/null 2>/dev/null \
                 | sed -n 's/^rootfs:[[:space:]]*\([^,]*\).*/\1/p' | head -1)
    if [[ "$exist_root" != "$storage:$new_ctid/vm-$new_ctid-disk-0.raw" ]]; then
      log "[$new_ctid] GUARD G7: CT id $new_ctid on $new_node already belongs to something else"
      log "[$new_ctid] GUARD G7:   its config says rootfs = '${exist_root:-<none: the config is truncated>}'"
      log "[$new_ctid] GUARD G7:   this row wants  rootfs = '$storage:$new_ctid/vm-$new_ctid-disk-0.raw'"
      log "[$new_ctid] GUARD G7:   syncing anyway would overwrite that container - pick a free new_ctid in"
      log "[$new_ctid] GUARD G7:   $INV, or remove the stale config on $new_node by hand"
      st_fail g7_ctid_taken; continue
    fi
  fi

  # --- the same storage id must resolve on the target too, or the config we
  #     write later points at a volume the new node cannot see. Cheap to check
  #     now, expensive to discover after a 400G transfer. ---
  tgtst=$(ssh $SSHOPT "root@$new_node" "pvesm status --storage $storage" </dev/null 2>/dev/null || true)
  if ! printf '%s\n' "$tgtst" | awk 'NR>1 && $3=="active"{f=1} END{exit !f}'; then
    log "[$new_ctid] ERROR: storage '$storage' is not active on $new_node - skip"
    log "[$new_ctid] ERROR:   add it there as NFS with the SAME id:"
    log "[$new_ctid] ERROR:   pvesm add nfs $storage --server <storage-node> --export <export> --content images,rootdir"
    st_fail storage_inactive; continue
  fi

  # --- take the source node, or leave it to the lane that already has it ---
  # Everything above this line is local or target-side. This is the first thing
  # that touches the old node, so it is the right place to serialise on it.
  if ! take_node_lock "$old_node"; then
    log "[$new_ctid] NOTE: source node $old_node is busy in another lane - skip (next run picks it up)"
    st_skip node_busy; continue
  fi

  # --- reachability + source state (clear, distinct reasons) ---
  if ! ssh $SSHOPT "root@$old_node" true </dev/null 2>/dev/null; then
    log "[$new_ctid] SSH to $old_node FAILED (key not set up / host down) - skip"
    st_fail ssh_old_node; continue
  fi
  oldcfg=$(ssh $SSHOPT "root@$old_node" "pct config $old_ctid" </dev/null 2>/dev/null || true)
  if [[ -z "$oldcfg" ]]; then
    log "[$new_ctid] CT $old_ctid NOT FOUND on $old_node (wrong id/node?) - skip"
    st_fail ct_not_found; continue
  fi

  # --- G8, both halves, BEFORE any transfer ----------------------------------
  # The lines this run will write are decided here, not at the config step: a
  # net line with no bridge= cannot be moved onto the island, and silently
  # dropping it would hand go-live a CT that answers on fewer interfaces than
  # production did - the miss nobody notices until a customer does.
  if (( MOCKNET )); then
    badnet=$(printf '%s\n' "$oldcfg" | grep -E '^net[0-9]+:' | grep -v 'bridge=' || true)
    if [[ -n "$badnet" ]]; then
      log "[$new_ctid] GUARD G8: net line(s) with no bridge= in CT $old_ctid's config:"
      while IFS= read -r _bl; do [[ -n "$_bl" ]] && log "[$new_ctid] GUARD G8:   $_bl"; done <<< "$badnet"
      log "[$new_ctid] GUARD G8:   fix the source config, or set MOCKNET=0 to migrate with no network"
      st_fail g8_nobridge; continue
    fi
    if ! g8_bridge_ok "$new_node"; then
      st_fail g8_bridge; continue
    fi
  fi

  # --- pick the source: running CT via /proc, or stopped CT via pct mount ---
  if (( FINAL )); then
    st=$(ssh $SSHOPT "root@$old_node" "pct status $old_ctid" </dev/null 2>/dev/null || true)
    if [[ "$st" != *stopped* ]]; then
      log "[$new_ctid] ERROR: --final needs CT $old_ctid on $old_node to be stopped (got: ${st:-unknown})"
      log "[$new_ctid] ERROR:   stop it yourself first - this tool does not touch CT lifecycle"
      st_fail not_stopped; continue
    fi
    if ! ssh $SSHOPT "root@$old_node" "pct mount $old_ctid" </dev/null >>"$LOG" 2>&1; then
      log "[$new_ctid] ERROR: pct mount $old_ctid failed on $old_node - skip"
      st_fail pct_mount; continue
    fi
    SRC_MOUNT_NODE="$old_node"; SRC_MOUNT_CT="$old_ctid"
    SRC="root@$old_node:/var/lib/lxc/$old_ctid/rootfs/"
    # With no image yet this is the FIRST copy, not a delta - and that is a
    # legitimate ask, not a misuse. --final used to refuse it and send the
    # operator to presync, which refuses a stopped container right back: a CT
    # that is already down - decommissioned, or shut down for exactly this
    # move - had no path into the fleet at all, and the two refusals pointed
    # at each other. The alloc/mkfs/grow machinery below has never cared where
    # the source bytes come from, so nothing else changes; a full copy from a
    # stopped CT is also the most consistent read this engine can ever get,
    # because the application closed its own files.
    if [[ ! -f "$IMG" ]]; then
      log "[$new_ctid] FIRST full copy from a STOPPED CT (pct mount) <= $old_node:$old_ctid"
      log "[$new_ctid]   no image yet, so this is the whole rootfs, not a delta - and it is"
      log "[$new_ctid]   application-consistent: the CT was down before anything was read"
    else
      log "[$new_ctid] FINAL delta from a STOPPED CT (pct mount) <= $old_node:$old_ctid"
    fi
  else
    ctpid=$(ssh $SSHOPT "root@$old_node" "lxc-info -n $old_ctid -p -H" </dev/null 2>/dev/null || true)
    if [[ -z "${ctpid:-}" || "$ctpid" == 0 ]]; then
      log "[$new_ctid] CT $old_ctid on $old_node is not running (start it first) - skip"
      st_fail not_running; continue
    fi
    SRC="root@$old_node:/proc/$ctpid/root/"
  fi

  # --- alloc + mkfs once. Sizing only matters when there is no image yet, so
  #     a resync costs one ssh round trip less than it used to. ---
  if [[ ! -f "$IMG" ]]; then
    # usage is read from inside the running CT; on compressed ZFS df shows the
    # COMPRESSED usage, so the factor covers typical lz4 ratios on ext4.
    oldsize=$(printf '%s\n' "$oldcfg" | awk -F'size=' '/^rootfs:/{print $2}' | awk -F, '{print $1}')
    [[ -z "$oldsize" ]] && { log "[$new_ctid] WARN: cannot read rootfs size, defaulting 8G"; oldsize=8G; }
    quota_gib=$(to_gib "$oldsize")
    # A running CT answers from inside itself; a stopped one cannot run pct
    # exec at all, but by this point --final has already pct-mounted it, so
    # its own filesystem answers from the outside. Without this branch every
    # first copy from a stopped CT fell back to quota+headroom - 40G allocated
    # for 1G of data, silently, per container.
    if (( FINAL )); then
      usedb=$(ssh $SSHOPT "root@$old_node" "df -B1 -P /var/lib/lxc/$old_ctid/rootfs" </dev/null 2>/dev/null \
              | awk 'NR==2{print $3}')
    else
      usedb=$(ssh $SSHOPT "root@$old_node" "pct exec $old_ctid -- df -B1 -P /" </dev/null 2>/dev/null \
              | awk 'NR==2{print $3}')
    fi
    if [[ "$usedb" =~ ^[0-9]+$ && "$usedb" -gt 0 ]]; then
      used_gib=$(( (usedb + 1073741823) / 1073741824 ))
      need_gib=$(( (used_gib * USAGE_FACTOR_PCT + 99) / 100 ))
      size_gib=$(( quota_gib > need_gib ? quota_gib : need_gib ))
      log "[$new_ctid] size: quota=${quota_gib}G used=${used_gib}G x${USAGE_FACTOR_PCT}% -> alloc ${size_gib}G"
    else
      size_gib=$(( (quota_gib * (100 + HEADROOM_PCT) + 99) / 100 ))
      log "[$new_ctid] size: cannot read usage, fallback quota+${HEADROOM_PCT}% -> alloc ${size_gib}G"
    fi

    availb=$(df -B1 --output=avail "$POOLPATH" 2>/dev/null | awk 'NR==2{print $1}')
    if [[ "$availb" =~ ^[0-9]+$ ]]; then
      avail_gib=$(( availb / 1073741824 ))
      if (( avail_gib < size_gib + POOL_RESERVE_GIB )); then
        log "[$new_ctid] ERROR: pool free ${avail_gib}G < need ${size_gib}G + reserve ${POOL_RESERVE_GIB}G - skip"
        st_fail pool_space; continue
      fi
    else
      log "[$new_ctid] WARN: cannot read free space on $POOLPATH - skipping the precheck"
    fi

    if (( DRY )); then
      # There is no image, so there is nothing to loop-mount and nothing for
      # rsync -n to compare against. Running it anyway would rsync into an
      # unmounted directory, which is the exact incident G1 exists for and
      # which the simulator records as a violation. Report and stop here.
      log "[$new_ctid] DRY: would alloc ${size_gib}G on '$storage' and mkfs.ext4 $IMG"
      log "[$new_ctid] DRY: first sync - the whole rootfs would transfer from $SRC"
      dry_cfg_plan "$new_ctid" "$new_node" "$storage" "${size_gib}G"
      log "[$new_ctid] dry-run - nothing was written"
      st_ok; continue
    fi
    log "[$new_ctid] alloc ${size_gib}G on '$storage' + mkfs.ext4"
    if ! pvesm alloc "$storage" "$new_ctid" "vm-$new_ctid-disk-0.raw" "${size_gib}G" --format raw >>"$LOG" 2>&1; then
      log "[$new_ctid] ERROR: pvesm alloc failed on '$storage' - see the rsync log above - skip"
      st_fail alloc_failed; continue
    fi
    # An unchecked mkfs leaves a zero-filled image that looks perfectly fine to
    # every later check, and the loop-mount below is where it finally shows up.
    # Say it here, where the fix is still one command.
    if ! mkfs.ext4 -F -m0 "$IMG" >>"$LOG" 2>&1; then
      log "[$new_ctid] ERROR: mkfs.ext4 failed on $IMG - the image has no filesystem"
      log "[$new_ctid] ERROR:   remove it and run again: pvesm free $storage:$new_ctid/vm-$new_ctid-disk-0.raw"
      st_fail mkfs_failed; continue
    fi
  fi

  # never rsync into an unmounted dir (alloc/mkfs failed, wrong storage id,
  # missing image...) — otherwise the whole CT lands on the node root fs.
  if [[ ! -f "$IMG" ]]; then
    log "[$new_ctid] ERROR: image missing after alloc ($IMG) - check storage '$storage' / free space - skip"
    st_fail alloc_failed; continue
  fi
  ST_IMG_GIB=$(( ( $(stat -c%s "$IMG" 2>/dev/null || echo 0) + 1073741823 ) / 1073741824 ))

  # --- loop-mount the local image and pull the rootfs ---
  mkdir -p "$MNT"
  # A dry run mounts read-only, so rsync -n can measure the delta without the
  # journal replay a read-write mount performs. Same rule as ct-replica.sh R6.
  MOPT=loop; (( DRY )) && MOPT=loop,ro,noload
  if ! mountpoint -q "$MNT"; then
    if ! mount -o "$MOPT" "$IMG" "$MNT" >>"$LOG" 2>&1; then
      log "[$new_ctid] ERROR: loop-mount failed ($IMG) - skip"
      st_fail loop_mount; continue
    fi
  fi
  arm_mnt "$MNT" "$IMG"         # from here a kill must still bring it back down
  log "[$new_ctid] rsync <= $SRC"
  log "[$new_ctid]    into  $IMG (${ST_IMG_GIB}G) on '$storage', mounted at $MNT"
  log "[$new_ctid]    target $new_node, bw=$BWLIMIT, mode=$( (( FINAL )) && echo final || echo presync )"
  st_begin                      # publish "in flight" before the long part starts
  run_rsync "$SRC" "$MNT/"; rc=$?
  ST_RC=$rc

  # --- G3: umount MUST succeed before anything else touches the image ---
  # A still-mounted image must never reach the grow-retry loop below:
  # truncate/e2fsck/resize2fs on a mounted filesystem corrupts it.
  safe_umount "$MNT" "$IMG"; um=$?
  disarm_mnt                    # G3 owns the outcome now; the trap must not retry
  if (( um )); then
    log "[$new_ctid] GUARD G3: umount $MNT FAILED - image left mounted; skipping this CT entirely"
    log "[$new_ctid] GUARD G3:   (no grow-retry, no config - never resize a mounted image)"
    log "[$new_ctid] GUARD G3:   fix: fuser -vm $MNT ; umount $MNT ; losetup -j $IMG ; losetup -d <loopN>"
    st_fail g3_umount; continue
  fi

  # a grow-retry is still one run, so its transfers add up rather than replace
  # each other; total_bytes is a property of the dataset, so it does not.
  acc_files=$RS_FILES; acc_lit=$RS_LITERAL; acc_wire=$RS_WIRE; acc_secs=$RS_SECS

  # --- G4: ENOSPC (rc=11) -> grow by GROW_PCT and retry, bounded ---
  attempt=0; umount_broke=0
  while [[ $rc -eq 11 && $attempt -lt $GROW_MAX_RETRY ]] && (( ! DRY )); do
    attempt=$(( attempt + 1 ))
    cur=$(stat -c%s "$IMG")
    new=$(( cur / 100 * (100 + GROW_PCT) ))
    log "[$new_ctid] ENOSPC - grow attempt $attempt/$GROW_MAX_RETRY: $(( cur/1024/1024/1024 ))G -> $(( new/1024/1024/1024 ))G, retrying"
    truncate -s "$new" "$IMG"
    e2fsck -fp "$IMG" >>"$LOG" 2>&1
    resize2fs "$IMG"  >>"$LOG" 2>&1
    if ! mount -o loop "$IMG" "$MNT" >>"$LOG" 2>&1; then
      log "[$new_ctid] ERROR: loop-mount failed during grow-retry - abort retries"; break
    fi
    arm_mnt "$MNT" "$IMG"
    run_rsync "$SRC" "$MNT/"; rc=$?
    ST_RC=$rc
    acc_files=$(( acc_files + RS_FILES )); acc_lit=$(( acc_lit + RS_LITERAL ))
    acc_wire=$(( acc_wire + RS_WIRE ));    acc_secs=$(( acc_secs + RS_SECS ))
    safe_umount "$MNT" "$IMG"; um=$?
    disarm_mnt
    if (( um )); then
      log "[$new_ctid] GUARD G3: umount $MNT FAILED after grow-retry - image left mounted"
      log "[$new_ctid] GUARD G3:   fix: fuser -vm $MNT ; umount $MNT ; losetup -j $IMG ; losetup -d <loopN>"
      umount_broke=1; break
    fi
  done
  ST_GROW=$attempt
  RS_FILES=$acc_files; RS_LITERAL=$acc_lit; RS_WIRE=$acc_wire; RS_SECS=$acc_secs
  ST_IMG_GIB=$(( ( $(stat -c%s "$IMG" 2>/dev/null || echo 0) + 1073741823 ) / 1073741824 ))
  if [[ $umount_broke -eq 1 ]]; then
    log "[$new_ctid] skipping this CT entirely (no further resize, no config)"
    st_fail g3_umount; continue
  fi
  if [[ $rc -eq 11 ]]; then
    log "[$new_ctid] ERROR: still out of space after $GROW_MAX_RETRY grow attempts - fix manually:"
    log "[$new_ctid] ERROR:   1) check real data size on the old CT (du -shx inside it)"
    log "[$new_ctid] ERROR:   2) grow the image yourself: truncate -s <SIZE>G $IMG ; e2fsck -fp $IMG ; resize2fs $IMG"
    log "[$new_ctid] ERROR:   3) run ct-migrate.sh again"
  fi
  # "synced" was said here unconditionally, rc included - so a run somebody
  # interrupted printed "rootfs synced (rsync rc=255)" one line above the
  # guard that refused it, and the two lines argued with each other.
  if [[ $rc -eq 0 || $rc -eq 24 ]]; then
    log "[$new_ctid] rootfs synced (rsync rc=$rc)"
  else
    log "[$new_ctid] rsync did NOT finish (rc=$rc) - the image holds a partial copy"
  fi
  # changed= is the convergence metric: it should fall round over round, and
  # when it stops falling the CT is ready to cut over. It was only ever
  # written to state/<ctid>.json, where nobody watching a migration looks.
  log "[$new_ctid] stats: files=${RS_FILES:-0} changed=$(hsize "${RS_LITERAL:-0}") wire=$(hsize "${RS_WIRE:-0}") of $(hsize "${RS_TOTAL:-0}") time=${RS_SECS:-0}s avg=$(hsize "$(( RS_WIRE / (RS_SECS > 0 ? RS_SECS : 1) ))")/s$( (( ST_GROW )) && echo " grow=$ST_GROW" )"

  # --- G5: config only after a GOOD sync (0 = ok, 24 = files vanished: ok) ---
  if [[ $rc -ne 0 && $rc -ne 24 ]]; then
    if [[ $rc -eq 23 ]]; then
      log "[$new_ctid] HINT: rc=23 (partial transfer) is often just unreadable xattrs/special files under /proc/<pid>/root - check the rsync errors in the log; if harmless, rerun or judge manually"
    fi
    log "[$new_ctid] GUARD G5: sync FAILED (rc=$rc) - config NOT created; do NOT start this CT"
    st_fail "$( [[ $rc -eq 11 ]] && echo g4_enospc || echo g5_rsync )"; continue
  fi
  if (( FINAL )) && [[ $rc -eq 24 ]]; then
    log "[$new_ctid] WARN: rc=24 (files vanished) on a STOPPED CT - something is still writing to it; investigate before go-live"
  fi
  cleanup_src

  # $size comes from the real image (an ENOSPC grow may have enlarged it), so the
  # config written below always matches the actual file. Same value the state
  # file reports, from the same stat, so the two can never disagree.
  size="${ST_IMG_GIB}G"

  # --- extra mountpoints: migrated WITHOUT their data, by decision ---
  # rsync -x already stops at the mount boundary, so nothing was copied and the
  # image did not blow up. The risk is the opposite one: the CT boots fine and
  # serves an EMPTY directory, which nobody notices. So name the paths.
  mplist=$(printf '%s\n' "$oldcfg" | grep -E '^mp[0-9]+:' || true)
  if [[ -n "$mplist" ]]; then
    log "[$new_ctid] WARN: old CT has extra mountpoint(s); their DATA IS NOT COPIED and they are stripped from the new config:"
    while IFS= read -r mpline; do
      [[ -z "$mpline" ]] && continue
      mpname="${mpline%%:*}"
      mppath=$(printf '%s\n' "$mpline" | sed -n 's/.*[,[:space:]]mp=\([^,]*\).*/\1/p')
      ST_MP+=("${mppath:-$mpname}")
      log "[$new_ctid] WARN:   $mpname -> ${mppath:-<no mp= found>} will be an EMPTY directory after boot"
    done <<< "$mplist"
    log "[$new_ctid] WARN:   copy that data yourself before go-live, or the CT will start and serve nothing"
  fi

  # --- G6: create config on new-node: mirror old, NO net, onboot=0, stopped ---
  if (( DRY )); then
    dry_cfg_plan "$new_ctid" "$new_node" "$storage" "$size"
    log "[$new_ctid] dry-run - nothing was written"
  elif ! ssh $SSHOPT "root@$new_node" "test -f /etc/pve/lxc/$new_ctid.conf" </dev/null 2>/dev/null; then
    log "[$new_ctid] create CT config on $new_node ($( (( MOCKNET )) && echo "net on $MOCKNET_BRIDGE" || echo "no net" ), onboot=0, stopped)"
    newcfg=$( printf '%s\n' "$oldcfg" \
                | grep -vE '^(rootfs|mp[0-9]+|net[0-9]+|onboot|unused[0-9]+|parent|lock|template|description):'
              echo "rootfs: $storage:$new_ctid/vm-$new_ctid-disk-0.raw,size=$size"
              echo "onboot: 0"
              (( MOCKNET )) && mocknet_lines "$oldcfg" )
    if (( MOCKNET )); then
      log "[$new_ctid]   net kept from the source, moved onto $MOCKNET_BRIDGE - at go-live,"
      log "[$new_ctid]   point each line back at its real bridge (the old node still has it):"
      log "[$new_ctid]   ssh root@$old_node 'pct config $old_ctid | grep ^net'"
    fi
    # Written, then read back and compared. A write cut short by a dropped
    # connection or a full /etc/pve leaves a half config, and G6 above will never
    # rewrite a config that exists - so the damage would be permanent and every
    # later run would report this CT as healthy. Verified once, here, is cheap.
    if printf '%s\n' "$newcfg" | ssh $SSHOPT "root@$new_node" "cat > /etc/pve/lxc/$new_ctid.conf" \
       && [[ "$(ssh $SSHOPT "root@$new_node" "cat /etc/pve/lxc/$new_ctid.conf" </dev/null 2>/dev/null)" == "$newcfg" ]]; then
      ST_CFG_PRESENT=1; ST_CFG_SIZE="$size"
    else
      log "[$new_ctid] ERROR: the config on $new_node does not match what was sent (truncated write)"
      log "[$new_ctid] ERROR:   the rootfs data is fine; only the config is bad"
      log "[$new_ctid] ERROR:   delete it and run again: rm /etc/pve/lxc/$new_ctid.conf"
      st_fail cfg_write; continue
    fi
  else
    # never rewrite it (a human may have added net0 by now), but the image can
    # have grown since it was written — say so instead of silently diverging.
    cfgsize=$(ssh $SSHOPT "root@$new_node" "grep '^rootfs:' /etc/pve/lxc/$new_ctid.conf" </dev/null 2>/dev/null \
              | sed -n 's/.*size=\([^,]*\).*/\1/p')
    ST_CFG_PRESENT=1; ST_CFG_SIZE="$cfgsize"
    if [[ -n "$cfgsize" && "$cfgsize" != "$size" ]]; then
      ST_DRIFT=1
      log "[$new_ctid] NOTE: config says size=$cfgsize but the image is now $size (grown by ENOSPC retry)"
      log "[$new_ctid] NOTE:   config left untouched on purpose; fix the line yourself if you care:"
      log "[$new_ctid] NOTE:   rootfs: $storage:$new_ctid/vm-$new_ctid-disk-0.raw,size=$size"
    fi
  fi
  st_ok
done 3< "$INV"

end_iteration          # closes out the LAST row; the EXIT trap then finds nothing to do

# close the mux masters instead of leaving them idling for ControlPersist secs.
# OUR masters only, never another lane's - see the ControlPath comment above.
for s in /run/ctmig-$$-*.sock; do
  [[ -S "$s" ]] && ssh -O exit -o ControlPath="$s" nohost >/dev/null 2>&1
done

hr2
log "lane '$LANE' finished: ok=$ok skipped=$skipped frozen=$frozen failed=$failed"
# Said once at the end as well as once per CT, because the per-CT lines scroll
# past and this is the line an operator reads before deciding to run it for
# real. No state file was written either, so `tp status` still shows the last
# run that actually moved something.
(( DRY )) && log "dry-run only - nothing was written, on this node or any other"

# A misspelled --storage or --ctid matches no row, does nothing, and exits 0.
# Under cron that is indistinguishable from a healthy run, so a lane can look
# fine for weeks while nothing at all is being migrated. Say it and fail.
if (( matched == 0 )) && [[ -n "$LANE_STORAGE$ONLY_CTID" ]]; then
  log "ERROR: no row in $INV matched${LANE_STORAGE:+ --storage $LANE_STORAGE}${ONLY_CTID:+ --ctid $ONLY_CTID}"
  # The mistake this message kept failing to prevent: --ctid matches the NEW
  # id, because that is the name every log line here carries - but the id an
  # operator has in their head is the OLD one, the container they can see on
  # the old node. Typing it got this error, which then printed two bare
  # columns and no hint about which of them --ctid meant.
  if [[ -n "$ONLY_CTID" ]]; then
    log "ERROR:   --ctid matches the NEW id (column 3 of the row), not the old one."
    log "ERROR:   these are the rows, as old_ctid -> new_ctid (storage):"
    awk '$1!~/^#/ && NF>=5 {print "ERROR:     " $2 " -> " $3 "  (" $5 ")"}' "$INV" \
      | while IFS= read -r _l; do log "$_l"; done
  else
    log "ERROR:   nothing was migrated. check the spelling against the inventory:"
    log "ERROR:   awk '\$1!~/^#/ && NF>=5 {print \$3, \$5}' $INV"
  fi
  exit 1
fi

if (( failed > 0 )); then
  log "NEEDS ATTENTION -> CT: ${FAILED_IDS[*]}"
  exit 1
fi
exit 0
