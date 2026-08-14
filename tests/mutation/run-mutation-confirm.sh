#!/usr/bin/env bash
# =============================================================================
#  run-mutation-confirm.sh — check that the confirmation simulator can FAIL.
# -----------------------------------------------------------------------------
#  Same contract as tp's suites, pointed at the question asked before anything is written. A green simulator means nothing until you have
#  watched it go red for the right reason: this takes ketsync, breaks
#  one specific thing in it, and runs the scenarios that are supposed to
#  notice. A scenario that still passes against a broken command is not a test,
#  it is decoration.
#
#  Every mutation is a literal-text edit anchored on a line of the file. When
#  the anchor moves, the mutation applies to nothing, and that is reported as a
#  failure too: a mutation that cannot be applied has stopped proving anything.
#  So any edit to ketsync must be mirrored here in the same change, and a
#  broken anchor is never "fixed" by deleting the mutation.
#
#  Three of these put back bugs that were really in this file, on a real fleet,
#  at the same time: the remote path assumed to be the local one, every node
#  treated as a target, and equal generations treated as equal content. They
#  are here so the suite can prove it would catch them a second time.
#
#  usage:  ./tests/mutation/run-mutation-confirm.sh
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SIM="$ROOT/tests/sim/confirm/run-sim-confirm.sh"
SRC="$ROOT/ketsync"
PASS=0; FAIL=0; FAILED_NAMES=()

command -v perl >/dev/null || { echo "perl is required for the mutation suite"; exit 1; }
[[ -x "$SIM" ]] || { echo "the confirmation simulator is not where this expects it: $SIM"; exit 1; }
[[ -r "$SRC" ]] || { echo "nothing to mutate: $SRC"; exit 1; }

# The mutant is a whole ketsync tree with one file swapped, because ketsync
# is SOURCED by the dispatcher rather than executed. Copying the tree is what
# lets the simulator run an otherwise untouched ketsync against a broken
# cmd_sync, the same way tp's suites hand their simulators a broken engine.
# $1 = name, $2 = perl s{}{} program, rest = scenarios that MUST fail on it
mutant(){
  local name="$1" prog="$2"; shift 2
  local m ok=1 s tree
  tree="$(mktemp -d /tmp/ksconf-mutant.XXXXXX)"
  m="$tree/ketsync"
  echo "  [$name]"
  mkdir -p "$tree/lib" "$tree/engines/tp"
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

# The same contract, pointed at lib/common.sh instead: ks_confirm lives there
# because it is shared, and the parts of it that matter - the terminal check
# and the default - cannot be reached by mutating the dispatcher.
mutant_lib(){
  local name="$1" prog="$2"; shift 2
  local m ok=1 s tree
  tree="$(mktemp -d /tmp/ksconf-mutant.XXXXXX)"
  echo "  [$name]"
  mkdir -p "$tree/lib" "$tree/engines/tp"
  cp "$ROOT/ketsync" "$tree/ketsync"; chmod +x "$tree/ketsync"
  cp "$ROOT"/lib/*.sh "$tree/lib/"
  m="$tree/lib/common.sh"
  if ! perl -0777 -pe "$prog" "$ROOT/lib/common.sh" > "$m" 2>/dev/null; then
    echo "      x perl refused the mutation program - fix the mutation, not the command"
    rm -rf "$tree"; FAIL=$((FAIL+1)); FAILED_NAMES+=("$name"); return
  fi
  if [[ ! -s "$m" ]] || (( $(wc -c <"$m") < $(( $(wc -c <"$ROOT/lib/common.sh") / 2 )) )); then
    echo "      x the mutant is empty or half the file is gone - that is corruption, not a mutation"
    rm -rf "$tree"; FAIL=$((FAIL+1)); FAILED_NAMES+=("$name"); return
  fi
  if cmp -s "$m" "$ROOT/lib/common.sh"; then
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

echo "=== ketsync confirmation mutation suite ==="

# ---------- the silent answer ------------------------------------------------
# Nothing on stdin means `read` returns immediately and empty. Treating that as
# "no" and exiting 0 is a nightly cron reporting success having done nothing.
mutant_lib "no terminal is taken as an answer of no, and the run exits 0" \
  's{\Q  if [[ ! -t 0 ]]; then\E}{  if false; then}' \
  1

mutant_lib "the default is yes, so a fast Enter overwrites a customer's copy" \
  's{\Q    y|Y|yes|YES) return 0;;\E}{    y|Y|yes|YES|"") return 0;;}' \
  9

mutant_lib "anything typed is taken as agreement" \
  's{\Q    *) say "nothing was done."; return 1;;\E}{    *) return 0;;}' \
  8 9

mutant_lib "-y is honoured even when it was never given" \
  's{\Q  if [[ "\E\$\{KS_ASSUME_YES:-0\}\Q" == 1 ]]; then return 0; fi\E}{  return 0}' \
  1 8

# ---------- which verbs write ------------------------------------------------
mutant "a writing verb is not recognised as one" \
  's{\Q    migrate|replica|failback|distribute|recall|prepare|isolate|restore|evacuate|sync) return 0;;\E}{    nothing) return 0;;}' \
  1

mutant "sync stops counting as something that writes to other machines" \
  's{\Qrestore|evacuate|sync) return 0;;\E}{restore|evacuate) return 0;;}' \
  12

mutant "--dry-run is asked about, which is how a prompt stops being read" \
  's{\Q    [[ "\E\$a\Q" == --dry-run || "\E\$a\Q" == --list ]] && return 1\E}{    [[ "\$a" == --nothing ]] \&\& return 1}' \
  4 5

# ---------- -y ---------------------------------------------------------------
mutant "-y is passed on to an engine that has never heard of it" \
  's{\Q    -y|--yes) KS_ASSUME_YES=1;;\E}{    -y|--yes) KS_ASSUME_YES=1; KS_ARGV+=("\$_a");;}' \
  3

mutant "-y is stripped but never actually skips the question" \
  's{\Q    -y|--yes) KS_ASSUME_YES=1;;\E}{    -y|--yes) :;;}' \
  2

# ---------- the call site ----------------------------------------------------
mutant "the question is asked and the answer is thrown away" \
  's{\Q    || exit \E\$\?}{    || true}' \
  8

mutant "nothing is ever asked at all" \
  's{\Qif ks_writes "\E\$\{1:-\}\Q" "\E\$@\Q"; then\E}{if false; then}' \
  1 8

# ---------- a bare verb is an incomplete instruction -------------------------
mutant "a bare writing verb is taken as every container in the fleet" \
  's{\Qif (( \E\$#\Q == 1 )) && ks_writes "\E\$1\Q" && ks_menu "\E\$1\Q"; then\E}{if false; then}' \
  13

mutant "the menu is printed and the command runs anyway" \
  's{\Q  exit 2\E\n\Qfi\E\n\n\Qif ks_writes "\E}{  :\nfi\n\nif ks_writes "}' \
  13

mutant "any number of arguments counts as a bare verb, so nothing ever runs" \
  's{\Qif (( \E\$#\Q == 1 )) && ks_writes\E}{if (( \$# >= 1 )) \&\& ks_writes}' \
  2

echo
echo "=== $PASS mutations killed, $FAIL survived ==="
if (( FAIL > 0 )); then echo "survived: ${FAILED_NAMES[*]}"; exit 1; fi
exit 0
