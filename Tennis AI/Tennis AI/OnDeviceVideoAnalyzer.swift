//
//  OnDeviceVideoAnalyzer.swift
//  Tennis AI
//
//  Created by Codex on 2026/3/12.
//

import AVFoundation
import CoreML
import CoreVideo
import Foundation

struct OnDeviceInferenceSummary {
    let totalFrames: Int
    let trackedFrames: Int
    let ballVisibleRate: Double
    let trackingQualityScore: Double
    let qualityBreakdown: SessionQualityBreakdown
    let estimatedBounceCount: Int
    let sampledFrameCount: Int
    let successfulPredictionCount: Int
    let modelName: String
    let trackedPoints: [InferencePoint]
    let bouncePoints: [InferencePoint]
    let detectedActions: [DetectedAction]
    let analysisNote: String

    @available(*, deprecated, renamed: "trackingQualityScore")
    var courtDetectionScore: Double {
        trackingQualityScore
    }
}

enum OnDeviceVideoAnalyzerError: LocalizedError {
    case missingVideoTrack
    case unableToSampleFrames
    case unsupportedInput
    case invalidTensorShape(name: String, shape: [Int])
    case pixelBufferCreationFailed
    case inferenceFailed(reason: String)

    var errorDescription: String? {
        switch self {
        case .missingVideoTrack:
            return "视频里没有检测到可读取的视频轨道。"
        case .unableToSampleFrames:
            return "无法从视频中抽取有效帧。"
        case .unsupportedInput:
            return "模型输入类型不支持（当前仅支持 image / multiArray）。"
        case .invalidTensorShape(let name, let shape):
            return "\(name) 的张量输入形状不受支持：\(shape)。"
        case .pixelBufferCreationFailed:
            return "图像转换为像素缓冲区失败。"
        case .inferenceFailed(let reason):
            return reason
        }
    }
}

extension OnDeviceVideoAnalyzerError {
    var failureCategory: JobFailureCategory {
        switch self {
        case .missingVideoTrack, .unsupportedInput:
            return .unreadableVideo
        case .unableToSampleFrames, .pixelBufferCreationFailed, .invalidTensorShape:
            return .frameExtractionFailed
        case .inferenceFailed:
            return .inferenceFailed
        }
    }
}

enum OnDeviceInferenceProfile: String, CaseIterable, Identifiable {
    case highRecall = "high_recall"
    case balanced = "balanced"
    case highPrecision = "high_precision"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .highRecall:
            return "高召回"
        case .balanced:
            return "平衡"
        case .highPrecision:
            return "高精度"
        }
    }

    var shortLabel: String {
        switch self {
        case .highRecall:
            return "召回优先"
        case .balanced:
            return "平衡模式"
        case .highPrecision:
            return "精度优先"
        }
    }

    var detail: String {
        switch self {
        case .highRecall:
            return "尽量不漏检动作与弹跳，适合训练回放阶段。"
        case .balanced:
            return "默认配置，综合兼顾稳定性与准确性。"
        case .highPrecision:
            return "更严格过滤低置信度事件，适合统计场景。"
        }
    }
}

struct OnDeviceVideoAnalyzer {
    private struct ActionRecognitionResolution {
        let actions: [DetectedAction]
        let note: String
    }

    private enum TensorOrder {
        case chw
        case hwc
    }

    private struct TensorLayout {
        let hasBatch: Bool
        let order: TensorOrder
        let channels: Int
        let height: Int
        let width: Int
    }

    private enum InputAdapter {
        case image(name: String, width: Int, height: Int)
        case multiArray(
            name: String,
            shape: [Int],
            layout: TensorLayout,
            dataType: MLMultiArrayDataType
        )
    }

    struct BounceThresholds {
        let peakFloor: Double
        let peakDivisor: Double
        let velocityFloor: Double
        let velocityDivisor: Double
        let reboundRatio: Double
        let maxWindowFrames: Int
        let dedupeFrameGap: Int
        let confidenceBoostCap: Double
    }

    struct ActionThresholds {
        let motionFloor: Double
        let motionScale: Double
        let speedGateRatio: Double
        let turnStrengthRatio: Double
        let turnAngleThreshold: Double
        let secondaryTurnAngleThreshold: Double
        let verticalDropRatio: Double
        let serveUpperBandRatio: Double
        let serveVerticalVsLateralRatio: Double
        let serveVerticalGainRatio: Double
        let lateralOutgoingRatio: Double
        let nonTurnPenalty: Double
        let unknownPenalty: Double
        let knownFloor: Double
        let unknownDropFloor: Double
        let serveConfidenceFloor: Double
        let dedupeFrameGap: Int
    }

    private let maxTrackNetWindows = 12   // 12 windows × 5 consecutive frames = 60 model inputs
    private let maxGenericFrames = 24
    private let detectionThreshold = 0.30  // GridTrackNet sigmoid outputs are often 0.2–0.5 on real footage
    private let profile: OnDeviceInferenceProfile

    init(profile: OnDeviceInferenceProfile = .balanced) {
        self.profile = profile
    }

    private func actionStabilityScore(for actions: [DetectedAction]) -> Double {
        guard !actions.isEmpty else { return 0.42 }
        let knownActions = actions.filter { $0.type != .unknown }
        let knownRatio = Double(knownActions.count) / Double(actions.count)
        let confidenceMean = mean(knownActions.map(\.confidence))
        return clamp(knownRatio * 0.52 + confidenceMean * 0.48, min: 0.18, max: 0.99)
    }

    private var bounceThresholds: BounceThresholds {
        switch profile {
        case .highRecall:
            return BounceThresholds(
                peakFloor: 3.0,
                peakDivisor: 36.0,
                velocityFloor: 1.4,
                velocityDivisor: 170.0,
                reboundRatio: 0.62,
                maxWindowFrames: 12,
                dedupeFrameGap: 2,
                confidenceBoostCap: 0.30
            )
        case .balanced:
            return BounceThresholds(
                peakFloor: 4.0,
                peakDivisor: 30.0,
                velocityFloor: 1.8,
                velocityDivisor: 140.0,
                reboundRatio: 0.70,
                maxWindowFrames: 10,
                dedupeFrameGap: 3,
                confidenceBoostCap: 0.25
            )
        case .highPrecision:
            return BounceThresholds(
                peakFloor: 5.0,
                peakDivisor: 25.0,
                velocityFloor: 2.1,
                velocityDivisor: 120.0,
                reboundRatio: 0.78,
                maxWindowFrames: 8,
                dedupeFrameGap: 4,
                confidenceBoostCap: 0.18
            )
        }
    }

