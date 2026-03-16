# Tennis AI Backend (FastAPI)

Minimal ingestion backend for two sync modes:

- `ios.ondevice.v1`: iOS local summary sync
- `phase1.v1`: Python Phase 1 full-detail sync

## Endpoint

- `GET /healthz`
- `POST /sessions/upload`
- `POST /telemetry/events`
- `GET /telemetry/admin/overview`
- `GET /telemetry/admin/daily`
- `GET /telemetry/admin/recent`
- `GET /telemetry/admin/screens`
- `GET /telemetry/admin/transitions`
- `GET /telemetry/admin/transitions/alerts`
- `GET /telemetry/admin/dashboard` (web UI)

## Supported schema versions

`POST /sessions/upload` intentionally supports two payload shapes:

- `ios.ondevice.v1`
  - source: iOS app
  - purpose: sync summary session rows
  - allowed shape: `rallies/shots/bounces` may all be empty
- `phase1.v1`
  - source: Python Phase 1 exporter
  - purpose: sync full rally / shot / bounce detail rows
  - expected shape: `session` + normalized child arrays

### Example: iOS summary payload

```json
{
  "user_id": "<auth.users.id UUID>",
  "overwrite_existing_children": true,
  "payload": {
    "schema_version": "ios.ondevice.v1",
    "generated_at_utc": "2026-03-12T10:00:00Z",
    "session": {
      "session_external_id": "ios-local-summary-001",
      "source_video_path": "TrainingVideoLibrary/training_20260312_101000.mov",
      "total_frames": 540,
      "num_shots": 7,
      "num_bounces": 3
    },
    "rallies": [],
    "shots": [],
    "bounces": []
  }
}
```

### Example: Phase 1 full payload

```json
{
  "user_id": "<auth.users.id UUID>",
  "overwrite_existing_children": true,
  "payload": {
    "schema_version": "phase1.v1",
    "generated_at_utc": "2026-03-12T10:00:00Z",
    "session": { "session_external_id": "U6WhLVQQpPc_15s", "source_video_path": "..." },
    "rallies": [],
    "shots": [],
    "bounces": []
  }
}
```

## Setup

1. Apply DB schema first:
   - `ai/phase1/data_contract/supabase_schema.sql`
2. Install dependencies:

```bash
cd "/Users/kl/Desktop/Tennisvisionclone/Tennis AI"
python3 -m venv .venv-backend
source .venv-backend/bin/activate
pip install -r ai/backend/requirements.txt
```

3. Configure env:

```bash
cp ai/backend/.env.example ai/backend/.env
# fill SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, ADMIN_API_KEY
```

4. Run API:

```bash
cd "/Users/kl/Desktop/Tennisvisionclone/Tennis AI"
source .venv-backend/bin/activate
set -a; source ai/backend/.env; set +a
uvicorn ai.backend.app.main:app --host 0.0.0.0 --port 8000 --reload
```

## Test with exported payload

```bash
python ai/backend/scripts/push_payload.py \
  --api-url "http://127.0.0.1:8000/sessions/upload" \
  --payload-json "ai/phase1/data_contract/outputs/U6WhLVQQpPc_15s_v2_analysis_payload.json" \
  --user-id "<REAL_AUTH_USER_UUID>" \
  --overwrite-existing-children
```

`user_id` must be a real `auth.users.id` in your Supabase project (because of FK + RLS).

## iOS app hookup

`Workflow` tab now includes a backend config card:

1. Fill backend URL (can be `http://127.0.0.1:8000`).
2. Fill local user id (for telemetry attribution, e.g. `player_001`).
3. Optional: fill `user_id` (`auth.users.id` UUID) to enable summary sync to `/sessions/upload`.
4. Tap `保存配置`.

Completed local jobs will auto-upload a summary session; failed uploads can be retried in the job detail page.
The iOS app does not upload full rally / shot / bounce detail rows in this mode.
If you need normalized child rows, use the Python Phase 1 exporter and push `phase1.v1`.

## Telemetry payload (click / dwell / usage)

`POST /telemetry/events`

