import CoreGraphics
import XCTest
@testable import Tennis_AI

final class PlaybackExportMathTests: XCTestCase {
    func testSmoothedFocusMovesContinuouslyTowardTarget() {
        var current = CGPoint(x: 100, y: 100)
        let target = CGPoint(x: 340, y: 220)
        let initialDistance = distance(current, target)

        var distances: [CGFloat] = []
        for _ in 0..<8 {
            current = PlaybackFrameMath.resolveSmoothedFocus(
                current: current,
                target: target,
                smoothing: 0.25
            ) ?? current
            distances.append(distance(current, target))
        }

        XCTAssertEqual(distances.count, 8)
        XCTAssertTrue(distances.allSatisfy { $0 >= 0 })
        for index in 1..<distances.count {
            XCTAssertLessThanOrEqual(distances[index], distances[index - 1] + 0.0001)
        }
        XCTAssertLessThan(distances.last ?? .greatestFiniteMagnitude, initialDistance)
    }

    func testCropRectAlwaysStaysInsideSourceBounds() {
        let sourceSize = CGSize(width: 1920, height: 1080)
        let focuses = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: sourceSize.width, y: 0),
            CGPoint(x: sourceSize.width, y: sourceSize.height),
            CGPoint(x: 0, y: sourceSize.height),
            CGPoint(x: sourceSize.width * 0.5, y: sourceSize.height * 0.5)
        ]

        for focus in focuses {
            let cropRect = PlaybackFrameMath.resolveCropRect(
                sourceSize: sourceSize,
                zoomScale: 2.6,
                aspectRatio: 9.0 / 16.0,
                focusPoint: focus
            )
            XCTAssertGreaterThan(cropRect.width, 0)
            XCTAssertGreaterThan(cropRect.height, 0)
            XCTAssertGreaterThanOrEqual(cropRect.minX, 0)
            XCTAssertGreaterThanOrEqual(cropRect.minY, 0)
            XCTAssertLessThanOrEqual(cropRect.maxX, sourceSize.width)
            XCTAssertLessThanOrEqual(cropRect.maxY, sourceSize.height)
        }
    }

    func testCropRectMatchesTargetAspectRatio() {
        let cropRect = PlaybackFrameMath.resolveCropRect(
            sourceSize: CGSize(width: 1080, height: 1920),
            zoomScale: 1.8,
            aspectRatio: 4.0 / 3.0,
            focusPoint: CGPoint(x: 420, y: 960)
        )

        XCTAssertEqual(cropRect.width / cropRect.height, 4.0 / 3.0, accuracy: 0.001)
    }

    func testOverlayOptionsTogglesAreIndependent() {
        var options = ExportOverlayOptions()
        XCTAssertTrue(options.showsTrajectory)
        XCTAssertTrue(options.showsBounces)
        XCTAssertFalse(options.showsActionLabels)
        XCTAssertTrue(options.showsMiniCourtMap)
        XCTAssertTrue(options.showsUncertaintyRings)
        XCTAssertTrue(options.showsSummaryCard)

        options.showsActionLabels = true
        XCTAssertTrue(options.showsActionLabels)
        XCTAssertTrue(options.showsTrajectory)
        XCTAssertTrue(options.showsBounces)
        XCTAssertTrue(options.showsMiniCourtMap)
        XCTAssertTrue(options.showsUncertaintyRings)
        XCTAssertTrue(options.showsSummaryCard)

        options.showsMiniCourtMap = false
        XCTAssertFalse(options.showsMiniCourtMap)
        XCTAssertTrue(options.showsActionLabels)
        XCTAssertTrue(options.showsTrajectory)
        XCTAssertTrue(options.showsBounces)
        XCTAssertTrue(options.showsUncertaintyRings)
        XCTAssertTrue(options.showsSummaryCard)

        options.showsUncertaintyRings = false
        XCTAssertFalse(options.showsUncertaintyRings)
        XCTAssertFalse(options.showsMiniCourtMap)
        XCTAssertTrue(options.showsActionLabels)
        XCTAssertTrue(options.showsTrajectory)
        XCTAssertTrue(options.showsBounces)
        XCTAssertTrue(options.showsSummaryCard)

        options.showsTrajectory = false
        XCTAssertFalse(options.showsTrajectory)
        XCTAssertTrue(options.showsBounces)
        XCTAssertTrue(options.showsActionLabels)
        XCTAssertFalse(options.showsMiniCourtMap)
        XCTAssertFalse(options.showsUncertaintyRings)
        XCTAssertTrue(options.showsSummaryCard)

        options.showsSummaryCard = false
        XCTAssertFalse(options.showsSummaryCard)
        XCTAssertFalse(options.showsTrajectory)
        XCTAssertTrue(options.showsBounces)
        XCTAssertTrue(options.showsActionLabels)
        XCTAssertFalse(options.showsMiniCourtMap)
        XCTAssertFalse(options.showsUncertaintyRings)
    }

    private func distance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        let dx = lhs.x - rhs.x
        let dy = lhs.y - rhs.y
        return sqrt(dx * dx + dy * dy)
    }
}
