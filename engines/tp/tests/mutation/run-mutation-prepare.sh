#!/usr/bin/env bash
# =============================================================================
#  run-mutation-prepare.sh — check that the prepare simulator can FAIL.
# -----------------------------------------------------------------------------
#  Same contract as run-mutation.sh, pointed at the engine that writes to the
#  config of a container that is running. A green suite means nothing until you
#  have seen it go red for the right reason: this takes ct-prepare.sh, breaks
#  one specific thing in it, and runs the scenarios that are supposed to
#  notice. A scenario that still passes against a broken engine is not a test,
#  it is decoration.
#
#  Every mutation is a literal-text edit anchored on a line of the engine. When
#  the anchor moves the mutation applies to nothing, and that is reported as a
#  failure too: a mutation that cannot be applied has stopped proving anything.
#  So any edit to ct-prepare.sh must be mirrored here in the same change, and a
#  broken anchor is never "fixed" by deleting the mutation.
#
#  Each one is a bug a person could really write - a guard inverted, a check
#  moved back to where it used to live, a variable cleared one line too early.
#  A mutant that only proves bash still parses proves nothing.
#
#  usage:  ./tests/mutation/run-mutation-prepare.sh
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SIM="$ROOT/tests/sim/prepare/run-sim-prepare.sh"
SRC="$ROOT/ct-prepare.sh"
PASS=0; FAIL=0; FAILED_NAMES=()

command -v perl >/dev/null || { echo "perl is required for the mutation suite"; exit 1; }
[[ -x "$SIM" ]] || { echo "the prepare simulator is not where this expects it: $SIM"; exit 1; }
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
  m="$(mktemp /tmp/ctprep-mutant.XXXXXX)"
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

echo "=== ct-prepare.sh mutation suite ==="

# ---------- P2: the guard the whole engine hangs off -------------------------
# A storage that answered is a container whose disk is fine, which is a
# container that is very likely serving somebody. Every mutation here ends with
# the tool causing the outage it exists to prevent, so the fake records a
# VIOLATION as well as the scenario failing.

mutant "P2 isolates a container whose storage answered" \
  's{\Q  if [[ "\E\$verdict\Q" == alive ]]; then\E}{  if false; then}' \
  3

mutant "P2 reads a storage that answered instantly as one that never answered" \
  's{\Q    0)   printf \E\x27\Qalive\E\x27\Q;;\E}{    0)   printf \x27dead\x27;;}' \
  3

mutant "P2 reads a mountpoint that is not there as a live storage" \
  's{\Q    *)   printf \E\x27\Qgone\E\x27\Q;;\E}{    *)   printf \x27alive\x27;;}' \
  4

# ---------- P1: unreachable is not safe to change ----------------------------
mutant "P1 treats a node that did not answer as one with nothing to say" \
  's{\Q  if [[ -z "\E\$out\Q" ]]; then\E\n\Q    log "[\E\$ct\Q] GUARD P1: \E\$pn\Q (\E\$pip\Q) did not answer\E}{  if false; then\n    log "[\$ct] GUARD P1: \$pn (\$pip) did not answer}' \
  11

mutant "P1 invents a node for a container the cluster has never heard of" \
  's!\Q  if [[ -z "\E\$pn\Q" ]]; then\E\n\Q    log "[\E\$ct\Q] GUARD P1: CT \E\$ct\Q has no config anywhere in the cluster - nothing to isolate"\E!  if false; then\n    log "[\$ct] GUARD P1: CT \$ct has no config anywhere in the cluster - nothing to isolate"!' \
  12

mutant "the container is looked for under the wrong id" \
  's#\Qls /etc/pve/nodes/*/lxc/\E\$1\Q.conf\E#ls /etc/pve/nodes/*/lxc/x\$1.conf#' \
  1

# ---------- P3: a stopped container is not a thing to rewrite ----------------
mutant "P3 rewrites the bridge names of a container that is not even running" \
  's{\Q  if [[ "\E\$st\Q" != running ]]; then\E}{  if false; then}' \
  5

mutant "P3 isolates a container that has no interfaces at all" \
  's{\Q(( nets == 0 )); then\E}{(( 0 )); then}' \
  32

# ---------- P4: a bridge that does not isolate -------------------------------
mutant "P4 moves interfaces onto a bridge the node does not have" \
  's{\Q  if [[ "\E\$out\Q" == *BRMISSING* ]]; then\E}{  if false; then}' \
  6

mutant "P4 stops asking whether the isolated bridge reaches a wire" \
  's{\Q  if [[ "\E\$out\Q" == *UPLINK* ]]; then\E}{  if false; then}' \
  7

# ---------- P5: the record is the only copy of what is being overwritten -----
mutant "P5 isolates a second time and writes vmbr99 down as the way back" \
  's!\Q  if [[ -n "\E\$\Q(rec_field "\E\$rec\Q" ctid)" ]]; then\E!  if false; then!' \
  8

