import XCTest
@testable import Tennis_AI

final class CourtCalibrationValidatorTests: XCTestCase {
    func testBuildResultComputesAverageAndMaxErrors() throws {
        let samples = [
            sample(targetIndex: 0, errorPixels: 2),
            sample(targetIndex: 1, errorPixels: 4),
            sample(targetIndex: 2, errorPixels: 8)
        ]

        let result = try XCTUnwrap(
            CourtCalibrationValidator.buildResult(
                samples: samples,
                frameSize: CGSize(width: 1080, height: 1920),
                validatedAt: Date(timeIntervalSince1970: 0)
            )
        )

        XCTAssertEqual(result.averageErrorPixels, 14.0 / 3.0, accuracy: 1e-8)
        XCTAssertEqual(result.maxErrorPixels, 8, accuracy: 1e-8)
        XCTAssertEqual(result.sampleCount, 3)
    }

    func testQualityTierUsesFrameNormalizedThresholds() {
        let frameSize = CGSize(width: 1080, height: 1920)

        XCTAssertEqual(
            CourtCalibrationValidator.qualityTier(averageErrorPixels: 10, frameSize: frameSize),
            .high
        )
        XCTAssertEqual(
            CourtCalibrationValidator.qualityTier(averageErrorPixels: 20, frameSize: frameSize),
            .medium
        )
        XCTAssertEqual(
            CourtCalibrationValidator.qualityTier(averageErrorPixels: 45, frameSize: frameSize),
            .low
        )
    }

    func testQualityScoreDecreasesAsErrorGrows() {
        let frameSize = CGSize(width: 1080, height: 1920)
        let highPrecision = CourtCalibrationValidator.qualityScore(averageErrorPixels: 4, frameSize: frameSize)
        let lowPrecision = CourtCalibrationValidator.qualityScore(averageErrorPixels: 50, frameSize: frameSize)

        XCTAssertGreaterThan(highPrecision, lowPrecision)
        XCTAssertGreaterThanOrEqual(highPrecision, 0)
        XCTAssertLessThanOrEqual(highPrecision, 1)
        XCTAssertGreaterThanOrEqual(lowPrecision, 0)
        XCTAssertLessThanOrEqual(lowPrecision, 1)
    }

    func testRecalibrationAdvisorPrefersValidationTierWhenAvailable() {
        XCTAssertTrue(
            CourtRecalibrationAdvisor.shouldRecommendRecalibration(
                calibrationScore: 0.92,
                validationTier: .low
            )
        )
        XCTAssertFalse(
            CourtRecalibrationAdvisor.shouldRecommendRecalibration(
                calibrationScore: 0.50,
                validationTier: .high
            )
        )
    }

    func testRecalibrationAdvisorFallsBackToCalibrationScoreThreshold() {
        XCTAssertTrue(
            CourtRecalibrationAdvisor.shouldRecommendRecalibration(
                calibrationScore: 0.63,
                validationTier: nil
            )
        )
        XCTAssertFalse(
            CourtRecalibrationAdvisor.shouldRecommendRecalibration(
                calibrationScore: 0.64,
                validationTier: nil
            )
        )
        XCTAssertFalse(
            CourtRecalibrationAdvisor.shouldRecommendRecalibration(
                calibrationScore: nil,
                validationTier: nil
            )
        )
    }

    func testCalibrationQualityEstimatorRewardsPlausibleCourtShape() {
        let frameSize = CGSize(width: 1080, height: 1920)
        let plausible = [
            CGPoint(x: 170, y: 1510),
            CGPoint(x: 920, y: 1510),
            CGPoint(x: 675, y: 520),
            CGPoint(x: 395, y: 520)
        ]
        let weak = [
            CGPoint(x: 320, y: 1280),
            CGPoint(x: 760, y: 1280),
            CGPoint(x: 660, y: 980),
            CGPoint(x: 420, y: 980)
        ]

        let plausibleScore = CourtCalibrationQualityEstimator.estimate(
            corners: plausible,
            frameSize: frameSize,
            modelPrior: 0.82,
            detectorScore: 0.78
        )
        let weakScore = CourtCalibrationQualityEstimator.estimate(
            corners: weak,
            frameSize: frameSize,
            modelPrior: 0.82,
            detectorScore: 0.30
        )

        XCTAssertGreaterThan(plausibleScore, weakScore)
    }

    func testAutoCourtCalibratorAggregateStabilizesAroundBestCandidate() throws {
        let frameSize = CGSize(width: 1080, height: 1920)
        let candidates = [
            AutoCourtCalibrator.Candidate(
                sourceCorners: [
                    CGPoint(x: 172, y: 1512),
                    CGPoint(x: 918, y: 1511),
                    CGPoint(x: 678, y: 516),
                    CGPoint(x: 397, y: 518)
                ],
                normalizedDetectorScore: 0.81,
                frameIndex: 120,
                frameSize: frameSize
            ),
            AutoCourtCalibrator.Candidate(
                sourceCorners: [
                    CGPoint(x: 168, y: 1508),
                    CGPoint(x: 923, y: 1510),
                    CGPoint(x: 672, y: 523),
                    CGPoint(x: 392, y: 524)
                ],
                normalizedDetectorScore: 0.77,
                frameIndex: 144,
                frameSize: frameSize
            ),
            AutoCourtCalibrator.Candidate(
                sourceCorners: [
                    CGPoint(x: 176, y: 1516),
                    CGPoint(x: 916, y: 1514),
                    CGPoint(x: 681, y: 520),
                    CGPoint(x: 401, y: 521)
                ],
                normalizedDetectorScore: 0.79,
                frameIndex: 132,
                frameSize: frameSize
            )
        ]

        let aggregated = try XCTUnwrap(AutoCourtCalibrator.aggregate(candidates: candidates))
        XCTAssertEqual(aggregated.frameIndex, 120)
        XCTAssertEqual(aggregated.sourceCorners[0].x, 172, accuracy: 4)
        XCTAssertEqual(aggregated.sourceCorners[0].y, 1512, accuracy: 4)
        XCTAssertEqual(aggregated.sourceCorners[2].x, 678, accuracy: 6)
        XCTAssertEqual(aggregated.sourceCorners[2].y, 520, accuracy: 6)
    }

