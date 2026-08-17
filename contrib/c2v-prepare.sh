#!/usr/bin/env bash
# =============================================================================
#  c2v-prepare.sh — turn a live LXC rootfs into a VM disk that is ready to be
#                   made bootable. Phase 1 of 2.
# -----------------------------------------------------------------------------
#  usage:
#    ./tools/c2v-prepare.sh --old-node pve6a --old-ctid 251 --vmid 9251 \
#                           --storage nfs-vm --iso local:iso/CentOS-7-x86_64-DVD-2009.iso
#
#    ./tools/c2v-prepare.sh --old-node pve6a --old-ctid 140 --vmid 9140 \
#                           --storage nfs-vm       # Debian or Ubuntu: no --iso
#
#    ./tools/c2v-prepare.sh ... --stopped      FINAL delta, source CT must be
#                                              stopped; reads it via `pct mount`
#    ./tools/c2v-prepare.sh ... --dry-run      print what would happen, do nothing
#
#  options:
#    --old-node HOST     node the source CT lives on                  (required)
#    --old-ctid ID       the CT to convert                            (required)
#    --vmid ID           vmid to build on THIS node                   (required)
#    --storage NAME      storage for the VM disk                      (required)
#    --iso VOLID         install DVD matching the guest    (required for EL only)
#    --family NAME       el or debian; override the probe   (default: ask the CT)
#    --memory MB         guest RAM                        (default: same as the CT)
#    --cores N           vcpus                            (default: same as the CT)
#    --size GiB          override the computed disk size
#    --factor PCT        usage multiplier when sizing                 (default 185)
#    --bwlimit KBPS      rsync --bwlimit                              (default 0 = none)
#    --ciphers LIST      ssh ciphers for the transfer, '' to leave ssh alone
#    --label NAME        ext4 label, must match phase 2  (default: c7root/debroot)
#    --stopped           source CT is stopped: read it via pct mount
#    --dry-run           plan only
#
#  The ISO has to match the guest, not the host and not this script: phase 2
#  installs the guest's kernel and bootloader out of it with the guest's own rpm.
#  A CentOS 6 guest needs a 6.x DVD, a CentOS 7 guest a 7.x DVD. Use the full
#  DVD rather than a Minimal ISO - Minimal does not carry every package phase 2
#  asks for, and yum exits 0 when only some of the names it was given are
#  missing, so the failure surfaces later as a VM with no bootloader.
#  A Debian or Ubuntu guest needs no ISO at all; see TWO FAMILIES below.
#
#  The label is the one string both phases have to agree on: phase 1 mkfs with
#  it, phase 2 writes root=LABEL= from it, and a mismatch drops the guest into a
#  dracut emergency shell at boot. Nothing reads the release out of the name -
#  the filesystem is created before a single byte of the guest has been copied,
#  so at that moment nothing here knows which release it is about to hold. Do
#  not change it on an image that already exists: phase 1 keeps an existing
#  filesystem rather than reformatting it, so a new --label would not be applied
#  here but would still be obeyed there. That is guarded rather than trusted -
#  see the label check in section 5.
#
#  Images built before this default changed carry 'c6root'. Re-syncing one needs
#  --label c6root; the guard in section 5 says so by name.
#
# -----------------------------------------------------------------------------
#  WHY THIS IS TWO SCRIPTS
#
#  Everything here runs on a modern PVE host. Phase 2 cannot. On an EL6 guest
#  that is absolute: `rpm`, `dracut` and `grub` inside that image are glibc 2.12
#  binaries, and a glibc 2.12 binary segfaults at ffffffffff600400 on a host
#  booted with vsyscall=none. An EL7 guest clears that bar, and still does not
#  run here: the host has no rpm and no yum to install a kernel with, and its
#  grub2 is Debian's, which writes a core.img that looks for /boot/grub with
#  Debian's module set while the guest expects /boot/grub2. So phase 2 runs
#  inside the guest's own rescue environment, from an install DVD of the guest's
#  own release. This script plants phase 2 inside the image and attaches that
#  ISO; a human boots it.
#
#  TWO FAMILIES, TWO PHASE 2s
#
#  Neither of those two reasons survives contact with a Debian or Ubuntu guest.
#  Ubuntu 20.04 is glibc 2.31, which runs on this kernel; and the PVE host is
#  Debian, so its apt, dpkg, grub-pc and initramfs-tools are the guest's own
#  tools rather than a foreign set. So the Debian family's phase 2 is a plain
#  chroot on this node - tools/c2v-inside-deb.sh - with no rescue ISO, no boot
#  into a strange environment, and nothing typed into a console that cannot
#  paste. The operator's mental model does not change: phase 1, then phase 2.
#  Only where phase 2 runs changes, and this script says which at the end.
#
#  Everything else here is shared on purpose. Partitioning, mkfs, the delta
#  rsync, the id renumber, the ENOSPC sizing, the mp0 warning and the bridge map
#  are the same work whatever is inside the image, and the mtab bug that cost a
#  live VM was one line fixed in one place. Two copies of this file would have
#  needed it fixed in two.
#
#  WHAT THIS SCRIPT DELIBERATELY DOES NOT DO
#
#  It never starts the VM and never stops the source CT. Same rule as
#  ct-migrate.sh: lifecycle is a human's job, done while looking at the machine.
#  The new VM also gets NO network — the operator adds net0 by hand at go-live,
#  which is what keeps two copies of the same host off the network at once.
#
#  WHY THE WHOLE IMAGE IS RE-OWNED AFTER THE SYNC
#
#  An unprivileged CT keeps its files shifted by the userns map, normally by
#  100000, and on PVE 6 that shift is really in the inodes. A VM has no map, so
#  the image has to be shifted back or setuid stops working — and setuid failing
#  means /bin/mount refuses to run, root never becomes writable, and every
#  service dies with errno 30 on a system that otherwise looks perfect. Section
#  6b does this and refuses to continue if any owner survives. It is the one
#  step here whose absence produces a VM that boots and lies to you.
#
#  WHY /boot, /etc/fstab AND /etc/mtab ARE EXCLUDED FROM THE SYNC
#
#  Phase 2 writes a kernel, an initramfs and a bootloader into /boot, and this
#  script writes an fstab with a real root device. The source CT has neither —
#  a container borrows the host kernel and has no root device of its own. rsync
#  runs with --delete, so a second pass would delete the kernel that phase 2
#  just installed and restore a container fstab over ours. The image would still
#  mount, still look complete, and never boot again. /etc/mtab is excluded for a
#  different reason, spelled out where it is rewritten: as a symlink into /proc
#  it crashes EL6 rescue before phase 2 can run at all. Excluding all three is
#  what makes a re-run safe: sync as many times as you like, in any order,
#  before or after phase 2.
#
#  IDEMPOTENCE
#
#  Every step checks for its own result first. Re-running after a failure
#  resumes rather than starting over, and re-running after success is a delta
#  sync. Nothing here destroys data that already exists in the image.
# =============================================================================
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF/.." && pwd)"

# Rule 7: found next to the project, never an absolute path. Optional - without
# it the CT's bridge names are carried across unchanged, which is right when both
# nodes name their networks the same way and wrong the moment they do not.
BRIDGEMAP="$ROOT/bridgemap.tsv"
# In the ketsync repo the per-site tables live in inventory/ - the same home
# as the work lists, resolved the same way the engines resolve theirs. A
# standalone copy of these scripts (an old node's folder) keeps the flat
# path above. A map left at the old flat home in a repo is refused, not
# ranked: this table decides which SEGMENT a machine lands on, and the one
# file nobody edits winning silently is the worst version of that.
if [[ -f "$ROOT/bin/ketsync" && -f "$ROOT/lib/common.sh" ]]; then
  if [[ -f "$BRIDGEMAP" ]]; then
    echo "ERROR: $BRIDGEMAP is the OLD home - the bridge map moved to inventory/." >&2
    echo "ERROR:   mv $BRIDGEMAP $ROOT/inventory/bridgemap.tsv" >&2
    exit 2
  fi
  BRIDGEMAP="$ROOT/inventory/bridgemap.tsv"
fi
THIS_NODE="$(hostname -s 2>/dev/null || hostname)"

OLD_NODE=""; OLD_CTID=""; VMID=""; STORAGE=""; ISO=""
# MEMORY and CORES start empty on purpose: empty means "the CT has not been asked
# yet", which is what lets an explicit flag win over what the config says without
# a second variable to remember whether it was given. Section 0 fills them in.
MEMORY=""; CORES=""; FORCE_SIZE=""; SIZE_FACTOR=185; BWLIMIT=0
# Same trick, and for the same reason: the default label depends on which family
# the guest turns out to be, and that is not known until the CT has been read.
# Empty means "not given", which is what lets --label win without a second flag.
LABEL=""; STOPPED=0; DRYRUN=0
GUEST_FAMILY=""; FAMILY_SRC="--family"
PKGS_GONE=""

# Split in two because ssh(1) takes the FIRST value it is given for a parameter.
# The transfer needs its own ControlMaster and cannot get it by appending to a
# list that already says auto - that value is simply ignored - so it is built
# from the common half instead. See the rsync -e string in section 6.
SSHOPT_COMMON=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new
        -o ConnectTimeout=10)
# ControlMaster keeps the probes to one TCP session per node instead of one each;
# the sizing step alone is three round trips.
SSHOPT=("${SSHOPT_COMMON[@]}" -o ControlMaster=auto
        -o ControlPath=/run/c2v-%r@%h:%p -o ControlPersist=60)

