import Foundation
import HealthKit

/// The one `HKStatisticsCollectionQuery` this package runs, shared by the
/// sync engine (`AggregateSync`, which uploads the rows and moves watermarks)
/// and the explorer (`HealthExplorer.aggregatePreview`, which only looks).
///
/// It is a nonisolated enum rather than an engine method so that the preview
/// path never needs an engine — and therefore never has a `SyncStateStore`
/// to move a watermark in. What is in here is the query and its recovery
/// shape; what to do with a chunk of rows is the caller's closure.
///
/// The recovery: HealthKit can fail a statistics query with `Code=3` and
/// "no data source available" when its private cached data-source metadata
/// is missing for part of the window. Retrying the same statistics API over
/// smaller bucket-aligned windows (and re-anchored on the chunk start, except
/// for month buckets) gets past it, so `bucketsRecovering` splits the chunk
/// in half and recurses down to single buckets before giving up.
enum AggregateQuery {
    /// One statistics-collection query over `chunk`, one row per bucket —
    /// including empty buckets, as explicit `value: nil`, so that a recompute
    /// can clear a stale server value.
    static func buckets(
        for config: AggregateConfig,
        unit: HKUnit?,
        queryAnchor: Date,
        calendar: Calendar,
        chunk: DateInterval,
        healthStore: HKHealthStore
    ) async throws -> [AggregateSampleRow] {
        let quantityType = HKQuantityType(HKQuantityTypeIdentifier(rawValue: config.typeIdentifier))
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
                value: value(from: stat, function: function, unit: unit),
                unit: unitString
            ))
        }
        return rows
    }

    /// `buckets` over `chunk`, handing each successful window's rows to
    /// `onChunk` with the window they cover — the whole chunk when the first
    /// query succeeds, else each bucket-aligned subwindow the recovery split
    /// it into. Returns the number of rows delivered.
    ///
    /// `onChunk` is where the two callers differ: the engine uploads and
    /// records the subwindow's end as its watermark (so a run cut off mid
    /// recovery resumes from the last acked subwindow), the preview appends.
    /// `onRecoveryStart` fires once, when the first query failed with the
    /// missing-data-source error and splitting is about to begin — the engine
    /// logs there. Any other error, and the original error once a single
    /// bucket still fails, propagate.
    static func bucketsRecovering(
        for config: AggregateConfig,
        unit: HKUnit?,
        canonicalAnchor: Date,
        calendar: Calendar,
        chunk: DateInterval,
        healthStore: HKHealthStore,
        onRecoveryStart: (@Sendable (Error) async -> Void)? = nil,
        onChunk: @Sendable ([AggregateSampleRow], DateInterval) async throws -> Void
    ) async throws -> Int {
        do {
            let rows = try await buckets(
                for: config, unit: unit, queryAnchor: canonicalAnchor,
                calendar: calendar, chunk: chunk, healthStore: healthStore
            )
            try await onChunk(rows, chunk)
            return rows.count
        } catch {
            guard isHealthKitMissingDataSourceError(error) else { throw error }
            await onRecoveryStart?(error)
            let bucketing = AggregateBucketing(
                anchor: canonicalAnchor, intervalValue: config.intervalValue,
                intervalUnit: config.intervalUnit, calendar: calendar
            )
            return try await recover(
                config: config, unit: unit, canonicalAnchor: canonicalAnchor,
                bucketing: bucketing, calendar: calendar, chunk: chunk,
                healthStore: healthStore, originalError: error, onChunk: onChunk
            )
        }
    }

    private static func recover(
        config: AggregateConfig,
        unit: HKUnit?,
        canonicalAnchor: Date,
        bucketing: AggregateBucketing,
        calendar: Calendar,
        chunk: DateInterval,
        healthStore: HKHealthStore,
        originalError: Error,
        onChunk: @Sendable ([AggregateSampleRow], DateInterval) async throws -> Void
    ) async throws -> Int {
        do {
            let rows = try await buckets(
                for: config, unit: unit,
                queryAnchor: retryAnchor(for: config, canonicalAnchor: canonicalAnchor, chunk: chunk),
                calendar: calendar, chunk: chunk, healthStore: healthStore
            )
            try await onChunk(rows, chunk)
            return rows.count
        } catch {
            guard isHealthKitMissingDataSourceError(error) else { throw error }
            guard let (left, right) = bucketing.split(chunk) else { throw originalError }
            let leftCount = try await recover(
                config: config, unit: unit, canonicalAnchor: canonicalAnchor,
                bucketing: bucketing, calendar: calendar, chunk: left,
                healthStore: healthStore, originalError: error, onChunk: onChunk
            )
            let rightCount = try await recover(
                config: config, unit: unit, canonicalAnchor: canonicalAnchor,
                bucketing: bucketing, calendar: calendar, chunk: right,
                healthStore: healthStore, originalError: error, onChunk: onChunk
            )
            return leftCount + rightCount
        }
    }

    static func retryAnchor(
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
    static func isHealthKitMissingDataSourceError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == "com.apple.healthkit"
            && nsError.code == 3
            && nsError.localizedDescription.localizedCaseInsensitiveContains("no data source available")
    }

    static func value(
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
}
