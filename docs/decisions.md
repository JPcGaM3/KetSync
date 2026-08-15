# ketsync — decisions

What this layer is for, what was argued about, and which parts are designed
but not yet built. Written before the code, so the code can be checked
against it.

`ketsync` decides. `tp` moves. Every guard that protects customer data lives in
`tp` and is anchored by its simulators; nothing here duplicates one.

---

## 1. The problem this layer exists for

The fleet has one storage node that every container's disk lives on. When it
dies, three things are true at once: the containers cannot run, the machine
that normally drives replication is the machine that died, and the backup node
holding the copies has nowhere near the CPU and RAM to run all of them.

So the copies have to be spread across the compute nodes, run there, keep being
replicated back to the backup node while they run there, and eventually come
home. That is a placement and coordination problem, not a data-movement one.

## 2. Promotion is a decision, not an election

Two machines cannot distinguish "the master is dead" from "I cannot reach the
master". With two nodes there is no third vote, and the consequence of getting
it wrong here is not a stale read - it is two machines running `rsync --delete`
into the same datasets.

**So there is no failover protocol.** `KS_ROLE` is a line in a config file,
changed by hand, on the machine that is taking over. What is automatic is the
part that is safe: every machine always has a current copy of the config and
the inventory, so any of them *can* take over in seconds.

This is the same rule the rest of the fleet already runs on: cutover and DR
promotion are decisions with customers on the other end, made by somebody
looking at the machine.

### Split-brain is not prevented; it is made survivable

Asked whether the split-brain case could simply be dropped because it is rare.
It can, and the reason is that we do not need to prevent two masters - we need
to make two masters harmless. The dangerous event is not "two machines think
they are in charge", it is "two machines write into the same destination".

**The lock therefore lives on the destination, not on the writer.** Before
anything writes into a copy's dataset, it takes a lock *on the machine holding
that dataset*. Both contenders are then fighting over one file on one machine,
which is atomic and needs no consensus. The loser logs that somebody else owns
that copy and skips.

Split-brain still happens. It just stops costing anything.

### What that is, in the engines

Built, and the same code in all four: `ct-replica.sh` R14, `ct-failback.sh` B8,
`ct-distribute.sh` D8, `ct-recall.sh` C8. This paragraph described a design for
months while every engine took a *local* `flock` instead — replica's keyed on the copy id,
failback's on the production id, distribute's on nothing but the run — which
between two machines settles nothing at all, and on one machine still let
failback read a copy that replica was writing.

    /run/ketsync-ct-<vmid>.lock     on the machine that holds that VMID
                                    8110 -> the backup node
                                    9110 -> the compute node running the copy

Taken with `set -C`, which makes the redirect `O_EXCL`, so the destination's
own kernel picks the winner. The file holds one line — the verb, the machine,
the pid, and when it started — and a run that loses prints it. `/run` because
it is tmpfs: a destination that reboots cannot leave a lock behind, and one
that rebooted has already killed whatever held it.

Three rules that are not obvious from the code:

**An unanswered destination is refused, not treated as free.** It is a separate
return value from "somebody has it" and it has its own message, because that is
the case where carrying on puts two `rsync --delete` into one dataset.

**Nothing ever breaks somebody else's lock, and there is no timeout.** A run
that is SIGKILLed leaves one, and the remedy is a human reading the holder line
and removing the file the refusal names. Deciding from the outside that
somebody else's transfer into a customer's rootfs has finished is the guess the
rest of this repo refuses everywhere else.

**A release removes the file only while it still says it is ours.** If a human
clears what looks like a stale lock while that run is alive, the next run takes
it legitimately — and an unconditional `rm` at the end of the first one would
then delete a lock a live transfer is relying on.

`ct-recall.sh` C8 takes two, and it is the only one that does: 9xxx on the
compute node, then 8xxx on the backup node, in that order. A fixed order is
what keeps it from deadlocking against the other three, each of which takes
exactly one - a cycle needs two engines that each take two.

### The last fallback, and why it is gone

`ctrep.conf` had `DEFAULT_DEST`, and a row in `inventory-replica.tsv` with no
dest column landed on whichever pool it named. That is the same shape as
`fleet.tsv`'s old fallback storage, and it was removed for the same reason: the
row that FORGOT to say where its copy goes looked exactly like the row that
meant it, and what arrives on the wrong pool is a customer's only DR copy.

Every row now names its pool and a row that does not refuses the whole file,
naming the line. Three things followed from that, and all three are
improvements the fallback had been hiding:

`AUTO_DISCOVER` is gone. It replicated every container in the cluster,
including ones with no row, and `DEFAULT_DEST` was the only thing that could
say where those copies went. Without it the mode cannot answer the question at
all, so it refuses rather than choosing.

`ct-failback.sh --ctid` on a container with no row is refused. It used to
derive both numbers - the target from `OFFSET`, the pool from `DEFAULT_DEST` -
and the first is arithmetic while the second was a guess. A container that had
been on the other pool was then looked for on the wrong one, where "not found"
reads as "no copy" rather than "wrong pool".

An unknown word in the dest column stopped being reachable. A field is only
classified as a dest when it IS a key in `BKP_DESTS`, so with no default the
"unknown dest" branch in `ct-recall.sh` could never fire, and it is gone too.

## 3. One writer for the fleet map, ordered by a generation number

What is synced is everything that is **fleet-wide** - the same bytes correct on
every machine: `nodes.tsv`, `fleet.tsv`, and the engines' two inventories,
`engines/tp/inventory-replica.tsv` and `engines/tp/inventory-migrate.tsv`. The
inventories belong here because a machine taking over needs them, and a backup
node holding a stale one replicates the wrong containers.

What is **not** synced is anything per-machine, and `ketsync.conf` is the one
that matters: it carries `KS_ROLE`, and pushing the master's copy sets every
node to `KS_ROLE=master`. Every node then believes it may write - which is
precisely the split brain section 2 is built to avoid, manufactured by the very
command meant to keep everyone consistent. It was live in `cmd_sync.sh` until
somebody read the file list out loud. There is a denylist now, and it stops the
run rather than warning.

`ctrep.conf` and `ctmig.conf` are also excluded, and the reason given here used
to be wrong. It said they mix fleet-wide tuning with per-machine addresses,
because `BKP_SSH` "means the other machine, which is a different machine
depending on who is asking". It does not. `BKP_SSH` is the backup node, for
every engine on every machine, and on the backup node itself it points at
itself. The value is identical fleet-wide.

What actually differs is one line of tuning: `BW_TOTAL_MB`, because the storage
node and the backup node do not have the same link. Everything else in
`ctrep.conf` - `BKP_DESTS`, `OFFSET`, `DR_OFFSET`, `DR_HEADROOM_PCT`,
`LOG_KEEP_DAYS` - is the same everywhere and would be correct to sync.

That matters more than it sounds, because `ct-distribute.sh` reads `ctrep.conf`
and distribute is the thing you run from the backup node during a disaster. As
it stands, that file has to be maintained there by hand, and a fleet-wide
change to `BKP_DESTS` has to be remembered twice. Splitting the file into a synced
part and a per-machine part would reduce "can the backup node take over?" to
one line of `ketsync.conf`. It has not been done.

