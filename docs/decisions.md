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

## 3. One writer for the inventory, ordered by a generation number

Every synced file carries `# generation: N` and the number goes up on every
edit. `ketsync sync` refuses to push a file over a newer one, so a master that
was promoted by mistake and then demoted cannot walk its stale inventory back
over the fleet.

A new machine joins by being added to `nodes.tsv` and receiving a sync. There
is no membership protocol, because with manual promotion there is nothing for
one to agree about.

## 4. `distribute` — designed, not built

Moves a copy from the backup node onto a compute node during a disaster:
resolve the target from the inventory's `dr` column, check the VMID is free
*there* (the copy's own guards only look at the backup node), transfer, write
the config, and then **print the `pct start` for a human to run**.

It does not start containers. That rule is not a technicality - starting a
container is the moment a customer's service either comes back or collides with
something, and it belongs to somebody who is looking at the machine.

Placement comes from the inventory's `dr` column, with `--node` to override on
the day. Not from free RAM: choosing automatically is how a customer lands on
the wrong machine at 3am, and it is the same "no defaults, never guess" rule
the engines already enforce.

## 5. `recall` — designed, not built, and the most dangerous thing here

The return trip, once the storage node is back. The container ran on a compute
node for hours; the image on the storage node is that many hours stale.

**The sync must go compute -> storage.** One inverted flag destroys every hour
of customer work since the disaster, and it cannot be undone. So `recall` may
not simply take a direction as an argument - it has to establish which side is
newer and **refuse to write into a destination that is newer than its source**.
The person running it has just been awake for six hours.

## 6. `status` — designed, not built

One table: every container, where it is running now, where its copy is, when it
was last synced, and whether that is where the inventory says it should be. The
last column is the point - a container that has quietly been living somewhere
else for a week is exactly what nobody notices.

## 7. Storage types

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

## 8. Everything is an IP

PVE stores container configs under `/etc/pve/nodes/<name>/`, so node names
cannot be avoided. Resolving them can be. `nodes.tsv` is the only place a name
becomes an address, and nothing else in this repo resolves a hostname - which
is what lets it work from a machine that is deliberately outside the cluster
and therefore has neither its `/etc/hosts` nor its DNS.

## 9. What is built today

    ketsync sync     real. pushes config + inventory, generation-ordered
    ketsync role     real. reports, and refuses to flip the role for you
    ketsync doctor   real. reachability, the generation lines, ssh to every
                     compute node, and whether tp is actually present
    ketsync status       stub, exits 2
    ketsync distribute   stub, exits 2
    ketsync recall       stub, exits 2

The stubs say so rather than half working. `tests/` is empty and that is a
debt: see `tests/README.md`. Nothing here should write to a real machine
before it has a simulator, for the same reason `tp` has one.
