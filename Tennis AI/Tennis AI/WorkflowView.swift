//
//  WorkflowView.swift
//  Tennis AI
//
//  Created by Codex on 2026/3/11.
//

import SwiftUI
import PhotosUI

struct WorkflowView: View {
    @ObservedObject var viewModel: TennisAIViewModel
    @EnvironmentObject private var themeStore: ThemeStore
    @AppStorage("skip_camera_prep") private var skipCameraPrep = false
    @State private var navigationPath = NavigationPath()
    @State private var isPhotoPickerPresented = false
    @State private var photoPickerItem: PhotosPickerItem?
    @State private var isCameraPrepPresented = false
    @State private var isCameraPresented = false
    @State private var isAdvancedSettingsExpanded = false
    @State private var importErrorMessage: String?

    private var shouldStubWorkflowActionsForUITests: Bool {
        ProcessInfo.processInfo.arguments.contains("UI_TESTS_STUB_WORKFLOW_ACTIONS")
    }

    private var advancedSettingsSummaryItems: [WorkflowAdvancedSettingsSummaryItem] {
        [
            WorkflowAdvancedSettingsSummaryItem(
                id: "model",
                title: "模型",
                value: modelSummaryValue,
                detail: modelSummaryDetail,
                tint: modelSummaryTint,
                icon: modelSummaryIcon
            ),
            WorkflowAdvancedSettingsSummaryItem(
                id: "sync",
                title: "同步",
                value: syncSummaryValue,
                detail: syncSummaryDetail,
                tint: syncSummaryTint,
                icon: syncSummaryIcon
            ),
            WorkflowAdvancedSettingsSummaryItem(
                id: "inference",
                title: "最近推理",
                value: inferenceSummaryValue,
                detail: inferenceSummaryDetail,
                tint: TennisTheme.courtDeepGreen,
                icon: "waveform.path.ecg"
            ),
            WorkflowAdvancedSettingsSummaryItem(
                id: "issues",
                title: "异常",
                value: "\(issueCount)",
                detail: issueSummaryDetail,
                tint: issueCount == 0 ? TennisTheme.courtGreen : TennisTheme.clayOrange,
                icon: issueCount == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
            )
        ]
    }

    private var modelSummaryValue: String {
        switch viewModel.modelStatus {
        case .checking:
            return "初始化中"
        case .ready(let modelName):
            return modelName
        case .missing:
            return "缺少模型"
        case .failed:
            return "加载失败"
        }
    }

    private var modelSummaryDetail: String {
        switch viewModel.modelStatus {
        case .checking:
            return "等待本地 Core ML"
        case .ready:
            return "任务会走本地推理"
        case .missing:
            return "需补充 .mlmodel"
        case .failed:
            return "请查看详细诊断"
        }
    }

    private var modelSummaryTint: Color {
        switch viewModel.modelStatus {
        case .checking:
            return TennisTheme.clayOrange
        case .ready:
            return TennisTheme.courtGreen
        case .missing, .failed:
            return .red
        }
    }

    private var modelSummaryIcon: String {
        switch viewModel.modelStatus {
        case .checking:
            return "hourglass"
        case .ready:
            return "checkmark.shield.fill"
        case .missing:
            return "shippingbox.fill"
        case .failed:
            return "xmark.octagon.fill"
        }
    }

    private var syncSummaryValue: String {
        let hasUserID = !viewModel.backendUploadUserID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if viewModel.backendConfigured && hasUserID {
            return "自动分析 + 兼容"
        }
        if viewModel.backendConfigured {
            return "自动分析"
        }
        if viewModel.telemetryConfigured {
            return "仅埋点"
        }
        return "未配置"
    }

