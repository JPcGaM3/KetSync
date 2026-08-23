#!/usr/bin/env bash
# =============================================================================
#  run-mutation-recall.sh — check that the recall simulator can actually FAIL.
# -----------------------------------------------------------------------------
#  Same contract as the other four, pointed at the engine that writes INTO the
#  DR copy - the one copy standing between the fleet and a second failure
#  while the storage node is down. A green suite means nothing until you have
#  seen it go red for the right reason: this takes ct-recall.sh, breaks one
#  specific thing in it, and runs the scenarios that are supposed to notice. A
#  scenario that still passes against a broken engine is not a test, it is
#  decoration.
#
#  Every mutation is a literal-text edit anchored on a line of the engine. When
#  the anchor moves the mutation applies to nothing, and that is reported as a
#  failure too: a mutation that cannot be applied has stopped proving anything.
#  So any edit to ct-recall.sh must be mirrored here in the same change, and a
#  broken anchor is never "fixed" by deleting the mutation.
#
#  Each one is a bug a person could really write - a guard inverted, a check
#  moved back to where it used to live, a variable cleared one line too early.
#  A mutant that only proves bash still parses proves nothing.
#
#  usage:  ./tests/mutation/run-mutation-recall.sh
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SIM="$ROOT/tests/sim/ct-recall/run-sim-recall.sh"
SRC="$ROOT/engines/ct-recall.sh"
PASS=0; FAIL=0; FAILED_NAMES=()

command -v perl >/dev/null || { echo "perl is required for the mutation suite"; exit 1; }
[[ -x "$SIM" ]] || { echo "the recall simulator is not where this expects it: $SIM"; exit 1; }
[[ -r "$SRC" ]] || { echo "no engine to mutate: $SRC"; exit 1; }

# Extra environment for the NEXT mutant only, cleared again by mutant(). Kept
# for parity with the other four runners; nothing here uses it yet.
RUN_ENV=()

# $1 = name, $2 = perl s{}{} program, rest = scenarios that MUST fail on it
mutant(){
  local name="$1" prog="$2"; shift 2
  local m ok=1 s
  m="$(mktemp /tmp/ctrec-mutant.XXXXXX)"
  echo "  [$name]"
  # A zero-byte mutant is not a mutant. perl refusing the program - an
  # unbalanced brace inside s{}{} is the easy way to get there - writes nothing,
  # and an empty file is valid bash that fails every scenario for no reason at
  # all. That would report as a kill and prove the opposite of one. Half an
  # engine is the same failure one step less obvious, which is why the size
  # check is separate rather than folded into the emptiness one.
  if ! perl -0777 -pe "$prog" "$SRC" > "$m" 2>/dev/null; then
    echo "      x perl refused the mutation program - fix the mutation, not the engine"
    rm -f "$m"; RUN_ENV=(); FAIL=$((FAIL+1)); FAILED_NAMES+=("$name"); return
  fi
  if [[ ! -s "$m" ]] || (( $(wc -c <"$m") < $(( $(wc -c <"$SRC") / 2 )) )); then
    echo "      x the mutant is empty or half the engine is gone - that is corruption, not a mutation"
    rm -f "$m"; RUN_ENV=(); FAIL=$((FAIL+1)); FAILED_NAMES+=("$name"); return
  fi
  if cmp -s "$m" "$SRC"; then
    echo "      x the mutation matched nothing - its anchor has moved in the engine"
    rm -f "$m"; RUN_ENV=(); FAIL=$((FAIL+1)); FAILED_NAMES+=("$name"); return
  fi
  if ! bash -n "$m" 2>/dev/null; then
    echo "      x the mutant does not even parse - fix the mutation, not the engine"
    rm -f "$m"; RUN_ENV=(); FAIL=$((FAIL+1)); FAILED_NAMES+=("$name"); return
  fi
  chmod +x "$m"
  for s in "$@"; do
    if env ${RUN_ENV[@]+"${RUN_ENV[@]}"} ENGINE="$m" "$SIM" "$s" >/dev/null 2>&1; then
      echo "      x scenario $s SURVIVES the mutation - it is not testing this"
      ok=0
    else
      echo "      - scenario $s dies, as it must"
    fi
  done
  rm -f "$m"; RUN_ENV=()
  if (( ok )); then PASS=$((PASS+1)); echo "      ok"
  else FAIL=$((FAIL+1)); FAILED_NAMES+=("$name"); fi
}

