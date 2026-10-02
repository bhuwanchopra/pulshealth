import Foundation

// Formatting helpers shared by views.

extension Int {
    var byteString: String {
        ByteCountFormatter.string(fromByteCount: Int64(self), countStyle: .file)
    }

    var compactString: String {
        if self >= 1_000_000 { return String(format: "%.1fM", Double(self) / 1_000_000) }
        if self >= 10_000 { return String(format: "%.0fK", Double(self) / 1_000) }
        return formatted()
    }
}

extension TimeInterval {
    var shortDuration: String {
        if self < 1 { return String(format: "%.0f ms", self * 1000) }
        if self < 90 { return String(format: "%.1f s", self) }
        if self < 5_400 { return String(format: "%.0f min", self / 60) }
        return String(format: "%.1f h", self / 3600)
    }
}

extension Date {
    var relativeString: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: self, relativeTo: Date())
    }
}
