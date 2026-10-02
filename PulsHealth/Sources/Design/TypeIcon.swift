import SwiftUI
import PulsHealthSync

/// The Health-style tile in front of a type or category row: the category
/// colour as a soft rounded square, the symbol in the same colour on top. One
/// component rather than an `Image` + `frame` in every row, so every list in
/// the app draws types the same way.
struct TypeIcon: View {
    enum Size {
        case small, regular, large

        var side: CGFloat {
            switch self {
            case .small: 28
            case .regular: 36
            case .large: 56
            }
        }

        var font: Font {
            switch self {
            case .small: .caption
            case .regular: .body
            case .large: .title2
            }
        }
    }

    let symbol: String
    let color: Color
    var size: Size = .regular

    init(symbol: String, color: Color, size: Size = .regular) {
        self.symbol = symbol
        self.color = color
        self.size = size
    }

    init(_ descriptor: HealthTypeDescriptor, size: Size = .regular) {
        self.init(symbol: descriptor.symbol, color: descriptor.group.color, size: size)
    }

    init(_ group: HealthTypeDescriptor.Group, size: Size = .regular) {
        self.init(symbol: group.symbol, color: group.color, size: size)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(color.opacity(0.18))
            Image(systemName: symbol)
                .font(size.font.weight(.medium))
                .foregroundStyle(color)
        }
        .frame(width: size.side, height: size.side)
        .accessibilityHidden(true)
    }
}
