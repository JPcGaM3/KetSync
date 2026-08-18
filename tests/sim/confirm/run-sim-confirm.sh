#!/usr/bin/env bash
# =============================================================================
#  run-sim-confirm.sh — the question asked before anything is written.
# -----------------------------------------------------------------------------
#  The confirmation is the one piece of this system whose whole behaviour
#  depends on something no other test controls: whether there is a person on
#  the other end. Everything about it is a trap.
#
#    - no terminal and no -y must REFUSE, not answer "no" quietly. `read` with
#      nothing on stdin returns immediately and empty, and taking that as a no
#      would be a nightly cron reporting success having done nothing at all
#    - --dry-run and --list must never ask, or the answer gets trained
#    - -y must be removed before the engine sees it, because no engine has
#      heard of it
#    - the default must be NO, including for a bare Enter
#
#  The prompting cases need a real terminal, so they run under `script`, which
#  allocates a pty. Piping into the command tests the opposite case by
#  accident: a pipe is not a terminal, which is exactly what the refusal is
#  for.
#
#  usage:  ./tests/sim/confirm/run-sim-confirm.sh        every scenario
#          ./tests/sim/confirm/run-sim-confirm.sh 3      scenario 3 only
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
KS="${KS:-$ROOT/ketsync}"

[[ -x "$KS" ]] || { echo "ketsync is not executable: $KS" >&2; exit 2; }
command -v script >/dev/null || {
  echo "this suite needs 'script' (util-linux) to allocate a pty - without it" >&2
  echo "the prompting half cannot be tested at all, and passing quietly would" >&2
  echo "be worse than refusing to run." >&2; exit 2; }
ONLY="${1:-}"
PASS=0; FAIL=0; FAILED_NAMES=()
ME=10.100.1.17

