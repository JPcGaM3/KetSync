# ketsync

Replication and disaster recovery for a Proxmox VE fleet whose containers all
live on one storage node.

That single storage node is the thing this exists for. It holds every
container's disk and exports them over NFS, so when it dies nothing runs: not
the compute nodes, whose images have gone, and not the backup node, which has
the data but nowhere near the CPU and RAM for the whole fleet. Getting back
from that is a placement problem — which container goes to which machine, on
which storage, in what order — and it has to be solvable at 3am by somebody
who did not design it.

**Nothing here starts, stops or destroys a container.** Every engine moves
data, writes a config, and then prints the `pct start` for a human. Bringing a
customer's service back is a decision, not a step.

---

## The machines

    storage node    exports the container disks over NFS. Every engine runs
                    here. Deliberately OUTSIDE the PVE cluster, so it has
                    neither the cluster's DNS nor its /etc/hosts
    compute nodes   NFS-mount those disks and run the containers
    backup node     a cluster member. Holds the stopped DR copies, and PBS

    storage --replica--> backup            every night, and every 15 minutes
    backup  --distribute--> compute        when the storage node is dead
    compute --recall--> backup             while it is still dead
    backup  --failback--> storage          when it comes back

## The two layers

`ketsync` decides **who** does **what** and **where**. `tp` — the five engines
under `engines/tp/` — does it. Nothing in the decision layer moves customer
data by itself; if you find an `rsync` outside an engine, it is in the wrong
place.

One repo, one clone, one command in front of both:

```
ketsync migrate      an old node's container  ->  a raw image here
ketsync replica      a live image here        ->  a stopped copy on the backup
ketsync failback     a promoted copy          ->  back into the production image
ketsync distribute   a DR copy                ->  a compute node's OWN storage
ketsync recall       a temporary DR container ->  back to the backup node
ketsync status       the last run of every container

ketsync sync         push the tables to every node that has a ketsync
ketsync role         who this machine thinks it is
ketsync doctor       the cross-checks nobody remembers to run, both layers
```

tp's commands pass straight through — same flags, same guards, same exit
codes. You should never need to reach into `engines/tp` to run anything.

## The three VMIDs

One container has up to three, and the digit in front tells you which one you
are looking at without asking anybody.

    300    production. A raw image on the storage node, NFS-mounted by the
           compute node that runs it
    8300   the DR copy on the backup node. Written every replica round,
           stopped, on a bridge with no uplink.        OFFSET=8000
    9300   a TEMPORARY container on a compute node's own disk, made only
           while the storage node is down.             DR_OFFSET=9000

**You never type 8300 or 9300.** They come from two numbers in one config
file, so the arithmetic cannot drift per container — and seeing a 9 in front
in `pct list` tells you immediately that this is temporary, its data is not
replicated anywhere, and somebody has to unwind it deliberately.

---

## Setting it up

Install on **two** machines: the storage node and the backup node. Compute
nodes need nothing but an ssh key.

### 1. Clone it to the same absolute path everywhere

```bash
git clone <this repo> /root/ketsync
```

Not a style preference: `ketsync sync` pushes to the path it is installed at,
so a clone somewhere else receives nothing. It says so per node now, but it
cannot fix it for you.

### 2. On the storage node — this is the master

```bash
cd /root/ketsync
cp ketsync.conf.sample  ketsync.conf     # KS_ROLE=master, KS_MASTER_IP=<this ip>
cp nodes.tsv.sample     nodes.tsv
cp fleet.tsv.sample     fleet.tsv
cd engines/tp
cp inventory-replica.sample.tsv  inventory-replica.tsv
```

Fill in `nodes.tsv` before anything else — every address this system will ever
use comes from that one file, and a machine with no row in it is a hard stop
rather than a guessed address:

```
# ip		role
10.0.0.17	storage
10.0.0.9	backup
10.0.0.32	compute
10.0.0.33	compute
```

There is no name column, and nothing here resolves a hostname. That is what
lets the storage node work from outside the cluster. PVE node *names* are
still needed to write a guest config; they are discovered from the cluster and
cached in `nodes.map`, which nobody edits.

