#!/usr/bin/env bash
# =============================================================================
#  run-mutation-tp.sh — check that the dispatcher suite can actually FAIL.
# -----------------------------------------------------------------------------
#  Same contract as the three engine runners, pointed at `tp` itself. The suite
#  in tests/tp/ went green the first time it was written, which by this repo's
#  standard means nothing: a scenario that still passes against a broken tp is
#  decoration. This breaks one specific thing at a time and checks the right
#  scenario dies.
#
#  `tp` is small and reads files rather than moving data, so it is tempting to
#  leave it untested. That is exactly backwards: `tp doctor` is the only thing
#  in this repo that will ever notice a container which went live with no DR
#  copy, and its findings only reach cron through its exit code.
#
#  usage:  ./tests/mutation/run-mutation-tp.sh
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SIM="$ROOT/tests/tp/run-tp.sh"
SRC="$ROOT/tp"
PASS=0; FAIL=0; FAILED_NAMES=()

command -v perl >/dev/null || { echo "perl is required for the mutation suite"; exit 1; }
[[ -x "$SIM" ]] || { echo "the dispatcher suite is not where this expects it: $SIM"; exit 1; }
[[ -r "$SRC" ]] || { echo "no dispatcher to mutate: $SRC"; exit 1; }

# $1 = name, $2 = perl s{}{} program, rest = scenarios that MUST fail on it
mutant(){
  local name="$1" prog="$2"; shift 2
  local m ok=1 s
  m="$(mktemp /tmp/tp-mutant.XXXXXX)"
  echo "  [$name]"
  # Same two guards the engine runners carry, for the same reason: a program
  # perl cannot compile writes nothing, and an empty file is valid bash that
  # fails every scenario for no reason at all - which reports as a kill and
  # proves the opposite of one.
  if ! perl -0777 -pe "$prog" "$SRC" > "$m" 2>/dev/null; then
    echo "      x perl refused the mutation program - fix the mutation, not the dispatcher"
    rm -f "$m"; FAIL=$((FAIL+1)); FAILED_NAMES+=("$name"); return
  fi
  if [[ ! -s "$m" ]] || (( $(wc -c <"$m") < $(( $(wc -c <"$SRC") / 2 )) )); then
    echo "      x the mutant is empty or half the dispatcher is gone - that is corruption, not a mutation"
    rm -f "$m"; FAIL=$((FAIL+1)); FAILED_NAMES+=("$name"); return
  fi
  if cmp -s "$m" "$SRC"; then
    echo "      x the mutation matched nothing - its anchor has moved in the dispatcher"
    rm -f "$m"; FAIL=$((FAIL+1)); FAILED_NAMES+=("$name"); return
  fi
  if ! bash -n "$m" 2>/dev/null; then
    echo "      x the mutant does not even parse - fix the mutation, not the dispatcher"
    rm -f "$m"; FAIL=$((FAIL+1)); FAILED_NAMES+=("$name"); return
  fi
  chmod +x "$m"
  for s in "$@"; do
    if TP="$m" "$SIM" "$s" >/dev/null 2>&1; then
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

# The runner's own safety net, exercised before it grades anything - see the
# long version of this argument in run-mutation.sh.
self_check(){
  local out
  out="$(mutant "self-check: a program perl cannot compile" 's{unbalanced' 1 2>&1)"
  [[ "$out" == *"perl refused the mutation program"* ]] || {
    echo "SELF-CHECK FAILED: mutant() accepted a program perl cannot compile" >&2
    printf '%s\n' "$out" >&2; exit 2; }
  out="$(mutant "self-check: a program that empties the dispatcher" 's{\A.*\z}{}s' 1 2>&1)"
  [[ "$out" == *"empty or half the dispatcher is gone"* ]] || {
    echo "SELF-CHECK FAILED: mutant() accepted an empty mutant" >&2
    printf '%s\n' "$out" >&2; exit 2; }
}
self_check

echo "=== tp dispatcher mutation suite ==="

# ---------- doctor's findings have to reach the exit code -------------------
# doctor is run by a human AND by cron. A finding that printed but left the
# exit code at 0 would be invisible in the second case, which is the failure
# mode this whole repo is built against.

# The delimiter is ! rather than {}: the anchor sits next to a closing brace,
# and perl balances one inside s{}{} against the delimiter (CLAUDE.md rule 1).
mutant "doctor prints its findings but always exits 0" \
  's!\Q  return \E\$rc\Q\E$!  return 0!m' \
  11 14 15 17

# Scenario 11 only, not 17: 17 arranges TWO findings on purpose, so the other
# one still carries the exit code and this mutation is invisible there. A
# mutation listed against a scenario that cannot see it proves nothing.
mutant "doctor stops counting the CT that went live with no DR copy" \
  's!\Q        found=1; rc=1\E$!        found=1!m' \
  11

# ---------- dispatch ---------------------------------------------------------

mutant "an unknown subcommand prints the usage and exits 0" \
  's{\Q  *) echo "tp: unknown subcommand \E.\Q\E\$1\Q\E.\Q" >&2; echo; usage; exit 2;;\E}{  *) usage; exit 0;;}' \
  2

mutant "the engine is exec'd without the arguments it was given" \
  's{\Q  exec "\E\$s\Q" "\E\$\Q@"\E}{  exec "\$s"}' \
  3

mutant "a missing engine is exec'd anyway instead of refused" \
  's{\Q  [[ -x "\E\$s\Q" ]] || { echo "tp: \E\$s\Q is missing or not executable" >&2; exit 2; }\E\n}{}' \
  8

# ---------- the output is a deliverable ------------------------------------

# It framed doctor's checks too, until a full-width rule between six short
# sections turned out to be harder to read than the sections. It still frames
# the status TABLE, where columns would otherwise run into whatever the shell
# printed before them - so scenario 6 is what kills this now, and 10 asserts
# the rule is NOT back.
mutant "the rule around the status table is dropped" \
  's{LOGSEP=.#+.}{LOGSEP=""}' \
  6

# ---------- status ----------------------------------------------------------

# The tool a state file belongs to is now in its NAME, so the table can show
# two tools for one container. A pre-split file has no prefix and its tool is
# unknowable; showing it as blank rather than saying so is how a fleet's
# history quietly stops meaning anything.
mutant "status stops labelling pre-split state files" \
  's{\Q      *)          tool="pre-split";;\E}{      *)          tool="";;}' \
  7

# A subcommand that quietly stops being routed is the worst kind of missing:
# `tp distribute` would print the usage and exit 0, which under pressure reads
# as "there is nothing to do" rather than "that command is gone".
mutant "tp distribute stops reaching its engine" \
  's{\Q  distribute) shift; engine ct-distribute.sh "\E\$\@\Q";;\E}{}' \
  3

# The usage block is what somebody reads at 2am to find out the command exists.
# It is a separate failure from the routing being gone, and scenario 1 is what
# notices - so it gets its own mutation rather than being bundled in above.
mutant "the usage stops mentioning a subcommand that exists" \
  's{\Q#    tp distribute DR copy on the backup ->  a compute node\E.\Qs OWN storage\E}{#}' \
  1

echo
echo "=== $PASS mutations killed, $FAIL survived ==="
if (( FAIL > 0 )); then echo "survived: ${FAILED_NAMES[*]}"; exit 1; fi
exit 0
