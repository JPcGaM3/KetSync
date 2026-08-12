# Working in this repository

Read this before you change anything. It is short on purpose; everything in it
is here because getting it wrong has a cost that is not obvious from the code.

## What this is

`tp` — teleport. Five engines that move **running production LXC containers**
around a real fleet, on a real schedule. There is no staging copy of the fleet.
A bug here does not fail a test — it corrupts somebody's container at 2am.

    tp migrate    old standalone node  ->  raw image on the storage node
    tp replica    live image here      ->  stopped copy on the backup node
    tp failback   promoted copy        ->  back into the production image
    tp distribute DR copy on the backup ->  a compute node's OWN storage
    tp recall     a compute node's 9<id> ->  back into its copy on the backup

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

    ct-migrate.sh    tests/mutation/run-mutation.sh             45 mutations
    ct-replica.sh    tests/mutation/run-mutation-replica.sh     57 mutations
    ct-failback.sh   tests/mutation/run-mutation-failback.sh    58 mutations
    ct-distribute.sh tests/mutation/run-mutation-distribute.sh  50 mutations
    ct-recall.sh     tests/mutation/run-mutation-recall.sh      41 mutations
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

**2. No Thai anywhere except `docs/*.html`.**
Code, comments, commit messages, test names, briefs: English. The operator
guides are Thai because the operator is Thai — that is the only exception, and
inside them Thai belongs in the prose, never inside `<pre>` or `<code>`.
Commands are copied and pasted at 2am; they have to survive that.

**3. Nothing here touches container lifecycle.**
No shutdown, no start, no IP remap, no rollback state machine. Cutover, DR
promotion and the return trip are done by hand, on purpose, by a human who is
looking at the machine. The engines refuse to run when the lifecycle is wrong
(`--stopped`, B1, B2, R2) — they never fix it themselves.

**4. A copy never reaches the wire by accident.**
`migrate` writes the target config with no network and `onboot: 0`; the operator
adds `net0` at go-live. `replica` does the opposite and gives the copy the
source's **real** network — same IP, same MAC, same VLAN — on an isolated
bridge with no uplink. Both are the same rule from different directions: two
copies of one host must never be reachable at once. R9 verifies the bridge has
no uplink before every run, and R11 warns when a promoted copy was never put
back. Do not weaken either.

**5. `new_node` and `storage` have no defaults, and neither does a dest.**
A row missing one is an ERROR and is skipped. Never guess, never fall back to a
"sensible" value. Guessing puts a container on the wrong node or a DR copy on
the wrong pool.

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

## Before you say you are done

    make lint       # bash -n + shellcheck + the language and separator rules
    make test       # 66 + 76 + 69 + 46 + 48 simulator, 16 dispatcher, 125 c2v
    make mutation   # 45 + 57 + 58 + 50 + 41 engine + 9 dispatcher bugs, all caught

All three, every time, even for a documentation change — `make test` runs the
real engines, so it is also how you find out that you broke something you did
not think you were near.

On a Mac, run `make gates` instead: it runs all three in a `debian:bookworm`
container with the repo mounted read-only. Do not run them natively there and
believe the result. macOS has no `flock`, so `if ! flock -n 9` reads
command-not-found as "the lock is held" and `ct-migrate.sh` logs "another sync
is running" and exits 0 having done nothing; `ct-replica.sh` and
`ct-failback.sh` die even earlier, on `declare -A` under bash 3.2. `bash -n`
catches none of it, which is why `make lint` passes there and proves nothing.

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

`ct-migrate.sh` — G1..G7:

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
    R9   the mock bridge must have NO uplink - checked once, refuses the run
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

    D1  the production container must be verifiably down and must STAY down:
        running refuses, unreachable refuses (unverified is not stopped), and
        `onboot: 1` refuses - a container that is stopped today and boots
        itself when the storage node returns puts two machines on one IP,
        each writing a rootfs that can never be merged with the other
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
        holding older data. No marker, no run - see docs/decisions.md section 6
    C4  presync needs the 9<id> RUNNING, --final needs it STOPPED. A stopped
        one without --final is refused: "it is down right now" and "we are
        cutting over" are different intentions. No PAUSE requirement, because
        R13 keys on the config existing rather than on it running
    C5  the destination dataset must report mounted=yes. R3, restated
    C6  a verified mountpoint before rsync, read-only with noload - a live
        container is writing to that filesystem and replaying its journal from
        the outside corrupts it. A zfspool volume is the storage's own mount:
        never mounted by this engine and never unmounted by it
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