# The cipher list for the transfer only; the probes above negotiate whatever they
# like, because eight short sessions cannot be made faster and a peer that refuses
# a list should not take the whole run down with it. OpenSSH offers
# chacha20-poly1305 first by default and it has no CPU instruction behind it,
# which caps one stream at roughly 150-400 MB/s. On a conversion where --old-node
# is this same machine one set of cores pays that price twice, once to encrypt and
# once to decrypt. Same list and same reasoning as SSH_CIPHERS in ctmig.conf.
SSH_CIPHERS=aes128-gcm@openssh.com,aes256-gcm@openssh.com,aes128-ctr

LOG=""          # set once the arguments are parsed; see set_log below
log(){
  if [ -n "$LOG" ]; then printf '%s  %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG"
  else                   printf '%s  %s\n' "$(date '+%F %T')" "$*"; fi
}
# A conversion is the run you are most likely to have to explain afterwards, and
# until now every word of it lived only in the terminal that ran it. tee rather
# than a redirect of the whole script on purpose: these tools are in production
# and proven, and wrapping them in a process substitution is a bigger change to
# working code than the problem justifies. Output from yum, dracut and grub
# still goes to the terminal only - pipe the whole run through tee if you want
# that too.
set_log(){      # $1 = full path
  LOG="$1"
  mkdir -p "$(dirname "$LOG")" 2>/dev/null || LOG=""
  [ -n "$LOG" ] && { : >> "$LOG" 2>/dev/null || LOG=""; }
  [ -n "$LOG" ] && log "log: $LOG"
  return 0
}

# The same rule the engines print between operations. These tools convert one
# container by hand, so the operation is the whole run - the rule is what
# separates this attempt from the last one in a terminal that has scrolled.
LOGSEP='##############################################################################'
hr(){ printf '%s\n' "$LOGSEP"; }
die(){ log "ERROR: $*"; exit 1; }
run(){ if (( DRYRUN )); then log "DRY: $*"; else "$@"; fi; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --old-node) OLD_NODE="${2:-}"; shift 2;;
    --old-ctid) OLD_CTID="${2:-}"; shift 2;;
    --vmid)     VMID="${2:-}";     shift 2;;
    --storage)  STORAGE="${2:-}";  shift 2;;
    --iso)      ISO="${2:-}";      shift 2;;
    --family)   GUEST_FAMILY="${2:-}"; shift 2;;
    --memory)   MEMORY="${2:-}";   shift 2;;
    --cores)    CORES="${2:-}";    shift 2;;
    --size)     FORCE_SIZE="${2:-}"; shift 2;;
    --factor)   SIZE_FACTOR="${2:-}"; shift 2;;
    --bwlimit)  BWLIMIT="${2:-}";  shift 2;;
    --ciphers)  SSH_CIPHERS="${2:-}"; shift 2;;
    --label)    LABEL="${2:-}";    shift 2;;
    --stopped)  STOPPED=1; shift;;
    --dry-run)  DRYRUN=1; shift;;
    -h|--help)  sed -n '2,32p' "${BASH_SOURCE[0]}"; exit 0;;
    *) die "unknown option: $1 (try --help)";;
  esac
done

# ISO is not in this loop, and that is the one thing about it worth explaining.
# Whether it is required at all depends on the guest family, and the guest family
# cannot be known until the CT has been read - which needs OLD_NODE and OLD_CTID,
# which are checked here. So --iso is required in section 0a instead, once there
# is an answer, and it is still required with no default there. Rule 5 holds; it
# just cannot be enforced this early.
for v in OLD_NODE OLD_CTID VMID STORAGE; do
  # OLD_NODE -> --old-node: the message has to name the flag the operator types,
  # not the variable. Rule 5 in CLAUDE.md - none of these get a default, ever.
  [[ -n "${!v}" ]] || die "--$(printf '%s' "${v,,}" | tr _ -) is required and has no default (try --help)"
done
[[ "$OLD_CTID" =~ ^[0-9]+$ ]] || die "--old-ctid must be numeric"
[[ "$VMID"     =~ ^[0-9]+$ ]] || die "--vmid must be numeric"

# Checked here rather than where it is used, because a typo in --family should
# not be discovered after the CT has already been probed and reported.
case "$GUEST_FAMILY" in
  ""|el|debian) ;;
  *) die "--family must be 'el' or 'debian' (got: $GUEST_FAMILY)";;
esac

# A cipher list is not a number, and it is pasted into the rsync -e string
# unquoted - where a space would quietly become another argument to rsync rather
# than an error. So it gets the only character set a cipher list can legitimately
# be made of, and anything else is refused here rather than misread there.
if [[ -n "$SSH_CIPHERS" && ! "$SSH_CIPHERS" =~ ^[A-Za-z0-9@.,+-]+$ ]]; then
  die "--ciphers '$SSH_CIPHERS' is not a plain cipher list"
fi

for c in qm pvesm parted mkfs.ext4 dumpe2fs losetup rsync ssh blkid; do
  command -v "$c" >/dev/null || die "missing command: $c"
done

VOLID="$STORAGE:$VMID/vm-$VMID-disk-0.raw"
MNT="/var/lib/c2v/$VMID"
LOOP=""

# ---------------------------------------------------------------------------
# A kill during rsync must still bring the loop device and the mount back down.
# Leaving a loop device attached to an image that a later run will resize is the
# same class of bug as G3 in the engine: the resize succeeds and the filesystem
# is silently wrong.
# ---------------------------------------------------------------------------
cleanup(){
  local rc=$?
  if mountpoint -q "$MNT" 2>/dev/null; then
    sync; umount "$MNT" 2>/dev/null || log "WARN: umount $MNT failed - fix by hand: fuser -vm $MNT"
  fi
  if [[ -n "$LOOP" ]] && losetup "$LOOP" >/dev/null 2>&1; then
    losetup -d "$LOOP" 2>/dev/null || log "WARN: losetup -d $LOOP failed"
  fi
  for s in /run/c2v-*; do
    [[ -S "$s" ]] && ssh -O exit -o ControlPath="$s" nohost >/dev/null 2>&1
  done
  exit $rc
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# 0. preflight
# ---------------------------------------------------------------------------
hr
set_log "$ROOT/logs/c2v-prepare-$VMID-$(date +%F).log"
log "=== c2v phase 1: CT $OLD_NODE:$OLD_CTID -> VM $VMID on $STORAGE ==="

pvesm status --storage "$STORAGE" >/dev/null 2>&1 \
  || die "storage '$STORAGE' does not exist on this node"

# The VM must be free, or already be the one we are resuming. A vmid that
# belongs to something else is the quiet disaster - qm set would attach our
# disk to a running production VM.
if [[ -f "/etc/pve/qemu-server/$VMID.conf" ]]; then
  if grep -qF "$VOLID" "/etc/pve/qemu-server/$VMID.conf"; then
    log "vmid $VMID already exists and owns $VOLID - resuming"
  elif grep -qx "name: c2v-$OLD_CTID" "/etc/pve/qemu-server/$VMID.conf"; then
    # `qm create` runs early, `qm set --virtio0` runs at the very end, so a run
    # that dies anywhere in between leaves a config that owns no disk at all.
    # Without this branch that half-built shell is indistinguishable from
    # somebody else's VM and the operator is told to pick another vmid, which
    # makes the script unresumable exactly when a resume is what is wanted.
    # The name written by our own `qm create` is the ownership proof.
    log "vmid $VMID is our own half-built shell (name: c2v-$OLD_CTID) - resuming"
  else
    die "vmid $VMID already exists on this node and does NOT own $VOLID - pick another vmid"
  fi

  # The delta re-run is the dangerous one. This script loop-mounts the image and
  # writes to it; doing that while qemu has the same file open is two writers on
  # one filesystem, and the corruption does not show up until the next boot.
  # Same reasoning as G3 in the engine - the operation succeeds, the data is
  # silently wrong.
  vst=$(qm status "$VMID" 2>/dev/null || true)
  [[ "$vst" == *stopped* ]] || die "VM $VMID is not stopped (got: ${vst:-unknown}) - 'qm stop $VMID' first, this mounts its disk"
fi

st=$(ssh "${SSHOPT[@]}" "root@$OLD_NODE" "pct status $OLD_CTID" </dev/null 2>/dev/null || true)
[[ -n "$st" ]] || die "cannot read 'pct status $OLD_CTID' on $OLD_NODE"
if (( STOPPED )); then
  [[ "$st" == *stopped* ]] || die "--stopped needs CT $OLD_CTID stopped on $OLD_NODE (got: $st)"
else
  [[ "$st" == *running* ]] || die "CT $OLD_CTID is not running on $OLD_NODE (got: $st) - use --stopped"
fi

oldcfg=$(ssh "${SSHOPT[@]}" "root@$OLD_NODE" "pct config $OLD_CTID" </dev/null 2>/dev/null || true)
[[ -n "$oldcfg" ]] || die "cannot read 'pct config $OLD_CTID' on $OLD_NODE"

# ---------------------------------------------------------------------------
# 0a. which family of guest is this?
# ---------------------------------------------------------------------------
# It decides four things, none of which can be decided later: whether an install
# DVD is needed at all, which phase 2 the operator will be told to run, which
# kernel and bootloader paths have to be held back from --delete, and what
# /etc/mtab has to look like in the image.
#
# It is asked before anything else that depends on the guest, because getting it
# wrong is not a failure - it is a disk that is built, synced, renumbered and
# then cannot be finished. Before this existed an Ubuntu CT went all the way
# through phase 1 without a single warning and produced exactly that.
#
# Three sources, in falling order of authority. /etc/os-release is a fact the
# guest states about itself and is the answer whenever it exists - but it
# arrived in EL7, so EL6 has to be asked the older question. Neither can be
# asked of a stopped CT, and the only thing left there is the ostype: line PVE
# keeps in the container config. That one is a label a human chose rather than
# something measured, so it is last, and taking it is announced.
# Fed three different shapes of string: a bare ID=, a space-separated ID_LIKE
# list, and a whole /etc/redhat-release line. That is why 'red hat' is spelled
# with the space as well as without - the ID is redhat and the release line says
# "Red Hat Enterprise Linux Server release 6.10" - and why ol, which is Oracle's
# ID and is two letters, is matched exactly rather than as a substring of every
# word that happens to contain it.
family_of(){ # family_of <id-ish string> - prints el or debian, or nothing
  case "$1" in
    *centos*|*rhel*|*redhat*|*'red hat'*|*almalinux*|*rocky*|*fedora*|*oracle*|*scientific*)
      printf 'el' ;;
    ol|*'ol '*|*' ol')
      printf 'el' ;;
    *debian*|*ubuntu*|*devuan*|*raspbian*)
      printf 'debian' ;;
  esac
}

