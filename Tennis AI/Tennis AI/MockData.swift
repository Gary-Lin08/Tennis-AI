//
//  MockData.swift
//  Tennis AI
//
//  Created by Codex on 2026/3/11.
//

import Combine
import Foundation
import SwiftUI

@MainActor
final class TennisAIViewModel: ObservableObject {
    @Published var sessions: [AnalysisSession]
    @Published var drills: [DrillRecommendation]
    @Published var jobs: [LocalAnalysisJob]
    @Published private(set) var modelStatus: OnDeviceModelStatus = .checking
    @Published private(set) var modelDiagnostics: LoadedModelDiagnostics?
    @Published private(set) var latestInferenceSummary: OnDeviceInferenceSummary?
    @Published private(set) var latestInferenceDate: Date?
    @Published private(set) var inferenceProfile: OnDeviceInferenceProfile = .balanced
    @Published var backendUploadEndpoint: String
    @Published var backendUploadUserID: String
    @Published var localAnalyticsUserID: String
    @Published private(set) var backendConfigMessage: String?
    @Published private(set) var cloudSyncStates: [UUID: CloudSyncState] = [:]
    @Published private(set) var telemetryUploadMessage: String?
    @Published private(set) var telemetryPendingEventsCount: Int = 0

    private let fileManager = FileManager.default
    private var runningTasks: [UUID: Task<Void, Never>] = [:]
    private var syncTasks: [UUID: Task<Void, Never>] = [:]
    private var loadedModel: LoadedOnDeviceModel?
    private let modelLoader: OnDeviceModelLoader
    private let backendUploader: BackendUploader
    private let remoteAnalysisService: RemoteAnalysisService
    private let telemetry: AppTelemetryManager
    private let defaults: UserDefaults
    private static let backendEndpointDefaultsKey = "backend_upload_endpoint"
    private static let backendUserIDDefaultsKey = "backend_upload_user_id"
    private static let localAnalyticsUserIDDefaultsKey = "local_analytics_user_id"
    private static let inferenceProfileDefaultsKey = "on_device_inference_profile"
    private static let demoModeVisibilityDefaultsKey = "demo_mode_visibility"
    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private var sessionsStoreURL: URL {
        Self.documentsDirectory.appendingPathComponent("analysis_sessions_local.json")
    }
    private var videoLibraryDirectory: URL {
        Self.documentsDirectory.appendingPathComponent("TrainingVideoLibrary", isDirectory: true)
    }

    static func backendConfigSavedMessage(summarySyncEnabled: Bool) -> String {
        if summarySyncEnabled {
            return "后端配置已保存，行为埋点与自动远端结构化分析已启用；legacy user_id 已保留作兼容字段。"
        }
        return "已保存：行为埋点与自动远端结构化分析已启用；未填写 legacy user_id。"
    }

    init(
        sessions: [AnalysisSession]? = nil,
        drills: [DrillRecommendation]? = nil,
        jobs: [LocalAnalysisJob] = [],
        modelLoader: OnDeviceModelLoader? = nil,
        defaults: UserDefaults = .standard,
        backendUploader: BackendUploader? = nil,
        remoteAnalysisService: RemoteAnalysisService? = nil,
        telemetry: AppTelemetryManager? = nil
    ) {
        self.defaults = defaults
        self.backendUploader = backendUploader ?? BackendUploader()
        self.remoteAnalysisService = remoteAnalysisService ?? RemoteAnalysisService()
        self.telemetry = telemetry ?? .shared
        self.backendUploadEndpoint = defaults.string(forKey: Self.backendEndpointDefaultsKey) ?? ""
        self.backendUploadUserID = defaults.string(forKey: Self.backendUserIDDefaultsKey) ?? ""
        self.localAnalyticsUserID = defaults.string(forKey: Self.localAnalyticsUserIDDefaultsKey)
        ?? "local-\(UUID().uuidString.prefix(8).lowercased())"
        let demoMode = DemoModeVisibility(rawValue: defaults.string(forKey: Self.demoModeVisibilityDefaultsKey) ?? "") ?? .hidden
        let initialSessions = sessions ?? (demoMode == .visible ? MockData.sessions : [])
        let initialDrills = drills ?? MockData.drills
        let localSessions = Self.loadPersistedLocalSessions()
        self.sessions = Self.merge(base: initialSessions, with: localSessions).sorted { $0.eventDate > $1.eventDate }
        self.drills = initialDrills
        self.jobs = jobs.sorted { $0.createdAt > $1.createdAt }
        self.modelLoader = modelLoader ?? OnDeviceModelLoader()
        self.telemetry.configure(endpointRaw: self.backendUploadEndpoint, localUserIDRaw: self.localAnalyticsUserID)
        self.telemetryUploadMessage = self.telemetry.lastUploadMessage
        self.telemetryPendingEventsCount = self.telemetry.pendingEventsCount
        if
            let profileRaw = defaults.string(forKey: Self.inferenceProfileDefaultsKey),
            let savedProfile = OnDeviceInferenceProfile(rawValue: profileRaw) {
            self.inferenceProfile = savedProfile
        }
        loadOnDeviceModel()
        Task { [weak self] in
            await self?.refreshRemoteSessionsIfPossible()
        }
    }