### 3. ssh, once, from the storage node

```bash
ssh-keygen -t ed25519 -N "" -f /root/.ssh/id_ed25519   # skip if you have one
ssh-copy-id root@10.0.0.9     # the backup node - REQUIRED
ssh-copy-id root@10.0.0.32    # each compute node
ssh-copy-id root@10.0.0.33
```

The storage-to-backup path is the one nothing works without: the container
configs, the copies' status, the cluster's node names and the data itself all
go through it.

### 4. On the backup node — this is the slave

```bash
cd /root/ketsync
cp ketsync.conf.sample  ketsync.conf     # KS_ROLE=slave, KS_MASTER_IP=<the storage node>
$EDITOR engines/tp/ctrep.conf            # BW_TOTAL_MB for THIS machine's link
./ketsync doctor                          # builds nodes.map here
```

Do not copy the tables here. `ketsync sync` sends them. Do not copy
`ketsync.conf` from the master either — it carries `KS_ROLE`, and one copy of
it on every machine makes every machine believe it may write.

Also give the backup node an ssh key to each compute node, and each compute
node a key back to the backup node. `distribute` issues its transfer on the
target, pulling from the backup node, and it checks that path before it
allocates anything.

### 5. Fill in the tables, then push them

`fleet.tsv` — four columns, all required, no defaults:

```
# ct		home		dr		dst
110	10.0.0.32	10.0.0.32	local-lvm
120	10.0.0.33	10.0.0.33	local-lvm
```

`home` is the compute node that normally runs it. `dr` is where it goes when
the storage node is gone — usually the same machine, because what died is the
disk and not the CPU. `dst` is the storage on that machine, spelled exactly as
`pvesm status` there spells it.

`engines/tp/inventory-replica.tsv` — which containers get copied, and to which
pool on the backup node:

```
# src_ctid	[tgt_ctid]	[storage-assert]	[dest]
110					replica-hdd
120					replica-hdd
```

Then, on the master:

```bash
./ketsync doctor         # says what is not wired up yet, touches nothing
./ketsync sync           # pushes the tables to every node that has a ketsync
```

### 6. Prove it on one unimportant container, then add cron

```bash
./ketsync replica --dry-run --ctid 110   # every guard runs, nothing is written
./ketsync replica --ctid 110             # for real, one container
./ketsync replica --storage tank-hdd-nas # a whole lane
```

```cron
*/15 * * * * /root/ketsync/engines/tp/ct-replica.sh --storage tank-hdd-nas
*/15 * * * * /root/ketsync/engines/tp/ct-replica.sh --storage tank-ssd-nas
```

One lane per storage, because the bandwidth ceiling is per lane.

---

## Day to day

```
what you want                              what you type
---------------------------------------------------------------------------
copy every container to the backup node    ./ketsync replica --storage <id>
see how the last run of each one went      ./ketsync status
check everything is still wired up         ./ketsync doctor
edited a table, send it to everyone        ./ketsync sync
```

**`sync` is not automatic.** Edit a table on the master and push it yourself,
or the backup node holds last month's list and nothing says so.

If `sync` prints **FORKED**, two machines hold the same generation number with
different contents — the normal state of a fleet that has never synced, since
every install starts at the generation its `.sample` shipped with. It stops
and sends nothing, because there is no version to prefer:

```bash
./ketsync sync --diff                    # what differs, read only
$EDITOR <the file>                       # make this machine's copy the right one
./ketsync sync --bump <the file>         # "mine is the one" - raises and pushes
```

Name the file. `--bump` on its own settles every forked file at once, which is
only what you want if you read every diff.

Logs are all in `logs/`, one file per verb per day: `ketsync-`, `migrate-`,
`replica-`, `failback-`, `distribute-`. One directory to read, one tarball to
send.

---

## When the storage node dies

The full runbook is `docs/disaster-recovery.html`. The shape of it:

```
1  stop production coming back by itself
     pct set 110 --onboot 0                     on each compute node
     distribute refuses until this is done - a container with onboot 1 starts
     ITSELF the moment the storage node returns, and then two machines hold
     one IP, each writing a rootfs that can never be merged with the other

2  put the copies where there is CPU
     ./ketsync distribute --list                # what would go where
     ./ketsync distribute --all                 # do it
     pct start 9110                             # by hand, per container

3  keep the DR data backed up WHILE it serves
     ./ketsync recall --all                     # 9110 -> 8110, repeatable
     run it as often as you like. Until you do, the only copy of everything
     the customer has done since the outage is on one compute node's local
     disk, with nothing replicating it

4  the storage node comes back
     touch engines/tp/PAUSE                     on the storage node
     ./ketsync recall --all                     # keep narrowing the gap
     ./ketsync failback --all                   # 8110 -> the production image
     both are presync tools: run them repeatedly while 9110 still serves, and
     watch changed= stop shrinking

5  cut over
     pct shutdown 9110
     ./ketsync recall --ctid 110 --final
     ./ketsync failback --ctid 110 --final
     pct set 110 --onboot 1
     pct start 110

6  clean up, or the next disaster collides with this one
     pct destroy 9110                           frees R13, which has been
                                                holding replica off 8110
     rm engines/tp/PAUSE
```

Everything routes through the backup node rather than going compute-to-storage
directly, and that is deliberate: it keeps a second copy of the DR data at
every moment, and it lets the final write into the production image go through
`failback`, which already takes a safety snapshot first.

`distribute` and `sync` can both be driven **from the backup node**, which is
the point — the machine that normally drives replication is the machine that
died. `replica`, `failback` and `migrate` cannot: all three read or write the
raw images, and those live on the storage node.

---

## What it will not do

**It does not fail over by itself.** `KS_ROLE` is changed by hand. Two machines
cannot tell "the master is dead" from "I cannot reach the master", and being
wrong means two machines running `rsync --delete` into one dataset. What *is*
automatic is that every machine has a current copy of the tables, so any of
them can take over in seconds.

**It does not choose where a container goes during a disaster.** The `dr`
column decides, written down in advance. `--to` overrides it on the day. A
container with neither is refused rather than placed somewhere reasonable.

**It does not fall back to a default storage.** A fleet is not homogeneous —
one node's local storage is `local-lvm` and another's is `local-zfs` — so a
row without a `dst` is refused by name rather than allocated somewhere nobody
chose.

---

## Developing

```bash
make lint       # bash -n, shellcheck, the language rule, the separator rule
make test       # 305 simulator scenarios + 21 for ketsync sync, plus c2v
make mutation   # 279 known bugs put back one at a time; none may survive
```

Every engine runs against a **simulator**: the real script, in a sandbox, with
fake `pvesm`, `pct`, `zfs`, `ssh` and `rsync`. Several of those fakes refuse to
pretend and record a VIOLATION instead — a double loop-mount, an rsync into a
directory that was never a mountpoint, a config written before a good
transfer, a container started at all. A scenario can fail two ways: wrong
observable behaviour, or a broken invariant. The second is the one that
matters.

`make mutation` breaks each engine one line at a time and checks the scenarios
notice. A green test suite means nothing until you have watched it go red for
the right reason — and every mutation in there is a bug somebody could really
write. Several are bugs that were really written, kept so the suite can prove
it would catch them again.

Read `CLAUDE.md` and `engines/tp/CLAUDE.md` before changing anything. The rules
in them are short and each one is there because getting it wrong had a cost
that is not obvious from the code.

## Where everything is

```
ketsync                      the dispatcher. No logic of its own
lib/                         one file per subcommand
engines/tp/                  the five engines that move data
docs/start-here.html         the operator's front door (Thai)
docs/infrastructure-setup.html   build it from nothing (Thai)
docs/disaster-recovery.html  the storage node is dead (Thai)
docs/c2v-el.html             convert a CT to a VM, EL guests (Thai)
docs/c2v-debian.html         the same, Debian/Ubuntu guests (Thai)
docs/decisions.md            why it is shaped this way, and what is not built
tests/                       the decision layer's simulator
```

The operator guides are Thai because the operators are Thai. Everything else —
code, comments, commit messages, this file — is English.
