from __future__ import annotations

import hmac
import json
from pathlib import Path

from fastapi import BackgroundTasks, Depends, FastAPI, File, Form, Header, HTTPException, Query, UploadFile
from fastapi.responses import HTMLResponse

from .analysis_pipeline import process_analysis_job
from .config import Settings
from .models import (
    AnalysisJobResponse,
    AnalysisVideoUploadResponse,
    CourtOverrideRequest,
    SessionUploadRequest,
    SessionUploadResponse,
    SessionDetailResponse,
    SessionSummaryItem,
    TelemetryDailyResponse,
    TelemetryEventsRequest,
    TelemetryEventsResponse,
    TelemetryOverviewResponse,
    TelemetryRecentResponse,
    TelemetryScreensResponse,
    TelemetryTransitionAlertsResponse,
    TelemetryTransitionsResponse,
    WinnerOverrideRequest,
)
from .repository import SupabaseRepository

app = FastAPI(title="Tennis AI Backend", version="0.1.0")

_repo: SupabaseRepository | None = None
_settings: Settings | None = None
_dashboard_html: str | None = None


def get_settings() -> Settings:
    global _settings
    if _settings is None:
        _settings = Settings.from_env()
    return _settings


def get_repo() -> SupabaseRepository:
    global _repo
    if _repo is None:
        _repo = SupabaseRepository(get_settings())
    return _repo


def get_dashboard_html() -> str:
    global _dashboard_html
    if _dashboard_html is None:
        html_path = Path(__file__).parent / "admin_dashboard.html"
        _dashboard_html = html_path.read_text(encoding="utf-8")
    return _dashboard_html


@app.get("/healthz")
def healthz() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/telemetry/admin/dashboard", response_class=HTMLResponse)
def telemetry_admin_dashboard() -> str:
    return get_dashboard_html()


def require_admin_key(x_admin_key: str | None = Header(default=None, alias="X-Admin-Key")) -> None:
    configured_key = get_settings().admin_api_key
    if not configured_key:
        raise HTTPException(status_code=503, detail="admin_api_key_not_configured")
    if not x_admin_key:
        raise HTTPException(status_code=401, detail="missing_admin_key")
    if not hmac.compare_digest(x_admin_key, configured_key):
        raise HTTPException(status_code=403, detail="invalid_admin_key")


def _parse_optional_json(raw: str | None) -> dict[str, object] | None:
    if raw is None:
        return None
    cleaned = raw.strip()
    if not cleaned:
        return None
    try:
        value = json.loads(cleaned)
    except Exception as exc:
        raise HTTPException(status_code=400, detail=f"invalid_json_payload: {exc}") from exc
    if not isinstance(value, dict):
        raise HTTPException(status_code=400, detail="invalid_json_payload: object_required")
    return value


@app.post("/sessions/upload", response_model=SessionUploadResponse)
def upload_session(request: SessionUploadRequest) -> SessionUploadResponse:
    try:
        result = get_repo().ingest_analysis_payload(request)
        return SessionUploadResponse(ok=True, **result)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except RuntimeError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"unexpected_error: {exc}") from exc


