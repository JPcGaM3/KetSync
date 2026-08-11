# =============================================================================
#  ketsync — one entry point for every repeatable task.
#  `make` with no target prints this list.
#
#  This repo holds two layers. `ketsync` decides; `engines/tp` moves. Most of
#  the test weight lives in tp, so every gate here runs both halves: a target
#  that only checked the decision layer would go green while the layer that
#  actually touches customer data was broken.
# =============================================================================
SHELL   := /bin/bash
ROOT    := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
TP      := $(ROOT)/engines/tp

SHIPPED := $(ROOT)/ketsync $(ROOT)/lib/*.sh

.DEFAULT_GOAL := help
.PHONY: help lint lint-ketsync lint-tp syntax shellcheck \
        test test-ketsync test-tp mutation tp-present clean

help:            ## show this list
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[1m%-14s\033[0m %s\n", $$1, $$2}'

# -- the guard every delegating target goes through ---------------------------
# engines/tp is committed here, so a missing one means a broken checkout, not a
# clone step somebody forgot. Say which it is rather than letting make print
# "No rule to make target".
tp-present:
	@if [ ! -f $(TP)/Makefile ]; then \
	  echo "engines/tp is missing or incomplete - this checkout is broken."; \
	  echo "It is committed in this repo; re-clone rather than cloning tp separately."; \
	  exit 1; fi

# -- static checks ------------------------------------------------------------
lint: lint-ketsync lint-tp  ## static checks for both layers, no cluster needed

lint-ketsync: syntax shellcheck  ## the decision layer only

lint-tp: tp-present   ## the engines: bash -n, shellcheck, the language rule, doc embeds
	@$(MAKE) --no-print-directory -C $(TP) lint

syntax:          ## bash -n everything ketsync ships
	@rc=0; for f in $(SHIPPED); do bash -n "$$f" || { echo "  syntax error: $$f"; rc=1; }; done; \
	 [ $$rc -eq 0 ] && echo "bash -n: clean"; exit $$rc

shellcheck:      ## shellcheck, if it is installed
	@if command -v shellcheck >/dev/null; then \
	  shellcheck -x -S warning $(SHIPPED) && echo "shellcheck: clean" \
	  || { echo "shellcheck: FAILED"; exit 1; }; \
	else echo "shellcheck not installed - skipped"; fi

# -- tests --------------------------------------------------------------------
# `test` must be able to go green, because a gate that is red every single day
# teaches everybody to ignore red - and then a real tp regression goes past
# unnoticed. So the missing ketsync simulator is a loud warning here and a hard
# failure in test-ketsync, which is the target that owns that debt.
test: test-tp     ## the real suite: all three engines, the dispatcher, c2v, python
	@echo
	@echo "WARNING: ketsync itself has no simulator. sync/role/doctor are untested."
	@echo "         See tests/README.md. Nothing here may write to a real machine"
	@echo "         before it has one. Run 'make test-ketsync' to see this fail."

test-tp: tp-present  ## engines/tp: every simulator, the dispatcher, c2v, unit tests
	@$(MAKE) --no-print-directory -C $(TP) test

test-ketsync:    ## the decision layer (see tests/README.md - not written yet)
	@if [ -x $(ROOT)/tests/sim/run-sim.sh ]; then $(ROOT)/tests/sim/run-sim.sh; \
	 else echo "no simulator yet - see tests/README.md. Do not ship a command without one."; exit 1; fi

mutation: tp-present  ## put every known bug back and prove the suites still notice
	@$(MAKE) --no-print-directory -C $(TP) mutation

clean:           ## remove run leftovers (never touches inventory or config)
	@rm -rf $(ROOT)/logs/*.log
	@if [ -f $(TP)/Makefile ]; then $(MAKE) --no-print-directory -C $(TP) clean; fi
	@echo "clean"
