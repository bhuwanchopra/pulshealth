import Foundation
import HealthKit
import Testing
@testable import PulsHealthSync

// MARK: - Catalog / function legality

@Suite struct AggregateCatalogTests {
    @Test func everyQuantityTypeHasAllowedFunctions() {
        for descriptor in HealthTypeCatalog.quantityTypes {
            let functions = HealthTypeCatalog.allowedAggregateFunctions(for: descriptor.identifier)
            #expect(!functions.isEmpty, "\(descriptor.identifier) has no allowed aggregate functions")
        }
    }

    @Test func nonQuantityTypesHaveNoAggregateFunctions() {
        #expect(HealthTypeCatalog.allowedAggregateFunctions(
            for: HealthTypeCatalog.workoutIdentifier).isEmpty)
        #expect(HealthTypeCatalog.allowedAggregateFunctions(
            for: "HKCategoryTypeIdentifierSleepAnalysis").isEmpty)
        #expect(HealthTypeCatalog.allowedAggregateFunctions(
            for: HealthTypeCatalog.electrocardiogramIdentifier).isEmpty)
        #expect(HealthTypeCatalog.allowedAggregateFunctions(for: "NotARealIdentifier").isEmpty)
    }

    // Mapping verified empirically by the app-hosted AggregateMatrixTests
    // (probes all 378 type×function combos against HealthKit).
    @Test func aggregationStylesMapToExpectedFunctions() {
        // Cumulative: sum (plus mostRecent/duration) but never average/min/max.
        let steps = HealthTypeCatalog.allowedAggregateFunctions(
            for: "HKQuantityTypeIdentifierStepCount")
        #expect(steps.contains(.sum) && steps.contains(.mostRecent) && steps.contains(.duration))
        #expect(!steps.contains(.average) && !steps.contains(.min) && !steps.contains(.max))

        // Discrete (heart rate is temporally weighted): avg/min/max/mostRecent
        // but never sum.
        let heartRate = HealthTypeCatalog.allowedAggregateFunctions(
            for: "HKQuantityTypeIdentifierHeartRate")
        #expect(heartRate.contains(.average) && heartRate.contains(.min)
            && heartRate.contains(.max) && heartRate.contains(.mostRecent))
        #expect(!heartRate.contains(.sum))

        // Discrete arithmetic behaves the same.
        let wrist = HealthTypeCatalog.allowedAggregateFunctions(
            for: "HKQuantityTypeIdentifierAppleSleepingWristTemperature")
        #expect(wrist.contains(.average) && wrist.contains(.min) && wrist.contains(.max))
        #expect(!wrist.contains(.sum))
    }

    /// Constructs a statistics-collection descriptor for every quantity type ×
    /// allowed function. HealthKit raises an ObjC exception (process crash, not
    /// a Swift error) for illegal option×style combos — surviving this test is
    /// the pass signal. Execution against a live store is covered by the app's
    /// debug "Validate Aggregate Functions" action.
    @Test func statisticsDescriptorsConstructForEveryAllowedCombo() {
        let end = Date(timeIntervalSince1970: 1_750_000_000)
        let start = end.addingTimeInterval(-86_400)
        var combos = 0
        for descriptor in HealthTypeCatalog.quantityTypes {
            let quantityType = HKQuantityType(
                HKQuantityTypeIdentifier(rawValue: descriptor.identifier))
            for function in HealthTypeCatalog.allowedAggregateFunctions(for: descriptor.identifier) {
                _ = HKStatisticsCollectionQueryDescriptor(
                    predicate: .quantitySample(
                        type: quantityType,
                        predicate: HKQuery.predicateForSamples(
                            withStart: start, end: end, options: .strictStartDate)
                    ),
                    options: function.statisticsOption,
                    anchorDate: start,
                    intervalComponents: DateComponents(hour: 1)
                )
                combos += 1
            }
        }
        #expect(combos >= HealthTypeCatalog.quantityTypes.count * 2)
    }

    @Test func seriesIdentityCoversNaturalKeyFieldsOnly() {
        var a = AggregateConfig(
            typeIdentifier: "HKQuantityTypeIdentifierStepCount", function: .sum,
            intervalValue: 1, intervalUnit: .day, deviceFilter: .all
        )
        var b = a
        b.id = UUID()
        b.settleDelay = 7_200
        b.startDate = Date(timeIntervalSince1970: 0)
        #expect(a.seriesIdentity == b.seriesIdentity, "id/settleDelay/startDate are not identity")
        a.intervalUnit = .week
        #expect(a.seriesIdentity != b.seriesIdentity)
    }

    @Test func durationUnitOverridesCatalogUnit() {
        let sum = AggregateConfig(
            typeIdentifier: "HKQuantityTypeIdentifierStepCount", function: .sum)
        #expect(sum.unitString == "count")
        let duration = AggregateConfig(
            typeIdentifier: "HKQuantityTypeIdentifierStepCount", function: .duration)
        #expect(duration.unitString == "s")
    }

    @Test func missingHealthKitDataSourceErrorIsRecognized() {
        let error = NSError(
            domain: "com.apple.healthkit",
            code: 3,
            userInfo: [
                NSLocalizedDescriptionKey: "Unable to invalidate interval: no data source available."
            ])
        #expect(AggregateQuery.isHealthKitMissingDataSourceError(error))

        let unrelated = NSError(
            domain: "com.apple.healthkit",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "Invalid argument"])
        #expect(!AggregateQuery.isHealthKitMissingDataSourceError(unrelated))
    }

    @Test func legacyInitialFullPassProgressMigratesButScheduledPassDoesNot() {
        let cursor = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(FullRecomputeMigration.legacyInitialCursor(
            computedThrough: cursor,
            lastFullRecomputeAt: nil,
            fullRecomputeStartedAt: nil
        ) == cursor)
        #expect(FullRecomputeMigration.legacyInitialCursor(
            computedThrough: cursor,
            lastFullRecomputeAt: cursor.addingTimeInterval(-31 * 86_400),
            fullRecomputeStartedAt: nil
        ) == nil)
        #expect(FullRecomputeMigration.legacyInitialCursor(
            computedThrough: cursor,
            lastFullRecomputeAt: nil,
            fullRecomputeStartedAt: cursor.addingTimeInterval(-100)
        ) == nil)
    }
}

