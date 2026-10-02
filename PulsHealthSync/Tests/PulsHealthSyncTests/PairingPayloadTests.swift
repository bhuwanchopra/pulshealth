import Foundation
import Testing
@testable import PulsHealthSync

/// The `puls://pair?url=&token=&user=` payload `scripts/bootstrap.sh` prints as
/// a QR code. A scanned code is untrusted input, so every field is re-validated
/// with the same rules the typed Settings fields use.
@Suite struct PairingPayloadTests {
    private let user = "5ea4d000-0000-4000-8000-000000000001"

    private func success(_ text: String) throws -> PairingPayload {
        switch PairingPayload.parse(text) {
        case .success(let payload): return payload
        case .failure(let failure): throw failure
        }
    }

    private func failure(_ text: String) throws -> PairingPayload.Failure {
        switch PairingPayload.parse(text) {
        case .success(let payload):
            Issue.record("expected a failure, parsed \(payload)")
            throw PairingPayload.Failure.notAPairingCode
        case .failure(let failure):
            return failure
        }
    }

    @Test func parsesTheBootstrapPayload() throws {
        let payload = try success("puls://pair?url=https://puls.example.test:8443&token=s3cr3t&user=\(user)")
        #expect(payload.serverURL == URL(string: "https://puls.example.test:8443"))
        #expect(payload.token == "s3cr3t")
        #expect(payload.userID == user)
    }

    /// bootstrap.sh percent-encodes every character outside `[A-Za-z0-9.~_-]`,
    /// so the real payload's `url` arrives fully escaped.
    @Test func decodesPercentEncodedFields() throws {
        let payload = try success(
            "puls://pair?url=https%3A%2F%2Fpuls.example.test%3A8443%2Fingest"
                + "&token=tok%2Fen%2Bwith%20spaces%3D%3D&user=\(user)")
        #expect(payload.serverURL == URL(string: "https://puls.example.test:8443/ingest"))
        #expect(payload.token == "tok/en+with spaces==")
        #expect(payload.userID == user)
    }

    @Test func normalizesTheURLAndUserCase() throws {
        let payload = try success(
            "PULS://PAIR?url=https%3A%2F%2FPuls.Example.test%3A8443%2F&token=t&user=\(user.uppercased())")
        #expect(payload.serverURL == URL(string: "https://Puls.Example.test:8443"), "trailing slash dropped")
        #expect(payload.userID == user, "user IDs are stored lowercased")
    }

    @Test func ignoresUnknownQueryItems() throws {
        let payload = try success(
            "puls://pair?url=https://puls.example.test&v=2&token=t&user=\(user)&note=hello")
        #expect(payload.token == "t")
    }

    @Test func acceptsPlainHTTPToALocalNetworkHost() throws {
        let payload = try success("puls://pair?url=http%3A%2F%2F192.168.1.20%3A8080&token=t&user=\(user)")
        #expect(payload.serverURL == URL(string: "http://192.168.1.20:8080"))
    }

    @Test func rejectsPlainHTTPToARemoteHost() throws {
        let result = try failure("puls://pair?url=http%3A%2F%2Fpuls.example.test%3A8080&token=t&user=\(user)")
        #expect(result == .invalidServerURL(.insecureRemoteHost("puls.example.test")))
        #expect(result.errorDescription?.contains("local-network") == true)
    }

    @Test func rejectsMissingFields() throws {
        #expect(try failure("puls://pair?token=t&user=\(user)") == .missingField("url"))
        #expect(try failure("puls://pair?url=https://puls.example.test&user=\(user)") == .missingField("token"))
        #expect(try failure("puls://pair?url=https://puls.example.test&token=t") == .missingField("user"))
        #expect(try failure("puls://pair") == .missingField("url"))
        #expect(try failure("puls://pair?url=&token=t&user=\(user)") == .missingField("url"))
    }

    @Test func rejectsAnythingThatIsNotAPairingCode() throws {
        #expect(try failure("https://pair?url=https://puls.example.test&token=t&user=\(user)") == .notAPairingCode)
        #expect(try failure("puls://setup?url=https://puls.example.test&token=t&user=\(user)") == .notAPairingCode)
        #expect(try failure("WIFI:S:home;T:WPA;P:hunter2;;") == .notAPairingCode)
        #expect(try failure("   ") == .notAPairingCode)
    }

