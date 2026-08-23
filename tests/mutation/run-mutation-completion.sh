#!/usr/bin/env bash
# =============================================================================
#  run-mutation-completion.sh — check that the completion suite can FAIL.
# -----------------------------------------------------------------------------
#  Same contract as every other mutation runner: a green suite means nothing
#  until it has been seen to go red for the right reason. Each mutation here
#  is a bug a person could really write into the completion - a verb dropped,
#  the wrong inventory column, the wrong half of a key:value - and every one
#  of them would TYPE A WRONG WORD INTO AN OPERATOR'S COMMAND LINE if the
#  suite could not see it.
#
#  usage:  ./tests/mutation/run-mutation-completion.sh
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SIM="$ROOT/tests/sim/completion/run-sim-completion.sh"
SRC="$ROOT/tools/ketsync-completion.bash"
PASS=0; FAIL=0; FAILED_NAMES=()

command -v perl >/dev/null || { echo "perl is required for the mutation suite"; exit 1; }
[[ -x "$SIM" ]] || { echo "the completion simulator is not where this expects it: $SIM"; exit 1; }
[[ -r "$SRC" ]] || { echo "nothing to mutate: $SRC"; exit 1; }

# $1 = name, $2 = perl s{}{} program, rest = scenarios that MUST fail on it
mutant(){
  local name="$1" prog="$2"; shift 2
  local m ok=1 s
  m="$(mktemp /tmp/ketsync-comp-mutant.XXXXXX)"
  echo "  [$name]"
  if ! perl -0777 -pe "$prog" "$SRC" > "$m" 2>/dev/null; then
    echo "      x perl refused the mutation program - fix the mutation, not the completion"
    rm -f "$m"; FAIL=$((FAIL+1)); FAILED_NAMES+=("$name"); return
  fi
  if [[ ! -s "$m" ]] || (( $(wc -c <"$m") < $(( $(wc -c <"$SRC") / 2 )) )); then
    echo "      x the mutant is empty or half the file is gone - that is corruption, not a mutation"
    rm -f "$m"; FAIL=$((FAIL+1)); FAILED_NAMES+=("$name"); return
  fi
  if cmp -s "$m" "$SRC"; then
    echo "      x the mutation matched nothing - its anchor has moved in the completion"
    rm -f "$m"; FAIL=$((FAIL+1)); FAILED_NAMES+=("$name"); return
  fi
  if ! bash -n "$m" 2>/dev/null; then
    echo "      x the mutant does not even parse - fix the mutation, not the completion"
    rm -f "$m"; FAIL=$((FAIL+1)); FAILED_NAMES+=("$name"); return
  fi
  for s in "$@"; do
    if COMPLETION="$m" "$SIM" "$s" >/dev/null 2>&1; then
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

# The suite must refuse a mutant that was never really applied. Feed it a
# program perl cannot compile and one that empties the file; if either is
# accepted as a kill, nothing this runner reports can be believed.
self_check(){
  local m rc
  m="$(mktemp /tmp/ketsync-comp-selfcheck.XXXXXX)"
  if perl -0777 -pe 's{unbalanced' "$SRC" > "$m" 2>/dev/null; then
    echo "SELF-CHECK FAILED: perl accepted a program that does not compile"; rm -f "$m"; exit 1
  fi
  if perl -0777 -pe 's{.*}{}s' "$SRC" > "$m" 2>/dev/null && [[ -s "$m" ]]; then
    rc=$(wc -c <"$m")
    if (( rc >= $(wc -c <"$SRC") / 2 )); then
      echo "SELF-CHECK FAILED: an emptied mutant would not be refused"; rm -f "$m"; exit 1
    fi
  fi
  rm -f "$m"
}
self_check

echo "=== ketsync completion mutations ==="

# ---------- the verb list ------------------------------------------------------
mutant "a verb falls out of the list, and TAB stops knowing a real subcommand" \
  's!\Qrecall prepare\E!prepare!' \
  1

mutant "a verb that does not exist is offered, typed faster than it can be doubted" \
  's!\Qmail-setup tp\E!mail-setup teleport tp!' \
  1

# ---------- the values ---------------------------------------------------------
# The quote-heavy programs are built in variables first: the anchors contain
# single quotes, dollars and backslashes, and one layer of quoting at a time
# is the only way anybody can read them back.
mutant "migrate --ctid completes the OLD id - the exact number the engine refuses" \
  's!\Q"\E\$root\Q/inventory/inventory-migrate.tsv" 3\E!"\$root/inventory/inventory-migrate.tsv" 2!' \
  6

prog=$(cat <<'PERL'
s{\Q| tr ' ' '\E\\n\Q' | sed 's/:.*//'\E}{| tr ' ' '\\n' | sed 's/.*://'}
PERL
)
mutant "--dest offers the dataset half of BKP_DESTS instead of the storage id" "$prog" 7

prog=$(cat <<'PERL'
s{\Qsed -En 's/^replica-(.*)-[0-9]{4}-[0-9]{2}-[0-9]{2}\E\\\Q.log\E\$\Q/\E\\1\Q/p'\E}{sed -En 's/^replica-([^-]*)-.*\$/\\1/p'}
PERL
)
mutant "the lane name is split on its own dashes" "$prog" 8

prog=$(cat <<'PERL'
s{\Q| grep -v '^all\E\$\Q' | sort -u\E}{| sort -u}
PERL
)
mutant "lane 'all' is offered as if it were a storage" "$prog" 8

prog=$(cat <<'PERL'
s{\Qawk -v c="\E\$\Q2" '/^[[:space:]]*(#|\E\$\Q)/{next}{print \E\$\Qc}'\E}{awk -v c="\$2" '{print \$c}'}
PERL
)
mutant "comment rows in the tables become suggestions" "$prog" 6 9

# ---------- the repo root ------------------------------------------------------
mutant "the symlink hop is gone - an operator's own ln -s completes nothing" \
  's!\Qif [[ -L "\E\$p\Q" ]]; then\E!if false; then!' \
  11

# ---------- the rename ---------------------------------------------------------
mutant "TAB resurrects --stopped on migrate" \
  's!\Qmigrate)    flags="--all --ctid --storage --final --dry-run --help";;\E!migrate)    flags="--all --ctid --storage --stopped --dry-run --help";;!' \
  5

echo
echo "=== $PASS mutations killed, $FAIL survived ==="
if (( FAIL > 0 )); then echo "survived: ${FAILED_NAMES[*]}"; exit 1; fi
exit 0
