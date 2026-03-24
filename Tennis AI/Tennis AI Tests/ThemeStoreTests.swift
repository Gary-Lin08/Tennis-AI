import SwiftUI
import UIKit
import XCTest
@testable import Tennis_AI

@MainActor
final class ThemeStoreTests: XCTestCase {
    private let suiteName = "ThemeStoreTests"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        ThemeStore.resetPersistedSelection(defaults: defaults)
        TennisTheme.currentSurface = .grass
    }

    override func tearDown() {
        ThemeStore.resetPersistedSelection(defaults: defaults)
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        TennisTheme.currentSurface = .grass
        super.tearDown()
    }

    func testDefaultsToGrassWhenNoPersistedSelectionExists() {
        let store = ThemeStore(defaults: defaults)
        let selectedSurface = store.selectedSurface
        let palette = store.palette
        let currentSurface = TennisTheme.currentSurface

        XCTAssertEqual(selectedSurface, .grass)
        assertColor(palette.pageBottom, red: 0.86, green: 0.94, blue: 0.87)
        XCTAssertEqual(currentSurface, .grass)
    }

    func testSelectionPersistsAcrossStoreInstances() {
        let store = ThemeStore(defaults: defaults)

        store.select(.clay)
        let persistedSurface = defaults.string(forKey: ThemeStore.selectedSurfaceDefaultsKey)

        XCTAssertEqual(persistedSurface, CourtSurfaceTheme.clay.rawValue)

        let reloadedStore = ThemeStore(defaults: defaults)
        let selectedSurface = reloadedStore.selectedSurface
        let currentSurface = TennisTheme.currentSurface
        XCTAssertEqual(selectedSurface, .clay)
        XCTAssertEqual(currentSurface, .clay)
    }

    func testPaletteMappingRemainsStableForEachSurface() {
        assertColor(CourtSurfaceTheme.hard.palette.courtDeepGreen, red: 0.08, green: 0.23, blue: 0.45)
        assertColor(CourtSurfaceTheme.clay.palette.pageTop, red: 0.98, green: 0.93, blue: 0.86)
        assertColor(CourtSurfaceTheme.grass.palette.courtGreen, red: 0.16, green: 0.49, blue: 0.26)
    }

    private func assertColor(
        _ color: Color,
        red expectedRed: CGFloat,
        green expectedGreen: CGFloat,
        blue expectedBlue: CGFloat,
        alpha expectedAlpha: CGFloat = 1.0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let uiColor = UIColor(color)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0

        XCTAssertTrue(
            uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha),
            file: file,
            line: line
        )
        XCTAssertEqual(red, expectedRed, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(green, expectedGreen, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(blue, expectedBlue, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(alpha, expectedAlpha, accuracy: 0.001, file: file, line: line)
    }
}
