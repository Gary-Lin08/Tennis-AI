# Tracking Benchmark Harness

This folder defines the fixed-camera benchmark contract for `TrackNet` and `GridTrackNet`.

## Scope

- Target only `behind-baseline / tripod / fixed-camera` training videos.
- Keep iOS out of this loop. These scripts are for offline model evaluation only.
- Output one JSON report per benchmark run so model regressions are easy to compare.

## Dataset Manifest

Use `dataset_manifest.example.json` as the template.

Each entry should include:

- `id`: stable clip identifier.
- `video`: absolute or repo-relative video path.
- `tags`: scene labels such as `fixed-camera`, `behind-baseline`, `usable`.
- `court_json` (optional): court detection JSON for TrackNet runs.
- `ground_truth_csv` (optional): frame-level ball labels with `frame_num,visible,x,y`.
- `bounce_gt_json` (optional): reserved for future bounce recall/precision evaluation.

## Commands

TrackNet benchmark:

```bash
cd "/Users/kaijunlin/Desktop/Tennisvisionclone/Tennis AI"
python3 ai/phase1/scripts/run_tracknet_benchmark.py \
  --manifest ai/phase1/benchmarks/dataset_manifest.example.json \
  --output-dir ai/phase1/benchmarks/outputs
```

GridTrackNet adapter benchmark:

```bash
cd "/Users/kaijunlin/Desktop/Tennisvisionclone/Tennis AI"
python3 ai/phase1/scripts/benchmark_tracking_models.py \
  --manifest ai/phase1/benchmarks/dataset_manifest.example.json \
  --model gridtracknet \
  --gridtracknet-repo /absolute/path/to/GridTrackNet \
  --output-dir ai/phase1/benchmarks/outputs
```

## Output Contract

Each benchmark run writes one JSON file with:

- `model`
- `dataset_version`
- `generated_at`
- `environment`
- `runs`
- `aggregate_metrics`

The metrics object keeps a stable shape even when some labels are missing:

- `visible_rate`
- `pixel_mean_error`
- `trajectory_continuity`
- `bounce_precision`
- `bounce_recall`
- `action_stability`
- `inference_wall_time_seconds`

Unavailable metrics are written as `null`. This keeps reports comparable while the labeling set is still growing.
