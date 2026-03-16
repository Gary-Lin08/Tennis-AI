# Court Detection (Task01)

This module detects 4 tennis-court corners with a Hough-line pipeline and computes
the image-to-court homography matrix.

## Files

- `detect_court.py`: main detector (image/video input)
- `evaluate_corners.py`: compare predicted corners against manual GT labels
- `samples/`: local extracted test frames (optional)
- `outputs/`: generated json and visualization artifacts

## Run

Use the existing Phase 1 virtualenv that already has OpenCV:

```bash
cd "/Users/kl/Desktop/Tennisvisionclone/Tennis AI/ai/phase1/TrackNetV2"
source .venv/bin/activate
cd "/Users/kl/Desktop/Tennisvisionclone/Tennis AI"
python ai/phase1/court_detection/detect_court.py \
  --input "ai/phase1/TrackNetV2/experiments/videos/U6WhLVQQpPc_60s.mp4" \
  --output-dir "ai/phase1/court_detection/outputs"
```

## Output

`*_court_detection.json` includes:

- 4 corners in pixels (`top_left/top_right/bottom_right/bottom_left`)
- homography (`homography_img_to_court`)
- inverse homography (`homography_court_to_img`)
- quality stats (`score`, `valid_detections`, `px_per_meter_near_baseline`)

Also written:

- `*_court_overlay.jpg`: source frame with corners and polygon
- `*_topdown.jpg`: perspective-warped top-down court view

## Optional evaluation with labeled corners

Ground truth file format:

```json
{
  "corners_px": {
    "top_left": [263, 45],
    "top_right": [457, 45],
    "bottom_right": [399, 327],
    "bottom_left": [236, 327]
  }
}
```

Run:

```bash
python ai/phase1/court_detection/evaluate_corners.py \
  --prediction "ai/phase1/court_detection/outputs/U6WhLVQQpPc_60s_court_detection.json" \
  --gt "ai/phase1/court_detection/outputs/U6WhLVQQpPc_60s_gt.json"
```
