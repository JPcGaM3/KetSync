#!/usr/bin/env bash
# =============================================================================
#  run-mutation.sh — check that the simulator suite can actually FAIL.
# -----------------------------------------------------------------------------
#  A green test suite means nothing until you have seen it go red for the right
#  reason. This takes ct-migrate.sh, breaks one specific thing in it, and runs
#  the scenarios that are supposed to notice. A scenario that still passes
#  against a broken engine is not a test, it is decoration.
#
#  Every mutation is a literal-text edit anchored on a line of the engine. When
#  the anchor moves the mutation applies to nothing, and that is reported as a
#  failure too: a mutation that cannot be applied has stopped proving anything.
#
#  usage:  ./tests/mutation/run-mutation.sh
#          make mutation
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SIM="$ROOT/tests/sim/run-sim.sh"
SRC="$ROOT/ct-migrate.sh"
PASS=0; FAIL=0; FAILED_NAMES=()
# extra environment for one mutation that is about the environment itself
RUN_ENV=()

command -v perl >/dev/null || { echo "perl is required for the mutation suite"; exit 1; }

# $1 = name, $2 = perl s{}{} program, rest = scenarios that MUST fail on it
mutant(){
  local name="$1" prog="$2"; shift 2
  local m ok=1 s
  m="$(mktemp /tmp/ctmig-mutant.XXXXXX)"
  echo "  [$name]"
  # perl's own exit status matters. A program that does not compile writes
  # nothing, and an EMPTY mutant "kills" every scenario - it does nothing at
  # all - so the suite would report a green tick for a mutation that was never
  # applied. That is the exact failure this whole file exists to prevent, and
  # it was live here for one mutation until it was caught by a sibling suite.
  if ! perl -0777 -pe "$prog" "$SRC" > "$m" 2>/dev/null; then
    echo "      x perl refused the mutation program - fix the mutation, not the engine"
    rm -f "$m"; FAIL=$((FAIL+1)); FAILED_NAMES+=("$name"); return
  fi
  if [[ ! -s "$m" ]] || (( $(wc -c <"$m") < $(( $(wc -c <"$SRC") / 2 )) )); then
    echo "      x the mutant is empty or half the engine is gone - that is corruption, not a mutation"
    rm -f "$m"; FAIL=$((FAIL+1)); FAILED_NAMES+=("$name"); return
  fi
  if cmp -s "$m" "$SRC"; then
    echo "      x the mutation matched nothing - its anchor has moved in the engine"
    rm -f "$m"; FAIL=$((FAIL+1)); FAILED_NAMES+=("$name"); return
  fi
  if ! bash -n "$m" 2>/dev/null; then
    echo "      x the mutant does not even parse - fix the mutation, not the engine"
    rm -f "$m"; FAIL=$((FAIL+1)); FAILED_NAMES+=("$name"); return
  fi
  chmod +x "$m"
  for s in "$@"; do
    if env "${RUN_ENV[@]}" ENGINE="$m" "$SIM" "$s" >/dev/null 2>&1; then
      echo "      x scenario $s SURVIVES the mutation - it is not testing this"
      ok=0
    else
      echo "      - scenario $s dies, as it must"
    fi
  done
  rm -f "$m"
  if (( ok )); then PASS=$((PASS+1)); echo "      ok"
  else FAIL=$((FAIL+1)); FAILED_NAMES+=("$name"); fi
}

# The runner's own safety net, exercised before it grades anything. The two
# guards inside mutant() exist because a mutation that had never been applied
# reported green here for weeks - and a guard nobody exercises is exactly how
# the replica runner came to be missing both of them while CLAUDE.md said
# otherwise. Each probe calls mutant() for real inside a command substitution,
# so its counters and its output are thrown away and only the refusal is read.
# The two probes are different failures on purpose: the first makes perl exit
# non-zero and write nothing, the second lets perl succeed and produce an empty
# file. A runner that cannot refuse both stops here rather than grading.
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

echo "=== ct-migrate.sh mutation suite ==="

# Same hole as the replica suite's: the preflight that names a missing tool has
# to run before the lock, or `flock -n 9` on a host without flock reads as "the
# lock is held" and the run exits 0 having done nothing.
mutant "the required-command preflight is reported but not obeyed" \
  's{\Qlog "ERROR:   this script sets PATH itself, so a miss here means the tool is genuinely absent"\E\n\Q  exit 2\E}{log "ERROR:   this script sets PATH itself, so a miss here means the tool is genuinely absent"\n  :}' \
  62


