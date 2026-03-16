#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import cv2
import numpy as np


def parse_int(raw: Any, default: int = 0) -> int:
    try:
        if raw is None or raw == "":
            return default
        return int(float(raw))
    except Exception:
        return default


def parse_optional_int(raw: Any) -> int | None:
    if raw is None or raw == "":
        return None
    try:
        return int(float(raw))
    except Exception:
        return None


def parse_float(raw: Any, default: float = 0.0) -> float:
    try:
        if raw is None or raw == "":
            return default
        return float(raw)
    except Exception:
        return default


def parse_optional_float(raw: Any) -> float | None:
    if raw is None or raw == "":
        return None
    try:
        return float(raw)
    except Exception:
        return None


def parse_bool(raw: Any) -> bool | None:
    if raw is None or raw == "":
        return None
    v = str(raw).strip().lower()
    if v in {"1", "true", "t", "yes", "y"}:
        return True
    if v in {"0", "false", "f", "no", "n"}:
        return False
    return None


def clean_side(raw: Any) -> str | None:
    if raw is None:
        return None
    side = str(raw).strip().lower()
    if side in {"near", "far"}:
        return side
    return None


def read_csv(path: Path) -> list[dict[str, str]]:
    with path.open("r", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        return list(reader)


def normalize_polygon(corners_raw: Any) -> np.ndarray | None:
    pts: list[list[float]] = []
    if isinstance(corners_raw, dict):
        # Prefer canonical order if named keys are available.
        ordered_keys = ["top_left", "top_right", "bottom_right", "bottom_left"]
        values: list[Any] = [corners_raw[k] for k in ordered_keys if k in corners_raw]
        if len(values) < 3:
            values = list(corners_raw.values())
    elif isinstance(corners_raw, list):
        values = corners_raw
    else:
        values = []

    for c in values:
        if isinstance(c, dict):
            x = parse_optional_float(c.get("x"))
            y = parse_optional_float(c.get("y"))
        elif isinstance(c, (list, tuple)) and len(c) >= 2:
            x = parse_optional_float(c[0])
            y = parse_optional_float(c[1])
        else:
            x, y = None, None
        if x is not None and y is not None:
            pts.append([x, y])

    if len(pts) < 3:
        return None

    arr = np.array(pts, dtype=np.float32)
    return arr.reshape((-1, 1, 2))


def load_court_geometry(court_json: Path | None) -> tuple[np.ndarray | None, np.ndarray | None, float | None, float | None]:
    if court_json is None:
        return None, None, None, None

    obj = json.loads(court_json.read_text(encoding="utf-8"))

    h_raw = obj.get("homography_img_to_court")
    H: np.ndarray | None = None
    if isinstance(h_raw, list) and len(h_raw) == 3:
        H_tmp = np.array(h_raw, dtype=np.float64)
        if H_tmp.shape == (3, 3):
            H = H_tmp

    polygon = normalize_polygon(obj.get("corners_px"))

    dims = obj.get("court_dimensions_m", {}) if isinstance(obj.get("court_dimensions_m"), dict) else {}
    width_m = parse_optional_float(dims.get("width"))
    length_m = parse_optional_float(dims.get("length"))

    return H, polygon, width_m, length_m


def to_court_coords(H: np.ndarray | None, x_px: float | None, y_px: float | None) -> tuple[float | None, float | None]:
    if H is None or x_px is None or y_px is None:
        return None, None

    p = np.array([x_px, y_px, 1.0], dtype=np.float64)
    q = H @ p
    if abs(float(q[2])) < 1e-9:
        return None, None
    return float(q[0] / q[2]), float(q[1] / q[2])


def in_polygon(polygon: np.ndarray | None, x_px: float | None, y_px: float | None) -> bool | None:
    if polygon is None or x_px is None or y_px is None:
        return None
    inside = cv2.pointPolygonTest(polygon, (float(x_px), float(y_px)), False)
    return inside >= 0.0


def read_video_meta(video: Path) -> dict[str, Any]:
    cap = cv2.VideoCapture(str(video))
    if not cap.isOpened():
        raise RuntimeError(f"Failed to open video: {video}")

    fps = float(cap.get(cv2.CAP_PROP_FPS) or 25.0)
    frame_count = int(cap.get(cv2.CAP_PROP_FRAME_COUNT) or 0)
    width_px = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH) or 0)
    height_px = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT) or 0)
    cap.release()

    duration_sec = (frame_count / fps) if fps > 0 else 0.0
    return {
        "fps": fps,
        "frame_count": frame_count,
        "width_px": width_px,
        "height_px": height_px,
        "duration_sec": duration_sec,
    }


