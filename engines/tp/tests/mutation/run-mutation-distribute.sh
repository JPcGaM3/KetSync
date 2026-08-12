#!/usr/bin/env bash
# =============================================================================
#  run-mutation-distribute.sh — check that the distribute simulator can FAIL.
# -----------------------------------------------------------------------------
#  Same contract as run-mutation.sh, pointed at the engine that runs during the
#  worst hour this fleet will have. A green suite means nothing until you have
#  seen it go red for the right reason: this takes ct-distribute.sh, breaks one specific thing in
#  it, and runs the scenarios that are supposed to notice. A scenario that still
#  passes against a broken engine is not a test, it is decoration.
#
#  Every mutation is a literal-text edit anchored on a line of the engine. When
#  the anchor moves the mutation applies to nothing, and that is reported as a
#  failure too: a mutation that cannot be applied has stopped proving anything.
#  So any edit to ct-distribute.sh must be mirrored here in the same change, and a
#  broken anchor is never "fixed" by deleting the mutation.
#
#  Each one is a bug a person could really write - a guard inverted, a check
#  moved back to where it used to live, a variable cleared one line too early.
#  A mutant that only proves bash still parses proves nothing.
#
#  usage:  ./tests/mutation/run-mutation-failback.sh
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SIM="$ROOT/tests/sim/distribute/run-sim-distribute.sh"
SRC="$ROOT/ct-distribute.sh"
PASS=0; FAIL=0; FAILED_NAMES=()

command -v perl >/dev/null || { echo "perl is required for the mutation suite"; exit 1; }
[[ -x "$SIM" ]] || { echo "the distribute simulator is not where this expects it: $SIM"; exit 1; }
[[ -r "$SRC" ]] || { echo "no engine to mutate: $SRC"; exit 1; }

# Extra environment for the NEXT mutant only, cleared again by mutant(). One
# mutation below is about what the engine takes from the process that started
# it - the PATH cron hands it - and that can only be said from outside the
# engine. Nothing else uses this.
RUN_ENV=()

# $1 = name, $2 = perl s{}{} program, rest = scenarios that MUST fail on it
mutant(){
  local name="$1" prog="$2"; shift 2
  local m ok=1 s
  m="$(mktemp /tmp/ctdist-mutant.XXXXXX)"
  echo "  [$name]"
  # A zero-byte mutant is not a mutant. perl refusing the program - an
  # unbalanced brace inside s{}{} is the easy way to get there - writes nothing,
  # and an empty file is valid bash that fails every scenario for no reason at
  # all. That would report as a kill and prove the opposite of one. Half an
  # engine is the same failure one step less obvious, which is why the size
  # check is separate rather than folded into the emptiness one.
  if ! perl -0777 -pe "$prog" "$SRC" > "$m" 2>/dev/null; then
    echo "      x perl refused the mutation program - fix the mutation, not the engine"
    rm -f "$m"; RUN_ENV=(); FAIL=$((FAIL+1)); FAILED_NAMES+=("$name"); return
  fi
  if [[ ! -s "$m" ]] || (( $(wc -c <"$m") < $(( $(wc -c <"$SRC") / 2 )) )); then
    echo "      x the mutant is empty or half the engine is gone - that is corruption, not a mutation"
    rm -f "$m"; RUN_ENV=(); FAIL=$((FAIL+1)); FAILED_NAMES+=("$name"); return
  fi
  if cmp -s "$m" "$SRC"; then
    echo "      x the mutation matched nothing - its anchor has moved in the engine"
    rm -f "$m"; RUN_ENV=(); FAIL=$((FAIL+1)); FAILED_NAMES+=("$name"); return
  fi
  if ! bash -n "$m" 2>/dev/null; then
    echo "      x the mutant does not even parse - fix the mutation, not the engine"
    rm -f "$m"; RUN_ENV=(); FAIL=$((FAIL+1)); FAILED_NAMES+=("$name"); return
  fi
  chmod +x "$m"
  for s in "$@"; do
    if env ${RUN_ENV[@]+"${RUN_ENV[@]}"} ENGINE="$m" "$SIM" "$s" >/dev/null 2>&1; then
      echo "      x scenario $s SURVIVES the mutation - it is not testing this"
      ok=0
    else
      echo "      - scenario $s dies, as it must"
    fi
  done
  rm -f "$m"; RUN_ENV=()
  if (( ok )); then PASS=$((PASS+1)); echo "      ok"
  else FAIL=$((FAIL+1)); FAILED_NAMES+=("$name"); fi
}

