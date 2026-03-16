from __future__ import annotations

from dataclasses import dataclass, field
import os
from pathlib import Path
import shutil
import subprocess
import sys
from typing import Callable


@dataclass(frozen=True)
class Phase1Artifact:
    stage: str
    asset_type: str
    path: Path


@dataclass
class Phase1RunResult:
    payload: dict
    session_external_id: str
    model_versions: dict[str, str]
    court_detection_quality_score: float | None
    artifacts: list[Phase1Artifact] = field(default_factory=list)
    metadata: dict[str, object] = field(default_factory=dict)
    warnings: list[str] = field(default_factory=list)


class Phase1ExecutionError(RuntimeError):
    def __init__(self, stage: str, command: list[str], message: str, stdout: str = "", stderr: str = "") -> None:
        self.stage = stage
        self.command = command
        self.stdout = stdout
        self.stderr = stderr
        detail = f"{stage} failed: {message}"
        if stderr.strip():
            detail = f"{detail}\nstderr:\n{stderr.strip()}"
        elif stdout.strip():
            detail = f"{detail}\nstdout:\n{stdout.strip()}"
        super().__init__(detail)


def default_phase1_python(phase1_root: Path) -> str:
    candidate = phase1_root / "TrackNetV2" / ".venv" / "bin" / "python"
    if candidate.exists():
        return str(candidate)
    return sys.executable


def parse_key_value_output(stdout: str) -> dict[str, str]:
    result: dict[str, str] = {}
    for raw_line in stdout.splitlines():
        line = raw_line.strip()
        if not line or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()
        if key and value:
            result[key] = value
    return result


def ensure_linked_video(source_video: Path, alias_video: Path) -> Path:
    alias_video.parent.mkdir(parents=True, exist_ok=True)
    if alias_video.exists():
        return alias_video
    try:
        alias_video.symlink_to(source_video.resolve())
        return alias_video
    except Exception:
        shutil.copy2(source_video, alias_video)
        return alias_video


