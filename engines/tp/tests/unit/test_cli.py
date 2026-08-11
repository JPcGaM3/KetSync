import json

import pytest

from ctmig.cli import human_bytes, human_secs, main


def run(capsys, *argv):
    rc = main(list(argv))
    cap = capsys.readouterr()
    return rc, cap.out, cap.err


@pytest.mark.parametrize("n,want", [
    (0, "0"), (512, "512B"), (1024, "1.0K"), (1536, "1.5K"),
    (2469606195, "2.3G"), (118111600640, "110.0G"),
])
def test_human_bytes(n, want):
    assert human_bytes(n) == want


@pytest.mark.parametrize("n,want", [
    (0, "-"), (9, "9s"), (75, "1m15s"), (3600, "1h00m"), (7325, "2h02m"),
])
def test_human_secs(n, want):
    assert human_secs(n) == want


def test_ls_lists_every_ct(repo, capsys):
    repo.write("251")
    rc, out, _ = run(capsys, "--base", str(repo.base), "ls")
    assert rc == 0
    assert "251" in out and "253" in out
    assert "synced" in out and "waiting" in out
    assert "total=2" in out


def test_ls_can_filter_to_one_lane(repo, capsys):
    repo.write("251")
    rc, out, _ = run(capsys, "--base", str(repo.base), "ls", "--storage", "tank-ssd-nas")
    assert rc == 0 and "253" in out and "tank-hdd-nas" not in out


def test_ls_shows_the_headline_only_where_it_matters(repo, capsys, make_run):
    repo.write("253", config_present=False, last=make_run(
        status="failed", reason="g5_rsync", message="GUARD G5: sync FAILED (rc=23)"))
    _, out, _ = run(capsys, "--base", str(repo.base), "ls")
    assert "GUARD G5" in out


def test_show_prints_the_history_and_the_trend(repo, capsys, make_run):
    repo.write("251")
    repo.history_write("251", [
        make_run(literal_bytes=9_000_000_000),
        make_run(literal_bytes=3_000_000_000),
        make_run(literal_bytes=200_000_000),
    ])
    rc, out, _ = run(capsys, "--base", str(repo.base), "show", "251")
    assert rc == 0
    assert "convergence" in out and "trending down" in out


def test_show_warns_that_mp_data_was_not_copied(repo, capsys):
    repo.write("251", mp_empty=["/var/www/data", "/srv/backup"])
    _, out, _ = run(capsys, "--base", str(repo.base), "show", "251")
    assert "/var/www/data" in out and "NOT copied" in out


def test_show_names_size_drift_as_harmless(repo, capsys):
    repo.write("251", size_drift=True, image_size_gib=21, config_size="20G")
    _, out, _ = run(capsys, "--base", str(repo.base), "show", "251")
    assert "DRIFT" in out and "harmless" in out


def test_show_says_so_when_a_ct_is_frozen(repo, capsys):
    repo.write("251")
    repo.freeze("251")
    _, out, _ = run(capsys, "--base", str(repo.base), "show", "251")
    assert "will not touch" in out


def test_show_of_an_unknown_ct_is_an_error_not_an_empty_page(repo, capsys):
    rc, _, err = run(capsys, "--base", str(repo.base), "show", "404")
    assert rc == 1 and "404" in err


def test_json_is_machine_readable(repo, capsys):
    repo.write("251")
    rc, out, _ = run(capsys, "--base", str(repo.base), "json")
    data = json.loads(out)
    assert rc == 0
    ids = {d["new_ctid"]: d for d in data}
    assert ids["251"]["phase"] == "synced"
    assert ids["251"]["last"]["rc"] == 0
    assert ids["253"]["last"] is None


def test_conf_shows_the_effective_lane_ceiling(repo, capsys):
    rc, out, _ = run(capsys, "--base", str(repo.base), "conf")
    assert rc == 0
    assert "250m" in out                      # BW_TOTAL_MB=500 / LANES=2
    assert "tank-hdd-nas tank-ssd-nas" in out


def test_validate_accepts_what_the_engine_writes(repo, capsys):
    pytest.importorskip("jsonschema")
    repo.write("251")
    rc, out, _ = run(capsys, "--base", str(repo.base), "validate")
    assert rc == 0 and "0 bad" in out


def test_validate_rejects_a_snapshot_with_a_bad_status(repo, capsys):
    pytest.importorskip("jsonschema")
    repo.write("251")
    snap = json.loads(repo.snapshot_path("251").read_text())
    snap["last"]["status"] = "probably fine"
    repo.snapshot_path("251").write_text(json.dumps(snap))
    rc, out, _ = run(capsys, "--base", str(repo.base), "validate")
    assert rc == 1 and "1 bad" in out


def test_validate_rejects_an_unknown_reason_slug(repo, capsys):
    """The slugs are an API: a TUI switches on them. A typo must not pass."""
    pytest.importorskip("jsonschema")
    repo.write("251")
    snap = json.loads(repo.snapshot_path("251").read_text())
    snap["last"]["reason"] = "g5_rysnc"
    repo.snapshot_path("251").write_text(json.dumps(snap))
    rc, _, _ = run(capsys, "--base", str(repo.base), "validate")
    assert rc == 1


def test_validate_says_the_inventory_is_clean_when_it_is(repo, capsys):
    pytest.importorskip("jsonschema")
    repo.write("251")
    rc, out, _ = run(capsys, "--base", str(repo.base), "validate")
    assert rc == 0 and "2 row(s), no duplicates" in out


def test_validate_reports_a_duplicate_even_though_every_state_file_is_good(repo, capsys):
    """The state can be perfect and the next run still refuse to start."""
    pytest.importorskip("jsonschema")
    repo.write("251")
    (repo.base / "inventory.tsv").write_text(
        "10.100.1.11\t251\t251\t10.100.1.31\ttank-hdd-nas\n"
        "10.100.1.12\t253\t251\t10.100.1.32\ttank-ssd-nas\n")
    rc, out, _ = run(capsys, "--base", str(repo.base), "validate")
    assert rc == 1
    assert "new_ctid 251 is on line 1 and again on line 2" in out
    assert "REFUSES to run" in out
    assert "0 bad" in out          # the schema half still ran, and still passed


def test_validate_names_the_line_of_a_malformed_row(repo, capsys):
    (repo.base / "inventory.tsv").write_text(
        "10.100.1.11\t251\t251\t10.100.1.31\ttank-hdd-nas\n"
        "10.100.1.12\t253\t253\t10.100.1.32\n")
    rc, out, _ = run(capsys, "--base", str(repo.base), "validate")
    assert rc != 0 and "inventory.tsv:2:" in out and "four-column" in out


def test_no_subcommand_behaves_like_ls(repo, capsys):
    repo.write("251")
    rc, out, _ = run(capsys, "--base", str(repo.base))
    assert rc == 0 and "total=2" in out