`fleet.tsv` is deliberately not called an inventory: `engines/tp` already has two
files with that word in the name and entirely different columns, and one word
meaning three things is how somebody edits the wrong table during a DR.
`fleet.tsv` is the map - which container lives where, and where it goes when
its home is gone. tp's inventories are work lists.

Every synced file carries `# generation: N` and the number goes up on every
edit. `ketsync sync` refuses to push a file over a newer one, so a master that
was promoted by mistake and then demoted cannot walk its stale map back over
the fleet.

A generation orders two versions of a file. It does not identify one, and for
a while this command behaved as though it did: equal generations were taken to
mean equal content, and the push was skipped. That is wrong in the one case
that matters most. Every install starts at the generation its `.sample` shipped
with, so two machines both saying "generation 1" and holding different content
is the normal state of a fleet that has never synced - which is exactly the
moment somebody runs this for the first time. sync reported success and the
disagreement survived every run afterwards.

Content is compared now, and equal generations with different content is a
**fork**: the run stops and sends nothing. There is no version to prefer, and
picking one would delete whichever side was right. `ketsync sync --diff` shows
what differs; `ketsync sync --bump` raises this machine's generation above
every other copy and pushes, which is the human saying "mine is the one". That
sentence has to be typed. It is not something a tool can work out.

`sync` writes to other machines, so it is the first command in this layer to
have a simulator: 21 scenarios and 19 mutations, in `tests/`. Writing it found
three bugs that were live on the fleet at the time, including the one above.
None had been caught by reading the file.

A new machine joins by being added to `nodes.tsv`, having ketsync cloned to the
**same absolute path** the rest of the fleet uses, and receiving a sync. The
path is not a style preference: sync pushes to the path it is installed at, so
a clone at `/root/github/KetSync` receiving from a master at
`/root/script/KetSync` gets nothing at all. That used to fail silently; it is
now named, per node, and it raises the exit code. There is no membership
protocol, because with manual promotion there is nothing for one to agree
about.

## 4. VMID numbering, and the two places a container can be

One container has up to three VMIDs, and the digit in front says where you are
looking. It is a policy rather than a mechanism, which is the point: reading
`9300` in a `pct list` tells you immediately that this is a temporary DR copy on
somebody's local disk and not the real thing.

    300     the production container. Its rootfs is a raw image on the storage
            node, mounted over NFS by the compute node that runs it
    8300    the DR copy on the backup node. Written by ct-replica every round,
            stopped, on a bridge with no uplink. OFFSET=8000 in ctrep.conf
    9300    a TEMPORARY copy running on a compute node's own local-lvm, made
            only while the storage node is down. DR_OFFSET=9000

The 9000 tier exists because of what the storage node's death actually breaks:
the images are gone, so the container cannot run where it normally runs, and the
backup node has the data but nowhere near the CPU and RAM to run the fleet. The
data therefore has to move a second time - backup node to a compute node's
*local* disk, which is the one storage in the building that does not depend on
the machine that died.

`local-lvm` specifically, and not a second NFS mount: the whole point is to stop
depending on shared storage for the duration. It is temporary and it is meant to
feel temporary - a 9xxx container is one somebody has to deliberately unwind.

## 4b. `prepare` — built, as `engines/tp/ct-prepare.sh`

Stage 1 of the DR runbook - get the production containers out of the way -
was four or five raw `pvesm`, `umount` and `pct` commands per node, in an
order almost everybody gets wrong. It is `isolate`, `restore` and `evacuate`
now. 72 scenarios, 63 mutations.

**What makes it safe is a proof, not an intention.** P2 and E2 refuse unless
the container's rootfs storage is provably dead, and the proof is not an
inference from "I cannot reach the storage node": it is a `stat` on that
storage's own mountpoint, on the node that mounts it, with a timeout - and a
HANG is the positive result. A live NFS mount answers instantly; one whose
server is gone blocks in the kernel until the timeout kills it. A mountpoint
that is not there any more counts too, because something already unmounted it.
A storage that answers is a hard refusal with no override. `distribute --all`
was run against this fleet while it was healthy, by mistake, the afternoon
this was designed; run against a healthy fleet these modes must do nothing at
all, and that is the property to preserve.

**The order is the whole trick, and it is backwards from instinct.** Disable
the storage, unmount it, restart pvestatd, and only then stop the containers.
A container whose dead NFS rootfs is still mounted cannot be stopped at all -
its processes are in uninterruptible sleep, `pct shutdown` waits for a guest
that cannot answer, and SIGKILL does not reach a task in D state. Unmount
first and the same command returns in seconds. The simulator holds that as a
causal fact rather than a log assertion: `pct shutdown` against a container
whose dead storage is still mounted returns 124 and changes nothing.

**A container that will not stop is isolated, never forced.** Every net line
moves onto `MOCKNET_BRIDGE`, which defends the thing the DR actually cares
about - one address, not one process - and there is no rung above that.

**The record is the only copy of what is being overwritten**, so it is written
first, at `/etc/pve/ketsync/isolate/<ctid>.tsv` and `.../evacuate/<node>.tsv`.
pmxcfs, so every member sees the same bytes and a reboot cannot lose them; not
the guest description field, which PVE owns, re-encodes on every write, and
which is where the operator keeps their own notes. `ls` of those directories
is the list of outstanding debt, which is exactly what `doctor` reports, and
deleting the file is how the debt clears.

This breaks `tp`'s rule 3 in two places on purpose - an IP remap and a
shutdown, both of a running production container - and `engines/tp/CLAUDE.md`
says so, says why, and says not to extend the carve-out to a third verb
without the same kind of proof.

**`--cleanup` is the other end of the same disaster, and it is where the third
break lives.** Everything above happens while the storage node is dead. This
happens after it is back and `ct-failback --final` has put the newest data
into the production image, and it deals with what is left standing: a
production container still on the isolated bridge, and a `9<id>` on a compute
node still holding the address production is about to use again. It restores
the production network from the isolate record, stops the `9<id>`, moves that
one onto `MOCKNET_BRIDGE` so a compute node rebooting cannot put the address
back on the wire, sets its `onboot` to 0, and - only with `--destroy` -
removes it.

The first drill found the gap the hard way. `recall --final` and
`failback --final` both finished, and afterwards CT 110 was still on `vmbr99`
and CT 9110 was still there: every remaining step was a `pct` command in a log
line, which is the thing this whole layer exists to stop being true.

**Stopping is the default and destroying is a flag**, because stopping is
reversible with one `pct start` and destroying is not reversible at all. The
cost of that default is real and the run prints it every time: ct-replica's
R13 keys on the `9<id>`'s config EXISTING rather than on it running, so a kept
one holds replication for that container and the nightly run keeps exiting
non-zero. That is the protection working - the pre-outage copy is what R13 is
guarding - but somebody has to decide when the fallback has stopped being
worth a paused nightly, and that somebody is not this engine.

**What proves it is safe to do at all is the failback's own state file.** K2
reads `state/failback-<ctid>.json` and requires a `--final` round that
finished `ok`. A presync is a rehearsal that leaves the newest data exactly
where it was, so "the last failback said ok" without reading WHICH MODE it was
is the whole bug that guard exists for. The file is written by the machine
that ran the failback, so `--cleanup` is run there too, and a missing file is
reported as "not on this machine" rather than assumed either way.

