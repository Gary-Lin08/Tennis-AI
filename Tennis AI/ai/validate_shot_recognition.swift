#!/usr/bin/env swift

import AVFoundation
import CoreGraphics
import CoreML
import Foundation
import Vision

enum ActionType: String {
    case backhand
    case forehand
    case serve
}

struct PoseSample {
    let frameIndex: Int
    let x: Int
    let y: Int
    let features: [Float]
    let mirroredFeatures: [Float]
}

struct RankedObservation {
    let points: [VNHumanBodyPoseObservation.JointName: VNRecognizedPoint]
    let minX: Double
    let maxX: Double
    let minY: Double
    let maxY: Double
    let score: Double

    func topLeftY(for point: VNRecognizedPoint) -> Double {
        1 - Double(point.location.y)
    }

    func anchorPoint(in image: CGImage) -> (Int, Int) {
        let wrists = [points[.leftWrist], points[.rightWrist]]
            .compactMap { $0 }
            .filter { $0.confidence >= 0.12 }

        let xNorm: Double
        let yNorm: Double
        if wrists.isEmpty {
            xNorm = (minX + maxX) * 0.5
            yNorm = (minY + maxY) * 0.5
        } else {
            xNorm = wrists.reduce(0) { $0 + Double($1.location.x) } / Double(wrists.count)
            yNorm = wrists.reduce(0) { $0 + (1 - Double($1.location.y)) } / Double(wrists.count)
        }

        let x = Int((xNorm * Double(max(image.width - 1, 1))).rounded())
        let y = Int((yNorm * Double(max(image.height - 1, 1))).rounded())
        return (x, y)
    }
}

let requiredJoints: [VNHumanBodyPoseObservation.JointName] = [
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

let poseOutputOrder: [ActionType?] = [.backhand, .forehand, nil, .serve]
let sequenceLength = 30
let framesPerWindow = 60
let maxWindows = 5
let minFramesBetweenShots = 60
let minJointConfidence: Float = 0.18
let minJointCount = 8

func clamp(_ value: Double, min lower: Double, max upper: Double) -> Double {
    Swift.max(lower, Swift.min(upper, value))
}

func bestObservation(from observations: [VNHumanBodyPoseObservation]) throws -> RankedObservation? {
    var best: RankedObservation?

    for observation in observations {
        let points = try observation.recognizedPoints(.all)
        var confidentPoints: [VNRecognizedPoint] = []
        confidentPoints.reserveCapacity(requiredJoints.count)

        for joint in requiredJoints {
            guard let point = points[joint], point.confidence >= minJointConfidence else {
                continue
            }
            confidentPoints.append(point)
        }

        guard confidentPoints.count >= minJointCount else {
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
        let candidate = RankedObservation(points: points, minX: minX, maxX: maxX, minY: minY, maxY: maxY, score: score)

        if let best, best.score >= candidate.score {
            continue
        }
        best = candidate
    }

    return best
}

func extractPoseSample(
    image: CGImage,
    frameIndex: Int,
    previous: PoseSample?
) throws -> PoseSample? {
    let request = VNDetectHumanBodyPoseRequest()
    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    try handler.perform([request])
    guard let observation = try bestObservation(from: request.results ?? []) else {
        return nil
    }

    let bboxWidth = max(observation.maxX - observation.minX, 0.08)
    let bboxHeight = max(observation.maxY - observation.minY, 0.12)
    var features: [Float] = []
    features.reserveCapacity(requiredJoints.count * 2)

    for (index, joint) in requiredJoints.enumerated() {
        if
            let point = observation.points[joint],
            point.confidence >= minJointConfidence {
            let normalizedY = clamp((observation.topLeftY(for: point) - observation.minY) / bboxHeight, min: 0, max: 1)
            let normalizedX = clamp((Double(point.location.x) - observation.minX) / bboxWidth, min: 0, max: 1)
            features.append(Float(normalizedY))
            features.append(Float(normalizedX))
        } else if let previous {
            features.append(previous.features[index * 2])
            features.append(previous.features[index * 2 + 1])
        } else {
            features.append(0.5)
            features.append(0.5)
        }
    }

    var mirrored = features
    for index in stride(from: 1, to: mirrored.count, by: 2) {
        mirrored[index] = Float(clamp(1 - Double(mirrored[index]), min: 0, max: 1))
    }

    let (x, y) = observation.anchorPoint(in: image)
    return PoseSample(frameIndex: frameIndex, x: x, y: y, features: features, mirroredFeatures: mirrored)
}

func probabilities(
    model: MLModel,
    inputName: String,
    outputName: String,
    sequence: [[Float]]
) throws -> [Double] {
    let array = try MLMultiArray(shape: [1, sequenceLength, 26].map { NSNumber(value: $0) }, dataType: .float32)
    var offset = 0
    for frame in sequence {
        for value in frame {
            array[offset] = NSNumber(value: value)
            offset += 1
        }
    }

    let provider = try MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(multiArray: array)])
    let output = try model.prediction(from: provider)
    let multiArray = output.featureValue(for: outputName)?.multiArrayValue
    guard let multiArray else {
        return []
    }
    return (0..<multiArray.count).map { multiArray[$0].doubleValue }
}

func score(_ values: [Double]) -> Double {
    let peak = max(values[safe: 0] ?? 0, max(values[safe: 1] ?? 0, values[safe: 3] ?? 0))
    let neutral = values[safe: 2] ?? 0
    return peak - neutral * 0.35
}

