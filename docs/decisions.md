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

`ctrep.conf` and `ctmig.conf` are also excluded, for a softer reason: they mix
fleet-wide tuning (bandwidth, retry counts) with per-machine addresses
(`BKP_SSH` means "the other machine", which is a different machine depending on
who is asking). Splitting them into a shared part and a local part is a job of
its own and has not been done.

`fleet.tsv` is deliberately not called an inventory: `engines/tp` already has two
files with that word in the name and entirely different columns, and one word
meaning three things is how somebody edits the wrong table during a DR.
`fleet.tsv` is the map - which container lives where, and where it goes when
its home is gone. tp's inventories are work lists.

Every synced file carries `# generation: N` and the number goes up on every
edit. `ketsync sync` refuses to push a file over a newer one, so a master that
was promoted by mistake and then demoted cannot walk its stale map back over
the fleet.

A new machine joins by being added to `nodes.tsv` and receiving a sync. There
is no membership protocol, because with manual promotion there is nothing for
one to agree about.

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
prints the `pct start` for a human. 34 scenarios, 30 mutations.

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

## 6. `recall` — designed, not built, and the most dangerous thing here


The return trip, once the storage node is back: `9300` on a compute node's
local-lvm has the real data, and `300`'s image on the storage node is however
many hours stale. The container ran on a compute node for hours; the image on
the storage node is that many hours stale.

**The sync must go compute -> storage.** One inverted flag destroys every hour
of customer work since the disaster, and it cannot be undone. So `recall` may
not simply take a direction as an argument - it has to establish which side is
newer and **refuse to write into a destination that is newer than its source**.
The person running it has just been awake for six hours.

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
    ketsync distribute   tp's - engines/tp/ct-distribute.sh, 34 scenarios,
                         30 mutations. See section 5
    ketsync status       tp's
    ketsync recall       stub, exits 2. See section 6 for why it is the one
                         command that must not be written carelessly

The one remaining stub says so rather than half working. ketsync's own `tests/`
is empty and that is a debt: see `tests/README.md`. Nothing in `lib/` should
write to a real machine before it has a simulator, for the same reason `tp` has
four.
