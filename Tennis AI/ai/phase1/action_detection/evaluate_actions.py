#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
from dataclasses import dataclass
from pathlib import Path


DEFAULT_CLASSES = ["forehand", "backhand", "serve", "unknown"]

FRAME_COLUMN_CANDIDATES = [
    "frame_num",
    "frame",
    "frame_index",
    "frameIndex",
    "idx",
]

LABEL_COLUMN_CANDIDATES = [
    "action_type",
    "action",
    "label",
    "type",
    "shot_type",
]

CONF_COLUMN_CANDIDATES = [
    "confidence",
    "conf",
    "score",
    "prob",
    "probability",
]


@dataclass
class Event:
    frame_num: int
    label: str
    confidence: float


def normalize_label(raw: str) -> str:
    value = raw.strip().lower()
    table = {
        "forehand": "forehand",
        "fore_hand": "forehand",
        "fh": "forehand",
        "正手": "forehand",
        "backhand": "backhand",
        "back_hand": "backhand",
        "bh": "backhand",
        "反手": "backhand",
        "serve": "serve",
        "service": "serve",
        "serving": "serve",
        "发球": "serve",
        "unknown": "unknown",
        "unk": "unknown",
        "other": "unknown",
        "na": "unknown",
        "n/a": "unknown",
        "none": "unknown",
        "未知": "unknown",
    }
    return table.get(value, value)


def choose_column(explicit: str | None, header: list[str], candidates: list[str], role: str) -> str:
    if explicit is not None:
        if explicit not in header:
            raise ValueError(f"Missing {role} column '{explicit}' in CSV header: {header}")
        return explicit

    for key in candidates:
        if key in header:
            return key
    raise ValueError(f"Cannot infer {role} column from header: {header}")