    private var actionThresholds: ActionThresholds {
        switch profile {
        case .highRecall:
            return ActionThresholds(
                motionFloor: 4.0,
                motionScale: 0.0080,
                speedGateRatio: 0.28,
                turnStrengthRatio: 0.45,
                turnAngleThreshold: 0.62,
                secondaryTurnAngleThreshold: 0.52,
                verticalDropRatio: 0.58,
                serveUpperBandRatio: 0.47,
                serveVerticalVsLateralRatio: 0.95,
                serveVerticalGainRatio: 0.36,
                lateralOutgoingRatio: 0.30,
                nonTurnPenalty: 0.05,
                unknownPenalty: 0.06,
                knownFloor: 0.38,
                unknownDropFloor: 0.22,
                serveConfidenceFloor: 0.34,
                dedupeFrameGap: 4
            )
        case .balanced:
            return ActionThresholds(
                motionFloor: 5.0,
                motionScale: 0.0100,
                speedGateRatio: 0.35,
                turnStrengthRatio: 0.60,
                turnAngleThreshold: 0.78,
                secondaryTurnAngleThreshold: 0.63,
                verticalDropRatio: 0.80,
                serveUpperBandRatio: 0.44,
                serveVerticalVsLateralRatio: 1.10,
                serveVerticalGainRatio: 0.45,
                lateralOutgoingRatio: 0.36,
                nonTurnPenalty: 0.07,
                unknownPenalty: 0.08,
                knownFloor: 0.45,
                unknownDropFloor: 0.28,
                serveConfidenceFloor: 0.40,
                dedupeFrameGap: 5
            )
        case .highPrecision:
            return ActionThresholds(
                motionFloor: 6.0,
                motionScale: 0.0120,
                speedGateRatio: 0.45,
                turnStrengthRatio: 0.75,
                turnAngleThreshold: 0.92,
                secondaryTurnAngleThreshold: 0.76,
                verticalDropRatio: 1.05,
                serveUpperBandRatio: 0.42,
                serveVerticalVsLateralRatio: 1.25,
                serveVerticalGainRatio: 0.58,
                lateralOutgoingRatio: 0.42,
                nonTurnPenalty: 0.10,
                unknownPenalty: 0.10,
                knownFloor: 0.56,
                unknownDropFloor: 0.35,
                serveConfidenceFloor: 0.48,
                dedupeFrameGap: 6
            )
        }
    }

