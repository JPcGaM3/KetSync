#!/usr/bin/env bash
# =============================================================================
#  run-mutation-doctor.sh — check that the doctor simulator can FAIL.
# -----------------------------------------------------------------------------
#  Same contract as every other suite here, and more load-bearing than most.
#  doctor writes nothing, so a scenario cannot prove itself by pointing at
#  damage that did not happen: every assertion is about a LINE OF OUTPUT. That
#  makes it the easiest suite in this repo to write badly - `has "== nodes.tsv"`
#  passes forever, whatever the section under it decided - and these mutations
#  are how you find out which of them are real.
#
#  Each one silences exactly one check, the way a refactor would, and the
#  scenario that exists for that check has to notice. A check that keeps
#  printing its heading while its body is dead is the failure mode this suite
#  is pointed at.
#
#  usage:  ./tests/mutation/run-mutation-doctor.sh
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SIM="$ROOT/tests/sim/doctor/run-sim-doctor.sh"
SRC="$ROOT/lib/cmd_doctor.sh"
PASS=0; FAIL=0; FAILED_NAMES=()

command -v perl >/dev/null || { echo "perl is required for the mutation suite"; exit 1; }
[[ -x "$SIM" ]] || { echo "the doctor simulator is not where this expects it: $SIM"; exit 1; }
[[ -r "$SRC" ]] || { echo "nothing to mutate: $SRC"; exit 1; }