// MARK: - Bucket math

@Suite struct AggregateBucketingTests {
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    @Test func hourBucketsFloorAndIndex() {
        let anchor = Date(timeIntervalSince1970: 1_700_000_000)
        let b = AggregateBucketing(anchor: anchor, intervalValue: 1, intervalUnit: .hour, calendar: utc)
        #expect(b.start(ofBucket: 0) == anchor)
        #expect(b.start(ofBucket: 3) == anchor.addingTimeInterval(3 * 3_600))
        #expect(b.index(of: anchor) == 0)
        #expect(b.index(of: anchor.addingTimeInterval(3_599)) == 0)
        #expect(b.index(of: anchor.addingTimeInterval(3_600)) == 1)
        #expect(b.floorBoundary(anchor.addingTimeInterval(5_000)) == anchor.addingTimeInterval(3_600))
        #expect(b.floorBoundary(anchor.addingTimeInterval(-50)) == anchor)
    }

    @Test func dayBucketsStayOnMidnightAcrossSpringForward() {
        var denver = Calendar(identifier: .gregorian)
        denver.timeZone = TimeZone(identifier: "America/Denver")!
        // US DST starts 2026-03-08: that day is 23 hours long in Denver.
        let anchor = denver.date(from: DateComponents(year: 2026, month: 3, day: 7))!
        let b = AggregateBucketing(anchor: anchor, intervalValue: 1, intervalUnit: .day, calendar: denver)
        let day1 = b.start(ofBucket: 1) // 2026-03-08 00:00 MST
        let day2 = b.start(ofBucket: 2) // 2026-03-09 00:00 MDT
        #expect(day1.timeIntervalSince(anchor) == 86_400)
        #expect(day2.timeIntervalSince(day1) == 82_800, "spring-forward day must be 23h, not 24h")
        #expect(denver.component(.hour, from: day2) == 0, "boundary stays on calendar midnight")
        #expect(b.index(of: day2) == 2)
        #expect(b.floorBoundary(day2.addingTimeInterval(-1)) == day1)
    }

