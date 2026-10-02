import SwiftUI
import PulsHealthSync

/// Named starting selections. `common` is what the Synced Data menu's "Enable
/// Common Set" applies and what first-run onboarding preselects, so the two
/// cannot drift apart.
enum TypePresets {
    static let common: Set<String> = [
        "HKQuantityTypeIdentifierStepCount",
        "HKQuantityTypeIdentifierHeartRate",
        "HKQuantityTypeIdentifierRestingHeartRate",
        "HKQuantityTypeIdentifierHeartRateVariabilitySDNN",
        "HKQuantityTypeIdentifierActiveEnergyBurned",
        "HKQuantityTypeIdentifierBasalEnergyBurned",
        "HKQuantityTypeIdentifierDistanceWalkingRunning",
        "HKQuantityTypeIdentifierAppleExerciseTime",
        "HKQuantityTypeIdentifierRespiratoryRate",
        "HKQuantityTypeIdentifierOxygenSaturation",
        "HKQuantityTypeIdentifierVO2Max",
        "HKQuantityTypeIdentifierBodyMass",
        "HKCategoryTypeIdentifierSleepAnalysis",
        HealthTypeCatalog.workoutIdentifier,
    ]
}

/// Sync → Synced Data, structured like Apple Health's Browse screen: a
/// category list with colored icons that drills into per-category toggle
/// pages, plus search across every type.
struct TypePickerView: View {
    @Environment(AppModel.self) private var model
    @State private var searchText = ""

