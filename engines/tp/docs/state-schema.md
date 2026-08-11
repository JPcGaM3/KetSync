# The state contract

This document is the prose companion to `schema/state.schema.json`; the schema
is the machine version and wins where the two ever disagree. The schema
describes **`ct-migrate.sh`'s** snapshot, and the whole of the detail below is
about that one. `ct-replica.sh` and `ct-failback.sh` write their own files with
their own shapes; those are checked for parse and content by their simulators
but do not yet have a schema of their own.

## Where it lives

Two files per CT per TOOL, all under `state/`, written by the engines and by
nothing else:

    state/migrate-<new_ctid>.json          current snapshot, replaced atomically
    state/migrate-<new_ctid>.runs.jsonl    append-only history, one object per run
    state/replica-<src_ctid>.json          ct-replica.sh, same shape of idea
    state/failback-<ctid>.json             ct-failback.sh, same
    ...and a .runs.jsonl beside each

The tool is in the file NAME on purpose. `ct-migrate.sh` keys on `new_ctid` and
`ct-replica.sh` on `src_ctid`, and those are the same number for any container
that was migrated here and is now replicated — so with one file per container
the second tool to run erased the first one's history. Nothing was corrupted
and no data moved wrongly; what was lost was the ability to look back.

Files named `state/<ctid>.json` with no tool prefix are from before that split.
Readers still accept them: `tp status` shows them with the tool column reading
`pre-split`, and `ct-replica.sh` falls back to the old name when it reads the
previous run's rc. A fleet that has been running for months should not go blank
on the day it is upgraded.

Plus a third thing that is *not* in the state at all:

    done/<new_ctid>.done          a human saying "I have cut this one over"

`state/` sits next to `ct-migrate.sh`, wherever that is. Nothing hard-codes an
absolute path — the same tree is checked out in a different place on every
node, and a reader finds it by walking up for `ct-migrate.sh`
(`ctmig.state.Repo.locate`).

One case writes no state at all: when the engine's inventory preflight finds
the same CT named on two rows it exits 2 before the first row is touched, so
every state file still holds whatever the previous run left. A reader that
notices its data has not moved should check the log, not conclude the run
succeeded — or ask `ctmig validate`, which reports the same duplicates without
running anything.

## Why two files and not one

"Has this CT converged yet" cannot be answered from a snapshot. One run
reporting 2.3 GB of new data means nothing without the run before it; three
runs reporting 9 GB, 3 GB, 200 MB mean the CT is ready. The trend *is* the
answer, so the history has to be durable.

It cannot live inside the snapshot, though, because appending to a JSON array
in bash means read-modify-write, and that is exactly how you end up with a
half-written state file when a run is killed. Appending one sub-4 KiB line to
an `O_APPEND` file descriptor is atomic; rewriting an array is not. So:
snapshot replaced whole via `mv`, history appended a line at a time.

## Atomicity, precisely

The snapshot is written to `state/.<ctid>.json.$$` and then `mv -f`'d into
place. A reader therefore sees either the previous complete file or the next
complete file, never a partial one — as long as it does a single `open`/`read`.
If a read fails to parse anyway (a truncated file from a previous crash, a
half-written file from an older version), treat it as *no snapshot*, not as an
error. `ctmig.state.Repo.snapshot` returns `None` and the CT reads as
`waiting`.

The history is appended with `>>` and never rewritten, except for one bounded
trim: when it passes `RUNS_KEEP * 2` lines (400 by default) it is cut back to
the newest `RUNS_KEEP` through the same temp-file-and-`mv` dance. That is one
rewrite every 200 runs. A reader that hits a corrupt line should skip that line
and keep going — one bad append must never hide the good history around it.

## Ownership, and the one field that does not exist

`done/<ctid>.done` is created by a human, by hand, after a container has gone
live on the new node. The engine only ever reads it, and it reads it *before*
writing any state, because a frozen row is skipped at the top of the loop. That
means the marker can never appear in the snapshot: there is no run to record it
in.

So a reader must check the marker itself and merge. Do not look for a `done`
field — there isn't one, and a future version adding one would be a mistake.
`ctmig.state.Repo.cts()` is where that join happens, and `done` beats every run
status, because the marker is a human saying "I have judged this one, leave it
alone".

## The snapshot

Every field is required. `additionalProperties` is false, so an unknown key is
a schema violation and `ctmig validate` will say so — but a *reader* should
ignore unknown keys rather than fail, so that a newer engine writing an extra
field does not take the dashboard down.

