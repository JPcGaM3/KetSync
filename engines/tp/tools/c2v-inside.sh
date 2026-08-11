#!/bin/bash
# =============================================================================
#  c2v-inside.sh — make a synced container rootfs bootable. Phase 2 of 2.
# -----------------------------------------------------------------------------
#  Runs INSIDE the guest, in the rescue environment of an install DVD that
#  matches the guest's own release. EL6 and EL7 are both handled; the release
#  is read out of /etc/redhat-release and everything version specific branches
#  on it. After phase 1:
#
#      qm start <vmid>                  boots the ISO that phase 1 attached
#      linux rescue                     EL6: type that at the boot prompt
#                                       EL7: Troubleshooting > Rescue a CentOS
#                                       system
#                                       either way, mount READ/WRITE
#      /mnt/sysimage/root/c2v-inside.sh
#
#  That last line is the whole of it. Started from the rescue shell this script
#  binds the install DVD onto the image's /mnt/source and chroots into the image
#  itself, which used to be two commands with four confusable paths between
#  them, typed by hand into a console that cannot paste. Doing your own
#  `chroot /mnt/sysimage` first and then running /root/c2v-inside.sh still
#  works and is unchanged.
#
#  options:
#    --label NAME    ext4 label of the root filesystem     (default c7root)
#    --disk DEV      whole disk to write the MBR to        (default: derived)
#    --kver VER      kernel version to boot                (default: newest)
#    --source DIR    the mounted install DVD               (default /mnt/source)
#    --sysroot DIR   where rescue mounted the image        (default /mnt/sysimage)
#    --repo DIR      the mounted DVD, in the RESCUE shell  (tried before the
#                    usual /run/install/repo and /mnt/source)
#    --no-relabel    skip creating /.autorelabel
#    --no-serial     skip the ttyS0 getty and serial console
#    -h, --help      this text
#
# -----------------------------------------------------------------------------
#  WHY THIS RUNS HERE AND NOT ON THE PVE HOST
#
#  On EL6 it is not a preference. rpm, dracut and grub inside that image are
#  glibc 2.12 binaries, glibc 2.12 reads the vsyscall page, and a modern host
#  boots with vsyscall=none, so all three segfault at ffffffffff600400 the
#  moment you chroot into the image from PVE 9. The rescue ISO runs kernel
#  2.6.32, where vsyscall is native, so the same binaries simply work.
#
#  EL7 clears that bar - glibc 2.17 does not touch the vsyscall page - and it
#  still runs here, for two reasons that are just as final. The host has no rpm
#  and no yum, so there is nothing to install packages with. And the host's own
#  grub2 is Debian's: it writes its core.img for /boot/grub with Debian's module
#  set, while the guest expects /boot/grub2 and its own. A bootloader assembled
#  from the wrong distribution's parts is the failure that looks like success.
#
#  Either way the ISO carries the kernel, the bootloader and dracut with every
#  dependency, which is why this installs from file:///mnt/source and never
#  needs a network or vault.centos.org.
#
#  THE FOURTH THING, WHICH IS NOT MISSING BUT WRONG
#
#  If the source was an unprivileged CT, every id in this rootfs is shifted by
#  the userns map, normally by 100000. Phase 1 takes that back out. Step 0b
#  checks it again here and fixes it if phase 1 did not, because by this point
#  the disk is attached to a running VM and phase 1 can no longer be re-run. It
#  is checked before anything else because the alternative is a VM that boots,
#  logs in, and has no working setuid — see the comment on step 0b.
#
#  WHAT A CONTAINER ROOTFS IS MISSING — EXACTLY THREE THINGS
#
#  A kernel, because a container borrows the host's. A bootloader, because a
#  container is never booted, so there is no MBR and no boot config. And an
#  initramfs that knows virtio, because nothing else can find the root disk.
#  Everything after step 6 is cleanup of assumptions a container was allowed to
#  get away with and a VM is not.
#
#  IDEMPOTENCE
#
#  Every step checks for its own result first, so a re-run after a failure
#  resumes instead of starting over. A re-run on a finished image is a no-op
#  plus a fresh initramfs, boot config and MBR, which is harmless.
# =============================================================================
set -uo pipefail

# Phase 1 re-plants this file on every run, so an old copy sitting inside a
# guest means the host it was planted from is carrying old tools too - and from
# inside the rescue shell there is no way to tell. Printing it in the banner is
# the cheapest fix: compare it against the runbook before trusting anything
# below it. Bump this whenever the behaviour of this script changes.
C2V_VERSION="2026-08-03e"

LABEL="c7root"; DISK=""; KVER=""; SRCDIR="/mnt/source"
SYSROOT="/mnt/sysimage"; REPOHINT=""
RELABEL=1; SERIAL=1

REPOFILE="/etc/yum.repos.d/c2v-iso.repo"
MOUNTED_SRC=0
# Bind mounts made in the rescue environment, newest first. Only ever set in
# the outer stage below; the inner run inherits nothing and unmounts nothing.
OUTER_MOUNTS=""

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

# A repo pointing at file:///mnt/source is a landmine once the ISO is detached:
# every yum run in production would then fail on a repo the operator never made
# and cannot explain. It exists for the length of this script and no longer.
cleanup(){
  rc=$?
  [ -f "$REPOFILE" ] && rm -f "$REPOFILE"
  [ "$MOUNTED_SRC" = 1 ] && umount "$SRCDIR" 2>/dev/null
  # Newest first, because the DVD bind sits under the sysroot and has to come
  # off before anything it is nested in. A mount left behind here is not
  # cosmetic: rescue mode unmounts the image on the way out, and one busy
  # mountpoint is the difference between a clean unmount and a dirty ext4.
  for m in $OUTER_MOUNTS; do umount "$m" 2>/dev/null; done
  exit $rc
}
trap cleanup EXIT INT TERM

