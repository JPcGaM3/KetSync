# ctmig simulator

Runs the REAL `ct-migrate.sh` — not a copy, not a rewrite — against fake
`pvesm`, `pct`, `ssh`, `rsync`, `mount`, `losetup`, `truncate`, `e2fsck` and
`resize2fs`. Nothing touches a real node, a real pool, or the network.

    ./tests/sim/run-sim.sh      (or: make test-sim)

Expected output: `=== 66 passed, 0 failed ===`

This file describes the **migrate** simulator. The other four live beside it and
are run the same way, each against its own fake fleet:

    ./tests/sim/replica/run-sim-replica.sh        76 scenarios   (or: make test-replica)
    ./tests/sim/failback/run-sim-failback.sh      69 scenarios   (or: make test-failback)
    ./tests/sim/distribute/run-sim-distribute.sh  46 scenarios   (or: make test-distribute)
    ./tests/sim/recall/run-sim-recall.sh          48 scenarios   (or: make test-recall)

The number in front of a scenario name is its selector, and the mutation suites
select by it: `run-sim-recall.sh 30` runs scenario 30 and the runner reads the
exit code. Two scenarios sharing one number make that ambiguous, so the replica
and recall runners refuse the full suite when they find a duplicate.

## How it works

Each scenario builds a throwaway sandbox with `mktemp -d`, writes a fake
inventory and a fake `ctmig.conf` into it, then runs the engine through a
symlink placed inside that sandbox. `${BASH_SOURCE[0]}` is not symlink-resolved,
so the engine's `BASE` lands in the sandbox and every path it derives — logs,
lock files, `.done` markers, `MNT_BASE` — stays there too.

`tests/sim/bin` is prepended to `PATH`, so every external command the engine calls is
a shell script that records what it was asked to do into `$SIMROOT/trace` and
mutates a small state file describing which images are loop-mounted where.

## The fakes are the test

The interesting part is not that the fakes return canned answers. It is that
several of them refuse to pretend, and write into `$SIMROOT/violations`:

- `truncate` / `e2fsck` / `resize2fs` on an image that is still loop-mounted
- `mount` loop-mounting an image that is already loop-mounted
- `rsync` writing into a destination that is not a mountpoint
- `pvesm alloc` allocating into a pool that sits on the root filesystem

Those four are the corruption and disk-fill incidents from the real fleet,
turned into executable assertions. A scenario fails if the violation file is
non-empty, even when the engine's own exit code and log look fine.

## Scenarios

    1   happy path, two CTs on two different storages
    2   G1  pool is not a mountpoint -> nothing is allocated
    3   G2  a copy is running on the new node -> refuse to sync into it
    4   G4  ENOSPC (rc=11) grows the image and retries
    5   G3  umount fails DURING an ENOSPC run -> no resize, no config
    6   G5  rc=23 is a failure -> no config
    7       rc=24 (files vanished on a live CT) is normal -> config written
    8       legacy 4-column row is refused, not guessed
    9       storage missing on the target node -> caught before transfer
    10      mp0 is migrated without data and every empty path is named
    11      --storage runs one lane only
    12      LANES splits the tool-wide bandwidth ceiling
    13      --final refuses a CT that is still running
    14      --final delta mounts, syncs, and always unmounts
    15      --final unmounts the source even when the sync fails
    16      .done freezes a finished CT
    17      G6  an existing config is never rewritten
    18      the old node being unreachable is a clear, distinct error
    19      a dir storage INSIDE a mounted filesystem is legitimate
    20      is_mountpoint declared but not mounted -> refuse
    21      no is_mountpoint does NOT excuse a pool on the root filesystem
    22      a storage path that does not exist is named as such
    23      is_mountpoint given as a PATH, not a boolean
    24      is_mountpoint PATH not mounted -> refuse, naming that path

Scenarios 25 onward were added with the state emitter. They assert on
`state/<ctid>.json` and `state/<ctid>.runs.jsonl` as well as on the log, and
every snapshot they produce is validated against `schema/state.schema.json`
when `jsonschema` is importable:

    25      two lanes want the same source node -> the second is skipped
            node_busy, and does not run rsync
    26      the node lock is released, so the next run proceeds
    27      the lock never blocks a DIFFERENT source node
    28      a complete run publishes a complete snapshot
    29      rsync's comma-formatted stats are recorded as numbers
    30      an ENOSPC retry SUMS the transfer counters, except total_bytes
    31      a failed sync records g5_rsync
    32      three grow attempts are counted, and the reason is g4_enospc
    33      a guard that fires before rsync records rc -1
    34      a frozen CT writes no state and appends no history line
    35      an incomplete inventory row produces no state file at all
    36      history accumulates one valid line per run
    37      a storage id full of JSON-hostile characters still parses
    38      --final records the mode it ran in
    39      mp0 paths that will be empty are named in the state file too
    40      two CTs on the same source node both complete

Scenarios 41 onward came with the duplicate preflight. They are about the
inventory file itself, so most of them assert that the engine ran *nothing*:

    41      a duplicate new_ctid is refused before anything runs, naming the
            real file lines even with a comment and a blank line above them
    42      the same old CT twice on one node is refused, naming both lines
    43      the same old_ctid on two DIFFERENT old nodes is legitimate and
            both CTs complete
    44      --ctid does not excuse a duplicate in an unrelated row
    45      a last row with no trailing newline is still a row
    46      the preflight sees that last row too

## Mutation testing

    ./tests/mutation/run-mutation.sh    (or: make mutation)

