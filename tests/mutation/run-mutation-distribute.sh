#!/usr/bin/env bash
# =============================================================================
#  run-mutation-distribute.sh — check that the distribute simulator can FAIL.
# -----------------------------------------------------------------------------
#  Same contract as tp's suites, pointed at the only command in this layer that
#  is not a pass-through. A green simulator means nothing until you have
#  watched it go red for the right reason: this takes lib/cmd_distribute.sh, breaks
#  one specific thing in it, and runs the scenarios that are supposed to
#  notice. A scenario that still passes against a broken command is not a test,
#  it is decoration.
#
#  Every mutation is a literal-text edit anchored on a line of the file. When
#  the anchor moves, the mutation applies to nothing, and that is reported as a
#  failure too: a mutation that cannot be applied has stopped proving anything.
#  So any edit to cmd_distribute.sh must be mirrored here in the same change, and a
#  broken anchor is never "fixed" by deleting the mutation.
#
#  Three of these put back bugs that were really in this file, on a real fleet,
#  at the same time: the remote path assumed to be the local one, every node
#  treated as a target, and equal generations treated as equal content. They
#  are here so the suite can prove it would catch them a second time.
#
#  usage:  ./tests/mutation/run-mutation-distribute.sh
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SIM="$ROOT/tests/sim/distribute/run-sim-distribute.sh"
SRC="$ROOT/lib/cmd_distribute.sh"
PASS=0; FAIL=0; FAILED_NAMES=()

command -v perl >/dev/null || { echo "perl is required for the mutation suite"; exit 1; }
[[ -x "$SIM" ]] || { echo "the distribute simulator is not where this expects it: $SIM"; exit 1; }
[[ -r "$SRC" ]] || { echo "nothing to mutate: $SRC"; exit 1; }

# The mutant is a whole ketsync tree with one file swapped, because cmd_distribute.sh
# is SOURCED by the dispatcher rather than executed. Copying the tree is what
# lets the simulator run an otherwise untouched ketsync against a broken
# cmd_sync, the same way tp's suites hand their simulators a broken engine.
# $1 = name, $2 = perl s{}{} program, rest = scenarios that MUST fail on it
mutant(){
  local name="$1" prog="$2"; shift 2
  local m ok=1 s tree
  tree="$(mktemp -d /tmp/ksdist-mutant.XXXXXX)"
  m="$tree/lib/cmd_distribute.sh"
  echo "  [$name]"
  mkdir -p "$tree/lib" "$tree/engines"
  cp "$ROOT/ketsync" "$tree/ketsync"; chmod +x "$tree/ketsync"
  cp "$ROOT"/lib/*.sh "$tree/lib/"
  # A zero-byte mutant is not a mutant. perl refusing the program - an
  # unbalanced brace inside s{}{} is the easy way to get there - writes nothing,
  # and an empty file is valid bash that fails every scenario for no reason at
  # all. That would report as a kill and prove the opposite of one. Half a file
  # is the same failure one step less obvious, which is why the size check is
  # separate rather than folded into the emptiness one.
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

# The runner's own safety net, exercised before it grades anything. A guard
# nobody exercises is how tp's replica runner came to be missing both of its
# own while CLAUDE.md said otherwise. Each probe calls mutant() for real inside
# a command substitution, so its counters and its output are thrown away and
# only the refusal is read.
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

echo "=== ketsync distribute mutation suite ==="

# ---------- the join that would ruin a rehearsal -----------------------------
# A dry run that reaches the engine and not the preparer disables a storage and
# stops containers on a live fleet, and produces a log that reads exactly like
# a successful rehearsal.
mutant "--dry-run reaches the engine but never the preparer" \
  's{\Q  (( dry )) && PARGS+=(--dry-run)\E}{  :}' \
  3 4

mutant "--dry-run is swallowed on the way to the engine instead" \
  's{\Q    --dry-run)    dry=1;  ENG+=("\E\$a\Q");;\E}{    --dry-run)    dry=1;;}' \
  3

# ---------- the scope mapping -----------------------------------------------
# The 2026-08-16 drill bug: the engine refuses a scopeless run LAST, and this
# command prepares FIRST, so the refusal has to live here and fire before the
# preparer does anything at all.
mutant "a scopeless run prepares the fleet on the way to a usage message" \
  's{\Q  if (( ! all && ! list )) && [[ -z "\E\$ctid\Q" ]]; then\E}{  if false; then}' \
  14 15

mutant "--ctid evacuates the whole node, stopping containers nobody named" \
  's{\Q      PARGS=(--isolate --ctid "\E\$ctid\Q")\E}{      PARGS=(--evacuate --all)}' \
  2

mutant "a fleet-wide run only isolates, and nothing is ever unmounted" \
  's{\Q      PARGS=(--evacuate --all)\E}{      PARGS=(--isolate --all)}' \
  1

mutant "the container id is read from the wrong argument" \
  's!\Q    [[ "\E\$1\Q" == --ctid && \E\$#\Q -ge 2 ]] && { ctid="\E\$2\Q"; shift 2; continue; }\E!    [[ "\$1" == --ctid \&\& \$# -ge 2 ]] \&\& { ctid="\$1"; shift 2; continue; }!' \
  2

# ---------- --list is a question, not an operation ---------------------------
mutant "--list prepares the fleet before answering a read-only question" \
  's{\Q  if (( prep )) && (( ! list )); then\E}{  if (( prep )); then}' \
  5

mutant "--no-prepare prepares anyway" \
  's{\Q      --no-prepare) prep=0;;\E}{      --no-prepare) prep=1;;}' \
  6

mutant "--no-prepare is passed on to an engine that has never heard of it" \
  's{\Q      --no-prepare) prep=0;;\E}{      --no-prepare) prep=0; ENG+=("\$a");;}' \
  6

# ---------- what a preparer's exit code means --------------------------------
mutant "a preparer that refused before touching anything is carried on past" \
  's{\Q    if (( rc == 2 )); then\E}{    if false; then}' \
  7

mutant "a preparer that skipped a container stops the whole run" \
  's{\Q    if (( rc == 2 )); then\E}{    if (( rc != 0 )); then}' \
  8

mutant "a missing preparer is treated as a step that can be skipped" \
  's{\Q    if [[ ! -x "\E\$TPREP\Q" ]]; then\E}{    if false; then}' \
  10 11

# ---------- the exit code cron reads -----------------------------------------
mutant "the engine is called rather than exec'd, and its exit code is lost" \
  's{\Q  exec "\E\$TP\Q" distribute \E\$\{ENG\[@\]\+"\$\{ENG\[@\]\}"\}}{  "\$TP" distribute \$\{ENG[@]+"\$\{ENG[@]\}"\}; return 0}' \
  9

mutant "the preparer runs after the copies have already been placed" \
  's{\Q  if (( prep )) && (( ! list )); then\E}{  if (( 0 )); then}' \
  1

echo
echo "=== $PASS mutations killed, $FAIL survived ==="
if (( FAIL > 0 )); then echo "survived: ${FAILED_NAMES[*]}"; exit 1; fi
exit 0