# Kept before the loop eats them: the outer stage re-runs this same script
# inside the chroot and has to hand it the flags the operator actually typed.
ARGV=("$@")

while [ $# -gt 0 ]; do
  case "$1" in
    --label)      LABEL="${2:-}";  shift 2;;
    --disk)       DISK="${2:-}";   shift 2;;
    --kver)       KVER="${2:-}";   shift 2;;
    --source)     SRCDIR="${2:-}"; shift 2;;
    --sysroot)    SYSROOT="${2:-}"; shift 2;;
    --repo)       REPOHINT="${2:-}"; shift 2;;
    --no-relabel) RELABEL=0; shift;;
    --no-serial)  SERIAL=0;  shift;;
    -h|--help)    sed -n '2,35p' "$0"; exit 0;;
    *) die "unknown option: $1 (try --help)";;
  esac
done

# ---------------------------------------------------------------------------
# 0. preflight
# ---------------------------------------------------------------------------
hr
set_log "${SYSROOT%/}/var/log/c2v-phase2.log"
log "=== c2v phase 2 [$C2V_VERSION]: make this rootfs bootable (label=$LABEL) ==="

[ "$(id -u)" = "0" ] || die "run this as root"

# ---------------------------------------------------------------------------
# 0a. the rescue shell, if that is where we are
#
# Outside the chroot every step below would land in the rescue ramdisk, which is
# thrown away at reboot, so the image would look untouched for no visible
# reason. That used to be a refusal: chroot first, it said, and then - once the
# DVD turned out to be invisible from inside the chroot - bind /run/install/repo
# onto /mnt/sysimage/mnt/source, four confusable paths typed by hand into a
# console that cannot paste.
#
# The bind has to happen out here whatever else is true, because the rescue
# shell is the only context that can see both the disc and the image at once;
# from inside the chroot the mounted repo is simply not in the namespace. So do
# it here and chroot ourselves. What the operator types is one path.
# ---------------------------------------------------------------------------
# C2V_INNER is set on the way in below and is the only thing standing between a
# rootfs that happens to contain an empty /mnt/sysimage and a chroot loop that
# an operator would have to kill from the PVE host.
if [ -d "$SYSROOT" ] && [ -z "${C2V_INNER:-}" ]; then
  log "rescue shell: $SYSROOT is mounted, so this run sets up and chroots itself"

  # An empty $SYSROOT means rescue never mounted the disk - almost always the
  # read-only option, or "skip to shell". Say which, because the next thing an
  # operator does with a bare directory is assume phase 1 failed.
  [ -x "$SYSROOT/root/c2v-inside.sh" ] || die "$SYSROOT has no /root/c2v-inside.sh in it.
  Either rescue did not mount the VM's disk - go back and take the read/write
  option, not read-only and not skip-to-shell - or phase 1 never finished."

  # Anaconda binds these itself, both on EL6 and EL7, but "1) Continue" is the
  # only choice that does and an operator who picked another one is otherwise
  # ten minutes from a rpm that cannot see /proc. Cheap to check, so check.
  for d in /dev /proc /sys; do
    if grep -q " $SYSROOT$d " /proc/mounts 2>/dev/null; then continue; fi
    if mount --bind "$d" "$SYSROOT$d" 2>/dev/null; then
      OUTER_MOUNTS="$SYSROOT$d $OUTER_MOUNTS"; log "  bound $d (rescue had not)"
    else
      log "  WARN: $d is not bound into $SYSROOT and could not be bound"
    fi
  done

  # /run/install/repo is where EL7 anaconda leaves the disc and /mnt/source is
  # where EL6 does. Ask /proc/mounts for anything iso9660 as well: a disc
  # attached as a second drive, or a rescue that mounted it somewhere else,
  # answers there and nowhere else. Verified by content, not by name - the
  # wrong mount here means yum installs from the wrong media.
  repo=""
  for d in $REPOHINT /run/install/repo /mnt/source $(awk '$3=="iso9660"{print $2}' /proc/mounts 2>/dev/null); do
    [ -d "$d/repodata" ] || [ -d "$d/Packages" ] || continue
    repo="$d"; break
  done

  if [ -n "$repo" ]; then
    mkdir -p "$SYSROOT$SRCDIR"
    if mount --bind "$repo" "$SYSROOT$SRCDIR" 2>/dev/null; then
      OUTER_MOUNTS="$SYSROOT$SRCDIR $OUTER_MOUNTS"
      log "  bound the DVD: $repo -> $SYSROOT$SRCDIR"
    else
      log "  WARN: found the DVD at $repo but could not bind it onto $SYSROOT$SRCDIR"
    fi
  else
    # Not fatal here. The inner run has its own fallback - it reads the device
    # out of /proc/mounts and mounts that - and it is in a better position to
    # report what it found than a guess from out here would be.
    log "  WARN: no install media found in the rescue environment either."
    log "  WARN:   looked at /run/install/repo, /mnt/source and every iso9660 mount."
    log "  WARN:   going in anyway - the chrooted run will try the drive directly."
  fi

  log "chroot $SYSROOT -> /root/c2v-inside.sh"
  C2V_INNER=1 chroot "$SYSROOT" /root/c2v-inside.sh "${ARGV[@]+"${ARGV[@]}"}"
  rc=$?
  # The EXIT trap takes the binds back off. Rescue unmounts the image on the way
  # out and one mount left behind is the difference between a clean unmount and
  # an ext4 that needs a fsck on the first real boot.
  [ $rc -eq 0 ] && { hr; log "=== phase 2 finished. Leave rescue and reboot: exit, then reboot ==="; }
  exit $rc