    @Test func weekAndMonthBuckets() {
        let anchor = utc.date(from: DateComponents(year: 2026, month: 1, day: 1))!
        let weeks = AggregateBucketing(anchor: anchor, intervalValue: 2, intervalUnit: .week, calendar: utc)
        #expect(weeks.start(ofBucket: 1) == anchor.addingTimeInterval(14 * 86_400))

        let months = AggregateBucketing(anchor: anchor, intervalValue: 1, intervalUnit: .month, calendar: utc)
        #expect(months.start(ofBucket: 1) == utc.date(from: DateComponents(year: 2026, month: 2, day: 1))!)
        #expect(months.start(ofBucket: 12) == utc.date(from: DateComponents(year: 2027, month: 1, day: 1))!)
        #expect(months.index(of: utc.date(from: DateComponents(year: 2026, month: 3, day: 15))!) == 2)
    }

    @Test func chunksCapBucketCountAndAlign() {
        let anchor = Date(timeIntervalSince1970: 1_700_000_000)
        let b = AggregateBucketing(anchor: anchor, intervalValue: 1, intervalUnit: .minute, calendar: utc)
        let to = anchor.addingTimeInterval(3_000 * 60)
        let chunks = b.chunks(from: anchor, to: to)
        #expect(chunks.count == 2)
        #expect(chunks[0].start == anchor)
        #expect(chunks[0].end == anchor.addingTimeInterval(2_000 * 60))
        #expect(chunks[1].start == chunks[0].end)
        #expect(chunks[1].end == to)
    }

    @Test func splitBisectsBucketAlignedChunks() {
        let anchor = Date(timeIntervalSince1970: 1_700_000_000)
        let b = AggregateBucketing(anchor: anchor, intervalValue: 1, intervalUnit: .hour, calendar: utc)
        let chunk = DateInterval(start: anchor, end: anchor.addingTimeInterval(5 * 3_600))
        let split = b.split(chunk)
        #expect(split?.0.start == anchor)
        #expect(split?.0.end == anchor.addingTimeInterval(2 * 3_600))
        #expect(split?.1.start == anchor.addingTimeInterval(2 * 3_600))
        #expect(split?.1.end == chunk.end)

        let oneBucket = DateInterval(start: anchor, end: anchor.addingTimeInterval(3_600))
        #expect(b.split(oneBucket) == nil)
    }

    @Test func chunksEmptyWhenNothingToCompute() {
        let anchor = Date(timeIntervalSince1970: 1_700_000_000)
        let b = AggregateBucketing(anchor: anchor, intervalValue: 1, intervalUnit: .hour, calendar: utc)
        #expect(b.chunks(from: anchor, to: anchor).isEmpty)
        #expect(b.chunks(from: anchor.addingTimeInterval(7_200), to: anchor.addingTimeInterval(3_600)).isEmpty)
        // Window entirely before the anchor.
        #expect(b.chunks(from: anchor.addingTimeInterval(-7_200), to: anchor).isEmpty)
        // Partial bucket only (to is not past the first boundary).
        #expect(b.chunks(from: anchor, to: anchor.addingTimeInterval(3_600)).count == 1)
    }

