# engines/

`tp` goes here — the whole repo, unmodified.

    git clone <the tp repo> engines/tp

Or as a submodule, if you would rather pin a revision:

    git submodule add <the tp repo> engines/tp

## Why it is vendored rather than rewritten

`tp` is three bash engines that move running production containers, anchored by
179 simulator scenarios and 117 mutations. In one week those suites caught five
real bugs, and every one of them was the same shape: a lesson learned once in
`ct-migrate.sh` and lost when a newer engine was written from scratch.

`ketsync` does not repeat any of that work. It decides who is in charge, where
each container lives and where its copy goes; `tp` does the moving, with the
guards it already has. If something is wrong in the moving, fix it in `tp` and
its mutation suite - never by writing a second copy here.

`ketsync doctor` fails when this directory is empty, because a decision layer
with nothing underneath it cannot do anything at all.