fi

[ -f /etc/redhat-release ] || die "no /etc/redhat-release - this is not the CentOS image"

# Everything version specific below branches on this one number. It used to be
# a warning. It is a refusal now, because a warning is a line that scrolls past
# at 2am and the next thing the script does is yum-install a kernel and a
# bootloader from whatever DVD is in the drive. Point an EL6 DVD at an EL7 root
# and rpm will happily write EL6 packages over an EL7 system, which is not a
# failed conversion but a broken original. Nothing here is version agnostic:
# grub 0.97 and grub2 are different bootloaders, with different install
# commands, different config paths and a different config language, and EL6
# dracut takes rd_NO_LVM where EL7 takes rd.lvm=0. Wrong release means wrong
# media, and there is nothing useful to do with wrong media but stop.
REL=$(cat /etc/redhat-release)
case "$REL" in
  *'release 6.'*|*'release 6 '*) EL=6 ;;
  *'release 7.'*|*'release 7 '*) EL=7 ;;
  *) die "$REL - this script knows EL6 and EL7 only, and the rescue media must match the guest" ;;
esac
log "guest: $REL"

# ---------------------------------------------------------------------------
# 0b. the id shift, before anything expensive
# ---------------------------------------------------------------------------
# An unprivileged CT stores every file with its id shifted by the userns map,
# PVE's default being `u 0 100000 65536`. Phase 1 removes that shift. Phase 1
# has not always done so, and an image built by an older copy arrives here
# still carrying it.
#
# It has to be caught, because it does not look like anything. Root keeps
# CAP_DAC_OVERRIDE, so the shell, ls, df and cat all behave normally on a
# completely mis-owned filesystem. What stops working is setuid: a setuid
# binary takes its euid from the FILE OWNER, so root exec'ing a /bin/mount
# owned by 100000 gets euid 100000 - a privilege DROP - and mount answers
#   mount: only root can use "--options" option (effective UID is 100000)
# systemd-remount-fs is the first caller, it fails, root stays mounted read
# only exactly as the kernel left it, and every service that writes at start
# dies with errno 30. The VM boots to a login prompt and is dead.
#
# Fixed here rather than reported, because by the time anyone reads this the
# disk is attached to a running VM and phase 1 cannot be re-run against it, and
# because this chroot is the one place where the fix is three commands. Done
# before step 1 because everything after it is a twenty minute yum install and
# a bootloader, none of it worth doing on an image that cannot boot into a
# working system.
#
# On an image that is already correct this costs one stat and stops.
idoff=$(stat -c %u /etc 2>/dev/null || true)
case "$idoff" in
  ''|*[!0-9]*) die "cannot stat /etc - this is not a rootfs" ;;
  0) : ;;
  *)
    [ "$idoff" -ge 65536 ] \
      || die "/etc is owned by uid $idoff, which is not a userns map - refusing to guess"
    idmax=$((idoff + 65535))
    log "ids: /etc is owned by $idoff - this image still carries the container's id shift"
    log "ids: renumbering [$idoff..$idmax] back to [0..65535], this walks the whole disk"
    # One pass per distinct id rather than one chown per file: about thirty
    # traversals instead of a million forks. Ascending order keeps it safe to do
    # in place, because every id only ever moves down, so a file an earlier pass
    # has already fixed can never be selected by a later one. -xdev is what keeps
    # it out of the /proc and /dev mounted above.
    for u in $(find / -xdev -printf '%U\n' | sort -un); do
      [ "$u" -ge "$idoff" ] && [ "$u" -le "$idmax" ] || continue
      find / -xdev -uid "$u" -exec chown -h "$((u - idoff))" {} +
    done
    for g in $(find / -xdev -printf '%G\n' | sort -un); do
      [ "$g" -ge "$idoff" ] && [ "$g" -le "$idmax" ] || continue
      find / -xdev -gid "$g" -exec chgrp -h "$((g - idoff))" {} +
    done
    left=$(find / -xdev \( -uid +"$((idoff - 1))" -uid -"$((idmax + 1))" \) -print -quit)
    [ -z "$left" ] || die "renumber did not take: $left is still owned in [$idoff..$idmax]"
    log "ids: renumbered - re-run phase 1 from the host as well, or the next delta brings it back"
    ;;
esac

is_mounted(){ grep -q " $1 " /proc/mounts 2>/dev/null; }

# rpm needs /proc for its file-descriptor and space checks, grub needs /dev to
# open the disk, and both fail in ways that do not name the missing mount.
is_mounted /proc || mount -t proc  proc  /proc  2>/dev/null
is_mounted /sys  || mount -t sysfs sysfs /sys   2>/dev/null
if ! is_mounted /dev; then
  # EL6 and EL7 both boot with devtmpfs, so an empty /dev is normal for a synced
  # rootfs. Create the two nodes early boot touches before devtmpfs is up anyway.
  [ -e /dev/console ] || mknod -m 600 /dev/console c 5 1 2>/dev/null
  [ -e /dev/null    ] || mknod -m 666 /dev/null    c 1 3 2>/dev/null
  mount -t devtmpfs devtmpfs /dev 2>/dev/null \
    || log "WARN: /dev is not mounted and devtmpfs failed - grub may not see the disk"
