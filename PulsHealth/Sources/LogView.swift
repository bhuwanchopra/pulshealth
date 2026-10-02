import SwiftUI
import PulsHealthSync

/// Sync → Activity → Log: the live, filterable event stream.
struct LogView: View {
    @Environment(AppModel.self) private var model
    @State private var minLevel: SyncEvent.Level = .debug
    @State private var filterType: String?

    private var filtered: [SyncEvent] {
        model.events.filter { event in
            event.level.rank >= minLevel.rank
                && (filterType == nil || event.type == filterType)
        }
    }

    var body: some View {
        List(filtered.reversed()) { event in
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(event.level.rawValue.uppercased())
                        .font(.caption2.bold())
                        .foregroundStyle(event.level.color)
                    if let type = event.type,
                       let descriptor = HealthTypeCatalog.descriptor(for: type) {
                        Text(descriptor.displayName)
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                    Spacer()
                    Text(event.date, format: .dateTime.hour().minute().second())
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                Text(event.message).font(.caption).textSelection(.enabled)
            }
            .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
        }
        .listStyle(.plain)
        // Title and the Log/Background switch are ActivityView's; this
        // contributes only the filter menu.
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Minimum level", selection: $minLevel) {
                        Text("Debug").tag(SyncEvent.Level.debug)
                        Text("Info").tag(SyncEvent.Level.info)
                        Text("Warnings").tag(SyncEvent.Level.warn)
                        Text("Errors").tag(SyncEvent.Level.error)
                    }
                    Picker("Type", selection: $filterType) {
                        Text("All types").tag(String?.none)
                        ForEach(model.statuses) { status in
                            Text(status.descriptor.displayName).tag(String?.some(status.id))
                        }
                    }
                    Button("Clear Log", role: .destructive) {
                        Task { await model.clearEvents() }
                    }
                } label: {
                    Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
                }
            }
        }
    }
}

extension SyncEvent.Level {
    var rank: Int {
        switch self {
        case .debug: return 0
        case .info: return 1
        case .warn: return 2
        case .error: return 3
        }
    }

    var color: Color {
        switch self {
        case .debug: return .secondary
        case .info: return .blue
        case .warn: return .orange
        case .error: return .red
        }
    }
}
