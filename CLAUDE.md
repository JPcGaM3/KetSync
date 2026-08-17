# Working in this repository

Read this before you change anything. One tree, two layers: `ketsync` (bin/,
lib/) decides who does what and where; the engines (engines/) move the bytes.
The engine rules in the second half of this file win over the general ones
wherever they overlap — a bug down there corrupts a customer's container at
2am, and the rules are shaped by exactly that.

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
left: `distribute` stopped being one when `engines/ct-distribute.sh` was
written, and `recall` when `engines/ct-recall.sh` was, with 67/69 and 53/47
scenarios and mutations behind them - which is the bar for the next one.
`isolate`/`restore`/`evacuate`/`cleanup` arrived at 81/78, deliberately smaller because
`ct-prepare.sh` moves no customer data: there is no transfer to tear, no
mountpoint to fill and no direction to invert, so the surface really is
smaller. Do not read it as the new bar. The helper that printed "designed but
not built" is gone with the last stub; bring it back with the next one rather
than keeping it warm.

**8a. The guides carry the commands; every command block is collapsible and
copyable.** A runbook read at 3am is skimmed for the next thing to type, so
the commands fold away and the prose reads as a flow. `docs/how-it-works.html`
is the map and deliberately has no commands in it: two files holding the same
commands is one file going stale.

**8. Nothing that writes to a real machine ships without a simulator, and the
one command that writes nothing needed one anyway.** Read `tests/README.md`.
`sync` has one - 21 scenarios and 19 mutations - and writing it found three
bugs that had been live on the fleet, none of which review had caught.
`distribute` has one too, 15 and 14, because it composes two engines and
every joint between them is invisible from inside either one; `recover`, the
other composed verb, has 20 and 21 for the same reason - it is the seven-step
return checklist executed, and what it can get wrong is the order, what a
failed step may touch, and what may happen only when everything went green.
The confirmation has 17 and 16, and it needs its own because its whole
behaviour turns on whether there is a person on the other end - the
prompting half runs under a pty, and a pipe tests the refusal by being one.
`watch` has 17 and 16, and it is the suite where the assertions are MAILS:
watch's output arrives while nobody is at a terminal, so what its simulator
pins down is edge-triggering (a standing problem mails once), tiering (the
right address), suppression (one story told once), and
delivered-and-remembered-or-neither (a failed send keeps the state file
untouched, exits red, and skips the dead-man ping so the silence is heard).
`mail-setup` has 9 and 5: the verb is one boundary - conf keys in, satellite
argv out, exit code back - and its fake satellite records the argv, which is
the entire output under test.

`doctor` has 22 and 22, and it went last for the wrong reason: it writes
nothing, so nothing it does can corrupt anything. What it can do is stop
noticing, and a check that stops noticing prints exactly what a healthy fleet
prints. Writing the simulator found one immediately - a compute node nobody
could ssh to was reported as expected, months after evacuate, isolate,
distribute, recall and cleanup all started running over that connection. Its
mutations are the ones to copy from if you add a section: every assertion in
that suite is a line of output, which makes it the easiest suite here to write
badly, so each mutation silences exactly one check and requires the scenario
for it to notice.

`role` is the last one without a simulator, and that is the remaining debt. A
mutation that proves the simulator can fail is part of the simulator, not a
follow-up.

## Before you say you are done

    make lint     # both layers: bash -n, shellcheck, the language rule
    make test     # both layers: 419 tp simulator + 16 dispatcher + 125 c2v, 121 ketsync
    make mutation # 486 known bugs put back. None may survive

Never commit on red. If you touched an engine, `make mutation` is not optional
— that is the target that proves the suite can still fail.

On a Mac, run `make gates` instead: it runs all three in a `debian:bookworm`
container with the repo mounted read-only. Do not run them natively there and
believe the result. macOS has no `flock`, so `if ! flock -n 9` reads
command-not-found as "the lock is held" and `ct-migrate.sh` logs "another sync
is running" and exits 0 having done nothing; `ct-replica.sh` and
`ct-failback.sh` die even earlier, on `declare -A` under bash 3.2. `bash -n`
catches none of it, which is why `make lint` passes there and proves nothing.

