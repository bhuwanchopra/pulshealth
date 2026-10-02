import Foundation
import HealthKit

// MARK: - Paging cursor (pure)

/// Walks every sample of a type in ascending start order, one bounded page at
/// a time, without an anchor.
///
/// Why not `HKAnchoredObjectQuery`: an anchor is sync state. The engine's
/// anchors are persisted per type with no destination dimension, and the
/// export invariant exists precisely because a second reader advancing them
/// loses data. A date-sorted `HKSampleQueryDescriptor` with a limit has no
/// state to share — the only cursor is a start date this struct holds for the
/// length of one scan.
///
/// The awkward part of paging on a sort key that is not unique: a page ends
/// mid-instant when several samples share the last start (two sources writing
/// at once, or a burst of Watch samples), and the next page — `start >=
/// lastStart` — returns those again. So the UUIDs at the last instant are
/// carried and dropped from the next page. A page made entirely of one instant
/// cannot advance at all; it is retried with a wider limit, up to
/// `maxWidening ×` the page size, after which the cursor steps one
/// millisecond past the instant and the skip is recorded: a lower bound on
/// what the profile missed, and the only lossy path in the scan.
struct SampleCursor: Sendable {
    /// One page: the samples with `start >= predicateStart` (unbounded when
    /// nil) up to the range end the scanner was built with, ascending by
    /// start, at most `limit` of them.
    typealias Fetch = @Sendable (_ predicateStart: Date?, _ limit: Int) async throws -> [ScannedSample]

    /// An instant at which more than `pageSize × maxWidening` samples share
    /// one start; `seen` is how many of them the scan did read. HealthKit
    /// never says how many it holds beyond the limit, so the number skipped
    /// is unknown — only that it is positive.
    struct SkippedInstant: Sendable, Equatable {
        var instant: Date
        var seen: Int
    }

    /// Where a scan stopped, and what it could not read.
    struct Outcome: Sendable, Equatable {
        var pages = 0
        var samples = 0
        var skippedInstants: [SkippedInstant] = []

        /// A note for `TypeProfile.failureReason`, nil when nothing was skipped.
        var skipNote: String? {
            guard !skippedInstants.isEmpty else { return nil }
            let formatter = ISO8601DateFormatter()
            let instants = skippedInstants.prefix(3).map {
                "\(formatter.string(from: $0.instant)) (\($0.seen) read)"
            }
            let more = skippedInstants.count > 3 ? " and \(skippedInstants.count - 3) more" : ""
            return "Skipped samples at \(skippedInstants.count) instant(s) where more than "
                + "\(SampleCursor.pageSize * SampleCursor.maxWidening) samples share one start: "
                + instants.joined(separator: ", ") + more
        }
    }

    static let pageSize = 5_000
    /// A page of one instant is widened to at most this multiple of `pageSize`.
    static let maxWidening = 4

    var pageSize = SampleCursor.pageSize
    var maxWidening = SampleCursor.maxWidening

    /// Scan from `start` (nil = the beginning of time). `onPage` receives each
    /// page's *new* samples — boundary repeats already dropped — with the
    /// start of the last sample read, before the next page is fetched.
    /// Cancellation is checked before every fetch and propagates; nothing is
    /// retained here, so a cancelled scan leaves no trace.
    func scan(
        from start: Date?,
        fetch: Fetch,
        onPage: (_ samples: ArraySlice<ScannedSample>, _ scannedThrough: Date) async throws -> Void
    ) async throws -> Outcome {
        var outcome = Outcome()
        var cursorStart = start
        var seenAtCursor: Set<UUID> = []
        var limit = pageSize
        let widestLimit = pageSize * maxWidening

        while true {
            try Task.checkCancellation()
            let page = try await fetch(cursorStart, limit)
            outcome.pages += 1

            let fresh = page.filter { !seenAtCursor.contains($0.uuid) }
            outcome.samples += fresh.count
            if let last = page.last {
                try await onPage(fresh[...], last.start)
            }

            guard page.count >= limit, let first = page.first, let last = page.last else {
                return outcome // a short page is the last page
            }

            if first.start == last.start {
                // Every sample on the page starts at the same instant; the
                // predicate cannot move without losing whatever else is there.
                seenAtCursor.formUnion(page.map(\.uuid))
                if limit < widestLimit {
                    limit = min(limit * 2, widestLimit)
                    continue
                }
                outcome.skippedInstants.append(SkippedInstant(instant: last.start, seen: seenAtCursor.count))
                cursorStart = last.start.addingTimeInterval(0.001)
                seenAtCursor = []
                limit = pageSize
                continue
            }

            cursorStart = last.start
            seenAtCursor = Set(page.lazy.filter { $0.start == last.start }.map(\.uuid))
            limit = pageSize
        }
    }
}