    private var syncSummaryDetail: String {
        if viewModel.backendConfigured && !viewModel.backendUploadUserID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "自动远端结构化 + legacy user_id"
        }
        if viewModel.backendConfigured {
            return "视频会自动上传到远端分析"
        }
        if viewModel.telemetryConfigured {
            return "事件会发送到后端"
        }
        return "本地运行，不做远端同步"
    }

    private var syncSummaryTint: Color {
        if viewModel.backendConfigured {
            return TennisTheme.courtGreen
        }
        if viewModel.telemetryConfigured {
            return TennisTheme.clayOrange
        }
        return TennisTheme.courtDeepGreen
    }

    private var syncSummaryIcon: String {
        if viewModel.backendConfigured && !viewModel.backendUploadUserID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "sparkles.rectangle.stack.fill"
        }
        if viewModel.backendConfigured {
            return "server.rack"
        }
        if viewModel.telemetryConfigured {
            return "waveform.and.magnifyingglass"
        }
        return "icloud.slash"
    }

    private var inferenceSummaryValue: String {
        guard let latestSummary = viewModel.latestInferenceSummary else {
            return "未运行"
        }
        return latestSummary.ballVisibleRate.formatted(.percent.precision(.fractionLength(0)))
    }

    private var inferenceSummaryDetail: String {
        guard let latestInferenceDate = viewModel.latestInferenceDate else {
            return "\(viewModel.inferenceProfile.shortLabel) · 暂无结果"
        }
        return "\(viewModel.inferenceProfile.shortLabel) · \(latestInferenceDate.formatted(date: .omitted, time: .shortened))"
    }

    private var failedJobCount: Int {
        viewModel.jobs.filter { $0.state == .failed }.count
    }

    private var failedSyncCount: Int {
        viewModel.cloudSyncStates.values.reduce(into: 0) { partial, state in
            if case .failed = state {
                partial += 1
            }
        }
    }

    private var issueCount: Int {
        failedJobCount + failedSyncCount + (viewModel.telemetryPendingEventsCount > 0 ? 1 : 0)
    }

    private var issueSummaryDetail: String {
        let segments = [
            failedJobCount > 0 ? "任务失败 \(failedJobCount)" : nil,
            failedSyncCount > 0 ? "同步失败 \(failedSyncCount)" : nil,
            viewModel.telemetryPendingEventsCount > 0 ? "待发 \(viewModel.telemetryPendingEventsCount)" : nil
        ].compactMap { $0 }

        return segments.isEmpty ? "当前没有待处理异常" : segments.joined(separator: " · ")
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ScrollView {
                VStack(spacing: 18) {
                    UploadHeroCard(
                        activeCount: viewModel.activeJobs.count,
                        finishedCount: viewModel.finishedJobs.count
                    ) {
                        handleUploadTap()
                    } onRecord: {
                        handleRecordTap()
                    }
                    .accessibilityIdentifier("workflow-hero-card")

                    WorkflowThemeSelectorCard(
                        selectedSurface: themeStore.selectedSurface
                    ) { surface in
                        selectTheme(surface)
                    }

                    if !viewModel.activeJobs.isEmpty {
                        SectionHeader(
                            title: "本地任务状态",
                            subtitle: "实时进度会自动刷新，无需手动下拉"
                        )
                        .accessibilityIdentifier("workflow-active-jobs-section")

                        VStack(spacing: 12) {
                            ForEach(viewModel.activeJobs) { job in
                                NavigationLink(value: job.id) {
                                    WorkflowJobCard(
                                        job: job,
                                        cloudSyncState: viewModel.cloudSyncState(for: job.id)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    SectionHeader(
                        title: "已完成任务",
                        subtitle: "先生成本地摘要，再自动触发远端结构化分析"
                    )
                    .accessibilityIdentifier("workflow-completed-jobs-section")

                    VStack(spacing: 12) {
                        if viewModel.finishedJobs.isEmpty {
                            EmptyWorkflowCard()
                        } else {
                            ForEach(viewModel.finishedJobs.prefix(5)) { job in
                                NavigationLink(value: job.id) {
                                    WorkflowJobCard(
                                        job: job,
                                        cloudSyncState: viewModel.cloudSyncState(for: job.id)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    SectionHeader(
                        title: "最近分析详情",
                        subtitle: "默认只展示真实会话；远端结果回填后会自动升级"
                    )
                    .accessibilityIdentifier("workflow-recent-analysis-section")

                    VStack(spacing: 10) {
                        ForEach(viewModel.sessions.prefix(6)) { session in
                            NavigationLink {
                                AnalysisDetailView(
                                    session: session,
                                    onUpdateSessionCalibration: { sessionID, calibration in
                                        viewModel.updateSessionCourtCalibration(sessionID: sessionID, calibration: calibration)
                                    },
                                    onUpdateSessionValidation: { sessionID, validation in
                                        viewModel.updateSessionCalibrationValidation(sessionID: sessionID, validation: validation)
                                    }
                                )
                            } label: {
                                SessionRow(session: session)
                                    .padding()
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .tennisCard()
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    WorkflowAdvancedSettingsCard(
                        isExpanded: $isAdvancedSettingsExpanded,
                        summaryItems: advancedSettingsSummaryItems
                    ) {
                        ModelBundleStatusCard(status: viewModel.modelStatus)
                        ModelDiagnosticsCard(
                            diagnostics: viewModel.modelDiagnostics,
                            latestSummary: viewModel.latestInferenceSummary,
                            latestInferenceDate: viewModel.latestInferenceDate
                        )
                        BackendSyncConfigCard(viewModel: viewModel)
                    }
                }
                .padding()
            }
            .background(CourtSurfaceBackground())
            .navigationTitle("分析工作流")
            .navigationDestination(for: UUID.self) { jobID in
                WorkflowJobDetailView(viewModel: viewModel, jobID: jobID)
            }
            .photosPicker(
                isPresented: $isPhotoPickerPresented,
                selection: $photoPickerItem,
                matching: .videos
            )
            .onChange(of: photoPickerItem) { newItem in
                guard let item = newItem else { return }
                Task { await handlePhotoPickerItem(item) }
            }
            .alert("上传失败", isPresented: Binding(
                get: { importErrorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        importErrorMessage = nil
                    }
                }
            ), actions: {
                Button("我知道了") {
                    importErrorMessage = nil
                }
            }, message: {
                Text(importErrorMessage ?? "未知错误")
            })
            .sheet(isPresented: $isCameraPresented) {
                CameraVideoPicker { capturedURL in
                    do {
                        let jobID = try viewModel.enqueueVideo(url: capturedURL, source: .camera)
                        viewModel.trackTap(
                            screen: "workflow",
                            target: "record_video_success",
                            metadata: ["job_id": jobID.uuidString.lowercased()]
                        )
                        isCameraPresented = false
                        navigateToJobDetail(jobID, delay: 0.35)
                    } catch {
                        viewModel.trackTap(
                            screen: "workflow",
                            target: "record_video_failed",
                            metadata: ["error": error.localizedDescription]
                        )
                        importErrorMessage = "保存拍摄视频失败：\(error.localizedDescription)"
                    }
                } onError: { message in
                    viewModel.trackTap(
                        screen: "workflow",
                        target: "camera_picker_failed",
                        metadata: ["error": message]
                    )
                    importErrorMessage = message
                }
            }
            .sheet(isPresented: $isCameraPrepPresented) {
                CameraPrepSheet(skipNextTime: $skipCameraPrep) {
                    isCameraPrepPresented = false
                    // Present camera after the prep sheet finishes dismiss animation.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        isCameraPresented = true
                    }
                }
            }
        }
    }

    private func handleUploadTap() {
        viewModel.trackTap(screen: "workflow", target: "upload_existing_video")
        guard !shouldStubWorkflowActionsForUITests else {
            importErrorMessage = "UI 测试桩：已触发上传已有视频。"
            return
        }
        photoPickerItem = nil
        isPhotoPickerPresented = true
    }

    private func handleRecordTap() {
        viewModel.trackTap(screen: "workflow", target: "start_recording")
        startCameraRecording()
    }

    @MainActor
    private func handlePhotoPickerItem(_ item: PhotosPickerItem) async {
        do {
            guard let movie = try await item.loadTransferable(type: LibraryMovie.self) else {
                importErrorMessage = "无法读取所选视频，请重试。"
                return
            }
            let jobID = try viewModel.enqueueVideo(url: movie.url, source: .upload)
            viewModel.trackTap(
                screen: "workflow",
                target: "import_video_success",
                metadata: ["job_id": jobID.uuidString.lowercased()]
            )
            photoPickerItem = nil
            navigateToJobDetail(jobID)
        } catch {
            viewModel.trackTap(
                screen: "workflow",
                target: "import_video_failed",
                metadata: ["error": error.localizedDescription]
            )
            importErrorMessage = "保存所选视频失败：\(error.localizedDescription)"
        }
    }

    private func startCameraRecording() {
        guard !shouldStubWorkflowActionsForUITests else {
            importErrorMessage = "UI 测试桩：已触发开始拍摄。"
            return
        }
        guard CameraVideoPicker.isSupported else {
            viewModel.trackTap(screen: "workflow", target: "camera_not_supported")
            importErrorMessage = "当前设备不支持系统相机录制，请改用“上传已有视频”。"
            return
        }
        if skipCameraPrep {
            isCameraPresented = true
        } else {
            isCameraPrepPresented = true
        }
    }

    private func selectTheme(_ surface: CourtSurfaceTheme) {
        guard themeStore.selectedSurface != surface else { return }
        themeStore.select(surface)
        viewModel.trackTap(
            screen: "workflow",
            target: "change_surface_theme",
            metadata: ["surface": surface.rawValue]
        )
    }

    private func navigateToJobDetail(_ jobID: UUID, delay: TimeInterval = 0.0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            navigationPath.append(jobID)
        }
    }
}

struct WorkflowJobDetailView: View {
    @ObservedObject var viewModel: TennisAIViewModel
    let jobID: UUID

    private var job: LocalAnalysisJob? {
        viewModel.job(id: jobID)
    }

    var body: some View {
        ScrollView {
            if let job {
                VStack(alignment: .leading, spacing: 18) {
                    JobDetailHero(
                        job: job,
                        cloudSyncState: viewModel.cloudSyncState(for: job.id)
                    )

                    if let failureCategory = job.resolvedFailureCategory(
                        cloudSyncState: viewModel.cloudSyncState(for: job.id)
                    ) {
                        FailureCategoryCard(
                            category: failureCategory,
                            message: job.errorMessage
                        )
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("处理阶段")
                            .font(.headline)
                        StageTimeline(job: job)
                    }
                    .padding()
                    .tennisCard()

                    if let cloudSyncState = viewModel.cloudSyncState(for: job.id) {
                        CloudSyncStatusCard(
                            state: cloudSyncState,
                            onRetry: {
                                viewModel.trackTap(screen: "workflow_job_detail", target: "retry_cloud_upload")
                                viewModel.retryCloudUpload(jobID: job.id)
                            }
                        )
                    }

                    if
                        job.state == .completed,
                        let sessionID = job.resultSessionID,
                        let session = viewModel.session(id: sessionID)
                    {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("分析已刷新")
                                .font(.headline)
                            Text("该任务已生成最新分析报告，点击查看完整详情。")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            NavigationLink {
                                AnalysisDetailView(
                                    session: session,
                                    onUpdateSessionCalibration: { sessionID, calibration in
                                        viewModel.updateSessionCourtCalibration(sessionID: sessionID, calibration: calibration)
                                    },
                                    onUpdateSessionValidation: { sessionID, validation in
                                        viewModel.updateSessionCalibrationValidation(sessionID: sessionID, validation: validation)
                                    }
                                )
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(session.videoTitle)
                                            .font(.subheadline.bold())
                                        Text("可见率 \(session.ballVisibleRate.formatted(.percent.precision(.fractionLength(1)))) · 跟踪质量 \(session.trackingQualityScore.formatted(.percent.precision(.fractionLength(1))))")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption.bold())
                                        .foregroundStyle(.secondary)
                                }
                                .padding()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(WorkflowPalette.cardAccent.opacity(0.14))
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding()
                        .tennisCard()
                    }
                }
                .padding()
            } else {
                Text("任务不存在或已被移除。")
                    .foregroundStyle(.secondary)
                    .padding()
            }
        }
        .background(CourtSurfaceBackground())
        .navigationTitle("任务详情")
        .onAppear {
            viewModel.trackScreenAppear("workflow_job_detail")
        }
        .onDisappear {
            viewModel.trackScreenLeave("workflow_job_detail")
        }
    }
}

struct UploadHeroCard: View {
    let activeCount: Int
    let finishedCount: Int
    let onUpload: () -> Void
    let onRecord: () -> Void

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 22)
                .fill(
                    LinearGradient(
                        colors: [WorkflowPalette.heroStart, WorkflowPalette.heroEnd],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Circle()
                .fill(TennisTheme.ballYellow.opacity(0.92))
                .frame(width: 68, height: 68)
                .overlay(
                    Circle()
                        .stroke(Color.black.opacity(0.18), lineWidth: 1)
                )
                .offset(x: 130, y: -68)

            Path { path in
                path.move(to: CGPoint(x: 18, y: 48))
                path.addLine(to: CGPoint(x: 260, y: 48))
                path.move(to: CGPoint(x: 18, y: 114))
                path.addLine(to: CGPoint(x: 290, y: 114))
                path.move(to: CGPoint(x: 170, y: 14))
                path.addLine(to: CGPoint(x: 170, y: 178))
            }
            .stroke(TennisTheme.lineWhite.opacity(0.22), lineWidth: 1.1)

            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("拍摄训练视频")
                            .font(.custom("AvenirNextCondensed-Bold", size: 34))
                            .foregroundStyle(.white)
                        Text("拍摄或上传后，本地生成训练摘要并自动刷新状态")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.85))
                    }

                    Spacer()

                    Image(systemName: "sparkles.tv")
                        .font(.title2)
                        .foregroundStyle(.white.opacity(0.9))
                }

                HStack(spacing: 10) {
                    Pill(title: "进行中 \(activeCount)", tint: TennisTheme.clayOrange)
                    Pill(title: "已完成 \(finishedCount)", tint: TennisTheme.courtGreen)
                }

                HStack(spacing: 10) {
                    Button(action: onRecord) {
                        HStack(spacing: 8) {
                            Image(systemName: "record.circle.fill")
                            Text("开始拍摄")
                                .fontWeight(.semibold)
                        }
                        .foregroundStyle(TennisTheme.courtDeepGreen)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(TennisTheme.ballYellow)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("workflow-start-recording-button")

                    Button(action: onUpload) {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.up.doc.fill")
                            Text("上传已有视频")
                                .fontWeight(.semibold)
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color.black.opacity(0.24))
                        .overlay(
                            Capsule()
                                .stroke(TennisTheme.lineWhite.opacity(0.34), lineWidth: 1)
                        )
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("workflow-upload-video-button")
                }
            }
            .padding(18)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 190)
        .shadow(color: WorkflowPalette.heroEnd.opacity(0.18), radius: 14, x: 0, y: 10)
    }
}

struct WorkflowThemeSelectorCard: View {
    let selectedSurface: CourtSurfaceTheme
    let onSelect: (CourtSurfaceTheme) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("场地主题")
                    .font(.custom("AvenirNextCondensed-DemiBold", size: 27))
                    .foregroundStyle(TennisTheme.courtDeepGreen)
                Text("切换工作流视觉基调，保持硬地 / 红土 / 草地三套风格一致。")
                    .font(.caption)
                    .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.64))
            }

            HStack(spacing: 10) {
                ForEach(CourtSurfaceTheme.allCases) { surface in
                    WorkflowThemeButton(
                        surface: surface,
                        isSelected: surface == selectedSurface
                    ) {
                        onSelect(surface)
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tennisCard()
        .accessibilityIdentifier("workflow-theme-selector-card")
    }
}

struct WorkflowThemeButton: View {
    let surface: CourtSurfaceTheme
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: surface.icon)
                        .font(.system(size: 11, weight: .bold))
                    Text(surface.scoreboardCode)
                        .font(.system(size: 13, weight: .black, design: .rounded))
                }

                Text(surface.displayName)
                    .font(.caption2.bold())
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .foregroundStyle(isSelected ? TennisTheme.courtDeepGreen : TennisTheme.lineWhite.opacity(0.92))
            .background(isSelected ? TennisTheme.ballYellow : TennisTheme.courtDeepGreen.opacity(0.62))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        isSelected
                        ? TennisTheme.ballYellow.opacity(0.90)
                        : TennisTheme.lineWhite.opacity(0.18),
                        lineWidth: 1
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("workflow-theme-\(surface.rawValue)-button")
        .accessibilityValue(isSelected ? "selected" : "not selected")
    }
}

