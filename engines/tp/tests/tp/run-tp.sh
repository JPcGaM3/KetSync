#!/usr/bin/env bash
# =============================================================================
#  run-tp.sh — exercise the dispatcher: tp status, tp doctor, and the promise
#  that everything after a subcommand reaches the engine untouched.
# -----------------------------------------------------------------------------
#  Why this exists: `tp doctor` is described as "the cross-checks nobody
#  remembers to run", and until this file nothing checked that it ran at all.
#  Its four findings are the ones with no other owner - a container that went
#  live and was never added to the replica inventory has no DR copy and nothing
#  else in this repo will ever say so - and each of them is a few lines of sed
#  and awk over files written by three different tools. That is exactly the
#  shape of code that rots quietly.
#
#  `tp status` is the same argument one step milder: it parses state/*.json
#  with sed rather than a JSON parser (rule 6 - no jq on a Proxmox node), so a
#  field that moves in the schema breaks a table nobody is testing.
#
#  No fakes are needed here. The dispatcher reads files and runs one exec; the
#  sandbox is a real TP_HOME with real files in it, which is what TP_HOME is
#  for. The engines are reached only through `-h`, which prints their header
#  and exits before touching a lock, a config or a node.
#
#  usage:  ./tests/tp/run-tp.sh          every scenario
#          ./tests/tp/run-tp.sh 4        scenario 4 only
#          KEEP=1 ./tests/tp/run-tp.sh 4 keep the sandbox and say where it is
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
TP="${TP:-$ROOT/tp}"

if [[ ! -x "$TP" ]]; then
  echo "tp is missing or not executable: $TP" >&2; exit 2
fi
ONLY="${1:-}"
PASS=0; FAIL=0; FAILED_NAMES=()

# ---------- sandbox ----------
# TP_HOME is the one seam the dispatcher already has: it resolves everything
# from there, so a sandbox needs no fake anything - only the real files, and
# symlinks to the three engines, which is what a deployed folder looks like.
new_world(){
  HOME_DIR="$(mktemp -d /tmp/tp-sim.XXXXXX)"
  mkdir -p "$HOME_DIR/state" "$HOME_DIR/done" "$HOME_DIR/logs"
  # the dispatcher resolves each engine relative to TP_HOME and refuses when it
  # is not there, so a sandbox that wants to dispatch has to carry them
  ln -s "$ROOT/ct-migrate.sh" "$ROOT/ct-replica.sh" "$ROOT/ct-failback.sh" "$HOME_DIR/"
  cp "$ROOT/ctmig.conf" "$ROOT/ctrep.conf" "$HOME_DIR/" 2>/dev/null || true
  : > "$HOME_DIR/inventory.tsv"
  : > "$HOME_DIR/inventory-replica.tsv"
}

run_tp(){
  OUT="$(TP_HOME="$HOME_DIR" "$TP" "$@" 2>&1)"; RC=$?
}

# A state snapshot of the shape the ENGINES write, not the shape the schema
# describes: it carries a "tool" key, and schema/state.schema.json is
# additionalProperties:false with no such field. That is the known
# migrate/replica namespace collision CLAUDE.md defers to lib/, and it is
# what scenario 7 is about. Only the fields tp reads are varied here.
state(){ # $1=ctid $2=tool $3=status $4=reason $5=rc $6=literal_bytes [7=size_drift 8=config_size 9=image_gib]
  cat > "$HOME_DIR/state/$2-$1.json" <<EOF
{
  "schema_version": 1,
  "new_ctid": "$1",
  "old_ctid": "$1",
  "old_node": "10.100.1.11",
  "new_node": "10.100.1.31",
  "storage": "tank-hdd-nas",
  "image": "/tank/hosting/images/$1/vm-$1-disk-0.raw",
  "image_size_gib": ${9:-20},
  "config_present": true,
  "config_size": "${8:-20G}",
  "size_drift": ${7:-false},
  "mp_empty": [],
  "tool": "$2",
  "last": {"ts":"2026-08-11T02:00:00+0700","epoch":1786431600,"lane":"all","mode":"presync","status":"$3","reason":"$4","message":"","rc":$5,"secs":12,"files":161,"literal_bytes":$6,"bytes_sent":$6,"total_bytes":118111600640,"grow_attempts":0}
}
EOF
}

