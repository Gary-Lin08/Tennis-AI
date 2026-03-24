//
//  BackendSync.swift
//  Tennis AI
//
//  Created by Codex on 2026/3/12.
//

import Foundation

struct BackendUploadConfig: Equatable {
    let uploadEndpoint: URL
    let userID: UUID

    static func build(endpointRaw: String, userIDRaw: String) -> BackendUploadConfig? {
        let endpoint = endpointRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = userIDRaw.trimmingCharacters(in: .whitespacesAndNewlines)

        guard
            let normalizedURL = normalizeUploadURL(endpoint),
            let uuid = UUID(uuidString: user)
        else {
            return nil
        }

        return BackendUploadConfig(uploadEndpoint: normalizedURL, userID: uuid)
    }

    private static func normalizeUploadURL(_ raw: String) -> URL? {
        guard var components = URLComponents(string: raw), components.scheme != nil else {
            return nil
        }

        if components.path.isEmpty || components.path == "/" {
            components.path = "/sessions/upload"
        }

        return components.url
    }
}

struct BackendSessionPayload: Codable {
    let sessionExternalID: String
    let sourceVideoPath: String
    let generatedAtUTC: String?
    let totalFrames: Int?
    let durationSec: Double?
    let firstServerSide: String?
    let currentServerSide: String?
    let finalSetsNear: Int?
    let finalSetsFar: Int?
    let finalGamesNear: Int?
    let finalGamesFar: Int?
    let finalPointsNear: String?
    let finalPointsFar: String?
    let numRallies: Int?
    let numShots: Int?
    let numBounces: Int?
    let numPointsScored: Int?
    let numPointsPending: Int?

    enum CodingKeys: String, CodingKey {
        case sessionExternalID = "session_external_id"
        case sourceVideoPath = "source_video_path"
        case generatedAtUTC = "generated_at_utc"
        case totalFrames = "total_frames"
        case durationSec = "duration_sec"
        case firstServerSide = "first_server_side"
        case currentServerSide = "current_server_side"
        case finalSetsNear = "final_sets_near"
        case finalSetsFar = "final_sets_far"
        case finalGamesNear = "final_games_near"
        case finalGamesFar = "final_games_far"
        case finalPointsNear = "final_points_near"
        case finalPointsFar = "final_points_far"
        case numRallies = "num_rallies"
        case numShots = "num_shots"
        case numBounces = "num_bounces"
        case numPointsScored = "num_points_scored"
        case numPointsPending = "num_points_pending"
    }
}

struct BackendAnalysisPayload: Codable {
    let schemaVersion: String
    let generatedAtUTC: String
    let session: BackendSessionPayload
    let rallies: [[String: String]]
    let shots: [[String: String]]
    let bounces: [[String: String]]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case generatedAtUTC = "generated_at_utc"
        case session
        case rallies
        case shots
        case bounces
    }
}

struct BackendUploadEnvelope: Codable {
    let userID: String
    let overwriteExistingChildren: Bool
    let payload: BackendAnalysisPayload

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case overwriteExistingChildren = "overwrite_existing_children"
        case payload
    }
}

struct BackendUploadResponse: Codable {
    let ok: Bool
    let sessionID: String
    let externalSessionID: String
    let schemaVersion: String

    enum CodingKeys: String, CodingKey {
        case ok
        case sessionID = "session_id"
        case externalSessionID = "external_session_id"
        case schemaVersion = "schema_version"
    }
}

enum BackendUploadError: LocalizedError {
    case invalidResponse
    case server(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "后端返回了无法识别的响应。"
        case .server(let statusCode, let message):
            return "后端请求失败（HTTP \(statusCode)）：\(message)"
        }
    }
}

struct BackendUploader {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func upload(
        config: BackendUploadConfig,
        payload: BackendAnalysisPayload,
        overwriteExistingChildren: Bool = true
    ) async throws -> BackendUploadResponse {
        let requestBody = BackendUploadEnvelope(
            userID: config.userID.uuidString.lowercased(),
            overwriteExistingChildren: overwriteExistingChildren,
            payload: payload
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let body = try encoder.encode(requestBody)

        var request = URLRequest(url: config.uploadEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BackendUploadError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = parseServerError(data: data)
            throw BackendUploadError.server(statusCode: httpResponse.statusCode, message: message)
        }

        let decoder = JSONDecoder()
        guard let payload = try? decoder.decode(BackendUploadResponse.self, from: data) else {
            throw BackendUploadError.invalidResponse
        }
        return payload
    }

    private func parseServerError(data: Data) -> String {
        if let text = String(data: data, encoding: .utf8), !text.isEmpty {
            if
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let detail = object["detail"]
            {
                return String(describing: detail)
            }
            return text
        }
        return "unknown"
    }
}
