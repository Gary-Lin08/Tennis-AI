#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path

import cv2
import numpy as np
import torch
from tqdm import tqdm


def select_device(device_arg: str) -> str:
    if device_arg != "auto":
        return device_arg
    if torch.cuda.is_available():
        return "cuda"
    if hasattr(torch.backends, "mps") and torch.backends.mps.is_available():
        return "mps"
    return "cpu"


def load_model(weights_path: Path, device: str) -> torch.nn.Module:
    import sys

    repo_dir = Path(__file__).resolve().parents[1] / "TrackNet-yastrebksv"
    if str(repo_dir) not in sys.path:
        sys.path.insert(0, str(repo_dir))
    from model import BallTrackerNet  # type: ignore

    model = BallTrackerNet()
    state = torch.load(str(weights_path), map_location=device)
    model.load_state_dict(state)
    model = model.to(device)
    model.eval()
    return model


def read_video_frames(video_path: Path) -> tuple[list[np.ndarray], int]:
    cap = cv2.VideoCapture(str(video_path))
    if not cap.isOpened():
        raise RuntimeError(f"Failed to open video: {video_path}")
    fps = int(cap.get(cv2.CAP_PROP_FPS)) or 25
    frames: list[np.ndarray] = []
    while True:
        ok, frame = cap.read()
        if not ok:
            break
        frames.append(frame)
    cap.release()
    if not frames:
        raise RuntimeError(f"No frames read from video: {video_path}")
    return frames, fps


def load_court_polygon(
    court_json_path: Path | None,
    frame_width: int,
    frame_height: int,
) -> np.ndarray | None:
    if court_json_path is None:
        return None
    payload = json.loads(court_json_path.read_text(encoding="utf-8"))
    corners = payload.get("corners_px", {})
    size = payload.get("image_size_px", {})
    w_ref = float(size.get("width", frame_width))
    h_ref = float(size.get("height", frame_height))
    sx = float(frame_width) / max(w_ref, 1.0)
    sy = float(frame_height) / max(h_ref, 1.0)

    order = ["top_left", "top_right", "bottom_right", "bottom_left"]
    pts: list[list[float]] = []
    for key in order:
        p = corners.get(key)
        if not p or len(p) != 2:
            raise ValueError(f"Invalid court json corners: missing {key}")
        pts.append([float(p[0]) * sx, float(p[1]) * sy])
    return np.array(pts, dtype=np.float32)


def extract_candidates(
    output_1d: np.ndarray,
    class_threshold: int = 40,
    min_area: int = 3,
    max_area: int = 180,
) -> list[dict[str, float]]:
    # output_1d is argmax label map flattened to (360*640,), labels in [0, 255].
    label_map = output_1d.reshape((360, 640)).astype(np.uint8)
    _, binary = cv2.threshold(label_map, class_threshold, 255, cv2.THRESH_BINARY)
    binary = cv2.morphologyEx(binary, cv2.MORPH_OPEN, np.ones((2, 2), np.uint8))

    comp_count, comp_label, stats, centroids = cv2.connectedComponentsWithStats(binary, 8)
    candidates: list[dict[str, float]] = []
    for k in range(1, comp_count):
        area = int(stats[k, cv2.CC_STAT_AREA])
        box_w = int(stats[k, cv2.CC_STAT_WIDTH])
        box_h = int(stats[k, cv2.CC_STAT_HEIGHT])
        if area < min_area or area > max_area:
            continue
        if box_w <= 0 or box_h <= 0:
            continue
        if box_w > 18 or box_h > 18:
            continue
        aspect = max(float(box_w) / float(box_h), float(box_h) / float(box_w))
        if aspect > 2.4:
            continue
        ys, xs = np.where(comp_label == k)
        if len(xs) == 0:
            continue
        vals = label_map[ys, xs]
        peak = float(np.max(vals))
        mean_score = float(np.mean(vals))
        x = float(centroids[k, 0])
        y = float(centroids[k, 1])
        score = peak + 0.15 * mean_score + 0.01 * float(area)
        candidates.append({"x": x, "y": y, "area": float(area), "score": score})
    return candidates


def point_inside_court(
    x: float,
    y: float,
    court_polygon: np.ndarray | None,
    margin_px: float,
) -> bool:
    if court_polygon is None:
        return True
    dist = cv2.pointPolygonTest(court_polygon.astype(np.float32), (float(x), float(y)), measureDist=True)
    return dist >= -margin_px


