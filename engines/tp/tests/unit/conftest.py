import json

import pytest

from ctmig.state import Repo


def _run(**kw):
    run = {
        "ts": "2026-07-23T02:00:00+0700", "epoch": 1784754000, "lane": "all",
        "mode": "presync", "status": "ok", "reason": "", "message": "",
        "rc": 0, "secs": 600, "files": 161, "literal_bytes": 2469606195,
        "bytes_sent": 2470127483, "total_bytes": 118111600640, "grow_attempts": 0,
    }
    run.update(kw)
    return run


def _snapshot(ctid="251", **kw):
    snap = {
        "schema_version": 1, "new_ctid": ctid, "old_ctid": ctid,
        "old_node": "10.100.1.11", "new_node": "10.100.1.31",
        "storage": "tank-hdd-nas",
        "image": "/pool/tank/hosting/images/%s/vm-%s-disk-0.raw" % (ctid, ctid),
        "image_size_gib": 20, "config_present": True, "config_size": "20G",
        "size_drift": False, "mp_empty": [], "last": _run(),
    }
    snap.update(kw)
    return snap


@pytest.fixture
def make_run():
    return _run


@pytest.fixture
def make_snapshot():
    return _snapshot


@pytest.fixture
def repo(tmp_path):
    """A working directory shaped exactly like the engine leaves one."""
    (tmp_path / "state").mkdir()
    (tmp_path / "done").mkdir()
    (tmp_path / "ct-migrate.sh").write_text("#!/usr/bin/env bash\n")
    (tmp_path / "inventory-migrate.tsv").write_text(
        "10.100.1.11\t251\t251\t10.100.1.31\ttank-hdd-nas\n"
        "10.100.1.12\t253\t253\t10.100.1.32\ttank-ssd-nas\n")
    (tmp_path / "ctmig.conf").write_text("BW_TOTAL_MB=500\nLANES=2\n")

    r = Repo(tmp_path)

    def write(ctid, **kw):
        r.snapshot_path(ctid).write_text(json.dumps(_snapshot(ctid, **kw)))

    def history(ctid, runs):
        with r.history_path(ctid).open("w") as fh:
            for run in runs:
                fh.write(json.dumps(run) + "\n")

    def freeze(ctid):
        (r.done_dir / ("%s.done" % ctid)).write_text("")

    r.write, r.history_write, r.freeze = write, history, freeze  # type: ignore[attr-defined]
    return r
