"""Read the engine's state/ directory and merge it with the inventory.

Three sources, three owners:

    inventory-migrate.tsv        a human, by hand -- what is SUPPOSED to happen
    state/<ctid>.json    the engine -- what actually happened, last run
    done/<ctid>.done     a human, by hand -- "stop touching this one"

The engine deliberately does not record `done` in its state file: the marker
is not its to own, and a frozen row is skipped before any state is written.
So the merge happens here, and only here.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Optional

from . import SCHEMA_VERSION
from .inventory import Row

# ordering matters: this is the sort order the TUI should list CTs in, worst
# first, because a screen full of finished CTs must never bury a broken one.
PHASE_ORDER = ("attention", "syncing", "interrupted", "waiting", "skipped", "synced", "done")


@dataclass(frozen=True)
class Run:
    ts: str = ""
    epoch: int = 0
    lane: str = ""
    mode: str = ""
    status: str = ""
    reason: str = ""
    message: str = ""
    rc: int = -1
    secs: int = 0
    files: int = 0
    literal_bytes: int = 0
    bytes_sent: int = 0
    total_bytes: int = 0
    grow_attempts: int = 0

    @classmethod
    def from_dict(cls, d: Dict) -> "Run":
        def s(k: str) -> str:
            v = d.get(k, "")
            return v if isinstance(v, str) else str(v)

        def i(k: str, default: int = 0) -> int:
            v = d.get(k, default)
            return v if isinstance(v, int) and not isinstance(v, bool) else default

        return cls(
            ts=s("ts"), epoch=i("epoch"), lane=s("lane"), mode=s("mode"),
            status=s("status"), reason=s("reason"), message=s("message"),
            rc=i("rc", -1), secs=i("secs"), files=i("files"),
            literal_bytes=i("literal_bytes"), bytes_sent=i("bytes_sent"),
            total_bytes=i("total_bytes"), grow_attempts=i("grow_attempts"),
        )

    @property
    def rate_mb_s(self) -> float:
        """Wire rate of this run. Zero-second runs report 0 rather than dividing."""
        return (self.bytes_sent / self.secs / 1048576.0) if self.secs > 0 else 0.0


@dataclass
class CT:
    new_ctid: str
    old_ctid: str = ""
    old_node: str = ""
    new_node: str = ""
    storage: str = ""
    image: str = ""
    image_size_gib: int = 0
    config_present: bool = False
    config_size: str = ""
    size_drift: bool = False
    mp_empty: List[str] = field(default_factory=list)
    last: Optional[Run] = None
    done: bool = False
    in_inventory: bool = False
    has_state: bool = False
    row_error: Optional[str] = None
    schema_version: int = SCHEMA_VERSION

    @property
    def phase(self) -> str:
        """One word for what a human should think about this CT.

        `done` wins over everything: the marker is a human saying "I have
        judged this one, leave it alone", and no later run may override that.
        """
        if self.done:
            return "done"
        if not self.has_state or self.last is None:
            return "waiting"
        st = self.last.status
        if st == "running":
            return "syncing"
        if st == "interrupted":
            return "interrupted"
        if st == "failed":
            return "attention"
        if st == "skipped":
            return "skipped"
        return "synced" if self.config_present else "waiting"

    @property
    def sort_key(self):
        try:
            p = PHASE_ORDER.index(self.phase)
        except ValueError:
            p = len(PHASE_ORDER)
        try:
            n = int(self.new_ctid)
        except ValueError:
            n = 0
        return (p, self.storage, n, self.new_ctid)

    @property
    def headline(self) -> str:
        """What to show on one line when something is wrong."""
        if self.row_error:
            return self.row_error
        if self.last is None:
            return "no run yet"
        return self.last.message or self.last.reason or ""


class Repo:
    """A ct-migrate.sh working directory."""

    def __init__(self, base: Path):
        self.base = Path(base)

    # ---------- locating ----------
    @classmethod
    def locate(cls, start: Optional[Path] = None) -> "Repo":
        """Walk up from `start` looking for ct-migrate.sh.

        The engine puts everything next to itself, so finding the script is
        the same as finding the data. Never hard-code an absolute path: the
        same tree is checked out in different places on different nodes.
        """
        here = Path(start or Path.cwd()).resolve()
        for d in [here, *here.parents]:
            if (d / "ct-migrate.sh").is_file():
                return cls(d)
        return cls(here)

    # ---------- paths ----------
    @property
    def inventory_path(self) -> Path:
        return self.base / "inventory-migrate.tsv"

    @property
    def conf_path(self) -> Path:
        return self.base / "ctmig.conf"

    @property
    def state_dir(self) -> Path:
        return self.base / "state"

    @property
    def done_dir(self) -> Path:
        return self.base / "done"

    # Each engine writes state/<tool>-<ctid>.json so two of them can hold history
    # for the same container at once. Files with no prefix are from before that
    # split and are still read, so a reader pointed at a fleet mid-upgrade does
    # not simply go blank.
    TOOL_PREFIXES = ("migrate-", "replica-", "failback-")

    def snapshot_path(self, ctid: str) -> Path:
        """The newest tool-prefixed snapshot for this CT, else the pre-split one."""
        best, best_mtime = None, -1.0
        for pref in self.TOOL_PREFIXES:
            cand = self.state_dir / ("%s%s.json" % (pref, ctid))
            try:
                m = cand.stat().st_mtime
            except OSError:
                continue
            if m > best_mtime:
                best, best_mtime = cand, m
        return best if best is not None else self.state_dir / ("%s.json" % ctid)

    def history_path(self, ctid: str) -> Path:
        snap = self.snapshot_path(ctid)
        return snap.with_name(snap.name[: -len(".json")] + ".runs.jsonl")

    @classmethod
    def strip_tool_prefix(cls, stem: str) -> str:
        for pref in cls.TOOL_PREFIXES:
            if stem.startswith(pref):
                return stem[len(pref):]
        return stem

    # ---------- reading ----------
    def snapshot(self, ctid: str) -> Optional[Dict]:
        try:
            with self.snapshot_path(ctid).open(encoding="utf-8") as fh:
                d = json.load(fh)
        except (OSError, ValueError):
            return None
        return d if isinstance(d, dict) else None

    def history(self, ctid: str, limit: Optional[int] = None) -> List[Run]:
        """Oldest first. A corrupt line is skipped, never fatal: the history is
        for a human reading a trend, and one bad append must not hide the rest."""
        runs: List[Run] = []
        try:
            with self.history_path(ctid).open(encoding="utf-8") as fh:
                for line in fh:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        d = json.loads(line)
                    except ValueError:
                        continue
                    if isinstance(d, dict):
                        runs.append(Run.from_dict(d))
        except OSError:
            return []
        return runs[-limit:] if limit else runs

    def is_done(self, ctid: str) -> bool:
        return (self.done_dir / ("%s.done" % ctid)).exists()

    def cts(self, rows: Optional[List[Row]] = None) -> List[CT]:
        """Every CT the tool knows about, inventory and state merged.

        A CT with a state file but no inventory row still shows up: that is
        somebody having edited inventory-migrate.tsv after a sync, and silently
        dropping it would hide real work sitting on a real disk.
        """
        if rows is None:
            from .inventory import load as load_inventory
            rows = load_inventory(self.inventory_path)

        out: Dict[str, CT] = {}
        for r in rows:
            ct = CT(
                new_ctid=r.new_ctid or "?", old_ctid=r.old_ctid,
                old_node=r.old_node, new_node=r.new_node, storage=r.storage,
                in_inventory=True, row_error=r.error,
            )
            out[ct.new_ctid] = ct

        try:
            orphans = sorted({self.strip_tool_prefix(p.stem)
                              for p in self.state_dir.glob("*.json")})
        except OSError:
            orphans = []
        for ctid in orphans:
            if ctid not in out:
                out[ctid] = CT(new_ctid=ctid)

        for ctid, ct in out.items():
            ct.done = self.is_done(ctid)
            snap = self.snapshot(ctid)
            if snap:
                ct.has_state = True
                ct.schema_version = snap.get("schema_version", SCHEMA_VERSION)
                # the state file is the engine's own record, so where the two
                # disagree it wins: the inventory may have been edited since.
                for key in ("old_ctid", "old_node", "new_node", "storage", "image", "config_size"):
                    val = snap.get(key)
                    if isinstance(val, str) and val:
                        setattr(ct, key, val)
                ct.image_size_gib = int(snap.get("image_size_gib") or 0)
                ct.config_present = bool(snap.get("config_present"))
                ct.size_drift = bool(snap.get("size_drift"))
                mp = snap.get("mp_empty")
                ct.mp_empty = [str(x) for x in mp] if isinstance(mp, list) else []
                last = snap.get("last")
                if isinstance(last, dict):
                    ct.last = Run.from_dict(last)

        return sorted(out.values(), key=lambda c: c.sort_key)

    def summary(self, cts: Optional[List[CT]] = None) -> Dict[str, int]:
        cts = self.cts() if cts is None else cts
        counts = {p: 0 for p in PHASE_ORDER}
        for ct in cts:
            counts[ct.phase] = counts.get(ct.phase, 0) + 1
        counts["total"] = len(cts)
        return counts


def convergence(runs: List[Run]) -> List[int]:
    """literal_bytes per successful run, oldest first.

    This is the number that answers "is this CT ready to cut over" -- it is
    the new data rsync had to send, so it should fall towards a floor of
    whatever the CT writes between runs. Runs that never transferred anything
    are dropped so a failed run does not read as convergence.
    """
    return [r.literal_bytes for r in runs if r.status in ("ok",) and r.rc in (0, 24)]
