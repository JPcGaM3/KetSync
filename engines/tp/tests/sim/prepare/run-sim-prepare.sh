#!/usr/bin/env bash
# =============================================================================
#  run-sim-prepare.sh — execute ct-prepare.sh against a fake cluster.
# -----------------------------------------------------------------------------
#  Why this exists: this engine writes to the config of a container that is
#  RUNNING, on a node whose storage has just died, during the worst hour this
#  fleet will have. The mistake it could make is not subtle - run it against a
#  healthy container and you take a customer off the network yourself - so the
#  fake refuses to simulate that rather than letting a scenario decide whether
#  to check for it.
#
#  It also holds one ordering invariant that no log line can prove: the record
#  of which bridge each interface came from must exist BEFORE any bridge is
#  changed. Reverse those two and every scenario still passes, every message
#  still reads correctly, and the fleet loses its only copy of the bridge names
#  the first time a run dies halfway. The fake records a VIOLATION instead.
#
#  A scenario can therefore FAIL two ways: wrong observable behaviour, or a
#  broken invariant. The second is the one that matters.
#
#  usage:  ./tests/sim/prepare/run-sim-prepare.sh          every scenario
#          ./tests/sim/prepare/run-sim-prepare.sh 7        scenario 7 only
#          KEEP=1 ./tests/sim/prepare/run-sim-prepare.sh 7 keep the sandbox
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
ENGINE="${ENGINE:-$ROOT/ct-prepare.sh}"

if [[ ! -f "$ENGINE" ]]; then
  echo "engine not found: $ENGINE" >&2; exit 2
elif [[ ! -x "$ENGINE" ]]; then
  echo "engine is not executable: $ENGINE" >&2
  echo "  every scenario would die with exit 126. fix it with:  chmod +x $ENGINE" >&2
  exit 2
fi
ONLY="${1:-}"
PASS=0; FAIL=0; FAILED_NAMES=()

BKP_HOST=100.100.100.35
N1=10.100.1.32          # a production node
N2=10.100.1.33          # a second one

new_world(){
  SIMROOT="$(mktemp -d /tmp/ctprep-sim.XXXXXX)"
  export SIMROOT SIMLIB="$HERE/lib.sh" SIMBIN="$HERE/bin" SIM_BKP_HOST="$BKP_HOST"
  WORK="$SIMROOT/work"; PVE="$SIMROOT/pve"
  mkdir -p "$WORK/state" "$WORK/logs" "$PVE/nodes" "$PVE/ketsync/isolate" "$SIMROOT/nodes"
  : > "$SIMROOT/violations"; : > "$SIMROOT/trace"

  add_node pve01; add_node pve02

  # Three containers on a node whose NFS storage has died, which is the
  # situation this engine is for. One net line each unless a scenario says
  # otherwise, running, onboot 1 - the normal state of a production container.
  add_ct 300 pve01 tank-hdd-nas
  add_ct 310 pve01 tank-hdd-nas
  add_ct 320 pve02 tank-ssd-nas
  storage pve01 tank-hdd-nas dead
  storage pve02 tank-ssd-nas dead

  ln -s "$ENGINE" "$WORK/ct-prepare.sh"
  write_conf
  write_nodemap
  inventory "300	replica-hdd" "310	replica-hdd" "320	replica-ssd"
}

# ---------- the cluster ----------
# Every node has the two bridges a real one has: a customer bridge with a
# physical port on it, and the isolated bridge with nothing on it.
add_node(){
  mkdir -p "$(node_d "$1")/ct" "$(node_d "$1")/bridges" "$(node_d "$1")/storage" "$PVE/nodes/$1/lxc"
  node_bridge "$1" vmbr0 eno1,nic
  node_bridge "$1" vmbr99
  printf '0\n' > "$(node_d "$1")/dstate"
}
node_d(){ printf '%s/nodes/%s' "$SIMROOT" "$1"; }
node_bridge(){ # node bridge [port,kind[,member,member]]...
  local n="$1" b="$2" p _port _kind _rest; shift 2
  : > "$(node_d "$n")/bridges/$b"
  # An ovsbond has members, and nothing else does: it is one OVS port with no
  # kernel netdev of its own, hiding the NICs that actually reach the wire.
  for p in "$@"; do
    IFS=, read -r _port _kind _rest <<<"$p"
    printf '%s %s %s\n' "$_port" "$_kind" "${_rest:-}" >> "$(node_d "$n")/bridges/$b"
  done; }
