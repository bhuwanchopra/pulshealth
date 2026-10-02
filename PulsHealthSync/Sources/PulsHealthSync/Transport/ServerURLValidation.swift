import Foundation

/// Validates a server URL the user typed before it is saved or tested.
///
/// The rules mirror App Transport Security: `https` everywhere, with plain
/// `http` accepted only for hosts on the local network — `localhost`, `*.local`,
/// and the private/link-local IP ranges — which is exactly what the app's
/// `NSAllowsLocalNetworking` ATS exception permits. Anything else over `http`
/// would be refused by ATS at connection time, so it is refused here with an
/// explanation instead.
public enum ServerURLValidation {
    public enum Failure: Error, Equatable, LocalizedError, Sendable {
        case empty
        case malformed
        /// No `scheme://` prefix at all (e.g. `myhost:8080`).
        case missingScheme
        case unsupportedScheme(String)
        case missingHost
        /// `http://` to a host that is not on the local network.
        case insecureRemoteHost(String)

        public var errorDescription: String? {
            switch self {
            case .empty:
                return "Enter the database URL."
            case .malformed:
                return "That is not a valid URL."
            case .missingScheme:
                return "Start the URL with https:// (or http:// for a local-network host)."
            case .unsupportedScheme(let scheme):
                return "Unsupported scheme \(scheme)://. Use https:// (or http:// for a local-network host)."
            case .missingHost:
                return "The URL has no host name."
            case .insecureRemoteHost(let host):
                return "Plain http:// is only allowed for local-network hosts (localhost, *.local, 10.x, 172.16–31.x, 192.168.x, 169.254.x). Use https:// for \(host)."
            }
        }
    }

    /// Parses and checks `text`. On success the URL has any trailing slash
    /// removed so `appendingPathComponent("v1/…")` produces a single slash.
    public static func validate(_ text: String) -> Result<URL, Failure> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        guard trimmed.contains("://") else { return .failure(.missingScheme) }
        guard let components = URLComponents(string: trimmed) else { return .failure(.malformed) }
        guard let scheme = components.scheme?.lowercased() else { return .failure(.missingScheme) }
        guard scheme == "http" || scheme == "https" else { return .failure(.unsupportedScheme(scheme)) }
        guard let host = components.host, !host.isEmpty else { return .failure(.missingHost) }
        if scheme == "http", !isLocalNetworkHost(host) {
            return .failure(.insecureRemoteHost(host))
        }
        var normalized = components
        while normalized.path.hasSuffix("/") { normalized.path.removeLast() }
        guard let url = normalized.url else { return .failure(.malformed) }
        return .success(url)
    }

    /// Whether `host` is on the local network and therefore reachable over
    /// plain `http` under `NSAllowsLocalNetworking`: `localhost`, `*.local`,
    /// loopback, RFC 1918 (10/8, 172.16/12, 192.168/16), link-local
    /// (169.254/16), and their IPv6 counterparts (`::1`, `fe80::/10`, `fc00::/7`).
    public static func isLocalNetworkHost(_ host: String) -> Bool {
        var name = host.lowercased()
        if name.hasPrefix("["), name.hasSuffix("]") {
            name = String(name.dropFirst().dropLast())
        }
        while name.hasSuffix(".") { name.removeLast() }
        if name == "localhost" || name.hasSuffix(".localhost") || name.hasSuffix(".local") {
            return true
        }
        if let octets = ipv4Octets(name) {
            switch (octets[0], octets[1]) {
            case (10, _), (127, _), (192, 168), (169, 254):
                return true
            case (172, 16...31):
                return true
            default:
                return false
            }
        }
        if name.contains(":") {
            // IPv6: strip a zone index (fe80::1%en0) before classifying.
            let address = name.split(separator: "%", maxSplits: 1).first.map(String.init) ?? name
            if address == "::1" { return true }
            if address.hasPrefix("fe8") || address.hasPrefix("fe9")
                || address.hasPrefix("fea") || address.hasPrefix("feb") {
                return true
            }
            if address.hasPrefix("fc") || address.hasPrefix("fd") { return true }
        }
        return false
    }

    private static func ipv4Octets(_ name: String) -> [Int]? {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isNumber), let value = Int(part), (0...255).contains(value) else {
                return nil
            }
            octets.append(value)
        }
        return octets
    }
}
