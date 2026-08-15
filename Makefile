# =============================================================================
#  ketsync — one entry point for every repeatable task.
#  `make` with no target prints this list.
#
#  One tree since the restructure: bin/ is what a person runs, engines/ is
#  what moves the bytes, lib/ is the decision layer, tests/ holds every
#  simulator and every mutation suite for both. There used to be a second
#  Makefile under engines/tp with its own copies of half these targets;
#  two files owning one gate is how a gate gets out of sync, so it is gone.
# =============================================================================
SHELL   := /bin/bash
ROOT    := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))

# Every engine, in one place. Adding one means adding it here and nowhere else
# - the lint targets read this list. ct-distribute.sh was once missing from
# it for its whole life, so shellcheck had never seen the engine that runs
# during the worst hour this fleet will have.
ENGINES := $(ROOT)/engines/ct-migrate.sh $(ROOT)/engines/ct-replica.sh \
           $(ROOT)/engines/ct-failback.sh $(ROOT)/engines/ct-distribute.sh \
           $(ROOT)/engines/ct-recall.sh $(ROOT)/engines/ct-prepare.sh

SHIPPED := $(ROOT)/bin/ketsync $(ROOT)/lib/*.sh $(ROOT)/tools/*.sh \
           $(ENGINES) $(ROOT)/engines/tp $(ROOT)/contrib/*.sh

# The harnesses are shipped too: a suite with a syntax error is a gate that
# never closes.
SIMS    := $(ROOT)/tests/sim/*/run-sim-*.sh $(ROOT)/tests/sim/*/lib.sh \
           $(ROOT)/tests/mutation/run-mutation-*.sh \
           $(ROOT)/tests/tp/run-tp.sh $(ROOT)/tests/c2v/run-c2v.sh \
           $(ROOT)/tests/gates-in-docker.sh

.DEFAULT_GOAL := help
.PHONY: help lint syntax shellcheck no-thai log-sep \
        test test-engines test-ketsync test-tp test-c2v \
        test-migrate test-replica test-failback test-distribute test-recall test-prepare \
        mutation mutation-engines mutation-ketsync gates clean

help:            ## show this list
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[1m%-16s\033[0m %s\n", $$1, $$2}'

# -- static checks ------------------------------------------------------------
lint: syntax shellcheck no-thai log-sep  ## static checks, no cluster needed

syntax:          ## bash -n everything that ships
	@rc=0; for f in $(SHIPPED) $(SIMS); do \
	  bash -n "$$f" || { echo "  syntax error: $$f"; rc=1; }; done; \
	[ $$rc -eq 0 ] && echo "bash -n: clean"; exit $$rc

shellcheck:      ## shellcheck, if it is installed
	@if command -v shellcheck >/dev/null; then \
	  shellcheck -x -S warning $(SHIPPED) $(SIMS) \
	  && echo "shellcheck: clean" \
	  || { echo "shellcheck: FAILED"; exit 1; }; \
	else echo "shellcheck not installed - skipped"; fi

no-thai:         ## code is English; only docs/th/*.html may be Thai, never in <pre>
	@$(ROOT)/tools/check-no-thai.sh

log-sep:         ## every tool that logs also separates its operations
	@$(ROOT)/tools/check-log-separator.sh

# -- tests --------------------------------------------------------------------
test: test-engines test-tp test-c2v test-ketsync  ## the real suite: everything
	@echo
	@echo "NOTE: ketsync role still has no simulator. sync, distribute, the"
	@echo "      confirmation, doctor and recover do. See tests/README.md before"
	@echo "      adding another command that writes to a real machine."

test-engines: test-migrate test-replica test-failback test-distribute test-recall test-prepare  ## every engine against its fake PVE

test-migrate:    ## ct-migrate.sh: old node -> raw image here
	@$(ROOT)/tests/sim/ct-migrate/run-sim-migrate.sh
test-replica:    ## ct-replica.sh: live image here -> stopped copy on the backup node
	@$(ROOT)/tests/sim/ct-replica/run-sim-replica.sh
test-failback:   ## ct-failback.sh: promoted copy -> back into the production image
	@$(ROOT)/tests/sim/ct-failback/run-sim-failback.sh
test-distribute: ## ct-distribute.sh: a DR copy -> a compute node's own storage
	@$(ROOT)/tests/sim/ct-distribute/run-sim-distribute.sh
test-recall:     ## ct-recall.sh: a compute node's 9<id> -> back into its DR copy
	@$(ROOT)/tests/sim/ct-recall/run-sim-recall.sh
test-prepare:    ## ct-prepare.sh: take a production CT off the wire, and put it back
	@$(ROOT)/tests/sim/ct-prepare/run-sim-prepare.sh

test-tp:         ## the dispatcher: tp status, tp doctor, argument pass-through
	@$(ROOT)/tests/tp/run-tp.sh
test-c2v:        ## what both CT-to-VM phase-2 scripts write
	@$(ROOT)/tests/c2v/run-c2v.sh

test-ketsync:    ## the decision layer: sync, distribute, the confirmation, doctor, recover
	@$(ROOT)/tests/sim/sync/run-sim-sync.sh
	@$(ROOT)/tests/sim/distribute/run-sim-distribute.sh
	@$(ROOT)/tests/sim/confirm/run-sim-confirm.sh
	@$(ROOT)/tests/sim/doctor/run-sim-doctor.sh
	@$(ROOT)/tests/sim/recover/run-sim-recover.sh

# -- mutations ----------------------------------------------------------------
mutation: mutation-engines mutation-ketsync  ## put every known bug back, prove the suites notice

mutation-engines:  ## the engines and their dispatcher
	@$(ROOT)/tests/mutation/run-mutation-ct-migrate.sh
	@$(ROOT)/tests/mutation/run-mutation-ct-replica.sh
	@$(ROOT)/tests/mutation/run-mutation-ct-failback.sh
	@$(ROOT)/tests/mutation/run-mutation-ct-distribute.sh
	@$(ROOT)/tests/mutation/run-mutation-ct-recall.sh
	@$(ROOT)/tests/mutation/run-mutation-ct-prepare.sh
	@$(ROOT)/tests/mutation/run-mutation-tp.sh

mutation-ketsync:  ## the decision layer's own mutations
	@$(ROOT)/tests/mutation/run-mutation-sync.sh
	@$(ROOT)/tests/mutation/run-mutation-distribute.sh
	@$(ROOT)/tests/mutation/run-mutation-confirm.sh
	@$(ROOT)/tests/mutation/run-mutation-doctor.sh
	@$(ROOT)/tests/mutation/run-mutation-recover.sh

# The gates assume a Debian userland. On macOS they do not merely fail, they
# pass wrongly - no flock, bash 3.2 - see the top of the script.
gates:           ## lint + test + mutation in a Debian container (use this on macOS)
	@$(ROOT)/tests/gates-in-docker.sh

clean:           ## remove run leftovers (never touches inventory, conf or state)
	@rm -rf $(ROOT)/logs/*.log $(ROOT)/engines/logs/*.log
	@echo "clean"
