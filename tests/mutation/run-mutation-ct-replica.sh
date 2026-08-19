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
SIM="$ROOT/tests/sim/ct-replica/run-sim-replica.sh"
SRC="$ROOT/engines/ct-replica.sh"
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

# DEST_SID is gone: the dest key IS the storage id now, so the comparison is
# against $DEST directly.
mutant "R8 lets an existing copy config point at another dest" \
  's{\Q    if [[ "\E\$csid\Q" != "\E\$DEST\Q" ]]; then\E}{    if false; then}' \
  19

# ---------- R9: the island bridge is the whole safety model ------------------

mutant "R9 accepts a mock bridge that has an uplink" \
  's{\Q  if [[ "\E\$\Q_r9" == *UPLINK* ]]; then\E}{  if false; then}' \
  20 21

# An OVS bond is a row in ovsdb, not a netdev: `list-ports` names the bond and
# the engine's test for a physical device finds nothing on it, so a bridge with
# two cables in it reads as an island. Every copy on that island carries a
# production IP and MAC.
mutant "R9 asks OVS for the bridge's PORTS, so a bonded uplink hides behind one name" \
  's!\Q--timeout=5 list-ifaces\E!--timeout=5 list-ports!' \
  21b

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

# AUTO_DISCOVER used to walk /cluster/resources and pick up every container in
# the fleet, and two mutations lived here about how it did that: one that let
# an empty discovery exit 0, and one that put `jq` back in the pipeline that
# Proxmox has no jq for. Both went when the mode did. Not to reach green - the
# CODE they anchored on is gone, because a mode that replicates containers with
# no inventory row cannot say which pool their copies belong on, and there is
# no default to answer with any more. What is left is one mutation on the
# refusal itself.
mutant "AUTO_DISCOVER=1 is accepted, and then replicates to nowhere" \
  's{\Q  log "ERROR: AUTO_DISCOVER=1 is not usable without a default destination - NOTHING was run"\E}{  :}' \
  37

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
  's{\Qif [[ -f "\E\$BASE\Q/../../ketsync" && -f "\E\$BASE\Q/../../lib/common.sh" ]]; then\E}{if true; then}' \
  1

mutant "the fallback log directory is not the engine's own" \
  's{\QLOGDIR="\E\$BASE\Q/logs"\E}{LOGDIR="\$BASE/../logs"}' \
  1

# ---------- R13: a live DR placement owns the newest data --------------------
# PAUSE could never cover this. The storage node dies with no warning, so
# nobody types `touch PAUSE` and the file would have been on the machine that
# died. When it comes back, cron copies the PRE-DISASTER image over the DR copy
# and the copy then LOOKS current while holding neither the old data nor the
# new. The fact that settles it is one PVE wrote itself: ct-distribute.sh
# creates 9<id> in pmxcfs, and only after a good transfer.
mutant "R13 stops looking for a live DR placement" \
  's{\Q  if [[ -n "\E\$_dract\Q" ]]; then\E}{  if false; then}' \
  49

mutant "R13 looks for the DR copy under the backup node only, not across the cluster" \
  's{\Qls /etc/pve/nodes/*/lxc/\E\$_dr\Q.conf\E}{ls /etc/pve/nodes/\$BKP_NODE/lxc/\$_dr.conf}' \
  49

mutant "R13 computes the DR id with the wrong offset, so it never finds one" \
  's{\Q  _dr=\E\$\(\( CT \+ DR_OFFSET \)\)}{  _dr=\$(( CT + OFFSET ))}' \
  49

mutant "a held-back container leaves the night reading as healthy" \
  's{\Qif (( \E\$\{#DR_ACTIVE_IDS\[\@\]\}\Q )); then\E\n\Q  [[ -n "\E\$HEALTH_URL\Q" ]]\E}{if false; then\n  [[ -n "\$HEALTH_URL" ]]}' \
  49

# ---------- the dest column is a storage id, spelled in full ----------------
# It used to be a short alias - hdd, ssd - which meant nothing to anybody who
# had not read ctrep.conf, and sat next to a source assertion like
# tank-hdd-nas looking like two spellings of one thing. Every fleet upgrading
# has the old word in its inventory today, and without this branch it falls
# through to "source storage assertion" and fails saying the CT does not live
# on a storage called 'hdd' - true, and nowhere near the mistake.
mutant "the old short dest name falls through to a storage assertion again" \
  's{\Q      elif [[ "\E\$f\Q" == hdd || "\E\$f\Q" == ssd ]]; then\E}{      elif false; then}' \
  64

