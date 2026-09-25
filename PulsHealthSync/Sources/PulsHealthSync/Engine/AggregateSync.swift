import Foundation
import HealthKit
import os

// MARK: - Bucket math (pure, testable without HealthKit)

/// Bucket-boundary math for one aggregate series: boundaries are `anchor + N ×
/// interval`, always computed via `Calendar` so day/week/month buckets stay
/// correct across DST transitions and month-length changes.
struct AggregateBucketing: Sendable {
    var anchor: Date
    var intervalValue: Int
    var intervalUnit: AggregateIntervalUnit
    var calendar: Calendar

    init(
        anchor: Date, intervalValue: Int, intervalUnit: AggregateIntervalUnit,
        calendar: Calendar = .current
    ) {
        self.anchor = anchor
        self.intervalValue = max(1, intervalValue)
        self.intervalUnit = intervalUnit
        self.calendar = calendar
    }

    private var approximateSeconds: TimeInterval {
        Double(intervalValue) * intervalUnit.approximateSeconds
    }

    /// Start of bucket `index` (bucket 0 starts at the anchor).
    func start(ofBucket index: Int) -> Date {
        guard index != 0 else { return anchor }
        return calendar.date(
            byAdding: intervalUnit.dateComponents(value: intervalValue, times: index),
            to: anchor
        ) ?? anchor.addingTimeInterval(Double(index) * approximateSeconds)
    }

    /// Index of the bucket containing `date` (start ≤ date < next start).
    /// O(1): estimate by approximate length, then correct for calendar drift.
    func index(of date: Date) -> Int {
        var i = Int((date.timeIntervalSince(anchor) / approximateSeconds).rounded(.down))
        while start(ofBucket: i) > date { i -= 1 }
        while start(ofBucket: i + 1) <= date { i += 1 }
        return i
    }

    /// Largest bucket boundary at or before `date`, clamped to the anchor.
    func floorBoundary(_ date: Date) -> Date {
        date <= anchor ? anchor : start(ofBucket: index(of: date))
    }

    /// Bucket-aligned chunks covering [from, to), each at most `maxBuckets`
    /// buckets so years of small buckets never become one giant query/upload.
    /// `to` is expected to be a bucket boundary; `from` is floored to one.
    func chunks(
        from: Date, to: Date, maxBuckets: Int = AggregateSchedule.maxBucketsPerChunk
    ) -> [DateInterval] {
        guard to > anchor, from < to else { return [] }
        let first = max(0, index(of: max(from, anchor)))
        let end = index(of: to) // `to` is a boundary: the bucket starting there is excluded
        guard end > first else { return [] }
        var out: [DateInterval] = []
        var i = first
        while i < end {
            let j = Swift.min(i + maxBuckets, end)
            out.append(DateInterval(start: start(ofBucket: i), end: start(ofBucket: j)))
            i = j
        }
        return out
    }

    /// Split a bucket-aligned chunk into two smaller bucket-aligned chunks.
    /// Returns nil when the chunk is already one bucket wide.
    func split(_ chunk: DateInterval) -> (DateInterval, DateInterval)? {
        let first = index(of: chunk.start)
        let end = index(of: chunk.end)
        let count = end - first
        guard count > 1 else { return nil }
        let mid = start(ofBucket: first + count / 2)
        guard mid > chunk.start, mid < chunk.end else { return nil }
        return (
            DateInterval(start: chunk.start, end: mid),
            DateInterval(start: mid, end: chunk.end)
        )
    }
}

/// Window policy for aggregate recomputes. Statistics queries have no anchors,
/// so progress is a watermark plus a trailing lookback that re-covers buckets
/// late-arriving Watch data may have changed.
enum AggregateSchedule {
    static let maxBucketsPerChunk = 2_000
    /// Full-series recompute cadence — repairs edits/deletes older than the lookback.
    static let fullRecomputeInterval: TimeInterval = 30 * 86_400
    /// How far back the priority pass reaches before the first full pass runs.
    static let priorityWindowSpan: TimeInterval = 30 * 86_400

    static func lookback(intervalSeconds: TimeInterval) -> TimeInterval {
        max(7 * 86_400, 3 * intervalSeconds)
    }