node_nobridge(){ rm -f "$(node_d "$1")/bridges/$2"; }
node_down(){ : > "$(node_d "$1")/.down"; }
# A node that writes a config and does not apply it to the running container.
# PVE hotplugs a bridge change; when it does not, the config and the kernel
# disagree and only the kernel is telling the truth.
node_nohotplug(){ : > "$(node_d "$1")/.nohotplug"; }
node_pve_ro(){    : > "$(node_d "$1")/.rowo"; }
node_rec_stuck(){ : > "$(node_d "$1")/.recstuck"; }
# A write that succeeds and stores nothing - which is why it is read back.
node_rec_trunc(){ : > "$(node_d "$1")/.rectrunc"; }
# A container that will not come down even once its dead mount has been forced
# to fail. There is no rung above asking politely, so evacuate isolates it.
ct_stubborn(){ : > "$(node_d "$2")/ct/$1.stubborn"; }
storage_disabled(){ [[ -f "$PVE/storage-$1.disabled" ]] \
  || _err "storage $1 should be disabled cluster-wide"; }
storage_enabled(){  [[ -f "$PVE/storage-$1.disabled" ]] \
  && _err "storage $1 should NOT be disabled"; return 0; }
storage_unmounted(){ [[ -f "$(node_d "$1")/storage/$2.unmounted" ]] \
  || _err "$2 should have been unmounted on $1"; }
storage_mounted(){ [[ -f "$(node_d "$1")/storage/$2.unmounted" ]] \
  && _err "$2 should still be mounted on $1"; return 0; }
ct_status_is(){ local got; got=$(cat "$(node_d "$2")/ct/$1.status" 2>/dev/null)
  [[ "$got" == "$3" ]] || _err "ct$1 on $2 is '$got', expected '$3'"; }
evac_f(){ printf '%s/pve/ketsync/evacuate/%s.tsv' "$SIMROOT" "$1"; }
evac_there(){ [[ -f "$(evac_f "$1")" ]] || _err "there is no evacuate record for $1"; }
evac_none(){  [[ -f "$(evac_f "$1")" ]] && _err "an evacuate record for $1 should NOT exist"; return 0; }
dstate(){ printf '%s\n' "$2" > "$(node_d "$1")/dstate"; }

# alive | dead | gone. The WORD, not a boolean: the engine tells three cases
# apart and a boolean would let two of them collapse unnoticed.
storage(){ # node sid verdict [path]
  printf '%s\n' "$3" > "$(node_d "$1")/storage/$2.verdict"
  printf '%s\n' "${4:-/mnt/pve/$2}" > "$(node_d "$1")/storage/$2.path"; }

add_ct(){ # ctid node rootfs-storage
  local d; d="$(node_d "$2")/ct"
  printf 'arch: amd64\nhostname: ct%s\n' "$1" "$1" > "$PVE/nodes/$2/lxc/$1.conf"
  printf 'running\n' > "$d/$1.status"
  printf '1\n'       > "$d/$1.onboot"
  printf '%s\n' "$3" > "$d/$1.rootsid"
  ct_nets  "$1" "$2" vmbr0
  ct_veths "$1" "$2" vmbr0; }
ct_state(){ printf '%s\n' "$3" > "$(node_d "$2")/ct/$1.status"
            [[ "$3" == running ]] || : > "$(node_d "$2")/ct/$1.veth"; }
ct_onboot(){ printf '%s\n' "$3" > "$(node_d "$2")/ct/$1.onboot"; }
ct_gone(){   rm -f "$PVE/nodes/$2/lxc/$1.conf"; }
# What the CONFIG declares, kept separate from the kernel on purpose.
ct_nets(){ # ctid node bridge...
  local id="$1" n="$2" i=0 b; shift 2
  : > "$(node_d "$n")/ct/$id.nets"
  for b in "$@"; do
    printf 'net%s: name=eth%s,bridge=%s,hwaddr=BC:24:11:00:00:%02d,ip=10.100.2.%s/24\n' \
      "$i" "$i" "$b" "$(( id % 100 ))" "$(( id % 250 ))" >> "$(node_d "$n")/ct/$id.nets"
    i=$(( i + 1 ))
  done; }
# What the KERNEL shows. No arguments means the container has no veth at all.
ct_veths(){ # ctid node bridge...
  local id="$1" n="$2" i=0 b; shift 2
  : > "$(node_d "$n")/ct/$id.veth"
  for b in "$@"; do
    printf 'veth%si%s %s\n' "$id" "$i" "$b" >> "$(node_d "$n")/ct/$id.veth"
    i=$(( i + 1 ))
  done; }