fi

# ---------------------------------------------------------------------------
# 1. find the root partition and the disk it lives on
# ---------------------------------------------------------------------------
have_disk(){
  local d
  for d in /dev/vd? /dev/sd? /dev/hd? /dev/xvd? /dev/nvme?n?; do
    [ -b "$d" ] && return 0
  done
  return 1
}

ROOTPART=$(blkid -L "$LABEL" 2>/dev/null)
[ -n "$ROOTPART" ] || ROOTPART=$(findfs "LABEL=$LABEL" 2>/dev/null)
if [ -z "$ROOTPART" ]; then
  # An empty /dev and a wrong label look identical from here - both are silence
  # out of blkid - and the two fixes have nothing to do with each other. Sending
  # somebody to re-check --label when the real fault is that nothing populated
  # /dev costs an hour, so separate them before saying anything. Rescue mode's
  # "Continue" bind-mounts /dev into the system it mounted; "Skip" does not, and
  # neither does a chroot done by hand.
  have_disk || die "/dev has no disks in it, so nothing can be found by label. Leave the chroot and bind-mount it from the rescue shell first: for d in dev proc sys; do mount --bind /\$d /mnt/sysimage/\$d; done - then chroot again"
  die "no filesystem labelled '$LABEL' - wrong --label, or phase 1 used a different one"
fi
log "root partition: $ROOTPART"

if [ -z "$DISK" ]; then
  case "$ROOTPART" in
    *[0-9]p[0-9]*) DISK="${ROOTPART%p*}" ;;                          # nvme-style
    *)             DISK=$(printf '%s' "$ROOTPART" | sed 's/[0-9]*$//') ;;
  esac
fi
[ -b "$DISK" ] || die "$DISK is not a block device - pass --disk"
log "boot disk: $DISK  (MBR goes here)"

# Phase 1 wrote this. If it is missing the guest mounts nothing and drops to a
# dracut shell, so check it here rather than discovering it at first boot.
grep -q "LABEL=$LABEL" /etc/fstab 2>/dev/null \
  || die "/etc/fstab does not reference LABEL=$LABEL - phase 1 did not finish"

# ---------------------------------------------------------------------------
# 2. the install DVD
# ---------------------------------------------------------------------------
have_source(){ [ -d "$SRCDIR/repodata" ] || [ -d "$SRCDIR/Packages" ]; }

if ! have_source; then
  # The rescue environment has already mounted the disc, but at a path the
  # chroot cannot reach - EL6 anaconda uses /mnt/source, EL7 /run/install/repo,
  # and neither survives the chroot. The path is out of reach; the device behind
  # it is not, because /proc is bind-mounted and names it. So ask /proc/mounts
  # first and only then fall back to guessing node names, which is what this
  # used to do alone and which says nothing when the drive is called something
  # else. Reported line by line on purpose: the previous version swallowed every
  # error and left an operator staring at three lines of silence and a die.
  log "$SRCDIR is empty in the chroot - looking for the DVD"
  mkdir -p "$SRCDIR"
  from_proc=$(awk '$3=="iso9660"{print $1}' /proc/mounts 2>/dev/null)
  for d in $from_proc /dev/sr0 /dev/sr1 /dev/scd0 /dev/cdrom /dev/hdc; do
    [ -b "$d" ] || continue
    if ! merr=$(mount -o ro "$d" "$SRCDIR" 2>&1); then
      log "  $d: ${merr:-mount failed}"
      continue
    fi
    if have_source; then MOUNTED_SRC=1; log "mounted $d at $SRCDIR"; break; fi
    log "  $d: mounted, but there is no Packages/ or repodata/ on it"
    umount "$SRCDIR" 2>/dev/null
  done
  if ! have_source; then
    # Nothing worked, so print what there was to work with. An operator in a
    # rescue shell cannot copy this out, but they can read it and say what it
    # says, which is more than an empty directory offers.
    ls -1d /dev/sr* /dev/cdrom /dev/hd? 2>/dev/null | sed 's/^/  device: /'
    grep -E 'iso9660|/run/install|/mnt/source' /proc/mounts 2>/dev/null | sed 's/^/  mount: /'
  fi
fi

# ---------------------------------------------------------------------------
# 3. kernel, bootloader, initramfs generator
# ---------------------------------------------------------------------------
have_kernel(){ ls /boot/vmlinuz-* >/dev/null 2>&1; }

if [ "$EL" = 6 ]; then
  # dracut-kernel is a separate package on EL6 and is what carries the 90kernel
  # modules dracut needs; on EL7 it was folded into dracut itself.
  PKGS="kernel grub dracut dracut-kernel"
  have_bootloader(){ [ -x /sbin/grub ]; }
else
  # grub2 on 7.9 is a metapackage that pulls grub2-pc, and grub2-tools is what
  # actually carries grub2-install. Naming grub2-tools as well costs nothing and
  # means a Minimal ISO that is missing it fails here, by name, instead of five
  # steps later with "grub2-install: command not found".
  PKGS="kernel grub2 grub2-tools dracut"
  have_bootloader(){ command -v grub2-install >/dev/null 2>&1; }
fi

if have_kernel && have_bootloader && command -v dracut >/dev/null 2>&1; then
  log "kernel, bootloader and dracut already installed - skipping the install"
