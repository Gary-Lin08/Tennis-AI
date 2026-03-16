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
class ShotLite:
    shot_id: int
    frame_num: int
    time_sec: float
    x_px: float
    y_px: float
    player_track_id: int | None
    player_side: str | None


@dataclass
class Rally:
    rally_id: int
    start_frame: int
    end_frame: int
    start_sec: float
    end_sec: float
    duration_sec: float
    num_frames: int
    num_shots: int
    first_shot_id: int | None
    last_shot_id: int | None
    near_shots: int
    far_shots: int
    unassigned_shots: int


def read_track_visibility(track_csv: Path) -> tuple[np.ndarray, np.ndarray]:
    frames: list[int] = []
    visible: list[bool] = []
    with track_csv.open("r", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            frames.append(int(row["frame_num"]))
            visible.append(int(row["visible"]) == 1)
    if not frames:
        raise RuntimeError(f"Empty track CSV: {track_csv}")
    return np.array(frames, dtype=np.int32), np.array(visible, dtype=bool)


def read_shots(shots_csv: Path | None) -> list[ShotLite]:
    if shots_csv is None:
        return []
    shots: list[ShotLite] = []
    with shots_csv.open("r", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            tid_raw = row.get("player_track_id", "")
            tid = int(tid_raw) if tid_raw not in {"", None} else None
            side_raw = row.get("player_side", "")
            side = side_raw if side_raw in {"near", "far"} else None
            shots.append(
                ShotLite(
                    shot_id=int(row["shot_id"]),
                    frame_num=int(row["frame_num"]),
                    time_sec=float(row.get("time_sec", 0.0)),
                    x_px=float(row.get("x_px", 0.0)),
                    y_px=float(row.get("y_px", 0.0)),
                    player_track_id=tid,
                    player_side=side,
                )
            )
    return sorted(shots, key=lambda s: s.frame_num)


def fill_small_gaps(mask: np.ndarray, max_gap: int) -> np.ndarray:
    out = mask.copy()
    n = len(out)
    i = 0
    while i < n:
        if out[i]:
            i += 1
            continue
        start = i
        while i < n and not out[i]:
            i += 1
        end = i
        gap = end - start
        left_on = start > 0 and out[start - 1]
        right_on = end < n and out[end]
        if left_on and right_on and gap <= max_gap:
            out[start:end] = True
    return out


def extract_segments(mask: np.ndarray, min_len: int) -> list[tuple[int, int]]:
    segs: list[tuple[int, int]] = []
    n = len(mask)
    i = 0
    while i < n:
        if not mask[i]:
            i += 1
            continue
        s = i
        while i < n and mask[i]:
            i += 1
        e = i - 1
        if (e - s + 1) >= min_len:
            segs.append((s, e))
    return segs


def merge_close_segments(segs: list[tuple[int, int]], max_gap: int) -> list[tuple[int, int]]:
    if not segs:
        return []
    merged: list[tuple[int, int]] = [segs[0]]
    for s, e in segs[1:]:
        ps, pe = merged[-1]
        if s - pe - 1 <= max_gap:
            merged[-1] = (ps, e)
        else:
            merged.append((s, e))
    return merged


def build_rallies(
    frame_ids: np.ndarray,
    segs_idx: list[tuple[int, int]],
    shots: list[ShotLite],
    fps: float,
    shot_pad_frames: int,
    start_pad_frames: int,
    end_pad_frames: int,
    min_shots: int,
) -> list[Rally]:
    rallies: list[Rally] = []
    ridx = 0
    for s_idx, e_idx in segs_idx:
        s_frame = int(frame_ids[s_idx])
        e_frame = int(frame_ids[e_idx])

        rally_shots = [s for s in shots if (s_frame - shot_pad_frames) <= s.frame_num <= (e_frame + shot_pad_frames)]
        if len(rally_shots) < min_shots:
            continue
        ridx += 1

        # Expand boundaries slightly to keep serve/contact context.
        s_final = max(0, s_frame - start_pad_frames)
        e_final = e_frame + end_pad_frames

        near = sum(1 for s in rally_shots if s.player_side == "near")
        far = sum(1 for s in rally_shots if s.player_side == "far")
        na = sum(1 for s in rally_shots if s.player_track_id is None)

        first_shot = rally_shots[0].shot_id if rally_shots else None
        last_shot = rally_shots[-1].shot_id if rally_shots else None
        duration = max(0.0, (e_final - s_final + 1) / max(fps, 1.0))

        rallies.append(
            Rally(
                rally_id=ridx,
                start_frame=s_final,
                end_frame=e_final,
                start_sec=float(s_final / max(fps, 1.0)),
                end_sec=float(e_final / max(fps, 1.0)),
                duration_sec=float(duration),
                num_frames=int(e_final - s_final + 1),
                num_shots=len(rally_shots),
                first_shot_id=first_shot,
                last_shot_id=last_shot,
                near_shots=near,
                far_shots=far,
                unassigned_shots=na,
            )
        )

    return rallies


def write_rallies_csv(path: Path, rallies: list[Rally]) -> None:
    with path.open("w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(
            [
                "rally_id",
                "start_frame",
                "end_frame",
                "start_sec",
                "end_sec",
                "duration_sec",
                "num_frames",
                "num_shots",
                "first_shot_id",
                "last_shot_id",
                "near_shots",
                "far_shots",
                "unassigned_shots",
            ]
        )
        for r in rallies:
            w.writerow(
                [
                    r.rally_id,
                    r.start_frame,
                    r.end_frame,
                    round(r.start_sec, 3),
                    round(r.end_sec, 3),
                    round(r.duration_sec, 3),
                    r.num_frames,
                    r.num_shots,
                    "" if r.first_shot_id is None else r.first_shot_id,
                    "" if r.last_shot_id is None else r.last_shot_id,
                    r.near_shots,
                    r.far_shots,
                    r.unassigned_shots,
                ]
            )


def write_rallies_json(path: Path, rallies: list[Rally]) -> None:
    payload = {
        "num_rallies": len(rallies),
        "rallies": [asdict(r) for r in rallies],
    }
    path.write_text(json.dumps(payload, indent=2, ensure_ascii=False), encoding="utf-8")


def render_overlay(video_path: Path, rallies: list[Rally], shots: list[ShotLite], out_path: Path) -> None:
    cap = cv2.VideoCapture(str(video_path))
    if not cap.isOpened():
        raise RuntimeError(f"Failed to open video: {video_path}")

    fps = float(cap.get(cv2.CAP_PROP_FPS) or 25.0)
    w = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    h = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    writer = cv2.VideoWriter(str(out_path), cv2.VideoWriter_fourcc(*"mp4v"), fps, (w, h))

    shot_by_frame: dict[int, list[ShotLite]] = {}
    for s in shots:
        shot_by_frame.setdefault(s.frame_num, []).append(s)

    i = 0
    while True:
        ok, frame = cap.read()
        if not ok:
            break

        draw = frame.copy()
        active = [r for r in rallies if r.start_frame <= i <= r.end_frame]
        if active:
            r = active[0]
            cv2.putText(
                draw,
                f"RALLY {r.rally_id}",
                (18, 28),
                cv2.FONT_HERSHEY_SIMPLEX,
                0.8,
                (20, 220, 255),
                2,
                cv2.LINE_AA,
            )

        if i in shot_by_frame:
            for s in shot_by_frame[i]:
                label = f"S{s.shot_id}"
                if s.player_track_id is not None:
                    label += f"->P{s.player_track_id}"
                cv2.circle(draw, (int(round(s.x_px)), int(round(s.y_px))), 8, (0, 255, 255), 2)
                cv2.putText(
                    draw,
                    label,
                    (int(round(s.x_px + 8)), int(round(s.y_px - 8))),
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


def main() -> None:
    parser = argparse.ArgumentParser(description="Split tennis rallies from ball visibility + shots.")
    parser.add_argument("--video", type=Path, required=True, help="Input video path")
    parser.add_argument("--track-csv", type=Path, required=True, help="Track CSV from infer_tracknet_tennis.py")
    parser.add_argument("--shots-csv", type=Path, default=None, help="Optional shots CSV (with or without player IDs)")
    parser.add_argument("--output-dir", type=Path, default=Path(__file__).resolve().parent / "outputs", help="Output directory")
    parser.add_argument("--prefix", type=str, default=None, help="Output prefix")
    parser.add_argument("--max-gap", type=int, default=10, help="Fill visibility gaps up to this many frames")
    parser.add_argument("--min-rally-frames", type=int, default=26, help="Minimum rally segment length in frames")
    parser.add_argument("--merge-gap", type=int, default=14, help="Merge adjacent rally segments if gap <= this")
    parser.add_argument("--shot-pad", type=int, default=8, help="Expand shot search range around visibility segment")
    parser.add_argument("--min-shots", type=int, default=1, help="Minimum shots required to keep a rally segment")
    parser.add_argument("--start-pad", type=int, default=5, help="Rally start frame padding")
    parser.add_argument("--end-pad", type=int, default=5, help="Rally end frame padding")
    parser.add_argument("--no-overlay", action="store_true", help="Skip rally overlay rendering")
    args = parser.parse_args()

    args.output_dir.mkdir(parents=True, exist_ok=True)

    frame_ids, vis = read_track_visibility(args.track_csv)
    vis_filled = fill_small_gaps(vis, max_gap=args.max_gap)

    segs = extract_segments(vis_filled, min_len=args.min_rally_frames)
    segs = merge_close_segments(segs, max_gap=args.merge_gap)

    cap = cv2.VideoCapture(str(args.video))
    if not cap.isOpened():
        raise RuntimeError(f"Failed to open video: {args.video}")
    fps = float(cap.get(cv2.CAP_PROP_FPS) or 25.0)
    cap.release()

    shots = read_shots(args.shots_csv)
    effective_min_shots = args.min_shots if shots else 0
    rallies = build_rallies(
        frame_ids=frame_ids,
        segs_idx=segs,
        shots=shots,
        fps=fps,
        shot_pad_frames=args.shot_pad,
        start_pad_frames=args.start_pad,
        end_pad_frames=args.end_pad,
        min_shots=effective_min_shots,
    )

    stem = args.prefix or args.track_csv.stem.replace("_tracknet_tennis", "")
    out_csv = args.output_dir / f"{stem}_rallies.csv"
    out_json = args.output_dir / f"{stem}_rallies.json"
    write_rallies_csv(out_csv, rallies)
    write_rallies_json(out_json, rallies)

    overlay_path = args.output_dir / f"{stem}_rallies_overlay.mp4"
    if not args.no_overlay:
        render_overlay(args.video, rallies, shots, overlay_path)

    print(f"track_csv={args.track_csv.resolve()}")
    if args.shots_csv is not None:
        print(f"shots_csv={args.shots_csv.resolve()}")
    print(f"rallies_csv={out_csv.resolve()}")
    print(f"rallies_json={out_json.resolve()}")
    if not args.no_overlay:
        print(f"overlay_video={overlay_path.resolve()}")
    print(f"num_rallies={len(rallies)}")


if __name__ == "__main__":
    main()
