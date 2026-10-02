import SwiftUI
import PulsHealthSync

/// Screens the Explore tab pushes. `type` opens the per-type page
/// (`TypePageView`), which links on to the sync detail when the type is
/// synced.
enum ExploreRoute: Hashable {
    case type(String)
}

/// The home tab: the catalog by category, the way Apple Health's Browse
/// screen lays it out, with what HealthKit holds for each type from
/// `ExploreModel` — the cheap facts for every row, the profile for the ones
/// that have been analyzed. Every type opens its page, whether it is synced
/// or not; turning sync on is the Sync tab's job.
///
/// The two Health-access cards live here, not on Sync, because they are about
/// what the app may read at all, server or no server.
///
/// Each category collapses from its header, and the toolbar menu expands or
/// collapses them all, hides types HealthKit holds nothing for, and picks the
/// order inside a category. All three are view preferences in UserDefaults —
/// category names and a sort, never health data.
struct ExploreView: View {
    @Environment(AppModel.self) private var model
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool
    /// Collapsed categories, by raw name, comma-joined.
    @AppStorage("explore.collapsedGroups") private var collapsedGroups = ""
    @AppStorage("explore.hidesEmptyTypes") private var hidesEmptyTypes = false
    @AppStorage("explore.sort") private var sort = ExploreSort.dataFirst

