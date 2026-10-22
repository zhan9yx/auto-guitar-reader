# AGR Community Server

FastAPI + SQLite backend for the community tab of Auto Guitar Reader.
Scores (AGR JSON) live in SQLite, page images on disk. No accounts: an anonymous
device id plus a free-form nickname identify uploaders.

## Run locally

```bash
cd server
python3 -m venv .venv
.venv/bin/pip install -r requirements-dev.txt
AGR_DATA_DIR=./data .venv/bin/uvicorn app.main:app --host 127.0.0.1 --port 8000
```

Tests: `.venv/bin/python -m pytest`

## Docker

```bash
docker build -t agr-community server/
docker run -d -p 8000:8000 -v agr-data:/data agr-community
```

Put a TLS-terminating reverse proxy (with its own `client_max_body_size`, e.g. 60m) in front for production.
Run a single container/worker per data volume.

## Environment variables

| Variable | Default | Meaning |
|---|---|---|
| `AGR_DATA_DIR` | `./data` (`/data` in Docker) | SQLite DB (`community.sqlite3`) and `assets/<score_id>/<name>` |
| `AGR_MAX_JSON_BYTES` | `2097152` | max size of the score JSON part |
| `AGR_MAX_ASSETS` | `10` | max page images per upload |
| `AGR_MAX_ASSET_BYTES` | `5242880` | max size per image |
| `AGR_RATE_LIMIT_PER_HOUR` | `30` | successful uploads per device id per rolling hour |
| `AGR_PROFILE_RATE_LIMIT_PER_HOUR` | `30` | profile / avatar mutations per device per rolling hour (429 beyond) |
| `AGR_MAX_AVATAR_BYTES` | `1048576` | max uploaded avatar size (JPEG/PNG, stored under `avatars/`) |
| `AGR_DEVICE_SALT` | random, persisted in the DB | salt for hashing device ids; set only to share it across data dirs |

## API (`/api/v1`)

Errors are always `{"detail": "<message>"}` (400 validation, 404, 413 too large, 422 bad params, 429 rate limit).

| Endpoint | Notes |
|---|---|
| `POST /scores` | multipart: `score` (JSON file) + repeatable `assets` (files). Headers: `X-Device-Id` (required, `[A-Za-z0-9._:-]{1,128}`), `X-Nickname` (percent-encoded UTF-8, optional, max 32 chars, default `匿名`). Returns 201 + summary. |
| `GET /scores?q=&sort=recent\|popular&page=1&page_size=20` | `page_size` is clamped to 1..50, `page` to >= 1 |
| `GET /scores/{id}` | the stored AGR JSON (its `id` is the server id); increments `downloads` |
| `GET /scores/{id}/assets/{name}` | page image; `name` must match `[A-Za-z0-9._-]+` |
| `POST /scores/{id}/report` | `{"reason": "..."}`, header `X-Device-Id`; 3 reports from distinct devices hide the score |
| `GET /healthz` | `{"status":"ok"}` |

Summary object: `id, title, artist, key, mode, uploader, downloads, created_at (ISO-8601 UTC "…Z"), page_count, uploader_id, favorites, favorited_by_me` (`favorited_by_me` is only ever true when `X-Device-Id` was sent).
Search response: `items, total, page, page_size`.

### Profiles, favorites, my uploads
Identity stays anonymous: the device id is HMAC-hashed with a server salt before it is stored (users, scores, reports,
favorites) and never appears in a response. Every authenticated request (any endpoint that needs `X-Device-Id`) creates
the user on first sight. A user is published as a short random `user_id` (10 hex chars).

| Endpoint | Notes |
|---|---|
| `GET /me` | own profile: `user_id, nickname, bio, avatar_emoji, avatar_url, level, genres, created_at, updated_at, favorites_count, stats{uploads,downloads,favorites_received}` |
| `PUT /me` | JSON partial update (only sent keys change, `null` clears): `nickname` (1-24), `bio` (<=200), `avatar_emoji` (an emoji; replaces an uploaded image), `level` (`beginner\|intermediate\|advanced`), `genres` (<=5, each <=20 chars). 422 on invalid input |
| `PUT /me/avatar` | multipart field `avatar`: JPEG or PNG (sniffed from the bytes), <= 1 MB (413 beyond); replaces the emoji |
| `DELETE /me/avatar` | removes image and emoji |
| `GET /users/{user_id}` | public profile (no `updated_at` / `favorites_count`) + stats; stats count visible (not report-hidden) scores |
| `GET /users/{user_id}/scores?page=&page_size=` | their uploads, newest first (`{items,total,page,page_size}`) |
| `GET /users/{user_id}/avatar` | image bytes (`avatar_url` already points here with a cache-busting `?v=`) |
| `POST/DELETE /scores/{id}/favorite` | idempotent; returns `{"favorited": bool, "favorites": n}` |
| `GET /me/favorites?page=` | scores I favorited, most recently favorited first |
| `GET /me/scores?page=` | my uploads |
| `DELETE /scores/{id}` | uploader only (403 otherwise); removes the score, its images, favorites and reports |

Profile mutations are limited per device (`AGR_PROFILE_RATE_LIMIT_PER_HOUR`). Changing the nickname also renames the
`uploader` of that device's existing scores; once a profile nickname is set it wins over the legacy `X-Nickname` header.
Older databases are migrated on start: `scores.favorites` is added, stored raw device ids are hashed and users are
created for existing uploaders (one-off, tracked in `server_meta`).

### Upload rules
- `score` must be a JSON object: `meta.title` non-empty string (<= 200 chars), `sections` array,
  optional `meta.artist/key` strings, `meta.mode` in `strumSing|fingerstyle`, optional `format` == `agr-score`.
- The set of uploaded asset names must equal the set of `pages[].fileName` (every page needs its image, every image must be a page).
  Names: `[A-Za-z0-9._-]{1,100}`, not starting with `.`, extension one of jpg/jpeg/png/gif/webp/heic/heif.
- The client's `id` inside the JSON is replaced by a fresh server UUID.

### Search
Title and artist are normalized (NFKC, case-fold, whitespace and punctuation removed). A query matches when it is a
substring of normalized title/artist, of their toneless concatenated pinyin, or of their pinyin initials
(`qlx`, `qilixiang` -> 七里香; `zhoujielun` -> 周杰伦). Ranking: exact title, title prefix, title substring,
artist substring, pinyin match; ties follow `sort`.

### curl examples

```bash
H='X-Device-Id: my-device-0001'
curl -s -H "$H" -H "X-Nickname: $(python3 -c 'import urllib.parse;print(urllib.parse.quote("小明"))')" \
  -F 'score=@song.agr.json;type=application/json' \
  -F 'assets=@page-0.jpg;type=image/jpeg' \
  http://127.0.0.1:8000/api/v1/scores

curl -s 'http://127.0.0.1:8000/api/v1/scores?q=qlx&sort=popular&page=1&page_size=20'
curl -s http://127.0.0.1:8000/api/v1/scores/<id> -o downloaded.agr.json
curl -s http://127.0.0.1:8000/api/v1/scores/<id>/assets/page-0.jpg -o page-0.jpg
curl -s -X POST -H "$H" -H 'Content-Type: application/json' \
  -d '{"reason":"spam"}' http://127.0.0.1:8000/api/v1/scores/<id>/report
```

## Security notes
Device ids are self-asserted, so rate limiting and report de-duplication are best-effort anti-abuse, not authentication.
Add IP-level limits at the proxy for public deployments. Assets are served with a fixed image content type derived from the
extension and `X-Content-Type-Options: nosniff`.
