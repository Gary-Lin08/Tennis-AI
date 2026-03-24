import XCTest
@testable import Tennis_AI

final class CourtHomographyTests: XCTestCase {
    func testSolveIdentityProjectsPointsWithoutDrift() {
        let source = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 1, y: 0),
            CGPoint(x: 1, y: 1),
            CGPoint(x: 0, y: 1)
        ]

        let destination = source
        let homography = CourtHomography.solve(source: source, destination: destination)

        XCTAssertNotNil(homography)

        let projected = homography?.project(CGPoint(x: 0.23, y: 0.74))
        XCTAssertNotNil(projected)
        XCTAssertEqual(projected?.x ?? -1, 0.23, accuracy: 1e-6)
        XCTAssertEqual(projected?.y ?? -1, 0.74, accuracy: 1e-6)
    }

    func testSolveMapsCornersToUnitCourt() {
        let source = [
            CGPoint(x: 120, y: 680),
            CGPoint(x: 940, y: 690),
            CGPoint(x: 760, y: 220),
            CGPoint(x: 300, y: 210)
        ]

        let destination = [
            CGPoint(x: 0, y: 1),
            CGPoint(x: 1, y: 1),
            CGPoint(x: 1, y: 0),
            CGPoint(x: 0, y: 0)
        ]

        let homography = CourtHomography.solve(source: source, destination: destination)
        XCTAssertNotNil(homography)

        for (index, corner) in source.enumerated() {
            let mapped = homography?.project(corner)
            XCTAssertNotNil(mapped)
            XCTAssertEqual(mapped?.x ?? -1, destination[index].x, accuracy: 1e-5)
            XCTAssertEqual(mapped?.y ?? -1, destination[index].y, accuracy: 1e-5)
        }
    }

    func testInverseProjectsBackToSourceCoordinates() throws {
        let source = [
            CGPoint(x: 160, y: 640),
            CGPoint(x: 980, y: 670),
            CGPoint(x: 740, y: 210),
            CGPoint(x: 280, y: 200)
        ]

        let destination = [
            CGPoint(x: 0, y: 1),
            CGPoint(x: 1, y: 1),
            CGPoint(x: 1, y: 0),
            CGPoint(x: 0, y: 0)
        ]

        let homography = try XCTUnwrap(CourtHomography.solve(source: source, destination: destination))
        let inverse = try XCTUnwrap(homography.inverted())

        let point = CGPoint(x: 420, y: 500)
        let normalized = try XCTUnwrap(homography.project(point))
        let reconstructed = try XCTUnwrap(inverse.project(normalized))

        XCTAssertEqual(reconstructed.x, point.x, accuracy: 1e-4)
        XCTAssertEqual(reconstructed.y, point.y, accuracy: 1e-4)
    }
}