# The runner's own safety net, exercised before it grades anything. The guards
# inside mutant() exist because a mutation that had never been applied reported
# green for weeks - and a guard nobody exercises is how the replica runner came
# to be missing both of them while CLAUDE.md said otherwise. Each probe calls
# mutant() for real inside a command substitution, so its counters and its
# output are thrown away and only the refusal is read. The two probes are
# different failures on purpose: the first makes perl exit non-zero and write
# nothing, the second lets perl succeed and produce an empty file. A runner
# that cannot refuse both stops here rather than grading.
self_check(){
  local out
  out="$(mutant "self-check: a program perl cannot compile" 's{unbalanced' 1 2>&1)"
  [[ "$out" == *"perl refused the mutation program"* ]] || {
    echo "SELF-CHECK FAILED: mutant() accepted a program perl cannot compile" >&2
    printf '%s\n' "$out" >&2; exit 2; }
  out="$(mutant "self-check: a program that empties the engine" 's{\A.*\z}{}s' 1 2>&1)"
  [[ "$out" == *"empty or half the engine is gone"* ]] || {
    echo "SELF-CHECK FAILED: mutant() accepted an empty mutant" >&2
    printf '%s\n' "$out" >&2; exit 2; }
}
self_check


echo "=== ct-recall.sh mutation suite ==="

# ---------- C1: the holder is discovered, never typed ------------------------
# pmxcfs is cluster-shared, so one question through the backup node names the
# machine holding the 9<id>. A node a human typed is a node that can be wrong,
# and wrong here reads an empty directory and then deletes a customer's DR copy
# to match it.
mutant "C1 carries on when there is no 9<id> in the cluster at all" \
  's{\Q  if [[ -z "\E\$path\Q" ]]; then\E}{  if false; then}' \
  6

mutant "C1 looks for the 9<id> under the backup node only" \
  's{\Qls /etc/pve/nodes/*/lxc/\E\$CT_DR\Q.conf\E}{ls /etc/pve/nodes/\$BKP_NODE/lxc/\$CT_DR.conf}' \
  1 7

mutant "C1 computes the DR id with the copy offset" \
  's{\Q  CT_DR=\E\$\(\( ct \+ DR_OFFSET \)\)}{  CT_DR=\$(( ct + OFFSET ))}' \
  1

mutant "C1 falls back to the pmxcfs name when nothing maps it to an address" \
  's{\Q  if [[ -z "\E\$CT_FROM\Q" ]]; then\E}{  CT_FROM="\${CT_FROM:-\$CT_FROMNODE}"; if false; then}' \
  8

# ---------- C3: direction comes from provenance, never from a timestamp ------
# The one mistake here that cannot be undone. rsync preserves mtimes, so the
# copy's files can be NEWER on disk than the DR container's while holding older
# data - which is why the marker ct-distribute wrote is the only usable fact.
# A `#` line in a guest config is the DESCRIPTION field, PVE owns it, and PVE
# re-emits it URL-encoded every time it writes the config. ct-distribute writes
# the file directly, so a fresh placement matches and every round after anybody
# starts or stops the container does not. The fleet met this at the cutover,
# with both containers already shut down and nowhere else for the data to go.
mutant "C3 reads the config raw, so PVE's own encoding defeats it" \
  's|\$\(pve_decode "\$cfg"\)|\$cfg|' \
  52

mutant "C3 stops checking where the 9<id> came from" \
  's|  if ! printf .*grep -qxF "\$marker"; then|  if false; then|' \
  9 10

mutant "C3 builds the marker from the DR id instead of the copy it came from" \
  's!, from \$CT_TGT on !, from \$CT_DR on !' \
  1

mutant "C3 matches the marker loosely instead of as a whole line" \
  's{\Qgrep -qxF "\E\$marker\Q"\E}{grep -qF "# ct-distribute:"}' \
  10