def parse_events(
    csv_path: Path,
    frame_col: str | None,
    label_col: str | None,
    conf_col: str | None,
    min_confidence: float,
    ignore_labels: set[str],
) -> tuple[list[Event], dict[str, str | None]]:
    with csv_path.open("r", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        if reader.fieldnames is None:
            raise ValueError(f"CSV has no header: {csv_path}")
        header = reader.fieldnames

        frame_key = choose_column(frame_col, header, FRAME_COLUMN_CANDIDATES, "frame")
        label_key = choose_column(label_col, header, LABEL_COLUMN_CANDIDATES, "label")

        conf_key = None
        if conf_col is not None:
            conf_key = choose_column(conf_col, header, CONF_COLUMN_CANDIDATES + [conf_col], "confidence")
        else:
            for cand in CONF_COLUMN_CANDIDATES:
                if cand in header:
                    conf_key = cand
                    break

        events: list[Event] = []
        for row in reader:
            raw_label = (row.get(label_key) or "").strip()
            if raw_label == "":
                continue

            label = normalize_label(raw_label)
            if label in ignore_labels:
                continue

            raw_frame = (row.get(frame_key) or "").strip()
            if raw_frame == "":
                continue

            try:
                frame_num = int(float(raw_frame))
            except ValueError:
                continue

            confidence = 1.0
            if conf_key is not None:
                raw_conf = (row.get(conf_key) or "").strip()
                if raw_conf:
                    try:
                        confidence = float(raw_conf)
                    except ValueError:
                        confidence = 0.0
                else:
                    confidence = 0.0

            if confidence < min_confidence:
                continue

            events.append(Event(frame_num=frame_num, label=label, confidence=confidence))

    events.sort(key=lambda e: e.frame_num)
    columns_used = {
        "frame": frame_key,
        "label": label_key,
        "confidence": conf_key,
    }
    return events, columns_used


def greedy_match(gt_events: list[Event], pred_events: list[Event], tolerance_frames: int) -> list[tuple[int, int]]:
    matched_pairs: list[tuple[int, int]] = []
    used_pred: set[int] = set()

    for gt_idx, gt in enumerate(gt_events):
        best_pred_idx = None
        best_delta = tolerance_frames + 1
        best_conf = -1.0

        for pred_idx, pred in enumerate(pred_events):
            if pred_idx in used_pred:
                continue
            delta = abs(pred.frame_num - gt.frame_num)
            if delta > tolerance_frames:
                continue
            if delta < best_delta or (delta == best_delta and pred.confidence > best_conf):
                best_delta = delta
                best_conf = pred.confidence
                best_pred_idx = pred_idx

        if best_pred_idx is not None:
            used_pred.add(best_pred_idx)
            matched_pairs.append((gt_idx, best_pred_idx))

    return matched_pairs


def init_confusion(classes: list[str]) -> dict[str, dict[str, int]]:
    rows = classes + ["spurious"]
    cols = classes + ["missing"]
    return {row: {col: 0 for col in cols} for row in rows}


def safe_div(num: float, den: float) -> float:
    return num / den if den > 0 else 0.0


def compute_report(
    gt_events: list[Event],
    pred_events: list[Event],
    classes: list[str],
    tolerance_frames: int,
) -> dict:
    matches = greedy_match(gt_events, pred_events, tolerance_frames=tolerance_frames)
    gt_to_pred = {gt_idx: pred_idx for gt_idx, pred_idx in matches}
    matched_pred_indices = {pred_idx for _, pred_idx in matches}

    confusion = init_confusion(classes)

    for gt_idx, gt in enumerate(gt_events):
        if gt.label not in classes:
            continue
        if gt_idx in gt_to_pred:
            pred = pred_events[gt_to_pred[gt_idx]]
            pred_label = pred.label if pred.label in classes else "unknown"
            confusion[gt.label][pred_label] += 1
        else:
            confusion[gt.label]["missing"] += 1

    for pred_idx, pred in enumerate(pred_events):
        if pred_idx in matched_pred_indices:
            continue
        pred_label = pred.label if pred.label in classes else "unknown"
        confusion["spurious"][pred_label] += 1

    per_class = []
    total_tp = 0
    total_fp = 0
    total_fn = 0

    for cls in classes:
        tp = confusion[cls][cls]
        fp = sum(confusion[other][cls] for other in classes if other != cls) + confusion["spurious"][cls]
        fn = sum(confusion[cls][other] for other in classes if other != cls) + confusion[cls]["missing"]
        support = sum(confusion[cls][col] for col in (classes + ["missing"]))

        precision = safe_div(tp, tp + fp)
        recall = safe_div(tp, tp + fn)
        f1 = safe_div(2 * precision * recall, precision + recall)

        total_tp += tp
        total_fp += fp
        total_fn += fn

        per_class.append(
            {
                "class": cls,
                "support": support,
                "tp": tp,
                "fp": fp,
                "fn": fn,
                "precision": precision,
                "recall": recall,
                "f1": f1,
            }
        )

    gt_total = len([e for e in gt_events if e.label in classes])
    pred_total = len(pred_events)
    matched_total = len(matches)
    correct = sum(confusion[cls][cls] for cls in classes)

    macro_f1_support = [row["f1"] for row in per_class if row["support"] > 0]
    macro_f1 = sum(macro_f1_support) / len(macro_f1_support) if macro_f1_support else 0.0

    classification_accuracy_on_gt = safe_div(correct, gt_total)
    classification_accuracy_on_matched = safe_div(correct, matched_total)

    micro_precision = safe_div(total_tp, total_tp + total_fp)
    micro_recall = safe_div(total_tp, total_tp + total_fn)
    micro_f1 = safe_div(2 * micro_precision * micro_recall, micro_precision + micro_recall)

    detection_precision = safe_div(matched_total, pred_total)
    detection_recall = safe_div(matched_total, gt_total)
    detection_f1 = safe_div(2 * detection_precision * detection_recall, detection_precision + detection_recall)

    return {
        "overview": {
            "gt_events": gt_total,
            "pred_events": pred_total,
            "matched_events": matched_total,
            "correct_classifications": correct,
            "classification_accuracy_on_gt": classification_accuracy_on_gt,
            "classification_accuracy_on_matched": classification_accuracy_on_matched,
            "macro_f1": macro_f1,
            "micro_precision": micro_precision,
            "micro_recall": micro_recall,
            "micro_f1": micro_f1,
            "detection_precision": detection_precision,
            "detection_recall": detection_recall,
            "detection_f1": detection_f1,
        },
        "per_class": per_class,
        "confusion_matrix": confusion,
    }


def write_confusion_csv(path: Path, classes: list[str], matrix: dict[str, dict[str, int]]) -> None:
    rows = classes + ["spurious"]
    cols = classes + ["missing"]

    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["true\\pred", *cols])
        for row in rows:
            writer.writerow([row, *[matrix[row][col] for col in cols]])


