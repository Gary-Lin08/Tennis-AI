#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
from dataclasses import asdict, dataclass
from pathlib import Path

import cv2


@dataclass
class RallyRow:
    rally_id: int
    start_frame: int
    end_frame: int
    start_sec: float
    end_sec: float
    num_shots: int
    near_shots: int
    far_shots: int
    unassigned_shots: int


@dataclass
class ShotRow:
    shot_id: int
    frame_num: int
    side: str | None


@dataclass
class ScoreState:
    sets_near: int = 0
    sets_far: int = 0
    games_near: int = 0
    games_far: int = 0
    points_near: int = 0
    points_far: int = 0
    server_side: str = "near"  # next regular-game server
    in_tiebreak: bool = False
    tb_points_near: int = 0
    tb_points_far: int = 0
    tb_start_server: str = "near"


@dataclass
class TimelineRow:
    rally_id: int
    start_frame: int
    end_frame: int
    start_sec: float
    end_sec: float
    server_side_before: str
    server_side_after: str
    winner_side: str | None
    winner_source: str
    point_status: str
    tie_break_before: bool
    tie_break_after: bool
    tb_points_before_near: int
    tb_points_before_far: int
    tb_points_after_near: int
    tb_points_after_far: int
    num_shots: int
    near_shots: int
    far_shots: int
    unassigned_shots: int
    before_sets_near: int
    before_sets_far: int
    before_games_near: int
    before_games_far: int
    before_points_near: str
    before_points_far: str
    after_sets_near: int
    after_sets_far: int
    after_games_near: int
    after_games_far: int
    after_points_near: str
    after_points_far: str
    game_won_by: str | None
    set_won_by: str | None


def opposite_side(side: str) -> str:
    return "far" if side == "near" else "near"


def point_labels_regular(points_near: int, points_far: int) -> tuple[str, str]:
    labels = ["0", "15", "30", "40"]
    pn, pf = points_near, points_far
    if pn >= 3 and pf >= 3:
        if pn == pf:
            return "40", "40"
        if pn == pf + 1:
            return "AD", "40"
        if pf == pn + 1:
            return "40", "AD"
    return labels[min(pn, 3)], labels[min(pf, 3)]


def current_server_side(state: ScoreState) -> str:
    if not state.in_tiebreak:
        return state.server_side

    idx = state.tb_points_near + state.tb_points_far  # points already played in tie-break
    if idx == 0:
        return state.tb_start_server

    block = (idx - 1) // 2
    return opposite_side(state.tb_start_server) if (block % 2 == 0) else state.tb_start_server


def current_point_labels(state: ScoreState) -> tuple[str, str]:
    if state.in_tiebreak:
        return f"TB{state.tb_points_near}", f"TB{state.tb_points_far}"
    return point_labels_regular(state.points_near, state.points_far)


