from __future__ import annotations

from conftest import make_score, search, upload


def report(client, sid, device="rep-1", reason="spam"):
    headers = {"X-Device-Id": device} if device else {}
    return client.post(f"/api/v1/scores/{sid}/report", json={"reason": reason}, headers=headers)


def test_three_distinct_reports_hide_score(client):
    sid = upload(client, make_score("bad", None)).json()["id"]
    upload(client, make_score("good", None))
    assert report(client, sid, "d1").status_code == 200
    assert report(client, sid, "d2").status_code == 200
    assert search(client, "bad")["total"] == 1
    assert report(client, sid, "d3").json() == {"ok": True}
    assert search(client, "bad")["total"] == 0
    assert search(client)["total"] == 1
    assert client.get(f"/api/v1/scores/{sid}").status_code == 404


def test_hidden_score_assets_unavailable(client):
    from conftest import page
    sid = upload(client, make_score(pages=[page("a.jpg")]), assets=[("a.jpg", b"x")]).json()["id"]
    for d in ("d1", "d2", "d3"):
        report(client, sid, d)
    assert client.get(f"/api/v1/scores/{sid}/assets/a.jpg").status_code == 404


def test_duplicate_reports_from_same_device_count_once(client):
    sid = upload(client).json()["id"]
    for _ in range(5):
        assert report(client, sid, "same").status_code == 200
    assert search(client)["total"] == 1


def test_report_errors(client):
    sid = upload(client).json()["id"]
    assert report(client, sid, device=None).status_code == 400
    assert report(client, sid, reason="").status_code == 422
    assert report(client, sid, reason="x" * 501).status_code == 422
    assert client.post(f"/api/v1/scores/{sid}/report", json={}, headers={"X-Device-Id": "d"}).status_code == 422
    r = report(client, "00000000-0000-4000-8000-000000000000")
    assert r.status_code == 404 and isinstance(r.json()["detail"], str)
    assert report(client, "garbage").status_code == 404


def test_rate_limit_per_device(make_client):
    c = make_client(rate_limit_per_hour=3)
    for i in range(3):
        assert upload(c, make_score(f"s{i}", None), device="dev-A").status_code == 201
    r = upload(c, make_score("s4", None), device="dev-A")
    assert r.status_code == 429 and "detail" in r.json() and "retry-after" in r.headers
    assert upload(c, make_score("other", None), device="dev-B").status_code == 201
    assert search(c)["total"] == 4


def test_rate_limit_window_expires(make_client, clock):
    c = make_client(rate_limit_per_hour=1)
    assert upload(c, device="dev-A").status_code == 201
    assert upload(c, device="dev-A").status_code == 429
    clock.advance(3601)
    assert upload(c, device="dev-A").status_code == 201


def test_rejected_uploads_do_not_consume_rate_limit(make_client):
    c = make_client(rate_limit_per_hour=2)
    for _ in range(5):
        assert upload(c, raw_score=b"nope", device="dev-A").status_code == 400
    assert upload(c, device="dev-A").status_code == 201
    assert upload(c, device="dev-A").status_code == 201


def test_unknown_route_error_shape(client):
    r = client.get("/api/v1/nothing")
    assert r.status_code == 404 and r.json() == {"detail": "Not Found"}
