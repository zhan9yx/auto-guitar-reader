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


class SearchResponse(BaseModel):
    items: list[ScoreSummary]
    total: int
    page: int
    page_size: int


class ReportBody(BaseModel):
    reason: str = Field(min_length=1, max_length=500)


class OkResponse(BaseModel):
    ok: bool = True
