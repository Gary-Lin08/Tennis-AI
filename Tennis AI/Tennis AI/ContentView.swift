//
//  ContentView.swift
//  Tennis AI
//
//  Created by Kaijun Lin on 2026/3/11.
//

import AVKit
import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel: TennisAIViewModel
    @EnvironmentObject private var themeStore: ThemeStore
    @State private var selectedTab: AppTab
    @Environment(\.scenePhase) private var scenePhase

    init(initialTab: AppTab = .launchDefault) {
        _viewModel = StateObject(wrappedValue: TennisAIViewModel())
        _selectedTab = State(initialValue: initialTab)
    }

    init(viewModel: TennisAIViewModel, initialTab: AppTab = .launchDefault) {
        _viewModel = StateObject(wrappedValue: viewModel)
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            DashboardView(viewModel: viewModel)
                .tag(AppTab.dashboard)
                .tabItem {
                    Label("总览", systemImage: "chart.bar.xaxis")
                }

            WorkflowView(
                viewModel: viewModel
            )
                .tag(AppTab.workflow)
                .tabItem {
                    Label("工作流", systemImage: "arrow.triangle.2.circlepath.circle.fill")
                }

            TrainingView(viewModel: viewModel)
                .tag(AppTab.training)
                .tabItem {
                    Label("训练", systemImage: "figure.tennis")
                }

            ArchiveView(viewModel: viewModel)
                .tag(AppTab.archive)
                .tabItem {
                    Label("回放", systemImage: "calendar.badge.clock")
                }
        }
        .tint(themeStore.palette.courtDeepGreen)
        .onAppear {
            viewModel.trackScreenAppear(selectedTab.analyticsScreenName)
            viewModel.handleScenePhase(scenePhase)
        }
        .onDisappear {
            viewModel.trackScreenLeave(selectedTab.analyticsScreenName)
        }
        .onChange(of: selectedTab) { oldValue, newValue in
            guard oldValue != newValue else { return }
            viewModel.trackScreenLeave(oldValue.analyticsScreenName)
            viewModel.trackScreenAppear(newValue.analyticsScreenName)
            viewModel.trackTap(screen: "tab_bar", target: "switch_tab", metadata: ["to": newValue.analyticsScreenName])
        }
        .onChange(of: scenePhase) { _, newPhase in
            viewModel.handleScenePhase(newPhase)
        }
    }
}

enum AppTab: Hashable {
    case dashboard
    case workflow
    case training
    case archive

    var analyticsScreenName: String {
        switch self {
        case .dashboard:
            return "dashboard"
        case .workflow:
            return "workflow"
        case .training:
            return "training"
        case .archive:
            return "archive"
        }
    }

    static var launchDefault: AppTab {
        let arguments = ProcessInfo.processInfo.arguments

        if arguments.contains("UI_TESTS_INITIAL_TAB_DASHBOARD") {
            return .dashboard
        }

        if arguments.contains("UI_TESTS_INITIAL_TAB_TRAINING") {
            return .training
        }

        if arguments.contains("UI_TESTS_INITIAL_TAB_ARCHIVE") {
            return .archive
        }

        return .workflow
    }
}

#Preview {
    ContentView()
        .environmentObject(ThemeStore())
}

struct DashboardView: View {
    @ObservedObject var viewModel: TennisAIViewModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ThemedPageHeader(
                        title: "比赛智能分析中心",
                        subtitle: "基于球轨迹、画面连续性与本地推理的训练摘要"
                    )

                    DashboardHeroCard()
                    ModelBundleStatusCard(status: viewModel.modelStatus)
                    ModelDiagnosticsCard(
                        diagnostics: viewModel.modelDiagnostics,
                        latestSummary: viewModel.latestInferenceSummary,
                        latestInferenceDate: viewModel.latestInferenceDate
                    )

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        MetricCard(
                            title: "平均可见率",
                            value: viewModel.averageVisibleRate.formatted(.percent.precision(.fractionLength(1))),
                            subtitle: "\(viewModel.completedCount) 场已完成"
                        )

                        MetricCard(
                            title: "跟踪总帧数",
                            value: "\(viewModel.totalTrackedFrames)",
                            subtitle: "累计识别结果"
                        )

                        MetricCard(
                            title: "跟踪质量得分",
                            value: viewModel.averageCourtScore.formatted(.percent.precision(.fractionLength(1))),
                            subtitle: "基于可见率、置信度与连续性的摘要指标"
                        )

                        MetricCard(
                            title: "待处理任务",
                            value: "\(viewModel.processingCount)",
                            subtitle: "视频仍在分析中"
                        )
                    }

                    if let latest = viewModel.latestSession {
                        SessionHighlightCard(session: latest)
                    }
                }
                .padding()
            }
            .background(CourtSurfaceBackground())
            .navigationTitle("Tennis AI")
        }
    }
}

struct AnalysisListView: View {
    @ObservedObject var viewModel: TennisAIViewModel

    var body: some View {
        NavigationStack {
            List(viewModel.sessions) { session in
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
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("分析记录")
        }
    }
}

struct TrainingView: View {
    @ObservedObject var viewModel: TennisAIViewModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ThemedPageHeader(
                        title: "本周训练重点",
                        subtitle: "训练建议和视觉主题一起跟随当前场地模式。"
                    )

                    TrainingFocusHeroCard(focusHint: viewModel.focusHint)
                    if !viewModel.trendSnapshots.isEmpty {
                        TrainingTrendSection(snapshots: viewModel.trendSnapshots)
                    }

                    if let phaseReport = viewModel.defaultPhaseComparisonReport {
                        TrainingPhaseComparisonCard(report: phaseReport)
                    }

                    TrainingFeedbackLoopCard(plan: viewModel.trainingFeedbackPlan)

                    ForEach(viewModel.drills) { drill in
                        DrillCard(drill: drill)
                    }
                }
                .padding()
            }
            .background(CourtSurfaceBackground())
            .navigationTitle("训练建议")
        }
    }
}

struct ArchiveView: View {
    @ObservedObject var viewModel: TennisAIViewModel
    @State private var selectedDate = Date()
    @State private var isComparisonMode = false
    @State private var selectedComparisonSessionIDs: [UUID] = []
    @State private var comparisonHint: String?
    @State private var comparisonReport: SessionComparisonReport?
    @State private var showsComparisonReport = false
    @State private var phaseComparisonReport: TrainingPhaseComparisonReport?
    @State private var showsPhaseComparisonReport = false

    private var selectedDaySessions: [AnalysisSession] {
        viewModel.sessions(on: selectedDate)
    }

    private var selectedComparisonSessions: [AnalysisSession] {
        let lookup = Dictionary(uniqueKeysWithValues: selectedDaySessions.map { ($0.id, $0) })
        return selectedComparisonSessionIDs.compactMap { lookup[$0] }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ThemedPageHeader(
                        title: "日期回放",
                        subtitle: "选择日期，查看当天的训练视频和分析结果。"
                    )

                    DatePicker(
                        "训练日期",
                        selection: $selectedDate,
                        displayedComponents: .date
                    )
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .tennisCard()

                    ArchiveOverviewCard(
                        selectedDate: selectedDate,
                        sessionCount: selectedDaySessions.count,
                        isComparisonMode: isComparisonMode
                    )

                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            Button(isComparisonMode ? "退出对比模式" : "进入对比模式") {
                                isComparisonMode.toggle()
                            }
                            .buttonStyle(.borderedProminent)

                            if isComparisonMode {
                                Text("已选 \(selectedComparisonSessionIDs.count)/2")
                                    .font(.caption.bold())
                                    .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.82))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(TennisTheme.lineWhite.opacity(0.34))
                                    .clipShape(Capsule())
                            }

                            Spacer()
                        }

                        if isComparisonMode {
                            Button {
                                generateComparisonReport()
                            } label: {
                                Label("生成对比报告", systemImage: "chart.bar.xaxis")
                                    .font(.subheadline.bold())
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(selectedComparisonSessionIDs.count != 2)

                            if let comparisonHint {
                                Text(comparisonHint)
                                    .font(.caption2)
                                    .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.72))
                            } else {
                                Text("请从下方列表选择 2 条训练记录进行对比。")
                                    .font(.caption2)
                                    .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.68))
                            }
                        }

                        Button {
                            generatePhaseComparisonReport()
                        } label: {
                            Label("查看阶段对比", systemImage: "chart.line.uptrend.xyaxis")
                                .font(.subheadline.bold())
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .tennisCard()

                    if selectedDaySessions.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("当天暂无训练记录", systemImage: "calendar.badge.exclamationmark")
                                .font(.subheadline.bold())
                                .foregroundStyle(TennisTheme.courtDeepGreen)
                            Text("你可以先去“工作流”拍摄/上传视频，分析完成后会自动出现在这里。")
                                .font(.caption)
                                .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.68))
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .tennisCard()
                    } else {
                        ForEach(selectedDaySessions) { session in
                            ArchiveSessionCard(
                                session: session,
                                isComparisonMode: isComparisonMode,
                                isSelectedForComparison: selectedComparisonSessionIDs.contains(session.id),
                                canSelectMore: selectedComparisonSessionIDs.count < 2 || selectedComparisonSessionIDs.contains(session.id),
                                onUpdateSessionCalibration: { sessionID, calibration in
                                    viewModel.updateSessionCourtCalibration(sessionID: sessionID, calibration: calibration)
                                },
                                onUpdateSessionValidation: { sessionID, validation in
                                    viewModel.updateSessionCalibrationValidation(sessionID: sessionID, validation: validation)
                                }
                            ) {
                                toggleComparisonSelection(for: session)
                            }
                        }
                    }
                }
                .padding()
            }
            .background(CourtSurfaceBackground())
            .navigationTitle("训练回放")
            .sheet(isPresented: $showsComparisonReport) {
                if let comparisonReport {
                    SessionComparisonReportSheet(report: comparisonReport)
                }
            }
            .sheet(isPresented: $showsPhaseComparisonReport) {
                if let phaseComparisonReport {
                    TrainingPhaseComparisonReportSheet(report: phaseComparisonReport)
                }
            }
            .onChange(of: selectedDate) { _, _ in
                let availableIDs = Set(selectedDaySessions.map(\.id))
                selectedComparisonSessionIDs.removeAll { !availableIDs.contains($0) }
                if selectedComparisonSessionIDs.count < 2 {
                    comparisonHint = nil
                }
            }
            .onChange(of: isComparisonMode) { _, newValue in
                if !newValue {
                    selectedComparisonSessionIDs = []
                    comparisonHint = nil
                }
            }
        }
    }

    private func toggleComparisonSelection(for session: AnalysisSession) {
        if let existingIndex = selectedComparisonSessionIDs.firstIndex(of: session.id) {
            selectedComparisonSessionIDs.remove(at: existingIndex)
            comparisonHint = nil
            return
        }
        guard selectedComparisonSessionIDs.count < 2 else {
            comparisonHint = "最多只能选择 2 条记录。请先取消一条再选择。"
            return
        }
        selectedComparisonSessionIDs.append(session.id)
        comparisonHint = nil
    }

    private func generateComparisonReport() {
        guard selectedComparisonSessions.count == 2 else {
            comparisonHint = "请选择 2 条记录后再生成报告。"
            return
        }
        let left = selectedComparisonSessions[0]
        let right = selectedComparisonSessions[1]
        comparisonReport = SessionComparisonReport.build(left: left, right: right)
        showsComparisonReport = true
    }

    private func generatePhaseComparisonReport() {
        phaseComparisonReport = viewModel.phaseComparisonReport(endingOn: selectedDate)
        showsPhaseComparisonReport = phaseComparisonReport != nil
    }
}

struct ArchiveSessionCard: View {
    let session: AnalysisSession
    let isComparisonMode: Bool
    let isSelectedForComparison: Bool
    let canSelectMore: Bool
    let onUpdateSessionCalibration: ((UUID, SessionCourtCalibration?) -> Void)?
    let onUpdateSessionValidation: ((UUID, SessionCalibrationValidation?) -> Void)?
    let onToggleComparisonSelection: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.videoTitle)
                        .font(.headline)
                        .foregroundStyle(TennisTheme.courtDeepGreen)
                    Text(session.eventDate.formatted(date: .omitted, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.66))
                }
                Spacer()
                if isComparisonMode {
                    Button(action: onToggleComparisonSelection) {
                        Label(
                            isSelectedForComparison ? "已选择" : (canSelectMore ? "选择" : "已满"),
                            systemImage: isSelectedForComparison ? "checkmark.circle.fill" : "circle"
                        )
                        .font(.caption2.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .foregroundStyle(isSelectedForComparison ? TennisTheme.courtGreen : TennisTheme.courtDeepGreen.opacity(0.7))
                        .background((isSelectedForComparison ? TennisTheme.courtGreen : TennisTheme.lineWhite).opacity(0.18))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSelectMore && !isSelectedForComparison)
                } else {
                    if session.isBuiltInSample {
                        Label("内置样例", systemImage: "shippingbox.fill")
                            .font(.caption2.bold())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .foregroundStyle(TennisTheme.clayOrange)
                            .background(TennisTheme.clayOrange.opacity(0.12))
                            .clipShape(Capsule())
                    } else if session.localVideoURL != nil {
                        Label("可回放", systemImage: "play.circle.fill")
                            .font(.caption2.bold())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .foregroundStyle(TennisTheme.courtGreen)
                            .background(TennisTheme.courtGreen.opacity(0.14))
                            .clipShape(Capsule())
                    } else {
                        Label("仅摘要", systemImage: "text.badge.checkmark")
                            .font(.caption2.bold())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .foregroundStyle(.secondary)
                            .background(Color.black.opacity(0.05))
                            .clipShape(Capsule())
                    }
                }
            }

            HStack(spacing: 12) {
                Label(session.ballVisibleRate.formatted(.percent.precision(.fractionLength(1))), systemImage: "dot.scope")
                Label(session.trackingQualityScore.formatted(.percent.precision(.fractionLength(1))), systemImage: "viewfinder")
                Label(session.presentationOriginLabel, systemImage: session.isBuiltInSample ? "shippingbox" : "waveform.path.ecg")
            }
            .font(.caption)
            .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.76))

            if isComparisonMode {
                Button(action: onToggleComparisonSelection) {
                    Label(
                        isSelectedForComparison ? "取消对比选择" : "选为对比对象",
                        systemImage: isSelectedForComparison ? "minus.circle" : "plus.circle"
                    )
                    .font(.caption.bold())
                    .foregroundStyle(TennisTheme.courtDeepGreen)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(TennisTheme.lineWhite.opacity(0.35))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!canSelectMore && !isSelectedForComparison)
            } else {
                HStack(spacing: 10) {
                    NavigationLink {
                        AnalysisDetailView(
                            session: session,
                            onUpdateSessionCalibration: onUpdateSessionCalibration,
                            onUpdateSessionValidation: onUpdateSessionValidation
                        )
                    } label: {
                        Label("查看分析", systemImage: "chart.bar.doc.horizontal")
                            .font(.caption.bold())
                            .foregroundStyle(TennisTheme.courtDeepGreen)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(TennisTheme.ballYellow.opacity(0.78))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)

                    if let videoURL = session.localVideoURL {
                        NavigationLink {
                            SessionVideoPlaybackView(
                                session: session,
                                videoURL: videoURL,
                                onCalibrationUpdated: { calibration in
                                    onUpdateSessionCalibration?(session.id, calibration)
                                },
                                onCalibrationValidationUpdated: { validation in
                                    onUpdateSessionValidation?(session.id, validation)
                                }
                            )
                        } label: {
                            Label("回放视频", systemImage: "play.rectangle.fill")
                                .font(.caption.bold())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(TennisTheme.courtDeepGreen)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .tennisCard()
    }
}

private struct SessionComparisonReportSheet: View {
    let report: SessionComparisonReport
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("A 场：\(report.leftSession.videoTitle)")
                            .font(.subheadline.bold())
                            .foregroundStyle(TennisTheme.courtDeepGreen)
                        Text(report.leftSession.eventDate.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.66))
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .tennisCard()

                    VStack(alignment: .leading, spacing: 4) {
                        Text("B 场：\(report.rightSession.videoTitle)")
                            .font(.subheadline.bold())
                            .foregroundStyle(TennisTheme.courtDeepGreen)
                        Text(report.rightSession.eventDate.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.66))
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .tennisCard()

                    ForEach(report.metrics) { metric in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(metric.title)
                                    .font(.subheadline.bold())
                                    .foregroundStyle(TennisTheme.courtDeepGreen)
                                Spacer()
                                Text("绝对差值 \(metric.deltaText)")
                                    .font(.caption.bold())
                                    .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.74))
                            }

                            Text("更优方：\(betterSideLabel(metric.betterSide))")
                                .font(.caption2)
                                .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.72))

                            HStack(spacing: 10) {
                                valuePill(title: "A", value: metric.leftValueText, side: metric.betterSide == .left || metric.betterSide == .tie)
                                valuePill(title: "B", value: metric.rightValueText, side: metric.betterSide == .right || metric.betterSide == .tie)
                            }
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .tennisCard()
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("训练建议")
                            .font(.headline)
                            .foregroundStyle(TennisTheme.courtDeepGreen)
                        ForEach(Array(report.recommendations.enumerated()), id: \.offset) { index, recommendation in
                            Text("\(index + 1). \(recommendation)")
                                .font(.caption)
                                .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.78))
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .tennisCard()
                }
                .padding()
            }
            .background(CourtSurfaceBackground())
            .navigationTitle("双场对比报告")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func valuePill(title: String, value: String, side: Bool) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.caption.bold())
            Text(value)
                .font(.caption.bold())
        }
        .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.84))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background((side ? TennisTheme.courtGreen : TennisTheme.lineWhite).opacity(side ? 0.18 : 0.35))
        .clipShape(Capsule())
    }

    private func betterSideLabel(_ side: SessionComparisonMetricRow.BetterSide) -> String {
        switch side {
        case .left:
            return "A"
        case .right:
            return "B"
        case .tie:
            return "持平"
        case .neutral:
            return "仅展示差异"
        }
    }
}

