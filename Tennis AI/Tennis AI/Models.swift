//
//  Models.swift
//  Tennis AI
//
//  Created by Codex on 2026/3/11.
//

import AVFoundation
import CoreGraphics
import CoreImage
import Foundation
import Vision

struct InferencePoint: Identifiable, Codable, Equatable {
    let frameIndex: Int
    let x: Int
    let y: Int
    let confidence: Double
    let isVisible: Bool

    var id: String {
        "\(frameIndex)-\(x)-\(y)-\(confidence)"
    }
}

enum ActionType: String, Codable, CaseIterable {
    case forehand
    case backhand
    case serve
    case unknown
}

extension ActionType {
    var displayName: String {
        switch self {
        case .forehand:
            return "正手"
        case .backhand:
            return "反手"
        case .serve:
            return "发球"
        case .unknown:
            return "未知"
        }
    }
}

struct DetectedAction: Identifiable, Codable, Equatable {
    let frameIndex: Int
    let x: Int
    let y: Int
    let confidence: Double
    let type: ActionType

    var id: String {
        "\(frameIndex)-\(x)-\(y)-\(confidence)-\(type.rawValue)"
    }
}

enum SessionOrigin: String, Codable, Equatable {
    case demo
    case localSummary = "local_summary"
    case remoteStructured = "remote_structured"

    var displayLabel: String {
        switch self {
        case .demo:
            return "内置样例"
        case .localSummary:
            return "本地摘要"
        case .remoteStructured:
            return "远端结构化"
        }
    }
}

enum DemoModeVisibility: String, Codable, Equatable {
    case hidden
    case visible
}

struct StructuredRally: Identifiable, Codable, Equatable {
    let rallyID: Int
    let startFrame: Int
    let endFrame: Int
    let startSec: Double
    let endSec: Double
    let durationSec: Double?
    let numFrames: Int?
    let numShots: Int?
    let winnerSide: String?
    let winnerSource: String?
    let pointStatus: String?
    let serverSideBefore: String?
    let serverSideAfter: String?
    let beforeScore: String?
    let afterScore: String?

    var id: Int { rallyID }

    enum CodingKeys: String, CodingKey {
        case rallyID = "rally_id"
        case startFrame = "start_frame"
        case endFrame = "end_frame"
        case startSec = "start_sec"
        case endSec = "end_sec"
        case durationSec = "duration_sec"
        case numFrames = "num_frames"
        case numShots = "num_shots"
        case winnerSide = "winner_side"
        case winnerSource = "winner_source"
        case pointStatus = "point_status"
        case serverSideBefore = "server_side_before"
        case serverSideAfter = "server_side_after"
        case beforeScore = "before_score"
        case afterScore = "after_score"
    }
}

struct StructuredShot: Identifiable, Codable, Equatable {
    let shotID: Int
    let rallyID: Int?
    let frameNum: Int
    let timeSec: Double
    let xPx: Double?
    let yPx: Double?
    let shotType: String?
    let confidence: Double?
    let hitterSide: String?
    let speedKMH: Double?

    var id: Int { shotID }

    enum CodingKeys: String, CodingKey {
        case shotID = "shot_id"
        case rallyID = "rally_id"
        case frameNum = "frame_num"
        case timeSec = "time_sec"
        case xPx = "x_px"
        case yPx = "y_px"
        case shotType = "shot_type"
        case confidence
        case hitterSide = "hitter_side"
        case speedKMH = "speed_kmh"
    }
}

struct StructuredBounce: Identifiable, Codable, Equatable {
    let bounceID: Int
    let rallyID: Int?
    let frameNum: Int
    let timeSec: Double
    let xPx: Double?
    let yPx: Double?
    let inCourt: Bool?
    let confidence: Double?
    let detectionMethod: String?

    var id: Int { bounceID }

    enum CodingKeys: String, CodingKey {
        case bounceID = "bounce_id"
        case rallyID = "rally_id"
        case frameNum = "frame_num"
        case timeSec = "time_sec"
        case xPx = "x_px"
        case yPx = "y_px"
        case inCourt = "in_court"
        case confidence
        case detectionMethod = "detection_method"
    }
}

struct ScoreTimelineEntry: Identifiable, Codable, Equatable {
    let rallyID: Int
    let beforeScore: String?
    let afterScore: String?
    let winnerSide: String?
    let pointStatus: String?
    let serverSideBefore: String?
    let serverSideAfter: String?

    var id: Int { rallyID }

    enum CodingKeys: String, CodingKey {
        case rallyID = "rally_id"
        case beforeScore = "before_score"
        case afterScore = "after_score"
        case winnerSide = "winner_side"
        case pointStatus = "point_status"
        case serverSideBefore = "server_side_before"
        case serverSideAfter = "server_side_after"
    }
}

enum RemoteAnalysisJobState: String, Codable, Equatable {
    case queued
    case uploading
    case analyzing
    case partialFailed = "partial_failed"
    case completed
    case failed

    var summaryLabel: String {
        switch self {
        case .queued:
            return "等待远端分析"
        case .uploading:
            return "上传中"
        case .analyzing:
            return "远端分析中"
        case .partialFailed:
            return "部分完成"
        case .completed:
            return "结构化已回填"
        case .failed:
            return "远端分析失败"
        }
    }
}

struct RemoteAnalysisJob: Identifiable, Codable, Equatable {
    let id: String
    let actorKey: String
    let localSessionID: String
    let state: RemoteAnalysisJobState
    let stage: String
    let errorMessage: String?
    let remoteSessionID: String?
    let remoteExternalSessionID: String?
    let sourceVideoPath: String?
    let createdAtUTC: Date
    let updatedAtUTC: Date

    enum CodingKeys: String, CodingKey {
        case id = "job_id"
        case actorKey = "actor_key"
        case localSessionID = "local_session_id"
        case state
        case stage
        case errorMessage = "error_message"
        case remoteSessionID = "remote_session_id"
        case remoteExternalSessionID = "remote_external_session_id"
        case sourceVideoPath = "source_video_path"
        case createdAtUTC = "created_at_utc"
        case updatedAtUTC = "updated_at_utc"
    }
}

struct ExportOverlayOptions: Codable, Equatable {
    var showsTrajectory: Bool = true
    var showsBounces: Bool = true
    var showsActionLabels: Bool = false
    var showsMiniCourtMap: Bool = true
    var showsUncertaintyRings: Bool = true
    var showsSummaryCard: Bool = true
}

struct PlaybackExportConfig: Equatable {
    let zoomScale: Double
    let aspectRatio: Double
    let focusTargetSourcePoint: CGPoint?
    let focusTrackingActionType: ActionType?
    let focusSmoothingFactor: Double
    let overlays: ExportOverlayOptions
}

enum CalibrationValidationTier: String, Codable, Equatable {
    case high
    case medium
    case low
}

struct SessionCalibrationValidation: Codable, Equatable {
    let averageErrorPixels: Double
    let maxErrorPixels: Double
    let score: Double
    let sampleCount: Int
    let tier: CalibrationValidationTier
    let validatedAt: Date
}

enum PlaybackFrameMath {
    static func resolveSmoothedFocus(
        current: CGPoint?,
        target: CGPoint?,
        smoothing: Double
    ) -> CGPoint? {
        guard let target else { return nil }
        guard let current else { return target }

        let alpha = min(max(smoothing, 0.05), 1.0)
        return CGPoint(
            x: current.x * (1 - alpha) + target.x * alpha,
            y: current.y * (1 - alpha) + target.y * alpha
        )
    }

    static func resolveCropRect(
        sourceSize: CGSize,
        zoomScale: Double,
        aspectRatio: Double,
        focusPoint: CGPoint?
    ) -> CGRect {
        let sourceWidth = sourceSize.width
        let sourceHeight = sourceSize.height
        let safeAspect = min(max(aspectRatio, 9.0 / 16.0), 16.0 / 9.0)
        let sourceAspect = sourceWidth / max(sourceHeight, 1)

        var cropWidth: CGFloat
        var cropHeight: CGFloat
        if sourceAspect > safeAspect {
            cropHeight = sourceHeight
            cropWidth = sourceHeight * safeAspect
        } else {
            cropWidth = sourceWidth
            cropHeight = sourceWidth / safeAspect
        }

        let safeZoom = max(zoomScale, 1)
        cropWidth /= safeZoom
        cropHeight /= safeZoom

        let center = focusPoint ?? CGPoint(x: sourceWidth * 0.5, y: sourceHeight * 0.5)
        var originX = center.x - cropWidth * 0.5
        var originY = center.y - cropHeight * 0.5
        originX = min(max(originX, 0), sourceWidth - cropWidth)
        originY = min(max(originY, 0), sourceHeight - cropHeight)

        return CGRect(x: originX, y: originY, width: cropWidth, height: cropHeight)
    }
}

