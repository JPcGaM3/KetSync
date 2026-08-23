#!/usr/bin/env bash
# =============================================================================
#  ketsync-completion.bash — TAB completion for ketsync / ./ketsync
# -----------------------------------------------------------------------------
#  install, once per machine (as the user that runs ketsync):
#
#    echo 'source /root/ketsync/tools/ketsync-completion.bash' >> /root/.bashrc
#
#  or system-wide, if the bash-completion package is present:
#
#    ln -s /root/ketsync/tools/ketsync-completion.bash \
#          /etc/bash_completion.d/ketsync
#
#  What completes, and where the answers come from:
#
#    verbs        ketsync repl<TAB>            the dispatcher's own list. The
#                                             list here is CHECKED against
#                                             bin/ketsync by the completion
#                                             suite, so it cannot drift quietly
#    flags        ketsync replica --<TAB>      each verb's real flag set
#    --ctid       from the same work list the verb reads: inventory-replica.tsv
#                 (replica, failback), inventory-migrate.tsv column 3 (migrate),
#                 conf/fleet.tsv (distribute, recall, prepare and friends)
#    --dest       the BKP_DESTS keys in conf/ctrep.conf
#    --storage    migrate: the storage column of its inventory. replica: the
#                 lanes that have actually run, read from logs/replica-*.log
#                 file names - the one place the lane names are written down
#    --to --node  first column of conf/nodes.tsv
#
#  Everything is best-effort: an unreadable file means no suggestions, never an
#  error. Completion must not have opinions a keystroke cannot overrule.
#
#  Works for `ketsync`, `./ketsync` and any path form: bash falls back to the
#  basename when no completion is bound to the exact word, and the repo root is
#  resolved from the command word itself (following the ketsync -> bin/ketsync
#  symlink), so the inventory read belongs to the checkout being completed.
# =============================================================================

