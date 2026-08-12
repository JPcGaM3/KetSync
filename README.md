# ketsync

Three guides, all in Thai, all written to be followed rather than studied:

- **[`docs/infrastructure-setup.html`](docs/infrastructure-setup.html)** —
  building it from nothing: the cluster, the ssh paths, the storages, the
  isolated bridge, PBS, and then this. Fourteen steps, each with a way to check
  it worked. Read it when you are setting a machine up, and only then.
- **[`docs/start-here.html`](docs/start-here.html)** — running it day to day.
  Which file is which, and what to type in what order. **Start here** if the
  system is already up: it is the only one of the three you need to have read.
- **[`docs/disaster-recovery.html`](docs/disaster-recovery.html)** — the storage
  node is dead. Read it once on an ordinary day, then again while it is
  happening: it carries the one step on the way back that loses data if it is
  skipped.

Everything below is the summary.

The layer above [`tp`](engines/README.md). `ketsync` decides who does what and
where; `tp` does it, with the guards it already has.

One command covers both layers. You should not have to know that
`engines/tp` exists to run a replica round.

```
ketsync migrate      old node -> a raw image here          -> tp
ketsync replica      live image here -> copy on the backup -> tp
ketsync failback     promoted copy -> back into production -> tp
ketsync status       the last run of every container       -> tp
ketsync tp <...>     anything else, straight through       -> tp

ketsync sync         push the tables to every node in nodes.tsv
ketsync role         who this machine thinks it is
ketsync doctor       the cross-checks nobody remembers to run, both layers
ketsync distribute   DR: a copy -> a compute node's own storage      -> tp
ketsync recall       the return trip, once the storage node is back     (stub)
```

tp's commands are passed through untouched — same flags, same guards, same
exit codes. This layer adds nothing to them and must never start to.

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

Everything you type is an IP. `nodes.tsv` is an address and a role, with no
name column, and nothing here resolves a hostname — which is what lets it run
from a machine that is outside the cluster on purpose and therefore has neither
its `/etc/hosts` nor its DNS. PVE node names are still needed to write a guest
config; they are discovered from the cluster and cached in `nodes.map`, which
nobody edits.

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
`fleet.tsv` does, written down in advance; `--to` overrides it on the day, and a
container with neither is refused rather than placed somewhere reasonable.

## What is in here

```
ketsync              the dispatcher, and lib/ behind it — the decision layer
engines/tp/          the four engines that do the moving, committed in full
docs/infrastructure-setup.html   build it from nothing, in Thai
docs/disaster-recovery.html      the storage node is dead, in Thai
docs/start-here.html the operator's front door, in Thai
docs/decisions.md    why it is shaped this way, and what is not built yet
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
make test       # engines/tp: 221 simulator scenarios, the dispatcher, c2v, python
make mutation   # 165 known bugs put back one at a time; none may survive
```

`make -C engines/tp test-replica` and friends still work if you want one engine.

## Status

`sync`, `role`, `doctor`, `distribute` and every tp command work. `recall` is
still a stub that says so and exits 2 — a command that half works is worse than
one that admits it does not, especially the one you reach for during a DR.

`engines/tp` is tested hard. `ketsync` itself is not tested at all: `tests/`
is empty, and that is a debt rather than a decision. `make test` says so on
every run. Read `tests/README.md` before adding anything here that writes to a
real machine.

The design, and the arguments behind it, are in `docs/decisions.md`.