struct WorkflowAdvancedSettingsCard<Content: View>: View {
    @Binding var isExpanded: Bool
    let summaryItems: [WorkflowAdvancedSettingsSummaryItem]
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("运行状态与高级设置")
                            .font(.headline)
                            .foregroundStyle(TennisTheme.courtDeepGreen)
                        Text("先看摘要，再按需展开模型诊断和同步配置。")
                            .font(.caption)
                            .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.64))
                    }

                    Spacer()

                    Image(systemName: isExpanded ? "chevron.up.circle.fill" : "chevron.down.circle.fill")
                        .font(.title3)
                        .foregroundStyle(TennisTheme.courtDeepGreen)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("workflow-advanced-settings-toggle")

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(summaryItems) { item in
                    WorkflowAdvancedSettingsSummaryTile(item: item)
                }
            }
            .accessibilityIdentifier("workflow-advanced-settings-summary")

            if isExpanded {
                VStack(spacing: 12) {
                    content()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tennisCard()
        .accessibilityIdentifier("workflow-advanced-settings-card")
    }
}

struct WorkflowAdvancedSettingsSummaryItem: Identifiable {
    let id: String
    let title: String
    let value: String
    let detail: String
    let tint: Color
    let icon: String
}

struct WorkflowAdvancedSettingsSummaryTile: View {
    let item: WorkflowAdvancedSettingsSummaryItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(item.tint.opacity(0.16))
                    .frame(width: 28, height: 28)
                    .overlay(
                        Image(systemName: item.icon)
                            .font(.caption.bold())
                            .foregroundStyle(item.tint)
                    )

