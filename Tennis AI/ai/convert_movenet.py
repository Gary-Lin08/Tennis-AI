#!/usr/bin/env python3
"""
Convert the official MoveNet SinglePose Lightning model to Core ML.

The upstream README for antoinekeller/tennis_shot_recognition points to the
MoveNet "singlepose/lightning" model as the pose frontend. This script fetches
the official TF-Hub SavedModel, converts it to a Core ML mlpackage, and writes
the result into the app target so Xcode can compile it into .mlmodelc at build
time.

Usage
-----
python ai/convert_movenet.py

python ai/convert_movenet.py \
  --source-saved-model /path/to/extracted/saved_model \
  --output "Tennis AI/MoveNetSinglePoseLightning.mlpackage"
"""

from __future__ import annotations

import argparse
import shutil
import tarfile
import tempfile
import urllib.request
from pathlib import Path

import coremltools as ct
import numpy as np
import tensorflow as tf


TFHUB_COMPRESSED_URL = (
    "https://tfhub.dev/google/movenet/singlepose/lightning/4?tf-hub-format=compressed"
)
DEFAULT_OUTPUT = (
    Path(__file__).resolve().parent.parent / "Tennis AI" / "MoveNetSinglePoseLightning.mlpackage"
)
INPUT_NAME = "input"
OUTPUT_NAME = "Identity"
INPUT_SHAPE = (1, 192, 192, 3)


def download_and_extract_saved_model(url: str) -> Path:
    temp_dir = Path(tempfile.mkdtemp(prefix="movenet_saved_model_"))
    archive_path = temp_dir / "movenet_saved_model.tar.gz"
    urllib.request.urlretrieve(url, archive_path)

    extract_dir = temp_dir / "extracted"
    extract_dir.mkdir(parents=True, exist_ok=True)

    with tarfile.open(archive_path, "r:gz") as archive:
        archive.extractall(extract_dir)

    return extract_dir


def resolve_saved_model_root(path: Path) -> Path:
    if (path / "saved_model.pb").is_file():
        return path

    candidates = list(path.rglob("saved_model.pb"))
    if len(candidates) == 1:
        return candidates[0].parent

    raise FileNotFoundError(f"Could not locate saved_model.pb under {path}")


def convert_saved_model(saved_model_dir: Path, output_path: Path) -> None:
    loaded = tf.saved_model.load(str(saved_model_dir))
    signature = loaded.signatures["serving_default"]
    tensor_name = next(iter(signature.structured_input_signature[1].keys()))

    mlmodel = ct.convert(
        str(saved_model_dir),
        source="tensorflow",
        convert_to="mlprogram",
        inputs=[
            ct.TensorType(
                name=tensor_name,
                shape=INPUT_SHAPE,
                dtype=np.int32,
            )
        ],
        minimum_deployment_target=ct.target.iOS15,
    )

    spec = mlmodel.get_spec()
    spec.description.metadata.shortDescription = (
        "Official MoveNet SinglePose Lightning model converted from TF-Hub for Tennis AI."
    )
    spec.description.metadata.author = "Converted for Tennis AI on-device pose extraction"
    spec.description.metadata.license = "Refer to the upstream TensorFlow Hub model card"

    if spec.description.input:
        spec.description.input[0].shortDescription = (
            "RGB tensor with shape [1,192,192,3], padded like tf.image.resize_with_pad."
        )
    if spec.description.output:
        spec.description.output[0].shortDescription = (
            "MoveNet keypoints in [y, x, score] order with shape [1,1,17,3]."
        )

    mlmodel = ct.models.MLModel(spec, weights_dir=mlmodel.weights_dir)
    mlmodel.user_defined_metadata["source_repo"] = "https://tfhub.dev/google/movenet/singlepose/lightning/4"
    mlmodel.user_defined_metadata["source_pipeline"] = (
        "antoinekeller/tennis_shot_recognition README MoveNet frontend"
    )
    mlmodel.user_defined_metadata["input_layout"] = "NHWC int32"
    mlmodel.user_defined_metadata["output_layout"] = "1x1x17x3 [y,x,score]"

    output_path.parent.mkdir(parents=True, exist_ok=True)
    if output_path.exists():
        shutil.rmtree(output_path)
    mlmodel.save(str(output_path))


def main() -> None:
    parser = argparse.ArgumentParser(description="Convert MoveNet SinglePose Lightning to Core ML.")
    parser.add_argument(
        "--source-saved-model",
        type=Path,
        help="Optional local SavedModel directory. If omitted, the official TF-Hub model is downloaded.",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=DEFAULT_OUTPUT,
        help=f"Output .mlpackage path (default: {DEFAULT_OUTPUT})",
    )
    args = parser.parse_args()

    output_path = args.output.expanduser().resolve()

    if args.source_saved_model:
        saved_model_root = resolve_saved_model_root(args.source_saved_model.expanduser().resolve())
    else:
        extracted_dir = download_and_extract_saved_model(TFHUB_COMPRESSED_URL)
        saved_model_root = resolve_saved_model_root(extracted_dir)

    print(f"Converting {saved_model_root}")
    convert_saved_model(saved_model_root, output_path)
    print(f"Saved {output_path}")


if __name__ == "__main__":
    main()