## Layout

    bin/ketsync          the dispatcher, and the only thing a person runs.
                         ./ketsync at the root is a symlink to it
    lib/common.sh        log, config, and the two tables everything reads
    lib/cmd_*.sh         one file per subcommand. cmd_distribute.sh and
                         cmd_recover.sh compose engines rather than passing
                         through - the way into a disaster and the way back
                         out - because the sequencing IS this layer's job
    engines/             the six engines and their dispatcher `tp`. Every
                         guard that touches customer data lives here. Their
                         runtime (state/, logs/, done/, PAUSE) sits beside
                         them, gitignored
    conf/                every conf, table and sample in one place: ketsync.conf,
                         ctrep.conf and ctmig.conf (the engines' knobs - moved
                         here from engines/, and an engine finding a copy at
                         the old home REFUSES rather than ranking them),
                         nodes.tsv (ip -> role, no name column on purpose),
                         fleet.tsv (ct, home, dr, storage - all required, no
                         fallback), nodes.map (GENERATED, never hand-edited)
    inventory/           the per-site tables: inventory-replica.tsv (what
                         replica copies nightly), inventory-migrate.tsv (the
                         intake list) and bridgemap.tsv (c2v's old-bridge ->
                         new-bridge map), gitignored next to their tracked
                         samples. Same old-home refusal as the confs
    contrib/             one-shot tools, not the daily path: the three CT-to-VM
                         scripts, bkp02-setup.sh, add-storage-column.sh
    docs/th/ docs/en/    the operator guides, a numbered ladder mirrored in
                         two languages: 01-what-is-this, 02-install, 03-daily,
                         04-drill, 05-disaster-day, 06-reference, plus each
                         index.html. Thai is the source of truth; en mirrors
                         the structure page for page. If you change what an
                         operator types, change the ladder too. how-it-works
                         and the c2v manuals stay Thai-only appendices
    docs/decisions.md    why both layers are shaped this way: Part I the
                         decision layer, Part II the engines. Engine comments
                         cite "section N" meaning Part II's numbering
    docs/state-schema.md the state-file contract in prose; schema/ holds the
                         machine-checkable half
    tests/sim/<name>/    one simulator per thing that ships: ct-<engine> for
                         the six engines, verb names for the decision layer
    tests/mutation/      one suite per file under test, run-mutation-ct-* for
                         the engines. One mutation per guard, each proven to
                         kill a scenario
    tests/tp/ tests/c2v/ the engine dispatcher, and what the CT-to-VM
                         scripts write
    tools/               the repo's own police: the language rule and the
                         log-separator rule

The engines came from the standalone `tp` repo at commit `b4ddc0c` and are
edited here; there is no upstream to pull from.

---

# The engine rules

Everything below governs engines/ and its suites, and wins over the general
rules above wherever they overlap. It is short on purpose; everything in it is
here because getting it wrong has a cost that is not obvious from the code.

`tp` — teleport. Six engines that move **running production LXC containers**
around a real fleet, on a real schedule. There is no staging copy of the fleet.
A bug here does not fail a test — it corrupts somebody's container at 2am.

    tp migrate    old standalone node  ->  raw image on the storage node
    tp replica    live image here      ->  stopped copy on the backup node
    tp failback   promoted copy        ->  back into the production image
    tp distribute DR copy on the backup ->  a compute node's OWN storage
    tp recall     a compute node's 9<id> ->  back into its copy on the backup
    tp isolate    a production CT off the wire, and tp restore puts it back;
                  tp evacuate does a whole node; tp cleanup puts the 9<id>
                  away once the failback is done. The only engine that moves
                  no bytes: it writes a network and stops what cannot be left
                  up

Every engine runs on the **storage node**. The machines around it:

    old-node        a CT still lives here; migrate reads it, never touches it
    storage-node    where every engine runs; owns the raw images
    compute-node    mounts those images over NFS and runs the CTs
    backup-node     holds the stopped DR copies, and PBS

## The rules

