import SwiftUI
import PulsHealthSync

/// Per-type configuration screen reached from the Synced Data lists: raw-sample
/// toggle plus the list of configured aggregate series for quantity types.
struct TypeConfigView: View {
    @Environment(AppModel.self) private var model
    let descriptor: HealthTypeDescriptor

    /// Freshly added draft to push its editor programmatically.
    @State private var newAggregate: AggregateConfig?

    private var allowedFunctions: [AggregateFunction] {
        HealthTypeCatalog.allowedAggregateFunctions(for: descriptor.identifier)
    }

    var body: some View {
        List {
            rawSamplesSection
            if !allowedFunctions.isEmpty {
                aggregatesSection
            }
            detailSection
        }
        .navigationTitle(descriptor.displayName)
        .navigationDestination(
            isPresented: Binding(
                get: { newAggregate != nil },
                set: { if !$0 { newAggregate = nil } }
            )
        ) {
            if let draft = newAggregate {
                AggregateEditorView(config: draft)
            }
        }
    }

    private var rawSamplesSection: some View {
        Section {
            Toggle(isOn: rawSamplesBinding) {
                HStack(spacing: 12) {
                    Image(systemName: descriptor.symbol)
                        .font(.body)
                        .foregroundStyle(descriptor.group.color)
                        .frame(width: 28)
                    Text("Sync raw samples")
                }
            }
            .padding(.vertical, 2)
        } header: {
            Text("Raw Samples")
        } footer: {
            Text("Raw sync exports every individual sample. Aggregates upload only computed bucket values (e.g. hourly averages) — much less data for high-volume types.")
        }
    }

    private var aggregatesSection: some View {
        Section {
            ForEach(model.aggregates(for: descriptor.identifier)) { config in
                NavigationLink {
                    AggregateEditorView(config: config)
                } label: {
                    AggregateConfigRow(config: config, state: model.aggregateStates[config.id])
                }
            }
            Button {
                addAggregate()
            } label: {
                Label("Add Aggregate", systemImage: "plus")
            }
        } header: {
            Text("Aggregates")
        } footer: {
            Text("Aggregates are computed on-device by HealthKit into fixed calendar buckets and recomputed automatically as late data arrives (e.g. from Apple Watch).")
        }
    }

    /// Link to the raw-sync debug screen, mirroring how the dashboard reaches it.
    @ViewBuilder private var detailSection: some View {
        if descriptor.kind == .quantity,
           model.config.enabledTypes.contains(descriptor.identifier),
           let status = model.statuses.first(where: { $0.id == descriptor.identifier }) {
            Section {
                NavigationLink("Raw Sync Details") {
                    TypeDetailView(status: status)
                }
            }
        }
    }

    private var rawSamplesBinding: Binding<Bool> {
        Binding(
            get: { model.config.enabledTypes.contains(descriptor.identifier) },
            set: { enabled in
                if enabled {
                    model.config.enabledTypes.insert(descriptor.identifier)
                } else {
                    model.config.enabledTypes.remove(descriptor.identifier)
                }
            }
        )
    }

    private func addAggregate() {
        guard let function = allowedFunctions.first else { return }
        // Cumulative types (sum-style) default to daily totals; discrete types
        // (average-style) to hourly values.
        let draft = AggregateConfig(
            typeIdentifier: descriptor.identifier,
            function: function,
            intervalValue: 1,
            intervalUnit: allowedFunctions.contains(.sum) ? .day : .hour,
            deviceFilter: .all,
            startDate: nil,
            settleDelay: 3_600,
            enabled: true
        )
        model.addAggregate(draft)
        newAggregate = draft
    }
}

/// One configured aggregate series: summary label + sync status subtitle.
private struct AggregateConfigRow: View {
    let config: AggregateConfig
    let state: AggregateSyncState?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(config.summaryLabel)
            subtitle
                .font(.caption)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
        .opacity(config.enabled ? 1 : 0.4)
    }

    @ViewBuilder private var subtitle: some View {
        if !config.enabled {
            Text("Disabled").foregroundStyle(.secondary)
        } else if let error = state?.lastError {
            Text(error).foregroundStyle(.red)
        } else if let through = state?.computedThrough {
            let computed = state?.lastComputedAt.map { " · \($0.relativeString)" } ?? ""
            Text("through \(through.formatted(date: .abbreviated, time: .shortened))\(computed)")
                .foregroundStyle(.secondary)
        } else {
            Text("waiting for first sync").foregroundStyle(.secondary)
        }
    }
}