new_world(){
  SIMROOT="$(mktemp -d /tmp/ksconf-sim.XXXXXX)"
  MASTER="$SIMROOT/master"
  mkdir -p "$MASTER/lib" "$MASTER/conf" "$MASTER/engines" "$MASTER/logs"
  : > "$SIMROOT/trace"
  local ksdir; ksdir="$(cd "$(dirname "$KS")" && pwd)"
  cp "$KS" "$MASTER/ketsync"; chmod +x "$MASTER/ketsync"
  cp "$ksdir"/lib/*.sh "$MASTER/lib/"
  cat > "$MASTER/conf/ketsync.conf" <<CONF
KS_ROLE=master
KS_MASTER_IP=$ME
CONF
  printf '# generation: 1\n%s\tstorage\n' "$ME" > "$MASTER/conf/nodes.tsv"
  local f
  for f in tp ct-prepare.sh; do
    cat > "$MASTER/engines/$f" <<STUB
#!/usr/bin/env bash
printf '%s %s\n' "$f" "\$*" >> "$SIMROOT/trace"
exit 0
STUB
    chmod +x "$MASTER/engines/$f"
  done
}

# No terminal: a pipe, a redirect, a cron. The common case, and the one whose
# wrong answer is silent.
run_headless(){
  ( cd "$MASTER" && ./ketsync "$@" </dev/null ) > "$SIMROOT/out" 2>&1
  RC=$?; OUT="$(cat "$SIMROOT/out")"; TRACE="$(cat "$SIMROOT/trace")"
}
# A terminal, with an answer typed into it.
run_tty(){   # $1 = what the person types, rest = arguments
  local ans="$1"; shift
  ( cd "$MASTER" && printf '%s\n' "$ans" | script -qec "./ketsync $*" /dev/null ) \
    > "$SIMROOT/out" 2>&1
  RC=$?; OUT="$(cat "$SIMROOT/out")"; TRACE="$(cat "$SIMROOT/trace")"
}

_err(){ echo "      x $*"; SFAIL=1; }
has(){   grep -qF -- "$1" <<<"$OUT" || _err "expected in log: $1"; }
hasnt(){ grep -qF -- "$1" <<<"$OUT" && _err "should NOT be in log: $1"; return 0; }
rc_is(){ [[ "$RC" == "$1" ]] || _err "exit code $RC, expected $1"; }
ran(){   grep -qxF -- "$1" <<<"$TRACE" || _err "expected this exact call: $1
         got: ${TRACE:-<nothing ran>}"; }
never_ran(){ [[ -s "$SIMROOT/trace" ]] && _err "nothing should have run, but this did:
         $TRACE"; return 0; }

SFAIL=0; SNAME=""
scenario(){
  [[ -n "$ONLY" && "$ONLY" != "${1%%:*}" ]] && return 1
  echo "  [$1]"; SFAIL=0; SNAME="${1%%:*}"; new_world; return 0
}
done_scenario(){
  if (( SFAIL )); then FAIL=$((FAIL+1)); FAILED_NAMES+=("$SNAME")
  else echo "      ok"; PASS=$((PASS+1)); fi
  [[ -n "${KEEP:-}" ]] && echo "      sandbox: $SIMROOT" || rm -rf "$SIMROOT"
  return 0
}

echo "=== ketsync confirmation simulator ==="

if scenario "1: no terminal and no -y REFUSES, rather than answering no quietly"; then
  run_headless replica --all
  rc_is 2
  never_ran
  has "REFUSED: this command writes, and there is nobody here to ask"
  has "add -y"
  done_scenario
fi

if scenario "2: -y is how a cron line says it has already decided"; then
  run_headless replica --all -y
  rc_is 0
  ran "tp replica --all"
  hasnt "REFUSED"
  done_scenario
fi

if scenario "3: -y never reaches the engine, which has not heard of it"; then
  run_headless failback --all -y
  rc_is 0
  ran "tp failback --all"
  done_scenario
fi

if scenario "4: --dry-run is never asked about - the answer would get trained"; then
  run_headless replica --all --dry-run
  rc_is 0
  ran "tp replica --all --dry-run"
  hasnt "REFUSED"
  done_scenario
fi

if scenario "5: --list is a question, so it is not questioned"; then
  run_headless recall --list
  rc_is 0
  ran "tp recall --list"
  hasnt "REFUSED"
  done_scenario
fi

if scenario "6: a read-only verb is never asked about at all"; then
  run_headless status
  rc_is 0
  ran "tp status"
  hasnt "REFUSED"
  done_scenario
fi

if scenario "7: at a terminal, y runs it"; then
  run_tty y replica --all
  rc_is 0
  ran "tp replica --all"
  has "proceed? [y/N]"
  done_scenario
fi

if scenario "8: at a terminal, n does not"; then
  run_tty n replica --all
  rc_is 1
  never_ran
  has "nothing was done."
  done_scenario
fi

if scenario "9: at a terminal, Enter on its own means no"; then
  # The default has to be the safe one. Somebody who is reading fast presses
  # Enter, and this is a command that overwrites a customer's only copy.
  run_tty "" replica --all
  rc_is 1
  never_ran
  done_scenario
fi

if scenario "10: the prompt says what it writes, not whether you are sure"; then
  run_tty n failback --all
  has "this WRITES a copy back into the PRODUCTION image"
  has "the direction that loses data if it is wrong"
  has "--dry-run"
  hasnt "are you sure"
  done_scenario
fi

if scenario "11: distribute says out loud that it prepares nodes, not just copies"; then
  run_tty n distribute --all
  has "PREPARES every node in the inventory"
  has "disabling dead storages, unmounting them, stopping containers"
  never_ran
  done_scenario
fi

if scenario "12: sync writes to every other machine, so it is asked about too"; then
  run_headless sync
  rc_is 2
  has "OVERWRITES the fleet tables on every other node"
  done_scenario
fi

if scenario "13: a bare writing verb prints the menu and refuses"; then
  # Four characters cheaper than saying --all, and the four characters are the
  # record of what somebody meant. A bare verb says "I pressed Enter".
  run_headless distribute
  rc_is 2
  never_ran
  has "--ctid <id>            one container, by its PRODUCTION id"
  has "refused: no scope given"
  hasnt "REFUSED: this command writes"
  done_scenario
fi

if scenario "14: a bare read-only verb is exactly right, and just runs"; then
  run_headless status
  rc_is 0
  ran "tp status"
  hasnt "refused: no scope given"
  done_scenario
fi

if scenario "15: the menu refuses before the question is even asked"; then
  # Order matters: asking "proceed?" about a command with no scope would be
  # asking somebody to agree to something nobody has described yet.
  run_tty y replica
  rc_is 2
  never_ran
  hasnt "proceed?"
  done_scenario
fi

if scenario "16: cleanup says what it stops, because that is what it is for"; then
  # The last verb of a disaster, and the one whose name sounds harmless. What
  # it actually does is stop the container that has been serving customers in
  # production's place, so the question says that rather than "tidy up".
  run_tty n cleanup --all
  has "STOPS each 9<id> that stood in during the outage"
  has "--destroy it removes them for good"
  never_ran
  done_scenario
fi

if scenario "17: a bare cleanup prints its own menu and refuses"; then
  run_headless cleanup
  rc_is 2
  never_ran
  has "--destroy              also destroy the 9<id>"
  has "refused: no scope given"
  done_scenario
fi


if scenario "18: --help is a question, and questions are never asked about"; then
  # The 2026-08-18 drill: `recover --help` was asked "proceed?" and then
  # refused '--help' as unknown. A help request must reach its answer with
  # nothing run and nothing asked - headless, because that is also how a
  # person pipes it into less.
  run_headless replica --help
  rc_is 0
  hasnt "REFUSED"
  hasnt "proceed?"
  ran "tp replica --help"
  done_scenario
fi

if scenario "19: the layer's own verbs answer --help themselves, without running"; then
  run_headless recover --help
  rc_is 0
  hasnt "REFUSED"
  hasnt "unknown argument"
  has "recover: the whole way back"
  has "--ctid <id>"
  never_ran
  run_headless sync --help
  rc_is 0
  has "push the fleet-wide tables"
  never_ran
  done_scenario
fi

echo
echo "=== $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then echo "failed: ${FAILED_NAMES[*]}"; exit 1; fi
exit 0
