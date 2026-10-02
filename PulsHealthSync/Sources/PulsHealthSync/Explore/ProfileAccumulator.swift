import Foundation

/// One HealthKit sample, reduced to what a profile needs — before the
/// `HKObject` goes away. Deliberately not `SyncSample` and not made by
/// `SampleMapper`: the mapper reads metadata and builds temporal contexts for
/// the wire, none of which a profile keeps, and on a million-sample type that
/// work is most of the cost. The `uuid` exists only so the scanner can drop
/// the samples it re-reads at a page boundary; the accumulator never stores it.
struct ScannedSample: Sendable, Equatable {
    var uuid: UUID
    var start: Date
    var end: Date
    /// The quantity in the catalog unit, nil when it is not a quantity sample
    /// or its quantity is not compatible with that unit.
    var value: Double?
    /// True for any quantity sample, convertible or not — the difference
    /// between the two is `TypeProfile.unmappableCount`.
    var hasQuantity = false
    /// `HKCategorySample.value`.
    var category: Int?
    /// Workout activity, ECG classification, state-of-mind kind, dose status.
    var label: String?
    /// Workout duration (which excludes pauses, unlike `end − start`).
    var duration: TimeInterval?
    var energyKcal: Double?
    var distanceMeters: Double?
    var sourceName: String
    var sourceBundleID: String
    var deviceName: String?
    var deviceModel: String?

    init(
        uuid: UUID = UUID(), start: Date, end: Date, value: Double? = nil, hasQuantity: Bool = false,
        category: Int? = nil, label: String? = nil, duration: TimeInterval? = nil,
        energyKcal: Double? = nil, distanceMeters: Double? = nil,
        sourceName: String = "", sourceBundleID: String = "",
        deviceName: String? = nil, deviceModel: String? = nil
    ) {
        self.uuid = uuid
        self.start = start
        self.end = end
        self.value = value
        self.hasQuantity = hasQuantity
        self.category = category
        self.label = label
        self.duration = duration
        self.energyKcal = energyKcal
        self.distanceMeters = distanceMeters
        self.sourceName = sourceName
        self.sourceBundleID = sourceBundleID
        self.deviceName = deviceName
        self.deviceModel = deviceModel
    }
}

/// Reduces a stream of `ScannedSample`s, in ascending start order, to a
/// `TypeProfile`. Pure and Sendable: HealthKit is the scanner's business, so
/// every rule in here is testable with hand-made samples.
///
/// Memory is bounded whatever the count: two reservoirs (values and gaps),
/// one dictionary entry per local day, and one per distinct source, device
/// and label.
struct ProfileAccumulator: Sendable {
    let typeIdentifier: String
    let kind: SampleKind
    let unitString: String?
    let histogramBins: Int
    let calendar: Calendar

    private(set) var sampleCount = 0
    private(set) var unmappableCount = 0
    private var earliestStart: Date?
    private var latestStart: Date?
    private var latestEnd: Date?
    private var welford = Welford()
    private var valueReservoir: ReservoirQuantiles
    private var gaps: GapAccumulator
    private var days: DailyCountAccumulator
    private var labels = BreakdownAccumulator<LabelKey>()
    private var sources = BreakdownAccumulator<SourceKey>()
    private var devices = BreakdownAccumulator<DeviceKey>()
    private var workoutDuration: TimeInterval = 0
    private var workoutEnergy: Double?
    private var workoutDistance: Double?

    private struct LabelKey: Hashable, Sendable, Comparable {
        var label: String
        var rawValue: Int?
        static func < (lhs: LabelKey, rhs: LabelKey) -> Bool {
            if let l = lhs.rawValue, let r = rhs.rawValue, l != r { return l < r }
            return lhs.label < rhs.label
        }
    }

    private struct SourceKey: Hashable, Sendable, Comparable {
        var name: String
        var bundleID: String
        static func < (lhs: SourceKey, rhs: SourceKey) -> Bool {
            (lhs.name, lhs.bundleID) < (rhs.name, rhs.bundleID)
        }
    }

    private struct DeviceKey: Hashable, Sendable, Comparable {
        var name: String?
        var model: String?
        static func < (lhs: DeviceKey, rhs: DeviceKey) -> Bool {
            (lhs.name ?? "", lhs.model ?? "") < (rhs.name ?? "", rhs.model ?? "")
        }
    }

    /// `seed` makes the reservoirs deterministic; the explorer draws a random
    /// one per run, tests pass a constant.
    init(
        typeIdentifier: String,
        kind: SampleKind,
        unitString: String?,
        histogramBins: Int = 40,
        reservoirCapacity: Int = 8_192,
        calendar: Calendar = .current,
        seed: UInt64 = .random(in: .min ... .max)
    ) {
        self.typeIdentifier = typeIdentifier
        self.kind = kind
        self.unitString = kind == .quantity ? unitString : nil
        self.histogramBins = max(1, histogramBins)
        self.calendar = calendar
        valueReservoir = ReservoirQuantiles(capacity: reservoirCapacity, seed: seed)
        gaps = GapAccumulator(reservoirCapacity: reservoirCapacity, seed: seed &+ 1)
        days = DailyCountAccumulator(calendar: calendar)
    }

