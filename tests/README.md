# Tests

`sync`, `distribute`, the confirmation, `doctor`, `recover` and `watch` have
simulators. `role` does not, and that is the remaining debt.

`sync` went first because it is the only command in this layer that WRITES to
another machine, and because everything it can get wrong is silent: a push that
went nowhere, a push that went to the wrong path, a slave left holding last
month's inventory. None of those print an error on the machine you are standing
on. The first anybody hears of one is a container that had no DR copy.

Three bugs were live in `cmd_sync.sh` when the simulator was written, and all
three had been running on a real fleet:

- the remote path was assumed to be the local one, so a fleet whose clones sit
  at different absolute paths pushed into a directory that did not exist and
  reported success
- every row in `nodes.tsv` was a target, including compute nodes, which have no
  ketsync and are not supposed to
- equal generations were treated as identical files, so two machines both
  saying "generation 1" with different contents stayed that way forever - which
  is the state of every fleet that has never synced

None of them were found by reading the file. The simulator found all three in
its first run.

    sim/sync/        the real dispatcher, in a sandbox, against fake ssh and
                     rsync. Every other machine is modelled as a WHOLE
                     FILESYSTEM rather than as "this directory again", which is
                     what makes the first bug above visible at all
    mutation/        one mutation per guard, each proven to kill a scenario. A
                     green suite means nothing until you have watched it go red
                     for the right reason

    sim/doctor/      every check doctor makes, one wrong thing at a time
                     against a fleet that is otherwise fine
    sim/distribute/  the one composed command: both engines are stubs that
                     record their argv, because the argv is the whole of what
                     the joins between them can get wrong
    sim/confirm/     the question asked before a write, half of it under a pty
    sim/watch/       the alerts: fake sendmail and curl record what would have
                     arrived at three in the morning, because watch's output is
                     a mail nobody is at a terminal for - the suite asserts on
                     the mails themselves, their tier, and their absence
    sim/recover/     the second composed command: the whole way back, with the
                     engines as stubs again - what recover can get wrong is the
                     ORDER, what a failed step is allowed to touch, and what
                     may happen only when everything went green

    make test-ketsync       21 + 13 + 17 + 20 + 17 scenarios
    make mutation-ketsync   19 + 13 + 16 + 19 + 17 mutations

`doctor` went last because it writes nothing, and that turned out to be the
wrong reason to leave it. A command that writes can be caught by looking at
what arrived; a command that only reads is caught by nothing at all when a
check stops firing, because a check that stops firing prints what a healthy
fleet prints. The simulator found one on its first run: a compute node nobody
could ssh to was reported as expected, months after every DR verb started
running over that connection.

Its mutations are the pattern to copy if you add a section to doctor. Every
assertion in that suite is a line of output - `has "== nodes.tsv"` passes
forever, whatever the section under it decided - so each mutation silences
exactly one check and names the scenario that has to notice.

`role` is next, and it is the only one left.

Copy the harness rather than inventing one: `sim/sync/run-sim-sync.sh` is the
pattern here, and `tp/tests/sim/run-sim.sh` is the older one it came from.
`scenario` / `done_scenario` / `has` / `traced` / `clean` are the whole
interface.

Traps that have each cost an hour, written down so they cost nothing:

**Exported functions need an exported environment.** The dispatcher sets its own
PATH, so a simulator cannot reach its fakes by prepending a directory -
`run_ks` exports shell *functions* instead. Those bodies are re-parsed by the
child bash, so every variable they name has to be in its environment. A shell
variable of the harness is not, and under `set -u` the dispatcher dies on the
first ssh complaining about an unbound variable, which looks nothing like the
actual cause.

**A mutation suite must load the mutant.** `cmd_sync.sh` is sourced, not
executed, so the mutation runner hands the simulator a whole ketsync tree with
one file swapped. The simulator has to take `lib/` from beside the dispatcher
it was given - taking it from the repo root loads the good copy and reports
every single mutation as survived, which is how you get a suite that proves
nothing while looking thorough.

**A mutation that cannot be applied proves nothing and can still look green.**
perl writes nothing when its program does not compile, and an empty mutant
"kills" every scenario because it does nothing at all. Check perl's exit status,
check the size, and check that the mutant actually differs from the original.
`self_check` runs all three probes before grading anything.

**An exit inside `$( )` ends the subshell, not the run.** `target="$(require_node
"$2")"` prints the refusal and then carries on with an empty target, which means
every node instead of none.