K3 is the one that protects a customer: a RUNNING `9<id>` is only stopped when
the production container is running. Stopping it otherwise means nothing
answers that address at all - an outage caused by the tidy-up - and starting
production is a decision with a customer on the other end, so it refuses and
names the command instead of running it. An already-stopped `9<id>` is not
asked about, because there is nothing left to take away.

**`--isolate` gained the same instinct at the other end.** Off the wire is not
the end of it: an isolated container is still a pending writer, blocked only
because its storage is gone. So the isolate MODE now asks it to stop
afterwards - but only when the dead mount is already out of the way, which is
what the `gone` verdict is. While the mount is still there the processes are
in uninterruptible sleep and `pct shutdown` hangs until a timeout for nothing,
and freeing them means unmounting a storage every container on that node
shares. A run that named ONE container will not do that to a machine behind
the operator's back: it prints `ketsync evacuate --node <ip>`, which is the
command that does it deliberately, and stops there.

**On Open vSwitch the kernel cannot name a bridge, and "read the kernel, not
the config" nearly cost this fleet its DR.** Every check about where an
interface really is reads `/sys/class/net/<if>/master`, because a config can
record a bridge change PVE never applied to a running container. OVS does not
work that way: every port of every OVS bridge on a host is enslaved to ONE
datapath device called `ovs-system`, and the bridge membership lives in ovsdb.
So the master says `ovs-system` for an interface on `vmbr0` and `ovs-system`
for the same interface after it moves to `vmbr99`, and a comparison against
`MOCKNET_BRIDGE` can never be true. The first drill on this fleet ended with
D1 refusing every container - `still on the wire: veth110i0(ovs-system)` -
about containers that were correctly isolated. On an OVS fleet that closes the
only route out of a dead storage node.

The probe now prints both answers, `VETH <if> <master>` from the kernel and
`OVSBR <if> <bridge>` from `ovs-vsctl iface-to-br`, and the ENGINE chooses -
kernel first, ovsdb only when the kernel's answer is `ovs-system` or nothing.
Choosing inside the remote snippet would have been shorter and is the wrong
place: the simulators reproduce what a snippet DOES rather than executing it,
so a decision made in there is a decision no scenario and no mutation can
reach. In local bash it took three mutations, one of which - "take the
datapath device for a bridge name" - is this bug, put back on purpose.

An ovsdb that does not answer leaves `ovs-system` in the message rather than
blanking it. It is not a bridge name, so the container is still refused; the
operator sees the word that says it was OVS that went unanswered, and not the
container that moved.

The same probe asks OVS for the bridge's `list-ifaces` rather than its
`list-ports`, in P4, D1 and R9. An OVS bond is one PORT whose members are the
NICs and it has no kernel netdev of its own, so `list-ports` on a bridge
uplinked by a bond returns a name with no `/device` and no `/bonding` - and
the island bridge that every copy's production IP and MAC depends on would
read as isolated while it reached the wire through two cables.

## 4c. Asking before writing

Every verb that writes asks once, at the dispatcher, and says what it writes
rather than whether you are sure. A prompt that asks "are you sure" teaches
people to press y without reading it, and is then worth less than nothing: it
looks like a safety net while being a keystroke. The default is no.

No terminal and no `-y` is a REFUSAL with exit 2, not a quiet no. `read` on an
empty stdin returns immediately, and treating that as "no" while exiting 0
would be a nightly cron reporting success having done nothing - the outcome
this repo refuses everywhere else. `-y` means the decision was already made:
it skips the question and nothing else, no guard, ever.

**There is no `--force` and there must not be.** It was proposed and the case
for it could not be named. A flag whose use case has to be invented under
pressure is a flag that gets used under pressure, by somebody who is stuck at
three in the morning and out of ideas - the worst possible moment to be
allowed past a guard. When a guard refuses something it should allow, that is
a bug in the guard; it happened twice in one week and both were fixed in the
guard. A narrow named override like `--to` or `--dst` reads in a log as a
decision somebody made; `--force` reads as somebody in a hurry.

A bare writing verb refuses with a menu instead of defaulting to `--all`. The
four characters are the record of what somebody meant: `--all` in a shell
history says "I meant the fleet", and a bare verb says "I pressed Enter".

## 5. `distribute` — built, as `engines/tp/ct-distribute.sh`

Moves a copy from the backup node onto a compute node during a disaster:
resolves the target from `fleet.tsv`'s `dr` column (`--to` overrides, and a
container with neither is refused rather than placed somewhere reasonable),
checks `9<id>` is free across the whole cluster, allocates on the target's own
storage, transfers, writes the config carrying the production network, and then
prints the `pct start` for a human. 67 scenarios, 68 mutations.

Three things about it are new to this repo.

**It runs on neither end of its own transfer.** Every other engine here is one
of the two machines involved. This one is a third, and rsync cannot do
remote-to-remote, so the transfer is issued ON the target, pulling from the
backup node. That needs root ssh from the target to the backup node - which two
cluster members already have, because it is how PVE migration works - and it is
checked before anything is allocated rather than discovered afterwards, when
the cost is an allocated volume and a half-written config to unpick by hand.

**The destination is not one shape.** "Local storage" means a block device on
`lvmthin`, a raw file on `dir`, or a dataset on `zfspool`, and the three differ
in whether they need `mkfs`, whether they need a loop device, and whether they
need mounting at all. `dst_shape()` names the three and refuses anything else
BY NAME - guessing at an unknown type means `mkfs` on something that was not a
block device. That is the storage abstraction this design has needed since the
beginning, arriving in the one place where getting it wrong is cheapest to
catch: a new engine with its own simulator, rather than a refactor of three
that the fleet has been running for months.

**D1 is the one guard here that accepts a running production container.** Every
other lifecycle check in this repo refuses one, so this needs saying properly.

What D1 defends is not "one process" but "one address". The copy carries the
production container's IP and MAC deliberately - that is what makes it a
replacement rather than a new machine - so what must never happen is two of
them answering at once. A container whose every interface is enslaved to
`MOCKNET_BRIDGE`, on a node where that bridge has no uplink, cannot answer. It
is the same mechanism that has always made the `8<id>` copy harmless on the
backup node, and R9 already trusts it there.

The reason to allow it is not tidiness. The container D1 refuses is, in this
fleet's actual disaster, one whose NFS rootfs has vanished: its processes are
in uninterruptible sleep waiting on I/O that will never return, `SIGKILL` does
not reach a task in D state, so `pct shutdown` hangs and `pct stop` queues
behind it. Until the storage node comes back there is no way to stop it, and
waiting for that is exactly what the DR exists to avoid. Moving each interface
onto the isolated bridge is a write to `/etc/pve` that hotplugs live and needs
nothing from the dead storage - it is the only remedy that still works.

Three things make it safe enough to accept. It reads the KERNEL - the `master`
of each veth, the ports of the bridge - never the config, because a config can
record a bridge change that the running container never received. It counts
every interface, not `net0`, because the one somebody forgot is the one that
answers; and if it finds fewer veths than the config declares net lines, that
is unverified, and unverified refuses, the same rule as "unreachable is not
stopped". And it says out loud what it has accepted: the container is still a
PENDING WRITER, blocked now and writing again the instant the storage returns,
so it still has to be stopped before then - and failback's B1 refuses to write
into the production image until it is.

