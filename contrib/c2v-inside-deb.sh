#!/usr/bin/env bash
# =============================================================================
#  c2v-inside-deb.sh — make a synced Debian or Ubuntu rootfs bootable.
#                      Phase 2 of 2, for the Debian family only.
# -----------------------------------------------------------------------------
#  Runs on the PVE node, NOT inside the guest. After phase 1:
#
#      ./tools/c2v-inside-deb.sh --vmid 9140 --storage nfs-vm
#
#  That is the whole of it. There is no ISO to attach, no rescue environment to
#  boot, and nothing to type into a console that cannot paste.
#
#  options:
#    --vmid ID        the VM phase 1 built                          (required)
#    --storage NAME   storage holding its disk                      (required)
#    --kernel PKG     kernel package to install       (default: from the guest)
#    --label NAME     expected ext4 label, checked not written  (default: any)
#    --no-serial      skip the ttyS0 getty and serial console
#    --dry-run        print what would happen, do nothing
#    -h, --help       this text
#
# -----------------------------------------------------------------------------
#  WHY THIS RUNS ON THE HOST AND ITS EL SIBLING DOES NOT
#
#  c2v-inside.sh runs inside the guest, in the rescue environment of an install
#  DVD, for two reasons. EL6's rpm, dracut and grub are glibc 2.12 binaries that
#  segfault at ffffffffff600400 the moment they are chrooted into from a host
#  booted with vsyscall=none. And EL7, which clears that bar, still cannot be
#  built from here because this host has no rpm and no yum, and its grub2 is
#  Debian's - it writes core.img for /boot/grub with Debian's module set while
#  the guest expects /boot/grub2 and its own.
#
#  Neither survives contact with a Debian or Ubuntu guest. Ubuntu 20.04 is glibc
#  2.31 and runs perfectly well on a modern kernel. And a PVE node IS Debian, so
#  its apt, dpkg, grub-pc and initramfs-tools are not a foreign set - they are
#  the guest's own tools. The packages still come from the guest's own sources
#  inside the chroot, so an Ubuntu guest gets Ubuntu's kernel and Debian's host
#  contributes nothing but the kernel it is running under.
#
#  So this is a plain chroot. Which makes it faster, scriptable, re-runnable,
#  and free of the one thing that cost the most time on the EL side: everything
#  below is typed on a host shell that can paste.
#
#  WHAT A CONTAINER ROOTFS IS MISSING — THE SAME EXACTLY THREE THINGS
#
#  A kernel, because a container borrows the host's. A bootloader, because a
#  container is never booted. And an initramfs that knows virtio, because
#  nothing else can find the root disk. Everything after step 6 is cleanup of
#  assumptions a container was allowed to get away with and a VM is not.
#
#  THE ONE THING THIS MUST NOT GET WRONG
#
#  update-grub inside the chroot resolves the root device through grub-probe,
#  which sees a loop partition. That is correct - it reads the filesystem UUID
#  off it, and the UUID travels with the disk. It is also one bad mount away
#  from writing root=/dev/loop0p1 into grub.cfg, which produces a VM that stops
#  in an initramfs shell with no clue why. Step 9 reads the generated grub.cfg
#  back and refuses to finish if it does not name the UUID blkid reports.
#
#  IDEMPOTENCE
#
#  Every step checks for its own result first, so a re-run after a failure
#  resumes instead of starting over, and a re-run on a finished image is a no-op
#  plus a fresh initramfs, grub.cfg and MBR. Phase 1 may be re-run before it as
#  often as needed; it will have taken /etc back to the container's copy, which
#  is exactly what running this again puts right.
# =============================================================================
set -uo pipefail

# Printed in the banner so a VM built by an old copy of this script can be told
# apart from one built by this copy, which is otherwise invisible once the disk
# is detached. Bump it whenever the behaviour here changes.
C2V_VERSION="2026-08-04b"

SELF=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

VMID=""; STORAGE=""; KPKG=""; LABEL=""; SERIAL=1; DRYRUN=0

LOOP=""; MNT=""; MOUNTS=""; RESOLV_SAVED=0

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

# A chroot that is still holding /dev, /sys or a loop device is not a tidiness
# problem. losetup -d on a busy device fails silently enough that the next run
# attaches a second loop to the same file, and two loops on one image is how a
# filesystem gets corrupted by a script that never wrote to it on purpose.
cleanup(){
  rc=$?
  if (( RESOLV_SAVED )) && [[ -n "$MNT" ]]; then
    rm -f "$MNT/etc/resolv.conf"
    [[ -e "$MNT/etc/resolv.conf.c2v" ]] && mv "$MNT/etc/resolv.conf.c2v" "$MNT/etc/resolv.conf"
  fi
  # Newest first: /run and /dev/pts sit under mounts made before them, and a
  # busy mountpoint here is the difference between a clean umount and an ext4
  # that has to be fsck'd before the VM will start.
  for m in $MOUNTS; do umount -l "$m" 2>/dev/null; done
  if [[ -n "$MNT" ]] && mountpoint -q "$MNT" 2>/dev/null; then
    sync; umount "$MNT" 2>/dev/null || umount -l "$MNT" 2>/dev/null
  fi
  [[ -n "$LOOP" ]] && losetup -d "$LOOP" 2>/dev/null
  exit $rc
}
trap cleanup EXIT INT TERM