    /// The settled window to (re)compute this run, or nil when nothing has
    /// settled yet. `to` is the last fully-elapsed bucket boundary at least
    /// `settleDelay` old; `from` trails the watermark by the lookback (or the
    /// start date on a full pass / first run).
    static func window(
        startDate: Date,
        computedThrough: Date?,
        fullPass: Bool,
        fullRecomputeThrough: Date? = nil,
        settleDelay: TimeInterval,
        now: Date,
        bucketing: AggregateBucketing,
        intervalSeconds: TimeInterval
    ) -> (from: Date, to: Date)? {
        let to = bucketing.floorBoundary(now.addingTimeInterval(-settleDelay))
        let from: Date
        if fullPass, let fullRecomputeThrough {
            // Initial and later scheduled full passes use a separate durable
            // cursor because the normal high-water mark may already be near now.
            from = max(startDate, fullRecomputeThrough)
        } else if !fullPass, let computedThrough {
            from = max(startDate, computedThrough.addingTimeInterval(
                -lookback(intervalSeconds: intervalSeconds)))
        } else {
            from = startDate
        }
        guard from < to else { return nil }
        return (from, to)
    }

    /// The bounded recent window a priority pass covers, or nil when nothing has
    /// settled yet. `to` is the same settled boundary a scheduled run would use;
    /// `from` trails it by `priorityWindowSpan`, or three buckets for intervals
    /// coarser than that, so a month-bucket series still gets a usable series
    /// rather than a single point. Clamped to the start date.
    ///
    /// This window is deliberately *not* a function of any watermark: the pass
    /// exists to put recent buckets on the server before the full pass has run,
    /// and it must be safe to run, repeat, or skip without changing what the
    /// full pass covers.
    static func priorityWindow(
        startDate: Date,
        settleDelay: TimeInterval,
        now: Date,
        bucketing: AggregateBucketing,
        intervalSeconds: TimeInterval
    ) -> (from: Date, to: Date)? {
        let to = bucketing.floorBoundary(now.addingTimeInterval(-settleDelay))
        let span = max(priorityWindowSpan, 3 * intervalSeconds)
        let from = max(startDate, bucketing.floorBoundary(to.addingTimeInterval(-span)))
        guard from < to else { return nil }
        return (from, to)
    }
}

/// What one run of an aggregate config is for.
enum AggregatePass: Sendable {
    /// The normal watermark-driven run: a trailing lookback, or a full recompute.
    case scheduled
    /// A bounded recent window, run ahead of the raw sweep on a first backfill.
    /// Moves no watermark — see `recordAggregateUploadWithoutWatermark`.
    case priority
}

/// Migration helper for state written before durable full-pass markers existed.
/// In that schema, `lastFullRecomputeAt == nil` plus a non-nil high-water mark
/// can only mean the initial full pass was interrupted after making progress.
enum FullRecomputeMigration {
    static func legacyInitialCursor(
        computedThrough: Date?,
        lastFullRecomputeAt: Date?,
        fullRecomputeStartedAt: Date?
    ) -> Date? {
        guard fullRecomputeStartedAt == nil, lastFullRecomputeAt == nil else { return nil }
        return computedThrough
    }
}

// MARK: - Engine integration

extension HealthSyncEngine {
    /// Run every enabled aggregate config, `maxConcurrentTypes` at a time.
    /// Called after the raw sweep by `syncAllEnabled`, and directly by the app.
    /// `syncRecentAggregates` is the sibling that runs *before* it.
    public func syncAllAggregates(reason: SyncReason = .incremental) async {
        await fanOutAggregates(
            await store.configuration.aggregates.filter(\.enabled),
            reason: reason, pass: .scheduled)
    }

