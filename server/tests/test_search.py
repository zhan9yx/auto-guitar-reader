from __future__ import annotations

import pytest
from conftest import make_score, search, titles, upload
from app.search import normalize, pinyin_full, pinyin_initials


def seed(client):
    for title, artist in [
        ("七里香", "周杰伦"),
        ("晴天", "周杰伦"),
        ("Yesterday", "The Beatles"),
        ("Let It Be", "The Beatles"),
        ("海阔天空", "Beyond"),
    ]:
        assert upload(client, make_score(title, artist)).status_code == 201


def test_normalize_and_pinyin_helpers():
    assert normalize("  Ｊａｙ  Ｃｈｏｕ！ ") == "jaychou"
    assert normalize("Let's, Go-Home.") == "letsgohome"
    assert normalize(None) == "" and normalize("") == ""
    assert pinyin_full("七里香") == "qilixiang"
    assert pinyin_initials("七里香") == "qlx"
    assert pinyin_initials("Hello 世界") == "hello" + "sj"
    assert pinyin_full("周杰伦 Jay") == "zhoujielunjay"


@pytest.mark.parametrize(
    "q,expected",
    [
        ("qlx", ["七里香"]),
        ("QLX", ["七里香"]),
        ("qilixiang", ["七里香"]),
        ("qi li xiang", ["七里香"]),
        ("七里", ["七里香"]),
        ("hktk", ["海阔天空"]),
        ("haikuotiankong", ["海阔天空"]),
        ("beyond", ["海阔天空"]),
        ("ＢＥＹＯＮＤ", ["海阔天空"]),
        ("let it be", ["Let It Be"]),
        ("LETITBE!", ["Let It Be"]),
        ("beatles", ["Yesterday", "Let It Be"]),
        ("nothing-matches", []),
    ],
)
def test_search_matches(client, q, expected):
    seed(client)
    res = search(client, q)
    assert sorted(titles(res)) == sorted(expected), q
    assert res["total"] == len(expected)


def test_search_by_artist_pinyin(client):
    seed(client)
    for q in ("zhoujielun", "zjl", "周杰伦", "杰伦"):
        assert sorted(titles(search(client, q))) == ["七里香", "晴天"], q


def test_empty_query_lists_everything_most_recent_first(client):
    seed(client)
    res = search(client)
    assert res["total"] == 5
    assert titles(res)[0] == "海阔天空" and titles(res)[-1] == "七里香"


def test_ranking_exact_prefix_substring_artist_pinyin(client):
    # all matched by query "qing"; tiers: exact(0) > prefix(1) > substring(2) > artist(3) > pinyin(4)
    for title, artist in [
        ("晴天 pinyin only", None),            # pinyin tier: "qingtianpinyinonly" contains... (see below)
        ("my qing", None),                      # substring
        ("qing song", None),                    # prefix
        ("qing", None),                         # exact
        ("zzz", "Qing Artist"),                 # artist substring
    ]:
        upload(client, make_score(title, artist))
    got = titles(search(client, "qing"))
    assert got == ["qing", "qing song", "my qing", "zzz", "晴天 pinyin only"]


def test_rank_beats_sort_but_sort_breaks_ties(client):
    for title in ("abc one", "abc two", "abc"):
        upload(client, make_score(title, None))
    ids = {i["title"]: i["id"] for i in search(client)["items"]}
    for _ in range(3):
        client.get(f"/api/v1/scores/{ids['abc one']}")
    client.get(f"/api/v1/scores/{ids['abc two']}")
    popular = titles(search(client, "abc", sort="popular"))
    assert popular == ["abc", "abc one", "abc two"]  # exact first, then prefix by downloads
    recent = titles(search(client, "abc", sort="recent"))
    assert recent == ["abc", "abc two", "abc one"]


def test_sort_popular_and_recent(client):
    for t in ("a1", "b1", "c1"):
        upload(client, make_score(t, None))
    ids = {i["title"]: i["id"] for i in search(client)["items"]}
    assert titles(search(client, sort="recent")) == ["c1", "b1", "a1"]
    for _ in range(2):
        client.get(f"/api/v1/scores/{ids['a1']}")
    client.get(f"/api/v1/scores/{ids['b1']}")
    assert titles(search(client, sort="popular")) == ["a1", "b1", "c1"]


def test_pagination(client):
    for i in range(7):
        upload(client, make_score(f"song{i}", None))
    p1 = search(client, "", page=1, page_size=3)
    p2 = search(client, "", page=2, page_size=3)
    p3 = search(client, "", page=3, page_size=3)
    p4 = search(client, "", page=4, page_size=3)
    assert [p1["total"], p2["total"], p3["total"], p4["total"]] == [7] * 4
    assert (len(p1["items"]), len(p2["items"]), len(p3["items"]), len(p4["items"])) == (3, 3, 1, 0)
    all_titles = titles(p1) + titles(p2) + titles(p3)
    assert all_titles == [f"song{i}" for i in range(6, -1, -1)]
    assert (p2["page"], p2["page_size"]) == (2, 3)


def test_punctuation_only_query_is_treated_as_empty_and_wildcards_are_literal(client):
    upload(client, make_score("100% love", None))
    upload(client, make_score("other", None))
    assert search(client, "%!")["total"] == 2  # normalizes to empty -> no filter
    assert search(client, "1%0")["total"] == 1  # "10" matches only "100love" (literal, no LIKE semantics)
    assert titles(search(client, "o'th")) == ["other"]
