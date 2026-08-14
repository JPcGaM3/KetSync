#!/usr/bin/env bash
# =============================================================================
#  run-sim-distribute.sh — execute `ketsync distribute` against fake engines.
# -----------------------------------------------------------------------------
#  This is the only ketsync command that is not a pass-through: it runs
#  ct-prepare.sh and then ct-distribute.sh, and the whole of what it can get
#  wrong is in the joins between them. Neither engine's own simulator can see
#  any of it, because from inside an engine the question "was I given
#  --dry-run" has already been answered by whoever called.
#
#  The failures this exists to catch are all silent:
#
#    - --dry-run reaching the engine but not the preparer, so a rehearsal
#      disables a storage and stops containers on a live fleet. This is the
#      worst bug this repo could ship and it would produce a completely
#      ordinary-looking log
#    - --ctid evacuating the whole NODE, which stops containers nobody asked
#      about
#    - --list preparing anything at all, when it is a read-only question
#    - the engine running after a preparer that refused before touching
#      anything, so the run allocates on a fleet whose config is wrong
#    - the engine's exit code being swallowed, which is what cron reads
#
#  So both engines are replaced by stubs that record their argv and exit with
#  a code the scenario chose. What is under test is the composition, and the
#  argv is the whole of it.
#
#  usage:  ./tests/sim/distribute/run-sim-distribute.sh          every scenario
#          ./tests/sim/distribute/run-sim-distribute.sh 7        scenario 7 only
#          KEEP=1 ./tests/sim/distribute/run-sim-distribute.sh 7 keep the sandbox
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
KS="${KS:-$ROOT/ketsync}"

if [[ ! -f "$KS" ]]; then
  echo "ketsync not found: $KS" >&2; exit 2
elif [[ ! -x "$KS" ]]; then
  echo "ketsync is not executable: $KS" >&2
  echo "  every scenario would die with exit 126. fix it with:  chmod +x $KS" >&2
  exit 2
fi
ONLY="${1:-}"
PASS=0; FAIL=0; FAILED_NAMES=()
ME=10.100.1.17