# The same container on an Open vSwitch node - which is what this fleet runs.
# OVS enslaves every port of every bridge to ONE datapath device, ovs-system,
# so the kernel's master is ovs-system for all of them and the bridge lives in
# ovsdb alone. Both facts are written down separately, because the engine has
# to ask two different questions to put them back together.
ct_veths_ovs(){ # ctid node bridge...
  local id="$1" n="$2" i=0 b; shift 2
  : > "$(node_d "$n")/ct/$id.veth"
  for b in "$@"; do
    printf 'veth%si%s ovs-system\n' "$id" "$i" >> "$(node_d "$n")/ct/$id.veth"
    printf 'veth%si%s %s\n' "$id" "$i" "$b"    >> "$(node_d "$n")/ovs"
    i=$(( i + 1 ))
  done; }
# ovsdb cannot answer: ovs-vsctl is not installed, or openvswitch-switch is
# down. The kernel still says ovs-system, and nothing can turn that into a
# bridge name.
node_ovs_mute(){ rm -f "$(node_d "$1")/ovs"; }

rec_f(){ printf '%s/pve/ketsync/isolate/%s.tsv' "$SIMROOT" "$1"; }
rec_put(){ # ctid node bridge-of-net0
  mkdir -p "$PVE/ketsync/isolate"
  printf 'ctid\t%s\nnode\t%s\nwhen\t2026-01-01T00:00:00+0700\nby\thand pid 1\nonboot\t1\nnet0\t%s\n' \
    "$1" "$2" "$3" > "$(rec_f "$1")"; }

write_conf(){
  cat > "$WORK/ctrep.conf" <<EOF
BKP_SSH="root@$BKP_HOST"
BKP_DESTS="replica-hdd:replica-hdd/ct replica-ssd:replica-ssd/ct"
MOCKNET_BRIDGE=vmbr99
STAT_TIMEOUT=5
EOF
}
conf_set(){ { grep -v "^$1=" "$WORK/ctrep.conf" || true; } > "$WORK/.c"
            mv -f "$WORK/.c" "$WORK/ctrep.conf"
            printf '%s=%s\n' "$1" "$2" >> "$WORK/ctrep.conf"; return 0; }
write_nodemap(){ printf '# ip\tpve node name\n%s\tpve01\n%s\tpve02\n' "$N1" "$N2" > "$WORK/nodes.map"; }
inventory(){ printf '%s\n' "$@" > "$WORK/inventory-replica.tsv"; }
no_inventory(){ rm -f "$WORK/inventory-replica.tsv"; }

run_engine(){
  ( export SIMROOT SIMLIB SIMBIN SIM_BKP_HOST SIMWORK="$WORK"
    SIM_DRY=0
    for _a in "$@"; do [[ "$_a" == --dry-run ]] && SIM_DRY=1; done
    export SIM_DRY
    # The engine owns its PATH (rule 8), so a directory cannot be prepended.
    # An exported function is resolved before PATH and survives the exec.
    ssh(){ "$SIMBIN/ssh" "$@"; }
    export -f ssh
    "$WORK/ct-prepare.sh" "$@" ) > "$SIMROOT/out" 2>&1
  RC=$?
  OUT="$(cat "$SIMROOT/out")"
  TRACE="$(cat "$SIMROOT/trace")"
  VIO="$(cat "$SIMROOT/violations")"
}

# ---------- assertions ----------
_err(){ echo "      x $*"; SFAIL=1; }
has(){    grep -qF -- "$1" <<<"$OUT" || _err "expected in log: $1"; }
hasnt(){  grep -qF -- "$1" <<<"$OUT" && _err "should NOT be in log: $1"; return 0; }
traced(){ grep -qF -- "$1" <<<"$TRACE" || _err "command should have run: $1"; }
untraced(){ grep -qF -- "$1" <<<"$TRACE" && _err "command must NOT have run: $1"; return 0; }
rc_is(){ [[ "$RC" == "$1" ]] || _err "exit code $RC, expected $1"; }
clean(){ [[ -z "$VIO" ]] || { _err "INVARIANT BROKEN:"; sed 's/^/         /' <<<"$VIO"; }; return 0; }
cfg_net(){ # node ctid netN bridge
  local got; got=$(sed -n "s/^$3: .*bridge=\([^,]*\).*/\1/p" "$(node_d "$1")/ct/$2.nets" 2>/dev/null)
  [[ "$got" == "$4" ]] || _err "$1 ct$2 $3 config bridge is '${got:-<none>}', expected '$4'"; }
kern_net(){ # node ctid ifN bridge
  local got; got=$(awk -v n="$3" '$1==n{print $2; exit}' "$(node_d "$1")/ct/$2.veth" 2>/dev/null)
  [[ "$got" == "$4" ]] || _err "$1 ct$2 $3 kernel master is '${got:-<none>}', expected '$4'"; }