**The 9<id> takes its network from the isolate record when the production
config has been overwritten.** D6 reads the production container's net lines
rather than the copy's, because the copy sits on the isolated bridge by design
and this one is placed in order to answer. But `ketsync distribute` isolates
BEFORE it places, so on a real DR the production config also says
`MOCKNET_BRIDGE` by the time D6 reads it - every container, not the odd one.
Carrying that across would put the whole fleet on a bridge with no uplink and
leave a person retyping a bridge per container at four in the morning, which is
the work the automation exists to remove.

ct-prepare.sh wrote each interface's real bridge into pmxcfs before it moved
anything, precisely so this can be undone, and D6 reads it back. Two checks
stand between that file and a config PVE will act on: the record must say it is
about this container, and the value must look like an interface name. Either
failing means "no record", which is the honest answer - a container that comes
up on the isolated bridge is recoverable in a way that one on a segment nobody
chose is not. A container moved onto the isolated bridge BY HAND still has no
record and still gets the warning, because nothing can reconstruct what was
overwritten.

The `onboot: 1` check below it is therefore asked only of a container that is
DOWN. Refusing a running-and-isolated container for `onboot` would be refusing
a strictly smaller hazard than the one just accepted, and would do it in a
message that calls a running container stopped. `onboot: 1` is the normal state
of a production container, so getting that wrong would have refused every real
use of this path.

`fleet.tsv` grew an optional fifth column, the storage on the dr node, for the
same reason: a fleet is not homogeneous, one compute node's local storage is
`local-lvm` and another's is `local-zfs`, and a single global default cannot be
right for both.

It does not start containers. That rule is not a technicality - starting a
container is the moment a customer's service either comes back or collides with
something, and it belongs to somebody who is looking at the machine.

Placement comes from the inventory's `dr` column, with `--node` to override on
the day. Not from free RAM: choosing automatically is how a customer lands on
the wrong machine at 3am, and it is the same "no defaults, never guess" rule
the engines already enforce.

## 6. `recall` — built, as `engines/tp/ct-recall.sh`

`9300` on a compute node's local disk has the real data. Everything the
customer has done since the outage began is there, on one local disk, with
nothing replicating it - which is a second single point of failure, created by
the tool that was fixing the first one. `recall` is what ends that: it writes
`9300` back into `8300`, the DR copy on the backup node, and it is repeatable,
so it can run every hour of a long outage rather than once at the end.

It goes to the copy rather than straight to the production image on purpose.
That keeps a second copy of the DR data at every moment, and it leaves the
final write into the production image to `ct-failback.sh`, which already takes
a safety snapshot first.

**One inverted direction destroys every hour of customer work since the
disaster, and there is nothing to restore it from.** So the engine does not
take a direction as an argument, and it does not decide which side is newer by
comparing timestamps: rsync preserves mtimes, so the copy's files can be newer
on disk than the DR container's while holding older data.

It uses provenance. `ct-distribute.sh` writes a marker line into the `9300`
config naming the container and the copy it came out of, and that line is a
fact PVE is holding: this rootfs descends from that copy. A `9300` without it
was not made by `ct-distribute` out of this copy, its relationship to the copy
is unknown, and C3 refuses rather than guesses. The person running this has
been awake for six hours; the answer has to come from the machine.

Two more things it does not do. It does not decide where the DR container is -
one `ls /etc/pve/nodes/*/lxc/9300.conf` through the backup node names the
holder, because pmxcfs is cluster-shared and a node typed by a human is a node
that can be wrong. And it does not run the `pct destroy 9300` it prints:
destroying that container is what releases `ct-replica`'s R13, and releasing
the shield on data nobody has checked is the one step here that cannot be
undone.

There is deliberately no PAUSE requirement, unlike `ct-failback`'s `--final`.
R13 keys on the `9300` config existing rather than on it running, so it holds
through the shutdown, through `--final`, and until a human destroys it.

A `#` line in a guest config is not a comment - it is the guest's description
field, PVE owns it, and PVE re-emits it URL-encoded every time it writes that
config. `ct-distribute` writes the file directly, so a fresh placement matched
and every round after anybody started or stopped the container did not. The
fleet met that at the cutover, with both containers already shut down. The
config is decoded before the marker is compared; the marker itself is
unchanged, so containers already placed keep working.

53 scenarios, 47 mutations.

## 7. `status` — designed, not built

One table: every container, where it is running now, where its copy is, when it
was last synced, and whether that is where the inventory says it should be. The
last column is the point - a container that has quietly been living somewhere
else for a week is exactly what nobody notices.

## 8. Storage types

The engines currently assume the source is a raw file on a `dir` or `nfs`
storage, which they loop-mount. That is no longer true once containers can live
on compute nodes:

    dir / nfs on zfs    zfs snapshot + clone, read the raw file from the clone
    zfspool             rsync into the dataset directly
    lvm-thin            lvcreate --snapshot, mount the snapshot LV read-only
    dir on xfs/ext4     no point-in-time at all; refused unless LIVE_FALLBACK

The right shape is one `src_open`/`src_close` pair and one `dst_open`/
`dst_close` pair with three implementations each, not a `case` spread through
the flow.

**This work belongs in `tp`, not here**, and it is the largest single piece
still outstanding. Two things it must carry: a thin pool that fills does not
merely fail, it can take the whole pool read-only, so free space is checked
before a snapshot is taken and the snapshot is removed in the exit trap; and a
container on a compute node's local storage can only be read *on that node*, so
the transfer runs between two machines while the orchestrator touches neither.
That second point is not a complication - it is exactly the capability the
disaster case needs, since the orchestrator will not be the storage node.

## 9. Everything a human types is an IP, and the one name nobody types

PVE stores container configs under `/etc/pve/nodes/<name>/`, so a node name is
unavoidable as *data*. Typing one is avoidable, and that is the part that
matters: this machine sits outside the cluster on purpose, so it has neither
the cluster's `/etc/hosts` nor its DNS, and an address that only works while a
name server answers is an address that stops working during the exact incident
this tool exists for.

So `nodes.tsv` has no name column - an IP and a role, and that is the whole
table. `fleet.tsv` addresses its home and dr nodes the same way, and
`ketsync doctor` refuses to stay quiet about one that has no row.

The names are discovered instead. `ketsync` asks the backup node - a cluster
member - for `pvesh get /cluster/status` and caches the ip-to-name map in
`nodes.map`, which is generated and never hand-edited. The engines do the same
thing one level down: `BKP_NODE` is read from the backup node's own
`/etc/pve/local` symlink rather than a config file. A name that is typed is a
name that can be wrong today, or right today and stale after a rename, and
being wrong writes a guest config into a directory belonging to another cluster
member - past every check that would have caught anything else.

Setting `BKP_NODE` by hand still works and now means something different: not
"here is the name" but "refuse the run if the machine at `BKP_SSH` is not this
one". A pinned value is verified, never trusted. That is worth keeping, so it
stayed.

The cache exists because discovery needs a reachable cluster and the run that
needs this most is the one during an outage. A cached name a week old is still
right; PVE node names effectively never change, and if one does, `ketsync
doctor` says so on the next good day.