# ---------- R14: the lock lives on the machine holding the copy --------------
# Every other lock here is a local flock, and local flocks settle nothing
# between machines. ct-replica runs on the storage node while distribute and
# recall are driven from the backup node - during an outage that is not an
# edge case, it is the normal shape of the day. decisions.md section 2 called
# this "the lock therefore lives on the destination" for months while nothing
# implemented it.
mutant "R14 is gone: the copy is written with only a local lock held" \
  's{\Q    take_dst_lock "\E\$BKP_SSH\Q" "\E\$TGT\Q"; _dl=\E\$\?}{    _dl=0}' \
  70 71

# The delimiter is ! because the anchors close a shell function and perl
# balances a brace inside s{}{} against its own delimiter.
mutant "R14 treats a destination that did not answer as a free lock" \
  's!\Q  esac\E\n\Q  return 2\E!  esac\n  return 0!' \
  72

mutant "R14 removes the lock without asking whether it is still ours" \
  's!\Q2>/dev/null && rm -f \E!2>/dev/null; rm -f !' \
  77

mutant "R14 releases by deleting the file, with no owner check at all" \
  's!\Qgrep -qxF \E\x27\$DST_LOCK_OWNER\x27\Q \E\x27\$f\x27\Q 2>/dev/null && \E!!' \
  70 77

mutant "R14 takes the lock with a plain redirect, so it overwrites whoever holds it" \
  's{\Qif (set -C; printf \E}{if (printf }' \
  71

mutant "R14 locks a name of its own instead of the copy's VMID" \
  's{\Qdst_lock_file(){ printf \E.\Q/run/ketsync-ct-%s.lock\E.\Q "\E\$1\Q"; }\E}{dst_lock_file(){ printf \x27/run/ketsync-ct.lock\x27; }}' \
  71

mutant "R14 names the holder and then syncs on top of it anyway" \
  's!\Q      log "[\E\$CT\Q] GUARD R14:   breaks a lock on its own - see \E\x27\Qketsync doctor\E\x27\Q."\E\n\Q      st_skip r14_dst_locked; continue\E!      st_skip r14_dst_locked!' \
  71

mutant "the lock is never released, so one round wedges that copy for good" \
  's!\Qrelease_dst_lock(){\E\n\Q  [[ -n "\E\$DST_LOCK_ID\Q" ]] || return 0\E!release_dst_lock(){\n  return 0!' \
  70

mutant "a dry run takes the lock for real on another machine" \
  's!\Q    peek_dst_lock "\E\$BKP_SSH\Q" "\E\$TGT\Q"; _dl=\E\$\?!    take_dst_lock "\$BKP_SSH" "\$TGT"; _dl=\$?!' \
  76

# ---------- the dest map's own format ----------------------------------------
# `hdd=replica-hdd/ct:replica-hdd` still contains a colon, so the shape check
# below it never fired: the entry parsed as a key of `hdd=replica-hdd/ct` and
# the run died one check later saying DEFAULT_DEST was not a key - which points
# at the wrong line. This engine SHIPPED that line in ctrep.conf, so it is the
# first thing every fleet upgrading hits.
mutant "the OLD key=dataset:storage-id map is read as though it worked" \
  's{\Q  if [[ "\E\$_kv\Q" == *=* ]]; then\E}{  if false; then}' \
  78


# ---------- the moved homes ---------------------------------------------------
# ctrep.conf and the work list moved out of engines/. A copy left at the old
# path is refused, because two files with one name is two places to edit and
# the engine reading the one nobody edits is a fleet configured by a ghost.
mutant "a conf left at the OLD home is silently outranked instead of refused" \
  's{\Q  if [[ -e "\E\$\QCONF" ]]; then\E\n\Q    echo "ERROR: \E\$\QCONF is the OLD home - the conf moved to conf/ctrep.conf." >&2\E}{  if false; then\n    echo "ERROR: \$CONF is the OLD home - the conf moved to conf/ctrep.conf." >&2}' \
  79

