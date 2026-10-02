import Foundation

/// What HealthKit holds for one catalog type, reduced to numbers.
///
/// A profile is the answer to "what is in here?" before anyone decides to sync
/// or export a type: how many samples, over what span, at what cadence, from
/// which apps and devices, and — for a quantity — how the values are
/// distributed. It is computed by `HealthExplorer.profile(for:)` from one
/// ascending scan of the type and cached by `TypeProfileStore`.
///
/// **It never holds a sample.** No UUIDs, no metadata, no per-sample values:
/// the largest thing in a profile is the histogram's bin counts plus one
/// entry per local day with data. That is what lets it sit on disk in
/// Application Support without changing the privacy claims the app makes
/// (the policy says no health samples are stored on the device, and a
/// profile is a summary, not a sample), and what keeps a multi-year heart
/// rate type's profile at a few kilobytes. Keep it that way: any field that
/// would grow with the number of samples belongs in an accumulator, not here.
///
/// Dates are encoded as epoch milliseconds (`JSONEncoder.puls`), like every
/// other file the package writes.
public struct TypeProfile: Codable, Sendable, Equatable {
    /// Bumped whenever the shape or meaning of a stored profile changes; the
    /// store drops (and deletes) any file whose version differs rather than
    /// showing numbers computed under old rules.
    /// 2: the value histogram covers the middle of the data on round bin
    /// widths, with the tails counted in `belowCount`/`aboveCount`, rather
    /// than spanning min…max.
    /// 3: that middle stops at the 5th or 95th percentile when the tail past
    /// it outruns the middle 90% (`Histogram.core(p1:p5:p95:p99:)`).
    /// 4: `lookbackDays`, for a scan of only the most recent days.
    /// 5: `readableSince`. Before it, a profile scanned under iOS 27's
    /// limited history access looked like one of a person with a month of
    /// data, and said it covered the year.
    public static let currentVersion = 5

    public var version: Int
    public var typeIdentifier: String
    public var kind: SampleKind
    /// The catalog's canonical unit for a quantity type, in which every value
    /// statistic below is expressed. Nil for every other kind.
    public var unitString: String?
    public var computedAt: Date
    public var scanDuration: TimeInterval
    /// The calendar zone the daily counts were bucketed in.
    public var timeZoneID: String
    /// The requested range (`HealthExplorer.ProfileOptions`), nil = unbounded.
    /// With a lookback, `rangeStart` is the day it resolved to.
    public var rangeStart: Date?
    public var rangeEnd: Date?
    /// `ProfileOptions.lookbackDays`: the scan covered only this many days
    /// back from the day it ran. Nil for a fixed range or the whole history.
    public var lookbackDays: Int?
    /// iOS 27 limited history access: the earliest date HealthKit let the
    /// app read the type from, when that fell inside the requested range —
    /// the scan started there, not at `rangeStart`, and every number covers
    /// only that part. Nil when the whole range was readable.
    public var readableSince: Date?
    /// False when the scan stopped before the end of the range — the reason is
    /// in `failureReason`, and every number is a lower bound over the part
    /// that was read.
    public var isComplete: Bool
    /// Scrubbed error text for an incomplete profile, or a note about samples
    /// the scan had to skip (see `SampleCursor`) on a complete one.
    public var failureReason: String?

    /// Every sample HealthKit returned, whatever its shape. This is the raw
    /// count, the one the sync's "drained" decisions are made on too — never
    /// the count of values that converted.
    public var sampleCount: Int
    /// Quantity samples whose quantity could not be expressed in `unitString`.
    /// Included in `sampleCount`, excluded from `values`. A non-zero count for
    /// a whole type means the catalog's unit is wrong for it — the same
    /// silent failure the sync engine logs as unmappable.
    public var unmappableCount: Int

    public var earliestStart: Date?
    public var latestStart: Date?
    public var latestEnd: Date?
    /// `latestEnd − earliestStart`.
    public var spanSeconds: TimeInterval?

