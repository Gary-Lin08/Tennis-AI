#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
from dataclasses import asdict, dataclass
from pathlib import Path

import cv2
import numpy as np


@dataclass
class ShotEvent:
    shot_id: int
    frame_num: int
    time_sec: float
    x_px: float
    y_px: float
    x_m: float | None
    y_m: float | None
    hitter_side: str | None
    angle_change_deg: float
    speed_before_kmh: float
    speed_after_kmh: float
    confidence: float


def read_track_csv(path: Path) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    frames: list[int] = []
    xs: list[float] = []
    ys: list[float] = []
    with path.open("r", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            frame = int(row["frame_num"])
            visible = int(row["visible"]) == 1
            frames.append(frame)
            if visible:
                xs.append(float(row["x"]))
                ys.append(float(row["y"]))
            else:
                xs.append(np.nan)
                ys.append(np.nan)

    idx = np.array(frames, dtype=np.int32)
    x = np.array(xs, dtype=np.float32)
    y = np.array(ys, dtype=np.float32)
    return idx, x, y


def interpolate_short_gaps(arr: np.ndarray, max_gap: int) -> np.ndarray:
    out = arr.copy()
    n = len(out)
    i = 0
    while i < n:
        if not np.isnan(out[i]):
            i += 1
            continue

        start = i
        while i < n and np.isnan(out[i]):
            i += 1
        end = i  # first non-nan after run

        gap_len = end - start
        left = start - 1
        right = end
        if gap_len <= max_gap and left >= 0 and right < n and not np.isnan(out[left]) and not np.isnan(out[right]):
            out[start:end] = np.linspace(out[left], out[right], gap_len + 2, dtype=np.float32)[1:-1]
    return out


def smooth_series(arr: np.ndarray, window: int) -> np.ndarray:
    if window <= 1:
        return arr
    if window % 2 == 0:
        window += 1

    out = arr.copy()
    half = window // 2
    n = len(arr)
    for i in range(n):
        lo = max(0, i - half)
        hi = min(n, i + half + 1)
        segment = arr[lo:hi]
        valid = segment[~np.isnan(segment)]
        if len(valid) >= max(2, window // 2):
            out[i] = float(np.mean(valid))
    return out


def transform_points(points_px: np.ndarray, h_img_to_court: np.ndarray | None) -> np.ndarray:
    points_m = np.full_like(points_px, np.nan, dtype=np.float32)
    if h_img_to_court is None:
        return points_m

    valid = ~np.isnan(points_px[:, 0]) & ~np.isnan(points_px[:, 1])
    if not np.any(valid):
        return points_m

    src = points_px[valid].astype(np.float32).reshape(-1, 1, 2)
    dst = cv2.perspectiveTransform(src, h_img_to_court.astype(np.float64)).reshape(-1, 2)
    points_m[valid] = dst
    return points_m


def compute_velocity(points: np.ndarray, fps: float) -> tuple[np.ndarray, np.ndarray]:
    n = len(points)
    vel = np.full((n, 2), np.nan, dtype=np.float32)
    speed_kmh = np.full(n, np.nan, dtype=np.float32)
    for i in range(1, n):
        p0 = points[i - 1]
        p1 = points[i]
        if np.any(np.isnan(p0)) or np.any(np.isnan(p1)):
            continue
        v = (p1 - p0) * float(fps)
        vel[i] = v
        speed_kmh[i] = float(np.linalg.norm(v) * 3.6)
    return vel, speed_kmh


def angle_between(v1: np.ndarray, v2: np.ndarray) -> float:
    n1 = float(np.linalg.norm(v1))
    n2 = float(np.linalg.norm(v2))
    if n1 < 1e-6 or n2 < 1e-6:
        return float("nan")
    cos_theta = float(np.dot(v1, v2) / (n1 * n2))
    cos_theta = max(-1.0, min(1.0, cos_theta))
    return float(np.degrees(np.arccos(cos_theta)))


def compute_angle_changes(vel: np.ndarray) -> np.ndarray:
    n = len(vel)
    angles = np.full(n, np.nan, dtype=np.float32)
    for i in range(1, n - 1):
        v_prev = vel[i]
        v_next = vel[i + 1]
        if np.any(np.isnan(v_prev)) or np.any(np.isnan(v_next)):
            continue
        angles[i] = angle_between(v_prev, v_next)
    return angles


def load_court_meta(court_json: Path | None) -> tuple[np.ndarray | None, float | None, float | None]:
    if court_json is None:
        return None, None, None
    payload = json.loads(court_json.read_text(encoding="utf-8"))
    h = np.array(payload["homography_img_to_court"], dtype=np.float64)
    width_m = float(payload["court_dimensions_m"]["width"])
    length_m = float(payload["court_dimensions_m"]["length"])
    return h, width_m, length_m


def mask_outside_metric_bounds(
    points_m: np.ndarray,
    court_width_m: float | None,
    court_length_m: float | None,
    margin_m: float = 2.0,
) -> np.ndarray:
    out = points_m.copy()
    if court_width_m is None or court_length_m is None:
        return out
    valid = ~np.isnan(out[:, 0]) & ~np.isnan(out[:, 1])
    inside = (
        (out[:, 0] >= -margin_m)
        & (out[:, 0] <= court_width_m + margin_m)
        & (out[:, 1] >= -margin_m)
        & (out[:, 1] <= court_length_m + margin_m)
    )
    out[valid & ~inside] = np.nan
    return out


def detect_shot_events(
    frame_ids: np.ndarray,
    points_px: np.ndarray,
    points_m: np.ndarray,
    speed_kmh: np.ndarray,
    angle_deg: np.ndarray,
    fps: float,
    min_angle_deg: float,
    min_speed_kmh: float,
    min_gap_frames: int,
    court_width_m: float | None,
    court_length_m: float | None,
) -> list[ShotEvent]:
    candidates: list[dict[str, float | int]] = []

    for i in range(2, len(frame_ids) - 2):
        if np.any(np.isnan(points_px[i])):
            continue

        a = angle_deg[i]
        sb = speed_kmh[i]
        sa = speed_kmh[i + 1]
        if np.isnan(a) or np.isnan(sb) or np.isnan(sa):
            continue
        if a < min_angle_deg:
            continue
        if min(sb, sa) < min_speed_kmh:
            continue

        # Local maximum for robustness.
        left = angle_deg[i - 1] if not np.isnan(angle_deg[i - 1]) else -1.0
        right = angle_deg[i + 1] if not np.isnan(angle_deg[i + 1]) else -1.0
        if a < left or a < right:
            continue

        score = float(a * np.sqrt(max((sb + sa) * 0.5, 1.0)))
        candidates.append({"idx": i, "score": score})

    # Temporal non-max suppression.
    kept: list[dict[str, float | int]] = []
    for c in candidates:
        idx = int(c["idx"])
        if kept and idx - int(kept[-1]["idx"]) < min_gap_frames:
            if float(c["score"]) > float(kept[-1]["score"]):
                kept[-1] = c
            continue
        kept.append(c)

    events: list[ShotEvent] = []
    for shot_id, c in enumerate(kept, start=1):
        i = int(c["idx"])
        x_px = float(points_px[i, 0])
        y_px = float(points_px[i, 1])

        x_m = None
        y_m = None
        side = None
        if not np.any(np.isnan(points_m[i])):
            x_m = float(points_m[i, 0])
            y_m = float(points_m[i, 1])
            if (
                court_width_m is not None
                and court_length_m is not None
                and 0.0 <= x_m <= court_width_m
                and 0.0 <= y_m <= court_length_m
            ):
                side = "near" if y_m >= (court_length_m * 0.5) else "far"

        a = float(angle_deg[i])
        sb = float(speed_kmh[i])
        sa = float(speed_kmh[i + 1])
        conf = min(1.0, (a / 90.0) * (min(sb, sa) / 80.0))

        events.append(
            ShotEvent(
                shot_id=shot_id,
                frame_num=int(frame_ids[i]),
                time_sec=float(frame_ids[i] / fps),
                x_px=x_px,
                y_px=y_px,
                x_m=x_m,
                y_m=y_m,
                hitter_side=side,
                angle_change_deg=a,
                speed_before_kmh=sb,
                speed_after_kmh=sa,
                confidence=float(conf),
            )
        )
    return events


def write_shots_json(path: Path, events: list[ShotEvent]) -> None:
    payload = {
        "num_shots": len(events),
        "shots": [asdict(e) for e in events],
    }
    path.write_text(json.dumps(payload, indent=2, ensure_ascii=False), encoding="utf-8")


def write_shots_csv(path: Path, events: list[ShotEvent]) -> None:
    with path.open("w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(
            [
                "shot_id",
                "frame_num",
                "time_sec",
                "x_px",
                "y_px",
                "x_m",
                "y_m",
                "hitter_side",
                "angle_change_deg",
                "speed_before_kmh",
                "speed_after_kmh",
                "confidence",
            ]
        )
        for e in events:
            w.writerow(
                [
                    e.shot_id,
                    e.frame_num,
                    round(e.time_sec, 3),
                    round(e.x_px, 2),
                    round(e.y_px, 2),
                    "" if e.x_m is None else round(e.x_m, 3),
                    "" if e.y_m is None else round(e.y_m, 3),
                    "" if e.hitter_side is None else e.hitter_side,
                    round(e.angle_change_deg, 2),
                    round(e.speed_before_kmh, 2),
                    round(e.speed_after_kmh, 2),
                    round(e.confidence, 3),
                ]
            )


def render_overlay(
    video_path: Path,
    out_path: Path,
    events: list[ShotEvent],
    hold_frames: int = 6,
) -> float:
    cap = cv2.VideoCapture(str(video_path))
    if not cap.isOpened():
        raise RuntimeError(f"Failed to open video: {video_path}")

    fps = float(cap.get(cv2.CAP_PROP_FPS) or 25.0)
    width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))

    writer = cv2.VideoWriter(str(out_path), cv2.VideoWriter_fourcc(*"mp4v"), fps, (width, height))

    i = 0
    while True:
        ok, frame = cap.read()
        if not ok:
            break

        draw = frame.copy()
        for e in events:
            delta = i - e.frame_num
            if 0 <= delta <= hold_frames:
                alpha = 1.0 - (delta / max(1, hold_frames + 1))
                radius = 7 + int(3 * alpha)
                cx = int(round(e.x_px))
                cy = int(round(e.y_px))
                cv2.circle(draw, (cx, cy), radius=radius, color=(0, 255, 255), thickness=2)
                cv2.putText(
                    draw,
                    f"SHOT {e.shot_id}",
                    (cx + 8, cy - 8),
                    cv2.FONT_HERSHEY_SIMPLEX,
                    0.45,
                    (0, 255, 255),
                    1,
                    cv2.LINE_AA,
                )

        writer.write(draw)
        i += 1

    writer.release()
    cap.release()
    return fps