# Two bugs that were fixed in ct-replica.sh first and lived on here for weeks.
# Both are silent: neither makes the engine crash, and both look like somebody
# else's fault from the call site.

# The mutant runs with a PATH that leads to a `flock` which refuses. Cron's real
# PATH proves nothing in the simulator - everything a node would lose from it
# (pvesm, zfs, e2fsck) the harness hands the engine as exported functions - so
# this stands in for "the engine no longer controls its own PATH". Scenario 1 is
# checked against the UNMUTATED engine under the same PATH first, so the
# environment alone cannot be what kills it.
_badpath="$(mktemp -d /tmp/ctmig-badpath.XXXXXX)"
printf '#!/bin/sh\nexit 1\n' > "$_badpath/flock"; chmod +x "$_badpath/flock"
if PATH="$_badpath:/usr/bin:/bin" "$SIM" 1 >/dev/null 2>&1; then
  RUN_ENV=(PATH="$_badpath:/usr/bin:/bin")
  mutant "the engine no longer sets its own PATH, so cron's PATH wins" \
    's{^\QPATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\E$}{: # PATH not set}m' \
    1
  RUN_ENV=()
else
  echo "  [the engine no longer sets its own PATH, so cron's PATH wins]"
  echo "      x scenario 1 fails under the probe PATH even unmutated - skipping"
  FAIL=$((FAIL+1)); FAILED_NAMES+=("PATH probe unusable")
fi
rm -rf "$_badpath"

mutant "the ssh control socket no longer carries this run's pid" \
  's{\Q-o ControlPath=/run/ctmig-\E\$\$\Q-%r\E\@\Q%h.sock\E}{-o ControlPath=/run/ctmig-%r\@%h.sock}' \
  55

mutant "the per-node lock is never contended" \
  's{\Qflock -n 8\E}{true}' \
  25 26 27

mutant "the lock is keyed on the CT instead of the source node" \
  's{\Qtake_node_lock "\E\$old_node}{take_node_lock "\$new_ctid}' \
  25

mutant "rsync stats keep their thousands separators" \
  's{\Qtr -d \E.,.}{cat}' \
  29 30

mutant "the JSON escaper passes its input through untouched" \
  's~\Qjson_str(){  # any bash string\E~json_str(){ printf \x27"%s"\x27 "\$1"; return 0; #~' \
  37

mutant "the state file is written but never moved into place" \
  's{\Q&& mv -f "\E\$t\Q" "\E\$f\Q" 2>/dev/null \E}{}' \
  28 31 33

mutant "the run history is never appended to" \
  's{\Q>> "\E\$h\Q" 2>/dev/null || true\E}{>/dev/null}' \
  36

mutant "an ENOSPC retry replaces the transfer counters instead of adding" \
  's{\Qacc_files=\E\$\Q(( acc_files + RS_FILES ))\E}{acc_files=\$(( RS_FILES ))}' \
  30

mutant "a frozen CT is treated as an ordinary row" \
  's{\Qif [[ -f "\E\$BASE\Q/done/\E\$new_ctid\Q.done" ]]; then\E}{if false; then}' \
  34

mutant "the run status is never set, so every run looks the same" \
  's~\Qst_fail(){ ST_STATUS=failed;\E~st_fail(){ ST_STATUS=ok;~' \
  31 32 33

mutant "the duplicate preflight reports, then runs anyway" \
  's{\Qpreflight_inventory || exit 2\E}{preflight_inventory || true}' \
  41 42 44 46

mutant "the source duplicate check keys on old_ctid alone, ignoring the node" \
  's{\Qk="s:\E\$a\Q \E\$b\Q"\E}{k="s:\$b"}' \
  43

mutant "the preflight stops one row short of the end of the file" \
  's{\Qwhile read -r a b c _rest || [[ -n "\E\$\Q{a:-}" ]]; do\E}{while read -r a b c _rest; do}' \
  46

mutant "the main loop drops a last row that has no trailing newline" \
  's{\Q|| [[ -n "\E\$\Q{old_node:-}" ]]; do\E}{; do}' \
  45

