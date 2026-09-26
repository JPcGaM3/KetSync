#!/usr/bin/env bash
# =============================================================================
#  ct-move.sh - move one LXC container's rootfs onto a storage of another (or
#  the same) PVE node: repeated presync rounds while it RUNS, then one short
#  --final round after a human has STOPPED it.
#
#  The shape is ct-migrate's, deliberately: nothing here stops or starts a
#  container. A person stops it, runs --final, checks, and types pct start.
#
#  Works for any direction the destination's PVE can allocate into:
#    NFS -> local (zfspool / lvmthin / dir), local -> local, local -> NFS.
#  The transfer is issued ON the destination node, pulling from the source
#  node (rsync cannot do remote-to-remote), exactly like ct-distribute.
#
#  Safety, in the order it is checked:
#    - the destination storage must exist on the destination node, be ACTIVE,
#      and be proven not to be the node's root filesystem - before anything
#      is allocated, and again on the path after allocation. A wrong storage
#      id once filled a node's root disk and hung it; that is the case this
#      refuses.
#    - one run per container here (flock) and one per target id on the
#      destination (/run/ketsync-ct-<id>.lock, same file ketsync's engines use)
#    - the volume made by round one is recorded in state/ and verified to
#      still exist every round; it is never silently re-allocated
#    - --final reads only a STOPPED source whose image nobody has attached,
#      writes the config only after rsync rc 0/24, and leaves the old volume
#      untouched and referenced as unusedN - the rollback
#    - rsync compares mtimes to the nanosecond (--modify-window=-1): a file
#      rewritten twice inside one second at the same size would otherwise be
#      skipped by --final and stay stale
# =============================================================================
set -uo pipefail
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

usage(){ cat <<'EOF'
usage: ct-move.sh --src-ip <ip> --src-ctid <id> --dst-ip <ip> --dst-ctid <id>
                  --storage <dst-storage-id> --bwlimit <MB/s>
                  [--zfs-props k=v[,k=v...]] [--final] [--dry-run]

  --src-ip     IP of the node the container lives on now
  --src-ctid   its id there
  --dst-ip     IP of the node it moves to (may be the same node)
  --dst-ctid   its id there. The SAME id moves the config (both nodes in one
               cluster); a DIFFERENT id gets its own config after the first good
               round, ONCE, like ketsync migrate: net on MOCKNET_BRIDGE, onboot 0,
               never rewritten - set its real network ahead of the cutover.
               --final leaves the old container stopped under lock: migrate
  --storage    PVE storage id ON THE DESTINATION NODE (zfspool, lvmthin, lvm, dir, nfs, cifs)
  --bwlimit    MB/s for rsync (no default on purpose)
  --zfs-props  zfspool only, set when the dataset is created, e.g. for MySQL/InnoDB:
               recordsize=16K,compression=lz4,atime=off
               recordsize only affects data written AFTER it is set, so it belongs on
               the first round. No flag = PVE defaults.
  --final      the container is STOPPED: copy the last delta, move the config
  --dry-run    every check, nothing written, then the plan

  run presync as often as you like while it runs; each round prints how long the
  copy took, which is roughly what --final will take while it is down.
EOF
}

SRC=""; DST=""; CTID=""; STORAGE=""; BW=""; NEW=""; ZPROPS=""; FINAL=0; DRY=0
while (( $# )); do
  case "$1" in
    --src-ip) SRC="${2:-}"; shift 2;;
    --dst-ip) DST="${2:-}"; shift 2;;
    --src-ctid) CTID="${2:-}"; shift 2;;
    --dst-ctid) NEW="${2:-}"; shift 2;;
    --storage) STORAGE="${2:-}"; shift 2;;
    --bwlimit) BW="${2:-}"; shift 2;;
    --zfs-props) ZPROPS="${2:-}"; shift 2;;
    --final) FINAL=1; shift;;
    --dry-run) DRY=1; shift;;
    -h|--help) usage; exit 0;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2;;
  esac
done
for v in SRC:--src-ip CTID:--src-ctid DST:--dst-ip NEW:--dst-ctid STORAGE:--storage BW:--bwlimit; do
  _n="${v%%:*}"
  [[ -n "${!_n}" ]] || { echo "missing ${v#*:} (no default)" >&2; usage >&2; exit 2; }
done
[[ "$CTID" =~ ^[0-9]+$ && "$NEW" =~ ^[0-9]+$ ]] || { echo "--src-ctid and --dst-ctid must be numbers" >&2; exit 2; }
[[ "$BW" =~ ^[0-9]+$ ]] || { echo "--bwlimit must be a number (MB/s)" >&2; exit 2; }

for c in ssh flock awk sed tee date; do
  command -v "$c" >/dev/null || { echo "missing command: $c" >&2; exit 2; }
