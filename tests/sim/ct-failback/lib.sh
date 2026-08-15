# shellcheck shell=bash
# shared state for the fake commands the failback simulator puts in front of the
# engine. Two worlds live in $SIMROOT: the storage node this engine runs on and
# owns the production images of, and the backup node holding the promoted
# copies, which it only ever reaches through ssh ($SIMROOT/bkp).
#
# The third world is the production nodes. The engine never touches them except
# to ask "is this CT stopped", so they are one status file each.
: "${SIMROOT:?SIMROOT not set - run through tests/sim/failback/run-sim-failback.sh}"
BKP="$SIMROOT/bkp"

violation(){ printf 'VIOLATION: %s\n' "$*" >> "$SIMROOT/violations"; }
trace(){ printf '%s\n' "$*" >> "$SIMROOT/trace"; }

# --- the dry-run invariant --------------------------------------------------
# SIM_DRY is exported by run_engine when the ENGINE was invoked with --dry-run,
# read out of the engine's own argv rather than set by the scenario. That is
# the whole point: every dry scenario is policed by this, including ones
# written months from now by somebody who never read the one that introduced
# it, and a write that somebody forgets to gate is caught the first time it
# runs rather than the first time a human thinks to assert on it.
#
# A dry run may read anything. Anything that would change the fleet - a
# read-write loop-mount, a snapshot, a resize, moving bytes into a customer's
# image - is a violation, because the engine told the operator it would write
# nothing.
dry_forbids(){
  (( ${SIM_DRY:-0} )) || return 0
  violation "$* during a --dry-run - the engine said it would write nothing"
}

# A read-only loop-mount is the one mount a dry run may make, so umount has to
# know which kind it was: packing the mountpoint back into the image is the
# write, and a mount the kernel would have refused to dirty cannot produce one.
mark_ro(){ printf '%s\n' "${1%/}" >> "$SIMROOT/ro-mounts"; }
is_ro(){   grep -qxF "${1%/}" "$SIMROOT/ro-mounts" 2>/dev/null; }
del_ro(){  grep -vxF "${1%/}" "$SIMROOT/ro-mounts" > "$SIMROOT/.r" 2>/dev/null
           mv -f "$SIMROOT/.r" "$SIMROOT/ro-mounts"; }

# ---------- local mounts ----------
is_mounted(){ grep -qxF "${1%/}" "$SIMROOT/mounted" 2>/dev/null; }
add_mount(){ printf '%s\n' "${1%/}" >> "$SIMROOT/mounted"; }
del_mount(){ grep -vxF "${1%/}" "$SIMROOT/mounted" > "$SIMROOT/.m" 2>/dev/null
             mv -f "$SIMROOT/.m" "$SIMROOT/mounted"; }
# deepest mounted ancestor of a path, "/" when there is none - what findmnt -T
# answers, and the whole of B3's question
fs_holder(){ local p="${1%/}"
  while [[ -n "$p" ]]; do is_mounted "$p" && { printf '%s\n' "$p"; return 0; }; p="${p%/*}"; done
  printf '/\n'; }
# fs.tsv:  mountpoint <TAB> fstype <TAB> source
fs_field(){ awk -F'\t' -v m="$1" -v c="$2" '$1==m{print $c; exit}' "$SIMROOT/fs.tsv" 2>/dev/null; }

# ---------- loop devices ----------
loop_of(){ awk -v i="$1" '$1==i{print $2}' "$SIMROOT/loopmap" 2>/dev/null; }
img_at(){  awk -v m="$1" '$2==m{print $1}' "$SIMROOT/loopmap" 2>/dev/null; }
add_loop(){ printf '%s %s\n' "$1" "$2" >> "$SIMROOT/loopmap"; }
del_loop_by_mnt(){ awk -v m="$1" '$2!=m' "$SIMROOT/loopmap" > "$SIMROOT/.l" 2>/dev/null
                   mv -f "$SIMROOT/.l" "$SIMROOT/loopmap"; }

# ---------- zfs on this node:  name <TAB> fs|snap <TAB> mountpoint ----------
zfs_field(){ awk -F'\t' -v n="$1" -v c="$2" '$1==n{print $c; exit}' "$SIMROOT/zfs.tsv" 2>/dev/null; }
zfs_type(){ zfs_field "$1" 2; }
zfs_add(){  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$SIMROOT/zfs.tsv"; }

# ---------- zfs on the backup node:  name <TAB> yes|no <TAB> mountpoint -----
bkp_field(){ awk -F'\t' -v n="$1" -v c="$2" '$1==n{print $c; exit}' "$BKP/zfs.tsv" 2>/dev/null; }
# which dataset owns a path over there - longest mountpoint wins, so a per-copy
# dataset beats the parent it hangs under
bkp_ds_of(){ awk -F'\t' -v p="${1%/}/" '
    $3 != "" && index(p, $3 "/") == 1 && length($3) > best { best=length($3); n=$1 }
    END{ print n }' "$BKP/zfs.tsv" 2>/dev/null; }

# ---------- the production side ----------
# An image path is /<pool>/images/<ctid>/vm-<ctid>-disk-0.raw, so the image
# names the container it belongs to. That is what lets a fake answer the only
# question B1 cares about without being told which CT is being worked on.
ct_of_image(){ local p="${1%/*}"; [[ "$p" == */images/* ]] || return 1; printf '%s\n' "${p##*/}"; }
prod_status(){ local f
  for f in "$SIMROOT"/nodes/*/ct/"$1".status; do
    [[ -e "$f" ]] || continue
    cat "$f"; return 0
  done
  return 1; }
