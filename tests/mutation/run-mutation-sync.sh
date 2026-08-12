#!/usr/bin/env bash
# =============================================================================
#  run-mutation-sync.sh — check that the sync simulator can FAIL.
# -----------------------------------------------------------------------------
#  Same contract as tp's suites, pointed at the only command in this layer that
#  writes to another machine. A green simulator means nothing until you have
#  watched it go red for the right reason: this takes lib/cmd_sync.sh, breaks
#  one specific thing in it, and runs the scenarios that are supposed to
#  notice. A scenario that still passes against a broken command is not a test,
#  it is decoration.
#
#  Every mutation is a literal-text edit anchored on a line of the file. When
#  the anchor moves, the mutation applies to nothing, and that is reported as a
#  failure too: a mutation that cannot be applied has stopped proving anything.
#  So any edit to cmd_sync.sh must be mirrored here in the same change, and a
#  broken anchor is never "fixed" by deleting the mutation.
#
#  Three of these put back bugs that were really in this file, on a real fleet,
#  at the same time: the remote path assumed to be the local one, every node
#  treated as a target, and equal generations treated as equal content. They
#  are here so the suite can prove it would catch them a second time.
#
#  usage:  ./tests/mutation/run-mutation-sync.sh
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SIM="$ROOT/tests/sim/sync/run-sim-sync.sh"
SRC="$ROOT/lib/cmd_sync.sh"
PASS=0; FAIL=0; FAILED_NAMES=()

command -v perl >/dev/null || { echo "perl is required for the mutation suite"; exit 1; }
[[ -x "$SIM" ]] || { echo "the sync simulator is not where this expects it: $SIM"; exit 1; }
[[ -r "$SRC" ]] || { echo "nothing to mutate: $SRC"; exit 1; }

# The mutant is a whole ketsync tree with one file swapped, because cmd_sync.sh
# is SOURCED by the dispatcher rather than executed. Copying the tree is what
# lets the simulator run an otherwise untouched ketsync against a broken
# cmd_sync, the same way tp's suites hand their simulators a broken engine.
# $1 = name, $2 = perl s{}{} program, rest = scenarios that MUST fail on it
mutant(){
  local name="$1" prog="$2"; shift 2
  local m ok=1 s tree
  tree="$(mktemp -d /tmp/kssync-mutant.XXXXXX)"
  m="$tree/lib/cmd_sync.sh"
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

echo "=== ketsync sync mutation suite ==="

# ---------- one writer -------------------------------------------------------
mutant "a slave is allowed to push too" \
  's{\Q  [[ "\E\$KS_ROLE\Q" == master ]] ||\E}{  [[ 1 ]] ||}' \
  2

# ---------- the per-machine files -------------------------------------------
# This was live: ketsync.conf carries KS_ROLE, and one copy of it on every node
# makes every node believe it may write.
mutant "ketsync.conf joins the list of files that get pushed" \
  's{\QKS_SYNCED=(nodes.tsv fleet.tsv\E}{KS_SYNCED=(ketsync.conf nodes.tsv fleet.tsv}' \
  4

# The denylist can only do anything when a per-machine file is actually in
# KS_SYNCED, so it takes both edits at once: put ketsync.conf back in the list
# AND stop the denylist refusing. Then the role file really is pushed, the fake
# rsync records it as a violation, and scenario 4 fails on the consequence
# rather than on a message.
mutant "the denylist stops refusing, and the role file goes out with the tables" \
  's{\QKS_SYNCED=(nodes.tsv fleet.tsv\E}{KS_SYNCED=(ketsync.conf nodes.tsv fleet.tsv}; s{^\Q      exit 2\E$}{      break 2}m' \
  4

# ---------- where the other machine keeps its install -----------------------
# The bug: $KS_BASE is where THIS machine's install lives, and it was used as
# the destination too. A fleet whose clones are at different absolute paths
# pushed into a directory that did not exist and reported success.
mutant "a node is written to without asking whether it has a ketsync" \
  's{\Q    if [[ -z "\E\$\(ks_remote_base \Q"\E\$ip\Q")" ]]; then\E}{    if false; then}' \
  11

mutant "every row in nodes.tsv is a target, ketsync or not" \
  's{\Q        log "  \E\$ip\Q nothing installed (expected - a compute node runs no engine)"\E}{        targets+=("\$ip"); log "  \$ip nothing installed (expected - a compute node runs no engine)"}' \
  12

# ---------- generation orders one line, not the file ------------------------
# The other bug that was live: equal generations were taken to mean equal
# content. Every install starts at the generation its .sample shipped with, so
# that is the state of every fleet that has never synced - which is exactly
# when somebody runs this for the first time.
mutant "the same generation is assumed to mean the same file" \
  's{\Q      [[ "\E\$\{RTEXT\[\$key\]\}\Q" == "\E\$ltext\Q" ]] && continue\E}{      continue}' \
  7

mutant "a fork is noticed and pushed over anyway" \
  's{\Q  if (( forked && ! bump )); then\E}{  if false; then}' \
  7

# ---------- the stale master ------------------------------------------------
mutant "a stale master walks its old tables back over a newer slave" \
  's{\Q      if (( rgen > gen )); then\E}{      if false; then}' \
  6

# ---------- --bump is a decision, and it has to actually raise --------------
mutant "--bump raises nothing, so the push it enables is still refused" \
  's{\Q      newgen=\E\$\(\( top \+ 1 \)\)}{      newgen=\$(( top ))}' \
  10

mutant "--bump raises past this machine only, ignoring what the far side holds" \
  's{\Q        (( \E\$\{RGEN\[\$ip\|\$f\]:-0\}\Q > top )) && top="\E\$\{RGEN\[\$ip\|\$f\]\}\Q"\E}{        :}' \
  10b

# ---------- read-only means read-only ---------------------------------------
mutant "--dry-run pushes anyway" \
  's{\Q      if (( dry )); then log "  \E\$ip\Q \E\$f\Q would go from generation \E\$rgen\Q to \E\$gen\Q"; n=\E\$\(\( n \+ 1 \)\)\Q; continue; fi\E}{      if false; then :; fi}' \
  3

mutant "--diff writes as well as shows" \
  's{\Q    log "=== diff finished: nothing was sent ==="\E}{    log "=== diff finished: nothing was sent ==="; rsync -a -e "ssh \$KS_SSH_OPTS" "\$KS_BASE/nodes.tsv" "root@\$\{targets[0]\}:\$KS_BASE/nodes.tsv"}' \
  9

# ---------- an address nobody wrote down ------------------------------------
mutant "--to accepts a machine that is in no table" \
  's{\Q|| die "\E\$2\Q is not in\E}{|| : "\$2 is not in}' \
  15

# ---------- a file nobody can order -----------------------------------------
mutant "a table with no generation line is pushed anyway" \
  's{\Q    [[ -n "\E\$gen\Q" ]] || \E}{    [[ 1 ]] || }' \
  16

echo
echo "=== $PASS mutations killed, $FAIL survived ==="
if (( FAIL > 0 )); then echo "survived: ${FAILED_NAMES[*]}"; exit 1; fi
exit 0
