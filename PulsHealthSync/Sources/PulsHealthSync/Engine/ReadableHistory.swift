import Foundation
import HealthKit

/// iOS 27's limited-history Health access, and the rules the sync keeps
/// because of it.
///
/// From iOS 27 the Health permission sheet has a second page, "How much data
/// would you like to share?", offering *Past 30 Days and Future Data* or *All
/// Recorded Data and Future Data*, and Settings → Privacy & Security → Health
/// → (app) → (type) offers *Limited Access* or *Full Access* per type
/// afterwards. Limited, HealthKit lets the app read a type only from an
/// earliest date on — 30 days before the moment it was chosen, fixed from
/// then — and says so in no query: history before it simply looks empty. A
/// whole-history backfill drains after a month and reports itself complete,
/// a statistics query returns empty buckets for every year before, and a
/// sample query for last spring finds nothing.
///
/// Measured on the iOS 27.0 simulator (24A434): the date is the same for
/// every type a sheet granted, and reported for the activity-summary type
/// too; a type with full access, or none decided yet, is simply absent from
/// the answer, and so is a per-object type; a sample is hidden only when it
/// *ends* before the date; narrowing access made an anchored query from an
/// older anchor report no deletions; and an anchor taken under the limit
/// returned none of the older samples once access was widened again.
///
/// Empty is not harmless on this pipeline, because some passes treat what
/// they read as the whole truth and the server overwrites or deletes to
/// match:
///
/// - aggregates upload an explicit `"value": null` for an empty bucket so a
///   recompute can clear a stale value — over unreadable history that would
///   null out years of real server buckets, and a bucket straddling the date
///   would be overwritten with a partial value;
/// - reconciliation deletes server rows the device does not have;
/// - the rings upsert by day.
///
/// So every one of those passes is clamped to what is readable
/// (`clampAggregateWindow`, `reconcileStart`, `firstWholeDay`) and the date
/// each one ran under is recorded (`readableSince` on the type, aggregate,
/// rings and enrichment states). When access widens later — the date moves
/// earlier, or the limit goes — the passes that ran under the old date start
/// over and read the history they missed (`HealthSyncEngine
/// .refreshReadableHistory`, and each pass's own check). The raw sweep needs
/// that most: its anchor sits past everything it has read, so the samples
/// that become readable would never be returned by it again. The raw sweep
/// itself needs no clamp: it only adds what HealthKit returns and deletes
/// what HealthKit lists as deleted.
///
/// HealthKit reports the date through `HKHealthStore
/// .earliestAuthorizedSampleDate(for:)`, an iOS 27 SDK API. This package also
/// builds with Xcode 26.5, whose SDK does not have it, so every use sits
/// behind `#if compiler(>=6.4)` as well as `#available(iOS 27.0, *)`:
/// Xcode 27.0 ships Swift 6.4 with the iOS 27 SDK, while Xcode 26.5 ships
/// Swift 6.3.2 (and 26.6, Swift 6.3.3) with the iOS 26.5 SDK. A compiler
/// version is the only thing `#if` can test that tells the two SDKs apart.
/// Built with the older SDK, or run before iOS 27, there is never a limit.
public enum ReadableHistory {
    /// True when this build can ask HealthKit for earliest readable dates
    /// and the running OS can answer: built with the iOS 27 SDK and running
    /// iOS 27 or later. Also when the permission sheet can ask how much
    /// history to share, as far as this app is concerned.
    public static var isSupported: Bool {
        #if compiler(>=6.4)
        if #available(iOS 27.0, *) { return true }
        #endif
        return false
    }

    /// How far a reported date may move before it counts as a new grant.
    /// HealthKit's date is fixed when the user answers the sheet, but a
    /// re-sweep is a whole backfill, so a jittering value must never be able
    /// to start one. A day, not an hour: a DST step moves a local-midnight
    /// date by exactly an hour, and a real change of answer moves it by
    /// more than a day — limiting again always lands 30 days before *now*,
    /// later than the old date — or removes it.
    static let tolerance: TimeInterval = 86_400