@app.post("/analysis/videos", response_model=AnalysisVideoUploadResponse)
async def upload_analysis_video(
    background_tasks: BackgroundTasks,
    actor_key: str = Form(...),
    local_session_id: str = Form(...),
    video_file: UploadFile = File(...),
    local_summary_json: str | None = Form(default=None),
    manual_calibration_json: str | None = Form(default=None),
) -> AnalysisVideoUploadResponse:
    normalized_actor_key = actor_key.strip()
    normalized_local_session_id = local_session_id.strip()
    if not normalized_actor_key:
        raise HTTPException(status_code=400, detail="actor_key_required")
    if not normalized_local_session_id:
        raise HTTPException(status_code=400, detail="local_session_id_required")

    try:
        file_bytes = await video_file.read()
        stored = get_repo().store_uploaded_video(
            actor_key=normalized_actor_key,
            local_session_id=normalized_local_session_id,
            filename=video_file.filename or "upload.mov",
            content=file_bytes,
        )
        job = get_repo().create_analysis_job(
            actor_key=normalized_actor_key,
            local_session_id=normalized_local_session_id,
            filename=video_file.filename or "upload.mov",
            source_video_path=stored["source_video_path"],
            local_summary_json=_parse_optional_json(local_summary_json),
            manual_calibration_json=_parse_optional_json(manual_calibration_json),
        )
        background_tasks.add_task(process_analysis_job, get_repo(), str(job["id"]))
        return AnalysisVideoUploadResponse(
            ok=True,
            job_id=job["id"],
            actor_key=job["actor_key"],
            local_session_id=job["local_session_id"],
            state=job["state"],
            stage=job["stage"],
            created_at_utc=job["created_at"],
        )
    except HTTPException:
        raise
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except RuntimeError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"unexpected_error: {exc}") from exc


@app.get("/analysis/jobs/{job_id}", response_model=AnalysisJobResponse)
def get_analysis_job(job_id: str) -> AnalysisJobResponse:
    try:
        job = get_repo().get_analysis_job(job_id)
        return AnalysisJobResponse(
            ok=True,
            job_id=job["id"],
            actor_key=job["actor_key"],
            local_session_id=job["local_session_id"],
            state=job["state"],
            stage=job["stage"],
            error_message=job.get("error_message"),
            remote_session_id=job.get("remote_session_id"),
            remote_external_session_id=job.get("remote_external_session_id"),
            source_video_path=job.get("source_video_path"),
            created_at_utc=job["created_at"],
            updated_at_utc=job["updated_at"],
        )
    except ValueError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"unexpected_error: {exc}") from exc


@app.get("/analysis/jobs", response_model=list[AnalysisJobResponse])
def list_analysis_jobs(
    actor_key: str = Query(...),
    limit: int = Query(default=50, ge=1, le=200),
) -> list[AnalysisJobResponse]:
    try:
        rows = get_repo().list_analysis_jobs(actor_key=actor_key.strip(), limit=limit)
        return [
            AnalysisJobResponse(
                ok=True,
                job_id=row["id"],
                actor_key=row["actor_key"],
                local_session_id=row["local_session_id"],
                state=row["state"],
                stage=row["stage"],
                error_message=row.get("error_message"),
                remote_session_id=row.get("remote_session_id"),
                remote_external_session_id=row.get("remote_external_session_id"),
                source_video_path=row.get("source_video_path"),
                created_at_utc=row["created_at"],
                updated_at_utc=row["updated_at"],
            )
            for row in rows
        ]
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"unexpected_error: {exc}") from exc


@app.get("/sessions", response_model=list[SessionSummaryItem])
def list_sessions(
    actor_key: str = Query(...),
    limit: int = Query(default=100, ge=1, le=200),
) -> list[SessionSummaryItem]:
    try:
        rows = get_repo().list_sessions_for_actor(actor_key=actor_key.strip(), limit=limit)
        return [SessionSummaryItem.model_validate(row) for row in rows]
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"unexpected_error: {exc}") from exc


@app.get("/sessions/{session_ref}", response_model=SessionSummaryItem)
def get_session_summary(
    session_ref: str,
    actor_key: str | None = Query(default=None),
) -> SessionSummaryItem:
    try:
        detail = get_repo().get_session_detail(session_ref, actor_key=actor_key.strip() if actor_key else None)
        return SessionSummaryItem.model_validate(detail["session"])
    except ValueError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"unexpected_error: {exc}") from exc