## 10. What is built today

    ketsync sync     real. pushes the fleet-wide tables, generation-ordered
    ketsync role     real. reports, and refuses to flip the role for you
    ketsync doctor   real. reachability, the node-name map, the generation
                     lines, every fleet.tsv address, whether the engines are
                     present AND executable, then tp doctor on top
    ketsync migrate      tp's, passed through untouched
    ketsync replica      tp's
    ketsync failback     tp's
    ketsync distribute   tp's - engines/tp/ct-distribute.sh, 67 scenarios,
                         68 mutations. See section 5
    ketsync recall       tp's - engines/tp/ct-recall.sh, 53 scenarios,
                         47 mutations. See section 6
    ketsync status       tp's
    ketsync isolate      tp's - engines/tp/ct-prepare.sh, 72 scenarios,
    ketsync restore      63 mutations, shared by all four. See section 4b
    ketsync evacuate
    ketsync cleanup

Nothing here is a stub any more. ketsync's own `tests/` covers `sync`,
`distribute`, the confirmation and `doctor`; `role` is the only command left
without a simulator, and that is the remaining debt - see `tests/README.md`.

`doctor` was written last, on the argument that a command which writes nothing
cannot break anything. That argument is wrong in a way worth writing down: a
read-only check does not fail loudly when it stops working, it reports the same
clean fleet a clean fleet reports. Its simulator found one on the first run - a
compute node this machine could not ssh to was being reported as expected,
which had been true for about a week and then stopped being true the moment
`evacuate`, `isolate`, `distribute`, `recall` and `cleanup` all started running
over exactly that connection. doctor was reporting a fleet that could not be
recovered as a fleet that was fine.
Nothing in `lib/` should write to a real machine before it has a simulator,
for the same reason `tp` has five.

---

# Part II — the engines

Everything below is the execution layer's ledger, kept with its own section
numbering: engine comments cite "docs/decisions.md section N" and every one of
those citations means a section in THIS part. It lived at
engines/tp/docs/decisions.md until the restructure put the repo in one tree;
merging the two files was the point, renumbering five hundred lines of scar
history against every comment that cites it was not.

Why this fleet is shaped the way it is, and what has already been tried.

`CLAUDE.md` tells you the rules you must not break while editing. This file
tells you why those rules exist, what the machines actually look like, and
which arguments have already been had — so nobody spends an afternoon
rediscovering that ZFS replication cannot give a container a GUI snapshot on
NFS. Everything here was learned against real hardware serving real customers.

Nothing in this file is aspirational. If something is not built, it says so.

---

## 1. The architecture, which is not up for discussion

    NFS node        an NFS server and nothing else. Deliberately OUTSIDE the
                    cluster. Owns tank/hosting and tank-ssd/hosting-ssd, runs
                    sanoid, and is where every engine in this repo runs.
    Compute nodes   run the CTs and VMs. Their disks live on the NFS node,
                    mounted over NFS. They own no guest data.
    Backup node     holds STOPPED copies of the guests, plus PBS. It is for
                    snapshots and backups, not for running production.

The hard requirement that drove the whole design: **`pct snapshot` must work
from the Proxmox GUI on the backup node, against a copy that is stopped but
could be started, snapshotted and backed up as it stands.** That is why the
copies are real containers with real configs on a ZFS `subvol-` dataset, and
not a tarball or a `zfs send` stream.

HA is not in use. Failover is manual, on purpose. If HA is ever turned on, the
copies must never be placed under it, and the HA group must be `restricted 1`
over the compute nodes — a low priority on the backup node is not enough,
because a low priority still allows a guest to land there.

## 2. The machines, and the two storage shapes

Both source storages are `dir` storages on the NFS node, and **they are not the
same shape**. This was guessed wrong twice before anybody ran `findmnt -T`.

    tank-hdd-nas   /tank/hosting          its own ZFS dataset, mounted there
    tank-ssd-nas   /tank-ssd/hosting-ssd  a plain subdirectory inside an XFS
                                          filesystem mounted at /tank-ssd

That difference is the whole reason G1 has two layers. The rule G1 is really
enforcing is *data must not land on the node root filesystem* — not "the pool
must be a mountpoint", which is a rule a legitimate `dir` storage breaks every
day. Layer one resolves the pool with `findmnt -T` and refuses `/`. Layer two
only runs when PVE has been told `is_mountpoint`, and then insists the declared
path really is mounted; that layer is what catches `tank/hosting` failing to
mount while its parent pool `tank` is up, which layer one cannot see.

`is_mountpoint` accepts a boolean *or* a path. Reading it as a boolean was a
real bug, caught by reading the PVE docs rather than by a test — which is why
two scenarios exist purely to keep it caught.

Two consequences worth carrying: the two storages overlap (`tank-ssd-nas` lives
inside `tank-ssd`, so PVE double-counts their capacity), and `tank-ssd` has
`content backup`, so a vzdump run competes for the same spindles as a migration
wave.

## 3. Locked scope — do not reopen

**No cutover in the tooling.** Nothing here starts, stops, reboots or rolls
back a guest. The last thing a migration does is move the final delta with
`--stopped`; a human stops the container, a human adds `net0`, a human starts
it. Cutover and DR promotion are decisions with customers on the other end, and
they are made by somebody looking at the machine.

**No defaults for `new_node`, `storage`, or a replica `dest`.** A row missing
one is an error and is skipped. Guessing puts a container on the wrong node or
a DR copy on the wrong pool.

**The 2 Gbps link is a hard ceiling.** `BW_TOTAL_MB` is divided by `LANES`
*statically*. Dynamic borrowing was rejected: a lane that computed its share
while alone keeps that share after another lane starts, and the ceiling is
breached exactly when it matters. Counting live lanes by `pgrep` does not work
either — rsync forks a receiver and a generator with identical argv, so every
lane counts double.

**`mp0` and other extra mountpoints are migrated as config, never as data.**
Every path that will become an empty directory is named in the log. `rsync -x`
stops at the mount boundary anyway, so nothing swells the rootfs image.

**Thai belongs in `docs/*.html` and nowhere else** — see `CLAUDE.md` rule 2.
This file is English for that reason.

## 4. Approaches that were tried or costed, and rejected

**GUI snapshots of a CT on NFS.** Structurally impossible: PVE only offers CT
snapshots on storage types that can do them, and NFS is not one. Ceph would
solve it and was rejected as a network dependency the fleet does not want.
`pvesr` (ZFS replication) was rejected because it requires guest disks on local
ZFS, which contradicts the architecture rule above.

**rsync straight from each compute node.** The container is live and the copy
would be inconsistent in a way nothing detects. The engines take a ZFS snapshot
and read out of the clone instead, so every file in one round comes from the
same instant.

**syncoid / `zfs send` for the copies.** Gives no `pct snapshot` in the GUI,
and a rollback on the destination destroys the copy's own snapshot history.

**One engine with a `MODE` switch.** Rejected when the three tools were merged
into this repo. The *order* of the guards is the safety design, and it
genuinely differs by direction — G1 before allocation, G7 with G2 before any
transfer, B1 before anything is mounted. Three sequences that each read
straight down beat one sequence with `if MODE` in it.

**Forcing every copy onto VLAN 99.** Rejected: a fleet with a VLAN per customer
reuses IP ranges, so one shared VLAN would make the copies collide with *each
other*. Copies keep the source VLAN tag and change only the bridge.

**Splitting the c2v tools into `tools/centos6/` and `tools/ubuntu20-04/`.**
Rejected: phase 1 differs between the families in about six places and every
one of them is a single `case`. Copying a thousand lines guarantees the next
mtab-class bug gets fixed in one copy and forgotten in the other.