# A filename is a claim, not a fact, so this warns rather than refusing: an ISO
# can legitimately be renamed or rebuilt. It exists to catch the one mistake
# that actually happens - last week's 6.10 DVD still sitting on the command line.
# Called once from the el branch below, and once more at the plant step for the
# --stopped path, where the release is not known until the image can be read.
iso_release_check(){
  local want_major iso_major
  case "$GUEST_REL" in
    *'release 6'*) want_major=6;;
    *'release 7'*) want_major=7;;
    *)             return 0;;
  esac
  iso_major=$(printf '%s' "$ISO" | sed -n 's/.*[Cc]ent[Oo][Ss][-_. ]*\([0-9][0-9]*\).*/\1/p')
  [[ -n "$iso_major" && "$iso_major" != "$want_major" ]] || return 0
  log "WARN: the CT reports release $want_major but --iso names a $iso_major disc: $ISO"
  log "WARN: phase 2 installs the guest's kernel from that disc and will fail on it"
}

GUEST_REL=""
if [[ -n "$GUEST_FAMILY" ]]; then
  log "guest family: $GUEST_FAMILY (forced by --family)"
else
  if (( ! STOPPED )); then
    # One ssh, two files, so a running CT costs a single round trip. os-release
    # is asked for first and matched first; redhat-release is what answers for
    # EL6, which has no os-release at all.
    guestos=$(ssh "${SSHOPT[@]}" "root@$OLD_NODE" \
              "pct exec $OLD_CTID -- sh -c 'cat /etc/os-release /etc/redhat-release 2>/dev/null'" \
              </dev/null 2>/dev/null || true)
    if [[ -n "$guestos" ]]; then
      # os-release values may be bare, "quoted" or 'quoted' - the spec allows all
      # three and distros use all three, so both quote characters come off.
      idline=$(printf '%s\n' "$guestos" | sed -n 's/^ID=//p'      | head -1 | tr -d "\"'" | tr '[:upper:]' '[:lower:]')
      idlike=$(printf '%s\n' "$guestos" | sed -n 's/^ID_LIKE=//p' | head -1 | tr -d "\"'" | tr '[:upper:]' '[:lower:]')
      # The human-readable release string, kept for the messages at the end.
      # PRETTY_NAME when there is one, the redhat-release line when there is not.
      GUEST_REL=$(printf '%s\n' "$guestos" | sed -n 's/^PRETTY_NAME=//p' | head -1 | tr -d '"')
      [[ -n "$GUEST_REL" ]] || GUEST_REL=$(printf '%s\n' "$guestos" | grep -m1 'release' || true)

      GUEST_FAMILY=$(family_of "$idline")
      [[ -n "$GUEST_FAMILY" ]] || GUEST_FAMILY=$(family_of "$idlike")
      # And third, the release line itself, which is the whole of what an EL6
      # guest can say about itself: os-release arrived in EL7, so there is no ID=
      # to read and the two lines above find nothing. Without this the release
      # this entire toolchain was written for is placed by its ostype: label and
      # warned about - and that warning is the loudest kind of wrong, because it
      # tells the operator to go and check a file that was read correctly.
      [[ -n "$GUEST_FAMILY" ]] \
        || GUEST_FAMILY=$(family_of "$(printf '%s' "$GUEST_REL" | tr '[:upper:]' '[:lower:]')")
      [[ -z "$GUEST_FAMILY" ]] || FAMILY_SRC="the CT itself"
    fi
  fi
  if [[ -z "$GUEST_FAMILY" ]]; then
    ostype=$(printf '%s\n' "$oldcfg" | sed -n 's/^ostype: *//p' | head -1)
    GUEST_FAMILY=$(family_of "$ostype")
    if [[ -n "$GUEST_FAMILY" ]]; then
      FAMILY_SRC="the CT config's 'ostype: $ostype'"
      log "WARN: could not read the guest's own release file - going by $FAMILY_SRC"
      log "WARN: if that label is wrong for what is really inside, pass --family"
    fi
  fi
fi

[[ -n "$GUEST_FAMILY" ]] || die "cannot tell what is inside CT $OLD_CTID - /etc/os-release and /etc/redhat-release could not be read and the config's ostype: says nothing this script knows. Pass --family el or --family debian"
[[ -n "$GUEST_REL" ]] && log "guest: $GUEST_REL"
[[ "$FAMILY_SRC" = "the CT itself" ]] && log "guest family: $GUEST_FAMILY (from $FAMILY_SRC)"

# The label default follows the family, because 'c7root' written on the side of
# an Ubuntu disk is a lie the next person has to work out at 2am. Nothing is
# relabelled by this: section 5 keeps an existing filesystem and refuses on a
# mismatch by name, so an image built under an older default still says what to
# pass. It is only the default for a filesystem that does not exist yet.
if [[ -n "$LABEL" ]]; then
  log "label $LABEL (forced by --label)"
else
  case "$GUEST_FAMILY" in
    el)     LABEL=c7root;;
    debian) LABEL=debroot;;
  esac
  log "label $LABEL (default for a $GUEST_FAMILY guest)"
fi

# Phase 2 is a different script per family and neither is optional: the last
# screen this prints tells the operator to run one of them by name, so a missing
# file has to be a refusal now rather than a command that does not exist later.
case "$GUEST_FAMILY" in
  el)
    [[ -r "$SELF/c2v-inside.sh" ]] \
      || die "cannot read $SELF/c2v-inside.sh (phase 2 for an EL guest lives next to this script)"
    # An EL guest cannot be finished without a DVD, so rule 5 applies to --iso
    # exactly as it does to the four flags checked at parse time. Refusing here
    # rather than at qm set is the point: an ISO typo only shows up after the
    # disk is already built, and phase 2 is unreachable without it.
    [[ -n "$ISO" ]] \
      || die "--iso is required for an EL guest and has no default - phase 2 installs its kernel from that disc (try --help)"
    iso_store="${ISO%%:*}"
    pvesm list "$iso_store" 2>/dev/null | awk '{print $1}' | grep -qx "$ISO" \
      || die "iso '$ISO' not found (pvesm list $iso_store)"
    iso_release_check
    ;;
  debian)
    [[ -x "$SELF/c2v-inside-deb.sh" ]] \
      || die "cannot execute $SELF/c2v-inside-deb.sh (phase 2 for a Debian-family guest lives next to this script and runs on THIS node)"
    if [[ -n "$ISO" ]]; then
      # Not a refusal: an operator converting a mixed batch will have the flag in
      # their shell history and copying it here is harmless. Saying it does
      # nothing is the part that matters, so nobody waits for a rescue prompt.
      log "WARN: --iso is ignored for a $GUEST_FAMILY guest - phase 2 runs in a chroot on this node, using this host's own apt and grub"
      ISO=""
    fi
    ;;
esac

# Size the VM like the container it is replacing, because that is the number
# somebody already decided was right for this workload. A flag still wins - it
# is the only way to give a converted machine more room than the CT had.
#
# Neither key is guaranteed. A CT with no `cores:` is not limited at all and runs
# on every core the node has, which is not a number a VM can be given, and a
# config with no `memory:` is malformed but readable. Both fall back and say so
# rather than being taken as zero.
cfgval(){ printf '%s\n' "$oldcfg" | sed -n "s/^$1: *\([0-9][0-9]*\).*/\1/p" | head -1; }

# The floor is not a guess about the workload. It is the smallest machine that
# can still finish being converted and then boot, and the two families do not
# need the same thing. On EL, phase 2 itself is the cost: yum and dracut run
# inside the guest's own rescue environment, which does not fit in what a small
# container is happy with. On the Debian side phase 2 runs on this node and
# spends this node's memory, so all that is left to clear is the first boot -
# where the initramfs is unpacked into RAM before the rootfs is mounted, work a
# container never had to do. Either way an explicit --memory still goes under.
case "$GUEST_FAMILY" in
  el)     MEM_FLOOR=1024; FLOOR_WHY="phase 2 runs yum in the guest and needs the room";;
  *)      MEM_FLOOR=512;  FLOOR_WHY="the initramfs is unpacked into RAM before / is mounted";;
esac

if [[ -n "$MEMORY" ]]; then
  log "memory ${MEMORY}M (forced by --memory)"
