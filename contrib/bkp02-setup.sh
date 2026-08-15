#!/usr/bin/env bash
# =============================================================================
#  bkp02-setup.sh — one-time prep on the BACKUP node (bkp02, 100.100.100.35)
#  before the first ct-replica.sh run. Idempotent: safe to run again.
#
#  Assumes YOU already created the two pools:  replica-hdd  and  replica-ssd
#  (this script refuses to run if either is missing - it configures, it does
#  not decide disk layout). Everything below the pool level is handled here:
#
#    1) datasets replica-hdd/ct + replica-ssd/ct with per-role properties:
#         both : atime=off  xattr=sa  acltype=posixacl   (LXC needs these two)
#                recordsize=128k (explicit: CT rootfs = many small/mixed files;
#                recordsize is a MAX, small files still use small records)
#         hdd  : compression=zstd  (40 idle cores buy a better ratio, and a
#                better ratio = fewer HDD IOs; worth it on the capacity tier)
#         ssd  : compression=lz4   (fastest path for a DR copy that must
#                pct start NOW; ratio matters less on the fast tier)
#       children subvol-<id>-disk-0 inherit all of it.
#    2) autotrim=on on the replica-ssd POOL (meaningless on HDD, skipped there)
#    3) PVE storage ids (named after the pools, per decision):
#         replica-hdd -> replica-hdd/ct,  replica-ssd -> replica-ssd/ct
#    4) recordsize=1M on the PBS chunk store (chunks are 1-4MB; only affects
#       NEW chunks, so it must happen BEFORE real backups start landing)
#    5) ARC cap: PVE >= 8.1 installs with zfs_arc_max ~ 10% of RAM; on 64G
#       that is ~6G. Raise to 32G on a dedicated backup node.
#    6) zed running (hot-spare activation + mail) + monthly scrub, every pool
# =============================================================================
set -uo pipefail

ARC_BYTES=34359738368          # 32 GiB
PBS_CHUNKS="pbsstore-sas/chunks"

say(){ printf '\n== %s\n' "$*"; }
die(){ printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# --- 0) the pools are YOUR job; refuse loudly when they are not there --------
for p in replica-hdd replica-ssd; do
  zpool list -H -o name "$p" >/dev/null 2>&1 \
    || die "pool '$p' does not exist - create it first, then run this again"
done

# --- 1) datasets + per-role properties ---------------------------------------
mkparent(){  # $1=dataset $2=storage-id $3=compression
  local ds="$1" sid="$2" comp="$3"
  if ! zfs list -H -o name "$ds" >/dev/null 2>&1; then
    say "create $ds"
    zfs create -p "$ds"
  fi
  say "properties on $ds (children inherit)"
  zfs set atime=off xattr=sa acltype=posixacl recordsize=128k compression="$comp" "$ds"
  # --- 3) storage id, so the copy configs' rootfs lines resolve --------------
  if ! pvesm status --storage "$sid" >/dev/null 2>&1; then
    say "add storage $sid -> $ds"
    pvesm add zfspool "$sid" --pool "$ds" --content rootdir,images --sparse 1 --nodes "$(hostname)"
  fi
  zfs get -H -o name,property,value compression,recordsize,atime,xattr,acltype "$ds"
}
# storage id = pool name, per decision: what the GUI shows is what zpool shows
mkparent replica-hdd/ct replica-hdd zstd
mkparent replica-ssd/ct replica-ssd lz4

# --- 2) autotrim: SSD pool only ----------------------------------------------
say "autotrim=on for replica-ssd (pool-level; no effect on HDD so not set there)"
zpool set autotrim=on replica-ssd
zpool get -H autotrim replica-ssd

# --- 4) PBS chunk store: big records for big chunks --------------------------
if zfs list -H -o name "$PBS_CHUNKS" >/dev/null 2>&1; then
  say "recordsize=1M on $PBS_CHUNKS (fewer IOPS on raidz1 HDD; new chunks only)"
  zfs set recordsize=1M "$PBS_CHUNKS"
else
  say "SKIP recordsize: $PBS_CHUNKS not found"
fi

# --- 5) ARC ------------------------------------------------------------------
cur=$(cat /sys/module/zfs/parameters/zfs_arc_max 2>/dev/null || echo 0)
say "zfs_arc_max now: $cur ($(( cur / 1024 / 1024 / 1024 ))G; 0 = default 50% of RAM)"
if (( cur != ARC_BYTES )); then
  say "set zfs_arc_max = $(( ARC_BYTES / 1024 / 1024 / 1024 ))G (live + persistent)"
  echo "$ARC_BYTES" > /sys/module/zfs/parameters/zfs_arc_max
  echo "options zfs zfs_arc_max=$ARC_BYTES" > /etc/modprobe.d/zfs.conf
  update-initramfs -u -k all
fi

# --- 6) zed + monthly scrub --------------------------------------------------
say "zed (needed for hot-spare auto-activation + email alerts)"
sed -i 's/^#\?ZED_EMAIL_ADDR=.*/ZED_EMAIL_ADDR="root"/' /etc/zfs/zed.d/zed.rc
systemctl enable --now zfs-zed
systemctl is-active zfs-zed
# Owner's decision (2026-07-31): no monthly scrub on the SSD pools.
# (For the record: scrub is a READ pass and barely touches SSD wear - it exists
# to catch silent corruption on any media. Remove a pool from this list to
# scrub it again.)
SCRUB_SKIP="replica-ssd rpool"
for p in $(zpool list -H -o name); do
  case " $SCRUB_SKIP " in
    *" $p "*)
      systemctl disable --now "zfs-scrub-monthly@${p}.timer" 2>/dev/null
      echo "scrub-monthly SKIPPED (SCRUB_SKIP): $p"
      continue;;
  esac
  systemctl enable --now "zfs-scrub-monthly@${p}.timer" 2>/dev/null \
    && echo "scrub-monthly enabled: $p"
done

say "done. verify:"
echo "  zfs list -o name,used,avail,recordsize,compression | grep -E 'replica|pbsstore'"
echo "  pvesm status | grep -E 'replica-hdd|replica-ssd'"
echo "  zpool get autotrim replica-ssd"
echo "  arc_summary | head -12"
