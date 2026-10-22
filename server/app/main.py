"""Auto Guitar Reader community API (FastAPI + SQLite)."""
from __future__ import annotations

import json
import re
import shutil
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, Optional
from urllib.parse import unquote

from fastapi import FastAPI, Query, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import FileResponse, JSONResponse, Response
from starlette.concurrency import run_in_threadpool
from starlette.datastructures import UploadFile
from starlette.exceptions import HTTPException

from . import db, profiles
from .models import OkResponse, ReportBody, ScoreSummary, SearchResponse
from .search import build_keys, build_search_sql, normalize
from .services import Services
from .settings import Settings

API = "/api/v1"
ANON = "匿名"
REPORT_HIDE_THRESHOLD = 3
MAX_PAGE_SIZE = 50
MAX_TEXT = 200  # title / artist / key length limit
MAX_NICKNAME = 32
MAX_QUERY = 100

DEVICE_ID_RE = re.compile(r"^[A-Za-z0-9._:-]{1,128}$")
ASSET_NAME_RE = re.compile(r"^[A-Za-z0-9._-]{1,100}$")
SCORE_ID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
VALID_MODES = ("strumSing", "fingerstyle")

# Only raster images are accepted as score pages; content type is derived from
# the extension (never from the client) and served with nosniff.
ASSET_CONTENT_TYPES = {
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".png": "image/png",
    ".gif": "image/gif",
    ".webp": "image/webp",
    ".heic": "image/heic",
    ".heif": "image/heif",
}


class RateLimited(Exception):
    pass


def iso_utc(ts: float) -> str:
    return datetime.fromtimestamp(ts, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def bad(detail: str, status: int = 400) -> HTTPException:
    return HTTPException(status_code=status, detail=detail)


# --------------------------------------------------------------------------- #
# request helpers
# --------------------------------------------------------------------------- #
def device_id_from(request: Request) -> str:
    value = request.headers.get("x-device-id")
    if value is None or not value.strip():
        raise bad("X-Device-Id header is required")
    value = value.strip()
    if not DEVICE_ID_RE.match(value):
        raise bad("X-Device-Id must be 1-128 characters of [A-Za-z0-9._:-]")
    return value


def viewer_from(request: Request) -> Optional[str]:
    """Raw device id if the (optional) header is present, else None."""
    if request.headers.get("x-device-id") is None:
        return None
    return device_id_from(request)


def nickname_from(request: Request) -> str:
    raw = request.headers.get("x-nickname")
    if raw is None:
        return ANON
    # Starlette decodes header bytes as latin-1; recover raw UTF-8 senders.
    try:
        raw = raw.encode("latin-1").decode("utf-8")
    except (UnicodeEncodeError, UnicodeDecodeError):
        pass
    name = unquote(raw, encoding="utf-8", errors="replace")
    name = "".join(ch for ch in name if ch.isprintable() or ch == " ").strip()
    name = name[:MAX_NICKNAME].strip()
    return name or ANON


# --------------------------------------------------------------------------- #
# score validation
# --------------------------------------------------------------------------- #
def _opt_text(meta: dict, key: str) -> Optional[str]:
    value = meta.get(key)
    if value is None:
        return None
    if not isinstance(value, str):
        raise bad(f"meta.{key} must be a string")
    value = value.strip()
    if len(value) > MAX_TEXT:
        raise bad(f"meta.{key} is too long (max {MAX_TEXT} characters)")
    return value or None


def validate_score(raw: bytes) -> dict:
    try:
        doc = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, ValueError, RecursionError):
        raise bad("score is not valid UTF-8 JSON")
    if not isinstance(doc, dict):
        raise bad("score must be a JSON object")
    fmt = doc.get("format")
    if fmt is not None and fmt != "agr-score":
        raise bad("score.format must be 'agr-score'")
    meta = doc.get("meta")
    if not isinstance(meta, dict):
        raise bad("score.meta must be an object")
    title = meta.get("title")
    if not isinstance(title, str) or not title.strip():
        raise bad("meta.title must be a non-empty string")
    if len(title.strip()) > MAX_TEXT:
        raise bad(f"meta.title is too long (max {MAX_TEXT} characters)")
    if not isinstance(doc.get("sections"), list):
        raise bad("score.sections must be an array")
    mode = meta.get("mode")
    if mode is not None and mode not in VALID_MODES:
        raise bad("meta.mode must be 'strumSing' or 'fingerstyle'")
    _opt_text(meta, "artist")
    _opt_text(meta, "key")
    pages = doc.get("pages")
    if pages is not None:
        if not isinstance(pages, list):
            raise bad("score.pages must be an array")
        for i, page in enumerate(pages):
            if not isinstance(page, dict) or not isinstance(page.get("fileName"), str):
                raise bad(f"pages[{i}].fileName must be a string")
    return doc