Expected output: `=== <all> mutations killed, 0 survived ===` (the number
grows with the engine; the suite prints it)

The harness patches one known bug into a copy of `ct-migrate.sh` with `perl`,
points the simulator at that copy through `ENGINE=`, and fails if the scenarios
that should have died still pass. Two things also count as failures, and both
matter more than they look: a mutation that no longer *matches* anything (its
anchor moved, so it is silently testing nothing) and a mutant that does not
parse (the patch was malformed, so the "failure" it caused was bash, not the
bug). Either way the suite says so instead of reporting a kill.

    the per-node lock is never contended
    the lock is keyed on the CT instead of the source node
    rsync stats keep their thousands separators
    the JSON escaper passes its input through untouched
    the state file is written but never moved into place
    the run history is never appended to
    an ENOSPC retry replaces the transfer counters instead of adding
    a frozen CT is treated as an ordinary row
    the run status is never set, so every run looks the same
    the duplicate preflight reports, then runs anyway
    the source duplicate check keys on old_ctid alone, ignoring the node
    the preflight stops one row short of the end of the file
    the main loop drops a last row that has no trailing newline

The second of those is the interesting one. It is not a mistake that breaks
anything visibly — it makes the check *stricter* — and scenario 43 is the only
thing standing between it and an engine that refuses a perfectly good
inventory because two different old nodes both number a container 100.

One candidate mutation was tried and deliberately dropped: "take the node lock
but never release it". It survives, and correctly so — `exec 8>path` releases
whatever the fd held before, and process exit releases everything, so within
one process the missing release is unobservable. It was replaced by keying the
lock on the CT instead of the node, which is the same mistake in a form that
has consequences.

## Mutations found by hand, before the harness existed

A suite that passes on the first run deserves suspicion. Three bugs were
reintroduced into the engine on purpose and each was caught:

    M1  move the umount gate back to AFTER the grow loop
        -> VIOLATION: truncate / e2fsck / resize2fs on a MOUNTED image
           VIOLATION: double loop-mount
    M2  delete the G1 pool-is-mounted check
        -> VIOLATION: pvesm alloc into an UNMOUNTED pool
           plus exit 0 instead of 1, and a config that should not exist
    M3  treat rsync rc=23 as success
        -> config created, exit 0 instead of 1

M1 is the one that matters: it is the review catch — umount failing while the
run is in the ENOSPC path — reproduced automatically instead of by reading.

Two more were run against the reworked G1:

    M4  require the pool path to be a mountpoint itself (the old rule)
        -> 19 refuses a legitimate subdirectory storage
           20 loses the is_mountpoint-specific message
    M5  keep only the is_mountpoint tier, drop the root-filesystem tier
        -> 21 allows the fill-the-node-root case:
           VIOLATION: pvesm alloc into a pool on the ROOT filesystem

M4 and M5 are the two ways to get G1 wrong in opposite directions — too strict
and too lax — and the suite fails on both.

Two more against the path-valued form of `is_mountpoint`:

    M6  read a path value as if it were the boolean 1, i.e. check the POOL path
        -> 23 rejects the documented BTRFS-style layout
           24 stops naming the path that actually failed to mount
    M7  drop the is_mountpoint tier and keep only the root-filesystem tier
        -> 20 and 24 both allocate into a pool whose declared mount is missing

M6 is not hypothetical: it is the bug that shipped in the first draft of this
guard, found by reading the PVE docs rather than by running the suite. The
scenario exists so the next reader does not have to find it that way.

## Adding a scenario

Copy an existing block in `run-sim.sh`. The helpers are:

    scenario "<name>"        start a fresh sandbox
    add_node <host>          create a fake node
    add_ct <host> <id> <status> <pid> <used> <quota>
                             give that node a CT
    add_storage <id> <path> [ismp]
                             map a storage id to a pool path
    mount_fs <path>          pretend <path> is a mounted filesystem
    unmount_pool <id>        pretend that storage's own mount went away
    declare_ismp <id> <val>  set is_mountpoint in storage.cfg (val may be a PATH)
    inventory "<row>" ...    write the fake inventory, one argument per line
    inventory_nonl "<row>" ...  the same, but the last line gets NO trailing
                             newline — the shape some editors leave behind
    rsync_stats <f> <lit> <sent> <total>
                             what rsync will claim it transferred
    rsync_rc <rc> [rc...]    queue the exit codes rsync will return, in order
    hold_node_lock <host>    pretend another lane owns that source node
    drop_node_lock           release it again
    run_engine [args...]     run the engine
    has / hasnt <regex>      assert on the engine's log
    traced / untraced <re>   assert on the command trace
    rc_is <n>                assert the engine's exit code
    clean                    assert the violation file is empty
    cfg_exists / cfg_absent  assert on the config written to the new node
    cfg_has / cfg_hasnt <re> assert on that config's contents

and, for the state files:

    st_valid <ctid>          the snapshot parses AND matches the schema
    st_is <ctid> <path> <v>  a dotted path equals a value, e.g.
                             `st_is 251 last.reason node_busy`
    st_absent <ctid>         no snapshot was written at all
    runs_count <ctid> <n>    the history has exactly n lines
    runs_valid <ctid>        every history line is valid JSON
    runs_last <ctid> <p> <v> a dotted path in the newest history line

The state helpers need `python3`, which the simulator host has and a Proxmox
node does not — that asymmetry is deliberate and is why the engine hand-rolls
its JSON.

Every scenario should end with `clean` unless it is deliberately testing that a
violation is produced.
