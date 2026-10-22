from __future__ import annotations

import json
import os
import re
import sqlite3
import uuid
from pathlib import Path

from conftest import make_score, page, search, upload

JPEG = b"\xff\xd8\xff\xe0" + b"\x00" * 64
PNG = b"\x89PNG\r\n\x1a\n" + b"\x00" * 64
USER_ID = re.compile(r"^[0-9a-f]{10}$")


def H(device="dev-aaaa-0001"):
    return {"X-Device-Id": device}


def me(client, device="dev-aaaa-0001"):
    r = client.get("/api/v1/me", headers=H(device))
    assert r.status_code == 200, r.text
    return r.json()


def put_me(client, body, device="dev-aaaa-0001"):
    return client.put("/api/v1/me", json=body, headers=H(device))


def avatar(client, data, name="a.jpg", device="dev-aaaa-0001"):
    return client.put("/api/v1/me/avatar", files={"avatar": (name, data, "image/jpeg")}, headers=H(device))


def capture(name: str, payload) -> None:
    """With AGR_CAPTURE_DIR set, store real server JSON for the Swift decoding tests."""
    target = os.environ.get("AGR_CAPTURE_DIR")
    if target:
        Path(target).mkdir(parents=True, exist_ok=True)
        (Path(target) / f"{name}.json").write_text(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True))


# --------------------------------------------------------------------------- #
def test_me_requires_device_id(client):
    assert client.get("/api/v1/me").status_code == 400
    assert client.put("/api/v1/me", json={}).status_code == 400


def test_me_auto_creates_profile_with_defaults(client):
    body = me(client)
    capture("me_default", body)
    assert USER_ID.match(body["user_id"])
    assert body["nickname"] == "匿名" and body["bio"] == "" and body["genres"] == []
    assert body["level"] is None and body["avatar_emoji"] is None and body["avatar_url"] is None
    assert body["stats"] == {"uploads": 0, "downloads": 0, "favorites_received": 0}
    assert body["favorites_count"] == 0
    assert me(client)["user_id"] == body["user_id"]  # stable
    assert me(client, "other-device-2")["user_id"] != body["user_id"]


def test_raw_device_id_is_never_stored_or_echoed(client, tmp_path):
    device = "very-secret-device-id-123"
    upload(client, device=device)
    body = me(client, device)
    assert device not in json.dumps(body)
    conn = sqlite3.connect(tmp_path / "data" / "community.sqlite3")
    dump = "\n".join(conn.iterdump())
    conn.close()
    assert device not in dump
    for item in search(client)["items"]:
        assert device not in json.dumps(item)


def test_update_profile_roundtrip(client):
    r = put_me(client, {"nickname": "小明", "bio": "爱弹吉他\n每天一小时", "level": "intermediate",
                        "genres": ["民谣", "流行", "民谣"], "avatar_emoji": "🎸"})
    assert r.status_code == 200, r.text
    body = r.json()
    capture("me_full", body)
    assert body["nickname"] == "小明" and body["bio"] == "爱弹吉他\n每天一小时"
    assert body["level"] == "intermediate" and body["genres"] == ["民谣", "流行"]
    assert body["avatar_emoji"] == "🎸"
    assert me(client) == body


def test_partial_update_keeps_other_fields_and_null_clears(client):
    put_me(client, {"nickname": "A", "bio": "hi", "level": "beginner", "genres": ["rock"]})
    r = put_me(client, {"bio": "changed"}).json()
    assert r["nickname"] == "A" and r["level"] == "beginner" and r["genres"] == ["rock"] and r["bio"] == "changed"
    r = put_me(client, {"level": None, "genres": None}).json()
    assert r["level"] is None and r["genres"] == []
    assert put_me(client, {}).status_code == 200


