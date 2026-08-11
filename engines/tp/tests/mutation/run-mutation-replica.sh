#!/usr/bin/env bash
# =============================================================================
#  run-mutation-replica.sh — check that the replica simulator can actually FAIL.
# -----------------------------------------------------------------------------
#  Same contract as run-mutation.sh, pointed at the other engine: a green suite
#  means nothing until you have seen it go red for the right reason. This takes
#  ct-replica.sh, breaks one specific thing in it, and runs the scenarios that
#  are supposed to notice. A scenario that still passes against a broken engine
#  is not a test, it is decoration.
#
#  Every mutation is a literal-text edit anchored on a line of the engine. When
#  the anchor moves the mutation applies to nothing, and that is reported as a
#  failure too: a mutation that cannot be applied has stopped proving anything.
#  So any edit to ct-replica.sh must be mirrored here in the same change, and a
#  broken anchor is never "fixed" by deleting the mutation.
#
#  Each mutation is a bug a person could really write: a guard inverted, a
#  check moved back to where it used to be, a "helpful" log line added in the
#  one function that must never print. Nothing here corrupts the engine at
#  random - a mutant that only proves bash still parses proves nothing.
#
#  usage:  ./tests/mutation/run-mutation-replica.sh
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SIM="$ROOT/tests/sim/replica/run-sim-replica.sh"
SRC="$ROOT/ct-replica.sh"
PASS=0; FAIL=0; FAILED_NAMES=()

command -v perl >/dev/null || { echo "perl is required for the mutation suite"; exit 1; }
[[ -x "$SIM" ]] || { echo "the replica simulator is not where this expects it: $SIM"; exit 1; }

# Extra environment for the NEXT mutant only, cleared again by mutant(). Two
# mutations below are about what the engine takes from the process that started
# it - the PATH it inherits, and whether a tool exists at all - and the world
# outside the engine is the only place that can be said. Each one carries its
# own comment; nothing else uses this.
RUN_ENV=()

