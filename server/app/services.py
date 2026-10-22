"""Shared helpers: device-id hashing, user rows, score summaries."""
from __future__ import annotations

import sqlite3
from datetime import datetime, timezone
from typing import Callable, Optional

from . import db
from .models import ScoreSummary
from .settings import Settings

MAX_PAGE_SIZE = 50
MAX_PROFILE_NICKNAME = 24


def iso_utc(ts: float) -> str:
    return datetime.fromtimestamp(ts, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


class Services:
    def __init__(self, settings: Settings, clock: Callable[[], float], salt: bytes):
        self.settings = settings
        self.clock = clock
        self.salt = salt

    # ----- identity ----------------------------------------------------------
    def dev(self, raw_device_id: str) -> str:
        """Hashed device id: the only form that is ever stored."""
        return db.hash_device(self.salt, raw_device_id)

    def ensure_user(self, conn: sqlite3.Connection, dhash: str, nickname: Optional[str] = None) -> sqlite3.Row:
        """Return the user row for ``dhash``, creating it on first sight. Safe inside or outside a transaction."""
        row = conn.execute("SELECT * FROM users WHERE device_id=?", (dhash,)).fetchone()
        if row is not None:
            return row
        now = self.clock()
        name = (nickname or "匿名")[:MAX_PROFILE_NICKNAME].strip() or "匿名"
        while True:
            cur = conn.execute(
                "INSERT OR IGNORE INTO users(device_id,user_id,nickname,created_ts,updated_ts) VALUES (?,?,?,?,?)",
                (dhash, db.new_user_id(), name, now, now),
            )
            if cur.rowcount == 1:
                break
            if conn.execute("SELECT 1 FROM users WHERE device_id=?", (dhash,)).fetchone() is not None:
                break  # created concurrently
            # else: public id collision, retry with a new one
        return conn.execute("SELECT * FROM users WHERE device_id=?", (dhash,)).fetchone()

    # ----- summaries ---------------------------------------------------------
    def summaries(self, conn: sqlite3.Connection, rows: list, viewer: Optional[str]) -> list[ScoreSummary]:
        if not rows:
            return []
        owners = sorted({r["device_id"] for r in rows})
        ph = ",".join("?" * len(owners))
        uid = {
            r["device_id"]: r["user_id"]
            for r in conn.execute(f"SELECT device_id,user_id FROM users WHERE device_id IN ({ph})", owners)
        }
        faved: set[str] = set()
        if viewer:
            ids = [r["id"] for r in rows]
            ph = ",".join("?" * len(ids))
            faved = {
                r[0]
                for r in conn.execute(
                    f"SELECT score_id FROM favorites WHERE device_id=? AND score_id IN ({ph})", [viewer, *ids]
                )
            }
        return [
            ScoreSummary(
                id=r["id"],
                title=r["title"],
                artist=r["artist"],
                key=r["key"],
                mode=r["mode"],
                uploader=r["uploader"],
                downloads=r["downloads"],
                created_at=iso_utc(r["created_ts"]),
                page_count=r["page_count"],
                uploader_id=uid.get(r["device_id"]),
                favorites=r["favorites"],
                favorited_by_me=r["id"] in faved,
            )
            for r in rows
        ]

    @staticmethod
    def paging(page: int, page_size: int) -> tuple[int, int]:
        return max(1, page), max(1, min(page_size, MAX_PAGE_SIZE))
