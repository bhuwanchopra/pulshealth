import SwiftUI

/// A titled card inside a `List` or `Form`: the inset-grouped cell the banners
/// and setup cards are made of. Title in `.headline`, an optional subtitle
/// under it, an optional trailing action beside it, then whatever the card
/// says or offers — laid out so every card in the app reads the same.
struct CardSection<Content: View, Action: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder let action: () -> Action
    @ViewBuilder let content: () -> Content

    init(
        _ title: String, subtitle: String? = nil,
        @ViewBuilder action: @escaping () -> Action,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.action = action
        self.content = content
    }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.headline)
                        if let subtitle {
                            Text(subtitle)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                // Wrap, never truncate: inside a list row an
                                // HStack can otherwise hand the text one line.
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                    action()
                }
                content()
            }
            .padding(.vertical, 4)
        }
    }
}

extension CardSection where Action == EmptyView {
    init(
        _ title: String, subtitle: String? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(title, subtitle: subtitle, action: { EmptyView() }, content: content)
    }
}
