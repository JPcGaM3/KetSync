#!/usr/bin/env bash
# =============================================================================
#  run-sim-completion.sh — the TAB key, held to the same standard as the tools.
# -----------------------------------------------------------------------------
#  Completion looks harmless, and that is exactly the problem: it is the one
#  piece of this system that TYPES INTO THE OPERATOR'S COMMAND LINE, at 3am,
#  on the machine where the next keystroke is a write. A completion that
#  offers a verb the dispatcher does not have, or fills --ctid from the wrong
#  inventory column, is not a convenience bug - it is a wrong command, typed
#  faster.
#
#  Two kinds of scenario:
#
#    - the DRIFT check: the verb list in the completion file is diffed against
#      the dispatch table in bin/ketsync itself. Adding a subcommand without
#      teaching TAB about it is a red gate here, not a quiet gap
#    - behaviour: verbs, per-verb flags, and the file-backed values (--ctid,
#      --dest, --storage, --to) against a sandbox repo this suite builds
#
#  The completion function is sourced and driven the way bash drives it:
#  COMP_WORDS/COMP_CWORD in, COMPREPLY out. No pty games - programmable
#  completion is a plain function call, which is what makes it testable.
#
#  usage:  ./tests/sim/completion/run-sim-completion.sh        every scenario
#          ./tests/sim/completion/run-sim-completion.sh 7      scenario 7 only
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
COMPLETION="${COMPLETION:-$ROOT/tools/ketsync-completion.bash}"
DISPATCHER="$ROOT/bin/ketsync"

PASS=0; FAIL=0; FAILED_NAMES=(); SFAIL=0; CUR=""
ONLY="${1:-}"

scenario(){
  CUR="${1%%:*}"
  [[ -n "$ONLY" && "$CUR" != "$ONLY" ]] && return 1
  echo "  [$1]"
  SFAIL=0
  # a fresh sandbox repo per scenario, so no scenario leans on another's files
  WORK="$(mktemp -d /tmp/ketsync-comp.XXXXXX)"
  mkdir -p "$WORK/bin" "$WORK/conf" "$WORK/inventory" "$WORK/logs"
  : > "$WORK/bin/ketsync"                      # root detection wants conf/ beside bin/
  ln -s bin/ketsync "$WORK/ketsync"            # the shape the repo actually ships
  printf '105\treplica-hdd\n113\treplica-ssd\n# a comment row\n' > "$WORK/inventory/inventory-replica.tsv"
  printf '10.100.1.11\t230\t5230\t10.100.1.31\ttank-hdd-nas\n10.100.1.11\t253\t5253\t10.100.1.32\ttank-ssd-nas\n' \
    > "$WORK/inventory/inventory-migrate.tsv"
  printf '300\tr32\tr33\tlocal-ssd\n# comment\n310\tr33\tr32\tlocal-ssd\n' > "$WORK/conf/fleet.tsv"
  printf '# ip\trole\n10.100.1.17\tmaster\n10.100.1.9\tbackup\n' > "$WORK/conf/nodes.tsv"
  printf 'BKP_DESTS="replica-hdd:replica-hdd/ct replica-ssd:replica-ssd/ct"\n' > "$WORK/conf/ctrep.conf"
  touch "$WORK/logs/replica-tank-hdd-nas-2026-08-22.log" \
        "$WORK/logs/replica-tank-hdd-nas-2026-08-23.log" \
        "$WORK/logs/replica-all-2026-08-23.log"
  return 0
}
done_scenario(){
  rm -rf "$WORK"
  if (( SFAIL )); then FAIL=$((FAIL+1)); FAILED_NAMES+=("$CUR"); else PASS=$((PASS+1)); echo "      ok"; fi
}
_err(){ echo "      x $*"; SFAIL=1; }

