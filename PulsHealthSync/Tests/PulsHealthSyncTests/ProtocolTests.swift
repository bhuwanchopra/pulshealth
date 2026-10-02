import Foundation
import Testing
@testable import PulsHealthSync

// MARK: - Protocol version

@Suite struct ProtocolVersionTests {
    @Test func clientVersionFormatsMarketingAndBuild() {
        #expect(PulsProtocol.clientVersion(marketing: "0.1.0", build: "7") == "0.1.0 (7)")
        #expect(PulsProtocol.clientVersion(marketing: " 0.1.0 ", build: "") == "0.1.0")
        #expect(PulsProtocol.clientVersion(marketing: nil, build: "7") == "(7)")
        #expect(PulsProtocol.clientVersion(marketing: nil, build: nil) == "unknown")
        #expect(!PulsProtocol.clientVersion.isEmpty)
    }

    @Test func uploadRequestsCarryProtocolVersionAndIdentity() throws {
        let transport = HTTPSyncTransport(
            baseURL: URL(string: "https://example.test/")!, authToken: "secret", userID: "user-1")
        let batch = SyncBatch(deviceID: "d", type: "t", reason: .incremental, samples: [], deletions: [])
        let request = transport.makeRequest(for: batch, body: Data([0x1F, 0x8B]))
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/v1/batches")
        #expect(request.value(forHTTPHeaderField: "X-Puls-Protocol") == String(PulsProtocol.version))
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        #expect(request.value(forHTTPHeaderField: "X-User-ID") == "user-1")
        #expect(request.value(forHTTPHeaderField: "X-Batch-ID") == batch.batchID.uuidString)
        #expect(request.value(forHTTPHeaderField: "Content-Encoding") == "gzip")
        #expect(request.value(forHTTPHeaderField: "X-Wake-ID") == nil)
    }

