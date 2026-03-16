//
//  VideoExportRenderer.swift
//  Tennis AI
//
//  Created by Codex on 2026/3/12.
//

import AVFoundation
import CoreGraphics
import CoreImage
import Foundation
import UIKit

enum VideoExportRendererError: LocalizedError {
    case noVideoTrack
    case readerSetupFailed
    case writerSetupFailed
    case pixelBufferPoolUnavailable
    case appendFailed
    case cancelled
    case writerFailed(String)
    case readerFailed(String)

    var errorDescription: String? {
        switch self {
        case .noVideoTrack:
            return "未找到可导出的视频轨道。"
        case .readerSetupFailed:
            return "视频读取器初始化失败。"
        case .writerSetupFailed:
            return "视频写入器初始化失败。"
        case .pixelBufferPoolUnavailable:
            return "导出缓冲区创建失败。"
        case .appendFailed:
            return "导出写入失败。"
        case .cancelled:
            return "导出已取消。"
        case .writerFailed(let detail):
            return "导出失败：\(detail)"
        case .readerFailed(let detail):
            return "读取失败：\(detail)"
        }
    }
}

final class VideoExportRenderer {
    private let stateLock = NSLock()
    private var cancelled = false

    func cancel() {
        stateLock.lock()
        cancelled = true
        stateLock.unlock()
    }