    var latestSession: AnalysisSession? {
        sessions.first
    }

    var averageVisibleRate: Double {
        guard !sessions.isEmpty else { return 0 }
        let total = sessions.reduce(0) { partial, session in
            partial + session.ballVisibleRate
        }
        return total / Double(sessions.count)
    }

    var averageCourtScore: Double {
        guard !sessions.isEmpty else { return 0 }
        let total = sessions.reduce(0) { partial, session in
            partial + session.trackingQualityScore
        }
        return total / Double(sessions.count)
    }

    var totalTrackedFrames: Int {
        sessions.reduce(0) { partial, session in
            partial + session.trackedFrames
        }
    }

    var processingCount: Int {
        jobs.filter { $0.state == .queued || $0.state == .running }.count
    }

    var completedCount: Int {
        sessions.count
    }

    var activeJobs: [LocalAnalysisJob] {
        jobs.filter { $0.state == .queued || $0.state == .running }
    }

    var finishedJobs: [LocalAnalysisJob] {
        jobs.filter { $0.state == .completed || $0.state == .failed }
    }

    var focusHint: String {
        trainingFeedbackPlan.issues.first ?? "当前训练数据稳定，可继续做阶段趋势复盘。"
    }

    var trendSnapshots: [TrainingTrendSnapshot] {
        [
            TrainingInsights.snapshot(
                title: "最近 7 天",
                subtitle: "短期训练趋势",
                sessions: TrainingInsights.recentSessions(from: sessions, days: 7)
            ),
            TrainingInsights.snapshot(
                title: "最近 30 天",
                subtitle: "阶段训练趋势",
                sessions: TrainingInsights.recentSessions(from: sessions, days: 30)
            )
        ].filter(\.hasData)
    }

    var trainingFeedbackPlan: TrainingFeedbackPlan {
        let focusSessions = TrainingInsights.recentSessions(from: sessions, days: 30)
        return TrainingInsights.feedbackPlan(for: focusSessions.isEmpty ? sessions : focusSessions)
    }

    var defaultPhaseComparisonReport: TrainingPhaseComparisonReport? {
        TrainingInsights.phaseComparison(sessions: sessions)
    }

    func phaseComparisonReport(endingOn date: Date) -> TrainingPhaseComparisonReport? {
        TrainingInsights.phaseComparison(sessions: sessions, endingOn: date)
    }

    var backendConfigured: Bool {
        resolvedRemoteAnalysisConfig() != nil
    }

    var telemetryConfigured: Bool {
        AppTelemetryManager.normalizedEventsEndpoint(from: backendUploadEndpoint) != nil
    }