# The repo root of the command word being completed. Echoes nothing when it
# cannot tell - callers treat that as "no file-backed suggestions".
_ketsync_root(){
  local w="$1" p d
  if [[ "$w" == */* ]]; then p="$w"; else p="$(command -v -- "$w" 2>/dev/null)"; fi
  [[ -n "$p" ]] || return 0
  # follow the root symlink (ketsync -> bin/ketsync) without needing GNU
  # readlink -f: one hop is the only shape this repo ships
  if [[ -L "$p" ]]; then
    d="$(cd "$(dirname -- "$p")" 2>/dev/null && pwd)" || return 0
    local t; t="$(readlink -- "$p")"
    # readlink may answer relative (the repo-root symlink: bin/ketsync) or
    # absolute (an operator's own ln -s /root/ketsync/bin/ketsync elsewhere)
    case "$t" in /*) p="$t";; *) p="$d/$t";; esac
  fi
  d="$(cd "$(dirname -- "$p")" 2>/dev/null && pwd)" || return 0
  # the command lives in bin/ (or is the repo-root symlink); the repo root is
  # whichever of the two holds conf/
  if [[ -d "$d/conf" ]]; then echo "$d"
  elif [[ -d "$d/../conf" ]]; then (cd "$d/.." && pwd)
  fi
}

# first column of a tab-separated table, comments and blanks skipped
_ketsync_col(){ # $1=file $2=column
  [[ -r "$1" ]] || return 0
  awk -v c="$2" '/^[[:space:]]*(#|$)/{next}{print $c}' "$1" 2>/dev/null
}

_ketsync(){
  local cur prev root verb i w
  COMPREPLY=()
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]:-}"
  root="$(_ketsync_root "${COMP_WORDS[0]}")"

  # The verb list. One line, alphabetical-ish by workflow, and the completion
  # suite diffs it against bin/ketsync's dispatch table - adding a subcommand
  # without updating this line is a red gate, not a quiet gap.
  local verbs="replica failback migrate distribute recall prepare isolate restore evacuate cleanup recover status sync role doctor watch mail-setup tp version help"

  # find the verb: the first word after the program name that is not -y.
  # `ketsync tp replica ...` completes exactly like `ketsync replica ...`,
  # because tp passes its arguments through untouched.
  verb=""
  for (( i=1; i<COMP_CWORD; i++ )); do
    w="${COMP_WORDS[i]}"
    [[ "$w" == -y || "$w" == tp ]] && continue
    verb="$w"; break
  done

  if [[ -z "$verb" ]]; then
    mapfile -t COMPREPLY < <(compgen -W "$verbs -y" -- "$cur")
    return 0
  fi

  # a flag that takes a value: suggest the values the verb will actually accept
  case "$prev" in
    --ctid)
      case "$verb" in
        replica|failback)
          mapfile -t COMPREPLY < <(compgen -W "$(_ketsync_col "$root/inventory/inventory-replica.tsv" 1)" -- "$cur"); return 0;;
        migrate)
          mapfile -t COMPREPLY < <(compgen -W "$(_ketsync_col "$root/inventory/inventory-migrate.tsv" 3)" -- "$cur"); return 0;;
        distribute|recall|prepare|isolate|restore|evacuate|cleanup|recover)
          mapfile -t COMPREPLY < <(compgen -W "$(_ketsync_col "$root/conf/fleet.tsv" 1)" -- "$cur"); return 0;;
      esac;;
    --storage)
      case "$verb" in
        migrate)
          mapfile -t COMPREPLY < <(compgen -W "$(_ketsync_col "$root/inventory/inventory-migrate.tsv" 5 | sort -u)" -- "$cur"); return 0;;
        replica)
          # the lanes that have actually run: logs/replica-<lane>-<date>.log.
          # The lane may itself contain dashes, so strip the fixed prefix and
          # the fixed date suffix rather than splitting on the dash.
          local lanes=""
          if [[ -n "$root" && -d "$root/logs" ]]; then
            lanes="$(cd "$root/logs" 2>/dev/null && printf '%s\n' replica-*.log 2>/dev/null \
                     | sed -En 's/^replica-(.*)-[0-9]{4}-[0-9]{2}-[0-9]{2}\.log$/\1/p' \
                     | grep -v '^all$' | sort -u)"
          fi
          mapfile -t COMPREPLY < <(compgen -W "$lanes" -- "$cur"); return 0;;
      esac;;
    --dest)
      # BKP_DESTS="replica-hdd:replica-hdd/ct replica-ssd:..." - the keys
      local dests=""
      if [[ -n "$root" && -r "$root/conf/ctrep.conf" ]]; then
        dests="$(sed -n 's/^BKP_DESTS="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$root/conf/ctrep.conf" 2>/dev/null \
                 | tr ' ' '\n' | sed 's/:.*//')"
      fi
      mapfile -t COMPREPLY < <(compgen -W "$dests" -- "$cur"); return 0;;
    --to|--node)
      mapfile -t COMPREPLY < <(compgen -W "$(_ketsync_col "$root/conf/nodes.tsv" 1)" -- "$cur"); return 0;;
    --dst)
      return 0;;   # a storage id on the TARGET node; nothing local knows it
  esac

  # each verb's real flag set, read off its own argument parser
  local flags=""
  case "$verb" in
    replica)    flags="--all --ctid --storage --move-dest --dry-run --help";;
    failback)   flags="--all --ctid --dest --final --list --no-snapshot --dry-run --help";;
    migrate)    flags="--all --ctid --storage --final --dry-run --help";;
    distribute) flags="--all --ctid --dst --to --list --no-prepare --dry-run --help";;
    recall)     flags="--all --ctid --final --list --dry-run --help";;
    prepare)    flags="--isolate --restore --evacuate --cleanup --all --ctid --node --destroy --list --dry-run --help";;
    isolate|restore) flags="--all --ctid --list --dry-run";;
    evacuate)   flags="--all --ctid --node --list --dry-run";;
    cleanup)    flags="--all --ctid --destroy --list --dry-run";;
    recover)    flags="--all --ctid --destroy --list --dry-run";;
    sync)       flags="--dry-run --diff --bump --to";;
    watch)      flags="--list --digest --dry-run";;
    role)       flags="master slave";;
    mail-setup) flags="--test";;
    help)       flags="$verbs";;
    status|doctor|version) flags="";;
  esac
  mapfile -t COMPREPLY < <(compgen -W "$flags" -- "$cur")
  return 0
}

# bash matches the exact command word first and falls back to the basename, so
# binding the basename covers `ketsync`, `./ketsync` and /root/ketsync/ketsync
complete -F _ketsync ketsync
