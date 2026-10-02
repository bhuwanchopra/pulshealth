import Foundation

/// The receiver that the persisted sync progress belongs to. Anchors and
/// watermarks record how far *one* server has been brought up to date under
/// *one* user; pointing the app at a different server (or a different user ID,
/// which the server treats as a different person) with those anchors intact
/// would silently deliver only data newer than the old high-water mark.
/// `SyncStateStore` records the identity the progress was earned against and
/// `serverIdentityChange(applying:)` reports when a configuration would move it.
///
/// Normalized so cosmetic URL edits are not changes: the host is lowercased, a
/// default port (`443` for https, `80` for http) reads the same as no port, and
/// trailing slashes on the path are dropped. The scheme is deliberately not
/// part of the identity — switching a host from http to https is the same
/// server.
public struct ServerIdentity: Codable, Sendable, Equatable, Hashable {
    public var host: String
    public var port: Int?
    public var path: String
    public var userID: String

    public init(host: String, port: Int?, path: String, userID: String) {
        self.host = host
        self.port = port
        self.path = path
        self.userID = userID
    }

    /// Nil when the configuration has no server URL (or one without a host).
    public init?(configuration: SyncConfiguration) {
        guard let url = configuration.serverURL else { return nil }
        self.init(url: url, userID: configuration.userID)
    }

    public init?(url: URL, userID: String) {
        guard let rawHost = url.host, !rawHost.isEmpty else { return nil }
        host = rawHost.lowercased()
        let scheme = url.scheme?.lowercased()
        switch (url.port, scheme) {
        case (443, "https"), (80, "http"):
            port = nil
        default:
            port = url.port
        }
        var trimmed = url.path
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        path = trimmed
        self.userID = userID.lowercased()
    }

    /// `host[:port][/path]`, for logs and prompts.
    public var serverLabel: String {
        host + (port.map { ":\($0)" } ?? "") + path
    }
}

/// A configuration whose server identity differs from the one the stored
/// progress was earned against.
public struct ServerIdentityChange: Sendable, Equatable {
    public var from: ServerIdentity
    public var to: ServerIdentity

    public init(from: ServerIdentity, to: ServerIdentity) {
        self.from = from
        self.to = to
    }

    public var serverChanged: Bool {
        from.host != to.host || from.port != to.port || from.path != to.path
    }

    public var userChanged: Bool { from.userID != to.userID }

    /// One line describing what moved, e.g. "database host:8080 → other:8080".
    /// Shown in the app's change prompt, so it says "database", the word
    /// the app uses for where data goes.
    public var summary: String {
        var parts: [String] = []
        if serverChanged {
            parts.append("database \(from.serverLabel) → \(to.serverLabel)")
        }
        if userChanged {
            parts.append("user ID \(from.userID) → \(to.userID)")
        }
        return parts.joined(separator: "; ")
    }
}
