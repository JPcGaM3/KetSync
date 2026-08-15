# Decisions

Why this fleet is shaped the way it is, and what has already been tried.

`CLAUDE.md` tells you the rules you must not break while editing. This file
tells you why those rules exist, what the machines actually look like, and
which arguments have already been had — so nobody spends an afternoon
rediscovering that ZFS replication cannot give a container a GUI snapshot on
NFS. Everything here was learned against real hardware serving real customers.

Nothing in this file is aspirational. If something is not built, it says so.

---

## 1. The architecture, which is not up for discussion

    NFS node        an NFS server and nothing else. Deliberately OUTSIDE the
                    cluster. Owns tank/hosting and tank-ssd/hosting-ssd, runs
                    sanoid, and is where every engine in this repo runs.
    Compute nodes   run the CTs and VMs. Their disks live on the NFS node,
                    mounted over NFS. They own no guest data.
    Backup node     holds STOPPED copies of the guests, plus PBS. It is for
                    snapshots and backups, not for running production.

The hard requirement that drove the whole design: **`pct snapshot` must work
from the Proxmox GUI on the backup node, against a copy that is stopped but
could be started, snapshotted and backed up as it stands.** That is why the
copies are real containers with real configs on a ZFS `subvol-` dataset, and
not a tarball or a `zfs send` stream.

HA is not in use. Failover is manual, on purpose. If HA is ever turned on, the
copies must never be placed under it, and the HA group must be `restricted 1`
over the compute nodes — a low priority on the backup node is not enough,
because a low priority still allows a guest to land there.

## 2. The machines, and the two storage shapes

Both source storages are `dir` storages on the NFS node, and **they are not the
same shape**. This was guessed wrong twice before anybody ran `findmnt -T`.

    tank-hdd-nas   /tank/hosting          its own ZFS dataset, mounted there
    tank-ssd-nas   /tank-ssd/hosting-ssd  a plain subdirectory inside an XFS
                                          filesystem mounted at /tank-ssd

That difference is the whole reason G1 has two layers. The rule G1 is really
enforcing is *data must not land on the node root filesystem* — not "the pool
must be a mountpoint", which is a rule a legitimate `dir` storage breaks every
day. Layer one resolves the pool with `findmnt -T` and refuses `/`. Layer two
only runs when PVE has been told `is_mountpoint`, and then insists the declared
path really is mounted; that layer is what catches `tank/hosting` failing to
mount while its parent pool `tank` is up, which layer one cannot see.

`is_mountpoint` accepts a boolean *or* a path. Reading it as a boolean was a
real bug, caught by reading the PVE docs rather than by a test — which is why
two scenarios exist purely to keep it caught.

Two consequences worth carrying: the two storages overlap (`tank-ssd-nas` lives
inside `tank-ssd`, so PVE double-counts their capacity), and `tank-ssd` has
`content backup`, so a vzdump run competes for the same spindles as a migration
wave.

## 3. Locked scope — do not reopen

**No cutover in the tooling.** Nothing here starts, stops, reboots or rolls
back a guest. The last thing a migration does is move the final delta with
`--stopped`; a human stops the container, a human adds `net0`, a human starts
it. Cutover and DR promotion are decisions with customers on the other end, and
they are made by somebody looking at the machine.

**No defaults for `new_node`, `storage`, or a replica `dest`.** A row missing
one is an error and is skipped. Guessing puts a container on the wrong node or
a DR copy on the wrong pool.

**The 2 Gbps link is a hard ceiling.** `BW_TOTAL_MB` is divided by `LANES`
*statically*. Dynamic borrowing was rejected: a lane that computed its share
while alone keeps that share after another lane starts, and the ceiling is
breached exactly when it matters. Counting live lanes by `pgrep` does not work
either — rsync forks a receiver and a generator with identical argv, so every
lane counts double.

**`mp0` and other extra mountpoints are migrated as config, never as data.**
Every path that will become an empty directory is named in the log. `rsync -x`
stops at the mount boundary anyway, so nothing swells the rootfs image.