    func cloudSyncState(for jobID: UUID) -> CloudSyncState? {
        cloudSyncStates[jobID]
    }

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            telemetry.appDidBecomeActive()
            Task { [weak self] in
                await self?.refreshRemoteSessionsIfPossible()
            }
        case .background, .inactive:
            telemetry.appWillMoveToBackground()
        @unknown default:
            break
        }
        telemetryUploadMessage = telemetry.lastUploadMessage
        telemetryPendingEventsCount = telemetry.pendingEventsCount
    }

    func trackScreenAppear(_ screen: String) {
        telemetry.trackScreenView(screen: screen)
        telemetryUploadMessage = telemetry.lastUploadMessage
        telemetryPendingEventsCount = telemetry.pendingEventsCount
    }

    func trackScreenLeave(_ screen: String) {
        telemetry.trackScreenLeave(screen: screen)
        telemetryUploadMessage = telemetry.lastUploadMessage
        telemetryPendingEventsCount = telemetry.pendingEventsCount
    }

    func trackTap(screen: String, target: String, metadata: [String: String] = [:]) {
        telemetry.trackTap(screen: screen, target: target, metadata: metadata)
        telemetryUploadMessage = telemetry.lastUploadMessage
        telemetryPendingEventsCount = telemetry.pendingEventsCount
    }

    func updateInferenceProfile(_ profile: OnDeviceInferenceProfile) {
        guard inferenceProfile != profile else { return }
        inferenceProfile = profile
        defaults.set(profile.rawValue, forKey: Self.inferenceProfileDefaultsKey)
        backendConfigMessage = "推理策略已切换为\(profile.displayName)。"
    }

    func saveBackendConfig() {
        let endpointRaw = backendUploadEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let userIDRaw = backendUploadUserID.trimmingCharacters(in: .whitespacesAndNewlines)
        let localUserRaw = localAnalyticsUserID.trimmingCharacters(in: .whitespacesAndNewlines)

        if endpointRaw.isEmpty && userIDRaw.isEmpty && localUserRaw.isEmpty {
            defaults.removeObject(forKey: Self.backendEndpointDefaultsKey)
            defaults.removeObject(forKey: Self.backendUserIDDefaultsKey)
            defaults.removeObject(forKey: Self.localAnalyticsUserIDDefaultsKey)
            telemetry.configure(endpointRaw: "", localUserIDRaw: "")
            telemetryUploadMessage = telemetry.lastUploadMessage
            telemetryPendingEventsCount = telemetry.pendingEventsCount
            backendConfigMessage = "已清空后端配置。"
            return
        }

        guard !endpointRaw.isEmpty else {
            backendConfigMessage = "请至少填写后端 URL。"
            return
        }

        guard AppTelemetryManager.normalizedEventsEndpoint(from: endpointRaw) != nil else {
            backendConfigMessage = "后端 URL 格式无效。"
            return
        }

        if !userIDRaw.isEmpty, UUID(uuidString: userIDRaw) == nil {
            backendConfigMessage = "legacy user_id 不是合法 UUID（可留空，仅保留自动远端分析与埋点）。"
            return
        }

        let normalizedLocalUser = localUserRaw.isEmpty ? "local-\(UUID().uuidString.prefix(8).lowercased())" : localUserRaw

        backendUploadEndpoint = endpointRaw
        backendUploadUserID = userIDRaw.lowercased()
        localAnalyticsUserID = normalizedLocalUser
        defaults.set(backendUploadEndpoint, forKey: Self.backendEndpointDefaultsKey)
        defaults.set(backendUploadUserID, forKey: Self.backendUserIDDefaultsKey)
        defaults.set(localAnalyticsUserID, forKey: Self.localAnalyticsUserIDDefaultsKey)

        telemetry.configure(endpointRaw: backendUploadEndpoint, localUserIDRaw: localAnalyticsUserID)
        telemetry.flush(force: true)
        telemetryUploadMessage = telemetry.lastUploadMessage
        telemetryPendingEventsCount = telemetry.pendingEventsCount

        backendConfigMessage = Self.backendConfigSavedMessage(
            summarySyncEnabled: !backendUploadUserID.isEmpty
        )
        uploadPendingCompletedJobs()
        Task { [weak self] in
            await self?.refreshRemoteSessionsIfPossible()
        }
    }

    func retryCloudUpload(jobID: UUID) {
        guard resolvedRemoteAnalysisConfig() != nil else {
            cloudSyncStates[jobID] = .failed(message: "自动远端分析未启用：请先填写后端 URL。")
            return
        }

        guard
            let job = job(id: jobID),
            job.state == .completed,
            let sessionID = job.resultSessionID,
            let resultSession = session(id: sessionID)
        else {
            cloudSyncStates[jobID] = .failed(message: "任务尚未完成，暂时无法上传。")
            return
        }

        scheduleCloudUpload(jobID: jobID, session: resultSession, force: true)
    }

    @discardableResult
    func enqueueVideo(url: URL, source: VideoInputSource = .upload) throws -> UUID {
        let persistedURL = try persistVideoToLibrary(from: url)
        let jobID = UUID()
        let job = LocalAnalysisJob(
            id: jobID,
            fileName: url.lastPathComponent,
            inputSource: source,
            videoLocalPath: persistedURL.path,
            createdAt: Date(),
            updatedAt: Date(),
            stage: .queued,
            state: .queued,
            progress: 0.03,
            resultSessionID: nil,
            errorMessage: nil,
            failureCategory: nil
        )

        jobs.insert(job, at: 0)

        if let blockedMessage = modelStatus.uploadBlockedMessage {
            updateJob(jobID: jobID) { job in
                job.state = .failed
                job.stage = .failed
                job.progress = 1.0
                job.errorMessage = blockedMessage
                job.failureCategory = .modelMissing
                job.updatedAt = Date()
            }
            return jobID
        }

        guard loadedModel != nil else {
            updateJob(jobID: jobID) { job in
                job.state = .failed
                job.stage = .failed
                job.progress = 1.0
                job.errorMessage = "模型状态异常：已显示就绪但未能取得模型实例。请重启应用后重试。"
                job.failureCategory = .modelMissing
                job.updatedAt = Date()
            }
            return jobID
        }

        startPipeline(jobID: jobID, sourceURL: persistedURL)
        return jobID
    }

    func job(id: UUID) -> LocalAnalysisJob? {
        jobs.first { $0.id == id }
    }

    func session(id: UUID) -> AnalysisSession? {
        sessions.first { $0.id == id }
    }

    func updateSessionCalibrationValidation(sessionID: UUID, validation: SessionCalibrationValidation?) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        withAnimation(.easeInOut(duration: 0.20)) {
            sessions[index].calibrationValidation = validation
        }
        savePersistedLocalSessions()
    }

    func updateSessionCourtCalibration(sessionID: UUID, calibration: SessionCourtCalibration?) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        withAnimation(.easeInOut(duration: 0.20)) {
            sessions[index].courtCalibration = calibration
            if calibration == nil {
                sessions[index].calibrationValidation = nil
            }
        }
        savePersistedLocalSessions()
    }

    func sessions(on date: Date) -> [AnalysisSession] {
        let calendar = Calendar.current
        return sessions
            .filter { calendar.isDate($0.eventDate, inSameDayAs: date) }
            .sorted { $0.eventDate > $1.eventDate }
    }

    private func startPipeline(jobID: UUID, sourceURL: URL) {
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runPipeline(jobID: jobID, sourceURL: sourceURL)
        }
        runningTasks[jobID] = task
    }

    private func runPipeline(jobID: UUID, sourceURL: URL) async {
        await animate(jobID: jobID, stage: .extractingFrames, target: 0.24, duration: 0.9)

        guard let loadedModel else {
            finishJobAsFailed(jobID: jobID, category: .modelMissing, message: "模型实例不可用，请重启应用后重试。")
            return
        }

        let analyzer = OnDeviceVideoAnalyzer(profile: inferenceProfile)
        let inferenceSummary: OnDeviceInferenceSummary

        do {
            inferenceSummary = try await analyzer.analyze(videoURL: sourceURL, loadedModel: loadedModel) { ratio in
                updateJob(jobID: jobID) { job in
                    job.state = .running
                    job.stage = .trackingBall
                    job.progress = 0.24 + ratio * 0.46
                    job.updatedAt = Date()
                }
            }
        } catch let error as OnDeviceVideoAnalyzerError {
            finishJobAsFailed(
                jobID: jobID,
                category: error.failureCategory,
                message: "本地推理失败：\(error.localizedDescription)"
            )
            return
        } catch {
            finishJobAsFailed(jobID: jobID, category: .inferenceFailed, message: "本地推理失败：\(error.localizedDescription)")
            return
        }

        latestInferenceSummary = inferenceSummary
        latestInferenceDate = Date()

        let autoCalibration: AutoCourtCalibrationResult?
        updateJob(jobID: jobID) { job in
            job.state = .running
            job.stage = .detectingCourt
            job.progress = max(job.progress, 0.70)
            job.updatedAt = Date()
        }
        do {
            let calibrator = AutoCourtCalibrator()
            autoCalibration = try await calibrator.calibrate(
                videoURL: sourceURL,
                trackingQualityScore: inferenceSummary.trackingQualityScore
            ) { ratio in
                Task { @MainActor in
                    self.updateJob(jobID: jobID) { job in
                        job.state = .running
                        job.stage = .detectingCourt
                        job.progress = 0.70 + ratio * 0.18
                        job.updatedAt = Date()
                    }
                }
            }
        } catch is CancellationError {
            runningTasks[jobID] = nil
            return
        } catch {
            autoCalibration = nil
            updateJob(jobID: jobID) { job in
                job.state = .running
                job.stage = .detectingCourt
                job.progress = max(job.progress, 0.88)
                job.updatedAt = Date()
            }
        }
        await animate(jobID: jobID, stage: .generatingSummary, target: 0.98, duration: 0.6)

        guard let finishedJob = job(id: jobID) else { return }
        let newSession = buildSession(
            from: finishedJob,
            sourceURL: sourceURL,
            inferenceSummary: inferenceSummary,
            autoCalibration: autoCalibration
        )
        sessions.insert(newSession, at: 0)
        savePersistedLocalSessions()

        updateJob(jobID: jobID) { job in
            job.state = .completed
            job.stage = .completed
            job.progress = 1.0
            job.resultSessionID = newSession.id
            job.updatedAt = Date()
        }

        if resolvedRemoteAnalysisConfig() != nil {
            scheduleCloudUpload(jobID: jobID, session: newSession, force: false)
        }
        runningTasks[jobID] = nil
    }

    private func animate(jobID: UUID, stage: PipelineStage, target: Double, duration: Double) async {
        guard let current = job(id: jobID) else { return }
        let start = current.progress
        let steps = max(1, Int(duration / 0.08))

        updateJob(jobID: jobID) { job in
            job.state = .running
            job.stage = stage
            job.updatedAt = Date()
        }

        for step in 1...steps {
            if Task.isCancelled { return }
            try? await Task.sleep(nanoseconds: 80_000_000)
            let ratio = Double(step) / Double(steps)
            let progress = start + (target - start) * ratio
            updateJob(jobID: jobID) { job in
                job.progress = min(max(progress, 0), 1)
                job.stage = stage
                job.state = .running
                job.updatedAt = Date()
            }
        }
    }

    private func updateJob(jobID: UUID, update: (inout LocalAnalysisJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        withAnimation(.easeInOut(duration: 0.20)) {
            update(&jobs[index])
        }
    }

    private func finishJobAsFailed(jobID: UUID, category: JobFailureCategory, message: String) {
        updateJob(jobID: jobID) { job in
            job.state = .failed
            job.stage = .failed
            job.progress = 1.0
            job.errorMessage = message
            job.failureCategory = category
            job.updatedAt = Date()
        }
        runningTasks[jobID] = nil
    }

    private func persistVideoToLibrary(from sourceURL: URL) throws -> URL {
        try fileManager.createDirectory(
            at: videoLibraryDirectory,
            withIntermediateDirectories: true
        )

        if sourceURL.path.hasPrefix(videoLibraryDirectory.path) {
            return sourceURL
        }

        let extensionName = sourceURL.pathExtension.isEmpty ? "mov" : sourceURL.pathExtension
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let fileName = "training_\(formatter.string(from: Date()))_\(UUID().uuidString.prefix(8)).\(extensionName)"
        let destinationURL = videoLibraryDirectory.appendingPathComponent(fileName)

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        return destinationURL
    }

    private func savePersistedLocalSessions() {
        let localSessions = sessions.filter { $0.localVideoPath != nil }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(localSessions)
            try data.write(to: sessionsStoreURL, options: .atomic)
        } catch {
            print("Failed to save local sessions: \(error.localizedDescription)")
        }
    }

    private static func loadPersistedLocalSessions() -> [AnalysisSession] {
        let storeURL = documentsDirectory.appendingPathComponent("analysis_sessions_local.json")
        guard let data = try? Data(contentsOf: storeURL) else { return [] }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([AnalysisSession].self, from: data)
        } catch {
            print("Failed to load local sessions: \(error.localizedDescription)")
            return []
        }
    }

    private static func merge(base: [AnalysisSession], with local: [AnalysisSession]) -> [AnalysisSession] {
        var merged = base
        let baseIDs = Set(base.map(\.id))
        for session in local where !baseIDs.contains(session.id) {
            merged.append(session)
        }
        return merged
    }

    private static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        ?? FileManager.default.temporaryDirectory
    }

    private func buildSession(
        from job: LocalAnalysisJob,
        sourceURL: URL,
        inferenceSummary: OnDeviceInferenceSummary,
        autoCalibration: AutoCourtCalibrationResult?
    ) -> AnalysisSession {
        let visibleRate = inferenceSummary.ballVisibleRate
        let trackingQualityScore = inferenceSummary.trackingQualityScore
        let notePrefix: String

        if visibleRate < 0.55 {
            notePrefix = "新视频分析已完成：建议优化机位稳定性和击球光照，提升高速回合识别率。"
        } else if trackingQualityScore < 0.85 {
            notePrefix = "新视频分析已完成：拍摄与跟踪质量基本稳定，建议减少画面抖动以优化落点统计。"
        } else {
            notePrefix = "新视频分析已完成：识别质量较高，可直接进入专项训练计划。"
        }

        let firstVisiblePoint = inferenceSummary.trackedPoints.first
        let firstBouncePoint = inferenceSummary.bouncePoints.first
        let firstAction = inferenceSummary.detectedActions.first
        let coordinateSnippet: String
        if let firstVisiblePoint {
            coordinateSnippet = "首个球坐标 (\(firstVisiblePoint.x), \(firstVisiblePoint.y))。"
        } else {
            coordinateSnippet = "未解析到稳定球坐标。"
        }
        let bounceSnippet: String
        if let firstBouncePoint {
            bounceSnippet = "首个弹跳点 (\(firstBouncePoint.x), \(firstBouncePoint.y))。"
        } else {
            bounceSnippet = "未检测到明确弹跳点。"
        }
        let actionSnippet: String
        if let firstAction {
            actionSnippet = "首个动作 \(firstAction.type.displayName)（置信度 \(firstAction.confidence.formatted(.number.precision(.fractionLength(2))))）。"
        } else {
            actionSnippet = "未识别到明确击球动作。"
        }
        let calibrationSnippet: String
        if let autoCalibration {
            calibrationSnippet = "自动球场标定已完成（质量 \(Int((autoCalibration.calibration.qualityScore * 100).rounded()))%，有效检测 \(autoCalibration.validDetections)/\(autoCalibration.sampleCount) 帧）。"
        } else {
            calibrationSnippet = "自动球场标定未完成，当前保留估算映射。"
        }

        let note = "\(notePrefix) \(inferenceSummary.analysisNote) \(coordinateSnippet) \(bounceSnippet) \(actionSnippet) \(calibrationSnippet) 模型 \(inferenceSummary.modelName) 抽帧 \(inferenceSummary.sampledFrameCount) 帧，成功 \(inferenceSummary.successfulPredictionCount) 次窗口推理。"

        return AnalysisSession(
            id: UUID(),
            videoTitle: job.fileName,
            sourceID: job.id.uuidString.lowercased(),
            actorKey: resolvedRemoteAnalysisConfig()?.actorKey,
            eventDate: Date(),
            trackedFrames: inferenceSummary.trackedFrames,
            totalFrames: inferenceSummary.totalFrames,
            ballVisibleRate: inferenceSummary.ballVisibleRate,
            trackingQualityScore: inferenceSummary.trackingQualityScore,
            estimatedBounceCount: inferenceSummary.estimatedBounceCount,
            processingStatus: .completed,
            inputSource: job.inputSource,
            localVideoPath: sourceURL.path,
            trajectoryPoints: inferenceSummary.trackedPoints,
            bouncePoints: inferenceSummary.bouncePoints,
            detectedActions: inferenceSummary.detectedActions,
            note: note,
            sessionOrigin: .localSummary,
            courtCalibration: autoCalibration?.calibration,
            qualityBreakdown: inferenceSummary.qualityBreakdown
        )
    }

    private func loadOnDeviceModel() {
        do {
            let loaded = try modelLoader.loadFirstAvailableModel()
            loadedModel = loaded
            modelDiagnostics = LoadedModelDiagnostics.from(modelName: loaded.name, model: loaded.model)
            modelStatus = .ready(modelName: loaded.name)
        } catch let error as OnDeviceModelLoaderError {
            modelDiagnostics = nil
            switch error {
            case .noModelFound(let expectedNames):
                modelStatus = .missing(expectedNames: expectedNames)
            case .loadFailed(let modelName, let reason):
                modelStatus = .failed(message: "\(modelName) 无法加载：\(reason)")
            }
        } catch {
            modelDiagnostics = nil
            modelStatus = .failed(message: error.localizedDescription)
        }
    }

    private func resolvedBackendConfig() -> BackendUploadConfig? {
        BackendUploadConfig.build(
            endpointRaw: backendUploadEndpoint,
            userIDRaw: backendUploadUserID
        )
    }

    private func resolvedRemoteAnalysisConfig() -> RemoteAnalysisConfig? {
        RemoteAnalysisConfig.build(
            endpointRaw: backendUploadEndpoint,
            installID: telemetry.stableInstallID,
            localUserIDRaw: localAnalyticsUserID
        )
    }

    private func refreshRemoteSessionsIfPossible() async {
        guard let config = resolvedRemoteAnalysisConfig() else { return }
        do {
            async let remoteJobsTask = remoteAnalysisService.fetchJobs(config: config)
            async let remoteSessionsTask = remoteAnalysisService.fetchSessions(config: config)
            let (remoteJobs, remoteSessions) = try await (remoteJobsTask, remoteSessionsTask)

            mergeRemoteJobs(remoteJobs)
            mergeRemoteSessions(remoteSessions)

            let detailRefs = Array(
                Set(
                    remoteJobs
                        .filter { $0.state == .completed || $0.state == .partialFailed }
                        .compactMap { $0.remoteExternalSessionID ?? $0.localSessionID }
                )
            )

            for detailRef in detailRefs.prefix(12) {
                do {
                    let detail = try await remoteAnalysisService.fetchSessionDetail(
                        config: config,
                        sessionRef: detailRef
                    )
                    mergeRemoteStructuredSession(detail)
                } catch {
                    continue
                }
            }
        } catch {
            backendConfigMessage = backendConfigMessage ?? "远端会话拉取失败：\(error.localizedDescription)"
        }
    }

    private func uploadPendingCompletedJobs() {
        guard resolvedRemoteAnalysisConfig() != nil else { return }

        for job in jobs where job.state == .completed {
            guard let sessionID = job.resultSessionID, let resultSession = session(id: sessionID) else { continue }
            if case .uploading? = cloudSyncStates[job.id] {
                continue
            }
            if case .processing? = cloudSyncStates[job.id] {
                continue
            }
            if case .uploaded? = cloudSyncStates[job.id] { continue }
            scheduleCloudUpload(jobID: job.id, session: resultSession, force: false)
        }
    }

    private func scheduleCloudUpload(jobID: UUID, session: AnalysisSession, force: Bool) {
        if !force {
            if case .uploading? = cloudSyncStates[jobID] {
                return
            }
            if case .processing? = cloudSyncStates[jobID] {
                return
            }
            if case .uploaded? = cloudSyncStates[jobID] {
                return
            }
        }

        guard let config = resolvedRemoteAnalysisConfig() else {
            cloudSyncStates[jobID] = .pendingConfiguration
            return
        }

        cloudSyncStates[jobID] = .queued
        syncTasks[jobID]?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.uploadSessionToBackend(jobID: jobID, session: session, config: config)
        }
        syncTasks[jobID] = task
    }

    private func uploadSessionToBackend(
        jobID: UUID,
        session: AnalysisSession,
        config: RemoteAnalysisConfig
    ) async {
        cloudSyncStates[jobID] = .uploading
        guard let videoURL = session.localVideoURL else {
            cloudSyncStates[jobID] = .failed(message: "没有可上传到远端分析的本地视频。")
            syncTasks[jobID] = nil
            return
        }

        do {
            let remoteJob = try await remoteAnalysisService.uploadVideo(
                config: config,
                localSessionID: session.sourceID,
                videoURL: videoURL,
                localSummary: session,
                manualCalibration: session.courtCalibration
            )
            if Task.isCancelled { return }

            cloudSyncStates[jobID] = .processing(stage: remoteJob.stage)
            let structuredSession = try await pollRemoteJobUntilCompleted(
                localJobID: jobID,
                remoteJobID: remoteJob.id,
                config: config
            )
            if Task.isCancelled { return }

            mergeRemoteStructuredSession(structuredSession)
            cloudSyncStates[jobID] = .uploaded(
                remoteSessionID: structuredSession.sourceID,
                uploadedAt: Date()
            )
        } catch {
            if Task.isCancelled { return }
            cloudSyncStates[jobID] = .failed(message: error.localizedDescription)
        }
        syncTasks[jobID] = nil
    }

    private func pollRemoteJobUntilCompleted(
        localJobID: UUID,
        remoteJobID: String,
        config: RemoteAnalysisConfig
    ) async throws -> AnalysisSession {
        for _ in 0..<45 {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 2_000_000_000)

            let remoteJob = try await remoteAnalysisService.fetchJob(config: config, jobID: remoteJobID)
            switch remoteJob.state {
            case .queued:
                cloudSyncStates[localJobID] = .queued
            case .uploading:
                cloudSyncStates[localJobID] = .uploading
            case .analyzing:
                cloudSyncStates[localJobID] = .processing(stage: remoteJob.stage)
            case .partialFailed, .completed:
                cloudSyncStates[localJobID] = .processing(stage: remoteJob.stage)
                let detailRef = remoteJob.remoteExternalSessionID ?? remoteJob.localSessionID
                return try await remoteAnalysisService.fetchSessionDetail(
                    config: config,
                    sessionRef: detailRef
                )
            case .failed:
                throw RemoteAnalysisServiceError.server(
                    statusCode: 500,
                    message: remoteJob.errorMessage ?? "远端分析失败。"
                )
            }
        }

        throw RemoteAnalysisServiceError.server(statusCode: 504, message: "远端分析超时，请稍后重试。")
    }

    private func mergeRemoteJobs(_ remoteJobs: [RemoteAnalysisJob]) {
        for remoteJob in remoteJobs {
            guard let localJobID = UUID(uuidString: remoteJob.localSessionID), job(id: localJobID) != nil else {
                continue
            }

            switch remoteJob.state {
            case .queued:
                cloudSyncStates[localJobID] = .queued
            case .uploading:
                cloudSyncStates[localJobID] = .uploading
            case .analyzing:
                cloudSyncStates[localJobID] = .processing(stage: remoteJob.stage)
            case .partialFailed, .completed:
                if let remoteSessionID = remoteJob.remoteExternalSessionID ?? remoteJob.remoteSessionID {
                    cloudSyncStates[localJobID] = .uploaded(
                        remoteSessionID: remoteSessionID,
                        uploadedAt: remoteJob.updatedAtUTC
                    )
                } else {
                    cloudSyncStates[localJobID] = .processing(stage: remoteJob.stage)
                }
            case .failed:
                cloudSyncStates[localJobID] = .failed(
                    message: remoteJob.errorMessage ?? "远端分析失败。"
                )
            }
        }
    }

    private func mergeRemoteSessions(_ remoteSessions: [AnalysisSession]) {
        guard !remoteSessions.isEmpty else { return }
        for remoteSession in remoteSessions {
            if sessions.contains(where: { $0.sourceID == remoteSession.sourceID }) {
                continue
            }
            sessions.append(remoteSession)
        }
        sessions.sort { $0.eventDate > $1.eventDate }
        savePersistedLocalSessions()
    }

    private func mergeRemoteStructuredSession(_ remote: AnalysisSession) {
        if let index = sessions.firstIndex(where: { $0.sourceID == remote.sourceID }) {
            let current = sessions[index]
            let merged = AnalysisSession(
                id: current.id,
                videoTitle: current.videoTitle,
                sourceID: current.sourceID,
                actorKey: remote.actorKey ?? current.actorKey,
                eventDate: remote.eventDate,
                trackedFrames: max(current.trackedFrames, remote.trackedFrames),
                totalFrames: max(current.totalFrames, remote.totalFrames),
                ballVisibleRate: current.ballVisibleRate > 0 ? current.ballVisibleRate : remote.ballVisibleRate,
                trackingQualityScore: max(current.trackingQualityScore, remote.trackingQualityScore),
                estimatedBounceCount: max(current.estimatedBounceCount, remote.estimatedBounceCount),
                processingStatus: .completed,
                inputSource: current.inputSource,
                localVideoPath: current.localVideoPath,
                trajectoryPoints: current.trajectoryPoints,
                bouncePoints: current.bouncePoints,
                detectedActions: current.detectedActions,
                note: remote.note,
                sessionOrigin: .remoteStructured,
                demoModeVisibility: .hidden,
                structuredRallies: remote.structuredRallies,
                structuredShots: remote.structuredShots,
                structuredBounces: remote.structuredBounces,
                scoreTimeline: remote.scoreTimeline,
                remoteModelVersions: remote.remoteModelVersions,
                courtDetectionQualityScore: remote.courtDetectionQualityScore,
                courtCalibration: current.courtCalibration ?? remote.courtCalibration,
                calibrationValidation: current.calibrationValidation ?? remote.calibrationValidation,
                qualityBreakdown: current.qualityBreakdown ?? remote.qualityBreakdown
            )
            sessions[index] = merged
        } else {
            sessions.insert(remote, at: 0)
        }
        sessions.sort { $0.eventDate > $1.eventDate }
        savePersistedLocalSessions()
    }
}