while [ $# -gt 0 ]; do
  case "$1" in
    --vmid)      VMID="${2:-}";    shift 2;;
    --storage)   STORAGE="${2:-}"; shift 2;;
    --kernel)    KPKG="${2:-}";    shift 2;;
    --label)     LABEL="${2:-}";   shift 2;;
    --no-serial) SERIAL=0; shift;;
    --dry-run)   DRYRUN=1; shift;;
    -h|--help)   sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 0;;
    *) die "unknown option: $1 (try --help)";;
  esac
done

# Rule 5 in CLAUDE.md applies here for the same reason it applies to phase 1: a
# guessed vmid writes a bootloader into somebody else's disk, and a guessed
# storage looks for the image in the wrong place and reports it missing on a
# machine that is perfectly healthy.
for v in VMID STORAGE; do
  [[ -n "${!v}" ]] || die "--$(printf '%s' "${v,,}" | tr _ -) is required and has no default (try --help)"
done
[[ "$VMID" =~ ^[0-9]+$ ]] || die "--vmid must be numeric"

# ---------------------------------------------------------------------------
# 0. preflight
# ---------------------------------------------------------------------------
hr
set_log "$SELF/../logs/c2v-phase2-deb-$VMID-$(date +%F).log"
log "=== c2v phase 2, Debian family [$C2V_VERSION]: VM $VMID on $STORAGE ==="

[[ "$(id -u)" = "0" ]] || die "run this as root"

for c in qm pvesm losetup blkid chroot mountpoint; do
  command -v "$c" >/dev/null || die "missing command: $c"
done

# The disk must not be attached to anything that could write to it. A running VM
# has the image open through qemu, and mounting it here would give the kernel a
# second, unsynchronised view of a filesystem qemu is caching - which is not a
# race that ends in an error message, it ends in a corrupt ext4.
vmstate=$(qm status "$VMID" 2>/dev/null | awk '{print $2}')
[[ -n "$vmstate" ]] || die "VM $VMID does not exist on this node - run phase 1 first"
[[ "$vmstate" = "stopped" ]] \
  || die "VM $VMID is '$vmstate' - stop it first: qm stop $VMID"

VOLID="$STORAGE:$VMID/vm-$VMID-disk-0.raw"
IMG=$(pvesm path "$VOLID" 2>/dev/null || true)
[[ -n "$IMG" && -e "$IMG" ]] || die "cannot find the disk for VM $VMID ($VOLID) - check --storage"
# Same restriction as phase 1, and the same reason: an LVM or ZFS volume is a
# block device whose partitions need kpartx rather than losetup -P. Refusing is
# better than half-supporting it.
[[ -f "$IMG" ]] || die "$IMG is not a regular file - this needs a dir/NFS storage; move the disk afterwards with 'qm move-disk'"

log "disk $IMG"

# ---------------------------------------------------------------------------
# 1. open the image
# ---------------------------------------------------------------------------
if (( DRYRUN )); then
  log "DRY: losetup -P $IMG, mount p1, chroot, install kernel + grub, unmount"
  log "DRY: nothing was changed"
  exit 0
fi

LOOP=$(losetup -P -f --show "$IMG") || die "losetup failed on $IMG"
PART="${LOOP}p1"
[[ -b "$PART" ]] || die "$PART did not appear - is there a partition table on this image? Run phase 1 first"

FSUUID=$(blkid -s UUID -o value "$PART" 2>/dev/null || true)
[[ -n "$FSUUID" ]] || die "no filesystem UUID on $PART - phase 1 has not made a filesystem here"
FSLABEL=$(blkid -s LABEL -o value "$PART" 2>/dev/null || true)

# Checked, never written. Phase 1 owns the label; all this can do is catch an
# operator who is about to convert the wrong disk, and the message has to say
# what it actually found so they can see which one they hit.
if [[ -n "$LABEL" && -n "$FSLABEL" && "$LABEL" != "$FSLABEL" ]]; then
  die "--label says '$LABEL' but this filesystem is labelled '$FSLABEL' - wrong disk?"
fi

MNT="/var/lib/c2v/$VMID"
mkdir -p "$MNT" || die "cannot create $MNT"
mount "$PART" "$MNT" || die "mount $PART failed - the filesystem may need e2fsck -f $PART"
log "mounted $PART at $MNT (UUID=$FSUUID${FSLABEL:+, LABEL=$FSLABEL})"

