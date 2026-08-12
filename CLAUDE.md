# Working in this repository

Read this before you change anything. `ketsync` sits above `tp`, and the rules
that matter most here are `tp`'s — read `engines/tp/CLAUDE.md` too.

## What this is

`ketsync` decides **who** does **what** and **where**. `tp` does it.

Nothing in this repo may move customer data by itself. If you find yourself
writing an rsync here, stop: either it belongs in a `tp` engine where the
guards and the mutation suite are, or you are about to reintroduce a bug that
`tp` already caught once.

## The rules

**1. English everywhere.** Code, comments, commit messages, docs. The only
exception is Thai prose in operator guides, and never inside `<pre>` or
`<code>` — commands get pasted at 2am.

**2. Nothing decides who is master.** `KS_ROLE` is a line in a config file that
a human edits. Two machines cannot tell "the master is dead" from "I cannot
reach the master", and being wrong means two machines writing into one dataset.
Do not add an election, a heartbeat, or an automatic promotion. The full
argument is in `docs/decisions.md` section 2.

**3. Nothing starts a container.** `distribute` moves data and writes a config,
then prints the `pct start`. Same rule as every engine in `tp`.

**4. No defaults, no guessing.** A node with no row in `nodes.tsv` is a hard
stop, never a guessed address. Placement comes from the inventory's `dr`
column, not from free RAM. Guessing puts a customer on the wrong machine.

**5. Everything a human types is an IP.** PVE forces node *names* on us because
it stores configs under `/etc/pve/nodes/<name>/` — but nobody types one.
`nodes.tsv` is an address and a role. Names are discovered from the cluster via
the backup node and cached in `nodes.map`; the engines read `BKP_NODE` off the
backup node's own `/etc/pve/local`. Nothing here resolves a hostname, which is
what lets this run from outside the cluster. Do not add a name column back: a
name that is typed is a name that can be stale, and a stale one writes a guest
config into another member's directory.

**6. Every engine and command sets its own PATH.** cron gives you
`/usr/bin:/bin` and `pvesm`, `zfs` and `losetup` live in sbin. Check required
commands **before** taking any lock: `flock` missing reads as "the lock is
held", and the run exits 0 having done nothing.

**7. A stub says it is a stub.** `recall` exits 2 with a pointer into
`docs/decisions.md`. Do not make one half work. `distribute` stopped being a
stub when `engines/tp/ct-distribute.sh` was written, with 34 scenarios and 32
mutations behind it - which is the bar for the next one.

**8. Nothing that writes to a real machine ships without a simulator.** Read
`tests/README.md`. `sync` has one - 17 scenarios and 14 mutations - and writing
it found three bugs that had been live on the fleet, none of which review had
caught. `role` and `doctor` still do not, and that is the remaining debt. A
mutation that proves the simulator can fail is part of the simulator, not a
follow-up.

## Before you say you are done

    make lint     # both layers: bash -n, shellcheck, the language rule, embeds
                  # the language rule is enforced on BOTH docs/ trees now
    make test     # both layers: 221 tp scenarios + 17 for ketsync sync
    make mutation # 187 known bugs put back. None may survive

Never commit on red. If you touched an engine, `make mutation` is not optional
— that is the target that proves the suite can still fail.

`make test-ketsync` runs the sync simulator; `make mutation-ketsync` runs its
mutations. Both are part of `make test` and `make mutation` now - they stopped
being separate when they stopped being empty.

## Layout

    docs/infrastructure-setup.html
                         build the whole thing from nothing. Written for a
                         reader who does not do infra for a living: every step
                         has a way to check it worked, and every refusal in the
                         engines has a row in its troubleshooting table
    docs/disaster-recovery.html
                         the storage node is dead. Drives ketsync distribute,
                         says plainly that recall is still hand-work, and
                         carries the PAUSE-before-cron step that is the
                         difference between a recovery and a data loss
    docs/start-here.html the operator's front door. If you change what an
                         operator types, change it here too
    ketsync              the dispatcher. Contains no logic of its own
    lib/common.sh        log, config, and the two tables everything reads
    lib/cmd_*.sh         one file per subcommand
    ketsync.conf.sample  this machine's role and the master's address
    nodes.tsv.sample     ip -> role. No name column, on purpose
    nodes.map            ip -> PVE node name. GENERATED. Never hand-edited
    fleet.tsv.sample     ct, tier, home node, dr node, dr storage. The fleet
                         map - "inventory" always means one of tp's work lists.
                         Mirrored into engines/tp, which reads it during a DR
    engines/tp/          the execution layer. Committed here, edited here
    docs/decisions.md    why it is shaped this way, and what is not built
    tests/sim/sync/      the sync simulator, and the pattern for the next one
    tests/mutation/      one mutation per guard, each proven to kill a scenario

`engines/tp` came from the standalone `tp` repo at commit `b4ddc0c` and is now
edited in place; there is no upstream to pull from. `engines/tp/CLAUDE.md`
governs everything beneath it and wins over this file wherever the two overlap.

## Style

Comments explain **why**, not what. The reader is somebody debugging a failed
failover under time pressure, who needs to know what a line is defending
against. Prose is plain: no marketing, no hedging, no bullet lists where a
sentence works.