                Text(item.title)
                    .font(.caption.bold())
                    .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.74))

                Spacer(minLength: 0)
            }

            Text(item.value)
                .font(.system(size: 20, weight: .black, design: .rounded))
                .foregroundStyle(TennisTheme.courtDeepGreen)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Text(item.detail)
                .font(.caption2)
                .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.68))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 108, alignment: .topLeading)
        .background(item.tint.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(item.tint.opacity(0.18), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .accessibilityIdentifier("workflow-advanced-summary-\(item.id)")
    }
}

struct CameraPrepSheet: View {
    @Binding var skipNextTime: Bool
    let onStart: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("拍摄前确认")
                        .font(.custom("AvenirNextCondensed-Bold", size: 30))
                        .foregroundStyle(TennisTheme.courtDeepGreen)
                    Text("按下面建议拍摄，分析结果会明显更稳定")
                        .font(.subheadline)
                        .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.70))
                }

                VStack(alignment: .leading, spacing: 10) {
                    PrepRow(
                        icon: "camera.aperture",
                        title: "横屏 + 固定机位",
                        detail: "建议底线后方 2-3 米，高度 1.5-2 米"
                    )
                    PrepRow(
                        icon: "video.badge.waveform",
                        title: "推荐 1080p / 60fps",
                        detail: "高速回合更容易跟踪，减少丢球片段"
                    )
                    PrepRow(
                        icon: "rectangle.dashed.and.paperclip",
                        title: "尽量拍全场地线",
                        detail: "含底线、发球线与中线，便于角点标定"
                    )
                    PrepRow(
                        icon: "sun.max",
                        title: "避免逆光和频繁变焦",
                        detail: "保持曝光稳定，检测与轨迹精度更高"
                    )
                }
                .padding()
                .tennisCard()

                Toggle("下次不再提示", isOn: $skipNextTime)
                    .toggleStyle(.switch)
                    .tint(TennisTheme.courtGreen)
                    .foregroundStyle(TennisTheme.courtDeepGreen)

                Button(action: onStart) {
                    HStack {
                        Spacer()
                        Label("开始拍摄", systemImage: "record.circle.fill")
                            .font(.headline)
                        Spacer()
                    }
                    .padding(.vertical, 12)
                    .foregroundStyle(TennisTheme.courtDeepGreen)
                    .background(TennisTheme.ballYellow)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)
            }
            .padding()
            .background(CourtSurfaceBackground())
            .navigationTitle("拍摄引导")
        }
        .presentationDetents([.large])
    }
}

