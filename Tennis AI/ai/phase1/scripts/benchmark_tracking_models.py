#!/usr/bin/env python3
"""Benchmark TrackNet or GridTrackNet on a fixed-camera dataset manifest."""

from __future__ import annotations

import argparse
import csv
import json
import math
import platform
import subprocess
import sys
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[3]
DEFAULT_TRACKNET_SCRIPT = REPO_ROOT / "ai/phase1/tracknet_tennis/infer_tracknet_tennis.py"
DEFAULT_GRIDTRACKNET_ADAPTER = REPO_ROOT / "ai/phase1/scripts/run_gridtracknet_adapter.py"


@dataclass
class PredictionRow:
    frame_num: int
    visible: int
    x: float
    y: float


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True, help="Benchmark dataset manifest JSON.")
    parser.add_argument("--model", choices=["tracknet", "gridtracknet"], required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--python-bin", default=sys.executable, help="Python interpreter used to launch adapters.")
    parser.add_argument("--tracknet-script", type=Path, default=DEFAULT_TRACKNET_SCRIPT)
    parser.add_argument("--gridtracknet-script", type=Path, default=DEFAULT_GRIDTRACKNET_ADAPTER)
    parser.add_argument("--gridtracknet-repo", type=Path, default=None, help="Path to an external GridTrackNet repo clone.")
    return parser.parse_args(argv)


def resolve_path(raw_path: str | None) -> Path | None:
    if not raw_path:
        return None
    path = Path(raw_path)
    return path if path.is_absolute() else (REPO_ROOT / path)


def load_manifest(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        manifest = json.load(handle)
    if "dataset_version" not in manifest or "entries" not in manifest:
        raise ValueError("Manifest must contain dataset_version and entries.")
    if not isinstance(manifest["entries"], list) or not manifest["entries"]:
        raise ValueError("Manifest entries must be a non-empty list.")
    return manifest


def run_model(
    model: str,
    entry: dict[str, Any],
    args: argparse.Namespace,
    entry_output_dir: Path,
) -> tuple[list[str], Path]:
    video_path = resolve_path(entry.get("video"))
    if video_path is None:
        raise ValueError(f"Entry {entry.get('id', '<missing id>')} is missing a video path.")
    if not video_path.exists():
        raise FileNotFoundError(f"Video not found: {video_path}")

    if model == "tracknet":
        command = [
            args.python_bin,
            str(args.tracknet_script),
            "--video",
            str(video_path),
            "--output-dir",
            str(entry_output_dir),
        ]
        court_json = resolve_path(entry.get("court_json"))
        if court_json:
            command.extend(["--court-json", str(court_json)])
        prediction_csv = entry_output_dir / f"{video_path.stem}_tracknet_tennis.csv"
        return command, prediction_csv

    if args.gridtracknet_repo is None:
        raise ValueError("--gridtracknet-repo is required when model=gridtracknet.")

    command = [
        args.python_bin,
        str(args.gridtracknet_script),
        "--video",
        str(video_path),
        "--output-dir",
        str(entry_output_dir),
        "--repo",
        str(args.gridtracknet_repo),
    ]
    prediction_csv = entry_output_dir / f"{video_path.stem}_gridtracknet.csv"
    return command, prediction_csv


def read_prediction_csv(path: Path) -> list[PredictionRow]:
    with path.open("r", encoding="utf-8", newline="") as handle:
        rows = []
        for raw in csv.DictReader(handle):
            rows.append(
                PredictionRow(
                    frame_num=int(raw["frame_num"]),
                    visible=int(raw["visible"]),
                    x=float(raw["x"]),
                    y=float(raw["y"]),
                )
            )
        return rows


def compute_visible_rate(rows: list[PredictionRow]) -> float | None:
    if not rows:
        return None
    visible = sum(1 for row in rows if row.visible == 1)
    return visible / len(rows)


def compute_trajectory_continuity(rows: list[PredictionRow]) -> float | None:
    visible_frames = [row.frame_num for row in rows if row.visible == 1]
    if not visible_frames:
        return 0.0
    if len(visible_frames) == 1:
        return 1.0
    consecutive_pairs = sum(
        1 for left, right in zip(visible_frames, visible_frames[1:]) if right - left <= 1
    )
    return consecutive_pairs / (len(visible_frames) - 1)


def compute_pixel_mean_error(
    predicted_rows: list[PredictionRow],
    ground_truth_csv: Path | None,
) -> float | None:
    if ground_truth_csv is None or not ground_truth_csv.exists():
        return None

    truth_by_frame: dict[int, PredictionRow] = {}
    for row in read_prediction_csv(ground_truth_csv):
        truth_by_frame[row.frame_num] = row

    errors: list[float] = []
    for predicted in predicted_rows:
        truth = truth_by_frame.get(predicted.frame_num)
        if truth is None or truth.visible != 1 or predicted.visible != 1:
            continue
        errors.append(math.hypot(predicted.x - truth.x, predicted.y - truth.y))

    if not errors:
        return None
    return sum(errors) / len(errors)


def mean_or_none(values: list[float | None]) -> float | None:
    usable = [value for value in values if value is not None]
    if not usable:
        return None
    return sum(usable) / len(usable)


def benchmark_entry(
    entry: dict[str, Any],
    args: argparse.Namespace,
) -> dict[str, Any]:
    entry_id = entry.get("id") or Path(entry["video"]).stem
    entry_output_dir = args.output_dir / args.model / entry_id
    entry_output_dir.mkdir(parents=True, exist_ok=True)

    command, prediction_csv = run_model(args.model, entry, args, entry_output_dir)
    started_at = time.perf_counter()
    completed = subprocess.run(command, cwd=REPO_ROOT, capture_output=True, text=True, check=False)
    elapsed = time.perf_counter() - started_at

    if completed.returncode != 0:
        raise RuntimeError(
            f"Benchmark adapter failed for {entry_id}:\n"
            f"STDOUT:\n{completed.stdout}\nSTDERR:\n{completed.stderr}"
        )
    if not prediction_csv.exists():
        raise FileNotFoundError(f"Expected prediction CSV was not created: {prediction_csv}")

    rows = read_prediction_csv(prediction_csv)
    pixel_mean_error = compute_pixel_mean_error(rows, resolve_path(entry.get("ground_truth_csv")))

    metrics = {
        "visible_rate": compute_visible_rate(rows),
        "pixel_mean_error": pixel_mean_error,
        "trajectory_continuity": compute_trajectory_continuity(rows),
        "bounce_precision": None,
        "bounce_recall": None,
        "action_stability": None,
        "inference_wall_time_seconds": elapsed,
    }

    return {
        "id": entry_id,
        "video": str(resolve_path(entry.get("video"))),
        "tags": entry.get("tags", []),
        "metrics": metrics,
        "artifacts": {
            "prediction_csv": str(prediction_csv),
            "stdout_log": completed.stdout.strip(),
            "stderr_log": completed.stderr.strip(),
        },
        "command": command,
    }


def build_report(manifest: dict[str, Any], args: argparse.Namespace, runs: list[dict[str, Any]]) -> dict[str, Any]:
    return {
        "model": args.model,
        "dataset_version": manifest["dataset_version"],
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "environment": {
            "python": sys.version.split()[0],
            "platform": platform.platform(),
            "machine": platform.machine(),
            "hostname": platform.node(),
        },
        "runs": runs,
        "aggregate_metrics": {
            "visible_rate": mean_or_none([run["metrics"]["visible_rate"] for run in runs]),
            "pixel_mean_error": mean_or_none([run["metrics"]["pixel_mean_error"] for run in runs]),
            "trajectory_continuity": mean_or_none(
                [run["metrics"]["trajectory_continuity"] for run in runs]
            ),
            "bounce_precision": mean_or_none([run["metrics"]["bounce_precision"] for run in runs]),
            "bounce_recall": mean_or_none([run["metrics"]["bounce_recall"] for run in runs]),
            "action_stability": mean_or_none([run["metrics"]["action_stability"] for run in runs]),
            "inference_wall_time_seconds": mean_or_none(
                [run["metrics"]["inference_wall_time_seconds"] for run in runs]
            ),
        },
    }


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    args.output_dir.mkdir(parents=True, exist_ok=True)

    manifest = load_manifest(args.manifest)
    runs = [benchmark_entry(entry, args) for entry in manifest["entries"]]
    report = build_report(manifest, args, runs)

    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    output_path = args.output_dir / f"{args.model}_benchmark_{timestamp}.json"
    with output_path.open("w", encoding="utf-8") as handle:
        json.dump(report, handle, indent=2, ensure_ascii=False)
        handle.write("\n")

    print(json.dumps({"report": str(output_path), "runs": len(runs)}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