    func export(
        videoURL: URL,
        session: AnalysisSession,
        config: PlaybackExportConfig,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: VideoExportRendererError.cancelled)
                    return
                }

                self.resetCancellation()

                do {
                    let exportedURL = try self.performExport(
                        videoURL: videoURL,
                        session: session,
                        config: config,
                        onProgress: onProgress
                    )
                    continuation.resume(returning: exportedURL)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func resetCancellation() {
        stateLock.lock()
        cancelled = false
        stateLock.unlock()
    }

    private func isCancelled() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return cancelled
    }

    private func performExport(
        videoURL: URL,
        session: AnalysisSession,
        config: PlaybackExportConfig,
        onProgress: @escaping @Sendable (Double) -> Void
    ) throws -> URL {
        let asset = AVURLAsset(url: videoURL)
        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            throw VideoExportRendererError.noVideoTrack
        }

        let transformedSize = videoTrack.naturalSize.applying(videoTrack.preferredTransform)
        let renderSize = CGSize(
            width: max(abs(transformedSize.width), 1),
            height: max(abs(transformedSize.height), 1)
        )

        let duration = asset.duration
        let durationSeconds = max(CMTimeGetSeconds(duration), 0.001)
        let nominalFPS = videoTrack.nominalFrameRate > 1 ? Double(videoTrack.nominalFrameRate) : 30.0
        let frameDuration = CMTime(seconds: 1.0 / nominalFPS, preferredTimescale: 600)

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = frameDuration
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        layerInstruction.setTransform(videoTrack.preferredTransform, at: .zero)
        instruction.layerInstructions = [layerInstruction]
        videoComposition.instructions = [instruction]

        guard let reader = try? AVAssetReader(asset: asset) else {
            throw VideoExportRendererError.readerSetupFailed
        }
        let readerOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: [videoTrack],
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
        )
        readerOutput.videoComposition = videoComposition
        readerOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerOutput) else {
            throw VideoExportRendererError.readerSetupFailed
        }
        reader.add(readerOutput)

        let outputURL = makeOutputURL()
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }

        guard let writer = try? AVAssetWriter(outputURL: outputURL, fileType: .mp4) else {
            throw VideoExportRendererError.writerSetupFailed
        }
        let writerInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(renderSize.width),
                AVVideoHeightKey: Int(renderSize.height)
            ]
        )
        writerInput.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: Int(renderSize.width),
                kCVPixelBufferHeightKey as String: Int(renderSize.height)
            ]
        )

        guard writer.canAdd(writerInput) else {
            throw VideoExportRendererError.writerSetupFailed
        }
        writer.add(writerInput)

        guard reader.startReading() else {
            throw VideoExportRendererError.readerSetupFailed
        }
        guard writer.startWriting() else {
            throw VideoExportRendererError.writerSetupFailed
        }
        writer.startSession(atSourceTime: .zero)

        let ciContext = CIContext(options: [.useSoftwareRenderer: false])
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let maxModelFrame = resolveMaxModelFrame(session: session)
        let overlayActions = (session.detectedActions ?? []).sorted { $0.frameIndex < $1.frameIndex }
        let trajectoryPoints = (session.trajectoryPoints ?? [])
            .filter(\.isVisible)
            .sorted { $0.frameIndex < $1.frameIndex }
        let bouncePoints = (session.bouncePoints ?? [])
            .sorted { $0.frameIndex < $1.frameIndex }

        var smoothedFocusPoint = config.focusTargetSourcePoint
        var lastPresentationTime = CMTime.zero
        onProgress(0)

        while reader.status == .reading {
            if isCancelled() {
                reader.cancelReading()
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: outputURL)
                throw VideoExportRendererError.cancelled
            }

            guard let sampleBuffer = readerOutput.copyNextSampleBuffer() else {
                break
            }
            guard let sourcePixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                continue
            }

            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            lastPresentationTime = presentationTime
            let progress = min(max(CMTimeGetSeconds(presentationTime) / durationSeconds, 0), 1)
            let modelFrame = Int((progress * Double(maxModelFrame)).rounded())

            let activeFocus = resolveActiveFocusPoint(
                baseFocus: config.focusTargetSourcePoint,
                trackingType: config.focusTrackingActionType,
                actions: overlayActions,
                modelFrame: modelFrame,
                sourceSize: renderSize
            )
            smoothedFocusPoint = PlaybackFrameMath.resolveSmoothedFocus(
                current: smoothedFocusPoint,
                target: activeFocus,
                smoothing: config.focusSmoothingFactor
            )
            let cropRect = PlaybackFrameMath.resolveCropRect(
                sourceSize: renderSize,
                zoomScale: max(config.zoomScale, 1.0),
                aspectRatio: config.aspectRatio,
                focusPoint: smoothedFocusPoint ?? activeFocus
            )

            while !writerInput.isReadyForMoreMediaData {
                if isCancelled() {
                    reader.cancelReading()
                    writer.cancelWriting()
                    try? FileManager.default.removeItem(at: outputURL)
                    throw VideoExportRendererError.cancelled
                }
                Thread.sleep(forTimeInterval: 0.002)
            }

            guard let pool = adaptor.pixelBufferPool else {
                throw VideoExportRendererError.pixelBufferPoolUnavailable
            }

            var outputPixelBufferRef: CVPixelBuffer?
            let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outputPixelBufferRef)
            guard status == kCVReturnSuccess, let outputPixelBufferRef else {
                throw VideoExportRendererError.pixelBufferPoolUnavailable
            }

            let sourceImage = CIImage(cvPixelBuffer: sourcePixelBuffer)
            let translated = sourceImage
                .cropped(to: cropRect)
                .transformed(by: CGAffineTransform(translationX: -cropRect.minX, y: -cropRect.minY))
                .transformed(by: CGAffineTransform(
                    scaleX: renderSize.width / cropRect.width,
                    y: renderSize.height / cropRect.height
                ))

            ciContext.render(
                translated,
                to: outputPixelBufferRef,
                bounds: CGRect(origin: .zero, size: renderSize),
                colorSpace: colorSpace
            )

            drawOverlays(
                on: outputPixelBufferRef,
                renderSize: renderSize,
                cropRect: cropRect,
                modelFrame: modelFrame,
                trajectoryPoints: trajectoryPoints,
                bouncePoints: bouncePoints,
                actions: overlayActions,
                options: config.overlays,
                sessionCalibration: session.courtCalibration,
                sessionValidation: session.calibrationValidation
            )

            if !adaptor.append(outputPixelBufferRef, withPresentationTime: presentationTime) {
                throw VideoExportRendererError.appendFailed
            }

            onProgress(progress)
        }

        if reader.status == .failed {
            throw VideoExportRendererError.readerFailed(reader.error?.localizedDescription ?? "未知读取错误")
        }

        if config.overlays.showsSummaryCard {
            try appendSummaryCardFrames(
                to: adaptor,
                writerInput: writerInput,
                renderSize: renderSize,
                frameDuration: frameDuration,
                startTime: CMTimeAdd(lastPresentationTime, frameDuration),
                session: session
            )
        }

        writerInput.markAsFinished()
        let finishSemaphore = DispatchSemaphore(value: 0)
        writer.finishWriting {
            finishSemaphore.signal()
        }
        finishSemaphore.wait()

        if isCancelled() {
            try? FileManager.default.removeItem(at: outputURL)
            throw VideoExportRendererError.cancelled
        }

        if writer.status != .completed {
            throw VideoExportRendererError.writerFailed(writer.error?.localizedDescription ?? "未知写入错误")
        }

        onProgress(1.0)
        return outputURL
    }

    private func resolveMaxModelFrame(session: AnalysisSession) -> Int {
        let maxTrajectory = session.trajectoryPoints?.map(\.frameIndex).max() ?? 0
        let maxBounce = session.bouncePoints?.map(\.frameIndex).max() ?? 0
        let maxAction = session.detectedActions?.map(\.frameIndex).max() ?? 0
        return max(maxTrajectory, max(maxBounce, maxAction))
    }

    private func resolveActiveFocusPoint(
        baseFocus: CGPoint?,
        trackingType: ActionType?,
        actions: [DetectedAction],
        modelFrame: Int,
        sourceSize: CGSize
    ) -> CGPoint? {
        guard let baseFocus else { return nil }
        guard let trackingType else { return baseFocus }

        let frameWindow = 16
        let maxSpatialDistance = max(sourceSize.width, sourceSize.height) * 0.35
        let candidates = actions.filter {
            $0.type == trackingType && abs($0.frameIndex - modelFrame) <= frameWindow
        }
        guard !candidates.isEmpty else { return baseFocus }

        let nearest = candidates.min { lhs, rhs in
            let lhsFrameGap = abs(lhs.frameIndex - modelFrame)
            let rhsFrameGap = abs(rhs.frameIndex - modelFrame)
            if lhsFrameGap != rhsFrameGap {
                return lhsFrameGap < rhsFrameGap
            }
            let lhsDist = hypot(CGFloat(lhs.x) - baseFocus.x, CGFloat(lhs.y) - baseFocus.y)
            let rhsDist = hypot(CGFloat(rhs.x) - baseFocus.x, CGFloat(rhs.y) - baseFocus.y)
            return lhsDist < rhsDist
        }

        guard let nearest else { return baseFocus }
        let dist = hypot(CGFloat(nearest.x) - baseFocus.x, CGFloat(nearest.y) - baseFocus.y)
        guard dist <= maxSpatialDistance else { return baseFocus }
        return CGPoint(x: CGFloat(nearest.x), y: CGFloat(nearest.y))
    }

    private func drawOverlays(
        on outputPixelBuffer: CVPixelBuffer,
        renderSize: CGSize,
        cropRect: CGRect,
        modelFrame: Int,
        trajectoryPoints: [InferencePoint],
        bouncePoints: [InferencePoint],
        actions: [DetectedAction],
        options: ExportOverlayOptions,
        sessionCalibration: SessionCourtCalibration?,
        sessionValidation: SessionCalibrationValidation?
    ) {
        CVPixelBufferLockBaseAddress(outputPixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(outputPixelBuffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(outputPixelBuffer) else { return }
        let width = CVPixelBufferGetWidth(outputPixelBuffer)
        let height = CVPixelBufferGetHeight(outputPixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(outputPixelBuffer)

        guard let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return }

        context.saveGState()
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)

        if options.showsTrajectory {
            let visibleTrajectory = trajectoryPoints
                .filter { $0.frameIndex <= modelFrame }
                .map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) }
            drawTrajectory(
                points: visibleTrajectory,
                in: context,
                cropRect: cropRect,
                renderSize: renderSize
            )
        }

        let visibleBounces = bouncePoints.filter { $0.frameIndex <= modelFrame }
        if options.showsBounces {
            drawBounces(
                points: visibleBounces.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) },
                in: context,
                cropRect: cropRect,
                renderSize: renderSize
            )
        }

        if options.showsActionLabels {
            drawCurrentActionLabel(
                actions: actions,
                modelFrame: modelFrame,
                in: context,
                cropRect: cropRect,
                renderSize: renderSize
            )
        }

        if options.showsMiniCourtMap {
            drawMiniCourt(
                bouncePoints: visibleBounces,
                calibration: sessionCalibration,
                validation: sessionValidation,
                showsUncertaintyRings: options.showsUncertaintyRings,
                in: context,
                renderSize: renderSize
            )
        }

        context.restoreGState()
    }

    private func drawTrajectory(
        points: [CGPoint],
        in context: CGContext,
        cropRect: CGRect,
        renderSize: CGSize
    ) {
        guard points.count >= 2 else { return }

        let mapped = points.map { mapSourcePointToOutput($0, cropRect: cropRect, renderSize: renderSize) }
        context.setLineCap(.round)
        context.setLineJoin(.round)

        context.setStrokeColor(UIColor.white.withAlphaComponent(0.35).cgColor)
        context.setLineWidth(4.0)
        context.beginPath()
        context.addLines(between: mapped)
        context.strokePath()

        context.setStrokeColor(UIColor(red: 0.95, green: 0.88, blue: 0.18, alpha: 0.95).cgColor)
        context.setLineWidth(2.2)
        context.beginPath()
        context.addLines(between: mapped)
        context.strokePath()
    }

    private func drawBounces(
        points: [CGPoint],
        in context: CGContext,
        cropRect: CGRect,
        renderSize: CGSize
    ) {
        for point in points {
            let mapped = mapSourcePointToOutput(point, cropRect: cropRect, renderSize: renderSize)
            let ringRect = CGRect(x: mapped.x - 7, y: mapped.y - 7, width: 14, height: 14)
            let dotRect = CGRect(x: mapped.x - 2.5, y: mapped.y - 2.5, width: 5, height: 5)

            context.setStrokeColor(UIColor(red: 0.92, green: 0.48, blue: 0.24, alpha: 1).cgColor)
            context.setLineWidth(2.0)
            context.strokeEllipse(in: ringRect)

            context.setFillColor(UIColor(red: 0.92, green: 0.48, blue: 0.24, alpha: 1).cgColor)
            context.fillEllipse(in: dotRect)
        }
    }

    private func drawCurrentActionLabel(
        actions: [DetectedAction],
        modelFrame: Int,
        in context: CGContext,
        cropRect: CGRect,
        renderSize: CGSize
    ) {
        guard let nearest = actions.min(by: {
            abs($0.frameIndex - modelFrame) < abs($1.frameIndex - modelFrame)
        }) else { return }
        guard abs(nearest.frameIndex - modelFrame) <= 8 else { return }

        let mapped = mapSourcePointToOutput(
            CGPoint(x: CGFloat(nearest.x), y: CGFloat(nearest.y)),
            cropRect: cropRect,
            renderSize: renderSize
        )

        let text = "\(nearest.type.displayName) \(nearest.confidence.formatted(.number.precision(.fractionLength(2))))"
        let textPosition = CGPoint(x: mapped.x + 10, y: mapped.y - 22)

        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 13, weight: .bold),
            .foregroundColor: UIColor.white,
            .backgroundColor: UIColor.black.withAlphaComponent(0.4)
        ]
        (text as NSString).draw(at: textPosition, withAttributes: attributes)

        context.setFillColor(UIColor.white.cgColor)
        context.fillEllipse(in: CGRect(x: mapped.x - 3, y: mapped.y - 3, width: 6, height: 6))
    }

    private func drawMiniCourt(
        bouncePoints: [InferencePoint],
        calibration: SessionCourtCalibration?,
        validation: SessionCalibrationValidation?,
        showsUncertaintyRings: Bool,
        in context: CGContext,
        renderSize: CGSize
    ) {
        let mapSize = CGSize(width: 128, height: 152)
        let padding: CGFloat = 12
        let mapRect = CGRect(
            x: renderSize.width - mapSize.width - padding,
            y: padding,
            width: mapSize.width,
            height: mapSize.height
        )

        context.setFillColor(UIColor.black.withAlphaComponent(0.35).cgColor)
        context.fill(mapRect)
        context.setStrokeColor(UIColor.white.withAlphaComponent(0.8).cgColor)
        context.setLineWidth(1.1)
        context.stroke(mapRect.insetBy(dx: 4, dy: 4))

        let courtRect = mapRect.insetBy(dx: 8, dy: 10)
        context.setStrokeColor(UIColor.white.withAlphaComponent(0.86).cgColor)
        context.setLineWidth(0.9)
        context.stroke(courtRect)
        context.move(to: CGPoint(x: courtRect.midX, y: courtRect.minY))
        context.addLine(to: CGPoint(x: courtRect.midX, y: courtRect.maxY))
        context.move(to: CGPoint(x: courtRect.minX, y: courtRect.midY))
        context.addLine(to: CGPoint(x: courtRect.maxX, y: courtRect.midY))
        context.strokePath()

        let uncertaintyRadius: CGFloat? = {
            guard showsUncertaintyRings else { return nil }
            guard let validation else { return nil }
            return CourtCalibrationValidator.uncertaintyRadiusOnMap(
                averageErrorPixels: validation.averageErrorPixels,
                frameSize: renderSize,
                mapReferenceLength: min(courtRect.width, courtRect.height)
            )
        }()
        let mappedBounces = CourtBounceProjector.map(
            points: bouncePoints,
            frameSize: renderSize,
            calibration: calibration
        )
        let visibleMappedBounces = Array(mappedBounces.suffix(180))

        if let validation, let uncertaintyRadius {
            let uncertaintyColor = colorForValidationTier(validation.tier).withAlphaComponent(0.34).cgColor
            context.setStrokeColor(uncertaintyColor)
            context.setLineWidth(1.1)

            for bounce in visibleMappedBounces {
                let point = miniCourtPoint(for: bounce.normalizedPoint, in: courtRect)
                context.strokeEllipse(
                    in: CGRect(
                        x: point.x - uncertaintyRadius,
                        y: point.y - uncertaintyRadius,
                        width: uncertaintyRadius * 2,
                        height: uncertaintyRadius * 2
                    )
                )
            }
        }

        let labelCount = min(6, visibleMappedBounces.count)
        let labelStartIndex = max(visibleMappedBounces.count - labelCount, 0)
        let firstVisibleSequenceIndex = max(mappedBounces.count - visibleMappedBounces.count, 0)

        for (index, bounce) in visibleMappedBounces.enumerated() {
            let point = miniCourtPoint(for: bounce.normalizedPoint, in: courtRect)
            let isLatest = index == visibleMappedBounces.count - 1
            let fillColor = miniCourtBounceColor(for: bounce)
            let dotRadius: CGFloat = isLatest ? 3.4 : 2.2

            if isLatest {
                context.setStrokeColor(UIColor.white.withAlphaComponent(0.96).cgColor)
                context.setLineWidth(1.4)
                context.strokeEllipse(
                    in: CGRect(
                        x: point.x - 6.5,
                        y: point.y - 6.5,
                        width: 13,
                        height: 13
                    )
                )
            }

            let dotRect = CGRect(
                x: point.x - dotRadius,
                y: point.y - dotRadius,
                width: dotRadius * 2,
                height: dotRadius * 2
            )
            context.setFillColor(fillColor.cgColor)
            context.fillEllipse(in: dotRect)

            if index >= labelStartIndex {
                drawMiniCourtSequenceBadge(
                    sequenceNumber: firstVisibleSequenceIndex + index + 1,
                    near: point,
                    emphasized: isLatest,
                    tint: fillColor,
                    in: context,
                    bounds: mapRect
                )
            }
        }
    }

    private func miniCourtPoint(for normalizedPoint: CGPoint, in courtRect: CGRect) -> CGPoint {
        CGPoint(
            x: courtRect.minX + min(max(normalizedPoint.x, 0), 1) * courtRect.width,
            y: courtRect.minY + min(max(normalizedPoint.y, 0), 1) * courtRect.height
        )
    }

    private func miniCourtBounceColor(for bounce: CourtMappedBounce) -> UIColor {
        if bounce.isInBounds {
            return UIColor(red: 0.95, green: 0.88, blue: 0.20, alpha: 0.95)
        }
        return UIColor(red: 0.92, green: 0.36, blue: 0.28, alpha: 0.95)
    }

    private func drawMiniCourtSequenceBadge(
        sequenceNumber: Int,
        near point: CGPoint,
        emphasized: Bool,
        tint: UIColor,
        in context: CGContext,
        bounds: CGRect
    ) {
        let diameter: CGFloat = emphasized ? 16 : 14
        let anchor = CGPoint(
            x: min(max(point.x + 8, bounds.minX + diameter / 2), bounds.maxX - diameter / 2),
            y: min(max(point.y - 8, bounds.minY + diameter / 2), bounds.maxY - diameter / 2)
        )
        let badgeRect = CGRect(
            x: anchor.x - diameter / 2,
            y: anchor.y - diameter / 2,
            width: diameter,
            height: diameter
        )

        context.setFillColor(UIColor.black.withAlphaComponent(emphasized ? 0.78 : 0.62).cgColor)
        context.fillEllipse(in: badgeRect)
        context.setStrokeColor(tint.withAlphaComponent(0.96).cgColor)
        context.setLineWidth(emphasized ? 1.2 : 1.0)
        context.strokeEllipse(in: badgeRect)

        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }

        let text = "\(sequenceNumber)"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: emphasized ? 9 : 8, weight: .bold),
            .foregroundColor: UIColor.white
        ]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let textOrigin = CGPoint(
            x: badgeRect.midX - textSize.width / 2,
            y: badgeRect.midY - textSize.height / 2
        )
        (text as NSString).draw(at: textOrigin, withAttributes: attributes)
    }

    private func appendSummaryCardFrames(
        to adaptor: AVAssetWriterInputPixelBufferAdaptor,
        writerInput: AVAssetWriterInput,
        renderSize: CGSize,
        frameDuration: CMTime,
        startTime: CMTime,
        session: AnalysisSession
    ) throws {
        let frameSeconds = max(CMTimeGetSeconds(frameDuration), 0.001)
        let summaryDurationSeconds = 1.6
        let frameCount = max(Int((summaryDurationSeconds / frameSeconds).rounded()), 1)

        for index in 0..<frameCount {
            if isCancelled() {
                throw VideoExportRendererError.cancelled
            }

            while !writerInput.isReadyForMoreMediaData {
                if isCancelled() {
                    throw VideoExportRendererError.cancelled
                }
                Thread.sleep(forTimeInterval: 0.002)
            }

            guard let pool = adaptor.pixelBufferPool else {
                throw VideoExportRendererError.pixelBufferPoolUnavailable
            }

            var pixelBufferRef: CVPixelBuffer?
            let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBufferRef)
            guard status == kCVReturnSuccess, let pixelBufferRef else {
                throw VideoExportRendererError.pixelBufferPoolUnavailable
            }

            drawSummaryCard(
                on: pixelBufferRef,
                renderSize: renderSize,
                session: session
            )

            let presentationTime = CMTimeAdd(
                startTime,
                CMTimeMultiply(frameDuration, multiplier: Int32(index))
            )
            if !adaptor.append(pixelBufferRef, withPresentationTime: presentationTime) {
                throw VideoExportRendererError.appendFailed
            }
        }
    }

    private func drawSummaryCard(
        on outputPixelBuffer: CVPixelBuffer,
        renderSize: CGSize,
        session: AnalysisSession
    ) {
        CVPixelBufferLockBaseAddress(outputPixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(outputPixelBuffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(outputPixelBuffer) else { return }
        let width = CVPixelBufferGetWidth(outputPixelBuffer)
        let height = CVPixelBufferGetHeight(outputPixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(outputPixelBuffer)

        guard let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return }

        context.saveGState()
        context.translateBy(x: 0, y: renderSize.height)
        context.scaleBy(x: 1, y: -1)

        let fullRect = CGRect(origin: .zero, size: renderSize)
        let backgroundColors = [
            UIColor(red: 0.07, green: 0.23, blue: 0.16, alpha: 1).cgColor,
            UIColor(red: 0.11, green: 0.36, blue: 0.24, alpha: 1).cgColor
        ] as CFArray
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: backgroundColors,
            locations: [0, 1]
        ) {
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: 0),
                end: CGPoint(x: renderSize.width, y: renderSize.height),
                options: []
            )
        } else {
            context.setFillColor(UIColor(red: 0.08, green: 0.28, blue: 0.19, alpha: 1).cgColor)
            context.fill(fullRect)
        }

        context.setStrokeColor(UIColor.white.withAlphaComponent(0.12).cgColor)
        context.setLineWidth(1.1)
        context.move(to: CGPoint(x: 28, y: 42))
        context.addLine(to: CGPoint(x: renderSize.width - 28, y: 42))
        context.move(to: CGPoint(x: 28, y: renderSize.height - 54))
        context.addLine(to: CGPoint(x: renderSize.width - 28, y: renderSize.height - 54))
        context.strokePath()

        let horizontalInset = max(renderSize.width * 0.08, 32)
        let verticalInset = max(renderSize.height * 0.10, 34)
        let cardRect = CGRect(
            x: horizontalInset,
            y: verticalInset,
            width: renderSize.width - horizontalInset * 2,
            height: renderSize.height - verticalInset * 2
        )
        let cardPath = UIBezierPath(roundedRect: cardRect, cornerRadius: 24)
        context.setFillColor(UIColor.white.withAlphaComponent(0.14).cgColor)
        context.addPath(cardPath.cgPath)
        context.fillPath()
        context.setStrokeColor(UIColor.white.withAlphaComponent(0.20).cgColor)
        context.addPath(cardPath.cgPath)
        context.strokePath()

        UIGraphicsPushContext(context)
        defer {
            UIGraphicsPopContext()
            context.restoreGState()
        }

        let plan = session.feedbackPlan
        let counts = session.actionCounts
        let titleColor = UIColor.white
        let subtitleColor = UIColor.white.withAlphaComponent(0.82)
        let bodyColor = UIColor.white.withAlphaComponent(0.88)
        let titleFont = UIFont.systemFont(ofSize: min(renderSize.width * 0.04, 30), weight: .bold)
        let subtitleFont = UIFont.systemFont(ofSize: min(renderSize.width * 0.022, 16), weight: .medium)
        let sectionFont = UIFont.systemFont(ofSize: min(renderSize.width * 0.024, 18), weight: .semibold)
        let bodyFont = UIFont.systemFont(ofSize: min(renderSize.width * 0.020, 15), weight: .regular)
        let footerFont = UIFont.systemFont(ofSize: min(renderSize.width * 0.017, 13), weight: .medium)

        let contentX = cardRect.minX + 26
        let contentWidth = cardRect.width - 52
        let titleRect = CGRect(x: contentX, y: cardRect.minY + 24, width: contentWidth, height: 36)
        ("训练摘要" as NSString).draw(
            in: titleRect,
            withAttributes: [
                .font: titleFont,
                .foregroundColor: titleColor
            ]
        )

        let subtitleRect = CGRect(x: contentX, y: titleRect.maxY + 4, width: contentWidth, height: 22)
        let subtitle = "\(session.videoTitle) · \(session.eventDate.formatted(date: .abbreviated, time: .shortened))"
        (subtitle as NSString).draw(
            in: subtitleRect,
            withAttributes: [
                .font: subtitleFont,
                .foregroundColor: subtitleColor
            ]
        )

        let metricTop = subtitleRect.maxY + 18
        let pillSpacing: CGFloat = 10
        let pillWidth = (contentWidth - pillSpacing * 2) / 3
        let pillHeight: CGFloat = 64
        drawSummaryMetric(
            title: "跟踪质量",
            value: session.trackingQualityScore.formatted(.percent.precision(.fractionLength(0))),
            frame: CGRect(x: contentX, y: metricTop, width: pillWidth, height: pillHeight),
            fillColor: UIColor(red: 0.93, green: 0.68, blue: 0.23, alpha: 0.26),
            textColor: bodyColor
        )
        drawSummaryMetric(
            title: "球可见率",
            value: session.ballVisibleRate.formatted(.percent.precision(.fractionLength(0))),
            frame: CGRect(x: contentX + pillWidth + pillSpacing, y: metricTop, width: pillWidth, height: pillHeight),
            fillColor: UIColor(red: 0.25, green: 0.63, blue: 0.34, alpha: 0.24),
            textColor: bodyColor
        )
        drawSummaryMetric(
            title: "弹跳识别",
            value: "\(session.estimatedBounceCount)",
            frame: CGRect(x: contentX + (pillWidth + pillSpacing) * 2, y: metricTop, width: pillWidth, height: pillHeight),
            fillColor: UIColor(red: 0.95, green: 0.88, blue: 0.20, alpha: 0.22),
            textColor: bodyColor
        )

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3

        ("当前问题" as NSString).draw(
            in: CGRect(x: contentX, y: metricTop + pillHeight + 18, width: contentWidth, height: 20),
            withAttributes: [
                .font: sectionFont,
                .foregroundColor: titleColor
            ]
        )
        let issuesText = plan.issues.prefix(2).enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        (issuesText as NSString).draw(
            in: CGRect(x: contentX, y: metricTop + pillHeight + 42, width: contentWidth, height: 54),
            withAttributes: [
                .font: bodyFont,
                .foregroundColor: bodyColor,
                .paragraphStyle: paragraph
            ]
        )

        ("建议动作" as NSString).draw(
            in: CGRect(x: contentX, y: metricTop + pillHeight + 104, width: contentWidth, height: 20),
            withAttributes: [
                .font: sectionFont,
                .foregroundColor: titleColor
            ]
        )
        let recommendationsText = plan.recommendations.prefix(2).enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        (recommendationsText as NSString).draw(
            in: CGRect(x: contentX, y: metricTop + pillHeight + 128, width: contentWidth, height: 54),
            withAttributes: [
                .font: bodyFont,
                .foregroundColor: bodyColor,
                .paragraphStyle: paragraph
            ]
        )

        let goalRect = CGRect(x: contentX, y: cardRect.maxY - 94, width: contentWidth, height: 44)
        let goalPath = UIBezierPath(roundedRect: goalRect, cornerRadius: 16)
        UIColor(red: 0.95, green: 0.88, blue: 0.20, alpha: 0.16).setFill()
        goalPath.fill()
        (plan.nextCaptureGoal as NSString).draw(
            in: goalRect.insetBy(dx: 12, dy: 9),
            withAttributes: [
                .font: bodyFont,
                .foregroundColor: titleColor,
                .paragraphStyle: paragraph
            ]
        )

        let footer = "动作分布  正手 \(counts.forehand) / 反手 \(counts.backhand) / 发球 \(counts.serve)"
        (footer as NSString).draw(
            in: CGRect(x: contentX, y: cardRect.maxY - 34, width: contentWidth, height: 18),
            withAttributes: [
                .font: footerFont,
                .foregroundColor: subtitleColor
            ]
        )
    }

    private func drawSummaryMetric(
        title: String,
        value: String,
        frame: CGRect,
        fillColor: UIColor,
        textColor: UIColor
    ) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let path = UIBezierPath(roundedRect: frame, cornerRadius: 16)
        fillColor.setFill()
        path.fill()

        (title as NSString).draw(
            in: CGRect(x: frame.minX + 12, y: frame.minY + 12, width: frame.width - 24, height: 16),
            withAttributes: [
                .font: UIFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: textColor.withAlphaComponent(0.82)
            ]
        )
        (value as NSString).draw(
            in: CGRect(x: frame.minX + 12, y: frame.minY + 30, width: frame.width - 24, height: 24),
            withAttributes: [
                .font: UIFont.systemFont(ofSize: 24, weight: .bold),
                .foregroundColor: textColor
            ]
        )

        context.setStrokeColor(UIColor.white.withAlphaComponent(0.10).cgColor)
        context.setLineWidth(1)
        context.addPath(path.cgPath)
        context.strokePath()
    }

    private func colorForValidationTier(_ tier: CalibrationValidationTier) -> UIColor {
        switch tier {
        case .high:
            return UIColor(red: 0.16, green: 0.66, blue: 0.32, alpha: 1.0)
        case .medium:
            return UIColor(red: 0.95, green: 0.78, blue: 0.23, alpha: 1.0)
        case .low:
            return UIColor(red: 0.89, green: 0.31, blue: 0.26, alpha: 1.0)
        }
    }

    private func mapSourcePointToOutput(
        _ sourcePoint: CGPoint,
        cropRect: CGRect,
        renderSize: CGSize
    ) -> CGPoint {
        let x = ((sourcePoint.x - cropRect.minX) / max(cropRect.width, 1)) * renderSize.width
        let y = ((sourcePoint.y - cropRect.minY) / max(cropRect.height, 1)) * renderSize.height
        return CGPoint(
            x: min(max(x, 0), renderSize.width),
            y: min(max(y, 0), renderSize.height)
        )
    }

    private func makeOutputURL() -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let name = "playback_export_\(formatter.string(from: Date()))_\(UUID().uuidString.prefix(6)).mp4"
        return FileManager.default.temporaryDirectory.appendingPathComponent(name)
    }
}
