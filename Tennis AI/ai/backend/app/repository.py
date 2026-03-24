from __future__ import annotations

from collections import Counter
from datetime import datetime, timezone
from datetime import timedelta
import json
from pathlib import Path
from typing import Any
from uuid import UUID

from supabase import Client, create_client

from .config import Settings
from .models import SessionUploadRequest, TelemetryEventsRequest

SESSION_FIELDS = {
    "source_video_path",
    "generated_at_utc",
    "fps",
    "total_frames",
    "width_px",
    "height_px",
    "duration_sec",
    "court_width_m",
    "court_length_m",
    "first_server_side",
    "current_server_side",
    "final_sets_near",
    "final_sets_far",
    "final_games_near",
    "final_games_far",
    "final_points_near",
    "final_points_far",
    "num_rallies",
    "num_shots",
    "num_bounces",
    "num_points_scored",
    "num_points_pending",
}

RALLY_FIELDS = {
    "rally_id",
    "start_frame",
    "end_frame",
    "start_sec",
    "end_sec",
    "duration_sec",
    "num_frames",
    "num_shots",
    "near_shots",
    "far_shots",
    "unassigned_shots",
    "winner_side",
    "winner_source",
    "point_status",
    "server_side_before",
    "server_side_after",
    "before_score",
    "after_score",
    "game_won_by",
    "set_won_by",
    "tie_break_before",
    "tie_break_after",
    "tb_points_before_near",
    "tb_points_before_far",
    "tb_points_after_near",
    "tb_points_after_far",
}

SHOT_FIELDS = {
    "shot_id",
    "rally_id",
    "frame_num",
    "time_sec",
    "x_px",
    "y_px",
    "x_m",
    "y_m",
    "hitter_side",
    "hitter_track_id",
    "assign_distance_px",
    "side_matched",
    "shot_type",
    "speed_kmh",
    "confidence",
}

BOUNCE_FIELDS = {
    "bounce_id",
    "rally_id",
    "frame_num",
    "time_sec",
    "x_px",
    "y_px",
    "x_m",
    "y_m",
    "in_court",
    "confidence",
    "detection_method",
}


RALLY_BOOL_FIELDS = {"tie_break_before", "tie_break_after"}
SHOT_BOOL_FIELDS = {"side_matched"}
BOUNCE_BOOL_FIELDS = {"in_court"}


def _chunked(items: list[dict[str, Any]], batch_size: int) -> list[list[dict[str, Any]]]:
    if not items:
        return []
    return [items[i : i + batch_size] for i in range(0, len(items), batch_size)]


def _to_bool_or_none(value: Any) -> bool | None:
    if value is None:
        return None
    if isinstance(value, bool):
        return value
    if value in (0, 1):
        return bool(value)
    raw = str(value).strip().lower()
    if raw in {"1", "true", "t", "yes", "y"}:
        return True
    if raw in {"0", "false", "f", "no", "n"}:
        return False
    return None


def _pick(src: dict[str, Any], allowed: set[str]) -> dict[str, Any]:
    out: dict[str, Any] = {}
    for k in allowed:
        if k in src:
            out[k] = src[k]
    return out


def _to_datetime_utc(value: Any) -> datetime:
    if isinstance(value, datetime):
        dt = value
    else:
        raw = str(value).strip()
        if raw.endswith("Z"):
            raw = f"{raw[:-1]}+00:00"
        dt = datetime.fromisoformat(raw)

    if dt.tzinfo is None:
        return dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


def _transition_key(from_screen: str, to_screen: str) -> str:
    return f"{from_screen}>>{to_screen}"


def _clean_actor_key(value: Any) -> str | None:
    if value is None:
        return None
    actor_key = str(value).strip()
    return actor_key or None


