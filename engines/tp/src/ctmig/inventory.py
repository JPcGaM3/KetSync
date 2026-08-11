"""Parse inventory-migrate.tsv.

Five tab-separated columns, all required:

    old_node  old_ctid  new_ctid  new_node  storage

A row missing new_node or storage is NOT guessed at -- the engine refuses it
loudly and so does this. Four-column rows are the old format and are reported
as such, because that is the one mistake a human is actually going to make.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional, Tuple

COLUMNS = ("old_node", "old_ctid", "new_ctid", "new_node", "storage")


@dataclass(frozen=True)
class Row:
    lineno: int
    old_node: str
    old_ctid: str
    new_ctid: str
    new_node: str
    storage: str
    error: Optional[str] = None

    @property
    def ok(self) -> bool:
        return self.error is None


def parse(text: str) -> List[Row]:
    rows: List[Row] = []
    for lineno, line in enumerate(text.splitlines(), 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        # the engine reads with `read -r a b c d e _rest`, which splits on any
        # whitespace run, so a file saved with spaces still works. Match that.
        parts = line.split()
        got = len(parts)
        parts = (parts + [""] * 5)[:5]
        err = None
        if got == 4:
            err = "four-column row (old format) - run tools/add-storage-column.sh"
        elif got < 4:
            err = "incomplete row: need %s" % " ".join(COLUMNS)
        elif not parts[3] or not parts[4]:
            err = "new_node and storage are required, neither has a default"
        rows.append(Row(lineno, parts[0], parts[1], parts[2], parts[3], parts[4], err))
    return rows


def load(path: Path) -> List[Row]:
    try:
        return parse(path.read_text(encoding="utf-8", errors="replace"))
    except OSError:
        return []


@dataclass(frozen=True)
class Duplicate:
    kind: str      # "new_ctid" or "old_ct"
    what: str      # the id, plus the node for an old CT
    first: int     # line it was first seen on
    second: int    # line that repeats it

    def __str__(self) -> str:
        # worded exactly as preflight_inventory() words it, so an operator who
        # saw one message does not have to translate it into the other
        return "%s %s is on line %d and again on line %d" % (
            "new_ctid" if self.kind == "new_ctid" else "old CT", self.what,
            self.first, self.second)


def duplicates(rows: List[Row]) -> List[Duplicate]:
    """Rows that name the same CT twice. The engine refuses to run on these.

    This mirrors preflight_inventory() in ct-migrate.sh, including its one
    subtlety: the source key is old_node PLUS old_ctid, never old_ctid alone.
    Standalone nodes all start numbering at 100, so the same id on two
    different old nodes is two different containers and is the normal case.

    The engine is the authority -- it is the one that refuses to run. If these
    two ever disagree, this is the side that is wrong.
    """
    found: List[Duplicate] = []
    first_new: Dict[str, int] = {}
    first_src: Dict[Tuple[str, str], int] = {}
    for r in rows:
        # a row can be malformed and still name a ctid, and a duplicate hiding
        # in a row that also has a format error is worth saying out loud
        if r.new_ctid:
            prev = first_new.setdefault(r.new_ctid, r.lineno)
            if prev != r.lineno:
                found.append(Duplicate("new_ctid", r.new_ctid, prev, r.lineno))
        if r.old_ctid:
            prev = first_src.setdefault((r.old_node, r.old_ctid), r.lineno)
            if prev != r.lineno:
                found.append(Duplicate(
                    "old_ct", "%s on %s" % (r.old_ctid, r.old_node), prev, r.lineno))
    return found


def storages(rows: List[Row]) -> List[str]:
    """Distinct storage ids in file order -- one lane per storage, so this is
    also the list of lanes the cron is expected to run."""
    seen: List[str] = []
    for r in rows:
        if r.ok and r.storage not in seen:
            seen.append(r.storage)
    return seen
