#!/usr/bin/env bash
# Add the required 5th column (storage) to an existing 4-column inventory.tsv.
#
# The engine holds inventory.tsv open on fd 3 for the whole run, so it is
# replaced atomically (tmp + mv) and never edited in place.
#
#   usage: tools/add-storage-column.sh <default-storage-id> [inventory.tsv]
set -euo pipefail
ST="${1:?usage: add-storage-column.sh <storage-id> [inventory.tsv]}"
INV="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/inventory.tsv}"
[[ -f "$INV" ]] || { echo "not found: $INV" >&2; exit 1; }

cp -a "$INV" "$INV.bak.$(date +%Y%m%d-%H%M%S)"
awk -v st="$ST" '
  /^[[:space:]]*($|#)/ { print; next }
  { n=NF; if (n==4) printf "%s\t%s\t%s\t%s\t%s\n", $1,$2,$3,$4,st; else print }
' "$INV" > "$INV.tmp"

echo "--- proposed ---"; cat "$INV.tmp"
echo "----------------"
read -r -p "replace $INV with the above? [y/N] " a
[[ "$a" == [yY] ]] || { rm -f "$INV.tmp"; echo "aborted, nothing changed"; exit 1; }
mv -f "$INV.tmp" "$INV"
echo "done. rows that already had 5 columns were left alone; a .bak was kept."
