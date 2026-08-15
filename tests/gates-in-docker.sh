#!/usr/bin/env bash
# =============================================================================
#  gates-in-docker.sh — run the gates against the userland they ship to.
# -----------------------------------------------------------------------------
#  Why this exists: this repo is developed on a Mac and runs on Proxmox, and
#  there is no server to test on. The gates therefore have to run somewhere that
#  is Debian, and the only such place on a laptop is a container.
#
#  They cannot run natively on macOS, and the reason is worth writing down
#  because it looks like a passing run:
#
#    - macOS has no flock. `if ! flock -n 9` reads command-not-found as a
#      non-zero exit, which is indistinguishable from "the lock is held", so
#      ct-migrate.sh logs "another sync is running" and exits 0 having done
#      nothing. A missing tool produced a silent green run, which is the one
#      outcome this repo refuses everywhere else.
#    - /bin/bash on macOS is 3.2: no `declare -A`, no `mapfile`. ct-replica.sh
#      and ct-failback.sh declare their maps above their lock, so they die
#      before they ever reach flock. `bash -n` catches neither - both parse
#      fine in 3.2 and fail at runtime, so `make lint` passes and tells you
#      nothing.
#    - stat -c, df -B1 --output and truncate are GNU. BSD has other spellings.
#
#  Homebrew does not fix this, because of rule 8. Every engine hard-codes
#  PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin, so
#  /opt/homebrew/bin is unreachable from inside an engine by design - the same
#  reason the simulators reach their fakes with exported functions rather than
#  a prepended directory. The only entry in that list writable on macOS is
#  /usr/local/bin, and putting GNU stat and df there shadows the BSD ones for
#  every other program on the machine. That is a system-wide change to fix a
#  test harness.
#
#  usage:  ./tests/gates-in-docker.sh                 lint, test and mutation
#          ./tests/gates-in-docker.sh mutation        one target
#          ./tests/gates-in-docker.sh lint test       several
#          make gates                                 same thing, from the root
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"          # rule 7: found relative to this script

# bookworm because PVE 8 is bookworm. The point is not "a Linux" but the same
# userland the engines meet on the fleet - a musl or a newer glibc would pass
# for reasons that do not transfer. Override when the fleet moves to trixie.
IMAGE="${TP_GATE_IMAGE:-debian:bookworm}"

# What the suites actually need. shellcheck is here rather than optional
# because its leg of `make lint` silently skips when it is absent, and a lint
# that skips half of itself is the kind of quiet pass this repo exists to
# prevent. git is deliberately NOT in this list: the suites do not use it, and
# leaving it out is what proves that.
PKGS="shellcheck rsync perl make python3-pytest python3-jsonschema"

TARGETS=("$@")
[[ ${#TARGETS[@]} -eq 0 ]] && TARGETS=(lint test mutation)

if ! command -v docker >/dev/null; then
  echo "docker not found - the gates cannot run on macOS itself, see the top of this file" >&2
  echo "  install Docker Desktop or OrbStack, then run this again" >&2
  exit 2
fi
if ! docker info >/dev/null 2>&1; then
  echo "the docker daemon is not running - start it and run this again" >&2
  exit 2
fi

# The repo goes in read-only and is copied to a container-local directory. Two
# separate reasons, both worth keeping: a gate that can write to the tree it is
# grading is not a gate, and a macOS bind mount is slow enough through VirtioFS
# that the mutation suite - which rewrites an engine 74 times and runs every
# scenario against each - crawls when it runs on one.
docker run --rm -v "$ROOT":/src:ro "$IMAGE" bash -c "
  set -uo pipefail
  apt-get update -qq >/dev/null 2>&1
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $PKGS >/dev/null 2>&1 \
    || { echo 'apt-get failed - no network, or the image moved on' >&2; exit 2; }
  cp -a /src /work && cd /work || exit 2
  rc=0
  for t in ${TARGETS[*]}; do
    echo \"=== make \$t ===\"
    make \"\$t\" || rc=1
  done
  exit \$rc
"