func sampleWindows(asset: AVAsset, fps: Double) throws -> [[(CGImage, Int)]] {
    let durationSeconds = max(CMTimeGetSeconds(asset.duration), 0.1)
    let frameInterval = 1.0 / fps
    let windowSpan = frameInterval * Double(framesPerWindow - 1)
    let usableDuration = max(durationSeconds - windowSpan, frameInterval)
    let maxFitting = max(1, Int((durationSeconds - windowSpan) / (windowSpan + frameInterval)))
    let windowCount = max(1, min(maxWindows, maxFitting))

    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    let tolerance = CMTime(seconds: frameInterval * 0.45, preferredTimescale: 6000)
    generator.requestedTimeToleranceBefore = tolerance
    generator.requestedTimeToleranceAfter = tolerance

    var windows: [[(CGImage, Int)]] = []
    windows.reserveCapacity(windowCount)

    for windowIndex in 0..<windowCount {
        let ratio = windowCount == 1 ? 0.5 : Double(windowIndex) / Double(windowCount - 1)
        let startSeconds = ratio * usableDuration
        var frames: [(CGImage, Int)] = []

        for frameOffset in 0..<framesPerWindow {
            let seconds = max(0, min(startSeconds + Double(frameOffset) * frameInterval, durationSeconds - 0.001))
            let time = CMTime(seconds: seconds, preferredTimescale: 6000)
            guard let image = try? generator.copyCGImage(at: time, actualTime: nil) else {
                continue
            }
            frames.append((image, Int((seconds * fps).rounded())))
        }

        if frames.count >= sequenceLength {
            windows.append(frames)
        }
    }

    return windows
}

func runValidation(videoURL: URL, modelURL: URL) throws {
    let compiledURL = try MLModel.compileModel(at: modelURL)
    let model = try MLModel(contentsOf: compiledURL)
    let inputName = model.modelDescription.inputDescriptionsByName.keys.sorted().first ?? "gru_input"
    let outputName = model.modelDescription.outputDescriptionsByName.keys.sorted().first ?? "Identity"

    let asset = AVURLAsset(url: videoURL)
    guard let track = asset.tracks(withMediaType: .video).first else {
        throw NSError(domain: "ValidateShotRecognition", code: 1, userInfo: [NSLocalizedDescriptionKey: "Video track missing"])
    }

    let fps = track.nominalFrameRate > 0 ? Double(track.nominalFrameRate) : 30.0
    let windows = try sampleWindows(asset: asset, fps: fps)

    var evaluatedSequenceCount = 0
    var acceptedActions: [(ActionType, Int, Double)] = []
    var lastAcceptedFrame = Int.min / 2

    for window in windows {
        var buffer: [PoseSample] = []
        var previous: PoseSample?

        for (image, frameIndex) in window {
            let sample = try extractPoseSample(image: image, frameIndex: frameIndex, previous: previous)
            guard let current = sample ?? previous.map({ PoseSample(frameIndex: frameIndex, x: $0.x, y: $0.y, features: $0.features, mirroredFeatures: $0.mirroredFeatures) }) else {
                continue
            }

            buffer.append(current)
            previous = current

            guard buffer.count >= sequenceLength else {
                continue
            }

            evaluatedSequenceCount += 1
            let sequence = Array(buffer.suffix(sequenceLength))
            let primary = try probabilities(model: model, inputName: inputName, outputName: outputName, sequence: sequence.map(\.features))
            let mirrored = try probabilities(model: model, inputName: inputName, outputName: outputName, sequence: sequence.map(\.mirroredFeatures))
            let chosen = score(mirrored) > score(primary) ? mirrored : primary

            let neutral = chosen[safe: 2] ?? 0
            var bestAction: ActionType?
            var bestScore = 0.0
            for (index, action) in poseOutputOrder.enumerated() {
                guard let action, index < chosen.count else { continue }
                if chosen[index] > bestScore {
                    bestAction = action
                    bestScore = chosen[index]
                }
            }

            guard let bestAction else {
                continue
            }

            let minConfidence = bestAction == .serve ? 0.84 : 0.82
            let minMargin = bestAction == .serve ? 0.04 : 0.08
            guard bestScore >= minConfidence, bestScore - neutral >= minMargin else {
                continue
            }

            guard frameIndex - lastAcceptedFrame >= minFramesBetweenShots else {
                continue
            }

            acceptedActions.append((bestAction, frameIndex, bestScore))
            lastAcceptedFrame = frameIndex
        }
    }

    let counts = Dictionary(grouping: acceptedActions, by: { $0.0 }).mapValues(\.count)
    print("video=\(videoURL.path)")
    print("model=\(modelURL.path)")
    print("input=\(inputName)")
    print("output=\(outputName)")
    print("windows=\(windows.count)")
    print("evaluated_sequences=\(evaluatedSequenceCount)")
    print("accepted_actions=\(acceptedActions.count)")
    print("forehand=\(counts[.forehand] ?? 0)")
    print("backhand=\(counts[.backhand] ?? 0)")
    print("serve=\(counts[.serve] ?? 0)")
    for (action, frame, confidence) in acceptedActions.prefix(12) {
        print("action \(action.rawValue) frame=\(frame) confidence=\(String(format: "%.3f", confidence))")
    }
}

let arguments = CommandLine.arguments
let workspaceRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let defaultVideoURL = workspaceRoot.appendingPathComponent(
    "Tennis AI/GridTrackNet/Sample Video's/Professional Hardcourt.mp4"
)
let defaultModelURL = workspaceRoot.appendingPathComponent("Tennis AI/Tennis AI/ShotRecognitionRNN.mlpackage")

let videoURL = arguments.count > 1 ? URL(fileURLWithPath: arguments[1]) : defaultVideoURL
let modelURL = arguments.count > 2 ? URL(fileURLWithPath: arguments[2]) : defaultModelURL

do {
    try runValidation(videoURL: videoURL, modelURL: modelURL)
} catch {
    fputs("ERROR: \(error.localizedDescription)\n", stderr)
    exit(1)
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}
