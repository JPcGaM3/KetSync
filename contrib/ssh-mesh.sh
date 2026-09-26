#!/usr/bin/env bash
# =============================================================================
#  ssh-mesh.sh - every node in the fleet can ssh every other node as root, by
#  key, with no prompt. Run on the storage node, which already reaches all of
#  them; no password is typed except for a node this machine cannot reach yet.
#
#  Hosts: conf/nodes.tsv + both columns of IPs in the inventories, or the IPs
#  given as arguments. For each ordered pair A -> B it (1) puts A's root public
#  key into B's authorized_keys, (2) records B's host key in A's known_hosts
#  if A has never seen B. A host key that CHANGED is never replaced - that pair
#  is reported FAIL with the command to fix it once you have checked the
#  fingerprint on B's console.
#
#  usage: contrib/ssh-mesh.sh [--check] [ip ...]
#         --check   only test every pair, change nothing
# =============================================================================
set -uo pipefail
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK=0; [[ "${1:-}" == --check ]] && { CHECK=1; shift; }

if (( $# )); then HOSTS=("$@")
else
  mapfile -t HOSTS < <({
    awk '$1!~/^#/ && $1~/^[0-9.]+$/ {print $1}' "$BASE/conf/nodes.tsv" 2>/dev/null
    for f in "$BASE"/inventory/inventory-migrate.tsv "$BASE"/inventory/inventory-move.tsv; do
      awk '$1!~/^#/ && NF>=4 {print $1; print $4}' "$f" 2>/dev/null
    done
  } | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | sort -uV)
fi
ME=$(hostname -I 2>/dev/null)
(( ${#HOSTS[@]} )) || { echo "no hosts found - pass IPs as arguments" >&2; exit 2; }
echo "hosts: ${HOSTS[*]}"

O="-o BatchMode=yes -o ConnectTimeout=8"
self(){ [[ " $ME " == *" $1 "* ]]; }
on(){ local h="$1"; shift; if self "$h"; then bash -c "$*"; else ssh $O -n "root@$h" "$*"; fi; }

# --- 0) this machine must reach every host (the only place a password is typed)
declare -A PUB=()
for h in "${HOSTS[@]}"; do
  self "$h" && continue
  if ! ssh $O -n "root@$h" true 2>/dev/null; then
    if (( CHECK )); then echo "FAIL this -> $h"; continue; fi
    echo ">>> this machine cannot reach $h by key - root password of $h:"
    ssh-copy-id -o StrictHostKeyChecking=accept-new "root@$h" </dev/tty \
      || { echo "FAIL this -> $h (host key changed? verify on its console, then: ssh-keygen -R $h)"; continue; }
  fi
done

if (( ! CHECK )); then
  # --- 1) every host has a root key; collect them
  for h in "${HOSTS[@]}"; do
    PUB[$h]=$(on "$h" '[ -f ~/.ssh/id_ed25519.pub ] || [ -f ~/.ssh/id_rsa.pub ] || ssh-keygen -q -t ed25519 -N "" -f ~/.ssh/id_ed25519; cat ~/.ssh/id_ed25519.pub 2>/dev/null || cat ~/.ssh/id_rsa.pub' 2>/dev/null)
    [[ -n "${PUB[$h]}" ]] || echo "WARN cannot read a root key on $h"
  done
  # --- 2) every key into every other host's authorized_keys, once
  for b in "${HOSTS[@]}"; do
    for a in "${HOSTS[@]}"; do
      [[ "$a" == "$b" || -z "${PUB[$a]:-}" ]] && continue
      k="${PUB[$a]}"
      on "$b" "mkdir -p ~/.ssh; touch ~/.ssh/authorized_keys; grep -qxF '$k' ~/.ssh/authorized_keys || echo '$k' >> ~/.ssh/authorized_keys" \
        || echo "WARN could not add $a's key on $b"
    done
  done
  # --- 3) host keys: record only what is not known yet (never replace a changed one)
  for a in "${HOSTS[@]}"; do
    for b in "${HOSTS[@]}"; do
      [[ "$a" == "$b" ]] && continue
      on "$a" "ssh-keygen -F $b >/dev/null 2>&1 || ssh-keyscan -T 5 $b 2>/dev/null >> ~/.ssh/known_hosts" || true
    done
  done
fi

# --- 4) the proof: every ordered pair, no prompt
echo; echo "=== check ==="; bad=0
for a in "${HOSTS[@]}"; do
  for b in "${HOSTS[@]}"; do
    [[ "$a" == "$b" ]] && continue
    if on "$a" "ssh -o BatchMode=yes -o ConnectTimeout=5 root@$b true" >/dev/null 2>&1; then :
    else echo "FAIL $a -> $b   (on $a: ssh root@$b true  - a changed host key needs: ssh-keygen -R $b after checking its fingerprint)"; bad=$((bad+1)); fi
  done
done
n=${#HOSTS[@]}; echo "=== $(( n*(n-1) - bad )) of $(( n*(n-1) )) pairs OK ==="
(( bad )) && exit 1; exit 0