    /// How a type's earliest readable date moved between two looks.
    public enum Change: Sendable, Equatable {
        case unchanged
        /// The date moved earlier, or the limit went away: history the
        /// passes could not read before is readable now.
        case widened
        /// A limit appeared, or the date moved later. Nothing is reset —
        /// what was synced stays synced, and the clamps keep the passes off
        /// what can no longer be read.
        case narrowed
    }

    /// The change from the date a pass recorded to the one HealthKit reports
    /// now. Nil means unlimited on both sides — as far as the dates go.
    ///
    /// A `.widened` here is only a claim. HealthKit leaves a type out of
    /// its answer unless it is limited *with a date*, so a type the user
    /// switched to **None** in Settings is absent exactly like one switched
    /// to Full Access. Measured on the iOS 27.0 simulator (24A434): Steps
    /// switched from Limited to None under Settings → Privacy & Security →
    /// Health → (app) dropped out of `earliestAuthorizedSampleDate(for:)`,
    /// and a sample query, a daily statistics query and an anchored query
    /// for it all came back empty without an error (the anchored one, from
    /// an anchor taken under the limit, with no deletions either). Acting on
    /// that "widening" would reset an aggregate series and recompute it from
    /// its start date with nothing to clamp it, every bucket a null. So a
    /// pass confirms a widening with `resolve(recorded:reported:olderHistoryFound:)`
    /// before it acts: switched back to Full Access, the same probe found
    /// the older samples at once.
    public static func change(from recorded: Date?, to current: Date?) -> Change {
        switch (recorded, current) {
        case (nil, nil):
            return .unchanged
        case (.some, nil):
            return .widened
        case (nil, .some):
            return .narrowed
        case let (recorded?, current?):
            if current < recorded.addingTimeInterval(-tolerance) { return .widened }
            if current > recorded.addingTimeInterval(tolerance) { return .narrowed }
            return .unchanged
        }
    }

    /// The date a pass should run under: HealthKit's report, except that a
    /// widening only counts once HealthKit has returned a sample older than
    /// the recorded date (`hasHistory(of:endingBefore:in:)`). Without one the
    /// report may as well be access set to None, and the recorded date
    /// stands — the pass keeps clamping to it and resets nothing.
    ///
    /// A type with genuinely no older data fails the probe too. Nothing is
    /// lost then: there is no older history to re-read, and the clamp still
    /// keeps nulls off the empty range.
    static func resolve(recorded: Date?, reported: Date?, olderHistoryFound: Bool) -> Date? {
        guard change(from: recorded, to: reported) == .widened, !olderHistoryFound else { return reported }
        return recorded
    }

    /// What `HealthSyncEngine.refreshReadableHistory` does for one raw type.
    enum RefreshAction: Sendable, Equatable {
        case none
        /// Write the new date down; nothing to redo.
        case record
        /// Reset the type's anchors and reopen its backfill.
        case resweep
        /// Another run holds the type. Leave it — writing a widened date now
        /// would let that run ack a page read under the old limit after the
        /// record says there is none — and retry at the next refresh.
        case deferUntilReleased
    }

    /// The decision behind `RefreshAction`, from a confirmed change (see
    /// `resolve`), whether the type has progress, and whether a run holds it.
    static func refreshAction(change: Change, hasProgress: Bool, isActive: Bool) -> RefreshAction {
        switch change {
        case .unchanged: return .none
        case .narrowed: return .record
        case .widened:
            if isActive { return .deferUntilReleased }
            return hasProgress ? .resweep : .record
        }
    }

    /// A limit that bites: `since` when it is later than where a pass starts
    /// reading anyway, else nil. A limit at or before the start cuts nothing
    /// off, so there is nothing to clamp, record, or later re-read.
    public static func effectiveLimit(_ since: Date?, readingFrom start: Date) -> Date? {
        guard let since, since > start else { return nil }
        return since
    }

    // MARK: - Clamps

    /// The first bucket boundary at or after `limit`. A bucket starting
    /// there holds only samples HealthKit lets the app read; every earlier
    /// bucket either ends before the limit or straddles it, and would be
    /// computed from part of its data.
    static func firstWholeBucket(atOrAfter limit: Date, bucketing: AggregateBucketing) -> Date {
        let index = bucketing.index(of: limit)
        let start = bucketing.start(ofBucket: index)
        return start == limit ? limit : bucketing.start(ofBucket: index + 1)
    }