enum VideoExportState: Equatable {
    case idle
    case exporting(progress: Double)
    case success(fileURL: URL)
    case failed(message: String)

    var isExporting: Bool {
        if case .exporting = self {
            return true
        }
        return false
    }
}

struct AnalysisSession: Identifiable, Codable {
    let id: UUID
    let videoTitle: String
    let sourceID: String
    let actorKey: String?
    let eventDate: Date
    let trackedFrames: Int
    let totalFrames: Int
    let ballVisibleRate: Double
    let trackingQualityScore: Double
    let estimatedBounceCount: Int
    let processingStatus: ProcessingStatus
    let inputSource: VideoInputSource?
    let localVideoPath: String?
    let trajectoryPoints: [InferencePoint]?
    let bouncePoints: [InferencePoint]?
    let detectedActions: [DetectedAction]?
    let note: String
    var sessionOrigin: SessionOrigin = .localSummary
    var demoModeVisibility: DemoModeVisibility = .hidden
    var structuredRallies: [StructuredRally]? = nil
    var structuredShots: [StructuredShot]? = nil
    var structuredBounces: [StructuredBounce]? = nil
    var scoreTimeline: [ScoreTimelineEntry]? = nil
    var remoteModelVersions: [String: String]? = nil
    var courtDetectionQualityScore: Double? = nil
    var courtCalibration: SessionCourtCalibration? = nil
    var calibrationValidation: SessionCalibrationValidation? = nil
    var qualityBreakdown: SessionQualityBreakdown? = nil

    @available(*, deprecated, renamed: "trackingQualityScore")
    var courtDetectionScore: Double {
        trackingQualityScore
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case videoTitle
        case sourceID
        case actorKey
        case eventDate
        case trackedFrames
        case totalFrames
        case ballVisibleRate
        case trackingQualityScore
        case courtDetectionScore
        case estimatedBounceCount
        case processingStatus
        case inputSource
        case localVideoPath
        case trajectoryPoints
        case bouncePoints
        case detectedActions
        case note
        case sessionOrigin
        case demoModeVisibility
        case structuredRallies
        case structuredShots
        case structuredBounces
        case scoreTimeline
        case remoteModelVersions
        case courtDetectionQualityScore
        case courtCalibration
        case calibrationValidation
        case qualityBreakdown
    }

    init(
        id: UUID,
        videoTitle: String,
        sourceID: String,
        actorKey: String? = nil,
        eventDate: Date,
        trackedFrames: Int,
        totalFrames: Int,
        ballVisibleRate: Double,
        trackingQualityScore: Double,
        estimatedBounceCount: Int,
        processingStatus: ProcessingStatus,
        inputSource: VideoInputSource?,
        localVideoPath: String?,
        trajectoryPoints: [InferencePoint]?,
        bouncePoints: [InferencePoint]?,
        detectedActions: [DetectedAction]?,
        note: String,
        sessionOrigin: SessionOrigin = .localSummary,
        demoModeVisibility: DemoModeVisibility = .hidden,
        structuredRallies: [StructuredRally]? = nil,
        structuredShots: [StructuredShot]? = nil,
        structuredBounces: [StructuredBounce]? = nil,
        scoreTimeline: [ScoreTimelineEntry]? = nil,
        remoteModelVersions: [String: String]? = nil,
        courtDetectionQualityScore: Double? = nil,
        courtCalibration: SessionCourtCalibration? = nil,
        calibrationValidation: SessionCalibrationValidation? = nil,
        qualityBreakdown: SessionQualityBreakdown? = nil
    ) {
        self.id = id
        self.videoTitle = videoTitle
        self.sourceID = sourceID
        self.actorKey = actorKey
        self.eventDate = eventDate
        self.trackedFrames = trackedFrames
        self.totalFrames = totalFrames
        self.ballVisibleRate = ballVisibleRate
        self.trackingQualityScore = trackingQualityScore
        self.estimatedBounceCount = estimatedBounceCount
        self.processingStatus = processingStatus
        self.inputSource = inputSource
        self.localVideoPath = localVideoPath
        self.trajectoryPoints = trajectoryPoints
        self.bouncePoints = bouncePoints
        self.detectedActions = detectedActions
        self.note = note
        self.sessionOrigin = sessionOrigin
        self.demoModeVisibility = demoModeVisibility
        self.structuredRallies = structuredRallies
        self.structuredShots = structuredShots
        self.structuredBounces = structuredBounces
        self.scoreTimeline = scoreTimeline
        self.remoteModelVersions = remoteModelVersions
        self.courtDetectionQualityScore = courtDetectionQualityScore
        self.courtCalibration = courtCalibration
        self.calibrationValidation = calibrationValidation
        self.qualityBreakdown = qualityBreakdown
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        videoTitle = try container.decode(String.self, forKey: .videoTitle)
        sourceID = try container.decode(String.self, forKey: .sourceID)
        actorKey = try container.decodeIfPresent(String.self, forKey: .actorKey)
        eventDate = try container.decode(Date.self, forKey: .eventDate)
        trackedFrames = try container.decode(Int.self, forKey: .trackedFrames)
        totalFrames = try container.decode(Int.self, forKey: .totalFrames)
        ballVisibleRate = try container.decode(Double.self, forKey: .ballVisibleRate)
        trackingQualityScore =
            try container.decodeIfPresent(Double.self, forKey: .trackingQualityScore)
            ?? (try container.decode(Double.self, forKey: .courtDetectionScore))
        estimatedBounceCount = try container.decode(Int.self, forKey: .estimatedBounceCount)
        processingStatus = try container.decode(ProcessingStatus.self, forKey: .processingStatus)
        inputSource = try container.decodeIfPresent(VideoInputSource.self, forKey: .inputSource)
        localVideoPath = try container.decodeIfPresent(String.self, forKey: .localVideoPath)
        trajectoryPoints = try container.decodeIfPresent([InferencePoint].self, forKey: .trajectoryPoints)
        bouncePoints = try container.decodeIfPresent([InferencePoint].self, forKey: .bouncePoints)
        detectedActions = try container.decodeIfPresent([DetectedAction].self, forKey: .detectedActions)
        note = try container.decode(String.self, forKey: .note)
        sessionOrigin = try container.decodeIfPresent(SessionOrigin.self, forKey: .sessionOrigin) ?? .localSummary
        demoModeVisibility = try container.decodeIfPresent(DemoModeVisibility.self, forKey: .demoModeVisibility) ?? .hidden
        structuredRallies = try container.decodeIfPresent([StructuredRally].self, forKey: .structuredRallies)
        structuredShots = try container.decodeIfPresent([StructuredShot].self, forKey: .structuredShots)
        structuredBounces = try container.decodeIfPresent([StructuredBounce].self, forKey: .structuredBounces)
        scoreTimeline = try container.decodeIfPresent([ScoreTimelineEntry].self, forKey: .scoreTimeline)
        remoteModelVersions = try container.decodeIfPresent([String: String].self, forKey: .remoteModelVersions)
        courtDetectionQualityScore = try container.decodeIfPresent(Double.self, forKey: .courtDetectionQualityScore)
        courtCalibration = try container.decodeIfPresent(SessionCourtCalibration.self, forKey: .courtCalibration)
        calibrationValidation = try container.decodeIfPresent(
            SessionCalibrationValidation.self,
            forKey: .calibrationValidation
        )
        qualityBreakdown = try container.decodeIfPresent(
            SessionQualityBreakdown.self,
            forKey: .qualityBreakdown
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(videoTitle, forKey: .videoTitle)
        try container.encode(sourceID, forKey: .sourceID)
        try container.encodeIfPresent(actorKey, forKey: .actorKey)
        try container.encode(eventDate, forKey: .eventDate)
        try container.encode(trackedFrames, forKey: .trackedFrames)
        try container.encode(totalFrames, forKey: .totalFrames)
        try container.encode(ballVisibleRate, forKey: .ballVisibleRate)
        try container.encode(trackingQualityScore, forKey: .trackingQualityScore)
        try container.encode(trackingQualityScore, forKey: .courtDetectionScore)
        try container.encode(estimatedBounceCount, forKey: .estimatedBounceCount)
        try container.encode(processingStatus, forKey: .processingStatus)
        try container.encodeIfPresent(inputSource, forKey: .inputSource)
        try container.encodeIfPresent(localVideoPath, forKey: .localVideoPath)
        try container.encodeIfPresent(trajectoryPoints, forKey: .trajectoryPoints)
        try container.encodeIfPresent(bouncePoints, forKey: .bouncePoints)
        try container.encodeIfPresent(detectedActions, forKey: .detectedActions)
        try container.encode(note, forKey: .note)
        try container.encode(sessionOrigin, forKey: .sessionOrigin)
        try container.encode(demoModeVisibility, forKey: .demoModeVisibility)
        try container.encodeIfPresent(structuredRallies, forKey: .structuredRallies)
        try container.encodeIfPresent(structuredShots, forKey: .structuredShots)
        try container.encodeIfPresent(structuredBounces, forKey: .structuredBounces)
        try container.encodeIfPresent(scoreTimeline, forKey: .scoreTimeline)
        try container.encodeIfPresent(remoteModelVersions, forKey: .remoteModelVersions)
        try container.encodeIfPresent(courtDetectionQualityScore, forKey: .courtDetectionQualityScore)
        try container.encodeIfPresent(courtCalibration, forKey: .courtCalibration)
        try container.encodeIfPresent(calibrationValidation, forKey: .calibrationValidation)
        try container.encodeIfPresent(qualityBreakdown, forKey: .qualityBreakdown)
    }
}

struct SessionComparisonMetricRow: Identifiable, Equatable {
    enum BetterSide: Equatable {
        case left
        case right
        case tie
        case neutral
    }

