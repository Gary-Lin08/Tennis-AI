#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Optional

import cv2
import numpy as np

COURT_WIDTH_M = 10.97
COURT_LENGTH_M = 23.77


@dataclass
class BaselineDetection:
    corners: np.ndarray  # [tl, tr, br, bl], shape (4, 2)
    top_segment: np.ndarray  # [x1, y1, x2, y2]
    bottom_segment: np.ndarray  # [x1, y1, x2, y2]
    score: float
    frame_index: int


def is_video(path: Path) -> bool:
    return path.suffix.lower() in {".mp4", ".mov", ".mkv", ".avi", ".m4v"}


def is_image(path: Path) -> bool:
    return path.suffix.lower() in {".jpg", ".jpeg", ".png", ".bmp", ".webp"}


def line_length(seg: np.ndarray) -> float:
    x1, y1, x2, y2 = seg.astype(float)
    return float(np.hypot(x2 - x1, y2 - y1))


def line_angle_deg(seg: np.ndarray) -> float:
    x1, y1, x2, y2 = seg.astype(float)
    return float(np.degrees(np.arctan2(y2 - y1, x2 - x1)))


def normalize_line_theta(angle_deg: float) -> float:
    return float((angle_deg + 180.0) % 180.0)


def ordered_endpoints(seg: np.ndarray) -> np.ndarray:
    p1 = np.array([float(seg[0]), float(seg[1])], dtype=np.float32)
    p2 = np.array([float(seg[2]), float(seg[3])], dtype=np.float32)
    if p1[0] <= p2[0]:
        return np.stack([p1, p2], axis=0)
    return np.stack([p2, p1], axis=0)


def line_intersection(seg_a: np.ndarray, seg_b: np.ndarray) -> Optional[np.ndarray]:
    x1, y1, x2, y2 = [float(v) for v in seg_a]
    x3, y3, x4, y4 = [float(v) for v in seg_b]
    den = (x1 - x2) * (y3 - y4) - (y1 - y2) * (x3 - x4)
    if abs(den) < 1e-6:
        return None
    num_x = (x1 * y2 - y1 * x2) * (x3 - x4) - (x1 - x2) * (x3 * y4 - y3 * x4)
    num_y = (x1 * y2 - y1 * x2) * (y3 - y4) - (y1 - y2) * (x3 * y4 - y3 * x4)
    return np.array([num_x / den, num_y / den], dtype=np.float32)


def pick_sideline_intersections(
    lines: np.ndarray,
    top_seg: np.ndarray,
    bottom_seg: np.ndarray,
    width: int,
    height: int,
) -> Optional[np.ndarray]:
    top_y = float((top_seg[1] + top_seg[3]) * 0.5)
    bottom_y = float((bottom_seg[1] + bottom_seg[3]) * 0.5)

    left_pool: list[np.ndarray] = []
    right_pool: list[np.ndarray] = []
    for line in lines[:, 0, :]:
        seg = line.astype(np.float32)
        length = line_length(seg)
        theta = normalize_line_theta(line_angle_deg(seg))
        x_mid = float((seg[0] + seg[2]) * 0.5)
        y_min = float(min(seg[1], seg[3]))
        y_max = float(max(seg[1], seg[3]))

        if length < height * 0.20:
            continue
        if not (50.0 <= theta <= 130.0):
            continue
        if y_max < top_y - 14 or y_min > bottom_y + 14:
            continue
        if x_mid <= width * 0.5:
            left_pool.append(seg)
        else:
            right_pool.append(seg)

    if not left_pool or not right_pool:
        return None

    best_score = -1.0
    best_corners: Optional[np.ndarray] = None
    for left in left_pool:
        for right in right_pool:
            tl = line_intersection(top_seg, left)
            tr = line_intersection(top_seg, right)
            bl = line_intersection(bottom_seg, left)
            br = line_intersection(bottom_seg, right)
            if tl is None or tr is None or bl is None or br is None:
                continue

            top_width = float(np.linalg.norm(tr - tl))
            bottom_width = float(np.linalg.norm(br - bl))
            if top_width < width * 0.20 or bottom_width < width * 0.34:
                continue
            ratio = bottom_width / max(top_width, 1e-6)
            if not (1.05 <= ratio <= 2.8):
                continue

            if not (tl[0] < tr[0] and bl[0] < br[0]):
                continue
            all_pts = np.stack([tl, tr, br, bl], axis=0)
            if np.min(all_pts[:, 0]) < -width * 0.18 or np.max(all_pts[:, 0]) > width * 1.18:
                continue
            if np.min(all_pts[:, 1]) < -height * 0.18 or np.max(all_pts[:, 1]) > height * 1.18:
                continue

            # Prior: a plausible court has long baselines and strong vertical span.
            score = top_width + bottom_width + 1.6 * float(bottom_y - top_y)
            if score > best_score:
                best_score = score
                best_corners = all_pts.astype(np.float32)

    return best_corners


