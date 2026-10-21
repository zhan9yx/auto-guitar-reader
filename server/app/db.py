"""SQLite helpers (stdlib sqlite3, WAL, one short-lived connection per call)."""
from __future__ import annotations

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
CREATE TABLE IF NOT EXISTS reports (
    score_id   TEXT NOT NULL REFERENCES scores(id),
    device_id  TEXT NOT NULL,
    reason     TEXT NOT NULL,
    created_ts REAL NOT NULL,
    PRIMARY KEY (score_id, device_id)
);
"""


def init_db(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(path, timeout=10)
    try:
        conn.execute("PRAGMA journal_mode=WAL")
        conn.executescript(SCHEMA)
        conn.commit()
    finally:
        conn.close()


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