    var body: some View {
        List {
            if searchText.isEmpty {
                categoriesSection
            } else {
                searchResultsSection
            }
        }
        .navigationTitle("Synced Data")
        .searchable(
            text: $searchText, placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search data types")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Enable Common Set", systemImage: "star") { enableCommon() }
                    Button("Enable All", systemImage: "checkmark.circle") { enableAll() }
                    Button("Disable All", systemImage: "xmark.circle", role: .destructive) {
                        model.config.enabledTypes = []
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }

    private var categoriesSection: some View {
        Section {
            ForEach(HealthTypeDescriptor.Group.allCases, id: \.self) { group in
                let types = HealthTypeCatalog.all.filter { $0.group == group }
                if !types.isEmpty {
                    NavigationLink {
                        TypeCategoryView(group: group, types: types)
                    } label: {
                        categoryRow(group, types: types)
                    }
                }
            }
        } header: {
            Text("Health Categories")
        } footer: {
            Text("\(model.config.enabledTypes.count) of \(HealthTypeCatalog.all.count) types enabled. Changes are staged — tap Apply to start syncing the new selection.")
        }
    }

    private func categoryRow(_ group: HealthTypeDescriptor.Group, types: [HealthTypeDescriptor]) -> some View {
        let enabled = types.count { model.config.enabledTypes.contains($0.identifier) }
        return HStack(spacing: 12) {
            Image(systemName: group.symbol)
                .font(.body)
                .foregroundStyle(group.color)
                .frame(width: 28)
            Text(group.rawValue)
                .fontWeight(.semibold)
                .foregroundStyle(group.color)
            Spacer()
            if enabled > 0 {
                Text("\(enabled) of \(types.count)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var searchResultsSection: some View {
        let matches = HealthTypeCatalog.all.filter {
            $0.displayName.localizedCaseInsensitiveContains(searchText)
                || $0.group.rawValue.localizedCaseInsensitiveContains(searchText)
                || $0.identifier.localizedCaseInsensitiveContains(searchText)
        }
        let routeMatches = "Workout Routes".localizedCaseInsensitiveContains(searchText)
        let enhancedMatches = "Enhanced Workout Data".localizedCaseInsensitiveContains(searchText)
        return Section {
            if matches.isEmpty && !routeMatches && !enhancedMatches {
                ContentUnavailableView.search(text: searchText)
            } else {
                ForEach(matches) { descriptor in
                    if descriptor.kind == .quantity {
                        TypeConfigLinkRow(descriptor: descriptor, showsCategory: true)
                    } else {
                        TypeToggleRow(descriptor: descriptor, showsCategory: true)
                    }
                }
                if routeMatches {
                    WorkoutRoutesToggleRow(showsCategory: true)
                }
                if enhancedMatches {
                    WorkoutEnhancedDataToggleRow(showsCategory: true)
                }
            }
        }
    }

    private func enableCommon() {
        model.config.enabledTypes = TypePresets.common
    }

    private func enableAll() {
        model.config.enabledTypes = Set(HealthTypeCatalog.all.map(\.identifier))
    }
}

/// One category's toggle list (Apple Health category page).
struct TypeCategoryView: View {
    @Environment(AppModel.self) private var model
    let group: HealthTypeDescriptor.Group
    let types: [HealthTypeDescriptor]

    var body: some View {
        List {
            Section {
                ForEach(types) { descriptor in
                    if descriptor.kind == .quantity {
                        TypeConfigLinkRow(descriptor: descriptor, showsCategory: false)
                    } else {
                        TypeToggleRow(descriptor: descriptor, showsCategory: false)
                    }
                }
                if group == .workouts {
                    WorkoutRoutesToggleRow(showsCategory: false)
                    WorkoutEnhancedDataToggleRow(showsCategory: false)
                }
            } header: {
                let enabled = types.count { model.config.enabledTypes.contains($0.identifier) }
                Text("\(enabled) of \(types.count) enabled")
            } footer: {
                if group == .workouts {
                    Text("Workout Routes attaches the GPS path to each exported workout. Enhanced Data adds the intra-workout heart-rate / power / cadence / speed curves, per-metric min/avg/max, lap & segment markers, multi-sport splits, and your age (for heart-rate zones). Both apply only to workouts synced from then on; effort scores are always included.")
                }
            }
        }
        .navigationTitle(group.rawValue)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Enable All in \(group.rawValue)", systemImage: "checkmark.circle") {
                        model.config.enabledTypes.formUnion(types.map(\.identifier))
                    }
                    Button("Disable All in \(group.rawValue)", systemImage: "xmark.circle", role: .destructive) {
                        model.config.enabledTypes.subtract(types.map(\.identifier))
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }
}

/// Chevron row for quantity types: drills into the per-type config screen
/// (raw toggle + aggregates), with a trailing raw/aggregate summary. A Toggle
/// inside a NavigationLink label is awkward in Lists, so the raw toggle lives
/// inside TypeConfigView.
private struct TypeConfigLinkRow: View {
    @Environment(AppModel.self) private var model
    let descriptor: HealthTypeDescriptor
    let showsCategory: Bool

    var body: some View {
        NavigationLink {
            TypeConfigView(descriptor: descriptor)
        } label: {
            HStack(spacing: 12) {
                TypeIcon(descriptor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(descriptor.displayName)
                    if showsCategory {
                        Text(descriptor.group.rawValue)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var summary: String {
        let raw = model.config.enabledTypes.contains(descriptor.identifier) ? "On" : "Off"
        let aggregates = model.aggregates(for: descriptor.identifier).count
        return aggregates > 0 ? "\(raw) · \(aggregates) agg" : raw
    }
}

/// A single data-type toggle with its colored Health-style icon.
private struct TypeToggleRow: View {
    @Environment(AppModel.self) private var model
    let descriptor: HealthTypeDescriptor
    let showsCategory: Bool

    var body: some View {
        Toggle(isOn: binding) {
            HStack(spacing: 12) {
                TypeIcon(descriptor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(descriptor.displayName)
                    if showsCategory {
                        Text(descriptor.group.rawValue)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var binding: Binding<Bool> {
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
}

/// Toggle for `SyncConfiguration.includeWorkoutRoutes` — routes aren't a catalog
/// type (they ride along with workout payloads), so this row binds to the config
/// flag instead of `enabledTypes`.
private struct WorkoutRoutesToggleRow: View {
    @Environment(AppModel.self) private var model
    let showsCategory: Bool

    var body: some View {
        Toggle(isOn: binding) {
            HStack(spacing: 12) {
                TypeIcon(symbol: "map.fill", color: HealthTypeDescriptor.Group.workouts.color)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Workout Routes")
                    if showsCategory {
                        Text(HealthTypeDescriptor.Group.workouts.rawValue)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var binding: Binding<Bool> {
        Binding(
            get: { model.config.includeWorkoutRoutes },
            set: { enabled in
                model.config.includeWorkoutRoutes = enabled
            }
        )
    }
}

/// Toggle for `SyncConfiguration.includeWorkoutEnhancedData` — the intra-workout
/// streams, detailed stats, events, and sub-activities that power the rich
/// workout view. Like routes, this rides with workout payloads, so it binds to
/// the config flag rather than `enabledTypes`.
private struct WorkoutEnhancedDataToggleRow: View {
    @Environment(AppModel.self) private var model
    let showsCategory: Bool

    var body: some View {
        Toggle(isOn: binding) {
            HStack(spacing: 12) {
                TypeIcon(symbol: "waveform.path.ecg", color: HealthTypeDescriptor.Group.workouts.color)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Enhanced Data")
                    if showsCategory {
                        Text(HealthTypeDescriptor.Group.workouts.rawValue)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var binding: Binding<Bool> {
        Binding(
            get: { model.config.includeWorkoutEnhancedData },
            set: { enabled in
                model.config.includeWorkoutEnhancedData = enabled
            }
        )
    }
}

/// Floating Apply/Discard bar shown on the Sync tab while the staged
/// configuration draft differs from what's applied to the engine. Nothing the
/// user toggles on the Synced Data screen — raw types, aggregates, workout
/// routes — reaches the sync engine or starts backfilling until they tap Apply.
struct PendingChangesBar: View {
    @Environment(AppModel.self) private var model
    @State private var applying = false

    var body: some View {
        Group {
            if model.hasPendingChanges {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Unapplied changes")
                            .font(.subheadline.weight(.semibold))
                        Text(model.pendingChangesSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Button("Discard", role: .destructive) {
                        model.discardChanges()
                    }
                    .buttonStyle(.bordered)
                    .disabled(applying)
                    Button {
                        applying = true
                        Task {
                            await model.applyChanges()
                            applying = false
                        }
                    } label: {
                        if applying {
                            ProgressView().frame(minWidth: 44)
                        } else {
                            Text("Apply").frame(minWidth: 44)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(applying)
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
                .background(.bar)
                .overlay(alignment: .top) { Divider() }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: model.hasPendingChanges)
    }
}
