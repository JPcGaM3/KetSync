#!/usr/bin/env bash
# =============================================================================
#  run-mutation-watch.sh — check that the watch simulator can FAIL.
# -----------------------------------------------------------------------------
#  Same contract as every other suite here. watch's output is a mail arriving
#  while nobody is at a terminal, so every mutation below is a way the mail
#  goes quietly wrong: sent every run until it is filtered, sent to the wrong
#  tier, "recovered" claimed about a thing merely lost sight of, a failed send
#  remembered as delivered. Each one is a bug the fleet would never surface on
#  its own, because the whole point of watch is the hour nobody is looking.
#
#  usage:  ./tests/mutation/run-mutation-watch.sh
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SIM="$ROOT/tests/sim/watch/run-sim-watch.sh"
SRC="$ROOT/lib/cmd_watch.sh"
PASS=0; FAIL=0; FAILED_NAMES=()

command -v perl >/dev/null || { echo "perl is required for the mutation suite"; exit 1; }
[[ -x "$SIM" ]] || { echo "the watch simulator is not where this expects it: $SIM"; exit 1; }
[[ -r "$SRC" ]] || { echo "nothing to mutate: $SRC"; exit 1; }

# A whole ketsync tree with one file swapped, because cmd_watch.sh is SOURCED
# by the dispatcher - and the simulator copies lib/ from beside the dispatcher
# it is handed, which is what makes this work.
mutant(){
  local name="$1" prog="$2"; shift 2
  local m ok=1 s tree
  tree="$(mktemp -d /tmp/kswatch-mutant.XXXXXX)"
  echo "  [$name]"
  mkdir -p "$tree/lib" "$tree/engines"
  cp "$ROOT/ketsync" "$tree/ketsync"; chmod +x "$tree/ketsync"
  cp "$ROOT"/lib/*.sh "$tree/lib/"
  m="$tree/lib/cmd_watch.sh"
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

echo "=== ketsync watch mutation suite ==="

# ---------- what must refuse before anything runs ----------------------------
# ---------- the split scope: fleet here, master-only there --------------------
# A slave that runs the master's checks is the objection this design used to
# carry - two half-tuned alert streams, every node event mailed twice. The
# scope is the whole reason a second watcher is allowed at all.
mutant "a slave watches the whole fleet, so every alert arrives twice" \
  's{\Q  if (( slave )); then\E\n\Q    # The one question, asked properly.\E}{  if false; then\n    # The one question, asked properly.}' \
  16

mutant "the master's death stops being noticed at all" \
  's{\Q    (( up )) || add_event master-unreachable INFRA \E\\}{    (( up )) || true \\}' \
  16

mutant "one failed ssh is enough, so every blip mails a dead master" \
  's{\Q    local tries="\E\$\Q{KS_MASTER_TRIES:-3}"\E}{    local tries="1"}' \
  19

mutant "a slave mails doctor's report as though it were the fleet's" \
  's{\Q  if (( slave && digest )); then\E}{  if false; then}' \
  20

mutant "a role nobody recognises is treated as a master" \
  's{\Q    slave)  slave=1;;\E}{    slave)  slave=1;;\n    maser) ;;}' \
  21

mutant "no addresses configured is carried on past" \
  's{\Q    if [[ -z "\E\$\Q{KS_MAIL_FROM:-}" || -z "\E\$\Q{KS_MAIL_INFRA:-}" || -z "\E\$\Q{KS_MAIL_NODE:-}" ]]; then\E}{    if false; then}' \
  2

# ---------- the edge, which is the whole design -------------------------------
mutant "every run mails the same standing problem again" \
  's{\Q  for k in "\E\$\Q{!NOWT[@]}"; do [[ -n "\E\$\Q{OLDT[\E\$\Qk]:-}" ]] || RAISED["\E\$\Qk"]=1; done\E}{  for k in "\${!NOWT[@]}"; do RAISED["\$k"]=1; done}' \
  4

mutant "a problem that goes away is never said to have cleared" \
  's{\Q  for k in "\E\$\Q{!OLDT[@]}"; do [[ -n "\E\$\Q{NOWT[\E\$\Qk]:-}" ]] || CLEARED["\E\$\Qk"]=1; done\E}{  for k in "\${!OLDT[@]}"; do :; done}' \
  5

# ---------- the checks themselves ---------------------------------------------
mutant "PAUSE stops being noticed, and every copy quietly ages" \
  's{\Q  [[ -f "\E\$PAUSE\Q" ]] && add_event pause INFRA \E\\}{  false && add_event pause INFRA \\}' \
  6

mutant "a node that stops answering stops being an event" \
  's{\Q    ks_ssh "\E\$ip\Q" true 2>/dev/null || add_event "node-unreachable:\E\$ip\Q" NODE \E\\}{    true || add_event "node-unreachable:\$ip" NODE \\}' \
  3

mutant "the backup node down is demoted to one more node line" \
  's{\Q    add_event backup-unreachable INFRA \E\\}{    add_event backup-unreachable NODE \\}' \
  7

mutant "stand-ins placed stops being an infra fact" \
  's{\Q    if [[ -n "\E\$nine\Q" ]]; then\E}{    if false; then}' \
  8

mutant "the records under a placed stand-in are raised anyway" \
  's{\Q      else\E\n\Q        local n\E}{      fi\n      if true; then\n        local n}' \
  8

mutant "an unreadable cluster clears what it can no longer see" \
  's{\Q        if (( cluster_unknown )) || { [[ -n "\E\$nine\Q" && "\E\$k\Q" != dr-standins ]]; }; then\E}{        if false; then}' \
  10

# ---------- delivered-and-remembered or neither -------------------------------
mutant "--dry-run sends the mail it promised not to" \
  's{\Q    if (( dry )); then\E\n\Q      log "DRY: would mail \E\$1\Q: \E\$2\Q"\E}{    if false; then\n      log "DRY: would mail \$1: \$2"}' \
  11

mutant "a failed send still marks every event delivered" \
  's{\Q  if (( ! dry && ! sendfail )); then\E}{  if (( ! dry )); then}' \
  12

mutant "the exit code forgets the mail that never went out" \
  's{\Q  return \E\$sendfail\E}{  return 0}' \
  12

mutant "the envelope sender stays root@hostname, and the relay rejects every mail" \
  's!\Q    } | sendmail -t -i -f "\E\$KS_MAIL_FROM\Q"\E!    } | sendmail -t -i!' \
  3

# ---------- the dead-man -------------------------------------------------------
mutant "the dead-man is pinged with no URL configured" \
  's{\Q    if [[ -n "\E\$\Q{KS_WATCH_HEALTHCHECK:-}" ]]; then\E}{    if true; then}' \
  13

# ---------- the digest ----------------------------------------------------------
mutant "the digest goes to the infra address instead of its own" \
  's{\Q    if send_mail "\E\$KS_MAIL_DIGEST\Q" \E\\}{    if send_mail "\$KS_MAIL_INFRA" \\}' \
  14

echo
echo "=== $PASS mutations killed, $FAIL survived ==="
if (( FAIL > 0 )); then echo "survived: ${FAILED_NAMES[*]}"; exit 1; fi
exit 0