**1. Every engine is anchored by a mutation suite.**
`tests/mutation/run-mutation*.sh` break each engine by matching **literal text**
from it. Move a line that a mutation anchors on and the mutation matches
nothing — which the suite reports as a *failure*, correctly, because a mutation
that cannot be applied has stopped proving anything. So: any edit to an engine
must be mirrored in its mutation file in the same change. Never "fix" a broken
anchor by deleting the mutation. If you are not confident you can do both
halves, do not touch the engine — say so instead.

    ct-migrate.sh    tests/mutation/run-mutation-ct-migrate.sh     49 mutations
    ct-replica.sh    tests/mutation/run-mutation-ct-replica.sh     58 mutations
    ct-failback.sh   tests/mutation/run-mutation-ct-failback.sh    60 mutations
    ct-distribute.sh tests/mutation/run-mutation-ct-distribute.sh  68 mutations
    ct-recall.sh     tests/mutation/run-mutation-ct-recall.sh      47 mutations
    ct-prepare.sh    tests/mutation/run-mutation-ct-prepare.sh     78 mutations
    tp               tests/mutation/run-mutation-tp.sh           9 mutations

A mutation the runner could not apply is not the only way this goes quiet.
Three mutations in the migrate suite were, for a while, perl programs that did
not compile: perl wrote nothing, the mutant was an empty file, an empty file
"kills" every scenario because it does nothing at all, and the suite printed a
green tick for a mutation that had never been applied. `mutant()` checks perl's
exit status and refuses a mutant that is empty or less than half the size of
the engine.

That sentence was written here while it was true of the migrate runner only.
The replica runner had neither check and the failback runner had no size check,
so this file described a safety net that two of the three suites did not have.
All three have both now, and each one exercises them on itself before it grades
anything: `self_check` feeds `mutant()` a program perl cannot compile and a
program that empties the engine, and refuses to run at all if either is
accepted. A guard nobody exercises is how this happened in the first place.

If you add a mutation, remember that a shell function's opening brace cannot
sit inside an `s{}{}` replacement — perl balances it against the closing
delimiter. Use a different delimiter.

**2. No Thai anywhere except `docs/th/*.html`.**
Code, comments, commit messages, test names, briefs: English. The operator
guides are Thai because the operator is Thai — that is the only exception, and
inside them Thai belongs in the prose, never inside `<pre>` or `<code>`.
Commands are copied and pasted at 2am; they have to survive that.

**3. Nothing here starts a container, and nothing creates one.**
No rollback state machine either. Cutover, DR promotion and the return trip are
decisions made by hand, on purpose, by somebody looking at the machine. The
engines refuse to run when the lifecycle is wrong (`--stopped`, B1, B2, R2,
D1) — they never fix it themselves. Bringing a service back is a decision with
a customer on the other end: `distribute` prints the `pct start` and stops
there, and that has not moved.

This rule used to say "no shutdown", "no IP remap" and "no destroy" too.
`ct-prepare.sh` took all three, deliberately: `--isolate` moves every net line
of a RUNNING production container onto `MOCKNET_BRIDGE`, `--evacuate` shuts
containers down, and `--cleanup --destroy` removes a `9<id>` once its data is
home. They are allowed for the same reason, and it is not convenience — it is
that at two hundred containers the alternative is a person typing the same
command two hundred times at four in the morning, and being right every time.

The destroy is the narrowest of the three and stays that way. Only a `9<id>`,
whose number is worked out from `DR_OFFSET` rather than typed; only with
`--destroy`, because stopping is reversible with one `pct start` and this is
not; and only after K2 has read `ct-failback`'s own state file and found a
`--final` round that finished ok, which is the proof the production image
holds the newest data. Without the flag `--cleanup` stops the `9<id>` and
moves it onto `MOCKNET_BRIDGE` instead, which removes the collision and keeps
the fallback. Note what that costs and say it out loud: R13 keys on the
config EXISTING, so a kept `9<id>` holds replication for that container until
somebody destroys it.

What makes it safe is the proof, not the intent. P2 and E2 refuse unless the
container's rootfs storage is PROVABLY dead: a `stat` on its mountpoint, on
the node that mounts it, that blocked until a timeout killed it. A storage
that answers is a hard refusal with no override. Run against a healthy fleet
these modes do nothing at all — which is the property to preserve. P5 refuses
to overwrite the record of where each interface came from, and E4 isolates a
container that will not stop rather than forcing it, because there is no rung
above asking.

