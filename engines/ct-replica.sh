#!/usr/bin/env bash
# =============================================================================
#  ct-replica.sh v3  —  run on the STORAGE NODE (nfs01)
# -----------------------------------------------------------------------------
#  Replicates critical CT rootfs (raw images on this node, served to compute
#  over NFS) into ZFS subvol datasets on the BACKUP node, and creates a
#  STOPPED copy CT config there. The copy can be snapshotted from the GUI
#  (pct snapshot) and started by hand during DR.
#
#  The backup node offers more than one destination pool (e.g. replica-hdd
#  and replica-ssd). EVERY row in the inventory names its own, and a row that
#  does not is refused: there is no default, because a copy landing on a pool
#  nobody chose is the same guess this tool refuses everywhere else. The dest
#  name IS the PVE storage id, and BKP_DESTS in ctrep.conf maps it to the
#  parent dataset.
#
#  The copy gets the source's REAL network config - same IP, same MAC, same
#  everything, including its VLAN tag - moved onto an ISOLATED bridge
#  (MOCKNET_BRIDGE). That bridge has no uplink, so nothing it carries can ever
#  reach the wire, which is what makes a duplicate IP harmless and lets you
#  boot a copy for a drill while the real CT is live. See R9: that one fact
#  is now the whole safety model, so it is verified before every run.
#
#  usage:
#    ct-replica.sh                          all CTs, lane "all"
#    ct-replica.sh --storage tank-ssd-nas   only CTs whose rootfs lives on that
#                                           SOURCE storage (own lane: lock+log)
#    ct-replica.sh --ctid 105               only that SOURCE ct
#    ct-replica.sh --dry-run                every guard, the plan, no write and
#                                           no snapshot - so no transfer number
#    ct-replica.sh --ctid 105 --move-dest   move that copy onto the pool its
#                                           inventory row NOW names, in one
#                                           command: copy, verify, repoint the
#                                           config, and only then remove the
#                                           old. This is the answer to R8.
#
#  layout — everything resolves relative to this script, the folder can be
#  moved or renamed freely; only re-point the cron line:
#    ct-replica.sh    this engine
#    ctrep.conf       site tuning (backup target, dests, bandwidth) — optional
#    ctrep-exclude.conf  what is NOT copied, one rsync pattern per line. Read
#                        by ct-failback.sh too, because that copies the same
#                        rootfs back and also runs --delete. REQUIRED: a
#                        missing one is refused, never replaced by a guess
#    inventory-replica.tsv   which CTs to copy (see
#                            inventory-replica.sample.tsv). A separate file
#                            from ct-migrate.sh's inventory-migrate.tsv on purpose:
#                            they share a folder and their columns mean
#                            different things
#    PAUSE            create this file to stop all syncing (used during a
#                     failback, when the copy holds the newer data)
#    ../logs/         daily log per lane in ketsync's ONE log directory,
#                     auto-pruned after LOG_KEEP_DAYS
#    state/           machine-readable status, one pair of files per CT:
#                       <src_ctid>.json        snapshot, replaced atomically
#                       <src_ctid>.runs.jsonl  append-only history, 1 JSON/run
#                     the run object is the SAME shape ct-migrate writes, so
#                     one dashboard can read both tools.
#
#  before any CT is touched the inventory is refused whole if it names the
#  same src_ctid twice or resolves two rows to the same target VMID.
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
#  THE GUARDS (R1..R16) — same contract as ct-migrate's G1..G7: each exists
#  because of a real incident on this fleet; keep them and keep their ORDER.
#
#   R1  point-in-time source, never a moving one. A ZFS-backed storage is
#       snapshotted + cloned and every image is read from the CLONE, so all
#       files in one round come from the same instant. A non-ZFS storage has
#       no snapshot: reading the live image spreads the reads over minutes
#       = torn copy. That runs only when LIVE_FALLBACK=1 says you accepted
#       it, and it logs loudly every round.
#       Also: if the backing filesystem of a storage path is not mounted, the
#       path is an empty dir on the node root fs — refuse, do not "sync" it.
#
#   R2  never rsync into a copy that is RUNNING on the backup node. A running
#       copy means DR was promoted; overwriting it destroys the live system.
#
#   R3  the destination dataset must report mounted=yes on the backup node,
#       otherwise rsync pours the whole CT into the backup node's root fs.
#
#   R4  the target VMID must not belong to any OTHER guest in the cluster —
#       checked against every node's lxc AND qemu-server config dirs.
#
#   R5  the copy config is written only after a GOOD sync (rc 0 or 24), then
#       read back and compared; an existing config is NEVER overwritten (a
#       human may have touched it). 24 = "files vanished", normal on a live
#       source. A write cut short by a dropped ssh leaves a half config that
#       R5 would never rewrite, so the damage would be permanent and silent -
#       hence the read-back.
#
#   R6  images are loop-mounted ro,noload: no ext4 journal replay (measured:
#       replay = 43s/CT of random reads on HDD) and no writes into the clone.
#       rc=23 right after a CT restart/failback is usually a ro,noload
#       transient — rerun; the SAME file failing twice = stop the CT and
#       e2fsck the raw image.
#
#   R7  one lock per lane, and snapshot/clone names carry the lane name, so
#       an "all" run and a per-storage run can never destroy each other's
#       snapshots mid-transfer.
#
#   R8  an existing copy config must agree with the row's destination.
#       If someone edits the dest column AFTER the copy was created, the sync
#       would fill the NEW dataset while the config still points at the OLD
#       one — a copy that looks fresh but boots stale data. Refuse, and make
#       the human move or remove the old copy first. `--move-dest` is that
#       move, done in the safe order and with every other guard still on.
#
#   R9  the mock bridge must have NO uplink. Copies carry production IPs and
#       MACs; the ONLY thing keeping that harmless is that MOCKNET_BRIDGE
#       cannot reach a wire. The moment a physical NIC or a bond is added to
#       it, every copy on it becomes a live duplicate of a production host.
#       Checked ONCE, before anything runs, and it refuses the WHOLE run
#       (exit 2) rather than continuing quietly - because if it trips, copies
#       that already exist may be colliding on the wire right now, and that
#       needs a human this minute, not a clean-looking log.
#
#   R10 one run at a time per TARGET copy. Lane locks assume lanes are
#       disjoint; per-storage lanes are, but the "all" lane overlaps every one
#       of them. A hand-run while cron is mid-flight would put two rsyncs with
#       --delete into the same destination dataset - and hand-runs happen
#       exactly when someone is watching a CT that cron also owns.
#
#   R11 a STOPPED copy must not sit on a production bridge. Going live moves it
#       onto a real bridge; coming back must move it off again. Forgetting that
#       leaves a copy holding a production IP and MAC one click from the wire,
#       somewhere R9 cannot see. Warned every round, never silently fixed - the
#       config belongs to whoever promoted it.
#
#   R12 a whole source storage being down is ONE fact, not one per container.
#       Its CTs are skipped, the reason is said once, and the run still refuses
#       to exit 0. It clears itself the moment the storage comes back, which is
#       the whole difference from pause/<ctid> - that one a human has to undo.
#
#   R13 a live 9<id> placement means ct-distribute.sh has already moved this
#       container somewhere else, so the copy here is the last data from BEFORE
#       the outage and the newest data is on a compute node. R2 does not shield
#       it - a DR copy is stopped by design - and PAUSE cannot, because the
#       storage node dies with no warning and PAUSE lives on the machine that
#       died. So the copy is left alone while that config exists anywhere in
#       the cluster. Per-container, so containers that never moved keep being
#       replicated, and it clears itself when somebody runs the `pct destroy`
#       the DR guide already ends with.
#
#  AFTER A GREEN ROUND the copy is snapshotted on the backup node, once a day,
#  and SNAP_KEEP of those are kept. Three things come out of one cheap call:
#    - a rollback point. rsync --inplace rewrites blocks where they lie, so a
#      round that dies half way leaves a copy that is neither yesterday nor
#      today. `zfs rollback` puts it back to a whole day.
#    - history. A file a customer deleted, or a directory something encrypted,
#      is still in yesterday's snapshot - the live copy has already been made
#      to match production, which is exactly what replication is for and
#      exactly why replication alone is not a backup.
#    - readable files, at <mountpoint>/.zfs/snapshot/ketsync-<date>/. That path
#      works whether or not `.zfs` is listed, and nothing here makes it listed:
#      snapdir=visible walks PBS's pxar encoder into `.zfs/shares`, which fails
#      the whole backup of that copy, and walks this engine's own rsync into a
#      destination entry the source has no counterpart for.
#  ONLY after a green round, so every snapshot names a copy that was whole.
#
#   R15 works BOTH directions now. While this engine writes into a copy the
#       copy carries `lock: disk` in pmxcfs, so a vzdump schedule that fires
#       mid-round refuses that guest - loudly, in the job log - instead of
#       snapshotting a half-rewritten rootfs into an archive that restores to
#       a filesystem that never existed. Set only while a config exists, and
#       cleared on every way out of the round; a leftover (a round that died
#       mid-write) is named by the next round with the pct unlock that ends it.
#
#   R15 a copy PVE itself has locked is left alone. vzdump writes `lock: backup`
#       into the copy's config for the whole of a PBS backup, and that backup
#       reads the same rootfs this engine writes into. rsync --delete running
#       underneath it does not corrupt the copy - it corrupts the BACKUP, which
#       ends up holding half of one round and half of the next and restores to
#       a filesystem that never existed. A skip, not a failure: nothing is
#       wrong, the lock clears when the job ends, and the next round copies it.
#
#   R14 the copy is locked on the machine that HOLDS it, not on this one. R7
#       and R10 are local flocks and settle nothing between machines, and more
#       than one machine writes into a copy - during an outage distribute and
#       recall are driven from the backup node, because the machine that
#       normally drives replication is the machine that died. An unanswered
#       destination is refused, not treated as free.
#
#   R16 an image ct-migrate is still bringing in is not copied. Intake and
#       replication run on this same machine against this same raw image, and
#       R1's snapshot can land in the middle of a migrate round - the clone
#       then holds half of one round and half of another, and the copy (and
#       the PBS backup of the copy) would archive that torn state behind a
#       green checkmark. The guard reads migrate's own state file: a round
#       running now, a round that finished after the snapshot, or a last real
#       round that did not end ok, all skip - and every skip clears itself on
#       the next round.
# =============================================================================
set -uo pipefail

# cron hands a script PATH=/usr/bin:/bin and nothing else, while half of what
# this tool needs lives in sbin: pvesm, zfs, losetup, e2fsck. Interactively as
# root it all works, under cron `pvesm` is simply "command not found" and the
# empty result then looks exactly like a storage that was never configured.
# Set it here so the two cases cannot diverge.
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # folder is relocatable
INV="$BASE/inventory-replica.tsv"
CONF="$BASE/ctrep.conf"
EXCL="$BASE/ctrep-exclude.conf"
# Repo shape: the per-site conf lives in conf/ and the work list in
# inventory/, one level up - the same walk-up as nodes.map. A flat tree (the
# simulators build one) keeps both beside the engine. A copy left at the OLD
# home is refused rather than ranked: two files with one name is two places
# to edit, and whichever one this engine did not read is the one somebody
# just edited.
if [[ -f "$BASE/../bin/ketsync" && -f "$BASE/../lib/common.sh" ]]; then
  _ksroot="$(cd "$BASE/.." && pwd)"
  if [[ -e "$CONF" ]]; then
    echo "ERROR: $CONF is the OLD home - the conf moved to conf/ctrep.conf." >&2
    echo "ERROR:   merge any local edits into $_ksroot/conf/ctrep.conf and remove" >&2
    echo "ERROR:   the old file. Two files with one name is how an edit gets lost." >&2
    exit 2
  fi
  if [[ -e "$INV" ]]; then
    echo "ERROR: $INV is the OLD home - the work lists moved to inventory/." >&2
    echo "ERROR:   mv $INV $_ksroot/inventory/inventory-replica.tsv" >&2
    exit 2
  fi
  CONF="$_ksroot/conf/ctrep.conf"
  INV="$_ksroot/inventory/inventory-replica.tsv"
  EXCL="$_ksroot/conf/ctrep-exclude.conf"
fi

# ---------- defaults (override in ctrep.conf, never here) ----------
BKP_SSH="root@100.100.100.35"    # backup node, by IP. key auth required
BKP_NODE=""                      # its pmxcfs name. LEAVE EMPTY: the engine asks
                                 # the node itself. Set it only to pin a value,
                                 # and it is then verified, never trusted
# storage-id : dataset. The KEY is the PVE storage id itself - there is no
# short alias any more. "hdd" and "ssd" meant nothing to anybody who had not
# read this file, and a row saying `hdd` next to a source assertion saying
# `tank-hdd-nas` read like two spellings of one thing when they are opposite
# ends of a transfer.
BKP_DESTS="replica-hdd:replica-hdd/ct replica-ssd:replica-ssd/ct"
SRC_STORAGES="tank-hdd-nas tank-ssd-nas"  # storages this tool may read from
OFFSET=8000                      # default tgt_ctid = src_ctid + OFFSET
DR_OFFSET=9000                   # src_ctid + this = the temporary DR copy R13
                                 # looks for. Same knob, same ctrep.conf, as
                                 # ct-distribute.sh - they must never disagree
AUTO_DISCOVER=0                  # REFUSED if set to 1: replicating a container
                                 # with no inventory row means guessing which
                                 # pool its copy belongs on, and there is no
                                 # default any more. List them, with their dest
LIVE_FALLBACK=0                  # 1 = allow syncing from LIVE images on non-ZFS
MOCKNET=1                        # 1 = copy the source's real net* onto the island
MOCKNET_BRIDGE=vmbr99            # must exist on the backup node, and have NO uplink
MOCKNET_TAG=""                   # "" = keep each source's own VLAN tag (default);
                                 # a number forces every copy onto that one VLAN
BW_TOTAL_MB=230                  # tool-wide ceiling in MiB/s across ALL lanes
LANES=1                          # how many lanes may run at once (cron schedules)
BW_MIN_MB=20                     # floor so a big LANES cannot starve a transfer
RUNS_KEEP=200                    # per-CT run history kept in state/<id>.runs.jsonl
SNAP_KEEP=7                      # daily ZFS snapshots kept ON THE COPY, taken
                                 # after a green round. 0 = take none (and
                                 # prune none - turning it off never destroys
                                 # what is already there)
LOG_KEEP_DAYS=14
MNT_BASE=/mnt/ct-replica         # deliberately ABSOLUTE: live loop-mounts must
                                 # not sit inside a folder someone can move
HEALTH_URL=""                    # healthchecks ping URL, empty = off
# Cipher list for the rsync transport. OpenSSH negotiates chacha20-poly1305
# first by default; it has no CPU instruction behind it and caps one stream at
# roughly 150-400 MB/s. The AES-GCM ciphers use AES-NI and are typically twice
# as fast on the same link. Empty = leave ssh to negotiate.
SSH_CIPHERS=aes128-gcm@openssh.com,aes256-gcm@openssh.com,aes128-ctr
# -------------------------------------------------------------------