def validate_asset_name(name: Optional[str]) -> str:
    if not name or not ASSET_NAME_RE.match(name) or name.startswith("."):
        raise bad("invalid asset name (allowed: letters, digits, '.', '_', '-')")
    ext = Path(name).suffix.lower()
    if ext not in ASSET_CONTENT_TYPES:
        raise bad(f"unsupported asset type {ext or '(none)'}; allowed: " + ", ".join(sorted(ASSET_CONTENT_TYPES)))
    return name


# --------------------------------------------------------------------------- #
# app factory
# --------------------------------------------------------------------------- #
def create_app(settings: Optional[Settings] = None, clock: Callable[[], float] = time.time) -> FastAPI:
    settings = settings or Settings.from_env()
    settings.data_dir.mkdir(parents=True, exist_ok=True)
    settings.assets_dir.mkdir(parents=True, exist_ok=True)
    settings.avatars_dir.mkdir(parents=True, exist_ok=True)
    salt = db.init_db(settings.db_path, settings.device_salt, clock())
    svc = Services(settings, clock, salt)

    app = FastAPI(title="Auto Guitar Reader Community", version="1.0.0")
    app.state.settings = settings

    # ----- error shape: always {"detail": "<string>"} ------------------------
    @app.exception_handler(RequestValidationError)
    async def _validation_error(_: Request, exc: RequestValidationError):
        errs = exc.errors()
        if errs:
            first = errs[0]
            loc = ".".join(str(p) for p in first.get("loc", []) if p != "body")
            detail = f"{loc}: {first.get('msg')}" if loc else str(first.get("msg"))
        else:
            detail = "invalid request"
        return JSONResponse(status_code=422, content={"detail": detail})

    # ----- helpers bound to settings ----------------------------------------
    def recent_uploads(conn, device_id: str) -> int:
        since = clock() - 3600
        return conn.execute(
            "SELECT COUNT(*) FROM scores WHERE device_id=? AND created_ts>?", (device_id, since)
        ).fetchone()[0]

    def check_rate(device_id: str) -> None:
        with db.connect(settings.db_path) as conn:
            if recent_uploads(conn, device_id) >= settings.rate_limit_per_hour:
                raise RateLimited

    def store_score(device_id: str, nickname: Optional[str], doc: dict, assets: dict[str, bytes]) -> ScoreSummary:
        sid = str(uuid.uuid4())
        doc["id"] = sid
        meta = doc["meta"]
        title = meta["title"].strip()
        artist = _opt_text(meta, "artist")
        key = _opt_text(meta, "key")
        mode = meta.get("mode") or "strumSing"
        page_count = len(doc.get("pages") or [])
        text = json.dumps(doc, ensure_ascii=False, separators=(",", ":"))
        keys = build_keys(title, artist)
        now = clock()

        asset_dir = settings.assets_dir / sid
        try:
            if assets:
                asset_dir.mkdir(parents=True)
                for name, data in assets.items():
                    (asset_dir / name).write_bytes(data)
            with db.connect(settings.db_path) as conn:
                with db.write_tx(conn):
                    if recent_uploads(conn, device_id) >= settings.rate_limit_per_hour:
                        raise RateLimited
                    user = svc.ensure_user(conn, device_id, nickname)
                    if user["nick_locked"]:
                        nickname = user["nickname"]  # profile nickname wins over the legacy header
                    else:
                        nickname = nickname or user["nickname"]
                        if nickname != user["nickname"]:
                            conn.execute("UPDATE users SET nickname=?, updated_ts=? WHERE device_id=?",
                                         (nickname[:24], now, device_id))
                    conn.execute(
                        "INSERT INTO scores (id,title,artist,key,mode,uploader,device_id,downloads,created_ts,"
                        "page_count,json,n_title,n_artist,py_title,py_artist,in_title,in_artist) "
                        "VALUES (?,?,?,?,?,?,?,0,?,?,?,?,?,?,?,?,?)",
                        (sid, title, artist, key, mode, nickname, device_id, now, page_count, text,
                         keys.n_title, keys.n_artist, keys.py_title, keys.py_artist, keys.in_title, keys.in_artist),
                    )
                    for name, data in assets.items():
                        conn.execute(
                            "INSERT INTO assets (score_id,name,size,content_type) VALUES (?,?,?,?)",
                            (sid, name, len(data), ASSET_CONTENT_TYPES[Path(name).suffix.lower()]),
                        )
                row = conn.execute("SELECT * FROM scores WHERE id=?", (sid,)).fetchone()
                return svc.summaries(conn, [row], None)[0]
        except BaseException:
            shutil.rmtree(asset_dir, ignore_errors=True)
            raise

    # ----- endpoints ---------------------------------------------------------
    @app.get("/healthz")
    def healthz():
        return {"status": "ok"}

    @app.post(f"{API}/scores", response_model=ScoreSummary, status_code=201)
    async def upload_score(request: Request):
        device_id = svc.dev(device_id_from(request))
        nickname = nickname_from(request)

        # Cheap early rejection of obviously oversized bodies (chunked uploads
        # are still bounded per-part below; use a reverse proxy limit in prod).
        limit = settings.max_json_bytes + settings.max_assets * settings.max_asset_bytes + 1024 * 1024
        declared = request.headers.get("content-length")
        if declared and declared.isdigit() and int(declared) > limit:
            raise bad("request body too large", 413)

        try:
            await run_in_threadpool(check_rate, device_id)
        except RateLimited:
            raise HTTPException(429, "upload rate limit exceeded; try again later", headers={"Retry-After": "3600"})

        try:
            form = await request.form(max_files=settings.max_assets + 2, max_fields=20)
        except HTTPException:
            raise
        except Exception:
            raise bad("malformed multipart body")
        try:
            score_part = form.get("score")
            if score_part is None:
                raise bad("multipart field 'score' is required")
            if isinstance(score_part, UploadFile):
                score_raw = await score_part.read(settings.max_json_bytes + 1)
            else:
                score_raw = str(score_part).encode("utf-8")
            if len(score_raw) > settings.max_json_bytes:
                raise bad(f"score JSON exceeds {settings.max_json_bytes} bytes", 413)

            parts = form.getlist("assets")
            if len(parts) > settings.max_assets:
                raise bad(f"too many assets (max {settings.max_assets})")
            assets: dict[str, bytes] = {}
            for part in parts:
                if not isinstance(part, UploadFile):
                    raise bad("'assets' parts must be file uploads")
                name = validate_asset_name(part.filename)
                if name in assets:
                    raise bad(f"duplicate asset name {name!r}")
                data = await part.read(settings.max_asset_bytes + 1)
                if len(data) > settings.max_asset_bytes:
                    raise bad(f"asset {name!r} exceeds {settings.max_asset_bytes} bytes", 413)
                if not data:
                    raise bad(f"asset {name!r} is empty")
                assets[name] = data

            doc = validate_score(score_raw)
            referenced = {p["fileName"] for p in (doc.get("pages") or [])}
            missing = sorted(referenced - assets.keys())
            if missing:
                raise bad(f"pages reference assets that were not uploaded: {', '.join(missing)}")
            unreferenced = sorted(assets.keys() - referenced)
            if unreferenced:
                raise bad(f"assets not referenced by pages[].fileName: {', '.join(unreferenced)}")
        finally:
            await form.close()

        try:
            return await run_in_threadpool(store_score, device_id, nickname, doc, assets)
        except RateLimited:
            raise HTTPException(429, "upload rate limit exceeded; try again later", headers={"Retry-After": "3600"})

    @app.get(f"{API}/scores", response_model=SearchResponse)
    def search_scores(
        request: Request,
        q: str = "",
        sort: str = "recent",
        page: int = 1,
        page_size: int = 20,
    ):
        viewer = viewer_from(request)
        viewer = svc.dev(viewer) if viewer else None
        if sort not in ("recent", "popular"):
            raise bad("sort must be 'recent' or 'popular'")
        page = max(1, page)
        page_size = max(1, min(page_size, MAX_PAGE_SIZE))
        nq = normalize(q[:MAX_QUERY])
        order = "downloads DESC, created_ts DESC, seq DESC" if sort == "popular" else "created_ts DESC, seq DESC"

        params: dict = {}
        where = "hidden = 0"
        rank = "0"
        if nq:
            w, rank, params = build_search_sql(nq)
            where += " AND " + w
        with db.connect(settings.db_path) as conn:
            total = conn.execute(f"SELECT COUNT(*) FROM scores WHERE {where}", params).fetchone()[0]
            rows = conn.execute(
                f"SELECT *, {rank} AS rank FROM scores WHERE {where} ORDER BY rank ASC, {order} LIMIT :limit OFFSET :offset",
                {**params, "limit": page_size, "offset": (page - 1) * page_size},
            ).fetchall()
            items = svc.summaries(conn, rows, viewer)
        return SearchResponse(items=items, total=total, page=page, page_size=page_size)

    @app.get(f"{API}/scores/{{score_id}}")
    def get_score(score_id: str):
        if not SCORE_ID_RE.match(score_id):
            raise bad("score not found", 404)
        with db.connect(settings.db_path) as conn:
            with db.write_tx(conn):
                row = conn.execute("SELECT json FROM scores WHERE id=? AND hidden=0", (score_id,)).fetchone()
                if row is None:
                    raise bad("score not found", 404)
                conn.execute("UPDATE scores SET downloads = downloads + 1 WHERE id=?", (score_id,))
        return Response(content=row["json"], media_type="application/json")

    @app.get(f"{API}/scores/{{score_id}}/assets/{{name}}")
    def get_asset(score_id: str, name: str):
        if not SCORE_ID_RE.match(score_id) or not ASSET_NAME_RE.match(name) or name.startswith("."):
            raise bad("asset not found", 404)
        with db.connect(settings.db_path) as conn:
            row = conn.execute(
                "SELECT a.content_type FROM assets a JOIN scores s ON s.id=a.score_id "
                "WHERE a.score_id=? AND a.name=? AND s.hidden=0",
                (score_id, name),
            ).fetchone()
        if row is None:
            raise bad("asset not found", 404)
        path = settings.assets_dir / score_id / name
        if not path.is_file():
            raise bad("asset not found", 404)
        return FileResponse(
            path,
            media_type=row["content_type"],
            headers={"X-Content-Type-Options": "nosniff", "Cache-Control": "public, max-age=86400"},
        )

    @app.post(f"{API}/scores/{{score_id}}/report", response_model=OkResponse)
    def report_score(score_id: str, body: ReportBody, request: Request):
        device_id = svc.dev(device_id_from(request))
        reason = body.reason.strip()
        if not reason:
            raise bad("reason must not be empty", 422)
        if not SCORE_ID_RE.match(score_id):
            raise bad("score not found", 404)
        with db.connect(settings.db_path) as conn:
            with db.write_tx(conn):
                if conn.execute("SELECT 1 FROM scores WHERE id=?", (score_id,)).fetchone() is None:
                    raise bad("score not found", 404)
                conn.execute(
                    "INSERT OR IGNORE INTO reports (score_id,device_id,reason,created_ts) VALUES (?,?,?,?)",
                    (score_id, device_id, reason, clock()),
                )
                n = conn.execute(
                    "SELECT COUNT(DISTINCT device_id) FROM reports WHERE score_id=?", (score_id,)
                ).fetchone()[0]
                if n >= REPORT_HIDE_THRESHOLD:
                    conn.execute("UPDATE scores SET hidden=1 WHERE id=?", (score_id,))
        return OkResponse()

    profiles.install(app, svc, device_id_from, lambda r: (lambda v: svc.dev(v) if v else None)(viewer_from(r)))

    return app


_default_app: Optional[FastAPI] = None


def __getattr__(name: str):
    """Lazily build ``app`` from the environment so `uvicorn app.main:app` works
    without creating data directories merely by importing this module."""
    global _default_app
    if name == "app":
        if _default_app is None:
            _default_app = create_app()
        return _default_app
    raise AttributeError(name)
