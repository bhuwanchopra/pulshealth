import Foundation
import HealthKit
import os

/// Read-only questions about what HealthKit holds, answered from a plain
/// `HKHealthStore` of its own.
///
/// **This layer never touches sync state.** It has no `HealthSyncEngine`, no
/// `SyncStateStore`, no `SyncEventLog`, no `WakeLog` and no transport, and it
/// does not want any of them: the engine advances a type's anchor whenever its
/// transport returns normally, and anchors and watermarks are keyed per type
/// with no notion of who read the data — the export invariant exists because
/// a second reader borrowing the engine records every sample it saw as
/// delivered. So exploring uses date-sorted sample queries and statistics
/// queries, which have no cursor to persist, and shares with the engine only
/// pure code: the catalog, the bucket math and `AggregateQuery`. What it
/// returns are numbers (`TypeProfile`, `TypeQuickFacts`, `AggregateBucket`),
/// never samples.
///
/// Every entry point first checks that HealthKit exists on the device and
/// that the device is unlocked — the HealthKit store is unreadable while
/// locked, and every query would fail with `errorDatabaseInaccessible`.
public final class HealthExplorer: Sendable {
    private let healthStore = HKHealthStore()
    private let logger = Logger(subsystem: PulsLog.subsystem, category: "explore")

    public init() {}

    /// How to scan for `profile(for:)`.
    public struct ProfileOptions: Sendable, Equatable {
        /// Bounds on sample start (`strictStartDate`); nil = unbounded.
        public var rangeStart: Date?
        public var rangeEnd: Date?
        /// Only the last this-many days: the scan starts at the start of the
        /// day `lookbackDays` before the one it runs on, in `calendar` (or at
        /// `rangeStart`, if that is later). The profile records the date it
        /// resolved to as `rangeStart` and this number as `lookbackDays`, and
        /// `TypeProfileStore.isStale` judges it by the number, since the date
        /// moves every day. Pass a `maxAge` there with it.
        public var lookbackDays: Int?
        /// Bins in the value histogram of a quantity type.
        public var histogramBins = 40
        /// Values (and gaps) kept for quantiles; above this the profile's
        /// quantiles, histogram and cadence percentiles are estimates.
        public var reservoirCapacity = 8_192
        /// The calendar daily counts are bucketed in — the phone's, normally,
        /// which is the one the sync's day buckets use too.
        public var calendar: Calendar = .current

        public init() {}

        /// Where a scan run at `now` starts: the later of `rangeStart` and
        /// the lookback's day.
        public func effectiveRangeStart(now: Date = Date()) -> Date? {
            guard let lookbackDays else { return rangeStart }
            let today = calendar.startOfDay(for: now)
            let start = calendar.date(byAdding: .day, value: -lookbackDays, to: today) ?? today
            return Swift.max(start, rangeStart ?? start)
        }
    }

    // MARK: - Readable history

    /// iOS 27 limited history access: the earliest date HealthKit lets the
    /// app read `identifier` from, or nil when it may read all of it —
    /// always nil before iOS 27 or when built with the iOS 26 SDK. Also nil
    /// when HealthKit cannot say, which is why the profile and preview
    /// record what they ran under rather than trust a later answer.
    public func readableSince(for identifier: String) async -> Date? {
        (try? await ReadableHistory.query([identifier], in: healthStore))?[identifier]
    }

    // MARK: - Quick facts