    @Test func windowRespectsSettleDelayAndWatermark() {
        let anchor = Date(timeIntervalSince1970: 1_700_000_000)
        let b = AggregateBucketing(anchor: anchor, intervalValue: 1, intervalUnit: .hour, calendar: utc)
        let now = anchor.addingTimeInterval(10 * 3_600 + 1_800) // 10.5h after anchor

        // No settle delay: everything through the last complete bucket (10h).
        let full = AggregateSchedule.window(
            startDate: anchor, computedThrough: nil, fullPass: true,
            settleDelay: 0, now: now, bucketing: b, intervalSeconds: 3_600)
        #expect(full?.from == anchor)
        #expect(full?.to == anchor.addingTimeInterval(10 * 3_600))

        // 1h settle delay shaves the most recent settled boundary back.
        let settled = AggregateSchedule.window(
            startDate: anchor, computedThrough: nil, fullPass: true,
            settleDelay: 3_600, now: now, bucketing: b, intervalSeconds: 3_600)
        #expect(settled?.to == anchor.addingTimeInterval(9 * 3_600))

        // Inside the settle window entirely: nothing to do.
        #expect(AggregateSchedule.window(
            startDate: anchor, computedThrough: nil, fullPass: true,
            settleDelay: 12 * 3_600, now: now, bucketing: b, intervalSeconds: 3_600) == nil)

        // Incremental: from trails the watermark by the lookback, clamped to start.
        let watermark = anchor.addingTimeInterval(8 * 3_600)
        let incremental = AggregateSchedule.window(
            startDate: anchor, computedThrough: watermark, fullPass: false,
            settleDelay: 0, now: now, bucketing: b, intervalSeconds: 3_600)
        #expect(incremental?.from == anchor, "7-day lookback clamps to startDate here")
        #expect(incremental?.to == anchor.addingTimeInterval(10 * 3_600))

        // Full pass ignores the watermark.
        let fullPass = AggregateSchedule.window(
            startDate: anchor, computedThrough: watermark, fullPass: true,
            settleDelay: 0, now: now, bucketing: b, intervalSeconds: 3_600)
        #expect(fullPass?.from == anchor)

        // An interrupted initial full pass resumes at its last acked chunk. This
        // is distinct from a later monthly full pass, which intentionally starts
        // at the original anchor as asserted above.
        let resumedFullPass = AggregateSchedule.window(
            startDate: anchor, computedThrough: watermark, fullPass: true,
            fullRecomputeThrough: watermark,
            settleDelay: 0, now: now, bucketing: b, intervalSeconds: 3_600)
        #expect(resumedFullPass?.from == watermark)
        #expect(resumedFullPass?.to == anchor.addingTimeInterval(10 * 3_600))

        // Lookback scales with the interval: max(7d, 3×interval).
        #expect(AggregateSchedule.lookback(intervalSeconds: 3_600) == 7 * 86_400)
        #expect(AggregateSchedule.lookback(intervalSeconds: 5 * 86_400) == 15 * 86_400)
    }

    // MARK: Priority window

    @Test func priorityWindowTrailsNowAndIgnoresEveryWatermark() {
        let anchor = Date(timeIntervalSince1970: 1_700_000_000)
        let b = AggregateBucketing(anchor: anchor, intervalValue: 1, intervalUnit: .day, calendar: utc)
        // A year of history, so the 30-day window is a small slice of it.
        let now = anchor.addingTimeInterval(365 * 86_400)

        let window = AggregateSchedule.priorityWindow(
            startDate: anchor, settleDelay: 0, now: now,
            bucketing: b, intervalSeconds: 86_400)
        #expect(window?.to == anchor.addingTimeInterval(365 * 86_400))
        #expect(window?.from == anchor.addingTimeInterval(335 * 86_400),
                "30 days back from the settled boundary")

        // The settle delay moves both ends, exactly as it does for a scheduled run.
        let settled = AggregateSchedule.priorityWindow(
            startDate: anchor, settleDelay: 2 * 86_400, now: now,
            bucketing: b, intervalSeconds: 86_400)
        #expect(settled?.to == anchor.addingTimeInterval(363 * 86_400))
        #expect(settled?.from == anchor.addingTimeInterval(333 * 86_400))
    }

    @Test func priorityWindowClampsToStartDateAndWidensForCoarseBuckets() {
        let anchor = Date(timeIntervalSince1970: 1_700_000_000)
        let day = AggregateBucketing(anchor: anchor, intervalValue: 1, intervalUnit: .day, calendar: utc)

        // Less history than the window: it cannot reach past the start date.
        let short = AggregateSchedule.priorityWindow(
            startDate: anchor, settleDelay: 0, now: anchor.addingTimeInterval(5 * 86_400),
            bucketing: day, intervalSeconds: 86_400)
        #expect(short?.from == anchor)
        #expect(short?.to == anchor.addingTimeInterval(5 * 86_400))

        // Nothing settled yet — no window at all rather than an empty one.
        #expect(AggregateSchedule.priorityWindow(
            startDate: anchor, settleDelay: 0, now: anchor,
            bucketing: day, intervalSeconds: 86_400) == nil)

        // A month-bucket series would get a single point from a flat 30 days, so
        // the span widens to three buckets — the same shape as `lookback`.
        let month = AggregateBucketing(anchor: anchor, intervalValue: 1, intervalUnit: .month, calendar: utc)
        let now = anchor.addingTimeInterval(365 * 86_400)
        let coarse = AggregateSchedule.priorityWindow(
            startDate: anchor, settleDelay: 0, now: now,
            bucketing: month, intervalSeconds: 30 * 86_400)
        let buckets = month.chunks(from: coarse!.from, to: coarse!.to)
            .reduce(0) { $0 + month.index(of: $1.end) - month.index(of: $1.start) }
        #expect(buckets >= 3, "coarse intervals still get a usable series")
    }
}

