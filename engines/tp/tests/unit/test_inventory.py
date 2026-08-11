from ctmig.inventory import duplicates, parse, storages

GOOD = "10.100.1.11\t251\t251\t10.100.1.31\ttank-hdd-nas\n"


def test_a_complete_row_parses():
    (row,) = parse(GOOD)
    assert (row.old_node, row.old_ctid, row.new_ctid, row.new_node, row.storage) == (
        "10.100.1.11", "251", "251", "10.100.1.31", "tank-hdd-nas")
    assert row.ok


def fields(row):
    return (row.old_node, row.old_ctid, row.new_ctid, row.new_node, row.storage, row.error)


def test_comments_and_blank_lines_are_ignored():
    assert [fields(r) for r in parse("# header\n\n" + GOOD + "\n")] == \
           [fields(r) for r in parse(GOOD)]


def test_line_numbers_survive_the_ignoring():
    rows = parse("# header\n\n" + GOOD)
    assert rows[0].lineno == 3


def test_spaces_work_because_the_engine_splits_on_whitespace():
    (row,) = parse("10.100.1.11 251 251 10.100.1.31 tank-hdd-nas\n")
    assert row.ok and row.storage == "tank-hdd-nas"


def test_a_four_column_row_is_named_as_the_old_format():
    (row,) = parse("10.100.1.11\t251\t251\t10.100.1.31\n")
    assert not row.ok
    assert "four-column" in row.error


def test_a_short_row_is_refused_not_padded():
    (row,) = parse("10.100.1.11\t251\n")
    assert not row.ok


def test_an_empty_column_is_refused_the_same_way_the_engine_refuses_it():
    """`read -r a b c d e` collapses a run of whitespace, so a row with an empty
    middle column is indistinguishable from a four-column row -- to the engine
    and therefore to this reader. What matters is that neither one is guessed
    at: new_node and storage have no default."""
    (row,) = parse("10.100.1.11\t251\t251\t\ttank-hdd-nas\n")
    assert not row.ok


def test_a_trailing_empty_storage_column_is_refused():
    (row,) = parse("10.100.1.11\t251\t251\t10.100.1.31\t\n")
    assert not row.ok


def test_a_sixth_column_is_tolerated_the_way_read_r_rest_tolerates_it():
    (row,) = parse(GOOD.rstrip("\n") + "\ttrailing junk\n")
    assert row.ok and row.storage == "tank-hdd-nas"


def test_storages_are_the_lanes_in_file_order_without_duplicates():
    text = (
        "a\t1\t1\tb\ttank-hdd-nas\n"
        "a\t2\t2\tb\ttank-ssd-nas\n"
        "a\t3\t3\tb\ttank-hdd-nas\n"
        "a\t4\t4\t\t\n"          # broken rows are not lanes
    )
    assert storages(parse(text)) == ["tank-hdd-nas", "tank-ssd-nas"]


def test_a_repeated_new_ctid_is_found_with_both_line_numbers():
    text = (
        "# header\n"
        "\n"
        "10.100.1.11\t251\t251\t10.100.1.31\ttank-hdd-nas\n"
        "10.100.1.12\t253\t251\t10.100.1.32\ttank-ssd-nas\n"
    )
    (dup,) = duplicates(parse(text))
    assert (dup.kind, dup.what, dup.first, dup.second) == ("new_ctid", "251", 3, 4)
    assert str(dup) == "new_ctid 251 is on line 3 and again on line 4"


def test_the_same_old_ct_twice_on_one_node_is_a_duplicate():
    text = (
        "10.100.1.11\t251\t251\t10.100.1.31\ttank-hdd-nas\n"
        "10.100.1.11\t251\t252\t10.100.1.31\ttank-ssd-nas\n"
    )
    (dup,) = duplicates(parse(text))
    assert dup.kind == "old_ct"
    assert str(dup) == "old CT 251 on 10.100.1.11 is on line 1 and again on line 2"


def test_the_same_old_ctid_on_two_different_nodes_is_not_a_duplicate():
    """Every standalone node started numbering at 100, so this is the normal
    case. Keying the check on old_ctid alone would refuse a correct file."""
    text = (
        "10.100.1.11\t100\t251\t10.100.1.31\ttank-hdd-nas\n"
        "10.100.1.12\t100\t253\t10.100.1.32\ttank-ssd-nas\n"
    )
    assert duplicates(parse(text)) == []


def test_a_clean_inventory_has_no_duplicates():
    assert duplicates(parse(GOOD + "10.100.1.12\t253\t253\t10.100.1.32\ttank-ssd-nas\n")) == []


def test_three_rows_sharing_one_id_report_against_the_first():
    text = (
        "a\t1\t9\tb\ts\n"
        "a\t2\t9\tb\ts\n"
        "a\t3\t9\tb\ts\n"
    )
    dups = duplicates(parse(text))
    assert [(d.first, d.second) for d in dups] == [(1, 2), (1, 3)]


def test_a_duplicate_inside_a_malformed_row_still_counts():
    """The row is broken AND repeated. The engine reports the duplicate first,
    because it refuses to run at all in that case."""
    text = (
        "10.100.1.11\t251\t251\t10.100.1.31\ttank-hdd-nas\n"
        "10.100.1.12\t253\t251\n"
    )
    rows = parse(text)
    assert not rows[1].ok
    (dup,) = duplicates(rows)
    assert dup.what == "251"