    /// Distribution of converted values; quantity types only.
    public var values: ValueDistribution?
    /// Per-label counts: category value, workout activity, ECG classification,
    /// state-of-mind kind, medication dose status. Empty for quantity and
    /// heartbeat-series types.
    public var labelCounts: [LabelCount]
    /// Workout totals; workout type only.
    public var workouts: WorkoutSummary?
    /// Gaps between consecutive sample starts.
    public var cadence: Cadence?
    /// One entry per local day (in `timeZoneID`) with at least one sample,
    /// ascending. The one field that scales with the span of the data rather
    /// than staying fixed: ~365 entries per year of daily data.
    public var dailyCounts: [DailyCount]
    public var coverage: Coverage?
    /// Writers of the samples (the `HKSource` — an app or the system), most
    /// frequent first.
    public var sources: [SourceBreakdown]
    /// Hardware the samples came from (`HKDevice`), most frequent first. A
    /// sample with no device is counted under nil name and model.
    public var devices: [DeviceBreakdown]

    public init(
        version: Int = TypeProfile.currentVersion,
        typeIdentifier: String,
        kind: SampleKind,
        unitString: String? = nil,
        computedAt: Date,
        scanDuration: TimeInterval = 0,
        timeZoneID: String,
        rangeStart: Date? = nil,
        rangeEnd: Date? = nil,
        lookbackDays: Int? = nil,
        readableSince: Date? = nil,
        isComplete: Bool = true,
        failureReason: String? = nil,
        sampleCount: Int = 0,
        unmappableCount: Int = 0,
        earliestStart: Date? = nil,
        latestStart: Date? = nil,
        latestEnd: Date? = nil,
        spanSeconds: TimeInterval? = nil,
        values: ValueDistribution? = nil,
        labelCounts: [LabelCount] = [],
        workouts: WorkoutSummary? = nil,
        cadence: Cadence? = nil,
        dailyCounts: [DailyCount] = [],
        coverage: Coverage? = nil,
        sources: [SourceBreakdown] = [],
        devices: [DeviceBreakdown] = []
    ) {
        self.version = version
        self.typeIdentifier = typeIdentifier
        self.kind = kind
        self.unitString = unitString
        self.computedAt = computedAt
        self.scanDuration = scanDuration
        self.timeZoneID = timeZoneID
        self.rangeStart = rangeStart
        self.rangeEnd = rangeEnd
        self.lookbackDays = lookbackDays
        self.readableSince = readableSince
        self.isComplete = isComplete
        self.failureReason = failureReason
        self.sampleCount = sampleCount
        self.unmappableCount = unmappableCount
        self.earliestStart = earliestStart
        self.latestStart = latestStart
        self.latestEnd = latestEnd
        self.spanSeconds = spanSeconds
        self.values = values
        self.labelCounts = labelCounts
        self.workouts = workouts
        self.cadence = cadence
        self.dailyCounts = dailyCounts
        self.coverage = coverage
        self.sources = sources
        self.devices = devices
    }

    // MARK: - Nested shapes

    /// Summary statistics over the converted values of a quantity type.
    /// `count`, `min`, `max`, `mean` and `stddev` are exact (one pass, Welford);
    /// the quantiles and histogram come from a fixed-size uniform reservoir
    /// and are estimates once `isEstimated` — the count exceeded the
    /// reservoir — is true.
    public struct ValueDistribution: Codable, Sendable, Equatable {
        public var count: Int
        public var min: Double
        public var max: Double
        public var mean: Double
        public var stddev: Double
        public var p5: Double
        public var median: Double
        public var p95: Double
        public var isEstimated: Bool
        public var histogram: Histogram

        public init(
            count: Int, min: Double, max: Double, mean: Double, stddev: Double,
            p5: Double, median: Double, p95: Double, isEstimated: Bool, histogram: Histogram
        ) {
            self.count = count
            self.min = min
            self.max = max
            self.mean = mean
            self.stddev = stddev
            self.p5 = p5
            self.median = median
            self.p95 = p95
            self.isEstimated = isEstimated
            self.histogram = histogram
        }
    }

