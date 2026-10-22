"""SQLite helpers (stdlib sqlite3, WAL, one short-lived connection per call)."""
from __future__ import annotations

import hashlib
import hmac
import secrets
import sqlite3
from contextlib import contextmanager
from pathlib import Path
from typing import Iterator

SCHEMA = """
CREATE TABLE IF NOT EXISTS scores (
    seq          INTEGER PRIMARY KEY AUTOINCREMENT,
    id           TEXT NOT NULL UNIQUE,
    title        TEXT NOT NULL,
    artist       TEXT,
    key          TEXT,
    mode         TEXT NOT NULL,
    uploader     TEXT NOT NULL,
    device_id    TEXT NOT NULL,
    downloads    INTEGER NOT NULL DEFAULT 0,
    created_ts   REAL NOT NULL,
    page_count   INTEGER NOT NULL DEFAULT 0,
    json         TEXT NOT NULL,
    n_title      TEXT NOT NULL DEFAULT '',
    n_artist     TEXT NOT NULL DEFAULT '',
    py_title     TEXT NOT NULL DEFAULT '',
    py_artist    TEXT NOT NULL DEFAULT '',
    in_title     TEXT NOT NULL DEFAULT '',
    in_artist    TEXT NOT NULL DEFAULT '',
    hidden       INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_scores_device ON scores(device_id, created_ts);
CREATE INDEX IF NOT EXISTS idx_scores_recent ON scores(hidden, created_ts);
CREATE INDEX IF NOT EXISTS idx_scores_popular ON scores(hidden, downloads);
CREATE TABLE IF NOT EXISTS assets (
    score_id     TEXT NOT NULL REFERENCES scores(id),
    name         TEXT NOT NULL,
    size         INTEGER NOT NULL,
    content_type TEXT NOT NULL,
    PRIMARY KEY (score_id, name)
);
CREATE TABLE IF NOT EXISTS server_meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS users (
    device_id     TEXT PRIMARY KEY,          -- HMAC(salt, raw device id); the raw id is never stored
    user_id       TEXT NOT NULL UNIQUE,      -- public short random id
    nickname      TEXT NOT NULL,
    nick_locked   INTEGER NOT NULL DEFAULT 0, -- 1 once the user set a nickname via PUT /me
    bio           TEXT NOT NULL DEFAULT '',
    avatar_emoji  TEXT,
    avatar_file   TEXT,
    avatar_ts     REAL,
    level         TEXT,
    genres        TEXT NOT NULL DEFAULT '[]',
    created_ts    REAL NOT NULL,
    updated_ts    REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS favorites (
    score_id   TEXT NOT NULL REFERENCES scores(id) ON DELETE CASCADE,
    device_id  TEXT NOT NULL,
    created_ts REAL NOT NULL,
    PRIMARY KEY (score_id, device_id)
);
CREATE INDEX IF NOT EXISTS idx_favorites_device ON favorites(device_id, created_ts);
CREATE TABLE IF NOT EXISTS profile_events (
    device_id  TEXT NOT NULL,
    created_ts REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_profile_events ON profile_events(device_id, created_ts);
CREATE TABLE IF NOT EXISTS reports (
    score_id   TEXT NOT NULL REFERENCES scores(id),
    device_id  TEXT NOT NULL,
    reason     TEXT NOT NULL,
    created_ts REAL NOT NULL,
    PRIMARY KEY (score_id, device_id)
);
"""


def hash_device(salt: bytes, device_id: str) -> str:
    return hmac.new(salt, device_id.encode("utf-8"), hashlib.sha256).hexdigest()


def new_user_id() -> str:
    return secrets.token_hex(5)


def _columns(conn: sqlite3.Connection, table: str) -> set[str]:
    return {r[1] for r in conn.execute(f"PRAGMA table_info({table})")}


def init_db(path: Path, salt_override: str = "", now: float = 0.0) -> bytes:
    """Create / migrate the schema. Returns the salt used for hashing device ids."""
    path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(path, timeout=10, isolation_level=None)
    try:
        conn.execute("PRAGMA journal_mode=WAL")
        conn.executescript(SCHEMA)
        conn.execute("BEGIN IMMEDIATE")
        try:
            # --- additive column migrations (older databases) ---
            if "favorites" not in _columns(conn, "scores"):
                conn.execute("ALTER TABLE scores ADD COLUMN favorites INTEGER NOT NULL DEFAULT 0")

            # --- salt ---
            row = conn.execute("SELECT value FROM server_meta WHERE key='device_salt'").fetchone()
            if row is None:
                conn.execute("INSERT INTO server_meta(key,value) VALUES('device_salt',?)", (secrets.token_hex(32),))
                row = conn.execute("SELECT value FROM server_meta WHERE key='device_salt'").fetchone()
            salt = (salt_override or row[0]).encode("utf-8")

            # --- one-off: hash raw device ids stored by older versions, create users for old uploaders ---
            done = conn.execute("SELECT 1 FROM server_meta WHERE key='device_hashed'").fetchone()
            if done is None:
                for table in ("scores", "reports"):
                    ids = [r[0] for r in conn.execute(f"SELECT DISTINCT device_id FROM {table}")]
                    for raw in ids:
                        conn.execute(f"UPDATE {table} SET device_id=? WHERE device_id=?", (hash_device(salt, raw), raw))
                conn.execute("INSERT INTO server_meta(key,value) VALUES('device_hashed','1')")
                for r in conn.execute(
                    "SELECT device_id, uploader, MIN(created_ts) AS first_ts FROM scores GROUP BY device_id"
                ).fetchall():
                    exists = conn.execute("SELECT 1 FROM users WHERE device_id=?", (r[0],)).fetchone()
                    if exists is None:
                        conn.execute(
                            "INSERT INTO users(device_id,user_id,nickname,created_ts,updated_ts) VALUES (?,?,?,?,?)",
                            (r[0], _unique_user_id(conn), (r[1] or "匿名")[:24], r[2] or now, now or r[2]),
                        )
            conn.execute("COMMIT")
        except BaseException:
            conn.execute("ROLLBACK")
            raise
    finally:
        conn.close()
    return salt


def _unique_user_id(conn: sqlite3.Connection) -> str:
    while True:
        uid = new_user_id()
        if conn.execute("SELECT 1 FROM users WHERE user_id=?", (uid,)).fetchone() is None:
            return uid


@contextmanager
def connect(path: Path) -> Iterator[sqlite3.Connection]:
    """Autocommit connection; use ``BEGIN IMMEDIATE`` explicitly for write blocks."""
    conn = sqlite3.connect(path, timeout=10, isolation_level=None)
    conn.row_factory = sqlite3.Row
    try:
        conn.execute("PRAGMA foreign_keys=ON")
        conn.execute("PRAGMA synchronous=NORMAL")
        yield conn
    finally:
        conn.close()


@contextmanager
def write_tx(conn: sqlite3.Connection) -> Iterator[sqlite3.Connection]:
    conn.execute("BEGIN IMMEDIATE")
    try:
        yield conn
    except BaseException:
        conn.execute("ROLLBACK")
        raise
    else:
        conn.execute("COMMIT")