    let id: String
    let title: String
    let leftValueText: String
    let rightValueText: String
    let deltaText: String
    let betterSide: BetterSide
}

struct SessionComparisonReport {
    let leftSession: AnalysisSession
    let rightSession: AnalysisSession
    let metrics: [SessionComparisonMetricRow]
    let recommendations: [String]

    static func build(left: AnalysisSession, right: AnalysisSession) -> SessionComparisonReport {
        let leftTrackRatio = ratio(left.trackedFrames, left.totalFrames)
        let rightTrackRatio = ratio(right.trackedFrames, right.totalFrames)

        let leftActions = actionCounts(left.detectedActions)
        let rightActions = actionCounts(right.detectedActions)

        let rows: [SessionComparisonMetricRow] = [
            percentMetric(
                id: "visible_rate",
                title: "球可见率",
                leftValue: left.ballVisibleRate,
                rightValue: right.ballVisibleRate
            ),
            percentMetric(
                id: "tracking_quality_score",
                title: "跟踪质量得分",
                leftValue: left.trackingQualityScore,
                rightValue: right.trackingQualityScore
            ),
            percentMetric(
                id: "track_ratio",
                title: "跟踪帧占比",
                leftValue: leftTrackRatio,
                rightValue: rightTrackRatio
            ),
            countMetric(
                id: "bounce_count",
                title: "弹跳次数",
                leftValue: left.estimatedBounceCount,
                rightValue: right.estimatedBounceCount,
                prefersHigher: false
            ),
            countMetric(
                id: "forehand_count",
                title: "动作计数（正手）",
                leftValue: leftActions.forehand,
                rightValue: rightActions.forehand,
                prefersHigher: false
            ),
            countMetric(
                id: "backhand_count",
                title: "动作计数（反手）",
                leftValue: leftActions.backhand,
                rightValue: rightActions.backhand,
                prefersHigher: false
            ),
            countMetric(
                id: "serve_count",
                title: "动作计数（发球）",
                leftValue: leftActions.serve,
                rightValue: rightActions.serve,
                prefersHigher: false
            )
        ]

        return SessionComparisonReport(
            leftSession: left,
            rightSession: right,
            metrics: rows,
            recommendations: buildRecommendations(left: left, right: right, leftActions: leftActions, rightActions: rightActions)
        )
    }

    private struct ActionCounts {
        let forehand: Int
        let backhand: Int
        let serve: Int
        let total: Int
    }

    private static func ratio(_ numerator: Int, _ denominator: Int) -> Double {
        guard denominator > 0 else { return 0 }
        return Double(numerator) / Double(denominator)
    }

    private static func actionCounts(_ actions: [DetectedAction]?) -> ActionCounts {
        let values = actions ?? []
        let forehand = values.filter { $0.type == .forehand }.count
        let backhand = values.filter { $0.type == .backhand }.count
        let serve = values.filter { $0.type == .serve }.count
        return ActionCounts(
            forehand: forehand,
            backhand: backhand,
            serve: serve,
            total: forehand + backhand + serve
        )
    }

    private static func percentMetric(
        id: String,
        title: String,
        leftValue: Double,
        rightValue: Double
    ) -> SessionComparisonMetricRow {
        let delta = leftValue - rightValue
        let better: SessionComparisonMetricRow.BetterSide
        if abs(delta) <= 0.0001 {
            better = .tie
        } else if delta > 0 {
            better = .left
        } else {
            better = .right
        }

        return SessionComparisonMetricRow(
            id: id,
            title: title,
            leftValueText: leftValue.formatted(.percent.precision(.fractionLength(1))),
            rightValueText: rightValue.formatted(.percent.precision(.fractionLength(1))),
            deltaText: absolutePercent(delta),
            betterSide: better
        )
    }

    private static func countMetric(
        id: String,
        title: String,
        leftValue: Int,
        rightValue: Int,
        prefersHigher: Bool
    ) -> SessionComparisonMetricRow {
        let delta = leftValue - rightValue
        let better: SessionComparisonMetricRow.BetterSide
        if prefersHigher {
            if delta == 0 {
                better = .tie
            } else if delta > 0 {
                better = .left
            } else {
                better = .right
            }
        } else {
            better = .neutral
        }

        return SessionComparisonMetricRow(
            id: id,
            title: title,
            leftValueText: "\(leftValue)",
            rightValueText: "\(rightValue)",
            deltaText: "\(abs(delta))",
            betterSide: better
        )
    }

    private static func absolutePercent(_ delta: Double) -> String {
        abs(delta).formatted(.percent.precision(.fractionLength(1)))
    }

    private static func buildRecommendations(
        left: AnalysisSession,
        right: AnalysisSession,
        leftActions: ActionCounts,
        rightActions: ActionCounts
    ) -> [String] {
        var items: [String] = []

        let visibleDelta = left.ballVisibleRate - right.ballVisibleRate
        if abs(visibleDelta) > 0.05 {
            if visibleDelta > 0 {
                items.append("A 场球可见率明显更高（>\(5)%），建议复用 A 场机位高度与拍摄稳定策略。")
            } else {
                items.append("B 场球可见率明显更高（>\(5)%），建议按 B 场机位和光照条件优化拍摄。")
            }
        }

        let trackingQualityDelta = left.trackingQualityScore - right.trackingQualityScore
        if abs(trackingQualityDelta) > 0.05 {
            if trackingQualityDelta > 0 {
                items.append("A 场跟踪质量摘要更稳定，建议参考 A 场机位和构图，减少画面抖动。")
            } else {
                items.append("B 场跟踪质量摘要更稳定，建议参考 B 场机位和构图，优先优化画面连续性。")
            }
        }

        let leftTotal = max(leftActions.total, 1)
        let rightTotal = max(rightActions.total, 1)
        let leftForehandShare = Double(leftActions.forehand) / Double(leftTotal)
        let rightForehandShare = Double(rightActions.forehand) / Double(rightTotal)
        if abs(leftForehandShare - rightForehandShare) > 0.25 {
            items.append("两场正手占比差异较大，建议下一次训练固定击球模式以便评估动作稳定性。")
        }

        let leftBackhandShare = Double(leftActions.backhand) / Double(leftTotal)
        let rightBackhandShare = Double(rightActions.backhand) / Double(rightTotal)
        if abs(leftBackhandShare - rightBackhandShare) > 0.25 {
            items.append("反手占比波动明显，建议增加反手专项回合并保持同一拍摄角度复测。")
        }

        if items.isEmpty {
            items.append("两场训练关键指标整体接近，建议继续保持当前训练与拍摄流程。")
        }

        return items
    }
}

enum ProcessingStatus: String, CaseIterable, Codable {
    case completed
    case processing
    case failed
}

struct DrillRecommendation: Identifiable {
    let id: UUID
    let title: String
    let durationMinutes: Int
    let focusArea: String
    let reason: String
}

struct LocalAnalysisJob: Identifiable {
    let id: UUID
    let fileName: String
    let inputSource: VideoInputSource
    let videoLocalPath: String
    let createdAt: Date
    var updatedAt: Date
    var stage: PipelineStage
    var state: JobExecutionState
    var progress: Double
    var resultSessionID: UUID?
    var errorMessage: String?
    var failureCategory: JobFailureCategory?
}

enum VideoInputSource: String, Codable {
    case camera
    case upload
}

enum JobExecutionState: String, Codable {
    case queued
    case running
    case completed
    case failed
}

enum CloudSyncState: Equatable {
    case pendingConfiguration
    case queued
    case uploading
    case processing(stage: String)
    case uploaded(remoteSessionID: String, uploadedAt: Date)
    case failed(message: String)
}

enum PipelineStage: Int, CaseIterable, Codable {
    case queued
    case extractingFrames
    case trackingBall
    case detectingCourt
    case generatingSummary
    case completed
    case failed
}

extension AnalysisSession {
    var localVideoURL: URL? {
        guard let localVideoPath, !localVideoPath.isEmpty else { return nil }
        let url = URL(fileURLWithPath: localVideoPath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    var isBuiltInSample: Bool {
        sessionOrigin == .demo || (localVideoPath == nil && inputSource == nil)
    }

    var hasStructuredAnalysis: Bool {
        !(structuredRallies ?? []).isEmpty || !(structuredShots ?? []).isEmpty || !(structuredBounces ?? []).isEmpty
    }

    var presentationOriginLabel: String {
        if isBuiltInSample {
            return "内置样例"
        }
        if hasStructuredAnalysis || sessionOrigin == .remoteStructured {
            return "远端结构化"
        }
        return "本地摘要"
    }

    var actionCounts: TrainingActionCounts {
        let actions = detectedActions ?? []
        return TrainingActionCounts(
            forehand: actions.filter { $0.type == .forehand }.count,
            backhand: actions.filter { $0.type == .backhand }.count,
            serve: actions.filter { $0.type == .serve }.count
        )
    }

    var feedbackPlan: TrainingFeedbackPlan {
        TrainingInsights.feedbackPlan(for: [self])
    }
}

struct SessionCourtCalibration: Codable, Equatable {
    let sourceCorners: [CGPoint]
    let homography: CourtHomography
    let qualityScore: Double
    let calibratedAt: Date
}

struct SessionQualityBreakdown: Codable, Equatable {
    let visibleRateScore: Double
    let continuityScore: Double
    let inferenceSuccessRate: Double
    let actionStabilityScore: Double

    var clampedVisibleRateScore: Double {
        clamp(visibleRateScore)
    }

    var clampedContinuityScore: Double {
        clamp(continuityScore)
    }

    var clampedInferenceSuccessRate: Double {
        clamp(inferenceSuccessRate)
    }

    var clampedActionStabilityScore: Double {
        clamp(actionStabilityScore)
    }

    var weightedTrackingQualityScore: Double {
        clamp(
            clampedVisibleRateScore * 0.42
                + clampedContinuityScore * 0.28
                + clampedInferenceSuccessRate * 0.20
                + clampedActionStabilityScore * 0.10
        )
    }

    private func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}

struct SessionPlaybackHighlight: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String
    let systemImage: String
    let frameIndex: Int
}

enum JobFailureCategory: String, Codable, CaseIterable {
    case modelMissing
    case unreadableVideo
    case frameExtractionFailed
    case inferenceFailed
    case syncFailed
    case unknown

