#!/usr/bin/env bash
# =============================================================================
#  run-c2v.sh — prove the EL6 and EL7 branches of c2v-inside.sh write what they
#               are supposed to write, without a CentOS guest to run them in,
#               and that phase 1 hands phase 2 an image it can still work on
# -----------------------------------------------------------------------------
#  Why this exists: c2v-inside.sh only ever runs in a rescue environment, on a
#  disk that already holds somebody's production data, and the operator sees the
#  result as either a login prompt or a machine that hangs on a black screen.
#  There is no smaller failure available. A wrong grub.cfg costs a second
#  rescue boot at 2am; a wrong EL6 grub.conf, introduced while adding EL7,
#  costs the same on a conversion nobody thought they had changed.
#
#  How it works: the two blocks that generate text are lifted out of the real
#  script by literal anchors, every path that is *written to* is redirected into
#  a sandbox, and the block is sourced. Lines that start with `echo` are left
#  alone on purpose - that is the generated content, and rewriting the /boot
#  paths inside it would make the test agree with itself instead of with the
#  guest. If an anchor stops matching, the extraction fails and so does the
#  test. That is the point: an anchor that matches nothing has stopped proving
#  anything, the same rule the mutation suite lives by.
#
#  Sections 8 to 10 lift blocks out of c2v-prepare.sh the same way. They live
#  here rather than in a file of their own because what they are checked against
#  is phase 2 - an exclude list that stops protecting a path phase 2 installs is
#  only wrong in company, and it took a dead VM to find out.
#
#  usage:  ./tests/c2v/run-c2v.sh
#          KEEP=1 ./tests/c2v/run-c2v.sh    keep the sandbox and print where
#          make test                        same thing, from the repo root
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SCRIPT="${SCRIPT:-$ROOT/contrib/c2v-inside.sh}"
PASS=0; FAIL=0; FAILED_NAMES=()

T="$(mktemp -d /tmp/c2v-test.XXXXXX)"
cleanup(){
  if [ "${KEEP:-0}" = "1" ]; then echo "sandbox kept at $T"; else rm -rf "$T"; fi
}
trap cleanup EXIT

ok(){   PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad(){  FAIL=$((FAIL+1)); FAILED_NAMES+=("$1"); printf '  FAIL  %s\n' "$1"; shift; printf '        %s\n' "$@"; }

# ---------------------------------------------------------------------------
#  extraction
# ---------------------------------------------------------------------------
# awk rather than sed -n '/a/,/b/p' because the end anchor has to be excluded
# and because an anchor that never matches must produce nothing, loudly.
extract_from(){ # extract_from <file> <start-regex> <end-regex-exclusive>
  awk -v s="$2" -v e="$3" '
    $0 ~ s {on=1}
    on && $0 ~ e {exit}
    on {print}
  ' "$1"
}

extract(){ extract_from "$SCRIPT" "$1" "$2"; }

sandboxed(){ # sandboxed <file>  - redirect writes into $T, leave content alone
  # Two kinds of line are content rather than instruction and must survive
  # untouched: anything echoed, and the body of a quoted heredoc. Rewriting a
  # /boot path inside either would only prove the test agrees with itself.
  #
  # The line that OPENS a heredoc is both at once - `cat > /etc/default/grub
  # <<'EOF'` is an instruction up to the `<<` and a delimiter after it - so it is
  # split and only the head is rewritten. Printing that line whole was a real
  # bug: the redirect escaped the sandbox and the test overwrote the *host's*
  # /etc/default/grub.
  awk -v t="$T" '
    function sandbox(s) {
      gsub("/boot/",           t "/boot/",           s)
      gsub("/etc/",            t "/etc/",            s)
      gsub("/usr/share/grub/", t "/usr/share/grub/", s)
      gsub("/usr/lib/systemd/", t "/usr/lib/systemd/", s)
      return s
    }
    /<<.?EOF.?$/ {
      i = index($0, "<<")
      print sandbox(substr($0, 1, i - 1)) substr($0, i)
      inhd = 1; next
    }
    inhd && /^EOF$/         { print; inhd=0; next }
    inhd                    { print; next }
    /^[[:space:]]*echo /    { print; next }
    { print sandbox($0) }
  ' "$1"
}

# An empty extraction usually means an anchor moved. It used to mean something
# else as well, and that one cost a green suite here and a red one in CI on the
# same commit: awk parses -v values as STRING literals before they are ever a
# regex, so a lone \$ is an unknown escape. mawk demoted it to a bare $ and then
# treated that $ as a literal mid-pattern, so every anchor matched by accident;
# gawk demoted it the same way and treated the $ as an end-of-line anchor, so
# nothing could ever match. Same anchors, opposite verdicts, decided by which
# awk the machine happens to ship. The anchors carry doubled backslashes now -
# \\$ reaches the regex as \$, a literal dollar in every awk there is - and this
# suite is green under mawk and gawk both. If it is ever empty again, the anchor
# really did move.
need(){ # need <what> <file> [script-the-anchor-lives-in]
  [ -s "$2" ] && return 0
  echo "EXTRACTION FAILED: $1 - nothing matched in ${3:-$SCRIPT}"
  echo "  either an anchor moved, or this awk is not GNU awk. Check awk first:"
  echo "  a warning about an escape sequence above means the anchors are fine"
  echo "  and the suite is being run on a userland it does not support."
  exit 2
}

REL_BLOCK="$T/rel.sh"
extract '^REL=\\$\\(cat /etc/redhat-release\\)$' '^log "guest: \\$REL"$' > "$REL_BLOCK.raw"
need "release detection" "$REL_BLOCK.raw"
sandboxed "$REL_BLOCK.raw" > "$REL_BLOCK"

BOOT_BLOCK="$T/boot.sh"
extract '^CONSOLE_ARGS="console=tty0"$' '^# The bootloader lives outside' > "$BOOT_BLOCK.raw"
need "bootloader section" "$BOOT_BLOCK.raw"
sandboxed "$BOOT_BLOCK.raw" > "$BOOT_BLOCK"

PKG_BLOCK="$T/pkg.sh"
extract '^have_kernel\\(\\)\\{' '^if have_kernel' > "$PKG_BLOCK.raw"
need "package selection" "$PKG_BLOCK.raw"
cp "$PKG_BLOCK.raw" "$PKG_BLOCK"

NET_BLOCK="$T/net.sh"
extract '^RULES=/etc/udev/rules\\.d/70-persistent-net\\.rules$' \
        '^# An ifcfg file is read by exactly two things' > "$NET_BLOCK.raw"
need "network cleanup" "$NET_BLOCK.raw"
sandboxed "$NET_BLOCK.raw" > "$NET_BLOCK"

# Not sandboxed, and it cannot be: this block walks `/` by design, so path
# rewriting would either miss it or aim it at the machine running the tests.
# Every call it makes to the outside is stubbed instead - see run_ids.
IDS_BLOCK="$T/ids.sh"
extract '^idoff=\\$\\(stat -c %u /etc' '^is_mounted\\(\\)\\{' > "$IDS_BLOCK.raw"
need "id shift check" "$IDS_BLOCK.raw"
cp "$IDS_BLOCK.raw" "$IDS_BLOCK"

RESCUE_BLOCK="$T/rescue.sh"
extract '^if \\[ -d "\\$SYSROOT" \\] && \\[ -z "\\$\\{C2V_INNER:-\\}" \\]; then' \
        '^\\[ -f /etc/redhat-release \\]' > "$RESCUE_BLOCK"
need "rescue shell stage" "$RESCUE_BLOCK"

# Extracted separately from the stage above because it runs at a different time:
# the binds are made before the chroot and taken back off after it, and the order
# they come off in is the half that only the EXIT trap can get wrong.
CLEAN_BLOCK="$T/clean.sh"
extract '^cleanup\\(\\)\\{' '^trap cleanup EXIT' > "$CLEAN_BLOCK"
need "cleanup trap" "$CLEAN_BLOCK"

# Three blocks out of phase 1. They belong in this file rather than in a new one
# because what they are checked against is phase 2: the exclude list has to keep
# exactly the files c2v-inside.sh tests for, and that pair is only ever wrong
# together. Nothing here is sandboxed - none of the three writes anything.
PREP="$ROOT/contrib/c2v-prepare.sh"

RSOPT_BLOCK="$T/rsopt.sh"
extract_from "$PREP" '^RSOPT=\\(-aHAX' '^log "rsync <= \\$SRC"$' > "$RSOPT_BLOCK"
need "rsync options" "$RSOPT_BLOCK" "$PREP"

MAP_BLOCK="$T/map.sh"
extract_from "$PREP" '^map_bridge\\(\\)\\{' '^NETHINT=""; UNMAPPED=""; CATCHALL=""$' > "$MAP_BLOCK"
need "bridge map lookup" "$MAP_BLOCK" "$PREP"

CFG_BLOCK="$T/cfg.sh"
extract_from "$PREP" '^cfgval\\(\\)\\{' '^mplist=' > "$CFG_BLOCK"
need "cpu and memory inheritance" "$CFG_BLOCK" "$PREP"

GUARD_BLOCK="$T/mapguard.sh"
extract_from "$PREP" '^HAVE_MAP=0$' '^map_bridge\\(\\)\\{' > "$GUARD_BLOCK"
need "bridge map guard" "$GUARD_BLOCK" "$PREP"

# Read, not sourced: section 6c is a list of paths, and the only question asked
# of it is whether the exclude list covers every one.
CHECK_BLOCK="$T/check6c.txt"
extract_from "$PREP" '^if ls "\\$MNT"/boot/vmlinuz-\*' '^  if \\[\\[ -n "\\$PKGS_GONE" \\]\\]' > "$CHECK_BLOCK"
need "post-sync package check" "$CHECK_BLOCK" "$PREP"

# Section 0a, which is the first thing phase 1 decides and the one every other
# block above depends on. Extracted from family_of() so both helpers come with
# it; iso_release_check lands in the middle and is only defined, never called.
FAM_BLOCK="$T/family.sh"
extract_from "$PREP" '^family_of\\(\\)\\{' '^# The label default follows the family' > "$FAM_BLOCK"
need "guest family probe" "$FAM_BLOCK" "$PREP"

# What 0a decides once the family is known. Not merged with the block above
# because this one reaches the filesystem - it looks for phase 2 next to the real
# script - and that is the half worth running against the real directory.
FAMUSE_BLOCK="$T/famuse.sh"
extract_from "$PREP" '^if \\[\\[ -n "\\$LABEL" \\]\\]; then' \
                     '^# Size the VM like the container' > "$FAMUSE_BLOCK"
need "label and phase 2 selection" "$FAMUSE_BLOCK" "$PREP"

# Section 7's two decisions. Sourced against a real directory rather than stubbed,
# because what is being asked is whether a file on disk is a symlink or not, and a
# stub that answers that question is a stub that can answer it wrongly.
S7_BLOCK="$T/sect7.sh"
extract_from "$PREP" '^if \\(\\( BOOTABLE \\)\\) && grep -Eq' \
                     '^# Phase 2 has to reach the guest somehow' > "$S7_BLOCK"
need "fstab and mtab decisions" "$S7_BLOCK" "$PREP"

# ---------------------------------------------------------------------------
#  stubs. grub and grub2-install are the only two commands in the extracted
#  blocks that touch the outside world; both record their arguments instead.
# ---------------------------------------------------------------------------
stub_env(){
  log(){ printf '%s\n' "$*" >> "$T/log"; }
  die(){ printf 'DIE: %s\n' "$*" >> "$T/log"; return 1; }
  # shellcheck disable=SC2317  # called from the sourced block, not from here
  grub(){ cat > "$T/grub.batch"; echo "Running \"setup (hd0)\"... succeeded"; }
  # shellcheck disable=SC2317
  grub2-install(){ printf '%s\n' "$*" > "$T/grub2-install.args"; echo "Installation finished. No error reported."; }
}

run_boot(){ # run_boot <EL> <SERIAL>
  # ${T:?} rather than $T: this line is one empty variable away from being
  # `rm -rf /boot /etc` on the machine running the tests.
  rm -rf "${T:?}/boot" "${T:?}/etc" "$T/log" "$T/grub.batch" "$T/grub2-install.args"
  mkdir -p "$T/boot" "$T/etc" "$T/usr/share/grub/x86_64-redhat"
  : > "$T/usr/share/grub/x86_64-redhat/stage2"
  : > "$T/usr/share/grub/x86_64-redhat/stage1"
  : > "$T/log"
  (
    stub_env
    # These are the inputs the extracted block reads. They look unused here
    # because the only reader is the block sourced two lines down.
    # shellcheck disable=SC2034
    { EL="$1"; SERIAL="$2"
      KVER="$KVER_UNDER_TEST"; LABEL=c7root; DISK=/dev/vda; ROOTPART=/dev/vda1; }
    # shellcheck disable=SC1090
    . "$BOOT_BLOCK"
  ) >> "$T/stdout" 2>&1
}

same(){ # same <name> <expected-file> <actual-file>
  if [ ! -f "$3" ]; then bad "$1" "$3 was never written"; return; fi
  if diff -u "$2" "$3" > "$T/diff" 2>&1; then ok "$1"; else bad "$1" "$(cat "$T/diff")"; fi
}

echo "=== c2v: EL and Debian branches, and what phase 1 hands phase 2 ==="
echo

# ---------------------------------------------------------------------------
#  1. release detection. These are the exact strings on the tin, including the
#     one that came off CT 140 and started all of this.
# ---------------------------------------------------------------------------
detect(){ # detect <release-string> -> prints EL or "die"
  mkdir -p "$T/etc"
  printf '%s\n' "$1" > "$T/etc/redhat-release"
  (
    stub_env
    # shellcheck disable=SC1090
    if . "$REL_BLOCK"; then printf '%s' "$EL"; else printf 'die'; fi
  )
}

while IFS='|' read -r want rel; do
  [ -n "$rel" ] || continue
  got=$(detect "$rel")
  if [ "$got" = "$want" ]; then ok "release: $rel -> $want"
  else bad "release: $rel" "wanted $want, got $got"; fi
done <<'TABLE'
6|CentOS release 6.10 (Final)
6|CentOS release 6.5 (Final)
6|Red Hat Enterprise Linux Server release 6.9 (Santiago)
7|CentOS Linux release 7.9.2009 (Core)
7|CentOS Linux release 7.0.1406 (Core)
7|Red Hat Enterprise Linux Server release 7.9 (Maipo)
die|CentOS Linux release 8.5.2111
die|Fedora release 38 (Thirty Eight)
die|
TABLE

# ---------------------------------------------------------------------------
#  2. package selection. A Minimal ISO that has no grub2-tools has to fail by
#     name, before yum, not at the first grub2-install.
# ---------------------------------------------------------------------------
pkgs_for(){
  (
    EL="$1"
    # shellcheck disable=SC1090
    . "$PKG_BLOCK"
    printf '%s' "$PKGS"
  )
}
for want_el in 6 7; do
  got=$(pkgs_for "$want_el")
  case "$want_el:$got" in
    '6:kernel grub dracut dracut-kernel') ok "EL6 package list" ;;
    '7:kernel grub2 grub2-tools dracut')  ok "EL7 package list" ;;
    *) bad "EL$want_el package list" "got: $got" ;;
  esac
