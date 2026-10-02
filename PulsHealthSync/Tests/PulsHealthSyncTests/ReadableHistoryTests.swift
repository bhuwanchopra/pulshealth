import Foundation
import HealthKit
import Testing
@testable import PulsHealthSync

// iOS 27 limited history access (`ReadableHistory`): the decisions that keep
// unreadable history from reaching the server as empty, and the re-sweep
// rule. HealthKit is not mockable, so everything here is the pure half —
// the engine calls these with what HealthKit reported.

private let day: TimeInterval = 86_400

/// Pacific time: the zone the iOS 27 simulator measurements were taken in,
/// and one with both DST transitions.
private let pacific: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    return calendar
}()

private func local(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0, _ s: Int = 0) -> Date {
    pacific.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min, second: s))!
}

@Suite struct ReadableHistoryChangeTests {
    let limit = Date(timeIntervalSince1970: 1_788_223_011.807) // what the simulator reported

    @Test func noLimitOnEitherSideIsUnchanged() {
        #expect(ReadableHistory.change(from: nil, to: nil) == .unchanged)
    }

    @Test func theSameDateIsUnchangedSoNothingLoops() {
        #expect(ReadableHistory.change(from: limit, to: limit) == .unchanged)
        // Jitter either way is not a new grant — nor is a DST step, which
        // moves a local-midnight date by exactly an hour.
        #expect(ReadableHistory.change(from: limit, to: limit.addingTimeInterval(-59 * 60)) == .unchanged)
        #expect(ReadableHistory.change(from: limit, to: limit.addingTimeInterval(59 * 60)) == .unchanged)
        #expect(ReadableHistory.change(from: limit, to: limit.addingTimeInterval(-3_600)) == .unchanged)
        #expect(ReadableHistory.change(from: limit, to: limit.addingTimeInterval(3_600)) == .unchanged)
    }

    @Test func theToleranceIsADay() {
        #expect(ReadableHistory.change(from: limit, to: limit.addingTimeInterval(-23 * 3_600)) == .unchanged)
        #expect(ReadableHistory.change(from: limit, to: limit.addingTimeInterval(23 * 3_600)) == .unchanged)
        #expect(ReadableHistory.change(from: limit, to: limit.addingTimeInterval(-day)) == .unchanged)
        #expect(ReadableHistory.change(from: limit, to: limit.addingTimeInterval(-25 * 3_600)) == .widened)
        #expect(ReadableHistory.change(from: limit, to: limit.addingTimeInterval(25 * 3_600)) == .narrowed)
    }

    // MARK: - Confirming a widening

    /// Settings → Health → (app) → (type) → None drops the type out of
    /// `earliestAuthorizedSampleDate(for:)` exactly like Full Access does.
    /// No older sample, no widening: the recorded date stands.
    @Test func noLimitReportedButNothingOlderReadableIsUnchanged() {
        let resolved = ReadableHistory.resolve(recorded: limit, reported: nil, olderHistoryFound: false)
        #expect(resolved == limit)
        #expect(ReadableHistory.change(from: limit, to: resolved) == .unchanged)
    }

    @Test func noLimitReportedAndAnOlderSampleReadIsAWidening() {
        let resolved = ReadableHistory.resolve(recorded: limit, reported: nil, olderHistoryFound: true)
        #expect(resolved == nil)
        #expect(ReadableHistory.change(from: limit, to: resolved) == .widened)
    }

    @Test func anEarlierDateNeedsAnOlderSampleToo() {
        let earlier = limit.addingTimeInterval(-10 * day)
        #expect(ReadableHistory.resolve(recorded: limit, reported: earlier, olderHistoryFound: false) == limit)
        #expect(ReadableHistory.resolve(recorded: limit, reported: earlier, olderHistoryFound: true) == earlier)
    }

    @Test func onlyWideningsAreQuestioned() {
        let later = limit.addingTimeInterval(10 * day)
        // A narrowing or the same date passes through whatever the probe says.
        #expect(ReadableHistory.resolve(recorded: limit, reported: later, olderHistoryFound: false) == later)
        #expect(ReadableHistory.resolve(recorded: nil, reported: limit, olderHistoryFound: false) == limit)
        #expect(ReadableHistory.resolve(recorded: limit, reported: limit, olderHistoryFound: false) == limit)
        #expect(ReadableHistory.resolve(recorded: nil, reported: nil, olderHistoryFound: false) == nil)
    }

    // MARK: - What a refresh does

    @Test func aRefreshActsOnAConfirmedChange() {
        #expect(ReadableHistory.refreshAction(change: .unchanged, hasProgress: true, isActive: false) == .none)
        #expect(ReadableHistory.refreshAction(change: .narrowed, hasProgress: true, isActive: false) == .record)
        #expect(ReadableHistory.refreshAction(change: .widened, hasProgress: true, isActive: false) == .resweep)
        #expect(ReadableHistory.refreshAction(change: .widened, hasProgress: false, isActive: false) == .record)
    }

