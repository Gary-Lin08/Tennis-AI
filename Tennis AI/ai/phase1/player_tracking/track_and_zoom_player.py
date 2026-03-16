#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass
from pathlib import Path

import cv2
import numpy as np
from ultralytics import YOLO


@dataclass
class TrackStat:
    track_id: int
    frames: int = 0
    first_frame: int = -1
    last_frame: int = -1
    conf_sum: float = 0.0
    area_sum: float = 0.0

    def update(self, frame_idx: int, conf: float, area: float) -> None:
        if self.frames == 0:
            self.first_frame = frame_idx
        self.frames += 1
        self.last_frame = frame_idx
        self.conf_sum += conf
        self.area_sum += area

    @property
    def avg_conf(self) -> float:
        return self.conf_sum / max(1, self.frames)

    @property
    def avg_area(self) -> float:
        return self.area_sum / max(1, self.frames)

    def to_dict(self) -> dict[str, int | float]:
        return {
            "track_id": self.track_id,
            "frames": self.frames,
            "first_frame": self.first_frame,
            "last_frame": self.last_frame,
            "avg_conf": round(self.avg_conf, 4),
            "avg_area_px": round(self.avg_area, 2),
        }


def probe_video_meta(video_path: Path) -> tuple[float, int, int, int]:
    cap = cv2.VideoCapture(str(video_path))
    if not cap.isOpened():
        raise RuntimeError(f"Failed to open video: {video_path}")
    fps = float(cap.get(cv2.CAP_PROP_FPS) or 25.0)
    width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    frame_count = int(cap.get(cv2.CAP_PROP_FRAME_COUNT) or 0)
    cap.release()
    if width <= 0 or height <= 0:
        raise RuntimeError(f"Invalid video size for {video_path}")
    return fps, width, height, frame_count


def iter_person_boxes(
    result,
    min_box_area: float,
) -> list[tuple[int, np.ndarray, float, float]]:
    if result.boxes is None or len(result.boxes) == 0:
        return []

    xyxy = result.boxes.xyxy.cpu().numpy()
    confs = result.boxes.conf.cpu().numpy()
    ids = result.boxes.id.cpu().numpy().astype(int) if result.boxes.id is not None else np.full(len(xyxy), -1)

    items: list[tuple[int, np.ndarray, float, float]] = []
    for i in range(len(xyxy)):
        track_id = int(ids[i])
        if track_id < 0:
            continue

        x1, y1, x2, y2 = [float(v) for v in xyxy[i]]
        area = max(0.0, x2 - x1) * max(0.0, y2 - y1)
        if area < min_box_area:
            continue

        items.append((track_id, xyxy[i], float(confs[i]), area))
    return items


def run_track_stream(
    model: YOLO,
    video: Path,
    tracker: str,
    conf: float,
    iou: float,
    imgsz: int,
    device: str,
):
    return model.track(
        source=str(video),
        stream=True,
        persist=True,
        tracker=tracker,
        classes=[0],  # person
        conf=conf,
        iou=iou,
        imgsz=imgsz,
        device=device,
        verbose=False,
    )


def collect_track_stats(
    model: YOLO,
    video: Path,
    tracker: str,
    conf: float,
    iou: float,
    imgsz: int,
    device: str,
    min_box_area: float,
) -> dict[int, TrackStat]:
    stats: dict[int, TrackStat] = {}
    stream = run_track_stream(
        model=model,
        video=video,
        tracker=tracker,
        conf=conf,
        iou=iou,
        imgsz=imgsz,
        device=device,
    )
    for frame_idx, res in enumerate(stream):
        for track_id, _box, det_conf, area in iter_person_boxes(res, min_box_area=min_box_area):
            row = stats.setdefault(track_id, TrackStat(track_id=track_id))
            row.update(frame_idx=frame_idx, conf=det_conf, area=area)
    return stats


def rank_track_stats(stats: dict[int, TrackStat]) -> list[TrackStat]:
    return sorted(
        stats.values(),
        key=lambda s: (-s.frames, -s.avg_area, -s.avg_conf, s.track_id),
    )


def print_track_table(ranked: list[TrackStat], show_top: int) -> None:
    if not ranked:
        print("No person tracks found.")
        return

    print("Detected person tracks:")
    print("track_id  frames  first  last  avg_conf  avg_area_px")
    for row in ranked[: max(1, show_top)]:
        print(
            f"{row.track_id:>8}  {row.frames:>6}  {row.first_frame:>5}  "
            f"{row.last_frame:>4}  {row.avg_conf:>8.3f}  {row.avg_area:>11.1f}"
        )


def choose_target_track_id(
    ranked: list[TrackStat],
    requested_track_id: int | None,
    auto_select: bool,
) -> int:
    if not ranked:
        raise RuntimeError("No track candidates to select from.")

    available_ids = {row.track_id for row in ranked}
    default_id = ranked[0].track_id

    if requested_track_id is not None:
        if requested_track_id not in available_ids:
            raise ValueError(f"--target-track-id={requested_track_id} not found in detected tracks.")
        return requested_track_id

    if auto_select or not sys.stdin.isatty():
        print(f"auto_selected_track_id={default_id}")
        return default_id

    while True:
        raw = input(f"Choose track_id to zoom [default {default_id}]: ").strip()
        if raw == "":
            return default_id
        try:
            picked = int(raw)
        except ValueError:
            print("Invalid input. Please enter an integer track_id.")
            continue
        if picked not in available_ids:
            print(f"track_id={picked} is not in the candidate list.")
            continue
        return picked


