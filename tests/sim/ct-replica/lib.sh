# shellcheck shell=bash
# shared state for the fake commands the replica simulator puts on the engine's
# path. Two worlds live in $SIMROOT: the storage node this engine runs on, and
# the backup node it only ever reaches through ssh ($SIMROOT/bkp).
: "${SIMROOT:?SIMROOT not set - run through tests/sim/replica/run-sim-replica.sh}"
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
# A dry run may read anything. Anything that would change the fleet - snapshot,
# clone, destroy, create a dataset, write a config on the backup node, move
# bytes - is a violation, because the engine told the operator it would write
# nothing.
dry_forbids(){
  (( ${SIM_DRY:-0} )) || return 0
  violation "$* during a --dry-run - the engine said it would write nothing"
}

# ---------- local mounts ----------
is_mounted(){ grep -qxF "${1%/}" "$SIMROOT/mounted" 2>/dev/null; }
add_mount(){ printf '%s\n' "${1%/}" >> "$SIMROOT/mounted"; }
del_mount(){ grep -vxF "${1%/}" "$SIMROOT/mounted" > "$SIMROOT/.m" 2>/dev/null
             mv -f "$SIMROOT/.m" "$SIMROOT/mounted"; }
# deepest mounted ancestor of a path, "/" when there is none - what findmnt -T
# answers, and the whole of R1's first question
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

# ---------- zfs on this node:  name <TAB> fs|snap|clone <TAB> mountpoint ----
zfs_field(){ awk -F'\t' -v n="$1" -v c="$2" '$1==n{print $c; exit}' "$SIMROOT/zfs.tsv" 2>/dev/null; }
zfs_type(){ zfs_field "$1" 2; }
zfs_mnt(){  zfs_field "$1" 3; }
zfs_add(){  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$SIMROOT/zfs.tsv"; }
zfs_del(){  awk -F'\t' -v n="$1" '$1!=n' "$SIMROOT/zfs.tsv" > "$SIMROOT/.z" 2>/dev/null
            mv -f "$SIMROOT/.z" "$SIMROOT/zfs.tsv"; }
# fs.tsv rows are how findmnt sees a dataset; a clone gets one the moment it is
# created, which is what lets the mount fake tell live bytes from cloned bytes
fs_add(){ printf '%s\t%s\t%s\n' "${1%/}" "$2" "$3" >> "$SIMROOT/fs.tsv"; }
fs_del(){ awk -F'\t' -v m="${1%/}" '$1!=m' "$SIMROOT/fs.tsv" > "$SIMROOT/.f" 2>/dev/null
          mv -f "$SIMROOT/.f" "$SIMROOT/fs.tsv"; }

# ---------- zfs on the backup node:  name <TAB> yes|no <TAB> mountpoint -----
bkp_field(){ awk -F'\t' -v n="$1" -v c="$2" '$1==n{print $c; exit}' "$BKP/zfs.tsv" 2>/dev/null; }
bkp_add(){  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$BKP/zfs.tsv"; }
# which dataset owns a path over there - longest mountpoint wins, so the
# per-copy dataset beats the parent it hangs under
bkp_ds_of(){ awk -F'\t' -v p="${1%/}/" '
    $3 != "" && index(p, $3 "/") == 1 && length($3) > best { best=length($3); n=$1 }
    END{ print n }' "$BKP/zfs.tsv" 2>/dev/null; }