@app.get("/sessions/{session_ref}/detail", response_model=SessionDetailResponse)
def get_session_detail(
    session_ref: str,
    actor_key: str | None = Query(default=None),
) -> SessionDetailResponse:
    try:
        detail = get_repo().get_session_detail(session_ref, actor_key=actor_key.strip() if actor_key else None)
        return SessionDetailResponse(
            ok=True,
            session=SessionSummaryItem.model_validate(detail["session"]),
            rallies=detail["rallies"],
            shots=detail["shots"],
            bounces=detail["bounces"],
            score_timeline=detail["score_timeline"],
            model_versions=detail["model_versions"],
            court_detection_quality_score=detail["court_detection_quality_score"],
        )
    except ValueError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"unexpected_error: {exc}") from exc


@app.post("/sessions/{session_ref}/court-override", response_model=SessionSummaryItem)
def apply_court_override(
    session_ref: str,
    request: CourtOverrideRequest,
    actor_key: str = Query(...),
) -> SessionSummaryItem:
    try:
        updated = get_repo().apply_court_override(
            session_ref=session_ref,
            actor_key=actor_key.strip(),
            source_corners=[item.model_dump(mode="json") for item in request.source_corners],
        )
        return SessionSummaryItem.model_validate(updated)
    except ValueError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"unexpected_error: {exc}") from exc


@app.post("/sessions/{session_ref}/winner-override", response_model=SessionDetailResponse)
def apply_winner_override(
    session_ref: str,
    request: WinnerOverrideRequest,
    actor_key: str = Query(...),
) -> SessionDetailResponse:
    try:
        get_repo().apply_winner_override(
            session_ref=session_ref,
            actor_key=actor_key.strip(),
            rally_id=request.rally_id,
            winner_side=request.winner_side,
        )
        detail = get_repo().get_session_detail(session_ref, actor_key=actor_key.strip())
        return SessionDetailResponse(
            ok=True,
            session=SessionSummaryItem.model_validate(detail["session"]),
            rallies=detail["rallies"],
            shots=detail["shots"],
            bounces=detail["bounces"],
            score_timeline=detail["score_timeline"],
            model_versions=detail["model_versions"],
            court_detection_quality_score=detail["court_detection_quality_score"],
        )
    except ValueError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"unexpected_error: {exc}") from exc


@app.post("/telemetry/events", response_model=TelemetryEventsResponse)
def upload_telemetry_events(request: TelemetryEventsRequest) -> TelemetryEventsResponse:
    try:
        result = get_repo().ingest_telemetry_events(request)
        return TelemetryEventsResponse(ok=True, **result)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except RuntimeError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"unexpected_error: {exc}") from exc


@app.get(
    "/telemetry/admin/overview",
    response_model=TelemetryOverviewResponse,
    dependencies=[Depends(require_admin_key)],
)
def telemetry_admin_overview(
    days: int = Query(default=7, ge=1, le=90),
    local_user_id: str | None = Query(default=None),
    install_id: str | None = Query(default=None),
    event_name: str | None = Query(default=None),
    screen_name: str | None = Query(default=None),
) -> TelemetryOverviewResponse:
    try:
        result = get_repo().get_telemetry_overview(
            days=days,
            local_user_id=local_user_id,
            install_id=install_id,
            event_name=event_name,
            screen_name=screen_name,
        )
        return TelemetryOverviewResponse(ok=True, **result)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except RuntimeError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"unexpected_error: {exc}") from exc


@app.get(
    "/telemetry/admin/daily",
    response_model=TelemetryDailyResponse,
    dependencies=[Depends(require_admin_key)],
)
def telemetry_admin_daily(
    days: int = Query(default=14, ge=1, le=180),
    local_user_id: str | None = Query(default=None),
    install_id: str | None = Query(default=None),
    screen_name: str | None = Query(default=None),
) -> TelemetryDailyResponse:
    try:
        result = get_repo().get_telemetry_daily(
            days=days,
            local_user_id=local_user_id,
            install_id=install_id,
            screen_name=screen_name,
        )
        return TelemetryDailyResponse(ok=True, **result)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except RuntimeError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"unexpected_error: {exc}") from exc


