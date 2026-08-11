"""ctmig -- read what ct-migrate.sh left behind.

Every subcommand is read-only. Nothing in here can change a migration, which
is the point: this is the thing you run at 2am to decide whether to cut over,
and it must not be able to make the situation worse.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import List, Optional

from . import __version__
from .config import bwlimit_mb, load as load_conf
from .inventory import duplicates, load as load_inventory, storages
from .state import CT, Repo, convergence

PHASE_MARK = {
    "attention": "!!", "syncing": ">>", "interrupted": "??",
    "waiting": "..", "skipped": "--", "synced": "ok", "done": "##",
}


def human_bytes(n: int) -> str:
    if n <= 0:
        return "0"
    for unit in ("B", "K", "M", "G", "T"):
        if n < 1024 or unit == "T":
            return ("%d%s" % (n, unit)) if unit == "B" else ("%.1f%s" % (n, unit))
        n /= 1024.0
    return str(n)


def human_secs(n: int) -> str:
    if n <= 0:
        return "-"
    h, rem = divmod(n, 3600)
    m, s = divmod(rem, 60)
    if h:
        return "%dh%02dm" % (h, m)
    if m:
        return "%dm%02ds" % (m, s)
    return "%ds" % s


def _table(rows: List[List[str]], headers: List[str]) -> str:
    width = [len(h) for h in headers]
    for r in rows:
        for i, cell in enumerate(r):
            width[i] = max(width[i], len(cell))
    line = "  ".join(h.ljust(width[i]) for i, h in enumerate(headers)).rstrip()
    out = [line, "  ".join("-" * w for w in width).rstrip()]
    for r in rows:
        out.append("  ".join(c.ljust(width[i]) for i, c in enumerate(r)).rstrip())
    return "\n".join(out)


def cmd_ls(repo: Repo, args: argparse.Namespace) -> int:
    cts = repo.cts()
    if args.storage:
        cts = [c for c in cts if c.storage == args.storage]
    if args.phase:
        cts = [c for c in cts if c.phase == args.phase]
    rows = []
    for c in cts:
        last = c.last
        rows.append([
            PHASE_MARK.get(c.phase, "?"), c.new_ctid, c.phase, c.storage,
            "%s -> %s" % (c.old_node or "?", c.new_node or "?"),
            "%dG" % c.image_size_gib if c.image_size_gib else "-",
            human_bytes(last.literal_bytes) if last else "-",
            human_secs(last.secs) if last else "-",
            (last.ts[:16].replace("T", " ") if last and last.ts else "-"),
            (c.headline[:60] if c.phase in ("attention", "skipped", "interrupted") else ""),
        ])
    print(_table(rows, ["", "ct", "phase", "storage", "path", "img",
                        "new data", "took", "last run", "note"]))
    s = repo.summary(cts)
    print()
    print("  ".join("%s=%d" % (k, s[k]) for k in
                    ("total", "done", "synced", "syncing", "waiting",
                     "skipped", "interrupted", "attention") if k in s))
    return 0


def cmd_show(repo: Repo, args: argparse.Namespace) -> int:
    cts = {c.new_ctid: c for c in repo.cts()}
    ct: Optional[CT] = cts.get(args.ctid)
    if ct is None:
        print("no CT %s in the inventory or in state/" % args.ctid, file=sys.stderr)
        return 1
    print("CT %s  [%s]" % (ct.new_ctid, ct.phase))
    print("  source     %s (CT %s)" % (ct.old_node or "?", ct.old_ctid or "?"))
    print("  target     %s on storage %s" % (ct.new_node or "?", ct.storage or "?"))
    print("  image      %s" % (ct.image or "-"))
    print("  size       %dG image, config says %s%s" % (
        ct.image_size_gib, ct.config_size or "-",
        "   << DRIFT, harmless bookkeeping" if ct.size_drift else ""))
    print("  config     %s" % ("written" if ct.config_present else "not written yet"))
    if ct.mp_empty:
        print("  EMPTY mp   %s" % ", ".join(ct.mp_empty))
        print("             these are migrated as config only - the data was NOT copied")
    if ct.done:
        print("  frozen     done/%s.done exists, the engine will not touch this CT" % ct.new_ctid)
    if ct.headline:
        print("  note       %s" % ct.headline)

    runs = repo.history(ct.new_ctid, limit=args.limit)
    if runs:
        print()
        rows = [[
            (r.ts[:16].replace("T", " ") or "-"), r.mode, r.status,
            r.reason or "", str(r.rc), human_secs(r.secs), str(r.files),
            human_bytes(r.literal_bytes), human_bytes(r.bytes_sent),
            "%.0f" % r.rate_mb_s if r.secs else "-",
            str(r.grow_attempts) if r.grow_attempts else "",
        ] for r in runs]
        print(_table(rows, ["when", "mode", "status", "reason", "rc", "took",
                            "files", "new data", "on wire", "MB/s", "grow"]))
        conv = convergence(runs)
        if len(conv) >= 2:
            print()
            print("  convergence (new data per good run, oldest first):")
            print("    %s" % "  ".join(human_bytes(b) for b in conv[-8:]))
            if conv[-1] < conv[0]:
                print("    trending down - the delta is shrinking, which is what you want")
            elif conv[-1] == conv[0]:
                print("    flat - the CT rewrites about as much as each run copies")
            else:
                print("    NOT shrinking - the CT is writing faster than the syncs converge")
    return 0


def cmd_json(repo: Repo, args: argparse.Namespace) -> int:
    out = []
    for c in repo.cts():
        d = dict(vars(c))
        d["phase"] = c.phase
        d["last"] = dict(vars(c.last)) if c.last else None
        out.append(d)
    json.dump(out, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0


def _schema_path(repo: Repo) -> Optional[Path]:
    """The schema ships with the source tree, not with the data directory.

    --base can point at a working directory that is only state/ and logs/, so
    look there first and then fall back to the tree this module was loaded
    from. Never hard-code an absolute path.
    """
    here = Path(__file__).resolve()
    candidates = [repo.base / "schema" / "state.schema.json"]
    candidates += [p / "schema" / "state.schema.json" for p in here.parents]
    for c in candidates:
        if c.is_file():
            return c
    return None


def _check_inventory(repo: Repo) -> bool:
    """Print what is wrong with inventory.tsv. True when something is.

    Deliberately first, and deliberately stdlib-only: this is the half of
    `validate` that answers "will the engine even start", and it has to work on
    a node where jsonschema is not installed.
    """
    rows = load_inventory(repo.inventory_path)
    if not rows:
        print("inventory.tsv: no rows found at %s" % repo.inventory_path)
        return False
    bad = False
    for r in rows:
        if not r.ok:
            print("inventory.tsv:%d: %s" % (r.lineno, r.error))
            bad = True
    dups = duplicates(rows)
    for d in dups:
        print("inventory.tsv: %s" % d)
    if dups:
        print("inventory.tsv: ct-migrate.sh REFUSES to run while a CT is named twice")
        bad = True
    if not bad:
        print("inventory.tsv: %d row(s), no duplicates" % len(rows))
    return bad


def cmd_validate(repo: Repo, args: argparse.Namespace) -> int:
    """Check inventory.tsv, then every state file against schema/state.schema.json."""
    bad_inv = _check_inventory(repo)
    print()
    # a real finding outranks "the schema half could not run": rc 2 means this
    # command could not do its job, and it just did half of it, badly-shaped
    # inventory and all.
    cannot = 1 if bad_inv else 2
    schema_path = _schema_path(repo)
    if schema_path is None:
        print("state.schema.json not found near %s or %s" % (repo.base, Path(__file__).parent),
              file=sys.stderr)
        return cannot
    try:
        schema = json.loads(schema_path.read_text(encoding="utf-8"))
    except OSError:
        print("cannot read %s" % schema_path, file=sys.stderr)
        return cannot
    try:
        import jsonschema
    except ImportError:
        print("jsonschema is not installed - pip install jsonschema", file=sys.stderr)
        return cannot

    validator = jsonschema.Draft202012Validator(schema)
    files = sorted(repo.state_dir.glob("*.json"))
    if not files:
        print("no state files yet in %s" % repo.state_dir)
        return 1 if bad_inv else 0
    bad = 0
    for f in files:
        try:
            inst = json.loads(f.read_text(encoding="utf-8"))
        except ValueError as exc:
            print("%s: not valid JSON: %s" % (f.name, exc))
            bad += 1
            continue
        errs = sorted(validator.iter_errors(inst), key=lambda e: list(e.path))
        for e in errs:
            print("%s: %s: %s" % (f.name, "/".join(str(p) for p in e.path) or "<root>", e.message))
        bad += 1 if errs else 0
    print("%d file(s) checked, %d bad" % (len(files), bad))
    return 1 if (bad or bad_inv) else 0


def cmd_conf(repo: Repo, args: argparse.Namespace) -> int:
    cfg = load_conf(repo.conf_path)
    rows = [[k, str(v)] for k, v in sorted(cfg.items())]
    print(_table(rows, ["setting", "value"]))
    print()
    print("per-lane rsync ceiling: %dm  (BW_TOTAL_MB / LANES, floored at BW_MIN_MB)"
          % bwlimit_mb(cfg))
    lanes = storages(load_inventory(repo.inventory_path))
    if lanes:
        print("lanes in inventory.tsv: %s" % " ".join(lanes))
    return 0



def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="ctmig",
        description="read-only view of a ct-migrate.sh working directory")
    p.add_argument("--base", type=Path, default=None,
                   help="the directory ct-migrate.sh lives in (default: found by walking up)")
    p.add_argument("--version", action="version", version="ctmig %s" % __version__)
    sub = p.add_subparsers(dest="cmd")

    ls = sub.add_parser("ls", help="one line per CT, worst first")
    ls.add_argument("--storage", help="only this lane")
    ls.add_argument("--phase", help="only CTs in this phase")
    ls.set_defaults(func=cmd_ls)

    show = sub.add_parser("show", help="everything known about one CT, plus its run history")
    show.add_argument("ctid")
    show.add_argument("--limit", type=int, default=20, help="history lines to show")
    show.set_defaults(func=cmd_show)

    sub.add_parser("json", help="the merged model as JSON").set_defaults(func=cmd_json)
    sub.add_parser("validate",
                   help="check inventory.tsv for duplicates and bad rows, then "
                        "every state file against the schema").set_defaults(func=cmd_validate)
    sub.add_parser("conf", help="effective configuration and lanes").set_defaults(func=cmd_conf)
    return p


def main(argv: Optional[List[str]] = None) -> int:
    args = build_parser().parse_args(argv)
    repo = Repo(args.base) if args.base else Repo.locate()
    func = getattr(args, "func", None)
    if func is None:
        return cmd_ls(repo, argparse.Namespace(storage=None, phase=None))
    return func(repo, args)


if __name__ == "__main__":
    raise SystemExit(main())