enum MockData {
    static let sessions: [AnalysisSession] = [
        AnalysisSession(
            id: UUID(),
            videoTitle: "Australian Open Clip A",
            sourceID: "U6WhLVQQpPc_60s",
            eventDate: date(year: 2026, month: 3, day: 11),
            trackedFrames: 858,
            totalFrames: 1500,
            ballVisibleRate: 0.572,
            trackingQualityScore: 0.88,
            estimatedBounceCount: 24,
            processingStatus: .completed,
            inputSource: nil,
            localVideoPath: nil,
            trajectoryPoints: nil,
            bouncePoints: nil,
            detectedActions: nil,
            note: "整体轨迹可追踪，底线区域稳定；中场高速回合存在短时丢球。",
            sessionOrigin: .demo,
            demoModeVisibility: .visible
        ),
        AnalysisSession(
            id: UUID(),
            videoTitle: "Australian Open Clip B",
            sourceID: "P-NHvA-LooM_60s",
            eventDate: date(year: 2026, month: 3, day: 10),
            trackedFrames: 721,
            totalFrames: 1501,
            ballVisibleRate: 0.4803,
            trackingQualityScore: 0.82,
            estimatedBounceCount: 19,
            processingStatus: .completed,
            inputSource: nil,
            localVideoPath: nil,
            trajectoryPoints: nil,
            bouncePoints: nil,
            detectedActions: nil,
            note: "镜头变焦较频繁，发球与接发阶段可见率下降明显。",
            sessionOrigin: .demo,
            demoModeVisibility: .visible
        ),
        AnalysisSession(
            id: UUID(),
            videoTitle: "Australian Open Clip C",
            sourceID: "FfyI1wYYiIA_60s",
            eventDate: date(year: 2026, month: 3, day: 9),
            trackedFrames: 625,
            totalFrames: 1500,
            ballVisibleRate: 0.4167,
            trackingQualityScore: 0.79,
            estimatedBounceCount: 17,
            processingStatus: .completed,
            inputSource: nil,
            localVideoPath: nil,
            trajectoryPoints: nil,
            bouncePoints: nil,
            detectedActions: nil,
            note: "高速对拉阶段丢球较多，建议针对光照与快门参数做拍摄优化。",
            sessionOrigin: .demo,
            demoModeVisibility: .visible
        )
    ]

    static let drills: [DrillRecommendation] = [
        DrillRecommendation(
            id: UUID(),
            title: "底线对拉 8 点落位",
            durationMinutes: 18,
            focusArea: "落点控制与击球稳定性",
            reason: "针对中场高速度回合丢球，优先提升击球点一致性。"
        ),
        DrillRecommendation(
            id: UUID(),
            title: "发球后第一拍衔接",
            durationMinutes: 15,
            focusArea: "发球 + 回位 + 第一拍",
            reason: "发球阶段轨迹稳定度较低，需强化发球后的节奏与脚步。"
        ),
        DrillRecommendation(
            id: UUID(),
            title: "横向移动耐力组",
            durationMinutes: 20,
            focusArea: "横向移动与体能",
            reason: "连续对拉阶段识别质量波动，通常伴随移动速度与重心变化。"
        )
    ]

    private static func date(year: Int, month: Int, day: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.calendar = Calendar(identifier: .gregorian)
        return components.date ?? Date()
    }
}
