import Darwin
import Foundation
import PullerCore
import PullerSystem
import XCTest
@testable import PullerHelper

final class HelperServerTests: XCTestCase {
    func testReadsUnixPeerCredentialsFromSocketPair() throws {
        var descriptors: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
        defer {
            close(descriptors[0])
            close(descriptors[1])
        }

        let credentials = try UnixPeerCredentials.read(from: descriptors[0])

        XCTAssertEqual(credentials.uid, geteuid())
        XCTAssertEqual(credentials.gid, getegid())
    }

    func testSocketPathPolicyRejectsRegularFileAndSymlink() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let regular = directory.appendingPathComponent("regular")
        XCTAssertTrue(FileManager.default.createFile(atPath: regular.path, contents: Data()))
        XCTAssertThrowsError(try HelperSocketPathPolicy.validateExistingPath(regular.path))

        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: regular)
        XCTAssertThrowsError(try HelperSocketPathPolicy.validateExistingPath(link.path))
    }

    func testFrameSessionRejectsOversizedInput() throws {
        var oversized = HelperFrameSession()
        var length = UInt32(65_537).bigEndian
        let oversizedHeader = withUnsafeBytes(of: &length) { Data($0) }
        XCTAssertThrowsError(try oversized.ingest(oversizedHeader, now: 10))
    }

    func testFrameSessionRejectsMalformedInput() throws {
        var malformed = HelperFrameSession()
        var malformedFrame = Data([0, 0, 0, 1])
        malformedFrame.append(UInt8(ascii: "x"))
        XCTAssertThrowsError(try malformed.ingest(malformedFrame, now: 10))
    }

    func testFrameSessionRejectsRateLimitedInput() throws {
        var rateLimited = HelperFrameSession()
        let frame = try FrameEncoder.encode(HelperRequest.status)
        let burst = (0..<11).reduce(into: Data()) { data, _ in data.append(frame) }
        XCTAssertThrowsError(try rateLimited.ingest(burst, now: 10))
    }

    func testClientLimiterAllowsAtMostEightConcurrentClients() async {
        let limiter = HelperClientLimiter(maximumClients: 8)
        var accepted: [Bool] = []
        for _ in 0..<9 {
            accepted.append(await limiter.acquire())
        }

        XCTAssertEqual(accepted, Array(repeating: true, count: 8) + [false])
        await limiter.release()
        let acceptedAfterRelease = await limiter.acquire()
        XCTAssertTrue(acceptedAfterRelease)
    }

    func testOnlyConfiguredUIDCanReachClosedHelperRequestProtocol() async throws {
        let listener = FakeHelperListener()
        let handler = FakeHelperRequestHandler()
        let server = HelperServer(handler: handler, allowedUID: 501, listener: listener)
        try await server.start()

        let unauthorized = try await listener.send(.cut, peerUID: 502)
        _ = try await listener.send(.status, peerUID: 501)
        _ = try await listener.send(.cut, peerUID: 501)
        _ = try await listener.send(.restore, peerUID: 501)

        guard case let .rejected(code, _, _) = unauthorized else {
            return XCTFail("Expected unauthorized response")
        }
        let requests = await handler.requests()
        XCTAssertEqual(code, "unauthorized")
        XCTAssertEqual(requests, [.status, .cut, .restore])
    }
}

private actor FakeHelperListener: HelperListening {
    private var handler: HelperPeerRequestHandler?

    func start(handler: @escaping HelperPeerRequestHandler) async throws {
        self.handler = handler
    }

    func stop() async {
        handler = nil
    }

    func send(_ request: HelperRequest, peerUID: uid_t) async throws -> HelperResponse {
        guard let handler else { throw FakeHelperServerError.notStarted }
        return await handler(request, peerUID)
    }
}

private actor FakeHelperRequestHandler: HelperRequestHandling {
    private var received: [HelperRequest] = []
    private let snapshot = PullerSnapshot(
        state: .ready,
        connectionCount: 1,
        remainingMilliseconds: 0
    )

    func handle(_ request: HelperRequest) async -> HelperResponse {
        received.append(request)
        return .status(snapshot)
    }

    func requests() -> [HelperRequest] {
        received
    }
}

private enum FakeHelperServerError: Error {
    case notStarted
}
