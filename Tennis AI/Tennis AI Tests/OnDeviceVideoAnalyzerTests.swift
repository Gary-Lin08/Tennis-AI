import XCTest
@testable import Tennis_AI

final class OnDeviceVideoAnalyzerTests: XCTestCase {

    // MARK: - BounceThresholds

    func testBounceThresholdsAllProfilesHavePositivePeakFloor() {
        for profile in OnDeviceInferenceProfile.allCases {
            let analyzer = OnDeviceVideoAnalyzer(profile: profile)
            let t = analyzer.bounceThresholdsForTesting
            XCTAssertGreaterThan(t.peakFloor, 0, "peakFloor must be > 0 for profile \(profile.rawValue)")
            XCTAssertGreaterThan(t.peakDivisor, 0, "peakDivisor must be > 0 for profile \(profile.rawValue)")
            XCTAssertGreaterThan(t.velocityFloor, 0, "velocityFloor must be > 0 for profile \(profile.rawValue)")
            XCTAssertGreaterThan(t.velocityDivisor, 0, "velocityDivisor must be > 0 for profile \(profile.rawValue)")
            XCTAssertGreaterThan(t.reboundRatio, 0, "reboundRatio must be > 0 for profile \(profile.rawValue)")
            XCTAssertGreaterThan(t.maxWindowFrames, 0, "maxWindowFrames must be > 0 for profile \(profile.rawValue)")
            XCTAssertGreaterThan(t.dedupeFrameGap, 0, "dedupeFrameGap must be > 0 for profile \(profile.rawValue)")
            XCTAssertGreaterThan(t.confidenceBoostCap, 0, "confidenceBoostCap must be > 0 for profile \(profile.rawValue)")
        }
    }

    func testBounceThresholdsHighPrecisionIsStricterThanHighRecall() {
        let recall = OnDeviceVideoAnalyzer(profile: .highRecall).bounceThresholdsForTesting
        let precision = OnDeviceVideoAnalyzer(profile: .highPrecision).bounceThresholdsForTesting
        XCTAssertGreaterThan(precision.peakFloor, recall.peakFloor)
        XCTAssertGreaterThan(precision.velocityFloor, recall.velocityFloor)
        XCTAssertGreaterThan(precision.reboundRatio, recall.reboundRatio)
        XCTAssertGreaterThan(precision.dedupeFrameGap, recall.dedupeFrameGap)
    }

    // MARK: - ActionThresholds

    func testActionThresholdsAllProfilesHavePositiveValues() {
        for profile in OnDeviceInferenceProfile.allCases {
            let analyzer = OnDeviceVideoAnalyzer(profile: profile)
            let t = analyzer.actionThresholdsForTesting
            XCTAssertGreaterThan(t.motionFloor, 0, "motionFloor must be > 0 for \(profile.rawValue)")
            XCTAssertGreaterThan(t.motionScale, 0, "motionScale must be > 0 for \(profile.rawValue)")
            XCTAssertGreaterThan(t.speedGateRatio, 0, "speedGateRatio must be > 0 for \(profile.rawValue)")
            XCTAssertGreaterThan(t.dedupeFrameGap, 0, "dedupeFrameGap must be > 0 for \(profile.rawValue)")
        }
    }

    // MARK: - smoothTrajectory

    func testSmoothTrajectoryEmptyInputReturnsEmpty() {
        let analyzer = OnDeviceVideoAnalyzer()
        let result = analyzer.smoothTrajectoryForTesting(points: [], windowRadius: 2)
        XCTAssertTrue(result.isEmpty)
    }