mutant "a work list left at the OLD home is silently outranked instead of refused" \
  's{\Q  if [[ -e "\E\$\QINV" ]]; then\E\n\Q    echo "ERROR: \E\$\QINV is the OLD home - the work lists moved to inventory/." >&2\E}{  if false; then\n    echo "ERROR: \$INV is the OLD home - the work lists moved to inventory/." >&2}' \
  79

# ---------- the per-site exclude list -----------------------------------------
# Three patterns that used to be typed into the rsync argument list. The thing
# that can now go wrong is new: a file, which can be absent, ignored, or looked
# for in the wrong place - and any of those changes what is IN the copy without
# changing anything about the run that made it.
mutant "a missing exclude list is carried past, and every copy fills with /tmp" \
  's{\Q  echo "ERROR: the exclude list is missing: \E\$\QEXCL" >&2\E}{  : "\$EXCL"}' \
  82

mutant "the destination's own .zfs is deleted, one failing unlink at a time" \
  's{\Q      "--exclude-from=\E\$\QEXCL"\E}{      "--exclude-from=\$EXCL" --delete-excluded}' \
  80b

mutant "the list is read and then not handed to rsync" \
  's!\Q      "--exclude-from=\E\$\QEXCL"\E!      \x27--exclude=/tmp/*\x27!' \
  80 81

mutant "in a repo tree the list is looked for at the old flat home" \
  's{\Q  EXCL="\E\$\Q_ksroot/conf/ctrep-exclude.conf"\E}{  :}' \
  79

# ---------- R15: the copy PVE itself is holding -------------------------------
# vzdump writes `lock: backup` into the copy's config for the whole of a PBS
# backup, and that backup reads the rootfs this engine writes into. What breaks
# is the BACKUP, not the copy - so nothing looks wrong until a restore.
mutant "a copy PBS is backing up is written into anyway" \
  's{\Q    if [[ -n "\E\$_plock\Q" ]]; then\E}{    if false; then}' \
  84 86

mutant "only 'backup' counts, so a rollback in progress is overwritten" \
  's{\Q    if [[ -n "\E\$_plock\Q" ]]; then\E}{    if [[ "\$_plock" == backup ]]; then}' \
  85

mutant "the skip is recorded as a good round, so the copy reads as fresh" \
  's{\Q      st_skip r15_pve_lock; continue\E}{      st_ok; continue}' \
  84

# ---------- the daily snapshot of the copy ------------------------------------
# The snapshot is the only thing between a replica and a backup: replication
# makes the copy MATCH production, deletions included. Every mutation here is a
# way the snapshots stop being taken, or stop being the days they claim to be,
# while every log line still says the copy is healthy.
mutant "a round that failed is snapshotted too, so the rollback point is a torn copy" \
  's{\Q    log "[\E\$CT\Q] GUARD R5: sync FAILED (rc=\E\$rc\Q) - copy config NOT created"\E}{    snap_after_green "\$TDS" "ketsync-\$(date +%F)"\n    log "[\$CT] GUARD R5: sync FAILED (rc=\$rc) - copy config NOT created"}' \
  89

mutant "SNAP_KEEP=0 takes one anyway, and prunes every day that was there" \
  's{\Q  if (( SNAP_KEEP > 0 )); then\E\n\Q    ST_SNAP="ketsync-\E\$\Q(date +%F)"\E}{  if true; then\n    ST_SNAP="ketsync-\$(date +%F)"}' \
  92

mutant "the prune keeps the oldest days and destroys the newest" \
  's!\Q      | sort | head -n -\E\$\QSNAP_KEEP \E\\!      | sort -r | head -n -\$SNAP_KEEP \\!' \
  90

mutant "the prune sweeps up snapshots ketsync never made" \
  's{\Qketsync-[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\E}{.*}' \
  91

mutant "a second round the same day takes a second snapshot, and the day fails" \
  's!\Q    if zfs list -H -o name -t snapshot \E\x27\Q\E\$\Qds@\E\$\Qsn\E\x27\Q >/dev/null 2>&1; then\E!    if false; then!' \
  88

mutant "a snapshot that could not be taken is forgotten by the round" \
  's{\Q            log "[\E\$CT\Q] WARN:   point and today\E\x27\Qs line of history. Check space and the pool."\E\n\Q            return 1;;\E}{            return 0;;}' \
  93

