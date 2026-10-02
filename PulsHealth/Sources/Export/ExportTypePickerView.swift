import SwiftUI
import PulsHealthSync

/// Export → Data types: which types the export draft covers. The same shape as
/// the Synced Data browser (categories that drill into per-category lists,
/// search across every type), but with checkmarks rather than toggles and a
/// draft of its own: nothing chosen here touches the sync selection.
struct ExportTypePickerView: View {
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
        .navigationTitle("Data Types")
        .searchable(
            text: $searchText, placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search data types")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    let applied = model.appliedConfig.enabledTypes
                    Button("Synced Selection", systemImage: "arrow.triangle.2.circlepath") {
                        model.export.draft.types = applied
                    }
                    .disabled(applied.isEmpty)
                    Button("Common Set", systemImage: "star") {
                        model.export.draft.types = TypePresets.common
                    }
                    Button("All Types", systemImage: "checkmark.circle") {
                        model.export.draft.types = Set(HealthTypeCatalog.all.map(\.identifier))
                    }
                    Button("None", systemImage: "xmark.circle", role: .destructive) {
                        model.export.draft.types = []
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
                        ExportTypeCategoryView(group: group, types: types)
                    } label: {
                        categoryRow(group, types: types)
                    }
                }
            }
        } header: {
            Text("Health Categories")
        } footer: {
            Text("\(model.export.draft.types.count) of \(HealthTypeCatalog.all.count) types in this export. The sync selection is not changed.")
        }
    }

    private func categoryRow(_ group: HealthTypeDescriptor.Group, types: [HealthTypeDescriptor]) -> some View {
        let selected = types.count { model.export.draft.types.contains($0.identifier) }
        return HStack(spacing: 12) {
            TypeIcon(group)
            Text(group.rawValue)
                .fontWeight(.semibold)
            Spacer()
            if selected > 0 {
                Text("\(selected) of \(types.count)")
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
        return Section {
            if matches.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                ForEach(matches) { descriptor in
                    ExportTypeRow(descriptor: descriptor, showsCategory: true)
                }
            }
        }
    }
}

/// One category's checklist.
struct ExportTypeCategoryView: View {
    @Environment(AppModel.self) private var model
    let group: HealthTypeDescriptor.Group
    let types: [HealthTypeDescriptor]

    var body: some View {
        List {
            Section {
                ForEach(types) { descriptor in
                    ExportTypeRow(descriptor: descriptor, showsCategory: false)
                }
            } header: {
                let selected = types.count { model.export.draft.types.contains($0.identifier) }
                Text("\(selected) of \(types.count) selected")
            } footer: {
                if group == .workouts {
                    Text("Workout routes and enhanced workout data are switched on from the Export tab once Workouts is selected.")
                }
            }
        }
        .navigationTitle(group.rawValue)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Select All in \(group.rawValue)", systemImage: "checkmark.circle") {
                        model.export.draft.types.formUnion(types.map(\.identifier))
                    }
                    Button("Clear \(group.rawValue)", systemImage: "xmark.circle", role: .destructive) {
                        model.export.draft.types.subtract(types.map(\.identifier))
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }
}

/// A type with a checkmark; the whole row toggles it.
private struct ExportTypeRow: View {
    @Environment(AppModel.self) private var model
    let descriptor: HealthTypeDescriptor
    let showsCategory: Bool

    private var isSelected: Bool { model.export.draft.types.contains(descriptor.identifier) }

    var body: some View {
        Button {
            if isSelected {
                model.export.draft.types.remove(descriptor.identifier)
            } else {
                model.export.draft.types.insert(descriptor.identifier)
            }
        } label: {
            HStack(spacing: 12) {
                TypeIcon(descriptor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(descriptor.displayName)
                        .foregroundStyle(.primary)
                    if showsCategory {
                        Text(descriptor.group.rawValue)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "checkmark")
                    .fontWeight(.semibold)
                    .foregroundStyle(.tint)
                    .opacity(isSelected ? 1 : 0)
            }
            .contentShape(Rectangle())
        }
        // A default button in a List tints the whole label; this row is a
        // choice, not an action.
        .buttonStyle(.plain)
        .padding(.vertical, 2)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