    /// Cover a bounded recent window for every enabled aggregate config that has
    /// never been computed, ahead of the raw sweep on a first backfill.
    ///
    /// Two things make this worth its own phase rather than leaving it to the
    /// full pass. The server's daily views join `aggregate_series`, and only an
    /// aggregate line creates a row there — so until *some* aggregate has landed
    /// there is nothing daily to show however many raw samples have arrived. And
    /// the full pass runs oldest-first from the start date, so on a multi-year
    /// series the newest buckets are the last thing it produces.
    ///
    /// Self-limiting: a config whose `computedThrough` is set has already had
    /// buckets acked, so the window is already covered and this skips it. That
    /// also means an interrupted first backfill keeps re-covering the recent
    /// window on each run until the full pass makes its first acked progress,
    /// which is the behaviour we want while there is nothing else to show.
    public func syncRecentAggregates(reason: SyncReason = .backfill) async {
        var pending: [AggregateConfig] = []
        for agg in await store.configuration.aggregates where agg.enabled {
            if await store.aggregateState(for: agg.id).computedThrough == nil {
                pending.append(agg)
            }
        }
        await fanOutAggregates(pending, reason: reason, pass: .priority)
    }

    private func fanOutAggregates(
        _ configs: [AggregateConfig], reason: SyncReason, pass: AggregatePass
    ) async {
        guard !configs.isEmpty else { return }
        let concurrency = await store.configuration.maxConcurrentTypes
        await withTaskGroup(of: Void.self) { group in
            var iterator = configs.makeIterator()
            var inFlight = 0
            func addNext(_ group: inout TaskGroup<Void>) {
                if let next = iterator.next() {
                    inFlight += 1
                    group.addTask {
                        await self.syncAggregate(configID: next.id, reason: reason, pass: pass)
                    }
                }
            }
            for _ in 0..<max(1, concurrency) { addNext(&group) }
            while inFlight > 0 {
                await group.next()
                inFlight -= 1
                addNext(&group)
            }
        }
        notifyChanged()
    }

    /// Every enabled aggregate config for one type — what an observer fire runs.
    public func syncAggregates(forType identifier: String, reason: SyncReason = .incremental) async {
        let configs = await store.configuration.aggregates
            .filter { $0.enabled && $0.typeIdentifier == identifier }
        for config in configs {
            await syncAggregate(configID: config.id, reason: reason)
        }
    }

    /// Recompute + upload one aggregate config. Overlap-guarded like `sync(type:)`.
    public func syncAggregate(configID: UUID, reason: SyncReason = .incremental) async {
        await syncAggregate(configID: configID, reason: reason, pass: .scheduled)
    }

    func syncAggregate(configID: UUID, reason: SyncReason, pass: AggregatePass) async {
        let key = "agg:\(configID.uuidString)"
        guard !activeSyncs.contains(key) else {
            pendingResync.insert(key)
            return
        }
        activeSyncs.insert(key)
        defer { activeSyncs.remove(key) }

        var nextReason = reason
        var nextPass = pass
        repeat {
            await runAggregateSync(configID: configID, reason: nextReason, pass: nextPass)
            nextReason = .incremental
            // Work queued while this run was in flight is ordinary sync work,
            // whatever this run happened to be for.
            nextPass = .scheduled
        } while pendingResync.remove(key) != nil
    }

