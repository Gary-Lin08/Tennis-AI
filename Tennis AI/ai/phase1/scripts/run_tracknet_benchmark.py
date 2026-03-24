#!/usr/bin/env python3
"""Convenience wrapper for the TrackNet fixed-camera benchmark."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parents[2]
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from benchmark_tracking_models import main as benchmark_main  # noqa: E402


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--python-bin", default=sys.executable)
    parser.add_argument(
        "--tracknet-script",
        type=Path,
        default=REPO_ROOT / "ai/phase1/tracknet_tennis/infer_tracknet_tennis.py",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    return benchmark_main(
        [
            "--manifest",
            str(args.manifest),
            "--model",
            "tracknet",
            "--output-dir",
            str(args.output_dir),
            "--python-bin",
            args.python_bin,
            "--tracknet-script",
            str(args.tracknet_script),
        ]
    )


if __name__ == "__main__":
    raise SystemExit(main())
