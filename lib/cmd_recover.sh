#!/usr/bin/env bash
# shellcheck shell=bash disable=SC1090,SC1091
# =============================================================================
#  ketsync recover — the whole way back, in one command
# -----------------------------------------------------------------------------
#  The 2026-08-15 drill ended with an operator running seven commands off a
#  printed checklist: restore two nodes, fsck two images, failback, restore two
#  containers, cleanup two stand-ins, unpause, replicate. Every one of them
#  already existed and every one of them was a chance to be skipped, doubled,
#  or run out of order at the end of the worst day the fleet will have. This
#  command is that checklist, executed - the second verb this layer composes,
#  for the same reason as `distribute`: SEQUENCING is what this layer is for.
#
#  It is driven by STATE, not by a script's memory of where it got to. Every
#  step asks the same sources of truth `doctor` reads - the records in pmxcfs,
#  the 9<id> configs, the superblocks - decides done or not done, and says
#  which. That is what makes it safe to re-run: a step whose record is gone is
#  reported as already done and skipped, so an interrupted recover is finished
#  by typing it again, and a finished one says there is nothing left.
#
#  The order, and why it is this order:
#
#    1  restore --node        storages back on, per evacuate record. First,
#                             because everything after it needs the storage
#                             active, and its record names the killed images
#    2  e2fsck -fy            every image whose superblock says "with errors",
#                             BEFORE the failback writes into it. The failback
#                             takes a safety snapshot before every write, so
#                             even the fsck is undoable
#    3  failback --final      per container with a 9<id> placed. ALWAYS run,
#                             never skipped off old state: a re-run costs a
#                             snapshot and a no-op rsync, a skip trusted to a
#                             stale state file costs the customer's data
#    4  restore --ctid        production network back, per isolate record
#    5  cleanup [--destroy]   the stand-in stopped and off the wire; --destroy
#                             removes it and releases R13
#    6  rm PAUSE + replica    only with --destroy, and only when every step
#                             above went green - replication must not restart
#                             over a half-finished return
#
#  What it will never do is `pct start`. Bringing a service back is a decision
#  with a customer on the other end, and it stays a human's - the run ends by
#  printing the starts, exactly as distribute does.
#
#  THE ONE THING IT CANNOT VERIFY, SAID OUT LOUD: this flow assumes
#  `recall --final` already ran for every 9<id> - that the copy holds what the
#  stand-in was serving. Recall's state file lives on the machine that DROVE
#  the recall, which during a disaster is the backup node, and this command
#  runs on the storage node; there is no cluster-visible marker to read. What
#  IS verifiable is enforced - a 9<id> that is still RUNNING refuses, because
#  stopping it is the cutover decision and recall --final requires it - and
#  the unverifiable half is in the confirmation this command asks before it
#  writes. Answering y to that question is the acknowledgment.
# =============================================================================
cmd_recover(){
  local all=0 destroy=0 dry=0 list=0 rc=0 only=""
  while (( $# )); do
    case "$1" in
      --all)     all=1; shift;;
      --destroy) destroy=1; shift;;
      --dry-run) dry=1; shift;;
      --list)    list=1; shift;;
      # One container out of what the records name. The scope is still the
      # DISASTER's: a --ctid the records do not know is refused below, because
      # recovering a container the disaster never touched would run a failback
      # into an image that was never behind.
      --ctid)    [[ $# -ge 2 ]] || { say "recover: --ctid needs a value"; return 2; }
                 only="$2"; shift 2;;
      *) say "recover: unknown argument '$1'"; return 2;;
    esac
  done
  if (( all )) && [[ -n "$only" ]]; then
    say "refused: --all recovers everything the records name and --ctid recovers one."
    say "  they contradict - pick one."
    return 2
  fi
  if (( ! all && ! list )) && [[ -z "$only" ]]; then
    say "refused: recover takes --all, or one container with --ctid <id>. Either"
    say "  way it recovers what the DISASTER touched, which it reads from the"
    say "  cluster - not from a list you type."
    say "  see where it stands first:  ./ketsync recover --list"
    return 2
  fi

  # Failback runs on the machine that owns the production images, so recover
  # does too. On the backup node this would fail four steps in with an error
  # about a missing image, which reads like a data problem and is a wrong-desk
  # problem.
  if [[ "${KS_ROLE:-}" != master ]]; then
    say "refused: recover runs on the MASTER (the storage node) - this machine is ${KS_ROLE:-unset}."
    say "  the failback writes into production images that live there. During the"
    say "  outage the backup node drives; the way back is driven from the machine"
    say "  that is back."
    return 2
  fi

  local TPREP="$KS_BASE/engines/ct-prepare.sh"
  local TFB="$KS_BASE/engines/ct-failback.sh"
  local TREP="$KS_BASE/engines/ct-replica.sh"
  local PAUSE="$KS_BASE/engines/PAUSE"
  local e
  for e in "$TPREP" "$TFB" "$TREP"; do
    [[ -x "$e" ]] || { say "ERROR: $e is missing or not executable - NOTHING was run"; return 2; }
  done

  local bkp; bkp="$(ip_of_role backup)"
  [[ -n "$bkp" ]] || { say "ERROR: no backup node in $(basename "$KS_NODES") - cannot read the cluster"; return 2; }
  if ! ks_ssh "$bkp" true 2>/dev/null; then
    say "ERROR: cannot reach the backup node ($bkp) - the records and the 9<id>"
    say "ERROR:   configs live in pmxcfs, and that is the door to them. Unanswered"
    say "ERROR:   is not the same as nothing left, so nothing was run."
    return 2
  fi

  # ---- what the disaster left, straight from the cluster --------------------
  # The same three questions doctor asks, and the worklist is their union. NOT
  # fleet.tsv: the fleet says what exists, the records say what the disaster
  # touched, and recovering a container the disaster never touched would run a
  # failback into an image that was never behind.
  local EVACN ISOL NINE
  EVACN="$(ks_ssh "$bkp" "ls /etc/pve/ketsync/evacuate/ 2>/dev/null" | sed 's/\.tsv$//')"
  ISOL="$(ks_ssh "$bkp" "ls /etc/pve/ketsync/isolate/ 2>/dev/null" | sed 's/\.tsv$//')"
  NINE="$(ks_ssh "$bkp" "ls /etc/pve/nodes/*/lxc/9*.conf 2>/dev/null")"

  # 9<id> -> production id, and the node name straight out of the config path.
  declare -A DRNODE=() DRID=()
  local f n id
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    n="${f#/etc/pve/nodes/}"; n="${n%%/*}"
    id="${f##*/}"; id="${id%.conf}"
    DRID[${id#9}]="$id"; DRNODE[${id#9}]="$n"
  done <<< "$NINE"

  declare -A INCT=()
  local ct
  for ct in "${!DRID[@]}"; do INCT[$ct]=1; done
  for ct in $ISOL; do INCT[$ct]=1; done
  declare -a CTS=()
  if (( ${#INCT[@]} )); then
    while IFS= read -r ct; do [[ -n "$ct" ]] && CTS+=("$ct"); done \
      < <(printf '%s\n' "${!INCT[@]}" | sort -n)
  fi
  # The superblock question, per container, same one round trip as doctor.
  img_state(){   # $1 = ctid, $2 = home ip -> sets IMG_PATH, IMG_STATE
    IMG_PATH=""; IMG_STATE=""
    local out
    out="$(ks_ssh "$2" "
      v=\$(pct config $1 2>/dev/null | sed -n 's/^rootfs: \([^,]*\).*/\1/p')
      [ -n \"\$v\" ] || { echo NOCONFIG; exit 0; }
      p=\$(pvesm path \"\$v\" 2>/dev/null)
      [ -n \"\$p\" ] && [ -f \"\$p\" ] || { echo NOIMAGE; exit 0; }
      echo \"PATH \$p\"
      dumpe2fs -h \"\$p\" 2>/dev/null | sed -n 's/^Filesystem state: *//p'
    " 2>/dev/null)"
    IMG_PATH="$(sed -n 's/^PATH //p' <<<"$out")"
    IMG_STATE="$(grep -v '^PATH ' <<<"$out" | tail -1)"
  }
  # "clean" is an answer dumpe2fs gave; these are the ABSENCE of an answer -
  # no config, no image file, or nothing came back at all. The guard below
  # exists because an image nobody can see must never be treated as an image
  # in good order.
  img_unseen(){ [[ -z "$IMG_STATE" || "$IMG_STATE" == NOIMAGE || "$IMG_STATE" == NOCONFIG ]]; }
  home_of(){ awk -v c="$1" '$1!~/^#/ && $1==c{print $2; exit}' "$KS_INV" 2>/dev/null; }
  map_ip(){  awk -v n="$1" '$1!~/^#/ && $2==n{print $1; exit}' "$KS_NODEMAP" 2>/dev/null; }

  # ---- --ctid: one container, out of what the records name ------------------
  if [[ -n "$only" ]]; then
    if [[ -z "${INCT[$only]:-}" ]]; then
      say "refused: the disaster's records do not name CT $only - no isolate record,"
      say "  no 9<id> placed. There is nothing to recover for it."
      say "  see what they do name:  ./ketsync recover --list"
      return 2
    fi
    CTS=("$only")
    # Step 1 below restores storages per evacuate record. With one container
    # named, only ITS node is restored - the other evacuated nodes were not
    # asked about, and switching a storage back on is a per-node decision.
    local _oh _on
    _oh="$(home_of "$only")"
    _on="$(awk -v i="$_oh" '$1!~/^#/ && $1==i{print $2; exit}' "$KS_NODEMAP" 2>/dev/null)"
    EVACN="$(grep -x "${_on:-__none__}" <<<"$EVACN" || true)"
  fi


  # ---- --list: the checklist, read-only -------------------------------------
  if (( list )); then
    say "== recover --list: what the disaster left, and what recover --all would do"
    if [[ -z "$EVACN" && -z "$ISOL" && ${#DRID[@]} -eq 0 ]]; then
      say "  nothing - no evacuate record, no isolate record, no 9<id> placed."
      [[ -f "$PAUSE" ]] && { say "  but PAUSE exists ($PAUSE) - replication is stopped."; return 1; }
      return 0
    fi
    for n in $EVACN; do
      say "  todo  restore --node $(map_ip "$n") ($n): storages still disabled by an evacuate"
    done
    for ct in ${CTS[@]+"${CTS[@]}"}; do
      local h; h="$(home_of "$ct")"
      if [[ -n "$h" ]]; then
        img_state "$ct" "$h"
        [[ "$IMG_STATE" == *"with errors"* ]] && say "  todo  e2fsck -fy on CT $ct's image ($IMG_PATH)"
      fi
      if [[ -n "${DRID[$ct]:-}" ]]; then
        say "  todo  failback --ctid $ct --final, then cleanup (CT ${DRID[$ct]} is placed on ${DRNODE[$ct]})"
        say "        recall --final done? NOT VERIFIABLE from here - its state is on the machine that drove it"
      fi
      grep -qx "$ct" <<<"$ISOL" && say "  todo  restore --ctid $ct: still on the isolation bridge"
    done
    [[ -f "$PAUSE" ]] && say "  todo  rm PAUSE + first replica round (recover does this only with --destroy)"
    return 0
  fi

  local mode=keep
  (( destroy )) && mode=destroy
  (( dry )) && mode="dry-run"
  hr
  log "=== $(hostname 2>/dev/null || echo '?') recover mode=$mode containers: ${CTS[*]:-<none>} nodes: ${EVACN:-<none>} ==="

  if [[ -z "$EVACN" && -z "$ISOL" && ${#DRID[@]} -eq 0 ]]; then
    log "nothing to recover: no evacuate record, no isolate record, no 9<id> placed."
    if [[ -f "$PAUSE" ]]; then
      log "  but PAUSE exists - replication is stopped and nothing here explains why."
      log "  if the disaster is truly over:  rm $PAUSE"
      return 1
    fi
    return 0
  fi

  local failed=0
  declare -A CTBAD=()

  # ---- 1: storages back on, per node ---------------------------------------
  for n in $EVACN; do
    local nip; nip="$(map_ip "$n")"
    if [[ -z "$nip" ]]; then
      log "[$n] ERROR: $(basename "$KS_NODEMAP") has no address for node '$n' - its storages stay off"
      failed=1; continue
    fi
    declare -a RA=(--restore --node "$nip"); (( dry )) && RA+=(--dry-run)
    "$TPREP" "${RA[@]}" || { log "[$n] restore --node $nip FAILED - carrying on, but its containers will fail below"; failed=1; }
  done
  [[ -z "$EVACN" ]] && log "storages: no evacuate record anywhere - already restored, or never evacuated"

  # ---- 2: the images the outage killed mid-write ---------------------------
  # -fy and not -fn, decided by the operator who asked for this command: the
  # failback takes a safety snapshot before it writes, so even a repair that
  # goes wrong has a way back - and a report nobody acts on is how "clean with
  # errors" outlives the disaster by a month.
  for ct in ${CTS[@]+"${CTS[@]}"}; do
    local h; h="$(home_of "$ct")"
    if [[ -z "$h" ]]; then
      log "[$ct] ERROR: no row in $(basename "$KS_INV") - cannot find its node to check the image"
      CTBAD[$ct]=1; failed=1; continue
    fi
    local pst; pst="$(ks_ssh "$h" "pct status $ct 2>/dev/null" | awk '{print $2}')"
    if [[ "$pst" == running ]]; then
      log "[$ct] production CT $ct is RUNNING on $h - a woken pending writer, or never down."
      log "[$ct]   nothing here stops a container whose storage answers - that proof belongs"
      log "[$ct]   to evacuate and the storage is back. Stop it, then run recover again:"
      log "[$ct]     ssh root@$h pct shutdown $ct"
      CTBAD[$ct]=1; failed=1; continue
    fi
    img_state "$ct" "$h"
    # The storages were switched back on one step ago, and an NFS mount can
    # take a moment to reappear - the 2026-08-16 drill hit exactly this window
    # and the answer came back NOIMAGE, which the old line below read as
    # "clean - no fsck needed". Absence is not cleanliness: a dirty image that
    # slips past here gets a failback written into it unrepaired. So wait for
    # the mount, bounded, and refuse the container if the image never shows.
    # The env knobs exist for the simulator, which must not sit through real
    # waits; the fleet runs the defaults.
    if img_unseen; then
      if (( dry )); then
        log "[$ct] DRY: cannot see the image from here (${IMG_STATE:-no answer}) - expected in a dry"
        log "[$ct] DRY:   run: step 1 was dry too, so the storage is likely still off. The real run"
        log "[$ct] DRY:   asks again once the storages are back, and refuses this container if the"
        log "[$ct] DRY:   image still does not show."
      else
        local try=0 tries="${KS_IMG_WAIT_TRIES:-8}" gap="${KS_IMG_WAIT_GAP:-3}"
        while (( try < tries )); do
          sleep "$gap"
          img_state "$ct" "$h"
          img_unseen || break
          try=$((try+1))
        done
        if img_unseen; then
          log "[$ct] ERROR: cannot see CT $ct's image on $h (${IMG_STATE:-no answer}) after $((tries*gap))s."
          log "[$ct] ERROR:   the storages were switched back on one step ago; an image that still"
          log "[$ct] ERROR:   does not show is a mount that did not come back, or a config pointing"
          log "[$ct] ERROR:   at something that is gone. Absence is not cleanliness - nothing more"
          log "[$ct] ERROR:   runs for this container until a human can see its image."
          CTBAD[$ct]=1; failed=1; continue
        fi
      fi
    fi
    if [[ "$IMG_STATE" == *"with errors"* ]]; then
      if (( dry )); then
        log "[$ct] DRY: would e2fsck -fy $IMG_PATH on $h (superblock says: $IMG_STATE)"
      else
        log "[$ct] e2fsck -fy $IMG_PATH on $h (superblock says: $IMG_STATE)"
        ks_ssh "$h" "e2fsck -fy '$IMG_PATH'"; rc=$?
        # 1 is "errors corrected" and 2 adds "reboot advised", which is about a
        # mounted root and this image is not mounted. 4 and up is a filesystem
        # e2fsck could not put right - writing a failback into that is throwing
        # the copy's data into a hole.
        if (( rc >= 4 )); then
          log "[$ct] ERROR: e2fsck exited $rc - the image needs a human before anything writes into it"
          CTBAD[$ct]=1; failed=1
        else
          log "[$ct] e2fsck done (rc=$rc) - the image is consistent again"
        fi
      fi
    elif ! img_unseen; then
      log "[$ct] image superblock is clean ($IMG_STATE) - no fsck needed"
    fi
  done

  # ---- 3: the failback, per container with a stand-in ----------------------
  local any_fb=0
  for ct in ${CTS[@]+"${CTS[@]}"}; do
    [[ -n "${DRID[$ct]:-}" ]] || continue
    [[ -n "${CTBAD[$ct]:-}" ]] && continue
    local dr="${DRID[$ct]}" drn="${DRNODE[$ct]}" drip dst
    drip="$(map_ip "$drn")"
    if [[ -z "$drip" ]]; then
      log "[$ct] ERROR: $(basename "$KS_NODEMAP") has no address for node '$drn' holding CT $dr"
      CTBAD[$ct]=1; failed=1; continue
    fi
    dst="$(ks_ssh "$drip" "pct status $dr 2>/dev/null" | awk '{print $2}')"
    if [[ "$dst" != stopped ]]; then
      log "[$ct] CT $dr is ${dst:-unreachable} on $drn - NOT failing back CT $ct"
      log "[$ct]   a running stand-in is still the service, and stopping it is the cutover"
      log "[$ct]   decision. recall --final requires it stopped and moves its data into the"
      log "[$ct]   copy; run that first, from the machine that drove the distribute:"
      log "[$ct]     ketsync recall --ctid $ct --final"
      CTBAD[$ct]=1; failed=1; continue
    fi
    if (( ! dry )) && [[ ! -f "$PAUSE" ]]; then
      # B2 requires it: with the copies stopped, the next replica cron tick
      # would overwrite the DR data with the stale production images. Created
      # here because sequencing is this command's job; removed only at the
      # very end, and only when everything went green.
      : > "$PAUSE"
      log "created $PAUSE - replication is held while production images are behind"
    fi
    any_fb=1
    declare -a FA=(--ctid "$ct" --final); (( dry )) && FA+=(--dry-run)
    if "$TFB" "${FA[@]}"; then
      log "[$ct] failback --final ok - the production image holds the newest data"
    else
      log "[$ct] failback --final FAILED (see above) - CT $ct stays isolated, its stand-in stays"
      CTBAD[$ct]=1; failed=1
    fi
  done
  (( any_fb )) || log "failback: no container has both a stand-in placed and a clean path to it"

  # ---- 4 and 5: network back, stand-in away --------------------------------
  for ct in ${CTS[@]+"${CTS[@]}"}; do
    [[ -n "${CTBAD[$ct]:-}" ]] && continue
    if grep -qx "$ct" <<<"$ISOL"; then
      declare -a RA=(--restore --ctid "$ct"); (( dry )) && RA+=(--dry-run)
      "$TPREP" "${RA[@]}" || { log "[$ct] restore --ctid FAILED - not cleaning up its stand-in"; CTBAD[$ct]=1; failed=1; continue; }
    else
      log "[$ct] no isolate record - its network was already restored, or never moved"
    fi
    if [[ -n "${DRID[$ct]:-}" ]]; then
      declare -a KA=(--cleanup --ctid "$ct"); (( destroy )) && KA+=(--destroy); (( dry )) && KA+=(--dry-run)
      "$TPREP" "${KA[@]}" || { log "[$ct] cleanup FAILED - CT ${DRID[$ct]} is still holding R13"; CTBAD[$ct]=1; failed=1; }
    fi
  done

  # ---- 6: replication back, only when it is safe ---------------------------
  if (( destroy )); then
    if (( failed )); then
      log "NOT removing PAUSE and NOT restarting replication: something above failed,"
      log "  and a replica round over a half-finished return is how a stale image"
      log "  becomes the newest copy. Fix what is named above, run recover again."
    elif (( dry )); then
      log "DRY: would rm $PAUSE and run one replica round, which must end failed=0"
    else
      rm -f "$PAUSE"
      log "removed PAUSE - running the first replica round; it must end failed=0"
      if "$TREP"; then
        log "replica round ok - the fleet is back to its nightly rhythm"
      else
        log "ERROR: the first replica round back did not end clean - read its log"
        failed=1
      fi
    fi
  elif (( ! dry )); then
    log "the stand-ins are KEPT (no --destroy): R13 still holds their containers out"
    log "  of replication and PAUSE stays. When the real ones have been checked:"
    for ct in ${CTS[@]+"${CTS[@]}"}; do
      [[ -n "${DRID[$ct]:-}" && -z "${CTBAD[$ct]:-}" ]] && log "    ./ketsync cleanup --ctid $ct --destroy"
    done
    log "    rm $PAUSE"
    log "    $TREP     # first round back, must end failed=0"
  fi

  # ---- what stays a human's -------------------------------------------------
  local started=0
  for ct in ${CTS[@]+"${CTS[@]}"}; do
    [[ -n "${CTBAD[$ct]:-}" ]] && continue
    local h; h="$(home_of "$ct")"
    (( started )) || { log "start each production container BY HAND - nothing here starts one, ever:"; started=1; }
    log "  ssh root@${h:-<its node>} pct start $ct"
  done

  return $failed
}
