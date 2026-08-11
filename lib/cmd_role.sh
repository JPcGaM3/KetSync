#!/usr/bin/env bash
# shellcheck shell=bash disable=SC1090,SC1091
# =============================================================================
#  ketsync role — who this machine thinks it is, and how to change it
# -----------------------------------------------------------------------------
#  Promotion is a file a human writes, not an election. Two machines cannot
#  tell "the master is dead" from "I cannot reach the master", and the cost of
#  getting that wrong here is two machines running rsync --delete into the same
#  datasets. See docs/decisions.md section 2 for the whole argument, including
#  why the destination-side lock makes a mistaken double master survivable.
# =============================================================================
cmd_role(){
  local want="${1:-}"
  if [[ -z "$want" ]]; then
    log "role:      $KS_ROLE"
    log "master ip: ${KS_MASTER_IP:-<unset>}"
    log "this host: $(hostname) $(hostname -I 2>/dev/null | awk '{print $1}')"
    [[ "$KS_ROLE" == master ]] \
      && log "this machine owns the tables; run 'ketsync sync' after every edit" \
      || log "this machine receives the tables; edit them on ${KS_MASTER_IP:-the master}, not here"
    exit 0
  fi
  case "$want" in
    master|slave) ;;
    *) die "role is 'master' or 'slave', not '$want'";;
  esac
  [[ "$want" == "$KS_ROLE" ]] && { log "already $want - nothing to do"; exit 0; }
  log "changing the role of a running machine is a decision, not a command."
  log "  edit KS_ROLE in $(basename "$KS_CONF") by hand, on the machine that is taking over,"
  log "  and only after you are certain the other one is not writing. Two masters"
  log "  writing into one dataset is the failure this whole design exists to avoid."
  log "  then:  ketsync sync --dry-run   and read it before you drop --dry-run."
  exit 2
}