    func testSmoothTrajectorySinglePointPassesThrough() {
        let analyzer = OnDeviceVideoAnalyzer()
        let point = InferencePoint(frameIndex: 0, x: 100, y: 200, confidence: 0.8, isVisible: true)
        let result = analyzer.smoothTrajectoryForTesting(points: [point], windowRadius: 2)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].x, 100)
        XCTAssertEqual(result[0].y, 200)
    }

    func testSmoothTrajectoryPreservesCount() {
        let analyzer = OnDeviceVideoAnalyzer()
        let points = (0..<10).map {
            InferencePoint(frameIndex: $0, x: $0 * 10, y: $0 * 5, confidence: 0.75, isVisible: true)
        }
        let result = analyzer.smoothTrajectoryForTesting(points: points, windowRadius: 2)
        XCTAssertEqual(result.count, points.count)
    }

    func testSmoothTrajectoryConfidenceStaysInRange() {
        let analyzer = OnDeviceVideoAnalyzer()
        let points = (0..<8).map {
            InferencePoint(frameIndex: $0, x: $0 * 20, y: 100, confidence: 0.6, isVisible: true)
        }
        let result = analyzer.smoothTrajectoryForTesting(points: points, windowRadius: 2)
        for p in result {
            XCTAssertGreaterThanOrEqual(p.confidence, 0.0)
            XCTAssertLessThanOrEqual(p.confidence, 1.0)
        }
    }

    // MARK: - detectBouncePoints

    func testDetectBouncePointsEmptyInputReturnsEmpty() {
        let analyzer = OnDeviceVideoAnalyzer()
        let result = analyzer.detectBouncePointsForTesting(from: [], sourceHeight: 1080)
        XCTAssertTrue(result.isEmpty)
    }

    func testDetectBouncePointsTooFewPointsReturnsEmpty() {
        let analyzer = OnDeviceVideoAnalyzer()
        let points = (0..<4).map {
            InferencePoint(frameIndex: $0, x: 100, y: $0 * 10, confidence: 0.8, isVisible: true)
        }
        let result = analyzer.detectBouncePointsForTesting(from: points, sourceHeight: 1080)
        XCTAssertTrue(result.isEmpty)
    }

    func testDetectBouncePointsDetectsLocalYPeak() {
        // Simulate a ball that drops, bounces, then rises.
        // y increases downward → bounce is local y-maximum.
        let analyzer = OnDeviceVideoAnalyzer(profile: .highRecall)
        let ys = [100, 200, 350, 500, 600, 500, 350, 200, 100]
        let points = ys.enumerated().map { i, y in
            InferencePoint(frameIndex: i, x: 400, y: y, confidence: 0.9, isVisible: true)
        }
        let result = analyzer.detectBouncePointsForTesting(from: points, sourceHeight: 1080)
        XCTAssertGreaterThan(result.count, 0, "Expected at least one bounce detected")
        // The peak should be near the centre frame (index 4, y=600)
        let peakBounce = result.max(by: { $0.y < $1.y })
        XCTAssertNotNil(peakBounce)
        XCTAssertGreaterThanOrEqual(peakBounce!.y, 500)
    }

    func testDetectBouncePointsNoFalsePositiveForLinearDrop() {
        // Ball only falls — no velocity flip, should produce 0 bounces.
        let analyzer = OnDeviceVideoAnalyzer(profile: .balanced)
        let ys = [50, 100, 200, 350, 500, 700, 900]
        let points = ys.enumerated().map { i, y in
            InferencePoint(frameIndex: i, x: 400, y: y, confidence: 0.8, isVisible: true)
        }
        let result = analyzer.detectBouncePointsForTesting(from: points, sourceHeight: 1080)
        XCTAssertEqual(result.count, 0, "Monotonically falling ball should have 0 bounces")
    }

    func testSmoothTrajectoryTwoPointsReturnsTwoUnchanged() {
        // Two points: count < 3, should pass through as-is.
        let analyzer = OnDeviceVideoAnalyzer()
        let points = [
            InferencePoint(frameIndex: 0, x: 10, y: 20, confidence: 0.7, isVisible: true),
            InferencePoint(frameIndex: 1, x: 30, y: 40, confidence: 0.7, isVisible: true),
        ]
        let result = analyzer.smoothTrajectoryForTesting(points: points, windowRadius: 2)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].x, 10)
        XCTAssertEqual(result[1].x, 30)
    }

    // MARK: - effectivePoints fallback

    func testEffectivePointsFallbackActivatesWhenNoVisiblePoints() {
        let analyzer = OnDeviceVideoAnalyzer()
        // All points invisible (confidence below threshold, isVisible = false)
        let allPoints = (0..<6).map { i in
            InferencePoint(frameIndex: i, x: i * 10, y: i * 5, confidence: 0.20, isVisible: false)
        }
        let (effective, usingFallback) = analyzer.effectivePointsForTesting(allPoints: allPoints)
        XCTAssertTrue(usingFallback, "Should use fallback when no visible points")
        XCTAssertFalse(effective.isEmpty, "Fallback should return non-empty points")
    }

    func testEffectivePointsNoFallbackWhenVisiblePointsExist() {
        let analyzer = OnDeviceVideoAnalyzer()
        let allPoints = [
            InferencePoint(frameIndex: 0, x: 100, y: 100, confidence: 0.35, isVisible: true),
            InferencePoint(frameIndex: 1, x: 110, y: 110, confidence: 0.20, isVisible: false),
        ]
        let (effective, usingFallback) = analyzer.effectivePointsForTesting(allPoints: allPoints)
        XCTAssertFalse(usingFallback)
        XCTAssertEqual(effective.count, 1)
        XCTAssertTrue(effective[0].isVisible)
    }

    func testEffectivePointsFallbackSelectsTopConfidencePoints() {
        let analyzer = OnDeviceVideoAnalyzer()
        // Best confidence = 0.28; threshold = 0.28 * 0.75 = 0.21. Points at 0.28 and 0.25 pass; 0.10 does not.
        let allPoints = [
            InferencePoint(frameIndex: 0, x: 0, y: 0, confidence: 0.28, isVisible: false),
            InferencePoint(frameIndex: 1, x: 0, y: 0, confidence: 0.25, isVisible: false),
            InferencePoint(frameIndex: 2, x: 0, y: 0, confidence: 0.10, isVisible: false),
        ]
        let (effective, _) = analyzer.effectivePointsForTesting(allPoints: allPoints)
        XCTAssertEqual(effective.count, 2, "Only points above 75% of best confidence should be included")
    }

    // MARK: - BounceThresholds ordering

    func testBounceThresholdsMaxWindowFramesDecreaseFromRecallToPrecision() {
        let recall    = OnDeviceVideoAnalyzer(profile: .highRecall).bounceThresholdsForTesting
        let precision = OnDeviceVideoAnalyzer(profile: .highPrecision).bounceThresholdsForTesting
        XCTAssertGreaterThan(recall.maxWindowFrames, precision.maxWindowFrames,
                             "highRecall should allow wider temporal windows than highPrecision")
    }

    // MARK: - ActionThresholds ordering

    func testActionThresholdsHighPrecisionHasHigherMotionFloor() {
        let recall    = OnDeviceVideoAnalyzer(profile: .highRecall).actionThresholdsForTesting
        let precision = OnDeviceVideoAnalyzer(profile: .highPrecision).actionThresholdsForTesting
        XCTAssertGreaterThan(precision.motionFloor, recall.motionFloor,
                             "highPrecision should require more motion to trigger an action")
    }
}