// MARK: - Wire format

@Suite struct AggregateWireTests {
    private func makeRow(value: Double?) -> AggregateSampleRow {
        AggregateSampleRow(
            type: "HKQuantityTypeIdentifierHeartRate", function: .average,
            intervalValue: 1, intervalUnit: .hour, deviceFilter: .watch,
            bucketStart: Date(timeIntervalSince1970: 1_700_000_000),
            bucketEnd: Date(timeIntervalSince1970: 1_700_003_600),
            value: value, unit: "count/min"
        )
    }

    @Test func ndjsonAppendsAggregateLinesAfterRoutesAndCountsThem() throws {
        let batch = SyncBatch(
            deviceID: "d", type: "HKQuantityTypeIdentifierHeartRate", reason: .incremental,
            samples: [], deletions: [],
            routes: [RoutePayload(workoutUUID: UUID(), points: [])],
            aggregates: [makeRow(value: 62.4), makeRow(value: nil)]
        )
        let data = try BatchSerializer.ndjson(for: batch)
        let lines = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 1 + 1 + 2)

        let header = try JSONDecoder.puls.decode(
            BatchSerializer.Header.self, from: Data(lines[0].utf8))
        #expect(header.aggregateCount == 2)
        #expect(header.routeCount == 1)

        // Routes come before aggregates so the server can parse in declared order.
        #expect(lines[1].contains("\"route\""))
        let firstAggregate = try JSONSerialization.jsonObject(
            with: Data(lines[2].utf8)) as! [String: Any]
        let payload = firstAggregate["aggregate"] as! [String: Any]
        #expect(payload["func"] as! String == "average")
        #expect(payload["type"] as! String == "HKQuantityTypeIdentifierHeartRate")
        #expect(payload["bucketStart"] as! Double == 1_700_000_000_000) // epoch-ms
        #expect(payload["value"] as! Double == 62.4)
        #expect(payload["deviceFilter"] as! String == "watch")

        // The empty bucket carries an explicit null, not an omitted key —
        // the server upsert must clear stale values.
        #expect(lines[3].contains("\"value\":null"))
    }

    @Test func aggregateRowRoundTripsIncludingNilValue() throws {
        for value in [62.4, nil] as [Double?] {
            let row = makeRow(value: value)
            let decoded = try JSONDecoder.puls.decode(
                AggregateSampleRow.self, from: JSONEncoder.puls.encode(row))
            #expect(decoded == row)
        }
    }

    @Test func headerWithoutAggregateCountDecodesAsZero() throws {
        let legacy = #"{"batchID":"\#(UUID().uuidString)","deviceID":"d","type":"t","reason":"backfill","exportedAt":0,"sampleCount":3,"deletionCount":0,"routeCount":0}"#
        let header = try JSONDecoder.puls.decode(
            BatchSerializer.Header.self, from: Data(legacy.utf8))
        #expect(header.aggregateCount == 0)
        #expect(header.sampleCount == 3)
    }

    @Test func configWithoutAggregatesDecodesToEmpty() throws {
        let legacy = #"{"enabledTypes":[],"startDate":0,"maxConcurrentTypes":4,"batchSize":1000}"#
        let config = try JSONDecoder.puls.decode(SyncConfiguration.self, from: Data(legacy.utf8))
        #expect(config.aggregates.isEmpty)

        var withAggregate = config
        withAggregate.aggregates = [AggregateConfig(
            typeIdentifier: "HKQuantityTypeIdentifierStepCount", function: .sum)]
        let reencoded = try JSONDecoder.puls.decode(
            SyncConfiguration.self, from: JSONEncoder.puls.encode(withAggregate))
        #expect(reencoded.aggregates == withAggregate.aggregates)
    }

    @Test func observedTypesAreUnionOfRawAndEnabledAggregates() {
        var config = SyncConfiguration(enabledTypes: ["HKQuantityTypeIdentifierHeartRate"])
        config.aggregates = [
            AggregateConfig(typeIdentifier: "HKQuantityTypeIdentifierStepCount", function: .sum),
            AggregateConfig(
                typeIdentifier: "HKQuantityTypeIdentifierVO2Max", function: .average,
                enabled: false),
        ]
        #expect(config.aggregateTypeIdentifiers == ["HKQuantityTypeIdentifierStepCount"])
        #expect(config.observedTypeIdentifiers == [
            "HKQuantityTypeIdentifierHeartRate", "HKQuantityTypeIdentifierStepCount",
        ])
    }
}

