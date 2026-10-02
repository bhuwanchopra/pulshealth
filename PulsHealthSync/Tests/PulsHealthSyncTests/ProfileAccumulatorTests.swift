import Foundation
import Testing
@testable import PulsHealthSync

@Suite struct ProfileAccumulatorTests {
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private let base = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01T00:00:00Z

    private func sample(
        _ offset: TimeInterval, value: Double? = nil, hasQuantity: Bool = false,
        category: Int? = nil, label: String? = nil, duration: TimeInterval? = nil,
        energy: Double? = nil, distance: Double? = nil, length: TimeInterval = 0,
        source: (String, String) = ("Watch", "com.apple.health"), device: (String?, String?) = (nil, nil)
    ) -> ScannedSample {
        ScannedSample(
            start: base.addingTimeInterval(offset), end: base.addingTimeInterval(offset + length),
            value: value, hasQuantity: hasQuantity, category: category, label: label,
            duration: duration, energyKcal: energy, distanceMeters: distance,
            sourceName: source.0, sourceBundleID: source.1, deviceName: device.0, deviceModel: device.1)
    }

    private func accumulator(_ kind: SampleKind, unit: String? = "count/min") -> ProfileAccumulator {
        ProfileAccumulator(
            typeIdentifier: "Test", kind: kind, unitString: unit, histogramBins: 4,
            reservoirCapacity: 100, calendar: Self.utc, seed: 1)
    }

    private func finish(_ acc: ProfileAccumulator, complete: Bool = true, reason: String? = nil) -> TypeProfile {
        acc.finish(
            computedAt: base, scanDuration: 1.5, rangeStart: nil, rangeEnd: nil,
            isComplete: complete, failureReason: reason)
    }

    // MARK: - Quantity

    @Test func quantityProfileKeepsRawCountAndUnmappableSeparately() {
        var acc = accumulator(.quantity)
        acc.add(sample(0, value: 60, hasQuantity: true))
        acc.add(sample(60, value: 70, hasQuantity: true))
        acc.add(sample(120, value: 80, hasQuantity: true, device: ("Apple Watch", "Watch")))
        acc.add(sample(180, value: nil, hasQuantity: true)) // wrong unit
        acc.add(sample(240, value: .nan, hasQuantity: true))
        let profile = finish(acc)

        #expect(profile.sampleCount == 5)
        #expect(profile.unmappableCount == 2)
        #expect(profile.unitString == "count/min")
        let values = profile.values!
        #expect(values.count == 3)
        #expect(values.min == 60)
        #expect(values.max == 80)
        #expect(values.mean == 70)
        #expect(values.median == 70)
        #expect(!values.isEstimated)
        // Round bins of 5 from 60, the last one holding 80 on its own.
        #expect(values.histogram.lowerBound == 60)
        #expect(values.histogram.counts == [1, 0, 1, 0, 1])
        #expect(values.histogram.counts.reduce(0, +) == 3)
        #expect(profile.labelCounts.isEmpty)
        #expect(profile.workouts == nil)
        #expect(profile.earliestStart == base)
        #expect(profile.latestStart == base.addingTimeInterval(240))
        #expect(profile.spanSeconds == 240)
        #expect(profile.cadence?.gapCount == 4)
        #expect(profile.cadence?.medianGapSeconds == 60)
        #expect(profile.dailyCounts == [TypeProfile.DailyCount(day: base, count: 5)])
        #expect(profile.coverage == TypeProfile.Coverage(daysInSpan: 1, daysWithSamples: 1, fraction: 1))
        #expect(profile.sources.count == 1)
        #expect(profile.sources[0].name == "Watch")
        #expect(profile.sources[0].count == 5)
        #expect(profile.devices.map(\.count) == [4, 1])
        #expect(profile.devices[1].model == "Watch")
        #expect(profile.timeZoneID == Self.utc.timeZone.identifier)
        #expect(profile.version == TypeProfile.currentVersion)
    }

    @Test func quantityWithNoConvertibleValuesHasNoDistribution() {
        var acc = accumulator(.quantity)
        acc.add(sample(0, value: nil, hasQuantity: true))
        let profile = finish(acc)
        #expect(profile.sampleCount == 1)
        #expect(profile.unmappableCount == 1)
        #expect(profile.values == nil)
    }

    @Test func largeQuantityStreamIsEstimatedAndScaled() {
        var acc = accumulator(.quantity)
        for i in 0..<10_000 { acc.add(sample(Double(i), value: Double(i % 100), hasQuantity: true)) }
        let values = finish(acc).values!
        #expect(values.isEstimated)
        #expect(values.count == 10_000)
        #expect(values.histogram.isEstimated)
        let total = values.histogram.counts.reduce(0, +)
        #expect(abs(total - 10_000) < 100)
        #expect(abs(values.median - 50) < 5)
    }