# Where OVSDB has the interface. On an OVS node this is the only place the
# bridge is written down at all - the kernel master stays ovs-system through
# the move, which is why kern_net cannot answer this question.
ovs_net(){ # node ifN bridge
  local got; got=$(awk -v n="$2" '$1==n{print $2; exit}' "$(node_d "$1")/ovs" 2>/dev/null)
  [[ "$got" == "$3" ]] || _err "$1 $2 is on '${got:-<none>}' in ovsdb, expected '$3'"; }
onboot_is(){ local got; got=$(cat "$(node_d "$1")/ct/$2.onboot" 2>/dev/null)
             [[ "$got" == "$3" ]] || _err "$1 ct$2 onboot is '${got:-<none>}', expected '$3'"; }
rec_has(){ grep -qP -- "^$2\t$3$" "$(rec_f "$1")" 2>/dev/null \
             || _err "the record for $1 lacks '$2 = $3'"; }
rec_there(){ [[ -f "$(rec_f "$1")" ]] || _err "there is no record for CT $1"; }
rec_none(){  [[ -f "$(rec_f "$1")" ]] && _err "a record for CT $1 should NOT exist"; return 0; }
log_lands_here(){
  local g=( "$WORK/logs/prepare"*.log )
  [[ -e "${g[0]}" ]] || _err "no log file under $WORK/logs matching prepare*.log"
  [[ -d "$WORK/../logs" ]] && _err "the engine wrote a logs/ OUTSIDE its own tree"
  return 0
}

SFAIL=0; SNAME=""
scenario(){
  [[ -n "$ONLY" && "$ONLY" != "${1%%:*}" ]] && return 1
  echo "  [$1]"; SFAIL=0; SNAME="${1%%:*}"; new_world; return 0
}
done_scenario(){
  if (( SFAIL )); then FAIL=$((FAIL+1)); FAILED_NAMES+=("$SNAME")
  else echo "      ok"; PASS=$((PASS+1)); fi
  [[ -n "${KEEP:-}" ]] && echo "      sandbox: $SIMROOT" || rm -rf "$SIMROOT"
  return 0
}

echo "=== ct-prepare.sh simulator ==="

if scenario "1: the happy path - a running CT whose storage is gone comes off the wire"; then
  run_engine --isolate --ctid 300
  rc_is 0; clean
  cfg_net  pve01 300 net0 vmbr99
  kern_net pve01 300 veth300i0 vmbr99
  has "ISOLATED"
  has "verified from /sys/class/net"
  log_lands_here
  done_scenario
fi

if scenario "2: the record says where it came from, and what onboot was"; then
  ct_onboot 300 pve01 1
  run_engine --isolate --ctid 300
  rc_is 0; clean
  rec_there 300
  rec_has 300 net0 vmbr0
  rec_has 300 onboot 1
  rec_has 300 node pve01
  done_scenario
fi

if scenario "3: GUARD P2 - a storage that ANSWERED means the container is fine"; then
  # The afternoon this was written, distribute --all was run against a healthy
  # fleet by mistake. Had this isolated on sight, two live customers would have
  # lost their network from one command.
  storage pve01 tank-hdd-nas alive
  run_engine --isolate --ctid 300
  rc_is 1; clean
  has "GUARD P2: storage 'tank-hdd-nas' on pve01 ANSWERED"
  has "this refusal has no override"
  cfg_net  pve01 300 net0 vmbr0
  kern_net pve01 300 veth300i0 vmbr0
  rec_none 300
  done_scenario
fi

if scenario "4: a mountpoint somebody already unmounted counts as gone, not as alive"; then
  storage pve01 tank-hdd-nas gone
  run_engine --isolate --ctid 300
  rc_is 0; clean
  has "is gone"
  cfg_net pve01 300 net0 vmbr99
  done_scenario
fi

if scenario "5: GUARD P3 - a stopped container has nothing to take off the network"; then
  ct_state 300 pve01 stopped
  run_engine --isolate --ctid 300
  rc_is 1; clean
  has "GUARD P3: CT 300 is stopped, not running"
  has "would destroy the only copy of them"
  cfg_net pve01 300 net0 vmbr0
  rec_none 300
  done_scenario
fi

if scenario "6: GUARD P4 - the isolated bridge is not on that node"; then
  node_nobridge pve01 vmbr99
  run_engine --isolate --ctid 300
  rc_is 1; clean
  has "GUARD P4: vmbr99 does not exist on pve01"
  cfg_net pve01 300 net0 vmbr0
  rec_none 300
  done_scenario
fi

if scenario "7: GUARD P4 - a bridge with a physical port on it isolates nothing"; then
  node_bridge pve01 vmbr99 eno2,nic
  run_engine --isolate --ctid 300
  rc_is 1; clean
  has "GUARD P4: vmbr99 on pve01 HAS AN UPLINK"
  has "port 'eno2' reaches a wire"
  cfg_net pve01 300 net0 vmbr0
  done_scenario
