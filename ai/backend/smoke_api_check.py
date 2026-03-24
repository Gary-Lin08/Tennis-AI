#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import mimetypes
import sys
import time
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from urllib import error, parse, request


TERMINAL_STATES = {"completed", "partial_failed", "failed"}
EXPECTED_STAGE_ORDER = [
    "queued",
    "upload_received",
    "court_detection",
    "tracknet",
    "shot_association",
    "rally_segmentation",
    "score_timeline",
    "export_contract",
    "db_ingest",
    "asset_publish",
    "completed",
]


@dataclass
class SmokeResult:
    ok: bool
    base_url: str
    actor_key: str
    checks: list[dict[str, Any]]
    job: dict[str, Any] | None
    session: dict[str, Any] | None
    detail: dict[str, Any] | None
    started_at_utc: str
    finished_at_utc: str


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def make_url(base_url: str, path: str, query: dict[str, str] | None = None) -> str:
    normalized = base_url.rstrip("/") + "/" + path.lstrip("/")
    if query:
        return normalized + "?" + parse.urlencode(query)
    return normalized


def http_json(
    method: str,
    url: str,
    payload: dict[str, Any] | None = None,
    headers: dict[str, str] | None = None,
    timeout_sec: int = 30,
) -> tuple[int, dict[str, Any] | list[Any] | str]:
    body: bytes | None = None
    req_headers = dict(headers or {})
    if payload is not None:
        body = json.dumps(payload).encode("utf-8")
        req_headers.setdefault("Content-Type", "application/json")
    req = request.Request(url=url, method=method, data=body, headers=req_headers)
    try:
        with request.urlopen(req, timeout=timeout_sec) as resp:
            raw = resp.read().decode("utf-8", errors="replace")
            content_type = resp.headers.get("Content-Type", "")
            if "application/json" in content_type:
                return resp.status, json.loads(raw)
            try:
                return resp.status, json.loads(raw)
            except Exception:
                return resp.status, raw
    except error.HTTPError as exc:
        raw = exc.read().decode("utf-8", errors="replace")
        try:
            data: Any = json.loads(raw)
        except Exception:
            data = raw
        return exc.code, data


def build_multipart_form_data(
    fields: dict[str, str],
    file_field: str,
    file_path: Path,
) -> tuple[bytes, str]:
    boundary = "----tennis-smoke-" + uuid.uuid4().hex
    lines: list[bytes] = []

    for key, value in fields.items():
        lines.append(f"--{boundary}\r\n".encode("utf-8"))
        lines.append(f'Content-Disposition: form-data; name="{key}"\r\n\r\n'.encode("utf-8"))
        lines.append((value + "\r\n").encode("utf-8"))

    mime = mimetypes.guess_type(file_path.name)[0] or "application/octet-stream"
    file_bytes = file_path.read_bytes()
    lines.append(f"--{boundary}\r\n".encode("utf-8"))
    lines.append(
        (
            f'Content-Disposition: form-data; name="{file_field}"; '
            f'filename="{file_path.name}"\r\n'
        ).encode("utf-8")
    )
    lines.append(f"Content-Type: {mime}\r\n\r\n".encode("utf-8"))
    lines.append(file_bytes)
    lines.append(b"\r\n")
    lines.append(f"--{boundary}--\r\n".encode("utf-8"))

    return b"".join(lines), f"multipart/form-data; boundary={boundary}"


def post_analysis_video(
    base_url: str,
    actor_key: str,
    local_session_id: str,
    video_path: Path,
    timeout_sec: int = 120,
) -> tuple[int, dict[str, Any] | list[Any] | str]:
    payload_summary = {
        "eventDate": utc_now_iso(),
        "totalFrames": 300,
        "trackedFrames": 120,
        "ballVisibleRate": 0.40,
        "trackingQualityScore": 0.70,
        "estimatedBounceCount": 3,
        "note": "smoke_api_check local summary",
    }
    fields = {
        "actor_key": actor_key,
        "local_session_id": local_session_id,
        "local_summary_json": json.dumps(payload_summary, ensure_ascii=False),
    }
    body, content_type = build_multipart_form_data(
        fields=fields,
        file_field="video_file",
        file_path=video_path,
    )
    url = make_url(base_url, "/analysis/videos")
    req = request.Request(
        url=url,
        method="POST",
        data=body,
        headers={"Content-Type": content_type},
    )
    try:
        with request.urlopen(req, timeout=timeout_sec) as resp:
            raw = resp.read().decode("utf-8", errors="replace")
            return resp.status, json.loads(raw)
    except error.HTTPError as exc:
        raw = exc.read().decode("utf-8", errors="replace")
        try:
            return exc.code, json.loads(raw)
        except Exception:
            return exc.code, raw


def assert_ok(status: int, data: Any, step: str) -> None:
    if 200 <= status < 300:
        return
    raise RuntimeError(f"{step} failed: HTTP {status}, response={data}")