struct SessionVideoPlaybackView: View {
    let session: AnalysisSession
    let videoURL: URL
    let onCalibrationUpdated: ((SessionCourtCalibration?) -> Void)?
    let onCalibrationValidationUpdated: ((SessionCalibrationValidation?) -> Void)?
    @Environment(\.scenePhase) private var scenePhase
    @State private var player = AVPlayer()
    @State private var videoCanvasSize = CGSize(width: 16, height: 9)
    @State private var playbackDuration: Double = 0
    @State private var currentPlaybackTime: Double = 0
    @State private var timeObserverToken: Any?
    @State private var showTrajectoryOverlay = true
    @State private var showBounceOverlay = true
    @State private var playbackZoomScale: Double = 1.0
    @State private var playbackAspectRatio: Double = 16.0 / 9.0
    @State private var isCalibratingCourt = false
    @State private var calibrationTask: Task<Void, Never>?
    @State private var calibrationProgress: Double = 0
    @State private var courtCalibration: SessionCourtCalibration?
    @State private var isValidatingCalibration = false
    @State private var calibrationValidationSamples: [CourtCalibrationValidationSample] = []
    @State private var calibrationValidationResult: CourtCalibrationValidationResult?
    @State private var calibrationMessage: String?
    @State private var shouldResumeAfterCalibration = false
    @State private var shouldResumeAfterValidation = false
    @State private var isSelectingFocusTarget = false
    @State private var focusTargetSourcePoint: CGPoint?
    @State private var focusTrackingActionType: ActionType?
    @State private var shouldResumeAfterFocusSelection = false
    @State private var focusStatusMessage: String?
    @State private var focusSmoothingFactor: Double = 0.32
    @State private var smoothedFocusSourcePoint: CGPoint?
    @State private var showsExportSheet = false
    @State private var exportOverlayOptions = ExportOverlayOptions(
        showsTrajectory: true,
        showsBounces: true,
        showsActionLabels: false,
        showsMiniCourtMap: true,
        showsUncertaintyRings: true,
        showsSummaryCard: true
    )
    @State private var exportState: VideoExportState = .idle
    @State private var exportRenderer: VideoExportRenderer?
    @State private var exportTask: Task<Void, Never>?
    @State private var exportedVideoURL: URL?
    @State private var showsShareSheet = false

    init(
        session: AnalysisSession,
        videoURL: URL,
        onCalibrationUpdated: ((SessionCourtCalibration?) -> Void)? = nil,
        onCalibrationValidationUpdated: ((SessionCalibrationValidation?) -> Void)? = nil
    ) {
        self.session = session
        self.videoURL = videoURL
        self.onCalibrationUpdated = onCalibrationUpdated
        self.onCalibrationValidationUpdated = onCalibrationValidationUpdated
    }

    private let minPlaybackAspectRatio: Double = 9.0 / 16.0
    private let maxPlaybackAspectRatio: Double = 16.0 / 9.0
    private let zoomPresets: [Double] = [1.0, 1.5, 2.0, 2.5, 3.0]
    private let aspectPresets: [(title: String, ratio: Double)] = [
        ("9:16", 9.0 / 16.0),
        ("3:4", 3.0 / 4.0),
        ("1:1", 1.0),
        ("4:3", 4.0 / 3.0),
        ("3:2", 3.0 / 2.0),
        ("16:9", 16.0 / 9.0)
    ]

    private var clampedPlaybackAspectRatio: CGFloat {
        CGFloat(min(max(playbackAspectRatio, minPlaybackAspectRatio), maxPlaybackAspectRatio))
    }

    private var zoomScaleText: String {
        String(format: "%.1fx", playbackZoomScale)
    }

    private var aspectRatioText: String {
        let presets: [(String, Double)] = [
            ("9:16", 9.0 / 16.0),
            ("3:4", 3.0 / 4.0),
            ("1:1", 1.0),
            ("4:3", 4.0 / 3.0),
            ("3:2", 3.0 / 2.0),
            ("16:9", 16.0 / 9.0)
        ]
        let value = playbackAspectRatio
        if let nearest = presets.min(by: { abs($0.1 - value) < abs($1.1 - value) }),
           abs(nearest.1 - value) <= 0.03 {
            return nearest.0
        }
        if value >= 1 {
            return String(format: "%.2f:1", value)
        }
        return String(format: "1:%.2f", 1.0 / max(value, 0.01))
    }

    private var naturalPlaybackAspectRatio: Double {
        Double(videoCanvasSize.width / max(videoCanvasSize.height, 1))
    }

    private var isZoomAtDefault: Bool {
        abs(playbackZoomScale - 1.0) <= 0.01
    }

    private var defaultPlaybackAspectRatio: Double {
        min(max(naturalPlaybackAspectRatio, minPlaybackAspectRatio), maxPlaybackAspectRatio)
    }

    private var isAspectAtDefault: Bool {
        abs(playbackAspectRatio - defaultPlaybackAspectRatio) <= 0.015
    }

    private func isZoomPresetSelected(_ value: Double) -> Bool {
        abs(playbackZoomScale - value) <= 0.05
    }

    private func isAspectPresetSelected(_ value: Double) -> Bool {
        abs(playbackAspectRatio - value) <= 0.015
    }

    private var projectionMode: CourtProjectionMode {
        if let courtCalibration {
            return .calibrated(score: courtCalibration.qualityScore)
        }
        return .approximate
    }

    private var shouldRecommendRecalibration: Bool {
        CourtRecalibrationAdvisor.shouldRecommendRecalibration(
            calibrationScore: courtCalibration?.qualityScore,
            validationTier: calibrationValidationResult?.tier
        )
    }

    private var recalibrationRecommendationText: String {
        CourtRecalibrationAdvisor.recommendationText(
            calibrationScore: courtCalibration?.qualityScore,
            validationTier: calibrationValidationResult?.tier
        )
    }

    private var displayedMappedBouncePoints: [CourtMappedBounce] {
        CourtBounceProjector.map(
            points: displayedBouncePoints,
            frameSize: videoCanvasSize,
            calibration: courtCalibration
        )
    }

    private var displayedMappedBounceCountInBounds: Int {
        displayedMappedBouncePoints.filter(\.isInBounds).count
    }

    private var calibrationProgressText: String {
        "自动标定 \(Int((calibrationProgress * 100).rounded()))%"
    }

    private var validationTargets: [CourtCalibrationValidationTarget] {
        CourtCalibrationValidator.defaultTargets
    }

    private var currentValidationTarget: CourtCalibrationValidationTarget? {
        guard isValidatingCalibration else { return nil }
        guard calibrationValidationSamples.count < validationTargets.count else { return nil }
        return validationTargets[calibrationValidationSamples.count]
    }

    private var validationProgressText: String {
        if let target = currentValidationTarget {
            return "点 \(calibrationValidationSamples.count + 1)/\(validationTargets.count)：\(target.displayName)"
        }
        return "验证点已采集完成"
    }

    private var visibleTrajectoryPoints: [InferencePoint] {
        (session.trajectoryPoints ?? [])
            .filter(\.isVisible)
            .sorted { $0.frameIndex < $1.frameIndex }
    }

    private var detectedBouncePoints: [InferencePoint] {
        (session.bouncePoints ?? [])
            .sorted { $0.frameIndex < $1.frameIndex }
    }

    private var recognizedActions: [DetectedAction] {
        (session.detectedActions ?? [])
            .sorted { $0.frameIndex < $1.frameIndex }
    }

    private var forehandActionCount: Int {
        recognizedActions.filter { $0.type == .forehand }.count
    }

    private var backhandActionCount: Int {
        recognizedActions.filter { $0.type == .backhand }.count
    }

    private var serveActionCount: Int {
        recognizedActions.filter { $0.type == .serve }.count
    }

    private var currentModelFrame: Int? {
        guard maxPlaybackModelFrame > 0 else {
            return nil
        }
        guard playbackDuration > 0 else { return nil }
        let progress = min(max(currentPlaybackTime / playbackDuration, 0), 1)
        return Int((progress * Double(maxPlaybackModelFrame)).rounded())
    }

    private var maxPlaybackModelFrame: Int {
        max(
            visibleTrajectoryPoints.map(\.frameIndex).max() ?? 0,
            max(
                detectedBouncePoints.map(\.frameIndex).max() ?? 0,
                recognizedActions.map(\.frameIndex).max() ?? 0
            )
        )
    }

    private var playbackHighlights: [SessionPlaybackHighlight] {
        session.playbackHighlights
    }

    private var displayedTrajectoryPoints: [InferencePoint] {
        guard let frame = currentModelFrame else { return visibleTrajectoryPoints }
        return visibleTrajectoryPoints.filter { $0.frameIndex <= frame }
    }

    private var displayedBouncePoints: [InferencePoint] {
        guard let frame = currentModelFrame else { return detectedBouncePoints }
        return detectedBouncePoints.filter { $0.frameIndex <= frame }
    }

    private var highlightedTrajectoryPoint: InferencePoint? {
        guard let frame = currentModelFrame else { return nil }
        return visibleTrajectoryPoints.min(by: {
            abs($0.frameIndex - frame) < abs($1.frameIndex - frame)
        })
    }

    private var highlightedBouncePoint: InferencePoint? {
        guard let frame = currentModelFrame else { return nil }
        guard let nearest = detectedBouncePoints.min(by: {
            abs($0.frameIndex - frame) < abs($1.frameIndex - frame)
        }) else {
            return nil
        }
        return abs(nearest.frameIndex - frame) <= 6 ? nearest : nil
    }

    private var currentAction: DetectedAction? {
        guard let frame = currentModelFrame else { return nil }
        guard let nearest = recognizedActions.min(by: {
            abs($0.frameIndex - frame) < abs($1.frameIndex - frame)
        }) else {
            return nil
        }
        return abs(nearest.frameIndex - frame) <= 8 ? nearest : nil
    }

    private var activeFocusSourcePoint: CGPoint? {
        guard let baseFocus = focusTargetSourcePoint else { return nil }
        guard let frame = currentModelFrame,
              let trackingType = focusTrackingActionType,
              let autoPoint = nearestActionPoint(frame: frame, around: baseFocus, type: trackingType) else {
            return baseFocus
        }
        return autoPoint
    }

    private var focusModeSummary: String {
        guard focusTargetSourcePoint != nil else { return "未锁定目标" }
        if let type = focusTrackingActionType {
            return "已锁定目标（跟随 \(type.displayName) 动作点）"
        }
        return "已锁定目标（静态中心）"
    }

    private var focusSmoothingText: String {
        "\(Int((min(max(focusSmoothingFactor, 0), 1)) * 100))%"
    }

    private var exportProgressValue: Double {
        if case .exporting(let progress) = exportState {
            return min(max(progress, 0), 1)
        }
        return 0
    }

    private var exportDisabledReason: String? {
        guard session.localVideoURL != nil else {
            return "当前会话无本地视频，无法导出。"
        }
        guard FileManager.default.fileExists(atPath: videoURL.path) else {
            return "本地视频文件已不存在，无法导出。"
        }
        return nil
    }

    private var canExportPlayback: Bool {
        exportDisabledReason == nil
    }

    private var exportStatusText: String {
        switch exportState {
        case .idle:
            return exportDisabledReason ?? "未开始导出。"
        case .exporting(let progress):
            return "导出中 \(Int(progress * 100))%"
        case .success:
            return "导出完成，可立即分享。"
        case .failed(let message):
            return message
        }
    }

    private var sessionForDetailView: AnalysisSession {
        var updated = session
        updated.courtCalibration = courtCalibration
        updated.calibrationValidation = calibrationValidationResult?.sessionValidation
        return updated
    }