    /// A run holding the type could ack a page read under the old limit
    /// after a widened date was written, progress or not: nothing is
    /// written until it lets go.
    @Test func aWideningWaitsForTheRunHoldingTheType() {
        #expect(ReadableHistory.refreshAction(change: .widened, hasProgress: true, isActive: true)
            == .deferUntilReleased)
        #expect(ReadableHistory.refreshAction(change: .widened, hasProgress: false, isActive: true)
            == .deferUntilReleased)
        // A narrowing is safe to note under a run: it only adds a clamp.
        #expect(ReadableHistory.refreshAction(change: .narrowed, hasProgress: true, isActive: true) == .record)
        #expect(ReadableHistory.refreshAction(change: .unchanged, hasProgress: true, isActive: true) == .none)
    }

    @Test func aLimitGoingAwayWidens() {
        #expect(ReadableHistory.change(from: limit, to: nil) == .widened)
    }

    @Test func anEarlierDateWidens() {
        #expect(ReadableHistory.change(from: limit, to: limit.addingTimeInterval(-2 * day)) == .widened)
    }

    @Test func aNewLimitOrALaterDateNarrows() {
        #expect(ReadableHistory.change(from: nil, to: limit) == .narrowed)
        #expect(ReadableHistory.change(from: limit, to: limit.addingTimeInterval(3 * day)) == .narrowed)
    }

    @Test func aLimitBeforeWherePassesStartBitesNothing() {
        let start = limit.addingTimeInterval(10 * day)
        #expect(ReadableHistory.effectiveLimit(limit, readingFrom: start) == nil)
        #expect(ReadableHistory.effectiveLimit(limit, readingFrom: limit) == nil)
        #expect(ReadableHistory.effectiveLimit(limit, readingFrom: limit.addingTimeInterval(-1)) == limit)
        #expect(ReadableHistory.effectiveLimit(nil, readingFrom: start) == nil)
    }

    // MARK: - Re-sweep

    private func state(
        anchor: Data? = nil, recent: Data? = nil, complete: Bool = false, samples: Int = 0,
        readableSince: Date?
    ) -> TypeSyncState {
        var s = TypeSyncState(identifier: "HKQuantityTypeIdentifierStepCount")
        s.anchorData = anchor
        s.recentAnchorData = recent
        s.backfillComplete = complete
        s.totalSamplesExported = samples
        s.readableSince = readableSince
        return s
    }

    @Test func aWidenedTypeWithProgressIsReSwept() {
        let synced = state(anchor: Data([1]), complete: true, samples: 6, readableSince: limit)
        #expect(ReadableHistory.needsResweep(synced, readableSince: nil))
        #expect(ReadableHistory.needsResweep(synced, readableSince: limit.addingTimeInterval(-30 * day)))
        // Mid-backfill counts: an anchor, or only the recent-window stream.
        #expect(ReadableHistory.needsResweep(state(anchor: Data([1]), readableSince: limit), readableSince: nil))
        #expect(ReadableHistory.needsResweep(state(recent: Data([1]), readableSince: limit), readableSince: nil))
    }

    @Test func aWidenedTypeThatNeverSyncedHasNothingToRedo() {
        #expect(!ReadableHistory.needsResweep(state(readableSince: limit), readableSince: nil))
    }

    @Test func theSameOrANarrowerDateNeverReSweeps() {
        let synced = state(anchor: Data([1]), complete: true, samples: 6, readableSince: limit)
        #expect(!ReadableHistory.needsResweep(synced, readableSince: limit))
        #expect(!ReadableHistory.needsResweep(synced, readableSince: limit.addingTimeInterval(day)))
        // Synced unlimited, now limited: what was sent stays sent.
        let unlimited = state(anchor: Data([1]), complete: true, samples: 6, readableSince: nil)
        #expect(!ReadableHistory.needsResweep(unlimited, readableSince: limit))
        #expect(!ReadableHistory.needsResweep(unlimited, readableSince: nil))
    }
}

@Suite struct ReadableHistoryClampTests {
    private func days(anchor: Date = local(2025, 10, 1), unit: AggregateIntervalUnit = .day, value: Int = 1) -> AggregateBucketing {
        AggregateBucketing(anchor: anchor, intervalValue: value, intervalUnit: unit, calendar: pacific)
    }

