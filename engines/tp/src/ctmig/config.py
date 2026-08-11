"""Parse ctmig.conf without sourcing it.

The engine sources this file as bash. Executing it here would be both a
security hole and a lie -- the reader is not bash and cannot honour bash
semantics. So this is a deliberately narrow parser: KEY=VALUE, one per line,
optionally quoted, comments and blanks ignored. Anything it does not
understand is skipped rather than guessed at, and the caller falls back to
the same defaults the engine ships with.
"""

from __future__ import annotations

import re
from pathlib import Path
from typing import Dict, Union

Value = Union[int, str]

# the engine's own defaults, repeated here so a missing ctmig.conf reads the
# same way to a human as it behaves in the engine. Keep in sync by eye; the
# unit tests assert these against the defaults block in ct-migrate.sh.
DEFAULTS: Dict[str, Value] = {
    "BW_TOTAL_MB": 230,
    "LANES": 1,
    "BW_MIN_MB": 20,
    "USAGE_FACTOR_PCT": 185,
    "HEADROOM_PCT": 30,
    "GROW_PCT": 5,
    "GROW_MAX_RETRY": 3,
    "POOL_RESERVE_GIB": 100,
    "RUNS_KEEP": 200,
    "MNT_BASE": "/mnt",
    "STORAGE_CFG": "/etc/pve/storage.cfg",
}

_LINE = re.compile(r"^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$")


def _unquote(raw: str) -> str:
    raw = raw.strip()
    # strip a trailing comment only when it cannot be part of a quoted value
    if raw[:1] not in ("'", '"'):
        raw = raw.split(" #", 1)[0].strip()
    if len(raw) >= 2 and raw[0] == raw[-1] and raw[0] in ("'", '"'):
        return raw[1:-1]
    return raw


def parse(text: str) -> Dict[str, Value]:
    """KEY=VALUE lines -> a dict, ints where the value is a plain integer."""
    out: Dict[str, Value] = {}
    for line in text.splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        m = _LINE.match(line)
        if not m:
            continue
        key, raw = m.group(1), _unquote(m.group(2))
        out[key] = int(raw) if re.fullmatch(r"-?[0-9]+", raw) else raw
    return out


def load(path: Path) -> Dict[str, Value]:
    """Defaults overlaid with whatever ctmig.conf actually sets."""
    cfg = dict(DEFAULTS)
    try:
        cfg.update(parse(path.read_text(encoding="utf-8", errors="replace")))
    except OSError:
        pass
    return cfg


def bwlimit_mb(cfg: Dict[str, Value]) -> int:
    """The per-lane ceiling, computed exactly the way the engine computes it."""
    total = int(cfg.get("BW_TOTAL_MB", DEFAULTS["BW_TOTAL_MB"]))
    lanes = max(1, int(cfg.get("LANES", DEFAULTS["LANES"])))
    floor = int(cfg.get("BW_MIN_MB", DEFAULTS["BW_MIN_MB"]))
    return max(total // lanes, floor)
