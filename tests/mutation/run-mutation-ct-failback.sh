#!/usr/bin/env bash
# =============================================================================
#  run-mutation-failback.sh — check that the failback simulator can actually FAIL.
# -----------------------------------------------------------------------------
#  Same contract as run-mutation.sh, pointed at the engine that writes into
#  PRODUCTION images. A green suite means nothing until you have seen it go red
#  for the right reason: this takes ct-failback.sh, breaks one specific thing in
#  it, and runs the scenarios that are supposed to notice. A scenario that still
#  passes against a broken engine is not a test, it is decoration.
#
#  Every mutation is a literal-text edit anchored on a line of the engine. When
#  the anchor moves the mutation applies to nothing, and that is reported as a
#  failure too: a mutation that cannot be applied has stopped proving anything.
#  So any edit to ct-failback.sh must be mirrored here in the same change, and a
#  broken anchor is never "fixed" by deleting the mutation.
#
#  Each one is a bug a person could really write - a guard inverted, a check
#  moved back to where it used to live, a variable cleared one line too early.
#  A mutant that only proves bash still parses proves nothing.
#
#  usage:  ./tests/mutation/run-mutation-failback.sh
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SIM="$ROOT/tests/sim/ct-failback/run-sim-failback.sh"
SRC="$ROOT/engines/ct-failback.sh"
PASS=0; FAIL=0; FAILED_NAMES=()

command -v perl >/dev/null || { echo "perl is required for the mutation suite"; exit 1; }
[[ -x "$SIM" ]] || { echo "the failback simulator is not where this expects it: $SIM"; exit 1; }
[[ -r "$SRC" ]] || { echo "no engine to mutate: $SRC"; exit 1; }

# Extra environment for the NEXT mutant only, cleared again by mutant(). One
# mutation below is about what the engine takes from the process that started
# it - the PATH cron hands it - and that can only be said from outside the
# engine. Nothing else uses this.
RUN_ENV=()