# ---------- C4: the mode must match the state --------------------------------
mutant "C4 presyncs out of a stopped DR container as if it were a cutover" \
  's{\Q    if [[ "\E\$drstat\Q" != running ]]; then\E}{    if false; then}' \
  11

mutant "C4 takes a final delta out of a LIVE rootfs" \
  's{\Q    if [[ "\E\$drstat\Q" != stopped ]]; then\E}{    if false; then}' \
  12

mutant "C4 treats a node that did not answer as a stopped container" \
  's{\Q  if [[ -z "\E\$drstat\Q" ]]; then\E}{  if false; then}' \
  14

# ---------- C2: a promoted copy is somebody's decision, not ours -------------
mutant "C2 writes into a copy that is RUNNING on the backup node" \
  's{\Q  if [[ "\E\$cstat\Q" == running ]]; then\E}{  if false; then}' \
  16

# ---------- C5: the destination has to be a mounted dataset ------------------
# An unmounted dataset is an ordinary empty directory. Writing there fills the
# backup node's root filesystem and leaves the copy looking present and empty.
mutant "C5 writes into a dataset that is not mounted" \
  's{\Q  if [[ "\E\$dsmounted\Q" != yes || -z "\E\$CT_DSTMNT\Q" || "\E\$CT_DSTMNT\Q" == none ]]; then\E}{  if false; then}' \
  17

mutant "a row with no dest is read as a row that meant the first pool" \
  's{\Q  if [[ -z "\E\$dd\Q" ]]; then\E}{  if false; then}' \
  18

# ---------- C6: rsync out of a real mountpoint, read-only --------------------
# Reading a path nothing mounted copies an empty directory, and --delete on the
# far end then makes the copy match it. That is the failure with the cleanest
# log in this whole repo.
mutant "C6 trusts a dataset without checking it is really mounted" \
  's|    if ! rsh "\$CT_FROM" "mountpoint -q .*then|    if false; then|' \
  19

mutant "C6 mounts the DR volume read-write, with nobody holding it" \
  's{\Q    local mopt="-o ro,noload"; [[ "\E\$shape\Q" == image ]] && mopt="-o loop,ro,noload"\E}{    local mopt="-o rw"; [[ "\$shape" == image ]] && mopt="-o loop,rw"}' \
  4b

mutant "C6 replays a journal that was never cleanly closed" \
  's{\Qlocal mopt="-o ro,noload"; [[ "\E\$shape\Q" == image ]] && mopt="-o loop,ro,noload"\E}{local mopt="-o ro"; [[ "\$shape" == image ]] && mopt="-o loop,ro"}' \
  4b

mutant "C6 loop-mounts a block device and mounts a raw file without one" \
  's{\Q[[ "\E\$shape\Q" == image ]] && mopt="-o loop,ro,noload"\E}{[[ "\$shape" == block ]] \&\& mopt="-o loop,ro,noload"}' \
  4b 21

# ---------- C6, the running case: the mount that cannot be made --------------
# This is the bug the fleet found. The engine mounted the 9<id> volume
# read-only on every presync round, and LXC already had it mounted read-write
# for the container that was running on it - so ext4 refused, C6 fired, and
# every presync round failed. The guard held; what it was guarding was wrong.
mutant "C6 mounts a RUNNING container\'s device instead of reading its mount" \
  's|  elif \[\[ "\$drstat" == running \]\]; then|  elif false; then|' \
  1 4

mutant "C6 reads a path derived from a pid it never asked for" \
  's|    _pid=\$\(rsh "\$CT_FROM" "lxc-info.*|    _pid=1|' \
  1

mutant "C6 does not check the container root is one before reading it" \
  's|    if ! rsh "\$CT_FROM" "test -d .*then|    if false; then|' \
  51

mutant "C6 carries on when the mount failed" \
  's|    if ! rsh "\$CT_FROM" "mkdir -p .*then|    if false; then|' \
  20

# The call before the rc branch has a second net behind it - the per-container
# loop calls cleanup_ct too - so removing just that one is invisible. What is
# NOT invisible is the unmount itself failing to happen, which is what leaves a
# loop device and a mountpoint on a compute node in the middle of a DR.
mutant "nothing ever comes down: the read-only mount is left on the compute node" \
  's!\Qcleanup_ct(){\E\n\Q  [[ -n "\E\$CUR_MNT\Q" && -n "\E\$CUR_HOST\Q" ]] || return 0\E!cleanup_ct(){\n  return 0!' \
  4b