def score_str(row: dict[str, str], prefix: str) -> str:
    sets_near = parse_int(row.get(f"{prefix}_sets_near"), 0)
    sets_far = parse_int(row.get(f"{prefix}_sets_far"), 0)
    games_near = parse_int(row.get(f"{prefix}_games_near"), 0)
    games_far = parse_int(row.get(f"{prefix}_games_far"), 0)
    points_near = row.get(f"{prefix}_points_near", "0")
    points_far = row.get(f"{prefix}_points_far", "0")
    return f"S{sets_near}-{sets_far} G{games_near}-{games_far} P{points_near}-{points_far}"


def read_timeline(timeline_csv: Path | None) -> tuple[list[dict[str, Any]], dict[int, dict[str, Any]]]:
    if timeline_csv is None:
        return [], {}

    rows = read_csv(timeline_csv)
    normalized: list[dict[str, Any]] = []
    by_rally: dict[int, dict[str, Any]] = {}

    for r in rows:
        rally_id = parse_int(r.get("rally_id"), -1)
        if rally_id < 0:
            continue

        item = {
            "rally_id": rally_id,
            "winner_side": clean_side(r.get("winner_side")),
            "winner_source": r.get("winner_source", "unknown") or "unknown",
            "point_status": r.get("point_status", "pending_winner") or "pending_winner",
            "server_side_before": clean_side(r.get("server_side_before")),
            "server_side_after": clean_side(r.get("server_side_after")),
            "before_score": score_str(r, "before"),
            "after_score": score_str(r, "after"),
            "game_won_by": clean_side(r.get("game_won_by")),
            "set_won_by": clean_side(r.get("set_won_by")),
            "tie_break_before": parse_bool(r.get("tie_break_before")),
            "tie_break_after": parse_bool(r.get("tie_break_after")),
            "tb_points_before_near": parse_optional_int(r.get("tb_points_before_near")),
            "tb_points_before_far": parse_optional_int(r.get("tb_points_before_far")),
            "tb_points_after_near": parse_optional_int(r.get("tb_points_after_near")),
            "tb_points_after_far": parse_optional_int(r.get("tb_points_after_far")),
            "after_sets_near": parse_int(r.get("after_sets_near"), 0),
            "after_sets_far": parse_int(r.get("after_sets_far"), 0),
            "after_games_near": parse_int(r.get("after_games_near"), 0),
            "after_games_far": parse_int(r.get("after_games_far"), 0),
            "after_points_near": r.get("after_points_near", "0"),
            "after_points_far": r.get("after_points_far", "0"),
        }
        normalized.append(item)
        by_rally[rally_id] = item

    normalized.sort(key=lambda x: x["rally_id"])
    return normalized, by_rally