fi

if scenario "8: GUARD P5 - a second isolate would overwrite the only record"; then
  rec_put 300 pve01 vmbr0
  run_engine --isolate --ctid 300
  rc_is 1; clean
  has "GUARD P5: CT 300 is already isolated"
  has "nothing left to reconstruct it from"
  has "net0	vmbr0"
  done_scenario
fi

if scenario "9: GUARD P5 - moved onto the isolated bridge by hand, with no record"; then
  ct_nets  300 pve01 vmbr99
  ct_veths 300 pve01 vmbr99
  run_engine --isolate --ctid 300
  rc_is 1; clean
  has "already on vmbr99, with no record"
  has "move it back to the"
  rec_none 300
  done_scenario
fi

if scenario "10: GUARD P6 - a config PVE did not apply is not an isolated container"; then
  # `pct set` writing a config is not the same as PVE hotplugging it onto a
  # running container, and this engine claims to have taken something off the
  # network. So it re-reads the kernel and refuses to say it worked.
  node_nohotplug pve01
  run_engine --isolate --ctid 300
  rc_is 1; clean
  has "GUARD P6: the config was written but the KERNEL still has: veth300i0(vmbr0)"
  has "CT 300 is NOT isolated - do not place its copy"
  hasnt "ISOLATED:"
  done_scenario
fi

if scenario "10b: on an OVS node, isolating is verified against ovsdb"; then
  # This fleet runs Open vSwitch, and OVS enslaves every port of every bridge
  # to ONE datapath device called ovs-system. /sys/class/net/<if>/master names
  # that datapath and never the bridge, so P6 - which re-reads the master and
  # refuses until every interface has moved - could never be satisfied here.
  # It would refuse every container it had just isolated correctly, and
  # ct-distribute's D1 did exactly that on the live fleet.
  ct_veths_ovs 300 pve01 vmbr0
  run_engine --isolate --ctid 300
  rc_is 0; clean
  has "ISOLATED: net0 now on vmbr99"
  hasnt "GUARD P6"
  cfg_net pve01 300 net0 vmbr99
  ovs_net pve01 veth300i0 vmbr99
  # The record has to hold the REAL bridge, or --restore puts the container
  # back onto the datapath device rather than onto the customer's network.
  rec_has 300 net0 vmbr0
  done_scenario
fi

if scenario "10c: GUARD P6 - an OVS node whose ovsdb does not answer is not verified"; then
  # ovs-vsctl missing, or openvswitch-switch down. The kernel says ovs-system,
  # nothing can turn that into a bridge name, and a bridge nobody can name is
  # not one that has been checked. The net lines ARE written by then, so the
  # refusal has to say how to put them back.
  ct_veths_ovs 300 pve01 vmbr0
  node_ovs_mute pve01
  run_engine --isolate --ctid 300
  rc_is 1; clean
  has "GUARD P6: the config was written but the KERNEL still has: veth300i0(ovs-system)"
  has "ovs-system is Open vSwitch's datapath, not a bridge"
  has "put them back with --restore"
  hasnt "ISOLATED:"
  done_scenario
fi

if scenario "7b: GUARD P4 - a bond uplinking the isolated bridge counts, on OVS too"; then
  # An OVS bond is one PORT whose members are the NICs, and it has no kernel
  # netdev of its own. Asking OVS for the bridge's PORTS returns a name with no
  # /device and no /bonding, so vmbr99 reads as isolated while it reaches the
  # customer's wire through two cables. Asking for its IFACES returns the
  # members, which is what the probe does.
  node_bridge pve01 vmbr99 bond0,ovsbond,eno2,eno3
  run_engine --isolate --ctid 300
  rc_is 1; clean
  has "GUARD P4: vmbr99 on pve01 HAS AN UPLINK"
  has "port 'eno2' reaches a wire"
  has "port 'eno3' reaches a wire"
  cfg_net pve01 300 net0 vmbr0
  rec_none 300
  done_scenario
fi

if scenario "11: GUARD P1 - a node that did not answer is not a node to change"; then
  node_down pve01
  run_engine --isolate --ctid 300
  rc_is 1; clean
  has "GUARD P1: pve01 (10.100.1.32) did not answer"
  has "unreachable is not stopped"
  done_scenario
fi

if scenario "12: GUARD P1 - a container with no config anywhere is skipped, not invented"; then
  ct_gone 300 pve01
  run_engine --isolate --ctid 300
  rc_is 1; clean
  has "has no config anywhere in the cluster"
  done_scenario
fi