**Thai belongs in `docs/*.html` and nowhere else** — see `CLAUDE.md` rule 2.
This file is English for that reason.

## 4. Approaches that were tried or costed, and rejected

**GUI snapshots of a CT on NFS.** Structurally impossible: PVE only offers CT
snapshots on storage types that can do them, and NFS is not one. Ceph would
solve it and was rejected as a network dependency the fleet does not want.
`pvesr` (ZFS replication) was rejected because it requires guest disks on local
ZFS, which contradicts the architecture rule above.

**rsync straight from each compute node.** The container is live and the copy
would be inconsistent in a way nothing detects. The engines take a ZFS snapshot
and read out of the clone instead, so every file in one round comes from the
same instant.

**syncoid / `zfs send` for the copies.** Gives no `pct snapshot` in the GUI,
and a rollback on the destination destroys the copy's own snapshot history.

**One engine with a `MODE` switch.** Rejected when the three tools were merged
into this repo. The *order* of the guards is the safety design, and it
genuinely differs by direction — G1 before allocation, G7 with G2 before any
transfer, B1 before anything is mounted. Three sequences that each read
straight down beat one sequence with `if MODE` in it.

**Forcing every copy onto VLAN 99.** Rejected: a fleet with a VLAN per customer
reuses IP ranges, so one shared VLAN would make the copies collide with *each
other*. Copies keep the source VLAN tag and change only the bridge.

**Splitting the c2v tools into `tools/centos6/` and `tools/ubuntu20-04/`.**
Rejected: phase 1 differs between the families in about six places and every
one of them is a single `case`. Copying a thousand lines guarantees the next
mtab-class bug gets fixed in one copy and forgotten in the other.

**Naming the backup pools after the machine (`rx740xd-*`).** Rejected: a role
outlives a chassis, and a per-machine pool name forces one PVE storage ID per
node, because a storage ID binds one path across the whole cluster. Pools are
named for what they hold: `replica-ssd`, `replica-hdd`, `pbsstore-sas`.

**Copying `/etc/pve` to "move" a node to new hardware.** Impossible. Cluster
membership lives in pmxcfs, corosync config and node certificates, and cannot
be carried across machines. The only supported shape is add a node, then remove
a node.

## 5. Incidents that became guards

Each of these happened. The guard is the scar.

**A failback refused every container because this host could not ssh to the
compute nodes.** The copies were up and serving, production was down, and every
row stopped at B1 with "cannot reach pve-r32 - 'unverified' is not 'stopped'".
B1 was right: it asks the production node whether the container is stopped, and
it asks by the pmxcfs node *name*. The storage node sits outside the cluster on
purpose, so it inherits neither the cluster's `/etc/hosts` nor its keys, and
nothing had ever said that failback depends on a path nothing else in this repo
uses. The engine was correct and the setup was incomplete, which is the worst
combination because it only shows up on the day it matters. → `--list` now
names every unreachable production node, prints the two commands that fix it,
and exits 1 rather than 0. Run it on an ordinary Tuesday.

**A dataset was not mounted and the engine filled the node root.** The pool
path resolved, the directory existed, and rsync wrote into the root filesystem
until it was full. → G1, and its equivalents R1 and B3.

**The review catch that mattered more than the fix.** When the umount guard was
added, the first version only skipped writing the config. It had to also skip
the ENOSPC grow-and-retry, because `resize2fs` against an image that is still
mounted is corruption rather than a failed run. → G3. That lesson was then
*lost* when `ct-failback.sh` was written, and found again by its simulator: a
`cleanup_ct` that cleared its "still mounted" flag even when the unmount had
failed silently disarmed the same gate. → the B5 gate, and mutation 12 in
`tests/mutation/run-mutation-failback.sh`.