def build_rallies(
    session_external_id: str,
    rallies_csv: Path,
    timeline_by_rally: dict[int, dict[str, Any]],
) -> list[dict[str, Any]]:
    rows = read_csv(rallies_csv)
    out: list[dict[str, Any]] = []

    for r in rows:
        rally_id = parse_int(r.get("rally_id"), -1)
        if rally_id < 0:
            continue
        t = timeline_by_rally.get(rally_id, {})

        out.append(
            {
                "session_external_id": session_external_id,
                "rally_id": rally_id,
                "start_frame": parse_int(r.get("start_frame"), 0),
                "end_frame": parse_int(r.get("end_frame"), 0),
                "start_sec": parse_float(r.get("start_sec"), 0.0),
                "end_sec": parse_float(r.get("end_sec"), 0.0),
                "duration_sec": parse_float(r.get("duration_sec"), 0.0),
                "num_frames": parse_int(r.get("num_frames"), 0),
                "num_shots": parse_int(r.get("num_shots"), 0),
                "near_shots": parse_int(r.get("near_shots"), 0),
                "far_shots": parse_int(r.get("far_shots"), 0),
                "unassigned_shots": parse_int(r.get("unassigned_shots"), 0),
                "winner_side": t.get("winner_side"),
                "winner_source": t.get("winner_source"),
                "point_status": t.get("point_status"),
                "server_side_before": t.get("server_side_before"),
                "server_side_after": t.get("server_side_after"),
                "before_score": t.get("before_score"),
                "after_score": t.get("after_score"),
                "game_won_by": t.get("game_won_by"),
                "set_won_by": t.get("set_won_by"),
                "tie_break_before": t.get("tie_break_before"),
                "tie_break_after": t.get("tie_break_after"),
                "tb_points_before_near": t.get("tb_points_before_near"),
                "tb_points_before_far": t.get("tb_points_before_far"),
                "tb_points_after_near": t.get("tb_points_after_near"),
                "tb_points_after_far": t.get("tb_points_after_far"),
            }
        )

    return sorted(out, key=lambda x: x["rally_id"])


def rally_id_for_frame(frame_num: int, rallies: list[dict[str, Any]]) -> int | None:
    for r in rallies:
        if r["start_frame"] <= frame_num <= r["end_frame"]:
            return int(r["rally_id"])
    return None


def build_shots(
    session_external_id: str,
    shots_csv: Path,
    rallies: list[dict[str, Any]],
    H: np.ndarray | None,
    fps: float,
) -> list[dict[str, Any]]:
    rows = read_csv(shots_csv)
    out: list[dict[str, Any]] = []

    for idx, r in enumerate(rows, start=1):
        shot_id = parse_int(r.get("shot_id"), idx)
        frame_num = parse_int(r.get("frame_num"), 0)
        time_sec = parse_float(r.get("time_sec"), frame_num / fps if fps > 0 else 0.0)

        x_px = parse_optional_float(r.get("x_px"))
        y_px = parse_optional_float(r.get("y_px"))
        if x_px is None:
            x_px = parse_optional_float(r.get("x"))
        if y_px is None:
            y_px = parse_optional_float(r.get("y"))

        x_m, y_m = to_court_coords(H, x_px, y_px)
        rally_id = rally_id_for_frame(frame_num, rallies)

        side = clean_side(r.get("player_side"))
        if side is None:
            side = clean_side(r.get("hitter_side"))

        out.append(
            {
                "session_external_id": session_external_id,
                "shot_id": shot_id,
                "rally_id": rally_id,
                "frame_num": frame_num,
                "time_sec": time_sec,
                "x_px": x_px,
                "y_px": y_px,
                "x_m": x_m,
                "y_m": y_m,
                "hitter_side": side,
                "hitter_track_id": parse_optional_int(r.get("player_track_id") or r.get("hitter_track_id")),
                "assign_distance_px": parse_optional_float(r.get("assign_distance_px")),
                "side_matched": parse_bool(r.get("side_matched")),
                "shot_type": (r.get("shot_type") or "").strip() or None,
                "speed_kmh": parse_optional_float(r.get("speed_kmh")),
                "confidence": parse_optional_float(r.get("player_conf") or r.get("confidence")),
            }
        )

    return sorted(out, key=lambda x: (x["frame_num"], x["shot_id"]))


def moving_average(values: np.ndarray, window: int) -> np.ndarray:
    if window <= 1 or len(values) < window:
        return values.astype(np.float64)
    kernel = np.ones(window, dtype=np.float64) / float(window)
    return np.convolve(values, kernel, mode="same")


