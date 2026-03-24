#!/usr/bin/env python3
"""
Convert GridTrackNet (Keras/TF) → CoreML TrackNet.mlmodel
===========================================================

Model facts (from VKorpelshoek/GridTrackNet)
--------------------------------------------
  Input  : float32 [1, IMGS*3, 432, 768]   channels_first, values in [0, 1]
           IMGS = 5 consecutive frames × 3 RGB channels = 15 input channels
  Output : float32 [1, IMGS*3, 27, 48]     (1/16 scale: 4 MaxPool layers)
           Per frame: channel k*3+0 = confidence grid   (27×48)
                      channel k*3+1 = x-offset grid     (27×48)
                      channel k*3+2 = y-offset grid     (27×48)
           Ball pixel: x = (col + x_off[row,col]) × (768/48)
                       y = (row + y_off[row,col]) × (432/27)

Usage
-----
    cd "Tennis AI"
    python ai/convert_tracknet.py

Output
------
    Tennis AI/TrackNet.mlmodel
    → Drag into Xcode, add to Tennis AI target (Build Phases → Copy Bundle Resources).
      Xcode compiles it to TrackNet.mlmodelc at build time.

iOS decoding (OnDeviceVideoAnalyzer)
-------------------------------------
    The iOS app reads the grid output, finds the argmax cell in the conf channel,
    applies the x/y offsets, and scales to source pixel coordinates.
    See decodeGridTrackNetOutput() in OnDeviceVideoAnalyzer.swift.
"""

import os
import sys
import tempfile
import argparse
from pathlib import Path

REPO_DIR      = Path(__file__).resolve().parent.parent / "GridTrackNet"
WEIGHTS_PATH  = REPO_DIR / "model_weights.h5"
OUTPUT_PATH   = Path(__file__).resolve().parent.parent / "Tennis AI" / "TrackNet.mlpackage"

IMGS_PER_INSTANCE = 5
INPUT_HEIGHT  = 432
INPUT_WIDTH   = 768


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def build_and_load(weights_path: Path):
    """Rebuild the GridTrackNet Keras model and load the pretrained weights."""
    sys.path.insert(0, str(REPO_DIR))
    # suppress TF log noise
    os.environ.setdefault("TF_CPP_MIN_LOG_LEVEL", "2")
    import tensorflow as tf
    tf.get_logger().setLevel("ERROR")
    from GridTrackNet import GridTrackNet as build_model

    print(f"  Building model (imgs={IMGS_PER_INSTANCE}, h={INPUT_HEIGHT}, w={INPUT_WIDTH}) ...")
    model = build_model(IMGS_PER_INSTANCE, INPUT_HEIGHT, INPUT_WIDTH)

    print(f"  Loading weights from: {weights_path}")
    model.load_weights(str(weights_path))

    in_shape  = model.input_shape   # (None, 15, 432, 768)
    out_shape = model.output_shape  # (None, 15, 27, 48)
    total_params = model.count_params()
    print(f"  Input shape : {in_shape}")
    print(f"  Output shape: {out_shape}")
    print(f"  Parameters  : {total_params:,}")
    return model


def to_saved_model(model, tmp_dir: str) -> str:
    """Export Keras model to TF SavedModel format."""
    saved_path = os.path.join(tmp_dir, "gridtracknet_saved")
    print(f"  Exporting to SavedModel: {saved_path}")
    model.save(saved_path, save_format="tf")
    return saved_path


def convert_to_coreml(saved_path: str, output_path: str):
    import coremltools as ct
    import numpy as np

    print(f"  Converting SavedModel → CoreML ...")
    mlmodel = ct.convert(
        saved_path,
        inputs=[
            ct.TensorType(
                name="input_1",
                shape=(1, IMGS_PER_INSTANCE * 3, INPUT_HEIGHT, INPUT_WIDTH),
                dtype=np.float32,
            )
        ],
        minimum_deployment_target=ct.target.iOS16,
        compute_units=ct.ComputeUnit.CPU_AND_NE,
    )

    mlmodel.short_description = (
        f"GridTrackNet tennis ball tracker — "
        f"{IMGS_PER_INSTANCE}-frame window, grid-based confidence+offset output"
    )
    mlmodel.input_description["input_1"] = (
        f"Stack of {IMGS_PER_INSTANCE} consecutive RGB frames "
        f"({IMGS_PER_INSTANCE}×3={IMGS_PER_INSTANCE*3} channels), "
        f"shape [1,{IMGS_PER_INSTANCE*3},{INPUT_HEIGHT},{INPUT_WIDTH}], values in [0,1]"
    )

    print(f"  Saving: {output_path}")
    mlmodel.save(output_path)
    # mlpackage is a directory bundle; report total size
    total = sum(f.stat().st_size for f in Path(output_path).rglob("*") if f.is_file())
    print(f"  Saved  (size: {total // 1024} KB)")


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="Convert GridTrackNet Keras model to CoreML")
    parser.add_argument("--weights", default=str(WEIGHTS_PATH),
                        help=f"Path to model_weights.h5 (default: {WEIGHTS_PATH})")
    parser.add_argument("--output",  default=str(OUTPUT_PATH),
                        help=f"Output .mlmodel path (default: {OUTPUT_PATH})")
    args = parser.parse_args()

    weights_path = Path(args.weights)
    output_path  = args.output

    print("GridTrackNet → CoreML converter")
    print("================================\n")

    if not REPO_DIR.is_dir():
        print(f"ERROR: GridTrackNet repo not found at {REPO_DIR}")
        print("Clone it first:  git clone https://github.com/VKorpelshoek/GridTrackNet GridTrackNet")
        sys.exit(1)

    if not weights_path.is_file():
        print(f"ERROR: Weights file not found: {weights_path}")
        sys.exit(1)

    print("[1/3] Loading Keras model ...")
    model = build_and_load(weights_path)

    with tempfile.TemporaryDirectory() as tmp_dir:
        print("\n[2/3] Exporting to SavedModel ...")
        saved_path = to_saved_model(model, tmp_dir)

        print("\n[3/3] Converting to CoreML ...")
        convert_to_coreml(saved_path, output_path)

    print(f"""
Done!
-----
Next steps:
  1. In Xcode, drag-and-drop:
       {output_path}
     into the 'Tennis AI' group in Project Navigator.
     Make sure the 'Tennis AI' target checkbox is ticked.

  2. Build (Cmd+B). Xcode compiles TrackNet.mlpackage → TrackNet.mlmodelc.

  3. Run the app — Workflow advanced settings will show "本地模型已就绪".
""")


if __name__ == "__main__":
    main()