struct PrepRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(TennisTheme.courtGreen.opacity(0.18))
                .frame(width: 28, height: 28)
                .overlay(
                    Image(systemName: icon)
                        .font(.caption.bold())
                        .foregroundStyle(TennisTheme.courtDeepGreen)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.bold())
                    .foregroundStyle(TennisTheme.courtDeepGreen)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.72))
            }

            Spacer()
        }
    }
}

struct BackendSyncConfigCard: View {
    @ObservedObject var viewModel: TennisAIViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("后端自动分析配置")
                        .font(.headline)
                        .foregroundStyle(TennisTheme.courtDeepGreen)
                    Text("保存后会启用行为埋点与自动远端结构化分析。新视频默认上传到 /analysis/videos，并按 actor_key 拉取 jobs、sessions 与 detail。legacy user_id 只保留给旧接口兼容。")
                        .font(.caption)
                        .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.68))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Label(
                        viewModel.telemetryConfigured ? "埋点已启用" : "埋点未配置",
                        systemImage: viewModel.telemetryConfigured ? "waveform.and.magnifyingglass" : "waveform.badge.exclamationmark"
                    )
                    .font(.caption2.bold())
                    .foregroundStyle(viewModel.telemetryConfigured ? TennisTheme.courtGreen : TennisTheme.clayOrange)

                    Label(
                        viewModel.backendConfigured ? "自动分析已启用" : "自动分析未启用",
                        systemImage: viewModel.backendConfigured ? "sparkles.rectangle.stack.fill" : "icloud.slash"
                    )
                    .font(.caption2.bold())
                    .foregroundStyle(viewModel.backendConfigured ? TennisTheme.courtGreen : TennisTheme.clayOrange)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("动作识别策略")
                    .font(.caption.bold())
                    .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.80))

                Picker(
                    "动作识别策略",
                    selection: Binding(
                        get: { viewModel.inferenceProfile },
                        set: { newValue in
                            viewModel.trackTap(
                                screen: "workflow",
                                target: "change_inference_profile",
                                metadata: ["profile": newValue.rawValue]
                            )
                            viewModel.updateInferenceProfile(newValue)
                        }
                    )
                ) {
                    ForEach(OnDeviceInferenceProfile.allCases) { profile in
                        Text(profile.displayName).tag(profile)
                    }
                }
                .pickerStyle(.segmented)

                Text(viewModel.inferenceProfile.detail)
                    .font(.caption2)
                    .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.66))
            }
            .padding(.top, 2)

            TextField("后端 URL（可填 http://127.0.0.1:8000）", text: $viewModel.backendUploadEndpoint)
                .font(.subheadline)
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .background(TennisTheme.lineWhite)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(TennisTheme.courtDeepGreen.opacity(0.18), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 10))

            TextField("legacy user_id（可留空，仅兼容旧 /sessions/upload）", text: $viewModel.backendUploadUserID)
                .font(.subheadline.monospaced())
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .background(TennisTheme.lineWhite)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(TennisTheme.courtDeepGreen.opacity(0.18), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 10))

            TextField("本地用户ID（用于埋点，例：player_001）", text: $viewModel.localAnalyticsUserID)
                .font(.subheadline.monospaced())
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .background(TennisTheme.lineWhite)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(TennisTheme.courtDeepGreen.opacity(0.18), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 10))

            HStack(spacing: 8) {
                Button {
                    viewModel.trackTap(screen: "workflow", target: "save_backend_config")
                    viewModel.saveBackendConfig()
                } label: {
                    Label("保存配置", systemImage: "square.and.arrow.down.fill")
                        .font(.caption.bold())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .foregroundStyle(TennisTheme.lineWhite)
                        .background(TennisTheme.courtDeepGreen)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                if let message = viewModel.backendConfigMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.70))
                        .lineLimit(2)
                }
            }

            if let telemetryMessage = viewModel.telemetryUploadMessage {
                Text("埋点状态：\(telemetryMessage)（待发 \(viewModel.telemetryPendingEventsCount)）")
                    .font(.caption2)
                    .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.66))
            }
        }
        .padding()
        .tennisCard()
    }
}

struct CloudSyncStatusCard: View {
    let state: CloudSyncState
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(state.label, systemImage: state.icon)
                    .font(.subheadline.bold())
                    .foregroundStyle(state.tint)
                Spacer()
                if state.showsProgress {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let detail = state.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.72))
            }

            if state.canRetry {
                Button(action: onRetry) {
                    Label("重试分析", systemImage: "arrow.clockwise")
                        .font(.caption.bold())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .foregroundStyle(TennisTheme.lineWhite)
                        .background(TennisTheme.courtDeepGreen)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding()
        .tennisCard()
    }
}

struct WorkflowJobCard: View {
    let job: LocalAnalysisJob
    let cloudSyncState: CloudSyncState?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(job.fileName)
                        .font(.subheadline.bold())
                        .foregroundStyle(TennisTheme.courtDeepGreen)
                        .lineLimit(1)
                    Text(job.stage.subtitle)
                        .font(.caption)
                        .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.62))
                    InputSourceBadge(source: job.inputSource, compact: true)
                }
                Spacer()
                JobBadge(state: job.state)
            }

            ScoreboardProgressPanel(job: job, compact: true)

            if let cloudSyncState {
                HStack(spacing: 6) {
                    Image(systemName: cloudSyncState.icon)
                        .font(.system(size: 10, weight: .bold))
                    Text(cloudSyncState.label)
                        .font(.caption2.bold())
                    Spacer()
                    if cloudSyncState.showsProgress {
                        ProgressView()
                            .controlSize(.mini)
                    }
                }
                .foregroundStyle(cloudSyncState.tint)
            }

            if let failureCategory = job.resolvedFailureCategory(cloudSyncState: cloudSyncState) {
                FailureCategoryBadge(category: failureCategory)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(job.stage.tint.opacity(0.22), lineWidth: 1)
        )
        .tennisCard()
    }
}

struct ScoreboardProgressPanel: View {
    let job: LocalAnalysisJob
    let compact: Bool

    private var progressPercentValue: Double {
        max(0, min(job.progress * 100, 100))
    }

    private var scoreboardStep: Int {
        max(0, min(job.stage.scoreboardStep, 4))
    }

