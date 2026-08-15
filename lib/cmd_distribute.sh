#!/usr/bin/env bash
# shellcheck shell=bash disable=SC1090,SC1091
# =============================================================================
#  ketsync distribute — get out of the way, then place the copies
# -----------------------------------------------------------------------------
#  Every other tp verb this dispatcher names is passed through untouched, and
#  that rule has not moved. This one composes two engines, because SEQUENCING
#  is the one thing this layer is for: `ketsync` decides who does what and in
#  what order, and `tp` does it.
#
#  What it composes:
#
#    ct-prepare.sh    get the production containers out of the way
#    ct-distribute.sh place their copies on a compute node's own storage
#
#  The reason it is one command is the reason the whole DR runbook exists. At
#  four containers, running prepare and then distribute yourself is two lines.
#  At two hundred it is the difference between a fleet that comes back and one
#  where somebody skipped a node at four in the morning.
#
#  WHAT MAKES IT SAFE TO DO AUTOMATICALLY is not this file. It is that
#  ct-prepare.sh refuses unless the container's rootfs storage is PROVABLY
#  dead - a stat on its mountpoint that blocked until a timeout killed it. Run
#  against a healthy fleet, prepare changes nothing and says so, and
#  distribute's own D1 then refuses every container for the usual reason. That
#  is exactly what happened when `distribute --all` was run against this fleet
#  by mistake, and it must keep happening.
#
#  THE SCOPE MAPPING IS NOT COSMETIC:
#
#    --all               -> prepare --evacuate --all
#                           per NODE: disable the dead storage, unmount it,
#                           restart pvestatd, stop what was on it
#    --ctid <id>         -> prepare --isolate --ctid <id>
#                           that container only. Evacuating its node would
#                           disable a storage and stop its neighbours, and
#                           nobody asked about the neighbours
#    no scope at all     -> refused HERE, before the preparer runs. The engine
#                           refuses a scopeless run too, but it refuses LAST,
#                           and this command prepares FIRST - so without this
#                           check a scopeless typo evacuates the fleet on the
#                           way to a usage message
#
#  --list never prepares: it is a read-only question. --dry-run is passed to
#  BOTH, because a dry distribute that evacuated a live node for real would be
#  the worst bug this repo could ship.
#
#  --no-prepare runs the engine alone, for the operator who has already done
#  the first half by hand and wants the second.
# =============================================================================
cmd_distribute(){
  local prep=1 dry=0 list=0 all=0 ctid="" a rc
  declare -a ENG=()
  for a in "$@"; do
    case "$a" in
      --no-prepare) prep=0;;                 # not passed on: the engine has
                                             # never heard of it
      --dry-run)    dry=1;  ENG+=("$a");;
      --list)       list=1; ENG+=("$a");;
      --all)        all=1;  ENG+=("$a");;
      *)            ENG+=("$a");;
    esac
  done
  # --ctid takes a value, and the value is the next argument. Read separately
  # from the loop above so a container id that happens to look like a flag
  # cannot be mistaken for one.
  while (( $# )); do
    [[ "$1" == --ctid && $# -ge 2 ]] && { ctid="$2"; shift 2; continue; }
    shift
  done

  # A scope has to be named BEFORE the preparer runs. The engine refuses a
  # scopeless run on its own, but it refuses LAST and this command prepares
  # FIRST: the 2026-08-16 drill ran `distribute --dry-run` and watched a dry
  # evacuate fire on the way to a usage message - and the non-dry shape of
  # that typo would have evacuated the fleet for real. A refusal that arrives
  # after work is not a refusal.
  if (( ! all && ! list )) && [[ -z "$ctid" ]]; then
    say "refused: no scope given. Say --all, or name one with --ctid, or ask with --list."
    say "  --dry-run is a mode, not a scope: a rehearsal still needs --all or --ctid."
    say "  nothing was prepared and nothing was placed."
    return 2
  fi

  if (( prep )) && (( ! list )); then
    local TPREP="$KS_BASE/engines/ct-prepare.sh"
    if [[ ! -x "$TPREP" ]]; then
      say "ERROR: $TPREP is missing or not executable - NOTHING was run"
      say "ERROR:   the engines are committed in this repo, so this is a broken"
      say "ERROR:   checkout rather than a clone step somebody skipped."
      return 2
    fi
    declare -a PARGS=()
    if [[ -n "$ctid" ]]; then
      PARGS=(--isolate --ctid "$ctid")
      say "== prepare: CT $ctid only - isolating it, NOT evacuating its node"
      say "   evacuating would disable a storage and stop its neighbours, and"
      say "   this command named one container."
    else
      PARGS=(--evacuate --all)
      say "== prepare: every node holding a container in the inventory"
    fi
    (( dry )) && PARGS+=(--dry-run)
    "$TPREP" "${PARGS[@]}"; rc=$?
    # 2 means prepare refused before touching anything - a bad config, a
    # missing inventory, a flag that contradicts itself. Whatever it was will
    # stop distribute in the same way one step later, so it stops here instead,
    # while nothing has been allocated.
    #
    # 1 does NOT stop anything. On a healthy fleet every container is skipped
    # and that is exactly the correct outcome; on a real one some containers
    # prepare and others do not, and D1 is the guard that decides what happens
    # to each of them. Two places deciding that would be one too many.
    if (( rc == 2 )); then
      say "== prepare refused before touching anything (exit 2) - not distributing"
      return 2
    fi
    (( rc != 0 )) && say "== prepare finished with exit $rc - carrying on; D1 decides per container"
  fi

  local TP="$KS_BASE/engines/tp"
  if [[ ! -x "$TP" ]]; then
    say "ERROR: $TP is missing or not executable - NOTHING was run"
    return 2
  fi
  # exec, so the engine's exit code is the one cron reads. There is nothing
  # useful this layer could do afterwards, and anything it did would be a
  # chance to lose that code.
  exec "$TP" distribute ${ENG[@]+"${ENG[@]}"}
}