    private func runAggregateSync(
        configID: UUID, reason: SyncReason, pass: AggregatePass
    ) async {
        let config = await store.configuration
        guard let agg = config.aggregates.first(where: { $0.id == configID }), agg.enabled else {
            return
        }
        let typeID = agg.typeIdentifier
        guard let descriptor = HealthTypeCatalog.descriptor(for: typeID),
              descriptor.kind == .quantity else {
            await eventLog.log(.error, type: typeID, "Aggregate \(agg.summaryLabel): not a quantity type")
            return
        }
        // Re-validate even though the UI only offers legal functions: an illegal
        // option×aggregation-style combo raises an ObjC exception inside
        // HealthKit (a crash, not a catchable Swift error).
        guard HealthTypeCatalog.allowedAggregateFunctions(for: typeID).contains(agg.function) else {
            await eventLog.log(
                .error, type: typeID,
                "Aggregate \(agg.summaryLabel): \(agg.function.rawValue) is not supported by this type's aggregation style — skipping"
            )
            return
        }
        await ensureTransport()
        guard let transport else {
            await eventLog.log(.error, type: typeID, "No transport configured — set server URL and token")
            return
        }

        let calendar = Calendar.current
        let startDate = agg.startDate ?? config.startDate
        let anchor = calendar.startOfDay(for: startDate)
        let bucketing = AggregateBucketing(
            anchor: anchor, intervalValue: agg.intervalValue,
            intervalUnit: agg.intervalUnit, calendar: calendar
        )

        let now = Date()
        var state = await store.aggregateState(for: configID)
        // A priority pass never opens, resumes or completes a full recompute:
        // its whole contract is to leave the watermarks where it found them.
        let fullPass: Bool
        let resolvedWindow: (from: Date, to: Date)?
        switch pass {
        case .priority:
            fullPass = false
            resolvedWindow = AggregateSchedule.priorityWindow(
                startDate: anchor,
                settleDelay: agg.settleDelay,
                now: now,
                bucketing: bucketing,
                intervalSeconds: agg.approximateIntervalSeconds
            )
        case .scheduled:
            let fullPassDue = state.computedThrough == nil
                || state.lastFullRecomputeAt.map {
                    now.timeIntervalSince($0) > AggregateSchedule.fullRecomputeInterval
                } ?? true
            fullPass = state.fullRecomputeStartedAt != nil || fullPassDue
            if fullPass, state.fullRecomputeStartedAt == nil {
                let legacyCursor = FullRecomputeMigration.legacyInitialCursor(
                    computedThrough: state.computedThrough,
                    lastFullRecomputeAt: state.lastFullRecomputeAt,
                    fullRecomputeStartedAt: state.fullRecomputeStartedAt)
                await store.beginAggregateFullRecompute(
                    configID: configID, at: now, resumeThrough: legacyCursor)
                state = await store.aggregateState(for: configID)
            }
            resolvedWindow = AggregateSchedule.window(
                startDate: anchor,
                computedThrough: state.computedThrough,
                fullPass: fullPass,
                fullRecomputeThrough: state.fullRecomputeThrough,
                settleDelay: agg.settleDelay,
                now: now,
                bucketing: bucketing,
                intervalSeconds: agg.approximateIntervalSeconds
            )
        }
        guard let window = resolvedWindow else {
            // The last acked chunk may already have reached this run's settled
            // boundary before interruption, leaving only completion to persist.
            if fullPass {
                await store.markAggregateFullRecompute(configID: configID, at: now)
            }
            return // nothing settled yet
        }

        let chunks = bucketing.chunks(from: window.from, to: window.to)
        guard !chunks.isEmpty else {
            if fullPass { await store.markAggregateFullRecompute(configID: configID, at: now) }
            return
        }

        let runStart = ContinuousClock.now
        var totalBuckets = 0

        do {
            let quantityType = HKQuantityType(HKQuantityTypeIdentifier(rawValue: typeID))
            for chunk in chunks {
                try Task.checkCancellation()
                totalBuckets += try await computeAndUploadAggregateChunk(
                    config: agg, configID: configID, quantityType: quantityType,
                    unit: descriptor.unit, reason: reason, transport: transport,
                    calendar: calendar, anchor: anchor, chunk: chunk, pass: pass
                )
                notifyChanged()
            }
            if fullPass {
                await store.markAggregateFullRecompute(configID: configID, at: now)
            }
            let elapsed = (ContinuousClock.now - runStart).seconds
            await eventLog.log(
                .info, type: typeID,
                "Aggregate \(agg.summaryLabel): \(totalBuckets) buckets in \(chunks.count) batch(es), \(String(format: "%.1f", elapsed))s\(fullPass ? " (full recompute)" : "")\(pass == .priority ? " (recent window)" : "")"
            )
        } catch let error as HKError where error.code == .errorAuthorizationNotDetermined {
            await store.recordAggregateError(configID: configID, error: SyncError.authorizationNotDetermined)
            await eventLog.log(.error, type: typeID, "Aggregate \(agg.summaryLabel): Health access not determined")
        } catch let error as HKError where error.code == .errorDatabaseInaccessible {
            // Device locked — expected in background; watermark untouched.
            await eventLog.log(.warn, type: typeID, "Aggregate \(agg.summaryLabel): Health database locked — will retry on next wake")
        } catch is CancellationError {
            // Background time expired mid-series; the watermark sits at the last
            // acked chunk and the next wake resumes. Not a failure.
            await eventLog.log(.debug, type: typeID, "Aggregate \(agg.summaryLabel): cancelled — will resume on next wake")
        } catch {
            await store.recordAggregateError(configID: configID, error: error)
            await eventLog.log(.error, type: typeID, "Aggregate \(agg.summaryLabel) failed: \(error)")
        }
        notifyChanged()
    }