**A stopped container already owned the target VMID.** G2 only sees a *running*
container, so a stopped one holding that id is invisible — and if its rootfs is
the same volid, the image is never allocated (it already exists) and
`rsync --delete` empties somebody else's container into ours. One mistyped
digit is enough. → G7, placed immediately after G2, before allocation and
before any transfer. That lesson was *also* lost in `ct-replica.sh`, where R4
ran after the transfer and only when a copy was first created. → R4 now runs
before the transfer, on every round.

**Two cron lanes at 21:00:02.** Both fired together, the empty lane finished in
zero seconds, and its cleanup loop `for s in /run/ctrep-*.sock` tore down the
ssh mux master the other lane was still using. It surfaced as
`storage 'replica-hdd' is not active` in the middle of a transfer. → the
control socket path carries the pid, and the cleanup glob matches only this
process's own sockets.

**`pvesm: command not found` under cron.** cron hands a script
`PATH=/usr/bin:/bin`, and `pvesm`, `zfs`, `losetup` and `e2fsck` all live in
sbin. It did not fail cleanly: `pvesm` returned nothing and the result looked
exactly like a storage that had never been configured. → every engine sets its
own PATH, and every engine has a required-command preflight that names what is
missing in one line.

**A `--storage` typo exited 0.** No row matched, no work was done, and under
cron that is indistinguishable from a healthy night. A lane can look fine for
weeks. → a `matched` counter, and a non-zero exit when a filter matches
nothing. The counter must be read *before* the `.done` check: a lane whose
containers have all gone live is not a typo.

**A config write was cut short and the damage was permanent.** G6 and R5 never
rewrite a config that exists, so a truncated one would boot never and every
later run would call that container healthy. → the config is written, read back
and compared; a mismatch is a failure, not a warning. Note that the rc is still
0 or 24 in that case, which is the point: the data is fine, only the config is
broken, and the fix is to delete the config and run again.

**`pct clone` failed with `mount: cannot mount /dev/loop0 read-only`.** The
source container was running and its ext4 journal needed replay. → mount
`ro,noload`, which also removed a 43-second stall that had been mistaken for
slow disks. It scales with journal dirtiness, not with image size.

**rc=23 after a failback.** Once is almost always the `ro,noload` transient and
clears on the next run. Twice in a row on the same container is a damaged
image. Only the previous run can tell them apart, so the engine reads the last
rc out of `state/<ctid>.json` and escalates the message on the second one. It
prints the `e2fsck -fn` command; it never repairs anything itself.

**QDevice, three failures in a row.** `corosync-qdevice` must be installed on
*every* node, not only the one running `pvecm qdevice setup`, and that setup is
not atomic — it can leave the qnetd database initialised after failing. The
container holding the qnetd address changed IP after a reboot, which looks like
a certificate problem and is not: `nc -zvw3 <ip> 5403` separates them, where a
timeout means nobody holds that address and a refusal means the host is up but
the daemon is not. The real root cause was ownership: `pvecm qdevice setup`
creates `/etc/corosync/qnetd/nssdb` over ssh as root, while the daemon runs as
`coroqnetd`. Fix is `chown -R coroqnetd:coroqnetd /etc/corosync/qnetd`. Do not
`rm -rf` that directory — the package sets its ownership. Also: `pvecm qdevice
setup` starts `corosync-qdevice` on the nodes but never `corosync-qnetd` on the
arbiter host, and `pvecm qdevice remove` ssh's out to the configured address
while holding a cfs lock, so it cannot be run while that host is down.

**A flag with its value missing ran forever.** All three engines parsed
`--storage`/`--ctid`/`--dest` with `shift 2 || true`. With the flag last on the
command line `shift 2` fails, `|| true` swallows it, `$#` never reaches zero and
the parse loop spins. Nothing is logged, nothing exits, and cron starts another
one every fifteen minutes. → the value is checked before the shift and a
missing one is exit 2. The engines now write `"$2"` rather than `"${2:-}"` on
purpose, so that deleting the check dies on `set -u` instead of spinning again
— a mutation that hangs proves nothing and blocks the suite forever.