def clamp(val: int, low: int, high: int) -> int:
    return max(low, min(high, val))


def compute_crop_rect(
    center_x: float,
    center_y: float,
    frame_w: int,
    frame_h: int,
    zoom: float,
    target_box: np.ndarray | None,
    box_margin: float,
) -> tuple[int, int, int, int]:
    safe_zoom = max(1.0, float(zoom))
    crop_w = int(round(frame_w / safe_zoom))
    crop_h = int(round(frame_h / safe_zoom))

    if target_box is not None:
        box_w = max(1.0, float(target_box[2] - target_box[0]))
        box_h = max(1.0, float(target_box[3] - target_box[1]))
        crop_w = max(crop_w, int(round(box_w * box_margin)))
        crop_h = max(crop_h, int(round(box_h * box_margin)))

    out_aspect = frame_w / max(1.0, frame_h)
    crop_w = max(64, min(frame_w, crop_w))
    crop_h = max(64, min(frame_h, crop_h))
    if crop_w / max(1.0, crop_h) > out_aspect:
        crop_h = int(round(crop_w / out_aspect))
    else:
        crop_w = int(round(crop_h * out_aspect))
    crop_w = max(64, min(frame_w, crop_w))
    crop_h = max(64, min(frame_h, crop_h))

    x1 = int(round(center_x - crop_w / 2.0))
    y1 = int(round(center_y - crop_h / 2.0))
    x1 = clamp(x1, 0, frame_w - crop_w)
    y1 = clamp(y1, 0, frame_h - crop_h)
    x2 = x1 + crop_w
    y2 = y1 + crop_h
    return x1, y1, x2, y2


def render_zoom_video(
    model: YOLO,
    video: Path,
    output_video: Path,
    tracker: str,
    target_track_id: int,
    conf: float,
    iou: float,
    imgsz: int,
    device: str,
    min_box_area: float,
    zoom: float,
    smooth_alpha: float,
    box_margin: float,
    max_missing_frames: int,
    show_hud: bool,
) -> dict[str, int | float]:
    fps, frame_w, frame_h, frame_count = probe_video_meta(video)
    writer = cv2.VideoWriter(
        str(output_video),
        cv2.VideoWriter_fourcc(*"mp4v"),
        fps,
        (frame_w, frame_h),
    )
    if not writer.isOpened():
        raise RuntimeError(f"Failed to open output writer: {output_video}")

    smooth_alpha = float(min(max(smooth_alpha, 0.01), 1.0))
    smoothed_center: tuple[float, float] | None = None
    last_seen_frame = -1_000_000
    lock_frames = 0
    miss_frames = 0

    stream = run_track_stream(
        model=model,
        video=video,
        tracker=tracker,
        conf=conf,
        iou=iou,
        imgsz=imgsz,
        device=device,
    )

    for frame_idx, res in enumerate(stream):
        frame = res.orig_img
        if frame is None:
            continue
        frame = frame.copy()

        target_box: np.ndarray | None = None
        target_conf = 0.0
        for track_id, box, det_conf, _area in iter_person_boxes(res, min_box_area=min_box_area):
            if track_id != target_track_id:
                continue
            if target_box is None or det_conf > target_conf:
                target_box = box
                target_conf = det_conf

        if target_box is not None:
            cx = float(target_box[0] + target_box[2]) * 0.5
            cy = float(target_box[1] + target_box[3]) * 0.5
            if smoothed_center is None:
                smoothed_center = (cx, cy)
            else:
                prev_x, prev_y = smoothed_center
                smoothed_center = (
                    prev_x * (1.0 - smooth_alpha) + cx * smooth_alpha,
                    prev_y * (1.0 - smooth_alpha) + cy * smooth_alpha,
                )
            last_seen_frame = frame_idx
            lock_frames += 1

        should_zoom = smoothed_center is not None and (frame_idx - last_seen_frame) <= max(0, max_missing_frames)
        if should_zoom and smoothed_center is not None:
            x1, y1, x2, y2 = compute_crop_rect(
                center_x=smoothed_center[0],
                center_y=smoothed_center[1],
                frame_w=frame_w,
                frame_h=frame_h,
                zoom=zoom,
                target_box=target_box,
                box_margin=box_margin,
            )
            crop = frame[y1:y2, x1:x2]
            if crop.size > 0:
                frame = cv2.resize(crop, (frame_w, frame_h), interpolation=cv2.INTER_LINEAR)
            else:
                should_zoom = False
                miss_frames += 1
        else:
            miss_frames += 1

        if show_hud:
            status = "LOCK" if should_zoom else "SEARCH"
            cv2.putText(
                frame,
                f"track_id={target_track_id}  status={status}",
                (18, 34),
                cv2.FONT_HERSHEY_SIMPLEX,
                0.8,
                (50, 220, 50) if should_zoom else (0, 180, 255),
                2,
                cv2.LINE_AA,
            )
            cv2.putText(
                frame,
                f"zoom={max(1.0, zoom):.2f}x",
                (18, 64),
                cv2.FONT_HERSHEY_SIMPLEX,
                0.72,
                (230, 230, 230),
                2,
                cv2.LINE_AA,
            )

        writer.write(frame)

    writer.release()
    return {
        "fps": round(fps, 4),
        "width": frame_w,
        "height": frame_h,
        "frame_count": frame_count,
        "lock_frames": lock_frames,
        "missing_or_search_frames": miss_frames,
    }


