import Foundation

// Pure, Sendable accumulators behind `TypeProfile`. None of them touch
// HealthKit, and every one is bounded in memory: a profile of a type with
// millions of samples (heart rate on a multi-year Watch owner) must run on a
// phone in the background, so nothing here keeps the samples themselves — the
// largest thing any of them holds is a fixed-capacity reservoir of doubles.

// MARK: - Seeded random numbers

/// SplitMix64: a tiny, fast, deterministic generator. The reservoir below
/// takes one so that a test can seed it and assert exact output, and so that a
/// profile computed twice over the same samples with the same seed is
/// byte-identical — which is what makes the store's equality checks meaningful.
struct SeededGenerator: RandomNumberGenerator, Sendable, Equatable {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - Welford

/// Running count / mean / variance / min / max in one pass, numerically stable
/// for any count (the naive sum-of-squares form loses precision by the time a
/// heart-rate series reaches a million samples). Non-finite values are counted
/// and otherwise ignored: a single NaN would poison every statistic.
struct Welford: Sendable, Equatable {
    private(set) var count = 0
    private(set) var nonFiniteCount = 0
    private(set) var mean = 0.0
    private(set) var min: Double?
    private(set) var max: Double?
    private var m2 = 0.0

    mutating func add(_ value: Double) {
        guard value.isFinite else {
            nonFiniteCount += 1
            return
        }
        count += 1
        let delta = value - mean
        mean += delta / Double(count)
        m2 += delta * (value - mean)
        min = Swift.min(min ?? value, value)
        max = Swift.max(max ?? value, value)
    }

    /// Sample standard deviation (n − 1). Zero for a single value, nil for none.
    var stddev: Double? {
        guard count > 0 else { return nil }
        guard count > 1 else { return 0 }
        return (m2 / Double(count - 1)).squareRoot()
    }
}

// MARK: - Reservoir quantiles

/// A uniform random sample of a stream (Li's Algorithm L), from which
/// quantiles are read at the end. Exact while the stream fits in the
/// reservoir; above that, each retained value is an unbiased sample of the
/// whole stream and the quantiles are estimates, which `isEstimated` says.
///
/// Algorithm L rather than the textbook per-item coin flip because it skips
/// ahead geometrically: once the reservoir is full it draws a random number
/// only when an item is actually going to be kept, so a stream of a million
/// values costs about `capacity × log(n / capacity)` draws, not a million.
struct ReservoirQuantiles: Sendable, Equatable {
    let capacity: Int
    private(set) var count = 0
    private(set) var values: [Double] = []
    private var generator: SeededGenerator
    private var weight = 0.0
    private var nextIndex = 0

    /// `seed` fixes the sequence of replacements; a caller that wants a
    /// non-reproducible profile draws one from the system generator.
    init(capacity: Int, seed: UInt64 = .random(in: .min ... .max)) {
        self.capacity = Swift.max(1, capacity)
        self.generator = SeededGenerator(seed: seed)
        values.reserveCapacity(self.capacity)
    }

    /// Reads the seed from any generator, for callers that already hold one.
    init(capacity: Int, generator: inout some RandomNumberGenerator) {
        self.init(capacity: capacity, seed: generator.next())
    }

    var isEstimated: Bool { count > capacity }

    private mutating func uniform() -> Double {
        // Open interval (0, 1): log(0) is -inf and would stall the skip.
        Swift.max(Double.random(in: 0..<1, using: &generator), .leastNonzeroMagnitude)
    }

    private mutating func scheduleNextReplacement() {
        weight *= exp(log(uniform()) / Double(capacity))
        nextIndex += Int(log(uniform()) / log(1 - weight)) + 1
    }

    mutating func add(_ value: Double) {
        guard value.isFinite else { return }
        defer { count += 1 }
        if values.count < capacity {
            values.append(value)
            if values.count == capacity {
                weight = exp(log(uniform()) / Double(capacity))
                nextIndex = capacity
                scheduleNextReplacement()
            }
            return
        }
        guard count == nextIndex else { return }
        values[Int.random(in: 0..<capacity, using: &generator)] = value
        scheduleNextReplacement()
    }

