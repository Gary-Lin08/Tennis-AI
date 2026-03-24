#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import urllib.error
import urllib.request
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser(description="Push phase1 analysis payload to FastAPI backend.")
    parser.add_argument("--api-url", type=str, default="http://127.0.0.1:8000/sessions/upload", help="Upload endpoint URL")
    parser.add_argument("--payload-json", type=Path, required=True, help="Path to *_analysis_payload.json")
    parser.add_argument("--user-id", type=str, required=True, help="Supabase auth.users.id UUID")
    parser.add_argument("--overwrite-existing-children", action="store_true", help="Delete and replace rallies/shots/bounces")
    args = parser.parse_args()

    payload = json.loads(args.payload_json.read_text(encoding="utf-8"))
    body = {
        "user_id": args.user_id,
        "overwrite_existing_children": bool(args.overwrite_existing_children),
        "payload": payload,
    }

    req = urllib.request.Request(
        url=args.api_url,
        data=json.dumps(body).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            text = resp.read().decode("utf-8")
            print(f"status={resp.status}")
            print(text)
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="ignore")
        print(f"status={exc.code}")
        print(detail)
        raise SystemExit(1)


if __name__ == "__main__":
    main()
