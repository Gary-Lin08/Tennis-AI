import XCTest
@testable import Tennis_AI

final class RemoteAnalysisConfigTests: XCTestCase {
    func testBuildNormalizesLegacyEndpointAndActorKey() {
        let config = RemoteAnalysisConfig.build(
            endpointRaw: "http://127.0.0.1:8000/sessions/upload",
            installID: "install-abc",
            localUserIDRaw: "player_001"
        )

        XCTAssertEqual(config?.baseURL.absoluteString, "http://127.0.0.1:8000")
        XCTAssertEqual(config?.actorKey, "ios:install-abc:player_001")
        XCTAssertEqual(config?.localUserID, "player_001")
    }

    func testBuildRejectsMissingLocalUserID() {
        let config = RemoteAnalysisConfig.build(
            endpointRaw: "http://127.0.0.1:8000",
            installID: "install-abc",
            localUserIDRaw: "   "
        )

        XCTAssertNil(config)
    }
}
