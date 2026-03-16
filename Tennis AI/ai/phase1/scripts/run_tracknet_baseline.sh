#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PHASE1_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TRACKNET_DIR="${PHASE1_DIR}/TrackNetV2"
VENV_DIR="${TRACKNET_DIR}/.venv"
VIDEOS_DIR="${TRACKNET_DIR}/experiments/videos"
RUNS_DIR="${TRACKNET_DIR}/experiments/runs"
LOGS_DIR="${RUNS_DIR}/logs"
COOKIE_BROWSER="${COOKIE_BROWSER:-chrome}"

URLS=(
  "https://www.youtube.com/watch?v=U6WhLVQQpPc"
  "https://www.youtube.com/watch?v=P-NHvA-LooM"
  "https://www.youtube.com/watch?v=FfyI1wYYiIA"
)

if [[ ! -d "${TRACKNET_DIR}" ]]; then
  echo "TrackNetV2 directory not found: ${TRACKNET_DIR}" >&2
  exit 1
fi

mkdir -p "${VIDEOS_DIR}" "${RUNS_DIR}" "${LOGS_DIR}"

if [[ ! -x "${VENV_DIR}/bin/python" ]]; then
  python3 -m venv "${VENV_DIR}"
fi

# shellcheck source=/dev/null
source "${VENV_DIR}/bin/activate"

python -m pip install --upgrade pip >/dev/null
python -m pip install \
  torch torchvision opencv-python tqdm yt-dlp torchsummary pyyaml >/dev/null

for url in "${URLS[@]}"; do
  yt-dlp \
    --js-runtimes node \
    --remote-components ejs:github \
    --cookies-from-browser "${COOKIE_BROWSER}" \
    --force-overwrites \
    --download-sections "*00:00:00-00:01:00" \
    -f "18/best[height<=360][ext=mp4]/best[ext=mp4]" \
    -o "${VIDEOS_DIR}/%(id)s_60s.%(ext)s" \
    "${url}"
done

for video_path in "${VIDEOS_DIR}"/*_60s.mp4; do
  video_file="$(basename "${video_path}")"
  base="${video_file%.mp4}"
  python "${TRACKNET_DIR}/detect.py" \
    --source "${video_path}" \
    --weights "${TRACKNET_DIR}/tf2torch/track.pt" \
    --save-txt \
    --project "${RUNS_DIR}" \
    --quiet \
    > "${LOGS_DIR}/${base}.log" 2>&1
done

RUNS_DIR_ABS="${RUNS_DIR}" python - <<'PY'
import csv
import glob
import os

run_dir = os.environ["RUNS_DIR_ABS"]
for csv_path in sorted(glob.glob(os.path.join(run_dir, "*_predict.csv"))):
    with open(csv_path, newline="") as f:
        rows = list(csv.DictReader(f))
    total = len(rows)
    visible = sum(1 for row in rows if row["visible"] == "1")
    pct = (visible / total * 100) if total else 0
    print(f"{os.path.basename(csv_path)}: visible={visible}/{total} ({pct:.2f}%)")
PY
