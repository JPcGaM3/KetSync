#!/usr/bin/env bash
# =============================================================================
#  run-remote-bash.sh - every remote command runs under bash, on any node.
# -----------------------------------------------------------------------------
#  ssh hands its command string to root's LOGIN shell. pve-r33 logs root into
#  zsh (2026-09), and zsh reads a bash snippet differently in exactly the way
#  that turns a failing check into a pass: an unmatched glob aborts the whole
#  command, and an unquoted $var is not split. Every file that talks to another
#  machine therefore sends its commands through bssh, which wraps each one as
#      exec bash -c '<the command>'
#  This suite holds that in place from four sides:
#
#    1. drift     - bssh is the same function in every file that has one
#    2. coverage  - no shipped file sends a command with plain ssh and the
#                   usual option variables (the sims refuse it at runtime too,
#                   but contrib/ has no sims)
#    3. meaning   - the wrapped command, run through a real sh and a real zsh
#                   as the login shell, prints exactly what bash -c prints;
#                   and the SAME matrix sent unwrapped through zsh does not,
#                   which is the proof this matrix can see the bug at all
#    4. the fakes - tests/sim/remote-bash.sh unwraps every wrapped command back
#                   to the original text, and refuses malformed ones
#
#  usage:  tests/remote-bash/run-remote-bash.sh      (make test-remote-bash)
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
PASS=0; FAIL=0; FAILED_NAMES=()
T="$(mktemp -d /tmp/remote-bash.XXXXXX)"; trap 'rm -rf "$T"' EXIT

SFAIL=0; SNAME=""
scenario(){ echo "  [$1]"; SFAIL=0; SNAME="${1%%:*}"; }
_err(){ echo "      x $*"; SFAIL=1; }
done_scenario(){
  if (( SFAIL )); then FAIL=$((FAIL+1)); FAILED_NAMES+=("$SNAME")
  else echo "      ok"; PASS=$((PASS+1)); fi
}

# Every shipped file that talks to another machine. A new one belongs here.
FILES=("$ROOT"/engines/ct-*.sh "$ROOT"/lib/common.sh
       "$ROOT"/contrib/ct-move.sh "$ROOT"/contrib/ssh-mesh.sh "$ROOT"/contrib/c2v-prepare.sh)

# the text of bssh(){ ... } in one file, or nothing
body_of(){ sed -n '/^bssh(){$/,/^}$/p' "$1"; }

echo "=== remote commands run under bash ==="

scenario "1: bssh is one function - identical in every file that talks to another machine"
ref="$(body_of "${FILES[0]}")"
[[ -n "$ref" ]] || _err "no bssh in ${FILES[0]#"$ROOT"/}"
for f in "${FILES[@]}"; do
  b="$(body_of "$f")"
  if [[ -z "$b" ]]; then _err "no bssh in ${f#"$ROOT"/}"
  elif [[ "$b" != "$ref" ]]; then _err "bssh in ${f#"$ROOT"/} differs from ${FILES[0]#"$ROOT"/}"; fi
done
done_scenario

scenario "2: nothing sends a remote command with plain ssh"
# The option variables every file uses for command ssh. rsync's -e "ssh ..."
# is a transport, not a command - its remote end is rsync --server, which it
# quotes itself - and `ssh -O exit` carries no command at all.
hits="$(grep -nE '(^|[^-[:alnum:]_])ssh (\$(SSH_OPT|SSHOPT|KS_SSH_OPTS|O)|"\$\{SSHOPT\[@\]\}")([^[:alnum:]_]|$)' \
          "${FILES[@]}" "$ROOT"/lib/*.sh "$ROOT"/bin/ketsync 2>/dev/null \
        | grep -vE ':[0-9]+:[[:space:]]*#' | grep -vE -- '-e "ssh ' || true)"
[[ -z "$hits" ]] || _err "plain ssh sends a remote command - use bssh:
$(sed "s|$ROOT/|        |" <<<"$hits")"
done_scenario

