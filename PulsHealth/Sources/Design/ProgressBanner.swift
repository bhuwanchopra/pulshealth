import SwiftUI

/// Something long-running, in a list row: what it is, where it stands, a bar
/// that is determinate when the work can say how far it is and a spinner when
/// it cannot (HealthKit never says how many samples a type holds), and a
/// Cancel when stopping it is an option.
struct ProgressBanner: View {
    let title: String
    var subtitle: String?
    /// 0…1 for a determinate bar; nil for an indeterminate one.
    var fraction: Double?
    var onCancel: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold))
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if let onCancel {
                    Button("Cancel", role: .destructive, action: onCancel)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            if let fraction {
                ProgressView(value: min(max(fraction, 0), 1))
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("In progress…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