else
  MEMORY=$(cfgval memory)
  if [[ -z "$MEMORY" ]]; then
    MEMORY=2048
    log "WARN: CT $OLD_CTID has no memory: line - using ${MEMORY}M"
  elif (( MEMORY < MEM_FLOOR )); then
    log "memory: CT is ${MEMORY}M, raising to ${MEM_FLOOR}M - $FLOOR_WHY"
    MEMORY=$MEM_FLOOR
  else
    log "memory ${MEMORY}M (from CT $OLD_CTID)"
  fi
fi

if [[ -n "$CORES" ]]; then
  log "cores $CORES (forced by --cores)"
else
  CORES=$(cfgval cores)
  if [[ -z "$CORES" || "$CORES" = 0 ]]; then
    CORES=2
    log "WARN: CT $OLD_CTID is not limited to a core count - using $CORES"
  else
    log "cores $CORES (from CT $OLD_CTID)"
  fi
fi

mplist=$(printf '%s\n' "$oldcfg" | grep -E '^mp[0-9]+:' || true)
if [[ -n "$mplist" ]]; then
  log "WARN: this CT has extra mountpoint(s). rsync -x stops at the mount boundary,"
  log "WARN: so their DATA IS NOT COPIED and they will be empty directories in the VM:"
  printf '%s\n' "$mplist" | sed 's/^/  WARN:   /'
  log "WARN: copy that data yourself, or attach it as a second virtio disk later"
fi

# Turn the CT's own net lines into the qm set commands the VM will need, because
# the two configs do not say the same things. A CT's netN carries the address; a
# VM's does not, and never will - the address lives in the guest's ifcfg, which
# phase 2 cleans and leaves alone. What the VM's netN does carry, and what is
# easy to lose in the move, is the MTU: on a CT the host sets it from this line,
# so a guest running jumbo frames has nothing anywhere inside it that says 9000,
# and a VM built without it comes up at 1500 and works perfectly until a payload
# is big enough to matter. tag= is the same story for a VLAN.
#
# hwaddr is deliberately not carried across. Two machines answering to one MAC on
# one segment is exactly what rule 4 exists to prevent, and the operator who
# wants the old MAC back after the CT is stopped can add it in one flag.
#
# A bridge name is local to a node. vmbr1 on the old node and vmbr1 here are the
# same string and need not be the same network, and nothing in either config says
# so - which makes carrying the name across the one substitution that can put a
# machine on the wrong segment while looking completely correct. bridgemap.tsv is
# where the operator writes down what they already know:
#
#   old_node   old_bridge   new_node   new_bridge
#   pve6a      vmbr1        pve9a      vmbr2
#
# * is allowed in any of the first three columns, and the first row that matches
# wins, so specific rows go above general ones. A * in the bridge column is the
# lab case - one row sends every interface to the dead-end bridge the VM is being
# tested on - and because forgetting to take it out again would put a production
# machine on that bridge at go-live, a row like that says so every run.
#
# A bridge with no row is carried unchanged and marked UNMAPPED in the output,
# never quietly: rule 5 says do not guess, and a wrong guess here is not visible
# until something that should be reachable is not.
#
# Built here, where the config has just been read, and printed at the end where
# it is actually used.
HAVE_MAP=0
if [[ -r "$BRIDGEMAP" ]] && grep -qE '^[[:space:]]*[^#[:space:]]' "$BRIDGEMAP"; then
  HAVE_MAP=1
  # A short row never matches anything, so it would silently behave as no map at
  # all - which is the failure this file exists to prevent. Refuse instead.
  badrows=$(awk 'NF && $1 !~ /^#/ && NF != 4 {printf "  line %d: %s\n", NR, $0}' "$BRIDGEMAP")
  [[ -z "$badrows" ]] || die "$BRIDGEMAP needs four columns per row (old_node old_bridge new_node new_bridge):
$badrows"
  log "bridge map: $BRIDGEMAP ($OLD_NODE -> $THIS_NODE)"
fi

map_bridge(){ # map_bridge <old_bridge>; prints "<new_bridge> <row|catchall>"
  awk -v on="$OLD_NODE" -v ob="$1" -v nn="$THIS_NODE" '
    NF == 0 || $1 ~ /^#/ { next }
    ($1 == on || $1 == "*") && ($2 == ob || $2 == "*") && ($3 == nn || $3 == "*") {
      print $4, ($2 == "*" ? "catchall" : "row"); found = 1; exit
    }
    END { exit !found }
  ' "$BRIDGEMAP"
}