done

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="$BASE/state"; LOGDIR="$BASE/logs"
mkdir -p "$STATE" "$LOGDIR" || exit 2
LOG="$LOGDIR/ct-move-$CTID-$(date +%F).log"
# The island bridge a new-id config lives on until --final - the same knob, in
# the same file, that ct-migrate's G8 reads. Never guessed.
MOCK=$(sed -n 's/^MOCKNET_BRIDGE=["]*\([^"# ]*\).*/\1/p' "$BASE/conf/ctmig.conf" 2>/dev/null | tail -1)
log(){ printf '%s [%s] %s\n' "$(date '+%F %T')" "$CTID" "$*" | tee -a "$LOG"; }
die(){ log "ERROR: $*"; exit 1; }
# Storages whose images live on THIS machine (the storage node). A source CT
# on one of them is read HERE, from its image, and pushed straight to the
# destination: one network hop, local disk, nothing asked of the node the CT
# runs on. Anything else is pulled by the destination from that node. The key
# must exist (empty is a decision, missing is not).
grep -qE '^SRC_STORAGES=' "$BASE/conf/ctmig.conf" 2>/dev/null \
  || die "SRC_STORAGES is missing from $BASE/conf/ctmig.conf - list the storage node's pools there (\"\" for none)"
SRC_STORAGES=$(sed -n 's/^SRC_STORAGES=["]*\([^"#]*\).*/\1/p' "$BASE/conf/ctmig.conf" | tail -1)
LIVE_FALLBACK=$(sed -n 's/^LIVE_FALLBACK=["]*\([0-9]*\).*/\1/p' "$BASE/conf/ctmig.conf" | tail -1)
CIPHERS=$(sed -n 's/^SSH_CIPHERS=["]*\([^"# ]*\).*/\1/p' "$BASE/conf/ctmig.conf" | tail -1)
SSH_DATA="ssh -o BatchMode=yes -o Compression=no${CIPHERS:+ -c $CIPHERS}"

