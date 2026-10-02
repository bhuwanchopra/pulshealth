import SwiftUI
import PulsHealthSync

/// Sync → Activity → Background, the field-study screen: how often the app gets background execution time, when
/// it wakes, and what work it does — plus a share-sheet export of the raw wake
/// records (CSV/JSON) and the event log (JSON) for offline analysis.
struct BackgroundActivityView: View {
    @Environment(AppModel.self) private var model
    @State private var exportURLs: [URL] = []

    private var stats: WakeStats { WakeStats(model.wakeRecords) }

    var body: some View {
        List {
            summarySection
            catchupScheduleSection
            triggerBreakdownSection
            recentSection
        }
        // Title and the Log/Background switch are ActivityView's.
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if exportURLs.isEmpty {
                    ProgressView()
                } else {
                    ShareLink(items: exportURLs) {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .task(id: model.wakeRecords.count) {
            exportURLs = await model.writeDiagnosticsBundle()
        }
        .refreshable { await model.refresh() }
    }

    private var catchupScheduleSection: some View {
        let status = model.backgroundScheduleStatus
        return Section("BG Processing safety net") {
            LabeledContent("Request pending", value: status.isPending ? "Yes" : "No")
            if let earliest = status.pendingEarliestBeginDate {
                LabeledContent("Earliest requested time") {
                    Text(earliest, format: .dateTime.month().day().hour().minute())
                }
            }
            if let submitted = status.lastSubmittedAt {
                LabeledContent("Last submitted") {
                    Text(submitted, format: .dateTime.month().day().hour().minute())
                }
            }
            if let launched = status.lastLaunchedAt {
                LabeledContent("Last granted by iOS") {
                    Text(launched, format: .dateTime.month().day().hour().minute())
                }
            }
            if let completed = status.lastCompletedAt {
                LabeledContent("Last completion") {
                    Text(completed, format: .dateTime.month().day().hour().minute())
                }
            }
            if let outcome = status.lastOutcome {
                LabeledContent("Last outcome", value: outcome.capitalized)
            }
            if let error = status.lastSubmissionError {
                LabeledContent("Submission error") {
                    Text(error).foregroundStyle(.red).multilineTextAlignment(.trailing)
                }
            }
            Text("A pending request confirms the app asked for catch-up time. iOS still decides whether and when to launch it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var summarySection: some View {
        Section("Overview") {
            LabeledContent("Wakes, last 24h", value: "\(stats.last24h)")
            LabeledContent("Wakes, last 7 days", value: "\(stats.last7d)")
            LabeledContent("Background wakes, 24h", value: "\(stats.background24h)")
            if let gap = stats.medianBackgroundGap {
                LabeledContent("Median between background wakes", value: gap.shortDuration)
            }
            if let last = stats.lastBackgroundWake {
                LabeledContent("Last background wake", value: last.relativeString)
            }
            if stats.cutShort > 0 {
                LabeledContent("Expired / interrupted") {
                    Text("\(stats.cutShort)").foregroundStyle(.orange)
                }
            }
            LabeledContent("Samples via wakes", value: stats.totalSamples.compactString)
        }
    }

    @ViewBuilder private var triggerBreakdownSection: some View {
        if !stats.byTrigger.isEmpty {
            Section("By trigger (all time)") {
                ForEach(stats.byTrigger, id: \.trigger) { row in
                    LabeledContent(row.trigger.displayName) {
                        Text("\(row.count) · \(row.samples.compactString) samples")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var recentSection: some View {
        Section("Recent wakes") {
            if model.wakeRecords.isEmpty {
                Text("No wakes recorded yet.").foregroundStyle(.secondary)
            } else {
                ForEach(model.wakeRecords.reversed()) { record in
                    WakeRow(record: record)
                }
            }
        }
    }
}

private struct WakeRow: View {
    let record: WakeRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(record.trigger.displayName)
                    .font(.caption.bold())
                    .foregroundStyle(record.trigger.isBackground ? Color.purple : Color.blue)
                outcomeBadge
                Spacer()
                Text(record.startedAt, format: .dateTime.month().day().hour().minute())
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            HStack(spacing: 12) {
                Text("\(record.samples.compactString) samples")
                if record.deletions > 0 { Text("\(record.deletions) del") }
                if let d = record.duration { Text(d.shortDuration) }
                Text(record.bytes.byteString)
            }
            .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                if let gap = record.gapSinceLastWake {
                    Text("after \(gap.shortDuration)")
                }
                if record.lowPowerMode { Label("Low Power", systemImage: "battery.25") }
                if record.thermalState != "nominal" {
                    Label(record.thermalState, systemImage: "thermometer.medium")
                }
            }
            .font(.caption2).foregroundStyle(.tertiary)
            if let detail = record.detail, !detail.isEmpty {
                Text(detail).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var outcomeBadge: some View {
        switch record.outcome {
        case .completed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).imageScale(.small)
        case .running:
            ProgressView().controlSize(.mini)
        case .expired:
            Text("EXPIRED").font(.caption2.bold()).foregroundStyle(.orange)
        case .interrupted:
            Text("INTERRUPTED").font(.caption2.bold()).foregroundStyle(.orange)
        case .failed:
            Text("FAILED").font(.caption2.bold()).foregroundStyle(.red)
        case .skippedLocked:
            Text("LOCKED").font(.caption2.bold()).foregroundStyle(.secondary)
        }
    }
}

/// On-device rollups of the wake records, so the screen is useful without an
/// export round-trip.
private struct WakeStats {
    let last24h: Int
    let last7d: Int
    let background24h: Int
    let cutShort: Int
    let totalSamples: Int
    let medianBackgroundGap: TimeInterval?
    let lastBackgroundWake: Date?
    let byTrigger: [(trigger: WakeTrigger, count: Int, samples: Int)]

    init(_ records: [WakeRecord]) {
        let now = Date()
        let dayAgo = now.addingTimeInterval(-86_400)
        let weekAgo = now.addingTimeInterval(-7 * 86_400)
        last24h = records.count { $0.startedAt >= dayAgo }
        last7d = records.count { $0.startedAt >= weekAgo }
        let background = records
            .filter { $0.trigger.isBackground }
            .sorted { $0.startedAt < $1.startedAt }
        background24h = background.count { $0.startedAt >= dayAgo }
        cutShort = records.count { $0.outcome == .expired || $0.outcome == .interrupted }
        totalSamples = records.reduce(0) { $0 + $1.samples }
        lastBackgroundWake = background.last?.startedAt
        let gaps = zip(background.dropFirst(), background)
            .map { later, earlier in later.startedAt.timeIntervalSince(earlier.startedAt) }
            .sorted()
        if gaps.isEmpty {
            medianBackgroundGap = nil
        } else if gaps.count.isMultiple(of: 2) {
            let upper = gaps.count / 2
            medianBackgroundGap = (gaps[upper - 1] + gaps[upper]) / 2
        } else {
            medianBackgroundGap = gaps[gaps.count / 2]
        }
        byTrigger = WakeTrigger.allCases.compactMap { trigger in
            let matching = records.filter { $0.trigger == trigger }
            guard !matching.isEmpty else { return nil }
            return (trigger, matching.count, matching.reduce(0) { $0 + $1.samples })
        }
    }
}