# The braces of a shell function body cannot sit inside an s{}{} replacement -
# perl balances them and the program stops parsing, which used to leave an
# empty mutant behind. Different delimiter, and the newline is matched outside
# \Q where it is still an escape sequence.
mutant "a killed run leaves the image loop-mounted, as it used to" \
  's#\Qend_iteration(){\E\n\Q  cleanup_mnt\E\n#end_iteration(){\n#' \
  47

mutant "the image is never armed, so the exit trap has nothing to unmount" \
  's{\Qarm_mnt "\E\$MNT\Q" "\E\$IMG\Q"         # from here\E}{: "\$MNT" "\$IMG"  # from here}' \
  47

mutant "a filter that matched nothing still exits 0" \
  's{\Qif (( matched == 0 )) && [[ -n "\E\$LANE_STORAGE\$ONLY_CTID\Q" ]]; then\E}{if false; then}' \
  48

mutant "the match counter runs after the .done check, so a frozen lane looks like a typo" \
  's{\Q  matched=\E\$\Q(( matched + 1 ))\E\n(\n\Q  if [[ -f "\E\$BASE\Q/done/\E\$new_ctid\Q.done" ]]; then\E.*?\n\Q  fi\E\n)}{$1  matched=\$(( matched + 1 ))\n}s' \
  49

mutant "G7 trusts an existing config instead of checking whose rootfs it is" \
  's{\Qif [[ "\E\$exist_root\Q" != "\E\$storage:\$new_ctid\Q/vm-\E\$new_ctid\Q-disk-0.raw" ]]; then\E}{if false; then}' \
  50 51

mutant "the written config is never read back" \
  's{\Q&& [[ "\E\$\Q(ssh \E\$SSHOPT\Q "root@\E\$new_node\Q" "cat /etc/pve/lxc/\E\$new_ctid\Q.conf" </dev/null 2>/dev/null)" == "\E\$newcfg\Q" ]]\E}{}' \
  52

mutant "mkfs may fail without anybody noticing" \
  's{\Qif ! mkfs.ext4 -F -m0 "\E\$IMG\Q" >>"\E\$LOG\Q" 2>&1; then\E}{mkfs.ext4 -F -m0 "\$IMG" >>"\$LOG" 2>\&1; if false; then}' \
  53

mutant "pvesm alloc may fail without anybody noticing" \
  's{\Qif ! pvesm alloc "\E\$storage\Q" \E}{if ! true "\$storage" }' \
  54

# Deleting the value check leaves `LANE_STORAGE="$2"` with nothing in $2, which
# set -u turns into an immediate death. That is deliberate: restoring the old
# `${2:-}` with `shift 2 || true` would make the mutant SPIN INSTEAD OF DYING
# and this runner would wait for it forever. A mutation has to fail fast.
# The delimiter is ! rather than {} because the anchor contains a brace pair.
mutant "a flag with no value is accepted instead of refused" \
  's! \Q|| { echo "--storage needs a value" >&2; exit 2; }\E!!' \
  56

# ---------- --dry-run: changes what is written, never what is checked --------
# Each of these is a write the dry run is supposed to skip. The SIM_DRY
# invariant catches them without any scenario asserting on them by name, which
# is the point: the fake refuses, `clean` fails, and the scenario goes red.

mutant "--dry-run still lets rsync move data" \
  's{\Q  (( DRY )) && opts+=(-n)\E\n}{}' \
  57b

mutant "--dry-run mounts the image read-write" \
  's{\QMOPT=loop; (( DRY )) && MOPT=loop,ro,noload\E}{MOPT=loop}' \
  57b

mutant "--dry-run allocates and formats the image after all" \
  's{\Q      st_ok; continue\E\n\Q    fi\E\n}{      st_ok\n    fi\n}' \
  57

# st_begin is the only call that reaches st_write without going through
# st_flush, and it happens just before the transfer - so this shows up on the
# resync path, not on first contact where the dry run stops before mounting.
mutant "--dry-run writes the state file over the last real run" \
  's! \Q&& return 0\E\n\Q  local f="\E\$BASE\Q/state/\E\$ST_PREFIX\E!\n  local f="\$BASE/state/\$ST_PREFIX!' \
  57b