    @Test func quantityHistogramStopsAtThe95thPastALongTail() {
        // 96 Watch-sized readings under 8, and four imported whole rides.
        var acc = accumulator(.quantity, unit: "m")
        for i in 0..<96 { acc.add(sample(Double(i), value: Double(i % 8) + 0.5, hasQuantity: true)) }
        for (i, ride) in [5_000.0, 12_000, 20_000, 30_000].enumerated() {
            acc.add(sample(Double(100 + i), value: ride, hasQuantity: true))
        }
        let values = finish(acc).values!
        #expect(values.max == 30_000)
        #expect(values.histogram.lowerBound == 0)
        #expect(values.histogram.upperBound == 8)
        #expect(values.histogram.aboveCount == 4)
        #expect(values.histogram.counts.reduce(0, +) == 96)
    }

    // MARK: - Category

    @Test func categoryLabelsCountAndSumDurations() {
        var acc = accumulator(.category, unit: nil)
        acc.add(sample(0, category: 3, length: 600))
        acc.add(sample(600, category: 4, length: 300))
        acc.add(sample(900, category: 3, length: 100))
        let profile = finish(acc)
        #expect(profile.unitString == nil)
        #expect(profile.values == nil)
        #expect(profile.labelCounts == [
            TypeProfile.LabelCount(label: "3", rawValue: 3, count: 2, totalDurationSeconds: 700),
            TypeProfile.LabelCount(label: "4", rawValue: 4, count: 1, totalDurationSeconds: 300),
        ])
        #expect(profile.latestEnd == base.addingTimeInterval(1_000))
        #expect(profile.spanSeconds == 1_000)
    }

    // MARK: - Workouts

    @Test func workoutSummaryTotalsAndLabels() {
        var acc = accumulator(.workout, unit: nil)
        acc.add(sample(0, label: "running", duration: 1_800, energy: 300, distance: 5_000, length: 2_000))
        acc.add(sample(86_400, label: "cycling", duration: 3_600, energy: nil, distance: 20_000, length: 3_600))
        acc.add(sample(172_800, label: "running", duration: 900, energy: 150, distance: nil, length: 900))
        let profile = finish(acc)
        #expect(profile.workouts == TypeProfile.WorkoutSummary(
            totalDurationSeconds: 6_300, totalEnergyKcal: 450, totalDistanceMeters: 25_000, withRouteCount: nil))
        #expect(profile.labelCounts.map(\.label) == ["running", "cycling"])
        #expect(profile.labelCounts[0].totalDurationSeconds == 2_700)
        #expect(profile.dailyCounts.count == 3)
    }

    // MARK: - Other kinds

    @Test func labelledKindsCountLabelsWithoutDurations() {
        for kind in [SampleKind.ecg, .stateOfMind, .medicationDose] {
            var acc = accumulator(kind, unit: nil)
            acc.add(sample(0, label: "a", length: 30))
            acc.add(sample(1, label: "a", length: 30))
            acc.add(sample(2, label: "b", length: 30))
            let profile = finish(acc)
            #expect(profile.labelCounts == [
                TypeProfile.LabelCount(label: "a", rawValue: nil, count: 2, totalDurationSeconds: nil),
                TypeProfile.LabelCount(label: "b", rawValue: nil, count: 1, totalDurationSeconds: nil),
            ])
            #expect(profile.workouts == nil)
        }
        var acc = accumulator(.heartbeatSeries, unit: nil)
        acc.add(sample(0, length: 60))
        #expect(finish(acc).labelCounts.isEmpty)
    }

    @Test func emptyStreamProfilesAsNothing() {
        let profile = finish(accumulator(.quantity), complete: false, reason: "locked")
        #expect(profile.sampleCount == 0)
        #expect(profile.values == nil)
        #expect(profile.cadence == nil)
        #expect(profile.coverage == nil)
        #expect(profile.earliestStart == nil)
        #expect(profile.spanSeconds == nil)
        #expect(!profile.isComplete)
        #expect(profile.failureReason == "locked")
        #expect(profile.sources.isEmpty)
    }

    // MARK: - Codable

    @Test func profileRoundTripsWithEpochMillisecondDates() throws {
        var acc = accumulator(.quantity)
        acc.add(sample(0.5, value: 60, hasQuantity: true))
        acc.add(sample(61.25, value: 61, hasQuantity: true, device: ("Watch", "Watch")))
        let profile = finish(acc)

        let data = try JSONEncoder.puls.encode(profile)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["computedAt"] as? Double == 1_767_225_600_000)
        #expect(json["earliestStart"] as? Double == 1_767_225_600_500)
        // Nothing per-sample: no UUIDs, no metadata, no value arrays.
        #expect(json["samples"] == nil)
        #expect(json["uuids"] == nil)
        #expect(json["metadata"] == nil)

        let decoded = try JSONDecoder.puls.decode(TypeProfile.self, from: data)
        #expect(decoded == profile)
    }
}
