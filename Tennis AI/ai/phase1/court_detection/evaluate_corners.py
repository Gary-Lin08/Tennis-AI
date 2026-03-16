#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path

import cv2
import numpy as np

COURT_WIDTH_M = 10.97
COURT_LENGTH_M = 23.77


def ordered_corner_names() -> list[str]:
    return ["top_left", "top_right", "bottom_right", "bottom_left"]


def parse_corners(payload: dict, key_hint: str | None = None) -> np.ndarray:
    if "corners_px" in payload:
        node = payload["corners_px"]
    elif key_hint and key_hint in payload:
        return parse_corners(payload[key_hint], key_hint=None)
    else:
        raise ValueError("No corners found. Expected 'corners_px' or a keyed nested object.")

    try:
        corners = np.array([node[name] for name in ordered_corner_names()], dtype=np.float32)
    except KeyError as exc:
        raise ValueError(f"Missing corner in payload: {exc}") from exc

    if corners.shape != (4, 2):
        raise ValueError(f"Corner array must be shape (4,2), got {corners.shape}")
    return corners


def world_reference_points() -> np.ndarray:
    return np.array(
        [
            [0.0, 0.0],
            [COURT_WIDTH_M, 0.0],
            [COURT_WIDTH_M, COURT_LENGTH_M],
            [0.0, COURT_LENGTH_M],
        ],
        dtype=np.float32,
    )


def main() -> None:
    parser = argparse.ArgumentParser(description="Evaluate predicted court corners against GT corners in centimeters.")
    parser.add_argument("--prediction", required=True, type=Path, help="Prediction json from detect_court.py")
    parser.add_argument("--gt", required=True, type=Path, help="Ground-truth json with corners_px")
    parser.add_argument("--key", type=str, default=None, help="Optional key for nested GT object")
    parser.add_argument("--output-json", type=Path, default=None, help="Optional output json for metrics")
    args = parser.parse_args()

    pred_obj = json.loads(args.prediction.read_text(encoding="utf-8"))
    gt_obj = json.loads(args.gt.read_text(encoding="utf-8"))

    pred_corners = parse_corners(pred_obj, key_hint=args.key)
    gt_corners = parse_corners(gt_obj, key_hint=args.key)
    world_pts = world_reference_points()

    # Ground-truth image->court mapping; this lets us convert pixel offset to meters.
    h_gt = cv2.getPerspectiveTransform(gt_corners.astype(np.float32), world_pts.astype(np.float32))
    pred_world = cv2.perspectiveTransform(pred_corners.reshape(1, 4, 2), h_gt)[0]

    metric_errors_m = np.linalg.norm(pred_world - world_pts, axis=1)
    metric_errors_cm = metric_errors_m * 100.0
    pixel_errors = np.linalg.norm(pred_corners - gt_corners, axis=1)

    names = ordered_corner_names()
    rows = []
    for i, name in enumerate(names):
        rows.append(
            {
                "corner": name,
                "pixel_error": float(pixel_errors[i]),
                "metric_error_cm": float(metric_errors_cm[i]),
            }
        )

    mean_cm = float(np.mean(metric_errors_cm))
    max_cm = float(np.max(metric_errors_cm))
    mean_px = float(np.mean(pixel_errors))
    max_px = float(np.max(pixel_errors))

    print("Per-corner error:")
    for row in rows:
        print(
            f"- {row['corner']}: "
            f"{row['pixel_error']:.2f} px, {row['metric_error_cm']:.2f} cm"
        )
    print(f"Mean error: {mean_px:.2f} px, {mean_cm:.2f} cm")
    print(f"Max error:  {max_px:.2f} px, {max_cm:.2f} cm")

    output_payload = {
        "prediction": str(args.prediction.resolve()),
        "ground_truth": str(args.gt.resolve()),
        "metrics": {
            "mean_pixel_error": mean_px,
            "max_pixel_error": max_px,
            "mean_metric_error_cm": mean_cm,
            "max_metric_error_cm": max_cm,
        },
        "per_corner": rows,
    }

    if args.output_json is not None:
        args.output_json.parent.mkdir(parents=True, exist_ok=True)
        args.output_json.write_text(json.dumps(output_payload, indent=2), encoding="utf-8")
        print(f"Metrics json written to: {args.output_json.resolve()}")


if __name__ == "__main__":
    main()