// MARK: - State store

@Suite struct AggregateStateStoreTests {
    private func makeDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("puls-tests-\(UUID())", isDirectory: true)
    }

    @Test func recordAdvancesWatermarkOnlyForward() async {
        let store = SyncStateStore(directory: makeDir())
        let configID = UUID()
        let mark = Date(timeIntervalSince1970: 2_000_000)
        await store.recordAggregateUpload(
            configID: configID, newComputedThrough: mark, buckets: 24, bytes: 512)
        var state = await store.aggregateState(for: configID)
        #expect(state.computedThrough == mark)
        #expect(state.totalBucketsUploaded == 24)
        #expect(state.totalBatchesUploaded == 1)
        #expect(state.totalBytesUploaded == 512)
        #expect(state.lastError == nil)

        // A trailing-lookback recompute ends before the watermark — never regress.
        await store.recordAggregateUpload(
            configID: configID, newComputedThrough: mark.addingTimeInterval(-3_600),
            buckets: 1, bytes: 64)
        state = await store.aggregateState(for: configID)
        #expect(state.computedThrough == mark)
        #expect(state.totalBucketsUploaded == 25)
    }

    @Test func priorityUploadsCountButMoveNoWatermark() async {
        let store = SyncStateStore(directory: makeDir())
        let configID = UUID()
        let now = Date(timeIntervalSince1970: 2_000_000)

        // The priority pass runs before anything has been computed. Its chunks
        // end near now; recording that as progress would tell the full pass the
        // whole history was already done.
        await store.recordAggregateUploadWithoutWatermark(
            configID: configID, buckets: 30, bytes: 900)
        var state = await store.aggregateState(for: configID)
        #expect(state.computedThrough == nil, "the full pass must still start at the start date")
        #expect(state.fullRecomputeThrough == nil)
        #expect(state.totalBucketsUploaded == 30, "the buckets really were uploaded")
        #expect(state.totalBatchesUploaded == 1)
        #expect(state.totalBytesUploaded == 900)
        #expect(state.lastComputedAt != nil)

        // Same during an in-flight full pass, where advancing `fullRecomputeThrough`
        // would make the pass skip everything older than the recent window.
        await store.beginAggregateFullRecompute(configID: configID, at: now, resumeThrough: nil)
        await store.recordAggregateUploadWithoutWatermark(
            configID: configID, buckets: 30, bytes: 900)
        state = await store.aggregateState(for: configID)
        #expect(state.fullRecomputeStartedAt == now)
        #expect(state.fullRecomputeThrough == nil)
        #expect(state.computedThrough == nil)
        #expect(state.totalBucketsUploaded == 60)

        // A scheduled ack still advances both, so the priority pass is the only
        // thing this changes.
        await store.recordAggregateUpload(
            configID: configID, newComputedThrough: now, buckets: 1, bytes: 10)
        state = await store.aggregateState(for: configID)
        #expect(state.computedThrough == now)
        #expect(state.fullRecomputeThrough == now)
    }

    @Test func errorsRecordedAndClearedOnSuccess() async {
        let store = SyncStateStore(directory: makeDir())
        let configID = UUID()
        struct Boom: Error {}
        await store.recordAggregateError(configID: configID, error: Boom())
        #expect(await store.aggregateState(for: configID).lastError != nil)
        await store.recordAggregateUpload(
            configID: configID, newComputedThrough: Date(), buckets: 1, bytes: 1)
        #expect(await store.aggregateState(for: configID).lastError == nil)
    }

    @Test func resetClearsWatermarkAndCounters() async {
        let store = SyncStateStore(directory: makeDir())
        let configID = UUID()
        await store.recordAggregateUpload(
            configID: configID, newComputedThrough: Date(), buckets: 5, bytes: 100)
        await store.markAggregateFullRecompute(configID: configID)
        await store.resetAggregate(configID: configID)
        let state = await store.aggregateState(for: configID)
        #expect(state.computedThrough == nil)
        #expect(state.lastFullRecomputeAt == nil)
        #expect(state.totalBucketsUploaded == 0)
    }

    @Test func pruneDropsStateForDeletedConfigs() async {
        let store = SyncStateStore(directory: makeDir())
        let keep = UUID()
        let drop = UUID()
        await store.recordAggregateUpload(
            configID: keep, newComputedThrough: Date(), buckets: 1, bytes: 1)
        await store.recordAggregateUpload(
            configID: drop, newComputedThrough: Date(), buckets: 1, bytes: 1)
        await store.pruneAggregateStates(keeping: [keep])
        #expect(await store.aggregateState(for: keep).computedThrough != nil)
        #expect(await store.aggregateState(for: drop).computedThrough == nil)
    }

    @Test func persistsAcrossInstances() async {
        let dir = makeDir()
        let store = SyncStateStore(directory: dir)
        let configID = UUID()
        let mark = Date(timeIntervalSince1970: 3_000_000)
        await store.recordAggregateUpload(
            configID: configID, newComputedThrough: mark, buckets: 7, bytes: 70)
        await store.persistNow()

        let reloaded = SyncStateStore(directory: dir)
        let state = await reloaded.aggregateState(for: configID)
        #expect(state.computedThrough == mark)
        #expect(state.totalBucketsUploaded == 7)
    }

    @Test func fullPassCursorPersistsAndCompletionClearsIt() async {
        let dir = makeDir()
        let configID = UUID()
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        let cursor = started.addingTimeInterval(30 * 86_400)
        let store = SyncStateStore(directory: dir)
        await store.beginAggregateFullRecompute(configID: configID, at: started)
        await store.recordAggregateUpload(
            configID: configID, newComputedThrough: cursor, buckets: 24, bytes: 100)
        await store.persistNow()

        let reloaded = SyncStateStore(directory: dir)
        var state = await reloaded.aggregateState(for: configID)
        #expect(state.fullRecomputeStartedAt == started)
        #expect(state.fullRecomputeThrough == cursor)

        let completed = cursor.addingTimeInterval(1)
        await reloaded.markAggregateFullRecompute(configID: configID, at: completed)
        state = await reloaded.aggregateState(for: configID)
        #expect(state.lastFullRecomputeAt == completed)
        #expect(state.fullRecomputeStartedAt == nil)
        #expect(state.fullRecomputeThrough == nil)
    }

    @Test func stateWithoutFullPassFieldsStillDecodes() throws {
        let id = UUID()
        let old = #"{"configID":"\#(id.uuidString)","computedThrough":1700000000000,"totalBucketsUploaded":2,"totalBatchesUploaded":1,"totalBytesUploaded":64}"#
        let state = try JSONDecoder.puls.decode(
            AggregateSyncState.self, from: Data(old.utf8))
        #expect(state.configID == id)
        #expect(state.computedThrough == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(state.fullRecomputeStartedAt == nil)
        #expect(state.fullRecomputeThrough == nil)
    }

    /// A state file written before aggregates existed must load intact —
    /// the file is decoded with `try?`, so a strict decoder would silently
    /// reset every anchor.
    @Test func legacyStateFileLoadsWithoutAggregateStates() async throws {
        let dir = makeDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let legacy = #"""
        {"configuration":{"enabledTypes":["type-a"],"startDate":0,"maxConcurrentTypes":4,"batchSize":1000},
         "typeStates":{"type-a":{"identifier":"type-a","backfillComplete":true,"totalSamplesExported":42,"totalDeletionsExported":0,"totalBytesUploaded":0,"totalBatchesUploaded":1}},
         "deviceID":"legacy-device"}
        """#.replacingOccurrences(of: "\n", with: "")
        try Data(legacy.utf8).write(to: dir.appendingPathComponent("sync-state.json"))

        let store = SyncStateStore(directory: dir)
        #expect(await store.deviceID == "legacy-device")
        #expect(await store.state(for: "type-a").totalSamplesExported == 42)
        #expect(await store.aggregateStates.isEmpty)
    }
}