# The runner's own safety net, exercised before it grades anything. The guards
# inside mutant() exist because a mutation that had never been applied reported
# green for weeks - and a guard nobody exercises is how the replica runner came
# to be missing both of them while CLAUDE.md said otherwise. Each probe calls
# mutant() for real inside a command substitution, so its counters and its
# output are thrown away and only the refusal is read. The two probes are
# different failures on purpose: the first makes perl exit non-zero and write
# nothing, the second lets perl succeed and produce an empty file. A runner
# that cannot refuse both stops here rather than grading.
self_check(){
  local out
  out="$(mutant "self-check: a program perl cannot compile" 's{unbalanced' 1 2>&1)"
  [[ "$out" == *"perl refused the mutation program"* ]] || {
    echo "SELF-CHECK FAILED: mutant() accepted a program perl cannot compile" >&2
    printf '%s\n' "$out" >&2; exit 2; }
  out="$(mutant "self-check: a program that empties the engine" 's{\A.*\z}{}s' 1 2>&1)"
  [[ "$out" == *"empty or half the engine is gone"* ]] || {
    echo "SELF-CHECK FAILED: mutant() accepted an empty mutant" >&2
    printf '%s\n' "$out" >&2; exit 2; }
}
self_check


echo "=== ct-distribute.sh mutation suite ==="

# ---------- D1: two copies of one host must never answer at once -------------
# This is rule 4 from the DR direction. The copy carries the production IP and
# MAC on purpose, so placing one while the original is up is not a duplicate
# container, it is two machines on one address.

mutant "D1 places a copy while the production CT is still running" \
  's{\Q    if [[ "\E\$pstat\Q" == running ]]; then\E}{    if false; then}' \
  4

mutant "D1 asks nobody, so 'still running' cannot be found out at all" \
  's{\Q    pstat=\E\$\Q(rsh\E}{    pstat=""; : \$(rsh}' \
  4

# ---------- D2: a live rootfs copies torn ------------------------------------
mutant "D2 copies out of a copy that is running" \
  's{\Q  if [[ "\E\$sstat\Q" == running ]]; then\E}{  if false; then}' \
  6

# ---------- D3: the id must be nobody else's ---------------------------------
mutant "D3 stops looking for other owners of the 9xxx id" \
  's{\Q  if [[ -n "\E\$owners\Q" ]]; then\E}{  if false; then}' \
  7

mutant "D3 looks for the id only where the copy is, not across the cluster" \
  's{\Qls /etc/pve/nodes/*/lxc/\E\$CT_DR\Q.conf /etc/pve/nodes/*/qemu-server/\E\$CT_DR\Q.conf\E}{ls /etc/pve/nodes/\$BKP_NODE/lxc/\$CT_DR.conf}' \
  7

# ---------- D4: what the destination actually is -----------------------------
mutant "D4 allocates into a storage PVE says is inactive" \
  's{\Q  if [[ "\E\$\{ST_ACTIVE\[\$key\]\}\Q" != active ]]; then\E}{  if false; then}' \
  8

# This one is not hypothetical. It is what shipped: the Status column of
# `pvesm status` holds a word, the guard compared it against the 1 the API
# returns, no word is ever equal to 1, and D4 therefore refused every storage
# on every node - distribute could not place a single container. It passed 33
# scenarios because the fake pvesm printed 1 too. Both halves are fixed; this
# mutation is here so the suite can prove it would notice a third time.
mutant "D4 compares the pvesm Status word against the number the API returns" \
  's{\Q" != active ]]; then\E}{" != 1 ]]; then}' \
  1

