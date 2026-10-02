import SwiftUI

/// `ContentUnavailableView` with the app's defaults, so an empty list says the
/// same kind of thing everywhere and never just shows nothing.
struct EmptyState: View {
    var title = "Nothing here yet"
    var symbol = "tray"
    var message: String?

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            if let message { Text(message) }
        }
    }
}