# ---------------------------------------------------------------------------
# 2. is this really a Debian-family rootfs?
# ---------------------------------------------------------------------------
# Everything below runs apt against whatever is on this disk. If phase 1's family
# probe was overridden with the wrong --family, or the operator typed a vmid that
# belongs to a different conversion, this is the last moment anything can tell.
[[ -f "$MNT/etc/debian_version" ]] || [[ -f "$MNT/etc/os-release" ]] \
  || die "$MNT has no /etc/debian_version and no /etc/os-release - this is not a Debian-family rootfs"

GUEST_ID=$(sed -n 's/^ID=//p' "$MNT/etc/os-release" 2>/dev/null | head -1 | tr -d "\"'" | tr '[:upper:]' '[:lower:]')
GUEST_REL=$(sed -n 's/^PRETTY_NAME=//p' "$MNT/etc/os-release" 2>/dev/null | head -1 | tr -d '"')
[[ -n "$GUEST_REL" ]] || GUEST_REL="Debian $(head -1 "$MNT/etc/debian_version" 2>/dev/null || echo unknown)"
case "$GUEST_ID" in
  ubuntu|debian|devuan|raspbian|"") ;;
  *) die "this rootfs says ID=$GUEST_ID, which is not in the Debian family - use tools/c2v-inside.sh instead";;
esac
log "guest: $GUEST_REL"

[[ -x "$MNT/usr/bin/apt-get" || -x "$MNT/usr/bin/apt" ]] \
  || die "no apt-get in this rootfs - nothing here can install a kernel into it"

# The kernel package is the one name that is genuinely per-distribution, because
# Ubuntu's meta-package is not in Debian's archive and vice versa. Guessing wrong
# fails loudly at apt-get, but it fails after the chroot is up and the mounts are
# made, so it is decided here where the answer can be explained.
if [[ -z "$KPKG" ]]; then
  case "$GUEST_ID" in
    ubuntu) KPKG="linux-image-generic";;
    *)      KPKG="linux-image-amd64";;
  esac
  log "kernel package: $KPKG (default for ID=${GUEST_ID:-debian})"
else
  log "kernel package: $KPKG (forced by --kernel)"
fi

# ---------------------------------------------------------------------------
# 3. the chroot's own kernel interfaces
# ---------------------------------------------------------------------------
# /run is a fresh tmpfs, NEVER a bind of this host's /run. Bind it and every
# systemctl below talks to THIS NODE's systemd through its socket in
# /run/systemd/private - which is to say, a script meant to enable a getty in a
# guest would be enabling and disabling units on the hypervisor. The tmpfs also
# gives dpkg's postinst scripts somewhere to write, which several of them assume.
mnt_bind(){ # mnt_bind <src> <dst-relative> [rbind]
  local src="$1" dst="$MNT/$2"
  mkdir -p "$dst"
  if [[ "${3:-}" = rbind ]]; then
    mount --rbind "$src" "$dst" || die "mount --rbind $src -> $dst failed"
    # Without rslave, an unmount inside the chroot propagates back out to the
    # host's own /dev or /sys. umount -l on the way out would then take the
    # node's devtmpfs with it.
    mount --make-rslave "$dst"
  else
    mount --bind "$src" "$dst" || die "mount --bind $src -> $dst failed"
  fi
  MOUNTS="$dst${MOUNTS:+ $MOUNTS}"
}

mkdir -p "$MNT"/{proc,sys,dev,run,boot,tmp}
chmod 1777 "$MNT/tmp"

mount -t proc proc "$MNT/proc" || die "mount proc failed"
MOUNTS="$MNT/proc"
mnt_bind /dev dev rbind
mnt_bind /sys sys rbind
mount -t tmpfs tmpfs "$MNT/run" || die "mount tmpfs on $MNT/run failed"
MOUNTS="$MNT/run${MOUNTS:+ $MOUNTS}"
log "chroot mounts ready (/run is a fresh tmpfs, not this node's)"

# ---------------------------------------------------------------------------
# 4. name resolution inside the chroot
# ---------------------------------------------------------------------------
# On Ubuntu 20.04 /etc/resolv.conf is usually a symlink into /run/systemd/resolve,
# and /run was just replaced with an empty tmpfs, so it now dangles - apt would
# fail on every hostname with no hint as to why. Moved aside rather than deleted,
# and put back by cleanup(), because that symlink is what the guest wants once it
# is a VM running systemd-resolved of its own.
if [[ -e "$MNT/etc/resolv.conf" || -L "$MNT/etc/resolv.conf" ]]; then
  mv "$MNT/etc/resolv.conf" "$MNT/etc/resolv.conf.c2v" || die "cannot move the guest's resolv.conf aside"
fi
RESOLV_SAVED=1
if [[ -r /etc/resolv.conf ]]; then
  # Copied rather than bind-mounted: a bind here would be one more mount to fail
  # to release, and this file is three lines.
  grep -E '^(nameserver|search|domain|options)' /etc/resolv.conf > "$MNT/etc/resolv.conf" 2>/dev/null