NETHINT=""; UNMAPPED=""; CATCHALL=""
while IFS= read -r ln; do
  [[ -n "$ln" ]] || continue
  n=${ln%%:*}
  rest=",${ln#*:},"
  rest=${rest// /}
  br=$(printf '%s' "$rest" | sed -n 's/.*,bridge=\([^,]*\),.*/\1/p')
  tag=$(printf '%s' "$rest" | sed -n 's/.*,tag=\([^,]*\),.*/\1/p')
  mtu=$(printf '%s' "$rest" | sed -n 's/.*,mtu=\([^,]*\),.*/\1/p')
  ipa=$(printf '%s' "$rest" | sed -n 's/.*,ip=\([^,]*\),.*/\1/p')

  src_br=${br:-vmbr0}; use_br="$src_br"; why=""
  if (( HAVE_MAP )); then
    if hit=$(map_bridge "$src_br"); then
      use_br=${hit%% *}
      [[ "${hit##* }" = catchall ]] && CATCHALL="$use_br"
      [[ "$use_br" = "$src_br" ]] || why="was $src_br on $OLD_NODE"
    else
      why="UNMAPPED - $BRIDGEMAP has no row for: $OLD_NODE $src_br $THIS_NODE ?"
      UNMAPPED="$UNMAPPED$src_br "
    fi
  fi

  cmt="$ipa"
  [[ -n "$why" ]] && cmt="${cmt:+$cmt  }$why"
  NETHINT="$NETHINT
    qm set $VMID --$n virtio,bridge=$use_br${tag:+,tag=$tag}${mtu:+,mtu=$mtu}${cmt:+   # $cmt}"
done < <(printf '%s\n' "$oldcfg" | grep -E '^net[0-9]+:' || true)

if [[ -n "$NETHINT" ]]; then
  log "the CT has $(printf '%s' "$NETHINT" | grep -c 'qm set') interface(s); the commands for them are printed at the end"
  if [[ -n "$UNMAPPED" ]]; then
    log "WARN: no bridge map row for:$UNMAPPED- the old names are carried across as they are"
    log "WARN: if that is not what this node calls those networks, add to $BRIDGEMAP:"
    for u in $UNMAPPED; do log "WARN:   $OLD_NODE	$u	$THIS_NODE	<name here>"; done
  elif (( ! HAVE_MAP )); then
    log "no $BRIDGEMAP - bridge names are carried from $OLD_NODE unchanged"
  fi
  # Said every run, on purpose. A catch-all row is a lab setting, and the run
  # where nobody notices it is still there is the run that puts a production
  # machine on a bridge with nothing on the other end.
  if [[ -n "$CATCHALL" ]]; then
    log "WARN: a * row in $BRIDGEMAP is sending EVERY interface to $CATCHALL"
    log "WARN: that is the lab bridge. Take the row out before go-live"
  fi
else
  log "WARN: the CT config has no netN line at all - check that $OLD_CTID is the right container"
  NETHINT="
    qm set $VMID --net0 virtio,bridge=vmbr0"
fi

# ---------------------------------------------------------------------------
# 1. size the disk:  max(quota, usage x factor)
# ---------------------------------------------------------------------------
if [[ -n "$FORCE_SIZE" ]]; then
  size_gib="$FORCE_SIZE"
  log "size ${size_gib}G (forced by --size)"
else
  quota=$(printf '%s\n' "$oldcfg" | awk -F'size=' '/^rootfs:/{print $2}' | awk -F, '{print $1}')
  quota_gib=$(printf '%s' "${quota:-8G}" | tr -dc '0-9')
  : "${quota_gib:=8}"

  if (( STOPPED )); then
    used_gib=0        # a stopped CT cannot be measured with pct exec; quota wins
  else
    usedb=$(ssh "${SSHOPT[@]}" "root@$OLD_NODE" "pct exec $OLD_CTID -- df -B1 -P /" </dev/null 2>/dev/null \
            | awk 'NR==2{print $3}')
    if [[ "$usedb" =~ ^[0-9]+$ ]]; then
      used_gib=$(( (usedb * SIZE_FACTOR / 100 + 1073741823) / 1073741824 ))
    else
      used_gib=0
      log "WARN: cannot measure usage inside CT $OLD_CTID - sizing from the quota alone"
    fi
  fi

  size_gib=$(( quota_gib > used_gib ? quota_gib : used_gib ))
  (( size_gib < 8 )) && size_gib=8
  log "size ${size_gib}G  (quota ${quota_gib}G, usage x${SIZE_FACTOR}% = ${used_gib}G)"
fi

# ---------------------------------------------------------------------------
# 2. create the VM shell.  virtio-blk, NOT virtio-scsi: virtio-scsi needs
#    RHEL 6.3+, virtio-blk has been in the tree since RHEL 5. When the guest's
#    minor version is unknown, take the one that cannot be wrong.
#
#    serial0 but NOT `--vga serial0`: the rescue ISO draws its boot screen on the
#    emulated VGA text console, so making serial the only display would hide the
#    one screen the operator has to act on - the `linux rescue` prompt on EL6,
#    the Troubleshooting menu on EL7. Keep VGA for noVNC and keep serial as the
#    second console, which is what phase 2 puts on the kernel command line.
#    A Debian guest never sees a rescue screen, but it gets the same machine:
#    one shape of VM to reason about is worth more than a display it will not
#    use, and grub is told to draw on both anyway.
# ---------------------------------------------------------------------------
if [[ ! -f "/etc/pve/qemu-server/$VMID.conf" ]]; then
  log "qm create $VMID (no network, onboot=0)"
  run qm create "$VMID" \
    --name "c2v-$OLD_CTID" \
    --memory "$MEMORY" --cores "$CORES" \
    --ostype l26 --bios seabios \
    --serial0 socket \
    --onboot 0 \
    || die "qm create failed"
fi

# ---------------------------------------------------------------------------
# 3. allocate the disk
# ---------------------------------------------------------------------------
IMG=$(pvesm path "$VOLID" 2>/dev/null || true)
if [[ -z "$IMG" || ! -e "$IMG" ]]; then
  log "pvesm alloc $VOLID (${size_gib}G, raw)"
  run pvesm alloc "$STORAGE" "$VMID" "vm-$VMID-disk-0.raw" "${size_gib}G" --format raw \
    || die "pvesm alloc failed on '$STORAGE'"
  IMG=$(pvesm path "$VOLID" 2>/dev/null || true)
fi
if (( DRYRUN )); then log "DRY: stopping before touching the image"; exit 0; fi
[[ -e "$IMG" ]] || die "image missing after alloc ($VOLID)"

# losetup only works on regular files. On LVM/ZFS the volume is a block device
# and its partitions need kpartx, which is a different and much easier thing to
# get wrong. Say so instead of half-supporting it.
[[ -f "$IMG" ]] || die "$IMG is not a regular file - use a dir/NFS storage for the conversion, then 'qm move-disk' afterwards"

# ---------------------------------------------------------------------------
# 4. partition table.  A CT image is a bare filesystem with no partition table
#    because LXC just mounts it. A VM needs an MBR to boot from, so the layout
#    is different from anything ct-migrate.sh produces.
#    MBR, not GPT: GRUB 0.97 on EL6 cannot boot from GPT at all, and phase 2
#    installs EL7's grub2 with --target=i386-pc, which is the BIOS target and
#    wants an MBR too. One layout serves both.
# ---------------------------------------------------------------------------
if ! parted -s "$IMG" print >/dev/null 2>&1 || ! parted -ms "$IMG" print 2>/dev/null | grep -q '^1:'; then
  log "parted: msdos label + one primary partition"
  parted -s "$IMG" mklabel msdos           || die "parted mklabel failed"
  parted -s "$IMG" mkpart primary ext4 1MiB 100% || die "parted mkpart failed"
  parted -s "$IMG" set 1 boot on           || die "parted set boot failed"
fi

LOOP=$(losetup -P -f --show "$IMG") || die "losetup failed on $IMG"
PART="${LOOP}p1"
[[ -b "$PART" ]] || die "$PART did not appear - kernel too old for 'losetup -P'?"

# ---------------------------------------------------------------------------
# 5. filesystem.
#    e2fsprogs on Debian 13 enables metadata_csum and 64bit by default. Kernel
#    2.6.32 refuses to mount a filesystem with either, and GRUB 0.97 cannot read
#    one. The failure mode is a VM that boots to "file not found" from the
#    bootloader with nothing in any log, so the flags are not optional.
#    An EL7 guest would read either set, and still gets this one: the filesystem
#    is made before a single byte of the guest has been copied, so nothing here
#    knows yet which release it is about to hold. The conservative set is the
#    one that is never wrong.
# ---------------------------------------------------------------------------
#
#    Deciding whether a filesystem is already here picks between mkfs and a
#    delta sync, and a wrong answer in one direction reformats a good 20 GiB
#    of synced data. blkid's exit status is not that answer: in low-level
#    probe mode it has reported success on a partition carrying no signature
#    at all, which skipped mkfs and then failed at mount with "bad superblock"
#    on an image one second old. Ask twice, read the output rather than the
#    status, and format only when both probes agree the partition is empty.
FSTYPE=$(blkid -p -s TYPE -o value "$PART" 2>/dev/null || true)
if dumpe2fs -h "$PART" >/dev/null 2>&1; then EXTSB=1; else EXTSB=0; fi

if [[ -z "$FSTYPE" ]] && (( EXTSB == 0 )); then
  log "mkfs.ext4 (EL6-compatible feature set), label=$LABEL"
  mkfs.ext4 -F -m0 -L "$LABEL" \
    -O '^64bit,^metadata_csum,^metadata_csum_seed,^orphan_file' \
    "$PART" || die "mkfs.ext4 failed on $PART"
elif (( EXTSB == 1 )); then
  log "filesystem already present on $PART (${FSTYPE:-ext}) - keeping it (delta sync)"
  # Keeping the filesystem also keeps the label it was made with, so a --label
  # given now would be silently ignored here and obeyed by phase 2, which writes
  # root=LABEL= from it. That combination boots to a dracut emergency shell.
  have_label=$(blkid -s LABEL -o value "$PART" 2>/dev/null || true)
  if [[ -n "$have_label" && "$have_label" != "$LABEL" ]]; then
    die "the existing filesystem is labelled '$have_label' but --label says '$LABEL' - phase 1 does not relabel a filesystem it is keeping. Re-run with --label $have_label, or wipe the disk and start over"
  fi
else
  die "$PART reports a '$FSTYPE' filesystem but carries no ext superblock - refusing to guess. Look with 'wipefs -n $PART'; if the partition really is empty, 'wipefs -a $PART' and run again"
fi

# ---------------------------------------------------------------------------
# 6. pull the rootfs
# ---------------------------------------------------------------------------
mkdir -p "$MNT"
mountpoint -q "$MNT" || mount "$PART" "$MNT" || die "mount $PART -> $MNT failed"

if (( STOPPED )); then
  ssh "${SSHOPT[@]}" "root@$OLD_NODE" "pct mount $OLD_CTID" </dev/null >/dev/null 2>&1 \
    || die "pct mount $OLD_CTID failed on $OLD_NODE"
  SRC="root@$OLD_NODE:/var/lib/lxc/$OLD_CTID/rootfs/"
  log "FINAL delta from a STOPPED CT (pct mount)"
else
  ctpid=$(ssh "${SSHOPT[@]}" "root@$OLD_NODE" "lxc-info -n $OLD_CTID -p -H" </dev/null 2>/dev/null || true)
  [[ "$ctpid" =~ ^[0-9]+$ ]] || die "cannot read the init pid of CT $OLD_CTID on $OLD_NODE"
  SRC="root@$OLD_NODE:/proc/$ctpid/root/"
fi

# -x stops at the mount boundary, which is what keeps an mp0 volume out of this
# image. --delete is what makes repeated runs a true delta; see the header for
# why /boot and /etc/fstab must be outside its reach.
#
# The second half of this list is the one that is not obvious, and it was missing
# long enough to cost a lab afternoon. A container has no kernel, no grub and no
# dracut, so on a delta run --delete does the only thing it can with the ones
# phase 2 installed: it removes them. /boot was already excluded, so the VM still
# BOOTS afterwards - which is exactly what makes it so quiet. It comes up, it
# logs in, and it has no modules left to load and no way to rebuild its own
# initramfs. Re-running phase 2 to repair it then finds have_bootloader false,
# falls through to the yum branch, and dies with "no install media at
# /mnt/source" on a VM that has no disc in the drive.
#
# Naming them here is enough to keep them: rsync protects excluded files on the
# receiver from --delete unless it is also given --delete-excluded, which it is
# not. Section 6c checks this list has not gone stale.
#
# /var/lib/rpm is deliberately NOT protected. The rpm database has to describe
# the filesystem it sits on, and every other byte of that filesystem comes from
# the container - so it gets the container's database and forgets these four
# packages. That is why phase 2 tests for files rather than asking rpm.
RSOPT=(-aHAX --numeric-ids --sparse -x --delete "--bwlimit=$BWLIMIT"
  '--exclude=/proc/*' '--exclude=/sys/*' '--exclude=/dev/*'
  '--exclude=/run/*'  '--exclude=/tmp/*' '--exclude=/lost+found'
  '--exclude=/boot/***' '--exclude=/etc/fstab' '--exclude=/etc/mtab'
  '--exclude=/etc/udev/rules.d/70-persistent-net.rules'
  # kernel modules. /lib is a symlink to /usr/lib on EL7 and a real directory on
  # EL6, and an exclude that matches nothing costs nothing, so name both.
  '--exclude=/lib/modules' '--exclude=/usr/lib/modules'
  # dracut: /usr/lib on EL7, /usr/share and /sbin on EL6
  '--exclude=/usr/bin/dracut' '--exclude=/sbin/dracut' '--exclude=/usr/sbin/dracut'
  '--exclude=/usr/lib/dracut' '--exclude=/usr/share/dracut'
  '--exclude=/etc/dracut.conf' '--exclude=/etc/dracut.conf.d'
  # initramfs-tools is what dracut is called on the Debian side, and it is named
  # here for exactly the same reason: phase 2 installs it, and a delta re-run
  # would otherwise --delete it straight back off the disk. /etc/kernel holds the
  # postinst.d hooks that run update-initramfs and update-grub when a kernel is
  # installed, so losing it breaks the next kernel upgrade rather than this boot,
  # which is the kind of damage nobody connects back to a re-sync.
  # Both spellings of sbin for the same reason /lib and /usr/lib are both above:
  # Ubuntu 20.04 has merged /usr and Debian 9 has not, and which of the two a
  # container is depends on how old the template was, not on what it says it is.
  '--exclude=/etc/initramfs-tools' '--exclude=/usr/share/initramfs-tools'
  '--exclude=/usr/sbin/update-initramfs' '--exclude=/usr/sbin/mkinitramfs'
  '--exclude=/sbin/update-initramfs' '--exclude=/sbin/mkinitramfs'
  '--exclude=/etc/kernel'
  # grub, all three generations. The glob takes grubby, which EL's kernel
  # scriptlets need, and grub-install/grub-mkconfig/grub-probe, which Debian's
  # do; a container has no reason to carry any of them. Same rule as the modules
  # above - an exclude that matches nothing costs nothing, so name both families.
  '--exclude=/sbin/grub*' '--exclude=/usr/sbin/grub*' '--exclude=/usr/bin/grub*'
  '--exclude=/usr/lib/grub' '--exclude=/usr/share/grub'
  '--exclude=/etc/grub.d' '--exclude=/etc/default/grub' '--exclude=/etc/grub2.cfg'
  '--exclude=/etc/default/grub.d')

# The transfer gets its own ssh, off the multiplexed socket the probes share. Two
# reasons, and the first one is silent: a session that rides an existing master
# keeps the cipher that master already negotiated, so -c would do nothing at all
# on any run where a probe had gone first - which is every run. The second is the
# one the engine gives for the same split: a transfer measured in hours must not
# share its fate with eight short probes, or die with their master. Compression
# is off explicitly, against a site-wide ssh_config that turned it on and made a
# single gzip thread the ceiling on a fast link.
RSH="ssh ${SSHOPT_COMMON[*]} -o ControlMaster=no -o ControlPath=none -o Compression=no"
[[ -n "$SSH_CIPHERS" ]] && RSH="$RSH -c $SSH_CIPHERS"
RSOPT+=(-e "$RSH")

log "rsync <= $SRC"
if [ -t 1 ]; then rsync "${RSOPT[@]}" --info=progress2 "$SRC" "$MNT/"; else rsync "${RSOPT[@]}" "$SRC" "$MNT/"; fi
rc=$?

if (( STOPPED )); then
  ssh "${SSHOPT[@]}" "root@$OLD_NODE" "pct unmount $OLD_CTID" </dev/null >/dev/null 2>&1 \
    || log "WARN: pct unmount $OLD_CTID on $OLD_NODE failed - check it by hand"
fi

# 24 = files vanished mid-sync, which is normal on a live CT. 23 is a partial
# transfer and is a real failure. 11 is out of space.
case "$rc" in
  0)  log "rsync ok";;
  24) log "rsync ok (rc=24: files vanished mid-sync, normal on a live CT)";;
  11) die "rsync out of space - grow the image: truncate -s <N>G $IMG ; e2fsck -fp $PART ; resize2fs $PART ; run again";;
  *)  die "rsync failed (rc=$rc) - image left as-is, nothing attached, do NOT boot this VM";;
