import Foundation

struct RemoteAnalysisConfig: Equatable {
    let baseURL: URL
    let actorKey: String
    let localUserID: String

    static func build(endpointRaw: String, installID: String, localUserIDRaw: String) -> RemoteAnalysisConfig? {
        let endpoint = endpointRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        let localUserID = localUserIDRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !localUserID.isEmpty,
            var components = URLComponents(string: endpoint),
            components.scheme != nil,
            components.host != nil
        else {
            return nil
        }

        if [
            "/sessions/upload",
            "/telemetry/events",
            "/analysis/videos",
            "/analysis/jobs"
        ].contains(components.path) {
            components.path = ""
        }

        guard let baseURL = components.url else { return nil }
        return RemoteAnalysisConfig(
            baseURL: baseURL,
            actorKey: "ios:\(installID):\(localUserID)",
            localUserID: localUserID
        )
    }
}

enum RemoteAnalysisServiceError: LocalizedError {
    case invalidResponse
    case server(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "远端分析返回了无法识别的响应。"
        case .server(let statusCode, let message):
            return "远端分析请求失败（HTTP \(statusCode)）：\(message)"
        }
    }
}

struct RemoteAnalysisService {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func uploadVideo(
        config: RemoteAnalysisConfig,
        localSessionID: String,
        videoURL: URL,
        localSummary: AnalysisSession,
        manualCalibration: SessionCourtCalibration? = nil
    ) async throws -> RemoteAnalysisJob {
        let boundary = "Boundary-\(UUID().uuidString)"
        let summaryJSON = try Self.encoder.encode(localSummary)
        let calibrationJSON = try manualCalibration.map { try Self.encoder.encode($0) }
        let fileData = try Data(contentsOf: videoURL)
        var request = URLRequest(
            url: config.baseURL
                .appendingPathComponent("analysis")
                .appendingPathComponent("videos")
        )
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.buildMultipartBody(
            boundary: boundary,
            actorKey: config.actorKey,
            localSessionID: localSessionID,
            fileName: videoURL.lastPathComponent,
            fileData: fileData,
            localSummaryJSON: summaryJSON,
            manualCalibrationJSON: calibrationJSON
        )

        let (data, response) = try await session.data(for: request)
        let httpResponse = try Self.validate(response: response, data: data)
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw RemoteAnalysisServiceError.server(
                statusCode: httpResponse.statusCode,
                message: Self.parseServerError(data: data)
            )
        }

