"""Profile, avatar, favorites and "my uploads" endpoints."""
from __future__ import annotations

import json
import re
import shutil
from typing import Optional

from fastapi import FastAPI, Request
from fastapi.responses import FileResponse
from starlette.concurrency import run_in_threadpool
from starlette.datastructures import UploadFile
from starlette.exceptions import HTTPException

from . import db
from .models import (
    FavoriteState,
    MeProfile,
    OkResponse,
    ProfileStats,
    ProfileUpdate,
    PublicProfile,
    SearchResponse,
)
from .services import MAX_PROFILE_NICKNAME, Services, iso_utc
from .settings import Settings

API = "/api/v1"
MAX_BIO = 200
MAX_GENRES = 5
MAX_GENRE_LEN = 20
MAX_EMOJI_CHARS = 8
LEVELS = ("beginner", "intermediate", "advanced")
USER_ID_RE = re.compile(r"^[0-9a-f]{10}$")
SCORE_ID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
DEVICE_ID_RE = re.compile(r"^[A-Za-z0-9._:-]{1,128}$")

JPEG_MAGIC = b"\xff\xd8\xff"
PNG_MAGIC = b"\x89PNG\r\n\x1a\n"


def bad(detail: str, status: int = 400) -> HTTPException:
    return HTTPException(status_code=status, detail=detail)


def _clean_line(text: str) -> str:
    return "".join(ch for ch in text if ch.isprintable() or ch == " ").strip()


def validate_nickname(value) -> str:
    if not isinstance(value, str):
        raise bad("nickname must be a string", 422)
    name = _clean_line(value)
    if not name or len(name) > MAX_PROFILE_NICKNAME:
        raise bad(f"nickname must be 1-{MAX_PROFILE_NICKNAME} characters", 422)
    return name


def validate_bio(value) -> str:
    if value is None:
        return ""
    if not isinstance(value, str):
        raise bad("bio must be a string", 422)
    text = "".join(ch for ch in value if ch.isprintable() or ch in " \n").strip()
    if len(text) > MAX_BIO:
        raise bad(f"bio must be at most {MAX_BIO} characters", 422)
    return text


def validate_emoji(value) -> Optional[str]:
    if value is None:
        return None
    if not isinstance(value, str):
        raise bad("avatar_emoji must be a string", 422)
    text = value.strip()
    if not text:
        return None
    if len(text) > MAX_EMOJI_CHARS or any(ch.isascii() and ch.isalnum() for ch in text) or not text.isprintable():
        raise bad(f"avatar_emoji must be a single emoji (at most {MAX_EMOJI_CHARS} characters, no letters or digits)", 422)
    return text


def validate_level(value) -> Optional[str]:
    if value is None:
        return None
    if value not in LEVELS:
        raise bad("level must be one of: " + ", ".join(LEVELS), 422)
    return value


def validate_genres(value) -> list[str]:
    if value is None:
        return []
    if not isinstance(value, list) or not all(isinstance(g, str) for g in value):
        raise bad("genres must be a list of strings", 422)
    out: list[str] = []
    for g in value:
        g = _clean_line(g)
        if not g:
            continue
        if len(g) > MAX_GENRE_LEN:
            raise bad(f"each genre must be at most {MAX_GENRE_LEN} characters", 422)
        if g not in out:
            out.append(g)
    if len(out) > MAX_GENRES:
        raise bad(f"at most {MAX_GENRES} genres", 422)
    return out


def sniff_image(data: bytes) -> Optional[tuple[str, str]]:
    """(extension, content type) from magic bytes; never trusts client-provided names or types."""
    if data.startswith(JPEG_MAGIC):
        return ".jpg", "image/jpeg"
    if data.startswith(PNG_MAGIC):
        return ".png", "image/png"
    return None


