from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


BACKEND_ROOT = Path(__file__).resolve().parents[1]
if str(BACKEND_ROOT) not in sys.path:
    sys.path.insert(0, str(BACKEND_ROOT))

from app.phase1_runner import parse_key_value_output, run_phase1_pipeline


class Phase1RunnerTests(unittest.TestCase):
    def test_parse_key_value_output_extracts_pairs(self) -> None:
        stdout = """
        track_csv=/tmp/track.csv
        output_video=/tmp/out.mp4
        ignored line
        """
        parsed = parse_key_value_output(stdout)
        self.assertEqual(parsed["track_csv"], "/tmp/track.csv")
        self.assertEqual(parsed["output_video"], "/tmp/out.mp4")
        self.assertNotIn("ignored line", parsed)

    def test_run_phase1_pipeline_uses_player_tracking_when_outputs_exist(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            phase1_root = root / "phase1"
            for relative in [
                "court_detection/detect_court.py",
                "tracknet_tennis/infer_tracknet_tennis.py",
                "shot_detection/detect_shots_from_track.py",
                "player_tracking/associate_shots_with_players.py",
                "rally_detection/split_rallies.py",
                "scoring/build_score_timeline.py",
                "data_contract/export_phase1_dataset.py",
            ]:
                path = phase1_root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("# stub\n", encoding="utf-8")

            video_path = root / "source.mov"
            video_path.write_bytes(b"video")

            def fake_run(cmd: list[str], text: bool, capture_output: bool, timeout: int, check: bool, env: dict[str, str]):
                script = Path(cmd[1]).name
                args = cmd[2:]

                def arg_value(flag: str) -> str:
                    return args[args.index(flag) + 1]

                if script == "detect_court.py":
                    output_dir = Path(arg_value("--output-dir"))
                    prefix = arg_value("--prefix")
                    output_dir.mkdir(parents=True, exist_ok=True)
                    (output_dir / f"{prefix}_court_detection.json").write_text(
                        json.dumps(
                            {
                                "quality": {"score": 0.87},
                                "corners_px": {
                                    "top_left": {"x": 1, "y": 2},
                                    "top_right": {"x": 3, "y": 4},
                                    "bottom_right": {"x": 5, "y": 6},
                                    "bottom_left": {"x": 7, "y": 8},
                                },
                                "homography_img_to_court": [[1, 0, 0], [0, 1, 0], [0, 0, 1]],
                                "homography_court_to_img": [[1, 0, 0], [0, 1, 0], [0, 0, 1]],
                                "court_dimensions_m": {"width": 10.97, "length": 23.77},
                            }
                        ),
                        encoding="utf-8",
                    )
                    (output_dir / f"{prefix}_court_overlay.jpg").write_bytes(b"overlay")
                    (output_dir / f"{prefix}_topdown.jpg").write_bytes(b"topdown")
                elif script == "infer_tracknet_tennis.py":
                    output_dir = Path(arg_value("--output-dir"))
                    stem = Path(arg_value("--video")).stem
                    output_dir.mkdir(parents=True, exist_ok=True)
                    (output_dir / f"{stem}_tracknet_tennis.csv").write_text("frame_num,visible,x,y\n0,1,10,20\n", encoding="utf-8")
                    (output_dir / f"{stem}_tracknet_tennis.mp4").write_bytes(b"track")
                elif script == "detect_shots_from_track.py":
                    output_dir = Path(arg_value("--output-dir"))
                    prefix = arg_value("--prefix")
                    output_dir.mkdir(parents=True, exist_ok=True)
                    (output_dir / f"{prefix}_shots.csv").write_text("shot_id,frame_num,time_sec,x_px,y_px\n1,10,0.3,10,20\n", encoding="utf-8")
                    (output_dir / f"{prefix}_shots.json").write_text('{"num_shots":1}', encoding="utf-8")
                elif script == "associate_shots_with_players.py":
                    output_dir = Path(arg_value("--output-dir"))
                    prefix = arg_value("--prefix")
                    output_dir.mkdir(parents=True, exist_ok=True)
                    (output_dir / f"{prefix}_shots_with_players.csv").write_text(
                        "shot_id,frame_num,time_sec,x_px,y_px,player_track_id,player_conf,player_side,assign_distance_px,side_matched\n"
                        "1,10,0.3,10,20,7,0.9,near,12,1\n",
                        encoding="utf-8",
                    )
                    (output_dir / f"{prefix}_shots_with_players.json").write_text('{"num_shots":1}', encoding="utf-8")
                elif script == "split_rallies.py":
                    output_dir = Path(arg_value("--output-dir"))
                    prefix = arg_value("--prefix")
                    output_dir.mkdir(parents=True, exist_ok=True)
                    (output_dir / f"{prefix}_rallies.csv").write_text(
                        "rally_id,start_frame,end_frame,start_sec,end_sec,duration_sec,num_frames,num_shots,near_shots,far_shots,unassigned_shots\n"
                        "1,0,40,0.0,1.3,1.3,41,1,1,0,0\n",
                        encoding="utf-8",
                    )
                    (output_dir / f"{prefix}_rallies.json").write_text('{"num_rallies":1}', encoding="utf-8")
                elif script == "build_score_timeline.py":
                    output_dir = Path(arg_value("--output-dir"))
                    prefix = arg_value("--prefix")
                    output_dir.mkdir(parents=True, exist_ok=True)
                    (output_dir / f"{prefix}_score_timeline.csv").write_text(
                        "rally_id,start_frame,end_frame,start_sec,end_sec,server_side_before,winner_side,winner_source,point_status,num_shots,near_shots,far_shots,unassigned_shots,before_sets_near,before_sets_far,before_games_near,before_games_far,before_points_near,before_points_far,after_sets_near,after_sets_far,after_games_near,after_games_far,after_points_near,after_points_far,game_won_by,set_won_by,server_side_after\n"
                        "1,0,40,0.0,1.3,near,near,rule,scored,1,1,0,0,0,0,0,0,0,0,0,0,0,0,15,0,near,,far\n",
                        encoding="utf-8",
                    )
                    (output_dir / f"{prefix}_score_timeline.json").write_text('{"num_rallies":1}', encoding="utf-8")
                elif script == "export_phase1_dataset.py":
                    output_dir = Path(arg_value("--output-dir"))
                    prefix = arg_value("--prefix")
                    session_id = arg_value("--session-id")
                    output_dir.mkdir(parents=True, exist_ok=True)
                    payload = {
                        "schema_version": "phase1.v1",
                        "generated_at_utc": "2026-03-16T00:00:00Z",
                        "session": {
                            "session_external_id": session_id,
                            "source_video_path": str(video_path),
                            "generated_at_utc": "2026-03-16T00:00:00Z",
                            "total_frames": 100,
                            "duration_sec": 4.0,
                            "num_rallies": 1,
                            "num_shots": 1,
                            "num_bounces": 0,
                        },
                        "rallies": [
                            {
                                "rally_id": 1,
                                "start_frame": 0,
                                "end_frame": 40,
                                "start_sec": 0.0,
                                "end_sec": 1.3,
                                "duration_sec": 1.3,
                                "num_frames": 41,
                                "num_shots": 1,
                                "near_shots": 1,
                                "far_shots": 0,
                                "unassigned_shots": 0,
                                "winner_side": "near",
                                "winner_source": "rule",
                                "point_status": "scored",
                                "server_side_before": "near",
                                "server_side_after": "far",
                                "before_score": "S0-0 G0-0 P0-0",
                                "after_score": "S0-0 G0-0 P15-0",
                            }
                        ],
                        "shots": [
                            {
                                "shot_id": 1,
                                "rally_id": 1,
                                "frame_num": 10,
                                "time_sec": 0.3,
                                "x_px": 10,
                                "y_px": 20,
                                "hitter_side": "near",
                            }
                        ],
                        "bounces": [],
                    }
                    (output_dir / f"{prefix}_analysis_payload.json").write_text(
                        json.dumps(payload),
                        encoding="utf-8",
                    )
                    for suffix in ["sessions.csv", "rallies.csv", "shots.csv", "bounces.csv"]:
                        (output_dir / f"{prefix}_{suffix}").write_text("header\n", encoding="utf-8")

                class Completed:
                    returncode = 0
                    stdout = "ok\n"
                    stderr = ""

                return Completed()

            with patch("app.phase1_runner.subprocess.run", side_effect=fake_run):
                result = run_phase1_pipeline(
                    video_path=video_path,
                    session_external_id="session-1",
                    output_root=root / "job-output",
                    phase1_root=phase1_root,
                    python_executable=sys.executable,
                    keep_overlays=False,
                )

            self.assertEqual(result.payload["session"]["session_external_id"], "session-1")
            self.assertEqual(result.court_detection_quality_score, 0.87)
            self.assertEqual(result.model_versions["player_tracking"], "yolo11n_bytetrack.v1")
            self.assertFalse(result.warnings)
            asset_types = {asset.asset_type for asset in result.artifacts}
            self.assertIn("analysis_payload_json", asset_types)
            self.assertIn("shots_with_players_csv", asset_types)


if __name__ == "__main__":
    unittest.main()
