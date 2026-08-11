import json

from ctmig.state import PHASE_ORDER, Repo, Run, convergence


def by_id(cts):
    return {c.new_ctid: c for c in cts}


# ---------- the merge ----------

def test_a_ct_with_no_state_yet_is_waiting(repo):
    cts = by_id(repo.cts())
    assert cts["251"].phase == "waiting"
    assert cts["251"].in_inventory and not cts["251"].has_state


def test_a_synced_ct_reports_its_snapshot(repo):
    repo.write("251")
    ct = by_id(repo.cts())["251"]
    assert ct.phase == "synced"
    assert ct.image_size_gib == 20 and ct.config_present and ct.config_size == "20G"
    assert ct.last is not None and ct.last.literal_bytes == 2469606195


def test_a_failed_run_needs_attention(repo, make_run):
    repo.write("251", config_present=False,
               last=make_run(status="failed", reason="g5_rsync", rc=23,
                             message="GUARD G5: sync FAILED (rc=23)"))
    ct = by_id(repo.cts())["251"]
    assert ct.phase == "attention"
    assert "GUARD G5" in ct.headline


def test_a_run_in_flight_shows_as_syncing(repo, make_run):
    repo.write("251", last=make_run(status="running", rc=-1))
    assert by_id(repo.cts())["251"].phase == "syncing"


def test_a_killed_run_shows_as_interrupted(repo, make_run):
    repo.write("251", last=make_run(status="interrupted", reason="interrupted", rc=-1))
    assert by_id(repo.cts())["251"].phase == "interrupted"


def test_a_busy_source_node_is_skipped_not_failed(repo, make_run):
    repo.write("251", config_present=False,
               last=make_run(status="skipped", reason="node_busy"))
    assert by_id(repo.cts())["251"].phase == "skipped"


def test_the_done_marker_beats_every_run_status(repo, make_run):
    """A human wrote done/<ctid>.done. Nothing the engine says may override it."""
    repo.write("251", last=make_run(status="failed", reason="g5_rsync", rc=23))
    repo.freeze("251")
    assert by_id(repo.cts())["251"].phase == "done"


def test_the_done_marker_is_read_not_stored(repo):
    """The engine must never write `done` into the state file, so the reader is
    the only place the two are joined."""
    repo.write("251")
    snap = json.loads(repo.snapshot_path("251").read_text())
    assert "done" not in snap


def test_a_state_file_with_no_inventory_row_still_appears(repo):
    """Somebody edited inventory.tsv after a sync. That image is still on a
    real disk, so hiding it would be the worst possible behaviour."""
    repo.write("999")
    ct = by_id(repo.cts())["999"]
    assert not ct.in_inventory and ct.has_state and ct.phase == "synced"


def test_the_state_file_wins_over_a_stale_inventory_row(repo):
    repo.write("251", storage="tank-ssd-nas", new_node="10.100.1.99")
    ct = by_id(repo.cts())["251"]
    assert ct.storage == "tank-ssd-nas" and ct.new_node == "10.100.1.99"


def test_a_broken_inventory_row_carries_its_error(repo):
    repo.inventory_path.write_text("10.100.1.11\t251\t251\t10.100.1.31\n")
    ct = by_id(repo.cts())["251"]
    assert ct.row_error and "four-column" in ct.row_error


# ---------- robustness ----------

def test_a_corrupt_snapshot_reads_as_no_snapshot_not_as_a_crash(repo):
    repo.snapshot_path("251").write_text("{ this is not json")
    ct = by_id(repo.cts())["251"]
    assert not ct.has_state and ct.phase == "waiting"


def test_a_truncated_snapshot_does_not_take_the_reader_down(repo):
    repo.write("251")
    text = repo.snapshot_path("251").read_text()
    repo.snapshot_path("251").write_text(text[: len(text) // 2])
    assert by_id(repo.cts())["251"].phase == "waiting"


def test_one_bad_history_line_does_not_hide_the_good_ones(repo, make_run):
    with repo.history_path("251").open("w") as fh:
        fh.write(json.dumps(make_run(rc=0)) + "\n")
        fh.write("{ half a line\n")
        fh.write(json.dumps(make_run(rc=24)) + "\n")
    runs = repo.history("251")
    assert [r.rc for r in runs] == [0, 24]


def test_history_is_oldest_first_and_limit_keeps_the_newest(repo, make_run):
    repo.history_write("251", [make_run(epoch=i, secs=i) for i in range(1, 6)])
    assert [r.secs for r in repo.history("251")] == [1, 2, 3, 4, 5]
    assert [r.secs for r in repo.history("251", limit=2)] == [4, 5]


def test_unknown_fields_in_a_snapshot_are_ignored_not_fatal(repo):
    repo.write("251", something_from_a_future_version={"a": 1})
    assert by_id(repo.cts())["251"].phase == "synced"


def test_a_wrong_typed_field_falls_back_instead_of_raising(repo, make_run):
    repo.write("251", last=make_run(rc="twenty-three", files=None))
    ct = by_id(repo.cts())["251"]
    assert ct.last.rc == -1 and ct.last.files == 0


# ---------- ordering and summary ----------

def test_the_worst_ct_sorts_first(repo, make_run):
    repo.write("251", last=make_run(status="ok"))
    repo.write("253", config_present=False, last=make_run(status="failed", reason="g5_rsync"))
    assert repo.cts()[0].new_ctid == "253"


def test_phase_order_covers_every_phase_the_reader_can_produce(repo, make_run):
    produced = set()
    for kw in ({}, {"status": "running"}, {"status": "failed"}, {"status": "skipped"},
               {"status": "interrupted"}):
        repo.write("251", last=make_run(**kw) if kw else make_run())
        produced.add(by_id(repo.cts())["251"].phase)
    repo.freeze("251")
    produced.add(by_id(repo.cts())["251"].phase)
    produced.add("waiting")
    assert produced <= set(PHASE_ORDER)


def test_summary_counts_add_up(repo, make_run):
    repo.write("251")
    repo.write("253", config_present=False, last=make_run(status="failed"))
    s = repo.summary()
    assert s["total"] == 2 and s["synced"] == 1 and s["attention"] == 1


# ---------- derived numbers ----------

def test_rate_is_wire_bytes_over_wall_clock():
    r = Run(bytes_sent=1048576 * 100, secs=100)
    assert abs(r.rate_mb_s - 1.0) < 1e-9


def test_a_zero_second_run_reports_no_rate_instead_of_dividing_by_zero():
    assert Run(bytes_sent=123, secs=0).rate_mb_s == 0.0


def test_convergence_only_counts_runs_that_actually_transferred(make_run):
    runs = [
        Run.from_dict(make_run(literal_bytes=900, rc=0, status="ok")),
        Run.from_dict(make_run(literal_bytes=0, rc=23, status="failed")),
        Run.from_dict(make_run(literal_bytes=400, rc=24, status="ok")),
        Run.from_dict(make_run(literal_bytes=0, rc=-1, status="skipped")),
        Run.from_dict(make_run(literal_bytes=100, rc=0, status="ok")),
    ]
    assert convergence(runs) == [900, 400, 100]


# ---------- locating ----------

def test_locate_walks_up_to_the_engine(tmp_path):
    (tmp_path / "ct-migrate.sh").write_text("#!/usr/bin/env bash\n")
    deep = tmp_path / "state" / "a" / "b"
    deep.mkdir(parents=True)
    assert Repo.locate(deep).base == tmp_path.resolve()


def test_locate_never_invents_a_path_when_there_is_no_engine(tmp_path):
    assert Repo.locate(tmp_path).base == tmp_path.resolve()