if scenario "13: every interface moves, not just net0"; then
  ct_nets  300 pve01 vmbr0 vmbr7
  ct_veths 300 pve01 vmbr0 vmbr7
  run_engine --isolate --ctid 300
  rc_is 0; clean
  cfg_net  pve01 300 net0 vmbr99
  cfg_net  pve01 300 net1 vmbr99
  kern_net pve01 300 veth300i0 vmbr99
  kern_net pve01 300 veth300i1 vmbr99
  rec_has 300 net0 vmbr0
  rec_has 300 net1 vmbr7
  done_scenario
fi

if scenario "14: the net line keeps its MAC and its address - only the bridge changes"; then
  run_engine --isolate --ctid 300
  rc_is 0; clean
  grep -q "hwaddr=BC:24:11:00:00:00" "$(node_d pve01)/ct/300.nets" \
    || _err "the MAC did not survive the move"
  grep -q "ip=10.100.2.50/24" "$(node_d pve01)/ct/300.nets" \
    || _err "the address did not survive the move"
  done_scenario
fi

if scenario "15: --dry-run runs every guard and writes nothing at all"; then
  run_engine --isolate --all --dry-run
  rc_is 0; clean
  has "DRY: would write /etc/pve/ketsync/isolate/300.tsv"
  has "DRY: would move net0 onto vmbr99"
  cfg_net  pve01 300 net0 vmbr0
  kern_net pve01 300 veth300i0 vmbr0
  rec_none 300; rec_none 310; rec_none 320
  done_scenario
fi

if scenario "16: --dry-run still refuses what a real run would refuse"; then
  storage pve01 tank-hdd-nas alive
  run_engine --isolate --ctid 300 --dry-run
  rc_is 1; clean
  has "GUARD P2"
  done_scenario
fi

if scenario "17: restore puts the bridge back, and onboot with it"; then
  run_engine --isolate --ctid 300
  rc_is 0; clean
  ct_onboot 300 pve01 0
  run_engine --restore --ctid 300
  rc_is 0; clean
  cfg_net  pve01 300 net0 vmbr0
  kern_net pve01 300 veth300i0 vmbr0
  onboot_is pve01 300 1
  rec_none 300
  has "RESTORED: net0(vmbr0), onboot 1"
  done_scenario
fi

if scenario "18: restore refuses when there is no record to restore from"; then
  ct_nets  300 pve01 vmbr99
  ct_veths 300 pve01 vmbr99
  run_engine --restore --ctid 300
  rc_is 1; clean
  has "no record at /etc/pve/ketsync/isolate/300.tsv"
  has "guessing a bridge puts a customer on the wrong segment"
  cfg_net pve01 300 net0 vmbr99
  done_scenario
fi

if scenario "19: restore of an interface that has since been removed keeps the record"; then
  run_engine --isolate --ctid 300
  rc_is 0; clean
  : > "$(node_d pve01)/ct/300.nets"
  ct_veths 300 pve01
  run_engine --restore --ctid 300
  rc_is 1; clean
  has "is in the record but not in CT 300's config any more"
  rec_there 300
  done_scenario
fi

if scenario "20: restore --dry-run changes nothing and says what it would do"; then
  run_engine --isolate --ctid 300
  rc_is 0; clean
  run_engine --restore --ctid 300 --dry-run
  rc_is 0; clean
  has "DRY: would put net0 back on vmbr0"
  cfg_net pve01 300 net0 vmbr99
  rec_there 300
  done_scenario
fi

if scenario "21: the record is written BEFORE anything moves"; then
  # Not provable from the log, which is why the fake holds it: reverse the two
  # and every message still reads correctly while a run that dies in between
  # loses the bridge names for good.
  run_engine --isolate --ctid 300
  rc_is 0; clean
  rec_there 300
  done_scenario
fi

if scenario "22: a read-only /etc/pve stops the run before anything is moved"; then
  node_pve_ro pve01
  run_engine --isolate --ctid 300
  rc_is 1; clean
  has "could not write /etc/pve/ketsync/isolate/300.tsv"
  has "A cluster without quorum is read-only"
  cfg_net pve01 300 net0 vmbr0
  done_scenario
fi

if scenario "23: --all keeps going past one refusal and reports both kinds"; then
  storage pve02 tank-ssd-nas alive
  run_engine --isolate --all
  rc_is 1; clean
  has "ok=2 skipped=1 failed=0"
  cfg_net pve01 300 net0 vmbr99
  cfg_net pve01 310 net0 vmbr99
  cfg_net pve02 320 net0 vmbr0
  done_scenario
fi

if scenario "24: --ctid for a container with no inventory row is refused"; then
  run_engine --isolate --ctid 999
  rc_is 2
  has "CT 999 has no row in inventory-replica.tsv"
  done_scenario