    /// Fixed-width bins over `[lowerBound, upperBound)`. A profile's
    /// histogram covers the middle of the data rather than min…max — one
    /// stray reading would otherwise squash every bar into the first bin —
    /// and the values it leaves out are counted in `belowCount` and
    /// `aboveCount`. `counts` and both tails are scaled back to sample
    /// counts when built from a reservoir (`isEstimated`).
    public struct Histogram: Codable, Sendable, Equatable {
        public var lowerBound: Double
        public var upperBound: Double
        public var binCount: Int
        public var counts: [Int]
        public var isEstimated: Bool
        /// Values below `lowerBound`, left off the axis.
        public var belowCount: Int
        /// Values at or above `upperBound`, left off the axis.
        public var aboveCount: Int

        public init(
            lowerBound: Double, upperBound: Double, binCount: Int, counts: [Int], isEstimated: Bool,
            belowCount: Int = 0, aboveCount: Int = 0
        ) {
            self.lowerBound = lowerBound
            self.upperBound = upperBound
            self.binCount = binCount
            self.counts = counts
            self.isEstimated = isEstimated
            self.belowCount = belowCount
            self.aboveCount = aboveCount
        }
    }

    /// One label's share of a type. `rawValue` is the `HKCategoryValue` for a
    /// category type (the label is its decimal string — the package keeps no
    /// per-type value vocabulary; the server's `category_labels` does), nil
    /// for the string-labelled kinds. `totalDurationSeconds` sums `end − start`
    /// for kinds where the interval means something (sleep stages, workouts).
    public struct LabelCount: Codable, Sendable, Equatable {
        public var label: String
        public var rawValue: Int?
        public var count: Int
        public var totalDurationSeconds: TimeInterval?

        public init(label: String, rawValue: Int? = nil, count: Int, totalDurationSeconds: TimeInterval? = nil) {
            self.label = label
            self.rawValue = rawValue
            self.count = count
            self.totalDurationSeconds = totalDurationSeconds
        }
    }

    /// Totals over every workout scanned. `withRouteCount` is nil until a
    /// scan reads routes, which today's does not (a route is a second query
    /// per workout, and the profile is meant to be cheap).
    public struct WorkoutSummary: Codable, Sendable, Equatable {
        public var totalDurationSeconds: TimeInterval
        public var totalEnergyKcal: Double?
        public var totalDistanceMeters: Double?
        public var withRouteCount: Int?

        public init(
            totalDurationSeconds: TimeInterval, totalEnergyKcal: Double? = nil,
            totalDistanceMeters: Double? = nil, withRouteCount: Int? = nil
        ) {
            self.totalDurationSeconds = totalDurationSeconds
            self.totalEnergyKcal = totalEnergyKcal
            self.totalDistanceMeters = totalDistanceMeters
            self.withRouteCount = withRouteCount
        }
    }

    /// Gaps between consecutive sample starts, in seconds. Min, max and the
    /// counts are exact; the median and p90 are reservoir estimates when
    /// `isEstimated`. `zeroGapCount` — samples sharing a start to the
    /// millisecond — is high for types several sources write at once.
    public struct Cadence: Codable, Sendable, Equatable {
        public var gapCount: Int
        public var medianGapSeconds: TimeInterval
        public var p90GapSeconds: TimeInterval
        public var minGapSeconds: TimeInterval
        public var maxGapSeconds: TimeInterval
        public var zeroGapCount: Int
        public var isEstimated: Bool

        public init(
            gapCount: Int, medianGapSeconds: TimeInterval, p90GapSeconds: TimeInterval,
            minGapSeconds: TimeInterval, maxGapSeconds: TimeInterval, zeroGapCount: Int, isEstimated: Bool
        ) {
            self.gapCount = gapCount
            self.medianGapSeconds = medianGapSeconds
            self.p90GapSeconds = p90GapSeconds
            self.minGapSeconds = minGapSeconds
            self.maxGapSeconds = maxGapSeconds
            self.zeroGapCount = zeroGapCount
            self.isEstimated = isEstimated
        }
    }

    /// Samples starting on one local day; `day` is that day's local midnight.
    public struct DailyCount: Codable, Sendable, Equatable {
        public var day: Date
        public var count: Int

        public init(day: Date, count: Int) {
            self.day = day
            self.count = count
        }
    }