def detect_bounces(
    session_external_id: str,
    track_csv: Path | None,
    rallies: list[dict[str, Any]],
    H: np.ndarray | None,
    court_polygon: np.ndarray | None,
    fps: float,
    smooth_window: int,
    min_down: float,
    min_up: float,
    min_delta: float,
    min_gap_frames: int,
    max_track_gap: int,
) -> list[dict[str, Any]]:
    if track_csv is None:
        return []

    rows = read_csv(track_csv)

    frames: list[int] = []
    xs: list[float] = []
    ys: list[float] = []

    for r in rows:
        visible = parse_int(r.get("visible"), 0)
        if visible <= 0:
            continue

        x = parse_optional_float(r.get("x"))
        y = parse_optional_float(r.get("y"))
        if x is None or y is None:
            continue

        frames.append(parse_int(r.get("frame_num"), 0))
        xs.append(float(x))
        ys.append(float(y))

    if len(frames) < 3:
        return []

    f = np.array(frames, dtype=np.int32)
    x = np.array(xs, dtype=np.float64)
    y = np.array(ys, dtype=np.float64)

    x_s = moving_average(x, smooth_window)
    y_s = moving_average(y, smooth_window)

    out: list[dict[str, Any]] = []
    last_bounce_frame = -10**9

    for i in range(1, len(f) - 1):
        gap_left = int(f[i] - f[i - 1])
        gap_right = int(f[i + 1] - f[i])
        if gap_left > max_track_gap or gap_right > max_track_gap:
            continue

        dy_prev = float(y_s[i] - y_s[i - 1])
        dy_next = float(y_s[i + 1] - y_s[i])
        delta = dy_prev - dy_next

        if dy_prev < min_down:
            continue
        if dy_next > -min_up:
            continue
        if delta < min_delta:
            continue

        frame_num = int(f[i])
        if frame_num - last_bounce_frame < min_gap_frames:
            continue

        x_px = float(x[i])
        y_px = float(y[i])
        x_m, y_m = to_court_coords(H, x_px, y_px)
        in_court = in_polygon(court_polygon, x_px, y_px)
        rally_id = rally_id_for_frame(frame_num, rallies)

        confidence = min(0.99, max(0.05, delta / (min_delta * 3.0)))
        if in_court is False:
            confidence *= 0.65

        out.append(
            {
                "session_external_id": session_external_id,
                "bounce_id": 0,
                "rally_id": rally_id,
                "frame_num": frame_num,
                "time_sec": frame_num / fps if fps > 0 else 0.0,
                "x_px": x_px,
                "y_px": y_px,
                "x_m": x_m,
                "y_m": y_m,
                "in_court": in_court,
                "confidence": float(confidence),
                "detection_method": "vy_sign_flip",
            }
        )
        last_bounce_frame = frame_num

    out.sort(key=lambda r: r["frame_num"])
    for i, row in enumerate(out, start=1):
        row["bounce_id"] = i
    return out


def build_session_row(
    session_external_id: str,
    video_path: Path,
    video_meta: dict[str, Any],
    court_width_m: float | None,
    court_length_m: float | None,
    timeline_rows: list[dict[str, Any]],
    rallies: list[dict[str, Any]],
    shots: list[dict[str, Any]],
    bounces: list[dict[str, Any]],
) -> dict[str, Any]:
    final_sets_near = 0
    final_sets_far = 0
    final_games_near = 0
    final_games_far = 0
    final_points_near = "0"
    final_points_far = "0"
    first_server_side = "near"
    current_server_side = "near"

    if timeline_rows:
        first = timeline_rows[0]
        last = timeline_rows[-1]
        first_server_side = first.get("server_side_before") or "near"
        current_server_side = last.get("server_side_after") or first_server_side

        final_sets_near = parse_int(last.get("after_sets_near"), 0)
        final_sets_far = parse_int(last.get("after_sets_far"), 0)
        final_games_near = parse_int(last.get("after_games_near"), 0)
        final_games_far = parse_int(last.get("after_games_far"), 0)
        final_points_near = str(last.get("after_points_near", "0"))
        final_points_far = str(last.get("after_points_far", "0"))

    scored_points = sum(1 for r in timeline_rows if r.get("point_status") == "scored")
    pending_points = sum(1 for r in timeline_rows if r.get("point_status") != "scored")

    return {
        "session_external_id": session_external_id,
        "source_video_path": str(video_path.resolve()),
        "generated_at_utc": datetime.now(timezone.utc).isoformat(),
        "fps": float(video_meta["fps"]),
        "total_frames": int(video_meta["frame_count"]),
        "width_px": int(video_meta["width_px"]),
        "height_px": int(video_meta["height_px"]),
        "duration_sec": float(video_meta["duration_sec"]),
        "court_width_m": court_width_m,
        "court_length_m": court_length_m,
        "first_server_side": first_server_side,
        "current_server_side": current_server_side,
        "final_sets_near": final_sets_near,
        "final_sets_far": final_sets_far,
        "final_games_near": final_games_near,
        "final_games_far": final_games_far,
        "final_points_near": final_points_near,
        "final_points_far": final_points_far,
        "num_rallies": len(rallies),
        "num_shots": len(shots),
        "num_bounces": len(bounces),
        "num_points_scored": scored_points,
        "num_points_pending": pending_points,
    }


