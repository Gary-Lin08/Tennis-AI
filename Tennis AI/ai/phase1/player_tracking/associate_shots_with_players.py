#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
from dataclasses import asdict, dataclass
from pathlib import Path

import cv2
import numpy as np
from ultralytics import YOLO


@dataclass
class ShotRow:
    shot_id: int
    frame_num: int
    time_sec: float
    x_px: float
    y_px: float
    hitter_side: str | None


@dataclass
class AssociatedShot:
    shot_id: int
    frame_num: int
    time_sec: float
    x_px: float
    y_px: float
    player_track_id: int | None
    player_conf: float | None
    player_side: str | None
    assign_distance_px: float | None
    side_matched: bool | None


def read_shots_csv(path: Path) -> list[ShotRow]:
    shots: list[ShotRow] = []
    with path.open("r", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            side_raw = row.get("hitter_side", "")
            side = side_raw if side_raw in {"near", "far"} else None
            shots.append(
                ShotRow(
                    shot_id=int(row["shot_id"]),
                    frame_num=int(row["frame_num"]),
                    time_sec=float(row["time_sec"]),
                    x_px=float(row["x_px"]),
                    y_px=float(row["y_px"]),
                    hitter_side=side,
                )
            )
    return shots


def point_to_box_distance(px: float, py: float, box: np.ndarray) -> float:
    x1, y1, x2, y2 = [float(v) for v in box]
    dx = max(x1 - px, 0.0, px - x2)
    dy = max(y1 - py, 0.0, py - y2)
    return float(np.hypot(dx, dy))


def side_by_y(y: float, h: int) -> str:
    return "near" if y >= (h * 0.5) else "far"


def load_court_polygon(court_json: Path | None, frame_w: int, frame_h: int) -> np.ndarray | None:
    if court_json is None:
        return None
    payload = json.loads(court_json.read_text(encoding="utf-8"))
    corners = payload.get("corners_px", {})
    size = payload.get("image_size_px", {})
    w_ref = float(size.get("width", frame_w))
    h_ref = float(size.get("height", frame_h))
    sx = float(frame_w) / max(1.0, w_ref)
    sy = float(frame_h) / max(1.0, h_ref)
    order = ["top_left", "top_right", "bottom_right", "bottom_left"]
    pts: list[list[float]] = []
    for k in order:
        p = corners.get(k)
        if not p or len(p) != 2:
            raise ValueError(f"Invalid court json: missing corner {k}")
        pts.append([float(p[0]) * sx, float(p[1]) * sy])
    return np.array(pts, dtype=np.float32)


def center_inside_court(cx: float, cy: float, court_polygon: np.ndarray | None, margin_px: float) -> bool:
    if court_polygon is None:
        return True
    dist = cv2.pointPolygonTest(court_polygon.astype(np.float32), (float(cx), float(cy)), measureDist=True)
    return dist >= -margin_px


def choose_player_for_shot(
    shot: ShotRow,
    players: list[dict[str, float | int | np.ndarray | str]],
    frame_h: int,
    side_penalty: float,
    max_assign_dist: float,
) -> tuple[int | None, float | None, float | None, str | None, bool | None]:
    if not players:
        return None, None, None, None, None

    prepared: list[tuple[dict[str, float | int | np.ndarray | str], float, str, bool]] = []
    for p in players:
        box = p["xyxy"]
        dist = point_to_box_distance(shot.x_px, shot.y_px, box)
        side = side_by_y(float(p["cy"]), frame_h)
        side_match = shot.hitter_side is None or side == shot.hitter_side
        prepared.append((p, dist, side, side_match))

    # If shot side is known, prioritize same-side candidates first.
    if shot.hitter_side is not None:
        same_side = [item for item in prepared if item[3]]
        if same_side:
            prepared = same_side
        else:
            return None, None, None, None, None

    best_score = float("inf")
    best_track_id: int | None = None
    best_conf: float | None = None
    best_dist: float | None = None
    best_side: str | None = None
    best_side_match: bool | None = None

    for p, dist, side, side_match in prepared:

        score = dist
        if shot.hitter_side is not None and not side_match:
            score += side_penalty

        if score < best_score:
            best_score = score
            best_track_id = int(p["track_id"])
            best_conf = float(p["conf"])
            best_dist = float(dist)
            best_side = side
            best_side_match = bool(side_match)

    if best_dist is None or best_dist > max_assign_dist:
        return None, None, None, None, None
    return best_track_id, best_conf, best_dist, best_side, best_side_match


def write_associated_csv(path: Path, rows: list[AssociatedShot]) -> None:
    with path.open("w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(
            [
                "shot_id",
                "frame_num",
                "time_sec",
                "x_px",
                "y_px",
                "player_track_id",
                "player_conf",
                "player_side",
                "assign_distance_px",
                "side_matched",
            ]
        )
        for r in rows:
            w.writerow(
                [
                    r.shot_id,
                    r.frame_num,
                    round(r.time_sec, 3),
                    round(r.x_px, 2),
                    round(r.y_px, 2),
                    "" if r.player_track_id is None else r.player_track_id,
                    "" if r.player_conf is None else round(r.player_conf, 3),
                    "" if r.player_side is None else r.player_side,
                    "" if r.assign_distance_px is None else round(r.assign_distance_px, 2),
                    "" if r.side_matched is None else int(r.side_matched),
                ]
            )


def write_associated_json(path: Path, rows: list[AssociatedShot]) -> None:
    payload = {
        "num_shots": len(rows),
        "shots": [asdict(r) for r in rows],
    }
    path.write_text(json.dumps(payload, indent=2, ensure_ascii=False), encoding="utf-8")


def main() -> None:
    default_model = Path(__file__).resolve().parent / "models" / "yolo11n.pt"
    parser = argparse.ArgumentParser(description="Associate shot events with player IDs using YOLOv8 + ByteTrack.")
    parser.add_argument("--video", type=Path, required=True, help="Input video path")
    parser.add_argument("--shots-csv", type=Path, required=True, help="Shots CSV from shot detection")
    parser.add_argument("--court-json", type=Path, default=None, help="Optional court_detection json to keep only on-court people")
    parser.add_argument("--output-dir", type=Path, default=Path(__file__).resolve().parent / "outputs", help="Output directory")
    parser.add_argument("--prefix", type=str, default=None, help="Output prefix")
    parser.add_argument("--model", type=str, default=str(default_model), help="Ultralytics model file")
    parser.add_argument("--imgsz", type=int, default=640, help="Inference size")
    parser.add_argument("--conf", type=float, default=0.25, help="Detection confidence threshold")
    parser.add_argument("--iou", type=float, default=0.5, help="NMS IoU threshold")
    parser.add_argument("--max-assign-dist", type=float, default=180.0, help="Max shot-to-player assignment distance in pixels")
    parser.add_argument("--side-penalty", type=float, default=80.0, help="Penalty when shot side and player side do not match")
    parser.add_argument("--court-margin", type=float, default=18.0, help="Outside-court tolerance (pixels) for person filtering")
    parser.add_argument("--min-box-area", type=float, default=1200.0, help="Minimum person bbox area in pixels")
    parser.add_argument("--device", type=str, default="mps", help="Ultralytics device string, e.g. cpu/cuda/mps")
    parser.add_argument("--no-overlay", action="store_true", help="Skip overlay video output")
    args = parser.parse_args()

    args.output_dir.mkdir(parents=True, exist_ok=True)
    shots = read_shots_csv(args.shots_csv)
    if not shots:
        raise RuntimeError("No shots found in shots CSV.")

    shot_by_frame: dict[int, list[ShotRow]] = {}
    for s in shots:
        shot_by_frame.setdefault(s.frame_num, []).append(s)

    model = YOLO(args.model)

    cap_probe = cv2.VideoCapture(str(args.video))
    if not cap_probe.isOpened():
        raise RuntimeError(f"Failed to open video: {args.video}")
    fps = float(cap_probe.get(cv2.CAP_PROP_FPS) or 25.0)
    w = int(cap_probe.get(cv2.CAP_PROP_FRAME_WIDTH))
    h = int(cap_probe.get(cv2.CAP_PROP_FRAME_HEIGHT))
    cap_probe.release()
    court_polygon = load_court_polygon(args.court_json, frame_w=w, frame_h=h)

    overlay_path = args.output_dir / f"{(args.prefix or args.shots_csv.stem.replace('_shots', ''))}_shots_with_players_overlay.mp4"
    writer = None
    if not args.no_overlay:
        writer = cv2.VideoWriter(str(overlay_path), cv2.VideoWriter_fourcc(*"mp4v"), fps, (w, h))

    associated_rows: list[AssociatedShot] = []
    associated_by_shot_id: dict[int, AssociatedShot] = {}

    results = model.track(
        source=str(args.video),
        stream=True,
        persist=True,
        tracker="bytetrack.yaml",
        classes=[0],
        conf=args.conf,
        iou=args.iou,
        imgsz=args.imgsz,
        device=args.device,
        verbose=False,
    )

    for frame_idx, res in enumerate(results):
        frame = res.orig_img.copy() if res.orig_img is not None else None

        players: list[dict[str, float | int | np.ndarray | str]] = []
        if res.boxes is not None and len(res.boxes) > 0:
            xyxy = res.boxes.xyxy.cpu().numpy()
            confs = res.boxes.conf.cpu().numpy()
            ids = res.boxes.id.cpu().numpy().astype(int) if res.boxes.id is not None else np.full(len(xyxy), -1)

            for i in range(len(xyxy)):
                x1, y1, x2, y2 = [float(v) for v in xyxy[i]]
                cx = (x1 + x2) * 0.5
                cy = (y1 + y2) * 0.5
                area = max(0.0, x2 - x1) * max(0.0, y2 - y1)
                if area < args.min_box_area:
                    continue
                if not center_inside_court(cx, cy, court_polygon=court_polygon, margin_px=args.court_margin):
                    continue
                track_id = int(ids[i])
                p = {
                    "track_id": track_id,
                    "xyxy": xyxy[i],
                    "cx": cx,
                    "cy": cy,
                    "conf": float(confs[i]),
                }
                players.append(p)

                if frame is not None:
                    cv2.rectangle(frame, (int(round(x1)), int(round(y1))), (int(round(x2)), int(round(y2))), (0, 220, 0), 2)
                    cv2.putText(
                        frame,
                        f"P{track_id}",
                        (int(round(x1)), int(round(y1)) - 6),
                        cv2.FONT_HERSHEY_SIMPLEX,
                        0.45,
                        (0, 220, 0),
                        1,
                        cv2.LINE_AA,
                    )

        if frame_idx in shot_by_frame:
            for shot in shot_by_frame[frame_idx]:
                track_id, pconf, dist, side, side_match = choose_player_for_shot(
                    shot,
                    players,
                    frame_h=h,
                    side_penalty=args.side_penalty,
                    max_assign_dist=args.max_assign_dist,
                )
                row = AssociatedShot(
                    shot_id=shot.shot_id,
                    frame_num=shot.frame_num,
                    time_sec=shot.time_sec,
                    x_px=shot.x_px,
                    y_px=shot.y_px,
                    player_track_id=track_id,
                    player_conf=pconf,
                    player_side=side,
                    assign_distance_px=dist,
                    side_matched=side_match,
                )
                associated_by_shot_id[shot.shot_id] = row

                if frame is not None:
                    cx = int(round(shot.x_px))
                    cy = int(round(shot.y_px))
                    cv2.circle(frame, (cx, cy), 8, (0, 255, 255), 2)
                    label = f"SHOT {shot.shot_id}"
                    if track_id is not None:
                        label += f" -> P{track_id}"
                    else:
                        label += " -> NA"
                    cv2.putText(
                        frame,
                        label,
                        (cx + 8, cy - 8),
                        cv2.FONT_HERSHEY_SIMPLEX,
                        0.45,
                        (0, 255, 255),
                        1,
                        cv2.LINE_AA,
                    )

        if writer is not None and frame is not None:
            writer.write(frame)

    if writer is not None:
        writer.release()

    for s in sorted(shots, key=lambda x: x.shot_id):
        r = associated_by_shot_id.get(s.shot_id)
        if r is None:
            r = AssociatedShot(
                shot_id=s.shot_id,
                frame_num=s.frame_num,
                time_sec=s.time_sec,
                x_px=s.x_px,
                y_px=s.y_px,
                player_track_id=None,
                player_conf=None,
                player_side=None,
                assign_distance_px=None,
                side_matched=None,
            )
        associated_rows.append(r)

    base = args.prefix or args.shots_csv.stem.replace("_shots", "")
    out_csv = args.output_dir / f"{base}_shots_with_players.csv"
    out_json = args.output_dir / f"{base}_shots_with_players.json"
    write_associated_csv(out_csv, associated_rows)
    write_associated_json(out_json, associated_rows)

    num_assigned = sum(1 for r in associated_rows if r.player_track_id is not None)

    print(f"video={args.video.resolve()}")
    print(f"shots_csv={args.shots_csv.resolve()}")
    if args.court_json is not None:
        print(f"court_json={args.court_json.resolve()}")
    print(f"output_csv={out_csv.resolve()}")
    print(f"output_json={out_json.resolve()}")
    if not args.no_overlay:
        print(f"overlay_video={overlay_path.resolve()}")
    print(f"assigned_shots={num_assigned}/{len(associated_rows)}")


if __name__ == "__main__":
    main()
