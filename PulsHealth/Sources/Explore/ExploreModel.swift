import Foundation
import Observation
import PulsHealthSync

/// State of the Explore tab: what HealthKit holds per type, as the library's
/// `TypeProfile`s, and the analyses in flight to find out.
///
/// Owned by `AppModel` so an analysis outlives the screen that started it —
/// a year of Watch heart rate is hundreds of thousands of samples. It goes through
/// `HealthExplorer`, which has no engine and no sync state, so nothing here
/// can move an anchor (CLAUDE.md, "Export never shares sync state" — the
/// explorer exists for the same reason). The app's real engine is used for
/// two things only: the HealthKit permission request, which is per-app, and
/// the activity log.
///
/// A profile is a summary, never samples, and `TypeProfileStore` keeps it
/// under the same file protection as the sync state; `deleteAll` is the
/// Settings switch that removes every one.
@MainActor
@Observable
final class ExploreModel {
    let explorer = HealthExplorer()
    let store: TypeProfileStore
    private let engine: HealthSyncEngine

    private(set) var profiles: [String: TypeProfile] = [:]
    private(set) var quickFacts: [String: TypeQuickFacts] = [:]
    /// Progress of every analysis in flight, keyed by type identifier.
    private(set) var running: [String: ProfileProgress] = [:]
    /// The last failure per type, cleared when the type is analyzed again.
    private(set) var errors: [String: String] = [:]
    private(set) var quickFactsLoaded = false
    private(set) var loaded = false

    /// A profile older than this is offered for a refresh even when the
    /// oldest and newest samples have not moved.
    static let maxProfileAge: TimeInterval = 7 * 86_400

    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var factsTask: Task<Void, Never>?
    /// Types a permission request failed to determine this session
    /// (iOS 26.5 omits blood pressure from the sheet, FB22735935): asking
    /// again only makes the sheet flash — or that the user declined on iOS
    /// 27's history page, where asking again would only ask again what they
    /// just answered. Session-only, like `AppModel`'s.
    @ObservationIgnored private var undeterminableTypes: Set<String> = []

    /// Called after an analysis presented the Health permission sheet —
    /// `AppModel` re-reads the history limits there (iOS 27), as it does
    /// after Apply's sheet.
    @ObservationIgnored var onHealthAccessRequested: (@MainActor () async -> Void)?

    init(engine: HealthSyncEngine, store: TypeProfileStore = TypeProfileStore()) {
        self.engine = engine
        self.store = store
    }

    // MARK: - Loading

    /// Every stored profile, once per launch.
    func load() async {
        guard !loaded else { return }
        loaded = true
        #if DEBUG
        if ExploreFixtures.isEnabled {
            for profile in ExploreFixtures.profiles { profiles[profile.typeIdentifier] = profile }
            TypeKnowledge.preload()
            return
        }
        #endif
        for profile in await store.allProfiles() {
            profiles[profile.typeIdentifier] = profile
        }
        TypeKnowledge.preload()
    }

    /// The cheap facts for every type, a few at a time so the list fills in
    /// as they arrive. Once per session unless `force`; a locked device
    /// (the tab opened from a background launch) is retried next time.
    func refreshQuickFactsIfNeeded(force: Bool = false) {
        guard force || !quickFactsLoaded, factsTask == nil else { return }
        factsTask = Task { [weak self] in
            guard let self else { return }
            let ok = await refreshQuickFacts(for: HealthTypeCatalog.all.map(\.identifier))
            quickFactsLoaded = quickFactsLoaded || ok
            factsTask = nil
        }
    }

    /// Explore's pull to refresh: every type's facts again, returning once
    /// they are in (or once a read already in flight finishes).
    func reloadQuickFacts() async {
        refreshQuickFactsIfNeeded(force: true)
        await factsTask?.value
    }

    /// Returns false when the device was locked and nothing could be read.
    @discardableResult
    func refreshQuickFacts(for identifiers: [String]) async -> Bool {
        guard await engine.isHealthDataAccessible() else { return false }
        let explorer = explorer
        for chunk in identifiers.chunked(into: 4) {
            if Task.isCancelled { return false }
            let results = await withTaskGroup(of: (String, TypeQuickFacts?).self) { group in
                for id in chunk {
                    group.addTask { (id, try? await explorer.quickFacts(for: id)) }
                }
                var facts: [(String, TypeQuickFacts?)] = []
                for await result in group { facts.append(result) }
                return facts
            }
            for (id, facts) in results {
                if let facts { quickFacts[id] = facts }
            }
        }
        return true
    }

    // MARK: - Derived

    func isRunning(_ id: String) -> Bool { running[id] != nil }

    /// Whether the stored profile no longer describes what HealthKit holds.
    /// Unknown facts count as fresh: the row should not offer a refresh it
    /// cannot justify.
    func isStale(_ id: String) -> Bool {
        guard let profile = profiles[id], let facts = quickFacts[id] else { return false }
        return TypeProfileStore.isStale(
            profile, facts: facts, options: Self.profileOptions, maxAge: Self.maxProfileAge)
    }

    /// Whether the stored profile was scanned under another iOS 27 history
    /// limit than the one HealthKit reports now — the reason it is stale,
    /// when it is, rather than new data.
    func readableHistoryChanged(_ id: String) -> Bool {
        guard let profile = profiles[id], let facts = quickFacts[id] else { return false }
        let start = Self.profileOptions.effectiveRangeStart() ?? .distantPast
        return ReadableHistory.change(
            from: profile.readableSince,
            to: ReadableHistory.effectiveLimit(facts.readableSince, readingFrom: start)) != .unchanged
    }