def main() -> None:
    parser = argparse.ArgumentParser(description="Detect tennis shot events from ball track CSV.")
    parser.add_argument("--track-csv", type=Path, required=True, help="Ball track CSV from infer_tracknet_tennis.py")
    parser.add_argument("--video", type=Path, required=True, help="Source video path for FPS and optional overlay rendering")
    parser.add_argument("--court-json", type=Path, default=None, help="Optional court_detection json for metric speed and near/far side")
    parser.add_argument("--output-dir", type=Path, default=Path(__file__).resolve().parent / "outputs", help="Output directory")
    parser.add_argument("--prefix", type=str, default=None, help="Output prefix; default uses CSV stem")
    parser.add_argument("--min-angle", type=float, default=45.0, help="Minimum direction change (degrees)")
    parser.add_argument("--min-speed-kmh", type=float, default=12.0, help="Minimum speed before and after shot")
    parser.add_argument("--min-gap-frames", type=int, default=6, help="Minimum gap between shots")
    parser.add_argument("--max-interp-gap", type=int, default=2, help="Max missing-frame gap for interpolation")
    parser.add_argument("--smooth-window", type=int, default=5, help="Smoothing window for coordinates")
    parser.add_argument("--no-overlay", action="store_true", help="Skip overlay video rendering")
    args = parser.parse_args()

    args.output_dir.mkdir(parents=True, exist_ok=True)

    frame_ids, x_raw, y_raw = read_track_csv(args.track_csv)
    x = interpolate_short_gaps(x_raw, max_gap=args.max_interp_gap)
    y = interpolate_short_gaps(y_raw, max_gap=args.max_interp_gap)
    x = smooth_series(x, window=args.smooth_window)
    y = smooth_series(y, window=args.smooth_window)

    points_px = np.stack([x, y], axis=1)
    h_img_to_court, court_width_m, court_length_m = load_court_meta(args.court_json)
    points_m = transform_points(points_px, h_img_to_court=h_img_to_court)
    points_m = mask_outside_metric_bounds(points_m, court_width_m=court_width_m, court_length_m=court_length_m, margin_m=2.0)

    cap = cv2.VideoCapture(str(args.video))
    if not cap.isOpened():
        raise RuntimeError(f"Failed to open video: {args.video}")
    fps = float(cap.get(cv2.CAP_PROP_FPS) or 25.0)
    cap.release()

    # Prefer metric-space velocity when court homography is available.
    velocity_space = points_m if h_img_to_court is not None else points_px
    vel, speed_kmh = compute_velocity(velocity_space, fps=fps)
    angles = compute_angle_changes(vel)

    events = detect_shot_events(
        frame_ids=frame_ids,
        points_px=points_px,
        points_m=points_m,
        speed_kmh=speed_kmh,
        angle_deg=angles,
        fps=fps,
        min_angle_deg=args.min_angle,
        min_speed_kmh=args.min_speed_kmh,
        min_gap_frames=args.min_gap_frames,
        court_width_m=court_width_m,
        court_length_m=court_length_m,
    )

    stem = args.prefix or args.track_csv.stem.replace("_tracknet_tennis", "")
    json_path = args.output_dir / f"{stem}_shots.json"
    csv_path = args.output_dir / f"{stem}_shots.csv"
    write_shots_json(json_path, events)
    write_shots_csv(csv_path, events)

    overlay_path = args.output_dir / f"{stem}_shots_overlay.mp4"
    if not args.no_overlay:
        render_overlay(args.video, overlay_path, events)

    print(f"track_csv={args.track_csv.resolve()}")
    if args.court_json is not None:
        print(f"court_json={args.court_json.resolve()}")
    print(f"shots_json={json_path.resolve()}")
    print(f"shots_csv={csv_path.resolve()}")
    if not args.no_overlay:
        print(f"overlay_video={overlay_path.resolve()}")
    print(f"num_shots={len(events)}")


if __name__ == "__main__":
    main()