    var summaryTitle: String {
        switch self {
        case .modelMissing:
            return "模型不可用"
        case .unreadableVideo:
            return "视频不可读"
        case .frameExtractionFailed:
            return "抽帧失败"
        case .inferenceFailed:
            return "推理失败"
        case .syncFailed:
            return "同步失败"
        case .unknown:
            return "未知异常"
        }
    }

    var guidance: String {
        switch self {
        case .modelMissing:
            return "请确认模型文件存在并可加载，必要时重启应用后重试。"
        case .unreadableVideo:
            return "建议重新导入视频，确认编码格式受支持且文件完整。"
        case .frameExtractionFailed:
            return "建议降低分辨率后重试，或更换视频源避免损坏帧。"
        case .inferenceFailed:
            return "建议检查模型状态与输入尺寸，必要时切换推理策略。"
        case .syncFailed:
            return "请检查网络与后端配置（URL / user_id），再尝试重传。"
        case .unknown:
            return "请记录错误信息并重试；若持续失败，建议导出日志排查。"
        }
    }
}

struct TrainingActionCounts: Codable, Equatable {
    let forehand: Int
    let backhand: Int
    let serve: Int

    var total: Int {
        forehand + backhand + serve
    }

    static let zero = TrainingActionCounts(forehand: 0, backhand: 0, serve: 0)
}

struct TrainingTrendSnapshot: Identifiable, Codable, Equatable {
    let id: String
    let title: String
    let subtitle: String
    let sessionCount: Int
    let averageVisibleRate: Double
    let averageTrackingQualityScore: Double
    let averageBounceCount: Double
    let averageQualityBreakdown: SessionQualityBreakdown
    let actionCounts: TrainingActionCounts

    var hasData: Bool {
        sessionCount > 0
    }
}

struct TrainingFeedbackPlan: Codable, Equatable {
    let issues: [String]
    let recommendations: [String]
    let nextCaptureGoal: String
}

struct TrainingPhaseComparisonReport: Codable, Equatable {
    let baseline: TrainingTrendSnapshot
    let recent: TrainingTrendSnapshot
    let headline: String
    let wins: [String]
    let cautions: [String]
}

enum TrainingInsights {
    static func recentSessions(
        from sessions: [AnalysisSession],
        days: Int,
        endingOn endDate: Date = Date()
    ) -> [AnalysisSession] {
        guard days > 0 else { return [] }
        let calendar = Calendar.current
        guard let startDate = calendar.date(byAdding: .day, value: -days, to: endDate) else {
            return []
        }
        return sessions
            .filter { $0.eventDate >= startDate && $0.eventDate <= endDate }
            .sorted { $0.eventDate > $1.eventDate }
    }

    static func snapshot(
        title: String,
        subtitle: String,
        sessions: [AnalysisSession]
    ) -> TrainingTrendSnapshot {
        guard !sessions.isEmpty else {
            return TrainingTrendSnapshot(
                id: "\(title)-\(subtitle)",
                title: title,
                subtitle: subtitle,
                sessionCount: 0,
                averageVisibleRate: 0,
                averageTrackingQualityScore: 0,
                averageBounceCount: 0,
                averageQualityBreakdown: SessionQualityBreakdown(
                    visibleRateScore: 0,
                    continuityScore: 0,
                    inferenceSuccessRate: 0,
                    actionStabilityScore: 0
                ),
                actionCounts: .zero
            )
        }

        let count = Double(sessions.count)
        let visibleRate = sessions.reduce(0) { $0 + $1.ballVisibleRate } / count
        let trackingQuality = sessions.reduce(0) { $0 + $1.trackingQualityScore } / count
        let bounceCount = sessions.reduce(0) { $0 + Double($1.estimatedBounceCount) } / count

        let breakdown = averageBreakdown(for: sessions)
        let actionCounts = aggregateActions(for: sessions)

        return TrainingTrendSnapshot(
            id: "\(title)-\(subtitle)",
            title: title,
            subtitle: subtitle,
            sessionCount: sessions.count,
            averageVisibleRate: visibleRate,
            averageTrackingQualityScore: trackingQuality,
            averageBounceCount: bounceCount,
            averageQualityBreakdown: breakdown,
            actionCounts: actionCounts
        )
    }

    static func feedbackPlan(for sessions: [AnalysisSession]) -> TrainingFeedbackPlan {
        guard !sessions.isEmpty else {
            return TrainingFeedbackPlan(
                issues: ["暂无可分析会话。"],
                recommendations: ["先完成 1-2 场标准机位拍摄，再进入趋势复盘。"],
                nextCaptureGoal: "保证整场都在同一机位，减少变焦与遮挡。"
            )
        }

        let trend = snapshot(title: "当前样本", subtitle: "综合", sessions: sessions)
        var issues: [String] = []
        var recommendations: [String] = []

        if trend.averageVisibleRate < 0.55 {
            issues.append("球可见率偏低，关键回合可能存在漏检。")
            recommendations.append("提高拍摄稳定性并优化光照，避免快速变焦。")
        }
        if trend.averageTrackingQualityScore < 0.75 {
            issues.append("跟踪质量得分偏低，轨迹连续性不足。")
            recommendations.append("保持固定机位和构图，优先覆盖完整球场。")
        }
        if trend.averageQualityBreakdown.clampedActionStabilityScore < 0.45 {
            issues.append("动作稳定性偏低，动作分布波动较大。")
            recommendations.append("训练中固定击球模式，按正手/反手分组采样。")
        }
        if issues.isEmpty {
            issues.append("近期训练数据整体稳定。")
            recommendations.append("继续沿用当前节奏，并增加专项目标训练。")
        }

        let nextCaptureGoal: String
        if trend.averageVisibleRate < 0.6 {
            nextCaptureGoal = "下次拍摄目标：全程保持球与球员同屏，减少遮挡。"
        } else if trend.averageTrackingQualityScore < 0.8 {
            nextCaptureGoal = "下次拍摄目标：固定机位高度，避免中途移动相机。"
        } else {
            nextCaptureGoal = "下次拍摄目标：保持机位不变，增加高强度对拉样本。"
        }

        return TrainingFeedbackPlan(
            issues: issues,
            recommendations: recommendations,
            nextCaptureGoal: nextCaptureGoal
        )
    }