    /// Values in ascending order — sorted at read time, once, rather than kept
    /// sorted through millions of inserts.
    var sorted: [Double] { values.sorted() }

    /// The `p`-quantile (0...1) by linear interpolation over the sorted
    /// reservoir; nil while empty.
    func quantile(_ p: Double) -> Double? {
        quantiles([p]).first ?? nil
    }

    /// Several quantiles from one sort.
    func quantiles(_ ps: [Double]) -> [Double?] {
        let sorted = self.sorted
        guard !sorted.isEmpty else { return ps.map { _ in nil } }
        return ps.map { p in
            let position = Swift.min(Swift.max(p, 0), 1) * Double(sorted.count - 1)
            let lower = Int(position.rounded(.down))
            let upper = Swift.min(lower + 1, sorted.count - 1)
            let fraction = position - Double(lower)
            return sorted[lower] + (sorted[upper] - sorted[lower]) * fraction
        }
    }
}

// MARK: - Histogram

extension TypeProfile.Histogram {
    /// Fixed-width bins over `[lower, upper]` from a set of values. When the
    /// values are a reservoir sample of a larger stream, `scale` (stream count
    /// ÷ reservoir count) brings the bar heights back to the stream's scale so
    /// the histogram reads as counts of samples, not of reservoir slots.
    ///
    /// The exact minimum and maximum come from `Welford`, so the edges are
    /// true edges even when the reservoir happens not to hold the extremes;
    /// the maximum itself lands in the last bin rather than one past it. A
    /// degenerate range (every value equal) is one bin holding everything.
    static func fixedBins(
        count: Int, lower: Double, upper: Double, values: [Double], scale: Double = 1
    ) -> TypeProfile.Histogram {
        let isEstimated = scale != 1
        func scaled(_ n: Int) -> Int { isEstimated ? Int((Double(n) * scale).rounded()) : n }

        guard upper > lower, count > 0 else {
            return TypeProfile.Histogram(
                lowerBound: lower, upperBound: upper, binCount: 1,
                counts: [scaled(values.count)], isEstimated: isEstimated)
        }
        let width = (upper - lower) / Double(count)
        var counts = [Int](repeating: 0, count: count)
        for value in values where value.isFinite {
            let index = Int(((value - lower) / width).rounded(.down))
            counts[Swift.min(Swift.max(index, 0), count - 1)] += 1
        }
        return TypeProfile.Histogram(
            lowerBound: lower, upperBound: upper, binCount: count,
            counts: counts.map(scaled), isEstimated: isEstimated)
    }

    /// A tail is left off the axis only when drawing it would take more than
    /// this share of the core's width: a heart rate that tops out a little
    /// past its 99th percentile keeps its true maximum on the axis, while
    /// one 5,000-step sample over a median of 25 does not.
    static let tailAllowance = 0.25

    /// How far past the 5th or 95th percentile the 1st or 99th may reach, as
    /// a multiple of the middle 90%, before that side of the core stops at
    /// the 5th or 95th instead.
    static let tailReach = 2.0

    /// The core `robustBins` draws: the 1st to 99th percentile, narrowed on
    /// either side to the 5th or 95th when the percentiles between them
    /// cover more than `tailReach` times the middle 90%. The narrowing is for
    /// types that mix two kinds of sample on one scale. Cycling distance from
    /// the Watch is a few metres per second-long sample, while a ride
    /// imported as a single sample is tens of kilometres. That put the 99th
    /// percentile at 720 m over a 95th of 8.5 m, and every bar in the first
    /// bin. A middle 90% of one value is left alone: narrowing it would bin
    /// nothing.
    static func core(p1: Double, p5: Double, p95: Double, p99: Double) -> ClosedRange<Double> {
        let middle = p95 - p5
        guard middle > 0 else { return p1...Swift.max(p99, p1) }
        let low = p5 - p1 > middle * tailReach ? p5 : p1
        let high = p99 - p95 > middle * tailReach ? p95 : p99
        return low...Swift.max(high, low)
    }