mutant "D4 guesses at a storage type it has never seen" \
  's{\Q    *)             printf \E..\Q;;\E}{    *)             printf \x27block\x27;;}' \
  9

mutant "D4 treats a storage that is not there as one that is" \
  's{\Q  if ! probe_storage "\E\$CT_TO\Q" "\E\$CT_DST\Q"; then\E}{  if false; then}' \
  10

# ---------- D5: a thin pool that fills takes the node with it ----------------
mutant "D5 stops checking free space before allocating" \
  's{\Q  if (( availb < needb )); then\E}{  if false; then}' \
  11 12

mutant "D5 counts the rootfs but drops the headroom" \
  's{\Q  needb=\E\$\Q(( bytes + bytes * DR_HEADROOM_PCT / 100 ))\E}{  needb=\$(( bytes ))}' \
  12

# ---------- D6: a config for a container nobody filled ----------------------
mutant "D6 writes the config even when the transfer failed" \
  's{\Q  if [[ "\E\$rc\Q" != 0 && "\E\$rc\Q" != 24 ]]; then\E}{  if false; then}' \
  13

mutant "D6 calls rsync 23 a success, so a partial transfer ships" \
  's{\Q!= 0 && "\E\$rc\Q" != 24 ]]\E}{!= 0 && "\$rc" != 24 && "\$rc" != 23 ]]}' \
  13

mutant "D6 stops reading the config back, so a truncated one is accepted" \
  's{\Q  if [[ "\E\$out\Q" != "\E\$newcfg\Q" ]]; then\E}{  if false; then}' \
  15

# ---------- placement is never guessed ---------------------------------------
mutant "a CT with no target is placed on the first thing that answers" \
  's{\Q  if [[ -z "\E\$CT_TO\Q" ]]; then\E}{  CT_TO="\${CT_TO:-10.100.1.32}"\n  if false; then}' \
  17

mutant "--to stops overriding what fleet.tsv says" \
  's{\Q  [[ -n "\E\$TO_IP\Q" ]] && { printf \E.%s.\Q "\E\$TO_IP\Q"; return 0; }\E}{  :}' \
  18 19

mutant "--dst stops overriding the storage column" \
  's{\Q  [[ -n "\E\$DST_SID\Q" ]] && { printf \E.%s.\Q "\E\$DST_SID\Q"; return 0; }\E}{  :}' \
  10 18

# ---------- the path the transfer actually takes ----------------------------
# Both ends are remote. Finding out afterwards that the target could not reach
# the backup node means an allocated volume and a half-written config.
mutant "the target-to-backup ssh is assumed instead of checked" \
  's{\Q  if ! rsh "\E\$CT_TO\Q" "ssh -o BatchMode=yes -o ConnectTimeout=10 \E\$BKP_SSH\Q true"; then\E}{  if false; then}' \
  23

mutant "an unreachable target is discovered by allocating on it" \
  's{\Q  if ! rsh "\E\$CT_TO\Q" true; then\E}{  if false; then}' \
  24

mutant "a backup node that will not say who it is is carried on with anyway" \
  's{\Qif [[ -z "\E\$_bknode\Q" ]]; then\E}{if false; then}' \
  25

# ---------- the shapes ------------------------------------------------------
mutant "a zfspool dataset is mkfs'd and mounted like a block device" \
  's{\Q  if [[ "\E\$shape\Q" == dataset ]]; then\E}{  if false; then}' \
  2

mutant "every destination is treated as a raw file needing a loop device" \
  's{\Q    local mopt=""; [[ "\E\$shape\Q" == image ]] && mopt="-o loop "\E}{    local mopt="-o loop "}' \
  1

mutant "no destination gets a loop device, so a raw file is mounted as a device" \
  's{\Q[[ "\E\$shape\Q" == image ]] && mopt="-o loop "\E}{:}' \
  32

# ---------- the run itself --------------------------------------------------
mutant "a missing DR copy is treated as an empty one" \
  's{\Q  if [[ -z "\E\$cfg\Q" ]]; then\E}{  if false; then}' \
  26