| field | meaning |
| --- | --- |
| `schema_version` | `1`. Bumped only when a reader would break. New optional fields do not bump it. |
| `new_ctid` | CT id on the new node, and the file name. |
| `old_ctid` | CT id on the old node. Usually the same number, not necessarily. |
| `old_node` | source node, verbatim from `inventory.tsv`. |
| `new_node` | target node. Required per row, never defaulted. |
| `storage` | PVE storage id the rootfs image lives on. Also the lane name. |
| `image` | absolute path of the raw image, as `pvesm path` reported it. |
| `image_size_gib` | real size of the image file, rounded up. `0` means it does not exist yet. |
| `config_present` | true once `/etc/pve/lxc/<new_ctid>.conf` exists on the new node. Written once, never rewritten (G6). |
| `config_size` | the `size=` value inside that config, e.g. `20G`. Empty while no config exists. |
| `size_drift` | true when `config_size` disagrees with `image_size_gib`. |
| `mp_empty` | mount point paths migrated as *config only*. Every one will be an empty directory on the new node. |
| `last` | the run object below — the most recent run, in full. |

Two of those deserve more than a table row.

**`size_drift` is bookkeeping, not damage.** It goes true after an ENOSPC grow:
the image on disk is now 21 GiB while the config still says `20G`. PVE reads the
real size from the storage layer during a resize, so it does not care. What you
must *not* do is "fix" it by shrinking the image back to match the config — the
filesystem inside was already `resize2fs`'d larger, and shrinking under it is
real corruption. If the mismatch bothers you, edit the config upward.

**`mp_empty` is the one that will bite somebody at 3am.** The engine migrates
mount point *configuration* but deliberately does not copy mount point *data*.
Those paths will exist on the new node and be empty. Any reader that shows a CT
as ready must show this list too.

## The run object

Identical shape in `last` and in every line of `runs.jsonl`, so a reader parses
one thing.

| field | meaning |
| --- | --- |
| `ts` | local time the run finished, ISO 8601 with offset. |
| `epoch` | the same instant in seconds, for sorting. |
| `lane` | `all` for a full run, otherwise the storage id passed to `--storage`. |
| `mode` | `presync` or `stopped`. `stopped` is the final delta off a CT you stopped yourself. |
| `status` | `running` / `ok` / `failed` / `skipped` / `interrupted`. |
| `reason` | stable slug for why it was not ok. Empty when ok. |
| `message` | the first ERROR / GUARD / WARN / HINT / NOTE line this CT logged. The headline for a human. |
| `rc` | rsync exit code. `-1` means the run never reached rsync. |
| `secs` | wall clock seconds in rsync, summed over ENOSPC retries. |
| `files` | regular files transferred, summed over retries. |
| `literal_bytes` | new content rsync actually had to send. **The convergence metric.** |
| `bytes_sent` | everything put on the wire, protocol overhead included. |
| `total_bytes` | size of the whole dataset considered. A property of the CT, so **not** summed across retries. |
| `grow_attempts` | how many times ENOSPC forced a grow during this run. |

### `status`, and the one that is a lie by the time you read it

`running` is published by `st_begin` *before* the long transfer starts, so a
reader can see work in flight. It is the only status that is meant to be
observed live. If you find a `running` snapshot whose `epoch` is hours old, the
engine died in a way that skipped its own exit trap — the run is not running,
it is dead. A TUI should treat a stale `running` as needing attention.

`interrupted` is what the exit trap rewrites `running` into when the engine is
killed mid-transfer. It is not a failure — the partial data is on disk and the
next run picks up exactly where it stopped, which is the whole point of doing
this with rsync. Do not count it as an error and do not panic-restart on it.

`skipped` is a *non-event*. `node_busy` in particular is the per-source-node
lock doing its job: another lane already had that node, this lane moved on
rather than sitting on its bandwidth waiting, and the next cron run will pick
the CT up. A screen full of `node_busy` on a busy night is correct behaviour,
not an incident.

### `rc`, and why 24 is success

    0    clean
    24   files vanished mid-sync -- NORMAL on a live container, this is success
    23   partial transfer -- a failure
    11   out of space -- triggers the G4 grow-and-retry path
    -1   never got as far as rsync (a guard fired, or the row was skipped)

24 is the one everybody gets wrong. The container is running and writing while
being read; files disappearing underneath rsync is expected, and the engine
writes the target config on 0 *or* 24.