    /// Bins for reading, not for bookkeeping: over `core` (the 1st to 99th
    /// percentile, or narrower — see `core(p1:p5:p95:p99:)`) rather than
    /// min…max, on a round width (1, 2, 2.5 or 5 ×
    /// 10ⁿ, whole numbers for whole-number data) that lands near `count`
    /// bins, with the values outside counted in the tails. A tail within
    /// `tailAllowance` of the core is drawn to its true edge instead.
    ///
    /// `min` and `max` are the stream's exact extremes; `values` is the
    /// reservoir and `scale` brings it back to the stream, as in `fixedBins`.
    static func robustBins(
        count: Int, min: Double, max: Double, core: ClosedRange<Double>,
        values: [Double], scale: Double = 1
    ) -> TypeProfile.Histogram {
        let width = core.upperBound - core.lowerBound
        guard width > 0, count > 0 else {
            // Most of the data is one value: bin the whole range as before.
            return fixedBins(count: count, lower: min, upper: max, values: values, scale: scale)
        }
        let allowance = width * tailAllowance
        let low = core.lowerBound - min <= allowance ? min : core.lowerBound
        let high = max - core.upperBound <= allowance ? max : core.upperBound

        let integral = values.allSatisfy { $0 == $0.rounded() }
        let step = roundWidth((high - low) / Double(count), integral: integral)
        let lower = (low / step).rounded(.down) * step
        // The bin that holds `high` is drawn whole, so a whole-number maximum
        // gets a bin of its own rather than sharing the one below it.
        let upper = ((high / step).rounded(.down) + 1) * step
        let bins = Swift.max(1, Int(((upper - lower) / step).rounded()))

        let isEstimated = scale != 1
        func scaled(_ n: Int) -> Int { isEstimated ? Int((Double(n) * scale).rounded()) : n }
        var counts = [Int](repeating: 0, count: bins)
        var below = 0
        var above = 0
        for value in values where value.isFinite {
            if value < lower {
                below += 1
            } else if value >= upper {
                above += 1
            } else {
                counts[Swift.min(Int(((value - lower) / step).rounded(.down)), bins - 1)] += 1
            }
        }
        return TypeProfile.Histogram(
            lowerBound: lower, upperBound: upper, binCount: bins,
            counts: counts.map(scaled), isEstimated: isEstimated,
            belowCount: scaled(below), aboveCount: scaled(above))
    }

    /// The smallest of 1, 2, 2.5, 5 × 10ⁿ at or above `raw`; for whole-number
    /// data at least 1 and never 2.5, so no bin straddles half a step.
    static func roundWidth(_ raw: Double, integral: Bool) -> Double {
        guard raw > 0, raw.isFinite else { return 1 }
        let magnitude = pow(10, log10(raw).rounded(.down))
        let steps: [Double] = integral && magnitude <= 1 ? [1, 2, 5, 10] : [1, 2, 2.5, 5, 10]
        let fraction = raw / magnitude
        let width = (steps.first { fraction <= $0 * (1 + 1e-9) } ?? 10) * magnitude
        return integral ? Swift.max(1, width) : width
    }
}

// MARK: - Gaps between consecutive samples

/// Cadence of a type: the gaps between consecutive sample starts, fed in
/// ascending order. Exact min/max/count, quantiles via a reservoir. A start
/// earlier than the previous one is counted in `disorderCount` and skipped,
/// never folded in as a negative gap.
struct GapAccumulator: Sendable {
    private(set) var gapCount = 0
    private(set) var zeroGapCount = 0
    private(set) var disorderCount = 0
    private(set) var minGap: TimeInterval?
    private(set) var maxGap: TimeInterval?
    private var reservoir: ReservoirQuantiles
    private var last: Date?

    init(reservoirCapacity: Int, seed: UInt64) {
        reservoir = ReservoirQuantiles(capacity: reservoirCapacity, seed: seed)
    }

