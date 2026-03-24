// PersonDetector.swift
// Tennis AI
//
// 使用苹果内建 Vision VNDetectHumanRectanglesRequest 检测人物
// 无需外部模型，Neural Engine 加速，iOS 14+
//

import AVFoundation
import CoreGraphics
import Foundation
import Vision

// MARK: - 单帧检测结果

struct PersonDetection {
    let frameIndex: Int
    let tracks: [TrackedPerson]   // ByteTrack 输出的持续追踪结果
}

// MARK: - PersonDetector

actor PersonDetector {

    private let tracker: ByteTracker
    private let detectionInterval = 3      // 每 3 帧跑一次 Vision（节省算力）
    private var lastDetections: [(box: CGRect, score: Float)] = []

    init() {
        tracker = ByteTracker()
    }

    /// 分析视频片段，返回每帧的追踪结果
    /// - Parameters:
    ///   - videoURL: 视频文件
    ///   - maxSeconds: 最多分析多少秒
    ///   - onProgress: 进度回调 [0, 1]
    func detectPersons(
        in videoURL: URL,
        maxSeconds: Double = 60,
        onProgress: @Sendable (Double) -> Void = { _ in }
    ) async throws -> [PersonDetection] {

        let asset = AVURLAsset(url: videoURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = tracks.first else { return [] }

        let naturalSize = try await videoTrack.load(.naturalSize)
        let duration = try await asset.load(.duration)
        let fps = try await videoTrack.load(.nominalFrameRate)

        let segmentSec = min(CMTimeGetSeconds(duration), maxSeconds)
        let totalFrames = Int(segmentSec * Double(fps))

        let reader = try AVAssetReader(asset: asset)
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: segmentSec, preferredTimescale: 600))
        reader.timeRange = range

        let output = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)]
        )
        reader.add(output)
        guard reader.startReading() else { return [] }

        var results: [PersonDetection] = []
        var frameIndex = 0

        while let sampleBuffer = output.copyNextSampleBuffer() {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                frameIndex += 1; continue
            }

            if Task.isCancelled { break }

            // 每 detectionInterval 帧做一次完整检测
            if frameIndex % detectionInterval == 0 {
                lastDetections = await runVisionDetection(pixelBuffer: pixelBuffer)
            }

            // ByteTrack 每帧都更新（预测帧用 Kalman）
            let activeTracks = tracker.update(detections: lastDetections)
            results.append(PersonDetection(frameIndex: frameIndex, tracks: activeTracks))

            frameIndex += 1
            if frameIndex % 30 == 0 {
                onProgress(Double(frameIndex) / Double(Swift.max(totalFrames, 1)))
            }
        }

        reader.cancelReading()
        tracker.reset()
        return results
    }

    // MARK: - Vision 检测（在后台线程）

    private func runVisionDetection(pixelBuffer: CVPixelBuffer) async -> [(box: CGRect, score: Float)] {
        await withCheckedContinuation { continuation in
            let request = VNDetectHumanRectanglesRequest { req, _ in
                guard let obs = req.results as? [VNHumanObservation] else {
                    continuation.resume(returning: []); return
                }
                let dets = obs.map { o in
                    (box: o.boundingBox, score: Float(o.confidence))
                }
                continuation.resume(returning: dets)
            }
            request.upperBodyOnly = false

            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
            try? handler.perform([request])
        }
    }
}

// MARK: - 便捷扩展：按 frameIndex 快速查询

extension [PersonDetection] {
    func tracks(at frameIndex: Int) -> [TrackedPerson] {
        // 最近的检测结果（最多向前找 10 帧）
        let start = Swift.max(0, frameIndex - 10)
        for fi in stride(from: frameIndex, through: start, by: -1) {
            if let d = first(where: { $0.frameIndex == fi }) { return d.tracks }
        }
        return []
    }
}
