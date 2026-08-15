# shellcheck shell=bash
# shared state helpers for the fake PVE/system commands
: "${SIMROOT:?SIMROOT not set - run through sim/run-sim.sh}"
esc(){ printf '%s' "$1" | tr '/' '%'; }
violation(){ echo "VIOLATION: $*" >> "$SIMROOT/violations"; }

# --- the dry-run invariant --------------------------------------------------
# SIM_DRY is exported by run_engine when the ENGINE was invoked with --dry-run,
# read out of the engine's own argv rather than set by the scenario. That is
# the whole point: every dry scenario is policed by this, including ones
# written months from now by somebody who never read the one that introduced
# it, and a write that somebody forgets to gate is caught the first time it
# runs rather than the first time a human thinks to assert on it.
#
# A dry run may read anything. Anything that would change the fleet - allocate,
# format, resize, snapshot, mount read-write, write a config, move bytes - is a
# violation, because the engine told the operator it would write nothing.
dry_forbids(){
  (( ${SIM_DRY:-0} )) || return 0
  violation "$* during a --dry-run - the engine said it would write nothing"
}
is_mounted(){ grep -qxF "$1" "$SIMROOT/mounted" 2>/dev/null; }
add_mount(){ echo "$1" >> "$SIMROOT/mounted"; }
del_mount(){ grep -vxF "$1" "$SIMROOT/mounted" > "$SIMROOT/.m" 2>/dev/null; mv -f "$SIMROOT/.m" "$SIMROOT/mounted"; }
loop_of(){ [[ -f "$SIMROOT/loopmap" ]] && awk -v i="$1" '$1==i{print $2}' "$SIMROOT/loopmap"; }
add_loop(){ echo "$1 $2" >> "$SIMROOT/loopmap"; }
del_loop_by_mnt(){ [[ -f "$SIMROOT/loopmap" ]] || return 0
  awk -v m="$1" '$2!=m' "$SIMROOT/loopmap" > "$SIMROOT/.l"; mv -f "$SIMROOT/.l" "$SIMROOT/loopmap"; }
trace(){ echo "$*" >> "$SIMROOT/trace"; }
# deepest mounted ancestor of a path, or "/" if none - mirrors findmnt -T
fs_holder(){ local p="${1%/}"
  while [[ -n "$p" ]]; do is_mounted "$p" && { echo "$p"; return 0; }; p="${p%/*}"; done
  echo "/"; }
