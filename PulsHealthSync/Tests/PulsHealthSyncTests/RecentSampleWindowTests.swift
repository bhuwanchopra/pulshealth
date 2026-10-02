import Foundation
import HealthKit
import Testing
@testable import PulsHealthSync

/// A type still backfilling sends its last month first, through an anchor of
/// its own. What must never happen is that stream touching the type's real
/// progress: its acks move neither `anchorData` nor `backfillComplete`, and it
/// disappears the moment the backfill is done.
@Suite struct RecentSampleWindowTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    let day: TimeInterval = 86_400

    @Test func aLongSyncRangeGetsAMonthUpFront() {
        let start = RecentSampleWindow.start(
            syncingFrom: now.addingTimeInterval(-365 * day), now: now)
        #expect(start == now.addingTimeInterval(-RecentSampleWindow.span))
        #expect(RecentSampleWindow.span == 30 * day)
    }

    @Test func aShortSyncRangeIsJustSwept() {
        // Under two windows the stream would send most of it twice.
        #expect(RecentSampleWindow.start(syncingFrom: now.addingTimeInterval(-45 * day), now: now) == nil)
        #expect(RecentSampleWindow.start(syncingFrom: now.addingTimeInterval(-60 * day), now: now) == nil)
        #expect(RecentSampleWindow.start(syncingFrom: now.addingTimeInterval(-61 * day), now: now) != nil)
    }

    func makeStore() -> SyncStateStore {
        SyncStateStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("puls-tests-\(UUID())", isDirectory: true))
    }

    @Test func aRecentUploadMovesOnlyItsOwnAnchor() async {
        let store = makeStore()
        let id = "HKQuantityTypeIdentifierHeartRate"
        await store.update(id) { $0.anchorData = Data([7]) }
        let windowStart = now.addingTimeInterval(-30 * day)

        await store.recordRecentWindowUpload(
            identifier: id, newAnchorData: Data([9]), windowStart: windowStart,
            bytes: 500, sampleDateRange: now.addingTimeInterval(-day)...now, duration: 1)

        let s = await store.state(for: id)
        #expect(s.recentAnchorData == Data([9]))
        #expect(s.recentWindowStart == windowStart)
        #expect(s.anchorData == Data([7]))
        #expect(!s.backfillComplete)
        // The sweep will send these again and count them then.
        #expect(s.totalSamplesExported == 0)
        #expect(s.totalBytesUploaded == 500)
        #expect(s.totalBatchesUploaded == 1)
        #expect(s.latestExported == now)
    }

    @Test func completingTheBackfillDropsTheStream() async {
        let store = makeStore()
        let id = "HKQuantityTypeIdentifierStepCount"
        await store.recordRecentWindowUpload(
            identifier: id, newAnchorData: Data([1]), windowStart: now,
            bytes: 1, sampleDateRange: nil, duration: 0)

        await store.markBackfillComplete(id)

        let s = await store.state(for: id)
        #expect(s.backfillComplete)
        #expect(s.recentAnchorData == nil)
        #expect(s.recentWindowStart == nil)
    }

    @Test func resettingATypeDropsTheStream() async {
        let store = makeStore()
        let id = "HKQuantityTypeIdentifierStepCount"
        await store.recordRecentWindowUpload(
            identifier: id, newAnchorData: Data([1]), windowStart: now,
            bytes: 1, sampleDateRange: nil, duration: 0)

        await store.resetType(id)

        let s = await store.state(for: id)
        #expect(s.recentAnchorData == nil)
        #expect(s.recentWindowStart == nil)
    }

    @Test func stateWrittenBeforeTheStreamExistedStillDecodes() throws {
        let json = #"{"identifier":"HKQuantityTypeIdentifierHeartRate","backfillComplete":false,"totalSamplesExported":3,"totalDeletionsExported":0,"totalBytesUploaded":10,"totalBatchesUploaded":1}"#
        let s = try JSONDecoder.puls.decode(TypeSyncState.self, from: Data(json.utf8))
        #expect(s.totalSamplesExported == 3)
        #expect(s.recentAnchorData == nil)
        #expect(s.recentWindowStart == nil)
    }

    @Test func aRecentPassPackRecordsToTheStreamNotTheSweep() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("puls-tests-\(UUID())", isDirectory: true)
        let engine = HealthSyncEngine(
            store: SyncStateStore(directory: dir), eventLog: SyncEventLog(directory: dir),
            wakeLog: WakeLog(directory: dir))
        let config = await engine.store.configuration
        let windowStart = now.addingTimeInterval(-30 * day)
        let page = MergedPage(
            identifier: "a",
            samples: [SyncSample(
                uuid: UUID(), type: "a", kind: .quantity, start: now, end: now,
                value: 1, unit: "count")],
            deletions: [],
            newAnchor: HKQueryAnchor(fromValue: 1),
            newAnchorData: Data([4]),
            enrichment: HealthSyncEngine.WorkoutEnrichment(),
            queryDuration: 0, drained: true, rawCount: 1, dropped: 0)

        let acked = await engine.uploadPacks(
            [[page]], reason: .backfill,
            transport: ConcurrentUploadTests.RecordingTransport(), config: config,
            pass: .recent, starts: ["a": windowStart])

        #expect(acked == [true])
        let s = await engine.store.state(for: "a")
        #expect(s.recentAnchorData == Data([4]))
        #expect(s.recentWindowStart == windowStart)
        #expect(s.anchorData == nil)
        #expect(s.totalSamplesExported == 0)
    }
}