**Two of the three mutation runners had no safety net, and this file said they
did.** `mutant()` is supposed to refuse a mutant that perl could not produce.
Only `run-mutation.sh` did. `run-mutation-replica.sh` checked neither perl's
exit status nor the mutant's size, so a mutation program that did not compile
produced a zero-byte file, which differs from the engine, parses as bash, runs
as an engine that does nothing, fails every scenario, and was reported as a
kill. Demonstrated on the real runner before it was fixed: a green tick and
exit 0 for a mutation that never touched the engine. → all three carry both
checks, and each one now runs `self_check` on itself before grading anything,
feeding `mutant()` a program perl cannot compile and a program that empties the
engine. The lesson is not that the guards were wrong; it is that nothing ever
asked whether they were there.

**A dry run that skipped a check rather than a write.** `ct-failback.sh`
gated the whole-run PAUSE requirement on `(( ! DRY ))`, so `--final --dry-run`
printed a clean plan for a run that was going to refuse, and the operator found
out inside the cutover window. → the check runs in both modes; only the outcome
differs. The real run exits 2, the dry run says "would REFUSE" and carries on
so the rest of the plan is still printed.

**A dry run that wrote to the production image.** `ct-failback.sh --dry-run`
loop-mounted the customer's image with a bare `-o loop`. Mounting ext4
read-write replays the journal and rewrites the superblock, so "dry-run —
nothing was written" was false at the byte level, against a production image,
at the one moment B1 has established nobody is watching it. The scenarios did
not catch it because they asserted on the image's *content*, which a journal
replay does not change. `ct-replica.sh` has mounted `ro,noload` since R6; the
lesson had simply not been carried across. → the dry mount is `ro,noload`, and
the simulator now enforces it as an invariant rather than an assertion:
`run_engine` reads `--dry-run` out of the engine's own argv and exports
`SIM_DRY`, and every fake that would change the fleet records a violation
instead of pretending. It found this bug the first time it ran, in three
images at once, without anybody writing an assertion for it.

**A comment inside a line continuation, and a `bash -n` that said clean.**
A comment placed between a command and its `\` continuation ends the
command. `mutant "name" \` + comment + `'program' \` + `1` therefore called
`mutant` with ONE argument, and it died on `$2: unbound variable` - after
the suite had already printed several green ticks, so the failure looked
like it belonged to the mutation before it. `bash -n` was clean again;
shellcheck caught it as SC2288 and named it exactly.

Two of these in one week, both the same shape: a comment edit that changed
what the shell parsed, past a syntax check that only proves a file parses.
Comments go ABOVE a `mutant` call, never inside one.

**A comment that lost its hashes, and a `bash -n` that said clean.** A block
of comment inserted into `ct-migrate.sh` kept the `#` on its first line and
lost it on the next five, so those lines were executed as commands. One of
them contained the word `tool's`, which opened a single quote - and that
quote was closed forty lines later by `LOGSEP='###...'`. The file therefore
PARSED, `bash -n` reported clean, and everything between the two quotes had
silently become one string. Every guard still looked present in the source.

What caught it was the simulator: 57 of 61 scenarios went red at once, which
is the signature of the engine itself being broken rather than a guard moving.
shellcheck caught it too, with SC1078 pointing at a quote thirty lines away
from the real fault. → the lesson is not about comments. It is that
`bash -n` proves a file parses and nothing more, and that `make lint` alone is
never enough to say a change is safe - which is why `make test` runs the real
engines even for a change that looks like documentation.

**Three mutations that were never applied.** In the migrate mutation suite,
three perl programs did not compile: a shell function's opening brace inside an
`s{}{}` replacement, which perl balances against the closing delimiter. perl
wrote nothing, the mutant was an empty file, and an empty file "kills" every
scenario because it does nothing at all. The suite printed a green tick for
three mutations that had never touched the engine. → `mutant()` checks perl's
exit status and refuses a mutant that is empty or less than half the size of
the engine.