    @Test func protocolRejectionBodyBecomesDistinctError() {
        let rejection = Data(#"{"error":"unsupported protocol version","supportedVersions":[2,3]}"#.utf8)
        guard case .unsupportedProtocol(let versions) = TransportError.fromResponse(status: 400, body: rejection) else {
            Issue.record("expected unsupportedProtocol"); return
        }
        #expect(versions == [2, 3])

        // Same body on a different status is not a protocol rejection.
        guard case .serverError(let status, _) = TransportError.fromResponse(status: 422, body: rejection) else {
            Issue.record("expected serverError"); return
        }
        #expect(status == 422)

        // Any other 400 stays a plain server error, body preserved for the log.
        guard case .serverError(400, let body) = TransportError.fromResponse(
            status: 400, body: Data(#"{"error":"invalid batch header: missing type"}"#.utf8)) else {
            Issue.record("expected serverError"); return
        }
        #expect(body.contains("missing type"))

        // A rejection without the version list still classifies (empty list).
        guard case .unsupportedProtocol(let none) = TransportError.fromResponse(
            status: 400, body: Data(#"{"error":"unsupported protocol version"}"#.utf8)) else {
            Issue.record("expected unsupportedProtocol"); return
        }
        #expect(none.isEmpty)
        #expect(TransportError.unsupportedProtocol(supportedVersions: [2]).errorDescription?
            .contains("does not support this app version") == true)
    }
}

// MARK: - Ingest receipt (PROTO-8)

/// The success body is optional and informational: the app reads the counts
/// when they are there and is indifferent to anything else. A body it cannot
/// read must look exactly like no body, and must never fail the upload.
@Suite struct IngestReceiptTests {
    @Test func referenceServerBodyDecodes() {
        let body = Data(#"{"accepted":812,"deleted":0,"duplicates":188,"routePoints":0,"seriesPoints":0,"aggregateSamples":0,"activitySummaries":0}"#.utf8)
        let receipt = IngestReceipt.decode(body)
        #expect(receipt?.accepted == 812)
        #expect(receipt?.duplicates == 188)
        #expect(receipt?.deleted == 0)
        #expect(receipt?.aggregateSamples == 0)
        #expect(receipt?.sampleOutcome == "812 new, 188 duplicates")
    }

    @Test func partialAndUnknownFieldsAreTolerated() {
        // A receiver that reports only some counts, plus fields the client
        // has never heard of: every known one it sent is kept.
        let body = Data(#"{"accepted":5,"retries":1,"server":"other","nested":{"x":[1,2]}}"#.utf8)
        let receipt = IngestReceipt.decode(body)
        #expect(receipt == IngestReceipt(accepted: 5))
        #expect(receipt?.duplicates == nil)
        #expect(receipt?.sampleOutcome == "5 new")
        #expect(IngestReceipt.decode(Data(#"{"duplicates":3}"#.utf8))?.sampleOutcome == "3 duplicates")
    }

    @Test func absentOrUnreadableBodyIsNoReceipt() {
        #expect(IngestReceipt.decode(Data()) == nil)
        #expect(IngestReceipt.decode(Data("{}".utf8)) == nil, "no known count")
        #expect(IngestReceipt.decode(Data(#"{"ok":true}"#.utf8)) == nil, "only unknown fields")
        #expect(IngestReceipt.decode(Data("not json".utf8)) == nil)
        #expect(IngestReceipt.decode(Data("<html><body>502</body></html>".utf8)) == nil)
        #expect(IngestReceipt.decode(Data("[1,2,3]".utf8)) == nil, "not an object")
        #expect(IngestReceipt.decode(Data(#"{"accepted":"lots"}"#.utf8)) == nil, "wrong type")
        #expect(IngestReceipt.decode(Data([0xFF, 0xFE, 0x00])) == nil, "not UTF-8")
    }

    @Test func largeCountsFormatWithGrouping() {
        let receipt = IngestReceipt(accepted: 1_000_000, duplicates: 12_345)
        let outcome = receipt.sampleOutcome ?? ""
        // Locale-dependent separator, but a six-digit count must be grouped.
        #expect(outcome.hasSuffix(" duplicates"))
        #expect(outcome.contains(" new, "))
        #expect(outcome.count > "1000000 new, 12345 duplicates".count)
    }

    // MARK: End to end through HTTPSyncTransport

    private func makeTransport(_ handler: @escaping MockURLProtocol.Handler) -> HTTPSyncTransport {
        let host = "\(UUID().uuidString.lowercased()).test"
        MockURLProtocol.register(host: host, handler)
        return HTTPSyncTransport(
            baseURL: URL(string: "https://\(host)")!, authToken: "secret", userID: "user-1",
            maxRetries: 0, session: MockURLProtocol.session())
    }

    private var batch: SyncBatch {
        SyncBatch(deviceID: "d", type: "t", reason: .incremental, samples: [], deletions: [])
    }

    @Test func uploadCarriesTheServerCounts() async throws {
        let transport = makeTransport { _ in
            .http(200, Data(#"{"accepted":812,"duplicates":188,"deleted":1}"#.utf8))
        }
        let result = try await transport.upload(batch)
        #expect(result.bytesSent > 0)
        #expect(result.receipt?.accepted == 812)
        #expect(result.receipt?.duplicates == 188)
        #expect(result.receipt?.deleted == 1)
    }

    @Test func emptyBodyStillAcks() async throws {
        let transport = makeTransport { _ in .http(202, Data()) }
        let result = try await transport.upload(batch)
        #expect(result.bytesSent > 0)
        #expect(result.receipt == nil)
    }

    @Test func unreadableBodyStillAcks() async throws {
        // A proxy that answers 200 with a page of its own, or a receiver
        // with a body of a different shape: the 2xx is the ack.
        for body in ["<html>ok</html>", #"{"status":"stored"}"#, "\u{0}\u{1}garbage"] {
            let transport = makeTransport { _ in .http(200, Data(body.utf8)) }
            let result = try await transport.upload(batch)
            #expect(result.receipt == nil, "body \(body)")
        }
    }
}

// MARK: - Capabilities

@Suite struct ServerCapabilitiesTests {
    @Test func decodesReferenceServerResponse() throws {
        let json = Data("""
        {"protocolVersions":[1],"features":["batches","stats","digest","uuids","aggregates",
        "activitySummaries","routes","series","profile"],"server":"puls-ingest","version":"0.4.0"}
        """.utf8)
        let caps = try JSONDecoder().decode(ServerCapabilities.self, from: json)
        #expect(caps.protocolVersions == [1])
        #expect(caps.acceptsClientProtocol)
        #expect(caps.supportsReconciliation)
        #expect(caps.supportsStats)
        #expect(caps.supports(ServerCapabilities.Feature.aggregates))
        #expect(caps.displayName == "puls-ingest 0.4.0")
    }

    @Test func decodesMinimalThirdPartyResponse() throws {
        let caps = try JSONDecoder().decode(
            ServerCapabilities.self, from: Data(#"{"protocolVersions":[1,2]}"#.utf8))
        #expect(caps.features.isEmpty)
        #expect(!caps.supportsReconciliation)
        #expect(!caps.supportsStats)
        #expect(caps.displayName.isEmpty)
        #expect(caps.acceptsClientProtocol)

        // Digest without uuids is not enough for reconciliation.
        let partial = ServerCapabilities(protocolVersions: [1], features: ["digest", "stats"])
        #expect(!partial.supportsReconciliation)
        #expect(partial.supportsStats)
    }

    @Test func roundTripsThroughCodable() throws {
        let caps = ServerCapabilities(protocolVersions: [1], features: ["stats", "digest"], server: "x", version: "1")
        let data = try JSONEncoder().encode(caps)
        #expect(try JSONDecoder().decode(ServerCapabilities.self, from: data) == caps)
    }
}

// MARK: - URL validation

@Suite struct ServerURLValidationTests {
    private func url(_ text: String) -> URL? {
        if case .success(let url) = ServerURLValidation.validate(text) { return url }
        return nil
    }

    private func failure(_ text: String) -> ServerURLValidation.Failure? {
        if case .failure(let failure) = ServerURLValidation.validate(text) { return failure }
        return nil
    }

    @Test func httpsIsAcceptedAnywhere() {
        #expect(url("https://health.example.com")?.absoluteString == "https://health.example.com")
        #expect(url("https://203.0.113.5:8443")?.absoluteString == "https://203.0.113.5:8443")
        #expect(url("  https://health.example.com/  ")?.absoluteString == "https://health.example.com")
        #expect(url("HTTPS://Health.Example.com:8080/")?.host?.lowercased() == "health.example.com")
    }

    @Test func httpIsAcceptedOnlyForLocalNetworkHosts() {
        for ok in [
            "http://localhost:8080", "http://LOCALHOST", "http://127.0.0.1:8080",
            "http://nas.local:8080", "http://puls.home.local", "http://10.0.0.5:8080",
            "http://172.16.0.1", "http://172.31.255.255", "http://192.168.1.10:8080",
            "http://169.254.10.1", "http://[::1]:8080", "http://[fe80::1%25en0]:8080", "http://[fd12::1]",
        ] {
            #expect(url(ok) != nil, "\(ok) should be accepted")
        }
        for bad in [
            "http://health.example.com", "http://203.0.113.5:8080", "http://172.32.0.1",
            "http://172.15.0.1", "http://11.0.0.1", "http://192.169.0.1", "http://[2001:db8::1]",
            "http://mylocal.example", "http://localhost.example.com",
        ] {
            guard case .insecureRemoteHost = failure(bad) else {
                Issue.record("\(bad) should require https"); continue
            }
        }
    }

    @Test func structuralFailuresAreExplained() {
        #expect(failure("") == .empty)
        #expect(failure("   ") == .empty)
        #expect(failure("myhost:8080") == .missingScheme)
        #expect(failure("192.168.1.5") == .missingScheme)
        #expect(failure("ftp://host") == .unsupportedScheme("ftp"))
        #expect(failure("https://") == .missingHost)
        #expect(failure("https:///path") == .missingHost)
        #expect(failure("https://exa mple.com") != nil)
        #expect(ServerURLValidation.Failure.insecureRemoteHost("h").errorDescription?.contains("https://") == true)
    }

    @Test func localNetworkClassification() {
        #expect(ServerURLValidation.isLocalNetworkHost("localhost"))
        #expect(ServerURLValidation.isLocalNetworkHost("Printer.local."))
        #expect(ServerURLValidation.isLocalNetworkHost("10.255.255.255"))
        #expect(ServerURLValidation.isLocalNetworkHost("172.20.1.1"))
        #expect(!ServerURLValidation.isLocalNetworkHost("172.20.1"))
        #expect(!ServerURLValidation.isLocalNetworkHost("10.0.0.256"))
        #expect(!ServerURLValidation.isLocalNetworkHost("example.local.com"))
        #expect(!ServerURLValidation.isLocalNetworkHost("8.8.8.8"))
    }
}

// MARK: - Connection test

/// In-process HTTP stand-in keyed by host, so suites can run in parallel with
/// one handler per test (`https://<uuid>.test`).
final class MockURLProtocol: URLProtocol {
    enum Reply: Sendable {
        case http(Int, Data)
        case failure(URLError.Code)
    }
    struct Recorded: Sendable {
        var request: URLRequest
        var body: Data
    }
    typealias Handler = @Sendable (Recorded) -> Reply

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]

    static func register(host: String, _ handler: @escaping Handler) {
        lock.withLock { handlers[host] = handler }
    }

    private static func handler(for host: String?) -> Handler? {
        lock.withLock { host.flatMap { handlers[$0] } }
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler(for: request.url?.host) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        switch handler(Recorded(request: request, body: Self.body(of: request))) {
        case .http(let status, let data):
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(
                code, userInfo: [NSURLErrorFailingURLErrorKey: request.url as Any]))
        }
    }

    override func stopLoading() {}

    /// URLSession hands a URLProtocol the body as a stream, not `httpBody`.
    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let n = stream.read(buffer, maxLength: 4096)
            guard n > 0 else { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

/// Thread-safe request log a handler appends to.
final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [MockURLProtocol.Recorded] = []
    func append(_ item: MockURLProtocol.Recorded) { lock.withLock { recorded.append(item) } }
    var all: [MockURLProtocol.Recorded] { lock.withLock { recorded } }
}

@Suite struct ConnectionTesterTests {
    private static let capabilitiesJSON = Data(
        #"{"protocolVersions":[1],"features":["batches","stats","digest","uuids"],"server":"puls-ingest","version":"0.4.0"}"#.utf8)

    private func makeTester(
        token: String = "secret", handler: @escaping MockURLProtocol.Handler
    ) -> (ConnectionTester, String) {
        let host = "\(UUID().uuidString.lowercased()).test"
        MockURLProtocol.register(host: host, handler)
        let tester = ConnectionTester(
            baseURL: URL(string: "https://\(host)")!, authToken: token,
            userID: "user-1", deviceID: "device-1", session: MockURLProtocol.session())
        return (tester, host)
    }

    @Test func capabilitiesEndpointYieldsOk() async {
        let recorder = RequestRecorder()
        let (tester, _) = makeTester { recorded in
            recorder.append(recorded)
            return .http(200, Self.capabilitiesJSON)
        }
        let result = await tester.run()
        guard case .ok(let caps) = result else { Issue.record("expected ok, got \(result)"); return }
        #expect(caps.server == "puls-ingest")
        #expect(caps.supportsReconciliation)
        #expect(result.isSuccess)
        #expect(result.message == "Connected to puls-ingest 0.4.0.")

        let requests = recorder.all
        #expect(requests.count == 1, "no probe when capabilities answered")
        #expect(requests.first?.request.url?.path == "/v1/capabilities")
        #expect(requests.first?.request.httpMethod == "GET")
        #expect(requests.first?.request.value(forHTTPHeaderField: "X-Puls-Protocol") == "1")
        #expect(requests.first?.request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        #expect(requests.first?.request.value(forHTTPHeaderField: "X-User-ID") == "user-1")
    }

    @Test func missingCapabilitiesFallsBackToHeaderOnlyProbe() async throws {
        let recorder = RequestRecorder()
        let (tester, _) = makeTester { recorded in
            recorder.append(recorded)
            switch recorded.request.url?.path {
            case "/v1/capabilities": return .http(404, Data("not found".utf8))
            case "/v1/batches": return .http(202, Data())
            default: return .http(500, Data())
            }
        }
        let result = await tester.run()
        #expect(result == .okNoCapabilities)
        #expect(result.isSuccess)

        let requests = recorder.all
        #expect(requests.count == 2)
        let probe = try #require(requests.last)
        #expect(probe.request.httpMethod == "POST")
        #expect(probe.request.value(forHTTPHeaderField: "X-Puls-Protocol") == "1")
        #expect(probe.request.value(forHTTPHeaderField: "Content-Encoding") == "gzip")
        #expect(probe.request.value(forHTTPHeaderField: "X-User-ID") == "user-1")

        // gzip framing: 10-byte header, raw DEFLATE, 8-byte trailer.
        #expect(probe.body.count > 18)
        #expect(probe.body[0] == 0x1F && probe.body[1] == 0x8B)
        let deflated = probe.body.subdata(in: 10..<(probe.body.count - 8))
        let ndjson = try (deflated as NSData).decompressed(using: .zlib) as Data
        let lines = String(decoding: ndjson, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 1, "header only")
        let header = try JSONDecoder.puls.decode(BatchSerializer.Header.self, from: Data(lines[0].utf8))
        #expect(header.schemaVersion == 1)
        #expect(header.type == PulsProtocol.probeBatchType)
        #expect(header.reason == .manual)
        #expect(header.deviceID == "device-1")
        #expect(header.sampleCount == 0 && header.deletionCount == 0 && header.routeCount == 0
            && header.aggregateCount == 0 && header.seriesCount == 0
            && header.activitySummaryCount == 0 && header.profileCount == 0)
    }

    @Test func methodNotAllowedAlsoFallsBack() async {
        let (tester, _) = makeTester { recorded in
            recorded.request.url?.path == "/v1/capabilities" ? .http(405, Data()) : .http(200, Data())
        }
        #expect(await tester.run() == .okNoCapabilities)
    }

    @Test func nonJSONCapabilitiesBodyFallsBack() async {
        // A receiver that answers every path with 200 HTML.
        let (tester, _) = makeTester { recorded in
            recorded.request.url?.path == "/v1/capabilities"
                ? .http(200, Data("<html>ok</html>".utf8)) : .http(200, Data())
        }
        #expect(await tester.run() == .okNoCapabilities)
    }

    @Test func rejectedTokenStopsBeforeProbe() async {
        let recorder = RequestRecorder()
        let (tester, _) = makeTester { recorded in
            recorder.append(recorded)
            return .http(401, Data(#"{"error":"unauthorized"}"#.utf8))
        }
        #expect(await tester.run() == .tokenRejected)
        #expect(recorder.all.count == 1)
        #expect(ConnectionTestResult.tokenRejected.message.contains("rejected the token"))
    }

    @Test func forbiddenIsAUserMismatchNotARejectedToken() async {
        // The ingest's 403: a device token bound to another user than the
        // X-User-ID sent. The token itself is fine, so the message must name
        // the user ID, not the token, and the probe is not attempted.
        let recorder = RequestRecorder()
        let (forbidden, _) = makeTester { recorded in
            recorder.append(recorded)
            return .http(403, Data("X-User-ID does not match the token's user".utf8))
        }
        let result = await forbidden.run()
        #expect(result == .userMismatch(userID: "user-1"))
        #expect(result != .tokenRejected)
        #expect(!result.isSuccess)
        #expect(recorder.all.count == 1)
        #expect(result.message.contains("different user ID"))
        #expect(result.message.contains("user-1"))
        #expect(result.message.contains("Settings → User"))

        // The same on the probe, for a receiver without capabilities.
        let (onProbe, _) = makeTester { recorded in
            recorded.request.url?.path == "/v1/capabilities" ? .http(404, Data()) : .http(403, Data())
        }
        #expect(await onProbe.run() == .userMismatch(userID: "user-1"))
    }

    @Test func unsupportedProtocolIsReportedWithServerVersions() async {
        // Rejected outright by the version gate.
        let (rejected, _) = makeTester { _ in
            .http(400, Data(#"{"error":"unsupported protocol version","supportedVersions":[2]}"#.utf8))
        }
        #expect(await rejected.run() == .unsupportedProtocol(supportedVersions: [2]))

        // Capabilities answered, but without this client's version in the list.
        let (mismatch, _) = makeTester { _ in
            .http(200, Data(#"{"protocolVersions":[2,3],"features":["batches"]}"#.utf8))
        }
        let result = await mismatch.run()
        #expect(result == .unsupportedProtocol(supportedVersions: [2, 3]))
        #expect(!result.isSuccess)
        #expect(result.message.contains("does not support this app version"))
    }

    @Test func probeFailuresAreServerErrors() async {
        let (tester, _) = makeTester { recorded in
            recorded.request.url?.path == "/v1/capabilities" ? .http(404, Data()) : .http(500, Data("boom".utf8))
        }
        #expect(await tester.run() == .serverError(status: 500))

        // 404 on the probe itself is fatal: there is nothing left to fall back to.
        let (missing, _) = makeTester { _ in .http(404, Data()) }
        #expect(await missing.run() == .serverError(status: 404))

        let (rejectedProbe, _) = makeTester { recorded in
            recorded.request.url?.path == "/v1/capabilities" ? .http(404, Data()) : .http(401, Data())
        }
        #expect(await rejectedProbe.run() == .tokenRejected)
    }

    @Test func networkFailuresAreUnreachableWithACause() async {
        let (refused, host) = makeTester { _ in .failure(.cannotConnectToHost) }
        guard case .unreachable(let detail) = await refused.run() else {
            Issue.record("expected unreachable"); return
        }
        #expect(detail.contains("refused"))
        #expect(detail.contains(host))

        let (tls, _) = makeTester { _ in .failure(.serverCertificateUntrusted) }
        guard case .unreachable(let tlsDetail) = await tls.run() else {
            Issue.record("expected unreachable"); return
        }
        #expect(tlsDetail.contains("TLS"))

        let (dns, _) = makeTester { _ in .failure(.cannotFindHost) }
        guard case .unreachable(let dnsDetail) = await dns.run() else {
            Issue.record("expected unreachable"); return
        }
        #expect(dnsDetail.contains("DNS"))

        let (ats, _) = makeTester { _ in .failure(.appTransportSecurityRequiresSecureConnection) }
        guard case .unreachable(let atsDetail) = await ats.run() else {
            Issue.record("expected unreachable"); return
        }
        #expect(atsDetail.contains("App Transport Security"))

        let (timeout, _) = makeTester { _ in .failure(.timedOut) }
        guard case .unreachable(let timeoutDetail) = await timeout.run() else {
            Issue.record("expected unreachable"); return
        }
        #expect(timeoutDetail.contains("Timed out"))
    }

    @Test func probeDoesNotRetry() async {
        // maxRetries 0 inside the tester: a 503 must come back at once, not
        // after the upload transport's backoff ladder.
        let recorder = RequestRecorder()
        let (tester, _) = makeTester { recorded in
            recorder.append(recorded)
            return recorded.request.url?.path == "/v1/capabilities" ? .http(404, Data()) : .http(503, Data())
        }
        #expect(await tester.run() == .serverError(status: 503))
        // Two requests — the capabilities probe and one upload attempt — is the
        // whole claim: a retry would show up here as a third. Wall-clock timing
        // used to stand in for that and failed on a loaded CI machine, which
        // says nothing about whether the code retried.
        #expect(recorder.all.count == 2)
    }
}