### `reason` is an API

The slugs are stable and a reader is expected to switch on them. A typo in one
is a bug that `ctmig validate` catches, which is why the schema enumerates them
rather than accepting any string.

    ""                empty: the run was ok
    interrupted       killed mid-run; partial data is fine, rerun

Pre-transfer, no data moved:

    storage_unknown   storage id is not in the inventory row's node
    g1_pool           G1: the pool is on the node root filesystem, or a
                      declared is_mountpoint is not actually mounted
    g2_running        G2: a container with this id is already running on the
                      new node -- refusing to sync into it
    g7_ctid_taken     G7: a config for this id already exists on the new node
                      and its rootfs is not the volume this row would write.
                      A stopped container owns that id, or an earlier config
                      write was truncated. Either way, syncing would empty
                      somebody else's rootfs into ours
    storage_inactive  the storage exists on the target but is not active
    node_busy         another lane holds the source node lock (see above)
    ssh_old_node      the old node is unreachable
    ct_not_found      no such CT on the old node
    not_stopped       --stopped was used on a CT that is still running
    no_image          --stopped with no image yet; run a presync first
    pct_mount         could not mount the CT on the old node
    not_running       presync needs a running CT to read /proc/<pid>/root
    pool_space        not enough room in the pool to allocate the image
    alloc_failed      pvesm alloc failed
    mkfs_failed       the image was allocated but has no filesystem. Checked
                      here rather than left to the loop-mount, because at this
                      point the fix is still one command
    loop_mount        could not loop-mount the target image

Transfer path:

    g3_umount         G3: the image could not be unmounted before a resize.
                      Nothing is resized. This is the guard that prevents
                      corrupting a mounted image, including on the ENOSPC path.
    g4_enospc         G4: out of space, grown 5% and retried, still out of
                      space after the retry limit
    g5_rsync          G5: rsync failed (rc other than 0/24/11), so no config
                      was written
    cfg_write         the sync succeeded but the config written to the new node
                      did not read back as what was sent. `rc` is 0 or 24 here,
                      which is the point: the DATA is fine and only the config
                      is bad, so the fix is to delete that one file and rerun

`ct-migrate.sh` writes G6 — refusing to overwrite an existing target config —
as a `message`, not a `reason`, because it is not a failure. The run is still
`ok`.

`cfg_write` is the one failure where a reader must not assume nothing was
transferred. It is a failure because a half-written config is permanent: G6 will
never rewrite a config that exists, so every later run would report this CT as
healthy while it can never boot.

## Convergence

The question the whole tool exists to answer is "can I cut this CT over
tonight", and the answer is a trend, not a number:

    literal_bytes of every run whose status is ok and whose rc is 0 or 24,
    oldest first

Failed runs are excluded on purpose — a run that transferred nothing because it
died is not evidence of convergence. `ctmig.state.convergence()` does exactly
this and nothing else, and `ctmig show <ctid>` prints it.

What you want to see is a fall towards a floor. The floor is whatever the
container writes between two runs; it never reaches zero on a live CT. When the
floor is small enough that copying it during a maintenance window is
acceptable, stop the CT and run `--stopped`.

A flat or rising series means the CT writes faster than the syncs converge —
usually a database or a busy log. Sync more often, or accept that this one
needs a longer window.

## Reading it without Python

The engine cannot depend on `jq` or `python3` — Proxmox ships neither reliably —
and neither should a 3am one-liner:

    # which CTs failed
    grep -l '"status":"failed"' state/*.json

    # the last run of one CT, readably
    tr ',' '\n' < state/251.json | grep -E 'status|reason|literal'

    # how much new data the last five runs of 251 moved
    tail -5 state/251.runs.jsonl | grep -o '"literal_bytes":[0-9]*'

With Python available, `ctmig ls`, `ctmig show <ctid>` and `ctmig json` are the
supported interface, and `ctmig validate` checks every state file against the
schema.

## Changing this contract

Adding an optional field: fine, no version bump, but add it to the schema —
`additionalProperties: false` means an unschema'd field fails `make
schema-check`.

Adding a `reason` slug: add it to the schema enum in the same commit as the
engine change, and give the reader a branch for it. A slug the reader does not
know still displays, since `headline` falls back to `message`, but it will not
be *understood*.

Removing or retyping a field, or changing what a slug means: that is a
`schema_version` bump, and every reader needs the matching change.