# Drive the completion exactly the way bash does. Runs in a SUBSHELL so one
# scenario's COMP_* cannot leak into the next; the replies come back on stdout,
# one per line, sorted for stable comparison.
comp(){ # comp <word0> <word...>, cursor on the LAST word
  (
    # shellcheck disable=SC1090
    . "$COMPLETION"
    COMP_WORDS=("$@"); COMP_CWORD=$(( $# - 1 ))
    COMPREPLY=()
    _ketsync
    printf '%s\n' ${COMPREPLY[@]+"${COMPREPLY[@]}"} | sort
  )
}
# The got-value comes in as an ARGUMENT, never on a pipe: the assert has to
# run in this shell, because an _err raised in a pipeline element raises it in
# a subshell and the scenario stays green having printed its own failure.
replies_are(){ # $1 = got  $2 = expected, newline-separated and sorted
  [[ "$1" == "$2" ]] || _err "expected [$(tr '\n' ' ' <<<"$2")] got [$(tr '\n' ' ' <<<"$1")]"
}
replies_have(){ grep -qxF -- "$2" <<<"$1" || _err "missing '$2' in [$(tr '\n' ' ' <<<"$1")]"; }
replies_lack(){ grep -qxF -- "$2" <<<"$1" && _err "'$2' must NOT be offered: [$(tr '\n' ' ' <<<"$1")]"; return 0; }

echo "=== ketsync completion simulator ==="

# The list bash offers must be the list the dispatcher answers. Both sides are
# read from the SHIPPED files, so this fails the day either one changes alone.
if scenario "1: the verb list is the dispatcher's, verbatim - drift is a red gate"; then
  comp_verbs="$(sed -n 's/^  local verbs="\(.*\)"$/\1/p' "$COMPLETION" | tr ' ' '\n' | sort -u)"
  disp_verbs="$(
    awk '/# --- tp.s, passed through untouched ---/,/^esac/' "$DISPATCHER" \
      | sed -n 's/^  \([a-z"|-]*\)).*/\1/p' | tr '|' '\n' \
      | sed 's/"//g' | grep -v '^$' | grep -v '^-' | sort -u
  )"
  [[ -n "$comp_verbs" ]] || _err "could not read the verb list out of the completion file"
  [[ -n "$disp_verbs" ]] || _err "could not read the dispatch table out of bin/ketsync"
  if [[ "$comp_verbs" != "$disp_verbs" ]]; then
    _err "verb lists differ:"
    diff <(echo "$disp_verbs") <(echo "$comp_verbs") | sed 's/^/         /'
    echo "         < only in bin/ketsync   > only in the completion"
  fi
  done_scenario
fi

if scenario "2: ketsync repl<TAB> is replica, and nothing else"; then
  replies_are "$(comp "$WORK/ketsync" repl)" "replica"
  done_scenario
fi

if scenario "3: the verb position offers every verb, plus -y"; then
  out="$(comp "$WORK/ketsync" "")"
  grep -qxF replica  <<<"$out" || _err "replica missing"
  grep -qxF recall   <<<"$out" || _err "recall missing"
  grep -qxF doctor   <<<"$out" || _err "doctor missing"
  grep -qxF -- -y    <<<"$out" || _err "-y missing"
  done_scenario
fi

if scenario "4: replica's flags are replica's - --move-dest offered, --final not"; then
  replies_have "$(comp "$WORK/ketsync" replica --)" "--move-dest"
  replies_have "$(comp "$WORK/ketsync" replica --)" "--storage"
  replies_lack "$(comp "$WORK/ketsync" replica --)" "--final"
  done_scenario
fi

if scenario "5: migrate says --final now - and TAB must not resurrect --stopped"; then
  replies_have "$(comp "$WORK/ketsync" migrate --)" "--final"
  replies_lack "$(comp "$WORK/ketsync" migrate --)" "--stopped"
  done_scenario
fi

if scenario "6: --ctid completes from the file the verb will actually read"; then
  replies_are "$(comp "$WORK/ketsync" replica --ctid "")" "$(printf '105\n113')"
  # migrate is driven by the NEW id, column 3 - offering column 2 would type
  # the exact wrong number the engine just learned to explain
  replies_are "$(comp "$WORK/ketsync" migrate --ctid "")" "$(printf '5230\n5253')"
  replies_are "$(comp "$WORK/ketsync" recall  --ctid "")" "$(printf '300\n310')"
  done_scenario
fi

if scenario "7: --dest offers the BKP_DESTS keys, not the dataset halves"; then
  replies_are "$(comp "$WORK/ketsync" failback --dest "")" "$(printf 'replica-hdd\nreplica-ssd')"
  done_scenario
fi

if scenario "8: --storage: migrate reads its inventory, replica reads its own lanes"; then
  replies_are "$(comp "$WORK/ketsync" migrate --storage "")" "$(printf 'tank-hdd-nas\ntank-ssd-nas')"
  # the lane name contains dashes and the date does not split it; lane 'all'
  # is a run shape, not a storage, and must not be offered
  replies_are "$(comp "$WORK/ketsync" replica --storage "")" "tank-hdd-nas"
  done_scenario
fi

if scenario "9: --to and --node complete from nodes.tsv, comments skipped"; then
  replies_are "$(comp "$WORK/ketsync" sync --to "")" "$(printf '10.100.1.17\n10.100.1.9' | sort)"
  replies_are "$(comp "$WORK/ketsync" prepare --node "")" "$(printf '10.100.1.17\n10.100.1.9' | sort)"
  done_scenario
fi

if scenario "10: missing files mean no suggestions - never an error on the prompt"; then
  rm -f "$WORK/inventory/inventory-replica.tsv" "$WORK/conf/ctrep.conf"
  err="$(comp "$WORK/ketsync" replica --ctid "" 2>&1 >/dev/null)"
  [[ -z "$err" ]] || _err "completion wrote to stderr: $err"
  replies_are "$(comp "$WORK/ketsync" replica --ctid "")" ""
  replies_are "$(comp "$WORK/ketsync" failback --dest "")" ""
  done_scenario
fi

if scenario "11: the repo root is found through the symlink, wherever the symlink lives"; then
  # the SYMLINK form the repo ships (ketsync -> bin/ketsync, relative)
  replies_have "$(comp "$WORK/ketsync" failback --dest "")" "replica-hdd"
  # the bin/ketsync form directly
  replies_have "$(comp "$WORK/bin/ketsync" failback --dest "")" "replica-hdd"
  # and an operator's own symlink OUTSIDE the repo (absolute target) - the
  # form a `ln -s /root/ketsync/bin/ketsync /usr/local/bin/ketsync` makes.
  # TRULY outside, in its own temp dir: a subdirectory of the sandbox would
  # find conf/ by walking up and the hop would never be needed at all.
  _out="$(mktemp -d /tmp/ketsync-comp-out.XXXXXX)"
  ln -s "$WORK/bin/ketsync" "$_out/ketsync"
  replies_have "$(comp "$_out/ketsync" failback --dest "")" "replica-hdd"
  rm -rf "$_out"
  done_scenario
fi

if scenario "12: ketsync tp replica completes exactly like ketsync replica"; then
  replies_have "$(comp "$WORK/ketsync" tp replica --)" "--move-dest"
  replies_are "$(comp "$WORK/ketsync" tp repl)" "replica"
  done_scenario
fi

echo
echo "=== $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then echo "failed: ${FAILED_NAMES[*]}"; exit 1; fi
exit 0