esac

# ---------------------------------------------------------------------------
# 6b. undo the unprivileged-container id shift
# ---------------------------------------------------------------------------
# An unprivileged CT stores every file with its id shifted by the userns map -
# PVE's default is `u 0 100000 65536`, so the container's root is uid 100000 on
# disk. PVE 6 has no idmapped mounts, so that shift is physically in the inodes,
# and --numeric-ids copies it here byte for byte. That is the only correct thing
# rsync could do: without it the ids would be mapped through THIS host's
# /etc/passwd, which is Debian's, and a CentOS guest would come out wearing
# Debian's uid numbering.
#
# A VM has no such map, and the result is not a permissions problem. Root in the
# VM keeps CAP_DAC_OVERRIDE, so login, ls, df and cat all behave perfectly
# normally on a completely mis-owned filesystem, which is why this hides so well.
# What it breaks is setuid, because a setuid binary takes its euid from the FILE
# OWNER rather than from 0: root exec'ing a /bin/mount owned by 100000 lands on
# euid 100000, a privilege DROP, and mount refuses with
#   mount: only root can use "--options" option (effective UID is 100000)
# systemd-remount-fs is the first caller. It fails, root stays mounted ro
# exactly as the kernel left it, and from there every service that writes at
# start dies with errno 30. The VM boots, logs in fine, and is dead.
#
# So: read the shift back off the image and take it out again. /etc is the
# probe because it is root-owned on every Red Hat release ever shipped, and
# reading it here rather than over ssh means one number that describes what
# rsync actually wrote, not what it was asked to write. A delta re-run measures
# the same shift again, because rsync re-applies the source ownership to every
# directory it walks, so this stays correct however many times it runs.
idoff=$(stat -c %u "$MNT/etc" 2>/dev/null || true)
[[ "$idoff" =~ ^[0-9]+$ ]] || die "cannot stat $MNT/etc to read the id shift - the sync did not produce a rootfs"

if [ "$idoff" = 0 ]; then
  log "ids: /etc is owned by root, nothing to renumber (privileged CT)"
elif [ "$idoff" -lt 65536 ]; then
  die "/etc is owned by uid $idoff, which is not a userns map - refusing to guess. Check 'grep idmap /etc/pve/lxc/$OLD_CTID.conf' on $OLD_NODE"
else
  idmax=$((idoff + 65535))
  log "ids: /etc is owned by $idoff - unprivileged CT, renumbering [$idoff..$idmax] back to [0..65535]"

  # One traversal to learn which ids are actually present, then one pass per
  # distinct id. The obvious version - chown once per file - is a million forks
  # on a real rootfs. This is about thirty, and every pass after the first runs
  # off cached metadata.
  #
  # Ascending order is what makes renaming in place safe: every id only ever
  # moves DOWN, so a file an earlier pass has already fixed can never be
  # selected by a later one, whatever the offset turns out to be.
  uids=$(find "$MNT" -xdev -printf '%U\n' | sort -un) \
    || die "cannot enumerate owners under $MNT - not renumbering, do NOT boot this VM"
  gids=$(find "$MNT" -xdev -printf '%G\n' | sort -un) \
    || die "cannot enumerate groups under $MNT - not renumbering, do NOT boot this VM"
  [ -n "$uids" ] || die "no owners found under $MNT - the sync did not produce a rootfs"

  stray=""
  for u in $uids; do
    if [ "$u" -lt "$idoff" ]; then
      # 0 is expected: lost+found, and the directories section 7 is about to make
      [ "$u" = 0 ] || stray="$stray uid=$u"
      continue
    fi
    # Above the window means the file was made by something the map cannot
    # express - inside the CT it shows up as nobody. Renumbering it would invent
    # an owner, so it is named and left alone.
    if [ "$u" -gt "$idmax" ]; then stray="$stray uid=$u"; continue; fi
    find "$MNT" -xdev -uid "$u" -exec chown -h "$((u - idoff))" {} +
  done
  for g in $gids; do
    if [ "$g" -lt "$idoff" ]; then
      [ "$g" = 0 ] || stray="$stray gid=$g"
      continue
    fi
    if [ "$g" -gt "$idmax" ]; then stray="$stray gid=$g"; continue; fi
    find "$MNT" -xdev -gid "$g" -exec chgrp -h "$((g - idoff))" {} +
  done
  [ -n "$stray" ] && log "WARN: ids outside the map, left as they are:$stray"

  # The post-condition, one cheap traversal that stops at the first survivor.
  # Checking the image rather than checking a list of setuid binaries is the
  # point: anything still in the shifted window is a bug in the loop above, and
  # this is the last moment where saying so costs nothing.
  left=$(find "$MNT" -xdev \( -uid +"$((idoff - 1))" -uid -"$((idmax + 1))" \) -print -quit)
  [ -z "$left" ] || die "renumber did not take: $left is still in [$idoff..$idmax]"
  left=$(find "$MNT" -xdev \( -gid +"$((idoff - 1))" -gid -"$((idmax + 1))" \) -print -quit)
  [ -z "$left" ] || die "renumber did not take: $left still has a group in [$idoff..$idmax]"
  log "ids: renumbered, no owner left in the container's range"
fi

# ---------------------------------------------------------------------------
# 6c. did the sync just take phase 2's own packages away?
# ---------------------------------------------------------------------------
# The exclude list in section 6 is hand written, and a hand written list of paths
# that belong to four packages goes stale. This is the cheap check that it has
# not: phase 2 decides whether it may skip the DVD by testing for exactly these
# three things, so testing them here means a stale list is reported on this node,
# with scrollback, instead of as a die on a VM console that cannot paste and has
# no disc in the drive.
#
# A kernel in /boot is the probe for "phase 2 has run". Before that all of this
# is legitimately missing, which is the whole reason a rescue ISO gets attached.
#
# It reports rather than dying, because by this point the deletion has already
# happened and stopping does not undo it - the source has no copy to restore
# from. What it can do is make section 8 attach the ISO again so the operator has
# a way to put them back, and say which of the three went.
if ls "$MNT"/boot/vmlinuz-* >/dev/null 2>&1; then
  [ -d "$MNT/lib/modules" ] || [ -d "$MNT/usr/lib/modules" ] \
    || PKGS_GONE="$PKGS_GONE /lib/modules"
  # The two families keep the bootloader and the initramfs generator under
  # different names, so the check has to follow the family or it reports every
  # healthy Ubuntu image as missing grub. What is being asked is the same
  # question either way: is the thing phase 2 installed still on the disk.
  case "$GUEST_FAMILY" in
    el)
      [ -x "$MNT/sbin/grub2-install" ] || [ -x "$MNT/usr/sbin/grub2-install" ] \
        || [ -x "$MNT/sbin/grub" ] || PKGS_GONE="$PKGS_GONE grub"
      [ -x "$MNT/usr/bin/dracut" ] || [ -x "$MNT/sbin/dracut" ] \
        || PKGS_GONE="$PKGS_GONE dracut"
      ;;
    debian)
      [ -x "$MNT/usr/sbin/grub-install" ] || [ -x "$MNT/sbin/grub-install" ] \
        || PKGS_GONE="$PKGS_GONE grub-install"
      [ -x "$MNT/usr/sbin/update-initramfs" ] || [ -x "$MNT/sbin/update-initramfs" ] \
        || PKGS_GONE="$PKGS_GONE update-initramfs"
      ;;
  esac
  if [[ -n "$PKGS_GONE" ]]; then
    log "WARN: this image has a kernel in /boot but not:$PKGS_GONE"
    log "WARN: an earlier sync deleted them and the CT has no copy to put back."
    # The remedy differs because the two phase 2s live in different places. EL
    # needs the disc back in the drive; Debian needs nothing attached at all,
    # only the same command run again on this node.
    case "$GUEST_FAMILY" in
      el)     log "WARN: the rescue ISO is being re-attached so phase 2 can reinstall them";;
      debian) log "WARN: run phase 2 again on this node and apt will put them back";;
    esac
  else
    log "phase 2's kernel, bootloader and initramfs generator all survived the sync"
  fi
