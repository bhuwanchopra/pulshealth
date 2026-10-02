import Foundation
import Testing
@testable import PulsHealthSync

/// The paging cursor against an in-memory HealthKit stand-in: a sorted array
/// answered with the same `start >= predicateStart, limit` semantics as
/// `HKSampleQueryDescriptor` — including the unstable order of samples that
/// share a start, which is the whole reason the cursor carries UUIDs.
@Suite struct SampleCursorTests {
    private let base = Date(timeIntervalSince1970: 1_767_225_600)

    /// `starts` in seconds from `base`; the fetch shuffles ties per call.
    private func store(_ starts: [Double]) -> (samples: [ScannedSample], fetch: SampleCursor.Fetch, calls: Counter) {
        let samples = starts.map {
            ScannedSample(start: base.addingTimeInterval($0), end: base.addingTimeInterval($0 + 1))
        }
        let calls = Counter()
        let fetch: SampleCursor.Fetch = { predicateStart, limit in
            calls.record(limit)
            var matching = samples.filter { predicateStart == nil || $0.start >= predicateStart! }
            // HealthKit sorts by start only; reverse ties on every other call
            // so the page boundary sees a different order than the last page.
            let flip = calls.count % 2 == 0
            matching.sort {
                $0.start == $1.start
                    ? (flip ? $0.uuid.uuidString > $1.uuid.uuidString : $0.uuid.uuidString < $1.uuid.uuidString)
                    : $0.start < $1.start
            }
            return Array(matching.prefix(limit))
        }
        return (samples, fetch, calls)
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var limits: [Int] = []
        func record(_ limit: Int) { lock.withLock { limits.append(limit) } }
        var count: Int { lock.withLock { limits.count } }
        var all: [Int] { lock.withLock { limits } }
    }

    private func scan(
        _ cursor: SampleCursor, from: Date? = nil, fetch: SampleCursor.Fetch
    ) async throws -> (outcome: SampleCursor.Outcome, delivered: [ScannedSample], through: [Date]) {
        var delivered: [ScannedSample] = []
        var through: [Date] = []
        let outcome = try await cursor.scan(from: from, fetch: fetch) { page, scannedThrough in
            delivered.append(contentsOf: page)
            through.append(scannedThrough)
        }
        return (outcome, delivered, through)
    }

    @Test func aBoundarySharedByManySamplesIsNeitherDuplicatedNorLost() async throws {
        // Pages of 4 over: 0, 1, 2, 2, 2, 2, 2, 3, 4 — the second page starts
        // inside the run of 2s, and a page is made entirely of 2s.
        let starts: [Double] = [0, 1, 2, 2, 2, 2, 2, 3, 4]
        let (samples, fetch, _) = store(starts)
        var cursor = SampleCursor()
        cursor.pageSize = 4
        cursor.maxWidening = 4

        let result = try await scan(cursor, fetch: fetch)
        #expect(result.delivered.count == samples.count)
        #expect(Set(result.delivered.map(\.uuid)) == Set(samples.map(\.uuid)))
        #expect(result.outcome.samples == samples.count)
        #expect(result.outcome.skippedInstants.isEmpty)
        #expect(result.through.last == base.addingTimeInterval(4))
        // Delivered in non-decreasing start order.
        #expect(result.delivered.map(\.start) == result.delivered.map(\.start).sorted())
    }

    @Test func shortPageEndsTheScanAndEmptyStoreIsOnePage() async throws {
        let (_, fetch, calls) = store([0, 1, 2])
        var cursor = SampleCursor()
        cursor.pageSize = 10
        let result = try await scan(cursor, fetch: fetch)
        #expect(result.outcome.pages == 1)
        #expect(result.outcome.samples == 3)
        #expect(calls.count == 1)

        let (_, empty, _) = store([])
        let none = try await scan(cursor, fetch: empty)
        #expect(none.outcome == SampleCursor.Outcome(pages: 1, samples: 0))
        #expect(none.through.isEmpty)
    }

    @Test func aPageOfOneInstantWidensUntilItFits() async throws {
        // Seven samples at t=1 with pages of 2: 2 → 4 → 8 fits them all.
        let starts: [Double] = [0, 1, 1, 1, 1, 1, 1, 1, 2]
        let (samples, fetch, calls) = store(starts)
        var cursor = SampleCursor()
        cursor.pageSize = 2
        cursor.maxWidening = 4

        let result = try await scan(cursor, fetch: fetch)
        #expect(Set(result.delivered.map(\.uuid)) == Set(samples.map(\.uuid)))
        #expect(result.delivered.count == samples.count)
        #expect(result.outcome.skippedInstants.isEmpty)
        #expect(calls.all.contains(4))
        #expect(calls.all.contains(8))
        // The widened page is delivered without the samples the narrow page
        // already handed over.
        #expect(result.delivered.filter { $0.start == base.addingTimeInterval(1) }.count == 7)
    }

    @Test func beyondTheWideningCapTheCursorStepsPastTheInstantAndRecordsIt() async throws {
        // Twenty samples at t=1; pages of 2 widen to at most 8, so the scan
        // must give up on that instant and carry on from t=1.001.
        let starts: [Double] = [0] + Array(repeating: 1, count: 20) + [2, 3]
        let (_, fetch, _) = store(starts)
        var cursor = SampleCursor()
        cursor.pageSize = 2
        cursor.maxWidening = 4

        let result = try await scan(cursor, fetch: fetch)
        #expect(result.outcome.skippedInstants.count == 1)
        #expect(result.outcome.skippedInstants.first?.instant == base.addingTimeInterval(1))
        // The widest page read 8 of them; the narrower retries may have seen
        // others (tie order is unstable), so "seen" is at least 8 and every
        // one of them was delivered exactly once.
        let seen = try #require(result.outcome.skippedInstants.first?.seen)
        #expect(seen >= 8 && seen < 20)
        let atInstant = result.delivered.filter { $0.start == base.addingTimeInterval(1) }
        let elsewhere = result.delivered.filter { $0.start != base.addingTimeInterval(1) }
        #expect(atInstant.count == seen)
        #expect(Set(atInstant.map(\.uuid)).count == seen)
        // Everything before and after the instant still arrives, exactly once.
        #expect(elsewhere.map(\.start) == [0, 2, 3].map { base.addingTimeInterval($0) })
        let note = try #require(result.outcome.skipNote)
        #expect(note.contains("1 instant(s)"))
        #expect(note.contains("(\(seen) read)"))
    }

    @Test func rangeStartIsPassedToTheFirstFetch() async throws {
        let (_, fetch, _) = store([0, 5, 10])
        var cursor = SampleCursor()
        cursor.pageSize = 10
        let result = try await scan(cursor, from: base.addingTimeInterval(5), fetch: fetch)
        #expect(result.delivered.map(\.start) == [5, 10].map { base.addingTimeInterval($0) })
    }

    @Test func cancellationThrowsBeforeTheNextPage() async throws {
        let (_, fetch, calls) = store(Array(stride(from: 0.0, to: 100, by: 1)))
        let cursor: SampleCursor = {
            var cursor = SampleCursor()
            cursor.pageSize = 10
            return cursor
        }()
        let task = Task {
            try await cursor.scan(from: nil, fetch: fetch) { _, _ in
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        #expect(calls.count == 1)
    }

    @Test func fetchErrorsPropagate() async throws {
        struct Boom: Error {}
        let cursor = SampleCursor()
        await #expect(throws: Boom.self) {
            _ = try await cursor.scan(from: nil, fetch: { _, _ in throw Boom() }) { _, _ in }
        }
    }
}