SSH_OPT="-o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=30 -o ServerAliveCountMax=6"
# bssh: ssh, with the remote command run by bash whatever root's login shell
# is. ssh hands its command string to the LOGIN shell, and a node whose root
# logs into zsh (pve-r33, 2026-09) reads it differently in exactly the way that
# turns a failing check into a pass: an unmatched glob aborts the whole command
# (`ls /etc/pve/nodes/*/lxc/<id>.conf` answers nothing = "that id is free"), and
# an unquoted $var is not split (a port loop sees one word = "no uplink"). The
# team keeps zsh, so every remote command goes through here instead. The
# command is single-quoted for the login shell, which sh, bash and zsh all read
# the same way; exec keeps its exit status and its stdin. Options pass through
# untouched, and a call with no command (`ssh -O exit`) is plain ssh. This
# function is identical in every file that has it - tests/remote-bash checks.
bssh(){
  local a=() c
  while (( $# )); do
    case "$1" in
      -[BbcDEeFIiJLlmOoPpQRSWw]) a+=("$1" "${2-}"); shift; (( $# )) && shift;;
      -*) a+=("$1"); shift;;
      *)  break;;
    esac
  done
  (( $# > 1 )) || { ssh "${a[@]}" "$@"; return; }
  a+=("$1"); shift; c="$*"
  ssh "${a[@]}" "exec bash -c '${c//\'/\'\\\'\'}'"
}
rsh(){ local h="$1"; shift; bssh $SSH_OPT "root@$h" "$*" </dev/null; }
wsh(){ local h="$1"; shift; bssh $SSH_OPT "root@$h" "$*"; }   # stdin passes through

to_gib(){ awk -v s="$1" 'BEGIN{
  n=s+0; u=toupper(substr(s,length(s)));
  if(u=="T") g=n*1024; else if(u=="G") g=n; else if(u=="M") g=n/1024; else if(u=="K") g=n/1048576; else g=n/1073741824;
  printf "%d", (g==int(g)) ? g : int(g)+1 }'; }

exec 9>"$STATE/.ct-move-$CTID.lock" || die "cannot open the local lock"
flock -n 9 || die "another ct-move for $CTID is running on this machine"

MODE=presync; (( FINAL )) && MODE=final
log "=== ct-move $MODE: CT $CTID on $SRC -> CT $NEW on $DST storage=$STORAGE bw=${BW}MB/s$( (( DRY )) && echo ' DRY-RUN') ==="

# ---------------------------------------------------------------- the nodes
SRCN=$(rsh "$SRC" 'basename "$(readlink /etc/pve/local)"') || SRCN=""
DSTN=$(rsh "$DST" 'basename "$(readlink /etc/pve/local)"') || DSTN=""
[[ -n "$SRCN" ]] || die "cannot ssh root@$SRC, or it is not a PVE node"
[[ -n "$DSTN" ]] || die "cannot ssh root@$DST, or it is not a PVE node"

# ---------------------------------------------------------------- the source
SRCCFG=$(rsh "$SRC" "cat /etc/pve/nodes/$SRCN/lxc/$CTID.conf") \
  || die "CT $CTID has no config on $SRCN ($SRC)"
if grep -q '^\[' <<<"$SRCCFG"; then
  # Same as ketsync migrate: only the live rootfs moves, never the snapshots,
  # so a new id gets the current config and nothing below the first [section].
  # Keeping the SAME id would carry snapshot sections that point at volumes
  # left behind on the old storage - refused.
  [[ "$NEW" != "$CTID" ]] || die "CT $CTID has snapshots - with the same id they would travel pointing at the old storage; use a different --dst-ctid or remove them"
  log "NOTE: CT $CTID has snapshots ($(grep -c '^\[' <<<"$SRCCFG")) - they stay on $SRCN; only the current rootfs moves"
  SRCCFG=$(sed '/^\[/,$d' <<<"$SRCCFG")
fi
grep -qE '^mp[0-9]+:' <<<"$SRCCFG" && die "CT $CTID has mount points (mpN) - this script moves the rootfs only"
_lk=$(sed -n 's/^lock:[[:space:]]*//p' <<<"$SRCCFG")
if [[ -n "$_lk" ]]; then
  [[ "$_lk" == migrate ]] && log "NOTE: lock: migrate is ours from an interrupted --final; check, then: ssh root@$SRC pct unlock $CTID"
  die "CT $CTID is locked ($_lk) - something else owns it right now"
fi
rsh "$SRC" "ha-manager status 2>/dev/null" | grep -qE "ct:$CTID([^0-9]|\$)" \
  && die "CT $CTID is HA-managed - take it out of HA first, HA would fight a stop and a config move"
OLDROOT=$(sed -n 's/^rootfs:[[:space:]]*//p' <<<"$SRCCFG" | head -1)
OLDVOL="${OLDROOT%%,*}"
OLDSIZE=$(sed -n 's/.*[,]size=\([^,]*\).*/\1/p' <<<"$OLDROOT")
[[ -n "$OLDVOL" ]] || die "no rootfs line in CT $CTID's config"
[[ "${OLDVOL%%:*}" == "$STORAGE" && "$SRCN" == "$DSTN" ]] && die "CT $CTID is already on $STORAGE on $DSTN"

OLDSID="${OLDVOL%%:*}"; READ_HERE=0; SRCIMG=""
_here=$(pvesm path "$OLDVOL" 2>/dev/null)
if [[ " $SRC_STORAGES " == *" $OLDSID "* ]]; then
  [[ "$_here" == /*/images/* && -f "$_here" ]] \
    || die "SRC_STORAGES lists '$OLDSID' but its image is not a file here (got '${_here:-nothing}') - the conf is wrong"
  READ_HERE=1; SRCIMG="$_here"
  (( FINAL )) || [[ "$LIVE_FALLBACK" == 1 ]] \
    || die "'$OLDSID' is read here while CT $CTID runs, which needs LIVE_FALLBACK=1 in conf/ctmig.conf (no snapshots; --final is unaffected)"
  log "source: image $SRCIMG, read HERE and pushed to $DSTN (one hop, $SRCN untouched)"
elif [[ "$_here" == /*/images/* && -f "$_here" ]]; then
  die "'$OLDSID' resolves to a file on this machine ($_here) but is not in SRC_STORAGES - add it, or it would be read the slow way through $SRCN"
else
  rsh "$DST" "ssh -o BatchMode=yes -o ConnectTimeout=10 root@$SRC true" \
    || die "$DSTN cannot ssh root@$SRC - the copy is issued ON $DSTN, pulling from $SRCN. fix: ssh root@$DST ssh-copy-id root@$SRC"
  log "source: CT $CTID on $SRCN, pulled by $DSTN"
fi

# every bridge the config names must exist on the destination, or the first
# pct start there fails - found now, not during the downtime
for br in $(sed -n 's/^net[0-9]*:.*bridge=\([^,]*\).*/\1/p' <<<"$SRCCFG" | sort -u); do
  rsh "$DST" "ip link show '$br' >/dev/null 2>&1" || die "bridge $br (used by CT $CTID) does not exist on $DSTN"
done

if [[ "$NEW" == "$CTID" ]]; then
  if [[ "$SRCN" != "$DSTN" ]]; then
    rsh "$DST" "test -f /etc/pve/nodes/$SRCN/lxc/$CTID.conf" \
      || die "keeping id $CTID needs $SRCN and $DSTN in ONE cluster ($DSTN cannot see the config) - use --new-ctid"
  fi
else
  [[ -n "$MOCK" ]] || die "no MOCKNET_BRIDGE in $BASE/conf/ctmig.conf - a new-id config needs the island bridge"
  grep -E '^net[0-9]+:' <<<"$SRCCFG" | grep -qv 'bridge=' && die "a net line of CT $CTID has no bridge= - refusing rather than dropping it"
  # G8, the same question ct-migrate asks: the config written after presync
  # carries the PRODUCTION IP and MAC; only a bridge with no uplink makes that safe
  _g8=$(rsh "$DST" "ip -br link show $MOCK >/dev/null 2>&1 || { echo MISSING; exit 0; }
    ports=\$(ovs-vsctl --timeout=5 list-ifaces $MOCK 2>/dev/null || ls /sys/class/net/$MOCK/brif/ 2>/dev/null)
    for p in \$ports; do [ -e /sys/class/net/\$p/device ] || [ -d /sys/class/net/\$p/bonding ] && echo \"UPLINK \$p\"; done
    echo OK")
  [[ "$_g8" == *MISSING* ]] && die "bridge $MOCK does not exist on $DSTN - create the isolated island there first"
  [[ "$_g8" == *OK* ]] || die "cannot inspect $MOCK on $DSTN"
  [[ "$_g8" == *UPLINK* ]] && die "$MOCK on $DSTN HAS AN UPLINK ($(grep UPLINK <<<"$_g8" | tr '\n' ' ')) - it would put the production IP on the wire"
  _used=$(rsh "$DST" "ls /etc/pve/nodes/*/lxc/$NEW.conf /etc/pve/nodes/*/qemu-server/$NEW.conf 2>/dev/null")
  NEWEXIST=""
  if [[ -n "$_used" ]]; then
    # the one legitimate owner: the config an earlier presync of THIS move wrote,
    # recognised by its rootfs being exactly the volume state/ recorded
    _sv=$(cat "$STATE/ct-move-$NEW.vol" 2>/dev/null)
    [[ -n "$_sv" && "$_used" == "/etc/pve/nodes/$DSTN/lxc/$NEW.conf" ]] || die "id $NEW already belongs to a guest: $_used"
    NEWEXIST=$(rsh "$DST" "cat /etc/pve/nodes/$DSTN/lxc/$NEW.conf")
    [[ "$(sed -n 's/^rootfs:[[:space:]]*\([^,]*\).*/\1/p' <<<"$NEWEXIST")" == "$_sv" ]] \
      || die "id $NEW has a config whose rootfs is not $_sv - not ours, refusing"
    # G2: never write into a rootfs whose container is up
    _ns=$(rsh "$DST" "pct status $NEW" | awk '{print $2}')
    [[ "$_ns" == stopped ]] || die "CT $NEW is '$_ns' on $DSTN - refusing to copy into a running container. pct stop $NEW first"
  fi
fi

# ---------------------------------------------------------------- destination
read -r DTYPE DACTIVE DAVAILK < <(rsh "$DST" "pvesm status -storage $STORAGE 2>/dev/null" \
  | awk -v s="$STORAGE" '$1==s{print $2, $3, $6; exit}')
[[ -n "${DTYPE:-}" ]] || die "storage '$STORAGE' does not exist on $DSTN - nothing allocated (check the name)"
[[ "$DACTIVE" == active ]] || die "storage '$STORAGE' is '$DACTIVE' on $DSTN, not active - nothing allocated"
case "$DTYPE" in
  zfspool)          SHAPE=dataset;;
  lvmthin|lvm)      SHAPE=block;;
  dir|nfs|cifs)     SHAPE=image;;
  *) die "storage '$STORAGE' is type '$DTYPE', which this script does not handle";;
esac
SCFG=$(rsh "$DST" "awk -v s='$STORAGE' '/^[a-z]+:[[:space:]]/{b=(\$2==s)} b' /etc/pve/storage.cfg")
case "$SHAPE" in
  dataset)
    ZPOOL=$(sed -n 's/^[[:space:]]*pool[[:space:]][[:space:]]*//p' <<<"$SCFG" | head -1)
    [[ -n "$ZPOOL" ]] || die "cannot read the pool of '$STORAGE' from storage.cfg on $DSTN"
    [[ "$(rsh "$DST" "zpool list -H -o health ${ZPOOL%%/*}")" == ONLINE ]] || die "zpool ${ZPOOL%%/*} is not ONLINE on $DSTN"
    [[ "$(rsh "$DST" "zfs get -H -o value mounted $ZPOOL")" == yes ]] \
      || die "dataset $ZPOOL is not mounted on $DSTN - a subvol under it would be a plain directory on the root disk";;
  image)
    if [[ "$DTYPE" == dir ]]; then SPATH=$(sed -n 's/^[[:space:]]*path[[:space:]][[:space:]]*//p' <<<"$SCFG" | head -1)
    else SPATH="/mnt/pve/$STORAGE"; fi
    [[ -n "$SPATH" ]] || die "cannot read the path of '$STORAGE' on $DSTN"
    _h=$(rsh "$DST" "findmnt -no TARGET -T '$SPATH'")
    [[ -n "$_h" && "$_h" != / ]] || die "'$STORAGE' ($SPATH) sits on the ROOT filesystem of $DSTN - refusing"
    if [[ "$DTYPE" != dir ]]; then
      _f=$(rsh "$DST" "findmnt -no FSTYPE -T '$SPATH'")
      [[ "$_f" == nfs* || "$_f" == cifs || "$_f" == smb3 ]] || die "'$STORAGE' ($SPATH) is not mounted as $DTYPE on $DSTN (it is '$_f')"
    fi;;
esac
log "destination: $STORAGE on $DSTN is $DTYPE, active, not the root disk"

# ---------------------------------------------------------------- locks / state
LOCKF="/run/ketsync-ct-$NEW.lock"
OWNER="ct-move $(hostname) pid $$ $(date +%s)"
LOCKED=0; DST_MNT=""; SRC_MOUNTED=0; HERE_MNT=""
cleanup(){
  [[ -n "$HERE_MNT" ]] && umount "$HERE_MNT" >>"$LOG" 2>&1 && HERE_MNT=""
  [[ -n "$DST_MNT" ]] && rsh "$DST" "umount '$DST_MNT'" >>"$LOG" 2>&1 && DST_MNT=""
  (( SRC_MOUNTED )) && rsh "$SRC" "pct unmount $CTID" >>"$LOG" 2>&1 && SRC_MOUNTED=0
  (( LOCKED )) && rsh "$DST" "grep -qxF '$OWNER' $LOCKF && rm -f $LOCKF"
  LOCKED=0
}
trap cleanup EXIT
trap 'exit 130' INT TERM
if (( ! DRY )); then
  _r=$(rsh "$DST" "if (set -C; printf '%s\n' '$OWNER' > $LOCKF) 2>/dev/null; then echo TAKEN; else echo HELD; cat $LOCKF; fi")
  [[ "$_r" == TAKEN ]] || die "id $NEW is locked on $DSTN by another run: ${_r#HELD}"
  LOCKED=1
fi

VOLF="$STATE/ct-move-$NEW.vol"; SIZEF="$STATE/ct-move-$NEW.size"; SECF="$STATE/ct-move-$NEW.secs"
VOLID=$(cat "$VOLF" 2>/dev/null)
if [[ -z "$VOLID" ]]; then
  (( FINAL )) && die "no presync has been run for $NEW - run it while the CT is up first"
  _ex=$(rsh "$DST" "pvesm list $STORAGE --vmid $NEW 2>/dev/null" | awk 'NR>1{print $1}')
  [[ -z "$_ex" ]] || die "$STORAGE already holds volume(s) for $NEW that this script did not record: $_ex"
  _fsb=$(rsh "$SRC" "pct exec $CTID -- df -P -B1 /" 2>/dev/null | awk 'NR==2{print $2}')
  SIZE_G=$(to_gib "${OLDSIZE:-0}")
  if [[ "$_fsb" =~ ^[0-9]+$ ]]; then
    _g=$(( (_fsb + 1073741823) / 1073741824 )); (( _g > SIZE_G )) && SIZE_G=$_g
    [[ "$(to_gib "${OLDSIZE:-0}")" != "$SIZE_G" ]] && log "NOTE: config says size=${OLDSIZE:-?} but the filesystem is ${_g}G - allocating ${SIZE_G}G"
  fi
  (( SIZE_G > 0 )) || die "cannot work out the rootfs size"
  (( DAVAILK * 1024 >= SIZE_G * 1073741824 * 11 / 10 )) \
    || die "$STORAGE on $DSTN has $(( DAVAILK / 1048576 ))G free, needs ${SIZE_G}G + 10%"
  case "$SHAPE" in
    dataset) VN="subvol-$NEW-disk-0"; FMT=subvol;;
    block)   VN="vm-$NEW-disk-0";     FMT=raw;;
    image)   VN="vm-$NEW-disk-0.raw"; FMT=raw;;
  esac
  if (( DRY )); then
    log "DRY: would allocate $VN (${SIZE_G}G, --format $FMT) on $STORAGE${ZPROPS:+, then zfs set $ZPROPS}"
  else
    _o=$(rsh "$DST" "pvesm alloc $STORAGE $NEW $VN ${SIZE_G}G --format $FMT 2>&1")
    VOLID=$(grep -o "'$STORAGE:[^']*'" <<<"$_o" | tr -d "'" | tail -1)
    [[ -n "$VOLID" ]] || die "pvesm alloc failed on $DSTN: $_o"
    printf '%s\n' "$VOLID" > "$VOLF"; printf '%s\n' "$SIZE_G" > "$SIZEF"
    log "allocated $VOLID (${SIZE_G}G)"
  fi
else
  SIZE_G=$(cat "$SIZEF" 2>/dev/null)
  _p=$(rsh "$DST" "pvesm path $VOLID 2>/dev/null")
  case "$SHAPE" in
    dataset) rsh "$DST" "zfs list -H -o name '$_p'" >/dev/null 2>&1;;
    block)   rsh "$DST" "test -b '$_p'";;
    image)   rsh "$DST" "test -f '$_p'";;
  esac || die "state says $VOLID but it is gone on $DSTN - somebody removed it. Not re-allocating; inspect, then rm $VOLF to start over"
  log "resync into $VOLID (${SIZE_G}G)"