new_world(){
  SIMROOT="$(mktemp -d /tmp/ksdist-sim.XXXXXX)"
  MASTER="$SIMROOT/master"
  mkdir -p "$MASTER/lib" "$MASTER/engines/tp" "$MASTER/logs"
  : > "$SIMROOT/trace"
  # lib/ comes from beside the DISPATCHER, not from the repo: cmd_distribute.sh
  # is sourced, and taking it from $ROOT would load the good copy while the
  # mutation suite was pointing at a broken one.
  local ksdir; ksdir="$(cd "$(dirname "$KS")" && pwd)"
  cp "$KS" "$MASTER/ketsync"; chmod +x "$MASTER/ketsync"
  cp "$ksdir"/lib/*.sh "$MASTER/lib/"
  cat > "$MASTER/ketsync.conf" <<CONF
KS_ROLE=master
KS_MASTER_IP=$ME
CONF
  printf '# generation: 1\n%s\tstorage\n' "$ME" > "$MASTER/nodes.tsv"
  stub ct-prepare.sh 0
  stub tp 0
}

# Each stub writes one line per invocation: its own name, then its arguments,
# exactly as it received them. The order of the lines is the order of the run,
# which is half of what these scenarios assert.
stub(){   # $1 = filename, $2 = exit code
  local f="$MASTER/engines/tp/$1"
  cat > "$f" <<STUB
#!/usr/bin/env bash
printf '%s %s\n' "$1" "\$*" >> "$SIMROOT/trace"
exit $2
STUB
  chmod +x "$f"
}
no_stub(){ rm -f "$MASTER/engines/tp/$1"; }
unexec(){  chmod -x "$MASTER/engines/tp/$1"; }

run_ks(){
  ( cd "$MASTER" && ./ketsync "$@" ) > "$SIMROOT/out" 2>&1
  RC=$?
  OUT="$(cat "$SIMROOT/out")"
  TRACE="$(cat "$SIMROOT/trace")"
}

_err(){ echo "      x $*"; SFAIL=1; }
has(){   grep -qF -- "$1" <<<"$OUT" || _err "expected in log: $1"; }
hasnt(){ grep -qF -- "$1" <<<"$OUT" && _err "should NOT be in log: $1"; return 0; }
rc_is(){ [[ "$RC" == "$1" ]] || _err "exit code $RC, expected $1"; }
ran(){   grep -qxF -- "$1" <<<"$TRACE" || _err "expected this exact call: $1
         got:
$(sed 's/^/           /' <<<"$TRACE")"; }
never_ran(){ grep -q "^$1 " <<<"$TRACE" && _err "$1 must NOT have run at all"; return 0; }
# Order matters more than presence: preparing after the copies have been placed
# is the same as not preparing.
before(){ local a b
  a=$(grep -n "^$1" <<<"$TRACE" | head -1 | cut -d: -f1)
  b=$(grep -n "^$2" <<<"$TRACE" | head -1 | cut -d: -f1)
  [[ -n "$a" && -n "$b" && "$a" -lt "$b" ]] || _err "$1 should have run before $2"; }

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

echo "=== ketsync distribute simulator ==="

if scenario "1: it evacuates every node first, then places the copies"; then
  run_ks distribute --all
  rc_is 0
  ran "ct-prepare.sh --evacuate --all"
  ran "tp distribute --all"
  before ct-prepare.sh tp
  done_scenario
fi

if scenario "2: --ctid isolates that container and does NOT evacuate its node"; then
  # Evacuating would disable a storage and stop the neighbours. Nobody asked
  # about the neighbours.
  run_ks distribute --ctid 300
  rc_is 0
  ran "ct-prepare.sh --isolate --ctid 300"
  ran "tp distribute --ctid 300"
  has "isolating it, NOT evacuating its node"
  done_scenario
fi

if scenario "3: --dry-run reaches BOTH, which is the whole point of a rehearsal"; then
  run_ks distribute --all --dry-run
  rc_is 0
  ran "ct-prepare.sh --evacuate --all --dry-run"
  ran "tp distribute --all --dry-run"
  done_scenario
fi

if scenario "4: --dry-run with --ctid reaches the isolate side too"; then
  run_ks distribute --ctid 300 --dry-run
  rc_is 0
  ran "ct-prepare.sh --isolate --ctid 300 --dry-run"
  done_scenario
fi

if scenario "5: --list prepares nothing - it is a read-only question"; then
  run_ks distribute --list
  rc_is 0
  never_ran ct-prepare.sh
  ran "tp distribute --list"
  done_scenario
fi

if scenario "6: --no-prepare runs the engine alone, and is not passed to it"; then
  run_ks distribute --all --no-prepare
  rc_is 0
  never_ran ct-prepare.sh
  ran "tp distribute --all"
  done_scenario
fi

if scenario "7: a preparer that refused before touching anything stops the run"; then
  # Exit 2 is a config that is wrong, and it will be just as wrong one step
  # later - with a volume allocated by then.
  stub ct-prepare.sh 2
  run_ks distribute --all
  rc_is 2
  never_ran tp
  has "prepare refused before touching anything"
  done_scenario
fi

if scenario "8: a preparer that skipped some containers does NOT stop the run"; then
  # On a healthy fleet every container is skipped and exit 1 is correct. D1
  # decides what happens to each container; two places deciding that would be
  # one too many.
  stub ct-prepare.sh 1
  run_ks distribute --all
  rc_is 0
  ran "tp distribute --all"
  has "carrying on; D1 decides per container"
  done_scenario
fi

if scenario "9: the engine's exit code is the command's exit code"; then
  stub tp 1
  run_ks distribute --all
  rc_is 1
  done_scenario
fi

if scenario "10: a missing preparer stops the run rather than skipping the half"; then
  no_stub ct-prepare.sh
  run_ks distribute --all
  rc_is 2
  never_ran tp
  has "is missing or not executable"
  done_scenario
fi

if scenario "11: a preparer that is present but not executable is the same answer"; then
  unexec ct-prepare.sh
  run_ks distribute --all
  rc_is 2
  never_ran tp
  done_scenario
fi

if scenario "12: everything else is passed to the engine untouched"; then
  run_ks distribute --ctid 300 --to 10.100.1.33 --dst local-zfs
  rc_is 0
  ran "tp distribute --ctid 300 --to 10.100.1.33 --dst local-zfs"
  ran "ct-prepare.sh --isolate --ctid 300"
  done_scenario
fi

if scenario "13: bare distribute prepares nothing it would not have prepared"; then
  # No scope named. The engine refuses with its usage, and the point here is
  # that the preparer is still asked first with the fleet-wide scope - so the
  # two halves cannot disagree about what "no arguments" meant.
  run_ks distribute
  rc_is 0
  ran "ct-prepare.sh --evacuate --all"
  ran "tp distribute"
  done_scenario
fi

echo
echo "=== $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then echo "failed: ${FAILED_NAMES[*]}"; exit 1; fi
exit 0