**The engine read its own unmount back as the storage recovering.** During the
2026-08-15 DR drill, evacuate correctly proved tank-hdd-nas dead, unmounted it
with `umount -f -l`, and asked CT 110 to stop. lxc-stop gave up, the engine
fell back to isolating - and P2 refused, because "the storage ANSWERED": the
unmount had left PVE's mountpoint directory behind, an empty dir on the node's
root filesystem, and a `stat` on an empty local dir answers instantly with
rc 0. The stat proof cannot tell a live NFS server from the hole where one was
unmounted; only `/proc/mounts` can, and nothing asked it. The simulator's fake
had modelled the unmounted case as ENOENT - what would have been convenient -
so every scenario passed against a world that does not exist. → the probe now
reports MOUNTED from `/proc/mounts` (which cannot block) plus the storage's
type, and the verdict is made in the engine: an nfs/cifs storage, or a dir
that declares is_mountpoint, that is absent from the mount table is `gone`
whatever the stat said. A plain dir storage keeps the stat alone - it was
never a mount, and condemning it for that would isolate every container on a
healthy local-path storage.

**The three-minute budget that never reached the command doing the waiting.**
Same drill, one line earlier. The evacuate wait was 180s because the I/O error
that lets a guest on a forced-off mount finally die was measured at ~132s -
but `pct shutdown` hands the wait to `lxc-stop --nokill --timeout 60`, its own
default, and nothing passed the budget down. lxc-stop gave up at sixty every
time; the outer `timeout 180` never fired and never helped. → every shutdown
here passes its budget with `--timeout`, and the outer timeout is thirty
seconds longer, existing only for a pct that never returns at all. The fake
reproduces pct's real failure line with the timeout number in it, so a budget
that stops reaching lxc-stop turns a scenario red by the number in the
message.

**Then the drill showed what the patience was buying, and the answer was
nothing.** With the budget finally reaching lxc-stop, both containers were
waited on for the full 180s and neither came down - whether the EIO that kills
a blocked guest ever arrives is a race with the RPCs in flight at unmount
time, and a real total outage loses it. Two facts decided what replaced the
waiting. The DR's critical path needs OFF THE WIRE, which isolate delivers in
about three seconds and D1 accepts. And the shutdown request is a SIGNAL that
outlives the wait: the same drill watched both containers, asked to stop
during the outage, shut themselves down hours later the moment the storage
returned, on the strength of that queued signal - so cutting the wait loses
nothing that was ever going to happen inside it. → SHUTDOWN_GRACE, 30s, on
the evacuate and isolate paths: long enough for a guest whose writes already
fail fast to run an orderly shutdown, an order of magnitude shorter than the
horizon it used to wait for. At two hundred containers the difference is
eleven hours of customer downtime against two. SHUTDOWN_TIMEOUT stays 180 for
`--cleanup` alone: that path runs after the disaster on healthy storage,
nothing is waiting on it, and a database flushing for two minutes deserves
its two minutes.

## 6. Numbers calibrated on the real fleet

    SHUTDOWN_GRACE     30s     evacuate/isolate: ask, give a fast-failing
                               guest room for an orderly shutdown, isolate the
                               rest. The signal outlives the wait - see the
                               2026-08-15 entries in section 5
    SHUTDOWN_TIMEOUT   180s    cleanup only: a 9<id> on healthy storage may
                               really need its two minutes to flush
    BW_TOTAL_MB        230     divided statically by LANES
    USAGE_FACTOR_PCT   185     image size from the container's used bytes
    OFFSET             8000    copy VMID = source VMID + 8000
    ARC on the backup  32 GiB  PVE >= 8.1 caps zfs_arc_max at ~10% of RAM,
                               which was ~6 GiB out of 64 and far too small
    recordsize         128k    replica datasets (container rootfs)
                       1M      pbsstore-sas/chunks, set BEFORE the first backup
    compression        zstd    replica-hdd: 40 idle cores buy a better ratio
                       lz4     replica-ssd: a DR start has to be fast

Every replica dataset also needs `atime=off`, `xattr=sa` and
`acltype=posixacl`; LXC will not start on a dataset without the last two.
`bkp02-setup.sh` sets all of this and refuses to run unless the pools already
exist — creating a pool is a decision about physical disks and belongs to a
human.

