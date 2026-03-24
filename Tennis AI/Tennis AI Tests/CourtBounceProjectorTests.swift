import CoreGraphics
import XCTest
@testable import Tennis_AI

final class CourtBounceProjectorTests: XCTestCase {
    func testCalibratedMappingProjectsIntoCourtCoordinates() throws {
        let sourceCorners = [
            CGPoint(x: 120, y: 680),
            CGPoint(x: 940, y: 690),
            CGPoint(x: 760, y: 220),
            CGPoint(x: 300, y: 210)
        ]
        let destinationCorners = [
            CGPoint(x: 0, y: 1),
            CGPoint(x: 1, y: 1),
            CGPoint(x: 1, y: 0),
            CGPoint(x: 0, y: 0)
        ]
        let homography = try XCTUnwrap(
            CourtHomography.solve(source: sourceCorners, destination: destinationCorners)
        )
        let calibration = SessionCourtCalibration(
            sourceCorners: sourceCorners,
            homography: homography,
            qualityScore: 0.93,
            calibratedAt: Date(timeIntervalSince1970: 1234)
        )

        let normalizedPoint = CGPoint(x: 0.42, y: 0.67)
        let sourcePoint = try XCTUnwrap(homography.inverted()?.project(normalizedPoint))
        let bounce = InferencePoint(
            frameIndex: 12,
            x: Int(sourcePoint.x.rounded()),
            y: Int(sourcePoint.y.rounded()),
            confidence: 0.9,
            isVisible: true
        )

        let mapped = CourtBounceProjector.map(
            points: [bounce],
            frameSize: CGSize(width: 1080, height: 1920),
            calibration: calibration
        )[0]

        XCTAssertEqual(mapped.normalizedPoint.x, normalizedPoint.x, accuracy: 0.01)
        XCTAssertEqual(mapped.normalizedPoint.y, normalizedPoint.y, accuracy: 0.01)
        XCTAssertTrue(mapped.isInBounds)
    }

    func testFallbackMappingUsesFrameNormalizationWithoutCalibration() {
        let bounce = InferencePoint(
            frameIndex: 5,
            x: 540,
            y: 960,
            confidence: 0.8,
            isVisible: true
        )

        let mapped = CourtBounceProjector.map(
            points: [bounce],
            frameSize: CGSize(width: 1080, height: 1920),
            calibration: nil
        )[0]

        XCTAssertEqual(mapped.normalizedPoint.x, 540.0 / 1079.0, accuracy: 1e-8)
        XCTAssertEqual(mapped.normalizedPoint.y, 960.0 / 1919.0, accuracy: 1e-8)
        XCTAssertTrue(mapped.isInBounds)
    }

    func testCalibratedMappingMarksOutOfBoundsBounces() throws {
        let sourceCorners = [
            CGPoint(x: 120, y: 680),
            CGPoint(x: 940, y: 690),
            CGPoint(x: 760, y: 220),
            CGPoint(x: 300, y: 210)
        ]
        let destinationCorners = [
            CGPoint(x: 0, y: 1),
            CGPoint(x: 1, y: 1),
            CGPoint(x: 1, y: 0),
            CGPoint(x: 0, y: 0)
        ]
        let homography = try XCTUnwrap(
            CourtHomography.solve(source: sourceCorners, destination: destinationCorners)
        )
        let calibration = SessionCourtCalibration(
            sourceCorners: sourceCorners,
            homography: homography,
            qualityScore: 0.93,
            calibratedAt: Date(timeIntervalSince1970: 1234)
        )

        let outsidePoint = CGPoint(x: 1.12, y: 0.52)
        let sourcePoint = try XCTUnwrap(homography.inverted()?.project(outsidePoint))
        let bounce = InferencePoint(
            frameIndex: 13,
            x: Int(sourcePoint.x.rounded()),
            y: Int(sourcePoint.y.rounded()),
            confidence: 0.9,
            isVisible: true
        )

        let mapped = CourtBounceProjector.map(
            points: [bounce],
            frameSize: CGSize(width: 1080, height: 1920),
            calibration: calibration
        )[0]

        XCTAssertEqual(mapped.normalizedPoint.x, outsidePoint.x, accuracy: 0.02)
        XCTAssertEqual(mapped.normalizedPoint.y, outsidePoint.y, accuracy: 0.02)
        XCTAssertFalse(mapped.isInBounds)
    }
}