    mutating func add(start: Date) {
        defer { last = Swift.max(last ?? start, start) }
        guard let last else { return }
        let gap = start.timeIntervalSince(last)
        guard gap >= 0 else {
            disorderCount += 1
            return
        }
        gapCount += 1
        if gap == 0 { zeroGapCount += 1 }
        minGap = Swift.min(minGap ?? gap, gap)
        maxGap = Swift.max(maxGap ?? gap, gap)
        reservoir.add(gap)
    }

    var cadence: TypeProfile.Cadence? {
        guard gapCount > 0, let minGap, let maxGap else { return nil }
        let quantiles = reservoir.quantiles([0.5, 0.9])
        return TypeProfile.Cadence(
            gapCount: gapCount,
            medianGapSeconds: quantiles[0] ?? 0,
            p90GapSeconds: quantiles[1] ?? 0,
            minGapSeconds: minGap,
            maxGapSeconds: maxGap,
            zeroGapCount: zeroGapCount,
            isEstimated: reservoir.isEstimated)
    }
}

// MARK: - Samples per local day

/// Samples per calendar day, in the caller's calendar. `HKStatisticsOptions`
/// has no count option, so the count comes from the scan itself; the samples
/// arrive in start order, so the bounds of the current day are cached and the
/// calendar is consulted only when a sample crosses into a new one.
struct DailyCountAccumulator: Sendable {
    let calendar: Calendar
    private var counts: [Date: Int] = [:]
    private var currentDay: Date?
    private var currentDayEnd: Date?

    init(calendar: Calendar) {
        self.calendar = calendar
    }

    mutating func add(_ date: Date) {
        if let currentDay, let currentDayEnd, date >= currentDay, date < currentDayEnd {
            counts[currentDay, default: 0] += 1
            return
        }
        let day = calendar.startOfDay(for: date)
        currentDay = day
        currentDayEnd = calendar.date(byAdding: .day, value: 1, to: day)
        counts[day, default: 0] += 1
    }

    /// One entry per day with at least one sample, ascending.
    var dailyCounts: [TypeProfile.DailyCount] {
        counts.keys.sorted().map { TypeProfile.DailyCount(day: $0, count: counts[$0]!) }
    }

    /// Days between the first and last day with samples, inclusive, against
    /// the days that actually had any — the same calendar, so a DST day is one
    /// day whatever its length.
    var coverage: TypeProfile.Coverage? {
        guard let first = counts.keys.min(), let last = counts.keys.max() else { return nil }
        let span = (calendar.dateComponents([.day], from: first, to: last).day ?? 0) + 1
        return TypeProfile.Coverage(
            daysInSpan: span,
            daysWithSamples: counts.count,
            fraction: span > 0 ? Double(counts.count) / Double(span) : 0)
    }
}

// MARK: - Per-key breakdowns

/// Count plus first/last sample start per key — sources, devices, labels.
struct BreakdownAccumulator<Key: Hashable & Sendable>: Sendable {
    struct Entry: Sendable, Equatable {
        var count = 0
        var earliestStart: Date?
        var latestStart: Date?
        var totalDuration: TimeInterval = 0
    }

    private(set) var entries: [Key: Entry] = [:]

    mutating func add(_ key: Key, start: Date, duration: TimeInterval? = nil) {
        var entry = entries[key] ?? Entry()
        entry.count += 1
        entry.earliestStart = Swift.min(entry.earliestStart ?? start, start)
        entry.latestStart = Swift.max(entry.latestStart ?? start, start)
        if let duration { entry.totalDuration += duration }
        entries[key] = entry
    }

    /// Entries by descending count, ties broken by `order` so output is stable.
    func sortedEntries(by order: (Key, Key) -> Bool) -> [(key: Key, entry: Entry)] {
        entries.map { (key: $0.key, entry: $0.value) }.sorted {
            $0.entry.count == $1.entry.count ? order($0.key, $1.key) : $0.entry.count > $1.entry.count
        }
    }
}
