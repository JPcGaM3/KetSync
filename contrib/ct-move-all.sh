#!/usr/bin/env bash
# =============================================================================
#  ct-move-all.sh - run contrib/ct-move.sh over a list, one row at a time.
#
#  A stopgap until ct-migrate can write onto a compute node's own storage
#  (claude/ketsync-migrate-remote-dest-grilling.md). Same list shape as
#  inventory-migrate.tsv, and the same bandwidth rule as ct-migrate: every
#  run gets BW_TOTAL_MB / LANES from conf/ctmig.conf, so two runs at once
#  (two lanes, split with --storage) stay inside the ceiling together.
#
#  Rows whose destination storage is one of this machine's own pools
#  (SRC_STORAGES in conf/ctmig.conf) are NOT moved here: ketsync migrate
#  writes those locally and is faster. They are listed and skipped.
#
#  Nothing here stops or starts a container, and every guard is ct-move.sh's.
# =============================================================================
set -uo pipefail
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

usage(){ cat <<'U'
usage: ct-move-all.sh [--file <list>] [--storage <dst-storage>] [--ctid <id>] [--final] [--dry-run]

  --file      default inventory/inventory-move.tsv. One row per CT:
                old_node  old_ctid  new_ctid  new_node  storage  [zfs=k=v,k=v]  [anything]
              old_node/new_node are IPs, storage is the id ON new_node. "#" starts a
              comment; text after the storage is ignored except a zfs= field, which
              is handed to ct-move.sh --zfs-props (used on a row's first round only).
  --storage   only rows for this destination storage - and the lane name. Two runs
              with different --storage are two lanes (set LANES=2 in ctmig.conf).
  --ctid      only this row (old or new id)
  --final     cutover round for every selected row: each CT must already be STOPPED
              by you; a row whose CT is still running fails, the others go on
  --dry-run   passed to every row
U
}

FILE=""; LANE_STORAGE=""; ONLY=""; PASS=()
while (( $# )); do
  case "$1" in
    --file) FILE="${2:-}"; shift 2;;
    --storage) LANE_STORAGE="${2:-}"; shift 2;;
    --ctid) ONLY="${2:-}"; shift 2;;
    --final|--dry-run) PASS+=("$1"); shift;;
    -h|--help) usage; exit 0;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2;;
  esac
done

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; BASE="$(cd "$HERE/.." && pwd)"
CONF="$BASE/conf/ctmig.conf"; MOVE="$HERE/ct-move.sh"
FILE="${FILE:-$BASE/inventory/inventory-move.tsv}"
[[ -x "$MOVE" ]] || { echo "not found or not executable: $MOVE" >&2; exit 2; }
[[ -r "$FILE" ]] || { echo "list not found: $FILE" >&2; exit 2; }
[[ -r "$CONF" ]] || { echo "conf not found: $CONF" >&2; exit 2; }

cget(){ sed -n "s/^$1=[\"]*\([^\"#]*\).*/\1/p" "$CONF" | tail -1 | sed 's/[[:space:]]*$//'; }
BW_TOTAL=$(cget BW_TOTAL_MB); LANES=$(cget LANES); BW_MIN=$(cget BW_MIN_MB); LOCALPOOLS=$(cget SRC_STORAGES)
for v in BW_TOTAL LANES BW_MIN; do
  [[ "${!v}" =~ ^[0-9]+$ ]] || { echo "$CONF: ${v/_TOTAL/_TOTAL_MB} must be a plain integer, got '${!v}'" >&2; exit 2; }
done
(( LANES > 0 )) || LANES=1
BW=$(( BW_TOTAL / LANES )); (( BW < BW_MIN )) && BW=$BW_MIN

LANE="${LANE_STORAGE:-all}"
mkdir -p "$BASE/state"
exec 8>"$BASE/state/.ct-move-all-$LANE.lock" || exit 2
flock -n 8 || { echo "another ct-move-all lane '$LANE' is running" >&2; exit 1; }

echo "=== ct-move-all lane=$LANE bw=${BW}MB/s (BW_TOTAL_MB=$BW_TOTAL / LANES=$LANES) ${PASS[*]:-presync} list=$FILE ==="
ok=(); failed=(); skipped=(); matched=0; n=0
while read -r onode octid nctid nnode stor rest <&3 || [[ -n "${onode:-}" ]]; do
  n=$(( n + 1 ))
  [[ -z "${onode:-}" || "$onode" == \#* ]] && continue
  if [[ -z "${stor:-}" || ! "$octid" =~ ^[0-9]+$ || ! "$nctid" =~ ^[0-9]+$ ]]; then
    echo "line $n: needs old_node old_ctid new_ctid new_node storage - got: $onode ${octid:-} ${nctid:-} ${nnode:-} ${stor:-}" >&2
    failed+=("line$n"); continue
  fi
  [[ -n "$LANE_STORAGE" && "$stor" != "$LANE_STORAGE" ]] && continue
  [[ -n "$ONLY" && "$ONLY" != "$octid" && "$ONLY" != "$nctid" ]] && continue
  matched=$(( matched + 1 ))
  if [[ " $LOCALPOOLS " == *" $stor "* ]]; then
    echo "--- $octid -> $nctid: '$stor' is this machine's own pool - use ketsync migrate for it (skipped)"
    skipped+=("$nctid"); continue
  fi
  zp=""; for f in ${rest:-}; do [[ "$f" == zfs=* ]] && zp="${f#zfs=}"; done
  echo; echo "--- $octid on $onode -> $nctid on $nnode ($stor) ---"
  args=(--src-ip "$onode" --src-ctid "$octid" --dst-ip "$nnode" --dst-ctid "$nctid" --storage "$stor" --bwlimit "$BW")
  [[ -n "$zp" ]] && args+=(--zfs-props "$zp")
  "$MOVE" "${args[@]}" "${PASS[@]}" </dev/null; rc=$?
  # Ctrl-C reaches ct-move too, which cleans up and exits 130. That is a normal
  # exit as far as this loop can see, so without this check ^C stopped one row
  # and the batch went straight on to the next one.
  if (( rc == 130 )); then failed+=("$nctid"); echo; echo "=== interrupted at $octid -> $nctid - the rest of the list was NOT run ==="; break; fi
  if (( rc == 0 )); then ok+=("$nctid"); else failed+=("$nctid"); fi
done 3< "$FILE"

echo; echo "=== ct-move-all lane=$LANE: ok=${#ok[@]} failed=${#failed[@]} skipped=${#skipped[@]} ==="
(( ${#failed[@]} )) && echo "FAILED: ${failed[*]}   (each one's log: logs/ct-move-<old ctid>-<date>.log)"
(( ${#skipped[@]} )) && echo "SKIPPED (storage-node pool, use ketsync migrate): ${skipped[*]}"
if (( matched == 0 )); then echo "ERROR: no row matched${LANE_STORAGE:+ --storage $LANE_STORAGE}${ONLY:+ --ctid $ONLY}" >&2; exit 1; fi
(( ${#failed[@]} )) && exit 1
exit 0
