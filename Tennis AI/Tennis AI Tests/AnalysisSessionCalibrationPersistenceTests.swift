import XCTest
@testable import Tennis_AI

@MainActor
final class AnalysisSessionCalibrationPersistenceTests: XCTestCase {
    func testEncodingAndDecodingPreservesCalibrationValidation() throws {
        let session = makeSession(
            courtCalibration: nil,
            calibrationValidation: SessionCalibrationValidation(
                averageErrorPixels: 5.2,
                maxErrorPixels: 12.7,
                score: 0.88,
                sampleCount: 3,
                tier: .high,
                validatedAt: Date(timeIntervalSince1970: 1000)
            )
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(session)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(AnalysisSession.self, from: data)
        let validation = try XCTUnwrap(decoded.calibrationValidation)

        XCTAssertEqual(validation.averageErrorPixels, 5.2, accuracy: 1e-8)
        XCTAssertEqual(validation.maxErrorPixels, 12.7, accuracy: 1e-8)
        XCTAssertEqual(validation.tier, .high)
    }

    func testDecodingWithoutCalibrationValidationKeepsBackwardCompatibility() throws {
        let session = makeSession(courtCalibration: nil, calibrationValidation: nil)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(session)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("calibrationValidation"))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(AnalysisSession.self, from: data)

        XCTAssertNil(decoded.calibrationValidation)
    }

    func testPresentationOriginDistinguishesBuiltInSamplesFromLocalSummaries() {
        let builtInSample = AnalysisSession(
            id: UUID(),
            videoTitle: "sample",
            sourceID: "sample-1",
            eventDate: Date(),
            trackedFrames: 50,
            totalFrames: 100,
            ballVisibleRate: 0.5,
            trackingQualityScore: 0.8,
            estimatedBounceCount: 4,
            processingStatus: .completed,
            inputSource: nil,
            localVideoPath: nil,
            trajectoryPoints: nil,
            bouncePoints: nil,
            detectedActions: nil,
            note: "sample"
        )

        XCTAssertTrue(builtInSample.isBuiltInSample)
        XCTAssertEqual(builtInSample.presentationOriginLabel, "内置样例")

        let localSummary = makeSession(courtCalibration: nil, calibrationValidation: nil)
        XCTAssertFalse(localSummary.isBuiltInSample)
        XCTAssertEqual(localSummary.presentationOriginLabel, "本地摘要")
    }

    func testEncodingAndDecodingPreservesCourtCalibration() throws {
        let calibration = SessionCourtCalibration(
            sourceCorners: [
                CGPoint(x: 120, y: 680),
                CGPoint(x: 940, y: 690),
                CGPoint(x: 760, y: 220),
                CGPoint(x: 300, y: 210)
            ],
            homography: CourtHomography(
                h11: 1,
                h12: 0,
                h13: 0,
                h21: 0,
                h22: 1,
                h23: 0,
                h31: 0,
                h32: 0,
                h33: 1
            ),
            qualityScore: 0.91,
            calibratedAt: Date(timeIntervalSince1970: 2000)
        )

        let session = makeSession(courtCalibration: calibration, calibrationValidation: nil)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(session)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(AnalysisSession.self, from: data)
        let restoredCalibration = try XCTUnwrap(decoded.courtCalibration)

        XCTAssertEqual(restoredCalibration.sourceCorners, calibration.sourceCorners)
        XCTAssertEqual(restoredCalibration.homography, calibration.homography)
        XCTAssertEqual(restoredCalibration.qualityScore, calibration.qualityScore, accuracy: 1e-8)
        XCTAssertEqual(restoredCalibration.calibratedAt, calibration.calibratedAt)
    }

    func testSaveBackendConfigUsesSummarySyncTerminology() {
        XCTAssertEqual(
            TennisAIViewModel.backendConfigSavedMessage(summarySyncEnabled: false),
            "已保存：行为埋点与自动远端结构化分析已启用；未填写 legacy user_id。"
        )
        XCTAssertEqual(
            TennisAIViewModel.backendConfigSavedMessage(summarySyncEnabled: true),
            "后端配置已保存，行为埋点与自动远端结构化分析已启用；legacy user_id 已保留作兼容字段。"
        )
    }

