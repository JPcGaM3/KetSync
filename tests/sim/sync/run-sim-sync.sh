#!/usr/bin/env bash
# =============================================================================
#  run-sim-sync.sh — execute `ketsync sync` against a fake fleet.
# -----------------------------------------------------------------------------
#  This is the first simulator this layer has ever had, and sync is the right
#  place to start: it is the only ketsync command that WRITES to another
#  machine. Everything it can get wrong is silent. A push that went nowhere, a
#  push that went to the wrong path, a slave left holding last month's
#  inventory - none of them print an error on the machine you are standing on,
#  and the first anybody hears of it is a container that had no DR copy.
#
#  The fleet lives under $SIMROOT, and every other machine is modelled as a
#  WHOLE FILESYSTEM rather than as "this directory again":
#
#    $SIMROOT/master/           this machine. KS_BASE points here
#    $SIMROOT/hosts/<ip>/fs/    that machine's filesystem, from /
#
#  That is deliberate. Every install in this fleet is at a different absolute
#  path, and a simulator that assumes they match cannot see what that does.
#
#  A scenario can FAIL two ways: wrong observable behaviour - exit code, log,
#  what ended up on the far side - or a broken invariant, which the fakes
#  record in $SIMROOT/violations. The second is the one that matters.
#
#  The dispatcher sets its own PATH, so a fake cannot be reached by prepending
#  a directory. run_ks exports shell FUNCTIONS, which bash resolves first.
#
#  usage:  ./tests/sim/sync/run-sim-sync.sh          every scenario
#          ./tests/sim/sync/run-sim-sync.sh 7        scenario 7 only
#          KEEP=1 ./tests/sim/sync/run-sim-sync.sh 7 keep the sandbox
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
KS="${KS:-$ROOT/ketsync}"

if [[ ! -f "$KS" ]]; then
  echo "ketsync not found: $KS" >&2; exit 2
elif [[ ! -x "$KS" ]]; then
  echo "ketsync is not executable: $KS" >&2
  echo "  every scenario would die with exit 126. fix it with:  chmod +x $KS" >&2
  exit 2
fi
ONLY="${1:-}"
PASS=0; FAIL=0; FAILED_NAMES=()

ME=10.100.1.17          # this machine, the storage node, the master
BKP=10.100.1.9          # the backup node
C1=10.100.1.32          # a compute node
C2=10.100.1.33          # a second one