## Layout

    tp                         the dispatcher: tp migrate|replica|failback|
                               status|doctor. Contains no migration logic of
                               its own, on purpose
    ct-migrate.sh              the migrate engine — see rule 1
    ct-replica.sh              the replica engine
    ct-failback.sh             the failback engine
    ctmig.conf / ctrep.conf    tuning, kept separate from the engines so
                               re-delivery never overwrites a calibrated value
    inventory-migrate.sample.tsv       migrate rows: old_node old_ctid new_ctid
                               new_node storage
    inventory-replica.sample.tsv
                               replica rows: src_ctid [tgt_ctid] [dest]
                               [storage-assert]
    bkp02-setup.sh             one-time prep of the backup node's pools
    tests/sim/                 the migrate simulator, and its fakes
    tests/sim/replica/         the replica simulator: a storage node plus a
                               whole backup node behind a fake ssh
    tests/sim/failback/        the failback simulator, same backup node, data
                               flowing the other way
    tests/tp/                  the dispatcher: tp status, tp doctor, and that
                               arguments reach the engine untouched
    tests/mutation/            one suite per engine — see rule 1
    tests/c2v/                 what both CT-to-VM phase-2 scripts write
    schema/state.schema.json   the data contract, machine-checkable
    docs/decisions.md          why the fleet is shaped this way, what has
                               already been tried and rejected, and which
                               incident produced which guard. Read it before
                               proposing an architectural change
    docs/state-schema.md       the same contract in prose
    tools/check-log-separator.sh
                               every tool that defines log() must define and
                               call hr(). The engines and tp bind their rule
                               with scenarios and mutations; the c2v tools
                               cannot cheaply, so this is what keeps theirs
                               from being deleted unnoticed
    tools/c2v-prepare.sh       CT to VM, phase 1: builds the VM disk on the
                               host. Partitions, mkfs and rsyncs a live CT
    tools/c2v-inside.sh        CT to VM, phase 2 for EL, in the guest's own
                               rescue environment
    tools/c2v-inside-deb.sh    CT to VM, phase 2 for Debian/Ubuntu, in a chroot
                               on the PVE node

The c2v tools are deliberately outside the engines: they convert one CT by hand
rather than moving a fleet, they are the only thing here that partitions and
mkfs an image for a bootloader, and on the EL path half of the work does not run
on the host at all. Phase 2 is split by family and phase 1 is not, on purpose —
the two families differ in about six places and every one of them is a `case` in
the one phase-1 script. Do not fork it.

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

Comments explain **why**, not what. The reader of this code is somebody
debugging a failed migration under time pressure, who needs to know what a line
is defending against. `# increment counter` helps nobody. `# rsync reports 24
when a file vanished mid-sync, which is normal on a live CT` is the whole point.

Prose in the docs is plain and direct. No marketing, no hedging, no bullet lists
where a sentence works.

## graphify

This project has a knowledge graph at graphify-out/ with god nodes, community structure, and cross-file relationships.

Rules:
- For codebase questions, first run `graphify query "<question>"` when graphify-out/graph.json exists. Use `graphify path "<A>" "<B>"` for relationships and `graphify explain "<concept>"` for focused concepts. These return a scoped subgraph, usually much smaller than GRAPH_REPORT.md or raw grep output.
- If graphify-out/wiki/index.md exists, use it for broad navigation instead of raw source browsing.
- Read graphify-out/GRAPH_REPORT.md only for broad architecture review or when query/path/explain do not surface enough context.
- After modifying code, run `graphify update .` to keep the graph current (AST-only, no API cost).
