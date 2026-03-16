# Phase 1 - TrackNet Baseline (Done)

Date: 2026-03-11

## Benchmark Harness

Date: 2026-03-13

Added a fixed-camera benchmark harness for candidate tracking models:

- Dataset contract:
  - `ai/phase1/benchmarks/dataset_manifest.example.json`
- Benchmark docs:
  - `ai/phase1/benchmarks/README.md`
- Scripts:
  - `ai/phase1/scripts/benchmark_tracking_models.py`
  - `ai/phase1/scripts/run_tracknet_benchmark.py`
  - `ai/phase1/scripts/run_gridtracknet_adapter.py`

This is the offline evaluation layer for comparing the current TrackNet path and an external GridTrackNet repo on the same `behind-baseline / tripod / fixed-camera` clips. It does not change the iOS pipeline.

## What was completed

1. Downloaded and prepared TrackNet code under:
   - `ai/phase1/TrackNetV2` (PyTorch implementation)
2. Downloaded 3 professional tennis match clips from YouTube (first 60 seconds each):
   - `U6WhLVQQpPc` (Australian Open 2026)
   - `P-NHvA-LooM` (Australian Open 2026)
   - `FfyI1wYYiIA` (Australian Open 2026)
3. Ran pretrained weight inference (`tf2torch/track.pt`) on all 3 clips.
4. Generated output video overlays and frame-level CSV ball coordinates.

## Important note

`yastrebksv/TrackNetV2` is not currently available as a public GitHub repository.
For the baseline run, we used a compatible TrackNetV2 PyTorch repo and applied the
official `tf2torch/diff.txt` model-structure change so pretrained weights can load.

## Output files

- Input clips: `ai/phase1/TrackNetV2/experiments/videos/*_60s.mp4`
- Predicted videos: `ai/phase1/TrackNetV2/experiments/runs/*_predict.mp4`
- Predicted coordinates: `ai/phase1/TrackNetV2/experiments/runs/*_predict.csv`
- Logs: `ai/phase1/TrackNetV2/experiments/runs/logs/*.log`

## Baseline result summary

- `U6WhLVQQpPc_60s_predict.csv`: visible `858/1500` (`57.20%`)
- `P-NHvA-LooM_60s_predict.csv`: visible `721/1501` (`48.03%`)
- `FfyI1wYYiIA_60s_predict.csv`: visible `625/1500` (`41.67%`)

Interpretation:

- The pipeline is working end-to-end, but raw pretrained quality is not stable enough
  for production tennis analytics.
- Fine-tuning on tennis-specific data is required before moving to downstream modules.

## One-command rerun

```bash
cd "/Users/kl/Desktop/Tennisvisionclone/Tennis AI"
./ai/phase1/scripts/run_tracknet_baseline.sh
```

If YouTube access is blocked, set browser source explicitly:

```bash
COOKIE_BROWSER=chrome ./ai/phase1/scripts/run_tracknet_baseline.sh
```

---

# Phase 1 - Task01 Court Detection + Homography (Done)

Date: 2026-03-11

## What was completed

1. Added a court-line detection module based on Hough transform:
   - `ai/phase1/court_detection/detect_court.py`
2. Implemented output of 4 court corners and homography matrices:
   - image -> court meters (`homography_img_to_court`)
   - court meters -> image (`homography_court_to_img`)
3. Added a GT evaluation utility (pixel + metric cm error):
   - `ai/phase1/court_detection/evaluate_corners.py`
4. Ran detection on all three downloaded match clips.

## Current detection outputs

Generated artifacts in:

- `ai/phase1/court_detection/outputs/*_court_detection.json`
- `ai/phase1/court_detection/outputs/*_court_overlay.jpg`
- `ai/phase1/court_detection/outputs/*_topdown.jpg`

Video results:

- `U6WhLVQQpPc_60s`: frame `374`
- `P-NHvA-LooM_60s`: frame `1090`
- `FfyI1wYYiIA_60s`: frame `783`

## Run

```bash
cd "/Users/kl/Desktop/Tennisvisionclone/Tennis AI/ai/phase1/TrackNetV2"
source .venv/bin/activate
cd "/Users/kl/Desktop/Tennisvisionclone/Tennis AI"
python ai/phase1/court_detection/detect_court.py \
  --input "ai/phase1/TrackNetV2/experiments/videos/U6WhLVQQpPc_60s.mp4" \
  --output-dir "ai/phase1/court_detection/outputs"
```