@app.get(
    "/telemetry/admin/recent",
    response_model=TelemetryRecentResponse,
    dependencies=[Depends(require_admin_key)],
)
def telemetry_admin_recent(
    limit: int = Query(default=100, ge=1, le=500),
    local_user_id: str | None = Query(default=None),
    install_id: str | None = Query(default=None),
    event_name: str | None = Query(default=None),
    screen_name: str | None = Query(default=None),
) -> TelemetryRecentResponse:
    try:
        result = get_repo().get_telemetry_recent(
            limit=limit,
            local_user_id=local_user_id,
            install_id=install_id,
            event_name=event_name,
            screen_name=screen_name,
        )
        return TelemetryRecentResponse(ok=True, **result)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except RuntimeError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"unexpected_error: {exc}") from exc


@app.get(
    "/telemetry/admin/screens",
    response_model=TelemetryScreensResponse,
    dependencies=[Depends(require_admin_key)],
)
def telemetry_admin_screens(
    days: int = Query(default=14, ge=1, le=180),
    local_user_id: str | None = Query(default=None),
    install_id: str | None = Query(default=None),
    screen_name: str | None = Query(default=None),
    top_n: int = Query(default=100, ge=1, le=500),
) -> TelemetryScreensResponse:
    try:
        result = get_repo().get_telemetry_screens(
            days=days,
            local_user_id=local_user_id,
            install_id=install_id,
            screen_name=screen_name,
            top_n=top_n,
        )
        return TelemetryScreensResponse(ok=True, **result)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except RuntimeError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"unexpected_error: {exc}") from exc


@app.get(
    "/telemetry/admin/transitions",
    response_model=TelemetryTransitionsResponse,
    dependencies=[Depends(require_admin_key)],
)
def telemetry_admin_transitions(
    days: int = Query(default=14, ge=1, le=180),
    local_user_id: str | None = Query(default=None),
    install_id: str | None = Query(default=None),
    screen_name: str | None = Query(default=None),
    top_n: int = Query(default=100, ge=1, le=500),
) -> TelemetryTransitionsResponse:
    try:
        result = get_repo().get_telemetry_transitions(
            days=days,
            local_user_id=local_user_id,
            install_id=install_id,
            screen_name=screen_name,
            top_n=top_n,
        )
        return TelemetryTransitionsResponse(ok=True, **result)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except RuntimeError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"unexpected_error: {exc}") from exc


@app.get(
    "/telemetry/admin/transitions/alerts",
    response_model=TelemetryTransitionAlertsResponse,
    dependencies=[Depends(require_admin_key)],
)
def telemetry_admin_transition_alerts(
    days: int = Query(default=14, ge=1, le=180),
    baseline_days: int = Query(default=14, ge=1, le=365),
    confirm_windows: int = Query(default=2, ge=1, le=4),
    local_user_id: str | None = Query(default=None),
    install_id: str | None = Query(default=None),
    screen_name: str | None = Query(default=None),
    top_n: int = Query(default=100, ge=1, le=500),
    min_current_count: int = Query(default=8, ge=1, le=100000),
    min_growth_ratio: float = Query(default=2.0, gt=0.0, le=1000.0),
    min_window_growth: float | None = Query(default=None, gt=0.0, le=1000.0),
    sort_by: str = Query(default="severity"),
) -> TelemetryTransitionAlertsResponse:
    try:
        result = get_repo().get_telemetry_transition_alerts(
            days=days,
            baseline_days=baseline_days,
            confirm_windows=confirm_windows,
            local_user_id=local_user_id,
            install_id=install_id,
            screen_name=screen_name,
            top_n=top_n,
            min_current_count=min_current_count,
            min_growth_ratio=min_growth_ratio,
            min_window_growth=min_window_growth,
            sort_by=sort_by,
        )
        return TelemetryTransitionAlertsResponse(ok=True, **result)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except RuntimeError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"unexpected_error: {exc}") from exc