fi

if scenario "25: a duplicated container in the inventory refuses the whole file"; then
  inventory "300	replica-hdd" "300	replica-ssd"
  run_engine --isolate --all
  rc_is 2
  has "container 300 appears twice"
  untraced "pct set"
  done_scenario
fi

if scenario "26: no inventory at all is a wiring mistake, not an empty workload"; then
  no_inventory
  run_engine --isolate --all
  rc_is 2
  has "no inventory at"
  done_scenario
fi

if scenario "27: no mode is refused with the usage, not taken as a default"; then
  run_engine --ctid 300
  rc_is 2
  has "usage: ct-prepare.sh --list | --isolate | --restore"
  untraced "pct set"
  done_scenario
fi

if scenario "28: --isolate and --restore together is refused, not resolved"; then
  run_engine --isolate --restore --ctid 300
  rc_is 2
  has "opposite directions - pick one"
  done_scenario
fi

if scenario "29: --list reports state and writes nothing"; then
  dstate pve01 7
  run_engine --list
  rc_is 0; clean
  has "LIST: on pve01 (10.100.1.32), running, rootfs storage 'tank-hdd-nas' is dead"
  has "kernel: veth300i0 -> vmbr0"
  has "--isolate would move 1 net line(s) onto vmbr99"
  rec_none 300
  untraced "pct set"
  done_scenario
fi

if scenario "30: --list says when isolate would refuse, before anybody tries it"; then
  storage pve01 tank-hdd-nas alive
  run_engine --list --ctid 300
  rc_is 0; clean
  has "--isolate would REFUSE: that storage answered"
  done_scenario
fi

if scenario "31: --list names a container this tool has already isolated"; then
  run_engine --isolate --ctid 300
  rc_is 0; clean
  run_engine --list --ctid 300
  rc_is 0; clean
  has "ISOLATED by this tool"
  has "net0 was on vmbr0"
  done_scenario
fi

if scenario "32: a container with no net lines is not something to isolate"; then
  ct_nets  300 pve01
  ct_veths 300 pve01
  run_engine --isolate --ctid 300
  rc_is 1; clean
  has "has no net lines at all"
  rec_none 300
  done_scenario
fi

if scenario "33: the record cannot be removed, so the run says so instead of lying"; then
  run_engine --isolate --ctid 300
  rc_is 0; clean
  node_rec_stuck pve01
  run_engine --restore --ctid 300
  rc_is 1; clean
  has "could not remove /etc/pve/ketsync/isolate/300.tsv"
  has "doctor will keep reporting"
  cfg_net pve01 300 net0 vmbr0
  done_scenario
fi

if scenario "34: MOCKNET_BRIDGE that is not an interface name is refused up front"; then
  conf_set MOCKNET_BRIDGE "vmbr99@bad"
  run_engine --isolate --ctid 300
  rc_is 2
  has "is not a plain interface name"
  untraced "pct set"
  done_scenario
fi

if scenario "35: STAT_TIMEOUT of zero would make every storage read as alive"; then
  conf_set STAT_TIMEOUT 0
  run_engine --isolate --ctid 300
  rc_is 2
  has "STAT_TIMEOUT must be at least 1 second"
  done_scenario
fi

if scenario "37: a record that was accepted and stored nothing stops the run"; then
  node_rec_trunc pve01
  run_engine --isolate --ctid 300
  rc_is 1; clean
  has "did not read back as what was sent - NOTHING was moved"
  cfg_net pve01 300 net0 vmbr0
  done_scenario
fi

if scenario "36: vmbr990 is not vmbr99, and a fleet big enough has both"; then
  # The already-moved-by-hand check compares the bridge FIELD, not the text of
  # the line. A substring match reads vmbr990 as vmbr99 and refuses to isolate a
  # container that is plainly still on the wire.
  ct_nets  300 pve01 vmbr990
  ct_veths 300 pve01 vmbr990
  node_bridge pve01 vmbr990
  run_engine --isolate --ctid 300
  rc_is 0; clean
  hasnt "already on vmbr99, with no record"
  cfg_net pve01 300 net0 vmbr99
  rec_has 300 net0 vmbr990
  done_scenario
fi

if scenario "38: evacuate frees the blocked I/O first, then the container stops"; then
  # The order everyone gets backwards. A container whose dead NFS rootfs is
  # still mounted cannot be shut down at all - its processes are in
  # uninterruptible sleep and SIGKILL does not reach them. Unmount first and
  # the same command returns in seconds.
  run_engine --evacuate --node "$N1"
  rc_is 0; clean
  storage_disabled tank-hdd-nas
  storage_unmounted pve01 tank-hdd-nas
  ct_status_is 300 pve01 stopped
  ct_status_is 310 pve01 stopped
  has "STOPPED on pve01"
  traced "systemctl restart pvestatd"
  rec_none 300
  done_scenario