# $1 = name, $2 = perl s{}{} program, rest = scenarios that MUST fail on it
mutant(){
  local name="$1" prog="$2"; shift 2
  local m ok=1 s
  m="$(mktemp /tmp/ctrep-mutant.XXXXXX)"
  echo "  [$name]"
  # perl's own exit status matters. A program that does not compile writes
  # nothing, and an EMPTY mutant "kills" every scenario - it does nothing at
  # all - so the suite would report a green tick for a mutation that was never
  # applied. Half an engine is the same failure one step less obvious.
  # This file went without either check while CLAUDE.md said it had both, and
  # it guards the engine that has never run against a real node.
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

# The runner's own safety net, exercised before it grades anything. This file
# is the reason the check exists at all: it went without both guards inside
# mutant() while CLAUDE.md said it had them, guarding the engine that has never
# run against a real node. Each probe calls mutant() for real inside a command
# substitution, so its counters and its output are thrown away and only the
# refusal is read. The two probes are different failures on purpose: the first
# makes perl exit non-zero and write nothing, the second lets perl succeed and
# produce an empty file. A runner that cannot refuse both stops here.
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

echo "=== ct-replica.sh mutation suite ==="

# ---------- R1: the bytes come out of a point in time, or not at all ---------

# The preflight that names a missing tool has to run BEFORE the lock. With no
# flock, `flock -n 9` is command-not-found - a non-zero exit, indistinguishable
# from "somebody else holds the lock" - so the engine says it is skipping and
# returns 0. Disarming the preflight puts that hole straight back.
# One CT held back by hand, and a whole storage being down. Both are SKIPPED
# rather than failed, and both must still be visible: a pause nobody undoes and
# a storage nobody notices are the same disaster - a container with no DR copy
# and nothing saying so.
mutant "a paused CT is copied anyway" \
  's{\Qst_skip paused; continue\E}{:; }' \
  60

mutant "a storage that is down exits 0, because the CTs only count as skipped" \
  's{\Qif (( _down )); then\E\n\Q  [[ -n "\E\$HEALTH_URL\Q" ]] && { curl -fsS -m 10 "\E\$HEALTH_URL\Q/fail" >/dev/null 2>&1 || true; }\E\n\Q  exit 1\E}{if false; then\n  :\n  :}' \
  62

mutant "the required-command preflight is reported but not obeyed" \
  's{\Qlog "ERROR:   this script sets PATH itself, so a miss here means the tool is genuinely absent"\E\n\Q  exit 2\E}{log "ERROR:   this script sets PATH itself, so a miss here means the tool is genuinely absent"\n  :}' \
  58

mutant "R1 reads the images off the LIVE dataset instead of the clone" \
  's{\Q    PREP_ROOT[\E\$\Qp]="\E\$\Q{cm}\E\$\Q{rel}"\E}{    PREP_ROOT[\$p]="\$p"}' \
  1 2 3

mutant "R1 accepts a clone that is not mounted" \
  's{\Q    if [[ -z "\E\$\Qcm" || "\E\$\Qcm" == "none" ]] || ! mountpoint -q "\E\$\Qcm"; then\E}{    if false; then}' \
  8

# ---------- R2: a RUNNING copy is the promoted DR system ---------------------

mutant "R2 syncs into a copy that is RUNNING" \
  's{\Q  if [[ "\E\$\Qst" == "running" ]]; then\E}{  if false; then}' \
  9

# ---------- R3: an unmounted dataset is a directory on the backup root fs ----

mutant "R3 no longer asks whether the destination dataset is mounted" \
  's{\Q  if [[ "\E\$\Q{tmounted:-}" != "yes" || -z "\E\$\Q{tmnt:-}" || "\E\$\Qtmnt" == "none" ]]; then\E}{  if false; then}' \
  10

# ---------- R4: the id must be free BEFORE rsync --delete runs ---------------
# The one that matters most in this file. R4 sat next to the config write until
# today, which meant it ran after the transfer and only when the copy was new -
# so a STOPPED guest on another node holding that id was noticed one step after
# rsync --delete had already emptied its rootfs. This puts it back exactly
# there: after the sync, inside the first-creation branch.

mutant "R4 runs after the transfer again, and only when the copy is new" \
  's{(\Q  # --- R4: the target VMID must not belong to any OTHER guest, anywhere ---\E.*?\Qst_fail r4_vmid_taken; continue\E\n\Q  fi\E\n)(.*?)(\Q  if [[ -z "\E\$\Qtgtcfg" ]]; then\E\n)}{$2$3$1}s' \
  12

# ---------- R5: judge the sync, then write the config, then read it back -----

mutant "R5 writes the copy config even when the sync failed" \
  's{\Q    st_fail r5_rsync; continue\E}{    st_fail r5_rsync}' \
  13 16

mutant "R5 trusts the config write instead of reading it back" \
  's{\Q.conf" \E\\\n\Q       && \E.*?\Q; then\E}{.conf"; then}s' \
  17

mutant "R5 counts rc=23 (a partial transfer) as success" \
  's{\Q  if [[ \E\$\Qrc -ne 0 && \E\$\Qrc -ne 24 ]]; then\E}{  if [[ \$rc -ne 0 && \$rc -ne 24 && \$rc -ne 23 ]]; then}' \
  13 14

# ---------- R6: read-only, and no journal replay into the clone --------------

mutant "R6 loop-mounts the image read-write" \
  's{\Qmount -o loop,ro,noload\E}{mount -o loop,rw}' \
  1 2

mutant "R6 loop-mounts without noload, so the journal is replayed" \
  's{\Qmount -o loop,ro,noload\E}{mount -o loop,ro}' \
  1 2

# ---------- R7: two lanes must not share a point-in-time source --------------

mutant "R7 drops the lane from the snapshot and clone names" \
  's{\Qsnap="ctrep-\E\$\QLANE"\E}{snap="ctrep"};s{\Qctrep-clone-\E\$\QLANE-\E}{ctrep-clone-}' \
  2 29

# ---------- R8: an existing copy config must agree with the row --------------

mutant "R8 lets an existing copy config point at another dest" \
  's{\Q    if [[ "\E\$\Qcsid" != "\E\$\Q{DEST_SID[\E\$\QDEST]}" ]]; then\E}{    if false; then}' \
  19

# ---------- R9: the island bridge is the whole safety model ------------------

mutant "R9 accepts a mock bridge that has an uplink" \
  's{\Q  if [[ "\E\$\Q_r9" == *UPLINK* ]]; then\E}{  if false; then}' \
  20 21

# the MISSING branch is only reachable while it is tested FIRST: the remote
# snippet prints MISSING and exits before it can print OK, so a missing bridge
# fails the *OK* test too. Swapping them back makes the operator chase an ssh
# problem that is not there.
mutant "R9 tests MISSING after OK again, where it cannot be reached" \
  's{(\Q  if [[ "\E\$\Q_r9" == *MISSING* ]]; then\E.*?\n\Q  fi\E\n)(\Q  if [[ "\E\$\Q_r9" != *OK* ]]; then\E.*?\n\Q  fi\E\n)}{$2$1}s' \
  22

# ---------- R10: one run at a time per target copy ---------------------------

mutant "R10 no longer takes the per-target lock" \
  's{\Q  if ! take_tgt_lock "\E\$\QTGT"; then\E}{  if false; then}' \
  26 27

# ---------- R11: a promoted copy left on a production bridge -----------------

mutant "R11 stops warning about a copy left on a production bridge" \
  's{\Q        if [[ -n "\E\$\Q_badbr" ]]; then\E}{        if false; then}' \
  30

# =============================================================================
#  Bugs this codebase really had. Each of these shipped once; none of them may
#  come back quietly.
# =============================================================================

mutant "the inventory preflight is collected and then ignored" \
  's{\Qif (( \E\$\Q{#INV_ERRS[\E\@\Q]} )); then\E}{if false; then}' \
  32 33

mutant "a --storage or --ctid that matched nothing still exits 0" \
  's{\Qif (( matched == 0 )) && [[ -n "\E\$\QLANE_STORAGE\E\$\QONLY_CTID" ]]; then\E}{if false; then}' \
  34

mutant "AUTO_DISCOVER finding nothing means nothing to do, exit 0" \
  's{\Q  if [[ \E\$\Q{#CTS[\E\@\Q]} -eq 0 || -z "\E\$\Q{CTS[0]:-}" ]]; then\E(\n\Q    log "ERROR: AUTO_DISCOVER=1\E)}{  if false; then$1}' \
  37

# Proxmox ships no jq (rule 6), and this engine used to pipe /cluster/resources
# through one: on a real node the pipe then produces nothing, CTS comes back
# empty and the run looks like a quiet night. A developer box usually HAS jq,
# which would make this mutation pass here and fail on the only machine it is
# about - so the node's truth is handed to the mutant instead of assumed: jq
# does not exist. An exported function is the same hook the simulator uses for
# pvesm and zfs, because bash finds those before PATH even in an engine that
# sets its own; BASH_FUNC_x%% is how bash carries one through the environment.
RUN_ENV=('BASH_FUNC_jq%%=() { return 127; }')
mutant "jq is back in the discover pipeline (Proxmox has none)" \
  's{\Q    | tr \E.*?\Q    | grep -vxFf \E}{    | jq -r \x27.[] | select(.type=="lxc") | .vmid\x27 \\\n    | grep -vxFf }s' \
  38

# Deleting the value check leaves `LANE_STORAGE="$2"` with nothing in $2, which
# set -u turns into an immediate death. That is deliberate: restoring the old
# `${2:-}` with `shift 2 || true` would make the mutant SPIN INSTEAD OF DYING
# and this runner would wait for it forever. A mutation has to fail fast.
# The delimiter is ! rather than {} because the anchor contains a brace pair.
mutant "a flag with no value is accepted instead of refused" \
  's! \Q|| { echo "--storage needs a value" >&2; exit 2; }\E!!' \
  51

# ---------- --dry-run: changes what is written, never what is checked --------
# Each of these is a write the dry run must not make. The SIM_DRY invariant
# catches them without any scenario naming them, which is the point of having
# an invariant rather than an assertion.

mutant "--dry-run takes the snapshot and the clone after all" \
  's{\Q    if (( DRY )); then\E\n\Q      # A snapshot and a clone are named objects on live customer storage, and\E}{    if false; then\n      #}' \
  52

mutant "--dry-run creates the destination dataset on the backup node" \
  's{\Q  DRY_NO_DS=0\E\n\Q  if (( DRY )); then\E}{  DRY_NO_DS=0\n  if false; then}' \
  52

# A dry round never reaches st_begin - it stops before the transfer - so the
# gate that actually keeps state clean is the one in st_flush, and that is the
# one worth breaking. st_write carries the same gate as belt and braces for a
# dry path that transfers something one day; it cannot be reached today, and a
# mutation of it would prove nothing.
mutant "--dry-run writes the state file over the last real round" \
  's{\Q  (( DRY )) && { ST_CTID=""; return 0; }\E\n}{}' \
  52b

# Rule 8: cron hands a job PATH=/usr/bin:/bin, so an engine that does not set
# its own runs whatever the caller's PATH leads to. cron's real PATH cannot
# show that here - what a node loses from it (pvesm, zfs, losetup) the
# simulator supplies as shell functions, which bash finds whatever PATH says,
# and everything else lives in /usr/bin either way. So the caller this mutation
# gets is one whose PATH leads to a flock that refuses, which is what a
# shadowed or missing tool looks like from inside the engine. The real engine
# never looks there and scenario 1 is untouched by it; the mutant takes it and
# reports lane 'all' as already running. The check above the mutation proves
# the environment alone is not what killed the scenario.
CRONBIN="$(mktemp -d /tmp/ctrep-cronbin.XXXXXX)"
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

# Two lanes run concurrently under cron and the engine's cleanup closes the mux
# masters it finds. With the pid gone from the socket name they share one
# master, and the lane that finishes first (nothing to do) tears down the
# connection the other lane is in the middle of using.
#
# The real incident: two cron lanes fired at 21:00, the empty lane finished in
# 0s, and its cleanup glob tore down the mux master the other lane was still
# using - which surfaced as "storage 'replica-hdd' is not active" halfway
# through a transfer. Scenario 50 records the ControlPath the fake ssh is
# handed and asserts it carries a pid.
# The guard that stands between a renamed file and a fleet that quietly stops
# being replicated. Without it the parse block is skipped and the run exits 0.
mutant "a missing inventory is treated as an empty workload again" \
  's{\Qif [[ ! -f "\E\$INV\Q" ]] && (( ! AUTO_DISCOVER )); then\E}{if false; then}' \
  31b

mutant "the ssh control socket no longer carries this run's pid" \
  's{\Q-o ControlPath=/run/ctrep-\E\$\$\Q-%r\E\@\Q%h.sock\E}{-o ControlPath=/run/ctrep-%r\@%h.sock}' \
  50

# mocknet_lines' stdout IS the container config being written. A log line from
# in there does not go to the log, it goes into the file - and the read-back
# (R5) compares the same corrupt text with itself, so it agrees.
mutant "mocknet_lines logs the line it is rewriting" \
  's{\Q    [[ "\E\$\Ql" == *bridge=* ]] || continue     # unreachable: refused in the main loop\E}{    [[ "\$l" == *bridge=* ]] || continue\n    log "MOCKNET: \$l -> \$MOCKNET_BRIDGE"}' \
  1 25

# The old behaviour: a net line with no bridge= cannot be moved onto the island,
# so it was dropped and the run carried on. The copy then came up with one
# interface missing and every report called it healthy.
mutant "a net line with no bridge= is dropped instead of refusing the CT" \
  's{\Q    if [[ -n "\E\$\Q_nobr" ]]; then\E}{    if false; then}' \
  44

# ---------- the log is a deliverable, not a side effect --------------------
# A daily log holds dozens of rounds. Without the rule between operations the
# reader is parsing timestamps to find where one container ends and the next
# begins, at the hour when that is hardest.
mutant "the operation separator is dropped from the log" \
  's{LOGSEP=.#+.}{LOGSEP=""}' \
  1

# ---------- the rsync option set ---------------------------------------------

mutant "the copy stops being --delete, so it only ever grows" \
  's{\Q-aHAX --numeric-ids --delete --inplace\E}{-aHAX --numeric-ids --inplace}' \
  1

mutant "the bandwidth ceiling is dropped from the replica transfer" \
  's{\Q "--bwlimit=\E\$BWLIMIT\Q"\E}{}' \
  1

# Anchored on the array line, not on the bare flag: the flag also appears in the
# comment three lines above it, s{}{} replaces the FIRST occurrence, and the
# mutation then edits prose and leaves the engine untouched.
mutant "the IO-stall timeout is dropped, so a hung receiver hangs the lane" \
  's{\Q"--bwlimit=\E\$BWLIMIT\Q" --timeout=300\E}{"--bwlimit=\$BWLIMIT"}' \
  1

# ---------- the backup node's identity ---------------------------------------
# Nobody types a pmxcfs name any more; the node is asked. Both halves of that
# have to keep working: adopting what it says, and refusing a pinned value that
# disagrees with it. Getting this wrong writes copy configs into a directory
# belonging to another cluster member, and every check before it passes.

mutant "a pinned BKP_NODE is adopted instead of checked" \
  's{\Qelif [[ "\E\$_bknode\Q" != "\E\$BKP_NODE\Q" ]]; then\E}{elif false; then}' \
  41

mutant "the name the node reports is thrown away, leaving BKP_NODE empty" \
  's{\Q  BKP_NODE="\E\$_bknode\Q"\E}{  :}' \
  41b 1

# --all is a no-op here and has to stay accepted. Dropping it turns one command
# shape across three engines back into three, and the failure is an exit 2 in
# the middle of a cron line that has worked for months.
mutant "--all is refused again, so one command shape stops working" \
  's{\Q    --all)     shift;;\E}{}' \
  41a

echo
echo "=== $PASS mutations killed, $FAIL survived ==="
if (( FAIL > 0 )); then echo "survived: ${FAILED_NAMES[*]}"; exit 1; fi
exit 0