fi
[[ -s "$MNT/etc/resolv.conf" ]] || printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > "$MNT/etc/resolv.conf"

inchroot(){ chroot "$MNT" /usr/bin/env -i \
  PATH=/usr/sbin:/usr/bin:/sbin:/bin \
  HOME=/root TERM="${TERM:-linux}" \
  DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true \
  LC_ALL=C LANG=C \
  SYSTEMD_OFFLINE=1 \
  /bin/sh -c "$1"; }

# ---------------------------------------------------------------------------
# 5. install the three missing things
# ---------------------------------------------------------------------------
# grub-pc asks which disks to install to, and in a chroot with no terminal that
# question either hangs or is answered wrongly with the HOST's disk - which
# would overwrite the boot sector of the node this is running on. Preseeding it
# empty is what makes step 8's explicit grub-install the only writer of an MBR
# in this script, on a device this script chose.
log "preseed grub-pc: install to nothing (step 8 does it explicitly, on the loop device)"
inchroot 'command -v debconf-set-selections >/dev/null || exit 0
printf "grub-pc grub-pc/install_devices multiselect \ngrub-pc grub-pc/install_devices_empty boolean true\n" | debconf-set-selections' \
  || log "WARN: debconf-set-selections failed - grub-pc may ask about install devices"

# --no-install-recommends is load-bearing rather than tidy: grub-pc Recommends
# os-prober, and os-prober run inside a chroot on a hypervisor scans every block
# device it can see and offers to add the NODE's other guests to this guest's
# boot menu. Not installing it is more reliable than turning it off, and step 7
# turns it off as well.
log "apt-get update"
inchroot 'apt-get update' || log "WARN: apt-get update reported an error - continuing, the install below will say if it matters"

log "apt-get install $KPKG grub-pc initramfs-tools"
inchroot "apt-get install -y --no-install-recommends $KPKG grub-pc grub2-common initramfs-tools" \
  || die "apt-get install failed - check the guest's sources.list inside $MNT/etc/apt, then run this again"

# apt exits 0 when a package is merely already configured, so the exit status is
# not proof that a kernel landed. The files are.
ls "$MNT"/boot/vmlinuz-* >/dev/null 2>&1 \
  || die "apt reported success but there is no kernel in $MNT/boot - look at $MNT/etc/apt/sources.list"
[[ -x "$MNT/usr/sbin/grub-install" ]] \
  || die "apt reported success but grub-install is not in the image"

# Same check for the other half. Phase 1 excludes update-initramfs for the same
# reason it excludes grub: the container's copy would be run against a kernel
# the container never had. It comes back only if apt actually unpacked
# initramfs-tools just now, and apt exits 0 without unpacking anything when the
# container already has the version the archive is offering.
[[ -x "$MNT/usr/sbin/update-initramfs" || -x "$MNT/sbin/update-initramfs" ]] \
  || die "apt reported success but update-initramfs is not in the image - run: chroot $MNT apt-get install -y --reinstall initramfs-tools"

KVER=$(cd "$MNT/boot" && ls -1 vmlinuz-* 2>/dev/null | sed 's/^vmlinuz-//' | sort -V | tail -1)
log "kernel $KVER"

# ---------------------------------------------------------------------------
# 6. teach the initramfs about virtio
# ---------------------------------------------------------------------------
# initramfs-tools' MODULES=most does normally pull these in, but "normally" is
# doing a lot of work in a guest whose /etc came from a container: an inherited
# initramfs.conf with MODULES=dep would build an initramfs from the modules THIS
# rootfs was using at build time, and a container was using none. Naming them
# explicitly costs a few hundred kilobytes and removes the failure mode entirely.
# Without virtio_blk there is no root disk and the boot stops in the initramfs
# shell; without virtio_net the VM comes up with no interface at all.
IMODS="$MNT/etc/initramfs-tools/modules"
mkdir -p "$(dirname "$IMODS")"
touch "$IMODS"
for m in virtio_pci virtio_blk virtio_scsi virtio_net virtio_console virtio_balloon; do
  grep -qx "$m" "$IMODS" || printf '%s\n' "$m" >> "$IMODS"
done
log "virtio modules named in /etc/initramfs-tools/modules"