def validate_telemetry(base_url: str, actor_key: str, checks: list[dict[str, Any]]) -> None:
    local_user = actor_key.split(":")[-1] if ":" in actor_key else actor_key
    payload = {
        "install_id": "smoke-install-" + uuid.uuid4().hex[:8],
        "app_session_id": "smoke-session-" + uuid.uuid4().hex[:8],
        "local_user_id": local_user,
        "platform": "ios",
        "app_version": "smoke",
        "os_version": "smoke",
        "events": [
            {
                "event_id": str(uuid.uuid4()),
                "event_name": "tap",
                "event_ts_utc": utc_now_iso(),
                "screen_name": "smoke",
                "target_name": "smoke_api_check",
                "metadata": {"source": "smoke_script"},
            }
        ],
    }
    status, data = http_json("POST", make_url(base_url, "/telemetry/events"), payload=payload, timeout_sec=30)
    assert_ok(status, data, "telemetry")
    checks.append({"step": "telemetry", "status": status, "response": data})


def poll_job_until_terminal(
    base_url: str,
    job_id: str,
    timeout_sec: int,
    interval_sec: float,
    checks: list[dict[str, Any]],
) -> dict[str, Any]:
    deadline = time.time() + timeout_sec
    last_job: dict[str, Any] | None = None
    while time.time() < deadline:
        status, data = http_json("GET", make_url(base_url, f"/analysis/jobs/{job_id}"), timeout_sec=30)
        assert_ok(status, data, "get_job")
        if not isinstance(data, dict):
            raise RuntimeError(f"get_job returned non-object: {data}")
        last_job = data
        checks.append(
            {
                "step": "poll_job",
                "status": status,
                "job_id": job_id,
                "state": data.get("state"),
                "stage": data.get("stage"),
                "updated_at_utc": data.get("updated_at_utc"),
            }
        )
        state = str(data.get("state") or "")
        if state in TERMINAL_STATES:
            return data
        time.sleep(interval_sec)
    raise TimeoutError(f"job {job_id} did not reach terminal state in {timeout_sec}s; last={last_job}")


def validate_stage_order(checks: list[dict[str, Any]], strict: bool) -> None:
    if not strict:
        return
    stage_index = {stage: idx for idx, stage in enumerate(EXPECTED_STAGE_ORDER)}
    observed: list[str] = []
    for item in checks:
        if item.get("step") != "poll_job":
            continue
        raw_stage = str(item.get("stage") or "").strip()
        if not raw_stage:
            continue
        if not observed or observed[-1] != raw_stage:
            observed.append(raw_stage)

    if not observed:
        raise RuntimeError("strict stage check failed: no stage observations found")

    previous_idx = -1
    for stage in observed:
        if stage not in stage_index:
            raise RuntimeError(
                "strict stage check failed: unknown stage "
                f"'{stage}', expected one of {EXPECTED_STAGE_ORDER}"
            )
        current_idx = stage_index[stage]
        if current_idx < previous_idx:
            raise RuntimeError(
                "strict stage check failed: stage order regressed, "
                f"observed sequence={observed}"
            )
        previous_idx = current_idx