```json
{
  "install_id": "device-install-id",
  "app_session_id": "launch-session-id",
  "local_user_id": "local-user-001",
  "platform": "ios",
  "app_version": "1.0",
  "os_version": "iOS 26.2",
  "events": [
    {
      "event_id": "uuid",
      "event_name": "tap",
      "event_ts_utc": "2026-03-12T12:00:00.000Z",
      "screen_name": "workflow",
      "target_name": "start_recording",
      "metadata": { "source": "hero_button" }
    }
  ]
}
```

Events are stored in `public.app_events`; daily aggregates are in `public.app_events_daily_summary`.

Quick smoke test:

```bash
python ai/backend/scripts/push_telemetry_sample.py \
  --api-url "http://127.0.0.1:8000/telemetry/events" \
  --local-user-id "player_001"
```

## Admin telemetry API (for dashboard / ops)

All admin query endpoints require header `X-Admin-Key: <ADMIN_API_KEY>`.

```bash
export ADMIN_KEY="change-me"
```

Overview for last 7 days:

```bash
curl -s "http://127.0.0.1:8000/telemetry/admin/overview?days=7" \
  -H "X-Admin-Key: ${ADMIN_KEY}" | jq
```

Daily metrics (clicks, dwell, usage) for one local user:

```bash
curl -s "http://127.0.0.1:8000/telemetry/admin/daily?days=30&local_user_id=player_001" \
  -H "X-Admin-Key: ${ADMIN_KEY}" | jq
```

Recent click events:

```bash
curl -s "http://127.0.0.1:8000/telemetry/admin/recent?limit=100&event_name=tap" \
  -H "X-Admin-Key: ${ADMIN_KEY}" | jq
```

Per-screen performance:

```bash
curl -s "http://127.0.0.1:8000/telemetry/admin/screens?days=14&top_n=50" \
  -H "X-Admin-Key: ${ADMIN_KEY}" | jq
```

Screen transitions:

```bash
curl -s "http://127.0.0.1:8000/telemetry/admin/transitions?days=14&top_n=50" \
  -H "X-Admin-Key: ${ADMIN_KEY}" | jq
```

Transition spike alerts (supports consecutive-window confirmation):

```bash
curl -s "http://127.0.0.1:8000/telemetry/admin/transitions/alerts?days=14&baseline_days=14&confirm_windows=2&min_current_count=8&min_growth_ratio=2.0&top_n=50" \
  -H "X-Admin-Key: ${ADMIN_KEY}" | jq
```

Example with weakest-window filter and sorting:

```bash
curl -s "http://127.0.0.1:8000/telemetry/admin/transitions/alerts?days=14&baseline_days=14&confirm_windows=2&min_current_count=8&min_growth_ratio=1.5&min_window_growth=2.2&sort_by=min_window_growth&top_n=50" \
  -H "X-Admin-Key: ${ADMIN_KEY}" | jq
```

Filter by one screen (works on overview/daily/recent/screens/transitions):

```bash
curl -s "http://127.0.0.1:8000/telemetry/admin/overview?days=14&screen_name=workflow" \
  -H "X-Admin-Key: ${ADMIN_KEY}" | jq
```

Open dashboard UI:

```bash
open "http://127.0.0.1:8000/telemetry/admin/dashboard"
```

Then paste your admin key in the page and click `Refresh All`.
You can also export `Daily Summary` and `Recent Events` as CSV from the dashboard.
Dashboard also supports auto-refresh interval and right-side trend metric switching.
Dashboard includes `Screen Performance` and `Screen Transitions` tables with CSV export.
Dashboard also renders a `Transition Flow Map` (SVG) to visualize major screen paths.
Clicking a node in `Transition Flow Map` will set `screen_name` filter and refresh all panels.
When a screen is selected, the flow map highlights incoming/outgoing edges and shows In/Out ratio.
`Transition Alerts` compares current/baseline windows and can require consecutive-window confirmation (`confirm_windows`) before marking spike edges in red.
Each alert row includes `window_counts` in order: `[current, previous_1, previous_2, ...]`.
Each alert row also includes `window_growths` in order: `[current/previous_1, previous_1/previous_2, ...]`.
Each alert row includes `min_window_growth` (the weakest ratio across `window_growths`).
Each alert row includes `alert_reason` for threshold confirmation details per window pair.
Dashboard provides one-click alert presets: `Preset Strict`, `Preset Balanced`, `Preset Aggressive`.
Dashboard also supports custom alert preset workflow: `Save Custom Preset` and `Apply Custom Preset`.
