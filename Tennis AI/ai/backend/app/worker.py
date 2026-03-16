from __future__ import annotations

import time

from .analysis_pipeline import process_analysis_job
from .config import Settings
from .repository import SupabaseRepository


def run_forever(poll_interval_sec: float = 2.0) -> None:
    repo = SupabaseRepository(Settings.from_env())
    while True:
        rows = repo.client.table("analysis_jobs").select("*").eq("state", "queued").order("created_at").limit(1).execute().data or []
        if not rows:
            time.sleep(poll_interval_sec)
            continue

        job = rows[0]
        job_id = str(job["id"])
        try:
            process_analysis_job(repo, job_id)
        except Exception as exc:
            repo.update_analysis_job(job_id, state="failed", stage="failed", error_message=str(exc))


if __name__ == "__main__":
    run_forever()
