from __future__ import annotations

import json
import sys
from pathlib import Path
from urllib.parse import quote

import pytest
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.main import create_app  # noqa: E402
from app.settings import Settings  # noqa: E402


class Clock:
    def __init__(self, now: float = 1_800_000_000.0):
        self.now = now

    def __call__(self) -> float:
        return self.now

    def advance(self, seconds: float) -> None:
        self.now += seconds


@pytest.fixture
def clock() -> Clock:
    return Clock()


@pytest.fixture
def make_client(tmp_path, clock):
    clients = []

    def factory(**overrides) -> TestClient:
        settings = Settings(data_dir=tmp_path / "data", **overrides)
        client = TestClient(create_app(settings, clock=clock))
        clients.append(client)
        return client

    yield factory
    for c in clients:
        c.close()


@pytest.fixture
def client(make_client) -> TestClient:
    return make_client()


def make_score(title="七里香", artist="周杰伦", pages=None, **meta_extra) -> dict:
    meta = {"title": title, "capo": 0, "tempo": 80, "mode": "strumSing", **meta_extra}
    if artist is not None:
        meta["artist"] = artist
    return {
        "format": "agr-score",
        "version": 1,
        "id": "11111111-2222-3333-4444-555555555555",
        "meta": meta,
        "sections": [
            {
                "id": "v1",
                "name": "主歌",
                "kind": "verse",
                "lines": [
                    {"id": "l1", "kind": "lyrics", "segments": [{"chord": "G", "text": "窗外的麻雀"}]}
                ],
            }
        ],
        "pages": pages or [],
    }


def page(name: str) -> dict:
    return {"fileName": name, "width": 100, "height": 200}


def upload(
    client,
    score=None,
    assets=None,
    device="device-0001",
    nickname=None,
    raw_score: bytes | None = None,
    headers=None,
):
    """POST /api/v1/scores. ``assets`` is a list of (name, bytes) tuples."""
    if raw_score is None:
        raw_score = json.dumps(score if score is not None else make_score(), ensure_ascii=False).encode()
    files = [("score", ("score.json", raw_score, "application/json"))]
    for name, data in assets or []:
        files.append(("assets", (name, data, "image/jpeg")))
    h = {}
    if device is not None:
        h["X-Device-Id"] = device
    if nickname is not None:
        h["X-Nickname"] = quote(nickname, safe="")
    h.update(headers or {})
    return client.post("/api/v1/scores", files=files, headers=h)


def search(client, q="", **params):
    r = client.get("/api/v1/scores", params={"q": q, **params})
    assert r.status_code == 200, r.text
    return r.json()


def titles(resp) -> list[str]:
    return [i["title"] for i in resp["items"]]
