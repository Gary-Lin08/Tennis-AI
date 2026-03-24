//
//  PoseShotRecognizer.swift
//  Tennis AI
//
//  Created by Codex on 2026/3/19.
//

import AVFoundation
import CoreGraphics
import CoreML
import Foundation
import Vision

struct PoseShotRecognitionResult {
    let actions: [DetectedAction]
    let modelName: String?
    let note: String
}

struct PoseShotRecognizer {
    private struct Runtime {
        let name: String
        let model: MLModel
        let inputName: String
        let outputName: String
    }

    private struct SampledFrame {
        let image: CGImage
        let frameIndex: Int
    }

    private struct PoseFeatureSample {
        let frameIndex: Int
        let x: Int
        let y: Int
        let features: [Float]
        let mirroredFeatures: [Float]

        func carryingFrameIndex(_ newFrameIndex: Int) -> PoseFeatureSample {
            PoseFeatureSample(
                frameIndex: newFrameIndex,
                x: x,
                y: y,
                features: features,
                mirroredFeatures: mirroredFeatures
            )
        }
    }

    private static let expectedModelNames = ["ShotRecognitionRNN", "TennisShotRecognitionRNN"]
    private static let sequenceLength = 30
    private static let framesPerWindow = 60
    private static let maxWindows = 5
    private static let minFramesBetweenShots = 60
    private static let minJointConfidence: Float = 0.18
    private static let minJointCount = 8
    private static let poseOutputOrder: [ActionType?] = [.backhand, .forehand, nil, .serve]
    private static let requiredJoints: [VNHumanBodyPoseObservation.JointName] = [
        .nose,
        .leftShoulder,
        .rightShoulder,
        .leftElbow,
        .rightElbow,
        .leftWrist,
        .rightWrist,
        .leftHip,
        .rightHip,
        .leftKnee,
        .rightKnee,
        .leftAnkle,
        .rightAnkle
    ]

    private static let runtime: Runtime? = {
        for modelName in expectedModelNames {
            guard let url = Bundle.main.url(forResource: modelName, withExtension: "mlmodelc") else {
                continue
            }
            guard let model = try? MLModel(contentsOf: url, configuration: MLModelConfiguration()) else {
                continue
            }

            let inputName = model.modelDescription.inputDescriptionsByName.keys.sorted().first ?? "gru_input"
            let outputName = model.modelDescription.outputDescriptionsByName.keys.sorted().first ?? "Identity"

            if
                let inputConstraint = model.modelDescription.inputDescriptionsByName[inputName]?.multiArrayConstraint,
                let outputConstraint = model.modelDescription.outputDescriptionsByName[outputName]?.multiArrayConstraint {
                let inputShape = inputConstraint.shape.map { Int(truncating: $0) }
                let outputShape = outputConstraint.shape.map { Int(truncating: $0) }
                guard inputShape == [1, sequenceLength, 26], outputShape == [1, 4] else {
                    continue
                }
            }

            return Runtime(
                name: modelName,
                model: model,
                inputName: inputName,
                outputName: outputName
            )
        }

        return nil
    }()

