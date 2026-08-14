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

**2a. A command that writes asks first, and a bare one refuses.** `-y` means
"I have already decided" and skips the question and nothing else; there is no
`--force` and there must not be, because a flag whose use case has to be
invented under pressure is a flag that gets used under pressure. No terminal
and no `-y` is a REFUSAL, not a quiet no: `read` on an empty stdin returns
immediately, and treating that as "no" would be a nightly cron reporting
success having done nothing. `--dry-run` and `--list` are never asked about,
or the answer gets trained. The question lives in the dispatcher because that
is where a person stands; cron calls the engines directly and is not prompted.

**2. Nothing decides who is master.** `KS_ROLE` is a line in a config file that
a human edits. Two machines cannot tell "the master is dead" from "I cannot
reach the master", and being wrong means two machines writing into one dataset.
Do not add an election, a heartbeat, or an automatic promotion. The full
argument is in `docs/decisions.md` section 2.

**3. Nothing starts a container.** `distribute` moves data and writes a config,
then prints the `pct start`. Same rule as every engine in `tp`.

`ketsync distribute` is the one verb this layer does not pass through: it runs
`ct-prepare.sh` first and `ct-distribute.sh` after, because deciding the ORDER
is what this layer is for. It adds no guard of its own and must not. What
makes preparing automatically safe is `ct-prepare.sh`'s own proof that the
storage is dead - against a healthy fleet the whole first half does nothing,
which is the property to keep.

**4. No defaults, no guessing, anywhere.** A node with no row in `nodes.tsv`
is a hard stop, never a guessed address. Placement comes from `fleet.tsv`'s
`dr` column, not from free RAM. There is no fallback storage and no default
destination pool - both were removed rather than tuned, because the row that
FORGOT a value looks exactly like the row that meant it, and what lands
somewhere nobody chose is a customer's only copy.

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

**7. A stub says it is a stub.** Do not make one half work. There are none
left: `distribute` stopped being one when `engines/tp/ct-distribute.sh` was
written, and `recall` when `engines/tp/ct-recall.sh` was, with 58/62 and 53/47
scenarios and mutations behind them - which is the bar for the next one.
`isolate`/`restore`/`evacuate` arrived at 50/46, deliberately smaller because
`ct-prepare.sh` moves no customer data: there is no transfer to tear, no
mountpoint to fill and no direction to invert, so the surface really is
smaller. Do not read it as the new bar. The helper that printed "designed but
not built" is gone with the last stub; bring it back with the next one rather
than keeping it warm.

**8. Nothing that writes to a real machine ships without a simulator.** Read
`tests/README.md`. `sync` has one - 21 scenarios and 19 mutations - and writing
it found three bugs that had been live on the fleet, none of which review had
caught. `distribute` has one too, 13 and 13, because it is the only verb here
that composes two engines and every joint between them is invisible from
inside either one. The confirmation has 15 and 14, and it needs its own
because its whole behaviour turns on whether there is a person on the other
end - the prompting half runs under a pty, and a pipe tests the refusal by
being one. `role` and `doctor` still do not, and that is the remaining debt. A
mutation that proves the simulator can fail is part of the simulator, not a
follow-up.

## Before you say you are done

    make lint     # both layers: bash -n, shellcheck, the language rule
    make test     # both layers: 372 tp scenarios + 49 for ketsync
    make mutation # 371 known bugs put back. None may survive

Never commit on red. If you touched an engine, `make mutation` is not optional
— that is the target that proves the suite can still fail.

`make test-ketsync` runs the sync simulator; `make mutation-ketsync` runs its
mutations. Both are part of `make test` and `make mutation` now - they stopped
being separate when they stopped being empty.

## Layout

    docs/index.html      which of the five guides to open. Every guide links
                         back to it, so a reader who lands anywhere can get out
    docs/infrastructure-setup.html
                         build the whole thing from nothing. Written for a
                         reader who does not do infra for a living: every step
                         has a way to check it worked, and every refusal in the
                         engines has a row in its troubleshooting table
    docs/disaster-recovery.html
                         the storage node is dead. Six stages, each with its
                         own command, and it says where the point of no return
                         is - nothing before stage 5 is irreversible
    docs/start-here.html the operator's front door. If you change what an
                         operator types, change it here too. Section 4 is the
                         master/slave sync setup - the part people got wrong
    docs/c2v-el.html     CT to VM, the EL path
    docs/c2v-debian.html CT to VM, the Debian/Ubuntu path
    ketsync              the dispatcher. Contains no logic of its own
    lib/common.sh        log, config, and the two tables everything reads
    lib/cmd_*.sh         one file per subcommand. cmd_distribute.sh is the
                         only one that composes engines rather than passing
                         through - the sequencing IS this layer's job
    ketsync.conf.sample  this machine's role and the master's address
    nodes.tsv.sample     ip -> role. No name column, on purpose
    nodes.map            ip -> PVE node name. GENERATED. Never hand-edited
    fleet.tsv.sample     ct, home node, dr node, dr storage. Four columns, all
                         required, no tier and no fallback. "inventory" always
                         means one of tp's work lists
    engines/tp/          the execution layer, five engines. Committed here
    docs/decisions.md    why it is shaped this way, and what is not built
    tests/sim/sync/      the sync simulator, and the pattern for the next one
    tests/sim/distribute/
                         the composed command: both engines are stubs that
                         record their argv, because the argv is the whole of
                         what the joins can get wrong
    tests/sim/confirm/   the question before a write, half of it under a pty
                         because there is no other way to test a prompt
    tests/mutation/      one mutation per guard, each proven to kill a scenario

`engines/tp` came from the standalone `tp` repo at commit `b4ddc0c` and is now
edited in place; there is no upstream to pull from. `engines/tp/CLAUDE.md`
governs everything beneath it and wins over this file wherever the two overlap.

## Style

Comments explain **why**, not what. The reader is somebody debugging a failed
failover under time pressure, who needs to know what a line is defending
against. Prose is plain: no marketing, no hedging, no bullet lists where a
sentence works.
