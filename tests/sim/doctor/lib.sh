#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
#  lib.sh — shared state for the doctor simulator's fakes.
# -----------------------------------------------------------------------------
#  `ketsync doctor` reads. That is the whole of it, and it is why this was the
#  last command here without a simulator: nothing it does can corrupt anything,
#  so nothing it does looked worth testing.
#
#  What it can do is be WRONG, quietly, in the direction that matters. Every
#  section of it exists because something in this fleet's history was true and
#  invisible - a copy three days old, a container still on the isolation
#  bridge, a cron line that would refuse to run, an image whose filesystem has
#  recorded an error. A check that stops firing does not fail: it reports a
#  healthy fleet, which is the same output as a healthy fleet, and the first
#  anybody hears of the difference is during the next disaster.
#
#  So the fleet lives under $SIMROOT and every machine is a whole filesystem,
#  the same way the sync simulator models one:
#
#    $SIMROOT/master/            this machine's install. KS_BASE points here
#    $SIMROOT/hosts/<ip>/fs/...  that machine's filesystem, from /
#    $SIMROOT/hosts/<ip>/.down   unreachable: ssh exits 255, which is a
#                                different fact from "the file is not there"
#    $SIMROOT/hosts/<ip>/ct/<id>.*   what that node would say about a container
#
#  A violation is not a failed assertion, it is a fake refusing to pretend.
# =============================================================================
violation(){ printf 'VIOLATION: %s\n' "$*" >> "$SIMROOT/violations"; }
trace(){     printf '%s\n' "$*" >> "$SIMROOT/trace"; }

host_dir(){ printf '%s/hosts/%s' "$SIMROOT" "$1"; }
host_up(){  [[ ! -f "$(host_dir "$1")/.down" ]]; }
remote_path(){ printf '%s/fs%s' "$(host_dir "$1")" "$2"; }