# ---------- the transfer itself ----------------------------------------------
mutant "rsync crosses into /proc, /sys, /dev and every extra mountpoint" \
  's{\Qrsync -aHAX -x --numeric-ids\E}{rsync -aHAX --numeric-ids}' \
  1

mutant "rsync loses --delete, so the copy keeps what the DR container deleted" \
  's{\Qrsync -aHAX -x --numeric-ids --sparse --delete --exclude=/.zfs --bwlimit=\E}{rsync -aHAX -x --numeric-ids --sparse --exclude=/.zfs --bwlimit=}' \
  1 5

# /g, because the source-destination pair now exists in BOTH transfer
# branches (tty progress and cron): inverting only the first would mutate
# the branch the simulator never runs, and the suite would call that a
# survivor.
mutant "the direction is inverted: the stale copy is written over the DR data" \
  "s!\\Q'\\E\\\$mnt\\Q/' '\\E\\\$BKP_SSH\\Q:\\E\\\$CT_DSTMNT\\Q/'\\E!'\\\$BKP_SSH:\\\$CT_DSTMNT/' '\\\$mnt/'!g" \
  1

mutant "the compute node's path to the backup node is no longer checked first" \
  's|  if ! rsh "\$CT_FROM" "ssh -o BatchMode=yes.*then|  if false; then|' \
  24

mutant "rsync 23 is treated as success, so a partial transfer reads as done" \
  's{\Q  if [[ "\E\$rc\Q" != 0 && "\E\$rc\Q" != 24 ]]; then\E}{  if false; then}' \
  26

mutant "rsync 24 is treated as a failure, so every live presync round fails" \
  's{\Q != 0 && "\E\$rc\Q" != 24 ]]; then\E}{ != 0 ]]; then}' \
  25

# ---------- C7: nothing here touches a container's lifecycle -----------------
# `pct destroy 9<id>` is what releases ct-replica's R13. Releasing that shield
# on data nobody has checked is the one thing this engine cannot undo, so it
# prints the command and stops.
mutant "C7 runs the destroy it is supposed to hand to another engine" \
  's!    log "\[\$ct\]     ct-prepare.sh --cleanup --ctid \$ct"!    rsh "\$CT_FROM" "pct destroy \$CT_DR"!' \
  29

# ---------- C8: both ends, locked where they live, in a fixed order ----------
mutant "C8 is gone: both ends are written with only a local flock held" \
  's{\Q  take_dst_lock "\E\$CT_FROM\Q" "\E\$CT_DR\Q"; _dl=\E\$\?}{  _dl=0}' \
  30 32

mutant "C8 does not lock the copy, only the container it reads" \
  's{\Q  take_dst_lock "\E\$\{BKP_SSH\#\*\@\}\Q" "\E\$CT_TGT\Q"; _dl=\E\$\?}{  _dl=0}' \
  30 33

mutant "C8 locks the copy first, so two engines can deadlock on a bad night" \
  's{\Q  take_dst_lock "\E\$CT_FROM\Q" "\E\$CT_DR\Q"; _dl=\E\$\?}{  take_dst_lock "\${BKP_SSH\#*\@}" "\$CT_TGT"; _dl=\$?}' \
  31

mutant "C8 treats an end that did not answer as a free lock" \
  's!\Q  esac\E\n\Q  return 2\E!  esac\n  return 0!' \
  34 35

mutant "C8 removes a lock without asking whether it is still ours" \
  's!\Q2>/dev/null && rm -f \E!2>/dev/null; rm -f !' \
  37

mutant "C8 releases by deleting the file, with no owner check at all" \
  's!\Qgrep -qxF \E\x27\$DST_LOCK_OWNER\x27\Q \E\x27\$f\x27\Q 2>/dev/null && \E!!' \
  30 37

mutant "C8 takes a lock with a plain redirect, so it overwrites whoever holds it" \
  's!\Qif (set -C; printf \E!if (printf !' \
  32