fi

if scenario "39: a container that still will not stop is isolated, never forced"; then
  ct_stubborn 300 pve01
  run_engine --evacuate --node "$N1"
  rc_is 0; clean
  ct_status_is 300 pve01 running
  ct_status_is 310 pve01 stopped
  has "did not come down within 90s"
  has "nothing here forces a stop"
  cfg_net pve01 300 net0 vmbr99
  rec_there 300
  done_scenario
fi

if scenario "40: GUARD E2 - a node whose storage answered is left completely alone"; then
  storage pve01 tank-hdd-nas alive
  run_engine --evacuate --node "$N1"
  rc_is 1; clean
  has "every storage this node's containers use ANSWERED"
  storage_enabled tank-hdd-nas
  storage_mounted pve01 tank-hdd-nas
  ct_status_is 300 pve01 running
  evac_none pve01
  done_scenario
fi

if scenario "41: a healthy storage on the same node keeps its containers running"; then
  # A compute node with one dead NFS storage and one working local one has to
  # come out of this with the local containers still up. This is the collateral
  # damage a node that reboots itself causes, and the reason not to reboot.
  add_ct 330 pve01 local-lvm
  storage pve01 local-lvm alive
  inventory "300	replica-hdd" "310	replica-hdd" "320	replica-ssd" "330	replica-hdd"
  run_engine --evacuate --node "$N1"
  rc_is 0; clean
  has "CT 330 is on 'local-lvm', which answered - left alone"
  storage_enabled local-lvm
  storage_mounted pve01 local-lvm
  ct_status_is 330 pve01 running
  ct_status_is 300 pve01 stopped
  done_scenario
fi

if scenario "42: the record of what was switched off is written before it is"; then
  run_engine --evacuate --node "$N1"
  rc_is 0; clean
  evac_there pve01
  grep -q "disabled	tank-hdd-nas" "$(evac_f pve01)" || _err "the record does not name the storage"
  done_scenario
fi

if scenario "43: restore --node switches the storages back on and clears the record"; then
  run_engine --evacuate --node "$N1"
  rc_is 0; clean
  run_engine --restore --node "$N1"
  rc_is 0; clean
  storage_enabled tank-hdd-nas
  evac_none pve01
  has "RE-ENABLED: tank-hdd-nas on pve01"
  done_scenario
fi

if scenario "44: restore --node refuses a storage this tool never disabled"; then
  run_engine --restore --node "$N1"
  rc_is 1; clean
  has "this tool did not evacuate pve01"
  has "only switches back on what it switched off"
  done_scenario
fi

if scenario "45: evacuate --dry-run touches neither the storage nor the containers"; then
  run_engine --evacuate --node "$N1" --dry-run
  rc_is 0; clean
  has "DRY: would write /etc/pve/ketsync/evacuate/pve01.tsv"
  storage_enabled tank-hdd-nas
  storage_mounted pve01 tank-hdd-nas
  ct_status_is 300 pve01 running
  evac_none pve01
  done_scenario
fi

if scenario "46: evacuate with no node named is refused - it is not a per-CT verb"; then
  run_engine --evacuate --ctid 300
  rc_is 2
  has "evacuating is per NODE"
  untraced "pvesm set"
  done_scenario
fi

if scenario "47: --evacuate and --isolate together is refused, not merged"; then
  run_engine --evacuate --isolate --node "$N1"
  rc_is 2
  has "already isolates what it cannot stop"
  done_scenario
fi

if scenario "48: GUARD E1 - a node with no inventory container is not evacuated"; then
  inventory "320	replica-ssd"
  run_engine --evacuate --node "$N1"
  rc_is 1; clean
  has "no container from the inventory lives on this node"
  storage_enabled tank-hdd-nas
  done_scenario
fi

if scenario "49: evacuate --all does every node that holds one, one at a time"; then
  run_engine --evacuate --all
  rc_is 0; clean
  storage_disabled tank-hdd-nas
  storage_disabled tank-ssd-nas
  ct_status_is 300 pve01 stopped
  ct_status_is 320 pve02 stopped
  done_scenario
fi

if scenario "50: a node that stopped answering mid-run disables nothing"; then
  node_down pve01
  run_engine --evacuate --node "$N1"
  rc_is 1; clean
  has "GUARD E1"
  storage_enabled tank-hdd-nas
  done_scenario
fi

echo
echo "=== $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then echo "failed: ${FAILED_NAMES[*]}"; exit 1; fi
exit 0