done

# ---------------------------------------------------------------------------
#  3. EL6 output, byte for byte. This one is a regression guard, not a feature
#     test: the EL7 work restructured the section around it, and the only
#     acceptable effect on an EL6 conversion is none at all.
# ---------------------------------------------------------------------------
KVER_UNDER_TEST=2.6.32-754.35.1.el6.x86_64
run_boot 6 1

cat > "$T/want.grub.conf" <<'EOF'
# generated by c2v-inside.sh - hand edits survive nothing but a re-run
default=0
timeout=5
serial --unit=0 --speed=115200 --word=8 --parity=no --stop=1
terminal --timeout=10 console serial
title CentOS 6 (2.6.32-754.35.1.el6.x86_64)
        root (hd0,0)
        kernel /boot/vmlinuz-2.6.32-754.35.1.el6.x86_64 ro root=LABEL=c7root console=tty0 console=ttyS0,115200n8 rd_NO_LUKS rd_NO_LVM rd_NO_MD rd_NO_DM
        initrd /boot/initramfs-2.6.32-754.35.1.el6.x86_64.img
EOF
same "EL6 /boot/grub/grub.conf" "$T/want.grub.conf" "$T/boot/grub/grub.conf"

if [ -L "$T/boot/grub/menu.lst" ] && [ -L "$T/etc/grub.conf" ]; then
  ok "EL6 menu.lst and /etc/grub.conf symlinks"
else
  bad "EL6 symlinks" "menu.lst or /etc/grub.conf missing"
fi

if grep -q 'setup (hd0)' "$T/grub.batch" && grep -q "device (hd0) /dev/vda" "$T/grub.batch"; then
  ok "EL6 grub batch names the device"
else
  bad "EL6 grub batch" "$(cat "$T/grub.batch" 2>/dev/null)"
fi

# The EL7 files must not exist on an EL6 run, and the other way round. Writing
# both would boot whichever the guest reads and hide the mistake for months.
if [ -e "$T/boot/grub2" ] || [ -e "$T/etc/default/grub" ]; then
  bad "EL6 leaves grub2 alone" "an EL6 run created grub2 files"
else
  ok "EL6 leaves grub2 alone"
fi

# ---------------------------------------------------------------------------
#  4. EL7 output, byte for byte.
# ---------------------------------------------------------------------------
KVER_UNDER_TEST=3.10.0-1160.el7.x86_64
run_boot 7 1

cat > "$T/want.grub.cfg" <<'EOF'
# generated by c2v-inside.sh - hand edits survive nothing but a re-run
set default=0
set timeout=5
serial --unit=0 --speed=115200 --word=8 --parity=no --stop=1
terminal_input console serial
terminal_output console serial
menuentry 'CentOS Linux (3.10.0-1160.el7.x86_64)' {
        insmod part_msdos
        insmod ext2
        set root='hd0,msdos1'
        linux16 /boot/vmlinuz-3.10.0-1160.el7.x86_64 root=LABEL=c7root ro console=tty0 console=ttyS0,115200n8 net.ifnames=0 biosdevname=0 rd.lvm=0 rd.md=0 rd.dm=0 rd.luks=0
        initrd16 /boot/initramfs-3.10.0-1160.el7.x86_64.img
}
EOF
same "EL7 /boot/grub2/grub.cfg" "$T/want.grub.cfg" "$T/boot/grub2/grub.cfg"

cat > "$T/want.default.grub" <<'EOF'
# generated by c2v-inside.sh
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR="$(sed 's, release .*$,,g' /etc/system-release)"
GRUB_DEFAULT=saved
GRUB_DISABLE_SUBMENU=true
GRUB_DISABLE_RECOVERY=true
GRUB_TERMINAL_OUTPUT="console serial"
GRUB_SERIAL_COMMAND="serial --unit=0 --speed=115200 --word=8 --parity=no --stop=1"
GRUB_CMDLINE_LINUX="console=tty0 console=ttyS0,115200n8 net.ifnames=0 biosdevname=0 rd.lvm=0 rd.md=0 rd.dm=0 rd.luks=0"
EOF
same "EL7 /etc/default/grub" "$T/want.default.grub" "$T/etc/default/grub"

# grubby rebuilds the cmdline from GRUB_CMDLINE_LINUX and adds root= itself. A
# root= left in here would end up on the line twice after the first kernel
# update, and the second one wins.
if grep -q '^GRUB_CMDLINE_LINUX=.*root=' "$T/etc/default/grub"; then
  bad "EL7 GRUB_CMDLINE_LINUX has no root=" "$(grep '^GRUB_CMDLINE_LINUX=' "$T/etc/default/grub")"
else
  ok "EL7 GRUB_CMDLINE_LINUX has no root="
fi

# --boot-directory has no trailing slash, so sandboxed() leaves it alone and
# what the stub records is the literal string a real guest would see. That is
# the point of checking it: --target=i386-pc is what makes this a BIOS install
# rather than EFI, and --recheck is what stops grub2 reusing a stale device map.
got_args=$(cat "$T/grub2-install.args" 2>/dev/null)
if [ "$got_args" = "--target=i386-pc --boot-directory=/boot --recheck /dev/vda" ]; then
  ok "EL7 grub2-install arguments"
else
  bad "EL7 grub2-install arguments" "got: $got_args"
fi

if [ -L "$T/etc/grub2.cfg" ]; then ok "EL7 /etc/grub2.cfg symlink"
else bad "EL7 /etc/grub2.cfg symlink" "not a symlink"; fi

if [ -e "$T/boot/grub/grub.conf" ]; then
  bad "EL7 leaves grub 0.97 alone" "an EL7 run created /boot/grub/grub.conf"
else
  ok "EL7 leaves grub 0.97 alone"
fi

# ---------------------------------------------------------------------------
#  5. --no-serial. The serial console is the operator's only way in before the
#     network exists, so the flag that removes it has to remove all of it and
#     nothing else.
# ---------------------------------------------------------------------------
run_boot 7 0
if grep -q 'ttyS0' "$T/boot/grub2/grub.cfg" || grep -q '^serial ' "$T/boot/grub2/grub.cfg"; then
  bad "EL7 --no-serial" "$(cat "$T/boot/grub2/grub.cfg")"
else
  ok "EL7 --no-serial leaves no serial in grub.cfg"
fi
if grep -q '^GRUB_TERMINAL_OUTPUT="console"$' "$T/etc/default/grub" \
   && ! grep -q 'GRUB_SERIAL_COMMAND' "$T/etc/default/grub"; then
  ok "EL7 --no-serial leaves no serial in /etc/default/grub"
else
  bad "EL7 --no-serial /etc/default/grub" "$(cat "$T/etc/default/grub")"
fi
if grep -q 'net.ifnames=0' "$T/boot/grub2/grub.cfg"; then
  ok "EL7 --no-serial keeps net.ifnames=0"
else
  bad "EL7 --no-serial keeps net.ifnames=0" "it did not"
fi

run_boot 6 0
if grep -q 'ttyS0' "$T/boot/grub/grub.conf" || grep -q '^serial ' "$T/boot/grub/grub.conf"; then
  bad "EL6 --no-serial" "$(cat "$T/boot/grub/grub.conf")"
else
  ok "EL6 --no-serial leaves no serial in grub.conf"
fi

# ---------------------------------------------------------------------------
#  6. the container-isms. A CT with two veths ships two ifcfg files and both
#     carry a MAC the VM will not have. Cleaning only the first leaves a VM
#     that answers on one address and not the other, which reads as a routing
#     problem and is not one - so every case here is about the second file.
# ---------------------------------------------------------------------------
NETDIR_T="$T/etc/sysconfig/network-scripts"
RULES_T="$T/etc/udev/rules.d/70-persistent-net.rules"

net_reset(){ # net_reset - a guest with no ifcfg files and no init system at all
  rm -rf "${T:?}/etc" "${T:?}/usr/lib" "$T/log"
  mkdir -p "$NETDIR_T" "$T/etc/udev/rules.d" "$T/usr/lib/systemd/system"
  printf 'SUBSYSTEM=="net", ATTR{address}=="86:dd:92:25:c9:8f", NAME="eth0"\n' > "$RULES_T"
  : > "$T/log"
}

net_run(){ # net_run <EL>
  (
    stub_env
    # shellcheck disable=SC2034  # read by the sourced block, not here
    EL="$1"
    # shellcheck disable=SC1090
    . "$NET_BLOCK"
    # IFCFG_SHOW only exists to be interpolated into the warnings further down
    # the real script. It is captured here because a rename that leaves those
    # warnings pointing at an unset name is a `set -u` abort at 2am, in the one
    # branch nobody exercises by hand.
    printf '%s' "${IFCFG_SHOW:-UNSET}" > "$T/ifcfg_show"
  ) >> "$T/stdout" 2>&1
}

