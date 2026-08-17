#!/usr/bin/env bash
# =============================================================================
#  run-sim-mail.sh — execute `ketsync mail-setup` against a fake satellite.
# -----------------------------------------------------------------------------
#  mail-setup is thin on purpose: it reads three conf keys and hands them to
#  contrib/mail-satellite.sh. Everything that can go wrong with it is a
#  boundary: a key missing from the conf and carried on past, an argument
#  invented, a --test that stops sending the addresses watch itself uses, an
#  exit code swallowed on its way back to the operator's terminal. Each of
#  those is a way the fleet ends up with a mail transport nobody configured -
#  so the satellite here is a fake that records its argv, and the argv IS the
#  output under test.
#
#  usage:  ./tests/sim/mail/run-sim-mail.sh          every scenario
#          ./tests/sim/mail/run-sim-mail.sh 3        scenario 3 only
#          KEEP=1 ./tests/sim/mail/run-sim-mail.sh 3 keep the sandbox
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
KS="${KS:-$ROOT/ketsync}"

if [[ ! -f "$KS" ]]; then
  echo "ketsync not found: $KS" >&2; exit 2
elif [[ ! -x "$KS" ]]; then
  echo "ketsync is not executable: $KS" >&2; exit 2
fi
ONLY="${1:-}"
PASS=0; FAIL=0; FAILED_NAMES=()

new_world(){
  SIMROOT="$(mktemp -d /tmp/ksmail-sim.XXXXXX)"
  MASTER="$SIMROOT/master"
  mkdir -p "$MASTER/lib" "$MASTER/conf" "$MASTER/contrib" "$MASTER/logs"
  local ksdir; ksdir="$(cd "$(dirname "$KS")" && pwd)"
  cp "$KS" "$MASTER/ketsync"; chmod +x "$MASTER/ketsync"
  cp "$ksdir"/lib/*.sh "$MASTER/lib/"
  cat > "$MASTER/conf/ketsync.conf" <<CONF
KS_ROLE=master
KS_MASTER_IP=10.100.1.17
KS_MAIL_FROM=ketsync@sim
KS_MAIL_INFRA=infra@sim
KS_MAIL_NODE=node@sim
KS_MAIL_DIGEST=digest@sim
KS_MAIL_RELAY=[smtp.sim]:587
KS_MAIL_USER=login@sim
KS_MAIL_KEYFILE=/sim/key
CONF
  # The satellite fake: its argv is the entire point of the verb, so the argv
  # is what gets written down. rc.sat makes it fail on request.
  cat > "$MASTER/contrib/mail-satellite.sh" <<'SAT'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$SIMROOT/satargs"
exit "$(cat "$SIMROOT/rc.sat" 2>/dev/null || echo 0)"
SAT
  chmod +x "$MASTER/contrib/mail-satellite.sh"
}

# ---------- world knobs ----------
no_key(){    sed -i "/^$1=/d" "$MASTER/conf/ketsync.conf"; }   # drop one conf key
sat_fails(){ printf '%s\n' "${1:-2}" > "$SIMROOT/rc.sat"; }
sat_gone(){  rm -f "$MASTER/contrib/mail-satellite.sh"; }

run_ks(){
  ( export SIMROOT
    cd "$MASTER" && ./ketsync "$@" -y ) > "$SIMROOT/out" 2>&1
  RC=$?
  OUT="$(cat "$SIMROOT/out")"
}
run_ks_piped(){   # no -y, stdin a pipe: the confirmation must refuse
  ( export SIMROOT
    cd "$MASTER" && ./ketsync "$@" < /dev/null ) > "$SIMROOT/out" 2>&1
  RC=$?
  OUT="$(cat "$SIMROOT/out")"
}

_err(){ echo "      x $*"; SFAIL=1; }
has(){   grep -qF -- "$1" <<<"$OUT" || _err "expected in log: $1"; }
hasnt(){ grep -qF -- "$1" <<<"$OUT" && _err "should NOT be in log: $1"; return 0; }
rc_is(){ [[ "$RC" == "$1" ]] || _err "exit code $RC, expected $1"; }
sat_ran(){    [[ -f "$SIMROOT/satargs" ]] || _err "the satellite should have run"; }
sat_not_run(){ [[ -f "$SIMROOT/satargs" ]] && _err "the satellite must NOT have run"; return 0; }
sat_has(){   grep -qF -- "$1" "$SIMROOT/satargs" 2>/dev/null || _err "expected in satellite argv: $1"; }
sat_hasnt(){ grep -qF -- "$1" "$SIMROOT/satargs" 2>/dev/null && _err "should NOT be in satellite argv: $1"; return 0; }

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

echo "=== ketsync mail-setup simulator ==="

if scenario "1: --test hands the satellite exactly what the conf says, from included"; then
  run_ks mail-setup --test
  rc_is 0
  sat_ran
  sat_has "--relay [smtp.sim]:587"
  sat_has "--user login@sim"
  sat_has "--keyfile /sim/key"
  sat_has "--test infra@sim"
  sat_has "--from ketsync@sim"
  done_scenario
fi

if scenario "2: without --test nothing about a test travels - no argument is invented"; then
  run_ks mail-setup
  rc_is 0
  sat_ran
  sat_has "--relay [smtp.sim]:587"
  sat_hasnt "--test"
  sat_hasnt "--from"
  done_scenario
fi

if scenario "3: a missing relay is a refusal, not an empty argument"; then
  no_key KS_MAIL_RELAY
  run_ks mail-setup
  rc_is 2
  has "refused: conf/ketsync.conf is missing: KS_MAIL_RELAY"
  sat_not_run
  done_scenario
fi

if scenario "4: every missing key is named in ONE refusal, not found one run at a time"; then
  no_key KS_MAIL_RELAY; no_key KS_MAIL_USER; no_key KS_MAIL_KEYFILE
  run_ks mail-setup
  rc_is 2
  has "KS_MAIL_RELAY KS_MAIL_USER KS_MAIL_KEYFILE"
  sat_not_run
  done_scenario
fi

if scenario "5: --test needs the watch addresses; plain setup does not"; then
  no_key KS_MAIL_FROM; no_key KS_MAIL_INFRA
  run_ks mail-setup --test
  rc_is 2
  has "KS_MAIL_FROM KS_MAIL_INFRA"
  sat_not_run
  run_ks mail-setup
  rc_is 0
  sat_ran
  done_scenario
fi

if scenario "6: an unknown argument is refused - the answers live in the conf"; then
  run_ks mail-setup --relay
  rc_is 2
  has "refused: unknown argument '--relay'"
  sat_not_run
  done_scenario
fi

if scenario "7: a missing satellite is a broken checkout, said before anything runs"; then
  sat_gone
  run_ks mail-setup
  rc_is 2
  has "NOTHING was run"
  sat_not_run
  done_scenario
fi

if scenario "8: the satellite's exit code IS the verb's exit code"; then
  sat_fails 2
  run_ks mail-setup
  rc_is 2
  sat_ran
  done_scenario
fi

if scenario "9: it writes postfix, so a pipe with no -y is refused like any writer"; then
  run_ks_piped mail-setup
  rc_is 2
  has "REFUSED: this command writes, and there is nobody here to ask."
  sat_not_run
  done_scenario
fi

echo
echo "=== $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then echo "failed: ${FAILED_NAMES[*]}"; exit 1; fi
exit 0
