#!/usr/bin/env bash
# shellcheck shell=bash disable=SC1090,SC1091
# =============================================================================
#  ketsync doctor — the questions nobody remembers to ask, asked on a Tuesday
# -----------------------------------------------------------------------------
#  Everything here is read-only and everything here has been the cause of a
#  real incident somewhere in this fleet's history. Run it before you need it.
#
#  It finishes by running `tp doctor`, so one command covers both layers. The
#  exit code is the worse of the two: a healthy decision layer sitting on top of
#  a broken execution layer is not a healthy system.
# =============================================================================
cmd_doctor(){
  local rc=0 ip role f gen name

  say "== this machine"
  say "  role=$KS_ROLE  master=${KS_MASTER_IP:-<unset>}"
  [[ -n "$KS_MASTER_IP" ]] || { say "  KS_MASTER_IP is unset - nothing knows who to receive from"; rc=1; }

  # Discovery first: everything below wants the map, and this is the one place
  # that is allowed to go and get it.
  say "== PVE node names, from the cluster"
  if nodemap_refresh; then
    say "  refreshed $(basename "$KS_NODEMAP") from the backup node"
  elif [[ -f "$KS_NODEMAP" ]]; then
    say "  could not reach the cluster - using the cached $(basename "$KS_NODEMAP")"
    say "  (that is fine for today; it is not fine for a month)"
    rc=1
  else
    say "  could not reach the cluster and there is no cache."
    say "  Nothing can write a guest config until this works once. Fix the ssh"
    say "  to the backup node first - every other name in this system comes"
    say "  from that one connection."
    rc=1
  fi

  say "== nodes.tsv"
  if [[ ! -f "$KS_NODES" ]]; then
    say "  missing - every address in this system comes from that file"; rc=1
  else
    local row verdict
    while read -r ip role _; do
      [[ "$ip" =~ ^# || -z "${ip:-}" ]] && continue
      name="$(node_name "$ip")"
      # Composed, not printf'd in two halves. Half a line on the screen and the
      # other half in the log is a log that says "SSH FAILS" without saying
      # which machine, which is worth nothing at all a week later.
      row="$(printf '  %-15s %-8s %-12s' "$ip" "${role:-?}" "${name:-<name unknown>}")"
      if ks_ssh "$ip" true 2>/dev/null; then verdict="ssh ok"
      elif [[ "$role" == compute ]]; then
        # This used to read "expected - asked through the cluster API instead",
        # and it was true for about a week. B1 went back to ssh because
        # `pvesh get /nodes/X` can only answer for a member of its own cluster
        # and this machine is deliberately not one; and everything built since
        # runs over that same connection. evacuate disables a storage and
        # unmounts it THERE, isolate writes a net line THERE, distribute issues
        # its transfer THERE, recall reads the 9<id> THERE, cleanup stops it
        # THERE. A compute node this machine cannot reach is a compute node the
        # whole DR cannot use, and doctor calling that expected is doctor
        # reporting a fleet that cannot be recovered as a fleet that is fine.
        verdict="SSH FAILS - no DR can run on this node"; rc=1
      else
        verdict="SSH FAILS"; rc=1
      fi
      say "$row $verdict"
    done < "$KS_NODES"
  fi

  # The one connection everything else is built on. It carries the config sync,
  # the node-name discovery, and every question ct-failback.sh asks about a
  # production CT.
  say "== the backup node, which everything else leans on"
  ip="$(ip_of_role backup)"
  if [[ -z "$ip" ]]; then
    say "  no row with role 'backup' in $(basename "$KS_NODES")"; rc=1
  elif ! ks_ssh "$ip" true 2>/dev/null; then
    say "  $ip UNREACHABLE - node names cannot be discovered and a failback"
    say "  cannot ask whether a production CT is stopped. Fix this one first."; rc=1
  else
    say "  $ip ok  (node $(node_name "$ip" || echo '?'))"
  fi

  say "== the files that must carry a generation"
  for f in conf/nodes.tsv conf/fleet.tsv inventory/inventory-replica.tsv inventory/inventory-migrate.tsv; do
    [[ -f "$KS_BASE/$f" ]] || { say "  $f: missing"; rc=1; continue; }
    gen="$(sed -n 's/^#[[:space:]]*generation:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$KS_BASE/$f" | head -1)"
    [[ -n "$gen" ]] && say "  $f: generation $gen" || { say "  $f: NO generation line - sync cannot order it"; rc=1; }
  done

  # Every address written in fleet.tsv has to be one this machine knows about,
  # or a DR lands a customer somewhere nobody planned for.
  say "== fleet.tsv"
  if [[ -f "$KS_INV" ]]; then
    local ct home dr dst bad=0
    while read -r ct home dr dst _; do
      [[ "$ct" =~ ^# || -z "${ct:-}" ]] && continue
      # Column 2 is an address. The old file had `tier` there, and an old row
      # has four fields too - so it parses as the new shape and means something
      # completely different. Everything a human types here is an IP.
      if [[ ! "$home" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        say "  CT $ct: column 2 is '$home', not an address - this is the OLD five-column file"
        say "  CT $ct:   the tier column is gone:  ct<TAB>home<TAB>dr<TAB>dst"
        bad=1; continue
      fi
      for ip in "$home" "$dr"; do
        [[ -n "$ip" ]] || continue
        [[ -n "$(node_role "$ip")" ]] || { say "  CT $ct: $ip has no row in nodes.tsv"; bad=1; }
      done
      # No default behind this one, on purpose: one node's local storage is
      # local-lvm and another's is local-zfs, so a fallback would place a
      # customer's rootfs on a storage nobody chose. distribute refuses at the
      # time; this says so on an ordinary Tuesday instead.
      [[ -n "$dst" ]] || { say "  CT $ct: no dst - distribute will refuse it, there is no default"; bad=1; }
    done < "$KS_INV"
    (( bad )) && rc=1 || say "  every row has an address, a dr node and a storage"
  fi

  # The question nobody thinks to ask, and the one the backup node dying makes
  # urgent. `replica` refuses cleanly while the backup node is unreachable and
  # says so once a night in a log nobody reads; doctor says the node is down.
  # Neither of them joins "unreachable for three days" to "three days with no
  # fresh copy", which is the sentence that matters. The epoch is already in
  # every state file - nobody was asking for it.
  say "== how old the newest copy of each container is"
  local sdir="$KS_BASE/engines/state" sf id ep age oldest=0 seen=0
  if [[ -d "$sdir" ]]; then
    for sf in "$sdir"/replica-*.json; do
      [[ -e "$sf" ]] || continue
      seen=1
      id="$(basename "$sf" .json)"; id="${id#replica-}"
      ep="$(sed -n 's/.*"epoch":[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$sf" | head -1)"
      if [[ -z "$ep" ]]; then
        say "  CT $id: state file has no epoch - cannot tell how old the copy is"; rc=1; continue
      fi
      age=$(( ( $(date +%s) - ep ) / 86400 ))
      (( age > oldest )) && oldest=$age
      if (( age >= KS_COPY_STALE_DAYS )); then
        say "  CT $id: last successful copy was $age day(s) ago"
        rc=1
      fi
    done
    if (( ! seen )); then
      say "  no replica state files yet - nothing has been copied from this machine"
    elif (( oldest < KS_COPY_STALE_DAYS )); then
      say "  every container was copied within the last $KS_COPY_STALE_DAYS day(s)"
    else
      say "  a copy older than $KS_COPY_STALE_DAYS day(s) is not a backup, it is a memory."
      say "  check the backup node and the replica cron before anything else."
    fi
  fi

  # There is no mirror any more, and a leftover one is worth naming: it is not
  # read, but somebody will find it during an incident and believe it.
  for f in fleet.tsv nodes.map; do
    [[ -e "$KS_BASE/engines/$f" ]] \
      && say "  engines/$f is a LEFTOVER from the old mirror - nothing reads it, delete it"
  done

  say "== the engines"
  if [[ ! -f "$KS_BASE/engines/tp" ]]; then
    say "  engines/ is missing its dispatcher - ketsync decides, tp does. Nothing can run."; rc=1
  else
    # Not "does the file exist" but "can cron actually run it". A checkout that
    # crossed a filesystem which drops the mode bit - a network share, a FUSE
    # mount, an unzip on Windows - leaves every one of these readable and not
    # executable, and the first anybody hears of it is exit 126 at 02:00.
    # ct-distribute.sh was missing from this list, which meant the one engine
    # you reach for while the storage node is dead was the one nobody checked
    # was runnable.
    for f in tp ct-migrate.sh ct-replica.sh ct-failback.sh ct-distribute.sh ct-recall.sh ct-prepare.sh; do
      if [[ -x "$KS_BASE/engines/$f" ]]; then say "  $f ok"
      else say "  $f is NOT EXECUTABLE - cron would exit 126. chmod +x engines/$f"; rc=1; fi
    done

    echo
    "$KS_BASE/engines/tp" doctor || rc=1
  fi

  # ---- what a half-finished DR left behind -------------------------------
  # Every one of these clears itself when the last step of the runbook is
  # actually done, and every one of them is invisible until the NEXT disaster
  # if it is not. A container still on the isolated bridge is a customer who
  # cannot be reached; a storage still disabled is a fleet running on a
  # storage nobody can see; a 9<id> still in pmxcfs is D3 refusing the next
  # placement of that container. None of them produce an error today.
  #
  # Read-only, and asked of the backup node because it is a cluster member and
  # this may be running from the storage node, which is deliberately not one.
  say "== what a disaster left behind"
  local bkp left=0 f
  bkp="$(awk '$1!~/^#/ && $2=="backup"{print $1; exit}' "$KS_NODES" 2>/dev/null)"
  if [[ -z "$bkp" ]]; then
    say "  no backup node in $(basename "$KS_NODES") - cannot ask the cluster"; rc=1
  elif ! ks_ssh "$bkp" true 2>/dev/null; then
    say "  cannot reach the backup node ($bkp) - this is the one check that"
    say "  needs a cluster member, and unanswered is not the same as clean"; rc=1
  else
    # Every guest the cluster holds, asked ONCE and used by both checks below.
    # A record naming a container that no longer exists is not something to
    # restore, and this section used to send somebody to a command that then
    # refuses - which it would do again tomorrow, and the day after, until the
    # one section worth reading after a disaster is the one nobody reads.
    local guests placed
    guests="$(ks_ssh "$bkp" "ls /etc/pve/nodes/*/lxc/*.conf 2>/dev/null" \
              | sed 's|.*/||; s|\.conf$||')"
    for f in $(ks_ssh "$bkp" "ls /etc/pve/ketsync/isolate/ 2>/dev/null" | sed 's/\.tsv$//'); do
      if printf '%s\n' "$guests" | grep -qxF "$f"; then
        say "  CT $f is still ISOLATED - it is on the isolation bridge and cannot answer"
        say "    put it back with:  ./ketsync restore --ctid $f"
      else
        say "  CT $f has an ISOLATE record and no config anywhere in the cluster"
        say "    the container that record describes is gone, so there is nothing to put"
        say "    back and restore refuses it. The record is what is left."
        say "    if CT $f really is gone, remove it - nothing here does that for you:"
        say "      ssh root@$bkp 'rm /etc/pve/ketsync/isolate/$f.tsv'"
        say "    if it is NOT gone, a node is out of the cluster and its guests cannot be"
        say "    seen from here; that record is the only memory of which bridge CT $f"
        say "    belonged on, so fix the cluster first and ask again."
      fi
      left=1; rc=1
    done
    for f in $(ks_ssh "$bkp" "ls /etc/pve/ketsync/evacuate/ 2>/dev/null" | sed 's/\.tsv$//'); do
      say "  node $f still has storages DISABLED by an evacuate"
      say "    switch them back on with:  ./ketsync restore --node <that node's ip>"
      left=1; rc=1
    done
    # A 9<id> that outlived its DR is the one that refuses the next one. It
    # comes out of pmxcfs and out of no state file, for the same reason R13
    # does: it is a fact PVE is holding, not a note somebody left. But a
    # leading 9 is not that fact - customers get to number a container 900,
    # and the day one did, this section condemned it as a leftover and told
    # the operator to run cleanup against a guest that was never ketsync's.
    # What makes a 9<id> OURS is the marker ct-distribute writes into its
    # description - the same provenance C3 demands before recall will move a
    # byte. PVE re-encodes the description on every rewrite (the colon
    # becomes %3A), so the match is the bare word, which both shapes contain.
    placed="$(ks_ssh "$bkp" "grep -l ct-distribute /etc/pve/nodes/*/lxc/*.conf 2>/dev/null" \
              | sed 's|.*/||; s|\.conf$||')"
    for f in $placed; do
      say "  CT $f is still placed - a DR container that outlived its disaster"
      say "    it also holds R13, so CT ${f#9} is not being replicated, and makes D3"
      say "    refuse the next placement of it."
      say "    when the failback is done:  ./ketsync cleanup --ctid ${f#9}"
      say "    that stops it and takes it off the wire; add --destroy to release R13."
      left=1; rc=1
    done
    (( left )) || say "  nothing left over"
  fi

  # ---- images whose filesystem has already recorded an error --------------
  # A container on a storage that died is not shut down, it is stopped by its
  # own writes failing - that is what forcing a dead mount to fail does, and it
  # is the only thing that gets a container down at all while its rootfs is
  # gone. ext4 aborts the journal, remounts read-only, and writes the error
  # into the image's superblock. The NEXT mount says so once, in dmesg, and
  # then mounts it anyway:
  #
  #   EXT4-fs warning: Filesystem error recorded from previous mount: IO failure
  #   EXT4-fs warning: Marked fs in need of filesystem check.
  #   EXT4-fs (loop0): warning: mounting fs with errors, running e2fsck is recommended
  #
  # Nobody reads dmesg on a Tuesday, and a failback writes INTO that image. So
  # it is asked here instead, of the node the container lives on, and it is
  # read-only: dumpe2fs touches the superblock and nothing else.
  #
  # The word to look for is "with errors", NOT "not clean". A mounted
  # filesystem always reports not clean - that is what mounted MEANS - and a
  # check that reported every running container would be a check nobody reads.
  # The error bit is independent of the mount state, which is exactly why it is
  # the one worth asking about.
  say "== images whose filesystem recorded an error"
  local imgs=0 img_bad=0 state
  # A dead storage node leaves the image path on a mount that BLOCKS: the
  # stat never returns and neither would this check - minutes per row, on the
  # fleet where it runs against every container, during exactly the outage a
  # doctor is run in. So the stat gets the engines' STAT_TIMEOUT treatment (a
  # live mount answers in microseconds; five seconds is not a tuning knob, it
  # is the difference between answered and blocked forever), and a node whose
  # storage blocked once is not asked about its remaining rows - the answer
  # would be the same block, one timeout at a time. Every skipped row is SAID:
  # a silent skip reads as clean, which is the lie this section exists to
  # never tell.
  local -A KS_IMG_BLOCKED=()
  if [[ -f "$KS_INV" ]]; then
    while read -r ct home _ _ _; do
      [[ "$ct" =~ ^# || -z "${ct:-}" ]] && continue
      [[ "$home" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
      imgs=1
      if [[ -n "${KS_IMG_BLOCKED[$home]:-}" ]]; then
        say "  CT $ct: skipped - $home's storage is already known to block"
        continue
      fi
      # One round trip: the rootfs volume out of the config, the path out of
      # the storage layer, the state out of the superblock. Asking in three
      # calls would be three times the round trips on a fleet where this runs
      # against every container.
      state="$(ks_ssh "$home" "
        v=\$(pct config $ct 2>/dev/null | sed -n 's/^rootfs: \([^,]*\).*/\1/p')
        [ -n \"\$v\" ] || { echo NOCONFIG; exit 0; }
        p=\$(pvesm path \"\$v\" 2>/dev/null)
        [ -n \"\$p\" ] || { echo NOIMAGE; exit 0; }
        timeout 5 test -f \"\$p\"; trc=\$?
        [ \"\$trc\" = 124 ] && { echo \"BLOCKED \$p\"; exit 0; }
        [ \"\$trc\" = 0 ] || { echo NOIMAGE; exit 0; }
        echo \"PATH \$p\"
        timeout 15 dumpe2fs -h \"\$p\" 2>/dev/null | sed -n 's/^Filesystem state: *//p'
      " 2>/dev/null)"
      if [[ -z "$state" ]]; then
        say "  CT $ct: could not ask $home - unanswered is not the same as clean"; rc=1; img_bad=1
      elif [[ "$state" == BLOCKED* ]]; then
        say "  CT $ct: its storage did not answer within 5s - the mount is BLOCKED, not clean"
        say "    ${state#BLOCKED }"
        say "    this is what a dead storage node looks like from $home. The rest of"
        say "    $home's rows are skipped rather than waited on, one timeout at a time."
        KS_IMG_BLOCKED[$home]=1
        rc=1; img_bad=1
      elif [[ "$state" == *"with errors"* ]]; then
        say "  CT $ct: its image says \"$(sed -n 's/^Filesystem state: *//p;$p' <<<"$state" | tail -1)\""
        say "    $(sed -n 's/^PATH //p' <<<"$state")"
        say "    it mounts anyway and says so only in dmesg. Check it while the container"
        say "    is STOPPED, before anything writes into it again:"
        say "      e2fsck -fy $(sed -n 's/^PATH //p' <<<"$state")"
        rc=1; img_bad=1
      fi
    done < "$KS_INV"
  fi
  (( imgs )) || say "  no rows in $(basename "$KS_INV") to ask about"
  (( imgs && ! img_bad )) && say "  none - no image reports an error in its superblock"

  # ---- cron lines that would refuse to run --------------------------------
  # A command that writes asks first, and a cron line has nobody to ask, so it
  # refuses with exit 2. That is the correct behaviour and it is also silent
  # until somebody reads the mail nobody has set up yet. So it is checked here,
  # on a Tuesday, rather than found at 02:00 on the night it mattered.
  # Where cron keeps its files. Overridable so the simulator can hand this a
  # sandbox: reading the real /etc/cron.d made these checks depend on whatever
  # the machine running the suite happens to schedule, which is a test that
  # passes on one laptop and fails on another.
  local CRON_D="${KS_CRON_D:-/etc/cron.d}" CRON_F="${KS_CRONTAB:-/etc/crontab}"

  # ---- a file cron throws away entirely -------------------------------------
  # A file in /etc/cron.d is a SYSTEM crontab and its sixth field is the USER.
  # A line written like a user crontab - five time fields and then the command -
  # makes cron reject THE WHOLE FILE at reload: nothing in it runs, nothing
  # mails, and the only evidence is one line in the cron daemon's journal that
  # nobody reads on a Tuesday. A watcher installed that way is a watcher that
  # was never watching. Found on the backup node the day the slave watch went
  # in, straight off this repo's own docs, which showed the five-field form.
  say "== cron.d lines cron itself will not run"
  local cd_bad=0 cf cl u f1 f2 f6
  for cf in "$CRON_D"/* "$CRON_F"; do
    [[ -f "$cf" ]] || continue
    while IFS= read -r cl || [[ -n "$cl" ]]; do
      case "$cl" in ''|'#'*) continue;; esac
      # PATH=, MAILTO= and friends are settings, not schedules
      [[ "$cl" =~ ^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*= ]] && continue
      # the three middle time fields are read into one throwaway on purpose:
      # naming them would be three variables nothing ever looks at
      read -r f1 f2 _ _ _ f6 _ <<< "$cl"
      # @daily and friends carry ONE time field, so the user moves up to second
      if [[ "$f1" == @* ]]; then u="$f2"; else u="$f6"; fi
      [[ -n "$u" && "$u" != /* ]] && continue
      say "  $cf: $cl"
      cd_bad=1
    done < "$cf"
  done
  if (( cd_bad )); then
    say "  the sixth field there is the USER, not the command. cron refuses the"
    say "  whole file over one line like this, so every job in it - a ketsync"
    say "  watch included - silently never runs:"
    say "    */10 * * * * root /root/ketsync/ketsync watch"
    say "  or put the five-field form in root's own crontab instead:  crontab -e"
    rc=1
  else
    say "  none"
  fi

  # ---- the opposite mistake, and it is worse ---------------------------------
  # -y belongs to the dispatcher, which is where the question lives. No engine
  # has ever heard of it, and an engine that meets it says "unknown argument"
  # and exits 2 - so a cron line written this way has never run once. With the
  # usual >/dev/null on the end there is nothing at all to notice: the fleet
  # simply stops replicating, quietly, from the minute the line was installed.
  say "== cron lines that hand -y to an engine, which has never heard of it"
  local enghits
  enghits="$( { crontab -l 2>/dev/null; cat "$CRON_D"/* "$CRON_F" 2>/dev/null; } \
              | grep -v '^[[:space:]]*#' | grep -E 'engines/(ct-[a-z]+\.sh|tp)' \
              | grep -E '(^|[[:space:]])-y([[:space:]]|$)' || true )"
  if [[ -n "$enghits" ]]; then
    say "  these exit 2 every time cron runs them, and have never done any work:"
    while IFS= read -r f; do [[ -n "$f" ]] && say "    $f"; done <<< "$enghits"
    say "  drop the -y. cron calls the engines directly and is never asked"
    say "  anything; -y is only for a verb that goes through ./ketsync."
    rc=1
  else
    say "  none"
  fi

  say "== cron lines that call ketsync without -y"
  local cronhits
  # Read-only verbs never ask, so cron lines for them need no -y: watch is
  # DESIGNED to run from cron bare, and nagging about it would train people
  # to sprinkle -y on verbs where it means nothing.
  # The match is the DISPATCHER being invoked - `ketsync <verb>` - not the
  # string "ketsync" anywhere in the line. Every engine on this fleet lives
  # under /root/ketsync/engines/, so the loose version nagged about lines that
  # are correct precisely BECAUSE they carry no -y, and the check above says
  # so in the opposite direction. Two checks disagreeing about one line is how
  # both stop being read.
  cronhits="$( { crontab -l 2>/dev/null; cat "$CRON_D"/* "$CRON_F" 2>/dev/null; } \
               | grep -v '^[[:space:]]*#' | grep -E '(^|[/[:space:]])ketsync[[:space:]]+[a-z]' \
               | grep -vE 'ketsync[[:space:]]+(watch|doctor|status|role)([[:space:]]|$)' \
               | grep -v -- '-y' || true )"
  if [[ -n "$cronhits" ]]; then
    say "  these would REFUSE, because there is nobody there to answer:"
    while IFS= read -r f; do [[ -n "$f" ]] && say "    $f"; done <<< "$cronhits"
    say "  add -y to each. It means the decision was already made, and it"
    say "  skips the question and nothing else."
    rc=1
  else
    say "  none"
  fi

  return $rc
}