# The initramfs needs one thing that is not a module, and getting it is not
# automatic here. Debian's and Ubuntu's init turns root=UUID= into a device by
# shelling out to blkid - resolve_device() and get_fstype() in
# /usr/share/initramfs-tools/scripts/functions both do - and blkid is put into
# the image by a hook that the UDEV package ships, not initramfs-tools. Phase 1
# excludes /usr/share/initramfs-tools wholesale, so that hook never arrives, and
# the apt run above cannot put it back: the rsync brought the container's dpkg
# database with it, so apt already believes udev is installed and never unpacks
# it. mkinitramfs then builds a valid-looking initramfs with no blkid in it and
# exits 0, and the VM stops at
#   ALERT!  UUID=... does not exist.  Dropping to a shell!
# half an hour after this script said it had finished. Owning a hook of our own
# depends on none of that. It lives under /etc, which phase 1 also excludes, so
# a re-sync cannot take it away either.
#
# udev itself is deliberately not restored, and it is worth being precise about
# what that does and does not cost, because the first version of this comment was
# not and the next failure came out of the gap. Device naming and assembly are
# genuinely not needed: phase 1 always builds one plain ext4 partition on
# virtio-blk, never LVM and never RAID, so nothing in here has to assemble
# anything, and init's wait_for_udev is a no-op when udevadm is absent. What IS
# lost with the package's hooks is scripts/init-bottom/udev, which is what
# normally moves the populated /dev onto the new root before the handover.
# Section 11 covers that on the disk instead, with static nodes, which does not
# depend on any script running here. A hook that copies one binary is still a
# smaller thing to be wrong about than a half-installed udev.
IHOOK="$MNT/etc/initramfs-tools/hooks/c2v"
mkdir -p "$(dirname "$IHOOK")"
cat > "$IHOOK" <<'HOOK'
#!/bin/sh
# Written by c2v-inside-deb.sh. Copies the binaries this guest's init shells out
# to, which would otherwise come from hooks phase 1's rsync excludes.
PREREQ=""
prereqs(){ echo "$PREREQ"; }
case "$1" in
prereqs) prereqs; exit 0 ;;
esac
. /usr/share/initramfs-tools/hook-functions

# blkid is the load-bearing one: init's resolve_device() and get_fstype() both
# run it, and without it root=UUID= never becomes a device. Add copy_exec lines
# below it if a guest turns out to need more.
blkid=$(command -v blkid 2>/dev/null)
[ -n "$blkid" ] && copy_exec "$blkid"

exit 0
HOOK
chmod 0755 "$IHOOK"
log "initramfs hook /etc/initramfs-tools/hooks/c2v written (blkid)"

# ---------------------------------------------------------------------------
# 7. the boot configuration
# ---------------------------------------------------------------------------
# Written whole rather than edited, because what is on this disk came out of a
# container and half of it is about a machine that does not exist. A marker line
# says who wrote it so the next person does not have to guess, and so a re-run
# can see its own work.
#
# net.ifnames=0 biosdevname=0 is not cosmetic. Systemd renames the NIC by its
# PCI path, so the interface a container called eth0 comes up as ens18 in a VM,
# and every /etc/network/interfaces stanza and every netplan match in this image
# names eth0. Turning the renaming off is the only change that keeps the guest's
# own network config meaningful without editing files the operator wrote.
#
# Both consoles are named, and in this order: the last console= on the command
# line is the one that gets /dev/console, so ttyS0 last is what makes
# `qm terminal` show the boot. tty0 first keeps noVNC showing it too.
GRUBDEF="$MNT/etc/default/grub"
if [[ -f "$GRUBDEF" ]] && grep -q '^# written by c2v-inside-deb.sh' "$GRUBDEF"; then
  log "keep /etc/default/grub (this script wrote it)"
else
  log "write /etc/default/grub (net.ifnames=0, serial console, no os-prober)"
  [[ -f "$GRUBDEF" ]] && cp -a "$GRUBDEF" "$GRUBDEF.c2v-orig"
  mkdir -p "$(dirname "$GRUBDEF")"
  cat > "$GRUBDEF" <<'EOF'
# written by c2v-inside-deb.sh - CT to VM conversion, phase 2.
# The original, if there was one, is next to this file as grub.orig.
GRUB_DEFAULT=0
GRUB_TIMEOUT=5
GRUB_TIMEOUT_STYLE=menu
GRUB_DISTRIBUTOR=`lsb_release -i -s 2> /dev/null || echo Debian`
GRUB_CMDLINE_LINUX_DEFAULT=""
GRUB_CMDLINE_LINUX="net.ifnames=0 biosdevname=0 console=tty0 console=ttyS0,115200n8"
GRUB_TERMINAL="console serial"
GRUB_SERIAL_COMMAND="serial --unit=0 --speed=115200 --word=8 --parity=no --stop=1"
# os-prober inside a chroot on a hypervisor scans every block device on the NODE
# and puts the node's other guests in this guest's boot menu. Off, and the
# package is not installed either.
GRUB_DISABLE_OS_PROBER=true
# NOT GRUB_DISABLE_LINUX_UUID. grub-probe resolves / to the loop partition's
# filesystem UUID, and that UUID travels with the disk - it is right in the VM.
# A device name would not be.
EOF
fi

# ---------------------------------------------------------------------------
# 8. the bootloader
# ---------------------------------------------------------------------------
# --target=i386-pc because phase 1 makes an MBR, not GPT, and this is the BIOS
# target. --no-floppy stops grub from probing a floppy that is not there and
# waiting for it. The device is the whole loop, not the partition: the boot
# sector goes in front of the partition table.
log "grub-install --target=i386-pc $LOOP"
inchroot "grub-install --target=i386-pc --recheck --no-floppy --boot-directory=/boot $LOOP" \
  || die "grub-install failed - the disk has no bootloader, do NOT start this VM"

