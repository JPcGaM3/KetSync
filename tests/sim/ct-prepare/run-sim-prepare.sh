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
ENGINE="${ENGINE:-$ROOT/engines/ct-prepare.sh}"

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
  SIM_MOCK_BRIDGE=vmbr99
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
  { printf '#!/usr/bin/env bash\n'
    printf 'echo $$ > "%s/engine.pid"\n' "$SIMROOT"
    printf 'exec "%s/ct-prepare.sh" "$@"\n' "$WORK"
  } > "$SIMROOT/run-engine.sh"; chmod +x "$SIMROOT/run-engine.sh"
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
# An operator pressing Ctrl-C, delivered for real at the first `pct shutdown`.
interrupt_at_shutdown(){ : > "$SIMROOT/.interrupt"; }
# ssh itself failing on the shutdown - the connection, not the container. 255
# is what ssh exits with, and it is the code an interrupted connection leaves
# behind too.
ct_ssh_dies(){ : > "$(node_d "$2")/ct/$1.sshdies"; }
# pct dying on a node that answered. It exits 255 too - it is perl - so this
# and ct_ssh_dies produce the SAME NUMBER from opposite ends of the run, and
# the pair of them is the only way to prove the engine tells them apart.
ct_pct_fails(){ : > "$(node_d "$2")/ct/$1.pctfails"; }
# pct never answering at all: the outer timeout kills it and leaves 124 with
# no words - a third shape, distinct from both of the above.
ct_pct_hangs(){ : > "$(node_d "$2")/ct/$1.pcthangs"; }
# A storage that is a plain directory on the node, not a mount. Its stat
# answers without the path being in /proc/mounts, and that is HEALTHY - the
# case that keeps the verdict from condemning everything unmounted.
storage_is_dir(){ printf 'dir\n' > "$(node_d "$1")/storage/$2.type"; }
# ...unless the storage declared is_mountpoint, which is PVE's way of saying
# "this dir is only real when something is mounted on it".
storage_declares_mountpoint(){ printf '1\n' > "$(node_d "$1")/storage/$2.ismp"; }
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
evac_has(){ grep -qP -- "^$2$" "$(evac_f "$1")" 2>/dev/null \
              || _err "the evacuate record for $1 lacks '$2'"; }
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

# What ct-failback.sh leaves behind on the machine that ran it. --cleanup reads
# it as the proof that the production image holds the newest data, so the shape
# matters: it is the engine's real state file, one JSON object per line.
failback_state(){ # ctid mode status
  mkdir -p "$WORK/state"
  printf '{\n  "ctid": %s,\n  "last": {"ts":"2026-01-01T00:00:00+0700","mode":"%s","status":"%s","rc":0}\n}\n' \
    "$1" "$2" "$3" > "$WORK/state/failback-$1.json"; }
no_failback_state(){ rm -f "$WORK/state/failback-$1.json"; }
ct_gone_from(){ [[ -f "$PVE/nodes/$2/lxc/$1.conf" ]] && _err "CT $1 should no longer exist on $2"; return 0; }
ct_there(){     [[ -f "$PVE/nodes/$2/lxc/$1.conf" ]] || _err "CT $1 should still exist on $2"; return 0; }

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
            # The fake needs to know which bridge is the isolated one: its rule
            # about a live storage is "do not move a serving container ONTO it",
            # and a rule that assumed vmbr99 would stop meaning anything the day
            # a scenario changed the name.
            [[ "$1" == MOCKNET_BRIDGE ]] && SIM_MOCK_BRIDGE="$2"
            printf '%s=%s\n' "$1" "$2" >> "$WORK/ctrep.conf"; return 0; }
write_nodemap(){ printf '# ip\tpve node name\n%s\tpve01\n%s\tpve02\n' "$N1" "$N2" > "$WORK/nodes.map"; }
inventory(){ printf '%s\n' "$@" > "$WORK/inventory-replica.tsv"; }
no_inventory(){ rm -f "$WORK/inventory-replica.tsv"; }