    var body: some View {
        VStack(spacing: compact ? 8 : 12) {
            HStack(spacing: compact ? 8 : 12) {
                ScoreboardSetTile(
                    step: scoreboardStep,
                    compact: compact
                )

                Spacer(minLength: 0)

                ScoreboardPercentTile(
                    progressPercentValue: progressPercentValue,
                    compact: compact
                )
            }

            HStack(spacing: compact ? 6 : 8) {
                ForEach(1...4, id: \.self) { index in
                    RoundedRectangle(cornerRadius: compact ? 3 : 4)
                        .fill(Color.black.opacity(0.50))
                        .frame(height: compact ? 7 : 9)
                        .overlay {
                            RoundedRectangle(cornerRadius: compact ? 3 : 4)
                                .fill(
                                    index <= scoreboardStep
                                    ? TennisTheme.ballYellow
                                    : TennisTheme.lineWhite.opacity(0.24)
                                )
                                .padding(1)
                        }
                        .overlay(alignment: .trailing) {
                            if index == scoreboardStep, job.state == .running {
                                Circle()
                                    .fill(TennisTheme.ballYellow)
                                    .frame(width: compact ? 8 : 10, height: compact ? 8 : 10)
                                    .shadow(color: TennisTheme.ballYellow.opacity(0.55), radius: 4, x: 0, y: 0)
                                    .offset(x: 2)
                                    .transition(.scale.combined(with: .opacity))
                            }
                        }
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.80), value: scoreboardStep)

            HStack(spacing: 6) {
                Image(systemName: job.stage.icon)
                    .font(.system(size: compact ? 10 : 12, weight: .bold))
                    .foregroundStyle(TennisTheme.ballYellow.opacity(0.95))
                ZStack {
                    Text(job.stage.scoreboardLabel)
                        .id(job.stage.scoreboardLabel)
                        .transition(.scoreboardTicker)
                }
                .font(.system(size: compact ? 10 : 12, weight: .black, design: .monospaced))
                .foregroundStyle(TennisTheme.lineWhite.opacity(0.90))
                Spacer()
                if job.state == .running {
                    Text("LIVE")
                        .font(.system(size: compact ? 9 : 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(TennisTheme.ballYellow)
                }
            }
            .animation(.easeInOut(duration: 0.24), value: job.stage.rawValue)
        }
        .padding(compact ? 8 : 12)
        .background(
            RoundedRectangle(cornerRadius: compact ? 10 : 12)
                .fill(
                    LinearGradient(
                        colors: [Color.black.opacity(0.80), Color.black.opacity(0.64)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: compact ? 10 : 12)
                .stroke(TennisTheme.lineWhite.opacity(0.30), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: compact ? 10 : 12))
    }
}

struct ScoreboardSetTile: View {
    let step: Int
    let compact: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text("SET")
                .foregroundStyle(TennisTheme.lineWhite.opacity(0.85))

            ZStack {
                Text("\(step)")
                    .id(step)
                    .transition(.scoreboardTicker)
            }
            .frame(width: compact ? 14 : 18)
            .foregroundStyle(TennisTheme.ballYellow)

            Text("/4")
                .foregroundStyle(TennisTheme.lineWhite.opacity(0.80))
        }
        .font(.system(size: compact ? 10 : 12, weight: .black, design: .monospaced))
        .padding(.horizontal, compact ? 8 : 10)
        .padding(.vertical, compact ? 5 : 6)
        .background(Color.black.opacity(0.40))
        .overlay(
            RoundedRectangle(cornerRadius: compact ? 6 : 8)
                .stroke(TennisTheme.lineWhite.opacity(0.22), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: compact ? 6 : 8))
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: step)
    }
}

struct ScoreboardPercentTile: View {
    let progressPercentValue: Double
    let compact: Bool

    private var percentageText: String {
        progressPercentValue.formatted(.number.precision(.fractionLength(0))) + "%"
    }

    var body: some View {
        Text(percentageText)
            .font(.system(size: compact ? 15 : 20, weight: .black, design: .monospaced))
            .foregroundStyle(TennisTheme.ballYellow)
            .contentTransition(.numericText(value: progressPercentValue))
            .frame(minWidth: compact ? 72 : 90, alignment: .trailing)
            .padding(.horizontal, compact ? 8 : 10)
            .padding(.vertical, compact ? 4 : 6)
            .background(Color.black.opacity(0.40))
            .overlay(
                RoundedRectangle(cornerRadius: compact ? 6 : 8)
                    .stroke(TennisTheme.lineWhite.opacity(0.22), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: compact ? 6 : 8))
    }
}

struct JobDetailHero: View {
    let job: LocalAnalysisJob
    let cloudSyncState: CloudSyncState?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(job.fileName)
                        .font(.headline)
                        .foregroundStyle(TennisTheme.courtDeepGreen)
                    Text(job.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.65))
                    InputSourceBadge(source: job.inputSource, compact: false)
                }
                Spacer()
                JobBadge(state: job.state)
            }

            HStack(alignment: .center) {
                ZStack {
                    Circle()
                        .stroke(WorkflowPalette.cardAccent.opacity(0.2), lineWidth: 9)
                    Circle()
                        .trim(from: 0, to: job.progress)
                        .stroke(job.stage.tint, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 68, height: 68)

                VStack(alignment: .leading, spacing: 4) {
                    Text(job.progress.formatted(.percent.precision(.fractionLength(0))))
                        .font(.title3.bold())
                        .foregroundStyle(TennisTheme.courtDeepGreen)
                    Text(job.stage.title)
                        .font(.subheadline)
                        .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.70))
                }

                Spacer()
            }

            ScoreboardProgressPanel(job: job, compact: false)

            if let failureCategory = job.resolvedFailureCategory(cloudSyncState: cloudSyncState) {
                FailureCategoryBadge(category: failureCategory)
            }

            if let errorMessage = job.errorMessage, !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding()
        .tennisCard()
    }
}

struct StageTimeline: View {
    let job: LocalAnalysisJob