def last_valid_points(
    track: list[tuple[float | None, float | None]],
    count: int = 2,
) -> list[tuple[float, float]]:
    out: list[tuple[float, float]] = []
    for x, y in reversed(track):
        if x is None or y is None:
            continue
        out.append((float(x), float(y)))
        if len(out) >= count:
            break
    return out


def choose_best_candidate(
    candidates: list[dict[str, float]],
    history: list[tuple[float | None, float | None]],
    max_speed: float,
    max_accel: float,
    predict_radius: float,
) -> tuple[float | None, float | None]:
    if not candidates:
        return None, None

    prev = last_valid_points(history, count=2)
    p1 = prev[0] if len(prev) >= 1 else None
    p2 = prev[1] if len(prev) >= 2 else None

    best_score = -1e18
    best_xy: tuple[float | None, float | None] = (None, None)
    for c in candidates:
        x = float(c["x"])
        y = float(c["y"])
        score = float(c["score"])

        if p1 is not None:
            vx1 = x - p1[0]
            vy1 = y - p1[1]
            speed = float(np.hypot(vx1, vy1))
            if speed > max_speed:
                continue
            pred_x, pred_y = p1[0], p1[1]
            if p2 is not None:
                vx0 = p1[0] - p2[0]
                vy0 = p1[1] - p2[1]
                pred_x = p1[0] + vx0
                pred_y = p1[1] + vy0
                accel = float(np.hypot(vx1 - vx0, vy1 - vy0))
                if accel > max_accel:
                    continue
            deviation = float(np.hypot(x - pred_x, y - pred_y))
            if deviation > predict_radius:
                continue
            score -= 0.7 * deviation
            score -= 0.2 * speed
        if score > best_score:
            best_score = score
            best_xy = (x, y)

    return best_xy


def infer_ball_track(
    frames: list[np.ndarray],
    model: torch.nn.Module,
    device: str,
    class_threshold: int,
    min_area: int,
    max_area: int,
    max_speed: float,
    max_accel: float,
    predict_radius: float,
    court_polygon: np.ndarray | None,
    court_margin: float,
) -> list[tuple[float | None, float | None]]:
    h, w = frames[0].shape[:2]
    sx = w / 640.0
    sy = h / 360.0

    track: list[tuple[float | None, float | None]] = [(None, None), (None, None)]
    for i in tqdm(range(2, len(frames)), desc="Infer"):
        cur = cv2.resize(frames[i], (640, 360))
        prev = cv2.resize(frames[i - 1], (640, 360))
        prev2 = cv2.resize(frames[i - 2], (640, 360))
        inp = np.concatenate((cur, prev, prev2), axis=2).astype(np.float32) / 255.0
        inp = np.expand_dims(np.transpose(inp, (2, 0, 1)), axis=0)

        with torch.no_grad():
            out = model(torch.from_numpy(inp).float().to(device))
        pred = out.argmax(dim=1).detach().cpu().numpy()[0]
        cands_360 = extract_candidates(
            pred,
            class_threshold=class_threshold,
            min_area=min_area,
            max_area=max_area,
        )
        scaled_candidates: list[dict[str, float]] = []
        for c in cands_360:
            x0 = float(c["x"] * sx)
            y0 = float(c["y"] * sy)
            if not point_inside_court(x0, y0, court_polygon=court_polygon, margin_px=court_margin):
                continue
            scaled_candidates.append({"x": x0, "y": y0, "area": c["area"], "score": c["score"]})

        x, y = choose_best_candidate(
            scaled_candidates,
            history=track,
            max_speed=max_speed,
            max_accel=max_accel,
            predict_radius=predict_radius,
        )
        if x is None or y is None:
            track.append((None, None))
        else:
            track.append((x, y))
    return track


def remove_outliers(track: list[tuple[float | None, float | None]], max_dist: float = 100.0) -> list[tuple[float | None, float | None]]:
    if len(track) < 3:
        return track

    dists = [-1.0, -1.0]
    for i in range(2, len(track)):
        p = track[i]
        q = track[i - 1]
        if p[0] is None or q[0] is None:
            dists.append(-1.0)
        else:
            dists.append(float(np.hypot(p[0] - q[0], p[1] - q[1])))

    outliers = [i for i, d in enumerate(dists) if d > max_dist]
    for i in outliers:
        if i + 1 >= len(dists):
            continue
        if dists[i + 1] > max_dist or dists[i + 1] == -1:
            track[i] = (None, None)
        elif i - 1 >= 0 and dists[i - 1] == -1:
            track[i - 1] = (None, None)
    return track


