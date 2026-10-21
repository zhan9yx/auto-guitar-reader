from __future__ import annotations

import json
import re
import uuid

from conftest import make_score, page, search, upload

ISO_Z = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")
SUMMARY_KEYS = {"id", "title", "artist", "key", "mode", "uploader", "downloads", "created_at", "page_count"}


def test_healthz(client):
    r = client.get("/healthz")
    assert r.status_code == 200 and r.json() == {"status": "ok"}


def test_upload_returns_summary(client):
    r = upload(client, make_score(key="G"))
    assert r.status_code == 201, r.text
    body = r.json()
    assert set(body) == SUMMARY_KEYS
    assert uuid.UUID(body["id"])
    assert body["title"] == "七里香" and body["artist"] == "周杰伦" and body["key"] == "G"
    assert body["mode"] == "strumSing"
    assert body["uploader"] == "匿名"
    assert body["downloads"] == 0 and body["page_count"] == 0
    assert ISO_Z.match(body["created_at"])


def test_server_replaces_client_id_and_fetch_increments_downloads(client):
    score = make_score()
    sid = upload(client, score).json()["id"]
    assert sid != score["id"]
    r1 = client.get(f"/api/v1/scores/{sid}")
    assert r1.status_code == 200
    assert r1.headers["content-type"].startswith("application/json")
    stored = r1.json()
    assert stored["id"] == sid
    expected = dict(score, id=sid)
    assert stored == expected  # everything else preserved verbatim, incl. Chinese text
    client.get(f"/api/v1/scores/{sid}")
    items = search(client)["items"]
    assert items[0]["downloads"] == 2


def test_missing_score_404_with_detail(client):
    r = client.get(f"/api/v1/scores/{uuid.uuid4()}")
    assert r.status_code == 404 and isinstance(r.json()["detail"], str)
    assert client.get("/api/v1/scores/not-a-uuid").status_code == 404


def test_chinese_nickname_percent_encoded(client):
    r = upload(client, nickname="小明同学")
    assert r.json()["uploader"] == "小明同学"


def test_raw_utf8_nickname_header_tolerated(client):
    r = upload(client, headers={"X-Nickname": "小红".encode("utf-8")})
    assert r.json()["uploader"] == "小红"


def test_nickname_truncated_and_blank_is_anonymous(client):
    r = upload(client, nickname="x" * 100)
    assert len(r.json()["uploader"]) == 32
    r = upload(client, nickname="   ")
    assert r.json()["uploader"] == "匿名"


def test_upload_with_assets_and_fetch_asset(client):
    score = make_score(pages=[page("page-0.jpg"), page("page-1.png")])
    data0, data1 = b"\xff\xd8\xff-fake-jpeg", b"\x89PNG-fake"
    r = upload(client, score, assets=[("page-0.jpg", data0), ("page-1.png", data1)])
    assert r.status_code == 201, r.text
    body = r.json()
    assert body["page_count"] == 2
    a0 = client.get(f"/api/v1/scores/{body['id']}/assets/page-0.jpg")
    assert a0.status_code == 200 and a0.content == data0
    assert a0.headers["content-type"] == "image/jpeg"
    assert a0.headers["x-content-type-options"] == "nosniff"
    a1 = client.get(f"/api/v1/scores/{body['id']}/assets/page-1.png")
    assert a1.content == data1 and a1.headers["content-type"] == "image/png"
    assert client.get(f"/api/v1/scores/{body['id']}/assets/nope.jpg").status_code == 404


def test_asset_traversal_on_download(client):
    score = make_score(pages=[page("a.jpg")])
    sid = upload(client, score, assets=[("a.jpg", b"x")]).json()["id"]
    for bad in ("..%2F..%2Fcommunity.sqlite3", "%2e%2e", "a.jpg%00", ".hidden", "a b.jpg"):
        r = client.get(f"/api/v1/scores/{sid}/assets/{bad}")
        assert r.status_code in (404, 400), (bad, r.status_code)
    # asset of another score id is not reachable
    other = upload(client, make_score(title="other")).json()["id"]
    assert client.get(f"/api/v1/scores/{other}/assets/a.jpg").status_code == 404


def test_plain_form_field_score_is_accepted(client):
    payload = json.dumps(make_score(title="Plain"), ensure_ascii=False)
    r = client.post("/api/v1/scores", data={"score": payload}, headers={"X-Device-Id": "device-plain"})
    assert r.status_code == 201 and r.json()["title"] == "Plain"


def test_fingerstyle_mode_and_optional_fields(client):
    r = upload(client, make_score(title="Tab", artist=None, mode="fingerstyle"))
    body = r.json()
    assert body["mode"] == "fingerstyle" and body["artist"] is None and body["key"] is None


def test_data_persists_across_restart(make_client, tmp_path):
    c1 = make_client()
    sid = upload(c1).json()["id"]
    c2 = make_client()  # same data dir
    assert search(c2)["total"] == 1
    assert c2.get(f"/api/v1/scores/{sid}").status_code == 200