## Notes

- This detector is tuned for behind-baseline fixed-camera shots (your app target).
- Broadcast clips include camera cuts and close-ups; the script samples frames and
  selects a valid court-view frame automatically.
- Final <5cm target still requires manual corner GT evaluation with:
  `ai/phase1/court_detection/evaluate_corners.py`.

---

# Phase 1 - Tracking Stability Hotfix (Done)

Date: 2026-03-11

## What changed

1. `ai/phase1/court_detection/detect_court.py`
   - tightened baseline candidate rules to avoid selecting on-court text lines,
   - added sideline intersection search to recover more realistic corner geometry.
2. `ai/phase1/tracknet_tennis/infer_tracknet_tennis.py`
   - replaced single Hough-circle pick with connected-component candidate extraction,
   - added temporal motion gating (speed/acceleration/prediction radius),
   - added optional court-region gating via `--court-json`.

## Recommended run sequence

```bash
cd "/Users/kl/Desktop/Tennisvisionclone/Tennis AI/ai/phase1/TrackNetV2"
source .venv/bin/activate
cd "/Users/kl/Desktop/Tennisvisionclone/Tennis AI"

python ai/phase1/court_detection/detect_court.py \
  --input "ai/phase1/tracknet_tennis/videos/U6WhLVQQpPc_15s.mp4" \
  --prefix "U6WhLVQQpPc_15s_v2"

python ai/phase1/tracknet_tennis/infer_tracknet_tennis.py \
  --video "ai/phase1/tracknet_tennis/videos/U6WhLVQQpPc_15s.mp4" \
  --output-dir "ai/phase1/tracknet_tennis/outputs_v2" \
  --court-json "ai/phase1/court_detection/outputs/U6WhLVQQpPc_15s_v2_court_detection.json" \
  --class-threshold 35 \
  --remove-static \
  --max-dist 110 \
  --max-speed 90 \
  --max-accel 120 \
  --predict-radius 85
```

---

# Phase 1 - Shot Event Detection Baseline (Done)

Date: 2026-03-11

## What was completed

1. Added shot-event detection script:
   - `ai/phase1/shot_detection/detect_shots_from_track.py`
2. Input: ball track CSV from TrackNet + court homography JSON.
3. Logic:
   - short-gap interpolation + smoothing,
   - velocity/angle estimation in court-metric space,
   - direction change threshold + speed threshold + temporal NMS.
4. Outputs:
   - `*_shots.json`
   - `*_shots.csv`
   - `*_shots_overlay.mp4` (shot markers rendered on video)

## Run

```bash
cd "/Users/kl/Desktop/Tennisvisionclone/Tennis AI/ai/phase1/TrackNetV2"
source .venv/bin/activate
cd "/Users/kl/Desktop/Tennisvisionclone/Tennis AI"

python ai/phase1/shot_detection/detect_shots_from_track.py \
  --track-csv "ai/phase1/tracknet_tennis/outputs_v2/U6WhLVQQpPc_15s_tracknet_tennis.csv" \
  --video "ai/phase1/tracknet_tennis/videos/U6WhLVQQpPc_15s.mp4" \
  --court-json "ai/phase1/court_detection/outputs/U6WhLVQQpPc_15s_v2_court_detection.json" \
  --output-dir "ai/phase1/shot_detection/outputs"
```

## Tuning

- More sensitive: lower `--min-angle` (e.g. `40`) and `--min-speed-kmh` (e.g. `10`).
- More conservative: raise `--min-angle` and `--min-speed-kmh`, or increase `--min-gap-frames`.

---

# Phase 1 - YOLOv8 + ByteTrack Shot Association (Done)

Date: 2026-03-11

## What was completed

1. Added player-tracking + shot-association script:
   - `ai/phase1/player_tracking/associate_shots_with_players.py`
2. Pipeline:
   - YOLOv8 person detection (`ultralytics`)
   - ByteTrack multi-object tracking (`tracker=bytetrack.yaml`)
   - per-shot nearest-player assignment with optional near/far side constraint
