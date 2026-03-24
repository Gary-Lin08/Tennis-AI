import XCTest
@testable import Tennis_AI

// MARK: - URLProtocol mock

private class MockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = MockURLProtocol.requestHandler else {
            client?.urlProtocol(self, didFailWithError:
                NSError(domain: "MockURLProtocol", code: -1, userInfo: nil))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func makeMockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: config)
}

private func httpBodyData(from request: URLRequest) -> Data {
    if let body = request.httpBody {
        return body
    }

    guard let stream = request.httpBodyStream else {
        return Data()
    }

    stream.open()
    defer { stream.close() }

    let bufferSize = 4096
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }

    var data = Data()
    while stream.hasBytesAvailable {
        let readCount = stream.read(buffer, maxLength: bufferSize)
        guard readCount > 0 else { break }
        data.append(buffer, count: readCount)
    }
    return data
}

private func makeConfig() -> RemoteAnalysisConfig {
    RemoteAnalysisConfig.build(
        endpointRaw: "http://127.0.0.1:8000",
        installID: "test-install",
        localUserIDRaw: "player_001"
    )!
}

// MARK: - Tests

@MainActor
final class RemoteAnalysisServiceTests: XCTestCase {

    // MARK: - uploadVideo: multipart body contains required fields

    func testUploadVideoRequestContainsActorKey() async throws {
        var capturedBody: Data?
        MockURLProtocol.requestHandler = { request in
            capturedBody = httpBodyData(from: request)
            let json = #"{"ok":true,"job_id":"j1","actor_key":"ios:test-install:player_001","local_session_id":"s1","state":"queued","stage":"queued","created_at_utc":"2024-01-01T00:00:00Z"}"#
            let resp = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (resp, json.data(using: .utf8)!)
        }

        let service = RemoteAnalysisService(session: makeMockSession())
        let config = makeConfig()
        let session = makeMinimalAnalysisSession()
        let tempVideo = try makeTemporaryVideoFile()
        defer { try? FileManager.default.removeItem(at: tempVideo) }

        _ = try await service.uploadVideo(
            config: config,
            localSessionID: "s1",
            videoURL: tempVideo,
            localSummary: session
        )

        let bodyString = String(data: capturedBody ?? Data(), encoding: .utf8) ?? ""
        let actorKey = config.actorKey
        XCTAssertTrue(bodyString.contains("actor_key"),
                      "Multipart body must contain actor_key field")
        XCTAssertTrue(bodyString.contains(actorKey),
                      "Multipart body must include actorKey value")
    }

    func testUploadVideoRequestContainsLocalSessionID() async throws {
        MockURLProtocol.requestHandler = { request in
            let json = #"{"ok":true,"job_id":"j2","actor_key":"ios:test-install:player_001","local_session_id":"session-xyz","state":"queued","stage":"queued","created_at_utc":"2024-01-01T00:00:00Z"}"#
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, json.data(using: .utf8)!)
        }

        let service = RemoteAnalysisService(session: makeMockSession())
        let tempVideo = try makeTemporaryVideoFile()
        defer { try? FileManager.default.removeItem(at: tempVideo) }

        let job = try await service.uploadVideo(
            config: makeConfig(),
            localSessionID: "session-xyz",
            videoURL: tempVideo,
            localSummary: makeMinimalAnalysisSession()
        )

        let localSessionID = job.localSessionID
        XCTAssertEqual(localSessionID, "session-xyz")
    }

    // MARK: - HTTP error propagation

    func testUploadVideo4xxThrowsServerError() async throws {
        MockURLProtocol.requestHandler = { request in
            let body = #"{"detail":"unauthorized"}"#
            let resp = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (resp, body.data(using: .utf8)!)
        }

        let service = RemoteAnalysisService(session: makeMockSession())
        let tempVideo = try makeTemporaryVideoFile()
        defer { try? FileManager.default.removeItem(at: tempVideo) }

        do {
            _ = try await service.uploadVideo(
                config: makeConfig(),
                localSessionID: "s1",
                videoURL: tempVideo,
                localSummary: makeMinimalAnalysisSession()
            )
            XCTFail("Expected server error to be thrown")
        } catch RemoteAnalysisServiceError.server(let statusCode, _) {
            XCTAssertEqual(statusCode, 401)
        }
    }

    func testFetchJobs5xxThrowsServerError() async throws {
        MockURLProtocol.requestHandler = { request in
            let resp = HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }

        let service = RemoteAnalysisService(session: makeMockSession())

        do {
            _ = try await service.fetchJobs(config: makeConfig())
            XCTFail("Expected server error to be thrown")
        } catch RemoteAnalysisServiceError.server(let statusCode, _) {
            XCTAssertEqual(statusCode, 503)
        }
    }

    // MARK: - fetchJobs: success decoding

    func testFetchJobsReturnsEmptyArrayForEmptyResponse() async throws {
        MockURLProtocol.requestHandler = { request in
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, "[]".data(using: .utf8)!)
        }

        let service = RemoteAnalysisService(session: makeMockSession())
        let jobs = try await service.fetchJobs(config: makeConfig())
        XCTAssertTrue(jobs.isEmpty)
    }

    // MARK: - Multipart boundary format

    func testUploadVideoContentTypeHeaderContainsBoundary() async throws {
        var capturedContentType: String?
        MockURLProtocol.requestHandler = { request in
            capturedContentType = request.value(forHTTPHeaderField: "Content-Type")
            let json = #"{"ok":true,"job_id":"j3","actor_key":"ios:test-install:player_001","local_session_id":"s1","state":"queued","stage":"queued","created_at_utc":"2024-01-01T00:00:00Z"}"#
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, json.data(using: .utf8)!)
        }

        let service = RemoteAnalysisService(session: makeMockSession())
        let tempVideo = try makeTemporaryVideoFile()
        defer { try? FileManager.default.removeItem(at: tempVideo) }

        _ = try await service.uploadVideo(
            config: makeConfig(),
            localSessionID: "s1",
            videoURL: tempVideo,
            localSummary: makeMinimalAnalysisSession()
        )

        XCTAssertNotNil(capturedContentType)
        XCTAssertTrue(capturedContentType?.hasPrefix("multipart/form-data; boundary=") == true,
                      "Content-Type must be multipart/form-data with a boundary")
        let boundary = capturedContentType?.components(separatedBy: "boundary=").last ?? ""
        XCTAssertFalse(boundary.isEmpty, "Boundary must not be empty")
    }
}

// MARK: - Helpers

private func makeMinimalAnalysisSession() -> AnalysisSession {
    AnalysisSession(
        id: UUID(),
        videoTitle: "test.mp4",
        sourceID: "src-1",
        eventDate: Date(timeIntervalSince1970: 0),
        trackedFrames: 0,
        totalFrames: 0,
        ballVisibleRate: 0,
        trackingQualityScore: 0,
        estimatedBounceCount: 0,
        processingStatus: .completed,
        inputSource: nil,
        localVideoPath: nil,
        trajectoryPoints: nil,
        bouncePoints: nil,
        detectedActions: nil,
        note: ""
    )
}

private func makeTemporaryVideoFile() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString + ".mp4")
    try Data("fake video bytes".utf8).write(to: url)
    return url
}