    /// The oldest and newest sample and the set of writers: three small
    /// queries, cheap enough for a list of every type — and, on iOS 27, how
    /// far back HealthKit lets the app read (`TypeQuickFacts.readableSince`).
    public func quickFacts(for identifier: String) async throws -> TypeQuickFacts {
        try await checkAvailability()
        let descriptor = try descriptor(for: identifier)
        let limit = await readableSince(for: identifier)

        if descriptor.kind == .activitySummary {
            // Rings have no source and no HKSample; one summary query over
            // all time returns only the days that have one.
            let days = try await activitySummaryDays(
                from: ExportPlan.allTimeFloor, to: Date(), calendar: .current)
            return TypeQuickFacts(
                typeIdentifier: identifier, earliestStart: days.min(), latestStart: days.max(),
                sourceNames: [], readableSince: limit)
        }
        guard let sampleType = descriptor.sampleType else {
            throw HealthExploreError.unsupportedKind(identifier)
        }
        do {
            async let earliest = boundarySample(of: sampleType, order: .forward)
            async let latest = boundarySample(of: sampleType, order: .reverse)
            async let sources = HKSourceQueryDescriptor(predicate: .sample(type: sampleType))
                .result(for: healthStore)
            return try await TypeQuickFacts(
                typeIdentifier: identifier,
                earliestStart: earliest,
                latestStart: latest,
                sourceNames: sources.map(\.name).sorted(),
                readableSince: limit)
        } catch {
            throw Self.wrap(error)
        }
    }

    // MARK: - Profile

    /// One ascending scan of the type, reduced to a `TypeProfile`.
    ///
    /// Under iOS 27's limited history access the scan starts at the type's
    /// earliest readable date when that is later than the requested start,
    /// and the profile says so (`TypeProfile.readableSince`): HealthKit
    /// would return nothing before it anyway, and a profile that claimed
    /// the requested range would describe a month as if it were a year.
    ///
    /// A failure before the first page throws; a failure after some pages
    /// returns what was read with `isComplete == false` and the scrubbed
    /// reason in `failureReason`, because on a multi-year type the pages
    /// already read are worth more than the error. Cancellation always
    /// throws, and nothing is kept.
    public func profile(
        for identifier: String,
        options: ProfileOptions = .init(),
        progress: ProfileProgressHandler? = nil
    ) async throws -> TypeProfile {
        try await checkAvailability()
        let descriptor = try descriptor(for: identifier)
        let started = ContinuousClock.now
        let requestedStart = options.effectiveRangeStart()
        let scanLimit = ReadableHistory.effectiveLimit(
            await readableSince(for: identifier), readingFrom: requestedStart ?? ExportPlan.allTimeFloor)
        let rangeStart = scanLimit ?? requestedStart
        progress?(ProfileProgress(phase: .probing))

        var accumulator = ProfileAccumulator(
            typeIdentifier: identifier,
            kind: descriptor.kind,
            unitString: descriptor.unitString,
            histogramBins: options.histogramBins,
            reservoirCapacity: options.reservoirCapacity,
            calendar: options.calendar)

        if descriptor.kind == .activitySummary {
            let days: [Date]
            do {
                days = try await activitySummaryDays(
                    from: rangeStart ?? ExportPlan.allTimeFloor,
                    to: options.rangeEnd ?? Date(),
                    calendar: options.calendar)
            } catch {
                throw Self.wrap(error)
            }
            for day in days.sorted() {
                let end = options.calendar.date(byAdding: .day, value: 1, to: day) ?? day
                accumulator.add(ScannedSample(start: day, end: end))
            }
            progress?(ProfileProgress(
                phase: .finishing, samplesScanned: days.count, pagesScanned: 1, scannedThrough: days.max()))
            var profile = accumulator.finish(
                scanDuration: (ContinuousClock.now - started).seconds,
                rangeStart: requestedStart, rangeEnd: options.rangeEnd,
                isComplete: true, failureReason: nil)
            profile.lookbackDays = options.lookbackDays
            profile.readableSince = scanLimit
            // A summary is computed by the system; "source" and "device"
            // would only ever say so.
            profile.sources = []
            profile.devices = []
            return profile
        }

        guard let sampleType = descriptor.sampleType else {
            throw HealthExploreError.unsupportedKind(identifier)
        }
        let scanner = SampleScanner(
            healthStore: healthStore, descriptor: descriptor, rangeEnd: options.rangeEnd)
        var pages = 0
        var scanned = 0
        var failure: String?
        var outcome: SampleCursor.Outcome?
        do {
            outcome = try await SampleCursor().scan(
                from: rangeStart, fetch: scanner.fetch(sampleType: sampleType)
            ) { samples, through in
                accumulator.add(contentsOf: samples)
                pages += 1
                scanned += samples.count
                progress?(ProfileProgress(
                    phase: .scanning, samplesScanned: scanned, pagesScanned: pages, scannedThrough: through))
            }
        } catch let error as CancellationError {
            throw error
        } catch {
            let reason = ErrorScrubber.describe(error, limit: ErrorScrubber.displayLimit)
            guard pages > 0 else { throw Self.wrap(error) }
            logger.warning("Profile of \(identifier) stopped after \(pages) page(s): \(reason)")
            failure = reason
        }

        progress?(ProfileProgress(
            phase: .finishing, samplesScanned: scanned, pagesScanned: pages))
        var profile = accumulator.finish(
            scanDuration: (ContinuousClock.now - started).seconds,
            rangeStart: requestedStart,
            rangeEnd: options.rangeEnd,
            isComplete: failure == nil,
            failureReason: failure ?? outcome?.skipNote)
        profile.lookbackDays = options.lookbackDays
        profile.readableSince = scanLimit
        return profile
    }