# The dirty file is a synthetic worst case; the clean one is copied from the
# real CT 140, which has neither HWADDR nor UUID. Both have to come out right.
net_reset
: > "$T/usr/lib/systemd/system/network.service"
cat > "$NETDIR_T/ifcfg-eth0" <<'EOF'
DEVICE=eth0
HWADDR=86:DD:92:25:C9:8F
UUID=1a2b3c4d-0000-0000-0000-000000000001
ONBOOT=yes
BOOTPROTO=none
IPADDR=58.82.170.211
NETMASK=255.255.255.224
GATEWAY=58.82.170.193
EOF
cat > "$NETDIR_T/ifcfg-eth1" <<'EOF'
DEVICE=eth1
ONBOOT=yes
BOOTPROTO=none
IPADDR=10.0.0.223
NETMASK=255.255.255.0
EOF
printf 'DEVICE=lo\nHWADDR=00:00:00:00:00:00\n' > "$NETDIR_T/ifcfg-lo"
net_run 7

cat > "$T/want.eth0" <<'EOF'
DEVICE=eth0
ONBOOT=yes
BOOTPROTO=none
IPADDR=58.82.170.211
NETMASK=255.255.255.224
GATEWAY=58.82.170.193
NM_CONTROLLED=no
EOF
same "EL7 ifcfg-eth0 loses HWADDR and UUID, keeps the address" "$T/want.eth0" "$NETDIR_T/ifcfg-eth0"

cat > "$T/want.eth1" <<'EOF'
DEVICE=eth1
ONBOOT=yes
BOOTPROTO=none
IPADDR=10.0.0.223
NETMASK=255.255.255.0
NM_CONTROLLED=no
EOF
same "EL7 ifcfg-eth1 is cleaned too, not just eth0" "$T/want.eth1" "$NETDIR_T/ifcfg-eth1"

# ifcfg-lo is not an eth*, and a rootfs with no loopback config is a rootfs
# where half of localhost stops working.
if grep -q '^HWADDR=' "$NETDIR_T/ifcfg-lo"; then
  ok "ifcfg-lo is left alone"
else
  bad "ifcfg-lo is left alone" "$(cat "$NETDIR_T/ifcfg-lo")"
fi

if [ -f "$RULES_T" ] && [ ! -s "$RULES_T" ]; then
  ok "70-persistent-net.rules emptied, not deleted"
else
  bad "70-persistent-net.rules" "wanted an empty file that still exists"
fi

if grep -q 'more than one interface' "$T/log"; then
  ok "two interfaces are announced, because qm set takes one --netN each"
else
  bad "two-interface note" "$(cat "$T/log")"
fi

if [ "$(cat "$T/ifcfg_show")" = "$NETDIR_T/ifcfg-eth0 $NETDIR_T/ifcfg-eth1" ]; then
  ok "IFCFG_SHOW names every file that was cleaned"
else
  bad "IFCFG_SHOW" "got: $(cat "$T/ifcfg_show")"
fi

# EL7 without initscripts: NM_CONTROLLED=no would hand the interface to a
# service that is not installed, taking it away from the only process that
# could have configured it.
net_reset
printf 'DEVICE=eth0\nHWADDR=aa:bb:cc:dd:ee:ff\nIPADDR=10.0.0.9\n' > "$NETDIR_T/ifcfg-eth0"
net_run 7
if grep -q 'NM_CONTROLLED' "$NETDIR_T/ifcfg-eth0"; then
  bad "EL7 without initscripts leaves NM_CONTROLLED alone" "$(cat "$NETDIR_T/ifcfg-eth0")"
else
  ok "EL7 without initscripts leaves NM_CONTROLLED alone"
fi
if grep -q 'initscripts is not installed' "$T/log"; then
  ok "EL7 without initscripts says so"
else
  bad "EL7 without initscripts message" "$(cat "$T/log")"
fi

# EL6 has no /usr/lib/systemd at all and must still claim the interface:
# initscripts owns rc.sysinit there, so a booting EL6 system has it by
# definition and the EL7 test must never be applied to it.
net_reset
printf 'DEVICE=eth0\nHWADDR=aa:bb:cc:dd:ee:ff\nIPADDR=10.0.0.9\n' > "$NETDIR_T/ifcfg-eth0"
net_run 6
if grep -qx 'NM_CONTROLLED=no' "$NETDIR_T/ifcfg-eth0"; then
  ok "EL6 claims the interface for initscripts regardless"
else
  bad "EL6 NM_CONTROLLED" "$(cat "$NETDIR_T/ifcfg-eth0")"
fi

# An operator who already decided this is not overruled, and the line is not
# added twice: the second copy is the one initscripts reads.
net_reset
: > "$T/usr/lib/systemd/system/network.service"
printf 'DEVICE=eth0\nNM_CONTROLLED=yes\nIPADDR=10.0.0.9\n' > "$NETDIR_T/ifcfg-eth0"
net_run 7
if [ "$(grep -c '^NM_CONTROLLED=' "$NETDIR_T/ifcfg-eth0")" = 1 ] \
   && grep -qx 'NM_CONTROLLED=yes' "$NETDIR_T/ifcfg-eth0"; then
  ok "an existing NM_CONTROLLED is neither doubled nor overruled"
else
  bad "existing NM_CONTROLLED" "$(cat "$NETDIR_T/ifcfg-eth0")"
fi

# No ifcfg at all is legal in a container - the LXC host configured the veth
# from outside - and it is the one case where the VM comes up with no address
# no matter how correct net0 is.
net_reset
net_run 7
if grep -q 'WARN: no .*ifcfg-eth\*' "$T/log"; then
  ok "a guest with no ifcfg-eth* is warned about"
else
  bad "no-ifcfg warning" "$(cat "$T/log")"
fi
if [ "$(cat "$T/ifcfg_show")" = "$NETDIR_T/ifcfg-eth0" ]; then
  ok "IFCFG_SHOW falls back to a name rather than to nothing"
else
  bad "IFCFG_SHOW fallback" "got: $(cat "$T/ifcfg_show")"
fi

# ---------------------------------------------------------------------------
#  7. the id shift. Every call this block makes to the outside is stubbed, so
#     what is under test is the arithmetic and the refusals - the part that
#     decides which ids move and by how much. A wrong window here re-owns
#     somebody's whole filesystem to the wrong uid, silently, and the machine
#     still boots.
# ---------------------------------------------------------------------------
run_ids(){ # run_ids <stat-uid> <uid-list> <gid-list> <leftover>
  : > "$T/passes"; : > "$T/log"
  (
    stub_env
    FAKE_STAT="$1"; FAKE_UIDS="$2"; FAKE_GIDS="$3"; FAKE_LEFT="$4"
    # The real die exits. stub_env's returns, which here would let a refused
    # image go on and be renumbered anyway - the exact bug this tests for.
    # shellcheck disable=SC2317
    die(){ printf 'DIE: %s\n' "$*" >> "$T/log"; exit 9; }
    # shellcheck disable=SC2317
    stat(){ printf '%s\n' "$FAKE_STAT"; }
    # shellcheck disable=SC2317
    find(){
      local a="$*"
      # The id lists are deliberately unquoted: they stand in for the many
      # lines real find prints, and the block under test pipes them to sort.
      # shellcheck disable=SC2086
      case "$a" in
        *'-printf %U'*)   printf '%s\n' $FAKE_UIDS ;;
        *'-printf %G'*)   printf '%s\n' $FAKE_GIDS ;;
        *'-print -quit'*) printf '%s' "$FAKE_LEFT" ;;
        *-exec*)          printf '%s\n' "$a" >> "$T/passes" ;;
      esac
    }
    # shellcheck disable=SC1090
    . "$IDS_BLOCK"
  ) >> "$T/stdout" 2>&1
}

run_ids 0 '0' '0' ''
if [ ! -s "$T/passes" ] && ! grep -q '^ids:' "$T/log"; then
  ok "an image owned by root is left completely alone"
else
  bad "uid 0 image" "$(cat "$T/passes" "$T/log")"
fi

run_ids '' '' '' ''
if grep -q 'DIE: cannot stat' "$T/log"; then
  ok "an unreadable /etc is a refusal, not a guess"
else
  bad "unreadable /etc" "$(cat "$T/log")"
fi

# 1000 is a real uid, not a map base. Subtracting it would renumber a working
# image into nonsense, so the only safe answer is to stop.
run_ids 1000 '1000' '1000' ''
if grep -q 'DIE: /etc is owned by uid 1000' "$T/log" && [ ! -s "$T/passes" ]; then
  ok "an offset below 65536 is refused before anything is renumbered"
else
  bad "offset 1000" "$(cat "$T/log" "$T/passes")"
fi

# The order of these is the safety invariant, not a detail: every id moves
# DOWN, so as long as the passes run ascending, a file an earlier pass has
# already fixed can never be selected by a later one. Fed deliberately out of
# order to prove the sort is doing that work.
run_ids 100000 '200000 100027 0 165534 100000 65534' '100000 4294967295' ''
cat > "$T/want.passes" <<EOF
/ -xdev -uid 100000 -exec chown -h 0 {} +
/ -xdev -uid 100027 -exec chown -h 27 {} +
/ -xdev -uid 165534 -exec chown -h 65534 {} +
/ -xdev -gid 100000 -exec chgrp -h 0 {} +
EOF
same "renumber passes: ascending, in-window only" "$T/want.passes" "$T/passes"

# 4294967295 is what an id outside the map looks like on disk. It is not ours
# to renumber and subtracting the offset from it would be a 4-billion-uid file.
if grep -q '4294967295' "$T/passes" || grep -q -- '-uid 65534 ' "$T/passes"; then
  bad "ids outside the map are skipped" "$(cat "$T/passes")"
else
  ok "ids outside the map are skipped"
fi

# The post-condition. Without it a renumber that silently did nothing looks
# exactly like one that worked, and the failure resurfaces as a dead VM.
run_ids 100000 '100000' '100000' '/usr/bin/passwd'
if grep -q 'DIE: renumber did not take' "$T/log"; then
  ok "anything left in the window after the passes is a failure"
else
  bad "renumber post-condition" "$(cat "$T/log")"
fi

# ---------------------------------------------------------------------------
#  8. phase 1's rsync exclude list, against what phase 2 puts in the image.
#     This pair cost a live conversion. Phase 2 installs a kernel, grub and
#     dracut; the container has no copy of any of them; the next delta sync ran
#     --delete and took all three back out. /boot was already excluded, so the
#     VM still booted - with no modules to load and no way to rebuild its own
#     initramfs - and re-running phase 2 to repair it died on "no install media
#     at /mnt/source" with no disc in the drive. A hand written list of paths is
#     only correct until somebody adds a package, so the paths checked here are
#     read out of section 6c rather than typed again.
# ---------------------------------------------------------------------------
# Read by the extracted block, not by anything here, so shellcheck cannot see
# the use. Neither value can change an answer below - the exclude patterns are
# what is under test and they are the same whatever the bandwidth cap is.
# shellcheck disable=SC2034
BWLIMIT=0
# shellcheck disable=SC2034
SSHOPT=(-o BatchMode=yes)
# The block builds its own ssh out of these two rather than out of SSHOPT, so
# both have to exist here or sourcing it dies under set -u.
# shellcheck disable=SC2034
SSHOPT_COMMON=(-o BatchMode=yes)
# shellcheck disable=SC2034
SSH_CIPHERS=aes128-gcm@openssh.com
# shellcheck disable=SC1090
. "$RSOPT_BLOCK"