    /// The case measured on the simulator: "Past 30 Days" granted at
    /// 17:36:51 PDT on Sep 30 left 17:36:51 PDT on Aug 31 readable. The day
    /// bucket of Aug 31 holds only part of that day's data, so the first
    /// bucket uploaded is Sep 1.
    @Test func theBucketThatStraddlesTheDateIsNotUploaded() {
        let limit = local(2026, 8, 31, 17, 36, 51)
        let bucketing = days()
        #expect(ReadableHistory.firstWholeBucket(atOrAfter: limit, bucketing: bucketing) == local(2026, 9, 1))
        let window = ReadableHistory.clampAggregateWindow(
            (local(2025, 10, 1), local(2026, 9, 30)), readableSince: limit, bucketing: bucketing)
        #expect(window?.from == local(2026, 9, 1))
        #expect(window?.to == local(2026, 9, 30))
        let chunks = bucketing.chunks(from: window!.from, to: window!.to)
        #expect(chunks.first?.start == local(2026, 9, 1))
    }

    @Test func aBucketStartingExactlyOnTheDateIsUploaded() {
        let limit = local(2026, 9, 1)
        #expect(ReadableHistory.firstWholeBucket(atOrAfter: limit, bucketing: days()) == limit)
        let window = ReadableHistory.clampAggregateWindow(
            (local(2026, 8, 1), local(2026, 9, 10)), readableSince: limit, bucketing: days())
        #expect(window?.from == limit)
    }

    @Test func aMillisecondPastABoundaryLosesThatBucket() {
        let limit = local(2026, 9, 1).addingTimeInterval(0.001)
        #expect(ReadableHistory.firstWholeBucket(atOrAfter: limit, bucketing: days()) == local(2026, 9, 2))
    }

    @Test func hourBucketsClampToTheNextHour() {
        let bucketing = days(anchor: local(2026, 1, 1), unit: .hour)
        #expect(ReadableHistory.firstWholeBucket(atOrAfter: local(2026, 9, 1, 10, 30), bucketing: bucketing)
            == local(2026, 9, 1, 11))
    }

    @Test func weekAndMonthBucketsClampToTheirNextBoundary() {
        // Weeks counted from a Thursday anchor.
        let weeks = days(anchor: local(2026, 1, 1), unit: .week)
        #expect(ReadableHistory.firstWholeBucket(atOrAfter: local(2026, 9, 1, 12), bucketing: weeks)
            == local(2026, 9, 3))
        let months = days(anchor: local(2026, 1, 1), unit: .month)
        #expect(ReadableHistory.firstWholeBucket(atOrAfter: local(2026, 8, 31, 17, 36), bucketing: months)
            == local(2026, 9, 1))
    }

    /// 1 Nov 2026 is 25 hours long in Pacific time: the boundary after it is
    /// the next local midnight, not 24 hours on.
    @Test func dayBucketsFollowTheCalendarAcrossTheEndOfDaylightTime() {
        let bucketing = days()
        let limit = local(2026, 11, 1, 12)
        let first = ReadableHistory.firstWholeBucket(atOrAfter: limit, bucketing: bucketing)
        #expect(first == local(2026, 11, 2))
        #expect(first.timeIntervalSince(local(2026, 11, 1)) == 25 * 3_600)
    }

    /// 8 Mar 2026 is 23 hours long.
    @Test func dayBucketsFollowTheCalendarAcrossTheStartOfDaylightTime() {
        let bucketing = days()
        let first = ReadableHistory.firstWholeBucket(atOrAfter: local(2026, 3, 8, 1), bucketing: bucketing)
        #expect(first == local(2026, 3, 9))
        #expect(first.timeIntervalSince(local(2026, 3, 8)) == 23 * 3_600)
    }

    @Test func noLimitLeavesTheWindowAlone() {
        let window = ReadableHistory.clampAggregateWindow(
            (local(2025, 10, 1, 7, 15), local(2026, 9, 30)), readableSince: nil, bucketing: days())
        #expect(window?.from == local(2025, 10, 1, 7, 15))
        #expect(window?.to == local(2026, 9, 30))
    }

    @Test func aWindowAlreadyPastTheDateIsUnchanged() {
        // A trailing lookback that starts after the limit.
        let window = ReadableHistory.clampAggregateWindow(
            (local(2026, 9, 20, 9), local(2026, 9, 30)), readableSince: local(2026, 8, 31, 17), bucketing: days())
        #expect(window?.from == local(2026, 9, 20, 9))
    }

    @Test func aWindowWhollyBeforeTheDateComputesNothing() {
        let limit = local(2026, 8, 31, 17)
        #expect(ReadableHistory.clampAggregateWindow(
            (local(2025, 10, 1), local(2026, 8, 31)), readableSince: limit, bucketing: days()) == nil)
        // Ending on the straddling bucket's start: still nothing whole.
        #expect(ReadableHistory.clampAggregateWindow(
            (local(2025, 10, 1), local(2026, 9, 1)), readableSince: limit, bucketing: days()) == nil)
    }

    @Test func ringsStartAtTheFirstWholeReadableDay() {
        #expect(ReadableHistory.firstWholeDay(atOrAfter: local(2026, 8, 31, 17, 36), calendar: pacific)
            == local(2026, 9, 1))
        #expect(ReadableHistory.firstWholeDay(atOrAfter: local(2026, 9, 1), calendar: pacific)
            == local(2026, 9, 1))
        #expect(ReadableHistory.firstWholeDay(atOrAfter: local(2026, 11, 1, 0, 0, 1), calendar: pacific)
            == local(2026, 11, 2))
    }

    @Test func reconciliationNeverComparesMonthsTheDeviceCannotRead() {
        let start = local(2025, 10, 1)
        let limit = Date(timeIntervalSince1970: 1_788_223_011.807) // 2026-09-01T00:36:51Z
        #expect(ReadableHistory.reconcileStart(syncStart: start, readableSince: nil) == start)
        #expect(ReadableHistory.reconcileStart(syncStart: start, readableSince: limit) == limit)
        #expect(ReadableHistory.reconcileStart(syncStart: limit.addingTimeInterval(day), readableSince: limit)
            == limit.addingTimeInterval(day))

        let now = Date(timeIntervalSince1970: 1_790_814_000) // 2026-10-01
        let windows = ReconcileDigest.monthWindows(
            from: ReadableHistory.reconcileStart(syncStart: start, readableSince: limit), to: now)
        // September from the limit on, then the start of October — nothing
        // from the eleven months before, whose server rows would otherwise
        // all have looked like orphans.
        #expect(windows.first?.start == limit)
        #expect(windows.allSatisfy { $0.start >= limit })
        #expect(windows.count == 2)
    }

    @Test func theReconciliationSummarySaysWhereItStarted() {
        var report = ReconciliationReport(type: "HKQuantityTypeIdentifierStepCount")
        report.windowsChecked = 2
        #expect(report.summary == "2 windows in sync")
        report.readableSince = local(2026, 9, 1)
        #expect(report.summary.hasPrefix("2 windows in sync (from "))
        #expect(report.summary.contains("Health access is limited to recent history"))
    }
}

