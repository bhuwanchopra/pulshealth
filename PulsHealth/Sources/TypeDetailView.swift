import SwiftUI
import PulsHealthSync

/// Sync → type: everything we know about one type's sync state. A header
/// (icon, name, what it is doing now) over `TypeSyncDetailsSections`, which
/// the Type page can embed on its own under "Sync details".
struct TypeDetailView: View {
    let status: TypeSyncStatus

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    TypeIcon(status.descriptor, size: .large)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(status.descriptor.displayName)
                            .font(.title3.weight(.semibold))
                        StatusPill(text: status.activity.label, color: status.activity.color)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
            }
            TypeSyncDetailsSections(status: status)
        }
        .navigationTitle(status.descriptor.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }
}

extension TypeSyncStatus.Activity {
    /// The word a person reads, not the enum case.
    var label: String {
        switch self {
        case .idle: "Idle"
        case .backfilling: "Backfilling"
        case .syncing: "Syncing"
        case .failed: "Failed"
        }
    }

    var color: Color {
        switch self {
        case .idle: .secondary
        case .backfilling, .syncing: .accentColor
        case .failed: .red
        }
    }
}

/// The per-type sync sections, as `Section`s for a `List` or `Form`: Status,
/// Volume, Timeline, Server (when the server reports stats or a reconciliation
/// ran), the last error, and the actions. No header and no title, so a host
/// can put them under its own (`TypeDetailView`) or inside a `DisclosureGroup`.
/// Self-contained: the server stats refresh and the reset confirmation are
/// attached here, not to the host.
struct TypeSyncDetailsSections: View {
    @Environment(AppModel.self) private var model
    let status: TypeSyncStatus
    @State private var confirmReset = false

    private var state: TypeSyncState { status.state }
    private var isActivitySummary: Bool { HealthTypeCatalog.isActivitySummary(status.id) }

    /// Reconciliation needs a kind the engine can digest *and* a server that
    /// advertises `digest` + `uuids`; unknown capabilities hide the control.
    private var supportsReconciliation: Bool {
        [.quantity, .category, .workout].contains(status.descriptor.kind)
            && model.serverSupportsReconciliation
    }

