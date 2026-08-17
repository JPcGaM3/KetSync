#!/usr/bin/env bash
# =============================================================================
#  run-mutation-mail.sh — check that the mail-setup simulator can FAIL.
# -----------------------------------------------------------------------------
#  Same contract as every other suite here. mail-setup's job is a boundary:
#  conf keys in, satellite argv out, exit code back. Every mutation below is
#  one of those quietly wrong: an empty relay carried on past, a --test that
#  stops naming the addresses watch uses, an exit code swallowed, a broken
#  checkout run anyway, a flag this verb never took accepted as if it had.
#
#  usage:  ./tests/mutation/run-mutation-mail.sh
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SIM="$ROOT/tests/sim/mail/run-sim-mail.sh"
SRC="$ROOT/lib/cmd_mail.sh"
PASS=0; FAIL=0; FAILED_NAMES=()

command -v perl >/dev/null || { echo "perl is required for the mutation suite"; exit 1; }
[[ -x "$SIM" ]] || { echo "the mail simulator is not where this expects it: $SIM"; exit 1; }
[[ -r "$SRC" ]] || { echo "nothing to mutate: $SRC"; exit 1; }

# A whole ketsync tree with one file swapped, because cmd_mail.sh is SOURCED
# by the dispatcher - and the simulator copies lib/ from beside the dispatcher
# it is handed, which is what makes this work.
mutant(){
  local name="$1" prog="$2"; shift 2
  local m ok=1 s tree
  tree="$(mktemp -d /tmp/ksmail-mutant.XXXXXX)"
  echo "  [$name]"
  mkdir -p "$tree/lib"
  cp "$ROOT/ketsync" "$tree/ketsync"; chmod +x "$tree/ketsync"
  cp "$ROOT"/lib/*.sh "$tree/lib/"
  m="$tree/lib/cmd_mail.sh"
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

echo "=== ketsync mail-setup mutation suite ==="

mutant "an empty relay is carried on past and handed to the satellite" \
  's{\Q  if (( \E\$\Q{#missing[@]} )); then\E}{  if false; then}' \
  3 4

mutant "--test stops sending the addresses watch itself uses" \
  's{\Q  (( dotest )) && ARGS+=(--test "\E\$\QKS_MAIL_INFRA" --from "\E\$\QKS_MAIL_FROM")\E}{  (( dotest )) && ARGS+=()}' \
  1

mutant "the satellite's exit code is swallowed on its way back" \
  's{\Q  exec "\E\$\QSAT" "\E\$\Q{ARGS[@]}"\E}{  "\$SAT" "\${ARGS[@]}"\n  return 0}' \
  8

mutant "a broken checkout is run anyway instead of being named" \
  's{\Q  if [[ ! -x "\E\$\QSAT" ]]; then\E}{  if false; then}' \
  7

mutant "a flag this verb never took is accepted as if it had" \
  's{\Q      *) say "refused: unknown argument \E.\$\Qa\E.\Q - mail-setup takes only --test"\E\n\Q         say "  the relay, user and keyfile come from conf/ketsync.conf, not from flags."\E\n\Q         return 2;;\E}{      *) : ;;}' \
  6

echo
echo "=== $PASS mutations killed, $FAIL survived ==="
if (( FAIL > 0 )); then echo "survived: ${FAILED_NAMES[*]}"; exit 1; fi
exit 0
