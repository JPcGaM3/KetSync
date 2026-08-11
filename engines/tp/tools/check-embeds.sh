#!/usr/bin/env bash
# =============================================================================
#  check-embeds.sh — docs/infra-setup.html ships a full copy of several scripts
#  inside <details> blocks, and a copy drifts. It has drifted twice: once the
#  doc handed out a cron line pointing at a folder the layout no longer had,
#  because that line lived inside a stale copy of an engine's own header.
#
#  This says so before a reader finds out. `make lint` runs it.
#
#  usage:  ./tools/check-embeds.sh          report
#          ./tools/check-embeds.sh --fix    re-embed from the working tree
# =============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1
FIX=0; [[ "${1:-}" == --fix ]] && FIX=1
PY=python3
command -v "$PY" >/dev/null || { echo "embeds: python3 not installed - skipped"; exit 0; }
"$PY" - "$FIX" <<'PYEOF'
import io, re, html, sys
fix = sys.argv[1] == "1"
doc = "docs/infra-setup.html"
s = io.open(doc, encoding="utf-8").read()
pat = re.compile(r'(<details class="src"><summary>[^<]*?:\s*([\w.\-]+)[^<]*</summary>\s*'
                 r'<div class="code"><pre>)(.*?)(</pre></div>\s*</details>)', re.S)
bad = []
def repl(m):
    head, name, body, tail = m.groups()
    try:
        cur = html.escape(io.open(name, encoding="utf-8").read().rstrip("\n"), quote=True)
    except FileNotFoundError:
        bad.append("%s: embedded but no such file in the repo" % name); return m.group(0)
    if cur != body:
        bad.append("%s: the copy in %s no longer matches the file" % (name, doc))
        if fix: return head + cur + tail
    return m.group(0)
out = pat.sub(repl, s)
if fix and out != s:
    io.open(doc, "w", encoding="utf-8").write(out)
    print("embeds: re-embedded %d block(s) in %s" % (len(bad), doc)); sys.exit(0)
if bad:
    print("embeds: OUT OF DATE"); [print("    " + b) for b in bad]
    print("    fix with:  ./tools/check-embeds.sh --fix"); sys.exit(1)
print("embeds: clean")
PYEOF