Do not extend the carve-out to a third verb without the same kind of proof,
and do not weaken the proof to make a mode more useful.

**4. A copy never reaches the wire by accident.**
`migrate` writes the target config with the source's net lines moved onto the
island bridge and `onboot: 0` — the same island replica uses, so go-live is a
bridge swap instead of retyping a MAC. G8 verifies the island on the NEW node
before any transfer, and a net line with no `bridge=` refuses the row rather
than being dropped; `MOCKNET=0` in ctmig.conf restores the old no-net shape.
`replica` gives the copy the
source's **real** network — same IP, same MAC, same VLAN — on an isolated
bridge with no uplink. Both are the same rule from different directions: two
copies of one host must never be reachable at once. R9 verifies the bridge has
no uplink before every run, and R11 warns when a promoted copy was never put
back. Do not weaken either.

`distribute` is the third direction and the only one that puts a container ON
the wire deliberately, because a `9<id>` is placed in order to answer. It takes
its net lines from the **production** container's config rather than the copy's
— the copy's bridge is the isolated one by design — and it may, because D1 has
already established that production cannot answer. Nothing starts, so a wrong
bridge costs a command and not an outage.

When that production config also says `MOCKNET_BRIDGE`, the real bridge comes
from ct-prepare.sh's isolate record, which was written before anything moved.
This is the normal case rather than the exception: `ketsync distribute`
isolates before it places, so during a real DR every container arriving at D6
has the isolated bridge in its config, put there minutes earlier by this same
toolchain. The record has to say it is about this container and has to name
something that is an interface name, or it is treated as absent.

What it never does is invent one. A container somebody moved onto
`MOCKNET_BRIDGE` by hand has no record, nothing can reconstruct where it came
from, and the run says so instead of guessing.

**5. Nothing has a default. Not `new_node`, not `storage`, not a dest.**
A row missing one is an ERROR - the inventory ones refuse the whole file,
naming the line. There is no `DEFAULT_DEST` any more and there must not be a
next one: it was the last fallback here, and what it did was make the row that
FORGOT its pool look exactly like the row that meant it. `AUTO_DISCOVER` went
with it - replicating a container that has no row means guessing where its
copy goes, and there is nothing left to guess with.

**6. No `jq`, no guaranteed `python3` in the engines.**
Proxmox ships neither. The engines depend on neither and their state files stay
`grep`-readable — which is what let `ketsync doctor` start reporting how old
each DR copy is with a `sed`, months after the files were designed. There used
to be a python reader under `src/ctmig/` with its own test suite; nothing ever
depended on it and it is gone.

**7. Paths are relative to the script.**
`inventory*.tsv`, `state/`, `logs/`, `done/` are all found relative to where the
script lives. Never hard-code an absolute path. The two exceptions are
deliberate and commented in place: `MNT_BASE` (a live loop-mount must not sit in
a folder somebody can move) and the ssh control sockets in `/run` (tmpfs, so a
crash cannot leave a stale one behind).

**8. Every engine sets its own PATH, and checks its tools BEFORE the lock.**
cron hands a script `PATH=/usr/bin:/bin`, and `pvesm`, `zfs`, `losetup` and
`e2fsck` all live in sbin. An engine that inherits cron's PATH does not fail
cleanly — `pvesm` comes back empty and the result looks exactly like a storage
that was never configured. Set it at the top, next to `set -uo pipefail`.

The required-command preflight has to run **before** the lock, and the order is
the whole point. `flock -n 9` on a host with no flock is command-not-found,
which is a non-zero exit, which is indistinguishable from "somebody else holds
the lock" — so the engine says it is skipping and returns 0. A missing tool
producing a green run is the one outcome this repo refuses everywhere else, and
for a while the check that would have named the missing tool sat below the lock
where it could never fire. List local commands only: `pct` runs on the old node
over ssh, and requiring it here would refuse a perfectly good storage node for
not being a compute node.