fi

# ---------------------------------------------------------------------------
# 6d. will this image boot its own init, or land in rescue mode?
# ---------------------------------------------------------------------------
# A bootloader lives in the MBR, outside the filesystem, so it survives every
# rsync this script will ever do. That signature is the honest answer to "has
# phase 2 run yet", and section 8 already attaches the drives from it. It is
# read here rather than there because section 7 needs the same answer: some of
# what section 7 writes is only safe for the length of a rescue session.
#
# Reading the first sector of a file whose partition is mounted is safe - the
# MBR is outside p1, and nothing in this script writes it.
if dd if="$IMG" bs=512 count=1 2>/dev/null | grep -aq GRUB; then BOOTABLE=1; else BOOTABLE=0; fi

# ---------------------------------------------------------------------------
# 7. the three things a container rootfs has never needed
# ---------------------------------------------------------------------------
mkdir -p "$MNT"/{proc,sys,dev,run,boot,tmp}
chmod 1777 "$MNT/tmp"

# Same reasoning as the mtab block below. A container has no fstab worth keeping,
# so the first run has to invent one - rescue mode cannot find the system without
# it. A re-run against a VM that already boots is a different situation: whatever
# is in there now is what carried it through its last boot, and it may have lines
# this script did not write, because the operator is the one who adds a data disk.
# Overwriting it would take those away silently, on a run whose only purpose was
# to plant a corrected phase 2. Only the root line has to be right, so that is
# the only thing checked, and anything else in the file is none of this script's
# business.
# The braces are load-bearing: "$LABEL[[" reads as an array subscript.
if (( BOOTABLE )) && grep -Eq "^[[:space:]]*LABEL=${LABEL}[[:space:]]+/[[:space:]]" "$MNT/etc/fstab" 2>/dev/null; then
  log "keep /etc/fstab as it is (it already mounts / from LABEL=$LABEL)"
else
  log "write /etc/fstab (rescue mode cannot find the system without it)"
  cat > "$MNT/etc/fstab" <<EOF
LABEL=$LABEL  /          ext4    defaults        1 1
tmpfs         /dev/shm   tmpfs   defaults        0 0
devpts        /dev/pts   devpts  gid=5,mode=620  0 0
sysfs         /sys       sysfs   defaults        0 0
proc          /proc      proc    defaults        0 0
EOF
fi

# /etc/mtab is rsync-excluded, so what happens to it here is the whole of what
# the image gets - and what it should be depends entirely on where phase 2 runs.
# The long story below is about the EL path, where phase 2 boots a rescue ISO.
# The Debian path never boots anything strange, so it is the short one and it
# comes first.
#
# A symlink to /proc/self/mounts is simply correct for a Debian guest, before
# phase 2 and after it. The chroot phase 2 runs in has a real procfs mounted at
# /proc, so the link resolves there too, and nothing in this script or in phase 2
# ever wants a plain file. It is written unconditionally because the exclude
# means a fresh image does not have the file at all, and rewriting a link that
# already points at the right place costs nothing and cannot break a running VM
# the way replacing it with a plain file did on EL7.
if [[ "$GUEST_FAMILY" = debian ]]; then
  log "/etc/mtab -> /proc/self/mounts (correct before and after phase 2 on this family)"
  rm -f "$MNT/etc/mtab"
  ln -sf /proc/self/mounts "$MNT/etc/mtab"

# A container has no mount table of its own, so the CT templates ship /etc/mtab
# as a symlink into /proc. That symlink is what stops phase 2 from ever starting.
# Anaconda's rescue mode writes the table of what it just mounted into
# <root>/etc/mtab, the symlink is absolute, so it resolves against the RESCUE
# environment's root and the write lands on the rescue kernel's own procfs, which
# has no write handler. Python buffers the write, so the EINVAL surfaces at
# close() and rescue.py dies with "IOError: [Errno 22] Invalid argument" and no
# shell - on a screen that offers nothing but a reboot. A real empty file costs
# nothing: EL6 rc.sysinit clears and rebuilds it at every boot. The rm is not
# tidiness - a bare redirect follows the symlink, opens THIS host's procfs, exits
# 0 because it writes nothing, and leaves the image's symlink exactly as it was.
#
# An EL7 guest wants the symlink back, because systemd never writes mtab and a
# real file would stay frozen at empty, with df and mount reporting nothing
# mounted forever. Phase 2 restores it. It is done there rather than skipped
# here because the file has to be a plain file for the length of the rescue
# session, whichever release this turns out to be.
#
# Which is why this is conditional. All of the above is true exactly once, on the
# way into rescue mode. Run this script again on a VM that has already been
# through phase 2 and there is no rescue session to protect - section 8 boots it
# from its own disk - so replacing the symlink here does nothing but break it:
# EL7 has no rc.sysinit to rebuild the file, so it stays empty, systemd cannot
# see what is mounted, -.mount fails, dbus.socket and logind fail behind it, and
# the guest loops on "Failed to mount /" forever. That is a VM that booted
# perfectly until phase 1 was re-run to plant a corrected phase 2, and it takes
# the console away, so the "boot it and run phase 2 again" instruction section 8
# prints cannot be followed. Leave what phase 2 put here alone: it already chose
# the right one for this release, and rsync cannot touch it either way.
#
# Unless an older copy of this script already broke it, which is the case that
# has to be repaired rather than only left alone - the re-run IS the recovery,
# and the console the operator would otherwise fix it from is the thing that is
# down. The release is read out of the image instead of $GUEST_REL because that
# came over ssh from the container and this decision is about the disk.
elif (( BOOTABLE )); then
  img_rel=$(head -1 "$MNT/etc/redhat-release" 2>/dev/null || true)
  case "$img_rel" in
    *'release 7.'*|*'release 7 '*) img_el7=1;;
    *)                             img_el7=0;;
  esac
  if (( img_el7 )) && [ ! -L "$MNT/etc/mtab" ]; then
    log "WARN: /etc/mtab is a real file on an EL7 guest that boots its own init."
    log "WARN: an older phase 1 left it that way and systemd never rebuilds it -"
    log "WARN: that is the 'Failed to mount /' loop, and a read-only /. Repairing."
    rm -f "$MNT/etc/mtab"
    ln -sf /proc/self/mounts "$MNT/etc/mtab"
  else
    log "keep /etc/mtab as phase 2 left it (this disk boots its own init, not rescue)"
  fi
else
  log "replace /etc/mtab (a CT ships it as a symlink into /proc, which crashes rescue mode)"
  rm -f "$MNT/etc/mtab"
  : > "$MNT/etc/mtab"
  chmod 0644 "$MNT/etc/mtab"
fi

# Phase 2 has to reach the guest somehow, and the two families do not agree on
# how. An EL guest is finished from inside itself, so the script has to be on the
# disk before the disk is unmounted - there is no other way in, and the PVE
# console has no paste, so retyping it is not an option the operator has. Planting
# it on every run is what makes a delta sync the way to deliver a corrected phase
# 2. A Debian guest is finished from this node, where the script already is, so
# putting a copy inside the image would only be a second copy to go stale.
#
# This is also the last chance to read anything out of the filesystem: it is
# unmounted three lines down. Section 0a normally already asked the running CT
# what release it is, and this is the fallback for the cases where it could not -
# --stopped, or an ssh that came back empty. The last screen needs it, because
# EL6 and EL7 do not share a rescue path.
case "$GUEST_FAMILY" in
  el)
    # Read the version out of the file being planted rather than keeping a copy
    # of it here: two constants that must agree is one more thing that can drift,
    # and the whole point of printing it is to catch a stale copy.
    inside_ver=$(sed -n 's/^C2V_VERSION="\(.*\)"$/\1/p' "$SELF/c2v-inside.sh" | head -1)
    log "plant phase 2 at /root/c2v-inside.sh${inside_ver:+ [$inside_ver]}"
    install -m 0755 "$SELF/c2v-inside.sh" "$MNT/root/c2v-inside.sh"

    if [[ -z "$GUEST_REL" && -f "$MNT/etc/redhat-release" ]]; then
      GUEST_REL=$(head -1 "$MNT/etc/redhat-release" 2>/dev/null || true)
      # On the --stopped path this is the first moment the release is known, so
      # the ISO cross-check gets its only chance here. Still worth printing: the
      # disc is attached below, and phase 2 has not been run yet.
      iso_release_check
    fi
    ;;
  debian)
    log "phase 2 is not planted in the image on this family - it runs on this node"
    if [[ -z "$GUEST_REL" && -f "$MNT/etc/os-release" ]]; then
      GUEST_REL=$(sed -n 's/^PRETTY_NAME=//p' "$MNT/etc/os-release" 2>/dev/null | head -1 | tr -d '"')
      [[ -n "$GUEST_REL" ]] && log "guest: $GUEST_REL (read from the image)"
    fi
    ;;
