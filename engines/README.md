# engines/

`tp` lives here, in this repo, at `engines/tp`. It is not a submodule and it is
not a clone step — clone this repo and the engines are already there.

    engines/tp/ct-migrate.sh    old standalone node  -> raw image on the storage node
    engines/tp/ct-replica.sh    live image here      -> stopped copy on the backup node
    engines/tp/ct-failback.sh   promoted copy        -> back into the production image
    engines/tp/ct-distribute.sh a DR copy -> a compute node's OWN storage, so it
                                can run while the storage node is gone
    engines/tp/tp               the dispatcher: status, doctor, and the four above

It arrived here from the standalone `tp` repository at commit `b4ddc0c`, whole
and unmodified. That repository is the ancestor, not a live upstream: from now
on the engines are edited here, so there is one place to change a guard and one
place to prove it still holds.

## Why it is vendored rather than rewritten

`tp` is five bash engines that move running production containers, anchored by
311 simulator scenarios and 268 mutations. In one week those suites caught five
real bugs, and every one of them was the same shape: a lesson learned once in
`ct-migrate.sh` and lost when a newer engine was written from scratch.

`ketsync` does not repeat any of that work. It decides who is in charge, where
each container lives and where its copy goes; `tp` does the moving, with the
guards it already has. If something is wrong in the moving, fix it in
`engines/tp` and its mutation suite — never by writing a second copy in `lib/`.

## Working in here

`engines/tp/CLAUDE.md` governs everything under this directory and its rules
win over the ones at the top of this repo wherever they overlap. Two of them
catch people out immediately: every mutation is anchored on literal text inside
its engine, so an engine edit and its mutation move in the same commit; and
code is English everywhere, with Thai allowed only as prose in `docs/*.html`
and never inside `<pre>` or `<code>`.

The gates are wired through the top-level `Makefile`, so `make lint`, `make
test` and `make mutation` at the root of this repo run tp's suites as well as
ketsync's own checks. `make -C engines/tp <target>` still works if you want a
single engine — `test-replica`, `mutation-failback`, and the rest.

## Deploying

`ketsync doctor` fails when this directory is empty, because a decision layer
with nothing underneath it cannot do anything at all.
