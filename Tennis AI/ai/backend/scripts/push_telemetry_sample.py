#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import urllib.error
import urllib.request
from datetime import datetime, timezone
from uuid import uuid4


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def main() -> None:
    parser = argparse.ArgumentParser(description="Push sample telemetry events to FastAPI backend.")
    parser.add_argument("--api-url", type=str, default="http://127.0.0.1:8000/telemetry/events")
    parser.add_argument("--install-id", type=str, default=f"install-{uuid4().hex[:12]}")
    parser.add_argument("--app-session-id", type=str, default=uuid4().hex)
    parser.add_argument("--local-user-id", type=str, default="local-user-001")
    args = parser.parse_args()

    payload = {
        "install_id": args.install_id,
        "app_session_id": args.app_session_id,
        "local_user_id": args.local_user_id,
        "platform": "ios",
        "app_version": "1.0(1)",
        "os_version": "iOS 26.2",
        "events": [
            {
                "event_id": uuid4().hex,
                "event_name": "screen_view",
                "event_ts_utc": now_iso(),
                "screen_name": "workflow",
                "target_name": None,
                "metadata": {"source": "sample_script"},
            },
            {
                "event_id": uuid4().hex,
                "event_name": "tap",
                "event_ts_utc": now_iso(),
                "screen_name": "workflow",
                "target_name": "start_recording",
                "metadata": {"source": "sample_script"},
            },
            {
                "event_id": uuid4().hex,
                "event_name": "app_usage_segment",
                "event_ts_utc": now_iso(),
                "duration_ms": 45000,
                "metadata": {"source": "sample_script"},
            },
        ],
    }

    request = urllib.request.Request(
        url=args.api_url,
        method="POST",
        headers={"Content-Type": "application/json"},
        data=json.dumps(payload).encode("utf-8"),
    )

    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            print(f"status={response.status}")
            print(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        print(f"status={exc.code}")
        print(exc.read().decode("utf-8", errors="ignore"))
        raise SystemExit(1)


if __name__ == "__main__":
    main()