# ---------- sandbox ----------
new_world(){
  SIMROOT="$(mktemp -d /tmp/kssync-sim.XXXXXX)"
  export SIMROOT SIMLIB="$HERE/lib.sh"
  MASTER="$SIMROOT/master"
  : > "$SIMROOT/violations"; : > "$SIMROOT/trace"

  # A whole ketsync install, because cmd_sync is sourced by the dispatcher and
  # the dispatcher is what sets KS_BASE.
  mkdir -p "$MASTER/lib" "$MASTER/engines/tp" "$MASTER/logs"
  # lib/ comes from beside the DISPATCHER, not from the repo. cmd_sync.sh is
  # sourced rather than executed, so the mutation suite hands this an otherwise
  # untouched ketsync tree with one file swapped - and taking lib/ from $ROOT
  # would quietly load the good copy and report every mutation as survived.
  local ksdir; ksdir="$(cd "$(dirname "$KS")" && pwd)"
  cp "$KS" "$MASTER/ketsync"; chmod +x "$MASTER/ketsync"
  cp "$ksdir"/lib/*.sh "$MASTER/lib/"

  cat > "$MASTER/ketsync.conf" <<CONF
KS_ROLE=master
KS_MASTER_IP=$ME
CONF
  table "$MASTER/nodes.tsv" 1 \
    "$ME	storage" "$BKP	backup" "$C1	compute" "$C2	compute"
  table "$MASTER/fleet.tsv" 1 "300	gold	$ME	$C1	local-lvm"
  table "$MASTER/engines/tp/inventory-replica.tsv" 1 "110	hdd" "120	hdd"
  table "$MASTER/engines/tp/inventory-migrate.tsv"  1 "251	tank-hdd-nas"

  # Three other machines. The backup node has an install at the SAME absolute
  # path; that is the case everything used to assume was universal.
  add_host "$BKP" same
  add_host "$C1"  none
  add_host "$C2"  none
}

# $1 = file, $2 = generation, rest = rows
table(){
  local f="$1" gen="$2"; shift 2
  { printf '# generation: %s\n' "$gen"; printf '%s\n' "$@"; } > "$f"
}

# $1 = ip, $2 = same | elsewhere | none
#   same       an install at the master's own absolute path
#   elsewhere  an install, but at a different path - the real fleet
#   none       no ketsync at all, which is every compute node
# Calling it again REPLACES that machine's filesystem, so a scenario can say
# "this one keeps its clone somewhere else" without inheriting the install
# new_world already gave it. Call it before remote_table, not after.
add_host(){
  local d; d="$(host_dir_local "$1")"
  rm -rf "$d/fs"; mkdir -p "$d/fs"
  case "$2" in
    same)      mkdir -p "$d/fs$MASTER/engines/tp"
               # The dispatcher itself, because "is there a ketsync here" is
               # what the master asks - an empty directory of the right name is
               # not an install and must not read as one.
               : > "$d/fs$MASTER/ketsync";;
    elsewhere) mkdir -p "$d/fs/root/elsewhere/ketsync/engines/tp"
               : > "$d/fs/root/elsewhere/ketsync/ketsync";;
    none)      : ;;
  esac
}
host_dir_local(){ printf '%s/hosts/%s' "$SIMROOT" "$1"; }
host_down(){ : > "$(host_dir_local "$1")/.down"; }

# What a machine is holding, so a scenario can set up a real disagreement.
remote_table(){  # ip path-under-base generation rows...
  local ip="$1" rel="$2" gen="$3" f; shift 3
  f="$(host_dir_local "$ip")/fs$MASTER/$rel"
  mkdir -p "$(dirname "$f")"
  table "$f" "$gen" "$@"
}
remote_file(){ printf '%s\n' "$(host_dir_local "$1")/fs$MASTER/$2"; }

conf_set(){ { grep -v "^$1=" "$MASTER/ketsync.conf" || true; } > "$MASTER/.c"
            mv -f "$MASTER/.c" "$MASTER/ketsync.conf"
            printf '%s=%s\n' "$1" "$2" >> "$MASTER/ketsync.conf"; return 0; }

# ---------- running it ----------
run_ks(){
  ( export SIMROOT SIMLIB SIMBIN="$HERE/bin"
    # PATH cannot reach a dispatcher that sets its own; exported functions can.
    # The function bodies are re-parsed by the child bash, so everything they
    # name has to be in its ENVIRONMENT - a shell variable of this script is
    # not, and under set -u the dispatcher dies on the first ssh with a message
    # about an unbound variable rather than anything to do with sync.
    ssh(){   "$SIMBIN/ssh"   "$@"; }
    rsync(){ "$SIMBIN/rsync" "$@"; }
    export -f ssh rsync
    "$MASTER/ketsync" "$@" ) > "$SIMROOT/out" 2>&1
  RC=$?
  OUT="$(cat "$SIMROOT/out")"
  TRACE="$(cat "$SIMROOT/trace")"
  VIO="$(cat "$SIMROOT/violations")"
}

# ---------- assertions ----------
_err(){ echo "      x $*"; SCEN_OK=0; }
has(){    grep -qF -- "$1" <<<"$OUT" || _err "expected in output: $1"; }
hasnt(){  grep -qF -- "$1" <<<"$OUT" && _err "should NOT be in output: $1"; return 0; }
rc_is(){  [[ "$RC" == "$1" ]] || _err "exit code $RC, expected $1"; }
traced(){   grep -qF -- "$1" <<<"$TRACE" || _err "expected to run: $1"; }
untraced(){ grep -qF -- "$1" <<<"$TRACE" && _err "must NOT have run: $1"; return 0; }
clean(){ [[ -z "$VIO" ]] || { _err "INVARIANT BROKEN:"; sed 's/^/         /' <<<"$VIO"; }; return 0; }

# What actually arrived, which is the only thing that matters.
arrived(){   # ip rel expected-generation
  local f; f="$(remote_file "$1" "$2")"
  [[ -f "$f" ]] || { _err "$1 never received $2"; return 0; }
  local g; g="$(sed -n 's/^#[[:space:]]*generation:[[:space:]]*\([0-9]*\).*/\1/p' "$f" | head -1)"
  [[ "$g" == "$3" ]] || _err "$1 holds $2 at generation ${g:-none}, expected $3"
  return 0
}
same_as_master(){  # ip rel
  local f; f="$(remote_file "$1" "$2")"
  cmp -s "$MASTER/$2" "$f" || _err "$1's $2 does not match the master's"
  return 0
}
# grep -E rather than -F: this is about the SHAPE of a line, not its content.
line_matches(){ grep -qE -- "$1" <<<"$OUT" || _err "no line matching: $1"; return 0; }
not_arrived(){ # ip rel
  [[ -f "$(remote_file "$1" "$2")" ]] && _err "$1 received $2 and should not have"
  return 0
}