fi

if (( DRY )); then
  log "DRY: source: $( ((FINAL)) && echo "pct mount $CTID on $SRCN (must be stopped)" || echo "/proc/<pid>/root of the running CT on $SRCN")"
  (( FINAL )) && log "DRY: then: config -> rootfs on $STORAGE, old volume kept as unusedN$( [[ $NEW == "$CTID" && $SRCN != "$DSTN" ]] && echo ", moved $SRCN -> $DSTN")"
  log "DRY: nothing was written"; exit 0
fi

DPATH=$(rsh "$DST" "pvesm path $VOLID")
[[ -n "$DPATH" ]] || die "cannot resolve $VOLID on $DSTN"
DS=""
case "$SHAPE" in
  dataset)
    DS=$(rsh "$DST" "zfs list -H -o name '$DPATH'")
    rsh "$DST" "mountpoint -q '$DPATH' && [ \"\$(findmnt -no FSTYPE -T '$DPATH')\" = zfs ]" \
      || die "$DPATH is not a mounted zfs dataset on $DSTN - refusing, it would be a directory on the root disk"
    if [[ -n "$ZPROPS" ]]; then
      [[ -s "$SECF" ]] && log "NOTE: --zfs-props after the first round only affects data written from now on"
      for kv in ${ZPROPS//,/ }; do rsh "$DST" "zfs set '$kv' '$DS'" || die "zfs set $kv $DS failed"; done
      log "zfs set $ZPROPS on $DS"
    fi
    MNT="$DPATH";;
  block|image)
    [[ -n "$ZPROPS" ]] && log "NOTE: --zfs-props ignored, $STORAGE is not zfspool"
    MNT="/var/tmp/ct-move-$NEW"
    if [[ ! -s "$SECF" ]] && ! rsh "$DST" "blkid '$DPATH' >/dev/null 2>&1"; then
      rsh "$DST" "mkfs.ext4 -q -F -m0 '$DPATH'" || die "mkfs.ext4 failed on $DPATH"
    fi
    if rsh "$DST" "mountpoint -q '$MNT'"; then
      _src=$(rsh "$DST" "findmnt -no SOURCE '$MNT'")
      _mine=$(rsh "$DST" "readlink -f '$DPATH'"); [[ "$SHAPE" == image ]] && _mine=$(rsh "$DST" "losetup -j '$DPATH' | cut -d: -f1")
      [[ -n "$_src" && "$_src" == "$_mine" ]] || die "$MNT on $DSTN is mounted from $_src, not from $VOLID - refusing"
      log "reusing the mount left at $MNT by an interrupted run"
    else
      _mo=""; [[ "$SHAPE" == image ]] && _mo="-o loop"
      rsh "$DST" "mkdir -p '$MNT' && mount $_mo '$DPATH' '$MNT' && mountpoint -q '$MNT'" || die "could not mount $DPATH on $DSTN"
    fi
    DST_MNT="$MNT";;