excluded(){ # excluded <path> - would RSOPT hold this file back from --delete?
  local opt pat
  for opt in "${RSOPT[@]}"; do
    case "$opt" in --exclude=*) pat=${opt#--exclude=} ;; *) continue ;; esac
    # Two simplifications, neither able to change an answer below: rsync's /***
    # means the directory and everything in it, which for this question is the
    # same as naming the directory, and rsync's * stops at a slash while bash's
    # does not - but no pattern in the list has a * that a path here could only
    # reach by crossing one.
    pat=${pat%/\*\*\*}
    # shellcheck disable=SC2053  # the glob on the right is the entire point
    [[ "$1" == $pat || "$1" == $pat/* ]] && return 0
  done
  return 1
}

unprotected=""
while read -r p; do
  [ -n "$p" ] || continue
  excluded "$p" || unprotected="$unprotected $p"
done <<'EOF'
/boot/vmlinuz-3.10.0-1160.el7.x86_64
/boot/initramfs-3.10.0-1160.el7.x86_64.img
/boot/grub2/grub.cfg
/boot/grub/grub.conf
/usr/lib/modules/3.10.0-1160.el7.x86_64/kernel/net/ipv4/ip_gre.ko
/lib/modules/2.6.32-754.el6.x86_64/kernel/fs/ext4/ext4.ko
/usr/sbin/grub2-install
/sbin/grub
/usr/share/grub/x86_64-redhat/stage2
/usr/lib/grub/x86_64-redhat/normal.mod
/etc/grub.d/10_linux
/etc/default/grub
/etc/grub2.cfg
/usr/bin/dracut
/usr/lib/dracut/modules.d/99base/init.sh
/usr/share/dracut/modules.d/99base/init.sh
/etc/dracut.conf
/etc/dracut.conf.d/02-generic-image.conf
EOF
if [ -z "$unprotected" ]; then
  ok "everything phase 2 installs survives a delta sync"
else
  bad "phase 2's packages survive --delete" "a later sync would delete:$unprotected"
fi

# The same list for the other family. It is a separate list because the failure
# it guards against is a different one: the EL paths were once left out and found
# by a dead VM, while these have never been through a real conversion at all, and
# a path nobody has typed out is exactly where a list like this goes wrong. Both
# spellings of sbin, because a merged /usr is a property of the template's age.
unprotected=""
while read -r p; do
  [ -n "$p" ] || continue
  excluded "$p" || unprotected="$unprotected $p"
done <<'EOF'
/boot/vmlinuz-5.4.0-152-generic
/boot/initrd.img-5.4.0-152-generic
/boot/grub/grub.cfg
/boot/grub/i386-pc/core.img
/usr/lib/modules/5.4.0-152-generic/kernel/drivers/block/virtio_blk.ko
/lib/modules/5.4.0-152-generic/kernel/drivers/net/virtio_net.ko
/usr/sbin/update-initramfs
/sbin/update-initramfs
/usr/sbin/mkinitramfs
/usr/sbin/grub-install
/usr/sbin/grub-mkconfig
/usr/sbin/grub-probe
/usr/bin/grub-mkimage
/usr/lib/grub/i386-pc/normal.mod
/usr/share/grub/grub-mkconfig_lib
/etc/initramfs-tools/modules
/etc/initramfs-tools/initramfs.conf
/usr/share/initramfs-tools/hooks/thermal
/etc/kernel/postinst.d/initramfs-tools
/etc/grub.d/10_linux
/etc/default/grub
/etc/default/grub.d/50-curtin-settings.cfg
EOF
if [ -z "$unprotected" ]; then
  ok "the Debian family's kernel, grub and initramfs-tools survive too"
else
  bad "debian packages survive --delete" "a later sync would delete:$unprotected"
fi

# grubby is not a bootloader and is easy to leave out of a list of them, but the
# kernel's own rpm scriptlets call it, so a kernel installed without it comes
# with no menu entry at all.
if excluded /usr/sbin/grubby && excluded /sbin/grubby; then
  ok "grubby is covered by the grub globs"
else
  bad "grubby is protected" "the kernel's scriptlets need it"
fi

wrongly=""
while read -r p; do
  [ -n "$p" ] || continue
  ! excluded "$p" || wrongly="$wrongly $p"
done <<'EOF'
/etc/sysconfig/network-scripts/ifcfg-eth0
/etc/nginx/nginx.conf
/etc/passwd
/etc/systemd/system/multi-user.target.wants/nginx.service
/usr/lib/systemd/system/nginx.service
/usr/share/nginx/html/index.html
/usr/bin/python
/usr/lib64/libc.so.6
/usr/libexec/mysqld
/var/www/html/index.php
/home/deploy/.ssh/authorized_keys
/opt/app/current/config.yml
EOF
if [ -z "$wrongly" ]; then
  ok "the container's own files still cross"
else
  bad "excludes do not reach into the CT's data" "would never sync:$wrongly"
fi

# The rpm database has to describe the filesystem it sits on, and every other
# byte of that filesystem comes from the container - so the image gets the
# container's database and forgets these packages. Protecting it would leave a
# database that disagrees with the disk, which is worse. This is why section 6c
# and c2v-inside.sh both test for files rather than asking rpm.
if excluded /var/lib/rpm/Packages; then
  bad "/var/lib/rpm is deliberately not protected" "phase 2 must test files, not rpm -q"
else
  ok "/var/lib/rpm is deliberately not protected"
fi

# The anti-staleness check, and the reason section 6c is extracted at all: every
# path 6c reports as missing has to be one the exclude list was keeping.
# Otherwise 6c fires on every single run and the warning stops meaning anything.
uncovered=""
while read -r p; do
  [ -n "$p" ] || continue
  excluded "$p" || uncovered="$uncovered $p"
done < <(grep -o '\$MNT/[^"]*' "$CHECK_BLOCK" | sed 's/^\$MNT//' | sort -u)
if [ -z "$uncovered" ]; then
  ok "every path section 6c checks for is one the exclude list keeps"
else
  bad "section 6c and the exclude list agree" "6c looks for, but section 6 does not keep:$uncovered"
fi

# ---------------------------------------------------------------------------
#  9. the bridge map. A bridge name is local to a node: vmbr1 on the old node
#     and vmbr1 on the new one are the same string and not necessarily the same
#     segment, and nothing in either config says which. Carrying the name across
#     is the one substitution that puts a machine on the wrong network while
#     looking entirely correct.
# ---------------------------------------------------------------------------
run_guard(){ # run_guard <map-file> - prints the log, then HAVE_MAP
  (
    BRIDGEMAP="$1"; OLD_NODE=pve6a; THIS_NODE=pve9a
    # shellcheck disable=SC2317  # both are called from the sourced block
    log(){ printf '%s\n' "$*"; }
    # shellcheck disable=SC2317
    die(){ printf 'DIE: %s\n' "$*"; exit 9; }
    # shellcheck disable=SC1090
    . "$GUARD_BLOCK"
    printf 'HAVE_MAP=%s\n' "$HAVE_MAP"
  ) 2>&1
}

MAP_OK="$T/map-ok.tsv"
cat > "$MAP_OK" <<'EOF'
# old_node	old_bridge	new_node	new_bridge
pve6a	vmbr1	pve9a	vmbr2
pve6a	vmbr0	pve9a	vmbr0
*	vmbr7	*	vmbr9
EOF

MAP_SHORT="$T/map-short.tsv"
cat > "$MAP_SHORT" <<'EOF'
pve6a	vmbr1	pve9a	vmbr2
pve6a	vmbr3	vmbr4
EOF

MAP_EMPTY="$T/map-empty.tsv"
cat > "$MAP_EMPTY" <<'EOF'
# nothing here yet - copied from the example and never filled in
EOF

MAP_LAB="$T/map-lab.tsv"
cat > "$MAP_LAB" <<'EOF'
pve6a	vmbr1	pve9a	vmbr2
*	*	*	vmbr99
EOF

if [ "$(run_guard "$MAP_OK" | tail -1)" = "HAVE_MAP=1" ]; then
  ok "a filled in map is picked up"
else
  bad "map is picked up" "$(run_guard "$MAP_OK")"
fi

# A short row matches nothing, so a map that has one behaves as if it were not
# there at all - which is the failure this file exists to prevent. Refusing is
# the only answer that cannot be missed.
# Captured rather than piped: grep -q closes the pipe on its first match, the
# subshell dies of SIGPIPE, and pipefail then reports the whole pipeline as
# failed even though the assertion held. Every check below is written this way.
out="$(run_guard "$MAP_SHORT")"
if grep -q 'DIE:.*needs four columns' <<<"$out"; then
  ok "a row with fewer than four columns is refused, not ignored"
else
  bad "short row is refused" "$out"
fi

if [ "$(run_guard "$MAP_EMPTY" | tail -1)" = "HAVE_MAP=0" ]; then
  ok "a map of nothing but comments counts as no map"
else
  bad "comment-only map" "$(run_guard "$MAP_EMPTY")"
fi

# shellcheck disable=SC1090
. "$MAP_BLOCK"

# Both variables are read by map_bridge, which was sourced above out of another
# file, so shellcheck sees the assignments and never the uses.
# shellcheck disable=SC2034
lookup(){ # lookup <old-node> <new-node> <bridge> - the row, or MISS
  OLD_NODE="$1"; THIS_NODE="$2"
  map_bridge "$3" || echo MISS
}

# Same again: map_bridge reads BRIDGEMAP. Setting it between checks is how each
# assertion below picks the fixture it wants.
# shellcheck disable=SC2034
BRIDGEMAP="$MAP_OK"
if [ "$(lookup pve6a pve9a vmbr1)" = "vmbr2 row" ]; then
  ok "a renamed bridge is translated"
else
  bad "exact row" "got: $(lookup pve6a pve9a vmbr1)"
fi

if [ "$(lookup pve6b pve9c vmbr7)" = "vmbr9 row" ]; then
  ok "* in a node column matches any node"
else
  bad "node wildcard" "got: $(lookup pve6b pve9c vmbr7)"
fi

# Not a miss on the map, a miss on this row: the node pair is wrong, so the row
# that names vmbr1 does not apply and guessing from it would be the whole bug.
if [ "$(lookup pve6z pve9a vmbr1)" = "MISS" ]; then
  ok "a row for another node pair does not answer for this one"
else
  bad "node is part of the key" "got: $(lookup pve6z pve9a vmbr1)"
fi

if [ "$(lookup pve6a pve9a vmbr5)" = "MISS" ]; then
  ok "an unmapped bridge is a miss, so the caller can say so"
else
  bad "unmapped bridge" "got: $(lookup pve6a pve9a vmbr5)"
fi

# shellcheck disable=SC2034  # read by map_bridge, sourced from c2v-prepare.sh
BRIDGEMAP="$MAP_LAB"
if [ "$(lookup pve6a pve9a vmbr1)" = "vmbr2 row" ]; then
  ok "first match wins: a real row above a catch-all still answers"
else
  bad "first match wins" "got: $(lookup pve6a pve9a vmbr1)"
fi

# The catch-all is a lab setting - every interface onto one dead-end bridge,
# which is what makes it safe to give the VM the CT's own addresses while the CT
# is still up. It has to announce itself on every run, because the run where
# nobody notices it is still there is the one that puts a production machine on
# a bridge with nothing on the other end.
if [ "$(lookup pve6a pve9a vmbr3)" = "vmbr99 catchall" ]; then
  ok "a * in the bridge column reports itself as a catch-all"
else
  bad "catch-all is flagged" "got: $(lookup pve6a pve9a vmbr3)"
fi

# ---------------------------------------------------------------------------
#  10. cpu and memory, taken from the container rather than from a default.
#      A default that happens to be smaller than the CT is a converted machine
#      that runs and is slow, which is a much later and much more expensive
#      discovery than one that does not start.
# ---------------------------------------------------------------------------
# oldcfg is the file the extracted block greps and OLD_CTID is what it names in
# its log lines; both are read there, so shellcheck only ever sees them set.
# shellcheck disable=SC2034
run_cfg(){ # run_cfg <ct-config> <forced-memory> <forced-cores> [family]
  (
    oldcfg="$1"; MEMORY="$2"; CORES="$3"; OLD_CTID=140; GUEST_FAMILY="${4:-el}"
    # shellcheck disable=SC2317  # called from the sourced block
    log(){ printf '%s\n' "$*"; }
    # shellcheck disable=SC1090
    . "$CFG_BLOCK"
    printf 'MEMORY=%s CORES=%s\n' "$MEMORY" "$CORES"
  ) 2>&1
}

CT_FULL='arch: amd64
cores: 4
hostname: web01
memory: 8192
net0: name=eth0,bridge=vmbr1,hwaddr=AA:BB:CC:DD:EE:FF,ip=10.0.0.11/24
ostype: centos
rootfs: local-lvm:vm-140-disk-0,size=40G
swap: 512'

if [ "$(run_cfg "$CT_FULL" '' '' | tail -1)" = "MEMORY=8192 CORES=4" ]; then
  ok "cpu and memory come from the CT"
else
  bad "inherit from CT" "got: $(run_cfg "$CT_FULL" '' '' | tail -1)"
fi

# swap: sits next to memory: in every config and is the wrong number to take.
out="$(run_cfg "$CT_FULL" '' '')"
if grep -q 'memory 8192M (from CT 140)' <<<"$out"; then
  ok "swap is not mistaken for memory"
else
  bad "swap vs memory" "$out"
fi

if [ "$(run_cfg "$CT_FULL" 16384 8 | tail -1)" = "MEMORY=16384 CORES=8" ]; then
  ok "an explicit flag still wins over the CT"
else
  bad "flag beats CT" "got: $(run_cfg "$CT_FULL" 16384 8 | tail -1)"
fi

# A CT with no cores: is not limited at all and runs on every core the node has.
# That is not a number a VM can be given, so it falls back - and says so, because
# a quiet 2 on a machine that had 24 is the slow kind of wrong.
CT_NOLIMIT='arch: amd64
hostname: web01
memory: 4096'
out="$(run_cfg "$CT_NOLIMIT" '' '')"
if [ "$(tail -1 <<<"$out")" = "MEMORY=4096 CORES=2" ] \
   && grep -q 'WARN.*not limited to a core count' <<<"$out"; then
  ok "a CT with no core limit falls back loudly"
else
  bad "no cores: line" "$out"
fi

CT_NOMEM='arch: amd64
cores: 2
hostname: web01'
out="$(run_cfg "$CT_NOMEM" '' '')"
if [ "$(tail -1 <<<"$out")" = "MEMORY=2048 CORES=2" ] \
   && grep -q 'WARN.*has no memory' <<<"$out"; then
  ok "a config with no memory: line falls back loudly"
else
  bad "no memory: line" "$out"
fi

# Phase 2 runs yum and dracut inside the guest's own rescue environment, which
# does not fit in what a small container is happy with. The floor is about
# finishing the conversion, not about the workload, so a flag can still go under.
CT_TINY='arch: amd64
cores: 1
memory: 512'
if [ "$(run_cfg "$CT_TINY" '' '' el | tail -1)" = "MEMORY=1024 CORES=1" ]; then
  ok "a CT below 1024M is raised so phase 2 can run"
else
  bad "memory floor" "got: $(run_cfg "$CT_TINY" '' '' el | tail -1)"
fi

if [ "$(run_cfg "$CT_TINY" 768 '' el | tail -1)" = "MEMORY=768 CORES=1" ]; then
  ok "the floor does not override an explicit --memory"
else
  bad "floor vs flag" "got: $(run_cfg "$CT_TINY" 768 '' el | tail -1)"
fi

# The same container converted the other way. Nothing on the Debian side runs
# in the guest before it boots, so the EL floor would be inventing memory the
# machine never had - and a VM given more RAM than its container had is a
# capacity plan quietly rewritten by a conversion script.
if [ "$(run_cfg "$CT_TINY" '' '' debian | tail -1)" = "MEMORY=512 CORES=1" ]; then
  ok "the same tiny CT keeps its 512M on the Debian side"
else
  bad "debian floor" "got: $(run_cfg "$CT_TINY" '' '' debian | tail -1)"
fi

# 256M is under both floors, so this is the one case where the two families
# agree that the number has to move - and they still move it to different places.
CT_TINIER='arch: amd64
cores: 1
memory: 256'
out="$(run_cfg "$CT_TINIER" '' '' debian)"
if [ "$(tail -1 <<<"$out")" = "MEMORY=512 CORES=1" ] \
   && grep -q 'initramfs is unpacked into RAM' <<<"$out"; then
  ok "under the Debian floor it is raised, and the reason names first boot"
else
  bad "debian floor reason" "$out"
fi

out="$(run_cfg "$CT_TINIER" '' '' el)"
if [ "$(tail -1 <<<"$out")" = "MEMORY=1024 CORES=1" ] \
   && grep -q 'yum in the guest' <<<"$out"; then
  ok "the EL reason still names phase 2, not first boot"
else
  bad "el floor reason" "$out"
fi

# ---------------------------------------------------------------------------
#  11. the rescue shell stage. This exists because of a console that cannot
#      paste: the DVD is only visible from outside the chroot and the image is
#      only writable from inside it, so somebody had to type
#      `mount --bind /run/install/repo /mnt/sysimage/mnt/source` by hand, four
#      paths, no copy, at 2am. Getting one of them wrong installs from the
#      wrong media or silently into the ramdisk. What is checked here is that
#      the script finds the disc by content, refuses to guess, chroots exactly
#      once, and takes its mounts back off in the order that leaves a clean
#      ext4 behind - rescue unmounts the image on the way out and a busy
#      mountpoint there is a fsck on the first real boot.
# ---------------------------------------------------------------------------
MOUNT_FAIL=""; CHROOT_RC=0; INNER=""

# Every variable set in the subshell below is read by the extracted block or by
# a stub the block calls, so shellcheck sees them assigned and never used.
# shellcheck disable=SC2034
run_rescue(){ # run_rescue <sysroot> <repo-hint> <fake-proc-mounts> [args...]
  : > "$T/log"; : > "$T/mounts"
  rm -f "$T/chroot.args" "$T/chroot.env" "$T/outer"
  local sysroot="$1" hint="$2" fake="$3"; shift 3
  (
    SYSROOT="$sysroot"; REPOHINT="$hint"; SRCDIR=/mnt/source
    OUTER_MOUNTS=""; ARGV=("$@"); C2V_INNER="$INNER"
    log(){ printf '%s\n' "$*" >> "$T/log"; }
    # The real die exits. One that returned would let a run with nothing in
    # $SYSROOT carry on and chroot into it anyway - the case below it.
    # shellcheck disable=SC2317
    die(){ printf 'DIE: %s\n' "$*" >> "$T/log"; exit 9; }
    # Only the two /proc/mounts probes reach these. Pointing them at a fixture
    # is the only way to test a rescue that had already bound /proc itself, or
    # a disc that anaconda left somewhere neither default name covers.
    # shellcheck disable=SC2317
    grep(){ local a; local args=()
            for a in "$@"; do [ "$a" = /proc/mounts ] && a="$fake"; args+=("$a"); done
            command grep "${args[@]}"; }
    # shellcheck disable=SC2317
    awk(){  local a; local args=()
            for a in "$@"; do [ "$a" = /proc/mounts ] && a="$fake"; args+=("$a"); done
            command awk "${args[@]}"; }
    # shellcheck disable=SC2317
    mount(){ printf '%s\n' "$*" >> "$T/mounts"
             [ -n "$MOUNT_FAIL" ] && [ "$MOUNT_FAIL" = "$3" ] && return 1
             return 0; }
    # Recorded here rather than from the EXIT trap because this is the one
    # moment every bind has been made and none taken back off, which is what
    # the order of OUTER_MOUNTS has to be right at.
    # shellcheck disable=SC2317
    chroot(){ printf '%s\n' "$*"                > "$T/chroot.args"
              printf '%s\n' "${C2V_INNER:-unset}" > "$T/chroot.env"
              printf '%s\n' "$OUTER_MOUNTS"     > "$T/outer"
              return "$CHROOT_RC"; }
    # shellcheck disable=SC1090
    . "$RESCUE_BLOCK"
    printf 'FELL THROUGH\n' >> "$T/log"
  ) >> "$T/stdout" 2>&1
}

# A rescue environment on disk: an image with phase 1's script in it, a disc
# that looks like a disc, and a decoy that does not.
S="$T/rescue/sysimage"
mkdir -p "$S/root" "$T/rescue/repo7/repodata" "$T/rescue/repo6/Packages" \
         "$T/rescue/decoy" "$T/rescue/elsewhere/repodata" "$T/rescue/bare/root"
: > "$S/root/c2v-inside.sh"; chmod 0755 "$S/root/c2v-inside.sh"
: > "$T/rescue/mounts.empty"
printf '/dev/sr0 %s iso9660 ro 0 0\n' "$T/rescue/elsewhere" > "$T/rescue/mounts.iso"
printf 'none %s/proc proc rw 0 0\nnone %s/sys sysfs rw 0 0\nnone %s/dev devtmpfs rw 0 0\n' \
       "$S" "$S" "$S" > "$T/rescue/mounts.bound"

run_rescue "$S" "$T/rescue/repo7" "$T/rescue/mounts.empty"
mnt="$(cat "$T/mounts")"
if grep -q -- "--bind $T/rescue/repo7 $S/mnt/source" <<<"$mnt"; then
  ok "the DVD is bound onto the image, without anyone typing four paths"
else
  bad "DVD bind" "$mnt"
fi

# repodata/ is what EL7 discs carry and Packages/ is what EL6 ones do. Either
# is proof; the name a directory happens to have is not.
run_rescue "$S" "$T/rescue/repo6" "$T/rescue/mounts.empty"
if grep -q -- "--bind $T/rescue/repo6 $S/mnt/source" <<<"$(cat "$T/mounts")"; then
  ok "a disc with Packages/ and no repodata/ still counts"
else
  bad "EL6 disc layout" "$(cat "$T/mounts")"
fi

# The decoy is the whole reason this is checked by content. An empty directory
# called /mnt/source binds happily and then yum installs nothing from it.
run_rescue "$S" "$T/rescue/decoy" "$T/rescue/mounts.empty"
out="$(cat "$T/log")"
if ! grep -q -- "--bind $T/rescue/decoy" <<<"$(cat "$T/mounts")" \
   && grep -q 'WARN: no install media found' <<<"$out"; then
  ok "a directory with no repodata and no Packages is not mistaken for the DVD"
else
  bad "decoy accepted" "$out$(cat "$T/mounts")"
fi

# Not fatal, on purpose: the chrooted run reads the drive out of /proc/mounts
# itself and is in a better position to say what it found.
if [ -f "$T/chroot.args" ]; then
  ok "no media out here is a warning, not a refusal - the inner run still tries"
else
  bad "no media aborted the run" "$(cat "$T/log")"
fi

# A disc attached as a second drive, or a rescue that mounted it somewhere of
# its own, answers in /proc/mounts and nowhere else.
run_rescue "$S" "" "$T/rescue/mounts.iso"
if grep -q -- "--bind $T/rescue/elsewhere $S/mnt/source" <<<"$(cat "$T/mounts")"; then
  ok "an iso9660 mount under neither usual name is still found"
else
  bad "iso9660 discovery" "$(cat "$T/mounts")"
fi

# "1) Continue" binds these; the other rescue menu choices do not, and an
# operator who picked one is otherwise ten minutes from an rpm with no /proc.
run_rescue "$S" "$T/rescue/repo7" "$T/rescue/mounts.empty"
mnt="$(cat "$T/mounts")"
miss=""
for d in /dev /proc /sys; do
  grep -q -- "--bind $d $S$d" <<<"$mnt" || miss="$miss $d"
done
if [ -z "$miss" ]; then ok "/dev /proc /sys are bound when rescue has not"
else bad "api filesystems" "not bound:$miss"; fi

run_rescue "$S" "$T/rescue/repo7" "$T/rescue/mounts.bound"
if ! grep -q -- '--bind /proc' <<<"$(cat "$T/mounts")"; then
  ok "a bind rescue already made is left alone"
else
  bad "double bind" "$(cat "$T/mounts")"
fi

# Newest first. The DVD bind sits under the sysroot, so it has to be recorded
# ahead of everything it is nested in or the unmount below comes off in the
# order that leaves a busy mountpoint behind.
run_rescue "$S" "$T/rescue/repo7" "$T/rescue/mounts.empty"
printf '%s\n' "$S/mnt/source $S/sys $S/proc $S/dev " > "$T/want.outer"
same "the mounts are recorded newest first" "$T/want.outer" "$T/outer"

# The flags the operator typed are on the outer run and the work happens on the
# inner one. Dropping them here is invisible until a --kver or --disk that was
# needed silently is not there.
run_rescue "$S" "$T/rescue/repo7" "$T/rescue/mounts.empty" --kver 3.10.0-1160.el7.x86_64 --no-serial
if [ "$(cat "$T/chroot.args")" = "$S /root/c2v-inside.sh --kver 3.10.0-1160.el7.x86_64 --no-serial" ]; then
  ok "the operator's flags reach the chrooted run"
else
  bad "ARGV forwarding" "got: $(cat "$T/chroot.args")"
fi

# A run with no flags at all is the common one, and ARGV is empty there. Under
# set -u a bare "${ARGV[@]}" would abort on bash 4.1, which is what the rescue
# ISO ships - so the empty case is the one that has to be proven.
run_rescue "$S" "$T/rescue/repo7" "$T/rescue/mounts.empty"
if [ "$(cat "$T/chroot.args")" = "$S /root/c2v-inside.sh" ]; then
  ok "no flags at all is not an unbound-variable abort"
else
  bad "empty ARGV" "got: $(cat "$T/chroot.args")"
fi

if [ "$(cat "$T/chroot.env")" = "1" ]; then
  ok "the chrooted run is marked as the inner one"
else
  bad "C2V_INNER not set for the chroot" "got: $(cat "$T/chroot.env")"
fi

# The guard, from the other side. A rootfs that happens to contain an empty
# /mnt/sysimage would otherwise re-detect "rescue shell" and chroot forever,
# from a console the operator cannot kill it from.
INNER=1
run_rescue "$S" "$T/rescue/repo7" "$T/rescue/mounts.empty"
INNER=""
if [ ! -f "$T/chroot.args" ] && grep -q 'FELL THROUGH' <<<"$(cat "$T/log")"; then
  ok "an inner run does not chroot again"
else
  bad "chroot loop guard" "$(cat "$T/log")"
fi

# An empty $SYSROOT is rescue's read-only option, or skip-to-shell. Going in
# anyway would do the whole of phase 2 in a ramdisk that is thrown away at
# reboot, and the image would look untouched for no visible reason.
run_rescue "$T/rescue/bare" "$T/rescue/repo7" "$T/rescue/mounts.empty"
out="$(cat "$T/log")"
if grep -q 'DIE: .*has no /root/c2v-inside.sh' <<<"$out" \
   && grep -q 'read/write' <<<"$out" && [ ! -f "$T/chroot.args" ]; then
  ok "an image rescue never mounted is a refusal, before any bind"
else
  bad "unmounted sysroot" "$out"
fi

# Phase 2's exit code is the operator's only signal from a run they cannot
# scroll back. Swallowing it would report a failed conversion as a finished one.
CHROOT_RC=3
run_rescue "$S" "$T/rescue/repo7" "$T/rescue/mounts.empty"; rc=$?
CHROOT_RC=0
out="$(cat "$T/log")"
if [ "$rc" = 3 ] && ! grep -q 'phase 2 finished' <<<"$out"; then
  ok "a failed inner run is not reported as finished"
else
  bad "exit code swallowed" "rc=$rc $out"
fi

run_rescue "$S" "$T/rescue/repo7" "$T/rescue/mounts.empty"; rc=$?
if [ "$rc" = 0 ] && grep -q 'phase 2 finished' <<<"$(cat "$T/log")"; then
  ok "a good run says what to type next"
else
  bad "success message" "rc=$rc $(cat "$T/log")"
fi

# The other half of newest-first. Rescue unmounts the image on its way out, so
# one bind left underneath it is an ext4 that needs a fsck on the first boot.
: > "$T/umounts"
(
  # shellcheck disable=SC2034
  { REPOFILE="$T/rescue/nosuchrepo"; MOUNTED_SRC=0; SRCDIR=/mnt/source
    OUTER_MOUNTS="$S/mnt/source $S/sys $S/proc $S/dev"; }
  # shellcheck disable=SC2317
  umount(){ printf '%s\n' "$*" >> "$T/umounts"; }
  # shellcheck disable=SC1090
  . "$CLEAN_BLOCK"
  cleanup
) >> "$T/stdout" 2>&1
cat > "$T/want.umounts" <<EOF
$S/mnt/source
$S/sys
$S/proc
$S/dev
EOF
same "the binds come off newest first" "$T/want.umounts" "$T/umounts"

# ---------------------------------------------------------------------------
#  12. what phase 1 is allowed to overwrite on a disk that already boots.
#
#  Phase 1 is re-run to plant a corrected phase 2, and that re-run used to take
#  the VM down: it replaced /etc/mtab with a real empty file every time, which is
#  right on the way into rescue mode and fatal afterwards, because EL7 has no
#  rc.sysinit to rebuild it. The guest came up read-only, logind died, and on the
#  worse of the two it looped on "Failed to mount /" - from a console the
#  operator was being told to run phase 2 from.
# ---------------------------------------------------------------------------
S7="$T/s7"

mk_s7(){ # mk_s7 <redhat-release line, or - for none> <mtab: link|file|none>
  rm -rf "${S7:?}"; mkdir -p "$S7/etc"
  [ "$1" = - ] || printf '%s\n' "$1" > "$S7/etc/redhat-release"
  case "$2" in
    link) ln -sf /proc/self/mounts "$S7/etc/mtab";;
    file) : > "$S7/etc/mtab";;
  esac
}

# Every variable here is read by the extracted block, not by this function.
# shellcheck disable=SC2034
run_sect7(){ # run_sect7 <bootable> <label> [family]
  : > "$T/log"
  (
    BOOTABLE="$1"; LABEL="$2"; MNT="$S7"; GUEST_FAMILY="${3:-el}"
    log(){ printf '%s\n' "$*" >> "$T/log"; }
    # shellcheck disable=SC1090
    . "$S7_BLOCK"
  ) >> "$T/stdout" 2>&1
}

EL7REL='CentOS Linux release 7.9.2009 (Core)'
EL6REL='CentOS release 6.10 (Final)'

# The first run, the one all of this was written for. A container's fstab is not
# worth keeping and its mtab symlink crashes anaconda before phase 2 can start.
mk_s7 "$EL7REL" link
printf 'LABEL=whatever /srv ext4 defaults 0 0\n' > "$S7/etc/fstab"
run_sect7 0 c7root
if grep -q '^LABEL=c7root  /  ' <<<"$(sed 's/  */  /g' "$S7/etc/fstab")" \
   && [ ! -L "$S7/etc/mtab" ] && [ -f "$S7/etc/mtab" ] && [ ! -s "$S7/etc/mtab" ]; then
  ok "a disk that cannot boot yet gets a fresh fstab and a real empty mtab"
else
  bad "first run" "fstab=$(cat "$S7/etc/fstab") mtab=$(ls -l "$S7/etc/mtab")"
fi

# The regression. This is the exact state a working VM is in when phase 1 is
# re-run against it, and the old code broke it here.
mk_s7 "$EL7REL" link
printf 'LABEL=c7root  /  ext4  defaults  1 1\nLABEL=data  /data  ext4  defaults  0 0\n' \
  > "$S7/etc/fstab"
run_sect7 1 c7root
if [ -L "$S7/etc/mtab" ] && grep -q '/data' "$S7/etc/fstab"; then
  ok "a disk that already boots keeps its mtab symlink and its fstab"
else
  bad "bootable EL7 clobbered" "mtab=$(ls -l "$S7/etc/mtab") fstab=$(cat "$S7/etc/fstab")"
fi

# The repair. A VM already damaged by the older script has to come back on the
# re-run, because the re-run IS the recovery and its console is what is down.
mk_s7 "$EL7REL" file
printf 'LABEL=c7root  /  ext4  defaults  1 1\n' > "$S7/etc/fstab"
run_sect7 1 c7root
out="$(cat "$T/log")"
if [ -L "$S7/etc/mtab" ] && grep -q 'WARN.*mtab is a real file' <<<"$out"; then
  ok "an EL7 disk an older phase 1 broke is repaired, and says so"
else
  bad "no mtab repair" "mtab=$(ls -l "$S7/etc/mtab") $out"
fi

# EL6 is the other way round and must not be "repaired" into breaking: rc.sysinit
# clears and rebuilds a real /etc/mtab at every boot, and there is no systemd.
mk_s7 "$EL6REL" file
printf 'LABEL=c6root  /  ext4  defaults  1 1\n' > "$S7/etc/fstab"
run_sect7 1 c6root
if [ ! -L "$S7/etc/mtab" ] && [ -f "$S7/etc/mtab" ]; then
  ok "an EL6 disk keeps its real mtab - rc.sysinit rebuilds that one"
else
  bad "EL6 mtab turned into a symlink" "$(ls -l "$S7/etc/mtab")"
fi

# No release file is not a licence to guess. Doing nothing leaves whatever
# carried the disk through its last boot in place, which is the safe answer.
mk_s7 - file
printf 'LABEL=c7root  /  ext4  defaults  1 1\n' > "$S7/etc/fstab"
run_sect7 1 c7root
if [ ! -L "$S7/etc/mtab" ]; then
  ok "an image with no /etc/redhat-release is left alone, not guessed at"
else
  bad "guessed EL7 with no release file" "$(ls -l "$S7/etc/mtab")"
fi

# Keeping the fstab is conditional on it still mounting / from this label. One
# that does not would leave a disk nothing can find its own root on.
mk_s7 "$EL7REL" link
printf 'LABEL=c6root  /  ext4  defaults  1 1\n' > "$S7/etc/fstab"
run_sect7 1 c7root
if grep -q 'LABEL=c7root' "$S7/etc/fstab" && ! grep -q 'c6root' "$S7/etc/fstab"; then
  ok "an fstab that mounts / from the wrong label is rewritten, not kept"
else
  bad "wrong-label fstab kept" "$(cat "$S7/etc/fstab")"
fi

# The label has to be on the root line to count. A data volume that happens to
# carry it is not the same file and must not buy the fstab a pass.
mk_s7 "$EL7REL" link
printf 'LABEL=c7root  /srv  ext4  defaults  0 0\n' > "$S7/etc/fstab"
run_sect7 1 c7root
if grep -Eq '^LABEL=c7root[[:space:]]+/[[:space:]]' "$S7/etc/fstab"; then
  ok "the label has to be on the / line, not just somewhere in the file"
else
  bad "matched a non-root line" "$(cat "$S7/etc/fstab")"
fi

# ---------------------------------------------------------------------------
#  12b. the same section on the Debian side, where the answer is the opposite
#       one and is the same on every run. Phase 2 is a chroot on this node, so
#       there is no rescue session whose write to /etc/mtab has to land in a
#       plain file, and a symlink to /proc/self/mounts is what a Debian guest
#       wants both before and after. The EL story above is three branches
#       because it changes; this is one branch because it does not.
# ---------------------------------------------------------------------------

# The real first run. /etc/mtab is rsync-excluded, so on a fresh image the file
# is not there at all - if this branch only ever repaired an existing file, every
# Debian conversion would boot with no mtab and find out at the first df.
mk_s7 - none
printf 'LABEL=whatever /srv ext4 defaults 0 0\n' > "$S7/etc/fstab"
run_sect7 0 debroot debian
if [ -L "$S7/etc/mtab" ] && [ "$(readlink "$S7/etc/mtab")" = /proc/self/mounts ]; then
  ok "a fresh Debian image, which has no mtab at all, gets the symlink"
else
  bad "debian first run" "mtab=$(ls -l "$S7/etc/mtab" 2>&1)"
fi

# The re-run against a VM that already boots - the case that cost an EL7 guest
# its console. Here it has to be a no-op, and the fstab has to survive with it.
mk_s7 - link
printf 'LABEL=debroot  /  ext4  defaults  1 1\nLABEL=data  /data  ext4  defaults  0 0\n' \
  > "$S7/etc/fstab"
run_sect7 1 debroot debian
if [ -L "$S7/etc/mtab" ] && grep -q '/data' "$S7/etc/fstab"; then
  ok "a Debian VM that already boots keeps its symlink and its added disk"
else
  bad "debian bootable clobbered" "mtab=$(ls -l "$S7/etc/mtab") fstab=$(cat "$S7/etc/fstab")"
fi

# A plain file here is the EL6 shape on a guest with no rc.sysinit to rebuild it,
# so it stays empty forever. It has to be replaced whether or not the disk boots.
mk_s7 - file
printf 'LABEL=debroot  /  ext4  defaults  1 1\n' > "$S7/etc/fstab"
run_sect7 1 debroot debian
if [ -L "$S7/etc/mtab" ]; then
  ok "a real mtab file on a Debian image is replaced, bootable or not"
else
  bad "debian mtab file kept" "$(ls -l "$S7/etc/mtab")"
fi

# The family picks the branch, not the disk. This fixture is deliberately absurd
# - an image carrying a CentOS release file converted as debian - because the
# only thing it can prove is which of the two inputs the code actually asked.
mk_s7 "$EL7REL" file
printf 'LABEL=debroot  /  ext4  defaults  1 1\n' > "$S7/etc/fstab"
run_sect7 1 debroot debian
if [ -L "$S7/etc/mtab" ] && ! grep -q 'boots its own init' "$T/log"; then
  ok "the family decides, not a release file left lying on the image"
else
  bad "debian took an EL branch" "mtab=$(ls -l "$S7/etc/mtab") $(cat "$T/log")"
fi

# ---------------------------------------------------------------------------
#  13. which family of guest phase 1 thinks it is converting.
#
#  This is the first thing phase 1 decides and everything above depends on it -
#  the exclude list, the mtab, the label, whether a DVD is needed and which
#  phase 2 gets named at the end. Getting it wrong is not a failure the operator
#  sees at the time. Before this block existed an Ubuntu CT ran the whole of
#  phase 1 without one warning and produced a disk that could never be finished,
#  because the release probe read /etc/redhat-release, got nothing, and the
#  release check it fed had a `*) return 0` at the bottom.
# ---------------------------------------------------------------------------
# Every variable here is read by the extracted block. The ssh stub answers with
# whatever the caller put in $T/guestos, which is the real shape of the answer:
# one command, two files, either of which may be missing.
# shellcheck disable=SC2034
run_family(){ # run_family <ct-config> <forced-family> <stopped> [guest files]
  : > "$T/log"
  printf '%s' "${4:-}" > "$T/guestos"
  (
    oldcfg="$1"; GUEST_FAMILY="$2"; STOPPED="$3"; FAMILY_SRC="--family"
    OLD_NODE=pve6a; OLD_CTID=140; SSHOPT=(-o BatchMode=yes)
    log(){ printf '%s\n' "$*" >> "$T/log"; }
    die(){ printf 'DIE: %s\n' "$*" >> "$T/log"; return 1; }
    # shellcheck disable=SC2317  # called from the sourced block
    ssh(){ cat "$T/guestos"; }
    # shellcheck disable=SC1090
    . "$FAM_BLOCK"
    printf 'FAMILY=%s\n' "$GUEST_FAMILY"
  ) 2>&1 | tail -1
}

CT_UBUNTU='arch: amd64
cores: 2
hostname: app01
memory: 2048
ostype: ubuntu'

CT_CENTOS='arch: amd64
cores: 2
hostname: web01
memory: 2048
ostype: centos'

# Every probe of a RUNNING CT below is given this config rather than one of the
# two above. `unmanaged` is a real PVE ostype and it is the one value that cannot
# answer the question, which is the point: with it in the config, the only thing
# left that can place the guest is the file the probe under test is reading. A
# fixture whose ostype: already knows the answer passes whether or not the probe
# works, and a test that passes with the probe deleted is not a test.
CT_UNMANAGED='arch: amd64
cores: 2
hostname: app01
memory: 2048
ostype: unmanaged'

# The exact file off the CT this was written for.
OSREL_FOCAL='NAME="Ubuntu"
VERSION="20.04.6 LTS (Focal Fossa)"
ID=ubuntu
ID_LIKE=debian
PRETTY_NAME="Ubuntu 20.04.6 LTS"
VERSION_ID="20.04"
VERSION_CODENAME=focal
UBUNTU_CODENAME=focal'

if [ "$(run_family "$CT_UNMANAGED" '' 0 "$OSREL_FOCAL")" = "FAMILY=debian" ]; then
  ok "an Ubuntu 20.04 CT is read off its own /etc/os-release"
else
  bad "ubuntu os-release" "got: $(run_family "$CT_UNMANAGED" '' 0 "$OSREL_FOCAL")"
fi

# PRETTY_NAME is what the operator sees in the log and on the final screen, and
# it is the only line of the file that says which point release this is.
run_family "$CT_UNMANAGED" '' 0 "$OSREL_FOCAL" >/dev/null
if grep -q 'guest: Ubuntu 20.04.6 LTS' "$T/log" && ! grep -q '"' "$T/log"; then
  ok "PRETTY_NAME is reported, with its quotes taken off"
else
  bad "pretty name" "$(cat "$T/log")"
fi

# Debian proper, which is the one os-release in common use with no ID_LIKE line
# at all - nothing is like Debian, it is what the others are like. The three
# sources are a ladder rather than three separate answers, so this is the case
# that has to come down it with the middle rung missing. It is also the guest
# most likely to be converted after Ubuntu, and it is not the same file.
OSREL_BULLSEYE='PRETTY_NAME="Debian GNU/Linux 11 (bullseye)"
NAME="Debian GNU/Linux"
VERSION_ID="11"
VERSION="11 (bullseye)"
VERSION_CODENAME=bullseye
ID=debian'
if [ "$(run_family "$CT_UNMANAGED" '' 0 "$OSREL_BULLSEYE")" = "FAMILY=debian" ]; then
  ok "Debian proper, which has no ID_LIKE line, is placed anyway"
else
  bad "debian id" "got: $(run_family "$CT_UNMANAGED" '' 0 "$OSREL_BULLSEYE")"
fi

# A distro whose own ID this script has never heard of. ID_LIKE is the line the
# derivative maintainer wrote precisely so that a stranger can still place it,
# and taking it is the difference between converting a Mint or a Pop!_OS
# container and refusing one for no reason a human would accept.
OSREL_DERIV='NAME="Linux Mint"
ID=linuxmint
ID_LIKE="ubuntu debian"
PRETTY_NAME="Linux Mint 20"'
if [ "$(run_family "$CT_UNMANAGED" '' 0 "$OSREL_DERIV")" = "FAMILY=debian" ]; then
  ok "an unknown ID falls back to ID_LIKE"
else
  bad "id_like fallback" "got: $(run_family "$CT_UNMANAGED" '' 0 "$OSREL_DERIV")"
fi

OSREL_ROCKY='NAME="Rocky Linux"
ID="rocky"
ID_LIKE="rhel centos fedora"
PRETTY_NAME="Rocky Linux 8.8 (Green Obsidian)"'
if [ "$(run_family "$CT_UNMANAGED" '' 0 "$OSREL_ROCKY")" = "FAMILY=el" ]; then
  ok "a quoted ID is still matched - os-release allows both spellings"
else
  bad "quoted id" "got: $(run_family "$CT_UNMANAGED" '' 0 "$OSREL_ROCKY")"
fi

# EL6 predates os-release entirely, so the only answer is the older file - and
# it is the release this whole toolchain was written for.
if [ "$(run_family "$CT_UNMANAGED" '' 0 "$EL6REL")" = "FAMILY=el" ]; then
  ok "CentOS 6, which has no os-release at all, still answers"
else
  bad "el6 redhat-release" "got: $(run_family "$CT_UNMANAGED" '' 0 "$EL6REL")"
fi

run_family "$CT_UNMANAGED" '' 0 "$EL6REL" >/dev/null
if grep -q "guest: $EL6REL" "$T/log"; then
  ok "with no PRETTY_NAME the redhat-release line is what gets reported"
else
  bad "el6 release string" "$(cat "$T/log")"
fi

# The same file on the distro CentOS was a rebuild of. It is here because its
# release line is the one that spells the vendor with a space, which no ID=
# anywhere does, and a pattern list written from ID= values alone misses it.
RHEL6REL='Red Hat Enterprise Linux Server release 6.10 (Santiago)'
if [ "$(run_family "$CT_UNMANAGED" '' 0 "$RHEL6REL")" = "FAMILY=el" ]; then
  ok "RHEL 6, which writes the vendor with a space, is placed too"
else
  bad "rhel6 release" "got: $(run_family "$CT_UNMANAGED" '' 0 "$RHEL6REL")"
fi

# A stopped CT cannot be asked anything, which is the whole reason ostype: is
# consulted at all. It is a label a human chose, so taking it has to be said out
# loud - and the message has to name the flag that overrides it.
out="$(run_family "$CT_UBUNTU" '' 1 "$OSREL_FOCAL")"
if [ "$out" = "FAMILY=debian" ] \
   && grep -q "ostype: ubuntu" "$T/log" && grep -q 'pass --family' "$T/log"; then
  ok "a stopped CT falls back to ostype: and says so"
else
  bad "stopped ostype" "$out $(cat "$T/log")"
fi

# The ssh answered, but with nothing this script can place. Falling through to
# ostype: here rather than refusing is deliberate: a CT whose os-release is
# missing is still a CT whose config says what it is.
if [ "$(run_family "$CT_CENTOS" '' 0 '')" = "FAMILY=el" ]; then
  ok "an unreadable guest falls back to the config, not to a guess"
else
  bad "empty guestos" "got: $(run_family "$CT_CENTOS" '' 0 '')"
fi

# Nothing left to ask. This has to be a refusal and not a default, because every
# default available here is wrong half the time, and the run that takes the wrong
# one is not a failure - it is a finished disk nobody can boot.
CT_NOTHING='arch: amd64
cores: 2
memory: 2048'
out="$(run_family "$CT_NOTHING" '' 1 '')"
if [ "$out" = "FAMILY=" ] && grep -q 'DIE:.*cannot tell what is inside' "$T/log"; then
  ok "a CT that cannot be placed is refused, not defaulted"
else
  bad "unplaceable CT" "$out $(cat "$T/log")"
fi

# --family is checked at parse time, so by here it is already a known word. What
# matters is that it is not asked again: an operator passes it exactly when the
# machine's own answer is the one they know to be wrong.
out="$(run_family "$CT_UBUNTU" el 0 "$OSREL_FOCAL")"
if [ "$out" = "FAMILY=el" ] && grep -q 'forced by --family' "$T/log"; then
  ok "--family wins over everything the guest says about itself"
else
  bad "family override" "$out $(cat "$T/log")"
fi

# ---------------------------------------------------------------------------
#  13b. what the family then decides. Run against the real tools directory,
#       because half of what this block does is look for phase 2 by name - and
#       a phase 2 that is present but not executable is a Debian conversion
#       that dies on its first line, after the operator has already waited out
#       a full rsync.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2034
run_famuse(){ # run_famuse <family> <label> <iso>
  : > "$T/log"
  (
    GUEST_FAMILY="$1"; LABEL="$2"; ISO="$3"; GUEST_REL=""; SELF="$ROOT/contrib"
    log(){ printf '%s\n' "$*" >> "$T/log"; }
    die(){ printf 'DIE: %s\n' "$*" >> "$T/log"; return 1; }
    # shellcheck disable=SC2317  # called from the sourced block
    pvesm(){ printf '%s\n' "iso-store:iso/CentOS-7-x86_64-DVD-2009.iso 4700M"; }
    # shellcheck disable=SC1090
    . "$FAMUSE_BLOCK"
    printf 'LABEL=%s ISO=%s\n' "$LABEL" "$ISO"
  ) 2>&1 | tail -1
}

ISO7='iso-store:iso/CentOS-7-x86_64-DVD-2009.iso'

if [ "$(run_famuse el '' "$ISO7")" = "LABEL=c7root ISO=$ISO7" ]; then
  ok "an EL guest gets c7root by default"
else
  bad "el label" "got: $(run_famuse el '' "$ISO7")"
fi

# c7root on the side of an Ubuntu disk is a lie the next person has to work out
# at 2am, from a rescue prompt, with no way to check what wrote it.
if [ "$(run_famuse debian '' '')" = "LABEL=debroot ISO=" ]; then
  ok "a Debian guest gets debroot, not the EL default"
else
  bad "debian label" "got: $(run_famuse debian '' '')"
fi

if [ "$(run_famuse debian c7root '' | sed 's/ ISO=.*//')" = "LABEL=c7root" ]; then
  ok "--label still wins over the family default"
else
  bad "label override" "got: $(run_famuse debian c7root '')"
fi

# Rule 5, applied to --iso: an EL guest cannot be finished without a disc, and
# the typo in its name only surfaces after the disk is already built.
run_famuse el '' '' >/dev/null
if grep -q 'DIE:.*--iso is required for an EL guest' "$T/log"; then
  ok "an EL guest with no --iso is refused before anything is built"
else
  bad "el iso required" "$(cat "$T/log")"
fi

# The other way round it is not a refusal. An operator converting a mixed batch
# has the flag in their shell history, and copying it here is harmless - but it
# has to be cleared, or section 8 attaches a disc the guest will never be told
# to boot and the operator waits at a rescue screen that is not coming.
out="$(run_famuse debian '' "$ISO7")"
if [ "$out" = "LABEL=debroot ISO=" ] && grep -q 'WARN.*--iso is ignored' "$T/log"; then
  ok "--iso on a Debian guest is cleared and announced, not obeyed"
else
  bad "debian iso ignored" "$out $(cat "$T/log")"
fi

# Not a mock. The last screen phase 1 prints tells the operator to run one of
# these by name, so both have to be there, and the Debian one has to be
# executable: it is run as a command, not sourced.
run_famuse debian '' '' >/dev/null
if ! grep -q 'DIE:' "$T/log"; then
  ok "phase 2 for a Debian guest is present and executable next to phase 1"
else
  bad "c2v-inside-deb.sh not runnable" "$(cat "$T/log")"
fi

run_famuse el '' "$ISO7" >/dev/null
if ! grep -q 'DIE:' "$T/log"; then
  ok "phase 2 for an EL guest is present next to phase 1"
else
  bad "c2v-inside.sh not readable" "$(cat "$T/log")"
fi

# ---------------------------------------------------------------------------
#  11. the initramfs hook phase 2 installs, run for real
# ---------------------------------------------------------------------------
# This one cost a live VM. Phase 1 excludes /usr/share/initramfs-tools, which
# also throws away the hooks packages OTHER than initramfs-tools ship into it -
# udev's above all, and udev's is what puts blkid in the image. apt cannot put
# it back, because the rsync brought the container's dpkg database along and apt
# already believes udev is installed. mkinitramfs then exits 0 having built an
# initramfs that cannot turn root=UUID= into a device, and the only symptom is
# a rescue shell on the console half an hour later.
#
# So the hook is lifted out and run, rather than grepped for. A hook that is
# present but silently copies nothing looks identical from the outside, and that
# is the exact shape of the bug this replaces.
DEB="$ROOT/contrib/c2v-inside-deb.sh"
H="$T/hook"; mkdir -p "$H/bin"

# The hook sources hook-functions by absolute path, which exists only inside a
# guest. Redirecting that one line at a stub is the whole mock - everything the
# hook decides, which is where blkid is and whether to copy it, is real code.
cat > "$H/hook-functions" <<'STUB'
copy_exec(){ printf 'COPY %s\n' "$1" >> "$COPIED"; }
STUB
extract_from "$DEB" 'IHOOK.*<<' '^HOOK$' | tail -n +2 \
  | sed "s#^\. /usr/share/initramfs-tools/hook-functions\$#. $H/hook-functions#" > "$H/c2v"
chmod +x "$H/c2v"

if [ -s "$H/c2v" ] && grep -q 'copy_exec' "$H/c2v"; then
  ok "the initramfs hook can be lifted out of c2v-inside-deb.sh"
else
  bad "hook extraction" "$(cat "$H/c2v")"
fi

# mkinitramfs calls every hook once with "prereqs" before it calls it for real.
# A hook that copies a binary during that pass, or exits non-zero, takes the
# whole build down with it.
COPIED="$H/prereq-copied"; : > "$COPIED"
if out="$(COPIED="$COPIED" /bin/sh "$H/c2v" prereqs 2>&1)" && [ ! -s "$COPIED" ]; then
  ok "the hook's prereqs pass copies nothing and exits 0"
else
  bad "hook prereqs" "$out"
fi

# The real pass. blkid is found on PATH rather than at a hard-coded path,
# because /sbin/blkid on Ubuntu 20.04 and /usr/sbin/blkid on a usrmerged Debian
# are both correct and neither is correct everywhere.
COPIED="$H/real-copied"; : > "$COPIED"
printf '#!/bin/sh\nexit 0\n' > "$H/bin/blkid"; chmod +x "$H/bin/blkid"
COPIED="$COPIED" PATH="$H/bin:$PATH" /bin/sh "$H/c2v" >/dev/null 2>&1
if grep -q "COPY $H/bin/blkid" "$COPIED"; then
  ok "the hook copies blkid into the initramfs"
else
  bad "hook copies blkid" "$(cat "$COPIED")"
fi

# And when there is no blkid to copy it must not take mkinitramfs down. That is
# section 9's job to catch, loudly, with the image in front of it - not this
# hook's, blind, in the middle of a build.
COPIED="$H/none-copied"; : > "$COPIED"
COPIED="$COPIED" PATH="/nonexistent" /bin/sh "$H/c2v" >/dev/null 2>&1; rc=$?
if [ "$rc" = 0 ] && [ ! -s "$COPIED" ]; then
  ok "a guest with no blkid does not abort the initramfs build"
else
  bad "hook with no blkid" "exit $rc $(cat "$COPIED")"
fi

# The read-back after update-initramfs is only worth having if its pattern
# matches what lsinitramfs really prints, so the pattern is taken from the
# script rather than retyped here.
PAT="$(sed -n "s/^.*lsinitramfs .* | grep -q '\(.*\)'; then\$/\1/p" "$DEB" | head -1)"
GOOD=$'usr/lib/x86_64-linux-gnu/libblkid.so.1\nsbin/blkid\nsbin/fsck\n'
BAD=$'sbin/dumpe2fs\nsbin/fsck\nsbin/wait-for-root\n'
if [ -n "$PAT" ] \
   && printf '%s' "$GOOD" | grep -q "$PAT" \
   && ! printf '%s' "$BAD" | grep -q "$PAT"; then
  ok "the initramfs read-back tells an image with blkid from one without"
else
  bad "initramfs read-back pattern" "pattern: ${PAT:-<not found>}"
fi

# ---------------------------------------------------------------------------
#  12. the static /dev nodes phase 2 makes, run for real
# ---------------------------------------------------------------------------
# The second live VM this cost, and the symptom names nothing it is about:
#
#   Kernel panic - not syncing: Attempted to kill init! exitcode=0x00000100
#
# The last line of the initramfs redirects init's stdio through
# ${rootmnt}/dev/console before it execs it, and the shell opens the redirection
# first, so a missing node kills pid 1 before init ever runs. A container's
# on-disk /dev is empty - the runtime covers it with a tmpfs - so the rootfs
# arrives without that node, and udev's init-bottom script, which would
# otherwise move a populated /dev across, went out with phase 1's
# --exclude=/usr/share/initramfs-tools along with the blkid hook above.
#
# Run rather than grepped. A loop that is there but makes console 5:2 instead of
# 5:1 reads identically from the outside and boots identically badly.
DN="$T/devnodes"; mkdir -p "$DN/dev" "$DN/bin"

# mknod is the only thing stubbed: it needs root, and make test also runs on
# machines whose /dev is not ours to write into. What gets made, what gets
# skipped, and with which major and minor is all real code.
cat > "$DN/bin/mknod" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$MKNOD_LOG"
STUB
chmod +x "$DN/bin/mknod"

{
  printf 'MNT=%s\n' "$DN"
  printf 'log(){ :; }\n'
  printf 'die(){ printf "DIE: %%s\\n" "$*"; exit 1; }\n'
  extract_from "$DEB" '^mkdir -p .*dev/pts' 'static device nodes created'
} > "$DN/run.sh"

if [ -s "$DN/run.sh" ] && grep -q mknod "$DN/run.sh"; then
  ok "the /dev node table can be lifted out of c2v-inside-deb.sh"
else
  bad "devnode extraction" "$(cat "$DN/run.sh")"
fi

MKNOD_LOG="$DN/made"; : > "$MKNOD_LOG"
out="$(MKNOD_LOG="$MKNOD_LOG" PATH="$DN/bin:$PATH" bash "$DN/run.sh" 2>&1)"; rc=$?
if [ "$rc" = 0 ]; then
  ok "the /dev node pass runs clean on a rootfs with an empty /dev"
else
  bad "devnode pass" "exit $rc: $out"
fi

# 5:1 is not negotiable. The console is a fixed major/minor pair compiled into
# the kernel, not something udev hands out, and this is the node whose absence
# produced the panic.
if grep -q -- "-m 600 $DN/dev/console c 5 1\$" "$MKNOD_LOG"; then
  ok "/dev/console is made as character 5:1, mode 600"
else
  bad "console node" "$(cat "$MKNOD_LOG")"
fi

# null is the other one that has to be exactly right: every early service writes
# to it, and a wrong minor points all of that at some real device instead.
if grep -q -- "-m 666 $DN/dev/null c 1 3\$" "$MKNOD_LOG"; then
  ok "/dev/null is made as character 1:3, mode 666"
else
  bad "null node" "$(cat "$MKNOD_LOG")"
fi

if [ "$(wc -l < "$MKNOD_LOG")" = 8 ] && [ -d "$DN/dev/pts" ] && [ -d "$DN/dev/shm" ]; then
  ok "eight nodes, plus /dev/pts and /dev/shm as directories"
else
  bad "devnode set" "$(wc -l < "$MKNOD_LOG") nodes: $(cat "$MKNOD_LOG")"
fi

# Phase 2 is re-run every time phase 1 is, so it meets images that already have
# these. Replacing a node the guest made for itself is not this script's
# business. The names come out of the log rather than being retyped, so adding a
# node to the table cannot leave this half-testing the old set.
sed 's|^.*/dev/||; s| c .*||' "$DN/made" | while read -r n; do : > "$DN/dev/$n"; done
MKNOD_LOG="$DN/made2"; : > "$MKNOD_LOG"
MKNOD_LOG="$MKNOD_LOG" PATH="$DN/bin:$PATH" bash "$DN/run.sh" >/dev/null 2>&1
if [ ! -s "$DN/made2" ]; then
  ok "a second pass makes nothing it has already made"
else
  bad "devnode re-run" "$(cat "$DN/made2")"
fi

# Which is only safe because of the read-back that follows it. Every node in the
# sandbox is a regular file right now - exactly the shape the skip above leaves
# behind when something else got there first - and that must not reach a boot.
{
  printf 'MNT=%s\n' "$DN"
  printf 'die(){ printf "DIE: %%s\\n" "$*"; exit 1; }\n'
  extract_from "$DEB" '^\\[\\[ -c ' '^# ---'
} > "$DN/readback.sh"
out="$(bash "$DN/readback.sh" 2>&1)"; rc=$?
if [ "$rc" != 0 ] && printf '%s' "$out" | grep -q console; then
  ok "the read-back refuses an image whose /dev/console is a regular file"
else
  bad "devnode read-back" "exit $rc: $out"
fi

echo
echo "=== $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then echo "failed: ${FAILED_NAMES[*]}"; exit 1; fi
exit 0