# device.map records that /dev/loop0 was called hd0, which stops being true the
# moment this image is a virtio disk. Nothing needs it - grub2 probes at run
# time - and a stale one is read in preference to probing.
rm -f "$MNT/boot/grub/device.map"

# The MBR is outside the filesystem, so this reads the image file directly and is
# the same check phase 1 uses to decide whether phase 2 has run.
dd if="$IMG" bs=512 count=1 2>/dev/null | grep -aq GRUB \
  || die "grub-install reported success but there is no GRUB signature in the MBR of $IMG"
log "MBR verified"

# ---------------------------------------------------------------------------
# 9. initramfs and the boot menu
# ---------------------------------------------------------------------------
log "update-initramfs -u -k all"
inchroot 'update-initramfs -u -k all' \
  || die "update-initramfs failed - the VM would stop in an initramfs shell"

# An exit status of 0 is not proof that the image can find the root filesystem.
# copy_exec warns about a binary it cannot find and carries on, and mkinitramfs
# still finishes successfully, so the whole failure is one warning in a page of
# output nobody reads. This is the read-back, and it checks the one thing that
# is fatal: without blkid, root=UUID= never resolves to a device and the boot
# ends in a rescue shell. Same reasoning as the grub.cfg check below - the
# expensive way to find this out is on the console, after the fact.
INITRD="/boot/initrd.img-$KVER"
[[ -s "$MNT$INITRD" ]] \
  || die "update-initramfs reported success but $MNT$INITRD is not there"
if ! inchroot 'command -v lsinitramfs >/dev/null 2>&1'; then
  log "WARN: lsinitramfs is not in the image - cannot verify what went into the initramfs"
elif inchroot "lsinitramfs $INITRD" 2>/dev/null | grep -q 'bin/blkid$'; then
  log "initramfs $KVER contains blkid"
else
  die "the initramfs for $KVER has no blkid in it, so it cannot resolve root=UUID=$FSUUID. Do NOT start this VM - check $MNT/etc/initramfs-tools/hooks/c2v and run this again"
fi

log "update-grub"
inchroot 'update-grub' || die "update-grub failed - there is no boot menu"

GRUBCFG="$MNT/boot/grub/grub.cfg"
[[ -s "$GRUBCFG" ]] || die "update-grub wrote no $GRUBCFG"

# The one thing this script must not get wrong. grub-probe was asked what / is
# while / was a loop partition, and the right answer is that partition's
# filesystem UUID, which travels with the disk. The wrong answer is the loop
# device's own name, which does not exist in a VM and produces a boot that stops
# in an initramfs shell with "ALERT! /dev/loop0p1 does not exist".
if grep -q "root=UUID=$FSUUID" "$GRUBCFG"; then
  log "grub.cfg boots root=UUID=$FSUUID"
elif [[ -n "$FSLABEL" ]] && grep -q "root=LABEL=$FSLABEL" "$GRUBCFG"; then
  log "grub.cfg boots root=LABEL=$FSLABEL"
else
  bad=$(grep -o 'root=[^ ]*' "$GRUBCFG" | sort -u | tr '\n' ' ')
  die "grub.cfg does not boot this filesystem. It says: ${bad:-nothing}. Expected root=UUID=$FSUUID. Do NOT start this VM - fix $MNT/etc/default/grub and run this again"
fi

# fstab is phase 1's, and it mounts / by LABEL. Checked rather than written,
# because the operator is the one who adds a data disk to it and this script has
# no business taking that away. A root line that does not match is not fatal on
# its own - grub.cfg above is what finds the disk - but it makes / read-only
# after the initramfs hands over, which looks exactly like a failing disk.
if [[ -n "$FSLABEL" ]] && ! grep -Eq "^[[:space:]]*(LABEL=${FSLABEL}|UUID=${FSUUID})[[:space:]]+/[[:space:]]" "$MNT/etc/fstab" 2>/dev/null; then
  log "WARN: $MNT/etc/fstab does not mount / from LABEL=$FSLABEL or UUID=$FSUUID."
  log "WARN: the VM will boot but / stays read-only. Check it before starting."
fi

# ---------------------------------------------------------------------------
# 10. undo the container-isms
# ---------------------------------------------------------------------------
# LXC gave this rootfs a MAC the VM will not have. udev remembers it and names
# the new NIC eth1, so the eth0 stanza the operator is counting on is applied to
# an interface that does not exist and the VM comes up unreachable.
RULES="$MNT/etc/udev/rules.d/70-persistent-net.rules"
if [[ -s "$RULES" ]]; then
  log "clearing /etc/udev/rules.d/70-persistent-net.rules (it still names the container's MAC)"
  : > "$RULES"