esac

# ---------------------------------------------------------------- source path
_st=$(rsh "$SRC" "pct status $CTID" | awk '{print $2}')
if (( FINAL )); then
  [[ "$_st" == stopped ]] || die "--final needs CT $CTID STOPPED on $SRCN (it is '${_st:-unknown}'). Stop the service cleanly, then: ssh root@$SRC pct shutdown $CTID"
  _op=$(rsh "$SRC" "pvesm path $OLDVOL 2>/dev/null")
  if [[ -n "$_op" ]] && rsh "$SRC" "test -f '$_op'"; then
    _lo=$(rsh "$SRC" "losetup -j '$_op'")
    [[ -z "$_lo" ]] || die "the old image is still attached on $SRCN ($_lo) - the container is not fully down"
  fi
  printf '%s\n' "$SRCCFG" > "$STATE/ct-move-$CTID.conf.orig"
  [[ -s "$SECF" ]] && log "estimate: the last presync copy took $(( $(cat "$SECF") / 60 ))m$(( $(cat "$SECF") % 60 ))s - expect about that now"
  if (( ! READ_HERE )); then
    rsh "$SRC" "pct mount $CTID" >>"$LOG" 2>&1 || die "pct mount $CTID failed on $SRCN"
    SRC_MOUNTED=1
    SRCPATH="/var/lib/lxc/$CTID/rootfs"
  fi
