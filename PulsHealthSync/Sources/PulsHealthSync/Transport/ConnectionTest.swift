import Foundation

/// Outcome of testing a server URL + token before they are saved.
public enum ConnectionTestResult: Sendable, Equatable {
    /// `GET /v1/capabilities` answered and accepts this client's protocol version.
    case ok(ServerCapabilities)
    /// No capabilities endpoint (404/405 or an unparseable body), but the
    /// header-only probe batch was accepted. Feature-gated UI stays hidden.
    case okNoCapabilities
    /// HTTP 401: the server is reachable but rejects the bearer token.
    case tokenRejected
    /// HTTP 403: the token is valid but bound to a different user than the
    /// `X-User-ID` this app sent (a per-device ingest token; the shared
    /// token is bound to nobody). Retyping the token does not help; the user
    /// ID has to be the one the token was issued for.
    case userMismatch(userID: String)
    /// The server does not speak `PulsProtocol.version`.
    case unsupportedProtocol(supportedVersions: [Int])
    /// DNS, TLS, timeout, refused connection, ATS block, no network.
    case unreachable(String)
    /// Any other non-2xx status.
    case serverError(status: Int)

    public var isSuccess: Bool {
        switch self {
        case .ok, .okNoCapabilities: return true
        default: return false
        }
    }

    /// User-facing one-liner.
    public var message: String {
        switch self {
        case .ok(let capabilities):
            let name = capabilities.displayName
            return name.isEmpty ? "Connected." : "Connected to \(name)."
        case .okNoCapabilities:
            return "Connected. This database does not advertise capabilities, so reconciliation and database statistics are unavailable."
        case .tokenRejected:
            return "The database rejected the token."
        case .userMismatch(let userID):
            return "The token is bound to a different user ID than this app's (\(userID)). "
                + "Use the user ID the token was issued for — the pairing code carries it, or set it under Settings → User."
        case .unsupportedProtocol(let versions):
            let list = versions.isEmpty ? "none" : versions.map(String.init).joined(separator: ", ")
            return "This database does not support this app version (it speaks protocol \(list); this app speaks \(PulsProtocol.version))."
        case .unreachable(let detail):
            return "Could not reach the database: \(detail)"
        case .serverError(let status):
            return "The database returned HTTP \(status)."
        }
    }
}

/// Tests a server URL + token without saving them: `GET /v1/capabilities`
/// first, falling back to a header-only probe batch for receivers that do not
/// implement the endpoint. Nothing is persisted; the caller decides what to do
/// with the result.
public struct ConnectionTester: Sendable {
    public var baseURL: URL
    public var authToken: String
    public var userID: String
    /// `deviceID` of the probe batch — the install's stable ID when available,
    /// so a server that records batches attributes the probe correctly.
    public var deviceID: String
    private let session: URLSession

    public init(
        baseURL: URL, authToken: String, userID: String = PulsDefaultUser.id,
        deviceID: String = "connection-test", session: URLSession? = nil
    ) {
        self.baseURL = baseURL
        self.authToken = authToken
        self.userID = userID
        self.deviceID = deviceID
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            // A test should answer promptly; the sync transport's 60 s is for uploads.
            config.timeoutIntervalForRequest = 20
            config.waitsForConnectivity = false
            self.session = URLSession(configuration: config)
        }
    }

    public func run() async -> ConnectionTestResult {
        let client = ServerAPIClient(
            baseURL: baseURL, authToken: authToken, userID: userID, session: session)
        do {
            let capabilities = try await client.capabilities()
            guard capabilities.acceptsClientProtocol else {
                return .unsupportedProtocol(supportedVersions: capabilities.protocolVersions)
            }
            return .ok(capabilities)
        } catch {
            if let result = Self.result(for: error, userID: userID, missingEndpointIsFatal: false) {
                return result
            }
            // 404/405 or a body that is not capabilities JSON: fall through to the probe.
        }

        // No retries: a test should report the first answer, not mask a flaky
        // server behind the upload transport's backoff ladder.
        let transport = HTTPSyncTransport(
            baseURL: baseURL, authToken: authToken, userID: userID, maxRetries: 0, session: session)
        do {
            _ = try await transport.probe(deviceID: deviceID)
            return .okNoCapabilities
        } catch {
            return Self.result(for: error, userID: userID, missingEndpointIsFatal: true)
                ?? .unreachable(error.localizedDescription)
        }
    }

    /// Maps a transport failure to a result. Returns nil for "no such
    /// endpoint" (404/405, or a 2xx whose body is not the expected JSON) when
    /// the caller can fall back to the probe.
    ///
    /// 401 and 403 are told apart: the ingest answers 401 to a token it does
    /// not know and 403 (`X-User-ID does not match the token's user`) to a
    /// known device token presented with another user's ID, before reading
    /// the body — so the two are fixed in different places.
    static func result(for error: Error, userID: String, missingEndpointIsFatal: Bool) -> ConnectionTestResult? {
        switch error {
        case TransportError.unsupportedProtocol(let versions):
            return .unsupportedProtocol(supportedVersions: versions)
        case TransportError.serverError(let status, _):
            switch status {
            case 401:
                return .tokenRejected
            case 403:
                return .userMismatch(userID: userID)
            case 404, 405:
                return missingEndpointIsFatal ? .serverError(status: status) : nil
            default:
                return .serverError(status: status)
            }
        case TransportError.network(let underlying):
            return .unreachable(describe(underlying))
        case TransportError.notConfigured:
            return .unreachable("Database URL or token missing.")
        case is DecodingError:
            return missingEndpointIsFatal ? .unreachable("Unexpected response body.") : nil
        case is CancellationError:
            return .unreachable("Cancelled.")
        default:
            return .unreachable(describe(error))
        }
    }

    /// Distinguishes the failures a person can act on: TLS, DNS, timeouts,
    /// refused connections, an ATS block, no network.
    static func describe(_ error: Error) -> String {
        guard let urlError = error as? URLError else { return error.localizedDescription }
        let host = urlError.failingURL?.host ?? "the database"
        switch urlError.code {
        case .appTransportSecurityRequiresSecureConnection:
            return "App Transport Security blocks plain http:// to \(host). Use https://, or a local-network host."
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
             .clientCertificateRejected, .clientCertificateRequired:
            return "TLS handshake with \(host) failed (\(urlError.localizedDescription))."
        case .cannotFindHost, .dnsLookupFailed:
            return "DNS could not resolve \(host)."
        case .timedOut:
            return "Timed out waiting for \(host)."
        case .cannotConnectToHost:
            return "\(host) refused the connection (is your database running on that port?)."
        case .notConnectedToInternet, .networkConnectionLost, .internationalRoamingOff, .dataNotAllowed:
            return "No network connection."
        case .badServerResponse:
            return "\(host) sent a response that is not HTTP."
        default:
            return urlError.localizedDescription
        }
    }
}