def test_profile_validation(client):
    bad_bodies = [
        {"nickname": ""},
        {"nickname": "   "},
        {"nickname": "x" * 25},
        {"nickname": None},
        {"bio": "x" * 201},
        {"level": "godlike"},
        {"genres": ["a", "b", "c", "d", "e", "f"]},
        {"genres": ["x" * 21]},
        {"genres": "rock"},
        {"avatar_emoji": "abc"},
        {"avatar_emoji": "🎸" * 9},
        {"nickname": 5},
    ]
    for body in bad_bodies:
        r = put_me(client, body)
        assert r.status_code == 422, (body, r.status_code, r.text)
        assert isinstance(r.json()["detail"], str)
    ok = put_me(client, {"nickname": "x" * 24, "bio": "y" * 200, "genres": ["a", "b", "c", "d", "e"]})
    assert ok.status_code == 200


def test_nickname_change_updates_existing_scores_and_new_uploads(client):
    upload(client, nickname="旧名字", device="dev-aaaa-0001")
    put_me(client, {"nickname": "新名字"})
    assert search(client)["items"][0]["uploader"] == "新名字"
    # the profile nickname wins over a stale X-Nickname header
    r = upload(client, make_score("again", None), nickname="旧名字", device="dev-aaaa-0001")
    assert r.json()["uploader"] == "新名字"


def test_upload_auto_creates_user_and_summary_has_uploader_id(client):
    r = upload(client, device="dev-up-1", nickname="小红")
    uid = r.json()["uploader_id"]
    assert USER_ID.match(uid)
    profile = client.get(f"/api/v1/users/{uid}").json()
    assert profile["nickname"] == "小红"
    assert me(client, "dev-up-1")["user_id"] == uid


def test_public_profile_hides_private_fields(client):
    upload(client, device="dev-pub-1")
    uid = me(client, "dev-pub-1")["user_id"]
    pub = client.get(f"/api/v1/users/{uid}").json()
    capture("public_profile", pub)
    assert "updated_at" not in pub and "favorites_count" not in pub and "device_id" not in pub
    assert pub["stats"]["uploads"] == 1


def test_user_not_found(client):
    assert client.get("/api/v1/users/0123456789").status_code == 404
    assert client.get("/api/v1/users/nope").status_code == 404
    assert client.get("/api/v1/users/0123456789/scores").status_code == 404
    assert client.get("/api/v1/users/0123456789/avatar").status_code == 404


def test_user_scores_listing_and_paging(client):
    for i in range(3):
        upload(client, make_score(f"S{i}", None), device="dev-lister")
    upload(client, make_score("other", None), device="dev-other")
    uid = me(client, "dev-lister")["user_id"]
    r = client.get(f"/api/v1/users/{uid}/scores", params={"page": 1, "page_size": 2}).json()
    capture("user_scores", r)
    assert r["total"] == 3 and [i["title"] for i in r["items"]] == ["S2", "S1"]
    r2 = client.get(f"/api/v1/users/{uid}/scores", params={"page": 2, "page_size": 2}).json()
    assert [i["title"] for i in r2["items"]] == ["S0"]


def test_stats_count_uploads_downloads_and_favorites(client):
    sid1 = upload(client, make_score("A", None), device="dev-owner").json()["id"]
    sid2 = upload(client, make_score("B", None), device="dev-owner").json()["id"]
    for _ in range(3):
        client.get(f"/api/v1/scores/{sid1}")
    client.get(f"/api/v1/scores/{sid2}")
    client.post(f"/api/v1/scores/{sid1}/favorite", headers=H("fan-1"))
    client.post(f"/api/v1/scores/{sid2}/favorite", headers=H("fan-1"))
    client.post(f"/api/v1/scores/{sid1}/favorite", headers=H("fan-2"))
    stats = me(client, "dev-owner")["stats"]
    assert stats == {"uploads": 2, "downloads": 4, "favorites_received": 3}