    mutating func add(_ sample: ScannedSample) {
        sampleCount += 1
        earliestStart = min(earliestStart ?? sample.start, sample.start)
        latestStart = max(latestStart ?? sample.start, sample.start)
        latestEnd = max(latestEnd ?? sample.end, sample.end)
        gaps.add(start: sample.start)
        days.add(sample.start)
        sources.add(SourceKey(name: sample.sourceName, bundleID: sample.sourceBundleID), start: sample.start)
        devices.add(DeviceKey(name: sample.deviceName, model: sample.deviceModel), start: sample.start)

        switch kind {
        case .quantity:
            if let value = sample.value {
                welford.add(value)
                valueReservoir.add(value)
            } else {
                unmappableCount += 1
            }
        case .category:
            let label = sample.label ?? sample.category.map(String.init) ?? "unknown"
            labels.add(
                LabelKey(label: label, rawValue: sample.category), start: sample.start,
                duration: max(0, sample.end.timeIntervalSince(sample.start)))
        case .workout:
            let duration = sample.duration ?? max(0, sample.end.timeIntervalSince(sample.start))
            labels.add(LabelKey(label: sample.label ?? "other", rawValue: nil), start: sample.start, duration: duration)
            workoutDuration += duration
            if let energy = sample.energyKcal { workoutEnergy = (workoutEnergy ?? 0) + energy }
            if let distance = sample.distanceMeters { workoutDistance = (workoutDistance ?? 0) + distance }
        case .ecg, .stateOfMind, .medicationDose:
            labels.add(LabelKey(label: sample.label ?? "unknown", rawValue: nil), start: sample.start)
        case .heartbeatSeries, .activitySummary:
            break
        }
    }

    mutating func add(contentsOf samples: some Sequence<ScannedSample>) {
        for sample in samples { add(sample) }
    }

    /// The profile so far. `isComplete` is the scanner's verdict — the
    /// accumulator cannot know whether the stream ended or was cut off.
    func finish(
        computedAt: Date = Date(),
        scanDuration: TimeInterval,
        rangeStart: Date?,
        rangeEnd: Date?,
        isComplete: Bool,
        failureReason: String?
    ) -> TypeProfile {
        var profile = TypeProfile(
            typeIdentifier: typeIdentifier,
            kind: kind,
            unitString: unitString,
            computedAt: computedAt,
            scanDuration: scanDuration,
            timeZoneID: calendar.timeZone.identifier,
            rangeStart: rangeStart,
            rangeEnd: rangeEnd,
            isComplete: isComplete,
            failureReason: failureReason,
            sampleCount: sampleCount,
            // A NaN or infinite quantity converted but cannot be described;
            // it is excluded from `values` like an unconvertible one.
            unmappableCount: unmappableCount + welford.nonFiniteCount,
            earliestStart: earliestStart,
            latestStart: latestStart,
            latestEnd: latestEnd
        )
        if let earliestStart, let latestEnd {
            profile.spanSeconds = max(0, latestEnd.timeIntervalSince(earliestStart))
        }
        profile.values = valueDistribution
        profile.labelCounts = labels.sortedEntries(by: <).map { key, entry in
            TypeProfile.LabelCount(
                label: key.label, rawValue: key.rawValue, count: entry.count,
                totalDurationSeconds: kind == .category || kind == .workout ? entry.totalDuration : nil)
        }
        if kind == .workout, sampleCount > 0 {
            profile.workouts = TypeProfile.WorkoutSummary(
                totalDurationSeconds: workoutDuration,
                totalEnergyKcal: workoutEnergy,
                totalDistanceMeters: workoutDistance)
        }
        profile.cadence = gaps.cadence
        profile.dailyCounts = days.dailyCounts
        profile.coverage = days.coverage
        profile.sources = sources.sortedEntries(by: <).compactMap { key, entry in
            guard let earliest = entry.earliestStart, let latest = entry.latestStart else { return nil }
            return TypeProfile.SourceBreakdown(
                name: key.name, bundleID: key.bundleID, count: entry.count,
                earliestStart: earliest, latestStart: latest)
        }
        profile.devices = devices.sortedEntries(by: <).compactMap { key, entry in
            guard let earliest = entry.earliestStart, let latest = entry.latestStart else { return nil }
            return TypeProfile.DeviceBreakdown(
                name: key.name, model: key.model, count: entry.count,
                earliestStart: earliest, latestStart: latest)
        }
        return profile
    }

    private var valueDistribution: TypeProfile.ValueDistribution? {
        guard kind == .quantity, welford.count > 0,
              let min = welford.min, let max = welford.max, let stddev = welford.stddev
        else { return nil }
        let quantiles = valueReservoir.quantiles([0.01, 0.05, 0.5, 0.95, 0.99])
        let scale = valueReservoir.isEstimated
            ? Double(welford.count) / Double(valueReservoir.values.count)
            : 1
        let p1 = quantiles[0] ?? min
        let p5 = quantiles[1] ?? min
        let p95 = quantiles[3] ?? max
        let p99 = quantiles[4] ?? max
        return TypeProfile.ValueDistribution(
            count: welford.count,
            min: min,
            max: max,
            mean: welford.mean,
            stddev: stddev,
            p5: p5,
            median: quantiles[2] ?? min,
            p95: p95,
            isEstimated: valueReservoir.isEstimated,
            histogram: TypeProfile.Histogram.robustBins(
                count: histogramBins, min: min, max: max,
                core: TypeProfile.Histogram.core(p1: p1, p5: p5, p95: p95, p99: p99),
                values: valueReservoir.values, scale: scale))
    }
}