    func recognize(asset: AVAsset, videoTrack: AVAssetTrack) async -> PoseShotRecognitionResult {
        guard let runtime = Self.runtime else {
            return PoseShotRecognitionResult(
                actions: [],
                modelName: nil,
                note: "ShotRecognitionRNN 未加入 App Bundle，继续使用轨迹启发式动作识别。"
            )
        }

        do {
            let windows = try await sampleWindows(from: asset, videoTrack: videoTrack)
            guard !windows.isEmpty else {
                return PoseShotRecognitionResult(
                    actions: [],
                    modelName: runtime.name,
                    note: "未能抽取足够的连续姿态窗口，继续使用轨迹启发式动作识别。"
                )
            }

            var actions: [DetectedAction] = []
            var lastAcceptedFrame = Int.min / 2

            for window in windows {
                var sequenceBuffer: [PoseFeatureSample] = []
                sequenceBuffer.reserveCapacity(window.count)
                var previousSample: PoseFeatureSample?

                for frame in window {
                    let sample = try await extractPoseSample(
                        from: frame.image,
                        frameIndex: frame.frameIndex,
                        previousSample: previousSample
                    )

                    guard let currentSample = sample ?? previousSample?.carryingFrameIndex(frame.frameIndex) else {
                        continue
                    }

                    sequenceBuffer.append(currentSample)
                    previousSample = currentSample

                    guard sequenceBuffer.count >= Self.sequenceLength else { continue }

                    let sequence = Array(sequenceBuffer.suffix(Self.sequenceLength))
                    guard let candidate = try predictAction(for: sequence, runtime: runtime) else {
                        continue
                    }

                    guard candidate.frameIndex - lastAcceptedFrame >= Self.minFramesBetweenShots else {
                        continue
                    }

                    actions.append(candidate)
                    lastAcceptedFrame = candidate.frameIndex
                }
            }

            if actions.isEmpty {
                return PoseShotRecognitionResult(
                    actions: [],
                    modelName: runtime.name,
                    note: "\(runtime.name) 已运行，但姿态分类未达到触发阈值，继续使用轨迹启发式动作识别。"
                )
            }

            let forehandCount = actions.filter { $0.type == .forehand }.count
            let backhandCount = actions.filter { $0.type == .backhand }.count
            let serveCount = actions.filter { $0.type == .serve }.count

            return PoseShotRecognitionResult(
                actions: actions,
                modelName: runtime.name,
                note: "使用 \(runtime.name) + Vision 姿态序列识别动作：正手 \(forehandCount) / 反手 \(backhandCount) / 发球 \(serveCount)。"
            )
        } catch {
            return PoseShotRecognitionResult(
                actions: [],
                modelName: runtime.name,
                note: "\(runtime.name) 运行失败（\(error.localizedDescription)），继续使用轨迹启发式动作识别。"
            )
        }
    }

    private func sampleWindows(
        from asset: AVAsset,
        videoTrack: AVAssetTrack
    ) async throws -> [[SampledFrame]] {
        let duration = try await asset.load(.duration)
        let durationSeconds = max(CMTimeGetSeconds(duration), 0.1)
        let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
        let fps = nominalFrameRate > 0 ? Double(nominalFrameRate) : 30.0
        let frameInterval = 1.0 / fps
        let windowSpan = frameInterval * Double(Self.framesPerWindow - 1)
        let usableDuration = max(durationSeconds - windowSpan, frameInterval)
        let maxFitting = max(
            1,
            Int((durationSeconds - windowSpan) / (windowSpan + frameInterval))
        )
        let windowCount = max(1, min(Self.maxWindows, maxFitting))

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let tolerance = CMTime(seconds: frameInterval * 0.45, preferredTimescale: 6000)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        var windows: [[SampledFrame]] = []
        windows.reserveCapacity(windowCount)

        for windowIndex in 0..<windowCount {
            let ratio = windowCount == 1 ? 0.5 : Double(windowIndex) / Double(windowCount - 1)
            let startSeconds = ratio * usableDuration

            var frames: [SampledFrame] = []
            frames.reserveCapacity(Self.framesPerWindow)

            for frameOffset in 0..<Self.framesPerWindow {
                let seconds = max(
                    0,
                    min(startSeconds + Double(frameOffset) * frameInterval, durationSeconds - 0.001)
                )
                let time = CMTime(seconds: seconds, preferredTimescale: 6000)
                guard let image = try? await generateFrame(generator: generator, at: time) else {
                    continue
                }

                frames.append(
                    SampledFrame(
                        image: image,
                        frameIndex: Int((seconds * fps).rounded())
                    )
                )
            }

            if frames.count >= Self.sequenceLength {
                windows.append(frames)
            }
        }

        return windows
    }