# ---------- harness ----------
scenario(){
  N="${1%%:*}"
  [[ -n "$ONLY" && "$ONLY" != "$N" ]] && return 1
  echo "  [$1]"
  SCEN_OK=1
  new_world
  return 0
}
done_scenario(){
  if (( SCEN_OK )); then PASS=$((PASS+1)); echo "      ok"
  else FAIL=$((FAIL+1)); FAILED_NAMES+=("$N"); echo "      sandbox: $SIMROOT"; fi
  [[ -n "${KEEP:-}" ]] || { (( SCEN_OK )) && rm -rf "$SIMROOT"; }
}

echo "=== ketsync sync simulator ==="

# ---------- who is allowed to push ------------------------------------------

if scenario "1: the master pushes every fleet-wide table to a node that has one"; then
  run_ks sync
  rc_is 0; clean
  arrived "$BKP" nodes.tsv 1
  arrived "$BKP" fleet.tsv 1
  arrived "$BKP" engines/tp/inventory-replica.tsv 1
  same_as_master "$BKP" engines/tp/inventory-replica.tsv
  done_scenario
fi

if scenario "2: a slave refuses to push at all - one writer, always"; then
  conf_set KS_ROLE slave
  run_ks sync
  rc_is 2; clean
  has "only the master pushes"
  untraced "rsync"
  done_scenario
fi

if scenario "3: --dry-run says what would go and sends nothing"; then
  remote_table "$BKP" nodes.tsv 0 "old"
  run_ks sync --dry-run
  rc_is 0; clean
  has "would go from generation 0 to 1"
  untraced "rsync"
  done_scenario
fi

# ---------- the per-machine files -------------------------------------------
# This is the one that was live in the repo: ketsync.conf carries KS_ROLE, and
# pushing the master's copy makes every node believe it is the master.

if scenario "4: ketsync.conf is never sent, whatever else goes"; then
  run_ks sync
  rc_is 0; clean
  not_arrived "$BKP" ketsync.conf
  untraced "ketsync.conf"
  done_scenario
fi

# ---------- generation is an order, and it only orders ONE line -------------

if scenario "5: a node already holding this generation is left alone"; then
  remote_table "$BKP" nodes.tsv 1 "$ME	storage" "$BKP	backup" "$C1	compute" "$C2	compute"
  run_ks sync
  rc_is 0; clean
  has "already at generation 1"
  done_scenario
fi

if scenario "6: a node holding a NEWER generation is refused, not overwritten"; then
  remote_table "$BKP" fleet.tsv 9 "300	gold	$ME	$C1	local-lvm"
  run_ks sync
  rc_is 1; clean
  has "REFUSED: it has generation 9, we have 1"
  arrived "$BKP" fleet.tsv 9
  done_scenario
fi

# ---------- the fork this fleet is actually in ------------------------------
# Two machines, both saying generation 1, holding different content. Equal
# generations were treated as "identical" and the push was skipped, so the
# disagreement survived every sync and the log said everything was fine.

if scenario "7: equal generation but different content is a FORK, and it stops"; then
  remote_table "$BKP" engines/tp/inventory-replica.tsv 1 "110	hdd" "120	hdd" "130	hdd" "140	hdd"
  run_ks sync
  rc_is 1; clean
  has "FORKED"
  has "engines/tp/inventory-replica.tsv"
  # Nothing is chosen for the operator. The slave still holds what it held.
  arrived "$BKP" engines/tp/inventory-replica.tsv 1
  done_scenario
fi

if scenario "8: the fork message says how to see it and how to settle it"; then
  remote_table "$BKP" fleet.tsv 1 "301	gold	$ME	$C2	local-zfs"
  run_ks sync
  rc_is 1
  has "ketsync sync --diff"
  has "--bump"
  done_scenario
fi

if scenario "9: --diff shows what differs and writes nothing at all"; then
  remote_table "$BKP" engines/tp/inventory-replica.tsv 1 "110	hdd" "999	ssd"
  run_ks sync --diff
  rc_is 1; clean
  has "999"
  untraced "rsync"
  done_scenario
fi

if scenario "10: --bump raises this machine's generation so the push is legal"; then
  remote_table "$BKP" engines/tp/inventory-replica.tsv 1 "110	hdd" "999	ssd"
  run_ks sync --bump
  rc_is 0; clean
  # The master's own copy went up, and only the forked file moved.
  has "generation 1 -> 2"
  arrived "$BKP" engines/tp/inventory-replica.tsv 2
  same_as_master "$BKP" engines/tp/inventory-replica.tsv
  done_scenario
fi