def test_avatar_upload_serve_and_delete(client):
    r = avatar(client, JPEG)
    assert r.status_code == 200, r.text
    body = r.json()
    capture("me_avatar", body)
    assert body["avatar_url"].startswith(f"/api/v1/users/{body['user_id']}/avatar?v=")
    assert body["avatar_emoji"] is None
    got = client.get(body["avatar_url"])
    assert got.status_code == 200 and got.content == JPEG
    assert got.headers["content-type"] == "image/jpeg" and got.headers["x-content-type-options"] == "nosniff"
    # PNG replaces JPEG
    body = avatar(client, PNG, name="b.png").json()
    got = client.get(body["avatar_url"])
    assert got.content == PNG and got.headers["content-type"] == "image/png"
    d = client.delete("/api/v1/me/avatar", headers=H())
    assert d.status_code == 200 and d.json()["avatar_url"] is None
    assert client.get(f"/api/v1/users/{body['user_id']}/avatar").status_code == 404


def test_avatar_validation(client, make_client):
    assert avatar(client, b"GIF89a-not-allowed").status_code == 400
    assert avatar(client, b"").status_code == 400
    # a lying client: .jpg name and image/jpeg type but HTML content
    assert avatar(client, b"<html><script>alert(1)</script></html>").status_code == 400
    assert client.put("/api/v1/me/avatar", data={"nope": "x"}, headers=H()).status_code in (400, 422)
    big = JPEG + b"\x00" * (1024 * 1024)
    r = avatar(client, big)
    assert r.status_code == 413
    assert avatar(client, JPEG + b"\x00" * (1024 * 1024 - len(JPEG))).status_code == 200  # exactly 1 MB


def test_emoji_and_image_avatars_replace_each_other(client):
    avatar(client, JPEG)
    r = put_me(client, {"avatar_emoji": "🎵"}).json()
    assert r["avatar_emoji"] == "🎵" and r["avatar_url"] is None
    r = avatar(client, PNG, name="x.png").json()
    assert r["avatar_emoji"] is None and r["avatar_url"] is not None
    # clearing the emoji leaves the uploaded image alone
    r = put_me(client, {"avatar_emoji": None}).json()
    assert r["avatar_url"] is not None


def test_profile_update_rate_limit(make_client):
    c = make_client(profile_rate_limit_per_hour=3)
    for i in range(3):
        assert put_me(c, {"bio": str(i)}).status_code == 200
    r = put_me(c, {"bio": "too many"})
    assert r.status_code == 429 and r.headers["retry-after"] == "3600"
    assert avatar(c, JPEG).status_code == 429
    assert c.delete("/api/v1/me/avatar", headers=H()).status_code == 429
    assert put_me(c, {"bio": "x"}, device="someone-else-1").status_code == 200
    assert c.get("/api/v1/me", headers=H()).status_code == 200  # reads are not limited


def test_profile_rate_limit_window_expires(make_client, clock):
    c = make_client(profile_rate_limit_per_hour=1)
    assert put_me(c, {"bio": "a"}).status_code == 200
    assert put_me(c, {"bio": "b"}).status_code == 429
    clock.advance(3601)
    assert put_me(c, {"bio": "c"}).status_code == 200


# ----- favorites ------------------------------------------------------------
def test_favorite_flow_and_idempotence(client):
    sid = upload(client, device="dev-owner").json()["id"]
    r = client.post(f"/api/v1/scores/{sid}/favorite", headers=H("fan-1"))
    assert r.status_code == 200 and r.json() == {"favorited": True, "favorites": 1}
    capture("favorite_state", r.json())
    assert client.post(f"/api/v1/scores/{sid}/favorite", headers=H("fan-1")).json()["favorites"] == 1
    assert client.post(f"/api/v1/scores/{sid}/favorite", headers=H("fan-2")).json()["favorites"] == 2
    d = client.delete(f"/api/v1/scores/{sid}/favorite", headers=H("fan-1"))
    assert d.json() == {"favorited": False, "favorites": 1}
    assert client.delete(f"/api/v1/scores/{sid}/favorite", headers=H("fan-1")).json()["favorites"] == 1


def test_favorite_errors(client):
    sid = upload(client).json()["id"]
    assert client.post(f"/api/v1/scores/{sid}/favorite").status_code == 400
    assert client.post(f"/api/v1/scores/{uuid.uuid4()}/favorite", headers=H()).status_code == 404
    assert client.post("/api/v1/scores/not-a-uuid/favorite", headers=H()).status_code == 404
    assert client.delete(f"/api/v1/scores/{uuid.uuid4()}/favorite", headers=H()).status_code == 404