    /// Compute and upload one aggregate chunk. On HealthKit's internal missing
    /// data-source error, retry with the same statistics API over smaller
    /// bucket-aligned windows and advance the watermark after each successful
    /// subwindow.
    private func computeAndUploadAggregateChunk(
        config: AggregateConfig,
        configID: UUID,
        quantityType: HKQuantityType,
        unit: HKUnit?,
        reason: SyncReason,
        transport: any SyncTransport,
        calendar: Calendar,
        anchor: Date,
        chunk: DateInterval,
        pass: AggregatePass
    ) async throws -> Int {
        let leadingEmptyBackfill = pass == .scheduled
            ? await store.aggregateState(for: configID).leadingEmptyBackfill
            : false

        do {
            let rows = try await computeBucketsOnce(
                config: config, quantityType: quantityType, unit: unit,
                queryAnchor: anchor, calendar: calendar, chunk: chunk
            )
            return try await prepareAndUploadAggregateRows(
                rows,
                leadingEmptyBackfill: leadingEmptyBackfill,
                config: config,
                configID: configID,
                reason: reason,
                transport: transport,
                chunk: chunk,
                pass: pass
            )
        } catch {
            guard Self.isHealthKitMissingDataSourceError(error) else { throw error }
            await eventLog.log(
                .warn, type: config.typeIdentifier,
                "Aggregate \(config.summaryLabel): HealthKit statistics data-source cache unavailable — retrying with smaller HealthKit statistics windows"
            )
            let bucketing = AggregateBucketing(
                anchor: anchor, intervalValue: config.intervalValue,
                intervalUnit: config.intervalUnit, calendar: calendar
            )
            return try await computeAndUploadRecoveringFromMissingDataSource(
                config: config, configID: configID, quantityType: quantityType,
                unit: unit, reason: reason, transport: transport,
                canonicalAnchor: anchor, bucketing: bucketing,
                calendar: calendar, chunk: chunk, pass: pass,
                leadingEmptyBackfill: leadingEmptyBackfill,
                originalError: error
            )
        }
    }

    private func computeAndUploadRecoveringFromMissingDataSource(
        config: AggregateConfig,
        configID: UUID,
        quantityType: HKQuantityType,
        unit: HKUnit?,
        reason: SyncReason,
        transport: any SyncTransport,
        canonicalAnchor: Date,
        bucketing: AggregateBucketing,
        calendar: Calendar,
        chunk: DateInterval,
        pass: AggregatePass,
        leadingEmptyBackfill: Bool,
        originalError: Error
    ) async throws -> Int {
        do {
            let rows = try await computeBucketsOnce(
                config: config, quantityType: quantityType, unit: unit,
                queryAnchor: Self.retryAnchor(for: config, canonicalAnchor: canonicalAnchor, chunk: chunk),
                calendar: calendar, chunk: chunk
            )
            return try await prepareAndUploadAggregateRows(
                rows,
                leadingEmptyBackfill: leadingEmptyBackfill,
                config: config,
                configID: configID,
                reason: reason,
                transport: transport,
                chunk: chunk,
                pass: pass
            )
        } catch {
            guard Self.isHealthKitMissingDataSourceError(error) else { throw error }
            guard let (left, right) = bucketing.split(chunk) else { throw originalError }
            let leftCount = try await computeAndUploadRecoveringFromMissingDataSource(
                config: config, configID: configID, quantityType: quantityType,
                unit: unit, reason: reason, transport: transport,
                canonicalAnchor: canonicalAnchor, bucketing: bucketing,
                calendar: calendar, chunk: left, pass: pass,
                leadingEmptyBackfill: leadingEmptyBackfill,
                originalError: error
            )

            let rightLeadingEmptyBackfill = pass == .scheduled
                ? await store.aggregateState(for: configID).leadingEmptyBackfill
                : false

            let rightCount = try await computeAndUploadRecoveringFromMissingDataSource(
                config: config, configID: configID, quantityType: quantityType,
                unit: unit, reason: reason, transport: transport,
                canonicalAnchor: canonicalAnchor, bucketing: bucketing,
                calendar: calendar, chunk: right, pass: pass,
                leadingEmptyBackfill: rightLeadingEmptyBackfill,
                originalError: error
            )
            return leftCount + rightCount
        }
    }