// MARK: - HealthKit page fetch

/// Reads pages of one catalog type from an `HKHealthStore` for `SampleCursor`
/// and reduces each `HKSample` to a `ScannedSample` on the spot.
struct SampleScanner: Sendable {
    let healthStore: HKHealthStore
    let descriptor: HealthTypeDescriptor
    let rangeEnd: Date?

    /// The page fetch a cursor drives. `rangeEnd` bounds every page; the
    /// cursor supplies the moving start.
    func fetch(sampleType: HKSampleType) -> SampleCursor.Fetch {
        let descriptor = descriptor
        let healthStore = healthStore
        let rangeEnd = rangeEnd
        return { predicateStart, limit in
            let predicate = HKQuery.predicateForSamples(
                withStart: predicateStart, end: rangeEnd, options: .strictStartDate)
            let query = HKSampleQueryDescriptor(
                predicates: [.sample(type: sampleType, predicate: predicate)],
                sortDescriptors: [SortDescriptor(\.startDate, order: .forward)],
                limit: limit)
            let samples = try await query.result(for: healthStore)
            return samples.map { Self.reduce($0, descriptor: descriptor) }
        }
    }

    /// The per-kind reduction. Mirrors what `SampleMapper` reads — source,
    /// device, the quantity in the catalog unit, the label enums' `pulsName`
    /// — and nothing it would compute for the wire.
    static func reduce(_ sample: HKSample, descriptor: HealthTypeDescriptor) -> ScannedSample {
        var scanned = ScannedSample(
            uuid: sample.uuid,
            start: sample.startDate,
            end: sample.endDate,
            sourceName: sample.sourceRevision.source.name,
            sourceBundleID: sample.sourceRevision.source.bundleIdentifier,
            deviceName: sample.device?.name,
            deviceModel: sample.device?.model)

        switch descriptor.kind {
        case .quantity:
            if let quantity = (sample as? HKQuantitySample)?.quantity {
                scanned.hasQuantity = true
                if let unit = descriptor.unit, quantity.is(compatibleWith: unit) {
                    scanned.value = quantity.doubleValue(for: unit)
                }
            }
        case .category:
            scanned.category = (sample as? HKCategorySample)?.value
        case .workout:
            if let workout = sample as? HKWorkout {
                scanned.label = workout.workoutActivityType.pulsName
                scanned.duration = workout.duration
                scanned.energyKcal = workout.statistics(for: HKQuantityType(.activeEnergyBurned))?
                    .sumQuantity()?.doubleValue(for: .kilocalorie())
                scanned.distanceMeters = workout.statistics(for: HKQuantityType(.distanceWalkingRunning))?
                    .sumQuantity()?.doubleValue(for: .meter())
                    ?? workout.statistics(for: HKQuantityType(.distanceCycling))?
                    .sumQuantity()?.doubleValue(for: .meter())
            }
        case .ecg:
            scanned.label = (sample as? HKElectrocardiogram)?.classification.pulsName
        case .stateOfMind:
            if #available(iOS 18.0, *), let som = sample as? HKStateOfMind {
                scanned.label = som.kind.pulsName
            }
        case .medicationDose:
            if #available(iOS 26.0, *), let dose = sample as? HKMedicationDoseEvent {
                scanned.label = dose.logStatus.pulsName
            }
        case .heartbeatSeries, .activitySummary:
            break
        }
        return scanned
    }
}
