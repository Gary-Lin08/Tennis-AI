from __future__ import annotations

from datetime import datetime
from typing import Any, Literal
from uuid import UUID

from pydantic import BaseModel, Field, model_validator


SchemaVersion = Literal["ios.ondevice.v1", "phase1.v1"]
AnalysisJobState = Literal["queued", "uploading", "analyzing", "partial_failed", "completed", "failed"]


class AnalysisPayload(BaseModel):
    schema_version: SchemaVersion
    generated_at_utc: datetime | None = None
    session: dict[str, Any]
    rallies: list[dict[str, Any]] = Field(default_factory=list)
    shots: list[dict[str, Any]] = Field(default_factory=list)
    bounces: list[dict[str, Any]] = Field(default_factory=list)


class SessionUploadRequest(BaseModel):
    user_id: UUID | None = None
    actor_key: str | None = None
    payload: AnalysisPayload
    overwrite_existing_children: bool = True

    @model_validator(mode="after")
    def validate_owner(self) -> "SessionUploadRequest":
        if self.user_id is None and not (self.actor_key or "").strip():
            raise ValueError("either user_id or actor_key is required")
        return self


class SessionUploadResponse(BaseModel):
    ok: bool = True
    session_id: UUID
    external_session_id: str
    schema_version: SchemaVersion
    actor_key: str | None = None
    inserted: dict[str, int]
    updated_at_utc: datetime


class Point2D(BaseModel):
    x: float
    y: float


class AnalysisVideoUploadResponse(BaseModel):
    ok: bool = True
    job_id: UUID
    actor_key: str
    local_session_id: str
    state: AnalysisJobState
    stage: str
    created_at_utc: datetime


class AnalysisJobResponse(BaseModel):
    ok: bool = True
    job_id: UUID
    actor_key: str
    local_session_id: str
    state: AnalysisJobState
    stage: str
    error_message: str | None = None
    remote_session_id: UUID | None = None
    remote_external_session_id: str | None = None
    source_video_path: str | None = None
    created_at_utc: datetime
    updated_at_utc: datetime


class SessionSummaryItem(BaseModel):
    id: UUID
    actor_key: str | None = None
    external_session_id: str
    source_video_path: str
    generated_at_utc: datetime | None = None
    total_frames: int | None = None
    duration_sec: float | None = None
    num_rallies: int = 0
    num_shots: int = 0
    num_bounces: int = 0
    first_server_side: str | None = None
    current_server_side: str | None = None
    final_sets_near: int = 0
    final_sets_far: int = 0
    final_games_near: int = 0
    final_games_far: int = 0
    final_points_near: str = "0"
    final_points_far: str = "0"
    raw_summary: dict[str, Any] = Field(default_factory=dict)
    created_at: datetime | None = None
    updated_at: datetime | None = None


class StructuredRallyItem(BaseModel):
    rally_id: int
    start_frame: int
    end_frame: int
    start_sec: float
    end_sec: float
    duration_sec: float | None = None
    num_frames: int | None = None
    num_shots: int | None = None
    near_shots: int | None = None
    far_shots: int | None = None
    unassigned_shots: int | None = None
    winner_side: str | None = None
    winner_source: str | None = None
    point_status: str | None = None
    server_side_before: str | None = None
    server_side_after: str | None = None
    before_score: str | None = None
    after_score: str | None = None
    game_won_by: str | None = None
    set_won_by: str | None = None


class StructuredShotItem(BaseModel):
    shot_id: int
    rally_id: int | None = None
    frame_num: int
    time_sec: float
    x_px: float | None = None
    y_px: float | None = None
    x_m: float | None = None
    y_m: float | None = None
    hitter_side: str | None = None
    hitter_track_id: int | None = None
    assign_distance_px: float | None = None
    side_matched: bool | None = None
    shot_type: str | None = None
    speed_kmh: float | None = None
    confidence: float | None = None


class StructuredBounceItem(BaseModel):
    bounce_id: int
    rally_id: int | None = None
    frame_num: int
    time_sec: float
    x_px: float | None = None
    y_px: float | None = None
    x_m: float | None = None
    y_m: float | None = None
    in_court: bool | None = None
    confidence: float | None = None
    detection_method: str | None = None


class ScoreTimelineEntry(BaseModel):
    rally_id: int
    before_score: str | None = None
    after_score: str | None = None
    winner_side: str | None = None
    point_status: str | None = None
    server_side_before: str | None = None
    server_side_after: str | None = None


class SessionDetailResponse(BaseModel):
    ok: bool = True
    session: SessionSummaryItem
    rallies: list[StructuredRallyItem] = Field(default_factory=list)
    shots: list[StructuredShotItem] = Field(default_factory=list)
    bounces: list[StructuredBounceItem] = Field(default_factory=list)
    score_timeline: list[ScoreTimelineEntry] = Field(default_factory=list)
    model_versions: dict[str, str] = Field(default_factory=dict)
    court_detection_quality_score: float | None = None


class CourtOverrideRequest(BaseModel):
    source_corners: list[Point2D]


class WinnerOverrideRequest(BaseModel):
    rally_id: int
    winner_side: Literal["near", "far"]


