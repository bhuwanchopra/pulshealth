import SwiftUI

/// One number with its label, for a 2- or 4-column `LazyVGrid` of them: the
/// label in a caption, the value large and tabular so a grid of them lines up
/// as digits change, an optional unit beside it and a footnote under it.
struct StatTile: View {
    let label: String
    let value: String
    var unit: String?
    var footnote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.title3.weight(.semibold).monospacedDigit())
                if let unit {
                    Text(unit)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if let footnote {
                Text(footnote)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// A short status word in a tinted capsule: "Backfilling", "3 failing".
/// One line, always — a capsule wrapped onto two lines crowds its text into
/// the corners. Anything longer than a word or two is a `StatusDot`.
struct StatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(color.opacity(0.15), in: Capsule())
    }
}

/// A coloured dot and the state in words, leading-aligned in the card's
/// reading order: "Connected", "Health has new data since".
struct StatusDot: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(text)
                .font(.subheadline)
        }
    }
}