# ---------- args ----------
LANE_STORAGE=""; ONLY_CTID=""; DRY=0; MOVE_DEST=0
# A value-taking flag whose value was lost to a copy-paste used to hang here
# forever: `shift 2` fails when only one argument is left, the old `|| true`
# swallowed that failure, and $# never reached zero. This lane runs from cron
# every fifteen minutes, so that is a new spinning process every tick and no
# replication. Refuse instead. "$2" is deliberately not "${2:-}", so that
# deleting the check below dies on set -u rather than spinning again.
while (( $# )); do
  case "$1" in
    --storage) [[ $# -ge 2 ]] || { echo "--storage needs a value" >&2; exit 2; }
               LANE_STORAGE="$2"; shift 2;;
    --ctid)    [[ $# -ge 2 ]] || { echo "--ctid needs a value" >&2; exit 2; }
               ONLY_CTID="$2";    shift 2;;
    # Accepted everywhere so one command shape works across all three engines.
    # Here it is what happens anyway, which is the point: an operator should not
    # have to remember that this engine defaults to the whole inventory and
    # ct-failback.sh insists on being told. Refusing a flag that means exactly
    # what the tool already does teaches nothing and costs a run.
    --all)     shift;;
    # Takes NO value, and says so when it is given one. The pool this moves the
    # copy TO is not something to type here: it is the dest column of the row,
    # which is the thing that changed and the reason R8 is now refusing. A
    # value here could disagree with the row, and then the very next round
    # would refuse the copy this command just moved.
    --move-dest)
               if [[ $# -ge 2 && "$2" != -* ]]; then
                 echo "--move-dest takes no value (got '$2')." >&2
                 echo "  The pool it moves the copy to is the one this row's dest column" >&2
                 echo "  already names. Edit the row in inventory-replica.tsv first, then:" >&2
                 echo "    ct-replica.sh --ctid <id> --move-dest" >&2
                 exit 2
               fi
               MOVE_DEST=1; shift;;
    --dry-run) DRY=1; shift;;
    # Walks the comment block instead of counting lines: a fixed range used to
    # stop short of the exit-code contract, which is the half of the header
    # anything running under cron needs most. Strips the # the way tp does.
    -h|--help) awk 'NR>1{ if (/^#/) { sub(/^#[ ]?/,""); print } else exit }' "${BASH_SOURCE[0]}"; exit 0;;
    *) echo "unknown argument: $1" >&2; exit 2;;
  esac
done

# ---------- config ----------
if [[ -f "$CONF" ]]; then
  # `.` returns the LAST line's status, so a conf with one broken line splashes
  # an error onto the terminal, keeps going, and every value that line was
  # setting silently stays at the engine default - a bandwidth ceiling nobody
  # chose, running against a live fleet. That is the fallback rule again, in
  # disguise: half a conf must not run. The shell's own complaint is kept and
  # shown, because "failed to read" without the line sent somebody to look at
  # file permissions when the problem was a typo on line 1.
  _conferr="$(mktemp "${TMPDIR:-/tmp}/ctrep-conf.XXXXXX")"
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
for _v in OFFSET DR_OFFSET AUTO_DISCOVER LIVE_FALLBACK MOCKNET \
          BW_TOTAL_MB LANES BW_MIN_MB RUNS_KEEP SNAP_KEEP LOG_KEEP_DAYS; do
  if [[ ! "${!_v}" =~ ^[0-9]+$ ]]; then
    echo "ctrep.conf: $_v='${!_v}' is not a plain integer" >&2; exit 1
  fi
done
if [[ -n "$MOCKNET_TAG" && ! "$MOCKNET_TAG" =~ ^[0-9]+$ ]]; then
  echo "ctrep.conf: MOCKNET_TAG='$MOCKNET_TAG' must be empty (keep the source tag) or a number" >&2; exit 1
fi
(( LANES >= 1 )) || { echo "ctrep.conf: LANES must be >= 1" >&2; exit 1; }
if [[ -n "$SSH_CIPHERS" && ! "$SSH_CIPHERS" =~ ^[A-Za-z0-9@.,+-]+$ ]]; then
  echo "ctrep.conf: SSH_CIPHERS='$SSH_CIPHERS' is not a plain cipher list" >&2; exit 1
fi
# pasted into a remote command line, so it gets the character set an interface
# name can legitimately be made of and nothing else.
if [[ ! "$MOCKNET_BRIDGE" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "ctrep.conf: MOCKNET_BRIDGE='$MOCKNET_BRIDGE' is not a plain interface name" >&2; exit 1
fi

# parse the dest map once; a broken entry is a conf error, not a per-row skip
declare -A DEST_DS=()
for _kv in $BKP_DESTS; do
  _k="${_kv%%:*}"; _ds="${_kv#*:}"
  # The old form was key=dataset:storage-id - `hdd=replica-hdd/ct:replica-hdd`.
  # It still contains a colon, so the shape check below never saw it: the entry
  # parsed as a key of `hdd=replica-hdd/ct` and the run died three lines later
  # saying DEFAULT_DEST was not a key, which points at the wrong line entirely.
  # An `=` is the old file every time - a PVE storage id cannot contain one -
  # and every fleet upgrading has that line in ctrep.conf today. This engine
  # shipped one itself for a week.
  if [[ "$_kv" == *=* ]]; then
    echo "ctrep.conf: BKP_DESTS entry '$_kv' is the OLD key=dataset:storage-id form" >&2
    echo "ctrep.conf:   the short key ('hdd', 'ssd') is gone. The key IS the storage id now:" >&2
    echo "ctrep.conf:   BKP_DESTS=\"replica-hdd:replica-hdd/ct replica-ssd:replica-ssd/ct\"" >&2
    echo "ctrep.conf:   every row in inventory-replica.tsv names one of those, and" >&2
    echo "ctrep.conf:   a row without a dest is refused - there is no default." >&2
    exit 2
  fi
  if [[ -z "$_k" || "$_kv" != *:* || -z "$_ds" ]]; then
    echo "ctrep.conf: BKP_DESTS entry '$_kv' is not storage-id:dataset" >&2
    echo "ctrep.conf:   BKP_DESTS=\"replica-hdd:replica-hdd/ct replica-ssd:replica-ssd/ct\"" >&2
    exit 2
  fi
  DEST_DS[$_k]="$_ds"
done
# There is no DEFAULT_DEST any more, and that is deliberate. It was the last
# fallback left in this system: a row with no dest column silently landed on
# whichever pool that variable happened to name, which is a customer's DR copy
# on a pool nobody chose. Every row says where its copy goes, or the run is
# refused - the same rule fleet.tsv's dst column already follows.

# ---------- the exclude list ----------
# The three patterns this tool has always excluded used to live in the rsync
# argument list, which meant the one thing every site eventually wants to
# change was the one thing you had to edit an engine to change - and an edited
# engine is a merge conflict on the next pull.
#
# It is REFUSED rather than defaulted when the file is not there. Falling back
# to a built-in list would mean a site that carefully wrote its own excludes,
# and then lost the file to a bad deploy, silently gets the shipped three back
# and a copy full of the paths it meant to keep out. The message below says
# exactly what the file holds, so restoring it by hand takes ten seconds.
if [[ ! -r "$EXCL" ]]; then
  echo "ERROR: the exclude list is missing: $EXCL" >&2
  echo "ERROR:   it ships with the tool and holds the paths replication does not copy." >&2
  echo "ERROR:   Nothing is guessed in its place - a copy is only as good as what is in" >&2
  echo "ERROR:   it, and that list is the one thing a site changes. Restore it from the" >&2
  echo "ERROR:   repo, or write it back by hand - the shipped contents are three lines:" >&2
  echo "ERROR:     /tmp/*" >&2
  echo "ERROR:     /run/*" >&2
  echo "ERROR:     /var/tmp/systemd-private-*" >&2
  echo "ERROR:     /.zfs" >&2
  exit 2
fi

# Static split, not dynamic: a lane that computed its share while alone would
# keep it after a second lane starts, and together they would break the
# ceiling. Predictable beats optimal when the ceiling is a hard constraint.
_bw=$(( BW_TOTAL_MB / LANES ))
(( _bw < BW_MIN_MB )) && _bw=$BW_MIN_MB
BWLIMIT="${_bw}m"

if [[ -n "$LANE_STORAGE" ]]; then
  case " $SRC_STORAGES " in
    *" $LANE_STORAGE "*) ;;
    *) echo "--storage $LANE_STORAGE is not in SRC_STORAGES ($SRC_STORAGES)" >&2; exit 2;;
  esac
fi

# One container at a time, named out loud. Moving a pool's worth of copies with
# one word is not a thing anybody should be able to do by accident, and the
# reason to move one is always about that one: it outgrew its tier, or it needs
# to start fast in a DR. If a whole tier really is moving, that is a row at a
# time, and each one is a command somebody read before they ran it.
if (( MOVE_DEST )); then
  if [[ -z "$ONLY_CTID" ]]; then
    echo "--move-dest needs --ctid <id>: it moves ONE copy between pools." >&2
    echo "  Moving every copy in the inventory with one word is not offered." >&2
    exit 2
  fi
  if [[ -n "$LANE_STORAGE" ]]; then
    echo "--move-dest and --storage do not go together: --storage is the cron lane," >&2
    echo "  --move-dest is one container by id." >&2
    exit 2
  fi
fi

# ---------- ssh ----------
# keepalives make a dead peer fail in ~3 min instead of hanging forever
# (a hung run holds the lane lock and blocks every later cron run).
SSH_COMMON="-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
-o GSSAPIAuthentication=no -o ServerAliveInterval=30 -o ServerAliveCountMax=6"
# control commands are multiplexed; socket lives in /run (tmpfs, wiped on boot)
# The socket name carries THIS process id. Two lanes run concurrently under
# cron, and the cleanup below closes the masters it finds - with a shared path,
# a lane that finishes in a second (nothing to do) would tear down the master
# the other lane is in the middle of using, and its next ssh dies for no
# visible reason. Per-pid costs nothing: ControlPersist is 120s, far shorter
# than the 15-minute cron interval, so no socket was ever being reused anyway.
SSH_OPT="$SSH_COMMON -o ControlMaster=auto -o ControlPath=/run/ctrep-$$-%r@%h.sock -o ControlPersist=120"
# rsync transport is NOT multiplexed: a long transfer must not share its fate
# with short control commands. Compression=no defends against a site-wide
# ssh_config that turned it on (one gzip thread becomes the ceiling).
SSH_DATA="$SSH_COMMON -o ControlMaster=no -o ControlPath=none -o Compression=no"
[[ -n "$SSH_CIPHERS" ]] && SSH_DATA="$SSH_DATA -c $SSH_CIPHERS"

# ---------- lane identity (R7) ----------
LANE="${LANE_STORAGE:-all}"
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

mkdir -p "$LOGDIR" "$LOGDIR/ct" "$BASE/state" "$MNT_BASE"
LOG="$LOGDIR/replica-$LANE-$(date +%F).log"
# Prune before opening today's file, so the run that finally fills the disk is
# not this one. Only replica-*.log at depth 1: the other engines and the
# dispatcher keep their own days in this same directory now, and nothing an
# operator parked in here is collateral damage either. logs/ct/ is pruned by
# the same clock and the same prefix - a per-CT file is the same day said
# again, so it ages out on the same day.
if (( LOG_KEEP_DAYS > 0 )); then
  find "$LOGDIR" "$LOGDIR/ct" -maxdepth 1 -type f -name 'replica-*.log' \
       -mtime +"$LOG_KEEP_DAYS" -delete 2>/dev/null || true
fi

# ST_MSG is the headline the state file shows for this CT. Captured here rather
# than passed around: the FIRST interesting line of an iteration is the real
# reason, every line after it is a how-to-fix hint. First one wins.
ST_PREFIX="replica-"
ST_MSG=""
# ---------- one container, one file ----------
# The day log above is the lane's narrative: every round, every container, in
# order. CT_LOG is ONE container's copy of the same lines - set when its turn
# starts, cleared when it ends - so "what happened to 252 today" is one file
# to open and one file to tail, the way a vzdump task log reads. Nothing is
# logged twice by hand: everything that goes through log() and the rules lands
# in both files while CT_LOG is set, and a container whose turn never printed
# a line never gets a file.
CT_LOG=""
_tee(){ if [[ -n "$CT_LOG" ]]; then tee -a "$LOG" "$CT_LOG"; else tee -a "$LOG"; fi; }
log(){
  local m="$*"
  [[ -z "$ST_MSG" && "$m" =~ (ERROR|GUARD\ R[0-9]|WARN|HINT|NOTE): ]] && ST_MSG="$m"
  printf '%s %s\n' "$(date '+%F %T')" "$m" | _tee
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

# A failback is the one time the replica holds NEWER data than the source, and
# R2 only protects a copy while it is RUNNING. The moment you shut the copy
# down to sync it back, the next cron tick would happily overwrite it with the
# stale original. So there has to be an off switch a human can flip BEFORE that
# shutdown, and it has to be obvious: a file, not a commented-out cron line.
if [[ -f "$BASE/PAUSE" ]]; then
  log "PAUSED by $BASE/PAUSE - nothing will be synced until that file is removed"
  exit 0
fi

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
for _c in pvesm zfs ssh rsync flock mount umount mountpoint findmnt df mktemp tac; do
  command -v "$_c" >/dev/null 2>&1 || _missing+=("$_c")
done
if (( ${#_missing[@]} )); then
  log "ERROR: required command(s) not found: ${_missing[*]} - NOTHING was run"
  log "ERROR:   PATH=$PATH"
  log "ERROR:   this script sets PATH itself, so a miss here means the tool is genuinely absent"
  exit 2
fi

exec 9>"$BASE/.replica-$LANE.lock"
flock -n 9 || { log "another run active in lane '$LANE' - skip"; exit 0; }

hr
log "=== $(hostname) lane=$LANE bw=$BWLIMIT (total ${BW_TOTAL_MB}m / $LANES lanes) conf=$([[ -f $CONF ]] && echo yes || echo defaults) mocknet=$([[ $MOCKNET == 1 ]] && echo "$MOCKNET_BRIDGE tag ${MOCKNET_TAG:-<from source>}" || echo off)$( (( DRY )) && echo " mode=dry-run" ) ==="

# ---------- inventory: parse + preflight in one pass ----------
# columns:  src_ctid  [fields in any order]
#   a NUMERIC field        -> tgt_ctid (default src_ctid + OFFSET)
#   a key from BKP_DESTS   -> destination pool. REQUIRED, no default
#   anything else          -> SOURCE storage assertion, verified later
# '#' starts a comment, whole-line or inline. The whole file is refused when a
# field cannot be classified, a field kind repeats, the same src_ctid appears
# twice, or two rows resolve to the same target VMID — a duplicate is a
# property of the FILE, so nothing at all is run (exit 2).
declare -a INV_CTS=()
declare -A TGT_MAP=() DEST_MAP=() STOR_ASSERT=()
declare -A SEEN_SRC=() SEEN_TGT=()
declare -a INV_ERRS=()
# A MISSING inventory is a deployment mistake, not an empty workload. Without
# this the parse block below is simply skipped, the CT list comes out empty and
# the run says "nothing to do" and exits 0 - which under cron is exactly what a
# healthy night looks like, every fifteen minutes, while nothing is replicated
# at all. This file has been renamed once already: it used to be called
# inventory.tsv, which is now inventory-migrate.tsv and belongs to ct-migrate.
# A rename is precisely how a fleet stops being copied without anybody being
# told, so a missing one has to be loud.
if [[ ! -f "$INV" ]] && (( ! AUTO_DISCOVER )); then
  log "ERROR: no inventory at $INV - NOTHING was run"
  log "ERROR:   this file is NOT ct-migrate's inventory-migrate.tsv; the columns differ"
  log "ERROR:   start from the sample:  cp ${INV%/*}/inventory-replica.sample.tsv $INV"
  log "ERROR:   or set AUTO_DISCOVER=1 in $CONF to replicate every CT in the cluster"
  exit 2
fi
if [[ -f "$INV" ]]; then
  ln=0
  while IFS= read -r line || [[ -n "${line:-}" ]]; do
    ln=$(( ln + 1 ))
    line="${line%%#*}"
    read -r c rest <<<"$line" || true
    [[ -z "${c:-}" ]] && continue
    if [[ ! "$c" =~ ^[0-9]+$ ]]; then
      INV_ERRS+=("line $ln: src_ctid '$c' is not a number"); continue
    fi
    if [[ -n "${SEEN_SRC[$c]:-}" ]]; then
      INV_ERRS+=("line $ln: src_ctid $c already on line ${SEEN_SRC[$c]}"); continue
    fi
    SEEN_SRC[$c]=$ln
    tgt=""; dest=""; stor=""
    for f in ${rest:-}; do
      if [[ "$f" =~ ^[0-9]+$ ]]; then
        [[ -n "$tgt"  ]] && { INV_ERRS+=("line $ln: two numeric tgt_ctid fields ('$tgt' and '$f')"); continue 2; }
        tgt="$f"
      elif [[ -n "${DEST_DS[$f]:-}" ]]; then
        [[ -n "$dest" ]] && { INV_ERRS+=("line $ln: two dest fields ('$dest' and '$f')"); continue 2; }
        dest="$f"
      elif [[ "$f" == hdd || "$f" == ssd ]]; then
        # The dest column used to take a short alias. It now takes the PVE
        # storage id itself. Without this branch the old word falls through to
        # "source storage assertion" and the row fails saying the CT does not
        # live on a storage called 'hdd' - true, unhelpful, and nowhere near
        # the actual mistake.
        INV_ERRS+=("line $ln: '$f' is the OLD short dest name. Write the storage id: ${!DEST_DS[*]}")
        continue 2
      else
        [[ -n "$stor" ]] && { INV_ERRS+=("line $ln: field '$f' is not a tgt_ctid, not a dest key (${!DEST_DS[*]}), and a storage assertion '$stor' is already set"); continue 2; }
        stor="$f"
      fi
    done
    # No dest, no run. This used to fall through to DEFAULT_DEST, which put a
    # customer's copy on whichever pool that variable named - and the row that
    # forgot it looked exactly like a row that meant it.
    if [[ -z "$dest" ]]; then
      INV_ERRS+=("line $ln: CT $c has no dest column. Every row names its pool: ${!DEST_DS[*]}")
      continue
    fi
    [[ -z "$tgt" ]] && tgt=$(( c + OFFSET ))
    if [[ -n "${SEEN_TGT[$tgt]:-}" ]]; then
      INV_ERRS+=("line $ln: target VMID $tgt already produced by line ${SEEN_TGT[$tgt]} - two sources would sync into one copy")
      continue
    fi
    SEEN_TGT[$tgt]=$ln
    TGT_MAP[$c]=$tgt
    DEST_MAP[$c]="$dest"
    [[ -n "$stor" ]] && STOR_ASSERT[$c]="$stor"
    INV_CTS+=("$c")
  done < "$INV"
fi
if (( ${#INV_ERRS[@]} )); then
  log "ERROR: inventory is broken - NOTHING was run"
  for e in "${INV_ERRS[@]}"; do log "ERROR:   $e"; done
  log "ERROR: fix $INV, then run again"
  exit 2
fi

# ---------- preflight: the backup node must be who ctrep.conf says it is -----
# /etc/pve/local is a symlink to nodes/<this node>, so it is the authoritative
# pmxcfs identity - safer than hostname, which can drift from it after a badly
# done rename. Getting BKP_NODE wrong is expensive in the worst possible way:
# every check below passes, the ENTIRE rootfs transfers, and only the very last
# step fails ("No such file or directory" writing the copy config) - or worse,
# if the name happens to be another cluster member, the write SUCCEEDS and the
# copies appear on a compute node.
_bkinfo=$(ssh $SSH_OPT "$BKP_SSH" \
  'readlink /etc/pve/local 2>/dev/null | sed "s|.*/||;s|^|NODE=|"
   ls -1 /etc/pve/nodes 2>/dev/null | tr "\n" " " | sed "s|^|NODES=|"' \
  </dev/null 2>/dev/null)
_bknode=$(printf '%s\n' "$_bkinfo" | sed -n 's/^NODE=//p' | head -1)
_bknodes=$(printf '%s\n' "$_bkinfo" | sed -n 's/^NODES=//p' | head -1)
if [[ -z "$_bknode" ]]; then
  log "ERROR: cannot read the PVE node identity of $BKP_SSH - NOTHING was run"
  log "ERROR:   check: ssh $BKP_SSH 'readlink /etc/pve/local'"
  exit 2
fi
# Nobody should have to type a pmxcfs name. The node knows its own, this
# engine is already talking to it, and a name that is typed is a name that can
# be wrong today or right today and stale next month. An empty BKP_NODE is
# therefore the normal case and not a missing setting. A value that IS set is
# still checked rather than believed - pinning it is a way of saying "refuse if
# this is not the machine I think it is", which is worth keeping.
if [[ -z "$BKP_NODE" ]]; then
  BKP_NODE="$_bknode"
  log "backup node identifies itself as '$_bknode' (BKP_NODE is unset in $CONF, which is fine)"
elif [[ "$_bknode" != "$BKP_NODE" ]]; then
  log "ERROR: BKP_NODE='$BKP_NODE' but $BKP_SSH is really node '$_bknode' - NOTHING was run"
  log "ERROR:   copy configs would land in a directory that is not this machine's"
  log "ERROR:   nodes visible there: ${_bknodes:-<none>}"
  log "ERROR:   fix BKP_NODE in $CONF (set it to '$_bknode', or remove the line)"
  exit 2
fi

# ---------- R9: the mock bridge must exist and must have no uplink ----------
# Runs once, before any CT is touched, and refuses the whole run. A physical
# NIC has a /sys/class/net/<if>/device symlink to its PCI device; a bond has a
# /bonding directory. Neither exists for an OVS internal port or for the veth
# PVE creates per container, which is exactly the distinction needed here.
#
# It asks OVS for list-IFACES, not list-ports. An OVS bond is one PORT whose
# members are the NICs, and it has no kernel netdev of its own: `list-ports`
# on a bridge uplinked by a bond returns a name that has no /device and no
# /bonding, and this guard would have called that bridge isolated while it
# reached the wire. list-ifaces returns the members themselves.
if (( MOCKNET )); then
  _r9=$(ssh $SSH_OPT "$BKP_SSH" "
    ip -br link show $MOCKNET_BRIDGE >/dev/null 2>&1 || { echo MISSING; exit 0; }
    ports=\$(ovs-vsctl --timeout=5 list-ifaces $MOCKNET_BRIDGE 2>/dev/null || ls /sys/class/net/$MOCKNET_BRIDGE/brif/ 2>/dev/null)
    for p in \$ports; do
      if [ -e /sys/class/net/\$p/device ] || [ -d /sys/class/net/\$p/bonding ]; then echo \"UPLINK \$p\"; fi
    done
    echo OK
  " </dev/null 2>/dev/null)
  # MISSING is tested FIRST: the remote snippet prints MISSING and exits before
  # it ever prints OK, so testing for a missing OK first swallowed this branch
  # and told the operator "ssh failed?" when the real answer was "the bridge is
  # not there, here is how to make it".
  if [[ "$_r9" == *MISSING* ]]; then
    log "GUARD R9: bridge $MOCKNET_BRIDGE does not exist on $BKP_NODE - NOTHING was run"
    log "GUARD R9:   create it there (isolated island, NO uplink), then run again:"
    log "GUARD R9:   /etc/network/interfaces.d/$MOCKNET_BRIDGE - see the setup guide"
    log "GUARD R9:   or set MOCKNET=0 in ctrep.conf to make copies without any network"
    exit 2
  fi
  if [[ "$_r9" != *OK* ]]; then
    log "GUARD R9: cannot inspect $MOCKNET_BRIDGE on $BKP_NODE (ssh failed?) - NOTHING was run"
    exit 2
  fi
  if [[ "$_r9" == *UPLINK* ]]; then
    log "GUARD R9: $MOCKNET_BRIDGE on $BKP_NODE HAS AN UPLINK - NOTHING was run"
    printf '%s\n' "$_r9" | grep UPLINK | while read -r _ p; do
      log "GUARD R9:   port '$p' is a physical NIC or a bond"
    done
    log "GUARD R9:   copies carry PRODUCTION IPs and MACs; the only thing that made"
    log "GUARD R9:   that safe was this bridge being unable to reach a wire."
    log "GUARD R9:   ANY COPY ALREADY RUNNING ON IT MAY BE COLLIDING WITH PRODUCTION NOW."
    log "GUARD R9:   check: ssh $BKP_SSH 'pct list' ; ovs-vsctl list-ifaces $MOCKNET_BRIDGE"
    exit 2
  fi
  log "R9: $MOCKNET_BRIDGE ok on $BKP_NODE (no uplink)"
fi

declare -a CTS=()
# AUTO_DISCOVER replicates every container in the cluster, including ones with
# no inventory row - and a container with no row has nothing that says which
# pool its copy belongs on. That used to be DEFAULT_DEST's job. With no
# fallback the mode cannot answer the question at all, so it refuses here
# rather than picking a pool on a customer's behalf.
if (( AUTO_DISCOVER )); then
  log "ERROR: AUTO_DISCOVER=1 is not usable without a default destination - NOTHING was run"
  log "ERROR:   there is no DEFAULT_DEST any more, on purpose: a copy landing on a"
  log "ERROR:   pool nobody chose is the guess this tool refuses everywhere else."
  log "ERROR:   list the containers you replicate in $(basename "$INV"), each with its dest."
  exit 2
fi
CTS=("${INV_CTS[@]:-}")
if [[ ${#CTS[@]} -eq 0 || -z "${CTS[0]:-}" ]]; then
  # The file exists and parsed, it just names nobody. That is a legitimate
  # state - somebody commented every row out - so it is not an error, but say
  # WHICH file is empty rather than leaving a bare "nothing to do" in the log.
  log "WARN: $INV names no CT - nothing is being replicated"
  exit 0
fi
log "candidates: ${CTS[*]}"

# =============================================================================
#  MACHINE-READABLE STATE — the data contract for everything that is not this
#  script. Two files per CT under state/, written here and nowhere else:
#    state/<src_ctid>.json         current snapshot, replaced atomically
#    state/<src_ctid>.runs.jsonl   append-only history, one JSON object per run
#
#  Why two files. "Has the delta converged yet" cannot be answered from a
#  snapshot: one run reporting 2.3 GB moved means nothing without the run
#  before it. Keeping that history inside the snapshot would mean
#  read-modify-write of a JSON array in bash, which is precisely how a
#  half-written state file gets created. Appending one sub-4KiB line to an
#  O_APPEND fd is atomic; a rewritten array is not.
#
#  The RUN OBJECT is deliberately identical in shape to the one ct-migrate
#  writes, so a single dashboard renders both tools' timelines. Only the
#  snapshot's identity fields differ, and any reader branches on "tool".
#
#  No jq and no python: Proxmox ships neither.
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

RS_FILES=0; RS_LITERAL=0; RS_SENT=0; RS_TOTAL=0; RS_SECS=0
ST_CTID=""; ST_TGT=""; ST_SRC_NODE=""; ST_SRC_STORAGE=""; ST_DEST=""; ST_DS=""
ST_CFG_PRESENT=0; ST_MOCKNET=0; ST_STATUS=""; ST_REASON=""; ST_RC=-1; ST_MP=()
ST_SNAP=""      # the snapshot this round left on the copy, "failed", or empty

st_reset(){
  ST_CTID=""; ST_TGT=""; ST_SRC_NODE=""; ST_SRC_STORAGE=""; ST_DEST=""; ST_DS=""
  ST_CFG_PRESENT=0; ST_MOCKNET=0; ST_STATUS=""; ST_REASON=""; ST_RC=-1
  ST_MSG=""; ST_MP=(); ST_SNAP=""
  RS_FILES=0; RS_LITERAL=0; RS_SENT=0; RS_TOTAL=0; RS_SECS=0
}

_st_run_json(){
  printf '{"ts":%s,"epoch":%s,"lane":%s,"mode":%s,"status":%s,"reason":%s,"message":%s,' \
    "$(json_str "$(date '+%FT%T%z')")" "$(json_num "$(date +%s)")" \
    "$(json_str "$LANE")"      "$(json_str replica)" \
    "$(json_str "$ST_STATUS")" "$(json_str "$ST_REASON")" "$(json_str "$ST_MSG")"
  printf '"rc":%s,"secs":%s,"files":%s,"literal_bytes":%s,"bytes_sent":%s,"total_bytes":%s,"grow_attempts":0}' \
    "$(json_num "$ST_RC")"      "$(json_num "$RS_SECS")"  "$(json_num "$RS_FILES")" \
    "$(json_num "$RS_LITERAL")" "$(json_num "$RS_SENT")"  "$(json_num "$RS_TOTAL")"
}

_st_snapshot_json(){
  local mp="" p
  for p in ${ST_MP+"${ST_MP[@]}"}; do mp+="${mp:+,}$(json_str "$p")"; done
  printf '{\n'
  printf '  "schema_version": %s,\n'  "$(json_num "$SCHEMA_VERSION")"
  printf '  "tool": %s,\n'            "$(json_str ct-replica)"
  printf '  "src_ctid": %s,\n'        "$(json_str "$ST_CTID")"
  printf '  "tgt_ctid": %s,\n'        "$(json_str "$ST_TGT")"
  printf '  "src_node": %s,\n'        "$(json_str "$ST_SRC_NODE")"
  printf '  "bkp_node": %s,\n'        "$(json_str "$BKP_NODE")"
  printf '  "src_storage": %s,\n'     "$(json_str "$ST_SRC_STORAGE")"
  printf '  "dest": %s,\n'            "$(json_str "$ST_DEST")"
  printf '  "dest_dataset": %s,\n'    "$(json_str "$ST_DS")"
  printf '  "config_present": %s,\n'  "$(json_bool "$ST_CFG_PRESENT")"
  printf '  "mocknet": %s,\n'         "$(json_bool "$ST_MOCKNET")"
  printf '  "mp_empty": [%s],\n'      "$mp"
  printf '  "snapshot": %s,\n'        "$(json_str "$ST_SNAP")"
  printf '  "last": %s\n'             "$(_st_run_json)"
  printf '}\n'
}

st_write(){   # replace the snapshot atomically - a reader never sees a half file
  # A dry run writes no state: it must not overwrite the record of the last
  # REAL round, or `tp status` reports a copy as healthy on the strength of a
  # run that moved nothing.
  (( DRY )) && return 0
  [[ -n "$ST_CTID" ]] || return 0
  local f="$BASE/state/$ST_PREFIX$ST_CTID.json" t="$BASE/state/.$ST_PREFIX$ST_CTID.json.$$"
  _st_snapshot_json > "$t" 2>/dev/null && mv -f "$t" "$f" 2>/dev/null && return 0
  rm -f "$t" 2>/dev/null
  log "[$ST_CTID] WARN: could not write state file $f"
  return 1
}
st_begin(){ ST_STATUS=running; ST_REASON=""; ST_RC=-1; st_write; }
st_flush(){
  [[ -n "$ST_CTID" ]] || return 0
  # see st_write: no snapshot and no history line either. ST_CTID is still
  # cleared, so the loop top and the EXIT trap do not try again.
  (( DRY )) && { ST_CTID=""; return 0; }
  [[ -n "$ST_STATUS" ]] || ST_STATUS=ok
  st_write
  local h="$BASE/state/$ST_PREFIX$ST_CTID.runs.jsonl" n
  printf '%s\n' "$(_st_run_json)" >> "$h" 2>/dev/null || true
  n=$(wc -l < "$h" 2>/dev/null || echo 0)
  if [[ "$n" =~ ^[0-9]+$ ]] && (( n > RUNS_KEEP * 2 )); then
    tail -n "$RUNS_KEEP" "$h" > "$h.tmp.$$" 2>/dev/null \
      && mv -f "$h.tmp.$$" "$h" 2>/dev/null || rm -f "$h.tmp.$$" 2>/dev/null
  fi
  ST_CTID=""    # flushed; the loop top and the EXIT trap must not write it twice
}
st_fail(){ ST_STATUS=failed;  ST_REASON="$1"; failed=$(( failed + 1 )); FAILED_IDS+=("${ST_CTID:-?}"); }
st_skip(){ ST_STATUS=skipped; ST_REASON="$1"; skipped=$(( skipped + 1 )); }
st_ok(){   ST_STATUS=ok;      ST_REASON="";   ok=$(( ok + 1 )); }

# ---------- R1: per-storage point-in-time prep (lazy, cached) ----------
declare -A PREP_STATE=() PREP_ROOT=() PREP_WHY=() DOWN_COUNT=() DOWN_SID=()
# The INSTANT each storage's read-source was fixed, for R16: on ZFS the
# moment the snapshot was taken, on the live-fallback path the moment the
# reads were about to begin. R16 compares intake activity against it.
declare -A PREP_EPOCH=()
declare -a CLONES=() SNAPS=()
prep_pool(){   # $1 = pool path (dir that contains images/)   $2 = storage id
  local p="$1" sid="$2" fsroot fstype fssrc ds pool snap clone cm rel
  case "${PREP_STATE[$p]:-}" in ok) return 0;; fail) return 1;; esac
  fsroot=$(findmnt -no TARGET -T "$p" 2>/dev/null | head -1)
  fstype=$(findmnt -no FSTYPE -T "$p" 2>/dev/null | head -1)
  fssrc=$(findmnt  -no SOURCE -T "$p" 2>/dev/null | head -1)
  if [[ -z "$fsroot" || "$fsroot" == "/" ]]; then
    PREP_STATE[$p]=fail; PREP_WHY[$p]="backing filesystem is not mounted"
    log "GUARD R1: $p sits on the ROOT filesystem - backing fs for '$sid' is not mounted"
    log "GUARD R1:   check: findmnt -T $p ; zfs mount -a"
    return 1
  fi
  if [[ "$fstype" == "zfs" ]]; then
    ds="$fssrc"; pool="${ds%%/*}"
    snap="ctrep-$LANE"
    clone="$pool/ctrep-clone-$LANE-${ds//\//_}"
    # leftovers from a crashed run. On a clean run they do not exist, and zfs
    # says so on stderr - which must not land in the log, or every healthy run
    # looks like it failed. A leftover that genuinely cannot be destroyed makes
    # the snapshot/clone below fail, and that path reports properly.
    if (( DRY )); then
      # A snapshot and a clone are named objects on live customer storage, and
      # the leftover cleanup just below DESTROYS pre-existing ones. A dry run
      # that died mid-way would leave a clone holding space on the pool it was
      # only supposed to look at. So it does not take one - which means it
      # cannot read the images either, and cannot say how much would move. It
      # says that outright rather than printing a zero somebody would believe.
      PREP_STATE[$p]=ok; PREP_ROOT[$p]="$p"; PREP_EPOCH[$p]=$(date +%s)
      log "R1: DRY: would snapshot $ds@$snap and clone it to $clone"
      log "R1: DRY:   not taken, so nothing is read from '$sid' and there is no transfer estimate"
      return 0
    fi
    zfs destroy -r "$clone"    >/dev/null 2>&1 || true
    zfs destroy    "$ds@$snap" >/dev/null 2>&1 || true
    if ! zfs snapshot "$ds@$snap" >>"$LOG" 2>&1 || ! zfs clone "$ds@$snap" "$clone" >>"$LOG" 2>&1; then
      PREP_STATE[$p]=fail; PREP_WHY[$p]="snapshot/clone failed on $ds"
      log "GUARD R1: snapshot/clone failed for $ds - see log"
      return 1
    fi
    SNAPS+=("$ds@$snap"); CLONES+=("$clone")
    PREP_EPOCH[$p]=$(date +%s)         # the instant the source stopped moving
    cm=$(zfs get -H -o value mountpoint "$clone" 2>/dev/null)
    if [[ -z "$cm" || "$cm" == "none" ]] || ! mountpoint -q "$cm"; then
      PREP_STATE[$p]=fail; PREP_WHY[$p]="the clone of $ds would not mount"
      log "GUARD R1: clone $clone not mounted (mountpoint: ${cm:-?}) - abort this storage"
      return 1
    fi
    rel="${p#"$fsroot"}"                 # storage may be a SUBDIR of the mount
    PREP_ROOT[$p]="${cm}${rel}"
    log "R1: '$sid' point-in-time ready ($ds@$snap -> $clone)"
  else
    if (( ! LIVE_FALLBACK )); then
      PREP_STATE[$p]=fail; PREP_WHY[$p]="on $fstype, which has no snapshots"
      log "GUARD R1: '$sid' is on $fstype - no snapshots, point-in-time copy impossible"
      log "GUARD R1:   reading LIVE images gives a torn copy; if you accept that,"
      log "GUARD R1:   set LIVE_FALLBACK=1 in ctrep.conf"
      return 1
    fi
    log "WARN R1: '$sid' is on $fstype - syncing from LIVE images (no point-in-time; LIVE_FALLBACK=1)"
    PREP_ROOT[$p]="$p"; PREP_EPOCH[$p]=$(date +%s)
  fi
  PREP_STATE[$p]=ok
  return 0
}

# destination storage id must be active on the backup node, or every config
# this run writes points at a storage PVE there cannot resolve. Cached per dest.
declare -A DEST_OK=()
dest_ready(){   # $1 = dest key
  local d="$1" sid st
  case "${DEST_OK[$d]:-}" in 1) return 0;; 0) return 1;; esac
  sid="$d"
  st=$(ssh $SSH_OPT "$BKP_SSH" "pvesm status --storage $sid" </dev/null 2>/dev/null || true)
  if printf '%s\n' "$st" | awk 'NR>1 && $3=="active"{f=1} END{exit !f}'; then
    DEST_OK[$d]=1; return 0
  fi
  DEST_OK[$d]=0
  log "ERROR: dest '$d': storage '$sid' is not active on $BKP_NODE"
  log "ERROR:   add it there: pvesm add zfspool $sid --pool ${DEST_DS[$d]} --content rootdir,images --sparse 1 --nodes $BKP_NODE"
  return 1
}

# ---------- mock network ----------
# The source's net lines, verbatim, with ONE edit by default: the bridge
# becomes the isolated one. The VLAN tag is deliberately left alone, because
# a fleet that puts customers on separate VLANs can legitimately reuse the same
# IP range in each of them - forcing every copy onto one VLAN would make those
# copies collide WITH EACH OTHER on the island. Keeping the tag preserves that
# separation exactly, and isolation does not depend on the tag anyway: it comes
# from the bridge having no uplink (R9).
# hwaddr is kept for the same reason: same MAC means DHCP reservations,
# MAC-bound licences and MAC-keyed rules still work, and go-live is then a
# one-field edit (bridge back to the real one).
# Set MOCKNET_TAG to a number to force one VLAN instead - only useful when every
# CT shares one subnet and you want all copies reachable from a single test port.
#
# stdout of this function IS config text - it is captured into the file being
# written. Nothing here may print anything else, not even through log(): a log
# line printed from in here lands inside the container config. That is why the
# "no bridge=" case is refused up in the main loop instead, before the transfer
# and before this runs; by the time we are here every line has a bridge.
mocknet_lines(){   # $1 = source config text
  printf '%s\n' "$1" | grep -E '^net[0-9]+:' | while IFS= read -r l; do
    [[ "$l" == *bridge=* ]] || continue     # unreachable: refused in the main loop
    if [[ -n "$MOCKNET_TAG" ]]; then
      l=$(printf '%s' "$l" | sed -E "s/,tag=[0-9]+//g; s/bridge=[^,]*/bridge=$MOCKNET_BRIDGE/")
      printf '%s,tag=%s\n' "$l" "$MOCKNET_TAG"
    else
      printf '%s\n' "$l" | sed -E "s/bridge=[^,]*/bridge=$MOCKNET_BRIDGE/"
    fi
  done
}

# rsync stats: captured via --log-file so the tty progress bar is untouched.
# Lines in that file carry a timestamp prefix, so the label is matched anywhere
# in the line, not anchored.
_rs_num(){ sed -n "s/.*$1: *\([0-9,][0-9,]*\).*/\1/p" "$2" 2>/dev/null | tr -d ',' | tail -1; }

# bytes -> human, integer math only. The convergence signal lives in this line,
# so a 158 KiB delta must not print as "0MiB" and look like nothing happened.
hsize(){
  local b=${1:-0}
  if   (( b >= 1073741824 )); then printf '%d.%01dGiB' $(( b/1073741824 )) $(( (b%1073741824)*10/1073741824 ))
  elif (( b >= 1048576    )); then printf '%d.%01dMiB' $(( b/1048576 ))    $(( (b%1048576)*10/1048576 ))
  elif (( b >= 1024       )); then printf '%dKiB' $(( b/1024 ))
  else                             printf '%dB' "$b"; fi
}

# --- progress, the way a backup task log reads -------------------------------
# Under cron this engine used to run silent for however long the copy took and
# then drop rsync's --stats block - fifteen lines of raw byte counts - straight
# into the log. The numbers were already parsed out of the stats FILE and said
# in one readable line, so the block was noise, and the hour before it was
# silence: nothing in the log answered "which CT is the round on, and how far".
# This filter sits on rsync's cron-mode output and turns it into what a vzdump
# task log does:
#   - one progress line per minute, human units: the first update immediately,
#     because "the bytes are moving" is what somebody tailing the log is
#     waiting for, then one every 60s so a two-hour copy is ~120 lines, not
#     twelve thousand;
#   - rsync's own words (vanished files, IO errors) kept verbatim, timestamped;
#   - the raw stats block dropped, because the stats: line below already says
#     it in units a person can read.
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

# --- the daily snapshot of the copy ------------------------------------------
# Taken on the backup node, after a green round, and named after the DATE so
# "once a day" needs no state file to remember: the name either exists or it
# does not. The date is this machine's, and it is in the name, so a reader
# never has to work out whose clock made it.
#
# One ssh takes it and prunes the excess, because this runs once per container
# per round and a round is already four round trips deep. The prune matches
# ONLY ketsync-<date>: a snapshot somebody took by hand, or one PBS left
# behind, is not this tool's to destroy. `sort` is chronological because the
# name is ISO; that is the whole reason for the dashes.
#
# It does NOT set snapdir=visible, and that is deliberate rather than an
# omission. Visible puts `.zfs` into the directory listing, and two things then
# walk into it: PBS, whose pxar encoder dies at `.zfs/shares` with EOPNOTSUPP
# and fails the whole backup of that copy, and this engine's own rsync, which
# sees a `.zfs` at the destination that the source does not have and tries to
# --delete it. `.zfs/snapshot/` is reachable by typing the path whether it is
# listed or not, so hidden costs discoverability and nothing else. That is why
# hidden is ZFS's own default.
#
# Returns non-zero only when TODAY'S SNAPSHOT DOES NOT EXIST afterwards. A
# prune that could not run is reported and forgiven - it costs space, not
# history, and space is visible. A snapshot that was never taken is a day of
# history that silently is not there, which is the thing worth failing over.
# $CT is the log prefix and $tmnt is where the copy is mounted on the backup
# node: this is only ever called from inside the per-container loop, after the
# transfer, where both are set and every other line is prefixed the same way.
snap_after_green(){   # $1 = dataset on the backup node   $2 = snapshot name
  local ds="$1" sn="$2" out rc=0 l
  out=$(ssh $SSH_OPT "$BKP_SSH" "
    if zfs list -H -o name -t snapshot '$ds@$sn' >/dev/null 2>&1; then
      echo HAVE
    elif zfs snapshot '$ds@$sn'; then
      echo TOOK
    else
      echo NOSNAP; exit 1
    fi
    zfs list -H -o name -t snapshot -d 1 '$ds' 2>/dev/null \
      | grep -E '@ketsync-[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\$' \
      | sort | head -n -$SNAP_KEEP \
      | while read -r s; do
          if zfs destroy \"\$s\"; then echo \"PRUNED \$s\"; else echo \"STUCK \$s\"; fi
        done
  " </dev/null 2>&1) || rc=$?
  case "$out" in
    *TOOK*) log "[$CT] snapshot: $ds@$sn (keeping $SNAP_KEEP; read it at $tmnt/.zfs/snapshot/$sn)";;
    *HAVE*) : ;;   # already taken today - said once, on the round that took it
    *)      log "[$CT] WARN: could not snapshot the copy: $ds@$sn (rc=$rc)"
            while IFS= read -r l; do [[ -n "$l" ]] && log "[$CT] WARN:   $l"; done <<< "$out"
            log "[$CT] WARN:   the copy itself is fine - what is missing is today's rollback"
            log "[$CT] WARN:   point and today's line of history. Check space and the pool."
            return 1;;
  esac
  while IFS= read -r l; do
    case "$l" in
      PRUNED*)    log "[$CT] snapshot: pruned ${l#PRUNED }";;
      STUCK*)     log "[$CT] WARN: snapshot ${l#STUCK } would not go - it is holding space";;
    esac
  done <<< "$out"
  return 0
}

# --- --move-dest: change which pool a copy lives on, in the safe order -------
# The problem this solves is R8. Somebody edits a row's dest column - the copy
# outgrew the HDD tier, or it has to start fast in a DR - and from that moment
# every round refuses that container, because the dataset the row names and the
# dataset the config boots are two different places. The fix was a documented
# sequence of zfs and editor commands, run by hand, on the day somebody was
# already busy. Half of that sequence removes data.
#
# THE ORDER IS THE WHOLE FEATURE: copy, verify, repoint, and only then remove.
# At every point before the last step the OLD copy is still the one the config
# boots, so an interrupted move loses nothing and can simply be run again. The
# reverse order - remove and then copy - is the same commands and a disaster.
#
# It is not a separate mode with its own preflight. It runs inside the normal
# per-container loop, after every guard: a copy that is RUNNING (R2), one with
# a live DR placement (R13), one another machine holds (R14) and one PVE has
# locked (R15) are all things you must not move, and they already say so.
#
# There is no file-by-file comparison at the end, deliberately. `zfs send`
# streams are checksummed and `zfs recv` refuses a stream that does not add up,
# so a torn transfer fails the receive rather than landing quietly. What is
# checked instead is what a checksum cannot say: that the result is a mounted
# dataset holding the same number of logical bytes as the snapshot it came from.
# $CT, $TGT, $DEST and $tgtcfg come from the loop, like everywhere else here.
move_copy_dest(){   # $1 = the dest the copy's config names TODAY
  local from="$1" ofrom onew snap out nmounted nlogical ologic newcfg _mvneed _mvfree
  if [[ -z "$from" ]]; then
    log "[$CT] MOVE: copy $TGT has no rootfs line to read a pool from - nothing to move"
    log "[$CT] MOVE:   that config is broken in a way this cannot guess at. Read it:"
    log "[$CT] MOVE:     ssh $BKP_SSH 'cat /etc/pve/nodes/$BKP_NODE/lxc/$TGT.conf'"
    st_fail move_no_rootfs; return 1
  fi
  if [[ "$from" == "$DEST" ]]; then
    log "[$CT] MOVE: copy $TGT is already on '$DEST' - nothing to move"
    log "[$CT] MOVE:   the row and the copy agree. A normal round syncs it."
    st_skip move_not_needed; return 0
  fi
  if [[ -z "${DEST_DS[$from]:-}" ]]; then
    log "[$CT] MOVE: copy $TGT sits on storage '$from', which BKP_DESTS does not name"
    log "[$CT] MOVE:   this cannot work out which dataset holds it, so it will not guess."
    log "[$CT] MOVE:   add '$from' to BKP_DESTS in $(basename "$CONF"), or move it by hand."
    st_fail move_unknown_pool; return 1
  fi
  ofrom="${DEST_DS[$from]}/subvol-$TGT-disk-0"
  onew="${DEST_DS[$DEST]}/subvol-$TGT-disk-0"
  snap="ketsync-move-$(date +%Y%m%d-%H%M%S)"

  # Two storage ids, one dataset. BKP_DESTS maps ids to parent datasets and
  # nothing stops two ids naming the same parent - and then this would send a
  # dataset to itself. The "already exists" refusal below would catch it, but
  # it would catch it by describing the wrong problem, and the operator would
  # go looking for a leftover that was never there.
  if [[ "$ofrom" == "$onew" ]]; then
    log "[$CT] MOVE: '$from' and '$DEST' are two names for the same dataset"
    log "[$CT] MOVE:   both resolve to $onew, so there is nowhere to move to."
    log "[$CT] MOVE:   fix BKP_DESTS in $(basename "$CONF") - one parent dataset per id."
    st_fail move_same_dataset; return 1
  fi

  if (( DRY )); then
    log "[$CT] DRY: would move copy $TGT from '$from' to '$DEST', in this order:"
    log "[$CT] DRY:   1. refuse if $onew already exists, or if '$DEST' has no room"
    log "[$CT] DRY:   2. zfs snapshot $ofrom@$snap"
    log "[$CT] DRY:   3. zfs send -R $ofrom@$snap | zfs recv $onew   (local to $BKP_NODE)"
    log "[$CT] DRY:   4. verify $onew is mounted and holds the same logical bytes"
    log "[$CT] DRY:   5. rewrite the copy config rootfs to '$DEST', and read it back"
    log "[$CT] DRY:   6. only then: zfs destroy -r $ofrom"
    log "[$CT] DRY:   the old copy stays bootable until step 5 succeeds"
    st_ok; return 0
  fi

  # Nothing is ever written into a dataset this run did not create. A dataset
  # already sitting at the destination is either a copy somebody made or the
  # wreckage of a move that died, and both need eyes rather than a --force.
  if ssh $SSH_OPT "$BKP_SSH" "zfs list -H -o name '$onew'" </dev/null >/dev/null 2>&1; then
    log "[$CT] MOVE: $onew already exists on $BKP_NODE - refusing"
    log "[$CT] MOVE:   nothing here overwrites a dataset it did not create. If that is"
    log "[$CT] MOVE:   the wreckage of a move that died, look at it and then remove it:"
    log "[$CT] MOVE:     ssh $BKP_SSH 'zfs list -r -t all $onew'"
    log "[$CT] MOVE:     ssh $BKP_SSH 'zfs destroy -r $onew'"
    st_fail move_dest_exists; return 1
  fi

  # Room on the far pool, asked BEFORE a transfer that could take hours. The
  # destination is shared with every other copy on that tier, so a move that
  # runs the pool out does not only fail itself - it takes the next replication
  # round of everything else with it, and that failure looks like a storage
  # problem rather than like this command. `used` is the source's own size with
  # its snapshots, which is what -R sends; compression can move the real figure
  # either way, so this is a floor and not a promise, and zfs recv remains the
  # actual test.
  read -r _mvneed _mvfree < <(ssh $SSH_OPT "$BKP_SSH" "
      zfs list -Hp -o used '$ofrom' 2>/dev/null
      zfs list -Hp -o available '${DEST_DS[$DEST]}' 2>/dev/null" </dev/null 2>/dev/null | paste -sd' ')
  if [[ ! "${_mvneed:-}" =~ ^[0-9]+$ || ! "${_mvfree:-}" =~ ^[0-9]+$ ]]; then
    log "[$CT] MOVE: could not read the sizes from $BKP_NODE - refusing rather than guessing"
    log "[$CT] MOVE:   need: zfs list -Hp -o used $ofrom"
    log "[$CT] MOVE:   free: zfs list -Hp -o available ${DEST_DS[$DEST]}"
    st_fail move_size_unknown; return 1
  fi
  if (( _mvneed > _mvfree )); then
    log "[$CT] MOVE: '$DEST' does not have room for copy $TGT - NOTHING was touched"
    log "[$CT] MOVE:   $ofrom uses $(hsize "$_mvneed") (its snapshots included, and -R sends them)"
    log "[$CT] MOVE:   ${DEST_DS[$DEST]} has $(hsize "$_mvfree") free"
    log "[$CT] MOVE:   that pool holds other customers' copies too, so filling it would"
    log "[$CT] MOVE:   fail their next round as well, and look like a storage fault."
    st_fail move_no_room; return 1
  fi

  log "[$CT] MOVE: $TGT  '$from' -> '$DEST'"
  log "[$CT] MOVE:   $ofrom  ->  $onew   (needs $(hsize "$_mvneed"), $(hsize "$_mvfree") free)"
  log "[$CT] MOVE:   copying first. Until the config is repointed the OLD copy is still"
  log "[$CT] MOVE:   the one that boots, so this is safe to interrupt and run again."
  # -R, not a plain send: it carries the ketsync-<date> snapshots too. Those
  # are the copy's history, and a move that silently dropped them would trade
  # a week of rollback points for a change of pool.
  if ! ssh $SSH_OPT "$BKP_SSH" "
      set -o pipefail
      zfs snapshot '$ofrom@$snap' || exit 1
      zfs send -R '$ofrom@$snap' | zfs recv '$onew'
    " </dev/null >>"$LOG" 2>&1; then
    log "[$CT] MOVE: the copy to $onew did not finish - NOTHING was removed"
    log "[$CT] MOVE:   $TGT still boots from '$from' and its config still says so."
    log "[$CT] MOVE:   two things are left behind, and neither is destroyed for you."
    log "[$CT] MOVE:   a half-received dataset may be sitting at the destination:"
    log "[$CT] MOVE:     ssh $BKP_SSH 'zfs list -r -t all $onew'"
    log "[$CT] MOVE:     ssh $BKP_SSH 'zfs destroy -r $onew'"
    log "[$CT] MOVE:   and the transfer snapshot on the SOURCE side, which the daily"
    log "[$CT] MOVE:   prune does not match and will therefore hold space forever:"
    log "[$CT] MOVE:     ssh $BKP_SSH 'zfs destroy $ofrom@$snap'"
    log "[$CT] MOVE:   clear both, then run this again."
    st_fail move_send; return 1
  fi

  read -r nmounted nlogical < <(ssh $SSH_OPT "$BKP_SSH" \
      "zfs get -H -o value mounted,logicalreferenced '$onew' 2>/dev/null | paste -sd' '" \
      </dev/null 2>/dev/null)
  ologic=$(ssh $SSH_OPT "$BKP_SSH" \
      "zfs get -H -o value logicalreferenced '$ofrom@$snap' 2>/dev/null" </dev/null 2>/dev/null)
  if [[ "${nmounted:-}" != yes ]]; then
    log "[$CT] MOVE: $onew is not mounted (mounted=${nmounted:-?}) - NOTHING was removed"
    log "[$CT] MOVE:   an unmounted dataset is a directory on the node's root fs, and the"
    log "[$CT] MOVE:   next round would pour this container into it. Fix the mount first."
    st_fail move_not_mounted; return 1
  fi
  if [[ -z "${nlogical:-}" || -z "${ologic:-}" || "$nlogical" != "$ologic" ]]; then
    log "[$CT] MOVE: the new dataset does not hold what the old one did - NOTHING was removed"
    log "[$CT] MOVE:   $ofrom@$snap  logicalreferenced ${ologic:-<no answer>}"
    log "[$CT] MOVE:   $onew         logicalreferenced ${nlogical:-<no answer>}"
    log "[$CT] MOVE:   $TGT still boots from '$from'. Compare them by hand before removing"
    log "[$CT] MOVE:   anything: ssh $BKP_SSH 'zfs list -o space -r ${DEST_DS[$DEST]}'"
    st_fail move_verify; return 1
  fi
  log "[$CT] MOVE: $onew verified: mounted, $nlogical logical bytes, same as the source"

  # The point of no return, and it is a config edit rather than a delete: after
  # this line the copy boots from the NEW dataset. Read back and compared for
  # the same reason R5 does it - a write cut short leaves a config nothing here
  # would ever rewrite.
  newcfg=$(printf '%s\n' "$tgtcfg" | sed -E "s#^(rootfs:[[:space:]]*)[^:]+:#\\1$DEST:#")
  if printf '%s\n' "$newcfg" | ssh $SSH_OPT "$BKP_SSH" "cat > /etc/pve/nodes/$BKP_NODE/lxc/$TGT.conf" \
     && [[ "$(ssh $SSH_OPT "$BKP_SSH" "cat /etc/pve/nodes/$BKP_NODE/lxc/$TGT.conf" </dev/null 2>/dev/null)" == "$newcfg" ]]; then
    log "[$CT] MOVE: copy config $TGT now boots from '$DEST'"
  else
    log "[$CT] MOVE: the config on $BKP_NODE does not match what was sent - STOPPING HERE"
    log "[$CT] MOVE:   both datasets exist and NOTHING was removed, so nothing is lost."
    log "[$CT] MOVE:   set the rootfs line by hand, then remove the old dataset:"
    log "[$CT] MOVE:     rootfs: $DEST:subvol-$TGT-disk-0,size=..."
    log "[$CT] MOVE:     ssh $BKP_SSH 'zfs destroy -r $ofrom'"
    st_fail move_cfg; return 1
  fi

  # Only now. Everything above can fail without costing anything; this is the
  # one irreversible line in the whole command, and it runs after the config
  # has been written AND read back.
  if ssh $SSH_OPT "$BKP_SSH" "zfs destroy -r '$ofrom'" </dev/null >>"$LOG" 2>&1; then
    log "[$CT] MOVE: removed the old dataset $ofrom"
  else
    log "[$CT] WARN: the old dataset $ofrom would not go. The move is DONE and correct -"
    log "[$CT] WARN:   this is space, not data: ssh $BKP_SSH 'zfs destroy -r $ofrom'"
  fi
  ssh $SSH_OPT "$BKP_SSH" "zfs destroy '$onew@$snap'" </dev/null >>"$LOG" 2>&1 \
    || log "[$CT] WARN: transfer snapshot $onew@$snap is still there - space, not correctness"
  log "[$CT] MOVE: done. $TGT is on '$DEST'; the next round syncs into it normally."
  st_ok; return 0
}

# --- one run at a time per TARGET copy ---------------------------------------
# Lane locks (R7) assume lanes are disjoint, and per-storage lanes are: a CT has
# exactly one rootfs storage. The "all" lane is not - it overlaps every storage
# lane. So a hand-run (./ct-replica.sh or --ctid, both lane "all") while cron is
# mid-flight in a storage lane puts TWO rsyncs with --delete into the SAME
# destination dataset. That is the most likely way to meet this bug, because
# hand-runs happen exactly when someone is watching a CT that cron also owns.
# Non-blocking on purpose: whoever cannot have the target moves on to the next
# CT instead of sitting on the lane lock; the next run picks it up.
TGT_LOCK=""
take_tgt_lock(){   # $1 = target vmid -> 0 when this run owns it
  exec 8>"$BASE/.ct-$1.lock" 2>/dev/null || return 1
  if flock -n 8; then TGT_LOCK="$1"; return 0; fi
  exec 8>&-
  return 1
}
release_tgt_lock(){  # closing the fd is what drops the flock
  [[ -n "$TGT_LOCK" ]] || return 0
  exec 8>&-
  TGT_LOCK=""
}

# --- R14: the lock that lives on the machine holding the copy ----------------
# R7 and R10 are local flocks. They serialise runs on THIS machine and nothing
# else - and the copy is not on this machine. More than one machine writes into
# it: this engine runs on the storage node, while ct-distribute.sh and the
# recall path can both be driven from the backup node, which during an outage
# is the entire point - the machine that normally drives replication is the
# machine that died. Two local locks, with different keys, on different hosts,
# exclude nothing at all.
#
# So the lock goes where the data is: one file on the machine that holds the
# copy, named after the copy's VMID, that every contender fights over with no
# consensus and no clock. `set -C` makes the redirect O_EXCL, so the winner is
# decided by the destination's own kernel. docs/decisions.md section 2 has the
# argument; it described this for months before anything implemented it.
#
# /run because it is tmpfs: a destination that reboots cannot leave a lock
# behind, and a destination that rebooted has already killed whatever held it.
# Same reason the ssh control sockets live there - rule 7.
#
# Nothing here ever breaks somebody else's lock, and there is no timeout. A run
# that is SIGKILLed leaves one behind; the refusal names the holder and the
# exact file, and `ketsync doctor` reports it. Deciding from the outside that
# somebody else's transfer into a customer's rootfs has finished is precisely
# the guess this repo refuses everywhere else.
DST_LOCK_OWNER="replica $(hostname 2>/dev/null | tr -cd 'A-Za-z0-9._-') pid $$ started $(date '+%F %T')"
DST_LOCK_HOST=""; DST_LOCK_ID=""; DST_LOCK_WHO=""
dst_lock_file(){ printf '/run/ketsync-ct-%s.lock' "$1"; }

# 0 = this run owns it, 1 = somebody else holds it, 2 = the destination could
# not be asked. Two is NOT one: an unanswered destination is the case where
# writing anyway puts two rsync --delete into one dataset, so it gets its own
# return value and its own refusal rather than sharing "busy".
take_dst_lock(){   # $1 = ssh destination, $2 = vmid
  local f out; f="$(dst_lock_file "$2")"; DST_LOCK_WHO=""
  out=$(ssh $SSH_OPT "$1" \
    "if (set -C; printf '%s\n' '$DST_LOCK_OWNER' > '$f') 2>/dev/null; then echo KETSYNC_LOCK_TAKEN; else echo KETSYNC_LOCK_HELD; cat '$f' 2>/dev/null; fi" \
    </dev/null 2>/dev/null)
  case "$out" in
    KETSYNC_LOCK_TAKEN*) DST_LOCK_HOST="$1"; DST_LOCK_ID="$2"; return 0;;
    KETSYNC_LOCK_HELD*)  DST_LOCK_WHO="$(printf '%s\n' "$out" | sed -n '2p')"; return 1;;
  esac
  return 2
}
# The grep is not belt-and-braces. If a human clears a stale lock while this run
# is still alive, the next run takes it legitimately - and an unconditional rm
# here would then delete a lock somebody else is relying on. Only ever remove a
# file that still says it is ours.
release_dst_lock(){
  [[ -n "$DST_LOCK_ID" ]] || return 0
  local f; f="$(dst_lock_file "$DST_LOCK_ID")"
  ssh $SSH_OPT "$DST_LOCK_HOST" \
      "grep -qxF '$DST_LOCK_OWNER' '$f' 2>/dev/null && rm -f '$f'" \
      </dev/null >/dev/null 2>&1 || true
  DST_LOCK_HOST=""; DST_LOCK_ID=""
}
# A dry run reads the lock and never creates one: `--dry-run` writing a file on
# another machine is the thing dry-run exists not to do. `exit 0` on the far end
# separates "nothing is there" from "that machine did not answer" - without it
# an unreachable destination reads exactly like a free lock.
peek_dst_lock(){   # $1 = ssh destination, $2 = vmid -> 0 free, 1 held, 2 no answer
  local out rc; DST_LOCK_WHO=""
  out=$(ssh $SSH_OPT "$1" "cat '$(dst_lock_file "$2")' 2>/dev/null; exit 0" </dev/null 2>/dev/null); rc=$?
  (( rc == 0 )) || return 2
  [[ -n "$out" ]] || return 0
  DST_LOCK_WHO="$(printf '%s\n' "$out" | sed -n '1p')"
  return 1
}

# every exit path, including a kill: bring the loop-mount down and record what
# happened. A CT still marked "running" here was interrupted, and saying so
# beats leaving a state file that claims a sync is still in progress.
CUR_MNT=""
# The config lock this run set on the copy, cleared on EVERY way out of the
# iteration - success, a failed rsync, and the EXIT trap alike. pmxcfs keeps
# it across reboots, so a leftover is not harmless: it blocks vzdump's next
# backup of that copy and R15's next round both. The stale-lock branch in R15
# is the net under this trapeze, not a licence to skip the release.
CFG_LOCKED=""
release_cfg_lock(){
  [[ -n "$CFG_LOCKED" ]] || return 0
  ssh $SSH_OPT "$BKP_SSH" "pct unlock $CFG_LOCKED" </dev/null >>"$LOG" 2>&1 \
    || log "[$CFG_LOCKED] WARN: pct unlock $CFG_LOCKED failed - the copy stays locked, vzdump will"
  CFG_LOCKED=""
}
end_iteration(){
  if [[ -n "$CUR_MNT" ]]; then
    mountpoint -q "$CUR_MNT" 2>/dev/null && { umount "$CUR_MNT" >>"$LOG" 2>&1 || true; }
    CUR_MNT=""
  fi
  release_tgt_lock
  # Here rather than in cleanup(), because cleanup() tears the ssh control
  # masters down and these need one: releasing over a connection that is
  # already gone opens a fresh one, and on a killed run that is the moment the
  # network is least likely to cooperate. cleanup() calls end_iteration first,
  # so the order holds on the trap path too. The config lock goes first: it is
  # the one whose leftover survives a reboot.
  release_cfg_lock
  release_dst_lock
  [[ "$ST_STATUS" == running ]] && { ST_STATUS=interrupted; ST_REASON=interrupted; }
  st_flush
  CT_LOG=""                     # this container's turn is over; the file stays
}

cleanup(){
  local d c s
  end_iteration
  for d in "$MNT_BASE"/*; do
    mountpoint -q "$d" 2>/dev/null && umount "$d" >>"$LOG" 2>&1
  done
  for c in "${CLONES[@]:-}"; do        # clones first: snapshots depend on them
    [[ -n "$c" ]] && { zfs destroy -r "$c" >>"$LOG" 2>&1 || true; }
  done
  for s in "${SNAPS[@]:-}"; do
    [[ -n "$s" ]] && { zfs destroy "$s" >>"$LOG" 2>&1 || true; }
  done
  for s in /run/ctrep-$$-*.sock; do    # OUR mux masters only - never another lane's
    [[ -S "$s" ]] && ssh -O exit -o ControlPath="$s" x >/dev/null 2>&1
  done
}
trap cleanup EXIT
# Ctrl-C must end the RUN, not just the copy. Under cron rsync sits in a
# pipeline with the progress filter, and when the filter - the last element -
# exits cleanly, bash treats a SIGINT that killed rsync as handled and carries
# on to the next CT. This trap makes the interrupt mean what the person who
# sent it meant: the run stops, the EXIT trap cleans up, and 130 says why.
# Deferred by bash until the foreground job ends, so nothing is torn down
# under a live rsync - exactly the old behaviour, now stated instead of
# inherited from how bash happens to treat a child that died of SIGINT.
trap 'exit 130' INT

# ---------- main loop ----------
ok=0; skipped=0; failed=0
# CTs R13 held back because a DR placement is still live. Separate from failed:
# nothing is wrong with them, but the run must not read as a healthy night.
DR_ACTIVE_IDS=()
# Copies that were transferred fine but got no snapshot. Not failed - the data
# is on the backup - and not silent either: a fleet that quietly stopped making
# rollback points looks identical to one that is making them.
SNAP_FAILED_IDS=()
matched=0            # CTs that survived --storage/--ctid; 0 = the flag is wrong
FAILED_IDS=()

for CT in "${CTS[@]}"; do
  end_iteration          # closes out the PREVIOUS CT: unmount, write state
  st_reset
  [[ -n "$ONLY_CTID" && "$CT" != "$ONLY_CTID" ]] && continue
  # From here every line of this CT's turn is said twice: once into the lane's
  # day log, once into this CT's own day file under logs/ct/.
  CT_LOG="$LOGDIR/ct/replica-$CT-$(date +%F).log"
  TGT=${TGT_MAP[$CT]:-$(( CT + OFFSET ))}
  DEST=${DEST_MAP[$CT]}
  # armed here: from now on failures are recorded. The lane filter below clears
  # it again, so a CT that belongs to the other lane never gets a state file
  # written by this one.
  ST_CTID="$CT"; ST_TGT="$TGT"; ST_DEST="$DEST"

  # --- one CT held back by a human, rather than the whole fleet -------------
  # PAUSE stops everything, which is right during a failback and far too blunt
  # for "this one is being fsck'd". Same idiom, one file per CT, and whatever
  # is written inside it is echoed every round: at 3am the first question is
  # "why is this one not copying", and the file should answer it. A pause that
  # is forgotten is a CT with no DR copy and nothing saying so, so tp status
  # and tp doctor report how long it has been there.
  if [[ -f "$BASE/pause/$CT" ]]; then
    _why=$(head -1 "$BASE/pause/$CT" 2>/dev/null)
    log "[$CT] PAUSED by pause/$CT${_why:+ - $_why}"
    # It counts as matched. `--ctid 105` on a paused CT found the row it was
    # asked for; reporting "no CT matched --ctid 105" would send somebody
    # hunting for a typo that is not there.
    [[ -n "$ONLY_CTID" ]] && matched=$(( matched + 1 ))
    st_skip paused; continue
  fi
  # The rc of the PREVIOUS run, read before st_begin overwrites it. rc=23 once
  # is almost always the ro,noload transient; rc=23 twice on the same CT is a
  # real filesystem problem, and only the run before this one can tell them
  # apart. Empty when this CT has never run.
  # Read the tool-prefixed file, and fall back to the pre-split name so a
  # fleet that has been running for months does not silently lose this on the
  # first round after an upgrade. Losing it would not fail a run - it would
  # quietly downgrade "this image is damaged" back to "probably transient",
  # which is the wrong direction to be wrong in.
  PREV_STATE="$BASE/state/$ST_PREFIX$CT.json"
  [[ -f "$PREV_STATE" ]] || PREV_STATE="$BASE/state/$CT.json"
  PREV_RC=$(sed -n 's/.*"rc": *\(-\{0,1\}[0-9][0-9]*\).*/\1/p' \
            "$PREV_STATE" 2>/dev/null | tail -1)

  # --- source config from the CLUSTER (this node is not a member; bkp is) ---
  cfgpath=$(ssh $SSH_OPT "$BKP_SSH" "ls /etc/pve/nodes/*/lxc/$CT.conf 2>/dev/null" </dev/null 2>/dev/null | head -1)
  if [[ -z "$cfgpath" ]]; then
    log "[$CT] ERROR: no config for CT $CT anywhere in the cluster - skip"
    st_fail no_source_config; continue
  fi
  srcnode="${cfgpath#/etc/pve/nodes/}"; srcnode="${srcnode%%/*}"
  ST_SRC_NODE="$srcnode"
  if [[ "$srcnode" == "$BKP_NODE" ]]; then
    # a CT that lives on the backup node IS (most likely) one of our copies
    if (( AUTO_DISCOVER )); then
      log "[$CT] NOTE: lives on $BKP_NODE (a copy?) - auto-discover skips it"
      ST_CTID=""; continue
    fi
    log "[$CT] ERROR: CT lives on $BKP_NODE - refusing to replicate the backup node onto itself"
    st_fail source_is_backup; continue
  fi
  # strip snapshot sections ([snapname]...) before parsing anything
  srccfg=$(ssh $SSH_OPT "$BKP_SSH" "cat $cfgpath" </dev/null 2>/dev/null | sed '/^\[/,$d')
  if [[ -z "$srccfg" ]]; then
    log "[$CT] ERROR: cannot read $cfgpath - skip"
    st_fail source_config_unreadable; continue
  fi

  # --- derive the CT's REAL storage from its own config: nothing to drift ---
  sid=$(printf '%s\n' "$srccfg" | sed -n 's/^rootfs:[[:space:]]*\([^:]*\):.*/\1/p' | head -1)
  vol=$(printf '%s\n' "$srccfg" | sed -n 's/^rootfs:[[:space:]]*[^:]*:\([^,]*\).*/\1/p' | head -1)
  if [[ -z "$sid" || -z "$vol" ]]; then
    log "[$CT] ERROR: cannot parse the rootfs line of $cfgpath - skip"
    st_fail rootfs_unparsable; continue
  fi
  ST_SRC_STORAGE="$sid"
  case " $SRC_STORAGES " in
    *" $sid "*) ;;
    *)
      if (( AUTO_DISCOVER )); then
        log "[$CT] NOTE: rootfs on '$sid' (not in SRC_STORAGES) - auto-discover skips it"
        ST_CTID=""; continue
      fi
      log "[$CT] ERROR: rootfs on '$sid' which is not in SRC_STORAGES ($SRC_STORAGES) - skip"
      st_fail storage_not_allowed; continue;;
  esac
  if [[ -n "${STOR_ASSERT[$CT]:-}" && "${STOR_ASSERT[$CT]}" != "$sid" ]]; then
    log "[$CT] ERROR: inventory asserts '${STOR_ASSERT[$CT]}' but the CT really lives on '$sid'"
    log "[$CT] ERROR:   someone moved it - fix the row (or drop the assertion) after checking WHY"
    st_fail storage_assert_mismatch; continue
  fi
  # lane filter comes AFTER derivation - membership is fact, not configuration.
  # ST_CTID cleared so this lane leaves the other lane's state file alone.
  if [[ -n "$LANE_STORAGE" && "$sid" != "$LANE_STORAGE" ]]; then ST_CTID=""; continue; fi
  matched=$(( matched + 1 ))
  # The rule goes after the lane filter, so a lane never prints a block for a
  # CT that belongs to the other one - and before the guards, so a guard that
  # refuses this CT prints inside the block that names it.
  hr_ct
  log "[$CT] CT $CT on $sid  ->  copy $TGT on $BKP_NODE, dest=$DEST"

  # --- destination must be resolvable before any data moves ---
  if ! dest_ready "$DEST"; then
    log "[$CT] ERROR: dest '$DEST' not usable on $BKP_NODE - skip"
    st_fail dest_inactive; continue
  fi

  # --- resolve the LIVE image path from PVE, then re-root it into the clone --
  IMG=$(pvesm path "$sid:$vol" 2>>"$LOG") || IMG=""
  if [[ -z "$IMG" || "$IMG" != /*/images/* ]]; then
    log "[$CT] ERROR: storage '$sid' unknown on THIS node, or not a dir storage (got '${IMG:-none}')"
    log "[$CT] ERROR:   define it here: pvesm add dir $sid --path <dataset-mountpoint> --is_mountpoint yes"
    st_fail storage_unknown_here; continue
  fi
  POOLPATH="${IMG%/images/*}"
  if ! prep_pool "$POOLPATH" "$sid"; then
    # A whole storage being unreachable is ONE fact, not one fact per CT. The
    # node holding it is down, or its dataset is not mounted; saying so forty
    # times buries the CT that failed for its own reason. prep_pool already
    # explained it once, so this is a single line, and it is SKIPPED rather
    # than failed - nothing about this CT is wrong. It clears itself: when the
    # storage comes back, the next round syncs. That is the whole difference
    # from pause/, which a human has to remember to undo.
    DOWN_COUNT[$POOLPATH]=$(( ${DOWN_COUNT[$POOLPATH]:-0} + 1 )); DOWN_SID[$POOLPATH]="$sid"
    log "[$CT] source '$sid' is down - skip (see GUARD R1 above)"
    st_skip source_down; continue
  fi
  RAW="${PREP_ROOT[$POOLPATH]}${IMG#"$POOLPATH"}"
  if [[ ! -f "$RAW" ]]; then
    log "[$CT] ERROR: raw image not found in snapshot ($RAW) - skip"
    st_fail image_missing; continue
  fi

  # --- R16: intake owns this image right now - leave the copy alone ----------
  # ct-migrate runs on THIS machine and writes into THIS raw image while a
  # container is being brought in (a presync every half hour; a first full
  # copy for hours). R1 makes the danger a question about ONE instant: if a
  # migrate round was in flight when the lane's snapshot was taken, the clone
  # holds half of one round and half of another, and syncing it puts that torn
  # state into the copy - where the next PBS backup archives it, permanently,
  # behind a green checkmark. Three reads of migrate's own state, all local:
  #
  #   running now            the snapshot may have landed inside the round
  #   finished after the     same doubt, stated after the fact - the round was
  #   snapshot               in flight when the instant was picked
  #   last real round did    a failed or interrupted round leaves the image
  #   not end ok             half-written UNTIL THE NEXT ROUND REPAIRS IT, so
  #                          the image is not a state anybody finished with.
  #                          "Real" skips the skipped records - a round that
  #                          moved nothing hides nothing
  #
  # Every skip clears itself: intake rounds leave gaps and the next replica
  # round reads a fresh snapshot. The rule deliberately also skips one safe
  # shape - a round that STARTED after the snapshot cannot reach the clone,
  # copy-on-write already split them - because one stale round is cheaper
  # than a second clock comparison somebody has to reason about at 2am. No
  # migrate state at all means this CT was never intake's: the guard is
  # silent, which is every container that did not come through migrate.
  _migst="$BASE/state/migrate-$CT.json"
  if [[ -f "$_migst" ]]; then
    if grep -q '"status":"running"' "$_migst" 2>/dev/null; then
      log "[$CT] GUARD R16: ct-migrate is mid-round on this image right now - skip"
      log "[$CT] GUARD R16:   the copy keeps its last complete state; the next round catches up"
      st_skip r16_intake_running; continue
    fi
    _mige=$(sed -n 's/.*"epoch":\([0-9][0-9]*\).*/\1/p' "$_migst" 2>/dev/null | head -1)
    if [[ "$_mige" =~ ^[0-9]+$ ]] && (( _mige >= ${PREP_EPOCH[$POOLPATH]:-0} )); then
      log "[$CT] GUARD R16: ct-migrate finished a round AFTER this lane's snapshot was taken"
      log "[$CT] GUARD R16:   the snapshot may hold half of that round - skip; the next round"
      log "[$CT] GUARD R16:   reads a fresh one"
      st_skip r16_intake_overlap; continue
    fi
    _miglast=$(tac "$BASE/state/migrate-$CT.runs.jsonl" 2>/dev/null \
               | grep -m1 -v '"status":"skipped"')
    if [[ -z "$_miglast" ]]; then
      log "[$CT] GUARD R16: intake state exists but its history is unreadable - skip"
      log "[$CT] GUARD R16:   nothing can say whether the image holds a finished round"
      st_skip r16_intake_torn; continue
    fi
    if ! grep -q '"status":"ok"' <<<"$_miglast"; then
      log "[$CT] GUARD R16: the last intake round that moved bytes did not finish ok"
      log "[$CT] GUARD R16:   the image holds a half-written round until ct-migrate repairs it;"
      log "[$CT] GUARD R16:   copying it now would put that torn state into copy $TGT"
      st_skip r16_intake_torn; continue
    fi
  fi

  # --- take the target, or leave it to the lane that already has it ---
  # First thing that would touch the destination, so this is where to serialise.
  if ! take_tgt_lock "$TGT"; then
    log "[$CT] NOTE: copy $TGT is being synced by another lane right now - skip (next run picks it up)"
    st_skip target_busy; continue
  fi

  # --- R14: and take it on the backup node too, where the copy actually is ---
  # Cheap and local first, then the one that costs an ssh: two lanes on this
  # machine settle it between themselves without touching the network. This
  # runs BEFORE R2 for the same reason it runs before the transfer - R2 reads
  # the copy's state, and an answer that another machine can change while it is
  # being acted on is not an answer.
  if (( DRY )); then
    peek_dst_lock "$BKP_SSH" "$TGT"; _dl=$?
    if (( _dl == 1 )); then
      log "[$CT] GUARD R14: DRY: copy $TGT is locked on $BKP_NODE - a real run would skip it"
      log "[$CT] GUARD R14: DRY:   holder: ${DST_LOCK_WHO:-<lock file unreadable>}"
      st_skip r14_dst_locked; continue
    elif (( _dl == 2 )); then
      log "[$CT] GUARD R14: DRY: $BKP_NODE did not answer - cannot say whether $TGT is free"
      st_fail r14_dst_unreachable; continue
    fi
  else
    take_dst_lock "$BKP_SSH" "$TGT"; _dl=$?
    if (( _dl == 1 )); then
      log "[$CT] GUARD R14: copy $TGT is locked on $BKP_NODE by another run - skip"
      log "[$CT] GUARD R14:   holder: ${DST_LOCK_WHO:-<lock file unreadable>}"
      log "[$CT] GUARD R14:   file:   $BKP_SSH:$(dst_lock_file "$TGT")"
      log "[$CT] GUARD R14:   if that run is gone, remove that file by hand. Nothing here"
      log "[$CT] GUARD R14:   breaks a lock on its own - see 'ketsync doctor'."
      st_skip r14_dst_locked; continue
    elif (( _dl == 2 )); then
      log "[$CT] GUARD R14: could not take the copy lock for $TGT on $BKP_NODE - NOTHING was transferred"
      log "[$CT] GUARD R14:   no answer is not 'nobody has it'. Syncing anyway is how two"
      log "[$CT] GUARD R14:   machines end up running rsync --delete into one dataset."
      st_fail r14_dst_unreachable; continue
    fi
  fi

  # --- every net line must carry a bridge=, or this CT does not get copied ---
  # Checked HERE, before anything is transferred, and not inside
  # mocknet_lines(): that function's stdout IS the config being written, so it
  # cannot report anything without corrupting the file it is building. Dropping
  # the line silently was the old behaviour and it is worse than refusing - the
  # copy comes up with one interface missing and looks healthy.
  if (( MOCKNET )); then
    _nobr=$(printf '%s\n' "$srccfg" | grep -E '^net[0-9]+:' | grep -v 'bridge=' || true)
    if [[ -n "$_nobr" ]]; then
      log "[$CT] ERROR: source config has a net line with no bridge= - NOT copying this CT"
      while IFS= read -r _l; do [[ -n "$_l" ]] && log "[$CT] ERROR:   $_l"; done <<< "$_nobr"
      log "[$CT] ERROR:   the copy would come up with that interface missing and look healthy"
      log "[$CT] ERROR:   fix the source config, or set MOCKNET=0 to copy with no network at all"
      st_fail net_no_bridge; continue
    fi
  fi

  # --- R2: never overwrite a copy that is RUNNING (DR promoted) ---
  st=$(ssh $SSH_OPT "$BKP_SSH" "pct status $TGT 2>/dev/null" </dev/null 2>/dev/null | awk '{print $2}')
  if [[ "$st" == "running" ]]; then
    log "[$CT] GUARD R2: copy $TGT is RUNNING on $BKP_NODE (DR active?) - SKIP + check by hand"
    st_skip r2_running; continue
  fi

  # --- R13: a DR placement is live for this CT, so the copy is the last one ---
  # R2 only shields a copy that is RUNNING. A DR copy is stopped by design -
  # onboot 0, on a bridge with no uplink - so R2 never shields it, and PAUSE was
  # the only thing that did.
  #
  # PAUSE cannot be relied on, because of how this actually fails. The storage
  # node dies with no warning; nobody gets to type `touch PAUSE`, and the file
  # would have been on the machine that died anyway. When it comes back, cron
  # fires on schedule and copies the PRE-DISASTER production image over the DR
  # copy. Nothing is lost immediately - the newest data is on the 9xxx running
  # on a compute node - but $TGT now looks like a fresh, healthy copy while
  # holding data from before the outage. Somebody reads a green `tp status`,
  # believes it, skips the recall, and loses every hour the customer worked
  # during the DR.
  #
  # The fact that settles it is one PVE wrote itself: ct-distribute.sh creates
  # 9<id> in pmxcfs, and only after a good transfer (D6). If that config exists
  # anywhere in the cluster, a DR placement for this container is live and has
  # not been cleaned up. It needs no marker in anybody's rootfs, no timestamp
  # and nothing for a human to remember, it is per-container rather than
  # fleet-wide - the containers that never moved keep being replicated, which
  # matters during a long outage - and it clears itself the moment somebody
  # runs the `pct destroy 9<id>` that the DR guide already ends with.
  _dr=$(( CT + DR_OFFSET ))
  _dract=$(ssh $SSH_OPT "$BKP_SSH" \
      "ls /etc/pve/nodes/*/lxc/$_dr.conf 2>/dev/null" </dev/null 2>/dev/null | head -1)
  if [[ -n "$_dract" ]]; then
    log "[$CT] GUARD R13: CT $_dr exists - a DR placement for this container is live"
    log "[$CT] GUARD R13:   $_dract"
    log "[$CT] GUARD R13:   copy $TGT is the last data from before the outage, and the"
    log "[$CT] GUARD R13:   newest data is on $_dr. Overwriting $TGT now would make it"
    log "[$CT] GUARD R13:   LOOK current while holding neither."
    log "[$CT] GUARD R13:   recall $_dr first, then destroy it. This clears itself."
    # Skipped, not failed - nothing is wrong with this container. But the run
    # must not exit 0 while it is true, for the same reason R12 does not: a
    # nightly cron reporting success while several containers have no fresh
    # copy is how a DR turns into a second incident. Counted separately from
    # `failed` so the summary still tells them apart.
    DR_ACTIVE_IDS+=("$CT/$_dr")
    st_skip r13_dr_active; continue
  fi

  # --- R4: the target VMID must not belong to any OTHER guest, anywhere ---
  # This used to live at the bottom, next to the config write, and only ran the
  # first time a copy was created. That is the same hole G7 exists to close in
  # ct-migrate, in the same words: R2 above only sees a copy that is RUNNING on
  # the backup node, and R8 below only reads this node's own config directory.
  # A STOPPED guest on ANOTHER node holding this id is invisible to both - and
  # by the time the old R4 noticed, rsync --delete had already emptied that
  # guest's rootfs into ours. It is checked here, before anything is
  # transferred, and on every run rather than only on the first.
  _own="/etc/pve/nodes/$BKP_NODE/lxc/$TGT.conf"
  _owners=$(ssh $SSH_OPT "$BKP_SSH" \
      "ls /etc/pve/nodes/*/lxc/$TGT.conf /etc/pve/nodes/*/qemu-server/$TGT.conf 2>/dev/null" \
      </dev/null 2>/dev/null | grep -vxF "$_own" || true)
  if [[ -n "$_owners" ]]; then
    log "[$CT] GUARD R4: VMID $TGT already belongs to another guest - NOT syncing"
    while IFS= read -r _o; do [[ -n "$_o" ]] && log "[$CT] GUARD R4:   $_o"; done <<< "$_owners"
    log "[$CT] GUARD R4:   rsync --delete into that guest's volume would empty its rootfs"
    log "[$CT] GUARD R4:   fix: give this row an explicit tgt_ctid in $(basename "$INV")"
    st_fail r4_vmid_taken; continue
  fi

  # --- R8: an existing copy config must agree with THIS row's dest ---
  # Read once here; reused at the bottom so config creation costs no extra ssh.
  tgtcfg=$(ssh $SSH_OPT "$BKP_SSH" "cat /etc/pve/nodes/$BKP_NODE/lxc/$TGT.conf 2>/dev/null" </dev/null 2>/dev/null)
  # --move-dest moves a copy that EXISTS. With none there, there is nothing to
  # move and nothing to be confused about: a plain round makes one, on the pool
  # the row names, which is where the operator wanted it in the first place.
  if (( MOVE_DEST )) && [[ -z "$tgtcfg" ]]; then
    log "[$CT] MOVE: there is no copy $TGT on $BKP_NODE yet - nothing to move"
    log "[$CT] MOVE:   a normal round creates it on '$DEST':  ct-replica.sh --ctid $CT"
    st_fail move_no_copy; continue
  fi
  if [[ -n "$tgtcfg" ]]; then
    ST_CFG_PRESENT=1
    # --- R15: PVE itself is holding this copy, so it is not ours right now ---
    # Read out of the config we already have, before anything below reports on a
    # guest another tool is in the middle of. R14's lock is the one ketsync
    # takes; this is the one PVE takes, and neither can see the other.
    #
    # The case that matters is `lock: backup`: PBS is reading this copy's rootfs
    # while rsync --delete would be writing into it. The copy survives that -
    # the next round repairs it - but the BACKUP does not. It ends up holding
    # files from two different rounds and restores to a filesystem that never
    # existed on any machine, and nothing about it looks wrong until the day
    # somebody restores it.
    #
    # Any lock counts, not just backup. snapshot, rollback, migrate, destroy -
    # every one of them means a tool that is not this one owns the guest right
    # now, and none of them wants an rsync underneath. The value is logged so
    # the operator knows which.
    _plock=$(printf '%s\n' "$tgtcfg" | sed -n 's/^lock:[[:space:]]*\(.*\)/\1/p' | head -1)
    if [[ -n "$_plock" ]]; then
      if [[ "$_plock" == disk ]]; then
        # `disk` is the value THIS engine sets while it writes into the copy
        # (see the transfer step), so a round that died mid-rsync leaves it
        # behind in pmxcfs - which survives every reboot - and R15 would then
        # hold this copy back forever while the log said vzdump was to blame.
        # It cannot be a live run's: this run holds the R14 lock right now,
        # and R14 is what makes runs exclusive. It is either ketsync's own
        # leftover or a disk operation a human is running by hand, and those
        # two cannot be told apart from here - so nothing is broken
        # automatically, and the one command that clears it is named instead.
        log "[$CT] GUARD R15: copy $TGT still carries 'lock: disk' on $BKP_NODE - skip"
        log "[$CT] GUARD R15:   that is the lock THIS tool sets while it writes into the copy, and"
        log "[$CT] GUARD R15:   no replica run is live (this run holds the copy's R14 lock). So it"
        log "[$CT] GUARD R15:   is a leftover from a round that died mid-write - or a disk operation"
        log "[$CT] GUARD R15:   somebody is running by hand, and those look identical from here."
        log "[$CT] GUARD R15:   if nothing else is touching $TGT, clear it and the next round runs:"
        log "[$CT] GUARD R15:     ssh $BKP_SSH 'pct unlock $TGT'"
        st_skip r15_stale_lock; continue
      fi
      log "[$CT] GUARD R15: copy $TGT is locked by PVE on $BKP_NODE (lock: $_plock) - skip"
      log "[$CT] GUARD R15:   something else owns this guest right now. For 'backup' that is"
      log "[$CT] GUARD R15:   vzdump reading the rootfs this run would be writing into: the copy"
      log "[$CT] GUARD R15:   would survive, the backup would not - it would hold half of one"
      log "[$CT] GUARD R15:   round and half of the next."
      log "[$CT] GUARD R15:   nothing to undo. The lock clears when that job ends and the next"
      log "[$CT] GUARD R15:   round copies this container normally."
      st_skip r15_pve_lock; continue
    fi
    if printf '%s\n' "$tgtcfg" | grep -qE '^net[0-9]+:'; then
      ST_MOCKNET=1
      # R11: going live during DR means moving the copy onto a real bridge, and
      # coming back from DR means moving it back. Forgetting the second half
      # leaves a STOPPED copy holding a production IP and MAC one click away
      # from the wire - and R9 cannot see it, because R9 only polices the mock
      # bridge. R2 already skipped this CT if the copy is running, so reaching
      # here with a real bridge means nobody put it back.
      if (( MOCKNET )); then
        _badbr=$(printf '%s\n' "$tgtcfg" | grep -E '^net[0-9]+:' \
                 | grep -vE "bridge=$MOCKNET_BRIDGE(,|$)" || true)
        if [[ -n "$_badbr" ]]; then
          ST_MOCKNET=0
          log "[$CT] WARN R11: copy $TGT is STOPPED but its net is NOT on $MOCKNET_BRIDGE:"
          while IFS= read -r _l; do [[ -n "$_l" ]] && log "[$CT] WARN R11:   $_l"; done <<< "$_badbr"
          log "[$CT] WARN R11:   a DR promotion was not reverted - this copy carries a production"
          log "[$CT] WARN R11:   IP/MAC and would collide the moment anyone starts it"
          log "[$CT] WARN R11:   fix: put every net line back on bridge=$MOCKNET_BRIDGE"
        fi
      fi
    fi
    csid=$(printf '%s\n' "$tgtcfg" | sed -n 's/^rootfs:[[:space:]]*\([^:]*\):.*/\1/p' | head -1)
    # Before R8, because R8 is the thing being answered. Every guard that says
    # "do not touch this copy" has already run above.
    if (( MOVE_DEST )); then
      move_copy_dest "$csid"
      continue
    fi
    if [[ "$csid" != "$DEST" ]]; then
      log "[$CT] GUARD R8: copy $TGT config points at '${csid:-<none>}' but this row's dest is '$DEST'"
      log "[$CT] GUARD R8:   the dest column changed after the copy was created; syncing now would fill"
      log "[$CT] GUARD R8:   the new dataset while the config still boots the old one"
      log "[$CT] GUARD R8:   fix: move it, in the safe order, with one command:"
      log "[$CT] GUARD R8:     ct-replica.sh --ctid $CT --move-dest"
      log "[$CT] GUARD R8:   (copies first, verifies, repoints the config, and only then removes"
      log "[$CT] GUARD R8:   the old dataset - add --dry-run to read the plan first). Or destroy"
      log "[$CT] GUARD R8:   the old copy yourself and let the next round recreate it on '$DEST'."
      st_fail r8_dest_changed; continue
    fi
  fi

  # --- R3: destination dataset exists AND is mounted ---
  TDS="${DEST_DS[$DEST]}/subvol-$TGT-disk-0"
  ST_DS="$TDS"
  # R3 splits under DRY, and only there: `zfs list` is a read and still happens,
  # `zfs create` is a write and does not. The mounted=yes half below is written
  # ONCE and runs in both modes - a second copy of it inside a DRY branch would
  # be the same literal text twice, and its mutation anchors on the first
  # occurrence, so the copy would silently take the mutation and the real path
  # would stop being tested.
  DRY_NO_DS=0
  if (( DRY )); then
    if ! ssh $SSH_OPT "$BKP_SSH" "zfs list $TDS >/dev/null 2>&1" </dev/null >/dev/null 2>&1; then
      log "[$CT] DRY: would create dataset $TDS on $BKP_NODE (xattr=sa, acltype=posixacl)"
      DRY_NO_DS=1
    fi
  elif ! ssh $SSH_OPT "$BKP_SSH" \
      "zfs list $TDS >/dev/null 2>&1 || zfs create -o xattr=sa -o acltype=posixacl $TDS" \
      </dev/null >>"$LOG" 2>&1; then
    log "[$CT] ERROR: cannot prepare dataset $TDS on backup - skip"
    st_fail dataset_create; continue
  fi
  if (( ! DRY_NO_DS )); then
    read -r tmounted tmnt < <(ssh $SSH_OPT "$BKP_SSH" \
        "zfs get -H -o value mounted,mountpoint $TDS 2>/dev/null | paste -sd' '" </dev/null 2>/dev/null)
    if [[ "${tmounted:-}" != "yes" || -z "${tmnt:-}" || "$tmnt" == "none" ]]; then
      log "[$CT] GUARD R3: $TDS NOT MOUNTED on backup (mounted=${tmounted:-?}) - rsync would fill the backup ROOT fs - skip"
      st_fail r3_not_mounted; continue
    fi
    (( DRY )) && log "[$CT] DRY: dest dataset $TDS is present and mounted at $tmnt"
  fi

  if (( DRY )); then
    # what the copy config would say. R5 never rewrites one that exists, so the
    # only interesting case is the first round for this CT.
    if [[ -z "$tgtcfg" ]]; then
      log "[$CT] DRY: would create copy config $TGT on $BKP_NODE (dest=$DEST, onboot=0, stopped)"
      log "[$CT] DRY:   rootfs: ${DEST}:subvol-${TGT}-disk-0"
      (( MOCKNET )) && log "[$CT] DRY:   net kept from the source, moved onto $MOCKNET_BRIDGE tag ${MOCKNET_TAG:-<from source>}"
    else
      log "[$CT] DRY: copy config $TGT already exists on $BKP_NODE - R5 would leave it untouched"
    fi
    log "[$CT] DRY: source image $RAW on '$sid' would be read from the clone, not live"
    if (( SNAP_KEEP > 0 )); then
      log "[$CT] DRY: after a green round it would snapshot $TDS@ketsync-$(date +%F), keeping $SNAP_KEEP"
    else
      log "[$CT] DRY: SNAP_KEEP=0 - this copy gets no snapshot and no rollback point"
    fi
    log "[$CT] dry-run - nothing was written"
    st_ok; continue
  fi
  # --- R6: loop-mount ro,noload and pull ---
  MNT="$MNT_BASE/$CT"
  mkdir -p "$MNT"
  if mountpoint -q "$MNT"; then
    umount "$MNT" >>"$LOG" 2>&1 || {
      log "[$CT] ERROR: stale mount at $MNT would not unmount - skip"
      st_fail stale_mount; continue; }
  fi
  if ! mount -o loop,ro,noload "$RAW" "$MNT" >>"$LOG" 2>&1; then
    log "[$CT] ERROR: loop-mount failed ($RAW) - skip"
    st_fail loop_mount; continue
  fi
  CUR_MNT="$MNT"                # from here a kill must still bring it back down
  used=$(df -h "$MNT" 2>/dev/null | awk 'NR==2{print $3}')
  # --- R15, the other direction: while THIS run writes, vzdump must not read.
  # R15 above covers a backup that started first. This covers a backup whose
  # schedule fires mid-round: rsync is rewriting the copy file by file, vzdump
  # snapshots it at some instant in the middle, and the archive holds half of
  # one round and half of the other - readable, restorable, and wrong. So the
  # copy is locked in pmxcfs for exactly the window the bytes move, with the
  # one enumerated value nothing else on this fleet uses: `backup` is vzdump's
  # own, `mounted` is what a human's pct mount sets, `disk` is ours. vzdump
  # refuses a locked guest LOUDLY - that copy's backup fails in the job log and
  # the mail - which is the trade this buys: a failed backup somebody sees
  # instead of a torn one nobody does. Only when a config exists: with no
  # config there is nothing vzdump could target.
  CFG_LOCKED=""
  if [[ -n "$tgtcfg" ]]; then
    if ssh $SSH_OPT "$BKP_SSH" "pct set $TGT --lock disk" </dev/null >>"$LOG" 2>&1; then
      CFG_LOCKED="$TGT"
    else
      # The race R15 cannot see: vzdump took the lock between R15's read and
      # this write. Backing up won the copy for this round; skip, exactly as
      # R15 would have, rather than writing under a running backup.
      log "[$CT] GUARD R15: could not lock copy $TGT - a backup started after this round's checks"
      log "[$CT] GUARD R15:   vzdump owns the copy now. Skipped, same as if it had been first."
      st_skip r15_lock_race; continue
    fi
  fi
  log "[$CT] SYNC -> $TGT dest=$DEST (used ${used:-?}, bw=$BWLIMIT, src=$sid)"
  st_begin                      # publish "in flight" before the long part starts
  # --timeout=300 catches an IO-stall on the receiver that keeps TCP alive
  # (ServerAlive cannot see it). The excludes come from ctrep-exclude.conf,
  # which ct-failback.sh reads too - both directions run --delete, so a pattern
  # that applied one way only would DELETE from production on the way back.
  RS=(-aHAX --numeric-ids --delete --inplace "--bwlimit=$BWLIMIT" --timeout=300
      "--exclude-from=$EXCL"
      -e "ssh $SSH_DATA")
  SF=$(mktemp "${TMPDIR:-/tmp}/ctrep-stats.XXXXXX" 2>/dev/null) || SF=""
  [[ -n "$SF" ]] && RS+=(--stats "--log-file=$SF" '--log-file-format=')
  rc=0; t0=$SECONDS
  if [ -t 1 ]; then
    rsync "${RS[@]}" --info=progress2 --no-inc-recursive "$MNT"/ "$BKP_SSH:$tmnt/" || rc=$?
  else
    # Same progress under cron that a tty gets, filtered to one line a minute.
    # PIPESTATUS[0] and not $?: the rc every guard below judges must be
    # rsync's, never the filter's.
    rsync "${RS[@]}" --info=progress2 --no-inc-recursive "$MNT"/ "$BKP_SSH:$tmnt/" 2>&1 | rs_progress "$CT"
    rc=${PIPESTATUS[0]}
  fi
  RS_SECS=$(( SECONDS - t0 )); ST_RC=$rc
  umount "$MNT" >>"$LOG" 2>&1 && CUR_MNT="" \
    || log "[$CT] WARN: umount $MNT failed - cleanup trap will retry"

  # per-CT numbers, tty or cron alike. "changed" is the data rsync actually had
  # to move - trending toward ~0 across rounds = the copy has converged; a jump
  # = something big changed inside the CT.
  if [[ -n "$SF" && -s "$SF" ]]; then
    RS_FILES=$(_rs_num 'Number of .*files transferred' "$SF")
    RS_LITERAL=$(_rs_num 'Literal data' "$SF")
    RS_SENT=$(_rs_num 'Total bytes sent' "$SF")
    RS_TOTAL=$(_rs_num 'Total file size' "$SF")
    for _n in RS_FILES RS_LITERAL RS_SENT RS_TOTAL; do
      [[ "${!_n}" =~ ^[0-9]+$ ]] || printf -v "$_n" 0
    done
    avg=0; (( RS_SECS > 0 )) && avg=$(( RS_SENT / RS_SECS ))
    log "[$CT] stats: files=$RS_FILES changed=$(hsize "$RS_LITERAL") wire=$(hsize "$RS_SENT") of $(hsize "$RS_TOTAL") time=${RS_SECS}s avg=$(hsize "$avg")/s"
  fi
  [[ -n "$SF" ]] && rm -f "$SF"

  # --- R5: judge the sync BEFORE any config work ---
  if [[ $rc -ne 0 && $rc -ne 24 ]]; then
    if [[ $rc -eq 23 ]]; then
      if [[ "${PREV_RC:-}" == "23" ]]; then
        log "[$CT] ERROR: rc=23 TWICE IN A ROW - not a transient any more"
        log "[$CT] ERROR:   ro,noload cannot read metadata that is still only in the ext4 journal,"
        log "[$CT] ERROR:   but two snapshots in a row means the image itself is damaged."
        log "[$CT] ERROR:   1) stop CT $CT on $srcnode"
        log "[$CT] ERROR:   2) on THIS node, look first:  e2fsck -fn $IMG"
        log "[$CT] ERROR:   3) repair only with the CT stopped:  e2fsck -fp $IMG"
        st_fail r5_rsync_repeat; continue
      fi
      log "[$CT] HINT: rc=23 once is usually the ro,noload transient - files whose metadata was"
      log "[$CT] HINT:   still in the ext4 journal when the snapshot was taken. The next run takes"
      log "[$CT] HINT:   a fresh snapshot and normally picks them up; if it fails again, it says so."
    fi
    log "[$CT] GUARD R5: sync FAILED (rc=$rc) - copy config NOT created"
    st_fail r5_rsync; continue
  fi
  log "[$CT] OK -> $TGT (rc=$rc)"

  # --- extra mountpoints are NOT replicated, by decision. The risk is not the
  #     missing data, it is a copy that boots fine and serves an EMPTY dir. ---
  mplist=$(printf '%s\n' "$srccfg" | grep -E '^mp[0-9]+:' || true)
  if [[ -n "$mplist" ]]; then
    while IFS= read -r mpline; do
      [[ -z "$mpline" ]] && continue
      mpname="${mpline%%:*}"
      mppath=$(printf '%s\n' "$mpline" | sed -n 's/.*[,[:space:]]mp=\([^,]*\).*/\1/p')
      ST_MP+=("${mppath:-$mpname}")
      log "[$CT] WARN: $mpname -> ${mppath:-<no mp= found>} is NOT replicated - empty dir on the copy"
    done <<< "$mplist"
  fi

  # --- first success only: create the copy config (R5) ---
  # R4 already ran, before the transfer - see above.
  if [[ -z "$tgtcfg" ]]; then
    SIZE=$(printf '%s\n' "$srccfg" | sed -n 's/^rootfs:.*size=\([^,]*\).*/\1/p')
    newcfg=$( printf '%s\n' "$srccfg" \
                | grep -Ev '^(net[0-9]+|mp[0-9]+|rootfs|onboot|parent|snaptime|lock|unused[0-9]+):'
              echo "rootfs: ${DEST}:subvol-${TGT}-disk-0,size=${SIZE:-8G}"
              echo "onboot: 0"
              (( MOCKNET )) && mocknet_lines "$srccfg" )
    # Written, then read back and compared. A write cut short by a dropped
    # connection or a full /etc/pve leaves a half config, and R5 never rewrites
    # a config that exists - so the damage would be permanent and every later
    # run would report this CT as healthy. Verified once, here, is cheap.
    if printf '%s\n' "$newcfg" | ssh $SSH_OPT "$BKP_SSH" "cat > /etc/pve/nodes/$BKP_NODE/lxc/$TGT.conf" \
       && [[ "$(ssh $SSH_OPT "$BKP_SSH" "cat /etc/pve/nodes/$BKP_NODE/lxc/$TGT.conf" </dev/null 2>/dev/null)" == "$newcfg" ]]; then
      ST_CFG_PRESENT=1
      (( MOCKNET )) && ST_MOCKNET=1
      log "[$CT] INIT: created copy config $TGT on $BKP_NODE (dest=$DEST, onboot=0, stopped$( (( MOCKNET )) && echo ", net on $MOCKNET_BRIDGE tag ${MOCKNET_TAG:-<from source>}" ))"
    else
      log "[$CT] ERROR: the config on $BKP_NODE does not match what was sent (truncated write)"
      log "[$CT] ERROR:   the rootfs data is fine; only the config is bad"
      log "[$CT] ERROR:   delete it and run again: rm /etc/pve/nodes/$BKP_NODE/lxc/$TGT.conf"
      st_fail cfg_write; continue
    fi
  fi

  # --- the round was green, so freeze it ---
  # Here and nowhere else: everything above this line can still turn the round
  # into a failure, and a snapshot of a copy that was only half written is a
  # rollback point that restores to nothing. SNAP_KEEP=0 turns it off, and
  # turning it off leaves whatever is already there alone - a knob that
  # destroys history when you set it to zero is a knob nobody dares touch.
  if (( SNAP_KEEP > 0 )); then
    ST_SNAP="ketsync-$(date +%F)"
    if ! snap_after_green "$TDS" "$ST_SNAP"; then
      ST_SNAP=failed
      SNAP_FAILED_IDS+=("$CT/$TGT")
    fi
  fi
  st_ok
done

end_iteration          # closes out the LAST CT; the EXIT trap then finds nothing

# ---------- summary + healthcheck ----------
hr2
log "=== lane '$LANE' finished: ok=$ok skipped=$skipped failed=$failed ==="
# Said once at the end as well as once per CT: the per-CT lines scroll past,
# and this is the line an operator reads before running it for real.
(( DRY )) && log "dry-run only - nothing was written, here or on the backup node"

# A misspelled --storage or --ctid matches nothing, does nothing, and exits 0.
# Under cron that looks exactly like a healthy run, so say it and fail.
if (( matched == 0 )) && [[ -n "$LANE_STORAGE$ONLY_CTID" ]]; then
  log "ERROR: no CT matched${LANE_STORAGE:+ --storage $LANE_STORAGE}${ONLY_CTID:+ --ctid $ONLY_CTID} - nothing was replicated"
  exit 1
fi

# A storage that is down took CTs out of replication, and every one of them is
# counted as skipped - which on its own would exit 0 and read as a healthy
# night. Name it, and do not exit 0 while it is true.
_down=0
for _p in "${!DOWN_COUNT[@]}"; do
  log "SOURCE DOWN: '${DOWN_SID[$_p]}' (${PREP_WHY[$_p]:-unusable}) - ${DOWN_COUNT[$_p]} CT not replicated this round"
  _down=1
done
if (( _down )); then
  log "SOURCE DOWN:   they resume by themselves when the storage is back - nothing to undo."
  log "SOURCE DOWN:   if the node holding it is gone for good, move those CTs and their"
  log "SOURCE DOWN:   config follows them; the next round picks up their new home."
fi

if (( ${#DR_ACTIVE_IDS[@]} )); then
  log "DR ACTIVE: ${#DR_ACTIVE_IDS[@]} container(s) not replicated - their newest data is on a 9xxx"
  log "DR ACTIVE:   ${DR_ACTIVE_IDS[*]}   (production/DR)"
  log "DR ACTIVE:   recall each one, then destroy the 9xxx. This clears itself."
fi

# Said the same way SOURCE DOWN is, and for the same reason: the bytes arrived,
# so counting these as failures would be a lie, and exiting 0 would be a
# different one. A copy with no snapshot has no rollback point and no history -
# which is only discovered on the day somebody needs one.
if (( ${#SNAP_FAILED_IDS[@]} )); then
  log "NO SNAPSHOT: ${#SNAP_FAILED_IDS[@]} copy(ies) were replicated but not snapshotted"
  log "NO SNAPSHOT:   ${SNAP_FAILED_IDS[*]}   (production/copy)"
  log "NO SNAPSHOT:   the data is on $BKP_NODE. What is missing is the rollback point"
  log "NO SNAPSHOT:   and the day's history: check free space on the destination pool."
  log "NO SNAPSHOT:   SNAP_KEEP=0 in $(basename "$CONF") turns snapshots off altogether."
fi

if (( failed > 0 )); then
  log "NEEDS ATTENTION -> CT: ${FAILED_IDS[*]}"
  [[ -n "$HEALTH_URL" ]] && { curl -fsS -m 10 "$HEALTH_URL/fail" >/dev/null 2>&1 || true; }
  exit 1
fi
if (( _down )); then
  [[ -n "$HEALTH_URL" ]] && { curl -fsS -m 10 "$HEALTH_URL/fail" >/dev/null 2>&1 || true; }
  exit 1
fi
if (( ${#DR_ACTIVE_IDS[@]} )); then
  [[ -n "$HEALTH_URL" ]] && { curl -fsS -m 10 "$HEALTH_URL/fail" >/dev/null 2>&1 || true; }
  exit 1
fi
if (( ${#SNAP_FAILED_IDS[@]} )); then
  [[ -n "$HEALTH_URL" ]] && { curl -fsS -m 10 "$HEALTH_URL/fail" >/dev/null 2>&1 || true; }
  exit 1
fi
[[ -n "$HEALTH_URL" ]] && { curl -fsS -m 10 "$HEALTH_URL" >/dev/null 2>&1 || true; }
exit 0
