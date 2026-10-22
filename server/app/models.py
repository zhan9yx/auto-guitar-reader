from __future__ import annotations

from typing import Literal, Optional

from pydantic import BaseModel, Field


class ScoreSummary(BaseModel):
    id: str
    title: str
    artist: Optional[str] = None
    key: Optional[str] = None
    mode: Literal["strumSing", "fingerstyle"] = "strumSing"
    uploader: str
    downloads: int
    created_at: str  # ISO-8601 UTC, e.g. 2026-10-21T08:30:00Z
    page_count: int
    uploader_id: Optional[str] = None  # public user id of the uploader (see /users/{user_id})
    favorites: int = 0
    favorited_by_me: bool = False  # only meaningful when X-Device-Id was sent


class SearchResponse(BaseModel):
    items: list[ScoreSummary]
    total: int
    page: int
    page_size: int


class ReportBody(BaseModel):
    reason: str = Field(min_length=1, max_length=500)


class OkResponse(BaseModel):
    ok: bool = True


Level = Literal["beginner", "intermediate", "advanced"]


class ProfileStats(BaseModel):
    uploads: int
    downloads: int  # total downloads of this user's visible scores
    favorites_received: int


class PublicProfile(BaseModel):
    user_id: str
    nickname: str
    bio: str
    avatar_emoji: Optional[str] = None
    avatar_url: Optional[str] = None  # relative to the server root, e.g. /api/v1/users/<id>/avatar?v=123
    level: Optional[Level] = None
    genres: list[str]
    created_at: str
    stats: ProfileStats


class MeProfile(PublicProfile):
    updated_at: str
    favorites_count: int  # how many scores I favorited


class ProfileUpdate(BaseModel):
    """Partial update: only fields present in the JSON body are changed; ``null`` clears optional ones."""

    nickname: Optional[str] = None
    bio: Optional[str] = None
    avatar_emoji: Optional[str] = None
    level: Optional[str] = None
    genres: Optional[list[str]] = None


class FavoriteState(BaseModel):
    favorited: bool
    favorites: int