else
  # Name the way out, not just the symptom. The fix is almost always to bind
  # the path the rescue system already has onto the one the chroot can see, and
  # that has to be done from outside the chroot, which is not obvious from in
  # here - the operator is standing in the one place the command cannot be run.
  have_source || die "no install media at $SRCDIR. Leave the chroot (type exit) and run:

    $SYSROOT/root/c2v-inside.sh

  which does the bind and the chroot itself. If it says it found no media either,
  the CentOS $EL DVD is not attached to this VM at all - re-run phase 1, or attach
  it from the host with: qm set <vmid> --ide2 <storage>:iso/<file>,media=cdrom"

  # A container image carries repo files pointing at mirror.centos.org, which
  # has been dead since 2020 and would hang the transaction on a DNS timeout.
  # Everything is disabled and only this one is turned on.
  cat > "$REPOFILE" <<EOF
[c2v-iso]
name=CentOS $EL install DVD
baseurl=file://$SRCDIR
enabled=1
gpgcheck=0
EOF

  # A stale Berkeley DB lock from the container's last transaction makes rpm
  # hang forever with no output. Cheap to clear, impossible to diagnose live.
  rm -f /var/lib/rpm/__db.*

  log "yum install $PKGS (from $SRCDIR)"
  # shellcheck disable=SC2086  # PKGS is a deliberate word list, not one name
  yum --disablerepo='*' --enablerepo=c2v-iso --disableplugin='*' \
      --nogpgcheck -y install $PKGS \
    || die "yum install failed - is the whole DVD mounted at $SRCDIR?"

  have_kernel || die "yum reported success but /boot has no vmlinuz - stop here and look"

  # yum prints "No package X available" and still exits 0 as long as SOMETHING
  # in the list installed, so a successful transaction proves nothing about the
  # bootloader. This is the line that catches an install DVD that is too small.
  have_bootloader || die "yum finished but there is still no bootloader - $SRCDIR is probably not the full DVD"
fi

# ---------------------------------------------------------------------------
# 4. pick the kernel to boot
# ---------------------------------------------------------------------------
if [ -z "$KVER" ]; then
  KVER=$(ls -1 /boot/vmlinuz-* 2>/dev/null \
         | sed 's|.*/vmlinuz-||' \
         | grep -v -e '\.hmac$' -e 'rescue' \
         | sort -V | tail -1)
fi
[ -n "$KVER" ] || die "cannot work out a kernel version from /boot"
[ -f "/boot/vmlinuz-$KVER" ] || die "/boot/vmlinuz-$KVER does not exist"
log "kernel: $KVER"

# ---------------------------------------------------------------------------
# 5. initramfs.
#    --no-hostonly on purpose: a hostonly image is built for the hardware dracut
#    can see right now, which is the rescue environment's view, and the guest
#    only gets one chance to find its root disk. Generic costs a few MB.
#    virtio_blk because phase 1 attaches virtio0 - virtio-scsi needs RHEL 6.3+
#    and this has to work on any EL6.
# ---------------------------------------------------------------------------
log "dracut: rebuilding /boot/initramfs-$KVER.img with virtio drivers"
dracut --force --no-hostonly \
  --add-drivers "virtio virtio_ring virtio_pci virtio_blk virtio_net virtio_console ext4" \
  "/boot/initramfs-$KVER.img" "$KVER" \
  || die "dracut failed - the VM would boot to a dracut emergency shell"
[ -s "/boot/initramfs-$KVER.img" ] || die "/boot/initramfs-$KVER.img is empty"

# ---------------------------------------------------------------------------
# 6. bootloader. Two entirely separate implementations - see the release check.
#
#    Both branches write the boot config by hand instead of asking grub for it,
#    and on EL7 that means deliberately not running grub2-mkconfig. Its output
#    depends on things this environment cannot promise: 10_linux asks grub2-probe
#    what device is behind /, which is only right if /proc was bind-mounted into
#    the chroot, and os-prober happily adds entries for the rescue media it is
#    booted from. It also writes root=UUID=, and that UUID was invented by
#    phase 1's mkfs and appears nowhere the operator can check. root=LABEL= is
#    the one identifier both phases agree on and can be read off the command
#    line that started phase 1.
# ---------------------------------------------------------------------------
CONSOLE_ARGS="console=tty0"
if [ "$SERIAL" = "1" ]; then
  CONSOLE_ARGS="console=tty0 console=ttyS0,115200n8"
fi