else
  [[ "$_st" == running ]] || die "presync needs CT $CTID RUNNING on $SRCN (it is '${_st:-unknown}'); stopped means use --final"
  _pid=$(rsh "$SRC" "lxc-info -n $CTID -p -H")
  [[ "$_pid" =~ ^[0-9]+$ && "$_pid" != 0 ]] || die "cannot read the init pid of CT $CTID on $SRCN"
  SRCPATH="/proc/$_pid/root"
  (( READ_HERE )) && log "WARN: reading the LIVE image of a running CT (LIVE_FALLBACK=1) - a file caught mid-write can fail this round (rc=23); --final repairs it"
fi
if (( READ_HERE )); then
  # the same image lock ct-migrate/replica/failback take on this machine, so
  # none of them writes it while it is read here
  exec 7>"$BASE/engines/.ct-intake-$CTID.lock" && flock -n 7 \
    || die "another ketsync engine holds CT $CTID's image right now (.ct-intake-$CTID.lock)"
  HERE_MNT="/mnt/ct-move-src-$CTID"; mkdir -p "$HERE_MNT"
  mountpoint -q "$HERE_MNT" && die "$HERE_MNT is already mounted here - inspect and umount it"
  # ro,noload: no journal replay - nothing is ever written into the source image
  mount -o loop,ro,noload "$SRCIMG" "$HERE_MNT" >>"$LOG" 2>&1 && mountpoint -q "$HERE_MNT" \
    || { HERE_MNT=""; die "could not mount $SRCIMG read-only here"; }
  SRCPATH="$HERE_MNT"
fi

