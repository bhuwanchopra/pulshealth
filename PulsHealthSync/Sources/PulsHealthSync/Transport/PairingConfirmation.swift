import Foundation

/// What the app has to say before a pairing *link* is allowed anywhere near the
/// server fields.
///
/// A code scanned or pasted inside the app is something the user went and did.
/// A `puls://pair?…` link is not: any web page, message or other app can fire
/// one, and its whole purpose is to say where this phone's health data should
/// go. So a link never fills anything on its own — the app shows this
/// confirmation first, naming the host the link points at, and it says so when
/// accepting would move the sync off a server that is already configured or
/// onto a connection that is not encrypted.
///
/// Pure on purpose: the decision and its wording are here, away from SwiftUI,
/// so they can be tested.
public struct PairingConfirmation: Sendable, Equatable {
    /// How the link's server relates to the one the app syncs to now.
    public enum Effect: Sendable, Equatable {
        /// No server is configured; this would be the first.
        case firstServer
        /// The link names the server already in use — accepting replaces the
        /// saved token (and, with `userChanges`, the user ID).
        case sameServer
        /// A different server is in use; `current` is its `host[:port][/path]`.
        case replacesServer(current: String)
    }

    /// Which screen will receive the values, because what "accept" leads to
    /// differs and the prompt must not promise the wrong thing.
    public enum Destination: Sendable, Equatable {
        /// The first-run flow's server step. Nothing is applied until its last step.
        case onboarding
        /// Sync → Database. Nothing is applied until Save & Apply.
        case settings
    }

    /// `host[:port][/path]` of the server the link points at — the same label
    /// the server-change prompt and the log use.
    public let serverLabel: String
    public let effect: Effect
    /// The link carries a different user ID than the one in use. Only reported
    /// alongside a configured server: on a first pairing the ID in use is a
    /// default nobody chose, and replacing it is the point.
    public let userChanges: Bool
    /// Plain `http://`. `PairingPayload.parse` only lets that through for a
    /// local-network host, but "local" is not "trusted" on someone else's Wi-Fi.
    public let isUnencrypted: Bool
    public let destination: Destination

    /// - Parameters:
    ///   - currentServerURL: the *applied* server — where data goes today — not
    ///     a half-typed draft.
    ///   - currentUserID: the applied user ID.
    public init(
        payload: PairingPayload, currentServerURL: URL?, currentUserID: String,
        destination: Destination
    ) {
        let target = ServerIdentity(url: payload.serverURL, userID: payload.userID)
        serverLabel = target?.serverLabel ?? payload.serverURL.absoluteString
        isUnencrypted = payload.serverURL.scheme?.lowercased() == "http"
        self.destination = destination

        let current = currentServerURL.flatMap { ServerIdentity(url: $0, userID: currentUserID) }
        if let current, let target {
            let change = ServerIdentityChange(from: current, to: target)
            effect = change.serverChanged ? .replacesServer(current: current.serverLabel) : .sameServer
            userChanges = change.userChanged
        } else {
            effect = .firstServer
            userChanges = false
        }
    }

    /// Names the host: the one fact the user has to check.
    public var title: String { "Pair with \(serverLabel)?" }

    /// Neutral, and not the default — the prompt's Cancel carries the cancel
    /// role, which is the button iOS emphasizes.
    public var confirmTitle: String { "Continue" }

    public var message: String {
        var paragraphs = [
            "A link asked PulsHealth to send your health data to this database. "
                + "Continue only if the link came from your own database."
        ]
        switch effect {
        case .firstServer:
            break
        case .sameServer:
            paragraphs.append(
                "This is the database you already sync to. Pairing again replaces the saved token"
                    + (userChanges ? " and changes your user ID." : "."))
        case .replacesServer(let current):
            paragraphs.append("It would replace the database you sync to now, \(current).")
        }
        if isUnencrypted {
            paragraphs.append(
                "The link uses plain http://, so the connection is not encrypted. "
                    + "Use it only on a network you trust.")
        }
        switch destination {
        case .onboarding:
            paragraphs.append(
                "The details are filled in and the connection is tested. "
                    + "Nothing is sent until you finish setup.")
        case .settings:
            paragraphs.append(
                "The details are filled in under Sync → Database and the connection is tested. "
                    + "Nothing changes until you tap Save & Apply.")
        }
        return paragraphs.joined(separator: "\n\n")
    }

    // MARK: - A link that cannot be used

    /// Title for a `puls://` link that did not parse. Deliberately unalarming:
    /// the usual cause is a truncated or stale link, not an attack, and either
    /// way nothing happened.
    public static let rejectionTitle = "This Link Can’t Be Used"

    public static func rejectionMessage(for failure: PairingPayload.Failure) -> String {
        let reason: String
        switch failure {
        case .notAPairingCode:
            // The scanner's wording ("scan the QR code…") is wrong for a link.
            reason = "It is not a PulsHealth pairing link."
        default:
            reason = failure.errorDescription ?? "It could not be read."
        }
        return reason + "\n\nNothing was changed. You can still scan the pairing code "
            + "or enter the database details by hand on Sync → Database."
    }
}
