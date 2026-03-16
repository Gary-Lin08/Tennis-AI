//
//  AppTelemetry.swift
//  Tennis AI
//
//  Created by Codex on 2026/3/12.
//

import Combine
import Foundation

#if canImport(UIKit)
import UIKit
#endif

struct AppTelemetryEventItem: Codable {
    let eventID: String
    let eventName: String
    let eventTsUTC: String
    let screenName: String?
    let targetName: String?
    let dwellMs: Int?
    let durationMs: Int?
    let metadata: [String: String]

    enum CodingKeys: String, CodingKey {
        case eventID = "event_id"
        case eventName = "event_name"
        case eventTsUTC = "event_ts_utc"
        case screenName = "screen_name"
        case targetName = "target_name"
        case dwellMs = "dwell_ms"
        case durationMs = "duration_ms"
        case metadata
    }
}

struct AppTelemetryEventsRequest: Codable {
    let installID: String
    let appSessionID: String
    let localUserID: String
    let platform: String
    let appVersion: String
    let osVersion: String
    let events: [AppTelemetryEventItem]

    enum CodingKeys: String, CodingKey {
        case installID = "install_id"
        case appSessionID = "app_session_id"
        case localUserID = "local_user_id"
        case platform
        case appVersion = "app_version"
        case osVersion = "os_version"
        case events
    }
}

struct AppTelemetryEventsResponse: Codable {
    let ok: Bool
    let inserted: Int
    let receivedAtUTC: String

    enum CodingKeys: String, CodingKey {
        case ok
        case inserted
        case receivedAtUTC = "received_at_utc"
    }
}

enum AppTelemetryError: LocalizedError {
    case invalidEndpoint
    case invalidResponse
    case httpError(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "Telemetry endpoint 无效。"
        case .invalidResponse:
            return "Telemetry 返回了无法识别的响应。"
        case .httpError(let code, let message):
            return "Telemetry HTTP \(code): \(message)"
        }
    }
}

@MainActor
final class AppTelemetryManager: ObservableObject {
    static let shared = AppTelemetryManager()

    @Published private(set) var pendingEventsCount: Int = 0
    @Published private(set) var lastUploadMessage: String?

    private let defaults: UserDefaults
    private var eventsEndpoint: URL?
    private var localUserID: String = "local-default"
    private let installID: String
    private var appSessionID: String
    private var queuedEvents: [AppTelemetryEventItem] = []
    private var screenEntryTimes: [String: Date] = [:]
    private var foregroundStartedAt: Date?
    private var uploadTask: Task<Void, Never>?

