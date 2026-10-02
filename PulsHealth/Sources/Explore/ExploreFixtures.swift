#if DEBUG
import Foundation
import PulsHealthSync

/// Synthetic `TypeProfile`s for a scripted simulator run: debug builds
/// accept `-PulsFixtureProfiles 1` alongside `-PulsInitialType`, and
/// `ExploreModel.load` seeds these in memory instead of reading the store,
/// so a Type page can be screenshotted on a simulator that holds no Health
/// data and cannot grant access. Nothing is written to disk and nothing
/// reaches HealthKit; the shapes are the accumulator's, invented.
enum ExploreFixtures {
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "PulsFixtureProfiles") }

    static var profiles: [TypeProfile] {
        [sleep, heartRate, steps, cyclingDistance, workouts]
    }

    private static let calendar = Calendar.current
    private static let now = Date()
    private static func daysAgo(_ days: Int) -> Date {
        calendar.startOfDay(for: calendar.date(byAdding: .day, value: -days, to: now) ?? now)
    }

    private static func dailyCounts(days: Int, perDay: (Int) -> Int) -> [TypeProfile.DailyCount] {
        (0..<days).reversed().compactMap { offset in
            let count = perDay(offset)
            return count > 0 ? TypeProfile.DailyCount(day: daysAgo(offset), count: count) : nil
        }
    }

    private static func base(
        _ identifier: String, kind: SampleKind, unit: String? = nil, sampleCount: Int, days: Int,
        daily: [TypeProfile.DailyCount]
    ) -> TypeProfile {
        TypeProfile(
            typeIdentifier: identifier, kind: kind, unitString: unit,
            computedAt: now.addingTimeInterval(-3_600), scanDuration: 4.2,
            timeZoneID: TimeZone.current.identifier,
            rangeStart: daysAgo(ExploreModel.lookbackDays), lookbackDays: ExploreModel.lookbackDays,
            sampleCount: sampleCount, earliestStart: daysAgo(days), latestStart: now.addingTimeInterval(-1_800),
            latestEnd: now.addingTimeInterval(-600), spanSeconds: Double(days) * 86_400,
            dailyCounts: daily,
            coverage: TypeProfile.Coverage(
                daysInSpan: days, daysWithSamples: daily.count, fraction: Double(daily.count) / Double(days)),
            sources: [
                TypeProfile.SourceBreakdown(
                    name: "Apple Watch", bundleID: "com.apple.health", count: sampleCount * 4 / 5,
                    earliestStart: daysAgo(days), latestStart: now),
                TypeProfile.SourceBreakdown(
                    name: "iPhone", bundleID: "com.apple.health", count: sampleCount / 5,
                    earliestStart: daysAgo(days - 40), latestStart: daysAgo(3)),
            ],
            devices: [
                TypeProfile.DeviceBreakdown(
                    name: "Apple Watch", model: "Watch", count: sampleCount * 4 / 5,
                    earliestStart: daysAgo(days), latestStart: now),
                TypeProfile.DeviceBreakdown(
                    name: "iPhone", model: "iPhone", count: sampleCount / 5,
                    earliestStart: daysAgo(days - 40), latestStart: daysAgo(3)),
            ])
    }

    static var sleep: TypeProfile {
        let days = ExploreModel.lookbackDays
        let daily = dailyCounts(days: days) { offset in offset % 9 == 4 ? 0 : 14 + (offset * 7) % 11 }
        let total = daily.reduce(0) { $0 + $1.count }
        var profile = base(
            "HKCategoryTypeIdentifierSleepAnalysis", kind: .category, sampleCount: total, days: days, daily: daily)
        let hours: Double = 3_600
        profile.labelCounts = [
            .init(label: "0", rawValue: 0, count: 380, totalDurationSeconds: 380 * 7.8 * hours),
            .init(label: "1", rawValue: 1, count: 42, totalDurationSeconds: 42 * 6.5 * hours),
            .init(label: "2", rawValue: 2, count: 1_930, totalDurationSeconds: 1_930 * 4 * 60),
            .init(label: "3", rawValue: 3, count: 2_610, totalDurationSeconds: 2_610 * 52 * 60),
            .init(label: "4", rawValue: 4, count: 1_120, totalDurationSeconds: 1_120 * 28 * 60),
            .init(label: "5", rawValue: 5, count: 1_480, totalDurationSeconds: 1_480 * 34 * 60),
        ]
        profile.cadence = TypeProfile.Cadence(
            gapCount: total - 1, medianGapSeconds: 31 * 60, p90GapSeconds: 3.2 * hours,
            minGapSeconds: 0, maxGapSeconds: 6 * 86_400, zeroGapCount: 118, isEstimated: true)
        return profile
    }

    static var heartRate: TypeProfile {
        let days = ExploreModel.lookbackDays
        let daily = dailyCounts(days: days) { offset in offset % 13 == 6 ? 0 : 160 + (offset * 37) % 140 }
        let total = daily.reduce(0) { $0 + $1.count }
        var profile = base(
            "HKQuantityTypeIdentifierHeartRate", kind: .quantity, unit: "count/min", sampleCount: total,
            days: days, daily: daily)
        let binCount = 36
        let lower = 38.0, upper = 182.0
        let width = (upper - lower) / Double(binCount)
        let counts = (0..<binCount).map { index -> Int in
            let center = lower + (Double(index) + 0.5) * width
            // A resting hump at ~64 and a broad exercise shoulder at ~120.
            let rest = exp(-pow((center - 64) / 9, 2))
            let active = 0.28 * exp(-pow((center - 122) / 22, 2))
            return Int(Double(total) * (rest + active) / 32)
        }
        profile.values = TypeProfile.ValueDistribution(
            count: total, min: 39, max: 181, mean: 78.4, stddev: 21.6, p5: 52, median: 71, p95: 131,
            isEstimated: true,
            histogram: TypeProfile.Histogram(
                lowerBound: lower, upperBound: upper, binCount: binCount, counts: counts, isEstimated: true))
        profile.cadence = TypeProfile.Cadence(
            gapCount: total - 1, medianGapSeconds: 4 * 60, p90GapSeconds: 11 * 60,
            minGapSeconds: 0, maxGapSeconds: 2.5 * 86_400, zeroGapCount: 2_310, isEstimated: true)
        return profile
    }

    static var steps: TypeProfile {
        let days = ExploreModel.lookbackDays
        let daily = dailyCounts(days: days) { offset in 90 + (offset * 53) % 70 }
        let total = daily.reduce(0) { $0 + $1.count }
        var profile = base(
            "HKQuantityTypeIdentifierStepCount", kind: .quantity, unit: "count", sampleCount: total,
            days: days, daily: daily)
        // Watch step samples: most a few dozen steps, a long tail of walks,
        // and the 1% of imports in the thousands that the axis leaves off.
        let binCount = 40
        let width = 25.0
        let above = total / 100
        let counts = (0..<binCount).map { index in
            Int(Double(total - above) * 0.268 * exp(-Double(index) / 3.2))
        }
        profile.values = TypeProfile.ValueDistribution(
            count: total, min: 1, max: 5_025, mean: 88, stddev: 190, p5: 3, median: 25, p95: 410,
            isEstimated: true,
            histogram: TypeProfile.Histogram(
                lowerBound: 0, upperBound: Double(binCount) * width, binCount: binCount, counts: counts,
                isEstimated: true, aboveCount: above))
        profile.cadence = TypeProfile.Cadence(
            gapCount: total - 1, medianGapSeconds: 83, p90GapSeconds: 14 * 60,
            minGapSeconds: 0, maxGapSeconds: 3 * 86_400, zeroGapCount: 4_120, isEstimated: true)
        return profile
    }

    static var cyclingDistance: TypeProfile {
        let days = ExploreModel.lookbackDays
        // Second-by-second Watch samples on ride days since the spring, and
        // before that the odd ride imported from another app as one sample.
        let daily = dailyCounts(days: days) { offset in
            if offset < 150 { return offset % 3 == 0 ? 2_400 + (offset * 37) % 1_500 : 0 }
            return offset % 11 == 0 ? 1 : 0
        }
        let total = daily.reduce(0) { $0 + $1.count }
        var profile = base(
            "HKQuantityTypeIdentifierDistanceCycling", kind: .quantity, unit: "m", sampleCount: total,
            days: days, daily: daily)
        // Drawn past a long tail: 0 to 8.5 m on quarter-metre bins, with the
        // whole rides (5%, up to 33 km) left off the axis.
        let binCount = 34
        let above = total / 20
        let counts = (0..<binCount).map { index in
            let center = (Double(index) + 0.5) * 0.25
            return Int(Double(total - above) * 0.25 * exp(-pow(center - 5.5, 2) / 4.5) / 3.76)
        }
        profile.values = TypeProfile.ValueDistribution(
            count: total, min: 0, max: 33_458, mean: 42.8, stddev: 910, p5: 0.12, median: 5.69, p95: 8.46,
            isEstimated: true,
            histogram: TypeProfile.Histogram(
                lowerBound: 0, upperBound: 8.5, binCount: binCount, counts: counts, isEstimated: true,
                aboveCount: above))
        profile.cadence = TypeProfile.Cadence(
            gapCount: total - 1, medianGapSeconds: 0.9999, p90GapSeconds: 1.2,
            minGapSeconds: 0, maxGapSeconds: 40 * 86_400, zeroGapCount: 0, isEstimated: true)
        return profile
    }

    static var workouts: TypeProfile {
        let days = ExploreModel.lookbackDays
        let daily = dailyCounts(days: days) { offset in offset % 3 == 0 ? 1 : 0 }
        let total = daily.reduce(0) { $0 + $1.count }
        var profile = base("HKWorkoutTypeIdentifier", kind: .workout, sampleCount: total, days: days, daily: daily)
        profile.labelCounts = [
            .init(label: "running", count: 96, totalDurationSeconds: 96 * 41 * 60),
            .init(label: "cycling", count: 44, totalDurationSeconds: 44 * 73 * 60),
            .init(label: "functionalStrengthTraining", count: 38, totalDurationSeconds: 38 * 35 * 60),
            .init(label: "walking", count: 18, totalDurationSeconds: 18 * 48 * 60),
            .init(label: "yoga", count: 4, totalDurationSeconds: 4 * 30 * 60),
        ]
        profile.workouts = TypeProfile.WorkoutSummary(
            totalDurationSeconds: profile.labelCounts.reduce(0) { $0 + ($1.totalDurationSeconds ?? 0) },
            totalEnergyKcal: 61_200, totalDistanceMeters: 1_420_000)
        profile.cadence = TypeProfile.Cadence(
            gapCount: total - 1, medianGapSeconds: 2 * 86_400, p90GapSeconds: 5 * 86_400,
            minGapSeconds: 3_600, maxGapSeconds: 19 * 86_400, zeroGapCount: 0, isEstimated: false)
        return profile
    }
}
#endif
