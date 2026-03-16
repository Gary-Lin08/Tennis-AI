# Action Detection Evaluation

Offline evaluator for action-event quality (`forehand`, `backhand`, `serve`, `unknown`).

## Input CSV format

Ground-truth CSV requires:

- frame column: one of `frame_num` / `frame` / `frame_index` / `frameIndex`
- label column: one of `action_type` / `action` / `label` / `type`

Prediction CSV requires:

- frame column: same rule as above
- label column: same rule as above
- optional confidence column: `confidence` / `conf` / `score` / `prob`

Label aliases are normalized automatically:

- `正手`, `fh` -> `forehand`
- `反手`, `bh` -> `backhand`
- `发球`, `service` -> `serve`
- `未知`, `na`, `other` -> `unknown`

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
```

## Grid Search (Auto-Tune Thresholds)

```bash
cd "/Users/kl/Desktop/Tennisvisionclone/Tennis AI"
python ai/phase1/action_detection/grid_search_actions.py \
  --gt-csv "ai/phase1/action_detection/labels/demo_gt.csv" \
  --pred-csv "ai/phase1/action_detection/labels/demo_pred.csv" \
  --tolerance-grid "2,3,4,5,6" \
  --confidence-grid "0.0,0.2,0.3,0.35,0.4,0.45,0.5" \
  --optimize macro_f1 \
  --output-leaderboard-csv "ai/phase1/action_detection/outputs/demo_grid.csv" \
  --output-best-json "ai/phase1/action_detection/outputs/demo_best.json"
```

Outputs:

- `demo_grid.csv`: full ranking of all parameter combinations.
- `demo_best.json`: best setting + top-k summary + confusion matrix for the best run.

## Metrics

- `classification_accuracy_on_gt`: correct class / GT events.
- `macro_f1`: average class F1 over GT-supported classes.
- `micro_precision`, `micro_recall`, `micro_f1`: global classification metrics.
- `detection_precision`, `detection_recall`, `detection_f1`: event matching quality regardless of class.
- confusion matrix:
  - row `spurious`: predicted events not matched to any GT.
  - column `missing`: GT events not matched by any prediction.

## Notes

- One-to-one greedy matching is used within `--tolerance-frames`.
- Use `--ignore-labels unknown` if your current GT only annotates known actions.
- You can override column names via:
  - `--gt-frame-col`, `--gt-label-col`
  - `--pred-frame-col`, `--pred-label-col`, `--pred-confidence-col`
