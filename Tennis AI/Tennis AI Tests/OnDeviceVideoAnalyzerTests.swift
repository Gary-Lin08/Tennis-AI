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
}