    static func phaseComparison(
        sessions: [AnalysisSession],
        endingOn endDate: Date = Date()
    ) -> TrainingPhaseComparisonReport? {
        guard sessions.count >= 2 else { return nil }

        let recentWindow = recentSessions(from: sessions, days: 14, endingOn: endDate)
        let baselineWindowEnd = Calendar.current.date(byAdding: .day, value: -14, to: endDate) ?? endDate
        let baselineWindow = recentSessions(from: sessions, days: 14, endingOn: baselineWindowEnd)

        let recentSessionsSet: [AnalysisSession]
        let baselineSessionsSet: [AnalysisSession]

        if !recentWindow.isEmpty && !baselineWindow.isEmpty {
            recentSessionsSet = recentWindow
            baselineSessionsSet = baselineWindow
        } else {
            let sorted = sessions.sorted { $0.eventDate < $1.eventDate }
            let splitIndex = max(1, sorted.count / 2)
            baselineSessionsSet = Array(sorted.prefix(splitIndex))
            recentSessionsSet = Array(sorted.suffix(sorted.count - splitIndex))
            if baselineSessionsSet.isEmpty || recentSessionsSet.isEmpty {
                return nil
            }
        }

        let baseline = snapshot(title: "基线阶段", subtitle: "较早样本", sessions: baselineSessionsSet)
        let recent = snapshot(title: "近期阶段", subtitle: "最新样本", sessions: recentSessionsSet)
        let visibleDelta = recent.averageVisibleRate - baseline.averageVisibleRate
        let qualityDelta = recent.averageTrackingQualityScore - baseline.averageTrackingQualityScore

        let headline: String
        if visibleDelta >= 0.03 || qualityDelta >= 0.03 {
            headline = "近期阶段整体优于基线阶段，训练与拍摄策略正在生效。"
        } else if visibleDelta <= -0.03 || qualityDelta <= -0.03 {
            headline = "近期阶段出现回落，建议先恢复稳定拍摄条件后再复测。"
        } else {
            headline = "两阶段核心指标接近，建议持续积累同机位样本。"
        }

        var wins: [String] = []
        var cautions: [String] = []
        if visibleDelta >= 0.03 {
            wins.append("球可见率提升 \(abs(visibleDelta).formatted(.percent.precision(.fractionLength(1))))。")
        } else if visibleDelta <= -0.03 {
            cautions.append("球可见率下降 \(abs(visibleDelta).formatted(.percent.precision(.fractionLength(1))))。")
        }

        if qualityDelta >= 0.03 {
            wins.append("跟踪质量得分提升 \(abs(qualityDelta).formatted(.percent.precision(.fractionLength(1))))。")
        } else if qualityDelta <= -0.03 {
            cautions.append("跟踪质量得分下降 \(abs(qualityDelta).formatted(.percent.precision(.fractionLength(1))))。")
        }

        let actionDelta = recent.averageQualityBreakdown.clampedActionStabilityScore
            - baseline.averageQualityBreakdown.clampedActionStabilityScore
        if actionDelta >= 0.05 {
            wins.append("动作稳定性改善明显。")
        } else if actionDelta <= -0.05 {
            cautions.append("动作稳定性回落，建议增加固定动作采样。")
        }

        return TrainingPhaseComparisonReport(
            baseline: baseline,
            recent: recent,
            headline: headline,
            wins: wins,
            cautions: cautions
        )
    }

    private static func averageBreakdown(for sessions: [AnalysisSession]) -> SessionQualityBreakdown {
        let count = Double(max(sessions.count, 1))
        let visible = sessions.reduce(0) { $0 + $1.resolvedQualityBreakdown.clampedVisibleRateScore } / count
        let continuity = sessions.reduce(0) { $0 + $1.resolvedQualityBreakdown.clampedContinuityScore } / count
        let inference = sessions.reduce(0) { $0 + $1.resolvedQualityBreakdown.clampedInferenceSuccessRate } / count
        let action = sessions.reduce(0) { $0 + $1.resolvedQualityBreakdown.clampedActionStabilityScore } / count
        return SessionQualityBreakdown(
            visibleRateScore: visible,
            continuityScore: continuity,
            inferenceSuccessRate: inference,
            actionStabilityScore: action
        )
    }

    private static func aggregateActions(for sessions: [AnalysisSession]) -> TrainingActionCounts {
        let allActions = sessions.compactMap(\.detectedActions).flatMap { $0 }
        return TrainingActionCounts(
            forehand: allActions.filter { $0.type == .forehand }.count,
            backhand: allActions.filter { $0.type == .backhand }.count,
            serve: allActions.filter { $0.type == .serve }.count
        )
    }
}

extension AnalysisSession {
    var resolvedQualityBreakdown: SessionQualityBreakdown {
        if let qualityBreakdown {
            return qualityBreakdown
        }

        let inferredContinuity = min(max(trackingQualityScore, 0), 1)
        let inferredInferenceRate = min(max(Double(trackedFrames) / Double(max(totalFrames, 1)), 0), 1)
        let inferredActionStability = SessionQualityBreakdownEstimator.actionStability(for: detectedActions ?? [])

        return SessionQualityBreakdown(
            visibleRateScore: ballVisibleRate,
            continuityScore: inferredContinuity,
            inferenceSuccessRate: inferredInferenceRate,
            actionStabilityScore: inferredActionStability
        )
    }

    var playbackHighlights: [SessionPlaybackHighlight] {
        var highlights: [SessionPlaybackHighlight] = []

        if let firstBounce = bouncePoints?.min(by: { $0.frameIndex < $1.frameIndex }) {
            highlights.append(
                SessionPlaybackHighlight(
                    id: "bounce-first-\(firstBounce.frameIndex)",
                    title: "首个弹跳",
                    subtitle: "帧 \(firstBounce.frameIndex)",
                    systemImage: "circle.dashed.inset.filled",
                    frameIndex: firstBounce.frameIndex
                )
            )
        }

        if let strongestAction = detectedActions?.max(by: { $0.confidence < $1.confidence }) {
            highlights.append(
                SessionPlaybackHighlight(
                    id: "action-peak-\(strongestAction.frameIndex)-\(strongestAction.type.rawValue)",
                    title: "高置信动作",
                    subtitle: "\(strongestAction.type.displayName) \(strongestAction.confidence.formatted(.number.precision(.fractionLength(2))))",
                    systemImage: "figure.tennis",
                    frameIndex: strongestAction.frameIndex
                )
            )
        }

        if let firstVisiblePoint = trajectoryPoints?.first(where: \.isVisible) {
            highlights.append(
                SessionPlaybackHighlight(
                    id: "visible-first-\(firstVisiblePoint.frameIndex)",
                    title: "首个可见球",
                    subtitle: "帧 \(firstVisiblePoint.frameIndex)",
                    systemImage: "scope",
                    frameIndex: firstVisiblePoint.frameIndex
                )
            )
        }

        let sorted = highlights.sorted { $0.frameIndex < $1.frameIndex }
        var unique: [SessionPlaybackHighlight] = []
        var seen: Set<String> = []
        for item in sorted where !seen.contains(item.id) {
            seen.insert(item.id)
            unique.append(item)
        }
        return unique
    }
}

private enum SessionQualityBreakdownEstimator {
    static func actionStability(for actions: [DetectedAction]) -> Double {
        guard !actions.isEmpty else { return 0.30 }

        let confidenceMean = actions.reduce(0) { $0 + $1.confidence } / Double(actions.count)
        let forehand = actions.filter { $0.type == .forehand }.count
        let backhand = actions.filter { $0.type == .backhand }.count
        let serve = actions.filter { $0.type == .serve }.count
        let maxCount = max(forehand, max(backhand, serve))
        let balance = Double(maxCount) / Double(max(actions.count, 1))
        let distributionScore = 1 - min(max(balance - 0.34, 0), 0.66) / 0.66

        return min(max(confidenceMean * 0.65 + distributionScore * 0.35, 0), 1)
    }
}

struct CourtMappedBounce: Identifiable, Equatable {
    let sourcePoint: InferencePoint
    let normalizedPoint: CGPoint
    let isInBounds: Bool

