import SwiftUI
import PulsHealthSync

// The Export tab's aggregate series: the row the tab lists them with, the
// editor sheet that adds or changes one, and the quick-add presets. All of it
// edits `ExportModel.draft` and nothing else: these series are the export's
// own, and `AggregateEditorView` (the sync's editor, with its Sync Now and
// Recompute paths) is not involved.

/// One series in the draft: the type's icon, "Average · 1 hour", the type's name.
struct ExportSeriesRow: View {
    let config: AggregateConfig

    var body: some View {
        let descriptor = HealthTypeCatalog.descriptor(for: config.typeIdentifier)
        HStack(spacing: 12) {
            if let descriptor {
                TypeIcon(descriptor)
            } else {
                TypeIcon(symbol: "sum", color: .secondary)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(config.summaryLabel)
                Text(descriptor?.displayName ?? config.typeIdentifier)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// The series one tap away: shown as chips at the top of the Add Series
/// sheet. Each is offered only when its type is a quantity type this OS's
/// catalog knows and the function is legal for it.
struct ExportQuickSeries: Identifiable {
    let title: String
    let typeIdentifier: String
    let function: AggregateFunction
    let intervalUnit: AggregateIntervalUnit

    var id: String { config.seriesIdentity }

    var config: AggregateConfig {
        AggregateConfig(
            typeIdentifier: typeIdentifier, function: function,
            intervalValue: 1, intervalUnit: intervalUnit, deviceFilter: .all,
            startDate: nil, settleDelay: 3_600, enabled: true)
    }

    static let all: [ExportQuickSeries] = [
        ExportQuickSeries(
            title: "Hourly steps",
            typeIdentifier: "HKQuantityTypeIdentifierStepCount",
            function: .sum, intervalUnit: .hour),
        ExportQuickSeries(
            title: "Daily active energy",
            typeIdentifier: "HKQuantityTypeIdentifierActiveEnergyBurned",
            function: .sum, intervalUnit: .day),
        ExportQuickSeries(
            title: "Daily resting heart rate",
            typeIdentifier: "HKQuantityTypeIdentifierRestingHeartRate",
            function: .average, intervalUnit: .day),
        ExportQuickSeries(
            title: "Hourly heart rate average",
            typeIdentifier: "HKQuantityTypeIdentifierHeartRate",
            function: .average, intervalUnit: .hour),
    ]

    /// The presets this OS can compute.
    static var available: [ExportQuickSeries] {
        all.filter { preset in
            guard let descriptor = HealthTypeCatalog.descriptor(for: preset.typeIdentifier),
                  descriptor.kind == .quantity, descriptor.isAvailableOnThisOS
            else { return false }
            return HealthTypeCatalog.allowedAggregateFunctions(for: preset.typeIdentifier)
                .contains(preset.function)
        }
    }
}

/// Add or edit one series of the export draft. Presented as a sheet; nothing
/// is written to the draft until Add / Save.
struct ExportSeriesEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    /// The series being edited, or nil for a new one.
    private let existing: AggregateConfig?
    @State private var typeIdentifier: String?
    @State private var function: AggregateFunction = .average
    @State private var intervalValue = 1
    @State private var intervalUnit: AggregateIntervalUnit = .hour
    @State private var deviceFilter: AggregateDeviceFilter = .all
    /// Custom was chosen on the interval picker, so the stepper and unit stay
    /// up even while the values happen to match a preset.
    @State private var customInterval = false

    init(editing config: AggregateConfig? = nil) {
        existing = config
        if let config {
            _typeIdentifier = State(initialValue: config.typeIdentifier)
            _function = State(initialValue: config.function)
            _intervalValue = State(initialValue: config.intervalValue)
            _intervalUnit = State(initialValue: config.intervalUnit)
            _deviceFilter = State(initialValue: config.deviceFilter)
            _customInterval = State(initialValue: IntervalChoice(value: config.intervalValue, unit: config.intervalUnit) == .custom)
        }
    }

    private var isNew: Bool { existing == nil }

    private var descriptor: HealthTypeDescriptor? {
        typeIdentifier.flatMap { HealthTypeCatalog.descriptor(for: $0) }
    }

    private var allowedFunctions: [AggregateFunction] {
        typeIdentifier.map { HealthTypeCatalog.allowedAggregateFunctions(for: $0) } ?? []
    }

    private var draftConfig: AggregateConfig? {
        guard let typeIdentifier, allowedFunctions.contains(function) else { return nil }
        return AggregateConfig(
            id: existing?.id ?? UUID(),
            typeIdentifier: typeIdentifier, function: function,
            intervalValue: intervalValue, intervalUnit: intervalUnit,
            deviceFilter: deviceFilter,
            startDate: nil, settleDelay: existing?.settleDelay ?? 3_600, enabled: true)
    }

    var body: some View {
        NavigationStack {
            Form {
                if isNew {
                    quickAddSection
                }
                typeSection
                if typeIdentifier != nil {
                    seriesSection
                }
            }
            .navigationTitle(isNew ? "Add Series" : "Edit Series")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Add" : "Save") {
                        guard let config = draftConfig else { return }
                        if isNew {
                            model.export.addAggregate(config)
                        } else {
                            model.export.updateAggregate(config)
                        }
                        dismiss()
                    }
                    .disabled(draftConfig == nil)
                }
            }
        }
    }

    private var quickAddSection: some View {
        let presets = ExportQuickSeries.available
        let present = Set(model.export.draft.aggregates.map(\.seriesIdentity))
        return Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(presets) { preset in
                        Button(preset.title) {
                            model.export.addAggregate(preset.config)
                            dismiss()
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .controlSize(.small)
                        .disabled(present.contains(preset.id))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            }
            .listRowInsets(EdgeInsets())
        } header: {
            Text("Quick add")
        }
    }