    /// 0…1 for a running scan, from where the scan is between where it
    /// started (the type's oldest sample, or a year ago) and the newest
    /// sample; nil until the facts say where those are.
    func fraction(for id: String) -> Double? {
        guard let progress = running[id], let through = progress.scannedThrough,
              let facts = quickFacts[id], let oldest = facts.earliestStart, let last = facts.latestStart
        else { return nil }
        let first = max(oldest, Self.profileOptions.effectiveRangeStart() ?? oldest)
        guard last > first else { return nil }
        return min(max(through.timeIntervalSince(first) / last.timeIntervalSince(first), 0), 1)
    }

    /// Analyses cover the past year: the page describes what a type looks
    /// like now, and a year keeps even heart rate's scan short.
    nonisolated static let lookbackDays = 365

    static var profileOptions: HealthExplorer.ProfileOptions {
        var options = HealthExplorer.ProfileOptions()
        options.lookbackDays = lookbackDays
        return options
    }

    // MARK: - Analysis

    /// Scan one type. Skipped while it is running, and — unless `force` —
    /// when the stored profile is still current.
    func analyze(_ id: String, force: Bool = false) {
        guard tasks[id] == nil else { return }
        errors[id] = nil
        running[id] = ProfileProgress(phase: .probing)
        tasks[id] = Task { [weak self] in
            await self?.runAnalysis(id, force: force)
        }
    }

    func cancel(_ id: String) {
        tasks[id]?.cancel()
    }

    /// Settings → Delete Analysis: every stored profile, and nothing else.
    func deleteAll() async {
        for task in tasks.values { task.cancel() }
        await store.removeAll()
        profiles = [:]
        errors = [:]
    }

    private func runAnalysis(_ id: String, force: Bool) async {
        defer {
            tasks[id] = nil
            running[id] = nil
        }
        let name = HealthTypeCatalog.descriptor(for: id)?.displayName ?? id
        do {
            await requestAccessIfNeeded(id)
            try Task.checkCancellation()
            let facts = try await explorer.quickFacts(for: id)
            quickFacts[id] = facts
            if !force, let existing = profiles[id],
               !TypeProfileStore.isStale(existing, facts: facts, options: Self.profileOptions, maxAge: Self.maxProfileAge)
            {
                return
            }
            // Progress arrives on the explorer's executor after every page.
            // Newest-only buffering hands the main actor the latest one and
            // drops the ones the screen would never draw (as ExportModel).
            let (updates, continuation) = AsyncStream.makeStream(
                of: ProfileProgress.self, bufferingPolicy: .bufferingNewest(1))
            let display = Task { [weak self] in
                for await progress in updates {
                    guard let self, self.running[id] != nil else { continue }
                    self.running[id] = progress
                }
            }
            await engine.eventLog.log(.info, type: id, "Analysis of \(name) started")
            let outcome: Result<TypeProfile, Error>
            do {
                outcome = .success(try await explorer.profile(for: id, options: Self.profileOptions) {
                    continuation.yield($0)
                })
            } catch {
                outcome = .failure(error)
            }
            // Drain before writing the result, or a late update lands after it.
            continuation.finish()
            await display.value
            let profile = try outcome.get()
            profiles[id] = profile
            try await store.save(profile)
            await engine.eventLog.log(
                profile.isComplete ? .info : .warn, type: id,
                "Analysis of \(name) finished: \(profile.sampleCount.formatted()) samples, "
                    + "\(profile.scanDuration.shortDuration)"
                    + (profile.isComplete ? "" : " (incomplete)"))
        } catch is CancellationError {
            await engine.eventLog.log(.info, type: id, "Analysis of \(name) cancelled")
        } catch {
            let message = Self.friendlyMessage(for: error)
            errors[id] = message
            await engine.eventLog.log(.warn, type: id, "Analysis of \(name) failed: \(message)")
        }
    }

    /// The permission step, the same one the export makes: ask for a type
    /// iOS still reports undetermined, once. Types iOS refuses to put in the
    /// sheet are not asked for again, and the medication picker is never
    /// requested here (it presents itself and may never return —
    /// CLAUDE.md, the medication gotcha).
    private func requestAccessIfNeeded(_ id: String) async {
        guard id != HealthTypeCatalog.medicationDoseIdentifier,
              !undeterminableTypes.contains(id),
              await engine.authorizationNeeded(for: [id])
        else { return }
        do {
            // Declined (iOS 27's history page) or not, a type still
            // undetermined afterwards is not asked about again this session.
            // Declining is an answer, not a failure: the scan reports what
            // it could not read, as for a first-page Don't Allow.
            try await engine.requestAuthorization(for: [id])
            if await engine.authorizationNeeded(for: [id]) {
                undeterminableTypes.insert(id)
            }
            await onHealthAccessRequested?()
        } catch {
            // Not fatal: the scan runs and reports what it could not read.
            await engine.eventLog.log(
                .warn, type: id, "Health access request before analysis failed: \(error.localizedDescription)")
        }
    }

    static func friendlyMessage(for error: Error) -> String {
        if let error = error as? HealthExploreError {
            switch error {
            case .deviceLocked:
                return "Unlock your iPhone to read Health data, then try again."
            case .healthDataUnavailable:
                return "Health data is not available on this device."
            case .queryFailed(let text) where text.contains("Code=5") || text.contains("Code=4"):
                // errorAuthorizationNotDetermined / errorAuthorizationDenied.
                return "PulsHealth does not have Health access for this type yet. Analyze it to ask, or allow it under Settings → Privacy & Security → Health."
            default:
                return error.localizedDescription
            }
        }
        return error.localizedDescription
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