def install(app: FastAPI, svc: Services, device_id_from, viewer_from) -> None:
    settings: Settings = svc.settings
    clock = svc.clock

    # ----- helpers -----------------------------------------------------------
    def authed(request: Request) -> str:
        """Hashed device id of the caller; creates the user row on first sight."""
        dhash = svc.dev(device_id_from(request))
        with db.connect(settings.db_path) as conn:
            svc.ensure_user(conn, dhash)
        return dhash

    def stats_for(conn, dhash: str) -> ProfileStats:
        row = conn.execute(
            "SELECT COUNT(*), COALESCE(SUM(downloads),0), COALESCE(SUM(favorites),0) "
            "FROM scores WHERE device_id=? AND hidden=0",
            (dhash,),
        ).fetchone()
        return ProfileStats(uploads=row[0], downloads=row[1], favorites_received=row[2])

    def public_fields(conn, u) -> dict:
        url = None
        if u["avatar_file"]:
            url = f"{API}/users/{u['user_id']}/avatar?v={int(u['avatar_ts'] or 0)}"
        return dict(
            user_id=u["user_id"],
            nickname=u["nickname"],
            bio=u["bio"],
            avatar_emoji=u["avatar_emoji"],
            avatar_url=url,
            level=u["level"],
            genres=json.loads(u["genres"] or "[]"),
            created_at=iso_utc(u["created_ts"]),
            stats=stats_for(conn, u["device_id"]),
        )

    def public_profile(conn, u) -> PublicProfile:
        return PublicProfile(**public_fields(conn, u))

    def me_profile(conn, u) -> MeProfile:
        n = conn.execute("SELECT COUNT(*) FROM favorites f JOIN scores s ON s.id=f.score_id "
                         "WHERE f.device_id=? AND s.hidden=0", (u["device_id"],)).fetchone()[0]
        return MeProfile(**public_fields(conn, u), updated_at=iso_utc(u["updated_ts"]), favorites_count=n)

    def take_profile_slot(conn, dhash: str) -> None:
        """Rate limit for profile mutations (call inside a write transaction)."""
        now = clock()
        conn.execute("DELETE FROM profile_events WHERE created_ts<?", (now - 3600,))
        n = conn.execute(
            "SELECT COUNT(*) FROM profile_events WHERE device_id=? AND created_ts>?", (dhash, now - 3600)
        ).fetchone()[0]
        if n >= settings.profile_rate_limit_per_hour:
            raise HTTPException(429, "profile update rate limit exceeded; try again later",
                                headers={"Retry-After": "3600"})
        conn.execute("INSERT INTO profile_events(device_id,created_ts) VALUES (?,?)", (dhash, now))

    def remove_avatar_files(user_id: str) -> None:
        for ext in (".jpg", ".png"):
            (settings.avatars_dir / f"{user_id}{ext}").unlink(missing_ok=True)

    def score_page(conn, where: str, params: list, order: str, page: int, page_size: int, viewer, join: str = ""):
        page, page_size = svc.paging(page, page_size)
        total = conn.execute(f"SELECT COUNT(*) FROM scores {join} WHERE {where}", params).fetchone()[0]
        rows = conn.execute(
            f"SELECT scores.* FROM scores {join} WHERE {where} ORDER BY {order} LIMIT ? OFFSET ?",
            [*params, page_size, (page - 1) * page_size],
        ).fetchall()
        return SearchResponse(items=svc.summaries(conn, rows, viewer), total=total, page=page, page_size=page_size)

    # ----- me ----------------------------------------------------------------
    @app.get(f"{API}/me", response_model=MeProfile)
    def get_me(request: Request):
        dhash = authed(request)
        with db.connect(settings.db_path) as conn:
            u = conn.execute("SELECT * FROM users WHERE device_id=?", (dhash,)).fetchone()
            return me_profile(conn, u)

    @app.put(f"{API}/me", response_model=MeProfile)
    def put_me(body: ProfileUpdate, request: Request):
        dhash = authed(request)
        sent = body.model_fields_set
        changes: dict = {}
        if "nickname" in sent:
            changes["nickname"] = validate_nickname(body.nickname)
            changes["nick_locked"] = 1
        if "bio" in sent:
            changes["bio"] = validate_bio(body.bio)
        if "level" in sent:
            changes["level"] = validate_level(body.level)
        if "genres" in sent:
            changes["genres"] = json.dumps(validate_genres(body.genres), ensure_ascii=False)
        emoji_change = "avatar_emoji" in sent
        if emoji_change:
            changes["avatar_emoji"] = validate_emoji(body.avatar_emoji)
        with db.connect(settings.db_path) as conn:
            with db.write_tx(conn):
                take_profile_slot(conn, dhash)
                u = conn.execute("SELECT * FROM users WHERE device_id=?", (dhash,)).fetchone()
                if emoji_change and changes["avatar_emoji"] is not None:
                    changes.update(avatar_file=None, avatar_ts=None)  # an emoji replaces an uploaded image
                elif emoji_change and u["avatar_file"]:
                    changes.pop("avatar_emoji")  # clearing the emoji must not touch an uploaded image
                if changes:
                    changes["updated_ts"] = clock()
                    sets = ", ".join(f"{k}=?" for k in changes)
                    conn.execute(f"UPDATE users SET {sets} WHERE device_id=?", [*changes.values(), dhash])
                    if "nickname" in changes:
                        conn.execute("UPDATE scores SET uploader=? WHERE device_id=?", (changes["nickname"], dhash))
                u = conn.execute("SELECT * FROM users WHERE device_id=?", (dhash,)).fetchone()
            if changes.get("avatar_file", "x") is None and u["avatar_file"] is None:
                remove_avatar_files(u["user_id"])
            return me_profile(conn, u)

    @app.put(f"{API}/me/avatar", response_model=MeProfile)
    async def put_avatar(request: Request):
        dhash = await run_in_threadpool(authed, request)
        limit = settings.max_avatar_bytes + 64 * 1024
        declared = request.headers.get("content-length")
        if declared and declared.isdigit() and int(declared) > limit:
            raise bad("avatar too large", 413)
        try:
            form = await request.form(max_files=2, max_fields=5)
        except HTTPException:
            raise
        except Exception:
            raise bad("malformed multipart body")
        try:
            part = form.get("avatar")
            if not isinstance(part, UploadFile):
                raise bad("multipart field 'avatar' (file) is required")
            data = await part.read(settings.max_avatar_bytes + 1)
        finally:
            await form.close()
        if len(data) > settings.max_avatar_bytes:
            raise bad(f"avatar exceeds {settings.max_avatar_bytes} bytes", 413)
        kind = sniff_image(data)
        if kind is None:
            raise bad("avatar must be a JPEG or PNG image")
        ext, _ = kind

        def store():
            with db.connect(settings.db_path) as conn:
                with db.write_tx(conn):
                    take_profile_slot(conn, dhash)
                    u = conn.execute("SELECT * FROM users WHERE device_id=?", (dhash,)).fetchone()
                    settings.avatars_dir.mkdir(parents=True, exist_ok=True)
                    remove_avatar_files(u["user_id"])
                    (settings.avatars_dir / f"{u['user_id']}{ext}").write_bytes(data)
                    now = clock()
                    conn.execute(
                        "UPDATE users SET avatar_file=?, avatar_ts=?, avatar_emoji=NULL, updated_ts=? WHERE device_id=?",
                        (f"{u['user_id']}{ext}", now, now, dhash),
                    )
                u = conn.execute("SELECT * FROM users WHERE device_id=?", (dhash,)).fetchone()
                return me_profile(conn, u)

        return await run_in_threadpool(store)

    @app.delete(f"{API}/me/avatar", response_model=MeProfile)
    def delete_avatar(request: Request):
        dhash = authed(request)
        with db.connect(settings.db_path) as conn:
            with db.write_tx(conn):
                take_profile_slot(conn, dhash)
                conn.execute(
                    "UPDATE users SET avatar_file=NULL, avatar_ts=NULL, avatar_emoji=NULL, updated_ts=? WHERE device_id=?",
                    (clock(), dhash),
                )
            u = conn.execute("SELECT * FROM users WHERE device_id=?", (dhash,)).fetchone()
            remove_avatar_files(u["user_id"])
            return me_profile(conn, u)

    @app.get(f"{API}/me/scores", response_model=SearchResponse)
    def my_scores(request: Request, page: int = 1, page_size: int = 20):
        dhash = authed(request)
        with db.connect(settings.db_path) as conn:
            return score_page(conn, "scores.device_id=? AND scores.hidden=0", [dhash],
                              "scores.created_ts DESC, scores.seq DESC", page, page_size, dhash)

    @app.get(f"{API}/me/favorites", response_model=SearchResponse)
    def my_favorites(request: Request, page: int = 1, page_size: int = 20):
        dhash = authed(request)
        with db.connect(settings.db_path) as conn:
            return score_page(conn, "f.device_id=? AND scores.hidden=0", [dhash],
                              "f.created_ts DESC, scores.seq DESC", page, page_size, dhash,
                              join="JOIN favorites f ON f.score_id=scores.id")

    # ----- other users -------------------------------------------------------
    def user_by_public_id(conn, user_id: str):
        if not USER_ID_RE.match(user_id):
            raise bad("user not found", 404)
        u = conn.execute("SELECT * FROM users WHERE user_id=?", (user_id,)).fetchone()
        if u is None:
            raise bad("user not found", 404)
        return u

    @app.get(f"{API}/users/{{user_id}}", response_model=PublicProfile)
    def get_user(user_id: str):
        with db.connect(settings.db_path) as conn:
            return public_profile(conn, user_by_public_id(conn, user_id))

    @app.get(f"{API}/users/{{user_id}}/scores", response_model=SearchResponse)
    def user_scores(user_id: str, request: Request, page: int = 1, page_size: int = 20):
        viewer = viewer_from(request)
        with db.connect(settings.db_path) as conn:
            u = user_by_public_id(conn, user_id)
            return score_page(conn, "scores.device_id=? AND scores.hidden=0", [u["device_id"]],
                              "scores.created_ts DESC, scores.seq DESC", page, page_size, viewer)

    @app.get(f"{API}/users/{{user_id}}/avatar")
    def user_avatar(user_id: str):
        with db.connect(settings.db_path) as conn:
            u = user_by_public_id(conn, user_id)
        name = u["avatar_file"]
        if not name or "/" in name or name.startswith("."):
            raise bad("avatar not found", 404)
        path = settings.avatars_dir / name
        if not path.is_file():
            raise bad("avatar not found", 404)
        ctype = "image/png" if name.endswith(".png") else "image/jpeg"
        return FileResponse(path, media_type=ctype,
                            headers={"X-Content-Type-Options": "nosniff", "Cache-Control": "public, max-age=86400"})

    # ----- favorites ---------------------------------------------------------
    def set_favorite(score_id: str, request: Request, on: bool) -> FavoriteState:
        dhash = authed(request)
        if not SCORE_ID_RE.match(score_id):
            raise bad("score not found", 404)
        with db.connect(settings.db_path) as conn:
            with db.write_tx(conn):
                if conn.execute("SELECT 1 FROM scores WHERE id=? AND hidden=0", (score_id,)).fetchone() is None:
                    raise bad("score not found", 404)
                if on:
                    conn.execute("INSERT OR IGNORE INTO favorites(score_id,device_id,created_ts) VALUES (?,?,?)",
                                 (score_id, dhash, clock()))
                else:
                    conn.execute("DELETE FROM favorites WHERE score_id=? AND device_id=?", (score_id, dhash))
                n = conn.execute("SELECT COUNT(*) FROM favorites WHERE score_id=?", (score_id,)).fetchone()[0]
                conn.execute("UPDATE scores SET favorites=? WHERE id=?", (n, score_id))
        return FavoriteState(favorited=on, favorites=n)

    @app.post(f"{API}/scores/{{score_id}}/favorite", response_model=FavoriteState)
    def favorite(score_id: str, request: Request):
        return set_favorite(score_id, request, True)

    @app.delete(f"{API}/scores/{{score_id}}/favorite", response_model=FavoriteState)
    def unfavorite(score_id: str, request: Request):
        return set_favorite(score_id, request, False)

    # ----- delete my score ---------------------------------------------------
    @app.delete(f"{API}/scores/{{score_id}}", response_model=OkResponse)
    def delete_score(score_id: str, request: Request):
        dhash = authed(request)
        if not SCORE_ID_RE.match(score_id):
            raise bad("score not found", 404)
        with db.connect(settings.db_path) as conn:
            with db.write_tx(conn):
                row = conn.execute("SELECT device_id FROM scores WHERE id=?", (score_id,)).fetchone()
                if row is None:
                    raise bad("score not found", 404)
                if row["device_id"] != dhash:
                    raise bad("only the uploader can delete this score", 403)
                for table in ("favorites", "assets", "reports"):
                    conn.execute(f"DELETE FROM {table} WHERE score_id=?", (score_id,))
                conn.execute("DELETE FROM scores WHERE id=?", (score_id,))
        shutil.rmtree(settings.assets_dir / score_id, ignore_errors=True)
        return OkResponse()