# $1 = name, $2 = perl s{}{} program, rest = scenarios that MUST fail on it
mutant(){
  local name="$1" prog="$2"; shift 2
  local m ok=1 s
  m="$(mktemp /tmp/ctback-mutant.XXXXXX)"
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

echo "=== ct-failback.sh mutation suite ==="

# ---------- B1: the production CT is stopped, or we do not write -------------
# The image this engine writes into is the rootfs of a real container. If that
# container is up on its own node the image is mounted there too, and a second
# mount here is ext4 corruption of the live customer system.

# B7. The safety snapshot before --final is the only way back from a round that
# overwrites the production image, and this used to be a WARN that carried on.
# Found on real hardware: every CT stopped at B1 because this host could not
# ssh to the compute nodes, and nothing had ever said failback needed that.
# --list is where you find out on an ordinary Tuesday - so it must say so, and
# it must not exit 0 while saying it.
mutant "--list reports an unreachable production node and still exits 0" \
  's{\Qlog "  this host needs root ssh to each of those addresses, before you need it:"\E}{:; exit 0; :}' \
  53

mutant "a copy id typed by mistake gets no hint about the source id" \
  's{\Qis the COPY of CT \E}{is not resolvable, full stop, }' \
  55

mutant "a safety snapshot that fails is a warning again, and the write proceeds" \
  's{\Qno_undo_point -1\E\n\Q        return 1\E}{no_undo_point -1\n        :}' \
  36

mutant "--no-snapshot is assumed, so nobody has to ask for it" \
  's{\Qelif (( NO_SNAPSHOT )); then\E}{elif true; then}' \
  36

mutant "an absent inventory is reported as an empty one" \
  's{\Qif [[ -f "\E\$INV\Q" ]]; then log "ERROR: \E\$INV\Q names no CT, and no --ctid was given - nothing to do"\E}{if true; then log "ERROR: \$INV names no CT, and no --ctid was given - nothing to do"}' \
  13b

mutant "B1 accepts a production CT that is still running" \
  's{\Q  if [[ "\E\$CT_PSTAT\Q" != "stopped" ]]; then\E}{  if false; then}' \
  15 17

mutant "B1 counts a production node it cannot reach as stopped" \
  's{\Q  if [[ -z "\E\$CT_PSTAT\Q" ]]; then\E}{  if [[ -z "\$CT_PSTAT" ]]; then CT_PSTAT=stopped; fi\n  if false; then}' \
  16

# B1 asks the production node itself, at the ADDRESS nodes.map resolved. Two
# ways that goes wrong and neither one crashes: the lookup is dropped and the
# pmxcfs name is used as a hostname on a host with no resolver (every CT
# refused, which is the incident that started all this), or the lookup silently
# guesses when the map has no row (the WRONG machine is asked whether a
# container is stopped, and then the right machine's image is written into).
mutant "the node-map lookup is dropped, so B1 ssh's to a name this host cannot resolve" \
  's{\Q  CT_HOST="\E\$\Q(node_ip "\E\$CT_NODE\Q")"; CT_HOST="\E\$\{CT_HOST:-\$CT_NODE\}\Q"\E}{  CT_HOST="\$CT_NODE"}' \
  15 53

mutant "node_ip returns the first row rather than the matching one" \
  's{\Q && \E\$2\Q==n{print \E\$1\Q; exit}\E}{ {print \$1; exit}}' \
  15 17

# ---------- B2: something has to be shielding the copy -----------------------
# Presync leans on ct-replica's R2, which only skips a copy while it RUNS.
# Once the copy is down the only thing left is PAUSE, and without it the next
# cron tick overwrites the DR data with the stale production image - which this
# run would then pull back over the customer's rootfs.

mutant "B2 presyncs from a copy that is not running" \
  's{\Q    if [[ "\E\$CT_CSTAT\Q" != "running" ]]; then\E}{    if false; then}' \
  18

mutant "B2 allows --final while the copy is still up" \
  's{\Q    if [[ "\E\$CT_CSTAT\Q" != "stopped" ]]; then\E}{    if false; then}' \
  19

mutant "B2 allows --final with no PAUSE file" \
  's{\Qif (( FINAL )) && [[ ! -f "\E\$BASE\Q/PAUSE" ]]; then\E}{if false; then}' \
  20

# The regression itself, put back verbatim: the check that skips itself as soon
# as the run is dry. That is what the engine did until this commit, and it is
# the only DRY gate here that ever changed what was CHECKED rather than what was
# written - so a dry run reported a clean plan for a --final that would refuse.
mutant "B2 stops checking PAUSE again as soon as the run is dry" \
  's{\Qif (( FINAL )) && [[ ! -f "\E\$BASE\Q/PAUSE" ]]; then\E}{if (( FINAL )) \&\& (( ! DRY )) \&\& [[ ! -f "\$BASE/PAUSE" ]]; then}' \
  22

# ---------- B3: an unmounted dataset is a directory on the node root ---------

mutant "B3 restores into an image that sits on the node root filesystem" \
  's{\Q  if [[ -z "\E\$holder\Q" || "\E\$holder\Q" == "/" ]]; then\E}{  if false; then}' \
  23

# ---------- B4: a missing image is a rebuild, and it must say so -------------

mutant "B4 carries on when the image does not exist" \
  's{\Q  if [[ ! -f "\E\$CT_IMG\Q" ]]; then\E}{  if false; then}' \
  25

# B4 used to sit BELOW B3, and that ordering was a real 3am cost: findmnt -T on
# a path that does not exist exits 1 with no output, B3 reads the empty answer
# as "the dataset is not mounted", and the operator is sent to run `zfs mount -a`
# against a filesystem that was fine. Nothing is damaged either way - the row is
# refused - but B4's message is unreachable in the one case it was written for.
mutant "B4 is back below B3, so a missing image reads as an unmounted dataset" \
  's{\Q  if [[ ! -f "\E\$CT_IMG\Q" ]]; then\E(.*?)\Q  fi\E\n\Q  holder=\E\$\Q(findmnt -no TARGET -T "\E\$CT_IMG\Q" 2>/dev/null | head -1)\E\n\Q  if [[ -z "\E\$holder\Q" || "\E\$holder\Q" == "/" ]]; then\E(.*?)\Q  fi\E\n}{  holder=\$(findmnt -no TARGET -T "\$CT_IMG" 2>/dev/null | head -1)\n  if [[ -z "\$holder" || "\$holder" == "/" ]]; then$2  fi\n  if [[ ! -f "\$CT_IMG" ]]; then$1  fi\n}s' \
  25

# ---------- B5: mounted, verified, and unmounted again before any resize -----

mutant "B5 leaves a stale mount from an earlier run in place" \
  's{\Q  if mountpoint -q "\E\$MNT\Q"; then\E}{  if false; then}' \
  27 28

# Two shapes of the same simplification. The first drops ONLY the verification
# and keeps mount's exit code, which is the edit somebody would actually make -
# it is invisible until the fake mount is told to report success without
# mounting (scenario 43), the kernel path where a loop device is exhausted or
# the filesystem will not mount. The second takes the whole pair.
mutant "B5 trusts mount's exit code and drops the verification" \
  's{\Q  if ! mountpoint -q "\E\$MNT\Q"; then\E\n.*?\Q  fi\E\n\Q  CUR_MNT="\E\$MNT\Q"\E\n}{  CUR_MNT="\$MNT"\n}s' \
  43

mutant "B5 trusts the loop-mount instead of checking it took" \
  's{\Q  if ! mount -o "\E\$MOPT\Q" "\E\$CT_IMG\Q" "\E\$MNT\Q" >>"\E\$LOG\Q" 2>&1; then\E\n.*?\Q  fi\E\n\Q  if ! mountpoint -q "\E\$MNT\Q"; then\E\n.*?\Q  fi\E\n}{  mount -o "\$MOPT" "\$CT_IMG" "\$MNT" >>"\$LOG" 2>\&1\n}s' \
  26

mutant "B5 never records the mount, so the exit trap has nothing to unmount" \
  's{\n\Q  CUR_MNT="\E\$MNT\Q"\E\n}{\n  : "\$MNT"\n}' \
  42 1

# THE ONE THIS FILE EXISTS FOR. cleanup_ct used to clear CUR_MNT
# unconditionally: it logged a WARN when the umount failed and then cleared it
# anyway. The grow loop's own gate is `is CUR_MNT still set`, so that single
# line disarmed it - truncate, e2fsck and resize2fs all ran against a still
# mounted customer image, mount -o loop put a second loop on top, the retry
# succeeded and the run reported ok. It is ct-migrate's G3 relearned in the
# direction where the image is somebody's live rootfs.
mutant "cleanup_ct clears CUR_MNT again even when the umount failed" \
  's{\Q      return 1                      # leaves CUR_MNT set: nothing may resize now\E}{      CUR_MNT=""; return 1}' \
  31

# ---------- B6: ENOSPC grows the image, bounded, and never while mounted -----

mutant "B6 grows without bound" \
  's{\Q  while [[ \E\$rc\Q -eq 11 && \E\$attempt\Q -lt \E\$GROW_MAX_RETRY\Q ]] && (( ! DRY )); do\E}{  while [[ \$rc -eq 11 ]] && (( ! DRY )); do}' \
  30

mutant "B6 grows the image with the gate on CUR_MNT removed" \
  's{\Q    if [[ -n "\E\$CUR_MNT\Q" ]]; then log "[\E\$ct\Q] GUARD B5: still mounted after ENOSPC - refusing to resize"; break; fi\E\n}{}' \
  31

mutant "the image is not unmounted before the grow loop starts" \
  's{\n\Q  cleanup_ct\E\n\n\Q  # --- B6:\E}{\n\n  # --- B6:}' \
  29

# 11 is out of space; 12 is a protocol error and is not this. Reading the wrong
# one strands a failback on a full image at the worst possible moment.
mutant "ENOSPC is read as rc 12, so a full image strands the failback" \
  's{\Q[[ \E\$rc\Q -eq 11 && \E}{[[ \$rc -eq 12 \&\& }' \
  29 30

# ---------- not guards, but a silent success is worse than a loud failure ----

# Under cron, exit 0 with no work done during a disaster reads as "all back".
mutant "a --dest that matched no row still exits 0" \
  's{\Qif (( matched == 0 )) && [[ -n "\E\$ONLY_DEST\Q" ]]; then\E}{if false; then}' \
  9

# Scenario 39 used to be the third witness here. It no longer is: an
# unreachable backup node is now refused for the whole run before any CT is
# read, so it never reaches this counter. 11 and 12 still do - a CT that is not
# in the cluster at all, and a CT that turns out to be a copy.
mutant "a CT that cannot be resolved is skipped quietly instead of failing" \
  's{\Q    failed=\E\$\Q(( failed + 1 )); FAILED_IDS+=("\E\$ct\Q"); continue\E}{    continue}' \
  11 12

# 0 and 24 are success; 23 is a partial transfer, which leaves the customer's
# rootfs half written and would be handed over as ready to start.
mutant "rc=23 (a partial transfer) counts as success" \
  's{\Q  if [[ \E\$rc\Q -ne 0 && \E\$rc\Q -ne 24 ]]; then\E}{  if [[ \$rc -ne 0 \&\& \$rc -ne 24 \&\& \$rc -ne 23 ]]; then}' \
  33

# The snapshot is the operator's only way back to the pre-failback image.
mutant "the safety snapshot before --final is dropped" \
  's{\Q  if (( FINAL )) && (( ! DRY )); then\E}{  if false; then}' \
  34 36

# A snapshot taken after the image is opened for writing is not a safety net,
# it is a snapshot of the damage.
mutant "the safety snapshot is taken after the image is mounted" \
  's{\Q  # --- safety net, only before the first write of the final round ---\E(.*?)\Q  # --- B5: mount read-write, verified ---\E(.*?)\Q  CUR_MNT="\E\$MNT\Q"\E\n}{  # --- B5: mount read-write, verified ---$2  CUR_MNT="\$MNT"\n  # --- safety net, only before the first write of the final round ---$1}s' \
  34

# --dry-run is what an operator runs to find out whether the copies are ready.
# It has to be readable without being a restore.
mutant "--dry-run is no longer read-only" \
  's{\Q(( DRY )) && RS+=(-n)\E\n}{}' \
  14 22

# The mount is the other half, and it is the one that shipped broken: a dry run
# loop-mounted the production image READ-WRITE, which replays the ext4 journal
# and rewrites the superblock before a byte has moved. The scenarios did not
# catch it because they asserted on the image's CONTENT, which a journal replay
# does not change. The SIM_DRY invariant does catch it, which is the point of
# having one.
mutant "--dry-run mounts the production image read-write again" \
  's{\QMOPT=loop; (( DRY )) && MOPT=loop,ro,noload\E}{MOPT=loop}' \
  14 22

# Two failbacks on one CT means two rsync --delete runs into one image.
mutant "the per-CT lock is never contended" \
  's{\Qflock -n 8\E}{true}' \
  40

# Deleting the value check leaves `ONLY_CTID="$2"` with nothing in $2, which
# set -u turns into an immediate death. That is deliberate: restoring the old
# `${2:-}` with `shift 2 || true` would make the mutant SPIN INSTEAD OF DYING
# and this runner would wait for it forever. A mutation has to fail fast.
# The delimiter is ! rather than {} because the anchor contains a brace pair.
mutant "a flag with no value is accepted instead of refused" \
  's! \Q|| { echo "--ctid needs a value" >&2; exit 2; }\E!!' \
  44

# Rule 8: cron hands a job PATH=/usr/bin:/bin, and pvesm, zfs, e2fsck and
# resize2fs all live in sbin. cron's real PATH cannot show that here - the
# simulator hands the engine those tools as exported shell functions, which
# bash finds whatever PATH says, and every real tool left is in /usr/bin on any
# node this runs on. So the caller this mutation gets is one whose PATH leads to
# a flock that refuses, which is what a missing or shadowed tool looks like from
# inside the engine: every CT reports as locked by somebody else and the
# failback does nothing. The engine that sets its own PATH never looks there,
# and the check below proves the poisoned PATH alone is not what killed the
# scenario.
CRONBIN="$(mktemp -d /tmp/ctback-cronbin.XXXXXX)"
printf '#!/bin/sh\nexit 1\n' > "$CRONBIN/flock"; chmod +x "$CRONBIN/flock"
if PATH="$CRONBIN:$PATH" "$SIM" 1 >/dev/null 2>&1; then
  RUN_ENV=("PATH=$CRONBIN:$PATH")
  mutant "the engine no longer sets its own PATH" \
    's{\QPATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\E\n}{}' \
    1
else
  echo "  [the engine no longer sets its own PATH]"
  echo "      x scenario 1 already fails on the UNMUTATED engine under this PATH"
  echo "      x - the check would have proven nothing, so it did not run"
  FAIL=$((FAIL+1)); FAILED_NAMES+=("the engine no longer sets its own PATH")
fi
rm -rf "$CRONBIN"

# ---------- the log is a deliverable, not a side effect --------------------
# A daily log holds dozens of rounds. Without the rule between operations the
# reader is parsing timestamps to find where one container ends and the next
# begins, at the hour when that is hardest.
mutant "the operation separator is dropped from the log" \
  's{LOGSEP=.#+.}{LOGSEP=""}' \
  1

# ---------- the rsync option set ---------------------------------------------

mutant "the restore stops being --delete, so files deleted during DR come back" \
  's{\Q-aHAX --numeric-ids --delete --inplace\E}{-aHAX --numeric-ids --inplace}' \
  1

mutant "the bandwidth ceiling is dropped from the restore" \
  's{\Q "--bwlimit=\E\$BWLIMIT\Q"\E}{}' \
  1

# ---------- the backup node's identity ---------------------------------------
# This engine uses the name to tell a copy from a production CT. A wrong one
# points a restore at the wrong side of the transfer, and an absent one means
# there is no connection to the machine every question goes through.

mutant "a backup node that will not say who it is is carried on with anyway" \
  's{\Qif [[ -z "\E\$_bknode\Q" ]]; then\E}{if false; then}' \
  39

mutant "a pinned BKP_NODE is adopted instead of checked" \
  's{\Qelif [[ "\E\$_bknode\Q" != "\E\$BKP_NODE\Q" ]]; then\E}{elif false; then}' \
  38b


# ---------- the three levels of rule --------------------------------------
# Flattening them back to one is invisible until the night somebody is
# scrolling a daily log for the container that did not come back, and every
# boundary in it looks the same. It costs nothing to write and it is exactly
# the kind of line a later reader tidies away.
mutant "every rule is the same again, so no boundary says which kind it is" \
  's{\QLOGSEP2=\E.=+.}{LOGSEP2="\$LOGSEP"}' \
  1

mutant "the container list never opens or closes, only the run does" \
  's{^(\s*)hr_ct$}{\$1hr}m' \
  1
# ---------- the one log tree ------------------------------------------------
# Both layers write into ketsync's logs/ when this engine is vendored inside
# it, which it always is on a real install. The walk-up is GUARDED, because an
# engine that has been copied somewhere else would otherwise write two
# directories above itself - into somebody's home, or /, or whatever happens to
# sit there. Every simulator sandbox takes the guarded path, which is what
# makes both of these observable.
mutant "the log is written two directories up whether ketsync is there or not" \
  's!\Qif [[ -f "\E\$BASE\Q/../bin/ketsync" && -f "\E\$BASE\Q/../lib/common.sh" ]]; then\E\n\Q  LOGDIR="\E\$\Q(cd "\E\$BASE\Q/.." && pwd)/logs"\E!if true; then\n  LOGDIR="\$(cd "\$BASE/.." \&\& pwd)/logs"!' \
  1

mutant "the fallback log directory is not the engine's own" \
  's{\QLOGDIR="\E\$BASE\Q/logs"\E}{LOGDIR="\$BASE/../logs"}' \
  1

# ---------- ketsync's node map, not a copy of it ----------------------------
# The copy this replaced was refreshed by `ketsync doctor` and by nothing else,
# so a machine that had been SENT the tables was still reading a file nobody
# had written - see the note in ct-distribute.sh.
mutant "the engine reads the node map beside itself instead of ketsync's own" \
  's{\Qif [[ -f "\E\$BASE\Q/../bin/ketsync" && -f "\E\$BASE\Q/../lib/common.sh" && -f "\E\$BASE\Q/../conf/nodes.map" ]]; then\E}{if false; then}' \
  57

# ---------- B8: the lock lives on the machine holding the copy ---------------
# The local lock here is keyed on the PRODUCTION id and ct-replica's is keyed
# on the COPY id, so even on one machine those two never excluded each other -
# and this engine reads a copy that ct-replica writes. Across machines a flock
# says nothing at all. Every mutation below is the shape of that bug.
# The delimiter is ! where an anchor closes a shell function: perl balances a
# brace inside s{}{} against its own delimiter.
mutant "B8 is gone: the copy is read with only a local lock held" \
  's!\Q    take_dst_lock "\E\$BKP_SSH\Q" "\E\$CT_TGT\Q"; _dl=\E\$\?!    _dl=0!' \
  58 59

mutant "B8 treats a destination that did not answer as a free lock" \
  's!\Q  esac\E\n\Q  return 2\E!  esac\n  return 0!' \
  60

mutant "B8 removes the lock without asking whether it is still ours" \
  's!\Q2>/dev/null && rm -f \E!2>/dev/null; rm -f !' \
  64

mutant "B8 releases by deleting the file, with no owner check at all" \
  's!\Qgrep -qxF \E\x27\$DST_LOCK_OWNER\x27\Q \E\x27\$f\x27\Q 2>/dev/null && \E!!' \
  58 64

mutant "B8 takes the lock with a plain redirect, so it overwrites whoever holds it" \
  's!\Qif (set -C; printf \E!if (printf !' \
  59

mutant "B8 locks a name of its own instead of the copy's VMID" \
  's!\Qdst_lock_file(){ printf \E\x27\Q/run/ketsync-ct-%s.lock\E\x27\Q "\E\$1\Q"; }\E!dst_lock_file(){ printf \x27/run/ketsync-ct.lock\x27; }!' \
  59

mutant "B8 names the holder and then reads the copy anyway" \
  's!\Q      log "[\E\$ct\Q] GUARD B8:   round and half of another into the production image."\E\n\Q      skipped=\E\$\(\( skipped \+ 1 \)\)\Q; continue\E!      skipped=\$(( skipped + 1 ))!' \
  59

mutant "the lock is only released between containers, never when the run ends" \
  's!\Qrelease_dst_lock(){\E\n\Q  [[ -n "\E\$DST_LOCK_ID\Q" ]] || return 0\E!release_dst_lock(){\n  return 0!' \
  58

mutant "a dry run takes the lock for real on another machine" \
  's!\Q    peek_dst_lock "\E\$BKP_SSH\Q" "\E\$CT_TGT\Q"; _dl=\E\$\?!    take_dst_lock "\$BKP_SSH" "\$CT_TGT"; _dl=\$?!' \
  63

# ---------- B2's third case: a stopped copy that R13 is holding ---------------
# The disaster this fleet actually has does not promote the copy at all. The
# data goes to a compute node as 9<id> and the copy on the backup node stays
# STOPPED for the whole outage, shielded by R13 rather than R2. Refusing to
# presync it means no delta is possible until cutover, so the single round at
# cutover carries every byte written since the outage began.
mutant "B2 refuses a stopped copy again, whatever is holding it" \
  's!\Q      if [[ -n "\E\$_dract\Q" ]]; then\E!      if false; then!' \
  66

mutant "B2 looks for the DR container under the backup node only" \
  's!\Qls /etc/pve/nodes/*/lxc/\E\$_dr\Q.conf\E!ls /etc/pve/nodes/\$BKP_NODE/lxc/\$_dr.conf!' \
  68

mutant "B2 computes the DR id with the copy offset, so it never finds one" \
  's!\Q      _dr=\E\$\(\( ct \+ DR_OFFSET \)\)!      _dr=\$(( ct + OFFSET ))!' \
  66

mutant "B2 reads any stopped copy, holder or not" \
  's!\Q        st_write "\E\$ct\Q" skipped b2_copy_not_running -1\E\n\Q        return 2\E!        :!' \
  67

# ---------- the dest map's own format ----------------------------------------
# This engine had no validation on that map at all, so an old entry parsed as a
# key of `hdd=replica-hdd/ct` and every row silently fell through to
# DEFAULT_DEST. One file, four engines, one refusal - worded identically.
mutant "the OLD key=dataset:storage-id map is read as though it worked" \
  's{\Q  if [[ "\E\$_kv\Q" == *=* ]]; then\E}{  if false; then}' \
  70

# ---------- the way out of the checklist --------------------------------------
# The seven-step tail is where an operator stands at the end of the worst day,
# and `ketsync recover --all` is that list as one command. A refactor that
# tidies the pointer away sends them back to typing seven commands from a log.
mutant "the pointer to the one-command return is tidied away" \
  's{\Q  log "  or all of it, state-driven and re-runnable:  ketsync recover --all"\E\n}{}' \
  21

# ---------- the exclude list, which is shared with replication ----------------
# This engine runs rsync --delete in the OTHER direction. A pattern that only
# ct-replica.sh honoured is a path the copy never had, and this engine then
# deletes it from PRODUCTION. That is why there is one file and why a missing
# one refuses rather than falling back to anything.
mutant "a missing exclude list is carried past, on the return path" \
  's{\Q  echo "ERROR: the exclude list is missing: \E\$\QEXCL" >&2\E}{  : "\$EXCL"}' \
  72

mutant "the site's list is ignored here, so the return deletes what it never copied" \
  's!\Q    "--exclude-from=\E\$\QEXCL"\E!    \x27--exclude=/tmp/*\x27!' \
  71

# ---------- the conf must read cleanly, whole ---------------------------------
# The dot returns the LAST line's status, so this is the bug as it was written:
# a broken line splashes an error, the source "succeeds", and every value that
# line was setting silently runs at the engine default. ctmig.conf did exactly
# this on the fleet - bw=500m against a ceiling set to 230 - and nothing but
# the splash said so.
mutant "a conf that half-reads runs on defaults, the way it used to" \
  's{\Q  if [[ -s "\E\$_conferr\Q" ]]; then\E}{  if false; then}' \
  73

# ---------- one log directory, really -----------------------------------------
# The walk-up that puts the log in the repo root is one line; making it a no-op
# is the bug as it lived for a year - every engine keeping a second log
# directory under engines/ while the README promised one directory to read.
mutant "the log quietly goes back to a second directory under engines/" \
  's!\Q  LOGDIR="\E\$\Q(cd "\E\$BASE\Q/.." && pwd)/logs"\E!  :!' \
  57

# ---------- the log a person can follow ---------------------------------------
# Per-CT files, the once-a-minute progress line, and the byte wall that used to
# follow every transfer. Each mutation is the feature quietly not happening -
# which is exactly what it looked like before it existed.
mutant "the second tee is gone - no per-CT file is ever written" \
  's{\Q_tee(){ if [[ -n "\E\$CT_LOG\Q" ]]; then tee -a "\E\$LOG\Q" "\E\$CT_LOG\Q"; else tee -a "\E\$LOG\Q"; fi; }\E}{_tee(){ tee -a "\$LOG"; }}' \
  74

mutant "CT_LOG is never set, so every line goes to the day log alone" \
  's!\Q  CT_LOG="\E\$LOGDIR\Q/ct/failback-\E\$ct\Q-\E\$\Q(date +%F).log"\E!  :!' \
  74

mutant "CT_LOG survives the loop, and the run summary leaks into the last CT's file" \
  's!\QCT_LOG=""                      # the summary below belongs to the run, not to a CT\E!:!' \
  74

mutant "the progress line is never printed - cron rounds go back to silence" \
  's!\Q        log "[\E\$_ct\Q] progress: \E\$\Q(hsize "\E\$_b\Q") (\E\$\{BASH_REMATCH\Q[2]}%) in \E\$_el\Q at \E\$\{BASH_REMATCH\Q[3]}"\E!        :!' \
  74

mutant "the once-a-minute limit is gone - every update becomes a log line" \
  's!\Q        [[ -n "\E\$_last\Q" ]] && (( SECONDS - _last < 60 )) && continue\E!        :!' \
  74

mutant "the stats byte wall lands in the log again" \
  's!\Q        :  # the raw --stats block - parsed from the stats file, said once, in units\E!        log "[\$_ct] rsync: \$_l"!' \
  74

# rc=$? would NOT be this bug: pipefail is on, so $? of the pipeline is still
# rsync's rc. The bug a person writes is the wrong INDEX - the filter is the
# last element, its rc is always 0, and every failed sync reads as green.
mutant "the rc judged is the filter's, not rsync's - every failed sync reads as green" \
  's!\Q    rc=\E\$\Q{PIPESTATUS[0]}\E!    rc=\${PIPESTATUS[1]}!' \
  33

mutant "the interrupt is swallowed by the pipeline - Ctrl-C no longer ends the run" \
  's!\Qtrap '"'"'exit 130'"'"' INT\E!: !' \
  42

# ---------- B9: the intake image lock ------------------------------------------
# Scenario 1 dies on both of these through the rsync fake's standing probe: a
# write-back into the production image while the lock is free is a violation,
# so removing the take breaks every scenario that moves bytes, not just the
# busy one.
mutant "B9 is never taken - the write-back no longer announces itself" \
  's{\Q  if ! take_intake_lock "\E\$\Qct"; then\E}{  if false; then}' \
  75 1

mutant "the busy answer is thrown away - flock -n says no and the write-back happens anyway" \
  's{\Q  if flock -n 7; then INTAKE_LOCK="\E\$\Q1"; return 0; fi\E}{  if true; then INTAKE_LOCK="\$1"; return 0; fi}' \
  75 1

echo
echo "=== $PASS mutations killed, $FAIL survived ==="
if (( FAIL > 0 )); then echo "survived: ${FAILED_NAMES[*]}"; exit 1; fi
exit 0
