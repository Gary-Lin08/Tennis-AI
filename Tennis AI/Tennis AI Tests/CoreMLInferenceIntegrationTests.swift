import CoreML
import Foundation
import XCTest
@testable import Tennis_AI

final class CoreMLInferenceIntegrationTests: XCTestCase {
    func testFixtureRunsOnDeviceCoreMLInference() async throws {
        let fixtureURL = try resolveFixtureVideoURL()
        let modelURL = try resolveModelSourceURL()
        let loadedModel = try loadModel(from: modelURL)

        let analyzer = OnDeviceVideoAnalyzer(profile: .balanced)
        let summary = try await analyzer.analyze(videoURL: fixtureURL, loadedModel: loadedModel)

        XCTAssertGreaterThan(summary.totalFrames, 0, "totalFrames should be positive")
        XCTAssertGreaterThan(summary.sampledFrameCount, 0, "sampledFrameCount should be positive")
        XCTAssertGreaterThan(summary.successfulPredictionCount, 0, "successfulPredictionCount should be positive")
        XCTAssertGreaterThan(summary.trackedFrames, 0, "trackedFrames should be positive")
        XCTAssertFalse(summary.modelName.isEmpty, "modelName should not be empty")

        print("COREML_INFERENCE fixture=\(fixtureURL.path)")
        print("COREML_INFERENCE model=\(summary.modelName)")
        print("COREML_INFERENCE totalFrames=\(summary.totalFrames)")
        print("COREML_INFERENCE sampledFrameCount=\(summary.sampledFrameCount)")
        print("COREML_INFERENCE successfulPredictionCount=\(summary.successfulPredictionCount)")
        print("COREML_INFERENCE trackedFrames=\(summary.trackedFrames)")
        print("COREML_INFERENCE bounceCount=\(summary.bouncePoints.count)")
        print("COREML_INFERENCE quality=\(summary.trackingQualityScore)")
        print("COREML_INFERENCE note=\(summary.analysisNote)")
    }

    private func resolveFixtureVideoURL() throws -> URL {
        let env = ProcessInfo.processInfo.environment
        if let raw = env["TENNIS_AI_FIXTURE_VIDEO"], !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let url = URL(fileURLWithPath: raw)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw XCTSkip("Fixture video not found at \(url.path)")
            }
            return url
        }

        let repoRoot = repositoryRoot()
        let defaultURL = repoRoot.appendingPathComponent(
            "Tennis AI/GridTrackNet/Sample Video's/Professional Hardcourt.mp4"
        )
        guard FileManager.default.fileExists(atPath: defaultURL.path) else {
            throw XCTSkip("Fixture video not found at \(defaultURL.path)")
        }
        return defaultURL
    }

    private func resolveModelSourceURL() throws -> URL {
        let env = ProcessInfo.processInfo.environment
        if let raw = env["TENNIS_AI_MODEL_SOURCE"], !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let url = URL(fileURLWithPath: raw)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw XCTSkip("Model source not found at \(url.path)")
            }
            return url
        }

        let repoRoot = repositoryRoot()
        let defaultURL = repoRoot.appendingPathComponent("Tennis AI/Tennis AI/TrackNet.mlpackage")
        guard FileManager.default.fileExists(atPath: defaultURL.path) else {
            throw XCTSkip("Model source not found at \(defaultURL.path)")
        }
        return defaultURL
    }

    private func loadModel(from sourceModelURL: URL) throws -> LoadedOnDeviceModel {
        let compiledURL = try MLModel.compileModel(at: sourceModelURL)
        let model = try MLModel(contentsOf: compiledURL, configuration: MLModelConfiguration())
        return LoadedOnDeviceModel(
            name: sourceModelURL.deletingPathExtension().lastPathComponent,
            model: model
        )
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // Tennis AI
            .deletingLastPathComponent() // Tennis AI (repo subdir)
    }
}