mutant "the run exits 0 while copies have no rollback point at all" \
  's{\Qif (( \E\$\Q{#SNAP_FAILED_IDS[\E\@\Q]} )); then\E\n\Q  [[ -n "\E\$HEALTH_URL}{if false; then\n  [[ -n "\$HEALTH_URL}' \
  93

# The regression this replaces, put back as a mutation: snapdir=visible was set
# for one commit, and it broke every PBS backup of every copy - pxar walks into
# `.zfs/shares`, gets EOPNOTSUPP, and fails the whole guest. Nothing about the
# replication round looked wrong.
mutant "snapdir is made visible, and PBS walks into .zfs/shares" \
  's{\Q    elif zfs snapshot \E}{    elif zfs set snapdir=visible '\$ds' \&\& zfs snapshot }' \
  87

# ---------- --move-dest: the order is the whole feature -----------------------
# Copy, verify, repoint, and only then remove. Every step before the last one
# is free to fail: the old copy is still the one the config boots. Reversed,
# the same commands are a customer's DR copy gone.
mutant "the old dataset is removed before anything points away from it" \
  's{\Q  log "[\E\$CT\Q] MOVE: \E\$onew\Q verified: mounted\E}{  ssh \$SSH_OPT "\$BKP_SSH" "zfs destroy -r \x27\$ofrom\x27" </dev/null >>"\$LOG" 2>\&1\n  log "[\$CT] MOVE: \$onew verified: mounted}' \
  95

mutant "a send that failed reads as a move that finished" \
  's{\Q      set -o pipefail\E}{      set +o pipefail}' \
  97

mutant "a dataset already sitting at the destination is written over" \
  's!\Q  if ssh \E\$SSH_OPT\Q "\E\$BKP_SSH\Q" "zfs list -H -o name \E\x27\Q\E\$\Qonew\E\x27\Q" </dev/null >/dev/null 2>&1; then\E!  if false; then!' \
  99

mutant "the verification compares nothing, so a short receive passes" \
  's{\Q  if [[ -z "\E\$\Q{nlogical:-}" || -z "\E\$\Q{ologic:-}" || "\E\$nlogical\Q" != "\E\$ologic\Q" ]]; then\E}{  if [[ 1 == 2 ]]; then}' \
  98

mutant "an unmounted destination is accepted, and the next round fills the root fs" \
  's{\Q  if [[ "\E\$\Q{nmounted:-}" != yes ]]; then\E}{  if [[ 1 == 2 ]]; then}' \
  105

mutant "the copy's history is dropped on the way across" \
  's!\Q      zfs send -R \E\x27\Q\E\$\Qofrom@\E\$\Qsnap\E\x27\Q | zfs recv \E\x27\Q\E\$\Qonew\E\x27\E!      zfs send \x27\$ofrom@\$snap\x27 | zfs recv \x27\$onew\x27!' \
  96

mutant "--move-dest takes a pool name, which the row may not agree with" \
  's{\Q               if [[ \E\$\Q# -ge 2 && "\E\$\Q2" != -* ]]; then\E}{               if false; then}' \
  100

mutant "--move-dest with no --ctid moves whatever the inventory happens to say" \
  's{\Q  if [[ -z "\E\$ONLY_CTID\Q" ]]; then\E\n\Q    echo "--move-dest needs --ctid <id>\E}{  if false; then\n    echo "--move-dest needs --ctid <id>}' \
  100

mutant "a copy already on the row's pool is moved onto itself" \
  's{\Q  if [[ "\E\$from\Q" == "\E\$DEST\Q" ]]; then\E}{  if false; then}' \
  101

mutant "a dry move does the move" \
  's{\Q  if (( DRY )); then\E\n\Q    log "[\E\$CT\Q] DRY: would move copy\E}{  if false; then\n    log "[\$CT] DRY: would move copy}' \
  102

mutant "--move-dest is read after R8 has already refused the row" \
  's{\Q    if (( MOVE_DEST )); then\E\n\Q      move_copy_dest "\E\$csid\Q"\E}{    if false; then\n      move_copy_dest "\$csid"}' \
  95

echo
echo "=== $PASS mutations killed, $FAIL survived ==="
if (( FAIL > 0 )); then echo "survived: ${FAILED_NAMES[*]}"; exit 1; fi
exit 0