mutant "C8 locks one name for every container instead of the VMID" \
  's!\Qdst_lock_file(){ printf \E\x27\Q/run/ketsync-ct-%s.lock\E\x27\Q "\E\$1\Q"; }\E!dst_lock_file(){ printf \x27/run/ketsync-ct.lock\x27; }!' \
  32

mutant "the locks are never released, so one round wedges both ends for good" \
  's!\Qrelease_dst_locks(){\E\n\Q  local i h v f\E!release_dst_locks(){\n  return 0\n  local i h v f!' \
  30

# The obvious mutation here - make the second lock's refusal exit instead of
# returning - proves nothing, because the exit trap releases both anyway. What
# a scenario CAN see is a release loop that only reaches the lock it took last,
# which leaves the 9<id> locked on a compute node with nothing holding it.
mutant "only the lock taken last is ever released" \
  's!\Q  for (( i = \E\$\Q{#DST_LOCKS[@]} - 1; i >= 0; i-- )); do\E!  for (( i = \${#DST_LOCKS[\@]} - 1; i >= \${#DST_LOCKS[\@]} - 1; i-- )); do!' \
  30

mutant "a dry run takes both locks for real on two other machines" \
  's!\Q    peek_dst_lock "\E\$CT_FROM\Q" "\E\$CT_DR\Q"; _dl=\E\$\?!    take_dst_lock "\$CT_FROM" "\$CT_DR"; _dl=\$?!' \
  40

# ---------- the plumbing -----------------------------------------------------
mutant "--list writes as well as reads" \
  's{\Q  if (( LIST )); then st_ok "\E\$ct\Q" listed; return 0; fi\E}{  :}' \
  39

mutant "a --ctid nobody replicates runs over the whole fleet instead" \
  's{\Q  if (( ! \E\$\{\#_keep\[\@\]\}\Q )); then\E}{  if false; then}' \
  42

mutant "a filter that matches nothing exits 0, which under cron reads as healthy" \
  's{\Q(( FAILED || SKIPPED )) && exit 1\E}{:}' \
  3

mutant "the log is written two directories up whether ketsync is there or not" \
  's{\Qif [[ -f "\E\$BASE\Q/../../ketsync" && -f "\E\$BASE\Q/../../lib/common.sh" ]]; then\E}{if true; then}' \
  1

mutant "the engine reads the node map beside itself instead of ketsync's own" \
  's{\Qif [[ -f "\E\$BASE\Q/../bin/ketsync" && -f "\E\$BASE\Q/../lib/common.sh" && -f "\E\$BASE\Q/../conf/nodes.map" ]]; then\E}{if false; then}' \
  48

# ---------- the dest map's own format ----------------------------------------
mutant "the OLD key=dataset:storage-id map is read as though it worked" \
  's{\Q  if [[ "\E\$_e\Q" == *=* ]]; then\E}{  if false; then}' \
  49

# ---------- the copy's own .zfs -----------------------------------------------
# -x keeps this rsync out of the auto-mounted snapshots on the READING side and
# does nothing for the writing side. Without the exclude, --delete spends the
# round failing to unlink a read-only control directory - on the way back from
# a disaster, which is the worst hour this engine has.
mutant "the round is spent failing to delete the copy's own snapshot directory" \
  's{\Q--delete --exclude=/.zfs --bwlimit=\E}{--delete --bwlimit=}' \
  50

# ---------- the conf must read cleanly, whole ---------------------------------
# The dot returns the LAST line's status, so this is the bug as it was written:
# a broken line splashes an error, the source "succeeds", and every value that
# line was setting silently runs at the engine default. ctmig.conf did exactly
# this on the fleet - bw=500m against a ceiling set to 230 - and nothing but
# the splash said so.
mutant "a conf that half-reads runs on defaults, the way it used to" \
  's{\Q  if [[ -s "\E\$_conferr\Q" ]]; then\E}{  if false; then}' \
  54

echo
echo "=== $PASS mutations killed, $FAIL survived ==="
if (( FAIL > 0 )); then echo "survived: ${FAILED_NAMES[*]}"; exit 1; fi
exit 0