3. Outputs:
   - `*_shots_with_players.csv`
   - `*_shots_with_players.json`
   - `*_shots_with_players_overlay.mp4`

## Run

```bash
cd "/Users/kl/Desktop/Tennisvisionclone/Tennis AI/ai/phase1/TrackNetV2"
source .venv/bin/activate
cd "/Users/kl/Desktop/Tennisvisionclone/Tennis AI"

# One-time dependency (if missing)
pip install ultralytics lap

python ai/phase1/player_tracking/associate_shots_with_players.py \
  --video "ai/phase1/tracknet_tennis/videos/U6WhLVQQpPc_15s.mp4" \
  --shots-csv "ai/phase1/shot_detection/outputs/U6WhLVQQpPc_15s_default_shots.csv" \
  --court-json "ai/phase1/court_detection/outputs/U6WhLVQQpPc_15s_v2_court_detection.json" \
  --output-dir "ai/phase1/player_tracking/outputs" \
  --device mps
```

## Notes

- If a shot cannot be confidently mapped to a same-side tracked player, result is `NA` (safer than wrong assignment).
- You can relax strictness with larger `--max-assign-dist` or by removing side constraint upstream.

---

# Phase 1 - Player Focus Zoom Tracking (YOLOv8 + ByteTrack) (Done)

Date: 2026-03-12

## What was completed

1. Added player-focus tracking + zoom script:
   - `ai/phase1/player_tracking/track_and_zoom_player.py`
2. Pipeline:
   - detect and track players via YOLOv8 + ByteTrack
   - list all stable `track_id` candidates
   - user selects one `track_id` to follow
   - export a zoom-follow output video around that player
3. Outputs:
   - `*_track_<id>_zoom.mp4`
   - `*_track_<id>_zoom_summary.json`

## Run

```bash
cd "/Users/kl/Desktop/Tennisvisionclone/Tennis AI/ai/phase1/TrackNetV2"
source .venv/bin/activate
cd "/Users/kl/Desktop/Tennisvisionclone/Tennis AI"

# One-time dependency (if missing)
pip install ultralytics lap

# Step 1: list available player track IDs
python ai/phase1/player_tracking/track_and_zoom_player.py \
  --video "ai/phase1/tracknet_tennis/videos/U6WhLVQQpPc_15s.mp4" \
  --list-only \
  --device mps

# Step 2: choose one track_id and export zoom-follow video
python ai/phase1/player_tracking/track_and_zoom_player.py \
  --video "ai/phase1/tracknet_tennis/videos/U6WhLVQQpPc_15s.mp4" \
  --target-track-id 1 \
  --zoom 2.4 \
  --output-dir "ai/phase1/player_tracking/outputs" \
  --device mps
```

## Notes

- If you omit `--target-track-id`, the script will prompt you to choose from detected IDs.
- `--auto-select` picks the longest visible track automatically.
- Increase `--zoom` for tighter framing; increase `--max-missing-frames` if short ID drops happen.

---

# Phase 1 - Rally Segmentation Baseline (Done)

Date: 2026-03-11

## What was completed

1. Added rally segmentation script:
   - `ai/phase1/rally_detection/split_rallies.py`
2. Inputs:
   - ball visibility track CSV
   - optional shots CSV (supports player-associated shots)
3. Logic:
   - fill short visibility gaps
   - split and merge visible segments
   - keep segments with at least `--min-shots` hits (default `1`)
   - output rally boundaries + per-rally shot summary
4. Outputs:
   - `*_rallies.csv`
   - `*_rallies.json`
   - `*_rallies_overlay.mp4`

## Run

```bash
cd "/Users/kl/Desktop/Tennisvisionclone/Tennis AI/ai/phase1/TrackNetV2"
source .venv/bin/activate
cd "/Users/kl/Desktop/Tennisvisionclone/Tennis AI"

python ai/phase1/rally_detection/split_rallies.py \
  --video "ai/phase1/tracknet_tennis/videos/U6WhLVQQpPc_15s.mp4" \
  --track-csv "ai/phase1/tracknet_tennis/outputs_v2/U6WhLVQQpPc_15s_tracknet_tennis.csv" \
  --shots-csv "ai/phase1/player_tracking/outputs/U6WhLVQQpPc_15s_default_court_filtered_v4_shots_with_players.csv" \
  --output-dir "ai/phase1/rally_detection/outputs" \
  --prefix "U6WhLVQQpPc_15s_v2"
```