    /// An aggregate window with every bucket before `firstWholeBucket` cut
    /// off, or nil when nothing readable is left in it. Nil `readableSince`
    /// is no limit, and the window comes back as it went in.
    ///
    /// A clamped bucket is not computed and not uploaded — not even as
    /// `"value": null`, which is what would overwrite real history on the
    /// server.
    static func clampAggregateWindow(
        _ window: (from: Date, to: Date), readableSince limit: Date?, bucketing: AggregateBucketing
    ) -> (from: Date, to: Date)? {
        guard let limit else { return window }
        let from = max(window.from, firstWholeBucket(atOrAfter: limit, bucketing: bucketing))
        guard from < window.to else { return nil }
        return (from, window.to)
    }

    /// Local midnight of the first day that starts at or after `limit`: the
    /// first ring day whose whole activity is readable.
    static func firstWholeDay(atOrAfter limit: Date, calendar: Calendar) -> Date {
        let day = calendar.startOfDay(for: limit)
        guard day < limit else { return day }
        return calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
    }

    /// Where reconciliation may start. It deletes what the server has and the
    /// device does not, so it must never compare a range the device cannot
    /// read. HealthKit hides a sample only when it *ends* before the date
    /// (measured on the iOS 27.0 simulator: a sample starting three hours
    /// before it and ending three hours after is returned), so every sample
    /// that starts at or after the date is readable, and the comparison —
    /// by start date, like the server's digests — is complete from there.
    static func reconcileStart(syncStart: Date, readableSince limit: Date?) -> Date {
        guard let limit else { return syncStart }
        return max(syncStart, limit)
    }

    // MARK: - Re-sweep

    /// Whether a raw type has progress a widened grant should redo: an
    /// anchor (either stream), a finished backfill, or samples sent.
    static func hasRawProgress(_ state: TypeSyncState) -> Bool {
        state.anchorData != nil || state.recentAnchorData != nil
            || state.backfillComplete || state.totalSamplesExported > 0
    }

    /// The re-sweep decision for one raw type: its access widened since the
    /// date it was last synced under, and it has synced something under it.
    static func needsResweep(_ state: TypeSyncState, readableSince current: Date?) -> Bool {
        change(from: state.readableSince, to: current) == .widened && hasRawProgress(state)
    }

    // MARK: - HealthKit

    /// The HealthKit object types to ask about for `identifiers`, mapped back
    /// to the identifier each answers for. Medication doses are left out:
    /// per-object types raise an Objective-C exception in HealthKit's bulk
    /// authorization APIs, and this is one of them as far as anyone knows.
    static func objectTypes(for identifiers: some Sequence<String>) -> [HKObjectType: String] {
        var types: [HKObjectType: String] = [:]
        let identifiers = Array(identifiers)
        for identifier in identifiers {
            if HealthTypeCatalog.isActivitySummary(identifier) {
                types[HKObjectType.activitySummaryType()] = identifier
                continue
            }
            guard !HealthTypeCatalog.usesPerObjectAuthorization(identifier),
                  let type = HealthTypeCatalog.descriptor(for: identifier)?.sampleType
            else { continue }
            types[type] = identifier
        }
        // HealthKit's authorization APIs refuse the heartbeat series without
        // HRV SDNN beside it (an uncatchable exception — see
        // `HealthSyncEngine.readAuthorizationTypes`); ask for the pair here
        // too rather than find out whether this one does.
        if identifiers.contains(HealthTypeCatalog.heartbeatSeriesIdentifier) {
            let hrv = HKQuantityType(.heartRateVariabilitySDNN)
            if types[hrv] == nil { types[hrv] = hrv.identifier }
        }
        return types
    }

    /// How long a HealthKit call here may take before its answer counts as
    /// unknown. HealthKit calls have been seen to stall for 30–60 s after a
    /// reinstall on the simulator, and one never to return on a fresh one;
    /// and these run before every sync claims its types. Unknown fails
    /// closed: the recorded date stands, and nothing widens.
    static let timeout: Duration = .seconds(10)