@Suite struct HealthAccessOutcomeTests {
    /// What iOS 27 threw on the simulator for Don't Allow on the history
    /// page: com.apple.healthkit code 4, "The user denied authorization."
    @Test func dontAllowOnTheHistoryPageIsAnAnswer() {
        #expect(HealthAccessRequestOutcome.classify(HKError(.errorAuthorizationDenied)) == .declined)
        let bridged = NSError(
            domain: HKErrorDomain, code: 4,
            userInfo: [NSLocalizedDescriptionKey: "The user denied authorization."])
        #expect(HealthAccessRequestOutcome.classify(bridged) == .declined)
    }

    @Test func everythingElseIsStillAFailure() {
        #expect(HealthAccessRequestOutcome.classify(HKError(.errorAuthorizationNotDetermined)) == nil)
        #expect(HealthAccessRequestOutcome.classify(HKError(.errorHealthDataUnavailable)) == nil)
        #expect(HealthAccessRequestOutcome.classify(HKError(.errorInvalidArgument)) == nil)
        #expect(HealthAccessRequestOutcome.classify(NSError(domain: NSCocoaErrorDomain, code: 4)) == nil)
        #expect(HealthAccessRequestOutcome.classify(URLError(.timedOut)) == nil)
        #expect(HealthAccessRequestOutcome.classify(SyncError.healthDataUnavailable) == nil)
    }
}