    /// Apply sparse storage only to the leading portion of an initial
    /// scheduled backfill. Once the first real value is materialized, NULL
    /// buckets remain meaningful and are uploaded normally so recomputations
    /// and deletions can clear previously stored values.
    private func prepareAndUploadAggregateRows(
        _ rows: [AggregateSampleRow],
        leadingEmptyBackfill: Bool,
        config: AggregateConfig,
        configID: UUID,
        reason: SyncReason,
        transport: any SyncTransport,
        chunk: DateInterval,
        pass: AggregatePass
    ) async throws -> Int {
        guard pass == .scheduled, leadingEmptyBackfill else {
            try await uploadAggregateRows(
                rows, config: config, configID: configID, reason: reason,
                transport: transport, chunk: chunk, pass: pass
            )
            return rows.count
        }

        guard let firstValueIndex = rows.firstIndex(where: { $0.value != nil }) else {
            await store.recordAggregateSkippedEmptyChunk(
                configID: configID,
                newComputedThrough: chunk.end
            )
            return 0
        }

        let materializedRows = Array(rows[firstValueIndex...])
        try await uploadAggregateRows(
            materializedRows,
            config: config,
            configID: configID,
            reason: reason,
            transport: transport,
            chunk: chunk,
            pass: pass
        )
        return materializedRows.count
    }

    private func uploadAggregateRows(
        _ rows: [AggregateSampleRow],
        config: AggregateConfig,
        configID: UUID,
        reason: SyncReason,
        transport: any SyncTransport,
        chunk: DateInterval,
        pass: AggregatePass
    ) async throws {
        let batch = SyncBatch(
            deviceID: store.deviceID,
            type: config.typeIdentifier,
            reason: reason,
            samples: [],
            deletions: [],
            aggregates: rows
        )
        let uploadResult = try await transport.upload(batch)
        switch pass {
        case .scheduled:
            await store.recordAggregateUpload(
                configID: configID,
                newComputedThrough: chunk.end,
                buckets: rows.count,
                bytes: uploadResult.bytesSent
            )
        case .priority:
            // Counters only. `chunk.end` here is near *now*, so recording it as
            // progress would tell a full pass that everything up to the recent
            // window is already done and it would skip the entire history —
            // the aggregate twin of reusing a raw type's anchor for a
            // date-bounded query.
            await store.recordAggregateUploadWithoutWatermark(
                configID: configID,
                buckets: rows.count,
                bytes: uploadResult.bytesSent
            )
        }
        await reportWakeBatch(
            type: "agg:\(config.typeIdentifier)", samples: rows.count,
            deletions: 0, bytes: uploadResult.bytesSent)
    }

    private nonisolated static func retryAnchor(
        for config: AggregateConfig,
        canonicalAnchor: Date,
        chunk: DateInterval
    ) -> Date {
        // For month buckets, re-anchoring on a later boundary can change later
        // month boundaries when the original day does not exist in every month.
        config.intervalUnit == .month ? canonicalAnchor : chunk.start
    }

