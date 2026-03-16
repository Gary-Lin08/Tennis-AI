from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
import json
from pathlib import Path
from typing import Any

from .models import AnalysisPayload, SessionUploadRequest
from .phase1_runner import Phase1ExecutionError, Phase1RunResult, run_phase1_pipeline
from .repository import SupabaseRepository

PIPELINE_STAGES = [
    "court_detection",
    "tracknet",
    "shot_association",
    "rally_segmentation",
    "score_timeline",
    "export_contract",
    "db_ingest",
    "asset_publish",
]


@dataclass
class SyntheticStructuredSession:
    payload: dict[str, Any]
    model_versions: dict[str, str]
    court_detection_quality_score: float | None


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _safe_int(value: Any, default: int = 0) -> int:
    try:
        if value is None or value == "":
            return default
        return int(float(value))
    except Exception:
        return default


def _safe_float(value: Any, default: float = 0.0) -> float:
    try:
        if value is None or value == "":
            return default
        return float(value)
    except Exception:
        return default


def _load_summary(raw: Any) -> dict[str, Any]:
    if isinstance(raw, dict):
        return raw
    if isinstance(raw, str):
        raw = raw.strip()
        if not raw:
            return {}
        try:
            obj = json.loads(raw)
            return obj if isinstance(obj, dict) else {}
        except Exception:
            return {}
    return {}


def _build_structured_payload(job: dict[str, Any]) -> SyntheticStructuredSession:
    summary = _load_summary(job.get("local_summary_json"))
    local_session_id = str(job.get("local_session_id") or "").strip()
    source_video_path = str(job.get("source_video_path") or "").strip()

    total_frames = _safe_int(summary.get("totalFrames"), 0)
    tracked_frames = _safe_int(summary.get("trackedFrames"), 0)
    duration_sec = _safe_float(summary.get("durationSec"), 0.0)
    visible_rate = _safe_float(summary.get("ballVisibleRate"), 0.0)
    quality_score = _safe_float(summary.get("trackingQualityScore"), 0.0)
    estimated_bounces = _safe_int(summary.get("estimatedBounceCount"), 0)
    event_date = summary.get("eventDate") or _now_iso()
    note = str(summary.get("note") or "")

    actions = sorted(
        [item for item in summary.get("detectedActions", []) if isinstance(item, dict)],
        key=lambda item: _safe_int(item.get("frameIndex"), 0),
    )
    bounce_points = sorted(
        [item for item in summary.get("bouncePoints", []) if isinstance(item, dict)],
        key=lambda item: _safe_int(item.get("frameIndex"), 0),
    )

    rallies: list[dict[str, Any]] = []
    rally_windows: list[tuple[int, int, int]] = []
    if actions:
        current_start = _safe_int(actions[0].get("frameIndex"), 0)
        current_end = current_start
        current_count = 0
        rally_id = 1
        for action in actions:
            frame = _safe_int(action.get("frameIndex"), current_end)
            action_type = str(action.get("type") or "unknown")
            is_boundary = current_count > 0 and (
                frame - current_end > 90 or action_type == "serve"
            )
            if is_boundary:
                rally_windows.append((rally_id, current_start, current_end))
                rally_id += 1
                current_start = frame
                current_count = 0
            current_end = frame
            current_count += 1
        rally_windows.append((rally_id, current_start, current_end))
    elif total_frames > 0:
        rally_windows.append((1, 0, max(total_frames - 1, 0)))

    shots: list[dict[str, Any]] = []
    for index, action in enumerate(actions, start=1):
        frame_num = _safe_int(action.get("frameIndex"), 0)
        rally_id = None
        for candidate_rally_id, start_frame, end_frame in rally_windows:
            if start_frame <= frame_num <= end_frame:
                rally_id = candidate_rally_id
                break
        shots.append(
            {
                "shot_id": index,
                "rally_id": rally_id,
                "frame_num": frame_num,
                "time_sec": _safe_float(action.get("timeSec"), frame_num / 30.0 if frame_num else 0.0),
                "x_px": _safe_float(action.get("x")),
                "y_px": _safe_float(action.get("y")),
                "shot_type": str(action.get("type") or "unknown"),
                "confidence": _safe_float(action.get("confidence"), 0.0),
                "hitter_side": None,
                "hitter_track_id": None,
                "assign_distance_px": None,
                "side_matched": None,
                "speed_kmh": None,
            }
        )

    bounces: list[dict[str, Any]] = []
    for index, bounce in enumerate(bounce_points, start=1):
        frame_num = _safe_int(bounce.get("frameIndex"), 0)
        rally_id = None
        for candidate_rally_id, start_frame, end_frame in rally_windows:
            if start_frame <= frame_num <= end_frame:
                rally_id = candidate_rally_id
                break
        bounces.append(
            {
                "bounce_id": index,
                "rally_id": rally_id,
                "frame_num": frame_num,
                "time_sec": _safe_float(bounce.get("timeSec"), frame_num / 30.0 if frame_num else 0.0),
                "x_px": _safe_float(bounce.get("x")),
                "y_px": _safe_float(bounce.get("y")),
                "in_court": None,
                "confidence": _safe_float(bounce.get("confidence"), 0.0),
                "detection_method": "ios_summary",
            }
        )

    before_score = "S0-0 G0-0 P0-0"
    for rally_id, start_frame, end_frame in rally_windows:
        rally_shots = [shot for shot in shots if shot.get("rally_id") == rally_id]
        rallies.append(
            {
                "rally_id": rally_id,
                "start_frame": start_frame,
                "end_frame": end_frame,
                "start_sec": start_frame / 30.0 if start_frame else 0.0,
                "end_sec": end_frame / 30.0 if end_frame else 0.0,
                "duration_sec": max((end_frame - start_frame) / 30.0, 0.0),
                "num_frames": max(end_frame - start_frame + 1, 0),
                "num_shots": len(rally_shots),
                "near_shots": 0,
                "far_shots": 0,
                "unassigned_shots": len(rally_shots),
                "winner_side": None,
                "winner_source": "pending",
                "point_status": "pending_winner",
                "server_side_before": "near",
                "server_side_after": "near",
                "before_score": before_score,
                "after_score": before_score,
                "game_won_by": None,
                "set_won_by": None,
                "tie_break_before": False,
                "tie_break_after": False,
                "tb_points_before_near": 0,
                "tb_points_before_far": 0,
                "tb_points_after_near": 0,
                "tb_points_after_far": 0,
            }
        )

    payload = {
        "schema_version": "phase1.v1",
        "generated_at_utc": _now_iso(),
        "session": {
            "session_external_id": local_session_id or f"ios-{_now_iso()}",
            "source_video_path": source_video_path or "unknown",
            "generated_at_utc": event_date,
            "total_frames": total_frames,
            "duration_sec": duration_sec,
            "first_server_side": "near",
            "current_server_side": "near",
            "final_sets_near": 0,
            "final_sets_far": 0,
            "final_games_near": 0,
            "final_games_far": 0,
            "final_points_near": "0",
            "final_points_far": "0",
            "num_rallies": len(rallies),
            "num_shots": len(shots),
            "num_bounces": len(bounces) if bounces else estimated_bounces,
            "num_points_scored": 0,
            "num_points_pending": len(rallies),
            "raw_summary": {
                "analysis_source": "ios_summary_fallback",
                "local_note": note,
                "tracked_frames": tracked_frames,
                "ball_visible_rate": visible_rate,
                "tracking_quality_score": quality_score,
            },
        },
        "rallies": rallies,
        "shots": shots,
        "bounces": bounces,
    }
    return SyntheticStructuredSession(
        payload=payload,
        model_versions={"ios_summary": "v1"},
        court_detection_quality_score=quality_score if quality_score > 0 else None,
    )


