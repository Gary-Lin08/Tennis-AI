import XCTest
@testable import Tennis_AI

final class SessionComparisonReportTests: XCTestCase {
    func testBuildComputesMetricRowsAndWinner() throws {
        let left = makeSession(
            title: "left",
            visibleRate: 0.72,
            trackingQualityScore: 0.83,
            trackedFrames: 180,
            totalFrames: 240,
            bounceCount: 18,
            actions: [
                action(frame: 10, type: .forehand),
                action(frame: 20, type: .serve)
            ]
        )
        let right = makeSession(
            title: "right",
            visibleRate: 0.60,
            trackingQualityScore: 0.79,
            trackedFrames: 140,
            totalFrames: 240,
            bounceCount: 14,
            actions: [
                action(frame: 11, type: .forehand)
            ]
        )

        let report = SessionComparisonReport.build(left: left, right: right)
        let visibleMetric = try XCTUnwrap(report.metrics.first(where: { $0.id == "visible_rate" }))
        XCTAssertEqual(visibleMetric.betterSide, .left)
        XCTAssertTrue(visibleMetric.leftValueText.contains("72"))
        XCTAssertTrue(visibleMetric.rightValueText.contains("60"))
        XCTAssertTrue(visibleMetric.deltaText.contains("12"))

        let trackMetric = try XCTUnwrap(report.metrics.first(where: { $0.id == "track_ratio" }))
        XCTAssertEqual(trackMetric.betterSide, .left)
    }

    func testBuildHandlesMissingActionsAsZeroCounts() throws {
        let left = makeSession(
            title: "left",
            visibleRate: 0.66,
            trackingQualityScore: 0.82,
            trackedFrames: 120,
            totalFrames: 180,
            bounceCount: 9,
            actions: nil
        )
        let right = makeSession(
            title: "right",
            visibleRate: 0.65,
            trackingQualityScore: 0.81,
            trackedFrames: 118,
            totalFrames: 180,
            bounceCount: 8,
            actions: [action(frame: 8, type: .backhand)]
        )

        let report = SessionComparisonReport.build(left: left, right: right)
        let forehandMetric = try XCTUnwrap(report.metrics.first(where: { $0.id == "forehand_count" }))
        let backhandMetric = try XCTUnwrap(report.metrics.first(where: { $0.id == "backhand_count" }))

        XCTAssertEqual(forehandMetric.leftValueText, "0")
        XCTAssertEqual(forehandMetric.rightValueText, "0")
        XCTAssertEqual(backhandMetric.leftValueText, "0")
        XCTAssertEqual(backhandMetric.rightValueText, "1")
    }

    func testBuildGeneratesRecommendationWhenQualityGapIsLarge() {
        let left = makeSession(
            title: "left",
            visibleRate: 0.80,
            trackingQualityScore: 0.90,
            trackedFrames: 200,
            totalFrames: 240,
            bounceCount: 16,
            actions: [action(frame: 5, type: .forehand), action(frame: 15, type: .forehand)]
        )
        let right = makeSession(
            title: "right",
            visibleRate: 0.60,
            trackingQualityScore: 0.72,
            trackedFrames: 120,
            totalFrames: 240,
            bounceCount: 10,
            actions: [action(frame: 7, type: .serve)]
        )

        let report = SessionComparisonReport.build(left: left, right: right)
        XCTAssertTrue(report.recommendations.contains(where: { $0.contains("球可见率") }))
        XCTAssertTrue(report.recommendations.contains(where: { $0.contains("跟踪质量摘要") }))
    }

    private func makeSession(
        title: String,
        visibleRate: Double,
        trackingQualityScore: Double,
        trackedFrames: Int,
        totalFrames: Int,
        bounceCount: Int,
        actions: [DetectedAction]?
    ) -> AnalysisSession {
        AnalysisSession(
            id: UUID(),
            videoTitle: title,
            sourceID: "source-\(title)",
            eventDate: Date(),
            trackedFrames: trackedFrames,
            totalFrames: totalFrames,
            ballVisibleRate: visibleRate,
            trackingQualityScore: trackingQualityScore,
            estimatedBounceCount: bounceCount,
            processingStatus: .completed,
            inputSource: .upload,
            localVideoPath: nil,
            trajectoryPoints: nil,
            bouncePoints: nil,
            detectedActions: actions,
            note: ""
        )
    }

    private func action(frame: Int, type: ActionType) -> DetectedAction {
        DetectedAction(frameIndex: frame, x: 100, y: 100, confidence: 0.8, type: type)
    }
}