# ct-migrate's G5/G6/G8 for a new id: written ONCE, after a good round, with
# every net line on the island bridge, onboot 0 and no description - and never
# touched again. That is what lets a person set the real network (and notes)
# on it ahead of the cutover. The one thing that can drift is the size, and
# that is only reported.
new_cfg_once(){
  local _cfg _cs
  if [[ -z "$NEWEXIST" ]]; then
    _cfg=$(grep -vE '^(rootfs|mp[0-9]+|net[0-9]+|onboot|unused[0-9]+|parent|lock|template|description):' <<<"$SRCCFG"
           echo "rootfs: $VOLID$(sed 's/^[^,]*//; s/,size=[^,]*//' <<<"$OLDROOT"),size=${SIZE_G}G"
           echo "onboot: 0"
           grep -E '^net[0-9]+:' <<<"$SRCCFG" | sed -E "s/bridge=[^,]*/bridge=$MOCK/")
    printf '%s\n' "$_cfg" | wsh "$DST" "set -C; cat > /etc/pve/nodes/$DSTN/lxc/$NEW.conf" \
      && [[ "$(rsh "$DST" "cat /etc/pve/nodes/$DSTN/lxc/$NEW.conf")" == "$_cfg" ]] \
      || die "the copy is fine but the config for $NEW on $DSTN was not written cleanly - check it"
    NEWEXIST="$_cfg"
    log "wrote /etc/pve/nodes/$DSTN/lxc/$NEW.conf - net on $MOCK (isolated), onboot 0; it is never rewritten"
    log "  set its real network and notes whenever you like, before the cutover"
  else
    _cs=$(sed -n 's/^rootfs:.*[,]size=\([^,]*\).*/\1/p' <<<"$NEWEXIST")
    if [[ "$_cs" != "${SIZE_G}G" ]]; then
      log "NOTE: $NEW's config says size=$_cs but the volume is ${SIZE_G}G - left untouched on purpose; fix it yourself:"
      log "NOTE:   rootfs: $VOLID,size=${SIZE_G}G"
    fi
  fi
}

# ---------------------------------------------------------------- the copy
PROG=""; [ -t 1 ] && PROG="--info=progress2"
[[ -z "$PROG" ]] && log "no terminal: rsync progress is not shown, only the result at the end (run it in tmux to watch)"
RSYNC="rsync -aHAX --numeric-ids --sparse --inplace -x --delete --modify-window=-1 --stats $PROG \
  --bwlimit=${BW}m --exclude='/proc/*' --exclude='/sys/*' --exclude='/dev/*' --exclude='/run/*' \
  --exclude='/tmp/*' --exclude='/lost+found' --exclude='/.zfs' -e '$SSH_DATA' \
  'root@$SRC:$SRCPATH/' '$MNT/'"
RSL=(-aHAX --numeric-ids --sparse --inplace -x --delete --modify-window=-1 --stats ${PROG:+"$PROG"}
  "--bwlimit=${BW}m" '--exclude=/proc/*' '--exclude=/sys/*' '--exclude=/dev/*' '--exclude=/run/*'
  '--exclude=/tmp/*' '--exclude=/lost+found' '--exclude=/.zfs' -e "$SSH_DATA")
attempt=0
while :; do
  t0=$SECONDS
  if (( READ_HERE )); then
    log "copy $(hostname):$SRCPATH -> $DSTN:$MNT"
    rsync "${RSL[@]}" "$SRCPATH/" "root@$DST:$MNT/" 2>&1 | tee -a "$LOG"; rc=${PIPESTATUS[0]}
  else
    log "copy $SRCN:$SRCPATH -> $DSTN:$MNT"
    rsh "$DST" "$RSYNC" 2>&1 | tee -a "$LOG"; rc=${PIPESTATUS[0]}
  fi
  secs=$(( SECONDS - t0 ))
  [[ $rc -eq 11 && $attempt -lt 3 ]] || break
  [[ "$SHAPE" == dataset ]] || die "out of space in $VOLID - grow it on $DSTN (lvextend/truncate + resize2fs, unmounted) and run again"
  attempt=$(( attempt + 1 ))
  _q=$(rsh "$DST" "zfs get -Hp -o value refquota '$DS'"); _n=$(( _q / 100 * 105 ))
  _av=$(rsh "$DST" "zfs get -Hp -o value avail '$ZPOOL'")
  (( _av > (_n - _q) * 2 )) || die "out of space, and $ZPOOL has too little room to grow $DS safely"
  rsh "$DST" "zfs set refquota=$_n '$DS' && { [ \"\$(zfs get -Hp -o value refreservation '$DS')\" = 0 ] || zfs set refreservation=$_n '$DS'; }" \
    || die "could not grow $DS"
  SIZE_G=$(( (_n + 1073741823) / 1073741824 )); printf '%s\n' "$SIZE_G" > "$SIZEF"
  log "out of space - grew $DS to ${SIZE_G}G ($attempt/3)"
done
_lit=$(grep 'Literal data:' "$LOG" | tail -1 | sed 's/.*: *//')
log "copy rc=$rc in $(( secs / 60 ))m$(( secs % 60 ))s (changed: ${_lit:-?})"

if (( ! FINAL )); then
  if [[ $rc -eq 0 || $rc -eq 24 ]]; then
    _first=0; [[ -s "$SECF" ]] || _first=1
    printf '%s\n' "$secs" > "$SECF"
    [[ "$NEW" != "$CTID" ]] && new_cfg_once
    if (( _first )); then
      log "presync OK - that was the FIRST, full copy; it says nothing about --final."
      log "  run presync again: a round over an existing copy is what --final repeats, and ITS time is the estimate."
      exit 0
    fi
    log "presync OK. estimate for --final: about $(( secs / 60 ))m$(( secs % 60 ))s of copy while the CT is down"
    log "  (plus the time to stop the service cleanly and to start it again). run presync again close to"
    log "  the cutover so the last delta is small."
    exit 0
  fi
  [[ $rc -eq 23 ]] && log "WARN: rc=23 - some files changed while being read; normal on a live CT, run it again"
  die "presync rsync rc=$rc"