def main() -> None:
    default_model = Path(__file__).resolve().parent / "models" / "yolo11n.pt"
    parser = argparse.ArgumentParser(
        description="Track players with ByteTrack and export a zoom-follow video for a selected player track_id."
    )
    parser.add_argument("--video", type=Path, required=True, help="Input video path")
    parser.add_argument("--output-dir", type=Path, default=Path(__file__).resolve().parent / "outputs", help="Output directory")
    parser.add_argument("--prefix", type=str, default=None, help="Output prefix (default: video stem)")
    parser.add_argument("--model", type=str, default=str(default_model), help="Ultralytics model file")
    parser.add_argument("--tracker", type=str, default="bytetrack.yaml", help="Ultralytics tracker config")
    parser.add_argument("--imgsz", type=int, default=640, help="Inference size")
    parser.add_argument("--conf", type=float, default=0.25, help="Detection confidence threshold")
    parser.add_argument("--iou", type=float, default=0.5, help="NMS IoU threshold")
    parser.add_argument("--device", type=str, default="mps", help="Ultralytics device string, e.g. cpu/cuda/mps")
    parser.add_argument("--min-box-area", type=float, default=1200.0, help="Minimum person bbox area in pixels")
    parser.add_argument("--show-top", type=int, default=20, help="How many track candidates to display")
    parser.add_argument("--target-track-id", type=int, default=None, help="Explicit target track_id to zoom")
    parser.add_argument("--list-only", action="store_true", help="Only list detected track IDs and exit")
    parser.add_argument("--auto-select", action="store_true", help="Auto-pick the longest visible track")
    parser.add_argument("--zoom", type=float, default=2.2, help="Zoom factor (>=1.0)")
    parser.add_argument("--smooth-alpha", type=float, default=0.35, help="Smoothing factor for camera center (0-1)")
    parser.add_argument("--max-missing-frames", type=int, default=8, help="Keep zoom center for short tracking gaps")
    parser.add_argument("--box-margin", type=float, default=2.8, help="Minimum crop size multiplier relative to target bbox")
    parser.add_argument("--no-hud", action="store_true", help="Disable text HUD on output video")
    args = parser.parse_args()

    args.output_dir.mkdir(parents=True, exist_ok=True)

    stats_model = YOLO(args.model)
    stats = collect_track_stats(
        model=stats_model,
        video=args.video,
        tracker=args.tracker,
        conf=args.conf,
        iou=args.iou,
        imgsz=args.imgsz,
        device=args.device,
        min_box_area=args.min_box_area,
    )
    ranked = rank_track_stats(stats)
    print_track_table(ranked, show_top=args.show_top)

    if not ranked:
        raise RuntimeError("No player track IDs found in this video.")
    if args.list_only:
        return

    target_track_id = choose_target_track_id(
        ranked=ranked,
        requested_track_id=args.target_track_id,
        auto_select=args.auto_select,
    )

    prefix = args.prefix or args.video.stem
    output_video = args.output_dir / f"{prefix}_track_{target_track_id}_zoom.mp4"
    summary_json = args.output_dir / f"{prefix}_track_{target_track_id}_zoom_summary.json"

    render_model = YOLO(args.model)
    render_meta = render_zoom_video(
        model=render_model,
        video=args.video,
        output_video=output_video,
        tracker=args.tracker,
        target_track_id=target_track_id,
        conf=args.conf,
        iou=args.iou,
        imgsz=args.imgsz,
        device=args.device,
        min_box_area=args.min_box_area,
        zoom=args.zoom,
        smooth_alpha=args.smooth_alpha,
        box_margin=args.box_margin,
        max_missing_frames=args.max_missing_frames,
        show_hud=not args.no_hud,
    )

    summary_payload = {
        "video": str(args.video.resolve()),
        "target_track_id": target_track_id,
        "zoom": max(1.0, float(args.zoom)),
        "tracker": args.tracker,
        "tracks": [row.to_dict() for row in ranked],
        "render": render_meta,
        "output_video": str(output_video.resolve()),
    }
    summary_json.write_text(json.dumps(summary_payload, indent=2), encoding="utf-8")

    print(f"selected_track_id={target_track_id}")
    print(f"output_video={output_video.resolve()}")
    print(f"summary_json={summary_json.resolve()}")


if __name__ == "__main__":
    main()