        guard let payload = try? Self.decoder.decode(RemoteUploadResponse.self, from: data) else {
            throw RemoteAnalysisServiceError.invalidResponse
        }
        return payload.asRemoteJob
    }

    func fetchJobs(config: RemoteAnalysisConfig) async throws -> [RemoteAnalysisJob] {
        guard var components = URLComponents(
            url: config.baseURL
                .appendingPathComponent("analysis")
                .appendingPathComponent("jobs"),
            resolvingAgainstBaseURL: false
        ) else {
            throw RemoteAnalysisServiceError.invalidResponse
        }
        components.queryItems = [
            URLQueryItem(name: "actor_key", value: config.actorKey),
            URLQueryItem(name: "limit", value: "100")
        ]
        guard let url = components.url else { throw RemoteAnalysisServiceError.invalidResponse }

        let (data, response) = try await session.data(from: url)
        let httpResponse = try Self.validate(response: response, data: data)
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw RemoteAnalysisServiceError.server(
                statusCode: httpResponse.statusCode,
                message: Self.parseServerError(data: data)
            )
        }
        guard let payload = try? Self.decoder.decode([RemoteAnalysisJob].self, from: data) else {
            throw RemoteAnalysisServiceError.invalidResponse
        }
        return payload
    }

    func fetchJob(config: RemoteAnalysisConfig, jobID: String) async throws -> RemoteAnalysisJob {
        let url = config.baseURL
            .appendingPathComponent("analysis")
            .appendingPathComponent("jobs")
            .appendingPathComponent(jobID)
        var request = URLRequest(url: url)
        request.timeoutInterval = 60

        let (data, response) = try await session.data(for: request)
        let httpResponse = try Self.validate(response: response, data: data)
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw RemoteAnalysisServiceError.server(
                statusCode: httpResponse.statusCode,
                message: Self.parseServerError(data: data)
            )
        }
        guard let payload = try? Self.decoder.decode(RemoteAnalysisJob.self, from: data) else {
            throw RemoteAnalysisServiceError.invalidResponse
        }
        return payload
    }

    func fetchSessions(config: RemoteAnalysisConfig) async throws -> [AnalysisSession] {
        guard var components = URLComponents(url: config.baseURL.appendingPathComponent("sessions"), resolvingAgainstBaseURL: false) else {
            throw RemoteAnalysisServiceError.invalidResponse
        }
        components.queryItems = [
            URLQueryItem(name: "actor_key", value: config.actorKey),
            URLQueryItem(name: "limit", value: "100")
        ]
        guard let url = components.url else { throw RemoteAnalysisServiceError.invalidResponse }

        let (data, response) = try await session.data(from: url)
        let httpResponse = try Self.validate(response: response, data: data)
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw RemoteAnalysisServiceError.server(
                statusCode: httpResponse.statusCode,
                message: Self.parseServerError(data: data)
            )
        }
        guard let payload = try? Self.decoder.decode([RemoteSessionSummary].self, from: data) else {
            throw RemoteAnalysisServiceError.invalidResponse
        }
        return payload.map { $0.asAnalysisSession }
    }

    func fetchSessionDetail(config: RemoteAnalysisConfig, sessionRef: String) async throws -> AnalysisSession {
        let detailURL = config.baseURL
            .appendingPathComponent("sessions")
            .appendingPathComponent(sessionRef)
            .appendingPathComponent("detail")
        guard var components = URLComponents(url: detailURL, resolvingAgainstBaseURL: false) else {
            throw RemoteAnalysisServiceError.invalidResponse
        }
        components.queryItems = [URLQueryItem(name: "actor_key", value: config.actorKey)]
        guard let url = components.url else { throw RemoteAnalysisServiceError.invalidResponse }

        let (data, response) = try await session.data(from: url)
        let httpResponse = try Self.validate(response: response, data: data)
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw RemoteAnalysisServiceError.server(
                statusCode: httpResponse.statusCode,
                message: Self.parseServerError(data: data)
            )
        }
        guard let payload = try? Self.decoder.decode(RemoteSessionDetailEnvelope.self, from: data) else {
            throw RemoteAnalysisServiceError.invalidResponse
        }
        return payload.asAnalysisSession
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = iso8601Fractional.date(from: value) ?? iso8601.date(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO8601 date: \(value)")
        }
        return decoder
    }()

    private static let iso8601Fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func validate(response: URLResponse, data: Data) throws -> HTTPURLResponse {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RemoteAnalysisServiceError.invalidResponse
        }
        return httpResponse
    }

    private static func parseServerError(data: Data) -> String {
        if let text = String(data: data, encoding: .utf8), !text.isEmpty {
            return text
        }
        return "unknown"
    }

    private static func buildMultipartBody(
        boundary: String,
        actorKey: String,
        localSessionID: String,
        fileName: String,
        fileData: Data,
        localSummaryJSON: Data,
        manualCalibrationJSON: Data?
    ) -> Data {
        var body = Data()

        func appendField(name: String, value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }

        appendField(name: "actor_key", value: actorKey)
        appendField(name: "local_session_id", value: localSessionID)

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"local_summary_json\"\r\n\r\n".data(using: .utf8)!)
        body.append(localSummaryJSON)
        body.append("\r\n".data(using: .utf8)!)

        if let manualCalibrationJSON {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"manual_calibration_json\"\r\n\r\n".data(using: .utf8)!)
            body.append(manualCalibrationJSON)
            body.append("\r\n".data(using: .utf8)!)
        }

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"video_file\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        return body
    }
}

private struct RemoteUploadResponse: Codable {
    let ok: Bool
    let jobID: String
    let actorKey: String
    let localSessionID: String
    let state: RemoteAnalysisJobState
    let stage: String
    let createdAtUTC: Date

    enum CodingKeys: String, CodingKey {
        case ok
        case jobID = "job_id"
        case actorKey = "actor_key"
        case localSessionID = "local_session_id"
        case state
        case stage
        case createdAtUTC = "created_at_utc"
    }

    var asRemoteJob: RemoteAnalysisJob {
        RemoteAnalysisJob(
            id: jobID,
            actorKey: actorKey,
            localSessionID: localSessionID,
            state: state,
            stage: stage,
            errorMessage: nil,
            remoteSessionID: nil,
            remoteExternalSessionID: nil,
            sourceVideoPath: nil,
            createdAtUTC: createdAtUTC,
            updatedAtUTC: createdAtUTC
        )
    }
}

private struct RemoteSessionSummary: Codable {
    let id: UUID
    let actorKey: String?
    let externalSessionID: String
    let sourceVideoPath: String
    let generatedAtUTC: Date?
    let totalFrames: Int?
    let durationSec: Double?
    let numRallies: Int
    let numShots: Int
    let numBounces: Int
    let rawSummary: [String: StringOrDoubleCodable]?

    enum CodingKeys: String, CodingKey {
        case id
        case actorKey = "actor_key"
        case externalSessionID = "external_session_id"
        case sourceVideoPath = "source_video_path"
        case generatedAtUTC = "generated_at_utc"
        case totalFrames = "total_frames"
        case durationSec = "duration_sec"
        case numRallies = "num_rallies"
        case numShots = "num_shots"
        case numBounces = "num_bounces"
        case rawSummary = "raw_summary"
    }