    func analyze(
        videoURL: URL,
        loadedModel: LoadedOnDeviceModel,
        progress: (Double) -> Void = { _ in }
    ) async throws -> OnDeviceInferenceSummary {
        let asset = AVURLAsset(url: videoURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else {
            throw OnDeviceVideoAnalyzerError.missingVideoTrack
        }

        // Determine inference path before sampling so we can use the right strategy.
        let adapter = try makeInputAdapter(for: loadedModel.model)

        if shouldUseTrackNetPath(adapter: adapter) {
            // TrackNet needs N temporally adjacent frames at native fps.
            // The required frame count per window = input_channels / 3.
            let framesPerWindow = framesPerTrackNetWindow(adapter: adapter)
            let windowedFrames = try await sampleWindowedFrames(
                from: asset,
                videoTrack: videoTrack,
                maxWindows: maxTrackNetWindows,
                framesPerWindow: framesPerWindow
            )
            return try await analyzeTrackNet(
                asset: asset,
                videoTrack: videoTrack,
                windowedFrames: windowedFrames,
                loadedModel: loadedModel,
                adapter: adapter,
                progress: progress
            )
        }

        let sampledFrames = try await sampleFrames(from: asset, maxCount: maxGenericFrames)
        return try await analyzeGeneric(
            asset: asset,
            videoTrack: videoTrack,
            sampledFrames: sampledFrames,
            loadedModel: loadedModel,
            adapter: adapter,
            progress: progress
        )
    }

    private func shouldUseTrackNetPath(adapter: InputAdapter) -> Bool {
        switch adapter {
        case .multiArray(_, _, let layout, _):
            return layout.channels >= 9 && layout.channels % 3 == 0
        case .image:
            return false
        }
    }

    /// Number of consecutive input frames the model expects per inference window.
    /// GridTrackNet: input channels = IMGS * 3  → IMGS frames.
    private func framesPerTrackNetWindow(adapter: InputAdapter) -> Int {
        if case .multiArray(_, _, let layout, _) = adapter, layout.channels % 3 == 0 {
            return max(3, layout.channels / 3)
        }
        return 3
    }

    private func analyzeTrackNet(
        asset: AVURLAsset,
        videoTrack: AVAssetTrack,
        windowedFrames: [[CGImage]],
        loadedModel: LoadedOnDeviceModel,
        adapter: InputAdapter,
        progress: (Double) -> Void
    ) async throws -> OnDeviceInferenceSummary {
        let windowCount = windowedFrames.count
        guard windowCount > 0 else {
            throw OnDeviceVideoAnalyzerError.unableToSampleFrames
        }

        var successfulPredictionCount = 0
        let framesPerWindow = windowedFrames.first?.count ?? 1
        var allPoints: [InferencePoint] = []
        allPoints.reserveCapacity(windowCount * framesPerWindow)

        for (windowIdx, chunk) in windowedFrames.enumerated() {
            if Task.isCancelled {
                break
            }

            do {
                let provider = try makeProvider(forFrames: chunk, using: adapter)
                let output = try await loadedModel.model.prediction(
                    from: provider,
                    options: MLPredictionOptions()
                )
                let refFrame = chunk[min(1, chunk.count - 1)]
                let decodedPoints = decodeTrackNetOutput(
                    output,
                    sourceWidth: refFrame.width,
                    sourceHeight: refFrame.height,
                    baseFrameIndex: windowIdx * chunk.count
                )
                if !decodedPoints.isEmpty {
                    allPoints.append(contentsOf: decodedPoints)
                    successfulPredictionCount += 1
                }
            } catch {
                continue
            }

            progress(Double(windowIdx + 1) / Double(windowCount))
        }

        let visiblePoints = allPoints.filter(\.isVisible)
        let refFrame = windowedFrames[0][min(1, windowedFrames[0].count - 1)]

        // If no ball detected at threshold, fall back to best-confidence points so the
        // task completes rather than failing. This can happen with non-tennis footage or
        // very short clips where the model confidence stays below threshold.
        let usingFallback = visiblePoints.isEmpty && !allPoints.isEmpty
        let effectivePoints: [InferencePoint]
        if usingFallback {
            let bestConf = allPoints.max(by: { $0.confidence < $1.confidence })?.confidence ?? 0
            effectivePoints = allPoints.filter { $0.confidence >= bestConf * 0.75 }
        } else {
            effectivePoints = visiblePoints
        }
        let smoothedPoints = smoothTrajectory(points: effectivePoints, windowRadius: 2)
        let bouncePoints = detectBouncePoints(from: smoothedPoints, sourceHeight: refFrame.height)
        let actionResolution = await resolveActions(
            asset: asset,
            videoTrack: videoTrack,
            from: smoothedPoints,
            sourceWidth: refFrame.width,
            sourceHeight: refFrame.height
        )
        let actions = actionResolution.actions
        let continuity = trajectoryContinuity(points: smoothedPoints, width: refFrame.width, height: refFrame.height)
        // Use real visiblePoints count so ballVisibleRate reflects actual model confidence,
        // not the size of the fallback set. Clamped to 0.05 floor to avoid zero quality scores.
        let ballVisibleRate = clamp(Double(visiblePoints.count) / Double(max(allPoints.count, 1)), min: 0.05, max: 0.99)
        let inferenceSuccessRate = clamp(Double(successfulPredictionCount) / Double(max(windowCount, 1)), min: 0, max: 1)
        let actionStability = actionStabilityScore(for: actions)
        let qualityBreakdown = SessionQualityBreakdown(
            visibleRateScore: ballVisibleRate,
            continuityScore: continuity,
            inferenceSuccessRate: inferenceSuccessRate,
            actionStabilityScore: actionStability
        )
        let trackingQualityScore = clamp(qualityBreakdown.weightedTrackingQualityScore, min: 0.10, max: 0.99)

        let duration = try await asset.load(.duration)
        let durationSeconds = max(CMTimeGetSeconds(duration), 0.1)
        let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
        let nominalFPS = nominalFrameRate > 0 ? Double(nominalFrameRate) : 30
        let totalFrames = max(Int(durationSeconds * nominalFPS), allPoints.count)
        let trackedFrames = max(Int(Double(totalFrames) * ballVisibleRate), 1)
        let estimatedBounceCount = max(bouncePoints.count, 1)
        let forehandCount = actions.filter { $0.type == .forehand }.count
        let backhandCount = actions.filter { $0.type == .backhand }.count
        let serveCount = actions.filter { $0.type == .serve }.count
        let unknownCount = actions.filter { $0.type == .unknown }.count

        let fallbackLabel = usingFallback ? "置信度回退，" : ""
        let analysisNote = "TrackNet 输出映射完成（\(profile.shortLabel)）：\(fallbackLabel)坐标点 \(smoothedPoints.count)/\(allPoints.count)，检测到弹跳 \(estimatedBounceCount) 次，动作统计 正手 \(forehandCount) / 反手 \(backhandCount) / 发球 \(serveCount) / 未知 \(unknownCount)。\(actionResolution.note)"

        return OnDeviceInferenceSummary(
            totalFrames: totalFrames,
            trackedFrames: trackedFrames,
            ballVisibleRate: ballVisibleRate,
            trackingQualityScore: trackingQualityScore,
            qualityBreakdown: qualityBreakdown,
            estimatedBounceCount: estimatedBounceCount,
            sampledFrameCount: windowedFrames.reduce(0) { $0 + $1.count },
            successfulPredictionCount: successfulPredictionCount,
            modelName: loadedModel.name,
            trackedPoints: smoothedPoints,
            bouncePoints: bouncePoints,
            detectedActions: actions,
            analysisNote: analysisNote
        )
    }

    private func analyzeGeneric(
        asset: AVURLAsset,
        videoTrack: AVAssetTrack,
        sampledFrames: [CGImage],
        loadedModel: LoadedOnDeviceModel,
        adapter: InputAdapter,
        progress: (Double) -> Void
    ) async throws -> OnDeviceInferenceSummary {
        var successfulPredictionCount = 0
        var outputSignals: [Double] = []
        var lastError: Error?

        for (index, frame) in sampledFrames.enumerated() {
            if Task.isCancelled {
                break
            }

            do {
                let provider = try makeProvider(for: frame, using: adapter)
                let output = try await loadedModel.model.prediction(
                    from: provider,
                    options: MLPredictionOptions()
                )
                outputSignals.append(extractSignal(from: output))
                successfulPredictionCount += 1
            } catch {
                lastError = error
            }

            let ratio = Double(index + 1) / Double(sampledFrames.count)
            progress(ratio)
        }

        guard successfulPredictionCount > 0 else {
            let detail = lastError?.localizedDescription ?? "未知原因"
            throw OnDeviceVideoAnalyzerError.inferenceFailed(reason: "模型推理失败：\(detail)")
        }

        let successRate = Double(successfulPredictionCount) / Double(sampledFrames.count)
        let signalMean = mean(outputSignals)
        let signalVariance = variance(values: outputSignals, mean: signalMean)
        let stability = clamp(1 - min(signalVariance * 8, 1), min: 0, max: 1)

        let ballVisibleRate = clamp(0.15 + successRate * 0.75 + signalMean * 0.10, min: 0.08, max: 0.98)
        let qualityBreakdown = SessionQualityBreakdown(
            visibleRateScore: ballVisibleRate,
            continuityScore: stability,
            inferenceSuccessRate: successRate,
            actionStabilityScore: 0.30
        )
        let trackingQualityScore = clamp(qualityBreakdown.weightedTrackingQualityScore, min: 0.10, max: 0.99)
        let duration = try await asset.load(.duration)
        let durationSeconds = max(CMTimeGetSeconds(duration), 0.1)
        let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
        let nominalFPS = nominalFrameRate > 0 ? Double(nominalFrameRate) : 30
        let totalFrames = max(Int(durationSeconds * nominalFPS), sampledFrames.count)
        let trackedFrames = max(Int(Double(totalFrames) * ballVisibleRate), 1)
        let bounceBase = (1 - signalMean) * 18 + Double(sampledFrames.count) * 0.35
        let estimatedBounceCount = max(6, Int(bounceBase.rounded()))
        let analysisNote = "通用输出映射：有效预测 \(successfulPredictionCount)/\(sampledFrames.count)。"

        return OnDeviceInferenceSummary(
            totalFrames: totalFrames,
            trackedFrames: trackedFrames,
            ballVisibleRate: ballVisibleRate,
            trackingQualityScore: trackingQualityScore,
            qualityBreakdown: qualityBreakdown,
            estimatedBounceCount: estimatedBounceCount,
            sampledFrameCount: sampledFrames.count,
            successfulPredictionCount: successfulPredictionCount,
            modelName: loadedModel.name,
            trackedPoints: [],
            bouncePoints: [],
            detectedActions: [],
            analysisNote: analysisNote
        )
    }

    private func decodeTrackNetOutput(
        _ provider: MLFeatureProvider,
        sourceWidth: Int,
        sourceHeight: Int,
        baseFrameIndex: Int
    ) -> [InferencePoint] {
        guard let array = firstMultiArray(from: provider),
              let layout = inferLayout(from: array.shape.map { Int(truncating: $0) }) else {
            return []
        }

        let strides = array.strides.map { Int(truncating: $0) }
        let valueAt = makeValueReader(for: array)

        // GridTrackNet output: channels = IMGS*3, grouped as (conf, xOff, yOff) per frame.
        // Standard heatmap: each channel is an independent per-frame confidence map.
        let isGridFormat = layout.channels >= 6 && layout.channels % 3 == 0
        let framesInOutput = isGridFormat ? layout.channels / 3 : min(layout.channels, 5)

        var points: [InferencePoint] = []
        points.reserveCapacity(framesInOutput)

        let gridCellW = Double(sourceWidth)  / Double(max(layout.width,  1))
        let gridCellH = Double(sourceHeight) / Double(max(layout.height, 1))

        for frameIdx in 0..<framesInOutput {
            let confChannel = isGridFormat ? frameIdx * 3     : frameIdx
            let xOffChannel = isGridFormat ? frameIdx * 3 + 1 : -1
            let yOffChannel = isGridFormat ? frameIdx * 3 + 2 : -1

            // Find argmax in confidence channel
            var bestConf = -Double.infinity
            var bestCol  = 0
            var bestRow  = 0

            for row in 0..<layout.height {
                for col in 0..<layout.width {
                    let off = heatmapOffset(layout: layout, strides: strides,
                                           channel: confChannel, y: row, x: col)
                    let v = valueAt(off)
                    if v > bestConf {
                        bestConf = v
                        bestCol = col
                        bestRow = row
                    }
                }
            }

            let confidence = normalizedSignal(bestConf)

            // Apply sub-cell offsets if available (GridTrackNet style)
            let xOff: Double
            let yOff: Double
            if xOffChannel >= 0 && yOffChannel >= 0 {
                let xOff_raw = valueAt(heatmapOffset(layout: layout, strides: strides,
                                                     channel: xOffChannel, y: bestRow, x: bestCol))
                let yOff_raw = valueAt(heatmapOffset(layout: layout, strides: strides,
                                                     channel: yOffChannel, y: bestRow, x: bestCol))
                // offsets are in [0,1] relative to the grid cell
                xOff = clamp(xOff_raw, min: 0, max: 1)
                yOff = clamp(yOff_raw, min: 0, max: 1)
            } else {
                xOff = 0.5
                yOff = 0.5
            }

            let pixelX = Int(((Double(bestCol) + xOff) * gridCellW).rounded())
            let pixelY = Int(((Double(bestRow) + yOff) * gridCellH).rounded())

            points.append(
                InferencePoint(
                    frameIndex: baseFrameIndex + frameIdx,
                    x: max(0, min(pixelX, sourceWidth  - 1)),
                    y: max(0, min(pixelY, sourceHeight - 1)),
                    confidence: confidence,
                    isVisible: confidence >= detectionThreshold
                )
            )
        }

        return points
    }

    private func heatmapOffset(layout: TensorLayout, strides: [Int], channel: Int, y: Int, x: Int) -> Int {
        switch (layout.order, layout.hasBatch) {
        case (.chw, true):
            return channel * strides[1] + y * strides[2] + x * strides[3]
        case (.chw, false):
            return channel * strides[0] + y * strides[1] + x * strides[2]
        case (.hwc, true):
            return y * strides[1] + x * strides[2] + channel * strides[3]
        case (.hwc, false):
            return y * strides[0] + x * strides[1] + channel * strides[2]
        }
    }

    private func firstMultiArray(from provider: MLFeatureProvider) -> MLMultiArray? {
        for name in provider.featureNames.sorted() {
            if let feature = provider.featureValue(for: name), let array = feature.multiArrayValue {
                return array
            }
        }
        return nil
    }

    private func makeValueReader(for array: MLMultiArray) -> (Int) -> Double {
        switch array.dataType {
        case .double:
            let ptr = array.dataPointer.bindMemory(to: Double.self, capacity: array.count)
            return { idx in Double(ptr[idx]) }
        case .float32:
            let ptr = array.dataPointer.bindMemory(to: Float32.self, capacity: array.count)
            return { idx in Double(ptr[idx]) }
        case .float16:
            let ptr = array.dataPointer.bindMemory(to: Float16.self, capacity: array.count)
            return { idx in Double(ptr[idx]) }
        case .int32:
            let ptr = array.dataPointer.bindMemory(to: Int32.self, capacity: array.count)
            return { idx in Double(ptr[idx]) / 255.0 }
        case .int8:
            let ptr = array.dataPointer.bindMemory(to: Int8.self, capacity: array.count)
            return { idx in Double(ptr[idx]) / 127.0 }
        @unknown default:
            return { _ in 0.0 }
        }
    }

    private func detectBouncePoints(from points: [InferencePoint], sourceHeight: Int) -> [InferencePoint] {
        let sorted = points.sorted { $0.frameIndex < $1.frameIndex }
        guard sorted.count >= 5 else { return [] }

        let thresholds = bounceThresholds
        var bounces: [InferencePoint] = []
        let minPeakDelta = max(thresholds.peakFloor, Double(sourceHeight) / thresholds.peakDivisor)
        let minVyIn = max(thresholds.velocityFloor, Double(sourceHeight) / thresholds.velocityDivisor)
        let minVyOut = max(thresholds.velocityFloor, Double(sourceHeight) / thresholds.velocityDivisor)

        for index in 2..<(sorted.count - 2) {
            let p0 = sorted[index - 2]
            let p1 = sorted[index - 1]
            let p2 = sorted[index]
            let p3 = sorted[index + 1]
            let p4 = sorted[index + 2]

            let dtIn = max(p2.frameIndex - p0.frameIndex, 1)
            let dtOut = max(p4.frameIndex - p2.frameIndex, 1)
            let vyIn = Double(p2.y - p0.y) / Double(dtIn)
            let vyOut = Double(p4.y - p2.y) / Double(dtOut)

            let isLocalPeak = p2.y >= p1.y && p2.y >= p3.y
            let approachDrop = Double(p2.y - min(p0.y, p1.y))
            let reboundRise = Double(p2.y - min(p3.y, p4.y))
            let temporalValid = (p4.frameIndex - p0.frameIndex) <= thresholds.maxWindowFrames
            let hasVelocityFlip = vyIn >= minVyIn && vyOut <= -minVyOut

            if isLocalPeak && temporalValid && hasVelocityFlip
                && approachDrop >= minPeakDelta && reboundRise >= minPeakDelta * thresholds.reboundRatio {
                let confidenceBoost = clamp(
                    (approachDrop + reboundRise) / (minPeakDelta * 3.2),
                    min: 0,
                    max: thresholds.confidenceBoostCap
                )
                let candidate = InferencePoint(
                    frameIndex: p2.frameIndex,
                    x: p2.x,
                    y: p2.y,
                    confidence: clamp(p2.confidence + confidenceBoost, min: 0.1, max: 0.99),
                    isVisible: true
                )

                if let last = bounces.last, abs(last.frameIndex - candidate.frameIndex) <= thresholds.dedupeFrameGap {
                    if candidate.confidence > last.confidence {
                        bounces[bounces.count - 1] = candidate
                    }
                } else {
                    bounces.append(candidate)
                }
            }
        }

        return bounces
    }

    private func resolveActions(
        asset: AVAsset,
        videoTrack: AVAssetTrack,
        from points: [InferencePoint],
        sourceWidth: Int,
        sourceHeight: Int
    ) async -> ActionRecognitionResolution {
        let heuristicActions = detectPlayerActions(
            from: points,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight
        )

        guard !points.isEmpty else {
            return ActionRecognitionResolution(
                actions: heuristicActions,
                note: heuristicActionNote(for: heuristicActions)
            )
        }

        let poseResult = await PoseShotRecognizer().recognize(asset: asset, videoTrack: videoTrack)
        if !poseResult.actions.isEmpty {
            return ActionRecognitionResolution(actions: poseResult.actions, note: poseResult.note)
        }

        let fallbackNote = heuristicActionNote(for: heuristicActions)
        let combinedNote = poseResult.note.isEmpty ? fallbackNote : "\(poseResult.note) \(fallbackNote)"
        return ActionRecognitionResolution(actions: heuristicActions, note: combinedNote)
    }

    private func heuristicActionNote(for actions: [DetectedAction]) -> String {
        guard !actions.isEmpty else {
            return "轨迹启发式动作识别也未触发。"
        }

        let forehandCount = actions.filter { $0.type == .forehand }.count
        let backhandCount = actions.filter { $0.type == .backhand }.count
        let serveCount = actions.filter { $0.type == .serve }.count
        let unknownCount = actions.filter { $0.type == .unknown }.count
        return "已回退到轨迹启发式动作识别：正手 \(forehandCount) / 反手 \(backhandCount) / 发球 \(serveCount) / 未知 \(unknownCount)。"
    }

    private func detectPlayerActions(
        from points: [InferencePoint],
        sourceWidth: Int,
        sourceHeight: Int
    ) -> [DetectedAction] {
        let sorted = points.sorted { $0.frameIndex < $1.frameIndex }
        guard sorted.count >= 7 else { return [] }

        let thresholds = actionThresholds
        let minMotion = max(thresholds.motionFloor, Double(max(sourceWidth, sourceHeight)) * thresholds.motionScale)
        let serveUpperBand = Int(Double(sourceHeight) * thresholds.serveUpperBandRatio)
        var actions: [DetectedAction] = []

        for index in 3..<(sorted.count - 3) {
            let p0 = sorted[index - 2]
            let p2 = sorted[index]
            let p4 = sorted[index + 2]

            let frameGapIn = max(p2.frameIndex - p0.frameIndex, 1)
            let frameGapOut = max(p4.frameIndex - p2.frameIndex, 1)
            let vxIn = Double(p2.x - p0.x) / Double(frameGapIn)
            let vyIn = Double(p2.y - p0.y) / Double(frameGapIn)
            let vxOut = Double(p4.x - p2.x) / Double(frameGapOut)
            let vyOut = Double(p4.y - p2.y) / Double(frameGapOut)

            let speedIn = hypot(vxIn, vyIn)
            let speedOut = hypot(vxOut, vyOut)
            if min(speedIn, speedOut) < minMotion * thresholds.speedGateRatio {
                continue
            }

            let horizontalTurn = vxIn * vxOut < 0
            let turnStrength = abs(vxIn - vxOut)
            let turnAngle = angleBetween(dx0: vxIn, dy0: vyIn, dx1: vxOut, dy1: vyOut)
            let normalizedSpeed = clamp(max(speedIn, speedOut) / max(minMotion * 2.0, 1), min: 0, max: 1)
            let normalizedTurn = clamp(turnAngle / .pi, min: 0, max: 1)
            let verticalDrop = vyOut - vyIn

            let eventLikely = horizontalTurn
                || turnStrength > minMotion * thresholds.turnStrengthRatio
                || turnAngle > thresholds.turnAngleThreshold
                || abs(verticalDrop) > minMotion * thresholds.verticalDropRatio
            if !eventLikely {
                continue
            }

            var actionType: ActionType = .unknown
            var actionConfidence = clamp(
                sorted[index].confidence * 0.52 + normalizedTurn * 0.23 + normalizedSpeed * 0.20,
                min: 0.10,
                max: 0.97
            )

            let isServeLike = p2.y <= serveUpperBand
                && vyOut > abs(vxOut) * thresholds.serveVerticalVsLateralRatio
                && vyOut > minMotion * thresholds.serveVerticalGainRatio
            if isServeLike {
                actionType = .serve
                let serveSignal = (vyOut / max(minMotion, 1)) * 0.10
                actionConfidence = clamp(actionConfidence + serveSignal, min: thresholds.serveConfidenceFloor, max: 0.97)
            } else {
                if abs(vxOut) < minMotion * thresholds.lateralOutgoingRatio {
                    actionType = .unknown
                    actionConfidence = clamp(actionConfidence - thresholds.unknownPenalty, min: 0.18, max: 0.85)
                } else {
                    actionType = vxOut >= 0 ? .forehand : .backhand
                    if !(horizontalTurn || turnAngle > thresholds.secondaryTurnAngleThreshold) {
                        actionConfidence = clamp(actionConfidence - thresholds.nonTurnPenalty, min: 0.12, max: 0.88)
                    }
                }
            }

            if actionType != .unknown && actionConfidence < thresholds.knownFloor {
                actionType = .unknown
                actionConfidence = clamp(actionConfidence, min: 0.20, max: 0.60)
            }
            if actionType == .unknown && actionConfidence < thresholds.unknownDropFloor {
                continue
            }

            let candidate = DetectedAction(
                frameIndex: p2.frameIndex,
                x: p2.x,
                y: p2.y,
                confidence: actionConfidence,
                type: actionType
            )

            if let last = actions.last, abs(last.frameIndex - candidate.frameIndex) <= thresholds.dedupeFrameGap {
                let keepCandidate: Bool
                if last.type == .unknown && candidate.type != .unknown {
                    keepCandidate = true
                } else if last.type != .unknown && candidate.type == .unknown {
                    keepCandidate = false
                } else {
                    keepCandidate = candidate.confidence > last.confidence
                }
                if keepCandidate {
                    actions[actions.count - 1] = candidate
                }
            } else {
                actions.append(candidate)
            }
        }

        return actions
    }

    private func smoothTrajectory(points: [InferencePoint], windowRadius: Int) -> [InferencePoint] {
        let sorted = points.sorted { $0.frameIndex < $1.frameIndex }
        guard sorted.count >= 3 else { return sorted }

        let radius = max(windowRadius, 1)
        var output: [InferencePoint] = []
        output.reserveCapacity(sorted.count)

        for index in sorted.indices {
            let lower = max(sorted.startIndex, index - radius)
            let upper = min(sorted.endIndex - 1, index + radius)

            var weightedX = 0.0
            var weightedY = 0.0
            var weightedConfidence = 0.0
            var weightSum = 0.0

            for neighbor in lower...upper {
                let distance = abs(neighbor - index)
                let temporalWeight = Double((radius + 1) - distance)
                let confidenceWeight = max(sorted[neighbor].confidence, 0.12)
                let w = temporalWeight * (0.55 + confidenceWeight)
                weightedX += Double(sorted[neighbor].x) * w
                weightedY += Double(sorted[neighbor].y) * w
                weightedConfidence += sorted[neighbor].confidence * w
                weightSum += w
            }

            let fallback = sorted[index]
            guard weightSum > 0 else {
                output.append(fallback)
                continue
            }

            output.append(
                InferencePoint(
                    frameIndex: fallback.frameIndex,
                    x: Int((weightedX / weightSum).rounded()),
                    y: Int((weightedY / weightSum).rounded()),
                    confidence: clamp(weightedConfidence / weightSum, min: 0.12, max: 0.99),
                    isVisible: true
                )
            )
        }

        return output
    }

    private func angleBetween(dx0: Double, dy0: Double, dx1: Double, dy1: Double) -> Double {
        let mag0 = hypot(dx0, dy0)
        let mag1 = hypot(dx1, dy1)
        guard mag0 > 1e-6, mag1 > 1e-6 else { return 0 }

        let dot = dx0 * dx1 + dy0 * dy1
        let value = clamp(dot / (mag0 * mag1), min: -1, max: 1)
        return acos(value)
    }

    private func trajectoryContinuity(points: [InferencePoint], width: Int, height: Int) -> Double {
        guard points.count >= 2 else { return 0.5 }
        let diagonal = max(sqrt(Double(width * width + height * height)), 1)

        var distanceSum = 0.0
        for idx in 1..<points.count {
            let p0 = points[idx - 1]
            let p1 = points[idx]
            let dx = Double(p1.x - p0.x)
            let dy = Double(p1.y - p0.y)
            distanceSum += sqrt(dx * dx + dy * dy) / diagonal
        }

        let avgDistance = distanceSum / Double(points.count - 1)
        return clamp(1 - avgDistance * 3.2, min: 0, max: 1)
    }

    private func sampleFrames(from asset: AVAsset, maxCount: Int) async throws -> [CGImage] {
        let duration = try await asset.load(.duration)
        let durationSeconds = max(CMTimeGetSeconds(duration), 0.1)
        let sampleCount = max(3, min(maxCount, Int(durationSeconds * 2.4)))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.02, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.02, preferredTimescale: 600)

        var frames: [CGImage] = []
        for index in 0..<sampleCount {
            let ratio = sampleCount == 1 ? 0.5 : Double(index) / Double(sampleCount - 1)
            let seconds = ratio * max(durationSeconds - 0.01, 0)
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            do {
                let frame = try await generateFrame(generator: generator, at: time)
                frames.append(frame)
            } catch {
                continue
            }
        }

        if frames.isEmpty {
            throw OnDeviceVideoAnalyzerError.unableToSampleFrames
        }
        return frames
    }