Each simulator runs the real engine in a sandbox with fake `pvesm`, `pct`,
`zfs`, `ssh`, `rsync` and friends. Several of those fakes refuse to pretend and
record a violation instead — a double loop-mount, a resize of a mounted image,
an allocation into a pool on the root filesystem, an rsync into a dataset that
is not mounted, an rsync into a copy that is running, a read of the live
dataset instead of the point-in-time clone. A scenario can therefore fail two
ways: wrong observable behaviour, or a broken invariant. The second is the one
that matters. If you need a new scenario, add it there rather than mocking at a
higher level.

All three engines set their own PATH (rule 8), so no simulator can reach its
fakes by prepending a directory — each `run_engine` exports shell *functions*
instead, which bash resolves before PATH. Two things to know if you add a fake:
it must be shimmed *and* listed in `export -f`, and a dotted name like
`mkfs.ext4` is legal but has to be exported on a line of its own. Leaving one
out is silent — the engine falls through to the real binary if the host has
one, and the scenario stops testing anything.

There is one invariant that is not per-scenario. `run_engine` reads the
engine's own arguments, and when it sees `--dry-run` it exports `SIM_DRY=1`.
Every fake that would change the fleet then calls `dry_forbids` from its
`lib.sh` and records a violation instead of pretending. It is derived from the
invocation rather than set by the scenario on purpose: every dry scenario is
policed, including the ones written by somebody who never read this file, and a
write that gets added later is caught the first time it runs rather than the
first time a human thinks to assert on it. It found a real bug the first time
it was armed — `ct-failback.sh --dry-run` was loop-mounting production images
read-write, in three images at once, and the scenarios had never noticed
because they assert on the image's *content* and a journal replay does not
change content. So: a new fake that writes anything needs a `dry_forbids` line,
and a dry run may mount only `ro`.

## Invariants the tests exist to protect

`ct-migrate.sh` — G1..G8:

    G1  the storage pool must not sit on the node root filesystem, checked
        BEFORE anything is allocated. If PVE declares is_mountpoint for that
        storage, the declared path must really be mounted too.
    G2  refuse to sync into a container already running on the new node
    G3  the image must be unmounted before any resize, ENOSPC retry included
    G4  ENOSPC grows the image 5% and retries, three times, then fails clearly
    G5  the target config is written only after a good sync (rc 0 or 24)
    G6  an existing target config is never overwritten, only reported
    G7  the new_ctid must be free on the new node, or already own exactly the
        volume this row would write
    G8  the net lines land on MOCKNET_BRIDGE, which must exist on the NEW
        node and reach no wire - R9's question asked per target, cached per
        node, BEFORE the transfer; and a net line with no bridge= refuses
        the row instead of being silently dropped

`ct-replica.sh` — R1..R13:

    R1   point-in-time source: snapshot + clone, read the images from the clone
    R2   never rsync into a copy that is RUNNING (DR was promoted)
    R3   the destination dataset must report mounted=yes
    R4   the target VMID must not belong to another guest in the cluster,
         checked BEFORE anything is transferred. R2 only sees a copy that is
         RUNNING on the backup node and R8 only reads that node's own config
         directory, so a STOPPED guest on ANOTHER node is invisible to both -
         and rsync --delete would empty its rootfs. This is G7, restated
    R5   config written only after rc 0/24, then read back and compared
    R6   loop-mount ro,noload - no journal replay, no writes into the clone
    R7   one lock per lane; snapshot names carry the lane
    R8   an existing copy config must agree with the row's dest
    R9   the mock bridge must have NO uplink - checked once, refuses the run.
         It asks OVS for the bridge's IFACES, not its ports: an OVS bond is
         one port with no kernel netdev of its own, so a bridge uplinked by a
         bond answers `list-ports` with a name that has no /device and no
         /bonding, and reads as an island while it reaches the wire
    R10  one run at a time per target copy ("all" overlaps every storage lane)
    R11  a stopped copy must not sit on a production bridge
    R12  a whole source storage being down is ONE fact, not one per CT: its
         containers are SKIPPED, said once, and the run still refuses to exit
         0. It clears itself when the storage returns - which is the whole
         difference from pause/<ctid>, which a human has to undo
    R13  a live 9xxx placement means the DR copy is the last data from before
         the outage and the NEWEST data is somewhere else. R2 does not shield a
         DR copy - it is stopped by design - and PAUSE cannot help, because the
         storage node dies with no warning and the file lives on the machine
         that died. So the copy is left alone while ct-distribute.sh's 9<id>
         config exists anywhere in the cluster. Per-container, so the ones that
         never moved keep being replicated; it clears itself when somebody runs
         the `pct destroy 9<id>` the DR guide already ends with; and the run
         refuses to exit 0 while it is true
    R14  the copy is locked on the machine that HOLDS it. R7 and R10 are local
         flocks and settle nothing between machines, and more than one machine
         writes into a copy - during an outage distribute and recall are driven
         from the backup node, because the machine that normally drives
         replication is the machine that died. `set -C` on
         /run/ketsync-ct-<vmid>.lock over ssh; the destination's kernel picks
         the winner. An unanswered destination is refused, never treated as
         free. Nothing breaks a lock it does not own, and a release only
         removes a file that still says it is ours. Same code, same file, in
         ct-failback.sh (B8) and ct-distribute.sh (D8) - it is ONE lock and
         three engines disagreeing about it would be worse than none.
         docs/decisions.md section 2