mutant "P5 stops noticing an interface somebody already moved by hand" \
  's{\Q  if [[ -n "\E\$_iso_bad\Q" ]]; then\E}{  if false; then}' \
  9

mutant "the bridge is matched as a prefix, so vmbr990 reads as vmbr99" \
  's{\Q    [[ "\E\$_br\Q" == "\E\$MOCKNET_BRIDGE\Q" ]] && _iso_bad=\E}{    [[ "\$_br" == "\$MOCKNET_BRIDGE"* ]] \&\& _iso_bad=}' \
  36

# ---------- P6: a config PVE did not apply ----------------------------------
mutant "P6 reports a container isolated because the config says so" \
  's{\Q  if [[ -n "\E\$_wired\Q" ]]; then\E\n\Q    log "[\E\$ct\Q] GUARD P6\E}{  if false; then\n    log "[\$ct] GUARD P6}' \
  10

mutant "P6 reads the config back instead of the kernel" \
  's{\Q    [[ "\E\$_k\Q" == VETH ]] || continue\E}{    [[ "\$_k" == NETLINE ]] || continue}' \
  10

# ---------- the record, and the order it is written in -----------------------
# The invariant no log line can prove. Reversed, every message still reads
# correctly and the fleet loses its only copy of the bridge names the first
# time a run dies halfway - so the fake holds it, not a scenario.
mutant "the record never lands, and the interfaces move anyway" \
  's#\Q        "mkdir -p \E\$REC_DIR\Q && cat > \E\x27\Q\E\$\Q(rec_path "\E\$ct\Q")\E\x27\Q" 2>/dev/null; then\E#        "cat > /dev/null" 2>/dev/null; then#' \
  1

mutant "the record keeps the bridge it is moving TO, not the one it came from" \
  's!\QNETBRS+=("\E\$\Q(net_bridge "\E\$_line\Q")")\E!NETBRS+=("\$MOCKNET_BRIDGE")!' \
  2

mutant "onboot is looked for under a word the probe never prints" \
  's!\QONBOOT"{print\E!ONBOOTX"{print!' \
  2

mutant "a record that did not read back is taken on trust" \
  's#\Q  if [[ "\E\$\Q(rec_field "\E\$back\Q" ctid)" != "\E\$ct\Q" ]]; then\E#  if false; then#' \
  37

# ---------- the move itself --------------------------------------------------
mutant "the interface is written back unchanged, so nothing actually moves" \
  's!\Qsed -E "s/bridge=[^,]*/bridge=\E\$MOCKNET_BRIDGE\Q/"\E!sed -E "s/unchanged=x/unchanged=y/"!' \
  1

mutant "only the first interface is moved, the way somebody reads net0 and stops" \
  's{\Q  for (( i = 0; i < \E\$\{#NETIDS\[@\]\}\Q; i++ )); do\E\n\Q    _line=\E}{  for (( i = 0; i < 1; i++ )); do\n    _line=}' \
  13

# ---------- restore ---------------------------------------------------------
mutant "restore invents a bridge for a container with no record" \
  's!\Q  if [[ -z "\E\$\Q(rec_field "\E\$rec\Q" ctid)" ]]; then\E!  if false; then!' \
  18

mutant "restore reads the isolated bridge out of the record instead of the real one" \
  's!\QRIDS+=("\E\$_k\Q"); RBRS+=("\E\$_v\Q")\E!RIDS+=("\$_k"); RBRS+=("\$MOCKNET_BRIDGE")!' \
  17

mutant "restore leaves onboot wherever the disaster left it" \
  's{\Q    rsh "\E\$pip\Q" "pct set \E\$ct\Q --onboot \E\$\{rob:-0\}\Q"\E}{    :}' \
  17

mutant "restore carries on past an interface the record names and the config lost" \
  's!\Q    if [[ -z "\E\$_line\Q" ]]; then\E!    if false; then!' \
  19

# ---------- --dry-run must write nothing ------------------------------------
mutant "a dry run writes the record anyway" \
  's{\Q    log "[\E\$ct\Q] DRY: would move \E\$\{NETIDS\[\*\]\}\Q onto \E\$MOCKNET_BRIDGE\Q and verify from /sys/class/net"\E\n\Q    st_ok "\E\$ct\Q"; return 0\E}{    log "[\$ct] DRY: would move \$\{NETIDS[*]\} onto \$MOCKNET_BRIDGE and verify from /sys/class/net"}' \
  15

mutant "a dry restore puts the interfaces back for real" \
  's!\Q  if (( DRY )); then\E\n\Q    for (( i = 0; i < \E!  if false; then\n    for (( i = 0; i < !' \
  20

# ---------- the flags, and refusing an incomplete instruction ---------------
mutant "opposite directions in one command are resolved instead of refused" \
  's{\Qif (( ISOLATE && RESTORE )); then\E}{if false; then}' \
  28