    /// How much of the span between the first and last day with data has any.
    public struct Coverage: Codable, Sendable, Equatable {
        public var daysInSpan: Int
        public var daysWithSamples: Int
        public var fraction: Double

        public init(daysInSpan: Int, daysWithSamples: Int, fraction: Double) {
            self.daysInSpan = daysInSpan
            self.daysWithSamples = daysWithSamples
            self.fraction = fraction
        }
    }

    public struct SourceBreakdown: Codable, Sendable, Equatable {
        public var name: String
        public var bundleID: String
        public var count: Int
        public var earliestStart: Date
        public var latestStart: Date

        public init(name: String, bundleID: String, count: Int, earliestStart: Date, latestStart: Date) {
            self.name = name
            self.bundleID = bundleID
            self.count = count
            self.earliestStart = earliestStart
            self.latestStart = latestStart
        }
    }

    public struct DeviceBreakdown: Codable, Sendable, Equatable {
        public var name: String?
        public var model: String?
        public var count: Int
        public var earliestStart: Date
        public var latestStart: Date

        public init(name: String?, model: String?, count: Int, earliestStart: Date, latestStart: Date) {
            self.name = name
            self.model = model
            self.count = count
            self.earliestStart = earliestStart
            self.latestStart = latestStart
        }
    }
}

/// The cheap answer about a type: three tiny queries (oldest sample, newest
/// sample, the set of writers), enough to draw a row in a list and to decide
/// whether a cached `TypeProfile` is still current without a full scan.
public struct TypeQuickFacts: Sendable, Equatable {
    public var typeIdentifier: String
    public var earliestStart: Date?
    public var latestStart: Date?
    /// Names of the apps and system sources that have written the type,
    /// sorted; empty when HealthKit holds nothing (or read access was denied,
    /// which HealthKit makes indistinguishable by design).
    public var sourceNames: [String]
    /// iOS 27 limited history access: the earliest date HealthKit lets the
    /// app read the type from, nil when unlimited (and always before
    /// iOS 27). `earliestStart` is then the oldest *readable* sample — older
    /// ones exist or not, and HealthKit does not say.
    public var readableSince: Date?

    public init(
        typeIdentifier: String, earliestStart: Date?, latestStart: Date?, sourceNames: [String],
        readableSince: Date? = nil
    ) {
        self.typeIdentifier = typeIdentifier
        self.earliestStart = earliestStart
        self.latestStart = latestStart
        self.sourceNames = sourceNames
        self.readableSince = readableSince
    }
}

/// Where a profile scan is, for a progress view. Delivered after every page.
public struct ProfileProgress: Sendable, Equatable {
    public enum Phase: String, Sendable {
        case probing
        case scanning
        case finishing
    }

    public var phase: Phase
    public var samplesScanned: Int
    public var pagesScanned: Int
    /// Start of the last sample read so far.
    public var scannedThrough: Date?

    public init(phase: Phase, samplesScanned: Int = 0, pagesScanned: Int = 0, scannedThrough: Date? = nil) {
        self.phase = phase
        self.samplesScanned = samplesScanned
        self.pagesScanned = pagesScanned
        self.scannedThrough = scannedThrough
    }
}

public typealias ProfileProgressHandler = @Sendable (ProfileProgress) -> Void

/// Why the explorer could not answer. `queryFailed` carries text already
/// passed through `ErrorScrubber`, so it is safe to show and to persist.
public enum HealthExploreError: Error, LocalizedError, Sendable, Equatable {
    case healthDataUnavailable
    case deviceLocked
    case unknownType(String)
    case unsupportedKind(String)
    case queryFailed(String)

    public var errorDescription: String? {
        switch self {
        case .healthDataUnavailable:
            return "HealthKit is not available on this device"
        case .deviceLocked:
            return "Health data is unavailable while the device is locked"
        case .unknownType(let identifier):
            return "Unknown type identifier: \(identifier)"
        case .unsupportedKind(let detail):
            return "Not supported for this type: \(detail)"
        case .queryFailed(let reason):
            return "HealthKit query failed: \(reason)"
        }
    }
}