    var body: some View {
        ScrollView {
            playbackContent
                .padding()
        }
        .background(CourtSurfaceBackground())
        .navigationTitle("视频回放")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showsExportSheet) {
            exportSheetContent
        }
        .sheet(isPresented: $showsShareSheet) {
            if let exportedVideoURL {
                ShareSheet(activityItems: [exportedVideoURL])
            }
        }
        .onAppear {
            courtCalibration = session.courtCalibration
            if let existingValidation = session.calibrationValidation {
                calibrationValidationResult = CourtCalibrationValidationResult(sessionValidation: existingValidation)
            } else {
                calibrationValidationResult = nil
            }
            player = AVPlayer(url: videoURL)
            player.play()
            attachPlaybackObserver()
            Task {
                let metadata = await resolveVideoMetadata(for: videoURL)
                videoCanvasSize = metadata.size
                playbackDuration = metadata.duration
                let naturalRatio = Double(metadata.size.width / max(metadata.size.height, 1))
                playbackAspectRatio = min(max(naturalRatio, minPlaybackAspectRatio), maxPlaybackAspectRatio)
                beginCourtCalibrationIfNeeded()
            }
        }
        .onDisappear {
            calibrationTask?.cancel()
            calibrationTask = nil
            calibrationProgress = 0
            isCalibratingCourt = false
            isValidatingCalibration = false
            calibrationValidationSamples = []
            isSelectingFocusTarget = false
            shouldResumeAfterFocusSelection = false
            shouldResumeAfterValidation = false
            smoothedFocusSourcePoint = nil
            cancelExport(cleanupState: false)
            detachPlaybackObserver()
            player.pause()
            player.replaceCurrentItem(with: nil)
        }
        .onChange(of: scenePhase) { _, newPhase in
            handleScenePhaseChange(newPhase)
        }
    }

    private var playbackContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            playbackCanvasSection
            playbackAdjustmentSection
            playbackHeaderSection
            playbackOverlaySummarySection
            playbackHighlightsSection
            playbackCalibrationSection

            if let calibrationMessage {
                Text(calibrationMessage)
                    .font(.caption2)
                    .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.74))
            }

            analysisLinkSection
        }
        .padding()
        .tennisCard()
    }

    private var playbackCanvasSection: some View {
        GeometryReader { proxy in
            let containerSize = proxy.size
            let followOffset = focusOffset(for: containerSize)

            ZStack {
                playbackSurface(followOffset: followOffset)

                if isSelectingFocusTarget {
                    FocusSelectionMaskOverlay()
                } else if focusTargetSourcePoint != nil && !isCalibratingCourt && !isValidatingCalibration {
                    FocusLockReticleOverlay()
                }
            }
            .overlay {
                if isSelectingFocusTarget {
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onEnded { value in
                                    handleFocusSelectionTap(
                                        value.location,
                                        containerSize: containerSize,
                                        appliedOffset: followOffset
                                    )
                                }
                        )
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            if !detectedBouncePoints.isEmpty && !isCalibratingCourt && !isValidatingCalibration {
                MiniCourtBounceMap(
                    mappedBouncePoints: displayedMappedBouncePoints,
                    totalBounceCount: detectedBouncePoints.count,
                    inBoundsCount: displayedMappedBounceCountInBounds,
                    projectionMode: projectionMode,
                    validationResult: calibrationValidationResult,
                    sourceFrameSize: videoCanvasSize,
                    showsUncertaintyRings: exportOverlayOptions.showsUncertaintyRings
                )
                .padding(10)
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(clampedPlaybackAspectRatio, contentMode: .fit)
        .background(Color.black.opacity(0.92))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        }
    }

    @ViewBuilder
    private func playbackSurface(followOffset: CGSize) -> some View {
        ZStack {
            VideoPlayer(player: player)

            if showTrajectoryOverlay || showBounceOverlay {
                BallTrajectoryOverlay(
                    trajectoryPoints: showTrajectoryOverlay ? displayedTrajectoryPoints : [],
                    bouncePoints: showBounceOverlay ? displayedBouncePoints : [],
                    sourceSize: videoCanvasSize,
                    highlightedPoint: showTrajectoryOverlay ? highlightedTrajectoryPoint : nil,
                    highlightedBounce: showBounceOverlay ? highlightedBouncePoint : nil
                )
            }

            if isCalibratingCourt {
                AutoCourtCalibrationOverlay(
                    progress: calibrationProgress,
                    statusText: calibrationMessage ?? "自动标定中…"
                )
            } else if isValidatingCalibration {
                CourtCalibrationValidationOverlay(
                    sourceSize: videoCanvasSize,
                    selectedSamples: calibrationValidationSamples,
                    currentTarget: currentValidationTarget,
                    onSelectPoint: appendValidationPoint
                )
            }
        }
        .scaleEffect(playbackZoomScale, anchor: .center)
        .offset(followOffset)
        .animation(.easeOut(duration: 0.12), value: followOffset)
    }

    private var playbackAdjustmentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("放大倍率", systemImage: "plus.magnifyingglass")
                    .font(.caption.bold())
                    .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.86))
                Spacer()
                Text(zoomScaleText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.72))
            }
            Slider(value: $playbackZoomScale, in: 1.0 ... 3.5, step: 0.1)
                .tint(TennisTheme.ballYellow)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(zoomPresets, id: \.self) { preset in
                        PlaybackPresetChip(
                            title: String(format: "%.1fx", preset),
                            isSelected: isZoomPresetSelected(preset),
                            accent: TennisTheme.ballYellow
                        ) {
                            withAnimation(.easeOut(duration: 0.16)) {
                                playbackZoomScale = preset
                            }
                        }
                    }
                }
            }

            HStack {
                Label("视频比例", systemImage: "aspectratio")
                    .font(.caption.bold())
                    .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.86))
                Spacer()
                Text(aspectRatioText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.72))
            }
            Slider(value: $playbackAspectRatio, in: minPlaybackAspectRatio ... maxPlaybackAspectRatio, step: 0.01)
                .tint(TennisTheme.clayOrange)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(aspectPresets, id: \.title) { preset in
                        PlaybackPresetChip(
                            title: preset.title,
                            isSelected: isAspectPresetSelected(preset.ratio),
                            accent: TennisTheme.clayOrange
                        ) {
                            withAnimation(.easeOut(duration: 0.16)) {
                                playbackAspectRatio = preset.ratio
                            }
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button {
                    withAnimation(.easeOut(duration: 0.18)) {
                        playbackZoomScale = 1.0
                        playbackAspectRatio = defaultPlaybackAspectRatio
                    }
                } label: {
                    Label("重置画面", systemImage: "arrow.counterclockwise")
                        .font(.caption.bold())
                        .foregroundStyle(TennisTheme.courtDeepGreen)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(TennisTheme.lineWhite.opacity(0.35))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .opacity((isZoomAtDefault && isAspectAtDefault) ? 0.45 : 1)
            }

            HStack(spacing: 8) {
                Button(isSelectingFocusTarget ? "取消选目标" : (focusTargetSourcePoint == nil ? "选择跟踪目标" : "重选跟踪目标")) {
                    toggleFocusTargetSelection()
                }
                .buttonStyle(.borderedProminent)

                if focusTargetSourcePoint != nil {
                    Button("清除目标") {
                        clearFocusTarget()
                    }
                    .buttonStyle(.bordered)
                }

                Spacer()
            }

            Text(focusModeSummary)
                .font(.caption2)
                .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.76))

            if let focusStatusMessage {
                Text(focusStatusMessage)
                    .font(.caption2)
                    .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.68))
            }

            if focusTargetSourcePoint != nil {
                HStack {
                    Label("跟随平滑度", systemImage: "waveform.path.ecg")
                        .font(.caption.bold())
                        .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.82))
                    Spacer()
                    Text(focusSmoothingText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.68))
                }
                Slider(value: $focusSmoothingFactor, in: 0.08 ... 0.85, step: 0.01)
                    .tint(TennisTheme.courtGreen)
            }

            HStack(spacing: 8) {
                Button {
                    showsExportSheet = true
                } label: {
                    Label("导出回放", systemImage: "square.and.arrow.up")
                        .font(.subheadline.bold())
                }
                .buttonStyle(.borderedProminent)
                .disabled(exportState.isExporting || !canExportPlayback)

                if exportState.isExporting {
                    Button("取消导出") {
                        cancelExport()
                    }
                    .buttonStyle(.bordered)
                } else if case .success = exportState {
                    Button("分享") {
                        if exportedVideoURL != nil {
                            showsShareSheet = true
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(exportedVideoURL == nil)
                }

                Spacer()
            }

            Text(exportStatusText)
                .font(.caption2)
                .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.72))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.86))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(TennisTheme.lineWhite.opacity(0.3), lineWidth: 1)
        }
        .disabled(isCalibratingCourt || isValidatingCalibration)
        .opacity((isCalibratingCourt || isValidatingCalibration) ? 0.72 : 1)
    }

    private var playbackHeaderSection: some View {
        HStack {
            Text(session.videoTitle)
                .font(.headline)
                .foregroundStyle(TennisTheme.courtDeepGreen)
            Spacer()
            Text(session.eventDate.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.66))
        }
    }

    @ViewBuilder
    private var playbackOverlaySummarySection: some View {
        if !visibleTrajectoryPoints.isEmpty {
            HStack(spacing: 10) {
                OverlayToggleChip(
                    color: TennisTheme.ballYellow,
                    title: "轨迹 \(displayedTrajectoryPoints.count)/\(visibleTrajectoryPoints.count)",
                    isOn: showTrajectoryOverlay
                ) {
                    showTrajectoryOverlay.toggle()
                }
                OverlayToggleChip(
                    color: TennisTheme.clayOrange,
                    title: "弹跳 \(displayedBouncePoints.count)/\(detectedBouncePoints.count)",
                    isOn: showBounceOverlay
                ) {
                    showBounceOverlay.toggle()
                }
                Spacer()
            }
        } else {
            Text("暂无可叠加的模型轨迹点。")
                .font(.caption)
                .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.58))
        }

        if calibrationValidationResult != nil {
            HStack(spacing: 10) {
                OverlayToggleChip(
                    color: TennisTheme.courtGreen,
                    title: "误差圈",
                    isOn: exportOverlayOptions.showsUncertaintyRings
                ) {
                    exportOverlayOptions.showsUncertaintyRings.toggle()
                }
                Spacer()
            }
        }

        if !recognizedActions.isEmpty {
            HStack(spacing: 8) {
                OverlayInfoChip(color: TennisTheme.courtGreen, title: "正手 \(forehandActionCount)")
                OverlayInfoChip(color: TennisTheme.clayOrange, title: "反手 \(backhandActionCount)")
                OverlayInfoChip(color: TennisTheme.ballYellow, title: "发球 \(serveActionCount)")
                Spacer()
            }

            if let currentAction {
                Text("当前动作：\(currentAction.type.displayName)（置信度 \(currentAction.confidence.formatted(.number.precision(.fractionLength(2))))）")
                    .font(.caption)
                    .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.74))
            }
        }
    }

    @ViewBuilder
    private var playbackHighlightsSection: some View {
        if !playbackHighlights.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("关键片段")
                    .font(.subheadline.bold())
                    .foregroundStyle(TennisTheme.courtDeepGreen)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(playbackHighlights) { highlight in
                            PlaybackHighlightChip(highlight: highlight) {
                                seekToHighlight(highlight)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    @ViewBuilder
    private var playbackCalibrationSection: some View {
        if !detectedBouncePoints.isEmpty {
            if isCalibratingCourt {
                calibrationStatusSection
            } else if isValidatingCalibration {
                calibrationValidationSection
            } else {
                calibrationActionsSection
            }
        }
    }

    private var calibrationStatusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("自动球场标定进行中：\(calibrationProgressText)")
                .font(.caption.bold())
                .foregroundStyle(TennisTheme.courtDeepGreen)

            HStack(spacing: 8) {
                ProgressView(value: calibrationProgress)
                    .tint(TennisTheme.courtGreen)

                Button("停止") {
                    cancelCourtCalibration()
                }
                .buttonStyle(.bordered)

                Spacer()
            }
        }
    }

    private var calibrationValidationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("精度验证进行中：\(validationProgressText)")
                .font(.caption.bold())
                .foregroundStyle(TennisTheme.courtDeepGreen)

            HStack(spacing: 8) {
                Button("撤销") {
                    if !calibrationValidationSamples.isEmpty {
                        calibrationValidationSamples.removeLast()
                    }
                }
                .buttonStyle(.bordered)
                .disabled(calibrationValidationSamples.isEmpty)

                Button("重置") {
                    calibrationValidationSamples = []
                }
                .buttonStyle(.bordered)

                Button("取消") {
                    cancelCalibrationValidation()
                }
                .buttonStyle(.bordered)

                Spacer()
            }
        }
    }

    private var calibrationActionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button(courtCalibration == nil ? "自动标定球场" : "重新自动标定") {
                    beginCourtCalibration()
                }
                .buttonStyle(.borderedProminent)

                if courtCalibration != nil {
                    Button("验证精度") {
                        beginCalibrationValidation()
                    }
                    .buttonStyle(.bordered)

                    Button("清除标定") {
                        clearCourtCalibration()
                    }
                    .buttonStyle(.bordered)
                }

                Spacer()

                Text(projectionMode.inlineSummary)
                    .font(.caption)
                    .foregroundStyle(projectionMode.tint)
            }

            if let calibrationValidationResult {
                Text(calibrationValidationResult.inlineSummary)
                    .font(.caption2)
                    .foregroundStyle(calibrationValidationResult.tint)
            }

            if shouldRecommendRecalibration {
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(TennisTheme.clayOrange)

                    Text(recalibrationRecommendationText)
                        .font(.caption2)
                        .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.84))

                    Spacer()

                    Button("立即重新标定") {
                        beginCourtCalibration()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(TennisTheme.clayOrange)
                }
            }
        }
    }

    private var analysisLinkSection: some View {
        NavigationLink {
            AnalysisDetailView(
                session: sessionForDetailView,
                onUpdateSessionCalibration: { _, calibration in
                    onCalibrationUpdated?(calibration)
                },
                onUpdateSessionValidation: { _, validation in
                    onCalibrationValidationUpdated?(validation)
                }
            )
        } label: {
            Label("查看该视频分析", systemImage: "chart.bar.doc.horizontal")
                .font(.subheadline.bold())
                .foregroundStyle(TennisTheme.courtDeepGreen)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(TennisTheme.ballYellow)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var exportSheetContent: some View {
        NavigationStack {
            Form {
                Section("导出图层") {
                    Toggle("轨迹", isOn: $exportOverlayOptions.showsTrajectory)
                    Toggle("弹跳", isOn: $exportOverlayOptions.showsBounces)
                    Toggle("动作标签", isOn: $exportOverlayOptions.showsActionLabels)
                    Toggle("小地图", isOn: $exportOverlayOptions.showsMiniCourtMap)
                    Toggle("误差圈", isOn: $exportOverlayOptions.showsUncertaintyRings)
                        .disabled(!exportOverlayOptions.showsMiniCourtMap || calibrationValidationResult == nil)
                    Toggle("摘要卡片", isOn: $exportOverlayOptions.showsSummaryCard)
                }

                Section("导出参数快照") {
                    HStack {
                        Text("放大倍率")
                        Spacer()
                        Text(String(format: "%.1fx", playbackZoomScale))
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("视频比例")
                        Spacer()
                        Text(aspectRatioText)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("目标锁定")
                        Spacer()
                        Text(focusTargetSourcePoint == nil ? "未锁定" : "已锁定")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("导出状态") {
                    if exportState.isExporting {
                        ProgressView(value: exportProgressValue)
                    }
                    Text(exportStatusText)
                        .font(.caption)
                }
            }
            .navigationTitle("导出回放")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        showsExportSheet = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(exportState.isExporting ? "导出中" : "开始导出") {
                        startExport()
                    }
                    .disabled(exportState.isExporting || !canExportPlayback)
                }
            }
        }
    }

    private func beginCourtCalibrationIfNeeded() {
        guard courtCalibration == nil else { return }
        guard !detectedBouncePoints.isEmpty else { return }
        guard !isCalibratingCourt, !isValidatingCalibration else { return }
        beginCourtCalibration(triggeredAutomatically: true)
    }

    private func beginCourtCalibration(triggeredAutomatically: Bool = false) {
        guard !isCalibratingCourt else { return }
        isValidatingCalibration = false
        calibrationValidationSamples = []
        shouldResumeAfterValidation = false
        isSelectingFocusTarget = false
        shouldResumeAfterFocusSelection = false
        shouldResumeAfterCalibration = player.rate > 0
        player.pause()
        playbackZoomScale = 1.0
        playbackAspectRatio = min(max(naturalPlaybackAspectRatio, minPlaybackAspectRatio), maxPlaybackAspectRatio)
        calibrationTask?.cancel()
        calibrationTask = nil
        calibrationProgress = 0
        isCalibratingCourt = true
        calibrationMessage = triggeredAutomatically
            ? "正在自动标定球场，扫描视频中的球场线…"
            : "正在重新自动标定球场…"

        let calibrator = AutoCourtCalibrator()
        let sourceURL = videoURL
        let modelPrior = session.trackingQualityScore

        calibrationTask = Task {
            do {
                let result = try await calibrator.calibrate(
                    videoURL: sourceURL,
                    trackingQualityScore: modelPrior
                ) { ratio in
                    Task { @MainActor in
                        calibrationProgress = ratio
                    }
                }

                if Task.isCancelled { return }
                await MainActor.run {
                    guard isCalibratingCourt else {
                        calibrationTask = nil
                        return
                    }
                    applyAutomaticCalibration(result)
                }
            } catch is CancellationError {
                await MainActor.run {
                    calibrationTask = nil
                }
            } catch {
                await MainActor.run {
                    guard isCalibratingCourt else {
                        calibrationTask = nil
                        return
                    }
                    calibrationTask = nil
                    calibrationProgress = 0
                    isCalibratingCourt = false
                    calibrationMessage = "自动标定失败：\(error.localizedDescription)"
                    if shouldResumeAfterCalibration {
                        player.play()
                    }
                    shouldResumeAfterCalibration = false
                }
            }
        }
    }

    private func cancelCourtCalibration() {
        calibrationTask?.cancel()
        calibrationTask = nil
        calibrationProgress = 0
        isCalibratingCourt = false
        calibrationMessage = "已取消自动标定。"
        if shouldResumeAfterCalibration {
            player.play()
        }
        shouldResumeAfterCalibration = false
    }

    private func clearCourtCalibration() {
        calibrationTask?.cancel()
        calibrationTask = nil
        calibrationProgress = 0
        courtCalibration = nil
        calibrationValidationResult = nil
        calibrationValidationSamples = []
        onCalibrationUpdated?(nil)
        onCalibrationValidationUpdated?(nil)
        calibrationMessage = "已清除自动标定，当前使用估算落点映射。"
    }

    private func applyAutomaticCalibration(_ result: AutoCourtCalibrationResult) {
        courtCalibration = result.calibration
        onCalibrationUpdated?(result.calibration)
        calibrationValidationResult = nil
        calibrationValidationSamples = []
        onCalibrationValidationUpdated?(nil)
        calibrationTask = nil
        calibrationProgress = 0
        isCalibratingCourt = false
        calibrationMessage = "自动标定完成：\(CourtProjectionMode.calibrated(score: result.calibration.qualityScore).inlineSummary)（检测 \(result.validDetections)/\(result.sampleCount) 帧）。"

        if shouldResumeAfterCalibration {
            player.play()
        }
        shouldResumeAfterCalibration = false
    }

    private func beginCalibrationValidation() {
        guard let courtCalibration else {
            calibrationMessage = "请先完成自动球场标定。"
            return
        }

        guard courtCalibration.homography.inverted() != nil else {
            calibrationMessage = "当前自动标定无法验证精度，请重新自动标定。"
            return
        }

        shouldResumeAfterValidation = player.rate > 0
        player.pause()
        isSelectingFocusTarget = false
        shouldResumeAfterFocusSelection = false
        shouldResumeAfterCalibration = false
        isCalibratingCourt = false
        isValidatingCalibration = true
        calibrationValidationSamples = []
        calibrationMessage = "请按顺序点击 3 个校验点：网带中心、近端发球 T、远端发球 T。"
    }

    private func appendValidationPoint(_ point: CGPoint) {
        guard isValidatingCalibration else { return }
        guard let courtCalibration else { return }
        guard let target = currentValidationTarget else { return }
        guard let inverseHomography = courtCalibration.homography.inverted(),
              let expectedSource = inverseHomography.project(target.normalizedCourtPoint) else {
            cancelCalibrationValidation(message: "验证中断：单应矩阵不可逆，请重新自动标定。")
            return
        }

        calibrationValidationSamples.append(
            CourtCalibrationValidationSample(
                target: target,
                observedSourcePoint: point,
                expectedSourcePoint: expectedSource,
                errorPixels: Double(distance(point, expectedSource))
            )
        )

        if calibrationValidationSamples.count == validationTargets.count {
            completeCalibrationValidation()
        }
    }

    private func cancelCalibrationValidation(message: String = "已取消精度验证。") {
        isValidatingCalibration = false
        calibrationValidationSamples = []
        calibrationMessage = message
        if shouldResumeAfterValidation {
            player.play()
        }
        shouldResumeAfterValidation = false
    }

    private func completeCalibrationValidation() {
        guard let result = CourtCalibrationValidator.buildResult(
            samples: calibrationValidationSamples,
            frameSize: videoCanvasSize
        ) else {
            cancelCalibrationValidation(message: "验证失败：采样点不足，请重试。")
            return
        }

        calibrationValidationResult = result
        onCalibrationValidationUpdated?(result.sessionValidation)
        calibrationValidationSamples = []
        isValidatingCalibration = false
        calibrationMessage = "精度验证完成：\(result.inlineSummary)"

        if shouldResumeAfterValidation {
            player.play()
        }
        shouldResumeAfterValidation = false
    }

    private func distance(_ p0: CGPoint, _ p1: CGPoint) -> CGFloat {
        let dx = p1.x - p0.x
        let dy = p1.y - p0.y
        return sqrt(dx * dx + dy * dy)
    }

    private func startExport() {
        guard !exportState.isExporting else { return }
        guard canExportPlayback else {
            exportState = .failed(message: exportDisabledReason ?? "没有可导出的本地视频。")
            return
        }

        cancelExport(cleanupState: false)
        exportState = .exporting(progress: 0)
        exportedVideoURL = nil

        let config = PlaybackExportConfig(
            zoomScale: playbackZoomScale,
            aspectRatio: playbackAspectRatio,
            focusTargetSourcePoint: focusTargetSourcePoint,
            focusTrackingActionType: focusTrackingActionType,
            focusSmoothingFactor: focusSmoothingFactor,
            overlays: exportOverlayOptions
        )

        let renderer = VideoExportRenderer()
        exportRenderer = renderer

        exportTask = Task {
            do {
                let exportedURL = try await renderer.export(
                    videoURL: videoURL,
                    session: sessionForDetailView,
                    config: config
                ) { progress in
                    Task { @MainActor in
                        exportState = .exporting(progress: progress)
                    }
                }

                if Task.isCancelled { return }
                await MainActor.run {
                    exportedVideoURL = exportedURL
                    exportState = .success(fileURL: exportedURL)
                    showsShareSheet = true
                }
            } catch let error as VideoExportRendererError {
                await MainActor.run {
                    exportState = .failed(message: error.localizedDescription)
                }
            } catch {
                await MainActor.run {
                    exportState = .failed(message: error.localizedDescription)
                }
            }
            await MainActor.run {
                exportTask = nil
                exportRenderer = nil
            }
        }
    }

    private func cancelExport(
        cleanupState: Bool = true,
        cancellationMessage: String = "导出已取消。"
    ) {
        exportRenderer?.cancel()
        exportTask?.cancel()
        exportTask = nil
        exportRenderer = nil
        if cleanupState {
            if exportState.isExporting {
                exportState = .failed(message: cancellationMessage)
            }
        }
    }

    private func handleScenePhaseChange(_ phase: ScenePhase) {
        guard phase == .background else { return }
        guard exportState.isExporting else { return }
        cancelExport(cleanupState: true, cancellationMessage: "导出在进入后台时被中断，请回到前台后重新导出。")
    }

    private func toggleFocusTargetSelection() {
        if isSelectingFocusTarget {
            isSelectingFocusTarget = false
            focusStatusMessage = "已取消目标选择。"
            if shouldResumeAfterFocusSelection {
                player.play()
            }
            shouldResumeAfterFocusSelection = false
            return
        }

        shouldResumeAfterFocusSelection = player.rate > 0
        player.pause()
        isSelectingFocusTarget = true
        focusStatusMessage = "请在画面中点选要跟踪放大的球员。"
    }

    private func clearFocusTarget() {
        focusTargetSourcePoint = nil
        focusTrackingActionType = nil
        smoothedFocusSourcePoint = nil
        focusStatusMessage = "已清除目标，画面回到中心缩放。"
    }

    private func seekToHighlight(_ highlight: SessionPlaybackHighlight) {
        guard playbackDuration > 0, maxPlaybackModelFrame > 0 else { return }

        let targetSeconds = min(
            max(Double(highlight.frameIndex) / Double(maxPlaybackModelFrame) * playbackDuration, 0),
            playbackDuration
        )
        let targetTime = CMTime(seconds: targetSeconds, preferredTimescale: 600)
        let shouldResume = player.rate > 0
        player.pause()
        player.seek(
            to: targetTime,
            toleranceBefore: CMTime(seconds: 0.02, preferredTimescale: 600),
            toleranceAfter: CMTime(seconds: 0.02, preferredTimescale: 600)
        ) { _ in
            currentPlaybackTime = targetSeconds
            updateSmoothedFocusPoint()
            if shouldResume {
                player.play()
            }
        }
    }

    private func handleFocusSelectionTap(
        _ displayPoint: CGPoint,
        containerSize: CGSize,
        appliedOffset: CGSize
    ) {
        guard let sourcePoint = mapDisplayPointToSource(
            displayPoint,
            containerSize: containerSize,
            appliedOffset: appliedOffset
        ) else {
            focusStatusMessage = "请点选视频内容区域内的球员。"
            return
        }

        focusTargetSourcePoint = sourcePoint
        focusTrackingActionType = inferFocusTrackingAction(near: sourcePoint)
        smoothedFocusSourcePoint = sourcePoint
        if let focusTrackingActionType {
            focusStatusMessage = "已锁定目标，将优先跟随\(focusTrackingActionType.displayName)动作点。"
        } else {
            focusStatusMessage = "已锁定目标（当前无可跟随动作点，使用静态中心）。"
        }
        if playbackZoomScale < 1.4 {
            withAnimation(.easeOut(duration: 0.16)) {
                playbackZoomScale = 1.8
            }
        }

        isSelectingFocusTarget = false
        if shouldResumeAfterFocusSelection {
            player.play()
        }
        shouldResumeAfterFocusSelection = false
    }

    private func inferFocusTrackingAction(near sourcePoint: CGPoint) -> ActionType? {
        guard !recognizedActions.isEmpty else { return nil }
        guard let frame = currentModelFrame else { return nil }
        let frameWindow = 12
        let maxSpatialDistance = max(videoCanvasSize.width, videoCanvasSize.height) * 0.22

        let candidates = recognizedActions.filter { abs($0.frameIndex - frame) <= frameWindow }
        guard !candidates.isEmpty else { return nil }

        let nearest = candidates.min { lhs, rhs in
            let lhsDist = hypot(CGFloat(lhs.x) - sourcePoint.x, CGFloat(lhs.y) - sourcePoint.y)
            let rhsDist = hypot(CGFloat(rhs.x) - sourcePoint.x, CGFloat(rhs.y) - sourcePoint.y)
            if abs(lhsDist - rhsDist) > 0.5 {
                return lhsDist < rhsDist
            }
            return abs(lhs.frameIndex - frame) < abs(rhs.frameIndex - frame)
        }
        guard let nearest else { return nil }
        let nearestDistance = hypot(CGFloat(nearest.x) - sourcePoint.x, CGFloat(nearest.y) - sourcePoint.y)
        guard nearestDistance <= maxSpatialDistance else { return nil }
        return nearest.type
    }

    private func nearestActionPoint(frame: Int, around sourcePoint: CGPoint, type: ActionType) -> CGPoint? {
        let frameWindow = 16
        let maxSpatialDistance = max(videoCanvasSize.width, videoCanvasSize.height) * 0.35

        let candidates = recognizedActions.filter {
            $0.type == type && abs($0.frameIndex - frame) <= frameWindow
        }
        guard !candidates.isEmpty else { return nil }

        let nearest = candidates.min { lhs, rhs in
            let lhsFrameGap = abs(lhs.frameIndex - frame)
            let rhsFrameGap = abs(rhs.frameIndex - frame)
            if lhsFrameGap != rhsFrameGap {
                return lhsFrameGap < rhsFrameGap
            }
            let lhsDist = hypot(CGFloat(lhs.x) - sourcePoint.x, CGFloat(lhs.y) - sourcePoint.y)
            let rhsDist = hypot(CGFloat(rhs.x) - sourcePoint.x, CGFloat(rhs.y) - sourcePoint.y)
            return lhsDist < rhsDist
        }
        guard let nearest else { return nil }
        let dist = hypot(CGFloat(nearest.x) - sourcePoint.x, CGFloat(nearest.y) - sourcePoint.y)
        guard dist <= maxSpatialDistance else { return nil }
        return CGPoint(x: CGFloat(nearest.x), y: CGFloat(nearest.y))
    }

    private func focusOffset(for containerSize: CGSize) -> CGSize {
        guard playbackZoomScale > 1.001,
              !isCalibratingCourt,
              !isSelectingFocusTarget else {
            return .zero
        }
        guard let focusPoint = smoothedFocusSourcePoint ?? activeFocusSourcePoint else { return .zero }

        let contentRect = aspectFitRect(container: containerSize, source: videoCanvasSize)
        guard contentRect.width > 0, contentRect.height > 0 else { return .zero }

        let mapped = mapSourcePointToDisplay(focusPoint, contentRect: contentRect)
        let center = CGPoint(x: containerSize.width * 0.5, y: containerSize.height * 0.5)
        let scale = CGFloat(playbackZoomScale)

        var dx = (center.x - mapped.x) * scale
        var dy = (center.y - mapped.y) * scale

        let maxOffsetX = max((containerSize.width * scale - containerSize.width) * 0.5, 0)
        let maxOffsetY = max((containerSize.height * scale - containerSize.height) * 0.5, 0)
        dx = min(max(dx, -maxOffsetX), maxOffsetX)
        dy = min(max(dy, -maxOffsetY), maxOffsetY)
        return CGSize(width: dx, height: dy)
    }

    private func mapDisplayPointToSource(
        _ displayPoint: CGPoint,
        containerSize: CGSize,
        appliedOffset: CGSize
    ) -> CGPoint? {
        let contentRect = aspectFitRect(container: containerSize, source: videoCanvasSize)
        guard contentRect.width > 0, contentRect.height > 0 else { return nil }

        let center = CGPoint(x: containerSize.width * 0.5, y: containerSize.height * 0.5)
        let scale = CGFloat(max(playbackZoomScale, 0.001))
        let untransformed = CGPoint(
            x: center.x + (displayPoint.x - appliedOffset.width - center.x) / scale,
            y: center.y + (displayPoint.y - appliedOffset.height - center.y) / scale
        )
        guard contentRect.contains(untransformed) else { return nil }

        let xScale = (untransformed.x - contentRect.minX) / max(contentRect.width, 1)
        let yScale = (untransformed.y - contentRect.minY) / max(contentRect.height, 1)
        let x = min(max(xScale, 0), 1) * max(videoCanvasSize.width - 1, 1)
        let y = min(max(yScale, 0), 1) * max(videoCanvasSize.height - 1, 1)
        return CGPoint(x: x, y: y)
    }

    private func mapSourcePointToDisplay(_ sourcePoint: CGPoint, contentRect: CGRect) -> CGPoint {
        let xScale = sourcePoint.x / max(videoCanvasSize.width - 1, 1)
        let yScale = sourcePoint.y / max(videoCanvasSize.height - 1, 1)
        return CGPoint(
            x: contentRect.minX + xScale * contentRect.width,
            y: contentRect.minY + yScale * contentRect.height
        )
    }

    private func aspectFitRect(container: CGSize, source: CGSize) -> CGRect {
        guard container.width > 0,
              container.height > 0,
              source.width > 0,
              source.height > 0 else {
            return .zero
        }

        let scale = min(container.width / source.width, container.height / source.height)
        let width = source.width * scale
        let height = source.height * scale
        let x = (container.width - width) / 2
        let y = (container.height - height) / 2
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func updateSmoothedFocusPoint() {
        guard let target = activeFocusSourcePoint else {
            smoothedFocusSourcePoint = nil
            return
        }
        smoothedFocusSourcePoint = PlaybackFrameMath.resolveSmoothedFocus(
            current: smoothedFocusSourcePoint,
            target: target,
            smoothing: focusSmoothingFactor
        )
    }

    private func attachPlaybackObserver() {
        detachPlaybackObserver()
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserverToken = player.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { time in
            currentPlaybackTime = max(CMTimeGetSeconds(time), 0)
            updateSmoothedFocusPoint()
        }
    }

    private func detachPlaybackObserver() {
        if let token = timeObserverToken {
            player.removeTimeObserver(token)
            timeObserverToken = nil
        }
        currentPlaybackTime = 0
    }

    private func resolveVideoMetadata(for url: URL) async -> (size: CGSize, duration: Double) {
        let fallback = CGSize(width: 16, height: 9)
        let asset = AVURLAsset(url: url)
        let duration = max((try? await asset.load(.duration)).map { CMTimeGetSeconds($0) } ?? 0, 0)

        guard let track = try? await asset.loadTracks(withMediaType: .video).first else {
            return (fallback, duration)
        }

        guard let naturalSize = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform) else {
            return (fallback, duration)
        }

        let transformed = naturalSize.applying(transform)
        let width = max(abs(transformed.width), 1)
        let height = max(abs(transformed.height), 1)
        return (CGSize(width: width, height: height), duration)
    }
}

private struct OverlayToggleChip: View {
    let color: Color
    let title: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Circle()
                    .fill(isOn ? color : Color.gray.opacity(0.55))
                    .frame(width: 8, height: 8)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(TennisTheme.courtDeepGreen.opacity(isOn ? 0.84 : 0.56))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background((isOn ? color.opacity(0.16) : TennisTheme.courtDeepGreen.opacity(0.05)))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct OverlayInfoChip: View {
    let color: Color
    let title: String

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(title)
                .font(.caption)
                .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.82))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(color.opacity(0.12))
        .clipShape(Capsule())
    }
}