fi

# A container image is built with several units masked to /dev/null, because
# they are the ones that would fight the host: udev owns device nodes the
# container does not have, and the two mount units below are the container's
# /sys and /proc, which LXC provides from outside. In a VM every one of them is
# needed, and a masked systemd-udevd is a VM whose disks and NICs never get
# device nodes at all - it boots to a shell that cannot see /dev/vda1.
UNMASKED=""
for u in systemd-udevd.service systemd-udevd-control.socket systemd-udevd-kernel.socket \
         udev.service systemd-udev-trigger.service \
         sys-kernel-debug.mount sys-kernel-config.mount proc-sys-fs-binfmt_misc.mount \
         systemd-journald-audit.socket; do
  f="$MNT/etc/systemd/system/$u"
  if [[ -L "$f" && "$(readlink "$f")" = /dev/null ]]; then
    rm -f "$f"
    UNMASKED="${UNMASKED:+$UNMASKED }$u"
  fi
done
[[ -n "$UNMASKED" ]] && log "unmasked (a container masks these, a VM needs them): $UNMASKED"

# Anything else masked to /dev/null is reported rather than removed: the list
# above is what LXC's own templates mask, and past that point a mask is
# somebody's decision rather than an artefact of the container.
OTHERMASK=""
if [[ -d "$MNT/etc/systemd/system" ]]; then
  while IFS= read -r f; do
    [[ "$(readlink "$f")" = /dev/null ]] || continue
    OTHERMASK="${OTHERMASK:+$OTHERMASK }$(basename "$f")"
  done < <(find "$MNT/etc/systemd/system" -maxdepth 1 -type l 2>/dev/null)
fi
[[ -n "$OTHERMASK" ]] && log "NOTE: still masked, left alone on purpose: $OTHERMASK"

if (( SERIAL )); then
  # Without this, root cannot log in on the serial port at all: `qm terminal`
  # shows the whole boot and then a login that rejects the only account there is.
  if [[ -f "$MNT/etc/securetty" ]] && ! grep -qx 'ttyS0' "$MNT/etc/securetty"; then
    log "adding ttyS0 to /etc/securetty"
    printf 'ttyS0\n' >> "$MNT/etc/securetty"
  fi
  # systemd-getty-generator does read console= off the command line and start
  # serial-getty@ttyS0 by itself - but only when /dev/ttyS0 is the system
  # console, and only from the generator, which leaves nothing on disk to check.
  # Enabling it explicitly makes it visible in the image and survives a change to
  # the command line.
  log "enable serial-getty@ttyS0 and getty@tty1"
  inchroot 'systemctl enable serial-getty@ttyS0.service getty@tty1.service >/dev/null 2>&1' \
    || log "WARN: systemctl enable failed in the chroot - the generator should still start a getty"
fi

# A container never had a VGA text console, so nothing ever enabled getty@tty1
# and noVNC would show the boot messages and then a blank screen forever - which
# looks exactly like a hung boot, and is the first thing the operator sees. The
# systemctl above covers it; this is the check that it actually landed, because
# systemctl in a chroot is the step most likely to have quietly done nothing.
[[ -e "$MNT/etc/systemd/system/getty.target.wants/getty@tty1.service" ]] || {
  log "linking getty@tty1 by hand (systemctl did not, and noVNC has nothing to show without it)"
  mkdir -p "$MNT/etc/systemd/system/getty.target.wants"
  ln -sf /lib/systemd/system/getty@.service \
         "$MNT/etc/systemd/system/getty.target.wants/getty@tty1.service"
}

sync

# ---------------------------------------------------------------------------
# 11. the device nodes the handover needs
# ---------------------------------------------------------------------------
# The chroot's mounts come off first, and that ordering is the entire reason
# this is a section of its own rather than three lines inside section 10.
# Everything above ran with $MNT/dev as an rbind of THIS NODE's /dev, so an
# mknod up there would have created the node in the hypervisor's devtmpfs and
# left the guest's disk exactly as empty as it was.
for m in $MOUNTS; do umount -l "$m" 2>/dev/null; done
MOUNTS=""

# And if that lazy umount did not take, everything below writes into this node's
# /dev. It costs one syscall to be sure, and being wrong about it is not
# something the operator would ever see.
! mountpoint -q "$MNT/dev" 2>/dev/null \
  || die "$MNT/dev is still a mountpoint after umount - refusing to mknod into this node's own /dev"