class SupabaseRepository:
    def __init__(self, settings: Settings):
        self.settings = settings
        self.client: Client = create_client(settings.supabase_url, settings.supabase_service_role_key)

    def _upsert_session(
        self,
        *,
        user_id: UUID | None,
        actor_key: str | None,
        payload: dict[str, Any],
        schema_version: str,
    ) -> dict[str, Any]:
        external_session_id = str(payload.get("session_external_id", "")).strip()
        if not external_session_id:
            raise ValueError("payload.session.session_external_id is required")

        normalized_actor_key = _clean_actor_key(actor_key)
        if user_id is None and normalized_actor_key is None:
            raise ValueError("either user_id or actor_key is required")

        row = _pick(payload, SESSION_FIELDS)
        row["external_session_id"] = external_session_id
        row["user_id"] = str(user_id) if user_id is not None else None
        row["actor_key"] = normalized_actor_key
        row["raw_summary"] = {
            "schema_version": schema_version,
            "payload_generated_at": payload.get("generated_at_utc"),
        }
        extra_raw_summary = payload.get("raw_summary")
        if isinstance(extra_raw_summary, dict):
            row["raw_summary"].update(extra_raw_summary)

        # Keep explicit generated timestamp if missing from payload.
        if not row.get("generated_at_utc"):
            row["generated_at_utc"] = datetime.now(timezone.utc).isoformat()

        if normalized_actor_key:
            conflict_target = "actor_key,external_session_id"
        else:
            conflict_target = "user_id,external_session_id"

        resp = self.client.table("sessions").upsert(row, on_conflict=conflict_target).execute()

        if not resp.data:
            raise RuntimeError("sessions upsert returned no data")

        session = resp.data[0]
        session_id = session.get("id")
        if not session_id:
            lookup = self.client.table("sessions").select("id,external_session_id")
            if normalized_actor_key:
                lookup = lookup.eq("actor_key", normalized_actor_key)
            elif user_id is not None:
                lookup = lookup.eq("user_id", str(user_id))
            lookup = lookup.eq("external_session_id", external_session_id).limit(1).execute()
            if not lookup.data:
                raise RuntimeError("failed to fetch session id after upsert")
            session = lookup.data[0]

        return session

    def _delete_children(self, session_id: str) -> None:
        self.client.table("bounces").delete().eq("session_id", session_id).execute()
        self.client.table("shots").delete().eq("session_id", session_id).execute()
        self.client.table("rallies").delete().eq("session_id", session_id).execute()

    def _upsert_rows(self, table: str, rows: list[dict[str, Any]], on_conflict: str) -> int:
        if not rows:
            return 0

        count = 0
        for chunk in _chunked(rows, self.settings.ingest_batch_size):
            self.client.table(table).upsert(chunk, on_conflict=on_conflict).execute()
            count += len(chunk)
        return count

    def ingest_analysis_payload(self, req: SessionUploadRequest) -> dict[str, Any]:
        body = req.model_dump(mode="json")
        payload = body["payload"]
        actor_key = _clean_actor_key(body.get("actor_key"))
        raw_user_id = body.get("user_id")
        user_id = UUID(str(raw_user_id)) if raw_user_id else None

        session = self._upsert_session(
            user_id=user_id,
            actor_key=actor_key,
            payload=payload["session"],
            schema_version=payload["schema_version"],
        )

        session_id = str(session["id"])

        if req.overwrite_existing_children:
            self._delete_children(session_id)

        rallies = []
        for r in payload.get("rallies", []):
            row = _pick(r, RALLY_FIELDS)
            for key in RALLY_BOOL_FIELDS:
                if key in row:
                    row[key] = _to_bool_or_none(row[key])
            row["session_id"] = session_id
            row["actor_key"] = actor_key
            row["raw_row"] = r
            rallies.append(row)

        shots = []
        for s in payload.get("shots", []):
            row = _pick(s, SHOT_FIELDS)
            for key in SHOT_BOOL_FIELDS:
                if key in row:
                    row[key] = _to_bool_or_none(row[key])
            row["session_id"] = session_id
            row["actor_key"] = actor_key
            row["raw_row"] = s
            shots.append(row)

        bounces = []
        for b in payload.get("bounces", []):
            row = _pick(b, BOUNCE_FIELDS)
            for key in BOUNCE_BOOL_FIELDS:
                if key in row:
                    row[key] = _to_bool_or_none(row[key])
            row["session_id"] = session_id
            row["actor_key"] = actor_key
            row["raw_row"] = b
            bounces.append(row)

        inserted_rallies = self._upsert_rows("rallies", rallies, on_conflict="session_id,rally_id")
        inserted_shots = self._upsert_rows("shots", shots, on_conflict="session_id,shot_id")
        inserted_bounces = self._upsert_rows("bounces", bounces, on_conflict="session_id,bounce_id")

        return {
            "session_id": session_id,
            "external_session_id": session["external_session_id"],
            "schema_version": payload["schema_version"],
            "actor_key": actor_key,
            "inserted": {
                "rallies": inserted_rallies,
                "shots": inserted_shots,
                "bounces": inserted_bounces,
            },
            "updated_at_utc": datetime.now(timezone.utc),
        }

    def media_root_path(self) -> Path:
        root = Path(self.settings.media_root)
        if not root.is_absolute():
            project_root = Path(__file__).resolve().parents[3]
            root = project_root / root
        root.mkdir(parents=True, exist_ok=True)
        return root

    def store_uploaded_video(
        self,
        *,
        actor_key: str,
        local_session_id: str,
        filename: str,
        content: bytes,
    ) -> dict[str, str]:
        safe_actor = actor_key.replace(":", "_").replace("/", "_")
        safe_name = Path(filename).name or "upload.mov"
        destination_dir = self.media_root_path() / "uploads" / safe_actor / local_session_id
        destination_dir.mkdir(parents=True, exist_ok=True)
        destination = destination_dir / safe_name
        destination.write_bytes(content)
        return {
            "storage_mode": self.settings.media_storage_mode,
            "storage_path": str(destination),
            "source_video_path": str(destination),
        }

    def create_analysis_job(
        self,
        *,
        actor_key: str,
        local_session_id: str,
        filename: str,
        source_video_path: str,
        local_summary_json: dict[str, Any] | None = None,
        manual_calibration_json: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        row = {
            "actor_key": actor_key,
            "local_session_id": local_session_id,
            "source_video_name": filename,
            "source_video_path": source_video_path,
            "state": "queued",
            "stage": "queued",
            "error_message": None,
            "local_summary_json": local_summary_json or {},
            "manual_calibration_json": manual_calibration_json or {},
            "created_at": datetime.now(timezone.utc).isoformat(),
            "updated_at": datetime.now(timezone.utc).isoformat(),
        }
        response = self.client.table("analysis_jobs").insert(row).execute()
        if not response.data:
            raise RuntimeError("analysis_jobs insert returned no data")
        return response.data[0]

    def update_analysis_job(self, job_id: str, **fields: Any) -> dict[str, Any]:
        fields["updated_at"] = datetime.now(timezone.utc).isoformat()
        response = (
            self.client.table("analysis_jobs")
            .update(fields)
            .eq("id", job_id)
            .execute()
        )
        if response.data:
            return response.data[0]
        lookup = self.client.table("analysis_jobs").select("*").eq("id", job_id).limit(1).execute()
        if not lookup.data:
            raise RuntimeError(f"analysis job not found: {job_id}")
        return lookup.data[0]

    def get_analysis_job(self, job_id: str) -> dict[str, Any]:
        response = self.client.table("analysis_jobs").select("*").eq("id", job_id).limit(1).execute()
        if not response.data:
            raise ValueError(f"analysis job not found: {job_id}")
        return response.data[0]

    def list_analysis_jobs(self, actor_key: str, limit: int = 50) -> list[dict[str, Any]]:
        response = (
            self.client.table("analysis_jobs")
            .select("*")
            .eq("actor_key", actor_key)
            .order("created_at", desc=True)
            .limit(limit)
            .execute()
        )
        return response.data or []

    def list_sessions_for_actor(self, actor_key: str, limit: int = 100) -> list[dict[str, Any]]:
        response = (
            self.client.table("sessions")
            .select("*")
            .eq("actor_key", actor_key)
            .order("generated_at_utc", desc=True)
            .limit(limit)
            .execute()
        )
        return response.data or []

    def _find_session(self, session_ref: str, actor_key: str | None = None) -> dict[str, Any]:
        by_id = self.client.table("sessions").select("*").eq("id", session_ref).limit(1)
        if actor_key:
            by_id = by_id.eq("actor_key", actor_key)
        response = by_id.execute()
        if response.data:
            return response.data[0]

        by_external = self.client.table("sessions").select("*").eq("external_session_id", session_ref).limit(1)
        if actor_key:
            by_external = by_external.eq("actor_key", actor_key)
        response = by_external.execute()
        if response.data:
            return response.data[0]
        raise ValueError(f"session not found: {session_ref}")

    def get_session_detail(self, session_ref: str, actor_key: str | None = None) -> dict[str, Any]:
        session = self._find_session(session_ref, actor_key=actor_key)
        session_id = str(session["id"])

        rallies = (
            self.client.table("rallies")
            .select("*")
            .eq("session_id", session_id)
            .order("rally_id")
            .execute()
            .data
            or []
        )
        shots = (
            self.client.table("shots")
            .select("*")
            .eq("session_id", session_id)
            .order("shot_id")
            .execute()
            .data
            or []
        )
        bounces = (
            self.client.table("bounces")
            .select("*")
            .eq("session_id", session_id)
            .order("bounce_id")
            .execute()
            .data
            or []
        )

        raw_summary = session.get("raw_summary") or {}
        score_timeline = [
            {
                "rally_id": row.get("rally_id"),
                "before_score": row.get("before_score"),
                "after_score": row.get("after_score"),
                "winner_side": row.get("winner_side"),
                "point_status": row.get("point_status"),
                "server_side_before": row.get("server_side_before"),
                "server_side_after": row.get("server_side_after"),
            }
            for row in rallies
        ]
        return {
            "session": session,
            "rallies": rallies,
            "shots": shots,
            "bounces": bounces,
            "score_timeline": score_timeline,
            "model_versions": raw_summary.get("model_versions") or {},
            "court_detection_quality_score": raw_summary.get("court_detection_quality_score"),
        }

    def apply_winner_override(
        self,
        *,
        session_ref: str,
        actor_key: str,
        rally_id: int,
        winner_side: str,
    ) -> dict[str, Any]:
        session = self._find_session(session_ref, actor_key=actor_key)
        session_id = str(session["id"])
        payload = {
            "winner_side": winner_side,
            "winner_source": "manual_override",
            "point_status": "winner_overridden",
        }
        response = (
            self.client.table("rallies")
            .update(payload)
            .eq("session_id", session_id)
            .eq("rally_id", rally_id)
            .execute()
        )
        self.client.table("session_overrides").insert(
            {
                "session_id": session_id,
                "actor_key": actor_key,
                "override_type": "winner_override",
                "payload": {"rally_id": rally_id, "winner_side": winner_side},
            }
        ).execute()
        if response.data:
            return response.data[0]
        raise RuntimeError("winner override update returned no data")

    def apply_court_override(
        self,
        *,
        session_ref: str,
        actor_key: str,
        source_corners: list[dict[str, float]],
    ) -> dict[str, Any]:
        session = self._find_session(session_ref, actor_key=actor_key)
        session_id = str(session["id"])
        raw_summary = dict(session.get("raw_summary") or {})
        raw_summary["manual_court_override"] = {
            "source_corners": source_corners,
            "updated_at_utc": datetime.now(timezone.utc).isoformat(),
        }
        response = (
            self.client.table("sessions")
            .update({"raw_summary": raw_summary})
            .eq("id", session_id)
            .execute()
        )
        self.client.table("session_overrides").insert(
            {
                "session_id": session_id,
                "actor_key": actor_key,
                "override_type": "court_override",
                "payload": {"source_corners": source_corners},
            }
        ).execute()
        if response.data:
            return response.data[0]
        raise RuntimeError("court override update returned no data")

    def upsert_analysis_asset(
        self,
        *,
        job_id: str,
        session_id: str | None,
        actor_key: str,
        asset_type: str,
        storage_path: str,
        metadata: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        response = self.client.table("analysis_assets").insert(
            {
                "job_id": job_id,
                "session_id": session_id,
                "actor_key": actor_key,
                "asset_type": asset_type,
                "storage_path": storage_path,
                "metadata": metadata or {},
            }
        ).execute()
        if not response.data:
            raise RuntimeError("analysis_assets insert returned no data")
        return response.data[0]

    def store_model_version(
        self,
        *,
        model_name: str,
        version: str,
        platform: str,
        metadata: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        response = self.client.table("model_versions").upsert(
            {
                "model_name": model_name,
                "version": version,
                "platform": platform,
                "metadata": metadata or {},
            },
            on_conflict="model_name,version,platform",
        ).execute()
        if not response.data:
            raise RuntimeError("model_versions upsert returned no data")
        return response.data[0]

    def ingest_telemetry_events(self, req: TelemetryEventsRequest) -> dict[str, Any]:
        body = req.model_dump(mode="json")
        base = {
            "install_id": body["install_id"],
            "app_session_id": body["app_session_id"],
            "local_user_id": body.get("local_user_id"),
            "platform": body.get("platform") or "ios",
            "app_version": body.get("app_version"),
            "os_version": body.get("os_version"),
        }

        rows: list[dict[str, Any]] = []
        for e in body.get("events", []):
            rows.append(
                {
                    **base,
                    "event_id": e.get("event_id"),
                    "event_name": e["event_name"],
                    "event_ts_utc": e["event_ts_utc"],
                    "screen_name": e.get("screen_name"),
                    "target_name": e.get("target_name"),
                    "dwell_ms": e.get("dwell_ms"),
                    "duration_ms": e.get("duration_ms"),
                    "metadata": e.get("metadata") or {},
                }
            )

        inserted = 0
        for chunk in _chunked(rows, self.settings.ingest_batch_size):
            self.client.table("app_events").insert(chunk).execute()
            inserted += len(chunk)

        return {
            "inserted": inserted,
            "received_at_utc": datetime.now(timezone.utc),
        }

    def _window_bounds(self, days: int) -> tuple[datetime, datetime]:
        if days < 1:
            raise ValueError("days must be >= 1")
        end_utc = datetime.now(timezone.utc)
        start_utc = end_utc - timedelta(days=days)
        return start_utc, end_utc

    def _apply_app_event_filters(
        self,
        query: Any,
        local_user_id: str | None = None,
        install_id: str | None = None,
        event_name: str | None = None,
        screen_name: str | None = None,
    ) -> Any:
        if local_user_id:
            query = query.eq("local_user_id", local_user_id)
        if install_id:
            query = query.eq("install_id", install_id)
        if event_name:
            query = query.eq("event_name", event_name)
        if screen_name:
            query = query.eq("screen_name", screen_name)
        return query

    def _fetch_app_event_rows(
        self,
        *,
        start_utc: datetime,
        end_utc: datetime,
        columns: str,
        local_user_id: str | None = None,
        install_id: str | None = None,
        event_name: str | None = None,
        screen_name: str | None = None,
        max_rows: int = 50000,
        page_size: int = 1000,
        order_desc: bool = False,
    ) -> list[dict[str, Any]]:
        if max_rows <= 0:
            return []

        rows: list[dict[str, Any]] = []
        offset = 0
        while offset < max_rows:
            upper = min(offset + page_size - 1, max_rows - 1)
            requested = upper - offset + 1
            query = (
                self.client.table("app_events")
                .select(columns)
                .gte("event_ts_utc", start_utc.isoformat())
                .lte("event_ts_utc", end_utc.isoformat())
            )
            query = self._apply_app_event_filters(
                query=query,
                local_user_id=local_user_id,
                install_id=install_id,
                event_name=event_name,
                screen_name=screen_name,
            )
            response = query.order("event_ts_utc", desc=order_desc).range(offset, upper).execute()
            chunk = response.data or []
            rows.extend(chunk)

            if len(chunk) < requested:
                break
            offset += len(chunk)

        return rows

    def get_telemetry_overview(
        self,
        *,
        days: int = 7,
        local_user_id: str | None = None,
        install_id: str | None = None,
        event_name: str | None = None,
        screen_name: str | None = None,
        top_n: int = 8,
    ) -> dict[str, Any]:
        start_utc, end_utc = self._window_bounds(days)
        rows = self._fetch_app_event_rows(
            start_utc=start_utc,
            end_utc=end_utc,
            columns=(
                "event_name,screen_name,target_name,dwell_ms,duration_ms,"
                "install_id,local_user_id,app_session_id"
            ),
            local_user_id=local_user_id,
            install_id=install_id,
            event_name=event_name,
            screen_name=screen_name,
            max_rows=50000,
            page_size=1000,
            order_desc=False,
        )

        event_counts: Counter[str] = Counter()
        screen_counts: Counter[str] = Counter()
        target_counts: Counter[str] = Counter()
        unique_installs: set[str] = set()
        unique_local_users: set[str] = set()
        unique_app_sessions: set[str] = set()

        usage_ms = 0
        screen_dwell_ms = 0

        for row in rows:
            name = str(row.get("event_name") or "").strip()
            if name:
                event_counts[name] += 1

            screen = str(row.get("screen_name") or "").strip()
            if screen:
                screen_counts[screen] += 1

            target = str(row.get("target_name") or "").strip()
            if target:
                target_counts[target] += 1

            install = str(row.get("install_id") or "").strip()
            if install:
                unique_installs.add(install)

            local = str(row.get("local_user_id") or "").strip()
            if local:
                unique_local_users.add(local)

            app_session = str(row.get("app_session_id") or "").strip()
            if app_session:
                unique_app_sessions.add(app_session)

            if name == "app_usage_segment":
                usage_ms += int(row.get("duration_ms") or 0)
            if name == "screen_leave":
                screen_dwell_ms += int(row.get("dwell_ms") or 0)

        return {
            "days": days,
            "window_start_utc": start_utc,
            "window_end_utc": end_utc,
            "local_user_id": local_user_id,
            "install_id": install_id,
            "event_name": event_name,
            "screen_name": screen_name,
            "totals": {
                "events": len(rows),
                "taps": event_counts.get("tap", 0),
                "screen_views": event_counts.get("screen_view", 0),
                "screen_leaves": event_counts.get("screen_leave", 0),
                "usage_segments": event_counts.get("app_usage_segment", 0),
                "usage_ms": usage_ms,
                "screen_dwell_ms": screen_dwell_ms,
                "unique_installs": len(unique_installs),
                "unique_local_users": len(unique_local_users),
                "unique_app_sessions": len(unique_app_sessions),
            },
            "top_screens": [
                {"key": key, "count": count}
                for key, count in screen_counts.most_common(max(1, top_n))
            ],
            "top_targets": [
                {"key": key, "count": count}
                for key, count in target_counts.most_common(max(1, top_n))
            ],
        }

    def get_telemetry_daily(
        self,
        *,
        days: int = 14,
        local_user_id: str | None = None,
        install_id: str | None = None,
        screen_name: str | None = None,
    ) -> dict[str, Any]:
        start_utc, end_utc = self._window_bounds(days)
        rows = self._fetch_app_event_rows(
            start_utc=start_utc,
            end_utc=end_utc,
            columns="event_name,event_ts_utc,install_id,local_user_id,dwell_ms,duration_ms",
            local_user_id=local_user_id,
            install_id=install_id,
            event_name=None,
            screen_name=screen_name,
            max_rows=100000,
            page_size=2000,
            order_desc=False,
        )

        by_day_actor: dict[tuple[datetime, str], dict[str, Any]] = {}

        for row in rows:
            event_ts_utc = _to_datetime_utc(row["event_ts_utc"])
            day_utc = event_ts_utc.replace(hour=0, minute=0, second=0, microsecond=0)
            actor_id = str(row.get("local_user_id") or row.get("install_id") or "unknown")
            key = (day_utc, actor_id)

            if key not in by_day_actor:
                by_day_actor[key] = {
                    "day_utc": day_utc,
                    "actor_id": actor_id,
                    "event_count": 0,
                    "tap_count": 0,
                    "screen_view_count": 0,
                    "screen_leave_count": 0,
                    "usage_segments": 0,
                    "usage_ms": 0,
                    "screen_dwell_ms": 0,
                }

            bucket = by_day_actor[key]
            bucket["event_count"] += 1
            name = str(row.get("event_name") or "")
            if name == "tap":
                bucket["tap_count"] += 1
            elif name == "screen_view":
                bucket["screen_view_count"] += 1
            elif name == "screen_leave":
                bucket["screen_leave_count"] += 1
                bucket["screen_dwell_ms"] += int(row.get("dwell_ms") or 0)
            elif name == "app_usage_segment":
                bucket["usage_segments"] += 1
                bucket["usage_ms"] += int(row.get("duration_ms") or 0)

        ordered_rows = sorted(
            by_day_actor.values(),
            key=lambda item: (item["day_utc"], item["actor_id"]),
            reverse=True,
        )

        return {
            "days": days,
            "window_start_utc": start_utc,
            "window_end_utc": end_utc,
            "local_user_id": local_user_id,
            "install_id": install_id,
            "screen_name": screen_name,
            "rows": ordered_rows,
        }

    def get_telemetry_recent(
        self,
        *,
        limit: int = 100,
        local_user_id: str | None = None,
        install_id: str | None = None,
        event_name: str | None = None,
        screen_name: str | None = None,
    ) -> dict[str, Any]:
        if limit < 1:
            raise ValueError("limit must be >= 1")

        query = self.client.table("app_events").select(
            "id,event_id,install_id,app_session_id,local_user_id,platform,app_version,os_version,"
            "event_name,event_ts_utc,screen_name,target_name,dwell_ms,duration_ms,metadata,received_at"
        )
        query = self._apply_app_event_filters(
            query=query,
            local_user_id=local_user_id,
            install_id=install_id,
            event_name=event_name,
            screen_name=screen_name,
        )
        response = query.order("event_ts_utc", desc=True).limit(limit).execute()

        return {
            "limit": limit,
            "local_user_id": local_user_id,
            "install_id": install_id,
            "event_name": event_name,
            "screen_name": screen_name,
            "events": response.data or [],
        }

    def get_telemetry_screens(
        self,
        *,
        days: int = 14,
        local_user_id: str | None = None,
        install_id: str | None = None,
        screen_name: str | None = None,
        top_n: int = 100,
    ) -> dict[str, Any]:
        filter_screen_name = screen_name.strip() if screen_name else None
        start_utc, end_utc = self._window_bounds(days)
        rows = self._fetch_app_event_rows(
            start_utc=start_utc,
            end_utc=end_utc,
            columns="event_name,screen_name,dwell_ms,local_user_id,install_id",
            local_user_id=local_user_id,
            install_id=install_id,
            event_name=None,
            screen_name=filter_screen_name,
            max_rows=100000,
            page_size=2000,
            order_desc=False,
        )

        by_screen: dict[str, dict[str, Any]] = {}

        for row in rows:
            row_screen_name = str(row.get("screen_name") or "").strip()
            if not row_screen_name:
                continue

            if row_screen_name not in by_screen:
                by_screen[row_screen_name] = {
                    "screen_name": row_screen_name,
                    "screen_views": 0,
                    "screen_leaves": 0,
                    "total_dwell_ms": 0,
                    "_unique_actors": set(),
                }

            bucket = by_screen[row_screen_name]
            event_name = str(row.get("event_name") or "").strip()
            actor_id = str(row.get("local_user_id") or row.get("install_id") or "").strip()
            if actor_id:
                bucket["_unique_actors"].add(actor_id)

            if event_name == "screen_view":
                bucket["screen_views"] += 1
            elif event_name == "screen_leave":
                bucket["screen_leaves"] += 1
                bucket["total_dwell_ms"] += int(row.get("dwell_ms") or 0)

        result_rows: list[dict[str, Any]] = []
        for bucket in by_screen.values():
            leaves = int(bucket["screen_leaves"] or 0)
            total_dwell = int(bucket["total_dwell_ms"] or 0)
            avg_dwell = int(round(total_dwell / leaves)) if leaves > 0 else 0
            result_rows.append(
                {
                    "screen_name": bucket["screen_name"],
                    "screen_views": int(bucket["screen_views"] or 0),
                    "screen_leaves": leaves,
                    "total_dwell_ms": total_dwell,
                    "avg_dwell_ms": avg_dwell,
                    "unique_actors": len(bucket["_unique_actors"]),
                }
            )

        result_rows.sort(
            key=lambda item: (
                int(item["screen_views"]),
                int(item["total_dwell_ms"]),
                item["screen_name"],
            ),
            reverse=True,
        )

        limit = max(1, top_n)
        return {
            "days": days,
            "window_start_utc": start_utc,
            "window_end_utc": end_utc,
            "local_user_id": local_user_id,
            "install_id": install_id,
            "screen_name": filter_screen_name,
            "rows": result_rows[:limit],
        }

    def get_telemetry_transitions(
        self,
        *,
        days: int = 14,
        local_user_id: str | None = None,
        install_id: str | None = None,
        screen_name: str | None = None,
        top_n: int = 100,
    ) -> dict[str, Any]:
        filter_screen_name = screen_name.strip() if screen_name else None
        start_utc, end_utc = self._window_bounds(days)
        rows = self._fetch_app_event_rows(
            start_utc=start_utc,
            end_utc=end_utc,
            columns="event_name,event_ts_utc,screen_name,app_session_id,local_user_id,install_id",
            local_user_id=local_user_id,
            install_id=install_id,
            event_name=None,
            screen_name=None,
            max_rows=100000,
            page_size=2000,
            order_desc=False,
        )
        result_rows = self._build_transition_rows(rows)

        if filter_screen_name:
            result_rows = [
                row
                for row in result_rows
                if str(row.get("from_screen") or "").strip() == filter_screen_name
                or str(row.get("to_screen") or "").strip() == filter_screen_name
            ]

        result_rows.sort(
            key=lambda item: (
                int(item["transition_count"]),
                int(item["unique_actors"]),
                item["from_screen"],
                item["to_screen"],
            ),
            reverse=True,
        )

        limit = max(1, top_n)
        return {
            "days": days,
            "window_start_utc": start_utc,
            "window_end_utc": end_utc,
            "local_user_id": local_user_id,
            "install_id": install_id,
            "screen_name": filter_screen_name,
            "rows": result_rows[:limit],
        }

    def _build_transition_rows(self, rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
        sessions: dict[tuple[str, str], list[dict[str, Any]]] = {}
        for row in rows:
            if str(row.get("event_name") or "").strip() != "screen_view":
                continue
            row_screen_name = str(row.get("screen_name") or "").strip()
            app_session_id = str(row.get("app_session_id") or "").strip()
            install = str(row.get("install_id") or "").strip()
            if not row_screen_name or not app_session_id:
                continue

            key = (install, app_session_id)
            sessions.setdefault(key, []).append(row)

        transitions: dict[str, dict[str, Any]] = {}
        for session_rows in sessions.values():
            sorted_rows = sorted(session_rows, key=lambda item: _to_datetime_utc(item["event_ts_utc"]))
            for idx in range(len(sorted_rows) - 1):
                cur_row = sorted_rows[idx]
                next_row = sorted_rows[idx + 1]

                from_screen = str(cur_row.get("screen_name") or "").strip()
                to_screen = str(next_row.get("screen_name") or "").strip()
                if not from_screen or not to_screen or from_screen == to_screen:
                    continue

                cur_ts = _to_datetime_utc(cur_row["event_ts_utc"])
                next_ts = _to_datetime_utc(next_row["event_ts_utc"])
                gap_sec = max(0.0, (next_ts - cur_ts).total_seconds())

                key = _transition_key(from_screen, to_screen)
                if key not in transitions:
                    transitions[key] = {
                        "from_screen": from_screen,
                        "to_screen": to_screen,
                        "transition_count": 0,
                        "_gap_total_sec": 0.0,
                        "_unique_actors": set(),
                    }

                bucket = transitions[key]
                bucket["transition_count"] += 1
                bucket["_gap_total_sec"] += gap_sec
                actor_id = str(cur_row.get("local_user_id") or cur_row.get("install_id") or "").strip()
                if actor_id:
                    bucket["_unique_actors"].add(actor_id)

        result_rows: list[dict[str, Any]] = []
        for bucket in transitions.values():
            count = int(bucket["transition_count"] or 0)
            avg_gap = (float(bucket["_gap_total_sec"]) / count) if count > 0 else 0.0
            result_rows.append(
                {
                    "from_screen": bucket["from_screen"],
                    "to_screen": bucket["to_screen"],
                    "transition_count": count,
                    "unique_actors": len(bucket["_unique_actors"]),
                    "avg_gap_sec": round(avg_gap, 2),
                }
            )
        return result_rows

    def get_telemetry_transition_alerts(
        self,
        *,
        days: int = 14,
        baseline_days: int = 14,
        confirm_windows: int = 2,
        local_user_id: str | None = None,
        install_id: str | None = None,
        screen_name: str | None = None,
        top_n: int = 100,
        min_current_count: int = 8,
        min_growth_ratio: float = 2.0,
        min_window_growth: float | None = None,
        sort_by: str = "severity",
    ) -> dict[str, Any]:
        allowed_sort_by = {
            "severity",
            "min_window_growth",
            "growth_ratio",
            "delta_count",
            "current_count",
        }
        if baseline_days < 1:
            raise ValueError("baseline_days must be >= 1")
        if confirm_windows < 1:
            raise ValueError("confirm_windows must be >= 1")
        if min_current_count < 1:
            raise ValueError("min_current_count must be >= 1")
        if min_growth_ratio <= 0:
            raise ValueError("min_growth_ratio must be > 0")
        if min_window_growth is not None and min_window_growth <= 0:
            raise ValueError("min_window_growth must be > 0")
        if sort_by not in allowed_sort_by:
            raise ValueError(
                "sort_by must be one of: severity, min_window_growth, growth_ratio, delta_count, current_count"
            )

        filter_screen_name = screen_name.strip() if screen_name else None
        window_start_utc, window_end_utc = self._window_bounds(days)
        window_bounds: list[tuple[datetime, datetime]] = [(window_start_utc, window_end_utc)]
        rolling_end_utc = window_start_utc
        for _ in range(confirm_windows):
            rolling_start_utc = rolling_end_utc - timedelta(days=baseline_days)
            window_bounds.append((rolling_start_utc, rolling_end_utc))
            rolling_end_utc = rolling_start_utc

        baseline_start_utc, baseline_end_utc = window_bounds[1]

        transition_rows_by_window: list[list[dict[str, Any]]] = []
        transition_count_maps: list[dict[str, int]] = []
        for start_utc, end_utc in window_bounds:
            event_rows = self._fetch_app_event_rows(
                start_utc=start_utc,
                end_utc=end_utc,
                columns="event_name,event_ts_utc,screen_name,app_session_id,local_user_id,install_id",
                local_user_id=local_user_id,
                install_id=install_id,
                event_name=None,
                screen_name=None,
                max_rows=100000,
                page_size=2000,
                order_desc=False,
            )
            transition_rows = self._build_transition_rows(event_rows)
            transition_rows_by_window.append(transition_rows)
            transition_count_maps.append(
                {
                    _transition_key(str(row.get("from_screen") or ""), str(row.get("to_screen") or "")): int(
                        row.get("transition_count") or 0
                    )
                    for row in transition_rows
                }
            )

        current_transitions = transition_rows_by_window[0]
        min_delta_count = max(1, min_current_count // 2)

        def _meets_alert_pair(newer_count: int, older_count: int) -> bool:
            if newer_count < min_current_count:
                return False
            growth_ratio_pair = float((newer_count + 1) / (older_count + 1))
            if growth_ratio_pair < min_growth_ratio:
                return False
            delta_count_pair = newer_count - older_count
            if delta_count_pair < min_delta_count:
                return False
            return True

        alert_rows: list[dict[str, Any]] = []
        for row in current_transitions:
            from_screen = str(row.get("from_screen") or "")
            to_screen = str(row.get("to_screen") or "")
            if filter_screen_name and from_screen != filter_screen_name and to_screen != filter_screen_name:
                continue

            current_count = int(row.get("transition_count") or 0)
            if current_count < min_current_count:
                continue

            key = _transition_key(from_screen, to_screen)
            previous_count = int(transition_count_maps[1].get(key, 0))
            delta_count = current_count - previous_count
            growth_ratio = float((current_count + 1) / (previous_count + 1))
            window_counts = [
                int(transition_count_maps[idx].get(key, 0)) for idx in range(confirm_windows + 1)
            ]
            window_growths = [
                round(float((window_counts[idx] + 1) / (window_counts[idx + 1] + 1)), 3)
                for idx in range(confirm_windows)
            ]
            min_window_growth_value = min(window_growths) if window_growths else round(growth_ratio, 3)
            pair_summaries = [
                (
                    f"w{idx}->w{idx + 1}: {window_counts[idx]}->{window_counts[idx + 1]} "
                    f"(delta={window_counts[idx] - window_counts[idx + 1]}, ratio={window_growths[idx]:.3f}x)"
                )
                for idx in range(confirm_windows)
            ]

            if not _meets_alert_pair(current_count, previous_count):
                continue

            confirmed = True
            for idx in range(1, confirm_windows):
                newer_count = int(transition_count_maps[idx].get(key, 0))
                older_count = int(transition_count_maps[idx + 1].get(key, 0))
                if not _meets_alert_pair(newer_count, older_count):
                    confirmed = False
                    break
            if not confirmed:
                continue
            if min_window_growth is not None and min_window_growth_value < min_window_growth:
                continue

            if growth_ratio >= 4.0 and delta_count >= 15:
                severity = "critical"
            elif growth_ratio >= 3.0 and delta_count >= 10:
                severity = "high"
            elif growth_ratio >= 2.0 and delta_count >= 5:
                severity = "medium"
            else:
                severity = "low"

            alert_reason = (
                "confirmed "
                f"{confirm_windows} windows "
                f"(min_current>={min_current_count}, min_growth>={min_growth_ratio:.3f}x, min_delta>={min_delta_count}); "
                + "; ".join(pair_summaries)
            )
            alert_rows.append(
                {
                    "from_screen": from_screen,
                    "to_screen": to_screen,
                    "current_count": current_count,
                    "previous_count": previous_count,
                    "delta_count": delta_count,
                    "growth_ratio": round(growth_ratio, 3),
                    "window_counts": window_counts,
                    "window_growths": window_growths,
                    "min_window_growth": round(min_window_growth_value, 3),
                    "alert_reason": alert_reason,
                    "severity": severity,
                }
            )

        severity_rank = {"critical": 4, "high": 3, "medium": 2, "low": 1}
        if sort_by == "severity":
            alert_rows.sort(
                key=lambda row: (
                    severity_rank.get(str(row.get("severity") or "low"), 0),
                    float(row.get("min_window_growth") or 0.0),
                    float(row.get("growth_ratio") or 0.0),
                    int(row.get("delta_count") or 0),
                ),
                reverse=True,
            )
        elif sort_by == "min_window_growth":
            alert_rows.sort(
                key=lambda row: (
                    float(row.get("min_window_growth") or 0.0),
                    float(row.get("growth_ratio") or 0.0),
                    int(row.get("delta_count") or 0),
                ),
                reverse=True,
            )
        elif sort_by == "growth_ratio":
            alert_rows.sort(
                key=lambda row: (
                    float(row.get("growth_ratio") or 0.0),
                    float(row.get("min_window_growth") or 0.0),
                    int(row.get("delta_count") or 0),
                ),
                reverse=True,
            )
        elif sort_by == "delta_count":
            alert_rows.sort(
                key=lambda row: (
                    int(row.get("delta_count") or 0),
                    float(row.get("growth_ratio") or 0.0),
                    float(row.get("min_window_growth") or 0.0),
                ),
                reverse=True,
            )
        else:  # sort_by == "current_count"
            alert_rows.sort(
                key=lambda row: (
                    int(row.get("current_count") or 0),
                    float(row.get("min_window_growth") or 0.0),
                    float(row.get("growth_ratio") or 0.0),
                ),
                reverse=True,
            )

        limit = max(1, top_n)
        return {
            "days": days,
            "baseline_days": baseline_days,
            "confirm_windows": confirm_windows,
            "window_start_utc": window_start_utc,
            "window_end_utc": window_end_utc,
            "baseline_start_utc": baseline_start_utc,
            "baseline_end_utc": baseline_end_utc,
            "local_user_id": local_user_id,
            "install_id": install_id,
            "screen_name": filter_screen_name,
            "min_current_count": min_current_count,
            "min_growth_ratio": min_growth_ratio,
            "min_window_growth": min_window_growth,
            "sort_by": sort_by,
            "rows": alert_rows[:limit],
        }