**Naming the backup pools after the machine (`rx740xd-*`).** Rejected: a role
outlives a chassis, and a per-machine pool name forces one PVE storage ID per
node, because a storage ID binds one path across the whole cluster. Pools are
named for what they hold: `replica-ssd`, `replica-hdd`, `pbsstore-sas`.

**Copying `/etc/pve` to "move" a node to new hardware.** Impossible. Cluster
membership lives in pmxcfs, corosync config and node certificates, and cannot
be carried across machines. The only supported shape is add a node, then remove
a node.

## 5. Incidents that became guards

Each of these happened. The guard is the scar.

**A failback refused every container because this host could not ssh to the
compute nodes.** The copies were up and serving, production was down, and every
row stopped at B1 with "cannot reach pve-r32 - 'unverified' is not 'stopped'".
B1 was right: it asks the production node whether the container is stopped, and
it asks by the pmxcfs node *name*. The storage node sits outside the cluster on
purpose, so it inherits neither the cluster's `/etc/hosts` nor its keys, and
nothing had ever said that failback depends on a path nothing else in this repo
uses. The engine was correct and the setup was incomplete, which is the worst
combination because it only shows up on the day it matters. → `--list` now
names every unreachable production node, prints the two commands that fix it,
and exits 1 rather than 0. Run it on an ordinary Tuesday.

**A dataset was not mounted and the engine filled the node root.** The pool
path resolved, the directory existed, and rsync wrote into the root filesystem
until it was full. → G1, and its equivalents R1 and B3.

**The review catch that mattered more than the fix.** When the umount guard was
added, the first version only skipped writing the config. It had to also skip
the ENOSPC grow-and-retry, because `resize2fs` against an image that is still
mounted is corruption rather than a failed run. → G3. That lesson was then
*lost* when `ct-failback.sh` was written, and found again by its simulator: a
`cleanup_ct` that cleared its "still mounted" flag even when the unmount had
failed silently disarmed the same gate. → the B5 gate, and mutation 12 in
`tests/mutation/run-mutation-failback.sh`.

**A stopped container already owned the target VMID.** G2 only sees a *running*
container, so a stopped one holding that id is invisible — and if its rootfs is
the same volid, the image is never allocated (it already exists) and
`rsync --delete` empties somebody else's container into ours. One mistyped
digit is enough. → G7, placed immediately after G2, before allocation and
before any transfer. That lesson was *also* lost in `ct-replica.sh`, where R4
ran after the transfer and only when a copy was first created. → R4 now runs
before the transfer, on every round.

**Two cron lanes at 21:00:02.** Both fired together, the empty lane finished in
zero seconds, and its cleanup loop `for s in /run/ctrep-*.sock` tore down the
ssh mux master the other lane was still using. It surfaced as
`storage 'replica-hdd' is not active` in the middle of a transfer. → the
control socket path carries the pid, and the cleanup glob matches only this
process's own sockets.

**`pvesm: command not found` under cron.** cron hands a script
`PATH=/usr/bin:/bin`, and `pvesm`, `zfs`, `losetup` and `e2fsck` all live in
sbin. It did not fail cleanly: `pvesm` returned nothing and the result looked
exactly like a storage that had never been configured. → every engine sets its
own PATH, and every engine has a required-command preflight that names what is
missing in one line.

**A `--storage` typo exited 0.** No row matched, no work was done, and under
cron that is indistinguishable from a healthy night. A lane can look fine for
weeks. → a `matched` counter, and a non-zero exit when a filter matches
nothing. The counter must be read *before* the `.done` check: a lane whose
containers have all gone live is not a typo.

**A config write was cut short and the damage was permanent.** G6 and R5 never
rewrite a config that exists, so a truncated one would boot never and every
later run would call that container healthy. → the config is written, read back
and compared; a mismatch is a failure, not a warning. Note that the rc is still
0 or 24 in that case, which is the point: the data is fine, only the config is
broken, and the fix is to delete the config and run again.

**`pct clone` failed with `mount: cannot mount /dev/loop0 read-only`.** The
source container was running and its ext4 journal needed replay. → mount
`ro,noload`, which also removed a 43-second stall that had been mistaken for
slow disks. It scales with journal dirtiness, not with image size.

**rc=23 after a failback.** Once is almost always the `ro,noload` transient and
clears on the next run. Twice in a row on the same container is a damaged
image. Only the previous run can tell them apart, so the engine reads the last
rc out of `state/<ctid>.json` and escalates the message on the second one. It
prints the `e2fsck -fn` command; it never repairs anything itself.

**QDevice, three failures in a row.** `corosync-qdevice` must be installed on
*every* node, not only the one running `pvecm qdevice setup`, and that setup is
not atomic — it can leave the qnetd database initialised after failing. The
container holding the qnetd address changed IP after a reboot, which looks like
a certificate problem and is not: `nc -zvw3 <ip> 5403` separates them, where a
timeout means nobody holds that address and a refusal means the host is up but
the daemon is not. The real root cause was ownership: `pvecm qdevice setup`
creates `/etc/corosync/qnetd/nssdb` over ssh as root, while the daemon runs as
`coroqnetd`. Fix is `chown -R coroqnetd:coroqnetd /etc/corosync/qnetd`. Do not
`rm -rf` that directory — the package sets its ownership. Also: `pvecm qdevice
setup` starts `corosync-qdevice` on the nodes but never `corosync-qnetd` on the
arbiter host, and `pvecm qdevice remove` ssh's out to the configured address
while holding a cfs lock, so it cannot be run while that host is down.

**A flag with its value missing ran forever.** All three engines parsed
`--storage`/`--ctid`/`--dest` with `shift 2 || true`. With the flag last on the
command line `shift 2` fails, `|| true` swallows it, `$#` never reaches zero and
the parse loop spins. Nothing is logged, nothing exits, and cron starts another
one every fifteen minutes. → the value is checked before the shift and a
missing one is exit 2. The engines now write `"$2"` rather than `"${2:-}"` on
purpose, so that deleting the check dies on `set -u` instead of spinning again
— a mutation that hangs proves nothing and blocks the suite forever.

**Two of the three mutation runners had no safety net, and this file said they
did.** `mutant()` is supposed to refuse a mutant that perl could not produce.
Only `run-mutation.sh` did. `run-mutation-replica.sh` checked neither perl's
exit status nor the mutant's size, so a mutation program that did not compile
produced a zero-byte file, which differs from the engine, parses as bash, runs
as an engine that does nothing, fails every scenario, and was reported as a
kill. Demonstrated on the real runner before it was fixed: a green tick and
exit 0 for a mutation that never touched the engine. → all three carry both
checks, and each one now runs `self_check` on itself before grading anything,
feeding `mutant()` a program perl cannot compile and a program that empties the
engine. The lesson is not that the guards were wrong; it is that nothing ever
asked whether they were there.

**A dry run that skipped a check rather than a write.** `ct-failback.sh`
gated the whole-run PAUSE requirement on `(( ! DRY ))`, so `--final --dry-run`
printed a clean plan for a run that was going to refuse, and the operator found
out inside the cutover window. → the check runs in both modes; only the outcome
differs. The real run exits 2, the dry run says "would REFUSE" and carries on
so the rest of the plan is still printed.

