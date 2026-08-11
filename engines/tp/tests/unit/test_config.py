import re
from pathlib import Path

import pytest

from ctmig.config import DEFAULTS, bwlimit_mb, load, parse

ENGINE = Path(__file__).resolve().parents[2] / "ct-migrate.sh"


def test_plain_assignments():
    cfg = parse("BW_TOTAL_MB=500\nLANES=2\nMNT_BASE=/mnt\n")
    assert cfg == {"BW_TOTAL_MB": 500, "LANES": 2, "MNT_BASE": "/mnt"}


def test_integers_come_back_as_integers_strings_as_strings():
    cfg = parse("A=7\nB=-7\nC=07\nD=7g\n")
    assert cfg["A"] == 7 and cfg["B"] == -7 and cfg["C"] == 7
    assert cfg["D"] == "7g"


def test_comments_blanks_and_quotes():
    cfg = parse('\n# a comment\nBW_TOTAL_MB=500  # trailing\nS="/a b/c"\nT=\'/d\'\n')
    assert cfg["BW_TOTAL_MB"] == 500
    assert cfg["S"] == "/a b/c"
    assert cfg["T"] == "/d"


def test_a_hash_inside_a_quoted_value_is_not_a_comment():
    assert parse('P="/pool/tank#1"')["P"] == "/pool/tank#1"


def test_lines_it_cannot_understand_are_skipped_not_guessed():
    cfg = parse("if [ -f x ]; then\n  BW_TOTAL_MB=500\nfi\n")
    assert cfg == {"BW_TOTAL_MB": 500}


def test_missing_file_gives_exactly_the_defaults(tmp_path):
    assert load(tmp_path / "nope.conf") == DEFAULTS


def test_conf_overlays_defaults(tmp_path):
    p = tmp_path / "ctmig.conf"
    p.write_text("BW_TOTAL_MB=500\n")
    cfg = load(p)
    assert cfg["BW_TOTAL_MB"] == 500
    assert cfg["GROW_MAX_RETRY"] == DEFAULTS["GROW_MAX_RETRY"]


@pytest.mark.parametrize("total,lanes,floor,expect", [
    (500, 1, 20, 500),
    (500, 2, 20, 250),
    (500, 4, 20, 125),
    (30, 4, 20, 20),      # the floor wins, exactly as the engine does it
    (500, 0, 20, 500),    # a nonsense LANES must not divide by zero
])
def test_bwlimit_matches_the_engine_formula(total, lanes, floor, expect):
    assert bwlimit_mb({"BW_TOTAL_MB": total, "LANES": lanes, "BW_MIN_MB": floor}) == expect


@pytest.mark.skipif(not ENGINE.is_file(), reason="engine not in this tree")
def test_defaults_here_match_the_defaults_in_the_engine():
    """If someone changes a default in ct-migrate.sh, this is what tells them
    the reader is now describing a configuration that does not exist."""
    text = ENGINE.read_text(encoding="utf-8")
    for key, want in DEFAULTS.items():
        m = re.search(r"^%s=(\S+)" % re.escape(key), text, re.M)
        assert m, "%s is no longer a default in ct-migrate.sh" % key
        got = m.group(1)
        assert got == str(want), "%s: engine says %s, ctmig.config says %s" % (key, got, want)
