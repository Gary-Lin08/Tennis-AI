#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path

from evaluate_actions import compute_report, normalize_label, parse_events


DEFAULT_TOLERANCE_GRID = [2, 3, 4, 5, 6]
DEFAULT_CONFIDENCE_GRID = [0.0, 0.2, 0.3, 0.35, 0.4, 0.45, 0.5, 0.55, 0.6]
DEFAULT_CLASSES = ["forehand", "backhand", "serve", "unknown"]


def parse_int_grid(raw: str, default_values: list[int]) -> list[int]:
    values: list[int] = []
    for token in raw.split(","):
        token = token.strip()
        if not token:
            continue
        values.append(int(token))
    if not values:
        values = default_values
    return sorted(set(max(0, v) for v in values))


def parse_float_grid(raw: str, default_values: list[float]) -> list[float]:
    values: list[float] = []
    for token in raw.split(","):
        token = token.strip()
        if not token:
            continue
        values.append(float(token))
    if not values:
        values = default_values
    clipped = [min(max(0.0, v), 1.0) for v in values]
    return sorted(set(round(v, 6) for v in clipped))


def write_leaderboard_csv(path: Path, rows: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fields = [
        "rank",
        "tolerance_frames",
        "min_confidence",
        "classification_accuracy_on_gt",
        "macro_f1",
        "micro_f1",
        "detection_f1",
        "detection_precision",
        "detection_recall",
        "pred_events",
        "matched_events",
        "correct_classifications",
    ]
    with path.open("w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fields)
        writer.writeheader()
        for idx, row in enumerate(rows, start=1):
            ov = row["overview"]
            writer.writerow(
                {
                    "rank": idx,
                    "tolerance_frames": row["tolerance_frames"],
                    "min_confidence": row["min_confidence"],
                    "classification_accuracy_on_gt": f"{ov['classification_accuracy_on_gt']:.6f}",
                    "macro_f1": f"{ov['macro_f1']:.6f}",
                    "micro_f1": f"{ov['micro_f1']:.6f}",
                    "detection_f1": f"{ov['detection_f1']:.6f}",
                    "detection_precision": f"{ov['detection_precision']:.6f}",
                    "detection_recall": f"{ov['detection_recall']:.6f}",
                    "pred_events": ov["pred_events"],
                    "matched_events": ov["matched_events"],
                    "correct_classifications": ov["correct_classifications"],
                }
            )


def print_top(rows: list[dict], top_k: int, optimize_metric: str) -> None:
    print(f"Grid search completed: {len(rows)} combinations")
    print(f"Optimize metric: {optimize_metric}")
    print(f"Top {top_k}:")
    for idx, row in enumerate(rows[:top_k], start=1):
        ov = row["overview"]
        print(
            f"- #{idx}: tol={row['tolerance_frames']}, conf={row['min_confidence']:.2f}, "
            f"acc={ov['classification_accuracy_on_gt']:.4f}, macro_f1={ov['macro_f1']:.4f}, "
            f"micro_f1={ov['micro_f1']:.4f}, det_f1={ov['detection_f1']:.4f}, "
            f"pred={ov['pred_events']}, matched={ov['matched_events']}"
        )


def metric_key(metric_name: str, row: dict) -> float:
    return float(row["overview"][metric_name])


def main() -> None:
    parser = argparse.ArgumentParser(description="Grid search tolerance/confidence for action-event evaluation.")
    parser.add_argument("--gt-csv", required=True, type=Path, help="Ground-truth events CSV")
    parser.add_argument("--pred-csv", required=True, type=Path, help="Predicted events CSV")

    parser.add_argument(
        "--classes",
        type=str,
        default=",".join(DEFAULT_CLASSES),
        help="Comma-separated class list, e.g. forehand,backhand,serve,unknown",
    )
    parser.add_argument(
        "--tolerance-grid",
        type=str,
        default=",".join(str(v) for v in DEFAULT_TOLERANCE_GRID),
        help="Comma-separated tolerance frame candidates",
    )
    parser.add_argument(
        "--confidence-grid",
        type=str,
        default=",".join(str(v) for v in DEFAULT_CONFIDENCE_GRID),
        help="Comma-separated confidence threshold candidates in [0,1]",
    )

    parser.add_argument(
        "--optimize",
        type=str,
        default="macro_f1",
        choices=[
            "macro_f1",
            "micro_f1",
            "classification_accuracy_on_gt",
            "detection_f1",
            "detection_recall",
            "detection_precision",
        ],
        help="Objective metric",
    )
    parser.add_argument("--top-k", type=int, default=10, help="Print top-k results")

    parser.add_argument("--gt-frame-col", type=str, default=None, help="Override GT frame column name")
    parser.add_argument("--gt-label-col", type=str, default=None, help="Override GT label column name")
    parser.add_argument("--pred-frame-col", type=str, default=None, help="Override prediction frame column name")
    parser.add_argument("--pred-label-col", type=str, default=None, help="Override prediction label column name")
    parser.add_argument("--pred-confidence-col", type=str, default=None, help="Override prediction confidence column name")
    parser.add_argument(
        "--ignore-labels",
        type=str,
        default="",
        help="Comma-separated labels to ignore (applies to GT + predictions)",
    )

    parser.add_argument(
        "--output-leaderboard-csv",
        type=Path,
        default=None,
        help="Optional csv output for all combinations sorted by objective",
    )
    parser.add_argument(
        "--output-best-json",
        type=Path,
        default=None,
        help="Optional json report for the best combination",
    )
    args = parser.parse_args()

    classes = [normalize_label(c) for c in args.classes.split(",") if c.strip()]
    classes = list(dict.fromkeys(classes))
    if "unknown" not in classes:
        classes.append("unknown")

    ignore_labels = {
        normalize_label(x)
        for x in args.ignore_labels.split(",")
        if x.strip()
    }

    tolerance_grid = parse_int_grid(args.tolerance_grid, DEFAULT_TOLERANCE_GRID)
    confidence_grid = parse_float_grid(args.confidence_grid, DEFAULT_CONFIDENCE_GRID)

    gt_events_raw, gt_cols = parse_events(
        csv_path=args.gt_csv,
        frame_col=args.gt_frame_col,
        label_col=args.gt_label_col,
        conf_col=None,
        min_confidence=0.0,
        ignore_labels=ignore_labels,
    )
    pred_events_raw, pred_cols = parse_events(
        csv_path=args.pred_csv,
        frame_col=args.pred_frame_col,
        label_col=args.pred_label_col,
        conf_col=args.pred_confidence_col,
        min_confidence=0.0,
        ignore_labels=ignore_labels,
    )

    gt_events = [e for e in gt_events_raw if e.label in classes]
    pred_events = [e for e in pred_events_raw if e.label in classes]

    rows: list[dict] = []
    for tol in tolerance_grid:
        for conf in confidence_grid:
            filtered_pred = [e for e in pred_events if e.confidence >= conf]
            report = compute_report(
                gt_events=gt_events,
                pred_events=filtered_pred,
                classes=classes,
                tolerance_frames=tol,
            )
            rows.append(
                {
                    "tolerance_frames": tol,
                    "min_confidence": conf,
                    "overview": report["overview"],
                    "per_class": report["per_class"],
                    "confusion_matrix": report["confusion_matrix"],
                }
            )

    rows.sort(
        key=lambda row: (
            metric_key(args.optimize, row),
            row["overview"]["detection_recall"],
            row["overview"]["micro_f1"],
            -row["min_confidence"],
            -row["tolerance_frames"],
        ),
        reverse=True,
    )

    top_k = max(1, min(args.top_k, len(rows)))
    print_top(rows, top_k=top_k, optimize_metric=args.optimize)

    if args.output_leaderboard_csv is not None:
        write_leaderboard_csv(args.output_leaderboard_csv, rows)
        print(f"leaderboard_csv={args.output_leaderboard_csv.resolve()}")

    if args.output_best_json is not None:
        best = rows[0]
        payload = {
            "meta": {
                "gt_csv": str(args.gt_csv.resolve()),
                "pred_csv": str(args.pred_csv.resolve()),
                "columns_used": {
                    "gt": gt_cols,
                    "pred": pred_cols,
                },
                "classes": classes,
                "ignore_labels": sorted(ignore_labels),
                "optimize": args.optimize,
                "grid": {
                    "tolerance_frames": tolerance_grid,
                    "min_confidence": confidence_grid,
                },
            },
            "best": best,
            "top_k": rows[:top_k],
        }
        args.output_best_json.parent.mkdir(parents=True, exist_ok=True)
        args.output_best_json.write_text(json.dumps(payload, indent=2), encoding="utf-8")
        print(f"best_json={args.output_best_json.resolve()}")


if __name__ == "__main__":
    main()