    var id: String {
        sourcePoint.id
    }
}

enum CourtBounceProjector {
    static func map(
        points: [InferencePoint],
        frameSize: CGSize,
        calibration: SessionCourtCalibration?
    ) -> [CourtMappedBounce] {
        points.map { point in
            let source = CGPoint(x: CGFloat(point.x), y: CGFloat(point.y))

            if let homography = calibration?.homography,
               let projected = homography.project(source) {
                let inBounds = projected.x >= 0 && projected.x <= 1 && projected.y >= 0 && projected.y <= 1
                return CourtMappedBounce(
                    sourcePoint: point,
                    normalizedPoint: projected,
                    isInBounds: inBounds
                )
            }

            let xScale = min(max(CGFloat(point.x) / max(frameSize.width - 1, 1), 0), 1)
            let yScale = min(max(CGFloat(point.y) / max(frameSize.height - 1, 1), 0), 1)
            return CourtMappedBounce(
                sourcePoint: point,
                normalizedPoint: CGPoint(x: xScale, y: yScale),
                isInBounds: true
            )
        }
    }
}

struct CourtCalibrationValidationTarget: Identifiable, Equatable {
    let id: String
    let displayName: String
    let normalizedCourtPoint: CGPoint
}

struct CourtCalibrationValidationSample: Identifiable, Equatable {
    let target: CourtCalibrationValidationTarget
    let observedSourcePoint: CGPoint
    let expectedSourcePoint: CGPoint
    let errorPixels: Double

    var id: String {
        target.id
    }
}

struct CourtCalibrationValidationResult: Equatable {
    let averageErrorPixels: Double
    let maxErrorPixels: Double
    let score: Double
    let sampleCount: Int
    let tier: CalibrationValidationTier
    let validatedAt: Date
}

extension CourtCalibrationValidationResult {
    init(sessionValidation: SessionCalibrationValidation) {
        self.averageErrorPixels = sessionValidation.averageErrorPixels
        self.maxErrorPixels = sessionValidation.maxErrorPixels
        self.score = sessionValidation.score
        self.sampleCount = sessionValidation.sampleCount
        self.tier = sessionValidation.tier
        self.validatedAt = sessionValidation.validatedAt
    }

    var sessionValidation: SessionCalibrationValidation {
        SessionCalibrationValidation(
            averageErrorPixels: averageErrorPixels,
            maxErrorPixels: maxErrorPixels,
            score: score,
            sampleCount: sampleCount,
            tier: tier,
            validatedAt: validatedAt
        )
    }
}

struct CourtCalibrationValidator {
    static let defaultTargets: [CourtCalibrationValidationTarget] = [
        CourtCalibrationValidationTarget(
            id: "net_center",
            displayName: "网带中心",
            normalizedCourtPoint: CGPoint(x: 0.5, y: 0.5)
        ),
        CourtCalibrationValidationTarget(
            id: "near_service_t",
            displayName: "近端发球 T",
            normalizedCourtPoint: CGPoint(x: 0.5, y: 0.72)
        ),
        CourtCalibrationValidationTarget(
            id: "far_service_t",
            displayName: "远端发球 T",
            normalizedCourtPoint: CGPoint(x: 0.5, y: 0.28)
        )
    ]

    static func buildResult(
        samples: [CourtCalibrationValidationSample],
        frameSize: CGSize,
        validatedAt: Date = Date()
    ) -> CourtCalibrationValidationResult? {
        guard !samples.isEmpty else { return nil }
        let errors = samples.map(\.errorPixels)
        let mean = errors.reduce(0, +) / Double(errors.count)
        let maxError = errors.max() ?? mean
        return CourtCalibrationValidationResult(
            averageErrorPixels: mean,
            maxErrorPixels: maxError,
            score: qualityScore(averageErrorPixels: mean, frameSize: frameSize),
            sampleCount: errors.count,
            tier: qualityTier(averageErrorPixels: mean, frameSize: frameSize),
            validatedAt: validatedAt
        )
    }

    static func qualityScore(averageErrorPixels: Double, frameSize: CGSize) -> Double {
        let reference = max(Double(max(frameSize.width, frameSize.height)), 1)
        let normalizedError = max(averageErrorPixels / reference, 0)
        return min(max(1 - normalizedError / 0.03, 0), 1)
    }

    static func qualityTier(averageErrorPixels: Double, frameSize: CGSize) -> CalibrationValidationTier {
        let reference = max(Double(max(frameSize.width, frameSize.height)), 1)
        let normalizedError = max(averageErrorPixels / reference, 0)
        if normalizedError <= 0.008 {
            return .high
        }
        if normalizedError <= 0.018 {
            return .medium
        }
        return .low
    }

    static func uncertaintyRadiusOnMap(
        averageErrorPixels: Double,
        frameSize: CGSize,
        mapReferenceLength: CGFloat
    ) -> CGFloat {
        guard mapReferenceLength > 0 else { return 0 }
        let frameReference = max(min(frameSize.width, frameSize.height), 1)
        let normalizedError = CGFloat(max(averageErrorPixels, 0)) / frameReference
        let scaledRadius = normalizedError * mapReferenceLength * 1.6
        let minRadius = max(mapReferenceLength * 0.015, 1.5)
        let maxRadius = mapReferenceLength * 0.24
        return min(max(scaledRadius, minRadius), maxRadius)
    }
}

enum CourtRecalibrationAdvisor {
    static func shouldRecommendRecalibration(
        calibrationScore: Double?,
        validationTier: CalibrationValidationTier?
    ) -> Bool {
        if let validationTier {
            return validationTier == .low
        }
        guard let calibrationScore else { return false }
        return calibrationScore < 0.64
    }

    static func recommendationText(
        calibrationScore: Double?,
        validationTier: CalibrationValidationTier?
    ) -> String {
        if let validationTier, validationTier == .low {
            return "验证结果偏低，建议重新自动标定后再看落点。"
        }
        if let calibrationScore, calibrationScore < 0.64 {
            return "当前标定质量较低，落点可能偏移，建议重新自动标定。"
        }
        return "当前落点映射稳定。"
    }
}

private enum CourtGeometry {
    static func distance(_ p0: CGPoint, _ p1: CGPoint) -> CGFloat {
        let dx = p1.x - p0.x
        let dy = p1.y - p0.y
        return sqrt(dx * dx + dy * dy)
    }

    static func polygonArea(_ points: [CGPoint]) -> CGFloat {
        guard points.count >= 3 else { return 0 }
        var sum: CGFloat = 0
        for index in 0..<points.count {
            let next = (index + 1) % points.count
            sum += points[index].x * points[next].y - points[next].x * points[index].y
        }
        return 0.5 * sum
    }

    static func medianPoint(_ points: [CGPoint]) -> CGPoint {
        guard !points.isEmpty else { return .zero }
        let sortedX = points.map(\.x).sorted()
        let sortedY = points.map(\.y).sorted()
        let middle = points.count / 2
        if points.count.isMultiple(of: 2) {
            return CGPoint(
                x: (sortedX[middle - 1] + sortedX[middle]) * 0.5,
                y: (sortedY[middle - 1] + sortedY[middle]) * 0.5
            )
        }
        return CGPoint(x: sortedX[middle], y: sortedY[middle])
    }
}

struct CourtCalibrationQualityEstimator {
    static func estimate(
        corners: [CGPoint],
        frameSize: CGSize,
        modelPrior: Double,
        detectorScore: Double = 0
    ) -> Double {
        guard corners.count == 4 else {
            return clamp(modelPrior * 0.6 + detectorScore * 0.4, min: 0, max: 1)
        }

        let frameArea = max(frameSize.width * frameSize.height, 1)
        let quadArea = max(abs(CourtGeometry.polygonArea(corners)), 1)
        let coverage = clamp(Double(quadArea / frameArea) / 0.28, min: 0, max: 1)

        var edgeLengths: [CGFloat] = []
        for index in 0..<corners.count {
            let next = (index + 1) % corners.count
            edgeLengths.append(CourtGeometry.distance(corners[index], corners[next]))
        }
        let minEdge = edgeLengths.min() ?? 0
        let maxEdge = edgeLengths.max() ?? 1
        let edgeUniformity = maxEdge > 0 ? Double(minEdge / maxEdge) : 0

        let diagonal1 = CourtGeometry.distance(corners[0], corners[2])
        let diagonal2 = CourtGeometry.distance(corners[1], corners[3])
        let diagonalBalance = max(diagonal1, diagonal2) > 0
            ? Double(min(diagonal1, diagonal2) / max(diagonal1, diagonal2))
            : 0

        let nearWidth = CourtGeometry.distance(corners[0], corners[1])
        let farWidth = CourtGeometry.distance(corners[2], corners[3])
        let widthRatio = nearWidth > 0 ? Double(nearWidth / max(farWidth, 1)) : 0
        let perspectiveScore = clamp(1 - abs(widthRatio - 1.55) / 1.55, min: 0, max: 1)

        let normalizedModelPrior = clamp(modelPrior, min: 0, max: 1)
        let normalizedDetectorScore = clamp(detectorScore, min: 0, max: 1)

        return clamp(
            coverage * 0.30
                + edgeUniformity * 0.18
                + diagonalBalance * 0.16
                + perspectiveScore * 0.20
                + normalizedModelPrior * 0.08
                + normalizedDetectorScore * 0.08,
            min: 0,
            max: 1
        )
    }