fi

[[ $rc -eq 0 || $rc -eq 24 ]] || die "--final rsync FAILED rc=$rc - the config was NOT touched. CT $CTID is still on $SRCN, stopped; start it there if needed"
(( SRC_MOUNTED )) && { rsh "$SRC" "pct unmount $CTID" >>"$LOG" 2>&1 && SRC_MOUNTED=0; }
[[ -n "$HERE_MNT" ]] && { umount "$HERE_MNT" >>"$LOG" 2>&1 && HERE_MNT=""; }
[[ -n "$DST_MNT" ]] && { rsh "$DST" "umount '$DST_MNT'" >>"$LOG" 2>&1 && DST_MNT=""; }

# ---------------------------------------------------------------- the config
# Rebuild rootfs with its own options kept, the new volume and the real size;
# the old volume stays referenced as unusedN, so nothing deletes it by accident
# and the way back is one line.
_opts=$(sed 's/^[^,]*//; s/,size=[^,]*//' <<<"$OLDROOT")
NEWROOT="rootfs: $VOLID${_opts},size=${SIZE_G}G"
if [[ "$NEW" == "$CTID" ]]; then
  rsh "$SRC" "pct set $CTID --lock migrate" || die "could not lock CT $CTID on $SRCN - config not touched"
  _st=$(rsh "$SRC" "pct status $CTID" | awk '{print $2}')
  [[ "$_st" == stopped ]] || die "CT $CTID is '$_st' on $SRCN after the copy - somebody started it. Config not moved (it is locked: pct unlock $CTID)"
  CUR=$(rsh "$SRC" "cat /etc/pve/nodes/$SRCN/lxc/$CTID.conf")
  n=0; while grep -q "^unused$n:" <<<"$CUR"; do n=$(( n + 1 )); done
  NEWCFG=$(sed "s|^rootfs:.*|$NEWROOT|" <<<"$CUR"; echo "unused$n: $OLDVOL")
  printf '%s\n' "$NEWCFG" | wsh "$SRC" "cat > /etc/pve/nodes/$SRCN/lxc/$CTID.conf" \
    || die "could not write the config on $SRCN - it is locked; the original is in $STATE/ct-move-$CTID.conf.orig"
  if [[ "$SRCN" != "$DSTN" ]]; then
    rsh "$SRC" "mv /etc/pve/nodes/$SRCN/lxc/$CTID.conf /etc/pve/nodes/$DSTN/lxc/$CTID.conf" \
      || die "could not move the config to $DSTN - it is on $SRCN, locked, pointing at the new volume"
  fi
  _back=$(rsh "$DST" "cat /etc/pve/nodes/$DSTN/lxc/$CTID.conf")
  [[ "$_back" == "$NEWCFG" ]] || die "the config on $DSTN does not read back as what was sent - it is locked; compare with $STATE/ct-move-$CTID.conf.orig"
  rsh "$DST" "pct unlock $CTID" || die "config is in place but still locked: ssh root@$DST pct unlock $CTID"
else
  # Same IP and MAC as the old one once somebody moves it onto the real
  # bridges: the old id is locked first, so the two cannot both come up.
  rsh "$SRC" "pct set $CTID --lock migrate" || die "could not lock CT $CTID on $SRCN - the data is copied, config not touched"
  _st=$(rsh "$SRC" "pct status $CTID" | awk '{print $2}')
  [[ "$_st" == stopped ]] || die "CT $CTID is '$_st' on $SRCN after the copy - somebody started it"
  new_cfg_once
fi
rm -f "$VOLF" "$SIZEF" "$SECF"

log "=== DONE: CT $NEW is on $DSTN, rootfs $VOLID (${SIZE_G}G). NOT started. ==="
log "  start:     ssh root@$DST pct start $NEW"
if [[ "$NEW" == "$CTID" ]]; then
  log "  old disk:  $OLDVOL kept as unused$n - remove it only after you have verified, days later"
  log "  rollback (anything written on $DSTN after start is lost):"
  log "    ssh root@$DST pct stop $CTID"
  log "    ssh root@$DST rm /etc/pve/nodes/$DSTN/lxc/$CTID.conf"
  log "    ssh root@$SRC 'cat > /etc/pve/nodes/$SRCN/lxc/$CTID.conf' < $STATE/ct-move-$CTID.conf.orig"
  log "    ssh root@$SRC pct start $CTID"
else
  grep -q "bridge=$MOCK" <<<"$NEWEXIST" && log "  network:   $NEW is still on $MOCK - put its real bridges in before pct start"
  log "  CT $CTID on $SRCN: data untouched, stopped, lock: migrate (same IP/MAC as $NEW - never run both)"
  log "  once $NEW is verified, days later: ssh root@$SRC 'pct unlock $CTID && pct destroy $CTID'"
  log "  rollback (anything written in $NEW after start is lost):"
  log "    ssh root@$DST pct stop $NEW"
  log "    ssh root@$SRC 'pct unlock $CTID && pct start $CTID'"
fi
exit 0