# ---- the matrix: what a remote check looks like, and what breaks it ---------
# Each entry is a command a bash author would write. The first two are the two
# zsh differences that were live on r33; the rest are the quoting bssh has to
# survive: single quotes, double quotes, backslashes, $, newlines, and exit
# status.
CMDS=()
CMDS+=('ls /nonexistent-remote-bash/*/lxc/266.conf 2>/dev/null; echo "rc=$?"')
CMDS+=('ports="eth0 eth1 bond0"; n=0; for p in $ports; do n=$((n+1)); done; echo "n=$n"')
CMDS+=("echo 'single' \"double\" 'it'\\''s'")
CMDS+=('printf "%s|" a\ b "c  d" '"'"'$HOME'"'"'; echo')
CMDS+=('x=1
y=2
echo "sum=$((x+y))"')
CMDS+=('echo "back\\slash \$ dollar"')
CMDS+=('exit 7')

# ssh stand-in: runs the command string the way sshd does - handed to the login
# shell as ONE string. $LOGIN_SH is that shell.
fake_ssh(){ local c="${!#}"; "$LOGIN_SH" -c "$c"; }
eval "$(body_of "$ROOT/engines/ct-migrate.sh")"
ssh(){ fake_ssh "$@"; }

run_matrix(){ # $1 = how: wrapped|plain -> one line per command: status + output
  local c out rc
  for c in "${CMDS[@]}"; do
    if [[ "$1" == wrapped ]]; then out="$(bssh -o BatchMode=yes root@node "$c" </dev/null 2>/dev/null)"; rc=$?
    else out="$(ssh -o BatchMode=yes root@node "$c" </dev/null 2>/dev/null)"; rc=$?; fi
    printf 'rc=%s out=%s\n' "$rc" "$out"
  done
}
want="$(for c in "${CMDS[@]}"; do out="$(bash -c "$c" </dev/null 2>/dev/null)"; printf 'rc=%s out=%s\n' "$?" "$out"; done)"

for sh in sh zsh; do
  scenario "3-$sh: a $sh login shell runs every wrapped command exactly as bash does"
  if ! command -v "$sh" >/dev/null; then
    if [[ "$sh" == zsh ]]; then echo "      zsh not installed - skipped (make gates installs it)"
    else _err "no sh on this machine"; fi
    done_scenario; continue
  fi
  LOGIN_SH="$sh"; got="$(run_matrix wrapped)"
  [[ "$got" == "$want" ]] || _err "differs from bash:
$(diff <(echo "$want") <(echo "$got") | sed 's/^/        /')"
  done_scenario
done

scenario "3-proof: the same matrix sent WITHOUT the wrapper breaks under zsh"
if command -v zsh >/dev/null; then
  LOGIN_SH="zsh"; got="$(run_matrix plain)"
  # the glob line and the split line must both differ, or this matrix no
  # longer contains the bug it exists for
  g1="$(sed -n 1p <<<"$got")"; w1="$(sed -n 1p <<<"$want")"
  g2="$(sed -n 2p <<<"$got")"; w2="$(sed -n 2p <<<"$want")"
  [[ "$g1" != "$w1" ]] || _err "plain ssh + zsh: the unmatched glob behaved like bash ($g1) - the matrix lost its glob case"
  [[ "$g2" != "$w2" ]] || _err "plain ssh + zsh: the word split behaved like bash ($g2) - the matrix lost its split case"
else
  echo "      zsh not installed - skipped"
fi
done_scenario

scenario "4a: stdin reaches the remote command - config writes are 'cat > file'"
LOGIN_SH="sh"
got="$(printf 'line one\nline two\n' | bssh root@node 'cat; echo "rc=$?"')"
[[ "$got" == $'line one\nline two\nrc=0' ]] || _err "got: $got"
command -v zsh >/dev/null && { LOGIN_SH="zsh"
  got="$(printf 'z\n' | bssh root@node 'cat')"; [[ "$got" == z ]] || _err "zsh stdin: $got"; }
done_scenario

scenario "4b: options pass through, and a call with no command is plain ssh"
unset -f ssh
ssh(){ printf '%s\n' "$@"; }
got="$(bssh -o ControlPath=/run/x -c aes128-gcm@openssh.com -n root@h 'true')"
want4=$'-o\nControlPath=/run/x\n-c\naes128-gcm@openssh.com\n-n\nroot@h\nexec bash -c \'true\''
[[ "$got" == "$want4" ]] || _err "argv: $(tr '\n' ' ' <<<"$got")"
got="$(bssh -O exit -o ControlPath=/run/x nohost)"
[[ "$got" == $'-O\nexit\n-o\nControlPath=/run/x\nnohost' ]] || _err "no-command argv: $(tr '\n' ' ' <<<"$got")"
done_scenario

scenario "5: the fakes unwrap every wrapped command back to its exact text"
# shellcheck source=tests/sim/remote-bash.sh
. "$ROOT/tests/sim/remote-bash.sh"
ssh(){ printf '%s' "${!#}"; }
for c in "${CMDS[@]}"; do
  w="$(bssh root@h "$c")"
  if ! unwrap_remote_bash "$w"; then _err "refused a real wrapper: $w"
  elif [[ "$REMOTE_CMD" != "$c" ]]; then _err "unwrapped to something else:
        sent: $c
        got:  $REMOTE_CMD"; fi
done
for bad in "pct status 300" "exec bash -c 'cat '/etc/x''" "exec bash -c 'x" "exec bash -c ''x'"; do
  unwrap_remote_bash "$bad" && _err "accepted a command that is not a clean wrapper: $bad"
done
unwrap_remote_bash "" || _err "refused an empty command (ssh -O exit carries none)"
done_scenario

echo
echo "=== $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then echo "failed: ${FAILED_NAMES[*]}"; exit 1; fi
exit 0