run_engine(){
  ( export SIMROOT SIMLIB SIMBIN SIM_BKP_HOST SIMWORK="$WORK" SIM_MOCK_BRIDGE
    SIM_DRY=0
    for _a in "$@"; do [[ "$_a" == --dry-run ]] && SIM_DRY=1; done
    export SIM_DRY
    # The engine owns its PATH (rule 8), so a directory cannot be prepended.
    # An exported function is resolved before PATH and survives the exec.
    ssh(){ "$SIMBIN/ssh" "$@"; }
    export -f ssh
    # Through a wrapper that records its own pid and then EXECS the engine, so
    # the number in engine.pid is the engine's. One scenario sends it a real
    # SIGINT, and from inside a command substitution the fake cannot tell the
    # engine from the subshell that called it - they share a command line.
    # Backgrounding it would have been easier and would have proved nothing: a
    # shell without job control sets SIGINT to ignore for background commands,
    # and a signal that is ignored on entry cannot be trapped at all.
    "$SIMROOT/run-engine.sh" "$@" ) > "$SIMROOT/out" 2>&1
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
  # The stat on an unmounted path ANSWERS - instantly, rc 0, because `umount`
  # leaves PVE's mountpoint directory behind on the node's root filesystem.
  # Only /proc/mounts knows the difference, and for one drill the engine did
  # not ask it: it read its own unmount back as a storage that had recovered,
  # and refused the isolation the unmount was for.
  storage pve01 tank-hdd-nas gone
  run_engine --isolate --ctid 300
  rc_is 0; clean
  has "is gone"
  has "mounted=0"
  cfg_net pve01 300 net0 vmbr99
  done_scenario
fi

if scenario "4b: a mount that errors instead of blocking is gone, not alive"; then
  # ESTALE: the path is still IN the mount table and stat fails at once
  # instead of hanging - an export rebuilt underneath its clients. I/O errors
  # rather than blocks, so everything this engine wants to do works, and
  # refusing it as \"answered\" would be wrong in the same direction as the
  # unmounted case.
  storage pve01 tank-hdd-nas stale
  run_engine --isolate --ctid 300
  rc_is 0; clean
  has "is gone"
  has "stat rc=1, mounted=1"
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

if scenario "10d: isolate asks it to stop once the dead mount is out of the way"; then
  # Off the wire is not the end of it: an isolated container is still a pending
  # writer, blocked only because its storage is gone and writing again the
  # instant it comes back. So isolate stops it - but only when stopping can
  # work at all, which is once the mount is no longer there. `gone` is exactly
  # that: something already unmounted it.
  storage pve01 tank-hdd-nas gone
  run_engine --isolate --ctid 300
  rc_is 0; clean
  has "ISOLATED: net0 now on vmbr99"
  has "STOPPED on pve01"
  ct_status_is 300 pve01 stopped
  traced "pct shutdown 300"
  done_scenario
fi

if scenario "10e: a dead mount that is still there is not something --ctid may unmount"; then
  # `pct shutdown` here would hang until the timeout and change nothing: the
  # container's processes are in uninterruptible sleep on a mount that is still
  # present. Freeing them means unmounting it, which every container on that
  # storage feels - so a run that named ONE container says which command does
  # that instead of doing it.
  run_engine --isolate --ctid 300
  rc_is 0; clean
  has "ISOLATED: net0 now on vmbr99"
  has "ketsync evacuate --node 10.100.1.32"
  hasnt "STOPPED on pve01"
  untraced "pct shutdown"
  ct_status_is 300 pve01 running
  done_scenario
fi

if scenario "10f: a container that will not come down stays isolated, never forced"; then
  storage pve01 tank-hdd-nas gone
  ct_stubborn 300 pve01
  run_engine --isolate --ctid 300
  rc_is 0; clean
  # lxc-stop's failure line carries the timeout it was GIVEN, and 180 in it is
  # the proof the engine's budget reached the process doing the waiting - pct's
  # own default is sixty, and for one drill the engine stood ready to wait
  # three minutes while lxc-stop had already given up at one.
  has "pct: command 'lxc-stop -n 300 --nokill --timeout 10' failed: exit code 1"
  has "pct itself failed (rc=255) and CT 300 is still running - it stays isolated"
  has "nothing here forces a stop"
  ct_status_is 300 pve01 running
  done_scenario
fi

if scenario "10f2: a pct that never returns is not a guest that refused"; then
  # 124 is the OUTER timeout's code: pct was killed still waiting, having said
  # nothing - not even its own failure. A guest refusing arrives as pct's 255
  # with lxc-stop's words attached; the two must not share a message.
  storage pve01 tank-hdd-nas gone
  ct_pct_hangs 300 pve01
  run_engine --isolate --ctid 300
  rc_is 0; clean
  has "pct itself never returned (rc=124) - it stays isolated"
  hasnt "pct itself failed"
  hasnt "ssh to pve01 FAILED"
  ct_status_is 300 pve01 running
  done_scenario
fi

if scenario "10h: pct dying is not the node failing, even where it costs nothing"; then
  # The same 255 collision as 51c, on the path where the container is already
  # off the wire and there is no fallback left to skip. Nothing here changes
  # what the engine DOES - which is exactly why it is worth a scenario: the
  # only thing at stake is whether the log sends somebody to the container or
  # to the connection, and a message nobody checks is a message that rots.
  storage pve01 tank-hdd-nas gone
  ct_pct_fails 300 pve01
  run_engine --isolate --ctid 300
  rc_is 0; clean
  has "pct: command 'lxc-stop -n 300 --nokill --timeout 10' failed: exit code 1"
  has "pct: container did not stop"
  has "pct itself failed (rc=255) and CT 300 is still running - it stays isolated"
  hasnt "ssh to pve01 FAILED"
  hasnt "never returned"
  ct_status_is 300 pve01 running
  done_scenario
fi

if scenario "10i: an ssh that failed after the isolate says so, and says whose"; then
  # The container IS isolated - that happened before the stop was attempted -
  # so this run is a success with one thing unfinished, and what is unfinished
  # is a node that stopped answering. Blaming CT 300 hides that entirely.
  storage pve01 tank-hdd-nas gone
  ct_ssh_dies 300 pve01
  run_engine --isolate --ctid 300
  rc_is 0; clean
  has "ssh to pve01 FAILED while asking it to stop - not CT 300"
  has "not even the exit code the command was told to print"
  hasnt "did not come down within"
  hasnt "pct itself failed"
  cfg_net pve01 300 net0 vmbr99
  done_scenario
fi

if scenario "10k: a directory storage that answers is alive, mounted or not"; then
  # A dir storage's path is just a directory on the node - it is never in
  # /proc/mounts, and that is its healthy state. The verdict must not read
  # "absent from the mount table" as dead for a storage that was never a
  # mount, or every healthy local-path storage on the fleet gets its
  # containers isolated off the air.
  add_ct 340 pve01 backup-dir
  storage pve01 backup-dir alive /var/lib/backup-dir
  storage_is_dir pve01 backup-dir
  inventory "340	replica-hdd"
  run_engine --isolate --ctid 340
  rc_is 1; clean
  has "GUARD P2: storage 'backup-dir' on pve01 ANSWERED"
  cfg_net pve01 340 net0 vmbr0
  done_scenario
fi

if scenario "10l: a dir that declared is_mountpoint is only real when mounted"; then
  # is_mountpoint is PVE's own way of saying "this path is a mount or it is
  # nothing" - the same declaration G1 honours in ct-migrate. When the backing
  # mount is out of the table, the instant answer from the leftover directory
  # is the same lie the 2026-08-15 drill hit, wearing a dir-type storage.
  add_ct 340 pve01 nas-dir
  storage pve01 nas-dir gone /srv/nas-dir
  storage_is_dir pve01 nas-dir
  storage_declares_mountpoint pve01 nas-dir
  inventory "340	replica-hdd"
  run_engine --isolate --ctid 340
  rc_is 0; clean
  has "P2: storage 'nas-dir' is gone"
  has "ISOLATED: net0 now on vmbr99"
  cfg_net pve01 340 net0 vmbr99
  done_scenario
fi

if scenario "10g: a dry isolate does not stop anything either"; then
  storage pve01 tank-hdd-nas gone
  run_engine --isolate --ctid 300 --dry-run
  rc_is 0; clean
  has "DRY: would ask it to stop"
  untraced "pct shutdown"
  ct_status_is 300 pve01 running
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
  # The 180 in lxc-stop's line is the engine's budget arriving where the
  # waiting happens - see 10f. And the sentence after it names the way this
  # ends without anyone forcing it: the blocked I/O erroring out.
  has "pct: command 'lxc-stop -n 300 --nokill --timeout 10' failed: exit code 1"
  has "pct itself failed (rc=255) and CT 300 is still running - isolating it instead"
  has "and 'pct stop', which kills rather"
  has "nothing here forces a stop"
  cfg_net pve01 300 net0 vmbr99
  rec_there 300
  done_scenario
fi

if scenario "39b: a pct that never returns is isolated too, and blamed correctly"; then
  # Same fact as 10f2, on the path where it matters more: evacuate is the
  # fleet-wide pass, and a wrong sentence here sends somebody to a guest when
  # the thing that broke was pct on that node.
  ct_pct_hangs 300 pve01
  run_engine --evacuate --node "$N1"
  rc_is 0; clean
  has "pct itself never returned (rc=124) - isolating CT 300 instead"
  has "said nothing"
  hasnt "pct itself failed"
  cfg_net pve01 300 net0 vmbr99
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

if scenario "41c: a second evacuate finds its own unmount, and neither lies nor forgets"; then
  # The 2026-08-15 drill, one command later. The first run unmounted the dead
  # storage; a re-run of the same node then reads the empty mountpoint
  # directory left behind - which answers a stat instantly. Three things have
  # to survive that: E2 must still call the storage gone rather than ANSWERED
  # (the lie the drill printed), the unmount step must say there is nothing to
  # unmount rather than warn that the stops may hang, and the record must
  # still name the containers the FIRST run killed mid-write - they are the
  # list --restore reads back for the fsck warning, and this run's own list is
  # empty because they are already down.
  run_engine --evacuate --node "$N1"
  rc_is 0; clean
  ct_status_is 300 pve01 stopped
  run_engine --evacuate --node "$N1"
  rc_is 0; clean
  has "E2: storage 'tank-hdd-nas' is gone here"
  hasnt "which answered"
  has "/mnt/pve/tank-hdd-nas is already out of the namespace - nothing to unmount"
  hasnt "the stops below may hang"
  evac_has pve01 "stopped	300"
  evac_has pve01 "stopped	310"
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

if scenario "43b: the way back names the images that were killed mid-write"; then
  # The containers evacuate stops are not shut down - they are stopped by their
  # own writes failing, which is what forcing a dead mount to fail does. ext4
  # aborts the journal, remounts read-only and records the error in the image,
  # and the NEXT mount says "error recorded from previous mount" and carries on
  # anyway. That is the moment nobody notices, so the tool says it at the one
  # moment somebody is about to start them: when the storage comes back.
  run_engine --evacuate --node "$N1"
  rc_is 0; clean
  storage pve01 tank-hdd-nas alive
  run_engine --restore --node "$N1"
  rc_is 0; clean
  has "RE-ENABLED: tank-hdd-nas on pve01"
  has "killed by I/O errors, not by a shutdown"
  has "300"
  has "e2fsck -fy"
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

if scenario "49b: an interrupt stops the run and says so, rather than blaming the fleet"; then
  # This is what a real Ctrl-C did. `trap cleanup EXIT INT TERM` ran the
  # handler and then CARRIED ON from wherever the signal landed - and almost
  # every remote call here happens inside a command substitution, where SIGINT
  # kills the subshell and leaves the parent reading an empty answer. So one
  # keystroke produced a run that continued, reported "the node did not
  # answer" for every machine it touched afterwards, and left an operator
  # reading a fleet-wide outage that was their own hand.
  interrupt_at_shutdown
  run_engine --evacuate --node "$N1"
  rc_is 130
  has "INTERRUPTED by SIGINT - stopping here"
  has "Nothing after this line was attempted"
  hasnt "did not answer"
  # 310 is the second container on that node. The run must not have reached it.
  untraced "pct shutdown 310"
  done_scenario
fi

if scenario "51b: an ssh that failed is not a container that refused to stop"; then
  # The container was never asked, so "it did not come down within 180s" is a
  # slander on a machine that may be perfectly fine - and it sends somebody to
  # look at the container instead of at the connection. This is what the
  # fleet's first drill printed about CT 120 after an operator interrupted the
  # run and killed its ssh.
  #
  # What proves the connection failed is a SILENCE, not a number: the remote
  # command was told to print its own exit code on its own line, and no line
  # came back, so the shell that would have printed it never ran. See 51c for
  # the other half of the pair.
  ct_ssh_dies 300 pve01
  run_engine --evacuate --node "$N1"
  rc_is 1; clean
  has "ssh to pve01 FAILED while asking it to stop"
  has "not CT 300"
  has "not even the exit code the command was told to print"
  hasnt "did not come down within"
  # The fallback needs the same connection, so it is not attempted - and
  # saying so is the difference between a container nobody isolated and a
  # container somebody thinks was isolated.
  hasnt "isolating it instead"
  done_scenario
fi

if scenario "51c: pct failing is not ssh failing, and the container is isolated"; then
  # The other half of 51b, and the reason this engine stopped reading exit
  # codes on their own. `pct` is perl; a perl program that dies exits 255 -
  # the SAME number ssh uses when it cannot reach the host. This engine read
  # the first as the second on a live drill: it announced that pve01 had not
  # answered, said CT 300 was never asked, and skipped the isolation - while
  # printing pct's own words from that same run three lines above.
  #
  # The container is up, on a node that answers, with a rootfs on a storage
  # that is gone. There is no rung above asking it to stop, so what is left is
  # taking it off the wire - which needs nothing from the dead storage.
  ct_pct_fails 300 pve01
  run_engine --evacuate --node "$N1"
  rc_is 0; clean
  has "pct: command 'lxc-stop -n 300 --nokill --timeout 10' failed: exit code 1"
  has "pct: container did not stop"
  has "pct itself failed (rc=255) and CT 300 is still running - isolating it instead"
  hasnt "ssh to pve01 FAILED"
  hasnt "was never asked"
  # Isolated for real, not merely announced.
  ct_status_is 300 pve01 running
  cfg_net pve01 300 net0 vmbr99
  rec_has 300 net0 vmbr0
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

# ---------------------------------------------------------------------------
# --cleanup: the far end of the disaster. The storage node is back, the
# failback has put the newest data into the production image, and what is left
# standing is a 9<id> holding the address production is about to use again.
#
# The world these scenarios need is the one AFTER the outage: production alive
# and running, a 9<id> on the other node, and the failback's own state file
# saying its last run was a final one that finished.
after_the_outage(){   # [production status]
  storage pve01 tank-hdd-nas alive
  ct_state 300 pve01 "${1:-running}"
  add_ct 9300 pve02 local-lvm
  storage pve02 local-lvm alive
  ct_state 9300 pve02 stopped
  failback_state 300 final ok
}

if scenario "51: cleanup stops the stand-in, takes it off the wire, and keeps it"; then
  # Stopping is reversible with one `pct start`; destroying is not reversible at
  # all. So the 9<id> is kept by default, on a bridge with no uplink so a
  # compute node rebooting cannot put a production address back on the wire.
  after_the_outage
  ct_state 9300 pve02 running
  run_engine --cleanup --ctid 300
  rc_is 0; clean
  has "K2: failback --final finished ok"
  has "cleanup: CT 9300 is stopped on pve02"
  has "moved onto vmbr99"
  has "R13 STILL HOLDS"
  ct_status_is 9300 pve02 stopped
  cfg_net pve02 9300 net0 vmbr99
  onboot_is pve02 9300 0
  ct_there 9300 pve02
  done_scenario
fi

if scenario "52: --destroy removes it, and says what that releases"; then
  after_the_outage
  run_engine --cleanup --ctid 300 --destroy
  rc_is 0; clean
  has "DESTROYED: CT 9300 is gone from pve02"
  has "R13 is released"
  ct_gone_from 9300 pve02
  done_scenario
fi

if scenario "53: GUARD K2 - no failback state at all is not permission"; then
  # This mode puts away the container that has been serving customers, so it
  # asks for proof the data is home. The proof is the failback's own record,
  # written by the machine that ran it - so a missing file means "not here",
  # which is a different answer from "not done" and gets a different message.
  after_the_outage
  no_failback_state 300
  run_engine --cleanup --ctid 300
  rc_is 1; clean
  has "GUARD K2: no failback state for CT 300 on this machine"
  has "the one that holds the production images"
  untraced "pct shutdown"
  untraced "pct destroy"
  done_scenario
fi

if scenario "54: GUARD K2 - a presync is a rehearsal, not a cutover"; then
  # A presync leaves the newest data exactly where it was. Reading "the last
  # failback said ok" without reading WHICH MODE it was is the whole bug this
  # guard is here for.
  after_the_outage
  failback_state 300 presync ok
  run_engine --cleanup --ctid 300
  rc_is 1; clean
  has "was mode='presync' status='ok'"
  has "only a FINAL round that ended ok"
  untraced "pct shutdown"
  done_scenario
fi

if scenario "55: GUARD K2 - a final round that FAILED is not a cutover either"; then
  after_the_outage
  failback_state 300 final failed
  run_engine --cleanup --ctid 300
  rc_is 1; clean
  has "status='failed'"
  untraced "pct shutdown"
  done_scenario
fi

if scenario "56: GUARD K3 - the stand-in is not stopped while production is down"; then
  # CT 9300 is what answers that address at this moment. Stopping it before
  # somebody starts production is an outage caused by the tidy-up, and starting
  # production is a decision with a customer on the other end - never this
  # engine's.
  after_the_outage stopped
  ct_state 9300 pve02 running
  run_engine --cleanup --ctid 300
  rc_is 1; clean
  has "GUARD K3: CT 9300 is RUNNING and production CT 300 is stopped"
  has "pct start 300"
  untraced "pct shutdown"
  ct_status_is 9300 pve02 running
  done_scenario
fi

if scenario "57: cleanup puts the production network back first, out of the record"; then
  # The normal order after a real DR: distribute isolated production on the way
  # in, so it is still on vmbr99 on the way out. Restoring it is part of the
  # same tidy-up, and it happens BEFORE the stand-in is put away - the address
  # has to belong to something at every moment.
  after_the_outage
  ct_nets  300 pve01 vmbr99
  ct_veths 300 pve01 vmbr99
  rec_put  300 pve01 vmbr0
  run_engine --cleanup --ctid 300
  rc_is 0; clean
  has "still has an isolate record - putting its network back first"
  has "RESTORED: net0(vmbr0)"
  cfg_net pve01 300 net0 vmbr0
  rec_none 300
  cfg_net pve02 9300 net0 vmbr99
  done_scenario
fi

if scenario "58: nothing was left behind, and that is an answer rather than a failure"; then
  after_the_outage
  ct_gone 9300 pve02
  run_engine --cleanup --ctid 300
  rc_is 0; clean
  has "no CT 9300 anywhere in the cluster - nothing was left behind"
  done_scenario
fi

if scenario "59: a dry cleanup stops nothing, moves nothing and destroys nothing"; then
  after_the_outage
  ct_state 9300 pve02 running
  run_engine --cleanup --ctid 300 --destroy --dry-run
  rc_is 0; clean
  has "DRY: would stop CT 9300"
  has "DRY: would then destroy CT 9300"
  untraced "pct shutdown"
  untraced "pct set"
  untraced "pct destroy"
  ct_there 9300 pve02
  done_scenario
fi

if scenario "60: --destroy is a flag of --cleanup, not a mode of its own"; then
  run_engine --destroy --ctid 300
  rc_is 2
  has "--destroy is a flag of --cleanup"
  done_scenario
fi

if scenario "61: --cleanup and --isolate are the two ends of one disaster"; then
  run_engine --cleanup --isolate --ctid 300
  rc_is 2
  has "--cleanup is the end of a disaster"
  done_scenario
fi

if scenario "62: --cleanup with no container named is refused"; then
  run_engine --cleanup
  rc_is 2
  has "usage: ct-prepare.sh --cleanup --all | --ctid"
  done_scenario
fi

echo
echo "=== $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then echo "failed: ${FAILED_NAMES[*]}"; exit 1; fi
exit 0