    private static let installIDKey = "telemetry_install_id"
    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private let flushThreshold = 12

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let persisted = defaults.string(forKey: Self.installIDKey)
        if let persisted, !persisted.isEmpty {
            self.installID = persisted
        } else {
            let newID = UUID().uuidString.lowercased()
            defaults.set(newID, forKey: Self.installIDKey)
            self.installID = newID
        }
        self.appSessionID = UUID().uuidString.lowercased()
    }

    var stableInstallID: String {
        installID
    }

    static func normalizedEventsEndpoint(from raw: String) -> URL? {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: cleaned), components.scheme != nil else {
            return nil
        }
        if components.path.isEmpty || components.path == "/" {
            components.path = "/telemetry/events"
        } else if ["/sessions/upload", "/analysis/videos", "/analysis/jobs"].contains(components.path) {
            components.path = "/telemetry/events"
        }
        return components.url
    }

    func configure(endpointRaw: String, localUserIDRaw: String) {
        eventsEndpoint = Self.normalizedEventsEndpoint(from: endpointRaw)
        let normalizedUserID = localUserIDRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        localUserID = normalizedUserID.isEmpty ? "local-default" : normalizedUserID
    }

    func startNewAppSession() {
        appSessionID = UUID().uuidString.lowercased()
        screenEntryTimes.removeAll()
        foregroundStartedAt = nil
    }

    func trackTap(screen: String, target: String, metadata: [String: String] = [:]) {
        enqueue(
            eventName: "tap",
            screenName: screen,
            targetName: target,
            metadata: metadata
        )
    }

    func trackScreenView(screen: String) {
        screenEntryTimes[screen] = Date()
        enqueue(eventName: "screen_view", screenName: screen, metadata: [:])
    }

    func trackScreenLeave(screen: String) {
        let dwellMs: Int?
        if let start = screenEntryTimes.removeValue(forKey: screen) {
            dwellMs = max(Int(Date().timeIntervalSince(start) * 1000), 0)
        } else {
            dwellMs = nil
        }

        enqueue(
            eventName: "screen_leave",
            screenName: screen,
            dwellMs: dwellMs,
            metadata: [:]
        )
    }

    func appDidBecomeActive() {
        if foregroundStartedAt == nil {
            foregroundStartedAt = Date()
        }
        enqueue(eventName: "app_foreground", metadata: [:])
    }

    func appWillMoveToBackground() {
        if let start = foregroundStartedAt {
            let durationMs = max(Int(Date().timeIntervalSince(start) * 1000), 0)
            enqueue(
                eventName: "app_usage_segment",
                durationMs: durationMs,
                metadata: [:]
            )
        }
        foregroundStartedAt = nil
        enqueue(eventName: "app_background", metadata: [:])
        flush(force: true)
    }

    func flush(force: Bool = false) {
        guard let endpoint = eventsEndpoint else {
            if force {
                lastUploadMessage = "未配置 telemetry endpoint，事件仅保存在本地队列。"
            }
            return
        }

        guard !queuedEvents.isEmpty else { return }
        if !force && queuedEvents.count < flushThreshold { return }
        if uploadTask != nil { return }

        let eventsToUpload = queuedEvents
        queuedEvents.removeAll()
        pendingEventsCount = 0

        let request = AppTelemetryEventsRequest(
            installID: installID,
            appSessionID: appSessionID,
            localUserID: localUserID,
            platform: "ios",
            appVersion: appVersion,
            osVersion: osVersion,
            events: eventsToUpload
        )

        uploadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await self.postEvents(request: request, endpoint: endpoint)
                if Task.isCancelled { return }
                self.lastUploadMessage = "Telemetry 已上报 \(response.inserted) 条事件。"
                self.uploadTask = nil
                if !self.queuedEvents.isEmpty {
                    self.flush(force: true)
                }
            } catch {
                if Task.isCancelled { return }
                self.queuedEvents.insert(contentsOf: eventsToUpload, at: 0)
                self.pendingEventsCount = self.queuedEvents.count
                self.lastUploadMessage = error.localizedDescription
                self.uploadTask = nil
            }
        }
    }

    private func enqueue(
        eventName: String,
        screenName: String? = nil,
        targetName: String? = nil,
        dwellMs: Int? = nil,
        durationMs: Int? = nil,
        metadata: [String: String]
    ) {
        let event = AppTelemetryEventItem(
            eventID: UUID().uuidString.lowercased(),
            eventName: eventName,
            eventTsUTC: Self.isoFormatter.string(from: Date()),
            screenName: screenName,
            targetName: targetName,
            dwellMs: dwellMs,
            durationMs: durationMs,
            metadata: metadata
        )
        queuedEvents.append(event)
        pendingEventsCount = queuedEvents.count
        flush(force: false)
    }

    private func postEvents(
        request: AppTelemetryEventsRequest,
        endpoint: URL
    ) async throws -> AppTelemetryEventsResponse {
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 60
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        urlRequest.httpBody = try encoder.encode(request)

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw AppTelemetryError.invalidResponse
        }

        guard (200..<300).contains(http.statusCode) else {
            let message = parseErrorMessage(data)
            throw AppTelemetryError.httpError(statusCode: http.statusCode, message: message)
        }

        let decoder = JSONDecoder()
        guard let payload = try? decoder.decode(AppTelemetryEventsResponse.self, from: data) else {
            throw AppTelemetryError.invalidResponse
        }
        return payload
    }

    private func parseErrorMessage(_ data: Data) -> String {
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            return "unknown"
        }
        if
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let detail = object["detail"]
        {
            return String(describing: detail)
        }
        return text
    }

    private var appVersion: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(short)(\(build))"
    }

    private var osVersion: String {
        #if canImport(UIKit)
        return "iOS \(UIDevice.current.systemVersion)"
        #else
        return ProcessInfo.processInfo.operatingSystemVersionString
        #endif
    }
}