    func testAutoCourtCalibratorRejectsImplausibleCourtShape() {
        let frameSize = CGSize(width: 1080, height: 1920)
        let flat = [
            CGPoint(x: 120, y: 1200),
            CGPoint(x: 940, y: 1200),
            CGPoint(x: 900, y: 1110),
            CGPoint(x: 160, y: 1110)
        ]

        XCTAssertFalse(AutoCourtCalibrator.isCourtLike(corners: flat, frameSize: frameSize))
        XCTAssertEqual(
            AutoCourtCalibrator.normalizedScore(
                for: flat,
                frameSize: frameSize,
                observationConfidence: 0.9
            ),
            0,
            accuracy: 1e-8
        )
    }

    func testCourtBounceProjectorUsesCalibrationHomographyForMiniCourtMapping() {
        let frameSize = CGSize(width: 1080, height: 1920)
        let calibration = makeLinearCalibration()
        let points = [inferencePoint(frameIndex: 12, x: 500, y: 1200)]

        let mapped = CourtBounceProjector.map(
            points: points,
            frameSize: frameSize,
            calibration: calibration
        )

        XCTAssertEqual(mapped.count, 1)
        XCTAssertEqual(mapped[0].normalizedPoint.x, 0.5, accuracy: 1e-8)
        XCTAssertEqual(mapped[0].normalizedPoint.y, 0.6, accuracy: 1e-8)
        XCTAssertTrue(mapped[0].isInBounds)
    }

    func testCourtBounceProjectorMarksOutOfBoundsWhenProjectedOutsideCourt() {
        let frameSize = CGSize(width: 1080, height: 1920)
        let calibration = makeLinearCalibration()
        let points = [inferencePoint(frameIndex: 24, x: 1300, y: 1200)]

        let mapped = CourtBounceProjector.map(
            points: points,
            frameSize: frameSize,
            calibration: calibration
        )

        XCTAssertEqual(mapped.count, 1)
        XCTAssertEqual(mapped[0].normalizedPoint.x, 1.3, accuracy: 1e-8)
        XCTAssertEqual(mapped[0].normalizedPoint.y, 0.6, accuracy: 1e-8)
        XCTAssertFalse(mapped[0].isInBounds)
    }

    func testUncertaintyRadiusOnMiniCourtIsMonotonicAndClamped() {
        let frameSize = CGSize(width: 1080, height: 1920)
        let mapReferenceLength: CGFloat = 100

        let minRadius = CourtCalibrationValidator.uncertaintyRadiusOnMap(
            averageErrorPixels: 0,
            frameSize: frameSize,
            mapReferenceLength: mapReferenceLength
        )
        let mediumRadius = CourtCalibrationValidator.uncertaintyRadiusOnMap(
            averageErrorPixels: 20,
            frameSize: frameSize,
            mapReferenceLength: mapReferenceLength
        )
        let maxRadius = CourtCalibrationValidator.uncertaintyRadiusOnMap(
            averageErrorPixels: 5_000,
            frameSize: frameSize,
            mapReferenceLength: mapReferenceLength
        )

        XCTAssertEqual(minRadius, 1.5, accuracy: 1e-8)
        XCTAssertGreaterThan(mediumRadius, minRadius)
        XCTAssertEqual(maxRadius, 24.0, accuracy: 1e-8)
    }

    private func sample(targetIndex: Int, errorPixels: CGFloat) -> CourtCalibrationValidationSample {
        let target = CourtCalibrationValidator.defaultTargets[targetIndex]
        let expected = CGPoint(x: 420, y: 300)
        let observed = CGPoint(x: expected.x + errorPixels, y: expected.y)
        return CourtCalibrationValidationSample(
            target: target,
            observedSourcePoint: observed,
            expectedSourcePoint: expected,
            errorPixels: Double(errorPixels)
        )
    }

    private func inferencePoint(frameIndex: Int, x: Int, y: Int) -> InferencePoint {
        InferencePoint(
            frameIndex: frameIndex,
            x: x,
            y: y,
            confidence: 0.95,
            isVisible: true
        )
    }

    private func makeLinearCalibration() -> SessionCourtCalibration {
        SessionCourtCalibration(
            sourceCorners: [
                CGPoint(x: 0, y: 2000),
                CGPoint(x: 1000, y: 2000),
                CGPoint(x: 1000, y: 0),
                CGPoint(x: 0, y: 0)
            ],
            homography: CourtHomography(
                h11: 1.0 / 1000.0,
                h12: 0,
                h13: 0,
                h21: 0,
                h22: 1.0 / 2000.0,
                h23: 0,
                h31: 0,
                h32: 0,
                h33: 1
            ),
            qualityScore: 0.9,
            calibratedAt: Date(timeIntervalSince1970: 0)
        )
    }
}
