import SwiftUI
import PulsHealthSync

/// Sync → Database: the URL and token, held in a `ServerFieldsDraft` until Save
/// & Apply — including the user ID a pairing code brought with them — with
/// Test Connection against the entered values and the three ways a pairing
/// code arrives (scanned, pasted, or accepted as a `puls://` link).
struct ServerSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// A caller that wants the scanner already up on arrival (a pairing
    /// route can); the Sync tab's Set Up opens the form itself.
    let scanOnArrival: Bool

    @State private var server = ServerFieldsDraft()
    @State private var loaded = false
    @State private var testingConnection = false
    /// Outcome of the last Test Connection for the values currently entered;
    /// cleared whenever either field changes.
    @State private var connectionTest: ConnectionTestResult?
    @State private var connectionTestRun = 0
    @State private var showScanner = false

    var body: some View {
        Form {
            Section {
                Button {
                    showScanner = true
                } label: {
                    Label("Scan Pairing Code", systemImage: "qrcode.viewfinder")
                }
                PastePairingCodeRow(urlText: server.urlText) { applyPairing($0) }
            } footer: {
                Text("A pairing code, scanned, pasted, or opened as a puls:// link, fills in the URL, token and user ID your database's setup prints (`make pairing`) and tests them.")
            }

            Section {
                // Verbatim prompts: as a string literal the URL became a
                // localized key, and Text styled it as a tappable link.
                LabeledContent("Database URL") {
                    TextField("Database URL", text: $server.urlText, prompt: Text(verbatim: "https://your-host:8443"))
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                if let issue = server.urlIssue {
                    Label(issue, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                LabeledContent("Token") {
                    SecureField("Token", text: $server.tokenText, prompt: Text(verbatim: "Bearer token"))
                }
                Button {
                    runConnectionTest()
                } label: {
                    HStack {
                        Text(testingConnection ? "Testing Connection…" : "Test Connection")
                        if testingConnection {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(testingConnection || !server.isTestable)
                if let pairedUserID = server.pairedUserID {
                    // The third value of a pairing code has no field on this
                    // screen (it lives under Settings → User → Advanced), so
                    // say that it is staged too rather than changing it out
                    // of sight.
                    Label {
                        Text("Filled in from a pairing code, with user ID \(pairedUserID). Nothing changes until you tap Save & Apply.")
                    } icon: {
                        Image(systemName: "qrcode")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            } header: {
                Text("Or enter it by hand")
            } footer: {
                Text("Database URL is the address your database's pairing code shows. Use https://; plain http:// is accepted only for hosts on your local network (localhost, *.local, 10.x, 172.16–31.x, 192.168.x). Test Connection uses the values entered above without saving them.")
            }

            // The outcome of the last test sits right above the button that
            // commits the values it was run against.
            Section {
                if let result = connectionTest {
                    ConnectionTestResultRow(result: result)
                }
                Button {
                    Task { await apply() }
                } label: {
                    Text("Save & Apply")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(server.urlIssue != nil)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                .listRowSeparator(.hidden)
            } footer: {
                Text("An empty URL disconnects the database; syncing stops and the Export tab keeps working.")
            }
        }
        .navigationTitle("Database")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if !loaded {
                loaded = true
                server = ServerFieldsDraft(configuration: model.config)
                showScanner = scanOnArrival
            }
            // This screen is built lazily: an accepted pairing link can be
            // what brings it on screen for the first time, already waiting.
            collectConfirmedPairing()
        }
        .onChange(of: model.pairingAwaitsSyncTab) { collectConfirmedPairing() }
        .onChange(of: server.urlText) {
            // A whole `puls://pair?…` string pasted into the URL field is a
            // pairing code, not a malformed URL.
            if let payload = server.pairingCodeInURLField {
                applyPairing(payload)
            } else {
                connectionTest = nil
            }
        }
        .onChange(of: server.tokenText) { connectionTest = nil }
        // The confirmation for an incoming link is an alert on RootView, and
        // it cannot come up over this sheet.
        .onChange(of: model.pairingLinkPrompt) { _, prompt in
            if prompt != nil { showScanner = false }
        }
        .sheet(isPresented: $showScanner) {
            PairingScannerView { applyPairing($0) }
        }
    }

    /// The one place a pairing code lands on this screen, whatever brought it:
    /// the scanner, the Paste button, a `puls://pair?…` string put in the URL
    /// field, or a link the user accepted (`collectConfirmedPairing`). It fills
    /// the three values and tests them. It never applies anything — Save &
    /// Apply does, and that still runs the server/user-change prompt if the
    /// target moved.
    private func applyPairing(_ payload: PairingPayload) {
        server.fill(from: payload)
        // The code was printed by the server it describes; find out now
        // whether the phone can reach it rather than after Save & Apply.
        runConnectionTest()
    }

    /// Takes a pairing link the user accepted (`AppModel.confirmPairingLink`).
    /// Not while the first-run flow is up: it has no database step, so the
    /// payload waits until the flow ends and RootView opens this screen.
    private func collectConfirmedPairing() {
        guard model.pairingAwaitsSyncTab, let payload = model.takeConfirmedPairing() else { return }
        applyPairing(payload)
    }

    /// Runs the connection test against the *entered* URL and token — not the
    /// saved ones — and persists nothing; only the result row changes.
    private func runConnectionTest() {
        guard let url = server.validatedURL else { return }
        let token = server.token
        guard !token.isEmpty else { return }
        let userID = server.connectionTestUserID(fallback: model.config.userID)
        testingConnection = true
        connectionTest = nil
        // A pairing code can arrive while an earlier test is still out; only
        // the latest run may report, or the row could describe old values.
        connectionTestRun += 1
        let run = connectionTestRun
        Task {
            let result = await model.testConnection(url: url, token: token, userID: userID)
            guard run == connectionTestRun else { return }
            connectionTest = result
            testingConnection = false
        }
    }

    private func apply() async {
        // Save & Apply is disabled while the URL is invalid; an empty field
        // clears the server.
        server.commit(to: &model.config)
        // The paired user ID is in the draft now, whichever way the
        // server-change prompt goes; holding on to it would overwrite a later
        // edit on the User page.
        server.markCommitted()
        // Applied: back to the Sync tab, which now shows the server's status.
        // Deferred to the server-change prompt instead: stay, so the fields
        // are still here to adjust if the user cancels it.
        if await model.applyConfiguration() {
            dismiss()
        }
    }
}
