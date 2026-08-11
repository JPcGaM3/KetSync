#!/usr/bin/env bash
# =============================================================================
#  check-no-thai.sh — enforce the one language rule this repo has.
# -----------------------------------------------------------------------------
#  Thai belongs in the operator guide, docs/*.html, and nowhere else. Not in
#  code, not in comments, not in test names, not in a commit message.
#
#  The reason is narrow and practical: the guide is read by a human, but code
#  and comments are read by whoever is debugging a failed migration, and by
#  tooling that has no opinion about encodings. A Thai string inside a <pre>
#  block is worse still — it gets copied into a shell at 2am.
#
#  Matching is done on UTF-8 bytes rather than on a character class, because
#  grep -P on some hosts refuses code points above U+00FF. Thai U+0E00-U+0E7F
#  encodes as E0 B8 80 .. E0 B9 BF, so the two-byte prefix is enough.
#
#  usage:  ./tools/check-no-thai.sh
#          make no-thai
# =============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

rc=0

# 1. no Thai outside docs/*.html
hits="$(LC_ALL=C grep -rlI $'\xe0[\xb8\xb9]' . \
          --exclude-dir=.git --exclude-dir=.pytest_cache \
          --exclude-dir=__pycache__ --exclude-dir=.venv --exclude-dir=venv \
          --exclude='*.html' 2>/dev/null)"
if [[ -n "$hits" ]]; then
  echo "Thai found outside docs/*.html:"
  echo "$hits" | sed 's/^/    /'
  echo "  code and comments are English - only the operator guide is Thai"
  rc=1
fi

# 2. no Thai inside a <pre> or <code> block, even in the guide. Commands get
#    copied and pasted; a Thai word inside one becomes a shell error.
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