# ---------- assertions, same idiom as the three simulators ----------
_err(){ echo "      x $*"; SCEN_OK=0; }
has(){    grep -qF -- "$1" <<<"$OUT" || _err "expected in output: $1"; }
hasnt(){  grep -qF -- "$1" <<<"$OUT" && _err "should NOT be in output: $1"; return 0; }
rc_is(){  [[ "$RC" == "$1" ]] || _err "exit code $RC, expected $1"; }

scenario(){
  N="${1%%:*}"
  [[ -n "$ONLY" && "$ONLY" != "$N" ]] && return 1
  echo "  [$1]"; SCEN_OK=1; new_world; return 0
}
done_scenario(){
  if (( SCEN_OK )); then PASS=$((PASS+1)); echo "      ok"
  else FAIL=$((FAIL+1)); FAILED_NAMES+=("$N"); fi
  if [[ -n "${KEEP:-}" ]]; then echo "      sandbox: $HOME_DIR"; else rm -rf "$HOME_DIR"; fi
}

echo "=== tp dispatcher ==="

# ---------- dispatch ----------

if scenario "1: no subcommand prints the usage rather than doing something"; then
  run_tp
  rc_is 0
  has "tp migrate"
  has "tp replica"
  has "tp failback"
  has "tp doctor"
  done_scenario
fi

if scenario "2: an unknown subcommand is refused, not guessed at"; then
  # `tp mgirate` must not fall through to anything. Exit 2 is the same code the
  # engines use for "refused before touching anything".
  run_tp mgirate --all
  rc_is 2
  has "unknown subcommand 'mgirate'"
  done_scenario
fi

if scenario "3: everything after the subcommand reaches the engine untouched"; then
  # The dispatcher's one real promise. -h is the only engine path that prints
  # and exits without a lock, a config or a node, so it is what proves the
  # arguments arrived.
  run_tp migrate -h
  rc_is 0
  has "ct-migrate.sh   --dry-run"
  hasnt "unknown argument"
  run_tp replica -h
  rc_is 0
  has "ct-replica.sh --dry-run"
  run_tp failback -h
  rc_is 0
  has "ct-failback.sh --all --dry-run"
  done_scenario
fi

if scenario "4: a flag the engine rejects still comes back as the engine's error"; then
  # dispatch must not swallow or rewrite the engine's own refusal
  run_tp migrate --nonsense
  rc_is 2
  has "unknown argument: --nonsense"
  done_scenario
fi

if scenario "8: an engine missing from TP_HOME is a refusal, not a stack trace"; then
  # tp is deployed by copying a folder. A half-copied one must say which file
  # is missing rather than dying on exec.
  rm -f "$HOME_DIR/ct-replica.sh"
  run_tp replica --storage tank-hdd-nas
  rc_is 2
  has "ct-replica.sh is missing or not executable"
  done_scenario
fi

# ---------- tp status ----------

if scenario "5: status on a fresh install says so instead of printing nothing"; then
  run_tp status
  rc_is 0
  has "no state files yet"
  done_scenario
fi

if scenario "6: status reports both engines in one table"; then
  state 251 migrate  ok     ""          0  2469606195
  state 105 replica  failed r3_not_mounted 1 0
  run_tp status
  rc_is 0
  has "CT       TOOL       STATUS"
  has "##############################################################################"
  has "251"; has "migrate"; has "ok"
  has "105"; has "replica"; has "failed"; has "r3_not_mounted"
  # both tools hold history for their own container at the same time, which is
  # the whole reason the files carry the tool in their name
  # literal_bytes is reported in MiB - the number that should fall round over
  # round, which is the whole point of the column
  has "2355MiB (rc=0)"
  done_scenario
fi