**ssh cipher.** OpenSSH negotiates chacha20-poly1305 first by default, which
has no CPU instruction behind it and tops out around 150-400 MB/s per stream —
matching exactly the throughput that was being blamed on disks and cabling.
Forcing AES-GCM roughly doubles it on the same link. It is applied to the data
path only; the control path and its mux master are left alone. Set
`SSH_CIPHERS=` empty if a peer refuses the list.

## 7. The backup node

`replica-ssd` is a mirror of two Samsung 870 EVO. `replica-hdd` is six 2.4 TB
10K SAS disks as three mirrored pairs. `pbsstore-sas` is a 6-wide raidz1 with
one hot spare.

The layout is not an aesthetic choice. raidz1 delivers random IOPS
approximately equal to a single disk however wide it is (a 6-wide array is
about 180 IOPS) where three mirrored pairs give roughly 1100 read and 550
write, and a resilver touches the whole vdev rather than one pair. A replica
pool has to be able to actually `pct start` a container during a disaster, so
it gets mirrors; a PBS chunk store is sequential and wants capacity, so it gets
raidz1.

On the spare: `zed` must be running for a hot spare to activate at all,
`autoreplace=on`, and **a scrub never touches the spare** — so it needs its own
`smartctl -t long` on a schedule. A spare that has activated is a temporary
state, not a resolution; order a disk the same day. Skip scrubs on SSD pools.

One flag worth remembering: `zpool create` takes `-o` for pool properties and
`-O` for dataset properties, and every single one needs its flag. `autotrim=on`
without `-o` was silently taken as the pool *name*, and the failure surfaced as
`cannot open 'pbsstore-sas': no such device in /dev`.

## 8. CT to VM

Proxmox has no `pct convert-to-vm`. A container rootfs is missing three things
a VM needs: a kernel, a bootloader, and an initramfs that knows virtio.
Everything else is tidying.

The split into two phases is not tidiness — **the line is which kernel runs the
command.** On the EL path, `rpm`, `dracut` and `grub` are linked against glibc
2.12, which calls the vsyscall page at a fixed address; on a PVE 9 host
(`vsyscall=none`) they segfault on the first command, and no amount of
scripting fixes that. Those three commands have to run under the rescue ISO's
own 2.6.32 kernel. The bonus is that the ISO carries `kernel`, `grub` and
`dracut` with their dependencies, so yum can point at `file:///mnt/source` and
never touch a dead vault mirror — which was previously half the elapsed time of
the whole job.

Debian and Ubuntu need none of that: a PVE node *is* Debian, so phase 2 is an
ordinary chroot on the host. That is why phase 2 is split by family and phase 1
is not.

Things learned the hard way here, all of which are now enforced in code:

Phase 1 excludes `/boot/***`, `/etc/fstab` and the persistent-net rules,
because a second `rsync --delete` after the kernel is installed would delete
that kernel silently — the MBR survives, so the VM simply stops booting with
nothing in any log. Ordering instructions were the old answer; an exclude
cannot be mistyped in the wrong order.

Phase 1 decides whether phase 2 has already run by reading sector 0 of the
image for the `GRUB` signature, because rsync cannot touch the MBR and it is
therefore the only honest witness.

Phase 1 refuses block storage (LVM, ZFS volumes) outright rather than doing
half the job — `losetup` works on regular files only.

VM 9600 failed to boot twice, both times from the same line:
`--exclude=/usr/share/initramfs-tools`. That directory is shared ground, and
the `udev` package owns three files in it — one hook that copies `blkid` into
the initramfs, and one `init-bottom` script that hands `/dev` over to the real
root. Losing the first gives `ALERT! UUID=... does not exist`; losing the
second gives `Kernel panic - Attempted to kill init!`. `apt` cannot repair it,
because the dpkg database copied from the container insists udev is installed.
The fix is not to narrow the exclude list — it exists to close the hole
`rsync --delete` would otherwise open — but to have phase 2 put back what it
needs and **read back every time**: `lsinitramfs | grep -q bin/blkid`, and a
`/dev` node table verified by running the real code with only `mknod` stubbed.