private struct FocusSelectionMaskOverlay: View {
    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.black.opacity(0.30))

            VStack(spacing: 8) {
                Image(systemName: "viewfinder")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Color.white)
                Text("点一下球员完成目标锁定")
                    .font(.caption.bold())
                    .foregroundStyle(Color.white)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .allowsHitTesting(false)
    }
}

private struct FocusLockReticleOverlay: View {
    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.65), lineWidth: 1.3)
                .frame(width: 28, height: 28)
            Circle()
                .fill(Color.white.opacity(0.85))
                .frame(width: 4, height: 4)
        }
        .allowsHitTesting(false)
    }
}

private enum CourtProjectionMode {
    case approximate
    case calibrated(score: Double)

    var inlineSummary: String {
        switch self {
        case .approximate:
            return "未自动标定 · 估算映射"
        case .calibrated(let score):
            if score >= 0.82 {
                return "已标定 · 高精度"
            }
            if score >= 0.64 {
                return "已标定 · 中精度"
            }
            return "已标定 · 低精度"
        }
    }

    var badgeText: String {
        switch self {
        case .approximate:
            return "估算"
        case .calibrated(let score):
            if score >= 0.82 {
                return "高精度"
            }
            if score >= 0.64 {
                return "中精度"
            }
            return "低精度"
        }
    }