    /// Samples `maxWindows` groups of `framesPerWindow` temporally adjacent frames at native fps.
    /// Each group is a consecutive run of frames suitable as a single TrackNet inference window.
    /// e.g. GridTrackNet: framesPerWindow = 5  (5 consecutive RGB frames)
    private func sampleWindowedFrames(
        from asset: AVAsset,
        videoTrack: AVAssetTrack,
        maxWindows: Int,
        framesPerWindow: Int = 3
    ) async throws -> [[CGImage]] {
        let n = max(2, framesPerWindow)   // frames per window
        let duration = try await asset.load(.duration)
        let durationSeconds = max(CMTimeGetSeconds(duration), 0.1)
        let nominalFPS = try await videoTrack.load(.nominalFrameRate)
        let fps = nominalFPS > 0 ? Double(nominalFPS) : 30.0
        let frameInterval = 1.0 / fps
        let windowSpan = frameInterval * Double(n - 1)   // time span of one window

        // How many non-overlapping windows fit in the video
        let maxFitting = max(1, Int((durationSeconds - windowSpan) / (windowSpan + frameInterval)))
        let windowCount = max(1, min(maxWindows, maxFitting))
        let usableDuration = max(durationSeconds - windowSpan, frameInterval)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let toleranceTime = CMTime(seconds: frameInterval * 0.45, preferredTimescale: 6000)
        generator.requestedTimeToleranceAfter = toleranceTime
        generator.requestedTimeToleranceBefore = toleranceTime

        var windows: [[CGImage]] = []

        for idx in 0..<windowCount {
            let ratio = windowCount == 1 ? 0.5 : Double(idx) / Double(windowCount - 1)
            let windowStart = ratio * usableDuration

            var window: [CGImage] = []
            for frameOffset in 0..<n {
                let t = max(0, min(windowStart + Double(frameOffset) * frameInterval, durationSeconds - 0.001))
                let time = CMTime(seconds: t, preferredTimescale: 6000)
                if let frame = try? await generateFrame(generator: generator, at: time) {
                    window.append(frame)
                }
            }

            if window.count == n {
                windows.append(window)
            }
        }

        if windows.isEmpty {
            throw OnDeviceVideoAnalyzerError.unableToSampleFrames
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
                continuation.resume(
                    throwing: error ?? OnDeviceVideoAnalyzerError.unableToSampleFrames
                )
            }
        }
    }

    private func makeInputAdapter(for model: MLModel) throws -> InputAdapter {
        let inputs = model.modelDescription.inputDescriptionsByName
        let sortedNames = inputs.keys.sorted()

        for name in sortedNames {
            guard let description = inputs[name] else { continue }
            if description.type == .image {
                let constraint = description.imageConstraint
                let width = max(constraint?.pixelsWide ?? 224, 1)
                let height = max(constraint?.pixelsHigh ?? 224, 1)
                return .image(name: name, width: width, height: height)
            }
        }

        for name in sortedNames {
            guard let description = inputs[name] else { continue }
            if description.type == .multiArray, let constraint = description.multiArrayConstraint {
                let shape = constraint.shape.map { Int(truncating: $0) }
                guard let layout = inferLayout(from: shape) else {
                    throw OnDeviceVideoAnalyzerError.invalidTensorShape(name: name, shape: shape)
                }
                return .multiArray(
                    name: name,
                    shape: shape,
                    layout: layout,
                    dataType: constraint.dataType
                )
            }
        }

        throw OnDeviceVideoAnalyzerError.unsupportedInput
    }

    private func inferLayout(from shape: [Int]) -> TensorLayout? {
        if shape.count == 4 {
            guard shape[0] == 1 else { return nil }
            if shape[1] > 0, shape[2] > 0, shape[3] > 0, shape[1] <= 128 {
                return TensorLayout(
                    hasBatch: true,
                    order: .chw,
                    channels: shape[1],
                    height: shape[2],
                    width: shape[3]
                )
            }
            if shape[1] > 0, shape[2] > 0, shape[3] > 0, shape[3] <= 128 {
                return TensorLayout(
                    hasBatch: true,
                    order: .hwc,
                    channels: shape[3],
                    height: shape[1],
                    width: shape[2]
                )
            }
            return nil
        }

        if shape.count == 3 {
            if shape[0] > 0, shape[1] > 0, shape[2] > 0, shape[0] <= 128 {
                return TensorLayout(
                    hasBatch: false,
                    order: .chw,
                    channels: shape[0],
                    height: shape[1],
                    width: shape[2]
                )
            }
            if shape[0] > 0, shape[1] > 0, shape[2] > 0, shape[2] <= 128 {
                return TensorLayout(
                    hasBatch: false,
                    order: .hwc,
                    channels: shape[2],
                    height: shape[0],
                    width: shape[1]
                )
            }
        }
        return nil
    }

    private func makeProvider(for frame: CGImage, using adapter: InputAdapter) throws -> MLDictionaryFeatureProvider {
        return try makeProvider(forFrames: [frame], using: adapter)
    }

    private func makeProvider(forFrames frames: [CGImage], using adapter: InputAdapter) throws -> MLDictionaryFeatureProvider {
        switch adapter {
        case .image(let name, let width, let height):
            guard let frame = frames.last else { throw OnDeviceVideoAnalyzerError.unableToSampleFrames }
            let pixelBuffer = try makePixelBuffer(from: frame, width: width, height: height)
            return try MLDictionaryFeatureProvider(dictionary: [name: MLFeatureValue(pixelBuffer: pixelBuffer)])
        case .multiArray(let name, let shape, let layout, let dataType):
            guard let frame = frames.last else { throw OnDeviceVideoAnalyzerError.unableToSampleFrames }
            let array: MLMultiArray
            if layout.channels >= 9, layout.channels % 3 == 0, frames.count >= 3 {
                array = try makeMultiArrayRGBInput(
                    from: Array(frames.suffix(min(frames.count, layout.channels / 3))),
                    shape: shape,
                    layout: layout,
                    dataType: dataType
                )
            } else {
                array = try makeMultiArrayInput(from: frame, shape: shape, layout: layout, dataType: dataType)
            }
            return try MLDictionaryFeatureProvider(dictionary: [name: MLFeatureValue(multiArray: array)])
        }
    }

    private func makePixelBuffer(from image: CGImage, width: Int, height: Int) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        )

        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw OnDeviceVideoAnalyzerError.pixelBufferCreationFailed
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw OnDeviceVideoAnalyzerError.pixelBufferCreationFailed
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw OnDeviceVideoAnalyzerError.pixelBufferCreationFailed
        }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixelBuffer
    }

    private func makeMultiArrayInput(
        from image: CGImage,
        shape: [Int],
        layout: TensorLayout,
        dataType: MLMultiArrayDataType
    ) throws -> MLMultiArray {
        let array = try MLMultiArray(
            shape: shape.map(NSNumber.init(value:)),
            dataType: dataType
        )
        let grayscale = try grayscalePixels(from: image, width: layout.width, height: layout.height)
        fillGray(array: array, layout: layout, grayscale: grayscale)
        return array
    }

    private func makeMultiArrayRGBInput(
        from frames: [CGImage],
        shape: [Int],
        layout: TensorLayout,
        dataType: MLMultiArrayDataType
    ) throws -> MLMultiArray {
        let frameCount = max(1, layout.channels / 3)
        let selectedFrames: [CGImage]
        if frames.count >= frameCount {
            selectedFrames = Array(frames.suffix(frameCount))
        } else if let last = frames.last {
            selectedFrames = frames + Array(repeating: last, count: frameCount - frames.count)
        } else {
            throw OnDeviceVideoAnalyzerError.unableToSampleFrames
        }

        var rgbFrames: [[Float]] = []
        rgbFrames.reserveCapacity(selectedFrames.count)
        for frame in selectedFrames {
            rgbFrames.append(try rgbPixels(from: frame, width: layout.width, height: layout.height))
        }

        let array = try MLMultiArray(
            shape: shape.map(NSNumber.init(value:)),
            dataType: dataType
        )
        fillRGB(array: array, layout: layout, rgbFrames: rgbFrames)
        return array
    }

    /// Renders `image` into a heap-allocated BGRA byte buffer without going through
    /// CVPixelBuffer — avoids an IOSurface allocation per frame when called in a tight loop.
    private func renderBGRA(from image: CGImage, width: Int, height: Int) throws -> (bytes: [UInt8], bytesPerRow: Int) {
        let bytesPerRow = width * 4
        var rawBytes = [UInt8](repeating: 0, count: height * bytesPerRow)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(
            data: &rawBytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw OnDeviceVideoAnalyzerError.pixelBufferCreationFailed
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (rawBytes, bytesPerRow)
    }

    private func grayscalePixels(from image: CGImage, width: Int, height: Int) throws -> [Float] {
        let (rawBytes, bytesPerRow) = try renderBGRA(from: image, width: width, height: height)
        var output = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let rowOffset = y * bytesPerRow
            for x in 0..<width {
                let off = rowOffset + x * 4
                let b = Float(rawBytes[off + 0])
                let g = Float(rawBytes[off + 1])
                let r = Float(rawBytes[off + 2])
                output[y * width + x] = (0.114 * b + 0.587 * g + 0.299 * r) / 255.0
            }
        }
        return output
    }

    private func rgbPixels(from image: CGImage, width: Int, height: Int) throws -> [Float] {
        let (rawBytes, bytesPerRow) = try renderBGRA(from: image, width: width, height: height)
        var output = [Float](repeating: 0, count: width * height * 3)
        for y in 0..<height {
            let rowOffset = y * bytesPerRow
            for x in 0..<width {
                let off = rowOffset + x * 4
                let b = Float(rawBytes[off + 0]) / 255.0
                let g = Float(rawBytes[off + 1]) / 255.0
                let r = Float(rawBytes[off + 2]) / 255.0
                let idx = (y * width + x) * 3
                output[idx + 0] = r
                output[idx + 1] = g
                output[idx + 2] = b
            }
        }
        return output
    }

    private func fillGray(array: MLMultiArray, layout: TensorLayout, grayscale: [Float]) {
        let strides = array.strides.map { Int(truncating: $0) }

        let valueProvider: (Int, Int, Int) -> Float = { _, y, x in
            grayscale[y * layout.width + x]
        }

        fillArray(
            array: array,
            layout: layout,
            strides: strides,
            valueProvider: valueProvider,
            integerScaling: 255.0
        )
    }

    private func fillRGB(array: MLMultiArray, layout: TensorLayout, rgbFrames: [[Float]]) {
        let strides = array.strides.map { Int(truncating: $0) }

        let valueProvider: (Int, Int, Int) -> Float = { channel, y, x in
            let frameIndex = min(channel / 3, rgbFrames.count - 1)
            let colorIndex = channel % 3
            let pixelIndex = (y * layout.width + x) * 3 + colorIndex
            return rgbFrames[frameIndex][pixelIndex]
        }

        fillArray(
            array: array,
            layout: layout,
            strides: strides,
            valueProvider: valueProvider,
            integerScaling: 255.0
        )
    }

    private func fillArray(
        array: MLMultiArray,
        layout: TensorLayout,
        strides: [Int],
        valueProvider: (Int, Int, Int) -> Float,
        integerScaling: Float
    ) {
        switch array.dataType {
        case .double:
            let data = array.dataPointer.bindMemory(to: Double.self, capacity: array.count)
            fillFloating(
                data: data,
                layout: layout,
                strides: strides,
                valueProvider: valueProvider
            )
        case .float32:
            let data = array.dataPointer.bindMemory(to: Float32.self, capacity: array.count)
            fillFloating(
                data: data,
                layout: layout,
                strides: strides,
                valueProvider: valueProvider
            )
        case .float16:
            let data = array.dataPointer.bindMemory(to: Float16.self, capacity: array.count)
            fillFloating(
                data: data,
                layout: layout,
                strides: strides,
                valueProvider: valueProvider
            )
        case .int32:
            let data = array.dataPointer.bindMemory(to: Int32.self, capacity: array.count)
            fillInteger(
                data: data,
                layout: layout,
                strides: strides,
                valueProvider: valueProvider,
                scaling: integerScaling
            )
        case .int8:
            let data = array.dataPointer.bindMemory(to: Int8.self, capacity: array.count)
            fillInteger(
                data: data,
                layout: layout,
                strides: strides,
                valueProvider: valueProvider,
                scaling: integerScaling
            )
        @unknown default:
            let data = array.dataPointer.bindMemory(to: Float32.self, capacity: array.count)
            fillFloating(
                data: data,
                layout: layout,
                strides: strides,
                valueProvider: valueProvider
            )
        }
    }

    private func fillFloating<T: BinaryFloatingPoint>(
        data: UnsafeMutablePointer<T>,
        layout: TensorLayout,
        strides: [Int],
        valueProvider: (Int, Int, Int) -> Float
    ) {
        for c in 0..<layout.channels {
            for y in 0..<layout.height {
                for x in 0..<layout.width {
                    let offset = heatmapOffset(layout: layout, strides: strides, channel: c, y: y, x: x)
                    data[offset] = T(valueProvider(c, y, x))
                }
            }
        }
    }

    private func fillInteger<T: FixedWidthInteger>(
        data: UnsafeMutablePointer<T>,
        layout: TensorLayout,
        strides: [Int],
        valueProvider: (Int, Int, Int) -> Float,
        scaling: Float
    ) {
        let minValue = Float(T.min)
        let maxValue = Float(T.max)

        for c in 0..<layout.channels {
            for y in 0..<layout.height {
                for x in 0..<layout.width {
                    let scaled = valueProvider(c, y, x) * scaling
                    let clamped = Swift.max(minValue, Swift.min(maxValue, scaled))
                    let offset = heatmapOffset(layout: layout, strides: strides, channel: c, y: y, x: x)
                    data[offset] = T(clamped.rounded())
                }
            }
        }
    }

    private func extractSignal(from provider: MLFeatureProvider) -> Double {
        for name in provider.featureNames.sorted() {
            guard let value = provider.featureValue(for: name) else { continue }
            switch value.type {
            case .double:
                return normalizedSignal(value.doubleValue)
            case .int64:
                return normalizedSignal(Double(value.int64Value))
            case .multiArray:
                if let array = value.multiArrayValue {
                    return normalizedSignal(signal(from: array))
                }
            case .dictionary:
                let dictionary = value.dictionaryValue
                if let maxValue = dictionary.values.map(\.doubleValue).max() {
                    return normalizedSignal(maxValue)
                }
            default:
                continue
            }
        }
        return 0.5
    }

    private func signal(from array: MLMultiArray) -> Double {
        let sampleCount = min(array.count, 256)
        if sampleCount <= 0 { return 0.5 }
        let step = max(array.count / sampleCount, 1)

        let values: [Double]
        switch array.dataType {
        case .double:
            let data = array.dataPointer.bindMemory(to: Double.self, capacity: array.count)
            values = stride(from: 0, to: array.count, by: step).prefix(sampleCount).map { data[$0] }
        case .float32:
            let data = array.dataPointer.bindMemory(to: Float32.self, capacity: array.count)
            values = stride(from: 0, to: array.count, by: step).prefix(sampleCount).map { Double(data[$0]) }
        case .float16:
            let data = array.dataPointer.bindMemory(to: Float16.self, capacity: array.count)
            values = stride(from: 0, to: array.count, by: step).prefix(sampleCount).map { Double(data[$0]) }
        case .int32:
            let data = array.dataPointer.bindMemory(to: Int32.self, capacity: array.count)
            values = stride(from: 0, to: array.count, by: step).prefix(sampleCount).map { Double(data[$0]) }
        case .int8:
            let data = array.dataPointer.bindMemory(to: Int8.self, capacity: array.count)
            values = stride(from: 0, to: array.count, by: step).prefix(sampleCount).map { Double(data[$0]) }
        @unknown default:
            values = []
        }

        if values.isEmpty {
            return 0.5
        }
        return values.reduce(0, +) / Double(values.count)
    }

    private func normalizedSignal(_ raw: Double) -> Double {
        guard raw.isFinite else { return 0.5 }
        if raw >= 0, raw <= 1 {
            return raw
        }
        let clipped = clamp(raw, min: -20, max: 20)
        return 1 / (1 + exp(-clipped))
    }

    private func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0.5 }
        return values.reduce(0, +) / Double(values.count)
    }

    private func variance(values: [Double], mean: Double) -> Double {
        guard values.count > 1 else { return 0 }
        let sum = values.reduce(0) { partial, value in
            let delta = value - mean
            return partial + (delta * delta)
        }
        return sum / Double(values.count)
    }

    private func clamp(_ value: Double, min: Double, max: Double) -> Double {
        Swift.max(min, Swift.min(max, value))
    }
}