# What this is for, and it cost a second live VM: the initramfs does its whole
# job - finds the disk, fscks it, mounts it - and the kernel panics anyway.
#
#   /init: line 373: can't open /root/dev/console: no such file
#   Kernel panic - not syncing: Attempted to kill init! exitcode=0x00000100
#
# The last line of Ubuntu's /init is
#
#   exec run-init $rootmnt $init "$@" <${rootmnt}/dev/console >${rootmnt}/dev/console 2>&1
#
# and the shell opens those redirections BEFORE it execs anything. With no
# /root/dev/console the redirection fails, dash exits 1, and dash is pid 1 - so
# the kernel reports exitcode 0x100, which is 1 << 8, with Comm: sh. Nothing is
# wrong with the root filesystem at that point; the lines above the panic show
# it fscked clean and mounted.
#
# Two separate things normally stop anyone from ever having to know this. A real
# Debian install has /dev/console and /dev/null on disk because debootstrap puts
# them there. And even without them, udev's own
# /usr/share/initramfs-tools/scripts/init-bottom/udev runs
# `mount -n -o move /dev ${rootmnt}/dev` and hands over a populated devtmpfs.
# This image has neither. An LXC container's on-disk /dev is empty because the
# runtime mounts a tmpfs over it, so the rsync had nothing to copy there even
# before --exclude=/dev/*; and init-bottom/udev is the same casualty of phase 1's
# --exclude=/usr/share/initramfs-tools as the blkid hook in section 6.
#
# Of the two ways to fix it, making the nodes on the disk is the smaller claim.
# It is a property of the image, true whether or not any init-bottom script ever
# runs, and phase 1 cannot undo it: rsync --delete does not delete what it
# excludes, and /dev/* is excluded. systemd mounts a devtmpfs over /dev within
# milliseconds of taking pid 1, so these matter for the instant of the handover
# and are invisible after it. Which is also why this is not an attempt to build
# a working /dev - it is debootstrap's list, no more.
mkdir -p "$MNT/dev/pts" "$MNT/dev/shm"
chmod 1777 "$MNT/dev/shm"

# name mode major minor
DEVNODES="console 600 5 1
null 666 1 3
zero 666 1 5
full 666 1 7
random 666 1 8
urandom 666 1 9
tty 666 5 0
ptmx 666 5 2"

MADE=""
while read -r dn dmode dmaj dmin; do
  [[ -n "$dn" ]] || continue
  # Anything already there is left alone, so a re-run cannot replace a node the
  # guest made for itself. Turning a wrong one into an error rather than a
  # surprise is the read-back's job, below.
  [[ -e "$MNT/dev/$dn" ]] && continue
  mknod -m "$dmode" "$MNT/dev/$dn" c "$dmaj" "$dmin" \
    || die "mknod /dev/$dn c $dmaj $dmin failed - without it the VM panics at the handover"
  MADE="${MADE:+$MADE }$dn"
done <<< "$DEVNODES"
[[ -n "$MADE" ]] && log "static device nodes created: $MADE"

# Same reasoning as the initramfs and grub.cfg read-backs in section 9: every
# command above can succeed and still leave the one thing that matters wrong,
# and the cheap place to find that out is here and not on a console. console is
# the node that panics; null is the one every early service writes to, and a
# regular file named null fills a disk instead of swallowing it.
[[ -c "$MNT/dev/console" ]] \
  || die "$MNT/dev/console is not a character device. Do NOT start this VM - init would panic with 'Attempted to kill init'"
[[ -c "$MNT/dev/null" ]] \
  || die "$MNT/dev/null is not a character device. Do NOT start this VM - remove whatever is at /dev/null in the image and run this again"

# ---------------------------------------------------------------------------
# 12. close it cleanly
# ---------------------------------------------------------------------------
# cleanup() would do all of this on the way out, but doing it here means a
# failure to unmount is an ERROR the operator sees rather than a silent exit 0
# with a dirty filesystem on a disk they are about to boot.
rm -f "$MNT/etc/resolv.conf"
[[ -e "$MNT/etc/resolv.conf.c2v" ]] && mv "$MNT/etc/resolv.conf.c2v" "$MNT/etc/resolv.conf"
RESOLV_SAVED=0
sync
umount "$MNT" || die "umount $MNT failed - do NOT start this VM until it is clean (lsof +f -- $MNT)"
losetup -d "$LOOP" || log "WARN: losetup -d $LOOP failed - check 'losetup -a'"
LOOP=""; MNT=""

cat <<EOF

$(date '+%F %T')  === phase 2 done ===

  guest       $GUEST_REL
  kernel      $KVER
  bootloader  MBR on the image, /boot/grub/grub.cfg
  root        UUID=$FSUUID${FSLABEL:+  (LABEL=$FSLABEL)}

  Nothing was started. Boot it by hand and watch it come up:

    qm start $VMID
    qm terminal $VMID

  It has NO network, on purpose. Only after you have seen it boot, and only
  when the old container is stopped, add the interface and reboot:

    qm set $VMID --net0 virtio,bridge=vmbr99,tag=99,mtu=9000
    qm reboot $VMID

  If phase 1 is re-run later to pick up newer data, it brings /etc back from the
  container and undoes everything section 10 above did. Run this again after it -
  it is one command, it is safe to repeat, and the path below works from any
  directory:

    $SELF/c2v-inside-deb.sh --vmid $VMID --storage $STORAGE

EOF
