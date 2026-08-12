# =============================================================================
#  tp — one entry point for every repeatable task.
#  `make` with no target prints this list.
# =============================================================================
SHELL   := /bin/bash
ROOT    := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
PY      ?= python3
ZIP     ?= tp.zip

# Every engine, in one place. Adding one means adding it here and nowhere else
# - the lint and syntax targets read this list. ct-distribute.sh was missing
# from it for its whole life, so shellcheck had never seen the engine that runs
# during the worst hour this fleet will have.
ENGINES := $(ROOT)/ct-migrate.sh $(ROOT)/ct-replica.sh $(ROOT)/ct-failback.sh \
           $(ROOT)/ct-distribute.sh $(ROOT)/ct-recall.sh
SHIPPED := $(ENGINES) $(ROOT)/tp $(ROOT)/bkp02-setup.sh $(ROOT)/tools/*.sh

.DEFAULT_GOAL := help
.PHONY: help test test-sim test-migrate test-replica test-failback test-distribute test-recall test-c2v \
        mutation mutation-migrate mutation-replica mutation-failback mutation-distribute mutation-recall mutation-tp \
        gates test-tp \
        lint syntax shellcheck no-thai log-sep zip clean schema-check

help:            ## show this list
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[1m%-16s\033[0m %s\n", $$1, $$2}'

test: test-sim test-tp test-c2v  ## every simulator, the dispatcher, and the c2v checks

test-sim: test-migrate test-replica test-failback test-distribute test-recall  ## every engine against its fake PVE

test-migrate:    ## ct-migrate.sh: old node -> raw image here
	@$(ROOT)/tests/sim/run-sim.sh

test-replica:    ## ct-replica.sh: live image here -> stopped copy on the backup node
	@$(ROOT)/tests/sim/replica/run-sim-replica.sh

test-failback:   ## ct-failback.sh: promoted copy -> back into the production image
	@$(ROOT)/tests/sim/failback/run-sim-failback.sh

test-distribute: ## ct-distribute.sh: a DR copy -> a compute node's own storage
	@$(ROOT)/tests/sim/distribute/run-sim-distribute.sh

test-recall:     ## ct-recall.sh: a compute node's 9<id> -> back into its DR copy
	@$(ROOT)/tests/sim/recall/run-sim-recall.sh

test-tp:         ## the dispatcher: tp status, tp doctor, and argument pass-through
	@$(ROOT)/tests/tp/run-tp.sh

test-c2v:        ## check what both phase-2 scripts write, EL and Debian alike
	@$(ROOT)/tests/c2v/run-c2v.sh

mutation: mutation-migrate mutation-replica mutation-failback mutation-distribute mutation-recall mutation-tp  ## break every engine and the dispatcher on purpose, prove the suites notice

mutation-migrate:  ## 45 known bugs put back into ct-migrate.sh
	@$(ROOT)/tests/mutation/run-mutation.sh

mutation-replica:  ## 57 known bugs put back into ct-replica.sh
	@$(ROOT)/tests/mutation/run-mutation-replica.sh

mutation-failback: ## 58 known bugs put back into ct-failback.sh
	@$(ROOT)/tests/mutation/run-mutation-failback.sh

mutation-distribute: ## 50 known bugs put back into ct-distribute.sh
	@$(ROOT)/tests/mutation/run-mutation-distribute.sh

mutation-recall:   ## 41 known bugs put back into ct-recall.sh
	@$(ROOT)/tests/mutation/run-mutation-recall.sh

mutation-tp:       ## 9 known bugs put back into the tp dispatcher
	@$(ROOT)/tests/mutation/run-mutation-tp.sh

# The gates above assume a Debian userland. On the Mac this repo is written on
# they do not merely fail, they pass wrongly - see the top of the script.
gates:           ## lint + test + mutation in a Debian container (use this on macOS)
	@$(ROOT)/tests/gates-in-docker.sh


lint: syntax shellcheck no-thai log-sep  ## static checks that need no cluster

syntax:          ## bash -n every shell script
	@rc=0; while read -r f; do \
	  bash -n "$$f" || { echo "  syntax error: $$f"; rc=1; }; \
	done < <(find $(ROOT) -name '*.sh' -not -path '*/.git/*'); \
	for f in $(ENGINES) $(ROOT)/tp; do bash -n "$$f" || rc=1; done; \
	[ $$rc -eq 0 ] && echo "bash -n: clean"; exit $$rc

shellcheck:      ## shellcheck, if it is installed
	@if command -v shellcheck >/dev/null; then \
	  shellcheck -x -S warning $(SHIPPED) \
	    $(ROOT)/tests/sim/run-sim.sh $(ROOT)/tests/sim/lib.sh \
	    $(ROOT)/tests/mutation/run-mutation.sh \
	    $(ROOT)/tests/sim/replica/run-sim-replica.sh $(ROOT)/tests/sim/replica/lib.sh \
	    $(ROOT)/tests/sim/failback/run-sim-failback.sh $(ROOT)/tests/sim/failback/lib.sh \
	    $(ROOT)/tests/mutation/run-mutation-replica.sh \
	    $(ROOT)/tests/mutation/run-mutation-failback.sh \
	    $(ROOT)/tests/sim/distribute/run-sim-distribute.sh $(ROOT)/tests/sim/distribute/lib.sh \
	    $(ROOT)/tests/mutation/run-mutation-distribute.sh \
	    $(ROOT)/tests/sim/recall/run-sim-recall.sh $(ROOT)/tests/sim/recall/lib.sh \
	    $(ROOT)/tests/mutation/run-mutation-recall.sh \
	    $(ROOT)/tests/c2v/run-c2v.sh $(ROOT)/tests/gates-in-docker.sh \
	    $(ROOT)/tests/tp/run-tp.sh $(ROOT)/tests/mutation/run-mutation-tp.sh \
	    $(ROOT)/tools/check-log-separator.sh \
	  && echo "shellcheck: clean" \
	  || { echo "shellcheck: FAILED"; exit 1; }; \
	else echo "shellcheck not installed - skipped"; fi


no-thai:         ## code is English, only docs/*.html may be Thai
	@$(ROOT)/tools/check-no-thai.sh

log-sep:         ## every tool that logs also separates its operations
	@$(ROOT)/tools/check-log-separator.sh

schema-check:    ## validate every state/*.json against schema/state.schema.json
	@cd $(ROOT) && PYTHONPATH=src $(PY) -m ctmig.cli validate

zip: clean       ## build the deployable archive (no runtime state, no .git)
	@cd $(ROOT) && rm -f $(ZIP) && zip -rq $(ZIP) . \
	  -x '.git/*' '*/__pycache__/*' '.pytest_cache/*' '*.egg-info/*' \
	     '.mypy_cache/*' '.ruff_cache/*' '.venv/*' 'venv/*' \
	     'logs/*' 'done/*' 'state/*' \
	     '.sync-*.lock' '.node-*.lock' '.replica-*.lock' '.failback-*.lock' \
	     '.distribute.lock' '.recall.lock' \
	     'PAUSE' 'inventory-migrate.tsv' 'inventory-replica.tsv' 'bridgemap.tsv' '$(ZIP)' \
	  && echo "built $(ZIP) ($$(unzip -l $(ZIP) | tail -1 | awk '{print $$2}') entries)"

clean:           ## remove build/test leftovers (never touches state/ or done/)
	@rm -rf $(ROOT)/$(ZIP)
	@find $(ROOT) -name __pycache__ -type d -exec rm -rf {} + 2>/dev/null; true
	@echo "clean"