    /// HealthKit can fail statistics queries with Code=3 and this description
    /// when its private cached data-source metadata is missing. The recovery path
    /// still uses HealthKit statistics; it only changes anchor/window shape.
    nonisolated static func isHealthKitMissingDataSourceError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == "com.apple.healthkit"
            && nsError.code == 3
            && nsError.localizedDescription.localizedCaseInsensitiveContains("no data source available")
    }

    private func computeBucketsOnce(
        config: AggregateConfig,
        quantityType: HKQuantityType,
        unit: HKUnit?,
        queryAnchor: Date,
        calendar: Calendar,
        chunk: DateInterval
    ) async throws -> [AggregateSampleRow] {
        var predicate = HKQuery.predicateForSamples(
            withStart: chunk.start, end: chunk.end, options: .strictStartDate
        )
        if let model = config.deviceFilter.deviceModelString {
            predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                predicate,
                HKQuery.predicateForObjects(
                    withDeviceProperty: HKDevicePropertyKeyModel, allowedValues: [model]
                ),
            ])
        }
        let queryDescriptor = HKStatisticsCollectionQueryDescriptor(
            predicate: HKSamplePredicate.quantitySample(type: quantityType, predicate: predicate),
            options: config.function.statisticsOption,
            anchorDate: queryAnchor,
            intervalComponents: config.intervalComponents
        )
        let collection = try await queryDescriptor.result(for: healthStore)

        var rows: [AggregateSampleRow] = []
        let function = config.function
        let unitString = config.unitString
        // enumerateStatistics yields a statistics object for every interval in
        // range, including empty ones; the bucket at chunk.end is filtered out.
        collection.enumerateStatistics(from: chunk.start, to: chunk.end) { stat, _ in
            guard stat.startDate >= chunk.start, stat.startDate < chunk.end else { return }
            rows.append(AggregateSampleRow(
                type: config.typeIdentifier,
                function: function,
                intervalValue: config.intervalValue,
                intervalUnit: config.intervalUnit,
                deviceFilter: config.deviceFilter,
                bucketStart: stat.startDate,
                bucketEnd: stat.endDate,
                bucketStartContext: .deviceCurrent(for: stat.startDate, timeZone: calendar.timeZone),
                bucketEndContext: .deviceCurrent(for: stat.endDate, timeZone: calendar.timeZone),
                value: Self.value(from: stat, function: function, unit: unit),
                unit: unitString
            ))
        }
        return rows
    }

    private nonisolated static func value(
        from stat: HKStatistics, function: AggregateFunction, unit: HKUnit?
    ) -> Double? {
        if function == .duration {
            return stat.duration()?.doubleValue(for: .second())
        }
        let quantity: HKQuantity?
        switch function {
        case .sum: quantity = stat.sumQuantity()
        case .average: quantity = stat.averageQuantity()
        case .min: quantity = stat.minimumQuantity()
        case .max: quantity = stat.maximumQuantity()
        case .mostRecent: quantity = stat.mostRecentQuantity()
        case .duration: quantity = nil
        }
        guard let quantity, let unit, quantity.is(compatibleWith: unit) else { return nil }
        return quantity.doubleValue(for: unit)
    }

    // MARK: - Debug matrix validation

    /// Executes a one-day statistics query for every quantity type × allowed
    /// function and returns failure descriptions. The option×style legality
    /// check happens inside HealthKit at query time and surfaces as an ObjC
    /// exception (process crash) rather than a Swift error — so run this from
    /// the debug UI after catalog changes or on a new iOS release: surviving
    /// the call IS the pass signal for legality; returned strings are softer
    /// errors (auth etc.) for context.
    public func validateAggregateFunctionMatrix() async -> [String] {
        var failures: [String] = []
        var combos = 0
        let end = Date()
        let start = end.addingTimeInterval(-86_400)
        for descriptor in HealthTypeCatalog.quantityTypes {
            let functions = HealthTypeCatalog.allowedAggregateFunctions(for: descriptor.identifier)
            if functions.isEmpty {
                failures.append("\(descriptor.identifier): no allowed functions (unknown aggregation style)")
                continue
            }
            let quantityType = HKQuantityType(
                HKQuantityTypeIdentifier(rawValue: descriptor.identifier))
            for function in functions {
                combos += 1
                let queryDescriptor = HKStatisticsCollectionQueryDescriptor(
                    predicate: HKSamplePredicate.quantitySample(
                        type: quantityType,
                        predicate: HKQuery.predicateForSamples(
                            withStart: start, end: end, options: .strictStartDate)
                    ),
                    options: function.statisticsOption,
                    anchorDate: start,
                    intervalComponents: DateComponents(hour: 1)
                )
                do {
                    _ = try await queryDescriptor.result(for: healthStore)
                } catch let error as HKError where error.code == .errorAuthorizationNotDetermined {
                    continue // query was accepted; auth just isn't granted — legality verified
                } catch {
                    failures.append("\(descriptor.identifier) × \(function.rawValue): \(error)")
                }
            }
        }
        await eventLog.log(
            failures.isEmpty ? .info : .error,
            "Aggregate matrix validation: \(combos) combos executed, \(failures.count) failures"
        )
        return failures
    }
}