    func testEncodingAndDecodingPreservesStructuredRemoteFields() throws {
        let session = AnalysisSession(
            id: UUID(),
            videoTitle: "remote",
            sourceID: "remote-1",
            actorKey: "ios:install:player_001",
            eventDate: Date(timeIntervalSince1970: 1234),
            trackedFrames: 120,
            totalFrames: 240,
            ballVisibleRate: 0.66,
            trackingQualityScore: 0.91,
            estimatedBounceCount: 10,
            processingStatus: .completed,
            inputSource: .upload,
            localVideoPath: "/tmp/video.mov",
            trajectoryPoints: nil,
            bouncePoints: nil,
            detectedActions: nil,
            note: "remote ready",
            sessionOrigin: .remoteStructured,
            structuredRallies: [
                StructuredRally(
                    rallyID: 1,
                    startFrame: 0,
                    endFrame: 60,
                    startSec: 0,
                    endSec: 2,
                    durationSec: 2,
                    numFrames: 61,
                    numShots: 4,
                    winnerSide: "near",
                    winnerSource: "rule",
                    pointStatus: "confirmed",
                    serverSideBefore: "near",
                    serverSideAfter: "far",
                    beforeScore: "0-0",
                    afterScore: "15-0"
                )
            ],
            scoreTimeline: [
                ScoreTimelineEntry(
                    rallyID: 1,
                    beforeScore: "0-0",
                    afterScore: "15-0",
                    winnerSide: "near",
                    pointStatus: "confirmed",
                    serverSideBefore: "near",
                    serverSideAfter: "far"
                )
            ],
            remoteModelVersions: ["ios_summary": "v1"],
            courtDetectionQualityScore: 0.93
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(session)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(AnalysisSession.self, from: data)

        XCTAssertEqual(decoded.actorKey, "ios:install:player_001")
        XCTAssertEqual(decoded.sessionOrigin, .remoteStructured)
        XCTAssertEqual(decoded.presentationOriginLabel, "远端结构化")
        XCTAssertEqual(decoded.structuredRallies?.count, 1)
        XCTAssertEqual(decoded.scoreTimeline?.first?.afterScore, "15-0")
        XCTAssertEqual(decoded.remoteModelVersions?["ios_summary"], "v1")
        XCTAssertEqual(try XCTUnwrap(decoded.courtDetectionQualityScore), 0.93, accuracy: 1e-8)
    }

    func testDecodingLegacyCourtDetectionScoreMapsToTrackingQualityScore() throws {
        let legacyJSON = """
        {
          "id": "123E4567-E89B-12D3-A456-426614174999",
          "videoTitle": "legacy",
          "sourceID": "legacy-1",
          "eventDate": "1970-01-01T00:08:20Z",
          "trackedFrames": 100,
          "totalFrames": 200,
          "ballVisibleRate": 0.5,
          "courtDetectionScore": 0.76,
          "estimatedBounceCount": 8,
          "processingStatus": "completed",
          "inputSource": "upload",
          "localVideoPath": "/tmp/video.mov",
          "note": "legacy"
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(AnalysisSession.self, from: Data(legacyJSON.utf8))

        XCTAssertEqual(decoded.trackingQualityScore, 0.76, accuracy: 1e-8)
    }

    private func makeSession(
        courtCalibration: SessionCourtCalibration?,
        calibrationValidation: SessionCalibrationValidation?
    ) -> AnalysisSession {
        AnalysisSession(
            id: UUID(),
            videoTitle: "session",
            sourceID: "source-1",
            eventDate: Date(timeIntervalSince1970: 500),
            trackedFrames: 100,
            totalFrames: 200,
            ballVisibleRate: 0.5,
            trackingQualityScore: 0.8,
            estimatedBounceCount: 8,
            processingStatus: .completed,
            inputSource: .upload,
            localVideoPath: "/tmp/video.mov",
            trajectoryPoints: nil,
            bouncePoints: nil,
            detectedActions: nil,
            note: "note",
            courtCalibration: courtCalibration,
            calibrationValidation: calibrationValidation
        )
    }
}