def read_rallies_csv(path: Path) -> list[RallyRow]:
    rows: list[RallyRow] = []
    with path.open("r", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for r in reader:
            rows.append(
                RallyRow(
                    rally_id=int(r["rally_id"]),
                    start_frame=int(r["start_frame"]),
                    end_frame=int(r["end_frame"]),
                    start_sec=float(r.get("start_sec", 0.0)),
                    end_sec=float(r.get("end_sec", 0.0)),
                    num_shots=int(r.get("num_shots", 0)),
                    near_shots=int(r.get("near_shots", 0)),
                    far_shots=int(r.get("far_shots", 0)),
                    unassigned_shots=int(r.get("unassigned_shots", 0)),
                )
            )
    return sorted(rows, key=lambda x: x.rally_id)


def parse_side(raw: str | None) -> str | None:
    if raw in {"near", "far"}:
        return raw
    return None


def read_shots_csv(path: Path | None) -> list[ShotRow]:
    if path is None:
        return []

    shots: list[ShotRow] = []
    with path.open("r", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for r in reader:
            side = parse_side(r.get("player_side"))
            if side is None:
                side = parse_side(r.get("hitter_side"))
            shots.append(
                ShotRow(
                    shot_id=int(r["shot_id"]),
                    frame_num=int(r["frame_num"]),
                    side=side,
                )
            )
    return sorted(shots, key=lambda x: (x.frame_num, x.shot_id))


def read_winner_overrides(path: Path | None) -> dict[int, str]:
    if path is None:
        return {}

    overrides: dict[int, str] = {}
    with path.open("r", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for r in reader:
            rid = int(r["rally_id"])
            side = parse_side(r.get("winner_side"))
            if side is not None:
                overrides[rid] = side
    return overrides


def apply_point(
    state: ScoreState,
    winner_side: str,
    set_target_games: int,
    tiebreak_target_points: int,
) -> tuple[str | None, str | None]:
    game_won_by: str | None = None
    set_won_by: str | None = None

    if state.in_tiebreak:
        if winner_side == "near":
            state.tb_points_near += 1
        else:
            state.tb_points_far += 1

        near_tb = state.tb_points_near
        far_tb = state.tb_points_far
        if max(near_tb, far_tb) >= tiebreak_target_points and abs(near_tb - far_tb) >= 2:
            set_won_by = "near" if near_tb > far_tb else "far"
            game_won_by = set_won_by

            if set_won_by == "near":
                state.sets_near += 1
            else:
                state.sets_far += 1

            # Next set first server is receiver of first TB point.
            state.server_side = opposite_side(state.tb_start_server)

            # Reset set/game/point state.
            state.games_near = 0
            state.games_far = 0
            state.points_near = 0
            state.points_far = 0
            state.in_tiebreak = False
            state.tb_points_near = 0
            state.tb_points_far = 0

        return game_won_by, set_won_by

    # Regular game mode.
    if winner_side == "near":
        state.points_near += 1
    else:
        state.points_far += 1

    near = state.points_near
    far = state.points_far
    if max(near, far) < 4 or abs(near - far) < 2:
        return None, None

    game_won_by = "near" if near > far else "far"
    if game_won_by == "near":
        state.games_near += 1
    else:
        state.games_far += 1

    state.points_near = 0
    state.points_far = 0

    # Alternate server every completed regular game.
    state.server_side = opposite_side(state.server_side)

    gn = state.games_near
    gf = state.games_far

    # Enter tie-break at 6-6.
    if gn == set_target_games and gf == set_target_games:
        state.in_tiebreak = True
        state.tb_points_near = 0
        state.tb_points_far = 0
        state.tb_start_server = state.server_side
        return game_won_by, None

    # Standard set win condition.
    near_set_win = gn >= set_target_games and (gn - gf) >= 2
    far_set_win = gf >= set_target_games and (gf - gn) >= 2
    if near_set_win or far_set_win:
        set_won_by = "near" if near_set_win else "far"
        if set_won_by == "near":
            state.sets_near += 1
        else:
            state.sets_far += 1

        # New set starts, games reset, server_side already points to next game server.
        state.games_near = 0
        state.games_far = 0

    return game_won_by, set_won_by


def infer_winner(
    rally: RallyRow,
    shots_in_rally: list[ShotRow],
    overrides: dict[int, str],
    winner_rule: str,
) -> tuple[str | None, str]:
    if rally.rally_id in overrides:
        return overrides[rally.rally_id], "override"

    sided = [s for s in shots_in_rally if s.side in {"near", "far"}]
    if not sided:
        return None, "unknown"

    last_side = sided[-1].side
    if last_side is None:
        return None, "unknown"

    if winner_rule == "last_hitter":
        return last_side, "last_hitter"
    if winner_rule == "opponent_of_last_hitter":
        return opposite_side(last_side), "opponent_of_last_hitter"
    raise ValueError(f"Unsupported winner rule: {winner_rule}")


def build_timeline(
    rallies: list[RallyRow],
    shots: list[ShotRow],
    overrides: dict[int, str],
    winner_rule: str,
    first_server: str,
    set_target_games: int,
    tiebreak_target_points: int,
) -> list[TimelineRow]:
    state = ScoreState(server_side=first_server)
    timeline: list[TimelineRow] = []

    for rally in rallies:
        shots_in_rally = [s for s in shots if rally.start_frame <= s.frame_num <= rally.end_frame]

        before_sets_near = state.sets_near
        before_sets_far = state.sets_far
        before_games_near = state.games_near
        before_games_far = state.games_far
        before_points_near, before_points_far = current_point_labels(state)
        server_before = current_server_side(state)
        tie_break_before = state.in_tiebreak
        tb_before_near = state.tb_points_near
        tb_before_far = state.tb_points_far

        winner_side, winner_source = infer_winner(rally, shots_in_rally, overrides, winner_rule)

        game_won_by: str | None = None
        set_won_by: str | None = None
        point_status = "pending_winner"
        if winner_side in {"near", "far"}:
            point_status = "scored"
            game_won_by, set_won_by = apply_point(
                state,
                winner_side=winner_side,
                set_target_games=set_target_games,
                tiebreak_target_points=tiebreak_target_points,
            )

        after_points_near, after_points_far = current_point_labels(state)
        server_after = current_server_side(state)

        timeline.append(
            TimelineRow(
                rally_id=rally.rally_id,
                start_frame=rally.start_frame,
                end_frame=rally.end_frame,
                start_sec=rally.start_sec,
                end_sec=rally.end_sec,
                server_side_before=server_before,
                server_side_after=server_after,
                winner_side=winner_side,
                winner_source=winner_source,
                point_status=point_status,
                tie_break_before=tie_break_before,
                tie_break_after=state.in_tiebreak,
                tb_points_before_near=tb_before_near,
                tb_points_before_far=tb_before_far,
                tb_points_after_near=state.tb_points_near,
                tb_points_after_far=state.tb_points_far,
                num_shots=rally.num_shots,
                near_shots=rally.near_shots,
                far_shots=rally.far_shots,
                unassigned_shots=rally.unassigned_shots,
                before_sets_near=before_sets_near,
                before_sets_far=before_sets_far,
                before_games_near=before_games_near,
                before_games_far=before_games_far,
                before_points_near=before_points_near,
                before_points_far=before_points_far,
                after_sets_near=state.sets_near,
                after_sets_far=state.sets_far,
                after_games_near=state.games_near,
                after_games_far=state.games_far,
                after_points_near=after_points_near,
                after_points_far=after_points_far,
                game_won_by=game_won_by,
                set_won_by=set_won_by,
            )
        )

    return timeline


def write_timeline_csv(path: Path, rows: list[TimelineRow]) -> None:
    with path.open("w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(
            [
                "rally_id",
                "start_frame",
                "end_frame",
                "start_sec",
                "end_sec",
                "server_side_before",
                "server_side_after",
                "winner_side",
                "winner_source",
                "point_status",
                "tie_break_before",
                "tie_break_after",
                "tb_points_before_near",
                "tb_points_before_far",
                "tb_points_after_near",
                "tb_points_after_far",
                "num_shots",
                "near_shots",
                "far_shots",
                "unassigned_shots",
                "before_sets_near",
                "before_sets_far",
                "before_games_near",
                "before_games_far",
                "before_points_near",
                "before_points_far",
                "after_sets_near",
                "after_sets_far",
                "after_games_near",
                "after_games_far",
                "after_points_near",
                "after_points_far",
                "game_won_by",
                "set_won_by",
            ]
        )
        for r in rows:
            w.writerow(
                [
                    r.rally_id,
                    r.start_frame,
                    r.end_frame,
                    round(r.start_sec, 3),
                    round(r.end_sec, 3),
                    r.server_side_before,
                    r.server_side_after,
                    "" if r.winner_side is None else r.winner_side,
                    r.winner_source,
                    r.point_status,
                    int(r.tie_break_before),
                    int(r.tie_break_after),
                    r.tb_points_before_near,
                    r.tb_points_before_far,
                    r.tb_points_after_near,
                    r.tb_points_after_far,
                    r.num_shots,
                    r.near_shots,
                    r.far_shots,
                    r.unassigned_shots,
                    r.before_sets_near,
                    r.before_sets_far,
                    r.before_games_near,
                    r.before_games_far,
                    r.before_points_near,
                    r.before_points_far,
                    r.after_sets_near,
                    r.after_sets_far,
                    r.after_games_near,
                    r.after_games_far,
                    r.after_points_near,
                    r.after_points_far,
                    "" if r.game_won_by is None else r.game_won_by,
                    "" if r.set_won_by is None else r.set_won_by,
                ]
            )


def write_timeline_json(path: Path, rows: list[TimelineRow]) -> None:
    payload = {
        "num_rallies": len(rows),
        "num_scored_points": sum(1 for r in rows if r.point_status == "scored"),
        "num_pending_points": sum(1 for r in rows if r.point_status != "scored"),
        "timeline": [asdict(r) for r in rows],
    }
    path.write_text(json.dumps(payload, indent=2, ensure_ascii=False), encoding="utf-8")


def write_pending_overrides_template(path: Path, rows: list[TimelineRow]) -> None:
    pending = [r for r in rows if r.point_status != "scored"]
    with path.open("w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(
            [
                "rally_id",
                "start_sec",
                "end_sec",
                "winner_side",
                "winner_source_hint",
                "score_before",
                "note",
            ]
        )
        for r in pending:
            w.writerow(
                [
                    r.rally_id,
                    round(r.start_sec, 3),
                    round(r.end_sec, 3),
                    "",
                    r.winner_source,
                    f"{r.before_points_near}-{r.before_points_far}",
                    "fill near/far manually",
                ]
            )


def draw_scoreboard(
    frame,
    sets_near: int,
    sets_far: int,
    games_near: int,
    games_far: int,
    p_near: str,
    p_far: str,
    server: str,
    rally_text: str,
) -> None:
    panel = frame.copy()
    cv2.rectangle(panel, (14, 14), (352, 118), (20, 20, 20), -1)
    cv2.addWeighted(panel, 0.50, frame, 0.50, 0, frame)

    cv2.putText(frame, "Tennis AI Score", (22, 36), cv2.FONT_HERSHEY_SIMPLEX, 0.58, (255, 255, 255), 1, cv2.LINE_AA)
    cv2.putText(frame, f"SET {sets_near}-{sets_far}", (22, 58), cv2.FONT_HERSHEY_SIMPLEX, 0.58, (100, 255, 255), 1, cv2.LINE_AA)
    cv2.putText(frame, f"GAME {games_near}-{games_far}", (22, 80), cv2.FONT_HERSHEY_SIMPLEX, 0.58, (100, 255, 255), 1, cv2.LINE_AA)
    cv2.putText(frame, f"POINT {p_near}-{p_far}", (22, 102), cv2.FONT_HERSHEY_SIMPLEX, 0.58, (100, 255, 255), 1, cv2.LINE_AA)

    cv2.putText(frame, f"Server: {server}", (210, 58), cv2.FONT_HERSHEY_SIMPLEX, 0.48, (220, 220, 220), 1, cv2.LINE_AA)
    if rally_text:
        cv2.putText(frame, rally_text, (210, 80), cv2.FONT_HERSHEY_SIMPLEX, 0.48, (0, 255, 255), 1, cv2.LINE_AA)


def render_overlay(video_path: Path, timeline: list[TimelineRow], out_path: Path) -> None:
    cap = cv2.VideoCapture(str(video_path))
    if not cap.isOpened():
        raise RuntimeError(f"Failed to open video: {video_path}")

    fps = float(cap.get(cv2.CAP_PROP_FPS) or 25.0)
    w = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    h = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    writer = cv2.VideoWriter(str(out_path), cv2.VideoWriter_fourcc(*"mp4v"), fps, (w, h))

    rows = sorted(timeline, key=lambda x: x.rally_id)
    completed_idx = -1

    i = 0
    while True:
        ok, frame = cap.read()
        if not ok:
            break

        while completed_idx + 1 < len(rows) and i > rows[completed_idx + 1].end_frame:
            completed_idx += 1

        active: TimelineRow | None = None
        probe = completed_idx + 1
        if probe < len(rows):
            cand = rows[probe]
            if cand.start_frame <= i <= cand.end_frame:
                active = cand

        if active is not None:
            draw_scoreboard(
                frame,
                active.before_sets_near,
                active.before_sets_far,
                active.before_games_near,
                active.before_games_far,
                active.before_points_near,
                active.before_points_far,
                active.server_side_before,
                f"RALLY {active.rally_id}",
            )
        elif completed_idx >= 0:
            prev = rows[completed_idx]
            draw_scoreboard(
                frame,
                prev.after_sets_near,
                prev.after_sets_far,
                prev.after_games_near,
                prev.after_games_far,
                prev.after_points_near,
                prev.after_points_far,
                prev.server_side_after,
                "",
            )
        else:
            draw_scoreboard(frame, 0, 0, 0, 0, "0", "0", "near", "")

        writer.write(frame)
        i += 1

    writer.release()
    cap.release()


def main() -> None:
    parser = argparse.ArgumentParser(description="Build tennis score timeline from rally sequence.")
    parser.add_argument("--video", type=Path, required=True, help="Input video path")
    parser.add_argument("--rallies-csv", type=Path, required=True, help="Rallies CSV from split_rallies.py")
    parser.add_argument("--shots-csv", type=Path, default=None, help="Optional shots CSV for winner inference")
    parser.add_argument("--winner-overrides", type=Path, default=None, help="Optional CSV: rally_id,winner_side")
    parser.add_argument("--winner-rule", type=str, default="opponent_of_last_hitter", choices=["opponent_of_last_hitter", "last_hitter"], help="Winner heuristic")
    parser.add_argument("--first-server", type=str, default="near", choices=["near", "far"], help="Initial server side")
    parser.add_argument("--set-target-games", type=int, default=6, help="Games needed to win a set")
    parser.add_argument("--tiebreak-target-points", type=int, default=7, help="Points needed to win tie-break")
    parser.add_argument("--output-dir", type=Path, default=Path(__file__).resolve().parent / "outputs", help="Output directory")
    parser.add_argument("--prefix", type=str, default=None, help="Output prefix")
    parser.add_argument("--pending-overrides-out", type=Path, default=None, help="Optional path for pending winner overrides template CSV")
    parser.add_argument("--no-overlay", action="store_true", help="Skip overlay video")
    args = parser.parse_args()

    args.output_dir.mkdir(parents=True, exist_ok=True)

    rallies = read_rallies_csv(args.rallies_csv)
    shots = read_shots_csv(args.shots_csv)
    overrides = read_winner_overrides(args.winner_overrides)

    timeline = build_timeline(
        rallies=rallies,
        shots=shots,
        overrides=overrides,
        winner_rule=args.winner_rule,
        first_server=args.first_server,
        set_target_games=args.set_target_games,
        tiebreak_target_points=args.tiebreak_target_points,
    )

    stem = args.prefix or args.rallies_csv.stem.replace("_rallies", "")
    out_csv = args.output_dir / f"{stem}_score_timeline.csv"
    out_json = args.output_dir / f"{stem}_score_timeline.json"
    write_timeline_csv(out_csv, timeline)
    write_timeline_json(out_json, timeline)

    pending_count = sum(1 for r in timeline if r.point_status != "scored")
    pending_template = args.pending_overrides_out or (args.output_dir / f"{stem}_winner_overrides_template.csv")
    if pending_count > 0:
        write_pending_overrides_template(pending_template, timeline)

    overlay_path = args.output_dir / f"{stem}_score_overlay.mp4"
    if not args.no_overlay:
        render_overlay(args.video, timeline, overlay_path)

    print(f"rallies_csv={args.rallies_csv.resolve()}")
    if args.shots_csv is not None:
        print(f"shots_csv={args.shots_csv.resolve()}")
    if args.winner_overrides is not None:
        print(f"winner_overrides={args.winner_overrides.resolve()}")
    print(f"timeline_csv={out_csv.resolve()}")
    print(f"timeline_json={out_json.resolve()}")
    if pending_count > 0:
        print(f"pending_overrides_template={pending_template.resolve()}")
    if not args.no_overlay:
        print(f"overlay_video={overlay_path.resolve()}")
    print(f"num_rallies={len(timeline)}")
    print(f"scored_points={sum(1 for r in timeline if r.point_status == 'scored')}")
    print(f"pending_points={pending_count}")


if __name__ == "__main__":
    main()