class TelemetryEventItem(BaseModel):
    event_id: str | None = None
    event_name: str
    event_ts_utc: datetime
    screen_name: str | None = None
    target_name: str | None = None
    dwell_ms: int | None = Field(default=None, ge=0)
    duration_ms: int | None = Field(default=None, ge=0)
    metadata: dict[str, Any] = Field(default_factory=dict)


class TelemetryEventsRequest(BaseModel):
    install_id: str
    app_session_id: str
    local_user_id: str | None = None
    platform: str = "ios"
    app_version: str | None = None
    os_version: str | None = None
    events: list[TelemetryEventItem] = Field(default_factory=list)


class TelemetryEventsResponse(BaseModel):
    ok: bool = True
    inserted: int
    received_at_utc: datetime


class TelemetryOverviewTotals(BaseModel):
    events: int = 0
    taps: int = 0
    screen_views: int = 0
    screen_leaves: int = 0
    usage_segments: int = 0
    usage_ms: int = 0
    screen_dwell_ms: int = 0
    unique_installs: int = 0
    unique_local_users: int = 0
    unique_app_sessions: int = 0


class TelemetryBreakdownItem(BaseModel):
    key: str
    count: int


class TelemetryOverviewResponse(BaseModel):
    ok: bool = True
    days: int
    window_start_utc: datetime
    window_end_utc: datetime
    local_user_id: str | None = None
    install_id: str | None = None
    event_name: str | None = None
    screen_name: str | None = None
    totals: TelemetryOverviewTotals
    top_screens: list[TelemetryBreakdownItem] = Field(default_factory=list)
    top_targets: list[TelemetryBreakdownItem] = Field(default_factory=list)


class TelemetryDailyItem(BaseModel):
    day_utc: datetime
    actor_id: str
    event_count: int = 0
    tap_count: int = 0
    screen_view_count: int = 0
    screen_leave_count: int = 0
    usage_segments: int = 0
    usage_ms: int = 0
    screen_dwell_ms: int = 0


class TelemetryDailyResponse(BaseModel):
    ok: bool = True
    days: int
    window_start_utc: datetime
    window_end_utc: datetime
    local_user_id: str | None = None
    install_id: str | None = None
    screen_name: str | None = None
    rows: list[TelemetryDailyItem] = Field(default_factory=list)


class TelemetryRecentEvent(BaseModel):
    id: int
    event_id: str | None = None
    install_id: str
    app_session_id: str
    local_user_id: str | None = None
    platform: str | None = None
    app_version: str | None = None
    os_version: str | None = None
    event_name: str
    event_ts_utc: datetime
    screen_name: str | None = None
    target_name: str | None = None
    dwell_ms: int | None = Field(default=None, ge=0)
    duration_ms: int | None = Field(default=None, ge=0)
    metadata: dict[str, Any] = Field(default_factory=dict)
    received_at: datetime | None = None


class TelemetryRecentResponse(BaseModel):
    ok: bool = True
    limit: int
    local_user_id: str | None = None
    install_id: str | None = None
    event_name: str | None = None
    screen_name: str | None = None
    events: list[TelemetryRecentEvent] = Field(default_factory=list)


class TelemetryScreenItem(BaseModel):
    screen_name: str
    screen_views: int = 0
    screen_leaves: int = 0
    total_dwell_ms: int = 0
    avg_dwell_ms: int = 0
    unique_actors: int = 0


class TelemetryScreensResponse(BaseModel):
    ok: bool = True
    days: int
    window_start_utc: datetime
    window_end_utc: datetime
    local_user_id: str | None = None
    install_id: str | None = None
    screen_name: str | None = None
    rows: list[TelemetryScreenItem] = Field(default_factory=list)


class TelemetryTransitionItem(BaseModel):
    from_screen: str
    to_screen: str
    transition_count: int = 0
    unique_actors: int = 0
    avg_gap_sec: float = 0.0


class TelemetryTransitionsResponse(BaseModel):
    ok: bool = True
    days: int
    window_start_utc: datetime
    window_end_utc: datetime
    local_user_id: str | None = None
    install_id: str | None = None
    screen_name: str | None = None
    rows: list[TelemetryTransitionItem] = Field(default_factory=list)


class TelemetryTransitionAlertItem(BaseModel):
    from_screen: str
    to_screen: str
    current_count: int = 0
    previous_count: int = 0
    delta_count: int = 0
    growth_ratio: float = 0.0
    window_counts: list[int] = Field(default_factory=list)
    window_growths: list[float] = Field(default_factory=list)
    min_window_growth: float = 0.0
    alert_reason: str = ""
    severity: str = "low"


class TelemetryTransitionAlertsResponse(BaseModel):
    ok: bool = True
    days: int
    baseline_days: int
    confirm_windows: int
    window_start_utc: datetime
    window_end_utc: datetime
    baseline_start_utc: datetime
    baseline_end_utc: datetime
    local_user_id: str | None = None
    install_id: str | None = None
    screen_name: str | None = None
    min_current_count: int
    min_growth_ratio: float
    min_window_growth: float | None = None
    sort_by: str = "severity"
    rows: list[TelemetryTransitionAlertItem] = Field(default_factory=list)
