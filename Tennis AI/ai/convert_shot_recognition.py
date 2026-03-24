#!/usr/bin/env python3
"""
Convert antoinekeller/tennis_shot_recognition's tennis_rnn.h5 to Core ML.

The upstream repository stores the Keras model in legacy HDF5 format. Recent
TensorFlow / h5py combinations can be finicky when loading it directly, so this
script rebuilds the network from the embedded JSON config and then injects the
weights manually before converting to Core ML.

Usage
-----
python ai/convert_shot_recognition.py \
  --source-model /path/to/tennis_shot_recognition/tennis_rnn.h5

Output
------
Tennis AI/ShotRecognitionRNN.mlpackage
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import coremltools as ct
import h5py
import numpy as np
from tensorflow import keras


OUTPUT_PATH = Path(__file__).resolve().parent.parent / "Tennis AI" / "ShotRecognitionRNN.mlpackage"
SEQUENCE_LENGTH = 30
FEATURE_COUNT = 26
INPUT_NAME = "gru_input"
OUTPUT_NAME = "Identity"


def rebuild_model_from_h5(source_model: Path) -> keras.Model:
    with h5py.File(source_model, "r") as handle:
        model_config = json.loads(handle.attrs["model_config"])
        model = keras.models.model_from_json(json.dumps(model_config))
        weights_root = handle["model_weights"]
        model.set_weights(
            [
                weights_root["gru"]["gru"]["gru_cell"]["kernel:0"][()],
                weights_root["gru"]["gru"]["gru_cell"]["recurrent_kernel:0"][()],
                weights_root["gru"]["gru"]["gru_cell"]["bias:0"][()],
                weights_root["dense"]["dense"]["kernel:0"][()],
                weights_root["dense"]["dense"]["bias:0"][()],
                weights_root["dense_1"]["dense_1"]["kernel:0"][()],
                weights_root["dense_1"]["dense_1"]["bias:0"][()],
            ]
        )
        return model


def convert_model(model: keras.Model, output_path: Path) -> None:
    mlmodel = ct.convert(
        model,
        source="tensorflow",
        convert_to="mlprogram",
        inputs=[
            ct.TensorType(
                name=INPUT_NAME,
                shape=(1, SEQUENCE_LENGTH, FEATURE_COUNT),
                dtype=np.float32,
            )
        ],
        minimum_deployment_target=ct.target.iOS15,
    )

    mlmodel.short_description = "Tennis shot recognition RNN from antoinekeller/tennis_shot_recognition"
    mlmodel.author = "Converted for Tennis AI local on-device inference"
    mlmodel.input_description[INPUT_NAME] = (
        "Pose sequence with shape [1,30,26]. Feature order follows the upstream repo: "
        "13 keypoints x (y,x), normalized within the player's tracked body box."
    )
    mlmodel.output_description[OUTPUT_NAME] = (
        "Softmax probabilities in upstream class order: [backhand, forehand, neutral, serve]."
    )
    mlmodel.user_defined_metadata["source_repo"] = "https://github.com/antoinekeller/tennis_shot_recognition"
    mlmodel.user_defined_metadata["class_order"] = "backhand,forehand,neutral,serve"

    output_path.parent.mkdir(parents=True, exist_ok=True)
    mlmodel.save(str(output_path))


def main() -> None:
    parser = argparse.ArgumentParser(description="Convert tennis_shot_recognition RNN to Core ML.")
    parser.add_argument(
        "--source-model",
        type=Path,
        required=True,
        help="Path to the upstream tennis_rnn.h5 file.",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=OUTPUT_PATH,
        help=f"Output .mlpackage path (default: {OUTPUT_PATH})",
    )
    args = parser.parse_args()

    source_model = args.source_model.expanduser().resolve()
    output_path = args.output.expanduser().resolve()

    if not source_model.is_file():
        raise FileNotFoundError(f"Source model not found: {source_model}")

    print(f"Loading {source_model}")
    model = rebuild_model_from_h5(source_model)
    print("Converting to Core ML...")
    convert_model(model, output_path)
    print(f"Saved {output_path}")


if __name__ == "__main__":
    main()