    private static func clamp(_ value: Double, min lower: Double, max upper: Double = 1) -> Double {
        Swift.min(Swift.max(value, lower), upper)
    }
}

struct AutoCourtCalibrationResult: Equatable {
    let calibration: SessionCourtCalibration
    let sampleCount: Int
    let validDetections: Int
    let anchorFrameIndex: Int
    let detectorScore: Double
}

enum AutoCourtCalibratorError: LocalizedError {
    case missingVideoTrack
    case frameSamplingFailed
    case noCourtDetected

    var errorDescription: String? {
        switch self {
        case .missingVideoTrack:
            return "视频里没有可用于自动标定的轨道。"
        case .frameSamplingFailed:
            return "自动标定无法从视频中抽取有效画面。"
        case .noCourtDetected:
            return "自动标定未识别到稳定球场。"
        }
    }
}

struct AutoCourtCalibrator {
    struct Candidate: Equatable {
        let sourceCorners: [CGPoint]
        let normalizedDetectorScore: Double
        let frameIndex: Int
        let frameSize: CGSize
    }

    private let maxSamples: Int
    private let detectorContext: CIContext

    init(
        maxSamples: Int = 14,
        detectorContext: CIContext = CIContext(options: [.useSoftwareRenderer: false])
    ) {
        self.maxSamples = max(maxSamples, 4)
        self.detectorContext = detectorContext
    }

    func calibrate(
        videoURL: URL,
        trackingQualityScore: Double,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> AutoCourtCalibrationResult {
        let asset = AVURLAsset(url: videoURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else {
            throw AutoCourtCalibratorError.missingVideoTrack
        }

        let duration = try await asset.load(.duration)
        let durationSeconds = max(CMTimeGetSeconds(duration), 0.1)
        let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
        let nominalFPS = nominalFrameRate > 0 ? Double(nominalFrameRate) : 30
        let totalFrames = max(Int((durationSeconds * nominalFPS).rounded()), 1)
        let frames = try await sampleFrames(from: asset, totalFrames: totalFrames)

        var detections: [Candidate] = []
        for (index, frame) in frames.enumerated() {
            try Task.checkCancellation()
            if let candidate = detectCandidate(in: frame.image, frameIndex: frame.frameIndex) {
                detections.append(candidate)
            }
            progress(Double(index + 1) / Double(max(frames.count, 1)))
        }

        guard let merged = Self.aggregate(candidates: detections) else {
            throw AutoCourtCalibratorError.noCourtDetected
        }

        guard let homography = CourtHomography.solve(
            source: merged.sourceCorners,
            destination: [
                CGPoint(x: 0, y: 1),
                CGPoint(x: 1, y: 1),
                CGPoint(x: 1, y: 0),
                CGPoint(x: 0, y: 0)
            ]
        ) else {
            throw AutoCourtCalibratorError.noCourtDetected
        }

        let quality = CourtCalibrationQualityEstimator.estimate(
            corners: merged.sourceCorners,
            frameSize: merged.frameSize,
            modelPrior: trackingQualityScore,
            detectorScore: merged.normalizedDetectorScore
        )

        return AutoCourtCalibrationResult(
            calibration: SessionCourtCalibration(
                sourceCorners: merged.sourceCorners,
                homography: homography,
                qualityScore: quality,
                calibratedAt: Date()
            ),
            sampleCount: frames.count,
            validDetections: detections.count,
            anchorFrameIndex: merged.frameIndex,
            detectorScore: merged.normalizedDetectorScore
        )
    }

    private func detectCandidate(in image: CGImage, frameIndex: Int) -> Candidate? {
        let frameSize = CGSize(width: image.width, height: image.height)
        let variants = preprocessVariants(for: image)
        var best: Candidate?

        for variant in variants {
            let observations = rectangleObservations(in: variant)
            for observation in observations {
                let corners = Self.convertObservation(observation, imageSize: frameSize)
                guard Self.isCourtLike(corners: corners, frameSize: frameSize) else { continue }

                let candidate = Candidate(
                    sourceCorners: corners,
                    normalizedDetectorScore: Self.normalizedScore(
                        for: corners,
                        frameSize: frameSize,
                        observationConfidence: Double(observation.confidence)
                    ),
                    frameIndex: frameIndex,
                    frameSize: frameSize
                )

                if let best, best.normalizedDetectorScore >= candidate.normalizedDetectorScore {
                    continue
                }
                best = candidate
            }
        }

        return best
    }

    private func rectangleObservations(in image: CGImage) -> [VNRectangleObservation] {
        let request = VNDetectRectanglesRequest()
        request.maximumObservations = 18
        request.minimumConfidence = 0.15
        request.minimumAspectRatio = 0.30
        request.maximumAspectRatio = 1.0
        request.quadratureTolerance = 28
        request.minimumSize = 0.16
        request.regionOfInterest = CGRect(x: 0.02, y: 0.04, width: 0.96, height: 0.92)

        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        return request.results ?? []
    }

    private func preprocessVariants(for image: CGImage) -> [CGImage] {
        let baseImage = CIImage(cgImage: image)
        let baseExtent = baseImage.extent

        let contrastBoost = baseImage
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 0.0,
                kCIInputContrastKey: 2.2,
                kCIInputBrightnessKey: 0.03
            ])
            .applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputHighlightAmount": 1.0,
                "inputShadowAmount": 0.0
            ])
            .applyingFilter("CISharpenLuminance", parameters: [
                kCIInputSharpnessKey: 0.75
            ])