    /// Thrown by `withTimeout` when the operation outran it.
    struct TimedOut: Error, CustomStringConvertible {
        var description: String { "HealthKit did not answer within \(ReadableHistory.timeout)" }
    }

    /// `operation`'s result, or `TimedOut` once `limit` has passed —
    /// whether or not the operation honours cancellation. It is cancelled
    /// then, and whatever it returns later is dropped. (A task group would
    /// not do: it waits for every child before it returns, so a HealthKit
    /// call that never comes back would hold it forever.)
    static func withTimeout<T: Sendable>(
        _ limit: Duration = timeout, _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let once = ResumeOnce<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                once.set(continuation)
                let work = Task {
                    do { once.resume(with: .success(try await operation())) } catch { once.resume(with: .failure(error)) }
                }
                let timer = Task {
                    try? await Task.sleep(for: limit)
                    if once.resume(with: .failure(TimedOut())) { work.cancel() }
                }
                once.onResume { timer.cancel() }
            }
        } onCancel: {
            once.resume(with: .failure(CancellationError()))
        }
    }

    /// Whether HealthKit returns anything of `identifier` that ends before
    /// `date` — the evidence that a widening is real (`resolve`). One
    /// sample, or for the rings one day's summary before `date`'s day. No
    /// answer — an error, a timeout, a type with no older data — is no: a
    /// widening is never inferred from silence.
    static func hasHistory(
        of identifier: String, endingBefore date: Date, in healthStore: HKHealthStore,
        calendar: Calendar = .current
    ) async -> Bool {
        do {
            return try await withTimeout {
                if HealthTypeCatalog.isActivitySummary(identifier) {
                    let units: Set<Calendar.Component> = [.era, .year, .month, .day]
                    guard let lastDay = calendar.date(
                        byAdding: .day, value: -1, to: calendar.startOfDay(for: date))
                    else { return false }
                    var start = calendar.dateComponents(units, from: ExportPlan.allTimeFloor)
                    start.calendar = calendar
                    var end = calendar.dateComponents(units, from: lastDay)
                    end.calendar = calendar
                    let predicate = HKQuery.predicate(forActivitySummariesBetweenStart: start, end: end)
                    return !(try await HKActivitySummaryQueryDescriptor(predicate: predicate)
                        .result(for: healthStore)).isEmpty
                }
                guard let type = HealthTypeCatalog.descriptor(for: identifier)?.sampleType else { return false }
                let older = HKSampleQueryDescriptor(
                    predicates: [.sample(
                        type: type,
                        predicate: HKQuery.predicateForSamples(withStart: nil, end: date, options: .strictEndDate))],
                    sortDescriptors: [],
                    limit: 1)
                return !(try await older.result(for: healthStore)).isEmpty
            }
        } catch {
            return false
        }
    }

    /// One HealthKit round trip: the earliest readable date of each of
    /// `identifiers` that iOS 27 limits, by identifier. Empty when none is
    /// limited — and always empty when built with the iOS 26 SDK or run
    /// before iOS 27. Throws what HealthKit throws, and `TimedOut` after
    /// `timeout`; callers decide what an unknown answer means for them.
    /// Never asks about an empty set: that breaks the connection to
    /// `healthd` (Cocoa error 4099).
    static func query(
        _ identifiers: some Collection<String>, in healthStore: HKHealthStore
    ) async throws -> [String: Date] {
        #if compiler(>=6.4)
        if #available(iOS 27.0, *) {
            let types = objectTypes(for: identifiers)
            guard !types.isEmpty else { return [:] }
            let asking = Set(types.keys)
            let dates = try await withTimeout {
                try await healthStore.earliestAuthorizedSampleDate(for: asking)
            }
            let asked = Set(identifiers)
            var byIdentifier: [String: Date] = [:]
            for (type, date) in dates {
                if let identifier = types[type], asked.contains(identifier) {
                    byIdentifier[identifier] = date
                }
            }
            return byIdentifier
        }
        #endif
        return [:]
    }
}

