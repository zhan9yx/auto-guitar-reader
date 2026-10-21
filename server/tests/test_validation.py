from __future__ import annotations

import json

import pytest
from conftest import make_score, page, search, upload


def detail(r):
    body = r.json()
    assert set(body) == {"detail"} and isinstance(body["detail"], str)
    return body["detail"]


def test_missing_device_id(client):
    r = upload(client, device=None)
    assert r.status_code == 400 and "X-Device-Id" in detail(r)


@pytest.mark.parametrize("bad", ["a b", "x" * 129, "dev/ice", "设备"])
def test_invalid_device_id(client, bad):
    # httpx only allows latin-1 header values; non-ASCII ids still must be rejected.
    r = upload(client, device=bad.encode("utf-8") if bad == "设备" else bad)
    assert r.status_code == 400


def test_missing_score_part(client):
    r = client.post("/api/v1/scores", files=[("other", ("x.json", b"{}", "application/json"))],
                    headers={"X-Device-Id": "device-1"})
    assert r.status_code == 400 and "score" in detail(r)


def test_not_multipart(client):
    r = client.post("/api/v1/scores", json={"a": 1}, headers={"X-Device-Id": "device-1"})
    assert r.status_code == 400


@pytest.mark.parametrize(
    "raw",
    [b"not json", b"\xff\xfe\x00bad", b"[]", b'"str"', b"null", b""],
)
def test_bad_json(client, raw):
    r = upload(client, raw_score=raw)
    assert r.status_code == 400, r.text
    detail(r)


def test_missing_or_blank_title(client):
    for doc in (
        {"meta": {}, "sections": []},
        {"meta": {"title": ""}, "sections": []},
        {"meta": {"title": "   "}, "sections": []},
        {"meta": {"title": 5}, "sections": []},
        {"sections": []},
    ):
        r = upload(client, doc)
        assert r.status_code == 400, doc
        assert "title" in detail(r) or "meta" in detail(r)


def test_sections_must_be_array(client):
    assert upload(client, {"meta": {"title": "x"}}).status_code == 400
    assert upload(client, {"meta": {"title": "x"}, "sections": {}}).status_code == 400


def test_minimal_score_accepted(client):
    assert upload(client, {"meta": {"title": "x"}, "sections": []}).status_code == 201


def test_bad_mode_format_and_lengths(client):
    assert upload(client, make_score(mode="banjo")).status_code == 400
    assert upload(client, dict(make_score(), format="other")).status_code == 400
    assert upload(client, make_score(title="t" * 201)).status_code == 400
    assert upload(client, make_score(artist=123)).status_code == 400


def test_oversize_json(make_client):
    c = make_client(max_json_bytes=500)
    big = make_score(title="big")
    big["sections"][0]["lines"][0]["segments"][0]["text"] = "x" * 1000
    r = upload(c, big)
    assert r.status_code == 413
    detail(r)
    assert search(c)["total"] == 0


def test_too_many_assets(make_client):
    c = make_client(max_assets=3)
    names = [f"p{i}.jpg" for i in range(4)]
    score = make_score(pages=[page(n) for n in names])
    r = upload(c, score, assets=[(n, b"x") for n in names])
    assert r.status_code == 400 and "too many" in detail(r)
    names = names[:3]
    ok = upload(c, make_score(pages=[page(n) for n in names]), assets=[(n, b"x") for n in names])
    assert ok.status_code == 201


def test_oversize_asset(make_client):
    c = make_client(max_asset_bytes=100)
    r = upload(c, make_score(pages=[page("a.jpg")]), assets=[("a.jpg", b"x" * 101)])
    assert r.status_code == 413
    assert search(c)["total"] == 0


@pytest.mark.parametrize(
    "name",
    ["../evil.jpg", "a/b.jpg", "..\\evil.jpg", ".hidden.jpg", "..", "x.html", "noext", "a b.jpg", "é.jpg", "x" * 120 + ".jpg"],
)
def test_bad_asset_names_rejected(client, name):
    r = upload(client, make_score(pages=[page(name)]), assets=[(name, b"data")])
    assert r.status_code == 400, (name, r.text)
    assert search(client)["total"] == 0


def test_asset_must_be_referenced_by_pages(client):
    r = upload(client, make_score(pages=[page("a.jpg")]), assets=[("a.jpg", b"x"), ("b.jpg", b"x")])
    assert r.status_code == 400 and "b.jpg" in detail(r)
    r = upload(client, make_score(), assets=[("a.jpg", b"x")])
    assert r.status_code == 400


def test_page_must_have_asset(client):
    r = upload(client, make_score(pages=[page("a.jpg")]), assets=[])
    assert r.status_code == 400 and "a.jpg" in detail(r)


def test_duplicate_and_empty_assets(client):
    sc = make_score(pages=[page("a.jpg")])
    assert upload(client, sc, assets=[("a.jpg", b"x"), ("a.jpg", b"y")]).status_code == 400
    assert upload(client, sc, assets=[("a.jpg", b"")]).status_code == 400


def test_failed_upload_leaves_no_files(client, tmp_path):
    upload(client, make_score(pages=[page("a.jpg")]), assets=[("b.jpg", b"x")])
    assets_dir = tmp_path / "data" / "assets"
    assert list(assets_dir.iterdir()) == []


def test_page_size_and_page_clamped(client):
    for i in range(3):
        upload(client, make_score(title=f"t{i}"))
    r = client.get("/api/v1/scores", params={"page_size": 500, "page": 0})
    assert r.status_code == 200
    assert r.json()["page_size"] == 50 and r.json()["page"] == 1
    r = client.get("/api/v1/scores", params={"page_size": "abc"})
    assert r.status_code == 422 and isinstance(r.json()["detail"], str)
    assert client.get("/api/v1/scores", params={"sort": "random"}).status_code == 400