def remove_static_false_positives(
    track: list[tuple[float | None, float | None]],
    window: int = 12,
    max_span_px: float = 6.0,
) -> list[tuple[float | None, float | None]]:
    if len(track) < window:
        return track
    cleaned = track[:]
    for i in range(0, len(track) - window + 1):
        segment = cleaned[i : i + window]
        pts = np.array([[p[0], p[1]] for p in segment if p[0] is not None], dtype=np.float32)
        if len(pts) < int(window * 0.8):
            continue
        span_x = float(np.max(pts[:, 0]) - np.min(pts[:, 0]))
        span_y = float(np.max(pts[:, 1]) - np.min(pts[:, 1]))
        if max(span_x, span_y) <= max_span_px:
            for j in range(i, i + window):
                cleaned[j] = (None, None)
    return cleaned


def split_track(track: list[tuple[float | None, float | None]], max_gap: int = 4, max_dist_gap: float = 80.0, min_track: int = 5) -> list[tuple[int, int]]:
    flags = [0 if p[0] is not None else 1 for p in track]
    groups: list[tuple[int, int]] = []
    cur = flags[0]
    cnt = 0
    for f in flags:
        if f == cur:
            cnt += 1
        else:
            groups.append((cur, cnt))
            cur = f
            cnt = 1
    groups.append((cur, cnt))

    result: list[tuple[int, int]] = []
    cursor = 0
    min_value = 0
    for i, (k, l) in enumerate(groups):
        if k == 1 and 0 < i < len(groups) - 1:
            p1 = track[cursor - 1]
            p2 = track[cursor + l]
            if p1[0] is not None and p2[0] is not None:
                dist = float(np.hypot(p1[0] - p2[0], p1[1] - p2[1]))
            else:
                dist = np.inf
            if l >= max_gap or (dist / max(l, 1)) > max_dist_gap:
                if cursor - min_value > min_track:
                    result.append((min_value, cursor))
                min_value = cursor + l - 1
        cursor += l
    if len(track) - min_value > min_track:
        result.append((min_value, len(track)))
    return result


def interpolate_track(track: list[tuple[float | None, float | None]]) -> list[tuple[float | None, float | None]]:
    x = np.array([p[0] if p[0] is not None else np.nan for p in track], dtype=np.float32)
    y = np.array([p[1] if p[1] is not None else np.nan for p in track], dtype=np.float32)
    if np.all(np.isnan(x)) or np.all(np.isnan(y)):
        return track

    x_idx = np.arange(len(x))
    y_idx = np.arange(len(y))
    if np.any(np.isnan(x)):
        mask = ~np.isnan(x)
        x[np.isnan(x)] = np.interp(x_idx[np.isnan(x)], x_idx[mask], x[mask])
    if np.any(np.isnan(y)):
        mask = ~np.isnan(y)
        y[np.isnan(y)] = np.interp(y_idx[np.isnan(y)], y_idx[mask], y[mask])
    return [(float(x[i]), float(y[i])) for i in range(len(track))]


