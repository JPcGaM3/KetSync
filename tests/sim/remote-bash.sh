# shellcheck shell=bash
# Sourced by every fake ssh. The engines send each remote command as
#     exec bash -c '<the command>'
# (bssh - see any engine), so that a node whose root logs into zsh still runs
# it under bash. The fakes model what the command MEANS, so they unwrap it
# first and match the text underneath, exactly as they did before.
#
# A command that arrives NOT wrapped is refused, loudly, in every simulator.
# That is the whole point of the check: a new remote call written as plain
# `ssh ... "cmd"` runs under whatever shell the node gives root, and on a zsh
# node the failure reads as a pass. Refusing it here turns every scenario that
# reaches the call into a red one, instead of one scenario somebody has to
# remember to write.
#
# unwrap_remote_bash "$c": 0 and REMOTE_CMD=<inner command> when $c is empty or
# a well-formed wrapper; 1 otherwise. Well-formed means the only single quotes
# left inside are the '\'' escapes bssh itself writes.
unwrap_remote_bash(){
  local w="$1" pre="exec bash -c '" body rest
  REMOTE_CMD=""
  [[ -z "$w" ]] && return 0
  [[ "$w" == "$pre"*"'" && ${#w} -gt ${#pre} ]] || return 1
  body="${w#"$pre"}"; body="${body%\'}"
  rest="${body//\'\\\'\'/}"
  [[ "$rest" == *\'* ]] && return 1
  # shellcheck disable=SC2034  # read by the fake that sourced this
  REMOTE_CMD="${body//\'\\\'\'/\'}"
  return 0
}

# require_remote_bash "$c" <violation-file>: unwrap into REMOTE_CMD, or record
# the violation and exit 126 - the status a shell gives a command it could not
# run, which is what a zsh node effectively did with these.
require_remote_bash(){
  if unwrap_remote_bash "$1"; then return 0; fi
  printf 'VIOLATION: remote command not run under bash (plain ssh, the login shell reads it): %s\n' \
    "$1" >> "$2"
  echo "fake ssh: remote command not wrapped in 'exec bash -c' - use bssh" >&2
  exit 126
}