@Suite struct ReadableHistoryStateTests {
    private func tempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("puls-tests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// `sync-state.json` exactly as a 1.5 build wrote it (an end-to-end run
    /// on 2026-09-28 against a local server, trimmed to two of its fourteen
    /// types). The file is loaded with a quarantine on any decode error,
    /// which would reset every anchor — so a field 1.6 adds must decode from
    /// its absence.
    static let stateFrom15 = #"""
        {"workoutRoutesState":{"totalBatchesUploaded":0,"totalPayloadsUploaded":0,"totalBytesUploade
        d":0,"totalWorkoutsUploaded":0},"typeStates":{"HKQuantityTypeIdentifierHeartRate":{"backfill
        Complete":true,"lastBatchDuplicates":91,"latestExported":1790629200000,"totalSamplesExported
        ":105091,"lastSyncDuration":0.278058292,"totalBytesUploaded":4873958,"lastBatchAccepted":0,"
        totalBatchesUploaded":115,"totalDeletionsExported":0,"lastSyncAt":1790638297249.127,"earlies
        tExported":1759102200000,"identifier":"HKQuantityTypeIdentifierHeartRate","anchorData":"YnBs
        aXN0MDDUAQIDBAUGBwpYJHZlcnNpb25ZJGFyY2hpdmVyVCR0b3BYJG9iamVjdHMSAAGGoF8QD05TS2V5ZWRBcmNoaXZl
        ctEICVRyb290gAGkCwwTFFUkbnVsbNMNDg8QERJVcm93aWRWJGNsYXNzW2NsaWVudFRva2VuEgAGvSiAA4ACXxCAZGYx
        NjczMzI4MGIxMmEzNjQyZjA3OTM2NGM0NjVmMzhkNzIyYjQwNzI4MDY4MmM3NDA5MTMzNmMxYmJkMTZiMmM3MGY0MTU4
        MDVmYjBiOWQwZjBhYzU3Nzk2ZTI3NzBkNTI0YWVlYWNlNjhmZDhmNTZkMTQyZTQyMGJhMjkyNjTSFRYXGFokY2xhc3Nu
        YW1lWCRjbGFzc2VzXUhLUXVlcnlBbmNob3KiGRpdSEtRdWVyeUFuY2hvclhOU09iamVjdAAIABEAGgAkACkAMgA3AEkA
        TABRAFMAWABeAGUAawByAH4AgwCFAIcBCgEPARoBIwExATQBQgAAAAAAAAIBAAAAAAAAABsAAAAAAAAAAAAAAAAAAAFL
        "},"HKQuantityTypeIdentifierStepCount":{"backfillComplete":true,"lastBatchDuplicates":717,"l
        atestExported":1790625600000,"totalSamplesExported":8757,"lastSyncDuration":0.299556,"totalB
        ytesUploaded":426353,"lastBatchAccepted":40,"totalBatchesUploaded":10,"lastSyncAt":179063825
        7026.849,"totalDeletionsExported":0,"earliestExported":1759104000000,"identifier":"HKQuantit
        yTypeIdentifierStepCount","anchorData":"YnBsaXN0MDDUAQIDBAUGBwpYJHZlcnNpb25ZJGFyY2hpdmVyVCR0
        b3BYJG9iamVjdHMSAAGGoF8QD05TS2V5ZWRBcmNoaXZlctEICVRyb290gAGkCwwTFFUkbnVsbNMNDg8QERJVcm93aWRW
        JGNsYXNzW2NsaWVudFRva2VuEgAG4qiAA4ACXxCAZGYxNjczMzI4MGIxMmEzNjQyZjA3OTM2NGM0NjVmMzhkNzIyYjQw
        NzI4MDY4MmM3NDA5MTMzNmMxYmJkMTZiMmM3MGY0MTU4MDVmYjBiOWQwZjBhYzU3Nzk2ZTI3NzBkNTI0YWVlYWNlNjhm
        ZDhmNTZkMTQyZTQyMGJhMjkyNjTSFRYXGFokY2xhc3NuYW1lWCRjbGFzc2VzXUhLUXVlcnlBbmNob3KiGRpdSEtRdWVy
        eUFuY2hvclhOU09iamVjdAAIABEAGgAkACkAMgA3AEkATABRAFMAWABeAGUAawByAH4AgwCFAIcBCgEPARoBIwExATQB
        QgAAAAAAAAIBAAAAAAAAABsAAAAAAAAAAAAAAAAAAAFL"}},"configuration":{"maxEnrichmentPointsPerBatc
        h":4000,"maxMergedBatchSamples":1000,"userName":null,"includeWorkoutEnhancedData":true,"obse
        rverCoalesceWindow":2,"startDate":1759102016552.0361,"enabledTypes":["HKQuantityTypeIdentifi
        erHeartRate","HKQuantityTypeIdentifierStepCount"],"userBiologicalSex":null,"maxConcurrentTyp
        es":4,"userID":"5ea4d000-0000-4000-8000-000000000001","batchSize":1000,"serverURL":"http://l
        ocalhost:8090","aggregates":[],"userDateOfBirth":null,"includeWorkoutRoutes":true,"userEmail
        ":null},"aggregateStates":{},"workoutStreamsState":{"totalBatchesUploaded":0,"totalPayloadsU
        ploaded":0,"totalBytesUploaded":0,"totalWorkoutsUploaded":0},"deviceID":"99E7D25C-A0EB-4C25-
        ADA4-A0D66764A462","activitySummaryState":{"totalBatchesUploaded":0,"totalBytesUploaded":0,"
        totalDaysUploaded":0},"serverIdentity":{"userID":"5ea4d000-0000-4000-8000-000000000001","pat
        h":"","host":"localhost","port":8090}}
        """#.replacingOccurrences(of: "\n", with: "")

    @Test func aStateFileFrom15LoadsWithItsAnchorsAndNoLimit() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(Self.stateFrom15.utf8).write(to: dir.appendingPathComponent("sync-state.json"))

        let store = SyncStateStore(directory: dir, tokenStore: InMemoryTokenStore())
        #expect(await store.deviceID == "99E7D25C-A0EB-4C25-ADA4-A0D66764A462")
        let heartRate = await store.state(for: "HKQuantityTypeIdentifierHeartRate")
        #expect(heartRate.anchorData != nil)
        #expect(heartRate.backfillComplete)
        #expect(heartRate.totalSamplesExported == 105_091)
        #expect(heartRate.readableSince == nil)
        #expect(await store.activitySummaryState.readableSince == nil)
        #expect(await store.workoutRoutesState.readableSince == nil)
        #expect(await store.workoutStreamsState.readableSince == nil)
        // Nothing was quarantined.
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(!files.contains { $0.contains("corrupt") })
    }

    @Test func everyLimitPersistsAsEpochMillisecondsAndComesBack() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let since = Date(timeIntervalSince1970: 1_788_223_011) // whole ms survive the round trip exactly
        let configID = UUID()
        let store = SyncStateStore(directory: dir, tokenStore: InMemoryTokenStore())
        await store.recordReadableSince("HKQuantityTypeIdentifierStepCount", since)
        await store.updateAggregate(configID) { $0.readableSince = since }
        await store.updateActivitySummary { $0.readableSince = since }
        await store.updateWorkoutEnrichment(.routes) { $0.readableSince = since }
        await store.persistNow()

        let json = try #require(JSONSerialization.jsonObject(
            with: Data(contentsOf: dir.appendingPathComponent("sync-state.json"))) as? [String: Any])
        let types = try #require(json["typeStates"] as? [String: [String: Any]])
        #expect(types["HKQuantityTypeIdentifierStepCount"]?["readableSince"] as? Double == 1_788_223_011_000)

        let reopened = SyncStateStore(directory: dir, tokenStore: InMemoryTokenStore())
        #expect(await reopened.state(for: "HKQuantityTypeIdentifierStepCount").readableSince == since)
        #expect(await reopened.aggregateState(for: configID).readableSince == since)
        #expect(await reopened.activitySummaryState.readableSince == since)
        #expect(await reopened.workoutRoutesState.readableSince == since)
        #expect(await reopened.workoutStreamsState.readableSince == nil)
    }

    @Test func aReSweepReopensTheWholeHistoryAndKeepsTheTraffic() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = "HKQuantityTypeIdentifierStepCount"
        let limit = Date(timeIntervalSince1970: 1_788_223_011.807)
        let store = SyncStateStore(directory: dir, tokenStore: InMemoryTokenStore())
        await store.recordUploadedBatch(
            identifier: id, newAnchorData: Data([7]), samples: 6, deletions: 1, bytes: 900,
            sampleDateRange: limit...limit.addingTimeInterval(29 * day), duration: 1, latency: nil)
        await store.recordRecentWindowUpload(
            identifier: id, newAnchorData: Data([8]), windowStart: limit, bytes: 100,
            sampleDateRange: nil, duration: 1)
        await store.markBackfillComplete(id)
        await store.recordReadableSince(id, limit)

        await store.restartBackfillForWidenedAccess(id, readableSince: nil)

        let s = await store.state(for: id)
        #expect(s.anchorData == nil)
        #expect(s.recentAnchorData == nil)
        #expect(s.recentWindowStart == nil)
        #expect(!s.backfillComplete)
        #expect(s.totalSamplesExported == 0) // the sweep counts them all again
        #expect(s.lastSyncAt == nil)
        #expect(s.readableSince == nil)
        #expect(s.totalBytesUploaded == 1_000)
        #expect(s.totalBatchesUploaded == 2)
        #expect(s.totalDeletionsExported == 1)
        #expect(s.earliestExported == limit)
    }

    @Test func resetsKeepWhatIOSLetsTheAppRead() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let limit = Date(timeIntervalSince1970: 1_788_223_011.807)
        let store = SyncStateStore(directory: dir, tokenStore: InMemoryTokenStore())
        for id in ["a", "b"] {
            await store.recordUploadedBatch(
                identifier: id, newAnchorData: Data([1]), samples: 1, deletions: 0, bytes: 1,
                sampleDateRange: nil, duration: 0, latency: nil)
        }
        await store.recordReadableSince("a", limit)

        await store.resetType("a")
        #expect(await store.state(for: "a").anchorData == nil)
        #expect(await store.state(for: "a").readableSince == limit)

        await store.recordUploadedBatch(
            identifier: "a", newAnchorData: Data([2]), samples: 1, deletions: 0, bytes: 1,
            sampleDateRange: nil, duration: 0, latency: nil)
        await store.resetAll()
        #expect(await store.state(for: "a").anchorData == nil)
        #expect(await store.state(for: "a").readableSince == limit)
        #expect(await store.state(for: "b").anchorData == nil)
        #expect(await store.hasSyncProgress == false)
    }
}

@Suite struct ReadableHistoryExportTests {
    let start = Date(timeIntervalSince1970: 1_759_276_800) // 2025-10-01
    let limit = Date(timeIntervalSince1970: 1_788_223_011)

    @Test func onlyLimitsAfterTheExportStartMakeItPartial() {
        let readable = [
            "HKQuantityTypeIdentifierStepCount": limit,
            "HKQuantityTypeIdentifierHeartRate": start.addingTimeInterval(-day),
        ]
        #expect(ExportPlan.limitedHistory(readable, exportStart: start)
            == ["HKQuantityTypeIdentifierStepCount": limit])
        // "Past 30 days" exports from after the limit: complete.
        #expect(ExportPlan.limitedHistory(readable, exportStart: limit.addingTimeInterval(day)).isEmpty)
        #expect(ExportPlan.limitedHistory([:], exportStart: start).isEmpty)
    }

    @Test func aLimitedExportIsNotComplete() {
        var result = ExportResult(
            format: .csv, directory: URL(fileURLWithPath: "/tmp/x"), files: [],
            rowCounts: [.samples: 6], notRepresented: [:],
            unmappableSamples: [:], failures: [], warnings: [], totalBytes: 1, duration: 1)
        #expect(result.isComplete)
        result.limitedHistory = ["HKQuantityTypeIdentifierStepCount": limit]
        #expect(!result.isComplete)
    }

    @Test func theManifestSaysWhichTypesStartLateAndWhen() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("puls-tests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let manifest = ExportManifest(
            format: .jsonl, schemaVersion: PulsProtocol.version, clientVersion: "1.6 (17)",
            createdAt: limit, startDate: nil, endDate: nil, userID: PulsDefaultUser.id,
            deviceID: "d", timeZone: "America/Los_Angeles", complete: false,
            types: ["HKQuantityTypeIdentifierStepCount"], aggregates: [], files: [], rows: [:],
            batches: 1, notRepresented: [:], unmappableSamples: [:],
            limitedHistory: ["HKQuantityTypeIdentifierStepCount": limit], failures: [])
        let url = dir.appendingPathComponent("m.json")
        _ = try manifest.write(to: url)
        let data = try Data(contentsOf: url)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((object["limitedHistory"] as? [String: Double])?["HKQuantityTypeIdentifierStepCount"]
            == 1_788_223_011_000)
        #expect(object["complete"] as? Bool == false)
        #expect(try JSONDecoder.puls.decode(ExportManifest.self, from: data) == manifest)
    }
}

@Suite struct ReadableHistoryProfileTests {
    private let now = Date(timeIntervalSince1970: 1_790_812_800) // 2026-10-01
    private let limit = Date(timeIntervalSince1970: 1_788_223_011.807)

    private var options: HealthExplorer.ProfileOptions {
        var options = HealthExplorer.ProfileOptions()
        options.lookbackDays = 365
        options.calendar = pacific
        return options
    }

    private func profile(readableSince: Date?) -> TypeProfile {
        var profile = TypeProfile(
            typeIdentifier: "HKQuantityTypeIdentifierStepCount", kind: .quantity, unitString: "count",
            computedAt: now, timeZoneID: "America/Los_Angeles",
            rangeStart: options.effectiveRangeStart(now: now), lookbackDays: 365,
            sampleCount: 6, earliestStart: limit, latestStart: now.addingTimeInterval(-day))
        profile.readableSince = readableSince
        return profile
    }

    private func facts(readableSince: Date?) -> TypeQuickFacts {
        TypeQuickFacts(
            typeIdentifier: "HKQuantityTypeIdentifierStepCount", earliestStart: limit,
            latestStart: now.addingTimeInterval(-day), sourceNames: ["Seeder"], readableSince: readableSince)
    }

    @Test func aProfileScannedUnderTheSameLimitIsFresh() {
        #expect(!TypeProfileStore.isStale(
            profile(readableSince: limit), facts: facts(readableSince: limit), options: options, now: now))
        #expect(!TypeProfileStore.isStale(
            profile(readableSince: nil), facts: facts(readableSince: nil), options: options, now: now))
    }

    @Test func aWidenedGrantMakesTheProfileStale() {
        #expect(TypeProfileStore.isStale(
            profile(readableSince: limit), facts: facts(readableSince: nil), options: options, now: now))
    }

    @Test func aNewLimitMakesAnUnlimitedProfileStale() {
        #expect(TypeProfileStore.isStale(
            profile(readableSince: nil), facts: facts(readableSince: limit), options: options, now: now))
    }

    @Test func aLimitOlderThanTheLookbackDoesNotMatter() {
        let old = now.addingTimeInterval(-400 * day)
        #expect(!TypeProfileStore.isStale(
            profile(readableSince: nil), facts: facts(readableSince: old), options: options, now: now))
    }
}

@Suite struct LimitedHistorySummaryTests {
    let limit = local(2026, 8, 31, 17, 36, 51)

    @Test func nothingLimitedSaysNothing() {
        #expect(LimitedHistorySummary([:]) == nil)
    }

    @Test func namesStayASentence() {
        let one = LimitedHistorySummary(["HKQuantityTypeIdentifierStepCount": limit])
        #expect(one?.typesText == "Steps")
        let two = LimitedHistorySummary([
            "HKQuantityTypeIdentifierStepCount": limit, "HKQuantityTypeIdentifierHeartRate": limit,
        ])
        #expect(two?.typesText == "Heart Rate and Steps")
        // Three are named in full: "and 1 more types" is not a sentence.
        let three = LimitedHistorySummary([
            "HKQuantityTypeIdentifierBodyMass": limit, "HKQuantityTypeIdentifierHeartRate": limit,
            HealthTypeCatalog.workoutIdentifier: limit,
        ])
        #expect(three?.typesText == "Body Weight, Heart Rate and Workouts")
        let many = LimitedHistorySummary([
            "HKQuantityTypeIdentifierStepCount": limit, "HKQuantityTypeIdentifierHeartRate": limit,
            "HKQuantityTypeIdentifierBodyMass": limit, HealthTypeCatalog.workoutIdentifier: limit,
        ])
        #expect(many?.typesText == "Body Weight, Heart Rate and 2 more types")
    }

    @Test func oneGrantIsOneDate() {
        let same = LimitedHistorySummary([
            "HKQuantityTypeIdentifierStepCount": limit,
            "HKQuantityTypeIdentifierHeartRate": limit.addingTimeInterval(60),
        ])
        #expect(same?.isOneDay(in: pacific) == true)
        #expect(same?.earliest == limit)
        // Steps limited later from Settings: two dates.
        let two = LimitedHistorySummary([
            "HKQuantityTypeIdentifierStepCount": limit.addingTimeInterval(5 * day),
            "HKQuantityTypeIdentifierHeartRate": limit,
        ])
        #expect(two?.isOneDay(in: pacific) == false)
        #expect(two?.latest == limit.addingTimeInterval(5 * day))
    }
}

@Suite struct ReadableHistoryTimeoutTests {
    @Test func anAnswerInTimeComesBack() async throws {
        let value = try await ReadableHistory.withTimeout(.seconds(5)) { 42 }
        #expect(value == 42)
    }

    @Test func anErrorInTimeIsRethrown() async {
        await #expect(throws: URLError.self) {
            try await ReadableHistory.withTimeout(.seconds(5)) { () async throws -> Int in throw URLError(.timedOut) }
        }
    }

    /// The case that matters: a HealthKit call that does not honour
    /// cancellation, and returns late or never. The caller is let go at the
    /// limit all the same.
    ///
    /// What these tests tell apart — let go at the limit, or kept until the
    /// call returns — is an order, not a duration: the caller is back while
    /// the stuck call has still not returned. A wall-clock bound said the
    /// same thing until the Xcode 27 runner stretched a 200 ms ceiling to
    /// 73–128 s under load and failed four runs that way; the order holds
    /// however slow the runner is.
    @Test func aCallThatIgnoresCancellationIsCutOffAtTheLimit() async {
        let stuck = StuckCall()
        await #expect(throws: ReadableHistory.TimedOut.self) {
            try await ReadableHistory.withTimeout(.milliseconds(200)) { await stuck.run() }
        }
        #expect(stuck.hasReturned == false)
    }

    @Test func cancellingTheCallerEndsTheWait() async {
        let stuck = StuckCall()
        let task = Task {
            try await ReadableHistory.withTimeout(.seconds(30)) { await stuck.run() }
        }
        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()
        let result = await task.result
        #expect(stuck.hasReturned == false)
        #expect(throws: CancellationError.self) { try result.get() }
    }

    /// A call that ignores cancellation and returns two minutes later, and
    /// records when it has.
    private final class StuckCall: @unchecked Sendable {
        private let lock = NSLock()
        private var returned = false

        var hasReturned: Bool { lock.withLock { returned } }

        func run() async -> Int {
            let value = await withCheckedContinuation { (continuation: CheckedContinuation<Int, Never>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + 120) { continuation.resume(returning: 1) }
            }
            lock.withLock { returned = true }
            return value
        }
    }
}

@Suite struct ReadableHistoryUnknownExportTests {
    /// HealthKit could not say (failed or timed out): the export cannot
    /// claim to cover the range asked for, so it is not complete.
    @Test func anUnknownLimitMakesTheExportIncomplete() {
        let issue = ExportPlan.readableHistoryIssue(nil)
        #expect(issue != nil)
        #expect(issue?.type == nil)
        var result = ExportResult(
            format: .csv, directory: URL(fileURLWithPath: "/tmp/x"), files: [],
            rowCounts: [.samples: 6], notRepresented: [:],
            unmappableSamples: [:], failures: [], warnings: [], totalBytes: 1, duration: 1)
        result.failures = [issue!]
        #expect(!result.isComplete)
    }

    @Test func aKnownAnswerIsNoIssue() {
        #expect(ExportPlan.readableHistoryIssue([:]) == nil)
        #expect(ExportPlan.readableHistoryIssue(["HKQuantityTypeIdentifierStepCount": Date()]) == nil)
    }
}