def _merge_raw_summary(
    *,
    payload: dict[str, Any],
    job: dict[str, Any],
    model_versions: dict[str, str],
    court_detection_quality_score: float | None,
    metadata: dict[str, Any] | None = None,
) -> dict[str, Any]:
    payload = json.loads(json.dumps(payload))
    session = payload.setdefault("session", {})
    raw_summary = dict(session.get("raw_summary") or {})
    local_summary = _load_summary(job.get("local_summary_json"))

    if local_summary.get("note"):
        raw_summary.setdefault("local_note", str(local_summary["note"]))
    if local_summary.get("trackedFrames") is not None:
        raw_summary.setdefault("tracked_frames", _safe_int(local_summary.get("trackedFrames")))
    if local_summary.get("ballVisibleRate") is not None:
        raw_summary.setdefault("ball_visible_rate", _safe_float(local_summary.get("ballVisibleRate")))
    if local_summary.get("trackingQualityScore") is not None:
        raw_summary.setdefault("tracking_quality_score", _safe_float(local_summary.get("trackingQualityScore")))

    if court_detection_quality_score is not None:
        raw_summary["court_detection_quality_score"] = court_detection_quality_score
    raw_summary["model_versions"] = model_versions
    if metadata:
        raw_summary.update(metadata)
    if job.get("manual_calibration_json"):
        raw_summary["manual_court_override"] = job.get("manual_calibration_json")

    session["raw_summary"] = raw_summary
    return payload