    var tint: Color {
        switch self {
        case .approximate:
            return TennisTheme.clayOrange
        case .calibrated(let score):
            if score >= 0.82 {
                return TennisTheme.courtGreen
            }
            if score >= 0.64 {
                return TennisTheme.ballYellow
            }
            return .red.opacity(0.82)
        }
    }

    var detailText: String {
        switch self {
        case .approximate:
            return "自动标定未完成，落点仅代表趋势。"
        case .calibrated(let score):
            return "透视标定质量 \(Int((score * 100).rounded()))%"
        }
    }
}

private extension CalibrationValidationTier {
    var displayName: String {
        switch self {
        case .high:
            return "高精度"
        case .medium:
            return "中精度"
        case .low:
            return "低精度"
        }
    }

    var tint: Color {
        switch self {
        case .high:
            return TennisTheme.courtGreen
        case .medium:
            return TennisTheme.ballYellow
        case .low:
            return .red.opacity(0.82)
        }
    }
}

extension CourtCalibrationValidationResult {
    var badgeText: String {
        switch tier {
        case .high:
            return "验证高准"
        case .medium:
            return "验证中准"
        case .low:
            return "验证低准"
        }
    }

    var tint: Color {
        tier.tint
    }

    var detailText: String {
        "验证均误差 \(averageErrorPixels.formatted(.number.precision(.fractionLength(1)))) px · 最大 \(maxErrorPixels.formatted(.number.precision(.fractionLength(1)))) px"
    }

    var inlineSummary: String {
        "\(badgeText)（均误差 \(averageErrorPixels.formatted(.number.precision(.fractionLength(1)))) px）"
    }
}

private struct AutoCourtCalibrationOverlay: View {
    let progress: Double
    let statusText: String

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.black.opacity(0.34))

            VStack(spacing: 10) {
                ProgressView(value: min(max(progress, 0), 1))
                    .tint(.white)
                    .frame(width: 180)
                Text("自动标定球场")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                Text(statusText)
                    .font(.caption2)
                    .foregroundStyle(Color.white.opacity(0.84))
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .allowsHitTesting(false)
    }
}

private struct CourtCalibrationValidationOverlay: View {
    let sourceSize: CGSize
    let selectedSamples: [CourtCalibrationValidationSample]
    let currentTarget: CourtCalibrationValidationTarget?
    let onSelectPoint: (CGPoint) -> Void