# The mutant is a whole ketsync tree with one file swapped, because
# cmd_doctor.sh is SOURCED by the dispatcher rather than executed - and the
# simulator copies lib/ from beside the dispatcher it is handed, which is what
# makes this work.
mutant(){
  local name="$1" prog="$2"; shift 2
  local m ok=1 s tree
  tree="$(mktemp -d /tmp/ksdoc-mutant.XXXXXX)"
  echo "  [$name]"
  mkdir -p "$tree/lib" "$tree/engines"
  cp "$ROOT/ketsync" "$tree/ketsync"; chmod +x "$tree/ketsync"
  cp "$ROOT"/lib/*.sh "$tree/lib/"
  m="$tree/lib/cmd_doctor.sh"
  # A zero-byte mutant is not a mutant: perl refusing the program writes
  # nothing, and an empty cmd_doctor.sh makes the dispatcher fail every
  # scenario for a reason that has nothing to do with the mutation. That would
  # report as a kill and prove the opposite of one.
  if ! perl -0777 -pe "$prog" "$SRC" > "$m" 2>/dev/null; then
    echo "      x perl refused the mutation program - fix the mutation, not the command"
    rm -rf "$tree"; FAIL=$((FAIL+1)); FAILED_NAMES+=("$name"); return
  fi
  if [[ ! -s "$m" ]] || (( $(wc -c <"$m") < $(( $(wc -c <"$SRC") / 2 )) )); then
    echo "      x the mutant is empty or half the file is gone - that is corruption, not a mutation"
    rm -rf "$tree"; FAIL=$((FAIL+1)); FAILED_NAMES+=("$name"); return
  fi
  if cmp -s "$m" "$SRC"; then
    echo "      x the mutation matched nothing - its anchor has moved"
    rm -rf "$tree"; FAIL=$((FAIL+1)); FAILED_NAMES+=("$name"); return
  fi
  if ! bash -n "$m" 2>/dev/null; then
    echo "      x the mutant does not even parse - fix the mutation, not the command"
    rm -rf "$tree"; FAIL=$((FAIL+1)); FAILED_NAMES+=("$name"); return
  fi
  for s in "$@"; do
    if KS="$tree/ketsync" "$SIM" "$s" >/dev/null 2>&1; then
      echo "      x scenario $s SURVIVES the mutation - it is not testing this"
      ok=0
    else
      echo "      - scenario $s dies, as it must"
    fi
  done
  rm -rf "$tree"
  if (( ok )); then PASS=$((PASS+1)); echo "      ok"
  else FAIL=$((FAIL+1)); FAILED_NAMES+=("$name"); fi
}

# The runner's own safety net, exercised before it grades anything - a guard
# nobody exercises is how a suite comes to be missing one while the file that
# describes it says otherwise.
self_check(){
  local out
  out="$(mutant "self-check: a program perl cannot compile" 's{unbalanced' 1 2>&1)"
  [[ "$out" == *"perl refused the mutation program"* ]] || {
    echo "SELF-CHECK FAILED: mutant() accepted a program perl cannot compile" >&2
    printf '%s\n' "$out" >&2; exit 2; }
  out="$(mutant "self-check: a program that empties the file" 's{\A.*\z}{}s' 1 2>&1)"
  [[ "$out" == *"empty or half the file is gone"* ]] || {
    echo "SELF-CHECK FAILED: mutant() accepted an empty mutant" >&2
    printf '%s\n' "$out" >&2; exit 2; }
  out="$(mutant "self-check: a program that changes nothing" 's{\Qzzz-not-in-this-file\E}{x}' 1 2>&1)"
  [[ "$out" == *"matched nothing"* ]] || {
    echo "SELF-CHECK FAILED: mutant() accepted a mutation that changed nothing" >&2
    printf '%s\n' "$out" >&2; exit 2; }
}
self_check

echo "=== ketsync doctor mutation suite ==="

# ---------- the machines ----------------------------------------------------
mutant "a node that did not answer is reported as one that did" \
  's{\Q      if ks_ssh "\E\$ip\Q" true 2>/dev/null; then verdict="ssh ok"\E}{      if true; then verdict="ssh ok"}' \
  2

mutant "a compute node with no ssh goes back to being expected" \
  's{\Q        verdict="SSH FAILS - no DR can run on this node"; rc=1\E}{        verdict="no ssh (expected)"}' \
  2

mutant "the backup node being unreachable stops being said out loud" \
  's{\Q  elif ! ks_ssh "\E\$ip\Q" true 2>/dev/null; then\E}{  elif false; then}' \
  3

# ---------- the tables ------------------------------------------------------
mutant "a missing generation line is taken as an ordered file" \
  's{\Q    [[ -n "\E\$gen\Q" ]] && say\E}{    true \&\& say}' \
  5

# The regex in that line is why this one spans it with .*? instead of quoting
# it: an anchor that has to be escaped twice is an anchor that breaks silently.
mutant "the old five-column fleet.tsv parses as the new shape" \
  's{\Q      if [[ ! "\E\$home\Q" =~ \E.*?\Q; then\E}{      if false; then}' \
  6

mutant "an address nodes.tsv has never heard of is let through" \
  's!\Q        [[ -n "\E\$\Q(node_role "\E\$ip\Q")" ]] || \E!        true || !' \
  7

mutant "a row with no destination storage is treated as complete" \
  's!\Q      [[ -n "\E\$dst\Q" ]] || \E!      true || !' \
  8

# ---------- the copy nobody was watching -------------------------------------
mutant "a copy older than the limit stops being old" \
  's{\Q      if (( age >= KS_COPY_STALE_DAYS )); then\E}{      if false; then}' \
  9

# ---------- what a half-finished DR left behind ------------------------------
# All three of these leave the section printing "nothing left over", which is
# the sentence somebody reads to decide the disaster is over.
mutant "a container left on the isolation bridge is not mentioned" \
  's{\Q    for f in \E\$\Q(ks_ssh "\E\$bkp\Q" "ls /etc/pve/ketsync/isolate/\E}{    for f in \$(true "ls /etc/pve/ketsync/isolate/}' \
  10

mutant "a storage still disabled by an evacuate is not mentioned" \
  's{\Q    for f in \E\$\Q(ks_ssh "\E\$bkp\Q" "ls /etc/pve/ketsync/evacuate/\E}{    for f in \$(true "ls /etc/pve/ketsync/evacuate/}' \
  10

mutant "a 9<id> that outlived its disaster is not mentioned" \
  's{\Q    for f in \E\$\Q(ks_ssh "\E\$bkp\Q" "ls /etc/pve/nodes/\E}{    for f in \$(true "ls /etc/pve/nodes/}' \
  10

mutant "a backup node that could not be asked reads as a fleet with nothing left" \
  's{\Q  elif ! ks_ssh "\E\$bkp\Q" true 2>/dev/null; then\E}{  elif false; then}' \
  11

# ---------- the engines cron has to be able to run ---------------------------
mutant "an engine that is not executable is reported as ok" \
  's{\Q      if [[ -x "\E\$KS_BASE\Q/engines/\E\$f\Q" ]]; then say "  \E}{      if [[ -e "\$KS_BASE/engines/\$f" ]]; then say "  }' \
  12

# ---------- the image whose filesystem already said something ----------------
mutant "an image that recorded an error is not reported" \
  's{\Q      elif [[ "\E\$state\Q" == *"with errors"* ]]; then\E}{      elif false; then}' \
  13

mutant "the check fires on every mounted filesystem, which is all of them" \
  's{\Q      elif [[ "\E\$state\Q" == *"with errors"* ]]; then\E}{      elif [[ "\$state" == *"not clean"* || "\$state" == *"with errors"* ]]; then}' \
  14

mutant "a node that could not be asked about an image reads as a clean image" \
  's{\Q      if [[ -z "\E\$state\Q" ]]; then\E}{      if false; then}' \
  15

# ---------- the cron line that would refuse at 02:00 -------------------------
mutant "a cron line without -y stops being noticed" \
  's{\Q  if [[ -n "\E\$cronhits\Q" ]]; then\E}{  if false; then}' \
  17

mutant "the -y a cron line already has is not looked for" \
  's{\Q | grep -v -- \E\x27\Q-y\E\x27}{}' \
  18

mutant "a read-only cron verb is nagged about a -y that would mean nothing" \
  's{\Q               | grep -vE \E\x27\Qketsync[[:space:]]+(watch|doctor|status|role)([[:space:]]|\E\$\Q)\E\x27 \\\n}{}' \
  21

# ---------- both layers, one exit code ---------------------------------------
mutant "the execution layer's exit code is dropped on the floor" \
  's{\Q    "\E\$KS_BASE\Q/engines/tp" doctor || rc=1\E}{    "\$KS_BASE/engines/tp" doctor || true}' \
  19


# ---------- the blocked mount ------------------------------------------------
# The 2026-08-17 outage: a dead storage node makes the stat on every image
# path BLOCK, and this check ran minutes per row at exactly the moment nobody
# has minutes. Two ways to lose what was fixed: read the block as clean, or
# keep paying the timeout once per row on a node already known to block.
mutant "a blocked mount reads as clean" \
  's{\Q      elif [[ "\E\$state\Q" == BLOCKED* ]]; then\E}{      elif false; then}' \
  22

mutant "a node that blocked once is asked again, one timeout at a time" \
  's{\Q      if [[ -n "\E\$\Q{KS_IMG_BLOCKED[\E\$\Qhome]:-}" ]]; then\E}{      if false; then}' \
  22


# ---------- the file cron throws away -----------------------------------------
# One line in the user-crontab shape kills every job in that cron.d file, and
# the only evidence is in the cron daemon's journal. A watcher that never ran
# looks exactly like a fleet with nothing to report.
mutant "a cron.d line missing its user field is not noticed" \
  's{\Q      [[ -n "\E\$u\Q" && "\E\$u\Q" != /* ]] && continue\E}{      continue}' \
  23

mutant "the @daily shorthand is parsed like a five-field line, so a good file is condemned" \
  's{\Q      if [[ "\E\$f1\Q" == @* ]]; then u="\E\$f2\Q"; else u="\E\$f6\Q"; fi\E}{      u="\$f6"}' \
  24


mutant "a cron line that hands -y to an engine is not noticed" \
  's{\Q  if [[ -n "\E\$enghits\Q" ]]; then\E}{  if false; then}' \
  25

mutant "the engine check fires on the dispatcher's own lines too" \
  "s!\\Qgrep -E 'engines/(ct-[a-z]+\\.sh|tp)'\\E!grep -E 'ketsync'!" \
  26

mutant "the -y check matches any line with ketsync in its PATH, engines included" \
  "s!\\Qgrep -E '(^|[/[:space:]])ketsync[[:space:]]+[a-z]'\\E!grep ketsync!" \
  26

echo
echo "=== $PASS mutations killed, $FAIL survived ==="
if (( FAIL > 0 )); then echo "survived: ${FAILED_NAMES[*]}"; exit 1; fi
exit 0