mutant "a command with no mode picks one" \
  's{\Qif (( ! LIST && ! ISOLATE && ! RESTORE && ! EVACUATE )); then\E}{if false; then}' \
  27

mutant "a container listed twice in the inventory is read as one" \
  's!\Q  if [[ -n "\E\$\{SEEN_CT\[\$\{f\[0\]\}\]:-\}\Q" ]]; then\E!  if false; then!' \
  25

mutant "--ctid for a container with no row is taken as an empty workload" \
  's{\Q  if (( \E\$\{#CTS\[@\]\}\Q == 0 )); then\E\n\Q    log "ERROR: CT \E\$ONLY_CTID\Q has no row\E}{  if false; then\n    log "ERROR: CT \$ONLY_CTID has no row}' \
  24

mutant "a MOCKNET_BRIDGE that is not an interface name is used as typed" \
  's# \Q=~ ^[A-Za-z0-9._-]+\E# =~ ^.*#' \
  34

mutant "a zero stat timeout, which makes every storage read as alive" \
  's{\Q(( STAT_TIMEOUT >= 1 ))\E}{(( 1 ))}' \
  35

# ---------- where the log goes ----------------------------------------------
mutant "the log is written outside the engine's own tree" \
  's{\QLOGDIR="\E\$BASE\Q/logs"\E}{LOGDIR="\$BASE/../../logs"}' \
  1

# ---------- --evacuate: a node, and the order it is dealt with in -----------
# Disable, unmount, THEN stop. Everyone does it the other way round, including
# the runbook this replaced, because the instinct is to close the container
# before touching its disk - and a container whose dead rootfs is still mounted
# cannot be closed at all.

mutant "E2 evacuates a node whose storage answered perfectly well" \
  's{\Q  if (( \E\$\{#DEADSIDS\[@\]\}\Q == 0 )); then\E}{  if false; then}' \
  40

mutant "E2 stops leaving healthy storages, and the containers on them, alone" \
  's{\Q      log "[\E\$pip\Q] E2: CT \E\$ct\Q is on \E\x27\Q\E\$sid\Q\E\x27\Q, which answered - left alone, not touched"\E\n\Q      continue\E}{      log "[\$pip] E2: CT \$ct is on \x27\$sid\x27, which answered - left alone, not touched"}' \
  41

mutant "the record of what was switched off never lands" \
  's#\Q        "mkdir -p \E\$EVAC_DIR\Q && cat > \E\x27\Q\E\$\Q(evac_path "\E\$pn\Q")\E\x27\Q" 2>/dev/null; then\E#        "cat > /dev/null" 2>/dev/null; then#' \
  42

mutant "the storage is disabled but never unmounted, so nothing can be stopped" \
  's{\Q    if rsh "\E\$pip\Q" "umount -f -l \E\x27\Q\E\$\{DEADPATHS\[\$i\]\}\Q\E\x27\Q"; then\E}{    if false; then}' \
  38

mutant "pvestatd is left holding the mount that just went away" \
  's{\Q"systemctl restart pvestatd"\E}{"true"}' \
  38

mutant "the shutdown is believed rather than checked" \
  's#\Q    if [[ "\E\$st\Q" != running ]]; then\E#    if true; then#' \
  39

mutant "a container that will not stop is forced instead of isolated" \
  's{\Q    do_isolate "\E\$ct\Q" || true\E}{    rsh "\$pip" "pct stop \$ct" || true}' \
  39

mutant "restore --node switches on a storage this tool never switched off" \
  's{\Q  if [[ -z "\E\$rec\Q" ]]; then\E}{  if false; then}' \
  44

mutant "--evacuate is taken as a per-container verb after all" \
  's{\Qif (( EVACUATE )) && (( ! ALL )) && [[ -z "\E\$ONLY_NODE\Q" ]]; then\E}{if false; then}' \
  46

mutant "--evacuate and --isolate in one command are merged instead of refused" \
  's{\Qif (( EVACUATE && (ISOLATE || RESTORE) )); then\E}{if false; then}' \
  47

mutant "a node holding none of the inventory is evacuated anyway" \
  's{\Q  if (( \E\$\{#MINE\[@\]\}\Q == 0 )); then\E}{  if false; then}' \
  48

mutant "evacuate --all stops after the first node it finds" \
  's{\Q      SEEN_NODE[\E\$_pip\Q]=1; NODES+=("\E\$_pip\Q")\E}{      SEEN_NODE[\$_pip]=1; [[ \$\{#NODES[@]\} == 0 ]] \&\& NODES+=("\$_pip")}' \
  49

echo
echo "=== $PASS mutations killed, $FAIL survived ==="
if (( FAIL > 0 )); then echo "survived: ${FAILED_NAMES[*]}"; exit 1; fi
exit 0