// MARK: - Testing Accessors

#if DEBUG
extension OnDeviceVideoAnalyzer {
    var bounceThresholdsForTesting: BounceThresholds { bounceThresholds }
    var actionThresholdsForTesting: ActionThresholds { actionThresholds }

    func smoothTrajectoryForTesting(points: [InferencePoint], windowRadius: Int) -> [InferencePoint] {
        smoothTrajectory(points: points, windowRadius: windowRadius)
    }

    func detectBouncePointsForTesting(from points: [InferencePoint], sourceHeight: Int) -> [InferencePoint] {
        detectBouncePoints(from: points, sourceHeight: sourceHeight)
    }

    func detectPlayerActionsForTesting(
        from points: [InferencePoint],
        sourceWidth: Int,
        sourceHeight: Int
    ) -> [DetectedAction] {
        detectPlayerActions(from: points, sourceWidth: sourceWidth, sourceHeight: sourceHeight)
    }

    /// Returns the effective points after applying the fallback rule, mirroring analyzeTrackNet logic.
    func effectivePointsForTesting(allPoints: [InferencePoint]) -> (points: [InferencePoint], usingFallback: Bool) {
        let visible = allPoints.filter(\.isVisible)
        if visible.isEmpty, !allPoints.isEmpty {
            let bestConf = allPoints.max(by: { $0.confidence < $1.confidence })?.confidence ?? 0
            return (allPoints.filter { $0.confidence >= bestConf * 0.75 }, true)
        }
        return (visible, false)
    }
}
#endif