    var body: some View {
        List {
            searchField
            if searchText.isEmpty {
                accessCards
                catalog
            } else {
                searchResults
            }
        }
        .scrollDismissesKeyboard(.immediately)
        .navigationTitle("Explore")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { optionsMenu }
        }
        .navigationDestination(for: ExploreRoute.self) { route in
            switch route {
            case .type(let id):
                TypePageView(identifier: id)
            }
        }
        .task {
            await model.explore.load()
            model.explore.refreshQuickFactsIfNeeded()
        }
        // The facts are read once per session; pulling re-reads them, so the
        // data-first order, Most Recent and the hidden types catch up.
        .refreshable { await model.explore.reloadQuickFacts() }
    }

    // MARK: - Search

    /// The list's first row, not `.searchable`: it sits under the large title
    /// and scrolls away with the content. A `.navigationBarDrawer` field can't
    /// do both on iOS 27 — `.automatic` starts collapsed until a pull down,
    /// and `.always` pins it and drops the large title — and the default
    /// placement is the bottom toolbar.
    private var searchField: some View {
        Section {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Search data types", text: $searchText)
                    .focused($searchFocused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                if !searchText.isEmpty {
                    Button("Clear Search", systemImage: "xmark.circle.fill") { searchText = "" }
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.secondary)
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .background(Color(.secondarySystemGroupedBackground), in: Capsule())
            .contentShape(Capsule())
            .onTapGesture { searchFocused = true }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }
        .listSectionSpacing(.compact)
    }

    // MARK: - Cards

    @ViewBuilder private var accessCards: some View {
        if model.needsAuthorization || !model.authorizationRequested {
            if model.authorizationRequested {
                CardSection(
                    "Health access incomplete",
                    subtitle: "Some enabled data types haven't been authorized yet, so their syncs will fail."
                ) {
                    // The Synced Data screen's Apply bar only appears while
                    // changes are staged, so in this exact situation (types
                    // added to the catalog after the first grant, or an
                    // interrupted permission sheet) there was no button to
                    // tap. Request access directly; the request is idempotent
                    // and skips determined types.
                    Button("Grant Health Access") {
                        Task { await model.requestAccessForEnabledTypesIfNeeded() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    authorizationHint
                }
            } else {
                CardSection(
                    "Health access not requested yet",
                    subtitle: "Opening a type asks for Health access to it, and nothing is read until you allow it."
                ) {
                    authorizationHint
                }
            }
        }

        // A read denial is invisible to HealthKit's own API — after the
        // sheet, granted and denied report the same status, and a denied
        // read returns an empty set rather than an error. So nothing above
        // this fires: no banner, no failed type, no error. Every enabled
        // type finishing a sync with zero samples is the only evidence
        // left, and without this the app just looks idle and healthy.
        if model.readsLookBlocked {
            CardSection(
                "No data is coming through",
                subtitle: "Every enabled type has synced and returned nothing. Either Apple Health has no data for them yet, or read access was declined — iOS doesn't tell apps which. Check Settings → Privacy & Security → Health → PulsHealth."
            ) {
                Button("Open Health Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    @ViewBuilder private var authorizationHint: some View {
        if let hint = model.authorizationHint {
            Text(hint)
                .font(.footnote)
                .foregroundStyle(.orange)
        }
    }

    // MARK: - Catalog

    private static let groups = HealthTypeDescriptor.Group.allCases

    @ViewBuilder private var catalog: some View {
        if Self.groups.allSatisfy({ visibleTypes(in: $0).isEmpty }) {
            // Only reachable with Hide Types Without Data on.
            ContentUnavailableView {
                Label("No Health Data", systemImage: "heart.text.square")
            } description: {
                Text("Apple Health has nothing for any type PulsHealth can read, or access hasn't been allowed.")
            } actions: {
                Button("Show All Types") { hidesEmptyTypes = false }
            }
        } else {
            ForEach(Self.groups, id: \.self) { group in
                categorySection(group, types: visibleTypes(in: group))
            }
            let hidden = hiddenCount
            if hidden > 0 {
                Section {
                    Button("Show \(hidden) Types Without Data") {
                        withAnimation { hidesEmptyTypes = false }
                    }
                }
            }
        }
    }

    @ViewBuilder private func categorySection(
        _ group: HealthTypeDescriptor.Group, types: [HealthTypeDescriptor]
    ) -> some View {
        if !types.isEmpty {
            let expanded = !collapsed.contains(group.rawValue)
            Section {
                if expanded {
                    ForEach(types) { descriptor in
                        typeRow(descriptor, showsCategory: false)
                    }
                }
            } header: {
                Button { toggle(group) } label: {
                    HStack(spacing: 8) {
                        TypeIcon(group, size: .small)
                        Text(group.rawValue)
                        Spacer()
                        Text("\(types.count)").monospacedDigit()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                .accessibilityHint(expanded ? "Hides this category's types" : "Shows this category's types")
            }
        }
    }

    private var optionsMenu: some View {
        let all = Set(Self.groups.map(\.rawValue))
        return Menu {
            Section {
                Button("Expand All", systemImage: "rectangle.expand.vertical") {
                    withAnimation { setCollapsed([]) }
                }
                .disabled(collapsed.isEmpty)
                Button("Collapse All", systemImage: "rectangle.compress.vertical") {
                    withAnimation { setCollapsed(all) }
                }
                .disabled(collapsed.isSuperset(of: all))
            }
            Section {
                Toggle("Hide Types Without Data", systemImage: "eye.slash", isOn: $hidesEmptyTypes.animation())
                Picker("Sort By", systemImage: "arrow.up.arrow.down", selection: $sort.animation()) {
                    ForEach(ExploreSort.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
            }
        } label: {
            Label("View Options", systemImage: "ellipsis.circle")
        }
    }

    private var collapsed: Set<String> {
        Set(collapsedGroups.split(separator: ",").map(String.init))
    }

    private func setCollapsed(_ groups: Set<String>) {
        collapsedGroups = groups.sorted().joined(separator: ",")
    }

    private func toggle(_ group: HealthTypeDescriptor.Group) {
        var groups = collapsed
        if groups.remove(group.rawValue) == nil { groups.insert(group.rawValue) }
        withAnimation { setCollapsed(groups) }
    }

    /// A category's rows: filtered when asked, then in the chosen order.
    private func visibleTypes(in group: HealthTypeDescriptor.Group) -> [HealthTypeDescriptor] {
        let types = HealthTypeCatalog.all.filter { $0.group == group }
        return sorted(hidesEmptyTypes ? types.filter { !isKnownEmpty($0) } : types)
    }

    private var hiddenCount: Int {
        hidesEmptyTypes ? HealthTypeCatalog.all.filter(isKnownEmpty).count : 0
    }

    /// The row's own "muted" test: the facts are in and say there is
    /// nothing. A type whose facts could not be read is never hidden.
    private func isKnownEmpty(_ descriptor: HealthTypeDescriptor) -> Bool {
        let explore = model.explore
        guard explore.quickFactsLoaded, let facts = explore.quickFacts[descriptor.identifier] else { return false }
        return facts.latestStart == nil && explore.profiles[descriptor.identifier] == nil
    }

    private func latestSample(_ descriptor: HealthTypeDescriptor) -> Date? {
        model.explore.quickFacts[descriptor.identifier]?.latestStart
            ?? model.explore.profiles[descriptor.identifier]?.latestStart
    }

    private func sorted(_ types: [HealthTypeDescriptor]) -> [HealthTypeDescriptor] {
        switch sort {
        case .dataFirst:
            // Types with data first, in catalog order; the rest after them.
            guard model.explore.quickFactsLoaded else { return types }
            return types.filter { latestSample($0) != nil } + types.filter { latestSample($0) == nil }
        case .name:
            return types.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        case .recent:
            let dated = types.compactMap { d in latestSample(d).map { (d, $0) } }
                .sorted { $0.1 > $1.1 }
                .map(\.0)
            return dated + types.filter { latestSample($0) == nil }
        }
    }

    private var searchResults: some View {
        let matches = HealthTypeCatalog.all.filter {
            $0.displayName.localizedCaseInsensitiveContains(searchText)
                || $0.group.rawValue.localizedCaseInsensitiveContains(searchText)
                || $0.identifier.localizedCaseInsensitiveContains(searchText)
        }
        return Section {
            if matches.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                // Search always covers every type; only the order applies.
                ForEach(sorted(matches)) { descriptor in
                    typeRow(descriptor, showsCategory: true)
                }
            }
        }
    }

    private func typeRow(_ descriptor: HealthTypeDescriptor, showsCategory: Bool) -> some View {
        let explore = model.explore
        return NavigationLink(value: ExploreRoute.type(descriptor.identifier)) {
            ExploreTypeRow(
                descriptor: descriptor,
                profile: explore.profiles[descriptor.identifier],
                facts: explore.quickFacts[descriptor.identifier],
                factsLoaded: explore.quickFactsLoaded,
                isRunning: explore.isRunning(descriptor.identifier),
                status: model.statuses.first { $0.id == descriptor.identifier },
                hasServer: model.appliedConfig.serverURL != nil,
                showsCategory: showsCategory)
        }
    }
}

/// The order of the types inside each Explore category and in search results.
enum ExploreSort: String, CaseIterable, Identifiable {
    case dataFirst, name, recent

    var id: Self { self }

    var title: String {
        switch self {
        case .dataFirst: "Data First"
        case .name: "Name"
        case .recent: "Most Recent"
        }
    }
}

private struct ExploreTypeRow: View {
    let descriptor: HealthTypeDescriptor
    let profile: TypeProfile?
    let facts: TypeQuickFacts?
    let factsLoaded: Bool
    let isRunning: Bool
    let status: TypeSyncStatus?
    /// A synced count means nothing without a server: an enabled type has a
    /// status either way, and on a server-less install it only ever said
    /// "0 synced".
    let hasServer: Bool
    let showsCategory: Bool

    private var hasData: Bool { facts?.latestStart != nil || profile != nil }
    /// Greyed once the facts are in and say there is nothing.
    private var muted: Bool { factsLoaded && facts != nil && !hasData }

    var body: some View {
        HStack(spacing: 12) {
            TypeIcon(descriptor)
            VStack(alignment: .leading, spacing: 1) {
                Text(descriptor.displayName)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if isRunning {
                ProgressView().controlSize(.small)
            }
            if let status, status.state.lastError != nil {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
        }
        .padding(.vertical, 2)
        .opacity(muted ? 0.55 : 1)
    }

    private var detail: String {
        var parts: [String] = []
        if showsCategory { parts.append(descriptor.group.rawValue) }
        if let profile {
            parts.append("\(profile.sampleCount.compactString) samples")
            if let scope = profileScope(profile) { parts.append(scope) }
            if let last = profile.latestStart { parts.append("last \(last.relativeString)") }
        } else if let facts, let first = facts.earliestStart {
            parts.append("Data since \(first.formatted(.dateTime.year()))")
            parts.append("tap to analyze")
        } else if facts != nil {
            parts.append("No data")
        } else if let status, hasServer {
            parts.append("\(status.state.totalSamplesExported.compactString) synced")
        } else {
            parts.append(kindLabel(descriptor.kind))
        }
        return parts.joined(separator: " · ")
    }
}
