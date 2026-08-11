# =============================================================================
#  ketsync — one entry point for every repeatable task.
#  `make` with no target prints this list.
# =============================================================================
SHELL   := /bin/bash
ROOT    := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))

SHIPPED := $(ROOT)/ketsync $(ROOT)/lib/*.sh

.DEFAULT_GOAL := help
.PHONY: help lint syntax shellcheck test clean

help:            ## show this list
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[1m%-12s\033[0m %s\n", $$1, $$2}'

lint: syntax shellcheck  ## static checks that need no cluster

syntax:          ## bash -n everything
	@rc=0; for f in $(SHIPPED); do bash -n "$$f" || { echo "  syntax error: $$f"; rc=1; }; done; \
	 [ $$rc -eq 0 ] && echo "bash -n: clean"; exit $$rc

shellcheck:      ## shellcheck, if it is installed
	@if command -v shellcheck >/dev/null; then \
	  shellcheck -x -S warning $(SHIPPED) && echo "shellcheck: clean" \
	  || { echo "shellcheck: FAILED"; exit 1; }; \
	else echo "shellcheck not installed - skipped"; fi

test:            ## the simulator (see tests/README.md - not written yet)
	@if [ -x $(ROOT)/tests/sim/run-sim.sh ]; then $(ROOT)/tests/sim/run-sim.sh; \
	 else echo "no simulator yet - see tests/README.md. Do not ship an engine without one."; exit 1; fi

clean:           ## remove run leftovers (never touches inventory or config)
	@rm -rf $(ROOT)/logs/*.log; echo "clean"