**A dry run that wrote to the production image.** `ct-failback.sh --dry-run`
loop-mounted the customer's image with a bare `-o loop`. Mounting ext4
read-write replays the journal and rewrites the superblock, so "dry-run —
nothing was written" was false at the byte level, against a production image,
at the one moment B1 has established nobody is watching it. The scenarios did
not catch it because they asserted on the image's *content*, which a journal
replay does not change. `ct-replica.sh` has mounted `ro,noload` since R6; the
lesson had simply not been carried across. → the dry mount is `ro,noload`, and
the simulator now enforces it as an invariant rather than an assertion:
`run_engine` reads `--dry-run` out of the engine's own argv and exports
`SIM_DRY`, and every fake that would change the fleet records a violation
instead of pretending. It found this bug the first time it ran, in three
images at once, without anybody writing an assertion for it.

**A comment inside a line continuation, and a `bash -n` that said clean.**
A comment placed between a command and its `\` continuation ends the
command. `mutant "name" \` + comment + `'program' \` + `1` therefore called
`mutant` with ONE argument, and it died on `$2: unbound variable` - after
the suite had already printed several green ticks, so the failure looked
like it belonged to the mutation before it. `bash -n` was clean again;
shellcheck caught it as SC2288 and named it exactly.

Two of these in one week, both the same shape: a comment edit that changed
what the shell parsed, past a syntax check that only proves a file parses.
Comments go ABOVE a `mutant` call, never inside one.

**A comment that lost its hashes, and a `bash -n` that said clean.** A block
of comment inserted into `ct-migrate.sh` kept the `#` on its first line and
lost it on the next five, so those lines were executed as commands. One of
them contained the word `tool's`, which opened a single quote - and that
quote was closed forty lines later by `LOGSEP='###...'`. The file therefore
PARSED, `bash -n` reported clean, and everything between the two quotes had
silently become one string. Every guard still looked present in the source.

What caught it was the simulator: 57 of 61 scenarios went red at once, which
is the signature of the engine itself being broken rather than a guard moving.
shellcheck caught it too, with SC1078 pointing at a quote thirty lines away
from the real fault. → the lesson is not about comments. It is that
`bash -n` proves a file parses and nothing more, and that `make lint` alone is
never enough to say a change is safe - which is why `make test` runs the real
engines even for a change that looks like documentation.

**Three mutations that were never applied.** In the migrate mutation suite,
three perl programs did not compile: a shell function's opening brace inside an
`s{}{}` replacement, which perl balances against the closing delimiter. perl
wrote nothing, the mutant was an empty file, and an empty file "kills" every
scenario because it does nothing at all. The suite printed a green tick for
three mutations that had never touched the engine. → `mutant()` checks perl's
exit status and refuses a mutant that is empty or less than half the size of
the engine.

**The engine read its own unmount back as the storage recovering.** During the
2026-08-15 DR drill, evacuate correctly proved tank-hdd-nas dead, unmounted it
with `umount -f -l`, and asked CT 110 to stop. lxc-stop gave up, the engine
fell back to isolating - and P2 refused, because "the storage ANSWERED": the
unmount had left PVE's mountpoint directory behind, an empty dir on the node's
root filesystem, and a `stat` on an empty local dir answers instantly with
rc 0. The stat proof cannot tell a live NFS server from the hole where one was
unmounted; only `/proc/mounts` can, and nothing asked it. The simulator's fake
had modelled the unmounted case as ENOENT - what would have been convenient -
so every scenario passed against a world that does not exist. → the probe now
reports MOUNTED from `/proc/mounts` (which cannot block) plus the storage's
type, and the verdict is made in the engine: an nfs/cifs storage, or a dir
that declares is_mountpoint, that is absent from the mount table is `gone`
whatever the stat said. A plain dir storage keeps the stat alone - it was
never a mount, and condemning it for that would isolate every container on a
healthy local-path storage.

**The three-minute budget that never reached the command doing the waiting.**
Same drill, one line earlier. The evacuate wait was 180s because the I/O error
that lets a guest on a forced-off mount finally die was measured at ~132s -
but `pct shutdown` hands the wait to `lxc-stop --nokill --timeout 60`, its own
default, and nothing passed the budget down. lxc-stop gave up at sixty every
time; the outer `timeout 180` never fired and never helped. → every shutdown
here passes its budget with `--timeout`, and the outer timeout is thirty
seconds longer, existing only for a pct that never returns at all. The fake
reproduces pct's real failure line with the timeout number in it, so a budget
that stops reaching lxc-stop turns a scenario red by the number in the
message.

**Then the drill showed what the patience was buying, and the answer was
nothing.** With the budget finally reaching lxc-stop, both containers were
waited on for the full 180s and neither came down - whether the EIO that kills
a blocked guest ever arrives is a race with the RPCs in flight at unmount
time, and a real total outage loses it. Two facts decided what replaced the
waiting. The DR's critical path needs OFF THE WIRE, which isolate delivers in
about three seconds and D1 accepts. And the shutdown request is a SIGNAL that
outlives the wait: the same drill watched both containers, asked to stop
during the outage, shut themselves down hours later the moment the storage
returned, on the strength of that queued signal - so cutting the wait loses
nothing that was ever going to happen inside it. → SHUTDOWN_GRACE, 30s, on
the evacuate and isolate paths: long enough for a guest whose writes already
fail fast to run an orderly shutdown, an order of magnitude shorter than the
horizon it used to wait for. At two hundred containers the difference is
eleven hours of customer downtime against two. SHUTDOWN_TIMEOUT stays 180 for
`--cleanup` alone: that path runs after the disaster on healthy storage,
nothing is waiting on it, and a database flushing for two minutes deserves
its two minutes.

## 6. Numbers calibrated on the real fleet

    SHUTDOWN_GRACE     30s     evacuate/isolate: ask, give a fast-failing
                               guest room for an orderly shutdown, isolate the
                               rest. The signal outlives the wait - see the
                               2026-08-15 entries in section 5
    SHUTDOWN_TIMEOUT   180s    cleanup only: a 9<id> on healthy storage may
                               really need its two minutes to flush
    BW_TOTAL_MB        230     divided statically by LANES
    USAGE_FACTOR_PCT   185     image size from the container's used bytes
    OFFSET             8000    copy VMID = source VMID + 8000
    ARC on the backup  32 GiB  PVE >= 8.1 caps zfs_arc_max at ~10% of RAM,
                               which was ~6 GiB out of 64 and far too small
    recordsize         128k    replica datasets (container rootfs)
                       1M      pbsstore-sas/chunks, set BEFORE the first backup
    compression        zstd    replica-hdd: 40 idle cores buy a better ratio
                       lz4     replica-ssd: a DR start has to be fast

Every replica dataset also needs `atime=off`, `xattr=sa` and
`acltype=posixacl`; LXC will not start on a dataset without the last two.
`bkp02-setup.sh` sets all of this and refuses to run unless the pools already
exist — creating a pool is a decision about physical disks and belongs to a
human.

**ssh cipher.** OpenSSH negotiates chacha20-poly1305 first by default, which
has no CPU instruction behind it and tops out around 150-400 MB/s per stream —
matching exactly the throughput that was being blamed on disks and cabling.
Forcing AES-GCM roughly doubles it on the same link. It is applied to the data
path only; the control path and its mux master are left alone. Set
`SSH_CIPHERS=` empty if a peer refuses the list.

## 7. The backup node