    var body: some View {
        VStack(spacing: 12) {
            ForEach(PipelineStage.visibleSteps, id: \.self) { stage in
                HStack(alignment: .top, spacing: 10) {
                    Circle()
                        .fill(stageStatus(for: stage).color.opacity(0.17))
                        .frame(width: 26, height: 26)
                        .overlay(
                            Image(systemName: stageStatus(for: stage).icon)
                                .font(.caption.bold())
                                .foregroundStyle(stageStatus(for: stage).color)
                        )

                    VStack(alignment: .leading, spacing: 2) {
                        Text(stage.title)
                            .font(.subheadline.bold())
                        Text(stage.subtitle)
                            .font(.caption)
                            .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.68))
                    }

                    Spacer()

                    Text(stageStatus(for: stage).label)
                        .font(.caption2.bold())
                        .foregroundStyle(stageStatus(for: stage).color)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .animation(.spring(response: 0.36, dampingFraction: 0.82), value: job.stage.rawValue)
    }

    private func stageStatus(for stage: PipelineStage) -> StageState {
        if job.state == .completed {
            return .completed
        }
        if job.state == .failed && stage == job.stage {
            return .failed
        }
        if stage.rawValue < job.stage.rawValue {
            return .completed
        }
        if stage == job.stage {
            if job.state == .queued {
                return .waiting
            }
            return .running
        }
        return .waiting
    }
}

struct SectionHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.custom("AvenirNextCondensed-DemiBold", size: 27))
                .foregroundStyle(TennisTheme.courtDeepGreen)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.64))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct Pill: View {
    let title: String
    let tint: Color

    var body: some View {
        Text(title)
            .font(.caption.bold())
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .foregroundStyle(TennisTheme.lineWhite)
            .background(tint.opacity(0.46))
            .clipShape(Capsule())
    }
}

struct JobBadge: View {
    let state: JobExecutionState

    var body: some View {
        Text(state.label)
            .font(.caption.bold())
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .foregroundStyle(state.tint)
            .background(state.tint.opacity(0.14))
            .clipShape(Capsule())
    }
}

struct FailureCategoryBadge: View {
    let category: JobFailureCategory

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: category.icon)
                .font(.system(size: 10, weight: .bold))
            Text(category.summaryTitle)
                .font(.caption2.bold())
        }
        .foregroundStyle(category.tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(category.tint.opacity(0.12))
        .clipShape(Capsule())
    }
}

struct FailureCategoryCard: View {
    let category: JobFailureCategory
    let message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(category.summaryTitle, systemImage: category.icon)
                    .font(.headline)
                    .foregroundStyle(category.tint)
                Spacer()
                Text("失败分类")
                    .font(.caption.bold())
                    .foregroundStyle(category.tint)
            }

            if let message, !message.isEmpty {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(TennisTheme.courtDeepGreen)
            }

            Text(category.guidance)
                .font(.caption)
                .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.76))
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(category.tint.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(category.tint.opacity(0.22), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

struct InputSourceBadge: View {
    let source: VideoInputSource
    let compact: Bool

    var body: some View {
        Label(source.label, systemImage: source.icon)
            .font(.system(size: compact ? 10 : 11, weight: .bold))
            .padding(.horizontal, compact ? 8 : 9)
            .padding(.vertical, compact ? 3 : 4)
            .foregroundStyle(source.tint)
            .background(source.tint.opacity(0.14))
            .clipShape(Capsule())
    }
}

struct EmptyWorkflowCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("还没有本地任务", systemImage: "clock.badge.questionmark")
                .font(.subheadline.bold())
                .foregroundStyle(TennisTheme.courtDeepGreen)
            Text("上传一个训练视频后，这里会显示实时处理状态与本地摘要结果。")
                .font(.caption)
                .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.66))
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .tennisCard()
    }
}

enum StageState {
    case waiting
    case running
    case completed
    case failed

    var label: String {
        switch self {
        case .waiting:
            return "等待中"
        case .running:
            return "进行中"
        case .completed:
            return "已完成"
        case .failed:
            return "失败"
        }
    }

    var icon: String {
        switch self {
        case .waiting:
            return "clock"
        case .running:
            return "waveform.path.ecg"
        case .completed:
            return "checkmark"
        case .failed:
            return "exclamationmark"
        }
    }

    var color: Color {
        switch self {
        case .waiting:
            return .gray
        case .running:
            return WorkflowPalette.cardAccent
        case .completed:
            return TennisTheme.courtGreen
        case .failed:
            return .red
        }
    }
}

enum WorkflowPalette {
    static let heroStart = TennisTheme.courtDeepGreen
    static let heroEnd = TennisTheme.courtGreen
    static let cardAccent = TennisTheme.courtLightGreen
}

extension AnyTransition {
    static var scoreboardTicker: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .top).combined(with: .opacity),
            removal: .move(edge: .bottom).combined(with: .opacity)
        )
    }
}

extension JobExecutionState {
    var label: String {
        switch self {
        case .queued:
            return "排队中"
        case .running:
            return "处理中"
        case .completed:
            return "已完成"
        case .failed:
            return "失败"
        }
    }

    var tint: Color {
        switch self {
        case .queued:
            return TennisTheme.clayOrange
        case .running:
            return WorkflowPalette.cardAccent
        case .completed:
            return TennisTheme.courtGreen
        case .failed:
            return .red
        }
    }
}

extension JobFailureCategory {
    var tint: Color {
        switch self {
        case .modelMissing:
            return TennisTheme.clayOrange
        case .unreadableVideo:
            return .red
        case .frameExtractionFailed:
            return TennisTheme.clayOrange
        case .inferenceFailed:
            return .red
        case .syncFailed:
            return TennisTheme.clayOrange
        case .unknown:
            return TennisTheme.courtDeepGreen
        }
    }

    var icon: String {
        switch self {
        case .modelMissing:
            return "shippingbox.fill"
        case .unreadableVideo:
            return "video.slash.fill"
        case .frameExtractionFailed:
            return "film.stack.fill"
        case .inferenceFailed:
            return "cpu.fill"
        case .syncFailed:
            return "icloud.slash.fill"
        case .unknown:
            return "questionmark.circle.fill"
        }
    }
}

extension LocalAnalysisJob {
    func resolvedFailureCategory(cloudSyncState: CloudSyncState?) -> JobFailureCategory? {
        if let failureCategory {
            return failureCategory
        }
        if let cloudSyncState, case .failed = cloudSyncState {
            return .syncFailed
        }
        if state == .failed {
            return .unknown
        }
        return nil
    }
}

