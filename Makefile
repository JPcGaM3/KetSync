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

SHIPPED := $(ROOT)/ketsync $(ROOT)/lib/*.sh $(ROOT)/tools/*.sh \
           $(ROOT)/tests/sim/sync/run-sim-sync.sh $(ROOT)/tests/sim/sync/lib.sh \
           $(ROOT)/tests/sim/sync/bin/ssh $(ROOT)/tests/sim/sync/bin/rsync \
           $(ROOT)/tests/sim/doctor/run-sim-doctor.sh $(ROOT)/tests/sim/doctor/lib.sh \
           $(ROOT)/tests/sim/doctor/bin/ssh \
           $(ROOT)/tests/mutation/run-mutation-sync.sh \
           $(ROOT)/tests/mutation/run-mutation-doctor.sh

.DEFAULT_GOAL := help
.PHONY: help lint lint-ketsync lint-tp syntax shellcheck no-thai \
        test test-ketsync test-tp mutation mutation-ketsync tp-present clean

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

lint-ketsync: syntax shellcheck no-thai  ## the decision layer only

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

no-thai:         ## code is English; only docs/*.html may be Thai, never in <pre>
	@$(ROOT)/tools/check-no-thai.sh

# -- tests --------------------------------------------------------------------
# This layer had no simulator at all for its first nine commits, and `test`
# carried a warning saying so. sync went first because it is the only command
# here that writes to another machine; doctor went last because it writes
# nothing at all - and writing its simulator found a check that had been
# reporting a compute node nobody could ssh to as expected, months after every
# DR verb started needing that connection. `role` is what is left, and the
# warning says so by name, because a warning that lists nothing specific is one
# nobody acts on.
test: test-tp test-ketsync  ## the real suite: both layers
	@echo
	@echo "NOTE: ketsync role still has no simulator. sync, distribute, the"
	@echo "      confirmation and doctor do. See tests/README.md before adding"
	@echo "      another command that writes to a real machine."

test-tp: tp-present  ## engines/tp: every simulator, the dispatcher, c2v, unit tests
	@$(MAKE) --no-print-directory -C $(TP) test

test-ketsync:    ## the decision layer: sync, distribute, the confirmation, doctor
	@$(ROOT)/tests/sim/sync/run-sim-sync.sh
	@$(ROOT)/tests/sim/distribute/run-sim-distribute.sh
	@$(ROOT)/tests/sim/confirm/run-sim-confirm.sh
	@$(ROOT)/tests/sim/doctor/run-sim-doctor.sh

mutation: tp-present mutation-ketsync  ## put every known bug back and prove the suites still notice
	@$(MAKE) --no-print-directory -C $(TP) mutation

mutation-ketsync:  ## the decision layer's own mutations
	@$(ROOT)/tests/mutation/run-mutation-sync.sh
	@$(ROOT)/tests/mutation/run-mutation-distribute.sh
	@$(ROOT)/tests/mutation/run-mutation-confirm.sh
	@$(ROOT)/tests/mutation/run-mutation-doctor.sh

clean:           ## remove run leftovers (never touches inventory or config)
	@rm -rf $(ROOT)/logs/*.log
	@if [ -f $(TP)/Makefile ]; then $(MAKE) --no-print-directory -C $(TP) clean; fi
	@echo "clean"
