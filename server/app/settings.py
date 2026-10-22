from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path


def _int_env(name: str, default: int) -> int:
    raw = os.environ.get(name)
    if raw is None or raw.strip() == "":
        return default
    try:
        value = int(raw)
    except ValueError as exc:
        raise ValueError(f"environment variable {name} must be an integer, got {raw!r}") from exc
    if value < 0:
        raise ValueError(f"environment variable {name} must be >= 0")
    return value


@dataclass(frozen=True)
class Settings:
    data_dir: Path = field(default_factory=lambda: Path("./data"))
    max_json_bytes: int = 2 * 1024 * 1024
    max_assets: int = 10
    max_asset_bytes: int = 5 * 1024 * 1024
    rate_limit_per_hour: int = 30
    max_avatar_bytes: int = 1024 * 1024
    profile_rate_limit_per_hour: int = 30
    # Optional fixed salt for hashing device ids (default: random, persisted in the DB).
    device_salt: str = ""

    @classmethod
    def from_env(cls) -> "Settings":
        return cls(
            data_dir=Path(os.environ.get("AGR_DATA_DIR", "./data")),
            max_json_bytes=_int_env("AGR_MAX_JSON_BYTES", 2 * 1024 * 1024),
            max_assets=_int_env("AGR_MAX_ASSETS", 10),
            max_asset_bytes=_int_env("AGR_MAX_ASSET_BYTES", 5 * 1024 * 1024),
            rate_limit_per_hour=_int_env("AGR_RATE_LIMIT_PER_HOUR", 30),
            max_avatar_bytes=_int_env("AGR_MAX_AVATAR_BYTES", 1024 * 1024),
            profile_rate_limit_per_hour=_int_env("AGR_PROFILE_RATE_LIMIT_PER_HOUR", 30),
            device_salt=os.environ.get("AGR_DEVICE_SALT", ""),
        )

    @property
    def db_path(self) -> Path:
        return self.data_dir / "community.sqlite3"

    @property
    def assets_dir(self) -> Path:
        return self.data_dir / "assets"

    @property
    def avatars_dir(self) -> Path:
        return self.data_dir / "avatars"