`replica-ssd` is a mirror of two Samsung 870 EVO. `replica-hdd` is six 2.4 TB
10K SAS disks as three mirrored pairs. `pbsstore-sas` is a 6-wide raidz1 with
one hot spare.

The layout is not an aesthetic choice. raidz1 delivers random IOPS
approximately equal to a single disk however wide it is (a 6-wide array is
about 180 IOPS) where three mirrored pairs give roughly 1100 read and 550
write, and a resilver touches the whole vdev rather than one pair. A replica
pool has to be able to actually `pct start` a container during a disaster, so
it gets mirrors; a PBS chunk store is sequential and wants capacity, so it gets
raidz1.

On the spare: `zed` must be running for a hot spare to activate at all,
`autoreplace=on`, and **a scrub never touches the spare** — so it needs its own
`smartctl -t long` on a schedule. A spare that has activated is a temporary
state, not a resolution; order a disk the same day. Skip scrubs on SSD pools.

One flag worth remembering: `zpool create` takes `-o` for pool properties and
`-O` for dataset properties, and every single one needs its flag. `autotrim=on`
without `-o` was silently taken as the pool *name*, and the failure surfaced as
`cannot open 'pbsstore-sas': no such device in /dev`.

## 8. CT to VM

Proxmox has no `pct convert-to-vm`. A container rootfs is missing three things
a VM needs: a kernel, a bootloader, and an initramfs that knows virtio.
Everything else is tidying.

The split into two phases is not tidiness — **the line is which kernel runs the
command.** On the EL path, `rpm`, `dracut` and `grub` are linked against glibc
2.12, which calls the vsyscall page at a fixed address; on a PVE 9 host
(`vsyscall=none`) they segfault on the first command, and no amount of
scripting fixes that. Those three commands have to run under the rescue ISO's
own 2.6.32 kernel. The bonus is that the ISO carries `kernel`, `grub` and
`dracut` with their dependencies, so yum can point at `file:///mnt/source` and
never touch a dead vault mirror — which was previously half the elapsed time of
the whole job.

Debian and Ubuntu need none of that: a PVE node *is* Debian, so phase 2 is an
ordinary chroot on the host. That is why phase 2 is split by family and phase 1
is not.

Things learned the hard way here, all of which are now enforced in code:

Phase 1 excludes `/boot/***`, `/etc/fstab` and the persistent-net rules,
because a second `rsync --delete` after the kernel is installed would delete
that kernel silently — the MBR survives, so the VM simply stops booting with
nothing in any log. Ordering instructions were the old answer; an exclude
cannot be mistyped in the wrong order.

Phase 1 decides whether phase 2 has already run by reading sector 0 of the
image for the `GRUB` signature, because rsync cannot touch the MBR and it is
therefore the only honest witness.

Phase 1 refuses block storage (LVM, ZFS volumes) outright rather than doing
half the job — `losetup` works on regular files only.

VM 9600 failed to boot twice, both times from the same line:
`--exclude=/usr/share/initramfs-tools`. That directory is shared ground, and
the `udev` package owns three files in it — one hook that copies `blkid` into
the initramfs, and one `init-bottom` script that hands `/dev` over to the real
root. Losing the first gives `ALERT! UUID=... does not exist`; losing the
second gives `Kernel panic - Attempted to kill init!`. `apt` cannot repair it,
because the dpkg database copied from the container insists udev is installed.
The fix is not to narrow the exclude list — it exists to close the hole
`rsync --delete` would otherwise open — but to have phase 2 put back what it
needs and **read back every time**: `lsinitramfs | grep -q bin/blkid`, and a
`/dev` node table verified by running the real code with only `mknod` stubbed.

The broader lesson: any phase-1 exclude pointing at a directory several
packages share will take other packages' files with it, and the package manager
will not notice.

## 9. What survives a re-sync

Asked often enough to be worth stating plainly. The line is whether the file is
inside the container's rootfs or outside it.

**Outside the rootfs — survives every round.** The target's config at
`/etc/pve/lxc/<new_ctid>.conf` is never overwritten once it exists (G6). So a
hand-added `net0`, an adjusted `memory` or `cores`, a changed `onboot` all
survive. Later rounds can only *report* that the image grew.

**Inside the rootfs — overwritten every round.** The sync is
`-aHAX --numeric-ids --sparse -x --delete` excluding only `/proc /sys /dev /run
/tmp /lost+found`. Everything else is made byte-identical to the source, so
network scripts, `/etc/hosts`, application config and anything created by hand
on the target are replaced or deleted. This is correct: a migration target that
is not identical to its source is not a migration.

If a change has to survive, make it on the source and let the sync carry it, or
apply it during the final cutover round.

Bridge mapping lives in `tools/c2v-prepare.sh` and nowhere else.
`ct-migrate.sh` strips every `net[0-9]+:` line on purpose. Even the c2v tool
only *prints* the `qm set` command for a human to paste — including `tag=` and
`mtu=` carried over from the container, and a missing `mtu` is the failure
where ssh connects fine but a large scp hangs.

## 10. What is not built

**`lib/`.** The three engines duplicate roughly nineteen functions. Five bugs
found in one week were the same bug in two engines. All three now have a
simulator and a mutation suite, which is what makes the extraction safe to do
without a fleet to test against. See `CLAUDE.md` for the two constraints.

**One shared bandwidth ceiling.** `ctmig.conf` and `ctrep.conf` each carry
their own `BW_TOTAL_MB`, so two engines running together use twice the ceiling
either believes it owns. `tp doctor` reports it; the fix lands with the
library.

**The `tp doctor` size-drift item is only a report.** When G4 grows an image,
G6 will not rewrite the config that already exists, so the config's `size=`
stays at the old number for good. The image is right and nothing is lost, but
`pct resize` later computes from that stale value. `tp doctor` names every
container it has happened to; fixing the line is still a human's job, on
purpose.

**Both migrate guides are current again.** `docs/quickstart.html` was the
stale one — it still named the engine `presync-all.sh`, a name that had not
existed for months, and gave a four-column inventory where five are required,
so an operator following it would have typed a command that was not there and
then had every row rejected. `docs/manual.html` turned out to be fine. The
lesson is the one in the note above it: a claim that a document is stale goes
stale too, so check before you trust it.

**What has actually run for real, and the README that said otherwise.**
`ct-migrate.sh`, `ct-replica.sh` and both c2v paths are in production and have
been for a while. `ct-failback.sh` has never been run once - it only exists for
the day the copies are needed, and that day has not come.

Worth recording because the README said something different, and said it
confidently: "ct-migrate.sh is in production against a real fleet. ct-replica.sh
and ct-failback.sh are newer." That was true when it was written and quietly
stopped being true, and it was then read and believed - twice, by two different
readers, one of whom repeated it back in a brief as established fact. A status
line is the most perishable sentence in any repository: it describes a moment
and nothing about it changes when the moment passes. The note above about the
stale migrate guide says a claim that a document is stale goes stale too. This
is the other half: a claim that something is NEW goes stale the fastest of all.

**Offsite copies.** Nothing exists. Everything is in one building.

**Lab acceptance.** T1, T5 and T6 have passed on real hardware. T2 (a GUI
`pct snapshot` on the copy), T3, T4, T7 and T8 are open, as are the three
timing numbers: seconds per replica round, RTO for the NFS-failure runbook, and
a full PBS restore.