---

# Phase 1 - Score Timeline Baseline (Done)

Date: 2026-03-11

## What was completed

1. Added score-state script:
   - `ai/phase1/scoring/build_score_timeline.py`
2. Inputs:
   - `rallies.csv`
   - optional `shots.csv` (for winner inference)
   - optional winner override CSV (`rally_id,winner_side`)
3. Logic:
   - tennis point/game/set state machine
   - supports tie-break (default 6-6 to 7 points, win by 2)
   - tie-break serve rotation and next-set first-server handoff
   - winner inference rule:
     - `opponent_of_last_hitter` (default)
     - `last_hitter`
   - unknown winner rallies are marked `pending_winner` and do not change score
4. Outputs:
   - `*_score_timeline.csv`
   - `*_score_timeline.json`
   - `*_score_overlay.mp4`
   - `*_winner_overrides_template.csv` (only when pending winners exist)

## Run

```bash
cd "/Users/kl/Desktop/Tennisvisionclone/Tennis AI/ai/phase1/TrackNetV2"
source .venv/bin/activate
cd "/Users/kl/Desktop/Tennisvisionclone/Tennis AI"

python ai/phase1/scoring/build_score_timeline.py \
  --video "ai/phase1/tracknet_tennis/videos/U6WhLVQQpPc_15s.mp4" \
  --rallies-csv "ai/phase1/rally_detection/outputs/U6WhLVQQpPc_15s_v2_rallies.csv" \
  --shots-csv "ai/phase1/player_tracking/outputs/U6WhLVQQpPc_15s_default_court_filtered_v4_shots_with_players.csv" \
  --output-dir "ai/phase1/scoring/outputs" \
  --prefix "U6WhLVQQpPc_15s_v1"
```

Tie-break params are configurable:

```bash
--set-target-games 6 --tiebreak-target-points 7
```

## Pending Winner Manual Fix

1. Run score script once and open `*_winner_overrides_template.csv`.
2. Fill `winner_side` with `near` or `far`.
3. Re-run with `--winner-overrides`:

```bash
python ai/phase1/scoring/build_score_timeline.py \
  --video "ai/phase1/tracknet_tennis/videos/U6WhLVQQpPc_15s.mp4" \
  --rallies-csv "ai/phase1/rally_detection/outputs/U6WhLVQQpPc_15s_v2_rallies.csv" \
  --shots-csv "ai/phase1/player_tracking/outputs/U6WhLVQQpPc_15s_default_court_filtered_v4_shots_with_players.csv" \
  --winner-overrides "ai/phase1/scoring/outputs/U6WhLVQQpPc_15s_v2_winner_overrides_filled.csv" \
  --output-dir "ai/phase1/scoring/outputs" \
  --prefix "U6WhLVQQpPc_15s_v2_overridden"
```

---

# Phase 1 - Data Contract + Supabase Schema (Done)

Date: 2026-03-12

## What was completed

1. Added normalized exporter:
   - `ai/phase1/data_contract/export_phase1_dataset.py`
2. Exporter merges:
   - rallies (`split_rallies.py`)
   - shots (`associate_shots_with_players.py`)
   - score timeline (`build_score_timeline.py`)
   - optional ball track + homography (for bounce extraction)
3. Outputs 4 core table-ready CSVs + one API JSON payload:
   - `*_sessions.csv`
   - `*_shots.csv`
   - `*_bounces.csv`
   - `*_rallies.csv`
   - `*_analysis_payload.json`
4. Added Supabase/PostgreSQL schema:
   - `ai/phase1/data_contract/supabase_schema.sql`
   - tables: `sessions`, `shots`, `bounces`, `rallies`
   - includes indexes + RLS policies by `auth.uid()`

## Run