    var body: some View {
        GeometryReader { proxy in
            let contentRect = aspectFitRect(container: proxy.size, source: sourceSize)

            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Color.black.opacity(0.28))

                if contentRect.width > 0, contentRect.height > 0 {
                    Path { path in
                        path.addRect(contentRect)
                    }
                    .stroke(Color.white.opacity(0.48), lineWidth: 1.2)
                }

                ForEach(Array(selectedSamples.enumerated()), id: \.offset) { index, sample in
                    let mapped = mapToDisplay(sample.observedSourcePoint, contentRect: contentRect)
                    ZStack {
                        Circle()
                            .fill(TennisTheme.ballYellow.opacity(0.92))
                            .frame(width: 22, height: 22)
                        Text("\(index + 1)")
                            .font(.caption2.bold())
                            .foregroundStyle(TennisTheme.courtDeepGreen)
                    }
                    .position(mapped)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("精度验证：网带中心 -> 近端发球 T -> 远端发球 T")
                    if let currentTarget {
                        Text("当前：\(currentTarget.displayName)")
                    }
                }
                .font(.caption2.bold())
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .foregroundStyle(TennisTheme.courtDeepGreen)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(8)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onEnded { value in
                        guard contentRect.contains(value.location) else { return }
                        onSelectPoint(mapToSource(value.location, contentRect: contentRect))
                    }
            )
        }
        .allowsHitTesting(true)
    }

    private func mapToDisplay(_ sourcePoint: CGPoint, contentRect: CGRect) -> CGPoint {
        let xScale = CGFloat(sourcePoint.x) / max(sourceSize.width - 1, 1)
        let yScale = CGFloat(sourcePoint.y) / max(sourceSize.height - 1, 1)
        return CGPoint(
            x: contentRect.minX + xScale * contentRect.width,
            y: contentRect.minY + yScale * contentRect.height
        )
    }

    private func mapToSource(_ displayPoint: CGPoint, contentRect: CGRect) -> CGPoint {
        let xScale = (displayPoint.x - contentRect.minX) / max(contentRect.width, 1)
        let yScale = (displayPoint.y - contentRect.minY) / max(contentRect.height, 1)
        let x = min(max(xScale, 0), 1) * max(sourceSize.width - 1, 1)
        let y = min(max(yScale, 0), 1) * max(sourceSize.height - 1, 1)
        return CGPoint(x: x, y: y)
    }

    private func aspectFitRect(container: CGSize, source: CGSize) -> CGRect {
        guard container.width > 0,
              container.height > 0,
              source.width > 0,
              source.height > 0 else {
            return .zero
        }

        let scale = min(container.width / source.width, container.height / source.height)
        let width = source.width * scale
        let height = source.height * scale
        let x = (container.width - width) / 2
        let y = (container.height - height) / 2
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

private struct PlaybackPresetChip: View {
    let title: String
    let isSelected: Bool
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption.bold())
                .foregroundStyle(TennisTheme.courtDeepGreen.opacity(isSelected ? 0.96 : 0.70))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(isSelected ? accent.opacity(0.28) : Color.white.opacity(0.62))
                .clipShape(Capsule())
                .overlay {
                    Capsule()
                        .stroke(isSelected ? accent.opacity(0.55) : TennisTheme.lineWhite.opacity(0.42), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
    }
}

private struct MiniCourtBounceMap: View {
    let mappedBouncePoints: [CourtMappedBounce]
    let totalBounceCount: Int
    let inBoundsCount: Int
    let projectionMode: CourtProjectionMode
    let validationResult: CourtCalibrationValidationResult?
    let sourceFrameSize: CGSize
    let showsUncertaintyRings: Bool

    private let courtAspectRatio: CGFloat = 0.62

    private var latestBounce: CourtMappedBounce? {
        mappedBouncePoints.last
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(TennisTheme.clayOrange)
                    .frame(width: 7, height: 7)
                Text("落点 \(inBoundsCount)/\(totalBounceCount)")
                    .font(.caption.bold())
                    .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.88))
                Text(projectionMode.badgeText)
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(projectionMode.tint.opacity(0.18))
                    .foregroundStyle(projectionMode.tint)
                    .clipShape(Capsule())

                if let validationResult {
                    Text(validationResult.badgeText)
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(validationResult.tint.opacity(0.18))
                        .foregroundStyle(validationResult.tint)
                        .clipShape(Capsule())
                }
            }

            GeometryReader { proxy in
                let courtRect = aspectFitRect(container: proxy.size, aspectRatio: courtAspectRatio)

                Canvas { context, _ in
                    guard courtRect.width > 0, courtRect.height > 0 else { return }
                    drawCourt(in: &context, rect: courtRect)
                    drawBounces(in: &context, rect: courtRect)
                }
            }
            .frame(width: 118, height: 140)

            if let validationResult {
                Text(validationResult.detailText)
                    .font(.caption2)
                    .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.76))
            } else {
                Text(projectionMode.detailText)
                    .font(.caption2)
                    .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.76))
            }

            if let latestBounce {
                Text("最新 (\(latestBounce.sourcePoint.x), \(latestBounce.sourcePoint.y))")
                    .font(.caption2)
                    .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.72))
            }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.white.opacity(0.25), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 6)
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.22), value: mappedBouncePoints.count)
    }

    private func drawCourt(in context: inout GraphicsContext, rect: CGRect) {
        let borderPath = Path(roundedRect: rect, cornerRadius: 8, style: .continuous)
        context.fill(borderPath, with: .color(TennisTheme.courtGreen.opacity(0.88)))
        context.stroke(borderPath, with: .color(.white.opacity(0.9)), style: StrokeStyle(lineWidth: 1.6))

        let singlesInset = rect.width * 0.11
        let singlesRect = rect.insetBy(dx: singlesInset, dy: 0)
        let topServiceY = rect.minY + rect.height * 0.28
        let bottomServiceY = rect.maxY - rect.height * 0.28
        let netY = rect.midY
        let centerX = rect.midX

        var linePath = Path()
        linePath.move(to: CGPoint(x: singlesRect.minX, y: rect.minY))
        linePath.addLine(to: CGPoint(x: singlesRect.minX, y: rect.maxY))
        linePath.move(to: CGPoint(x: singlesRect.maxX, y: rect.minY))
        linePath.addLine(to: CGPoint(x: singlesRect.maxX, y: rect.maxY))

        linePath.move(to: CGPoint(x: rect.minX, y: topServiceY))
        linePath.addLine(to: CGPoint(x: rect.maxX, y: topServiceY))
        linePath.move(to: CGPoint(x: rect.minX, y: bottomServiceY))
        linePath.addLine(to: CGPoint(x: rect.maxX, y: bottomServiceY))

        linePath.move(to: CGPoint(x: rect.minX, y: netY))
        linePath.addLine(to: CGPoint(x: rect.maxX, y: netY))

        linePath.move(to: CGPoint(x: centerX, y: topServiceY))
        linePath.addLine(to: CGPoint(x: centerX, y: bottomServiceY))

        context.stroke(linePath, with: .color(.white.opacity(0.86)), style: StrokeStyle(lineWidth: 1.05))
    }

    private func drawBounces(in context: inout GraphicsContext, rect: CGRect) {
        let bounceArea = rect.insetBy(dx: rect.width * 0.03, dy: rect.height * 0.02)
        let uncertaintyRadius = resolveUncertaintyRadius(mapRect: bounceArea)
        let uncertaintyColor = validationResult?.tint.opacity(0.34) ?? TennisTheme.ballYellow.opacity(0.28)

        for point in mappedBouncePoints {
            let center = mapToCourt(point.normalizedPoint, in: bounceArea)

            if let uncertaintyRadius {
                let uncertaintyRect = CGRect(
                    x: center.x - uncertaintyRadius,
                    y: center.y - uncertaintyRadius,
                    width: uncertaintyRadius * 2,
                    height: uncertaintyRadius * 2
                )
                context.stroke(
                    Path(ellipseIn: uncertaintyRect),
                    with: .color(uncertaintyColor),
                    style: StrokeStyle(lineWidth: 1.2)
                )
            }

            if point.isInBounds {
                let dot = CGRect(x: center.x - 2.6, y: center.y - 2.6, width: 5.2, height: 5.2)
                let ring = CGRect(x: center.x - 5.8, y: center.y - 5.8, width: 11.6, height: 11.6)
                context.fill(Path(ellipseIn: dot), with: .color(TennisTheme.clayOrange))
                context.stroke(
                    Path(ellipseIn: ring),
                    with: .color(TennisTheme.clayOrange.opacity(0.72)),
                    style: StrokeStyle(lineWidth: 1.4)
                )
            } else {
                var cross = Path()
                cross.move(to: CGPoint(x: center.x - 4, y: center.y - 4))
                cross.addLine(to: CGPoint(x: center.x + 4, y: center.y + 4))
                cross.move(to: CGPoint(x: center.x + 4, y: center.y - 4))
                cross.addLine(to: CGPoint(x: center.x - 4, y: center.y + 4))
                context.stroke(cross, with: .color(.red.opacity(0.9)), style: StrokeStyle(lineWidth: 1.8))
            }
        }

        if let latestBounce {
            let center = mapToCourt(latestBounce.normalizedPoint, in: bounceArea)
            let pulse = CGRect(x: center.x - 10, y: center.y - 10, width: 20, height: 20)
            context.stroke(
                Path(ellipseIn: pulse),
                with: .color(TennisTheme.ballYellow.opacity(0.96)),
                style: StrokeStyle(lineWidth: 2.3)
            )
        }
    }

    private func resolveUncertaintyRadius(mapRect: CGRect) -> CGFloat? {
        guard showsUncertaintyRings else { return nil }
        guard let validationResult else { return nil }
        return CourtCalibrationValidator.uncertaintyRadiusOnMap(
            averageErrorPixels: validationResult.averageErrorPixels,
            frameSize: sourceFrameSize,
            mapReferenceLength: min(mapRect.width, mapRect.height)
        )
    }

    private func mapToCourt(_ normalized: CGPoint, in rect: CGRect) -> CGPoint {
        let xScale = min(max(normalized.x, 0), 1)
        let yScale = min(max(normalized.y, 0), 1)
        return CGPoint(
            x: rect.minX + xScale * rect.width,
            y: rect.minY + yScale * rect.height
        )
    }

    private func aspectFitRect(container: CGSize, aspectRatio: CGFloat) -> CGRect {
        guard container.width > 0, container.height > 0, aspectRatio > 0 else {
            return .zero
        }

        let containerRatio = container.width / container.height
        let width: CGFloat
        let height: CGFloat

        if containerRatio > aspectRatio {
            height = container.height
            width = height * aspectRatio
        } else {
            width = container.width
            height = width / aspectRatio
        }

        let x = (container.width - width) / 2
        let y = (container.height - height) / 2
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

private struct BallTrajectoryOverlay: View {
    let trajectoryPoints: [InferencePoint]
    let bouncePoints: [InferencePoint]
    let sourceSize: CGSize
    let highlightedPoint: InferencePoint?
    let highlightedBounce: InferencePoint?

    var body: some View {
        GeometryReader { proxy in
            let contentRect = aspectFitRect(container: proxy.size, source: sourceSize)

            Canvas { context, _ in
                guard contentRect.width > 0, contentRect.height > 0 else { return }

                if trajectoryPoints.count >= 2 {
                    var path = Path()
                    var didMove = false

                    for point in trajectoryPoints {
                        let mapped = map(point: point, sourceSize: sourceSize, into: contentRect)
                        if !didMove {
                            path.move(to: mapped)
                            didMove = true
                        } else {
                            path.addLine(to: mapped)
                        }
                    }

                    context.stroke(
                        path,
                        with: .color(.white.opacity(0.35)),
                        style: StrokeStyle(lineWidth: 4.0, lineCap: .round, lineJoin: .round)
                    )
                    context.stroke(
                        path,
                        with: .color(TennisTheme.ballYellow.opacity(0.95)),
                        style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round)
                    )
                }

                for bounce in bouncePoints {
                    let center = map(point: bounce, sourceSize: sourceSize, into: contentRect)
                    let ring = CGRect(
                        x: center.x - 7,
                        y: center.y - 7,
                        width: 14,
                        height: 14
                    )
                    let dot = CGRect(
                        x: center.x - 2.5,
                        y: center.y - 2.5,
                        width: 5,
                        height: 5
                    )
                    context.stroke(
                        Path(ellipseIn: ring),
                        with: .color(TennisTheme.clayOrange),
                        style: StrokeStyle(lineWidth: 2)
                    )
                    context.fill(
                        Path(ellipseIn: dot),
                        with: .color(TennisTheme.clayOrange)
                    )
                }

                if let highlightedPoint {
                    let center = map(point: highlightedPoint, sourceSize: sourceSize, into: contentRect)
                    let glow = CGRect(x: center.x - 12, y: center.y - 12, width: 24, height: 24)
                    let core = CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8)

                    context.fill(Path(ellipseIn: glow), with: .color(.white.opacity(0.28)))
                    context.fill(Path(ellipseIn: core), with: .color(.white))
                }

                if let highlightedBounce {
                    let center = map(point: highlightedBounce, sourceSize: sourceSize, into: contentRect)
                    let pulse = CGRect(x: center.x - 10, y: center.y - 10, width: 20, height: 20)
                    context.stroke(
                        Path(ellipseIn: pulse),
                        with: .color(.white.opacity(0.88)),
                        style: StrokeStyle(lineWidth: 2.4)
                    )
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func map(point: InferencePoint, sourceSize: CGSize, into rect: CGRect) -> CGPoint {
        let xScale = CGFloat(point.x) / max(sourceSize.width - 1, 1)
        let yScale = CGFloat(point.y) / max(sourceSize.height - 1, 1)
        return CGPoint(
            x: rect.minX + xScale * rect.width,
            y: rect.minY + yScale * rect.height
        )
    }

    private func aspectFitRect(container: CGSize, source: CGSize) -> CGRect {
        guard container.width > 0,
              container.height > 0,
              source.width > 0,
              source.height > 0 else {
            return .zero
        }

        let scale = min(container.width / source.width, container.height / source.height)
        let width = source.width * scale
        let height = source.height * scale
        let x = (container.width - width) / 2
        let y = (container.height - height) / 2
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

struct AnalysisDetailView: View {
    let session: AnalysisSession
    let onUpdateSessionCalibration: ((UUID, SessionCourtCalibration?) -> Void)?
    let onUpdateSessionValidation: ((UUID, SessionCalibrationValidation?) -> Void)?

    init(
        session: AnalysisSession,
        onUpdateSessionCalibration: ((UUID, SessionCourtCalibration?) -> Void)? = nil,
        onUpdateSessionValidation: ((UUID, SessionCalibrationValidation?) -> Void)? = nil
    ) {
        self.session = session
        self.onUpdateSessionCalibration = onUpdateSessionCalibration
        self.onUpdateSessionValidation = onUpdateSessionValidation
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text(session.videoTitle)
                            .font(.custom("AvenirNextCondensed-Bold", size: 24))
                            .foregroundStyle(TennisTheme.courtDeepGreen)
                        Spacer()
                        StatusBadge(status: session.processingStatus)
                    }

                    Text("素材 ID: \(session.sourceID)")
                        .font(.subheadline)
                        .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.70))
                    Text("日期: \(session.eventDate.formatted(date: .abbreviated, time: .omitted))")
                        .font(.subheadline)
                        .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.70))

                    Label(
                        sessionSummaryDescription,
                        systemImage: session.isBuiltInSample ? "shippingbox.fill" : "text.badge.checkmark"
                    )
                    .font(.caption)
                    .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.72))

                    if let videoURL = session.localVideoURL {
                        NavigationLink {
                            SessionVideoPlaybackView(
                                session: session,
                                videoURL: videoURL,
                                onCalibrationUpdated: { calibration in
                                    onUpdateSessionCalibration?(session.id, calibration)
                                },
                                onCalibrationValidationUpdated: { validation in
                                    onUpdateSessionValidation?(session.id, validation)
                                }
                            )
                        } label: {
                            HStack {
                                Label("一键回放当次视频", systemImage: "play.rectangle.fill")
                                    .font(.subheadline.bold())
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.bold())
                            }
                            .foregroundStyle(TennisTheme.courtDeepGreen)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(TennisTheme.ballYellow.opacity(0.72))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                    } else {
                        Label("该记录没有可回放的本地视频", systemImage: "video.slash")
                            .font(.caption)
                            .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.58))
                    }

                    scoreRow(
                        title: "球可见率",
                        value: session.ballVisibleRate,
                        color: TennisTheme.courtGreen
                    )
                    scoreRow(
                        title: "跟踪质量得分",
                        value: session.trackingQualityScore,
                        color: TennisTheme.clayOrange
                    )

                    SessionQualityBreakdownCard(session: session)

                    StructuredSessionOverviewCard(session: session)

                    if let scoreTimeline = session.scoreTimeline, !scoreTimeline.isEmpty {
                        StructuredScoreTimelineCard(entries: scoreTimeline)
                    }

                    if let rallies = session.structuredRallies, !rallies.isEmpty {
                        StructuredRallyCard(rallies: rallies)
                    }

                    if let shots = session.structuredShots, !shots.isEmpty {
                        StructuredShotCard(shots: shots)
                    }

                    if let bounces = session.structuredBounces, !bounces.isEmpty {
                        StructuredBounceCard(bounces: bounces)
                    }

                    if let validation = session.calibrationValidation {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("落点映射验证")
                                Spacer()
                                Text(validation.tier.displayName)
                                    .font(.caption.bold())
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(validation.tier.tint.opacity(0.16))
                                    .foregroundStyle(validation.tier.tint)
                                    .clipShape(Capsule())
                            }
                            .foregroundStyle(TennisTheme.courtDeepGreen)

                            HStack {
                                Text("平均误差")
                                Spacer()
                                Text("\(validation.averageErrorPixels.formatted(.number.precision(.fractionLength(1)))) px")
                                    .fontWeight(.semibold)
                            }
                            .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.86))

                            HStack {
                                Text("最大误差")
                                Spacer()
                                Text("\(validation.maxErrorPixels.formatted(.number.precision(.fractionLength(1)))) px")
                                    .fontWeight(.semibold)
                            }
                            .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.86))
                        }
                    }

                    HStack {
                        Text("跟踪帧数")
                        Spacer()
                        Text("\(session.trackedFrames) / \(session.totalFrames)")
                            .fontWeight(.semibold)
                    }
                    .foregroundStyle(TennisTheme.courtDeepGreen)

                    HStack {
                        Text("估计弹跳次数")
                        Spacer()
                        Text("\(session.estimatedBounceCount)")
                            .fontWeight(.semibold)
                    }
                    .foregroundStyle(TennisTheme.courtDeepGreen)

                    if let trajectoryPoints = session.trajectoryPoints, !trajectoryPoints.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("模型输出映射")
                                .font(.headline)
                                .foregroundStyle(TennisTheme.courtDeepGreen)

                            if let firstVisible = trajectoryPoints.first(where: { $0.isVisible }) {
                                HStack {
                                    Text("首个球坐标")
                                    Spacer()
                                    Text("(\(firstVisible.x), \(firstVisible.y))")
                                        .fontWeight(.semibold)
                                }
                                .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.85))
                            }

                            HStack {
                                Text("轨迹点数量")
                                Spacer()
                                Text("\(trajectoryPoints.count)")
                                    .fontWeight(.semibold)
                            }
                            .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.85))

                            if let bouncePoints = session.bouncePoints, !bouncePoints.isEmpty {
                                if let firstBounce = bouncePoints.first {
                                    HStack {
                                        Text("首个弹跳点")
                                        Spacer()
                                        Text("(\(firstBounce.x), \(firstBounce.y))")
                                            .fontWeight(.semibold)
                                    }
                                    .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.85))
                                }

                                HStack {
                                    Text("弹跳点数量")
                                    Spacer()
                                    Text("\(bouncePoints.count)")
                                        .fontWeight(.semibold)
                                }
                                .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.85))
                            }
                        }
                    }

                    if let actions = session.detectedActions, !actions.isEmpty {
                        let forehandCount = actions.filter { $0.type == .forehand }.count
                        let backhandCount = actions.filter { $0.type == .backhand }.count
                        let serveCount = actions.filter { $0.type == .serve }.count

                        VStack(alignment: .leading, spacing: 6) {
                            Text("动作识别")
                                .font(.headline)
                                .foregroundStyle(TennisTheme.courtDeepGreen)

                            HStack {
                                Text("正手 / 反手 / 发球")
                                Spacer()
                                Text("\(forehandCount) / \(backhandCount) / \(serveCount)")
                                    .fontWeight(.semibold)
                            }
                            .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.85))

                            if let firstAction = actions.first {
                                HStack {
                                    Text("首个动作")
                                    Spacer()
                                    Text("\(firstAction.type.displayName) (\(firstAction.confidence.formatted(.number.precision(.fractionLength(2)))))")
                                        .fontWeight(.semibold)
                                }
                                .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.85))
                            }

                            HStack {
                                Text("动作候选数量")
                                Spacer()
                                Text("\(actions.count)")
                                    .fontWeight(.semibold)
                            }
                            .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.85))
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("备注")
                            .font(.headline)
                        Text(session.note)
                            .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.75))
                    }
                }
                .padding()
                .tennisCard()
            }
            .padding()
        }
        .background(CourtSurfaceBackground())
        .navigationTitle("分析详情")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var sessionSummaryDescription: String {
        if session.isBuiltInSample {
            return "当前记录为内置样例，仅用于展示摘要界面，不支持回放或远端结构化分析。"
        }
        if session.hasStructuredAnalysis {
            return "当前记录已回填远端结构化分析，下面会展示比分时间线、回合、击球和弹跳列表。"
        }
        if session.sessionOrigin == .remoteStructured {
            return "当前记录来自远端结构化会话摘要；完整回合详情会在下次拉取 detail 后补齐。"
        }
        return "当前记录展示 iOS 本地分析摘要；远端结构化结果完成后会自动覆盖为 rally、比分和结构化明细。"
    }

    @ViewBuilder
    private func scoreRow(title: String, value: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                Spacer()
                Text(value.formatted(.percent.precision(.fractionLength(1))))
                    .fontWeight(.semibold)
            }
            ProgressView(value: value)
                .tint(color)
        }
    }
}

