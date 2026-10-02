import SwiftUI
import PulsHealthSync

/// The prompt an incoming `puls://` link has to get through
/// (`AppModel.handleIncomingURL`): "Pair with <host>?" for a valid pairing
/// link, or a plain notice for one that cannot be used. Until the user taps
/// Continue the link has changed nothing, and Cancel — the emphasized button —
/// leaves it that way.
///
/// Attached twice, because an alert cannot come up from underneath a cover:
/// on `RootView` for a configured install, and on `OnboardingView` while the
/// first-run flow is covering it. `canPresent` is how each host says "not me,
/// not now", so exactly one of them ever tries.
struct PairingLinkPromptModifier: ViewModifier {
    @Environment(AppModel.self) private var model
    let canPresent: Bool

    func body(content: Content) -> some View {
        content.alert(
            title,
            isPresented: Binding(
                get: { canPresent && model.pairingLinkPrompt != nil },
                // As with the server-change prompt: an alert only closes
                // through its buttons, and each clears the prompt itself.
                set: { _ in }
            ),
            presenting: model.pairingLinkPrompt
        ) { prompt in
            switch prompt {
            case .confirm(let payload):
                // The button hands back the payload this alert was built
                // from; the model refuses it if that is no longer the one
                // pending, so what was read is what gets filled in.
                Button(model.pairingConfirmation(for: payload).confirmTitle) {
                    model.confirmPairingLink(payload)
                }
                Button("Cancel", role: .cancel) { model.dismissPairingLink() }
            case .rejected:
                Button("OK", role: .cancel) { model.dismissPairingLink() }
            }
        } message: { prompt in
            switch prompt {
            case .confirm(let payload): Text(model.pairingConfirmation(for: payload).message)
            case .rejected(let message): Text(message)
            }
        }
    }

    private var title: String {
        switch model.pairingLinkPrompt {
        case .confirm(let payload): model.pairingConfirmation(for: payload).title
        case .rejected, nil: PairingConfirmation.rejectionTitle
        }
    }
}

extension View {
    func pairingLinkPrompt(canPresent: Bool) -> some View {
        modifier(PairingLinkPromptModifier(canPresent: canPresent))
    }
}

/// "Paste Pairing Code": the route for a database whose QR code is not in
/// front of the camera — a terminal on the same device, a payload sent over a
/// message. Used by the Sync tab’s Database screen.
///
/// It is the system `PasteButton` rather than a button that reads
/// `UIPasteboard`: the tap itself is the permission, so iOS shows no
/// "PulsHealth would like to paste from …" banner, and the app never looks at
/// the clipboard unless that button is tapped.
struct PastePairingCodeRow: View {
    /// The screen's URL text. Any change to it — a scan, an accepted link, the
    /// user typing — means the complaint below is about a paste that no longer
    /// matters, so it is dropped rather than left next to fields that are fine.
    let urlText: String
    /// Called with a validated payload; the screen's one pairing function.
    let onPayload: (PairingPayload) -> Void
    /// Why the last paste was not a usable pairing code.
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Paste Pairing Code", systemImage: "doc.on.clipboard")
                Spacer()
                PasteButton(payloadType: String.self) { strings in
                    paste(strings)
                }
                .labelStyle(.titleOnly)
                .buttonBorderShape(.capsule)
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .onChange(of: urlText) { problem = nil }
    }

    private func paste(_ strings: [String]) {
        // A pasteboard can hold several strings; the first that parses wins,
        // and the first failure that is at least pairing-code-shaped is the
        // one worth explaining.
        var shapedFailure: PairingPayload.Failure?
        for text in strings {
            switch PairingPayload.parse(text) {
            case .success(let payload):
                problem = nil
                onPayload(payload)
                return
            case .failure(let failure):
                if failure != .notAPairingCode, shapedFailure == nil { shapedFailure = failure }
            }
        }
        // The token never appears here: no failure description carries one.
        problem = shapedFailure?.errorDescription
            ?? "That is not a pairing code. Copy the line starting with puls://pair from your database's pairing block (make pairing), then paste again."
    }
}
