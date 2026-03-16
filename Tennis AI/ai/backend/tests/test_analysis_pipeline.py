from __future__ import annotations

import sys
import unittest
from pathlib import Path


BACKEND_ROOT = Path(__file__).resolve().parents[1]
if str(BACKEND_ROOT) not in sys.path:
    sys.path.insert(0, str(BACKEND_ROOT))

from app.analysis_pipeline import _build_structured_payload, _load_summary


class AnalysisPipelineTests(unittest.TestCase):
    def test_load_summary_accepts_json_string(self) -> None:
        summary = _load_summary('{"trackedFrames": 42, "ballVisibleRate": 0.6}')
        self.assertEqual(summary["trackedFrames"], 42)
        self.assertEqual(summary["ballVisibleRate"], 0.6)

    def test_build_structured_payload_synthesizes_rallies_shots_and_bounces(self) -> None:
        job = {
            "local_session_id": "ios-local-1",
            "source_video_path": "/tmp/match.mov",
            "local_summary_json": {
                "eventDate": "2026-03-16T10:00:00Z",
                "totalFrames": 300,
                "trackedFrames": 180,
                "durationSec": 10,
                "ballVisibleRate": 0.6,
                "trackingQualityScore": 0.84,
                "estimatedBounceCount": 2,
                "note": "synthetic test",
                "detectedActions": [
                    {"frameIndex": 10, "x": 100, "y": 200, "confidence": 0.9, "type": "serve"},
                    {"frameIndex": 40, "x": 130, "y": 220, "confidence": 0.8, "type": "forehand"},
                    {"frameIndex": 180, "x": 330, "y": 180, "confidence": 0.7, "type": "serve"},
                ],
                "bouncePoints": [
                    {"frameIndex": 25, "x": 120, "y": 210, "confidence": 0.75},
                    {"frameIndex": 200, "x": 340, "y": 170, "confidence": 0.72},
                ],
            },
        }

        result = _build_structured_payload(job)

        self.assertEqual(result.payload["schema_version"], "phase1.v1")
        self.assertEqual(result.payload["session"]["session_external_id"], "ios-local-1")
        self.assertEqual(result.payload["session"]["num_shots"], 3)
        self.assertEqual(result.payload["session"]["num_bounces"], 2)
        self.assertEqual(len(result.payload["rallies"]), 2)
        self.assertEqual(len(result.payload["shots"]), 3)
        self.assertEqual(len(result.payload["bounces"]), 2)
        self.assertEqual(result.payload["shots"][0]["shot_type"], "serve")
        self.assertEqual(result.payload["rallies"][0]["point_status"], "pending_winner")
        self.assertEqual(result.model_versions["ios_summary"], "v1")
        self.assertAlmostEqual(result.court_detection_quality_score or 0, 0.84, places=6)


if __name__ == "__main__":
    unittest.main()
