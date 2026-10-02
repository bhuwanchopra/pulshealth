import Foundation
import Testing
@testable import PulsHealthSync

/// The server fields as typed, shared by Settings → Server and the first-run
/// flow — and the one way a pairing code lands in them.
@Suite struct ServerFieldsDraftTests {
    private let user = "5ea4d000-0000-4000-8000-000000000001"

    private func pairing(_ url: String = "https://puls.example.test:8443") -> PairingPayload {
        PairingPayload(serverURL: URL(string: url)!, token: "s3cr3t", userID: user)
    }

    @Test func startsFromTheConfiguration() {
        var config = SyncConfiguration()
        config.serverURL = URL(string: "https://puls.example.test")
        config.authToken = "tok"
        let draft = ServerFieldsDraft(configuration: config)
        #expect(draft.urlText == "https://puls.example.test")
        #expect(draft.tokenText == "tok")
        #expect(draft.pairedUserID == nil)
        #expect(draft.isTestable)
    }

    @Test func anEmptyURLIsAllowedAndAnUnusableOneIsExplained() {
        var draft = ServerFieldsDraft()
        #expect(draft.urlValidation == nil)
        #expect(draft.urlIssue == nil)
        #expect(!draft.isTestable)

        draft.urlText = "puls.example.test:8080"
        #expect(draft.validatedURL == nil)
        #expect(draft.urlIssue == ServerURLValidation.Failure.missingScheme.errorDescription)

        draft.urlText = " https://puls.example.test/ "
        #expect(draft.validatedURL == URL(string: "https://puls.example.test"))
        #expect(draft.urlIssue == nil)
    }

    @Test func acceptsAPastedEnvLineAsTheToken() {
        var draft = ServerFieldsDraft(urlText: "https://puls.example.test")
        draft.tokenText = "  PULS_TOKEN=abc=def\n"
        #expect(draft.token == "abc=def")
        draft.tokenText = " bare "
        #expect(draft.token == "bare")
        draft.tokenText = "   "
        #expect(draft.token.isEmpty)
        #expect(!draft.isTestable)
    }

    /// People paste the whole pairing string into the first field they see.
    @Test func aPairingCodeInTheURLFieldIsRecognized() {
        var draft = ServerFieldsDraft()
        draft.urlText = "puls://pair?url=https%3A%2F%2Fpuls.example.test%3A8443&token=s3cr3t&user=\(user)"
        #expect(draft.pairingCodeInURLField == pairing())
        #expect(draft.urlIssue == nil, "not a URL validation error")

        draft.urlText = "https://puls.example.test"
        #expect(draft.pairingCodeInURLField == nil)
    }

    /// A pairing code that does not parse is reported as one, not as
    /// "Unsupported scheme puls://".
    @Test func aBrokenPairingCodeInTheURLFieldIsExplainedAsOne() {
        var draft = ServerFieldsDraft()
        draft.urlText = "puls://pair?url=https%3A%2F%2Fpuls.example.test&user=\(user)"
        #expect(draft.pairingCodeInURLField == nil)
        #expect(draft.urlIssue == PairingPayload.Failure.missingField("token").errorDescription)
        #expect(draft.validatedURL == nil)
    }

    @Test func fillReplacesAllThreeValues() {
        var draft = ServerFieldsDraft(urlText: "https://old.example.test", tokenText: "old")
        draft.fill(from: pairing())
        #expect(draft.urlText == "https://puls.example.test:8443")
        #expect(draft.tokenText == "s3cr3t")
        #expect(draft.pairedUserID == user)
        #expect(draft.connectionTestUserID(fallback: "someone-else") == user)
        #expect(ServerFieldsDraft().connectionTestUserID(fallback: "someone-else") == "someone-else")
    }

    /// Filling is not committing: the configuration — user ID included — is
    /// untouched until the screen says so.
    @Test func nothingReachesTheConfigurationBeforeCommit() {
        var config = SyncConfiguration(enabledTypes: ["HKQuantityTypeIdentifierStepCount"])
        let before = config
        var draft = ServerFieldsDraft(configuration: config)
        draft.fill(from: pairing())
        #expect(config == before)

        draft.commit(to: &config)
        #expect(config.serverURL == URL(string: "https://puls.example.test:8443"))
        #expect(config.authToken == "s3cr3t")
        #expect(config.userID == user)
        #expect(config.enabledTypes == before.enabledTypes)
        #expect(config.startDate == before.startDate)
    }

    @Test func handTypedFieldsLeaveTheUserIDAlone() {
        var config = SyncConfiguration()
        config.userID = user
        var draft = ServerFieldsDraft(urlText: "https://puls.example.test", tokenText: "tok")
        draft.commit(to: &config)
        #expect(config.userID == user)

        // Emptied fields un-configure the server.
        draft.urlText = ""
        draft.tokenText = ""
        draft.commit(to: &config)
        #expect(config.serverURL == nil)
        #expect(config.authToken == nil)
        #expect(config.userID == user)
    }

    /// Once applied, the paired ID must not come back to overwrite a later
    /// edit made on the User page.
    @Test func aCommittedPairingStopsCarryingItsUserID() {
        var config = SyncConfiguration()
        var draft = ServerFieldsDraft()
        draft.fill(from: pairing())
        draft.commit(to: &config)
        draft.markCommitted()
        #expect(draft.pairedUserID == nil)

        config.userID = "5ea4d000-0000-4000-8000-000000000009"
        draft.commit(to: &config)
        #expect(config.userID == "5ea4d000-0000-4000-8000-000000000009")
    }
}