mutant "--stopped --dry-run is quietly allowed to pct mount the old node" \
  's{\Qif (( STOPPED )) && (( DRY )); then\E}{if false; then}' \
  57c

# ---------- the log is a deliverable, not a side effect --------------------
# A daily log holds dozens of rounds. Without the rule between operations the
# reader is parsing timestamps to find where one container ends and the next
# begins, at the hour when that is hardest.
mutant "the operation separator is dropped from the log" \
  's{LOGSEP=.#+.}{LOGSEP=""}' \
  1

# ct-migrate's whole workflow is "run it again until the delta stops shrinking,
# then cut over". changed= is that delta. It was computed, filed into
# state/<ctid>.json, and never shown to the person doing the deciding.
# The wire number comes off the RECEIVED line because this engine pulls. Read
# the sent line instead and every migration reports a few kilobytes: the log
# says wire=3KiB for sixty gigabytes, the state file files the same, and the
# bandwidth ceiling is set from a number that was never the traffic.
mutant "the wire bytes are read off the sending side of a transfer that pulls" \
  's{\Q    RS_WIRE=\E\$\Q(_rs_num \E\x27\QTotal bytes received\E\x27}{    RS_WIRE=\$(_rs_num \x27Total bytes sent\x27}' \
  29

mutant "the per-CT transfer numbers stop being logged" \
  's{\Q  log "[\E\$new_ctid\Q] stats: files=\E.*?\n}{}' \
  1

mutant "the row header stops naming which migration this block is" \
  's{\Q  log "[\E\$new_ctid\Q] CT \E\$old_ctid\Q on \E\$old_node\Q  ->  CT \E.*?\n}{}' \
  1

# ---------- the rsync option set, which nothing checked until now ------------
# Probed before these were written: reducing the whole opts array to `-a` left
# the suite at 61 passed, 0 failed. Every flag below was correct in the tree and
# nothing would have said so on the day it stopped being.

mutant "rsync no longer stops at the mount boundary (-x), so mp0 floods the image" \
  's{\Q --sparse -x --delete\E}{ --sparse --delete}' \
  1

mutant "rsync stops deleting, so the target drifts from the source forever" \
  's{\Q -x --delete "--bwlimit=\E}{ -x "--bwlimit=}' \
  1

mutant "rsync maps uids through names instead of numbers" \
  's{\Q-aHAX --numeric-ids --sparse\E}{-aHAX --sparse}' \
  1

mutant "the bandwidth ceiling is dropped from the transfer" \
  's{\Q "--bwlimit=\E\$BWLIMIT\Q"\E}{}' \
  1

# The dot matches the shell single quote around the exclude. \x27 inside
# \Q...\E is interpreted by perl before the quoting takes effect, and a literal
# quote cannot ride inside the single-quoted program this file hands to perl.
# The comment sits ABOVE the call, not inside it: a comment between a line and
# its continuation ends the command, and mutant() then dies on $2 unbound.
mutant "/proc is no longer excluded from the rootfs copy" \
  's{.\Q--exclude=/proc/*\E. }{}' \
  1

# ---------- the inventory rename ---------------------------------------------
# inventory.tsv became inventory-migrate.tsv when three engines moved into one
# folder. The failure this creates on an upgrade is not subtle - the engine
# refuses every run - but the diagnosis is, because the operator is looking at
# a file called inventory.tsv sitting right there.

mutant "a missing inventory is treated as an empty workload again" \
  's{\Qif [[ ! -f "\E\$INV\Q" ]]; then\E}{if false; then}' \
  64 64b

mutant "an upgrade over the old inventory.tsv gets no hint about the rename" \
  's{\Q  if [[ -f "\E\$BASE\Q/inventory.tsv" ]]; then\E}{  if false; then}' \
  64

# --all is a no-op here and has to stay accepted. Dropping it turns one command
# shape across three engines back into three, and the failure is an exit 2 in
# the middle of a cron line that has worked for months.
mutant "--all is refused again, so one command shape stops working" \
  's{\Q    --all)     shift;;\E}{}' \
  63b


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

echo
echo "=== $PASS mutations killed, $FAIL survived ==="
if (( FAIL > 0 )); then echo "survived: ${FAILED_NAMES[*]}"; exit 1; fi
exit 0
