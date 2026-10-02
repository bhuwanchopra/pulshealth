import Foundation

/// The server fields as they sit on screen — URL text, token text, and the user
/// ID a pairing code brought with it — before any of it reaches a
/// `SyncConfiguration`.
///
/// Settings → Server and the first-run flow's server step both keep one of
/// these as view state, so both apply the same rules: what counts as a usable
/// URL, what a pasted token line looks like, and — the reason this type exists
/// — **one** way a `PairingPayload` lands in the fields, whether it was
/// scanned, pasted, typed into the URL field, or opened as a `puls://` link.
///
/// Nothing here touches a configuration until `commit(to:)`. That includes the
/// paired user ID: it is staged with the other two values rather than written
/// into the shared draft on arrival, so a pairing code that is filled in and
/// then abandoned leaves nothing behind for some later Apply to pick up.
public struct ServerFieldsDraft: Sendable, Equatable {
    public var urlText: String
    public var tokenText: String
    /// The user ID of the last pairing code filled in, until it is committed.
    /// Nil when the fields were typed by hand — the configuration's own user
    /// ID then stays as it is.
    public private(set) var pairedUserID: String?

    public init(urlText: String = "", tokenText: String = "") {
        self.urlText = urlText
        self.tokenText = tokenText
    }

    /// The fields as a configuration has them.
    public init(configuration: SyncConfiguration) {
        self.init(
            urlText: configuration.serverURL?.absoluteString ?? "",
            tokenText: configuration.authToken ?? "")
    }

    // MARK: - URL

    /// Validation of the entered URL; nil while the field is empty (an empty
    /// URL is allowed — it un-configures the server).
    public var urlValidation: Result<URL, ServerURLValidation.Failure>? {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : ServerURLValidation.validate(trimmed)
    }

    public var validatedURL: URL? {
        if case .success(let url) = urlValidation { return url }
        return nil
    }

    /// What is wrong with the URL field, for the caption under it.
    public var urlIssue: String? {
        // A pairing code that does not parse is reported as one. Left to URL
        // validation it would read "Unsupported scheme puls://", which says
        // nothing about the code's actual problem.
        // A valid one is no issue at all: the screen is about to take it out of
        // the field (`pairingCodeInURLField`), and an error must not flash first.
        switch PairingPayload.parse(urlText) {
        case .success: return nil
        case .failure(.notAPairingCode): break
        case .failure(let failure): return failure.errorDescription
        }
        if case .failure(let failure) = urlValidation { return failure.errorDescription }
        return nil
    }

    /// The pairing code sitting in the URL field, if that is what was put
    /// there. People paste the whole `puls://pair?…` string into the first
    /// field they see; the screen hands this to `fill(from:)` instead of
    /// showing a validation error.
    public var pairingCodeInURLField: PairingPayload? {
        if case .success(let payload) = PairingPayload.parse(urlText) { return payload }
        return nil
    }

    // MARK: - Token

    /// The entered token, normalized: accepts a pasted `PULS_TOKEN=…` line from
    /// the server's `.env` as well as the bare token.
    public var token: String { Self.normalizeToken(tokenText) }

    public static func normalizeToken(_ text: String) -> String {
        var token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.hasPrefix("PULS_TOKEN="), let value = token.split(separator: "=", maxSplits: 1).last {
            token = String(value)
        }
        return token
    }

    /// Whether there is enough here to run a connection test.
    public var isTestable: Bool { validatedURL != nil && !token.isEmpty }

    /// The user ID a connection test of these fields should present:
    /// the paired one when a code supplied it. A per-device token is bound to
    /// its user, so testing a freshly paired token under the *old* ID is a 403
    /// for a pairing that is perfectly good.
    public func connectionTestUserID(fallback: String) -> String { pairedUserID ?? fallback }

    // MARK: - Pairing

    /// The single entry point for a pairing code, whatever its source.
    public mutating func fill(from payload: PairingPayload) {
        urlText = payload.serverURL.absoluteString
        tokenText = payload.token
        pairedUserID = payload.userID
    }

    /// Writes the fields into a configuration draft: the validated URL (nil
    /// when the field is empty or unusable), the token (nil when empty), and
    /// the paired user ID when there is one. Nothing else is touched.
    public func commit(to configuration: inout SyncConfiguration) {
        configuration.serverURL = validatedURL
        configuration.authToken = token.isEmpty ? nil : token
        if let pairedUserID { configuration.userID = pairedUserID }
    }

    /// Call once the fields have been applied: the paired user ID has done its
    /// job, and keeping it would overwrite a later edit on the User page the
    /// next time these fields are saved.
    public mutating func markCommitted() {
        pairedUserID = nil
    }
}