/// What a Health permission request came back with.
public enum HealthAccessRequestOutcome: Sendable, Equatable {
    /// iOS showed its sheet and the user answered it, or there was nothing
    /// to ask. As ever, HealthKit does not say what was allowed.
    case answered
    /// The user chose Don't Allow on iOS 27's second page, "How much data
    /// would you like to share?". `requestAuthorization` throws
    /// `errorAuthorizationDenied` for it and the types stay undetermined. It
    /// is the user's answer, not a failure: nothing is shown as an error, and
    /// the types are read like any others the user has not allowed.
    case declined

    /// `.declined` for the error page two's Don't Allow throws; nil for any
    /// other error, which is a real failure. (Don't Allow on the first page
    /// returns normally, as it always has.)
    public static func classify(_ error: Error) -> HealthAccessRequestOutcome? {
        if let error = error as? HKError {
            return error.code == .errorAuthorizationDenied ? .declined : nil
        }
        let nsError = error as NSError
        guard nsError.domain == HKErrorDomain,
              nsError.code == HKError.Code.errorAuthorizationDenied.rawValue
        else { return nil }
        return .declined
    }
}

/// What the app says about types iOS 27 lets it read only from a date on:
/// which ones, and since when. The pure half of the Sync tab's notice, kept
/// here so its choices are tested.
public struct LimitedHistorySummary: Sendable, Equatable {
    /// Display names, alphabetical.
    public var typeNames: [String]
    /// The earliest and the latest of the types' dates. Usually one date:
    /// every type a permission sheet granted gets the same one.
    public var earliest: Date
    public var latest: Date

    /// Nil when nothing is limited.
    public init?(_ limits: [String: Date]) {
        guard let earliest = limits.values.min(), let latest = limits.values.max() else { return nil }
        self.typeNames = limits.keys
            .map { HealthTypeCatalog.descriptor(for: $0)?.displayName ?? $0 }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        self.earliest = earliest
        self.latest = latest
    }

    /// "Steps", "Heart Rate and Steps", "Body Weight, Heart Rate and Steps",
    /// "Body Weight, Heart Rate and 4 more types": every name up to three,
    /// then two and a count, so the sentence stays a sentence.
    public var typesText: String {
        switch typeNames.count {
        case 1: return typeNames[0]
        case 2: return "\(typeNames[0]) and \(typeNames[1])"
        case 3: return "\(typeNames[0]), \(typeNames[1]) and \(typeNames[2])"
        default: return "\(typeNames[0]), \(typeNames[1]) and \(typeNames.count - 2) more types"
        }
    }

    /// Whether every date falls on the same local day, so one date says it.
    public func isOneDay(in calendar: Calendar = .current) -> Bool {
        calendar.isDate(earliest, inSameDayAs: latest)
    }
}

/// A continuation resumed exactly once, by whichever of `withTimeout`'s
/// racers gets there first. A lock, because the racers are unstructured
/// tasks and the cancellation handler runs on whatever thread cancels.
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var pending: Result<T, Error>?
    private var resumed = false
    private var hooks: [@Sendable () -> Void] = []

    /// Installs the continuation; a result that arrived first (cancellation
    /// before the continuation existed) is delivered at once.
    func set(_ continuation: CheckedContinuation<T, Error>) {
        lock.lock()
        if let pending {
            self.pending = nil
            lock.unlock()
            continuation.resume(with: pending)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    /// Runs `hook` when the continuation is resumed (now, if it was).
    func onResume(_ hook: @escaping @Sendable () -> Void) {
        lock.lock()
        if resumed {
            lock.unlock()
            hook()
            return
        }
        hooks.append(hook)
        lock.unlock()
    }

    /// True for the call that resumed it; false for every later one.
    @discardableResult
    func resume(with result: Result<T, Error>) -> Bool {
        lock.lock()
        guard !resumed else {
            lock.unlock()
            return false
        }
        resumed = true
        let continuation = self.continuation
        self.continuation = nil
        if continuation == nil { pending = result }
        let hooks = self.hooks
        self.hooks = []
        lock.unlock()
        continuation?.resume(with: result)
        for hook in hooks { hook() }
        return true
    }
}