    // MARK: - Aggregate preview

    /// One bucket of a previewed aggregate series; `value` is nil for an
    /// empty bucket, as on the wire.
    public struct AggregateBucket: Codable, Sendable, Equatable {
        public var start: Date
        public var end: Date
        public var value: Double?
        public var unit: String?

        public init(start: Date, end: Date, value: Double?, unit: String?) {
            self.start = start
            self.end = end
            self.value = value
            self.unit = unit
        }
    }

    /// The buckets a configured aggregate series would produce over
    /// `[from, to]`, computed exactly as the sync computes them (same query,
    /// same bucket math, same recovery) and uploaded nowhere: no watermark
    /// moves, no `computedThrough`, no priority-window bookkeeping.
    ///
    /// `gridAnchor` is the bucket grid's origin, which decides where day and
    /// week boundaries fall; the default is the start of the config's start
    /// date (or `from`) in `calendar`, which is what the engine uses, so the
    /// preview's buckets line up with the ones already on the server.
    /// Bounds are widened to whole buckets: the bucket containing `to` is
    /// included in full. Under iOS 27's limited history access the series
    /// starts at the first whole bucket the app may read, as the sync's does
    /// (`ReadableHistory.clampAggregateWindow`): earlier buckets would come
    /// back empty and read as "no data", which is not what they are.
    public func aggregatePreview(
        _ config: AggregateConfig,
        from: Date,
        to: Date,
        gridAnchor: Date? = nil,
        calendar: Calendar = .current,
        progress: ProfileProgressHandler? = nil
    ) async throws -> [AggregateBucket] {
        try await checkAvailability()
        let descriptor = try descriptor(for: config.typeIdentifier)
        guard descriptor.kind == .quantity else {
            throw HealthExploreError.unsupportedKind("\(config.typeIdentifier) is not a quantity type")
        }
        // Re-validate even if the caller only offers legal functions: an
        // illegal option×aggregation-style combo raises an ObjC exception
        // inside HealthKit when the query executes — a crash, not an error.
        guard HealthTypeCatalog.allowedAggregateFunctions(for: config.typeIdentifier)
            .contains(config.function)
        else {
            throw HealthExploreError.unsupportedKind(
                "\(config.function.rawValue) is not allowed for \(config.typeIdentifier)")
        }
        guard from < to else { return [] }

        let anchor = gridAnchor ?? calendar.startOfDay(for: config.startDate ?? from)
        let bucketing = AggregateBucketing(
            anchor: anchor, intervalValue: config.intervalValue,
            intervalUnit: config.intervalUnit, calendar: calendar)
        let window = ReadableHistory.clampAggregateWindow(
            (from, Self.ceilBoundary(to, bucketing: bucketing)),
            readableSince: await readableSince(for: config.typeIdentifier), bucketing: bucketing)
        guard let window else { return [] }
        let chunks = bucketing.chunks(from: window.from, to: window.to)
        let sink = OSAllocatedUnfairLock(initialState: [AggregateBucket]())

        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            do {
                _ = try await AggregateQuery.bucketsRecovering(
                    for: config, unit: descriptor.unit, canonicalAnchor: anchor,
                    calendar: calendar, chunk: chunk, healthStore: healthStore
                ) { rows, _ in
                    sink.withLock { buckets in
                        buckets.append(contentsOf: rows.map {
                            AggregateBucket(start: $0.bucketStart, end: $0.bucketEnd, value: $0.value, unit: $0.unit)
                        })
                    }
                }
            } catch let error as CancellationError {
                throw error
            } catch {
                throw Self.wrap(error)
            }
            let count = sink.withLock(\.count)
            progress?(ProfileProgress(
                phase: index + 1 == chunks.count ? .finishing : .scanning,
                samplesScanned: count, pagesScanned: index + 1, scannedThrough: chunk.end))
        }
        return sink.withLock { $0 }
    }

    /// `to` itself when it is a boundary, else the next boundary after it —
    /// `AggregateBucketing.chunks` excludes the bucket starting at `to`.
    static func ceilBoundary(_ to: Date, bucketing: AggregateBucketing) -> Date {
        let index = bucketing.index(of: to)
        let start = bucketing.start(ofBucket: index)
        return start == to ? to : bucketing.start(ofBucket: index + 1)
    }

    // MARK: - Helpers

    private func checkAvailability() async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HealthExploreError.healthDataUnavailable
        }
        guard await ProtectedData.isAvailable else {
            throw HealthExploreError.deviceLocked
        }
    }

    private func descriptor(for identifier: String) throws -> HealthTypeDescriptor {
        guard let descriptor = HealthTypeCatalog.descriptor(for: identifier) else {
            throw HealthExploreError.unknownType(identifier)
        }
        return descriptor
    }

    /// Everything HealthKit throws becomes `queryFailed` with scrubbed text;
    /// the explorer's own errors pass through unchanged.
    private static func wrap(_ error: Error) -> Error {
        if let error = error as? HealthExploreError { return error }
        if let error = error as? HKError, error.code == .errorDatabaseInaccessible {
            return HealthExploreError.deviceLocked
        }
        return HealthExploreError.queryFailed(
            ErrorScrubber.describe(error, limit: ErrorScrubber.displayLimit))
    }

    /// Start of the oldest (`.forward`) or newest (`.reverse`) sample, or nil
    /// when HealthKit holds none — or, indistinguishably by design, when read
    /// access was denied.
    private func boundarySample(of sampleType: HKSampleType, order: SortOrder) async throws -> Date? {
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.sample(type: sampleType)],
            sortDescriptors: [SortDescriptor(\.startDate, order: order)],
            limit: 1)
        return try await descriptor.result(for: healthStore).first?.startDate
    }

    /// Local midnight of every day in `[from, to]` that has an activity
    /// summary. The predicate wants era/year/month/day components carrying
    /// the calendar, as in `ActivitySummarySync`.
    private func activitySummaryDays(from: Date, to: Date, calendar: Calendar) async throws -> [Date] {
        let units: Set<Calendar.Component> = [.era, .year, .month, .day]
        var startComps = calendar.dateComponents(units, from: from)
        startComps.calendar = calendar
        var endComps = calendar.dateComponents(units, from: to)
        endComps.calendar = calendar
        let predicate = HKQuery.predicate(forActivitySummariesBetweenStart: startComps, end: endComps)
        let summaries = try await HKActivitySummaryQueryDescriptor(predicate: predicate).result(for: healthStore)
        return summaries.compactMap { calendar.date(from: $0.dateComponents(for: calendar)) }
    }
}