extension CloudSyncState {
    var label: String {
        switch self {
        case .pendingConfiguration:
            return "待配置后端"
        case .queued:
            return "等待远端分析"
        case .uploading:
            return "视频上传中"
        case .processing:
            return "远端分析中"
        case .uploaded:
            return "结构化已回填"
        case .failed:
            return "远端分析失败"
        }
    }

    var icon: String {
        switch self {
        case .pendingConfiguration:
            return "icloud.slash"
        case .queued:
            return "clock.arrow.trianglehead.counterclockwise.rotate.90"
        case .uploading:
            return "icloud.and.arrow.up"
        case .processing:
            return "gearshape.2.fill"
        case .uploaded:
            return "checkmark.icloud.fill"
        case .failed:
            return "exclamationmark.icloud.fill"
        }
    }

    var tint: Color {
        switch self {
        case .pendingConfiguration:
            return TennisTheme.clayOrange
        case .queued:
            return TennisTheme.clayOrange
        case .uploading:
            return WorkflowPalette.cardAccent
        case .processing:
            return WorkflowPalette.cardAccent
        case .uploaded:
            return TennisTheme.courtGreen
        case .failed:
            return .red
        }
    }

    var detail: String? {
        switch self {
        case .pendingConfiguration:
            return "请先填写后端 URL。保存后，新视频会自动上传到 /analysis/videos。"
        case .queued:
            return "视频已进入远端结构化分析队列。"
        case .uploading:
            return "正在上传原始视频与本地摘要元数据。"
        case .processing(let stage):
            return "当前阶段：\(stageDisplayName(for: stage))"
        case .uploaded(let remoteSessionID, let uploadedAt):
            let timeText = uploadedAt.formatted(date: .omitted, time: .shortened)
            return "远端结构化 session: \(remoteSessionID) · \(timeText)"
        case .failed(let message):
            return message
        }
    }

    var canRetry: Bool {
        switch self {
        case .pendingConfiguration, .failed:
            return true
        case .queued, .uploading, .processing, .uploaded:
            return false
        }
    }

    var showsProgress: Bool {
        switch self {
        case .uploading, .processing:
            return true
        case .pendingConfiguration, .queued, .uploaded, .failed:
            return false
        }
    }

    private func stageDisplayName(for stage: String) -> String {
        switch stage {
        case "queued":
            return "排队中"
        case "upload_received":
            return "已接收上传"
        case "court_detection":
            return "球场检测"
        case "tracknet":
            return "球轨迹推理"
        case "shot_association":
            return "击球关联"
        case "rally_segmentation":
            return "回合切分"
        case "score_timeline":
            return "比分时间线"
        case "export_contract":
            return "导出结构化数据"
        case "db_ingest":
            return "写入数据库"
        case "asset_publish":
            return "发布素材"
        case "completed":
            return "已完成"
        default:
            return stage.replacingOccurrences(of: "_", with: " ")
        }
    }
}

extension VideoInputSource {
    var label: String {
        switch self {
        case .camera:
            return "拍摄"
        case .upload:
            return "上传"
        }
    }

    var icon: String {
        switch self {
        case .camera:
            return "video.fill"
        case .upload:
            return "arrow.up.doc.fill"
        }
    }

    var tint: Color {
        switch self {
        case .camera:
            return TennisTheme.courtGreen
        case .upload:
            return TennisTheme.clayOrange
        }
    }
}

extension PipelineStage {
    static var visibleSteps: [PipelineStage] {
        [.extractingFrames, .trackingBall, .detectingCourt, .generatingSummary]
    }

    var scoreboardStep: Int {
        switch self {
        case .queued:
            return 0
        case .extractingFrames:
            return 1
        case .trackingBall:
            return 2
        case .detectingCourt:
            return 3
        case .generatingSummary:
            return 4
        case .completed:
            return 4
        case .failed:
            return 4
        }
    }

    var scoreboardLabel: String {
        switch self {
        case .queued:
            return "QUEUE READY"
        case .extractingFrames:
            return "FRAME EXTRACT"
        case .trackingBall:
            return "BALL TRACKING"
        case .detectingCourt:
            return "QUALITY SCORE"
        case .generatingSummary:
            return "SUMMARY BUILD"
        case .completed:
            return "MATCH FINISH"
        case .failed:
            return "REVIEW ERROR"
        }
    }

    var title: String {
        switch self {
        case .queued:
            return "等待队列"
        case .extractingFrames:
            return "抽取视频帧"
        case .trackingBall:
            return "球轨迹跟踪"
        case .detectingCourt:
            return "估算跟踪质量"
        case .generatingSummary:
            return "生成分析摘要"
        case .completed:
            return "任务完成"
        case .failed:
            return "任务失败"
        }
    }

    var subtitle: String {
        switch self {
        case .queued:
            return "等待可用计算资源"
        case .extractingFrames:
            return "拆分关键帧并规范化分辨率"
        case .trackingBall:
            return "识别高速轨迹与失帧片段"
        case .detectingCourt:
            return "基于可见率、置信度与连续性生成摘要指标"
        case .generatingSummary:
            return "汇总指标并生成训练建议"
        case .completed:
            return "输出报告已可查看"
        case .failed:
            return "分析流程中断"
        }
    }

    var icon: String {
        switch self {
        case .queued:
            return "hourglass"
        case .extractingFrames:
            return "rectangle.stack"
        case .trackingBall:
            return "dot.scope"
        case .detectingCourt:
            return "viewfinder"
        case .generatingSummary:
            return "doc.text.magnifyingglass"
        case .completed:
            return "checkmark.circle"
        case .failed:
            return "xmark.circle"
        }
    }

    var tint: Color {
        switch self {
        case .queued:
            return TennisTheme.clayOrange
        case .extractingFrames:
            return TennisTheme.courtGreen
        case .trackingBall:
            return TennisTheme.ballYellow
        case .detectingCourt:
            return TennisTheme.courtLightGreen
        case .generatingSummary:
            return TennisTheme.courtDeepGreen
        case .completed:
            return TennisTheme.courtGreen
        case .failed:
            return .red
        }
    }
}

// MARK: - Photo library video transferable

private struct LibraryMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("library_\(UUID().uuidString.prefix(8)).mov")
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: received.file, to: dest)
            return .init(url: dest)
        }
    }
}