def write_csv_rows(path: Path, rows: list[dict[str, Any]], headers: list[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=headers)
        writer.writeheader()
        for row in rows:
            payload: dict[str, Any] = {}
            for h in headers:
                v = row.get(h)
                if v is None:
                    payload[h] = ""
                elif isinstance(v, bool):
                    payload[h] = int(v)
                elif isinstance(v, float):
                    payload[h] = round(v, 6)
                else:
                    payload[h] = v
            writer.writerow(payload)


def main() -> None:
    parser = argparse.ArgumentParser(description="Export normalized session/shots/bounces/rallies payload for backend ingestion.")
    parser.add_argument("--video", type=Path, required=True, help="Input video path")
    parser.add_argument("--rallies-csv", type=Path, required=True, help="Rallies CSV from split_rallies.py")
    parser.add_argument("--shots-csv", type=Path, required=True, help="Shots CSV from player_tracking")
    parser.add_argument("--timeline-csv", type=Path, default=None, help="Optional score timeline CSV")
    parser.add_argument("--track-csv", type=Path, default=None, help="Optional ball track CSV for bounce extraction")
    parser.add_argument("--court-json", type=Path, default=None, help="Optional court detection JSON with homography")
    parser.add_argument("--session-id", type=str, default=None, help="Stable external session id (default: video stem)")
    parser.add_argument("--output-dir", type=Path, default=Path(__file__).resolve().parent / "outputs", help="Output directory")
    parser.add_argument("--prefix", type=str, default=None, help="Output prefix (default: session id)")

    parser.add_argument("--bounce-smooth-window", type=int, default=3, help="Smoothing window for bounce detection")
    parser.add_argument("--bounce-min-down", type=float, default=2.0, help="Min downward dy before bounce")
    parser.add_argument("--bounce-min-up", type=float, default=2.0, help="Min upward dy after bounce")
    parser.add_argument("--bounce-min-delta", type=float, default=8.0, help="Min dy sign-flip magnitude")
    parser.add_argument("--bounce-min-gap-frames", type=int, default=5, help="Min frame gap between bounces")
    parser.add_argument("--bounce-max-track-gap", type=int, default=3, help="Max allowed gap in visible track continuity")

    args = parser.parse_args()

    args.output_dir.mkdir(parents=True, exist_ok=True)
    session_external_id = (args.session_id or args.video.stem).strip()
    if not session_external_id:
        raise ValueError("session id cannot be empty")

    prefix = args.prefix or session_external_id

    video_meta = read_video_meta(args.video)
    H, court_polygon, court_width_m, court_length_m = load_court_geometry(args.court_json)

    timeline_rows, timeline_by_rally = read_timeline(args.timeline_csv)
    rallies = build_rallies(session_external_id, args.rallies_csv, timeline_by_rally)
    shots = build_shots(session_external_id, args.shots_csv, rallies, H, float(video_meta["fps"]))

    bounces = detect_bounces(
        session_external_id=session_external_id,
        track_csv=args.track_csv,
        rallies=rallies,
        H=H,
        court_polygon=court_polygon,
        fps=float(video_meta["fps"]),
        smooth_window=max(1, args.bounce_smooth_window),
        min_down=args.bounce_min_down,
        min_up=args.bounce_min_up,
        min_delta=args.bounce_min_delta,
        min_gap_frames=max(1, args.bounce_min_gap_frames),
        max_track_gap=max(1, args.bounce_max_track_gap),
    )

    session_row = build_session_row(
        session_external_id=session_external_id,
        video_path=args.video,
        video_meta=video_meta,
        court_width_m=court_width_m,
        court_length_m=court_length_m,
        timeline_rows=timeline_rows,
        rallies=rallies,
        shots=shots,
        bounces=bounces,
    )

    sessions_csv = args.output_dir / f"{prefix}_sessions.csv"
    rallies_csv = args.output_dir / f"{prefix}_rallies.csv"
    shots_csv = args.output_dir / f"{prefix}_shots.csv"
    bounces_csv = args.output_dir / f"{prefix}_bounces.csv"
    payload_json = args.output_dir / f"{prefix}_analysis_payload.json"

    write_csv_rows(
        sessions_csv,
        [session_row],
        [
            "session_external_id",
            "source_video_path",
            "generated_at_utc",
            "fps",
            "total_frames",
            "width_px",
            "height_px",
            "duration_sec",
            "court_width_m",
            "court_length_m",
            "first_server_side",
            "current_server_side",
            "final_sets_near",
            "final_sets_far",
            "final_games_near",
            "final_games_far",
            "final_points_near",
            "final_points_far",
            "num_rallies",
            "num_shots",
            "num_bounces",
            "num_points_scored",
            "num_points_pending",
        ],
    )

    write_csv_rows(
        rallies_csv,
        rallies,
        [
            "session_external_id",
            "rally_id",
            "start_frame",
            "end_frame",
            "start_sec",
            "end_sec",
            "duration_sec",
            "num_frames",
            "num_shots",
            "near_shots",
            "far_shots",
            "unassigned_shots",
            "winner_side",
            "winner_source",
            "point_status",
            "server_side_before",
            "server_side_after",
            "before_score",
            "after_score",
            "game_won_by",
            "set_won_by",
            "tie_break_before",
            "tie_break_after",
            "tb_points_before_near",
            "tb_points_before_far",
            "tb_points_after_near",
            "tb_points_after_far",
        ],
    )

    write_csv_rows(
        shots_csv,
        shots,
        [
            "session_external_id",
            "shot_id",
            "rally_id",
            "frame_num",
            "time_sec",
            "x_px",
            "y_px",
            "x_m",
            "y_m",
            "hitter_side",
            "hitter_track_id",
            "assign_distance_px",
            "side_matched",
            "shot_type",
            "speed_kmh",
            "confidence",
        ],
    )

    write_csv_rows(
        bounces_csv,
        bounces,
        [
            "session_external_id",
            "bounce_id",
            "rally_id",
            "frame_num",
            "time_sec",
            "x_px",
            "y_px",
            "x_m",
            "y_m",
            "in_court",
            "confidence",
            "detection_method",
        ],
    )

    payload = {
        "schema_version": "phase1.v1",
        "generated_at_utc": datetime.now(timezone.utc).isoformat(),
        "session": session_row,
        "rallies": rallies,
        "shots": shots,
        "bounces": bounces,
    }
    payload_json.write_text(json.dumps(payload, indent=2, ensure_ascii=False), encoding="utf-8")

    print(f"sessions_csv={sessions_csv.resolve()}")
    print(f"rallies_csv={rallies_csv.resolve()}")
    print(f"shots_csv={shots_csv.resolve()}")
    print(f"bounces_csv={bounces_csv.resolve()}")
    print(f"payload_json={payload_json.resolve()}")
    print(f"session_external_id={session_external_id}")
    print(f"num_rallies={len(rallies)}")
    print(f"num_shots={len(shots)}")
    print(f"num_bounces={len(bounces)}")


if __name__ == "__main__":
    main()