private struct StructuredSessionOverviewCard: View {
    let session: AnalysisSession

    private var summaryItems: [(String, String)] {
        var items: [(String, String)] = []
        if let quality = session.courtDetectionQualityScore {
            items.append(("球场检测质量", quality.formatted(.percent.precision(.fractionLength(1)))))
        }
        if let rallies = session.structuredRallies?.count, rallies > 0 {
            items.append(("回合数", "\(rallies)"))
        }
        if let shots = session.structuredShots?.count, shots > 0 {
            items.append(("击球数", "\(shots)"))
        }
        if let bounces = session.structuredBounces?.count, bounces > 0 {
            items.append(("弹跳数", "\(bounces)"))
        }
        return items
    }

    var body: some View {
        if !summaryItems.isEmpty || !(session.remoteModelVersions ?? [:]).isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("远端结构化概览")
                    .font(.headline)
                    .foregroundStyle(TennisTheme.courtDeepGreen)

                ForEach(summaryItems, id: \.0) { item in
                    HStack {
                        Text(item.0)
                        Spacer()
                        Text(item.1)
                            .fontWeight(.semibold)
                    }
                    .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.84))
                }

                if let versions = session.remoteModelVersions, !versions.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("模型版本")
                            .font(.subheadline.bold())
                            .foregroundStyle(TennisTheme.courtDeepGreen)

                        ForEach(versions.keys.sorted(), id: \.self) { key in
                            HStack {
                                Text(key)
                                Spacer()
                                Text(versions[key] ?? "-")
                                    .font(.caption.bold())
                            }
                            .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.78))
                        }
                    }
                    .padding(.top, 4)
                }
            }
        }
    }
}

private struct StructuredScoreTimelineCard: View {
    let entries: [ScoreTimelineEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("比分时间线")
                .font(.headline)
                .foregroundStyle(TennisTheme.courtDeepGreen)

            ForEach(Array(entries.prefix(8))) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("回合 \(entry.rallyID)")
                        Spacer()
                        Text(entry.afterScore ?? entry.beforeScore ?? "待定")
                            .font(.caption.bold())
                    }
                    .foregroundStyle(TennisTheme.courtDeepGreen)

                    Text(
                        [
                            entry.beforeScore.map { "前比分 \($0)" },
                            entry.winnerSide.map { "胜者 \(displaySide($0))" },
                            entry.pointStatus.map { "状态 \($0)" }
                        ]
                            .compactMap { $0 }
                            .joined(separator: " · ")
                    )
                    .font(.caption)
                    .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.70))
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func displaySide(_ side: String) -> String {
        switch side {
        case "near":
            return "近侧"
        case "far":
            return "远侧"
        default:
            return side
        }
    }
}

private struct StructuredRallyCard: View {
    let rallies: [StructuredRally]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("回合列表")
                .font(.headline)
                .foregroundStyle(TennisTheme.courtDeepGreen)

            ForEach(Array(rallies.prefix(8))) { rally in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("回合 \(rally.rallyID)")
                        Spacer()
                        Text("\(rally.numShots ?? 0) 拍")
                            .font(.caption.bold())
                    }
                    .foregroundStyle(TennisTheme.courtDeepGreen)

                    Text(
                        "时间 \(formatSeconds(rally.startSec)) - \(formatSeconds(rally.endSec)) · 状态 \(rally.pointStatus ?? "pending")"
                    )
                    .font(.caption)
                    .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.70))
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func formatSeconds(_ seconds: Double) -> String {
        "\(seconds.formatted(.number.precision(.fractionLength(1))))s"
    }
}

private struct StructuredShotCard: View {
    let shots: [StructuredShot]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("击球列表")
                .font(.headline)
                .foregroundStyle(TennisTheme.courtDeepGreen)

            ForEach(Array(shots.prefix(10))) { shot in
                HStack {
                    Text("帧 \(shot.frameNum)")
                    Spacer()
                    Text(
                        [
                            shot.shotType ?? "unknown",
                            shot.confidence.map { $0.formatted(.number.precision(.fractionLength(2))) }
                        ]
                            .compactMap { $0 }
                            .joined(separator: " · ")
                    )
                    .font(.caption.bold())
                }
                .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.82))
            }
        }
    }
}

private struct StructuredBounceCard: View {
    let bounces: [StructuredBounce]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("弹跳列表")
                .font(.headline)
                .foregroundStyle(TennisTheme.courtDeepGreen)

            ForEach(Array(bounces.prefix(10))) { bounce in
                HStack {
                    Text("帧 \(bounce.frameNum)")
                    Spacer()
                    Text(
                        [
                            bounce.detectionMethod ?? "remote",
                            bounce.inCourt.map { $0 ? "界内" : "界外" }
                        ]
                            .compactMap { $0 }
                            .joined(separator: " · ")
                    )
                    .font(.caption.bold())
                }
                .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.82))
            }
        }
    }
}

private struct TrainingTrendSection: View {
    let snapshots: [TrainingTrendSnapshot]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("进步趋势")
                    .font(.headline)
                    .foregroundStyle(TennisTheme.courtDeepGreen)
                Spacer()
                Text("最近 7/30 天")
                    .font(.caption.bold())
                    .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.66))
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(snapshots) { snapshot in
                        TrainingTrendCard(snapshot: snapshot)
                            .frame(width: 286)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }
}

private struct TrainingTrendCard: View {
    let snapshot: TrainingTrendSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(snapshot.title)
                    .font(.headline)
                    .foregroundStyle(TennisTheme.courtDeepGreen)
                Text("\(snapshot.subtitle) · \(snapshot.sessionCount) 场")
                    .font(.caption)
                    .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.66))
            }

            HStack(spacing: 10) {
                TrendMetricPill(
                    title: "可见率",
                    value: snapshot.averageVisibleRate.formatted(.percent.precision(.fractionLength(0))),
                    tint: TennisTheme.courtGreen
                )
                TrendMetricPill(
                    title: "质量",
                    value: snapshot.averageTrackingQualityScore.formatted(.percent.precision(.fractionLength(0))),
                    tint: TennisTheme.clayOrange
                )
                TrendMetricPill(
                    title: "弹跳",
                    value: snapshot.averageBounceCount.formatted(.number.precision(.fractionLength(1))),
                    tint: TennisTheme.ballYellow
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                QualityBreakdownRow(
                    title: "连续性",
                    value: snapshot.averageQualityBreakdown.clampedContinuityScore,
                    tint: TennisTheme.courtGreen
                )
                QualityBreakdownRow(
                    title: "推理成功率",
                    value: snapshot.averageQualityBreakdown.clampedInferenceSuccessRate,
                    tint: TennisTheme.clayOrange
                )
                QualityBreakdownRow(
                    title: "动作稳定性",
                    value: snapshot.averageQualityBreakdown.clampedActionStabilityScore,
                    tint: TennisTheme.ballYellow
                )
            }

            Text("动作分布：正手 \(snapshot.actionCounts.forehand) / 反手 \(snapshot.actionCounts.backhand) / 发球 \(snapshot.actionCounts.serve)")
                .font(.caption)
                .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.72))
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .tennisCard()
    }
}

private struct TrendMetricPill: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.58))
            Text(value)
                .font(.caption.bold())
                .foregroundStyle(TennisTheme.courtDeepGreen)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(tint.opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

private struct TrainingFeedbackLoopCard: View {
    let plan: TrainingFeedbackPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("训练闭环")
                .font(.headline)
                .foregroundStyle(TennisTheme.courtDeepGreen)

            VStack(alignment: .leading, spacing: 8) {
                Text("当前问题")
                    .font(.subheadline.bold())
                    .foregroundStyle(TennisTheme.courtDeepGreen)
                ForEach(Array(plan.issues.enumerated()), id: \.offset) { index, issue in
                    Text("\(index + 1). \(issue)")
                        .font(.caption)
                        .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.78))
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("建议动作")
                    .font(.subheadline.bold())
                    .foregroundStyle(TennisTheme.courtDeepGreen)
                ForEach(Array(plan.recommendations.enumerated()), id: \.offset) { index, recommendation in
                    Text("\(index + 1). \(recommendation)")
                        .font(.caption)
                        .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.78))
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("下次拍摄目标")
                    .font(.subheadline.bold())
                    .foregroundStyle(TennisTheme.courtDeepGreen)
                Text(plan.nextCaptureGoal)
                    .font(.caption)
                    .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.80))
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(TennisTheme.ballYellow.opacity(0.18))
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .tennisCard()
    }
}

private struct TrainingPhaseComparisonCard: View {
    let report: TrainingPhaseComparisonReport

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("阶段对比")
                    .font(.headline)
                    .foregroundStyle(TennisTheme.courtDeepGreen)
                Spacer()
                Text("\(report.baseline.sessionCount) -> \(report.recent.sessionCount) 场")
                    .font(.caption.bold())
                    .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.66))
            }

            Text(report.headline)
                .font(.subheadline)
                .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.82))

            HStack(spacing: 10) {
                PhaseComparisonStatColumn(
                    title: report.baseline.title,
                    visibleRate: report.baseline.averageVisibleRate,
                    trackingQuality: report.baseline.averageTrackingQualityScore
                )
                PhaseComparisonStatColumn(
                    title: report.recent.title,
                    visibleRate: report.recent.averageVisibleRate,
                    trackingQuality: report.recent.averageTrackingQualityScore
                )
            }

            if let firstWin = report.wins.first {
                Label(firstWin, systemImage: "arrow.up.right")
                    .font(.caption)
                    .foregroundStyle(TennisTheme.courtGreen)
            }

            if let firstCaution = report.cautions.first {
                Label(firstCaution, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(TennisTheme.clayOrange)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .tennisCard()
    }
}

private struct PhaseComparisonStatColumn: View {
    let title: String
    let visibleRate: Double
    let trackingQuality: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.bold())
                .foregroundStyle(TennisTheme.courtDeepGreen)
            Text("可见率 \(visibleRate.formatted(.percent.precision(.fractionLength(0))))")
                .font(.caption)
                .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.74))
            Text("质量 \(trackingQuality.formatted(.percent.precision(.fractionLength(0))))")
                .font(.caption)
                .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.74))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(TennisTheme.lineWhite.opacity(0.42))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

private struct TrainingPhaseComparisonReportSheet: View {
    let report: TrainingPhaseComparisonReport
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    TrainingPhaseComparisonCard(report: report)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("提升点")
                            .font(.headline)
                            .foregroundStyle(TennisTheme.courtDeepGreen)
                        if report.wins.isEmpty {
                            Text("当前没有明确的提升项，建议继续累计同机位样本。")
                                .font(.caption)
                                .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.72))
                        } else {
                            ForEach(Array(report.wins.enumerated()), id: \.offset) { index, win in
                                Label("\(index + 1). \(win)", systemImage: "checkmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(TennisTheme.courtGreen)
                            }
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .tennisCard()

                    VStack(alignment: .leading, spacing: 8) {
                        Text("风险点")
                            .font(.headline)
                            .foregroundStyle(TennisTheme.courtDeepGreen)
                        if report.cautions.isEmpty {
                            Text("当前没有明显回落项，可以继续沿用现有训练方式。")
                                .font(.caption)
                                .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.72))
                        } else {
                            ForEach(Array(report.cautions.enumerated()), id: \.offset) { index, caution in
                                Label("\(index + 1). \(caution)", systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundStyle(TennisTheme.clayOrange)
                            }
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .tennisCard()
                }
                .padding()
            }
            .background(CourtSurfaceBackground())
            .navigationTitle("阶段对比报告")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct SessionQualityBreakdownCard: View {
    let session: AnalysisSession

    var body: some View {
        let breakdown = session.resolvedQualityBreakdown
        let showsFallback = session.qualityBreakdown == nil

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("质量解释")
                    .font(.headline)
                    .foregroundStyle(TennisTheme.courtDeepGreen)
                Spacer()
                Text(showsFallback ? "由摘要回推" : "本地模型输出")
                    .font(.caption.bold())
                    .foregroundStyle(showsFallback ? TennisTheme.clayOrange : TennisTheme.courtGreen)
            }

            QualityBreakdownRow(
                title: "球可见率",
                value: breakdown.clampedVisibleRateScore,
                tint: TennisTheme.courtGreen
            )
            QualityBreakdownRow(
                title: "连续性",
                value: breakdown.clampedContinuityScore,
                tint: TennisTheme.clayOrange
            )
            QualityBreakdownRow(
                title: "推理成功率",
                value: breakdown.clampedInferenceSuccessRate,
                tint: TennisTheme.ballYellow
            )
            QualityBreakdownRow(
                title: "动作稳定性",
                value: breakdown.clampedActionStabilityScore,
                tint: TennisTheme.courtDeepGreen
            )

            Text(
                showsFallback
                ? "当前会话没有保存细分分数，页面使用摘要字段回推可解释子项。"
                : "当前会话已保存 4 个质量子项，可用于趋势分析和后续模型回归。"
            )
            .font(.caption)
            .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.72))
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .tennisCard()
    }
}

private struct QualityBreakdownRow: View {
    let title: String
    let value: Double
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption.bold())
                    .foregroundStyle(TennisTheme.courtDeepGreen)
                Spacer()
                Text(value.formatted(.percent.precision(.fractionLength(0))))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.74))
            }
            ProgressView(value: value)
                .tint(tint)
        }
    }
}