def preprocess_line_mask(frame: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    hsv = cv2.cvtColor(frame, cv2.COLOR_BGR2HSV)
    gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)

    # White line prior in HSV + top-hat enhancement for bright thin structures.
    white_mask = cv2.inRange(hsv, (0, 0, 120), (180, 105, 255))
    tophat = cv2.morphologyEx(gray, cv2.MORPH_TOPHAT, np.ones((9, 9), np.uint8))
    _, bright_mask = cv2.threshold(tophat, 22, 255, cv2.THRESH_BINARY)

    mask = cv2.bitwise_or(white_mask, bright_mask)
    mask = cv2.medianBlur(mask, 3)
    mask = cv2.morphologyEx(mask, cv2.MORPH_OPEN, np.ones((2, 2), np.uint8))
    mask = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, np.ones((3, 3), np.uint8))

    edges = cv2.Canny(mask, 30, 120)
    return mask, edges


def detect_baselines_in_frame(frame: np.ndarray, frame_index: int = 0) -> Optional[BaselineDetection]:
    h, w = frame.shape[:2]
    _, edges = preprocess_line_mask(frame)

    lines = cv2.HoughLinesP(
        edges,
        rho=1,
        theta=np.pi / 180,
        threshold=max(20, w // 28),
        minLineLength=max(30, int(w * 0.08)),
        maxLineGap=max(10, int(w * 0.02)),
    )
    if lines is None:
        return None

    horizontal_candidates: list[np.ndarray] = []
    for line in lines[:, 0, :]:
        seg = line.astype(np.float32)
        length = line_length(seg)
        angle = line_angle_deg(seg)
        y_mid = (seg[1] + seg[3]) * 0.5

        if abs(angle) > 10:
            continue
        if length < w * 0.15:
            continue
        if y_mid < h * 0.04 or y_mid > h * 0.98:
            continue
        horizontal_candidates.append(seg)

    if not horizontal_candidates:
        return None

    top_candidates = []
    bottom_candidates = []
    for seg in horizontal_candidates:
        y_mid = float((seg[1] + seg[3]) * 0.5)
        length = line_length(seg)
        if h * 0.10 <= y_mid <= h * 0.52 and length >= w * 0.22:
            top_candidates.append(seg)
        if h * 0.54 <= y_mid <= h * 0.88 and length >= w * 0.38:
            bottom_candidates.append(seg)

    if not top_candidates or not bottom_candidates:
        return None

    top_seg = max(top_candidates, key=lambda s: (line_length(s), -((s[1] + s[3]) * 0.5)))
    bottom_seg = max(bottom_candidates, key=lambda s: (line_length(s), ((s[1] + s[3]) * 0.5)))

    top_endpoints = ordered_endpoints(top_seg)
    bottom_endpoints = ordered_endpoints(bottom_seg)

    tl = top_endpoints[0]
    tr = top_endpoints[1]
    bl = bottom_endpoints[0]
    br = bottom_endpoints[1]

    top_y = float((tl[1] + tr[1]) * 0.5)
    bottom_y = float((bl[1] + br[1]) * 0.5)
    if bottom_y <= top_y + 20:
        return None

    top_width = float(np.linalg.norm(tr - tl))
    bottom_width = float(np.linalg.norm(br - bl))
    if top_width < w * 0.22 or bottom_width < w * 0.34:
        return None

    width_ratio = bottom_width / max(top_width, 1e-6)
    if not (1.05 <= width_ratio <= 2.8):
        return None

    corners = pick_sideline_intersections(lines, top_seg, bottom_seg, w, h)
    if corners is None:
        # Fallback for difficult frames: use baseline endpoints.
        corners = np.stack([tl, tr, br, bl], axis=0).astype(np.float32)

    # Heuristic confidence: prefer larger vertical span and longer baselines.
    score = top_width + bottom_width + 1.5 * (bottom_y - top_y)

    return BaselineDetection(
        corners=corners,
        top_segment=top_seg.astype(np.float32),
        bottom_segment=bottom_seg.astype(np.float32),
        score=float(score),
        frame_index=frame_index,
    )


def sample_video_frames(cap: cv2.VideoCapture, max_samples: int) -> Iterable[tuple[int, np.ndarray]]:
    total = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    if total <= 0:
        return []

    sample_count = max(1, min(max_samples, total))
    frame_ids = np.linspace(0, total - 1, sample_count, dtype=np.int32)

    sampled: list[tuple[int, np.ndarray]] = []
    for frame_id in np.unique(frame_ids):
        cap.set(cv2.CAP_PROP_POS_FRAMES, int(frame_id))
        ok, frame = cap.read()
        if ok and frame is not None:
            sampled.append((int(frame_id), frame))
    return sampled


def aggregate_detections(detections: list[BaselineDetection]) -> BaselineDetection:
    anchor = max(detections, key=lambda d: d.score)
    anchor_top_y = float((anchor.corners[0, 1] + anchor.corners[1, 1]) * 0.5)
    anchor_bottom_y = float((anchor.corners[2, 1] + anchor.corners[3, 1]) * 0.5)

    similar = [
        d
        for d in detections
        if abs(((d.corners[0, 1] + d.corners[1, 1]) * 0.5) - anchor_top_y) <= 22
        and abs(((d.corners[2, 1] + d.corners[3, 1]) * 0.5) - anchor_bottom_y) <= 22
    ]
    if not similar:
        similar = [anchor]

    corners_stack = np.stack([d.corners for d in similar], axis=0)
    corners = np.median(corners_stack, axis=0).astype(np.float32)

    top_seg = np.array([corners[0, 0], corners[0, 1], corners[1, 0], corners[1, 1]], dtype=np.float32)
    bottom_seg = np.array([corners[3, 0], corners[3, 1], corners[2, 0], corners[2, 1]], dtype=np.float32)
    score = float(np.median([d.score for d in similar]))

    return BaselineDetection(
        corners=corners,
        top_segment=top_seg,
        bottom_segment=bottom_seg,
        score=score,
        frame_index=anchor.frame_index,
    )


def compute_homography(corners: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    src = corners.astype(np.float32)  # [tl, tr, br, bl]
    dst = np.array(
        [
            [0.0, 0.0],
            [COURT_WIDTH_M, 0.0],
            [COURT_WIDTH_M, COURT_LENGTH_M],
            [0.0, COURT_LENGTH_M],
        ],
        dtype=np.float32,
    )
    h_img_to_court = cv2.getPerspectiveTransform(src, dst)
    h_court_to_img = cv2.getPerspectiveTransform(dst, src)
    return h_img_to_court, h_court_to_img


def draw_detection(frame: np.ndarray, det: BaselineDetection) -> np.ndarray:
    vis = frame.copy()
    corners = det.corners.astype(int)

    # Baselines.
    cv2.line(vis, tuple(corners[0]), tuple(corners[1]), (0, 255, 0), 2, cv2.LINE_AA)
    cv2.line(vis, tuple(corners[3]), tuple(corners[2]), (0, 255, 0), 2, cv2.LINE_AA)

    # Court polygon.
    poly = corners.reshape(-1, 1, 2)
    cv2.polylines(vis, [poly], True, (255, 0, 0), 2, cv2.LINE_AA)

    labels = ["TL", "TR", "BR", "BL"]
    for i, p in enumerate(corners):
        cv2.circle(vis, tuple(p), 5, (0, 0, 255), -1, cv2.LINE_AA)
        cv2.putText(
            vis,
            labels[i],
            (int(p[0] + 6), int(p[1] - 6)),
            cv2.FONT_HERSHEY_SIMPLEX,
            0.5,
            (255, 255, 255),
            1,
            cv2.LINE_AA,
        )

    return vis


def render_topdown(frame: np.ndarray, h_img_to_court: np.ndarray, scale_px_per_meter: int = 45) -> np.ndarray:
    warp_w = int(round(COURT_WIDTH_M * scale_px_per_meter))
    warp_h = int(round(COURT_LENGTH_M * scale_px_per_meter))
    scale = np.array(
        [
            [scale_px_per_meter, 0.0, 0.0],
            [0.0, scale_px_per_meter, 0.0],
            [0.0, 0.0, 1.0],
        ],
        dtype=np.float64,
    )
    h_img_to_warp = scale @ h_img_to_court
    return cv2.warpPerspective(frame, h_img_to_warp, (warp_w, warp_h))


def as_float_list(arr: np.ndarray, decimals: int = 6) -> list[list[float]]:
    rounded = np.round(arr.astype(np.float64), decimals=decimals)
    return [[float(x) for x in row] for row in rounded]


def corners_payload(corners: np.ndarray) -> dict[str, list[float]]:
    return {
        "top_left": [float(corners[0, 0]), float(corners[0, 1])],
        "top_right": [float(corners[1, 0]), float(corners[1, 1])],
        "bottom_right": [float(corners[2, 0]), float(corners[2, 1])],
        "bottom_left": [float(corners[3, 0]), float(corners[3, 1])],
    }


def run_on_image(image_path: Path) -> tuple[np.ndarray, BaselineDetection]:
    frame = cv2.imread(str(image_path))
    if frame is None:
        raise RuntimeError(f"Failed to read image: {image_path}")
    det = detect_baselines_in_frame(frame, frame_index=0)
    if det is None:
        raise RuntimeError("Court baseline detection failed on image.")
    return frame, det


def run_on_video(video_path: Path, max_samples: int) -> tuple[np.ndarray, BaselineDetection, int, int]:
    cap = cv2.VideoCapture(str(video_path))
    if not cap.isOpened():
        raise RuntimeError(f"Failed to open video: {video_path}")

    sampled = list(sample_video_frames(cap, max_samples=max_samples))
    detections: list[BaselineDetection] = []
    frame_cache: dict[int, np.ndarray] = {}
    for frame_id, frame in sampled:
        frame_cache[frame_id] = frame
        det = detect_baselines_in_frame(frame, frame_index=frame_id)
        if det is not None:
            detections.append(det)

    if not detections:
        raise RuntimeError("Court baseline detection failed on sampled video frames.")

    merged = aggregate_detections(detections)
    anchor_frame = frame_cache.get(merged.frame_index)
    if anchor_frame is None:
        cap.set(cv2.CAP_PROP_POS_FRAMES, int(merged.frame_index))
        ok, anchor_frame = cap.read()
        if not ok or anchor_frame is None:
            raise RuntimeError("Unable to load selected anchor frame from video.")
    cap.release()
    return anchor_frame, merged, len(sampled), len(detections)


def main() -> None:
    parser = argparse.ArgumentParser(description="Detect tennis court corners with Hough lines and compute homography.")
    parser.add_argument("--input", required=True, type=Path, help="Input image or video path.")
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path(__file__).resolve().parent / "outputs",
        help="Directory for json and visualization outputs.",
    )
    parser.add_argument("--max-samples", type=int, default=45, help="Maximum sampled frames for video input.")
    parser.add_argument("--prefix", type=str, default=None, help="Optional output filename prefix.")
    parser.add_argument("--no-topdown", action="store_true", help="Skip writing top-down warped image.")
    args = parser.parse_args()

    in_path = args.input.resolve()
    if not in_path.exists():
        raise FileNotFoundError(f"Input does not exist: {in_path}")

    args.output_dir.mkdir(parents=True, exist_ok=True)
    prefix = args.prefix or in_path.stem

    sampled_frames = 1
    valid_detections = 1
    if is_image(in_path):
        source_type = "image"
        frame, det = run_on_image(in_path)
    elif is_video(in_path):
        source_type = "video"
        frame, det, sampled_frames, valid_detections = run_on_video(in_path, max_samples=args.max_samples)
    else:
        raise ValueError(f"Unsupported input extension: {in_path.suffix}")

    h_img_to_court, h_court_to_img = compute_homography(det.corners)

    vis = draw_detection(frame, det)
    vis_path = args.output_dir / f"{prefix}_court_overlay.jpg"
    cv2.imwrite(str(vis_path), vis)

    topdown_path = args.output_dir / f"{prefix}_topdown.jpg"
    if not args.no_topdown:
        topdown = render_topdown(frame, h_img_to_court)
        cv2.imwrite(str(topdown_path), topdown)

    h, w = frame.shape[:2]
    near_baseline_width_px = float(np.linalg.norm(det.corners[2] - det.corners[3]))
    px_per_meter_near = near_baseline_width_px / COURT_WIDTH_M

    payload = {
        "input_path": str(in_path),
        "source_type": source_type,
        "frame_index": int(det.frame_index),
        "image_size_px": {"width": int(w), "height": int(h)},
        "corners_px": corners_payload(det.corners),
        "court_dimensions_m": {"width": COURT_WIDTH_M, "length": COURT_LENGTH_M},
        "homography_img_to_court": as_float_list(h_img_to_court),
        "homography_court_to_img": as_float_list(h_court_to_img),
        "quality": {
            "score": float(round(det.score, 3)),
            "sampled_frames": int(sampled_frames),
            "valid_detections": int(valid_detections),
            "px_per_meter_near_baseline": float(round(px_per_meter_near, 3)),
        },
        "artifacts": {
            "overlay_image": str(vis_path.resolve()),
            "topdown_image": str(topdown_path.resolve()) if not args.no_topdown else None,
        },
    }

    json_path = args.output_dir / f"{prefix}_court_detection.json"
    json_path.write_text(json.dumps(payload, indent=2), encoding="utf-8")

    print(f"Detected corners written to: {json_path}")
    print(f"Overlay image written to:    {vis_path}")
    if not args.no_topdown:
        print(f"Top-down image written to:   {topdown_path}")


if __name__ == "__main__":
    main()
