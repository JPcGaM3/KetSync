# Tests

Empty on purpose, and that is a debt, not a decision.

`tp` has 221 simulator scenarios and 165 mutations behind it, and the reason
is written down in its `CLAUDE.md`: five bugs found in one week were the same
bug living in two engines, and every one of them was caught by a scenario
rather than by review. `ketsync` moves the same customer data through the same
`rsync --delete`, so it earns the same discipline.

Nothing in `ketsync` should be allowed to write to a real machine until this
directory looks like `tp/tests/`:

    sim/         the real dispatcher, in a sandbox, against fake ssh and rsync,
                 with fakes that refuse to pretend and record a VIOLATION
                 instead - an inventory pushed over a newer one, a sync run
                 from a slave, a distribute onto a node that already has that
                 VMID
    mutation/    one mutation per guard, each proven to kill a scenario. A
                 green suite means nothing until you have watched it go red
                 for the right reason.

Copy the harness rather than inventing one: `tp/tests/sim/run-sim.sh` is the
pattern, and its `scenario` / `done_scenario` / `has` / `traced` / `clean`
helpers are the whole interface.

Two traps that cost an hour each in `tp`, written here so they cost nothing:

Every engine sets its own PATH, so a simulator cannot reach its fakes by
prepending a directory - `run_engine` exports shell *functions*, and a fake has
to be both shimmed and listed in `export -f`.

A mutation that cannot be applied proves nothing and can still look green: perl
writes nothing when its program does not compile, and an empty mutant "kills"
every scenario because it does nothing at all. Check perl's exit status.
