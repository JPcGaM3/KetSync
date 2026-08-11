#!/usr/bin/env bash
# =============================================================================
#  check-no-thai.sh — the language rule, for the ketsync layer.
# -----------------------------------------------------------------------------
#  Same rule as engines/tp: Thai belongs in docs/*.html and nowhere else, and
#  even there it belongs in the prose, never inside <pre> or <code>. Commands
#  are copied out of a guide and pasted into a shell at 2am; a Thai word in one
#  is a syntax error at the worst possible moment.
#
#  This checks the ketsync layer only. engines/tp has its own copy and its own
#  Makefile target, because it is its own body of work with its own docs, and
#  one checker walking both would report tp's files against ketsync's paths.
#
#  Matching is on UTF-8 bytes rather than a character class, because grep -P on
#  some hosts refuses code points above U+00FF. Thai U+0E00-U+0E7F encodes as
#  E0 B8 80 .. E0 B9 BF, so the two-byte prefix is enough.
#
#  usage:  ./tools/check-no-thai.sh
#          make no-thai
# =============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

rc=0

# 1. no Thai outside docs/*.html. engines/ is excluded rather than walked: it
#    is checked by its own tools/check-no-thai.sh, via `make -C engines/tp`.
hits="$(LC_ALL=C grep -rlI $'\xe0[\xb8\xb9]' . \
          --exclude-dir=.git --exclude-dir=engines --exclude-dir=_tmp \
          --exclude-dir=.pytest_cache --exclude-dir=__pycache__ \
          --exclude='*.html' 2>/dev/null)"
if [[ -n "$hits" ]]; then
  echo "Thai found outside docs/*.html:"
  echo "$hits" | sed 's/^/    /'
  echo "  code and comments are English - only the operator guide is Thai"
  rc=1
fi

# 2. no Thai inside a <pre> or <code> block, even in the guide.
while IFS= read -r f; do
  [[ -e "$f" ]] || continue
  if LC_ALL=C perl -0777 -ne '
        my $bad = 0;
        while (m{<(pre|code)\b[^>]*>(.*?)</\1>}gis) {
          my $body = $2;
          $bad++ if $body =~ /\xe0[\xb8\xb9]/;
        }
        exit($bad ? 1 : 0);' "$f"; then
    :
  else
    echo "Thai inside a <pre> or <code> block: $f"
    echo "  prose may be Thai, commands may not - they get pasted into a shell"
    rc=1
  fi
done < <(find docs -name '*.html' 2>/dev/null)

(( rc == 0 )) && echo "language check: clean"
exit $rc