        let exposed = baseImage
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 0.0,
                kCIInputContrastKey: 1.8,
                kCIInputBrightnessKey: 0.08
            ])
            .applyingFilter("CIExposureAdjust", parameters: [
                kCIInputEVKey: 0.55
            ])

        var variants: [CGImage] = [image]
        if let rendered = detectorContext.createCGImage(contrastBoost, from: baseExtent) {
            variants.append(rendered)
        }
        if let rendered = detectorContext.createCGImage(exposed, from: baseExtent) {
            variants.append(rendered)
        }
        return variants
    }

    private func sampleFrames(
        from asset: AVAsset,
        totalFrames: Int
    ) async throws -> [(frameIndex: Int, image: CGImage)] {
        let duration = try await asset.load(.duration)
        let durationSeconds = max(CMTimeGetSeconds(duration), 0.1)
        let sampleCount = max(5, min(maxSamples, Int(durationSeconds * 1.5)))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.04, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.04, preferredTimescale: 600)

        var frames: [(frameIndex: Int, image: CGImage)] = []
        for index in 0..<sampleCount {
            try Task.checkCancellation()
            let ratio = sampleCount == 1 ? 0.5 : Double(index) / Double(sampleCount - 1)
            let seconds = ratio * max(durationSeconds - 0.01, 0)
            let frameIndex = min(max(Int((ratio * Double(max(totalFrames - 1, 1))).rounded()), 0), max(totalFrames - 1, 0))
            let time = CMTime(seconds: seconds, preferredTimescale: 600)

            do {
                let frame = try await generateFrame(generator: generator, at: time)
                frames.append((frameIndex: frameIndex, image: frame))
            } catch {
                continue
            }
        }

        guard !frames.isEmpty else {
            throw AutoCourtCalibratorError.frameSamplingFailed
        }
        return frames
    }

    private func generateFrame(generator: AVAssetImageGenerator, at time: CMTime) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            generator.generateCGImageAsynchronously(for: time) { image, _, error in
                if let image {
                    continuation.resume(returning: image)
                    return
                }
                continuation.resume(
                    throwing: error ?? AutoCourtCalibratorError.frameSamplingFailed
                )
            }
        }
    }

    static func aggregate(candidates: [Candidate]) -> Candidate? {
        guard let anchor = candidates.max(by: { $0.normalizedDetectorScore < $1.normalizedDetectorScore }) else {
            return nil
        }

        let anchorTopY = 0.5 * (anchor.sourceCorners[2].y + anchor.sourceCorners[3].y)
        let anchorBottomY = 0.5 * (anchor.sourceCorners[0].y + anchor.sourceCorners[1].y)
        let tolerance = max(anchor.frameSize.height * 0.06, 18)

        let similar = candidates.filter { candidate in
            let topY = 0.5 * (candidate.sourceCorners[2].y + candidate.sourceCorners[3].y)
            let bottomY = 0.5 * (candidate.sourceCorners[0].y + candidate.sourceCorners[1].y)
            return abs(topY - anchorTopY) <= tolerance
                && abs(bottomY - anchorBottomY) <= tolerance
        }

        let pool = similar.isEmpty ? [anchor] : similar
        let aggregatedCorners = (0..<4).map { index in
            CourtGeometry.medianPoint(pool.map { $0.sourceCorners[index] })
        }
        let medianScore = pool.map(\.normalizedDetectorScore).sorted()
        let middle = medianScore.count / 2
        let score = medianScore.count.isMultiple(of: 2)
            ? 0.5 * (medianScore[middle - 1] + medianScore[middle])
            : medianScore[middle]

        return Candidate(
            sourceCorners: aggregatedCorners,
            normalizedDetectorScore: score,
            frameIndex: anchor.frameIndex,
            frameSize: anchor.frameSize
        )
    }

    static func convertObservation(_ observation: VNRectangleObservation, imageSize: CGSize) -> [CGPoint] {
        let topLeft = denormalize(observation.topLeft, imageSize: imageSize)
        let topRight = denormalize(observation.topRight, imageSize: imageSize)
        let bottomRight = denormalize(observation.bottomRight, imageSize: imageSize)
        let bottomLeft = denormalize(observation.bottomLeft, imageSize: imageSize)
        return [bottomLeft, bottomRight, topRight, topLeft]
    }

    static func isCourtLike(corners: [CGPoint], frameSize: CGSize) -> Bool {
        guard corners.count == 4 else { return false }

        let nearLeft = corners[0]
        let nearRight = corners[1]
        let farRight = corners[2]
        let farLeft = corners[3]

        let bottomWidth = CourtGeometry.distance(nearLeft, nearRight)
        let topWidth = CourtGeometry.distance(farLeft, farRight)
        let verticalSpan = 0.5 * ((nearLeft.y + nearRight.y) - (farLeft.y + farRight.y))

        guard bottomWidth >= frameSize.width * 0.26 else { return false }
        guard topWidth >= frameSize.width * 0.10 else { return false }
        guard verticalSpan >= frameSize.height * 0.18 else { return false }
        guard nearLeft.x < nearRight.x, farLeft.x < farRight.x else { return false }
        guard farLeft.x > nearLeft.x - frameSize.width * 0.12 else { return false }
        guard farRight.x < nearRight.x + frameSize.width * 0.12 else { return false }
        guard nearLeft.y > farLeft.y, nearRight.y > farRight.y else { return false }

        let widthRatio = Double(bottomWidth / max(topWidth, 1))
        guard (1.05...3.4).contains(widthRatio) else { return false }

        let quadArea = abs(CourtGeometry.polygonArea(corners))
        guard quadArea >= frameSize.width * frameSize.height * 0.05 else { return false }

        return true
    }

    static func normalizedScore(
        for corners: [CGPoint],
        frameSize: CGSize,
        observationConfidence: Double
    ) -> Double {
        guard isCourtLike(corners: corners, frameSize: frameSize) else { return 0 }

        let quadArea = abs(CourtGeometry.polygonArea(corners))
        let areaScore = clamp(Double(quadArea / max(frameSize.width * frameSize.height, 1)) / 0.22, min: 0, max: 1)

        let bottomWidth = CourtGeometry.distance(corners[0], corners[1])
        let topWidth = CourtGeometry.distance(corners[2], corners[3])
        let widthRatio = Double(bottomWidth / max(topWidth, 1))
        let ratioScore = clamp(1 - abs(widthRatio - 1.65) / 1.65, min: 0, max: 1)

        let verticalSpan = Double(0.5 * ((corners[0].y + corners[1].y) - (corners[2].y + corners[3].y)))
        let spanScore = clamp(verticalSpan / Double(max(frameSize.height, 1) * 0.42), min: 0, max: 1)
        let confidenceScore = clamp(observationConfidence, min: 0, max: 1)

        return clamp(
            areaScore * 0.36
                + ratioScore * 0.24
                + spanScore * 0.24
                + confidenceScore * 0.16,
            min: 0,
            max: 1
        )
    }

    private static func denormalize(_ point: CGPoint, imageSize: CGSize) -> CGPoint {
        CGPoint(
            x: point.x * imageSize.width,
            y: (1 - point.y) * imageSize.height
        )
    }

    private static func clamp(_ value: Double, min lower: Double, max upper: Double = 1) -> Double {
        Swift.min(Swift.max(value, lower), upper)
    }
}

struct CourtHomography: Codable, Equatable {
    let h11: Double
    let h12: Double
    let h13: Double
    let h21: Double
    let h22: Double
    let h23: Double
    let h31: Double
    let h32: Double
    let h33: Double

    func project(_ point: CGPoint) -> CGPoint? {
        let x = Double(point.x)
        let y = Double(point.y)
        let denominator = h31 * x + h32 * y + h33
        guard abs(denominator) > 1e-8 else { return nil }
        let mappedX = (h11 * x + h12 * y + h13) / denominator
        let mappedY = (h21 * x + h22 * y + h23) / denominator
        guard mappedX.isFinite, mappedY.isFinite else { return nil }
        return CGPoint(x: CGFloat(mappedX), y: CGFloat(mappedY))
    }

    func inverted() -> CourtHomography? {
        let a = h11
        let b = h12
        let c = h13
        let d = h21
        let e = h22
        let f = h23
        let g = h31
        let h = h32
        let i = h33

        let c11 = e * i - f * h
        let c12 = -(d * i - f * g)
        let c13 = d * h - e * g
        let c21 = -(b * i - c * h)
        let c22 = a * i - c * g
        let c23 = -(a * h - b * g)
        let c31 = b * f - c * e
        let c32 = -(a * f - c * d)
        let c33 = a * e - b * d

        let determinant = a * c11 + b * c12 + c * c13
        guard abs(determinant) > 1e-12 else { return nil }

        return CourtHomography(
            h11: c11 / determinant,
            h12: c21 / determinant,
            h13: c31 / determinant,
            h21: c12 / determinant,
            h22: c22 / determinant,
            h23: c32 / determinant,
            h31: c13 / determinant,
            h32: c23 / determinant,
            h33: c33 / determinant
        )
    }

    static func solve(source: [CGPoint], destination: [CGPoint]) -> CourtHomography? {
        guard source.count == 4, destination.count == 4 else { return nil }

        var matrix = Array(repeating: Array(repeating: 0.0, count: 8), count: 8)
        var vector = Array(repeating: 0.0, count: 8)

        for index in 0..<4 {
            let x = Double(source[index].x)
            let y = Double(source[index].y)
            let u = Double(destination[index].x)
            let v = Double(destination[index].y)

            let row = index * 2
            matrix[row][0] = x
            matrix[row][1] = y
            matrix[row][2] = 1
            matrix[row][3] = 0
            matrix[row][4] = 0
            matrix[row][5] = 0
            matrix[row][6] = -x * u
            matrix[row][7] = -y * u
            vector[row] = u

            matrix[row + 1][0] = 0
            matrix[row + 1][1] = 0
            matrix[row + 1][2] = 0
            matrix[row + 1][3] = x
            matrix[row + 1][4] = y
            matrix[row + 1][5] = 1
            matrix[row + 1][6] = -x * v
            matrix[row + 1][7] = -y * v
            vector[row + 1] = v
        }

        guard let solution = gaussianElimination(matrix: matrix, vector: vector) else {
            return nil
        }

        return CourtHomography(
            h11: solution[0],
            h12: solution[1],
            h13: solution[2],
            h21: solution[3],
            h22: solution[4],
            h23: solution[5],
            h31: solution[6],
            h32: solution[7],
            h33: 1
        )
    }

    private static func gaussianElimination(
        matrix: [[Double]],
        vector: [Double]
    ) -> [Double]? {
        let n = vector.count
        var a = matrix
        var b = vector

        for pivotIndex in 0..<n {
            var maxRow = pivotIndex
            var maxValue = abs(a[pivotIndex][pivotIndex])
            for row in (pivotIndex + 1)..<n {
                let value = abs(a[row][pivotIndex])
                if value > maxValue {
                    maxValue = value
                    maxRow = row
                }
            }

            guard maxValue > 1e-12 else { return nil }

            if maxRow != pivotIndex {
                a.swapAt(pivotIndex, maxRow)
                b.swapAt(pivotIndex, maxRow)
            }

            let pivot = a[pivotIndex][pivotIndex]
            for column in pivotIndex..<n {
                a[pivotIndex][column] /= pivot
            }
            b[pivotIndex] /= pivot

            for row in 0..<n where row != pivotIndex {
                let factor = a[row][pivotIndex]
                if abs(factor) < 1e-12 { continue }
                for column in pivotIndex..<n {
                    a[row][column] -= factor * a[pivotIndex][column]
                }
                b[row] -= factor * b[pivotIndex]
            }
        }

        return b
    }
}
