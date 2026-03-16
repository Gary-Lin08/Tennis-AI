from __future__ import annotations

import os
from dataclasses import dataclass


def _env_bool(name: str, default: bool) -> bool:
    raw = os.getenv(name)
    if raw is None:
        return default
    value = raw.strip().lower()
    if value in {"1", "true", "t", "yes", "y", "on"}:
        return True
    if value in {"0", "false", "f", "no", "n", "off"}:
        return False
    return default


@dataclass(frozen=True)
class Settings:
    supabase_url: str
    supabase_service_role_key: str
    ingest_batch_size: int = 500
    admin_api_key: str = ""
    media_storage_mode: str = "local"
    media_root: str = "ai/backend/storage"
    media_videos_bucket: str = "analysis-videos"
    media_artifacts_bucket: str = "analysis-artifacts"
    phase1_root: str = "ai/phase1"
    phase1_python: str = ""
    phase1_tracknet_device: str = "auto"
    phase1_player_tracking_device: str = "cpu"
    phase1_keep_overlays: bool = False
    phase1_timeout_seconds: int = 1800
    phase1_allow_synthetic_fallback: bool = True

    @classmethod
    def from_env(cls) -> "Settings":
        supabase_url = os.getenv("SUPABASE_URL", "").strip()
        service_key = os.getenv("SUPABASE_SERVICE_ROLE_KEY", "").strip()

        if not supabase_url:
            raise RuntimeError("SUPABASE_URL is required")
        if not service_key:
            raise RuntimeError("SUPABASE_SERVICE_ROLE_KEY is required")

        raw_batch = os.getenv("INGEST_BATCH_SIZE", "500").strip()
        try:
            batch_size = max(1, int(raw_batch))
        except Exception as exc:
            raise RuntimeError("INGEST_BATCH_SIZE must be an integer") from exc

        raw_phase1_timeout = os.getenv("PHASE1_TIMEOUT_SECONDS", "1800").strip()
        try:
            phase1_timeout_seconds = max(60, int(raw_phase1_timeout))
        except Exception as exc:
            raise RuntimeError("PHASE1_TIMEOUT_SECONDS must be an integer") from exc

        return cls(
            supabase_url=supabase_url,
            supabase_service_role_key=service_key,
            ingest_batch_size=batch_size,
            admin_api_key=os.getenv("ADMIN_API_KEY", "").strip(),
            media_storage_mode=os.getenv("MEDIA_STORAGE_MODE", "local").strip().lower() or "local",
            media_root=os.getenv("MEDIA_ROOT", "ai/backend/storage").strip() or "ai/backend/storage",
            media_videos_bucket=os.getenv("MEDIA_VIDEOS_BUCKET", "analysis-videos").strip() or "analysis-videos",
            media_artifacts_bucket=os.getenv("MEDIA_ARTIFACTS_BUCKET", "analysis-artifacts").strip() or "analysis-artifacts",
            phase1_root=os.getenv("PHASE1_ROOT", "ai/phase1").strip() or "ai/phase1",
            phase1_python=os.getenv("PHASE1_PYTHON", "").strip(),
            phase1_tracknet_device=os.getenv("PHASE1_TRACKNET_DEVICE", "auto").strip() or "auto",
            phase1_player_tracking_device=os.getenv("PHASE1_PLAYER_TRACKING_DEVICE", "cpu").strip() or "cpu",
            phase1_keep_overlays=_env_bool("PHASE1_KEEP_OVERLAYS", False),
            phase1_timeout_seconds=phase1_timeout_seconds,
            phase1_allow_synthetic_fallback=_env_bool("PHASE1_ALLOW_SYNTHETIC_FALLBACK", True),
        )