```bash
cd "/Users/kl/Desktop/Tennisvisionclone/Tennis AI/ai/phase1/TrackNetV2"
source .venv/bin/activate
cd "/Users/kl/Desktop/Tennisvisionclone/Tennis AI"

python ai/phase1/data_contract/export_phase1_dataset.py \
  --video "ai/phase1/tracknet_tennis/videos/U6WhLVQQpPc_15s.mp4" \
  --rallies-csv "ai/phase1/rally_detection/outputs/U6WhLVQQpPc_15s_v2_rallies.csv" \
  --shots-csv "ai/phase1/player_tracking/outputs/U6WhLVQQpPc_15s_default_court_filtered_v4_shots_with_players.csv" \
  --timeline-csv "ai/phase1/scoring/outputs/U6WhLVQQpPc_15s_v2_overridden_score_timeline.csv" \
  --track-csv "ai/phase1/tracknet_tennis/outputs_v2/U6WhLVQQpPc_15s_tracknet_tennis.csv" \
  --court-json "ai/phase1/court_detection/outputs/U6WhLVQQpPc_15s_v2_court_detection.json" \
  --output-dir "ai/phase1/data_contract/outputs" \
  --prefix "U6WhLVQQpPc_15s_v2"
```

## Supabase apply

Run `ai/phase1/data_contract/supabase_schema.sql` in Supabase SQL Editor, then ingest the exported CSV/JSON.

---

# Phase 2 - FastAPI Ingestion Skeleton (Done)

Date: 2026-03-12

## What was completed

1. Added backend service:
   - `ai/backend/app/main.py`
   - endpoint `POST /sessions/upload`
   - endpoint `POST /telemetry/events`
2. Added Supabase write layer:
   - `ai/backend/app/repository.py`
   - upserts `sessions` and ingests `rallies/shots/bounces`
   - ingests app telemetry events (`click/screen/usage`)
3. Added backend setup docs:
   - `ai/backend/README.md`
   - `ai/backend/.env.example`
4. Added payload push helper:
   - `ai/backend/scripts/push_payload.py`

## Quick start

```bash
cd "/Users/kl/Desktop/Tennisvisionclone/Tennis AI"
python3 -m venv ai/backend/.venv
source ai/backend/.venv/bin/activate
pip install -r ai/backend/requirements.txt

cp ai/backend/.env.example ai/backend/.env
# fill SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY

set -a; source ai/backend/.env; set +a
uvicorn ai.backend.app.main:app --host 0.0.0.0 --port 8000 --reload
```

---

# Phase 1 - Action Detection Evaluation Toolkit (Done)

Date: 2026-03-12

## What was completed

1. Added offline action-event evaluator:
   - `ai/phase1/action_detection/evaluate_actions.py`
2. Supports temporal-tolerant one-to-one event matching between GT and predictions.
3. Outputs:
   - overview metrics (`accuracy`, `macro_f1`, `micro_f1`, detection precision/recall/f1)
   - per-class metrics (`forehand`, `backhand`, `serve`, `unknown`)
   - confusion matrix with `spurious` row and `missing` column
4. Added usage and CSV format docs:
   - `ai/phase1/action_detection/README.md`
5. Added auto-tuning script for threshold search:
   - `ai/phase1/action_detection/grid_search_actions.py`
   - supports grid search over `tolerance_frames` + `min_confidence`

## Run

```bash
cd "/Users/kl/Desktop/Tennisvisionclone/Tennis AI"

python ai/phase1/action_detection/evaluate_actions.py \
  --gt-csv "ai/phase1/action_detection/labels/demo_gt.csv" \
  --pred-csv "ai/phase1/action_detection/labels/demo_pred.csv" \
  --tolerance-frames 4 \
  --min-confidence 0.35 \
  --output-json "ai/phase1/action_detection/outputs/demo_report.json" \
  --output-confusion-csv "ai/phase1/action_detection/outputs/demo_confusion.csv"

python ai/phase1/action_detection/grid_search_actions.py \
  --gt-csv "ai/phase1/action_detection/labels/demo_gt.csv" \
  --pred-csv "ai/phase1/action_detection/labels/demo_pred.csv" \
  --tolerance-grid "2,3,4,5,6" \
  --confidence-grid "0.0,0.2,0.3,0.35,0.4,0.45,0.5" \
  --optimize macro_f1 \
  --output-leaderboard-csv "ai/phase1/action_detection/outputs/demo_grid.csv" \
  --output-best-json "ai/phase1/action_detection/outputs/demo_best.json"
```
