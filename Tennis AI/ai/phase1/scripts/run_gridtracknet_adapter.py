#!/usr/bin/env python3
"""Adapter that runs an external GridTrackNet repo and writes Tennis AI CSV output."""

from __future__ import annotations

import argparse
import csv
import importlib.util
import json
from pathlib import Path
from typing import Any


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--video", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--repo", type=Path, required=True, help="Path to a GridTrackNet clone.")
    return parser.parse_args()


def import_predict_module(repo_root: Path):
    predict_path = repo_root / "Predict.py"
    if not predict_path.exists():
        raise FileNotFoundError(f"Predict.py not found in GridTrackNet repo: {predict_path}")

    spec = importlib.util.spec_from_file_location("gridtracknet_predict", predict_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Unable to load Predict.py from {predict_path}")

    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def load_frames(video_path: Path):
    try:
        import cv2
    except ModuleNotFoundError as exc:
        raise RuntimeError("opencv-python is required for the GridTrackNet adapter.") from exc

    capture = cv2.VideoCapture(str(video_path))
    if not capture.isOpened():
        raise RuntimeError(f"Unable to open video: {video_path}")

    frames = []
    while True:
        ok, frame = capture.read()
        if not ok:
            break
        frames.append(frame)
    capture.release()
    if not frames:
        raise RuntimeError(f"No frames decoded from {video_path}")
    return frames


def normalize_prediction(prediction: Any) -> tuple[int, float, float]:
    if isinstance(prediction, dict):
        visible = int(prediction.get("visible", 1))
        return visible, float(prediction.get("x", -1)), float(prediction.get("y", -1))

    if isinstance(prediction, (list, tuple)):
        if len(prediction) >= 3:
            return int(prediction[0]), float(prediction[1]), float(prediction[2])
        if len(prediction) == 2:
            x, y = float(prediction[0]), float(prediction[1])
            visible = 1 if x >= 0 and y >= 0 else 0
            return visible, x, y

    raise TypeError(f"Unsupported GridTrackNet prediction item: {prediction!r}")


def normalize_predictions(raw_predictions: Any) -> list[tuple[int, float, float]]:
    if hasattr(raw_predictions, "tolist"):
        raw_predictions = raw_predictions.tolist()
    if isinstance(raw_predictions, dict):
        if {"visible", "x", "y"}.issubset(raw_predictions.keys()):
            visible = raw_predictions["visible"]
            xs = raw_predictions["x"]
            ys = raw_predictions["y"]
            return [
                (int(visible[index]), float(xs[index]), float(ys[index]))
                for index in range(len(visible))
            ]
        raise TypeError(f"Unsupported GridTrackNet prediction dict shape: {raw_predictions.keys()}")

    if not isinstance(raw_predictions, list):
        raise TypeError(f"Unsupported GridTrackNet predictions type: {type(raw_predictions)!r}")

    return [normalize_prediction(item) for item in raw_predictions]


def main() -> int:
    args = parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    if not args.video.exists():
        raise FileNotFoundError(f"Video not found: {args.video}")

    frames = load_frames(args.video)
    if len(frames) < 5:
        raise RuntimeError("GridTrackNet requires at least 5 frames.")

    usable_frame_count = len(frames) - (len(frames) % 5)
    usable_frames = frames[:usable_frame_count]

    module = import_predict_module(args.repo)
    if not hasattr(module, "getPredictions"):
        raise AttributeError("GridTrackNet Predict.py does not expose getPredictions(frames, isBGRFormat=True).")

    raw_predictions = module.getPredictions(usable_frames, isBGRFormat=True)
    predictions = normalize_predictions(raw_predictions)
    if len(predictions) != usable_frame_count:
        raise RuntimeError(
            f"GridTrackNet returned {len(predictions)} predictions for {usable_frame_count} frames."
        )

    output_csv = args.output_dir / f"{args.video.stem}_gridtracknet.csv"
    with output_csv.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(["frame_num", "visible", "x", "y"])
        for frame_index, (visible, x, y) in enumerate(predictions):
            writer.writerow([frame_index, visible, x, y])

    print(
        json.dumps(
            {
                "output_csv": str(output_csv),
                "processed_frames": usable_frame_count,
                "trimmed_frames": len(frames) - usable_frame_count,
            },
            ensure_ascii=False,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