mutant "a --ctid that matches no row exits 0 with nothing done" \
  's{\Q  if (( ! \E\$\{#_keep\[@\]\}\Q )); then\E}{  if false; then}' \
  27

mutant "a size the engine cannot read is allocated anyway" \
  's{\Q  if [[ -z "\E\$bytes\Q" || "\E\$bytes\Q" == 0 ]]; then\E}{  if false; then}' \
  33

mutant "the run lock is never contended, so two placements can overlap" \
  's{\Qif ! flock -n 9; then\E}{if false; then}' \
  30

mutant "the production network is dropped from the placed config" \
  's{\Q          -e "s|^onboot:.*|onboot: 0|")\E}{          -e "s|^net0:.*||" -e "s|^onboot:.*|onboot: 0|")}' \
  28


# ---------- the three levels of rule --------------------------------------
# Flattening them back to one is invisible until the night somebody is
# scrolling a daily log for the container that did not come back, and every
# boundary in it looks the same. It costs nothing to write and it is exactly
# the kind of line a later reader tidies away.
mutant "every rule is the same again, so no boundary says which kind it is" \
  's{\QLOGSEP2=\E.=+.}{LOGSEP2="\$LOGSEP"}' \
  29

mutant "the container list never opens or closes, only the run does" \
  's{^(\s*)hr_ct$}{\$1hr}m' \
  29
# ---------- the one log tree ------------------------------------------------
# Both layers write into ketsync's logs/ when this engine is vendored inside
# it, which it always is on a real install. The walk-up is GUARDED, because an
# engine that has been copied somewhere else would otherwise write two
# directories above itself - into somebody's home, or /, or whatever happens to
# sit there. Every simulator sandbox takes the guarded path, which is what
# makes both of these observable.
# Anchored on the LOGDIR line above it: the same condition now appears twice in
# this engine - once for ketsync's tables, once for the log tree - and an
# anchor that matches the wrong one silently tests nothing.
mutant "the log is written two directories up whether ketsync is there or not" \
  's{\QLOGDIR="\E\$BASE\Q/logs"\E\n\Qif [[ -f "\E\$BASE\Q/../../ketsync" && -f "\E\$BASE\Q/../../lib/common.sh" ]]; then\E}{LOGDIR="\$BASE/logs"\nif true; then}' \
  1

mutant "the fallback log directory is not the engine's own" \
  's{\QLOGDIR="\E\$BASE\Q/logs"\E}{LOGDIR="\$BASE/../logs"}' \
  1

# ---------- ketsync's tables, not a copy of them ----------------------------
# The mirror this replaced failed on the fleet: sync delivered fleet.tsv to the
# backup node's repo root, the engine read a copy that nothing had refreshed,
# and distribute refused every container 43 seconds after a successful sync.
mutant "the engine reads the copy beside itself instead of ketsync's own table" \
  's{\QNODEMAP="\E\$BASE\Q/nodes.map"    # ip <TAB> pve node name, generated by ketsync\E\n\Qif [[ -f "\E\$BASE\Q/../../ketsync" && -f "\E\$BASE\Q/../../lib/common.sh" ]]; then\E}{NODEMAP="\$BASE/nodes.map"    # ip <TAB> pve node name, generated by ketsync\nif false; then}' \
  35

mutant "only the node map is taken from ketsync, the placement table is not" \
  's{\Q  [[ -f "\E\$_ks\Q/fleet.tsv" ]] && FLEET="\E\$_ks\Q/fleet.tsv"\E}{  :}' \
  35

mutant "the fallback placement table is not the engine's own" \
  's{\QFLEET="\E\$BASE\Q/fleet.tsv"      # ketsync\E.\Qs placement table\E}{FLEET="\$BASE/../fleet.tsv"}' \
  1

echo
echo "=== $PASS mutations killed, $FAIL survived ==="
if (( FAIL > 0 )); then echo "survived: ${FAILED_NAMES[*]}"; exit 1; fi
exit 0
