from __future__ import annotations

from datetime import datetime, timezone
from types import ModuleType
import sys
import unittest

from pydantic import ValidationError

_supabase_stub = ModuleType("supabase")
_supabase_stub.Client = object
_supabase_stub.create_client = lambda *args, **kwargs: None
sys.modules.setdefault("supabase", _supabase_stub)

from ai.backend.app import main as backend_main
from ai.backend.app.models import SessionUploadRequest


class _FakeRepository:
    def ingest_analysis_payload(self, request):
        payload = request.model_dump(mode="json")["payload"]
        return {
            "session_id": "00000000-0000-0000-0000-000000000001",
            "external_session_id": payload["session"]["session_external_id"],
            "schema_version": payload["schema_version"],
            "inserted": {
                "rallies": len(payload.get("rallies", [])),
                "shots": len(payload.get("shots", [])),
                "bounces": len(payload.get("bounces", [])),
            },
            "updated_at_utc": datetime(2026, 3, 13, tzinfo=timezone.utc),
        }

    def ingest_telemetry_events(self, request):
        return {
            "inserted": len(request.events),
            "received_at_utc": datetime(2026, 3, 13, tzinfo=timezone.utc),
        }


class SessionUploadContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self._original_get_repo = backend_main.get_repo
        backend_main.get_repo = lambda: _FakeRepository()

    def tearDown(self) -> None:
        backend_main.get_repo = self._original_get_repo

    def test_sessions_upload_accepts_ios_summary_payload_with_empty_children(self) -> None:
        request = SessionUploadRequest.model_validate(
            {
                "user_id": "123e4567-e89b-12d3-a456-426614174000",
                "overwrite_existing_children": True,
                "payload": {
                    "schema_version": "ios.ondevice.v1",
                    "generated_at_utc": "2026-03-13T12:00:00Z",
                    "session": {
                        "session_external_id": "ios-summary-1",
                        "source_video_path": "library/training.mov",
                        "total_frames": 540,
                        "num_shots": 6,
                        "num_bounces": 2,
                    },
                    "rallies": [],
                    "shots": [],
                    "bounces": [],
                },
            }
        )
        response = backend_main.upload_session(request)

        self.assertTrue(response.ok)
        self.assertEqual(response.schema_version, "ios.ondevice.v1")
        self.assertEqual(response.inserted, {"rallies": 0, "shots": 0, "bounces": 0})

    def test_sessions_upload_accepts_phase1_full_payload(self) -> None:
        request = SessionUploadRequest.model_validate(
            {
                "user_id": "123e4567-e89b-12d3-a456-426614174000",
                "overwrite_existing_children": True,
                "payload": {
                    "schema_version": "phase1.v1",
                    "generated_at_utc": "2026-03-13T12:00:00Z",
                    "session": {
                        "session_external_id": "phase1-full-1",
                        "source_video_path": "exports/session.mp4",
                    },
                    "rallies": [{"rally_id": "r1"}],
                    "shots": [{"shot_id": "s1"}],
                    "bounces": [{"bounce_id": "b1"}],
                },
            }
        )
        response = backend_main.upload_session(request)

        self.assertTrue(response.ok)
        self.assertEqual(response.schema_version, "phase1.v1")
        self.assertEqual(response.inserted, {"rallies": 1, "shots": 1, "bounces": 1})

    def test_sessions_upload_rejects_unknown_schema_version(self) -> None:
        with self.assertRaises(ValidationError):
            SessionUploadRequest.model_validate(
                {
                    "user_id": "123e4567-e89b-12d3-a456-426614174000",
                    "overwrite_existing_children": True,
                    "payload": {
                        "schema_version": "ios.ondevice.v2",
                        "generated_at_utc": "2026-03-13T12:00:00Z",
                        "session": {
                            "session_external_id": "invalid-schema",
                            "source_video_path": "library/training.mov",
                        },
                    },
                }
            )


if __name__ == "__main__":
    unittest.main()