The broader lesson: any phase-1 exclude pointing at a directory several
packages share will take other packages' files with it, and the package manager
will not notice.

## 9. What survives a re-sync

Asked often enough to be worth stating plainly. The line is whether the file is
inside the container's rootfs or outside it.

**Outside the rootfs — survives every round.** The target's config at
`/etc/pve/lxc/<new_ctid>.conf` is never overwritten once it exists (G6). So a
hand-added `net0`, an adjusted `memory` or `cores`, a changed `onboot` all
survive. Later rounds can only *report* that the image grew.

**Inside the rootfs — overwritten every round.** The sync is
`-aHAX --numeric-ids --sparse -x --delete` excluding only `/proc /sys /dev /run
/tmp /lost+found`. Everything else is made byte-identical to the source, so
network scripts, `/etc/hosts`, application config and anything created by hand
on the target are replaced or deleted. This is correct: a migration target that
is not identical to its source is not a migration.

If a change has to survive, make it on the source and let the sync carry it, or
apply it during the final cutover round.

Bridge mapping lives in `tools/c2v-prepare.sh` and nowhere else.
`ct-migrate.sh` strips every `net[0-9]+:` line on purpose. Even the c2v tool
only *prints* the `qm set` command for a human to paste — including `tag=` and
`mtu=` carried over from the container, and a missing `mtu` is the failure
where ssh connects fine but a large scp hangs.

## 10. What is not built

**`lib/`.** The three engines duplicate roughly nineteen functions. Five bugs
found in one week were the same bug in two engines. All three now have a
simulator and a mutation suite, which is what makes the extraction safe to do
without a fleet to test against. See `CLAUDE.md` for the two constraints.

**One shared bandwidth ceiling.** `ctmig.conf` and `ctrep.conf` each carry
their own `BW_TOTAL_MB`, so two engines running together use twice the ceiling
either believes it owns. `tp doctor` reports it; the fix lands with the
library.

**The `tp doctor` size-drift item is only a report.** When G4 grows an image,
G6 will not rewrite the config that already exists, so the config's `size=`
stays at the old number for good. The image is right and nothing is lost, but
`pct resize` later computes from that stale value. `tp doctor` names every
container it has happened to; fixing the line is still a human's job, on
purpose.

**Both migrate guides are current again.** `docs/quickstart.html` was the
stale one — it still named the engine `presync-all.sh`, a name that had not
existed for months, and gave a four-column inventory where five are required,
so an operator following it would have typed a command that was not there and
then had every row rejected. `docs/manual.html` turned out to be fine. The
lesson is the one in the note above it: a claim that a document is stale goes
stale too, so check before you trust it.

**What has actually run for real, and the README that said otherwise.**
`ct-migrate.sh`, `ct-replica.sh` and both c2v paths are in production and have
been for a while. `ct-failback.sh` has never been run once - it only exists for
the day the copies are needed, and that day has not come.

Worth recording because the README said something different, and said it
confidently: "ct-migrate.sh is in production against a real fleet. ct-replica.sh
and ct-failback.sh are newer." That was true when it was written and quietly
stopped being true, and it was then read and believed - twice, by two different
readers, one of whom repeated it back in a brief as established fact. A status
line is the most perishable sentence in any repository: it describes a moment
and nothing about it changes when the moment passes. The note above about the
stale migrate guide says a claim that a document is stale goes stale too. This
is the other half: a claim that something is NEW goes stale the fastest of all.

**Offsite copies.** Nothing exists. Everything is in one building.

**Lab acceptance.** T1, T5 and T6 have passed on real hardware. T2 (a GUI
`pct snapshot` on the copy), T3, T4, T7 and T8 are open, as are the three
timing numbers: seconds per replica round, RTO for the NFS-failure runbook, and
a full PBS restore.