    var asAnalysisSession: AnalysisSession {
        let trackedFrames = Int(rawSummary?["tracked_frames"]?.doubleValue ?? 0)
        let visibleRate = rawSummary?["ball_visible_rate"]?.doubleValue ?? 0
        let trackingQualityScore = rawSummary?["tracking_quality_score"]?.doubleValue ?? 0
        let note = rawSummary?["local_note"]?.stringValue ?? "已回填远端结构化会话。"
        let modelVersions = rawSummary?["model_versions"]?.stringDictionary
        let courtDetectionQualityScore = rawSummary?["court_detection_quality_score"]?.doubleValue

        return AnalysisSession(
            id: id,
            videoTitle: URL(fileURLWithPath: sourceVideoPath).lastPathComponent,
            sourceID: externalSessionID,
            actorKey: actorKey,
            eventDate: generatedAtUTC ?? Date(),
            trackedFrames: trackedFrames,
            totalFrames: totalFrames ?? 0,
            ballVisibleRate: visibleRate,
            trackingQualityScore: trackingQualityScore,
            estimatedBounceCount: numBounces,
            processingStatus: .completed,
            inputSource: nil,
            localVideoPath: nil,
            trajectoryPoints: nil,
            bouncePoints: nil,
            detectedActions: nil,
            note: note,
            sessionOrigin: .remoteStructured,
            remoteModelVersions: modelVersions,
            courtDetectionQualityScore: courtDetectionQualityScore
        )
    }
}

private struct RemoteSessionDetailEnvelope: Codable {
    let ok: Bool
    let session: RemoteSessionSummary
    let rallies: [StructuredRally]
    let shots: [StructuredShot]
    let bounces: [StructuredBounce]
    let scoreTimeline: [ScoreTimelineEntry]
    let modelVersions: [String: String]
    let courtDetectionQualityScore: Double?

    enum CodingKeys: String, CodingKey {
        case ok
        case session
        case rallies
        case shots
        case bounces
        case scoreTimeline = "score_timeline"
        case modelVersions = "model_versions"
        case courtDetectionQualityScore = "court_detection_quality_score"
    }

    var asAnalysisSession: AnalysisSession {
        let trackedFrames = Int(session.rawSummary?["tracked_frames"]?.doubleValue ?? 0)
        let visibleRate = session.rawSummary?["ball_visible_rate"]?.doubleValue ?? 0
        let trackingQualityScore = session.rawSummary?["tracking_quality_score"]?.doubleValue
            ?? courtDetectionQualityScore
            ?? 0
        let note = session.rawSummary?["local_note"]?.stringValue ?? "远端结构化分析已完成。"
        let mergedModelVersions = session.rawSummary?["model_versions"]?.stringDictionary ?? modelVersions

        return AnalysisSession(
            id: session.id,
            videoTitle: URL(fileURLWithPath: session.sourceVideoPath).lastPathComponent,
            sourceID: session.externalSessionID,
            actorKey: session.actorKey,
            eventDate: session.generatedAtUTC ?? Date(),
            trackedFrames: trackedFrames,
            totalFrames: session.totalFrames ?? 0,
            ballVisibleRate: visibleRate,
            trackingQualityScore: trackingQualityScore,
            estimatedBounceCount: session.numBounces,
            processingStatus: .completed,
            inputSource: nil,
            localVideoPath: nil,
            trajectoryPoints: nil,
            bouncePoints: nil,
            detectedActions: nil,
            note: note,
            sessionOrigin: .remoteStructured,
            structuredRallies: rallies,
            structuredShots: shots,
            structuredBounces: bounces,
            scoreTimeline: scoreTimeline,
            remoteModelVersions: mergedModelVersions,
            courtDetectionQualityScore: courtDetectionQualityScore
        )
    }
}

private enum StringOrDoubleCodable: Codable {
    case string(String)
    case double(Double)
    case dictionary([String: StringOrDoubleCodable])
    case array([StringOrDoubleCodable])
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let array = try? container.decode([StringOrDoubleCodable].self) {
            self = .array(array)
        } else if let dictionary = try? container.decode([String: StringOrDoubleCodable].self) {
            self = .dictionary(dictionary)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .dictionary(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    var stringValue: String? {
        switch self {
        case .string(let value):
            return value
        default:
            return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .double(let value):
            return value
        case .string(let value):
            return Double(value)
        default:
            return nil
        }
    }

    var dictionaryValue: [String: StringOrDoubleCodable]? {
        switch self {
        case .dictionary(let value):
            return value
        default:
            return nil
        }
    }

    var stringDictionary: [String: String]? {
        dictionaryValue?.reduce(into: [:]) { partial, item in
            if let string = item.value.stringValue {
                partial[item.key] = string
            }
        }
    }
}