    private func generateFrame(generator: AVAssetImageGenerator, at time: CMTime) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            generator.generateCGImageAsynchronously(for: time) { image, _, error in
                if let image {
                    continuation.resume(returning: image)
                    return
                }
                continuation.resume(throwing: error ?? OnDeviceVideoAnalyzerError.unableToSampleFrames)
            }
        }
    }

    private func extractPoseSample(
        from image: CGImage,
        frameIndex: Int,
        previousSample: PoseFeatureSample?
    ) async throws -> PoseFeatureSample? {
        let request = VNDetectHumanBodyPoseRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        let observations = request.results ?? []
        guard let bestObservation = try bestObservation(from: observations) else {
            return nil
        }

        let bboxWidth = max(bestObservation.maxX - bestObservation.minX, 0.08)
        let bboxHeight = max(bestObservation.maxY - bestObservation.minY, 0.12)

        var features: [Float] = []
        features.reserveCapacity(Self.requiredJoints.count * 2)

        for (index, joint) in Self.requiredJoints.enumerated() {
            if
                let point = bestObservation.points[joint],
                point.confidence >= Self.minJointConfidence {
                let normalizedY = clamp((bestObservation.topLeftY(for: point) - bestObservation.minY) / bboxHeight, min: 0, max: 1)
                let normalizedX = clamp((Double(point.location.x) - bestObservation.minX) / bboxWidth, min: 0, max: 1)
                features.append(Float(normalizedY))
                features.append(Float(normalizedX))
            } else if let previousSample {
                features.append(previousSample.features[index * 2])
                features.append(previousSample.features[index * 2 + 1])
            } else {
                features.append(0.5)
                features.append(0.5)
            }
        }

        var mirrored = features
        for index in stride(from: 1, to: mirrored.count, by: 2) {
            mirrored[index] = Float(clamp(1 - Double(mirrored[index]), min: 0, max: 1))
        }

        let anchorPoint = bestObservation.anchorPoint(in: image)
        return PoseFeatureSample(
            frameIndex: frameIndex,
            x: anchorPoint.x,
            y: anchorPoint.y,
            features: features,
            mirroredFeatures: mirrored
        )
    }

    private func bestObservation(
        from observations: [VNHumanBodyPoseObservation]
    ) throws -> RankedObservation? {
        var best: RankedObservation?

        for observation in observations {
            let points = try observation.recognizedPoints(.all)
            var confidentPoints: [VNRecognizedPoint] = []
            confidentPoints.reserveCapacity(Self.requiredJoints.count)

            for joint in Self.requiredJoints {
                guard let point = points[joint], point.confidence >= Self.minJointConfidence else {
                    continue
                }
                confidentPoints.append(point)
            }

            guard confidentPoints.count >= Self.minJointCount else {
                continue
            }

            let xs = confidentPoints.map { Double($0.location.x) }
            let ys = confidentPoints.map { 1 - Double($0.location.y) }
            guard
                let minX = xs.min(),
                let maxX = xs.max(),
                let minY = ys.min(),
                let maxY = ys.max()
            else {
                continue
            }

            let width = maxX - minX
            let height = maxY - minY
            guard width >= 0.04, height >= 0.10 else {
                continue
            }

            let meanConfidence = confidentPoints.reduce(0) { $0 + Double($1.confidence) } / Double(confidentPoints.count)
            let score = meanConfidence * height * 1.8 + width

            let ranked = RankedObservation(
                points: points,
                minX: minX,
                maxX: maxX,
                minY: minY,
                maxY: maxY,
                score: score
            )

            if let best, best.score >= ranked.score {
                continue
            }
            best = ranked
        }

        return best
    }

    private func predictAction(
        for sequence: [PoseFeatureSample],
        runtime: Runtime
    ) throws -> DetectedAction? {
        let primary = try probabilities(
            for: sequence.map(\.features),
            runtime: runtime
        )
        let mirrored = try probabilities(
            for: sequence.map(\.mirroredFeatures),
            runtime: runtime
        )
        let selected = selectProbabilities(primary: primary, mirrored: mirrored)

        let neutralScore = selected[safe: 2] ?? 0
        var bestType: ActionType?
        var bestScore = 0.0

        for (index, actionType) in Self.poseOutputOrder.enumerated() {
            guard let actionType, index < selected.count else { continue }
            if selected[index] > bestScore {
                bestType = actionType
                bestScore = selected[index]
            }
        }

        guard let bestType else {
            return nil
        }

        let minConfidence = bestType == .serve ? 0.84 : 0.82
        let minMargin = bestType == .serve ? 0.04 : 0.08
        guard bestScore >= minConfidence, bestScore - neutralScore >= minMargin else {
            return nil
        }

        guard let anchor = sequence.last else {
            return nil
        }

        return DetectedAction(
            frameIndex: anchor.frameIndex,
            x: anchor.x,
            y: anchor.y,
            confidence: bestScore,
            type: bestType
        )
    }

    private func probabilities(
        for sequence: [[Float]],
        runtime: Runtime
    ) throws -> [Double] {
        let array = try MLMultiArray(
            shape: [1, Self.sequenceLength, 26].map { NSNumber(value: $0) },
            dataType: .float32
        )

        var offset = 0
        for frame in sequence {
            for value in frame {
                array[offset] = NSNumber(value: value)
                offset += 1
            }
        }

        let provider = try MLDictionaryFeatureProvider(
            dictionary: [runtime.inputName: MLFeatureValue(multiArray: array)]
        )
        let output = try runtime.model.prediction(from: provider)
        guard let multiArray = output.featureValue(for: runtime.outputName)?.multiArrayValue ?? firstMultiArray(from: output) else {
            return []
        }
        return multiArrayDoubles(multiArray)
    }

    private func selectProbabilities(primary: [Double], mirrored: [Double]) -> [Double] {
        func score(_ values: [Double]) -> Double {
            let shotPeak = max(values[safe: 0] ?? 0, max(values[safe: 1] ?? 0, values[safe: 3] ?? 0))
            let neutral = values[safe: 2] ?? 0
            return shotPeak - neutral * 0.35
        }

        return score(mirrored) > score(primary) ? mirrored : primary
    }

    private func firstMultiArray(from provider: MLFeatureProvider) -> MLMultiArray? {
        for name in provider.featureNames.sorted() {
            if let value = provider.featureValue(for: name)?.multiArrayValue {
                return value
            }
        }
        return nil
    }

    private func multiArrayDoubles(_ array: MLMultiArray) -> [Double] {
        (0..<array.count).map { array[$0].doubleValue }
    }

    private func clamp(_ value: Double, min minValue: Double, max maxValue: Double) -> Double {
        Swift.max(minValue, Swift.min(maxValue, value))
    }
}

private struct RankedObservation {
    let points: [VNHumanBodyPoseObservation.JointName: VNRecognizedPoint]
    let minX: Double
    let maxX: Double
    let minY: Double
    let maxY: Double
    let score: Double

    func topLeftY(for point: VNRecognizedPoint) -> Double {
        1 - Double(point.location.y)
    }

    func anchorPoint(in image: CGImage) -> (x: Int, y: Int) {
        let wristCandidates = [
            points[.leftWrist],
            points[.rightWrist]
        ]
        .compactMap { $0 }
        .filter { $0.confidence >= 0.12 }

        let xNorm: Double
        let yNorm: Double
        if !wristCandidates.isEmpty {
            xNorm = wristCandidates.reduce(0) { $0 + Double($1.location.x) } / Double(wristCandidates.count)
            yNorm = wristCandidates.reduce(0) { $0 + (1 - Double($1.location.y)) } / Double(wristCandidates.count)
        } else {
            xNorm = (minX + maxX) * 0.5
            yNorm = (minY + maxY) * 0.5
        }

        return (
            x: Int((xNorm * Double(max(image.width - 1, 1))).rounded()),
            y: Int((yNorm * Double(max(image.height - 1, 1))).rounded())
        )
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}