def _run_script(
    *,
    python_executable: str,
    script_path: Path,
    command: list[str],
    timeout_seconds: int,
    extra_env: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    if extra_env:
        env.update(extra_env)

    pythonpath_entries = [str(script_path.parents[2].resolve())]
    existing_pythonpath = env.get("PYTHONPATH", "").strip()
    if existing_pythonpath:
        pythonpath_entries.append(existing_pythonpath)
    env["PYTHONPATH"] = os.pathsep.join(pythonpath_entries)

    return subprocess.run(
        [python_executable, str(script_path), *command],
        text=True,
        capture_output=True,
        timeout=timeout_seconds,
        check=False,
        env=env,
    )


def run_phase1_pipeline(
    *,
    video_path: Path,
    session_external_id: str,
    output_root: Path,
    phase1_root: Path,
    python_executable: str | None = None,
    tracknet_device: str = "auto",
    player_tracking_device: str = "cpu",
    keep_overlays: bool = False,
    timeout_seconds: int = 1800,
    on_stage: Callable[[str], None] | None = None,
) -> Phase1RunResult:
    phase1_root = phase1_root.resolve()
    if not phase1_root.exists():
        raise Phase1ExecutionError(
            stage="phase1_root",
            command=[str(phase1_root)],
            message=f"phase1 root does not exist: {phase1_root}",
        )

    python_cmd = python_executable or default_phase1_python(phase1_root)
    output_root.mkdir(parents=True, exist_ok=True)
    alias_video = ensure_linked_video(
        video_path.resolve(),
        output_root / "input" / f"{session_external_id}{video_path.suffix or '.mp4'}",
    )

    def run_stage(stage: str, relative_script: str, args: list[str]) -> tuple[subprocess.CompletedProcess[str], dict[str, str]]:
        if on_stage is not None:
            on_stage(stage)
        script_path = phase1_root / relative_script
        completed = _run_script(
            python_executable=python_cmd,
            script_path=script_path,
            command=args,
            timeout_seconds=timeout_seconds,
        )
        if completed.returncode != 0:
            raise Phase1ExecutionError(
                stage=stage,
                command=[python_cmd, str(script_path), *args],
                message=f"exit code {completed.returncode}",
                stdout=completed.stdout,
                stderr=completed.stderr,
            )
        return completed, parse_key_value_output(completed.stdout)

    artifacts: list[Phase1Artifact] = []
    warnings: list[str] = []
    model_versions = {
        "court_detection": "hough_homography.v1",
        "tracknet": "tracknet_tennis_yastrebksv.v1",
        "shot_detection": "ball_track_heuristic.v1",
        "rally_segmentation": "visibility_segmentation.v1",
        "score_timeline": "ruleset.v1",
        "export_contract": "phase1.v1",
    }

    court_dir = output_root / "court_detection"
    _, _ = run_stage(
        "court_detection",
        "court_detection/detect_court.py",
        [
            "--input",
            str(alias_video),
            "--output-dir",
            str(court_dir),
            "--prefix",
            session_external_id,
        ],
    )
    court_json = court_dir / f"{session_external_id}_court_detection.json"
    court_overlay = court_dir / f"{session_external_id}_court_overlay.jpg"
    court_topdown = court_dir / f"{session_external_id}_topdown.jpg"
    artifacts.extend(
        [
            Phase1Artifact(stage="court_detection", asset_type="court_json", path=court_json),
            Phase1Artifact(stage="court_detection", asset_type="court_overlay", path=court_overlay),
        ]
    )
    if court_topdown.exists():
        artifacts.append(Phase1Artifact(stage="court_detection", asset_type="court_topdown", path=court_topdown))

    track_dir = output_root / "tracknet_tennis"
    _, _ = run_stage(
        "tracknet",
        "tracknet_tennis/infer_tracknet_tennis.py",
        [
            "--video",
            str(alias_video),
            "--output-dir",
            str(track_dir),
            "--device",
            tracknet_device,
            "--court-json",
            str(court_json),
            "--extrapolate",
        ],
    )
    track_csv = track_dir / f"{alias_video.stem}_tracknet_tennis.csv"
    track_video = track_dir / f"{alias_video.stem}_tracknet_tennis.mp4"
    artifacts.append(Phase1Artifact(stage="tracknet", asset_type="track_csv", path=track_csv))
    if track_video.exists():
        artifacts.append(Phase1Artifact(stage="tracknet", asset_type="track_overlay_video", path=track_video))

    shots_dir = output_root / "shot_detection"
    shot_args = [
        "--track-csv",
        str(track_csv),
        "--video",
        str(alias_video),
        "--court-json",
        str(court_json),
        "--output-dir",
        str(shots_dir),
        "--prefix",
        session_external_id,
    ]
    if not keep_overlays:
        shot_args.append("--no-overlay")
    _, _ = run_stage("shot_detection", "shot_detection/detect_shots_from_track.py", shot_args)
    shots_csv = shots_dir / f"{session_external_id}_shots.csv"
    shots_json = shots_dir / f"{session_external_id}_shots.json"
    artifacts.extend(
        [
            Phase1Artifact(stage="shot_detection", asset_type="shots_csv", path=shots_csv),
            Phase1Artifact(stage="shot_detection", asset_type="shots_json", path=shots_json),
        ]
    )
    shot_overlay = shots_dir / f"{session_external_id}_shots_overlay.mp4"
    if shot_overlay.exists():
        artifacts.append(Phase1Artifact(stage="shot_detection", asset_type="shots_overlay_video", path=shot_overlay))

    effective_shots_csv = shots_csv
    player_dir = output_root / "player_tracking"
    player_args = [
        "--video",
        str(alias_video),
        "--shots-csv",
        str(shots_csv),
        "--court-json",
        str(court_json),
        "--output-dir",
        str(player_dir),
        "--prefix",
        session_external_id,
        "--device",
        player_tracking_device,
    ]
    if not keep_overlays:
        player_args.append("--no-overlay")
    try:
        _, _ = run_stage("shot_association", "player_tracking/associate_shots_with_players.py", player_args)
        player_csv = player_dir / f"{session_external_id}_shots_with_players.csv"
        player_json = player_dir / f"{session_external_id}_shots_with_players.json"
        if player_csv.exists():
            effective_shots_csv = player_csv
            model_versions["player_tracking"] = "yolo11n_bytetrack.v1"
            artifacts.extend(
                [
                    Phase1Artifact(stage="shot_association", asset_type="shots_with_players_csv", path=player_csv),
                    Phase1Artifact(stage="shot_association", asset_type="shots_with_players_json", path=player_json),
                ]
            )
            player_overlay = player_dir / f"{session_external_id}_shots_with_players_overlay.mp4"
            if player_overlay.exists():
                artifacts.append(
                    Phase1Artifact(stage="shot_association", asset_type="shots_with_players_overlay_video", path=player_overlay)
                )
        else:
            warnings.append("player_tracking produced no CSV; using raw shot detections")
    except Phase1ExecutionError as exc:
        warnings.append(f"player_tracking_failed: {exc}")

    rally_dir = output_root / "rally_detection"
    rally_args = [
        "--video",
        str(alias_video),
        "--track-csv",
        str(track_csv),
        "--shots-csv",
        str(effective_shots_csv),
        "--output-dir",
        str(rally_dir),
        "--prefix",
        session_external_id,
    ]
    if not keep_overlays:
        rally_args.append("--no-overlay")
    _, _ = run_stage("rally_segmentation", "rally_detection/split_rallies.py", rally_args)
    rallies_csv = rally_dir / f"{session_external_id}_rallies.csv"
    rallies_json = rally_dir / f"{session_external_id}_rallies.json"
    artifacts.extend(
        [
            Phase1Artifact(stage="rally_segmentation", asset_type="rallies_csv", path=rallies_csv),
            Phase1Artifact(stage="rally_segmentation", asset_type="rallies_json", path=rallies_json),
        ]
    )

    score_dir = output_root / "scoring"
    score_args = [
        "--video",
        str(alias_video),
        "--rallies-csv",
        str(rallies_csv),
        "--shots-csv",
        str(effective_shots_csv),
        "--output-dir",
        str(score_dir),
        "--prefix",
        session_external_id,
    ]
    if not keep_overlays:
        score_args.append("--no-overlay")
    _, _ = run_stage("score_timeline", "scoring/build_score_timeline.py", score_args)
    timeline_csv = score_dir / f"{session_external_id}_score_timeline.csv"
    timeline_json = score_dir / f"{session_external_id}_score_timeline.json"
    artifacts.extend(
        [
            Phase1Artifact(stage="score_timeline", asset_type="score_timeline_csv", path=timeline_csv),
            Phase1Artifact(stage="score_timeline", asset_type="score_timeline_json", path=timeline_json),
        ]
    )
    pending_overrides = score_dir / f"{session_external_id}_winner_overrides_template.csv"
    if pending_overrides.exists():
        artifacts.append(
            Phase1Artifact(stage="score_timeline", asset_type="winner_overrides_template_csv", path=pending_overrides)
        )

    export_dir = output_root / "data_contract"
    _, _ = run_stage(
        "export_contract",
        "data_contract/export_phase1_dataset.py",
        [
            "--video",
            str(alias_video),
            "--rallies-csv",
            str(rallies_csv),
            "--shots-csv",
            str(effective_shots_csv),
            "--timeline-csv",
            str(timeline_csv),
            "--track-csv",
            str(track_csv),
            "--court-json",
            str(court_json),
            "--session-id",
            session_external_id,
            "--output-dir",
            str(export_dir),
            "--prefix",
            session_external_id,
        ],
    )
    payload_json = export_dir / f"{session_external_id}_analysis_payload.json"
    sessions_csv = export_dir / f"{session_external_id}_sessions.csv"
    export_shots_csv = export_dir / f"{session_external_id}_shots.csv"
    export_rallies_csv = export_dir / f"{session_external_id}_rallies.csv"
    export_bounces_csv = export_dir / f"{session_external_id}_bounces.csv"
    artifacts.extend(
        [
            Phase1Artifact(stage="export_contract", asset_type="analysis_payload_json", path=payload_json),
            Phase1Artifact(stage="export_contract", asset_type="sessions_csv", path=sessions_csv),
            Phase1Artifact(stage="export_contract", asset_type="rallies_csv", path=export_rallies_csv),
            Phase1Artifact(stage="export_contract", asset_type="shots_csv", path=export_shots_csv),
            Phase1Artifact(stage="export_contract", asset_type="bounces_csv", path=export_bounces_csv),
        ]
    )

    if not payload_json.exists():
        raise Phase1ExecutionError(
            stage="export_contract",
            command=[str(payload_json)],
            message=f"payload json not found: {payload_json}",
        )

    import json

    payload = json.loads(payload_json.read_text(encoding="utf-8"))
    court_payload = json.loads(court_json.read_text(encoding="utf-8"))
    quality = court_payload.get("quality", {}) if isinstance(court_payload, dict) else {}
    court_quality_score = quality.get("score")
    if court_quality_score is not None:
        try:
            court_quality_score = float(court_quality_score)
        except Exception:
            court_quality_score = None

    metadata: dict[str, object] = {
        "analysis_source": "phase1_real",
        "court_detection": court_payload,
        "artifacts_root": str(output_root.resolve()),
    }
    if warnings:
        metadata["warnings"] = list(warnings)

    return Phase1RunResult(
        payload=payload,
        session_external_id=session_external_id,
        model_versions=model_versions,
        court_detection_quality_score=court_quality_score,
        artifacts=[artifact for artifact in artifacts if artifact.path.exists()],
        metadata=metadata,
        warnings=warnings,
    )