def print_report(report: dict) -> None:
    ov = report["overview"]
    print("Overview:")
    print(f"- gt_events: {ov['gt_events']}")
    print(f"- pred_events: {ov['pred_events']}")
    print(f"- matched_events: {ov['matched_events']}")
    print(f"- correct_classifications: {ov['correct_classifications']}")
    print(f"- classification_accuracy_on_gt: {ov['classification_accuracy_on_gt']:.4f}")
    print(f"- classification_accuracy_on_matched: {ov['classification_accuracy_on_matched']:.4f}")
    print(f"- macro_f1: {ov['macro_f1']:.4f}")
    print(f"- micro_precision: {ov['micro_precision']:.4f}")
    print(f"- micro_recall: {ov['micro_recall']:.4f}")
    print(f"- micro_f1: {ov['micro_f1']:.4f}")
    print(f"- detection_precision: {ov['detection_precision']:.4f}")
    print(f"- detection_recall: {ov['detection_recall']:.4f}")
    print(f"- detection_f1: {ov['detection_f1']:.4f}")

    print("\nPer-class:")
    for row in report["per_class"]:
        print(
            f"- {row['class']}: support={row['support']}, TP={row['tp']}, FP={row['fp']}, FN={row['fn']}, "
            f"P={row['precision']:.4f}, R={row['recall']:.4f}, F1={row['f1']:.4f}"
        )


def main() -> None:
    parser = argparse.ArgumentParser(description="Evaluate tennis action-event predictions with temporal tolerance.")
    parser.add_argument("--gt-csv", required=True, type=Path, help="Ground-truth events CSV")
    parser.add_argument("--pred-csv", required=True, type=Path, help="Predicted events CSV")
    parser.add_argument(
        "--classes",
        type=str,
        default=",".join(DEFAULT_CLASSES),
        help="Comma-separated class list, e.g. forehand,backhand,serve,unknown",
    )
    parser.add_argument("--tolerance-frames", type=int, default=4, help="Frame matching tolerance (default: 4)")
    parser.add_argument("--min-confidence", type=float, default=0.0, help="Drop predictions below this score")

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

    parser.add_argument("--output-json", type=Path, default=None, help="Optional output report json")
    parser.add_argument("--output-confusion-csv", type=Path, default=None, help="Optional confusion matrix csv")

    args = parser.parse_args()

    class_list = [normalize_label(c) for c in args.classes.split(",") if c.strip()]
    class_list = list(dict.fromkeys(class_list))
    if "unknown" not in class_list:
        class_list.append("unknown")

    ignore_labels = {
        normalize_label(x)
        for x in args.ignore_labels.split(",")
        if x.strip()
    }

    gt_events, gt_cols = parse_events(
        csv_path=args.gt_csv,
        frame_col=args.gt_frame_col,
        label_col=args.gt_label_col,
        conf_col=None,
        min_confidence=0.0,
        ignore_labels=ignore_labels,
    )

    pred_events, pred_cols = parse_events(
        csv_path=args.pred_csv,
        frame_col=args.pred_frame_col,
        label_col=args.pred_label_col,
        conf_col=args.pred_confidence_col,
        min_confidence=max(0.0, args.min_confidence),
        ignore_labels=ignore_labels,
    )

    gt_events = [e for e in gt_events if e.label in class_list]
    pred_events = [e for e in pred_events if e.label in class_list]

    report = compute_report(
        gt_events=gt_events,
        pred_events=pred_events,
        classes=class_list,
        tolerance_frames=max(0, args.tolerance_frames),
    )

    report["meta"] = {
        "gt_csv": str(args.gt_csv.resolve()),
        "pred_csv": str(args.pred_csv.resolve()),
        "columns_used": {
            "gt": gt_cols,
            "pred": pred_cols,
        },
        "classes": class_list,
        "tolerance_frames": max(0, args.tolerance_frames),
        "min_confidence": max(0.0, args.min_confidence),
        "ignore_labels": sorted(ignore_labels),
    }

    print_report(report)

    if args.output_json is not None:
        args.output_json.parent.mkdir(parents=True, exist_ok=True)
        args.output_json.write_text(json.dumps(report, indent=2), encoding="utf-8")
        print(f"\nreport_json={args.output_json.resolve()}")

    if args.output_confusion_csv is not None:
        write_confusion_csv(
            path=args.output_confusion_csv,
            classes=class_list,
            matrix=report["confusion_matrix"],
        )
        print(f"confusion_csv={args.output_confusion_csv.resolve()}")


if __name__ == "__main__":
    main()