def fetch_session_and_detail(
    base_url: str,
    actor_key: str,
    target_external_session_id: str | None,
    checks: list[dict[str, Any]],
) -> tuple[dict[str, Any], dict[str, Any]]:
    status, sessions_data = http_json(
        "GET",
        make_url(base_url, "/sessions", {"actor_key": actor_key, "limit": "100"}),
        timeout_sec=30,
    )
    assert_ok(status, sessions_data, "list_sessions")
    if not isinstance(sessions_data, list) or not sessions_data:
        raise RuntimeError("list_sessions returned empty result")
    checks.append({"step": "list_sessions", "status": status, "count": len(sessions_data)})

    chosen: dict[str, Any] | None = None
    if target_external_session_id:
        for item in sessions_data:
            if str(item.get("external_session_id") or "") == target_external_session_id:
                chosen = item
                break
    if chosen is None:
        chosen = sessions_data[0]

    session_ref = str(chosen.get("id") or chosen.get("external_session_id") or "")
    if not session_ref:
        raise RuntimeError("unable to resolve session_ref from sessions list")

    status, detail_data = http_json(
        "GET",
        make_url(base_url, f"/sessions/{session_ref}/detail", {"actor_key": actor_key}),
        timeout_sec=30,
    )
    assert_ok(status, detail_data, "session_detail")
    if not isinstance(detail_data, dict):
        raise RuntimeError(f"session_detail returned non-object: {detail_data}")
    required_fields = {"session", "rallies", "shots", "bounces", "score_timeline"}
    missing = [field for field in required_fields if field not in detail_data]
    if missing:
        raise RuntimeError(f"session_detail missing fields: {missing}")
    checks.append(
        {
            "step": "session_detail",
            "status": status,
            "session_ref": session_ref,
            "rallies": len(detail_data.get("rallies") or []),
            "shots": len(detail_data.get("shots") or []),
            "bounces": len(detail_data.get("bounces") or []),
            "score_timeline": len(detail_data.get("score_timeline") or []),
        }
    )
    return chosen, detail_data


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Tennis AI backend 最小化自动化 smoke 检查。",
    )
    parser.add_argument("--base-url", default="http://127.0.0.1:8000", help="Backend base URL")
    parser.add_argument("--actor-key", required=True, help="分析 actor_key（示例: ios:smoke:player_001）")
    parser.add_argument("--video-path", help="用于 /analysis/videos 的本地视频路径")
    parser.add_argument("--local-session-id", help="可选，默认自动生成")
    parser.add_argument("--poll-timeout-sec", type=int, default=900, help="任务轮询超时秒数")
    parser.add_argument("--poll-interval-sec", type=float, default=2.0, help="轮询间隔秒数")
    parser.add_argument("--skip-telemetry", action="store_true", help="跳过 telemetry 检查")
    parser.add_argument("--skip-analysis-upload", action="store_true", help="跳过 analysis 上传与状态推进检查")
    parser.add_argument(
        "--strict-stage-order",
        action="store_true",
        help="严格校验 stage 顺序是否按预期单调推进",
    )
    parser.add_argument("--summary-out", help="可选，写入 JSON 汇总文件")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    started_at = utc_now_iso()
    checks: list[dict[str, Any]] = []
    job_result: dict[str, Any] | None = None
    session_result: dict[str, Any] | None = None
    detail_result: dict[str, Any] | None = None

    try:
        status, health = http_json("GET", make_url(args.base_url, "/healthz"), timeout_sec=15)
        assert_ok(status, health, "healthz")
        if not isinstance(health, dict) or health.get("status") != "ok":
            raise RuntimeError(f"healthz payload unexpected: {health}")
        checks.append({"step": "healthz", "status": status, "response": health})

        if not args.skip_telemetry:
            validate_telemetry(args.base_url, args.actor_key, checks)

        if not args.skip_analysis_upload:
            if not args.video_path:
                raise RuntimeError("--video-path is required when analysis upload is enabled")
            video_path = Path(args.video_path).expanduser().resolve()
            if not video_path.exists() or not video_path.is_file():
                raise RuntimeError(f"video file not found: {video_path}")
            local_session_id = args.local_session_id or f"smoke-{uuid.uuid4().hex[:10]}"
            status, upload_data = post_analysis_video(
                base_url=args.base_url,
                actor_key=args.actor_key,
                local_session_id=local_session_id,
                video_path=video_path,
                timeout_sec=120,
            )
            assert_ok(status, upload_data, "analysis_upload")
            if not isinstance(upload_data, dict):
                raise RuntimeError(f"analysis_upload returned non-object: {upload_data}")
            job_id = str(upload_data.get("job_id") or "")
            if not job_id:
                raise RuntimeError(f"analysis_upload missing job_id: {upload_data}")
            checks.append({"step": "analysis_upload", "status": status, "job_id": job_id, "response": upload_data})

            job_result = poll_job_until_terminal(
                base_url=args.base_url,
                job_id=job_id,
                timeout_sec=args.poll_timeout_sec,
                interval_sec=args.poll_interval_sec,
                checks=checks,
            )
            validate_stage_order(checks=checks, strict=args.strict_stage_order)
            checks.append(
                {
                    "step": "stage_order_validation",
                    "strict": args.strict_stage_order,
                    "ok": True,
                }
            )
            if str(job_result.get("state") or "") == "failed":
                raise RuntimeError(f"job failed: {job_result.get('error_message') or job_result}")

            target_external_session_id = (
                str(job_result.get("remote_external_session_id") or "").strip() or None
            )
            session_result, detail_result = fetch_session_and_detail(
                base_url=args.base_url,
                actor_key=args.actor_key,
                target_external_session_id=target_external_session_id,
                checks=checks,
            )

        result = SmokeResult(
            ok=True,
            base_url=args.base_url,
            actor_key=args.actor_key,
            checks=checks,
            job=job_result,
            session=session_result,
            detail=detail_result,
            started_at_utc=started_at,
            finished_at_utc=utc_now_iso(),
        )
        payload = json.dumps(result.__dict__, ensure_ascii=False, indent=2)
        print(payload)
        if args.summary_out:
            out_path = Path(args.summary_out).expanduser().resolve()
            out_path.parent.mkdir(parents=True, exist_ok=True)
            out_path.write_text(payload + "\n", encoding="utf-8")
        return 0
    except Exception as exc:
        result = SmokeResult(
            ok=False,
            base_url=args.base_url,
            actor_key=args.actor_key,
            checks=checks + [{"step": "error", "message": str(exc)}],
            job=job_result,
            session=session_result,
            detail=detail_result,
            started_at_utc=started_at,
            finished_at_utc=utc_now_iso(),
        )
        print(json.dumps(result.__dict__, ensure_ascii=False, indent=2), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