    private var typeSection: some View {
        Section {
            NavigationLink {
                ExportSeriesTypeList(selected: typeIdentifier) { chosen in
                    choose(type: chosen)
                }
            } label: {
                HStack(spacing: 12) {
                    if let descriptor {
                        TypeIcon(descriptor)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(descriptor.displayName)
                            Text(descriptor.group.rawValue)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Choose a data type")
                    }
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("Data type")
        } footer: {
            if typeIdentifier == nil {
                Text("Series are computed for quantity types only: steps, heart rate, energy, and the like.")
            }
        }
    }

    private var seriesSection: some View {
        Section {
            Picker("Function", selection: $function) {
                ForEach(allowedFunctions) { function in
                    Text(function.displayName).tag(function)
                }
            }
            Picker("Interval", selection: intervalChoice) {
                ForEach(IntervalChoice.allCases) { choice in
                    Text(choice.title).tag(choice)
                }
            }
            .pickerStyle(.menu)
            if customInterval {
                Stepper(value: $intervalValue, in: 1...999) {
                    LabeledContent("Every", value: intervalLabel)
                }
                Picker("Unit", selection: $intervalUnit) {
                    ForEach(AggregateIntervalUnit.allCases) { unit in
                        Text(unit.displayName).tag(unit)
                    }
                }
            }
            Picker("Devices", selection: $deviceFilter) {
                ForEach(AggregateDeviceFilter.allCases) { filter in
                    Text(filter.displayName).tag(filter)
                }
            }
        } header: {
            Text("Series")
        } footer: {
            Text("One value per bucket, computed by HealthKit on this iPhone. Unit: \(unitString).")
        }
    }

    private var unitString: String {
        function == .duration ? "s" : (descriptor?.unitString ?? "none")
    }

    private var intervalLabel: String {
        let unit = intervalUnit.displayName.lowercased()
        return intervalValue == 1 ? "1 \(unit)" : "\(intervalValue) \(unit)s"
    }

    private var intervalChoice: Binding<IntervalChoice> {
        Binding(
            get: {
                customInterval ? .custom : IntervalChoice(value: intervalValue, unit: intervalUnit)
            },
            set: { choice in
                customInterval = choice == .custom
                if let (value, unit) = choice.interval {
                    intervalValue = value
                    intervalUnit = unit
                }
            }
        )
    }

    private func choose(type identifier: String) {
        let allowed = HealthTypeCatalog.allowedAggregateFunctions(for: identifier)
        guard !allowed.isEmpty else { return }
        let changed = identifier != typeIdentifier
        typeIdentifier = identifier
        if !allowed.contains(function) {
            function = allowed.first ?? function
        }
        // A new type's natural grain, as the sync editor picks it: totals
        // by the day for cumulative types, values by the hour for the rest.
        if changed, !customInterval, isNew {
            intervalValue = 1
            intervalUnit = allowed.contains(.sum) ? .day : .hour
        }
    }

    /// The interval picker's choices: four calendar grains and Custom.
    enum IntervalChoice: Hashable, CaseIterable, Identifiable {
        case hourly, daily, weekly, monthly, custom

        var id: Self { self }

        init(value: Int, unit: AggregateIntervalUnit) {
            switch (value, unit) {
            case (1, .hour): self = .hourly
            case (1, .day): self = .daily
            case (1, .week): self = .weekly
            case (1, .month): self = .monthly
            default: self = .custom
            }
        }

        var title: String {
            switch self {
            case .hourly: "Hourly"
            case .daily: "Daily"
            case .weekly: "Weekly"
            case .monthly: "Monthly"
            case .custom: "Custom"
            }
        }

        var interval: (Int, AggregateIntervalUnit)? {
            switch self {
            case .hourly: (1, .hour)
            case .daily: (1, .day)
            case .weekly: (1, .week)
            case .monthly: (1, .month)
            case .custom: nil
            }
        }
    }
}

/// The quantity types a series can be computed for, by category, searchable.
/// Picking one hands it back and pops.
private struct ExportSeriesTypeList: View {
    @Environment(\.dismiss) private var dismiss
    let selected: String?
    let onChoose: (String) -> Void
    @State private var searchText = ""

    private var candidates: [HealthTypeDescriptor] {
        HealthTypeCatalog.all.filter {
            $0.kind == .quantity && !HealthTypeCatalog.allowedAggregateFunctions(for: $0.identifier).isEmpty
        }
    }

    var body: some View {
        List {
            if searchText.isEmpty {
                ForEach(HealthTypeDescriptor.Group.allCases, id: \.self) { group in
                    let types = candidates.filter { $0.group == group }
                    if !types.isEmpty {
                        Section(group.rawValue) {
                            ForEach(types) { row($0) }
                        }
                    }
                }
            } else {
                let matches = candidates.filter {
                    $0.displayName.localizedCaseInsensitiveContains(searchText)
                        || $0.group.rawValue.localizedCaseInsensitiveContains(searchText)
                }
                if matches.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    ForEach(matches) { row($0) }
                }
            }
        }
        .navigationTitle("Data Type")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: $searchText, placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search quantity types")
    }

    private func row(_ descriptor: HealthTypeDescriptor) -> some View {
        Button {
            onChoose(descriptor.identifier)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                TypeIcon(descriptor)
                Text(descriptor.displayName)
                    .foregroundStyle(.primary)
                Spacer()
                if descriptor.identifier == selected {
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
    }
}
