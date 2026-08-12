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

Built, and the same code in all four: `ct-replica.sh` R14, `ct-failback.sh`
B8, `ct-distribute.sh` D8, `ct-recall.sh` C8. This paragraph described a design for months while
every engine took a *local* `flock` instead — replica's keyed on the copy id,
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

## 5. `distribute` — built, as `engines/tp/ct-distribute.sh`

Moves a copy from the backup node onto a compute node during a disaster:
resolves the target from `fleet.tsv`'s `dr` column (`--to` overrides, and a
container with neither is refused rather than placed somewhere reasonable),
checks `9<id>` is free across the whole cluster, allocates on the target's own
storage, transfers, writes the config carrying the production network, and then
prints the `pct start` for a human. 46 scenarios, 50 mutations.

Two things about it are new to this repo.

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

48 scenarios, 41 mutations.

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
    ketsync distribute   tp's - engines/tp/ct-distribute.sh, 46 scenarios,
                         50 mutations. See section 5
    ketsync recall       tp's - engines/tp/ct-recall.sh, 48 scenarios,
                         41 mutations. See section 6
    ketsync status       tp's

Nothing here is a stub any more. ketsync's own `tests/` covers `sync` and not
`role` or `doctor`, and that is the remaining debt: see `tests/README.md`.
Nothing in `lib/` should write to a real machine before it has a simulator,
for the same reason `tp` has five.
