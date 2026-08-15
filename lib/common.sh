#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034,SC1090,SC1091
# =============================================================================
#  common.sh — log, config, and the tables everything reads.
#  Sourced, never executed. KS_BASE is set by the dispatcher.
# =============================================================================
# ---------- where the log goes ----------
# ONE tree for both layers: the four engines write their own days into this
# same directory, each file named after the verb an operator typed. A bad
# night is then one directory to read and one tarball to send, instead of two
# places to remember at 3am.
#
#   logs/ketsync-<date>.log      sync, role, doctor - the decisions
#   logs/migrate-<lane>-<date>.log
#   logs/replica-<lane>-<date>.log
#   logs/failback-<date>.log
#   logs/distribute-<date>.log   the engines - what actually moved
#
# Commands that are passed through to tp exec into it and log as the engine,
# not as the dispatcher: there is one record of a replica round, written by the
# thing that ran it.
KS_LOGDIR="$KS_BASE/logs"
KS_LOG="$KS_LOGDIR/ketsync-$(date +%F).log"
KS_LOG_KEEP_DAYS=14           # tp prunes its own the same way; 0 disables
KS_COPY_STALE_DAYS=2          # doctor complains about a DR copy older than this
mkdir -p "$KS_LOGDIR" 2>/dev/null
# Prune before opening today's file, so the run that finally fills the disk is
# not this one. Only ketsync-*.log at depth 1: the engines' days live here too
# and each one prunes its own.
if [[ "$KS_LOG_KEEP_DAYS" =~ ^[0-9]+$ ]] && (( KS_LOG_KEEP_DAYS > 0 )); then
  find "$KS_LOGDIR" -maxdepth 1 -type f -name 'ketsync-*.log' \
       -mtime +"$KS_LOG_KEEP_DAYS" -delete 2>/dev/null || true
fi

