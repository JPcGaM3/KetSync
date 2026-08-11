# tp — teleport

One command for every way a container moves in this fleet.

```
tp migrate     old standalone node  ->  raw image on the storage node
tp replica     live image here      ->  stopped copy on the backup node
tp failback    promoted copy        ->  back into the production image
tp status      what every CT's last run did, both engines, one table
tp doctor      the cross-checks nobody remembers to run
```

Every engine runs on the **storage node** and needs nothing installed: bash,
rsync, ssh and the PVE tools that are already there. No `jq`, no python.

## The three flows

**migrate** is one-way and has an end. It pre-syncs a container that is still
running on an old standalone node into a raw image here, as many times as you
like, then takes the last delta once you have stopped it. It writes the target
config on the new node with no network and `onboot: 0`, so the container cannot
come up behind your back. You add `net0` and start it by hand.

**replica** never ends. Every fifteen minutes it takes a ZFS snapshot of the
storage, reads each image out of the clone so every file in a round comes from
the same instant, and rsyncs it into a stopped copy on the backup node. Copies
land on `replica-ssd` or `replica-hdd` per CT, so a customer who must come back
fast is not queued behind one who does not care. The copy gets the source's
**real** network — same IP, same MAC, same VLAN — on a bridge with no uplink,
which is what lets you boot it for a drill while the real container is live.

**failback** is the reverse, and it only exists for the day you needed the copy.
It pre-syncs the promoted copy back into the production image while the copy is
still serving traffic, so the cutover window is seconds rather than the whole
rootfs.

## Looking before you leap

Every engine takes `--dry-run`, and it is the only safe first contact this tool
has with a fleet.

```bash
tp migrate  --ctid 251 --dry-run
tp replica  --storage tank-hdd-nas --dry-run
tp failback --all --dry-run
```

A dry run changes what is **written**, never what is **checked**. Every guard
still runs, in the same order, against the real machines — so you find out that
G1 would refuse, or that R9 has found an uplink on the isolated bridge, at your
desk rather than at 02:00. It prints the plan, not the absence of errors: which
image, how large it would allocate and why, which dataset it would write into,
the config it would create, and how much would actually move.

Two places it cannot answer, and says so rather than guessing. A `migrate` row
with no image yet has nothing to compare against, so it reports the sizing and
stops; and `replica` will not take the ZFS snapshot its point-in-time read
depends on, because a snapshot and a clone are named objects on live customer
storage — so it gives you the plan without a transfer estimate. `--stopped
--dry-run` is refused outright: `--stopped` needs `pct mount` on the old node,
which is a write on somebody else's machine.

Nothing is written under `state/` either, so `tp status` keeps showing the last
run that really moved something.

## Getting started

```bash
git clone <this repo> /root/tp && cd /root/tp
cp inventory-migrate.sample.tsv          inventory-migrate.tsv
cp inventory-replica.sample.tsv  inventory-replica.tsv
$EDITOR ctmig.conf ctrep.conf     # the machines and the bandwidth ceiling
./tp doctor                       # says what is not wired up yet
```

Then one cron line per lane:

```cron
*/15 * * * * root /root/tp/tp replica --storage tank-hdd-nas >/dev/null 2>&1
*/15 * * * * root /root/tp/tp replica --storage tank-ssd-nas >/dev/null 2>&1
```

The Thai operator guides are in `docs/`: `infra-setup.html` builds the whole
hybrid from scratch, `ct-replica-setup.html` installs the replica system, and
`ct-replica-manual.html` is the day-to-day plus the DR and failback runbooks.

## What the engines refuse to do

They do not touch container lifecycle. Nothing here starts, stops or reboots a
container, remaps an IP, or rolls anything back. When the lifecycle is wrong the
engine stops and says which command you should run — it never runs it for you.
Cutover and DR promotion are decisions with customers on the other end.

They also refuse rather than guess. A row missing a target node, a storage that
is not mounted, a copy that is running when it should not be, a bridge that
grew an uplink, an inventory that names one container twice: each of these
stops the run and prints what to fix. Silence and a green exit code are the one
outcome that is never acceptable, because under cron that is indistinguishable
from a healthy run.

## Development

```bash
make lint        # bash -n + shellcheck + the language and separator rules
make test        # 184 simulator + 16 dispatcher scenarios, 125 c2v, 82 python
make mutation    # 124 known bugs reintroduced: 117 in the engines, 7 in the dispatcher, all must be caught
```

`make mutation` is the target that matters. A green suite means nothing until
you have watched it go red for the right reason, so everything executable
here has a runner that breaks it on purpose — thirty-eight ways for migrate,
thirty-six for replica, thirty-six for failback, seven for the `tp`
dispatcher — and fails if the suites let any of them through. Every one of
those hundred and seventeen is a bug somebody could really write, and several
are bugs that were really written here.

Those three need a Debian userland. On a Mac run `make gates` instead, which
runs all three in a container with the repo mounted read-only. Do not run them
natively there and believe the result: macOS has no `flock`, and an engine that
cannot take its lock reports "another sync is running" and exits 0 — the suites
go red, but an engine run by hand looks like a healthy skip.

Read `CLAUDE.md` before changing anything. It is short, and every rule in it is
there because getting it wrong once was expensive. `docs/decisions.md` is the
longer companion: what the machines actually look like, which approaches were
already tried and rejected, and which incident produced which guard.

## Status

`ct-migrate.sh`, `ct-replica.sh` and both c2v paths — EL and Debian — are in
production against a real fleet and have been for a while.

`ct-failback.sh` **has never been run for real, not once.** It only exists for
the day the copies were needed, and that day has not come. It is the one engine
here that writes into a live customer's rootfs image rather than into a copy,
so treat its first run as an experiment with a human watching it: `--list`,
then `--dry-run`, then one container, and read the whole log before the second.

All of them are now anchored by a simulator and a mutation suite, which is what
makes the next job — extracting the shared library they currently duplicate —
something you can do without a fleet to test against. The plan and its
constraints are in `CLAUDE.md`.

Writing those suites found five real bugs, all of the same shape: something
learned once in `ct-migrate.sh` and lost when the newer engines were written.
The worst two were R4 running *after* `rsync --delete` had already emptied
another guest's rootfs, and a `cleanup_ct` that cleared its "still mounted"
flag even when the unmount had failed, so `resize2fs` ran against a mounted
customer image and the run reported success. That is the argument for the
shared library, stated as evidence rather than as a preference.