/// Editor for one aggregate config. Edits mutate the staged `model.config`
/// draft directly (the app's usual style) but don't reach the engine until the
/// Sync tab's Apply bar (or this screen's explicit Sync Now / Recompute
/// All) commits them. On apply, `AppModel` resets the watermark of any series
/// whose `seriesIdentity`/`startDate` changed so it recomputes from scratch.
struct AggregateEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private let configID: UUID
    /// Snapshot of the stored config when the editor opened, advanced on commit.
    @State private var original: AggregateConfig
    @State private var confirmRecompute = false
    @State private var confirmDelete = false

    init(config: AggregateConfig) {
        self.configID = config.id
        self._original = State(initialValue: config)
    }

    /// Live value in the model; falls back to the snapshot mid-dismissal after delete.
    private var current: AggregateConfig {
        model.config.aggregates.first { $0.id == configID } ?? original
    }

    private var allowedFunctions: [AggregateFunction] {
        HealthTypeCatalog.allowedAggregateFunctions(for: current.typeIdentifier)
    }

    private var state: AggregateSyncState? { model.aggregateStates[configID] }

    var body: some View {
        Form {
            seriesSection
            startDateSection
            settleSection
            Section {
                Toggle("Enabled", isOn: binding(\.enabled))
            } footer: {
                Text("Disabled aggregates keep their progress but stop computing and uploading.")
            }
            statusSection
            actionsSection
        }
        .navigationTitle(current.summaryLabel)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Recompute the entire series?",
            isPresented: $confirmRecompute, titleVisibility: .visible
        ) {
            Button("Recompute All", role: .destructive) {
                Task {
                    await model.applyChanges()
                    await model.resetAggregate(id: configID)
                    model.syncAggregate(id: configID)
                }
            }
        } message: {
            Text("Clears the local watermark and re-uploads every bucket from the start date. Your database replaces the buckets it already has, so this is safe but re-sends the whole series.")
        }
        .confirmationDialog(
            "Delete this aggregate?",
            isPresented: $confirmDelete, titleVisibility: .visible
        ) {
            Button("Delete Aggregate", role: .destructive) {
                model.deleteAggregate(id: configID)
                dismiss()
            }
        } message: {
            Text("Stops computing this series. Data already uploaded stays in your database.")
        }
    }

    private var seriesSection: some View {
        Section {
            Picker("Function", selection: binding(\.function)) {
                ForEach(allowedFunctions) { function in
                    Text(function.displayName).tag(function)
                }
            }
            Stepper(value: binding(\.intervalValue), in: 1...999) {
                LabeledContent("Interval", value: current.intervalLabel)
            }
            Picker("Interval unit", selection: binding(\.intervalUnit)) {
                ForEach(AggregateIntervalUnit.allCases) { unit in
                    Text(unit.displayName).tag(unit)
                }
            }
            Picker("Devices", selection: binding(\.deviceFilter)) {
                ForEach(AggregateDeviceFilter.allCases) { filter in
                    Text(filter.displayName).tag(filter)
                }
            }
        } header: {
            Text("Series")
        } footer: {
            Text("Changing the function, interval, or device filter creates a different series in your database — it recomputes from scratch. Unit: \(current.unitString ?? "—").")
        }
    }

    private var startDateSection: some View {
        Section("Start date") {
            Toggle("Use global start date", isOn: useGlobalStartBinding)
            if current.startDate != nil {
                DatePicker(
                    "Compute from",
                    selection: startDateBinding,
                    in: ...Date(),
                    displayedComponents: .date
                )
            } else {
                LabeledContent(
                    "Compute from",
                    value: model.config.startDate.formatted(date: .abbreviated, time: .omitted)
                )
            }
        }
    }

    private var settleSection: some View {
        Section {
            Picker("Settle delay", selection: binding(\.settleDelay)) {
                Text("None").tag(TimeInterval(0))
                Text("5 minutes").tag(TimeInterval(300))
                Text("15 minutes").tag(TimeInterval(900))
                Text("1 hour").tag(TimeInterval(3_600))
                Text("6 hours").tag(TimeInterval(21_600))
                Text("24 hours").tag(TimeInterval(86_400))
            }
        } footer: {
            Text("Buckets ending within this window aren't uploaded yet, giving late-arriving Apple Watch data time to land first.")
        }
    }

    private var statusSection: some View {
        Section("Status") {
            LabeledContent(
                "Computed through",
                value: state?.computedThrough?.formatted() ?? "never"
            )
            LabeledContent(
                "Last computed",
                value: state?.lastComputedAt.map { "\($0.formatted()) (\($0.relativeString))" } ?? "never"
            )
            LabeledContent(
                "Buckets uploaded",
                value: (state?.totalBucketsUploaded ?? 0).formatted()
            )
            LabeledContent(
                "Bytes uploaded (gzip)",
                value: (state?.totalBytesUploaded ?? 0).byteString
            )
            if let error = state?.lastError {
                VStack(alignment: .leading, spacing: 2) {
                    Text(error).font(.caption).foregroundStyle(.red)
                    if let at = state?.lastErrorAt {
                        Text(at.formatted()).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var actionsSection: some View {
        Section {
            Button("Sync Now") {
                Task {
                    await model.applyChanges()
                    model.syncAggregate(id: configID)
                }
            }
            .disabled(!current.enabled)
            Button("Recompute All") {
                confirmRecompute = true
            }
            .disabled(!current.enabled)
            Button("Delete Aggregate", role: .destructive) {
                confirmDelete = true
            }
        }
    }

    // MARK: - Bindings

    private func binding<T>(_ keyPath: WritableKeyPath<AggregateConfig, T>) -> Binding<T> {
        Binding(
            get: { current[keyPath: keyPath] },
            set: { newValue in
                guard let index = model.config.aggregates.firstIndex(where: { $0.id == configID })
                else { return }
                model.config.aggregates[index][keyPath: keyPath] = newValue
            }
        )
    }

    private var useGlobalStartBinding: Binding<Bool> {
        Binding(
            get: { current.startDate == nil },
            set: { useGlobal in
                binding(\.startDate).wrappedValue =
                    useGlobal ? nil : (original.startDate ?? model.config.startDate)
            }
        )
    }

    private var startDateBinding: Binding<Date> {
        Binding(
            get: { current.startDate ?? model.config.startDate },
            set: { binding(\.startDate).wrappedValue = $0 }
        )
    }
}