    @ViewBuilder var body: some View {
        Section("Status") {
            LabeledContent("Backfill complete", value: state.backfillComplete ? "Yes" : "No")
            LabeledContent(isActivitySummary ? "Day watermark" : "Anchor") {
                if isActivitySummary {
                    Text(state.latestExported?.formatted(date: .abbreviated, time: .omitted) ?? "none")
                        .foregroundStyle(state.latestExported == nil ? .secondary : .primary)
                } else if let anchorData = state.anchorData {
                    Text("\(anchorData.count) bytes").monospacedDigit()
                } else {
                    Text("none (will export from start date)")
                        .foregroundStyle(.secondary)
                }
            }
            if let rate = status.currentRate {
                LabeledContent("Current rate", value: "\(Int(rate)) samples/s")
            }
            if let eta = status.estimatedSecondsRemaining {
                LabeledContent("Backfill ETA", value: eta.shortDuration)
            }
        }
        .task { if model.serverSupportsStats { await model.refreshServerStats() } }
        .onChange(of: model.serverSupportsStats) { _, supported in
            if supported { Task { await model.refreshServerStats() } }
        }

        Section("Volume") {
            LabeledContent(
                isActivitySummary ? "Days exported" : "Samples exported",
                value: state.totalSamplesExported.formatted())
            if !isActivitySummary {
                LabeledContent("Deletions exported", value: state.totalDeletionsExported.formatted())
            }
            LabeledContent("Batches uploaded", value: state.totalBatchesUploaded.formatted())
            LabeledContent("Bytes uploaded (gzip)", value: state.totalBytesUploaded.byteString)
            if state.totalBatchesUploaded > 0 {
                LabeledContent(
                    "Avg batch size",
                    value: (state.totalSamplesExported / max(1, state.totalBatchesUploaded)).formatted()
                )
            }
        }

        Section("Timeline") {
            LabeledContent("Earliest sample", value: state.earliestExported?.formatted() ?? "None")
            LabeledContent("Latest sample", value: state.latestExported?.formatted() ?? "None")
            LabeledContent("Last sync", value: state.lastSyncAt.map { "\($0.formatted()) (\($0.relativeString))" } ?? "Never")
            if let duration = state.lastSyncDuration {
                LabeledContent("Last batch duration", value: duration.shortDuration)
            }
            // Only a server that reports its counts fills these in, and
            // only for a batch that carried this type alone.
            if let accepted = state.lastBatchAccepted {
                LabeledContent("Last batch new in database", value: accepted.formatted())
            }
            if let duplicates = state.lastBatchDuplicates {
                LabeledContent("Last batch already in database", value: duplicates.formatted())
            }
            if let latency = state.lastObservedLatency {
                LabeledContent("Sample to upload latency", value: latency.shortDuration)
            }
        }

        // Server-side rows come from GET /v1/stats, which only a server
        // advertising `stats` offers; a past reconciliation stays visible.
        if model.serverSupportsStats || state.lastReconcileAt != nil {
            Section("Database") {
                if model.serverSupportsStats {
                    if let stats = model.serverStats[status.id] {
                        LabeledContent("Rows in database") {
                            Text(Int(stats.rows).formatted()).monospacedDigit()
                        }
                        LabeledContent("Batches received", value: Int(stats.batches).formatted())
                        LabeledContent("Earliest row", value: stats.earliest?.formatted() ?? "None")
                        LabeledContent("Latest row", value: stats.latest?.formatted() ?? "None")
                        if let at = stats.lastBatchAt {
                            LabeledContent("Last batch", value: "\(at.formatted()) (\(at.relativeString))")
                        }
                    } else if let error = model.serverStatsError {
                        Text("Stats unavailable: \(error)").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("No rows for this type yet").foregroundStyle(.secondary)
                    }
                }
                if let at = state.lastReconcileAt {
                    LabeledContent("Last reconciliation") {
                        VStack(alignment: .trailing) {
                            Text(at.relativeString)
                            if let summary = state.lastReconcileSummary {
                                Text(summary).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }

        if let error = state.lastError {
            Section("Last error") {
                Text(error).font(.caption).foregroundStyle(.red)
                if let at = state.lastErrorAt {
                    LabeledContent("At", value: at.formatted())
                }
            }
        }

        Section {
            Button("Sync This Type Now") {
                Task { await model.syncOne(status.id) }
            }
            if supportsReconciliation {
                Button {
                    Task { await model.reconcile(status.id) }
                } label: {
                    if model.reconciling.contains(status.id) {
                        HStack {
                            Text("Reconciling…")
                            Spacer()
                            ProgressView()
                        }
                    } else {
                        Text("Reconcile with Database")
                    }
                }
                .disabled(model.reconciling.contains(status.id))
            }
            Button(
                isActivitySummary
                    ? "Reset Progress (recompute everything)"
                    : "Reset Anchor (re-export everything)",
                role: .destructive
            ) {
                confirmReset = true
            }
            // A reset under a running sync is undone by that run's next
            // state write; the engine refuses it, and the button says so.
            .disabled(status.activity != .idle)
            // On the button, not the sections: a modifier on the whole
            // builder would attach one dialog per section.
            .confirmationDialog(
                isActivitySummary
                    ? "Recompute all \(status.descriptor.displayName) data from the start date? Existing days are safely updated in your database."
                    : "Re-export all \(status.descriptor.displayName) data from the start date? Your database skips samples it already has, so this is safe but slow.",
                isPresented: $confirmReset, titleVisibility: .visible
            ) {
                Button(isActivitySummary ? "Reset Progress" : "Reset Anchor", role: .destructive) {
                    Task { await model.resetType(status.id) }
                }
            }
        } header: {
            Text("Actions")
        } footer: {
            if supportsReconciliation {
                Text("Reconciliation compares per-month sample digests with your database, re-uploads anything missing, and removes orphans left by purged deletion tombstones. A month Health returns nothing for is left alone: a type whose Health access is off reads the same as one with no data.")
            }
        }
    }
}