def _store_assets(
    repo: SupabaseRepository,
    *,
    job_id: str,
    session_id: str,
    actor_key: str,
    source_video_path: str,
    result: Phase1RunResult | None,
) -> None:
    repo.upsert_analysis_asset(
        job_id=job_id,
        session_id=session_id,
        actor_key=actor_key,
        asset_type="source_video",
        storage_path=source_video_path,
        metadata={"generated_at_utc": _now_iso(), "source_video_path": source_video_path},
    )

    if result is None:
        return

    for artifact in result.artifacts:
        repo.upsert_analysis_asset(
            job_id=job_id,
            session_id=session_id,
            actor_key=actor_key,
            asset_type=artifact.asset_type,
            storage_path=str(artifact.path),
            metadata={"stage": artifact.stage},
        )

    for model_name, version in result.model_versions.items():
        repo.store_model_version(
            model_name=model_name,
            version=version,
            platform="server",
            metadata={"analysis_source": "phase1_real"},
        )


def _run_real_phase1(repo: SupabaseRepository, job: dict[str, Any], job_id: str) -> Phase1RunResult:
    settings = repo.settings
    phase1_root = Path(settings.phase1_root)
    project_root = Path(__file__).resolve().parents[3]
    if not phase1_root.is_absolute():
        phase1_root = project_root / phase1_root
    output_root = repo.media_root_path() / "phase1_jobs" / job_id
    source_video_path = Path(str(job.get("source_video_path") or "")).expanduser()
    python_executable = settings.phase1_python or None
    if python_executable is not None:
        python_path = Path(python_executable)
        if not python_path.is_absolute():
            python_executable = str((project_root / python_path).resolve())

    if not source_video_path.exists():
        raise Phase1ExecutionError(
            stage="source_video",
            command=[str(source_video_path)],
            message=f"source video does not exist: {source_video_path}",
        )

    def on_stage(stage: str) -> None:
        repo.update_analysis_job(job_id, state="analyzing", stage=stage)

    return run_phase1_pipeline(
        video_path=source_video_path,
        session_external_id=str(job.get("local_session_id") or job_id),
        output_root=output_root,
        phase1_root=phase1_root,
        python_executable=python_executable,
        tracknet_device=settings.phase1_tracknet_device,
        player_tracking_device=settings.phase1_player_tracking_device,
        keep_overlays=settings.phase1_keep_overlays,
        timeout_seconds=settings.phase1_timeout_seconds,
        on_stage=on_stage,
    )


def process_analysis_job(repo: SupabaseRepository, job_id: str) -> dict[str, Any]:
    job = repo.update_analysis_job(job_id, state="uploading", stage="upload_received")
    actor_key = str(job.get("actor_key") or "")
    source_video_path = str(job.get("source_video_path") or "")

    result_payload: dict[str, Any]
    model_versions: dict[str, str]
    court_detection_quality_score: float | None
    real_result: Phase1RunResult | None = None
    final_state = "completed"
    final_error_message: str | None = None

    try:
        real_result = _run_real_phase1(repo, job, job_id)
        result_payload = real_result.payload
        model_versions = real_result.model_versions
        court_detection_quality_score = real_result.court_detection_quality_score
        if real_result.warnings:
            final_state = "partial_failed"
            final_error_message = "; ".join(real_result.warnings)
    except Phase1ExecutionError as exc:
        if not repo.settings.phase1_allow_synthetic_fallback:
            repo.update_analysis_job(job_id, state="failed", stage=exc.stage, error_message=str(exc))
            raise
        repo.update_analysis_job(job_id, state="analyzing", stage="synthetic_fallback")
        synthetic = _build_structured_payload(job)
        result_payload = synthetic.payload
        model_versions = synthetic.model_versions
        court_detection_quality_score = synthetic.court_detection_quality_score
        final_state = "partial_failed"
        final_error_message = f"phase1_fallback: {exc}"

    payload_with_summary = _merge_raw_summary(
        payload=result_payload,
        job=job,
        model_versions=model_versions,
        court_detection_quality_score=court_detection_quality_score,
        metadata=(real_result.metadata if real_result is not None else {"analysis_source": "ios_summary_fallback"}),
    )

    repo.update_analysis_job(job_id, state="analyzing", stage="db_ingest")
    request = SessionUploadRequest(
        actor_key=actor_key,
        payload=AnalysisPayload.model_validate(payload_with_summary),
        overwrite_existing_children=True,
    )
    ingest_result = repo.ingest_analysis_payload(request)

    session_detail = repo.get_session_detail(
        ingest_result["external_session_id"],
        actor_key=actor_key,
    )
    session = session_detail["session"]

    repo.update_analysis_job(job_id, state="analyzing", stage="asset_publish")
    _store_assets(
        repo,
        job_id=str(job_id),
        session_id=str(session["id"]),
        actor_key=actor_key,
        source_video_path=source_video_path,
        result=real_result,
    )

    repo.update_analysis_job(
        job_id,
        state=final_state,
        stage="completed",
        error_message=final_error_message,
        remote_session_id=str(session["id"]),
        remote_external_session_id=str(session["external_session_id"]),
    )
    return repo.get_analysis_job(job_id)
