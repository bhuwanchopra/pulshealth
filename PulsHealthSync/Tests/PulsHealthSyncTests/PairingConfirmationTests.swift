import Foundation
import Testing
@testable import PulsHealthSync

/// The prompt an incoming `puls://pair` link has to get through. Anyone can
/// fire such a link, so what the prompt says — which host, whether it displaces
/// a configured server, whether the connection is encrypted — is the security
/// boundary, and it is decided here rather than in a view.
@Suite struct PairingConfirmationTests {
    private let user = "5ea4d000-0000-4000-8000-000000000001"
    private let otherUser = "5ea4d000-0000-4000-8000-000000000002"

    private func payload(_ url: String, token: String = "s3cr3t-t0ken", user: String? = nil) -> PairingPayload {
        PairingPayload(serverURL: URL(string: url)!, token: token, userID: user ?? self.user)
    }

    @Test func aFirstPairingNamesTheHostAndNothingElse() {
        let confirmation = PairingConfirmation(
            payload: payload("https://puls.example.test:8443/ingest"),
            currentServerURL: nil, currentUserID: PulsDefaultUser.id, destination: .onboarding)
        #expect(confirmation.effect == .firstServer)
        #expect(confirmation.serverLabel == "puls.example.test:8443/ingest")
        #expect(confirmation.title == "Pair with puls.example.test:8443/ingest?")
        #expect(!confirmation.isUnencrypted)
        // Swapping the default user ID for the server's is the point of a
        // first pairing, not something to warn about.
        #expect(!confirmation.userChanges)
        #expect(!confirmation.message.contains("replace"))
        #expect(!confirmation.message.contains("http://"))
        #expect(confirmation.message.contains("Nothing is sent until you finish setup."))
    }

    @Test func aDifferentConfiguredServerIsCalledOutByName() {
        let confirmation = PairingConfirmation(
            payload: payload("https://new.example.test"),
            currentServerURL: URL(string: "https://old.example.test:8443"), currentUserID: user,
            destination: .settings)
        #expect(confirmation.effect == .replacesServer(current: "old.example.test:8443"))
        #expect(confirmation.message.contains("It would replace the database you sync to now, old.example.test:8443."))
        #expect(confirmation.message.contains("Nothing changes until you tap Save & Apply."))
    }

    /// The same normalization the server-change prompt uses: a default port,
    /// host case, a trailing slash and http→https are not a different server.
    @Test func cosmeticURLDifferencesAreTheSameServer() {
        let confirmation = PairingConfirmation(
            payload: payload("https://Puls.Example.test:443"),
            currentServerURL: URL(string: "https://puls.example.test/"), currentUserID: user,
            destination: .settings)
        #expect(confirmation.effect == .sameServer)
        #expect(!confirmation.userChanges)
        #expect(confirmation.message.contains("Pairing again replaces the saved token."))
    }

    @Test func aChangedUserOnTheSameServerIsSaid() {
        let confirmation = PairingConfirmation(
            payload: payload("https://puls.example.test", user: otherUser),
            currentServerURL: URL(string: "https://puls.example.test"), currentUserID: user,
            destination: .settings)
        #expect(confirmation.effect == .sameServer)
        #expect(confirmation.userChanges)
        #expect(confirmation.message.contains("replaces the saved token and changes your user ID."))
    }

    @Test func plainHTTPIsCalledUnencrypted() {
        let confirmation = PairingConfirmation(
            payload: payload("http://192.168.1.20:8080"),
            currentServerURL: nil, currentUserID: user, destination: .onboarding)
        #expect(confirmation.isUnencrypted)
        #expect(confirmation.title == "Pair with 192.168.1.20:8080?")
        #expect(confirmation.message.contains("not encrypted"))
    }

    /// `https://trusted@evil` is a classic: the prompt must show where the
    /// connection actually goes.
    @Test func userinfoNeverPassesForTheHost() {
        let confirmation = PairingConfirmation(
            payload: payload("https://puls.example.test@elsewhere.example.test"),
            currentServerURL: nil, currentUserID: user, destination: .onboarding)
        #expect(confirmation.serverLabel == "elsewhere.example.test")
    }

    /// The prompt is shown to whoever is holding the phone and its wording
    /// ends up in screenshots; the token belongs in neither.
    @Test func theTokenIsNeverInTheCopy() {
        for destination in [PairingConfirmation.Destination.onboarding, .settings] {
            let confirmation = PairingConfirmation(
                payload: payload("http://192.168.1.20:8080", user: otherUser),
                currentServerURL: URL(string: "https://old.example.test"), currentUserID: user,
                destination: destination)
            #expect(!confirmation.title.contains("s3cr3t-t0ken"))
            #expect(!confirmation.message.contains("s3cr3t-t0ken"))
        }
    }

    @Test func aLinkThatIsNotAPairingLinkGetsACalmExplanation() {
        let message = PairingConfirmation.rejectionMessage(for: .notAPairingCode)
        #expect(message.hasPrefix("It is not a PulsHealth pairing link."))
        #expect(message.contains("Nothing was changed."))
        // The scanner's advice makes no sense for a link.
        #expect(!message.contains("Scan the one your database"))
    }

    @Test func aBrokenPairingLinkSaysWhatIsWrongWithIt() {
        let message = PairingConfirmation.rejectionMessage(
            for: .invalidServerURL(.insecureRemoteHost("puls.example.test")))
        #expect(message.contains("local-network"))
        #expect(message.contains("Nothing was changed."))
        let incomplete = PairingConfirmation.rejectionMessage(for: .missingField("token"))
        #expect(incomplete.hasPrefix("This isn’t a complete PulsHealth pairing code."))
        #expect(incomplete.contains("on Sync → Database"))
        // Whoever opens the link may never have seen the server's scripts.
        #expect(!incomplete.contains("scripts/"))
    }
}