def test_summaries_carry_favorites_and_favorited_by_me(client):
    sid = upload(client, make_score("Fav", None), device="dev-owner").json()["id"]
    upload(client, make_score("Not", None), device="dev-owner")
    client.post(f"/api/v1/scores/{sid}/favorite", headers=H("fan-1"))
    anon = client.get("/api/v1/scores").json()["items"]
    assert {i["title"]: (i["favorites"], i["favorited_by_me"]) for i in anon} == {"Fav": (1, False), "Not": (0, False)}
    mine = client.get("/api/v1/scores", headers=H("fan-1")).json()
    capture("search_with_viewer", mine)
    assert {i["title"]: i["favorited_by_me"] for i in mine["items"]} == {"Fav": True, "Not": False}
    other = client.get("/api/v1/scores", headers=H("fan-2")).json()["items"]
    assert not any(i["favorited_by_me"] for i in other)


def test_my_favorites_listing_order_and_paging(client, clock):
    ids = [upload(client, make_score(f"T{i}", None), device="dev-owner").json()["id"] for i in range(3)]
    for sid in (ids[0], ids[2], ids[1]):
        clock.advance(1)
        client.post(f"/api/v1/scores/{sid}/favorite", headers=H("fan-1"))
    r = client.get("/api/v1/me/favorites", headers=H("fan-1")).json()
    capture("my_favorites", r)
    assert [i["title"] for i in r["items"]] == ["T1", "T2", "T0"] and r["total"] == 3
    assert all(i["favorited_by_me"] for i in r["items"])
    r2 = client.get("/api/v1/me/favorites", params={"page": 2, "page_size": 2}, headers=H("fan-1")).json()
    assert [i["title"] for i in r2["items"]] == ["T0"]
    assert me(client, "fan-1")["favorites_count"] == 3
    assert client.get("/api/v1/me/favorites", headers=H("nobody-1")).json()["total"] == 0
    assert client.get("/api/v1/me/favorites").status_code == 400


def test_hidden_scores_leave_favorites_and_stats(client):
    sid = upload(client, device="dev-owner").json()["id"]
    client.post(f"/api/v1/scores/{sid}/favorite", headers=H("fan-1"))
    for d in ("r1", "r2", "r3"):
        client.post(f"/api/v1/scores/{sid}/report", json={"reason": "x"}, headers=H(d))
    assert client.get("/api/v1/me/favorites", headers=H("fan-1")).json()["total"] == 0
    assert me(client, "dev-owner")["stats"]["uploads"] == 0
    assert client.post(f"/api/v1/scores/{sid}/favorite", headers=H("fan-2")).status_code == 404


# ----- my uploads -----------------------------------------------------------
def test_my_scores_lists_only_mine(client):
    upload(client, make_score("mine1", None), device="dev-me-1")
    upload(client, make_score("mine2", None), device="dev-me-1")
    upload(client, make_score("theirs", None), device="dev-they")
    r = client.get("/api/v1/me/scores", headers=H("dev-me-1")).json()
    capture("my_scores", r)
    assert [i["title"] for i in r["items"]] == ["mine2", "mine1"]


def test_delete_own_score_removes_everything(client, tmp_path):
    score = make_score(pages=[page("a.jpg")])
    sid = upload(client, score, assets=[("a.jpg", b"x")], device="dev-owner").json()["id"]
    client.post(f"/api/v1/scores/{sid}/favorite", headers=H("fan-1"))
    assert (tmp_path / "data" / "assets" / sid / "a.jpg").exists()
    r = client.delete(f"/api/v1/scores/{sid}", headers=H("dev-owner"))
    assert r.status_code == 200 and r.json() == {"ok": True}
    assert client.get(f"/api/v1/scores/{sid}").status_code == 404
    assert client.get(f"/api/v1/scores/{sid}/assets/a.jpg").status_code == 404
    assert not (tmp_path / "data" / "assets" / sid).exists()
    assert search(client)["total"] == 0
    assert client.get("/api/v1/me/favorites", headers=H("fan-1")).json()["total"] == 0
    assert client.delete(f"/api/v1/scores/{sid}", headers=H("dev-owner")).status_code == 404


