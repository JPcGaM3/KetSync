#!/usr/bin/env bash
# =============================================================================
#  check-log-separator.sh — every tool that logs, separates its operations.
# -----------------------------------------------------------------------------
#  The rule of #### between operations is what makes a daily log readable at the
#  hour somebody is scrolling it for the container that did not come back. In
#  the engines and the dispatcher it is bound by scenarios and mutations. In the
#  c2v tools it is not, and it cannot cheaply be: tests/c2v checks what phase 2
#  WRITES TO DISK, not what it prints, so binding log text there would mean a
#  different harness with a different shape.
#
#  That left the c2v separators as exactly what the commit that added them
#  called decoration - a log line that can be deleted without a test noticing.
#  This is the cheap half of the answer: not "the rule printed the right thing"
#  but "the rule is still there and still called", checked statically, for every
#  tool at once including ones added after this file was written.
#
#  The contract, in one sentence: a shipped tool that defines log() must also
#  define hr() and call it at least once.
#
#  usage:  ./tools/check-log-separator.sh
#          make lint
# =============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

# bkp02-setup.sh is the one deliberate exemption: it has no log(), seven echo
# lines in total, and is a one-time hand-run pool setup. There is no daily log
# to scroll and nothing to separate. It is listed here rather than silently
# skipped so that the exemption is a decision somebody made, not an oversight.
EXEMPT="bkp02-setup.sh"

rc=0
for f in ct-migrate.sh ct-replica.sh ct-failback.sh tp \
         tools/c2v-prepare.sh tools/c2v-inside.sh tools/c2v-inside-deb.sh \
         bkp02-setup.sh; do
  [[ -f "$f" ]] || { echo "  missing: $f"; rc=1; continue; }
  case " $EXEMPT " in *" $f "*) continue;; esac

  # tp prints with echo rather than log(), so the trigger is "does it talk to an
  # operator at all", not "does it define log()". Both forms are covered.
  if ! grep -qE '^(log\(\)|cmd_status\(\))' "$f"; then continue; fi

  if ! grep -qE '^hr\(\)' "$f"; then
    echo "$f defines log() but no hr() - operations would run together in the log"
    echo "    add:  LOGSEP='###...'  and  hr(){ printf '%s\\n' \"\$LOGSEP\"; }"
    rc=1; continue
  fi
  if ! grep -qE '(^|[;[:space:]])hr($|[;[:space:]])' "$f"; then
    echo "$f defines hr() but never calls it - the rule exists and prints nothing"
    rc=1; continue
  fi
  if ! grep -qE "^LOGSEP='#+'" "$f"; then
    echo "$f has an hr() whose LOGSEP is not a row of # - the separator has to be"
    echo "    greppable and the same in every tool"
    rc=1; continue
  fi
done

[[ $rc -eq 0 ]] && echo "log separator: clean"
exit $rc