log(){ printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$KS_LOG"; }
hr(){  printf '%s\n' "##############################################################################" | tee -a "$KS_LOG"; }
die(){ log "ERROR: $*"; exit 2; }

# doctor is a report, not a transcript: its lines are aligned columns a human
# reads, and a timestamp in front of every one of them makes the table
# unreadable. say() keeps the screen clean AND still leaves a record, which
# matters because doctor is the command most likely to be run from cron and
# the one whose output there was no record of at all until this existed.
say(){ printf '%s\n' "$*"; printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$KS_LOG"; }

# ---------- config -----------------------------------------------------------
# Defaults live here so the sample config can stay short; a value in the file
# always wins. Same split as tp's ctmig.conf / ctrep.conf, for the same reason:
# re-delivering the code must never overwrite a calibrated value.
KS_ROLE=slave                 # master | slave. Changed by hand. See section 2.
KS_MASTER_IP=""               # the machine that owns the tables
# watch's addresses. Empty means "not configured" and watch REFUSES to run -
# an empty default is a refusal waiting to be read, never a guess. The tiers
# are addresses on purpose: routing lives in the mail system, not in code.
KS_MAIL_FROM=""               # the From: on everything watch sends
KS_MAIL_INFRA=""              # immediate: the floor everything stands on
KS_MAIL_NODE=""               # immediate: one machine's problem
KS_MAIL_DIGEST=""             # daily: doctor's whole report (watch --digest)
KS_WATCH_HEALTHCHECK=""       # optional dead-man URL, pinged only by green runs
KS_SSH_OPTS="-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"
KS_CONF="$KS_BASE/conf/ketsync.conf"
KS_NODES="$KS_BASE/conf/nodes.tsv"
KS_INV="$KS_BASE/conf/fleet.tsv"
KS_NODEMAP="$KS_BASE/conf/nodes.map"     # generated, never edited by hand
[[ -f "$KS_CONF" ]] && . "$KS_CONF"

# ---------- nodes.tsv --------------------------------------------------------
# An IP and a role. That is the whole table.
#
#   <ip> <TAB> <role>       role: storage | backup | compute
#
# There is no name column and nothing here resolves a hostname. That is not
# tidiness, it is what lets this run from the storage node, which sits OUTSIDE
# the cluster on purpose and therefore has neither the cluster's /etc/hosts nor
# its DNS. An address that only works when a name server answers is an address
# that stops working during the exact incident this tool exists for.
ks_rows(){ awk '$1!~/^#/ && NF>=2 {print}' "$KS_NODES" 2>/dev/null; }
node_role(){     awk -v i="$1" '$1!~/^#/ && $1==i{print $2; exit}' "$KS_NODES" 2>/dev/null; }
nodes_of_role(){ awk -v r="$1" '$1!~/^#/ && $2==r{print $1}'       "$KS_NODES" 2>/dev/null; }
all_node_ips(){  awk '$1!~/^#/ && NF>=2{print $1}'                 "$KS_NODES" 2>/dev/null; }
ip_of_role(){    nodes_of_role "$1" | head -1; }

# An address with no row is a hard stop, never a guess. Guessing puts a
# customer's rootfs on a machine nobody meant. Same rule as tp's rule 5.
require_node(){   # $1 = ip -> confirm it is in the table, or refuse
  [[ -n "$(node_role "$1")" ]] \
    || die "$1 is not in $(basename "$KS_NODES") - add it, do not guess what it is"
  printf '%s' "$1"
}

ks_ssh(){ ssh $KS_SSH_OPTS "root@$1" "${@:2}" </dev/null; }

# ---------- nodes.map: the name nobody types ---------------------------------
# PVE keeps a guest's config at /etc/pve/nodes/<NAME>/lxc/<id>.conf, so a node
# name is unavoidable as *data*. Typing one is avoidable, and typing one is
# where the damage comes from: a name that is wrong, or right and then stale,
# writes a config into a directory belonging to a different machine.
#
# So the map is discovered from the cluster rather than maintained. The storage
# node is not a member and cannot ask directly, so it asks the backup node -
# which is - exactly the way ct-failback.sh asks about a production CT.
#
# The result is cached because discovery needs a quorate cluster, and the run
# that needs this most is the one during an outage. A cached name that is a
# week old is still right; PVE node names effectively never change, and if one
# does, `ketsync doctor` says so on the next good day.
nodemap_refresh(){   # -> writes ip<TAB>name, one node per line. rc 1 if it could not
  local bkp out
  bkp="$(ip_of_role backup)"
  [[ -n "$bkp" ]] || { log "no backup node in $(basename "$KS_NODES") - cannot discover node names"; return 1; }
  out="$(ks_ssh "$bkp" "pvesh get /cluster/status --output-format yaml 2>/dev/null" 2>/dev/null)"
  [[ -n "$out" ]] || return 1
  # One record per node, fields in any order; the cluster itself is also a
  # record and has a name but no ip, which is what type: node filters out.
  out="$(printf '%s\n' "$out" | awk '
    function flush(){ if (t=="node" && n!="" && i!="") print i "\t" n; n=""; i=""; t="" }
    /^-/                        { flush() }
    /^[[:space:]]*name:[[:space:]]/ { n=$2; gsub(/^["\x27]|["\x27]$/,"",n) }
    /^[[:space:]]*ip:[[:space:]]/   { i=$2; gsub(/^["\x27]|["\x27]$/,"",i) }
    /^[[:space:]]*type:[[:space:]]/ { t=$2; gsub(/^["\x27]|["\x27]$/,"",t) }
    END { flush() }')"
  [[ -n "$out" ]] || return 1
  printf '# generated by ketsync from the cluster. Do not edit - it is rewritten.\n# ip\tpve node name\n%s\n' "$out" > "$KS_NODEMAP"
  # ct-failback.sh reads the same file, in the same format, from beside itself:
  # it has to turn the pmxcfs name out of a config path into an address before
  # it can ssh a production node to ask whether a container is stopped. Writing
  # it here rather than making the engine call back up into ketsync keeps the
  # engines standalone - without the map they fall back to the name, which is
  # what they always did.
  return 0
}

# There is no mirror any more. `ketsync doctor` used to cp fleet.tsv and
# nodes.map down into engines/tp and the engines read those copies. It failed
# exactly where it mattered: `ketsync sync` delivers fleet.tsv to a slave's repo
# root, nothing on that machine refreshed the copy, and the copy is gitignored
# so a fresh clone never had one. The backup node answered "CT 110 has no row in
# fleet.tsv" 43 seconds after being sent a fleet.tsv. The engines read these
# files where they live now - see the note at the top of ct-distribute.sh.

node_name(){   # $1 = ip -> its PVE node name from the cache, or empty
  awk -v i="$1" '$1!~/^#/ && $1==i{print $2; exit}' "$KS_NODEMAP" 2>/dev/null; }

# The same refusal as require_node, for the half that cannot be guessed at all.
# Nothing may write into /etc/pve/nodes/<name>/ on a name this did not return.
require_node_name(){   # $1 = ip -> its PVE node name, or refuse
  local n; n="$(node_name "$1")"
  [[ -n "$n" ]] && { printf '%s' "$n"; return 0; }
  nodemap_refresh >/dev/null 2>&1 && n="$(node_name "$1")"
  [[ -n "$n" ]] || die "no PVE node name known for $1 - run 'ketsync doctor' while the cluster is up"
  printf '%s' "$n"
}

# ---------------------------------------------------------------------------
#  ks_confirm — the last thing between a person and a command that writes
# ---------------------------------------------------------------------------
#  Not "are you sure". A prompt that asks that teaches people to press y
#  without reading, and then it is worth less than nothing because it looks
#  like a safety net while being a keystroke. This one states what the command
#  writes and how to see it first, and defaults to NO.
#
#  It lives here, at the dispatcher, and not in the engines. The engines are
#  what cron calls - `ct-replica.sh --storage tank-hdd-nas` in a crontab is
#  reviewed once, by somebody awake, and prompting it would mean every existing
#  cron line silently stopping until a flag was added. A person types
#  `ketsync`. That is the line where a person is standing.
#
#  NO TTY AND NO -y IS A REFUSAL, not a silent no. `read` with nothing on stdin
#  returns immediately and empty; taking that as "no" and exiting 0 would be a
#  scheduled run reporting success every night having done nothing at all,
#  which is the one outcome this repo refuses everywhere else.
ks_confirm(){   # $1 = one line saying what this writes, $2.. = how to preview
  local ans
  if [[ "${KS_ASSUME_YES:-0}" == 1 ]]; then return 0; fi
  if [[ ! -t 0 ]]; then
    say "REFUSED: this command writes, and there is nobody here to ask."
    say "  $1"
    say "  running from cron or a script? add -y, which means you have already"
    say "  decided. It skips the question and nothing else - no guard, ever."
    return 2
  fi
  printf '%s\n' "$1"
  local l; for l in "${@:2}"; do printf '%s\n' "$l"; done
  printf 'proceed? [y/N] '
  read -r ans || ans=""
  case "$ans" in
    y|Y|yes|YES) return 0;;
    *) say "nothing was done."; return 1;;
  esac
}