def test_delete_requires_ownership(client):
    sid = upload(client, device="dev-owner").json()["id"]
    assert client.delete(f"/api/v1/scores/{sid}", headers=H("dev-intruder")).status_code == 403
    assert client.delete(f"/api/v1/scores/{sid}").status_code == 400
    assert search(client)["total"] == 1


# ----- migration ------------------------------------------------------------
OLD_SCHEMA = """
CREATE TABLE scores (seq INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL UNIQUE, title TEXT NOT NULL,
 artist TEXT, key TEXT, mode TEXT NOT NULL, uploader TEXT NOT NULL, device_id TEXT NOT NULL,
 downloads INTEGER NOT NULL DEFAULT 0, created_ts REAL NOT NULL, page_count INTEGER NOT NULL DEFAULT 0,
 json TEXT NOT NULL, n_title TEXT NOT NULL DEFAULT '', n_artist TEXT NOT NULL DEFAULT '',
 py_title TEXT NOT NULL DEFAULT '', py_artist TEXT NOT NULL DEFAULT '', in_title TEXT NOT NULL DEFAULT '',
 in_artist TEXT NOT NULL DEFAULT '', hidden INTEGER NOT NULL DEFAULT 0);
CREATE TABLE assets (score_id TEXT NOT NULL REFERENCES scores(id), name TEXT NOT NULL, size INTEGER NOT NULL,
 content_type TEXT NOT NULL, PRIMARY KEY (score_id, name));
CREATE TABLE reports (score_id TEXT NOT NULL REFERENCES scores(id), device_id TEXT NOT NULL, reason TEXT NOT NULL,
 created_ts REAL NOT NULL, PRIMARY KEY (score_id, device_id));
"""


def test_old_database_is_migrated_in_place(make_client, tmp_path, clock):
    data = tmp_path / "data"
    data.mkdir()
    sid = str(uuid.uuid4())
    conn = sqlite3.connect(data / "community.sqlite3")
    conn.executescript(OLD_SCHEMA)
    doc = json.dumps(make_score("旧曲", None))
    conn.execute(
        "INSERT INTO scores (id,title,artist,key,mode,uploader,device_id,downloads,created_ts,page_count,json) "
        "VALUES (?,?,?,?,?,?,?,?,?,?,?)",
        (sid, "旧曲", None, None, "strumSing", "老用户", "legacy-device-1", 7, clock() - 100, 0, doc),
    )
    conn.execute("INSERT INTO reports VALUES (?,?,?,?)", (sid, "legacy-reporter", "spam", clock()))
    conn.commit()
    conn.close()

    c = make_client()
    items = search(c)["items"]
    assert len(items) == 1 and items[0]["downloads"] == 7 and items[0]["favorites"] == 0
    uid = items[0]["uploader_id"]
    assert USER_ID.match(uid)
    assert c.get(f"/api/v1/users/{uid}").json()["nickname"] == "老用户"
    # the legacy device still owns its score through the hashed id
    assert me(c, "legacy-device-1")["user_id"] == uid
    assert me(c, "legacy-device-1")["stats"]["uploads"] == 1
    raw = sqlite3.connect(data / "community.sqlite3")
    stored = {r[0] for r in raw.execute("SELECT device_id FROM scores UNION SELECT device_id FROM reports")}
    raw.close()
    assert "legacy-device-1" not in stored and "legacy-reporter" not in stored
    # restart: migration is idempotent
    c2 = make_client()
    assert search(c2)["items"][0]["uploader_id"] == uid
    assert c2.delete(f"/api/v1/scores/{sid}", headers=H("legacy-device-1")).status_code == 200