if scenario "7: a state file from before the split is still shown, and labelled"; then
  # A fleet that has been running for months has state/<ctid>.json with no tool
  # in the name. Those files must not vanish from the table on upgrade - the
  # history is the reason the file exists - but the tool that wrote them is
  # genuinely unknowable, so it is said rather than guessed.
  state 251 migrate ok "" 0 0
  mv "$HOME_DIR/state/migrate-251.json" "$HOME_DIR/state/251.json"
  run_tp status
  rc_is 0
  has "251"
  has "pre-split"
  done_scenario
fi

# ---------- tp doctor ----------

if scenario "10: doctor is quiet and exits 0 when there is nothing to say"; then
  run_tp doctor
  rc_is 0
  has "live in the hybrid but not replicated"
  # five unrelated checks in a row, each able to raise the exit code on its
  # own, so the reader has to see which finding came from which check
  has "##############################################################################"
  has "bandwidth ceilings that do not know about each other"
  has "stale PAUSE"
  has "inventories readable"
  done_scenario
fi

if scenario "11: doctor names a CT that went live with no DR copy"; then
  # The dangerous gap this command exists for: migrate finished, a human marked
  # the CT done, it is serving customers - and nobody added it to the replica
  # inventory, so it has no copy and nothing else would ever say so.
  : > "$HOME_DIR/done/251.done"
  printf '105\thdd\n' > "$HOME_DIR/inventory-replica.tsv"
  run_tp doctor
  rc_is 1
  has "CT 251 went live (done/251.done) but is not in inventory-replica.tsv - it has NO DR copy"
  done_scenario
fi

if scenario "12: a CT that went live AND is replicated is not reported"; then
  : > "$HOME_DIR/done/251.done"
  printf '251\thdd\n' > "$HOME_DIR/inventory-replica.tsv"
  run_tp doctor
  rc_is 0
  hasnt "NO DR copy"
  done_scenario
fi

if scenario "13: doctor adds the two bandwidth ceilings together"; then
  printf 'BW_TOTAL_MB=230\n' > "$HOME_DIR/ctmig.conf"
  printf 'BW_TOTAL_MB=230\n' > "$HOME_DIR/ctrep.conf"
  run_tp doctor
  has "ctmig.conf=230m  ctrep.conf=230m  -> up to 460m if both run at once"
  done_scenario
fi

if scenario "14: doctor names an image that outgrew what its config says"; then
  # G4 grows an image on ENOSPC and G6 never rewrites a config that exists, so
  # the config's size= is stale for good. Nothing is corrupt - but `pct resize`
  # later computes from that stale number, and only this command ever says so.
  state 251 migrate ok "" 0 0 true 20G 22
  run_tp doctor
  rc_is 1
  has "CT 251: config says size=20G, image is 22G"
  has "fix the rootfs line by hand"
  done_scenario
fi

if scenario "15: doctor reports a PAUSE nobody removed after a failback"; then
  # A PAUSE left behind stops every copy in the fleet, and the only symptom is
  # a log line saying PAUSED where nobody is looking.
  : > "$HOME_DIR/PAUSE"
  run_tp doctor
  rc_is 1
  has "replication is STOPPED for every CT"
  done_scenario
fi

if scenario "16: doctor counts the rows in each inventory, and says which is missing"; then
  printf '# comment\n\n10.100.1.11\t251\t251\t10.100.1.31\ttank-hdd-nas\n' > "$HOME_DIR/inventory.tsv"
  rm -f "$HOME_DIR/inventory-replica.tsv"
  run_tp doctor
  has "inventory.tsv: 1 rows"
  has "inventory-replica.tsv: not present"
  done_scenario
fi

if scenario "17: one finding is enough to make doctor exit non-zero"; then
  # doctor is meant for cron as much as for a human. A finding that did not
  # change the exit code would be invisible there, which is the failure mode
  # this whole repo is built against.
  : > "$HOME_DIR/PAUSE"
  : > "$HOME_DIR/done/251.done"
  printf '105\thdd\n' > "$HOME_DIR/inventory-replica.tsv"
  run_tp doctor
  rc_is 1
  has "NO DR copy"
  has "replication is STOPPED"
  done_scenario
fi

echo
echo "=== $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then echo "failed: ${FAILED_NAMES[*]}"; exit 1; fi
exit 0