def write_outputs(
    frames: list[np.ndarray],
    track: list[tuple[float | None, float | None]],
    out_video: Path,
    out_csv: Path,
    fps: int,
    trace: int = 7,
    dot_radius: int = 3,
) -> tuple[int, int]:
    h, w = frames[0].shape[:2]
    writer = cv2.VideoWriter(str(out_video), cv2.VideoWriter_fourcc(*"mp4v"), fps, (w, h))
    visible_count = 0

    with out_csv.open("w", newline="", encoding="utf-8") as f:
        cw = csv.writer(f)
        cw.writerow(["frame_num", "visible", "x", "y"])
        for i, frame in enumerate(frames):
            draw = frame.copy()
            for k in range(trace):
                j = i - k
                if j <= 0:
                    break
                x, y = track[j]
                if x is None or y is None:
                    break
                # Small solid dot with short fading trail; default size is just above tennis-ball visual size.
                r = max(1, dot_radius - (k // 2))
                cv2.circle(draw, (int(round(x)), int(round(y))), radius=r, color=(0, 0, 255), thickness=-1)

            x, y = track[i]
            if x is None or y is None:
                cw.writerow([i, 0, 0, 0])
            else:
                visible_count += 1
                cw.writerow([i, 1, int(round(x)), int(round(y))])
            writer.write(draw)
    writer.release()
    return visible_count, len(frames)


def main() -> None:
    parser = argparse.ArgumentParser(description="Track tennis ball with yastrebksv/TrackNet pretrained weights.")
    parser.add_argument("--video", type=Path, required=True, help="Input video path.")
    parser.add_argument(
        "--weights",
        type=Path,
        default=Path(__file__).resolve().parents[1] / "TrackNet-yastrebksv" / "weights_tracknet.pth",
        help="Path to pretrained TrackNet weights.",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path(__file__).resolve().parent / "outputs",
        help="Output directory.",
    )
    parser.add_argument("--device", type=str, default="auto", help="auto|cpu|mps|cuda")
    parser.add_argument("--max-dist", type=float, default=120.0, help="Outlier max movement distance between frames.")
    parser.add_argument("--trace", type=int, default=7, help="Trace length for drawing.")
    parser.add_argument("--dot-radius", type=int, default=3, help="Rendered ball dot radius in pixels.")
    parser.add_argument("--extrapolate", action="store_true", help="Enable interpolation in stable subtracks.")
    parser.add_argument("--class-threshold", type=int, default=40, help="Argmax label threshold for candidate mask (0-255).")
    parser.add_argument("--heat-threshold", dest="class_threshold", type=int, help=argparse.SUPPRESS)
    parser.add_argument("--min-area", type=int, default=3, help="Minimum connected-component area for candidates.")
    parser.add_argument("--max-area", type=int, default=180, help="Maximum connected-component area for candidates.")
    parser.add_argument("--max-speed", type=float, default=85.0, help="Max inter-frame speed (pixels/frame).")
    parser.add_argument("--max-accel", type=float, default=95.0, help="Max acceleration (pixels/frame^2).")
    parser.add_argument("--predict-radius", type=float, default=70.0, help="Max deviation from constant-velocity prediction.")
    parser.add_argument("--court-json", type=Path, default=None, help="Optional court_detection json to restrict detections to court region.")
    parser.add_argument("--court-margin", type=float, default=18.0, help="Outside-court tolerance in pixels when --court-json is used.")
    parser.add_argument("--remove-static", action="store_true", help="Drop long static pseudo-points.")
    args = parser.parse_args()

    args.output_dir.mkdir(parents=True, exist_ok=True)
    device = select_device(args.device)

    model = load_model(args.weights, device=device)
    frames, fps = read_video_frames(args.video)
    h, w = frames[0].shape[:2]
    court_polygon = load_court_polygon(args.court_json, frame_width=w, frame_height=h)
    track = infer_ball_track(
        frames,
        model,
        device=device,
        class_threshold=args.class_threshold,
        min_area=args.min_area,
        max_area=args.max_area,
        max_speed=args.max_speed,
        max_accel=args.max_accel,
        predict_radius=args.predict_radius,
        court_polygon=court_polygon,
        court_margin=args.court_margin,
    )
    track = remove_outliers(track, max_dist=args.max_dist)
    if args.remove_static:
        track = remove_static_false_positives(track)
    if args.extrapolate:
        for start, end in split_track(track):
            track[start:end] = interpolate_track(track[start:end])

    stem = args.video.stem
    out_video = args.output_dir / f"{stem}_tracknet_tennis.mp4"
    out_csv = args.output_dir / f"{stem}_tracknet_tennis.csv"
    visible, total = write_outputs(
        frames,
        track,
        out_video,
        out_csv,
        fps=fps,
        trace=args.trace,
        dot_radius=args.dot_radius,
    )

    print(f"device={device}")
    if args.court_json is not None:
        print(f"court_json={args.court_json.resolve()}")
    print(f"output_video={out_video.resolve()}")
    print(f"output_csv={out_csv.resolve()}")
    print(f"visible_frames={visible}/{total} ({(visible / total * 100.0):.2f}%)")


if __name__ == "__main__":
    main()
