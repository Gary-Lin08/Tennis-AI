# Tennis AI

Tennis AI is currently positioned as an `iOS on-device training analysis prototype v1`.

## What lives here

- `Tennis AI/`: SwiftUI app for local video intake, on-device TrackNet inference, pose-based shot recognition, playback, export, comparison, and telemetry
- `ai/backend/`: FastAPI + Supabase ingestion and telemetry dashboard
- `ai/phase1/`: offline Python pipeline for high-fidelity rally / shot / bounce / score generation

## Product boundary

- iOS app is the user-facing product surface.
- iOS sync mode is `ios.ondevice.v1`: it uploads summary sessions only.
- Python Phase 1 is the full-detail analytics lane and remains the source for normalized rally / shot / bounce / score data.

## Source of truth

- Playback, export, comparison, and local session history: iOS on-device session data
- Structured match analytics and normalized child tables: Python Phase 1 exports
- Telemetry and ops dashboard: FastAPI + Supabase

See `docs/architecture.md` for the full data-flow diagram and integration rules.

## Quick start

### iOS app

```bash
cd "/Users/kaijunlin/Desktop/Tennisvisionclone/Tennis AI"
xcodebuild -project "Tennis AI.xcodeproj" -scheme "Tennis AI" -destination "generic/platform=iOS Simulator" build
```

### Backend

```bash
cd "/Users/kaijunlin/Desktop/Tennisvisionclone/Tennis AI"
python3 -m venv ai/backend/.venv
source ai/backend/.venv/bin/activate
pip install -r ai/backend/requirements.txt
```

Then follow `ai/backend/README.md`.

## Repo hygiene

- The canonical repo is this inner `Tennis AI/` directory.
- User-specific Xcode state, virtualenvs, generated AI outputs, videos, and UI screenshots are local-only and should stay ignored.
- The committed Core ML models in `Tennis AI/` and `Tennis AI/Models/` are intentionally retained so fresh clones can build the iOS app.
