import AVFoundation
import CoreML
import Foundation
import XCTest
@testable import Tennis_AI

final class PlaybackExportIntegrationTests: XCTestCase {
    func testConfiguredFixtureRunsAutoCalibrationAndExportsPlayback() async throws {
        let config = try integrationConfig()
        let loadedModel = try loadModel(using: config)

        let analyzer = OnDeviceVideoAnalyzer(profile: .balanced)
        let inferenceSummary = try await analyzer.analyze(
            videoURL: config.fixtureVideoURL,
            loadedModel: loadedModel
        )

        let calibrator = AutoCourtCalibrator()
        let autoCalibration = try await calibrator.calibrate(
            videoURL: config.fixtureVideoURL,
            trackingQualityScore: inferenceSummary.trackingQualityScore
        )

        let aspectRatio = try await resolveAspectRatio(for: config.fixtureVideoURL)
        let session = AnalysisSession(
            id: UUID(),
            videoTitle: config.fixtureVideoURL.lastPathComponent,
            sourceID: "integration-export-fixture",
            eventDate: Date(),
            trackedFrames: inferenceSummary.trackedFrames,
            totalFrames: inferenceSummary.totalFrames,
            ballVisibleRate: inferenceSummary.ballVisibleRate,
            trackingQualityScore: inferenceSummary.trackingQualityScore,
            estimatedBounceCount: inferenceSummary.estimatedBounceCount,
            processingStatus: .completed,
            inputSource: .upload,
            localVideoPath: config.fixtureVideoURL.path,
            trajectoryPoints: inferenceSummary.trackedPoints,
            bouncePoints: inferenceSummary.bouncePoints,
            detectedActions: inferenceSummary.detectedActions,
            note: "Integration export fixture generated from Mixkit tennis footage.",
            courtCalibration: autoCalibration.calibration,
            qualityBreakdown: inferenceSummary.qualityBreakdown
        )

        let renderer = VideoExportRenderer()
        let exportedURL = try await renderer.export(
            videoURL: config.fixtureVideoURL,
            session: session,
            config: PlaybackExportConfig(
                zoomScale: 1.0,
                aspectRatio: aspectRatio,
                focusTargetSourcePoint: nil,
                focusTrackingActionType: nil,
                focusSmoothingFactor: 0.32,
                overlays: ExportOverlayOptions(
                    showsTrajectory: true,
                    showsBounces: true,
                    showsActionLabels: true,
                    showsMiniCourtMap: true,
                    showsUncertaintyRings: false,
                    showsSummaryCard: true
                )
            )
        ) { _ in }

        try FileManager.default.createDirectory(
            at: config.outputVideoURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: config.outputVideoURL.path) {
            try FileManager.default.removeItem(at: config.outputVideoURL)
        }
        try FileManager.default.copyItem(at: exportedURL, to: config.outputVideoURL)

        let attributes = try FileManager.default.attributesOfItem(atPath: config.outputVideoURL.path)
        let outputSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0

        XCTAssertGreaterThan(inferenceSummary.trackedFrames, 0)
        XCTAssertGreaterThan(autoCalibration.calibration.qualityScore, 0)
        XCTAssertGreaterThan(outputSize, 1_000_000)

        print("Fixture video: \(config.fixtureVideoURL.path)")
        print("Output video: \(config.outputVideoURL.path)")
        print("Tracked frames: \(inferenceSummary.trackedFrames)")
        print("Bounce count: \(inferenceSummary.bouncePoints.count)")
        print("Calibration quality: \(autoCalibration.calibration.qualityScore)")
    }

    private func integrationConfig() throws -> IntegrationConfig {
        let env = ProcessInfo.processInfo.environment
        let documentsURL = try documentsDirectory()
        let repoRoot = repositoryRoot()

        let fixtureVideoPath = env["TENNIS_AI_FIXTURE_VIDEO"].flatMap { $0.isEmpty ? nil : $0 }
            ?? repoRoot
                .appendingPathComponent("Tennis AI/GridTrackNet/Sample Video's/Professional Hardcourt.mp4")
                .path
        let outputVideoPath = env["TENNIS_AI_EXPORT_OUTPUT"].flatMap { $0.isEmpty ? nil : $0 }
            ?? documentsURL
                .appendingPathComponent("IntegrationOutputs", isDirectory: true)
                .appendingPathComponent("tennis-auto-calibration-output.mp4")
                .path
        let modelSourcePath = env["TENNIS_AI_MODEL_SOURCE"].flatMap { $0.isEmpty ? nil : $0 }

        guard FileManager.default.fileExists(atPath: fixtureVideoPath) else {
            throw XCTSkip("Missing fixture video at \(fixtureVideoPath).")
        }
        if let modelSourcePath, !FileManager.default.fileExists(atPath: modelSourcePath) {
            throw XCTSkip("Missing model source at \(modelSourcePath).")
        }

        return IntegrationConfig(
            fixtureVideoURL: URL(fileURLWithPath: fixtureVideoPath),
            outputVideoURL: URL(fileURLWithPath: outputVideoPath),
            modelSourceURL: modelSourcePath.map { URL(fileURLWithPath: $0) }
        )
    }

    private func loadModel(using config: IntegrationConfig) throws -> LoadedOnDeviceModel {
        if let sourceModelURL = config.modelSourceURL {
            let compiledURL = try MLModel.compileModel(at: sourceModelURL)
            let model = try MLModel(contentsOf: compiledURL, configuration: MLModelConfiguration())
            return LoadedOnDeviceModel(
                name: sourceModelURL.deletingPathExtension().lastPathComponent,
                model: model
            )
        }

        return try OnDeviceModelLoader(bundle: .main).loadFirstAvailableModel()
    }

    private func documentsDirectory() throws -> URL {
        if let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            return url
        }
        throw XCTSkip("Unable to resolve simulator documents directory.")
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // Tennis AI
            .deletingLastPathComponent() // Tennis AI (repo subdir)
    }

    private func resolveAspectRatio(for videoURL: URL) async throws -> Double {
        let asset = AVURLAsset(url: videoURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else {
            return 16.0 / 9.0
        }
        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let size = naturalSize.applying(transform)
        let width = max(abs(size.width), 1)
        let height = max(abs(size.height), 1)
        return Double(width / height)
    }
}

private struct IntegrationConfig {
    let fixtureVideoURL: URL
    let outputVideoURL: URL
    let modelSourceURL: URL?
}