`ct-failback.sh` — B1..B6:

    B1  the production CT must be STOPPED, and unreachable counts as not stopped
    B2  presync needs the copy RUNNING (R2 shields it), OR stopped with its
        9<id> live somewhere in the cluster (R13 shields it, and that is the
        shape a real disaster here takes - nobody promotes the copy at all).
        --final needs it STOPPED *and* PAUSE present, because R2 stops
        shielding the moment it goes down
    B3  the image must live on a mounted filesystem, never the node root
    B4  the image must already exist - a missing one is a rebuild, not this
    B5  verified mountpoint before rsync; unmount before any resize
    B6  ENOSPC grows the image rather than stranding the failback
    B0  not a guard, a prerequisite: B1 has to find out whether a CT on a
        production node is stopped, and this engine runs on the storage node,
        which is outside the cluster. It asks that node DIRECTLY, over ssh,
        with `pct status` - which needs no quorum, no pvedaemon proxying and
        no cluster membership, and therefore keeps working against a
        standalone node or a node in another cluster. The address comes from
        nodes.map, because PVE hands us a NAME and this host has neither the
        cluster's /etc/hosts nor its DNS.

        This paragraph described the opposite for a while. There was a version
        that asked the backup node over the cluster API instead, and this file
        still said "the only ssh path failback needs is the one to the backup
        node" and that the simulator recorded a violation for ssh to any other
        host, months after both had been reverted. The API version was the
        narrower design: it can only answer for members of its own cluster.
        Nothing is more expensive than a CLAUDE.md that describes a design
        somebody already decided against. `--list` reports what it could not
        resolve and exits 1 rather than 0
    B7  --final refuses when the safety snapshot cannot be taken. That
        snapshot is the only way back from a round that overwrites the
        production image, and every other guard here refuses rather than
        warns; this one used to be the exception. --no-snapshot is the way
        past it, typed by hand by somebody who read the refusal
    B8  the copy is locked on the machine that HOLDS it, not on this one. The
        local lock here is keyed on the production id and ct-replica's on the
        copy id, so even on one machine those two never excluded each other -
        and this engine READS a copy that ct-replica writes. R14, same code,
        same file

