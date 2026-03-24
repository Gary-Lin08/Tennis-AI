import XCTest
@testable import Tennis_AI

final class TrainingAnalyticsTests: XCTestCase {
    func testTrendSnapshotAggregatesAveragesAndActionCounts() {
        let sessions = [
            makeSession(
                dayOffset: -1,
                visibleRate: 0.60,
                trackingQuality: 0.75,
                bounceCount: 10,
                trackedFrames: 120,
                totalFrames: 200,
                actions: [
                    action(frame: 10, type: .forehand, confidence: 0.82),
                    action(frame: 20, type: .serve, confidence: 0.88)
                ],
                qualityBreakdown: SessionQualityBreakdown(
                    visibleRateScore: 0.60,
                    continuityScore: 0.70,
                    inferenceSuccessRate: 0.74,
                    actionStabilityScore: 0.78
                )
            ),
            makeSession(
                dayOffset: -2,
                visibleRate: 0.80,
                trackingQuality: 0.90,
                bounceCount: 14,
                trackedFrames: 180,
                totalFrames: 220,
                actions: [
                    action(frame: 14, type: .backhand, confidence: 0.76),
                    action(frame: 32, type: .forehand, confidence: 0.81)
                ],
                qualityBreakdown: SessionQualityBreakdown(
                    visibleRateScore: 0.80,
                    continuityScore: 0.88,
                    inferenceSuccessRate: 0.91,
                    actionStabilityScore: 0.69
                )
            )
        ]

        let snapshot = TrainingInsights.snapshot(
            title: "最近 7 天",
            subtitle: "短期训练趋势",
            sessions: sessions
        )

        XCTAssertEqual(snapshot.sessionCount, 2)
        XCTAssertEqual(snapshot.averageVisibleRate, 0.70, accuracy: 0.001)
        XCTAssertEqual(snapshot.averageTrackingQualityScore, 0.825, accuracy: 0.001)
        XCTAssertEqual(snapshot.averageBounceCount, 12.0, accuracy: 0.001)
        XCTAssertEqual(snapshot.actionCounts.forehand, 2)
        XCTAssertEqual(snapshot.actionCounts.backhand, 1)
        XCTAssertEqual(snapshot.actionCounts.serve, 1)
        XCTAssertEqual(snapshot.averageQualityBreakdown.clampedContinuityScore, 0.79, accuracy: 0.001)
    }

    func testPhaseComparisonBuildsRecentAndBaselineWindows() throws {
        let referenceDate = Calendar.current.startOfDay(for: Date())
        let sessions = [
            makeSession(dayOffset: -1, visibleRate: 0.82, trackingQuality: 0.90, bounceCount: 16),
            makeSession(dayOffset: -3, visibleRate: 0.80, trackingQuality: 0.88, bounceCount: 15),
            makeSession(dayOffset: -10, visibleRate: 0.62, trackingQuality: 0.73, bounceCount: 9),
            makeSession(dayOffset: -18, visibleRate: 0.64, trackingQuality: 0.76, bounceCount: 10),
            makeSession(dayOffset: -26, visibleRate: 0.65, trackingQuality: 0.74, bounceCount: 8)
        ]

        let report = try XCTUnwrap(
            TrainingInsights.phaseComparison(
                sessions: sessions,
                endingOn: referenceDate
            )
        )

        XCTAssertEqual(report.recent.sessionCount, 3)
        XCTAssertEqual(report.baseline.sessionCount, 2)
        XCTAssertGreaterThan(report.recent.averageVisibleRate, report.baseline.averageVisibleRate)
        XCTAssertTrue(report.headline.contains("近期阶段"))
    }

    func testResolvedQualityBreakdownFallsBackWhenStoredBreakdownMissing() {
        let session = makeSession(
            dayOffset: -1,
            visibleRate: 0.58,
            trackingQuality: 0.77,
            bounceCount: 7,
            trackedFrames: 110,
            totalFrames: 200,
            actions: [
                action(frame: 6, type: .forehand, confidence: 0.80),
                action(frame: 16, type: .unknown, confidence: 0.42)
            ],
            qualityBreakdown: nil
        )

        let breakdown = session.resolvedQualityBreakdown
        XCTAssertEqual(breakdown.clampedVisibleRateScore, 0.58, accuracy: 0.001)
        XCTAssertGreaterThan(breakdown.clampedContinuityScore, 0)
        XCTAssertGreaterThan(breakdown.clampedInferenceSuccessRate, 0)
        XCTAssertGreaterThan(breakdown.clampedActionStabilityScore, 0)
    }

    func testPlaybackHighlightsAreEmptyWithoutSignals() {
        let session = makeSession(
            dayOffset: -1,
            visibleRate: 0.60,
            trackingQuality: 0.78,
            bounceCount: 0,
            trackedFrames: 0,
            totalFrames: 100,
            actions: nil,
            bouncePoints: nil
        )

        XCTAssertTrue(session.playbackHighlights.isEmpty)
    }

    func testPlaybackHighlightsIncludeBounceAndStrongestAction() {
        let session = makeSession(
            dayOffset: -1,
            visibleRate: 0.60,
            trackingQuality: 0.78,
            bounceCount: 1,
            trackedFrames: 80,
            totalFrames: 100,
            actions: [
                action(frame: 24, type: .serve, confidence: 0.91),
                action(frame: 48, type: .forehand, confidence: 0.86)
            ],
            bouncePoints: [
                InferencePoint(frameIndex: 12, x: 100, y: 100, confidence: 0.88, isVisible: true)
            ]
        )

        let highlights = session.playbackHighlights
        XCTAssertEqual(highlights.first?.id, "bounce-first-12")
        XCTAssertTrue(highlights.contains(where: { $0.id == "action-peak-24-serve" }))
    }

    private func makeSession(
        dayOffset: Int,
        visibleRate: Double,
        trackingQuality: Double,
        bounceCount: Int,
        trackedFrames: Int = 120,
        totalFrames: Int = 200,
        actions: [DetectedAction]? = nil,
        bouncePoints: [InferencePoint]? = nil,
        qualityBreakdown: SessionQualityBreakdown? = nil
    ) -> AnalysisSession {
        AnalysisSession(
            id: UUID(),
            videoTitle: "session-\(dayOffset)",
            sourceID: "session-\(dayOffset)",
            eventDate: Calendar.current.date(byAdding: .day, value: dayOffset, to: Date()) ?? Date(),
            trackedFrames: trackedFrames,
            totalFrames: totalFrames,
            ballVisibleRate: visibleRate,
            trackingQualityScore: trackingQuality,
            estimatedBounceCount: bounceCount,
            processingStatus: .completed,
            inputSource: .upload,
            localVideoPath: nil,
            trajectoryPoints: nil,
            bouncePoints: bouncePoints,
            detectedActions: actions,
            note: "",
            qualityBreakdown: qualityBreakdown
        )
    }

    private func action(frame: Int, type: ActionType, confidence: Double) -> DetectedAction {
        DetectedAction(frameIndex: frame, x: 120, y: 220, confidence: confidence, type: type)
    }
}