private struct PlaybackHighlightChip: View {
    let highlight: SessionPlaybackHighlight
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: highlight.systemImage)
                    .font(.caption.bold())
                VStack(alignment: .leading, spacing: 2) {
                    Text(highlight.title)
                        .font(.caption.bold())
                    Text(highlight.subtitle)
                        .font(.caption2)
                        .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.66))
                }
            }
            .foregroundStyle(TennisTheme.courtDeepGreen)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(TennisTheme.lineWhite.opacity(0.42))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}

struct MetricCard: View {
    let title: String
    let value: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.65))
            Text(value)
                .font(.custom("AvenirNextCondensed-Bold", size: 27))
                .foregroundStyle(TennisTheme.courtDeepGreen)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.70))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .tennisCard()
    }
}

struct SessionHighlightCard: View {
    let session: AnalysisSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("最近一次分析")
                        .font(.headline)
                        .foregroundStyle(TennisTheme.courtDeepGreen)
                    Text(session.videoTitle)
                        .font(.subheadline)
                        .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.70))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    SurfaceThemeBadge(surface: TennisTheme.currentSurface)
                    StatusBadge(status: session.processingStatus)
                }
            }

            ProgressView(value: session.ballVisibleRate) {
                Text("球可见率")
            } currentValueLabel: {
                Text(session.ballVisibleRate.formatted(.percent.precision(.fractionLength(1))))
                    .fontWeight(.semibold)
            }
            .tint(TennisTheme.courtGreen)

            ProgressView(value: session.trackingQualityScore) {
                Text("跟踪质量得分")
            } currentValueLabel: {
                Text(session.trackingQualityScore.formatted(.percent.precision(.fractionLength(1))))
                    .fontWeight(.semibold)
            }
            .tint(TennisTheme.clayOrange)

            Label(session.presentationOriginLabel, systemImage: session.isBuiltInSample ? "shippingbox" : "waveform.path.ecg")
                .font(.caption2.bold())
                .foregroundStyle(session.isBuiltInSample ? TennisTheme.clayOrange : TennisTheme.courtGreen)

            Text("跟踪帧数 \(session.trackedFrames) / \(session.totalFrames)")
                .font(.footnote)
                .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.68))
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .tennisCard()
    }
}

struct SessionRow: View {
    let session: AnalysisSession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(session.videoTitle)
                    .font(.headline)
                    .foregroundStyle(TennisTheme.courtDeepGreen)
                Spacer()
                StatusBadge(status: session.processingStatus)
            }

            Text(session.eventDate.formatted(date: .abbreviated, time: .omitted))
                .font(.subheadline)
                .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.66))

            HStack(spacing: 14) {
                Label(session.ballVisibleRate.formatted(.percent.precision(.fractionLength(1))), systemImage: "dot.scope")
                Label("\(session.trackedFrames)/\(session.totalFrames)", systemImage: "film.stack")
                Label(session.presentationOriginLabel, systemImage: session.isBuiltInSample ? "shippingbox" : "waveform.path.ecg")
                if session.localVideoURL != nil {
                    Label("可回放", systemImage: "play.circle")
                }
            }
            .font(.caption)
            .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.72))
        }
        .padding(.vertical, 5)
    }
}

struct DrillCard: View {
    let drill: DrillRecommendation

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(drill.title)
                    .font(.headline)
                    .foregroundStyle(TennisTheme.courtDeepGreen)
                Spacer()
                Text("\(drill.durationMinutes) 分钟")
                    .font(.caption.bold())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(TennisTheme.ballYellow.opacity(0.35))
                    .clipShape(Capsule())
            }

            Text(drill.focusArea)
                .font(.subheadline)
                .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.68))

            Text(drill.reason)
                .font(.footnote)
                .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.74))
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .tennisCard()
    }
}

struct ThemedPageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.custom("AvenirNextCondensed-Bold", size: 30))
                    .foregroundStyle(TennisTheme.courtDeepGreen)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.72))
            }

            Spacer(minLength: 0)

            SurfaceThemeBadge(surface: TennisTheme.currentSurface)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SurfaceThemeBadge: View {
    let surface: CourtSurfaceTheme
    var emphasized: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: surface.icon)
                    .font(.system(size: 11, weight: .bold))
                Text(surface.scoreboardCode)
                    .font(.system(size: 12, weight: .black, design: .rounded))
            }

            Text(surface.displayName)
                .font(.caption2.bold())
        }
        .foregroundStyle(emphasized ? TennisTheme.courtDeepGreen : TennisTheme.courtDeepGreen.opacity(0.86))
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(emphasized ? TennisTheme.ballYellow : TennisTheme.skyMint.opacity(0.66))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(
                    emphasized
                    ? TennisTheme.ballYellow.opacity(0.92)
                    : TennisTheme.courtDeepGreen.opacity(0.10),
                    lineWidth: 1
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

struct TrainingFocusHeroCard: View {
    let focusHint: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 22)
                .fill(
                    LinearGradient(
                        colors: [TennisTheme.courtDeepGreen, TennisTheme.courtGreen],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Circle()
                .fill(TennisTheme.ballYellow.opacity(0.92))
                .frame(width: 74, height: 74)
                .overlay(
                    Circle()
                        .stroke(Color.black.opacity(0.18), lineWidth: 1)
                )
                .offset(x: 240, y: 96)

            Path { path in
                path.move(to: CGPoint(x: 20, y: 34))
                path.addLine(to: CGPoint(x: 292, y: 34))
                path.move(to: CGPoint(x: 20, y: 112))
                path.addLine(to: CGPoint(x: 322, y: 112))
                path.move(to: CGPoint(x: 166, y: 16))
                path.addLine(to: CGPoint(x: 166, y: 186))
            }
            .stroke(TennisTheme.lineWhite.opacity(0.22), lineWidth: 1.1)

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("训练模式")
                            .font(.caption.bold())
                            .foregroundStyle(TennisTheme.lineWhite.opacity(0.84))
                        Text("本周训练重点")
                            .font(.custom("AvenirNextCondensed-Bold", size: 30))
                            .foregroundStyle(TennisTheme.lineWhite)
                    }

                    Spacer()

                    SurfaceThemeBadge(surface: TennisTheme.currentSurface, emphasized: true)
                }

                Text(focusHint)
                    .font(.subheadline)
                    .foregroundStyle(TennisTheme.lineWhite.opacity(0.90))
                    .lineLimit(3)

                HStack(spacing: 8) {
                    TrainingTag(title: "固定机位")
                    TrainingTag(title: "节奏复盘")
                    TrainingTag(title: TennisTheme.currentSurface.displayName)
                }
            }
            .padding(18)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 194)
        .shadow(color: TennisTheme.courtDeepGreen.opacity(0.18), radius: 14, x: 0, y: 10)
    }
}

struct TrainingTag: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption.bold())
            .foregroundStyle(TennisTheme.lineWhite)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.16))
            .overlay(
                Capsule()
                    .stroke(TennisTheme.lineWhite.opacity(0.16), lineWidth: 1)
            )
            .clipShape(Capsule())
    }
}

struct ArchiveOverviewCard: View {
    let selectedDate: Date
    let sessionCount: Int
    let isComparisonMode: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("回放概览")
                        .font(.headline)
                        .foregroundStyle(TennisTheme.courtDeepGreen)
                    Text(isComparisonMode ? "对比模式已开启，最多可选择两场训练。" : "当前日期下的训练记录和回放入口都集中在这里。")
                        .font(.caption)
                        .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.68))
                }

                Spacer()

                SurfaceThemeBadge(surface: TennisTheme.currentSurface)
            }

            HStack(spacing: 10) {
                ArchiveInfoPill(
                    title: "训练日期",
                    value: selectedDate.formatted(date: .abbreviated, time: .omitted),
                    icon: "calendar"
                )
                ArchiveInfoPill(
                    title: "当天记录",
                    value: "\(sessionCount)",
                    icon: "play.rectangle.on.rectangle"
                )
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .tennisCard()
    }
}

struct ArchiveInfoPill: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption.bold())
                .foregroundStyle(TennisTheme.courtDeepGreen)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.60))
                Text(value)
                    .font(.caption.bold())
                    .foregroundStyle(TennisTheme.courtDeepGreen)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(TennisTheme.lineWhite.opacity(0.42))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

struct StatusBadge: View {
    let status: ProcessingStatus

    var body: some View {
        Text(status.label)
            .font(.caption.bold())
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .foregroundStyle(status.color)
            .background(status.color.opacity(0.18))
            .clipShape(Capsule())
    }
}

struct DashboardHeroCard: View {
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 18)
                .fill(
                    LinearGradient(
                        colors: [TennisTheme.courtDeepGreen, TennisTheme.courtLightGreen],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            RoundedRectangle(cornerRadius: 18)
                .stroke(TennisTheme.lineWhite.opacity(0.28), lineWidth: 1.1)

            Path { path in
                path.move(to: CGPoint(x: 18, y: 34))
                path.addLine(to: CGPoint(x: 200, y: 34))
                path.move(to: CGPoint(x: 18, y: 92))
                path.addLine(to: CGPoint(x: 260, y: 92))
                path.move(to: CGPoint(x: 140, y: 18))
                path.addLine(to: CGPoint(x: 140, y: 138))
            }
            .stroke(TennisTheme.lineWhite.opacity(0.26), lineWidth: 1)

            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("当前主题已同步到全局")
                        .font(.caption.bold())
                        .foregroundStyle(TennisTheme.lineWhite.opacity(0.82))
                    Text("Court Pulse")
                        .font(.custom("AvenirNextCondensed-Bold", size: 28))
                        .foregroundStyle(TennisTheme.lineWhite)
                    Text("让每一次挥拍都有可追踪的数据轨迹")
                        .font(.subheadline)
                        .foregroundStyle(TennisTheme.lineWhite.opacity(0.85))

                    HStack(spacing: 8) {
                        SurfaceThemeBadge(surface: TennisTheme.currentSurface, emphasized: true)
                        Text(TennisTheme.currentSurface.displayName)
                            .font(.caption.bold())
                            .foregroundStyle(TennisTheme.lineWhite.opacity(0.90))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.black.opacity(0.14))
                            .clipShape(Capsule())
                    }
                }

                Spacer()

                Circle()
                    .fill(TennisTheme.ballYellow)
                    .frame(width: 36, height: 36)
                    .overlay(
                        Circle()
                            .stroke(Color.black.opacity(0.20), lineWidth: 1)
                    )
            }
            .padding(16)
        }
        .frame(height: 142)
        .shadow(color: TennisTheme.courtDeepGreen.opacity(0.18), radius: 12, x: 0, y: 8)
    }
}

struct ModelBundleStatusCard: View {
    let status: OnDeviceModelStatus

    private var tint: Color {
        switch status {
        case .checking:
            return TennisTheme.clayOrange
        case .ready:
            return TennisTheme.courtGreen
        case .missing:
            return .red
        case .failed:
            return .red
        }
    }

    private var icon: String {
        switch status {
        case .checking:
            return "hourglass"
        case .ready:
            return "checkmark.shield.fill"
        case .missing:
            return "exclamationmark.triangle.fill"
        case .failed:
            return "xmark.octagon.fill"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.subheadline.bold())
                .foregroundStyle(tint)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(status.summaryTitle)
                    .font(.subheadline.bold())
                    .foregroundStyle(TennisTheme.courtDeepGreen)
                Text(status.detail)
                    .font(.caption)
                    .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.70))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(tint.opacity(0.24), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

struct ModelDiagnosticsCard: View {
    let diagnostics: LoadedModelDiagnostics?
    let latestSummary: OnDeviceInferenceSummary?
    let latestInferenceDate: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("模型诊断")
                .font(.subheadline.bold())
                .foregroundStyle(TennisTheme.courtDeepGreen)

            if let diagnostics {
                Text("模型：\(diagnostics.modelName)")
                    .font(.caption.bold())
                    .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.82))

                ioSection(title: "输入", descriptors: diagnostics.inputDescriptors)
                ioSection(title: "输出", descriptors: diagnostics.outputDescriptors)
            } else {
                Text("模型尚未加载，加载后会展示输入/输出签名。")
                    .font(.caption)
                    .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.70))
            }

            if let latestSummary, let latestInferenceDate {
                let actionCount = latestSummary.detectedActions.count
                let forehandCount = latestSummary.detectedActions.filter { $0.type == .forehand }.count
                let backhandCount = latestSummary.detectedActions.filter { $0.type == .backhand }.count
                let serveCount = latestSummary.detectedActions.filter { $0.type == .serve }.count
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("最近推理：\(latestInferenceDate.formatted(date: .omitted, time: .shortened))")
                        .font(.caption.bold())
                        .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.84))
                    Text("抽帧 \(latestSummary.sampledFrameCount) / 成功 \(latestSummary.successfulPredictionCount) · 可见率 \(latestSummary.ballVisibleRate.formatted(.percent.precision(.fractionLength(1)))) · 弹跳 \(latestSummary.estimatedBounceCount)")
                        .font(.caption)
                        .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.70))
                    if let first = latestSummary.trackedPoints.first(where: { $0.isVisible }) {
                        Text("首个球坐标：(\(first.x), \(first.y))")
                            .font(.caption)
                            .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.70))
                    }
                    if let bounce = latestSummary.bouncePoints.first {
                        Text("首个弹跳点：(\(bounce.x), \(bounce.y))")
                            .font(.caption)
                            .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.70))
                    }
                    if actionCount > 0 {
                        Text("动作识别：正手 \(forehandCount) / 反手 \(backhandCount) / 发球 \(serveCount)")
                            .font(.caption)
                            .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.70))
                        if let firstAction = latestSummary.detectedActions.first {
                            Text("首个动作：\(firstAction.type.displayName)（\(firstAction.confidence.formatted(.number.precision(.fractionLength(2))))）")
                                .font(.caption)
                                .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.70))
                        }
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .tennisCard()
    }

    @ViewBuilder
    private func ioSection(title: String, descriptors: [ModelIODescriptor]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.bold())
                .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.84))

            if descriptors.isEmpty {
                Text("无")
                    .font(.caption)
                    .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.60))
            } else {
                ForEach(Array(descriptors.prefix(3))) { descriptor in
                    Text("\(descriptor.name) · \(descriptor.type) · \(descriptor.detail)")
                        .font(.caption)
                        .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.70))
                }
                if descriptors.count > 3 {
                    Text("另有 \(descriptors.count - 3) 个字段…")
                        .font(.caption2)
                        .foregroundStyle(TennisTheme.courtDeepGreen.opacity(0.56))
                }
            }
        }
    }
}

extension ProcessingStatus {
    var label: String {
        switch self {
        case .completed:
            return "已完成"
        case .processing:
            return "处理中"
        case .failed:
            return "失败"
        }
    }

    var color: Color {
        switch self {
        case .completed:
            return TennisTheme.courtGreen
        case .processing:
            return TennisTheme.clayOrange
        case .failed:
            return .red
        }
    }
}