if [ "$EL" = 6 ]; then
  # -------------------------------------------------------------------------
  # grub 0.97. grub.conf, not grub.cfg. root (hd0,0) is the first primary
  # partition, the only one phase 1 creates, and /boot is on it rather than
  # separate, so the kernel path keeps its /boot prefix.
  # -------------------------------------------------------------------------
  mkdir -p /boot/grub

  # `setup (hd0)` reads stage1/stage2/e2fs_stage1_5 out of /boot/grub. They only
  # arrive there because grub-install copies them, and grub-install is exactly
  # the script that misbehaves in a chroot, so copy them directly.
  for f in /usr/share/grub/*/*; do
    [ -f "$f" ] || continue
    cp -f "$f" /boot/grub/
  done
  [ -f /boot/grub/stage2 ] || die "/boot/grub/stage2 missing - the 'grub' package did not install"

  printf '(hd0)\t%s\n' "$DISK" > /boot/grub/device.map

  SERIAL_HEAD=""
  if [ "$SERIAL" = "1" ]; then
    SERIAL_HEAD=$'serial --unit=0 --speed=115200 --word=8 --parity=no --stop=1\nterminal --timeout=10 console serial'
  fi

  log "write /boot/grub/grub.conf"
  {
    echo "# generated by c2v-inside.sh - hand edits survive nothing but a re-run"
    echo "default=0"
    echo "timeout=5"
    [ -n "$SERIAL_HEAD" ] && printf '%s\n' "$SERIAL_HEAD"
    echo "title CentOS 6 ($KVER)"
    echo "        root (hd0,0)"
    # rd_NO_LVM and friends stop dracut waiting on LVM, MD and LUKS that a
    # converted container has never had.
    echo "        kernel /boot/vmlinuz-$KVER ro root=LABEL=$LABEL $CONSOLE_ARGS rd_NO_LUKS rd_NO_LVM rd_NO_MD rd_NO_DM"
    echo "        initrd /boot/initramfs-$KVER.img"
  } > /boot/grub/grub.conf

  # Both names are load-bearing: grub itself reads menu.lst, and anaconda,
  # grubby and every EL6 how-to reach for /etc/grub.conf.
  [ -e /boot/grub/menu.lst ] || ln -sf ./grub.conf /boot/grub/menu.lst
  [ -e /etc/grub.conf ]      || ln -sf ../boot/grub/grub.conf /etc/grub.conf

  log "grub: writing the MBR to $DISK"
  # The batch form with --device-map=/dev/null, not grub-install: grub-install
  # guesses BIOS drive numbers from the host's disks and fails with "does not
  # have any corresponding BIOS drive" in a chroot. Naming the device removes
  # the guess.
  gout=$(grub --batch --device-map=/dev/null <<EOF 2>&1
device (hd0) $DISK
root (hd0,0)
setup (hd0)
quit
EOF
)
  printf '%s\n' "$gout" | grep -q 'succeeded' \
    || { printf '%s\n' "$gout"; die "grub setup did not report success - the VM will not boot"; }

else
  # -------------------------------------------------------------------------
  # grub2. Different file, different language, different installer, and a
  # config the guest's own grubby will keep editing for the rest of its life.
  # -------------------------------------------------------------------------
  mkdir -p /boot/grub2

  SERIAL_HEAD=""
  GRUB_TERM="console"
  if [ "$SERIAL" = "1" ]; then
    # grub2 splits what grub 0.97 called `terminal` into input and output, and
    # naming console first on both keeps noVNC working if the serial port is
    # not attached.
    SERIAL_HEAD=$'serial --unit=0 --speed=115200 --word=8 --parity=no --stop=1\nterminal_input console serial\nterminal_output console serial'
    GRUB_TERM="console serial"
  fi

  # net.ifnames=0 biosdevname=0 is not cosmetic. Everything the container knows
  # about its own network is in an ifcfg-eth0, and EL7 renames the NIC to ens18
  # unless it is told not to - which applies that file to an interface that does
  # not exist and brings the VM up with no address. rd.lvm=0 and friends are the
  # EL7 spelling of rd_NO_LVM: stop dracut waiting on LVM, MD, DM and LUKS that
  # a converted container has never had.
  KARGS="$CONSOLE_ARGS net.ifnames=0 biosdevname=0 rd.lvm=0 rd.md=0 rd.dm=0 rd.luks=0"

  log "write /boot/grub2/grub.cfg"
  {
    echo "# generated by c2v-inside.sh - hand edits survive nothing but a re-run"
    echo "set default=0"
    echo "set timeout=5"
    [ -n "$SERIAL_HEAD" ] && printf '%s\n' "$SERIAL_HEAD"
    echo "menuentry 'CentOS Linux ($KVER)' {"
    # msdos1 is the first primary partition, the only one phase 1 creates, and
    # /boot sits on it rather than on a filesystem of its own, so the kernel
    # path keeps its /boot prefix. ext2 is grub2's name for the whole ext
    # family, ext4 included - there is no insmod ext4.
    echo "        insmod part_msdos"
    echo "        insmod ext2"
    echo "        set root='hd0,msdos1'"
    # linux16/initrd16, not linux/initrd: this is a BIOS guest, and the 16-bit
    # entry point is what EL7 generates for one.
    echo "        linux16 /boot/vmlinuz-$KVER root=LABEL=$LABEL ro $KARGS"
    echo "        initrd16 /boot/initramfs-$KVER.img"
    echo "}"
  } > /boot/grub2/grub.cfg

  # The next `yum update kernel` adds its entry with grubby, and grubby takes
  # the cmdline for it from here. An image without this file quietly loses
  # net.ifnames=0 on the first kernel update and comes up unreachable months
  # later, with nothing left to connect that to this conversion.
  log "write /etc/default/grub"
  mkdir -p /etc/default
  cat > /etc/default/grub <<'EOF'
# generated by c2v-inside.sh
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR="$(sed 's, release .*$,,g' /etc/system-release)"
GRUB_DEFAULT=saved
GRUB_DISABLE_SUBMENU=true
GRUB_DISABLE_RECOVERY=true
EOF
  {
    echo "GRUB_TERMINAL_OUTPUT=\"$GRUB_TERM\""
    [ "$SERIAL" = "1" ] && echo 'GRUB_SERIAL_COMMAND="serial --unit=0 --speed=115200 --word=8 --parity=no --stop=1"'
    echo "GRUB_CMDLINE_LINUX=\"$KARGS\""
  } >> /etc/default/grub

  # grubby and every EL7 how-to reach for /etc/grub2.cfg.
  [ -e /etc/grub2.cfg ] || ln -sf ../boot/grub2/grub.cfg /etc/grub2.cfg

  # grub2-install asks grub2-probe what device is behind /boot, and grub2-probe
  # reads /proc/mounts. The kernel rewrites those paths relative to the reading
  # process's root, so inside a proper rescue chroot the root filesystem really
  # does show up as "/" and this is true. It is false when /proc was never
  # bind-mounted in, and then grub2-probe answers with the rescue image's own
  # root device instead. Cheaper to say so here than to read the error.
  grep -q "^$ROOTPART / " /proc/mounts 2>/dev/null \
    || log "WARN: /proc/mounts does not show $ROOTPART on / - if the next step fails, leave the chroot and run: for d in dev proc sys; do mount --bind /\$d /mnt/sysimage/\$d; done"

  log "grub2-install: writing the MBR to $DISK"
  # --target=i386-pc is BIOS, which is what phase 1 builds: an MBR disk with no
  # EFI system partition. Left to itself grub2-install picks a target from the
  # platform it is running on, and an EFI target has nowhere to go on this disk.
  # --boot-directory=/boot rather than the default, because /boot is not a
  # separate filesystem here and we are already inside the chroot.
  gout=$(grub2-install --target=i386-pc --boot-directory=/boot --recheck "$DISK" 2>&1) \
    || { printf '%s\n' "$gout"; die "grub2-install failed - the VM will not boot"; }
  printf '%s\n' "$gout"
fi

# The bootloader lives outside the filesystem, so nothing above proves it landed.
dd if="$DISK" bs=512 count=1 2>/dev/null | grep -aq GRUB \
  || die "no GRUB signature in the first sector of $DISK"
log "MBR verified"

# ---------------------------------------------------------------------------
# 7. undo the container-isms
# ---------------------------------------------------------------------------
# LXC gave this rootfs a MAC that the VM will not have. udev remembers it and
# names the new NIC eth1, so the ifcfg-eth0 the operator is counting on is
# applied to an interface that does not exist and the VM comes up unreachable.
RULES=/etc/udev/rules.d/70-persistent-net.rules
if [ -s "$RULES" ]; then
  log "clearing $RULES (it still names the container's MAC)"
  : > "$RULES"
fi

# NM_CONTROLLED=no hands the interface to the initscripts network service, and
# on EL6 that service is always there. On EL7 it is a package that a container
# image is entitled not to have, and writing this line into a guest where
# NetworkManager is the only thing that reads ifcfg files takes the interface
# away from the only process that could have configured it. Decided once, here:
# it is a fact about the guest, not about any one interface.
CLAIM_INITSCRIPTS=1
if [ "$EL" = 7 ] && [ ! -f /usr/lib/systemd/system/network.service ]; then
  CLAIM_INITSCRIPTS=0
fi

# Every ifcfg-eth*, not only eth0. A CT with two veths ships ifcfg-eth0 and
# ifcfg-eth1 and both carry a container MAC. Cleaning only the first leaves the
# second interface silently down in a VM that answers on one address and not the
# other, which reads as a routing problem and is not one.
NETDIR=/etc/sysconfig/network-scripts
IFCFG_LIST=""
for f in "$NETDIR"/ifcfg-eth*; do
  [ -f "$f" ] || continue
  IFCFG_LIST="${IFCFG_LIST:+$IFCFG_LIST }$f"
  log "cleaning $f (drop HWADDR and UUID, keep the address)"
  sed -i -e '/^HWADDR=/d' -e '/^UUID=/d' "$f"
  if [ "$CLAIM_INITSCRIPTS" = 1 ]; then
    grep -q '^NM_CONTROLLED=' "$f" || echo 'NM_CONTROLLED=no' >> "$f"
  fi
done

if [ -z "$IFCFG_LIST" ]; then
  log "WARN: no $NETDIR/ifcfg-eth* - the guest has no interface config, write one before adding net0"
else
  [ "$CLAIM_INITSCRIPTS" = 1 ] \
    || log "initscripts is not installed - leaving NM_CONTROLLED alone so NetworkManager keeps these"
  # Said out loud because qm set takes one --netN per interface and the count is
  # not visible from the host once the CT is gone. An interface with no card
  # behind it takes down every daemon that binds its address, with errno 99.
  case "$IFCFG_LIST" in
    *' '*) log "NOTE: more than one interface here - the VM needs a --netN for each: $IFCFG_LIST" ;;
  esac
fi
IFCFG_SHOW="${IFCFG_LIST:-$NETDIR/ifcfg-eth0}"

# An ifcfg file is read by exactly two things: the initscripts network service,
# or NetworkManager. A container image is entitled to have neither, because the
# LXC host configured the interface from outside and nothing inside ever needed
# to. That stays invisible until this becomes a VM, gets net0, and comes up with
# no address - at go-live, with the old CT already stopped, which is the worst
# moment there is to discover it. EL6 is exempt: initscripts owns rc.sysinit
# there, so a booting EL6 system has it by definition.
if [ "$EL" = 7 ]; then
  net_pkg=""; net_on=""
  [ -f /usr/lib/systemd/system/network.service ] && net_pkg="network"
  [ -f /usr/lib/systemd/system/NetworkManager.service ] && net_pkg="${net_pkg:+$net_pkg }NetworkManager"
  for u in network NetworkManager; do
    [ -e "/etc/systemd/system/multi-user.target.wants/$u.service" ] && net_on="${net_on:+$net_on }$u"
  done
  if [ -z "$net_pkg" ]; then
    log "WARN: neither initscripts nor NetworkManager is installed here, so nothing"
    log "WARN: in this guest reads $IFCFG_SHOW - every interface comes up with no address."
    log "WARN: fix it now, while the DVD is still mounted at $SRCDIR:"
    log "WARN:   printf '[c2v]\\nname=c2v\\nbaseurl=file://$SRCDIR\\nenabled=1\\ngpgcheck=0\\n' > $REPOFILE"
    log "WARN:   yum --disablerepo='*' --enablerepo=c2v install -y initscripts && rm -f $REPOFILE"
    log "WARN:   ln -sf /usr/lib/systemd/system/network.service \\"
    log "WARN:      /etc/systemd/system/multi-user.target.wants/network.service"
  elif [ -z "$net_on" ]; then
    # Installed but not enabled is the same outcome with a different cause, and
    # systemctl cannot be trusted in a chroot, so this links the unit by hand.
    log "WARN: $net_pkg is installed but not enabled, so no interface gets an address."
    log "WARN: enable one of them now:"
    log "WARN:   ln -sf /usr/lib/systemd/system/NetworkManager.service \\"
    log "WARN:      /etc/systemd/system/multi-user.target.wants/NetworkManager.service"
  else
    log "network at boot: $net_on (reads $IFCFG_SHOW)"
  fi
fi

if [ "$SERIAL" = "1" ]; then
  # Without this, root cannot log in on the serial port at all: `qm terminal`
  # shows the boot log and then a login that rejects the only account there is.
  grep -qx 'ttyS0' /etc/securetty 2>/dev/null || echo 'ttyS0' >> /etc/securetty

  if [ "$EL" = 6 ] && [ ! -f /etc/init/ttyS0.conf ]; then
    log "adding an upstart getty on ttyS0"
    cat > /etc/init/ttyS0.conf <<'EOF'
# getty on the virtual serial port, added by c2v-inside.sh
start on stopped rc RUNLEVEL=[2345]
stop on runlevel [S016]
respawn
exec /sbin/agetty -h -L ttyS0 115200 vt102
EOF
  fi
  # EL7 needs no unit file at all: systemd-getty-generator reads console= off
  # the kernel command line and starts serial-getty@ttyS0 by itself, and we put
  # console=ttyS0 there in step 6.
fi

if [ "$EL" = 7 ]; then
  # The other console. A container never had a VGA text console, so nothing ever
  # enabled getty@tty1, and the installer that normally would has never run on
  # this image. Without it noVNC shows the boot messages and then a blank screen
  # forever - which looks exactly like a hung boot, and is the first thing the
  # operator sees.
  if [ ! -e /etc/systemd/system/getty.target.wants/getty@tty1.service ]; then
    log "enabling getty@tty1 (noVNC has nothing to show without it)"
    mkdir -p /etc/systemd/system/getty.target.wants
    ln -sf /usr/lib/systemd/system/getty@.service \
           /etc/systemd/system/getty.target.wants/getty@tty1.service
  fi

  # Phase 1 replaced the container's /etc/mtab symlink with a real empty file,
  # because the symlink is absolute and it crashes anaconda's rescue mode before
  # this script can run. EL6 wants that file - rc.sysinit clears and rebuilds it
  # every boot. EL7 wants the symlink back: systemd never writes /etc/mtab, so a
  # real file there is frozen at whatever phase 1 left in it, which is nothing,
  # and df and mount would report a machine with no filesystems mounted.
  # Restoring it does not re-arm the crash either - /etc/mtab is a symlink on
  # every stock EL7 system, and EL7 rescue mode is used on those every day.
  if [ ! -L /etc/mtab ]; then
    log "restore /etc/mtab -> /proc/self/mounts (EL7 has no rc.sysinit to rebuild it)"
    rm -f /etc/mtab
    ln -sf /proc/self/mounts /etc/mtab
  fi
fi

# Everything yum wrote into /boot was created with SELinux disabled, because the
# rescue environment has it disabled. On an enforcing guest those unlabelled
# files stop the boot. One relabel pass on the first boot fixes it permanently.
if [ "$RELABEL" = "1" ] && [ -f /etc/selinux/config ] \
   && ! grep -q '^SELINUX=disabled' /etc/selinux/config; then
  log "SELinux is not disabled - touching /.autorelabel (first boot will be slow, once)"
  touch /.autorelabel
fi

sync

if [ "$EL" = 6 ]; then BOOTCFG=/boot/grub/grub.conf; else BOOTCFG=/boot/grub2/grub.cfg; fi

cat <<EOF

$(date '+%F %T')  === phase 2 done ===

  guest       $REL
  kernel      $KVER
  initramfs   /boot/initramfs-$KVER.img
  bootloader  MBR on $DISK, $BOOTCFG
  root        LABEL=$LABEL

  Leave the chroot and shut the rescue system down:

    exit
    exit

  Then on the PVE node, detach the ISO and boot the disk:

    qm stop <vmid>
    qm set <vmid> --delete ide2
    qm set <vmid> --boot order=virtio0
    qm start <vmid>
    qm terminal <vmid>

  It boots with NO network, on purpose. Only after you have seen it come up,
  and only when the old container is stopped:

    qm set <vmid> --net0 virtio,bridge=vmbr0
    qm reboot <vmid>

EOF