    // MARK: - Pasted and linked payloads

    /// A paste comes with whatever surrounded the payload in the terminal.
    @Test func toleratesSurroundingWhitespaceAndNewlines() throws {
        let payload = try success("\n  \tpuls://pair?url=https://puls.example.test&token=t&user=\(user)  \r\n")
        #expect(payload.serverURL == URL(string: "https://puls.example.test"))
        #expect(payload.token == "t")
    }

    /// Mail clients wrap links in angle brackets; chat messages and READMEs
    /// quote or back-tick them.
    @Test func unwrapsBracketsAndQuotes() throws {
        let bare = "puls://pair?url=https://puls.example.test&token=t0k&user=\(user)"
        for wrapped in ["<\(bare)>", "\"\(bare)\"", "'\(bare)'", "`\(bare)`", "“\(bare)”", "(\(bare))"] {
            let payload = try success(wrapped)
            #expect(payload.token == "t0k", "token must not keep a wrapper: \(wrapped)")
            #expect(payload.userID == user, "user must not keep a wrapper: \(wrapped)")
        }
    }

    /// Copying the whole block `bootstrap.sh` prints, label and all.
    @Test func findsThePayloadInsideThePairingBlock() throws {
        let block = """
             Pairing payload (what the QR code encodes):
             puls://pair?url=https%3A%2F%2Fpuls.example.test%3A8443&token=s3cr3t&user=\(user)

             Later: make pairing re-prints this block.
            """
        let payload = try success(block)
        #expect(payload.serverURL == URL(string: "https://puls.example.test:8443"))
        #expect(payload.token == "s3cr3t")
        #expect(payload.userID == user)
    }

    /// `URL.absoluteString` of an opened link, scheme in whatever case the
    /// sender used.
    @Test func acceptsAnUppercaseSchemeAnywhereItIsFound() throws {
        #expect(try success("Payload: PULS://pair?url=https://puls.example.test&token=t&user=\(user)").token == "t")
    }

    /// The payload has to stand on its own. One smuggled into another URL's
    /// query string is that URL's business, not a pairing code.
    @Test func ignoresAPayloadBuriedInAnotherURL() throws {
        #expect(
            try failure("https://example.test/?next=puls://pair?url=https://puls.example.test&token=t&user=\(user)")
                == .notAPairingCode)
        #expect(try failure("xpuls://pair?url=https://puls.example.test&token=t&user=\(user)") == .notAPairingCode)
    }

    /// Tolerance is about the wrapping only — every field is still re-validated.
    @Test func aWrappedPayloadIsStillValidated() throws {
        #expect(
            try failure("<puls://pair?url=http%3A%2F%2Fpuls.example.test&token=t&user=\(user)>")
                == .invalidServerURL(.insecureRemoteHost("puls.example.test")))
        #expect(try failure("  puls://pair?url=https://puls.example.test&token=t&user=me\n") == .invalidUserID)
        #expect(try failure("puls://elsewhere?url=https://puls.example.test&token=t&user=\(user)") == .notAPairingCode)
    }

    @Test func rejectsABadUserID() throws {
        #expect(try failure("puls://pair?url=https://puls.example.test&token=t&user=me") == .invalidUserID)
        #expect(
            try failure("puls://pair?url=https://puls.example.test&token=t&user=5ea4d000-0000-4000-8000")
                == .invalidUserID)
    }

    @Test func rejectsAMalformedServerURL() throws {
        #expect(try failure("puls://pair?url=puls.example.test%3A8080&token=t&user=\(user)")
            == .invalidServerURL(.missingScheme))
        #expect(try failure("puls://pair?url=ftp%3A%2F%2Fpuls.example.test&token=t&user=\(user)")
            == .invalidServerURL(.unsupportedScheme("ftp")))
    }

    @Test func appliesOnlyTheThreeServerFields() throws {
        var config = SyncConfiguration(enabledTypes: ["HKQuantityTypeIdentifierStepCount"])
        let before = config.startDate
        try success("puls://pair?url=https://puls.example.test&token=t&user=\(user)").apply(to: &config)
        #expect(config.serverURL == URL(string: "https://puls.example.test"))
        #expect(config.authToken == "t")
        #expect(config.userID == user)
        #expect(config.enabledTypes == ["HKQuantityTypeIdentifierStepCount"])
        #expect(config.startDate == before)
    }
}