esac

sync
umount "$MNT" || die "umount $MNT failed - do NOT attach this disk until it is clean"
losetup -d "$LOOP"; LOOP=""

# ---------------------------------------------------------------------------
# 8. attach.
#
#    $BOOTABLE, read in section 6d, decides what to attach: before phase 2 the
#    disk cannot boot and the ISO has to come first, after phase 2 putting the
#    ISO first would drop the operator back into rescue mode on a delta re-run
#    and look like the conversion had been undone.
#
#    There is a third case, and it is the one section 6c just found: the MBR
#    boots but the packages behind it are gone. Then the disc goes back in the
#    drive WITHOUT taking the head of the boot order, so the VM still starts
#    normally and phase 2, re-run from inside it, finds media to install from.
#
#    All three are EL cases. A Debian-family guest never boots anything but its
#    own disk, so there is nothing to decide and no drive to fill.
# ---------------------------------------------------------------------------
qm set "$VMID" --virtio0 "$VOLID" >/dev/null || die "qm set --virtio0 failed"

if [[ "$GUEST_FAMILY" = debian ]]; then
  log "boot from disk (this family's phase 2 runs on this node, so there is no ISO)"
  # Deleting an ide2 that is not there is not an error worth reporting, and the
  # operator may have attached one by hand for their own reasons on an earlier
  # run. Leaving a stale disc in the drive with the disk first in the boot order
  # is harmless, but it is one more thing to explain at 2am.
  qm set "$VMID" --delete ide2 >/dev/null 2>&1
  qm set "$VMID" --boot 'order=virtio0' >/dev/null || die "qm set --boot failed"
elif (( BOOTABLE )); then
  if [[ -n "$PKGS_GONE" ]]; then
    log "MBR carries a bootloader but$PKGS_GONE is missing - disk first, ISO in the drive"
    qm set "$VMID" --ide2 "$ISO,media=cdrom" >/dev/null || die "qm set --ide2 failed"
  else
    log "MBR already carries a bootloader - phase 2 has run, booting from disk"
    qm set "$VMID" --delete ide2 >/dev/null 2>&1
  fi
  qm set "$VMID" --boot 'order=virtio0' >/dev/null || die "qm set --boot failed"
else
  log "attach rescue ISO to VM $VMID (no bootloader on the disk yet)"
  qm set "$VMID" --ide2 "$ISO,media=cdrom" >/dev/null   || die "qm set --ide2 failed"
  qm set "$VMID" --boot 'order=ide2;virtio0' >/dev/null || die "qm set --boot failed"
fi

echo
hr
log "=== phase 1 done ==="

# Built once because it is printed on more than one screen and it must stay
# identical: an operator comparing two runs should not have to work out whether
# a difference in this line means anything. --iso is only in it when there is one
# - it is refused as meaningless on the Debian side, so printing it would hand
# back a command that warns.
RESYNC="$0 --old-node $OLD_NODE --old-ctid $OLD_CTID --vmid $VMID --storage $STORAGE${ISO:+ --iso $ISO}"

if [[ "$GUEST_FAMILY" = debian ]]; then

# One command, on this node, and it is the same command whatever state the disk
# is in - which is the whole benefit of not needing a rescue ISO. What changes
# between these three cases is only what the operator should expect it to do, so
# the framing is per-case and the instruction is not.
if (( ! BOOTABLE )); then
  DEBWHY="  VM $VMID has the rootfs and an fstab. It has no bootloader yet, and NO
  network, by design - add net0 by hand at go-live.

  Phase 2 installs the kernel, grub and the initramfs for it. It runs HERE, on
  this node, in a chroot onto the image: this host is Debian, so its apt, dpkg,
  grub-pc and initramfs-tools are the guest's own tools rather than a foreign
  set. Nothing is typed into a console that cannot paste, and no ISO is needed."
elif [[ -n "$PKGS_GONE" ]]; then
  DEBWHY="  VM $VMID is bootable and now holds a fresh copy of CT $OLD_CTID, but the
  packages phase 2 installed are not in this image:$PKGS_GONE

  An earlier run of this script synced them away - the container does not have a
  kernel, grub or initramfs-tools, so --delete removed the ones phase 2 had put
  there. /boot was excluded, which is why the VM still boots and still looks
  healthy while having no modules to load and no way to rebuild its own
  initramfs. This version of the script excludes them, so it will not happen
  again. Running phase 2 again reinstalls them."
else
  DEBWHY="  VM $VMID is already bootable and now holds a fresh copy of CT $OLD_CTID.
  It still has NO network, by design.

  The kernel, grub and initramfs-tools all survived, and so did /etc/fstab. But
  every VM-only edit phase 2 made inside /etc came back from the container with
  this sync: the serial getty, the securetty line and /etc/default/grub are the
  container's again. Running phase 2 again puts them back."
fi

cat <<EOF

$DEBWHY

  From this node, with the VM stopped:

    $SELF/c2v-inside-deb.sh --vmid $VMID --storage $STORAGE

  Then:

    qm start $VMID
    qm terminal $VMID

  Only once it boots and you are happy, and only once the old CT is stopped:
$NETHINT

  To re-sync later (the VM must be stopped; /boot, /etc/fstab and /etc/mtab are
  never touched by the sync, and phase 2 has to be run again after it):

    $RESYNC
    $RESYNC --stopped

EOF

elif (( BOOTABLE )) && [[ -n "$PKGS_GONE" ]]; then
cat <<EOF

  VM $VMID is bootable and now holds a fresh copy of CT $OLD_CTID, but the
  packages phase 2 installed are not in this image:$PKGS_GONE

  An earlier run of this script synced them away - the container does not have
  a kernel, grub or dracut, so --delete removed the ones phase 2 had put there.
  /boot was excluded, which is why the VM still boots and still looks healthy
  while having no modules to load and no way to rebuild its own initramfs.
  This version of the script excludes them, so it will not happen again.

  The rescue ISO is back in the drive for that reason, with the DISK still
  first in the boot order. Boot it normally and run phase 2 again: it finds the
  disc, reinstalls what is missing, rebuilds the initramfs, and puts back the
  VM-only edits inside /etc that this sync also overwrote.

    qm start $VMID
    qm terminal $VMID
    /root/c2v-inside.sh          # inside the VM, as root
    reboot

  Only once it boots and you are happy, and only once the old CT is stopped:
$NETHINT
    qm reboot $VMID

EOF
elif (( BOOTABLE )); then
cat <<EOF

  VM $VMID is already bootable and now holds a fresh copy of CT $OLD_CTID.
  It still has NO network, by design.

  This sync also brought /etc back from the container. The bootloader, the
  kernel, the modules, grub and dracut all survived, and so did /etc/fstab and
  /etc/mtab - this script leaves both of those alone on a disk that already
  boots, because they are what carried it through its last boot. But every
  VM-only edit phase 2 made inside /etc is gone: the ifcfg files have the
  container's HWADDR again and ttyS0 has dropped out of /etc/securetty, and
  SELinux is back to whatever the container had. Run phase 2 again to put them
  back. It
  finds the kernel, the bootloader and dracut still installed, skips the whole
  DVD step, and needs no rescue ISO - it is one command, from the VM's own
  console:

    qm start $VMID
    qm terminal $VMID
    /root/c2v-inside.sh          # inside the VM, as root
    reboot

  Only once it boots and you are happy, and only once the old CT is stopped:
$NETHINT
    qm reboot $VMID

EOF
else
case "$GUEST_REL" in
  *'release 6.'*|*'release 6 '*)
    RESCUE="  Guest is $GUEST_REL
  At the ISO's boot prompt type:

    linux rescue

  Answer: no network, and mount the system READ/WRITE. Then:" ;;
  *'release 7.'*|*'release 7 '*)
    RESCUE="  Guest is $GUEST_REL
  On the ISO's boot menu choose:

    Troubleshooting  >  Rescue a CentOS system  >  1) Continue

  Continue is the read/write option, and it is the one that bind-mounts /dev.
  Then:" ;;
  *)
    RESCUE="  Guest release not recognised${GUEST_REL:+ ($GUEST_REL)} - on the ISO's boot screen:

    EL6:  type   linux rescue
    EL7:  choose Troubleshooting > Rescue a CentOS system > 1) Continue

  Either way, mount the system READ/WRITE. Then:" ;;
esac
cat <<EOF

  VM $VMID has the rootfs, an fstab and no bootloader yet. It has NO network,
  by design - add net0 by hand at go-live.

  Next, by hand:

    qm start $VMID
    qm terminal $VMID            # or the noVNC console

$RESCUE

    /mnt/sysimage/root/c2v-inside.sh

  That one line is the whole of phase 2. Run from the rescue shell it binds the
  DVD onto the image's /mnt/source and chroots itself - the two steps that used
  to be typed by hand, in a console with no paste.

  When it finishes, from this node:

    qm stop $VMID
    qm set $VMID --delete ide2
    qm set $VMID --boot order=virtio0
    qm start $VMID
    qm terminal $VMID

  Only once it boots and you are happy:
$NETHINT

  To re-sync later (before or after phase 2, both are safe - the VM must be
  stopped, and /boot, /etc/fstab and /etc/mtab are never touched by the sync):

    $RESYNC
    $RESYNC --stopped

EOF
fi
