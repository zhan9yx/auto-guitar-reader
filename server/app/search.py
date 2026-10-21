"""Text normalization and pinyin helpers for community search."""
from __future__ import annotations

import unicodedata
from dataclasses import dataclass

try:  # degrade gracefully if pypinyin is unavailable
    from pypinyin import Style, lazy_pinyin

    HAVE_PYPINYIN = True
except Exception:  # pragma: no cover - exercised only without the dependency
    HAVE_PYPINYIN = False


def normalize(text: str | None) -> str:
    """NFKC, casefold, drop whitespace / punctuation / control characters.

    Full-width and half-width forms, case and spacing all collapse so that
    ``"Ｊａｙ Chou!"`` and ``"jaychou"`` compare equal.
    """
    if not text:
        return ""
    text = unicodedata.normalize("NFKC", text).casefold()
    text = unicodedata.normalize("NFKC", text)
    return "".join(
        ch for ch in text if unicodedata.category(ch)[0] not in ("Z", "C", "P")
    )


def _per_char(chunk: str) -> list[str]:
    return list(chunk)


def pinyin_full(text: str | None) -> str:
    """Toneless concatenated pinyin (non-Chinese characters kept), normalized."""
    if not text or not HAVE_PYPINYIN:
        return ""
    try:
        parts = lazy_pinyin(text, style=Style.NORMAL, errors=_per_char)
    except Exception:  # pragma: no cover
        return ""
    return normalize("".join(parts))


def pinyin_initials(text: str | None) -> str:
    """First letter of each character's pinyin (non-Chinese characters kept)."""
    if not text or not HAVE_PYPINYIN:
        return ""
    try:
        parts = lazy_pinyin(text, style=Style.FIRST_LETTER, errors=_per_char)
    except Exception:  # pragma: no cover
        return ""
    return normalize("".join(parts))


@dataclass(frozen=True)
class SearchKeys:
    n_title: str
    n_artist: str
    py_title: str
    py_artist: str
    in_title: str
    in_artist: str


def build_keys(title: str, artist: str | None) -> SearchKeys:
    return SearchKeys(
        n_title=normalize(title),
        n_artist=normalize(artist),
        py_title=pinyin_full(title),
        py_artist=pinyin_full(artist),
        in_title=pinyin_initials(title),
        in_artist=pinyin_initials(artist),
    )


# Rank tiers (lower is better).
RANK_EXACT_TITLE = 0
RANK_TITLE_PREFIX = 1
RANK_TITLE_SUBSTRING = 2
RANK_ARTIST_SUBSTRING = 3
RANK_PINYIN = 4


def build_search_sql(nq: str) -> tuple[str, str, dict]:
    """Return (where_clause, rank_expression, named_params).

    ``nq`` must already be normalized and non-empty. ``instr`` is used instead
    of LIKE so no wildcard escaping is needed.
    """
    where = (
        "(instr(n_title, :q) > 0 OR instr(n_artist, :q) > 0 "
        "OR instr(py_title, :q) > 0 OR instr(py_artist, :q) > 0 "
        "OR instr(in_title, :q) > 0 OR instr(in_artist, :q) > 0)"
    )
    rank = (
        "CASE "
        f"WHEN n_title = :q THEN {RANK_EXACT_TITLE} "
        f"WHEN substr(n_title, 1, :qlen) = :q THEN {RANK_TITLE_PREFIX} "
        f"WHEN instr(n_title, :q) > 0 THEN {RANK_TITLE_SUBSTRING} "
        f"WHEN instr(n_artist, :q) > 0 THEN {RANK_ARTIST_SUBSTRING} "
        f"ELSE {RANK_PINYIN} END"
    )
    return where, rank, {"q": nq, "qlen": len(nq)}