if scenario "10b: --bump raises past every machine, not just past this one"; then
  # Two machines that can receive, disagreeing in different ways: one forked at
  # our own generation, one simply ahead of us. Raising by one would settle the
  # first and be refused by the second, which is a half-finished sync that
  # looks finished. --bump means "my copy is the one", so it has to end up
  # above everybody.
  add_host "$C1" same
  remote_table "$BKP" fleet.tsv 1 "301	gold	$ME	$C2	local-zfs"
  remote_table "$C1"  fleet.tsv 5 "302	gold	$ME	$C2	local-zfs"
  run_ks sync --bump
  rc_is 0; clean
  has "generation 1 -> 6"
  arrived "$BKP" fleet.tsv 6
  arrived "$C1"  fleet.tsv 6
  same_as_master "$BKP" fleet.tsv
  done_scenario
fi

if scenario "10c: --bump <file> settles that one and leaves the other forked"; then
  # The ordinary shape of a real fork: both inventories disagree at once. One
  # command deciding both is how the file nobody read gets overwritten, so
  # naming one settles one - and the run still says it is not finished.
  remote_table "$BKP" engines/tp/inventory-replica.tsv 1 "110	hdd" "999	ssd"
  remote_table "$BKP" engines/tp/inventory-migrate.tsv 1 "888	tank-hdd-nas"
  run_ks sync --bump engines/tp/inventory-replica.tsv
  rc_is 1; clean
  arrived "$BKP" engines/tp/inventory-replica.tsv 2
  same_as_master "$BKP" engines/tp/inventory-replica.tsv
  # untouched: still theirs, still generation 1
  arrived "$BKP" engines/tp/inventory-migrate.tsv 1
  has "inventory-migrate.tsv is still FORKED"
  done_scenario
fi

if scenario "10d: --bump on a file that has not forked refuses"; then
  remote_table "$BKP" engines/tp/inventory-replica.tsv 1 "110	hdd" "999	ssd"
  run_ks sync --bump fleet.tsv
  rc_is 2; clean
  has "fleet.tsv has not forked"
  untraced "rsync"
  done_scenario
fi

if scenario "10e: --bump on a file that is not synced at all refuses"; then
  run_ks sync --bump ketsync.conf
  rc_is 2; clean
  # The specific refusal matters: "not one of the synced files" and "has not
  # forked" both exit 2, and only the first one is true here. A run that gives
  # the wrong reason sends the reader to look at the wrong thing.
  has "is not one of the synced files"
  untraced "rsync"
  done_scenario
fi

if scenario "9b: the diff body carries no timestamp - it has to be readable"; then
  # A timestamp in front of every line of a diff makes it unreadable, and a
  # diff nobody can read is the same as not having printed one. The log copy
  # still carries the time.
  remote_table "$BKP" fleet.tsv 1 "301	gold	$ME	$C2	local-zfs"
  run_ks sync --diff
  rc_is 1; clean
  line_matches '^    [<>] '
  done_scenario
fi

# ---------- where the other machine keeps its install -----------------------
# Every node in this fleet has ketsync at a different absolute path. Pushing to
# our own path on their machine writes nothing and says nothing.

if scenario "11: a node whose install is somewhere else is named, not silently missed"; then
  add_host "$BKP" elsewhere
  run_ks sync
  rc_is 1; clean
  has "$BKP"
  has "has no ketsync at"
  not_arrived "$BKP" nodes.tsv
  done_scenario
fi

if scenario "12: a compute node with no ketsync at all is skipped, not an error"; then
  # Nothing is installed on a compute node and nothing should be. It is not a
  # fault, and reporting it as one trains people to ignore the exit code.
  run_ks sync
  rc_is 0; clean
  has "$C1"
  has "nothing installed"
  untraced "rsync $MASTER/nodes.tsv -> root@$C1"
  done_scenario
fi

# ---------- the machine that is not there -----------------------------------

if scenario "13: an unreachable node is reported and the rest still go"; then
  host_down "$BKP"
  run_ks sync
  rc_is 1; clean
  has "UNREACHABLE"
  untraced "rsync"
  done_scenario
fi

if scenario "14: --to sends to one machine only"; then
  run_ks sync --to "$BKP"
  rc_is 0; clean
  arrived "$BKP" nodes.tsv 1
  done_scenario
fi

if scenario "15: --to a machine with no row in nodes.tsv is refused"; then
  run_ks sync --to 10.100.9.99
  rc_is 2; clean
  untraced "rsync"
  done_scenario
fi

# ---------- a table nobody can order ----------------------------------------

if scenario "16: a table with no generation line stops the whole run"; then
  printf '110\thdd\n' > "$MASTER/engines/tp/inventory-replica.tsv"
  run_ks sync
  rc_is 2; clean
  has "no '# generation: N' line"
  untraced "rsync"
  done_scenario
fi

echo
echo "=== $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then echo "failed: ${FAILED_NAMES[*]}"; exit 1; fi
exit 0
