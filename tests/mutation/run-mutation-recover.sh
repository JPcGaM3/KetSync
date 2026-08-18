#!/usr/bin/env bash
# =============================================================================
#  run-mutation-recover.sh — check that the recover simulator can FAIL.
# -----------------------------------------------------------------------------
#  Same contract as every other suite here. recover is composition, so every
#  mutation below is a JOIN going quiet - a guard between two steps inverted,
#  a flag not passed down, a failure not carried into the exit code - and each
#  one is a bug that would leave the fleet half-returned while the log read
#  like a finished disaster.
#
#  usage:  ./tests/mutation/run-mutation-recover.sh
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SIM="$ROOT/tests/sim/recover/run-sim-recover.sh"
SRC="$ROOT/lib/cmd_recover.sh"
PASS=0; FAIL=0; FAILED_NAMES=()

command -v perl >/dev/null || { echo "perl is required for the mutation suite"; exit 1; }
[[ -x "$SIM" ]] || { echo "the recover simulator is not where this expects it: $SIM"; exit 1; }
[[ -r "$SRC" ]] || { echo "nothing to mutate: $SRC"; exit 1; }

# A whole ketsync tree with one file swapped, because cmd_recover.sh is SOURCED
# by the dispatcher - and the simulator copies lib/ from beside the dispatcher
# it is handed, which is what makes this work.
mutant(){
  local name="$1" prog="$2"; shift 2
  local m ok=1 s tree
  tree="$(mktemp -d /tmp/ksrec-mutant.XXXXXX)"
  echo "  [$name]"
  mkdir -p "$tree/lib" "$tree/engines"
  cp "$ROOT/ketsync" "$tree/ketsync"; chmod +x "$tree/ketsync"
  cp "$ROOT"/lib/*.sh "$tree/lib/"
  m="$tree/lib/cmd_recover.sh"
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

# The runner's own safety net, exercised before it grades anything.
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
}
self_check

echo "=== ketsync recover mutation suite ==="

# ---------- what must refuse before anything runs ----------------------------
mutant "the role guard is gone, so a slave runs the failback" \
  's{\Q  if [[ "\E\$\{KS_ROLE:-\}\Q" != master ]]; then\E}{  if false; then}' \
  10

mutant "an unanswered backup node reads as a fleet with nothing left" \
  's{\Q  if ! ks_ssh "\E\$bkp\Q" true 2>/dev/null; then\E}{  if false; then}' \
  16

mutant "the checklist runs the engines instead of reading" \
  's{\Q  if (( list )); then\E}{  if false; then}' \
  9

# ---------- the worklist ------------------------------------------------------
mutant "a placed stand-in stops being work" \
  's{\Q    DRID[\E\$\{id#9\}\Q]="\E\$id\Q"; DRNODE[\E\$\{id#9\}\Q]="\E\$n\Q"\E}{    :}' \
  1

# ---------- the fsck ----------------------------------------------------------
mutant "a dirty image stops being noticed" \
  's{\Q    if [[ "\E\$IMG_STATE\Q" == *"with errors"* ]]; then\E}{    if false; then}' \
  4

mutant "an image e2fsck could not repair is failed back over anyway" \
  's{\Q        if (( rc >= 4 )); then\E}{        if false; then}' \
  5

# The next four put back the 2026-08-16 drill bug and its cousins: the probe
# ran inside the window where the NFS mount had not reappeared, and absence
# was read as cleanliness.
mutant "an image nobody can see is called clean" \
  's{\Q  img_unseen(){ [[ -z "\E\$IMG_STATE\Q" || "\E\$IMG_STATE\Q" == NOIMAGE || "\E\$IMG_STATE\Q" == NOCONFIG ]]; }\E}{  img_unseen(){ false; }}' \
  17 19

mutant "the unseen image is reported but nothing is stranded" \
  's{\Q          CTBAD[\E\$ct\Q]=1; failed=1; continue\E}{          :}' \
  17

mutant "the wait gives up without ever asking again" \
  's{\Q        while (( try < tries )); do\E}{        while false; do}' \
  18

mutant "a dry run claims the unseen image is clean" \
  's{\Q    elif ! img_unseen; then\E}{    else}' \
  19

mutant "a woken production container is written toward anyway" \
  's{\Q    if [[ "\E\$pst\Q" == running ]]; then\E}{    if false; then}' \
  7

# ---------- the failback ------------------------------------------------------
mutant "a stand-in that is still RUNNING is failed back over" \
  's{\Q    if [[ "\E\$dst\Q" != stopped ]]; then\E}{    if false; then}' \
  6

mutant "PAUSE is never created, so the next cron tick eats the copies" \
  's{\Q    if (( ! dry )) && [[ ! -f "\E\$PAUSE\Q" ]]; then\E}{    if false; then}' \
  13

mutant "--dry-run stops reaching the failback" \
  's{\Q    declare -a FA=(--ctid "\E\$ct\Q" --final); (( dry )) && FA+=(--dry-run)\E}{    declare -a FA=(--ctid "\$ct" --final)}' \
  8

# ---------- what a failure is allowed to touch --------------------------------
# The first CTBAD guard is the failback loop's; the second, matched through
# the grep that follows it, is the restore/cleanup loop's. Same line of text,
# two different joins, and each has its own scenario.
mutant "a container whose fsck failed is failed back anyway" \
  's{\Q    [[ -n "\E\$\{CTBAD\[\$ct\]:-\}\Q" ]] && continue\E}{    :}' \
  5

mutant "a container whose failback failed gets its network back anyway" \
  's!\Q ]] && continue\E\n\Q    if grep -qx "\E!\ ]] || continue\n    if grep -qx "!' \
  12

mutant "--destroy leaks into a run that did not ask for it" \
  's{\Q(( destroy )) && KA+=(--destroy)\E}{KA+=(--destroy)}' \
  2

# ---------- the end, which must be earned -------------------------------------
mutant "a red run removes PAUSE and restarts replication anyway" \
  's{\Q    if (( failed )); then\E}{    if false; then}' \
  12

mutant "PAUSE stays behind after a green destroy" \
  's{\Q      rm -f "\E\$PAUSE\Q"\E\n}{      :\n}' \
  1

mutant "the first replica round is skipped and called ok" \
  's{\Q      if "\E\$TREP\Q"; then\E}{      if true; then}' \
  1 15

mutant "the exit code forgets what failed" \
  's{\Q  return \E\$failed\E}{  return 0}' \
  6


# ---------- --ctid is a scope, not a suggestion -------------------------------
mutant "the --ctid scope leaks: recovering one container recovers everything" \
  's{\Q    CTS=("\E\$only\Q")\E}{    :}' \
  21

echo
echo "=== $PASS mutations killed, $FAIL survived ==="
if (( FAIL > 0 )); then echo "survived: ${FAILED_NAMES[*]}"; exit 1; fi
exit 0