`ct-distribute.sh` — D1..D8:

    D1  the production container must not be able to ANSWER, and must not be
        able to start answering later. Unreachable refuses (unverified is not
        stopped). `onboot: 1` refuses - a container that is stopped today and
        boots itself when the storage node returns puts two machines on one
        IP, each writing a rootfs that can never be merged with the other -
        and that question is asked only of a container that is DOWN.
        Running refuses too, with one exception: every veth it has is
        enslaved to MOCKNET_BRIDGE and that bridge has no uplink on that
        node, all of it read from the KERNEL rather than from a config that
        can record a change nothing applied. Fewer veths than the config's
        net lines is unverified, and unverified refuses. On an Open vSwitch
        node the kernel cannot answer at all - every port of every OVS bridge
        is enslaved to one datapath device called ovs-system - so the probe
        asks ovsdb as well and the ENGINE picks between the two answers.
        Putting that choice in the remote snippet instead would put it where
        no simulator and no mutation can reach it. An unanswered ovsdb leaves
        ovs-system in the message, which is not a bridge name, so the
        container is refused and the operator can see why. The exception exists
        because the container this guard refuses is usually one whose NFS
        rootfs vanished: its processes are in uninterruptible sleep, SIGKILL
        does not reach them, `pct shutdown` hangs, and the one remedy left
        needs nothing from the dead storage. Accepting says out loud that it
        is still a PENDING WRITER - blocked now, writing again the instant
        the storage returns - and B1 refuses the failback until it is down
    D2  the source copy must exist on the backup node and be STOPPED
    D3  9<id> must be free everywhere: no config anywhere in the cluster and
        no volume already allocated. G7/R4 again
    D4  the destination storage must be ACTIVE on the target and must not sit
        on the node root filesystem. The Status column is the WORD pvesm
        prints, not a boolean - comparing it against 1 passed every scenario
        and refused every storage on the fleet
    D5  free space is checked BEFORE anything is allocated. A thin pool that
        fills can go read-only and take every container on that node with it
    D6  the config is written only after a good transfer, then read back
    D7  nothing is started, ever
    D8  9<id> is locked on the TARGET, before D3 is asked. The run lock here
        is a flock on the machine typing the commands and everything this
        engine does happens elsewhere - during a DR it is driven from two
        machines on purpose. R14, same code, same file

`ct-recall.sh` — C1..C8:

    C1  the 9<id> is found by asking the CLUSTER, never from a typed argument.
        pmxcfs is shared, so one ls through the backup node names the holder
    C2  the copy must be STOPPED. A running one was promoted by somebody, so
        two rootfs are taking writes and which is real is a human's decision
    C3  direction comes from PROVENANCE, not timestamps. ct-distribute wrote a
        marker naming the container and the copy this 9<id> came out of; rsync
        preserves mtimes, so the copy's files can be newer on disk while
        holding older data. No marker, no run - see docs/decisions.md section 6.
        The config is DECODED first: a `#` line in a guest config is the
        description field, PVE owns it, and PVE re-emits it URL-encoded on
        every write - `:` becomes %3A the first time anybody starts or stops
        the container
    C4  presync needs the 9<id> RUNNING, --final needs it STOPPED. A stopped
        one without --final is refused: "it is down right now" and "we are
        cutting over" are different intentions. No PAUSE requirement, because
        R13 keys on the config existing rather than on it running
    C5  the destination dataset must report mounted=yes. R3, restated
    C6  a real, already-mounted filesystem before rsync, and WHOSE mount it is
        depends on the container's state. RUNNING and block-backed: the
        container's own, at /proc/<pid>/root, because LXC already has that
        device mounted rw and ext4 refuses to add a ro mount of it - which is
        how this failed on the fleet, on the first real presync round.
        STOPPED: the device is nobody's, so mount it ro,noload. zfspool: the
        storage's own mount, never mounted or unmounted by this engine.
        rsync carries -x, because the running path is a mount namespace
    C7  nothing is started, stopped or destroyed. `pct destroy 9<id>` is what
        releases R13, and releasing that on unchecked data cannot be undone
    C8  BOTH ends locked where they live, 9<id> first then 8<id>. The only
        engine here that holds two, so it fixes the order. R14, same code

The order matters in all five. G1 runs before allocation for a reason, G7 runs
with G2 before anything is transferred, B1 runs before anything is mounted, D8
runs before D3 because an answer nothing holds still is not an answer, and C3
runs before anything is mounted because a direction nobody established is the
one mistake in this repo with no way back.

Two things that are not guards but fail a run for the same reason — a silent
success is worse than a loud failure:

    a config that does not read back as what was sent is `cfg_write`, not a
    warning: G6/R5 will never rewrite it, so a truncated config is permanent
    and every later run would call that CT healthy.

    a filter (`--storage`, `--ctid`, `--dest`) that matches no row at all exits
    non-zero. Under cron, exit 0 with no work done looks exactly like a healthy
    run.

