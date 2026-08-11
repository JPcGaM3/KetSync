# ketsync

**New here? Open [`docs/start-here.html`](docs/start-here.html) first.** One
page, in Thai: which file is which, what goes on which machine, and what to
type in what order. Everything below is the summary.

The layer above [`tp`](engines/README.md). `ketsync` decides who does what and
where; `tp` does it, with the guards it already has.

```
ketsync sync         push config + inventory to every node in nodes.tsv
ketsync role         who this machine thinks it is
ketsync distribute   DR: put a copy onto a compute node and hand over   (stub)
ketsync recall       the return trip, once the storage node is back     (stub)
ketsync status       every container: where it is, where its copy is    (stub)
ketsync doctor       the cross-checks nobody remembers to run
```

## Why it exists

One storage node holds every container's disk. When it dies, the containers
cannot run, the machine that normally drives replication is the machine that
died, and the backup node cannot run everything at once. The copies have to be
spread across the compute nodes, keep being replicated while they run there,
and come home afterwards. That is placement and coordination — a different
problem from moving the bytes, which `tp` already solves.

## Getting started

One repo, one clone. `engines/tp` is committed here, so there is no second
checkout and no submodule to forget.

```bash
git clone <this repo> /root/ketsync && cd /root/ketsync

cp ketsync.conf.sample  ketsync.conf
cp nodes.tsv.sample     nodes.tsv
cp fleet.tsv.sample     fleet.tsv
$EDITOR nodes.tsv          # every address this machine will ever use
./ketsync doctor           # says what is not wired up yet
```

`nodes.tsv` is the only place a PVE node name becomes an address. Nothing here
resolves a hostname, which is what lets it run from a machine that is outside
the cluster on purpose.

## What it will not do

It does not fail over by itself. `KS_ROLE` is changed by hand, because two
machines cannot tell "the master is dead" from "I cannot reach the master", and
being wrong about that means two machines writing into one dataset. What is
automatic is that every machine always has a current inventory, so any of them
*can* take over in seconds.

It does not start containers. `distribute` moves the data and writes the
config, then prints the `pct start` for a human. Bringing a customer's service
back is a decision, not a step.

It does not choose where a container goes during a disaster. The `dr` column in
the inventory does, written down in advance; `--node` overrides it on the day.

## What is in here

```
ketsync              the dispatcher, and lib/ behind it — the decision layer
engines/tp/          the three engines that do the moving, committed in full
docs/start-here.html the operator's front door, in Thai
docs/decisions.md    why it is shaped this way, and what is not built
tests/               the debt
```

Three tables, and they are not interchangeable — that is why none of them share
a name any more:

```
fleet.tsv                          the map: which CT lives where, and where it
                                   goes when its home is gone
engines/tp/inventory-migrate.tsv   a work list: which CTs to move in
engines/tp/inventory-replica.tsv   a work list: which CTs to copy nightly
```

## The gates

```bash
make lint       # both layers: bash -n, shellcheck, the language rule, doc embeds
make test       # engines/tp: 181 simulator scenarios, the dispatcher, c2v, python
make mutation   # 120 known bugs put back one at a time; none may survive
```

`make -C engines/tp test-replica` and friends still work if you want one engine.

## Status

`sync`, `role` and `doctor` work. `distribute`, `recall` and `status` are
stubs that say so and exit 2 — a command that half works is worse than one
that admits it does not, especially the one you reach for during a DR.

`engines/tp` is tested hard. `ketsync` itself is not tested at all: `tests/`
is empty, and that is a debt rather than a decision. `make test` says so on
every run. Read `tests/README.md` before adding anything here that writes to a
real machine.

The design, and the arguments behind it, are in `docs/decisions.md`.