rsync exit codes: 0 is success, **24 is also success** — files vanished
mid-sync, which is normal when the source container is live. 23 is a partial
transfer and is a failure; once is usually the ro,noload transient, twice in a
row on the same CT is a damaged image. 11 is out of space and triggers G4/B6.


## The shared library (not written yet — read this before you start it)

The three engines duplicate roughly nineteen functions between them: `log`,
`hsize`, the rsync stats parser, the JSON escaper, the whole `st_*` state
block, the lock helpers and `safe_umount`. Four bugs found in `ct-replica.sh`
during one session existed verbatim in `ct-migrate.sh` and had to be fixed
twice. That duplication is the reason this repo exists.

The plan is `lib/` — `common.sh`, `ssh.sh`, `xfer.sh`, `state.sh`, `lock.sh`,
`guards.sh` — sourced by each engine, with the flow and its guards staying in
the engine where they can be read top to bottom.

Two things to respect when it is done:

  - **Do not flatten the guards into one function with mode branches.** The
    order of the guards is the safety design, and it genuinely differs by
    direction. Three ordered sequences that each read straight down beat one
    sequence with `if MODE` in it.
  - **All three are anchored now, so all three cost the same to move.** Every
    mutation anchors on literal text inside its engine; moving a line into a
    lib function moves the anchor. Both halves in the same change, green suites
    before the commit. Port `ct-replica.sh` first anyway — it is the one whose
    duplication was measured — and do `ct-migrate.sh` last, because the fleet
    has been running against it the longest.

`tp doctor` reports the one thing the split still costs today: `ctmig.conf` and
`ctrep.conf` each carry their own `BW_TOTAL_MB`, so two engines running at once
use twice the ceiling either of them thinks it owns. One shared ceiling lands
with the library.

## What the merge shares, and how each shared thing was separated

Putting three engines in one folder means `$BASE` is now the same directory for
all of them. Two things had to be separated the moment that happened, and one
still has not been:

  - **inventories: done.** `ct-migrate.sh` reads `inventory-migrate.tsv`;
    `ct-replica.sh` and `ct-failback.sh` read `inventory-replica.tsv`. The
    columns mean entirely different things, so one filename for both would have
    fed migrate rows to the replica parser. If you add a fourth engine, give it
    its own file before it ever runs.

  - **logs and locks: fine.** `ctmig-`, `replica-` and `failback-` prefix the
    daily logs; `.sync-`, `.node-`, `.replica-` and `.failback-` prefix the
    locks. Nothing collides.

  - **`state/<ctid>.json`: decided, and done.** It used to collide.
    `ct-migrate.sh` keyed on `new_ctid` and `ct-replica.sh` on `src_ctid`, which
    are the same number for any CT that was migrated here and is now
    replicated, so the second writer erased the first one's record. Nothing was
    corrupted and no data moved wrongly; what was lost was the ability to look
    back, which is the only reason the file exists.

    Every tool now writes `state/<tool>-<ctid>.json` and
    `state/<tool>-<ctid>.runs.jsonl`, with the prefix in one variable
    (`ST_PREFIX`) per engine. `ct-failback.sh` gained state at the same time —
    it wrote nothing at all before, so a failback could never appear in
    `tp status` and an incident could not be reconstructed afterwards.

    Two things to keep. **Readers fall back to the pre-split name**: `tp status`
    shows an unprefixed file and labels its tool `pre-split`, and
    `ct-replica.sh` looks for the old path when reading `PREV_RC` — losing that
    would not fail a run, it would quietly downgrade "this image is damaged"
    back to "probably transient". And `schema/state.schema.json` still
    describes the **migrate** snapshot only, so `make schema-check` and the
    simulator's `st_valid` validate `state/migrate-*.json`; the replica and
    failback shapes are checked for parse and content, not against a schema of
    their own. That is the next piece of this, not a thing already done.

## Style

Comments explain **why**, not what. The reader is somebody debugging a failed
failover under time pressure, who needs to know what a line is defending
against. Prose is plain: no marketing, no hedging, no bullet lists where a
sentence works.
